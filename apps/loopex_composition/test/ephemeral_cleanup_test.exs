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

  test "stop preserves a prior session-local seal until cleanup is proved", %{tmp: tmp} do
    test = self()

    drain = fn executor, instance, owner, nonce, _deadline ->
      send(test, {:sealed_drain_entered, self()})

      receive do
        :release_sealed_drain ->
          send(owner, {executor, instance, nonce, :groups_empty})
          {:ok, nonce}
      end
    end

    session = start_session(tmp, drain)
    {:loopex_ephemeral_session, _owner, cell} = session
    :atomics.put(cell, 1, 3)

    stop = Task.async(fn -> Ephemeral.stop_session(session) end)
    assert_receive {:sealed_drain_entered, worker}, 3_000
    assert :atomics.get(cell, 1) == 3
    send(worker, :release_sealed_drain)
    assert :ok = Task.await(stop, 7_000)
    assert :atomics.get(cell, 1) == 2
  end

  test "each failed drain seals group cleanup and reaps its worker", %{
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
              {:cleanup_unproved, %{pending: pending, root: ^root, root_ownership: :owned}}} =
               Task.await(stop, 7_000)

      assert pending in [[:process_groups], [:process_groups, :session_subtree]]

      if pending == [:process_groups] do
        assert_receive {:DOWN, ^runtime_monitor, :process, _, _}, 1_000
        assert_receive {:DOWN, ^root_monitor, :process, ^root_pid, _}, 1_000
      end

      assert :atomics.get(cell, 1) == 3
      assert File.dir?(root)
    end
  end

  test "runtime stop waits for its worker result, finish, and exact DOWN", %{tmp: tmp} do
    test = self()
    session = start_session(tmp, successful_drain(), phase_started: {test, :runtime_stop})
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
             suspend_at_phase(owner, :runtime_stop)

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

    # Concept: observe the owner after the forged messages and before the real result.
    # Technical depth: the suspended owner handles this queued sys request after
    # the forged messages; the worker cannot answer until the runtime is released.
    probe = make_ref()
    send(owner, {:system, {test, probe}, :get_state})

    assert Process.alive?(worker)
    assert Process.alive?(root_pid)
    assert File.dir?(root)
    refute_receive {^stop_ref, _}, 0

    send(suspension, {self(), :release})
    assert_receive {^suspension, :released}, 1_000
    assert :ok = :sys.resume(owner)

    assert_receive {^probe, {:ok, %{abort: probed}}}, 1_000

    assert %{stage: :runtime_stop, worker: %{pid: ^worker, result: false, finish_sent: false}} =
             probed

    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, :normal}, 1_000
    assert :ok = Task.await(stop, 7_000)
    assert_receive {:DOWN, ^runtime_monitor, :process, _, _}, 1_000
    assert_receive {:DOWN, ^root_monitor, :process, ^root_pid, _}, 1_000
    assert :atomics.get(cell, 1) == 2
    refute File.exists?(root)
  end

  test "a lost runtime root cannot certify a surviving session child", %{tmp: tmp} do
    test = self()

    drain = fn executor, instance, owner, nonce, _deadline ->
      send(test, {:drain_entered, self()})

      receive do
        :release ->
          send(owner, {executor, instance, nonce, :groups_empty})
          {:ok, nonce}
      end
    end

    session = start_session(tmp, drain)
    {:loopex_ephemeral_session, owner, cell} = session

    %{startup: %{owned_root: %{path: root}, registered: %{runtime: %Runtime{} = runtime}}} =
      :sys.get_state(owner)

    assert {:ok, %{owner_groups: owner_groups}} = Runtime.children(runtime)

    [{_, group, :worker, _}] = DynamicSupervisor.which_children(owner_groups)
    suspension = suspend_process(group)
    on_exit(fn -> send(suspension, {self(), :release}) end)

    runtime_monitor = Process.monitor(runtime.supervisor)
    stop = Task.async(fn -> Ephemeral.stop_session(session) end)
    assert_receive {:drain_entered, worker}, 3_000

    Process.exit(runtime.supervisor, :kill)
    assert_receive {:DOWN, ^runtime_monitor, :process, _, :killed}, 1_000
    assert Process.alive?(group)
    send(worker, :release)

    assert {:error,
            {:cleanup_unproved,
             %{pending: [:session_subtree], root: ^root, root_ownership: :owned}}} =
             Task.await(stop, 7_000)

    assert :atomics.get(cell, 1) == 3
    assert Process.alive?(group)
    assert File.dir?(root)

    group_monitor = Process.monitor(group)
    send(suspension, {self(), :release})
    assert_receive {^suspension, :released}, 1_000
    if Process.alive?(group), do: Process.exit(group, :kill)
    assert_receive {:DOWN, ^group_monitor, :process, ^group, _}, 1_000
  end

  test "a failed runtime-stop worker cannot certify the session subtree", %{tmp: tmp} do
    session = start_session(tmp, successful_drain(), phase_started: {self(), :runtime_stop})
    {:loopex_ephemeral_session, owner, cell} = session

    %{startup: %{owned_root: %{path: root}, registered: %{runtime: %Runtime{} = runtime}}} =
      :sys.get_state(owner)

    suspension = suspend_runtime(runtime.supervisor)
    on_exit(fn -> send(suspension, {self(), :release}) end)
    stop = Task.async(fn -> Ephemeral.stop_session(session) end)

    assert %{stage: :runtime_stop, worker: %{pid: worker}} =
             suspend_at_phase(owner, :runtime_stop)

    monitor = Process.monitor(worker)
    Process.exit(worker, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^worker, :killed}, 1_000
    assert :ok = :sys.resume(owner)
    send(suspension, {self(), :release})
    assert_receive {^suspension, :released}, 1_000

    assert {:error,
            {:cleanup_unproved,
             %{pending: [:session_subtree], root: ^root, root_ownership: :owned}}} =
             Task.await(stop, 7_000)

    assert :atomics.get(cell, 1) == 3
    assert File.dir?(root)
  end

  test "subtree stop waits for its worker result, finish, and exact DOWN", %{tmp: tmp} do
    test = self()

    subtree_stop = fn root ->
      send(test, {:subtree_stop_entered, self(), root})

      receive do
        {^test, :release} ->
          Process.exit(root, :shutdown)
          :ok
      end
    end

    session = start_session(tmp, successful_drain(), subtree_stop: subtree_stop)
    {:loopex_ephemeral_session, owner, cell} = session
    %{startup: %{root: root_pid, owned_root: %{path: root}}} = :sys.get_state(owner)
    root_monitor = Process.monitor(root_pid)
    # Concept: hold a live subtree while testing its stop-worker ordering.
    # Technical depth: runtime shutdown otherwise makes its holder collapse the root first.
    holder = :sys.get_state(owner).startup.registered.runtime_holder
    holder_suspension = suspend_process(holder)
    on_exit(fn -> send(holder_suspension, {self(), :release}) end)
    stop = Task.async(fn -> Ephemeral.stop_session(session) end)
    stop_ref = stop.ref

    assert_receive {:subtree_stop_entered, worker, ^root_pid}, 3_000

    on_exit(fn ->
      send(worker, {test, :release})
      if Process.alive?(worker), do: :erlang.resume_process(worker)
      if Process.alive?(owner), do: :sys.resume(owner)
    end)

    worker_monitor = Process.monitor(worker)

    assert %{
             stage: :subtree_stop,
             worker: %{
               pid: ^worker,
               reference: reference,
               monitor: monitor,
               result: false,
               finish_sent: false
             },
             root_removal_attempted: false
           } = :sys.get_state(owner).abort

    send(owner, {:EXIT, worker, :normal})
    send(owner, {:DOWN, make_ref(), :process, worker, :normal})
    send(owner, {:DOWN, monitor, :process, self(), :normal})
    send(owner, {:DOWN, monitor, :process, worker, :normal})
    send(owner, {worker, make_ref(), :subtree_stop, :result, :ok, System.monotonic_time()})
    send(owner, {self(), reference, :subtree_stop, :result, :ok, System.monotonic_time()})
    send(worker, {self(), reference, :finish})

    assert %{
             stage: :subtree_stop,
             worker: %{pid: ^worker, result: false, finish_sent: false},
             root_removal_attempted: false
           } = :sys.get_state(owner).abort

    assert Process.alive?(worker)
    assert Process.alive?(root_pid)
    assert File.dir?(root)
    refute_receive {^stop_ref, _}, 0

    assert :ok = :sys.suspend(owner)
    send(worker, {test, :release})
    assert_receive {:DOWN, ^root_monitor, :process, ^root_pid, _}, 1_000
    assert waiting_for_finish?(worker)
    assert true = :erlang.suspend_process(worker)
    assert :ok = :sys.resume(owner)

    assert %{
             stage: :subtree_stop,
             worker: %{pid: ^worker, result: true, finish_sent: true},
             root_removal_attempted: false
           } = :sys.get_state(owner).abort

    assert Process.alive?(worker)
    assert File.dir?(root)
    refute_receive {^stop_ref, _}, 0

    assert true = :erlang.resume_process(worker)
    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, :normal}, 1_000
    send(holder_suspension, {self(), :release})
    assert_receive {^holder_suspension, :released}, 1_000
    assert :ok = Task.await(stop, 7_000)
    assert :atomics.get(cell, 1) == 2
    refute File.exists?(root)
  end

  test "a raised subtree-stop operation retains the root despite root DOWN", %{tmp: tmp} do
    subtree_stop = fn root ->
      Process.exit(root, :shutdown)
      raise "subtree stop failed"
    end

    session = start_session(tmp, successful_drain(), subtree_stop: subtree_stop)
    {:loopex_ephemeral_session, owner, cell} = session
    %{startup: %{root: root_pid, owned_root: %{path: root}}} = :sys.get_state(owner)
    root_monitor = Process.monitor(root_pid)

    assert {:error,
            {:cleanup_unproved,
             %{pending: [:session_subtree], root: ^root, root_ownership: :owned}}} =
             Ephemeral.stop_session(session)

    assert_receive {:DOWN, ^root_monitor, :process, ^root_pid, _}, 1_000
    assert :atomics.get(cell, 1) == 3
    assert File.dir?(root)
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

    configuration =
      %{
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
        test_seams:
          Map.merge(
            %{
              temp_root: temp_root,
              group_drain: drain,
              group_attest: fn _executor, _instance, _nonce, _deadline -> :ok end
            },
            Map.new(Keyword.take(options, [:subtree_stop, :phase_started]))
          )
      }
      |> LoopexComposition.PreparedSessionFixture.capture()

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

  defp waiting_for_finish?(worker) do
    Enum.reduce_while(1..100, false, fn _, _ ->
      if Process.info(worker, :status) == {:status, :waiting} do
        {:halt, true}
      else
        Process.sleep(1)
        {:cont, false}
      end
    end)
  end

  # Concept: suspend the owner at a phase start, ahead of that phase's deadlines.
  # Technical depth: the owner is held before it launches the phase worker and
  # arms its cutoff and slot timers; this sys suspend request is queued before
  # the owner continues, so it is handled before either timer message. The
  # suspended owner still answers sys requests, which returns the launched worker.
  defp suspend_at_phase(owner, phase) do
    assert_receive {:abort_phase_held, ^phase, ^owner, reference}, 3_000
    suspended = make_ref()
    send(owner, {:system, {self(), suspended}, :suspend})
    send(owner, {reference, :continue})
    assert_receive {^suspended, :ok}, 3_000
    :sys.get_state(owner).abort
  end

  defp suspend_runtime(runtime_supervisor), do: suspend_process(runtime_supervisor)

  defp suspend_process(target) do
    test = self()

    # Concept: hold the real runtime stop worker while forged completions arrive.
    # Technical depth: Supervisor.stop still terminates a :sys-suspended supervisor;
    # the process that suspends it must also resume it, including after test failure.
    suspension =
      spawn(fn ->
        test_monitor = Process.monitor(test)
        true = :erlang.suspend_process(target)
        send(test, {self(), :suspended})

        receive do
          {requester, :release} ->
            if Process.alive?(target), do: :erlang.resume_process(target)
            send(requester, {self(), :released})

          {:DOWN, ^test_monitor, :process, ^test, _} ->
            if Process.alive?(target), do: :erlang.resume_process(target)
        end
      end)

    assert_receive {^suspension, :suspended}, 1_000
    suspension
  end
end
