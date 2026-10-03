defmodule Loopex.Executor.Local.ArtifactRetentionContractTest do
  @moduledoc false

  use ExUnit.Case, async: true

  # A job that runs its whole 60 s run deadline out must still present as a
  # receipt this module can assert on, not as ExUnit's own 60 s timeout.
  @moduletag timeout: 90_000

  alias Loopex.ArtifactStore
  alias Loopex.Executor.Local
  alias Loopex.Executor.Local.WorkspaceLease
  alias LoopexProtocol.Canonical

  @fence 19

  defmodule ContractStore do
    @moduledoc false
    @behaviour Loopex.ArtifactStore

    alias LoopexProtocol.Canonical

    def start(mode \\ :truthful) do
      Agent.start_link(fn -> %{mode: mode, calls: [], objects: %{}, uses: %{}} end)
    end

    def calls(pid), do: Agent.get(pid, &Enum.reverse(&1.calls))

    def put(pid, bytes, %{media_type: media_type, role: role, metadata: metadata} = use) do
      digest = Canonical.digest_bytes(bytes)
      locator = "contract:" <> digest

      object = %{digest: digest, size: byte_size(bytes), locator: locator}

      artifact_use = %{
        canonicalization_version: Canonical.version(),
        object_digest: object.digest,
        object_size: object.size,
        object_locator: object.locator,
        media_type: media_type,
        role: role,
        metadata: metadata
      }

      use_digest = Canonical.digest(["artifact-use-v2", artifact_use])
      mode = Agent.get(pid, & &1.mode)

      reference =
        Map.merge(object, %{
          media_type: media_type,
          role: role,
          use_canonicalization_version: Canonical.version(),
          use_digest: use_digest,
          use_locator:
            if(mode == :private_locator,
              do: "use:" <> metadata["session_id"],
              else: "use:" <> use_digest
            )
        })
        |> then(fn reference ->
          if mode == :wrong_digest,
            do: %{reference | digest: String.duplicate("f", 64)},
            else: reference
        end)

      :ok =
        Agent.update(pid, fn state ->
          %{
            state
            | calls: [{bytes, use} | state.calls],
              objects: Map.put(state.objects, locator, {object, bytes}),
              uses: Map.put(state.uses, "use:" <> use_digest, artifact_use)
          }
        end)

      if match?({:hold, _}, mode) do
        {:hold, owner} = mode
        send(owner, {:early_retention_blocked, self()})

        receive do
          :release_early_retention -> :ok
        end
      end

      {:ok, reference}
    end

    def put(pid, bytes, unnormalized) do
      :ok = Agent.update(pid, &%{&1 | calls: [{bytes, unnormalized} | &1.calls]})
      {:error, :adapter_received_unnormalized_use}
    end

    def fetch(pid, object) do
      case Agent.get(pid, &Map.fetch(&1.objects, object.locator)) do
        {:ok, {_stored_object, bytes}} -> {:ok, bytes}
        :error -> {:error, :unknown_artifact}
      end
    end

    def stat(pid, locator) when is_binary(locator) do
      case Agent.get(pid, &Map.fetch(&1.objects, locator)) do
        {:ok, {object, _bytes}} -> {:ok, object}
        :error -> {:error, :unknown_artifact}
      end
    end

    def stat(_pid, _locator), do: {:error, :unknown_artifact}

    def describe(pid, use_locator) do
      case Agent.get(pid, &{&1.mode, Map.fetch(&1.uses, use_locator)}) do
        {:missing_describe, _retained} -> {:error, :unknown_artifact_use}
        {_mode, {:ok, use}} -> {:ok, use}
        {_mode, :error} -> {:error, :unknown_artifact_use}
      end
    end
  end

  test "a real local executor spills through core with the complete private artifact use" do
    root = workspace()
    full = String.duplicate("artifact-line\n", 512)
    File.write!(Path.join(root, "large.txt"), full)
    {:ok, artifact_store} = ContractStore.start()
    {executor, lease_id} = executor_for(root, artifact_store)

    identity = %{
      session_id: "private-session-id",
      run_id: "private-run-id",
      operation_id: "private-operation-id",
      attempt: 7,
      tool_call_id: "private-tool-call-id"
    }

    assert {:ok, receipt} = execute_read(executor, lease_id, identity)
    assert receipt.outcome == :completed
    assert [reference] = receipt.artifacts
    assert ArtifactStore.valid_reference?(reference)
    assert reference.use_locator == "use:" <> reference.use_digest
    assert byte_size(receipt.output) < byte_size(full)
    assert receipt.output =~ reference.locator

    assert [{^full, normalized}] = ContractStore.calls(artifact_store)

    assert normalized == %{
             media_type: "text/plain",
             role: "tool_output",
             metadata: %{
               "session_id" => identity.session_id,
               "run_id" => identity.run_id,
               "operation_id" => identity.operation_id,
               "attempt" => identity.attempt,
               "tool_call_id" => identity.tool_call_id
             }
           }

    assert {:ok, described} = invoke_core(:describe, [store(artifact_store), reference])
    assert described.metadata == normalized.metadata
    assert {:ok, ^full} = invoke_core(:fetch, [store(artifact_store), reference])

    compact = Canonical.encode(reference)

    for private <- Map.values(normalized.metadata) |> Enum.reject(&is_integer/1) do
      refute compact =~ private

      refute receipt.output =~ private,
             "the model-facing Local output exposed private artifact-use provenance #{inspect(private)}"
    end
  end

  test "a real executor refuses a dishonest retained artifact instead of returning its reference" do
    for mode <- [:wrong_digest, :private_locator, :missing_describe] do
      root = workspace()
      full = String.duplicate("dishonest-output\n", 512)
      File.write!(Path.join(root, "large.txt"), full)
      {:ok, artifact_store} = ContractStore.start(mode)
      {executor, lease_id} = executor_for(root, artifact_store)

      identity = %{
        session_id: "dishonest-session",
        run_id: "dishonest-run",
        operation_id: "dishonest-operation",
        attempt: 1,
        tool_call_id: "dishonest-call"
      }

      assert {:ok, receipt} = execute_read(executor, lease_id, identity)
      assert [{retained, normalized}] = ContractStore.calls(artifact_store)
      assert retained == full

      assert Map.has_key?(normalized, :metadata),
             "the executor bypassed Core normalization: #{inspect(normalized)}"

      metadata = Map.fetch!(normalized, :metadata)

      assert metadata["session_id"] == identity.session_id
      assert metadata["run_id"] == identity.run_id
      assert metadata["operation_id"] == identity.operation_id
      assert metadata["attempt"] == identity.attempt
      assert metadata["tool_call_id"] == identity.tool_call_id
      assert receipt.outcome == :completed
      assert receipt.artifacts == []
      assert receipt.output =~ "nothing beyond it was retained"
    end
  end

  test "read retains below capture limits at the complete escaped message boundary" do
    root = workspace()
    {:ok, artifact_store} = ContractStore.start()
    {executor, lease_id} = executor_for(root, artifact_store)
    identity = identity()
    id = Loopex.Conversation.normalized_call_id(identity.run_id, 1, identity.tool_call_id)
    empty = %{"role" => "tool", "tool_call_id" => id, "outcome" => "completed", "content" => ""}
    {:ok, framing} = LoopexProtocol.Frame.encode(empty)
    overhead = byte_size(IO.iodata_to_binary(framing)) - 1

    for {content, expected_size, retain?} <- [
          {String.duplicate("x", 2_048 - overhead), 2_048, false},
          {String.duplicate("x", 2_049 - overhead), 2_049, true},
          {String.duplicate("\"", 1_000), overhead + 2_000, true}
        ] do
      File.write!(Path.join(root, "large.txt"), content)
      {:ok, encoded} = LoopexProtocol.Frame.encode(%{empty | "content" => content})
      assert byte_size(IO.iodata_to_binary(encoded)) - 1 == expected_size

      assert {:ok, receipt} =
               execute_read(executor, lease_id, identity, %{
                 tool_version: "1.1.0",
                 resource_budgets: %{"max_output_bytes" => 16_384},
                 artifact_policy: policy(identity, read_binding())
               })

      assert receipt.outcome == :completed
      assert byte_size(content) < 16_384

      if retain? do
        assert [reference] = receipt.artifacts
        assert reference.size == byte_size(content)
        assert {:ok, ^content} = ArtifactStore.fetch(store(artifact_store), reference)
      else
        assert receipt.artifacts == []
        assert receipt.output == content
      end
    end

    assert length(ContractStore.calls(artifact_store)) == 2
  end

  test "current reads without projection or with null capability retain inline bytes" do
    root = workspace()
    content = String.duplicate("\"", 2_000)
    File.write!(Path.join(root, "large.txt"), content)
    {:ok, artifact_store} = ContractStore.start()
    {executor, lease_id} = executor_for(root, artifact_store)

    for {version, policy} <- [
          {"1.1.0", %{"retain" => true}},
          {"1.1.0", policy(identity(), nil)}
        ] do
      assert {:ok, receipt} =
               execute_read(executor, lease_id, identity(), %{
                 tool_version: version,
                 resource_budgets: %{"max_output_bytes" => 16_384},
                 artifact_policy: policy
               })

      assert receipt.output == content
      assert receipt.artifacts == []
    end

    assert ContractStore.calls(artifact_store) == []
  end

  test "each new search generation retains exactly its captured records and receipt stays immutable" do
    root = workspace()

    for number <- 1..200,
        do:
          File.write!(
            Path.join(root, "entry-#{number}-" <> String.duplicate("n", 64)),
            "needle\n"
          )

    {:ok, artifact_store} = ContractStore.start()
    {executor, lease_id} = executor_for(root, artifact_store)

    for {id, arguments} <- [
          {"loopex.ls", %{}},
          {"loopex.find", %{"pattern" => "**"}},
          {"loopex.grep", %{"pattern" => "needle"}}
        ] do
      {:ok, admitted} = Loopex.Executor.Local.ReadOnlyTools.arguments(id, arguments)
      {:completed, captured} = Loopex.Executor.Local.ReadOnlyTools.execute(root, admitted, 16_384)
      assert byte_size(captured) > 2_048 and byte_size(captured) <= 16_384

      {job, grant} =
        read_job(lease_id, identity(), %{
          tool_id: id,
          tool_version: "1.1.0",
          validated_arguments: arguments,
          resource_budgets: %{"max_output_bytes" => 16_384},
          artifact_policy: policy(identity(), read_binding())
        })

      assert {:ok, receipt} =
               Local.execute(executor, job, grant, [], Loopex.Executor.discard_progress())

      assert [reference] = receipt.artifacts
      assert reference.size == byte_size(captured)
      assert {:ok, ^captured} = ArtifactStore.fetch(store(artifact_store), reference)
      assert receipt.canonical_request_digest == job.canonical_request_digest
      calls = ContractStore.calls(artifact_store)
      File.rm!(Path.join(root, "entry-1-" <> String.duplicate("n", 64)))

      assert {:ok, ^receipt} =
               Local.execute(executor, job, grant, [], Loopex.Executor.discard_progress())

      assert ContractStore.calls(artifact_store) == calls
      File.write!(Path.join(root, "entry-1-" <> String.duplicate("n", 64)), "needle\n")
    end
  end

  test "new search jobs require the closed projection context before any effect" do
    root = workspace()
    {:ok, artifact_store} = ContractStore.start()
    {executor, lease_id} = executor_for(root, artifact_store)

    {job, grant} =
      read_job(lease_id, identity(), %{
        tool_id: "loopex.ls",
        tool_version: "1.1.0",
        validated_arguments: %{},
        resource_budgets: %{"max_output_bytes" => 16_384}
      })

    assert {:error, reason} =
             Local.execute(executor, job, grant, [], Loopex.Executor.discard_progress())

    assert inspect(reason) =~ "invalid_projection_context"
    assert ContractStore.calls(artifact_store) == []

    good = policy(identity(), read_binding())
    fields = Map.from_struct(job)

    for bad <- [
          put_in(good, ["projection", "revision"], 2),
          put_in(good, ["projection", "normalized_call_id"], "raw"),
          put_in(
            good,
            ["projection", "artifact_read", "definition_digest"],
            String.duplicate("0", 64)
          ),
          put_in(good, ["projection", "extra"], true),
          Map.put(good, "extra", true)
        ] do
      assert {:error, :invalid_job_request} =
               Loopex.Executor.job(%{fields | artifact_policy: bad})
    end

    assert {:ok, changed} = Loopex.Executor.job(%{fields | artifact_policy: good})
    refute changed.canonical_request_digest == job.canonical_request_digest

    assert {:error, _} =
             Loopex.Executor.validate_grant(changed, grant, %{
               executor_identity: changed.executor_identity,
               workspace_lease: lease_id,
               fencing_token: @fence,
               now: System.system_time(:millisecond)
             })
  end

  test "current searches with explicit null capability keep inline output" do
    root = workspace()

    for number <- 1..100,
        do:
          File.write!(Path.join(root, "entry-#{number}-" <> String.duplicate("n", 40)), "needle")

    {:ok, artifact_store} = ContractStore.start()
    {executor, lease_id} = executor_for(root, artifact_store)
    {:ok, arguments} = Loopex.Executor.Local.ReadOnlyTools.arguments("loopex.ls", %{})
    {:completed, captured} = Loopex.Executor.Local.ReadOnlyTools.execute(root, arguments, 16_384)
    assert byte_size(captured) > 2_048

    for {version, policy} <- [{"1.1.0", policy(identity(), nil)}] do
      assert {:ok, receipt} =
               execute_read(executor, lease_id, identity(), %{
                 tool_id: "loopex.ls",
                 tool_version: version,
                 validated_arguments: %{},
                 resource_budgets: %{"max_output_bytes" => 16_384},
                 artifact_policy: policy
               })

      assert receipt.output == captured
      assert receipt.artifacts == []
    end

    assert ContractStore.calls(artifact_store) == []
  end

  test "the exact full read capture survives early retention and projection" do
    root = workspace()
    full = String.duplicate("x", 16_384)
    File.write!(Path.join(root, "large.txt"), full)
    {:ok, artifact_store} = ContractStore.start()
    {executor, lease_id} = executor_for(root, artifact_store)

    assert {:ok, receipt} =
             execute_read(executor, lease_id, identity(), %{
               tool_version: "1.1.0",
               resource_budgets: %{"max_output_bytes" => 16_384},
               artifact_policy: policy(identity(), read_binding())
             })

    assert [reference] = receipt.artifacts
    assert reference.size == 16_384
    assert [{^full, _use}] = ContractStore.calls(artifact_store)
    assert {:ok, ^full} = ArtifactStore.fetch(store(artifact_store), reference)

    assert {:ok, projected} =
             Loopex.Runtime.ToolResultExcerpt.encode(
               %{
                 "role" => "tool",
                 "tool_call_id" =>
                   policy(identity(), read_binding())["projection"]["normalized_call_id"],
                 "outcome" => "completed",
                 "content" => receipt.output
               },
               reference
             )

    assert {:ok, encoded} = LoopexProtocol.Frame.encode(projected.message)
    assert byte_size(IO.iodata_to_binary(encoded)) - 1 <= 2_048
    assert length(ContractStore.calls(artifact_store)) == 1
  end

  test "dishonest early retention exposes no reference and preserves the tool outcome" do
    root = workspace()
    full = String.duplicate("\"", 2_000)
    File.write!(Path.join(root, "large.txt"), full)

    for mode <- [:wrong_digest, :private_locator, :missing_describe] do
      {:ok, artifact_store} = ContractStore.start(mode)
      {executor, lease_id} = executor_for(root, artifact_store)

      assert {:ok, receipt} =
               execute_read(executor, lease_id, identity(), %{
                 tool_version: "1.1.0",
                 resource_budgets: %{"max_output_bytes" => 16_384},
                 artifact_policy: policy(identity(), read_binding())
               })

      assert receipt.outcome == :completed
      assert receipt.artifacts == []
      assert receipt.output =~ "retention unavailable"
      assert [{^full, use}] = ContractStore.calls(artifact_store)

      assert Map.keys(use.metadata) |> Enum.sort() ==
               ~w(attempt operation_id run_id session_id tool_call_id)
    end
  end

  test "cancelling early retention joins its blocked worker before returning" do
    root = workspace()
    File.write!(Path.join(root, "large.txt"), String.duplicate("\"", 2_000))
    {:ok, artifact_store} = ContractStore.start({:hold, self()})
    {executor, lease_id} = executor_for(root, artifact_store)

    {job, grant} =
      read_job(lease_id, identity(), %{
        tool_version: "1.1.0",
        resource_budgets: %{"max_output_bytes" => 16_384},
        artifact_policy: policy(identity(), read_binding())
      })

    task =
      Task.async(fn ->
        Local.execute(executor, job, grant, [], Loopex.Executor.discard_progress())
      end)

    assert_receive {:early_retention_blocked, worker}, 5_000
    monitor = Process.monitor(worker)
    assert {:ok, :cleaned} = Local.cancel(executor, job.job_id)
    refute Process.alive?(worker)
    assert_receive {:DOWN, ^monitor, :process, ^worker, _}, 0
    assert {:ok, receipt} = Task.await(task, 5_000)
    assert receipt.artifacts == []
    assert length(ContractStore.calls(artifact_store)) == 1
  end

  test "the fixed run cutoff abandons early retention and joins its exact worker" do
    root = workspace()
    File.write!(Path.join(root, "large.txt"), String.duplicate("\"", 2_000))
    {:ok, artifact_store} = ContractStore.start({:hold, self()})
    {executor, lease_id} = executor_for(root, artifact_store)
    cutoff = System.system_time(:millisecond) + 500

    {job, grant} =
      read_job(lease_id, identity(), %{
        tool_version: "1.1.0",
        resource_budgets: %{"max_output_bytes" => 16_384},
        artifact_policy: policy(identity(), read_binding()),
        run_deadline: cutoff,
        cleanup_grace_ms: 8_000
      })

    task =
      Task.async(fn ->
        Local.execute(executor, job, grant, [], Loopex.Executor.discard_progress())
      end)

    assert_receive {:early_retention_blocked, worker}, 400
    monitor = Process.monitor(worker)
    assert {:ok, receipt} = Task.await(task, 5_000)
    assert receipt.outcome == :completed
    assert receipt.artifacts == []
    assert receipt.output =~ "the run deadline passed"
    assert job.run_deadline == cutoff
    refute Process.alive?(worker)
    assert_receive {:DOWN, ^monitor, :process, ^worker, _}, 0
    assert length(ContractStore.calls(artifact_store)) == 1
  end

  defp identity do
    %{
      session_id: "private-session",
      run_id: "private-run",
      operation_id: "private-operation",
      attempt: 1,
      tool_call_id: "private-call"
    }
  end

  defp read_binding do
    Loopex.Runtime.ArtifactReadCapabilities.table() |> Map.values() |> Enum.find(& &1)
  end

  defp policy(identity, binding) do
    Loopex.Executor.JobRequest.artifact_policy(
      "loopex.read",
      "1.1.0",
      binding,
      Loopex.Conversation.normalized_call_id(identity.run_id, 1, identity.tool_call_id)
    )
  end

  defp execute_read(executor, lease_id, identity, overrides \\ %{}) do
    {job, grant} = read_job(lease_id, identity, overrides)
    Local.execute(executor, job, grant, [], Loopex.Executor.discard_progress())
  end

  defp read_job(lease_id, identity, overrides) do
    fields =
      Map.merge(
        %{
          protocol_version: 1,
          job_id: "job-#{System.unique_integer([:positive])}",
          turn_id: "turn-1",
          origin_session_epoch: 1,
          origin_executor_epoch: 3,
          executor_identity: "executor-local",
          required_capabilities: ["process"],
          tool_id: "loopex.read",
          tool_version: "1.1.0",
          effect_class: "read_only",
          validated_arguments: %{"path" => "large.txt"},
          workspace_ref: "workspace",
          workspace_lease: lease_id,
          run_deadline: System.system_time(:millisecond) + 60_000,
          resource_budgets: %{"max_output_bytes" => 128},
          idempotency_class: "never_blind_retry",
          fencing_token: @fence,
          artifact_policy: %{"retain" => true},
          output_policy: %{"capture" => true}
        },
        identity
      )

    {:ok, job} = Loopex.Executor.job(Map.merge(fields, overrides))

    {:ok, grant} =
      Loopex.Executor.issue_grant(
        {:host_policy, :allow},
        job,
        System.system_time(:millisecond) + 60_000
      )

    {job, grant}
  end

  defp executor_for(root, artifact_store) do
    lease_id = "lease-#{System.unique_integer([:positive])}"
    {:ok, lease} = WorkspaceLease.start_link(id: lease_id, path: root, fencing_token: @fence)
    ledger = temporary_root("artifact-ledger")
    on_exit(fn -> File.rm_rf(ledger) end)

    {:ok, executor} =
      Local.start_link(
        identity: "executor-local",
        epoch: 3,
        fencing_token: @fence,
        workspace_leases: %{lease_id => lease},
        ledger_root: ledger,
        artifacts: store(artifact_store)
      )

    {executor, lease_id}
  end

  defp store(handle), do: %{module: ContractStore, handle: handle}

  defp invoke_core(name, arguments) do
    if function_exported?(ArtifactStore, name, length(arguments)) do
      apply(ArtifactStore, name, arguments)
    else
      {:error, {:artifact_object_use_contract_missing, name, length(arguments)}}
    end
  end

  defp workspace do
    root = temporary_root("artifact-workspace")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    root
  end

  defp temporary_root(prefix) do
    Path.join(
      System.tmp_dir!(),
      "loopex-#{prefix}-#{System.unique_integer([:positive])}"
    )
  end
end
