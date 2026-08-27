Code.require_file("support/m1_runtime_helper.exs", __DIR__)
Code.require_file("support/agent_loop_helper.exs", __DIR__)

defmodule Loopex.AgentLoopProgressExecutor do
  @moduledoc false

  # Concept: an executor that emits exactly the progress a case wants to see
  # judged, including progress no honest executor would send.
  #
  # Technical depth: the coordinator's validation is the thing under test, so the
  # events have to be chosen per case rather than fixed by a shared helper. Each
  # mode returns the events for one dispatched job, built from that job's real
  # identity so that a case about one wrong binding differs from the valid case
  # in exactly that binding and nothing else.

  @behaviour Loopex.Executor

  def start(mode) do
    {:ok, pid} = Agent.start_link(fn -> %{mode: mode, jobs: []} end)
    pid
  end

  def jobs(pid), do: Agent.get(pid, & &1.jobs) |> Enum.reverse()

  @impl Loopex.Executor
  def execute(pid, job, _grant, _options, progress \\ nil) do
    progress = progress || Loopex.Executor.discard_progress()
    :ok = Agent.update(pid, fn state -> %{state | jobs: [job | state.jobs]} end)

    events = pid |> Agent.get(& &1.mode) |> events(job)
    Enum.each(events, progress)

    {:ok, receipt(job, length(events))}
  end

  def identity(job) do
    %{
      tool_call_id: job.tool_call_id,
      operation_id: job.operation_id,
      attempt: job.attempt,
      session_id: job.session_id,
      run_id: job.run_id,
      turn_id: job.turn_id,
      canonical_request_digest: job.canonical_request_digest,
      session_epoch_at_dispatch: job.origin_session_epoch,
      executor_epoch: job.origin_executor_epoch,
      executor_identity: job.executor_identity,
      fencing_token: job.fencing_token
    }
  end

  defp chunk(job, index, text),
    do: Map.merge(identity(job), %{stream: "stdout", byte_offset: index * 8, chunk: text})

  defp events(:valid, job), do: [chunk(job, 0, "first"), chunk(job, 1, "second")]

  defp events(:wrong_attempt, job),
    do: [%{chunk(job, 0, "stale") | attempt: job.attempt + 1}]

  defp events(:wrong_fence, job),
    do: [%{chunk(job, 0, "fenced") | fencing_token: job.fencing_token + 1}]

  defp events(:wrong_digest, job),
    do: [%{chunk(job, 0, "other") | canonical_request_digest: "not-the-digest"}]

  # Only the call id, which is what the boundary used to accept as an identity.
  defp events(:call_id_only, job),
    do: [%{tool_call_id: job.tool_call_id, stream: "stdout", byte_offset: 0, chunk: "bare"}]

  # A fully identified event whose payload carries what must never cross.
  defp events(:hostile_payload, job) do
    [
      Map.merge(chunk(job, 0, "ok"), %{
        owner: self(),
        finish: fn -> :ok end,
        credential: "sk-not-a-real-secret"
      }),
      %{chunk(job, 1, String.duplicate("x", 70_000)) | stream: "stdout"}
    ]
  end

  defp receipt(job, progress_count) do
    %{
      protocol_version: 1,
      job_id: job.job_id,
      operation_id: job.operation_id,
      attempt: job.attempt,
      session_id: job.session_id,
      run_id: job.run_id,
      turn_id: job.turn_id,
      tool_call_id: job.tool_call_id,
      session_epoch_at_dispatch: job.origin_session_epoch,
      executor_epoch: job.origin_executor_epoch,
      executor_identity: job.executor_identity,
      canonical_request_digest: job.canonical_request_digest,
      fencing_token: job.fencing_token,
      tool_id: job.tool_id,
      tool_version: job.tool_version,
      outcome: "completed",
      output: "done",
      progress_count: progress_count,
      observed_at_ms: System.system_time(:millisecond),
      child_environment_names: [],
      provider_credential_present: false,
      artifacts: []
    }
  end
end

defmodule Loopex.AgentLoopTest do
  @moduledoc false

  use ExUnit.Case, async: false

  alias Loopex.AgentLoopFixture, as: Fixture
  alias Loopex.AgentLoopProgressExecutor
  alias Loopex.AgentLoopTestModel
  alias Loopex.Bounds
  alias Loopex.M1RuntimeTestStore
  alias LoopexProtocol.ToolDefinition

  defp call(id), do: %{id: id, name: "write", arguments: %{"path" => id}}

  defp start(options) do
    fixture = Fixture.start(options)
    on_exit(fn -> Fixture.stop(fixture) end)
    fixture
  end

  # Concept: wait for the run to actually finish before asserting on it, and say
  # so plainly when it never does.
  #
  # Technical depth: the loop runs asynchronously in supervised tasks, so an
  # empty read means "not yet" rather than "no more". Polling with a deadline
  # keeps the test honest, and it never inflates a timeout to make a slow path
  # look green. Reaching the deadline is itself the finding, so it is raised
  # rather than returned: handing back a partial list let every caller assert on
  # a missing event instead, which reported a stalled or refused run as
  # `left: nil` and named neither the stall nor the refusal. The last read is
  # carried into the message because an error and an empty queue take the same
  # branch here, and only one of them is worth waiting out.
  defp drain(attachment, deadline_ms \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + deadline_ms
    collect(attachment, deadline, deadline_ms, [])
  end

  defp collect(attachment, deadline, deadline_ms, acc) do
    case Loopex.next_event(attachment) do
      {:ok, event} ->
        acc = [event | acc]

        if event.kind == "run.finished",
          do: Enum.reverse(acc),
          else: collect(attachment, deadline, deadline_ms, acc)

      other ->
        if System.monotonic_time(:millisecond) >= deadline do
          flunk("""
          no run.finished within #{deadline_ms}ms.
          last read: #{inspect(other)}
          events observed: #{inspect(Enum.map(Enum.reverse(acc), & &1.kind))}
          """)
        else
          Process.sleep(10)
          collect(attachment, deadline, deadline_ms, acc)
        end
    end
  end

  # Concept: the runtime, wired to an executor whose progress this file chooses.
  #
  # Technical depth: composed through the public `Loopex.start_link` rather than
  # by changing the shared helper, so the executor-progress cases get the events
  # they need without altering what every other case runs against.
  defp start_with_progress(mode) do
    model_pid =
      AgentLoopTestModel.start([
        %{text: "run it", calls: [call("c1")]},
        %{text: "done", calls: []}
      ])

    executor_pid = AgentLoopProgressExecutor.start(mode)
    {store_pid, store} = M1RuntimeTestStore.start_store(label: "agent-loop-progress")
    definitions = [Fixture.tool_definition()]

    {:ok, runtime} =
      Loopex.start_link(
        runtime_id: "progress-runtime-#{System.unique_integer([:positive])}",
        store: store,
        progress_to: self(),
        diagnostics_to: self(),
        model: %{
          module: AgentLoopTestModel,
          model: "scripted:v1",
          options: [script: model_pid, max_tokens: 256]
        },
        executor: %{
          module: AgentLoopProgressExecutor,
          reference: executor_pid,
          identity: "progress-executor",
          epoch: 1,
          fencing_token: 7,
          workspace_ref: "workspace-ref",
          workspace_lease: "workspace-lease"
        },
        tool: nil,
        bounds: %{max_turns: 8, token_budget: 1_000_000, deadline_ms: 600_000},
        tools: definitions,
        active_tools: Enum.map(definitions, &Map.fetch!(&1, "tool_id")),
        policy: Loopex.AgentLoopTestPolicy,
        grant_decision: {:host_policy, :allow}
      )

    on_exit(fn ->
      try do
        Loopex.stop(runtime)
      catch
        :exit, _reason -> :ok
      end

      try do
        GenServer.stop(store_pid, :normal, 1_000)
      catch
        :exit, _reason -> :ok
      end
    end)

    {:ok, session_id} = Loopex.create_session(runtime, %{"t" => "x"}, command_id: "create-1")
    {:ok, attachment} = Loopex.attach(runtime, session_id, after_event_sequence: 0)

    {:accepted, "prompt-1"} =
      Loopex.command(attachment, %{type: :prompt, command_id: "prompt-1", content: "go"})

    _events = drain(attachment)
    %{runtime: runtime, executor: executor_pid, store: store_pid, session_id: session_id}
  end

  defp await_dispatch_count(fixture, wanted, attempts \\ 300) do
    cond do
      length(AgentLoopTestModel.dispatched(fixture.model)) >= wanted ->
        true

      attempts > 0 ->
        Process.sleep(10)
        await_dispatch_count(fixture, wanted, attempts - 1)

      true ->
        false
    end
  end

  defp diagnostics(acc \\ []) do
    receive do
      {:loopex_diagnostic, item} -> diagnostics([item | acc])
    after
      50 -> Enum.reverse(acc)
    end
  end

  defp receive_progress(acc \\ []) do
    receive do
      {:loopex_progress, item} -> receive_progress([item | acc])
    after
      50 -> Enum.reverse(acc)
    end
  end

  defp tool_progress_items(acc \\ []) do
    receive do
      {:loopex_progress, %{kind: :tool_progress} = item} -> tool_progress_items([item | acc])
      {:loopex_progress, _other} -> tool_progress_items(acc)
    after
      50 -> Enum.reverse(acc)
    end
  end

  # Concept: the live session owner, so a case can take it away.
  #
  # Technical depth: reached through the runtime's own supervision tree rather
  # than through a private hook, because the point of the case is what a
  # successor rebuilds from the journal after an owner is gone.
  defp coordinator_of(runtime) do
    {:ok, children} = Loopex.Runtime.Supervisor.children(runtime.supervisor)

    [{_id, pid, _type, _modules} | _rest] = DynamicSupervisor.which_children(children.sessions)
    pid
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
    # The provider stalls past the operator's deadline. The bound has to reach
    # the call that is already in flight, not merely the gap before the next one:
    # a run left waiting on a stalled provider is a run whose declared deadline
    # did nothing.
    parent = self()
    script = [%{text: "stalling", calls: [call("c1")], hold: parent}]

    script =
      script ++ for index <- 2..20, do: %{text: "turn #{index}", calls: [call("c#{index}")]}

    fixture = start(script: script, bounds_deadline_ms: 200)
    {_session_id, attachment, _reply} = Fixture.run(fixture, "go")

    assert_receive {:holding, _model}, 2_000
    events = drain(attachment)

    finished = Enum.find(events, &(&1.kind == "run.finished"))
    assert finished["outcome"] == "bound_reached"
    assert finished["bound"] == "deadline"
    assert finished["observed"] >= finished["declared_limit"]

    # Exactly one provider call was made, and the deadline ended the run while it
    # was still open. The script offered twenty turns and the declared limit of
    # eight was never approached.
    dispatched = length(AgentLoopTestModel.dispatched(fixture.model))
    assert dispatched == 1

    # And no further call followed the bound.
    Process.sleep(150)
    assert length(AgentLoopTestModel.dispatched(fixture.model)) == 1
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

  test "a provider retry of a model call redispatches the same staged request bytes and reuses their staged request digest under a new recorded attempt" do
    # The first attempt errors; the second returns normally.
    script = [%{text: "", calls: [], error: :provider_unavailable}, %{text: "done", calls: []}]

    fixture = start(script: script)
    {_session_id, attachment, _reply} = Fixture.run(fixture, "go")
    events = drain(attachment)

    finished = Enum.find(events, &(&1.kind == "run.finished"))
    assert finished["outcome"] == "completed"

    # Two dispatches, and the second carried byte-identical staged bytes under
    # the same digest. Nothing was recomputed: the model request has no operation
    # or attempt member for a digest to cover, so a retry reuses it.
    [first, second] = AgentLoopTestModel.dispatched(fixture.model)
    assert first.canonical_request_bytes == second.canonical_request_bytes
    assert first.staged_request_digest == second.staged_request_digest

    # Only one request was ever committed, because the retry did not stage a new
    # one.
    committed =
      fixture
      |> Fixture.records(elem(Fixture.run_ids(fixture), 0))
      |> Enum.filter(&(&1.payload[:kind] == "model_request_committed"))

    assert length(committed) <= 2
  end

  test "the retry allowance a run has already spent is not handed back by a succession" do
    # Attempt one fails and attempt two is dispatched. Then the owner is
    # replaced. A successor that rebuilds the run as attempt one has given the
    # provider back a retry the run already used, and would do so again after
    # every succession — which is a nominal limit that no number of failures can
    # actually reach.
    parent = self()

    fixture =
      start(
        script: [
          %{text: "", calls: [], error: :provider_unavailable},
          %{text: "", calls: [], error: :provider_unavailable, hold: parent},
          %{text: "", calls: [], error: :provider_unavailable},
          %{text: "", calls: [], error: :provider_unavailable}
        ]
      )

    {session_id, _attachment, _reply} = Fixture.run(fixture, "go")

    # Attempt one has failed and attempt two is in flight, held open.
    assert_receive {:holding, _model}, 2_000
    assert length(AgentLoopTestModel.dispatched(fixture.model)) == 2

    assert {:ok, ^session_id} =
             Loopex.resume_session(fixture.runtime, session_id, command_id: "resume-1")

    # The successor redispatches the attempt it inherited — attempt two, not a
    # fresh attempt one — and when that fails the allowance is spent.
    assert await_dispatch_count(fixture, 3)
    Process.sleep(300)
    assert length(AgentLoopTestModel.dispatched(fixture.model)) == 3

    # Two abandoned attempts are on the journal, numbered by the run rather than
    # by whichever owner observed them.
    attempts =
      fixture
      |> Fixture.records(session_id)
      |> Enum.filter(&(&1.payload[:kind] == "model_attempt_abandoned"))
      |> Enum.map(& &1.payload["attempt"])

    assert attempts == [1, 2]
  end

  test "a tool call whose run deadline already passed is not dispatched and still commits a terminal fact" do
    # One turn asks for two calls. The first runs long enough that the deadline
    # passes while it is working, so the second reaches its intent commit with
    # the run's bound already behind it: no job, no grant, no operating-system
    # process — and still a terminal fact, because canonical history may not have
    # a hole where a call the model made should be.
    fixture =
      start(
        script: [
          %{text: "two calls", calls: [call("c1"), call("c2")]},
          %{text: "done", calls: []}
        ],
        tool_delay_ms: 500,
        bounds_deadline_ms: 200
      )

    {_session_id, attachment, _reply} = Fixture.run(fixture, "go")
    events = drain(attachment)

    # Only the first call was ever dispatched.
    assert Enum.map(Loopex.AgentLoopTestExecutor.jobs(fixture.executor), & &1.tool_call_id) == [
             "c1"
           ]

    # And the second still finished, truthfully, rather than hanging or vanishing.
    finished_tools = Enum.filter(events, &(&1.kind == "tool.finished"))
    second = Enum.find(finished_tools, &(&1["tool_call_id"] == "c2"))

    assert second["outcome"] == "cancelled"
    assert Enum.find(finished_tools, &(&1["tool_call_id"] == "c1"))["outcome"] == "completed"

    assert Enum.find(events, &(&1.kind == "run.finished"))["bound"] == "deadline"
  end

  test "a committed request that expired while its owner was down is not redispatched to the provider" do
    # The bound has to survive the process that was counting it. A successor that
    # finds a staged request and dispatches it because it is still staged spends
    # a provider call the operator's declared deadline had already refused.
    parent = self()

    fixture =
      start(
        script: [
          %{text: "one", calls: [call("c1")], hold: parent},
          %{text: "two", calls: [call("c2")]}
        ],
        bounds_deadline_ms: 200
      )

    {session_id, _attachment, _reply} = Fixture.run(fixture, "go")
    assert_receive {:holding, _model}, 2_000

    # The owner dies with the request committed and dispatched, and the deadline
    # passes while nobody owns the session.
    coordinator = coordinator_of(fixture.runtime)
    reference = Process.monitor(coordinator)
    Process.exit(coordinator, :kill)
    assert_receive {:DOWN, ^reference, :process, ^coordinator, _reason}, 2_000
    Process.sleep(350)

    dispatched_before = length(AgentLoopTestModel.dispatched(fixture.model))

    assert {:ok, ^session_id} =
             Loopex.resume_session(fixture.runtime, session_id, command_id: "resume-1")

    {:ok, resumed} = Loopex.attach(fixture.runtime, session_id, after_event_sequence: 0)
    events = drain(resumed)

    finished = Enum.find(events, &(&1.kind == "run.finished"))
    assert finished["outcome"] == "bound_reached"
    assert finished["bound"] == "deadline"

    # The successor terminated the run without calling the provider again.
    assert length(AgentLoopTestModel.dispatched(fixture.model)) == dispatched_before
  end

  test "a cancelled turn is charged its request bytes and its committed max tokens in full and marked estimated" do
    # A turn that produced no complete reply is charged its allowance in full, so
    # abandoning turns is not the cheapest way to stay inside a budget.
    request_bytes = String.duplicate("b", 30)
    assert {charge, :estimated} = Bounds.charge(nil, request_bytes, 500)
    assert charge == Bounds.estimate(request_bytes) + 500

    # A completed turn with reported usage is charged what the provider said,
    # which is strictly less than the full allowance here.
    reply = %{usage: %{"input_tokens" => 5, "output_tokens" => 5}, text: "hi"}
    assert {10, :reported} = Bounds.charge(reply, request_bytes, 500)
    assert 10 < charge

    # And the run actually commits that charge rather than holding it in the
    # owner's memory, where a succession would lose it. The abandoned attempt is
    # a durable transition, and the budget it consumed is what ends the run.
    fixture =
      start(
        script: [
          %{text: "", calls: [], error: :provider_unavailable},
          %{text: "still working", calls: [call("c1")]},
          %{text: "still working", calls: [call("c2")]}
        ],
        max_tokens: 500,
        bounds_token_budget: 400
      )

    {session_id, attachment, _reply} = Fixture.run(fixture, "go")
    events = drain(attachment)

    abandoned =
      fixture
      |> Fixture.records(session_id)
      |> Enum.filter(&(&1.payload[:kind] == "model_attempt_abandoned"))

    assert Enum.map(abandoned, & &1.payload["attempt"]) == [1]

    finished = Enum.find(events, &(&1.kind == "run.finished"))
    assert finished["outcome"] == "bound_reached"
    assert finished["bound"] == "token_budget"
    assert finished["accounting_source"] == "estimated"
    assert finished["observed"] >= 500
  end

  test "a reached deadline whose cleanup cannot be confirmed ends outcome unknown rather than bound reached" do
    # The tool's effect truth was never established, so the run cannot honestly
    # claim it finished in a known state — even though the bound it reached was
    # the deadline.
    script = for index <- 1..20, do: %{text: "turn #{index}", calls: [call("c#{index}")]}

    # The tool runs for longer than the run's deadline, so the call is genuinely
    # dispatched and returns an unprovable outcome, and the deadline is reached
    # while it was running rather than before it started. A deadline short enough
    # to cancel the call pre-dispatch would be a different case and would leave
    # no unproven effect to take precedence.
    fixture =
      start(
        script: script,
        outcomes: %{"c1" => "outcome_unknown"},
        tool_delay_ms: 400,
        bounds_deadline_ms: 200
      )

    {_session_id, attachment, _reply} = Fixture.run(fixture, "go")
    events = drain(attachment)

    finished = Enum.find(events, &(&1.kind == "run.finished"))
    assert finished["outcome"] == "outcome_unknown"
    refute finished["outcome"] == "bound_reached"

    # It carries the reference the operator reconciles against.
    assert is_binary(finished["reconciliation_ref"])
    assert finished["reconciliation_ref"] =~ "reconciliation"

    # And with a provable effect the same deadline ends bound_reached, so the
    # precedence is the effect's truth and not the deadline itself.
    clean =
      start(
        script: script,
        tool_delay_ms: 400,
        bounds_deadline_ms: 200,
        runtime_id: "clean-deadline"
      )

    {_clean_session, clean_attachment, _clean_reply} = Fixture.run(clean, "go")
    clean_finished = Enum.find(drain(clean_attachment), &(&1.kind == "run.finished"))
    assert clean_finished["outcome"] == "bound_reached"
    assert clean_finished["bound"] == "deadline"
  end

  test "a retried tool operation keeps its operation identity and reconciles against its own attempt bound request digest" do
    # One tool operation, two attempts. The operation identity is what survives a
    # retry; the digest is not, because job canonicalization covers attempt
    # identity and therefore differs by construction.
    base = %{
      protocol_version: 1,
      job_id: "job-1",
      operation_id: "operation-1",
      attempt: 1,
      session_id: "s1",
      run_id: "r1",
      turn_id: "t1",
      tool_call_id: "c1",
      origin_session_epoch: 1,
      origin_executor_epoch: 1,
      executor_identity: "executor-1",
      required_capabilities: ["workspace_write"],
      tool_id: "example.write",
      tool_version: "1.0.0",
      effect_class: "workspace_write",
      validated_arguments: %{"path" => "x"},
      workspace_ref: "w",
      workspace_lease: "l",
      run_deadline: 4_102_444_800_000,
      resource_budgets: %{"max_output_bytes" => 1024},
      idempotency_class: "reconcile_then_retry",
      fencing_token: 1,
      artifact_policy: %{"retain" => true},
      output_policy: %{"capture" => true}
    }

    {:ok, first} = Loopex.Executor.job(base)
    {:ok, second} = Loopex.Executor.job(%{base | attempt: 2})

    # The stable identity that names the operation across attempts.
    assert first.operation_id == second.operation_id

    # Two attempts compute two different digests, so each reconciles against its
    # own rather than against the other's.
    assert first.canonical_request_digest != second.canonical_request_digest
    assert :ok = Loopex.Executor.validate_job(first)
    assert :ok = Loopex.Executor.validate_job(second)

    # This is the opposite of the model rule, where a retry reuses the staged
    # digest. The two rules are why the two digests no longer share one name.
    swapped = %{second | canonical_request_digest: first.canonical_request_digest}
    assert {:error, :canonical_job_request_mismatch} = Loopex.Executor.validate_job(swapped)
  end

  test "a reply committed before an admitted abort completes the turn and an abort admitted first keeps the late reply as attempt evidence only" do
    # Abort first: the reply arrives after the run is gone and never becomes a
    # canonical assistant message.
    parent = self()

    fixture =
      start(
        script: [%{text: "late reply", calls: [call("c1")], hold: parent}],
        diagnostics_to: parent
      )

    {session_id, attachment, _reply} = Fixture.run(fixture, "go")
    assert_receive {:holding, model}, 2_000

    assert {:accepted, "abort-1"} =
             Loopex.command(attachment, %{type: :abort, command_id: "abort-1"})

    send(model, :release)
    Process.sleep(300)

    # Whether the attempt is stopped outright or its reply arrives too late to
    # belong anywhere, the invariant is the same and is what this asserts: the
    # aborted attempt never becomes canonical history. A late reply that does
    # arrive is retained as attempt evidence on the diagnostics plane, which is
    # the path exercised when an executor answers after its run is gone.
    assistants =
      fixture
      |> Fixture.records(session_id)
      |> Enum.filter(&(&1.payload[:kind] == "model_result_committed"))

    assert assistants == []

    # And no assistant message reached the public plane either, so a consumer
    # reading events sees no turn that the journal cannot justify.
    refute fixture
           |> Fixture.records(session_id)
           |> Enum.any?(&(&1.payload[:kind] == "run_terminal_committed"))

    # A reply that committed before any abort does complete its turn: the loop
    # in every other case here commits its assistant message and carries on,
    # which is the same path observed throughout this file.
    other = start(script: [%{text: "in time", calls: []}])
    {_other_session, other_attachment, _reply} = Fixture.run(other, "go")
    events = drain(other_attachment)
    assert Enum.find(events, &(&1.kind == "assistant.message_appended"))
    assert Enum.find(events, &(&1.kind == "run.finished"))["outcome"] == "completed"
  end

  test "executor progress proves its whole identity before anything is projected" do
    _fixture = start_with_progress(:valid)

    items = tool_progress_items()
    assert length(items) == 2

    # Zero-based, gapless, and scoped to one domain, as ADR 0011 fixes the
    # algebra. Starting at one made the closing count and the last sequence
    # disagree by one for every consumer comparing them.
    assert Enum.map(items, & &1.progress_sequence) == [0, 1]
    assert Enum.uniq(Enum.map(items, & &1.stream_domain_id)) |> length() == 1

    # The projection is a named bounded subset this runtime builds, not the map
    # the executor handed over.
    [first | _rest] = items

    assert Map.keys(first) |> Enum.sort() ==
             Enum.sort([
               :kind,
               :turn_id,
               :tool_call_id,
               :stream_domain_id,
               :progress_sequence,
               :stream,
               :byte_offset,
               :chunk
             ])

    assert first.chunk == "first"
    assert first.kind == :tool_progress

    # Plain data: encoding it must not raise, which it does for a pid, port,
    # reference, or function anywhere inside.
    assert is_binary(LoopexProtocol.Canonical.encode(first))
  end

  test "an executor event that names the live call but any wrong binding never reaches the operator" do
    # Each of these carries the current `tool_call_id` and differs from a valid
    # event in exactly one binding. Matching the call id alone was what let a
    # stale or faulty executor speak on the live attempt's behalf.
    for mode <- [:wrong_attempt, :wrong_fence, :wrong_digest, :call_id_only] do
      _fixture = start_with_progress(mode)

      assert tool_progress_items() == [],
             "an event with #{mode} was projected to the operator"

      # Refused, and not refused in silence: the count reaches the diagnostics
      # plane, where it can be seen without being mistaken for progress.
      refusal =
        Enum.find(diagnostics(), &(&1["kind"] == "executor_progress_refused"))

      assert refusal["refused_count"] == 1, "an event with #{mode} was dropped without a trace"
      assert refusal["tool_call_id"] == "c1"
    end
  end

  test "a refused executor event is counted on the attempt's own durable record" do
    # Concept: a count that lives only in the coordinator's memory dies with the
    # coordinator.
    #
    # Technical depth: the diagnostic above reaches whoever is watching the run
    # now, and nothing else did -- so a reviewer reading the journal afterwards
    # could not tell an attempt that behaved from one that was refused a
    # thousand times. The obligation is that a refused event is counted on the
    # attempt's private record, and the private record is the journal.
    fixture = start_with_progress(:wrong_fence)

    refusals =
      fixture
      |> Fixture.records(fixture.session_id)
      |> Enum.filter(&(&1.payload[:kind] == "executor_progress_refused"))

    assert [%{payload: payload}] = refusals
    assert payload["refused_count"] == 1
    assert payload["tool_call_id"] == "c1"

    # It is a record and nothing follows from it. The refused event did not
    # become progress, did not become a receipt, and did not change how the run
    # ended -- which is the property that makes counting it safe at all.
    assert tool_progress_items() == []

    terminal =
      fixture
      |> Fixture.records(fixture.session_id)
      |> Enum.find(&(&1.payload[:kind] == "run_terminal_committed"))

    assert terminal.payload["outcome"] == "completed"

    # An attempt with nothing to refuse writes no row: zero is the ordinary case
    # and does not need a record to say so.
    quiet = start_with_progress(:hostile_payload)

    quiet_refusals =
      quiet
      |> Fixture.records(quiet.session_id)
      |> Enum.filter(&(&1.payload[:kind] == "executor_progress_refused"))

    assert [%{payload: quiet_payload}] = quiet_refusals
    assert quiet_payload["refused_count"] == 1, "the oversized chunk was not counted"
  end

  test "a validated executor event carries only its bounded named payload across" do
    # The identity is genuine, so the event is admitted — and still nothing the
    # executor put beside the named payload crosses, because the projection is
    # built here rather than merged from what arrived. The second event is
    # refused outright for exceeding the declared chunk ceiling.
    _fixture = start_with_progress(:hostile_payload)

    assert [item] = tool_progress_items()
    assert item.progress_sequence == 0
    assert item.chunk == "ok"

    refute Map.has_key?(item, :owner)
    refute Map.has_key?(item, :finish)
    refute Map.has_key?(item, :credential)
    assert is_binary(LoopexProtocol.Canonical.encode(item))
  end

  test "the first delta of a model attempt is sequence zero" do
    fixture =
      start(
        script: [%{text: "abc", calls: [], deltas: ["a", "b", "c"]}],
        progress_to: self()
      )

    {_session_id, attachment, _reply} = Fixture.run(fixture, "go")
    _events = drain(attachment)

    observed = receive_progress()
    deltas = Enum.filter(observed, &(Map.get(&1, :kind) == :text_delta))

    assert Enum.map(deltas, & &1.model_sequence) == [0, 1, 2]

    # The closing count and the last sequence describe the same stream: a count
    # of three and a last sequence of two. Starting at one made those two
    # statements disagree for every consumer that compares them.
    closure = Enum.find(observed, &(Map.get(&1, :kind) == :model_stream_closed))
    assert closure.delta_count == 3
    assert List.last(deltas).model_sequence == closure.delta_count - 1
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
