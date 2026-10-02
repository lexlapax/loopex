defmodule LoopexComposition.ArtifactRangeExecutorTest do
  use ExUnit.Case, async: false

  alias Loopex.{ArtifactStore, Executor}
  alias Loopex.Executor.Local
  alias Loopex.Executor.Local.{CodingTools, WorkspaceLease}
  alias Loopex.Store.Local.{Artifacts, Transfers}
  alias LoopexProtocol.{Frame, ToolDefinition}

  defmodule LegacyStore do
    @moduledoc false
    @behaviour ArtifactStore
    def put(%{base: base}, bytes, use), do: Artifacts.put(base, bytes, use)
    def describe(%{base: base}, use), do: Artifacts.describe(base, use)
    def stat(%{base: base}, locator), do: Artifacts.stat(base, locator)

    def fetch(%{observer: observer, base: base}, object) do
      send(observer, :unexpected_fetch)
      Artifacts.fetch(base, object)
    end
  end

  defmodule ObservedStore do
    @moduledoc false
    @behaviour ArtifactStore
    defdelegate put(handle, bytes, use), to: LegacyStore
    defdelegate describe(handle, use), to: LegacyStore
    defdelegate stat(handle, locator), to: LegacyStore
    defdelegate fetch(handle, object), to: LegacyStore

    def read_job_range(%{base: base, observer: observer, calls: calls, mode: mode}, job) do
      Agent.update(calls, &[job.job_id | &1])
      send(observer, {:range_started, self(), job.job_id})
      result = Artifacts.read_job_range(base, job)
      send(observer, {:range_verified, self(), job.job_id, result})

      if mode == :hold,
        do:
          (receive do
             :release -> :ok
           end)

      result
    end
  end

  test "compiled generations retain exact literal identities without changing the legacy selection" do
    assert length(CodingTools.definitions()) == 7
    ranges = Enum.filter(CodingTools.generations(), &(&1["tool_id"] == "loopex.read"))
    assert Enum.map(ranges, & &1["tool_version"]) == ["1.0.0", "1.1.0"]

    for definition <- ranges do
      assert {:ok, _} = Loopex.Runtime.ArtifactReadCapabilities.resolve([definition])

      assert Map.has_key?(
               Loopex.Runtime.ArtifactReadCapabilities.table(),
               ToolDefinition.generation(definition)
             )
    end
  end

  test "a bounded real range settles once and its retained receipt survives executor restart" do
    f = fixture(:normal, :binary.copy(<<0>>, 4_096))
    {job, grant} = request(f, 0, 4_096)
    assert {:ok, receipt} = Local.execute(f.executor, job, grant)
    assert receipt.outcome == :completed
    assert receipt.artifacts == []
    assert receipt.cleanup_confirmation == :confirmed
    assert receipt.tool_version == "1.1.0"
    assert {:ok, range} = Frame.decode(receipt.output, 8_192)
    assert range["byte_count"] in 1..4_095
    assert range["content"] == binary_part(f.bytes, 0, range["byte_count"])
    assert range["next_offset"] == range["byte_count"]
    assert :sys.get_state(f.transfers).jobs == %{}

    assert {:ok, envelope} =
             Frame.encode(%{
               "role" => "tool",
               "tool_call_id" => "lx_" <> String.duplicate("a", 48),
               "outcome" => "completed",
               "content" => receipt.output
             })

    assert IO.iodata_length(envelope) - 1 <= 8_192

    File.rm!(
      Path.join([f.base.root, binary_part(f.reference.locator, 0, 2), f.reference.locator])
    )

    assert {:ok, ^receipt} = Local.execute(f.executor, job, grant)
    assert :ok = stop_supervised(Local)
    restarted = start_supervised!({Local, f.executor_options})
    assert {:ok, ^receipt} = Local.receipt(restarted, job.job_id)
    assert {:ok, ^receipt} = Local.execute(restarted, job, grant)
    assert Agent.get(f.calls, & &1) == [job.job_id]
    refute_received :unexpected_fetch
  end

  test "last and empty EOF ranges and UTF-8 refusals use the real executor path" do
    f = fixture(:normal, "a😀z")

    for {offset, length, content, eof} <- [
          {0, 3, "a", false},
          {1, 4, "😀", false},
          {5, 4, "z", true},
          {6, 4, "", true}
        ] do
      {job, grant} = request(f, offset, length)

      assert {:ok, %{outcome: :completed, output: output, artifacts: []}} =
               Local.execute(f.executor, job, grant)

      assert {:ok, range} = Frame.decode(output, 8_192)
      assert range["content"] == content
      assert range["eof"] == eof
      assert range["next_offset"] == offset + byte_size(content)
    end

    {job, grant} = request(f, 2, 2)

    assert {:ok, %{outcome: :failed, output: output, artifacts: []}} =
             Local.execute(f.executor, job, grant)

    assert output =~ "artifact_range_unsupported_content"
  end

  test "an adapter without the optional callback refuses without falling back to fetch" do
    f = fixture(:legacy, "source")
    {job, grant} = request(f, 0, 4)

    assert {:ok, %{outcome: :failed, output: output, artifacts: []}} =
             Local.execute(f.executor, job, grant)

    assert output =~ "artifact_transfer_unsupported"
    assert Agent.get(f.calls, & &1) == []
    refute_received :unexpected_fetch
  end

  test "invalid grants and malformed resolved arguments never reach the adapter" do
    f = fixture(:normal, "source")
    {job, grant} = request(f, 0, 4)
    assert {:error, _} = Local.execute(f.executor, job, %{grant | fencing_token: 9})
    assert :absent = Local.receipt(f.executor, job.job_id)
    {job, _grant} = request(f, 0, 4)
    arguments = Map.put(job.validated_arguments, "path", "also-a-path")

    assert {:ok, malformed} =
             Executor.job(%{Map.from_struct(job) | validated_arguments: arguments})

    assert {:ok, allowed} =
             Executor.issue_grant({:host_policy, :allow}, malformed, job.run_deadline)

    assert {:error, {:refused_before_effect, :invalid_tool_arguments}} =
             Local.execute(f.executor, malformed, allowed)

    assert Agent.get(f.calls, & &1) == []
  end

  test "cancellation after verified I/O joins the effect and keeps its cancelled receipt" do
    f = fixture(:hold, "cancelled range")
    {job, grant} = request(f, 0, 4)
    running = Task.async(fn -> Local.execute(f.executor, job, grant) end)
    assert_receive {:range_verified, effect, job_id, {:ok, "canc"}}, 5_000
    assert job_id == job.job_id
    assert :sys.get_state(f.transfers).jobs == %{}
    monitor = Process.monitor(effect)
    assert {:ok, :cleaned} = Local.cancel(f.executor, job.job_id)
    assert_receive {:DOWN, ^monitor, :process, ^effect, _reason}, 5_000
    assert {:ok, receipt} = Task.await(running, 5_000)
    assert receipt.outcome == :cancelled
    assert receipt.cleanup_confirmation == :confirmed
    assert receipt.artifacts == []
    assert {:ok, ^receipt} = Local.execute(f.executor, job, grant)
    assert Agent.get(f.calls, & &1) == [job.job_id]
  end

  test "both read generations preserve path reads and the new path branch rejects resolution" do
    f = fixture(:normal, "artifact")
    File.write!(Path.join(f.workspace, "source.txt"), "workspace text")

    for version <- ["1.0.0", "1.1.0"] do
      {job, _grant} = request(f, 0, 4)

      {job, grant} =
        changed_request(job, %{
          tool_version: version,
          validated_arguments: %{"path" => "source.txt"}
        })

      assert {:ok, %{outcome: :completed, output: "workspace text"}} =
               Local.execute(f.executor, job, grant)
    end

    {job, _grant} = request(f, 0, 4)

    arguments =
      Map.take(job.validated_arguments, ["resolved_artifact"]) |> Map.put("path", "source.txt")

    {job, grant} = changed_request(job, %{validated_arguments: arguments})

    assert {:error, {:refused_before_effect, :invalid_tool_arguments}} =
             Local.execute(f.executor, job, grant)

    assert Agent.get(f.calls, & &1) == []
  end

  test "cancellation while waiting for shared capacity cannot allocate a late transfer" do
    f = fixture(:normal, "queued range")
    {job, grant} = request(f, 0, 4)
    :sys.suspend(f.transfers)

    try do
      running = Task.async(fn -> Local.execute(f.executor, job, grant) end)
      assert_receive {:range_started, effect, job_id}, 5_000
      assert job_id == job.job_id
      monitor = Process.monitor(effect)
      assert {:ok, :cleaned} = Local.cancel(f.executor, job.job_id)
      assert_receive {:DOWN, ^monitor, :process, ^effect, _}, 5_000

      assert {:ok, %{outcome: :cancelled, cleanup_confirmation: :confirmed}} =
               Task.await(running, 5_000)

      refute_received {:range_verified, _, _, _}
    after
      :sys.resume(f.transfers)
    end

    assert :sys.get_state(f.transfers).jobs == %{}
    assert File.ls!(Path.join(f.base.root, "transfers")) == []
  end

  test "a completed job closes its cancellation address before its caller accepts another job" do
    f = fixture(:hold, "successive ranges")
    {first, first_grant} = request(f, 0, 4)
    {second, second_grant} = request(f, 4, 4)
    parent = self()

    running =
      Task.async(fn ->
        send(parent, {:first_receipt, Local.execute(f.executor, first, first_grant)})

        receive do
          :next ->
            send(parent, {:between_jobs, Process.info(self(), :messages)})
            Local.execute(f.executor, second, second_grant)
        end
      end)

    assert_receive {:range_verified, first_effect, first_id, {:ok, "succ"}}, 5_000
    assert first_id == first.job_id
    table = :sys.get_state(f.executor).inflight_table
    assert [{^first_id, {:range, caller, old_alias}}] = :ets.lookup(table, first_id)
    assert caller == running.pid
    send(first_effect, :release)
    assert_receive {:first_receipt, {:ok, %{outcome: :completed}}}, 5_000
    episode = {System.monotonic_time(:millisecond) + 5_000, 5_000, "unused"}
    send(old_alias, {:loopex_cancel_pending, make_ref(), self(), episode})
    send(caller, :next)
    assert_receive {:between_jobs, {:messages, []}}, 5_000
    assert_receive {:range_verified, second_effect, second_id, {:ok, "essi"}}, 5_000
    assert second_id == second.job_id
    send(second_effect, :release)
    assert {:ok, %{outcome: :completed}} = Task.await(running, 5_000)
  end

  test "the job deadline stops a held reader and its failed receipt prevents reopening" do
    f = fixture(:hold, "deadline range")
    {job, _grant} = request(f, 0, 4)
    {job, grant} = changed_request(job, %{run_deadline: System.system_time(:millisecond) + 1_000})
    running = Task.async(fn -> Local.execute(f.executor, job, grant) end)
    assert_receive {:range_verified, effect, _, {:ok, "dead"}}, 5_000
    monitor = Process.monitor(effect)
    assert {:ok, receipt} = Task.await(running, 5_000)
    assert_receive {:DOWN, ^monitor, :process, ^effect, _}, 5_000
    assert receipt.outcome == :failed
    assert receipt.cleanup_confirmation == :confirmed
    assert receipt.artifacts == []
    assert {:ok, ^receipt} = Local.execute(f.executor, job, grant)
    assert Agent.get(f.calls, & &1) == [job.job_id]
    assert :sys.get_state(f.transfers).jobs == %{}
  end

  defp changed_request(job, changes) do
    assert {:ok, revised} = Executor.job(Map.merge(Map.from_struct(job), changes))

    assert {:ok, grant} =
             Executor.issue_grant({:host_policy, :allow}, revised, revised.run_deadline)

    {revised, grant}
  end

  defp fixture(mode, bytes) do
    root =
      Path.join(System.tmp_dir!(), "loopex-range-executor-#{System.unique_integer([:positive])}")

    workspace = Path.join(root, "workspace")
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf!(root) end)
    base = %{root: Path.join(root, "artifacts")}
    transfers = start_supervised!({Transfers, root: base.root})
    base = Map.put(base, :transfers, transfers)
    calls = start_supervised!({Agent, fn -> [] end})

    source = %{
      "record_kind" => "executor_receipt_committed",
      "journal_version" => 3,
      "record_digest" => String.duplicate("b", 64),
      "run_id" => "source-run",
      "operation_id" => "source-operation",
      "attempt" => 1,
      "tool_call_id" => "source-call"
    }

    metadata =
      source
      |> Map.take(["run_id", "operation_id", "attempt", "tool_call_id"])
      |> Map.merge(%{
        "session_id" => "session",
        "media_type" => "text/plain",
        "role" => "tool_output"
      })

    assert {:ok, reference} =
             ArtifactStore.put(%{module: Artifacts, handle: base}, bytes, metadata)

    lease = start_supervised!({WorkspaceLease, id: "lease", path: workspace, fencing_token: 1})
    module = if mode == :legacy, do: LegacyStore, else: ObservedStore
    store = %{module: module, handle: %{base: base, calls: calls, observer: self(), mode: mode}}

    options = [
      identity: "local",
      epoch: 1,
      fencing_token: 1,
      workspace_leases: %{"lease" => lease},
      ledger_root: Path.join(root, "ledger"),
      artifacts: store
    ]

    executor = start_supervised!({Local, options})

    %{
      executor: executor,
      executor_options: options,
      base: base,
      reference: reference,
      source: source,
      calls: calls,
      transfers: transfers,
      bytes: bytes,
      workspace: workspace
    }
  end

  defp request(f, offset, length) do
    unique = System.unique_integer([:positive])
    deadline = System.system_time(:millisecond) + 30_000
    reference = Map.new(f.reference, fn {key, value} -> {Atom.to_string(key), value} end)

    assert {:ok, job} =
             Executor.job(%{
               protocol_version: 1,
               job_id: "read-#{unique}",
               operation_id: "operation-#{unique}",
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
                 "artifact_use" => f.reference.use_locator,
                 "offset" => offset,
                 "length" => length,
                 "resolved_artifact" => %{"reference" => reference, "source" => f.source}
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

    assert {:ok, grant} = Executor.issue_grant({:host_policy, :allow}, job, deadline)
    {job, grant}
  end
end
