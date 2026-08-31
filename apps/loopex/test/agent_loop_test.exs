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
    {:ok, pid} =
      Agent.start_link(fn -> %{mode: mode, jobs: [], effects: [], progress: nil} end)

    pid
  end

  def jobs(pid), do: Agent.get(pid, & &1.jobs) |> Enum.reverse()
  def effects(pid), do: Agent.get(pid, & &1.effects) |> Enum.reverse()

  @impl Loopex.Executor
  def cancel(_pid, _job_id), do: {:ok, :cleaned}

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

    case mode do
      {held_mode, observer}
      when held_mode in [
             :held_after_effect,
             :held_after_effect_and_progress,
             :held_after_effect_with_refusal,
             :held_after_effect_then_lost
           ] and is_pid(observer) ->
        :ok =
          Agent.update(pid, fn state ->
            %{state | effects: [job.tool_call_id | state.effects]}
          end)

        send(observer, {:executor_effect_held, self()})

        receive do
          :release -> :ok
        after
          5_000 -> :ok
        end

        progress.(chunk(job, 1, 17, "after succession"))

        if held_mode == :held_after_effect_and_progress do
          send(observer, {:executor_progress_held, self()})

          receive do
            :release_after_progress -> :ok
          after
            5_000 -> :ok
          end
        end

      _other ->
        :ok
    end

    # Concept: an executor that emitted progress and then could not produce a
    # receipt at all.
    #
    # Technical depth: the stream is closed `abandoned` rather than `complete`,
    # and there is no receipt, so the executor's own count does not exist to be
    # passed along. That is precisely the closure a count taken from the receipt
    # cannot describe, and the one a case that only ever drives a completed job
    # never reaches.
    case mode do
      :one_valid_two_refused_then_lost ->
        {:error, {:receipt_not_retained, :enospc}}

      {held_mode, _observer}
      when held_mode in [
             :held_after_effect,
             :held_after_effect_and_progress,
             :held_after_effect_with_refusal
           ] ->
        {:ok, receipt(job, length(events) + 1)}

      {:held_after_effect_then_lost, _observer} ->
        {:error, {:receipt_not_retained, :enospc}}

      _other ->
        {:ok, receipt(job, length(events))}
    end
  end

  def identity(job) do
    %{
      protocol_version: job.protocol_version,
      job_id: job.job_id,
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

  defp chunk(job, sequence, offset, text),
    do:
      Map.merge(identity(job), %{
        progress_sequence: sequence,
        stream: "stdout",
        byte_offset: offset,
        chunk: text
      })

  defp events(:valid, job), do: [chunk(job, 0, 0, "first"), chunk(job, 1, 5, "second")]

  defp events({:held_after_effect, _observer}, job),
    do: [chunk(job, 0, 0, "before succession")]

  defp events({:held_after_effect_then_lost, _observer}, job),
    do: [chunk(job, 0, 0, "before succession")]

  defp events({:held_after_effect_and_progress, _observer}, job),
    do: [chunk(job, 0, 0, "before succession")]

  defp events({:held_after_effect_with_refusal, _observer}, job) do
    [
      chunk(job, 0, 0, "before succession"),
      %{chunk(job, 1, 17, "refused before succession") | attempt: job.attempt + 1}
    ]
  end

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
    event = chunk(job, 0, 0, "tampered")
    [Map.put(event, binding, tamper(Map.fetch!(event, binding)))]
  end

  defp events({:missing, binding}, job) do
    event = chunk(job, 0, 0, "missing")
    [Map.delete(event, binding)]
  end

  defp events(:wrong_attempt, job),
    do: [%{chunk(job, 0, 0, "stale") | attempt: job.attempt + 1}]

  defp events(:wrong_fence, job),
    do: [%{chunk(job, 0, 0, "fenced") | fencing_token: job.fencing_token + 1}]

  defp events(:wrong_digest, job),
    do: [%{chunk(job, 0, 0, "other") | canonical_request_digest: "not-the-digest"}]

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
      chunk(job, 0, 0, "kept"),
      %{chunk(job, 1, 4, "stale") | attempt: job.attempt + 1},
      %{chunk(job, 1, 4, "fenced") | fencing_token: job.fencing_token + 1}
    ]
  end

  defp events(:one_valid_two_refused_one_valid, job),
    do: events(:one_valid_two_refused, job) ++ [chunk(job, 1, 4, "kept after refusals")]

  defp events(:payload_refusal_preserves_executor_gap, job) do
    [
      chunk(job, 0, 0, "ok"),
      %{chunk(job, 1, 2, "refused") | stream: "telemetry"},
      chunk(job, 2, 2, "after gap")
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
      Map.merge(chunk(job, 0, 0, "ok"), %{
        owner: self(),
        finish: fn -> :ok end,
        credential: "sk-not-a-real-secret"
      }),
      %{chunk(job, 1, 0, "warning") | stream: "stderr"},
      %{chunk(job, 2, 0, "half way") | stream: "progress"},
      %{chunk(job, 3, 0, "not a declared stream") | stream: "telemetry"},
      chunk(job, 4, -1, "negative offset"),
      chunk(job, 5, 3, "gap"),
      chunk(job, 6, 2, String.duplicate("x", 70_000))
    ]
  end

  # Kept below every `events/2` clause rather than beside the one that calls it:
  # a private helper written between two clauses of the same name and arity
  # splits them, and a split definition is a compile warning. The gate's selector
  # runner refuses a warning, so the placement is not a style preference.
  defp tamper(value) when is_integer(value), do: value + 1
  defp tamper(value) when is_binary(value), do: value <> "-not-this-one"

  def receipt(job, progress_count) do
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

defmodule Loopex.AgentLoopControlBoundaryProxy do
  @moduledoc false

  # Concept: expose the one ownership operation a predecessor is about to use,
  # without replacing the runtime Control that actually owns succession.
  #
  # Technical depth: the production coordinator is pointed at this forwarding
  # process only inside one test. A raw `current_owner` precheck is forwarded
  # before the test starts handoff and its answer is held; an atomic
  # `close_progress` call is held before it reaches Control. Releasing either
  # after Control has begun acquisition deterministically distinguishes a stale
  # check-then-close from the serialized close operation.
  def start(real_control, observer, mode \\ true)
      when is_pid(real_control) and is_pid(observer) and
             (is_boolean(mode) or
                (is_tuple(mode) and tuple_size(mode) == 3 and elem(mode, 0) == :reply_once)) do
    spawn_link(fn -> loop(real_control, observer, mode) end)
  end

  def arm(proxy) when is_pid(proxy), do: GenServer.call(proxy, :arm)

  def release(proxy, reference) when is_pid(proxy) and is_reference(reference),
    do: send(proxy, {:release, reference})

  defp loop(real_control, observer, true = armed) do
    receive do
      {:"$gen_call", from, {:current_owner, _session_id, _owner} = request} ->
        reply = GenServer.call(real_control, request, :infinity)
        hold_and_reply(real_control, observer, from, request, :current_owner, reply)

      {:"$gen_call", from, {:close_progress, _session_id, _owner, _relay, _disposition} = request} ->
        hold_and_reply(real_control, observer, from, request, :close_progress, :forward)

      {:"$gen_call", from, {:project_progress, _session_id, _owner, _relay, _item} = request} ->
        hold_and_reply(real_control, observer, from, request, :project_progress, :forward)

      {:"$gen_call", from, {:post_commit, _session_id, _owner, _positions, _receipt} = request} ->
        reply = GenServer.call(real_control, request, :infinity)
        hold_and_reply(real_control, observer, from, request, :post_commit, reply)

      {:"$gen_call", from, request} ->
        GenServer.reply(from, GenServer.call(real_control, request, :infinity))
        loop(real_control, observer, armed)
    end
  end

  defp loop(real_control, observer, false) do
    receive do
      {:"$gen_call", from, :arm} ->
        GenServer.reply(from, :ok)
        loop(real_control, observer, true)

      {:"$gen_call", from, request} ->
        GenServer.reply(from, GenServer.call(real_control, request, :infinity))
        loop(real_control, observer, false)
    end
  end

  # Concept: make one unavailable ownership answer observable without replacing
  # the runtime Control that still owns the session.
  #
  # Technical depth: this is a boundary fault, not a substitute implementation.
  # Every non-target call reaches the real Control, the matching call receives
  # exactly one injected reply, and the proxy then disarms. That lets a runtime
  # case distinguish unavailability from a real owner-loss verdict while the
  # live current-owner slot remains authoritative and independently checkable.
  defp loop(real_control, observer, {:reply_once, boundary, reply} = mode) do
    receive do
      {:"$gen_call", from, request} ->
        if boundary_of(request) == boundary do
          send(observer, {:control_boundary_injected, self(), boundary, reply})
          GenServer.reply(from, reply)
          loop(real_control, observer, false)
        else
          GenServer.reply(from, GenServer.call(real_control, request, :infinity))
          loop(real_control, observer, mode)
        end
    end
  end

  defp boundary_of({:current_owner, _session_id, _owner}), do: :current_owner

  defp boundary_of({:close_progress, _session_id, _owner, _relay, _disposition}),
    do: :close_progress

  defp boundary_of({:project_progress, _session_id, _owner, _relay, _item}),
    do: :project_progress

  defp boundary_of({:post_commit, _session_id, _owner, _positions, _receipt}),
    do: :post_commit

  defp boundary_of(_request), do: :other

  defp hold_and_reply(real_control, observer, from, request, boundary, prepared) do
    reference = make_ref()
    send(observer, {:control_boundary_waiting, self(), reference, boundary})

    receive do
      {:release, ^reference} ->
        reply =
          case prepared do
            :forward -> GenServer.call(real_control, request, :infinity)
            reply -> reply
          end

        GenServer.reply(from, reply)
        loop(real_control, observer, false)
    end
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
    {:ok, pid} =
      Agent.start_link(fn -> %{answers: answers, jobs: [], effects: [], waiting: nil} end)

    pid
  end

  def jobs(pid), do: Agent.get(pid, & &1.jobs) |> Enum.reverse()

  def effects(pid), do: Agent.get(pid, & &1.effects) |> Enum.reverse()

  @impl Loopex.Executor
  def cancel(pid, _job_id) do
    case Agent.get(pid, & &1.waiting) do
      waiting when is_pid(waiting) ->
        send(waiting, :answer)
        Process.sleep(120)

      nil ->
        :ok
    end

    {:ok, :cleaned}
  end

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

      # Concept: a receipt that becomes available while cancellation is being
      # reduced, rather than before or after it.
      #
      # Technical depth: `cancel/2` releases this worker and waits long enough
      # for its answer to reach the coordinator mailbox. Cleanup must validate
      # that answer before choosing the stream's complete disposition, exactly
      # as the ordinary result path does.
      {:held_after_effect, observer} when is_pid(observer) ->
        worker = self()

        :ok =
          Agent.update(pid, fn state ->
            %{state | effects: [job.tool_call_id | state.effects], waiting: worker}
          end)

        send(observer, {:executor_receipt_held, worker})

        receive do
          :answer -> :ok
        after
          4_000 -> :ok
        end

        :ok = Agent.update(pid, &%{&1 | waiting: nil})

        {:ok, receipt(job)}

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

defmodule Loopex.AgentLoopSilentExecutor do
  @moduledoc false

  # Concept: an older or nonconforming executor that exports no cancellation at
  # all.
  #
  # Technical depth: the facade remains fail-closed when it encounters this
  # shape at runtime even though a conforming executor must implement the
  # callback. What it may conclude from silence is still nothing.
  def execute(_reference, _job, _grant, _options, progress \\ nil) do
    _progress = progress || Loopex.Executor.discard_progress()
    {:error, {:refused_before_effect, :not_implemented}}
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
  def cancel(_pid, _job_id), do: {:ok, :unconfirmed}

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
  def cancel(_pid, _job_id), do: {:ok, :unconfirmed}

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
  alias Loopex.Runtime.Control
  alias Loopex.Runtime.ExecutorStream
  alias Loopex.Runtime.StreamRelay
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
  defp start_with_progress(
         mode,
         script \\ [
           %{text: "run it", calls: [call("c1")]},
           %{text: "done", calls: []}
         ]
       ) do
    model_pid = AgentLoopTestModel.start(script)

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

    events = drain(attachment)

    %{
      runtime: runtime,
      executor: executor_pid,
      store: store_pid,
      session_id: session_id,
      events: events
    }
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

  defp await_superseded(coordinator, attempts \\ 300) do
    case :sys.get_state(coordinator) do
      %{superseded: true} ->
        true

      _state when attempts > 0 ->
        Process.sleep(10)
        await_superseded(coordinator, attempts - 1)

      _state ->
        false
    end
  catch
    :exit, _reason -> false
  end

  defp await_process_message(process, matches?, attempts \\ 300) do
    case Process.info(process, :messages) do
      {:messages, messages} ->
        cond do
          Enum.any?(messages, matches?) ->
            true

          attempts > 0 ->
            Process.sleep(10)
            await_process_message(process, matches?, attempts - 1)

          true ->
            false
        end

      nil ->
        false
    end
  end

  defp await_worker_result_drain(coordinator, abort, attempts \\ 100_000) do
    info = Process.info(coordinator, [:status, :current_function])

    cond do
      is_list(info) and Keyword.get(info, :status) == :waiting and
          Keyword.get(info, :current_function) ==
            {Loopex.Runtime.SessionCoordinator, :take_worker_result, 1} ->
        :waiting

      attempts == 0 ->
        {:timeout, info}

      true ->
        case Task.yield(abort, 0) do
          nil ->
            :erlang.yield()
            await_worker_result_drain(coordinator, abort, attempts - 1)

          result ->
            {:returned, result}
        end
    end
  end

  defp admit_abort_before_queued_model_result(fixture, attachment, model, command_id) do
    coordinator = coordinator_of(fixture.runtime)

    [{reference, {:model, run_id, _worker}}] =
      coordinator
      |> :sys.get_state()
      |> Map.fetch!(:in_flight)
      |> Map.to_list()

    :ok = :sys.suspend(coordinator)

    on_exit(fn ->
      if Process.alive?(coordinator) do
        try do
          :sys.resume(coordinator)
        catch
          :exit, _reason -> :ok
        end
      end
    end)

    abort =
      Task.async(fn ->
        Loopex.command(attachment, %{type: :abort, command_id: command_id})
      end)

    assert await_process_message(coordinator, fn
             {:"$gen_call", _from, {:command, _owner, %{type: :abort}}} -> true
             _other -> false
           end)

    send(model, :release)

    assert await_process_message(coordinator, fn
             {^reference, _result} -> true
             _other -> false
           end)

    :ok = :sys.resume(coordinator)
    assert {:accepted, ^command_id} = Task.await(abort, 5_000)

    {run_id, drain(attachment)}
  end

  defp retain_late_model_evidence(turn, command_id) do
    parent = self()

    fixture =
      start(
        script: [Map.put(turn, :hold, parent)],
        diagnostics_to: parent
      )

    {session_id, attachment, _reply} = Fixture.run(fixture, "go")
    assert_receive {:holding, model}, 2_000

    {run_id, events} =
      admit_abort_before_queued_model_result(fixture, attachment, model, command_id)

    records = Fixture.records(fixture, session_id)

    assert [%{payload: evidence}] =
             Enum.filter(records, &(&1.payload[:kind] == "model_attempt_evidence_retained"))

    {run_id, events, records, evidence}
  end

  defp full_record_boundary_text(request) do
    size = greatest_candidate_text_size(request, 0, 65_536)
    text = String.duplicate("x", size)
    reply = model_reply_for_boundary(request, text)

    :ok =
      Loopex.Store.validate_private_record(%{
        "reply" => reply,
        kind: "model_reply_candidate"
      })

    {:error, _reason} =
      Loopex.Store.validate_private_record(%{
        "run_id" => "run_00000000000000000000000000000000",
        "attempt" => 1,
        "termination" => "abort",
        "evidence" => %{"kind" => "reply", "reply" => reply},
        kind: "model_attempt_evidence_retained"
      })

    text
  end

  defp greatest_candidate_text_size(_request, low, high) when low == high, do: low

  defp greatest_candidate_text_size(request, low, high) do
    candidate = div(low + high + 1, 2)
    text = String.duplicate("x", candidate)

    if :ok ==
         Loopex.Store.validate_private_record(%{
           "reply" => model_reply_for_boundary(request, text),
           kind: "model_reply_candidate"
         }) do
      greatest_candidate_text_size(request, candidate, high)
    else
      greatest_candidate_text_size(request, low, candidate - 1)
    end
  end

  defp model_reply_for_boundary(request, text) do
    %{
      text: text,
      identity: %{provider: "scripted", model: request.model, endpoint: "in-process"},
      usage: %{},
      tool_calls: [],
      delta_count: 0,
      streamed: false,
      provider_response_id: "req-boundary",
      canonical_request_bytes: request.canonical_request_bytes,
      staged_request_digest: request.staged_request_digest
    }
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

  # Concept: wait for the terminal item of a tool progress domain.
  #
  # Technical depth: a Store refusal deliberately kills the session owner, so
  # there is no run terminal for `drain/2` to await. The closure itself is the
  # observable under test; polling it by message rather than sleeping keeps the
  # case deterministic even on a loaded scheduler.
  defp await_tool_closure(acc \\ [], attempts \\ 500) do
    receive do
      {:loopex_progress, %{kind: :tool_stream_closed} = closure} ->
        {Enum.reverse(acc), closure}

      {:loopex_progress, item} ->
        await_tool_closure([item | acc], attempts)
    after
      10 ->
        if attempts > 0 do
          await_tool_closure(acc, attempts - 1)
        else
          flunk("no tool stream closure arrived; progress: #{inspect(Enum.reverse(acc))}")
        end
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

  test "a model tool call preserves a JSON number argument through durable dispatch" do
    definition =
      Fixture.tool_definition(%{
        "parameter_schema" => %{
          "type" => "object",
          "properties" => %{"threshold" => %{"type" => "number"}},
          "required" => ["threshold"]
        }
      })

    call = %{id: "c1", name: "write", arguments: %{"threshold" => 0.5}}

    fixture =
      start(
        script: [%{text: "use the threshold", calls: [call]}, %{text: "done", calls: []}],
        tools: [definition]
      )

    {session_id, attachment, _reply} = Fixture.run(fixture, "go")
    events = drain(attachment)

    assert Enum.find(events, &(&1.kind == "run.finished"))["outcome"] == "completed"

    assert [job] = Loopex.AgentLoopTestExecutor.jobs(fixture.executor)
    assert job.validated_arguments == %{"threshold" => 0.5}

    assert Enum.any?(Fixture.records(fixture, session_id), fn record ->
             record.payload[:kind] == "model_result_committed" and
               get_in(record.payload, ["reply", "tool_calls", Access.at(0), "arguments"]) == %{
                 "threshold" => 0.5
               }
           end)
  end

  test "a schema-invalid tool call fails before policy or executor sees it" do
    definition =
      Fixture.tool_definition(%{
        "parameter_schema" => %{
          "type" => "object",
          "properties" => %{"threshold" => %{"type" => "integer"}},
          "required" => ["threshold"]
        }
      })

    call = %{id: "c1", name: "write", arguments: %{"threshold" => 0.5}}

    fixture =
      start(
        script: [%{text: "use the threshold", calls: [call]}, %{text: "done", calls: []}],
        tools: [definition],
        policy: Loopex.AgentLoopUnexpectedPolicy
      )

    {_session_id, attachment, _reply} = Fixture.run(fixture, "go")
    events = drain(attachment)

    assert Enum.find(events, &(&1.kind == "run.finished"))["outcome"] == "completed"

    assert Enum.find(events, &(&1.kind == "tool.finished"))["outcome"] == "failed"
    assert Loopex.AgentLoopTestExecutor.jobs(fixture.executor) == []

    [_first, second] = AgentLoopTestModel.dispatched(fixture.model)
    result = Enum.find(second.messages, &(&1["role"] == "tool"))
    assert result["outcome"] == "failed"
    assert result["content"] =~ "invalid_tool_arguments"
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
    deadline_ms = 500
    script = [%{text: "stalling", calls: [call("c1")], hold: parent}]

    script =
      script ++ for index <- 2..20, do: %{text: "turn #{index}", calls: [call("c#{index}")]}

    fixture = start(script: script, bounds_deadline_ms: deadline_ms)
    {session_id, attachment, _reply} = Fixture.run(fixture, "go")

    assert_receive {:holding, _model}, 2_000

    coordinator_state = fixture.runtime |> coordinator_of() |> :sys.get_state()
    run_id = coordinator_state.durable.active_run_id

    {declared, _charged} =
      Loopex.Runtime.SessionState.accounting(coordinator_state.durable, run_id)

    timer = Map.fetch!(coordinator_state.deadline_timers, run_id)
    timer_remaining = Process.read_timer(timer)
    committed_remaining = max(declared.deadline - System.system_time(:millisecond), 0)

    assert is_integer(timer_remaining),
           "the supervised model call had no live timer for its committed deadline"

    assert timer_remaining <= committed_remaining + 100,
           "the supervised model timer can outlast the run's committed deadline"

    assert coordinator_state.session_id == session_id
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

  test "a prompt fixes its deadline at first request staging and not at admission" do
    # Concept: admitting a prompt commits the duration the operator chose. The
    # absolute instant starts only when the first provider request becomes a
    # durable dispatch, so downtime before any provider work does not consume a
    # run that has not started spending that allowance.
    #
    # Technical depth: the Store pauses the admitting transaction after it is
    # durable but before the coordinator receives its result. Killing that owner
    # leaves a recoverable `model_pending` run with no staged request. Downtime
    # longer than the duration distinguishes the rule: an instant computed at
    # admission would already be expired, while the staged-request rule dispatches
    # once and commits a fresh instant derived from the retained duration.
    parent = self()
    duration_ms = 200
    fixture = start(script: [%{text: "done", calls: []}], bounds_deadline_ms: duration_ms)

    {:ok, session_id} =
      Loopex.create_session(fixture.runtime, %{"tenant" => "t"}, command_id: "create-1")

    {:ok, attachment} = Loopex.attach(fixture.runtime, session_id, after_event_sequence: 0)

    :ok =
      M1RuntimeTestStore.delay_after_record(
        fixture.store,
        "command_admitted",
        self()
      )

    caller =
      spawn(fn ->
        result =
          try do
            Loopex.command(attachment, %{type: :prompt, command_id: "prompt-1", content: "go"})
          catch
            :exit, reason -> {:caller_exit, reason}
          end

        send(parent, {:prompt_caller_finished, self(), result})
      end)

    assert_receive {:record_linearized, waiter, _store, "command_admitted",
                    :session_journal_commit, {:committed, "prompt-1", _receipt}},
                   5_000

    assert AgentLoopTestModel.dispatched(fixture.model) == [],
           "the provider was called before the admitting transaction returned"

    coordinator = coordinator_of(fixture.runtime)
    coordinator_reference = Process.monitor(coordinator)
    Process.exit(coordinator, :kill)
    assert_receive {:DOWN, ^coordinator_reference, :process, ^coordinator, _reason}, 5_000

    M1RuntimeTestStore.release(waiter)

    assert_receive {:prompt_caller_finished, ^caller, caller_result}, 5_000

    assert caller_result == {:error, :session_unavailable} or
             match?({:caller_exit, _}, caller_result)

    Process.sleep(duration_ms + 100)
    staging_floor = System.system_time(:millisecond)

    assert {:ok, ^session_id} =
             Loopex.resume_session(fixture.runtime, session_id, command_id: "resume-1")

    assert await_dispatch_count(fixture, 1),
           "a run with only pre-staging downtime was treated as expired"

    {:ok, resumed} = Loopex.attach(fixture.runtime, session_id, after_event_sequence: 0)

    _events = drain(resumed)

    assert [request] = AgentLoopTestModel.dispatched(fixture.model)
    assert request.deadline >= staging_floor + duration_ms
    assert request.deadline <= System.system_time(:millisecond) + duration_ms

    records = Fixture.records(fixture, session_id)
    admitted = Enum.find(records, &(&1.payload[:kind] == "command_admitted"))
    staged = Enum.find(records, &(&1.payload[:kind] == "model_request_committed"))

    assert admitted.payload["deadline_ms"] == duration_ms
    refute Map.has_key?(admitted.payload, "deadline")
    assert staged.payload["request"]["deadline"] == request.deadline
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

    # The successor abandons the attempt it inherited rather than re-running it
    # under the same identity, and dispatches the next one. Re-running it would
    # give two owners one stream domain, because ADR 0011 makes a domain one
    # attempt's progress stream; abandoning it also charges the call the
    # predecessor actually made, which a silent reuse did not.
    assert await_dispatch_count(fixture, 3)
    Process.sleep(300)

    attempts =
      fixture
      |> Fixture.records(session_id)
      |> Enum.filter(&(&1.payload[:kind] == "model_attempt_abandoned"))
      |> Enum.map(& &1.payload["attempt"])

    # Numbered by the run rather than by whichever owner observed them, and never
    # restarted at one: attempt two is the inherited one the successor gave up,
    # and attempt three is the successor's own.
    assert Enum.take(attempts, 2) == [1, 2]

    refute length(attempts) > length(Enum.uniq(attempts)),
           "an attempt number was abandoned twice: #{inspect(attempts)}"

    dispatched = length(AgentLoopTestModel.dispatched(fixture.model))

    assert dispatched == 3,
           "the successor made #{dispatched - 2} further provider calls rather than one"
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

  test "the runtime commits the assistant reply and never assembles canonical history from streamed deltas" do
    fixture =
      start(
        script: [
          %{text: "AUTHORITATIVE", calls: [call("c1")], deltas: ["PARTIAL"]},
          %{text: "done", calls: []}
        ],
        progress_to: self()
      )

    {session_id, attachment, _reply} = Fixture.run(fixture, "go")
    events = drain(attachment)

    # The transient plane really carried the contradictory bytes, so this is a
    # runtime-boundary proof rather than the equality of two values produced by
    # the same fixture branch.
    assert Enum.any?(receive_progress(), fn
             %{kind: :text_delta, text: "PARTIAL"} -> true
             _other -> false
           end)

    assistant = Enum.find(events, &(&1.kind == "assistant.message_appended"))
    assert assistant["content"] == "AUTHORITATIVE"
    refute assistant["content"] =~ "PARTIAL"

    committed =
      fixture
      |> Fixture.records(session_id)
      |> Enum.find(
        &(&1.payload[:kind] == "model_result_committed" and
            get_in(&1.payload, ["reply", "text"]) == "AUTHORITATIVE")
      )

    assert committed.payload["reply"]["text"] == "AUTHORITATIVE"

    # The next provider request is the production consumer of canonical
    # conversation history. An event and the raw model-result record can both be
    # correct while the durable assistant element is wrong, so this assertion is
    # the one that proves the bytes replayed to the model came from the reply.
    [_first, second] = AgentLoopTestModel.dispatched(fixture.model)
    replayed = Enum.find(second.messages, &(&1["role"] == "assistant"))
    assert replayed["content"] == "AUTHORITATIVE"
    refute replayed["content"] =~ "PARTIAL"
  end

  test "a reply committed before an admitted abort completes the turn and an abort admitted first keeps the late reply as attempt evidence only" do
    # Abort first: the reply arrives after the run is gone and never becomes a
    # canonical assistant message.
    parent = self()

    fixture =
      start(
        script: [
          %{
            text: "late reply",
            calls: [call("c1")],
            deltas: ["late ", "reply"],
            usage: %{"input_tokens" => 17, "output_tokens" => 4},
            reply_overrides: %{provider_response_id: "req_late_reply_1"},
            hold: parent
          }
        ],
        diagnostics_to: parent
      )

    {session_id, attachment, _reply} = Fixture.run(fixture, "go")
    assert_receive {:holding, model}, 2_000

    coordinator = coordinator_of(fixture.runtime)

    [{reference, {:model, run_id, _worker}}] =
      coordinator
      |> :sys.get_state()
      |> Map.fetch!(:in_flight)
      |> Map.to_list()

    :ok = :sys.suspend(coordinator)

    on_exit(fn ->
      if Process.alive?(coordinator) do
        try do
          :sys.resume(coordinator)
        catch
          :exit, _reason -> :ok
        end
      end
    end)

    abort =
      Task.async(fn ->
        Loopex.command(attachment, %{type: :abort, command_id: "abort-1"})
      end)

    assert await_process_message(coordinator, fn
             {:"$gen_call", _from, {:command, _owner, %{type: :abort}}} -> true
             _other -> false
           end),
           "the abort was not queued before the model reply"

    send(model, :release)

    assert await_process_message(coordinator, fn
             {^reference, {:ok, %{text: "late reply"}}} -> true
             _other -> false
           end),
           "the model reply was not queued behind the admitted abort"

    :ok = :sys.resume(coordinator)
    assert {:accepted, "abort-1"} = Task.await(abort, 5_000)

    assert_receive {:loopex_diagnostic,
                    %{
                      "kind" => "late_result_discarded",
                      "run_id" => ^run_id,
                      "operation" => "model",
                      "outcome" => "reply"
                    }},
                   5_000

    events = drain(attachment)
    assert Enum.find(events, &(&1.kind == "run.finished"))["outcome"] == "cancelled"

    # Whether the attempt is stopped outright or its reply arrives too late to
    # belong anywhere, the invariant is the same and is what this asserts: the
    # aborted attempt never becomes canonical history. A late reply that does
    # arrive is a durable attempt-evidence record and the diagnostic is only its
    # live notification.
    records = Fixture.records(fixture, session_id)
    assistants = Enum.filter(records, &(&1.payload[:kind] == "model_result_committed"))

    assert assistants == []

    assert [%{payload: evidence}] =
             Enum.filter(records, &(&1.payload[:kind] == "model_attempt_evidence_retained"))

    assert evidence["run_id"] == run_id
    assert evidence["attempt"] == 1
    assert evidence["termination"] == "abort"
    assert evidence["evidence"]["kind"] == "reply"

    retained_reply = evidence["evidence"]["reply"]

    assert Map.keys(retained_reply) |> Enum.sort() ==
             ~w(canonical_request_bytes delta_count identity provider_response_id staged_request_digest streamed text tool_calls usage)

    assert retained_reply["text"] == "late reply"
    assert retained_reply["provider_response_id"] == "req_late_reply_1"

    assert retained_reply["identity"] == %{
             "provider" => "scripted",
             "model" => "scripted:v1",
             "endpoint" => "in-process"
           }

    assert retained_reply["usage"] == %{"input_tokens" => 17, "output_tokens" => 4}

    assert retained_reply["tool_calls"] == [
             %{
               "id" => "c1",
               "name" => "write",
               "arguments" => %{"path" => "c1"}
             }
           ]

    assert retained_reply["delta_count"] == 2
    assert retained_reply["streamed"]

    staged = Enum.find(records, &(&1.payload[:kind] == "model_request_committed"))

    assert retained_reply["canonical_request_bytes"] ==
             staged.payload["request"]["canonical_request_bytes"]

    assert retained_reply["staged_request_digest"] ==
             staged.payload["request"]["staged_request_digest"]

    terminals = Enum.filter(records, &(&1.payload[:kind] == "run_terminal_committed"))

    assert Enum.map(terminals, & &1.payload["outcome"]) == ["cancelled"]

    assert {:ok, recovered} =
             Loopex.Runtime.SessionState.recover(
               session_id,
               records,
               Fixture.events(fixture, session_id)
             )

    refute Enum.any?(
             Loopex.Runtime.SessionState.elements(recovered, run_id),
             &(&1.kind == :assistant_message)
           )

    # Reply first: let the held provider reply commit, then submit the abort. The
    # completed run wins by journal order and the later command is refused rather
    # than rewriting its terminal.
    other = start(script: [%{text: "in time", calls: [], hold: parent}])
    {_other_session, other_attachment, _reply} = Fixture.run(other, "go")
    assert_receive {:holding, in_time_model}, 2_000
    send(in_time_model, :release)

    events = drain(other_attachment)
    assert Enum.find(events, &(&1.kind == "assistant.message_appended"))["content"] == "in time"
    assert Enum.find(events, &(&1.kind == "run.finished"))["outcome"] == "completed"

    assert {:error, :no_active_run} =
             Loopex.command(other_attachment, %{type: :abort, command_id: "abort-too-late"})
  end

  test "cleanup waits for a model result sent after the supervisor answers" do
    # Concept: a supervisor confirming that it stopped a worker does not prove
    # the worker's result has already reached this owner.
    #
    # Technical depth: the real worker supervisor is suspended with its
    # terminate call stably queued, then that call receives its reply while the
    # held provider task still has not answered. The coordinator must remain in
    # its result drain until the task's own result or ordered DOWN arrives.
    # Restoring the old zero-timeout poll makes the public abort return before
    # the provider is released and fails this case without scheduler timing.
    parent = self()

    fixture =
      start(
        script: [%{text: "late after supervisor", calls: [], hold: parent}],
        diagnostics_to: parent
      )

    {session_id, attachment, _reply} = Fixture.run(fixture, "go")
    assert_receive {:holding, model}, 2_000

    coordinator = coordinator_of(fixture.runtime)
    coordinator_state = :sys.get_state(coordinator)
    workers = coordinator_state.workers

    [{_reference, {:model, run_id, ^model}}] = Map.to_list(coordinator_state.in_flight)

    :ok = :sys.suspend(workers)

    on_exit(fn ->
      send(model, :release)

      if Process.alive?(workers) do
        try do
          :sys.resume(workers)
        catch
          :exit, _reason -> :ok
        end
      end
    end)

    abort =
      Task.async(fn ->
        Loopex.command(attachment, %{
          type: :abort,
          command_id: "abort-after-supervisor-reply"
        })
      end)

    assert await_process_message(workers, fn
             {:"$gen_call", _from, {:terminate_child, ^model}} -> true
             _other -> false
           end),
           "the coordinator never asked its real supervisor to stop the model worker"

    {:messages, messages} = Process.info(workers, :messages)

    {:"$gen_call", from, {:terminate_child, ^model}} =
      Enum.find(messages, fn
        {:"$gen_call", _from, {:terminate_child, ^model}} -> true
        _other -> false
      end)

    GenServer.reply(from, :ok)

    assert :waiting == await_worker_result_drain(coordinator, abort),
           "the abort returned instead of waiting for the worker's ordered result or DOWN"

    send(model, :release)
    assert {:accepted, "abort-after-supervisor-reply"} = Task.await(abort, 5_000)

    :ok = :sys.resume(workers)

    events = drain(attachment)
    assert Enum.find(events, &(&1.kind == "run.finished"))["outcome"] == "cancelled"

    records = Fixture.records(fixture, session_id)

    assert [%{payload: evidence}] =
             Enum.filter(records, &(&1.payload[:kind] == "model_attempt_evidence_retained"))

    assert evidence["run_id"] == run_id
    assert evidence["attempt"] == 1
    assert evidence["termination"] == "abort"
    assert evidence["evidence"]["reply"]["text"] == "late after supervisor"
  end

  test "late model evidence binds the provider retry attempt that produced it" do
    parent = self()

    fixture =
      start(
        script: [
          %{text: "", calls: [], error: :provider_unavailable},
          %{text: "late retry", calls: [], hold: parent}
        ],
        diagnostics_to: parent
      )

    {session_id, attachment, _reply} = Fixture.run(fixture, "go")
    assert_receive {:holding, model}, 2_000
    assert length(AgentLoopTestModel.dispatched(fixture.model)) == 2

    {run_id, events} =
      admit_abort_before_queued_model_result(
        fixture,
        attachment,
        model,
        "abort-late-retry"
      )

    assert Enum.find(events, &(&1.kind == "run.finished"))["outcome"] == "cancelled"

    records = Fixture.records(fixture, session_id)

    assert [%{payload: evidence}] =
             Enum.filter(records, &(&1.payload[:kind] == "model_attempt_evidence_retained"))

    assert evidence["run_id"] == run_id
    assert evidence["attempt"] == 2
    assert evidence["termination"] == "abort"
    assert evidence["evidence"]["reply"]["text"] == "late retry"

    stale_records =
      Enum.map(records, fn
        %{payload: %{kind: "model_attempt_evidence_retained"} = payload} = record ->
          %{record | payload: Map.put(payload, "attempt", 1)}

        record ->
          record
      end)

    assert {:error, :invalid_model_attempt_evidence} =
             Loopex.Runtime.SessionState.recover(
               session_id,
               stale_records,
               Fixture.events(fixture, session_id)
             )
  end

  test "a Store refusal of late model attempt evidence makes clean cancellation unprovable" do
    parent = self()

    fixture =
      start(
        script: [%{text: "late but unretained", calls: [], hold: parent}],
        diagnostics_to: parent
      )

    {session_id, attachment, _reply} = Fixture.run(fixture, "go")
    assert_receive {:holding, model}, 2_000

    :ok =
      M1RuntimeTestStore.refuse_next_record(
        fixture.store,
        "model_attempt_evidence_retained"
      )

    coordinator = coordinator_of(fixture.runtime)

    [{reference, {:model, _run_id, _worker}}] =
      coordinator
      |> :sys.get_state()
      |> Map.fetch!(:in_flight)
      |> Map.to_list()

    :ok = :sys.suspend(coordinator)

    on_exit(fn ->
      if Process.alive?(coordinator) do
        try do
          :sys.resume(coordinator)
        catch
          :exit, _reason -> :ok
        end
      end
    end)

    abort =
      Task.async(fn ->
        Loopex.command(attachment, %{type: :abort, command_id: "abort-unretained-evidence"})
      end)

    assert await_process_message(coordinator, fn
             {:"$gen_call", _from, {:command, _owner, %{type: :abort}}} -> true
             _other -> false
           end)

    send(model, :release)

    assert await_process_message(coordinator, fn
             {^reference, {:ok, %{text: "late but unretained"}}} -> true
             _other -> false
           end)

    :ok = :sys.resume(coordinator)
    assert {:accepted, "abort-unretained-evidence"} = Task.await(abort, 5_000)

    events = drain(attachment)
    assert Enum.find(events, &(&1.kind == "run.finished"))["outcome"] == "outcome_unknown"

    records = Fixture.records(fixture, session_id)

    refute Enum.any?(records, &(&1.payload[:kind] == "model_attempt_evidence_retained"))

    assert Enum.any?(records, &(&1.payload[:kind] == "model_attempt_abandoned"))

    assert [%{payload: terminal}] =
             Enum.filter(records, &(&1.payload[:kind] == "run_terminal_committed"))

    assert terminal["outcome"] == "outcome_unknown"
  end

  test "a late model error is retained as bounded attempt evidence without becoming history" do
    parent = self()

    fixture =
      start(
        script: [%{error: :provider_unavailable, hold: parent}],
        diagnostics_to: parent
      )

    {session_id, attachment, _reply} = Fixture.run(fixture, "go")
    assert_receive {:holding, model}, 2_000

    {run_id, events} =
      admit_abort_before_queued_model_result(
        fixture,
        attachment,
        model,
        "abort-late-error"
      )

    assert Enum.find(events, &(&1.kind == "run.finished"))["outcome"] == "cancelled"

    records = Fixture.records(fixture, session_id)

    assert [%{payload: evidence}] =
             Enum.filter(records, &(&1.payload[:kind] == "model_attempt_evidence_retained"))

    assert evidence["run_id"] == run_id
    assert evidence["termination"] == "abort"

    assert evidence["evidence"] == %{
             "kind" => "error",
             "reason" => "model_call_failed"
           }

    refute Enum.any?(records, &(&1.payload[:kind] == "model_result_committed"))
  end

  test "an unreadable late model reply is retained as a bounded error instead of crashing cleanup" do
    parent = self()

    fixture =
      start(
        script: [
          %{
            hold: parent,
            raw_result:
              {:ok,
               %{
                 text: "unreadable",
                 identity: %{owner: self()},
                 usage: %{},
                 tool_calls: [],
                 canonical_request_bytes: "wrong",
                 staged_request_digest: "wrong"
               }}
          }
        ],
        diagnostics_to: parent
      )

    {session_id, attachment, _reply} = Fixture.run(fixture, "go")
    assert_receive {:holding, model}, 2_000

    {_run_id, events} =
      admit_abort_before_queued_model_result(
        fixture,
        attachment,
        model,
        "abort-unreadable-late-reply"
      )

    assert Enum.find(events, &(&1.kind == "run.finished"))["outcome"] == "cancelled"

    assert [%{payload: evidence}] =
             fixture
             |> Fixture.records(session_id)
             |> Enum.filter(&(&1.payload[:kind] == "model_attempt_evidence_retained"))

    assert evidence["evidence"] == %{
             "kind" => "error",
             "reason" => "unreadable_model_answer"
           }
  end

  test "an undeclared late provider field becomes bounded error and never reaches the journal" do
    secret = "sk-live-provider-secret-1234567890"

    {_run_id, events, records, evidence} =
      retain_late_model_evidence(
        %{
          text: "otherwise valid",
          calls: [],
          reply_overrides: %{credential: secret}
        },
        "abort-late-provider-field"
      )

    assert Enum.find(events, &(&1.kind == "run.finished"))["outcome"] == "cancelled"

    assert evidence["evidence"] == %{
             "kind" => "error",
             "reason" => "unreadable_model_answer"
           }

    refute :erlang.term_to_binary(records) =~ secret
  end

  test "an unreadable live model reply abandons and retries its attempt" do
    secret = "sk-live-provider-secret-before-retry"

    fixture =
      start(
        script: [
          %{text: "unreadable", calls: [], reply_overrides: %{credential: secret}},
          %{text: "recovered", calls: []}
        ]
      )

    {session_id, attachment, _reply} = Fixture.run(fixture, "go")
    events = drain(attachment)
    records = Fixture.records(fixture, session_id)

    assert Enum.find(events, &(&1.kind == "run.finished"))["outcome"] == "completed"
    assert length(AgentLoopTestModel.dispatched(fixture.model)) == 2

    assert records
           |> Enum.filter(&(&1.payload[:kind] == "model_attempt_abandoned"))
           |> Enum.map(& &1.payload["attempt"]) == [1]

    refute :erlang.term_to_binary(records) =~ secret

    exhausted =
      start(
        script: [
          %{error: :provider_unavailable},
          %{text: "still unreadable", calls: [], reply_overrides: %{credential: secret}}
        ]
      )

    {exhausted_session, _attachment, _reply} = Fixture.run(exhausted, "go")
    exhausted_coordinator = coordinator_of(exhausted.runtime)
    exhausted_reference = Process.monitor(exhausted_coordinator)

    assert_receive {:DOWN, ^exhausted_reference, :process, ^exhausted_coordinator, _reason},
                   5_000

    exhausted_records = Fixture.records(exhausted, exhausted_session)

    assert exhausted_records
           |> Enum.filter(&(&1.payload[:kind] == "model_attempt_abandoned"))
           |> Enum.map(& &1.payload["attempt"]) == [1, 2]

    refute :erlang.term_to_binary(exhausted_records) =~ secret
  end

  test "nested provider fields are projected out of valid late evidence" do
    secret = "sk-live-nested-provider-secret"

    {_run_id, events, records, evidence} =
      retain_late_model_evidence(
        %{
          text: "provider-neutral reply",
          calls: [
            %{
              id: "c1",
              name: "write",
              arguments: %{"path" => "safe.txt"},
              provider_private: secret
            }
          ],
          reply_overrides: %{
            identity: %{
              provider: "scripted",
              model: "scripted:v1",
              endpoint: "in-process",
              credential: secret,
              provider_private: secret
            },
            usage: %{input_tokens: 7, output_tokens: 3, provider_private: secret}
          }
        },
        "abort-nested-late-provider-fields"
      )

    assert Enum.find(events, &(&1.kind == "run.finished"))["outcome"] == "cancelled"

    assert %{"kind" => "reply", "reply" => reply} = evidence["evidence"]

    assert reply["identity"] == %{
             "provider" => "scripted",
             "model" => "scripted:v1",
             "endpoint" => "in-process"
           }

    assert reply["usage"] == %{"input_tokens" => 7, "output_tokens" => 3}

    assert reply["tool_calls"] == [
             %{
               "id" => "c1",
               "name" => "write",
               "arguments" => %{"path" => "safe.txt"}
             }
           ]

    refute :erlang.term_to_binary(records) =~ secret
  end

  test "a deeply nested late provider term becomes bounded error at the Store boundary" do
    nested =
      Enum.reduce(1..20, "leaf", fn level, value ->
        %{"level_#{level}" => value}
      end)

    {_run_id, events, _records, evidence} =
      retain_late_model_evidence(
        %{
          text: "otherwise valid",
          calls: [],
          reply_overrides: %{usage: %{"provider_private" => nested}}
        },
        "abort-deep-late-provider-term"
      )

    assert Enum.find(events, &(&1.kind == "run.finished"))["outcome"] == "cancelled"

    assert evidence["evidence"] == %{
             "kind" => "error",
             "reason" => "unreadable_model_answer"
           }
  end

  test "a malformed streamed flag in a late reply becomes bounded error" do
    for {malformed, index} <- Enum.with_index(["not-a-boolean", 1], 1) do
      {_run_id, events, _records, evidence} =
        retain_late_model_evidence(
          %{
            text: "otherwise valid",
            calls: [],
            reply_overrides: %{delta_count: 1, streamed: malformed}
          },
          "abort-late-streamed-shape-#{index}"
        )

      assert Enum.find(events, &(&1.kind == "run.finished"))["outcome"] == "cancelled"

      assert evidence["evidence"] == %{
               "kind" => "error",
               "reason" => "unreadable_model_answer"
             }
    end
  end

  test "a late reply whose streamed flag contradicts its count becomes bounded error" do
    {_run_id, events, _records, evidence} =
      retain_late_model_evidence(
        %{
          text: "otherwise valid",
          calls: [],
          reply_overrides: %{delta_count: 0, streamed: true}
        },
        "abort-late-stream-count-contradiction"
      )

    assert Enum.find(events, &(&1.kind == "run.finished"))["outcome"] == "cancelled"

    assert evidence["evidence"] == %{
             "kind" => "error",
             "reason" => "unreadable_model_answer"
           }
  end

  test "an oversized valid late reply is retained as bounded error" do
    {_run_id, events, records, evidence} =
      retain_late_model_evidence(
        %{
          text: &full_record_boundary_text/1,
          calls: [],
          reply_overrides: %{provider_response_id: "req-boundary"}
        },
        "abort-oversized-late-reply"
      )

    assert Enum.find(events, &(&1.kind == "run.finished"))["outcome"] == "cancelled"

    assert evidence["evidence"] == %{
             "kind" => "error",
             "reason" => "unreadable_model_answer"
           }

    assert :erlang.external_size(records) < 65_536
  end

  test "a late model error retains only its generic bounded category" do
    # Erlang bounds atoms by characters rather than their UTF-8 byte encoding.
    # This stays inside the VM's atom-length limit while exceeding the retained
    # error-reason byte ceiling.
    oversized_reason = String.to_atom(String.duplicate("é", 200))

    for {reason, index} <- Enum.with_index([oversized_reason, {oversized_reason, :detail}], 1) do
      {_run_id, events, _records, evidence} =
        retain_late_model_evidence(
          %{error: reason},
          "abort-oversized-late-error-#{index}"
        )

      assert Enum.find(events, &(&1.kind == "run.finished"))["outcome"] == "cancelled"

      assert evidence["evidence"] == %{
               "kind" => "error",
               "reason" => "model_call_failed"
             }
    end
  end

  test "a model reply queued behind its deadline is retained with the deadline termination" do
    parent = self()

    fixture =
      start(
        script: [%{text: "late at deadline", calls: [], hold: parent}],
        bounds_deadline_ms: 300,
        diagnostics_to: parent
      )

    {session_id, attachment, _reply} = Fixture.run(fixture, "go")
    assert_receive {:holding, model}, 2_000

    coordinator = coordinator_of(fixture.runtime)
    coordinator_state = :sys.get_state(coordinator)
    run_id = coordinator_state.durable.active_run_id
    deadline = get_in(coordinator_state.durable.pending_work, [run_id, :request, :deadline])

    [{reference, {:model, ^run_id, _worker}}] = Map.to_list(coordinator_state.in_flight)

    :ok = :sys.suspend(coordinator)

    on_exit(fn ->
      if Process.alive?(coordinator) do
        try do
          :sys.resume(coordinator)
        catch
          :exit, _reason -> :ok
        end
      end
    end)

    assert await_process_message(coordinator, fn
             {:run_deadline, ^run_id, ^deadline} -> true
             _other -> false
           end)

    send(model, :release)

    assert await_process_message(coordinator, fn
             {^reference, {:ok, %{text: "late at deadline"}}} -> true
             _other -> false
           end)

    :ok = :sys.resume(coordinator)
    events = drain(attachment)

    finished = Enum.find(events, &(&1.kind == "run.finished"))
    assert finished["outcome"] == "bound_reached"
    assert finished["bound"] == "deadline"

    assert [%{payload: evidence}] =
             fixture
             |> Fixture.records(session_id)
             |> Enum.filter(&(&1.payload[:kind] == "model_attempt_evidence_retained"))

    assert evidence["termination"] == "deadline"
    assert evidence["evidence"]["kind"] == "reply"
    assert evidence["evidence"]["reply"]["text"] == "late at deadline"
  end

  test "executor progress proves its whole identity before anything is projected" do
    fixture = start_with_progress(:valid)

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
               :base_event_sequence,
               :progress_sequence,
               :stream,
               :byte_offset,
               :chunk
             ])

    assert first.chunk == "first"
    assert first.kind == :tool_progress

    # The event and receipt are deliberately built from the job, so comparing
    # them only with each other would admit a self-consistent job carrying the
    # wrong configured executor identity. Bind the dispatched job back to the
    # independent runtime configuration this fixture supplied.
    assert [job] = AgentLoopProgressExecutor.jobs(fixture.executor)
    assert job.origin_executor_epoch == 1
    assert job.executor_identity == "progress-executor"
    assert job.fencing_token == 7
    assert job.workspace_ref == "workspace-ref"
    assert job.workspace_lease == "workspace-lease"

    assert Enum.all?(items, &(&1.turn_id == job.turn_id)),
           "the projection did not retain the dispatched job's turn identity"

    assert Enum.all?(items, &(&1.tool_call_id == job.tool_call_id)),
           "the projection did not retain the dispatched job's tool-call identity"

    tool_started = Enum.find(fixture.events, &(&1.kind == "tool.started"))

    assert Enum.all?(items, &(&1.base_event_sequence == tool_started.event_sequence)),
           "executor progress was not anchored to the public event that preceded dispatch"

    # Plain data: encoding it must not raise, which it does for a pid, port,
    # reference, or function anywhere inside.
    assert is_binary(LoopexProtocol.Canonical.encode(first))
  end

  test "each executor stream anchors to the current public event at its own dispatch" do
    fixture =
      start_with_progress(:valid, [
        %{text: "first", calls: [call("c1")]},
        %{text: "second", calls: [call("c2")]},
        %{text: "done", calls: []}
      ])

    progress =
      receive_progress()
      |> Enum.filter(&(&1.kind in [:tool_progress, :tool_stream_closed]))

    assert jobs = AgentLoopProgressExecutor.jobs(fixture.executor)
    assert length(jobs) == 2

    started =
      fixture.events
      |> Enum.filter(&(&1.kind == "tool.started"))
      |> Map.new(&{&1["tool_call_id"], &1.event_sequence})

    for job <- jobs do
      domain = Loopex.StreamDomain.for_job(job)
      items = Enum.filter(progress, &(&1.stream_domain_id == domain))

      assert length(items) == 3

      assert Enum.all?(
               items,
               &(&1.base_event_sequence == Map.fetch!(started, job.tool_call_id))
             )
    end

    [first, second] = Enum.map(jobs, &Map.fetch!(started, &1.tool_call_id))
    assert second > first
  end

  test "an executor event that names the live call but any wrong binding never reaches the operator" do
    # Each of these carries the current `tool_call_id` and differs from a valid
    # event in exactly one binding. Matching the call id alone was what let a
    # stale or faulty executor speak on the live attempt's behalf.
    #
    # Every binding is asked for by name, and the list is the full identity a
    # dispatched job carries rather than a selection. Missing and wrong are
    # independent fail-closed shapes, so every binding is driven once each
    # rather than letting one mostly-empty event stand in for all missing
    # members.
    bindings = [
      :protocol_version,
      :job_id,
      :tool_call_id,
      :operation_id,
      :attempt,
      :session_id,
      :run_id,
      :turn_id,
      :canonical_request_digest,
      :session_epoch_at_dispatch,
      :executor_epoch,
      :executor_identity,
      :fencing_token,
      :progress_sequence
    ]

    modes = Enum.flat_map(bindings, &[{:wrong, &1}, {:missing, &1}])

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
      assert refusal["refused_bindings"] == %{Atom.to_string(elem(mode, 1)) => 1}
    end
  end

  test "a refused executor event is counted privately and never journaled" do
    # Concept: invalid progress is observable to the current operator without
    # becoming durable truth about the run.
    #
    # Technical depth: ADR 0011 makes the count relay-private and says neither
    # the refused event nor its accounting is journaled. The coordinator emits
    # one bounded diagnostic after close, while the run, receipt and durable
    # projection remain unchanged.
    fixture = start_with_progress(:one_valid_two_refused_one_valid)

    refute fixture
           |> Fixture.records(fixture.session_id)
           |> Enum.any?(&(&1.payload[:kind] == "executor_progress_refused"))

    diagnostic = Enum.find(diagnostics(), &(&1["kind"] == "executor_progress_refused"))
    assert diagnostic["refused_count"] == 2
    assert diagnostic["tool_call_id"] == "c1"
    assert diagnostic["refused_bindings"] == %{"attempt" => 1, "fencing_token" => 1}

    # The two valid items crossed and the two wrong-identity items did not. An
    # event that does not belong to the live attempt cannot consume that
    # attempt's sequence or byte offset, so the valid item after both refusals is
    # still sequence one at stdout offset four. The diagnostic changes neither
    # the receipt nor how the run ends.
    assert [first, second] = tool_progress_items()
    assert Enum.map([first, second], & &1.progress_sequence) == [0, 1]
    assert Enum.map([first, second], & &1.byte_offset) == [0, 4]

    terminal =
      fixture
      |> Fixture.records(fixture.session_id)
      |> Enum.find(&(&1.payload[:kind] == "run_terminal_committed"))

    assert terminal.payload["outcome"] == "completed"

    # Payload refusals have the same transient-only boundary.
    quiet = start_with_progress(:hostile_payload)

    refute quiet
           |> Fixture.records(quiet.session_id)
           |> Enum.any?(&(&1.payload[:kind] == "executor_progress_refused"))

    quiet_payload = Enum.find(diagnostics(), &(&1["kind"] == "executor_progress_refused"))

    assert quiet_payload["refused_count"] == 4,
           "the unknown stream, two bad offsets, and oversized chunk were not all counted"

    assert quiet_payload["refused_bindings"] == %{
             "byte_offset" => 2,
             "chunk" => 1,
             "stream" => 1
           }
  end

  test "a refused current-attempt payload preserves its executor sequence gap" do
    fixture = start_with_progress(:payload_refusal_preserves_executor_gap)
    progress_plane = receive_progress()

    # The middle event proves the live attempt's full identity and next
    # sequence, then fails its stream binding. It therefore consumes executor
    # sequence one but no stdout bytes. Carrying the later event's supplied
    # sequence unchanged lets the consumer see the same gap the coordinator
    # saw, while its offset remains the next contiguous stdout byte.
    assert [before_gap, after_gap] =
             Enum.filter(progress_plane, &(&1.kind == :tool_progress))

    assert Enum.map([before_gap, after_gap], & &1.progress_sequence) == [0, 2]
    assert Enum.map([before_gap, after_gap], & &1.byte_offset) == [0, 2]

    refusal = Enum.find(diagnostics(), &(&1["kind"] == "executor_progress_refused"))
    assert refusal["refused_count"] == 1
    assert refusal["refused_bindings"] == %{"stream" => 1}

    refute fixture
           |> Fixture.records(fixture.session_id)
           |> Enum.any?(&(&1.payload[:kind] == "executor_progress_refused"))

    assert %{progress_count: 3} =
             Enum.find(progress_plane, &(&1.kind == :tool_stream_closed))
  end

  test "a validated executor event carries only its bounded named payload across" do
    # The identity is genuine, so the event is admitted — and still nothing the
    # executor put beside the named payload crosses, because the projection is
    # built here rather than merged from what arrived. The second event is
    # refused outright for exceeding the declared chunk ceiling.
    fixture = start_with_progress(:hostile_payload)

    items = tool_progress_items()
    assert Enum.map(items, & &1.progress_sequence) == [0, 1, 2]
    assert Enum.map(items, & &1.stream) == ["stdout", "stderr", "progress"]

    [first | _rest] = items
    assert first.chunk == "ok"

    for item <- items do
      refute Map.has_key?(item, :owner)
      refute Map.has_key?(item, :finish)
      refute Map.has_key?(item, :credential)
      assert is_binary(LoopexProtocol.Canonical.encode(item))
    end

    refusal = Enum.find(diagnostics(), &(&1["kind"] == "executor_progress_refused"))
    assert refusal["refused_count"] == 4

    assert refusal["refused_bindings"] == %{
             "byte_offset" => 2,
             "chunk" => 1,
             "stream" => 1
           }

    refute fixture
           |> Fixture.records(fixture.session_id)
           |> Enum.any?(&(&1.payload[:kind] == "executor_progress_refused"))
  end

  test "the first delta of a model attempt is sequence zero" do
    fixture =
      start(
        script: [
          %{text: "run", calls: [call("c1")], deltas: ["run"]},
          %{text: "abc", calls: [], deltas: ["a", "b", "c"]}
        ],
        progress_to: self()
      )

    {_session_id, attachment, _reply} = Fixture.run(fixture, "go")
    events = drain(attachment)

    observed = receive_progress()

    model_items =
      Enum.filter(observed, &(Map.get(&1, :kind) in [:text_delta, :model_stream_closed]))

    domains = model_items |> Enum.map(& &1.stream_domain_id) |> Enum.uniq()
    assert length(domains) == 2

    grouped = Enum.group_by(model_items, & &1.stream_domain_id)

    [{first_domain, [0], 1}, {second_domain, [0, 1, 2], 3}] =
      Enum.map(domains, fn domain ->
        items = Map.fetch!(grouped, domain)
        deltas = Enum.filter(items, &(&1.kind == :text_delta))
        closure = Enum.find(items, &(&1.kind == :model_stream_closed))

        assert List.last(deltas).model_sequence == closure.delta_count - 1
        {domain, Enum.map(deltas, & &1.model_sequence), closure.delta_count}
      end)

    refute first_domain == second_domain

    run_started = Enum.find(events, &(&1.kind == "run.started"))
    tool_finished = Enum.find(events, &(&1.kind == "tool.finished"))

    for {domain, anchor} <- [
          {first_domain, run_started.event_sequence},
          {second_domain, tool_finished.event_sequence}
        ] do
      assert Enum.all?(
               Map.fetch!(grouped, domain),
               &(&1.base_event_sequence == anchor)
             )
    end
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
    declared = Keyword.take(options, [:cleanup_grace_ms, :progress_to, :diagnostics_to])

    model_pid = AgentLoopTestModel.start(script)
    {store_pid, store} = M1RuntimeTestStore.start_store(label: "agent-loop-answering")
    definitions = [Fixture.tool_definition()]

    {:ok, runtime} =
      Loopex.start_link(
        [
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
        ] ++ declared
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

    case Keyword.get(options, :before_prompt) do
      prepare when is_function(prepare, 3) -> prepare.(runtime, session_id, store_pid)
      prepare when is_function(prepare, 1) -> prepare.(store_pid)
      nil -> :ok
    end

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

  test "a complete tool stream closes on its receipt's own progress count" do
    # Concept: ADR 0011 assigns a complete closure the producer's own statement,
    # and the difference between that statement and what a consumer received is
    # the signal the closure exists to give.
    #
    # Technical depth: an earlier round of this amendment substituted the count
    # this runtime published, on the reasoning that refusals are not loss. That
    # was a departure from an accepted decision, and it erased the loss signal a
    # refusal leaves on the transient plane. The executor below emits three
    # events and reports three; two carry a wrong binding and never reach the
    # operator. The closure states three, one item arrived, and the current
    # operator receives one private refusal diagnostic explaining the mismatch.
    _fixture = start_with_progress(:one_valid_two_refused)

    items = receive_progress()

    progress = Enum.filter(items, &(&1.kind == :tool_progress))
    assert length(progress) == 1
    assert [%{chunk: "kept", progress_sequence: 0}] = progress

    closure = Enum.find(items, &(&1.kind == :tool_stream_closed))
    assert closure, "the tool stream was never closed"
    assert closure.disposition == :complete

    assert closure.progress_count == 3,
           "the closing item carried #{closure.progress_count} rather than the count its " <>
             "receipt reported, so a consumer cannot tell that two items never arrived"

    # The diagnostic explains the difference without turning the refusal into a
    # durable run fact.
    refusal = Enum.find(diagnostics(), &(&1["kind"] == "executor_progress_refused"))
    assert refusal["refused_count"] == 2
  end

  test "a receipt the Store refuses cannot complete its tool stream" do
    # Concept: a complete closure is a claim that a valid executor receipt was
    # retained. A receipt the Store refused never earned that claim, however
    # complete its in-memory shape looked before the transaction.
    #
    # Technical depth: this is distinct from an executor returning
    # `receipt_not_retained` and from a malformed receipt. The executor returns a
    # fully valid receipt after emitting one accepted and two refused events;
    # the Store alone refuses `executor_receipt_committed`. The stream must close
    # abandoned on the one item this runtime emitted. Mutating only the Store
    # error branch to close complete previously left every locked case green.
    executor = AgentLoopProgressExecutor.start(:one_valid_two_refused)

    fixture =
      start_with_executor(
        AgentLoopProgressExecutor,
        executor,
        one_call_script(),
        progress_to: self(),
        before_prompt: fn store ->
          :ok = M1RuntimeTestStore.refuse_next_record(store, "executor_receipt_committed")
        end
      )

    {progress, closure} = await_tool_closure()

    assert [%{chunk: "kept", progress_sequence: 0}] =
             Enum.filter(progress, &(&1.kind == :tool_progress))

    assert closure.disposition == :abandoned,
           "a receipt the Store refused was published as a completed stream"

    assert closure.progress_count == 1,
           "the abandoned closure did not state the count this runtime emitted"

    refute fixture.session_id
           |> then(&Fixture.records(fixture, &1))
           |> Enum.any?(&(&1.payload[:kind] == "executor_receipt_committed")),
           "the Store refusal did not reach the receipt transaction this case names"
  end

  test "a reply the Store refuses cannot complete its model stream" do
    # Concept: a complete model closure is a claim that the assistant message is
    # durable. A reply the Store refused never earned that claim.
    #
    # Technical depth: the model is held after publishing one delta so this case
    # can monitor the live owner before the reply reaches the refused
    # `model_result_committed` transaction. The owner then stops and its linked
    # relay ends without inventing a disposition. Restoring the old
    # close-before-commit order publishes `complete` before that refusal and
    # makes this case fail on the exact false statement.
    parent = self()

    fixture =
      start_with_executor(
        Loopex.AgentLoopTestExecutor,
        Loopex.AgentLoopTestExecutor.start(),
        [%{text: "answer", calls: [], deltas: ["partial"], hold: parent}],
        progress_to: self(),
        before_prompt: fn store ->
          :ok = M1RuntimeTestStore.refuse_next_record(store, "model_result_committed")
        end
      )

    assert_receive {:holding, model}, 5_000
    owner = coordinator_of(fixture.runtime)
    owner_reference = Process.monitor(owner)
    send(model, :release)

    assert_receive {:DOWN, ^owner_reference, :process, ^owner, _reason},
                   5_000,
                   "the Store refusal did not stop the owner whose result it refused"

    observed = receive_progress()

    assert Enum.any?(observed, &(&1.kind == :text_delta)),
           "the model did not open the stream whose false closure is under test"

    refute Enum.any?(
             observed,
             &(&1.kind == :model_stream_closed and &1.disposition == :complete)
           ),
           "a reply the Store refused was published as a completed stream"

    refute fixture.session_id
           |> then(&Fixture.records(fixture, &1))
           |> Enum.any?(&(&1.payload[:kind] == "model_result_committed")),
           "the Store refusal did not reach the model-result transaction this case names"
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

  test "the run's terminal reports the cleanup period this session declared" do
    # Concept: ADR 0009 requires the declared cleanup grace to be reported in the
    # terminal outcome's evidence, so an operator can tell a clean cooperative
    # stop from a forced kill that was confirmed and from a termination that
    # could not be confirmed at all.
    #
    # Technical depth: ADR 0009 calls it a declared *session* configuration value
    # with a default. This runtime read it back off whatever the answering
    # executor had written into a receipt instead, which is a different thing
    # wearing the same name: a run that produced no receipt reported `nil`, and
    # those are exactly the endings the period matters for -- an abort admitted
    # before any executor answered, a run stopped between turns, and every
    # recovery. The session declares it, the composed executor is handed the same
    # value, and the terminal names it whatever happened.
    #
    # The second half is what the receipt-derived version could not do at all.
    declared =
      start_with_executor(
        AgentLoopAnsweringExecutor,
        AgentLoopAnsweringExecutor.start(%{}),
        one_call_script(),
        cleanup_grace_ms: 750
      )

    finished = Enum.find(drain(declared.attachment), &(&1.kind == "run.finished"))

    assert finished["outcome"] == "completed"

    assert finished["cleanup_grace_ms"] == 750,
           "the run's terminal did not report the period this session declared: " <>
             inspect(finished["cleanup_grace_ms"])

    # Concept: the bounds a job runs under are declared where they are journaled.
    #
    # Technical depth: the output ceiling was always declared on the job; the
    # wall-time ceiling was read only from the executor's own copy of the
    # definition, which made the bound a fact about the hand rather than about
    # the dispatch and left nothing durable naming it. Both come from the
    # definition this call resolved through now, and Outcome 4 proves the
    # executor honours the smaller of them.
    [job | _rest] = AgentLoopAnsweringExecutor.jobs(declared.executor)
    budgets = Fixture.tool_definition() |> Map.fetch!("budgets")

    assert job.resource_budgets == %{
             "max_output_bytes" => Map.fetch!(budgets, "output_bytes"),
             "max_wall_time_ms" => Map.fetch!(budgets, "wall_time_ms")
           },
           "the dispatched job declared #{inspect(job.resource_budgets)} rather than the " <>
             "ceilings its tool definition names"

    # Concept: a declared bound that the digest does not cover is a bound nobody
    # signed for.
    #
    # Technical depth: reaching the job is not enough. `canonical_request_digest`
    # is what an executor revalidates against and what reconciliation matches an
    # attempt by, so a ceiling omitted from the canonical encoding could be
    # changed between the journal and the hand without either noticing. Dropping
    # `max_wall_time_ms` before that encoding left two jobs bounded at ten and
    # twenty milliseconds with identical bytes and identical digests, and left
    # every case in this repository green -- the assertion above proves the field
    # travelled, and nothing proved it was covered.
    signed =
      for milliseconds <- [10, 20] do
        fields =
          job
          |> Map.take(Loopex.Executor.job_fields())
          |> Map.put(:resource_budgets, %{
            "max_output_bytes" => 1024,
            "max_wall_time_ms" => milliseconds
          })

        {:ok, request} = Loopex.Executor.job(fields)

        {request.canonical_request_bytes, request.canonical_request_digest}
      end

    assert [{first_bytes, first_digest}, {second_bytes, second_digest}] = signed

    assert first_bytes != second_bytes,
           "two jobs differing only in their declared wall-time ceiling canonicalized to the " <>
             "same bytes, so the ceiling is outside what the digest covers"

    assert first_digest != second_digest,
           "two jobs differing only in their declared wall-time ceiling carry one digest"

    # A session that declares none reports the port's default rather than an
    # absence: ADR 0009 says "with a default", and a terminal carrying `nil` is a
    # terminal an operator cannot read the stopping out of.
    #
    # The number is written out rather than read back from
    # `Loopex.Executor.default_cleanup_grace_ms/0`. Comparing the reported value
    # against the same function the runtime reads it from asserts only that one
    # value reached two places; five seconds is what the operator guidance
    # promises, so changing it is a change to a documented promise and this case
    # is one of the places that has to be edited to make it.
    defaulted =
      start_with_executor(
        AgentLoopAnsweringExecutor,
        AgentLoopAnsweringExecutor.start(%{}),
        one_call_script()
      )

    defaulted_finished = Enum.find(drain(defaulted.attachment), &(&1.kind == "run.finished"))

    assert defaulted_finished["cleanup_grace_ms"] == 5_000,
           "a session that declared no period reported " <>
             "#{inspect(defaulted_finished["cleanup_grace_ms"])} rather than the five seconds " <>
             "the operator guidance promises"

    assert Loopex.Executor.default_cleanup_grace_ms() == 5_000,
           "the port's declared default and the period a run reports are no longer one number"
  end

  test "no item of a stream domain is emitted after that domain's closure" do
    # Concept: ADR 0011 says the closure is the last item of its domain in every
    # case. Not usually, and not within a window.
    #
    # Technical depth: this was two processes emitting into one domain -- a
    # producer running an adapter's or an executor's callback, and the
    # coordinator closing it -- and nothing either of them did alone made "last"
    # true. A seal stopped the next reservation and said nothing about a sequence
    # already handed out, so a producer preempted between reserving and emitting
    # put a delta on the plane after its own closure; a review demonstrated
    # exactly that. Waiting for the stranded item bounded the window rather than
    # closing it, and the wait had to be bounded because the waiter is the
    # session's serial writer.
    #
    # Neither of them emits now. `Loopex.Runtime.StreamRelay` is the only emitter
    # of its domain: it assigns every sequence, emits every item, emits the
    # closure itself as the last thing it does, and then ends -- so a producer
    # handing an item to a closed domain is sending to a process that no longer
    # exists, which is what ADR 0011 says happens to a delta offered after
    # closure.
    #
    # The assertion is the rule itself, driven with a producer racing the closer
    # from another process. How many items arrive is not fixed and does not need
    # to be: what is fixed is that the closure is last, that its total is exactly
    # the number of items before it, and that their sequences are gapless from
    # zero.
    supervisor =
      start_supervised!({Task.Supervisor, name: :"relay-#{System.unique_integer([:positive])}"})

    {:ok, relay} =
      StreamRelay.open(
        supervisor,
        self(),
        fn item, sequence -> %{kind: :item, item: item, model_sequence: sequence} end,
        fn disposition, count ->
          %{kind: :closed, disposition: disposition, delta_count: count}
        end
      )

    producer = spawn(fn -> Enum.each(1..500, &StreamRelay.emit(relay, &1)) end)
    on_exit(fn -> Process.exit(producer, :kill) end)

    count = StreamRelay.close(relay, :abandoned)
    observed = receive_progress()

    closure_at = Enum.find_index(observed, &(&1.kind == :closed))

    assert closure_at,
           "the domain was never closed; #{length(observed)} items reached the plane"

    assert closure_at == length(observed) - 1,
           "#{length(observed) - 1 - closure_at} item(s) of this domain were emitted after " <>
             "its own closure"

    assert closure_at == count,
           "the closure stated #{count} while #{closure_at} items preceded it"

    assert observed |> Enum.take(closure_at) |> Enum.map(& &1.model_sequence) ==
             Enum.to_list(0..(closure_at - 1)//1)
  end

  test "a closed stream domain accepts nothing further and its relay is gone" do
    # Concept: closing is not a flag that a later emission might read too late.
    #
    # Technical depth: the relay ends when it closes, so there is no state left
    # for a stale progress function to race. Handing an item to it afterwards is
    # a send to a dead process, which succeeds and does nothing -- a producer
    # needs no answer and has none to misread. A second close has no relay to ask
    # and says so rather than inventing a second, different total.
    supervisor =
      start_supervised!({Task.Supervisor, name: :"relay-#{System.unique_integer([:positive])}"})

    {:ok, relay} =
      StreamRelay.open(
        supervisor,
        self(),
        fn item, sequence -> %{kind: :item, item: item, model_sequence: sequence} end,
        fn disposition, count ->
          %{kind: :closed, disposition: disposition, delta_count: count}
        end
      )

    StreamRelay.emit(relay, :first)
    assert StreamRelay.close(relay, :abandoned) == 1

    assert StreamRelay.emit(relay, :late) == :ok
    assert StreamRelay.close(relay, :abandoned) == :unavailable

    observed = receive_progress()

    assert Enum.map(observed, & &1.kind) == [:item, :closed],
           "a late item reached the plane: #{inspect(Enum.map(observed, & &1.kind))}"

    # A complete domain states its producer's own figure rather than the relay's,
    # which is the other half of ADR 0011's disposition table.
    {:ok, complete} =
      StreamRelay.open(
        supervisor,
        self(),
        fn item, sequence -> %{kind: :item, item: item, model_sequence: sequence} end,
        fn disposition, count ->
          %{kind: :closed, disposition: disposition, delta_count: count}
        end
      )

    StreamRelay.emit(complete, :only)
    assert StreamRelay.close(complete, {:complete, 4}) == 4

    assert Enum.find(receive_progress(), &(&1.kind == :closed)) == %{
             kind: :closed,
             disposition: :complete,
             delta_count: 4
           }
  end

  test "a succession never gives two owners one stream domain" do
    # Concept: ADR 0011 makes a stream domain one attempt's progress stream, and
    # its closure the last item of that domain. Two owners producing into one
    # label breaks both at once.
    #
    # Technical depth: a predecessor superseded while still alive with a model
    # call in flight left the run at `model_dispatched`, and the successor
    # dispatched the same staged bytes under the same attempt — so it derived the
    # same domain. A review drove it: the successor emitted sequence zero and a
    # complete closure, and the predecessor's producer, resumed afterwards,
    # emitted sequences zero, one and two under the identical label. The closure
    # was no longer last and sequence zero appeared twice.
    #
    # Two things changed and this drives both. The successor abandons the attempt
    # it inherited, so its dispatch opens a *different* domain; and recognized
    # model supersession closes the predecessor's model domain even where that
    # process remains alive. The producer here is held open across the
    # succession, which is what makes the old domain still live at the moment
    # the new one opens.
    parent = self()

    fixture =
      start(
        script: [
          %{text: "", calls: [], error: :provider_unavailable, hold: parent, deltas: ["a"]},
          %{text: "done", calls: [], deltas: ["b"]}
        ],
        progress_to: self()
      )

    {session_id, _attachment, _reply} = Fixture.run(fixture, "go")
    assert_receive {:holding, model}, 5_000
    model_reference = Process.monitor(model)

    predecessor = receive_progress()

    assert [predecessor_delta] =
             Enum.filter(predecessor, &(&1.kind == :text_delta)),
           "the predecessor did not publish exactly the delta that keeps its domain observable"

    assert {:ok, ^session_id} =
             Loopex.resume_session(fixture.runtime, session_id, command_id: "resume-1")

    assert_receive {:loopex_progress,
                    %{
                      kind: :model_stream_closed,
                      disposition: :abandoned,
                      delta_count: 1
                    } = predecessor_closure},
                   5_000,
                   "the predecessor's open domain was not closed abandoned when it was superseded"

    assert predecessor_closure.stream_domain_id == predecessor_delta.stream_domain_id
    predecessor = predecessor ++ [predecessor_closure]

    assert_receive {:DOWN, ^model_reference, :process, ^model, _reason},
                   1_000,
                   "the superseded provider task kept running after its successor took the run"

    {:ok, resumed} =
      Loopex.attach(fixture.runtime, session_id, after_event_sequence: 0)

    assert await_dispatch_count(fixture, 2),
           "the successor did not dispatch its replacement attempt"

    events = drain(resumed)

    assert Enum.find(events, &(&1.kind == "run.finished"))["outcome"] == "completed",
           "the successor did not durably finish after the predecessor was terminated"

    successor = receive_progress()

    assert receive_progress() == [],
           "the predecessor emitted after supersession closed its domain"

    observed = predecessor ++ successor
    domains = observed |> Enum.map(& &1.stream_domain_id) |> Enum.uniq()

    assert length(domains) == 2,
           "the predecessor and successor used #{length(domains)} domains: #{inspect(domains)}"

    assert predecessor_delta.stream_domain_id !=
             successor
             |> Enum.find(&(&1.kind == :text_delta))
             |> Map.fetch!(:stream_domain_id),
           "the successor reused the predecessor's stream domain"

    assert Enum.count(observed, &(&1.kind == :model_stream_closed)) == 2,
           "the succession did not publish exactly one closure for each owner's domain"

    for domain <- domains do
      items = Enum.filter(observed, &(&1.stream_domain_id == domain))
      closures = Enum.filter(items, &(&1.kind == :model_stream_closed))

      assert length(closures) == 1,
             "domain #{domain} was closed #{length(closures)} times rather than exactly once"

      assert List.last(items).kind == :model_stream_closed,
             "an item of domain #{domain} was emitted after its own closure"

      sequences =
        items
        |> Enum.reject(&(&1.kind == :model_stream_closed))
        |> Enum.map(& &1.model_sequence)

      assert sequences == Enum.to_list(0..(length(sequences) - 1)),
             "domain #{domain} was not independently gapless: #{inspect(sequences)}"
    end

    # And the successor's own domain is a different one, because it abandoned the
    # attempt it inherited rather than re-running it under the same identity.
    attempts =
      fixture
      |> Fixture.records(session_id)
      |> Enum.filter(&(&1.payload[:kind] == "model_attempt_abandoned"))
      |> Enum.map(& &1.payload["attempt"])

    assert 1 in attempts,
           "the successor re-ran the attempt it inherited, so both owners derived one domain"
  end

  test "a prior ownership verdict cannot suppress notified model cleanup" do
    # Concept: the handoff notification still ends effect-free model work even
    # if another ownership fence already marked the coordinator stale.
    #
    # Technical depth: a deadline, progress, or terminal-result fence can set
    # `superseded` before Control delivers its cast. Pre-marking that exact state
    # makes the ordering deterministic. The later cast must still terminate and
    # drain the model worker, close its model domain abandoned, and reap the
    # settled coordinator. Restoring the old `not state.superseded` guard leaves
    # all three alive and fails only this case.
    fixture =
      start(
        script: [
          %{
            text: "",
            calls: [],
            error: :provider_unavailable,
            hold: self(),
            hold_timeout_ms: 30_000,
            deltas: ["open"]
          }
        ],
        progress_to: self()
      )

    {_session_id, _attachment, _reply} = Fixture.run(fixture, "go")
    assert_receive {:holding, model}, 5_000
    model_reference = Process.monitor(model)

    predecessor = coordinator_of(fixture.runtime)
    predecessor_reference = Process.monitor(predecessor)
    predecessor_state = :sys.get_state(predecessor)

    assert [{{:model, _run_id}, stream}] = Map.to_list(predecessor_state.streams)
    relay = stream.relay
    relay_reference = Process.monitor(relay)
    workers = predecessor_state.workers

    assert [%{kind: :text_delta} = delta] = receive_progress()
    :sys.replace_state(predecessor, &%{&1 | superseded: true})

    :sys.suspend(workers)

    try do
      GenServer.cast(predecessor, {:superseded, "replacement-generation"})

      assert await_process_message(workers, fn
               {:"$gen_call", {^predecessor, _tag}, {:terminate_child, ^model}} -> true
               _other -> false
             end),
             "the notified predecessor never tried to terminate its model worker"

      assert Process.alive?(relay),
             "the notified model domain closed before its worker terminated and drained"
    after
      :sys.resume(workers)
    end

    assert_receive {:DOWN, ^model_reference, :process, ^model, _reason},
                   5_000,
                   "the prior fence suppressed model-worker termination"

    assert_receive {:loopex_progress,
                    %{
                      kind: :model_stream_closed,
                      stream_domain_id: domain,
                      disposition: :abandoned,
                      delta_count: 1
                    }},
                   5_000,
                   "the prior fence suppressed the notified model closure"

    assert domain == delta.stream_domain_id

    assert_receive {:DOWN, ^relay_reference, :process, _relay, _reason},
                   5_000,
                   "the notified model relay stayed alive"

    assert_receive {:DOWN, ^predecessor_reference, :process, ^predecessor, :normal},
                   5_000,
                   "the settled notified predecessor stayed alive"
  end

  test "a superseded coordinator is not reaped while cleanup is still pending" do
    # Concept: owner loss does not erase cleanup the predecessor already owns;
    # it may leave only after every cleanup disposition has settled.
    #
    # Technical depth: a cleanup with no host job can sit in `pending_cleanup`
    # while its `cleanup_settled` message is queued, so `in_flight` alone is not
    # the lifecycle authority. A settled run supplies an otherwise empty real
    # coordinator, and an exact pending entry makes that mailbox interval
    # deterministic. Deleting the pending-cleanup term from the reaper predicate
    # stops the coordinator at the first cast and fails only this case.
    fixture = start(script: [%{text: "done", calls: []}])
    {_session_id, attachment, _reply} = Fixture.run(fixture, "go")
    assert Enum.find(drain(attachment), &(&1.kind == "run.finished"))["outcome"] == "completed"

    predecessor = coordinator_of(fixture.runtime)
    predecessor_reference = Process.monitor(predecessor)
    before = :sys.get_state(predecessor)

    assert before.in_flight == %{}
    assert before.pending_cleanup == %{}
    assert before.streams == %{}
    assert before.pending_fault == nil

    pending = %{"queued-cleanup" => %{purpose: :abort, model: nil}}
    :sys.replace_state(predecessor, &%{&1 | pending_cleanup: pending})

    GenServer.cast(predecessor, {:superseded, "replacement-generation"})

    assert %{superseded: true, pending_cleanup: ^pending} = :sys.get_state(predecessor),
           "owner loss reaped the coordinator before its queued cleanup settled"

    :sys.replace_state(predecessor, &%{&1 | pending_cleanup: %{}})
    GenServer.cast(predecessor, {:superseded, "replacement-generation"})

    assert_receive {:DOWN, ^predecessor_reference, :process, ^predecessor, :normal},
                   5_000,
                   "the coordinator remained after its pending cleanup was settled"
  end

  test "an abrupt model owner death never gives its successor the same stream domain" do
    # Concept: abrupt owner death leaves the old transient model view
    # incomplete, but it must not let the successor reuse that attempt's domain.
    #
    # Technical depth: unlike the recognized-supersession case above, the
    # predecessor is killed while its producer is held. Its linked relay must
    # disappear without a closure, the successor must durably advance the
    # inherited attempt before dispatch, and releasing the orphaned producer
    # after the successor finishes must project nothing. This keeps abrupt death
    # and live supersession as distinct full-runtime evidence.
    fixture =
      start(
        script: [
          %{text: "", calls: [], error: :provider_unavailable, hold: self(), deltas: ["a"]},
          %{text: "done", calls: [], deltas: ["b"]}
        ],
        progress_to: self()
      )

    {session_id, _attachment, _reply} = Fixture.run(fixture, "go")
    assert_receive {:holding, model}, 5_000

    predecessor = receive_progress()

    assert [predecessor_delta] =
             Enum.filter(predecessor, &(&1.kind == :text_delta)),
           "the predecessor did not publish the delta that makes its domain observable"

    coordinator = coordinator_of(fixture.runtime)
    coordinator_reference = Process.monitor(coordinator)
    Process.exit(coordinator, :kill)

    assert_receive {:DOWN, ^coordinator_reference, :process, ^coordinator, :killed},
                   5_000

    assert {:ok, ^session_id} =
             Loopex.resume_session(
               fixture.runtime,
               session_id,
               command_id: "resume-after-abrupt-model-owner-death"
             )

    {:ok, resumed} =
      Loopex.attach(fixture.runtime, session_id, after_event_sequence: 0)

    assert await_dispatch_count(fixture, 2),
           "the successor did not dispatch its replacement attempt"

    assert Enum.find(drain(resumed), &(&1.kind == "run.finished"))["outcome"] == "completed"

    successor = receive_progress()
    model_reference = Process.monitor(model)
    send(model, :release)

    assert_receive {:DOWN, ^model_reference, :process, ^model, _reason},
                   5_000,
                   "the orphaned provider task did not settle after release"

    assert receive_progress() == [],
           "the predecessor emitted after abrupt owner and relay death"

    observed = predecessor ++ successor
    domains = observed |> Enum.map(& &1.stream_domain_id) |> Enum.uniq()

    assert length(domains) == 2,
           "the dead predecessor and successor used #{length(domains)} domains"

    successor_domain =
      successor
      |> Enum.find(&(&1.kind == :text_delta))
      |> Map.fetch!(:stream_domain_id)

    assert predecessor_delta.stream_domain_id != successor_domain,
           "the successor reused the abruptly dead predecessor's stream domain"

    refute Enum.any?(predecessor, &(&1.kind == :model_stream_closed)),
           "abrupt owner death fabricated a predecessor closure"

    assert Enum.count(successor, &(&1.kind == :model_stream_closed)) == 1,
           "the successor did not close exactly its own model domain"

    attempts =
      fixture
      |> Fixture.records(session_id)
      |> Enum.filter(&(&1.payload[:kind] == "model_attempt_abandoned"))
      |> Enum.map(& &1.payload["attempt"])

    assert 1 in attempts,
           "the successor re-ran the attempt inherited from the dead predecessor"
  end

  test "a model error before its supersession notification cannot close the old domain" do
    # Concept: an error returned by model work does not authorize a predecessor
    # to describe that attempt after the runtime has begun transferring the
    # session. The successor owns the durable abandonment and retry decision.
    #
    # Technical depth: a forwarding proxy pauses the predecessor at the first
    # ownership operation its model-error path attempts. The successor then
    # begins acquisition and is held after durable owner advancement but before
    # `owner_ready` sends the supersession cast. The conforming path reaches one
    # atomic `close_progress` operation, which Control refuses after acquisition
    # starts. Restoring a separate `current_owner` precheck makes that check
    # answer `:ok` before handoff and resume afterwards into a stale raw close;
    # bypassing the atomic close reaches no boundary at all. Either mutation
    # fails this case instead of passing through an early discard.
    fixture =
      start(
        script: [
          %{
            text: "",
            calls: [],
            error: :provider_unavailable,
            hold: self(),
            deltas: ["before handoff"]
          },
          %{text: "done", calls: [], deltas: ["after handoff"]}
        ],
        progress_to: self()
      )

    {session_id, _attachment, _reply} = Fixture.run(fixture, "go")
    assert_receive {:holding, model}, 5_000
    model_reference = Process.monitor(model)
    predecessor = coordinator_of(fixture.runtime)
    predecessor_reference = Process.monitor(predecessor)

    assert [{{:model, _run_id}, stream}] =
             predecessor
             |> :sys.get_state()
             |> Map.fetch!(:streams)
             |> Map.to_list()

    relay = stream.relay
    relay_reference = Process.monitor(relay)

    assert [first_delta] =
             receive_progress()
             |> Enum.filter(&(&1.kind == :text_delta))

    old_domain = first_delta.stream_domain_id
    real_control = :sys.get_state(predecessor).control
    control_proxy = Loopex.AgentLoopControlBoundaryProxy.start(real_control, self())

    :sys.replace_state(predecessor, &Map.put(&1, :control, control_proxy))

    :ok =
      M1RuntimeTestStore.delay_after_commit(
        fixture.store,
        :session_journal_advance_owner,
        self()
      )

    send(model, :release)

    assert_receive {:control_boundary_waiting, ^control_proxy, boundary_reference, boundary},
                   5_000

    assert boundary == :close_progress,
           "the model error used #{inspect(boundary)} instead of one atomic close boundary"

    resume =
      Task.async(fn ->
        Loopex.resume_session(
          fixture.runtime,
          session_id,
          command_id: "resume-model-error-before-notify"
        )
      end)

    assert_receive {:transaction_linearized, owner_waiter, _store, :session_journal_advance_owner,
                    {:committed, _tx_id, _owner_receipt}},
                   5_000

    assert Task.yield(resume, 0) == nil,
           "the successor became ready before the delayed owner result was released"

    Loopex.AgentLoopControlBoundaryProxy.release(control_proxy, boundary_reference)

    assert_receive {:DOWN, ^model_reference, :process, ^model, _reason},
                   5_000,
                   "the old model worker did not return its error"

    assert_receive {:DOWN, ^relay_reference, :process, ^relay, _reason},
                   5_000,
                   "the model error did not end the old transient plane"

    assert_receive {:DOWN, ^predecessor_reference, :process, ^predecessor, :normal},
                   5_000,
                   "the settled stale model coordinator was not reaped"

    refute Enum.any?(receive_progress(), fn item ->
             item.stream_domain_id == old_domain and item.kind == :model_stream_closed
           end),
           "the stale predecessor described its model error as an abandoned attempt"

    assert length(AgentLoopTestModel.dispatched(fixture.model)) == 1,
           "the successor dispatched a retry before it owned and recovered the run"

    M1RuntimeTestStore.release(owner_waiter)
    assert {:ok, session_id} == Task.await(resume, 5_000)

    resumed =
      case Loopex.attach(fixture.runtime, session_id, after_event_sequence: 0) do
        {:ok, resumed} ->
          resumed

        other ->
          flunk(
            "successor unavailable after model-error recovery: #{inspect(other)}; " <>
              "records=#{inspect(Enum.map(Fixture.records(fixture, session_id), & &1.payload[:kind]))}; " <>
              "dispatches=#{length(AgentLoopTestModel.dispatched(fixture.model))}"
          )
      end

    assert Enum.find(drain(resumed), &(&1.kind == "run.finished"))["outcome"] == "completed"
    assert length(AgentLoopTestModel.dispatched(fixture.model)) == 2

    attempts =
      fixture
      |> Fixture.records(session_id)
      |> Enum.filter(&(&1.payload[:kind] == "model_attempt_abandoned"))
      |> Enum.map(& &1.payload["attempt"])

    assert attempts == [1],
           "the stale predecessor, rather than only its successor, recorded abandonment"
  end

  test "runtime unavailability while closing a model error does not invent owner supersession" do
    # Concept: losing the ownership service is not evidence that another owner
    # exists. The live session therefore keeps running once Control is available
    # again instead of silently abandoning work under an invented succession.
    #
    # Technical depth: inject exactly one `:runtime_unavailable` answer at the
    # real coordinator's `close_progress` boundary. The proxy leaves the real
    # Control and its current-owner slot untouched and forwards every later
    # operation. Marking this coordinator superseded in the catch-all error
    # branch stops it before the retry and makes this case fail on both process
    # identity and completed behavior.
    fixture =
      start(
        script: [
          %{
            text: "",
            calls: [],
            error: :provider_unavailable,
            deltas: ["before unavailable close"],
            hold: self()
          },
          %{text: "done", calls: [], deltas: ["after retry"]}
        ],
        progress_to: self()
      )

    {:ok, session_id} =
      Loopex.create_session(fixture.runtime, %{"tenant" => "t"},
        command_id: "create-runtime-unavailable-close"
      )

    {:ok, attachment} = Loopex.attach(fixture.runtime, session_id, after_event_sequence: 0)
    predecessor = coordinator_of(fixture.runtime)
    predecessor_state = :sys.get_state(predecessor)
    real_control = predecessor_state.control

    control_proxy =
      Loopex.AgentLoopControlBoundaryProxy.start(
        real_control,
        self(),
        {:reply_once, :close_progress, {:error, :runtime_unavailable}}
      )

    :sys.replace_state(predecessor, &Map.put(&1, :control, control_proxy))

    assert {:accepted, "prompt-runtime-unavailable-close"} =
             Loopex.command(attachment, %{
               type: :prompt,
               command_id: "prompt-runtime-unavailable-close",
               content: "go"
             })

    assert_receive {:holding, model}, 5_000

    assert_receive {:loopex_progress, %{kind: :text_delta} = first_delta},
                   5_000,
                   "the first attempt did not publish its delta before the close boundary"

    send(model, :release)

    assert_receive {:control_boundary_injected, ^control_proxy, :close_progress,
                    {:error, :runtime_unavailable}},
                   5_000,
                   "the model-error path never reached the unavailable Control boundary"

    assert await_dispatch_count(fixture, 2),
           "runtime unavailability was treated as owner loss and suppressed the retry"

    assert Enum.find(drain(attachment), &(&1.kind == "run.finished"))["outcome"] ==
             "completed"

    assert Process.alive?(predecessor),
           "the live coordinator was reaped after an unavailable ownership answer"

    assert coordinator_of(fixture.runtime) == predecessor,
           "runtime unavailability replaced the owner without a succession"

    refute :sys.get_state(predecessor).superseded,
           "runtime unavailability was recorded as an owner supersession"

    assert Control.current_owner(real_control, session_id, predecessor_state.owner) == :ok,
           "the real Control no longer recognizes the unchanged owner"

    records = Fixture.records(fixture, session_id)

    assert Enum.count(records, &(&1.payload[:kind] == "model_attempt_abandoned")) == 1
    assert Enum.count(records, &(&1.payload[:kind] == "model_result_committed")) == 1

    progress = receive_progress()

    assert Enum.count(progress, &(&1.kind == :model_stream_closed)) == 1,
           "the unavailable first close fabricated a closure or the successful retry did not close"

    assert [retry_delta] = Enum.filter(progress, &(&1.kind == :text_delta))

    refute first_delta.stream_domain_id == retry_delta.stream_domain_id,
           "the retry reused the unavailable attempt's stream domain"

    [closure] = Enum.filter(progress, &(&1.kind == :model_stream_closed))

    assert closure.stream_domain_id == retry_delta.stream_domain_id,
           "the only truthful closure did not belong to the completed retry"
  end

  test "handoff cannot move between progress admission and relay emission" do
    # Concept: an item belongs to the owner that emits it. Once Control begins
    # replacing that owner, the old callback cannot add another item to its
    # transient domain.
    #
    # Technical depth: the proxy is installed before dispatch but armed only
    # after the model has retained its callback. A conforming callback reaches
    # one atomic project_progress call, which is forwarded only after durable
    # ownership advancement and is refused. Splitting it into current_owner
    # followed by StreamRelay.emit prepares :ok before handoff, resumes after
    # handoff, and leaks the injected delta into the predecessor's live relay.
    fixture =
      start(
        script: [
          %{text: "", calls: [], hold: self(), hold_timeout_ms: 30_000},
          %{text: "done", calls: []}
        ],
        progress_to: self()
      )

    {:ok, session_id} =
      Loopex.create_session(fixture.runtime, %{"tenant" => "t"}, command_id: "create-1")

    {:ok, attachment} = Loopex.attach(fixture.runtime, session_id, after_event_sequence: 0)
    predecessor = coordinator_of(fixture.runtime)
    predecessor_state = :sys.get_state(predecessor)

    control_proxy =
      Loopex.AgentLoopControlBoundaryProxy.start(
        predecessor_state.control,
        self(),
        false
      )

    :sys.replace_state(predecessor, &Map.put(&1, :control, control_proxy))

    assert {:accepted, "prompt-1"} =
             Loopex.command(attachment, %{
               type: :prompt,
               command_id: "prompt-1",
               content: "go"
             })

    assert_receive {:holding, model}, 5_000

    assert [{{:model, _run_id}, stream}] =
             predecessor
             |> :sys.get_state()
             |> Map.fetch!(:streams)
             |> Map.to_list()

    old_domain = stream.domain
    progress = AgentLoopTestModel.retained_progress(fixture.model)

    :ok = Loopex.AgentLoopControlBoundaryProxy.arm(control_proxy)

    emission =
      Task.async(fn ->
        progress.(%{kind: :text_delta, content_index: 0, text: "after the check"})
      end)

    assert_receive {:control_boundary_waiting, ^control_proxy, boundary_reference, boundary},
                   5_000,
                   "the model delta never reached the ownership boundary"

    :ok =
      M1RuntimeTestStore.delay_after_commit(
        fixture.store,
        :session_journal_advance_owner,
        self()
      )

    resume =
      Task.async(fn ->
        Loopex.resume_session(
          fixture.runtime,
          session_id,
          command_id: "resume-progress-admission"
        )
      end)

    assert_receive {:transaction_linearized, owner_waiter, _store, :session_journal_advance_owner,
                    {:committed, _tx_id, _owner_receipt}},
                   5_000,
                   "the successor did not durably advance ownership"

    Loopex.AgentLoopControlBoundaryProxy.release(control_proxy, boundary_reference)
    assert Task.await(emission, 5_000) == :ok

    refute Enum.any?(receive_progress(), fn item ->
             item.kind == :text_delta and item.stream_domain_id == old_domain
           end),
           "a predecessor delta crossed the plane after ownership advancement"

    assert boundary == :project_progress,
           "progress used #{inspect(boundary)} instead of one atomic admission-and-send boundary"

    M1RuntimeTestStore.release(owner_waiter)
    assert {:ok, ^session_id} = Task.await(resume, 5_000)

    assert_receive {:loopex_progress,
                    %{
                      kind: :model_stream_closed,
                      stream_domain_id: ^old_domain,
                      disposition: :abandoned,
                      delta_count: 0
                    }},
                   5_000,
                   "the notified predecessor did not close its empty domain abandoned"

    {:ok, resumed} = Loopex.attach(fixture.runtime, session_id, after_event_sequence: 0)
    assert Enum.find(drain(resumed), &(&1.kind == "run.finished"))["outcome"] == "completed"
    refute Process.alive?(model)
  end

  test "a stale Store refusal of a model result leaves closure and abandonment to the successor" do
    # Concept: a complete provider answer that meets the stale-owner Store fence
    # is not a retained fact. The predecessor therefore ends its transient view
    # without a closure, while the successor owns the durable abandonment and
    # distinct retry.
    #
    # Technical depth: owner advancement is held after Store linearization and
    # before `owner_ready`, so no supersession cast can explain the result. The
    # successful held model answer reaches the Store under the old epoch and is
    # refused there. Treating that as a generic model-result failure kills the
    # coordinator abnormally; closing from the unretained reply fabricates a
    # complete domain. Both mutations fail this case.
    fixture =
      start(
        script: [
          %{text: "stale", calls: [], hold: self(), deltas: ["before fence"]},
          %{text: "done", calls: [], deltas: ["after recovery"]}
        ],
        progress_to: self()
      )

    {session_id, _attachment, _reply} = Fixture.run(fixture, "go")
    assert_receive {:holding, model}, 5_000
    model_reference = Process.monitor(model)

    predecessor = coordinator_of(fixture.runtime)
    predecessor_reference = Process.monitor(predecessor)

    assert [{{:model, _run_id}, stream}] =
             predecessor
             |> :sys.get_state()
             |> Map.fetch!(:streams)
             |> Map.to_list()

    relay_reference = Process.monitor(stream.relay)

    assert [%{kind: :text_delta} = first_delta] = receive_progress()
    old_domain = first_delta.stream_domain_id

    :ok =
      M1RuntimeTestStore.delay_after_commit(
        fixture.store,
        :session_journal_advance_owner,
        self()
      )

    resume =
      Task.async(fn ->
        Loopex.resume_session(
          fixture.runtime,
          session_id,
          command_id: "resume-before-stale-model-result"
        )
      end)

    assert_receive {:transaction_linearized, owner_waiter, _store, :session_journal_advance_owner,
                    {:committed, _tx_id, _owner_receipt}},
                   5_000

    refute :sys.get_state(predecessor).superseded,
           "the ordinary supersession cast arrived before the Store refusal"

    send(model, :release)

    assert_receive {:DOWN, ^model_reference, :process, ^model, _reason},
                   5_000,
                   "the predecessor's model worker did not return its answer"

    assert_receive {:DOWN, ^relay_reference, :process, _relay, _reason},
                   5_000,
                   "the stale Store refusal left the old model relay alive"

    assert_receive {:DOWN, ^predecessor_reference, :process, ^predecessor, :normal},
                   5_000,
                   "the terminal stale-owner refusal killed the predecessor abnormally"

    refute Enum.any?(receive_progress(), fn item ->
             item.stream_domain_id == old_domain and item.kind == :model_stream_closed
           end),
           "an unretained model result fabricated a complete or abandoned closure"

    M1RuntimeTestStore.release(owner_waiter)
    assert {:ok, ^session_id} = Task.await(resume, 5_000)

    {:ok, resumed} = Loopex.attach(fixture.runtime, session_id, after_event_sequence: 0)
    assert await_dispatch_count(fixture, 2)
    assert Enum.find(drain(resumed), &(&1.kind == "run.finished"))["outcome"] == "completed"

    refute Enum.any?(receive_progress(), fn item ->
             item.stream_domain_id == old_domain and item.kind == :model_stream_closed
           end),
           "the successor fabricated a closure under the predecessor's domain"

    attempts =
      fixture
      |> Fixture.records(session_id)
      |> Enum.filter(&(&1.payload[:kind] == "model_attempt_abandoned"))
      |> Enum.map(& &1.payload["attempt"])

    assert attempts == [1]
    assert length(AgentLoopTestModel.dispatched(fixture.model)) == 2
  end

  test "a retained model result closes complete after Control handoff" do
    # Concept: ownership moving after a model result commits does not make that
    # retained reply untrue. Its originating domain still gets the exact
    # `complete` closure the durable result and producer count prove.
    #
    # Technical depth: the Store holds the predecessor after the
    # `model_result_committed` record linearizes. A successor recovers that fact
    # and becomes current in Control before the predecessor receives its Store
    # result. Releasing the result makes the old coordinator's `post_commit`
    # fence refuse it, but the retained result still authorizes the direct close.
    # Replacing that close with `close_current_model_stream/3`, or treating the
    # refused cache projection as an uncommitted result, leaves the old domain
    # without its truthful terminal item and fails this case.
    fixture =
      start(
        script: [%{text: "done", calls: [], deltas: ["retained"], hold: self()}],
        progress_to: self()
      )

    :ok =
      M1RuntimeTestStore.delay_after_record(
        fixture.store,
        "model_result_committed",
        self()
      )

    {session_id, _attachment, reply} = Fixture.run(fixture, "go")
    assert reply == {:accepted, "prompt-1"}
    assert_receive {:holding, model}, 5_000

    predecessor = coordinator_of(fixture.runtime)
    predecessor_reference = Process.monitor(predecessor)

    assert [{{:model, _run_id}, stream}] =
             predecessor
             |> :sys.get_state()
             |> Map.fetch!(:streams)
             |> Map.to_list()

    relay = stream.relay
    relay_reference = Process.monitor(relay)

    assert [delta] =
             receive_progress()
             |> Enum.filter(&(&1.kind == :text_delta))

    old_domain = delta.stream_domain_id

    send(model, :release)

    assert_receive {:record_linearized, result_waiter, _store, "model_result_committed",
                    :session_journal_commit, {:committed, _tx_id, _receipt}},
                   5_000

    assert {:ok, ^session_id} =
             Loopex.resume_session(
               fixture.runtime,
               session_id,
               command_id: "resume-after-retained-model-result"
             )

    M1RuntimeTestStore.release(result_waiter)

    assert_receive {:loopex_progress,
                    %{
                      kind: :model_stream_closed,
                      stream_domain_id: ^old_domain,
                      disposition: :complete,
                      delta_count: 1
                    }},
                   5_000,
                   "the retained model result did not close its originating domain complete"

    assert_receive {:DOWN, ^relay_reference, :process, ^relay, _reason},
                   5_000,
                   "the retained model result left its originating relay alive"

    assert_receive {:DOWN, ^predecessor_reference, :process, ^predecessor, :normal},
                   5_000,
                   "the settled superseded coordinator was not reaped after retaining its result"

    refute Enum.any?(receive_progress(), fn item ->
             item.stream_domain_id == old_domain and item.kind == :model_stream_closed
           end),
           "the retained model result closed its originating domain more than once"

    {:ok, resumed} = Loopex.attach(fixture.runtime, session_id, after_event_sequence: 0)

    assert Enum.find(drain(resumed), &(&1.kind == "run.finished"))["outcome"] == "completed"
    assert length(AgentLoopTestModel.dispatched(fixture.model)) == 1

    records = Fixture.records(fixture, session_id)

    assert Enum.count(records, &(&1.payload[:kind] == "model_result_committed")) == 1
    refute Enum.any?(records, &(&1.payload[:kind] == "model_attempt_abandoned"))
  end

  test "a model result admitted before handoff still closes complete after ownership moves" do
    # Concept: once the Store has retained a model result, a later handoff
    # cannot make its complete disposition or producer count untrue.
    #
    # Technical depth: the forwarding proxy first lets the predecessor's
    # `post_commit` call update Control successfully, then withholds that `:ok`
    # reply. A successor takes ownership while the predecessor is paused between
    # that admitted cache update and its direct close. Releasing the reply must
    # still produce the retained fact's exact complete closure. Adding a second
    # ownership gate around that close discards it and fails this case.
    fixture =
      start(
        script: [%{text: "done", calls: [], deltas: ["retained before handoff"], hold: self()}],
        progress_to: self()
      )

    {session_id, _attachment, reply} = Fixture.run(fixture, "go")
    assert reply == {:accepted, "prompt-1"}
    assert_receive {:holding, model}, 5_000

    predecessor = coordinator_of(fixture.runtime)
    predecessor_reference = Process.monitor(predecessor)
    predecessor_state = :sys.get_state(predecessor)

    assert [{{:model, _run_id}, stream}] = Map.to_list(predecessor_state.streams)

    relay = stream.relay
    relay_reference = Process.monitor(relay)

    assert [delta] =
             receive_progress()
             |> Enum.filter(&(&1.kind == :text_delta))

    old_domain = delta.stream_domain_id

    control_proxy =
      Loopex.AgentLoopControlBoundaryProxy.start(predecessor_state.control, self())

    :sys.replace_state(predecessor, &Map.put(&1, :control, control_proxy))
    send(model, :release)

    assert_receive {:control_boundary_waiting, ^control_proxy, boundary_reference, :post_commit},
                   5_000,
                   "the retained result did not reach its successful post-commit boundary"

    assert Enum.count(
             Fixture.records(fixture, session_id),
             &(&1.payload[:kind] == "model_result_committed")
           ) == 1,
           "the case reached Control before the model result was durable"

    assert receive_progress() == [],
           "the old domain closed before the post-commit result returned"

    assert {:ok, ^session_id} =
             Loopex.resume_session(
               fixture.runtime,
               session_id,
               command_id: "resume-after-admitted-model-result"
             )

    Loopex.AgentLoopControlBoundaryProxy.release(control_proxy, boundary_reference)

    assert_receive {:loopex_progress,
                    %{
                      kind: :model_stream_closed,
                      stream_domain_id: ^old_domain,
                      disposition: :complete,
                      delta_count: 1
                    }},
                   5_000,
                   "the admitted retained result lost its complete closure after handoff"

    assert_receive {:DOWN, ^relay_reference, :process, ^relay, _reason},
                   5_000,
                   "the admitted retained result left its originating relay alive"

    assert_receive {:DOWN, ^predecessor_reference, :process, ^predecessor, :normal},
                   5_000,
                   "the settled superseded coordinator was not reaped after its admitted result"

    {:ok, resumed} = Loopex.attach(fixture.runtime, session_id, after_event_sequence: 0)

    assert Enum.find(drain(resumed), &(&1.kind == "run.finished"))["outcome"] == "completed"
    assert length(AgentLoopTestModel.dispatched(fixture.model)) == 1

    records = Fixture.records(fixture, session_id)
    refute Enum.any?(records, &(&1.payload[:kind] == "model_attempt_abandoned"))
  end

  test "a live executor supersession ends its old stream without claiming the effect abandoned" do
    # Concept: losing session authority says nothing about an effect that is
    # already running. The old progress plane ends, but it cannot call that
    # effect abandoned merely because a successor now owns reconciliation.
    #
    # Technical depth: the executor records its effect, emits one fully bound
    # progress item, and holds the receipt across a real Control succession. The
    # predecessor remains alive long enough to process the supersession cast, so
    # this distinguishes live supersession from the abrupt-owner-death relay
    # case below. The successor reaches the public reconciliation API from the
    # durable `effect_dispatched` fact and dispatches no second job. Restoring
    # the blanket `close_tool_stream(..., :abandoned)` branch publishes the
    # exact false closure this case refuses.
    executor = AgentLoopProgressExecutor.start({:held_after_effect, self()})

    fixture =
      start_with_executor(
        AgentLoopProgressExecutor,
        executor,
        one_call_script(),
        progress_to: self(),
        diagnostics_to: self()
      )

    assert_receive {:executor_effect_held, worker}, 5_000
    worker_reference = Process.monitor(worker)
    predecessor = coordinator_of(fixture.runtime)
    predecessor_reference = Process.monitor(predecessor)

    before_succession = receive_progress()

    assert [progress] = Enum.filter(before_succession, &(&1.kind == :tool_progress))
    assert AgentLoopProgressExecutor.effects(executor) == ["c1"]

    assert {:ok, fixture.session_id} ==
             Loopex.resume_session(
               fixture.runtime,
               fixture.session_id,
               command_id: "resume-executor-1"
             )

    assert await_superseded(predecessor),
           "the live predecessor never processed the supersession notification"

    after_succession = receive_progress()
    old_domain = progress.stream_domain_id

    refute Enum.any?(after_succession, fn item ->
             item.kind == :tool_stream_closed and item.stream_domain_id == old_domain
           end),
           "live supersession called an unproved executor effect abandoned"

    assert Process.alive?(worker),
           "supersession terminated the effectful executor worker instead of reconciling it"

    {:ok, resumed} =
      Loopex.attach(fixture.runtime, fixture.session_id, after_event_sequence: 0)

    assert {:ok, query} = Loopex.reconciliation_query(resumed)
    assert query.current_session_epoch > query.original_session_epoch
    assert query.original_attempt == 1

    assert length(AgentLoopProgressExecutor.jobs(executor)) == 1,
           "the successor retried the executor effect before asking for reconciliation"

    assert :ok = Loopex.reconcile(resumed, Map.put(query, :evidence, "outcome_unknown"))

    events = drain(resumed)
    finished = Enum.find(events, &(&1.kind == "run.finished"))

    assert finished["outcome"] == "outcome_unknown"

    assert length(AgentLoopProgressExecutor.jobs(executor)) == 1,
           "the successor retried an executor effect before reconciling it"

    send(worker, :release)

    assert_receive {:DOWN, ^worker_reference, :process, ^worker, _reason},
                   5_000,
                   "the predecessor's executor worker did not settle after its receipt was released"

    assert_receive {:DOWN, ^predecessor_reference, :process, ^predecessor, :normal},
                   5_000,
                   "the settled superseded coordinator was not reaped after its executor returned"

    refute Enum.any?(receive_progress(), &(&1.stream_domain_id == old_domain)),
           "the fenced predecessor projected an item under its old domain after reconciliation"

    assert length(AgentLoopProgressExecutor.jobs(executor)) == 1
  end

  test "reconciling an unknown effect resolves its steer and promotes its follow up atomically" do
    # Concept: an operator may keep directing a recovered run while its effect is
    # waiting for reconciliation; settling that run must settle the operator's
    # queued input at the same time.
    #
    # Technical depth: this is a real Control succession over an effect-dispatched
    # run. The successor solicits reconciliation, then admits both queue members
    # before committing outcome_unknown. The first read ends at that terminal; the
    # second can finish only if the same proposal resolved the steer and promoted
    # the follow-up. Removing either reducer helper therefore fails this one case:
    # one loses the resolution, and the other leaves the second drain waiting for
    # a run that never starts.
    executor = AgentLoopProgressExecutor.start({:held_after_effect, self()})

    fixture =
      start_with_executor(
        AgentLoopProgressExecutor,
        executor,
        one_call_script(),
        progress_to: self()
      )

    assert_receive {:executor_effect_held, worker}, 5_000
    [job] = AgentLoopProgressExecutor.jobs(executor)
    predecessor = coordinator_of(fixture.runtime)

    assert {:ok, fixture.session_id} ==
             Loopex.resume_session(
               fixture.runtime,
               fixture.session_id,
               command_id: "resume-reconcile-queues"
             )

    assert await_superseded(predecessor)

    {:ok, resumed} =
      Loopex.attach(fixture.runtime, fixture.session_id, after_event_sequence: 0)

    assert {:ok, query} = Loopex.reconciliation_query(resumed)

    assert {:accepted, "recovered-steer"} =
             Loopex.command(resumed, %{
               type: :steer,
               command_id: "recovered-steer",
               run_id: job.run_id,
               content: "apply if another turn starts"
             })

    assert {:accepted, "recovered-follow-up"} =
             Loopex.command(resumed, %{
               type: :follow_up,
               command_id: "recovered-follow-up",
               content: "continue after reconciliation"
             })

    assert :ok = Loopex.reconcile(resumed, Map.put(query, :evidence, "outcome_unknown"))

    first_run = drain(resumed)
    first_finished = Enum.find(first_run, &(&1.kind == "run.finished"))
    assert first_finished["run_id"] == job.run_id
    assert first_finished["outcome"] == "outcome_unknown"

    promoted_run = drain(resumed)

    assert Enum.any?(promoted_run, fn event ->
             event.kind == "steer.resolved" and
               event["command_id"] == "recovered-steer" and
               event["disposition"] == "unapplied" and
               event["reason"] == "run_terminal"
           end)

    promoted_prompt =
      Enum.find(
        promoted_run,
        &(&1.kind == "user.message_appended" and
            &1["command_id"] == "recovered-follow-up")
      )

    assert is_binary(promoted_prompt["run_id"])
    refute promoted_prompt["run_id"] == job.run_id

    promoted_finished = Enum.find(promoted_run, &(&1.kind == "run.finished"))
    assert promoted_finished["run_id"] == promoted_prompt["run_id"]
    assert promoted_finished["outcome"] == "completed"

    send(worker, :release)
  end

  test "an executor progress ownership refusal ends the stale plane without terminating its worker" do
    # Concept: Control refusing one executor item is the ownership verdict for
    # the whole transient plane. The old relay ends immediately, while the
    # already-dispatched effect keeps running so its receipt can be reconciled.
    #
    # Technical depth: the successor's owner transaction is held after it
    # linearizes but before Control can send the ordinary supersession cast. The
    # executor then offers another fully bound item and pauses again. Only that
    # progress-side Control refusal can tell the predecessor it lost ownership;
    # deleting the callback notification leaves the coordinator and relay live,
    # while turning the notification into worker termination loses the receipt.
    executor = AgentLoopProgressExecutor.start({:held_after_effect_and_progress, self()})

    fixture =
      start_with_executor(
        AgentLoopProgressExecutor,
        executor,
        one_call_script(),
        progress_to: self(),
        diagnostics_to: self()
      )

    assert_receive {:executor_effect_held, worker}, 5_000
    worker_reference = Process.monitor(worker)
    predecessor = coordinator_of(fixture.runtime)
    predecessor_reference = Process.monitor(predecessor)

    assert [{{:executor, _run_id}, stream}] =
             predecessor
             |> :sys.get_state()
             |> Map.fetch!(:streams)
             |> Map.to_list()

    relay = ExecutorStream.relay(stream)
    relay_reference = Process.monitor(relay)

    assert [first_progress] =
             receive_progress()
             |> Enum.filter(&(&1.kind == :tool_progress))

    old_domain = first_progress.stream_domain_id
    [job] = AgentLoopProgressExecutor.jobs(executor)

    :ok =
      M1RuntimeTestStore.delay_after_commit(
        fixture.store,
        :session_journal_advance_owner,
        self()
      )

    resume =
      Task.async(fn ->
        Loopex.resume_session(
          fixture.runtime,
          fixture.session_id,
          command_id: "resume-after-progress-fence"
        )
      end)

    assert_receive {:transaction_linearized, owner_waiter, _store, :session_journal_advance_owner,
                    {:committed, _tx_id, owner_receipt}},
                   5_000

    refute :sys.get_state(predecessor).superseded,
           "the ordinary supersession notification arrived before the progress-side verdict"

    send(worker, :release)
    assert_receive {:executor_progress_held, ^worker}, 5_000

    assert await_superseded(predecessor),
           "the progress-side Control refusal did not reach the coordinator"

    assert_receive {:DOWN, ^relay_reference, :process, ^relay, _reason},
                   5_000,
                   "the refused item left the stale executor relay alive"

    assert Process.alive?(worker),
           "ending the stale progress plane terminated the effectful executor worker"

    refute Enum.any?(receive_progress(), fn item ->
             item.stream_domain_id == old_domain
           end),
           "the refused item or an invented closure crossed the stale executor domain"

    refute Enum.any?(diagnostics(), &(&1["kind"] == "executor_progress_refused")),
           "the ownership refusal itself was misreported as refused executor progress"

    M1RuntimeTestStore.release(owner_waiter)
    assert {:ok, fixture.session_id} == Task.await(resume, 5_000)

    send(worker, :release_after_progress)

    assert_receive {:DOWN, ^worker_reference, :process, ^worker, _reason},
                   5_000,
                   "the effectful executor worker did not settle after producing its receipt"

    assert_receive {:DOWN, ^predecessor_reference, :process, ^predecessor, :normal},
                   5_000,
                   "the settled superseded coordinator was not reaped"

    {:ok, resumed} =
      Loopex.attach(fixture.runtime, fixture.session_id, after_event_sequence: 0)

    assert {:ok, query} = Loopex.reconciliation_query(resumed)
    assert query.current_session_epoch == owner_receipt.owner_epoch

    reconciliation =
      query
      |> Map.put(:evidence, "receipt")
      |> Map.put(:retained_receipt, AgentLoopProgressExecutor.receipt(job, 2))

    assert :ok = Loopex.reconcile(resumed, reconciliation)
    assert Enum.find(drain(resumed), &(&1.kind == "run.finished"))["outcome"] == "completed"

    refute Enum.any?(receive_progress(), &(&1.stream_domain_id == old_domain)),
           "the old domain emitted after the successor reconciled the receipt"
  end

  test "runtime unavailability during executor progress does not invent owner loss" do
    # Concept: a temporary failure to reach Control drops that progress item but
    # does not transfer the session, end the operator's task, or turn its effect
    # into a reconciliation problem.
    #
    # Technical depth: install a one-shot unavailable answer before the prompt,
    # so the executor worker's retained callback captures the proxy as its real
    # production boundary. The real Control and current-owner slot remain
    # untouched. Broadening the owner-loss branch to include unavailability
    # sends a false verdict to the coordinator before the same worker's receipt,
    # suppressing the next model dispatch deterministically.
    parent = self()
    executor = AgentLoopProgressExecutor.start(:valid)

    fixture =
      start_with_executor(
        AgentLoopProgressExecutor,
        executor,
        one_call_script(),
        progress_to: self(),
        before_prompt: fn runtime, session_id, _store ->
          predecessor = coordinator_of(runtime)
          predecessor_state = :sys.get_state(predecessor)
          real_control = predecessor_state.control

          control_proxy =
            Loopex.AgentLoopControlBoundaryProxy.start(
              real_control,
              parent,
              {:reply_once, :project_progress, {:error, :runtime_unavailable}}
            )

          :sys.replace_state(predecessor, &Map.put(&1, :control, control_proxy))

          send(
            parent,
            {:runtime_unavailable_progress_fixture, predecessor, real_control,
             predecessor_state.owner, session_id, control_proxy}
          )
        end
      )

    assert_receive {:runtime_unavailable_progress_fixture, predecessor, real_control, owner,
                    session_id, control_proxy},
                   5_000

    assert_receive {:control_boundary_injected, ^control_proxy, :project_progress,
                    {:error, :runtime_unavailable}},
                   5_000,
                   "executor progress never reached the unavailable Control boundary"

    assert await_dispatch_count(fixture, 2),
           "runtime unavailability was treated as owner loss and suppressed the next turn"

    assert Enum.find(drain(fixture.attachment), &(&1.kind == "run.finished"))["outcome"] ==
             "completed"

    assert Process.alive?(predecessor),
           "the live coordinator was reaped after unavailable executor progress"

    assert coordinator_of(fixture.runtime) == predecessor,
           "unavailable executor progress replaced the owner without a succession"

    refute :sys.get_state(predecessor).superseded,
           "unavailable executor progress was recorded as owner loss"

    assert Control.current_owner(real_control, session_id, owner) == :ok,
           "the real Control no longer recognizes the unchanged owner"

    assert length(AgentLoopProgressExecutor.jobs(executor)) == 1,
           "the unavailable progress item caused the executor operation to be retried"

    progress = receive_progress()

    assert Enum.count(progress, &(&1.kind == :tool_stream_closed)) == 1,
           "the completed executor operation did not close exactly one truthful domain"

    assert Enum.any?(progress, fn
             %{kind: :tool_stream_closed, disposition: :complete} -> true
             _other -> false
           end),
           "the completed executor operation did not close its domain complete"
  end

  test "runtime unavailability while closing a refused tool does not invent owner loss" do
    # Concept: Control unavailability does not prove that a successor exists.
    # The current coordinator keeps its authority and continues the run after
    # discarding the transient plane whose close could not be admitted.
    #
    # Technical depth: a pre-effect refusal reaches the ordinary abandoned tool
    # close without emitting progress. A one-shot proxy refuses exactly that
    # `close_progress`; all later operations reach the unchanged real Control.
    # Treating the catch-all as owner loss marks the coordinator superseded and
    # deterministically prevents the second model dispatch.
    parent = self()

    executor =
      AgentLoopAnsweringExecutor.start(%{
        "c1" => {:before_effect, {:error, :invalid_tool_arguments}}
      })

    fixture =
      start_with_executor(
        AgentLoopAnsweringExecutor,
        executor,
        one_call_script(),
        progress_to: self(),
        before_prompt: fn runtime, session_id, _store ->
          predecessor = coordinator_of(runtime)
          predecessor_state = :sys.get_state(predecessor)
          real_control = predecessor_state.control

          control_proxy =
            Loopex.AgentLoopControlBoundaryProxy.start(
              real_control,
              parent,
              {:reply_once, :close_progress, {:error, :runtime_unavailable}}
            )

          :sys.replace_state(predecessor, &Map.put(&1, :control, control_proxy))

          send(
            parent,
            {:runtime_unavailable_tool_close_fixture, predecessor, real_control,
             predecessor_state.owner, session_id, control_proxy}
          )
        end
      )

    assert_receive {:runtime_unavailable_tool_close_fixture, predecessor, real_control, owner,
                    session_id, control_proxy},
                   5_000

    assert_receive {:control_boundary_injected, ^control_proxy, :close_progress,
                    {:error, :runtime_unavailable}},
                   5_000,
                   "the refused-tool path never reached the unavailable Control boundary"

    assert await_dispatch_count(fixture, 2),
           "runtime unavailability was treated as owner loss and suppressed the next turn"

    events = drain(fixture.attachment)
    finished = Enum.find(events, &(&1.kind == "run.finished"))
    assert finished["outcome"] == "completed"
    assert finished["reconciliation_ref"] == nil

    assert Process.alive?(predecessor),
           "the live coordinator was reaped after an unavailable ownership answer"

    assert coordinator_of(fixture.runtime) == predecessor,
           "runtime unavailability replaced the owner without a succession"

    refute :sys.get_state(predecessor).superseded,
           "runtime unavailability was recorded as an owner supersession"

    assert Control.current_owner(real_control, session_id, owner) == :ok,
           "the real Control no longer recognizes the unchanged owner"

    assert AgentLoopAnsweringExecutor.effects(executor) == []
    assert length(AgentLoopAnsweringExecutor.jobs(executor)) == 1

    tool = Enum.find(events, &(&1.kind == "tool.finished"))
    assert tool["outcome"] == "failed"

    refute Enum.any?(receive_progress(), &(&1.kind == :tool_stream_closed)),
           "the unavailable close fabricated a tool-stream closure"
  end

  test "a durable owner handoff fences executor progress and closure before its notification arrives" do
    # Concept: the Store can make the successor the durable owner before the old
    # coordinator receives Control's supersession cast. That interval does not
    # let the old transient plane describe an effect it no longer has authority
    # to describe.
    #
    # Technical depth: the test Store pauses the successor after `advance_owner`
    # linearizes but before its result reaches recovery and `owner_ready`. The
    # predecessor is therefore demonstrably not yet marked superseded when its
    # held executor emits one more item and returns its receipt. Control has
    # already serialized the handoff, so it refuses both the item and any
    # ordinary closure. Restoring an unguarded progress send or changing the
    # stale-owner receipt branch back to `close_tool_stream(..., :abandoned)`
    # makes this case fail while the recognized-supersession case above remains
    # green.
    executor = AgentLoopProgressExecutor.start({:held_after_effect, self()})

    fixture =
      start_with_executor(
        AgentLoopProgressExecutor,
        executor,
        one_call_script(),
        progress_to: self()
      )

    assert_receive {:executor_effect_held, worker}, 5_000
    worker_reference = Process.monitor(worker)
    predecessor = coordinator_of(fixture.runtime)
    predecessor_reference = Process.monitor(predecessor)

    assert [{{:executor, _run_id}, stream}] =
             predecessor
             |> :sys.get_state()
             |> Map.fetch!(:streams)
             |> Map.to_list()

    relay = ExecutorStream.relay(stream)
    relay_reference = Process.monitor(relay)

    assert [progress] =
             receive_progress()
             |> Enum.filter(&(&1.kind == :tool_progress))

    old_domain = progress.stream_domain_id
    [job] = AgentLoopProgressExecutor.jobs(executor)

    :ok =
      M1RuntimeTestStore.delay_after_commit(
        fixture.store,
        :session_journal_advance_owner,
        self()
      )

    resume =
      Task.async(fn ->
        Loopex.resume_session(
          fixture.runtime,
          fixture.session_id,
          command_id: "resume-executor-before-notify"
        )
      end)

    assert_receive {:transaction_linearized, owner_waiter, _store, :session_journal_advance_owner,
                    {:committed, _tx_id, owner_receipt}},
                   5_000

    assert owner_receipt.owner_epoch > job.origin_session_epoch

    refute :sys.get_state(predecessor).superseded,
           "the case no longer holds the successor before its notification"

    assert Task.yield(resume, 0) == nil,
           "the successor became ready before the delayed owner result was released"

    send(worker, :release)

    assert_receive {:DOWN, ^worker_reference, :process, ^worker, _reason},
                   5_000,
                   "the old executor worker did not finish after its receipt was released"

    assert_receive {:DOWN, ^relay_reference, :process, ^relay, _reason},
                   5_000,
                   "the old executor stream did not end after its receipt met the ownership fence"

    refute Enum.any?(receive_progress(), fn item ->
             item.stream_domain_id == old_domain and
               item.kind in [:tool_progress, :tool_stream_closed]
           end),
           "the stale predecessor projected progress or a closure after ownership moved"

    assert_receive {:DOWN, ^predecessor_reference, :process, ^predecessor, :normal},
                   5_000,
                   "the stale coordinator was not reaped after its executor receipt was refused"

    assert length(AgentLoopProgressExecutor.jobs(executor)) == 1,
           "the successor retried the executor effect before reconciliation"

    M1RuntimeTestStore.release(owner_waiter)
    assert {:ok, fixture.session_id} == Task.await(resume, 5_000)

    {:ok, resumed} =
      Loopex.attach(fixture.runtime, fixture.session_id, after_event_sequence: 0)

    assert {:ok, query} = Loopex.reconciliation_query(resumed)
    assert query.current_session_epoch == owner_receipt.owner_epoch
    assert query.original_attempt == 1

    reconciliation =
      query
      |> Map.put(:evidence, "receipt")
      |> Map.put(:retained_receipt, AgentLoopProgressExecutor.receipt(job, 2))

    assert :ok = Loopex.reconcile(resumed, reconciliation)

    assert Enum.find(drain(resumed), &(&1.kind == "run.finished"))["outcome"] == "completed"

    assert length(AgentLoopProgressExecutor.jobs(executor)) == 1
  end

  test "a malformed executor receipt cannot close the old domain across an owner handoff" do
    # Concept: malformed evidence gives the predecessor no disposition it may
    # publish after Control has begun moving the session to another owner.
    # Invalidity does not turn lost authority into proof of abandonment.
    #
    # Technical depth: the executor holds a receipt whose progress count cannot
    # be a count. The successor's owner transaction is paused after it becomes
    # durable but before the predecessor receives the supersession cast, then
    # the malformed receipt is released. Its validation fails before a Store
    # commit, so this drives the `{:invalid, reason}` branch rather than the
    # stale-owner branch above. The ownership-fenced close must discard the
    # relay without a closure. Replacing it with raw `close_tool_stream/3`
    # publishes `abandoned` and fails this case.
    executor =
      AgentLoopAnsweringExecutor.start(%{"c1" => {:held_after_effect, self()}})

    fixture =
      start_with_executor(
        AgentLoopAnsweringExecutor,
        executor,
        one_call_script(),
        receipt_extras: %{progress_count: -1},
        progress_to: self(),
        diagnostics_to: self()
      )

    assert_receive {:executor_receipt_held, worker}, 5_000
    worker_reference = Process.monitor(worker)
    predecessor = coordinator_of(fixture.runtime)
    predecessor_reference = Process.monitor(predecessor)

    assert [{{:executor, _run_id}, stream}] =
             predecessor
             |> :sys.get_state()
             |> Map.fetch!(:streams)
             |> Map.to_list()

    relay = ExecutorStream.relay(stream)
    relay_reference = Process.monitor(relay)
    old_domain = stream.domain

    :ok =
      M1RuntimeTestStore.delay_after_commit(
        fixture.store,
        :session_journal_advance_owner,
        self()
      )

    resume =
      Task.async(fn ->
        Loopex.resume_session(
          fixture.runtime,
          fixture.session_id,
          command_id: "resume-malformed-receipt-before-notify"
        )
      end)

    assert_receive {:transaction_linearized, owner_waiter, _store, :session_journal_advance_owner,
                    {:committed, _tx_id, owner_receipt}},
                   5_000

    refute :sys.get_state(predecessor).superseded,
           "the case no longer holds the successor before its notification"

    send(worker, :answer)

    assert_receive {:DOWN, ^worker_reference, :process, ^worker, _reason},
                   5_000,
                   "the old executor worker did not return its malformed receipt"

    assert_receive {:DOWN, ^relay_reference, :process, ^relay, _reason},
                   5_000,
                   "the malformed receipt did not end the old executor stream"

    assert_receive {:DOWN, ^predecessor_reference, :process, ^predecessor, :normal},
                   5_000,
                   "the malformed stale receipt kept its settled predecessor alive"

    refute Enum.any?(diagnostics(), &(&1["kind"] == "executor_effect_unproven")),
           "the stale predecessor diagnosed and attempted later run work"

    refute Enum.any?(receive_progress(), fn item ->
             item.stream_domain_id == old_domain and item.kind == :tool_stream_closed
           end),
           "the fenced predecessor described the malformed receipt as an abandoned effect"

    assert length(AgentLoopAnsweringExecutor.jobs(executor)) == 1,
           "the successor retried before recovering the unproved effect"

    M1RuntimeTestStore.release(owner_waiter)
    assert {:ok, fixture.session_id} == Task.await(resume, 5_000)

    {:ok, resumed} =
      Loopex.attach(fixture.runtime, fixture.session_id, after_event_sequence: 0)

    assert {:ok, query} = Loopex.reconciliation_query(resumed)
    assert query.current_session_epoch == owner_receipt.owner_epoch
    assert query.original_attempt == 1

    assert :ok = Loopex.reconcile(resumed, Map.put(query, :evidence, "outcome_unknown"))

    assert Enum.find(drain(resumed), &(&1.kind == "run.finished"))["outcome"] ==
             "outcome_unknown"

    assert length(AgentLoopAnsweringExecutor.jobs(executor)) == 1
  end

  test "a stale non receipt executor answer leaves diagnosis and reconciliation to the successor" do
    # Concept: once ownership moves, an executor answer without a retained
    # receipt cannot authorize a diagnostic, a terminal fact, or later run work
    # from the predecessor.
    #
    # Technical depth: the executor has performed its effect and remains held
    # across a real full-runtime succession. The supersession notification ends
    # the old plane but deliberately leaves the evidence-producing worker alive.
    # Releasing it returns no receipt. The stale coordinator must stop normally
    # without emitting `executor_effect_unproven`; the successor alone exposes
    # and settles the reconciliation query. Disabling the superseded guard in
    # the non-receipt result path fails only this case.
    executor = AgentLoopProgressExecutor.start({:held_after_effect_then_lost, self()})

    fixture =
      start_with_executor(
        AgentLoopProgressExecutor,
        executor,
        one_call_script(),
        progress_to: self(),
        diagnostics_to: self()
      )

    assert_receive {:executor_effect_held, worker}, 5_000
    worker_reference = Process.monitor(worker)
    predecessor = coordinator_of(fixture.runtime)
    predecessor_reference = Process.monitor(predecessor)

    assert [{{:executor, _run_id}, stream}] =
             predecessor
             |> :sys.get_state()
             |> Map.fetch!(:streams)
             |> Map.to_list()

    relay = ExecutorStream.relay(stream)
    relay_reference = Process.monitor(relay)

    assert [first_progress] =
             receive_progress()
             |> Enum.filter(&(&1.kind == :tool_progress))

    old_domain = first_progress.stream_domain_id

    assert {:ok, fixture.session_id} ==
             Loopex.resume_session(
               fixture.runtime,
               fixture.session_id,
               command_id: "resume-before-non-receipt-answer"
             )

    assert await_superseded(predecessor),
           "the predecessor did not receive the full-runtime ownership handoff"

    assert_receive {:DOWN, ^relay_reference, :process, ^relay, _reason},
                   5_000,
                   "the handoff left the predecessor's old executor plane alive"

    refute Enum.any?(receive_progress(), fn item ->
             item.stream_domain_id == old_domain and item.kind == :tool_stream_closed
           end),
           "owner loss fabricated a closure for the unproved executor effect"

    send(worker, :release)

    assert_receive {:DOWN, ^worker_reference, :process, ^worker, _reason},
                   5_000,
                   "the evidence-producing executor worker did not return its error"

    assert_receive {:DOWN, ^predecessor_reference, :process, ^predecessor, :normal},
                   5_000,
                   "the stale non-receipt answer killed or retained the predecessor"

    refute Enum.any?(diagnostics(), &(&1["kind"] == "executor_effect_unproven")),
           "the stale predecessor diagnosed an effect only the successor may reconcile"

    records = Fixture.records(fixture, fixture.session_id)

    refute Enum.any?(records, &(&1.payload[:kind] == "outcome_unknown_committed")),
           "the stale predecessor committed a terminal operation fact after handoff"

    {:ok, resumed} =
      Loopex.attach(fixture.runtime, fixture.session_id, after_event_sequence: 0)

    assert {:ok, query} = Loopex.reconciliation_query(resumed)
    assert :ok = Loopex.reconcile(resumed, Map.put(query, :evidence, "outcome_unknown"))

    assert Enum.find(drain(resumed), &(&1.kind == "run.finished"))["outcome"] ==
             "outcome_unknown"

    assert length(AgentLoopProgressExecutor.jobs(executor)) == 1
  end

  test "an executor receipt admitted before handoff still closes complete after ownership moves" do
    # Concept: a retained executor receipt fixes its originating stream even
    # when Control admitted it before a handoff and the coordinator receives
    # that admission reply afterwards.
    #
    # Technical depth: the forwarding proxy lets `post_commit` update Control,
    # then withholds the successful reply. A successor takes ownership while the
    # predecessor is paused between that admission and its direct close. The
    # closure must still carry the receipt's exact count, while the now-stale
    # coordinator must not start the separate refused-progress transaction.
    # Replacing the direct close with the current-owner-gated close loses the
    # terminal item and fails only this case.
    executor = AgentLoopProgressExecutor.start({:held_after_effect_with_refusal, self()})

    fixture =
      start_with_executor(
        AgentLoopProgressExecutor,
        executor,
        one_call_script(),
        progress_to: self(),
        diagnostics_to: self()
      )

    assert_receive {:executor_effect_held, worker}, 5_000
    worker_reference = Process.monitor(worker)
    predecessor = coordinator_of(fixture.runtime)
    predecessor_reference = Process.monitor(predecessor)
    predecessor_state = :sys.get_state(predecessor)

    assert [{{:executor, _run_id}, stream}] = Map.to_list(predecessor_state.streams)

    relay = ExecutorStream.relay(stream)
    relay_reference = Process.monitor(relay)

    assert [first_progress] =
             receive_progress()
             |> Enum.filter(&(&1.kind == :tool_progress))

    old_domain = first_progress.stream_domain_id

    control_proxy =
      Loopex.AgentLoopControlBoundaryProxy.start(predecessor_state.control, self())

    :sys.replace_state(predecessor, &Map.put(&1, :control, control_proxy))
    send(worker, :release)

    assert_receive {:control_boundary_waiting, ^control_proxy, boundary_reference, :post_commit},
                   5_000,
                   "the retained receipt did not reach its successful post-commit boundary"

    assert_receive {:DOWN, ^worker_reference, :process, ^worker, _reason},
                   5_000,
                   "the executor worker did not return the retained receipt"

    assert Enum.any?(
             Fixture.records(fixture, fixture.session_id),
             &(&1.payload[:kind] == "executor_receipt_committed")
           ),
           "the case reached Control before the executor receipt was durable"

    refute Enum.any?(receive_progress(), &(&1.kind == :tool_stream_closed)),
           "the old domain closed before the admitted post-commit result returned"

    assert {:ok, fixture.session_id} ==
             Loopex.resume_session(
               fixture.runtime,
               fixture.session_id,
               command_id: "resume-after-admitted-executor-receipt"
             )

    Loopex.AgentLoopControlBoundaryProxy.release(control_proxy, boundary_reference)

    assert_receive {:loopex_progress,
                    %{
                      kind: :tool_stream_closed,
                      stream_domain_id: ^old_domain,
                      disposition: :complete,
                      progress_count: 3
                    }},
                   5_000,
                   "the admitted retained receipt lost its complete closure after handoff"

    assert_receive {:DOWN, ^relay_reference, :process, ^relay, _reason},
                   5_000,
                   "the admitted retained receipt left its originating relay alive"

    assert_receive {:DOWN, ^predecessor_reference, :process, ^predecessor, :normal},
                   5_000,
                   "the settled predecessor stayed alive after its admitted receipt"

    refute Enum.any?(diagnostics(), &(&1["kind"] == "executor_progress_refused")),
           "the stale coordinator emitted refusal diagnostics after handoff"

    records = Fixture.records(fixture, fixture.session_id)

    refute Enum.any?(records, &(&1.payload[:kind] == "executor_progress_refused")),
           "the stale coordinator retained refusal accounting after handoff"

    {:ok, resumed} =
      Loopex.attach(fixture.runtime, fixture.session_id, after_event_sequence: 0)

    assert Enum.find(drain(resumed), &(&1.kind == "run.finished"))["outcome"] == "completed"
    assert length(AgentLoopProgressExecutor.jobs(executor)) == 1
  end

  test "a retained executor receipt closes complete after Control handoff" do
    # Concept: a receipt that became durable under the predecessor remains true
    # after Control installs the successor. Losing the runtime-local owner slot
    # must not turn that committed fact into a failed executor operation or
    # discard the truthful complete closure it supports.
    #
    # Technical depth: the Store pauses the executor-receipt transaction after
    # linearization. The successor reads that new journal head, advances
    # ownership, recovers the retained receipt, and becomes current in Control
    # while the predecessor still waits for its Store result. Releasing the
    # result makes the predecessor's `post_commit` fence answer
    # `:superseded_owner`. The receipt still fixes the old domain's complete
    # disposition and producer count. Treating that answer as an uncommitted
    # receipt kills the predecessor; guarding the close by current ownership
    # discards the truthful terminal item. Either mutation fails this case.
    executor = AgentLoopProgressExecutor.start({:held_after_effect_with_refusal, self()})

    fixture =
      start_with_executor(
        AgentLoopProgressExecutor,
        executor,
        one_call_script(),
        progress_to: self(),
        diagnostics_to: self()
      )

    assert_receive {:executor_effect_held, worker}, 5_000
    worker_reference = Process.monitor(worker)
    predecessor = coordinator_of(fixture.runtime)
    predecessor_reference = Process.monitor(predecessor)

    assert [{{:executor, _run_id}, stream}] =
             predecessor
             |> :sys.get_state()
             |> Map.fetch!(:streams)
             |> Map.to_list()

    relay = ExecutorStream.relay(stream)
    relay_reference = Process.monitor(relay)

    assert [first_progress] =
             receive_progress()
             |> Enum.filter(&(&1.kind == :tool_progress))

    old_domain = first_progress.stream_domain_id

    :ok =
      M1RuntimeTestStore.delay_after_commit(
        fixture.store,
        :session_journal_commit,
        self()
      )

    send(worker, :release)

    assert_receive {:transaction_linearized, receipt_waiter, _store, :session_journal_commit,
                    {:committed, _tx_id, _receipt}},
                   5_000

    assert_receive {:DOWN, ^worker_reference, :process, ^worker, _reason},
                   5_000,
                   "the old executor worker did not return the receipt the Store retained"

    assert Enum.any?(receive_progress(), fn item ->
             item.kind == :tool_progress and item.stream_domain_id == old_domain
           end),
           "the executor did not publish its held progress before succession began"

    assert {:ok, fixture.session_id} ==
             Loopex.resume_session(
               fixture.runtime,
               fixture.session_id,
               command_id: "resume-after-retained-receipt"
             )

    assert length(AgentLoopProgressExecutor.jobs(executor)) == 1,
           "the successor retried an executor operation whose receipt was durable"

    M1RuntimeTestStore.release(receipt_waiter)

    assert_receive {:loopex_progress,
                    %{
                      kind: :tool_stream_closed,
                      stream_domain_id: ^old_domain,
                      disposition: :complete,
                      progress_count: 3
                    }},
                   5_000,
                   "the retained executor receipt did not close its originating domain complete"

    assert_receive {:DOWN, ^relay_reference, :process, ^relay, _reason},
                   5_000,
                   "the predecessor's old executor stream remained live after Control handoff"

    assert_receive {:DOWN, ^predecessor_reference, :process, ^predecessor, :normal},
                   5_000,
                   "the settled superseded coordinator was not reaped after retaining its receipt"

    refute Enum.any?(diagnostics(), &(&1["kind"] == "executor_progress_refused")),
           "the stale coordinator emitted a refusal diagnostic after ownership moved"

    records = Fixture.records(fixture, fixture.session_id)

    assert Enum.any?(records, &(&1.payload[:kind] == "executor_receipt_committed")),
           "the delayed Store result did not retain the receipt this case depends on"

    refute Enum.any?(records, &(&1.payload[:kind] == "executor_progress_refused")),
           "the stale coordinator retained a second refusal transaction after ownership moved"

    {:ok, resumed} =
      Loopex.attach(fixture.runtime, fixture.session_id, after_event_sequence: 0)

    assert Enum.find(drain(resumed), &(&1.kind == "run.finished"))["outcome"] == "completed"
    assert length(AgentLoopProgressExecutor.jobs(executor)) == 1
  end

  test "a stream relay ends with the owner that opened it, ahead of its own backlog" do
    # Concept: an owner death ends its transient plane without inventing a
    # disposition the durable record may contradict.
    #
    # Technical depth: the task supervisor relays run under belongs to the
    # runtime rather than to one session, so it survives a coordinator that stops
    # mid-run — which is what a refused commit on the cleanup path makes the
    # coordinator do. A relay that only ended on `close/2` would sit in `receive`
    # for the life of the runtime, one for every domain that never got closed.
    #
    # A monitor's `:DOWN` would queue behind whatever a producer already handed
    # the relay and would have to guess whether the durable result committed
    # immediately before the owner died. A link ends this plane without draining
    # the backlog or fabricating `abandoned`; ADR 0011 defines the resulting
    # missing closure as an incomplete transient view.
    supervisor =
      start_supervised!({Task.Supervisor, name: :"relay-#{System.unique_integer([:positive])}"})

    parent = self()

    owner =
      spawn(fn ->
        {:ok, relay} =
          StreamRelay.open(
            supervisor,
            parent,
            fn item, sequence -> %{kind: :item, item: item, model_sequence: sequence} end,
            fn disposition, count ->
              %{kind: :closed, disposition: disposition, delta_count: count}
            end
          )

        send(parent, {:opened, relay})

        receive do
          :never -> :ok
        end
      end)

    assert_receive {:opened, relay}, 5_000
    assert Process.alive?(relay)

    :erlang.suspend_process(relay)
    Enum.each(1..5, &StreamRelay.emit(relay, &1))

    reference = Process.monitor(relay)
    Process.exit(owner, :kill)

    assert_receive {:DOWN, ^reference, :process, ^relay, _reason},
                   5_000,
                   "the relay outlived the owner that opened it"

    assert receive_progress() == [],
           "the dead owner's relay drained backlog or fabricated a closure after its plane ended"
  end

  test "two attempts of one tool operation never share a stream domain" do
    # Concept: ADR 0011 makes a stream domain one `(operation_id, attempt)`
    # pair's progress stream. Two attempts of one operation sharing a label runs
    # their sequences together and makes each closing total describe the other's
    # items.
    #
    # Technical depth: the coordinator named the attempt at the dispatch site,
    # and nothing drove it. Replacing `job.attempt` with the literal one left the
    # whole suite green, because `build_job/4` dispatches attempt one and this
    # milestone never dispatches a second attempt of a tool operation — an
    # unproven effect is never blindly retried, which is a non-negotiable rather
    # than an omission. So the branch was unreachable from the loop, and a seam
    # that injected an attempt the design refuses to produce would have been a
    # case observing the seam rather than the runtime.
    #
    # The opener has one production home instead. It is exactly what the
    # coordinator calls, and it takes two real job requests here — identical
    # except for the attempt the reconciliation contract distinguishes them by.
    # The dispatch site no longer names the attempt at all, so it cannot name a
    # different one than the job carries; opening, sequencing and closure are
    # driven through the same relay path an executor job uses in a live run.
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
      resource_budgets: %{"max_output_bytes" => 1024, "max_wall_time_ms" => 30_000},
      idempotency_class: "reconcile_then_retry",
      fencing_token: 1,
      artifact_policy: %{"retain" => true},
      output_policy: %{"capture" => true}
    }

    {:ok, first} = Loopex.Executor.job(base)
    {:ok, second} = Loopex.Executor.job(%{base | attempt: 2})

    assert first.operation_id == second.operation_id,
           "the two jobs are not two attempts of one operation"

    supervisor =
      start_supervised!(
        {Task.Supervisor, name: :"executor-stream-#{System.unique_integer([:positive])}"}
      )

    {:ok, first_stream, first_progress} =
      ExecutorStream.open(supervisor, self(), first, 17, &StreamRelay.emit/2)

    {:ok, second_stream, second_progress} =
      ExecutorStream.open(supervisor, self(), second, 23, &StreamRelay.emit/2)

    first_progress.(
      Map.merge(AgentLoopProgressExecutor.identity(first), %{
        progress_sequence: 0,
        stream: "stdout",
        byte_offset: 0,
        chunk: "first-a"
      })
    )

    first_progress.(
      Map.merge(AgentLoopProgressExecutor.identity(first), %{
        progress_sequence: 1,
        stream: "stdout",
        byte_offset: 7,
        chunk: "first-b"
      })
    )

    second_progress.(
      Map.merge(AgentLoopProgressExecutor.identity(second), %{
        progress_sequence: 0,
        stream: "stderr",
        byte_offset: 0,
        chunk: "second"
      })
    )

    assert ExecutorStream.close(first_stream, :abandoned) == 2
    assert ExecutorStream.close(second_stream, {:complete, 1}) == 1

    observed = receive_progress()
    by_domain = Enum.group_by(observed, & &1.stream_domain_id)

    assert map_size(by_domain) == 2,
           "two attempts of one operation opened #{map_size(by_domain)} stream domains"

    first_domain = Loopex.StreamDomain.for_job(first)
    second_domain = Loopex.StreamDomain.for_job(second)

    assert first_domain != second_domain,
           "two attempts of one operation derived the same stream domain"

    assert Map.has_key?(by_domain, first_domain)
    assert Map.has_key?(by_domain, second_domain)

    assert_domain = fn job, domain, base_event_sequence, disposition, progress_count ->
      items = Map.fetch!(by_domain, domain)
      progress = Enum.reject(items, &(&1.kind == :tool_stream_closed))
      closure = List.last(items)

      assert Enum.map(progress, & &1.progress_sequence) == Enum.to_list(0..(progress_count - 1))
      assert closure.kind == :tool_stream_closed
      assert closure.turn_id == job.turn_id
      assert closure.tool_call_id == job.tool_call_id
      assert closure.stream_domain_id == domain
      assert Enum.all?(items, &(&1.base_event_sequence == base_event_sequence))
      assert closure.disposition == disposition
      assert closure.progress_count == progress_count
      assert closure == Enum.find(items, &(&1.kind == :tool_stream_closed))
    end

    assert_domain.(first, first_domain, 17, :abandoned, 2)
    assert_domain.(second, second_domain, 23, :complete, 1)
  end

  test "an executor that declares no cancellation confirms nothing" do
    # Concept: `cancel/2` is required for a conforming executor. An older or
    # nonconforming module that does not export it has still told this runtime
    # nothing about what its cleanup achieved.
    #
    # Technical depth: the absence used to read as `cleaned`, which is a claim
    # about the executor this repository ships rather than about the port. A
    # third-party executor may own an operating-system process and omit the
    # required callback; reading its silence as confirmed cleanup committed
    # `cancelled` over a process tree nobody signalled and nobody looked at. What
    # this runtime knows is `unconfirmed`, which ends the run `outcome_unknown`
    # carrying a reconciliation reference the operator can act on.
    assert {:cancel, 2} in Loopex.Executor.behaviour_info(:callbacks)
    refute {:cancel, 2} in Loopex.Executor.behaviour_info(:optional_callbacks)

    assert Loopex.Executor.cancel(AgentLoopSilentExecutor, :ignored, "job-1") ==
             {:ok, :unconfirmed},
           "an executor that declares no cancellation had its silence read as a clean stop"

    # And an executor that does declare one is still asked and still answered.
    answering = AgentLoopAnsweringExecutor.start(%{})

    assert Loopex.Executor.cancel(AgentLoopAnsweringExecutor, answering, "job-1") ==
             {:ok, :cleaned}
  end

  test "a stream statistic that is not a count is refused rather than published or committed" do
    # Concept: `delta_count` and `progress_count` are the numbers ADR 0011 closes
    # a complete domain on, and the numbers a consumer compares against what
    # arrived to detect loss. A negative one describes no stream.
    #
    # Technical depth: nothing checked either. An adapter returning
    # `delta_count: -1` had that value published on the closing item and
    # committed into the durable assistant message, so the durable record carried
    # a statistic that cannot be true and the loss comparison became meaningless.
    # An executor receipt reporting `progress_count: -1` did the same on its own
    # plane.
    #
    # The model half takes the abandoned path rather than killing the owner,
    # because an answer this runtime cannot read is what that path is for: the
    # domain closes on what the relay actually emitted, the attempt is charged,
    # and the turn is retried.
    fixture =
      start(
        script: [
          %{text: "one", calls: [], deltas: ["a"], delta_count: -1},
          %{text: "two", calls: [], deltas: ["b"]}
        ],
        progress_to: self()
      )

    {session_id, attachment, _reply} = Fixture.run(fixture, "go")
    events = drain(attachment)

    assert Enum.find(events, &(&1.kind == "run.finished"))["outcome"] == "completed",
           "a malformed count killed the run instead of costing it one attempt"

    observed = receive_progress()
    closures = Enum.filter(observed, &(Map.get(&1, :kind) == :model_stream_closed))

    for closure <- closures do
      assert is_integer(closure.delta_count) and closure.delta_count >= 0,
             "a closing item published #{inspect(closure.delta_count)} as a count"
    end

    assert Enum.any?(closures, &(&1.disposition == :abandoned)),
           "the attempt whose count could not be read was not abandoned"

    counts =
      fixture
      |> Fixture.records(session_id)
      |> Enum.filter(&(&1.payload[:kind] == "model_result_committed"))
      |> Enum.map(&get_in(&1.payload, ["reply", "delta_count"]))

    assert Enum.all?(counts, &(is_nil(&1) or (is_integer(&1) and &1 >= 0))),
           "a durable assistant message carries #{inspect(counts)} as a count"

    # And the two closing-item constructors refuse it directly, which is what
    # makes the rule a property of the public boundary rather than of the two
    # callers that happen to validate before reaching it.
    assert_raise FunctionClauseError, fn ->
      Loopex.StreamDomain.model_closed("t1", "d1", 0, :complete, -1)
    end

    assert_raise FunctionClauseError, fn ->
      Loopex.StreamDomain.tool_closed("t1", "d1", "c1", 0, :complete, -1)
    end

    assert %{delta_count: 0} = Loopex.StreamDomain.model_closed("t1", "d1", 0, :complete, 0)

    # The executor half is refused durably rather than coerced: a receipt this
    # runtime cannot read is not a receipt.
    answering =
      start_with_executor(
        AgentLoopAnsweringExecutor,
        AgentLoopAnsweringExecutor.start(%{}),
        one_call_script(),
        receipt_extras: %{progress_count: -1},
        progress_to: self()
      )

    answering_events = drain(answering.attachment)
    answering_tool = Enum.find(answering_events, &(&1.kind == "tool.finished"))
    answering_finished = Enum.find(answering_events, &(&1.kind == "run.finished"))

    assert answering_tool["outcome"] == "outcome_unknown"
    assert answering_finished["outcome"] == "outcome_unknown"

    assert Process.alive?(coordinator_of(answering.runtime)),
           "a malformed receipt killed the session owner instead of settling the effect unproven"

    refute answering.session_id
           |> then(&Fixture.records(answering, &1))
           |> Enum.any?(&(&1.payload[:kind] == "executor_receipt_committed")),
           "a receipt reporting a negative progress count reached the journal"

    tool_closures =
      receive_progress()
      |> Enum.filter(&(&1.kind == :tool_stream_closed))

    assert [%{disposition: :abandoned, progress_count: 0}] = tool_closures

    refute Enum.any?(tool_closures, &(&1.disposition == :complete)),
           "a malformed receipt was published as a completed tool stream"

    # The same validation order governs a receipt that arrives while an abort is
    # settling the executor worker. This is a different production branch: the
    # ordinary result handler never sees the answer, and cleanup adopts it from
    # the worker mailbox after host cancellation returns.
    cleanup =
      start_with_executor(
        AgentLoopAnsweringExecutor,
        AgentLoopAnsweringExecutor.start(%{"c1" => {:held_after_effect, self()}}),
        one_call_script(),
        receipt_extras: %{progress_count: -1},
        progress_to: self()
      )

    assert_receive {:executor_receipt_held, _worker}, 5_000

    assert {:accepted, "abort-1"} =
             Loopex.command(cleanup.attachment, %{type: :abort, command_id: "abort-1"})

    cleanup_events = drain(cleanup.attachment)
    cleanup_finished = Enum.find(cleanup_events, &(&1.kind == "run.finished"))

    assert cleanup_finished["outcome"] == "outcome_unknown",
           "cleanup treated a malformed receipt as a proved terminal effect"

    cleanup_closures =
      receive_progress()
      |> Enum.filter(&(&1.kind == :tool_stream_closed))

    assert [%{disposition: :abandoned, progress_count: 0}] = cleanup_closures

    refute cleanup.session_id
           |> then(&Fixture.records(cleanup, &1))
           |> Enum.any?(&(&1.payload[:kind] == "executor_receipt_committed")),
           "cleanup committed a receipt whose progress count was malformed"
  end

  test "executor receipts are bounded projected and bind every repeated job identity" do
    # Concept: an executor receipt contributes only its declared terminal fact;
    # private adapter fields and credentials never become durable session data.
    #
    # Technical depth: the first fixture proves projection rather than rejection
    # for a bounded extension. The second supplies a pid, which is outside the
    # Store's plain-data algebra and must become an unproven effect without killing
    # the owner. The literal identity oracle then changes each repeated job field
    # alone on both the live and solicited-reconciliation paths. Restoring raw
    # `encode_plain(receipt)` leaks the first secret and crashes on the pid; deleting
    # any comparison admits the one vector carrying that field's name.
    projected =
      start_with_executor(
        AgentLoopAnsweringExecutor,
        AgentLoopAnsweringExecutor.start(%{}),
        one_call_script(),
        receipt_extras: %{
          provider_api_key: "credential-that-must-not-be-retained",
          adapter_private_note: "private-extension"
        }
      )

    projected_finished = Enum.find(drain(projected.attachment), &(&1.kind == "run.finished"))
    assert projected_finished["outcome"] == "completed"

    projected_record =
      projected
      |> Fixture.records(projected.session_id)
      |> Enum.find(&(&1.payload[:kind] == "executor_receipt_committed"))

    projected_receipt = projected_record.payload["receipt"]
    refute Map.has_key?(projected_receipt, "provider_api_key")
    refute Map.has_key?(projected_receipt, "adapter_private_note")
    refute inspect(projected_record) =~ "credential-that-must-not-be-retained"

    unsupported =
      start_with_executor(
        AgentLoopAnsweringExecutor,
        AgentLoopAnsweringExecutor.start(%{}),
        one_call_script(),
        receipt_extras: %{adapter_private: self()}
      )

    unsupported_events = drain(unsupported.attachment)
    unsupported_tool = Enum.find(unsupported_events, &(&1.kind == "tool.finished"))
    unsupported_finished = Enum.find(unsupported_events, &(&1.kind == "run.finished"))
    assert unsupported_tool["outcome"] == "outcome_unknown"
    assert unsupported_finished["outcome"] == "outcome_unknown"
    assert Process.alive?(coordinator_of(unsupported.runtime))

    refute unsupported
           |> Fixture.records(unsupported.session_id)
           |> Enum.any?(&(&1.payload[:kind] == "executor_receipt_committed"))

    wrong_identities = [
      protocol_version: 2,
      job_id: "wrong-job",
      operation_id: "wrong-operation",
      attempt: 2,
      session_id: "wrong-session",
      run_id: "wrong-run",
      turn_id: "wrong-turn",
      tool_call_id: "wrong-call",
      canonical_request_digest: String.duplicate("0", 64),
      session_epoch_at_dispatch: 99,
      executor_epoch: 99,
      executor_identity: "wrong-executor",
      fencing_token: 99,
      tool_id: "wrong.tool",
      tool_version: "99.0.0"
    ]

    for {field, wrong} <- wrong_identities do
      fixture =
        start_with_executor(
          AgentLoopAnsweringExecutor,
          AgentLoopAnsweringExecutor.start(%{}),
          one_call_script(),
          receipt_extras: %{field => wrong}
        )

      events = drain(fixture.attachment)
      tool = Enum.find(events, &(&1.kind == "tool.finished"))
      finished = Enum.find(events, &(&1.kind == "run.finished"))

      assert tool["outcome"] == "outcome_unknown",
             "a live receipt with wrong #{field} was admitted"

      assert finished["outcome"] == "outcome_unknown"
      assert Process.alive?(coordinator_of(fixture.runtime))

      refute fixture
             |> Fixture.records(fixture.session_id)
             |> Enum.any?(&(&1.payload[:kind] == "executor_receipt_committed")),
             "a live receipt with wrong #{field} reached the journal"
    end

    executor = AgentLoopProgressExecutor.start({:held_after_effect, self()})

    recovered =
      start_with_executor(
        AgentLoopProgressExecutor,
        executor,
        one_call_script(),
        progress_to: self()
      )

    assert_receive {:executor_effect_held, worker}, 5_000
    [job] = AgentLoopProgressExecutor.jobs(executor)
    predecessor = coordinator_of(recovered.runtime)

    assert {:ok, recovered.session_id} ==
             Loopex.resume_session(
               recovered.runtime,
               recovered.session_id,
               command_id: "resume-receipt-identity"
             )

    assert await_superseded(predecessor)

    {:ok, resumed} =
      Loopex.attach(recovered.runtime, recovered.session_id, after_event_sequence: 0)

    assert {:ok, query} = Loopex.reconciliation_query(resumed)
    valid_receipt = AgentLoopProgressExecutor.receipt(job, 2)

    for {field, wrong} <- wrong_identities do
      response =
        query
        |> Map.put(:evidence, "receipt")
        |> Map.put(:retained_receipt, Map.put(valid_receipt, field, wrong))

      assert {:error, {:mismatch, ^field}} = Loopex.reconcile(resumed, response)
    end

    unsupported_response =
      query
      |> Map.put(:evidence, "receipt")
      |> Map.put(:retained_receipt, Map.put(valid_receipt, :adapter_private, self()))

    assert {:error, :invalid_executor_receipt} =
             Loopex.reconcile(resumed, unsupported_response)

    assert Process.alive?(coordinator_of(recovered.runtime)),
           "an unsupported reconciliation receipt killed the current owner"

    response =
      query
      |> Map.put(:evidence, "receipt")
      |> Map.put(
        :retained_receipt,
        Map.put(valid_receipt, :provider_api_key, "reconciliation-secret")
      )

    assert :ok = Loopex.reconcile(resumed, response)
    assert Enum.find(drain(resumed), &(&1.kind == "run.finished"))["outcome"] == "completed"

    reconciled_record =
      recovered
      |> Fixture.records(recovered.session_id)
      |> Enum.find(&(&1.payload[:kind] == "executor_receipt_committed"))

    refute Map.has_key?(reconciled_record.payload["receipt"], "provider_api_key")
    refute inspect(reconciled_record) =~ "reconciliation-secret"

    send(worker, :release)
  end

  test "a complete model stream closes on its reply's own delta count" do
    # Concept: ADR 0011 assigns a complete closure the producer's own statement,
    # and the executor side of that table is proved by
    # `a complete tool stream closes on its receipt's own progress count`. This
    # is the model side of the same rule.
    #
    # Technical depth: the adapter below emits two deltas and reports two. One is
    # past the declared payload ceiling and is refused here, so one item reaches
    # the operator under a closure stating two. That difference is the signal: a
    # consumer comparing the stated total against what it received learns that
    # something did not arrive, whether the transient plane coalesced it away or
    # this runtime refused it. Substituting the count this runtime published --
    # which an earlier round of this amendment did, on both sides -- makes the
    # two numbers agree and leaves a live consumer with no evidence at all.
    fixture =
      start(
        script: [
          %{text: "ab", calls: [], deltas: ["a", String.duplicate("x", 1_000_000)]}
        ],
        progress_to: self()
      )

    {_session_id, attachment, _reply} = Fixture.run(fixture, "go")
    _events = drain(attachment)

    observed = receive_progress()

    closure = Enum.find(observed, &(Map.get(&1, :kind) == :model_stream_closed))
    assert closure, "the model domain was never closed"
    assert closure.disposition == :complete

    deltas = Enum.filter(observed, &(Map.get(&1, :kind) == :text_delta))

    assert length(deltas) == 1,
           "the fixture did not produce one accepted and one refused delta"

    assert closure.delta_count == 2,
           "the closure stated #{closure.delta_count} rather than the two its adapter reported, " <>
             "so a consumer has no evidence that a delta never arrived"
  end

  test "a run that no executor answered still reports the period it would have stopped under" do
    # Concept: the ending that most needs the period is the one with no receipt
    # in it.
    #
    # Technical depth: this run's model answers on its first turn and requests no
    # tool, so no executor is ever dispatched and nothing writes a
    # `cleanup_grace_ms` anywhere. Under the receipt-derived reading the terminal
    # carried `nil`, and an operator had no way to tell a period of zero from a
    # period nobody recorded. It is a session declaration now, so the run reports
    # it regardless of what ran.
    fixture =
      start_with_executor(
        AgentLoopAnsweringExecutor,
        AgentLoopAnsweringExecutor.start(%{}),
        [%{text: "no tools here", calls: []}],
        cleanup_grace_ms: 1_250
      )

    finished = Enum.find(drain(fixture.attachment), &(&1.kind == "run.finished"))

    assert finished["outcome"] == "completed"

    assert finished["cleanup_grace_ms"] == 1_250,
           "a run that dispatched no tool reported #{inspect(finished["cleanup_grace_ms"])} " <>
             "instead of the period its session declared"
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
      |> Map.merge(%{
        progress_sequence: 999,
        stream: "stdout",
        byte_offset: 999,
        chunk: "after the closure"
      })

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
