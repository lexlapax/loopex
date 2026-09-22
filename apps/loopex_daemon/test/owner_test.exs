defmodule LoopexDaemon.OwnerTest do
  use ExUnit.Case, async: true
  @moduletag capture_log: true

  alias LoopexDaemon.{AdmissionRelay, ConnectionRegistry, LeaseOwner, Owner}

  defmodule ManualConnection do
    def start_link(options) do
      listener = Keyword.fetch!(options, :listener)

      pid =
        spawn_link(fn ->
          send(listener, {:manual_connection_started, self(), options})
          loop(listener, options)
        end)

      {:ok, pid}
    end

    defp loop(parent, options) do
      receive do
        {:manual_call, caller, reference, :promote} ->
          result =
            ConnectionRegistry.promote(
              Keyword.fetch!(options, :registry),
              Keyword.fetch!(options, :rollback_token),
              Keyword.fetch!(options, :connection_incarnation)
            )

          send(caller, {:manual_result, reference, result})
          loop(parent, options)

        {:manual_call, caller, reference, :initialize} ->
          result =
            ConnectionRegistry.initialize_complete(
              Keyword.fetch!(options, :registry),
              Keyword.fetch!(options, :rollback_token),
              Keyword.fetch!(options, :connection_incarnation)
            )

          send(caller, {:manual_result, reference, result})
          loop(parent, options)

        {:manual_call, caller, reference, {:register_relay, relay, recipient}} ->
          result =
            AdmissionRelay.register_connection(
              relay,
              Keyword.fetch!(options, :connection_incarnation),
              recipient
            )

          send(caller, {:manual_result, reference, result})
          loop(parent, options)

        {:connection_abort, _token, _reason} ->
          :ok

        message ->
          send(parent, {:manual_connection_message, self(), message})
          loop(parent, options)
      end
    end
  end

  test "the fixed owner publishes a grant before delivery and clears it before release" do
    owner = start_owner()
    components = Owner.components(owner)
    connection = initialized_connection(components)

    acquire_origin = {connection.incarnation, 0, 1}

    {acquire_worker, acquire_worker_incarnation} =
      start_worker(connection.pid, acquire_origin)

    assert {:ok, :proposed, lease_owner, owner_incarnation} =
             Owner.acquire_control(
               owner,
               acquire_origin,
               "acquire-1",
               "session",
               connection.pid,
               connection.incarnation,
               acquire_worker,
               acquire_worker_incarnation,
               now_ms() + 1_000
             )

    assert_receive {:worker_go, ^acquire_worker, ^acquire_origin}, 500

    assert_receive {:manual_connection_message, connection_pid,
                    {:relay_permit_result, ^acquire_origin, acquire_result}},
                   500

    assert connection_pid == connection.pid
    assert acquire_result["method"] == "session.acquire_control"
    writer_epoch = Base.url_decode64!(acquire_result["result"]["writer_epoch"], padding: false)

    assert %{granted_routes: 1, lease_operations: 0, mirror_operations: 0} =
             wait_for_owner_settlement(owner)

    assert %{phase: :held, held: true} = LeaseOwner.status(lease_owner)

    assert %{granted_routing_mirrors: 1, provisional_routing_mirrors: 0} =
             ConnectionRegistry.status(components.registry)

    refused_origin = {connection.incarnation, 1, 1}

    {refused_worker, refused_worker_incarnation} =
      start_worker(connection.pid, refused_origin)

    assert {:ok, :completed, ^lease_owner, ^owner_incarnation} =
             Owner.release_control(
               owner,
               refused_origin,
               "release-refused",
               "session",
               connection.pid,
               connection.incarnation,
               refused_worker,
               refused_worker_incarnation,
               incarnation(),
               now_ms() + 1_000
             )

    assert_receive {:manual_connection_message, ^connection_pid,
                    {:relay_permit_result, ^refused_origin, refused_result}},
                   500

    assert refused_result["code"] == "control_not_held"
    assert %{phase: :held, held: true} = LeaseOwner.status(lease_owner)

    release_origin = {connection.incarnation, 2, 1}

    {release_worker, release_worker_incarnation} =
      start_worker(connection.pid, release_origin)

    assert {:ok, :proposed, ^lease_owner, ^owner_incarnation} =
             Owner.release_control(
               owner,
               release_origin,
               "release-1",
               "session",
               connection.pid,
               connection.incarnation,
               release_worker,
               release_worker_incarnation,
               writer_epoch,
               now_ms() + 1_000
             )

    assert_receive {:worker_go, ^release_worker, ^release_origin}, 500

    assert_receive {:manual_connection_message, ^connection_pid,
                    {:relay_permit_result, ^release_origin, release_result}},
                   500

    assert release_result == %{
             "method" => "session.release_control",
             "request_id" => "release-1",
             "result" => %{"released" => true},
             "type" => "result"
           }

    assert %{
             granted_routes: 0,
             lease_operations: 0,
             mirror_operations: 0,
             owner_slots: 0,
             retiring_owners: 0
           } =
             wait_for_owner_retirement(owner)

    refute Process.alive?(lease_owner)
    assert %{routing_mirrors: 0} = ConnectionRegistry.status(components.registry)

    assert %{lease_owners: 0, retiring_lease_owners: 0} =
             AdmissionRelay.status(components.relay)

    successor_origin = {connection.incarnation, 3, 1}

    {successor_worker, successor_worker_incarnation} =
      start_worker(connection.pid, successor_origin)

    assert {:ok, :proposed, successor, successor_incarnation} =
             Owner.acquire_control(
               owner,
               successor_origin,
               "acquire-2",
               "session",
               connection.pid,
               connection.incarnation,
               successor_worker,
               successor_worker_incarnation,
               now_ms() + 1_000
             )

    refute successor == lease_owner
    refute successor_incarnation == owner_incarnation
    assert_receive {:worker_go, ^successor_worker, ^successor_origin}, 500

    assert_receive {:manual_connection_message, ^connection_pid,
                    {:relay_permit_result, ^successor_origin, successor_result}},
                   500

    successor_epoch =
      Base.url_decode64!(successor_result["result"]["writer_epoch"], padding: false)

    refute successor_epoch == writer_epoch

    assert %{owner_slots: 1, live_owners: 1, granted_routes: 1} =
             wait_for_owner_settlement(owner)
  end

  @tag timeout: 120_000
  test "a same-session successor inherits a freed slot while an unrelated 513th owner is refused" do
    owner = start_owner(retirement_pop_gate: self(), retirement_exit_gate: self())
    components = Owner.components(owner)
    connection = initialized_connection(components)

    owners =
      for sequence <- 1..512 do
        origin = {connection.incarnation, 0, sequence}
        session_id = "capacity-#{sequence}"
        {worker, worker_incarnation} = start_worker(connection.pid, origin)

        assert {:ok, :proposed, lease_owner, owner_incarnation} =
                 Owner.acquire_control(
                   owner,
                   origin,
                   "acquire-#{sequence}",
                   session_id,
                   connection.pid,
                   connection.incarnation,
                   worker,
                   worker_incarnation,
                   now_ms() + 5_000
                 )

        assert_receive {:worker_go, ^worker, ^origin}, 500

        assert_receive {:manual_connection_message, _, {:relay_permit_result, ^origin, result}},
                       500

        epoch = Base.url_decode64!(result["result"]["writer_epoch"], padding: false)
        {session_id, lease_owner, owner_incarnation, epoch}
      end

    assert %{owner_slots: 512, live_owners: 512, waiting_owner_starts: 0} =
             wait_for_owner_settlement(owner, 200)

    [{session_id, predecessor, predecessor_incarnation, predecessor_epoch} | _rest] = owners
    release_origin = {connection.incarnation, 0, 513}
    {release_worker, release_worker_incarnation} = start_worker(connection.pid, release_origin)

    assert {:ok, :proposed, ^predecessor, ^predecessor_incarnation} =
             Owner.release_control(
               owner,
               release_origin,
               "release-capacity-1",
               session_id,
               connection.pid,
               connection.incarnation,
               release_worker,
               release_worker_incarnation,
               predecessor_epoch,
               now_ms() + 5_000
             )

    assert_receive {:worker_go, ^release_worker, ^release_origin}, 500

    assert_receive {:manual_connection_message, _,
                    {:relay_permit_result, ^release_origin, _release_result}},
                   500

    assert_receive {:retirement_exit_blocked, ^predecessor, ^predecessor_incarnation,
                    retirement_ref},
                   500

    assert %{
             owner_slots: 512,
             live_owners: 511,
             retiring_owners: 1,
             waiting_owner_starts: 0,
             mirror_operations: 0
           } = Owner.status(owner)

    assert Process.alive?(predecessor)

    successor_origin = {connection.incarnation, 0, 514}

    {successor_worker, successor_worker_incarnation} =
      start_worker(connection.pid, successor_origin)

    successor_deadline = now_ms() + 5_000

    assert {:ok, :queued, ^owner, _daemon_incarnation} =
             Owner.acquire_control(
               owner,
               successor_origin,
               "acquire-successor",
               session_id,
               connection.pid,
               connection.incarnation,
               successor_worker,
               successor_worker_incarnation,
               successor_deadline
             )

    assert_receive {:worker_go, ^successor_worker, ^successor_origin}, 500

    assert {:ok, :queued, ^owner, _daemon_incarnation} =
             Owner.acquire_control(
               owner,
               successor_origin,
               "acquire-successor",
               session_id,
               connection.pid,
               connection.incarnation,
               successor_worker,
               successor_worker_incarnation,
               successor_deadline
             )

    assert %{
             owner_slots: 512,
             live_owners: 511,
             retiring_owners: 1,
             waiting_owner_starts: 1
           } = Owner.status(owner)

    unrelated_origin = {connection.incarnation, 0, 515}

    {unrelated_worker, unrelated_worker_incarnation} =
      start_worker(connection.pid, unrelated_origin)

    assert {:error, :control_capacity_reached} =
             Owner.acquire_control(
               owner,
               unrelated_origin,
               "acquire-unrelated",
               "capacity-513",
               connection.pid,
               connection.incarnation,
               unrelated_worker,
               unrelated_worker_incarnation,
               now_ms() + 5_000
             )

    refute_receive {:worker_go, ^unrelated_worker, ^unrelated_origin}, 20

    refute_receive {:manual_connection_message, _, {:relay_permit_result, ^successor_origin, _}},
                   20

    assert :ok = LeaseOwner.release_retirement_exit(predecessor, retirement_ref)
    assert_receive {:retirement_pop_blocked, ^owner, ^session_id}, 500

    assert %{
             owner_slots: 512,
             live_owners: 511,
             retiring_owners: 0,
             waiting_owner_starts: 1,
             mirror_operations: 1
           } = wait_for_transferred_slot(owner)

    refute Process.alive?(predecessor)

    assert :ok = Owner.release_retirement_pop(owner, session_id)

    assert_receive {:manual_connection_message, _,
                    {:relay_permit_result, ^successor_origin, successor_result}},
                   1_000

    successor_epoch =
      Base.url_decode64!(successor_result["result"]["writer_epoch"], padding: false)

    refute successor_epoch == predecessor_epoch

    assert %{owner_slots: 512, live_owners: 512, waiting_owner_starts: 0} =
             wait_for_owner_settlement(owner, 200)
  end

  test "connection loss cancels a queued successor without retaining its transferred slot" do
    owner = start_owner(retirement_pop_gate: self(), retirement_exit_gate: self())
    components = Owner.components(owner)
    holder = initialized_connection(components)
    successor = initialized_connection(components)
    acquire_origin = {holder.incarnation, 0, 1}
    {acquire_worker, acquire_worker_incarnation} = start_worker(holder.pid, acquire_origin)

    assert {:ok, :proposed, predecessor, predecessor_incarnation} =
             Owner.acquire_control(
               owner,
               acquire_origin,
               "acquire-held",
               "cancelled-successor",
               holder.pid,
               holder.incarnation,
               acquire_worker,
               acquire_worker_incarnation,
               now_ms() + 1_000
             )

    assert_receive {:worker_go, ^acquire_worker, ^acquire_origin}, 500

    assert_receive {:manual_connection_message, _,
                    {:relay_permit_result, ^acquire_origin, result}},
                   500

    writer_epoch = Base.url_decode64!(result["result"]["writer_epoch"], padding: false)
    release_origin = {holder.incarnation, 0, 2}
    {release_worker, release_worker_incarnation} = start_worker(holder.pid, release_origin)

    assert {:ok, :proposed, ^predecessor, ^predecessor_incarnation} =
             Owner.release_control(
               owner,
               release_origin,
               "release-held",
               "cancelled-successor",
               holder.pid,
               holder.incarnation,
               release_worker,
               release_worker_incarnation,
               writer_epoch,
               now_ms() + 1_000
             )

    assert_receive {:worker_go, ^release_worker, ^release_origin}, 500

    assert_receive {:manual_connection_message, _, {:relay_permit_result, ^release_origin, _}},
                   500

    assert_receive {:retirement_exit_blocked, ^predecessor, ^predecessor_incarnation,
                    retirement_ref},
                   500

    successor_origin = {successor.incarnation, 0, 1}

    {successor_worker, successor_worker_incarnation} =
      start_worker(successor.pid, successor_origin)

    assert {:ok, :queued, ^owner, _daemon_incarnation} =
             Owner.acquire_control(
               owner,
               successor_origin,
               "acquire-cancelled",
               "cancelled-successor",
               successor.pid,
               successor.incarnation,
               successor_worker,
               successor_worker_incarnation,
               now_ms() + 1_000
             )

    assert_receive {:worker_go, ^successor_worker, ^successor_origin}, 500

    Process.exit(successor.pid, :kill)

    assert %{
             owner_slots: 1,
             waiting_owner_starts: 0,
             lease_operations: 0,
             mirror_operations: 0,
             pending_dispositions: 0
           } = wait_for_successor_cancellation(owner)

    assert Process.alive?(predecessor)
    assert :ok = LeaseOwner.release_retirement_exit(predecessor, retirement_ref)
    assert_receive {:retirement_pop_blocked, ^owner, "cancelled-successor"}, 500
    assert :ok = Owner.release_retirement_pop(owner, "cancelled-successor")

    assert %{owner_slots: 0, waiting_owner_starts: 0} = wait_for_owner_retirement(owner)
    assert %{permits: 0, settling: 0, lease_owners: 0} = AdmissionRelay.status(components.relay)
  end

  test "a suspended registry cannot extend the mirror deadline" do
    owner = start_owner(mirror_deadline_ms: 30)
    components = Owner.components(owner)
    connection = initialized_connection(components)
    origin = {connection.incarnation, 0, 1}
    {worker, worker_incarnation} = start_worker(connection.pid, origin)

    :sys.suspend(components.registry)

    owner_monitor = Process.monitor(owner)

    assert {:ok, :proposed, lease_owner, owner_incarnation} =
             Owner.acquire_control(
               owner,
               origin,
               "deadline-acquire",
               "deadline-session",
               connection.pid,
               connection.incarnation,
               worker,
               worker_incarnation,
               now_ms() + 1_000
             )

    assert_receive {:worker_go, ^worker, ^origin}, 500
    assert is_pid(lease_owner)
    assert byte_size(owner_incarnation) == 16
    assert_receive {:DOWN, ^owner_monitor, :process, ^owner, :connections_lost}, 500
    refute Process.alive?(components.registry)
  end

  test "connection loss cancels a grant whose provisional mirror is still installing" do
    owner = start_owner(mirror_deadline_ms: 1_000)
    components = Owner.components(owner)
    connection = initialized_connection(components)
    origin = {connection.incarnation, 0, 1}
    {worker, worker_incarnation} = start_worker(connection.pid, origin)

    :sys.suspend(components.registry)

    assert {:ok, :proposed, lease_owner, _owner_incarnation} =
             Owner.acquire_control(
               owner,
               origin,
               "lost-acquire",
               "lost-session",
               connection.pid,
               connection.incarnation,
               worker,
               worker_incarnation,
               now_ms() + 2_000
             )

    assert_receive {:worker_go, ^worker, ^origin}, 500
    Process.exit(connection.pid, :kill)
    assert %{settling: 1} = wait_for_relay_settling(components.relay)

    :sys.resume(components.registry)

    assert %{
             granted_routes: 0,
             lease_operations: 0,
             mirror_operations: 0,
             pending_dispositions: 0
           } = wait_for_owner_settlement(owner)

    assert %{owner_slots: 0} = wait_for_owner_retirement(owner)
    assert Process.alive?(owner)
    refute Process.alive?(lease_owner)
    assert %{routing_mirrors: 0} = ConnectionRegistry.status(components.registry)
    assert %{permits: 0, settling: 0} = AdmissionRelay.status(components.relay)
  end

  test "connection loss cancels release and preserves the granted route" do
    owner = start_owner(mirror_deadline_ms: 1_000)
    components = Owner.components(owner)
    connection = initialized_connection(components)
    acquire_origin = {connection.incarnation, 0, 1}

    {acquire_worker, acquire_worker_incarnation} =
      start_worker(connection.pid, acquire_origin)

    assert {:ok, :proposed, lease_owner, owner_incarnation} =
             Owner.acquire_control(
               owner,
               acquire_origin,
               "release-loss-acquire",
               "release-loss-session",
               connection.pid,
               connection.incarnation,
               acquire_worker,
               acquire_worker_incarnation,
               now_ms() + 2_000
             )

    assert_receive {:worker_go, ^acquire_worker, ^acquire_origin}, 500

    assert_receive {:manual_connection_message, _,
                    {:relay_permit_result, ^acquire_origin, acquire_result}},
                   500

    writer_epoch = Base.url_decode64!(acquire_result["result"]["writer_epoch"], padding: false)
    assert %{granted_routes: 1} = wait_for_owner_settlement(owner)

    release_origin = {connection.incarnation, 1, 1}
    {release_worker, release_worker_incarnation} = start_worker(connection.pid, release_origin)

    :sys.suspend(lease_owner)

    release_task =
      Task.async(fn ->
        Owner.release_control(
          owner,
          release_origin,
          "lost-release",
          "release-loss-session",
          connection.pid,
          connection.incarnation,
          release_worker,
          release_worker_incarnation,
          writer_epoch,
          now_ms() + 2_000
        )
      end)

    assert %{pending: 1} = wait_for_relay_pending(components.relay)
    suspend_task = Task.async(fn -> :sys.suspend(owner) end)
    :sys.resume(lease_owner)

    assert {:ok, :proposed, ^lease_owner, ^owner_incarnation} = Task.await(release_task, 500)
    assert :ok = Task.await(suspend_task, 500)
    assert_receive {:worker_go, ^release_worker, ^release_origin}, 500

    Process.exit(connection.pid, :kill)
    assert %{settling: 1} = wait_for_relay_settling(components.relay)
    :sys.resume(owner)

    assert %{
             granted_routes: 1,
             lease_operations: 0,
             mirror_operations: 0,
             pending_dispositions: 0
           } = wait_for_owner_settlement(owner)

    assert Process.alive?(owner)
    assert %{phase: :held, held: true} = LeaseOwner.status(lease_owner)

    assert %{granted_routing_mirrors: 1, provisional_routing_mirrors: 0} =
             ConnectionRegistry.status(components.registry)

    assert %{permits: 0, settling: 0} = AdmissionRelay.status(components.relay)
  end

  test "expiry clears the granted route before the lease becomes expired" do
    owner = start_owner(lease_term_ms: 30)
    components = Owner.components(owner)
    connection = initialized_connection(components)
    origin = {connection.incarnation, 0, 1}
    {worker, worker_incarnation} = start_worker(connection.pid, origin)

    assert {:ok, :proposed, lease_owner, _owner_incarnation} =
             Owner.acquire_control(
               owner,
               origin,
               "expiring-acquire",
               "expiring-session",
               connection.pid,
               connection.incarnation,
               worker,
               worker_incarnation,
               now_ms() + 1_000
             )

    assert_receive {:manual_connection_message, _, {:relay_permit_result, ^origin, _result}}, 500

    assert %{granted_routes: 0, mirror_operations: 0, owner_slots: 0} =
             wait_for_owner_retirement(owner)

    refute Process.alive?(lease_owner)
    assert %{routing_mirrors: 0} = ConnectionRegistry.status(components.registry)
  end

  defp start_owner(options \\ []) do
    options =
      Keyword.merge(
        [admission_wait_ms: 1_000, connection_module: ManualConnection],
        options
      )

    start_supervised!({Owner, options}, restart: :temporary)
  end

  defp initialized_connection(components) do
    listener_incarnation = make_ref()

    assert {:ok, %{rollback_token: token}} =
             ConnectionRegistry.reserve(
               components.registry,
               self(),
               listener_incarnation,
               now_ms()
             )

    assert {:ok, pid, incarnation} =
             ConnectionRegistry.start_connection(components.registry, token)

    assert_receive {:manual_connection_started, ^pid, _options}, 500
    assert :ok = ConnectionRegistry.begin_transfer(components.registry, token, incarnation)
    assert :ok = ConnectionRegistry.transfer_result(components.registry, token, incarnation, :ok)
    assert :ok = manual_call(pid, :promote)
    assert :ok = manual_call(pid, :initialize)
    assert :ok = manual_call(pid, {:register_relay, components.relay, components.registry})
    %{pid: pid, incarnation: incarnation}
  end

  defp manual_call(pid, operation) do
    reference = make_ref()
    send(pid, {:manual_call, self(), reference, operation})

    receive do
      {:manual_result, ^reference, result} -> result
    after
      500 -> flunk("manual connection call did not answer")
    end
  end

  defp start_worker(connection, origin) do
    parent = self()
    worker_incarnation = incarnation()

    worker =
      spawn(fn ->
        monitor = Process.monitor(connection)

        receive do
          {:relay_go, ^origin, ^worker_incarnation} ->
            send(parent, {:worker_go, self(), origin})

          {:DOWN, ^monitor, :process, ^connection, _reason} ->
            :ok
        end
      end)

    {worker, worker_incarnation}
  end

  defp wait_for_owner_settlement(owner, attempts \\ 20)

  defp wait_for_owner_settlement(owner, attempts) when attempts > 0 do
    status = Owner.status(owner)

    if status.lease_operations == 0 and status.mirror_operations == 0 do
      status
    else
      Process.sleep(5)
      wait_for_owner_settlement(owner, attempts - 1)
    end
  end

  defp wait_for_owner_settlement(owner, 0), do: Owner.status(owner)

  defp wait_for_owner_retirement(owner, attempts \\ 40)

  defp wait_for_owner_retirement(owner, attempts) when attempts > 0 do
    status = Owner.status(owner)

    if status.owner_slots == 0 and status.retiring_owners == 0 and
         status.lease_operations == 0 and status.mirror_operations == 0 do
      status
    else
      Process.sleep(5)
      wait_for_owner_retirement(owner, attempts - 1)
    end
  end

  defp wait_for_owner_retirement(owner, 0), do: Owner.status(owner)

  defp wait_for_transferred_slot(owner, attempts \\ 200)

  defp wait_for_transferred_slot(owner, attempts) when attempts > 0 do
    status = Owner.status(owner)

    if status.owner_slots == 512 and status.retiring_owners == 0 and
         status.waiting_owner_starts == 1 and status.mirror_operations == 1 do
      status
    else
      Process.sleep(5)
      wait_for_transferred_slot(owner, attempts - 1)
    end
  end

  defp wait_for_transferred_slot(owner, 0), do: Owner.status(owner)

  defp wait_for_successor_cancellation(owner, attempts \\ 100)

  defp wait_for_successor_cancellation(owner, attempts) when attempts > 0 do
    status = Owner.status(owner)

    if status.waiting_owner_starts == 0 and status.lease_operations == 0 and
         status.mirror_operations == 0 and status.pending_dispositions == 0 do
      status
    else
      Process.sleep(5)
      wait_for_successor_cancellation(owner, attempts - 1)
    end
  end

  defp wait_for_successor_cancellation(owner, 0), do: Owner.status(owner)

  defp wait_for_relay_settling(relay, attempts \\ 20)

  defp wait_for_relay_settling(relay, attempts) when attempts > 0 do
    status = AdmissionRelay.status(relay)

    if status.settling == 1 do
      status
    else
      Process.sleep(5)
      wait_for_relay_settling(relay, attempts - 1)
    end
  end

  defp wait_for_relay_settling(relay, 0), do: AdmissionRelay.status(relay)

  defp wait_for_relay_pending(relay, attempts \\ 20)

  defp wait_for_relay_pending(relay, attempts) when attempts > 0 do
    status = AdmissionRelay.status(relay)

    if status.pending == 1 do
      status
    else
      Process.sleep(5)
      wait_for_relay_pending(relay, attempts - 1)
    end
  end

  defp wait_for_relay_pending(relay, 0), do: AdmissionRelay.status(relay)

  defp incarnation, do: :crypto.strong_rand_bytes(16)
  defp now_ms, do: System.monotonic_time(:millisecond)
end
