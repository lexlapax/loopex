Code.require_file("support/m1_runtime_helper.exs", __DIR__)
Code.require_file("support/agent_loop_helper.exs", __DIR__)
Code.require_file("support/configured_genesis_helper.exs", __DIR__)

defmodule Loopex.Runtime.CompactionRecordSourcesTest do
  use ExUnit.Case, async: true

  alias Loopex.AgentLoopFixture, as: Fixture
  alias Loopex.ConfiguredGenesisFixture, as: Genesis
  alias Loopex.Conversation
  alias Loopex.Runtime.{Instructions, SessionConfiguration, SessionState}
  alias Loopex.Store
  alias LoopexProtocol.{Canonical, ToolDefinition}

  test "session scope includes all settled runs and preserves original tool groups and provenance" do
    {fixture, session, attachment} =
      start([
        %{text: "working", calls: [call("write")]},
        %{text: "first done", calls: []},
        %{text: "second done", calls: []}
      ])

    {initial, _, _} = states(fixture, session)
    assert SessionState.lineage_elements(initial, :session) == []
    assert SessionState.compaction_units(initial, :session) == {:ok, []}
    assert SessionState.projected_lineage(initial, :session, 0) == {:ok, [], nil}
    assert {:ok, empty_candidate} = standalone_candidate(initial)
    {:ok, instructions} = Instructions.render(initial.configuration["instructions"])
    assert empty_candidate.request.messages == [%{"role" => "system", "content" => instructions}]
    assert empty_candidate.request.continuation == nil
    assert empty_candidate.request.deadline == 61_000

    prompt(attachment)
    finish(attachment)

    assert {:accepted, "second"} =
             Loopex.command(attachment, %{
               type: :prompt,
               command_id: "second",
               content: "continue with the exact earlier result"
             })

    finish(attachment)
    {live, replayed, rows} = states(fixture, session)
    [first, second] = replayed.run_order

    expected = SessionState.elements(replayed, first) ++ SessionState.elements(replayed, second)
    assert SessionState.lineage_elements(live, :session) == expected
    assert SessionState.lineage_elements(replayed, :session) == expected

    assert SessionState.lineage_elements(replayed, first) ==
             SessionState.elements(replayed, first)

    assert SessionState.lineage_elements(replayed, "unadmitted") == []
    assert {:ok, units} = SessionState.compaction_units(replayed, :session)
    assert SessionState.compaction_units(live, :session) == {:ok, units}
    assert Enum.flat_map(units, & &1.elements) == expected
    refute Enum.any?(units, & &1.protected?)

    assert [
             %{
               elements: [
                 %{kind: :user_message},
                 %{kind: :assistant_message},
                 %{kind: :tool_result}
               ]
             },
             %{elements: [%{kind: :assistant_message}]},
             %{elements: [%{kind: :user_message}, %{kind: :assistant_message}]}
           ] = units

    assert {:ok, choice} = Conversation.compaction_tail(units, :explicit, fn [] -> {:ok, 0} end)
    assert choice.eligible_unit_count == 3
    assert choice.retained_tail == []
    assert {:ok, expected_entries} = Conversation.lineage_entries(expected)
    assert {:ok, ^expected_entries, nil} = SessionState.projected_lineage(replayed, :session, 0)
    assert {:ok, candidate} = standalone_candidate(replayed)

    assert candidate.request.messages ==
             [hd(empty_candidate.request.messages) | Enum.map(expected_entries, &elem(&1, 1))]

    assert candidate.request.model == replayed.configuration["model"]
    assert candidate.request.sampling == SessionConfiguration.sampling(replayed.configuration)
    assert candidate.request.tools == replayed.tool_selection["definitions"]
    assert candidate.request.continuation == nil
    assert candidate.receipt["continuation_cost"] == nil

    assert candidate.receipt["context_token_budget"] ==
             replayed.configuration["context_token_budget"]

    assert candidate.receipt["record_byte_cost"] == 0

    session_blocks =
      Enum.filter(candidate.receipt["blocks"], &(&1["provenance_class"] == "session"))

    assert Enum.map(session_blocks, & &1["source_reference"]) ==
             Enum.map(expected_entries, &elem(&1, 0))

    assert length(candidate.receipt["blocks"]) ==
             1 + length(expected_entries) + length(candidate.request.tools)

    refute Map.has_key?(candidate.request, :run_id)
    refute Map.has_key?(candidate.request, :turn_id)
    refute Map.has_key?(candidate.request, :scope)
    assert Loopex.Model.validate_request(candidate.request) == :ok

    for element <- expected do
      source = Conversation.source_reference(element)
      original = replayed.conversation_record_sources[source]
      assert live.conversation_record_sources[source] == original
      row = Enum.find(rows, &(&1.journal_version == original.journal_version))
      assert_original(replayed, element, row)
    end

    # Concept: reading standalone history changes no durable session facts.
    # Technical depth: the scope contains original run IDs only. No command,
    # provider intent, maintenance record or accounting mutation is proposed.
    assert replayed.active_run_id == nil
    assert replayed.pending_compact == nil
    assert replayed.maintenance_episodes == %{}
    assert replayed.commands |> Map.keys() |> Enum.sort() == ["prompt", "second"]
  end

  test "session scope protects an unfinished latest run while retaining settled earlier history" do
    {fixture, session, attachment} =
      start([%{text: "first done", calls: []}, %{text: "held", calls: [], hold: self()}])

    prompt(attachment)
    finish(attachment)

    assert {:accepted, "second"} =
             Loopex.command(attachment, %{
               type: :prompt,
               command_id: "second",
               content: "still in progress"
             })

    assert_receive {:holding, worker}, 5_000
    {live, replayed, _} = states(fixture, session)
    assert {:ok, [earlier, current]} = SessionState.compaction_units(replayed, :session)
    refute earlier.protected?
    assert current.protected?
    assert current.run_id == replayed.active_run_id
    assert SessionState.compaction_units(live, :session) == {:ok, [earlier, current]}
    assert standalone_candidate(replayed) == {:error, :context_projection_invalid}

    send(worker, :release)
    finish(attachment)
    {_live, settled, _} = states(fixture, session)
    assert {:ok, [earlier, latest]} = SessionState.compaction_units(settled, :session)
    refute earlier.protected?
    refute latest.protected?
    assert {:ok, _candidate} = standalone_candidate(settled)
  end

  test "standalone candidates reject invented run identity steer and optional intake" do
    {fixture, session, _attachment} = start([])
    {state, _, _} = states(fixture, session)
    staging = standalone_staging(state)

    for invalid <- [
          Map.put(staging, :run_id, "invented"),
          Map.put(staging, :run_id, nil),
          Map.put(staging, :steer, %{command_id: "invented", content: "invented"}),
          Map.delete(staging, :steer)
        ] do
      assert {:error, :context_projection_invalid} =
               SessionState.reference_model_candidate(state, invalid, [], ordinary_project(), nil)
    end

    assert {:error, :context_projection_invalid} =
             SessionState.reference_model_candidate(
               state,
               staging,
               [{"optional resource", %{}}],
               ordinary_project(),
               nil
             )

    assert {:error, :context_projection_invalid} =
             SessionState.reference_model_candidate(state, staging, [], ordinary_project(), %{})

    for invalid <- [
          %{state | pending_work: %{"unfinished" => %{}}},
          %{state | open_interaction: "unfinished"},
          %{state | aborting: "unfinished"},
          %{state | follow_up: %{command_id: "unfinished"}}
        ] do
      assert standalone_candidate(invalid) == {:error, :context_projection_invalid}
    end
  end

  test "full settlement provenance includes private fields absent from canonical messages" do
    {fixture, session, attachment} = start([%{text: "answer", calls: []}])
    prompt(attachment)
    finish(attachment)
    {live, replayed, rows} = states(fixture, session)
    assert live.conversation_record_sources == replayed.conversation_record_sources
    [run] = replayed.run_order
    [input, assistant] = SessionState.elements(replayed, run)
    input_row = Enum.find(rows, &(&1.payload.kind == "prompt_admitted_v3"))
    settlement = Enum.find(rows, &(&1.payload.kind == "model_attempt_settled_v3"))
    assert_original(replayed, input, input_row)
    assert_original(replayed, assistant, settlement)

    # Concept: hashing rendered messages would miss a changed original reply.
    # Technical depth: response identity is retained private evidence, omitted
    # from conversation and public events. Alter it without changing those
    # planes; replay must derive a different complete-record digest.
    changed =
      Enum.map(rows, fn row ->
        if row.journal_version == settlement.journal_version,
          do:
            put_in(row, [:payload, "result", "reply", "provider_response_id"], "another-response"),
          else: row
      end)

    assert {:ok, other} = SessionState.recover(session, changed, Fixture.events(fixture, session))
    assert other.conversation == replayed.conversation
    source = Conversation.source_reference(assistant)

    refute other.conversation_record_sources[source].record_digest ==
             replayed.conversation_record_sources[source].record_digest

    assert map_size(replayed.conversation_record_sources[source]) == 3
    refute Map.has_key?(replayed.conversation_record_sources[source], :record)

    original_request = maintenance_candidate(replayed)
    changed_request = maintenance_candidate(other)
    assert original_request["source_digest"] == changed_request["source_digest"]

    refute original_request["covered_range"]["digest"] ==
             changed_request["covered_range"]["digest"]

    assert original_request["covered_range"]["unit_count"] == 1
    assert original_request["covered_range"]["record_count"] == 2
    assert original_request["covered_range"]["source_count"] == 2
  end

  test "queued steer and promoted follow up keep their original admission records" do
    {fixture, session, attachment} =
      start([
        %{text: "working", calls: [call("write")], hold: self()},
        %{text: "first done", calls: []},
        %{text: "follow up done", calls: []}
      ])

    prompt(attachment)
    assert_receive {:holding, worker}, 5_000
    {:ok, %{active_run_id: run}} = Loopex.session_status(fixture.runtime, session)

    assert {:accepted, "steer"} =
             Loopex.command(attachment, %{
               type: :steer,
               command_id: "steer",
               run_id: run,
               content: "retain this instruction"
             })

    assert {:accepted, "follow"} =
             Loopex.command(attachment, %{
               type: :follow_up,
               command_id: "follow",
               content: "then continue"
             })

    send(worker, :release)
    finish(attachment)
    finish(attachment)
    {live, replayed, rows} = states(fixture, session)
    assert live.conversation_record_sources == replayed.conversation_record_sources
    assert length(replayed.run_order) == 2

    for command <- ["prompt", "steer", "follow"] do
      input =
        replayed.run_order
        |> Enum.flat_map(&SessionState.elements(replayed, &1))
        |> Enum.find(&(&1.kind == :user_message and &1.command_id == command))

      row = Enum.find(rows, &(&1.payload["command_id"] == command))
      assert_original(replayed, input, row)
    end

    result = Enum.find(SessionState.elements(replayed, run), &(&1.kind == :tool_result))
    receipt = Enum.find(rows, &(&1.payload.kind == "executor_receipt_committed_v2"))
    assert_original(replayed, result, receipt)

    source = Conversation.source_reference(result)

    assert replayed.conversation_record_sources[source].record_digest ==
             replayed.tool_result_sources[source].record_digest
  end

  test "unstarted results bind the terminal that derived them" do
    {fixture, session, attachment} =
      start([%{text: "three writes", calls: [call("a"), call("b"), call("c")]}],
        outcomes: %{"a" => "outcome_unknown"}
      )

    prompt(attachment)
    finish(attachment)
    {live, replayed, rows} = states(fixture, session)
    assert live.conversation_record_sources == replayed.conversation_record_sources
    [run] = replayed.run_order
    result = Enum.find(SessionState.elements(replayed, run), &(Map.get(&1, :tool_call_id) == "b"))
    assert result.outcome == :cancelled
    terminal = Enum.find(rows, &(&1.payload.kind == "run_terminal_committed"))
    assert_original(replayed, result, terminal)

    refute Enum.any?(
             rows,
             &(&1.payload["receipt"] && &1.payload["receipt"]["tool_call_id"] == "b")
           )

    candidate = maintenance_candidate(replayed)
    assert candidate["covered_range"]["source_count"] == 5
    assert candidate["covered_range"]["record_count"] == 4

    {:ok, compact} =
      SessionState.propose(replayed, %{
        type: :compact,
        command_id: "repair-rendering",
        bounds: %{max_attempts: 4, deadline_ms: 60_000, token_budget: 32_768}
      })

    pending = commit_local(compact)

    assert {:ok, probe} =
             SessionState.preflight_standalone_context(pending, 61_000, fn -> :ok end)

    assert probe.failure == nil
    assert probe.rendering == {:error, :canonical_history_rendering_unsupported}

    assert {:ok, minimum} =
             SessionState.preflight_standalone_context(pending, 61_000, fn -> :ok end, %{
               elements: []
             })

    assert minimum.failure == nil
    assert minimum.rendering == :ok

    assert {:ok, plan} =
             SessionState.preflight_standalone_compaction(pending, 61_000, fn -> :ok end)

    assert plan.trigger == "canonical_rendering"
    assert plan.origin == "explicit"
    assert plan.targets == nil

    assert plan.last_offending_source == %{
             "kind" => "session_assistant",
             "run_id" => run,
             "turn" => 1
           }

    assert plan.eligible_unit_count == 1
    assert plan.retained_tail == []
    assert plan.tail_tokens == 0

    parent = pending.configuration

    selection = %{
      "model" => parent["model"],
      "reasoning" => "none",
      "model_capabilities" => %{parent["model_capabilities"] | "reasoning_levels" => ["none"]},
      "provider_mapping" => %{parent["provider_mapping"] | "thinking_disabled" => true}
    }

    {:ok, instructions} =
      Loopex.Runtime.MaintenanceConfiguration.capture_instructions(%{
        "version" => "summary.v1",
        "body" => "Retain the complete tool outcome"
      })

    assert {:ok, capture} =
             SessionState.propose_standalone_maintenance_episode(
               pending,
               selection,
               instructions,
               1_000,
               fn -> :ok end
             )

    assert hd(capture.records)["trigger"] == "canonical_rendering"
    assert hd(capture.records)["last_offending_source"] == plan.last_offending_source
    assert hd(capture.records)["deadline"] == 61_000
    captured = commit_local(capture)
    assert captured.active_run_id == nil

    assert captured.maintenance_episodes[captured.active_maintenance]["session_version"] ==
             captured.journal_version

    settled = settle_standalone_source(captured, String.duplicate("g", 3_000))

    assert {:ok, candidate} =
             SessionState.preflight_maintenance_checkpoint(settled, 2_001, fn -> :ok end)

    assert candidate.trigger == "canonical_rendering"
    assert candidate.before.rendering == {:error, :canonical_history_rendering_unsupported}
    assert candidate.after.rendering == :ok
    assert candidate.after.record_bytes > candidate.before.record_bytes
    assert candidate.after.tokens > candidate.before.tokens
    assert candidate.after.admission |> elem(0) == :ok
    assert candidate.consumed_range["unit_count"] == 1
    assert candidate.consumed_range["first_kept"] == nil
    assert settled.conversation == captured.conversation
    assert settled.conversation_record_sources == captured.conversation_record_sources
    assert settled.active_checkpoint == nil

    assert pending.conversation == replayed.conversation
    assert pending.conversation_record_sources == replayed.conversation_record_sources
  end

  test "canonical-rendering substitution refuses hard overflow despite advancing raw coverage" do
    configuration =
      Genesis.configuration()
      |> Map.put("context_token_budget", 1_000)
      |> Map.put("system_class_tokens", 512)
      |> put_in(["budget_origins", "context_token_budget"], "explicit")

    {fixture, session, attachment} =
      start(
        [
          %{text: "three writes", calls: [call("a"), call("b"), call("c")]}
        ],
        outcomes: %{"a" => "outcome_unknown"},
        configuration: configuration
      )

    prompt(attachment)
    finish(attachment)
    {_, retained, _} = states(fixture, session)

    {:ok, compact} =
      SessionState.propose(retained, %{
        type: :compact,
        command_id: "repair-rendering",
        bounds: %{max_attempts: 4, deadline_ms: 60_000, token_budget: 32_768}
      })

    pending = commit_local(compact)
    parent = pending.configuration

    selection = %{
      "model" => parent["model"],
      "reasoning" => "none",
      "model_capabilities" => %{parent["model_capabilities"] | "reasoning_levels" => ["none"]},
      "provider_mapping" => %{parent["provider_mapping"] | "thinking_disabled" => true}
    }

    {:ok, instructions} =
      Loopex.Runtime.MaintenanceConfiguration.capture_instructions(%{
        "version" => "summary.v1",
        "body" => "Retain the complete tool outcome"
      })

    {:ok, capture} =
      SessionState.propose_standalone_maintenance_episode(
        pending,
        selection,
        instructions,
        1_000,
        fn -> :ok end
      )

    captured = commit_local(capture)

    assert captured.maintenance_episodes[captured.active_maintenance]["trigger"] ==
             "canonical_rendering"

    settled = settle_standalone_source(captured, String.duplicate("g", 4_000))

    assert {:error, :compaction_no_progress} =
             SessionState.preflight_maintenance_checkpoint(settled, 2_001, fn -> :ok end)

    failure = %{
      "version" => 2,
      "category" => "context_preparation_failed",
      "retryable" => false,
      "measurement_scope" => "ordinary",
      "cause" => "compaction_no_progress"
    }

    assert {:ok, ended} = SessionState.propose_standalone_compact_failure(settled, failure, 2_001)
    completed = commit_local(ended)
    assert completed.active_checkpoint == nil
    assert completed.conversation == retained.conversation
    assert completed.conversation_record_sources == retained.conversation_record_sources
    assert List.last(ended.records)["result"]["usage"]["reported_tokens"] == 56

    assert Enum.map(ended.events, & &1.kind) == [
             "context.maintenance_changed",
             "context.compaction_finished"
           ]

    assert hd(ended.events)["active_maintenance"] == nil
  end

  test "question answers bind the admitted response rather than a fabricated tool result" do
    question = %{
      id: "ask",
      name: "ask",
      arguments: %{"question" => "Which value?"}
    }

    {fixture, session, attachment} =
      start(
        [%{text: "question", calls: [question]}, %{text: "answered", calls: []}],
        tools: [ToolDefinition.question_definition()]
      )

    prompt(attachment)
    requested = event(attachment, "interaction.requested")

    assert {:accepted, "answer"} =
             Loopex.command(attachment, %{
               type: :interaction_answer,
               command_id: "answer",
               interaction_id: requested["interaction_id"],
               answer: %{"text" => "the exact answer"}
             })

    finish(attachment)
    {live, replayed, rows} = states(fixture, session)
    assert live.conversation_record_sources == replayed.conversation_record_sources
    [run] = replayed.run_order
    result = Enum.find(SessionState.elements(replayed, run), &(&1.kind == :tool_result))
    response = Enum.find(rows, &(&1.payload.kind == "model_question_response_admitted_v2"))
    assert_original(replayed, result, response)
  end

  defp settle_standalone_source(captured, summary) do
    {:ok, staged} =
      SessionState.propose_selected_maintenance_request(captured, 1_500, fn -> :ok end)

    opened = commit_local(staged)
    request = opened.maintenance_episodes[opened.active_maintenance]["request"]

    raw = %{
      text: ~s({"summary":"#{summary}","carry_forward":{"files_read":[],"files_changed":[]}}),
      identity: %{provider: "scripted", model: request.model, endpoint: "in-process"},
      usage: %{input_tokens: 37, output_tokens: 19},
      tool_calls: [],
      delta_count: 0,
      streamed: false,
      provider_response_id: nil,
      canonical_request_bytes: request.canonical_request_bytes,
      staged_request_digest: request.staged_request_digest,
      completion: "natural",
      continuation: nil
    }

    {:ok, settled} =
      SessionState.propose_maintenance_attempt_settled(opened, {:reply, raw}, 2_000)

    commit_local(settled)
  end

  defp start(script, options \\ []) do
    fixture = Fixture.start(Keyword.put(options, :script, script))
    on_exit(fn -> Fixture.stop(fixture) end)

    {:ok, session} =
      Loopex.create_session(fixture.runtime, %{},
        command_id: "create",
        genesis:
          Genesis.genesis(
            fixture.definitions,
            Keyword.get_lazy(options, :configuration, fn -> Genesis.configuration() end)
          )
      )

    {:ok, attachment} = Loopex.attach(fixture.runtime, session, after_event_sequence: 0)
    {fixture, session, attachment}
  end

  defp prompt(attachment) do
    assert {:accepted, "prompt"} =
             Loopex.command(attachment, %{type: :prompt, command_id: "prompt", content: "work"})
  end

  defp finish(attachment), do: event(attachment, "run.finished")

  defp event(attachment, kind, cutoff \\ nil) do
    cutoff = cutoff || System.monotonic_time(:millisecond) + 5_000

    case Loopex.next_event(attachment) do
      {:ok, %{kind: ^kind} = row} ->
        row

      {:ok, _row} ->
        event(attachment, kind, cutoff)

      {:error, :empty} ->
        assert System.monotonic_time(:millisecond) < cutoff, "missing #{kind}"
        Process.sleep(10)
        event(attachment, kind, cutoff)

      other ->
        flunk("event read failed: #{inspect(other)}")
    end
  end

  defp states(fixture, session) do
    rows = Fixture.records(fixture, session)
    assert {:ok, replayed} = SessionState.recover(session, rows, Fixture.events(fixture, session))
    {:ok, children} = Loopex.Runtime.Supervisor.children(fixture.runtime.supervisor)
    [{_, coordinator, _, _}] = DynamicSupervisor.which_children(children.sessions)
    live = :sys.get_state(coordinator).durable
    {live, replayed, rows}
  end

  defp maintenance_candidate(state) do
    {:ok, prompt} =
      SessionState.propose(state, %{type: :prompt, command_id: "next", content: "continue"}, %{
        max_turns: 8,
        token_budget: 10_000,
        deadline_ms: 60_000,
        context_token_budget: 8_192
      })

    state = commit_local(prompt)
    parent = state.configuration

    selection = %{
      "model" => parent["model"],
      "reasoning" => "none",
      "model_capabilities" => %{parent["model_capabilities"] | "reasoning_levels" => ["none"]},
      "provider_mapping" => %{parent["provider_mapping"] | "thinking_disabled" => true}
    }

    {:ok, instructions} =
      Loopex.Runtime.MaintenanceConfiguration.capture_instructions(%{
        "version" => "summary.v1",
        "body" => "Retain facts"
      })

    {:ok, admission} =
      SessionState.propose_maintenance_episode(
        state,
        state.active_run_id,
        selection,
        instructions,
        1_000
      )

    state = commit_local(admission)
    {:ok, candidate} = SessionState.preflight_maintenance_request(state, 1, 1_001, fn -> :ok end)
    candidate
  end

  defp standalone_candidate(state),
    do:
      SessionState.reference_model_candidate(
        state,
        standalone_staging(state),
        [],
        ordinary_project(),
        nil
      )

  defp standalone_staging(state),
    do: %{
      scope: :session,
      elements: SessionState.lineage_elements(state, :session),
      steer: nil,
      deadline: 61_000,
      excerpt_allowance: 0
    }

  defp ordinary_project,
    do: %{
      "class" => "project_resource",
      "receipt_revision" => 2,
      "disposition" => "not_evaluated_required_failure",
      "detail" => nil
    }

  defp commit_local(proposal) do
    state = proposal.next

    receipt = %{
      journal_versions: %{
        first: state.journal_version + 1,
        last: state.journal_version + length(proposal.records)
      },
      event_sequences:
        if(proposal.events == [],
          do: nil,
          else: %{
            first: state.event_sequence + 1,
            last: state.event_sequence + length(proposal.events)
          }
        )
    }

    {:ok, committed} = SessionState.commit_proposal(proposal, receipt)
    committed
  end

  defp assert_original(state, element, row) do
    assert row
    {:ok, normalized, bytes} = Store.normalize_and_measure_item(:record, row.payload)
    actual = state.conversation_record_sources[Conversation.source_reference(element)]
    assert actual.record_digest == Canonical.digest(normalized)
    assert actual.record_byte_cost == bytes
    assert actual.journal_version == row.journal_version
  end

  defp call(id), do: %{id: id, name: "write", arguments: %{"path" => id}}
end
