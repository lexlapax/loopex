defmodule LoopexDaemon.AdmissionRelayTest do
  use ExUnit.Case, async: false

  @moduletag capture_log: true

  import ExUnit.CaptureLog

  alias LoopexDaemon.AdmissionRelay

  test "connection authentication and monotonic origins enforce the 32-row bound" do
    relay = start_relay()
    incarnation = incarnation()
    connection = start_connection(relay, incarnation)
    first = {incarnation, 0, 1}

    assert {:error, :connection_unavailable} =
             AdmissionRelay.open_permit(relay, first, :daemon_status)

    assert {:ok, ^first} =
             invoke(connection, fn ->
               AdmissionRelay.open_permit(relay, first, :daemon_status)
             end)

    assert {:ok, ^first} =
             invoke(connection, fn ->
               AdmissionRelay.open_permit(relay, first, :daemon_status)
             end)

    assert {:error, :permit_conflict} =
             invoke(connection, fn ->
               AdmissionRelay.open_permit(relay, first, :session_list)
             end)

    assert {:error, :invalid_origin} =
             invoke(connection, fn ->
               AdmissionRelay.open_permit(
                 relay,
                 {incarnation, 0, 2},
                 :session_inspect
               )
             end)

    assert {:error, :invalid_origin} =
             invoke(connection, fn ->
               AdmissionRelay.open_permit(
                 relay,
                 {incarnation, 0, 2},
                 :daemon_status,
                 "session"
               )
             end)

    for slot <- 1..31 do
      origin = {incarnation, slot, 1}

      assert {:ok, ^origin} =
               invoke(connection, fn ->
                 AdmissionRelay.open_permit(relay, origin, :daemon_status)
               end)
    end

    assert %{permits: 32, pending: 32, executing: 0, origin_limit: 16_384} =
             AdmissionRelay.status(relay)

    assert {:error, :capacity_exceeded} =
             invoke(connection, fn ->
               AdmissionRelay.open_permit(relay, {incarnation, 0, 2}, :daemon_status)
             end)

    assert {:error, :invalid_origin} =
             invoke(connection, fn ->
               AdmissionRelay.open_permit(relay, {incarnation, 0, 0}, :daemon_status)
             end)

    monitor = Process.monitor(connection)
    Process.exit(connection, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^connection, :killed}, 500
    assert_receive {:relay_connection_retired, ^relay, ^incarnation}, 500

    eventually(fn ->
      AdmissionRelay.status(relay) == %{
        phase: :serving,
        connections: 0,
        permits: 0,
        tickets: 0,
        pending: 0,
        queued: 0,
        ticketed: 0,
        waiting: 0,
        executing: 0,
        settling: 0,
        connection_limit: 512,
        origin_limit: 16_384,
        admission_deadline_set: false,
        lease_owners: 0,
        retiring_lease_owners: 0,
        owner_losses: 0
      }
    end)
  end

  test "a worker dispatches only after bind and its real result wins once" do
    relay = start_relay()
    incarnation = incarnation()
    connection = start_connection(relay, incarnation)
    origin = {incarnation, 0, 1}

    assert {:ok, ^origin} =
             invoke(connection, fn ->
               AdmissionRelay.open_permit(relay, origin, :daemon_status)
             end)

    {worker, worker_incarnation} = start_worker(relay, connection, origin)
    worker_monitor = Process.monitor(worker)

    refute_receive {:worker_go, ^worker, ^origin}, 30

    assert :ok =
             invoke(connection, fn ->
               AdmissionRelay.bind_worker(relay, origin, worker, worker_incarnation)
             end)

    assert_receive {:worker_go, ^worker, ^origin}, 500

    assert %{permits: 1, pending: 0, executing: 1, settling: 0} =
             AdmissionRelay.status(relay)

    canary = "relay-result-canary-9c4a"

    result = %{
      "type" => "result",
      "method" => "daemon.status",
      "request_id" => "r1",
      "result" => %{"marker" => canary}
    }

    log =
      capture_log(fn ->
        send(worker, {:complete, result})
        assert_receive {:worker_complete, ^worker, :ok}, 500

        assert_receive {:connection_message, ^connection,
                        {:relay_permit_result, ^origin, ^result}},
                       500

        assert_receive {:DOWN, ^worker_monitor, :process, ^worker, :normal}, 500
        eventually(fn -> AdmissionRelay.status(relay).permits == 0 end)
      end)

    refute log =~ canary
    stop_connection(connection, relay, incarnation)
  end

  test "worker loss returns one fixed failure and frees its origin" do
    relay = start_relay()
    incarnation = incarnation()
    connection = start_connection(relay, incarnation)
    origin = {incarnation, 3, 1}

    assert {:ok, ^origin} =
             invoke(connection, fn ->
               AdmissionRelay.open_permit(relay, origin, :session_inspect, "session")
             end)

    {worker, worker_incarnation} = start_worker(relay, connection, origin)

    assert :ok =
             invoke(connection, fn ->
               AdmissionRelay.bind_worker(relay, origin, worker, worker_incarnation)
             end)

    assert_receive {:worker_go, ^worker, ^origin}, 500
    Process.exit(worker, :kill)

    assert_receive {:connection_message, ^connection,
                    {:relay_permit_failed, ^origin, :worker_lost}},
                   500

    eventually(fn -> AdmissionRelay.status(relay).permits == 0 end)
    stop_connection(connection, relay, incarnation)
  end

  test "cut freezes exact rows, is idempotent and refuses every later permit" do
    relay = start_relay(admission_wait_ms: 500)
    incarnation = incarnation()
    connection = start_connection(relay, incarnation)
    origin = {incarnation, 4, 1}

    assert {:ok, ^origin} =
             invoke(connection, fn ->
               AdmissionRelay.open_permit(relay, origin, :artifact_read_chunk)
             end)

    cut_ref = make_ref()
    send(relay, {:relay_barrier, cut_ref, :cut})

    assert_receive {:relay_barrier_ack, ^cut_ref, :cut, payload}, 500
    assert payload.tickets == []
    assert payload.permits == [{origin, :pending}]
    assert is_integer(payload.admission_deadline)

    send(relay, {:relay_barrier, cut_ref, :cut})
    assert_receive {:relay_barrier_ack, ^cut_ref, :cut, ^payload}, 500

    retirement_recipient = self()

    assert :ok =
             invoke(connection, fn ->
               AdmissionRelay.register_connection(
                 relay,
                 incarnation,
                 retirement_recipient
               )
             end)

    stale_ref = make_ref()
    send(relay, {:relay_barrier, stale_ref, :cut})
    refute_receive {:relay_barrier_ack, ^stale_ref, :cut, _payload}, 40

    assert {:error, :daemon_stopping} =
             invoke(connection, fn ->
               AdmissionRelay.open_permit(
                 relay,
                 {incarnation, 5, 1},
                 :artifact_read_chunk
               )
             end)

    {worker, worker_incarnation} = start_worker(relay, connection, origin)

    assert :ok =
             invoke(connection, fn ->
               AdmissionRelay.bind_worker(relay, origin, worker, worker_incarnation)
             end)

    assert_receive {:worker_go, ^worker, ^origin}, 500

    result = %{
      "type" => "result",
      "method" => "artifact.read_chunk",
      "request_id" => "r2",
      "result" => %{"eof" => true}
    }

    send(worker, {:complete, %{invalid: self()}})
    assert_receive {:worker_complete, ^worker, {:error, :invalid_result}}, 500
    refute_receive {:connection_message, ^connection, _message}, 40

    send(worker, {:complete, result})
    assert_receive {:worker_complete, ^worker, :ok}, 500

    assert_receive {:connection_message, ^connection, {:relay_permit_result, ^origin, ^result}},
                   500

    eventually(fn -> AdmissionRelay.status(relay).permits == 0 end)
    stop_connection(connection, relay, incarnation)
  end

  test "the admission deadline cancels a pending worker before dispatch" do
    relay = start_relay(admission_wait_ms: 20)
    incarnation = incarnation()
    connection = start_connection(relay, incarnation)
    origin = {incarnation, 6, 1}

    assert {:ok, ^origin} =
             invoke(connection, fn ->
               AdmissionRelay.open_permit(relay, origin, :resources_catalog, "session")
             end)

    cut_ref = make_ref()
    send(relay, {:relay_barrier, cut_ref, :cut})
    assert_receive {:relay_barrier_ack, ^cut_ref, :cut, _payload}, 500

    assert_receive {:connection_message, ^connection,
                    {:relay_permit_cancelled, ^origin, :daemon_stopping}},
                   500

    {worker, worker_incarnation} = start_worker(relay, connection, origin)

    assert {:error, :daemon_stopping} =
             invoke(connection, fn ->
               AdmissionRelay.bind_worker(relay, origin, worker, worker_incarnation)
             end)

    refute_receive {:worker_go, ^worker, ^origin}, 40

    assert %{permits: 0, pending: 0, executing: 0, phase: :draining} =
             AdmissionRelay.status(relay)

    Process.exit(worker, :kill)
    stop_connection(connection, relay, incarnation)
  end

  test "connection loss kills an executing worker before retirement acknowledgement" do
    relay = start_relay()
    incarnation = incarnation()
    connection = start_connection(relay, incarnation)
    origin = {incarnation, 7, 1}

    assert {:ok, ^origin} =
             invoke(connection, fn ->
               AdmissionRelay.open_permit(relay, origin, :artifact_read_chunk)
             end)

    {worker, worker_incarnation} = start_worker(relay, connection, origin)
    worker_monitor = Process.monitor(worker)

    assert :ok =
             invoke(connection, fn ->
               AdmissionRelay.bind_worker(relay, origin, worker, worker_incarnation)
             end)

    assert_receive {:worker_go, ^worker, ^origin}, 500

    connection_monitor = Process.monitor(connection)
    Process.exit(connection, :kill)
    assert_receive {:DOWN, ^connection_monitor, :process, ^connection, :killed}, 500
    assert_receive {:relay_connection_retired, ^relay, ^incarnation}, 500
    refute Process.alive?(worker)
    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, :killed}, 500

    eventually(fn ->
      status = AdmissionRelay.status(relay)
      status.connections == 0 and status.permits == 0
    end)
  end

  test "a selected result remains selected when connection loss races worker exit" do
    relay = start_relay()
    incarnation = incarnation()
    connection = start_connection(relay, incarnation)
    origin = {incarnation, 8, 1}

    assert {:ok, ^origin} =
             invoke(connection, fn ->
               AdmissionRelay.open_permit(relay, origin, :daemon_status)
             end)

    {worker, worker_incarnation} = start_worker(relay, connection, origin, :hold_after_result)
    worker_monitor = Process.monitor(worker)

    assert :ok =
             invoke(connection, fn ->
               AdmissionRelay.bind_worker(relay, origin, worker, worker_incarnation)
             end)

    assert_receive {:worker_go, ^worker, ^origin}, 500

    result = %{
      "type" => "result",
      "method" => "daemon.status",
      "request_id" => "r3",
      "result" => %{}
    }

    send(worker, {:complete, result})
    assert_receive {:worker_complete, ^worker, :ok}, 500

    assert_receive {:connection_message, ^connection, {:relay_permit_result, ^origin, ^result}},
                   500

    assert %{settling: 1} = AdmissionRelay.status(relay)

    Process.exit(connection, :kill)
    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, :killed}, 500
    assert_receive {:relay_connection_retired, ^relay, ^incarnation}, 500
    eventually(fn -> AdmissionRelay.status(relay).permits == 0 end)
  end

  test "process diagnostics redact origins, workers and result records" do
    relay = start_relay()
    incarnation = incarnation()
    connection = start_connection(relay, incarnation)
    origin = {incarnation, 9, 1}

    assert {:ok, ^origin} =
             invoke(connection, fn ->
               AdmissionRelay.open_permit(relay, origin, :daemon_status)
             end)

    rendered = inspect(:sys.get_status(relay), limit: :infinity)
    refute rendered =~ Base.encode16(incarnation)
    refute rendered =~ inspect(origin)
    assert rendered =~ "redacted_admission_relay_state"

    stop_connection(connection, relay, incarnation)
  end

  test "ticket origins cover the ten mutation classes and share the connection bound" do
    relay = start_relay()
    incarnation = incarnation()
    connection = start_connection(relay, incarnation)
    owner_binding = {self(), incarnation()}

    assert :ok =
             AdmissionRelay.register_lease_owner(
               relay,
               "session",
               elem(owner_binding, 0),
               elem(owner_binding, 1)
             )

    classes = [
      {:session_create, nil, nil},
      {:session_resume, "session", owner_binding},
      {:session_attach, "session", nil},
      {:session_prompt, "session", owner_binding},
      {:session_steer, "session", owner_binding},
      {:session_follow_up, "session", owner_binding},
      {:session_abort, "session", owner_binding},
      {:session_respond_interaction, "session", owner_binding},
      {:session_admit_resources, "session", owner_binding},
      {:session_activate_skill, "session", owner_binding}
    ]

    Enum.with_index(classes, fn {class, session_id, binding}, slot ->
      origin = {incarnation, slot, 1}

      assert {:ok, ^origin} =
               invoke(connection, fn ->
                 AdmissionRelay.open_ticket(relay, origin, class, session_id, binding)
               end)

      assert {:ok, ^origin} =
               invoke(connection, fn ->
                 AdmissionRelay.open_ticket(relay, origin, class, session_id, binding)
               end)
    end)

    conflict = {incarnation, 0, 1}

    assert {:error, :permit_conflict} =
             invoke(connection, fn ->
               AdmissionRelay.open_permit(relay, conflict, :daemon_status)
             end)

    assert {:error, :ticket_conflict} =
             invoke(connection, fn ->
               AdmissionRelay.open_ticket(relay, conflict, :session_attach, "session")
             end)

    assert {:error, :invalid_origin} =
             invoke(connection, fn ->
               AdmissionRelay.open_ticket(
                 relay,
                 {incarnation, 10, 1},
                 :session_prompt,
                 "session"
               )
             end)

    for slot <- 10..31 do
      origin = {incarnation, slot, 1}

      assert {:ok, ^origin} =
               invoke(connection, fn ->
                 AdmissionRelay.open_permit(relay, origin, :daemon_status)
               end)
    end

    assert {:error, :capacity_exceeded} =
             invoke(connection, fn ->
               AdmissionRelay.open_ticket(
                 relay,
                 {incarnation, 0, 2},
                 :session_create
               )
             end)

    assert %{permits: 22, tickets: 10, pending: 32, queued: 0} =
             AdmissionRelay.status(relay)

    stop_connection(connection, relay, incarnation)
  end

  test "a queued ticket worker is monitored without dispatch and loss terminalizes it" do
    relay = start_relay()
    incarnation = incarnation()
    connection = start_connection(relay, incarnation)
    origin = {incarnation, 0, 1}

    assert {:ok, ^origin} =
             invoke(connection, fn ->
               AdmissionRelay.open_ticket(relay, origin, :session_create)
             end)

    worker = start_ticket_worker(connection)

    assert :ok =
             invoke(connection, fn ->
               AdmissionRelay.bind_ticket_worker(relay, origin, worker, incarnation())
             end)

    refute_receive {:ticket_worker_message, ^worker, _message}, 40
    assert %{tickets: 1, pending: 0, queued: 1} = AdmissionRelay.status(relay)

    Process.exit(worker, :kill)

    assert_receive {:connection_message, ^connection,
                    {:relay_ticket_failed, ^origin, :worker_lost}},
                   500

    eventually(fn -> AdmissionRelay.status(relay).tickets == 0 end)
    stop_connection(connection, relay, incarnation)
  end

  test "the cut freezes pending and queued tickets and the deadline reaps both" do
    relay = start_relay(admission_wait_ms: 20)
    incarnation = incarnation()
    connection = start_connection(relay, incarnation)
    pending = {incarnation, 0, 1}
    queued = {incarnation, 1, 1}

    for origin <- [pending, queued] do
      assert {:ok, ^origin} =
               invoke(connection, fn ->
                 AdmissionRelay.open_ticket(relay, origin, :session_attach, "session")
               end)
    end

    worker = start_ticket_worker(connection)
    worker_monitor = Process.monitor(worker)

    assert :ok =
             invoke(connection, fn ->
               AdmissionRelay.bind_ticket_worker(relay, queued, worker, incarnation())
             end)

    cut_ref = make_ref()
    send(relay, {:relay_barrier, cut_ref, :cut})

    assert_receive {:relay_barrier_ack, ^cut_ref, :cut, payload}, 500
    assert payload.permits == []
    assert payload.tickets == [{pending, :pending}, {queued, :queued}]

    assert {:error, :daemon_stopping} =
             AdmissionRelay.register_lease_owner(
               relay,
               "late-session",
               start_actor(),
               incarnation()
             )

    assert_receive {:connection_message, ^connection,
                    {:relay_ticket_cancelled, ^pending, :daemon_stopping}},
                   500

    assert_receive {:connection_message, ^connection,
                    {:relay_ticket_cancelled, ^queued, :daemon_stopping}},
                   500

    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, :killed}, 500
    eventually(fn -> AdmissionRelay.status(relay).tickets == 0 end)
    stop_connection(connection, relay, incarnation)
  end

  test "connection loss reaps a queued ticket worker before relay retirement" do
    relay = start_relay()
    incarnation = incarnation()
    connection = start_connection(relay, incarnation)
    origin = {incarnation, 0, 1}

    assert {:ok, ^origin} =
             invoke(connection, fn ->
               AdmissionRelay.open_ticket(relay, origin, :session_create)
             end)

    worker = start_ticket_worker(connection)
    worker_monitor = Process.monitor(worker)

    assert :ok =
             invoke(connection, fn ->
               AdmissionRelay.bind_ticket_worker(relay, origin, worker, incarnation())
             end)

    connection_monitor = Process.monitor(connection)
    Process.exit(connection, :kill)
    assert_receive {:DOWN, ^connection_monitor, :process, ^connection, :killed}, 500
    assert_receive {:relay_connection_retired, ^relay, ^incarnation}, 500
    refute Process.alive?(worker)
    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, _reason}, 500
    assert %{connections: 0, tickets: 0} = AdmissionRelay.status(relay)
  end

  test "registry promotion starts the task before acknowledgement and settles its result" do
    relay = start_relay()
    registry = start_registry()
    registry_incarnation = incarnation()
    assert :ok = AdmissionRelay.register_registry(relay, registry, registry_incarnation)

    incarnation = incarnation()
    connection = start_connection(relay, incarnation)
    origin = {incarnation, 0, 1}
    settlement_ref = make_ref()

    assert {:ok, ^origin} =
             invoke(connection, fn ->
               AdmissionRelay.open_ticket(relay, origin, :session_create)
             end)

    worker = start_ticket_worker(connection)
    worker_monitor = Process.monitor(worker)

    assert :ok =
             invoke(connection, fn ->
               AdmissionRelay.bind_ticket_worker(relay, origin, worker, incarnation())
             end)

    parent = self()
    task_release = make_ref()

    result = %{
      "type" => "result",
      "method" => "session.create",
      "request_id" => "r-ticket-1",
      "result" => %{"session_id" => "session"}
    }

    promotion_ref = make_ref()

    send(
      registry,
      {:invoke, self(), promotion_ref,
       fn ->
         AdmissionRelay.promote_ticket(
           relay,
           origin,
           registry_incarnation,
           settlement_ref,
           fn ->
             send(parent, {:ticket_task_started, self()})

             receive do
               ^task_release -> result
             end
           end
         )
       end}
    )

    assert_receive {:ticket_task_started, task}, 500
    assert_receive {:invoked, ^promotion_ref, {:ok, ^origin}}, 500
    assert Process.alive?(task)
    refute Process.alive?(worker)
    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, :killed}, 500

    assert {:ok, ^origin} =
             invoke(registry, fn ->
               AdmissionRelay.promote_ticket(
                 relay,
                 origin,
                 registry_incarnation,
                 settlement_ref,
                 fn ->
                   send(parent, :duplicate_task_started)
                   result
                 end
               )
             end)

    refute_receive :duplicate_task_started, 40

    assert {:error, :invalid_promotion} =
             invoke(registry, fn ->
               AdmissionRelay.promote_ticket(
                 relay,
                 origin,
                 registry_incarnation,
                 make_ref(),
                 fn -> result end
               )
             end)

    send(task, task_release)

    assert_receive {:registry_message, ^registry,
                    {:relay_ticket_settlement, ^relay, ^origin, ^settlement_ref, ^result}},
                   500

    assert :ok =
             invoke(registry, fn ->
               AdmissionRelay.settle_ticket(
                 relay,
                 origin,
                 registry_incarnation,
                 settlement_ref
               )
             end)

    assert_receive {:connection_message, ^connection, {:relay_ticket_result, ^origin, ^result}},
                   500

    eventually(fn -> AdmissionRelay.status(relay).tickets == 0 end)
    stop_connection(connection, relay, incarnation)
  end

  test "shutdown barriers run in order, repeat idempotently and seal an unresolved task" do
    relay = start_relay()
    registry = start_registry()
    registry_incarnation = incarnation()
    assert :ok = AdmissionRelay.register_registry(relay, registry, registry_incarnation)

    incarnation = incarnation()
    connection = start_connection(relay, incarnation)
    origin = {incarnation, 0, 1}

    assert {:ok, ^origin} =
             invoke(connection, fn ->
               AdmissionRelay.open_ticket(relay, origin, :session_create)
             end)

    worker = start_ticket_worker(connection)

    assert :ok =
             invoke(connection, fn ->
               AdmissionRelay.bind_ticket_worker(relay, origin, worker, incarnation())
             end)

    parent = self()

    assert {:ok, ^origin} =
             invoke(registry, fn ->
               AdmissionRelay.promote_ticket(
                 relay,
                 origin,
                 registry_incarnation,
                 make_ref(),
                 fn ->
                   send(parent, {:ticket_task_started, self()})
                   Process.sleep(:infinity)
                 end
               )
             end)

    assert_receive {:ticket_task_started, task}, 500
    task_monitor = Process.monitor(task)

    # A later barrier sent before its predecessor is ignored.
    early = make_ref()
    send(relay, {:relay_barrier, early, {:quiescing, make_ref()}})
    refute_receive {:relay_barrier_ack, ^early, _name, _payload}, 40

    cut_ref = make_ref()
    send(relay, {:relay_barrier, cut_ref, :cut})
    assert_receive {:relay_barrier_ack, ^cut_ref, :cut, _payload}, 500

    freeze = make_ref()
    send(relay, {:relay_barrier, freeze, {:freeze_lease_ops, 0}})
    assert_receive {:relay_barrier_ack, ^freeze, :freeze_lease_ops, []}, 500
    send(relay, {:relay_barrier, freeze, {:freeze_lease_ops, 0}})
    assert_receive {:relay_barrier_ack, ^freeze, :freeze_lease_ops, []}, 500
    assert AdmissionRelay.status(relay).phase == :lease_ops_frozen

    # Nothing new is admitted once lease operations are frozen.
    assert {:error, :daemon_stopping} =
             invoke(connection, fn ->
               AdmissionRelay.open_ticket(relay, {incarnation, 1, 2}, :session_create)
             end)

    drain_id = make_ref()
    quiescing = make_ref()
    send(relay, {:relay_barrier, quiescing, {:quiescing, drain_id}})
    assert_receive {:relay_barrier_ack, ^quiescing, :quiescing, ^drain_id}, 500

    seal = make_ref()
    deadline = System.monotonic_time(:millisecond) + 2_000
    send(relay, {:relay_barrier, seal, {:seal_after_quiesce, drain_id, deadline}})

    assert_receive {:relay_barrier_ack, ^seal, :seal_after_quiesce,
                    %{results: [], unresolved: [^origin]}},
                   2_500

    assert_receive {:DOWN, ^task_monitor, :process, ^task, :killed}, 500
    assert AdmissionRelay.status(relay).tickets == 0

    teardown = make_ref()
    send(relay, {:relay_barrier, teardown, :tearing_down})
    assert_receive {:relay_barrier_ack, ^teardown, :tearing_down, []}, 500
    assert AdmissionRelay.status(relay).phase == :tearing_down
  end

  test "only the registered registry can promote and its exact identity is fixed" do
    relay = start_relay()
    registry = start_registry()
    registry_incarnation = incarnation()

    assert {:error, :invalid_registry} =
             invoke(registry, fn ->
               AdmissionRelay.register_registry(relay, registry, registry_incarnation)
             end)

    assert :ok = AdmissionRelay.register_registry(relay, registry, registry_incarnation)
    assert :ok = AdmissionRelay.register_registry(relay, registry, registry_incarnation)

    assert {:error, :registry_conflict} =
             AdmissionRelay.register_registry(relay, start_registry(), incarnation())

    incarnation = incarnation()
    connection = start_connection(relay, incarnation)
    origin = {incarnation, 0, 1}

    assert {:ok, ^origin} =
             invoke(connection, fn ->
               AdmissionRelay.open_ticket(relay, origin, :session_create)
             end)

    assert {:error, :registry_unavailable} =
             AdmissionRelay.promote_ticket(
               relay,
               origin,
               registry_incarnation,
               make_ref(),
               fn -> %{} end
             )

    assert {:error, :registry_unavailable} =
             invoke(registry, fn ->
               AdmissionRelay.promote_ticket(
                 relay,
                 origin,
                 incarnation(),
                 make_ref(),
                 fn -> %{} end
               )
             end)

    stop_connection(connection, relay, incarnation)
  end

  test "a promoted task lost before a result fails the relay closed" do
    Process.flag(:trap_exit, true)
    relay = start_relay()
    relay_monitor = Process.monitor(relay)
    registry = start_registry()
    registry_incarnation = incarnation()
    assert :ok = AdmissionRelay.register_registry(relay, registry, registry_incarnation)

    incarnation = incarnation()
    connection = start_connection(relay, incarnation)
    origin = {incarnation, 0, 1}

    assert {:ok, ^origin} =
             invoke(connection, fn ->
               AdmissionRelay.open_ticket(relay, origin, :session_create)
             end)

    assert {:ok, ^origin} =
             invoke(registry, fn ->
               AdmissionRelay.promote_ticket(
                 relay,
                 origin,
                 registry_incarnation,
                 make_ref(),
                 fn -> exit(:task_canary_reason) end
               )
             end)

    assert_receive {:DOWN, ^relay_monitor, :process, ^relay, :relay_task_lost}, 500
    assert_receive {:EXIT, ^relay, :relay_task_lost}, 500
  end

  test "a promoted task outlives its connection and retirement waits for settlement" do
    relay = start_relay()
    registry = start_registry()
    registry_incarnation = incarnation()
    assert :ok = AdmissionRelay.register_registry(relay, registry, registry_incarnation)

    incarnation = incarnation()
    connection = start_connection(relay, incarnation)
    origin = {incarnation, 0, 1}
    settlement_ref = make_ref()
    parent = self()

    assert {:ok, ^origin} =
             invoke(connection, fn ->
               AdmissionRelay.open_ticket(relay, origin, :session_attach, "session")
             end)

    result = %{
      "type" => "result",
      "method" => "session.attach",
      "request_id" => "r-ticket-2",
      "result" => %{"attachment_id" => "attachment"}
    }

    assert {:ok, ^origin} =
             invoke(registry, fn ->
               AdmissionRelay.promote_ticket(
                 relay,
                 origin,
                 registry_incarnation,
                 settlement_ref,
                 fn ->
                   send(parent, {:promoted_task_waiting, self()})

                   receive do
                     :finish -> result
                   end
                 end
               )
             end)

    assert_receive {:promoted_task_waiting, task}, 500
    Process.exit(connection, :kill)
    refute_receive {:relay_connection_retired, ^relay, ^incarnation}, 40

    send(task, :finish)

    assert_receive {:registry_message, ^registry,
                    {:relay_ticket_settlement, ^relay, ^origin, ^settlement_ref, ^result}},
                   500

    assert :ok =
             invoke(registry, fn ->
               AdmissionRelay.settle_ticket(
                 relay,
                 origin,
                 registry_incarnation,
                 settlement_ref
               )
             end)

    assert_receive {:relay_connection_retired, ^relay, ^incarnation}, 500
    refute_receive {:connection_message, ^connection, _message}, 40
  end

  test "only a frozen pre-cut ticket can promote before the admission deadline" do
    relay = start_relay(admission_wait_ms: 200)
    registry = start_registry()
    registry_incarnation = incarnation()
    assert :ok = AdmissionRelay.register_registry(relay, registry, registry_incarnation)

    incarnation = incarnation()
    connection = start_connection(relay, incarnation)
    admitted = {incarnation, 0, 1}
    expires = {incarnation, 1, 1}

    for origin <- [admitted, expires] do
      assert {:ok, ^origin} =
               invoke(connection, fn ->
                 AdmissionRelay.open_ticket(relay, origin, :session_create)
               end)
    end

    cut_ref = make_ref()
    send(relay, {:relay_barrier, cut_ref, :cut})
    assert_receive {:relay_barrier_ack, ^cut_ref, :cut, _payload}, 500

    settlement_ref = make_ref()
    result = %{"type" => "result", "method" => "session.create", "request_id" => "cut"}

    assert {:ok, ^admitted} =
             invoke(registry, fn ->
               AdmissionRelay.promote_ticket(
                 relay,
                 admitted,
                 registry_incarnation,
                 settlement_ref,
                 fn -> result end
               )
             end)

    assert_receive {:registry_message, ^registry,
                    {:relay_ticket_settlement, ^relay, ^admitted, ^settlement_ref, ^result}},
                   500

    assert :ok =
             invoke(registry, fn ->
               AdmissionRelay.settle_ticket(
                 relay,
                 admitted,
                 registry_incarnation,
                 settlement_ref
               )
             end)

    assert_receive {:connection_message, ^connection, {:relay_ticket_result, ^admitted, ^result}},
                   500

    assert_receive {:connection_message, ^connection,
                    {:relay_ticket_cancelled, ^expires, :daemon_stopping}},
                   500

    assert {:error, :daemon_stopping} =
             invoke(registry, fn ->
               AdmissionRelay.promote_ticket(
                 relay,
                 expires,
                 registry_incarnation,
                 make_ref(),
                 fn -> result end
               )
             end)

    eventually(fn -> AdmissionRelay.status(relay).tickets == 0 end)
    stop_connection(connection, relay, incarnation)
  end

  test "an exact duplicate waits on one promoted task and receives its own origin result" do
    relay = start_relay()
    registry = start_registry()
    registry_incarnation = incarnation()
    assert :ok = AdmissionRelay.register_registry(relay, registry, registry_incarnation)

    primary_incarnation = incarnation()
    waiter_incarnation = incarnation()
    primary_connection = start_connection(relay, primary_incarnation)
    waiter_connection = start_connection(relay, waiter_incarnation)
    primary = {primary_incarnation, 0, 1}
    waiter = {waiter_incarnation, 0, 1}
    settlement_ref = make_ref()
    parent = self()

    assert {:ok, ^primary} =
             invoke(primary_connection, fn ->
               AdmissionRelay.open_ticket(relay, primary, :session_create)
             end)

    result = %{"session_id" => "shared-session", "disposition" => "activated"}

    assert {:ok, ^primary} =
             invoke(registry, fn ->
               AdmissionRelay.promote_ticket(
                 relay,
                 primary,
                 registry_incarnation,
                 settlement_ref,
                 fn ->
                   send(parent, {:primary_task_started, self()})

                   receive do
                     :complete -> result
                   end
                 end
               )
             end)

    assert_receive {:primary_task_started, task}, 500

    assert {:ok, ^waiter} =
             invoke(waiter_connection, fn ->
               AdmissionRelay.open_ticket(relay, waiter, :session_create)
             end)

    waiter_worker = start_ticket_worker(waiter_connection)
    waiter_worker_monitor = Process.monitor(waiter_worker)

    assert :ok =
             invoke(waiter_connection, fn ->
               AdmissionRelay.bind_ticket_worker(
                 relay,
                 waiter,
                 waiter_worker,
                 incarnation()
               )
             end)

    assert {:ok, ^primary} =
             invoke(registry, fn ->
               AdmissionRelay.wait_for_ticket(
                 relay,
                 waiter,
                 primary,
                 registry_incarnation
               )
             end)

    refute Process.alive?(waiter_worker)
    assert_receive {:DOWN, ^waiter_worker_monitor, :process, ^waiter_worker, :killed}, 500

    assert {:ok, ^primary} =
             invoke(registry, fn ->
               AdmissionRelay.wait_for_ticket(
                 relay,
                 waiter,
                 primary,
                 registry_incarnation
               )
             end)

    assert %{ticketed: 1, waiting: 1, tickets: 2} = AdmissionRelay.status(relay)

    send(task, :complete)

    assert_receive {:registry_message, ^registry,
                    {:relay_ticket_settlement, ^relay, ^primary, ^settlement_ref, ^result}},
                   500

    assert :ok =
             invoke(registry, fn ->
               AdmissionRelay.settle_ticket(
                 relay,
                 primary,
                 registry_incarnation,
                 settlement_ref
               )
             end)

    assert_receive {:connection_message, ^primary_connection,
                    {:relay_ticket_result, ^primary, ^result}},
                   500

    assert_receive {:connection_message, ^waiter_connection,
                    {:relay_ticket_result, ^waiter, ^result}},
                   500

    eventually(fn -> AdmissionRelay.status(relay).tickets == 0 end)
    stop_connection(primary_connection, relay, primary_incarnation)
    stop_connection(waiter_connection, relay, waiter_incarnation)
  end

  test "a waiting connection can disappear without cancelling its primary" do
    relay = start_relay()
    registry = start_registry()
    registry_incarnation = incarnation()
    assert :ok = AdmissionRelay.register_registry(relay, registry, registry_incarnation)

    primary_incarnation = incarnation()
    waiter_incarnation = incarnation()
    primary_connection = start_connection(relay, primary_incarnation)
    waiter_connection = start_connection(relay, waiter_incarnation)
    primary = {primary_incarnation, 0, 1}
    waiter = {waiter_incarnation, 0, 1}
    settlement_ref = make_ref()
    parent = self()

    assert {:ok, ^primary} =
             invoke(primary_connection, fn ->
               AdmissionRelay.open_ticket(relay, primary, :session_attach, "session")
             end)

    result = %{"attachment_id" => "attachment"}

    assert {:ok, ^primary} =
             invoke(registry, fn ->
               AdmissionRelay.promote_ticket(
                 relay,
                 primary,
                 registry_incarnation,
                 settlement_ref,
                 fn ->
                   send(parent, {:primary_waiting, self()})

                   receive do
                     :complete -> result
                   end
                 end
               )
             end)

    assert_receive {:primary_waiting, task}, 500

    assert {:ok, ^waiter} =
             invoke(waiter_connection, fn ->
               AdmissionRelay.open_ticket(relay, waiter, :session_attach, "session")
             end)

    assert {:ok, ^primary} =
             invoke(registry, fn ->
               AdmissionRelay.wait_for_ticket(
                 relay,
                 waiter,
                 primary,
                 registry_incarnation
               )
             end)

    Process.exit(waiter_connection, :kill)
    assert_receive {:relay_connection_retired, ^relay, ^waiter_incarnation}, 500
    assert %{ticketed: 1, waiting: 0, tickets: 1} = AdmissionRelay.status(relay)

    send(task, :complete)

    assert_receive {:registry_message, ^registry,
                    {:relay_ticket_settlement, ^relay, ^primary, ^settlement_ref, ^result}},
                   500

    assert :ok =
             invoke(registry, fn ->
               AdmissionRelay.settle_ticket(
                 relay,
                 primary,
                 registry_incarnation,
                 settlement_ref
               )
             end)

    assert_receive {:connection_message, ^primary_connection,
                    {:relay_ticket_result, ^primary, ^result}},
                   500

    eventually(fn -> AdmissionRelay.status(relay).tickets == 0 end)
    stop_connection(primary_connection, relay, primary_incarnation)
  end

  test "a registered lease owner alone promotes its mutation task" do
    relay = start_relay()
    owner = start_actor()
    owner_incarnation = incarnation()

    assert :ok =
             AdmissionRelay.register_lease_owner(
               relay,
               "session",
               owner,
               owner_incarnation
             )

    assert :ok =
             AdmissionRelay.register_lease_owner(
               relay,
               "session",
               owner,
               owner_incarnation
             )

    assert {:error, :owner_conflict} =
             AdmissionRelay.register_lease_owner(
               relay,
               "session",
               start_actor(),
               incarnation()
             )

    incarnation = incarnation()
    connection = start_connection(relay, incarnation)
    origin = {incarnation, 0, 1}

    assert {:error, :invalid_origin} =
             invoke(connection, fn ->
               AdmissionRelay.open_ticket(
                 relay,
                 origin,
                 :session_prompt,
                 "session",
                 {owner, incarnation()}
               )
             end)

    assert {:ok, ^origin} =
             invoke(connection, fn ->
               AdmissionRelay.open_ticket(
                 relay,
                 origin,
                 :session_prompt,
                 "session",
                 {owner, owner_incarnation}
               )
             end)

    worker = start_ticket_worker(connection)
    worker_monitor = Process.monitor(worker)

    assert :ok =
             invoke(connection, fn ->
               AdmissionRelay.bind_ticket_worker(relay, origin, worker, incarnation())
             end)

    parent = self()
    result = %{"accepted" => true}

    assert {:ok, ^origin} =
             invoke(owner, fn ->
               AdmissionRelay.promote_lease_ticket(
                 relay,
                 origin,
                 owner_incarnation,
                 fn ->
                   send(parent, {:lease_task_waiting, self()})

                   receive do
                     :complete -> result
                   end
                 end
               )
             end)

    assert_receive {:lease_task_waiting, task}, 500
    refute Process.alive?(worker)
    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, :killed}, 500

    assert {:ok, ^origin} =
             invoke(owner, fn ->
               AdmissionRelay.promote_lease_ticket(
                 relay,
                 origin,
                 owner_incarnation,
                 fn -> %{"duplicate" => true} end
               )
             end)

    send(task, :complete)

    assert_receive {:connection_message, ^connection, {:relay_ticket_result, ^origin, ^result}},
                   500

    eventually(fn -> AdmissionRelay.status(relay).tickets == 0 end)
    stop_connection(connection, relay, incarnation)
  end

  test "one unresolved mutation per session spans direct and resume promotion" do
    relay = start_relay()
    owner = start_actor()
    owner_incarnation = incarnation()
    registry = start_registry()
    registry_incarnation = incarnation()

    assert :ok =
             AdmissionRelay.register_lease_owner(
               relay,
               "session",
               owner,
               owner_incarnation
             )

    assert :ok =
             AdmissionRelay.register_registry(relay, registry, registry_incarnation)

    connection_incarnation = incarnation()
    connection = start_connection(relay, connection_incarnation)
    first = {connection_incarnation, 0, 1}
    second = {connection_incarnation, 1, 1}
    resume = {connection_incarnation, 2, 1}
    binding = {owner, owner_incarnation}

    for {origin, class} <- [
          {first, :session_prompt},
          {second, :session_abort},
          {resume, :session_resume}
        ] do
      assert {:ok, ^origin} =
               invoke(connection, fn ->
                 AdmissionRelay.open_ticket(relay, origin, class, "session", binding)
               end)

      worker = start_ticket_worker(connection)

      assert :ok =
               invoke(connection, fn ->
                 AdmissionRelay.bind_ticket_worker(relay, origin, worker, incarnation())
               end)
    end

    parent = self()
    first_result = %{"operation" => "first", "status" => "accepted"}

    assert {:ok, ^first} =
             invoke(owner, fn ->
               AdmissionRelay.promote_lease_ticket(
                 relay,
                 first,
                 owner_incarnation,
                 fn ->
                   send(parent, {:one_mutation_task, self()})

                   receive do
                     :complete -> first_result
                   end
                 end
               )
             end)

    assert_receive {:one_mutation_task, first_task}, 500

    assert {:error, :ticket_outstanding} =
             invoke(owner, fn ->
               AdmissionRelay.promote_lease_ticket(
                 relay,
                 second,
                 owner_incarnation,
                 fn -> %{"unexpected" => true} end
               )
             end)

    resume_settlement = make_ref()

    assert {:error, :ticket_outstanding} =
             invoke(registry, fn ->
               AdmissionRelay.promote_resume_ticket(
                 relay,
                 resume,
                 registry_incarnation,
                 resume_settlement,
                 owner,
                 owner_incarnation,
                 fn -> %{"unexpected" => true} end
               )
             end)

    send(first_task, :complete)

    assert_receive {:connection_message, ^connection,
                    {:relay_ticket_result, ^first, ^first_result}},
                   500

    assert_receive {:registry_message, ^owner,
                    {:relay_lease_ticket_settled, ^relay, ^first, ^owner_incarnation}},
                   500

    resume_result = %{"operation" => "resume", "status" => "accepted"}

    assert {:ok, ^resume} =
             invoke(registry, fn ->
               AdmissionRelay.promote_resume_ticket(
                 relay,
                 resume,
                 registry_incarnation,
                 resume_settlement,
                 owner,
                 owner_incarnation,
                 fn -> resume_result end
               )
             end)

    assert_receive {:registry_message, ^registry,
                    {:relay_ticket_settlement, ^relay, ^resume, ^resume_settlement,
                     ^resume_result}},
                   500

    assert :ok =
             invoke(registry, fn ->
               AdmissionRelay.settle_ticket(
                 relay,
                 resume,
                 registry_incarnation,
                 resume_settlement
               )
             end)

    assert_receive {:connection_message, ^connection,
                    {:relay_ticket_result, ^resume, ^resume_result}},
                   500

    eventually(fn -> AdmissionRelay.status(relay).tickets == 1 end)

    # A resume settles through the registry, but only the relay knows when its
    # slot is free: removing the ticket tells the session's registered lease
    # owner, so the owner can promote its next queued mutation.
    assert_receive {:registry_message, ^owner,
                    {:relay_lease_ticket_settled, ^relay, ^resume, ^owner_incarnation}},
                   500

    second_result = %{"operation" => "second", "status" => "accepted"}

    assert {:ok, ^second} =
             invoke(owner, fn ->
               AdmissionRelay.promote_lease_ticket(
                 relay,
                 second,
                 owner_incarnation,
                 fn -> second_result end
               )
             end)

    assert_receive {:connection_message, ^connection,
                    {:relay_ticket_result, ^second, ^second_result}},
                   500

    assert_receive {:registry_message, ^owner,
                    {:relay_lease_ticket_settled, ^relay, ^second, ^owner_incarnation}},
                   500

    eventually(fn -> AdmissionRelay.status(relay).tickets == 0 end)
    stop_connection(connection, relay, connection_incarnation)
  end

  test "lease owner loss claims pending and queued mutations for exact settlement" do
    daemon_incarnation = incarnation()
    relay = start_relay(owner_incarnation: daemon_incarnation)
    owner = start_actor()
    owner_incarnation = incarnation()
    binding = {owner, owner_incarnation}

    assert :ok =
             AdmissionRelay.register_lease_owner(
               relay,
               "session",
               owner,
               owner_incarnation
             )

    incarnation = incarnation()
    connection = start_connection(relay, incarnation)
    pending = {incarnation, 0, 1}
    queued = {incarnation, 1, 1}

    for {origin, class} <- [{pending, :session_prompt}, {queued, :session_abort}] do
      assert {:ok, ^origin} =
               invoke(connection, fn ->
                 AdmissionRelay.open_ticket(relay, origin, class, "session", binding)
               end)
    end

    worker = start_ticket_worker(connection)
    worker_monitor = Process.monitor(worker)

    assert :ok =
             invoke(connection, fn ->
               AdmissionRelay.bind_ticket_worker(relay, queued, worker, incarnation())
             end)

    Process.exit(owner, :kill)

    assert_receive {:relay_owner_lost, ^relay, "session", ^owner, ^owner_incarnation, origins},
                   500

    assert origins == [pending, queued]
    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, :killed}, 500

    assert_receive {:relay_owner_loss_ready, ^relay, ^owner, ^owner_incarnation}, 500
    refute_receive {:connection_message, ^connection, {:relay_ticket_failed, _, _}}, 40

    assert %{lease_owners: 0, owner_losses: 1, tickets: 2, settling: 2} =
             AdmissionRelay.status(relay)

    classification_ref = make_ref()

    assert :ok =
             AdmissionRelay.classify_owner_loss(
               relay,
               classification_ref,
               daemon_incarnation,
               "session",
               owner,
               owner_incarnation,
               nil
             )

    assert_receive {:connection_message, ^connection,
                    {:relay_ticket_cancelled, ^pending, :control_owner_lost}},
                   500

    assert_receive {:connection_message, ^connection,
                    {:relay_ticket_cancelled, ^queued, :control_owner_lost}},
                   500

    assert_receive {:relay_owner_loss_classified_ack, ^relay, ^classification_ref, "session",
                    ^owner, ^owner_incarnation},
                   500

    assert %{owner_losses: 0, tickets: 0} = AdmissionRelay.status(relay)
    stop_connection(connection, relay, incarnation)
  end

  test "an early owner-loss classification joins exact down and suppresses a holder refusal" do
    daemon_incarnation = incarnation()
    relay = start_relay(owner_incarnation: daemon_incarnation)
    owner = start_actor()
    owner_incarnation = incarnation()
    binding = {owner, owner_incarnation}

    assert :ok =
             AdmissionRelay.register_lease_owner(
               relay,
               "early-session",
               owner,
               owner_incarnation
             )

    connection_incarnation = incarnation()
    connection = start_connection(relay, connection_incarnation)
    origin = {connection_incarnation, 0, 1}

    assert {:ok, ^origin} =
             invoke(connection, fn ->
               AdmissionRelay.open_ticket(
                 relay,
                 origin,
                 :session_prompt,
                 "early-session",
                 binding
               )
             end)

    classification_ref = make_ref()

    assert :ok =
             AdmissionRelay.classify_owner_loss(
               relay,
               classification_ref,
               daemon_incarnation,
               "early-session",
               owner,
               owner_incarnation,
               connection_incarnation
             )

    eventually(fn -> AdmissionRelay.status(relay).owner_losses == 1 end)

    refute_receive {:relay_owner_loss_classified_ack, ^relay, ^classification_ref, _, _, _}, 40
    Process.exit(owner, :kill)

    assert_receive {:relay_owner_lost, ^relay, "early-session", ^owner, ^owner_incarnation,
                    [^origin]},
                   500

    assert_receive {:relay_owner_loss_ready, ^relay, ^owner, ^owner_incarnation}, 500

    assert_receive {:relay_owner_loss_classified_ack, ^relay, ^classification_ref,
                    "early-session", ^owner, ^owner_incarnation},
                   500

    refute_receive {:connection_message, ^connection,
                    {:relay_ticket_cancelled, ^origin, :control_owner_lost}},
                   40

    assert %{owner_losses: 0, tickets: 0} = AdmissionRelay.status(relay)
    stop_connection(connection, relay, connection_incarnation)
  end

  test "an already promoted mutation keeps its real result after owner loss" do
    daemon_incarnation = incarnation()
    relay = start_relay(owner_incarnation: daemon_incarnation)
    owner = start_actor()
    owner_incarnation = incarnation()

    assert :ok =
             AdmissionRelay.register_lease_owner(
               relay,
               "session",
               owner,
               owner_incarnation
             )

    incarnation = incarnation()
    connection = start_connection(relay, incarnation)
    origin = {incarnation, 0, 1}

    assert {:ok, ^origin} =
             invoke(connection, fn ->
               AdmissionRelay.open_ticket(
                 relay,
                 origin,
                 :session_steer,
                 "session",
                 {owner, owner_incarnation}
               )
             end)

    parent = self()
    result = %{"accepted" => true, "kind" => "steer"}

    assert {:ok, ^origin} =
             invoke(owner, fn ->
               AdmissionRelay.promote_lease_ticket(
                 relay,
                 origin,
                 owner_incarnation,
                 fn ->
                   send(parent, {:promoted_owner_task, self()})

                   receive do
                     :complete -> result
                   end
                 end
               )
             end)

    assert_receive {:promoted_owner_task, task}, 500
    Process.exit(owner, :kill)

    assert_receive {:relay_owner_lost, ^relay, "session", ^owner, ^owner_incarnation, []}, 500
    assert_receive {:relay_owner_loss_ready, ^relay, ^owner, ^owner_incarnation}, 500

    classification_ref = make_ref()

    assert :ok =
             AdmissionRelay.classify_owner_loss(
               relay,
               classification_ref,
               daemon_incarnation,
               "session",
               owner,
               owner_incarnation,
               nil
             )

    assert_receive {:relay_owner_loss_classified_ack, ^relay, ^classification_ref, "session",
                    ^owner, ^owner_incarnation},
                   500

    assert %{ticketed: 1, tickets: 1, owner_losses: 0} = AdmissionRelay.status(relay)
    send(task, :complete)

    assert_receive {:connection_message, ^connection, {:relay_ticket_result, ^origin, ^result}},
                   500

    eventually(fn -> AdmissionRelay.status(relay).tickets == 0 end)
    stop_connection(connection, relay, incarnation)
  end

  test "an authenticated resume ticket promotes through the capacity registry" do
    relay = start_relay()
    registry = start_registry()
    registry_incarnation = incarnation()
    assert :ok = AdmissionRelay.register_registry(relay, registry, registry_incarnation)

    owner = start_actor()
    owner_incarnation = incarnation()

    assert :ok =
             AdmissionRelay.register_lease_owner(
               relay,
               "session",
               owner,
               owner_incarnation
             )

    incarnation = incarnation()
    connection = start_connection(relay, incarnation)
    origin = {incarnation, 0, 1}
    settlement_ref = make_ref()
    result = %{"session_id" => "session", "disposition" => "activated"}

    assert {:ok, ^origin} =
             invoke(connection, fn ->
               AdmissionRelay.open_ticket(
                 relay,
                 origin,
                 :session_resume,
                 "session",
                 {owner, owner_incarnation}
               )
             end)

    assert {:error, :owner_unavailable} =
             invoke(registry, fn ->
               AdmissionRelay.authorize_resume_ticket(
                 relay,
                 origin,
                 registry_incarnation,
                 owner,
                 incarnation()
               )
             end)

    assert {:error, :registry_unavailable} =
             invoke(owner, fn ->
               AdmissionRelay.authorize_resume_ticket(
                 relay,
                 origin,
                 registry_incarnation,
                 owner,
                 owner_incarnation
               )
             end)

    assert :ok =
             invoke(registry, fn ->
               AdmissionRelay.authorize_resume_ticket(
                 relay,
                 origin,
                 registry_incarnation,
                 owner,
                 owner_incarnation
               )
             end)

    assert {:ok, ^origin} =
             invoke(registry, fn ->
               AdmissionRelay.promote_resume_ticket(
                 relay,
                 origin,
                 registry_incarnation,
                 settlement_ref,
                 owner,
                 owner_incarnation,
                 fn -> result end
               )
             end)

    assert_receive {:registry_message, ^registry,
                    {:relay_ticket_settlement, ^relay, ^origin, ^settlement_ref, ^result}},
                   500

    assert :ok =
             invoke(registry, fn ->
               AdmissionRelay.settle_ticket(
                 relay,
                 origin,
                 registry_incarnation,
                 settlement_ref
               )
             end)

    assert_receive {:connection_message, ^connection, {:relay_ticket_result, ^origin, ^result}},
                   500

    eventually(fn -> AdmissionRelay.status(relay).tickets == 0 end)
    stop_connection(connection, relay, incarnation)
  end

  test "an actor-bound lease permit dispatches only to its exact owner" do
    relay = start_relay()
    owner = start_actor()
    owner_incarnation = incarnation()

    assert :ok =
             AdmissionRelay.register_lease_owner(
               relay,
               "session",
               owner,
               owner_incarnation
             )

    connection_incarnation = incarnation()
    connection = start_connection(relay, connection_incarnation)
    origin = {connection_incarnation, 0, 1}
    {worker, worker_incarnation} = start_lease_worker(connection, origin)
    worker_monitor = Process.monitor(worker)

    assert {:ok, ^origin} =
             AdmissionRelay.open_lease_permit(
               relay,
               connection,
               origin,
               :session_acquire_control,
               "session",
               owner,
               owner_incarnation,
               worker,
               worker_incarnation
             )

    assert {:error, :invalid_actor} =
             AdmissionRelay.claim_lease_permit(relay, origin, owner_incarnation)

    assert :ok =
             invoke(owner, fn ->
               AdmissionRelay.claim_lease_permit(relay, origin, owner_incarnation)
             end)

    assert_receive {:lease_worker_go, ^worker, ^origin}, 500
    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, :normal}, 500

    result = %{"writer_epoch" => "epoch", "expires_in_ms" => 30_000, "renewed" => true}

    assert :ok =
             invoke(owner, fn ->
               AdmissionRelay.complete_lease_permit(
                 relay,
                 origin,
                 owner_incarnation,
                 result
               )
             end)

    assert_receive {:connection_message, ^connection, {:relay_permit_result, ^origin, ^result}},
                   500

    eventually(fn -> AdmissionRelay.status(relay).permits == 0 end)
    stop_connection(connection, relay, connection_incarnation)
  end

  # Concept: at the freeze, lease work not yet claimed is cancelled with a
  # correlated `daemon_stopping`, and executing lease work becomes the
  # barrier's own `shutdown_admitted` row: the owner's later result is
  # cleanup-only and reaches no client; nothing new can be claimed.
  #
  # Technical depth: one lease permit is claimed by its owner and executing,
  # a second is open but unclaimed. After the transport cut, the freeze barrier
  # names only the executing one, tagged with its class and exact actor; the
  # unclaimed one can no longer be claimed and settles by itself. The owner's
  # completion after the freeze is refused `daemon_stopping`, no
  # `relay_permit_result` reaches the connection, and both rows are terminal.
  test "the freeze admits executing lease work for shutdown and cancels unclaimed work" do
    relay = start_relay()
    registry = start_registry()
    assert :ok = AdmissionRelay.register_registry(relay, registry, incarnation())
    owner = start_actor()
    owner_incarnation = incarnation()
    assert :ok = AdmissionRelay.register_lease_owner(relay, "session", owner, owner_incarnation)

    connection_incarnation = incarnation()
    connection = start_connection(relay, connection_incarnation)
    executing = {connection_incarnation, 0, 1}
    unclaimed = {connection_incarnation, 1, 2}

    for origin <- [executing, unclaimed] do
      {worker, worker_incarnation} = start_lease_worker(connection, origin)

      assert {:ok, ^origin} =
               AdmissionRelay.open_lease_permit(
                 relay,
                 connection,
                 origin,
                 :session_acquire_control,
                 "session",
                 owner,
                 owner_incarnation,
                 worker,
                 worker_incarnation
               )
    end

    assert :ok =
             invoke(owner, fn ->
               AdmissionRelay.claim_lease_permit(relay, executing, owner_incarnation)
             end)

    cut = make_ref()
    send(relay, {:relay_barrier, cut, :cut})
    assert_receive {:relay_barrier_ack, ^cut, :cut, _payload}, 500

    freeze = make_ref()
    send(relay, {:relay_barrier, freeze, {:freeze_lease_ops, 0}})

    expected = [
      {:shutdown_admitted, executing, :session_acquire_control, owner, owner_incarnation, nil}
    ]

    assert_receive {:relay_barrier_ack, ^freeze, :freeze_lease_ops, ^expected}, 500

    assert_receive {:connection_message, ^connection,
                    {:relay_permit_cancelled, ^unclaimed, :daemon_stopping}},
                   500

    assert {:error, _refused} =
             invoke(owner, fn ->
               AdmissionRelay.claim_lease_permit(relay, unclaimed, owner_incarnation)
             end)

    assert {:error, :daemon_stopping} =
             invoke(owner, fn ->
               AdmissionRelay.complete_lease_permit(relay, executing, owner_incarnation, %{
                 "writer_epoch" => "epoch",
                 "expires_in_ms" => 30_000,
                 "renewed" => false
               })
             end)

    eventually(fn -> AdmissionRelay.pending_origins(relay, [executing, unclaimed]) == 0 end)

    refute_receive {:connection_message, ^connection,
                    {:relay_permit_result, ^executing, _result}},
                   40
  end

  # Concept: a lease row whose result, connection loss or owner loss was
  # selected before the freeze keeps that selection and is named in its exact
  # settling variant; a row the freeze wins is the barrier's own
  # `shutdown_admitted`. Every call returns the same fixed tagged set, and
  # nothing settled after the freeze reaches a client.
  #
  # Technical depth: on one connection an existing owner claims an acquire it
  # never completes, a release and an acquire whose daemon result selections
  # the relay consumed, and a second owner claims a release before it is
  # killed; on a second connection a claimed acquire loses its connection.
  # The freeze answer, and a repeat with the same reference, is compared with
  # the exact descriptors. Afterwards the first owner's late result is refused
  # `daemon_stopping`, the selected release settles without any
  # `relay_permit_result`, and the executing row is terminal.
  test "the freeze returns one tagged descriptor per lease row in its selected variant" do
    daemon_incarnation = incarnation()
    relay = start_relay(owner_incarnation: daemon_incarnation)
    registry = start_registry()
    assert :ok = AdmissionRelay.register_registry(relay, registry, incarnation())
    owner = start_actor()
    owner_incarnation = incarnation()
    lost_owner = start_actor()
    lost_incarnation = incarnation()
    assert :ok = AdmissionRelay.register_lease_owner(relay, "session", owner, owner_incarnation)

    assert :ok =
             AdmissionRelay.register_lease_owner(relay, "lost", lost_owner, lost_incarnation)

    connection_incarnation = incarnation()
    connection = start_connection(relay, connection_incarnation)
    lost_connection_incarnation = incarnation()
    lost_connection = start_connection(relay, lost_connection_incarnation)
    executing = {connection_incarnation, 0, 1}
    released = {connection_incarnation, 1, 1}
    granted = {connection_incarnation, 2, 1}
    owner_lost = {connection_incarnation, 3, 1}
    connection_lost = {lost_connection_incarnation, 0, 1}

    rows = [
      {executing, connection, :session_acquire_control, "session", owner, owner_incarnation},
      {released, connection, :session_release_control, "session", owner, owner_incarnation},
      {granted, connection, :session_acquire_control, "session", owner, owner_incarnation},
      {owner_lost, connection, :session_release_control, "lost", lost_owner, lost_incarnation},
      {connection_lost, lost_connection, :session_acquire_control, "session", owner,
       owner_incarnation}
    ]

    for {origin, row_connection, class, session_id, actor, actor_incarnation} <- rows do
      {worker, worker_incarnation} = start_lease_worker(row_connection, origin)

      assert {:ok, ^origin} =
               AdmissionRelay.open_lease_permit(
                 relay,
                 row_connection,
                 origin,
                 class,
                 session_id,
                 actor,
                 actor_incarnation,
                 worker,
                 worker_incarnation
               )

      assert :ok =
               invoke(actor, fn ->
                 AdmissionRelay.claim_lease_permit(relay, origin, actor_incarnation)
               end)

      assert_receive {:lease_worker_go, ^worker, ^origin}, 500
    end

    selections =
      for {origin, result} <- [{released, %{"released" => true}}, {granted, %{"granted" => 1}}] do
        settlement_ref = make_ref()
        selection_ref = make_ref()

        assert :ok =
                 AdmissionRelay.request_lease_result_selection(
                   relay,
                   selection_ref,
                   daemon_incarnation,
                   origin,
                   owner,
                   owner_incarnation,
                   settlement_ref,
                   result
                 )

        assert_receive {:relay_lease_operation_ack, ^selection_ref, ^relay, _, :select_result,
                        :ok},
                       500

        {origin, settlement_ref}
      end

    %{^released => release_ref, ^granted => grant_ref} = Map.new(selections)
    Process.exit(lost_connection, :kill)

    assert_receive {:relay_lease_disposition, ^relay, ^connection_lost, :connection_lost,
                    loss_ref, :session_acquire_control, "session", ^owner, ^owner_incarnation,
                    nil},
                   500

    Process.exit(lost_owner, :kill)

    assert_receive {:relay_owner_lost, ^relay, "lost", ^lost_owner, ^lost_incarnation,
                    [^owner_lost]},
                   500

    cut = make_ref()
    send(relay, {:relay_barrier, cut, :cut})
    assert_receive {:relay_barrier_ack, ^cut, :cut, _payload}, 500
    freeze = make_ref()
    send(relay, {:relay_barrier, freeze, {:freeze_lease_ops, 0}})

    expected =
      Enum.sort_by(
        [
          {:shutdown_admitted, executing, :session_acquire_control, owner, owner_incarnation,
           nil},
          {:settling_release, released, :result, owner, owner_incarnation, release_ref},
          {:settling_acquire, granted, :result, owner, owner_incarnation, nil, grant_ref},
          {:settling_owner_loss, owner_lost, :session_release_control, lost_owner,
           lost_incarnation, :owner_loss},
          {:settling_acquire, connection_lost, :connection_lost, owner, owner_incarnation, nil,
           loss_ref}
        ],
        &elem(&1, 1)
      )

    assert_receive {:relay_barrier_ack, ^freeze, :freeze_lease_ops, ^expected}, 500
    send(relay, {:relay_barrier, freeze, {:freeze_lease_ops, 0}})
    assert_receive {:relay_barrier_ack, ^freeze, :freeze_lease_ops, ^expected}, 500

    assert {:error, :daemon_stopping} =
             invoke(owner, fn ->
               AdmissionRelay.complete_lease_permit(relay, executing, owner_incarnation, %{
                 "renewed" => true
               })
             end)

    settle_ref = make_ref()

    assert :ok =
             AdmissionRelay.request_lease_result_settlement(
               relay,
               settle_ref,
               daemon_incarnation,
               released,
               release_ref
             )

    assert_receive {:relay_lease_operation_ack, ^settle_ref, ^relay, _, :settle_result, :ok},
                   500

    eventually(fn -> AdmissionRelay.pending_origins(relay, [executing, released]) == 0 end)

    refute_receive {:connection_message, ^connection, {:relay_permit_result, _origin, _result}},
                   40
  end

  test "a fresh acquisition is bound to the daemon actor and start reference" do
    daemon_incarnation = incarnation()
    relay = start_relay(owner_incarnation: daemon_incarnation)
    connection_incarnation = incarnation()
    connection = start_connection(relay, connection_incarnation)
    origin = {connection_incarnation, 0, 1}
    start_op_ref = make_ref()
    {worker, worker_incarnation} = start_lease_worker(connection, origin)

    assert {:error, :invalid_actor} =
             AdmissionRelay.open_lease_permit(
               relay,
               connection,
               origin,
               :session_acquire_control,
               "session",
               self(),
               incarnation(),
               worker,
               worker_incarnation,
               make_ref()
             )

    assert {:ok, ^origin} =
             AdmissionRelay.open_lease_permit(
               relay,
               connection,
               origin,
               :session_acquire_control,
               "session",
               self(),
               daemon_incarnation,
               worker,
               worker_incarnation,
               start_op_ref
             )

    assert {:error, :invalid_actor} =
             AdmissionRelay.claim_lease_permit(
               relay,
               origin,
               daemon_incarnation,
               make_ref()
             )

    assert :ok =
             AdmissionRelay.claim_lease_permit(
               relay,
               origin,
               daemon_incarnation,
               start_op_ref
             )

    assert_receive {:lease_worker_go, ^worker, ^origin}, 500

    result = %{"writer_epoch" => "fresh", "expires_in_ms" => 30_000}

    assert :ok =
             AdmissionRelay.complete_lease_permit(
               relay,
               origin,
               daemon_incarnation,
               result
             )

    assert_receive {:connection_message, ^connection, {:relay_permit_result, ^origin, ^result}},
                   500

    eventually(fn -> AdmissionRelay.status(relay).permits == 0 end)
    stop_connection(connection, relay, connection_incarnation)
  end

  test "connection loss selects one retained lease disposition" do
    daemon_incarnation = incarnation()
    relay = start_relay(owner_incarnation: daemon_incarnation)
    owner = start_actor()
    owner_incarnation = incarnation()

    assert :ok =
             AdmissionRelay.register_lease_owner(
               relay,
               "session",
               owner,
               owner_incarnation
             )

    connection_incarnation = incarnation()
    connection = start_connection(relay, connection_incarnation)
    origin = {connection_incarnation, 0, 1}
    {worker, worker_incarnation} = start_lease_worker(connection, origin, :hold)
    worker_monitor = Process.monitor(worker)

    assert {:ok, ^origin} =
             AdmissionRelay.open_lease_permit(
               relay,
               connection,
               origin,
               :session_release_control,
               "session",
               owner,
               owner_incarnation,
               worker,
               worker_incarnation
             )

    connection_monitor = Process.monitor(connection)
    Process.exit(connection, :kill)
    assert_receive {:DOWN, ^connection_monitor, :process, ^connection, :killed}, 500

    assert_receive {:relay_lease_disposition, ^relay, ^origin, :connection_lost, settlement_ref,
                    :session_release_control, "session", ^owner, ^owner_incarnation, nil},
                   500

    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, worker_reason}, 500
    assert worker_reason in [:normal, :killed]

    assert {:error, :permit_unavailable} =
             AdmissionRelay.settle_lease_disposition(
               relay,
               origin,
               :connection_lost,
               make_ref()
             )

    operation_ref = make_ref()

    assert :ok =
             AdmissionRelay.request_lease_disposition_settlement(
               relay,
               operation_ref,
               daemon_incarnation,
               origin,
               :connection_lost,
               settlement_ref
             )

    assert_receive {:relay_lease_operation_ack, ^operation_ref, ^relay, ^daemon_incarnation,
                    :settle_disposition, :ok},
                   500

    assert_receive {:relay_connection_retired, ^relay, ^connection_incarnation}, 500
  end

  test "lease owner loss claims actor-bound permits with mutation origins" do
    daemon_incarnation = incarnation()
    relay = start_relay(owner_incarnation: daemon_incarnation)
    owner = start_actor()
    owner_incarnation = incarnation()
    binding = {owner, owner_incarnation}

    assert :ok =
             AdmissionRelay.register_lease_owner(
               relay,
               "session",
               owner,
               owner_incarnation
             )

    connection_incarnation = incarnation()
    connection = start_connection(relay, connection_incarnation)
    permit_origin = {connection_incarnation, 0, 1}
    ticket_origin = {connection_incarnation, 1, 1}
    {worker, worker_incarnation} = start_lease_worker(connection, permit_origin, :hold)
    worker_monitor = Process.monitor(worker)

    assert {:ok, ^permit_origin} =
             AdmissionRelay.open_lease_permit(
               relay,
               connection,
               permit_origin,
               :session_release_control,
               "session",
               owner,
               owner_incarnation,
               worker,
               worker_incarnation
             )

    assert {:ok, ^ticket_origin} =
             invoke(connection, fn ->
               AdmissionRelay.open_ticket(
                 relay,
                 ticket_origin,
                 :session_prompt,
                 "session",
                 binding
               )
             end)

    Process.exit(owner, :kill)

    assert_receive {:relay_owner_lost, ^relay, "session", ^owner, ^owner_incarnation, origins},
                   500

    assert origins == [permit_origin, ticket_origin]
    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, :killed}, 500
    assert_receive {:relay_owner_loss_ready, ^relay, ^owner, ^owner_incarnation}, 500

    classification_ref = make_ref()

    assert :ok =
             AdmissionRelay.classify_owner_loss(
               relay,
               classification_ref,
               daemon_incarnation,
               "session",
               owner,
               owner_incarnation,
               nil
             )

    assert_receive {:connection_message, ^connection,
                    {:relay_permit_cancelled, ^permit_origin, :control_owner_lost}},
                   500

    assert_receive {:connection_message, ^connection,
                    {:relay_ticket_cancelled, ^ticket_origin, :control_owner_lost}},
                   500

    assert_receive {:relay_owner_loss_classified_ack, ^relay, ^classification_ref, "session",
                    ^owner, ^owner_incarnation},
                   500

    assert %{owner_losses: 0, permits: 0, tickets: 0} = AdmissionRelay.status(relay)
    stop_connection(connection, relay, connection_incarnation)
  end

  # Concept: after the admission cut ordinary owner-loss notification stops:
  # a claimed origin still joins the exact classification and is terminal,
  # but no correlated `control_owner_lost` refusal reaches its connection.
  #
  # Technical depth: a pending mutation origin is bound to the owner before
  # the cut; the owner is killed after it, the relay claims the origin, and
  # the daemon's classification is acknowledged with the origin removed and
  # nothing sent to the connection.
  test "an owner loss after the cut claims its origins without a correlated refusal" do
    daemon_incarnation = incarnation()
    relay = start_relay(owner_incarnation: daemon_incarnation)
    registry = start_registry()
    assert :ok = AdmissionRelay.register_registry(relay, registry, incarnation())
    owner = start_actor()
    owner_incarnation = incarnation()
    assert :ok = AdmissionRelay.register_lease_owner(relay, "session", owner, owner_incarnation)
    connection_incarnation = incarnation()
    connection = start_connection(relay, connection_incarnation)
    origin = {connection_incarnation, 0, 1}

    assert {:ok, ^origin} =
             invoke(connection, fn ->
               AdmissionRelay.open_ticket(
                 relay,
                 origin,
                 :session_prompt,
                 "session",
                 {owner, owner_incarnation}
               )
             end)

    cut = make_ref()
    send(relay, {:relay_barrier, cut, :cut})
    assert_receive {:relay_barrier_ack, ^cut, :cut, _payload}, 500
    Process.exit(owner, :kill)

    assert_receive {:relay_owner_lost, ^relay, "session", ^owner, ^owner_incarnation, [^origin]},
                   500

    classification_ref = make_ref()

    assert :ok =
             AdmissionRelay.classify_owner_loss(
               relay,
               classification_ref,
               daemon_incarnation,
               "session",
               owner,
               owner_incarnation,
               nil
             )

    assert_receive {:relay_owner_loss_classified_ack, ^relay, ^classification_ref, "session",
                    ^owner, ^owner_incarnation},
                   500

    assert %{owner_losses: 0, tickets: 0} = AdmissionRelay.status(relay)

    refute_receive {:connection_message, ^connection,
                    {:relay_ticket_cancelled, ^origin, :control_owner_lost}},
                   40
  end

  test "an idle lease owner retires through its exact monitored down" do
    relay = start_relay()
    owner = start_actor()
    owner_incarnation = incarnation()

    assert :ok =
             AdmissionRelay.register_lease_owner(
               relay,
               "retiring-session",
               owner,
               owner_incarnation
             )

    assert :ok =
             invoke(owner, fn ->
               AdmissionRelay.prepare_lease_owner_retirement(
                 relay,
                 "retiring-session",
                 owner_incarnation
               )
             end)

    assert %{lease_owners: 1, retiring_lease_owners: 1, owner_losses: 0} =
             AdmissionRelay.status(relay)

    connection_incarnation = incarnation()
    connection = start_connection(relay, connection_incarnation)
    origin = {connection_incarnation, 0, 1}
    {worker, worker_incarnation} = start_lease_worker(connection, origin)

    assert {:error, :invalid_actor} =
             AdmissionRelay.open_lease_permit(
               relay,
               connection,
               origin,
               :session_acquire_control,
               "retiring-session",
               owner,
               owner_incarnation,
               worker,
               worker_incarnation
             )

    assert {:error, :invalid_origin} =
             invoke(connection, fn ->
               AdmissionRelay.open_ticket(
                 relay,
                 origin,
                 :session_prompt,
                 "retiring-session",
                 {owner, owner_incarnation}
               )
             end)

    stop_connection(connection, relay, connection_incarnation)

    owner_monitor = Process.monitor(owner)
    send(owner, :stop_normal)
    assert_receive {:DOWN, ^owner_monitor, :process, ^owner, :normal}, 500

    assert_receive {:relay_owner_retirement_complete, ^relay, "retiring-session", ^owner,
                    ^owner_incarnation},
                   500

    refute_receive {:relay_owner_lost, ^relay, _, ^owner, ^owner_incarnation, _}, 40

    assert %{lease_owners: 0, retiring_lease_owners: 0, owner_losses: 0} =
             AdmissionRelay.status(relay)
  end

  test "retirement waits for the session's final relay row and then wakes the owner" do
    relay = start_relay()
    owner = start_actor()
    owner_incarnation = incarnation()

    assert :ok =
             AdmissionRelay.register_lease_owner(
               relay,
               "busy-session",
               owner,
               owner_incarnation
             )

    connection_incarnation = incarnation()
    connection = start_connection(relay, connection_incarnation)
    origin = {connection_incarnation, 0, 1}

    assert {:ok, ^origin} =
             invoke(connection, fn ->
               AdmissionRelay.open_ticket(
                 relay,
                 origin,
                 :session_prompt,
                 "busy-session",
                 {owner, owner_incarnation}
               )
             end)

    assert {:error, :owner_busy} =
             invoke(owner, fn ->
               AdmissionRelay.prepare_lease_owner_retirement(
                 relay,
                 "busy-session",
                 owner_incarnation
               )
             end)

    connection_monitor = Process.monitor(connection)
    Process.exit(connection, :kill)
    assert_receive {:DOWN, ^connection_monitor, :process, ^connection, :killed}, 500
    assert_receive {:relay_connection_retired, ^relay, ^connection_incarnation}, 500

    assert_receive {:registry_message, ^owner, {:relay_owner_idle, ^relay, ^owner_incarnation}},
                   500

    assert :ok =
             invoke(owner, fn ->
               AdmissionRelay.prepare_lease_owner_retirement(
                 relay,
                 "busy-session",
                 owner_incarnation
               )
             end)

    send(owner, :stop_normal)

    assert_receive {:relay_owner_retirement_complete, ^relay, "busy-session", ^owner,
                    ^owner_incarnation},
                   500
  end

  test "an authenticated asynchronous lease result wins a later connection loss" do
    daemon_incarnation = incarnation()
    relay = start_relay(owner_incarnation: daemon_incarnation)
    owner = start_actor()
    owner_incarnation = incarnation()

    assert :ok =
             AdmissionRelay.register_lease_owner(
               relay,
               "session",
               owner,
               owner_incarnation
             )

    connection_incarnation = incarnation()
    connection = start_connection(relay, connection_incarnation)
    origin = {connection_incarnation, 0, 1}
    {worker, worker_incarnation} = start_lease_worker(connection, origin)
    worker_monitor = Process.monitor(worker)

    assert {:ok, ^origin} =
             AdmissionRelay.open_lease_permit(
               relay,
               connection,
               origin,
               :session_release_control,
               "session",
               owner,
               owner_incarnation,
               worker,
               worker_incarnation
             )

    assert :ok =
             invoke(owner, fn ->
               AdmissionRelay.claim_lease_permit(relay, origin, owner_incarnation)
             end)

    assert_receive {:lease_worker_go, ^worker, ^origin}, 500
    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, :normal}, 500

    settlement_ref = make_ref()
    result = %{"released" => true}
    stale_ref = make_ref()

    assert :ok =
             AdmissionRelay.request_lease_result_selection(
               relay,
               stale_ref,
               incarnation(),
               origin,
               owner,
               owner_incarnation,
               settlement_ref,
               result
             )

    refute_receive {:relay_lease_operation_ack, ^stale_ref, _, _, _, _}, 40

    foreign_ref = make_ref()

    assert :ok =
             invoke(owner, fn ->
               AdmissionRelay.request_lease_result_selection(
                 relay,
                 foreign_ref,
                 daemon_incarnation,
                 origin,
                 owner,
                 owner_incarnation,
                 settlement_ref,
                 result
               )
             end)

    refute_receive {:registry_message, ^owner,
                    {:relay_lease_operation_ack, ^foreign_ref, _, _, _, _}},
                   40

    selection_ref = make_ref()

    assert :ok =
             AdmissionRelay.request_lease_result_selection(
               relay,
               selection_ref,
               daemon_incarnation,
               origin,
               owner,
               owner_incarnation,
               settlement_ref,
               result
             )

    assert_receive {:relay_lease_operation_ack, ^selection_ref, ^relay, ^daemon_incarnation,
                    :select_result, :ok},
                   500

    connection_monitor = Process.monitor(connection)
    Process.exit(connection, :kill)
    assert_receive {:DOWN, ^connection_monitor, :process, ^connection, :killed}, 500

    refute_receive {:relay_lease_disposition, ^relay, ^origin, :connection_lost, _, _, _, _, _,
                    _},
                   40

    settle_ref = make_ref()

    assert :ok =
             AdmissionRelay.request_lease_result_settlement(
               relay,
               settle_ref,
               daemon_incarnation,
               origin,
               settlement_ref
             )

    assert_receive {:relay_lease_operation_ack, ^settle_ref, ^relay, ^daemon_incarnation,
                    :settle_result, :ok},
                   500

    assert_receive {:relay_connection_retired, ^relay, ^connection_incarnation}, 500
  end

  # Concept: acquire and release permits opened before the cut and claimed
  # immediately before it, or after it but before the admission deadline, are
  # executing when a freeze arrives ahead of the deadline timer; the freeze
  # wins each of them as a `shutdown_admitted` row, cancels only the unclaimed
  # row, returns the same tagged set when repeated, and the stale timer
  # cancels nothing later.
  #
  # Technical depth: the claims run inside the frozen-origin window, so each
  # worker starts; the freeze cancels the deadline timer, expires the one
  # pending row as the deadline would, and its descriptors carry each exact
  # class and actor. The rows are terminal once their workers are reaped.
  test "claims before the admission deadline survive a freeze ahead of the timer" do
    %{relay: relay, connection: connection, claim: claim, origins: origins, owner: owner} =
      lease_rows_across_the_cut(300)

    %{pre_cut: pre_cut, acquire: acquire, release: release, unclaimed: unclaimed} = origins
    assert :ok = claim.(acquire)
    assert :ok = claim.(release)
    assert_receive {:lease_worker_go, _acquire_worker, ^acquire}, 500
    assert_receive {:lease_worker_go, _release_worker, ^release}, 500

    freeze = make_ref()
    send(relay, {:relay_barrier, freeze, {:freeze_lease_ops, 0}})
    expected = admitted_descriptors(origins, owner)
    assert_receive {:relay_barrier_ack, ^freeze, :freeze_lease_ops, ^expected}, 500
    send(relay, {:relay_barrier, freeze, {:freeze_lease_ops, 0}})
    assert_receive {:relay_barrier_ack, ^freeze, :freeze_lease_ops, ^expected}, 500

    assert_receive {:connection_message, ^connection,
                    {:relay_permit_cancelled, ^unclaimed, :daemon_stopping}},
                   500

    refute_receive {:connection_message, ^connection,
                    {:relay_permit_cancelled, _claimed, :daemon_stopping}},
                   400

    eventually(fn -> AdmissionRelay.pending_origins(relay, [pre_cut, acquire, release]) == 0 end)
    assert %{phase: :lease_ops_frozen, executing: 0} = AdmissionRelay.status(relay)
  end

  # Concept: when the admission deadline timer fires before the freeze, it
  # cancels only the unclaimed row; a claim after the deadline is refused, and
  # the later freeze still wins every claim made before the deadline.
  #
  # Technical depth: the timer's expiry is observed through the unclaimed
  # row's `daemon_stopping` refusal; the late claim runs against the expired
  # row, which is already terminal and therefore not named by the freeze.
  test "claims before the admission deadline survive a freeze after the timer" do
    %{relay: relay, connection: connection, claim: claim, origins: origins, owner: owner} =
      lease_rows_across_the_cut(200)

    %{pre_cut: pre_cut, acquire: acquire, release: release, unclaimed: unclaimed} = origins
    assert :ok = claim.(acquire)
    assert :ok = claim.(release)

    assert_receive {:connection_message, ^connection,
                    {:relay_permit_cancelled, ^unclaimed, :daemon_stopping}},
                   500

    assert {:error, _refused} = claim.(unclaimed)

    freeze = make_ref()
    send(relay, {:relay_barrier, freeze, {:freeze_lease_ops, 0}})
    assert_receive {:relay_barrier_ack, ^freeze, :freeze_lease_ops, descriptors}, 500
    assert descriptors == admitted_descriptors(origins, owner)

    refute_receive {:connection_message, ^connection,
                    {:relay_permit_cancelled, _claimed, :daemon_stopping}},
                   40

    eventually(fn -> AdmissionRelay.pending_origins(relay, [pre_cut, acquire, release]) == 0 end)
    assert %{phase: :lease_ops_frozen, executing: 0} = AdmissionRelay.status(relay)
  end

  defp admitted_descriptors(origins, {owner, owner_incarnation}) do
    [
      {:shutdown_admitted, origins.pre_cut, :session_acquire_control, owner, owner_incarnation,
       nil},
      {:shutdown_admitted, origins.acquire, :session_acquire_control, owner, owner_incarnation,
       nil},
      {:shutdown_admitted, origins.release, :session_release_control, owner, owner_incarnation,
       nil}
    ]
    |> Enum.sort_by(&elem(&1, 1))
  end

  # Concept: four lease permits straddle the admission cut: an acquire
  # claimed immediately before it, and an acquire, a release and an acquire
  # that are still pending when it is taken. Technical depth: the cut payload
  # is asserted to freeze exactly those phases; `claim` claims as the
  # registered lease owner.
  defp lease_rows_across_the_cut(admission_wait_ms) do
    relay = start_relay(admission_wait_ms: admission_wait_ms)
    registry = start_registry()
    assert :ok = AdmissionRelay.register_registry(relay, registry, incarnation())
    owner = start_actor()
    owner_incarnation = incarnation()
    assert :ok = AdmissionRelay.register_lease_owner(relay, "session", owner, owner_incarnation)
    connection_incarnation = incarnation()
    connection = start_connection(relay, connection_incarnation)

    origins = %{
      pre_cut: {connection_incarnation, 0, 1},
      acquire: {connection_incarnation, 1, 1},
      release: {connection_incarnation, 2, 1},
      unclaimed: {connection_incarnation, 3, 1}
    }

    classes = %{
      pre_cut: :session_acquire_control,
      acquire: :session_acquire_control,
      release: :session_release_control,
      unclaimed: :session_acquire_control
    }

    for {name, origin} <- origins do
      {worker, worker_incarnation} = start_lease_worker(connection, origin)

      assert {:ok, ^origin} =
               AdmissionRelay.open_lease_permit(
                 relay,
                 connection,
                 origin,
                 Map.fetch!(classes, name),
                 "session",
                 owner,
                 owner_incarnation,
                 worker,
                 worker_incarnation
               )
    end

    claim = fn origin ->
      invoke(owner, fn ->
        AdmissionRelay.claim_lease_permit(relay, origin, owner_incarnation)
      end)
    end

    assert :ok = claim.(origins.pre_cut)
    pre_cut = origins.pre_cut
    assert_receive {:lease_worker_go, _pre_cut_worker, ^pre_cut}, 500

    cut = make_ref()
    send(relay, {:relay_barrier, cut, :cut})
    assert_receive {:relay_barrier_ack, ^cut, :cut, payload}, 500

    assert payload.permits == [
             {origins.pre_cut, :executing},
             {origins.acquire, :pending},
             {origins.release, :pending},
             {origins.unclaimed, :pending}
           ]

    %{
      relay: relay,
      connection: connection,
      claim: claim,
      origins: origins,
      owner: {owner, owner_incarnation}
    }
  end

  defp start_relay(options \\ []) do
    options =
      Keyword.merge(
        [owner: self(), owner_incarnation: incarnation(), admission_wait_ms: 1_000],
        options
      )

    start_supervised!({AdmissionRelay, options})
  end

  defp start_connection(relay, incarnation) do
    parent = self()

    connection =
      spawn(fn ->
        result = AdmissionRelay.register_connection(relay, incarnation, parent)
        send(parent, {:connection_registered, self(), result})
        connection_loop(parent)
      end)

    assert_receive {:connection_registered, ^connection, :ok}, 500
    connection
  end

  defp start_registry do
    parent = self()
    spawn_link(fn -> registry_loop(parent) end)
  end

  defp start_actor do
    parent = self()
    spawn(fn -> registry_loop(parent) end)
  end

  defp registry_loop(parent) do
    receive do
      :stop_normal ->
        :ok

      {:invoke, caller, reference, operation} ->
        send(caller, {:invoked, reference, operation.()})
        registry_loop(parent)

      message ->
        send(parent, {:registry_message, self(), message})
        registry_loop(parent)
    end
  end

  defp connection_loop(parent) do
    receive do
      {:invoke, caller, reference, operation} ->
        send(caller, {:invoked, reference, operation.()})
        connection_loop(parent)

      message ->
        send(parent, {:connection_message, self(), message})
        connection_loop(parent)
    end
  end

  defp invoke(connection, operation) do
    reference = make_ref()
    send(connection, {:invoke, self(), reference, operation})

    receive do
      {:invoked, ^reference, result} -> result
    after
      1_000 -> flunk("connection invocation did not answer")
    end
  end

  defp start_worker(relay, connection, origin, mode \\ :exit_after_result) do
    parent = self()
    worker_incarnation = incarnation()

    worker =
      spawn(fn ->
        connection_monitor = Process.monitor(connection)
        send(parent, {:worker_ready, self(), connection_monitor})

        receive do
          {:relay_go, ^origin, ^worker_incarnation} ->
            send(parent, {:worker_go, self(), origin})
            worker_completion_loop(parent, relay, origin, worker_incarnation, mode)

          {:DOWN, ^connection_monitor, :process, ^connection, _reason} ->
            :ok
        end
      end)

    assert_receive {:worker_ready, ^worker, _monitor}, 500
    {worker, worker_incarnation}
  end

  defp start_ticket_worker(connection) do
    parent = self()

    worker =
      spawn(fn ->
        connection_monitor = Process.monitor(connection)
        send(parent, {:ticket_worker_ready, self()})
        ticket_worker_loop(parent, connection, connection_monitor)
      end)

    assert_receive {:ticket_worker_ready, ^worker}, 500
    worker
  end

  defp start_lease_worker(connection, origin, mode \\ :exit) do
    parent = self()
    worker_incarnation = incarnation()

    worker =
      spawn(fn ->
        connection_monitor = Process.monitor(connection)
        send(parent, {:lease_worker_ready, self()})

        receive do
          {:relay_go, ^origin, ^worker_incarnation} ->
            send(parent, {:lease_worker_go, self(), origin})

            if mode == :hold do
              receive do
                :finish -> :ok
              end
            end

          {:DOWN, ^connection_monitor, :process, ^connection, _reason} ->
            :ok
        end
      end)

    assert_receive {:lease_worker_ready, ^worker}, 500
    {worker, worker_incarnation}
  end

  defp ticket_worker_loop(parent, connection, connection_monitor) do
    receive do
      {:DOWN, ^connection_monitor, :process, ^connection, _reason} ->
        :ok

      message ->
        send(parent, {:ticket_worker_message, self(), message})
        ticket_worker_loop(parent, connection, connection_monitor)
    end
  end

  defp worker_completion_loop(parent, relay, origin, worker_incarnation, mode) do
    receive do
      {:complete, result} ->
        completion =
          AdmissionRelay.complete_permit(
            relay,
            origin,
            worker_incarnation,
            result
          )

        send(parent, {:worker_complete, self(), completion})

        case {completion, mode} do
          {:ok, :hold_after_result} ->
            receive do
              :finish -> :ok
            end

          {:ok, :exit_after_result} ->
            :ok

          {{:error, _reason}, _mode} ->
            worker_completion_loop(parent, relay, origin, worker_incarnation, mode)
        end
    end
  end

  defp stop_connection(connection, relay, incarnation) do
    monitor = Process.monitor(connection)
    Process.exit(connection, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^connection, :killed}, 500
    assert_receive {:relay_connection_retired, ^relay, ^incarnation}, 500
  end

  defp incarnation, do: :crypto.strong_rand_bytes(16)

  defp eventually(fun, attempts \\ 100)
  defp eventually(fun, 0), do: assert(fun.())

  defp eventually(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(5)
      eventually(fun, attempts - 1)
    end
  end
end
