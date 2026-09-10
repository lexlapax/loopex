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

# Concept: observe actual candidate evaluation without changing product code.
# Technical depth: only fixture-runtime descendants inherit call tracing. The
# dedicated tracer discards candidate bodies and retains bounded counters only.
# Both boundaries have positive controls; delivery is fenced before reading them.
defmodule Loopex.M3Opening.Trace do
  @boundaries [
    {Loopex.Runtime.ContextAdmission, :preflight_required_candidate, 2},
    {Loopex.Store, :normalize_and_measure_item, 2}
  ]

  def start do
    tracer =
      spawn_link(fn ->
        collect(%{
          required_store: 0,
          optional_store: 0,
          required_admission: 0,
          optional_admission: 0
        })
      end)

    for {module, _, _} = boundary <- @boundaries do
      {:module, ^module} = Code.ensure_loaded(module)
      1 = :erlang.trace_pattern(boundary, true, [:local])
    end

    1 = :erlang.trace(self(), true, [:call, :set_on_spawn, {:tracer, tracer}])
    tracer
  end

  def detach_parent do
    1 = :erlang.trace(self(), false, [:call, :set_on_spawn])
  end

  def finish(tracer) do
    barrier = :erlang.trace_delivered(:all)

    receive do
      {:trace_delivered, :all, ^barrier} -> :ok
    after
      1_000 -> throw({:witness_error, "trace_delivery_barrier_missing"})
    end

    for boundary <- @boundaries, do: :erlang.trace_pattern(boundary, false, [:local])
    send(tracer, {:finish, self()})

    receive do
      {:candidate_trace, ^tracer, counts} -> counts
    after
      1_000 -> throw({:witness_error, "trace_collector_result_missing"})
    end
  end

  defp collect(counts) do
    receive do
      {:trace, _pid, :call, {Loopex.Store, :normalize_and_measure_item, [:record, candidate]}} ->
        collect(count(counts, candidate, :required_store, :optional_store))

      {:trace, _pid, :call,
       {Loopex.Runtime.ContextAdmission, :preflight_required_candidate, [candidate, _]}} ->
        collect(count(counts, candidate, :required_admission, :optional_admission))

      {:finish, caller} ->
        send(caller, {:candidate_trace, self(), counts})

      _ ->
        collect(counts)
    end
  end

  defp count(counts, %{"context_receipt" => %{"blocks" => blocks}}, required, optional)
       when is_list(blocks) do
    key =
      if Enum.any?(blocks, &(is_map(&1) and &1["provenance_class"] == "project_resource")),
        do: optional,
        else: required

    Map.update!(counts, key, &min(&1 + 1, 1_024))
  end

  defp count(counts, _candidate, _required, _optional), do: counts
end

defmodule Loopex.M3Opening do
  alias Loopex.Store

  def run(root) do
    small = observe(root, 100, false)
    project_control = observe(root, 100, true)
    required = observe(root, 32_000, false)
    optional = observe(root, 32_000, true)

    for {name, control} <- [{"required_control", small}, {"project_control", project_control}] do
      require_witness(control.calls == 1, name <> "_model_call_missing_or_duplicate")

      require_witness(
        is_nil(control.refusal) and is_map(control.staged),
        name <> "_staged_receipt_missing"
      )
    end

    require_witness(
      get_in(project_control.staged, ["project_resource", "disposition"]) == "staged",
      "project_control_not_staged"
    )

    require_witness(
      Enum.any?(
        project_control.staged["blocks"],
        &(&1["provenance_class"] == "project_resource")
      ),
      "project_control_descriptor_missing"
    )

    require_witness(
      small.trace.required_store > 0 and small.trace.required_admission > 0,
      "required_control_trace_missing"
    )

    require_witness(
      project_control.trace.optional_store > 0 and project_control.trace.optional_admission > 0,
      "project_control_trace_missing"
    )

    for {name, overflow} <- [{"required_overflow", required}, {"project_overflow", optional}] do
      require_witness(
        overflow.calls == 0 and is_nil(overflow.staged),
        name <> "_unexpected_dispatch_or_staging"
      )

      require_witness(
        match?(
          %{
            "dimension" => "context_record_bytes",
            "limit" => _limit,
            "observed" => observed,
            "record_byte_cost" => observed,
            "system_message_count" => 1,
            "session_message_count" => 1,
            "steer_message_count" => 0,
            "tool_definition_count" => 0
          },
          overflow.refusal
        ),
        name <> "_invalid_compact_refusal"
      )

      require_witness(
        overflow.refusal["limit"] == Store.max_item_bytes() and
          overflow.refusal["observed"] > overflow.refusal["limit"],
        name <> "_not_above_byte_ceiling"
      )

      digest = overflow.refusal["ordered_descriptor_digest"]

      require_witness(
        is_binary(digest) and byte_size(digest) == 64,
        name <> "_descriptor_digest_missing"
      )

      require_witness(overflow.trace.required_store > 0, name <> "_required_measurement_missing")
    end

    require_witness(
      required.refusal["project_disposition"] == "no_manifest",
      "required_overflow_unexpected_project"
    )

    require_witness(
      required.refusal["provider_estimated_tokens"] ==
        optional.refusal["provider_estimated_tokens"],
      "required_token_observations_disagree"
    )

    disposition = optional.refusal["project_disposition"]

    IO.puts(
      "LOOPEX_M3_OBSERVATION controls=2/2 required_bytes=#{required.refusal["observed"]} optional_retry_bytes=#{optional.refusal["observed"]} ceiling=#{Store.max_item_bytes()} overflow_model_calls=0 required_counts=1,1,0,0 project_disposition=#{disposition} optional_store_measurements=#{optional.trace.optional_store} optional_admissions=#{optional.trace.optional_admission}"
    )

    if optional.trace.optional_store > 0 or optional.trace.optional_admission > 0 do
      IO.puts(
        "M3 gate RED: required-only context overflow evaluates optional project content before refusal"
      )

      System.halt(1)
    else
      require_witness(
        disposition == "not_evaluated_required_failure",
        "required_overflow_wrong_project_disposition"
      )
    end
  end

  defp require_witness(true, _reason), do: :ok
  defp require_witness(false, reason), do: throw({:witness_error, reason})

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

    tracer = Loopex.M3Opening.Trace.start()

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

    Loopex.M3Opening.Trace.detach_parent()

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

        require_witness(
          measured == staged.payload["context_receipt"]["record_byte_cost"],
          label <> "_staged_byte_cost_mismatch"
        )
      end

      Loopex.stop(runtime)
      trace = Loopex.M3Opening.Trace.finish(tracer)

      %{
        refusal: result && result.payload,
        staged: staged && staged.payload["context_receipt"],
        calls: drain(0),
        trace: trace
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
        require_witness(
          System.monotonic_time(:millisecond) < deadline,
          "session_settlement_deadline_exceeded"
        )

        Process.sleep(10)
        settle(runtime, session, deadline)
    end
  end

  defp drain(calls) do
    receive do
      :model_called -> drain(calls + 1)
      :unexpected_executor_call -> throw({:witness_error, "unexpected_executor_invocation"})
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
  :throw, {:witness_error, reason} ->
    IO.puts(:stderr, "M3 opening WITNESS ERROR: #{reason}")
    System.halt(2)

  kind, _reason ->
    IO.puts(:stderr, "M3 opening UNAVAILABLE: #{kind}")
    System.halt(2)
end
