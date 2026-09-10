# Concept: observe required-context refusal through a real local session and Store.
# Technical depth: the deterministic model supplies only the positive control;
# no tools are registered and any executor invocation invalidates this probe.
defmodule Loopex.M3Opening.Model do
  def complete(request, options, _progress) do
    send(Keyword.fetch!(options, :observer), :model_called)

    {:ok,
     %{
       text: "done",
       identity: %{provider: "fixture", model: request.model, endpoint: "in-process"},
       usage: %{input_tokens: 1, output_tokens: 1},
       tool_calls: [],
       delta_count: 0,
       streamed: false,
       canonical_request_bytes: request.canonical_request_bytes,
       staged_request_digest: request.staged_request_digest
     }}
  end
end

defmodule Loopex.M3Opening.Policy do
  def decide(_), do: {:allow, nil}
end

defmodule Loopex.M3Opening.Executor do
  def execute(observer, _, _, _, _) do
    send(observer, :unexpected_executor_call)
    {:error, {:refused_before_effect, :no_probe_tools}}
  end

  def cancel(_, _), do: {:ok, :cleaned}
end

defmodule Loopex.M3Opening do
  alias Loopex.Store

  def run(root) do
    small = observe(root, 100, false)
    project_control = observe(root, 100, true)
    required = observe(root, 32_000, false)
    optional = observe(root, 32_000, true)

    for control <- [small, project_control] do
      true = control.calls == 1 and is_nil(control.refusal)
      true = is_map(control.staged)
    end

    "staged" = get_in(project_control.staged, ["project_resource", "disposition"])

    true =
      Enum.any?(project_control.staged["blocks"], &(&1["provenance_class"] == "project_resource"))

    for overflow <- [required, optional] do
      true = overflow.calls == 0 and is_nil(overflow.staged)

      %{
        "dimension" => "context_record_bytes",
        "limit" => limit,
        "observed" => observed,
        "record_byte_cost" => observed,
        "system_message_count" => 1,
        "session_message_count" => 1,
        "steer_message_count" => 0,
        "tool_definition_count" => 0
      } = overflow.refusal

      true = limit == Store.max_item_bytes() and observed > limit
      true = is_binary(overflow.refusal["ordered_descriptor_digest"])
      true = byte_size(overflow.refusal["ordered_descriptor_digest"]) == 64
    end

    "no_manifest" = required.refusal["project_disposition"]

    true =
      required.refusal["provider_estimated_tokens"] ==
        optional.refusal["provider_estimated_tokens"]

    disposition = optional.refusal["project_disposition"]

    IO.puts(
      "LOOPEX_M3_OBSERVATION controls=2/2 required_bytes=#{required.refusal["observed"]} optional_retry_bytes=#{optional.refusal["observed"]} ceiling=#{Store.max_item_bytes()} overflow_model_calls=0 required_counts=1,1,0,0 project_disposition=#{disposition}"
    )

    case disposition do
      "context_record_bytes" ->
        IO.puts(
          "M3 gate RED: required-only context overflow evaluates optional project content before refusal"
        )

        System.halt(1)

      "not_evaluated_required_failure" ->
        :ok

      _ ->
        raise "unexpected required-overflow project disposition"
    end
  end

  defp observe(root, size, project?) do
    label = "probe-#{size}-#{project?}"
    {:ok, pid} = Loopex.Store.Local.start_link(path: Path.join(root, label <> ".log"))
    {:ok, store} = Store.new(Loopex.Store.Local, pid)
    content = "bounded project instructions"

    manifest = %{
      entries: [
        %{
          label: "AGENTS.md",
          content: content,
          byte_size: byte_size(content),
          content_digest: LoopexProtocol.Canonical.digest_bytes(content),
          contained: true
        }
      ],
      workspace: %{workspace_ref: "workspace-ref", repository_origin: nil, revision: nil}
    }

    {:ok, digest, _} = Loopex.ProjectResource.digest(manifest)

    decision = %{
      manifest_digest: digest,
      workspace_ref: "workspace-ref",
      trust_scope: "project_resource",
      decision_source: "host_supplied",
      issued_at: "2026-09-01T00:00:00Z",
      expires_at: nil,
      revocation_state: "active"
    }

    {:ok, runtime} =
      Loopex.start_link(
        runtime_id: label,
        store: store,
        model: %{module: Loopex.M3Opening.Model, model: "fixture:v1", options: [observer: self()]},
        executor: %{
          module: Loopex.M3Opening.Executor,
          reference: self(),
          identity: "probe-executor",
          epoch: 1,
          fencing_token: 1,
          workspace_ref: "workspace-ref",
          workspace_lease: "workspace-lease"
        },
        policy: Loopex.M3Opening.Policy,
        bounds: %{max_turns: 1, token_budget: 100_000, deadline_ms: 60_000},
        context_token_budget: 100_000,
        tools: [],
        active_tools: [],
        project_manifest: if(project?, do: manifest),
        project_decision: if(project?, do: decision)
      )

    try do
      {:ok, session} = Loopex.create_session(runtime, %{}, command_id: label <> "-create")
      {:ok, attachment} = Loopex.attach(runtime, session, after_event_sequence: 0)

      {:accepted, _} =
        Loopex.command(attachment, %{
          type: :prompt,
          command_id: label,
          content: String.duplicate("x", size)
        })

      settle(runtime, session, System.monotonic_time(:millisecond) + 6_000)
      {:ok, records} = Store.load_records(store, session, 0, 100)

      result =
        Enum.find(records, &(to_string(&1.payload[:kind]) == "context_admission_refused_v1"))

      staged = Enum.find(records, &(to_string(&1.payload[:kind]) == "model_request_committed"))

      if staged do
        {:ok, _normalized, measured} = Store.normalize_and_measure_item(:record, staged.payload)
        true = measured == staged.payload["context_receipt"]["record_byte_cost"]
      end

      %{
        refusal: result && result.payload,
        staged: staged && staged.payload["context_receipt"],
        calls: drain(0)
      }
    after
      Loopex.stop(runtime)
      GenServer.stop(pid)
    end
  end

  defp settle(runtime, session, deadline) do
    case Loopex.session_status(runtime, session) do
      {:ok, %{active_run_id: nil, pending_work_ids: []}} ->
        :ok

      _ ->
        if System.monotonic_time(:millisecond) >= deadline, do: raise("session did not settle")
        Process.sleep(10)
        settle(runtime, session, deadline)
    end
  end

  defp drain(calls) do
    receive do
      :model_called -> drain(calls + 1)
      :unexpected_executor_call -> raise "unexpected executor invocation"
      _ -> drain(calls)
    after
      0 -> calls
    end
  end
end

Process.flag(:trap_exit, true)

try do
  [root] = System.argv()
  Loopex.M3Opening.run(root)
rescue
  error ->
    IO.puts(
      :stderr,
      "M3 opening UNAVAILABLE: #{inspect(error.__struct__)}: #{Exception.message(error) |> String.slice(0, 500)}"
    )

    System.halt(2)
catch
  kind, _reason ->
    IO.puts(:stderr, "M3 opening UNAVAILABLE: #{kind}")
    System.halt(2)
end

