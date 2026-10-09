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
  the operator's decoded configuration, and optionally of the runner context
  for pinned values), `plan` (a function of the runner
  context returning conversations of `Conversation` steps) and `joins` (a
  function of the committed rows, the dispatch outcome and the workspace
  returning `{:ok, nil}`, `{:missing, reason}` or `{:failed, reason}`).
  Prompts are literal and pinned here, so the case's specification digest
  covers them through the manifest entry's driver name and this module's
  bytes, which the candidate pins.
  """

  @dated "anthropic:claude-haiku-4-5-20251001"
  @fable "anthropic:claude-fable-5-1"
  @thinking_cells [
    {@dated, "low"},
    {@dated, "medium"},
    {@dated, "high"},
    {@fable, "default"},
    {@fable, "low"},
    {@fable, "medium"},
    {@fable, "high"}
  ]
  @rounds_facts %{"a.txt" => "cedar", "b.txt" => "seven", "c.txt" => "amber"}
  @rounds_files Map.new(@rounds_facts, fn {path, word} -> {path, word <> "\n"} end)
  @rounds_prompt "Read a.txt, then b.txt, then c.txt, one read tool call at a time and in that order. Then reply with the three words you read, in order."
  @readme "M7 scenario workspace.\n"
  @sentinel "AMBER-SENTINEL"
  @oversized_sentinel "M7-OVERSIZED-SENTINEL-7F3A"
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

  # V6.5: a pinned large prompt becomes old history in a small context; the
  # summary source must be excerpted, the flag inherited by a later
  # checkpoint, and the complete original retained in host history. The
  # sentinel sits in the middle, outside the excerpts, and is never asked for.
  def get("m7.oversized-source") do
    %{
      seed: %{"README.md" => @readme},
      allowed: [],
      profile: fn profile ->
        profile
        |> put_in(["session", "context_token_budget"], 6_000)
        |> put_in(["session", "system_class_tokens"], 2_000)
        |> put_in(["session", "max_tokens"], 1_024)
        |> Map.put("maintenance", %{"model" => profile["session"]["model"]})
      end,
      plan: fn _context ->
        {:ok,
         [
           %{
             resume: false,
             steps:
               Enum.flat_map(
                 [oversized_prompt(), "Reply with the word ready.", "/compact"],
                 &[{:line, &1}, {:line, "/wait"}]
               ) ++
                 [
                   {:line, "Reply with the word again."},
                   {:line, "/wait"},
                   {:line, "/compact"},
                   {:line, "/wait"},
                   {:line, "/status"},
                   {:line, "/quit"}
                 ]
           }
         ]}
      end,
      joins: fn rows, _outcome, _workspace ->
        checkpoints = all(rows, "standalone_compaction_checkpoint_committed_v1")
        requests = all(rows, "maintenance_request_committed_v1")
        original = oversized_prompt()

        excerpted =
          Enum.filter(requests, & &1.payload["source_excerpted"])

        cond do
          length(checkpoints) < 2 ->
            {:missing, :two_checkpoints}

          not Enum.any?(
            rows,
            &(&1.payload.kind == "prompt_admitted_v3" and
                  &1.payload["content"] == original)
          ) ->
            {:failed, :original_not_retained}

          excerpted == [] ->
            {:missing, :excerpted_source}

          Enum.any?(
            excerpted,
            &(:binary.match(&1.payload["request"]["canonical_request_bytes"], @oversized_sentinel) !=
                  :nomatch)
          ) ->
            {:failed, :sentinel_inside_excerpt}

          not Enum.all?(checkpoints, &get_in(&1.payload, ["summary", "source_excerpted"])) ->
            {:failed, :omission_flag_not_inherited}

          true ->
            {:ok, nil}
        end
      end
    }
  end

  # V6.7: an always-on thinking conversation model is summarized by a distinct
  # thinking-off summarizer; the conversation continues on its own model and
  # the summary's usage is charged once, to its maintenance attempt. The
  # adapter registers Haiku at `none` as the only thinking-off summarizer and
  # Fable as the always-on model, so both share the Anthropic route today.
  def get("m7.cross-provider-maintenance") do
    %{
      seed: %{"README.md" => @readme},
      allowed: [],
      profile: fn profile, context ->
        a = get_in(context, [:pins, "thinking_model"]) || @fable
        b = get_in(context, [:pins, "summarizer"]) || @dated

        profile
        |> put_in(["session", "model"], a)
        |> put_in(["session", "reasoning"], "medium")
        |> Map.put("maintenance", %{"model" => b})
      end,
      plan: fn _context ->
        {:ok,
         [
           conversation([
             "Remember this release fact exactly: release_prefix=amber, batch_size=3.",
             "Reply with the word ready.",
             "/compact",
             "Without any tool, state the release fact you were given."
           ])
         ]}
      end,
      joins: fn rows, _outcome, _workspace ->
        genesis = find(rows, "session_genesis_v3")
        conversation = genesis && genesis.payload["initial_configuration"]["model"]
        [request | _] = all(rows, "maintenance_request_committed_v1") ++ [nil]
        summarizer = request && get_in(request.payload, ["request", "model"])
        settled = all(rows, "maintenance_attempt_settled_v3")
        checkpoint = find(rows, "standalone_compaction_checkpoint_committed_v1")
        later = checkpoint && runs_after(rows, checkpoint.journal_version)

        cond do
          is_nil(checkpoint) -> {:missing, :checkpoint}
          is_nil(summarizer) -> {:missing, :maintenance_request}
          summarizer == conversation -> {:failed, :summarizer_not_distinct}
          length(settled) != 1 -> {:failed, :maintenance_usage_not_once}
          later == [] -> {:missing, :continued_run}
          true -> {:ok, nil}
        end
      end
    }
  end

  # V7.3: each continuation-required thinking cell runs the fixed three-file
  # tool fixture as one subcase of one session, then the session reopens.
  def get("m7.thinking-rounds") do
    %{
      seed: @rounds_files,
      allowed: [],
      profile: fn profile ->
        profile
        |> put_in(["session", "model"], @dated)
        |> put_in(["session", "max_tokens"], 8_192)
        |> put_in(["session", "tools"], "read-only")
        |> Map.put("maintenance", %{"model" => @dated})
      end,
      plan: fn _context ->
        # Each later cell first checkpoints the earlier cells' native history,
        # which a thinking change may otherwise refuse as compaction_required.
        subcases =
          @thinking_cells
          |> Enum.with_index()
          |> Enum.flat_map(fn {{model, reasoning}, index} ->
            compact = if index == 0, do: [], else: [{:line, "/compact"}, {:line, "/wait"}]

            compact ++
              [
                {:line, ~s(/configure {"model":"#{model}","reasoning":"#{reasoning}"})},
                {:line, @rounds_prompt},
                {:line, "/wait"}
              ]
          end)

        {:ok,
         [
           %{resume: false, steps: subcases ++ [{:line, "/quit"}]},
           %{resume: true, steps: [{:line, "/status"}, {:line, "/quit"}]}
         ]}
      end,
      joins: fn rows, outcome, _workspace -> thinking_rounds(rows, outcome) end
    }
  end

  def get(_case_id), do: nil

  @doc false
  def thinking_cells, do: @thinking_cells

  # Per thinking run: at least two continuation requests after committed tool
  # results, each replaying a retained thinking literal, and a final reply that
  # names every fixture fact.
  defp thinking_rounds(rows, outcome) do
    runs =
      rows
      |> Enum.filter(&(&1.payload.kind == "model_request_committed_v2"))
      |> Enum.group_by(& &1.payload["run_id"])

    replies =
      for row <- rows,
          row.payload.kind == "model_attempt_settled_v3",
          continuation = get_in(row.payload, ["result", "reply", "continuation"]),
          is_map(continuation),
          into: %{},
          do: {row.payload["operation_id"], continuation["content"]}

    counted =
      for {run, requests} <- runs,
          continuations = Enum.count(requests, &replays_thinking?(&1, replies)),
          do: {run, continuations}

    finals =
      for row <- rows,
          row.payload.kind == "model_attempt_settled_v3",
          text = get_in(row.payload, ["result", "reply", "text"]),
          is_binary(text),
          Enum.all?(Map.values(@rounds_facts), &String.contains?(text, &1)),
          do: row.payload["run_id"]

    cond do
      length(counted) < length(@thinking_cells) -> {:missing, :thinking_subcases}
      Enum.any?(counted, fn {_run, n} -> n < 2 end) -> {:missing, :continuation_rounds}
      Enum.any?(counted, fn {run, _} -> run not in finals end) -> {:failed, :fixture_facts}
      outcome.conversations < 2 -> {:missing, :settled_reopen}
      true -> {:ok, nil}
    end
  end

  # Concept: a counted continuation request replays a retained thinking
  # literal, and every replayed capsule equals the reply it names.
  # Technical depth: the committed canonical request bytes carry each entry's
  # source operation and capsule; the source reply's committed continuation
  # content must match it exactly once expanded to plain maps.
  defp replays_thinking?(row, replies) do
    with bytes when is_binary(bytes) <-
           get_in(row.payload, ["request", "canonical_request_bytes"]),
         request when is_list(request) <- :erlang.binary_to_term(bytes, [:safe]),
         %{"entries" => [_ | _] = entries} <- plain(Keyword.get(request, :continuation)) do
      thinking? =
        Enum.any?(entries, fn entry ->
          Enum.any?(entry["capsule"]["content"], fn block ->
            block["kind"] == "literal" and
              block["value"]["type"] in ["thinking", "redacted_thinking"]
          end)
        end)

      thinking? and
        Enum.all?(
          entries,
          &(Map.get(replies, &1["source"]["operation_id"]) == &1["capsule"]["content"])
        )
    else
      _ -> false
    end
  rescue
    _ -> false
  end

  defp plain({:loopex_map, pairs}), do: Map.new(pairs, fn {key, value} -> {key, plain(value)} end)
  defp plain(list) when is_list(list), do: Enum.map(list, &plain/1)
  defp plain(value), do: value

  defp runs_after(rows, version),
    do:
      for(
        row <- rows,
        row.journal_version > version,
        row.payload.kind == "run_terminal_committed",
        row.payload["outcome"] == "completed",
        do: row
      )

  # Pinned: 160 backslash-dense ledger lines with the sentinel in the middle.
  # The summary request embeds its source as escaped JSON text, so backslashes
  # double there while the same prompt still fits an ordinary run.
  @doc false
  def oversized_prompt do
    lines =
      for n <- 1..160 do
        if n == 80,
          do: ~s(line 80: "#{@oversized_sentinel}"),
          else: "line #{n}: " <> String.duplicate("\\\\", 24)
      end

    "Read this release ledger and reply only with the word noted. " <> Enum.join(lines, " | ")
  end

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
