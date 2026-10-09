Code.require_file("support/configured_genesis_helper.exs", __DIR__)
Code.require_file("support/m1_runtime_helper.exs", __DIR__)

defmodule Loopex.ArtifactTransferCustodyTest do
  use ExUnit.Case, async: true

  alias Loopex.ArtifactStore
  alias Loopex.M1RuntimeTestStore, as: TestStore
  alias Loopex.Runtime
  alias LoopexProtocol.Canonical

  # Concept: controlled callbacks expose Core ordering, not physical Store proof.
  # Technical depth: each real original callback actor waits for the test's
  # explicit reply. Local's separate conformance cases own descriptor/scratch
  # retirement. This adapter records no invented filesystem observation.
  defmodule ControlledArtifacts do
    def reserve_transfer(test, request, context), do: call(test, :reserve, {request, context})
    def open_transfer(test, request, context), do: call(test, :open, {request, context})
    def read_transfer(test, transfer, length), do: call(test, :read, {transfer, length})
    def close_transfer(test, selector), do: call(test, selector.action, selector)

    defp call(test, operation, arguments) do
      ref = make_ref()
      send(test, {:artifact_callback, operation, self(), ref, arguments})

      receive do
        {:artifact_callback_reply, ^ref, result} -> result
      end
    end
  end

  test "reservation and verification remain responsive and the original custodian owns reads" do
    fixture = fixture()
    data = data(fixture.attachment.session_id)
    caller = Task.async(fn -> Loopex.open_artifact_transfer(fixture.attachment, data.request) end)
    reserve = callback(:reserve)
    {routed, context} = reserve.arguments
    assert ArtifactStore.valid_transfer_request?(routed)
    assert routed.session_id === fixture.attachment.session_id
    assert ArtifactStore.valid_open_context?(context)
    assert {:ok, %{status: :active}} = Loopex.attachment_status(fixture.attachment)
    reply(reserve, {:ok, %{transfer_ref: context.transfer_ref}})
    open = callback(:open)
    assert open.pid === reserve.pid
    assert open.arguments === reserve.arguments
    assert {:ok, %{status: :active}} = Loopex.attachment_status(fixture.attachment)
    opened = opened(data, context)
    reply(open, {:ok, opened})
    assert {:ok, compact} = Task.await(caller, 1_000)

    assert compact === %{
             transfer_ref: context.transfer_ref,
             total_size: 3,
             window_start: 0,
             window_length: 3,
             object_digest: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
             object_reference: %{
               digest: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
               size: 3,
               locator: "object:fixture"
             },
             use_reference: %{
               digest: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
               size: 3,
               locator: "object:fixture",
               media_type: "application/octet-stream",
               role: "tool_output",
               use_canonicalization_version: "loopex.canonical.v1",
               use_digest: binary_part(data.request.use_locator, 4, 64),
               use_locator: data.request.use_locator
             }
           }

    refute Map.has_key?(compact, :work)
    refute Map.has_key?(compact, :use)
    refute Map.has_key?(compact.use_reference, :metadata)
    entry = entry(fixture, context.transfer_ref)
    assert entry.custodian === reserve.pid
    assert Process.alive?(entry.custodian)
    assert Process.alive?(entry.observer)
    assert entry.invocation === :idle

    reader =
      Task.async(fn ->
        Loopex.read_artifact_chunk(fixture.attachment, context.transfer_ref, 100_000)
      end)

    read = callback(:read)
    assert read.pid === reserve.pid
    assert read.arguments === {opened.transfer, 100_000}
    chunk = %{offset: 0, bytes: "abc", chunk_digest: digest("abc")}
    reply(read, {:ok, chunk})
    assert {:ok, ^chunk} = Task.await(reader, 1_000)
    assert ledger(fixture).transfer_debit === 1_048_579
    assert ledger(fixture).transfer_reserved === 0

    complete =
      Task.async(fn ->
        Loopex.read_artifact_chunk(fixture.attachment, context.transfer_ref, 1)
      end)

    read = callback(:read)
    reply(read, {:ok, :complete})
    assert {:ok, :complete} = Task.await(complete, 1_000)
    assert entry(fixture, context.transfer_ref).phase === :live
    assert ledger(fixture).transfer_debit === 1_048_579
    close_and_join(fixture, context, opened.work)
    assert ledger(fixture).transfer_debit === 1_048_579
  end

  test "detach before reservation acknowledgement revokes permission and retains the same observer" do
    fixture = fixture()
    data = data(fixture.attachment.session_id)
    caller = Task.async(fn -> Loopex.open_artifact_transfer(fixture.attachment, data.request) end)
    reserve = callback(:reserve)
    {_request, context} = reserve.arguments
    assert :ok = Loopex.detach(fixture.attachment)
    first = callback(:retire)
    original_selector = first.arguments
    assert original_selector.open_deadline_ms === context.open_deadline_ms
    assert {:error, %{reason: :cancelled, cleanup: :unproved}} = Task.await(caller, 1_000)
    assert entry(fixture, context.transfer_ref).observation === :retire
    reply(first, {:unregistered, %{transfer_ref: context.transfer_ref}})
    await(fn -> entry(fixture, context.transfer_ref).observation === :idle end)
    assert entry(fixture, context.transfer_ref).invocation === :reserve
    assert map_size(state(fixture).artifact_transfers) === 1
    reply(reserve, {:ok, %{transfer_ref: context.transfer_ref}})
    second = callback(:retire)
    assert second.pid === first.pid
    assert second.arguments === original_selector
    refute_received {:artifact_callback, :open, _, _, _}
    receipt = receipt(context, zero_work())
    reply(second, {:retired, receipt})
    ack = callback(:acknowledge)
    assert ack.pid === first.pid

    assert ack.arguments === %{
             action: :acknowledge,
             transfer_ref: context.transfer_ref,
             receipt_ref: receipt.receipt_ref
           }

    reply(ack, :ok)
    await_released(fixture, context.transfer_ref)
    assert now() < original_selector.close_deadline_ms
    assert ledger(fixture).transfer_debit === 1_048_576
    assert ledger(fixture).transfer_reserved === 0
  end

  test "conclusive never-reserved refusal joins both original actors without receipt or ack" do
    fixture = fixture()
    data = data(fixture.attachment.session_id)
    caller = Task.async(fn -> Loopex.open_artifact_transfer(fixture.attachment, data.request) end)
    reserve = callback(:reserve)
    {_request, context} = reserve.arguments
    original = entry(fixture, context.transfer_ref)
    custodian_monitor = Process.monitor(original.custodian)
    observer_monitor = Process.monitor(original.observer)

    reply(
      reserve,
      {:error,
       %{
         reason: :transfer_limit_reached,
         transfer_ref: context.transfer_ref,
         state: :not_reserved
       }}
    )

    assert {:error, %{reason: :transfer_limit_reached, cleanup: :unproved}} =
             Task.await(caller, 1_000)

    assert_receive {:DOWN, ^custodian_monitor, :process, _, :normal}, 1_000
    assert_receive {:DOWN, ^observer_monitor, :process, _, :normal}, 1_000
    await_released(fixture, context.transfer_ref)
    assert state(fixture).artifact_transfers === %{}
    refute_received {:artifact_callback, :open, _, _, _}
    refute_received {:artifact_callback, :retire, _, _, _}
    refute_received {:artifact_callback, :acknowledge, _, _, _}
    assert ledger(fixture).transfer_debit === 1_048_576
  end

  test "uncertainty is never a not-reserved proof and unavailable work keeps conservative credit" do
    fixture = fixture()
    data = data(fixture.attachment.session_id)
    caller = Task.async(fn -> Loopex.open_artifact_transfer(fixture.attachment, data.request) end)
    reserve = callback(:reserve)
    {_request, context} = reserve.arguments
    reply(reserve, {:error, :transfers_unavailable})
    retire = callback(:retire)
    assert entry(fixture, context.transfer_ref).not_reserved === false
    assert ledger(fixture).transfer_reserved === 134_348_801

    assert {:error, %{reason: :transfers_unavailable, cleanup: :unproved}} =
             Task.await(caller, 1_000)

    assert entry(fixture, context.transfer_ref).observation === :retire
    reply(retire, {:error, :cleanup_unproved})
    await(fn -> entry(fixture, context.transfer_ref).observation === :idle end)
    original = entry(fixture, context.transfer_ref)
    assert :ok = Loopex.detach(fixture.attachment)
    observe = callback(:retire)
    assert observe.pid === retire.pid
    assert observe.arguments === retire.arguments
    reply(observe, {:retired, receipt(context, :unavailable)})
    ack = callback(:acknowledge)
    reply(ack, :ok)
    await_released(fixture, context.transfer_ref)
    assert original.observer === observe.pid
    assert ledger(fixture).transfer_debit === 0
    assert ledger(fixture).transfer_reserved === 134_348_801

    {:ok, replacement} =
      Loopex.attach(fixture.runtime, fixture.attachment.session_id, after_event_sequence: 0)

    assert ledger(fixture).transfer_reserved === 134_348_801
    assert replacement.attachment_id !== fixture.attachment.attachment_id
  end

  test "receipt cannot be acknowledged before the original read invocation finishes" do
    fixture = fixture()
    {context, opened} = open(fixture)

    reader =
      Task.async(fn ->
        Loopex.read_artifact_chunk(fixture.attachment, context.transfer_ref, 3)
      end)

    read = callback(:read)

    closer =
      Task.async(fn ->
        Loopex.close_artifact_transfer(fixture.attachment, context.transfer_ref)
      end)

    retire = callback(:retire)
    reply(retire, {:retired, receipt(context, opened.work)})
    assert {:error, :unknown_transfer} = Task.await(reader, 1_000)
    assert entry(fixture, context.transfer_ref).receipt !== nil
    assert entry(fixture, context.transfer_ref).invocation !== :idle
    refute_received {:artifact_callback, :acknowledge, _, _, _}
    reply(read, {:ok, %{offset: 0, bytes: "abc", chunk_digest: digest("abc")}})
    ack = callback(:acknowledge)
    assert ack.pid === retire.pid
    assert entry(fixture, context.transfer_ref).invocation === :idle
    assert map_size(state(fixture).artifact_transfers) === 1
    assert {:ok, %{status: :active}} = Loopex.attachment_status(fixture.attachment)
    reply(ack, :ok)
    assert :ok = Task.await(closer, 1_000)
    assert state(fixture).artifact_transfers === %{}
    assert ledger(fixture).transfer_debit === 1_048_579
    assert now() < retire.arguments.close_deadline_ms
  end

  test "repeated close reuses the original observer and the first cleanup cutoff" do
    fixture = fixture()
    {context, opened} = open(fixture)

    closer =
      Task.async(fn ->
        Loopex.close_artifact_transfer(fixture.attachment, context.transfer_ref)
      end)

    first = callback(:retire)
    reply(first, {:error, :cleanup_unproved})
    assert {:error, :cleanup_unproved} = Task.await(closer, 1_000)
    original = entry(fixture, context.transfer_ref)
    assert Process.alive?(original.observer)

    closer =
      Task.async(fn ->
        Loopex.close_artifact_transfer(fixture.attachment, context.transfer_ref)
      end)

    second = callback(:retire)
    assert second.pid === first.pid
    assert second.arguments === first.arguments
    assert entry(fixture, context.transfer_ref).observer_monitor === original.observer_monitor
    reply(second, {:retired, receipt(context, opened.work)})
    ack = callback(:acknowledge)
    reply(ack, :ok)
    assert :ok = Task.await(closer, 1_000)
    assert now() < first.arguments.close_deadline_ms
    assert state(fixture).artifact_transfers === %{}
  end

  test "pending entries consume original connection and runtime headroom before any I/O" do
    fixture = fixture()
    data = data(fixture.attachment.session_id)

    callers =
      for _ <- 1..2,
          do:
            Task.async(fn -> Loopex.open_artifact_transfer(fixture.attachment, data.request) end)

    held = for _ <- 1..2, do: callback(:reserve)

    assert {:error, :transfer_limit_reached} =
             Loopex.open_artifact_transfer(fixture.attachment, data.request)

    assert map_size(state(fixture).artifact_transfers) === 2

    {holder, holder_monitor} =
      spawn_monitor(fn ->
        receive do
          :finish -> :ok
        end
      end)

    try do
      {:ok, other} =
        Runtime.attach_for_holder(fixture.runtime, fixture.attachment.session_id, holder,
          after_event_sequence: 0
        )

      others =
        for _ <- 1..2,
            do: Task.async(fn -> Loopex.open_artifact_transfer(other, data.request) end)

      held = held ++ for _ <- 1..2, do: callback(:reserve)
      assert map_size(state(fixture).artifact_transfers) === 4

      assert {:error, :transfer_limit_reached} =
               Loopex.open_artifact_transfer(other, data.request)

      refute_received {:artifact_callback, :open, _, _, _}

      for reserve <- held do
        {_request, context} = reserve.arguments

        reply(
          reserve,
          {:error,
           %{
             reason: :transfer_limit_reached,
             transfer_ref: context.transfer_ref,
             state: :not_reserved
           }}
        )
      end

      for caller <- callers ++ others do
        assert {:error, %{reason: :transfer_limit_reached, cleanup: :unproved}} =
                 Task.await(caller, 1_000)
      end

      await(fn -> state(fixture).artifact_transfers === %{} end)
      assert state(fixture).artifact_transfers === %{}
    after
      cutoff = now() + 1_000
      send(holder, :finish)
      assert now() < cutoff
      assert_receive {:DOWN, ^holder_monitor, :process, ^holder, :normal}, max(0, cutoff - now())
      assert now() < cutoff
    end
  end

  test "session mismatch with matching canonical digest is refused before adoption" do
    fixture = fixture()
    data = data("other-session")
    caller = Task.async(fn -> Loopex.open_artifact_transfer(fixture.attachment, data.request) end)
    reserve = callback(:reserve)
    {request, context} = reserve.arguments

    assert request.use_locator ===
             "use:" <> Canonical.digest_bytes(Canonical.encode(["artifact-use-v2", data.use]))

    assert request.session_id === fixture.attachment.session_id
    refute ArtifactStore.valid_transfer_use?(data.use, request)
    reply(reserve, {:ok, %{transfer_ref: context.transfer_ref}})
    invocation = callback(:open)
    opened = opened(data, context)
    reply(invocation, {:ok, opened})
    retire = callback(:retire)
    assert entry(fixture, context.transfer_ref).transfer === nil
    assert state(fixture).attachments[fixture.attachment.attachment_id].transfers === %{}
    reply(retire, {:retired, receipt(context, opened.work)})
    ack = callback(:acknowledge)
    reply(ack, :ok)

    assert {:error, %{reason: :transfers_unavailable, cleanup: :unproved}} =
             Task.await(caller, 1_000)

    await_released(fixture, context.transfer_ref)
    assert state(fixture).artifact_transfers === %{}
  end

  test "connection debit survives explicit live-holder release and cross-session reattachment" do
    fixture = fixture()
    {context, opened} = open(fixture)
    close_and_join(fixture, context, opened.work)
    assert ledger(fixture).transfer_debit === 1_048_576
    assert :ok = Runtime.release_holder(fixture.runtime, self())
    assert ledger(fixture).transfer_debit === 1_048_576
    assert Process.alive?(self())
    {:ok, session_id} = Loopex.create_session(fixture.runtime, %{}, command_id: "other-session")
    {:ok, _attachment} = Loopex.attach(fixture.runtime, session_id, after_event_sequence: 0)
    assert ledger(fixture).transfer_debit === 1_048_576
    assert ledger(fixture).transfer_reserved === 0
  end

  test "lost final accounting restores conservative credit without undoing physical cleanup" do
    fixture = fixture()
    {context, _opened} = open(fixture)
    assert ledger(fixture).transfer_debit === 1_048_576
    assert ledger(fixture).transfer_reserved === 0
    close_and_join(fixture, context, :unavailable)
    assert ledger(fixture).transfer_debit === 1_048_576
    assert ledger(fixture).transfer_reserved === 133_300_225
    assert ledger(fixture).transfer_uncertain === true
    assert state(fixture).artifact_transfers === %{}
    request = data(fixture.attachment.session_id).request

    assert {:error, :transfers_unavailable} =
             Loopex.open_artifact_transfer(fixture.attachment, request)

    refute_received {:artifact_callback, :reserve, _, _, _}
  end

  test "maximum opening reservation refuses before I/O when actual remaining connection credit is insufficient" do
    fixture = fixture()
    small = data(fixture.attachment.session_id)
    use = %{small.use | object_size: 67_108_864}
    encoded = Canonical.encode(["artifact-use-v2", use])
    request = %{use_locator: "use:" <> Canonical.digest_bytes(encoded), start: 0}

    work = %{
      source_read_bytes: 67_108_864,
      snapshot_write_debit: 67_108_864,
      metadata_read_bytes: 131_073,
      write_uncertain: false
    }

    for _ <- 1..7 do
      caller = Task.async(fn -> Loopex.open_artifact_transfer(fixture.attachment, request) end)
      reserve = callback(:reserve)
      {_request, context} = reserve.arguments
      reply(reserve, {:ok, %{transfer_ref: context.transfer_ref}})
      invocation = callback(:open)
      object = %{digest: use.object_digest, size: use.object_size, locator: use.object_locator}

      transfer = %{
        transfer_ref: context.transfer_ref,
        object: object,
        use_locator: request.use_locator,
        total_size: 67_108_864,
        window_start: 0,
        window_length: 67_108_864,
        object_digest: use.object_digest
      }

      opened = %{transfer: transfer, use: use, work: work}
      assert ArtifactStore.valid_open_result?({:ok, opened}, elem(reserve.arguments, 0), context)
      reply(invocation, {:ok, opened})
      assert {:ok, _compact} = Task.await(caller, 1_000)
      close_and_join(fixture, context, work)
    end

    # Independent literal arithmetic: seven maximum work reports charge
    # 940441607; 133300217 remains, below the next 134348801 reservation.
    assert ledger(fixture).transfer_debit === 940_441_607
    assert 1_073_741_824 - ledger(fixture).transfer_debit === 133_300_217
    assert ledger(fixture).transfer_reserved === 0
    assert state(fixture).artifact_transfers === %{}

    assert {:error, :open_work_budget_exhausted} =
             Loopex.open_artifact_transfer(fixture.attachment, small.request)

    refute_received {:artifact_callback, :reserve, _, _, _}
    assert ledger(fixture).transfer_debit === 940_441_607
  end

  test "original observer loss retains occupied custody and never spawns a successor" do
    fixture = fixture()
    {context, _opened} = open(fixture)
    original = entry(fixture, context.transfer_ref)
    monitor = Process.monitor(original.observer)
    Process.exit(original.observer, :kill)
    assert_receive {:DOWN, ^monitor, :process, _, :killed}, 1_000
    await(fn -> entry(fixture, context.transfer_ref).lost end)
    retained = entry(fixture, context.transfer_ref)
    assert retained.observer === original.observer
    assert retained.observer_monitor === original.observer_monitor
    assert retained.acknowledged === false
    assert retained.observer_down.reason === :killed
    assert Process.alive?(retained.custodian)
    assert map_size(state(fixture).artifact_transfers) === 1
    refute_received {:artifact_callback, :retire, _, _, _}
    refute_received {:artifact_callback, :acknowledge, _, _, _}
  end

  test "actual Dispatcher replacement preserves delivery but cannot reset original artifact occupancy" do
    fixture = fixture()
    {_context, _opened} = open(fixture)
    original = hd(Map.values(state(fixture).artifact_transfers))
    dispatcher_monitor = Process.monitor(fixture.dispatcher)
    custodian_monitor = Process.monitor(original.custodian)
    observer_monitor = Process.monitor(original.observer)
    Process.exit(fixture.dispatcher, :kill)
    assert_receive {:DOWN, ^dispatcher_monitor, :process, _, :killed}, 1_000
    assert_receive {:DOWN, ^custodian_monitor, :process, _, :killed}, 1_000
    assert_receive {:DOWN, ^observer_monitor, :process, _, :killed}, 1_000

    await(fn ->
      case Runtime.children(fixture.runtime) do
        {:ok, %{dispatcher: dispatcher}} -> dispatcher !== fixture.dispatcher
        _other -> false
      end
    end)

    {:ok, %{control: control, dispatcher: replacement_dispatcher}} =
      Runtime.children(fixture.runtime)

    assert :ok = GenServer.call(control, {:await_dispatcher_ready, fixture.runtime.token}, 1_000)

    {:ok, replacement} =
      Loopex.attach(fixture.runtime, fixture.attachment.session_id, after_event_sequence: 0)

    assert {:ok, %{status: :active}} = Loopex.attachment_status(replacement)
    assert replacement_dispatcher !== fixture.runtime.artifact_dispatcher
    assert replacement.runtime.artifact_dispatcher === fixture.dispatcher
    request = data(fixture.attachment.session_id).request

    assert {:error, %{reason: :transfers_unavailable, cleanup: :unproved}} =
             Loopex.open_artifact_transfer(replacement, request)

    refute_received {:artifact_callback, :reserve, _, _, _}
    refute_received {:artifact_callback, :open, _, _, _}
    # Abnormal original DOWNs establish loss, never Store retirement or a
    # successful cleanup of the prior generation's occupied entry.
  end

  test "completed open failure settles work and responds before held original retirement" do
    fixture = fixture()
    data = data(fixture.attachment.session_id)
    caller = Task.async(fn -> Loopex.open_artifact_transfer(fixture.attachment, data.request) end)
    reserve = callback(:reserve)
    {_request, context} = reserve.arguments
    reply(reserve, {:ok, %{transfer_ref: context.transfer_ref}})
    invocation = callback(:open)

    work = %{
      source_read_bytes: 1_048_576,
      snapshot_write_debit: 1,
      metadata_read_bytes: 17,
      write_uncertain: false
    }

    failure = %{
      reason: :artifact_unreadable,
      transfer_ref: context.transfer_ref,
      work: work,
      state: :retiring
    }

    assert ArtifactStore.valid_open_result?(
             {:error, failure},
             elem(reserve.arguments, 0),
             context
           )

    reply(invocation, {:error, failure})
    retire = callback(:retire)
    original = entry(fixture, context.transfer_ref)
    assert original.observation === :retire
    assert original.opening_work === work
    assert ledger(fixture).transfer_debit === 1_048_594
    assert ledger(fixture).transfer_reserved === 0

    assert {:error, %{reason: :artifact_unreadable, cleanup: :unproved}} =
             Task.await(caller, 1_000)

    assert Process.alive?(retire.pid)
    assert map_size(state(fixture).artifact_transfers) === 1
    refute_received {:artifact_callback, :acknowledge, _, _, _}
    reply(retire, {:retired, receipt(context, work)})
    ack = callback(:acknowledge)
    assert ack.pid === retire.pid
    reply(ack, :ok)
    await_released(fixture, context.transfer_ref)
    assert ledger(fixture).transfer_debit === 1_048_594
    assert ledger(fixture).transfer_reserved === 0
    assert now() < retire.arguments.close_deadline_ms
  end

  test "unknown opening failure responds while the original observer remains blocked" do
    fixture = fixture()
    data = data(fixture.attachment.session_id)
    caller = Task.async(fn -> Loopex.open_artifact_transfer(fixture.attachment, data.request) end)
    reserve = callback(:reserve)
    {_request, context} = reserve.arguments
    reply(reserve, {:ok, %{transfer_ref: context.transfer_ref}})
    invocation = callback(:open)
    reply(invocation, {:error, :transfers_unavailable})
    retire = callback(:retire)

    assert {:error, %{reason: :transfers_unavailable, cleanup: :unproved}} =
             Task.await(caller, 1_000)

    assert entry(fixture, context.transfer_ref).observer === retire.pid
    assert ledger(fixture).transfer_reserved === 134_348_801
    reply(retire, {:retired, receipt(context, :unavailable)})
    ack = callback(:acknowledge)
    reply(ack, :ok)
    await_released(fixture, context.transfer_ref)
    assert ledger(fixture).transfer_reserved === 134_348_801
  end

  test "unknown earlier Store lifetime permits prospective release but cannot prove a later close" do
    fixture = fixture()
    {context, opened} = open(fixture)
    original = entry(fixture, context.transfer_ref)
    assert is_integer(original.permission_issued_at)
    assert original.lifetime_deadline === original.callback_completed_at + 600_000
    proof_ceiling = original.permission_issued_at + 5_000
    remaining = proof_ceiling - now()
    assert remaining > 0

    receive do
      :unexpected_fixture_message -> flunk("unexpected fixture message")
    after
      remaining -> :ok
    end

    assert now() >= proof_ceiling
    assert entry(fixture, context.transfer_ref).phase === :live
    assert now() < original.lifetime_deadline
    custodian_monitor = Process.monitor(original.custodian)
    observer_monitor = Process.monitor(original.observer)

    closer =
      Task.async(fn ->
        Loopex.close_artifact_transfer(fixture.attachment, context.transfer_ref)
      end)

    retire = callback(:retire)
    assert retire.pid === original.observer
    assert retire.arguments.close_deadline_ms > proof_ceiling
    reply(retire, {:retired, receipt(context, opened.work)})
    ack = callback(:acknowledge)
    reply(ack, :ok)
    assert {:error, :cleanup_unproved} = Task.await(closer, 1_000)
    assert_receive {:DOWN, ^custodian_monitor, :process, _, :normal}, 1_000
    assert_receive {:DOWN, ^observer_monitor, :process, _, :normal}, 1_000
    await_released(fixture, context.transfer_ref)
    assert now() < retire.arguments.close_deadline_ms
    assert ledger(fixture).transfer_debit === 1_048_576
  end

  @tag :long_bound
  @tag timeout: 70_000
  test "the real sixty-second response expires while reserve remains blocked and later proof only reclaims" do
    fixture = fixture()
    data = data(fixture.attachment.session_id)
    caller = Task.async(fn -> Loopex.open_artifact_transfer(fixture.attachment, data.request) end)
    reserve = callback(:reserve)
    {_request, context} = reserve.arguments

    assert {:error, %{reason: :open_deadline_exhausted, cleanup: :unproved}} =
             Task.await(caller, 60_000)

    retire = callback(:retire)
    assert retire.arguments.close_deadline_ms === context.open_deadline_ms + 5_000
    assert entry(fixture, context.transfer_ref).invocation === :reserve
    reply(retire, {:unregistered, %{transfer_ref: context.transfer_ref}})
    reply(reserve, {:ok, %{transfer_ref: context.transfer_ref}})
    late = callback(:retire)
    assert late.pid === retire.pid
    assert late.arguments === retire.arguments
    refute_received {:artifact_callback, :open, _, _, _}
    reply(late, {:retired, receipt(context, zero_work())})
    ack = callback(:acknowledge)
    reply(ack, :ok)
    await_released(fixture, context.transfer_ref)
    assert now() < retire.arguments.close_deadline_ms
    assert ledger(fixture).transfer_debit === 1_048_576
  end

  defp fixture do
    {store_pid, store} = TestStore.start_store()

    {:ok, runtime} =
      Loopex.start_link(
        context_token_budget: 8_192,
        session_creation_defaults:
          Loopex.ConfiguredGenesisFixture.genesis([]) |> Map.drop([:kind, "options"]),
        runtime_id: "artifact-custody",
        store: store,
        artifact_store: %{module: ControlledArtifacts, handle: self()}
      )

    Process.unlink(runtime.supervisor)

    on_exit(fn ->
      if Runtime.alive?(runtime), do: Loopex.stop(runtime)
      if Process.alive?(store_pid), do: GenServer.stop(store_pid)
    end)

    :ok = Loopex.ConfiguredGenesisFixture.await_creation_ready(runtime)
    {:ok, %{dispatcher: dispatcher}} = Runtime.children(runtime)
    {:ok, session_id} = Loopex.create_session(runtime, %{}, command_id: "session")
    {:ok, attachment} = Loopex.attach(runtime, session_id, after_event_sequence: 0)
    %{runtime: runtime, dispatcher: dispatcher, attachment: attachment, holder: self()}
  end

  defp data(session_id) do
    use = %{
      canonicalization_version: Canonical.version(),
      object_digest: digest("abc"),
      object_size: 3,
      object_locator: "object:fixture",
      media_type: "application/octet-stream",
      role: "tool_output",
      metadata: %{
        "session_id" => session_id,
        "run_id" => "run",
        "operation_id" => "operation",
        "attempt" => 1,
        "tool_call_id" => "tool"
      }
    }

    bytes = Canonical.encode(["artifact-use-v2", use])

    %{
      use: use,
      request: %{use_locator: "use:" <> Canonical.digest_bytes(bytes), start: 0},
      work: %{
        source_read_bytes: 3,
        snapshot_write_debit: 3,
        metadata_read_bytes: byte_size(bytes),
        write_uncertain: false
      }
    }
  end

  defp opened(data, context) do
    object = %{digest: data.use.object_digest, size: 3, locator: data.use.object_locator}

    transfer = %{
      transfer_ref: context.transfer_ref,
      object: object,
      use_locator: data.request.use_locator,
      total_size: 3,
      window_start: 0,
      window_length: 3,
      object_digest: object.digest
    }

    %{transfer: transfer, use: data.use, work: data.work}
  end

  defp open(fixture) do
    data = data(fixture.attachment.session_id)
    caller = Task.async(fn -> Loopex.open_artifact_transfer(fixture.attachment, data.request) end)
    reserve = callback(:reserve)
    {_request, context} = reserve.arguments
    reply(reserve, {:ok, %{transfer_ref: context.transfer_ref}})
    invocation = callback(:open)
    assert invocation.pid === reserve.pid
    opened = opened(data, context)
    reply(invocation, {:ok, opened})
    assert {:ok, _compact} = Task.await(caller, 1_000)
    {context, opened}
  end

  defp close_and_join(fixture, context, work) do
    original = entry(fixture, context.transfer_ref)
    custodian_monitor = Process.monitor(original.custodian)
    observer_monitor = Process.monitor(original.observer)

    closer =
      Task.async(fn ->
        Loopex.close_artifact_transfer(fixture.attachment, context.transfer_ref)
      end)

    retire = callback(:retire)
    assert retire.pid === original.observer
    reply(retire, {:retired, receipt(context, work)})
    ack = callback(:acknowledge)
    assert ack.pid === retire.pid
    reply(ack, :ok)
    assert :ok = Task.await(closer, 1_000)
    assert_receive {:DOWN, ^custodian_monitor, :process, _, :normal}, 1_000
    assert_receive {:DOWN, ^observer_monitor, :process, _, :normal}, 1_000
    assert state(fixture).artifact_transfers === %{}
    assert now() < retire.arguments.close_deadline_ms
  end

  defp callback(operation) do
    assert_receive {:artifact_callback, ^operation, pid, ref, arguments}, 1_000
    %{pid: pid, ref: ref, arguments: arguments}
  end

  defp reply(callback, result),
    do: send(callback.pid, {:artifact_callback_reply, callback.ref, result})

  defp receipt(context, work),
    do: %{transfer_ref: context.transfer_ref, receipt_ref: String.duplicate("d", 32), work: work}

  defp zero_work,
    do: %{
      source_read_bytes: 0,
      snapshot_write_debit: 0,
      metadata_read_bytes: 0,
      write_uncertain: false
    }

  defp digest(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
  defp now, do: System.monotonic_time(:millisecond)
  defp state(fixture), do: :sys.get_state(fixture.dispatcher)
  defp entry(fixture, id), do: Map.fetch!(state(fixture).artifact_transfers, id)
  defp ledger(fixture), do: Map.fetch!(state(fixture).holders, fixture.holder)

  defp await_released(fixture, id),
    do: await(fn -> not Map.has_key?(state(fixture).artifact_transfers, id) end)

  defp await(predicate) do
    cutoff = now() + 1_000
    await(predicate, cutoff)
  end

  defp await(predicate, cutoff) do
    assert now() < cutoff
    result = predicate.()
    assert now() < cutoff

    if result do
      :ok
    else
      Process.sleep(1)
      await(predicate, cutoff)
    end
  end
end
