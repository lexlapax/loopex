defmodule LoopexDaemon.LeaseOwnerTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias LoopexDaemon.{AdmissionRelay, LeaseOwner, WireRecords}
  alias LoopexProtocol.Wire

  test "a first acquisition stays provisional until daemon settlement" do
    fixture = start_fixture()
    connection_incarnation = incarnation()
    connection = start_connection(fixture.relay, connection_incarnation)
    origin = {connection_incarnation, 0, 1}
    start_op_ref = make_ref()
    {worker, worker_incarnation} = start_worker(connection, origin)
    worker_monitor = Process.monitor(worker)

    assert {:ok, ^origin} =
             AdmissionRelay.open_lease_permit(
               fixture.relay,
               connection,
               origin,
               :session_acquire_control,
               fixture.session_id,
               self(),
               fixture.daemon_incarnation,
               worker,
               worker_incarnation,
               start_op_ref
             )

    assert :ok =
             AdmissionRelay.claim_lease_permit(
               fixture.relay,
               origin,
               fixture.daemon_incarnation,
               start_op_ref
             )

    assert_receive {:lease_request_go, ^worker, ^origin}, 500
    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, :normal}, 500

    request_deadline = now_ms() + 1_000

    assert {:ok, :proposed} =
             LeaseOwner.first_acquire(
               fixture.owner,
               origin,
               "acquire-1",
               connection,
               connection_incarnation,
               request_deadline
             )

    assert %{phase: :grant_pending, held: false} = LeaseOwner.status(fixture.owner)

    assert_receive {:lease_grant_proposed, grant_ref, ^origin, owner, owner_incarnation,
                    session_id, ^connection, ^connection_incarnation, writer_epoch,
                    ^request_deadline},
                   500

    assert owner == fixture.owner
    assert owner_incarnation == fixture.owner_incarnation
    assert session_id == fixture.session_id
    assert byte_size(writer_epoch) == 16

    settlement_ref = make_ref()
    result = WireRecords.control_acquired("acquire-1", writer_epoch, 30_000, false)

    assert :ok =
             AdmissionRelay.select_lease_result(
               fixture.relay,
               origin,
               self(),
               fixture.daemon_incarnation,
               settlement_ref,
               result
             )

    assert :ok = LeaseOwner.resolve_grant(fixture.owner, grant_ref, :granted, now_ms())
    assert %{phase: :held, held: true} = LeaseOwner.status(fixture.owner)
    assert :ok = AdmissionRelay.settle_lease_result(fixture.relay, origin, settlement_ref)

    assert_receive {:connection_message, ^connection, {:relay_permit_result, ^origin, ^result}},
                   500

    stop_connection(connection, fixture.relay, connection_incarnation)
    assert %{phase: :held, held: true} = LeaseOwner.status(fixture.owner)
  end

  test "the holder renews one epoch and another connection learns no epoch" do
    fixture = start_fixture()
    {holder, holder_incarnation, writer_epoch} = grant_first(fixture)

    renewal_origin = {holder_incarnation, 1, 1}
    {renewal_worker, renewal_worker_incarnation} = start_worker(holder, renewal_origin)

    assert {:ok, ^renewal_origin} =
             open_existing_acquire(
               fixture,
               holder,
               holder_incarnation,
               renewal_origin,
               renewal_worker,
               renewal_worker_incarnation
             )

    assert {:ok, :completed} =
             LeaseOwner.acquire(
               fixture.owner,
               renewal_origin,
               "renew-1",
               holder,
               holder_incarnation,
               now_ms() + 1_000
             )

    assert_receive {:lease_request_go, ^renewal_worker, ^renewal_origin}, 500

    assert_receive {:connection_message, ^holder,
                    {:relay_permit_result, ^renewal_origin, renewal}},
                   500

    assert renewal["result"]["writer_epoch"] == Wire.encode_identity(writer_epoch)
    assert renewal["result"]["renewed"] == true

    observer_incarnation = incarnation()
    observer = start_connection(fixture.relay, observer_incarnation)
    observer_origin = {observer_incarnation, 0, 1}
    {observer_worker, observer_worker_incarnation} = start_worker(observer, observer_origin)

    assert {:ok, ^observer_origin} =
             open_existing_acquire(
               fixture,
               observer,
               observer_incarnation,
               observer_origin,
               observer_worker,
               observer_worker_incarnation
             )

    assert {:ok, :completed} =
             LeaseOwner.acquire(
               fixture.owner,
               observer_origin,
               "observer-1",
               observer,
               observer_incarnation,
               now_ms() + 1_000
             )

    assert_receive {:connection_message, ^observer,
                    {:relay_permit_result, ^observer_origin, refused}},
                   500

    assert refused == WireRecords.control_error("observer-1", "control_held")
    refute inspect(refused) =~ Wire.encode_identity(writer_epoch)

    stop_connection(observer, fixture.relay, observer_incarnation)
    stop_connection(holder, fixture.relay, holder_incarnation)
  end

  test "expiry clears the old route before queued takeover mints a fresh epoch" do
    fixture = start_fixture(lease_term_ms: 60)
    {holder, holder_incarnation, first_epoch} = grant_first(fixture, 60)

    assert_receive {:lease_expiry_proposed, expiry_ref, owner, owner_incarnation, session_id,
                    ^holder, ^holder_incarnation, ^first_epoch},
                   500

    assert owner == fixture.owner
    assert owner_incarnation == fixture.owner_incarnation
    assert session_id == fixture.session_id
    assert %{phase: :expiry_pending, held: true} = LeaseOwner.status(fixture.owner)

    successor_incarnation = incarnation()
    successor = start_connection(fixture.relay, successor_incarnation)
    successor_origin = {successor_incarnation, 0, 1}
    {worker, worker_incarnation} = start_worker(successor, successor_origin)

    assert {:ok, ^successor_origin} =
             open_existing_acquire(
               fixture,
               successor,
               successor_incarnation,
               successor_origin,
               worker,
               worker_incarnation
             )

    request_deadline = now_ms() + 1_000

    assert {:ok, :queued} =
             LeaseOwner.acquire(
               fixture.owner,
               successor_origin,
               "takeover-1",
               successor,
               successor_incarnation,
               request_deadline
             )

    assert %{waiting_acquires: 1, phase: :expiry_pending} = LeaseOwner.status(fixture.owner)
    assert :ok = LeaseOwner.resolve_expiry(fixture.owner, expiry_ref)

    assert_receive {:lease_grant_proposed, grant_ref, ^successor_origin, ^owner,
                    ^owner_incarnation, ^session_id, ^successor, ^successor_incarnation,
                    second_epoch, ^request_deadline},
                   500

    refute second_epoch == first_epoch

    settlement_ref = make_ref()
    result = WireRecords.control_acquired("takeover-1", second_epoch, 60, false)

    assert :ok =
             AdmissionRelay.select_lease_result(
               fixture.relay,
               successor_origin,
               fixture.owner,
               fixture.owner_incarnation,
               settlement_ref,
               result
             )

    assert :ok = LeaseOwner.resolve_grant(fixture.owner, grant_ref, :granted, now_ms())

    assert :ok =
             AdmissionRelay.settle_lease_result(fixture.relay, successor_origin, settlement_ref)

    assert_receive {:connection_message, ^successor,
                    {:relay_permit_result, ^successor_origin, ^result}},
                   500

    stop_connection(successor, fixture.relay, successor_incarnation)
    stop_connection(holder, fixture.relay, holder_incarnation)
  end

  test "release stays held until result settlement and connection loss restores it" do
    fixture = start_fixture(lease_term_ms: 1_000)
    {holder, holder_incarnation, writer_epoch} = grant_first(fixture, 1_000)
    release_origin = {holder_incarnation, 1, 1}
    {worker, worker_incarnation} = start_worker(holder, release_origin)
    worker_monitor = Process.monitor(worker)

    assert {:ok, ^release_origin} =
             open_release(
               fixture,
               holder,
               holder_incarnation,
               release_origin,
               worker,
               worker_incarnation
             )

    assert {:ok, :proposed} =
             LeaseOwner.release(
               fixture.owner,
               release_origin,
               "release-1",
               holder,
               holder_incarnation,
               writer_epoch
             )

    assert_receive {:release_proposed, release_ref, ^release_origin, owner, owner_incarnation,
                    ^holder_incarnation},
                   500

    assert owner == fixture.owner
    assert owner_incarnation == fixture.owner_incarnation
    assert %{phase: :release_pending, held: true} = LeaseOwner.status(fixture.owner)
    assert_receive {:lease_request_go, ^worker, ^release_origin}, 500
    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, :normal}, 500

    holder_monitor = Process.monitor(holder)
    Process.exit(holder, :kill)
    assert_receive {:DOWN, ^holder_monitor, :process, ^holder, :killed}, 500

    assert_receive {:relay_lease_disposition, relay, ^release_origin, :connection_lost,
                    settlement_ref, :session_release_control, session_id, ^owner,
                    ^owner_incarnation, nil},
                   500

    assert relay == fixture.relay
    assert session_id == fixture.session_id

    assert :ok = LeaseOwner.resolve_release(fixture.owner, release_ref, :cancelled)
    assert %{phase: :held, held: true} = LeaseOwner.status(fixture.owner)

    assert :ok =
             AdmissionRelay.settle_lease_disposition(
               fixture.relay,
               release_origin,
               :connection_lost,
               settlement_ref
             )

    assert_receive {:relay_connection_retired, ^relay, ^holder_incarnation}, 500
  end

  test "successful explicit release clears control and wrong epochs are indistinguishable" do
    fixture = start_fixture()
    {holder, holder_incarnation, writer_epoch} = grant_first(fixture)

    refused_origin = {holder_incarnation, 1, 1}
    {refused_worker, refused_worker_incarnation} = start_worker(holder, refused_origin)

    assert {:ok, ^refused_origin} =
             open_release(
               fixture,
               holder,
               holder_incarnation,
               refused_origin,
               refused_worker,
               refused_worker_incarnation
             )

    assert {:ok, :completed} =
             LeaseOwner.release(
               fixture.owner,
               refused_origin,
               "release-refused",
               holder,
               holder_incarnation,
               :crypto.strong_rand_bytes(16)
             )

    assert_receive {:connection_message, ^holder,
                    {:relay_permit_result, ^refused_origin, refused}},
                   500

    assert refused == WireRecords.control_error("release-refused", "control_not_held")

    release_origin = {holder_incarnation, 2, 1}
    {worker, worker_incarnation} = start_worker(holder, release_origin)
    worker_monitor = Process.monitor(worker)

    assert {:ok, ^release_origin} =
             open_release(
               fixture,
               holder,
               holder_incarnation,
               release_origin,
               worker,
               worker_incarnation
             )

    assert {:ok, :proposed} =
             LeaseOwner.release(
               fixture.owner,
               release_origin,
               "release-ok",
               holder,
               holder_incarnation,
               writer_epoch
             )

    assert_receive {:release_proposed, release_ref, ^release_origin, _, _, _}, 500
    assert_receive {:lease_request_go, ^worker, ^release_origin}, 500
    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, :normal}, 500

    result = WireRecords.control_released("release-ok")
    settlement_ref = make_ref()

    assert :ok =
             AdmissionRelay.select_lease_result(
               fixture.relay,
               release_origin,
               fixture.owner,
               fixture.owner_incarnation,
               settlement_ref,
               result
             )

    assert :ok = AdmissionRelay.settle_lease_result(fixture.relay, release_origin, settlement_ref)
    assert :ok = LeaseOwner.resolve_release(fixture.owner, release_ref, :released)
    assert %{phase: :released, held: false} = LeaseOwner.status(fixture.owner)

    assert_receive {:connection_message, ^holder,
                    {:relay_permit_result, ^release_origin, ^result}},
                   500

    stop_connection(holder, fixture.relay, holder_incarnation)
  end

  test "attachment accounting and diagnostics reveal only bounded counts" do
    session_canary = "session-canary-lease-owner-58dd"
    fixture = start_fixture(session_id: session_canary)
    connection = spawn(fn -> Process.sleep(:infinity) end)
    connection_incarnation = incarnation()

    log =
      capture_log(fn ->
        assert :ok =
                 LeaseOwner.attachment_opened(
                   fixture.owner,
                   connection,
                   connection_incarnation,
                   "attachment-canary"
                 )

        assert %{attachments: 1, phase: :free} = LeaseOwner.status(fixture.owner)

        assert :ok =
                 LeaseOwner.attachment_closed(
                   fixture.owner,
                   connection,
                   connection_incarnation,
                   "attachment-canary"
                 )
      end)

    refute log =~ session_canary
    refute log =~ "attachment-canary"
    refute inspect(:sys.get_status(fixture.owner)) =~ session_canary
    refute inspect(:sys.get_status(fixture.owner)) =~ "attachment-canary"
    Process.exit(connection, :kill)
  end

  defp start_fixture(options \\ []) do
    daemon_incarnation = incarnation()
    session_id = Keyword.get(options, :session_id, "session")

    relay =
      start_supervised!(
        {AdmissionRelay,
         owner: self(), owner_incarnation: daemon_incarnation, admission_wait_ms: 1_000}
      )

    owner_incarnation = incarnation()

    owner =
      start_supervised!(
        {LeaseOwner,
         daemon_owner: self(),
         relay: relay,
         session_id: session_id,
         owner_incarnation: owner_incarnation,
         lease_term_ms: Keyword.get(options, :lease_term_ms, 30_000)}
      )

    assert :ok =
             AdmissionRelay.register_lease_owner(
               relay,
               session_id,
               owner,
               owner_incarnation
             )

    assert :ok = LeaseOwner.activate(owner)

    %{
      relay: relay,
      owner: owner,
      daemon_incarnation: daemon_incarnation,
      owner_incarnation: owner_incarnation,
      session_id: session_id
    }
  end

  defp grant_first(fixture, lease_term_ms \\ 30_000) do
    connection_incarnation = incarnation()
    connection = start_connection(fixture.relay, connection_incarnation)
    origin = {connection_incarnation, 0, 1}
    start_op_ref = make_ref()
    {worker, worker_incarnation} = start_worker(connection, origin)
    worker_monitor = Process.monitor(worker)

    assert {:ok, ^origin} =
             AdmissionRelay.open_lease_permit(
               fixture.relay,
               connection,
               origin,
               :session_acquire_control,
               fixture.session_id,
               self(),
               fixture.daemon_incarnation,
               worker,
               worker_incarnation,
               start_op_ref
             )

    assert :ok =
             AdmissionRelay.claim_lease_permit(
               fixture.relay,
               origin,
               fixture.daemon_incarnation,
               start_op_ref
             )

    assert_receive {:lease_request_go, ^worker, ^origin}, 500
    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, :normal}, 500
    request_deadline = now_ms() + 1_000

    assert {:ok, :proposed} =
             LeaseOwner.first_acquire(
               fixture.owner,
               origin,
               "first-acquire",
               connection,
               connection_incarnation,
               request_deadline
             )

    assert_receive {:lease_grant_proposed, grant_ref, ^origin, _, _, _, ^connection,
                    ^connection_incarnation, writer_epoch, ^request_deadline},
                   500

    result =
      WireRecords.control_acquired(
        "first-acquire",
        writer_epoch,
        lease_term_ms,
        false
      )

    settlement_ref = make_ref()

    assert :ok =
             AdmissionRelay.select_lease_result(
               fixture.relay,
               origin,
               self(),
               fixture.daemon_incarnation,
               settlement_ref,
               result
             )

    assert :ok = LeaseOwner.resolve_grant(fixture.owner, grant_ref, :granted, now_ms())
    assert :ok = AdmissionRelay.settle_lease_result(fixture.relay, origin, settlement_ref)

    assert_receive {:connection_message, ^connection, {:relay_permit_result, ^origin, ^result}},
                   500

    {connection, connection_incarnation, writer_epoch}
  end

  defp open_existing_acquire(
         fixture,
         connection,
         _connection_incarnation,
         origin,
         worker,
         worker_incarnation
       ) do
    AdmissionRelay.open_lease_permit(
      fixture.relay,
      connection,
      origin,
      :session_acquire_control,
      fixture.session_id,
      fixture.owner,
      fixture.owner_incarnation,
      worker,
      worker_incarnation
    )
  end

  defp open_release(
         fixture,
         connection,
         _connection_incarnation,
         origin,
         worker,
         worker_incarnation
       ) do
    AdmissionRelay.open_lease_permit(
      fixture.relay,
      connection,
      origin,
      :session_release_control,
      fixture.session_id,
      fixture.owner,
      fixture.owner_incarnation,
      worker,
      worker_incarnation
    )
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
      message ->
        send(parent, {:connection_message, self(), message})
        connection_loop(parent)
    end
  end

  defp start_worker(connection, origin) do
    parent = self()
    worker_incarnation = incarnation()

    worker =
      spawn(fn ->
        connection_monitor = Process.monitor(connection)
        send(parent, {:lease_request_ready, self()})

        receive do
          {:relay_go, ^origin, ^worker_incarnation} ->
            send(parent, {:lease_request_go, self(), origin})

          {:DOWN, ^connection_monitor, :process, ^connection, _reason} ->
            :ok
        end
      end)

    assert_receive {:lease_request_ready, ^worker}, 500
    {worker, worker_incarnation}
  end

  defp stop_connection(connection, relay, incarnation) do
    monitor = Process.monitor(connection)
    Process.exit(connection, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^connection, :killed}, 500
    assert_receive {:relay_connection_retired, ^relay, ^incarnation}, 500
  end

  defp incarnation, do: :crypto.strong_rand_bytes(16)
  defp now_ms, do: System.monotonic_time(:millisecond)
end
