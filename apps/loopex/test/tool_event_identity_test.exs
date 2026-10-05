Code.require_file("support/m1_runtime_helper.exs", __DIR__)
Code.require_file("support/agent_loop_helper.exs", __DIR__)
Code.require_file("support/configured_genesis_helper.exs", __DIR__)

defmodule Loopex.ToolEventIdentityTest do
  use ExUnit.Case, async: false

  alias Loopex.AgentLoopFixture, as: Fixture
  alias Loopex.Runtime.SessionState
  alias LoopexProtocol.ToolDefinition

  defmodule DenyQuestions do
    @moduledoc false
    @behaviour Loopex.Policy
    @impl Loopex.Policy
    def decide(%{generation: {"loopex.ask", _, _}}), do: {:deny, :interaction_unsupported}
    def decide(_request), do: {:allow, nil}
  end

  defmodule DenyAll do
    @moduledoc false
    @behaviour Loopex.Policy
    @impl Loopex.Policy
    def decide(_request), do: {:deny, :policy_denied}
  end

  test "a denied question and repeated effects retain distinct events across turns and runs" do
    fixture =
      start(
        tools: [ToolDefinition.question_definition(), Fixture.tool_definition()],
        policy: DenyQuestions,
        script: [
          %{text: "ask", calls: [call("ask", %{"question" => "encoding?"})]},
          %{text: "write one", calls: [call("write", %{"path" => "one"})]},
          %{text: "write two", calls: [call("write", %{"path" => "two"})]},
          %{text: "first done", calls: []},
          %{text: "write three", calls: [call("write", %{"path" => "three"})]},
          %{text: "second done", calls: []}
        ]
      )

    {session, attachment, {:accepted, "prompt-1"}} = Fixture.run(fixture, "first")
    assert await_finished(attachment)["outcome"] == "completed"

    assert {:accepted, "prompt-2"} =
             Loopex.command(attachment, %{
               type: :prompt,
               command_id: "prompt-2",
               content: "second"
             })

    assert await_finished(attachment)["outcome"] == "completed"

    events = Fixture.events(fixture, session)
    started = Enum.filter(events, &(&1.kind == "tool.started"))
    finished = Enum.filter(events, &(&1.kind == "tool.finished"))
    assert length(started) == 3
    assert Enum.map(finished, & &1["outcome"]) == ~w(denied completed completed completed)

    assert Enum.map(finished, & &1.event_id) == [
             "event-to_cefc2cbd4fc34f55ef0abfa5b41385",
             "event-to_e813046189958f53e4e6ddd8666fa1",
             "event-to_76a8d9301fe17c2f93bc8b4cb0505b",
             "event-to_9e80fe9ad664b8f14511b8559e88fe"
           ]

    assert Enum.map(started, & &1.event_id) == [
             "event-to_24b7074eb6602c71aa1455b8fba5f5",
             "event-to_a7c6743418824504cb71d51b9f7ec7",
             "event-to_ee71b07aadf9450a8e8dc50fd62dfc"
           ]

    assert Enum.uniq(Enum.map(started ++ finished, & &1["tool_call_id"])) == ["same"]
    assert length(Enum.uniq(Enum.map(started ++ finished, & &1.event_id))) == 7
    assert length(Enum.uniq(Enum.map(finished, &{&1["run_id"], &1["turn_id"]}))) == 4
    jobs = Loopex.AgentLoopTestExecutor.jobs(fixture.executor)
    assert length(jobs) == 3
    assert length(Enum.uniq(Enum.map(jobs, & &1.job_id))) == 3
    assert length(Enum.uniq(Enum.map(jobs, & &1.operation_id))) == 3
    assert {:ok, recovered} = recover(fixture, session)
    assert recovered.active_run_id == nil

    assert Enum.count(
             Fixture.records(fixture, session),
             &(&1.payload.kind == "executor_receipt_committed_v2")
           ) == 3
  end

  test "repeated refused calls in one run use distinct terminal transaction identities" do
    fixture =
      start(
        policy: DenyAll,
        script: [
          %{text: "one", calls: [call("write", %{"path" => "one"})]},
          %{text: "two", calls: [call("write", %{"path" => "two"})]},
          %{text: "done", calls: []}
        ]
      )

    {session, attachment, {:accepted, "prompt-1"}} = Fixture.run(fixture, "first")
    assert await_finished(attachment)["outcome"] == "completed"

    rows =
      Enum.filter(
        Fixture.records(fixture, session),
        &(&1.payload.kind == "tool_result_committed_v2")
      )

    assert length(rows) == 2
    assert Enum.map(rows, & &1.payload["tool_call_id"]) == ["same", "same"]
    events = Enum.filter(Fixture.events(fixture, session), &(&1.kind == "tool.finished"))
    assert Enum.map(events, & &1["outcome"]) == ~w(denied denied)
    assert length(Enum.uniq(Enum.map(events, & &1.event_id))) == 2
    assert Loopex.AgentLoopTestExecutor.jobs(fixture.executor) == []
    assert {:ok, _recovered} = recover(fixture, session)
  end

  test "repeated IDs survive unknown intent and receipt commits without duplicate dispatch" do
    {store, _journal} = Loopex.M1RuntimeTestStore.start_store()
    :ok = Loopex.M1RuntimeTestStore.observe_representations(store, self())

    :ok =
      Loopex.M1RuntimeTestStore.hold_next_record_before_linearization(
        store,
        "effect_intent_committed_v2",
        self()
      )

    fixture =
      start(
        store: store,
        script: [
          %{text: "one", calls: [call("write", %{"path" => "one"})]},
          %{text: "two", calls: [call("write", %{"path" => "two"})]},
          %{text: "done", calls: []}
        ]
      )

    {session, attachment, {:accepted, "prompt-1"}} = Fixture.run(fixture, "first")

    assert_receive {:record_held_before_linearization, waiter, ^store,
                    "effect_intent_committed_v2", intent},
                   1_000

    assert Loopex.AgentLoopTestExecutor.jobs(fixture.executor) == []

    :ok =
      Loopex.M1RuntimeTestStore.hold_next_record_before_linearization(
        store,
        "executor_receipt_committed_v2",
        self()
      )

    :ok =
      Loopex.M1RuntimeTestStore.inject(
        store,
        {:session_journal_commit, :after_linearization_before_result}
      )

    Loopex.M1RuntimeTestStore.release(waiter)
    assert_receive {:transaction_represented, ^store, ^intent, {:committed, _, _}}, 1_000

    assert_receive {:record_held_before_linearization, waiter, ^store,
                    "executor_receipt_committed_v2", receipt},
                   1_000

    assert length(Loopex.AgentLoopTestExecutor.jobs(fixture.executor)) == 1
    assert length(Loopex.AgentLoopTestModel.dispatched(fixture.model)) == 1

    :ok =
      Loopex.M1RuntimeTestStore.inject(
        store,
        {:session_journal_commit, :after_linearization_before_result}
      )

    Loopex.M1RuntimeTestStore.release(waiter)
    assert_receive {:transaction_represented, ^store, ^receipt, {:committed, _, _}}, 1_000
    assert await_finished(attachment)["outcome"] == "completed"
    jobs = Loopex.AgentLoopTestExecutor.jobs(fixture.executor)
    assert Enum.map(jobs, & &1.tool_call_id) == ["same", "same"]
    assert length(Enum.uniq(Enum.map(jobs, & &1.job_id))) == 2
    assert length(Enum.uniq(Enum.map(jobs, & &1.operation_id))) == 2
    events = Fixture.events(fixture, session)
    assert Enum.count(events, &(&1.kind == "tool.started")) == 2
    finished = Enum.filter(events, &(&1.kind == "tool.finished"))

    assert Enum.map(finished, & &1.event_id) == [
             "event-to_cefc2cbd4fc34f55ef0abfa5b41385",
             "event-to_e813046189958f53e4e6ddd8666fa1"
           ]

    assert length(Loopex.AgentLoopTestModel.dispatched(fixture.model)) == 3
    assert {:ok, _recovered} = recover(fixture, session)
  end

  test "two answered model questions can reuse the same raw call ID" do
    fixture =
      start(
        tools: [ToolDefinition.question_definition()],
        script: [
          %{text: "one", calls: [call("ask", %{"question" => "first?"})]},
          %{text: "two", calls: [call("ask", %{"question" => "second?"})]},
          %{text: "done", calls: []}
        ]
      )

    {:ok, session} =
      Loopex.create_session(fixture.runtime, %{},
        command_id: "create",
        genesis: Loopex.ConfiguredGenesisFixture.genesis(fixture.definitions)
      )

    {:ok, attachment} = Loopex.attach(fixture.runtime, session, after_event_sequence: 0)

    assert {:accepted, "prompt-1"} =
             Loopex.command(attachment, %{
               type: :prompt,
               command_id: "prompt-1",
               content: "ask twice"
             })

    first = await_event(attachment, "interaction.requested")
    assert first["tool_call_id"] == "same"

    assert {:accepted, "answer-1"} =
             Loopex.command(attachment, %{
               type: :interaction_answer,
               command_id: "answer-1",
               interaction_id: first["interaction_id"],
               answer: %{"text" => "first answer"}
             })

    second = await_event(attachment, "interaction.requested")
    assert second["tool_call_id"] == "same"
    refute second["interaction_id"] == first["interaction_id"]

    assert {:accepted, "answer-2"} =
             Loopex.command(attachment, %{
               type: :interaction_answer,
               command_id: "answer-2",
               interaction_id: second["interaction_id"],
               answer: %{"text" => "second answer"}
             })

    assert await_finished(attachment)["outcome"] == "completed"
    terminals = Enum.filter(Fixture.events(fixture, session), &(&1.kind == "tool.finished"))

    assert Enum.map(terminals, & &1.event_id) == [
             "event-to_cefc2cbd4fc34f55ef0abfa5b41385",
             "event-to_e813046189958f53e4e6ddd8666fa1"
           ]

    assert Enum.map(terminals, & &1["outcome"]) == ~w(completed completed)
    assert Loopex.AgentLoopTestExecutor.jobs(fixture.executor) == []
    assert {:ok, _recovered} = recover(fixture, session)
  end

  test "current intent and receipt replay reject retired kinds and old event IDs" do
    fixture =
      start(
        script: [
          %{text: "write", calls: [call("write", %{"path" => "one"})]},
          %{text: "done", calls: []}
        ]
      )

    {session, attachment, {:accepted, "prompt-1"}} = Fixture.run(fixture, "first")
    assert session == "s_test_1"
    assert await_finished(attachment)["outcome"] == "completed"
    records = Fixture.records(fixture, session)
    terminal = Enum.find(records, &(&1.payload.kind == "executor_receipt_committed_v2"))
    finished = Enum.find(Fixture.events(fixture, session), &(&1.kind == "tool.finished"))

    prefix = Enum.take_while(records, &(&1.journal_version <= terminal.journal_version))

    events =
      Enum.take_while(
        Fixture.events(fixture, session),
        &(&1.event_sequence <= finished.event_sequence)
      )

    assert {:ok, recovered} = SessionState.recover(session, prefix, events)

    assert recovered.expected_events ==
             Enum.map(
               events,
               &Map.drop(&1, [:event_sequence, :owner_epoch, :owner_incarnation_id])
             )

    for {current, retired} <- [
          {"effect_intent_committed_v2", "effect_intent_committed"},
          {"executor_receipt_committed_v2", "executor_receipt_committed"}
        ] do
      changed =
        Enum.map(prefix, fn row ->
          if row.payload.kind == current, do: put_in(row, [:payload, :kind], retired), else: row
        end)

      assert {:error, _retired_kind} = SessionState.recover(session, changed, events)
    end

    for {kind, old_id} <- [
          {"tool.started", "event-to_97dadde6e247e890a41fdd5e11fb4a"},
          {"tool.finished", "event-to_a86243fc3b5042265ee736650ac626"}
        ] do
      changed = Enum.map(events, &if(&1.kind == kind, do: %{&1 | event_id: old_id}, else: &1))
      assert {:error, _retired_identity} = SessionState.recover(session, prefix, changed)
    end
  end

  test "current non-receipt terminals reject retired kinds identities and extra fields" do
    fixture =
      start(
        policy: DenyAll,
        script: [
          %{text: "write", calls: [call("write", %{"path" => "one"})]},
          %{text: "done", calls: []}
        ]
      )

    {session, attachment, {:accepted, "prompt-1"}} = Fixture.run(fixture, "first")
    assert await_finished(attachment)["outcome"] == "completed"
    rows = Fixture.records(fixture, session)
    terminal = Enum.find(rows, &(&1.payload.kind == "tool_result_committed_v2"))
    prefix = Enum.take_while(rows, &(&1.journal_version <= terminal.journal_version))
    finished = Enum.find(Fixture.events(fixture, session), &(&1.kind == "tool.finished"))

    events =
      Enum.take_while(
        Fixture.events(fixture, session),
        &(&1.event_sequence <= finished.event_sequence)
      )

    historical =
      List.update_at(prefix, -1, &put_in(&1, [:payload, :kind], "tool_result_committed"))

    old_events =
      List.update_at(events, -1, &%{&1 | event_id: "event-to_a86243fc3b5042265ee736650ac626"})

    assert {:ok, _current} = SessionState.recover(session, prefix, events)
    assert {:error, _retired_kind} = SessionState.recover(session, historical, events)
    assert {:error, _retired_identity} = SessionState.recover(session, prefix, old_events)
    assert {:error, _retired_pair} = SessionState.recover(session, historical, old_events)

    assert {:error, _extra_field} =
             SessionState.recover(
               session,
               List.update_at(prefix, -1, &put_in(&1, [:payload, "extra"], true)),
               events
             )

    assert {:error, _future_kind} =
             SessionState.recover(
               session,
               List.update_at(
                 prefix,
                 -1,
                 &put_in(&1, [:payload, :kind], "tool_result_committed_v3")
               ),
               events
             )
  end

  defp call(name, arguments), do: %{id: "same", name: name, arguments: arguments}

  defp start(options) do
    fixture = Fixture.start(options)
    on_exit(fn -> Fixture.stop(fixture) end)
    fixture
  end

  defp recover(fixture, session),
    do:
      SessionState.recover(
        session,
        Fixture.records(fixture, session),
        Fixture.events(fixture, session)
      )

  defp await_finished(attachment), do: await_event(attachment, "run.finished")

  defp await_event(attachment, kind, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + 5000

    case Loopex.next_event(attachment) do
      {:ok, %{kind: ^kind} = event} ->
        event

      observation ->
        assert System.monotonic_time(:millisecond) < deadline, inspect(observation)
        unless match?({:ok, %{}}, observation), do: Process.sleep(10)
        await_event(attachment, kind, deadline)
    end
  end
end
