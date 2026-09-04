Code.require_file("support/m1_runtime_helper.exs", __DIR__)
Code.require_file("support/agent_loop_helper.exs", __DIR__)

defmodule Loopex.TimerDomainTestExecutor do
  @moduledoc false

  # Concept: an executor whose receipt is released by the test rather than by a
  # sleep, so a case can hold the coordinator inside the execute-result reserve
  # for exactly as long as it wants to ask questions of it.
  #
  # Technical depth: `cancel/2` answers `{:ok, :cleaned}` immediately and
  # deliberately does not release the running job. That is the shape the reserve
  # exists for: the process group is reported gone while the call that produced
  # the effect has still said nothing. The test then chooses between the two
  # admitted endings by releasing the job inside the reserve or leaving the
  # reserve to expire.

  @behaviour Loopex.Executor

  def start do
    {:ok, pid} = Agent.start_link(fn -> %{jobs: [], waiting: nil, cancellations: []} end)
    pid
  end

  def jobs(pid), do: Agent.get(pid, & &1.jobs) |> Enum.reverse()
  def cancellations(pid), do: Agent.get(pid, & &1.cancellations) |> Enum.reverse()

  def release(pid) do
    waiting = Agent.get(pid, & &1.waiting)
    if is_pid(waiting), do: send(waiting, :answer)
    :ok
  end

  @impl Loopex.Executor
  def cancel(pid, job_id) do
    :ok =
      Agent.update(pid, fn state -> %{state | cancellations: [job_id | state.cancellations]} end)

    {:ok, :cleaned}
  end

  @impl Loopex.Executor
  def execute(pid, job, _grant, _options, progress \\ nil) do
    _progress = progress || Loopex.Executor.discard_progress()
    caller = self()
    :ok = Agent.update(pid, fn state -> %{state | jobs: [job | state.jobs], waiting: caller} end)

    receive do
      :answer -> :ok
    after
      30_000 -> :ok
    end

    {:ok, receipt(job)}
  end

  def receipt(job) do
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
      output: "wrote #{job.tool_call_id}",
      progress_count: 0,
      observed_at_ms: System.system_time(:millisecond),
      child_environment_names: [],
      provider_credential_present: false,
      artifacts: []
    }
  end
end

defmodule Loopex.TimerDomainTest do
  @moduledoc false

  use ExUnit.Case, async: false

  alias Loopex.AgentLoopFixture, as: Fixture
  alias Loopex.AgentLoopTestModel
  alias Loopex.M1RuntimeTestStore
  alias Loopex.TimerDomainTestExecutor, as: TestExecutor

  @uint64_max 18_446_744_073_709_551_615

  defp call(id), do: %{id: id, name: "write", arguments: %{"path" => id}}

  # Concept: the same public composition every other case uses, with the two
  # numbers this file is about left to the caller.
  #
  # Technical depth: composed through `Loopex.start_link/1` rather than by
  # editing the shared helper, so a case can name an admitted cleanup period or
  # an admitted deadline at the boundary a host would name it at.
  defp start_runtime(options) do
    script = Keyword.fetch!(options, :script)
    model_pid = AgentLoopTestModel.start(script)
    executor_pid = TestExecutor.start()
    {store_pid, store} = M1RuntimeTestStore.start_store(label: "timer-domain")
    definitions = [Fixture.tool_definition()]

    bounds =
      Keyword.get(options, :bounds, %{
        max_turns: 8,
        token_budget: 1_000_000,
        deadline_ms: 600_000
      })

    start =
      [
        context_token_budget: 8_192,
        runtime_id: "timer-domain-#{System.unique_integer([:positive])}",
        store: store,
        model: %{
          module: AgentLoopTestModel,
          model: "scripted:v1",
          options: [script: model_pid, max_tokens: 256]
        },
        executor: %{
          module: TestExecutor,
          reference: executor_pid,
          identity: "timer-domain-executor",
          epoch: 1,
          fencing_token: 1,
          workspace_ref: "workspace-ref",
          workspace_lease: "workspace-lease"
        },
        tool: nil,
        bounds: bounds,
        tools: definitions,
        active_tools: Enum.map(definitions, &Map.fetch!(&1, "tool_id")),
        policy: Loopex.AgentLoopTestPolicy,
        grant_decision: {:host_policy, :allow}
      ] ++ Keyword.take(options, [:cleanup_grace_ms])

    {:ok, runtime} = Loopex.start_link(start)

    fixture = %{runtime: runtime, model: model_pid, executor: executor_pid, store: store_pid}

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

    fixture
  end

  defp attached(fixture) do
    {:ok, session_id} = Loopex.create_session(fixture.runtime, %{"t" => "x"}, command_id: "cs")
    {:ok, attachment} = Loopex.attach(fixture.runtime, session_id, after_event_sequence: 0)
    {session_id, attachment}
  end

  defp dispatched_tool(options) do
    fixture = start_runtime(options)
    {session_id, attachment} = attached(fixture)

    {:accepted, "p1"} =
      Loopex.command(attachment, %{type: :prompt, command_id: "p1", content: "do the work"})

    assert :dispatched = await(fn -> TestExecutor.jobs(fixture.executor) != [] end, :dispatched)
    {fixture, session_id, attachment}
  end

  defp await(check, answer, attempts \\ 600) do
    cond do
      check.() ->
        answer

      attempts > 0 ->
        Process.sleep(10)
        await(check, answer, attempts - 1)

      true ->
        :never
    end
  end

  defp events(attachment, acc \\ []) do
    case Loopex.next_event(attachment) do
      {:ok, event} -> events(attachment, [event | acc])
      _other -> Enum.reverse(acc)
    end
  end

  defp await_run_finished(attachment, acc \\ [], attempts \\ 800) do
    acc = acc ++ events(attachment)

    cond do
      event = Enum.find(acc, &(&1.kind == "run.finished")) ->
        event

      attempts > 0 ->
        Process.sleep(10)
        await_run_finished(attachment, acc, attempts - 1)

      true ->
        flunk("no run.finished was published; saw #{inspect(Enum.map(acc, & &1.kind))}")
    end
  end

  defp coordinator_of(runtime) do
    {:ok, children} = Loopex.Runtime.Supervisor.children(runtime.supervisor)

    [{_id, pid, _type, _modules} | _rest] = DynamicSupervisor.which_children(children.sessions)
    pid
  end

  # ------------------------------------------------------------------
  # B4 -- the execute-result reserve is a state-machine wait
  # ------------------------------------------------------------------

  # Concept: an operator can still be answered while the coordinator is waiting
  # for a receipt it may never get.
  #
  # Technical depth: the reserve used to be a `receive ... after` inside the
  # coordinator's own reduction of the cleanup, so every call queued behind it
  # for the whole reserve. Under a twenty-second grace the derived reserve is
  # seven seconds while `session_status/2` bounds itself at five, which turned a
  # wait into a refusal of an unrelated read. The sampler runs for the whole time
  # the receipt is withheld and the slowest answer it ever got is the assertion.
  test "session status answers while the execute-result reserve is open" do
    {fixture, session_id, attachment} =
      dispatched_tool(script: [%{text: "run it", calls: [call("c1")]}])

    [job] = TestExecutor.jobs(fixture.executor)
    runtime = fixture.runtime

    sampler =
      Task.async(fn ->
        sample_status(runtime, session_id, System.monotonic_time(:millisecond) + 900, 0)
      end)

    assert {:accepted, "abort-1"} =
             Loopex.command(attachment, %{type: :abort, command_id: "abort-1"})

    assert :cancelled =
             await(
               fn -> TestExecutor.cancellations(fixture.executor) == [job.job_id] end,
               :cancelled
             )

    slowest = Task.await(sampler, 10_000)

    assert slowest < 100,
           "a session status read waited #{slowest} ms behind the execute-result reserve"

    # The receipt released inside the reserve is still admitted, so the ending is
    # the one today's cases prove for it.
    :ok = TestExecutor.release(fixture.executor)
    assert await_run_finished(attachment)["outcome"] == "cancelled"
  end

  defp sample_status(runtime, session_id, until, slowest) do
    if System.monotonic_time(:millisecond) >= until do
      slowest
    else
      started = System.monotonic_time(:millisecond)
      _answer = Loopex.session_status(runtime, session_id)
      elapsed = System.monotonic_time(:millisecond) - started
      sample_status(runtime, session_id, until, max(slowest, elapsed))
    end
  end

  # Concept: the reserve expiring still ends the run the way it always did.
  #
  # Technical depth: moving the wait out of the reduction may not move the
  # outcome. Expiry proves only that the reserve elapsed, so the worker is
  # terminated and the operation is unproved, which is `outcome_unknown` carrying
  # the reference an operator reconciles against.
  test "an expired execute-result reserve still settles outcome_unknown" do
    {_fixture, _session_id, attachment} =
      dispatched_tool(
        script: [%{text: "run it", calls: [call("c1")]}],
        cleanup_grace_ms: 40
      )

    assert {:accepted, "abort-1"} =
             Loopex.command(attachment, %{type: :abort, command_id: "abort-1"})

    finished = await_run_finished(attachment)
    assert finished["outcome"] == "outcome_unknown"
    assert is_binary(finished["reconciliation_ref"])
  end

  # ------------------------------------------------------------------
  # B5 -- a near-uint64 deadline is armed in slices
  # ------------------------------------------------------------------

  # Concept: a run may declare a deadline anywhere in its admitted domain and
  # still be dispatched.
  #
  # Technical depth: `arm_deadline/2` handed the whole remaining duration to
  # `Process.send_after/3`, which raises above the VM's timer ceiling. It raised
  # inside the coordinator's own reduction, immediately after `Control` had sent
  # the provider permit, so the run that died was one that may already have been
  # billed. The dispatch is driven all the way to the run's own ending here,
  # because observing the invocation alone is what let the crash pass unseen.
  test "a run with a near-uint64 deadline dispatches and finishes normally" do
    fixture =
      start_runtime(
        script: [%{text: "done"}],
        bounds: %{
          max_turns: 8,
          token_budget: 1_000_000,
          deadline_ms: Integer.pow(2, 63)
        }
      )

    {session_id, attachment} = attached(fixture)
    coordinator = coordinator_of(fixture.runtime)

    assert {:accepted, "p1"} =
             Loopex.command(attachment, %{
               type: :prompt,
               command_id: "p1",
               content: "do the work"
             })

    assert await_run_finished(attachment)["outcome"] == "completed"
    assert Process.alive?(coordinator)
  end

  # Concept: the declared deadline domain is the one the durable plane can carry.
  #
  # Technical depth: `deadline_ms` is admitted over `1..2^64-1`, the same
  # positive unsigned 64-bit domain ADR 0016 gives the cleanup period and ADR
  # 0017 gives the context ceiling. A duration outside it can be represented by
  # no committed instant, so it is refused where every other bound is rather than
  # committed and discovered at replay.
  test "a deadline outside the unsigned 64-bit domain is refused before it is committed" do
    fixture = start_runtime(script: [%{text: "never runs"}])
    {_session_id, attachment} = attached(fixture)

    assert {:error, :invalid_declared_bounds} =
             Loopex.command(attachment, %{
               type: :prompt,
               command_id: "p1",
               content: "do the work",
               bounds: %{max_turns: 8, token_budget: 1_000, deadline_ms: @uint64_max + 1}
             })

    assert {:ok, %{max_turns: 8, token_budget: 1_000, deadline_ms: @uint64_max}} =
             Loopex.Bounds.declare(%{
               max_turns: 8,
               token_budget: 1_000,
               deadline_ms: @uint64_max
             })

    assert {:error, :invalid_declared_bounds} =
             Loopex.Bounds.declare(%{
               max_turns: 8,
               token_budget: 1_000,
               deadline_ms: @uint64_max + 1
             })
  end

  # ------------------------------------------------------------------
  # B6 -- the maximum admitted cleanup period reaches no raw VM timer
  # ------------------------------------------------------------------

  # Concept: the largest cleanup period a host may configure still cancels a run.
  #
  # Technical depth: `cancellation_bounds/1` admits `1..2^64-1`, so the derived
  # `execute_result_reserve_ms` is about 4.6e18 at the maximum. Both the reserve
  # this coordinator arms for an executor answer and the one it arms for a
  # provider answer used to reach `Process.send_after/3` or `receive ... after`
  # whole, which raises `:timeout_value` and kills the coordinator mid-cleanup.
  # The reserve is far longer than the case, so the ending is the one the
  # executor's own answer produces.
  test "the maximum admitted cleanup period cancels a tool call without a timer_value crash" do
    {fixture, session_id, attachment} =
      dispatched_tool(
        script: [%{text: "run it", calls: [call("c1")]}],
        cleanup_grace_ms: @uint64_max
      )

    coordinator = coordinator_of(fixture.runtime)

    assert {:accepted, "abort-1"} =
             Loopex.command(attachment, %{type: :abort, command_id: "abort-1"})

    assert :cancelled =
             await(fn -> TestExecutor.cancellations(fixture.executor) != [] end, :cancelled)

    assert Process.alive?(coordinator)

    :ok = TestExecutor.release(fixture.executor)
    assert await_run_finished(attachment)["outcome"] == "cancelled"
    assert Process.alive?(coordinator)
  end

  # Concept: the same period, reaching the reserve a provider attempt is given.
  #
  # Technical depth: `arm_model_reserve/2` is the other timer derived from the
  # committed cleanup period, armed when a termination lands on an open provider
  # attempt. It is a different clause from the executor reserve and fails the
  # same way, so it is proved separately rather than assumed to travel with it.
  test "the maximum admitted cleanup period terminates a provider attempt" do
    fixture =
      start_runtime(
        script: [%{text: "thinking", hold: self()}],
        cleanup_grace_ms: @uint64_max
      )

    {session_id, attachment} = attached(fixture)
    coordinator = coordinator_of(fixture.runtime)

    assert {:accepted, "p1"} =
             Loopex.command(attachment, %{
               type: :prompt,
               command_id: "p1",
               content: "do the work"
             })

    assert_receive {:holding, model}, 5_000

    assert {:accepted, "abort-1"} =
             Loopex.command(attachment, %{type: :abort, command_id: "abort-1"})

    assert Process.alive?(coordinator)
    send(model, :release)

    assert await_run_finished(attachment)["outcome"] in ["cancelled", "outcome_unknown"]
    assert Process.alive?(coordinator)
  end

  # ------------------------------------------------------------------
  # H1 -- an out-of-domain cleanup period never becomes durable
  # ------------------------------------------------------------------

  # Concept: a cleanup period no session could ever recover under is refused
  # before anything is written, not after.
  #
  # Technical depth: runtime option validation accepted every positive integer
  # while replay enforces ADR 0016's `1..2^64-1`, so `2^64` started a runtime,
  # committed a `session_genesis_v2` naming it, and left the session listed and
  # unrecoverable with `{:error, :owner_recovery_failed}`. The domain is now
  # refused at the runtime option and again on the genesis path, so no durable
  # record can carry a period the same code cannot read back.
  test "an out-of-domain cleanup period is refused at start and at session creation" do
    {store_pid, store} = M1RuntimeTestStore.start_store(label: "timer-domain-grace")

    on_exit(fn ->
      try do
        GenServer.stop(store_pid, :normal, 1_000)
      catch
        :exit, _reason -> :ok
      end
    end)

    model_pid = AgentLoopTestModel.start([%{text: "done"}])

    # `validate_cleanup_grace/1` names the option; `start_link/1` collapses every
    # malformed option to the one reason it always has, and that collapse is not
    # changed here.
    assert {:error, :invalid_runtime_options} =
             Loopex.start_link(
               context_token_budget: 8_192,
               runtime_id: "timer-domain-grace-#{System.unique_integer([:positive])}",
               store: store,
               model: %{
                 module: AgentLoopTestModel,
                 model: "scripted:v1",
                 options: [script: model_pid, max_tokens: 256]
               },
               tool: Loopex.AgentLoopTestExecutor,
               grant_decision: {:host_policy, :allow},
               cleanup_grace_ms: @uint64_max + 1
             )

    # Concept: the genesis path refuses the same domain on its own.
    #
    # Technical depth: the runtime tree is started around the oversized value
    # directly, which is the only way to reach the create with option validation
    # already behind it. Nothing is committed, so the store holds no session and
    # no `session_genesis_v2` naming a period replay would refuse.
    runtime = start_unvalidated_runtime(store, model_pid, @uint64_max + 1)

    assert {:error, :invalid_session_creation} =
             Loopex.create_session(runtime, %{"t" => "x"}, command_id: "cs-oversized")

    assert M1RuntimeTestStore.inspect_state(store_pid).sessions == %{}
  end

  defp start_unvalidated_runtime(store, model_pid, cleanup_grace_ms) do
    token = make_ref()

    {:ok, supervisor} =
      Loopex.Runtime.Supervisor.start_link(
        token: token,
        runtime_id: "timer-domain-genesis-#{System.unique_integer([:positive])}",
        store: store,
        attachment_capacity: 64,
        progress_to: nil,
        diagnostics_to: nil,
        model: %{
          module: AgentLoopTestModel,
          model: "scripted:v1",
          options: [script: model_pid, max_tokens: 256]
        },
        executor: nil,
        tool: Loopex.AgentLoopTestExecutor,
        tools: [],
        declared_tools: [],
        active_tools: [],
        bounds: %{max_turns: 8, token_budget: 1_000, deadline_ms: 600_000},
        sampling: %{"max_tokens" => 256},
        policy: nil,
        project_manifest: nil,
        project_decision: nil,
        grant_decision: {:host_policy, :allow},
        fault_to: nil,
        cleanup_grace_ms: cleanup_grace_ms,
        context_token_budget: 8_192
      )

    on_exit(fn ->
      try do
        Supervisor.stop(supervisor, :normal)
      catch
        :exit, _reason -> :ok
      end
    end)

    %Loopex.Runtime{supervisor: supervisor, token: token}
  end
end
