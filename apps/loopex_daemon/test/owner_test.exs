defmodule LoopexDaemon.OwnerTest do
  use ExUnit.Case, async: true
  @moduletag capture_log: true

  alias LoopexDaemon.{AdmissionRelay, ConnectionRegistry, LeaseOwner, Owner, WireRecords}

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

    # Technical depth: the owner's reply to a request this connection sent
    # for a test goes to the test process that asked; everything else is
    # reported to the listener.
    defp forward(parent, {[:alias | request_id], reply} = message) do
      case Process.delete({:manual_request, request_id}) do
        {caller, reference} -> send(caller, {:manual_reply, reference, reply})
        nil -> send(parent, {:manual_connection_message, self(), message})
      end
    end

    defp forward(parent, {:DOWN, request_id, :process, _owner, _reason} = message) do
      case Process.delete({:manual_request, request_id}) do
        {caller, reference} -> send(caller, {:manual_reply, reference, :owner_down})
        nil -> send(parent, {:manual_connection_message, self(), message})
      end
    end

    defp forward(parent, message), do: send(parent, {:manual_connection_message, self(), message})

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

        {:manual_call, caller, reference,
         {:owner_loss_closed, owner, close_ref, connection_incarnation}} ->
          result =
            LoopexDaemon.Owner.owner_loss_connection_closed(
              owner,
              close_ref,
              connection_incarnation
            )

          send(caller, {:manual_result, reference, result})

        {:manual_call, caller, reference,
         {:open_ticket, relay, origin, class, session_id, owner_binding}} ->
          result =
            LoopexDaemon.AdmissionRelay.open_ticket(
              relay,
              origin,
              class,
              session_id,
              owner_binding
            )

          send(caller, {:manual_result, reference, result})
          loop(parent, options)

        {:manual_call, caller, reference, {:invoke, operation}} ->
          send(caller, {:manual_result, reference, operation.()})
          loop(parent, options)

        {:manual_request, caller, reference, request} ->
          request_id = request.()
          Process.put({:manual_request, request_id}, {caller, reference})
          loop(parent, options)

        {:connection_abort, _token, _reason} ->
          :ok

        message ->
          forward(parent, message)
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

    assert {:ok, :accepted, lease_owner, owner_incarnation} =
             acquire_as(
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

    assert {:ok, :accepted, ^lease_owner, ^owner_incarnation} =
             release_as(
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

    assert {:ok, :accepted, ^lease_owner, ^owner_incarnation} =
             release_as(
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

    assert {:ok, :accepted, successor, successor_incarnation} =
             acquire_as(
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

        assert {:ok, :accepted, lease_owner, owner_incarnation} =
                 acquire_as(
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

    assert {:ok, :accepted, ^predecessor, ^predecessor_incarnation} =
             release_as(
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

    assert {:ok, :accepted, ^owner, _daemon_incarnation} =
             acquire_as(
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

    assert {:ok, :accepted, ^owner, _daemon_incarnation} =
             acquire_as(
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
             acquire_as(
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

    assert {:ok, :accepted, predecessor, predecessor_incarnation} =
             acquire_as(
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

    assert {:ok, :accepted, ^predecessor, ^predecessor_incarnation} =
             release_as(
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

    assert {:ok, :accepted, ^owner, _daemon_incarnation} =
             acquire_as(
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

  test "unexpected held-owner loss is session-scoped and gates its fresh successor" do
    owner = start_owner()
    components = Owner.components(owner)
    holder = initialized_connection(components)
    observer = initialized_connection(components)
    successor = initialized_connection(components)
    holder_pid = holder.pid
    observer_pid = observer.pid
    successor_pid = successor.pid
    acquire_origin = {holder.incarnation, 0, 1}
    {acquire_worker, acquire_worker_incarnation} = start_worker(holder.pid, acquire_origin)

    assert {:ok, :accepted, predecessor, predecessor_incarnation} =
             acquire_as(
               owner,
               acquire_origin,
               "owner-loss-acquire",
               "owner-loss-session",
               holder.pid,
               holder.incarnation,
               acquire_worker,
               acquire_worker_incarnation,
               now_ms() + 1_000
             )

    assert_receive {:worker_go, ^acquire_worker, ^acquire_origin}, 500

    assert_receive {:manual_connection_message, _,
                    {:relay_permit_result, ^acquire_origin, acquire_result}},
                   500

    predecessor_epoch =
      Base.url_decode64!(acquire_result["result"]["writer_epoch"], padding: false)

    observer_origin = {observer.incarnation, 0, 1}

    assert {:ok, ^observer_origin} =
             manual_call(
               observer.pid,
               {:open_ticket, components.relay, observer_origin, :session_prompt,
                "owner-loss-session", {predecessor, predecessor_incarnation}}
             )

    predecessor_monitor = Process.monitor(predecessor)
    :ok = GenServer.stop(predecessor, :normal)
    assert_receive {:DOWN, ^predecessor_monitor, :process, ^predecessor, :normal}, 500

    assert_receive {:manual_connection_message, ^observer_pid,
                    {:relay_ticket_cancelled, ^observer_origin, :control_owner_lost}},
                   500

    assert_receive {:manual_connection_message, ^holder_pid,
                    {:daemon_control_owner_lost, ^owner, close_ref, "owner-loss-session",
                     holder_incarnation}},
                   500

    assert holder_incarnation == holder.incarnation
    assert Process.alive?(owner)
    assert Process.alive?(observer.pid)

    successor_origin = {successor.incarnation, 0, 1}

    {successor_worker, successor_worker_incarnation} =
      start_worker(successor.pid, successor_origin)

    assert {:ok, :accepted, ^owner, _daemon_incarnation} =
             acquire_as(
               owner,
               successor_origin,
               "owner-loss-successor",
               "owner-loss-session",
               successor.pid,
               successor.incarnation,
               successor_worker,
               successor_worker_incarnation,
               now_ms() + 1_000
             )

    assert_receive {:worker_go, ^successor_worker, ^successor_origin}, 500

    refute_receive {:manual_connection_message, ^successor_pid,
                    {:relay_permit_result, ^successor_origin, _result}},
                   40

    assert %{
             owner_slots: 1,
             live_owners: 0,
             lost_owners: 1,
             waiting_owner_starts: 1,
             mirror_operations: 1
           } = Owner.status(owner)

    holder_monitor = Process.monitor(holder.pid)

    assert :ok =
             manual_call(
               holder.pid,
               {:owner_loss_closed, owner, close_ref, holder.incarnation}
             )

    assert_receive {:DOWN, ^holder_monitor, :process, ^holder_pid, :normal}, 500

    assert_receive {:manual_connection_message, ^successor_pid,
                    {:relay_permit_result, ^successor_origin, successor_result}},
                   500

    successor_epoch =
      Base.url_decode64!(successor_result["result"]["writer_epoch"], padding: false)

    refute successor_epoch == predecessor_epoch

    assert %{owner_slots: 1, live_owners: 1, lost_owners: 0, waiting_owner_starts: 0} =
             wait_for_owner_settlement(owner)

    assert Process.alive?(observer.pid)

    assert %{owner_losses: 0, tickets: 0, lease_owners: 1} =
             AdmissionRelay.status(components.relay)

    assert %{routing_mirrors: 1} = ConnectionRegistry.status(components.registry)
  end

  test "owner loss wins an unsettled release and preserves the holder for terminal close" do
    owner = start_owner(mirror_deadline_ms: 1_000)
    components = Owner.components(owner)
    holder = initialized_connection(components)
    acquire_origin = {holder.incarnation, 0, 1}
    {acquire_worker, acquire_worker_incarnation} = start_worker(holder.pid, acquire_origin)

    assert {:ok, :accepted, lease_owner, owner_incarnation} =
             acquire_as(
               owner,
               acquire_origin,
               "release-owner-loss-acquire",
               "release-owner-loss-session",
               holder.pid,
               holder.incarnation,
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

    release_origin = {holder.incarnation, 1, 1}
    {release_worker, release_worker_incarnation} = start_worker(holder.pid, release_origin)
    :sys.suspend(lease_owner)

    release_task =
      Task.async(fn ->
        release_as(
          owner,
          release_origin,
          "release-owner-loss",
          "release-owner-loss-session",
          holder.pid,
          holder.incarnation,
          release_worker,
          release_worker_incarnation,
          writer_epoch,
          now_ms() + 2_000
        )
      end)

    assert %{pending: 1} = wait_for_relay_pending(components.relay)
    suspend_task = Task.async(fn -> :sys.suspend(owner) end)
    :sys.resume(lease_owner)

    assert {:ok, :accepted, ^lease_owner, ^owner_incarnation} = Task.await(release_task, 500)
    assert :ok = Task.await(suspend_task, 500)
    assert_receive {:worker_go, ^release_worker, ^release_origin}, 500

    lease_owner_monitor = Process.monitor(lease_owner)
    Process.exit(lease_owner, :kill)
    assert_receive {:DOWN, ^lease_owner_monitor, :process, ^lease_owner, :killed}, 500
    assert %{owner_losses: 1} = wait_for_relay_owner_loss(components.relay)
    :sys.resume(owner)

    assert_receive {:manual_connection_message, holder_pid,
                    {:daemon_control_owner_lost, ^owner, close_ref, "release-owner-loss-session",
                     holder_incarnation}},
                   500

    assert holder_pid == holder.pid
    assert holder_incarnation == holder.incarnation

    refute_receive {:manual_connection_message, ^holder_pid,
                    {:relay_permit_result, ^release_origin, _result}},
                   40

    holder_monitor = Process.monitor(holder.pid)

    assert :ok =
             manual_call(
               holder.pid,
               {:owner_loss_closed, owner, close_ref, holder.incarnation}
             )

    assert_receive {:DOWN, ^holder_monitor, :process, ^holder_pid, :normal}, 500

    assert %{
             owner_slots: 0,
             lost_owners: 0,
             granted_routes: 0,
             lease_operations: 0,
             mirror_operations: 0
           } = wait_for_owner_retirement(owner)

    assert Process.alive?(owner)
    assert %{routing_mirrors: 0} = ConnectionRegistry.status(components.registry)

    assert %{permits: 0, settling: 0, owner_losses: 0, lease_owners: 0} =
             AdmissionRelay.status(components.relay)
  end

  test "a selected release settles before later owner-loss classification" do
    owner = start_owner(mirror_deadline_ms: 1_000)
    components = Owner.components(owner)
    holder = initialized_connection(components)
    acquire_origin = {holder.incarnation, 0, 1}
    {acquire_worker, acquire_worker_incarnation} = start_worker(holder.pid, acquire_origin)

    assert {:ok, :accepted, lease_owner, owner_incarnation} =
             acquire_as(
               owner,
               acquire_origin,
               "selected-release-acquire",
               "selected-release-session",
               holder.pid,
               holder.incarnation,
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

    release_origin = {holder.incarnation, 1, 1}
    {release_worker, release_worker_incarnation} = start_worker(holder.pid, release_origin)
    :sys.suspend(components.registry)

    assert {:ok, :accepted, ^lease_owner, ^owner_incarnation} =
             release_as(
               owner,
               release_origin,
               "selected-release",
               "selected-release-session",
               holder.pid,
               holder.incarnation,
               release_worker,
               release_worker_incarnation,
               writer_epoch,
               now_ms() + 2_000
             )

    assert_receive {:worker_go, ^release_worker, ^release_origin}, 500
    assert :ok = wait_for_mirror_step(owner, :release, :clear)

    lease_owner_monitor = Process.monitor(lease_owner)
    Process.exit(lease_owner, :kill)
    assert_receive {:DOWN, ^lease_owner_monitor, :process, ^lease_owner, :killed}, 500
    :sys.resume(components.registry)

    assert_receive {:manual_connection_message, holder_pid,
                    {:relay_permit_result, ^release_origin, release_result}},
                   500

    assert holder_pid == holder.pid

    assert release_result == %{
             "method" => "session.release_control",
             "request_id" => "selected-release",
             "result" => %{"released" => true},
             "type" => "result"
           }

    assert %{
             owner_slots: 0,
             lost_owners: 0,
             granted_routes: 0,
             lease_operations: 0,
             mirror_operations: 0
           } = wait_for_owner_retirement(owner)

    assert Process.alive?(owner)
    assert Process.alive?(holder.pid)

    refute_receive {:manual_connection_message, ^holder_pid,
                    {:daemon_control_owner_lost, ^owner, _close_ref, "selected-release-session",
                     _holder_incarnation}},
                   40

    assert %{routing_mirrors: 0} = ConnectionRegistry.status(components.registry)

    assert %{permits: 0, settling: 0, owner_losses: 0, lease_owners: 0} =
             AdmissionRelay.status(components.relay)
  end

  test "a selected fresh grant settles before its dead child is classified" do
    owner = start_owner(mirror_deadline_ms: 1_000)
    components = Owner.components(owner)
    holder = initialized_connection(components)
    origin = {holder.incarnation, 0, 1}
    {worker, worker_incarnation} = start_worker(holder.pid, origin)
    :sys.suspend(components.registry)

    assert {:ok, :accepted, lease_owner, _owner_incarnation} =
             acquire_as(
               owner,
               origin,
               "selected-fresh-grant",
               "selected-fresh-session",
               holder.pid,
               holder.incarnation,
               worker,
               worker_incarnation,
               now_ms() + 2_000
             )

    assert_receive {:worker_go, ^worker, ^origin}, 500
    assert :ok = wait_for_mirror_step(owner, :grant, :install)
    :sys.suspend(components.relay)
    :sys.resume(components.registry)
    assert :ok = wait_for_mirror_step(owner, :grant, :select_result)
    :sys.suspend(owner)
    :sys.resume(components.relay)
    assert %{settling: 1} = wait_for_relay_settling(components.relay)
    :sys.suspend(components.registry)
    :sys.resume(owner)
    assert :ok = wait_for_mirror_step(owner, :grant, :resolve_granted)

    lease_owner_monitor = Process.monitor(lease_owner)
    Process.exit(lease_owner, :kill)
    assert_receive {:DOWN, ^lease_owner_monitor, :process, ^lease_owner, :killed}, 500
    :sys.resume(components.registry)

    assert_receive {:manual_connection_message, holder_pid,
                    {:relay_permit_result, ^origin, acquire_result}},
                   500

    assert holder_pid == holder.pid
    assert acquire_result["method"] == "session.acquire_control"

    assert_receive {:manual_connection_message, ^holder_pid,
                    {:daemon_control_owner_lost, ^owner, close_ref, "selected-fresh-session",
                     holder_incarnation}},
                   500

    assert holder_incarnation == holder.incarnation
    holder_monitor = Process.monitor(holder.pid)

    assert :ok =
             manual_call(
               holder.pid,
               {:owner_loss_closed, owner, close_ref, holder.incarnation}
             )

    assert_receive {:DOWN, ^holder_monitor, :process, ^holder_pid, :normal}, 500

    assert %{
             owner_slots: 0,
             lost_owners: 0,
             granted_routes: 0,
             lease_operations: 0,
             mirror_operations: 0
           } = wait_for_owner_retirement(owner)

    assert Process.alive?(owner)
    assert %{routing_mirrors: 0} = ConnectionRegistry.status(components.registry)

    assert %{permits: 0, settling: 0, owner_losses: 0, lease_owners: 0} =
             AdmissionRelay.status(components.relay)
  end

  test "owner loss wins an existing owner's holder-changing grant before selection" do
    owner = start_owner(lease_term_ms: 40, mirror_deadline_ms: 5_000)
    components = Owner.components(owner)
    former = initialized_connection(components)
    successor = initialized_connection(components)
    former_pid = former.pid
    successor_pid = successor.pid
    former_origin = {former.incarnation, 0, 1}
    {former_worker, former_worker_incarnation} = start_worker(former.pid, former_origin)

    assert {:ok, :accepted, lease_owner, owner_incarnation} =
             acquire_as(
               owner,
               former_origin,
               "existing-grant-former",
               "existing-grant-session",
               former.pid,
               former.incarnation,
               former_worker,
               former_worker_incarnation,
               now_ms() + 2_000
             )

    assert_receive {:worker_go, ^former_worker, ^former_origin}, 500

    assert_receive {:manual_connection_message, ^former_pid,
                    {:relay_permit_result, ^former_origin, _former_result}},
                   500

    :sys.suspend(components.registry)
    assert :ok = wait_for_mirror_step(owner, :expiry, :clear)

    successor_origin = {successor.incarnation, 0, 1}

    {successor_worker, successor_worker_incarnation} =
      start_worker(successor.pid, successor_origin)

    assert {:ok, :accepted, ^lease_owner, ^owner_incarnation} =
             acquire_as(
               owner,
               successor_origin,
               "existing-grant-successor",
               "existing-grant-session",
               successor.pid,
               successor.incarnation,
               successor_worker,
               successor_worker_incarnation,
               now_ms() + 2_000
             )

    assert_receive {:worker_go, ^successor_worker, ^successor_origin}, 500

    # Concept: the lease owner proposes the successor grant before it
    # acknowledges the expiry, so its death can precede the daemon's retirement
    # request. Technical depth: the registry holds the grant at install while
    # the killed owner's queued acknowledgement is still undelivered.
    :sys.suspend(lease_owner)
    :sys.resume(components.registry)
    assert :ok = wait_for_mirror_step(owner, :expiry, :resolve_owner_expiry)
    :sys.suspend(components.registry)
    :sys.resume(lease_owner)
    assert :ok = wait_for_mirror_step(owner, :grant, :install)

    lease_owner_monitor = Process.monitor(lease_owner)
    Process.exit(lease_owner, :kill)
    assert_receive {:DOWN, ^lease_owner_monitor, :process, ^lease_owner, :killed}, 500
    assert %{owner_losses: 1} = wait_for_relay_owner_loss(components.relay)
    :sys.resume(components.registry)

    assert_receive {:manual_connection_message, ^successor_pid,
                    {:relay_permit_cancelled, ^successor_origin, :control_owner_lost}},
                   2_000

    assert %{
             owner_slots: 0,
             lost_owners: 0,
             granted_routes: 0,
             lease_operations: 0,
             mirror_operations: 0
           } = wait_for_owner_retirement(owner)

    refute_receive {:manual_connection_message, ^successor_pid,
                    {:relay_permit_result, ^successor_origin, _result}},
                   40

    refute_receive {:manual_connection_message, _holder,
                    {:daemon_control_owner_lost, ^owner, _close_ref, "existing-grant-session",
                     _holder_incarnation}},
                   40

    assert Process.alive?(owner)
    assert Process.alive?(former_pid)
    assert Process.alive?(successor_pid)
    assert %{routing_mirrors: 0} = ConnectionRegistry.status(components.registry)

    assert %{permits: 0, settling: 0, owner_losses: 0, lease_owners: 0} =
             AdmissionRelay.status(components.relay)
  end

  test "owner loss during a cancelled grant settles the connection loss without the owner" do
    owner = start_owner(mirror_deadline_ms: 1_000)
    components = Owner.components(owner)
    holder = initialized_connection(components)
    origin = {holder.incarnation, 0, 1}
    {worker, worker_incarnation} = start_worker(holder.pid, origin)
    :sys.suspend(components.registry)

    assert {:ok, :accepted, lease_owner, _owner_incarnation} =
             acquire_as(
               owner,
               origin,
               "cancelled-grant-owner-loss",
               "cancelled-grant-session",
               holder.pid,
               holder.incarnation,
               worker,
               worker_incarnation,
               now_ms() + 2_000
             )

    assert_receive {:worker_go, ^worker, ^origin}, 500
    assert :ok = wait_for_mirror_step(owner, :grant, :install)

    holder_monitor = Process.monitor(holder.pid)
    Process.exit(holder.pid, :kill)
    assert_receive {:DOWN, ^holder_monitor, :process, _holder, :killed}, 500
    assert :ok = wait_for_mirror_step(owner, :grant, :install_connection_lost)

    :sys.suspend(lease_owner)
    :sys.resume(components.registry)
    assert :ok = wait_for_mirror_step(owner, :grant, :resolve_owner_cancel)

    lease_owner_monitor = Process.monitor(lease_owner)
    Process.exit(lease_owner, :kill)
    assert_receive {:DOWN, ^lease_owner_monitor, :process, ^lease_owner, :killed}, 500

    assert %{
             owner_slots: 0,
             lost_owners: 0,
             granted_routes: 0,
             lease_operations: 0,
             mirror_operations: 0,
             pending_dispositions: 0
           } = wait_for_owner_retirement(owner)

    assert Process.alive?(owner)
    assert %{routing_mirrors: 0} = ConnectionRegistry.status(components.registry)

    assert %{permits: 0, settling: 0, owner_losses: 0, lease_owners: 0} =
             AdmissionRelay.status(components.relay)
  end

  test "a fresh child lost before it proposes refuses its first acquire" do
    owner = start_owner(mirror_deadline_ms: 1_000)
    components = Owner.components(owner)
    holder = initialized_connection(components)
    holder_pid = holder.pid
    origin = {holder.incarnation, 0, 1}
    {worker, worker_incarnation} = start_worker(holder.pid, origin)
    test_pid = self()

    # Concept: the relay's registration call parks the daemon owner after the
    # child starts. Technical depth: a relay debug hook holds that exact call;
    # the child is then released for exactly its activation and killed before
    # its first acquire can arrive.
    :ok =
      :sys.install(
        components.relay,
        {fn
           :waiting,
           {:in, {:"$gen_call", _from, {:register_lease_owner, "unproposed-session", child, _}}},
           _proc_state ->
             send(test_pid, {:registering, child})

             receive do
               :continue_registration -> :done
             end

           :waiting, _event, _proc_state ->
             :waiting
         end, :waiting}
      )

    acquire =
      Task.async(fn ->
        acquire_as(
          owner,
          origin,
          "unproposed-first-acquire",
          "unproposed-session",
          holder.pid,
          holder.incarnation,
          worker,
          worker_incarnation,
          now_ms() + 2_000
        )
      end)

    assert_receive {:registering, child}, 500
    :sys.suspend(child)
    send(components.relay, :continue_registration)

    # The child activates and is then held as its first acquire arrives, so
    # the kill always lands before any proposal.
    :ok =
      :sys.install(
        child,
        {fn
           :waiting, {:in, {:lease_request, _owner, _incarnation, request}}, _proc_state
           when is_tuple(request) and elem(request, 0) == :first_acquire ->
             send(test_pid, :first_acquire_held)

             receive do
               :never -> :done
             end

           :waiting, _event, _proc_state ->
             :waiting
         end, :waiting}
      )

    :sys.resume(child)
    assert_receive :first_acquire_held, 500

    child_monitor = Process.monitor(child)
    Process.exit(child, :kill)
    assert_receive {:DOWN, ^child_monitor, :process, ^child, :killed}, 500
    assert {:ok, :accepted, ^child, _owner_incarnation} = Task.await(acquire, 1_000)
    assert_receive {:worker_go, ^worker, ^origin}, 500

    assert_receive {:manual_connection_message, ^holder_pid,
                    {:relay_permit_result, ^origin, result}},
                   500

    assert result["code"] == "control_pending"

    assert %{
             owner_slots: 0,
             lost_owners: 0,
             granted_routes: 0,
             lease_operations: 0,
             mirror_operations: 0
           } = wait_for_owner_retirement(owner)

    assert Process.alive?(owner)
    assert %{routing_mirrors: 0} = ConnectionRegistry.status(components.registry)

    assert %{permits: 0, settling: 0, owner_losses: 0, lease_owners: 0} =
             AdmissionRelay.status(components.relay)
  end

  test "a suspended registry cannot extend the mirror deadline" do
    owner = start_owner(mirror_deadline_ms: 30)
    components = Owner.components(owner)
    connection = initialized_connection(components)
    origin = {connection.incarnation, 0, 1}
    {worker, worker_incarnation} = start_worker(connection.pid, origin)

    :sys.suspend(components.registry)

    owner_monitor = Process.monitor(owner)

    assert {:ok, :accepted, lease_owner, owner_incarnation} =
             acquire_as(
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

    assert {:ok, :accepted, lease_owner, _owner_incarnation} =
             acquire_as(
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

    assert {:ok, :accepted, lease_owner, owner_incarnation} =
             acquire_as(
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
        release_as(
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

    assert {:ok, :accepted, ^lease_owner, ^owner_incarnation} = Task.await(release_task, 500)
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

    assert {:ok, :accepted, lease_owner, _owner_incarnation} =
             acquire_as(
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

  test "an expiry mirror selected before owner loss clears without closing the former holder" do
    owner = start_owner(lease_term_ms: 40, mirror_deadline_ms: 1_000)
    components = Owner.components(owner)
    holder = initialized_connection(components)
    origin = {holder.incarnation, 0, 1}
    {worker, worker_incarnation} = start_worker(holder.pid, origin)

    assert {:ok, :accepted, lease_owner, _owner_incarnation} =
             acquire_as(
               owner,
               origin,
               "expiry-owner-loss-acquire",
               "expiry-owner-loss-session",
               holder.pid,
               holder.incarnation,
               worker,
               worker_incarnation,
               now_ms() + 1_000
             )

    assert_receive {:worker_go, ^worker, ^origin}, 500
    assert_receive {:manual_connection_message, _, {:relay_permit_result, ^origin, _result}}, 500
    :sys.suspend(components.registry)
    assert :ok = wait_for_mirror_step(owner, :expiry, :clear)

    lease_owner_monitor = Process.monitor(lease_owner)
    Process.exit(lease_owner, :kill)
    assert_receive {:DOWN, ^lease_owner_monitor, :process, ^lease_owner, :killed}, 500
    :sys.resume(components.registry)

    assert %{
             owner_slots: 0,
             lost_owners: 0,
             granted_routes: 0,
             lease_operations: 0,
             mirror_operations: 0
           } = wait_for_owner_retirement(owner)

    assert Process.alive?(owner)
    assert Process.alive?(holder.pid)
    holder_pid = holder.pid

    refute_receive {:manual_connection_message, ^holder_pid,
                    {:daemon_control_owner_lost, ^owner, _close_ref, "expiry-owner-loss-session",
                     _holder_incarnation}},
                   40

    assert %{routing_mirrors: 0} = ConnectionRegistry.status(components.registry)
    assert %{owner_losses: 0, lease_owners: 0} = AdmissionRelay.status(components.relay)
  end

  # Concept: a release whose lease owner dies before it can propose never
  # reaches settlement, so owner loss wins and the holder's granted mirror is
  # still in place for classification to pop.
  #
  # Technical depth: the daemon owner's synchronous release call is parked on
  # the suspended lease owner after the relay opened the permit. The kill turns
  # that call into `:queued`, the relay claims the never-claimed permit, and
  # the pop returns the exact holder, so the holder receives the one
  # uncorrelated close while the release origin receives neither a result nor
  # a refusal and its worker is never started.
  test "an owner lost before its release proposal leaves the holder mirror for classification" do
    owner = start_owner(mirror_deadline_ms: 1_000)
    components = Owner.components(owner)
    holder = initialized_connection(components)
    holder_pid = holder.pid

    {lease_owner, owner_incarnation, writer_epoch} =
      acquire_held(owner, holder, "unproposed-release-session")

    release_origin = {holder.incarnation, 1, 1}
    {release_worker, release_worker_incarnation} = start_worker(holder.pid, release_origin)
    :sys.suspend(lease_owner)

    release_task =
      Task.async(fn ->
        release_as(
          owner,
          release_origin,
          "unproposed-release",
          "unproposed-release-session",
          holder.pid,
          holder.incarnation,
          release_worker,
          release_worker_incarnation,
          writer_epoch,
          now_ms() + 2_000
        )
      end)

    assert %{pending: 1} = wait_for_relay_pending(components.relay)
    lease_owner_monitor = Process.monitor(lease_owner)
    Process.exit(lease_owner, :kill)
    assert_receive {:DOWN, ^lease_owner_monitor, :process, ^lease_owner, :killed}, 500
    assert {:ok, :accepted, ^lease_owner, ^owner_incarnation} = Task.await(release_task, 1_000)

    assert_receive {:manual_connection_message, ^holder_pid,
                    {:daemon_control_owner_lost, ^owner, close_ref, "unproposed-release-session",
                     holder_incarnation}},
                   500

    assert holder_incarnation == holder.incarnation
    refute_received {:worker_go, ^release_worker, ^release_origin}

    refute_receive {:manual_connection_message, ^holder_pid,
                    {:relay_permit_result, ^release_origin, _result}},
                   40

    refute_received {:manual_connection_message, ^holder_pid,
                     {:relay_permit_cancelled, ^release_origin, _reason}}

    close_owner_loss_holder(owner, holder, close_ref)
    assert_clean_retirement(owner, components)
  end

  # Concept: once the relay has selected the release result, owner loss can
  # no longer take the release: the mirror is cleared before the one
  # correlated success, and the later owner-loss pop finds nothing to close.
  #
  # Technical depth: a relay debug hook parks the selection request; the daemon
  # owner is suspended while the relay completes the result CAS, then the lease
  # owner is killed and the relay consumes its `DOWN` before the daemon owner
  # has even requested the mirror clear. The success is observed with the
  # granted mirror already gone, and no `daemon_control_owner_lost` follows.
  test "an owner lost after the release result CAS clears the mirror before one success" do
    owner = start_owner(mirror_deadline_ms: 1_000)
    components = Owner.components(owner)
    holder = initialized_connection(components)
    holder_pid = holder.pid

    {lease_owner, owner_incarnation, writer_epoch} =
      acquire_held(owner, holder, "selected-before-clear-session")

    release_origin = {holder.incarnation, 1, 1}
    {release_worker, release_worker_incarnation} = start_worker(holder.pid, release_origin)
    park_relay_operation(components.relay, :select_result)

    assert {:ok, :accepted, ^lease_owner, ^owner_incarnation} =
             release_as(
               owner,
               release_origin,
               "selected-before-clear",
               "selected-before-clear-session",
               holder.pid,
               holder.incarnation,
               release_worker,
               release_worker_incarnation,
               writer_epoch,
               now_ms() + 2_000
             )

    assert_receive {:worker_go, ^release_worker, ^release_origin}, 500
    assert_receive {:relay_operation_parked, :select_result}, 500
    :sys.suspend(owner)
    send(components.relay, :continue_parked_operation)
    assert %{settling: 1} = wait_for_relay_settling(components.relay)

    lease_owner_monitor = Process.monitor(lease_owner)
    Process.exit(lease_owner, :kill)
    assert_receive {:DOWN, ^lease_owner_monitor, :process, ^lease_owner, :killed}, 500
    assert %{owner_losses: 1} = wait_for_relay_owner_loss(components.relay)
    assert %{granted_routing_mirrors: 1} = ConnectionRegistry.status(components.registry)
    :sys.resume(owner)

    assert_receive {:manual_connection_message, ^holder_pid,
                    {:relay_permit_result, ^release_origin, release_result}},
                   500

    assert %{granted_routing_mirrors: 0} = ConnectionRegistry.status(components.registry)
    assert release_result == WireRecords.control_released("selected-before-clear")
    assert_clean_retirement(owner, components)

    refute_receive {:manual_connection_message, ^holder_pid,
                    {:daemon_control_owner_lost, ^owner, _close_ref, _session_id, _incarnation}},
                   40

    refute_received {:manual_connection_message, ^holder_pid,
                     {:relay_permit_result, ^release_origin, _second}}

    assert Process.alive?(holder.pid)
  end

  # Concept: an owner lost after the mirror clear but before the success is
  # sent still leaves exactly one success and no holder close.
  #
  # Technical depth: the relay is parked on the result settlement the daemon
  # owner requests after the registry cleared the granted mirror; the kill's
  # `DOWN` queues behind that settlement, and the daemon owner's later pop is
  # absent.
  test "an owner lost after the release clear sends one success and pops nothing" do
    owner = start_owner(mirror_deadline_ms: 1_000)
    components = Owner.components(owner)
    holder = initialized_connection(components)
    holder_pid = holder.pid

    {lease_owner, owner_incarnation, writer_epoch} =
      acquire_held(owner, holder, "cleared-release-session")

    release_origin = {holder.incarnation, 1, 1}
    {release_worker, release_worker_incarnation} = start_worker(holder.pid, release_origin)
    park_relay_operation(components.relay, :settle_result)

    assert {:ok, :accepted, ^lease_owner, ^owner_incarnation} =
             release_as(
               owner,
               release_origin,
               "cleared-release",
               "cleared-release-session",
               holder.pid,
               holder.incarnation,
               release_worker,
               release_worker_incarnation,
               writer_epoch,
               now_ms() + 2_000
             )

    assert_receive {:worker_go, ^release_worker, ^release_origin}, 500
    assert_receive {:relay_operation_parked, :settle_result}, 500
    assert %{granted_routing_mirrors: 0} = ConnectionRegistry.status(components.registry)

    lease_owner_monitor = Process.monitor(lease_owner)
    Process.exit(lease_owner, :kill)
    assert_receive {:DOWN, ^lease_owner_monitor, :process, ^lease_owner, :killed}, 500
    send(components.relay, :continue_parked_operation)

    assert_receive {:manual_connection_message, ^holder_pid,
                    {:relay_permit_result, ^release_origin, release_result}},
                   500

    assert release_result == WireRecords.control_released("cleared-release")
    assert_clean_retirement(owner, components)

    refute_receive {:manual_connection_message, ^holder_pid,
                    {:daemon_control_owner_lost, ^owner, _close_ref, _session_id, _incarnation}},
                   40

    refute_received {:manual_connection_message, ^holder_pid,
                     {:relay_permit_result, ^release_origin, _second}}
  end

  # Concept: a malformed relay settlement cannot be interpreted, so the daemon
  # owner stops as `relay_lost` rather than guessing a release outcome.
  #
  # Technical depth: while the relay is parked on the real settlement, a
  # settlement acknowledgement with the exact operation reference, relay and
  # daemon incarnation but an unknown result reaches the daemon owner.
  test "a malformed release settlement selects relay_lost without a success" do
    owner = start_owner(mirror_deadline_ms: 1_000)
    components = Owner.components(owner)
    holder = initialized_connection(components)
    holder_pid = holder.pid

    {lease_owner, owner_incarnation, writer_epoch} =
      acquire_held(owner, holder, "malformed-settlement-session")

    release_origin = {holder.incarnation, 1, 1}
    {release_worker, release_worker_incarnation} = start_worker(holder.pid, release_origin)
    park_relay_operation(components.relay, :settle_result)

    assert {:ok, :accepted, ^lease_owner, ^owner_incarnation} =
             release_as(
               owner,
               release_origin,
               "malformed-settlement",
               "malformed-settlement-session",
               holder.pid,
               holder.incarnation,
               release_worker,
               release_worker_incarnation,
               writer_epoch,
               now_ms() + 2_000
             )

    assert_receive {:relay_operation_parked, :settle_result}, 500

    [operation_ref] =
      for {operation_ref, %{kind: :release, step: :settle_result}} <-
            :sys.get_state(owner).mirror_operations,
          do: operation_ref

    owner_monitor = Process.monitor(owner)

    send(
      owner,
      {:relay_lease_operation_ack, operation_ref, components.relay, components.daemon_incarnation,
       :settle_result, {:error, :malformed}}
    )

    assert_receive {:DOWN, ^owner_monitor, :process, ^owner, :relay_lost}, 500

    refute_receive {:manual_connection_message, ^holder_pid,
                    {:relay_permit_result, ^release_origin, _result}},
                   40
  end

  # Concept: under an existing lease owner, a successor whose connection is
  # lost at provisional install is cancelled; no epoch is ever exposed and the
  # former holder is not closed.
  #
  # Technical depth: the grant is parked at install behind the suspended
  # registry; the connection-loss disposition arrives first, so the install
  # resolves cancelled, the owner cancels its grant, the relay settles the
  # disposition and the idle owner retires normally rather than being lost.
  test "an existing owner's successor lost at install resolves cancelled without an epoch" do
    owner = start_owner(lease_term_ms: 40, mirror_deadline_ms: 5_000)
    components = Owner.components(owner)
    former = initialized_connection(components)
    successor = initialized_connection(components)
    former_pid = former.pid

    {lease_owner, _successor_origin} =
      park_existing_owner_grant(owner, components, former, successor, "existing-loss-session")

    lease_owner_monitor = Process.monitor(lease_owner)
    successor_monitor = Process.monitor(successor.pid)
    Process.exit(successor.pid, :kill)
    assert_receive {:DOWN, ^successor_monitor, :process, _successor, :killed}, 500
    assert :ok = wait_for_mirror_step(owner, :grant, :install_connection_lost)
    :sys.resume(components.registry)

    assert_receive {:DOWN, ^lease_owner_monitor, :process, ^lease_owner, :normal}, 1_000
    assert %{lost_owners: 0, granted_routes: 0} = assert_clean_retirement(owner, components)

    refute_receive {:manual_connection_message, ^former_pid,
                    {:daemon_control_owner_lost, ^owner, _close_ref, _session_id, _incarnation}},
                   40

    assert Process.alive?(former_pid)
  end

  # Concept: under an existing lease owner, a successor grant whose result
  # was selected before the owner died is granted, and the later owner-loss
  # path closes exactly that promoted holder once.
  #
  # Technical depth: the grant report and install acknowledgement are
  # consumed, the relay completes the result CAS, and the owner is killed
  # while the provisional resolution waits on the suspended registry.
  test "an existing owner's selected successor grant is closed once after owner loss" do
    owner = start_owner(lease_term_ms: 40, mirror_deadline_ms: 5_000)
    components = Owner.components(owner)
    former = initialized_connection(components)
    successor = initialized_connection(components)
    former_pid = former.pid
    successor_pid = successor.pid

    {lease_owner, successor_origin} =
      park_existing_owner_grant(owner, components, former, successor, "existing-result-session")

    :sys.suspend(components.relay)
    :sys.resume(components.registry)
    assert :ok = wait_for_mirror_step(owner, :grant, :select_result)
    :sys.suspend(owner)
    :sys.resume(components.relay)
    assert %{settling: 1} = wait_for_relay_settling(components.relay)
    :sys.suspend(components.registry)
    :sys.resume(owner)
    assert :ok = wait_for_mirror_step(owner, :grant, :resolve_granted)

    lease_owner_monitor = Process.monitor(lease_owner)
    Process.exit(lease_owner, :kill)
    assert_receive {:DOWN, ^lease_owner_monitor, :process, ^lease_owner, :killed}, 500
    :sys.resume(components.registry)

    assert_receive {:manual_connection_message, ^successor_pid,
                    {:relay_permit_result, ^successor_origin, successor_result}},
                   1_000

    assert is_binary(successor_result["result"]["writer_epoch"])

    assert_receive {:manual_connection_message, ^successor_pid,
                    {:daemon_control_owner_lost, ^owner, close_ref, "existing-result-session",
                     holder_incarnation}},
                   1_000

    assert holder_incarnation == successor.incarnation
    close_owner_loss_holder(owner, successor, close_ref)
    assert_clean_retirement(owner, components)

    refute_receive {:manual_connection_message, _connection,
                    {:daemon_control_owner_lost, ^owner, _close_ref, _session_id, _incarnation}},
                   40

    assert Process.alive?(former_pid)
  end

  # Concept: under an existing lease owner, owner loss consumed before the
  # successor's result CAS cancels the grant: the provisional mirror is
  # cleared, the successor receives one correlated refusal and stays open,
  # and no epoch is exposed.
  #
  # Technical depth: the daemon owner is suspended while the registry
  # acknowledges the install, so the relay consumes the owner `DOWN` first and
  # answers the later result selection with `owner_lost`.
  test "an existing owner lost after install acknowledgement refuses its successor" do
    owner = start_owner(lease_term_ms: 40, mirror_deadline_ms: 5_000)
    components = Owner.components(owner)
    former = initialized_connection(components)
    successor = initialized_connection(components)
    former_pid = former.pid
    successor_pid = successor.pid

    {lease_owner, successor_origin} =
      park_existing_owner_grant(owner, components, former, successor, "existing-lost-session")

    :sys.suspend(owner)
    :sys.resume(components.registry)

    assert %{provisional_routing_mirrors: 1} =
             ConnectionRegistry.status(components.registry)

    lease_owner_monitor = Process.monitor(lease_owner)
    Process.exit(lease_owner, :kill)
    assert_receive {:DOWN, ^lease_owner_monitor, :process, ^lease_owner, :killed}, 500
    assert %{owner_losses: 1} = wait_for_relay_owner_loss(components.relay)
    :sys.resume(owner)

    assert_receive {:manual_connection_message, ^successor_pid,
                    {:relay_permit_cancelled, ^successor_origin, :control_owner_lost}},
                   1_000

    assert_clean_retirement(owner, components)

    refute_receive {:manual_connection_message, ^successor_pid,
                    {:relay_permit_result, ^successor_origin, _result}},
                   40

    refute_received {:manual_connection_message, _connection,
                     {:daemon_control_owner_lost, ^owner, _close_ref, _session_id, _incarnation}}

    assert Process.alive?(former_pid)
    assert Process.alive?(successor_pid)
  end

  # Concept: a fresh lease owner that dies after its grant reached the daemon
  # but before the registry committed the provisional mirror leaves one
  # terminal outcome: the daemon-actor grant settles, and owner loss then
  # closes the exact holder it produced once.
  #
  # Technical depth: the install request is queued at the suspended registry
  # when the child is killed, so the daemon owner consumes the linked `EXIT`
  # with its install already sent; the relay does not claim a daemon-actor
  # permit on the child's `DOWN`.
  test "a fresh owner lost before its install commits settles one grant and one close" do
    owner = start_owner(mirror_deadline_ms: 1_000)
    components = Owner.components(owner)
    holder = initialized_connection(components)
    holder_pid = holder.pid
    origin = {holder.incarnation, 0, 1}
    {worker, worker_incarnation} = start_worker(holder.pid, origin)
    :sys.suspend(components.registry)

    assert {:ok, :accepted, lease_owner, _owner_incarnation} =
             acquire_as(
               owner,
               origin,
               "uncommitted-install",
               "uncommitted-install-session",
               holder.pid,
               holder.incarnation,
               worker,
               worker_incarnation,
               now_ms() + 2_000
             )

    assert_receive {:worker_go, ^worker, ^origin}, 500
    assert :ok = wait_for_mirror_step(owner, :grant, :install)

    lease_owner_monitor = Process.monitor(lease_owner)
    Process.exit(lease_owner, :kill)
    assert_receive {:DOWN, ^lease_owner_monitor, :process, ^lease_owner, :killed}, 500
    assert %{lost_owners: 1} = Owner.status(owner)
    :sys.resume(components.registry)

    assert_receive {:manual_connection_message, ^holder_pid,
                    {:relay_permit_result, ^origin, acquire_result}},
                   1_000

    assert acquire_result["method"] == "session.acquire_control"

    assert_receive {:manual_connection_message, ^holder_pid,
                    {:daemon_control_owner_lost, ^owner, close_ref, "uncommitted-install-session",
                     holder_incarnation}},
                   1_000

    assert holder_incarnation == holder.incarnation
    close_owner_loss_holder(owner, holder, close_ref)
    assert_clean_retirement(owner, components)

    refute_received {:manual_connection_message, ^holder_pid,
                     {:relay_permit_result, ^origin, _second}}
  end

  # Concept: after an exact dead-owner pop and a successor grant, the dead
  # owner's identity can neither pop nor clear the successor's mirror.
  #
  # Technical depth: with the daemon owner suspended, the registry receives a
  # duplicate exact pop and an old exact granted clear in the daemon owner's
  # own mirror form; their acknowledgements are read from the suspended owner's
  # queue before it resumes and ignores their unknown references.
  test "a dead owner's duplicate pop and old clear leave the successor mirror in place" do
    owner = start_owner()
    components = Owner.components(owner)
    holder = initialized_connection(components)
    successor = initialized_connection(components)
    successor_pid = successor.pid

    {predecessor, predecessor_incarnation, predecessor_epoch} =
      acquire_held(owner, holder, "stale-mirror-session")

    predecessor_monitor = Process.monitor(predecessor)
    Process.exit(predecessor, :kill)
    assert_receive {:DOWN, ^predecessor_monitor, :process, ^predecessor, :killed}, 500

    assert_receive {:manual_connection_message, _holder_pid,
                    {:daemon_control_owner_lost, ^owner, close_ref, "stale-mirror-session",
                     _holder_incarnation}},
                   500

    close_owner_loss_holder(owner, holder, close_ref)
    successor_origin = {successor.incarnation, 0, 1}

    {successor_worker, successor_worker_incarnation} =
      start_worker(successor.pid, successor_origin)

    assert {:ok, :accepted, successor_owner, _successor_owner_incarnation} =
             acquire_as(
               owner,
               successor_origin,
               "stale-mirror-successor",
               "stale-mirror-session",
               successor.pid,
               successor.incarnation,
               successor_worker,
               successor_worker_incarnation,
               now_ms() + 2_000
             )

    assert_receive {:manual_connection_message, ^successor_pid,
                    {:relay_permit_result, ^successor_origin, _successor_result}},
                   500

    assert %{granted_routes: 1} = wait_for_owner_settlement(owner)
    :sys.suspend(owner)
    pop_ref = make_ref()
    clear_ref = make_ref()

    stale_owner = %{
      session_id: "stale-mirror-session",
      owner_pid: predecessor,
      owner_incarnation: predecessor_incarnation
    }

    stale_granted =
      Map.merge(stale_owner, %{
        phase: :granted,
        holder_pid: holder.pid,
        holder_incarnation: holder.incarnation,
        writer_epoch: predecessor_epoch
      })

    for {reference, action, row} <- [
          {pop_ref, :pop_owner_mirror, stale_owner},
          {clear_ref, :clear_granted, stale_granted}
        ] do
      send(
        components.registry,
        {:apply_mirror, reference, owner, components.routing_incarnation, action, row}
      )
    end

    assert %{granted_routing_mirrors: 1, provisional_routing_mirrors: 0} =
             ConnectionRegistry.status(components.registry)

    registry = components.registry
    routing_incarnation = components.routing_incarnation
    {:messages, queued} = Process.info(owner, :messages)
    assert {:mirror_applied, pop_ref, registry, routing_incarnation, {:ok, :absent}} in queued

    assert {:mirror_applied, clear_ref, registry, routing_incarnation, {:error, :mirror_conflict}} in queued

    :sys.resume(owner)

    assert %{live_owners: 1, granted_routes: 1} = wait_for_owner_settlement(owner)
    assert %{granted_routing_mirrors: 1} = ConnectionRegistry.status(components.registry)
    assert Process.alive?(successor_owner)

    refute_receive {:manual_connection_message, ^successor_pid,
                    {:daemon_control_owner_lost, ^owner, _close_ref, _session_id, _incarnation}},
                   40
  end

  # Concept: the registry never installs a provisional mirror for a
  # connection incarnation that is already closing.
  #
  # Technical depth: while the daemon owner is inside its bounded close of
  # every connection, each connection row is `closing` but its process is
  # still alive; an install in the daemon owner's own mirror form is refused
  # for that incarnation, while the same install for a live incarnation made
  # just before the close is accepted.
  test "the registry refuses a provisional install for a closing incarnation" do
    owner = start_owner()
    components = Owner.components(owner)
    live = initialized_connection(components)
    closing = initialized_connection(components)
    closing_pid = closing.pid

    install = fn connection, session_id ->
      row = %{
        permit_id: {connection.incarnation, 0, 1},
        start_op_ref: make_ref(),
        session_id: session_id,
        owner_pid: self(),
        owner_incarnation: incarnation(),
        holder_pid: connection.pid,
        holder_incarnation: connection.incarnation,
        writer_epoch: incarnation()
      }

      send(
        components.registry,
        {:apply_mirror, make_ref(), owner, components.routing_incarnation, :install_provisional,
         row}
      )

      ConnectionRegistry.status(components.registry)
    end

    assert %{provisional_routing_mirrors: 1} = install.(live, "live-install-session")
    record = WireRecords.daemon_stopping("operator_stop")
    close_task = Task.async(fn -> Owner.close_connections(owner, record, now_ms() + 200) end)

    assert_receive {:manual_connection_message, ^closing_pid, {:daemon_stopping, ^record}}, 500
    assert Process.alive?(closing_pid)
    assert %{closing: 2} = ConnectionRegistry.status(components.registry)

    assert %{provisional_routing_mirrors: 1, routing_mirrors: 1} =
             install.(closing, "closing-install-session")

    assert {:ok, :forced} = Task.await(close_task, 1_000)
  end

  # Concept: the crossing witness, stop first. A serving owner-loss
  # classification paused before its acknowledgement is overtaken by the
  # admission cut: the row is rebound to the transport-cut instant, its
  # private clock becomes cleanup-only, and the later acknowledgement completes
  # the loss without the uncorrelated `control_owner_lost` close.
  #
  # Technical depth: a relay debug hook parks the classification request. The
  # cut is consumed while it is parked; the owner-loss operation is asserted to
  # carry no timer and no step instant, and the daemon owner outlives its
  # 300 ms serving step. Releasing the relay acknowledges the
  # classification and then the cut; the holder receives nothing and stays
  # open for the later `daemon.stopping`/EOF path.
  test "a stop consumed before a paused classification rebinds it and closes no holder" do
    owner = start_owner(mirror_deadline_ms: 300)
    components = Owner.components(owner)
    holder = initialized_connection(components)
    holder_pid = holder.pid
    {lease_owner, _owner_incarnation, _epoch} = acquire_held(owner, holder, "stop-first-session")
    park_relay_classification(components.relay)
    lease_owner_monitor = Process.monitor(lease_owner)
    Process.exit(lease_owner, :kill)
    assert_receive {:DOWN, ^lease_owner_monitor, :process, ^lease_owner, :killed}, 500
    assert_receive :relay_classification_parked, 500

    cut_started = now_ms()
    cut_task = Task.async(fn -> Owner.cut_admission(owner, 5_000) end)
    assert :ok = wait_for_stop(owner)

    assert [%{step: :await_classification, timer: nil, step_deadline: nil}] =
             owner_loss_operations(owner)

    assert now_ms() >= cut_started
    Process.sleep(400)
    assert Process.alive?(owner)
    send(components.relay, :continue_parked_classification)
    assert {:ok, _cut_ref} = Task.await(cut_task, 1_000)

    assert %{lost_owners: 0, owner_slots: 0, mirror_operations: 0} =
             wait_for_owner_retirement(owner)

    refute_receive {:manual_connection_message, ^holder_pid,
                    {:daemon_control_owner_lost, _owner, _close_ref, _session_id, _incarnation}},
                   40

    assert Process.alive?(holder_pid)
    assert %{routing_mirrors: 0} = ConnectionRegistry.status(components.registry)
    assert %{owner_losses: 0} = AdmissionRelay.status(components.relay)
  end

  # Concept: the crossing witness, classification first. A classification
  # whose acknowledgement the daemon owner consumes before the stop completes
  # its selected form as an ordinary pre-cut result.
  #
  # Technical depth: the relay is parked on the classification while the
  # daemon owner is suspended; releasing the relay queues the acknowledgement
  # ahead of the later cut call, so the daemon owner consumes it first and
  # emits the one uncorrelated close before accepting the cut.
  test "a classification completed before the stop keeps its selected holder close" do
    owner = start_owner(mirror_deadline_ms: 1_000)
    components = Owner.components(owner)
    holder = initialized_connection(components)
    holder_pid = holder.pid

    {lease_owner, _owner_incarnation, _epoch} =
      acquire_held(owner, holder, "classified-first-session")

    park_relay_classification(components.relay)
    lease_owner_monitor = Process.monitor(lease_owner)
    Process.exit(lease_owner, :kill)
    assert_receive {:DOWN, ^lease_owner_monitor, :process, ^lease_owner, :killed}, 500
    assert_receive :relay_classification_parked, 500

    :sys.suspend(owner)
    send(components.relay, :continue_parked_classification)
    assert :ok = wait_for_queue_length(owner, 1)
    cut_task = Task.async(fn -> Owner.cut_admission(owner, 5_000) end)
    assert :ok = wait_for_queue_length(owner, 2)
    :sys.resume(owner)

    assert_receive {:manual_connection_message, ^holder_pid,
                    {:daemon_control_owner_lost, ^owner, close_ref, "classified-first-session",
                     holder_incarnation}},
                   500

    assert holder_incarnation == holder.incarnation
    assert {:ok, _cut_ref} = Task.await(cut_task, 1_000)
    close_owner_loss_holder(owner, holder, close_ref)

    assert %{lost_owners: 0, owner_slots: 0, mirror_operations: 0} =
             wait_for_owner_retirement(owner)
  end

  # Concept: owner losses after the admission cut join the stop barrier
  # rather than each starting a clock: at the maximum live-owner population,
  # every exact `DOWN` and mirror-pop fact, delivered in both orders, settles
  # under the one freeze deadline with no `control_owner_lost` form.
  #
  # Technical depth: 512 held owners on one connection are cut, then half are
  # killed with the relay suspended (pop first) and half with the registry
  # suspended (relay `DOWN` first). While each half is parked every owner-loss
  # operation is asserted to carry no timer, and the daemon owner outlives its
  # 200 ms serving deadline. The freeze barrier, under one five-second
  # deadline, answers only after all 512 losses have joined.
  @tag timeout: 180_000
  test "owner losses after the cut join one stop deadline at the maximum population" do
    owner = start_owner(mirror_deadline_ms: 200)
    components = Owner.components(owner)
    connection = initialized_connection(components)
    connection_pid = connection.pid

    owners =
      for sequence <- 1..512 do
        origin = {connection.incarnation, 0, sequence}
        {worker, worker_incarnation} = start_worker(connection.pid, origin)

        assert {:ok, :accepted, lease_owner, _owner_incarnation} =
                 acquire_as(
                   owner,
                   origin,
                   "overlap-#{sequence}",
                   "overlap-#{sequence}",
                   connection.pid,
                   connection.incarnation,
                   worker,
                   worker_incarnation,
                   now_ms() + 5_000
                 )

        # Each grant carries its own 5 s deadline; its result is awaited for
        # that long, since 512 grants on a loaded machine are not instant.
        assert_receive {:manual_connection_message, _, {:relay_permit_result, ^origin, _result}},
                       5_000

        lease_owner
      end

    assert %{live_owners: 512, granted_routes: 512} = wait_for_owner_settlement(owner, 400)
    assert {:ok, _cut_ref} = Owner.cut_admission(owner, 5_000)
    {pop_first, down_first} = Enum.split(owners, 256)

    :sys.suspend(components.relay)
    Enum.each(pop_first, &Process.exit(&1, :kill))
    assert :ok = wait_for_owner_loss_step(owner, :await_classification, 256)
    assert Enum.all?(owner_loss_operations(owner), &is_nil(&1.timer))
    Process.sleep(300)
    assert Process.alive?(owner)

    :sys.suspend(components.registry)
    :sys.resume(components.relay)
    Enum.each(down_first, &Process.exit(&1, :kill))
    assert :ok = wait_for_owner_loss_step(owner, :pop_owner, 256)
    assert Enum.all?(owner_loss_operations(owner), &is_nil(&1.timer))
    :sys.resume(components.registry)

    started = now_ms()
    assert {:ok, []} = freeze(owner)
    assert now_ms() - started < 5_000

    assert %{lost_owners: 0, live_owners: 0, owner_slots: 0, mirror_operations: 0} =
             Owner.status(owner)

    assert %{routing_mirrors: 0} = ConnectionRegistry.status(components.registry)
    assert %{owner_losses: 0, lease_owners: 0} = AdmissionRelay.status(components.relay)

    refute_received {:manual_connection_message, ^connection_pid,
                     {:daemon_control_owner_lost, _owner, _close_ref, _session_id, _incarnation}}

    assert Process.alive?(connection_pid)
  end

  # Concept: the freeze wins an existing owner's still-executing acquire as
  # `shutdown_admitted`; the daemon owner kills and reaps that exact actor,
  # pops its granted mirror and joins the relay's owner loss, all without a
  # reply, refusal or holder close, while a promoted mutation under the same
  # owner stays on its real-result path.
  #
  # Technical depth: the attached holder's mutation is promoted and blocked in
  # its task, so the holder's renewal queues behind it and its permit is
  # executing under the lease owner when the freeze arrives. The barrier
  # returns that one descriptor only after the kill, the exact pop and the
  # classification have finished; the blocked task then delivers its result.
  test "the freeze kills an existing owner it admitted and joins its loss without output" do
    owner = start_owner()
    components = Owner.components(owner)
    holder = initialized_connection(components)
    holder_pid = holder.pid
    session_id = "admitted-session"
    {lease_owner, owner_incarnation, epoch} = acquire_held(owner, holder, session_id)

    send(
      owner,
      {:registry_attachment, components.registry, nil, :opened, session_id, holder.pid,
       holder.incarnation, "admitted-attachment"}
    )

    assert :ok = wait_for_attachment(lease_owner)
    mutation_origin = {holder.incarnation, 1, 1}
    ticket_worker = start_ticket_worker(holder.pid)
    parent = self()
    result = %{"operation" => "prompt", "status" => "accepted"}

    assert {:ok, :admitted} =
             manual_call(
               holder.pid,
               {:invoke,
                fn ->
                  with {:ok, ^mutation_origin} <-
                         AdmissionRelay.open_ticket(
                           components.relay,
                           mutation_origin,
                           :session_prompt,
                           session_id,
                           {lease_owner, owner_incarnation}
                         ),
                       :ok <-
                         AdmissionRelay.bind_ticket_worker(
                           components.relay,
                           mutation_origin,
                           ticket_worker,
                           incarnation()
                         ) do
                    lease_mutate(
                      lease_owner,
                      mutation_origin,
                      :session_prompt,
                      "admitted-mutation",
                      holder.incarnation,
                      epoch,
                      ticket_worker,
                      fn ->
                        send(parent, {:mutation_waiting, self()})

                        receive do
                          :complete -> {:accepted, result}
                        end
                      end
                    )
                  end
                end}
             )

    assert_receive {:mutation_waiting, task}, 500
    origin = {holder.incarnation, 2, 1}
    {worker, worker_incarnation} = start_worker(holder.pid, origin)

    assert {:ok, :accepted, ^lease_owner, ^owner_incarnation} =
             acquire_as(
               owner,
               origin,
               "admitted-renewal",
               session_id,
               holder.pid,
               holder.incarnation,
               worker,
               worker_incarnation,
               now_ms() + 5_000
             )

    assert_receive {:worker_go, ^worker, ^origin}, 500
    assert {:ok, _cut_ref} = Owner.cut_admission(owner, 5_000)
    lease_owner_monitor = Process.monitor(lease_owner)

    assert {:ok,
            [
              {:shutdown_admitted, ^origin, :session_acquire_control, ^lease_owner,
               ^owner_incarnation, nil}
            ]} = freeze(owner)

    assert_receive {:DOWN, ^lease_owner_monitor, :process, ^lease_owner, :killed}, 500

    assert %{
             lease_operations: 0,
             mirror_operations: 0,
             lost_owners: 0,
             owner_slots: 0,
             granted_routes: 0
           } = Owner.status(owner)

    assert %{routing_mirrors: 0} = ConnectionRegistry.status(components.registry)
    assert %{permits: 0, owner_losses: 0, tickets: 1} = AdmissionRelay.status(components.relay)

    # A proposal the killed actor had already sent for the tombstoned permit
    # arrives after the freeze and creates no mirror row.
    send(
      owner,
      {:lease_grant_proposed, make_ref(), origin, lease_owner, owner_incarnation, session_id,
       holder.pid, holder.incarnation, :crypto.strong_rand_bytes(16), now_ms() + 5_000}
    )

    send(
      owner,
      {:release_proposed, make_ref(), origin, lease_owner, owner_incarnation, holder.incarnation}
    )

    assert %{mirror_operations: 0, lease_operations: 0} = Owner.status(owner)
    assert Process.alive?(owner)
    send(task, :complete)

    assert_receive {:manual_connection_message, ^holder_pid,
                    {:relay_ticket_result, ^mutation_origin, ^result}},
                   500

    refute_receive {:manual_connection_message, ^holder_pid,
                    {:daemon_control_owner_lost, _owner, _close_ref, _session_id, _incarnation}},
                   40

    refute_received {:manual_connection_message, ^holder_pid,
                     {:relay_permit_result, ^origin, _result}}

    refute_received {:manual_connection_message, ^holder_pid,
                     {:relay_permit_cancelled, ^origin, _reason}}
  end

  # Concept: a fresh acquire whose owner was never materialized is the daemon
  # owner's own barrier-owned row; its retained start record says so, the
  # operation is tombstoned and its reserved slot released, and no successor
  # owner starts afterwards.
  #
  # Technical depth: the predecessor's retirement exit is gated, so the
  # successor acquire waits unmaterialized. The freeze names it with the
  # daemon owner as actor and its exact start reference; after the gates open
  # the predecessor retires and no owner remains.
  test "the freeze tombstones a fresh acquire whose owner never materialized" do
    owner = start_owner(retirement_pop_gate: self(), retirement_exit_gate: self())
    components = Owner.components(owner)
    connection = initialized_connection(components)
    connection_pid = connection.pid
    session_id = "unmaterialized-session"

    {predecessor, predecessor_incarnation, epoch} =
      acquire_held(owner, connection, session_id)

    release_origin = {connection.incarnation, 1, 1}
    {release_worker, release_worker_incarnation} = start_worker(connection.pid, release_origin)

    assert {:ok, :accepted, ^predecessor, ^predecessor_incarnation} =
             release_as(
               owner,
               release_origin,
               "unmaterialized-release",
               session_id,
               connection.pid,
               connection.incarnation,
               release_worker,
               release_worker_incarnation,
               epoch,
               now_ms() + 5_000
             )

    assert_receive {:manual_connection_message, _,
                    {:relay_permit_result, ^release_origin, _release_result}},
                   500

    assert_receive {:retirement_exit_blocked, ^predecessor, ^predecessor_incarnation,
                    retirement_ref},
                   500

    successor_origin = {connection.incarnation, 2, 1}

    {successor_worker, successor_worker_incarnation} =
      start_worker(connection.pid, successor_origin)

    daemon_incarnation = components.daemon_incarnation

    assert {:ok, :accepted, ^owner, ^daemon_incarnation} =
             acquire_as(
               owner,
               successor_origin,
               "unmaterialized-successor",
               session_id,
               connection.pid,
               connection.incarnation,
               successor_worker,
               successor_worker_incarnation,
               now_ms() + 5_000
             )

    assert_receive {:worker_go, ^successor_worker, ^successor_origin}, 500
    assert %{waiting_owner_starts: 1} = Owner.status(owner)
    assert {:ok, _cut_ref} = Owner.cut_admission(owner, 5_000)

    assert {:ok,
            [
              {:shutdown_admitted, ^successor_origin, :session_acquire_control, ^owner,
               ^daemon_incarnation, start_op_ref}
            ]} = freeze(owner)

    assert is_reference(start_op_ref)
    assert %{waiting_owner_starts: 0, lease_operations: 0} = Owner.status(owner)

    assert :ok = LeaseOwner.release_retirement_exit(predecessor, retirement_ref)
    assert_receive {:retirement_pop_blocked, ^owner, ^session_id}, 500
    assert :ok = Owner.release_retirement_pop(owner, session_id)

    assert %{owner_slots: 0, live_owners: 0, mirror_operations: 0} =
             wait_for_owner_retirement(owner)

    refute_receive {:manual_connection_message, ^connection_pid,
                    {:relay_permit_result, ^successor_origin, _result}},
                   40

    assert %{permits: 0, lease_owners: 0} = AdmissionRelay.status(components.relay)
  end

  # Concept: the admission cut makes a release's serving clocks cleanup-only,
  # so a lease owner that has not restored after a connection loss is not
  # killed by `owner_restore_deadline`; the freeze then owns it and kills,
  # supersedes and reaps it without a reply.
  #
  # Technical depth: the release is proposed, its connection is lost before
  # the result CAS, and the lease owner is suspended when the cancellation
  # reaches it. After the cut the daemon owner outlives the 200 ms restore
  # instant with the owner still alive. The freeze names the
  # `settling_release` row with its connection-loss disposition, kills the
  # owner, terminalizes the no-reply settlement and pops the granted mirror.
  # Technical depth: the restore clock runs from the park until the cut, so its
  # 2 s deadline leaves a loaded machine room to reach the cut first; the
  # 2.3 s sleep after the cut then outlasts that deadline, which proves the cut
  # made the clock cleanup-only.
  test "the cut makes release clocks cleanup-only and the freeze supersedes an unrestored owner" do
    owner = start_owner(mirror_deadline_ms: 2_000)
    components = Owner.components(owner)
    connection = initialized_connection(components)
    session_id = "frozen-release-session"

    {lease_owner, owner_incarnation, release_origin, loss_ref} =
      park_release_cancellation(owner, components, connection, session_id)

    assert {:ok, _cut_ref} = Owner.cut_admission(owner, 5_000)
    Process.sleep(2_300)
    assert Process.alive?(lease_owner)
    assert Process.alive?(owner)
    lease_owner_monitor = Process.monitor(lease_owner)

    assert {:ok,
            [
              {:settling_release, ^release_origin, :connection_lost, ^lease_owner,
               ^owner_incarnation, ^loss_ref}
            ]} = freeze(owner)

    assert_receive {:DOWN, ^lease_owner_monitor, :process, ^lease_owner, :killed}, 500

    assert %{lease_operations: 0, mirror_operations: 0, lost_owners: 0, owner_slots: 0} =
             Owner.status(owner)

    assert %{routing_mirrors: 0} = ConnectionRegistry.status(components.registry)
    assert %{permits: 0, owner_losses: 0} = AdmissionRelay.status(components.relay)
  end

  # Concept: while serving, a lease owner that stays paused through
  # `owner_restore_deadline` cannot keep `release_pending`: the daemon owner
  # kills that exact owner, supersedes the cancellation without a reply, and
  # the ordinary owner-loss path finishes; the daemon itself keeps serving.
  #
  # Technical depth: the owner is suspended when the cancellation reaches it;
  # the 200 ms restore instant fires, the owner is killed and the no-reply
  # settlement and owner-loss pop leave no operation, mirror or permit.
  test "an owner paused through the restore deadline is killed and superseded" do
    owner = start_owner(mirror_deadline_ms: 200)
    components = Owner.components(owner)
    connection = initialized_connection(components)

    {lease_owner, _owner_incarnation, _release_origin, _loss_ref} =
      park_release_cancellation(owner, components, connection, "paused-restore-session")

    lease_owner_monitor = Process.monitor(lease_owner)
    assert_receive {:DOWN, ^lease_owner_monitor, :process, ^lease_owner, :killed}, 1_000
    assert Process.alive?(owner)
    assert_clean_retirement(owner, components)
  end

  # Concept: an owner restoration acknowledgement queued before
  # `owner_restore_deadline` but consumed at or after it is cleanup-only: the
  # daemon owner still kills that exact owner and supersedes the cancellation.
  #
  # Technical depth: the daemon owner is suspended while the resumed lease
  # owner restores and acknowledges, and stays suspended past the 300 ms
  # instant so the acknowledgement is queued ahead of the timer. On resume the
  # acknowledgement is consumed late, and the restored owner is killed.
  test "a restoration acknowledgement consumed after the restore deadline is cleanup-only" do
    owner = start_owner(mirror_deadline_ms: 300)
    components = Owner.components(owner)
    connection = initialized_connection(components)

    {lease_owner, _owner_incarnation, _release_origin, _loss_ref} =
      park_release_cancellation(owner, components, connection, "late-restore-session")

    :sys.suspend(owner)
    lease_owner_monitor = Process.monitor(lease_owner)
    :sys.resume(lease_owner)
    assert :ok = wait_for_queue_length(owner, 1)
    Process.sleep(350)
    :sys.resume(owner)

    assert_receive {:DOWN, ^lease_owner_monitor, :process, ^lease_owner, :killed}, 1_000
    assert Process.alive?(owner)
    assert_clean_retirement(owner, components)
  end

  # Concept (P1, T16 for a release): each step of a release has its own
  # instant, so a selection and a settlement that each take most of their own
  # step still render the one correlated success, although together they
  # outlast any single step.
  #
  # Technical depth: the relay is parked on the result selection and then on
  # the result settlement for 350 ms each, against a 500 ms step.
  test "a release whose steps each use most of their instant succeeds" do
    owner = start_owner(mirror_deadline_ms: 500)
    components = Owner.components(owner)
    holder = initialized_connection(components)
    holder_pid = holder.pid
    session_id = "settled-in-time-session"
    {lease_owner, owner_incarnation, writer_epoch} = acquire_held(owner, holder, session_id)
    release_origin = {holder.incarnation, 1, 1}
    {release_worker, release_worker_incarnation} = start_worker(holder.pid, release_origin)
    park_relay_operation(components.relay, :select_result)
    park_relay_operation(components.relay, :settle_result)

    assert {:ok, :accepted, ^lease_owner, ^owner_incarnation} =
             release_as(
               owner,
               release_origin,
               "settled-in-time",
               session_id,
               holder.pid,
               holder.incarnation,
               release_worker,
               release_worker_incarnation,
               writer_epoch,
               now_ms() + 5_000
             )

    assert_receive {:relay_operation_parked, :select_result}, 500
    Process.sleep(350)
    send(components.relay, :continue_parked_operation)
    assert_receive {:relay_operation_parked, :settle_result}, 500
    Process.sleep(350)
    send(components.relay, :continue_parked_operation)

    assert_receive {:manual_connection_message, ^holder_pid,
                    {:relay_permit_result, ^release_origin, release_result}},
                   500

    assert release_result == WireRecords.control_released("settled-in-time")
    assert_clean_retirement(owner, components)
  end

  # Concept: a relay result settlement still missing at
  # `release_settlement_deadline` selects `relay_lost`, never
  # `connections_lost` and never a success.
  #
  # Technical depth: the relay stays parked on the result settlement; the
  # daemon owner's timer passes the 200 ms restore instant, rearms for the
  # 400 ms settlement instant and stops the daemon owner as `relay_lost`.
  test "a release settlement missing at the settlement deadline selects relay_lost" do
    owner = start_owner(mirror_deadline_ms: 200)
    components = Owner.components(owner)
    holder = initialized_connection(components)
    holder_pid = holder.pid
    session_id = "settlement-deadline-session"
    {lease_owner, owner_incarnation, writer_epoch} = acquire_held(owner, holder, session_id)
    release_origin = {holder.incarnation, 1, 1}
    {release_worker, release_worker_incarnation} = start_worker(holder.pid, release_origin)
    park_relay_operation(components.relay, :settle_result)
    owner_monitor = Process.monitor(owner)

    assert {:ok, :accepted, ^lease_owner, ^owner_incarnation} =
             release_as(
               owner,
               release_origin,
               "settlement-deadline",
               session_id,
               holder.pid,
               holder.incarnation,
               release_worker,
               release_worker_incarnation,
               writer_epoch,
               now_ms() + 5_000
             )

    assert_receive {:relay_operation_parked, :settle_result}, 500
    assert_receive {:DOWN, ^owner_monitor, :process, ^owner, :relay_lost}, 1_000

    refute_received {:manual_connection_message, ^holder_pid,
                     {:relay_permit_result, ^release_origin, _result}}
  end

  # Concept: freeze cleanup fails closed: a descriptor set the daemon owner
  # cannot match to its own records is `relay_lost` and begins no cleanup.
  #
  # Technical depth: the relay is parked on the freeze and an
  # acknowledgement with the exact barrier reference but an unknown tag is
  # delivered to the daemon owner.
  test "an unmatched freeze descriptor selects relay_lost" do
    owner = start_owner()
    components = Owner.components(owner)
    assert {:ok, _cut_ref} = Owner.cut_admission(owner, 5_000)
    park_relay_freeze(components.relay)
    freeze_task = Task.async(fn -> freeze(owner) end)
    assert_receive :relay_freeze_parked, 500
    %{stop: %{barrier: %{ref: barrier_ref}}} = :sys.get_state(owner)

    send(
      owner,
      {:relay_barrier_ack, barrier_ref, :freeze_lease_ops, [{:rolled_back, :origin}]}
    )

    assert {:error, :relay_lost} = Task.await(freeze_task, 1_000)
    send(components.relay, :continue_parked_freeze)
  end

  # Concept: mirror work still unfinished at `freeze_deadline` is
  # `connections_lost`, and the exact registry is killed rather than trusted.
  #
  # Technical depth: the registry is suspended with an expiry clear pending
  # when a 200 ms freeze begins.
  test "mirror work unfinished at the freeze deadline selects connections_lost" do
    owner = start_owner(lease_term_ms: 400)
    components = Owner.components(owner)
    holder = initialized_connection(components)
    _held = acquire_held(owner, holder, "unfinished-mirror-session")
    assert {:ok, _cut_ref} = Owner.cut_admission(owner, 5_000)
    :sys.suspend(components.registry)
    assert :ok = wait_for_mirror_step(owner, :expiry, :clear)
    registry_monitor = Process.monitor(components.registry)
    assert {:error, :connections_lost} = freeze(owner, 200)
    assert_receive {:DOWN, ^registry_monitor, :process, _registry, :killed}, 500
  end

  # Concept: a freeze that fails only because the relay has not answered an
  # owner-loss classification is `relay_lost`, and the registry, which
  # answered everything asked of it, is not killed.
  #
  # Technical depth: after the cut a held owner is killed while the registry
  # is suspended, so its mirror pop waits; the freeze is acknowledged, the
  # registry is resumed, and the relay is parked on the classification that
  # follows. At the 400 ms freeze deadline only the classification is
  # unfinished.
  test "a classification unfinished at the freeze deadline selects relay_lost" do
    owner = start_owner()
    components = Owner.components(owner)
    holder = initialized_connection(components)
    {lease_owner, _owner_incarnation, _epoch} = acquire_held(owner, holder, "late-class-session")
    assert {:ok, _cut_ref} = Owner.cut_admission(owner, 5_000)
    park_relay_classification(components.relay)
    :sys.suspend(components.registry)
    Process.exit(lease_owner, :kill)
    assert :ok = wait_for_owner_loss_step(owner, :pop_owner, 1)
    freeze_task = Task.async(fn -> freeze(owner, 400) end)
    assert :ok = wait_for_freeze_descriptors(owner)
    :sys.resume(components.registry)
    assert_receive :relay_classification_parked, 500
    assert {:error, :relay_lost} = Task.await(freeze_task, 1_000)
    assert Process.alive?(components.registry)
    send(components.relay, :continue_parked_classification)
  end

  # Concept: a settling descriptor must name the exact settlement the daemon
  # owner retained for that permit; a different reference means the relay and
  # the daemon owner disagree, which is `relay_lost`, and nothing is cleaned.
  #
  # Technical depth: a connection-loss release is left waiting for its owner's
  # restoration; with the relay parked on the freeze, an acknowledgement
  # naming that exact permit, disposition and actor but a fresh reference is
  # delivered, and the unrestored owner is not killed.
  test "a settling descriptor whose reference does not match selects relay_lost" do
    owner = start_owner(mirror_deadline_ms: 1_000)
    components = Owner.components(owner)
    connection = initialized_connection(components)

    {lease_owner, owner_incarnation, release_origin, _loss_ref} =
      park_release_cancellation(owner, components, connection, "mismatched-ref-session")

    assert {:ok, _cut_ref} = Owner.cut_admission(owner, 5_000)
    park_relay_freeze(components.relay)
    freeze_task = Task.async(fn -> freeze(owner) end)
    assert_receive :relay_freeze_parked, 500
    %{stop: %{barrier: %{ref: barrier_ref}}} = :sys.get_state(owner)

    send(
      owner,
      {:relay_barrier_ack, barrier_ref, :freeze_lease_ops,
       [
         {:settling_release, release_origin, :connection_lost, lease_owner, owner_incarnation,
          make_ref()}
       ]}
    )

    assert {:error, :relay_lost} = Task.await(freeze_task, 1_000)
    assert Process.alive?(lease_owner)
    send(components.relay, :continue_parked_freeze)
  end

  # Concept: a connection lost while an existing owner still holds its
  # claimed acquire queued is settled while serving: the daemon owner tells
  # that owner to discard it and settles the loss itself, so no relay row,
  # operation or disposition leaks and the owner can later retire.
  #
  # Technical depth: the successor queues behind an expiry whose mirror clear
  # waits on the suspended registry, with a 300 ms request deadline. Its
  # connection is killed; the discard settles it before that deadline would
  # have made the owner refuse it on a row nobody settles. After the registry
  # resumes the expired owner retires and its slot frees.
  test "a queued acquire whose connection is lost is discarded and settled while serving" do
    owner = start_owner(lease_term_ms: 40)
    components = Owner.components(owner)
    former = initialized_connection(components)
    successor = initialized_connection(components)

    {lease_owner, _owner_incarnation, _successor_origin} =
      queue_successor_behind_expiry(owner, components, former, successor, "discard-session")

    assert :ok = wait_for_lease_owner(lease_owner, &(&1.waiting_acquires == 1))
    Process.exit(successor.pid, :kill)

    assert :ok =
             wait_for_status(owner, &(&1.pending_dispositions == 0 and &1.lease_operations == 0))

    assert %{waiting_acquires: 0} = LeaseOwner.status(lease_owner)

    Process.sleep(400)
    :sys.resume(components.registry)
    assert_clean_retirement(owner, components)
  end

  # Concept: an owner lost before it answers a discard cannot settle it, so
  # its exact `EXIT` settles every connection loss retained for its
  # unproposed operations, and the ordinary owner-loss path then finishes.
  #
  # Technical depth: the lease owner is suspended when the successor's
  # connection is lost and then killed; after the registry resumes no
  # operation, disposition, mirror or permit remains.
  test "an owner lost before its discard answer still settles the retained loss" do
    owner = start_owner(lease_term_ms: 40)
    components = Owner.components(owner)
    former = initialized_connection(components)
    successor = initialized_connection(components)

    {lease_owner, _owner_incarnation, _successor_origin} =
      queue_successor_behind_expiry(owner, components, former, successor, "lost-discard-session")

    :sys.suspend(lease_owner)
    Process.exit(successor.pid, :kill)
    assert :ok = wait_for_pending_dispositions(owner, 1)
    lease_owner_monitor = Process.monitor(lease_owner)
    Process.exit(lease_owner, :kill)
    assert_receive {:DOWN, ^lease_owner_monitor, :process, ^lease_owner, :killed}, 500
    :sys.resume(components.registry)
    assert_clean_retirement(owner, components)
  end

  # Concept: at the freeze, a retained connection loss for an existing
  # owner's unproposed acquire is settled without the discard round trip:
  # the operation is tombstoned, its no-reply settlement terminalizes the
  # exact row named by the matching reference, and that exact owner is killed
  # so it can neither keep the queued acquire nor propose it later.
  #
  # Technical depth: the lease owner is suspended when the successor's
  # connection is lost, so its discard is unanswered. The freeze names the
  # `settling_acquire` descriptor with the retained loss reference, kills the
  # owner and answers once its loss has joined.
  test "the freeze settles a retained loss for an unproposed existing-owner acquire" do
    owner = start_owner(lease_term_ms: 40)
    components = Owner.components(owner)
    former = initialized_connection(components)
    successor = initialized_connection(components)

    {lease_owner, owner_incarnation, successor_origin} =
      queue_successor_behind_expiry(owner, components, former, successor, "frozen-loss-session")

    :sys.suspend(lease_owner)
    Process.exit(successor.pid, :kill)
    assert :ok = wait_for_pending_dispositions(owner, 1)

    [loss_ref] =
      for {_permit_id, %{settlement_ref: loss_ref}} <- :sys.get_state(owner).pending_dispositions,
          do: loss_ref

    :sys.resume(components.registry)
    assert :ok = wait_for_mirror_step(owner, :expiry, :resolve_owner_expiry)
    assert {:ok, _cut_ref} = Owner.cut_admission(owner, 5_000)
    lease_owner_monitor = Process.monitor(lease_owner)

    assert {:ok,
            [
              {:settling_acquire, ^successor_origin, :connection_lost, ^lease_owner,
               ^owner_incarnation, nil, ^loss_ref}
            ]} = freeze(owner)

    assert_receive {:DOWN, ^lease_owner_monitor, :process, ^lease_owner, :killed}, 500

    assert %{
             pending_dispositions: 0,
             lease_operations: 0,
             mirror_operations: 0,
             lost_owners: 0,
             owner_slots: 0
           } = Owner.status(owner)

    assert %{permits: 0} = AdmissionRelay.status(components.relay)
  end

  # Concept (risk packet fix 2): a settlement the freeze starts has no mirror
  # instant of its own: while the relay takes longer than the serving step to
  # settle it, the freeze deadline governs, so the daemon is never failed
  # `connections_lost` for it.
  #
  # Technical depth: as above, but the relay parks on the freeze's no-reply
  # disposition settlement for six seconds, past the five-second mirror
  # step, inside a ten-second freeze window.
  @tag timeout: 30_000
  test "a freeze-time settlement outlasting the mirror step does not fail connections" do
    owner = start_owner(lease_term_ms: 40, fatal_recipient: self())
    components = Owner.components(owner)
    former = initialized_connection(components)
    successor = initialized_connection(components)

    {lease_owner, _owner_incarnation, _successor_origin} =
      queue_successor_behind_expiry(owner, components, former, successor, "slow-freeze-loss")

    :sys.suspend(lease_owner)
    Process.exit(successor.pid, :kill)
    assert :ok = wait_for_pending_dispositions(owner, 1)
    :sys.resume(components.registry)
    assert :ok = wait_for_mirror_step(owner, :expiry, :resolve_owner_expiry)
    assert {:ok, _cut_ref} = Owner.cut_admission(owner, 5_000)
    test_pid = self()

    :ok =
      :sys.install(
        components.relay,
        {fn
           :waiting, {:in, message}, _state
           when is_tuple(message) and elem(message, 0) == :relay_lease_operation and
                  elem(message, 4) == :settle_disposition ->
             send(test_pid, :settlement_parked)
             Process.sleep(6_000)
             :done

           hook_state, _event, _state ->
             hook_state
         end, :waiting}
      )

    frozen = Task.async(fn -> freeze(owner, 10_000) end)
    assert_receive :settlement_parked, 2_000

    assert {:ok, [{:settling_acquire, _, :connection_lost, _, _, _, _}]} =
             Task.await(frozen, 12_000)

    refute_received {:daemon_component_fatal, _reporter, _class}
    assert Process.alive?(owner)
  end

  # Concept: a connection loss the relay reports after the daemon owner has
  # already consumed the exact owner's `EXIT` is settled at once rather than
  # sent as a discard nobody can answer, so the lost owner's pop, its slot and
  # any successor are not held forever.
  #
  # Technical depth: the relay is suspended while the successor's connection
  # and then the lease owner are killed, so the daemon owner consumes the
  # owner's `EXIT` first. Resuming the relay delivers the connection-loss
  # disposition for the owner's unproposed acquire; after the registry
  # resumes, nothing is left.
  test "a loss reported after its owner's exit is settled without a discard" do
    owner = start_owner(lease_term_ms: 40)
    components = Owner.components(owner)
    former = initialized_connection(components)
    successor = initialized_connection(components)

    {lease_owner, _owner_incarnation, _successor_origin} =
      queue_successor_behind_expiry(owner, components, former, successor, "exit-first-session")

    :sys.suspend(components.relay)
    Process.exit(successor.pid, :kill)
    lease_owner_monitor = Process.monitor(lease_owner)
    Process.exit(lease_owner, :kill)
    assert_receive {:DOWN, ^lease_owner_monitor, :process, ^lease_owner, :killed}, 500
    assert :ok = wait_for_status(owner, &(&1.lost_owners == 1))
    assert %{pending_dispositions: 0, lease_operations: 1} = Owner.status(owner)
    :sys.resume(components.relay)
    :sys.resume(components.registry)
    assert_clean_retirement(owner, components)
  end

  # Concept: a fresh child whose first acquire lost its connection before it
  # proposed is killed at the freeze and its permit tombstoned, so a proposal
  # it sent just before the kill creates no mirror row and does not stop the
  # daemon owner.
  #
  # Technical depth: a debug hook holds the child as its first acquire
  # arrives, so the daemon owner's call times out and the acquire is kept
  # unproposed; the connection is then lost and the loss retained. After the
  # freeze has killed the child and settled the loss, the proposal the child
  # would have sent is delivered to the daemon owner; the kill always lands
  # before the held child can send it, so it is delivered from the test.
  @tag timeout: 60_000
  test "the freeze tombstones a fresh child's unproposed acquire and kills the child" do
    owner = start_owner()
    components = Owner.components(owner)
    holder = initialized_connection(components)
    origin = {holder.incarnation, 0, 1}
    {worker, worker_incarnation} = start_worker(holder.pid, origin)
    test_pid = self()

    :ok =
      :sys.install(
        components.relay,
        {fn
           :waiting,
           {:in, {:"$gen_call", _from, {:register_lease_owner, "held-child-session", child, _}}},
           _proc_state ->
             send(test_pid, {:registering, child})

             receive do
               :continue_registration -> :done
             end

           :waiting, _event, _proc_state ->
             :waiting
         end, :waiting}
      )

    # The daemon owner's own call to the held child times out after five
    # seconds, so the acquire is called with a longer bound than the client's.
    acquire =
      Task.async(fn ->
        acquire_as(
          owner,
          origin,
          "held-child-acquire",
          "held-child-session",
          holder.pid,
          holder.incarnation,
          worker,
          worker_incarnation,
          now_ms() + 30_000,
          10_000
        )
      end)

    assert_receive {:registering, child}, 500
    :sys.suspend(child)
    send(components.relay, :continue_registration)

    :ok =
      :sys.install(
        child,
        {fn
           :waiting, {:in, {:lease_request, _owner, _incarnation, request}}, _proc_state
           when is_tuple(request) and elem(request, 0) == :first_acquire ->
             send(test_pid, :first_acquire_held)

             receive do
               :never -> :done
             end

           :waiting, _event, _proc_state ->
             :waiting
         end, :waiting}
      )

    :sys.resume(child)
    assert_receive :first_acquire_held, 500
    assert {:ok, :accepted, ^child, child_incarnation} = Task.await(acquire, 10_000)
    Process.exit(holder.pid, :kill)
    assert :ok = wait_for_pending_dispositions(owner, 1)
    assert {:ok, _cut_ref} = Owner.cut_admission(owner, 5_000)
    child_monitor = Process.monitor(child)
    daemon_incarnation = components.daemon_incarnation

    assert {:ok,
            [
              {:settling_acquire, ^origin, :connection_lost, ^owner, ^daemon_incarnation,
               start_op_ref, _loss_ref}
            ]} = freeze(owner)

    assert is_reference(start_op_ref)
    assert_receive {:DOWN, ^child_monitor, :process, ^child, :killed}, 500

    send(
      owner,
      {:lease_grant_proposed, make_ref(), origin, child, child_incarnation, "held-child-session",
       holder.pid, holder.incarnation, :crypto.strong_rand_bytes(16), now_ms() + 30_000}
    )

    # Concept (T7, R7): a notice for an operation the freeze tombstoned is
    # cleanup-only.
    send(owner, {:lease_permit_settled, origin, child, child_incarnation, :result})

    assert %{
             pending_dispositions: 0,
             lease_operations: 0,
             mirror_operations: 0,
             owner_slots: 0
           } = Owner.status(owner)

    assert Process.alive?(owner)
    assert %{permits: 0} = AdmissionRelay.status(components.relay)
  end

  # Concept (P3 at the stop): a holder close the connection never
  # acknowledges is bound, at the cut, to the transport-cut instant; there the
  # holder is killed, its exit completes the close, and the freeze settles
  # with no daemon failure.
  #
  # Technical depth: a held owner is killed while serving, its classification
  # completes and the one close reaches the holder, which never answers; the
  # cut is given a 300 ms deadline.
  test "a holder close unacknowledged at the cut instant is killed and the freeze settles" do
    owner = start_owner(mirror_deadline_ms: 1_000, fatal_recipient: self())
    components = Owner.components(owner)
    holder = initialized_connection(components)
    holder_pid = holder.pid
    {lease_owner, _owner_incarnation, _epoch} = acquire_held(owner, holder, "unclosed-session")
    Process.exit(lease_owner, :kill)

    assert_receive {:manual_connection_message, ^holder_pid,
                    {:daemon_control_owner_lost, ^owner, _close_ref, "unclosed-session",
                     _holder_incarnation}},
                   500

    holder_monitor = Process.monitor(holder_pid)
    cut_started = now_ms()
    assert {:ok, _cut_ref} = Owner.cut_admission(owner, 300)
    assert_receive {:DOWN, ^holder_monitor, :process, ^holder_pid, :killed}, 1_000
    assert now_ms() - cut_started >= 250
    assert {:ok, _descriptors} = freeze(owner)
    refute_received {:daemon_component_fatal, _reporter, _class}
    assert Process.alive?(components.registry)
  end

  # Concept: a client disconnect never fail-stops the daemon, even when the
  # connection's loss reaches the relay between an existing owner's claim and
  # its renewal result: the relay's connection-loss disposition finds the
  # kept operation and settles it.
  #
  # Technical depth: the relay is parked on the renewal's claim while the
  # holder connection is killed, so the loss is ordered after the claim and
  # before the owner's completion, which is refused `connection_lost`.
  test "a disconnect between a renewal's claim and result settles without a fail-stop" do
    assert_disconnected_renewal_settles(:claim_lease_permit)
  end

  # Concept: the same holds when the loss reaches the relay between the
  # daemon owner's permit open and the lease owner's claim: the claim is
  # refused `connection_lost` and the kept operation is settled.
  #
  # Technical depth: the relay is parked on the permit open while the holder
  # connection is killed.
  test "a disconnect between a renewal's open and claim settles without a fail-stop" do
    assert_disconnected_renewal_settles(:open_lease_permit)
  end

  # Concept: a lease owner whose release acknowledgement is still missing at
  # `release_settlement_deadline`, after the relay rendered the one success
  # and the registry cleared the mirror, is the late party: that exact owner
  # is killed and superseded, and the registry and daemon keep serving.
  #
  # Technical depth: the relay is parked on the result settlement while the
  # lease owner is suspended, then released; the success reaches the holder,
  # the 400 ms settlement instant kills the owner, and the lost-owner path
  # leaves nothing behind.
  test "a release acknowledgement missing at the settlement deadline kills the owner" do
    owner = start_owner(mirror_deadline_ms: 200)
    components = Owner.components(owner)
    holder = initialized_connection(components)
    holder_pid = holder.pid
    session_id = "late-release-ack-session"
    {lease_owner, owner_incarnation, writer_epoch} = acquire_held(owner, holder, session_id)
    release_origin = {holder.incarnation, 1, 1}
    {release_worker, release_worker_incarnation} = start_worker(holder.pid, release_origin)
    park_relay_operation(components.relay, :settle_result)

    assert {:ok, :accepted, ^lease_owner, ^owner_incarnation} =
             release_as(
               owner,
               release_origin,
               "late-release-ack",
               session_id,
               holder.pid,
               holder.incarnation,
               release_worker,
               release_worker_incarnation,
               writer_epoch,
               now_ms() + 5_000
             )

    assert_receive {:relay_operation_parked, :settle_result}, 500
    :sys.suspend(lease_owner)
    lease_owner_monitor = Process.monitor(lease_owner)
    send(components.relay, :continue_parked_operation)

    assert_receive {:manual_connection_message, ^holder_pid,
                    {:relay_permit_result, ^release_origin, release_result}},
                   500

    assert release_result == WireRecords.control_released("late-release-ack")
    assert_receive {:DOWN, ^lease_owner_monitor, :process, ^lease_owner, :killed}, 1_000
    assert Process.alive?(owner)
    assert Process.alive?(components.registry)
    assert_clean_retirement(owner, components)
  end

  defp acquire_held(owner, connection, session_id) do
    origin = {connection.incarnation, 0, 1}
    {worker, worker_incarnation} = start_worker(connection.pid, origin)

    assert {:ok, :accepted, lease_owner, owner_incarnation} =
             acquire_as(
               owner,
               origin,
               "#{session_id}-acquire",
               session_id,
               connection.pid,
               connection.incarnation,
               worker,
               worker_incarnation,
               now_ms() + 2_000
             )

    assert_receive {:worker_go, ^worker, ^origin}, 500

    assert_receive {:manual_connection_message, _connection,
                    {:relay_permit_result, ^origin, result}},
                   500

    assert %{granted_routes: 1} = wait_for_owner_settlement(owner)
    epoch = Base.url_decode64!(result["result"]["writer_epoch"], padding: false)
    {lease_owner, owner_incarnation, epoch}
  end

  # Concept: a holder-changing grant under an existing lease owner. Technical
  # depth: the former holder's lease expires while the registry is suspended,
  # the successor queues behind that expiry, and the owner's successor grant
  # is left waiting at provisional install behind the suspended registry.
  defp park_existing_owner_grant(owner, components, former, successor, session_id) do
    former_origin = {former.incarnation, 0, 1}
    {former_worker, former_worker_incarnation} = start_worker(former.pid, former_origin)

    assert {:ok, :accepted, lease_owner, owner_incarnation} =
             acquire_as(
               owner,
               former_origin,
               "#{session_id}-former",
               session_id,
               former.pid,
               former.incarnation,
               former_worker,
               former_worker_incarnation,
               now_ms() + 2_000
             )

    assert_receive {:worker_go, ^former_worker, ^former_origin}, 500

    assert_receive {:manual_connection_message, _former,
                    {:relay_permit_result, ^former_origin, _former_result}},
                   500

    :sys.suspend(components.registry)
    assert :ok = wait_for_mirror_step(owner, :expiry, :clear)
    successor_origin = {successor.incarnation, 0, 1}

    {successor_worker, successor_worker_incarnation} =
      start_worker(successor.pid, successor_origin)

    assert {:ok, :accepted, ^lease_owner, ^owner_incarnation} =
             acquire_as(
               owner,
               successor_origin,
               "#{session_id}-successor",
               session_id,
               successor.pid,
               successor.incarnation,
               successor_worker,
               successor_worker_incarnation,
               now_ms() + 2_000
             )

    assert_receive {:worker_go, ^successor_worker, ^successor_origin}, 500
    :sys.suspend(lease_owner)
    :sys.resume(components.registry)
    assert :ok = wait_for_mirror_step(owner, :expiry, :resolve_owner_expiry)
    :sys.suspend(components.registry)
    :sys.resume(lease_owner)
    assert :ok = wait_for_mirror_step(owner, :grant, :install)
    {lease_owner, successor_origin}
  end

  # Concept: the relay can be held just before it applies one daemon-owner
  # lease operation. Technical depth: a debug hook parks the relay on the
  # first matching request, tells the test, and returns once released.
  defp park_relay_operation(relay, action) do
    test_pid = self()

    :ok =
      :sys.install(
        relay,
        {fn
           :waiting, {:in, {:relay_lease_operation, _ref, _owner, _incarnation, ^action, _}}, _ ->
             send(test_pid, {:relay_operation_parked, action})

             receive do
               :continue_parked_operation -> :done
             end

           :waiting, _event, _proc_state ->
             :waiting
         end, :waiting}
      )
  end

  defp close_owner_loss_holder(owner, connection, close_ref) do
    connection_pid = connection.pid
    monitor = Process.monitor(connection_pid)

    assert :ok =
             manual_call(
               connection_pid,
               {:owner_loss_closed, owner, close_ref, connection.incarnation}
             )

    assert_receive {:DOWN, ^monitor, :process, ^connection_pid, :normal}, 500
  end

  defp assert_clean_retirement(owner, components) do
    status =
      assert %{
               owner_slots: 0,
               lost_owners: 0,
               granted_routes: 0,
               lease_operations: 0,
               mirror_operations: 0,
               pending_dispositions: 0
             } = wait_for_owner_retirement(owner)

    assert Process.alive?(owner)
    assert %{routing_mirrors: 0} = ConnectionRegistry.status(components.registry)

    assert %{permits: 0, settling: 0, owner_losses: 0, lease_owners: 0} =
             AdmissionRelay.status(components.relay)

    status
  end

  # Concept: the collaboration owner decides the transport cut at its one
  # deadline and names the component that missed it.
  #
  # Technical depth: each case suspends the component under test, so only the
  # owner's own deadline can end the wait. Elapsed times are bounded below by
  # the deadline and above by well under the caller's verdict margin.
  # Concept: a relay that missed the cut is killed at the decision instant, so
  # a suspended relay can never resume and admit or dispatch work queued
  # before the cut.
  test "a relay silent past the cut deadline answers relay_lost and is killed at that instant" do
    owner = start_owner(fatal_recipient: self())
    components = Owner.components(owner)
    relay_monitor = Process.monitor(components.relay)
    owner_monitor = Process.monitor(owner)
    :ok = :sys.suspend(components.relay)

    started = now_ms()
    assert {:error, :relay_lost} = Owner.cut_admission(owner, 300)
    elapsed = now_ms() - started
    assert elapsed >= 290
    assert elapsed < 900

    assert_receive {:DOWN, ^relay_monitor, :process, _relay, :killed}, 100

    # The owner and its registry stay up so the registry can still write the
    # daemon's `fatal:relay_lost` stop records.
    refute_receive {:DOWN, ^owner_monitor, :process, ^owner, _reason}, 200
    assert Process.alive?(components.registry)

    # The caller already holds the class; the kill is not reported again.
    refute_received {:daemon_component_fatal, ^owner, _class}
  end

  # Concept: the collaboration owner never blocks on the registry during the
  # cut, so a relay lost while the registry is silent is consumed at once and
  # its class stands, instead of the registry deadline naming
  # `connections_lost`.
  test "a relay lost while the registry gate is held is reported relay_lost at once" do
    owner = start_owner(fatal_recipient: self())
    components = Owner.components(owner)
    :ok = :sys.suspend(components.registry)

    on_exit(fn -> Process.exit(components.registry, :kill) end)
    cut = Task.async(fn -> Owner.cut_admission(owner, 3_000) end)
    assert :ok = wait_for_stop(owner)
    assert :ok = await_owner_phase(owner, :gating)

    started = now_ms()
    Process.exit(components.relay, :kill)
    assert_receive {:daemon_component_fatal, ^owner, :relay_lost}, 1_000
    assert {:error, :relay_lost} = Task.await(cut, 1_000)
    assert now_ms() - started < 1_000

    # The owner, and the registry it links, outlive the relay for the daemon's
    # stop records.
    assert Process.alive?(owner)
    assert Process.alive?(components.registry)
  end

  test "a registry gate silent past the cut deadline answers connections_lost and stops the owner" do
    owner = start_owner()
    components = Owner.components(owner)
    owner_monitor = Process.monitor(owner)
    registry_monitor = Process.monitor(components.registry)
    :ok = :sys.suspend(components.registry)

    started = now_ms()
    assert {:error, :connections_lost} = Owner.cut_admission(owner, 300)
    elapsed = now_ms() - started
    assert elapsed >= 290
    assert elapsed < 900

    assert_receive {:DOWN, ^registry_monitor, :process, _registry, :killed}, 1_000
    assert_receive {:DOWN, ^owner_monitor, :process, ^owner, :connections_lost}, 1_000
  end

  test "an uninitialized peer the sweep cannot close answers connections_lost at the cut deadline" do
    owner = start_owner()
    components = Owner.components(owner)
    peer = uninitialized_connection(components)
    owner_monitor = Process.monitor(owner)

    deadline = now_ms() + 600
    assert {:ok, cut_ref} = Owner.cut_admission(owner, deadline - now_ms())
    # The manual connection is a plain process, so the VM suspends it.
    true = :erlang.suspend_process(peer)

    assert {:error, :connections_lost} = Owner.reap_uninitialized(owner, cut_ref, deadline)
    assert now_ms() >= deadline - 10
    assert now_ms() < deadline + 600
    assert_receive {:DOWN, ^owner_monitor, :process, ^owner, :connections_lost}, 1_000
  end

  test "an empty uninitialized sweep answers at once inside the cut deadline" do
    owner = start_owner()
    components = Owner.components(owner)
    _initialized = initialized_connection(components)

    deadline = now_ms() + 2_000
    assert {:ok, cut_ref} = Owner.cut_admission(owner, deadline - now_ms())
    assert :ok = Owner.reap_uninitialized(owner, cut_ref, deadline)
    assert now_ms() < deadline
  end

  defp start_owner(options \\ []) do
    options =
      Keyword.merge(
        [admission_wait_ms: 1_000, connection_module: ManualConnection],
        options
      )

    start_supervised!({Owner, options}, restart: :temporary)
  end

  # Concept: the registry never waits on the relay inside a call, so its exit
  # is its own loss whatever its reason.
  test "a registry exit is connections_lost whatever its reason" do
    owner = start_owner(fatal_recipient: self())
    state = :sys.get_state(owner)
    timeout = {:timeout, {GenServer, :call, [state.relay, :x, 5_000]}}

    assert {:stop, :connections_lost, _state} =
             Owner.handle_info({:EXIT, state.registry, timeout}, state)

    assert_received {:daemon_component_fatal, _reporter, :connections_lost}

    assert {:stop, :connections_lost, _state} =
             Owner.handle_info({:EXIT, state.registry, :killed}, state)
  end

  # Concept (T13): a relay that leaves a registry request unanswered for five
  # seconds while serving is named `relay_lost` exactly once, and the registry
  # that reported it keeps serving.
  #
  # Technical depth: the relay is suspended and a registry promotion is sent
  # from a separate caller. At the request's instant the registry reports to
  # the owner, which reports `relay_lost` to its fatal recipient, marks fatal
  # teardown and kills the relay. The registry's request then ends on the
  # relay's exit without ending the registry, and a repeated report latches
  # nothing further.
  @tag timeout: 30_000
  test "an unanswered registry relay request latches relay_lost once while serving" do
    owner = start_owner(fatal_recipient: self())
    components = Owner.components(owner)
    relay_monitor = Process.monitor(components.relay)
    :ok = :sys.suspend(components.relay)

    started = now_ms()
    spawn_registry_promotion(components.registry, {:crypto.strong_rand_bytes(16), 0, 1})

    assert_receive {:daemon_component_fatal, ^owner, :relay_lost}, 7_000
    assert now_ms() - started >= 4_900
    assert_receive {:DOWN, ^relay_monitor, :process, _relay, :killed}, 1_000

    send(
      owner,
      {:registry_relay_unanswered, components.registry, components.routing_incarnation}
    )

    refute_receive {:daemon_component_fatal, _reporter, _class}, 300
    assert Process.alive?(owner)
    assert Process.alive?(components.registry)
    assert %{relay_flow: nil} = :sys.get_state(components.registry)
  end

  # Concept (T21, partial: the daemon owner's side only; the full witness
  # needs the later lease-owner step): once the stop has begun, the stop's own
  # deadlines govern, so the daemon owner treats a registry's unanswered-relay
  # report as cleanup and the relay keeps serving.
  test "an unanswered registry relay report after the cut is cleanup-only" do
    owner = start_owner(fatal_recipient: self())
    components = Owner.components(owner)
    assert {:ok, _cut_ref} = Owner.cut_admission(owner, 2_000)

    send(
      owner,
      {:registry_relay_unanswered, components.registry, components.routing_incarnation}
    )

    refute_receive {:daemon_component_fatal, _reporter, _class}, 300
    assert Process.alive?(components.relay)
    assert %{fatal_teardown: false} = :sys.get_state(owner)
  end

  # Concept (T23): after the admission deadline the relay refuses the
  # registry's queued promotions with `daemon_stopping`, each caller hears it
  # and its reservation is released, and the final close never waits behind
  # those flows.
  #
  # Technical depth: after the cut, a debug hook parks the relay on the first
  # promotion while a second waits in the registry's flow queue. The final
  # close answers while the relay is still parked. Released past the
  # admission deadline, the relay answers both promotions `daemon_stopping`.
  test "queued registry flows end daemon_stopping past the admission deadline" do
    owner = start_owner(admission_wait_ms: 200)
    components = Owner.components(owner)
    _connection = initialized_connection(components)
    assert {:ok, _cut_ref} = Owner.cut_admission(owner, 2_000)

    park_relay_message(
      components.relay,
      &match?({:"$gen_call", _from, {:promote_ticket, _, _, _, _}}, &1),
      :relay_promotion_parked,
      :continue_parked_promotion
    )

    first = spawn_registry_promotion(components.registry, {incarnation(), 0, 1}, :fresh)
    assert_receive :relay_promotion_parked, 1_000
    second = spawn_registry_promotion(components.registry, {incarnation(), 1, 1}, :fresh)

    eventually_true(fn -> registry_flow_state(components.registry).queued == 1 end)

    assert %{relay_flow: %{}, queued: 1, activation_reservations: 1} =
             registry_flow_state(components.registry)

    record = WireRecords.daemon_stopping("operator_stop")
    assert {:ok, :forced} = Owner.close_connections(owner, record, now_ms() + 200)

    Process.sleep(300)
    send(components.relay, :continue_parked_promotion)

    assert_receive {:registry_promotion, ^first, {:error, :daemon_stopping}}, 1_000
    assert_receive {:registry_promotion, ^second, {:error, :daemon_stopping}}, 1_000

    assert %{relay_flow: nil, activation_reservations: 0} =
             registry_flow_state(components.registry)
  end

  # Concept: an unanswered-relay report names the current registry and
  # routing incarnation; any other report latches nothing.
  test "a registry relay report naming another registry or incarnation is cleanup-only" do
    owner = start_owner(fatal_recipient: self())
    components = Owner.components(owner)

    send(owner, {:registry_relay_unanswered, self(), components.routing_incarnation})
    send(owner, {:registry_relay_unanswered, components.registry, incarnation()})

    refute_receive {:daemon_component_fatal, _reporter, _class}, 300
    assert Process.alive?(components.relay)
    assert %{fatal_teardown: false} = :sys.get_state(owner)
  end

  # Concept (E9): a connection's report of an unanswered relay request while
  # serving names the relay lost once: the fatal recipient hears
  # `relay_lost` and the relay is killed.
  test "a connection relay report while serving latches relay_lost" do
    owner = start_owner(fatal_recipient: self())
    components = Owner.components(owner)
    relay_monitor = Process.monitor(components.relay)

    send(owner, {:connection_relay_unanswered, self(), incarnation()})

    assert_receive {:daemon_component_fatal, ^owner, :relay_lost}, 500
    assert_receive {:DOWN, ^relay_monitor, :process, _relay, :killed}, 1_000
    send(owner, {:connection_relay_unanswered, self(), incarnation()})
    refute_receive {:daemon_component_fatal, _reporter, _class}, 200
  end

  # Concept (E9): once the stop has begun, a connection's relay report is
  # cleanup-only; the stop's own deadlines govern.
  test "a connection relay report after the cut is cleanup-only" do
    owner = start_owner(fatal_recipient: self())
    components = Owner.components(owner)
    assert {:ok, _cut_ref} = Owner.cut_admission(owner, 2_000)

    send(owner, {:connection_relay_unanswered, self(), incarnation()})

    refute_receive {:daemon_component_fatal, _reporter, _class}, 300
    assert Process.alive?(components.relay)
    assert %{fatal_teardown: false} = :sys.get_state(owner)
  end

  # Concept (E8): a second final close while one is in flight joins it: the
  # registry is asked once and both callers hear its one answer.
  test "a repeated final close joins the close in flight" do
    owner = start_owner()
    components = Owner.components(owner)
    _connection = initialized_connection(components)
    1 = :erlang.trace(components.registry, true, [:receive])

    record = WireRecords.daemon_stopping("operator_stop")
    deadline = now_ms() + 300

    closes =
      for _ <- 1..2, do: Task.async(fn -> Owner.close_connections(owner, record, deadline) end)

    assert [{:ok, :forced}, {:ok, :forced}] = Enum.map(closes, &Task.await(&1, 3_000))
    :erlang.trace(components.registry, false, [:receive])

    requests =
      Stream.repeatedly(fn ->
        receive do
          {:trace, _registry, :receive, {:owner_request, ^owner, _ref, {:close_all, _, _}}} ->
            :close_all

          {:trace, _registry, :receive, _other} ->
            :other
        after
          0 -> :done
        end
      end)
      |> Enum.take_while(&(&1 != :done))
      |> Enum.count(&(&1 == :close_all))

    assert requests == 1
  end

  # Concept (E8): a close the registry misses is answered `connections_lost`
  # once at its deadline; the registry's reply arriving later is ignored.
  test "a late close reply after the close deadline is ignored" do
    {state, tag, ref} = pending_close_state()
    state = %{state | registry: spawn(fn -> Process.sleep(:infinity) end)}

    assert {:noreply, state} = Owner.handle_info({:close_connections_deadline, ref}, state)
    assert_received {^tag, {:error, :connections_lost}}

    assert {:noreply, _state} =
             Owner.handle_info({:owner_reply, state.registry, ref, :ok}, state)

    refute_received {^tag, _reply}
  end

  # Concept (E8): a registry that exits while the final close waits answers
  # that close `connections_lost`, the same class the owner stops with.
  test "a registry exit answers a pending close connections_lost" do
    {state, tag, _ref} = pending_close_state()

    assert {:stop, :connections_lost, _state} =
             Owner.handle_info({:EXIT, state.registry, :killed}, state)

    assert_received {^tag, {:error, :connections_lost}}
  end

  # Concept (F1): when the relay acknowledges its teardown, the daemon owner
  # tells the registry, which abandons every remaining relay flow.
  test "the relay's teardown barrier abandons the registry's relay flows" do
    owner = start_owner()
    components = Owner.components(owner)
    deadline = now_ms() + 2_000
    assert {:ok, cut_ref} = Owner.cut_admission(owner, 1_000)
    assert :ok = Owner.reap_uninitialized(owner, cut_ref, now_ms() + 1_000)
    assert {:ok, _descriptors} = freeze(owner)
    assert {:ok, _drain} = Owner.barrier(owner, {:quiescing, "drain"}, deadline)

    assert {:ok, _sealed} =
             Owner.barrier(owner, {:seal_after_quiesce, "drain", deadline}, deadline)

    assert %{relay_flows_abandoned: false} = :sys.get_state(components.registry)

    assert {:ok, _owners} = Owner.barrier(owner, :tearing_down, deadline)
    assert %{relay_flows_abandoned: true} = :sys.get_state(components.registry)

    caller = spawn_registry_promotion(components.registry, {incarnation(), 0, 1})
    assert_receive {:registry_promotion, ^caller, {:error, :relay_unavailable}}, 500
  end

  # An owner state with one final close pending, answered to the test under
  # `tag`.
  # Concept (T1): the daemon owner never waits on a lease owner, so a
  # suspended lease owner leaves the owner answering its connections.
  #
  # Technical depth: the holder's renewal is accepted when the relay opens
  # its permit, and a status request answers promptly, while the lease owner
  # stays suspended; the renewal completes once it resumes.
  test "the owner stays responsive while a lease owner is suspended" do
    owner = start_owner()
    components = Owner.components(owner)
    holder = initialized_connection(components)
    session_id = "responsive-session"
    {lease_owner, owner_incarnation, _epoch} = acquire_held(owner, holder, session_id)
    :sys.suspend(lease_owner)
    origin = {holder.incarnation, 1, 1}
    {worker, worker_incarnation} = start_worker(holder.pid, origin)

    renewal =
      Task.async(fn ->
        acquire_as(
          owner,
          origin,
          "responsive-renewal",
          session_id,
          holder.pid,
          holder.incarnation,
          worker,
          worker_incarnation,
          now_ms() + 2_000
        )
      end)

    assert {:ok, :accepted, ^lease_owner, ^owner_incarnation} = Task.await(renewal, 500)
    assert %{live_owners: 1} = Task.await(Task.async(fn -> Owner.status(owner) end), 500)
    :sys.resume(lease_owner)

    assert_receive {:manual_connection_message, _holder,
                    {:relay_permit_result, ^origin, %{"result" => %{"renewed" => true}}}},
                   500
  end

  # Concept (T2): a relay that leaves the owner's open unanswered for five
  # seconds while serving is named `relay_lost` exactly once; the owner
  # answers meanwhile, and the waiting connection gets its one answer.
  @tag timeout: 30_000
  test "an open unanswered for five seconds latches relay_lost once" do
    owner = start_owner(fatal_recipient: self())
    components = Owner.components(owner)
    holder = initialized_connection(components)
    session_id = "unanswered-open"
    {_lease_owner, _owner_incarnation, _epoch} = acquire_held(owner, holder, session_id)
    origin = {holder.incarnation, 1, 1}
    {worker, worker_incarnation} = start_worker(holder.pid, origin)
    relay_monitor = Process.monitor(components.relay)

    park_relay_message(
      components.relay,
      &match?({:"$gen_call", _from, {:open_lease_permit, _, ^origin, _, _, _, _, _, _, _}}, &1),
      :open_parked,
      :continue_open
    )

    started = now_ms()

    renewal =
      Task.async(fn ->
        long_acquire(
          owner,
          origin,
          "unanswered-open",
          session_id,
          holder,
          {worker, worker_incarnation}
        )
      end)

    assert_receive :open_parked, 500
    assert %{live_owners: 1} = Task.await(Task.async(fn -> Owner.status(owner) end), 500)
    assert_receive {:daemon_component_fatal, ^owner, :relay_lost}, 6_000
    assert now_ms() - started >= 4_900
    assert_receive {:DOWN, ^relay_monitor, :process, _relay, :killed}, 1_000
    assert {:error, :daemon_stopping} = Task.await(renewal, 1_000)
    refute_receive {:daemon_component_fatal, _reporter, _class}, 300
  end

  # Concept (D1, T4): a queued acquire the lease owner later settles
  # directly — here refused at its request deadline — is removed from the
  # owner's operations by its notice while its lease owner is still live, so
  # nothing waits on it.
  #
  # Technical depth: the observer queues behind the holder's release, held at
  # the suspended registry's mirror clear. Its short request deadline passes
  # either while it waits or before it is claimed; both are the lease owner's
  # direct `control_pending`, so the outcome does not depend on timing. After
  # the registry resumes, the released lease owner retires and its slot frees.
  test "a queued acquire settled directly leaves no operation" do
    owner = start_owner()
    components = Owner.components(owner)
    holder = initialized_connection(components)
    observer = initialized_connection(components)
    session_id = "direct-session"
    {lease_owner, owner_incarnation, epoch} = acquire_held(owner, holder, session_id)
    :sys.suspend(components.registry)
    release_origin = {holder.incarnation, 1, 1}
    {release_worker, release_worker_incarnation} = start_worker(holder.pid, release_origin)

    assert {:ok, :accepted, ^lease_owner, ^owner_incarnation} =
             release_as(
               owner,
               release_origin,
               "direct-release",
               session_id,
               holder.pid,
               holder.incarnation,
               release_worker,
               release_worker_incarnation,
               epoch,
               now_ms() + 5_000
             )

    assert :ok = wait_for_mirror_step(owner, :release, :clear)
    origin = {observer.incarnation, 0, 1}
    {worker, worker_incarnation} = start_worker(observer.pid, origin)

    assert {:ok, :accepted, ^lease_owner, ^owner_incarnation} =
             acquire_as(
               owner,
               origin,
               "direct-acquire",
               session_id,
               observer.pid,
               observer.incarnation,
               worker,
               worker_incarnation,
               now_ms() + 100
             )

    observer_pid = observer.pid

    assert_receive {:manual_connection_message, ^observer_pid,
                    {:relay_permit_result, ^origin, %{"code" => "control_pending"}}},
                   2_000

    assert :ok =
             wait_for_status(owner, fn _status ->
               not Map.has_key?(:sys.get_state(owner).operations, origin)
             end)

    assert Process.alive?(lease_owner)
    :sys.resume(components.registry)
    assert %{owner_slots: 0, lease_operations: 0} = wait_for_owner_retirement(owner)
  end

  # Concept (T5, R5, notice first): a `connection_lost` notice that arrives
  # before the relay's disposition marks the operation superseded, and the
  # disposition then settles it once, without the lease owner.
  #
  # Technical depth: the lease owner is suspended, so the notice is forged;
  # the settlement completes while it stays suspended. Its later claim finds
  # no permit and its notice is cleanup-only.
  test "a connection_lost notice before the disposition settles once" do
    assert_connection_lost_notice(:notice_first)
  end

  # Concept (T5, R5, disposition first): the notice then settles the
  # retained disposition itself, and the lease owner's later discard answer
  # finds nothing.
  test "a connection_lost notice after the disposition settles once" do
    assert_connection_lost_notice(:disposition_first)
  end

  # Concept (D3, T6): a lease owner that dies after the relay recorded its
  # result, but before it saw the answer, strands no operation: once its
  # exit and the relay's loss report are both seen, its unmirrored
  # operations outside the relay's claim are deleted and the loss finishes.
  #
  # Technical depth: a relay debug hook suspends the lease owner when its
  # renewal completion arrives and kills it once the relay has answered.
  test "a lease owner killed after its recorded result strands no operation" do
    owner = start_owner()
    components = Owner.components(owner)
    holder = initialized_connection(components)
    session_id = "recorded-result"
    {lease_owner, owner_incarnation, _epoch} = acquire_held(owner, holder, session_id)
    test_pid = self()

    :ok =
      :sys.install(
        components.relay,
        {fn
           :waiting, {:in, {:"$gen_call", {^lease_owner, _tag}, request}}, _proc_state
           when elem(request, 0) == :complete_lease_permit ->
             :sys.suspend(lease_owner)
             :recorded

           :recorded, {:out, _reply, {^lease_owner, _tag}, _state}, _proc_state ->
             Process.exit(lease_owner, :kill)
             send(test_pid, :lease_owner_killed)
             :done

           hook_state, _event, _proc_state ->
             hook_state
         end, :waiting}
      )

    origin = {holder.incarnation, 1, 1}
    {worker, worker_incarnation} = start_worker(holder.pid, origin)

    assert {:ok, :accepted, ^lease_owner, ^owner_incarnation} =
             acquire_as(
               owner,
               origin,
               "recorded-renewal",
               session_id,
               holder.pid,
               holder.incarnation,
               worker,
               worker_incarnation,
               now_ms() + 2_000
             )

    assert_receive :lease_owner_killed, 500

    assert_receive {:manual_connection_message, _holder,
                    {:relay_permit_result, ^origin, %{"result" => %{"renewed" => true}}}},
                   500

    holder_pid = holder.pid

    assert_receive {:manual_connection_message, ^holder_pid,
                    {:daemon_control_owner_lost, ^owner, close_ref, ^session_id, _incarnation}},
                   1_000

    close_owner_loss_holder(owner, holder, close_ref)
    assert %{owner_slots: 0, lease_operations: 0} = wait_for_owner_retirement(owner)
  end

  # Concept (T8): a request whose deadline passed before it reached its
  # lease owner is still claimed and answered by the relay, `control_pending`.
  #
  # Technical depth: the relay is parked on the observer's open past the
  # request's 100 ms deadline.
  test "a request expired before it reaches the lease owner gets control_pending" do
    owner = start_owner()
    components = Owner.components(owner)
    holder = initialized_connection(components)
    observer = initialized_connection(components)
    session_id = "expired-in-transit"
    {lease_owner, owner_incarnation, _epoch} = acquire_held(owner, holder, session_id)
    origin = {observer.incarnation, 0, 1}
    {worker, worker_incarnation} = start_worker(observer.pid, origin)

    park_relay_message(
      components.relay,
      &match?({:"$gen_call", _from, {:open_lease_permit, _, ^origin, _, _, _, _, _, _, _}}, &1),
      :open_parked,
      :continue_open
    )

    acquire =
      Task.async(fn ->
        acquire_as(
          owner,
          origin,
          "expired-in-transit",
          session_id,
          observer.pid,
          observer.incarnation,
          worker,
          worker_incarnation,
          now_ms() + 100
        )
      end)

    assert_receive :open_parked, 500
    Process.sleep(200)
    send(components.relay, :continue_open)
    assert {:ok, :accepted, ^lease_owner, ^owner_incarnation} = Task.await(acquire, 500)
    observer_pid = observer.pid

    assert_receive {:manual_connection_message, ^observer_pid,
                    {:relay_permit_result, ^origin, %{"code" => "control_pending"}}},
                   500
  end

  # Concept (T18, F4): a request for a session whose lease owner is still
  # registering waits and is dispatched after that owner's first acquire, so
  # it is decided against the first acquire's grant.
  #
  # Technical depth: the relay is parked on the registration; the second
  # acquire arrives meanwhile and is held in the row's `pending_dispatch`.
  test "an acquire during registration is dispatched after the first acquire" do
    owner = start_owner()
    components = Owner.components(owner)
    first = initialized_connection(components)
    second = initialized_connection(components)
    session_id = "registering-session"

    park_relay_message(
      components.relay,
      &match?({:"$gen_call", _from, {:register_lease_owner, ^session_id, _, _}}, &1),
      :register_parked,
      :continue_register
    )

    first_origin = {first.incarnation, 0, 1}
    {first_worker, first_worker_incarnation} = start_worker(first.pid, first_origin)

    assert {:ok, :accepted, lease_owner, owner_incarnation} =
             acquire_as(
               owner,
               first_origin,
               "registering-first",
               session_id,
               first.pid,
               first.incarnation,
               first_worker,
               first_worker_incarnation,
               now_ms() + 2_000
             )

    assert_receive :register_parked, 500
    second_origin = {second.incarnation, 0, 1}
    {second_worker, second_worker_incarnation} = start_worker(second.pid, second_origin)

    queued =
      Task.async(fn ->
        acquire_as(
          owner,
          second_origin,
          "registering-second",
          session_id,
          second.pid,
          second.incarnation,
          second_worker,
          second_worker_incarnation,
          now_ms() + 2_000
        )
      end)

    assert :ok =
             wait_for_status(owner, fn _status ->
               match?(
                 %{owners: %{^session_id => %{phase: :registering, pending_dispatch: [_]}}},
                 :sys.get_state(owner)
               )
             end)

    send(components.relay, :continue_register)
    assert {:ok, :accepted, ^lease_owner, ^owner_incarnation} = Task.await(queued, 1_000)

    assert_receive {:manual_connection_message, _first,
                    {:relay_permit_result, ^first_origin, %{"result" => %{"writer_epoch" => _}}}},
                   1_000

    second_pid = second.pid

    assert_receive {:manual_connection_message, ^second_pid,
                    {:relay_permit_result, ^second_origin, %{"code" => "control_held"}}},
                   1_000
  end

  # Concept (T18, F4, error branch): a registration the relay refuses
  # discards the started child, frees its slot and refuses the first acquire
  # through the relay.
  #
  # Technical depth: the owner is suspended once the relay has admitted the
  # first acquire's claim; a conflicting lease-owner row is then written into
  # the relay's state, so the registration that follows is refused.
  test "a refused registration discards its child and refuses the first acquire" do
    owner = start_owner()
    components = Owner.components(owner)
    connection = initialized_connection(components)
    session_id = "refused-registration"
    origin = {connection.incarnation, 0, 1}
    {worker, worker_incarnation} = start_worker(connection.pid, origin)

    park_relay_message(
      components.relay,
      &match?({:"$gen_call", _from, {:claim_lease_permit, ^origin, _, _}}, &1),
      :claim_parked,
      :continue_claim
    )

    acquire =
      Task.async(fn ->
        acquire_as(
          owner,
          origin,
          "refused-registration",
          session_id,
          connection.pid,
          connection.incarnation,
          worker,
          worker_incarnation,
          now_ms() + 2_000
        )
      end)

    assert_receive :claim_parked, 500
    :sys.suspend(owner)
    send(components.relay, :continue_claim)
    assert_receive {:worker_go, ^worker, ^origin}, 500
    conflict = %{binding: {self(), incarnation()}, monitor: make_ref(), phase: :live}

    :sys.replace_state(components.relay, fn relay_state ->
      put_in(relay_state, [:lease_owners, session_id], conflict)
    end)

    :sys.resume(owner)
    assert {:ok, :accepted, child, _child_incarnation} = Task.await(acquire, 1_000)
    child_monitor = Process.monitor(child)
    assert_receive {:DOWN, ^child_monitor, :process, ^child, reason}, 500
    assert reason in [:killed, :noproc]

    assert_receive {:manual_connection_message, _connection,
                    {:relay_permit_result, ^origin, %{"code" => "control_pending"}}},
                   500

    assert :ok = wait_for_status(owner, &(&1.owner_slots == 0 and &1.lease_operations == 0))
  end

  # Concept (T20, F5): a lease owner that does not acknowledge an attachment
  # within its five-second step while serving is killed, and the attachment
  # completes at its exit.
  @tag timeout: 30_000
  test "a lease owner suspended past its attachment acknowledgement is killed" do
    owner = start_owner()
    components = Owner.components(owner)
    holder = initialized_connection(components)
    session_id = "attachment-bound"
    {lease_owner, _owner_incarnation, _epoch} = acquire_held(owner, holder, session_id)
    :sys.suspend(lease_owner)
    monitor = Process.monitor(lease_owner)
    started = now_ms()

    send(
      owner,
      {:registry_attachment, components.registry, make_ref(), :opened, session_id, holder.pid,
       holder.incarnation, "bounded-attachment"}
    )

    assert :ok =
             wait_for_status(owner, fn _status ->
               map_size(:sys.get_state(owner).attachment_acks) == 1
             end)

    assert_receive {:DOWN, ^monitor, :process, ^lease_owner, :killed}, 6_000
    assert now_ms() - started >= 4_900

    assert :ok =
             wait_for_status(owner, fn _status -> :sys.get_state(owner).attachment_acks == %{} end)
  end

  # Concept (T22, F8, D6): an acquire racing its lease owner's retirement is
  # held, not failed, and dispatched as a successor acquire when the
  # retirement intent arrives.
  #
  # Technical depth: a relay debug hook suspends the lease owner when its
  # retirement preparation arrives, so the relay marks it retiring while its
  # intent is not yet sent. The observer's open is refused `actor_retiring`
  # and held until the lease owner resumes.
  test "an acquire racing a retirement is held until the retirement intent" do
    {owner, observer, origin, acquire, lease_owner} = race_retirement("retiring-hold")
    assert nil == Task.yield(acquire, 200)
    :sys.resume(lease_owner)
    assert {:ok, :accepted, ^owner, _daemon_incarnation} = Task.await(acquire, 1_000)
    observer_pid = observer.pid

    assert_receive {:manual_connection_message, ^observer_pid,
                    {:relay_permit_result, ^origin, %{"result" => %{"writer_epoch" => _}}}},
                   2_000
  end

  # Concept (F8): a retiring lease owner that has not sent its intent within
  # the hold's five-second step is killed; the held acquire waits for that
  # owner's loss to finish and is then dispatched to a fresh owner.
  @tag timeout: 30_000
  test "a retiring hold past its step kills the lease owner and dispatches the acquire" do
    {_owner, observer, origin, acquire, lease_owner} = race_retirement("retiring-bound")
    monitor = Process.monitor(lease_owner)
    assert_receive {:DOWN, ^monitor, :process, ^lease_owner, :killed}, 6_000
    assert {:ok, :accepted, successor, _incarnation} = Task.await(acquire, 1_000)
    refute successor == lease_owner
    observer_pid = observer.pid

    assert_receive {:manual_connection_message, ^observer_pid,
                    {:relay_permit_result, ^origin, %{"result" => %{"writer_epoch" => _}}}},
                   2_000
  end

  # Concept (carried requirement 1, F8): requests refused `actor_lost` are
  # held until the owner-loss notification finishes: the returned holder's
  # then hears `holder_closed`, and another connection's acquire is
  # dispatched afresh.
  #
  # Technical depth: the owner is suspended with both requests queued ahead
  # of the lease owner's `EXIT`, and resumed once the relay has seen the
  # loss, so both opens name the lost owner.
  test "actor_lost requests wait for the loss notification to finish" do
    owner = start_owner()
    components = Owner.components(owner)
    holder = initialized_connection(components)
    observer = initialized_connection(components)
    session_id = "lost-hold"
    {lease_owner, _owner_incarnation, _epoch} = acquire_held(owner, holder, session_id)
    holder_origin = {holder.incarnation, 1, 1}
    observer_origin = {observer.incarnation, 0, 1}
    {holder_worker, holder_worker_incarnation} = start_worker(holder.pid, holder_origin)
    {observer_worker, observer_worker_incarnation} = start_worker(observer.pid, observer_origin)
    :sys.suspend(owner)

    renewal =
      Task.async(fn ->
        acquire_as(
          owner,
          holder_origin,
          "lost-hold-renewal",
          session_id,
          holder.pid,
          holder.incarnation,
          holder_worker,
          holder_worker_incarnation,
          now_ms() + 5_000
        )
      end)

    acquire =
      Task.async(fn ->
        acquire_as(
          owner,
          observer_origin,
          "lost-hold-acquire",
          session_id,
          observer.pid,
          observer.incarnation,
          observer_worker,
          observer_worker_incarnation,
          now_ms() + 5_000
        )
      end)

    assert :ok = wait_for_queue_length(owner, 2)
    Process.exit(lease_owner, :kill)
    assert %{owner_losses: 1} = wait_for_relay_owner_loss(components.relay)
    :sys.resume(owner)
    holder_pid = holder.pid

    assert_receive {:manual_connection_message, ^holder_pid,
                    {:daemon_control_owner_lost, ^owner, close_ref, ^session_id, _incarnation}},
                   1_000

    assert nil == Task.yield(renewal, 200)
    assert nil == Task.yield(acquire, 0)
    assert [_, _] = :sys.get_state(owner).owners[session_id].held
    close_owner_loss_holder(owner, holder, close_ref)
    # The holder's connection has closed, so its `holder_closed` answer
    # reaches no one; the held entry is gone.
    assert :ok =
             wait_for_status(owner, fn _status ->
               not match?(%{held: [_ | _]}, :sys.get_state(owner).owners[session_id])
             end)

    Task.shutdown(renewal, :brutal_kill)
    assert {:ok, :accepted, successor, _incarnation} = Task.await(acquire, 1_000)
    refute successor == lease_owner
    observer_pid = observer.pid

    assert_receive {:manual_connection_message, ^observer_pid,
                    {:relay_permit_result, ^observer_origin,
                     %{"result" => %{"writer_epoch" => _}}}},
                   1_000
  end

  # Concept (carried requirement 1, loss already finished): an `actor_lost`
  # answer that arrives after the loss finished is released at once — the
  # returned holder hears `holder_closed` and another connection's release
  # `control_not_held` — since no later step would release it.
  #
  # Technical depth: by same-relay order this answer precedes the
  # classification the loss waits for, so it is driven directly against the
  # owner's state after a finished loss.
  test "an actor_lost answer after the loss finished is released at once" do
    owner = start_owner()
    components = Owner.components(owner)
    holder = initialized_connection(components)
    session_id = "finished-loss"
    {lease_owner, owner_incarnation, epoch} = acquire_held(owner, holder, session_id)
    monitor = Process.monitor(lease_owner)
    Process.exit(lease_owner, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^lease_owner, :killed}, 500
    holder_pid = holder.pid

    assert_receive {:manual_connection_message, ^holder_pid,
                    {:daemon_control_owner_lost, ^owner, close_ref, ^session_id, _incarnation}},
                   1_000

    close_owner_loss_holder(owner, holder, close_ref)
    assert %{owner_slots: 0} = wait_for_owner_retirement(owner)
    state = :sys.get_state(owner)
    refute Map.has_key?(state.owners, session_id)

    holder_request = %{
      class: :session_acquire_control,
      session_id: session_id,
      permit_id: {holder.incarnation, 1, 1},
      connection: holder.pid,
      connection_incarnation: holder.incarnation
    }

    other_request = %{
      class: :session_release_control,
      session_id: session_id,
      permit_id: {incarnation(), 0, 1},
      connection: self(),
      connection_incarnation: incarnation(),
      writer_epoch: epoch
    }

    for {request, tag} <- [{holder_request, make_ref()}, {other_request, make_ref()}] do
      request_id = make_ref()

      operation = %{
        request: request,
        owner_pid: lease_owner,
        owner_incarnation: owner_incarnation,
        actor_pid: lease_owner,
        actor_incarnation: owner_incarnation,
        start_op_ref: nil,
        phase: :opening,
        reply_to: {self(), tag}
      }

      state =
        state
        |> put_in([:operations, request.permit_id], operation)
        |> put_in([:relay_requests, request_id], %{
          continuation: {:open, request.permit_id},
          timer: nil
        })

      assert {:noreply, released} =
               Owner.handle_info({[:alias | request_id], {:error, :actor_lost}}, state)

      refute Map.has_key?(released.operations, request.permit_id)
      expected = if request == holder_request, do: :holder_closed, else: :control_not_held
      assert_received {^tag, {:error, ^expected}}
    end
  end

  # Concept: a lease owner's report of an unanswered relay request latches
  # `relay_lost` once while serving and is cleanup-only after the cut.
  test "a lease owner's unanswered-relay report latches relay_lost once while serving" do
    owner = start_owner(fatal_recipient: self())
    components = Owner.components(owner)
    holder = initialized_connection(components)
    {lease_owner, owner_incarnation, _epoch} = acquire_held(owner, holder, "report-session")
    relay_monitor = Process.monitor(components.relay)
    send(owner, {:lease_owner_relay_unanswered, lease_owner, owner_incarnation})
    assert_receive {:daemon_component_fatal, ^owner, :relay_lost}, 500
    assert_receive {:DOWN, ^relay_monitor, :process, _relay, :killed}, 500
    send(owner, {:lease_owner_relay_unanswered, lease_owner, owner_incarnation})
    refute_receive {:daemon_component_fatal, _reporter, _class}, 200
  end

  test "a lease owner's unanswered-relay report after the cut is cleanup-only" do
    cut_owner = start_owner(fatal_recipient: self())
    cut_components = Owner.components(cut_owner)
    cut_holder = initialized_connection(cut_components)

    {cut_lease_owner, cut_incarnation, _epoch} =
      acquire_held(cut_owner, cut_holder, "report-after-cut")

    assert {:ok, _cut_ref} = Owner.cut_admission(cut_owner, 2_000)
    send(cut_owner, {:lease_owner_relay_unanswered, cut_lease_owner, cut_incarnation})
    refute_receive {:daemon_component_fatal, _reporter, _class}, 300
    assert Process.alive?(cut_components.relay)
  end

  defp assert_connection_lost_notice(order) do
    owner = start_owner(fatal_recipient: self())
    components = Owner.components(owner)
    holder = initialized_connection(components)
    observer = initialized_connection(components)
    session_id = "notice-#{order}"
    {lease_owner, owner_incarnation, _epoch} = acquire_held(owner, holder, session_id)
    :sys.suspend(lease_owner)
    origin = {observer.incarnation, 0, 1}
    {worker, worker_incarnation} = start_worker(observer.pid, origin)

    assert {:ok, :accepted, ^lease_owner, ^owner_incarnation} =
             acquire_as(
               owner,
               origin,
               "notice-acquire",
               session_id,
               observer.pid,
               observer.incarnation,
               worker,
               worker_incarnation,
               now_ms() + 5_000
             )

    notice = {:lease_permit_settled, origin, lease_owner, owner_incarnation, :connection_lost}

    if order == :notice_first do
      send(owner, notice)

      assert :ok =
               wait_for_status(owner, fn _status ->
                 :sys.get_state(owner).operations[origin].phase == :superseded
               end)
    end

    Process.exit(observer.pid, :kill)

    if order == :disposition_first do
      assert :ok = wait_for_pending_dispositions(owner, 1)
      send(owner, notice)
    end

    assert :ok =
             wait_for_status(
               owner,
               &(&1.lease_operations == 0 and &1.pending_dispositions == 0 and
                   &1.mirror_operations == 0)
             )

    :sys.resume(lease_owner)
    assert %{permits: 0} = wait_for_relay_permits(components.relay, 0)
    refute_receive {:daemon_component_fatal, _reporter, _class}, 200
    assert Process.alive?(owner)
    assert %{lease_operations: 0, pending_dispositions: 0} = Owner.status(owner)
  end

  # Technical depth: the holder releases, so its lease owner prepares its
  # retirement; a relay debug hook suspends the lease owner as that
  # preparation arrives. The observer's acquire then meets a retiring actor.
  defp race_retirement(session_id) do
    owner = start_owner()
    components = Owner.components(owner)
    holder = initialized_connection(components)
    observer = initialized_connection(components)
    {lease_owner, owner_incarnation, epoch} = acquire_held(owner, holder, session_id)
    test_pid = self()

    :ok =
      :sys.install(
        components.relay,
        {fn
           :waiting, {:in, {:"$gen_call", {^lease_owner, _tag}, request}}, _proc_state
           when elem(request, 0) == :prepare_lease_owner_retirement ->
             :sys.suspend(lease_owner)
             send(test_pid, :retirement_prepared)
             :done

           hook_state, _event, _proc_state ->
             hook_state
         end, :waiting}
      )

    release_origin = {holder.incarnation, 1, 1}
    {release_worker, release_worker_incarnation} = start_worker(holder.pid, release_origin)

    assert {:ok, :accepted, ^lease_owner, ^owner_incarnation} =
             release_as(
               owner,
               release_origin,
               "#{session_id}-release",
               session_id,
               holder.pid,
               holder.incarnation,
               release_worker,
               release_worker_incarnation,
               epoch,
               now_ms() + 2_000
             )

    assert_receive :retirement_prepared, 1_000
    origin = {observer.incarnation, 0, 1}
    {worker, worker_incarnation} = start_worker(observer.pid, origin)

    acquire =
      Task.async(fn ->
        long_acquire(
          owner,
          origin,
          "#{session_id}-acquire",
          session_id,
          observer,
          {worker, worker_incarnation}
        )
      end)

    assert :ok =
             wait_for_status(owner, fn _status ->
               match?(%{held: [_]}, :sys.get_state(owner).owners[session_id])
             end)

    {owner, observer, origin, acquire, lease_owner}
  end

  # Technical depth: a connection's acquire held across a five-second step
  # is awaited past the default call timeout.
  defp long_acquire(
         owner,
         origin,
         request_id,
         session_id,
         connection,
         {worker, worker_incarnation}
       ) do
    acquire_as(
      owner,
      origin,
      request_id,
      session_id,
      connection.pid,
      connection.incarnation,
      worker,
      worker_incarnation,
      now_ms() + 20_000,
      10_000
    )
  end

  # Concept: every acquire and release reaches the owner from the connection
  # it names, as a request whose reply the connection receives; the test
  # asks the manual connection to send it and waits for that reply.
  defp acquire_as(
         owner,
         origin,
         request_id,
         session_id,
         connection,
         connection_incarnation,
         worker,
         worker_incarnation,
         request_deadline,
         timeout \\ 5_000
       ) do
    as_connection(
      connection,
      fn ->
        Owner.acquire_control_request(
          owner,
          origin,
          request_id,
          session_id,
          connection,
          connection_incarnation,
          worker,
          worker_incarnation,
          request_deadline
        )
      end,
      timeout
    )
  end

  defp release_as(
         owner,
         origin,
         request_id,
         session_id,
         connection,
         connection_incarnation,
         worker,
         worker_incarnation,
         writer_epoch,
         request_deadline
       ) do
    as_connection(
      connection,
      fn ->
        Owner.release_control_request(
          owner,
          origin,
          request_id,
          session_id,
          connection,
          connection_incarnation,
          worker,
          worker_incarnation,
          writer_epoch,
          request_deadline
        )
      end,
      5_000
    )
  end

  defp as_connection(connection, request, timeout) do
    reference = make_ref()
    send(connection, {:manual_request, self(), reference, request})

    receive do
      {:manual_reply, ^reference, :owner_down} -> exit(:owner_down)
      {:manual_reply, ^reference, reply} -> reply
    after
      timeout -> exit({:timeout, :owner_request})
    end
  end

  defp wait_for_relay_permits(relay, count, attempts \\ 200)

  defp wait_for_relay_permits(relay, count, attempts) when attempts > 0 do
    status = AdmissionRelay.status(relay)

    if status.permits == count do
      status
    else
      Process.sleep(5)
      wait_for_relay_permits(relay, count, attempts - 1)
    end
  end

  defp wait_for_relay_permits(relay, _count, 0), do: AdmissionRelay.status(relay)

  # Concept: a fresh acquire whose connection is lost between the relay's
  # open and this owner's claim is refused `connection_lost` and its
  # disposition, which arrived while the claim was outstanding, is settled
  # once.
  #
  # Technical depth: the owner is suspended while the relay answers the
  # open, and the connection is killed then, so the relay's disposition is
  # retained at the owner before the claim is sent and refused.
  test "a fresh acquire whose connection is lost before its claim settles once" do
    owner = start_owner(fatal_recipient: self())
    components = Owner.components(owner)
    connection = initialized_connection(components)
    session_id = "lost-before-claim"
    origin = {connection.incarnation, 0, 1}
    {worker, worker_incarnation} = start_worker(connection.pid, origin)

    park_relay_message(
      components.relay,
      &match?({:"$gen_call", _from, {:open_lease_permit, _, ^origin, _, _, _, _, _, _, _}}, &1),
      :open_parked,
      :continue_open
    )

    acquire =
      Task.async(fn ->
        acquire_as(
          owner,
          origin,
          "lost-before-claim",
          session_id,
          connection.pid,
          connection.incarnation,
          worker,
          worker_incarnation,
          now_ms() + 2_000
        )
      end)

    assert_receive :open_parked, 500
    :sys.suspend(owner)
    send(components.relay, :continue_open)
    assert %{permits: 1} = wait_for_relay_permits(components.relay, 1)
    monitor = Process.monitor(connection.pid)
    Process.exit(connection.pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, _connection, :killed}, 500
    assert %{settling: 1} = wait_for_relay_settling(components.relay)
    :sys.resume(owner)
    # The connection is gone, so the refusal reaches no one.
    Task.shutdown(acquire, :brutal_kill)

    assert :ok =
             wait_for_status(
               owner,
               &(&1.lease_operations == 0 and &1.pending_dispositions == 0 and
                   &1.mirror_operations == 0 and &1.owner_slots == 0)
             )

    assert %{permits: 0} = wait_for_relay_permits(components.relay, 0)
    refute_receive {:daemon_component_fatal, _reporter, _class}, 100
  end

  # Concept: a successor acquire whose claim is still outstanding when its
  # predecessor's retirement finishes is started by the claim's answer, not
  # refused as an inconsistent operation.
  #
  # Technical depth: both retirement gates hold the predecessor; its exit is
  # released first, the successor's claim is parked at the relay, and the
  # retirement pop is released then, so the retirement finishes while the
  # successor is `:claiming`.
  test "a successor opened while its predecessor finishes starts after its claim" do
    owner = start_owner(retirement_pop_gate: self(), retirement_exit_gate: self())
    components = Owner.components(owner)
    holder = initialized_connection(components)
    observer = initialized_connection(components)
    session_id = "claiming-successor"
    {lease_owner, owner_incarnation, epoch} = acquire_held(owner, holder, session_id)
    release_origin = {holder.incarnation, 1, 1}
    {release_worker, release_worker_incarnation} = start_worker(holder.pid, release_origin)

    assert {:ok, :accepted, ^lease_owner, ^owner_incarnation} =
             release_as(
               owner,
               release_origin,
               "claiming-successor-release",
               session_id,
               holder.pid,
               holder.incarnation,
               release_worker,
               release_worker_incarnation,
               epoch,
               now_ms() + 2_000
             )

    assert_receive {:retirement_exit_blocked, ^lease_owner, ^owner_incarnation, retirement_ref},
                   1_000

    assert :ok = LeaseOwner.release_retirement_exit(lease_owner, retirement_ref)
    assert_receive {:retirement_pop_blocked, ^owner, ^session_id}, 1_000

    assert :ok =
             wait_for_status(owner, fn _status ->
               match?(%{relay_complete: true}, :sys.get_state(owner).owners[session_id])
             end)

    origin = {observer.incarnation, 0, 1}
    {worker, worker_incarnation} = start_worker(observer.pid, origin)

    park_relay_message(
      components.relay,
      &match?({:"$gen_call", _from, {:claim_lease_permit, ^origin, _, _}}, &1),
      :claim_parked,
      :continue_claim
    )

    acquire =
      Task.async(fn ->
        acquire_as(
          owner,
          origin,
          "claiming-successor-acquire",
          session_id,
          observer.pid,
          observer.incarnation,
          worker,
          worker_incarnation,
          now_ms() + 5_000
        )
      end)

    assert_receive :claim_parked, 500
    assert :ok = Owner.release_retirement_pop(owner, session_id)

    assert :ok =
             wait_for_status(owner, fn _status ->
               match?(%{mirror_complete: true}, :sys.get_state(owner).owners[session_id])
             end)

    assert Process.alive?(owner)
    send(components.relay, :continue_claim)
    assert {:ok, :accepted, ^owner, _daemon_incarnation} = Task.await(acquire, 1_000)
    observer_pid = observer.pid

    assert_receive {:manual_connection_message, ^observer_pid,
                    {:relay_permit_result, ^origin, %{"result" => %{"writer_epoch" => _}}}},
                   1_000
  end

  # Concept (T21 at the collaboration owner): between the cut and the
  # freeze, a lease owner's and a registry's reports of relay requests left
  # unanswered for five seconds are cleanup-only; the stop's own deadlines
  # govern, the relay keeps serving once it resumes, and the freeze then
  # settles.
  #
  # Technical depth: a mutation ticket is opened before the cut; after the
  # cut the relay is suspended for six seconds while the lease owner's
  # promotion and a registry promotion wait on it. An owner debug hook
  # forwards both kinds of report: the lease owner's real report arrives and
  # latches nothing; the registry arms no instant after the cut, so its
  # waiting promotion reports nothing at all.
  @tag timeout: 30_000
  test "a lease owner's real unanswered-relay report during the stop latches nothing" do
    owner = start_owner(fatal_recipient: self(), admission_wait_ms: 10_000)
    components = Owner.components(owner)
    holder = initialized_connection(components)
    session_id = "stop-report"
    {lease_owner, owner_incarnation, epoch} = acquire_held(owner, holder, session_id)
    origin = {holder.incarnation, 1, 1}
    worker = spawn(fn -> Process.sleep(20_000) end)
    relay = components.relay

    assert {:ok, ^origin} =
             manual_call(
               holder.pid,
               {:open_ticket, relay, origin, :session_prompt, session_id,
                {lease_owner, owner_incarnation}}
             )

    assert :ok =
             manual_call(
               holder.pid,
               {:invoke,
                fn -> AdmissionRelay.bind_ticket_worker(relay, origin, worker, incarnation()) end}
             )

    test_pid = self()

    :ok =
      :sys.install(
        owner,
        {fn
           forwarded,
           {:in, {:lease_owner_relay_unanswered, ^lease_owner, _incarnation}},
           _proc_state ->
             send(test_pid, :lease_owner_reported)
             forwarded

           forwarded, {:in, {:registry_relay_unanswered, _registry, _incarnation}}, _proc_state ->
             send(test_pid, :registry_reported)
             forwarded

           forwarded, _event, _proc_state ->
             forwarded
         end, :forwarding}
      )

    assert {:ok, _cut_ref} = Owner.cut_admission(owner, 10_000)
    :sys.suspend(relay)

    send(
      holder.pid,
      {:manual_call, self(), make_ref(),
       {:invoke,
        fn ->
          lease_mutate(
            lease_owner,
            origin,
            :session_prompt,
            "stop-report-mutation",
            holder.incarnation,
            epoch,
            worker,
            fn -> {:accepted, %{"accepted" => true}} end
          )
        end}}
    )

    spawn_registry_promotion(components.registry, {:crypto.strong_rand_bytes(16), 0, 1})
    assert_receive :lease_owner_reported, 6_000
    refute_received :registry_reported
    refute_receive {:daemon_component_fatal, _reporter, _class}, 500
    :sys.resume(relay)
    assert Process.alive?(relay)
    assert %{fatal_teardown: false} = :sys.get_state(owner)
    assert {:ok, _descriptors} = freeze(owner)
    refute_receive {:daemon_component_fatal, _reporter, _class}, 100
  end

  # Concept (review item 2): no owner row is dropped with a request still
  # held on it. A successor whose claim fails after its predecessor's loss
  # finished frees the row, and the request held there is answered.
  #
  # Technical depth: driven directly against the owner's state: a finished
  # loss row with a claiming successor and one held release is given the
  # relay's refusal of the successor's claim.
  test "a successor claim refused after a finished loss answers the held request" do
    {state, session_id, row} = finished_loss_state("successor-claim-held")
    successor_tag = make_ref()
    held_tag = make_ref()
    successor_origin = {incarnation(), 0, 1}
    request_id = make_ref()

    held = %{
      request: other_release(session_id),
      from: {self(), held_tag},
      reason: :actor_lost,
      owner: row.pid,
      timer: nil
    }

    operation = %{
      request: %{
        class: :session_acquire_control,
        session_id: session_id,
        permit_id: successor_origin,
        connection: self(),
        connection_incarnation: elem(successor_origin, 0),
        request_id: "successor",
        request_deadline: now_ms() + 5_000
      },
      owner_pid: nil,
      owner_incarnation: nil,
      actor_pid: self(),
      actor_incarnation: state.daemon_incarnation,
      start_op_ref: make_ref(),
      phase: :claiming,
      reply_to: {self(), successor_tag}
    }

    state =
      state
      |> put_in([:owners, session_id], %{row | successor: successor_origin, held: [held]})
      |> put_in([:operations, successor_origin], operation)
      |> put_in([:relay_requests, request_id], %{
        continuation: {:claim, successor_origin},
        timer: nil
      })

    assert {:noreply, state} =
             Owner.handle_info({[:alias | request_id], {:error, :permit_unavailable}}, state)

    assert_received {^successor_tag, {:error, :permit_unavailable}}
    assert_received {^held_tag, {:error, :control_not_held}}
    refute Map.has_key?(state.owners, session_id)
  end

  # Concept (review item 3, F8): held acquires keep their arrival order: an
  # acquire that arrives while an earlier one is held waits behind it, so the
  # earlier one becomes the session's next holder.
  #
  # Technical depth: the first observer's acquire is refused `actor_lost`
  # and held; the second arrives after the loss began and queues behind it.
  test "an acquire arriving behind a held acquire keeps its place" do
    owner = start_owner()
    components = Owner.components(owner)
    holder = initialized_connection(components)
    first = initialized_connection(components)
    second = initialized_connection(components)
    session_id = "held-order"
    {lease_owner, _owner_incarnation, _epoch} = acquire_held(owner, holder, session_id)
    first_origin = {first.incarnation, 0, 1}
    {first_worker, first_worker_incarnation} = start_worker(first.pid, first_origin)
    :sys.suspend(owner)

    first_acquire =
      Task.async(fn ->
        acquire_as(
          owner,
          first_origin,
          "held-first",
          session_id,
          first.pid,
          first.incarnation,
          first_worker,
          first_worker_incarnation,
          now_ms() + 5_000
        )
      end)

    assert :ok = wait_for_queue_length(owner, 1)
    Process.exit(lease_owner, :kill)
    assert %{owner_losses: 1} = wait_for_relay_owner_loss(components.relay)
    :sys.resume(owner)
    holder_pid = holder.pid

    assert_receive {:manual_connection_message, ^holder_pid,
                    {:daemon_control_owner_lost, ^owner, close_ref, ^session_id, _incarnation}},
                   1_000

    assert :ok =
             wait_for_status(owner, fn _status ->
               match?(%{held: [_]}, :sys.get_state(owner).owners[session_id])
             end)

    second_origin = {second.incarnation, 0, 1}
    {second_worker, second_worker_incarnation} = start_worker(second.pid, second_origin)

    second_acquire =
      Task.async(fn ->
        acquire_as(
          owner,
          second_origin,
          "held-second",
          session_id,
          second.pid,
          second.incarnation,
          second_worker,
          second_worker_incarnation,
          now_ms() + 5_000
        )
      end)

    assert :ok =
             wait_for_status(owner, fn _status ->
               match?(%{held: [_, _]}, :sys.get_state(owner).owners[session_id])
             end)

    close_owner_loss_holder(owner, holder, close_ref)
    assert {:ok, :accepted, _first_actor, _} = Task.await(first_acquire, 1_000)
    assert {:ok, :accepted, _second_actor, _} = Task.await(second_acquire, 1_000)
    first_pid = first.pid
    second_pid = second.pid

    assert_receive {:manual_connection_message, ^first_pid,
                    {:relay_permit_result, ^first_origin, %{"result" => %{"writer_epoch" => _}}}},
                   1_000

    assert_receive {:manual_connection_message, ^second_pid,
                    {:relay_permit_result, ^second_origin, %{"code" => "control_held"}}},
                   1_000
  end

  # Concept (review item 4): a request refused `actor_lost` after the
  # admission cut is answered `daemon_stopping` at once, since the cut has
  # already answered every held request and no later hold would be; it is
  # never held and dispatched again.
  test "a hold created after the cut is refused daemon_stopping" do
    owner = start_owner(admission_wait_ms: 5_000)
    components = Owner.components(owner)
    holder = initialized_connection(components)
    observer = initialized_connection(components)
    session_id = "hold-after-cut"
    {lease_owner, _owner_incarnation, _epoch} = acquire_held(owner, holder, session_id)
    origin = {observer.incarnation, 0, 1}
    {worker, worker_incarnation} = start_worker(observer.pid, origin)
    :sys.suspend(owner)

    renewal =
      Task.async(fn ->
        acquire_as(
          owner,
          origin,
          "hold-after-cut",
          session_id,
          observer.pid,
          observer.incarnation,
          worker,
          worker_incarnation,
          now_ms() + 5_000
        )
      end)

    assert :ok = wait_for_queue_length(owner, 1)
    Process.exit(lease_owner, :kill)
    assert %{owner_losses: 1} = wait_for_relay_owner_loss(components.relay)

    test_pid = self()

    :ok =
      :sys.install(
        components.relay,
        {fn
           reporting,
           {:in, {:"$gen_call", _from, {:open_lease_permit, _, ^origin, _, _, _, _, _, _, _}}},
           _state ->
             send(test_pid, :relay_saw_open)
             reporting

           reporting, _event, _state ->
             reporting
         end, :reporting}
      )

    park_relay_message(
      components.relay,
      &match?({:"$gen_call", _from, {:open_lease_permit, _, ^origin, _, _, _, _, _, _, _}}, &1),
      :open_parked,
      :continue_open
    )

    :sys.resume(owner)
    assert_receive :open_parked, 500
    cut = Task.async(fn -> Owner.cut_admission(owner, 5_000) end)
    assert :ok = wait_for_status(owner, fn _status -> not is_nil(:sys.get_state(owner).stop) end)
    send(components.relay, :continue_open)
    assert {:error, :daemon_stopping} = Task.await(renewal, 500)
    assert_received :relay_saw_open
    refute_receive :relay_saw_open, 200
    Task.await(cut, 6_000)
  end

  # Concept (review item 2): an acquire or a release reaches the owner only
  # from the connection it names; any other caller is refused before any
  # permit exists.
  test "a request naming another connection is refused and opens nothing" do
    owner = start_owner()
    components = Owner.components(owner)
    connection = initialized_connection(components)
    origin = {connection.incarnation, 0, 1}
    {worker, worker_incarnation} = start_worker(connection.pid, origin)

    acquire =
      Owner.acquire_control_request(
        owner,
        origin,
        "impostor-acquire",
        "impostor-session",
        connection.pid,
        connection.incarnation,
        worker,
        worker_incarnation,
        now_ms() + 2_000
      )

    assert {:reply, {:error, :invalid_operation}} = :gen_server.receive_response(acquire, 1_000)

    release =
      Owner.release_control_request(
        owner,
        {connection.incarnation, 1, 1},
        "impostor-release",
        "impostor-session",
        connection.pid,
        connection.incarnation,
        worker,
        worker_incarnation,
        incarnation(),
        now_ms() + 2_000
      )

    assert {:reply, {:error, :invalid_operation}} = :gen_server.receive_response(release, 1_000)
    assert %{permits: 0} = AdmissionRelay.status(components.relay)
    assert %{lease_operations: 0, owner_slots: 0} = Owner.status(owner)
  end

  # Concept (round 3 item 2): a malformed acquire or release request —
  # too short, or the wrong size for its tag — is refused `invalid_operation`
  # and never stops the owner.
  test "a malformed acquire or release request is refused" do
    owner = start_owner()
    me = self()

    for message <- [
          {:acquire_control},
          {:release_control, 1, 2},
          {:acquire_control, 1, 2, 3, me, 5, 6, 7, 8, 9},
          {:release_control, 1, 2, 3, me, 5, 6, 7, 8},
          {:acquire_control, 1, 2, 3, me, 5, 6, 7, 8}
        ] do
      assert {:error, :invalid_operation} = GenServer.call(owner, message)
    end

    assert Process.alive?(owner)
    assert %{lease_operations: 0} = Owner.status(owner)
  end

  # Concept (review item 4): after the lease freeze no lease request reaches
  # the relay: a connection's acquire is refused `daemon_stopping` by the
  # owner itself.
  #
  # Technical depth: a relay debug hook reports every permit open it
  # receives after the freeze.
  test "after the freeze an acquire is refused without reaching the relay" do
    owner = start_owner()
    components = Owner.components(owner)
    connection = initialized_connection(components)
    assert {:ok, _cut_ref} = Owner.cut_admission(owner, 5_000)
    assert {:ok, _descriptors} = freeze(owner)
    test_pid = self()

    :ok =
      :sys.install(
        components.relay,
        {fn
           reporting, {:in, {:"$gen_call", _from, request}}, _state
           when elem(request, 0) == :open_lease_permit ->
             send(test_pid, :relay_saw_open)
             reporting

           reporting, _event, _state ->
             reporting
         end, :reporting}
      )

    origin = {connection.incarnation, 0, 1}
    {worker, worker_incarnation} = start_worker(connection.pid, origin)

    assert {:error, :daemon_stopping} =
             acquire_as(
               owner,
               origin,
               "after-freeze",
               "after-freeze-session",
               connection.pid,
               connection.incarnation,
               worker,
               worker_incarnation,
               now_ms() + 2_000
             )

    refute_receive :relay_saw_open, 100
  end

  # Concept (review item 4, review item 5): the freeze does not settle while
  # a relay request this owner sent after the freeze barrier is unanswered,
  # and the relay's refusal of that request during the stop latches nothing.
  #
  # Technical depth: a fresh acquire's open is parked across the cut, so its
  # claim and its lease owner's registration follow the cut; the registration
  # is parked until the freeze is requested, and its refusal makes this
  # owner complete the first permit through the relay after the freeze
  # barrier. That completion is parked while the freeze waits.
  @tag timeout: 30_000
  test "the freeze waits for a completion sent after its barrier" do
    owner = start_owner(fatal_recipient: self(), admission_wait_ms: 5_000)
    components = Owner.components(owner)
    connection = initialized_connection(components)
    session_id = "freeze-wait"
    origin = {connection.incarnation, 0, 1}
    {worker, worker_incarnation} = start_worker(connection.pid, origin)

    park_relay_message(
      components.relay,
      &match?({:"$gen_call", _from, {:open_lease_permit, _, ^origin, _, _, _, _, _, _, _}}, &1),
      :open_parked,
      :continue_open
    )

    park_relay_message(
      components.relay,
      &match?({:"$gen_call", _from, {:register_lease_owner, ^session_id, _, _}}, &1),
      :register_parked,
      :continue_register
    )

    park_relay_message(
      components.relay,
      &match?({:"$gen_call", _from, {:complete_lease_permit, ^origin, _, _}}, &1),
      :complete_parked,
      :continue_complete
    )

    acquire =
      Task.async(fn ->
        acquire_as(
          owner,
          origin,
          "freeze-wait",
          session_id,
          connection.pid,
          connection.incarnation,
          worker,
          worker_incarnation,
          now_ms() + 5_000
        )
      end)

    assert_receive :open_parked, 500
    cut = Task.async(fn -> Owner.cut_admission(owner, 5_000) end)
    assert :ok = wait_for_status(owner, fn _status -> not is_nil(:sys.get_state(owner).stop) end)

    send(components.relay, :continue_open)
    assert_receive :register_parked, 1_000
    assert {:ok, _cut_ref} = Task.await(cut, 6_000)
    assert {:ok, :accepted, _child, _child_incarnation} = Task.await(acquire, 1_000)

    frozen = Task.async(fn -> freeze(owner) end)
    assert :ok = wait_for_queue_length(components.relay, 1)
    send(components.relay, :continue_register)
    assert_receive :complete_parked, 1_000
    assert nil == Task.yield(frozen, 300)
    send(components.relay, :continue_complete)
    assert {:ok, _descriptors} = Task.await(frozen, 6_000)
    assert :sys.get_state(owner).relay_requests == %{}
    refute_receive {:daemon_component_fatal, _reporter, _class}, 100
  end

  # Concept (review item 5): during the stop a relay refusal of this owner's
  # completion is cleanup only; `relay_lost` latches only while serving.
  #
  # Technical depth: driven directly against the owner's state, because a
  # correct relay does not produce it: a completion sent before the freeze
  # barrier is answered before it and admitted, and one sent after it is
  # answered only after the barrier's acknowledgement has already
  # tombstoned the operation.
  test "a completion refused during the stop latches nothing" do
    owner = start_owner(fatal_recipient: self())
    assert {:ok, _cut_ref} = Owner.cut_admission(owner, 5_000)
    state = :sys.get_state(owner)
    permit_id = {incarnation(), 0, 1}
    request_id = make_ref()

    operation = %{
      request: %{
        class: :session_acquire_control,
        session_id: "stop-complete",
        permit_id: permit_id
      },
      owner_pid: nil,
      owner_incarnation: nil,
      actor_pid: self(),
      actor_incarnation: state.daemon_incarnation,
      start_op_ref: make_ref(),
      phase: :refusing
    }

    state =
      state
      |> put_in([:operations, permit_id], operation)
      |> put_in([:relay_requests, request_id], %{
        continuation: {:complete, permit_id, :registration_failed},
        timer: nil
      })

    assert {:noreply, settled} =
             Owner.handle_info({[:alias | request_id], {:error, :daemon_stopping}}, state)

    refute settled.fatal_teardown
    refute_received {:daemon_component_fatal, _reporter, _class}
  end

  # Concept (review item 5): a `:result` notice meeting a retained
  # connection loss during the stop is cleanup only.
  #
  # Technical depth: driven directly against the owner's state, because the
  # pairing cannot be produced: one relay compare-and-set decides each
  # permit, so a `:result` and a connection-loss disposition for the same
  # permit never both exist unless the relay is inconsistent.
  test "a result notice meeting a retained loss during the stop latches nothing" do
    owner = start_owner(fatal_recipient: self())
    assert {:ok, _cut_ref} = Owner.cut_admission(owner, 5_000)
    state = :sys.get_state(owner)
    permit_id = {incarnation(), 0, 1}
    lease_owner = spawn(fn -> Process.sleep(1_000) end)
    lease_owner_incarnation = incarnation()

    state =
      state
      |> put_in([:operations, permit_id], %{
        request: %{
          class: :session_acquire_control,
          session_id: "stop-notice",
          permit_id: permit_id
        },
        owner_pid: lease_owner,
        owner_incarnation: lease_owner_incarnation,
        actor_pid: lease_owner,
        actor_incarnation: lease_owner_incarnation,
        start_op_ref: nil,
        phase: :opened
      })
      |> put_in([:pending_dispositions, permit_id], %{settlement_ref: make_ref()})

    assert {:noreply, settled} =
             Owner.handle_info(
               {:lease_permit_settled, permit_id, lease_owner, lease_owner_incarnation, :result},
               state
             )

    refute settled.fatal_teardown
    refute_received {:daemon_component_fatal, _reporter, _class}
  end

  # Concept (review item 5): `invalid_actor` for a lease owner this owner
  # still has live is the relay's loss and still answers the request; for a
  # lease owner that has already retired or exited it is treated like any
  # refusal of a departing actor, and latches nothing.
  #
  # Technical depth: these are driven directly against the owner's state.
  # A live-actor refusal needs a relay that disagrees with the owner, which
  # a correct relay never does; a departed-actor refusal needs the lease
  # owner's exit or retirement to overtake the owner's earlier open at the
  # relay, an order between different senders the runtime does not let a
  # test impose.
  test "invalid_actor for a live actor answers the request and latches relay_lost" do
    {state, session_id, row} = live_row_state("invalid-actor", fatal_recipient: self())
    live_tag = make_ref()
    {state, live_request} = opening_existing(state, session_id, row, live_tag, :acquire)

    assert {:noreply, latched} =
             Owner.handle_info({[:alias | live_request], {:error, :invalid_actor}}, state)

    assert_received {^live_tag, {:error, :owner_unavailable}}
    assert latched.fatal_teardown
    assert_received {:daemon_component_fatal, _reporter, :relay_lost}
  end

  test "invalid_actor for a retired actor is released at once and latches nothing" do
    {state, session_id, row} = live_row_state("departed-actor", fatal_recipient: self())
    retiring = %{row | phase: :retiring, retirement_ref: make_ref()}
    state = put_in(state, [:owners, session_id], retiring)
    departed_tag = make_ref()

    {state, departed_request} =
      opening_existing(state, session_id, retiring, departed_tag, :release)

    assert {:noreply, released} =
             Owner.handle_info({[:alias | departed_request], {:error, :invalid_actor}}, state)

    assert_received {^departed_tag, {:error, :control_not_held}}
    refute released.fatal_teardown
    refute_received {:daemon_component_fatal, _reporter, _class}
  end

  # Concept (review item 3): `invalid_actor` for a lease owner whose exit
  # this owner has consumed but whose loss has not finished is held until
  # that loss finishes, like `actor_lost`, and latches nothing.
  #
  # Technical depth: driven directly against the owner's state, because a
  # correct relay cannot produce it: `open_existing` is reached only for a
  # `:live` row, so the open was sent before this owner consumed the exit,
  # and the relay removes a lost lease owner's binding only through this
  # owner's later classification, which it handles after that earlier open;
  # the open therefore meets `actor_lost`, never `invalid_actor`.
  test "invalid_actor for an exited actor whose loss is unfinished is held" do
    {state, session_id, row} = live_row_state("exited-actor", fatal_recipient: self())
    lost = %{row | phase: :lost, exit_consumed: true}
    state = put_in(state, [:owners, session_id], lost)
    tag = make_ref()
    {state, request_id} = opening_existing(state, session_id, lost, tag, :release)

    assert {:noreply, held} =
             Owner.handle_info({[:alias | request_id], {:error, :invalid_actor}}, state)

    refute_received {^tag, _reply}
    assert [%{reason: :actor_lost}] = held.owners[session_id].held
    refute held.fatal_teardown
    refute_received {:daemon_component_fatal, _reporter, _class}
  end

  # Concept (review item 6): a claimed permit whose session row is gone is
  # answered and refused through the relay, never left to crash the owner.
  #
  # Technical depth: driven directly against the owner's state, because a
  # claiming operation's row is removed only by that operation's own
  # answers, so the state cannot be produced by any interleaving.
  test "a claim answered after its session row is gone is still answered" do
    owner = start_owner()
    state = :sys.get_state(owner)
    permit_id = {incarnation(), 0, 1}
    request_id = make_ref()
    tag = make_ref()

    operation = %{
      request: %{
        class: :session_acquire_control,
        session_id: "rowless-claim",
        permit_id: permit_id,
        request_id: "rowless-claim"
      },
      owner_pid: nil,
      owner_incarnation: nil,
      actor_pid: self(),
      actor_incarnation: state.daemon_incarnation,
      start_op_ref: make_ref(),
      phase: :claiming,
      reply_to: {self(), tag}
    }

    state =
      state
      |> put_in([:operations, permit_id], operation)
      |> put_in([:relay_requests, request_id], %{continuation: {:claim, permit_id}, timer: nil})

    assert {:noreply, refusing} = Owner.handle_info({[:alias | request_id], :ok}, state)
    assert_received {^tag, {:ok, :accepted, _actor, _incarnation}}
    assert %{phase: :refusing} = refusing.operations[permit_id]
    assert map_size(refusing.relay_requests) == 1
  end

  # Concept (D4): a fresh lease owner lost while its registration is in
  # flight keeps its row, so its loss is reported against a known owner and
  # finishes: the first acquire is refused through the relay and the slot
  # frees.
  #
  # Technical depth: the relay is parked on the registration; the child is
  # killed there, so the owner consumes its `EXIT` while the row is still
  # registering and the relay then registers a dead pid and reports its loss.
  test "a lease owner lost while registering keeps its row until its loss finishes" do
    owner = start_owner(fatal_recipient: self())
    components = Owner.components(owner)
    connection = initialized_connection(components)
    session_id = "lost-registering"
    origin = {connection.incarnation, 0, 1}
    {worker, worker_incarnation} = start_worker(connection.pid, origin)

    park_relay_message(
      components.relay,
      &match?({:"$gen_call", _from, {:register_lease_owner, ^session_id, _, _}}, &1),
      :register_parked,
      :continue_register
    )

    assert {:ok, :accepted, child, _child_incarnation} =
             acquire_as(
               owner,
               origin,
               "lost-registering",
               session_id,
               connection.pid,
               connection.incarnation,
               worker,
               worker_incarnation,
               now_ms() + 2_000
             )

    assert_receive :register_parked, 500
    monitor = Process.monitor(child)
    Process.exit(child, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^child, :killed}, 500

    assert :ok =
             wait_for_status(owner, fn _status ->
               match?(%{phase: :lost}, :sys.get_state(owner).owners[session_id])
             end)

    send(components.relay, :continue_register)

    assert_receive {:manual_connection_message, _connection,
                    {:relay_permit_result, ^origin, %{"code" => "control_pending"}}},
                   1_000

    assert %{owner_slots: 0, lease_operations: 0} = wait_for_owner_retirement(owner)
    assert Process.alive?(owner)
    refute_receive {:daemon_component_fatal, _reporter, _class}, 100
  end

  # Concept (T7, R7): a lease owner's completion the relay records before the
  # freeze is a terminal direct result the freeze does not name; the notice
  # that follows still removes the operation, before or after the freeze
  # settles, and the stop continues.
  #
  # Technical depth: the observer's permit is opened before the cut with its
  # lease owner suspended; after the cut the relay is parked on that lease
  # owner's `control_held` completion and the freeze is requested behind it.
  test "a completion recorded before the freeze settles through its notice" do
    owner = start_owner(fatal_recipient: self(), admission_wait_ms: 5_000)
    components = Owner.components(owner)
    holder = initialized_connection(components)
    observer = initialized_connection(components)
    session_id = "freeze-notice"
    {lease_owner, owner_incarnation, _epoch} = acquire_held(owner, holder, session_id)
    origin = {observer.incarnation, 0, 1}
    {worker, worker_incarnation} = start_worker(observer.pid, origin)
    :sys.suspend(lease_owner)

    assert {:ok, :accepted, ^lease_owner, ^owner_incarnation} =
             acquire_as(
               owner,
               origin,
               "freeze-notice",
               session_id,
               observer.pid,
               observer.incarnation,
               worker,
               worker_incarnation,
               now_ms() + 5_000
             )

    assert {:ok, _cut_ref} = Owner.cut_admission(owner, 5_000)

    park_relay_message(
      components.relay,
      &match?({:"$gen_call", _from, {:complete_lease_permit, ^origin, _, _}}, &1),
      :complete_parked,
      :continue_complete
    )

    :sys.resume(lease_owner)
    assert_receive :complete_parked, 500
    frozen = Task.async(fn -> freeze(owner) end)
    assert :ok = wait_for_queue_length(components.relay, 1)
    send(components.relay, :continue_complete)
    assert {:ok, _descriptors} = Task.await(frozen, 6_000)
    observer_pid = observer.pid

    assert_receive {:manual_connection_message, ^observer_pid,
                    {:relay_permit_result, ^origin, %{"code" => "control_held"}}},
                   1_000

    assert :ok = wait_for_status(owner, &(&1.lease_operations == 0))
    refute_receive {:daemon_component_fatal, _reporter, _class}, 100
  end

  # Technical depth: a live owner's state after a real loss of the session's
  # lease owner has finished, with that row kept as a template.
  defp finished_loss_state(session_id) do
    owner = start_owner()
    components = Owner.components(owner)
    holder = initialized_connection(components)
    {lease_owner, _owner_incarnation, _epoch} = acquire_held(owner, holder, session_id)
    template = :sys.get_state(owner).owners[session_id]
    monitor = Process.monitor(lease_owner)
    Process.exit(lease_owner, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^lease_owner, :killed}, 500
    holder_pid = holder.pid

    assert_receive {:manual_connection_message, ^holder_pid,
                    {:daemon_control_owner_lost, ^owner, close_ref, ^session_id, _incarnation}},
                   1_000

    close_owner_loss_holder(owner, holder, close_ref)
    assert %{owner_slots: 0} = wait_for_owner_retirement(owner)
    state = :sys.get_state(owner)

    row = %{
      template
      | phase: :lost,
        exit_consumed: true,
        mirror_complete: true,
        classification_complete: true,
        notification_complete: true,
        relay_loss_seen: true,
        relay_loss_ready: true,
        loss_origins: [],
        slot_charged: true
    }

    {state, session_id, row}
  end

  defp live_row_state(session_id, options) do
    owner = start_owner(options)
    components = Owner.components(owner)
    holder = initialized_connection(components)
    {_lease_owner, _owner_incarnation, _epoch} = acquire_held(owner, holder, session_id)
    state = :sys.get_state(owner)
    {state, session_id, state.owners[session_id]}
  end

  # Technical depth: an existing-owner operation awaiting the relay's open,
  # with its request identifier registered as outstanding.
  defp opening_existing(state, session_id, row, tag, kind) do
    request_id = make_ref()

    request =
      if kind == :acquire,
        do: %{
          class: :session_acquire_control,
          session_id: session_id,
          permit_id: {incarnation(), 0, 1},
          connection: self(),
          connection_incarnation: incarnation(),
          request_id: "invalid-actor",
          request_deadline: now_ms() + 5_000
        },
        else: other_release(session_id)

    operation = %{
      request: request,
      owner_pid: row.pid,
      owner_incarnation: row.incarnation,
      actor_pid: row.pid,
      actor_incarnation: row.incarnation,
      start_op_ref: nil,
      phase: :opening,
      reply_to: {self(), tag}
    }

    state =
      state
      |> put_in([:operations, request.permit_id], operation)
      |> put_in([:relay_requests, request_id], %{
        continuation: {:open, request.permit_id},
        timer: nil
      })

    {state, request_id}
  end

  defp other_release(session_id) do
    connection_incarnation = incarnation()

    %{
      class: :session_release_control,
      session_id: session_id,
      permit_id: {connection_incarnation, 0, 1},
      connection: spawn(fn -> :ok end),
      connection_incarnation: connection_incarnation,
      request_id: "other-release",
      writer_epoch: incarnation()
    }
  end

  # Concept: a connection sends its mutation or resume descriptor without
  # blocking, exactly as the socket connection does; this helper runs in the
  # connection and waits for that one reply.
  defp descriptor_call(owner, descriptor) do
    calls = LeaseOwner.send_descriptor(owner, descriptor, :descriptor, :gen_server.reqids_new())

    case :gen_server.receive_response(calls, 10_000, true) do
      {{:reply, reply}, :descriptor, _calls} -> reply
      {{:error, {reason, _server}}, :descriptor, _calls} -> exit(reason)
    end
  end

  defp lease_mutate(owner, origin, class, request_id, incarnation, epoch, worker, task),
    do:
      descriptor_call(
        owner,
        {:mutate, origin, class, request_id, incarnation, epoch, worker, task}
      )

  # Concept (step 7, risk item 7): a holder that disconnects after its
  # owner-lost close was sent, without acknowledging it, completes the close
  # by its exit; the daemon keeps serving.
  #
  # Technical depth: the close reaches the manual holder, which never
  # answers, and the holder is then killed well inside its step.
  test "a holder disconnecting after its close was sent completes the loss" do
    owner = start_owner(mirror_deadline_ms: 1_000, fatal_recipient: self())
    components = Owner.components(owner)
    holder = initialized_connection(components)
    holder_pid = holder.pid
    {lease_owner, _owner_incarnation, _epoch} = acquire_held(owner, holder, "racing-holder")
    Process.exit(lease_owner, :kill)

    assert_receive {:manual_connection_message, ^holder_pid,
                    {:daemon_control_owner_lost, ^owner, _close_ref, "racing-holder",
                     _incarnation}},
                   500

    Process.exit(holder_pid, :kill)
    assert %{owner_slots: 0, lost_owners: 0} = wait_for_owner_retirement(owner)
    refute_received {:daemon_component_fatal, _reporter, _class}
    Process.sleep(1_100)
    refute_received {:daemon_component_fatal, _reporter, _class}
    assert Process.alive?(owner)
  end

  # Concept (P3, T12): a holder that ignores its owner-lost close is killed at
  # its step's instant, its exit completes the close, and the daemon keeps
  # serving without a daemon-wide failure.
  test "a holder ignoring its close is killed at its step and the loss completes" do
    owner = start_owner(mirror_deadline_ms: 300, fatal_recipient: self())
    components = Owner.components(owner)
    holder = initialized_connection(components)
    holder_pid = holder.pid
    {lease_owner, _owner_incarnation, _epoch} = acquire_held(owner, holder, "silent-holder")
    holder_monitor = Process.monitor(holder_pid)
    Process.exit(lease_owner, :kill)

    assert_receive {:manual_connection_message, ^holder_pid,
                    {:daemon_control_owner_lost, ^owner, _close_ref, "silent-holder",
                     _incarnation}},
                   500

    sent = now_ms()
    assert_receive {:DOWN, ^holder_monitor, :process, ^holder_pid, :killed}, 1_000
    assert now_ms() - sent >= 250
    assert %{owner_slots: 0, lost_owners: 0} = wait_for_owner_retirement(owner)
    refute_received {:daemon_component_fatal, _reporter, _class}
    assert Process.alive?(owner)
    assert Process.alive?(components.registry)
  end

  # Concept (P1): a relay step that overruns its own instant names the relay.
  #
  # Technical depth: the relay is parked on a fresh grant's result selection
  # past its 300 ms step.
  test "a grant selection overrunning its step names the relay" do
    owner = start_owner(mirror_deadline_ms: 300)
    components = Owner.components(owner)
    connection = initialized_connection(components)
    origin = {connection.incarnation, 0, 1}
    {worker, worker_incarnation} = start_worker(connection.pid, origin)
    park_relay_operation(components.relay, :select_result)
    owner_monitor = Process.monitor(owner)

    assert {:ok, :accepted, _lease_owner, _incarnation} =
             acquire_as(
               owner,
               origin,
               "late-selection",
               "late-selection-session",
               connection.pid,
               connection.incarnation,
               worker,
               worker_incarnation,
               now_ms() + 5_000
             )

    assert_receive {:relay_operation_parked, :select_result}, 500
    assert_receive {:DOWN, ^owner_monitor, :process, ^owner, :relay_lost}, 1_000
  end

  # Concept (P1): a late owner-loss classification is the relay's lateness,
  # never the registry's.
  #
  # Technical depth: the relay is parked on the classification past its
  # 300 ms step.
  test "an owner-loss classification overrunning its step names the relay" do
    owner = start_owner(mirror_deadline_ms: 300)
    components = Owner.components(owner)
    holder = initialized_connection(components)
    {lease_owner, _owner_incarnation, _epoch} = acquire_held(owner, holder, "late-classification")
    park_relay_classification(components.relay)
    owner_monitor = Process.monitor(owner)
    Process.exit(lease_owner, :kill)
    assert_receive :relay_classification_parked, 500
    assert_receive {:DOWN, ^owner_monitor, :process, ^owner, :relay_lost}, 1_000
  end

  # Concept (P1, P2): a lease owner that overruns its own resolution step is
  # killed and superseded, scoped to its session: its grant still reaches the
  # client through the lost-owner path, and the daemon keeps serving.
  #
  # Technical depth: the relay is parked on the fresh lease owner's
  # registration while a debug hook is installed on it; the hook holds the
  # lease owner on its grant resolution, past the 300 ms step.
  test "a lease owner overrunning its resolution step is replaced" do
    owner = start_owner(mirror_deadline_ms: 300, fatal_recipient: self())
    components = Owner.components(owner)
    connection = initialized_connection(components)
    connection_pid = connection.pid
    origin = {connection.incarnation, 0, 1}
    {worker, worker_incarnation} = start_worker(connection.pid, origin)
    test_pid = self()

    park_relay_message(
      components.relay,
      &match?(
        {:"$gen_call", _from, {:register_lease_owner, "late-resolution-session", _, _}},
        &1
      ),
      :register_parked,
      :continue_register
    )

    acquire =
      Task.async(fn ->
        acquire_as(
          owner,
          origin,
          "late-resolution",
          "late-resolution-session",
          connection.pid,
          connection.incarnation,
          worker,
          worker_incarnation,
          now_ms() + 5_000
        )
      end)

    assert {:ok, :accepted, lease_owner, _incarnation} = Task.await(acquire, 1_000)
    monitor = Process.monitor(lease_owner)

    :ok =
      :sys.install(
        lease_owner,
        {fn
           :waiting, {:in, {:daemon_lease_resolution, _, _, _, :grant, _}}, _state ->
             send(test_pid, :resolution_held)

             receive do
               :never -> :done
             end

           hook_state, _event, _state ->
             hook_state
         end, :waiting}
      )

    assert_receive :register_parked, 1_000
    send(components.relay, :continue_register)
    assert_receive :resolution_held, 1_000
    assert_receive {:DOWN, ^monitor, :process, ^lease_owner, :killed}, 1_000

    assert_receive {:manual_connection_message, ^connection_pid,
                    {:relay_permit_result, ^origin, %{"result" => %{"writer_epoch" => _}}}},
                   1_000

    refute_received {:daemon_component_fatal, _reporter, _class}
    assert Process.alive?(owner)
    assert Process.alive?(components.registry)
  end

  # Concept (P1, T16): each step of a grant has its own instant, so a
  # selection and a settlement that each take most of their step still
  # complete the grant, although together they outlast any single step.
  #
  # Technical depth: the relay is parked on the grant's result selection and
  # then on its result settlement for 350 ms each, against a 500 ms step.
  test "a grant whose steps each use most of their instant completes" do
    owner = start_owner(mirror_deadline_ms: 500, fatal_recipient: self())
    components = Owner.components(owner)
    connection = initialized_connection(components)
    connection_pid = connection.pid
    origin = {connection.incarnation, 0, 1}
    {worker, worker_incarnation} = start_worker(connection.pid, origin)
    park_relay_operation(components.relay, :select_result)
    park_relay_operation(components.relay, :settle_result)

    acquire =
      Task.async(fn ->
        acquire_as(
          owner,
          origin,
          "slow-steps",
          "slow-steps-session",
          connection.pid,
          connection.incarnation,
          worker,
          worker_incarnation,
          now_ms() + 5_000
        )
      end)

    assert_receive {:relay_operation_parked, :select_result}, 1_000
    Process.sleep(350)
    send(components.relay, :continue_parked_operation)
    assert_receive {:relay_operation_parked, :settle_result}, 1_000
    Process.sleep(350)
    send(components.relay, :continue_parked_operation)
    assert {:ok, :accepted, _lease_owner, _incarnation} = Task.await(acquire, 1_000)

    assert_receive {:manual_connection_message, ^connection_pid,
                    {:relay_permit_result, ^origin, %{"result" => %{"writer_epoch" => _}}}},
                   1_000

    assert %{granted_routes: 1} = wait_for_owner_settlement(owner)
    refute_received {:daemon_component_fatal, _reporter, _class}
  end

  # Concept (T24, R11): when the daemon kills a lease owner whose grant is
  # being resolved, the grant's settlement is requested and acknowledged
  # before the lost owner's mirror pop begins, so the holder's grant precedes
  # its close in causal order.
  #
  # Technical depth: the relay is parked on the fresh lease owner's
  # registration while a debug hook is installed on it; the hook holds the
  # lease owner on its grant resolution, and it is killed there. The relay is
  # then parked on the result settlement request itself, so no pop may be
  # sent while that request is unanswered; once the relay continues, a trace
  # of the daemon owner's sends and receives orders the settlement request,
  # its acknowledgement and the pop's `apply_mirror`.
  test "T24: a lease owner killed in its resolution settles the grant before the pop" do
    owner = start_owner(fatal_recipient: self())
    components = Owner.components(owner)
    connection = initialized_connection(components)
    connection_pid = connection.pid
    session_id = "t24-session"
    origin = {connection.incarnation, 0, 1}
    {worker, worker_incarnation} = start_worker(connection.pid, origin)
    test_pid = self()

    park_relay_message(
      components.relay,
      &match?({:"$gen_call", _from, {:register_lease_owner, ^session_id, _, _}}, &1),
      :register_parked,
      :continue_register
    )

    acquire =
      Task.async(fn ->
        acquire_as(
          owner,
          origin,
          "t24-acquire",
          session_id,
          connection.pid,
          connection.incarnation,
          worker,
          worker_incarnation,
          now_ms() + 5_000
        )
      end)

    assert {:ok, :accepted, lease_owner, _incarnation} = Task.await(acquire, 1_000)

    :ok =
      :sys.install(
        lease_owner,
        {fn
           :waiting, {:in, {:daemon_lease_resolution, _, _, _, :grant, _}}, _state ->
             send(test_pid, :resolution_held)

             receive do
               :never -> :done
             end

           hook_state, _event, _state ->
             hook_state
         end, :waiting}
      )

    assert_receive :register_parked, 1_000
    send(components.relay, :continue_register)
    assert_receive :resolution_held, 1_000

    park_relay_message(
      components.relay,
      &match?({:relay_lease_operation, _, _, _, :settle_result, _}, &1),
      :settle_parked,
      :continue_settle
    )

    :erlang.trace(owner, true, [:send, :receive, {:tracer, test_pid}])
    Process.exit(lease_owner, :kill)
    assert_receive :settle_parked, 1_000
    Process.sleep(200)
    send(components.relay, :continue_settle)

    assert_receive {:manual_connection_message, ^connection_pid,
                    {:daemon_control_owner_lost, ^owner, _close_ref, ^session_id, _incarnation}},
                   2_000

    :erlang.trace(owner, false, [:send, :receive])
    events = collect_trace_events([])

    settle =
      Enum.find_index(events, fn event ->
        match?({:send, {:relay_lease_operation, _, _, _, :settle_result, _}}, event)
      end)

    acknowledged =
      Enum.find_index(events, fn event ->
        match?({:receive, {:relay_lease_operation_ack, _, _, _, :settle_result, _}}, event)
      end)

    pop =
      Enum.find_index(events, fn event ->
        match?({:send, {:apply_mirror, _, _, _, :pop_owner_mirror, _}}, event)
      end)

    assert is_integer(settle) and is_integer(acknowledged) and is_integer(pop)
    assert settle < acknowledged
    assert acknowledged < pop

    assert_receive {:manual_connection_message, ^connection_pid,
                    {:relay_permit_result, ^origin, %{"result" => %{"writer_epoch" => _}}}},
                   1_000
  end

  defp collect_trace_events(events) do
    receive do
      {:trace, _owner, :send, message, _to} -> collect_trace_events([{:send, message} | events])
      {:trace, _owner, :receive, message} -> collect_trace_events([{:receive, message} | events])
    after
      100 -> Enum.reverse(events)
    end
  end

  defp pending_close_state do
    owner = start_owner(fatal_recipient: self())
    tag = make_ref()
    ref = make_ref()
    close = %{ref: ref, froms: [{self(), tag}], timer: make_ref()}
    {%{:sys.get_state(owner) | close: close}, tag, ref}
  end

  defp eventually_true(predicate, attempts \\ 100)
  defp eventually_true(predicate, 0), do: assert(predicate.())

  defp eventually_true(predicate, attempts) do
    if predicate.() do
      :ok
    else
      Process.sleep(10)
      eventually_true(predicate, attempts - 1)
    end
  end

  # A promotion sent to the registry from its own caller process, whose answer
  # (or its call exit) is reported back to the test.
  defp spawn_registry_promotion(registry, origin, mode \\ :historical) do
    test = self()
    command_id = Base.encode16(:crypto.strong_rand_bytes(8))
    digest = :crypto.hash(:sha256, command_id)

    spawn(fn ->
      result =
        registry
        |> ConnectionRegistry.promote_create_request(
          origin,
          command_id,
          digest,
          mode,
          %{"refusal" => "ceiling"},
          %{"refusal" => "conflict"},
          fn -> {:no_activation, nil, %{"result" => "none"}} end
        )
        |> :gen_server.receive_response(5_000)
        |> case do
          {:reply, reply} -> reply
          _no_reply -> :call_exit
        end

      send(test, {:registry_promotion, self(), result})
    end)
  end

  defp registry_flow_state(registry) do
    state = :sys.get_state(registry)

    %{
      relay_flow: state.relay_flow,
      queued: :queue.len(state.relay_flow_queue),
      activation_reservations: map_size(state.activation_reservations)
    }
  end

  defp await_owner_phase(owner, phase, attempts \\ 200)

  defp await_owner_phase(owner, phase, attempts) when attempts > 0 do
    case :sys.get_state(owner) do
      %{stop: %{phase: ^phase}} ->
        :ok

      _other ->
        Process.sleep(5)
        await_owner_phase(owner, phase, attempts - 1)
    end
  end

  defp await_owner_phase(_owner, _phase, 0), do: {:error, :phase_not_reached}

  defp uninitialized_connection(components) do
    assert {:ok, %{rollback_token: token}} =
             ConnectionRegistry.reserve(components.registry, self(), make_ref(), now_ms())

    assert {:ok, pid, incarnation} =
             ConnectionRegistry.start_connection(components.registry, token)

    assert_receive {:manual_connection_started, ^pid, _options}, 500
    assert :ok = ConnectionRegistry.begin_transfer(components.registry, token, incarnation)
    assert :ok = ConnectionRegistry.transfer_result(components.registry, token, incarnation, :ok)
    assert :ok = manual_call(pid, :promote)
    pid
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

  defp wait_for_owner_settlement(owner, attempts \\ 1_000)

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

  defp wait_for_owner_retirement(owner, attempts \\ 1_000)

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

  defp wait_for_transferred_slot(owner, attempts \\ 1_000)

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

  defp wait_for_successor_cancellation(owner, attempts \\ 1_000)

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

  defp wait_for_relay_settling(relay, attempts \\ 1_000)

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

  defp wait_for_relay_pending(relay, attempts \\ 1_000)

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

  defp wait_for_relay_owner_loss(relay, attempts \\ 1_000)

  defp wait_for_relay_owner_loss(relay, attempts) when attempts > 0 do
    status = AdmissionRelay.status(relay)

    if status.owner_losses == 1 do
      status
    else
      Process.sleep(5)
      wait_for_relay_owner_loss(relay, attempts - 1)
    end
  end

  defp wait_for_relay_owner_loss(relay, 0), do: AdmissionRelay.status(relay)

  defp wait_for_mirror_step(owner, kind, step, attempts \\ 1_000)

  defp wait_for_mirror_step(owner, kind, step, attempts) when attempts > 0 do
    state = :sys.get_state(owner)

    if Enum.any?(state.mirror_operations, fn {_operation_ref, operation} ->
         operation.kind == kind and operation.step == step
       end) do
      :ok
    else
      Process.sleep(5)
      wait_for_mirror_step(owner, kind, step, attempts - 1)
    end
  end

  defp wait_for_mirror_step(_owner, _kind, _step, 0), do: {:error, :not_reached}

  # Concept: a connection-loss release whose lease owner has not restored.
  # Technical depth: the release is proposed, its connection is killed before
  # the result CAS, and the lease owner is suspended when the daemon owner
  # asks it to restore; the daemon owner is left at `resolve_owner_cancel`.
  defp park_release_cancellation(owner, components, connection, session_id) do
    {lease_owner, owner_incarnation, writer_epoch} = acquire_held(owner, connection, session_id)
    release_origin = {connection.incarnation, 1, 1}
    {release_worker, release_worker_incarnation} = start_worker(connection.pid, release_origin)
    :sys.suspend(lease_owner)

    release_task =
      Task.async(fn ->
        release_as(
          owner,
          release_origin,
          "#{session_id}-release",
          session_id,
          connection.pid,
          connection.incarnation,
          release_worker,
          release_worker_incarnation,
          writer_epoch,
          now_ms() + 5_000
        )
      end)

    assert %{pending: 1} = wait_for_relay_pending(components.relay)
    suspend_task = Task.async(fn -> :sys.suspend(owner) end)
    :sys.resume(lease_owner)
    assert {:ok, :accepted, ^lease_owner, ^owner_incarnation} = Task.await(release_task, 500)
    assert :ok = Task.await(suspend_task, 500)
    assert_receive {:worker_go, ^release_worker, ^release_origin}, 500
    assert :ok = wait_for_lease_owner(lease_owner, &(&1.phase == :release_pending))
    :sys.suspend(lease_owner)
    Process.exit(connection.pid, :kill)
    assert %{settling: 1} = wait_for_relay_settling(components.relay)
    :sys.resume(owner)
    assert :ok = wait_for_mirror_step(owner, :release, :resolve_owner_cancel)

    [loss_ref] =
      for {_operation_ref, %{kind: :release, loss_ref: loss_ref}} <-
            :sys.get_state(owner).mirror_operations,
          do: loss_ref

    {lease_owner, owner_incarnation, release_origin, loss_ref}
  end

  # Concept: the relay can be held just before it applies an owner-loss
  # classification or the lease freeze. Technical depth: a debug hook parks
  # the relay on the first matching message and returns once released.
  defp park_relay_classification(relay) do
    park_relay_message(
      relay,
      &match?({:relay_owner_loss_classification, _, _, _, _, _, _, _}, &1),
      :relay_classification_parked,
      :continue_parked_classification
    )
  end

  defp park_relay_freeze(relay) do
    park_relay_message(
      relay,
      &match?({:relay_barrier, _ref, {:freeze_lease_ops, _deadline}}, &1),
      :relay_freeze_parked,
      :continue_parked_freeze
    )
  end

  defp park_relay_message(relay, matcher, parked, continue) do
    test_pid = self()

    :ok =
      :sys.install(
        relay,
        {fn
           :waiting, {:in, message}, _proc_state ->
             if matcher.(message) do
               send(test_pid, parked)

               receive do
                 ^continue -> :done
               end
             else
               :waiting
             end

           :waiting, _event, _proc_state ->
             :waiting
         end, :waiting}
      )
  end

  defp freeze(owner, window \\ 5_000) do
    deadline = now_ms() + window
    Owner.barrier(owner, {:freeze_lease_ops, deadline}, deadline)
  end

  defp owner_loss_operations(owner) do
    for {_operation_ref, %{kind: :owner_loss} = operation} <-
          :sys.get_state(owner).mirror_operations,
        do: operation
  end

  defp wait_for_stop(owner, attempts \\ 100)

  defp wait_for_stop(owner, attempts) when attempts > 0 do
    if :sys.get_state(owner).stop do
      :ok
    else
      Process.sleep(5)
      wait_for_stop(owner, attempts - 1)
    end
  end

  defp wait_for_stop(_owner, 0), do: {:error, :not_stopping}

  defp wait_for_owner_loss_step(owner, step, count, attempts \\ 2_000)

  defp wait_for_owner_loss_step(owner, step, count, attempts) when attempts > 0 do
    if Enum.count(owner_loss_operations(owner), &(&1.step == step)) == count do
      :ok
    else
      Process.sleep(5)
      wait_for_owner_loss_step(owner, step, count, attempts - 1)
    end
  end

  defp wait_for_owner_loss_step(_owner, _step, _count, 0), do: {:error, :not_reached}

  defp wait_for_queue_length(pid, length, attempts \\ 100)

  defp wait_for_queue_length(pid, length, attempts) when attempts > 0 do
    case Process.info(pid, :message_queue_len) do
      {:message_queue_len, queued} when queued >= length ->
        :ok

      _other ->
        Process.sleep(5)
        wait_for_queue_length(pid, length, attempts - 1)
    end
  end

  defp wait_for_queue_length(_pid, _length, 0), do: {:error, :not_queued}
  # Technical depth: the connection's answer is its acceptance, so a test
  # that needs the lease owner's later step waits for its status.
  defp wait_for_lease_owner(lease_owner, predicate, attempts \\ 200)

  defp wait_for_lease_owner(lease_owner, predicate, attempts) when attempts > 0 do
    if predicate.(LeaseOwner.status(lease_owner)) do
      :ok
    else
      Process.sleep(5)
      wait_for_lease_owner(lease_owner, predicate, attempts - 1)
    end
  end

  defp wait_for_lease_owner(_lease_owner, _predicate, 0), do: {:error, :not_reached}

  defp wait_for_attachment(lease_owner, attempts \\ 100)

  defp wait_for_attachment(lease_owner, attempts) when attempts > 0 do
    if LeaseOwner.status(lease_owner).attachments == 1 do
      :ok
    else
      Process.sleep(5)
      wait_for_attachment(lease_owner, attempts - 1)
    end
  end

  defp wait_for_attachment(_lease_owner, 0), do: {:error, :not_attached}

  defp start_ticket_worker(connection) do
    parent = self()

    worker =
      spawn(fn ->
        connection_monitor = Process.monitor(connection)
        send(parent, {:ticket_worker_ready, self()})

        receive do
          {:DOWN, ^connection_monitor, :process, ^connection, _reason} -> :ok
        end
      end)

    assert_receive {:ticket_worker_ready, ^worker}, 500
    worker
  end

  # Concept: a claimed acquire queued inside an existing owner with no
  # proposal. Technical depth: the former holder's 40 ms lease expires while
  # the registry is suspended, so its expiry clear waits and the successor's
  # acquire, with a 300 ms request deadline, queues behind it; the registry
  # is left suspended.
  defp queue_successor_behind_expiry(owner, components, former, successor, session_id) do
    former_origin = {former.incarnation, 0, 1}
    {former_worker, former_worker_incarnation} = start_worker(former.pid, former_origin)

    assert {:ok, :accepted, lease_owner, owner_incarnation} =
             acquire_as(
               owner,
               former_origin,
               "#{session_id}-former",
               session_id,
               former.pid,
               former.incarnation,
               former_worker,
               former_worker_incarnation,
               now_ms() + 2_000
             )

    assert_receive {:manual_connection_message, _former,
                    {:relay_permit_result, ^former_origin, _former_result}},
                   500

    :sys.suspend(components.registry)
    assert :ok = wait_for_mirror_step(owner, :expiry, :clear)
    successor_origin = {successor.incarnation, 0, 1}

    {successor_worker, successor_worker_incarnation} =
      start_worker(successor.pid, successor_origin)

    assert {:ok, :accepted, ^lease_owner, ^owner_incarnation} =
             acquire_as(
               owner,
               successor_origin,
               "#{session_id}-successor",
               session_id,
               successor.pid,
               successor.incarnation,
               successor_worker,
               successor_worker_incarnation,
               now_ms() + 300
             )

    assert_receive {:worker_go, ^successor_worker, ^successor_origin}, 500
    {lease_owner, owner_incarnation, successor_origin}
  end

  # Technical depth: the relay is parked on the renewal's `action` call while
  # the holder is killed, so its `DOWN` is queued ahead of the next call.
  defp assert_disconnected_renewal_settles(action) do
    owner = start_owner()
    components = Owner.components(owner)
    holder = initialized_connection(components)
    session_id = "disconnected-#{action}"
    {_lease_owner, _owner_incarnation, _epoch} = acquire_held(owner, holder, session_id)
    origin = {holder.incarnation, 1, 1}
    {worker, worker_incarnation} = start_detached_worker(origin)

    park_relay_message(
      components.relay,
      fn
        {:"$gen_call", _from, request} when is_tuple(request) ->
          elem(request, 0) == action and Enum.member?(Tuple.to_list(request), origin)

        _other ->
          false
      end,
      :renewal_parked,
      :continue_renewal
    )

    renewal =
      Task.async(fn ->
        acquire_as(
          owner,
          origin,
          "#{session_id}-renewal",
          session_id,
          holder.pid,
          holder.incarnation,
          worker,
          worker_incarnation,
          now_ms() + 2_000
        )
      end)

    assert_receive :renewal_parked, 500
    holder_monitor = Process.monitor(holder.pid)
    Process.exit(holder.pid, :kill)
    assert_receive {:DOWN, ^holder_monitor, :process, _holder, :killed}, 500
    owner_monitor = Process.monitor(owner)
    send(components.relay, :continue_renewal)

    # The acceptance precedes the loss; the relay's disposition settles the
    # operation it kept.
    # The holder's connection is gone, so the acceptance, if any, reaches no
    # one; the relay's disposition settles the operation.
    case Task.yield(renewal, 1_000) || Task.shutdown(renewal, :brutal_kill) do
      nil -> :ok
      {:ok, reply} -> assert {:ok, :accepted, _lease_owner, _owner_incarnation} = reply
    end

    assert %{lease_operations: 0, pending_dispositions: 0, mirror_operations: 0} =
             wait_for_owner_settlement(owner)

    refute_received {:DOWN, ^owner_monitor, :process, _owner, _reason}
    assert Process.alive?(owner)
    assert %{permits: 0} = AdmissionRelay.status(components.relay)
  end

  defp wait_for_freeze_descriptors(owner, attempts \\ 200)

  defp wait_for_freeze_descriptors(owner, attempts) when attempts > 0 do
    if match?(%{stop: %{barrier: %{descriptors: [_ | _]}}}, :sys.get_state(owner)) or
         match?(%{stop: %{barrier: %{descriptors: []}}}, :sys.get_state(owner)) do
      :ok
    else
      Process.sleep(5)
      wait_for_freeze_descriptors(owner, attempts - 1)
    end
  end

  defp wait_for_freeze_descriptors(_owner, 0), do: {:error, :not_frozen}

  defp wait_for_pending_dispositions(owner, count, attempts \\ 200)

  defp wait_for_pending_dispositions(owner, count, attempts) when attempts > 0 do
    if Owner.status(owner).pending_dispositions == count do
      :ok
    else
      Process.sleep(5)
      wait_for_pending_dispositions(owner, count, attempts - 1)
    end
  end

  defp wait_for_pending_dispositions(_owner, _count, 0), do: {:error, :not_retained}

  defp wait_for_status(owner, predicate, attempts \\ 400)

  defp wait_for_status(owner, predicate, attempts) when attempts > 0 do
    if predicate.(Owner.status(owner)) do
      :ok
    else
      Process.sleep(5)
      wait_for_status(owner, predicate, attempts - 1)
    end
  end

  defp wait_for_status(_owner, _predicate, 0), do: {:error, :not_reached}

  # Technical depth: a request worker that outlives its connection, so the
  # relay's claim can still dispatch after the connection's loss is queued.
  defp start_detached_worker(origin) do
    parent = self()
    worker_incarnation = incarnation()

    worker =
      spawn(fn ->
        receive do
          {:relay_go, ^origin, ^worker_incarnation} -> send(parent, {:worker_go, self(), origin})
        end
      end)

    {worker, worker_incarnation}
  end

  defp incarnation, do: :crypto.strong_rand_bytes(16)
  defp now_ms, do: System.monotonic_time(:millisecond)
end
