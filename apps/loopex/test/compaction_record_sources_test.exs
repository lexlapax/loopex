Code.require_file("support/m1_runtime_helper.exs", __DIR__)
Code.require_file("support/agent_loop_helper.exs", __DIR__)
Code.require_file("support/configured_genesis_helper.exs", __DIR__)

defmodule Loopex.Runtime.CompactionRecordSourcesTest do
  use ExUnit.Case, async: true

  alias Loopex.AgentLoopFixture, as: Fixture
  alias Loopex.ConfiguredGenesisFixture, as: Genesis
  alias Loopex.Conversation
  alias Loopex.Runtime.SessionState
  alias Loopex.Store
  alias LoopexProtocol.{Canonical, ToolDefinition}

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
      start([%{text: "two writes", calls: [call("a"), call("b")]}],
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

  defp start(script, options \\ []) do
    fixture = Fixture.start(Keyword.put(options, :script, script))
    on_exit(fn -> Fixture.stop(fixture) end)

    {:ok, session} =
      Loopex.create_session(fixture.runtime, %{},
        command_id: "create",
        genesis: Genesis.genesis(fixture.definitions)
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
