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
        executing: 0,
        settling: 0,
        connection_limit: 512,
        origin_limit: 16_384,
        admission_deadline_set: false
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

  defp start_relay(options \\ []) do
    options = Keyword.merge([owner: self(), admission_wait_ms: 1_000], options)
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
