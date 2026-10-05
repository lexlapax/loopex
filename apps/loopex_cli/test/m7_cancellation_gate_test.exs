Code.require_file("../../loopex/test/support/m1_runtime_helper.exs", __DIR__)
Code.require_file("../../loopex/test/support/agent_loop_helper.exs", __DIR__)
Code.require_file("../../loopex_llm_reqllm/test/support/provider_isolation_fixture.exs", __DIR__)

defmodule LoopexCli.M7CancellationGateProbe do
  @moduledoc false
  @behaviour Loopex.Model

  @impl Loopex.Model
  def complete(request, options, progress) do
    exact =
      request === options[:expected_request] and progress === options[:expected_progress] and
        options[:verify_options].(options)

    scoped = Loopex.Runtime.ProviderLifetime.starter() === options[:expected_starter]
    send(options[:observer], {:gate_probe, self(), exact, scoped})
    options[:result]
  end
end

defmodule LoopexCli.M7CancellationGateTest do
  use ExUnit.Case, async: false

  alias LoopexCli.Model.M7CancellationGate, as: Gate
  alias Loopex.AgentLoopFixture, as: Fixture
  alias Loopex.AgentLoopTestModel
  alias Loopex.AgentLoopTestExecutor
  alias Loopex.M1RuntimeTestStore, as: TestStore
  alias Loopex.Runtime.{ProviderLifetime, SessionState}
  alias Loopex.LLM.ReqLLM, as: Adapter
  alias Loopex.LLM.ReqLLM.ProviderIsolationFixture, as: Provider

  test "same callback forwards exact arguments, progress and result under its original lifetime scope" do
    gate = gate()
    request = request("first")
    progress = fn _ -> :ok end
    result = {:error, {:delegate_result, make_ref()}}
    {:ok, workers} = Task.Supervisor.start_link()

    starter =
      ProviderLifetime.Starter.new(fn child -> Task.Supervisor.start_child(workers, child) end)

    marker = make_ref()

    options =
      [
        observer: self(),
        expected_request: request,
        expected_progress: progress,
        expected_starter: {:managed, starter},
        result: result,
        private_marker: marker
      ]
      |> options_proof()

    owner = self()

    resource =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    stop = make_ref()

    on_exit(fn ->
      join_fixture(resource)
      join_fixture(workers)
    end)

    assert result ===
             ProviderLifetime.scoped(fn ^resource, ^stop -> :registered end, starter, fn ->
               assert :registered == ProviderLifetime.register(resource, stop)

               Gate.complete(
                 request,
                 Gate.options(gate, LoopexCli.M7CancellationGateProbe, options),
                 progress
               )
             end)

    assert_receive {:gate_probe, ^owner, true, true}
    assert_receive {:loopex_m7_gate, :permitted, ^gate, ^owner, digest, 1}
    assert digest == request.staged_request_digest
    assert Gate.status(gate) == %{permitted: 1, mode: :await_second}
    assert :ok = stop_gate(gate)
    GenServer.stop(workers)
  end

  test "retries of one digest pass, second distinct digest holds and only the exact host release spends it" do
    gate = gate()
    first = request("first")
    progress = fn _ -> :ok end
    options = probe_options(first, progress)

    assert :delegate_result ==
             Gate.complete(
               first,
               Gate.options(gate, LoopexCli.M7CancellationGateProbe, options),
               progress
             )

    assert :delegate_result ==
             Gate.complete(
               first,
               Gate.options(gate, LoopexCli.M7CancellationGateProbe, options),
               progress
             )

    assert Gate.status(gate).permitted == 2
    second = request("second")
    callback = async_call(gate, second)
    monitor = Process.monitor(callback)
    assert_receive {:loopex_m7_gate, :held, ^gate, ^callback, digest, token}, 5_000
    assert digest == second.staged_request_digest

    assert Gate.release(gate, callback, first.staged_request_digest, token) ==
             {:error, :invalid_gate_release}

    assert Gate.release(gate, callback, digest, make_ref()) == {:error, :invalid_gate_release}
    foreign = Task.async(fn -> Gate.release(gate, callback, digest, token) end)
    assert Task.await(foreign) == {:error, :invalid_gate_release}
    assert Gate.status(gate) == %{permitted: 2, mode: :holding}
    assert :ok == Gate.release(gate, callback, digest, token)
    assert_receive {:gate_probe, ^callback, true, true}, 5_000
    assert_receive {:gate_call_result, ^callback, :delegate_result}, 5_000
    assert_receive {:DOWN, ^monitor, :process, ^callback, :normal}, 5_000
    assert Gate.release(gate, callback, digest, token) == {:error, :invalid_gate_release}
    assert Gate.status(gate) == %{permitted: 3, mode: :spent}
    assert :ok = stop_gate(gate)
  end

  test "an expired held request cannot dispatch through a late release" do
    gate = gate()
    prime(gate)
    second = request("expired", System.system_time(:millisecond) + 1_000)
    callback = async_call(gate, second)
    monitor = Process.monitor(callback)
    assert_receive {:loopex_m7_gate, :held, ^gate, ^callback, digest, token}, 5_000
    assert_receive {:gate_call_result, ^callback, {:error, :m7_cancellation_gate_deadline}}, 5_000
    assert_receive {:DOWN, ^monitor, :process, ^callback, :normal}, 5_000
    refute_received {:gate_probe, ^callback, _, _}
    assert Gate.release(gate, callback, digest, token) == {:error, :invalid_gate_release}
    assert Gate.status(gate).permitted == 1
    assert :ok = stop_gate(gate)
  end

  test "release checks the captured deadline even while its expiry message is delayed" do
    gate = gate()
    prime(gate)
    second = request("delayed expiry", System.system_time(:millisecond) + 1_000)
    callback = async_call(gate, second)
    monitor = Process.monitor(callback)
    assert_receive {:loopex_m7_gate, :held, ^gate, ^callback, digest, token}, 5_000
    :ok = :sys.suspend(gate)

    resumer =
      Task.async(fn ->
        wait_until(second.deadline)
        :sys.resume(gate)
      end)

    # Queue the exact host's release before expiry; its fresh deadline check
    # refuses it even when the timer message is behind that queued release.
    assert Gate.release(gate, callback, digest, token) == {:error, :m7_cancellation_gate_closed}
    assert :ok = Task.await(resumer)
    assert_receive {:gate_call_result, ^callback, {:error, :m7_cancellation_gate_deadline}}, 5_000
    assert_receive {:DOWN, ^monitor, :process, ^callback, :normal}, 5_000
    refute_received {:gate_probe, ^callback, _, _}
    assert :ok = stop_gate(gate)
  end

  for loss <- [:host, :control] do
    test "#{loss} loss closes the held callback before any downstream entry" do
      observer = self()
      host = spawn(fn -> host_loop(observer) end)

      control =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      on_exit(fn ->
        join_fixture(host)
        join_fixture(control)
      end)

      send(host, {:start, control})
      assert_receive {:started_gate, gate}, 5_000
      first = request("first")
      progress = fn _ -> :ok end

      assert :delegate_result ==
               Gate.complete(
                 first,
                 Gate.options(
                   gate,
                   LoopexCli.M7CancellationGateProbe,
                   probe_options(first, progress)
                 ),
                 progress
               )

      callback = async_call(gate, request("second"))
      callback_monitor = Process.monitor(callback)
      gate_monitor = Process.monitor(gate)
      assert_receive {:loopex_m7_gate, :held, ^gate, ^callback, _digest, _token}, 5_000
      Process.exit(if(unquote(loss) == :host, do: host, else: control), :kill)
      assert_receive {:DOWN, ^gate_monitor, :process, ^gate, _reason}, 5_000
      assert_receive {:gate_call_result, ^callback, {:error, :m7_cancellation_gate_closed}}, 5_000
      assert_receive {:DOWN, ^callback_monitor, :process, ^callback, :normal}, 5_000
      refute_received {:gate_probe, ^callback, _, _}
      assert :ok = stop_gate(gate)
      for pid <- [host, control], Process.alive?(pid), do: Process.exit(pid, :kill)
    end
  end

  test "a suspended gate cannot extend callback admission beyond the captured request cutoff" do
    gate = gate()
    :ok = :sys.suspend(gate)
    callback = async_call(gate, request("suspended", System.system_time(:millisecond) + 1_000))
    monitor = Process.monitor(callback)
    assert_receive {:gate_call_result, ^callback, {:error, :m7_cancellation_gate_deadline}}, 5_000
    assert_receive {:DOWN, ^monitor, :process, ^callback, :normal}, 5_000
    refute_received {:gate_probe, ^callback, _, _}
    :ok = :sys.resume(gate)
    assert Gate.status(gate) == %{permitted: 0, mode: :await_second}
    assert :ok = stop_gate(gate)
  end

  test "a suspended owner reports unconfirmed stop at its captured cleanup cutoff" do
    gate = gate()
    assert :erlang.suspend_process(gate)
    cutoff = System.monotonic_time(:millisecond) + 1_000
    assert Gate.stop(gate, cutoff) == {:error, :m7_cancellation_gate_stop_unconfirmed}
    assert Process.alive?(gate)
    assert :erlang.resume_process(gate)
    assert :ok = stop_gate(gate)
    refute Process.alive?(gate)
  end

  test "real Core commits first-turn tool results then aborts its held permitted attempt before confirmed cleanup" do
    gate = gate(false)

    script =
      AgentLoopTestModel.start([
        %{
          text: "first tool",
          calls: [%{id: "call-first", name: "write", arguments: %{"path" => "a"}}]
        },
        %{text: "later prompt one", calls: []},
        %{text: "later prompt two", calls: []}
      ])

    executor = AgentLoopTestExecutor.start()
    {store_pid, store} = TestStore.start_store(label: "m7-gate")
    definition = Fixture.tool_definition()

    {:ok, runtime} =
      Loopex.start_link(
        runtime_id: "m7-gate",
        context_token_budget: 8_192,
        store: store,
        session_creation_defaults: Fixture.creation_defaults([definition]),
        model: %{
          module: Gate,
          model: "scripted:v1",
          options: Gate.options(gate, AgentLoopTestModel, script: script)
        },
        executor: %{
          module: AgentLoopTestExecutor,
          reference: executor,
          identity: "agent-loop-executor",
          epoch: 1,
          fencing_token: 1,
          workspace_ref: "workspace-ref",
          workspace_lease: "workspace-lease"
        },
        tools: [definition],
        policy: Loopex.AgentLoopTestPolicy,
        policy_identity: %{"id" => "m7-gate-policy", "revision" => "1"},
        bounds: %{max_turns: 8, token_budget: 256, deadline_ms: 30_000}
      )

    {:ok, %{control: control}} = Loopex.Runtime.children(runtime)
    assert :ok = Gate.bind_control(gate, control)

    on_exit(fn ->
      if Loopex.Runtime.alive?(runtime), do: Loopex.stop(runtime)
      stop_gate(gate)
      for pid <- [store_pid, script, executor], Process.alive?(pid), do: GenServer.stop(pid)
    end)

    {:ok, session} = Loopex.create_session(runtime, %{}, command_id: "create")
    {:ok, attachment} = Loopex.attach(runtime, session, after_event_sequence: 0)

    assert {:accepted, "first"} =
             Loopex.command(attachment, %{
               type: :prompt,
               command_id: "first",
               content: "tool then cancel"
             })

    assert_receive {:loopex_m7_gate, :held, ^gate, callback, digest, token}, 5_000
    callback_monitor = Process.monitor(callback)
    fixture = %{store: store_pid}
    committed = Fixture.events(fixture, session)

    assert Enum.any?(
             committed,
             &(&1.kind == "tool.finished" and &1["tool_call_id"] == "call-first")
           )

    [first_staged, second_staged] =
      for %{payload: %{kind: kind} = row} <- Fixture.records(fixture, session),
          kind in ["model_request_committed_v2", "model_request_committed_resources_v2"],
          do: row

    assert first_staged["staged_request_digest"] != digest
    assert second_staged["staged_request_digest"] == digest
    assert second_staged["request"]["staged_request_digest"] == digest

    opened =
      for %{payload: %{kind: "model_attempt_opened_v1"} = row} <-
            Fixture.records(fixture, session),
          do: row

    assert List.last(opened)["operation_id"] == second_staged["operation_id"]
    assert List.last(opened)["staged_request_digest"] == digest

    assert length(AgentLoopTestExecutor.jobs(executor)) == 1
    assert length(AgentLoopTestModel.dispatched(script)) == 1
    assert {:accepted, "abort"} = Loopex.command(attachment, %{type: :abort, command_id: "abort"})
    assert_receive {:DOWN, ^callback_monitor, :process, ^callback, :killed}, 5_000
    refute Process.alive?(callback)
    events = await_terminal(attachment)
    terminal = Enum.find(events, &(&1.kind == "run.finished"))
    assert terminal["outcome"] == "cancelled"
    # A cancelled terminal requires confirmed owned cleanup; unconfirmed cleanup
    # ends outcome_unknown. The exact callback DOWN was joined before reading it.
    records = Fixture.records(fixture, session)
    settlements = for %{payload: %{kind: "model_attempt_settled_v3"} = row} <- records, do: row
    assert length(settlements) == 2
    held = List.last(settlements)
    assert held["staged_request_digest"] == digest
    assert held["transport"] == "dispatched_or_unknown"
    assert held["termination"] == "abort"
    assert held["accounting"] == %{"source" => "estimated", "basis" => "remaining_allowance"}

    assert {:ok, replay} =
             SessionState.recover(session, records, Fixture.events(fixture, session))

    assert elem(SessionState.accounting(replay, held["run_id"]), 1) == %{
             tokens: 256,
             source: :estimated
           }

    assert Gate.release(gate, callback, digest, token) == {:error, :invalid_gate_release}

    for id <- ["later-one", "later-two"] do
      assert {:accepted, ^id} =
               Loopex.command(attachment, %{type: :prompt, command_id: id, content: id})

      assert Enum.find(await_terminal(attachment), &(&1.kind == "run.finished"))["outcome"] ==
               "completed"
    end

    assert Enum.map(AgentLoopTestModel.dispatched(script), & &1.model) ==
             List.duplicate("scripted:v1", 3)

    assert Gate.status(gate) == %{permitted: 3, mode: :spent}
    assert :ok = Loopex.stop(runtime)
    assert :ok = stop_gate(gate)
  end

  test "the actual protected adapter HTTP call passes through unchanged" do
    provider = Provider.new(:reply)
    gate = gate()
    request = Provider.request()

    assert {:ok, reply} =
             Gate.complete(request, Gate.options(gate, Adapter, provider.options), fn _ -> :ok end)

    assert reply.text == "loopex"
    assert reply.canonical_request_bytes == request.canonical_request_bytes
    assert reply.staged_request_digest == request.staged_request_digest
    assert Provider.methods(provider) == ["POST"]
    assert [{_request, true}] = Provider.events(provider)
    Provider.assert_gone(provider)
    assert :ok = stop_gate(gate)
  end

  defp stop_gate(gate),
    do:
      Gate.stop(
        gate,
        System.monotonic_time(:millisecond) + Loopex.Executor.default_cleanup_grace_ms()
      )

  defp gate(bind? \\ true) do
    {:ok, gate} = Gate.start_link(self())
    if bind?, do: assert(:ok == Gate.bind_control(gate, self()))
    on_exit(fn -> stop_gate(gate) end)
    gate
  end

  defp request(content, deadline \\ System.system_time(:millisecond) + 30_000) do
    {:ok, request} =
      Loopex.Model.request("scripted:v1", [%{"role" => "user", "content" => content}],
        sampling: %{"max_tokens" => 64},
        deadline: deadline
      )

    request
  end

  defp probe_options(request, progress),
    do:
      [
        observer: self(),
        expected_request: request,
        expected_progress: progress,
        expected_starter: :unmanaged,
        result: :delegate_result
      ]
      |> options_proof()

  defp options_proof(options),
    do:
      [verify_options: fn actual -> Keyword.delete(actual, :verify_options) === options end] ++
        options

  defp join_fixture(pid) do
    monitor = Process.monitor(pid)
    cutoff = System.monotonic_time(:millisecond) + Loopex.Executor.default_cleanup_grace_ms()
    if Process.alive?(pid), do: Process.exit(pid, :kill)

    receive do
      {:DOWN, ^monitor, :process, ^pid, _reason} -> :ok
    after
      max(cutoff - System.monotonic_time(:millisecond), 0) ->
        flunk("fixture actor did not stop within its captured cleanup cutoff")
    end
  end

  defp prime(gate) do
    first = request("first")
    progress = fn _ -> :ok end

    assert :delegate_result ==
             Gate.complete(
               first,
               Gate.options(
                 gate,
                 LoopexCli.M7CancellationGateProbe,
                 probe_options(first, progress)
               ),
               progress
             )
  end

  defp async_call(gate, request) do
    observer = self()

    callback =
      spawn(fn ->
        progress = fn _ -> :ok end

        options =
          [
            observer: observer,
            expected_request: request,
            expected_progress: progress,
            expected_starter: :unmanaged,
            result: :delegate_result
          ]
          |> options_proof()

        result =
          Gate.complete(
            request,
            Gate.options(gate, LoopexCli.M7CancellationGateProbe, options),
            progress
          )

        send(observer, {:gate_call_result, self(), result})
      end)

    on_exit(fn -> join_fixture(callback) end)
    callback
  end

  defp host_loop(observer) do
    receive do
      {:start, control} ->
        {:ok, gate} = Gate.start_link(self())
        :ok = Gate.bind_control(gate, control)
        send(observer, {:started_gate, gate})
        host_loop(observer)

      message ->
        send(observer, message)
        host_loop(observer)
    end
  end

  defp wait_until(cutoff) do
    if System.system_time(:millisecond) < cutoff do
      Process.sleep(1)
      wait_until(cutoff)
    end
  end

  defp await_terminal(attachment),
    do: await_terminal(attachment, [], System.monotonic_time(:millisecond) + 5_000)

  defp await_terminal(attachment, events, cutoff) do
    case Loopex.next_event(attachment) do
      {:ok, %{kind: "run.finished"} = event} ->
        Enum.reverse([event | events])

      {:ok, event} ->
        await_terminal(attachment, [event | events], cutoff)

      {:error, :empty} ->
        assert System.monotonic_time(:millisecond) < cutoff
        Process.sleep(5)
        await_terminal(attachment, events, cutoff)

      other ->
        flunk("gate attachment unavailable: #{inspect(other)}")
    end
  end
end
