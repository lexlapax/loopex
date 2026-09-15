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

  test "a deferred question suspends the run, publishes its request and dispatches nothing" do
    fixture = loop_fixture(SuspendingPolicy)
    {session_id, attachment} = loop_session(fixture)

    assert {:accepted, "p1"} =
             Loopex.command(attachment, %{type: :prompt, command_id: "p1", content: "do it"})

    requested = await_event(fixture, session_id, "interaction.requested")
    assert requested["prompt"] == "May the tool write the file?"
    assert Enum.map(requested["choices"], & &1["id"]) == ["allow", "deny"]
    assert is_integer(requested["expires_at"])

    events = Fixture.events(fixture, session_id)
    assert Enum.all?(events, &(&1.kind != "tool.started"))
    assert Enum.all?(events, &(&1.kind != "run.finished"))

    # The question stands: the run is suspended rather than finished, and the
    # executor was never asked to do anything.
    assert {:ok, %{active_run_id: run_id}} = Loopex.session_status(fixture.runtime, session_id)
    assert is_binary(run_id)

    # Nobody answers, so the question expires and the call it suspended is
    # denied rather than left standing.
    expired = await_event(fixture, session_id, "interaction.expired", 4_000)
    assert expired["interaction_id"] == requested["interaction_id"]
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

  test "a committed answer re-enters host policy and an allow dispatches the call" do
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

  test "an answer to a question that is absent wrong or already resolved refuses with its own reason" do
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

    assert {:error, :interaction_resolved} =
             Loopex.command(attachment, %{
               type: :interaction_answer,
               command_id: "answer-late",
               interaction_id: requested["interaction_id"],
               choice_id: "allow"
             })

    assert Enum.all?(Fixture.events(fixture, session_id), &(&1.kind != "tool.started"))
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
