Code.require_file("support/m1_runtime_helper.exs", __DIR__)
Code.require_file("support/configured_genesis_helper.exs", __DIR__)
Code.require_file("support/m5_query_fault_store.exs", __DIR__)

defmodule Loopex.CreationStartupStatusTest do
  use ExUnit.Case, async: false

  alias Loopex.ConfiguredGenesisFixture
  alias Loopex.M1RuntimeTestStore, as: Fixture
  alias Loopex.Runtime
  alias Loopex.Runtime.Control
  alias Loopex.Store

  test "held actual startup read answers a closed snapshot without work or activation" do
    {pid, store} = fixture()
    :ok = Fixture.hold_next_creation_recovery(pid, self())
    runtime = runtime(store)
    assert_receive {:creation_read_held, waiter, reader, %{command_id: nil}}, 1_000
    on_exit(fn -> Fixture.release(waiter) end)
    {:ok, children} = Runtime.children(runtime)
    original = :sys.get_state(children.control)
    assert original.creation.action.worker == reader
    assert original.creation.cutoff == original.creation_startup.startup_deadline_ms
    assert original.creation.invocation == original.creation_startup.invocation
    original_joins = monitor_startup_action(original.creation.action)
    before_store = Fixture.inspect_state(pid)
    workers = Task.Supervisor.children(children.workers)

    for _ <- 1..8 do
      assert {:ok, snapshot} = Loopex.creation_startup_status(runtime, 100)
      assert_snapshot(snapshot, :starting, original.creation_startup)
    end

    assert :sys.get_state(children.control).creation == original.creation
    assert Fixture.inspect_state(pid).creation_calls == before_store.creation_calls
    assert Fixture.inspect_state(pid).creation_queries == before_store.creation_queries
    assert Task.Supervisor.children(children.workers) == workers
    assert DynamicSupervisor.which_children(children.sessions) == []
    assert {:error, :store_unavailable} = Runtime.create_session(runtime, "no-create", %{})
    assert Fixture.inspect_state(pid).creation_calls == []
    Fixture.release(waiter)
    assert_startup_action_joins(original_joins)
    snapshot = await_status(runtime, :ready)
    assert_snapshot(snapshot, :ready, original.creation_startup)
    assert :sys.get_state(children.control).creation == nil
  end

  test "held actual claim and close retain the original startup identity through retirement" do
    {pid, store} = fixture()
    seed_reservation(store)

    :ok =
      Fixture.hold_next_transition_before_linearization(
        pid,
        :runtime_control_claim_creation_domain,
        self()
      )

    :ok =
      Fixture.hold_next_transition_before_linearization(
        pid,
        :runtime_control_close_creation_reservation,
        self()
      )

    runtime = runtime(store)

    assert_receive {:record_held_before_linearization, claim_waiter, ^pid,
                    :runtime_control_claim_creation_domain, _claim},
                   1_000

    on_exit(fn -> Fixture.release(claim_waiter) end)
    assert {:ok, initial} = Runtime.creation_startup_status(runtime)
    assert initial.state == :starting
    Fixture.release(claim_waiter)

    assert_receive {:record_held_before_linearization, close_waiter, ^pid,
                    :runtime_control_close_creation_reservation, _close},
                   1_000

    on_exit(fn -> Fixture.release(close_waiter) end)
    assert {:ok, ^initial} = Runtime.creation_startup_status(runtime, 100)
    {:ok, %{control: control, sessions: sessions}} = Runtime.children(runtime)
    original = :sys.get_state(control)
    original_joins = monitor_startup_action(original.creation.action)
    assert original.creation.phase == :close
    assert original.creation.cutoff == initial.startup_deadline_ms
    calls = Fixture.inspect_state(pid).creation_calls
    assert {:ok, ^initial} = Loopex.creation_startup_status(runtime)
    assert Fixture.inspect_state(pid).creation_calls == calls
    assert DynamicSupervisor.which_children(sessions) == []
    Fixture.release(close_waiter)
    assert_startup_action_joins(original_joins)
    assert_snapshot(await_status(runtime, :ready), :ready, initial)
    assert :sys.get_state(control).creation == nil
    assert Fixture.inspect_state(pid).sessions == %{}
  end

  test "actual Control initialization captures its cutoff before delayed startup intake" do
    {_root_store_pid, root_store} = fixture()
    runtime = runtime(root_store)
    await_status(runtime, :ready)
    {pid, store} = fixture()
    :ok = Fixture.hold_next_creation_recovery(pid, self())

    {:ok, %{start: {Control, :start_link, [options]}}} =
      :supervisor.get_childspec(runtime.supervisor, Control)

    options = Keyword.put(options, :store, store)

    {:ok, delayed_supervisor} =
      Supervisor.start_link(
        [
          %{id: Control, start: {__MODULE__, :start_delayed_control, [options, self()]}}
        ],
        strategy: :one_for_one
      )

    [{Control, delayed, :worker, _}] = Supervisor.which_children(delayed_supervisor)

    on_exit(fn ->
      if Process.alive?(delayed) do
        send(delayed, :enter_loop)
        Supervisor.stop(delayed_supervisor)
      end
    end)

    delayed_monitor = Process.monitor(delayed)
    assert_receive {:initialized, ^delayed, capture, before_init, after_init}, 1_000
    assert capture.startup_deadline_ms >= before_init + 60_000
    assert capture.startup_deadline_ms <= after_init + 60_000
    assert {:messages, [:creation_startup]} = Process.info(delayed, :messages)
    wait_until(after_init + 20)
    assert Fixture.inspect_state(pid).creation_queries == []
    send(delayed, :enter_loop)
    assert_receive {:creation_read_held, waiter, _, _}, 1_000
    on_exit(fn -> Fixture.release(waiter) end)
    entry = :sys.get_state(delayed).creation
    assert entry.cutoff == capture.startup_deadline_ms
    assert entry.invocation == capture.invocation
    assert Process.read_timer(entry.timer) <= capture.startup_deadline_ms - after_init - 20

    assert {:ok, snapshot} =
             GenServer.call(delayed, {:creation_startup_status, runtime.token}, 100)

    assert_snapshot(snapshot, :starting, capture)
    Fixture.release(waiter)
    await(fn -> :sys.get_state(delayed).creation == nil end)

    assert {:ok, snapshot} =
             GenServer.call(delayed, {:creation_startup_status, runtime.token}, 100)

    assert_snapshot(snapshot, :ready, capture)
    :ok = Supervisor.stop(delayed_supervisor)
    assert_receive {:DOWN, ^delayed_monitor, :process, ^delayed, :shutdown}, 1_000
  end

  @doc false
  def start_delayed_control(options, observer),
    do: :proc_lib.start_link(__MODULE__, :init_delayed_control, [options, observer])

  @doc false
  def init_delayed_control(options, observer) do
    before_init = System.monotonic_time(:millisecond)
    {:ok, state} = Control.init(options)
    after_init = System.monotonic_time(:millisecond)
    :proc_lib.init_ack({:ok, self()})
    send(observer, {:initialized, self(), state.creation_startup, before_init, after_init})

    receive do
      :enter_loop -> :gen_server.enter_loop(Control, [], state)
    end
  end

  test "invalid timeout is rejected before suspended root or Control receives any read" do
    {_pid, store} = fixture()
    runtime = runtime(store)
    await_status(runtime, :ready)
    {:ok, %{control: control}} = Runtime.children(runtime)
    :ok = :sys.suspend(runtime.supervisor)
    :ok = :sys.suspend(control)

    on_exit(fn ->
      resume(control)
      resume(runtime.supervisor)
    end)

    before_root = Process.info(runtime.supervisor, :messages)
    before_control = Process.info(control, :messages)

    for timeout <- [0, -1, 1_001, :infinity, nil, 1.0, "1"] do
      assert {:error, :invalid_status_timeout} = Runtime.creation_startup_status(runtime, timeout)
      assert {:error, :invalid_status_timeout} = Loopex.creation_startup_status(nil, timeout)
    end

    assert Process.info(runtime.supervisor, :messages) == before_root
    assert Process.info(control, :messages) == before_control
    resume(control)
    resume(runtime.supervisor)
  end

  test "suspended root and suspended original Control consume one finite read allowance" do
    {_pid, store} = fixture()
    runtime = runtime(store)
    original = await_status(runtime, :ready)
    {:ok, %{control: control}} = Runtime.children(runtime)

    for actor <- [runtime.supervisor, control] do
      :ok = :sys.suspend(actor)
      on_exit(fn -> resume(actor) end)
      assert {:error, :runtime_unavailable} = Runtime.creation_startup_status(runtime, 20)
      resume(actor)
      assert {:ok, ^original} = Runtime.creation_startup_status(runtime)
    end
  end

  test "wrong references and tokens fail while two original startups remain isolated" do
    {pid_a, store_a} = fixture()
    {_pid_b, store_b} = fixture()
    :ok = Fixture.hold_next_creation_recovery(pid_a, self())
    a = runtime(store_a)
    assert_receive {:creation_read_held, waiter, _, _}, 1_000
    on_exit(fn -> Fixture.release(waiter) end)
    b = runtime(store_b)
    ready = await_status(b, :ready)
    assert {:ok, starting} = Runtime.creation_startup_status(a)
    assert starting.state == :starting
    refute starting.startup_id == ready.startup_id

    for invalid <- [
          nil,
          %{},
          %{a | supervisor: nil},
          %{a | token: nil},
          %{a | token: make_ref()},
          %{a | token: b.token}
        ] do
      assert {:error, :runtime_unavailable} = Runtime.creation_startup_status(invalid, 100)
    end

    assert {:ok, ^ready} = Runtime.creation_startup_status(b)
    Fixture.release(waiter)
    assert_snapshot(await_status(a, :ready), :ready, starting)
  end

  test "root resolution and Control observation share the original timeout without renewal" do
    {_pid, store} = fixture()
    runtime = runtime(store)
    original = await_status(runtime, :ready)
    {:ok, %{control: control}} = Runtime.children(runtime)
    :ok = :sys.suspend(runtime.supervisor)
    :ok = :sys.suspend(control)

    on_exit(fn ->
      resume(control)
      resume(runtime.supervisor)
    end)

    parent = self()
    timeout_ms = 500
    observation_scheduling_grace_ms = 100

    {caller, monitor} =
      spawn_monitor(fn ->
        started = System.monotonic_time(:millisecond)
        send(parent, {:status_started, self(), started})
        result = Runtime.creation_startup_status(runtime, timeout_ms)
        elapsed = System.monotonic_time(:millisecond) - started
        send(parent, {:bounded_status, self(), result, elapsed})
      end)

    on_exit(fn -> if Process.alive?(caller), do: Process.exit(caller, :kill) end)
    assert_receive {:status_started, ^caller, started}, 1_000

    await(fn ->
      Enum.any?(elem(Process.info(runtime.supervisor, :messages), 1), fn
        {:"$gen_call", _, :which_children} -> true
        _ -> false
      end)
    end)

    wait_until(started + 250)
    resume(runtime.supervisor)
    assert_receive {:bounded_status, ^caller, {:error, :runtime_unavailable}, elapsed}, 1_000
    assert elapsed >= timeout_ms
    assert elapsed <= timeout_ms + observation_scheduling_grace_ms
    assert_receive {:DOWN, ^monitor, :process, ^caller, :normal}, 1_000
    resume(control)
    assert {:ok, ^original} = Runtime.creation_startup_status(runtime)
  end

  test "a real reply queued while its caller is suspended cannot establish a late observation" do
    {_pid, store} = fixture()
    runtime = runtime(store)
    original = await_status(runtime, :ready)
    {:ok, %{control: control}} = Runtime.children(runtime)
    :ok = :sys.suspend(control)
    on_exit(fn -> resume(control) end)
    parent = self()

    {caller, caller_monitor} =
      spawn_monitor(fn ->
        send(parent, {:late_status, self(), Runtime.creation_startup_status(runtime, 100)})
      end)

    await(fn ->
      Enum.any?(elem(Process.info(control, :messages), 1), fn
        {:"$gen_call", _, {:creation_startup_status, _}} -> true
        _ -> false
      end)
    end)

    :erlang.suspend_process(caller)
    on_exit(fn -> if Process.alive?(caller), do: Process.exit(caller, :kill) end)
    resume(control)

    await(fn ->
      Enum.any?(elem(Process.info(caller, :messages), 1), fn
        {_tag, {:ok, %{startup_id: id}}} -> id == original.startup_id
        _ -> false
      end)
    end)

    wait_until(System.monotonic_time(:millisecond) + 101)
    :erlang.resume_process(caller)
    assert_receive {:late_status, ^caller, {:error, :runtime_unavailable}}, 1_000
    assert_receive {:DOWN, ^caller_monitor, :process, ^caller, :normal}, 1_000
    assert {:ok, ^original} = Runtime.creation_startup_status(runtime)
  end

  test "missing capture and missing recovery capability never default to ready" do
    {:ok, store} = Store.new(Loopex.M5QueryFaultStore, :absent)
    runtime = runtime(store)
    assert %{state: :unavailable} = await_status(runtime, :unavailable)
    {:ok, %{control: control}} = Runtime.children(runtime)
    original = :sys.get_state(control)
    :sys.replace_state(control, &Map.delete(&1, :creation_startup))
    assert {:error, :runtime_unavailable} = Runtime.creation_startup_status(runtime)
    :sys.replace_state(control, fn _ -> original end)
    assert {:ok, %{state: :unavailable}} = Runtime.creation_startup_status(runtime)
  end

  test "original Control loss fails its outstanding read and replacement has a distinct capture" do
    {_pid, store} = fixture()
    runtime = runtime(store)
    initial = await_status(runtime, :ready)
    {:ok, %{control: control}} = Runtime.children(runtime)
    :ok = :sys.suspend(control)
    on_exit(fn -> resume(control) end)
    parent = self()

    {observer, observer_monitor} =
      spawn_monitor(fn ->
        send(parent, {:status_answer, self(), Runtime.creation_startup_status(runtime)})
      end)

    on_exit(fn -> if Process.alive?(observer), do: Process.exit(observer, :kill) end)

    await(fn ->
      Enum.any?(elem(Process.info(control, :messages), 1), fn
        {:"$gen_call", _, {:creation_startup_status, _}} -> true
        _ -> false
      end)
    end)

    monitor = Process.monitor(control)
    Process.exit(control, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^control, :killed}, 1_000
    assert_receive {:status_answer, ^observer, {:error, :runtime_unavailable}}, 1_000
    assert_receive {:DOWN, ^observer_monitor, :process, ^observer, :normal}, 1_000
    replacement = await_status(runtime, :ready)
    refute replacement.startup_id == initial.startup_id
    assert byte_size(replacement.startup_id) == 32
  end

  test "authored busy and failure preserve the original ready snapshot" do
    {pid, store} = fixture()
    runtime = runtime(store)
    original = await_status(runtime, :ready)

    :ok =
      Fixture.hold_next_transition_before_linearization(
        pid,
        :runtime_control_reserve_creation,
        self()
      )

    parent = self()

    {caller, caller_monitor} =
      spawn_monitor(fn ->
        send(
          parent,
          {:create_answer, self(), Runtime.create_session(runtime, "authored", %{"version" => 1})}
        )
      end)

    on_exit(fn -> if Process.alive?(caller), do: Process.exit(caller, :kill) end)

    assert_receive {:record_held_before_linearization, waiter, ^pid,
                    :runtime_control_reserve_creation, _},
                   1_000

    on_exit(fn -> Fixture.release(waiter) end)
    assert {:ok, ^original} = Runtime.creation_startup_status(runtime)

    assert {:error, :creation_in_progress} =
             Runtime.create_session(runtime, "overlap", %{"version" => 1})

    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^caller_monitor, :process, ^caller, :killed}, 1_000
    {:ok, %{control: control}} = Runtime.children(runtime)
    await(fn -> :sys.get_state(control).creation == nil end)
    assert :sys.get_state(control).creation_status == :unavailable
    assert {:ok, ^original} = Runtime.creation_startup_status(runtime)
    Fixture.release(waiter)
  end

  test "stop and quiesce reduce availability while a real startup read remains held" do
    for operation <- [:stop, :quiesce] do
      {pid, store} = fixture()
      :ok = Fixture.hold_next_creation_recovery(pid, self())
      runtime = runtime(store)
      assert_receive {:creation_read_held, waiter, _, _}, 1_000
      on_exit(fn -> Fixture.release(waiter) end)
      assert {:ok, initial} = Runtime.creation_startup_status(runtime)
      {:ok, %{control: control}} = Runtime.children(runtime)

      result =
        case operation do
          :stop ->
            Control.stop_creation(control, runtime.token)

          :quiesce ->
            assert {:ok, []} = Control.begin_quiesce(control, runtime.token, "drain", 1_000)
            :ok
        end

      assert :ok = result

      assert_snapshot(elem(Runtime.creation_startup_status(runtime), 1), :unavailable, initial)
      Fixture.release(waiter)
    end
  end

  test "safe runtime stop joins original held startup actors and the stopped root is unavailable" do
    {pid, store} = fixture()
    :ok = Fixture.hold_next_creation_recovery(pid, self())
    runtime = runtime(store)
    assert_receive {:creation_read_held, waiter, _, _}, 1_000
    on_exit(fn -> Fixture.release(waiter) end)
    {:ok, %{control: control}} = Runtime.children(runtime)
    entry = :sys.get_state(control).creation

    monitors =
      for actor <- [
            entry.action.pid,
            entry.action.group,
            entry.action.worker,
            control,
            runtime.supervisor
          ],
          do: {actor, Process.monitor(actor)}

    assert {:ok, %{state: :starting}} = Runtime.creation_startup_status(runtime)
    assert :ok = Runtime.stop(runtime)

    for {actor, monitor} <- monitors,
        do: assert_receive({:DOWN, ^monitor, :process, ^actor, _}, 1_000)

    assert {:error, :runtime_unavailable} = Runtime.creation_startup_status(runtime)
    assert Fixture.inspect_state(pid).creation_calls == []
    Fixture.release(waiter)
  end

  @tag :long_bound
  @tag timeout: 75_000
  test "timely startup proof stays ready after the original real sixty second cutoff" do
    {_pid, store} = fixture()
    runtime = runtime(store)
    original = await_status(runtime, :ready)
    wait_until(original.startup_deadline_ms + 1)
    assert {:ok, ^original} = Runtime.creation_startup_status(runtime)
    assert {:ok, _session} = Runtime.create_session(runtime, "after-cutoff", %{})
  end

  @tag :long_bound
  @tag timeout: 75_000
  test "queued status and late adoption of original join facts cannot prove startup after its real cutoff" do
    {pid, store} = fixture()
    seed_reservation(store)
    :ok = Fixture.hold_next_creation_recovery(pid, self())
    runtime = runtime(store)
    assert_receive {:creation_read_held, first_waiter, _, _}, 1_000
    assert {:ok, original} = Runtime.creation_startup_status(runtime)

    :ok =
      Fixture.hold_next_transition_before_linearization(
        pid,
        :runtime_control_close_creation_reservation,
        self()
      )

    Fixture.release(first_waiter)

    assert_receive {:record_held_before_linearization, waiter, ^pid,
                    :runtime_control_close_creation_reservation, _},
                   1_000

    on_exit(fn -> Fixture.release(waiter) end)
    {:ok, %{control: control}} = Runtime.children(runtime)
    entry = :sys.get_state(control).creation
    wait_until(original.startup_deadline_ms - 500)
    :ok = :sys.suspend(control)
    on_exit(fn -> resume(control) end)
    parent = self()

    {observer, observer_monitor} =
      spawn_monitor(fn ->
        send(parent, {:expired_status, self(), Runtime.creation_startup_status(runtime)})
      end)

    on_exit(fn -> if Process.alive?(observer), do: Process.exit(observer, :kill) end)

    await(fn ->
      Enum.any?(elem(Process.info(control, :messages), 1), fn
        {:"$gen_call", _, {:creation_startup_status, _}} -> true
        _ -> false
      end)
    end)

    monitors =
      for actor <- [entry.action.pid, entry.action.group, entry.action.worker],
          do: {actor, Process.monitor(actor)}

    Fixture.release(waiter)

    for {actor, monitor} <- monitors,
        do: assert_receive({:DOWN, ^monitor, :process, ^actor, _}, 1_000)

    wait_until(original.startup_deadline_ms + 1)
    resume(control)
    assert_receive {:expired_status, ^observer, {:ok, snapshot}}, 1_000
    assert_receive {:DOWN, ^observer_monitor, :process, ^observer, :normal}, 1_000
    assert_snapshot(snapshot, :unavailable, original)
    assert_snapshot(await_status(runtime, :unavailable), :unavailable, original)
    await(fn -> :sys.get_state(control).creation == nil end)
    assert :sys.get_state(control).creation_status == :unavailable
    assert {:error, :store_unavailable} = Runtime.create_session(runtime, "late", %{})
    assert Fixture.inspect_state(pid).sessions == %{}
  end

  # Concept: physical normal retirement after cutoff cannot establish startup readiness.
  # Technical depth: only the actual final-read guardian is suspended across the
  # original work instant. Control retains its real cleanup; the genuine Store
  # reply and all three original normal DOWN signals occur after that instant.
  @tag :long_bound
  @tag timeout: 75_000
  test "original startup actors physically join normally after cutoff without becoming ready" do
    {pid, store} = fixture()
    seed_reservation(store)

    :ok =
      Fixture.hold_next_transition_before_linearization(
        pid,
        :runtime_control_close_creation_reservation,
        self()
      )

    runtime = runtime(store)

    assert_receive {:record_held_before_linearization, close_waiter, ^pid,
                    :runtime_control_close_creation_reservation, _close},
                   1_000

    on_exit(fn -> Fixture.release(close_waiter) end)
    {:ok, %{control: control, sessions: sessions, workers: workers}} = Runtime.children(runtime)
    close_entry = :sys.get_state(control).creation
    assert close_entry.phase == :close
    close_joins = monitor_startup_action(close_entry.action)
    close_waiter_monitor = Process.monitor(close_waiter)
    assert {:ok, original} = Runtime.creation_startup_status(runtime)
    assert original.state == :starting
    assert close_entry.cutoff == original.startup_deadline_ms
    :ok = Fixture.hold_next_creation_recovery(pid, self())
    Fixture.release(close_waiter)
    assert_receive {:DOWN, ^close_waiter_monitor, :process, ^close_waiter, :normal}, 1_000
    assert_startup_action_joins(close_joins)

    assert_receive {:creation_read_held, read_waiter, reader, %{command_id: nil}}, 1_000
    on_exit(fn -> Fixture.release(read_waiter) end)
    original_control = :sys.get_state(control)
    entry = original_control.creation
    assert entry.phase == :post_terminal
    assert entry.action.worker == reader
    assert entry.cutoff == original.startup_deadline_ms
    assert entry.invocation == original_control.creation_startup.invocation
    assert entry.cleanup == nil and not entry.stopped
    assert {:ok, snapshot} = Runtime.creation_startup_status(runtime)
    assert_snapshot(snapshot, :starting, original)
    guardian = entry.action.pid
    group = entry.action.group
    worker = entry.action.worker
    invocation = entry.invocation
    permit = entry.action.permit
    incarnation = original_control.creation_incarnation
    original_joins = monitor_startup_action(entry.action)
    read_waiter_monitor = Process.monitor(read_waiter)
    before_store = Fixture.inspect_state(pid)
    1 = :erlang.trace(control, true, [:receive])
    on_exit(fn -> if Process.alive?(control), do: :erlang.trace(control, false, [:receive]) end)

    wait_until(original.startup_deadline_ms - 500)
    assert System.monotonic_time(:millisecond) < original.startup_deadline_ms
    :erlang.suspend_process(guardian)

    on_exit(fn ->
      try do
        if Process.alive?(guardian), do: :erlang.resume_process(guardian)
      catch
        :error, :badarg -> :ok
      end

      Fixture.release(read_waiter)
    end)

    wait_until(original.startup_deadline_ms + 1)

    for {actor, monitor} <- original_joins do
      assert Process.alive?(actor)
      refute_received {:DOWN, ^monitor, :process, ^actor, _}
    end

    assert System.monotonic_time(:millisecond) > original.startup_deadline_ms
    assert Process.alive?(control)
    assert {:ok, snapshot} = Runtime.creation_startup_status(runtime)
    assert_snapshot(snapshot, :unavailable, original)
    await(fn -> :sys.get_state(control).creation.stopped end)
    stopped = :sys.get_state(control).creation
    assert stopped.invocation == invocation and stopped.cutoff == entry.cutoff
    assert stopped.action == entry.action
    cleanup = stopped.cleanup
    assert original_control.cleanup_grace_ms == 5_000
    assert cleanup.observe - cleanup.cooperative == 5_000
    assert System.monotonic_time(:millisecond) < cleanup.cooperative
    {:messages, held_messages} = Process.info(guardian, :messages)

    assert Enum.any?(held_messages, fn
             {:creation_retire, ^control, ^incarnation, ^invocation, ^permit, ^cleanup} -> true
             _ -> false
           end)

    Fixture.release(read_waiter)
    assert_receive {:DOWN, ^read_waiter_monitor, :process, ^read_waiter, :normal}, 1_000
    {^worker, worker_monitor} = List.keyfind(original_joins, worker, 0)
    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, :normal}, 1_000
    assert System.monotonic_time(:millisecond) > original.startup_deadline_ms
    assert Process.alive?(guardian) and Process.alive?(group)
    {:messages, held_messages} = Process.info(guardian, :messages)

    assert Enum.any?(held_messages, fn
             {:creation_outcome, ^worker, ^permit, {:ok, %{command: nil, head: head}}} ->
               head == entry.head and is_nil(head.active_command_id)

             _ -> false
           end)

    :erlang.resume_process(guardian)

    for {actor, monitor} <- original_joins, actor != worker do
      assert_receive {:DOWN, ^monitor, :process, ^actor, :normal}, 1_000
      assert System.monotonic_time(:millisecond) > original.startup_deadline_ms
      assert System.monotonic_time(:millisecond) < cleanup.observe
    end

    assert_receive {:trace, ^control, :receive,
                    {:creation_carrier_joined, ^incarnation, ^invocation, ^permit, ^guardian,
                     ^group, ^worker, {:ok, %{command: nil}}}},
                   1_000

    await(fn -> :sys.get_state(control).creation == nil end)
    final_control = :sys.get_state(control)
    assert final_control.creation_status == :unavailable
    assert final_control.creation_incarnation == incarnation
    assert final_control.creation_startup.invocation == invocation
    assert {:ok, %{control: ^control}} = Runtime.children(runtime)
    assert {:ok, snapshot} = Runtime.creation_startup_status(runtime)
    assert_snapshot(snapshot, :unavailable, original)
    assert {:error, :store_unavailable} = Runtime.create_session(runtime, "late-normal", %{})
    after_store = Fixture.inspect_state(pid)
    assert after_store.creation_calls == before_store.creation_calls
    assert after_store.creation_queries == before_store.creation_queries
    assert after_store.sessions == %{}
    assert Task.Supervisor.children(workers) == []
    assert DynamicSupervisor.which_children(sessions) == []
    :erlang.trace(control, false, [:receive])
  end

  # Concept: positive readiness follows independently observed original actors.
  # Technical depth: capture exact identities before releasing the held callback;
  # consume only their own monitors before accepting the ready snapshot.
  defp monitor_startup_action(action) do
    for actor <- [action.pid, action.group, action.worker] do
      {actor, Process.monitor(actor)}
    end
  end

  defp assert_startup_action_joins(monitors) do
    for {actor, monitor} <- monitors do
      assert_receive {:DOWN, ^monitor, :process, ^actor, _reason}, 1_000
    end
  end

  defp fixture do
    {pid, store} = Fixture.start_store()
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    {pid, store}
  end

  defp runtime(store) do
    before_start = System.monotonic_time(:millisecond)

    {:ok, runtime} =
      Loopex.start_link(
        runtime_id: "runtime",
        store: store,
        context_token_budget: 8_192,
        cleanup_grace_ms: 5_000,
        session_creation_defaults: Map.drop(genesis(), [:kind, "options"])
      )

    after_start = System.monotonic_time(:millisecond)
    on_exit(fn -> if Process.alive?(runtime.supervisor), do: Runtime.stop(runtime) end)
    assert {:ok, capture} = Runtime.creation_startup_status(runtime)
    assert capture.startup_deadline_ms >= before_start + 60_000
    assert capture.startup_deadline_ms <= after_start + 60_000
    runtime
  end

  defp genesis, do: ConfiguredGenesisFixture.genesis([])

  defp seed_reservation(store) do
    selection = String.duplicate("a", 64)
    {:ok, claim} = Store.claim_creation_domain("runtime", 0, selection)
    assert {:committed, _, _} = Store.transact(store, claim)
    {:ok, reserve} = Store.reserve_creation("runtime", "retained", 1, selection, 0, genesis())
    assert {:committed, _, _} = Store.transact(store, reserve)
  end

  defp assert_snapshot(snapshot, state, original) do
    assert Map.keys(snapshot) |> Enum.sort() == [:startup_deadline_ms, :startup_id, :state]
    assert snapshot.state == state
    assert byte_size(snapshot.startup_id) == 32
    assert is_integer(snapshot.startup_deadline_ms)
    assert snapshot.startup_id == original.startup_id
    assert snapshot.startup_deadline_ms == original.startup_deadline_ms
  end

  defp await_status(runtime, desired) do
    await_value(fn ->
      case Runtime.creation_startup_status(runtime) do
        {:ok, %{state: ^desired} = snapshot} -> snapshot
        _ -> nil
      end
    end)
  end

  defp await(check), do: await_value(fn -> if check.(), do: true end)
  defp await_value(check), do: await_value(check, System.monotonic_time(:millisecond) + 1_000)

  defp await_value(check, cutoff) do
    case check.() do
      nil ->
        assert System.monotonic_time(:millisecond) < cutoff

        receive do
        after
          1 -> :ok
        end

        await_value(check, cutoff)

      value ->
        value
    end
  end

  defp wait_until(cutoff) do
    remaining = cutoff - System.monotonic_time(:millisecond)

    if remaining > 0 do
      receive do
      after
        remaining -> :ok
      end

      wait_until(cutoff)
    end
  end

  defp resume(actor) do
    try do
      :sys.resume(actor)
    catch
      :exit, _ -> :ok
    end
  end
end
