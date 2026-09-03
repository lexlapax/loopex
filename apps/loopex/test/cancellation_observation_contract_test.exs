Code.require_file("support/m1_runtime_helper.exs", __DIR__)
Code.require_file("support/agent_loop_helper.exs", __DIR__)

defmodule Loopex.CancellationObservationContractTest.CancelObserver do
  @moduledoc false

  @behaviour Loopex.Executor

  @impl Loopex.Executor
  def cancel(observer, job_id) do
    send(observer, {:cancel_callback_reached, job_id})
    {:ok, :cleaned}
  end

  @impl Loopex.Executor
  def execute(_reference, _job, _grant, _options, _progress),
    do: {:error, {:refused_before_effect, :not_used}}
end

defmodule Loopex.CancellationObservationContractTest.DelayedCancelObserver do
  @moduledoc false

  @behaviour Loopex.Executor

  @impl Loopex.Executor
  def cancel({observer, delay_ms}, job_id) do
    send(observer, {:delayed_cancel_started, self(), job_id})
    Process.sleep(delay_ms)
    send(observer, {:delayed_cancel_finished, self(), job_id})
    {:ok, :cleaned}
  end

  @impl Loopex.Executor
  def execute(_reference, _job, _grant, _options, _progress),
    do: {:error, {:refused_before_effect, :not_used}}
end

defmodule Loopex.CancellationObservationContractTest.ControlledCancelObserver do
  @moduledoc false

  @behaviour Loopex.Executor

  @impl Loopex.Executor
  def cancel({observer, token}, job_id) do
    send(observer, {:controlled_cancel_waiting, self(), token, job_id})

    receive do
      {:release_controlled_cancel, ^token} -> {:ok, :cleaned}
    end
  end

  @impl Loopex.Executor
  def execute(_reference, _job, _grant, _options, _progress),
    do: {:error, {:refused_before_effect, :not_used}}
end

defmodule Loopex.CancellationObservationContractTest.ExecutorFixture do
  @moduledoc false

  @behaviour Loopex.Executor

  def start(observer, mode) do
    Agent.start_link(fn -> %{observer: observer, mode: mode, jobs: [], workers: %{}} end)
  end

  def jobs(pid), do: Agent.get(pid, &Enum.reverse(&1.jobs))

  @impl Loopex.Executor
  def cancel(pid, job_id) do
    %{observer: observer, workers: workers} = Agent.get(pid, & &1)
    send(observer, {:executor_cancelled, job_id})

    case Map.fetch(workers, job_id) do
      {:ok, worker} -> send(worker, {:cancel_job, job_id})
      :error -> :ok
    end

    {:ok, :cleaned}
  end

  @impl Loopex.Executor
  def execute(pid, job, _grant, _options, progress) do
    _progress = progress || Loopex.Executor.discard_progress()

    worker = self()

    state =
      Agent.get_and_update(pid, fn state ->
        next = %{
          state
          | jobs: [job | state.jobs],
            workers: Map.put(state.workers, job.job_id, worker)
        }

        {state, next}
      end)

    send(state.observer, {:executor_job_started, job.job_id})

    with {:ok, grace} <- Map.fetch(job, :cleanup_grace_ms),
         true <- function_exported?(Loopex.Executor, :cancellation_bounds, 1),
         {:ok, bounds} <- apply(Loopex.Executor, :cancellation_bounds, [grace]) do
      outcome =
        case state.mode do
          :complete ->
            :completed

          :hold ->
            receive do
              {:cancel_job, job_id} when job_id == job.job_id -> :cancelled
            after
              10_000 -> :outcome_unknown
            end

          # Concept: the receipt is withheld until the case releases it, never for
          # a chosen number of milliseconds. Sleeping picked a duration hoping to
          # land inside or outside a reserve whose arming instant nothing orders
          # against the worker's own, which made the verdict a race. The case now
          # decides when the receipt exists.
          :hold_until_released ->
            receive do
              {:cancel_job, job_id} when job_id == job.job_id ->
                send(state.observer, {:receipt_held, job.job_id, self()})

                receive do
                  {:release_receipt, released} when released == job.job_id ->
                    send(state.observer, {:receipt_released, job.job_id})
                    :cancelled
                after
                  30_000 -> :outcome_unknown
                end
            after
              10_000 -> :outcome_unknown
            end
        end

      :ok =
        Agent.update(pid, fn current ->
          %{current | workers: Map.delete(current.workers, job.job_id)}
        end)

      {:ok, receipt(job, outcome, grace, bounds)}
    else
      _missing_contract ->
        {:error, {:refused_before_effect, :cleanup_grace_not_committed}}
    end
  end

  defp receipt(job, outcome, grace, bounds) do
    %{
      protocol_version: job.protocol_version,
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
      outcome: outcome,
      output: "fixture output",
      progress_count: 0,
      observed_at_ms: System.system_time(:millisecond),
      child_environment_names: [],
      provider_credential_present: false,
      artifacts: [],
      cleanup_grace_ms: grace,
      cleanup_confirmation: :confirmed,
      receipt_retention_bound_ms: bounds.receipt_retention_ms
    }
  end
end

defmodule Loopex.CancellationObservationContractTest do
  @moduledoc false

  use ExUnit.Case, async: false

  alias Loopex.Executor
  alias Loopex.M1RuntimeTestStore
  alias Loopex.Runtime.SessionState
  alias Loopex.CancellationObservationContractTest.CancelObserver
  alias Loopex.CancellationObservationContractTest.ControlledCancelObserver
  alias Loopex.CancellationObservationContractTest.DelayedCancelObserver
  alias Loopex.CancellationObservationContractTest.ExecutorFixture

  @max_uint64 18_446_744_073_709_551_615

  setup do
    on_exit(fn -> disable_cancel_trace() end)
    :ok
  end

  test "the committed cleanup period propagates through genesis status job receipt and terminal" do
    grace = 7_501
    fixture = runtime_fixture(grace, :complete)

    {session_id, attachment} = start_one_tool_run(fixture, "propagate cleanup")
    assert_receive {:executor_job_started, _job_id}, 5_000

    assert [job] = ExecutorFixture.jobs(fixture.executor)
    assert Map.fetch(job, :cleanup_grace_ms) == {:ok, grace}

    events = drain(attachment)

    assert {:ok, %{cleanup_grace_ms: ^grace}} = Loopex.session_status(fixture.runtime, session_id)

    assert :cleanup_grace_ms in Executor.job_fields()

    records =
      fixture.store_pid
      |> M1RuntimeTestStore.inspect_state()
      |> get_in([:sessions, session_id, :records])

    assert %{payload: genesis} = Enum.find(records, &(&1.payload.kind == "session_genesis_v2"))

    assert genesis == %{
             "options" => %{"tenant" => "contract"},
             "runtime_configuration" => %{"cleanup_grace_ms" => grace},
             kind: "session_genesis_v2"
           }

    receipt_record = Enum.find(records, &(&1.payload.kind == "executor_receipt_committed"))
    assert receipt_record.payload["receipt"]["cleanup_grace_ms"] == grace
    assert receipt_record.payload["receipt"]["cleanup_confirmation"] == "confirmed"

    finished = Enum.find(events, &(&1.kind == "run.finished"))
    assert finished["outcome"] == "completed"
    assert finished["cleanup_grace_ms"] == grace
  end

  test "the versioned genesis decoder refuses missing extra invalid and legacy cleanup truth" do
    grace = 9_001
    fixture = runtime_fixture(grace, :complete)
    {session_id, attachment} = start_one_tool_run(fixture, "decode cleanup genesis")
    assert_receive {:executor_job_started, _job_id}, 5_000
    _events = drain(attachment)

    session = M1RuntimeTestStore.inspect_state(fixture.store_pid).sessions[session_id]
    [genesis | tail] = session.records

    assert genesis.payload == %{
             "options" => %{"tenant" => "contract"},
             "runtime_configuration" => %{"cleanup_grace_ms" => grace},
             kind: "session_genesis_v2"
           }

    assert {:ok, %{cleanup_grace_ms: ^grace}} =
             SessionState.recover(session_id, session.records, session.events)

    invalid_payloads = [
      Map.put(genesis.payload, :kind, "session_genesis"),
      put_in(genesis.payload, ["runtime_configuration"], %{}),
      put_in(genesis.payload, ["runtime_configuration", "cleanup_grace_ms"], 0),
      put_in(genesis.payload, ["runtime_configuration", "unexpected"], true),
      Map.put(genesis.payload, "unexpected", true)
    ]

    for payload <- invalid_payloads do
      assert {:error, _reason} =
               SessionState.recover(
                 session_id,
                 [%{genesis | payload: payload} | tail],
                 session.events
               ),
             "recovery admitted malformed or legacy genesis #{inspect(payload)}"
    end
  end

  test "the cleanup period is a canonical job fact rather than an executor side option" do
    fixture = runtime_fixture(5_001, :complete)
    {_session_id, attachment} = start_one_tool_run(fixture, "digest cleanup job")
    assert_receive {:executor_job_started, _job_id}, 5_000
    _events = drain(attachment)

    assert [job] = ExecutorFixture.jobs(fixture.executor)
    assert job.cleanup_grace_ms == 5_001

    fields =
      job
      |> Map.from_struct()
      |> Map.drop([:canonical_request_digest, :effective_job_deadline])

    assert {:ok, changed} = Executor.job(%{fields | cleanup_grace_ms: 5_002})
    refute changed.canonical_request_digest == job.canonical_request_digest
  end

  # Concept: the shortest wait any admitted cleanup period can produce.
  #
  # Technical depth: the coordinator falls back to it when a committed period is
  # unreadable, and the comment there says it spends "the shortest admitted
  # reserve". That is a claim about this formula rather than about the
  # coordinator: it holds because the reserve is non-decreasing in the period, so
  # the floor of the admitted domain derives the floor of the reserve. A fallback
  # that restated the number instead of deriving it would keep the old value
  # silently if this formula ever moved, which is the drift this states.
  test "the shortest admitted cleanup period derives the shortest result reserve" do
    assert {:ok, %{execute_result_reserve_ms: shortest}} =
             invoke(Executor, :cancellation_bounds, [1])

    for grace <- [1, 2, 3, 4, 5, 5_000, 32_001, @max_uint64] do
      assert {:ok, %{execute_result_reserve_ms: reserve}} =
               invoke(Executor, :cancellation_bounds, [grace])

      assert reserve >= shortest
    end
  end

  test "cancellation bounds follow the exact formula and invalid input never calls the executor" do
    for grace <- [1, 4, 5, 5_000, 32_001, 58_001, @max_uint64] do
      quarter = max(1, div(grace + 3, 4))
      executor_observe = max(10_000, grace + 2_000)
      execute_reserve = quarter + 2_000
      terminal_reserve = max(10_000, execute_reserve)

      assert invoke(Executor, :cancellation_bounds, [grace]) ==
               {:ok,
                %{
                  executor_observe_ms: executor_observe,
                  receipt_retention_ms: quarter,
                  execute_result_reserve_ms: execute_reserve,
                  terminal_reserve_ms: terminal_reserve,
                  session_cache_ms: terminal_reserve,
                  cli_backstop_ms: executor_observe + execute_reserve + terminal_reserve
                }}
    end

    for invalid <- [0, -1, 1.0, @max_uint64 + 1] do
      assert invoke(Executor, :cancellation_bounds, [invalid]) ==
               {:error, :invalid_cleanup_grace}

      assert invoke(Executor, :cancel, [CancelObserver, self(), "job-invalid", invalid]) ==
               {:error, :invalid_cleanup_grace}

      refute_received {:cancel_callback_reached, "job-invalid"}
    end

    assert function_exported?(Executor, :cancel, 3),
           "the defensive legacy facade disappeared instead of staying available to direct callers"

    assert function_exported?(Executor, :cancel, 4),
           "configured cancellation has no distinct production entry"

    assert Executor.cancel(CancelObserver, self(), "legacy-direct") == {:ok, :cleaned}
    assert_receive {:cancel_callback_reached, "legacy-direct"}, 5_000

    assert invoke(Executor, :cancel, [CancelObserver, self(), "configured-uint64", @max_uint64]) ==
             {:ok, :cleaned},
           "a valid uint64 cleanup period was handed directly to a VM timer instead of sliced"

    assert_receive {:cancel_callback_reached, "configured-uint64"}, 5_000

    fixture = runtime_fixture(1, :hold)
    {_session_id, attachment} = start_one_tool_run(fixture, "configured cancellation")
    assert_receive {:executor_job_started, job_id}, 5_000

    trace_cancel_entries()

    assert {:accepted, "abort-configured"} =
             Loopex.command(attachment, %{type: :abort, command_id: "abort-configured"})

    assert_receive {:trace, _caller, :call, {Executor, :cancel, [_, _, _, 1]}}, 5_000
    assert_receive {:executor_cancelled, ^job_id}, 5_000

    refute_receive {:trace, _caller, :call, {Executor, :cancel, [_, _, _]}}, 100

    assert Enum.find(drain(attachment), &(&1.kind == "run.finished"))["outcome"] == "cancelled"
  end

  @tag timeout: 70_000
  test "configured cancellation observes a delayed callback beyond the legacy sixty second bound" do
    # This is deliberately a real duration rather than a source or call-shape
    # assertion. A configured facade that delegates to cancel/3 stays green for
    # every short callback and is false only after the old defensive bound.
    delay_ms = 60_500
    grace_ms = 65_000
    started_at = System.monotonic_time(:millisecond)

    assert invoke(Executor, :cancel, [
             DelayedCancelObserver,
             {self(), delay_ms},
             "long-cleanup",
             grace_ms
           ]) ==
             {:ok, :cleaned}

    elapsed = System.monotonic_time(:millisecond) - started_at
    assert elapsed >= delay_ms
    assert elapsed < grace_ms + 4_000
    assert_receive {:delayed_cancel_started, _worker, "long-cleanup"}, 5_000
    assert_receive {:delayed_cancel_finished, _worker, "long-cleanup"}, 5_000
  end

  test "configured cancellation enters a uint64 observation wait without handing it to one VM timer" do
    token = make_ref()
    parent = self()

    assert invoke(Executor, :cancel, [
             ControlledCancelObserver,
             {parent, token},
             "controlled-invalid",
             0
           ]) == {:error, :invalid_cleanup_grace}

    cancellation =
      Task.async(fn ->
        invoke(Executor, :cancel, [
          ControlledCancelObserver,
          {parent, token},
          "controlled-uint64",
          @max_uint64
        ])
      end)

    assert_receive {:controlled_cancel_waiting, worker, ^token, "controlled-uint64"}, 5_000
    assert Task.yield(cancellation, 0) == nil
    send(worker, {:release_controlled_cancel, token})
    assert Task.await(cancellation, 5_000) == {:ok, :cleaned}
  end

  test "the execute-result reserve admits one late receipt but expiry stays outcome unknown" do
    # Concept: the admitted half is causal in ordering - the receipt is released
    # while the worker provably still holds it - and is bounded only by its
    # reserve, which this half sizes at sixty-two seconds so that no scheduler
    # pause this suite could survive elsewhere can expire it first. The reserve is
    # a coordinator-side timer the case can neither observe nor drive, so a fully
    # causal admitted half needs a seam production does not yet expose. The
    # expired half is fully causal: it never releases, the reserve must expire on
    # its own evidence, and the late receipt is then released, traced into the
    # coordinator, barriered, and proved to have changed nothing.
    admitted = runtime_fixture(240_000, :hold_until_released)
    {_session_id, admitted_attachment} = start_one_tool_run(admitted, "reserved result")
    assert_receive {:executor_job_started, _admitted_job}, 5_000

    assert {:accepted, "abort-reserved"} =
             Loopex.command(admitted_attachment, %{
               type: :abort,
               command_id: "abort-reserved"
             })

    assert_receive {:receipt_held, admitted_job, admitted_worker}, 5_000
    send(admitted_worker, {:release_receipt, admitted_job})
    assert_receive {:receipt_released, ^admitted_job}, 5_000

    admitted_finished =
      admitted_attachment
      |> drain()
      |> Enum.find(&(&1.kind == "run.finished"))

    assert admitted_finished["outcome"] == "cancelled"

    expired = runtime_fixture(1, :hold_until_released)
    {expired_session, expired_attachment} = start_one_tool_run(expired, "expired result reserve")
    assert_receive {:executor_job_started, _expired_job}, 5_000

    assert {:accepted, "abort-expired-reserve"} =
             Loopex.command(expired_attachment, %{
               type: :abort,
               command_id: "abort-expired-reserve"
             })

    assert_receive {:receipt_held, expired_job, expired_worker}, 5_000

    expired_finished =
      expired_attachment
      |> drain()
      |> Enum.find(&(&1.kind == "run.finished"))

    assert expired_finished["outcome"] == "outcome_unknown",
           "the reserve expired with the receipt still withheld, so the run cannot claim cancelled"

    assert is_binary(expired_finished["reconciliation_ref"]) and
             expired_finished["reconciliation_ref"] != "",
           "an unknown outcome must carry the reference an operator reconciles with"

    # The withheld receipt is released only now, strictly after the terminal. It
    # must change nothing. That is proved causally: the worker's return is traced
    # into the coordinator's mailbox, a synchronous state read then barriers
    # every message ahead of it, and the durable store and public history are
    # compared to their pre-release snapshots. A coordinator that instead
    # terminated the withheld worker at expiry never produces the late receipt,
    # which satisfies the same rule and is accepted.
    coordinator = coordinator_of(expired.runtime)
    before = M1RuntimeTestStore.inspect_state(expired.store_pid)
    assert Map.has_key?(before.sessions, expired_session)
    _ = :erlang.trace(coordinator, true, [:receive])
    send(expired_worker, {:release_receipt, expired_job})

    receive do
      {:receipt_released, ^expired_job} ->
        assert_receive {:trace, ^coordinator, :receive, {_reply, {:ok, %{job_id: ^expired_job}}}},
                       5_000

        _barrier = :sys.get_state(coordinator)

        assert M1RuntimeTestStore.inspect_state(expired.store_pid) == before,
               "a receipt admitted after expiry changed durable state"

        assert later_events(expired_attachment) == [],
               "a receipt admitted after expiry published further public history"
    after
      5_000 ->
        refute Process.alive?(expired_worker),
               "the withheld worker was neither released nor terminated at expiry"
    end

    _ = :erlang.trace(coordinator, false, [:receive])
  end

  test "genesis and effect intent are measured before owner or executor authority" do
    {store_pid, store} = M1RuntimeTestStore.start_store(label: "genesis-preflight")
    on_exit(fn -> stop_process(store_pid) end)

    {:ok, runtime} =
      Loopex.start_link(
        context_token_budget: 8_192,
        runtime_id: "genesis-preflight",
        store: store
      )

    on_exit(fn -> stop_runtime(runtime) end)

    before = M1RuntimeTestStore.inspect_state(store_pid)

    assert Loopex.create_session(
             runtime,
             %{"oversized" => String.duplicate("g", 65_537)},
             command_id: "oversized-genesis"
           ) == {:error, :session_configuration_too_large}

    assert M1RuntimeTestStore.inspect_state(store_pid) == before,
           "an oversized genesis reached Store or acquired session authority before refusal"

    definition =
      Loopex.AgentLoopFixture.tool_definition(%{
        "tool_id" => "example.oversized",
        "name" => "oversized",
        "parameter_schema" => %{
          "type" => "object",
          "properties" => %{"payload" => %{"type" => "string"}},
          "required" => ["payload"]
        }
      })

    fixture =
      runtime_fixture(5_000, :complete,
        tools: [definition],
        script: [
          %{
            text: "",
            calls: [
              %{
                id: "oversized-call",
                name: "oversized",
                arguments: %{"payload" => String.duplicate("e", 62_000)}
              }
            ]
          },
          %{text: "settled"}
        ]
      )

    {_session_id, attachment} = start_one_tool_run(fixture, "preflight effect intent")
    events = drain(attachment)

    assert ExecutorFixture.jobs(fixture.executor) == [],
           "an oversized effect-intent record crossed the executor boundary"

    assert Enum.any?(events, fn event ->
             event.kind == "tool.finished" and
               event["outcome"] == "failed" and
               event["reason"] =~ "effect_intent_record_too_large"
           end),
           "the oversized effect intent did not commit its declared pre-effect refusal"
  end

  test "the complete genesis admits exactly 65536 canonical bytes and refuses one byte more" do
    grace = 5_000
    at_limit_options = genesis_options_for_size(grace, 65_536)
    over_limit_options = genesis_options_for_size(grace, 65_537)

    assert genesis_size(at_limit_options, grace) == 65_536
    assert genesis_size(over_limit_options, grace) == 65_537

    {store_pid, store} = M1RuntimeTestStore.start_store(label: "genesis-exact-boundary")
    on_exit(fn -> stop_process(store_pid) end)

    {:ok, runtime} =
      Loopex.start_link(
        context_token_budget: 8_192,
        runtime_id: "genesis-exact-boundary",
        store: store,
        cleanup_grace_ms: grace
      )

    on_exit(fn -> stop_runtime(runtime) end)

    assert {:ok, _session_id} =
             Loopex.create_session(runtime, at_limit_options, command_id: "genesis-at-limit")

    before_oversized = M1RuntimeTestStore.inspect_state(store_pid)

    assert Loopex.create_session(
             runtime,
             over_limit_options,
             command_id: "genesis-over-limit"
           ) == {:error, :session_configuration_too_large}

    assert M1RuntimeTestStore.inspect_state(store_pid) == before_oversized
  end

  defp runtime_fixture(grace, mode, options \\ []) do
    script =
      Keyword.get(options, :script, [
        %{
          text: "",
          calls: [%{id: "cleanup-call", name: "write", arguments: %{"path" => "note.txt"}}]
        },
        %{text: "done"}
      ])

    tools = Keyword.get(options, :tools, [Loopex.AgentLoopFixture.tool_definition()])
    model = Loopex.AgentLoopTestModel.start(script)
    {:ok, executor} = ExecutorFixture.start(self(), mode)
    {store_pid, store} = M1RuntimeTestStore.start_store(label: "cancellation-observation")

    {:ok, runtime} =
      Loopex.start_link(
        context_token_budget: 8_192,
        runtime_id: "cancellation-observation-#{System.unique_integer([:positive])}",
        store: store,
        model: %{
          module: Loopex.AgentLoopTestModel,
          model: "scripted:v1",
          options: [script: model, max_tokens: 256]
        },
        executor: %{
          module: ExecutorFixture,
          reference: executor,
          identity: "cancellation-contract-executor",
          epoch: 1,
          fencing_token: 1,
          workspace_ref: "workspace-ref",
          workspace_lease: "workspace-lease"
        },
        tools: tools,
        active_tools: Enum.map(tools, &Map.fetch!(&1, "tool_id")),
        policy: Loopex.AgentLoopTestPolicy,
        grant_decision: {:host_policy, :allow},
        cleanup_grace_ms: grace
      )

    on_exit(fn ->
      stop_runtime(runtime)
      stop_process(store_pid)
      stop_process(model)
      stop_process(executor)
    end)

    %{runtime: runtime, store_pid: store_pid, executor: executor}
  end

  defp genesis_options_for_size(grace, wanted_size) do
    padding_size = find_genesis_padding(grace, wanted_size, 0, wanted_size)

    assert is_integer(padding_size),
           "no canonical genesis padding produced exactly #{wanted_size} bytes"

    %{"padding" => :binary.copy("g", padding_size)}
  end

  defp find_genesis_padding(_grace, _wanted_size, low, high) when low > high, do: nil

  defp find_genesis_padding(grace, wanted_size, low, high) do
    candidate = div(low + high, 2)
    size = genesis_size(%{"padding" => :binary.copy("g", candidate)}, grace)

    cond do
      size == wanted_size -> candidate
      size < wanted_size -> find_genesis_padding(grace, wanted_size, candidate + 1, high)
      true -> find_genesis_padding(grace, wanted_size, low, candidate - 1)
    end
  end

  defp genesis_size(options, grace) do
    %{
      "options" => options,
      "runtime_configuration" => %{"cleanup_grace_ms" => grace},
      kind: "session_genesis_v2"
    }
    |> :erlang.term_to_binary([:deterministic])
    |> byte_size()
  end

  defp start_one_tool_run(fixture, content) do
    {:ok, session_id} =
      Loopex.create_session(
        fixture.runtime,
        %{"tenant" => "contract"},
        command_id: "create-#{System.unique_integer([:positive])}"
      )

    {:ok, attachment} = Loopex.attach(fixture.runtime, session_id, after_event_sequence: 0)

    command_id = "prompt-#{System.unique_integer([:positive])}"

    assert {:accepted, ^command_id} =
             Loopex.command(attachment, %{type: :prompt, command_id: command_id, content: content})

    {session_id, attachment}
  end

  # Concept: read whatever the attachment still yields after its terminal without
  # waiting for a new one. This backs a refutation, so a bounded read can only
  # miss a violation, never invent one. It follows the double's own
  # `receipt_released` message, which the double sends before it builds and
  # returns the receipt - so the release is anchored, though the receipt's
  # delivery to the coordinator is not.
  defp coordinator_of(runtime) do
    {:ok, %{sessions: sessions}} = Loopex.Runtime.children(runtime)

    sessions
    |> DynamicSupervisor.which_children()
    |> Enum.find_value(fn
      {_id, pid, :worker, _modules} when is_pid(pid) -> pid
      _other -> nil
    end)
  end

  defp later_events(attachment, acc \\ [], attempts \\ 40)
  defp later_events(_attachment, acc, 0), do: Enum.reverse(acc)

  defp later_events(attachment, acc, attempts) do
    case Loopex.next_event(attachment) do
      {:ok, event} ->
        later_events(attachment, [event | acc], attempts)

      _empty ->
        Process.sleep(5)
        later_events(attachment, acc, attempts - 1)
    end
  end

  defp drain(attachment, acc \\ [], attempts \\ 1_000)

  defp drain(_attachment, _acc, 0),
    do: raise("the cancellation contract fixture did not publish run.finished")

  defp drain(attachment, acc, attempts) do
    case Loopex.next_event(attachment) do
      {:ok, %{kind: "run.finished"} = event} ->
        Enum.reverse([event | acc])

      {:ok, event} ->
        drain(attachment, [event | acc], attempts)

      _empty ->
        Process.sleep(5)
        drain(attachment, acc, attempts - 1)
    end
  end

  defp trace_cancel_entries do
    assert :erlang.trace_pattern({Executor, :cancel, 3}, true, []) == 1
    assert :erlang.trace_pattern({Executor, :cancel, 4}, true, []) == 1

    Enum.each(Process.list(), fn pid ->
      _ = :erlang.trace(pid, true, [:call, {:tracer, self()}])
    end)

    _ = :erlang.trace(:new, true, [:call, {:tracer, self()}])
  end

  defp disable_cancel_trace do
    _ = :erlang.trace(:new, false, [:call])

    Enum.each(Process.list(), fn pid ->
      _ = :erlang.trace(pid, false, [:call])
    end)

    _ = :erlang.trace_pattern({Executor, :cancel, 3}, false, [])
    _ = :erlang.trace_pattern({Executor, :cancel, 4}, false, [])
    :ok
  end

  defp stop_runtime(runtime) do
    try do
      Loopex.stop(runtime)
    catch
      :exit, _reason -> :ok
    end
  end

  defp stop_process(pid) when is_pid(pid) do
    if Process.alive?(pid) do
      try do
        GenServer.stop(pid, :normal, 1_000)
      catch
        :exit, _reason -> :ok
      end
    end
  end

  defp invoke(module, function, arguments) do
    if Code.ensure_loaded?(module) and function_exported?(module, function, length(arguments)) do
      apply(module, function, arguments)
    else
      {:error, {:contract_entry_missing, module, function, length(arguments)}}
    end
  end
end
