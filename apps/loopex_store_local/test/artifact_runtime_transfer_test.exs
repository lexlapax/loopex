Code.require_file("../../loopex/test/support/configured_genesis_helper.exs", __DIR__)

defmodule Loopex.Store.Local.ArtifactRuntimeTransferTest do
  @moduledoc """
  ## Concept

  Runtime attachment transfers preserve real Local storage custody and capacity
  from verified opening through reads and the final original actor joins.

  ## Technical depth

  The public facade drives an actual Runtime, Local journal and Local artifact
  owner. Private owner state supplies exact identity and accounting observations;
  no adapter substitutes responses or physical retirement evidence. These cases
  do not qualify daemon transport or reclaim a lost registration.
  """

  use ExUnit.Case, async: true

  alias Loopex.ArtifactStore
  alias Loopex.Runtime
  alias Loopex.Store.Local
  alias Loopex.Store.Local.Artifacts
  alias Loopex.Store.Local.Transfers

  test "actual runtime adoption retains original actors through snapshot reads and joined close" do
    fixture = fixture()
    bytes = :binary.copy("verified snapshot ", 3_000)
    {reference, metadata_bytes} = store_artifact(fixture, bytes)

    {:ok, attachment} =
      Loopex.attach(fixture.runtime, fixture.session_id, after_event_sequence: 0)

    assert {:ok, transfer} =
             Loopex.open_artifact_transfer(attachment, %{
               use_locator: reference.use_locator,
               start: 3,
               length: 40_000
             })

    # Concept: a compact facade response reveals no private custody or placement.
    # Technical depth: assert the complete current key set; work and provenance
    # remain available only through their actual private owners below.
    assert Enum.sort(Map.keys(transfer)) ==
             Enum.sort([
               :transfer_ref,
               :total_size,
               :window_start,
               :window_length,
               :object_digest,
               :object_reference,
               :use_reference
             ])

    assert transfer.object_digest == reference.digest
    assert transfer.total_size == byte_size(bytes)
    assert transfer.window_start == 3
    assert transfer.window_length == 40_000
    refute inspect(transfer) =~ fixture.artifacts.root
    original = core_entry(fixture, transfer.transfer_ref)
    record = store_entry(fixture, transfer.transfer_ref)
    assert original.phase == :live
    assert original.invocation == :idle
    assert original.receipt == nil
    refute original.acknowledged
    assert original.permission
    assert record.caller == original.custodian
    assert record.context == original.context
    assert record.status == :live
    assert Process.alive?(original.custodian)
    assert Process.alive?(original.observer)
    assert Process.alive?(record.worker)
    actors = monitor_actors(original, record)
    work = expected_work(byte_size(bytes), metadata_bytes)
    assert record.work == work
    assert original.opening_work == work
    assert ledger(fixture, self()).transfer_debit == 1_048_576
    assert ledger(fixture, self()).transfer_reserved == 0
    assert {:ok, []} = File.ls(Path.join(fixture.artifacts.root, "transfers"))

    # The reader owns the verified unlinked snapshot, even when the original
    # digest-addressed source is rewritten after adoption.
    File.write!(object_path(fixture, reference), :binary.copy("!", byte_size(bytes)))
    first_bytes = binary_part(bytes, 3, 32_768)
    second_bytes = binary_part(bytes, 32_771, 7_232)

    assert {:ok, %{offset: 3, bytes: ^first_bytes, chunk_digest: first_digest}} =
             Loopex.read_artifact_chunk(attachment, transfer.transfer_ref, 32_768)

    assert first_digest == digest(first_bytes)

    assert {:ok, %{offset: 32_771, bytes: ^second_bytes, chunk_digest: second_digest}} =
             Loopex.read_artifact_chunk(attachment, transfer.transfer_ref, 32_768)

    assert second_digest == digest(second_bytes)
    assert {:ok, :complete} = Loopex.read_artifact_chunk(attachment, transfer.transfer_ref, 1)
    retained = core_entry(fixture, transfer.transfer_ref)
    assert retained.custodian == original.custodian
    assert retained.custodian_monitor == original.custodian_monitor
    assert retained.observer == original.observer
    assert retained.observer_monitor == original.observer_monitor
    assert store_entry(fixture, transfer.transfer_ref).worker == record.worker
    assert ledger(fixture, self()).transfer_debit == 1_048_576 + 40_000
    close_and_join(fixture, attachment, transfer, actors)
    assert ledger(fixture, self()).transfer_debit == 1_048_576 + 40_000
    assert ledger(fixture, self()).transfer_reserved == 0

    assert {:error, :unknown_transfer} =
             Loopex.read_artifact_chunk(attachment, transfer.transfer_ref, 1)

    assert {:error, :unknown_transfer} =
             Loopex.close_artifact_transfer(attachment, transfer.transfer_ref)

    assert ledger(fixture, self()).transfer_debit == 1_048_576 + 40_000
  end

  test "real Store and Core conserve four slots and replace exactly one joined transfer" do
    fixture = fixture()
    {reference, _metadata_bytes} = store_artifact(fixture, "four original slots")
    request = %{use_locator: reference.use_locator, start: 0}
    holder = holder()
    waiting_holder = holder()

    {:ok, first} = Loopex.attach(fixture.runtime, fixture.session_id, after_event_sequence: 0)

    {:ok, second} =
      Runtime.attach_for_holder(fixture.runtime, fixture.session_id, holder,
        request_id: "second-holder",
        after_event_sequence: 0
      )

    {:ok, waiting} =
      Runtime.attach_for_holder(fixture.runtime, fixture.session_id, waiting_holder,
        request_id: "waiting-holder",
        after_event_sequence: 0
      )

    opened =
      for attachment <- [first, first, second, second] do
        assert {:ok, transfer} = Loopex.open_artifact_transfer(attachment, request)
        {attachment, transfer}
      end

    assert map_size(core_state(fixture).artifact_transfers) == 4
    assert length(Transfers.live(fixture.artifacts.transfers)) == 4
    assert {:error, :transfer_limit_reached} = Loopex.open_artifact_transfer(first, request)
    assert {:error, :transfer_limit_reached} = Loopex.open_artifact_transfer(second, request)
    assert {:error, :transfer_limit_reached} = Loopex.open_artifact_transfer(waiting, request)
    assert ledger(fixture, waiting_holder).transfer_reserved == 0
    [{attachment, transfer} | retained] = opened
    original = core_entry(fixture, transfer.transfer_ref)
    record = store_entry(fixture, transfer.transfer_ref)
    close_and_join(fixture, attachment, transfer, monitor_actors(original, record))
    assert map_size(core_state(fixture).artifact_transfers) == 3
    assert length(Transfers.live(fixture.artifacts.transfers)) == 3
    assert {:ok, replacement} = Loopex.open_artifact_transfer(attachment, request)
    refute replacement.transfer_ref == transfer.transfer_ref
    assert {:error, :transfer_limit_reached} = Loopex.open_artifact_transfer(attachment, request)
    assert map_size(core_state(fixture).artifact_transfers) == 4
    assert length(Transfers.live(fixture.artifacts.transfers)) == 4

    for {owner, held} <- [{attachment, replacement} | retained] do
      entry = core_entry(fixture, held.transfer_ref)
      stored = store_entry(fixture, held.transfer_ref)
      close_and_join(fixture, owner, held, monitor_actors(entry, stored))
    end

    assert core_state(fixture).artifact_transfers == %{}
    assert Transfers.live(fixture.artifacts.transfers) == []
    assert ledger(fixture, self()).transfer_debit == 3 * 1_048_576
    assert ledger(fixture, holder).transfer_debit == 2 * 1_048_576
    assert ledger(fixture, self()).transfer_reserved == 0
    assert ledger(fixture, holder).transfer_reserved == 0
    finish_holder(holder)
    finish_holder(waiting_holder)
  end

  test "a corrupted real opening retains its complete failed verification charge exactly once" do
    fixture = fixture()
    bytes = :binary.copy("a", 1_100_000)
    {reference, metadata_bytes} = store_artifact(fixture, bytes)

    File.write!(
      object_path(fixture, reference),
      binary_part(bytes, 0, byte_size(bytes) - 1) <> "!"
    )

    {:ok, attachment} =
      Loopex.attach(fixture.runtime, fixture.session_id, after_event_sequence: 0)

    owner = fixture.artifacts.transfers

    # Concept: failure still retires the actual original Store I/O actor.
    # Technical depth: process-scoped spawn/exit tracing is installed before the
    # owner can create that actor. It preserves original identity through a fast
    # failure without substituting a monitor acquired after the actor has exited.
    assert 1 = :erlang.trace(owner, true, [:procs, :set_on_spawn, {:tracer, self()}])
    true = :erlang.suspend_process(fixture.artifacts.transfers)

    try do
      caller =
        Task.async(fn ->
          Loopex.open_artifact_transfer(attachment, %{
            use_locator: reference.use_locator,
            start: 0,
            length: 1
          })
        end)

      await(fn -> map_size(core_state(fixture).artifact_transfers) == 1 end, now() + 1_000)
      [original] = Map.values(core_state(fixture).artifact_transfers)
      custodian_monitor = Process.monitor(original.custodian)
      observer_monitor = Process.monitor(original.observer)
      assert ledger(fixture, self()).transfer_reserved == 134_348_801
      cleanup_cutoff = now() + 5_000
      true = :erlang.resume_process(fixture.artifacts.transfers)
      remaining = remaining!(cleanup_cutoff)
      assert_receive {:trace, ^owner, :spawn, worker, _entry}, remaining
      remaining = remaining!(cleanup_cutoff)
      assert_receive {:trace, ^worker, :exit, :normal}, remaining
      assert now() < cleanup_cutoff

      assert {:error, %{reason: :artifact_digest_mismatch, cleanup: :unproved}} =
               Task.await(caller, remaining!(cleanup_cutoff))

      join_actor(original.custodian, custodian_monitor, cleanup_cutoff)
      join_actor(original.observer, observer_monitor, cleanup_cutoff)
      await(fn -> core_state(fixture).artifact_transfers == %{} end, cleanup_cutoff)
      assert Transfers.live(fixture.artifacts.transfers) == []
      assert {:ok, []} = File.ls(Path.join(fixture.artifacts.root, "transfers"))
      expected_debit = byte_size(bytes) * 2 + metadata_bytes
      assert ledger(fixture, self()).transfer_debit == expected_debit
      assert ledger(fixture, self()).transfer_reserved == 0

      assert {:error, :unknown_transfer} =
               Loopex.read_artifact_chunk(attachment, original.id, 1)

      assert {:error, :unknown_transfer} = Loopex.close_artifact_transfer(attachment, original.id)
      assert ledger(fixture, self()).transfer_debit == expected_debit
      assert ledger(fixture, self()).transfer_reserved == 0
    after
      if Process.alive?(fixture.artifacts.transfers) do
        :erlang.trace(owner, false, [:procs, :set_on_spawn])

        try do
          :erlang.resume_process(fixture.artifacts.transfers)
        catch
          :error, :badarg -> :ok
        end
      end
    end
  end

  defp fixture do
    root =
      Path.join(
        System.tmp_dir!(),
        "loopex-runtime-transfer-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    artifact_root = Path.join(root, "artifacts")
    {:ok, owner} = Transfers.start_link(root: artifact_root)
    Process.unlink(owner)
    on_exit(fn -> stop_fixture_owner(owner, fn -> GenServer.stop(owner) end) end)
    artifacts = %{root: artifact_root, transfers: owner}
    {:ok, store_pid} = Local.start_link(path: Path.join(root, "state"))
    Process.unlink(store_pid)
    on_exit(fn -> stop_fixture_owner(store_pid, fn -> GenServer.stop(store_pid) end) end)
    {:ok, store} = Loopex.Store.new(Local, store_pid)

    {:ok, runtime} =
      Loopex.start_link(
        runtime_id: "artifact-runtime-transfer",
        context_token_budget: 8_192,
        store: store,
        artifact_store: %{module: Artifacts, handle: artifacts},
        session_creation_defaults:
          Loopex.ConfiguredGenesisFixture.genesis([]) |> Map.drop([:kind, "options"])
      )

    Process.unlink(runtime.supervisor)

    on_exit(fn ->
      stop_fixture_owner(runtime.supervisor, fn -> Loopex.stop(runtime) end)
    end)

    :ok = Loopex.ConfiguredGenesisFixture.await_creation_ready(runtime)
    {:ok, session_id} = Loopex.create_session(runtime, %{}, command_id: "create")
    {:ok, %{dispatcher: dispatcher}} = Runtime.children(runtime)
    %{runtime: runtime, session_id: session_id, dispatcher: dispatcher, artifacts: artifacts}
  end

  defp store_artifact(fixture, bytes) do
    use = %{
      media_type: "application/octet-stream",
      role: "tool_output",
      metadata: %{
        "session_id" => fixture.session_id,
        "run_id" => "run",
        "operation_id" => "operation",
        "attempt" => 1,
        "tool_call_id" => "tool"
      }
    }

    {:ok, reference} = Artifacts.put(fixture.artifacts, bytes, use)
    use_digest = binary_part(reference.use_locator, 4, 64)

    use_path =
      Path.join([fixture.artifacts.root, "uses", binary_part(use_digest, 0, 2), use_digest])

    {reference, File.stat!(use_path).size}
  end

  defp holder do
    pid =
      spawn(fn ->
        receive do
          :finish -> :ok
        end
      end)

    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)
    pid
  end

  defp finish_holder(pid) do
    monitor = Process.monitor(pid)
    send(pid, :finish)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 1_000
  end

  defp stop_fixture_owner(pid, stop) do
    if Process.alive?(pid) do
      monitor = Process.monitor(pid)
      assert :ok = stop.()
      assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 1_000
    end
  end

  defp expected_work(size, metadata_bytes),
    do: %{
      source_read_bytes: size,
      snapshot_write_debit: size,
      metadata_read_bytes: metadata_bytes,
      write_uncertain: false
    }

  defp monitor_actors(entry, record),
    do: Enum.map([entry.custodian, entry.observer, record.worker], &{&1, Process.monitor(&1)})

  defp close_and_join(fixture, attachment, transfer, actors) do
    cutoff = now() + ArtifactStore.transfer_limits().cleanup_deadline_ms
    assert :ok = Loopex.close_artifact_transfer(attachment, transfer.transfer_ref)
    Enum.each(actors, fn {pid, monitor} -> join_actor(pid, monitor, cutoff) end)
    assert now() < cutoff
    refute Map.has_key?(core_state(fixture).artifact_transfers, transfer.transfer_ref)
    refute transfer.transfer_ref in Transfers.live(fixture.artifacts.transfers)
  end

  defp join_actor(pid, monitor, cutoff) do
    remaining = remaining!(cutoff)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, remaining
    assert now() < cutoff
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

  defp remaining!(cutoff) do
    remaining = cutoff - now()
    assert remaining > 0
    remaining
  end

  defp object_path(fixture, reference),
    do:
      Path.join([fixture.artifacts.root, binary_part(reference.locator, 0, 2), reference.locator])

  defp core_state(fixture), do: :sys.get_state(fixture.dispatcher)
  defp core_entry(fixture, id), do: Map.fetch!(core_state(fixture).artifact_transfers, id)

  defp store_entry(fixture, id),
    do: Map.fetch!(:sys.get_state(fixture.artifacts.transfers).transfers, id)

  defp ledger(fixture, holder), do: Map.fetch!(core_state(fixture).holders, holder)
  defp digest(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
  defp now, do: System.monotonic_time(:millisecond)
end
