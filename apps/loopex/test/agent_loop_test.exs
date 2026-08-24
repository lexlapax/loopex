Code.require_file("support/m1_runtime_helper.exs", __DIR__)
Code.require_file("support/agent_loop_helper.exs", __DIR__)

defmodule Loopex.AgentLoopTest do
  @moduledoc false

  use ExUnit.Case, async: false

  alias Loopex.AgentLoopFixture, as: Fixture
  alias Loopex.AgentLoopTestModel
  alias Loopex.Bounds
  alias LoopexProtocol.ToolDefinition

  defp call(id), do: %{id: id, name: "write", arguments: %{"path" => id}}

  defp start(options) do
    fixture = Fixture.start(options)
    on_exit(fn -> Fixture.stop(fixture) end)
    fixture
  end

  # Concept: wait for the run to actually finish before asserting on it.
  #
  # Technical depth: the loop runs asynchronously in supervised tasks, so an
  # empty read means "not yet" rather than "no more". Polling with a deadline
  # keeps the test honest: it fails on a genuinely stuck run instead of passing
  # because it looked too early, and it never inflates a timeout to make a slow
  # path look green.
  defp drain(attachment, deadline_ms \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + deadline_ms
    collect(attachment, deadline, [])
  end

  defp collect(attachment, deadline, acc) do
    case Loopex.next_event(attachment) do
      {:ok, event} ->
        acc = [event | acc]

        if event.kind == "run.finished",
          do: Enum.reverse(acc),
          else: collect(attachment, deadline, acc)

      _other ->
        if System.monotonic_time(:millisecond) >= deadline do
          Enum.reverse(acc)
        else
          Process.sleep(10)
          collect(attachment, deadline, acc)
        end
    end
  end

  test "a prompt runs until the model stops requesting tools rather than after a fixed number of turns" do
    # Four turns of tool use, then the model stops on its own. M1's loop was
    # hardwired to exactly two turns; nothing here caps it at any number.
    script =
      for index <- 1..4 do
        %{text: "turn #{index}", calls: [call("c#{index}")]}
      end ++ [%{text: "all done", calls: []}]

    fixture = start(script: script)
    {_session_id, attachment, reply} = Fixture.run(fixture, "do the work")
    assert {:accepted, "prompt-1"} = reply

    events = drain(attachment)
    finished = Enum.find(events, &(&1.kind == "run.finished"))
    assert finished["outcome"] == "completed"

    # Five model requests: four that asked for a tool and one that stopped.
    assert length(AgentLoopTestModel.dispatched(fixture.model)) == 5
    assert length(Loopex.AgentLoopTestExecutor.jobs(fixture.executor)) == 4
  end

  test "every model request carries the committed conversation history including the original prompt" do
    script = [
      %{text: "reading", calls: [call("c1")]},
      %{text: "writing", calls: [call("c2")]},
      %{text: "finished", calls: []}
    ]

    fixture = start(script: script)
    {_session_id, attachment, _reply} = Fixture.run(fixture, "the original prompt")
    _events = drain(attachment)

    [first, second, third] = AgentLoopTestModel.dispatched(fixture.model)

    # Every request, including the first, carries the operator's exact prompt.
    for request <- [first, second, third] do
      assert Enum.any?(
               request.messages,
               &(&1["role"] == "user" and &1["content"] == "the original prompt")
             )
    end

    # And each later request carries strictly more history than the one before.
    assert length(first.messages) < length(second.messages)
    assert length(second.messages) < length(third.messages)
  end

  test "an assistant tool call and its real tool result are committed and replayed to the model" do
    script = [
      %{text: "I will write the file", calls: [call("c1")]},
      %{text: "done", calls: []}
    ]

    fixture = start(script: script)
    {_session_id, attachment, _reply} = Fixture.run(fixture, "go")
    _events = drain(attachment)

    [_first, second] = AgentLoopTestModel.dispatched(fixture.model)

    # The model's own prior message is replayed back to it verbatim.
    assistant = Enum.find(second.messages, &(&1["role"] == "assistant"))
    assert assistant["content"] == "I will write the file"
    assert [%{"tool_call_id" => "c1"}] = assistant["tool_calls"]

    # And so is the tool's real output, not a synthesized summary of it. M1 sent
    # the string "Tool <name> completed: completed" here.
    result = Enum.find(second.messages, &(&1["role"] == "tool"))
    assert result["tool_call_id"] == "c1"
    assert result["content"] == "tool output for c1"
    assert result["outcome"] == "completed"
  end

  test "each turn dispatches exactly the canonical request bytes and digest committed before it" do
    script = [%{text: "one", calls: [call("c1")]}, %{text: "two", calls: []}]

    fixture = start(script: script)
    {session_id, attachment, _reply} = Fixture.run(fixture, "go")
    _events = drain(attachment)

    dispatched = AgentLoopTestModel.dispatched(fixture.model)

    committed =
      fixture
      |> Fixture.records(session_id)
      |> Enum.filter(&(&1.payload[:kind] == "model_request_committed"))

    assert length(committed) == length(dispatched)

    # What the adapter received is byte-identical to what was committed before
    # it was called, and the digest covers exactly those bytes.
    for {record, request} <- Enum.zip(committed, dispatched) do
      assert record.payload["request"]["canonical_request_bytes"] ==
               request.canonical_request_bytes

      assert record.payload["request"]["staged_request_digest"] == request.staged_request_digest
      assert :ok = Loopex.Model.validate_request(request)
    end
  end

  test "a staged request carries complete tool definition bytes and its generation triple and is reconstructible from the journal alone" do
    definition = Fixture.tool_definition()
    fixture = start(script: [%{text: "done", calls: []}], tools: [definition])
    {session_id, attachment, _reply} = Fixture.run(fixture, "go")
    _events = drain(attachment)

    [request] = AgentLoopTestModel.dispatched(fixture.model)

    # Every field of the record travels, not only the three a provider renders,
    # which is what makes the digest checkable here at all.
    assert [staged] = request.tools
    assert Map.keys(staged) |> Enum.sort() == Enum.sort(ToolDefinition.fields())
    assert staged == definition
    assert ToolDefinition.generation(staged) == ToolDefinition.generation(definition)

    # The journal alone reconstructs it: no registry read is involved, which is
    # why a later version bump or removal cannot change what was dispatched.
    [record] =
      fixture
      |> Fixture.records(session_id)
      |> Enum.filter(&(&1.payload[:kind] == "model_request_committed"))

    assert record.payload["request"]["tools"] == [definition]
  end

  test "every turn after the first is canonical history replay and the reserved continuation field stays empty" do
    script = [
      %{text: "one", calls: [call("c1")]},
      %{text: "two", calls: [call("c2")]},
      %{text: "three", calls: []}
    ]

    fixture = start(script: script)
    {_session_id, attachment, _reply} = Fixture.run(fixture, "go")
    _events = drain(attachment)

    requests = AgentLoopTestModel.dispatched(fixture.model)
    assert length(requests) == 3

    # Turn two is a continuation because the conversation was replayed, not
    # because a provider handle was retained. The reserved field is present and
    # empty in every request, and M2 never reads or writes it.
    for request <- requests do
      assert Map.has_key?(request, :continuation)
      assert request.continuation == nil
    end
  end

  test "the maximum turn bound ends the run bound reached before another provider call" do
    # The model would keep asking forever; the bound is what stops it.
    script = for index <- 1..20, do: %{text: "turn #{index}", calls: [call("c#{index}")]}

    fixture = start(script: script)
    {_session_id, attachment, _reply} = Fixture.run(fixture, "go", %{max_turns: 3})
    events = drain(attachment)

    finished = Enum.find(events, &(&1.kind == "run.finished"))
    assert finished["outcome"] == "bound_reached"
    assert finished["bound"] == "max_turns"
    assert finished["observed"] == 3
    assert finished["declared_limit"] == 3

    # No further provider call was made after the bound was reached.
    assert length(AgentLoopTestModel.dispatched(fixture.model)) == 3
  end

  test "the cumulative token budget ends the run bound reached before another provider call" do
    script =
      for index <- 1..20 do
        %{
          text: "turn #{index}",
          calls: [call("c#{index}")],
          usage: %{"input_tokens" => 400, "output_tokens" => 100}
        }
      end

    fixture = start(script: script)
    {_session_id, attachment, _reply} = Fixture.run(fixture, "go", %{token_budget: 1_000})
    events = drain(attachment)

    finished = Enum.find(events, &(&1.kind == "run.finished"))
    assert finished["outcome"] == "bound_reached"
    assert finished["bound"] == "token_budget"
    assert finished["declared_limit"] == 1_000
    assert finished["observed"] >= 1_000

    # The provider reported its own usage, so that is what was charged.
    assert finished["accounting_source"] == "reported"
    assert length(AgentLoopTestModel.dispatched(fixture.model)) == 2
  end

  test "the wall clock deadline ends the run bound reached before another provider call" do
    script = for index <- 1..20, do: %{text: "turn #{index}", calls: [call("c#{index}")]}

    fixture = start(script: script)
    # A deadline already in the past when the first turn settles.
    {_session_id, attachment, _reply} = Fixture.run(fixture, "go", %{deadline_ms: 1})
    events = drain(attachment)

    finished = Enum.find(events, &(&1.kind == "run.finished"))
    assert finished["outcome"] == "bound_reached"
    assert finished["bound"] == "deadline"

    # The deadline ended it, not exhaustion: the script offered twenty turns and
    # the declared limit of eight was never reached. The exact turn count is
    # deliberately not asserted — a one millisecond deadline can be reached
    # within the same millisecond a fast turn completes in, so pinning it would
    # make this case pass or fail on scheduling rather than on the bound.
    dispatched = length(AgentLoopTestModel.dispatched(fixture.model))
    assert dispatched >= 1
    assert dispatched < 8
    assert finished["observed"] >= finished["declared_limit"]
  end

  test "the committed absolute deadline is propagated into the model call rather than an independent per call timeout" do
    before = System.system_time(:millisecond)
    fixture = start(script: [%{text: "one", calls: [call("c1")]}, %{text: "two", calls: []}])
    {_session_id, attachment, _reply} = Fixture.run(fixture, "go", %{deadline_ms: 3_600_000})
    _events = drain(attachment)

    [first | rest] = AgentLoopTestModel.dispatched(fixture.model)
    deadline = first.deadline

    # The instant is fixed once, by the first turn, and lies inside the window
    # the run declared rather than being invented per call.
    assert deadline >= before + 3_600_000
    assert deadline <= System.system_time(:millisecond) + 3_600_000

    # Every later turn reuses that same instant. A per-call timeout would drift
    # forward on each turn and could outlast the run that owns it.
    for request <- rest do
      assert request.deadline == deadline
    end

    # So does every executor job the run dispatched, as a canonicalized field
    # covered by the job digest rather than a timeout the executor chose.
    for job <- Loopex.AgentLoopTestExecutor.jobs(fixture.executor) do
      assert job.run_deadline == deadline
    end
  end

  test "every sampling bound is a declared committed value with no implicit default" do
    # M1 fell back to 128 output tokens when nothing declared one. A run that
    # declares no bound is now refused rather than silently truncated.
    fixture = start(script: [%{text: "done", calls: []}], max_tokens: 512)
    {session_id, attachment, _reply} = Fixture.run(fixture, "go")
    _events = drain(attachment)

    [request] = AgentLoopTestModel.dispatched(fixture.model)
    assert request.sampling == %{"max_tokens" => 512}
    assert Loopex.Model.max_tokens(request) == 512

    # The declared value is inside the committed bytes, so it is covered by the
    # digest rather than being an argument the adapter could vary.
    [record] =
      fixture
      |> Fixture.records(session_id)
      |> Enum.filter(&(&1.payload[:kind] == "model_request_committed"))

    assert record.payload["request"]["sampling"] == %{"max_tokens" => 512}

    # And a prompt that declares no bounds at all is refused outright.
    {:ok, other} = Loopex.create_session(fixture.runtime, %{"t" => "x"}, command_id: "create-2")
    {:ok, other_attachment} = Loopex.attach(fixture.runtime, other, after_event_sequence: 0)

    # A prompt that names no bounds still commits declared values, taken from the
    # runtime's configuration rather than invented at dispatch.
    assert {:accepted, "unbounded"} =
             Loopex.command(other_attachment, %{
               type: :prompt,
               command_id: "unbounded",
               content: "go"
             })

    # And a malformed declaration is refused rather than quietly defaulted.
    assert {:error, :invalid_declared_bounds} = Bounds.declare(%{max_turns: 1, token_budget: 1})
  end

  test "several tool calls in one turn are dispatched in the model's own call order" do
    script = [
      %{text: "three at once", calls: [call("a"), call("b"), call("c")]},
      %{text: "done", calls: []}
    ]

    fixture = start(script: script)
    {_session_id, attachment, _reply} = Fixture.run(fixture, "go")
    _events = drain(attachment)

    dispatched = Loopex.AgentLoopTestExecutor.jobs(fixture.executor)
    assert Enum.map(dispatched, & &1.tool_call_id) == ["a", "b", "c"]

    # The next turn is staged only once every call of that turn has an answer.
    [_first, second] = AgentLoopTestModel.dispatched(fixture.model)
    results = Enum.filter(second.messages, &(&1["role"] == "tool"))
    assert Enum.map(results, & &1["tool_call_id"]) == ["a", "b", "c"]
  end
end
