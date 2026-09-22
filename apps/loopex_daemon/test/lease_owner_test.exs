defmodule LoopexDaemon.LeaseOwnerTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias LoopexDaemon.{AdmissionRelay, ConnectionRegistry, LeaseOwner, WireRecords}
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

  test "the mutation gate refuses a missing attachment before core work" do
    fixture = start_fixture()
    {holder, holder_incarnation, writer_epoch} = grant_first(fixture)
    origin = {holder_incarnation, 1, 1}
    worker = start_ticket_worker(holder)
    worker_monitor = Process.monitor(worker)

    assert {:ok, ^origin} =
             open_mutation(fixture, holder, origin, :session_prompt, worker)

    parent = self()

    assert {:ok, :admitted} =
             invoke(holder, fn ->
               LeaseOwner.mutate(
                 fixture.owner,
                 origin,
                 :session_prompt,
                 "mutation-no-attachment",
                 holder_incarnation,
                 writer_epoch,
                 worker,
                 fn ->
                   send(parent, :unexpected_mutation_call)
                   {:accepted, %{"unexpected" => true}}
                 end
               )
             end)

    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, :killed}, 500

    refused = WireRecords.control_error("mutation-no-attachment", "control_not_held")

    assert_receive {:connection_message, ^holder, {:relay_ticket_result, ^origin, ^refused}},
                   500

    refute_receive :unexpected_mutation_call, 40
    eventually(fn -> LeaseOwner.status(fixture.owner).in_flight == 0 end)
    stop_connection(holder, fixture.relay, holder_incarnation)
  end

  test "holder identity, epoch and held-state failures use one refusal shape" do
    fixture = start_fixture()
    {holder, holder_incarnation, writer_epoch} = grant_first(fixture)

    assert :ok =
             LeaseOwner.attachment_opened(
               fixture.owner,
               holder,
               holder_incarnation,
               "holder-attachment"
             )

    assert_mutation_refused(
      fixture,
      holder,
      holder_incarnation,
      {holder_incarnation, 1, 1},
      :crypto.strong_rand_bytes(16),
      "wrong-epoch"
    )

    observer_incarnation = incarnation()
    observer = start_connection(fixture.relay, observer_incarnation)

    assert :ok =
             LeaseOwner.attachment_opened(
               fixture.owner,
               observer,
               observer_incarnation,
               "observer-attachment"
             )

    assert_mutation_refused(
      fixture,
      observer,
      observer_incarnation,
      {observer_incarnation, 0, 1},
      writer_epoch,
      "wrong-holder"
    )

    assert :ok =
             LeaseOwner.attachment_closed(
               fixture.owner,
               observer,
               observer_incarnation,
               "observer-attachment"
             )

    stop_connection(observer, fixture.relay, observer_incarnation)
    release_origin = {holder_incarnation, 2, 1}
    {release_worker, release_worker_incarnation} = start_worker(holder, release_origin)

    assert {:ok, ^release_origin} =
             open_release(
               fixture,
               holder,
               holder_incarnation,
               release_origin,
               release_worker,
               release_worker_incarnation
             )

    assert {:ok, :proposed} =
             LeaseOwner.release(
               fixture.owner,
               release_origin,
               "release-before-refusal",
               holder,
               holder_incarnation,
               writer_epoch
             )

    assert_receive {:release_proposed, release_ref, ^release_origin, _, _, _}, 500
    release_result = WireRecords.control_released("release-before-refusal")
    settlement_ref = make_ref()

    assert :ok =
             AdmissionRelay.select_lease_result(
               fixture.relay,
               release_origin,
               fixture.owner,
               fixture.owner_incarnation,
               settlement_ref,
               release_result
             )

    assert :ok =
             AdmissionRelay.settle_lease_result(
               fixture.relay,
               release_origin,
               settlement_ref
             )

    assert :ok = LeaseOwner.resolve_release(fixture.owner, release_ref, :released)

    assert_receive {:connection_message, ^holder,
                    {:relay_permit_result, ^release_origin, ^release_result}},
                   500

    assert_mutation_refused(
      fixture,
      holder,
      holder_incarnation,
      {holder_incarnation, 3, 1},
      writer_epoch,
      "not-held"
    )

    stop_connection(holder, fixture.relay, holder_incarnation)
  end

  test "an expired lease refuses a mutation before core work" do
    fixture = start_fixture(lease_term_ms: 60)
    {holder, holder_incarnation, writer_epoch} = grant_first(fixture, 60)

    assert :ok =
             LeaseOwner.attachment_opened(
               fixture.owner,
               holder,
               holder_incarnation,
               "expired-lease-attachment"
             )

    assert_receive {:lease_expiry_proposed, expiry_ref, _, _, _, ^holder, ^holder_incarnation,
                    ^writer_epoch},
                   500

    assert_mutation_refused(
      fixture,
      holder,
      holder_incarnation,
      {holder_incarnation, 1, 1},
      writer_epoch,
      "expired-lease"
    )

    assert :ok = LeaseOwner.resolve_expiry(fixture.owner, expiry_ref)
    stop_connection(holder, fixture.relay, holder_incarnation)
  end

  test "an accepted mutation renews before a queued takeover can pass" do
    lease_term_ms = 300
    fixture = start_fixture(lease_term_ms: lease_term_ms)
    {holder, holder_incarnation, writer_epoch} = grant_first(fixture, lease_term_ms)

    assert :ok =
             LeaseOwner.attachment_opened(
               fixture.owner,
               holder,
               holder_incarnation,
               "controller-attachment"
             )

    Process.sleep(150)
    origin = {holder_incarnation, 1, 1}
    worker = start_ticket_worker(holder)

    assert {:ok, ^origin} =
             open_mutation(fixture, holder, origin, :session_prompt, worker)

    parent = self()
    result = %{"operation" => "prompt", "status" => "accepted"}

    assert {:ok, :admitted} =
             invoke(holder, fn ->
               LeaseOwner.mutate(
                 fixture.owner,
                 origin,
                 :session_prompt,
                 "mutation-renewal",
                 holder_incarnation,
                 writer_epoch,
                 worker,
                 fn ->
                   send(parent, {:mutation_waiting, self()})

                   receive do
                     :complete -> {:accepted, result}
                   end
                 end
               )
             end)

    assert_receive {:mutation_waiting, task}, 500
    assert %{in_flight: 1, phase: :held} = LeaseOwner.status(fixture.owner)
    Process.sleep(180)
    refute_receive {:lease_expiry_proposed, _, _, _, _, _, _, _}, 40

    successor_incarnation = incarnation()
    successor = start_connection(fixture.relay, successor_incarnation)
    successor_origin = {successor_incarnation, 0, 1}
    {acquire_worker, acquire_worker_incarnation} = start_worker(successor, successor_origin)

    assert {:ok, ^successor_origin} =
             open_existing_acquire(
               fixture,
               successor,
               successor_incarnation,
               successor_origin,
               acquire_worker,
               acquire_worker_incarnation
             )

    assert {:ok, :queued} =
             LeaseOwner.acquire(
               fixture.owner,
               successor_origin,
               "takeover-after-mutation",
               successor,
               successor_incarnation,
               now_ms() + 1_000
             )

    send(task, :complete)

    assert_receive {:connection_message, ^holder, {:relay_ticket_result, ^origin, ^result}}, 500

    refused = WireRecords.control_error("takeover-after-mutation", "control_held")

    assert_receive {:connection_message, ^successor,
                    {:relay_permit_result, ^successor_origin, ^refused}},
                   500

    assert %{in_flight: 0, phase: :held} = LeaseOwner.status(fixture.owner)
    stop_connection(successor, fixture.relay, successor_incarnation)
    stop_connection(holder, fixture.relay, holder_incarnation)
  end

  test "an admission-unknown mutation commits its candidate renewal" do
    lease_term_ms = 400
    fixture = start_fixture(lease_term_ms: lease_term_ms)
    {holder, holder_incarnation, writer_epoch} = grant_first(fixture, lease_term_ms)

    assert :ok =
             LeaseOwner.attachment_opened(
               fixture.owner,
               holder,
               holder_incarnation,
               "unknown-admission-attachment"
             )

    Process.sleep(250)
    origin = {holder_incarnation, 1, 1}
    worker = start_ticket_worker(holder)

    assert {:ok, ^origin} =
             open_mutation(fixture, holder, origin, :session_prompt, worker)

    result = %{"operation" => "prompt", "status" => "admission_unknown"}

    assert {:ok, :admitted} =
             invoke(holder, fn ->
               LeaseOwner.mutate(
                 fixture.owner,
                 origin,
                 :session_prompt,
                 "unknown-admission-renewal",
                 holder_incarnation,
                 writer_epoch,
                 worker,
                 fn -> {:admission_unknown, result} end
               )
             end)

    assert_receive {:connection_message, ^holder, {:relay_ticket_result, ^origin, ^result}}, 500
    eventually(fn -> LeaseOwner.status(fixture.owner).in_flight == 0 end)

    refute_receive {:lease_expiry_proposed, _, _, _, _, _, _, _}, 220
    assert %{phase: :held, held: true} = LeaseOwner.status(fixture.owner)
    stop_connection(holder, fixture.relay, holder_incarnation)
  end

  test "a refused mutation discards its candidate renewal" do
    lease_term_ms = 400
    fixture = start_fixture(lease_term_ms: lease_term_ms)
    {holder, holder_incarnation, writer_epoch} = grant_first(fixture, lease_term_ms)

    assert :ok =
             LeaseOwner.attachment_opened(
               fixture.owner,
               holder,
               holder_incarnation,
               "refused-admission-attachment"
             )

    Process.sleep(250)
    origin = {holder_incarnation, 1, 1}
    worker = start_ticket_worker(holder)

    assert {:ok, ^origin} =
             open_mutation(fixture, holder, origin, :session_prompt, worker)

    result = %{"operation" => "prompt", "status" => "refused"}

    assert {:ok, :admitted} =
             invoke(holder, fn ->
               LeaseOwner.mutate(
                 fixture.owner,
                 origin,
                 :session_prompt,
                 "refused-admission-no-renewal",
                 holder_incarnation,
                 writer_epoch,
                 worker,
                 fn -> {:refused, result} end
               )
             end)

    assert_receive {:connection_message, ^holder, {:relay_ticket_result, ^origin, ^result}}, 500
    eventually(fn -> LeaseOwner.status(fixture.owner).in_flight == 0 end)

    assert_receive {:lease_expiry_proposed, expiry_ref, owner, owner_incarnation, session_id,
                    ^holder, ^holder_incarnation, ^writer_epoch},
                   250

    assert owner == fixture.owner
    assert owner_incarnation == fixture.owner_incarnation
    assert session_id == fixture.session_id
    assert :ok = LeaseOwner.resolve_expiry(fixture.owner, expiry_ref)
    assert %{phase: :expired, held: false} = LeaseOwner.status(fixture.owner)
    stop_connection(holder, fixture.relay, holder_incarnation)
  end

  test "an earlier mutation settles before explicit release" do
    fixture = start_fixture()
    {holder, holder_incarnation, writer_epoch} = grant_first(fixture)

    assert :ok =
             LeaseOwner.attachment_opened(
               fixture.owner,
               holder,
               holder_incarnation,
               "controller-attachment"
             )

    mutation_origin = {holder_incarnation, 1, 1}
    mutation_worker = start_ticket_worker(holder)

    assert {:ok, ^mutation_origin} =
             open_mutation(
               fixture,
               holder,
               mutation_origin,
               :session_prompt,
               mutation_worker
             )

    parent = self()
    mutation_result = %{"operation" => "prompt", "status" => "accepted"}

    assert {:ok, :admitted} =
             invoke(holder, fn ->
               LeaseOwner.mutate(
                 fixture.owner,
                 mutation_origin,
                 :session_prompt,
                 "mutation-before-release",
                 holder_incarnation,
                 writer_epoch,
                 mutation_worker,
                 fn ->
                   send(parent, {:release_order_mutation, self()})

                   receive do
                     :complete -> {:accepted, mutation_result}
                   end
                 end
               )
             end)

    assert_receive {:release_order_mutation, task}, 500
    release_origin = {holder_incarnation, 2, 1}
    {release_worker, release_worker_incarnation} = start_worker(holder, release_origin)

    assert {:ok, ^release_origin} =
             open_release(
               fixture,
               holder,
               holder_incarnation,
               release_origin,
               release_worker,
               release_worker_incarnation
             )

    assert {:ok, :queued} =
             LeaseOwner.release(
               fixture.owner,
               release_origin,
               "release-after-mutation",
               holder,
               holder_incarnation,
               writer_epoch
             )

    refute_receive {:release_proposed, _, ^release_origin, _, _, _}, 40
    assert %{in_flight: 1, queued_operations: 1} = LeaseOwner.status(fixture.owner)
    send(task, :complete)

    assert_receive {:connection_message, ^holder,
                    {:relay_ticket_result, ^mutation_origin, ^mutation_result}},
                   500

    assert_receive {:release_proposed, release_ref, ^release_origin, owner, owner_incarnation,
                    ^holder_incarnation},
                   500

    assert owner == fixture.owner
    assert owner_incarnation == fixture.owner_incarnation
    release_result = WireRecords.control_released("release-after-mutation")
    settlement_ref = make_ref()

    assert :ok =
             AdmissionRelay.select_lease_result(
               fixture.relay,
               release_origin,
               fixture.owner,
               fixture.owner_incarnation,
               settlement_ref,
               release_result
             )

    assert :ok =
             AdmissionRelay.settle_lease_result(
               fixture.relay,
               release_origin,
               settlement_ref
             )

    assert :ok = LeaseOwner.resolve_release(fixture.owner, release_ref, :released)

    assert_receive {:connection_message, ^holder,
                    {:relay_permit_result, ^release_origin, ^release_result}},
                   500

    assert %{phase: :released, in_flight: 0, queued_operations: 0} =
             LeaseOwner.status(fixture.owner)

    stop_connection(holder, fixture.relay, holder_incarnation)
  end

  test "pipelined mutations promote in connection order one at a time" do
    fixture = start_fixture()
    {holder, holder_incarnation, writer_epoch} = grant_first(fixture)

    assert :ok =
             LeaseOwner.attachment_opened(
               fixture.owner,
               holder,
               holder_incarnation,
               "controller-attachment"
             )

    first_origin = {holder_incarnation, 1, 1}
    second_origin = {holder_incarnation, 2, 1}
    first_worker = start_ticket_worker(holder)
    second_worker = start_ticket_worker(holder)

    assert {:ok, ^first_origin} =
             open_mutation(fixture, holder, first_origin, :session_prompt, first_worker)

    assert {:ok, ^second_origin} =
             open_mutation(fixture, holder, second_origin, :session_abort, second_worker)

    parent = self()
    first_result = %{"operation" => "first", "status" => "accepted"}
    second_result = %{"operation" => "second", "status" => "accepted"}

    assert {:ok, :admitted} =
             invoke(holder, fn ->
               LeaseOwner.mutate(
                 fixture.owner,
                 first_origin,
                 :session_prompt,
                 "pipeline-first",
                 holder_incarnation,
                 writer_epoch,
                 first_worker,
                 fn ->
                   send(parent, {:pipeline_task, :first, self()})

                   receive do
                     :complete -> {:accepted, first_result}
                   end
                 end
               )
             end)

    assert_receive {:pipeline_task, :first, first_task}, 500
    second_invoke = make_ref()

    send(
      holder,
      {:invoke, self(), second_invoke,
       fn ->
         LeaseOwner.mutate(
           fixture.owner,
           second_origin,
           :session_abort,
           "pipeline-second",
           holder_incarnation,
           writer_epoch,
           second_worker,
           fn ->
             send(parent, {:pipeline_task, :second, self()})

             receive do
               :complete -> {:accepted, second_result}
             end
           end
         )
       end}
    )

    eventually(fn -> LeaseOwner.status(fixture.owner).queued_operations == 1 end)
    refute_receive {:pipeline_task, :second, _task}, 40
    refute_receive {:invoked, ^second_invoke, _result}, 40
    send(first_task, :complete)

    assert_receive {:pipeline_task, :second, second_task}, 500
    assert_receive {:invoked, ^second_invoke, {:ok, :admitted}}, 500
    assert %{in_flight: 1, queued_operations: 0} = LeaseOwner.status(fixture.owner)
    send(second_task, :complete)

    assert_receive {:connection_message, ^holder,
                    {:relay_ticket_result, ^first_origin, ^first_result}},
                   500

    assert_receive {:connection_message, ^holder,
                    {:relay_ticket_result, ^second_origin, ^second_result}},
                   500

    eventually(fn -> LeaseOwner.status(fixture.owner).in_flight == 0 end)
    stop_connection(holder, fixture.relay, holder_incarnation)
  end

  test "a queued worker lost before promotion starts no core task" do
    fixture = start_fixture()
    {holder, holder_incarnation, writer_epoch} = grant_first(fixture)

    assert :ok =
             LeaseOwner.attachment_opened(
               fixture.owner,
               holder,
               holder_incarnation,
               "worker-loss-attachment"
             )

    first_origin = {holder_incarnation, 1, 1}
    lost_origin = {holder_incarnation, 2, 1}
    first_worker = start_ticket_worker(holder)
    lost_worker = start_ticket_worker(holder)

    assert {:ok, ^first_origin} =
             open_mutation(fixture, holder, first_origin, :session_prompt, first_worker)

    assert {:ok, ^lost_origin} =
             open_mutation(fixture, holder, lost_origin, :session_abort, lost_worker)

    parent = self()
    first_result = %{"operation" => "first", "status" => "accepted"}

    assert {:ok, :admitted} =
             invoke(holder, fn ->
               LeaseOwner.mutate(
                 fixture.owner,
                 first_origin,
                 :session_prompt,
                 "worker-loss-first",
                 holder_incarnation,
                 writer_epoch,
                 first_worker,
                 fn ->
                   send(parent, {:worker_loss_first_task, self()})

                   receive do
                     :complete -> {:accepted, first_result}
                   end
                 end
               )
             end)

    assert_receive {:worker_loss_first_task, first_task}, 500
    lost_invoke = make_ref()

    send(
      holder,
      {:invoke, self(), lost_invoke,
       fn ->
         LeaseOwner.mutate(
           fixture.owner,
           lost_origin,
           :session_abort,
           "worker-loss-second",
           holder_incarnation,
           writer_epoch,
           lost_worker,
           fn ->
             send(parent, :unexpected_lost_worker_task)
             {:accepted, %{"unexpected" => true}}
           end
         )
       end}
    )

    eventually(fn -> LeaseOwner.status(fixture.owner).queued_operations == 1 end)
    lost_worker_monitor = Process.monitor(lost_worker)
    Process.exit(lost_worker, :kill)

    assert_receive {:DOWN, ^lost_worker_monitor, :process, ^lost_worker, :killed}, 500
    assert_receive {:invoked, ^lost_invoke, {:error, :ticket_unavailable}}, 500

    assert_receive {:connection_message, ^holder,
                    {:relay_ticket_failed, ^lost_origin, :worker_lost}},
                   500

    refute_receive :unexpected_lost_worker_task, 40
    assert %{in_flight: 1, queued_operations: 0} = LeaseOwner.status(fixture.owner)
    send(first_task, :complete)

    assert_receive {:connection_message, ^holder,
                    {:relay_ticket_result, ^first_origin, ^first_result}},
                   500

    eventually(fn -> LeaseOwner.status(fixture.owner).in_flight == 0 end)
    refute_receive :unexpected_lost_worker_task, 40
    stop_connection(holder, fixture.relay, holder_incarnation)
  end

  test "a dormant resume may activate without an attachment and settles capacity before reply" do
    fixture = start_fixture()
    {holder, holder_incarnation, writer_epoch} = grant_first(fixture)
    origin = {holder_incarnation, 1, 1}
    worker = start_ticket_worker(holder)

    assert {:ok, ^origin} =
             open_mutation(fixture, holder, origin, :session_resume, worker)

    parent = self()

    result = %{
      "type" => "result",
      "method" => "session.resume",
      "request_id" => "resume-dormant",
      "result" => %{"session_id" => "session"}
    }

    assert {:ok, :admitted} =
             invoke(holder, fn ->
               LeaseOwner.resume(
                 fixture.owner,
                 origin,
                 "resume-dormant",
                 "resume-command",
                 holder_incarnation,
                 writer_epoch,
                 worker,
                 fn ->
                   send(parent, :dormant_resume_called)
                   {:accepted, :activated, result}
                 end
               )
             end)

    assert_receive :dormant_resume_called, 500

    assert_receive {:connection_message, ^holder, {:relay_ticket_result, ^origin, ^result}},
                   500

    assert %{active_sessions: 1, activation_reservations: 0, activations_used: 1} =
             ConnectionRegistry.status(fixture.registry)

    eventually(fn -> LeaseOwner.status(fixture.owner).in_flight == 0 end)
    stop_connection(holder, fixture.relay, holder_incarnation)
  end

  test "an active resume still requires attachment and starts no core call when absent" do
    fixture = start_fixture()
    {holder, holder_incarnation, writer_epoch} = grant_first(fixture)
    count_activation(fixture.registry, fixture.session_id, 90)
    origin = {holder_incarnation, 1, 1}
    worker = start_ticket_worker(holder)

    assert {:ok, ^origin} =
             open_mutation(fixture, holder, origin, :session_resume, worker)

    parent = self()

    assert {:ok, :completed} =
             invoke(holder, fn ->
               LeaseOwner.resume(
                 fixture.owner,
                 origin,
                 "resume-unattached",
                 "resume-unattached-command",
                 holder_incarnation,
                 writer_epoch,
                 worker,
                 fn ->
                   send(parent, :unexpected_active_resume)
                   {:accepted, :no_activation, %{"unexpected" => true}}
                 end
               )
             end)

    refused = WireRecords.request_error("resume-unattached", "control_not_held")

    assert_receive {:connection_message, ^holder, {:relay_ticket_result, ^origin, ^refused}},
                   500

    refute_receive :unexpected_active_resume, 40

    assert %{active_sessions: 1, activation_reservations: 0} =
             ConnectionRegistry.status(fixture.registry)

    stop_connection(holder, fixture.relay, holder_incarnation)
  end

  test "an active attached resume proceeds at the full activation ceiling" do
    fixture = start_fixture()
    {holder, holder_incarnation, writer_epoch} = grant_first(fixture)

    Enum.each(1..63, fn index ->
      count_activation(fixture.registry, "other-session-#{index}", index)
    end)

    count_activation(fixture.registry, fixture.session_id, 90)

    assert %{active_sessions: 64, activations_used: 64} =
             ConnectionRegistry.status(fixture.registry)

    assert :ok =
             LeaseOwner.attachment_opened(
               fixture.owner,
               holder,
               holder_incarnation,
               "resume-attachment"
             )

    origin = {holder_incarnation, 1, 1}
    worker = start_ticket_worker(holder)

    assert {:ok, ^origin} =
             open_mutation(fixture, holder, origin, :session_resume, worker)

    result = %{
      "type" => "result",
      "method" => "session.resume",
      "request_id" => "resume-active",
      "result" => %{"session_id" => "session"}
    }

    parent = self()

    assert {:ok, :admitted} =
             invoke(holder, fn ->
               LeaseOwner.resume(
                 fixture.owner,
                 origin,
                 "resume-active",
                 "resume-active-command",
                 holder_incarnation,
                 writer_epoch,
                 worker,
                 fn ->
                   send(parent, :active_resume_called)
                   {:accepted, :no_activation, result}
                 end
               )
             end)

    assert_receive :active_resume_called, 500

    assert_receive {:connection_message, ^holder, {:relay_ticket_result, ^origin, ^result}},
                   500

    assert %{active_sessions: 64, activation_reservations: 0, activations_used: 64} =
             ConnectionRegistry.status(fixture.registry)

    eventually(fn -> LeaseOwner.status(fixture.owner).in_flight == 0 end)
    stop_connection(holder, fixture.relay, holder_incarnation)
  end

  test "a dormant resume at the activation ceiling refuses before its core call" do
    fixture = start_fixture()
    {holder, holder_incarnation, writer_epoch} = grant_first(fixture)

    Enum.each(1..64, fn index ->
      count_activation(fixture.registry, "full-session-#{index}", index)
    end)

    origin = {holder_incarnation, 1, 1}
    worker = start_ticket_worker(holder)

    assert {:ok, ^origin} =
             open_mutation(fixture, holder, origin, :session_resume, worker)

    parent = self()

    assert {:ok, :completed} =
             invoke(holder, fn ->
               LeaseOwner.resume(
                 fixture.owner,
                 origin,
                 "resume-capacity",
                 "resume-capacity-command",
                 holder_incarnation,
                 writer_epoch,
                 worker,
                 fn ->
                   send(parent, :unexpected_capacity_resume)
                   {:accepted, :activated, %{"unexpected" => true}}
                 end
               )
             end)

    refused = WireRecords.request_error("resume-capacity", "activation_ceiling_reached")

    assert_receive {:connection_message, ^holder, {:relay_ticket_result, ^origin, ^refused}},
                   500

    refute_receive :unexpected_capacity_resume, 40

    assert %{active_sessions: 64, activation_reservations: 0, activations_used: 64} =
             ConnectionRegistry.status(fixture.registry)

    stop_connection(holder, fixture.relay, holder_incarnation)
  end

  test "an exact dormant resume replay shares one reservation and one task" do
    fixture = start_fixture()
    {holder, holder_incarnation, writer_epoch} = grant_first(fixture)
    first = {holder_incarnation, 1, 1}
    duplicate = {holder_incarnation, 2, 1}
    first_worker = start_ticket_worker(holder)
    duplicate_worker = start_ticket_worker(holder)

    for {origin, worker} <- [{first, first_worker}, {duplicate, duplicate_worker}] do
      assert {:ok, ^origin} =
               open_mutation(fixture, holder, origin, :session_resume, worker)
    end

    parent = self()
    release = make_ref()

    result = %{
      "type" => "result",
      "method" => "session.resume",
      "request_id" => "resume-primary",
      "result" => %{"session_id" => "session"}
    }

    assert {:ok, :admitted} =
             invoke(holder, fn ->
               LeaseOwner.resume(
                 fixture.owner,
                 first,
                 "resume-primary",
                 "same-resume-command",
                 holder_incarnation,
                 writer_epoch,
                 first_worker,
                 fn ->
                   send(parent, {:resume_primary_task, self()})

                   receive do
                     ^release -> {:accepted, :activated, result}
                   end
                 end
               )
             end)

    assert_receive {:resume_primary_task, task}, 500

    assert {:ok, :admitted} =
             invoke(holder, fn ->
               LeaseOwner.resume(
                 fixture.owner,
                 duplicate,
                 "resume-duplicate",
                 "same-resume-command",
                 holder_incarnation,
                 writer_epoch,
                 duplicate_worker,
                 fn ->
                   send(parent, :unexpected_duplicate_resume_task)
                   {:accepted, :activated, %{"unexpected" => true}}
                 end
               )
             end)

    assert %{activation_reservations: 1, activations_used: 1} =
             ConnectionRegistry.status(fixture.registry)

    assert %{ticketed: 1, waiting: 1} = AdmissionRelay.status(fixture.relay)
    refute_receive :unexpected_duplicate_resume_task, 40
    send(task, release)

    assert_receive {:connection_message, ^holder, {:relay_ticket_result, ^first, ^result}}, 500

    assert_receive {:connection_message, ^holder, {:relay_ticket_result, ^duplicate, ^result}},
                   500

    refute_receive :unexpected_duplicate_resume_task, 40

    assert %{active_sessions: 1, activation_reservations: 0, activations_used: 1} =
             ConnectionRegistry.status(fixture.registry)

    eventually(fn -> LeaseOwner.status(fixture.owner).in_flight == 0 end)
    stop_connection(holder, fixture.relay, holder_incarnation)
  end

  defp start_fixture(options \\ []) do
    daemon_incarnation = incarnation()
    session_id = Keyword.get(options, :session_id, "session")

    relay =
      start_supervised!(
        {AdmissionRelay,
         owner: self(), owner_incarnation: daemon_incarnation, admission_wait_ms: 1_000}
      )

    registry =
      start_supervised!({ConnectionRegistry, owner: self(), initialize_deadline_ms: 1_000})

    registry_incarnation = incarnation()
    assert :ok = AdmissionRelay.register_registry(relay, registry, registry_incarnation)
    assert :ok = ConnectionRegistry.bind_relay(registry, relay, registry_incarnation)

    owner_incarnation = incarnation()

    owner =
      start_supervised!(
        {LeaseOwner,
         daemon_owner: self(),
         relay: relay,
         registry: registry,
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
      registry: registry,
      registry_incarnation: registry_incarnation,
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

  defp open_mutation(fixture, connection, origin, class, worker) do
    invoke(connection, fn ->
      with {:ok, ^origin} <-
             AdmissionRelay.open_ticket(
               fixture.relay,
               origin,
               class,
               fixture.session_id,
               {fixture.owner, fixture.owner_incarnation}
             ),
           :ok <-
             AdmissionRelay.bind_ticket_worker(
               fixture.relay,
               origin,
               worker,
               incarnation()
             ) do
        {:ok, origin}
      end
    end)
  end

  defp assert_mutation_refused(
         fixture,
         connection,
         connection_incarnation,
         origin,
         writer_epoch,
         request_id
       ) do
    worker = start_ticket_worker(connection)

    assert {:ok, ^origin} =
             open_mutation(fixture, connection, origin, :session_prompt, worker)

    parent = self()

    assert {:ok, :admitted} =
             invoke(connection, fn ->
               LeaseOwner.mutate(
                 fixture.owner,
                 origin,
                 :session_prompt,
                 request_id,
                 connection_incarnation,
                 writer_epoch,
                 worker,
                 fn ->
                   send(parent, {:unexpected_mutation_call, request_id})
                   {:accepted, %{"unexpected" => true}}
                 end
               )
             end)

    refused = WireRecords.control_error(request_id, "control_not_held")

    assert_receive {:connection_message, ^connection, {:relay_ticket_result, ^origin, ^refused}},
                   500

    refute_receive {:unexpected_mutation_call, ^request_id}, 20
    eventually(fn -> LeaseOwner.status(fixture.owner).in_flight == 0 end)
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

  defp count_activation(registry, session_id, sequence) do
    origin = {:crypto.hash(:md5, "activation-#{sequence}"), rem(sequence, 32), sequence + 1}

    assert {:ok, {:primary, reservation_ref}} =
             ConnectionRegistry.reserve_activation(
               registry,
               origin,
               {:resume, session_id, "activation-command-#{sequence}"}
             )

    assert :ok =
             ConnectionRegistry.resolve_activation(
               registry,
               reservation_ref,
               :activated,
               session_id
             )
  end

  defp eventually(assertion, attempts \\ 50)

  defp eventually(assertion, attempts) when attempts > 0 do
    if assertion.() do
      :ok
    else
      Process.sleep(10)
      eventually(assertion, attempts - 1)
    end
  end

  defp eventually(_assertion, 0), do: flunk("condition did not become true")

  defp incarnation, do: :crypto.strong_rand_bytes(16)
  defp now_ms, do: System.monotonic_time(:millisecond)
end
