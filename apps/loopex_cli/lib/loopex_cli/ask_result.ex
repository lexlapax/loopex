defmodule LoopexCli.AskResult do
  @moduledoc """
  ## Concept

  Renders one bounded public `ask` observation without exposing private run or
  command state.

  ## Technical depth

  The command selects its public ending and cleanup proof before calling this
  private renderer. It emits the closed `loopex.ask/1` object or text lines and
  maps malformed input to a fixed diagnostic with zero standard-output bytes.
  """

  @uint64_max 18_446_744_073_709_551_615
  @observed_max 55_340_232_221_128_654_844
  @tool_outcomes ~w(completed failed denied cancelled cancelled_workspace_lease_lost outcome_unknown)
  @pending [:run_ending, :effect_cleanup, :process_groups, :session_subtree, :root_removal]
  @diagnostics [
    :invalid_arguments,
    :invalid_output,
    :invalid_state_root,
    :invalid_cwd,
    :invalid_model,
    :invalid_tools,
    :invalid_skills,
    :invalid_max_steps,
    :invalid_deadline,
    :invalid_trace_configuration,
    :trace_start_failed,
    :policy_required,
    :invalid_policy,
    :workspace_unusable,
    :invalid_prompt_empty,
    :invalid_prompt_too_large,
    :invalid_prompt_invalid_utf8,
    :skill_directories_unavailable,
    :application_start_failed,
    :durable_model_unsupported,
    :provider_credential_required,
    :durable_runtime_unavailable,
    :composition_unavailable,
    :session_create_failed,
    :session_tracking_failed,
    :attachment_failed,
    :resource_admission_failed,
    :skill_activation_failed,
    :session_status_failed,
    :prompt_submission_failed,
    :follow_reader_cleanup_unconfirmed,
    :interrupt_handler_unavailable,
    :runtime_cleanup_unconfirmed,
    :session_unavailable,
    :command_failed
  ]

  @doc """
  ## Concept

  Converts a selected ending into its exit status and output bytes.

  ## Technical depth

  `ending` is the public run result or no-ending value. `cleanup` is `:proved`,
  `:durable`, or `{:unproved, public_map}`. No opaque handle is read here.
  """
  @spec render(term(), term(), :text | :json) :: %{
          status: integer(),
          stdout: binary(),
          stderr: binary()
        }
  def render(ending, cleanup, mode) do
    try do
      do_render(ending, cleanup, mode)
    rescue
      _ -> diagnostic(:command_failed)
    catch
      _, _ -> diagnostic(:command_failed)
    end
  end

  @doc """
  ## Concept

  Renders one status-1 refusal without including its source value.

  ## Technical depth

  Only the accepted fixed codes are emitted. An unknown code maps to the
  contract's `command_failed` fallback.
  """
  @spec diagnostic(term()) :: %{status: 1, stdout: <<>>, stderr: binary()}
  def diagnostic(code) do
    fixed = if code in @diagnostics, do: code, else: :command_failed

    guidance =
      if fixed == :interrupt_handler_unavailable do
        "loopex: The interrupt handler is unavailable. Before running ask again, make sure the previous ask process has exited and start a fresh command. If this repeats, fix the host's signal handling so Loopex can safely handle Ctrl-C and termination signals.\n"
      else
        ""
      end

    %{status: 1, stdout: "", stderr: "loopex: #{fixed}\n" <> guidance}
  end

  defp do_render(:none, {:unproved, map}, mode) when mode in [:text, :json] do
    {_cleanup, root_line} = cleanup!(:ephemeral, {:unproved, map})
    %{status: 1, stdout: "", stderr: root_line}
  end

  defp do_render(:none, :proved, mode) when mode in [:text, :json],
    do: diagnostic(:session_unavailable)

  defp do_render({:error, :session_unavailable}, _cleanup, mode) when mode in [:text, :json],
    do: diagnostic(:session_unavailable)

  defp do_render(ending, cleanup, mode) when mode in [:text, :json] do
    require!(not match?({:unproved, %{root: nil}}, cleanup))
    {status, outcome, observation, details} = ending!(ending)
    profile = Map.fetch!(observation, :profile)
    require!(profile in [:ephemeral, :durable])

    # Concept: an unproved cleanup map is the source of its selected ending;
    # a post-admission ephemeral session loss cannot claim proved cleanup.
    # Technical depth: this is the command's public-result boundary. The
    # selector's precedence alone cannot validate a direct or malformed call.
    case cleanup do
      {:unproved, %{ending: ^ending}} -> :ok
      {:unproved, _} -> invalid!()
      _ -> :ok
    end

    if profile == :ephemeral and outcome == :no_ending and
         Map.fetch!(details, :reason) == "session_unavailable" do
      require!(match?({:unproved, _}, cleanup))
    end

    {cleanup_object, root_line} = cleanup!(profile, cleanup)
    object = object!(observation, profile, outcome, details, cleanup_object)

    case mode do
      :json ->
        %{status: status, stdout: JSON.encode!(object) <> "\n", stderr: root_line}

      :text ->
        stdout = if outcome == :completed, do: object.text <> "\n", else: ""
        %{status: status, stdout: stdout, stderr: text_lines(object) <> root_line}
    end
  end

  defp do_render(_, _, _), do: diagnostic(:command_failed)

  defp ending!({:ok, %{outcome: :completed} = observation}),
    do: {0, :completed, observation, details!(:completed, Map.fetch!(observation, :details))}

  defp ending!({:error, {:run, outcome, %{outcome: outcome} = observation}})
       when outcome in [:failed, :bound_reached, :outcome_unknown, :cancelled] do
    status = %{failed: 2, bound_reached: 3, outcome_unknown: 4, cancelled: 5}[outcome]
    {status, outcome, observation, details!(outcome, Map.fetch!(observation, :details))}
  end

  defp ending!({:error, {reason, snapshot}})
       when reason in [:timeout, :session_unavailable] and is_map(snapshot) do
    waited = decimal!(Map.fetch!(snapshot, :waited_ms), :nonnegative, @uint64_max)
    {6, :no_ending, snapshot, %{reason: Atom.to_string(reason), waited_ms: waited}}
  end

  defp ending!(_), do: invalid!()

  defp object!(source, profile, outcome, details, cleanup) do
    session_id = Map.fetch!(source, :session_id)
    run_id = Map.fetch!(source, :run_id)
    text = Map.fetch!(source, :text)
    text_truncated = Map.fetch!(source, :text_truncated)
    tools = Map.fetch!(source, :tools)
    tools_truncated = Map.fetch!(source, :tools_truncated)
    shadowed = Map.fetch!(source, :shadowed_skills)

    require!(bounded_text?(session_id, 1_024, false))
    require!((outcome == :no_ending and is_nil(run_id)) or bounded_text?(run_id, 1_024, false))
    require!(bounded_text?(text, 65_536, true))
    require!(is_boolean(text_truncated) and (text != "" or not text_truncated))
    require!(is_boolean(tools_truncated) and (tools != [] or not tools_truncated))
    require!(bounded_list?(tools, 256, &tool?/1))
    require!(bounded_list?(shadowed, 4, &shadowed_skill?/1))
    require!(shadowed == shadowed |> Enum.uniq() |> Enum.sort())

    %{
      schema: "loopex.ask/1",
      session_id: session_id,
      run_id: run_id,
      profile: Atom.to_string(profile),
      outcome: Atom.to_string(outcome),
      text: text,
      text_truncated: text_truncated,
      tools: Enum.map(tools, &Map.take(&1, [:tool_id, :outcome])),
      tools_truncated: tools_truncated,
      shadowed_skills: shadowed,
      cleanup: cleanup,
      details: details
    }
  end

  defp details!(outcome, details) when outcome in [:completed, :cancelled] do
    require!(is_map(details))
    %{cleanup_grace_ms: decimal!(Map.fetch!(details, "cleanup_grace_ms"), :positive, @uint64_max)}
  end

  defp details!(:failed, details) do
    require!(is_map(details))
    reason = Map.fetch!(details, "reason")
    failure = Map.fetch!(details, "failure")

    require!(
      (reason in ["model_call_failed", "unreadable_model_answer"] and is_nil(failure)) or
        (is_nil(reason) and is_map(failure))
    )

    %{
      reason: reason,
      failure: if(is_nil(failure), do: nil, else: failure!(failure)),
      cleanup_grace_ms: decimal!(Map.fetch!(details, "cleanup_grace_ms"), :positive, @uint64_max)
    }
  end

  defp details!(:bound_reached, details) do
    require!(is_map(details))
    bound = Map.fetch!(details, "bound")
    accounting = Map.fetch!(details, "accounting_source")
    require!(bound in ["max_turns", "token_budget", "deadline"])
    require!(accounting in ["reported", "estimated", nil])

    %{
      bound: bound,
      observed: decimal!(Map.fetch!(details, "observed"), :nonnegative, @observed_max),
      declared_limit: decimal!(Map.fetch!(details, "declared_limit"), :nonnegative, @uint64_max),
      accounting_source: accounting,
      cleanup_grace_ms: decimal!(Map.fetch!(details, "cleanup_grace_ms"), :positive, @uint64_max)
    }
  end

  defp details!(:outcome_unknown, details) do
    require!(is_map(details))
    ref = Map.fetch!(details, "reconciliation_ref")
    require!(bounded_text?(ref, 1_024, false))

    %{
      reconciliation_ref: ref,
      cleanup_grace_ms: decimal!(Map.fetch!(details, "cleanup_grace_ms"), :positive, @uint64_max)
    }
  end

  defp failure!(source) do
    category = Map.fetch!(source, "category")
    retryable = Map.fetch!(source, "retryable")
    dimension = Map.fetch!(source, "dimension")
    observed = Map.fetch!(source, "observed")
    limit = Map.fetch!(source, "limit")
    require!(retryable == false)

    case category do
      "deadline_preflight_failed" ->
        require!(is_nil(dimension) and is_nil(observed) and is_nil(limit))
        %{category: category, retryable: false, dimension: nil, observed: nil, limit: nil}

      "context_budget_exceeded" ->
        require!(
          dimension in ~w(system_class_tokens context_tokens context_record_bytes context_record_depth context_record_cardinality)
        )

        %{
          category: category,
          retryable: false,
          dimension: dimension,
          observed: decimal!(observed, :nonnegative, @observed_max),
          limit: decimal!(limit, :positive, @uint64_max)
        }

      _ ->
        invalid!()
    end
  end

  defp cleanup!(:durable, :durable), do: {nil, ""}
  defp cleanup!(:ephemeral, :proved), do: {%{proved: true}, ""}

  defp cleanup!(:ephemeral, {:unproved, source}) when is_map(source) do
    root = Map.fetch!(source, :root)
    ownership = Map.fetch!(source, :root_ownership)
    pending = Map.fetch!(source, :pending)
    require!(ownership in [:owned, :unknown])
    require!(bounded_list?(pending, 5, &(&1 in @pending)) and pending != [])
    require!(pending == Enum.filter(@pending, &(&1 in pending)))

    require!(
      case root do
        nil ->
          ownership == :unknown and pending == [:session_subtree] and
            Map.fetch(source, :ending) == {:ok, :none}

        value when is_binary(value) ->
          bounded_text?(value, 65_536, false) and :binary.match(value, <<0>>) == :nomatch

        _ ->
          false
      end
    )

    pending_names = Enum.map(pending, &Atom.to_string/1)

    line =
      "loopex: cleanup_unproved root=#{JSON.encode!(root)} ownership=#{ownership} pending=#{Enum.join(pending_names, ",")}\n"

    {%{
       proved: false,
       root: root,
       root_ownership: Atom.to_string(ownership),
       pending: pending_names
     }, line <> cleanup_guidance(root, pending)}
  end

  defp cleanup!(_, _), do: invalid!()

  defp cleanup_guidance(nil, _pending) do
    "loopex: Loopex could not confirm that the temporary session stopped, and no root path is known. Before running ask again, make sure the previous ask process has exited; do not remove a guessed directory.\n"
  end

  defp cleanup_guidance(_root, [:root_removal]) do
    "loopex: Removal of the temporary root is unconfirmed. Before running ask again, make sure the previous ask process has exited and inspect the root named above. Remove it only if you can independently verify this session created it; otherwise leave it untouched and investigate.\n"
  end

  defp cleanup_guidance(_root, _pending) do
    "loopex: Session cleanup is unconfirmed. Before running ask again, make sure the previous ask process has exited and inspect the root named above; do not remove an unverified path.\n"
  end

  defp text_lines(object) do
    tools =
      Enum.map_join(object.tools, "", fn tool ->
        id = if is_nil(tool.tool_id), do: "null", else: JSON.encode!(tool.tool_id)
        "tool #{tool.outcome} #{id}\n"
      end)

    ending =
      if object.outcome == "no_ending",
        do: "ending no_ending #{object.details.reason}\n",
        else: "ending #{object.outcome}\n"

    tools <> ending
  end

  defp tool?(tool) when is_map(tool) do
    id = Map.get(tool, :tool_id, :missing)
    outcome = Map.get(tool, :outcome, :missing)
    (is_nil(id) or bounded_text?(id, 128, false)) and outcome in @tool_outcomes
  end

  defp tool?(_), do: false

  defp shadowed_skill?(value),
    do:
      bounded_text?(value, 1_024, false) and byte_size(value) > 5 and
        String.starts_with?(value, "user:")

  defp bounded_text?(value, max, empty?) when is_binary(value) do
    byte_size(value) <= max and (empty? or byte_size(value) > 0) and String.valid?(value)
  end

  defp bounded_text?(_, _, _), do: false

  defp bounded_list?([], _max, _predicate), do: true

  defp bounded_list?([head | tail], max, predicate) when max > 0,
    do: predicate.(head) and bounded_list?(tail, max - 1, predicate)

  defp bounded_list?(_, _, _), do: false

  defp decimal!(value, domain, maximum) do
    require!(
      is_integer(value) and value <= maximum and (domain == :nonnegative or value > 0) and
        value >= 0
    )

    Integer.to_string(value)
  end

  defp require!(true), do: :ok
  defp require!(_), do: invalid!()
  defp invalid!(), do: throw(:invalid_ask_result)
end
