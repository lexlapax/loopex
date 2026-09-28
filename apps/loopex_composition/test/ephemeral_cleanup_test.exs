defmodule LoopexComposition.Ephemeral.CleanupTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias Loopex.Runtime
  alias LoopexComposition.Ephemeral
  alias LoopexComposition.Ephemeral.{OwnerActivation, SessionOwner}

  defmodule Policy do
    @moduledoc false
    @behaviour Loopex.Policy

    @impl true
    def decide(_request), do: {:allow, nil}
  end

  setup do
    tmp = Path.join(System.tmp_dir!(), "loopex-cleanup-#{System.unique_integer([:positive])}")
    File.mkdir!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)
    %{tmp: tmp}
  end

  test "each failed drain is reaped before independent runtime and subtree teardown", %{
    tmp: tmp
  } do
    test = self()

    for failure <- [:error, :malformed, :raise, :throw, :exit, :cutoff] do
      drain = fn _executor, _instance, _owner, _nonce, _deadline ->
        send(test, {:drain_entered, failure, self()})

        receive do
          :release -> drain_failure(failure)
        end
      end

      session = start_session(tmp, drain)
      {:loopex_ephemeral_session, owner, cell} = session

      %{startup: %{owned_root: %{path: root}, registered: %{runtime: %Runtime{} = runtime}}} =
        :sys.get_state(owner)

      assert File.dir?(root)
      runtime_monitor = Process.monitor(runtime.supervisor)
      root_pid = :sys.get_state(owner).startup.root
      root_monitor = Process.monitor(root_pid)
      stop = Task.async(fn -> Ephemeral.stop_session(session) end)
      assert_receive {:drain_entered, ^failure, worker}, 3_000
      worker_monitor = Process.monitor(worker)

      assert %{stage: :process_groups, worker: %{pid: ^worker, result: false}} =
               :sys.get_state(owner).abort

      send(owner, {:EXIT, worker, :normal})
      send(owner, {:DOWN, make_ref(), :process, worker, :normal})

      assert %{stage: :process_groups, worker: %{pid: ^worker, result: false}} =
               :sys.get_state(owner).abort

      assert Process.alive?(runtime.supervisor)
      assert Process.alive?(root_pid)

      if failure != :cutoff, do: send(worker, :release)

      assert_receive {:DOWN, ^worker_monitor, :process, ^worker, :killed}, 3_000

      assert {:error,
              {:cleanup_unproved,
               %{pending: [:process_groups], root: ^root, root_ownership: :owned}}} =
               Task.await(stop, 7_000)

      assert_receive {:DOWN, ^runtime_monitor, :process, _, _}, 1_000
      assert_receive {:DOWN, ^root_monitor, :process, ^root_pid, _}, 1_000
      assert :atomics.get(cell, 1) == 3
      assert File.dir?(root)
    end
  end

  test "runtime stop waits for its worker result, finish, and exact DOWN", %{tmp: tmp} do
    session = start_session(tmp, successful_drain())
    {:loopex_ephemeral_session, owner, cell} = session

    %{startup: %{owned_root: %{path: root}, registered: %{runtime: %Runtime{} = runtime}}} =
      :sys.get_state(owner)

    root_pid = :sys.get_state(owner).startup.root
    runtime_monitor = Process.monitor(runtime.supervisor)
    root_monitor = Process.monitor(root_pid)

    suspension = suspend_runtime(runtime.supervisor)
    on_exit(fn -> send(suspension, {self(), :release}) end)
    stop = Task.async(fn -> Ephemeral.stop_session(session) end)
    stop_ref = stop.ref

    assert %{stage: :runtime_stop, worker: %{pid: worker, reference: reference} = phase_worker} =
             await_runtime_stop(owner)

    assert %{result: false, finish_sent: false} = phase_worker
    worker_monitor = Process.monitor(worker)

    send(owner, {:EXIT, worker, :normal})
    send(owner, {:DOWN, make_ref(), :process, worker, :normal})

    send(
      owner,
      {worker, make_ref(), :runtime_stop, :result, :ok, System.monotonic_time()}
    )

    send(
      owner,
      {self(), reference, :runtime_stop, :result, :ok, System.monotonic_time()}
    )

    assert %{stage: :runtime_stop, worker: %{pid: ^worker, result: false, finish_sent: false}} =
             :sys.get_state(owner).abort

    assert Process.alive?(worker)
    assert Process.alive?(root_pid)
    assert File.dir?(root)
    refute_receive {^stop_ref, _}, 0

    send(suspension, {self(), :release})
    assert_receive {^suspension, :released}, 1_000

    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, :normal}, 1_000
    assert :ok = Task.await(stop, 7_000)
    assert_receive {:DOWN, ^runtime_monitor, :process, _, _}, 1_000
    assert_receive {:DOWN, ^root_monitor, :process, ^root_pid, _}, 1_000
    assert :atomics.get(cell, 1) == 2
    refute File.exists?(root)
  end

  test "a retry cannot remove a replacement for the previously owned root", %{tmp: tmp} do
    test = self()
    removals = :atomics.new(1, signed: false)

    remove = fn path ->
      send(test, {:remove_invoked, path})
      :atomics.add_get(removals, 1, 1)
      {:error, :eacces}
    end

    session = start_session(tmp, successful_drain(), rm_rf: remove)
    {:loopex_ephemeral_session, owner, cell} = session
    root = :sys.get_state(owner).startup.owned_root.path

    assert {:error,
            {:cleanup_unproved, %{pending: [:root_removal], root: ^root, root_ownership: :owned}}} =
             Ephemeral.stop_session(session)

    assert_receive {:remove_invoked, ^root}, 1_000
    assert :atomics.get(removals, 1) == 1
    assert File.dir?(root)

    original = root <> ".original"
    File.rename!(root, original)
    File.mkdir!(root)
    marker = Path.join(root, "replacement-marker")
    File.write!(marker, "not owned by this session")

    assert {:error,
            {:cleanup_unproved, %{pending: [:root_removal], root: ^root, root_ownership: :owned}}} =
             Ephemeral.stop_session(session)

    refute_receive {:remove_invoked, ^root}, 25
    assert :atomics.get(removals, 1) == 1
    assert File.read!(marker) == "not owned by this session"
    assert File.dir?(original)
    assert :atomics.get(cell, 1) == 3
  end

  defp drain_failure(:error), do: {:error, :drain_failed}
  defp drain_failure(:malformed), do: :unexpected
  defp drain_failure(:raise), do: raise("drain failed")
  defp drain_failure(:throw), do: throw(:drain_failed)
  defp drain_failure(:exit), do: exit(:drain_failed)

  defp successful_drain do
    fn executor, instance, owner, nonce, _deadline ->
      send(owner, {executor, instance, nonce, :groups_empty})
      {:ok, nonce}
    end
  end

  defp start_session(tmp, drain, options \\ []) do
    {:ok, _digest, manifest} =
      Loopex.ResourcePack.digest(%{
        "version" => "loopex.resource_pack/1",
        "workspace_ref" => "workspace-ref",
        "revision" => nil,
        "packs" => []
      })

    temp_root =
      %{tmp: fn -> tmp end}
      |> maybe_remove_seam(options[:rm_rf])

    configuration = %{
      cwd: tmp,
      model: "ollama:test",
      provider: %{credential_variable: nil},
      base_url: "http://localhost:11434",
      policy: Policy,
      tools: :none,
      skills: %{manifest: manifest, shadowed_skills: []},
      max_steps: 16,
      deadline_ms: 60_000,
      max_tokens: 128,
      context_token_budget: 8_192,
      timeout: 60_000,
      test_seams: %{temp_root: temp_root, group_drain: drain}
    }

    {:ok, supervisor} = DynamicSupervisor.start_link(strategy: :one_for_one)

    on_exit(fn ->
      if Process.alive?(supervisor), do: Process.exit(supervisor, :shutdown)
    end)

    {:ok, activation} = OwnerActivation.start(supervisor)
    owner = OwnerActivation.owner(activation)
    {:ok, cell} = OwnerActivation.begin(activation)
    assert {:ok, :session_ready} = SessionOwner.start_session(owner, configuration, 6_000)
    {:loopex_ephemeral_session, owner, cell}
  end

  defp maybe_remove_seam(temp_root, nil), do: temp_root
  defp maybe_remove_seam(temp_root, remove), do: Map.put(temp_root, :rm_rf, remove)

  defp await_runtime_stop(owner) do
    Enum.reduce_while(1..100, nil, fn _, _ ->
      case :sys.get_state(owner).abort do
        %{stage: :runtime_stop, worker: worker} = abort when is_map(worker) ->
          {:halt, abort}

        _ ->
          Process.sleep(2)
          {:cont, nil}
      end
    end)
  end

  defp suspend_runtime(runtime_supervisor) do
    test = self()

    # Concept: hold the real runtime stop worker while forged completions arrive.
    # Technical depth: Supervisor.stop still terminates a :sys-suspended supervisor;
    # the process that suspends it must also resume it, including after test failure.
    suspension =
      spawn(fn ->
        test_monitor = Process.monitor(test)
        true = :erlang.suspend_process(runtime_supervisor)
        send(test, {self(), :suspended})

        receive do
          {requester, :release} ->
            true = :erlang.resume_process(runtime_supervisor)
            send(requester, {self(), :released})

          {:DOWN, ^test_monitor, :process, ^test, _} ->
            :erlang.resume_process(runtime_supervisor)
        end
      end)

    assert_receive {^suspension, :suspended}, 1_000
    suspension
  end
end
