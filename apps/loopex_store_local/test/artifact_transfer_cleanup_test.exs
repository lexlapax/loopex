defmodule Loopex.Store.Local.ArtifactTransferCleanupTest do
  use ExUnit.Case, async: false

  alias Loopex.Store.Local.Artifacts
  alias Loopex.Store.Local.Transfers

  test "snapshot creation failure closes the source before returning" do
    root =
      Path.join(
        System.tmp_dir!(),
        "loopex-transfer-cleanup-#{System.unique_integer([:positive])}"
      )

    owner = start_supervised!({Transfers, root: root})
    on_exit(fn -> File.rm_rf!(root) end)
    handle = %{root: root, transfers: owner}

    assert {:ok, reference} =
             Artifacts.put(handle, "source bytes", %{
               media_type: "text/plain",
               role: "tool_output",
               metadata: %{
                 "session_id" => "session",
                 "run_id" => "run",
                 "operation_id" => "operation",
                 "attempt" => 1,
                 "tool_call_id" => "call"
               }
             })

    scratch = Path.join(root, "transfers")
    File.rmdir!(scratch)
    File.write!(scratch, "not a directory")

    :erlang.trace_pattern({File, :open, 2}, [{:_, [], [{:return_trace}]}], [:local])
    :erlang.trace_pattern({File, :close, 1}, [{:_, [], [{:return_trace}]}], [:local])
    :erlang.trace(owner, true, [:call, :procs, :set_on_spawn, {:tracer, self()}])

    on_exit(fn ->
      :erlang.trace_pattern({File, :open, 2}, false, [:local])
      :erlang.trace_pattern({File, :close, 1}, false, [:local])
    end)

    request = %{session_id: "session", use_locator: reference.use_locator, start: 0}

    context = %{
      transfer_ref: Base.encode16(:crypto.strong_rand_bytes(16), case: :lower),
      open_deadline_ms: System.monotonic_time(:millisecond) + 60_000,
      object_work_bytes: 134_217_728,
      metadata_read_bytes: 131_073
    }

    assert {:ok, _} = Artifacts.reserve_transfer(handle, request, context)

    assert {:error, %{reason: :artifact_unreadable, state: :retired, work: work}} =
             Artifacts.open_transfer(handle, request, context)

    assert_receive {:trace, ^owner, :spawn, worker, _entry}
    assert_receive {:trace, ^worker, :return_from, {File, :open, 2}, {:ok, use_reader}}
    assert_receive {:trace, ^worker, :call, {File, :close, [^use_reader]}}
    assert_receive {:trace, ^worker, :return_from, {File, :close, 1}, :ok}
    assert_receive {:trace, ^worker, :return_from, {File, :open, 2}, {:ok, source}}
    assert_receive {:trace, ^worker, :call, {File, :close, [^source]}}
    assert_receive {:trace, ^worker, :return_from, {File, :close, 1}, :ok}
    assert_receive {:trace, ^worker, :exit, :normal}
    assert work.source_read_bytes == 0
    assert work.snapshot_write_debit == 0

    # Concept: failure retires the actual original I/O actor and its descriptors.
    # Technical depth: exact call/return evidence above proves both actual closes
    # before original actor exit; reading another actor's raw descriptor from this
    # process would only prove ownership refusal. The original slot retains its
    # physical proof until the matching receipt acknowledgement.
    assert [id] = Transfers.live(owner)
    assert id == context.transfer_ref

    selector = %{
      action: :retire,
      transfer_ref: id,
      open_deadline_ms: context.open_deadline_ms,
      close_deadline_ms: System.monotonic_time(:millisecond) + 5_000
    }

    assert {:retired, %{receipt_ref: receipt}} = Artifacts.close_transfer(handle, selector)

    assert :ok =
             Artifacts.close_transfer(handle, %{
               action: :acknowledge,
               transfer_ref: id,
               receipt_ref: receipt
             })

    assert Transfers.live(owner) == []
    assert Process.alive?(owner)
  end

  test "reservation returns without any File or file I/O on the original owner" do
    root =
      Path.join(System.tmp_dir!(), "loopex-reserve-no-io-#{System.unique_integer([:positive])}")

    owner = start_supervised!({Transfers, root: root})
    on_exit(fn -> File.rm_rf!(root) end)
    File.rm_rf!(root)
    handle = %{root: root, transfers: owner}
    patterns = [{File, :_, :_}, {:file, :_, :_}]

    on_exit(fn ->
      Enum.each(patterns, &:erlang.trace_pattern(&1, false, [:local]))
    end)

    Enum.each(patterns, &:erlang.trace_pattern(&1, true, [:local]))
    :erlang.trace(owner, true, [:call, {:tracer, self()}])

    context = %{
      transfer_ref: String.duplicate("a", 32),
      open_deadline_ms: System.monotonic_time(:millisecond) + 60_000,
      object_work_bytes: 134_217_728,
      metadata_read_bytes: 131_073
    }

    request = %{session_id: "session", use_locator: "use:" <> String.duplicate("b", 64), start: 0}
    assert {:ok, %{transfer_ref: id}} = Artifacts.reserve_transfer(handle, request, context)
    assert id == context.transfer_ref
    :erlang.trace(owner, false, [:call])
    fence = :erlang.trace_delivered(owner)
    assert_receive {:trace_delivered, ^owner, ^fence}
    refute_receive {:trace, ^owner, :call, _io}, 0
    refute File.exists?(root)
    record = :sys.get_state(owner).transfers[id]
    assert record.worker == nil

    selector = %{
      action: :retire,
      transfer_ref: id,
      open_deadline_ms: context.open_deadline_ms,
      close_deadline_ms: System.monotonic_time(:millisecond) + 5_000
    }

    assert {:retired, %{receipt_ref: receipt}} = Artifacts.close_transfer(handle, selector)

    assert :ok =
             Artifacts.close_transfer(handle, %{
               action: :acknowledge,
               transfer_ref: id,
               receipt_ref: receipt
             })

    assert Transfers.live(owner) == []
  end
end
