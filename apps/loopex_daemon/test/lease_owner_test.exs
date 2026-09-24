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

    assert :ok =
             first_acquire(
               fixture,
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

    stale_ref = make_ref()

    assert :ok =
             LeaseOwner.request_grant_resolution(
               fixture.owner,
               stale_ref,
               incarnation(),
               grant_ref,
               :granted,
               now_ms()
             )

    refute_receive {:lease_owner_resolution_ack, ^stale_ref, _, _, _, _}, 40
    assert %{phase: :grant_pending, held: false} = LeaseOwner.status(fixture.owner)

    operation_ref = make_ref()

    assert :ok =
             LeaseOwner.request_grant_resolution(
               fixture.owner,
               operation_ref,
               fixture.owner_incarnation,
               grant_ref,
               :granted,
               now_ms()
             )

    assert_receive {:lease_owner_resolution_ack, ^operation_ref, ^owner, ^owner_incarnation,
                    :grant, :ok},
                   500

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

    assert :ok =
             acquire(
               fixture,
               renewal_origin,
               "renew-1",
               holder,
               holder_incarnation,
               now_ms() + 1_000
             )

    assert_settled(fixture, renewal_origin, :result)

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

    assert :ok =
             acquire(
               fixture,
               observer_origin,
               "observer-1",
               observer,
               observer_incarnation,
               now_ms() + 1_000
             )

    assert_settled(fixture, observer_origin, :result)

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

    assert :ok =
             acquire(
               fixture,
               successor_origin,
               "takeover-1",
               successor,
               successor_incarnation,
               request_deadline
             )

    assert :ok = await_waiters(fixture, 1)

    assert %{waiting_acquires: 1, phase: :expiry_pending} = LeaseOwner.status(fixture.owner)
    resolution_ref = make_ref()

    assert :ok =
             LeaseOwner.request_expiry_resolution(
               fixture.owner,
               resolution_ref,
               fixture.owner_incarnation,
               expiry_ref
             )

    assert_receive {:lease_owner_resolution_ack, ^resolution_ref, ^owner, ^owner_incarnation,
                    :expiry, :ok},
                   500

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

    assert :ok = resolve(fixture, :grant, grant_ref, :granted, now_ms())

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

    assert :ok =
             release(
               fixture,
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

    resolution_ref = make_ref()

    assert :ok =
             LeaseOwner.request_release_resolution(
               fixture.owner,
               resolution_ref,
               fixture.owner_incarnation,
               release_ref,
               :cancelled
             )

    assert_receive {:lease_owner_resolution_ack, ^resolution_ref, ^owner, ^owner_incarnation,
                    :release, :ok},
                   500

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

    assert :ok =
             release(
               fixture,
               refused_origin,
               "release-refused",
               holder,
               holder_incarnation,
               :crypto.strong_rand_bytes(16)
             )

    assert_settled(fixture, refused_origin, :result)

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

    assert :ok =
             release(
               fixture,
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
    assert :ok = resolve(fixture, :release, release_ref, :released)
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
        assert :ok = attach(fixture, connection, connection_incarnation, "attachment-canary")

        assert %{attachments: 1, phase: :free} = LeaseOwner.status(fixture.owner)

        assert :ok = detach(fixture, connection, connection_incarnation, "attachment-canary")
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
               lease_mutate(
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

    assert :ok = attach(fixture, holder, holder_incarnation, "holder-attachment")

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

    assert :ok = attach(fixture, observer, observer_incarnation, "observer-attachment")

    assert_mutation_refused(
      fixture,
      observer,
      observer_incarnation,
      {observer_incarnation, 0, 1},
      writer_epoch,
      "wrong-holder"
    )

    assert :ok = detach(fixture, observer, observer_incarnation, "observer-attachment")

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

    assert :ok =
             release(
               fixture,
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

    assert :ok = resolve(fixture, :release, release_ref, :released)

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

    assert :ok = attach(fixture, holder, holder_incarnation, "expired-lease-attachment")

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

    assert :ok = resolve(fixture, :expiry, expiry_ref)
    stop_connection(holder, fixture.relay, holder_incarnation)
  end

  test "an accepted mutation renews before a queued takeover can pass" do
    lease_term_ms = 300
    fixture = start_fixture(lease_term_ms: lease_term_ms)
    {holder, holder_incarnation, writer_epoch} = grant_first(fixture, lease_term_ms)

    assert :ok = attach(fixture, holder, holder_incarnation, "controller-attachment")

    Process.sleep(150)
    origin = {holder_incarnation, 1, 1}
    worker = start_ticket_worker(holder)

    assert {:ok, ^origin} =
             open_mutation(fixture, holder, origin, :session_prompt, worker)

    parent = self()
    result = %{"operation" => "prompt", "status" => "accepted"}

    assert {:ok, :admitted} =
             invoke(holder, fn ->
               lease_mutate(
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

    assert :ok =
             acquire(
               fixture,
               successor_origin,
               "takeover-after-mutation",
               successor,
               successor_incarnation,
               now_ms() + 1_000
             )

    assert :ok = await_waiters(fixture, 1)

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

  # Technical depth: the mutation lands 1.25 s into a 2 s term, and the
  # renewal is proved by no expiry across the original deadline 0.75 s later;
  # these proportions give a loaded machine room, where 250 ms into 400 ms did not.
  test "an admission-unknown mutation commits its candidate renewal" do
    lease_term_ms = 2_000
    fixture = start_fixture(lease_term_ms: lease_term_ms)
    {holder, holder_incarnation, writer_epoch} = grant_first(fixture, lease_term_ms)

    assert :ok = attach(fixture, holder, holder_incarnation, "unknown-admission-attachment")

    Process.sleep(1_250)
    origin = {holder_incarnation, 1, 1}
    worker = start_ticket_worker(holder)

    assert {:ok, ^origin} =
             open_mutation(fixture, holder, origin, :session_prompt, worker)

    result = %{"operation" => "prompt", "status" => "admission_unknown"}

    assert {:ok, :admitted} =
             invoke(holder, fn ->
               lease_mutate(
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

    refute_receive {:lease_expiry_proposed, _, _, _, _, _, _, _}, 1_100
    assert %{phase: :held, held: true} = LeaseOwner.status(fixture.owner)
    stop_connection(holder, fixture.relay, holder_incarnation)
  end

  test "a refused mutation discards its candidate renewal" do
    lease_term_ms = 400
    fixture = start_fixture(lease_term_ms: lease_term_ms)
    {holder, holder_incarnation, writer_epoch} = grant_first(fixture, lease_term_ms)

    assert :ok = attach(fixture, holder, holder_incarnation, "refused-admission-attachment")

    Process.sleep(250)
    origin = {holder_incarnation, 1, 1}
    worker = start_ticket_worker(holder)

    assert {:ok, ^origin} =
             open_mutation(fixture, holder, origin, :session_prompt, worker)

    result = %{"operation" => "prompt", "status" => "refused"}

    assert {:ok, :admitted} =
             invoke(holder, fn ->
               lease_mutate(
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
    assert :ok = resolve(fixture, :expiry, expiry_ref)
    assert %{phase: :expired, held: false} = LeaseOwner.status(fixture.owner)
    stop_connection(holder, fixture.relay, holder_incarnation)
  end

  test "an earlier mutation settles before explicit release" do
    fixture = start_fixture()
    {holder, holder_incarnation, writer_epoch} = grant_first(fixture)

    assert :ok = attach(fixture, holder, holder_incarnation, "controller-attachment")

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
               lease_mutate(
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

    assert :ok =
             release(
               fixture,
               release_origin,
               "release-after-mutation",
               holder,
               holder_incarnation,
               writer_epoch
             )

    assert :ok = eventually(fn -> LeaseOwner.status(fixture.owner).queued_operations == 1 end)

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

    assert :ok = resolve(fixture, :release, release_ref, :released)

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

    assert :ok = attach(fixture, holder, holder_incarnation, "controller-attachment")

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
               lease_mutate(
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
         lease_mutate(
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

    assert :ok = attach(fixture, holder, holder_incarnation, "worker-loss-attachment")

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
               lease_mutate(
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
         lease_mutate(
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
               lease_resume(
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
               lease_resume(
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

    assert :ok = attach(fixture, holder, holder_incarnation, "resume-attachment")

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
               lease_resume(
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
               lease_resume(
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
               lease_resume(
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
               lease_resume(
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

  test "distinct dormant resumes hold independent reservations while promotion is serial" do
    fixture = start_fixture()
    {holder, holder_incarnation, writer_epoch} = grant_first(fixture)
    first = {holder_incarnation, 1, 1}
    second = {holder_incarnation, 2, 1}
    first_worker = start_ticket_worker(holder)
    second_worker = start_ticket_worker(holder)

    for {origin, worker} <- [{first, first_worker}, {second, second_worker}] do
      assert {:ok, ^origin} =
               open_mutation(fixture, holder, origin, :session_resume, worker)
    end

    parent = self()
    first_release = make_ref()
    second_release = make_ref()

    first_result = %{
      "type" => "result",
      "method" => "session.resume",
      "request_id" => "resume-distinct-first",
      "result" => %{"session_id" => "session"}
    }

    second_result = %{
      "type" => "result",
      "method" => "session.resume",
      "request_id" => "resume-distinct-second",
      "result" => %{"session_id" => "session"}
    }

    assert {:ok, :admitted} =
             invoke(holder, fn ->
               lease_resume(
                 fixture.owner,
                 first,
                 "resume-distinct-first",
                 "resume-distinct-command-one",
                 holder_incarnation,
                 writer_epoch,
                 first_worker,
                 fn ->
                   send(parent, {:distinct_resume_task, :first, self()})

                   receive do
                     ^first_release -> {:accepted, :activated, first_result}
                   end
                 end
               )
             end)

    assert_receive {:distinct_resume_task, :first, first_task}, 500
    second_invoke = make_ref()

    send(
      holder,
      {:invoke, self(), second_invoke,
       fn ->
         lease_resume(
           fixture.owner,
           second,
           "resume-distinct-second",
           "resume-distinct-command-two",
           holder_incarnation,
           writer_epoch,
           second_worker,
           fn ->
             send(parent, {:distinct_resume_task, :second, self()})

             receive do
               ^second_release -> {:accepted, :no_activation, second_result}
             end
           end
         )
       end}
    )

    eventually(fn -> ConnectionRegistry.status(fixture.registry).activation_preparations == 1 end)

    assert %{
             active_sessions: 0,
             activation_reservations: 2,
             activation_preparations: 1,
             activations_used: 2
           } = ConnectionRegistry.status(fixture.registry)

    attacker =
      Task.async(fn ->
        ConnectionRegistry.promote_resume(
          fixture.registry,
          second,
          fixture.session_id,
          "resume-distinct-command-two",
          fixture.owner_incarnation,
          :ineligible,
          false,
          WireRecords.request_error("resume-distinct-second", "control_not_held"),
          WireRecords.request_error("resume-distinct-second", "activation_ceiling_reached"),
          fn -> {:refused, :no_activation, second_result} end
        )
      end)

    assert {:error, :owner_unavailable} = Task.await(attacker)

    assert %{activation_reservations: 2, activation_preparations: 1} =
             ConnectionRegistry.status(fixture.registry)

    assert %{in_flight: 1, queued_operations: 1} = LeaseOwner.status(fixture.owner)
    refute_receive {:distinct_resume_task, :second, _task}, 40
    refute_receive {:invoked, ^second_invoke, _result}, 40
    send(first_task, first_release)

    assert_receive {:connection_message, ^holder, {:relay_ticket_result, ^first, ^first_result}},
                   500

    assert_receive {:distinct_resume_task, :second, second_task}, 500
    assert_receive {:invoked, ^second_invoke, {:ok, :admitted}}, 500

    assert %{
             active_sessions: 1,
             activation_reservations: 1,
             activation_preparations: 0,
             activations_used: 2
           } = ConnectionRegistry.status(fixture.registry)

    send(second_task, second_release)

    assert_receive {:connection_message, ^holder,
                    {:relay_ticket_result, ^second, ^second_result}},
                   500

    assert %{active_sessions: 1, activation_reservations: 0, activations_used: 1} =
             ConnectionRegistry.status(fixture.registry)

    eventually(fn -> LeaseOwner.status(fixture.owner).in_flight == 0 end)
    stop_connection(holder, fixture.relay, holder_incarnation)
  end

  test "queued resume worker loss releases only its prepared reservation" do
    fixture = start_fixture()
    {holder, holder_incarnation, writer_epoch} = grant_first(fixture)
    first = {holder_incarnation, 1, 1}
    queued = {holder_incarnation, 2, 1}
    first_worker = start_ticket_worker(holder)
    queued_worker = start_ticket_worker(holder)

    for {origin, worker} <- [{first, first_worker}, {queued, queued_worker}] do
      assert {:ok, ^origin} =
               open_mutation(fixture, holder, origin, :session_resume, worker)
    end

    parent = self()
    release = make_ref()
    first_result = %{"operation" => "resume", "status" => "accepted"}

    assert {:ok, :admitted} =
             invoke(holder, fn ->
               lease_resume(
                 fixture.owner,
                 first,
                 "resume-worker-primary",
                 "resume-worker-command-one",
                 holder_incarnation,
                 writer_epoch,
                 first_worker,
                 fn ->
                   send(parent, {:resume_worker_primary, self()})

                   receive do
                     ^release -> {:accepted, :activated, first_result}
                   end
                 end
               )
             end)

    assert_receive {:resume_worker_primary, first_task}, 500
    queued_invoke = make_ref()

    send(
      holder,
      {:invoke, self(), queued_invoke,
       fn ->
         lease_resume(
           fixture.owner,
           queued,
           "resume-worker-queued",
           "resume-worker-command-two",
           holder_incarnation,
           writer_epoch,
           queued_worker,
           fn ->
             send(parent, :unexpected_queued_resume_task)
             {:accepted, :no_activation, %{"unexpected" => true}}
           end
         )
       end}
    )

    eventually(fn -> ConnectionRegistry.status(fixture.registry).activation_preparations == 1 end)

    assert %{activation_reservations: 2, activation_preparations: 1} =
             ConnectionRegistry.status(fixture.registry)

    queued_worker_monitor = Process.monitor(queued_worker)
    Process.exit(queued_worker, :kill)
    assert_receive {:DOWN, ^queued_worker_monitor, :process, ^queued_worker, :killed}, 500
    assert_receive {:invoked, ^queued_invoke, {:error, :ticket_unavailable}}, 500

    eventually(fn ->
      match?(
        %{activation_reservations: 1, activation_preparations: 0},
        ConnectionRegistry.status(fixture.registry)
      )
    end)

    assert_receive {:connection_message, ^holder, {:relay_ticket_failed, ^queued, :worker_lost}},
                   500

    refute_receive :unexpected_queued_resume_task, 40
    send(first_task, release)

    assert_receive {:connection_message, ^holder, {:relay_ticket_result, ^first, ^first_result}},
                   500

    eventually(fn -> ConnectionRegistry.status(fixture.registry).activation_reservations == 0 end)
    stop_connection(holder, fixture.relay, holder_incarnation)
  end

  test "lease-owner loss releases queued resume preparations without disturbing promotion" do
    fixture = start_fixture()
    {holder, holder_incarnation, writer_epoch} = grant_first(fixture)
    first = {holder_incarnation, 1, 1}
    queued = {holder_incarnation, 2, 1}
    first_worker = start_ticket_worker(holder)
    queued_worker = start_ticket_worker(holder)

    for {origin, worker} <- [{first, first_worker}, {queued, queued_worker}] do
      assert {:ok, ^origin} =
               open_mutation(fixture, holder, origin, :session_resume, worker)
    end

    parent = self()
    release = make_ref()
    first_result = %{"operation" => "resume", "status" => "accepted"}

    assert {:ok, :admitted} =
             invoke(holder, fn ->
               lease_resume(
                 fixture.owner,
                 first,
                 "resume-owner-primary",
                 "resume-owner-command-one",
                 holder_incarnation,
                 writer_epoch,
                 first_worker,
                 fn ->
                   send(parent, {:resume_owner_primary, self()})

                   receive do
                     ^release -> {:accepted, :activated, first_result}
                   end
                 end
               )
             end)

    assert_receive {:resume_owner_primary, first_task}, 500
    queued_invoke = make_ref()

    send(
      holder,
      {:invoke, self(), queued_invoke,
       fn ->
         catch_exit(
           lease_resume(
             fixture.owner,
             queued,
             "resume-owner-queued",
             "resume-owner-command-two",
             holder_incarnation,
             writer_epoch,
             queued_worker,
             fn ->
               send(parent, :unexpected_owner_loss_resume_task)
               {:accepted, :no_activation, %{"unexpected" => true}}
             end
           )
         )
       end}
    )

    eventually(fn -> ConnectionRegistry.status(fixture.registry).activation_preparations == 1 end)

    assert %{activation_reservations: 2, activation_preparations: 1} =
             ConnectionRegistry.status(fixture.registry)

    stop_supervised!(LeaseOwner)

    assert_receive {:relay_owner_lost, relay, session_id, owner, owner_incarnation, [^queued]},
                   500

    assert relay == fixture.relay
    assert session_id == fixture.session_id
    assert owner == fixture.owner
    assert owner_incarnation == fixture.owner_incarnation

    assert_receive {:relay_owner_loss_ready, ^relay, ^owner, ^owner_incarnation}, 500

    eventually(fn ->
      match?(
        %{activation_reservations: 1, activation_preparations: 0},
        ConnectionRegistry.status(fixture.registry)
      )
    end)

    classification_ref = make_ref()

    assert :ok =
             AdmissionRelay.classify_owner_loss(
               fixture.relay,
               classification_ref,
               fixture.daemon_incarnation,
               fixture.session_id,
               fixture.owner,
               fixture.owner_incarnation,
               holder_incarnation
             )

    assert_receive {:relay_owner_loss_classified_ack, ack_relay, ^classification_ref,
                    ack_session_id, ack_owner, ack_owner_incarnation},
                   500

    assert ack_relay == fixture.relay
    assert ack_session_id == fixture.session_id
    assert ack_owner == fixture.owner
    assert ack_owner_incarnation == fixture.owner_incarnation

    assert_receive {:invoked, ^queued_invoke, _result}, 500
    refute_receive {:connection_message, ^holder, {:relay_ticket_failed, ^queued, _reason}}, 40
    assert %{tickets: 1, owner_losses: 0} = AdmissionRelay.status(fixture.relay)
    refute_receive :unexpected_owner_loss_resume_task, 40

    send(first_task, release)

    assert_receive {:connection_message, ^holder, {:relay_ticket_result, ^first, ^first_result}},
                   500

    eventually(fn -> ConnectionRegistry.status(fixture.registry).activation_reservations == 0 end)
    stop_connection(holder, fixture.relay, holder_incarnation)
  end

  test "the admission deadline releases a queued resume preparation" do
    fixture = start_fixture(admission_wait_ms: 20)
    {holder, holder_incarnation, writer_epoch} = grant_first(fixture)
    first = {holder_incarnation, 1, 1}
    queued = {holder_incarnation, 2, 1}
    first_worker = start_ticket_worker(holder)
    queued_worker = start_ticket_worker(holder)

    for {origin, worker} <- [{first, first_worker}, {queued, queued_worker}] do
      assert {:ok, ^origin} =
               open_mutation(fixture, holder, origin, :session_resume, worker)
    end

    parent = self()
    release = make_ref()
    first_result = %{"operation" => "resume", "status" => "accepted"}

    assert {:ok, :admitted} =
             invoke(holder, fn ->
               lease_resume(
                 fixture.owner,
                 first,
                 "resume-cut-primary",
                 "resume-cut-command-one",
                 holder_incarnation,
                 writer_epoch,
                 first_worker,
                 fn ->
                   send(parent, {:resume_cut_primary, self()})

                   receive do
                     ^release -> {:accepted, :activated, first_result}
                   end
                 end
               )
             end)

    assert_receive {:resume_cut_primary, first_task}, 500
    queued_invoke = make_ref()

    send(
      holder,
      {:invoke, self(), queued_invoke,
       fn ->
         lease_resume(
           fixture.owner,
           queued,
           "resume-cut-queued",
           "resume-cut-command-two",
           holder_incarnation,
           writer_epoch,
           queued_worker,
           fn ->
             send(parent, :unexpected_cut_resume_task)
             {:accepted, :no_activation, %{"unexpected" => true}}
           end
         )
       end}
    )

    eventually(fn -> ConnectionRegistry.status(fixture.registry).activation_preparations == 1 end)
    cut_ref = make_ref()
    send(fixture.relay, {:relay_barrier, cut_ref, :cut})
    assert_receive {:relay_barrier_ack, ^cut_ref, :cut, _payload}, 500

    assert_receive {:invoked, ^queued_invoke, {:error, :ticket_unavailable}}, 500

    assert_receive {:connection_message, ^holder,
                    {:relay_ticket_cancelled, ^queued, :daemon_stopping}},
                   500

    eventually(fn ->
      match?(
        %{activation_reservations: 1, activation_preparations: 0},
        ConnectionRegistry.status(fixture.registry)
      )
    end)

    refute_receive :unexpected_cut_resume_task, 40
    send(first_task, release)

    assert_receive {:connection_message, ^holder, {:relay_ticket_result, ^first, ^first_result}},
                   500

    eventually(fn -> ConnectionRegistry.status(fixture.registry).activation_reservations == 0 end)
    stop_connection(holder, fixture.relay, holder_incarnation)
  end

  test "connection loss releases a queued resume preparation and retains promoted accounting" do
    fixture = start_fixture()
    relay = fixture.relay
    {holder, holder_incarnation, writer_epoch} = grant_first(fixture)
    first = {holder_incarnation, 1, 1}
    queued = {holder_incarnation, 2, 1}
    first_worker = start_ticket_worker(holder)
    queued_worker = start_ticket_worker(holder)

    for {origin, worker} <- [{first, first_worker}, {queued, queued_worker}] do
      assert {:ok, ^origin} =
               open_mutation(fixture, holder, origin, :session_resume, worker)
    end

    parent = self()
    release = make_ref()
    first_result = %{"operation" => "resume", "status" => "accepted"}

    assert {:ok, :admitted} =
             invoke(holder, fn ->
               lease_resume(
                 fixture.owner,
                 first,
                 "resume-connection-primary",
                 "resume-connection-command-one",
                 holder_incarnation,
                 writer_epoch,
                 first_worker,
                 fn ->
                   send(parent, {:resume_connection_primary, self()})

                   receive do
                     ^release -> {:accepted, :activated, first_result}
                   end
                 end
               )
             end)

    assert_receive {:resume_connection_primary, first_task}, 500

    send(
      holder,
      {:invoke, self(), make_ref(),
       fn ->
         lease_resume(
           fixture.owner,
           queued,
           "resume-connection-queued",
           "resume-connection-command-two",
           holder_incarnation,
           writer_epoch,
           queued_worker,
           fn ->
             send(parent, :unexpected_connection_loss_resume_task)
             {:accepted, :no_activation, %{"unexpected" => true}}
           end
         )
       end}
    )

    eventually(fn -> ConnectionRegistry.status(fixture.registry).activation_preparations == 1 end)
    holder_monitor = Process.monitor(holder)
    Process.exit(holder, :kill)
    assert_receive {:DOWN, ^holder_monitor, :process, ^holder, :killed}, 500

    eventually(fn ->
      match?(
        %{activation_reservations: 1, activation_preparations: 0},
        ConnectionRegistry.status(fixture.registry)
      )
    end)

    refute_receive :unexpected_connection_loss_resume_task, 40
    refute_receive {:relay_connection_retired, ^relay, ^holder_incarnation}, 40
    send(first_task, release)

    eventually(fn -> ConnectionRegistry.status(fixture.registry).activation_reservations == 0 end)
    assert_receive {:relay_connection_retired, ^relay, ^holder_incarnation}, 500
  end

  test "queued resume rechecks an expired lease before using its reservation" do
    fixture = start_fixture(lease_term_ms: 80)
    {holder, holder_incarnation, writer_epoch} = grant_first(fixture, 80)
    first = {holder_incarnation, 1, 1}
    queued = {holder_incarnation, 2, 1}
    first_worker = start_ticket_worker(holder)
    queued_worker = start_ticket_worker(holder)

    for {origin, worker} <- [{first, first_worker}, {queued, queued_worker}] do
      assert {:ok, ^origin} =
               open_mutation(fixture, holder, origin, :session_resume, worker)
    end

    parent = self()
    release = make_ref()
    first_result = %{"operation" => "resume", "status" => "refused"}

    assert {:ok, :admitted} =
             invoke(holder, fn ->
               lease_resume(
                 fixture.owner,
                 first,
                 "resume-expiry-primary",
                 "resume-expiry-command-one",
                 holder_incarnation,
                 writer_epoch,
                 first_worker,
                 fn ->
                   send(parent, {:resume_expiry_primary, self()})

                   receive do
                     ^release -> {:refused, :no_activation, first_result}
                   end
                 end
               )
             end)

    assert_receive {:resume_expiry_primary, first_task}, 500
    queued_invoke = make_ref()

    send(
      holder,
      {:invoke, self(), queued_invoke,
       fn ->
         lease_resume(
           fixture.owner,
           queued,
           "resume-expiry-queued",
           "resume-expiry-command-two",
           holder_incarnation,
           writer_epoch,
           queued_worker,
           fn ->
             send(parent, :unexpected_expired_resume_task)
             {:accepted, :activated, %{"unexpected" => true}}
           end
         )
       end}
    )

    eventually(fn -> ConnectionRegistry.status(fixture.registry).activation_preparations == 1 end)

    assert %{activation_reservations: 2, activation_preparations: 1} =
             ConnectionRegistry.status(fixture.registry)

    Process.sleep(90)
    send(first_task, release)

    assert_receive {:connection_message, ^holder, {:relay_ticket_result, ^first, ^first_result}},
                   500

    # Once the first resume settles, the owner may recheck the queued resume
    # against the lapsed term first or propose the expiry first; this case
    # stands in for the daemon owner, so it resolves a proposed expiry and the
    # queued resume must be refused either way.
    await_queued_after_expiry(fixture, queued_invoke)
    refused = WireRecords.request_error("resume-expiry-queued", "control_not_held")

    assert_receive {:connection_message, ^holder, {:relay_ticket_result, ^queued, ^refused}},
                   500

    refute_receive :unexpected_expired_resume_task, 40

    assert %{
             active_sessions: 0,
             activation_reservations: 0,
             activation_preparations: 0,
             activations_used: 0
           } = ConnectionRegistry.status(fixture.registry)

    stop_connection(holder, fixture.relay, holder_incarnation)
  end

  defp await_queued_after_expiry(fixture, queued_invoke) do
    receive do
      {:invoked, ^queued_invoke, {:ok, :completed}} ->
        :ok

      {:lease_expiry_proposed, expiry_ref, _owner, _incarnation, _session, _holder,
       _holder_incarnation, _epoch} ->
        resolution_ref = make_ref()

        assert :ok =
                 LeaseOwner.request_expiry_resolution(
                   fixture.owner,
                   resolution_ref,
                   fixture.owner_incarnation,
                   expiry_ref
                 )

        assert_receive {:lease_owner_resolution_ack, ^resolution_ref, _, _, :expiry, :ok}, 2_000
        assert_receive {:invoked, ^queued_invoke, {:ok, :completed}}, 2_000
    after
      2_000 -> flunk("the queued resume neither completed nor waited on an expiry")
    end
  end

  test "released owner waits for the final relay row before acknowledged retirement" do
    fixture = start_fixture(unmanaged_owner: true)
    {holder, holder_incarnation, writer_epoch} = grant_first(fixture)
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

    assert :ok =
             release(
               fixture,
               release_origin,
               "retire-release",
               holder,
               holder_incarnation,
               writer_epoch
             )

    assert_receive {:release_proposed, release_ref, ^release_origin, _, _, ^holder_incarnation},
                   500

    assert_receive {:lease_request_go, ^worker, ^release_origin}, 500
    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, :normal}, 500

    settlement_ref = make_ref()
    result = WireRecords.control_released("retire-release")

    assert :ok =
             AdmissionRelay.select_lease_result(
               fixture.relay,
               release_origin,
               fixture.owner,
               fixture.owner_incarnation,
               settlement_ref,
               result
             )

    assert :ok = resolve(fixture, :release, release_ref, :released)
    assert :ok = LeaseOwner.request(fixture.owner, fixture.owner_incarnation, :retire_if_idle)

    assert %{phase: :released, retirement_requested: true} =
             LeaseOwner.status(fixture.owner)

    assert :ok =
             AdmissionRelay.settle_lease_result(
               fixture.relay,
               release_origin,
               settlement_ref
             )

    assert_receive {:lease_owner_retirement_intent, retirement_ref, owner, owner_incarnation,
                    session_id},
                   500

    assert owner == fixture.owner
    assert owner_incarnation == fixture.owner_incarnation
    assert session_id == fixture.session_id
    assert %{phase: :retiring, retirement_requested: true} = LeaseOwner.status(fixture.owner)

    owner_monitor = Process.monitor(fixture.owner)
    assert :ok = LeaseOwner.complete_retirement(fixture.owner, retirement_ref)
    assert_receive {:DOWN, ^owner_monitor, :process, ^owner, :normal}, 500

    assert_receive {:relay_owner_retirement_complete, relay, ^session_id, ^owner,
                    ^owner_incarnation},
                   500

    assert relay == fixture.relay
    stop_connection(holder, fixture.relay, holder_incarnation)
  end

  # Concept: a renewal result the lease owner has already sent to the relay
  # wins over that owner's later death: the holder receives the renewed epoch
  # once and owner loss claims nothing.
  #
  # Technical depth: a relay debug hook parks the relay on the owner's direct
  # `complete_lease_permit` call, the owner is killed while that call is
  # queued, so its `DOWN` necessarily follows the result into the relay.
  test "a renewal result sent before owner death wins the renewal" do
    Process.flag(:trap_exit, true)
    fixture = start_fixture(unmanaged_owner: true)
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

    kill_owner_while_relay_parked(fixture, :complete_lease_permit, renewal_origin)

    assert :ok = renewal_call(fixture, renewal_origin, holder, holder_incarnation)

    assert_receive :owner_killed_while_parked, 500

    assert_receive {:connection_message, ^holder,
                    {:relay_permit_result, ^renewal_origin, renewal}},
                   500

    assert renewal["result"]["writer_epoch"] == Wire.encode_identity(writer_epoch)
    assert renewal["result"]["renewed"] == true
    owner = fixture.owner
    owner_incarnation = fixture.owner_incarnation

    assert_receive {:relay_owner_lost, relay, session_id, ^owner, ^owner_incarnation, []}, 500
    assert relay == fixture.relay
    assert session_id == fixture.session_id
    classify_loss(fixture, holder_incarnation)

    refute_receive {:connection_message, ^holder, {:relay_permit_cancelled, ^renewal_origin, _}},
                   40

    stop_connection(holder, fixture.relay, holder_incarnation)
  end

  # Concept: an owner that dies after claiming a renewal but before sending
  # its result loses the renewal to owner loss: the relay claims the origin
  # and no renewed epoch reaches the holder.
  #
  # Technical depth: the relay is parked on the owner's claim call; the owner
  # is killed while blocked on that claim, so the relay admits the claim and
  # then consumes the exact owner `DOWN` with no direct result ever sent. The
  # holder's classification suppresses its correlated refusal.
  test "owner death before the renewal result selects owner loss" do
    Process.flag(:trap_exit, true)
    fixture = start_fixture(unmanaged_owner: true)
    {holder, holder_incarnation, _writer_epoch} = grant_first(fixture)
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

    kill_owner_while_relay_parked(fixture, :claim_lease_permit, renewal_origin)

    assert :ok = renewal_call(fixture, renewal_origin, holder, holder_incarnation)

    assert_receive :owner_killed_while_parked, 500
    owner = fixture.owner
    owner_incarnation = fixture.owner_incarnation

    assert_receive {:relay_owner_lost, relay, _session_id, ^owner, ^owner_incarnation,
                    [^renewal_origin]},
                   500

    assert relay == fixture.relay
    classify_loss(fixture, holder_incarnation)

    refute_receive {:connection_message, ^holder,
                    {:relay_permit_result, ^renewal_origin, _renewal}},
                   40

    refute_received {:connection_message, ^holder,
                     {:relay_permit_cancelled, ^renewal_origin, _reason}}

    assert %{permits: 0, owner_losses: 0} = AdmissionRelay.status(fixture.relay)
    stop_connection(holder, fixture.relay, holder_incarnation)
  end

  # Concept (T17, F2, first claim order): a permit the daemon owner discards
  # while its claim is awaited takes nothing from the relay's answer: no
  # notice and no decision, even when that answer admits the claim.
  #
  # Technical depth: the relay is parked on the lease owner's claim; the
  # connection is killed, so its `DOWN` follows the claim, and the discard is
  # answered `:discarded` before the claim's `:ok` arrives. The test, acting
  # as the daemon owner, settles the relay's disposition itself.
  test "a discarded awaited permit takes nothing from a later admitting claim" do
    assert_awaited_discard(:claim_admitted)
  end

  # Concept (T17, F2, second claim order): the same holds when the relay
  # answers the claim `connection_lost`.
  #
  # Technical depth: the connection is killed and its disposition received
  # before the claim is sent, so the relay refuses the parked claim.
  test "a discarded awaited permit takes nothing from a later refused claim" do
    assert_awaited_discard(:claim_refused)
  end

  # Concept (T17, F2): a discarded permit still waiting behind an awaited
  # step is removed from the deferred inputs and never claimed.
  test "a discarded deferred permit is never claimed and sends no notice" do
    fixture = start_fixture()
    {holder, holder_incarnation, _writer_epoch} = grant_first(fixture)
    owner = fixture.owner
    owner_incarnation = fixture.owner_incarnation
    {first, first_origin} = opened_observer(fixture)
    {second, second_origin} = opened_observer(fixture)
    park_relay(fixture.relay, &claim_event?(&1, owner, first_origin))

    assert :ok =
             acquire(
               fixture,
               first_origin,
               "first",
               first,
               elem(first_origin, 0),
               now_ms() + 2_000
             )

    assert_receive :relay_parked, 500

    assert :ok =
             acquire(
               fixture,
               second_origin,
               "second",
               second,
               elem(second_origin, 0),
               now_ms() + 2_000
             )

    assert %{awaiting: true, deferred: 1} = LeaseOwner.status(owner)
    discard_ref = make_ref()
    assert :ok = LeaseOwner.request_discard(owner, discard_ref, owner_incarnation, second_origin)

    assert_receive {:lease_owner_resolution_ack, ^discard_ref, ^owner, ^owner_incarnation,
                    :discard, :discarded},
                   500

    assert %{deferred: 0} = LeaseOwner.status(owner)
    send(fixture.relay, :continue_relay)
    assert_settled(fixture, first_origin, :result)
    refute_receive {:lease_permit_settled, ^second_origin, _, _, _}, 100
    Process.exit(second, :kill)
    settle_disposition(fixture, second_origin)
    stop_connection(first, fixture.relay, elem(first_origin, 0))
    stop_connection(holder, fixture.relay, holder_incarnation)
    assert %{permits: 0} = AdmissionRelay.status(fixture.relay)
  end

  # Concept (D2): the lease owner reports a permit's outcome only after the
  # relay's answer, so a refusal the relay could not record because the
  # connection was already lost is reported `:connection_lost`, not `:result`.
  #
  # Technical depth: the relay is parked on the claim and the connection is
  # killed there, so its `DOWN` is handled after the claim is admitted and
  # before the lease owner's `control_held` completion. The worker outlives
  # its connection, so the claim itself is admitted.
  test "a refusal the relay answers connection_lost is noticed as connection_lost" do
    fixture = start_fixture()
    {holder, holder_incarnation, _writer_epoch} = grant_first(fixture)
    owner = fixture.owner
    {observer, origin} = opened_observer(fixture, :detached)
    park_relay(fixture.relay, &claim_event?(&1, owner, origin))
    assert :ok = acquire(fixture, origin, "refused", observer, elem(origin, 0), now_ms() + 2_000)
    assert_receive :relay_parked, 500
    kill_connection(observer)
    send(fixture.relay, :continue_relay)
    assert_settled(fixture, origin, :connection_lost)
    settle_disposition(fixture, origin)
    stop_connection(holder, fixture.relay, holder_incarnation)
    assert %{permits: 0} = AdmissionRelay.status(fixture.relay)
  end

  # Concept (T25): a lease owner acknowledges a resolution before any relay
  # work the resolution makes due, so a parked relay cannot delay the daemon
  # owner's step.
  #
  # Technical depth: a release is proposed and an observer's acquire waits
  # behind it. The relay is parked on the next completion; cancelling the
  # release restores the holder, which makes the waiter's `control_held`
  # completion due. The acknowledgement arrives while the relay stays parked.
  test "a resolution is acknowledged while the completion it makes due is parked" do
    fixture = start_fixture()
    {holder, holder_incarnation, writer_epoch} = grant_first(fixture)
    owner = fixture.owner
    owner_incarnation = fixture.owner_incarnation
    release_ref = propose_release(fixture, holder, holder_incarnation, writer_epoch)
    {observer, origin} = opened_observer(fixture)
    assert :ok = acquire(fixture, origin, "behind", observer, elem(origin, 0), now_ms() + 2_000)
    assert :ok = await_waiters(fixture, 1)

    park_relay(fixture.relay, fn
      {:in, {:"$gen_call", {^owner, _tag}, request}} ->
        elem(request, 0) == :complete_lease_permit

      _event ->
        false
    end)

    operation_ref = make_ref()

    assert :ok =
             LeaseOwner.request_release_resolution(
               owner,
               operation_ref,
               owner_incarnation,
               release_ref,
               :cancelled
             )

    assert_receive {:lease_owner_resolution_ack, ^operation_ref, ^owner, ^owner_incarnation,
                    :release, :ok},
                   500

    assert_receive :relay_parked, 500
    send(fixture.relay, :continue_relay)
    assert_settled(fixture, origin, :result)
    stop_connection(observer, fixture.relay, elem(origin, 0))
  end

  # Concept (T11): a lease owner awaiting the registry's `prepare_resume`
  # still restores its lease within its own step.
  #
  # Technical depth: a release is proposed; the holder's resume is then
  # awaited on a suspended registry, and the release's cancellation is
  # acknowledged while the registry stays suspended.
  test "a lease owner awaiting prepare_resume still restores its lease" do
    fixture = start_fixture()
    {holder, holder_incarnation, writer_epoch} = grant_first(fixture)
    owner = fixture.owner
    owner_incarnation = fixture.owner_incarnation
    release_ref = propose_release(fixture, holder, holder_incarnation, writer_epoch)
    origin = {holder_incarnation, 5, 1}
    worker = start_ticket_worker(holder)
    assert {:ok, ^origin} = open_mutation(fixture, holder, origin, :session_resume, worker)
    :sys.suspend(fixture.registry)

    resume =
      invoke_async(holder, fn ->
        lease_resume(
          owner,
          origin,
          "resume-awaiting",
          "resume-awaiting-command",
          holder_incarnation,
          writer_epoch,
          worker,
          fn -> {:accepted, :activated, %{"resumed" => true}} end
        )
      end)

    assert :ok = eventually(fn -> LeaseOwner.status(owner).awaiting end)
    operation_ref = make_ref()

    assert :ok =
             LeaseOwner.request_release_resolution(
               owner,
               operation_ref,
               owner_incarnation,
               release_ref,
               :cancelled
             )

    assert_receive {:lease_owner_resolution_ack, ^operation_ref, ^owner, ^owner_incarnation,
                    :release, :ok},
                   500

    assert %{phase: :held, held: true, awaiting: true} = LeaseOwner.status(owner)
    :sys.resume(fixture.registry)
    Task.await(resume, 2_000)
  end

  # Concept (T19, F6): an expiry that falls due while a promotion is awaited
  # is proposed by the drain once the mutation settles, and a later acquire
  # is then granted.
  #
  # Technical depth: the relay is parked on the promotion across the lease
  # deadline, so the expiry timer fires while the step is awaited and is not
  # re-armed. The mutation's task is refused, so it extends nothing, and no
  # acquire waits, so the expiry can come only from the drain.
  test "an expiry due during an awaited promotion is proposed by the drain" do
    lease_term_ms = 200
    fixture = start_fixture(lease_term_ms: lease_term_ms)
    {holder, holder_incarnation, writer_epoch} = grant_first(fixture, lease_term_ms)
    owner = fixture.owner
    assert :ok = attach(fixture, holder, holder_incarnation, "expiry-drain-attachment")
    origin = {holder_incarnation, 1, 1}
    worker = start_ticket_worker(holder)
    assert {:ok, ^origin} = open_mutation(fixture, holder, origin, :session_prompt, worker)
    {successor, successor_origin} = opened_observer(fixture)
    park_relay(fixture.relay, &promote_event?(&1, owner))
    parent = self()

    mutation =
      invoke_async(holder, fn ->
        lease_mutate(
          owner,
          origin,
          :session_prompt,
          "expiry-drain-mutation",
          holder_incarnation,
          writer_epoch,
          worker,
          fn ->
            send(parent, {:expiry_drain_task, self()})

            receive do
              :complete -> {:refused, %{"refused" => true}}
            end
          end
        )
      end)

    assert_receive :relay_parked, 500
    Process.sleep(lease_term_ms + 100)
    send(fixture.relay, :continue_relay)
    assert {:ok, :admitted} = Task.await(mutation, 1_000)
    assert_receive {:expiry_drain_task, task}, 500
    send(task, :complete)

    assert_receive {:lease_expiry_proposed, expiry_ref, ^owner, _, _, ^holder,
                    ^holder_incarnation, ^writer_epoch},
                   1_000

    assert :ok = resolve(fixture, :expiry, expiry_ref)

    assert :ok =
             acquire(
               fixture,
               successor_origin,
               "expiry-successor",
               successor,
               elem(successor_origin, 0),
               now_ms() + 5_000
             )

    assert_receive {:lease_grant_proposed, _grant_ref, ^successor_origin, ^owner, _, _,
                    ^successor, _, _epoch, _deadline},
                   1_000
  end

  # Concept: a relay that leaves a lease owner's request unanswered for five
  # seconds while serving is reported once to the daemon owner, which names
  # the failure; the lease owner itself keeps waiting for the answer.
  @tag timeout: 30_000
  test "an unanswered relay request is reported once to the daemon owner" do
    fixture = start_fixture()
    {holder, holder_incarnation, _writer_epoch} = grant_first(fixture)
    owner = fixture.owner
    owner_incarnation = fixture.owner_incarnation
    {observer, origin} = opened_observer(fixture)
    park_relay(fixture.relay, &claim_event?(&1, owner, origin))
    started = now_ms()

    assert :ok =
             acquire(fixture, origin, "unanswered", observer, elem(origin, 0), now_ms() + 20_000)

    assert_receive :relay_parked, 500
    assert_receive {:lease_owner_relay_unanswered, ^owner, ^owner_incarnation}, 6_000
    assert now_ms() - started >= 4_900
    refute_receive {:lease_owner_relay_unanswered, _, _}, 300
    assert Process.alive?(owner)
    send(fixture.relay, :continue_relay)
    assert_settled(fixture, origin, :result)
    stop_connection(observer, fixture.relay, elem(origin, 0))
    stop_connection(holder, fixture.relay, holder_incarnation)
  end

  # Concept: a mutation is in flight from the moment its promotion is sent,
  # so its classification and the relay's settlement are kept even when they
  # arrive before the promotion's answer, and it settles once admitted.
  #
  # Technical depth: the relay is parked on the promotion; the task's
  # classification and the ticket settlement are delivered first, naming the
  # task reference the lease owner recorded. The real task is held, so only
  # those early messages can settle the mutation.
  test "a classification arriving before the promotion answer is kept" do
    fixture = start_fixture()
    {holder, holder_incarnation, writer_epoch} = grant_first(fixture)
    owner = fixture.owner
    owner_incarnation = fixture.owner_incarnation
    relay = fixture.relay
    assert :ok = attach(fixture, holder, holder_incarnation, "early-classification")
    origin = {holder_incarnation, 1, 1}
    worker = start_ticket_worker(holder)
    assert {:ok, ^origin} = open_mutation(fixture, holder, origin, :session_prompt, worker)
    park_relay(relay, &promote_event?(&1, owner))
    parent = self()

    mutation =
      invoke_async(holder, fn ->
        lease_mutate(
          owner,
          origin,
          :session_prompt,
          "early-classification",
          holder_incarnation,
          writer_epoch,
          worker,
          fn ->
            send(parent, {:early_task, self()})

            receive do
              :complete -> {:accepted, %{"accepted" => true}}
            end
          end
        )
      end)

    assert_receive :relay_parked, 500
    task_ref = :sys.get_state(owner).in_flight |> Map.fetch!(origin) |> Map.fetch!(:task_ref)
    send(owner, {:lease_mutation_classified, task_ref, origin, :accepted})
    send(owner, {:relay_lease_ticket_settled, relay, origin, owner_incarnation})
    send(relay, :continue_relay)
    assert {:ok, :admitted} = Task.await(mutation, 1_000)
    assert :ok = eventually(fn -> LeaseOwner.status(owner).in_flight == 0 end)
    assert_receive {:early_task, task}, 500
    send(task, :complete)
    stop_connection(holder, relay, holder_incarnation)
  end

  # Concept (review item 7): a request this lease owner cannot take in its
  # current phase is still answered through the relay, `internal_failure`,
  # and reported as a result; no permit is left undecided.
  #
  # Technical depth: the lease owner is registered with the relay but never
  # activated, so it is still `:starting` when the request arrives.
  test "a request outside the active phase is answered through the relay" do
    fixture = start_fixture(activate: false)
    {observer, origin} = opened_observer(fixture)
    assert %{phase: :starting} = LeaseOwner.status(fixture.owner)
    assert :ok = acquire(fixture, origin, "inactive", observer, elem(origin, 0), now_ms() + 2_000)
    assert_settled(fixture, origin, :result)

    assert_receive {:connection_message, ^observer,
                    {:relay_permit_result, ^origin, %{"code" => "internal_failure"}}},
                   500
  end

  # Concept (review item 7): a permit whose client the relay already answered
  # — its request worker was lost — is reported as a result, not as an
  # undecided permit.
  test "a permit the relay already answered is noticed as a result" do
    fixture = start_fixture()
    {holder, holder_incarnation, _writer_epoch} = grant_first(fixture)
    {observer, origin} = opened_observer(fixture, :detached)

    [{_origin, %{worker_pid: worker}}] =
      Enum.filter(:sys.get_state(fixture.relay).permits, fn {id, _permit} -> id == origin end)

    monitor = Process.monitor(worker)
    Process.exit(worker, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^worker, :killed}, 500

    assert_receive {:connection_message, ^observer,
                    {:relay_permit_failed, ^origin, :worker_lost}},
                   500

    assert :ok =
             acquire(fixture, origin, "worker-lost", observer, elem(origin, 0), now_ms() + 2_000)

    assert_settled(fixture, origin, :result)
    stop_connection(holder, fixture.relay, holder_incarnation)
  end

  # Concept (review item 7): a record the relay refuses as invalid is
  # replaced once by the fixed `internal_failure` record, so its client is
  # still answered.
  #
  # Technical depth: driven directly against the lease owner's state with an
  # awaited completion answered `invalid_result`.
  test "a completion refused as an invalid record is retried with the fixed failure" do
    fixture = start_fixture()
    state = :sys.get_state(fixture.owner)
    request = make_ref()
    permit_id = {incarnation(), 0, 1}
    result = WireRecords.control_error("invalid-record", "control_held")

    state = %{
      state
      | awaiting: %{request: request, step: {:complete, permit_id, nil, result}, timer: nil}
    }

    assert {:noreply, retried} =
             LeaseOwner.handle_info({[:alias | request], {:error, :invalid_result}}, state)

    fallback = WireRecords.request_error("invalid-record", "internal_failure")
    assert %{step: {:complete, ^permit_id, nil, ^fallback}} = retried.awaiting
  end

  # Concept (review item 8): a resume whose registry is lost during its
  # promotion may already have started, so its outcome is reported unknown
  # and the connection writes no refusal for it.
  #
  # Technical depth: a registry debug hook parks the registry on the resume
  # promotion and the registry is killed there.
  test "a resume promotion whose registry is lost reports its outcome unknown" do
    Process.flag(:trap_exit, true)
    fixture = start_fixture()
    {holder, holder_incarnation, writer_epoch} = grant_first(fixture)
    origin = {holder_incarnation, 1, 1}
    worker = start_ticket_worker(holder)
    assert {:ok, ^origin} = open_mutation(fixture, holder, origin, :session_resume, worker)
    test_pid = self()

    :ok =
      :sys.install(
        fixture.registry,
        {fn
           :waiting, {:in, {:"$gen_call", _from, request}}, _state
           when elem(request, 0) == :promote_resume ->
             send(test_pid, :promotion_parked)

             receive do
               :never -> :done
             end

           hook_state, _event, _state ->
             hook_state
         end, :waiting}
      )

    resume =
      invoke_async(holder, fn ->
        lease_resume(
          fixture.owner,
          origin,
          "resume-registry-lost",
          "resume-registry-lost-command",
          holder_incarnation,
          writer_epoch,
          worker,
          fn -> {:accepted, :activated, %{"resumed" => true}} end
        )
      end)

    assert_receive :promotion_parked, 1_000
    Process.exit(fixture.registry, :kill)
    assert {:error, :promotion_outcome_unknown} = Task.await(resume, 2_000)
  end

  defp assert_awaited_discard(order) do
    fixture = start_fixture()
    {holder, holder_incarnation, _writer_epoch} = grant_first(fixture)
    owner = fixture.owner
    owner_incarnation = fixture.owner_incarnation
    {observer, origin} = opened_observer(fixture, :detached)
    park_relay(fixture.relay, &claim_event?(&1, owner, origin))
    report_completions(fixture.relay, owner, origin)
    if order == :claim_refused, do: kill_connection(observer)

    assert :ok = acquire(fixture, origin, "awaited", observer, elem(origin, 0), now_ms() + 2_000)
    assert_receive :relay_parked, 500
    if order == :claim_admitted, do: kill_connection(observer)
    discard_ref = make_ref()
    assert :ok = LeaseOwner.request_discard(owner, discard_ref, owner_incarnation, origin)

    assert_receive {:lease_owner_resolution_ack, ^discard_ref, ^owner, ^owner_incarnation,
                    :discard, :discarded},
                   500

    send(fixture.relay, :continue_relay)
    settle_disposition(fixture, origin)
    assert %{awaiting: false, deferred: 0} = LeaseOwner.status(owner)
    refute_receive {:lease_permit_settled, ^origin, _, _, _}, 100
    refute_received {:relay_saw_completion, ^origin}
    stop_connection(holder, fixture.relay, holder_incarnation)
    assert %{permits: 0} = AdmissionRelay.status(fixture.relay)
  end

  # Technical depth: a second relay debug hook reports every completion the
  # lease owner sends for `origin`, so a decision made for a discarded
  # permit is observable even when the relay refuses it.
  defp report_completions(relay, owner, origin) do
    test_pid = self()

    :ok =
      :sys.install(
        relay,
        {fn
           reported, {:in, {:"$gen_call", {^owner, _tag}, request}}, _proc_state
           when elem(request, 0) == :complete_lease_permit and elem(request, 1) == origin ->
             send(test_pid, {:relay_saw_completion, origin})
             reported

           reported, _event, _proc_state ->
             reported
         end, :reporting}
      )
  end

  defp start_detached_worker(origin) do
    parent = self()
    worker_incarnation = incarnation()

    worker =
      spawn(fn ->
        receive do
          {:relay_go, ^origin, ^worker_incarnation} ->
            send(parent, {:lease_request_go, self(), origin})
        after
          5_000 -> :ok
        end
      end)

    {worker, worker_incarnation}
  end

  defp kill_connection(connection) do
    monitor = Process.monitor(connection)
    Process.exit(connection, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^connection, :killed}, 500
  end

  # Technical depth: an observer connection with an open existing-owner
  # acquire permit whose worker has not yet been told to go.
  defp opened_observer(fixture, worker_kind \\ :linked) do
    connection_incarnation = incarnation()
    connection = start_connection(fixture.relay, connection_incarnation)
    origin = {connection_incarnation, 0, 1}

    {worker, worker_incarnation} =
      if worker_kind == :detached,
        do: start_detached_worker(origin),
        else: start_worker(connection, origin)

    assert {:ok, ^origin} =
             open_existing_acquire(
               fixture,
               connection,
               connection_incarnation,
               origin,
               worker,
               worker_incarnation
             )

    {connection, origin}
  end

  defp propose_release(fixture, holder, holder_incarnation, writer_epoch) do
    origin = {holder_incarnation, 9, 1}
    {worker, worker_incarnation} = start_worker(holder, origin)

    assert {:ok, ^origin} =
             open_release(fixture, holder, holder_incarnation, origin, worker, worker_incarnation)

    assert :ok =
             release(
               fixture,
               origin,
               "proposed-release",
               holder,
               holder_incarnation,
               writer_epoch
             )

    assert_receive {:release_proposed, release_ref, ^origin, _, _, ^holder_incarnation}, 500
    release_ref
  end

  defp claim_event?(event, owner, origin),
    do: match?({:in, {:"$gen_call", {^owner, _tag}, {:claim_lease_permit, ^origin, _, _}}}, event)

  defp promote_event?(event, owner) do
    match?(
      {:in, {:"$gen_call", {^owner, _tag}, request}}
      when elem(request, 0) == :promote_lease_ticket,
      event
    )
  end

  # Concept: the relay can be held at one exact debug event. Technical depth:
  # the hook parks on the first matching event, returns once released and
  # then stays inert.
  defp park_relay(relay, matcher) do
    test_pid = self()

    :ok =
      :sys.install(
        relay,
        {fn
           :waiting, event, _proc_state ->
             if matcher.(event) do
               send(test_pid, :relay_parked)

               receive do
                 :continue_relay -> :done
               end
             else
               :waiting
             end

           :done, _event, _proc_state ->
             :done
         end, :waiting}
      )
  end

  defp invoke_async(connection, operation),
    do: Task.async(fn -> invoke(connection, operation) end)

  defp settle_disposition(fixture, origin) do
    assert_receive {:relay_lease_disposition, _relay, ^origin, :connection_lost, settlement_ref,
                    _class, _session_id, _owner, _owner_incarnation, _start_op_ref},
                   500

    assert :ok =
             AdmissionRelay.settle_lease_disposition(
               fixture.relay,
               origin,
               :connection_lost,
               settlement_ref
             )
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

  defp lease_resume(owner, origin, request_id, command_id, incarnation, epoch, worker, task),
    do:
      descriptor_call(
        owner,
        {:resume, origin, request_id, command_id, incarnation, epoch, worker, task}
      )

  defp start_fixture(options \\ []) do
    daemon_incarnation = incarnation()
    session_id = Keyword.get(options, :session_id, "session")

    relay =
      start_supervised!(
        {AdmissionRelay,
         owner: self(),
         owner_incarnation: daemon_incarnation,
         admission_wait_ms: Keyword.get(options, :admission_wait_ms, 1_000)}
      )

    registry =
      start_supervised!({ConnectionRegistry, owner: self(), initialize_deadline_ms: 1_000})

    registry_incarnation = incarnation()
    assert :ok = AdmissionRelay.register_registry(relay, registry, registry_incarnation)
    assert :ok = ConnectionRegistry.bind_relay(registry, relay, registry_incarnation)

    owner_incarnation = incarnation()

    owner_options = [
      daemon_owner: self(),
      relay: relay,
      registry: registry,
      session_id: session_id,
      owner_incarnation: owner_incarnation,
      lease_term_ms: Keyword.get(options, :lease_term_ms, 30_000)
    ]

    owner =
      if Keyword.get(options, :unmanaged_owner, false) do
        {:ok, owner} = LeaseOwner.start_link(owner_options)

        on_exit(fn ->
          try do
            if Process.alive?(owner), do: GenServer.stop(owner)
          catch
            :exit, _reason -> :ok
          end
        end)

        owner
      else
        start_supervised!({LeaseOwner, owner_options})
      end

    assert :ok =
             AdmissionRelay.register_lease_owner(
               relay,
               session_id,
               owner,
               owner_incarnation
             )

    if Keyword.get(options, :activate, true),
      do: assert(:ok = LeaseOwner.request(owner, owner_incarnation, :activate))

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

    assert :ok =
             first_acquire(
               fixture,
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

    assert :ok = resolve(fixture, :grant, grant_ref, :granted, now_ms())
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
               lease_mutate(
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

  # Concept: the lease owner can be killed at an exact point in its exchange
  # with the relay. Technical depth: a relay debug hook parks the relay on the
  # owner's first matching call for `origin`; a separate process kills the
  # owner while the relay is parked, then releases the relay, so the owner's
  # `DOWN` is queued behind that call.
  defp kill_owner_while_relay_parked(fixture, call, origin) do
    test_pid = self()
    owner = fixture.owner

    killer =
      spawn(fn ->
        receive do
          {:relay_parked, relay} ->
            monitor = Process.monitor(owner)
            Process.exit(owner, :kill)

            receive do
              {:DOWN, ^monitor, :process, ^owner, :killed} -> :ok
            end

            send(relay, :continue_parked_call)
            send(test_pid, :owner_killed_while_parked)
        end
      end)

    :ok =
      :sys.install(
        fixture.relay,
        {fn
           :waiting, {:in, {:"$gen_call", _from, request}}, _proc_state
           when is_tuple(request) and tuple_size(request) > 1 and elem(request, 0) == call and
                  elem(request, 1) == origin ->
             send(killer, {:relay_parked, self()})

             receive do
               :continue_parked_call -> :done
             end

           :waiting, _event, _proc_state ->
             :waiting
         end, :waiting}
      )
  end

  defp renewal_call(fixture, origin, holder, holder_incarnation),
    do: acquire(fixture, origin, "renew-race", holder, holder_incarnation, now_ms() + 1_000)

  # Concept: this test process is the daemon owner; it sends each lease
  # request without waiting and observes the answer the lease owner sends.
  defp first_acquire(fixture, origin, request_id, connection, incarnation, deadline),
    do:
      lease_request(
        fixture,
        {:first_acquire, origin, request_id, connection, incarnation, deadline}
      )

  defp acquire(fixture, origin, request_id, connection, incarnation, deadline),
    do: lease_request(fixture, {:acquire, origin, request_id, connection, incarnation, deadline})

  defp release(fixture, origin, request_id, connection, incarnation, writer_epoch),
    do:
      lease_request(
        fixture,
        {:release, origin, request_id, connection, incarnation, writer_epoch}
      )

  defp attach(fixture, connection, incarnation, attachment_id),
    do: attachment(fixture, :opened, connection, incarnation, attachment_id)

  defp detach(fixture, connection, incarnation, attachment_id),
    do: attachment(fixture, :closed, connection, incarnation, attachment_id)

  defp attachment(fixture, kind, connection, incarnation, attachment_id) do
    ack_ref = make_ref()
    owner = fixture.owner
    owner_incarnation = fixture.owner_incarnation

    :ok =
      lease_request(fixture, {:attachment, ack_ref, kind, connection, incarnation, attachment_id})

    assert_receive {:lease_attachment_ack, ^ack_ref, ^owner, ^owner_incarnation}, 500
    :ok
  end

  defp lease_request(fixture, request),
    do: LeaseOwner.request(fixture.owner, fixture.owner_incarnation, request)

  defp assert_settled(fixture, permit_id, kind) do
    owner = fixture.owner
    owner_incarnation = fixture.owner_incarnation
    assert_receive {:lease_permit_settled, ^permit_id, ^owner, ^owner_incarnation, ^kind}, 500
  end

  defp await_waiters(fixture, count) do
    eventually(fn -> LeaseOwner.status(fixture.owner).waiting_acquires == count end)
    :ok
  end

  # Technical depth: a resolution is a message the lease owner acknowledges
  # with its exact result.
  defp resolve(fixture, kind, transition_ref, disposition, granted_at \\ nil) do
    operation_ref = make_ref()
    owner = fixture.owner
    owner_incarnation = fixture.owner_incarnation

    :ok =
      case kind do
        :grant ->
          LeaseOwner.request_grant_resolution(
            owner,
            operation_ref,
            owner_incarnation,
            transition_ref,
            disposition,
            granted_at
          )

        :release ->
          LeaseOwner.request_release_resolution(
            owner,
            operation_ref,
            owner_incarnation,
            transition_ref,
            disposition
          )
      end

    assert_receive {:lease_owner_resolution_ack, ^operation_ref, ^owner, ^owner_incarnation,
                    ^kind, result},
                   500

    result
  end

  defp resolve(fixture, :expiry, expiry_ref) do
    operation_ref = make_ref()
    owner = fixture.owner
    owner_incarnation = fixture.owner_incarnation

    :ok =
      LeaseOwner.request_expiry_resolution(owner, operation_ref, owner_incarnation, expiry_ref)

    assert_receive {:lease_owner_resolution_ack, ^operation_ref, ^owner, ^owner_incarnation,
                    :expiry, result},
                   500

    result
  end

  defp classify_loss(fixture, holder_incarnation) do
    relay = fixture.relay
    owner = fixture.owner
    owner_incarnation = fixture.owner_incarnation
    assert_receive {:relay_owner_loss_ready, ^relay, ^owner, ^owner_incarnation}, 500
    classification_ref = make_ref()

    assert :ok =
             AdmissionRelay.classify_owner_loss(
               relay,
               classification_ref,
               fixture.daemon_incarnation,
               fixture.session_id,
               owner,
               owner_incarnation,
               holder_incarnation
             )

    assert_receive {:relay_owner_loss_classified_ack, ^relay, ^classification_ref, _session_id,
                    ^owner, ^owner_incarnation},
                   500
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
