defmodule Mix.Tasks.Loopex.M7Evidence.Scenarios do
  @moduledoc """
  ## Concept

  The non-coding M7 cases that run as ordinary `loopex chat` conversations
  under the operator's own policy: each fixes its seed workspace, the
  configuration change it exercises, its conversations and the committed
  facts that decide it. Model prose never decides a case.

  ## Technical depth

  `get/1` returns `nil` or a closed map: `seed` (relative path to bytes),
  `allowed` (paths the case may create or change), `profile` (a function of
  the operator's decoded configuration), `plan` (a function of the runner
  context returning conversations of `Conversation` steps) and `joins` (a
  function of the committed rows, the dispatch outcome and the workspace
  returning `{:ok, nil}`, `{:missing, reason}` or `{:failed, reason}`).
  Prompts are literal and pinned here, so the case's specification digest
  covers them through the manifest entry's driver name and this module's
  bytes, which the candidate pins.
  """

  @dated "anthropic:claude-haiku-4-5-20251001"
  @readme "M7 scenario workspace.\n"
  @sentinel "AMBER-SENTINEL"
  @instruction "Project instruction: end every answer with the word AMBER-SENTINEL.\n"
  @instructed_prompt "Use the read tool on README.md and report its first line."

  @doc false
  def get("m7.baseline.durable") do
    %{
      seed: %{"README.md" => @readme},
      allowed: [],
      profile: fn profile ->
        profile
        |> put_in(["session", "model"], @dated)
        |> update_in(["session"], &Map.delete(&1, "reasoning"))
      end,
      plan: fn _context ->
        {:ok,
         [
           conversation([
             "Use the read tool on README.md and report its first line. No other tool is needed."
           ])
         ]}
      end,
      joins: fn rows, outcome, _workspace ->
        genesis = find(rows, "session_genesis_v3")
        configuration = genesis && genesis.payload["initial_configuration"]

        cond do
          is_nil(configuration) -> {:missing, :session_genesis}
          configuration["model"] != @dated -> {:failed, :model_not_dated_literal}
          configuration["reasoning"] != "default" -> {:failed, :reasoning_not_default}
          completed_receipts(rows) == [] -> {:missing, :tool_round}
          outcome.exit != 0 -> {:failed, :conversation_failed}
          true -> {:ok, nil}
        end
      end
    }
  end

  def get("m7.policy-denial") do
    %{
      seed: %{"README.md" => @readme},
      allowed: [],
      profile: &Map.put(&1, "policy", "shell-allowlist"),
      plan: fn _context ->
        {:ok,
         [
           conversation([
             "Use the bash tool with argv [\"rm\", \"README.md\"] to delete README.md. " <>
               "Report the tool's result; do not try another way."
           ])
         ]}
      end,
      joins: fn rows, _outcome, workspace ->
        cond do
          tool_results(rows, "denied") == [] ->
            {:missing, :denied_call}

          find(rows, "effect_intent_committed_v2") ->
            {:failed, :effect_intent_committed}

          File.read(Path.join(workspace, "README.md")) != {:ok, @readme} ->
            {:failed, :workspace_changed}

          true ->
            {:ok, nil}
        end
      end
    }
  end

  def get("m7.pipe-answer") do
    %{
      seed: %{"README.md" => @readme},
      allowed: [],
      profile: & &1,
      plan: fn _context ->
        {:ok,
         [
           %{
             resume: false,
             steps: [
               {:line, ask_prompt("answer")},
               {:answer, "yes"},
               {:line, "/wait"},
               {:line, "/quit"}
             ]
           },
           # The decline subcase reopens the session so its question is the
           # first pending interaction the reopened conversation reads.
           %{
             resume: true,
             steps: [
               {:line, ask_prompt("decline")},
               :decline,
               {:line, "/wait"},
               {:line, "/status"},
               {:line, "/quit"}
             ]
           }
         ]}
      end,
      joins: fn rows, outcome, _workspace ->
        requested = all(rows, "model_question_requested_v1")
        responses = all(rows, "model_question_response_admitted_v2")
        dispositions = Enum.map(responses, & &1.payload["disposition"])
        ids = MapSet.new(requested, & &1.payload["interaction_id"])

        cond do
          length(requested) < 2 ->
            {:missing, :two_questions}

          length(responses) < 2 ->
            {:missing, :answer_and_decline}

          not Enum.all?(responses, &MapSet.member?(ids, &1.payload["interaction_id"])) ->
            {:failed, :unknown_interaction}

          Enum.sort(dispositions) != ["answered", "declined"] ->
            {:failed, {:dispositions, dispositions}}

          not String.contains?(outcome.closing, ~s("cleanup":"confirmed")) ->
            {:failed, :cleanup_unconfirmed}

          true ->
            {:ok, nil}
        end
      end
    }
  end

  def get("m7.trace." <> variant) when variant in ["flag", "file"] do
    %{
      seed: %{"README.md" => @readme},
      allowed: [],
      profile: fn profile ->
        if variant == "file", do: Map.put(profile, "trace", %{"enabled" => true}), else: profile
      end,
      plan: fn _context ->
        extra = if variant == "flag", do: ["--trace"], else: []

        {:ok,
         [
           %{
             resume: false,
             extra: extra,
             steps: [
               {:line, "Use the read tool on README.md and report its first line."},
               {:line, "/wait"},
               {:line, "/status"},
               {:line, "/quit"}
             ]
           }
         ]}
      end,
      joins: fn _rows, outcome, _workspace ->
        status = last_control(outcome.output, "status")
        origin = if variant == "flag", do: "flag", else: "file#/trace/enabled"

        cond do
          is_nil(status) ->
            {:missing, :status}

          get_in(status, ["trace", "enabled"]) != true ->
            {:failed, :trace_disabled}

          not String.contains?(outcome.diagnostics, ~s("setting":"/trace/enabled")) ->
            {:missing, :settings_report}

          not String.contains?(outcome.diagnostics, origin) ->
            {:failed, :trace_origin}

          not String.contains?(outcome.closing, ~s("cleanup":"confirmed")) ->
            {:failed, :trace_cleanup_unconfirmed}

          true ->
            {:ok, nil}
        end
      end
    }
  end

  def get("m7.baseline.ask") do
    %{
      seed: %{"README.md" => @readme},
      allowed: [],
      profile: & &1,
      ask: fn workspace ->
        ["ask", "--tools", "read-only", "--policy", "allow-all", "--cwd", workspace] ++
          ["--output", "json", "Read README.md and report its first line."]
      end,
      plan: fn _context -> {:ok, []} end,
      joins: fn _rows, outcome, _workspace ->
        case one_json(outcome.output) do
          %{"outcome" => "completed"} -> {:ok, nil}
          nil -> {:failed, :result_unavailable}
          _ -> {:failed, :ask_not_completed}
        end
      end
    }
  end

  def get("m7.trace.json") do
    %{
      seed: %{"README.md" => @readme},
      allowed: [],
      profile: & &1,
      ask: fn workspace ->
        ["ask", "--policy", "allow-all", "--cwd", workspace, "--output", "json", "--trace"] ++
          ["--trace-level", "calls", "Read README.md and report its first line."]
      end,
      plan: fn _context -> {:ok, []} end,
      joins: fn _rows, outcome, _workspace ->
        case one_json(outcome.output) do
          %{"outcome" => "completed"} -> {:ok, nil}
          nil -> {:failed, :stdout_not_one_result}
          _ -> {:failed, :ask_not_completed}
        end
      end
    }
  end

  def get("m7.instructions." <> variant) when variant in ["admitted", "declined", "changed"] do
    %{
      seed: %{"README.md" => @readme},
      allowed: [],
      profile: & &1,
      plan: fn context ->
        root = Path.dirname(context.workspace)
        file = Path.join(root, "project-instructions.md")

        case variant do
          "declined" ->
            {:ok, [conversation([@instructed_prompt])]}

          "admitted" ->
            File.write!(file, @instruction)
            {:ok, [Map.put(conversation([@instructed_prompt]), :extra, append(file))]}

          "changed" ->
            changed = Path.join(root, "project-instructions-changed.md")
            File.write!(file, @instruction)
            File.write!(changed, @instruction <> "Also name the file you read.\n")

            {:ok,
             [
               Map.put(conversation([@instructed_prompt]), :extra, append(file)),
               Map.merge(conversation([@instructed_prompt]), %{
                 extra: append(changed),
                 fresh: true
               })
             ]}
        end
      end,
      joins: fn rows, outcome, workspace ->
        appendix = appendix(rows)
        sentinel = String.contains?(outcome.output, @sentinel)

        cond do
          is_nil(appendix) ->
            {:missing, :session_genesis}

          variant == "declined" and String.contains?(appendix, @sentinel) ->
            {:failed, :declined_resource_admitted}

          variant == "declined" ->
            if sentinel, do: {:failed, :declined_resource_followed}, else: {:ok, nil}

          not String.contains?(appendix, @sentinel) ->
            {:failed, :resource_not_admitted}

          not sentinel ->
            {:missing, :instruction_not_followed}

          variant == "changed" ->
            changed_receipt(rows, outcome, workspace)

          true ->
            {:ok, nil}
        end
      end
    }
  end

  def get("m7.provider-switch") do
    %{
      seed: %{"README.md" => @readme},
      allowed: [],
      profile: fn profile -> profile end,
      plan: fn context ->
        case get_in(context, [:pins, "provider_b"]) do
          %{"model" => b} ->
            a = get_in(context, [:pins, "provider_a"]) || "anthropic:claude-haiku-4-5-20251001"

            {:ok,
             [
               %{
                 resume: false,
                 steps: [
                   {:line, "Use the read tool on README.md and remember its first line."},
                   {:line, "/wait"},
                   {:line, ~s(/configure {"model":"#{b}"})},
                   {:line, "Without reading again, repeat the first line you read earlier."},
                   {:line, "/wait"},
                   {:line, "/quit"}
                 ]
               },
               %{
                 resume: true,
                 steps: [
                   {:line, ~s(/configure {"model":"#{a}"})},
                   {:line, "Without reading again, repeat the first line you read earlier."},
                   {:line, "/wait"},
                   {:line, "/status"},
                   {:line, "/quit"}
                 ]
               }
             ]}

          _ ->
            {:error, :provider_pins_required}
        end
      end,
      joins: fn rows, outcome, _workspace ->
        models =
          for row <- rows,
              row.payload.kind == "session_configuration_admitted_v2",
              do: get_in(row.payload, ["configuration", "model"])

        cond do
          completed_receipts(rows) == [] -> {:missing, :tool_round}
          length(models) < 2 -> {:missing, :provider_changes}
          outcome.conversations < 2 -> {:missing, :reopen}
          Enum.uniq(models) |> length() < 2 -> {:failed, :provider_not_switched}
          true -> {:ok, nil}
        end
      end
    }
  end

  def get(_case_id), do: nil

  defp append(file), do: ["--append-system-prompt-file", file]

  defp appendix(rows) do
    case find(rows, "session_genesis_v3") do
      nil ->
        nil

      genesis ->
        get_in(genesis.payload, ["initial_configuration", "instructions", "appendix"]) || ""
    end
  end

  # The changed resource runs as a fresh session; its admitted receipt differs.
  defp changed_receipt(rows, outcome, workspace) do
    state = Path.join(Path.dirname(workspace), "state")

    with [_, second] <- outcome.sessions,
         {:ok, later} <- Mix.Tasks.Loopex.M7Evidence.CaseRunner.committed(state, second),
         first =
           get_in(find(rows, "session_genesis_v3").payload, [
             "initial_configuration",
             "instructions",
             "digest"
           ]),
         %{} = genesis <- find(later, "session_genesis_v3"),
         changed = get_in(genesis.payload, ["initial_configuration", "instructions", "digest"]),
         true <- changed != first do
      {:ok, nil}
    else
      false -> {:failed, :receipt_unchanged}
      _ -> {:missing, :changed_session}
    end
  end

  # The ask result stream holds exactly one JSON object; diagnostics go to
  # standard error.
  defp one_json(output) do
    with [line, ""] <- String.split(output, "\n"),
         {:ok, %{} = result} <- JSON.decode(line) do
      result
    else
      _ -> nil
    end
  end

  defp ask_prompt(subcase),
    do:
      "Subcase #{subcase}: call the ask tool with question \"Continue the #{subcase} subcase?\" " <>
        "and choices [\"yes\", \"no\"], then report the outcome. Do not use any other tool."

  defp conversation(prompts) do
    steps = Enum.flat_map(prompts, &[{:line, &1}, {:line, "/wait"}])
    %{resume: false, steps: steps ++ [{:line, "/status"}, {:line, "/quit"}]}
  end

  defp tool_results(rows, outcome),
    do:
      for(
        row <- rows,
        row.payload.kind == "tool_result_committed_v2",
        row.payload["outcome"] == outcome,
        do: row
      )

  defp completed_receipts(rows),
    do:
      for(
        row <- rows,
        row.payload.kind == "executor_receipt_committed_v2",
        row.payload["receipt"]["outcome"] == "completed",
        do: row
      )

  defp find(rows, kind), do: Enum.find(rows, &(&1.payload.kind == kind))
  defp all(rows, kind), do: Enum.filter(rows, &(&1.payload.kind == kind))

  defp last_control(output, event) do
    output
    |> String.split("\n")
    |> Enum.flat_map(fn
      "@loopex " <> json ->
        case JSON.decode(json) do
          {:ok, %{"event" => ^event} = record} -> [record]
          _ -> []
        end

      _ ->
        []
    end)
    |> List.last()
  end
end
