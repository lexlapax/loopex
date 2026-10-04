defmodule LoopexComposition.Ephemeral.UnknownRootTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias LoopexComposition.Ephemeral.{OwnerActivation, SessionOwner}

  defmodule Policy do
    @moduledoc false
    @behaviour Loopex.Policy

    @impl true
    def decide(_request), do: {:allow, nil}
  end

  test "pre-claim cleanup uncertainty has no invented root path or claim grant" do
    test = self()

    tmp =
      Path.join(System.tmp_dir!(), "loopex-unknown-root-#{System.unique_integer([:positive])}")

    File.mkdir!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)

    configuration =
      configuration(tmp, %{
        temp_root: %{
          tmp: fn -> tmp end,
          entropy: fn 32 ->
            Process.flag(:trap_exit, true)
            send(test, {:candidate_prepare_blocked, self()})

            receive do
              :release_candidate_prepare ->
                send(test, :candidate_prepare_resumed)
                :binary.copy(<<1>>, 32)
            end
          end,
          mkdir: fn path ->
            send(test, {:unexpected_claim, path})
            File.mkdir(path)
          end,
          lstat: fn path ->
            send(test, {:unexpected_inspect, path})
            File.lstat(path)
          end,
          rm_rf: fn path ->
            send(test, {:unexpected_remove, path})
            File.rm_rf(path)
          end
        }
      })

    creator =
      spawn(fn ->
        {:ok, supervisor} = DynamicSupervisor.start_link(strategy: :one_for_one)
        {:ok, activation} = OwnerActivation.start(supervisor)
        owner = OwnerActivation.owner(activation)
        {:ok, cell} = OwnerActivation.begin(activation)
        send(test, {:owner, owner, cell})
        send(test, {:result, SessionOwner.start_session(owner, configuration, 20_000)})
        receive do: (:finish -> :ok)
      end)

    assert_receive {:owner, owner, cell}, 2_000
    assert_receive {:candidate_prepare_blocked, root}, 2_000

    on_exit(fn ->
      Process.exit(root, :kill)
      send(creator, :finish)
    end)

    assert %{startup: %{root: ^root, candidate: nil, owned_root: nil}} = :sys.get_state(owner)
    assert File.ls!(tmp) == []

    assert_receive {:result,
                    {:error,
                     {:cleanup_unproved,
                      %{
                        root: nil,
                        root_ownership: :unknown,
                        pending: [:session_subtree],
                        ending: :none
                      }}}},
                   20_000

    assert :atomics.get(cell, 1) == 3
    assert File.ls!(tmp) == []

    send(root, :release_candidate_prepare)
    assert_receive :candidate_prepare_resumed, 1_000
    refute_receive {:unexpected_claim, _path}, 50
    refute_receive {:unexpected_inspect, _path}, 0
    refute_receive {:unexpected_remove, _path}, 0
    assert File.ls!(tmp) == []
  end

  test "an exact collision is not retained while the next candidate stalls" do
    test = self()
    tmp = temporary_directory()
    on_exit(fn -> File.rm_rf!(tmp) end)

    configuration =
      configuration(tmp, %{
        temp_root: %{
          tmp: fn -> tmp end,
          entropy: fn 32 ->
            count = Process.get(:collision_then_stall, 0) + 1
            Process.put(:collision_then_stall, count)

            if count == 1 do
              <<1::unsigned-size(256)>>
            else
              Process.flag(:trap_exit, true)
              send(test, {:next_candidate_blocked, self()})
              receive do: (:release_next_candidate -> <<2::unsigned-size(256)>>)
            end
          end,
          mkdir: fn path ->
            File.mkdir!(path)
            send(test, {:foreign_path, path})
            {:error, :eexist}
          end,
          lstat: fn path ->
            send(test, {:unexpected_inspect, path})
            File.lstat(path)
          end,
          rm_rf: fn path ->
            send(test, {:unexpected_remove, path})
            File.rm_rf(path)
          end
        }
      })

    creator =
      spawn(fn ->
        {:ok, supervisor} = DynamicSupervisor.start_link(strategy: :one_for_one)
        {:ok, activation} = OwnerActivation.start(supervisor)
        owner = OwnerActivation.owner(activation)
        {:ok, cell} = OwnerActivation.begin(activation)
        send(test, {:owner, owner, cell})
        send(test, {:result, SessionOwner.start_session(owner, configuration, 20_000)})
        receive do: (:finish -> :ok)
      end)

    assert_receive {:owner, _owner, cell}, 2_000
    assert_receive {:foreign_path, foreign_path}, 2_000
    assert_receive {:next_candidate_blocked, root}, 2_000

    on_exit(fn ->
      if Process.alive?(root), do: Process.exit(root, :kill)
      send(creator, :finish)
    end)

    assert_receive {:result,
                    {:error,
                     {:cleanup_unproved,
                      %{root: nil, root_ownership: :unknown, pending: [:session_subtree]}}}},
                   20_000

    assert :atomics.get(cell, 1) == 3
    assert File.dir?(foreign_path)
    send(root, :release_next_candidate)
    refute_receive {:unexpected_inspect, _}, 50
    refute_receive {:unexpected_remove, _}, 0
    assert File.dir?(foreign_path)
  end

  test "a real startup timeout drops a reply queued ahead of cancellation" do
    test = self()
    tmp = temporary_directory()
    on_exit(fn -> File.rm_rf!(tmp) end)
    configuration = configuration(tmp, %{})

    creator =
      spawn(fn ->
        {:ok, supervisor} = DynamicSupervisor.start_link(strategy: :one_for_one)
        {:ok, activation} = OwnerActivation.start(supervisor)
        owner = OwnerActivation.owner(activation)
        {:ok, cell} = OwnerActivation.begin(activation)
        send(test, {:owner, owner, cell})

        receive do
          :start ->
            send(test, {:result, SessionOwner.start_session(owner, configuration, 1)})
        end

        receive do: (:finish -> :ok)
      end)

    assert_receive {:owner, owner, cell}, 2_000
    owner_monitor = Process.monitor(owner)
    :ok = :sys.suspend(owner)

    on_exit(fn ->
      if Process.alive?(owner), do: :sys.resume(owner)
      send(creator, :finish)
    end)

    send(creator, :start)
    assert_receive {:result, {:error, :session_unavailable}}, 18_000
    :ok = :sys.resume(owner)
    assert_receive {:DOWN, ^owner_monitor, :process, ^owner, :normal}, 2_000
    assert :atomics.get(cell, 1) == 2
    assert {:messages, messages} = Process.info(creator, :messages)
    refute Enum.any?(messages, &match?({^owner, _, _}, &1))
    assert File.ls!(tmp) == []
  end

  test "abort deadline ahead of timeout cancellation still logs unproved cleanup" do
    test = self()
    tmp = temporary_directory()
    on_exit(fn -> File.rm_rf!(tmp) end)

    configuration =
      configuration(tmp, %{
        candidate_ready: fn candidate ->
          Process.flag(:trap_exit, true)
          send(test, {:candidate_known, self(), candidate})
          receive do: (:release_candidate_ready -> :ok)
        end,
        subtree_stop: fn root ->
          send(test, {:subtree_stop_blocked, self(), root})
          receive do: (:release_subtree_stop -> :ok)
        end,
        temp_root: root_seam(test, tmp)
      })

    creator =
      spawn(fn ->
        {:ok, supervisor} = DynamicSupervisor.start_link(strategy: :one_for_one)
        {:ok, activation} = OwnerActivation.start(supervisor)
        owner = OwnerActivation.owner(activation)
        {:ok, cell} = OwnerActivation.begin(activation)
        send(test, {:owner, owner, cell})
        send(test, {:result, SessionOwner.start_session(owner, configuration, 1)})
        receive do: (:finish -> :ok)
      end)

    assert_receive {:owner, owner, cell}, 2_000
    assert_receive {:candidate_known, root, %{path: path}}, 2_000
    assert_receive {:subtree_stop_blocked, _worker, ^root}, 7_000
    owner_monitor = Process.monitor(owner)
    :ok = :sys.suspend(owner)

    on_exit(fn ->
      if Process.alive?(owner), do: :sys.resume(owner)
      if Process.alive?(root), do: Process.exit(root, :kill)
      send(creator, :finish)
    end)

    assert_receive {:result, {:error, :session_unavailable}}, 18_000

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        :ok = :sys.resume(owner)
        assert_receive {:DOWN, ^owner_monitor, :process, ^owner, :normal}, 2_000
      end)

    assert log =~ "possible_root=#{inspect(path)}"
    assert log =~ "root_ownership=unknown"
    assert log =~ "pending=[:session_subtree]"
    assert :atomics.get(cell, 1) == 3
    assert {:messages, messages} = Process.info(creator, :messages)
    refute Enum.any?(messages, &match?({^owner, _, _}, &1))
    assert File.ls!(tmp) == []
  end

  test "a known candidate is retained when creator loss leaves teardown unproved" do
    test = self()
    tmp = temporary_directory()
    on_exit(fn -> File.rm_rf!(tmp) end)

    configuration =
      configuration(tmp, %{
        candidate_ready: fn candidate ->
          send(test, {:candidate_known, self(), candidate})
          receive do: (:release_candidate_ready -> :ok)
        end,
        subtree_stop: fn root ->
          send(test, {:subtree_stop_blocked, self(), root})

          receive do
            :release_subtree_stop ->
              Process.exit(root, :shutdown)
              :ok
          end
        end,
        temp_root: root_seam(test, tmp)
      })

    {:ok, supervisor} = DynamicSupervisor.start_link(strategy: :one_for_one)
    on_exit(fn -> stop_supervisor(supervisor) end)

    creator =
      spawn(fn ->
        {:ok, activation} = OwnerActivation.start(supervisor)
        owner = OwnerActivation.owner(activation)
        {:ok, cell} = OwnerActivation.begin(activation)
        send(test, {:owner, owner, cell})
        _ = SessionOwner.start_session(owner, configuration, 20_000)
      end)

    assert_receive {:owner, owner, cell}, 2_000
    assert_receive {:candidate_known, root, %{path: path}}, 2_000
    on_exit(fn -> if Process.alive?(root), do: Process.exit(root, :kill) end)
    assert candidate_recorded?(owner, path)
    owner_monitor = Process.monitor(owner)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        Process.exit(creator, :kill)
        assert_receive {:subtree_stop_blocked, _worker, ^root}, 2_000

        assert %{phase: :aborting, startup: %{possible_root: ^path, owned_root: nil}} =
                 :sys.get_state(owner)

        assert eventually(fn -> :atomics.get(cell, 1) == 3 end, 1_200)
        assert_receive {:DOWN, ^owner_monitor, :process, ^owner, :normal}, 2_000
      end)

    assert log =~ path
    assert log =~ "pending=[:session_subtree]"
    refute_receive {:unexpected_claim, _}, 0
    refute_receive {:unexpected_inspect, _}, 0
    refute_receive {:unexpected_remove, _}, 0
    assert File.ls!(tmp) == []
  end

  test "collision grant does not authorize removing the next unclaimed candidate" do
    test = self()
    tmp = temporary_directory()
    on_exit(fn -> File.rm_rf!(tmp) end)

    configuration =
      configuration(tmp, %{
        candidate_ready: fn candidate ->
          count = Process.get(:candidate_gate_count, 0) + 1
          Process.put(:candidate_gate_count, count)

          if count == 2 do
            send(test, {:candidate_known, self(), candidate})
            receive do: (:release_candidate_ready -> :ok)
          end
        end,
        temp_root: collision_then_candidate_seam(test, tmp)
      })

    {:ok, supervisor} = DynamicSupervisor.start_link(strategy: :one_for_one)
    on_exit(fn -> stop_supervisor(supervisor) end)

    creator =
      spawn(fn ->
        {:ok, activation} = OwnerActivation.start(supervisor)
        owner = OwnerActivation.owner(activation)
        {:ok, cell} = OwnerActivation.begin(activation)
        request = :erlang.alias([:reply])
        send(owner, {self(), request, :start_session, configuration})
        send(test, {:owner, owner, cell})

        receive do
          :cancel ->
            :erlang.unalias(request)
            send(owner, {self(), request, :cancel_start})
        end

        receive do: (:finish -> :ok)
      end)

    assert_receive {:owner, owner, cell}, 2_000
    assert_receive {:foreign_path, foreign_path}, 2_000
    assert_receive {:candidate_known, root, %{path: path}}, 2_000
    on_exit(fn -> if Process.alive?(root), do: Process.exit(root, :kill) end)
    assert candidate_recorded?(owner, path)
    assert :sys.get_state(owner).startup.root_claim_granted == false
    owner_monitor = Process.monitor(owner)

    send(creator, :cancel)
    assert_receive {:DOWN, ^owner_monitor, :process, ^owner, :normal}, 3_000
    assert :atomics.get(cell, 1) == 2
    assert {:messages, messages} = Process.info(creator, :messages)
    refute Enum.any?(messages, &match?({^owner, _, _}, &1))
    send(creator, :finish)
    refute_receive {:unexpected_claim, _}, 0
    refute_receive {:unexpected_inspect, _}, 0
    refute_receive {:unexpected_remove, _}, 0
    assert File.dir?(foreign_path)
    assert File.ls!(tmp) == [Path.basename(foreign_path)]
  end

  test "creator loss during startup abort does not crash the owner" do
    test = self()
    tmp = temporary_directory()
    on_exit(fn -> File.rm_rf!(tmp) end)

    configuration =
      configuration(tmp, %{
        candidate_ready: fn candidate ->
          send(test, {:candidate_known, self(), candidate})
          receive do: (:release_candidate_ready -> :ok)
        end,
        subtree_stop: fn root ->
          send(test, {:subtree_stop_blocked, self(), root})

          receive do
            :release_subtree_stop ->
              Process.exit(root, :shutdown)
              :ok
          end
        end,
        temp_root: root_seam(test, tmp)
      })

    {:ok, supervisor} = DynamicSupervisor.start_link(strategy: :one_for_one)
    on_exit(fn -> stop_supervisor(supervisor) end)

    creator =
      spawn(fn ->
        {:ok, activation} = OwnerActivation.start(supervisor)
        owner = OwnerActivation.owner(activation)
        {:ok, cell} = OwnerActivation.begin(activation)
        send(test, {:owner, owner, cell})
        _ = SessionOwner.start_session(owner, configuration, 20_000)
      end)

    assert_receive {:owner, owner, cell}, 2_000
    assert_receive {:candidate_known, root, %{path: path}}, 2_000
    on_exit(fn -> if Process.alive?(root), do: Process.exit(root, :kill) end)
    assert candidate_recorded?(owner, path)
    owner_monitor = Process.monitor(owner)

    assert_receive {:subtree_stop_blocked, worker, ^root}, 7_000
    assert :sys.get_state(owner).startup.no_waiter == false
    Process.exit(creator, :kill)
    assert eventually(fn -> :sys.get_state(owner).startup.no_waiter end)
    send(worker, :release_subtree_stop)

    assert eventually(fn -> :atomics.get(cell, 1) == 2 end)
    assert_receive {:DOWN, ^owner_monitor, :process, ^owner, :normal}, 2_000
    refute_receive {:unexpected_claim, _}, 0
    assert File.ls!(tmp) == []
  end

  test "the final exact collision retires its foreign path before teardown" do
    test = self()
    tmp = temporary_directory()
    on_exit(fn -> File.rm_rf!(tmp) end)

    configuration =
      configuration(tmp, %{
        temp_root: %{
          tmp: fn -> tmp end,
          entropy: fn 32 ->
            count = Process.get(:collision_attempt, 0) + 1
            Process.put(:collision_attempt, count)
            <<count::unsigned-size(256)>>
          end,
          mkdir: fn path ->
            File.mkdir!(path)
            send(test, {:foreign_path, path})
            {:error, :eexist}
          end,
          lstat: fn path ->
            send(test, {:unexpected_inspect, path})
            File.lstat(path)
          end,
          rm_rf: fn path ->
            send(test, {:unexpected_remove, path})
            File.rm_rf(path)
          end
        }
      })

    {:ok, supervisor} = DynamicSupervisor.start_link(strategy: :one_for_one)
    on_exit(fn -> stop_supervisor(supervisor) end)
    {:ok, activation} = OwnerActivation.start(supervisor)
    owner = OwnerActivation.owner(activation)
    {:ok, cell} = OwnerActivation.begin(activation)

    assert {:error, {:composition, :temporary_root_creation_failed}} =
             SessionOwner.start_session(owner, configuration, 6_000)

    paths =
      for _ <- 1..16 do
        assert_receive {:foreign_path, path}, 1_000
        path
      end

    assert Enum.uniq(paths) == paths
    assert Enum.all?(paths, &File.dir?/1)
    assert length(File.ls!(tmp)) == 16
    assert :atomics.get(cell, 1) == 2
    refute_received {:unexpected_inspect, _}
    refute_received {:unexpected_remove, _}
  end

  defp temporary_directory do
    tmp =
      Path.join(System.tmp_dir!(), "loopex-unknown-root-#{System.unique_integer([:positive])}")

    File.mkdir!(tmp)
    tmp
  end

  defp root_seam(test, tmp) do
    %{
      tmp: fn -> tmp end,
      entropy: fn 32 -> :binary.copy(<<1>>, 32) end,
      mkdir: fn path ->
        send(test, {:unexpected_claim, path})
        File.mkdir(path)
      end,
      lstat: fn path ->
        send(test, {:unexpected_inspect, path})
        File.lstat(path)
      end,
      rm_rf: fn path ->
        send(test, {:unexpected_remove, path})
        File.rm_rf(path)
      end
    }
  end

  defp collision_then_candidate_seam(test, tmp) do
    %{
      tmp: fn -> tmp end,
      entropy: fn 32 ->
        count = Process.get(:collision_nonce_count, 0) + 1
        Process.put(:collision_nonce_count, count)
        <<count::unsigned-size(256)>>
      end,
      mkdir: fn path ->
        count = Process.get(:collision_mkdir_count, 0) + 1
        Process.put(:collision_mkdir_count, count)

        if count == 1 do
          File.mkdir!(path)
          send(test, {:foreign_path, path})
          {:error, :eexist}
        else
          send(test, {:unexpected_claim, path})
          File.mkdir(path)
        end
      end,
      lstat: fn path ->
        send(test, {:unexpected_inspect, path})
        File.lstat(path)
      end,
      rm_rf: fn path ->
        send(test, {:unexpected_remove, path})
        File.rm_rf(path)
      end
    }
  end

  defp configuration(tmp, seams) do
    %{
      cwd: tmp,
      model: "ollama:test",
      provider: %{credential_variable: nil},
      base_url: "http://localhost:11434",
      policy: Policy,
      tools: :read_only,
      skills: %{
        manifest: %{"version" => "loopex.resource_pack/1", "packs" => []},
        shadowed_skills: []
      },
      max_steps: 16,
      deadline_ms: 60_000,
      max_tokens: 128,
      context_token_budget: 8_192,
      test_seams: seams
    }
    |> LoopexComposition.PreparedSessionFixture.capture()
  end

  defp candidate_recorded?(owner, path) do
    eventually(fn ->
      case :sys.get_state(owner) do
        %{startup: %{expected: :root_claim, granted: false, candidate: %{path: ^path}}} ->
          true

        _ ->
          false
      end
    end)
  end

  defp eventually(check, attempts \\ 100)
  defp eventually(check, 0), do: check.()

  defp eventually(check, attempts) do
    if check.() do
      true
    else
      Process.sleep(10)
      eventually(check, attempts - 1)
    end
  end

  defp stop_supervisor(supervisor) do
    Supervisor.stop(supervisor)
  catch
    :exit, _ -> :ok
  end
end
