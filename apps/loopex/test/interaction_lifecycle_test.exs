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

  # The M3 closure candidate: the last revision whose reducer knew nothing of
  # interaction records, and so the reader an operator could still be running.
  @old_reader_revision "72c0a3091a8ec08cf04ac08e29d60f9ac6e4ce26"

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
    assert Enum.all?(records, &(&1.payload.kind != "effect_intent_committed"))
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
    intents = Enum.filter(records, &(&1.payload.kind == "effect_intent_committed"))
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
    intent = find_record(records, "effect_intent_committed")

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

  @tag timeout: 300_000
  test "old readers refuse interaction records before effects beside an old format positive control" do
    fixture = loop_fixture(AnsweringPolicy)
    {session_id, attachment} = loop_session(fixture)

    assert {:accepted, "p1"} =
             Loopex.command(attachment, %{type: :prompt, command_id: "p1", content: "do it"})

    requested = await_event(fixture, session_id, "interaction.requested")
    records = Fixture.records(fixture, session_id)
    events = Fixture.events(fixture, session_id)
    assert Enum.any?(records, &(&1.payload.kind == "interaction_requested_v1"))
    assert requested["interaction_id"]

    reader = build_old_reader()

    # The positive control: history this reader's own version could have
    # written replays, so a refusal below is about the new record rather than
    # about the reader being unable to read anything.
    old_format = Enum.reject(records, &(&1.payload.kind == "interaction_requested_v1"))
    old_events = Enum.reject(events, &String.starts_with?(&1.kind, "interaction."))

    assert replay(reader, session_id, old_format, old_events) =~ "ok"

    # The new record is refused as private history this reader cannot read, and
    # it is refused before any effect: nothing in that history dispatched.
    refusal = replay(reader, session_id, records, old_events)
    assert refusal =~ "error"
    assert refusal =~ "invalid_private_history"
    assert Enum.all?(records, &(&1.payload.kind != "effect_intent_committed"))
  end

  # Concept: a reader built from the milestone before interactions existed.
  #
  # Technical depth: the source is the M3 closure candidate, which is the last
  # revision whose reducer knew nothing of these records, and it is compiled
  # here rather than mocked, so what refuses is the real older reducer. Core
  # carries no external dependency, which is why this can be built offline.
  defp build_old_reader do
    root =
      Path.join(System.tmp_dir!(), "loopex-old-reader-#{:erlang.unique_integer([:positive])}")

    repository = repository_root()

    {_output, 0} = System.cmd("git", ["clone", "--quiet", "--no-hardlinks", repository, root])
    {_output, 0} = System.cmd("git", ["-C", root, "checkout", "--quiet", @old_reader_revision])

    # The environment is named rather than inherited. A runner that exports
    # `MIX_ENV=test` would otherwise build this reader into `_build/test` while
    # the replay below loads `_build/dev`, and the child would fail for a reason
    # that has nothing to do with what the reader can read.
    {output, status} =
      System.cmd("mix", ["compile"],
        cd: Path.join([root, "apps", "loopex"]),
        stderr_to_stdout: true,
        env: [{"MIX_ENV", "dev"}]
      )

    assert status == 0, "the old reader did not build: #{output}"

    on_exit(fn -> File.rm_rf(root) end)
    root
  end

  defp repository_root do
    {root, 0} = System.cmd("git", ["rev-parse", "--show-toplevel"])
    String.trim(root)
  end

  # Runs the old reader's own `recover/3` over a supplied history and reports
  # what it made of it, in its own VM against its own beams.
  defp replay(reader, session_id, records, events) do
    input = Path.join(reader, "history.bin")
    File.write!(input, :erlang.term_to_binary({session_id, records, events}))

    script = Path.join(reader, "replay.exs")

    File.write!(script, """
    {session_id, records, events} = :erlang.binary_to_term(File.read!(#{inspect(input)}))

    case Loopex.Runtime.SessionState.recover(session_id, records, events) do
      {:ok, _state} -> IO.puts("ok")
      {:error, reason} -> IO.puts("error " <> inspect(reason))
    end
    """)

    {output, 0} =
      System.cmd(
        "elixir",
        [
          "-pa",
          Path.join([reader, "_build", "dev", "lib", "loopex", "ebin"]),
          "-pa",
          Path.join([reader, "_build", "dev", "lib", "loopex_protocol", "ebin"]),
          script
        ],
        stderr_to_stdout: true
      )

    output
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
    assert Enum.all?(records, &(&1.payload.kind != "effect_intent_committed"))
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
    assert_receive {:resumed, _first_evaluation}, 4_000

    assert {:ok, ^session_id} =
             Loopex.resume_session(fixture.runtime, session_id, command_id: "successor")

    # The successor finds the answer on disk and asks the host again rather than
    # assuming what the first evaluation would have said. Nothing was dispatched
    # in between.
    assert_receive {:resumed, second_evaluation}, 8_000
    assert Enum.all?(Fixture.events(fixture, session_id), &(&1.kind != "tool.started"))
    send(second_evaluation, :release)

    resolved = await_event(fixture, session_id, "interaction.resolved", 8_000)
    assert resolved["resolution"] == "allowed"

    tool_finished = await_event(fixture, session_id, "tool.finished", 8_000)
    assert tool_finished["outcome"] == "completed"

    events = Fixture.events(fixture, session_id)
    assert Enum.count(events, &(&1.kind == "interaction.resolved")) == 1
    assert Enum.count(events, &(&1.kind == "interaction.requested")) == 1

    started = Enum.find(events, &(&1.kind == "tool.started"))
    resolution = Enum.find(events, &(&1.kind == "interaction.resolved"))
    assert started.event_sequence > resolution.event_sequence
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

    events = Fixture.events(fixture, session_id)
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

  # The instant the run committed as its deadline, read from the request the run
  # staged rather than recomputed from a clock here.
  defp run_deadline(fixture, session_id) do
    fixture
    |> Fixture.records(session_id)
    |> Enum.filter(&(&1.payload.kind == "model_request_committed"))
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
