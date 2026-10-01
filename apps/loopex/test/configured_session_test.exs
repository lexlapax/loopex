Code.require_file("support/m1_runtime_helper.exs", __DIR__)
Code.require_file("support/agent_loop_helper.exs", __DIR__)
Code.require_file("support/configured_genesis_helper.exs", __DIR__)

defmodule Loopex.ConfiguredSessionDeferringPolicy do
  @moduledoc false
  @behaviour Loopex.Policy
  @impl Loopex.Policy
  def decide(_request) do
    {:defer,
     %{
       kind: :choice,
       prompt: "Allow this write?",
       choices: [%{id: "allow", label: "Allow"}],
       expires_in_ms: 700
     }}
  end
end

defmodule Loopex.ConfiguredQuestionCountingPolicy do
  @moduledoc false
  @behaviour Loopex.Policy
  @impl Loopex.Policy
  def decide(request) do
    send(
      Process.whereis(:m7_question_policy_observer),
      {:question_policy_call, request.tool_call_id}
    )

    {:allow, nil}
  end
end

defmodule Loopex.ConfiguredSessionTest do
  use ExUnit.Case, async: false

  import Loopex.ConfiguredGenesisFixture,
    only: [configuration: 0, configuration: 1, genesis: 1, genesis: 2]

  alias Loopex.AgentLoopFixture, as: Fixture
  alias Loopex.AgentLoopTestModel
  alias Loopex.Runtime
  alias Loopex.Runtime.ContextAdmission
  alias Loopex.Runtime.Instructions
  alias Loopex.Runtime.SessionConfiguration
  alias Loopex.Runtime.SessionState
  alias LoopexProtocol.ToolDefinition
  alias LoopexProtocol.Canonical

  test "the admitted question generation never dispatches an executor effect" do
    for {policy, reason} <- [
          {Loopex.ConfiguredSessionDeferringPolicy, "policy_unavailable"}
        ] do
      fixture =
        start(
          tools: [ToolDefinition.question_definition()],
          policy: policy,
          policy_identity: %{"id" => "loopex.test.question-policy", "revision" => "1"},
          script: [
            %{
              text: "I have a question",
              calls: [%{id: "ask-1", name: "ask", arguments: %{"question" => "Which encoding?"}}]
            },
            %{text: "done", calls: []}
          ]
        )

      assert {:ok, session} =
               Runtime.create_session_with_genesis(
                 fixture.runtime,
                 "create-question",
                 %{},
                 genesis(fixture.definitions)
               )

      assert {:ok, attachment} = Loopex.attach(fixture.runtime, session, after_event_sequence: 0)

      assert {:accepted, "prompt"} =
               Loopex.command(attachment, %{
                 type: :prompt,
                 command_id: "prompt",
                 content: "implement"
               })

      events = finish(attachment)
      terminal = Enum.find(events, &(&1.kind == "tool.finished"))
      assert terminal["outcome"] == "denied"
      assert terminal["reason"] == reason
      assert Enum.find(events, &(&1.kind == "run.finished"))["outcome"] == "completed"
      refute Enum.any?(events, &(&1.kind == "interaction.requested"))
      assert Agent.get(fixture.executor, & &1.jobs) == []

      refute Enum.any?(
               Fixture.records(fixture, session),
               &String.starts_with?(&1.payload.kind, "effect_")
             )
    end
  end

  test "model questions settle exact text, choice and decline in one transaction" do
    Process.register(self(), :m7_question_policy_observer)
    text = String.duplicate("é", 4_096)

    for {arguments, answer, content, disposition} <- [
          {%{"question" => "Explain"}, %{"text" => text}, text, "answered"},
          {%{"question" => "Choose", "choices" => ["empty", "literal_null"]},
           %{"choice_id" => "choice-2"}, "literal_null", "answered"},
          {%{"question" => "Explain"}, %{"disposition" => "declined"}, "question_declined",
           "declined"}
        ] do
      fixture =
        start(
          tools: [ToolDefinition.question_definition()],
          policy: Loopex.ConfiguredQuestionCountingPolicy,
          script: [
            %{text: "question", calls: [%{id: "ask-1", name: "ask", arguments: arguments}]},
            %{text: "done", calls: []}
          ]
        )

      assert {:ok, session} =
               Runtime.create_session_with_genesis(
                 fixture.runtime,
                 "create",
                 %{},
                 genesis(fixture.definitions)
               )

      assert {:ok, attachment} = Loopex.attach(fixture.runtime, session, after_event_sequence: 0)

      assert {:accepted, "prompt"} =
               Loopex.command(attachment, %{
                 type: :prompt,
                 command_id: "prompt",
                 content: "implement"
               })

      question = await_question(attachment)
      assert_received {:question_policy_call, _}
      assert question["producer"] == "model_tool"

      assert question["interaction_kind"] ==
               if(Map.has_key?(arguments, "choices"), do: "choice", else: "text")

      assert length(AgentLoopTestModel.dispatched(fixture.model)) == 1

      assert {:ok, pending} =
               SessionState.recover(
                 session,
                 Fixture.records(fixture, session),
                 Fixture.events(fixture, session)
               )

      assert pending.open_interaction == question["interaction_id"]

      assert SessionState.propose_interaction_resolution(
               pending,
               pending.open_interaction,
               "expired",
               "legacy-bypass"
             ) == {:error, :invalid_interaction_transition}

      pending_interaction = pending.interactions[question["interaction_id"]]

      if pending_interaction.request.kind == :choice do
        assert SessionState.propose_interaction_answer(
                 pending,
                 pending.open_interaction,
                 "legacy-bypass",
                 "choice-1"
               ) == {:error, :invalid_interaction_transition}
      end

      assert pending_interaction.expires_at ==
               min(
                 pending_interaction.created_at + 600_000,
                 pending.deadlines[pending_interaction.run_id]
               )

      assert SessionState.propose_model_question_expiry(
               pending,
               question["interaction_id"],
               pending_interaction.expires_at - 1
             ) == {:error, :invalid_model_question_transition}

      pending_records = Fixture.records(fixture, session)

      for {field, changed} <- [
            {"argument_digest", String.duplicate("0", 64)},
            {"interaction_id", "forged"},
            {"tool_call_id", "forged-call"},
            {"turn", 999},
            {"expires_at", pending_interaction.expires_at + 1},
            {"interaction_request", %{}},
            {"producer", "policy_defer"}
          ] do
        altered =
          Enum.map(pending_records, fn row ->
            if row.payload.kind == "model_question_requested_v1",
              do: %{row | payload: Map.put(row.payload, field, changed)},
              else: row
          end)

        assert SessionState.recover(session, altered, Fixture.events(fixture, session)) ==
                 {:error, :invalid_model_question_transition}
      end

      command = %{
        type: :interaction_answer,
        command_id: "answer",
        interaction_id: question["interaction_id"],
        answer: answer
      }

      assert {:ok, late} =
               SessionState.propose(pending, %{command | command_id: "late"}, %{
                 admitted_at: pending_interaction.expires_at
               })

      assert late.reply == {:error, :interaction_resolved}
      assert late.next.open_interaction == pending.open_interaction

      assert {:ok, expired} =
               SessionState.propose_model_question_expiry(
                 pending,
                 pending.open_interaction,
                 pending_interaction.expires_at
               )

      assert length(expired.records) == 1
      assert is_nil(expired.next.open_interaction)
      assert expired.next.interactions[pending.open_interaction].status == "expired"

      assert {:error, :invalid_command} =
               Loopex.command(
                 attachment,
                 %{
                   command
                   | command_id: "oversized",
                     answer: %{"text" => String.duplicate("x", 8_193)}
                 }
               )

      wrong_answer =
        if Map.has_key?(arguments, "choices"),
          do: %{"text" => "wrong kind"},
          else: %{"choice_id" => "choice-1"}

      assert {:error, :invalid_interaction_answer} =
               Loopex.command(
                 attachment,
                 %{command | command_id: "wrong-kind", answer: wrong_answer}
               )

      assert {:accepted, "answer"} = Loopex.command(attachment, command)

      assert {:error, :idempotency_conflict} =
               Loopex.command(
                 attachment,
                 %{command | interaction_id: "different-question"}
               )

      events = finish(attachment)
      assert {:accepted, "answer"} = Loopex.command(attachment, command)

      assert {:error, :interaction_resolved} =
               Loopex.command(
                 attachment,
                 %{command | command_id: "second-answer"}
               )

      terminal = Enum.find(events, &(&1.kind in ["interaction.answered", "interaction.declined"]))
      assert terminal["disposition"] == disposition
      assert Agent.get(fixture.executor, & &1.jobs) == []
      refute_received {:question_policy_call, _}
      [_first, second] = AgentLoopTestModel.dispatched(fixture.model)
      result = Enum.find(second.messages, &(&1["role"] == "tool"))

      assert result["content"] ==
               if(disposition == "answered",
                 do: content,
                 else: Loopex.Conversation.result_content(:denied, content)
               )

      records = Fixture.records(fixture, session)
      response = Enum.find(records, &(&1.payload.kind == "model_question_response_admitted_v1"))
      assert Enum.count(records, &(&1.payload.kind == "model_question_response_admitted_v1")) == 1
      assert response.payload["answer"] == answer
      assert terminal["command_id"] == response.payload["command_id"]
      assert terminal["command_digest"] == response.payload["command_digest"]
      assert terminal["settlement_sequence"] == response.journal_version

      assert {:ok, recovered} =
               SessionState.recover(session, records, Fixture.events(fixture, session))

      assert is_nil(recovered.open_interaction)
      assert recovered.interactions[question["interaction_id"]].status == disposition

      refute Enum.any?(
               records,
               &(&1.payload.kind in [
                   "effect_intent_committed",
                   "executor_receipt_committed",
                   "interaction_resolved_v1"
                 ])
             )
    end
  end

  test "commit unknown re-presents exact question and response bytes before publication" do
    fixture =
      start(
        tools: [ToolDefinition.question_definition()],
        script: [
          %{
            text: "question",
            calls: [%{id: "ask-1", name: "ask", arguments: %{"question" => "Explain"}}]
          },
          %{text: "done", calls: []}
        ]
      )

    assert {:ok, session} =
             Runtime.create_session_with_genesis(
               fixture.runtime,
               "create",
               %{},
               genesis(fixture.definitions)
             )

    assert {:ok, attachment} = Loopex.attach(fixture.runtime, session, after_event_sequence: 0)
    hold_question_commit(fixture, "model_question_requested_v1", :before)

    assert {:accepted, "prompt"} =
             Loopex.command(attachment, %{type: :prompt, command_id: "prompt", content: "go"})

    {pending_waiter, pending_proposal} =
      await_question_commit(fixture, session, "model_question_requested_v1", :before)

    refute Enum.any?(Fixture.events(fixture, session), &(&1.kind == "interaction.requested"))
    assert length(AgentLoopTestModel.dispatched(fixture.model)) == 1

    :ok =
      Loopex.M1RuntimeTestStore.inject(
        fixture.store,
        {:session_journal_commit, :after_linearization_before_result}
      )

    Loopex.M1RuntimeTestStore.release(pending_waiter)
    question = await_question(attachment)
    assert question["interaction_id"] == pending_proposal["interaction_id"]
    assert question["expires_at"] == pending_proposal["expires_at"]
    hold_question_commit(fixture, "model_question_response_admitted_v1", :before)
    parent = self()

    caller =
      spawn(fn ->
        send(
          parent,
          {:unknown_answer_result, self(),
           Loopex.command(attachment, question_answer(question["interaction_id"]))}
        )
      end)

    {answer_waiter, answer_proposal} =
      await_question_commit(fixture, session, "model_question_response_admitted_v1", :before)

    refute_receive {:unknown_answer_result, ^caller, _}, 20
    refute Enum.any?(Fixture.events(fixture, session), &(&1.kind == "interaction.answered"))
    assert length(AgentLoopTestModel.dispatched(fixture.model)) == 1

    :ok =
      Loopex.M1RuntimeTestStore.inject(
        fixture.store,
        {:session_journal_commit, :after_linearization_before_result}
      )

    Loopex.M1RuntimeTestStore.release(answer_waiter)
    assert_receive {:unknown_answer_result, ^caller, {:accepted, "answer"}}, 5_000
    events = finish(attachment)
    assert Enum.count(events, &(&1.kind == "interaction.answered")) == 1
    records = Fixture.records(fixture, session)

    assert Enum.filter(records, &(&1.payload.kind == "model_question_requested_v1"))
           |> Enum.map(& &1.payload) == [pending_proposal]

    assert Enum.filter(records, &(&1.payload.kind == "model_question_response_admitted_v1"))
           |> Enum.map(& &1.payload) == [answer_proposal]

    assert Enum.count(Fixture.events(fixture, session), &(&1.kind == "interaction.requested")) ==
             1

    assert length(AgentLoopTestModel.dispatched(fixture.model)) == 2
    assert Agent.get(fixture.executor, & &1.jobs) == []

    assert {:accepted, "answer"} =
             Loopex.command(attachment, question_answer(question["interaction_id"]))

    assert {:ok, recovered} =
             SessionState.recover(session, records, Fixture.events(fixture, session))

    assert is_nil(recovered.open_interaction)
  end

  test "owner crashes before and after question and response commits retain one settlement" do
    for target <- [:pending, :response], phase <- [:before, :after] do
      fixture =
        start(
          tools: [ToolDefinition.question_definition()],
          script: [
            %{
              text: "question",
              calls: [%{id: "ask-1", name: "ask", arguments: %{"question" => "Explain"}}]
            },
            %{text: "done", calls: []}
          ]
        )

      assert {:ok, session} =
               Runtime.create_session_with_genesis(
                 fixture.runtime,
                 "create",
                 %{},
                 genesis(fixture.definitions)
               )

      assert {:ok, attachment} = Loopex.attach(fixture.runtime, session, after_event_sequence: 0)

      kind =
        if target == :pending,
          do: "model_question_requested_v1",
          else: "model_question_response_admitted_v1"

      if target == :pending, do: hold_question_commit(fixture, kind, phase)

      assert {:accepted, "prompt"} =
               Loopex.command(attachment, %{type: :prompt, command_id: "prompt", content: "go"})

      question = if target == :response, do: await_question(attachment)
      parent = self()

      caller =
        if target == :response do
          hold_question_commit(fixture, kind, phase)

          spawn(fn ->
            result =
              try do
                Loopex.command(attachment, question_answer(question["interaction_id"]))
              catch
                :exit, reason -> {:caller_exit, reason}
              end

            send(parent, {:question_caller_finished, self(), result})
          end)
        end

      {waiter, proposed} = await_question_commit(fixture, session, kind, phase)
      id = proposed["interaction_id"]
      matching = Enum.filter(Fixture.records(fixture, session), &(&1.payload.kind == kind))
      assert length(matching) == if(phase == :after, do: 1, else: 0)
      assert length(AgentLoopTestModel.dispatched(fixture.model)) == 1
      assert Agent.get(fixture.executor, & &1.jobs) == []

      {:ok, children} = Loopex.Runtime.Supervisor.children(fixture.runtime.supervisor)
      [{_, owner, _, _}] = DynamicSupervisor.which_children(children.sessions)
      monitor = Process.monitor(owner)
      Process.exit(owner, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^owner, :killed}, 5_000

      assert {:ok, ^session} =
               Loopex.resume_session(fixture.runtime, session, command_id: "successor")

      Loopex.M1RuntimeTestStore.release(waiter)

      if caller do
        assert_receive {:question_caller_finished, ^caller, result}, 5_000
        assert result == {:error, :session_unavailable} or match?({:caller_exit, _}, result)
      end

      assert {:ok, successor} = Loopex.attach(fixture.runtime, session, after_event_sequence: 0)
      retained_question = await_question(successor)
      assert retained_question["interaction_id"] == id

      if target == :pending and phase == :after do
        assert retained_question["expires_at"] == proposed["expires_at"]
        assert retained_question["choices"] == proposed["interaction_request"]["choices"]
      end

      answer_command_id =
        if target == :response and phase == :before, do: "successor-answer", else: "answer"

      if target == :response and phase == :before do
        # Concept: a proved non-commit is terminal for its transaction identity.
        # Technical depth: ADR 0006 requires a fresh logical transaction after
        # succession; the old ID cannot acquire new owner or timestamp bindings.
        assert {:terminal, {:not_committed, :stale_owner_epoch}} =
                 await_question_transaction(fixture.store, session, "answer")

        assert {:error, :tx_id_conflict} = Loopex.command(successor, question_answer(id))
      end

      assert {:accepted, ^answer_command_id} =
               Loopex.command(successor, question_answer(id, answer_command_id))

      events = finish(successor)
      assert Enum.count(events, &(&1.kind == "interaction.answered")) == 1
      assert Enum.count(events, &(&1.kind == "tool.finished")) == 1
      assert length(AgentLoopTestModel.dispatched(fixture.model)) == 2
      assert Agent.get(fixture.executor, & &1.jobs) == []

      records = Fixture.records(fixture, session)
      pending = Enum.filter(records, &(&1.payload.kind == "model_question_requested_v1"))

      responses =
        Enum.filter(records, &(&1.payload.kind == "model_question_response_admitted_v1"))

      assert length(pending) == 1
      assert length(responses) == 1

      if phase == :after,
        do: assert(hd(if(target == :pending, do: pending, else: responses)).payload == proposed)

      assert {:ok, recovered} =
               SessionState.recover(session, records, Fixture.events(fixture, session))

      assert is_nil(recovered.open_interaction)
      assert recovered.interactions[id].answer == %{"text" => "retained answer"}

      assert {:accepted, ^answer_command_id} =
               Loopex.command(successor, question_answer(id, answer_command_id))
    end
  end

  defp question_answer(id, command_id \\ "answer"),
    do: %{
      type: :interaction_answer,
      command_id: command_id,
      interaction_id: id,
      answer: %{"text" => "retained answer"}
    }

  defp hold_question_commit(fixture, kind, :before),
    do:
      Loopex.M1RuntimeTestStore.hold_next_record_before_linearization(fixture.store, kind, self())

  defp hold_question_commit(fixture, kind, :after),
    do: Loopex.M1RuntimeTestStore.delay_after_record(fixture.store, kind, self())

  defp await_question_commit(_fixture, _session, kind, :before) do
    assert_receive {:record_held_before_linearization, waiter, _store, ^kind, transaction}, 5_000
    {waiter, Enum.find(transaction.records, &(&1.kind == kind))}
  end

  defp await_question_commit(fixture, session, kind, :after) do
    assert_receive {:record_linearized, waiter, _store, ^kind, :session_journal_commit,
                    {:committed, _, _receipt}},
                   5_000

    records = Fixture.records(fixture, session)
    {waiter, Enum.find(records, &(&1.payload.kind == kind)).payload}
  end

  defp await_question_transaction(store, session, tx_id, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + 5_000

    case Loopex.M1RuntimeTestStore.transaction_status(store, session, "session", tx_id) do
      :absent ->
        if System.monotonic_time(:millisecond) >= deadline, do: flunk("transaction unresolved")
        Process.sleep(10)
        await_question_transaction(store, session, tx_id, deadline)

      result ->
        result
    end
  end

  test "aborting a pending model question settles its slot and preserves a cancelled result" do
    fixture =
      start(
        tools: [ToolDefinition.question_definition()],
        script: [
          %{
            text: "question",
            calls: [%{id: "ask-1", name: "ask", arguments: %{"question" => "Explain"}}]
          },
          %{text: "next prompt", calls: []}
        ]
      )

    assert {:ok, session} =
             Runtime.create_session_with_genesis(
               fixture.runtime,
               "create",
               %{},
               genesis(fixture.definitions)
             )

    assert {:ok, attachment} = Loopex.attach(fixture.runtime, session, after_event_sequence: 0)

    assert {:accepted, "prompt"} =
             Loopex.command(attachment, %{
               type: :prompt,
               command_id: "prompt",
               content: "implement"
             })

    question = await_question(attachment)
    assert {:accepted, "abort"} = Loopex.command(attachment, %{type: :abort, command_id: "abort"})
    events = finish(attachment)
    assert Enum.find(events, &(&1.kind == "run.finished"))["outcome"] == "cancelled"
    cancelled = Enum.find(events, &(&1.kind == "interaction.cancelled"))
    assert cancelled["interaction_id"] == question["interaction_id"]
    assert cancelled["producer"] == "model_tool"
    assert cancelled["disposition"] == "cancelled"
    assert cancelled["command_id"] == "abort"
    assert is_binary(cancelled["command_digest"])

    assert {:ok, recovered} =
             SessionState.recover(
               session,
               Fixture.records(fixture, session),
               Fixture.events(fixture, session)
             )

    assert is_nil(recovered.open_interaction)

    assert Enum.find(
             SessionState.elements(recovered, question["run_id"]),
             &(&1.kind == :tool_result)
           ).outcome == :cancelled

    assert Agent.get(fixture.executor, & &1.jobs) == []

    assert {:error, :interaction_resolved} =
             Loopex.command(
               attachment,
               %{
                 type: :interaction_answer,
                 command_id: "late",
                 interaction_id: question["interaction_id"],
                 answer: %{"text" => "too late"}
               }
             )

    prompt(attachment, "next", "continue")
    [_first, second] = AgentLoopTestModel.dispatched(fixture.model)
    assert Enum.find(second.messages, &(&1["role"] == "tool"))["outcome"] == "cancelled"
  end

  test "invalid question arguments fail before policy or executor admission" do
    for arguments <- [
          %{"question" => ""},
          %{"question" => "Pick", "choices" => ["same", "same"]},
          %{"question" => "Pick", "choices" => []}
        ] do
      fixture =
        start(
          tools: [ToolDefinition.question_definition()],
          policy: Loopex.AgentLoopUnexpectedPolicy,
          policy_identity: %{"id" => "loopex.test.question-policy", "revision" => "1"},
          script: [
            %{text: "question", calls: [%{id: "ask-invalid", name: "ask", arguments: arguments}]},
            %{text: "done", calls: []}
          ]
        )

      assert {:ok, session} =
               Runtime.create_session_with_genesis(
                 fixture.runtime,
                 "create-invalid-question",
                 %{},
                 genesis(fixture.definitions)
               )

      assert {:ok, attachment} = Loopex.attach(fixture.runtime, session, after_event_sequence: 0)

      assert {:accepted, "prompt"} =
               Loopex.command(attachment, %{
                 type: :prompt,
                 command_id: "prompt",
                 content: "implement"
               })

      events = finish(attachment)
      terminal = Enum.find(events, &(&1.kind == "tool.finished"))
      assert terminal["outcome"] == "failed"
      assert terminal["reason"] == "invalid_tool_arguments"
      refute Enum.any?(events, &(&1.kind == "interaction.requested"))
      assert Agent.get(fixture.executor, & &1.jobs) == []
    end
  end

  test "two prompts and restart stage captured host instructions, settings and tools" do
    fixture =
      start(
        script: [%{text: "first answer", calls: []}, %{text: "second answer", calls: []}],
        max_tokens: 7
      )

    configuration = configuration(String.duplicate("captured ", 400))
    genesis = genesis(fixture.definitions, configuration)

    assert {:ok, session} =
             Runtime.create_session_with_genesis(fixture.runtime, "create-v3", %{}, genesis)

    assert {:ok, attachment} = Loopex.attach(fixture.runtime, session, after_event_sequence: 0)
    prompt(attachment, "first", "first prompt")
    prompt(attachment, "second", "second prompt")
    [first, second] = AgentLoopTestModel.dispatched(fixture.model)
    {:ok, text} = Instructions.render(configuration["instructions"])

    for request <- [first, second] do
      assert hd(request.messages) == %{"role" => "system", "content" => text}
      assert request.sampling == SessionConfiguration.sampling(configuration)
      assert request.tools == fixture.definitions
    end

    assert Enum.map(tl(second.messages), & &1["content"]) == [
             "first prompt",
             "first answer",
             "second prompt"
           ]

    records = Fixture.records(fixture, session)
    assert hd(records).payload == genesis

    assert {:ok, recovered} =
             SessionState.recover(session, records, Fixture.events(fixture, session))

    for run <- recovered.run_order do
      assert SessionState.run_configuration(recovered, run) == configuration
    end

    staged = Enum.filter(records, &(&1.payload.kind == "model_request_committed_v2"))
    assert length(staged) == 2

    for row <- staged do
      assert row.payload["configuration_version"] == 1

      assert hd(row.payload["context_receipt"]["blocks"])["source_reference"] ==
               SessionConfiguration.instruction_source(configuration)
    end

    assert :ok = Loopex.stop(fixture.runtime)

    restarted =
      start(
        store: fixture.store,
        tools: [],
        max_tokens: 3,
        cleanup_grace_ms: 1,
        script: [%{text: "third answer", calls: []}]
      )

    before_duplicate = Fixture.records(restarted, session)

    assert {:ok, ^session} =
             Runtime.create_session_with_genesis(restarted.runtime, "create-v3", %{}, genesis)

    assert Fixture.records(restarted, session) == before_duplicate

    assert {:ok, ^session} =
             Loopex.resume_session(restarted.runtime, session, command_id: "resume-v3")

    assert {:ok, attachment} =
             Loopex.attach(restarted.runtime, session,
               after_event_sequence: List.last(Fixture.events(restarted, session)).event_sequence
             )

    prompt(attachment, "third", "third prompt")
    [third] = AgentLoopTestModel.dispatched(restarted.model)
    assert hd(third.messages) == hd(first.messages)
    assert third.sampling == first.sampling
    assert third.tools == first.tools

    assert Enum.map(tl(third.messages), & &1["content"]) == [
             "first prompt",
             "first answer",
             "second prompt",
             "second answer",
             "third prompt"
           ]

    assert {:ok, final} =
             SessionState.recover(
               session,
               Fixture.records(restarted, session),
               Fixture.events(restarted, session)
             )

    assert final.cleanup_grace_ms == 5_000
  end

  test "fresh creation validates admitted definitions and normalized original options" do
    fixture = start(script: [])
    definition = Map.put(Fixture.tool_definition(), "description", "unregistered bytes")

    assert Runtime.create_session_with_genesis(
             fixture.runtime,
             "unregistered",
             %{},
             genesis([definition])
           ) ==
             {:error, :invalid_session_creation}

    assert Runtime.create_session_with_genesis(
             fixture.runtime,
             "options-mismatch",
             %{tenant: "other"},
             genesis(fixture.definitions)
           ) ==
             {:error, :invalid_session_creation}

    assert Fixture.run_ids(fixture) == {}

    selected = genesis(fixture.definitions) |> Map.put("options", %{"tenant" => "a"})

    assert {:ok, session} =
             Runtime.create_session_with_genesis(
               fixture.runtime,
               "normalized",
               %{tenant: "a"},
               selected
             )

    assert hd(Fixture.records(fixture, session)).payload == selected

    assert {:ok, ^session} =
             Runtime.create_session_with_genesis(
               fixture.runtime,
               "normalized",
               %{"tenant" => "a"},
               selected
             )
  end

  test "one create identity cannot substitute changed captured genesis" do
    fixture = start(script: [])
    original = genesis(fixture.definitions)

    assert {:ok, session} =
             Runtime.create_session_with_genesis(fixture.runtime, "identity", %{}, original)

    changed = put_in(original, ["runtime_configuration", "cleanup_grace_ms"], 1)

    assert {:error, _reason} =
             Runtime.create_session_with_genesis(fixture.runtime, "identity", %{}, changed)

    assert hd(Fixture.records(fixture, session)).payload == original
  end

  test "replay rejects configuration-version substitution despite unchanged request receipts" do
    fixture = start(script: [%{text: "answer", calls: []}])

    assert {:ok, session} =
             Runtime.create_session_with_genesis(
               fixture.runtime,
               "create",
               %{},
               genesis(fixture.definitions)
             )

    assert {:ok, attachment} = Loopex.attach(fixture.runtime, session, after_event_sequence: 0)
    prompt(attachment, "prompt", "input")
    records = Fixture.records(fixture, session)
    events = Fixture.events(fixture, session)
    assert {:ok, _} = SessionState.recover(session, records, events)

    for kind <- ["prompt_admitted_v3", "model_request_committed_v2"] do
      substituted =
        Enum.map(records, fn record ->
          if record.payload.kind == kind,
            do: put_in(record, [:payload, "configuration_version"], 2),
            else: record
        end)

      assert {:error, _reason} = SessionState.recover(session, substituted, events)
    end
  end

  test "configured input overflow commits a v2 numeric refusal without a provider call" do
    fixture = start(script: [%{text: "must not run", calls: []}])

    config =
      configuration()
      |> Map.put("context_token_budget", 700)
      |> Map.put("system_class_tokens", 600)
      |> put_in(["budget_origins", "context_token_budget"], "explicit")

    assert {:ok, session} =
             Runtime.create_session_with_genesis(
               fixture.runtime,
               "create",
               %{},
               genesis(fixture.definitions, config)
             )

    assert {:ok, attachment} = Loopex.attach(fixture.runtime, session, after_event_sequence: 0)

    assert {:accepted, "overflow"} =
             Loopex.command(attachment, %{
               type: :prompt,
               command_id: "overflow",
               content: String.duplicate("p", 2_100)
             })

    events = finish(attachment)
    terminal = Enum.find(events, &(&1.kind == "run.finished"))
    assert terminal["outcome"] == "failed"
    assert terminal["failure"]["version"] == 2
    assert terminal["failure"]["measurement_scope"] == "ordinary"
    assert terminal["failure"]["dimension"] == "context_tokens"
    assert terminal["failure"]["limit"] == 700
    assert terminal["failure"]["hard_limit"] == 700
    assert AgentLoopTestModel.dispatched(fixture.model) == []
    records = Fixture.records(fixture, session)
    refusal = Enum.find(records, &(&1.payload.kind == "context_admission_refused_v2"))
    assert refusal.payload["configuration_version"] == 1
    assert refusal.payload["projection_state"] == "measured"
    assert refusal.payload["episode_id"] == nil
    assert {:ok, _} = SessionState.recover(session, records, Fixture.events(fixture, session))

    invalid =
      Enum.map(records, fn row ->
        if row.payload.kind == "context_admission_refused_v2",
          do: put_in(row, [:payload, "failure", "hard_limit"], 701),
          else: row
      end)

    assert {:error, _} = SessionState.recover(session, invalid, Fixture.events(fixture, session))
  end

  test "captured refuse mode denies policy deferral without an interaction or executor effect" do
    fixture =
      start(
        policy: Loopex.ConfiguredSessionDeferringPolicy,
        script: [
          %{
            text: "try write",
            calls: [%{id: "write-call", name: "write", arguments: %{"path" => "a"}}]
          },
          %{text: "write was denied", calls: []}
        ]
      )

    retained = genesis(fixture.definitions) |> Map.put("policy_defer_mode", "refuse")

    assert {:ok, session} =
             Runtime.create_session_with_genesis(fixture.runtime, "create", %{}, retained)

    assert {:ok, attachment} = Loopex.attach(fixture.runtime, session, after_event_sequence: 0)

    assert {:accepted, "prompt"} =
             Loopex.command(attachment, %{type: :prompt, command_id: "prompt", content: "write a"})

    events = finish(attachment)
    assert Enum.find(events, &(&1.kind == "run.finished"))["outcome"] == "completed"
    denial = Enum.find(events, &(&1.kind == "tool.finished"))
    assert denial["outcome"] == "denied"
    assert denial["reason"] == "interaction_unsupported"
    refute Enum.any?(events, &(&1.kind == "interaction.requested"))

    assert {:ok, recovered} =
             SessionState.recover(
               session,
               Fixture.records(fixture, session),
               Fixture.events(fixture, session)
             )

    assert recovered.policy_defer_mode == "refuse"
    assert is_nil(recovered.open_interaction)
    assert Agent.get(fixture.executor, & &1.jobs) == []
  end

  test "self-consistent renamed instruction provenance cannot replace captured source identity" do
    fixture = start(script: [%{text: "answer", calls: []}])

    assert {:ok, session} =
             Runtime.create_session_with_genesis(
               fixture.runtime,
               "create",
               %{},
               genesis(fixture.definitions)
             )

    assert {:ok, attachment} = Loopex.attach(fixture.runtime, session, after_event_sequence: 0)
    prompt(attachment, "prompt", "input")

    records =
      Enum.map(Fixture.records(fixture, session), fn record ->
        if record.payload.kind == "model_request_committed_v2" do
          receipt = record.payload["context_receipt"]
          [first | rest] = receipt["blocks"]
          changed = put_in(first, ["source_reference", "version"], "host.v2")
          blocks = [changed | rest]

          receipt = %{
            receipt
            | "blocks" => blocks,
              "ordered_descriptor_digest" => descriptor_digest(blocks)
          }

          put_in(record, [:payload, "context_receipt"], receipt)
        else
          record
        end
      end)

    assert {:error, :invalid_model_request_transition} =
             SessionState.recover(session, records, Fixture.events(fixture, session))
  end

  test "captured system ceilings retain strict edges and the legacy fallback" do
    observations = %{
      system_class_tokens: 4_999,
      system_class_token_ceiling: 5_000,
      provider_estimated_tokens: 6_000,
      context_token_budget: 8_192,
      context_record_byte_ceiling: 65_536,
      context_record_depth_limit: 12,
      context_record_cardinality_limit: 1_024
    }

    record = %{kind: "candidate"}
    assert ContextAdmission.preflight_required_candidate(record, observations) == :ok

    for observed <- [5_000, 5_001] do
      assert {:refused,
              %{"dimension" => "system_class_tokens", "observed" => ^observed, "limit" => 5_000}} =
               ContextAdmission.preflight_required_candidate(record, %{
                 observations
                 | system_class_tokens: observed
               })
    end

    legacy = Map.delete(observations, :system_class_token_ceiling)

    assert ContextAdmission.preflight_required_candidate(record, %{
             legacy
             | system_class_tokens: 999
           }) == :ok

    assert {:refused, %{"limit" => 1_000}} =
             ContextAdmission.preflight_required_candidate(record, %{
               legacy
               | system_class_tokens: 1_000
             })

    for limit <- [nil, 0, -1, 1.0, "5000", 18_446_744_073_709_551_616] do
      assert ContextAdmission.preflight_required_candidate(record, %{
               observations
               | system_class_token_ceiling: limit
             }) ==
               {:error, :invalid_system_class_ceiling}
    end

    for observed <- [nil, -1, "4999"] do
      assert ContextAdmission.preflight_required_candidate(record, %{
               observations
               | system_class_tokens: observed
             }) ==
               {:error, :invalid_system_class_observation}
    end
  end

  defp descriptor_digest(blocks) do
    blocks
    |> Enum.reduce(
      :crypto.hash_update(:crypto.hash_init(:sha256), "loopex.context.descriptors.v1" <> <<0>>),
      fn block, digest ->
        bytes = Canonical.encode(block)

        digest
        |> :crypto.hash_update(<<byte_size(bytes)::unsigned-big-integer-size(64)>>)
        |> :crypto.hash_update(bytes)
      end
    )
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  defp start(options) do
    fixture = Fixture.start(options)
    on_exit(fn -> Fixture.stop(fixture) end)
    fixture
  end

  defp prompt(attachment, id, content) do
    assert {:accepted, ^id} =
             Loopex.command(attachment, %{type: :prompt, command_id: id, content: content})

    assert Enum.find(finish(attachment), &(&1.kind == "run.finished"))["outcome"] == "completed"
  end

  defp await_question(attachment, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + 5_000

    case Loopex.next_event(attachment) do
      {:ok, %{kind: "interaction.requested"} = event} ->
        event

      _ ->
        if System.monotonic_time(:millisecond) >= deadline, do: flunk("no model question")
        Process.sleep(10)
        await_question(attachment, deadline)
    end
  end

  defp finish(attachment),
    do: collect(attachment, System.monotonic_time(:millisecond) + 5_000, [])

  defp collect(attachment, deadline, events) do
    case Loopex.next_event(attachment) do
      {:ok, event} ->
        if event.kind == "run.finished",
          do: Enum.reverse([event | events]),
          else: collect(attachment, deadline, [event | events])

      other ->
        if System.monotonic_time(:millisecond) >= deadline do
          flunk(
            "configured run did not finish: #{inspect(other)}; #{inspect(Enum.map(events, & &1.kind))}"
          )
        else
          Process.sleep(10)
          collect(attachment, deadline, events)
        end
    end
  end
end
