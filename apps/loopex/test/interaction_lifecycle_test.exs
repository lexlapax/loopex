Code.require_file("support/m1_runtime_helper.exs", __DIR__)
Code.require_file("support/agent_loop_helper.exs", __DIR__)

defmodule Loopex.InteractionLifecycleTest do
  @moduledoc """
  ## Concept

  A host policy may answer a tool decision with a bounded question instead of a
  verdict. These cases prove what question the runtime will carry, what it
  refuses, and that asking one authorizes nothing by itself.

  ## Technical depth

  The evaluator and the question family land before the durable lifecycle that
  uses them, so this file starts with the boundary: one callback, called once,
  whose deferred question is admitted only inside the family accepted ADR 0024
  fixes. The inherited one-shot projection stays exactly as M2 locked it, which
  the case below proves against the same policy module.
  """

  use ExUnit.Case, async: false

  alias Loopex.AgentLoopFixture, as: Fixture
  alias Loopex.Interaction
  alias Loopex.Policy

  defmodule DeferringPolicy do
    @moduledoc false
    @behaviour Loopex.Policy

    @impl Loopex.Policy
    def decide(request) do
      case Map.get(request, :interaction_response) do
        nil -> {:defer, Map.get(request, :test_question, question())}
        %{answer: %{choice_id: "allow"}} -> {:allow, nil}
        %{answer: %{choice_id: _other}} -> {:deny, :policy_denied}
      end
    end

    def question do
      %{
        kind: :choice,
        prompt: "May the tool write the file?",
        choices: [%{id: "allow", label: "Allow once"}, %{id: "deny", label: "Deny"}],
        expires_in_ms: 60_000
      }
    end
  end

  defmodule CountingPolicy do
    @moduledoc false
    @behaviour Loopex.Policy

    @impl Loopex.Policy
    def decide(_request) do
      count = :counters.add(:persistent_term.get(__MODULE__), 1, 1)
      _observed = count
      {:defer, DeferringPolicy.question()}
    end
  end

  test "the evaluator admits a bounded deferred question that the inherited projection still refuses" do
    request = policy_request()

    assert {:defer, question} = Policy.evaluate(DeferringPolicy, request)
    assert question.kind == :choice
    assert Enum.map(question.choices, & &1.id) == ["allow", "deny"]
    assert question.expires_in_ms == 60_000

    # M2's locked one-shot projection is unchanged by the evaluator existing.
    assert Policy.decide(DeferringPolicy, request) == {:deny, :interaction_unsupported}
  end

  test "a caller that already owns a supervised task chooses how a defer is read" do
    request = policy_request()

    # The coordinator runs the callback in its own supervised task, so it calls
    # the callback form rather than the evaluator's. Both dispositions are
    # available there, and the inherited one is still the default.
    assert Policy.evaluate_callback(DeferringPolicy, request) ==
             {:deny, :interaction_unsupported}

    assert Policy.evaluate_callback(DeferringPolicy, request, :refuse_defer) ==
             {:deny, :interaction_unsupported}

    assert {:defer, question} =
             Policy.evaluate_callback(DeferringPolicy, request, :admit_defer)

    assert question.kind == :choice
  end

  test "a resumed evaluation carries the answer and only an allow comes back" do
    answered =
      Map.put(
        policy_request(),
        :interaction_response,
        Interaction.response_member("interaction-1", DeferringPolicy.question(), "allow")
      )

    assert {:allow, nil} = Policy.evaluate(DeferringPolicy, answered)

    denied =
      Map.put(
        policy_request(),
        :interaction_response,
        Interaction.response_member("interaction-1", DeferringPolicy.question(), "deny")
      )

    assert {:deny, :policy_denied} = Policy.evaluate(DeferringPolicy, denied)
  end

  test "the host callback runs exactly once per evaluation" do
    counter = :counters.new(1, [])
    :persistent_term.put(CountingPolicy, counter)
    on_exit(fn -> :persistent_term.erase(CountingPolicy) end)

    assert {:defer, _question} = Policy.evaluate(CountingPolicy, policy_request())
    assert :counters.get(counter, 1) == 1

    assert {:deny, :interaction_unsupported} = Policy.decide(CountingPolicy, policy_request())
    assert :counters.get(counter, 1) == 2
  end

  test "a question outside the admitted family is unavailable rather than retained" do
    for refused <- [
          %{DeferringPolicy.question() | kind: :freeform},
          %{DeferringPolicy.question() | prompt: ""},
          %{DeferringPolicy.question() | prompt: :binary.copy("a", 2_049)},
          %{DeferringPolicy.question() | choices: []},
          %{
            DeferringPolicy.question()
            | choices: Enum.map(1..9, &%{id: "c#{&1}", label: "choice #{&1}"})
          },
          %{
            DeferringPolicy.question()
            | choices: [%{id: "same", label: "one"}, %{id: "same", label: "two"}]
          },
          %{DeferringPolicy.question() | choices: [%{id: "", label: "empty id"}]},
          %{DeferringPolicy.question() | choices: [%{id: "c", label: ""}]},
          %{DeferringPolicy.question() | expires_in_ms: 0},
          %{DeferringPolicy.question() | expires_in_ms: 600_001},
          Map.put(DeferringPolicy.question(), :decision_ref, :binary.copy("r", 257)),
          Map.put(DeferringPolicy.question(), :unknown, true),
          :not_a_map
        ] do
      assert {:error, :invalid_interaction_request} = Interaction.validate_request(refused)

      asked = Map.put(policy_request(), :test_question, refused)
      assert {:deny, :policy_unavailable} = Policy.evaluate(DeferringPolicy, asked)
    end
  end

  test "a retained question keeps the host reference private and the answer bounded" do
    with_reference = Map.put(DeferringPolicy.question(), :decision_ref, "host-ref")
    assert {:ok, validated} = Interaction.validate_request(with_reference)
    assert validated.decision_ref == "host-ref"

    record = %{
      interaction_id: "interaction-1",
      run_id: "run-1",
      turn: 1,
      tool_call_id: "call-1",
      status: "pending",
      request: validated,
      expires_at: 1_000
    }

    view = Interaction.view(record)
    refute Map.has_key?(view, "decision_ref")
    refute inspect(view, limit: :infinity, printable_limit: :infinity) =~ "host-ref"

    assert view["choices"] == [
             %{"id" => "allow", "label" => "Allow once"},
             %{"id" => "deny", "label" => "Deny"}
           ]

    refute Map.has_key?(view, "choice_id")

    answered = Interaction.view(Map.put(record, :choice_id, "allow"))
    assert answered["choice_id"] == "allow"

    assert Interaction.offered?(validated, "allow")
    refute Interaction.offered?(validated, "invented")
    refute Interaction.offered?(validated, :allow)
  end

  test "the three digests stay distinct and the expiry is the earlier instant" do
    {:ok, question} = Interaction.validate_request(DeferringPolicy.question())
    member = Interaction.response_member("interaction-1", question, "allow")

    policy_digest = Interaction.digest(policy_request())
    question_digest = Interaction.digest(question)

    assert policy_digest != question_digest
    assert question_digest != member.answer_digest
    assert member.answer_digest == Interaction.digest(%{choice_id: "allow"})
    assert member.interaction_request == question

    # The run's deadline ends the question early; without one the requested
    # duration stands.
    assert Interaction.effective_expiry(1_000, 60_000, 5_000) == 5_000
    assert Interaction.effective_expiry(1_000, 60_000, 500_000) == 61_000
    assert Interaction.effective_expiry(1_000, 60_000, nil) == 61_000
  end

  defmodule SuspendingPolicy do
    @moduledoc false
    @behaviour Loopex.Policy

    @impl Loopex.Policy
    def decide(_request) do
      {:defer,
       %{
         kind: :choice,
         prompt: "May the tool write the file?",
         choices: [%{id: "allow", label: "Allow once"}, %{id: "deny", label: "Deny"}],
         expires_in_ms: 700
       }}
    end
  end

  test "policy defer commits one pending interaction before publication and suspends the run without executor intent" do
    fixture = loop_fixture(SuspendingPolicy)
    {session_id, attachment} = loop_session(fixture)

    assert {:accepted, "p1"} =
             Loopex.command(attachment, %{type: :prompt, command_id: "p1", content: "do it"})

    requested = await_event(fixture, session_id, "interaction.requested")
    assert requested["prompt"] == "May the tool write the file?"

    # The same bounded view is readable from the session's own status, at the
    # cursor that status reports, and it carries no host reference.
    assert {:ok, status} = Loopex.session_status(fixture.runtime, session_id)
    assert status.open_interaction["interaction_id"] == requested["interaction_id"]
    assert status.open_interaction["status"] == "pending"
    refute Map.has_key?(status.open_interaction, "decision_ref")
    refute Map.has_key?(status.open_interaction, "choice_id")
    assert Enum.map(requested["choices"], & &1["id"]) == ["allow", "deny"]
    assert is_integer(requested["expires_at"])

    events = Fixture.events(fixture, session_id)
    assert Enum.all?(events, &(&1.kind != "tool.started"))
    assert Enum.all?(events, &(&1.kind != "run.finished"))

    # The question is on disk as one private record, and no executor intent
    # exists beside it: the transaction that publishes the request is the one
    # that retained it, and nothing was authorized by asking.
    records = Fixture.records(fixture, session_id)
    retained = Enum.filter(records, &(&1.payload.kind == "interaction_requested_v1"))
    assert length(retained) == 1
    assert Enum.all?(records, &(&1.payload.kind != "effect_intent_committed_v2"))
    assert hd(retained).payload["interaction_id"] == requested["interaction_id"]
    assert hd(retained).payload["round"] == 0

    # The question stands: the run is suspended rather than finished, and the
    # executor was never asked to do anything.
    assert {:ok, %{active_run_id: run_id}} = Loopex.session_status(fixture.runtime, session_id)
    assert is_binary(run_id)

    # Nobody answers, so the question expires and the call it suspended is
    # denied rather than left standing.
    expired = await_event(fixture, session_id, "interaction.expired", 4_000)
    assert expired["interaction_id"] == requested["interaction_id"]
    assert expired["run_id"] == requested["run_id"]
    assert expired["turn"] == requested["turn"]
    assert expired["tool_call_id"] == requested["tool_call_id"]
    assert Map.has_key?(expired, "answer_command_id")
    assert expired["answer_command_id"] == nil
    refute Map.has_key?(expired, "choice_id")

    finished = await_event(fixture, session_id, "run.finished", 4_000)
    assert finished["outcome"] == "completed"

    tool_finished = await_event(fixture, session_id, "tool.finished", 4_000)
    assert tool_finished["outcome"] == "denied"
  end

  defmodule AnsweringPolicy do
    @moduledoc false
    @behaviour Loopex.Policy

    @impl Loopex.Policy
    def decide(request) do
      case Map.get(request, :interaction_response) do
        nil ->
          {:defer,
           %{
             kind: :choice,
             prompt: "May the tool write the file?",
             choices: [%{id: "allow", label: "Allow once"}, %{id: "deny", label: "Deny"}],
             expires_in_ms: 60_000
           }}

        %{answer: %{choice_id: "allow"}} ->
          {:allow, nil}

        %{answer: %{choice_id: _refused}} ->
          {:deny, :policy_denied}
      end
    end
  end

  test "a committed answer re-enters host policy and only an allow result mints a grant before dispatch" do
    fixture = loop_fixture(AnsweringPolicy)
    {session_id, attachment} = loop_session(fixture)

    assert {:accepted, "p1"} =
             Loopex.command(attachment, %{type: :prompt, command_id: "p1", content: "do it"})

    requested = await_event(fixture, session_id, "interaction.requested")

    assert {:accepted, "answer-1"} =
             Loopex.command(attachment, %{
               type: :interaction_answer,
               command_id: "answer-1",
               interaction_id: requested["interaction_id"],
               choice_id: "allow"
             })

    resolved = await_event(fixture, session_id, "interaction.resolved", 4_000)
    assert resolved["resolution"] == "allowed"
    assert resolved["choice_id"] == "allow"

    tool_finished = await_event(fixture, session_id, "tool.finished", 4_000)
    assert tool_finished["outcome"] == "completed"

    finished = await_event(fixture, session_id, "run.finished", 4_000)
    assert finished["outcome"] == "completed"

    # The grant and the intent exist only after the allow, and the allow only
    # after the answer: asking the question minted nothing.
    records = Fixture.records(fixture, session_id)
    intents = Enum.filter(records, &(&1.payload.kind == "effect_intent_committed_v2"))
    assert length(intents) == 1

    resolution = Enum.find(records, &(&1.payload.kind == "interaction_resolved_v1"))
    assert resolution.payload["resolution"] == "allowed"
    assert hd(intents).journal_version > resolution.journal_version

    answer_record =
      Enum.find(records, &(&1.payload["command_type"] == "interaction_answer"))

    assert answer_record.journal_version < resolution.journal_version
  end

  test "an answer choosing refusal resolves the question as denied and dispatches nothing" do
    fixture = loop_fixture(AnsweringPolicy)
    {session_id, attachment} = loop_session(fixture)

    assert {:accepted, "p1"} =
             Loopex.command(attachment, %{type: :prompt, command_id: "p1", content: "do it"})

    requested = await_event(fixture, session_id, "interaction.requested")

    assert {:accepted, "answer-1"} =
             Loopex.command(attachment, %{
               type: :interaction_answer,
               command_id: "answer-1",
               interaction_id: requested["interaction_id"],
               choice_id: "deny"
             })

    resolved = await_event(fixture, session_id, "interaction.resolved", 4_000)
    assert resolved["resolution"] == "denied"

    tool_finished = await_event(fixture, session_id, "tool.finished", 4_000)
    assert tool_finished["outcome"] == "denied"

    assert Enum.all?(Fixture.events(fixture, session_id), &(&1.kind != "tool.started"))
  end

  test "identical response replay returns the historical admission and changed content wrong target resolved expired or absent interactions refuse with stable reasons" do
    fixture = loop_fixture(AnsweringPolicy)
    {session_id, attachment} = loop_session(fixture)

    assert {:accepted, "p1"} =
             Loopex.command(attachment, %{type: :prompt, command_id: "p1", content: "do it"})

    requested = await_event(fixture, session_id, "interaction.requested")
    interaction_id = requested["interaction_id"]

    assert {:error, :interaction_absent} =
             Loopex.command(attachment, %{
               type: :interaction_answer,
               command_id: "answer-absent",
               interaction_id: "interaction-nobody-asked",
               choice_id: "allow"
             })

    assert {:error, :invalid_interaction_answer} =
             Loopex.command(attachment, %{
               type: :interaction_answer,
               command_id: "answer-invented",
               interaction_id: interaction_id,
               choice_id: "invented"
             })

    assert {:accepted, "answer-1"} =
             Loopex.command(attachment, %{
               type: :interaction_answer,
               command_id: "answer-1",
               interaction_id: interaction_id,
               choice_id: "allow"
             })

    # The same command replayed returns the admission history already holds,
    # rather than being admitted a second time or refused as late.
    assert {:accepted, "answer-1"} =
             Loopex.command(attachment, %{
               type: :interaction_answer,
               command_id: "answer-1",
               interaction_id: interaction_id,
               choice_id: "allow"
             })

    # The same command id carrying different content is a different command,
    # and is refused rather than silently answered by the historical one.
    assert {:error, :idempotency_conflict} =
             Loopex.command(attachment, %{
               type: :interaction_answer,
               command_id: "answer-1",
               interaction_id: interaction_id,
               choice_id: "deny"
             })

    _resolved = await_event(fixture, session_id, "interaction.resolved", 4_000)

    # A late answer to a question that has resolved refuses rather than
    # reopening it.
    assert {:error, :interaction_resolved} =
             Loopex.command(attachment, %{
               type: :interaction_answer,
               command_id: "answer-late",
               interaction_id: interaction_id,
               choice_id: "deny"
             })

    # Exactly one admission is on disk for that answer.
    records = Fixture.records(fixture, session_id)

    admitted =
      Enum.filter(
        records,
        &(&1.payload["command_type"] == "interaction_answer" and
            &1.payload["admission"] == "accepted")
      )

    assert length(admitted) == 1
  end

  test "every interaction transaction cut is journaled before publication and before any effect intent" do
    fixture = loop_fixture(AnsweringPolicy)
    {session_id, attachment} = loop_session(fixture)

    assert {:accepted, "p1"} =
             Loopex.command(attachment, %{type: :prompt, command_id: "p1", content: "do it"})

    requested = await_event(fixture, session_id, "interaction.requested")
    answer(attachment, "answer-1", requested)
    _resolved = await_event(fixture, session_id, "interaction.resolved", 8_000)
    _finished = await_event(fixture, session_id, "tool.finished", 8_000)

    records = Fixture.records(fixture, session_id)
    events = Fixture.events(fixture, session_id)

    creation = find_record(records, "interaction_requested_v1")
    admission = Enum.find(records, &(&1.payload["command_type"] == "interaction_answer"))
    resolution = find_record(records, "interaction_resolved_v1")
    intent = find_record(records, "effect_intent_committed_v2")

    # The three cuts are journaled in order, and the effect intent is after all
    # of them: nothing was dispatched on the strength of a question, an answer,
    # or anything short of the committed resolution.
    assert creation.journal_version < admission.journal_version
    assert admission.journal_version < resolution.journal_version
    assert resolution.journal_version < intent.journal_version

    # Each published fact follows the record that made it true, and the tool
    # starts only after the last of them.
    request_event = Enum.find(events, &(&1.kind == "interaction.requested"))
    resolved_event = Enum.find(events, &(&1.kind == "interaction.resolved"))
    started_event = Enum.find(events, &(&1.kind == "tool.started"))

    assert request_event["interaction_id"] == creation.payload["interaction_id"]
    assert resolved_event["interaction_id"] == resolution.payload["interaction_id"]
    assert request_event.event_sequence < resolved_event.event_sequence
    assert resolved_event.event_sequence < started_event.event_sequence

    # The question was retained exactly once, and so was its ending.
    assert Enum.count(records, &(&1.payload.kind == "interaction_requested_v1")) == 1
    assert Enum.count(records, &(&1.payload.kind == "interaction_resolved_v1")) == 1
  end

  test "policy request interaction request and answer digests and their retained preimages survive commit unknown and restart under the same policy identity and revision" do
    fixture = loop_fixture(AnsweringPolicy)
    {session_id, attachment} = loop_session(fixture)

    # The creation transaction is held, and the Store is told to linearize it
    # and then report an unknown outcome. The owner must resolve that same
    # transaction rather than composing a second question with a later clock.
    :ok =
      Loopex.M1RuntimeTestStore.hold_next_record_before_linearization(
        fixture.store,
        "interaction_requested_v1",
        self()
      )

    assert {:accepted, "p1"} =
             Loopex.command(attachment, %{type: :prompt, command_id: "p1", content: "do it"})

    assert_receive {:record_held_before_linearization, waiter, _store, _kind, transaction}, 8_000
    [proposed] = Enum.filter(transaction.records, &(&1.kind == "interaction_requested_v1"))

    :ok =
      Loopex.M1RuntimeTestStore.inject(
        fixture.store,
        {:session_journal_commit, :after_linearization_before_result}
      )

    send(waiter, :release)

    requested = await_event(fixture, session_id, "interaction.requested", 8_000)

    records = Fixture.records(fixture, session_id)
    retained = Enum.filter(records, &(&1.payload.kind == "interaction_requested_v1"))
    assert length(retained) == 1
    retained = hd(retained).payload

    # The resolved commit is the one that was proposed, byte for byte in every
    # field the question is judged by: its identity, the instants, the three
    # digests, and the policy binding that asked it.
    assert retained["interaction_id"] == proposed["interaction_id"]
    assert retained["created_at"] == proposed["created_at"]
    assert retained["expires_at"] == proposed["expires_at"]
    assert retained["interaction_request_digest"] == proposed["interaction_request_digest"]
    assert retained["policy_request_digest"] == proposed["policy_request_digest"]
    assert retained["policy_identity"] == proposed["policy_identity"]
    assert requested["interaction_id"] == proposed["interaction_id"]

    # The same preimages come back after owner succession, and the answer's own
    # digest is the one the admission committed.
    assert {:ok, ^session_id} =
             Loopex.resume_session(fixture.runtime, session_id, command_id: "successor")

    # The successor owns the session now, so the answer comes through an
    # attachment to it rather than the superseded one.
    {:ok, successor_attachment} =
      Loopex.attach(fixture.runtime, session_id, after_event_sequence: 0)

    answer(successor_attachment, "answer-1", requested)
    resolved = await_event(fixture, session_id, "interaction.resolved", 8_000)
    assert resolved["choice_id"] == "allow"

    admission =
      fixture
      |> Fixture.records(session_id)
      |> Enum.find(&(&1.payload["command_type"] == "interaction_answer"))

    assert admission.payload["answer_digest"] ==
             Loopex.Interaction.digest(%{choice_id: "allow"})

    assert admission.payload["interaction_id"] == proposed["interaction_id"]

    after_restart =
      fixture
      |> Fixture.records(session_id)
      |> Enum.find(&(&1.payload.kind == "interaction_requested_v1"))

    assert after_restart.payload == retained
  end

  defp find_record(records, kind) do
    case Enum.find(records, &(&1.payload.kind == kind)) do
      nil -> flunk("no #{kind} record was journaled")
      record -> record
    end
  end

  defmodule MisbehavingPolicy do
    @moduledoc false
    @behaviour Loopex.Policy

    @impl Loopex.Policy
    def decide(request) do
      case Map.get(request, :interaction_response) do
        nil ->
          {:defer,
           %{
             kind: :choice,
             prompt: "How should the host misbehave?",
             choices: [
               %{id: "malformed", label: "Return something that is not a decision"},
               %{id: "crash", label: "Raise"},
               %{id: "hang", label: "Never answer"}
             ],
             expires_in_ms: 60_000
           }}

        %{answer: %{choice_id: "malformed"}} ->
          {:perhaps, "not a decision"}

        %{answer: %{choice_id: "crash"}} ->
          raise "host policy failed while resuming"

        %{answer: %{choice_id: "hang"}} ->
          Process.sleep(60_000)
          {:allow, nil}
      end
    end
  end

  test "invalid answers malformed policy output and failed or timed out re-evaluation dispatch nothing and resolve as denial" do
    # An answer that names no offered choice never reaches the host at all.
    fixture = loop_fixture(MisbehavingPolicy)
    {session_id, attachment} = loop_session(fixture)

    assert {:accepted, "p1"} =
             Loopex.command(attachment, %{type: :prompt, command_id: "p1", content: "do it"})

    requested = await_event(fixture, session_id, "interaction.requested")

    assert {:error, :invalid_interaction_answer} =
             Loopex.command(attachment, %{
               type: :interaction_answer,
               command_id: "answer-invalid",
               interaction_id: requested["interaction_id"],
               choice_id: "invented"
             })

    assert {:ok, status} = Loopex.session_status(fixture.runtime, session_id)
    assert status.open_interaction["status"] == "pending"

    # A host that answers with something that is not a decision, one that
    # raises, and one that never answers all resolve the same way: the question
    # is denied and nothing is dispatched.
    misbehaviour_denies(fixture, session_id, attachment, requested, "malformed")

    for choice <- ["crash", "hang"] do
      other = loop_fixture(MisbehavingPolicy)
      {other_session, other_attachment} = loop_session(other)

      assert {:accepted, "p1"} =
               Loopex.command(other_attachment, %{
                 type: :prompt,
                 command_id: "p1",
                 content: "do it"
               })

      asked = await_event(other, other_session, "interaction.requested")
      misbehaviour_denies(other, other_session, other_attachment, asked, choice)
    end
  end

  defp misbehaviour_denies(fixture, session_id, attachment, requested, choice) do
    assert {:accepted, "answer-misbehaviour"} =
             Loopex.command(attachment, %{
               type: :interaction_answer,
               command_id: "answer-misbehaviour",
               interaction_id: requested["interaction_id"],
               choice_id: choice
             })

    resolved = await_event(fixture, session_id, "interaction.resolved", 12_000)
    assert resolved["resolution"] == "denied"
    assert resolved["reason"] == "policy_unavailable"

    tool_finished = await_event(fixture, session_id, "tool.finished", 12_000)
    assert tool_finished["outcome"] == "denied"
    assert tool_finished["reason"] == "policy_unavailable"

    records = Fixture.records(fixture, session_id)
    assert Enum.all?(records, &(&1.payload.kind != "effect_intent_committed_v2"))
    assert Enum.all?(Fixture.events(fixture, session_id), &(&1.kind != "tool.started"))
  end

  defmodule AlwaysDeferringPolicy do
    @moduledoc false
    @behaviour Loopex.Policy

    @impl Loopex.Policy
    def decide(_request) do
      {:defer,
       %{
         kind: :choice,
         prompt: "Ask again?",
         choices: [%{id: "allow", label: "Allow once"}],
         expires_in_ms: 60_000
       }}
    end
  end

  test "successive answer and defer rounds stop at the exact bound with a stable refusal" do
    fixture = loop_fixture(AlwaysDeferringPolicy)
    {session_id, attachment} = loop_session(fixture)

    assert {:accepted, "p1"} =
             Loopex.command(attachment, %{type: :prompt, command_id: "p1", content: "do it"})

    # Three questions is the whole allowance: the first, and two more after an
    # answer. Answering the third does not buy a fourth.
    first = await_nth_request(fixture, session_id, 1)
    answer(attachment, "answer-1", first)

    second = await_nth_request(fixture, session_id, 2)
    assert second["interaction_id"] != first["interaction_id"]
    answer(attachment, "answer-2", second)

    third = await_nth_request(fixture, session_id, 3)
    assert third["interaction_id"] != second["interaction_id"]
    answer(attachment, "answer-3", third)

    tool_finished = await_event(fixture, session_id, "tool.finished", 8_000)
    assert tool_finished["outcome"] == "denied"
    assert tool_finished["reason"] == "policy_denied"

    events = Fixture.events(fixture, session_id)
    assert Enum.count(events, &(&1.kind == "interaction.requested")) == 3
    assert Enum.all?(events, &(&1.kind != "tool.started"))

    # Concept: a replacement closes the answered round before the next question.
    # Technical depth: both facts derive from its one retained creation row;
    # every historical cursor must replay without consulting current state.
    for {old, replacement, command} <- [
          {first, second, "answer-1"},
          {second, third, "answer-2"}
        ] do
      admitted =
        Enum.find(events, fn event ->
          event.kind == "interaction.answer_admitted" and
            event["interaction_id"] == old["interaction_id"]
        end)

      [terminal] =
        Enum.filter(events, fn event ->
          event.kind == "interaction.cancelled" and
            event["interaction_id"] == old["interaction_id"]
        end)

      assert terminal["resolution"] == "cancelled"

      assert Map.drop(terminal, [:kind, :event_id, :event_sequence]) == %{
               "interaction_id" => old["interaction_id"],
               "run_id" => old["run_id"],
               "turn" => old["turn"],
               "tool_call_id" => old["tool_call_id"],
               "resolution" => "cancelled",
               "answer_command_id" => command,
               "choice_id" => "allow"
             }

      assert terminal["choice_id"] == "allow"
      assert terminal.event_sequence == admitted.event_sequence + 1
      assert replacement.event_sequence == terminal.event_sequence + 1

      for {cursor, expected} <- [
            {admitted.event_sequence, {"answered", old["interaction_id"]}},
            {terminal.event_sequence, nil},
            {replacement.event_sequence, {"pending", replacement["interaction_id"]}}
          ] do
        {:ok, historical} =
          Loopex.attach(fixture.runtime, session_id, after_event_sequence: cursor)

        snapshot = Loopex.snapshot(historical)
        assert snapshot.event_sequence == cursor

        case expected do
          nil ->
            assert snapshot.open_interaction == nil

          {status, identity} ->
            assert snapshot.open_interaction["status"] == status
            assert snapshot.open_interaction["interaction_id"] == identity

            if status == "answered" do
              assert snapshot.open_interaction["answer_command_id"] == command
            end
        end
      end
    end

    records = Fixture.records(fixture, session_id)
    assert {:ok, recovered} = Loopex.Runtime.SessionState.recover(session_id, records, events)
    assert recovered.interactions[first["interaction_id"]].status == "cancelled"
    assert recovered.interactions[second["interaction_id"]].status == "cancelled"

    configuration =
      Loopex.Runtime.SessionConfiguration.public_view(
        hd(records).payload["initial_configuration"]
      )

    for cursor <- 0..length(events) do
      assert {:ok, expected} =
               Loopex.Runtime.SessionState.snapshot(session_id, cursor, events, configuration)

      assert {:ok, historical} =
               Loopex.attach(fixture.runtime, session_id, after_event_sequence: cursor)

      assert Loopex.snapshot(historical).open_interaction == expected.open_interaction
    end

    assert Loopex.AgentLoopTestExecutor.jobs(fixture.executor) == []
  end

  test "a reused raw tool call starts a fresh policy decision in a later run or turn" do
    call = %{text: "working", calls: [%{id: "c1", name: "write", arguments: %{"path" => "c1"}}]}
    done = %{text: "done", calls: []}

    for scope <- [:run, :turn] do
      script = if scope == :run, do: [call, done, call, done], else: [call, call, done]
      fixture = Fixture.start(script: script, policy: DeferringPolicy)
      on_exit(fn -> Fixture.stop(fixture) end)
      {session_id, attachment} = loop_session(fixture)

      assert {:accepted, "p1"} =
               Loopex.command(attachment, %{type: :prompt, command_id: "p1", content: "first"})

      first = await_nth_request(fixture, session_id, 1)

      assert {:accepted, "deny-first"} =
               Loopex.command(attachment, %{
                 type: :interaction_answer,
                 command_id: "deny-first",
                 interaction_id: first["interaction_id"],
                 choice_id: "deny"
               })

      if scope == :run do
        await_event(fixture, session_id, "run.finished", 8_000)

        assert {:accepted, "p2"} =
                 Loopex.command(attachment, %{type: :prompt, command_id: "p2", content: "second"})
      end

      second = await_nth_request(fixture, session_id, 2)
      assert second["tool_call_id"] == first["tool_call_id"]

      if scope == :run do
        assert second["run_id"] != first["run_id"]
      else
        assert second["run_id"] == first["run_id"]
        assert second["turn"] == first["turn"] + 1
      end

      assert second["interaction_id"] != first["interaction_id"]
      assert {:ok, status} = Loopex.session_status(fixture.runtime, session_id)
      assert status.open_interaction["interaction_id"] == second["interaction_id"]
      assert status.open_interaction["status"] == "pending"

      requested =
        Fixture.records(fixture, session_id)
        |> Enum.filter(&(&1.payload.kind == "interaction_requested_v1"))

      assert Enum.map(requested, & &1.payload["round"]) == [0, 0]
      assert Loopex.AgentLoopTestExecutor.jobs(fixture.executor) == []

      assert {:accepted, "abort-second"} =
               Loopex.command(attachment, %{type: :abort, command_id: "abort-second"})
    end
  end

  defmodule BlockingResumePolicy do
    @moduledoc false
    @behaviour Loopex.Policy

    @impl Loopex.Policy
    def decide(request) do
      case Map.get(request, :interaction_response) do
        nil ->
          {:defer,
           %{
             kind: :choice,
             prompt: "May the tool write the file?",
             choices: [%{id: "allow", label: "Allow once"}],
             expires_in_ms: 60_000
           }}

        %{answer: %{choice_id: "allow"}} ->
          hold()
          {:allow, nil}
      end
    end

    # The resumed evaluation waits where a slow host would, so a test can force
    # owner succession while the question is answered and unresolved.
    defp hold do
      case Process.whereis(:interaction_resume_observer) do
        nil ->
          :ok

        observer ->
          send(observer, {:resumed, self()})

          receive do
            :release -> :ok
          after
            5_000 -> :ok
          end
      end
    end
  end

  test "recovery resumes an answered but unresolved interaction without speculating acknowledging or dispatching first" do
    # The name dies with this process, so the policy above finds no observer in
    # any other case.
    Process.register(self(), :interaction_resume_observer)

    fixture = loop_fixture(BlockingResumePolicy)
    {session_id, attachment} = loop_session(fixture)

    assert {:accepted, "p1"} =
             Loopex.command(attachment, %{type: :prompt, command_id: "p1", content: "do it"})

    requested = await_event(fixture, session_id, "interaction.requested")

    assert {:accepted, "answer-1"} =
             Loopex.command(attachment, %{
               type: :interaction_answer,
               command_id: "answer-1",
               interaction_id: requested["interaction_id"],
               choice_id: "allow"
             })

    # The host is mid-decision when this owner is replaced.
    assert_receive {:resumed, first_evaluation}, 4_000
    first_monitor = Process.monitor(first_evaluation)

    assert {:ok, ^session_id} =
             Loopex.resume_session(fixture.runtime, session_id, command_id: "successor")

    # The successor finds the answer on disk and asks the host again rather than
    # assuming what the first evaluation would have said. Nothing was dispatched
    # in between.
    assert_receive {:DOWN, ^first_monitor, :process, ^first_evaluation, _}, 8_000
    assert_receive {:resumed, second_evaluation}, 8_000
    second_monitor = Process.monitor(second_evaluation)
    assert Enum.all?(Fixture.events(fixture, session_id), &(&1.kind != "tool.started"))
    send(second_evaluation, :release)
    assert_receive {:DOWN, ^second_monitor, :process, ^second_evaluation, _}, 8_000

    resolved = await_event(fixture, session_id, "interaction.resolved", 8_000)
    assert resolved["resolution"] == "allowed"
    assert resolved["turn"] == requested["turn"]
    assert resolved["run_id"] == requested["run_id"]
    assert resolved["tool_call_id"] == requested["tool_call_id"]
    assert resolved["answer_command_id"] == "answer-1"
    assert resolved["choice_id"] == "allow"

    tool_finished = await_event(fixture, session_id, "tool.finished", 8_000)
    assert tool_finished["outcome"] == "completed"

    events = Fixture.events(fixture, session_id)
    assert Enum.count(events, &(&1.kind == "interaction.resolved")) == 1
    assert Enum.count(events, &(&1.kind == "interaction.requested")) == 1
    assert Enum.count(events, &(&1.kind == "interaction.answer_admitted")) == 1
    answer_event = Enum.find(events, &(&1.kind == "interaction.answer_admitted"))
    assert answer_event["answer_command_id"] == "answer-1"
    assert answer_event["answer_choice_id"] == "allow"

    started = Enum.find(events, &(&1.kind == "tool.started"))
    resolution = Enum.find(events, &(&1.kind == "interaction.resolved"))
    assert started.event_sequence > resolution.event_sequence
    records = Fixture.records(fixture, session_id)
    assert {:ok, _} = Loopex.Runtime.SessionState.recover(session_id, records, events)
  end

  test "expiry abort deadline and restart races resolve by journal order and recovery resumes only retained pending state" do
    # The deadline is the race this case owns; expiry, abort and restart each
    # have their own beside it.
    fixture =
      Fixture.start(
        script: [
          %{text: "working", calls: [%{id: "c1", name: "write", arguments: %{"path" => "c1"}}]},
          %{text: "done", calls: []}
        ],
        policy: AnsweringPolicy,
        bounds_deadline_ms: 900
      )

    on_exit(fn -> Fixture.stop(fixture) end)
    {session_id, attachment} = loop_session(fixture)

    assert {:accepted, "p1"} =
             Loopex.command(attachment, %{type: :prompt, command_id: "p1", content: "do it"})

    requested = await_event(fixture, session_id, "interaction.requested")

    # The question's effective expiry is capped at the run's deadline, so the
    # two timers race by design. Which one wins is the journal's to decide; what
    # this case fixes is that exactly one of them does, and that the question
    # never outlives the run either way.
    assert requested["expires_at"] <= run_deadline(fixture, session_id)

    finished = await_event(fixture, session_id, "run.finished", 8_000)
    assert finished["outcome"] in ["bound_reached", "completed"]

    ending =
      Enum.find(Fixture.events(fixture, session_id), fn event ->
        event.kind in ["interaction.cancelled", "interaction.expired", "interaction.resolved"]
      end)

    assert ending["interaction_id"] == requested["interaction_id"]
    assert ending.event_sequence < finished.event_sequence or finished["outcome"] == "completed"

    # Exactly one ending for that question, and the session is answerable
    # again: nothing is left open against a run that is over.
    events = Fixture.events(fixture, session_id)

    assert Enum.count(
             events,
             &(&1.kind in ["interaction.cancelled", "interaction.expired", "interaction.resolved"])
           ) == 1

    assert {:ok, status} = Loopex.session_status(fixture.runtime, session_id)
    assert status.open_interaction == nil

    assert {:error, :interaction_resolved} =
             Loopex.command(attachment, %{
               type: :interaction_answer,
               command_id: "answer-late",
               interaction_id: requested["interaction_id"],
               choice_id: "allow"
             })
  end

  test "a session whose policy binding changed stays suspended and dispatches nothing" do
    Process.register(self(), :interaction_resume_observer)

    fixture = loop_fixture(BlockingResumePolicy)
    {session_id, attachment} = loop_session(fixture)

    assert {:accepted, "p1"} =
             Loopex.command(attachment, %{type: :prompt, command_id: "p1", content: "do it"})

    requested = await_event(fixture, session_id, "interaction.requested")

    assert {:accepted, "answer-1"} =
             Loopex.command(attachment, %{
               type: :interaction_answer,
               command_id: "answer-1",
               interaction_id: requested["interaction_id"],
               choice_id: "allow"
             })

    assert_receive {:resumed, _held}, 4_000

    # The session comes back under a policy that carries a different revision.
    # The answer on disk was given to the one that asked, so this runtime waits
    # rather than deciding under a binding it did not have.
    :ok = Loopex.stop(fixture.runtime)

    successor_fixture =
      Fixture.start(
        script: [%{text: "done", calls: []}],
        policy: BlockingResumePolicy,
        policy_identity: %{"id" => inspect(BlockingResumePolicy), "revision" => "2"},
        store: fixture.store
      )

    on_exit(fn -> Fixture.stop(successor_fixture) end)
    successor = successor_fixture.runtime

    assert {:ok, ^session_id} =
             Loopex.resume_session(successor, session_id, command_id: "successor")

    refute_receive {:resumed, _second}, 1_000

    assert {:ok, status} = Loopex.session_status(successor, session_id)
    assert status.open_interaction["interaction_id"] == requested["interaction_id"]
    assert status.open_interaction["status"] == "answered"
    assert status.open_interaction["producer"] == "policy_defer"
    assert status.open_interaction["kind"] == "choice"
    assert status.open_interaction["answer_command_id"] == "answer-1"
    assert status.open_interaction["answer_choice_id"] == "allow"
    assert map_size(status.open_interaction) == 12

    events = Fixture.events(fixture, session_id)
    assert Enum.count(events, &(&1.kind == "interaction.answer_admitted")) == 1
    answer_event = Enum.find(events, &(&1.kind == "interaction.answer_admitted"))

    {:ok, historical} =
      Loopex.attach(successor, session_id, after_event_sequence: answer_event.event_sequence)

    assert Loopex.snapshot(historical).open_interaction == status.open_interaction
    assert Enum.all?(events, &(&1.kind != "tool.started"))
    assert Enum.all?(events, &(&1.kind != "interaction.resolved"))
  end

  test "an abort cancels the open question and a later answer finds it resolved" do
    fixture = loop_fixture(AnsweringPolicy)
    {session_id, attachment} = loop_session(fixture)

    assert {:accepted, "p1"} =
             Loopex.command(attachment, %{type: :prompt, command_id: "p1", content: "do it"})

    requested = await_event(fixture, session_id, "interaction.requested")

    assert {:accepted, "abort-1"} =
             Loopex.command(attachment, %{type: :abort, command_id: "abort-1"})

    cancelled = await_event(fixture, session_id, "interaction.cancelled", 4_000)
    assert cancelled["interaction_id"] == requested["interaction_id"]
    assert cancelled["run_id"] == requested["run_id"]
    assert cancelled["turn"] == requested["turn"]
    assert cancelled["tool_call_id"] == requested["tool_call_id"]
    assert Map.has_key?(cancelled, "answer_command_id")
    assert cancelled["answer_command_id"] == nil
    refute Map.has_key?(cancelled, "choice_id")
    refute Map.has_key?(cancelled, "reason")

    assert {:error, :interaction_resolved} =
             Loopex.command(attachment, %{
               type: :interaction_answer,
               command_id: "answer-late",
               interaction_id: requested["interaction_id"],
               choice_id: "allow"
             })

    assert Enum.all?(Fixture.events(fixture, session_id), &(&1.kind != "tool.started"))
  end

  defmodule StopWitnessPolicy do
    @moduledoc false
    @behaviour Loopex.Policy

    @impl Loopex.Policy
    def decide(_request), do: {:deny, :policy_unavailable}

    @impl Loopex.Policy
    def decide(request, {observer, nonce}) do
      case Map.get(request, :interaction_response) do
        nil ->
          {:defer, Loopex.InteractionLifecycleTest.DeferringPolicy.question()}

        %{answer: %{choice_id: "allow"}} ->
          send(observer, {:interaction_stop_held, nonce, self()})

          receive do
            {:interaction_stop_monitor_installed, ^nonce, monitor} ->
              true = observer in elem(Process.info(self(), :monitored_by), 1)
              send(observer, {:interaction_stop_monitor_confirmed, nonce, self(), monitor})
          end

          # Concept: this callback never grants authority through a fixture timeout.
          # Technical depth: it remains in the real policy task until public stop;
          # the runtime's unchanged policy timeout still owns late evaluation.
          receive do
            {:interaction_stop_unexpected_release, ^nonce} ->
              exit(:interaction_stop_fixture_released)
          end
      end
    end
  end

  test "public runtime stop joins an answered interaction's held policy and attributes original shutdown reports" do
    observer = self()
    nonce = make_ref()
    fixture = loop_fixture(%{module: StopWitnessPolicy, context: {observer, nonce}})
    {session_id, attachment} = loop_session(fixture)

    assert {:accepted, "p1"} =
             Loopex.command(attachment, %{type: :prompt, command_id: "p1", content: "do it"})

    requested = await_event(fixture, session_id, "interaction.requested")
    answer(attachment, "stop-answer", requested)
    assert_receive {:interaction_stop_held, ^nonce, policy}, 4_000
    policy_monitor = Process.monitor(policy)
    send(policy, {:interaction_stop_monitor_installed, nonce, policy_monitor})

    assert_receive {:interaction_stop_monitor_confirmed, ^nonce, ^policy, ^policy_monitor}, 1_000
    assert {:ok, children} = Loopex.Runtime.children(fixture.runtime)
    control = :sys.get_state(children.control, 1_000)
    %{coordinator: coordinator, owner_group: group} = Map.fetch!(control.sessions, session_id)
    %{workers: private_workers, providers: providers} = :sys.get_state(group, 1_000)
    assert {:ok, ^private_workers} = Loopex.Runtime.OwnerGroup.workers(group)

    assert {:undefined, policy, :worker, [Task.Supervised]} in Supervisor.which_children(
             private_workers
           )

    # Completed model actors can remain in a retirement record, but none may
    # remain live during this distinctly policy-only stopping interval.
    for {_reference, provider} <- providers,
        pid <- provider.original_members,
        do: refute(Process.alive?(pid))

    tasks = Task.Supervisor.children(private_workers)
    assert policy in tasks

    actors =
      Map.new(children, fn {role, pid} -> {pid, Atom.to_string(role)} end)
      |> Map.merge(Map.new(tasks, &{&1, "private_task"}))
      |> Map.merge(%{
        fixture.runtime.supervisor => "runtime",
        coordinator => "coordinator",
        group => "owner_group",
        private_workers => "private_supervisor",
        policy => "policy"
      })

    monitors =
      Map.new(actors, fn {pid, role} ->
        reference = if pid == policy, do: policy_monitor, else: Process.monitor(pid)
        assert Process.alive?(pid)
        assert self() in elem(Process.info(pid, :monitored_by), 1)
        {reference, {pid, role}}
      end)

    records_before = Fixture.records(fixture, session_id)

    assert Enum.any?(
             records_before,
             &(&1.payload.kind == "policy_interaction_answer_admitted_v1")
           )

    refute Enum.any?(records_before, &(&1.payload.kind == "effect_intent_committed_v2"))
    assert Loopex.AgentLoopTestExecutor.jobs(fixture.executor) == []
    refute Enum.any?(Fixture.events(fixture, session_id), &(&1.kind == "tool.started"))
    interaction_stop_observe(fixture, session_id, actors, monitors, records_before, nonce)
  end

  # Concept: ordinary stop evidence names the actual pre-captured actor census.
  # Technical depth: the primary filter preserves the event and copies only
  # fixed supervisor metadata. One cutoff spans stop, original joins and trace
  # delivery; no Logger drain allowance or blanket quiet assertion is added.
  defp interaction_stop_observe(fixture, session_id, actors, monitors, records_before, nonce) do
    observer = self()
    {:ok, logger_started} = Application.ensure_all_started(:logger)

    try do
      filters = :logger.get_primary_config().filters
      filter = :loopex_interaction_stop_witness
      key = {__MODULE__, :interaction_stop_evidence, nonce}
      cutoff = System.monotonic_time(:millisecond) + 1_000

      Process.put(key, %{
        joins: [],
        reports: [],
        trace: [],
        result: nil,
        complete: false,
        collector_joined: false,
        actors: actors
      })

      try do
        {collector, collector_monitor} =
          spawn_monitor(fn -> interaction_stop_collect(observer, actors, [], %{}, nil, 0) end)

        try do
          Process.put(key, %{
            Process.get(key)
            | actors: Map.put(actors, collector, "trace_collector")
          })

          session = :trace.session_create(:loopex_interaction_stop_witness, collector, [])
          Process.put({key, :session}, session)

          enabled =
            Keyword.update!(filters, :logger_translator, fn {callback, configuration} ->
              {callback, %{configuration | sasl: true}}
            end)

          :ok = :logger.set_primary_config(:filters, enabled)

          :ok =
            :logger.add_primary_filter(filter, {&interaction_stop_report/2, {observer, actors}})

          Process.put({key, :filter_added}, true)
          pids = Map.keys(actors)

          receive_patterns =
            for pid <- pids,
                reason <- [:normal, :shutdown, :noproc, :killed, {:shutdown, :noproc}],
                shape <- [:exit, :down] do
              message =
                if shape == :exit,
                  do: {:EXIT, pid, reason},
                  else: {:DOWN, :_, :process, pid, reason}

              {[:_, :_, message], [], []}
            end

          :trace.recv(session, receive_patterns, [])

          for {mfa, arguments} <- [
                {{:erlang, :monitor, 2}, fn pid -> [:process, pid] end},
                {{DynamicSupervisor, :monitor_child, 1}, fn pid -> [pid] end}
              ] do
            assert :trace.function(
                     session,
                     mfa,
                     for(
                       pid <- pids,
                       do: {arguments.(pid), [], [{:message, {:const, pid}}, {:return_trace}]}
                     ),
                     if(elem(mfa, 0) == DynamicSupervisor, do: [:local], else: [])
                   ) > 0
          end

          assert :trace.function(
                   session,
                   {:erlang, :exit, 2},
                   for(
                     pid <- pids,
                     reason <- [:normal, :shutdown, :kill],
                     do: {[pid, reason], [], [{:message, {:const, {pid, reason}}}]}
                   ),
                   []
                 ) > 0

          for pid <- pids do
            assert :trace.process(session, pid, true, [
                     :call,
                     :arity,
                     :procs,
                     :receive,
                     :monotonic_timestamp
                   ]) == 1
          end

          {stopper, stopper_monitor} =
            spawn_monitor(fn ->
              receive do
                {:interaction_stop_begin, ^nonce} ->
                  result = Loopex.stop(fixture.runtime)
                  send(observer, {:interaction_stop_returned, nonce, self(), result})
              end
            end)

          Process.put({key, :stopper}, {stopper, stopper_monitor})

          Process.put(key, %{
            Process.get(key)
            | actors: Map.put(Process.get(key).actors, stopper, "stop_caller")
          })

          send(stopper, {:interaction_stop_begin, nonce})

          interaction_stop_join(
            Map.put(monitors, stopper_monitor, {stopper, "stop_caller"}),
            collector,
            collector_monitor,
            session,
            nonce,
            cutoff,
            key,
            false
          )

          evidence = Process.get(key)
          interaction_stop_retain(evidence, cutoff)
          assert evidence.result == :ok
          assert evidence.complete
          assert System.monotonic_time(:millisecond) <= cutoff
          assert Fixture.records(fixture, session_id) == records_before
          assert Loopex.AgentLoopTestExecutor.jobs(fixture.executor) == []

          for row <- evidence.joins do
            assert row["reason"] in ["normal", "shutdown"]
          end

          for report <- evidence.reports do
            assert report["logger_producer"] == report["supervisor"]
            assert Enum.any?(evidence.joins, &(&1["pid"] == report["supervisor"]))
            original = Enum.find(evidence.joins, &(&1["pid"] == report["pid"]))
            assert original != nil

            exited =
              Enum.find(
                evidence.trace,
                &(&1["event"] == "actor_exit" and &1["pid"] == report["pid"])
              )

            assert exited != nil and exited["reason"] == original["reason"]

            if report["reason"] == "noproc" do
              installed =
                Enum.find(
                  evidence.trace,
                  &(&1["event"] == "monitor_installed" and
                      &1["pid"] == report["pid"] and &1["actor"] == report["supervisor"])
                )

              assert installed != nil and exited["at_ns"] <= installed["at_ns"]

              assert Enum.any?(
                       evidence.trace,
                       &(&1["event"] == "supervisor_down" and
                           &1["actor"] == report["supervisor"] and &1["pid"] == report["pid"] and
                           &1["monitor"] == installed["monitor"] and &1["reason"] == "noproc")
                     )
            else
              assert report["reason"] == original["reason"]
            end
          end
        after
          interaction_stop_cleanup([
            fn -> interaction_stop_retain(Process.get(key), cutoff) end,
            fn ->
              case Process.get({key, :session}) do
                nil -> :ok
                session -> :trace.session_destroy(session)
              end
            end,
            fn ->
              if Process.get({key, :filter_added}), do: :logger.remove_primary_filter(filter)
            end,
            fn -> :ok = :logger.set_primary_config(:filters, filters) end,
            fn ->
              unless Process.get(key).collector_joined do
                if Process.alive?(collector), do: Process.exit(collector, :kill)

                assert_receive {:DOWN, ^collector_monitor, :process, ^collector, _},
                               interaction_stop_left(cutoff)
              end
            end,
            fn ->
              case Process.get({key, :stopper}) do
                {stopper, monitor} ->
                  joined =
                    Enum.any?(Process.get(key).joins, fn row ->
                      row["pid"] == interaction_stop_identity(stopper) and
                        row["monitor"] == interaction_stop_identity(monitor)
                    end)

                  unless joined do
                    if Process.alive?(stopper), do: Process.exit(stopper, :kill)

                    assert_receive {:DOWN, ^monitor, :process, ^stopper, _},
                                   interaction_stop_left(cutoff)
                  end

                nil ->
                  :ok
              end
            end
          ])
        end
      after
        Process.delete({key, :session})
        Process.delete({key, :filter_added})
        Process.delete({key, :stopper})
        Process.delete(key)
      end
    after
      interaction_stop_cleanup(
        Enum.map(Enum.reverse(logger_started), fn application ->
          fn -> Application.stop(application) end
        end)
      )
    end
  end

  # Concept: evidence-write failures cannot leave this witness's actors running.
  # Technical depth: attempt every cleanup action, then re-raise the first failure
  # with its original kind, reason and stack. Outer after clauses independently
  # own process keys and the Logger applications started by this witness.
  defp interaction_stop_cleanup(actions) do
    failure =
      Enum.reduce(actions, nil, fn action, first_failure ->
        try do
          action.()
          first_failure
        catch
          kind, reason -> first_failure || {kind, reason, __STACKTRACE__}
        end
      end)

    case failure do
      nil -> :ok
      {kind, reason, stacktrace} -> :erlang.raise(kind, reason, stacktrace)
    end
  end

  defp interaction_stop_join(
         monitors,
         collector,
         collector_monitor,
         session,
         nonce,
         cutoff,
         key,
         finishing
       ) do
    finishing =
      if map_size(monitors) == 0 and not finishing do
        send(collector, {:interaction_stop_finish, self(), session})
        true
      else
        finishing
      end

    receive do
      {:DOWN, reference, :process, pid, reason} when is_map_key(monitors, reference) ->
        {^pid, role} = Map.fetch!(monitors, reference)

        row = %{
          "pid" => interaction_stop_identity(pid),
          "role" => role,
          "monitor" => interaction_stop_identity(reference),
          "reason" => interaction_stop_reason(reason)
        }

        interaction_stop_update(key, :joins, row)

        interaction_stop_join(
          Map.delete(monitors, reference),
          collector,
          collector_monitor,
          session,
          nonce,
          cutoff,
          key,
          finishing
        )

      {:interaction_stop_returned, ^nonce, _stopper, result} ->
        Process.put(key, %{Process.get(key) | result: result})

        interaction_stop_join(
          monitors,
          collector,
          collector_monitor,
          session,
          nonce,
          cutoff,
          key,
          finishing
        )

      {:interaction_stop_trace_row, ^collector, row} ->
        interaction_stop_update(key, :trace, row)

        interaction_stop_join(
          monitors,
          collector,
          collector_monitor,
          session,
          nonce,
          cutoff,
          key,
          finishing
        )

      {:interaction_stop_supervisor_report, row} ->
        interaction_stop_update(key, :reports, row)

        interaction_stop_join(
          monitors,
          collector,
          collector_monitor,
          session,
          nonce,
          cutoff,
          key,
          finishing
        )

      {:interaction_stop_trace_complete, ^collector, records} when finishing ->
        assert Process.get(key).trace == records

        assert_receive {:DOWN, ^collector_monitor, :process, ^collector, :normal},
                       interaction_stop_left(cutoff)

        row = %{
          "pid" => interaction_stop_identity(collector),
          "role" => "trace_collector",
          "monitor" => interaction_stop_identity(collector_monitor),
          "reason" => "normal"
        }

        interaction_stop_update(key, :joins, row)
        Process.put(key, %{Process.get(key) | complete: true, collector_joined: true})

      {:DOWN, ^collector_monitor, :process, ^collector, reason} ->
        Process.put(key, %{Process.get(key) | collector_joined: true})
        flunk("interaction stop collector failed: " <> interaction_stop_reason(reason))
    after
      interaction_stop_left(cutoff) ->
        flunk("interaction stop original actors or trace did not join")
    end
  end

  defp interaction_stop_update(key, field, row) do
    evidence = Process.get(key)
    Process.put(key, Map.update!(evidence, field, &(&1 ++ [row])))
  end

  # Concept: fixed trace metadata attributes a report without capturing policy data.
  # Technical depth: only pre-captured pids, monitors, fixed exit reasons and
  # monotonic timestamps are retained. Other process metadata is discarded and
  # still counts toward the same finite collector cap.
  defp interaction_stop_collect(observer, actors, records, targets, fence, count)
       when count < 2_048 do
    receive do
      {:trace_ts, actor, :call, {:erlang, :exit, 2}, {child, reason}, at}
      when is_map_key(actors, actor) and is_map_key(actors, child) and
             reason in [:normal, :shutdown, :kill] ->
        row = %{
          "event" => "exit_signal_sent",
          "actor" => interaction_stop_identity(actor),
          "pid" => interaction_stop_identity(child),
          "reason" => Atom.to_string(reason),
          "at_ns" => interaction_stop_time(at)
        }

        send(observer, {:interaction_stop_trace_row, self(), row})
        interaction_stop_collect(observer, actors, records ++ [row], targets, fence, count + 1)

      {:trace_ts, actor, :call, {_module, _function, _arity} = mfa, child, at}
      when is_map_key(actors, actor) and is_map_key(actors, child) ->
        row = %{
          "event" => "monitor_call",
          "actor" => interaction_stop_identity(actor),
          "pid" => interaction_stop_identity(child),
          "at_ns" => interaction_stop_time(at)
        }

        send(observer, {:interaction_stop_trace_row, self(), row})

        interaction_stop_collect(
          observer,
          actors,
          records ++ [row],
          Map.put(targets, {actor, mfa}, child),
          fence,
          count + 1
        )

      {:trace_ts, actor, :return_from, {:erlang, :monitor, 2} = mfa, reference, at}
      when is_map_key(actors, actor) and is_reference(reference) ->
        row = %{
          "event" => "monitor_installed",
          "actor" => interaction_stop_identity(actor),
          "pid" => interaction_stop_identity(Map.fetch!(targets, {actor, mfa})),
          "monitor" => interaction_stop_identity(reference),
          "at_ns" => interaction_stop_time(at)
        }

        send(observer, {:interaction_stop_trace_row, self(), row})
        interaction_stop_collect(observer, actors, records ++ [row], targets, fence, count + 1)

      {:trace_ts, actor, :receive, {:DOWN, monitor, :process, child, reason}, at}
      when is_map_key(actors, actor) and is_map_key(actors, child) ->
        row = %{
          "event" => "supervisor_down",
          "actor" => interaction_stop_identity(actor),
          "pid" => interaction_stop_identity(child),
          "monitor" => interaction_stop_identity(monitor),
          "reason" => interaction_stop_reason(reason),
          "at_ns" => interaction_stop_time(at)
        }

        send(observer, {:interaction_stop_trace_row, self(), row})
        interaction_stop_collect(observer, actors, records ++ [row], targets, fence, count + 1)

      {:trace_ts, actor, :receive, {:EXIT, child, reason}, at}
      when is_map_key(actors, actor) and is_map_key(actors, child) ->
        row = %{
          "event" => "supervisor_exit",
          "actor" => interaction_stop_identity(actor),
          "pid" => interaction_stop_identity(child),
          "reason" => interaction_stop_reason(reason),
          "at_ns" => interaction_stop_time(at)
        }

        send(observer, {:interaction_stop_trace_row, self(), row})
        interaction_stop_collect(observer, actors, records ++ [row], targets, fence, count + 1)

      {:trace_ts, pid, :exit, reason, at} when is_map_key(actors, pid) ->
        row = %{
          "event" => "actor_exit",
          "pid" => interaction_stop_identity(pid),
          "reason" => interaction_stop_reason(reason),
          "at_ns" => interaction_stop_time(at)
        }

        send(observer, {:interaction_stop_trace_row, self(), row})
        interaction_stop_collect(observer, actors, records ++ [row], targets, fence, count + 1)

      {:interaction_stop_finish, ^observer, session} when fence == nil ->
        interaction_stop_collect(
          observer,
          actors,
          records,
          targets,
          :trace.delivered(session, :all),
          count
        )

      {:trace_delivered, :all, reference} when reference == fence ->
        send(observer, {:interaction_stop_trace_complete, self(), records})

      _other ->
        interaction_stop_collect(observer, actors, records, targets, fence, count + 1)
    end
  end

  defp interaction_stop_collect(_observer, _actors, _records, _targets, _fence, _count),
    do: exit(:interaction_stop_trace_limit)

  defp interaction_stop_report(%{msg: {:report, %{report: report}}} = event, {observer, actors})
       when is_list(report) do
    offender = Keyword.get(report, :offender, [])

    supervisor =
      case Keyword.get(report, :supervisor) do
        {pid, _} when is_pid(pid) -> pid
        pid when is_pid(pid) -> pid
        _ -> nil
      end

    context = Keyword.get(report, :errorContext)

    if is_map_key(actors, supervisor) and is_list(offender) and
         context in [:shutdown_error, :child_terminated] do
      pid = Keyword.get(offender, :pid)

      if is_pid(pid) do
        row = %{
          "logger_producer" => interaction_stop_identity(self()),
          "supervisor" => interaction_stop_identity(supervisor),
          "pid" => interaction_stop_identity(pid),
          "context" => Atom.to_string(context),
          "reason" => interaction_stop_reason(Keyword.get(report, :reason)),
          "shutdown" => interaction_stop_shutdown(Keyword.get(offender, :shutdown))
        }

        send(observer, {:interaction_stop_supervisor_report, row})
      end
    end

    event
  end

  defp interaction_stop_report(event, _configuration), do: event
  defp interaction_stop_left(nil), do: 0
  defp interaction_stop_left(cutoff), do: max(cutoff - System.monotonic_time(:millisecond), 0)
  defp interaction_stop_time(at), do: System.convert_time_unit(at, :native, :nanosecond)

  defp interaction_stop_identity(pid) when is_pid(pid),
    do: List.to_string(:erlang.pid_to_list(pid))

  defp interaction_stop_identity(ref) when is_reference(ref),
    do: List.to_string(:erlang.ref_to_list(ref))

  defp interaction_stop_reason({:shutdown, :noproc}), do: "shutdown:noproc"

  defp interaction_stop_reason(reason) when reason in [:normal, :shutdown, :noproc, :killed],
    do: Atom.to_string(reason)

  defp interaction_stop_reason(_reason), do: "other"
  defp interaction_stop_shutdown(:brutal_kill), do: "brutal_kill"

  defp interaction_stop_shutdown(shutdown) when is_integer(shutdown) and shutdown >= 0,
    do: shutdown

  defp interaction_stop_shutdown(_shutdown), do: "other"

  defp interaction_stop_retain(evidence, cutoff) do
    case System.get_env("LOOPEX_PRIVATE_TASK_SHUTDOWN_EVIDENCE_DIR") do
      nil ->
        :ok

      directory ->
        expanded = Path.expand(directory)
        assert String.starts_with?(expanded, Path.expand(System.tmp_dir!()) <> "/")

        data = %{
          "scope" => "Ordinary public stop of held answered policy; exact actor evidence only",
          "complete_original_joins_and_trace" => evidence.complete,
          "stop_result" => if(evidence.result == :ok, do: "ok", else: "unproved"),
          "observation_cutoff_monotonic_ms" => cutoff,
          "actors" =>
            Map.new(evidence.actors, fn {pid, role} -> {interaction_stop_identity(pid), role} end),
          "original_downs" => evidence.joins,
          "supervisor_reports" => evidence.reports,
          "trace" => evidence.trace
        }

        File.write!(Path.join(expanded, "interaction-public-stop.json"), JSON.encode!(data))
    end
  end

  defp loop_fixture(policy) do
    fixture =
      Fixture.start(
        script: [
          %{text: "working", calls: [%{id: "c1", name: "write", arguments: %{"path" => "c1"}}]},
          %{text: "done", calls: []}
        ],
        policy: policy
      )

    on_exit(fn -> Fixture.stop(fixture) end)
    fixture
  end

  defp loop_session(fixture) do
    {:ok, session_id} = Loopex.create_session(fixture.runtime, %{}, command_id: "cs")
    {:ok, attachment} = Loopex.attach(fixture.runtime, session_id, after_event_sequence: 0)
    {session_id, attachment}
  end

  # The instant the run committed as its deadline, read from the request the run
  # staged rather than recomputed from a clock here.
  defp run_deadline(fixture, session_id) do
    fixture
    |> Fixture.records(session_id)
    |> Enum.filter(&(&1.payload.kind == "model_request_committed_v2"))
    |> List.last()
    |> then(& &1.payload["request"]["deadline"])
  end

  defp answer(attachment, command_id, requested) do
    assert {:accepted, ^command_id} =
             Loopex.command(attachment, %{
               type: :interaction_answer,
               command_id: command_id,
               interaction_id: requested["interaction_id"],
               choice_id: "allow"
             })
  end

  defp await_nth_request(fixture, session_id, position, deadline \\ 8_000) do
    requests =
      fixture
      |> Fixture.events(session_id)
      |> Enum.filter(&(&1.kind == "interaction.requested"))

    cond do
      length(requests) >= position -> Enum.at(requests, position - 1)
      deadline <= 0 -> flunk("question #{position} never arrived")
      true -> Process.sleep(20) && await_nth_request(fixture, session_id, position, deadline - 20)
    end
  end

  defp await_event(fixture, session_id, kind, deadline \\ 2_000) do
    found =
      fixture
      |> Fixture.events(session_id)
      |> Enum.find(&(&1.kind == kind))

    cond do
      found -> found
      deadline <= 0 -> flunk("no #{kind} event arrived")
      true -> Process.sleep(20) && await_event(fixture, session_id, kind, deadline - 20)
    end
  end

  defp policy_request do
    %{
      session_id: "session-1",
      run_id: "run-1",
      tool_call_id: "call-1",
      tool_id: "loopex.demo.write@1.0.0",
      arguments: %{"path" => "workspace/file.txt"}
    }
  end
end
