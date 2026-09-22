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

    assert {:ok, :proposed, predecessor, predecessor_incarnation} =
             Owner.acquire_control(
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

    assert {:ok, :queued, ^owner, _daemon_incarnation} =
             Owner.acquire_control(
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

    assert {:ok, :proposed, lease_owner, owner_incarnation} =
             Owner.acquire_control(
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
        Owner.release_control(
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

    assert {:ok, :proposed, ^lease_owner, ^owner_incarnation} = Task.await(release_task, 500)
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

    assert {:ok, :proposed, lease_owner, owner_incarnation} =
             Owner.acquire_control(
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

    assert {:ok, :proposed, ^lease_owner, ^owner_incarnation} =
             Owner.release_control(
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

    assert {:ok, :proposed, lease_owner, _owner_incarnation} =
             Owner.acquire_control(
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
    owner = start_owner(lease_term_ms: 40, mirror_deadline_ms: 1_000)
    components = Owner.components(owner)
    former = initialized_connection(components)
    successor = initialized_connection(components)
    former_pid = former.pid
    successor_pid = successor.pid
    former_origin = {former.incarnation, 0, 1}
    {former_worker, former_worker_incarnation} = start_worker(former.pid, former_origin)

    assert {:ok, :proposed, lease_owner, owner_incarnation} =
             Owner.acquire_control(
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

    assert {:ok, :queued, ^lease_owner, ^owner_incarnation} =
             Owner.acquire_control(
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
                   500

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

    assert {:ok, :proposed, lease_owner, _owner_incarnation} =
             Owner.acquire_control(
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
        Owner.acquire_control(
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
    assert :ok = wait_for_queued_message(child)
    :sys.resume(child)
    :sys.suspend(child)

    child_monitor = Process.monitor(child)
    Process.exit(child, :kill)
    assert_receive {:DOWN, ^child_monitor, :process, ^child, :killed}, 500
    assert {:ok, :queued, ^child, _owner_incarnation} = Task.await(acquire, 1_000)
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

  test "an expiry mirror selected before owner loss clears without closing the former holder" do
    owner = start_owner(lease_term_ms: 40, mirror_deadline_ms: 1_000)
    components = Owner.components(owner)
    holder = initialized_connection(components)
    origin = {holder.incarnation, 0, 1}
    {worker, worker_incarnation} = start_worker(holder.pid, origin)

    assert {:ok, :proposed, lease_owner, _owner_incarnation} =
             Owner.acquire_control(
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

  defp wait_for_relay_owner_loss(relay, attempts \\ 20)

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

  defp wait_for_mirror_step(owner, kind, step, attempts \\ 100)

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

  defp wait_for_queued_message(pid, attempts \\ 100)

  defp wait_for_queued_message(pid, attempts) when attempts > 0 do
    case Process.info(pid, :message_queue_len) do
      {:message_queue_len, length} when length > 0 ->
        :ok

      _other ->
        Process.sleep(5)
        wait_for_queued_message(pid, attempts - 1)
    end
  end

  defp wait_for_queued_message(_pid, 0), do: {:error, :not_queued}

  defp incarnation, do: :crypto.strong_rand_bytes(16)
  defp now_ms, do: System.monotonic_time(:millisecond)
end
