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
    {:ok, pid} = Agent.start_link(fn -> %{mode: mode, jobs: [], progress: nil} end)
    pid
  end

  def jobs(pid), do: Agent.get(pid, & &1.jobs) |> Enum.reverse()

  # Concept: the executor keeps the callback it was handed, exactly as a real one
  # does for as long as it holds the job.
  #
  # Technical depth: the coordinator cannot take the function back. Retaining it
  # here is what lets a case ask the only question that matters about closure:
  # what happens when the executor calls it once more after its job has answered.
  # An executor with a buffered chunk, or a progress call racing its own return,
  # does exactly this.
  def retained_progress(pid), do: Agent.get(pid, & &1.progress)

  @impl Loopex.Executor
  def execute(pid, job, _grant, _options, progress \\ nil) do
    progress = progress || Loopex.Executor.discard_progress()
    :ok = Agent.update(pid, fn state -> %{state | jobs: [job | state.jobs]} end)

    mode = Agent.get(pid, & &1.mode)
    :ok = Agent.update(pid, fn state -> %{state | progress: progress} end)
    events = events(mode, job)
    Enum.each(events, progress)

    # Concept: an executor that emitted progress and then could not produce a
    # receipt at all.
    #
    # Technical depth: the stream is closed `abandoned` rather than `complete`,
    # and there is no receipt, so the executor's own count does not exist to be
    # passed along. That is precisely the closure a count taken from the receipt
    # cannot describe, and the one a case that only ever drives a completed job
    # never reaches.
    case mode do
      :one_valid_two_refused_then_lost -> {:error, {:receipt_not_retained, :enospc}}
      _other -> {:ok, receipt(job, length(events))}
    end
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

  # Concept: one wrong binding, chosen by the case rather than by this double,
  # so every binding can be asked for rather than the three somebody thought of.
  #
  # Technical depth: three named vectors and one where every binding is missing
  # left seven of the eleven bindings free: any subset of the eleven that still
  # contains attempt, fencing token and digest refuses all four, so the other
  # seven could be deleted from the coordinator's comparison at once and nothing
  # went red. A vector per binding is the only shape that says "every".
  #
  # The wrong value is derived from the right one so it stays the same type. A
  # binding compared by equality would otherwise be refused for being a string
  # where an integer belongs, which is a different refusal from the one this is
  # about.
  defp events({:wrong, binding}, job) do
    event = chunk(job, 0, "tampered")
    [Map.put(event, binding, tamper(Map.fetch!(event, binding)))]
  end

  defp events(:wrong_attempt, job),
    do: [%{chunk(job, 0, "stale") | attempt: job.attempt + 1}]

  defp events(:wrong_fence, job),
    do: [%{chunk(job, 0, "fenced") | fencing_token: job.fencing_token + 1}]

  defp events(:wrong_digest, job),
    do: [%{chunk(job, 0, "other") | canonical_request_digest: "not-the-digest"}]

  # Concept: one event this coordinator accepts and two it refuses, from an
  # executor that counts all three.
  #
  # Technical depth: the executor's `progress_count` is what it emitted, which is
  # the only number it can know. Whether an event was projected is the
  # coordinator's decision, made after the executor has finished with it. A case
  # that needs those two numbers to differ needs an executor that emits events
  # of both kinds in one job, which no single-mode double could produce.
  defp events(:one_valid_two_refused, job) do
    [
      chunk(job, 0, "kept"),
      %{chunk(job, 1, "stale") | attempt: job.attempt + 1},
      %{chunk(job, 2, "fenced") | fencing_token: job.fencing_token + 1}
    ]
  end

  # The same three events from an executor that then loses its receipt, so the
  # stream is abandoned rather than completed.
  defp events(:one_valid_two_refused_then_lost, job),
    do: events(:one_valid_two_refused, job)

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

  # Kept below every `events/2` clause rather than beside the one that calls it:
  # a private helper written between two clauses of the same name and arity
  # splits them, and a split definition is a compile warning. The gate's selector
  # runner refuses a warning, so the placement is not a style preference.
  defp tamper(value) when is_integer(value), do: value + 1
  defp tamper(value) when is_binary(value), do: value <> "-not-this-one"

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

defmodule Loopex.AgentLoopAnsweringExecutor do
  @moduledoc false

  # Concept: an executor that answers a dispatched call with an error, and
  # records whether that call's effect had already happened when it did.
  #
  # Technical depth: the coordinator's classification of executor errors is what
  # is under test, so the case has to be able to name both sides of it — an
  # error raised by the validation that runs before anything is started, and an
  # error raised after the effect landed and only its receipt was lost. The
  # shared loop executor always answers `{:ok, receipt}`, so neither side of that
  # distinction can be reached through it. `effects/1` is this double's own
  # record of what actually ran; it stands in for the file the reviewer's probe
  # found in the workspace after the executor had reported an error.

  @behaviour Loopex.Executor

  def start(answers) when is_map(answers) do
    {:ok, pid} = Agent.start_link(fn -> %{answers: answers, jobs: [], effects: []} end)
    pid
  end

  def jobs(pid), do: Agent.get(pid, & &1.jobs) |> Enum.reverse()

  def effects(pid), do: Agent.get(pid, & &1.effects) |> Enum.reverse()

  @impl Loopex.Executor
  def cancel(_pid, _job_id), do: {:ok, :cleaned}

  @impl Loopex.Executor
  def execute(pid, job, _grant, _options, progress \\ nil) do
    _progress = progress || Loopex.Executor.discard_progress()
    :ok = Agent.update(pid, fn state -> %{state | jobs: [job | state.jobs]} end)

    case Agent.get(pid, &Map.get(&1.answers, job.tool_call_id, :completed)) do
      # The effect ran and landed. Only the answer about it is lost.
      {:after_effect, answer} ->
        :ok =
          Agent.update(pid, fn state ->
            %{state | effects: [job.tool_call_id | state.effects]}
          end)

        answer

      # Concept: this double says in the answer which of its own answers preceded
      # the effect, because the port makes that the executor's statement rather
      # than a caller's inference.
      #
      # Technical depth: nothing was started -- no process, no workspace change --
      # and `effects/1` has recorded nothing, so this branch is the one place this
      # double can trace to a line that runs before the record exists. Every other
      # answer it gives is produced after that record exists and is returned
      # untagged, which is why `{:receipt_not_retained, _}` can never arrive
      # wearing this tag.
      {:before_effect, {:error, reason}} ->
        {:error, {:refused_before_effect, reason}}

      :completed ->
        :ok =
          Agent.update(pid, fn state ->
            %{state | effects: [job.tool_call_id | state.effects]}
          end)

        {:ok, receipt(job)}
    end
  end

  defp receipt(job) do
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
      progress_count: 0,
      observed_at_ms: System.system_time(:millisecond),
      child_environment_names: [],
      provider_credential_present: false,
      artifacts: []
    }
    |> Map.merge(:persistent_term.get({__MODULE__, :receipt_extras}, %{}))
  end
end

defmodule Loopex.AgentLoopUndeclaringExecutor do
  @moduledoc false

  # Concept: a conforming executor that is not this project's, that loses its
  # workspace lease halfway through the effect and says so with the same name the
  # shipped local executor uses before a start.
  #
  # Technical depth: it implements exactly `execute/5`. `refused_before_effect?/1`
  # is optional, and an executor that does not export it has declared nothing --
  # which is the whole point of this double. Under the deleted allowlist the
  # coordinator recognised `:workspace_lease_lost` by name, read this answer as a
  # refusal, committed an ordinary `failed`, and let the loop resume past an
  # effect that had already landed in a workspace this executor no longer held.
  # `effects/1` is this double's own record of what actually ran.

  @behaviour Loopex.Executor

  def start(answers) when is_map(answers) do
    {:ok, pid} = Agent.start_link(fn -> %{answers: answers, jobs: [], effects: []} end)
    pid
  end

  def jobs(pid), do: Agent.get(pid, & &1.jobs) |> Enum.reverse()

  def effects(pid), do: Agent.get(pid, & &1.effects) |> Enum.reverse()

  @impl Loopex.Executor
  def execute(pid, job, _grant, _options, progress \\ nil) do
    _progress = progress || Loopex.Executor.discard_progress()
    :ok = Agent.update(pid, fn state -> %{state | jobs: [job | state.jobs]} end)

    :ok =
      Agent.update(pid, fn state -> %{state | effects: [job.tool_call_id | state.effects]} end)

    Agent.get(pid, &Map.get(&1.answers, job.tool_call_id, {:error, :workspace_lease_lost}))
  end
end

defmodule Loopex.AgentLoopBrokenDeclarationExecutor do
  @moduledoc false

  # Concept: an executor that reaches for the declaration and misses.
  #
  # Technical depth: the tag is a shape, and a shape can be got wrong. A bare
  # atom where a tuple belongs, a tuple of the wrong size, a term that is not an
  # error at all -- each is an executor that intended to say its effect never
  # started and did not say it. None of them is a statement that the effect did
  # not happen, so none may be read as one, and each must reach the same unproven
  # answer a silent executor reaches. This double runs the effect first, so
  # believing any of them would be believing a falsehood.

  @behaviour Loopex.Executor

  def start(mode) do
    {:ok, pid} = Agent.start_link(fn -> %{mode: mode, effects: []} end)
    pid
  end

  # The three ways an answer can wear the tag without carrying it. Each is an
  # executor that meant to declare and did not manage to, and each has to reach
  # the same place a silent executor reaches: `true` is not a word the runtime
  # will accept in a shape it did not define.
  defp malformed(:bare_atom), do: {:error, :refused_before_effect}
  defp malformed(:wrong_arity), do: {:error, {:refused_before_effect}}
  defp malformed(:not_an_error), do: {:refused_before_effect, :invalid_tool_arguments}

  def effects(pid), do: Agent.get(pid, & &1.effects) |> Enum.reverse()

  @impl Loopex.Executor
  def execute(pid, job, _grant, _options, progress \\ nil) do
    _progress = progress || Loopex.Executor.discard_progress()

    :ok =
      Agent.update(pid, fn state -> %{state | effects: [job.tool_call_id | state.effects]} end)

    malformed(Agent.get(pid, & &1.mode))
  end
end

defmodule Loopex.AgentLoopTest do
  @moduledoc false

  use ExUnit.Case, async: false

  alias Loopex.AgentLoopFixture, as: Fixture
  alias Loopex.AgentLoopAnsweringExecutor
  alias Loopex.AgentLoopBrokenDeclarationExecutor
  alias Loopex.AgentLoopUndeclaringExecutor
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
    assert length(Loopex.AgentLoopAnsweringExecutor.jobs(fixture.executor)) == 4
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
    for job <- Loopex.AgentLoopAnsweringExecutor.jobs(fixture.executor) do
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
    assert Enum.map(Loopex.AgentLoopAnsweringExecutor.jobs(fixture.executor), & &1.tool_call_id) ==
             [
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

  # Concept: run one turn whose tool effect could not be proved, under an
  # ordinary deadline, and hand back what the session published.
  #
  # Technical depth: the deadline stays at its default, so nothing here can end
  # the run by reaching a bound in flight. Whatever ends these runs is the
  # unknown effect itself, which is the whole point: the precedence used to be
  # checked only where the deadline had already been reached, so a case that
  # arranged an elapsed deadline exercised the one branch that already had it.
  defp unknown_effect_run(script, bound_overrides \\ %{}) do
    fixture = start(script: script, outcomes: %{"c1" => "outcome_unknown"})
    {session_id, attachment, _reply} = Fixture.run(fixture, "go", bound_overrides)
    events = drain(attachment)

    {fixture, session_id, events, Enum.find(events, &(&1.kind == "run.finished"))}
  end

  test "an unproven effect ends the run rather than letting the model be asked again" do
    # The model would ask for another tool, and under an ordinary deadline
    # nothing else would stop it. An effect nobody could prove has to, because
    # `outcome_unknown` is terminal for the affected run: `docs/vision-technical.md`
    # fixes it as "immutable and terminal for its operation attempt and the
    # affected logical operation. Later evidence never rewrites the original
    # terminal event or silently resumes the model loop."
    script = for index <- 1..20, do: %{text: "turn #{index}", calls: [call("c#{index}")]}

    {fixture, session_id, events, finished} = unknown_effect_run(script)

    assert finished["outcome"] == "outcome_unknown"
    refute finished["outcome"] == "bound_reached"

    # The tool fact that outranked everything is published truthfully too.
    tool = Enum.find(events, &(&1.kind == "tool.finished"))
    assert tool["tool_call_id"] == "c1"
    assert tool["outcome"] == "outcome_unknown"

    # The model was asked exactly once. A second dispatch would mean the loop
    # resumed past an outcome that was already terminal, and would have carried
    # the unproven result back to the model as if it were a settled fact.
    assert length(AgentLoopTestModel.dispatched(fixture.model)) == 1
    Process.sleep(150)
    assert length(AgentLoopTestModel.dispatched(fixture.model)) == 1

    # And no further effect was dispatched behind it.
    assert Enum.map(Loopex.AgentLoopAnsweringExecutor.jobs(fixture.executor), & &1.tool_call_id) ==
             [
               "c1"
             ]

    # It carries the reference the operator reconciles against, and the
    # published reference is the one the run actually committed rather than a
    # value the projection invented.
    assert is_binary(finished["reconciliation_ref"])
    assert finished["reconciliation_ref"] =~ "reconciliation"

    committed =
      fixture
      |> Fixture.records(session_id)
      |> Enum.find(&(&1.payload[:kind] == "run_terminal_committed"))

    assert committed.payload["outcome"] == "outcome_unknown"
    assert committed.payload["reconciliation_ref"] == finished["reconciliation_ref"]

    # No bound ended this run, so none is claimed.
    assert finished["bound"] == nil
  end

  test "an unproven effect outranks the model stopping on its own and the run never finishes completed" do
    # The model asks for one tool and then stops asking. That is the ordinary
    # `completed` path, and it is exactly where a run holding an unproven effect
    # would quietly claim it finished in a known state.
    script = [%{text: "run it", calls: [call("c1")]}, %{text: "done", calls: []}]

    {fixture, _session_id, _events, finished} = unknown_effect_run(script)

    assert finished["outcome"] == "outcome_unknown"
    refute finished["outcome"] == "completed"
    assert is_binary(finished["reconciliation_ref"])

    # The model never got the second turn that would have produced `completed`.
    assert length(AgentLoopTestModel.dispatched(fixture.model)) == 1
  end

  test "an unproven effect stops the tool calls still queued behind it in the same batch" do
    # Both calls belong to one assistant message, so the run never reaches the
    # settlement where the precedence used to be read: the turn is still open,
    # and the coordinator dispatches the next call of that same turn directly.
    # `docs/vision-technical.md` makes `outcome_unknown` terminal for the
    # affected run, and a run that keeps running its remaining effects has
    # resumed past a terminal outcome — the loop was merely paused at the next
    # model call rather than stopped. The precedence is over further effects,
    # not only over the next request.
    script = [
      %{text: "two at once", calls: [call("c1"), call("c2")]},
      %{text: "done", calls: []}
    ]

    {fixture, _session_id, events, finished} = unknown_effect_run(script)

    assert Enum.map(Loopex.AgentLoopAnsweringExecutor.jobs(fixture.executor), & &1.tool_call_id) ==
             [
               "c1"
             ]

    # The second call was never announced either, so no operator is left holding
    # a `tool.started` that never finishes.
    assert Enum.map(Enum.filter(events, &(&1.kind == "tool.started")), & &1["tool_call_id"]) == [
             "c1"
           ]

    assert finished["outcome"] == "outcome_unknown"
    assert finished["bound"] == nil
    assert is_binary(finished["reconciliation_ref"])

    # And the model was asked exactly once, which is the part the earlier repair
    # already held.
    assert length(AgentLoopTestModel.dispatched(fixture.model)) == 1
  end

  test "an unproven effect outranks the maximum turn bound" do
    # The bound is reached on the same turn the unknown effect settles. A run
    # that reports `bound_reached` here tells an operator it stopped in a known
    # state at a limit, and buries the effect nobody can account for.
    script = for index <- 1..20, do: %{text: "turn #{index}", calls: [call("c#{index}")]}

    {fixture, _session_id, _events, finished} = unknown_effect_run(script, %{max_turns: 1})

    assert finished["outcome"] == "outcome_unknown"
    refute finished["outcome"] == "bound_reached"
    assert finished["bound"] == nil
    assert is_binary(finished["reconciliation_ref"])
    assert length(AgentLoopTestModel.dispatched(fixture.model)) == 1
  end

  test "an unproven effect outranks the cumulative token budget" do
    # Same precedence, reached through the other between-turn bound.
    script =
      for index <- 1..20 do
        %{
          text: "turn #{index}",
          calls: [call("c#{index}")],
          usage: %{"input_tokens" => 400, "output_tokens" => 100}
        }
      end

    {fixture, _session_id, _events, finished} = unknown_effect_run(script, %{token_budget: 400})

    assert finished["outcome"] == "outcome_unknown"
    refute finished["outcome"] == "bound_reached"
    assert finished["bound"] == nil
    assert is_binary(finished["reconciliation_ref"])
    assert length(AgentLoopTestModel.dispatched(fixture.model)) == 1
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

    # And the run did not end as though the attempt had succeeded, so a consumer
    # reading events sees no turn the journal cannot justify.
    #
    # This asserted that no `run_terminal_committed` record existed at all, which
    # was true only because an abort used to carry its ending inside its own
    # admission record and produce no terminal. It therefore passed without
    # testing anything the comment above it claimed. An abort commits an ending
    # now, like every other way a run stops, so the assertion is what the comment
    # always meant: whatever the run ended as, it was not `completed`.
    terminals =
      fixture
      |> Fixture.records(session_id)
      |> Enum.filter(&(&1.payload[:kind] == "run_terminal_committed"))

    refute Enum.any?(terminals, &(&1.payload["outcome"] == "completed")),
           "an aborted attempt's reply completed the run: " <>
             inspect(Enum.map(terminals, & &1.payload["outcome"]))

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
    #
    # Every binding is asked for by name, and the list is the full identity a
    # dispatched job carries rather than a selection. Three named vectors plus
    # one with no bindings at all was not "any wrong binding": it left seven of
    # the eleven unexercised, and they could be dropped from the coordinator's
    # comparison together without a single case noticing. `tool_call_id` is
    # covered by `:call_id_only` and by every other case in this file, since an
    # event that does not name the live call is refused before any of this.
    bindings = [
      :operation_id,
      :attempt,
      :session_id,
      :run_id,
      :turn_id,
      :canonical_request_digest,
      :session_epoch_at_dispatch,
      :executor_epoch,
      :executor_identity,
      :fencing_token
    ]

    modes = Enum.map(bindings, &{:wrong, &1}) ++ [:call_id_only]

    for mode <- modes do
      _fixture = start_with_progress(mode)

      assert tool_progress_items() == [],
             "an event with #{inspect(mode)} was projected to the operator"

      # Refused, and not refused in silence: the count reaches the diagnostics
      # plane, where it can be seen without being mistaken for progress.
      refusal =
        Enum.find(diagnostics(), &(&1["kind"] == "executor_progress_refused"))

      assert refusal["refused_count"] == 1,
             "an event with #{inspect(mode)} was dropped without a trace"

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

    dispatched = Loopex.AgentLoopAnsweringExecutor.jobs(fixture.executor)
    assert Enum.map(dispatched, & &1.tool_call_id) == ["a", "b", "c"]

    # The next turn is staged only once every call of that turn has an answer.
    [_first, second] = AgentLoopTestModel.dispatched(fixture.model)
    results = Enum.filter(second.messages, &(&1["role"] == "tool"))
    assert Enum.map(results, & &1["tool_call_id"]) == ["a", "b", "c"]
  end

  # Concept: the runtime, wired to an executor this file can make answer with an
  # error, and say whether the effect had already run when it did.
  #
  # Technical depth: composed through the public `Loopex.start_link` for the same
  # reason the progress cases are — the shared loop helper always answers
  # `{:ok, receipt}`, and the executor's error is the whole input here. The
  # attachment is handed back rather than drained, because these cases assert on
  # what the executor recorded before they wait for the run to end.
  defp start_answering(answers, script),
    do:
      start_with_executor(
        AgentLoopAnsweringExecutor,
        AgentLoopAnsweringExecutor.start(answers),
        script
      )

  # Concept: the same runtime, wired to whichever executor a case needs to be the
  # one under test.
  #
  # Technical depth: whether an effect started is now the executor's own
  # statement, so the cases that judge that classification differ only in which
  # executor module the runtime holds -- one that declares, one that does not,
  # one whose declaration is broken. Composing them through one function is what
  # keeps that the only difference between them.
  defp start_with_executor(module, executor_pid, script, options \\ []) do
    extras = Keyword.get(options, :receipt_extras, %{})
    :persistent_term.put({AgentLoopAnsweringExecutor, :receipt_extras}, extras)

    model_pid = AgentLoopTestModel.start(script)
    {store_pid, store} = M1RuntimeTestStore.start_store(label: "agent-loop-answering")
    definitions = [Fixture.tool_definition()]

    {:ok, runtime} =
      Loopex.start_link(
        runtime_id: "answering-runtime-#{System.unique_integer([:positive])}",
        store: store,
        model: %{
          module: AgentLoopTestModel,
          model: "scripted:v1",
          options: [script: model_pid, max_tokens: 256]
        },
        executor: %{
          module: module,
          reference: executor_pid,
          identity: "answering-executor",
          epoch: 1,
          fencing_token: 3,
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

    %{
      runtime: runtime,
      model: model_pid,
      executor: executor_pid,
      store: store_pid,
      session_id: session_id,
      attachment: attachment
    }
  end

  defp one_call_script,
    do: [%{text: "run it", calls: [call("c1")]}, %{text: "done", calls: []}]

  test "a receipt lost after the effect ran ends the run outcome unknown rather than failed" do
    # `{:receipt_not_retained, reason}` is the executor saying the tool ran and
    # its answer could not be written down. The effect happened, in the
    # workspace, and nothing can now establish what it did — which is exactly
    # `docs/vision-technical.md`'s indeterminate effect, not a call that never
    # started. Reading it as an ordinary `failed` told the model the tool did not
    # run, dispatched it again, and finished the run `completed`.
    fixture =
      start_answering(
        %{"c1" => {:after_effect, {:error, {:receipt_not_retained, :enotdir}}}},
        one_call_script()
      )

    events = drain(fixture.attachment)

    # The effect really did land before the executor answered.
    assert AgentLoopAnsweringExecutor.effects(fixture.executor) == ["c1"]

    tool = Enum.find(events, &(&1.kind == "tool.finished"))
    assert tool["tool_call_id"] == "c1"
    assert tool["outcome"] == "outcome_unknown"
    refute tool["outcome"] == "failed"

    finished = Enum.find(events, &(&1.kind == "run.finished"))
    assert finished["outcome"] == "outcome_unknown"
    refute finished["outcome"] == "completed"

    # It carries the reference an operator reconciles the effect against.
    assert is_binary(finished["reconciliation_ref"])
    assert finished["reconciliation_ref"] =~ "reconciliation"

    # The model was asked exactly once. A second dispatch would be the loop
    # resuming past an outcome that is already terminal, carrying an effect
    # nobody can account for back to the model as a settled failure.
    assert length(AgentLoopTestModel.dispatched(fixture.model)) == 1
    Process.sleep(150)
    assert length(AgentLoopTestModel.dispatched(fixture.model)) == 1
  end

  test "a refusal that precedes the effect stays a terminal failed and the loop carries on" do
    # Nothing started: the executor refused the job at the validation that runs
    # immediately before an effect. There is no indeterminate effect to
    # reconcile, so the call takes a terminal `failed` fact the model can read
    # and act on, and the run finishes in the known state it is actually in.
    fixture =
      start_answering(
        %{"c1" => {:before_effect, {:error, :invalid_tool_arguments}}},
        one_call_script()
      )

    events = drain(fixture.attachment)

    assert AgentLoopAnsweringExecutor.effects(fixture.executor) == []

    tool = Enum.find(events, &(&1.kind == "tool.finished"))
    assert tool["outcome"] == "failed"

    finished = Enum.find(events, &(&1.kind == "run.finished"))
    assert finished["outcome"] == "completed"
    assert finished["reconciliation_ref"] == nil

    # The loop carried on, and the model was told what refused the call.
    assert [_first, second] = AgentLoopTestModel.dispatched(fixture.model)
    result = Enum.find(second.messages, &(&1["role"] == "tool"))
    assert result["outcome"] == "failed"
    assert result["content"] =~ "invalid_tool_arguments"
  end

  test "an executor error the runtime cannot place before the effect is unproven" do
    # The port declares `{:error, term()}` and nothing narrower, so an executor
    # may answer with a shape this runtime has never seen. `failed` asserts the
    # effect did not happen, which is a claim about an executor's internals that
    # no unrecognised term supports; the honest reading is that it is unproven.
    # `:job_id_conflict` is the shipped example — the local executor already
    # holds a receipt at this job's identity, so an effect ran under it.
    unknown =
      start_answering(
        %{"c1" => {:after_effect, {:error, :some_executor_specific_trouble}}},
        one_call_script()
      )

    unknown_finished = Enum.find(drain(unknown.attachment), &(&1.kind == "run.finished"))
    assert unknown_finished["outcome"] == "outcome_unknown"
    assert is_binary(unknown_finished["reconciliation_ref"])

    # An executor that answered `:ok` certainly ran. A reply this runtime cannot
    # read as a receipt is a lost answer to an effect that happened, and it took
    # the same `failed` path as a refusal for exactly the same reason.
    malformed =
      start_answering(
        %{"c1" => {:after_effect, {:ok, "not a receipt"}}},
        one_call_script()
      )

    malformed_finished = Enum.find(drain(malformed.attachment), &(&1.kind == "run.finished"))
    assert malformed_finished["outcome"] == "outcome_unknown"
    assert length(AgentLoopTestModel.dispatched(malformed.model)) == 1
  end

  test "an executor that declares nothing has every error read as unproven" do
    # Concept: the port is open, so the coordinator meets executors it did not
    # ship and must not read their error names as though it had.
    #
    # Technical depth: this executor loses its workspace lease halfway through
    # the effect and answers `{:error, :workspace_lease_lost}` -- the same name
    # the shipped local executor uses for a refusal that precedes every start.
    # The deleted allowlist matched on that name, committed an ordinary `failed`,
    # told the model the tool had not run, and let the loop carry on past an
    # effect already in a workspace this executor no longer held: the exact
    # defect this milestone repaired, reintroduced through the port. Because this
    # executor exports no `refused_before_effect?/1`, it has declared nothing,
    # and nothing is what the coordinator believes.
    fixture =
      start_with_executor(
        AgentLoopUndeclaringExecutor,
        AgentLoopUndeclaringExecutor.start(%{"c1" => {:error, :workspace_lease_lost}}),
        one_call_script()
      )

    events = drain(fixture.attachment)

    # The effect really did run under this executor before it answered.
    assert AgentLoopUndeclaringExecutor.effects(fixture.executor) == ["c1"]

    tool = Enum.find(events, &(&1.kind == "tool.finished"))
    assert tool["tool_call_id"] == "c1"
    assert tool["outcome"] == "outcome_unknown"
    refute tool["outcome"] == "failed"

    finished = Enum.find(events, &(&1.kind == "run.finished"))
    assert finished["outcome"] == "outcome_unknown"
    refute finished["outcome"] == "completed"
    assert is_binary(finished["reconciliation_ref"])

    # The loop stopped. A resumed loop is what the name-matching classification
    # produced, and it is the observable this case exists to refuse.
    assert length(AgentLoopTestModel.dispatched(fixture.model)) == 1
    Process.sleep(150)
    assert length(AgentLoopTestModel.dispatched(fixture.model)) == 1
  end

  test "an answer that reaches for the pre-start tag and misses its shape declares nothing" do
    # Concept: an executor declares by returning one exact shape, and a shape can
    # be got wrong. A missed declaration is not a statement that the effect did
    # not happen.
    #
    # Technical depth: the tag is required literally rather than approximately. A
    # bare `:refused_before_effect` atom, a one-element `{:refused_before_effect}`
    # tuple, and a term that is not an `{:error, _}` at all are the three ways an
    # implementation can plainly have meant to declare and not have declared. All
    # three reach the same place a silent executor reaches, because the runtime
    # believes only what an executor actually said -- and this double ran its
    # effect before answering, so believing any of them would be believing a
    # falsehood about a workspace.
    for mode <- [:bare_atom, :wrong_arity, :not_an_error] do
      fixture =
        start_with_executor(
          AgentLoopBrokenDeclarationExecutor,
          AgentLoopBrokenDeclarationExecutor.start(mode),
          one_call_script()
        )

      events = drain(fixture.attachment)

      assert AgentLoopBrokenDeclarationExecutor.effects(fixture.executor) == ["c1"]

      tool = Enum.find(events, &(&1.kind == "tool.finished"))

      assert tool["outcome"] == "outcome_unknown",
             "a #{mode} answer was read as a refusal that preceded the effect"

      finished = Enum.find(events, &(&1.kind == "run.finished"))
      assert finished["outcome"] == "outcome_unknown"
      assert length(AgentLoopTestModel.dispatched(fixture.model)) == 1
    end
  end

  test "a pre-start refusal is read from the answer's shape and not from the error's name" do
    # Concept: the same error name means opposite things from two executors, and
    # only the executor that produced it can say which.
    #
    # Technical depth: both executors here answer with the name
    # `:workspace_lease_lost`. One refuses before it records an effect and wears
    # the tag; the other has already run the effect and returns the name bare. A
    # classification that reads the name gives them the same answer, and exactly
    # one of those answers is true of each -- which is the defect this milestone
    # repaired and the one the port could reintroduce.
    #
    # The pair is driven end to end rather than asserted against a classifier,
    # because what matters is the outcome an operator is shown, and because a
    # classifier that is not on the path is not evidence that the path uses it.
    declared =
      start_with_executor(
        AgentLoopAnsweringExecutor,
        AgentLoopAnsweringExecutor.start(%{
          "c1" => {:before_effect, {:error, :workspace_lease_lost}}
        }),
        one_call_script()
      )

    declared_events = drain(declared.attachment)

    assert AgentLoopAnsweringExecutor.effects(declared.executor) == [],
           "the declaring double recorded an effect, so its refusal is not one"

    declared_tool = Enum.find(declared_events, &(&1.kind == "tool.finished"))

    assert declared_tool["outcome"] == "failed",
           "a refusal the executor tagged was not read as one"

    # The committed failure carries the executor's own reason and not the
    # wrapper it travelled in. The reason is model-facing content, so the next
    # request is where it is observable -- and a tag left on it would be this
    # runtime's private vocabulary leaking into a conversation.
    declared_requests = AgentLoopAnsweringExecutor.jobs(declared.executor)
    assert length(declared_requests) == 1

    resumed =
      inspect(AgentLoopTestModel.dispatched(declared.model),
        limit: :infinity,
        printable_limit: :infinity
      )

    assert resumed =~ "workspace_lease_lost",
           "the committed failure lost the reason the executor gave"

    refute resumed =~ "refused_before_effect",
           "the runtime's own tag reached the model as part of the tool's reason"

    undeclared =
      start_with_executor(
        AgentLoopUndeclaringExecutor,
        AgentLoopUndeclaringExecutor.start(%{"c1" => {:error, :workspace_lease_lost}}),
        one_call_script()
      )

    undeclared_events = drain(undeclared.attachment)

    assert AgentLoopUndeclaringExecutor.effects(undeclared.executor) == ["c1"],
           "the undeclaring double did not run the effect this case is about"

    undeclared_tool = Enum.find(undeclared_events, &(&1.kind == "tool.finished"))

    assert undeclared_tool["outcome"] == "outcome_unknown",
           "the same error name from an executor that declared nothing was read as a refusal"

    finished = Enum.find(undeclared_events, &(&1.kind == "run.finished"))
    assert finished["outcome"] == "outcome_unknown"

    assert length(AgentLoopTestModel.dispatched(undeclared.model)) == 1,
           "the loop resumed past an effect nobody could account for"
  end

  test "a tool stream closes on the count this runtime published rather than the executor's own" do
    # Concept: the closing item is this coordinator's statement about the stream
    # it published, so it cannot be an executor's claim passed along.
    #
    # Technical depth: a completed stream closed with the receipt's
    # `progress_count`. That is the executor's count of what it emitted, and the
    # port declares no relationship between it and what a coordinator accepted --
    # it could not, because refusal happens here, after the executor is done. The
    # executor below emits three events and reports three; two carry a wrong
    # binding and never reach the operator, so the stream carried one. Closing it
    # at three tells a consumer that two items were lost on the transient plane,
    # which is the one reading of a closing count that matters and the one thing
    # that did not happen.
    _fixture = start_with_progress(:one_valid_two_refused)

    items = receive_progress()

    progress = Enum.filter(items, &(&1.kind == :tool_progress))
    assert length(progress) == 1
    assert [%{chunk: "kept", progress_sequence: 0}] = progress

    closure = Enum.find(items, &(&1.kind == :tool_stream_closed))
    assert closure, "the tool stream was never closed"
    assert closure.disposition == :complete

    assert closure.progress_count == 1,
           "the closing item carried the executor's count of three rather than the one item " <>
             "this runtime published"

    # The two that were refused are still visible, as refusals rather than as
    # progress that went missing.
    refusal = Enum.find(diagnostics(), &(&1["kind"] == "executor_progress_refused"))
    assert refusal["refused_count"] == 2
  end

  test "an abandoned model stream closes on the count this runtime published rather than zero" do
    # Concept: an abandoned domain still owes a truthful total, and the only
    # total anyone can vouch for is the one this coordinator published.
    #
    # Technical depth: a completed attempt closes with the producer's own
    # `delta_count`, which it can know; an abandoned one has no reply to read a
    # count from, so the coordinator closes it with what it counted itself. Both
    # abandoned call sites pass zero for the reported count, so replacing the
    # counter with that argument makes every abandoned model domain announce a
    # total of zero -- and it left the whole suite green, because every clause-2
    # assertion about an abandoned closure builds the closure itself with a
    # test-supplied count and the only coordinator-driven model closure in the
    # repository is a complete one.
    #
    # Scenario: a provider streams three deltas and the attempt then fails. The
    # operator's terminal holds sequences 0, 1 and 2 and receives a closure
    # declaring nothing was sent. A consumer doing the gap check the algebra asks
    # for sees three items under a total of zero, and the fallback to the durable
    # record never fires because nothing looks missing.
    script = [
      %{text: "", calls: [], deltas: ["a", "b", "c"], error: :provider_unavailable},
      %{text: "done", calls: []}
    ]

    fixture = start(script: script, progress_to: self())
    {_session_id, attachment, _reply} = Fixture.run(fixture, "go")
    _events = drain(attachment)

    observed = receive_progress()

    closures = Enum.filter(observed, &(Map.get(&1, :kind) == :model_stream_closed))
    abandoned = Enum.find(closures, &(&1.disposition == :abandoned))

    assert abandoned, "the failed attempt's domain was never closed: #{inspect(closures)}"

    delivered =
      observed
      |> Enum.filter(&(Map.get(&1, :kind) == :text_delta))
      |> Enum.filter(&(&1.stream_domain_id == abandoned.stream_domain_id))

    assert length(delivered) == 3,
           "this case no longer drives an abandoned domain that carried deltas"

    assert abandoned.delta_count == 3,
           "an abandoned domain that carried #{length(delivered)} deltas closed on " <>
             "#{abandoned.delta_count}, so a consumer's gap check reports loss that did not happen"

    # The retry's own domain is separate and closes on its own count, so the two
    # are never compared or concatenated.
    complete = Enum.find(closures, &(&1.disposition == :complete))
    assert complete
    refute complete.stream_domain_id == abandoned.stream_domain_id
  end

  test "a delta carrying a field its kind does not declare is refused rather than projected" do
    # Concept: an adapter supplies content. The domain, the sequence and the turn
    # are this coordinator's statements about a stream it opened, and a field
    # nobody named is neither bounded nor understood.
    #
    # Technical depth: two holes met here. The shape check admitted any plain
    # map while the byte ceiling measured four recognised names, so a field
    # nobody had named was neither refused nor counted -- a megabyte of
    # `vendor_blob` beside a short `text` measured as the length of the text and
    # crossed onto the progress plane. And an adapter could carry
    # `"stream_domain_id"` and `"model_sequence"` as *string* keys, which the
    # coordinator's atom-keyed labels do not overwrite, so an item reached a
    # consumer wearing two contradictory sequences.
    #
    # Admitting an exact field set per kind closes both. A forged label is now
    # refused outright rather than overwritten, which is the stronger answer: an
    # item that tried to name its own domain never reaches the plane at all.
    for forged <- [
          %{stream_domain_id: "not-this-domain", model_sequence: 0},
          %{"stream_domain_id" => "not-this-domain", "model_sequence" => 0},
          %{turn_id: "not-this-turn"},
          %{vendor_blob: String.duplicate("x", 1_000_000)}
        ] do
      fixture =
        start(
          script: [%{text: "abc", calls: [], deltas: ["a"], forged_labels: forged}],
          progress_to: self()
        )

      {_session_id, attachment, _reply} = Fixture.run(fixture, "go")
      _events = drain(attachment)

      observed = receive_progress()
      deltas = Enum.filter(observed, &(Map.get(&1, :kind) == :text_delta))

      assert deltas == [],
             "a delta carrying #{inspect(Map.keys(forged))} reached the operator: " <>
               inspect(deltas)
    end

    # The ceiling still bounds an admitted field. With the field set exact,
    # measuring "every field" and measuring the four content names are the same
    # measurement for every admitted shape, so no mutant distinguishes them --
    # what must be driven is that an oversized *admitted* field is refused.
    oversized =
      start(
        script: [%{text: "big", calls: [], deltas: [String.duplicate("x", 1_000_000)]}],
        progress_to: self()
      )

    {_session_id, oversized_attachment, _reply} = Fixture.run(oversized, "go")
    _events = drain(oversized_attachment)

    assert Enum.filter(receive_progress(), &(Map.get(&1, :kind) == :text_delta)) == [],
           "a delta past the declared byte ceiling reached the operator"

    # And the mechanism still projects an ordinary delta, so the case above is
    # about the extra field rather than about the fixture.
    clean = start(script: [%{text: "ab", calls: [], deltas: ["a", "b"]}], progress_to: self())
    {_session_id, attachment, _reply} = Fixture.run(clean, "go")
    _events = drain(attachment)

    observed = receive_progress()
    deltas = Enum.filter(observed, &(Map.get(&1, :kind) == :text_delta))

    assert Enum.map(deltas, & &1.model_sequence) == [0, 1]
    assert Enum.all?(deltas, &is_binary(&1.stream_domain_id))
  end

  test "the run's terminal reports the cleanup period the executor that answered it declared" do
    # Concept: ADR 0009 requires the declared cleanup grace to be reported in the
    # terminal outcome's evidence, so an operator can tell a clean cooperative
    # stop from a forced kill that was confirmed and from a termination that
    # could not be confirmed at all.
    #
    # Technical depth: the shipped executor wrote it into every receipt and the
    # coordinator's receipt reconstruction dropped it, so a session rebuilt from
    # the journal could not name the period a job had run under and no terminal
    # reported it. That was recorded as a limitation and deferred; it is
    # implemented instead. The value comes from the receipt rather than from
    # anything this session decided, because the period is the executor's
    # declaration.
    #
    # An executor that declares none -- one with no operating-system work to
    # bound -- reports none. That is an absence rather than a default nobody
    # named, which is why the field is optional on the way in.
    declared =
      start_with_executor(
        AgentLoopAnsweringExecutor,
        AgentLoopAnsweringExecutor.start(%{}),
        one_call_script(),
        receipt_extras: %{cleanup_grace_ms: 750}
      )

    finished = Enum.find(drain(declared.attachment), &(&1.kind == "run.finished"))

    assert finished["outcome"] == "completed"

    assert finished["cleanup_grace_ms"] == 750,
           "the run's terminal did not report the period its executor declared: " <>
             inspect(finished["cleanup_grace_ms"])

    silent =
      start_with_executor(
        AgentLoopAnsweringExecutor,
        AgentLoopAnsweringExecutor.start(%{}),
        one_call_script()
      )

    silent_finished = Enum.find(drain(silent.attachment), &(&1.kind == "run.finished"))

    assert silent_finished["cleanup_grace_ms"] == nil,
           "a run whose executor declared no period reported one anyway"
  end

  test "a model delta emitted after its stream is closed is neither projected nor counted" do
    # Concept: the model side has the same algebra as the executor side and had
    # none of the protection.
    #
    # Technical depth: the executor stream carried a closed flag; the model
    # stream carried nothing at all, so a retained adapter callback emitted into
    # a closed domain with a sequence past the total that domain's own closure
    # had already published. The flag was also check-then-act -- read the flag,
    # get preempted, a closer publishes, then increment and emit -- so it was a
    # narrower window rather than none. Both are one compare-and-exchange on the
    # counter itself now: reserving a sequence and sealing are the same
    # operation, and there is no interleaving in which an item is emitted that
    # the closing total does not include.
    #
    # The retained callback is the reachable form of the race. It cannot
    # schedule the preemption, but it proves the state the preemption would
    # reach: a producer holding a live callback for a domain that has closed.
    fixture =
      start(script: [%{text: "ab", calls: [], deltas: ["a", "b"]}], progress_to: self())

    {_session_id, attachment, _reply} = Fixture.run(fixture, "go")
    _events = drain(attachment)

    observed = receive_progress()
    closure = Enum.find(observed, &(Map.get(&1, :kind) == :model_stream_closed))

    assert closure, "the model stream was never closed"
    assert closure.delta_count == 2

    progress = AgentLoopTestModel.retained_progress(fixture.model)
    assert is_function(progress, 1), "the model double did not retain its callback"

    assert progress.(%{kind: :text_delta, content_index: 0, text: "after the closure"}) == :ok

    late = receive_progress()

    refute Enum.any?(late, &(Map.get(&1, :kind) == :text_delta)),
           "a delta emitted after its stream closed was projected to the operator"

    refute Enum.any?(late, &(Map.get(&1, :kind) == :model_stream_closed)),
           "a second closure was emitted for a domain already closed"
  end

  test "an event emitted after its stream is closed is neither projected nor counted" do
    # Concept: a closed domain stays closed. The executor still holding the
    # callback cannot reopen it.
    #
    # Technical depth: closing emits the total and deletes this coordinator's
    # record of the stream — but the function handed to the executor is a closure
    # over the sink and the counter, and it outlives that deletion. Nothing in
    # the coordinator could refuse a later call, because the coordinator no
    # longer knew the stream existed. A buffered chunk, or a progress call
    # racing its own return, was therefore projected into a closed domain at a
    # sequence past the total its own closure had just declared — which is
    # exactly the loss a consumer uses that total to detect, reported for an
    # event that was not lost at all.
    #
    # The count is the assertion that matters. A late event that is merely not
    # emitted, but still increments the counter, has corrupted a total that was
    # already published.
    fixture = start_with_progress(:valid)

    items = receive_progress()
    closure = Enum.find(items, &(&1.kind == :tool_stream_closed))

    assert closure, "the tool stream was never closed"
    assert closure.progress_count == 2

    before = Enum.count(items, &(&1.kind == :tool_progress))
    assert before == 2

    # The executor calls the callback once more, after its job has answered and
    # after the closure above was published. It is a well-formed event carrying
    # the live call's whole identity: nothing about it is refusable except that
    # it is late.
    [job] = AgentLoopProgressExecutor.jobs(fixture.executor)
    progress = AgentLoopProgressExecutor.retained_progress(fixture.executor)
    assert is_function(progress, 1), "the double did not retain its callback"

    late =
      AgentLoopProgressExecutor.identity(job)
      |> Map.merge(%{stream: "stdout", byte_offset: 999, chunk: "after the closure"})

    assert progress.(late) == :ok

    after_items = receive_progress()

    refute Enum.any?(after_items, &(&1.kind == :tool_progress)),
           "an event emitted after its stream closed was projected to the operator"

    refute Enum.any?(after_items, &(&1.kind == :tool_stream_closed)),
           "a second closure was emitted for a domain already closed"

    # And it was not counted as a refusal either: a refusal is this runtime's
    # judgement about an event's identity, and this event's identity is correct.
    refusal = Enum.find(diagnostics(), &(&1["kind"] == "executor_progress_refused"))

    refute refusal,
           "a late but well-formed event was reported as a binding refusal: #{inspect(refusal)}"
  end

  test "an abandoned tool stream closes on the count this runtime published rather than a claim" do
    # Concept: a stream that was abandoned still has to say truthfully how many
    # items crossed it, and there is nobody left to ask.
    #
    # Technical depth: the case above proves the completed closure. It is silent
    # about the abandoned one, and the two reach the closing item by different
    # paths: a completed job has a receipt whose `progress_count` is at least a
    # number, while an abandoned one has no receipt at all. A closure built from
    # anything but this coordinator's own count of what it published is therefore
    # not merely wrong here, it is unsourced -- and a consumer reading a closure
    # of three against one delivered item concludes that two were lost on the
    # transient plane, which is the reading that matters and the thing that did
    # not happen.
    #
    # This executor emits the same three events, one accepted and two refused,
    # and then answers `{:receipt_not_retained, :enospc}`: the effect ran and its
    # account is gone. The run ends `outcome_unknown` for that reason, which is a
    # separate guarantee proved elsewhere and asserted here only so the case
    # fails loudly if it stops driving the path it claims to drive.
    _fixture = start_with_progress(:one_valid_two_refused_then_lost)

    items = receive_progress()

    progress = Enum.filter(items, &(&1.kind == :tool_progress))
    assert length(progress) == 1
    assert [%{chunk: "kept", progress_sequence: 0}] = progress

    closure = Enum.find(items, &(&1.kind == :tool_stream_closed))
    assert closure, "the abandoned tool stream was never closed"

    assert closure.disposition == :abandoned,
           "this case no longer drives an abandoned closure, so it proves nothing about one"

    assert closure.progress_count == 1,
           "the closing item on an abandoned stream carried a count of " <>
             "#{closure.progress_count} against the one item this runtime published"

    refusal = Enum.find(diagnostics(), &(&1["kind"] == "executor_progress_refused"))
    assert refusal["refused_count"] == 2
  end
end
