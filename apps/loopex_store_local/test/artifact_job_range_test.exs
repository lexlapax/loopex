defmodule Loopex.Store.Local.ArtifactJobRangeTest do
  use ExUnit.Case, async: false

  alias Loopex.{ArtifactStore, Executor}
  alias Loopex.Store.Local.{Artifacts, Transfers}

  @source %{
    "record_kind" => "executor_receipt_committed_v2",
    "journal_version" => 3,
    "record_digest" => String.duplicate("b", 64),
    "run_id" => "source-run",
    "operation_id" => "source-operation",
    "attempt" => 1,
    "tool_call_id" => "source-call"
  }

  test "verified first, last and empty ranges release capacity before returning" do
    {handle, reference} = stored("0123456789")

    for {offset, length, expected} <- [{0, 4, "0123"}, {8, 4, "89"}, {10, 4, ""}] do
      assert {:ok, ^expected} = Artifacts.read_job_range(handle, job(reference, offset, length))
      assert :sys.get_state(handle.transfers).jobs == %{}
      assert File.ls!(Path.join(handle.root, "transfers")) == []
    end
  end

  test "corruption outside the requested window refuses the range" do
    {handle, reference} = stored("0123456789")
    File.write!(object_path(handle, reference), "012345678X")

    assert {:error, :artifact_digest_mismatch} =
             Artifacts.read_job_range(handle, job(reference, 0, 2))

    assert :sys.get_state(handle.transfers).jobs == %{}
    assert File.ls!(Path.join(handle.root, "transfers")) == []
  end

  test "a valid use cannot turn a local object locator into a filesystem path" do
    {handle, reference} = stored("content")
    assert {:ok, use} = ArtifactStore.describe(%{module: Artifacts, handle: handle}, reference)
    name = String.duplicate("x", 62)
    locator = "./" <> name
    File.write!(Path.join(handle.root, name), "content")
    use = %{use | object_locator: locator}
    canonical = ["artifact-use-v2", use]
    digest = LoopexProtocol.Canonical.digest(canonical)
    use_path = Path.join([handle.root, "uses", binary_part(digest, 0, 2), digest])
    File.mkdir_p!(Path.dirname(use_path))
    File.write!(use_path, LoopexProtocol.Canonical.encode(canonical))
    forged = %{reference | locator: locator, use_digest: digest, use_locator: "use:" <> digest}
    assert ArtifactStore.valid_reference?(forged)
    assert {:ok, _} = ArtifactStore.describe(%{module: Artifacts, handle: handle}, forged)
    assert {:error, :unknown_artifact} = Artifacts.read_job_range(handle, job(forged, 0, 4))
  end

  test "session and original source provenance must match the verified use" do
    {handle, reference} = stored("content")
    original = job(reference, 0, 4)

    for changes <- [
          %{session_id: "other-session"},
          %{
            validated_arguments:
              put_in(
                original.validated_arguments,
                ["resolved_artifact", "source", "operation_id"],
                "other-operation"
              )
          }
        ] do
      fields = original |> Map.from_struct() |> Map.merge(changes)
      assert {:ok, changed} = Executor.job(fields)
      assert {:error, :artifact_use_mismatch} = Artifacts.read_job_range(handle, changed)
    end

    assert {:error, :invalid_tool_arguments} =
             Artifacts.read_job_range(handle, %{original | canonical_request_digest: "forged"})

    assert :sys.get_state(handle.transfers).jobs == %{}
  end

  test "attachment and job reads share the runtime transfer ceiling" do
    {handle, reference} = stored("capacity")

    open = fn ->
      request = %{session_id: "session", use_locator: reference.use_locator, start: 0}

      context = %{
        transfer_ref: Base.encode16(:crypto.strong_rand_bytes(16), case: :lower),
        open_deadline_ms: System.monotonic_time(:millisecond) + 60_000,
        object_work_bytes: 134_217_728,
        metadata_read_bytes: 131_073
      }

      assert {:ok, %{transfer_ref: id}} = Artifacts.reserve_transfer(handle, request, context)
      assert id == context.transfer_ref
      assert {:ok, %{transfer: transfer}} = Artifacts.open_transfer(handle, request, context)
      Process.put({:transfer_context, id}, context)
      {:ok, transfer}
    end

    transfers =
      for _ <- 1..4,
          do:
            (
              assert {:ok, transfer} = open.()
              transfer
            )

    assert {:error, :transfer_limit_reached} =
             Artifacts.read_job_range(handle, job(reference, 0, 4))

    [first | rest] = transfers
    assert :ok = close_transfer(handle, first)
    parent = self()

    holder =
      spawn(fn ->
        assert {:ok, placement} =
                 Transfers.reserve_job(
                   handle.transfers,
                   System.monotonic_time(:millisecond) + 5_000
                 )

        send(parent, {:reserved, self()})

        receive do
          :release -> Transfers.release_job(handle.transfers, placement.job_monitor)
        end
      end)

    assert_receive {:reserved, ^holder}
    assert {:error, :transfer_limit_reached} = open.()
    monitor = Process.monitor(holder)
    send(holder, :release)
    assert_receive {:DOWN, ^monitor, :process, ^holder, :normal}
    assert {:ok, "capa"} = Artifacts.read_job_range(handle, job(reference, 0, 4))
    Enum.each(rest, &close_transfer(handle, &1))
  end

  test "malformed resolved jobs fail before reserving or consulting artifact uses" do
    {handle, reference} = stored("content")
    original = job(reference, 0, 4)
    arguments = original.validated_arguments

    invalid = [
      Map.put(arguments, "path", "also-a-path"),
      Map.put(arguments, "offset", 8),
      Map.put(arguments, "length", 4_097),
      Map.put(arguments, "length", 0),
      put_in(arguments, ["resolved_artifact", "source", "record_digest"], "untrusted"),
      put_in(arguments, ["resolved_artifact", "source", "journal_version"], 0),
      put_in(arguments, ["resolved_artifact", "source", "extra"], "untrusted"),
      put_in(arguments, ["resolved_artifact", "reference", "extra"], "untrusted"),
      put_in(arguments, ["resolved_artifact", "reference"], nil)
    ]

    for arguments <- invalid do
      assert {:ok, request} =
               Executor.job(%{Map.from_struct(original) | validated_arguments: arguments})

      assert {:error, :invalid_tool_arguments} = Artifacts.read_job_range(handle, request)
      assert :sys.get_state(handle.transfers).jobs == %{}
    end
  end

  test "callback completion stops its linked watchdog and releases capacity" do
    {handle, reference} = stored("cleanup")
    {:links, before} = Process.info(self(), :links)
    assert {:ok, "clea"} = Artifacts.read_job_range(handle, job(reference, 0, 4))
    {:links, after_links} = Process.info(self(), :links)
    assert Enum.sort(before) == Enum.sort(after_links)
    assert :sys.get_state(handle.transfers).jobs == %{}
    assert File.ls!(Path.join(handle.root, "transfers")) == []
  end

  test "whole-object work is charged once and all actual descriptors close on success and corruption" do
    bytes = :binary.copy("a", 131_072)
    {handle, reference} = stored(bytes)

    for corrupt <- [false, true] do
      if corrupt,
        do: File.write!(object_path(handle, reference), :binary.copy("b", byte_size(bytes)))

      {result, observed} =
        trace_io(fn -> Artifacts.read_job_range(handle, job(reference, 0, 4)) end)

      if corrupt,
        do: assert(result == {:error, :artifact_digest_mismatch}),
        else: assert(result == {:ok, "aaaa"})

      devices = for {:opened, device} <- observed, do: device
      assert length(devices) == 3
      for device <- devices, do: assert(:file.read(device, 1) == {:error, :einval})

      work =
        Enum.reduce(observed, %{}, fn
          {:work, kind, count}, totals -> Map.update(totals, kind, count, &(&1 + count))
          _, totals -> totals
        end)

      assert work[:source_read] == byte_size(bytes)
      assert work[:snapshot_written] == byte_size(bytes)
      assert Map.get(work, :emitted, 0) == if(corrupt, do: 0, else: 4)
      assert Map.get(work, :snapshot_write_uncertain, 0) == 0
    end
  end

  test "a queued job spends its deadline and cannot reserve capacity after caller death" do
    {handle, reference} = stored("queued")
    request = job(reference, 0, 4, System.system_time(:millisecond) + 300)
    :sys.suspend(handle.transfers)
    on_exit(fn -> if Process.alive?(handle.transfers), do: :sys.resume(handle.transfers) end)
    {caller, monitor} = spawn_monitor(fn -> Artifacts.read_job_range(handle, request) end)
    assert_receive {:DOWN, ^monitor, :process, ^caller, :killed}, 2_000
    :sys.resume(handle.transfers)
    assert :sys.get_state(handle.transfers).jobs == %{}
  end

  test "open-work exhaustion refuses before source reads and leaves no snapshot" do
    limits = %{ArtifactStore.transfer_limits() | open_work_bytes: 1}
    {handle, reference} = stored("over budget", limits)

    assert {{:error, :open_work_budget_exhausted}, observed} =
             trace_io(fn -> Artifacts.read_job_range(handle, job(reference, 0, 4)) end)

    assert [{:opened, use_reader}] = observed
    assert :file.read(use_reader, 1) == {:error, :einval}

    assert :sys.get_state(handle.transfers).jobs == %{}
    assert File.ls!(Path.join(handle.root, "transfers")) == []
  end

  test "oversized or trailing use bytes refuse without accepting a valid prefix" do
    {handle, reference} = stored("content")

    use =
      Path.join([
        handle.root,
        "uses",
        binary_part(reference.use_digest, 0, 2),
        reference.use_digest
      ])

    original = File.read!(use)

    for bytes <- [
          original <> "trailing",
          :binary.copy("x", ArtifactStore.max_use_bytes() + 1),
          :erlang.term_to_binary(:binary.copy("x", 1_048_576), [:compressed])
        ] do
      File.write!(use, bytes)

      assert {:error, :artifact_integrity_failed} =
               Artifacts.read_job_range(handle, job(reference, 0, 4))
    end
  end

  defp stored(bytes, limits \\ ArtifactStore.transfer_limits()) do
    root = Path.join(System.tmp_dir!(), "loopex-job-range-#{System.unique_integer([:positive])}")
    owner = start_supervised!({Transfers, root: root, limits: limits})
    on_exit(fn -> File.rm_rf!(root) end)
    handle = %{root: root, transfers: owner}

    metadata =
      @source
      |> Map.take(["run_id", "operation_id", "attempt", "tool_call_id"])
      |> Map.put("session_id", "session")

    assert {:ok, reference} =
             Artifacts.put(handle, bytes, %{
               media_type: "text/plain",
               role: "tool_output",
               metadata: metadata
             })

    {handle, reference}
  end

  defp trace_io(work) do
    caller = self()
    collector = spawn_link(fn -> collect_io(caller, []) end)
    :erlang.trace_pattern({File, :open, 2}, [{:_, [], [{:return_trace}]}], [:local])
    :erlang.trace(caller, true, [:call, :send, {:tracer, collector}])

    try do
      result = work.()
      :erlang.trace(caller, false, [:call, :send])
      delivered = :erlang.trace_delivered(caller)
      assert_receive {:trace_delivered, ^caller, ^delivered}
      send(collector, :finish)
      assert_receive {:io_observed, observed}
      {result, observed}
    after
      :erlang.trace(caller, false, [:call, :send])
      :erlang.trace_pattern({File, :open, 2}, false, [:local])
      Process.unlink(collector)
      if Process.alive?(collector), do: Process.exit(collector, :kill)
    end
  end

  defp collect_io(caller, observed) do
    receive do
      {:trace, ^caller, :return_from, {File, :open, 2}, {:ok, device}} ->
        collect_io(caller, [{:opened, device} | observed])

      {:trace, ^caller, :send, {:job_storage_work, ^caller, kind, bytes}, _destination} ->
        collect_io(caller, [{:work, kind, bytes} | observed])

      :finish ->
        send(caller, {:io_observed, Enum.reverse(observed)})

      _other ->
        collect_io(caller, observed)
    end
  end

  defp close_transfer(handle, transfer) do
    context = Process.get({:transfer_context, transfer.transfer_ref})

    selector = %{
      action: :retire,
      transfer_ref: transfer.transfer_ref,
      open_deadline_ms: context.open_deadline_ms,
      close_deadline_ms: System.monotonic_time(:millisecond) + 5_000
    }

    assert {:retired, %{receipt_ref: receipt}} = Artifacts.close_transfer(handle, selector)

    assert :ok =
             Artifacts.close_transfer(handle, %{
               action: :acknowledge,
               transfer_ref: transfer.transfer_ref,
               receipt_ref: receipt
             })

    :ok
  end

  defp job(reference, offset, length, deadline \\ System.system_time(:millisecond) + 10_000) do
    plain = Map.new(reference, fn {key, value} -> {Atom.to_string(key), value} end)

    assert {:ok, job} =
             Executor.job(%{
               protocol_version: 1,
               job_id: "read-job",
               operation_id: "read-operation",
               attempt: 1,
               session_id: "session",
               run_id: "read-run",
               turn_id: "read-turn",
               tool_call_id: "read-call",
               origin_session_epoch: 1,
               origin_executor_epoch: 1,
               executor_identity: "local",
               required_capabilities: ["read_only"],
               tool_id: "loopex.read",
               tool_version: "1.1.0",
               effect_class: "read_only",
               validated_arguments: %{
                 "artifact_use" => reference.use_locator,
                 "offset" => offset,
                 "length" => length,
                 "resolved_artifact" => %{"reference" => plain, "source" => @source}
               },
               workspace_ref: "workspace",
               workspace_lease: "lease",
               run_deadline: deadline,
               resource_budgets: %{"max_output_bytes" => 16_384},
               idempotency_class: "safe_retry",
               fencing_token: 1,
               artifact_policy: %{"retain" => true},
               output_policy: %{"capture" => true}
             })

    job
  end

  defp object_path(handle, reference),
    do: Path.join([handle.root, binary_part(reference.locator, 0, 2), reference.locator])
end
