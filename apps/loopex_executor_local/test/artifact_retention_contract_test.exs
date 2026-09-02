defmodule Loopex.Executor.Local.ArtifactRetentionContractTest do
  @moduledoc false

  use ExUnit.Case, async: false

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

  defp execute_read(executor, lease_id, identity) do
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
          tool_version: "1.0.0",
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

    {:ok, job} = Loopex.Executor.job(fields)

    {:ok, grant} =
      Loopex.Executor.issue_grant(
        {:host_policy, :allow},
        job,
        System.system_time(:millisecond) + 60_000
      )

    Local.execute(executor, job, grant, [], Loopex.Executor.discard_progress())
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
