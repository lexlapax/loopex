defmodule LoopexComposition.Ephemeral.StopContractTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias LoopexComposition.Ephemeral
  alias LoopexComposition.Ephemeral.{OwnerActivation, SessionOwner}

  defmodule Policy do
    @moduledoc false
    def decide(_request), do: {:allow, nil}
  end

  defmodule Facade do
    @moduledoc false

    def create_session(_runtime, %{"surface" => "embedded"}, command_id: "create"),
      do: {:ok, "stop-contract-session"}

    def attach(runtime, "stop-contract-session", after_event_sequence: 0) do
      Process.put(:events, [])
      Process.put(:sequence, 0)

      {:ok,
       %Loopex.Attachment{
         runtime: runtime,
         session_id: "stop-contract-session",
         attachment_id: "a",
         incarnation_id: "i",
         snapshot: %{}
       }}
    end

    def session_status(_runtime, "stop-contract-session"),
      do:
        {:ok,
         %{
           status: :active,
           owner_epoch: 0,
           active_run_id: nil,
           pending_work_ids: [],
           cleanup_grace_ms: 5_000
         }}

    def command(_attachment, %{type: :prompt} = command) do
      run_id = "run-" <> command.content

      enqueue(%{
        "command_id" => command.command_id,
        "run_id" => run_id,
        "content" => command.content,
        kind: "user.message_appended"
      })

      enqueue(%{
        "run_id" => run_id,
        "content" => "answer: " <> command.content,
        kind: "assistant.message_appended"
      })

      enqueue(%{
        "run_id" => run_id,
        "outcome" => "completed",
        "cleanup_grace_ms" => 5_000,
        kind: "run.finished"
      })

      {:accepted, command.command_id}
    end

    def next_event(_attachment) do
      case Process.get(:events, []) do
        [event | rest] ->
          Process.put(:events, rest)
          {:ok, event}

        [] ->
          {:error, :empty}
      end
    end

    defp enqueue(event) do
      sequence = Process.get(:sequence) + 1
      Process.put(:sequence, sequence)
      Process.put(:events, Process.get(:events) ++ [Map.put(event, :event_sequence, sequence)])
    end
  end

  setup do
    tmp = Path.join(System.tmp_dir!(), "loopex-stop-#{System.unique_integer([:positive])}")
    File.mkdir!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)
    {:ok, tmp: tmp}
  end

  test "concurrent stops share one drain and ignore stale worker and certificate messages", %{
    tmp: tmp
  } do
    test = self()

    drain = fn executor, instance, owner, nonce, _deadline ->
      send(test, {:drain_started, self(), executor, instance, owner, nonce})

      receive do
        :release_drain ->
          send(owner, {executor, instance, nonce, :groups_empty})
          {:ok, nonce}
      end
    end

    session = start_session(tmp, group_drain: drain)
    {:loopex_ephemeral_session, owner, cell} = session
    root = owned_root(owner)
    first = Task.async(fn -> Ephemeral.stop_session(session) end)
    assert_receive {:drain_started, worker, executor, instance, ^owner, nonce}, 3_000

    assert %{stage: :process_groups, worker: %{pid: ^worker, result: false}} =
             :sys.get_state(owner).abort

    second = Task.async(fn -> Ephemeral.stop_session(session) end)
    assert eventually(fn -> length(:sys.get_state(owner).stop.waiters) == 2 end)

    send(
      owner,
      {worker, make_ref(), :process_groups, :result, {:ok, nonce}, System.monotonic_time()}
    )

    send(owner, {executor, instance, make_ref(), :groups_empty})

    send(
      owner,
      {self(), make_ref(), :process_groups, :result, {:ok, nonce}, System.monotonic_time()}
    )

    assert %{worker: %{pid: ^worker, result: false, certificate: false}} =
             :sys.get_state(owner).abort

    send(worker, :release_drain)
    assert :ok = Task.await(first, 7_000)
    assert :ok = Task.await(second, 7_000)
    assert :atomics.get(cell, 1) == 2
    refute File.exists?(root)
    refute_receive {:drain_started, _, _, _, _, _}
    assert :ok = Ephemeral.stop_session(session)
  end

  test "queued in-time drain proof survives cutoff and exact DOWN precedes slot", %{tmp: tmp} do
    test = self()

    drain = fn executor, instance, owner, nonce, _deadline ->
      send(test, {:queued_drain_started, self()})

      receive do
        :release_queued_drain ->
          send(owner, {executor, instance, nonce, :groups_empty})
          {:ok, nonce}
      end
    end

    session =
      start_session(tmp,
        group_drain: drain,
        result_enqueued: test,
        abort_phase_window_ms: {5_000, 6_000}
      )

    {:loopex_ephemeral_session, owner, cell} = session
    root = owned_root(owner)
    stop = Task.async(fn -> Ephemeral.stop_session(session) end)
    assert_receive {:queued_drain_started, worker}, 3_000

    assert %{worker: %{pid: ^worker, reference: reference, cutoff: cutoff}} =
             :sys.get_state(owner).abort

    on_exit(fn ->
      if Process.alive?(owner), do: :sys.resume(owner)

      if Process.info(worker, :status) == {:status, :suspended},
        do: :erlang.resume_process(worker)
    end)

    assert :ok = :sys.suspend(owner)
    send(owner, {:abort_operation_cutoff, reference})
    send(worker, :release_queued_drain)

    assert_receive {:abort_result_enqueued, ^worker, ^reference, :process_groups, completed_at},
                   1_000

    assert completed_at <= cutoff
    assert true = :erlang.suspend_process(worker)
    assert :ok = :sys.resume(owner)

    assert eventually(fn ->
             case :sys.get_state(owner).abort do
               %{worker: %{pid: ^worker, result: true, certificate: true, finish_sent: true}} ->
                 true

               _ ->
                 false
             end
           end)

    assert Process.alive?(worker)

    monitor = Process.monitor(worker)
    assert true = :erlang.resume_process(worker)
    assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 1_000

    assert :ok = Task.await(stop, 7_000)
    assert :atomics.get(cell, 1) == 2
    refute File.exists?(root)
  end

  test "a normal DOWN observed after slot cannot prove cleanup before its timer arrives", %{
    tmp: tmp
  } do
    test = self()

    drain = fn executor, instance, owner, nonce, _deadline ->
      send(test, {:late_down_drain_started, self()})

      receive do
        :release_late_down_drain ->
          send(owner, {executor, instance, nonce, :groups_empty})
          {:ok, nonce}
      end
    end

    session =
      start_session(tmp,
        group_drain: drain,
        result_enqueued: test,
        abort_phase_window_ms: {2_000, 3_000}
      )

    {:loopex_ephemeral_session, owner, cell} = session
    root = owned_root(owner)
    stop = Task.async(fn -> Ephemeral.stop_session(session) end)
    assert_receive {:late_down_drain_started, worker}, 3_000
    assert %{worker: %{pid: ^worker, reference: reference}} = :sys.get_state(owner).abort

    on_exit(fn ->
      if Process.alive?(owner), do: :sys.resume(owner)

      if Process.info(worker, :status) == {:status, :suspended},
        do: :erlang.resume_process(worker)
    end)

    assert :ok = :sys.suspend(owner)
    send(worker, :release_late_down_drain)
    assert_receive {:abort_result_enqueued, ^worker, ^reference, :process_groups, _}, 1_000
    assert true = :erlang.suspend_process(worker)
    assert :ok = :sys.resume(owner)

    assert eventually(fn ->
             case :sys.get_state(owner).abort do
               %{worker: %{pid: ^worker, result: true, certificate: true, finish_sent: true}} ->
                 true

               _ ->
                 false
             end
           end)

    :sys.replace_state(owner, fn state ->
      put_in(state.abort.worker.slot, System.monotonic_time() - 1)
    end)

    monitor = Process.monitor(worker)
    assert true = :erlang.resume_process(worker)
    assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 1_000

    assert {:error, {:cleanup_unproved, %{pending: pending, root: ^root}}} =
             Task.await(stop, 7_000)

    assert :process_groups in pending
    assert :atomics.get(cell, 1) == 3
    assert File.dir?(root)
  end

  test "a queued drain result completed after the stored cutoff cannot prove cleanup", %{
    tmp: tmp
  } do
    test = self()

    drain = fn executor, instance, owner, nonce, _deadline ->
      send(test, {:late_drain_started, self()})

      receive do
        :release_late_drain ->
          send(owner, {executor, instance, nonce, :groups_empty})
          {:ok, nonce}
      end
    end

    session =
      start_session(tmp,
        group_drain: drain,
        result_enqueued: test,
        abort_phase_window_ms: {2_000, 3_000}
      )

    {:loopex_ephemeral_session, owner, cell} = session
    root = owned_root(owner)
    stop = Task.async(fn -> Ephemeral.stop_session(session) end)
    assert_receive {:late_drain_started, worker}, 3_000

    assert %{worker: %{pid: ^worker, reference: reference}} =
             :sys.get_state(owner).abort

    :sys.replace_state(owner, fn state ->
      put_in(state.abort.worker.cutoff, System.monotonic_time() - 1)
    end)

    assert %{worker: %{cutoff: cutoff}} = :sys.get_state(owner).abort

    on_exit(fn -> if Process.alive?(owner), do: :sys.resume(owner) end)

    assert :ok = :sys.suspend(owner)
    send(owner, {:abort_operation_cutoff, reference})

    send(worker, :release_late_drain)

    assert_receive {:abort_result_enqueued, ^worker, ^reference, :process_groups, completed_at},
                   2_000

    assert completed_at > cutoff
    assert :ok = :sys.resume(owner)

    assert {:error, {:cleanup_unproved, %{pending: pending, root: ^root}}} =
             Task.await(stop, 7_000)

    assert :process_groups in pending
    assert :atomics.get(cell, 1) == 3
    assert File.dir?(root)
  end

  test "drain completion after the cleanup deadline starts no next cleanup operation", %{
    tmp: tmp
  } do
    test = self()

    drain = fn executor, instance, owner, nonce, _deadline ->
      send(test, {:deadline_drain_started, self()})

      receive do
        :release_deadline_drain ->
          send(owner, {executor, instance, nonce, :groups_empty})
          {:ok, nonce}
      end
    end

    session =
      start_session(tmp,
        group_drain: drain,
        phase_started: test,
        result_enqueued: test,
        abort_phase_window_ms: {5_000, 6_000}
      )

    {:loopex_ephemeral_session, owner, cell} = session
    root = owned_root(owner)
    runtime = :sys.get_state(owner).startup.registered.runtime
    stop = Task.async(fn -> Ephemeral.stop_session(session) end)
    assert_receive {:deadline_drain_started, worker}, 3_000
    assert_receive {:abort_phase_started, :process_groups}, 1_000

    :sys.replace_state(owner, fn state ->
      put_in(state.abort.deadline, System.monotonic_time() - 1)
    end)

    assert %{worker: %{pid: ^worker, reference: reference}} = :sys.get_state(owner).abort
    send(worker, :release_deadline_drain)
    assert_receive {:abort_result_enqueued, ^worker, ^reference, :process_groups, _}, 1_000

    assert {:error, {:cleanup_unproved, %{pending: pending, root: ^root}}} =
             Task.await(stop, 7_000)

    refute_receive {:abort_phase_started, :runtime_stop}, 0
    refute :process_groups in pending
    assert :session_subtree in pending
    assert Process.alive?(runtime.supervisor)
    assert :atomics.get(cell, 1) == 3
    assert File.dir?(root)
  end

  test "a direct certificate cannot replace a failed drain result", %{tmp: tmp} do
    bad =
      start_session(tmp,
        group_drain: fn executor, instance, owner, nonce, _deadline ->
          send(owner, {executor, instance, nonce, :groups_empty})
          {:error, :drain_failed}
        end
      )

    peer = start_session(tmp)
    {:loopex_ephemeral_session, bad_owner, bad_cell} = bad
    {:loopex_ephemeral_session, _peer_owner, peer_cell} = peer
    bad_root = owned_root(bad_owner)
    bad_subtree = Map.keys(:sys.get_state(bad_owner).startup.process_monitors)

    assert {:error,
            {:cleanup_unproved, %{pending: pending, root: ^bad_root, root_ownership: :owned}}} =
             Ephemeral.stop_session(bad)

    assert pending in [[:process_groups], [:process_groups, :session_subtree]]

    if pending == [:process_groups] do
      refute Enum.any?(bad_subtree, &Process.alive?/1)
    end

    assert :atomics.get(bad_cell, 1) == 3
    assert File.dir?(bad_root)
    assert {:error, :session_unavailable} = Ephemeral.ask(bad, "closed")
    assert :atomics.get(peer_cell, 1) == 0
    assert {:ok, %{text: "answer: peer", outcome: :completed}} = Ephemeral.ask(peer, "peer")
    assert :ok = Ephemeral.stop_session(peer)
    assert :atomics.get(peer_cell, 1) == 2
  end

  test "slot handler takes a queued exact DOWN for a dead worker before later teardown", %{
    tmp: tmp
  } do
    test = self()

    session =
      start_session(tmp,
        group_drain: fn _executor, _instance, _owner, _nonce, _deadline ->
          send(test, {:drain_worker, self()})

          receive do
            :never -> :ok
          end
        end
      )

    {:loopex_ephemeral_session, owner, cell} = session
    startup = :sys.get_state(owner).startup
    root = startup.owned_root.path
    subtree = Map.keys(startup.process_monitors)
    stop = Task.async(fn -> Ephemeral.stop_session(session) end)
    assert_receive {:drain_worker, worker}, 3_000

    assert %{worker: %{pid: ^worker, monitor: owner_monitor, reference: reference}} =
             :sys.get_state(owner).abort

    monitor = Process.monitor(worker)

    :ok = :sys.suspend(owner)

    try do
      # Concept: an expired operation never proves its group, but a reaped worker
      # allows independent runtime and subtree teardown to continue.
      # Technical depth: a separate real monitor first proves worker death; an
      # test-injected exact DOWN tuple is then queued behind the slot event.
      # This avoids a race between delivery to the test and suspended owner.
      send(owner, {:abort_slot_deadline, reference})
      Process.exit(worker, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^worker, :killed}, 1_000
      send(owner, {:DOWN, owner_monitor, :process, worker, :killed})
    after
      if Process.alive?(owner), do: :sys.resume(owner)
    end

    assert {:error,
            {:cleanup_unproved,
             %{pending: [:process_groups], root: ^root, root_ownership: :owned}}} =
             Task.await(stop, 7_000)

    refute Enum.any?(subtree, &Process.alive?/1)
    assert :atomics.get(cell, 1) == 3
    assert File.dir?(root)
  end

  test "a successful worker return without the direct certificate cannot close", %{tmp: tmp} do
    session =
      start_session(tmp,
        group_drain: fn _executor, _instance, _owner, nonce, _deadline ->
          {:ok, nonce}
        end
      )

    {:loopex_ephemeral_session, owner, cell} = session
    startup = :sys.get_state(owner).startup
    root = startup.owned_root.path
    subtree = Map.keys(startup.process_monitors)
    assert subtree != []

    assert {:error,
            {:cleanup_unproved,
             %{
               pending: pending,
               root: ^root,
               root_ownership: :owned
             }}} =
             Ephemeral.stop_session(session)

    # Concept: missing group proof always seals the session, even if its subtree ended.
    # Technical depth: the worker DOWN and owner slot timer can win in either order.
    assert pending in [[:process_groups], [:process_groups, :session_subtree]]

    if pending == [:process_groups] do
      refute Enum.any?(subtree, &Process.alive?/1)
    end

    assert :atomics.get(cell, 1) == 3
    assert File.dir?(root)
    assert {:error, :session_unavailable} = Ephemeral.stop_session(session)
  end

  test "a matching certificate forged by the drain worker cannot close", %{tmp: tmp} do
    session =
      start_session(tmp,
        fake_group_attestation: false,
        group_drain: fn executor, instance, owner, nonce, _deadline ->
          send(owner, {executor, instance, nonce, :groups_empty})
          {:ok, nonce}
        end
      )

    {:loopex_ephemeral_session, owner, cell} = session
    root = owned_root(owner)
    subtree = Map.keys(:sys.get_state(owner).startup.process_monitors)

    assert {:error, {:cleanup_unproved, %{pending: pending, root: ^root, root_ownership: :owned}}} =
             Ephemeral.stop_session(session)

    assert pending in [[:process_groups], [:process_groups, :session_subtree]]

    if pending == [:process_groups] do
      refute Enum.any?(subtree, &Process.alive?/1)
    end

    assert :atomics.get(cell, 1) == 3
    assert File.dir?(root)
  end

  test "root-removal refusal retains a retryable root and retry gets a new deadline", %{
    tmp: tmp
  } do
    test = self()
    attempts = :atomics.new(1, signed: false)
    drains = :atomics.new(1, signed: false)

    drain = fn executor, instance, owner, nonce, _deadline ->
      :atomics.add_get(drains, 1, 1)
      send(owner, {executor, instance, nonce, :groups_empty})
      {:ok, nonce}
    end

    remove = fn path ->
      case :atomics.add_get(attempts, 1, 1) do
        1 ->
          {:error, :eacces}

        2 ->
          send(test, {:retry_removal_started, self(), path})

          receive do
            :release_removal -> File.rm_rf(path)
          end
      end
    end

    session = start_session(tmp, group_drain: drain, rm_rf: remove)
    {:loopex_ephemeral_session, owner, cell} = session
    root = owned_root(owner)

    assert {:error,
            {:cleanup_unproved, %{pending: [:root_removal], root: ^root, root_ownership: :owned}}} =
             Ephemeral.stop_session(session)

    assert :atomics.get(cell, 1) == 3
    assert File.dir?(root)
    assert :atomics.get(attempts, 1) == 1
    assert :atomics.get(drains, 1) == 1
    first_deadline = :sys.get_state(owner).stop.deadline

    retry = Task.async(fn -> Ephemeral.stop_session(session) end)
    assert_receive {:retry_removal_started, worker, ^root}, 3_000
    assert :sys.get_state(owner).stop.deadline > first_deadline
    assert :atomics.get(drains, 1) == 1
    assert %{stage: :root_removal, worker: %{pid: ^worker}} = :sys.get_state(owner).abort
    assert :atomics.get(cell, 1) == 3
    send(worker, :release_removal)

    assert :ok = Task.await(retry, 7_000)
    assert :atomics.get(cell, 1) == 2
    assert :atomics.get(attempts, 1) == 2
    refute File.exists?(root)
    assert :ok = Ephemeral.stop_session(session)
  end

  defp start_session(tmp, options \\ []) do
    {:ok, _digest, manifest} =
      Loopex.ResourcePack.digest(%{
        "version" => "loopex.resource_pack/1",
        "workspace_ref" => "workspace-ref",
        "revision" => nil,
        "packs" => []
      })

    drain =
      options[:group_drain] ||
        fn executor, instance, owner, nonce, _deadline ->
          send(owner, {executor, instance, nonce, :groups_empty})
          {:ok, nonce}
        end

    temp_root = %{tmp: fn -> tmp end}

    temp_root =
      if options[:rm_rf], do: Map.put(temp_root, :rm_rf, options[:rm_rf]), else: temp_root

    test_seams = %{temp_root: temp_root, group_drain: drain}

    test_seams =
      Enum.reduce([:phase_started, :result_enqueued, :abort_phase_window_ms], test_seams, fn key,
                                                                                             seams ->
        case Keyword.fetch(options, key) do
          {:ok, value} -> Map.put(seams, key, value)
          :error -> seams
        end
      end)

    test_seams =
      if Keyword.get(options, :fake_group_attestation, true) do
        Map.put(test_seams, :group_attest, fn _executor, _instance, _nonce, _deadline -> :ok end)
      else
        test_seams
      end

    configuration = %{
      cwd: tmp,
      model: "ollama:test",
      provider: %{credential_variable: nil},
      base_url: "http://localhost:11434",
      policy: Policy,
      tools: :read_only,
      skills: %{manifest: manifest, shadowed_skills: []},
      max_steps: 16,
      deadline_ms: 60_000,
      max_tokens: 128,
      context_token_budget: 8_192,
      timeout: 60_000,
      test_facade: Facade,
      test_seams: test_seams
    }

    {:ok, supervisor} = DynamicSupervisor.start_link(strategy: :one_for_one)
    {:ok, activation} = OwnerActivation.start(supervisor)
    owner = OwnerActivation.owner(activation)
    {:ok, cell} = OwnerActivation.begin(activation)
    assert {:ok, :session_ready} = SessionOwner.start_session(owner, configuration, 6_000)
    {:loopex_ephemeral_session, owner, cell}
  end

  defp owned_root(owner), do: :sys.get_state(owner).startup.owned_root.path

  defp eventually(predicate, attempts \\ 200)
  defp eventually(_predicate, 0), do: false

  defp eventually(predicate, attempts) do
    if predicate.() do
      true
    else
      Process.sleep(5)
      eventually(predicate, attempts - 1)
    end
  end
end
