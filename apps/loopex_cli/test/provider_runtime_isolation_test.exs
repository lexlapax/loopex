Code.require_file("../../loopex/test/support/m1_runtime_helper.exs", __DIR__)
Code.require_file("../../loopex/test/support/agent_loop_helper.exs", __DIR__)
Code.require_file("../../loopex_llm_reqllm/test/support/provider_isolation_fixture.exs", __DIR__)

defmodule LoopexCli.ProviderRuntimeIsolationTest do
  @moduledoc false
  use ExUnit.Case, async: false
  require Logger

  alias Loopex.AgentLoopFixture
  alias Loopex.AgentLoopTestExecutor
  alias Loopex.LLM.ReqLLM, as: Adapter
  alias Loopex.LLM.ReqLLM.ProviderIsolationFixture, as: Provider
  alias Loopex.M1RuntimeTestStore
  alias Loopex.Runtime

  @handler :loopex_provider_runtime_isolation_witness

  setup do
    variable = Adapter.credential_variable()
    previous = System.get_env(variable)
    System.put_env(variable, "synthetic-runtime-isolation-key")

    on_exit(fn ->
      if previous, do: System.put_env(variable, previous), else: System.delete_env(variable)
    end)

    {:ok, _started} = Application.ensure_all_started(:req_llm)
    :ok
  end

  # Concept: one runtime's failed provider invocation cannot poison another
  # runtime or acquire the host's diagnostic machinery.
  #
  # Technical depth: both actual protected workers reach held Finch request
  # adapters before HTTP dispatch. Release one to its real HTTP failure while
  # the other invocation remains live, then release that one to HTTP success.
  # Failure settles first. App stop/start and each
  # outcome preserve exact host Logger configuration and live group leaders;
  # ordinary host log events must still traverse the unchanged Logger pipeline.
  test "adapter lifecycle and two real runtimes preserve host diagnostics across one provider failure" do
    was_started = adapter_started?()

    on_exit(fn ->
      case {was_started, adapter_started?()} do
        {true, false} -> :ok = Application.start(:loopex_llm_reqllm)
        {false, true} -> :ok = Application.stop(:loopex_llm_reqllm)
        _unchanged -> :ok
      end
    end)

    assert :ok =
             :logger.add_handler(@handler, __MODULE__, %{
               level: :all,
               config: %{observer: self()}
             })

    host = spawn_link(fn -> host_log_loop() end)

    on_exit(fn ->
      :logger.remove_handler(@handler)
      if Process.alive?(host), do: Process.exit(host, :kill)
    end)

    host_processes = [
      self(),
      host,
      Process.whereis(ReqLLM.Supervisor),
      Process.whereis(ReqLLM.TaskSupervisor)
    ]

    baseline = host_snapshot(host_processes)
    assert_host_unchanged(baseline, host_processes, host, :before_lifecycle)

    if was_started do
      assert :ok = Application.stop(:loopex_llm_reqllm)
      assert_host_unchanged(baseline, host_processes, host, :initial_stop)
    end

    refute adapter_started?()
    assert :ok = Application.start(:loopex_llm_reqllm)
    assert adapter_started?()
    assert_host_unchanged(baseline, host_processes, host, :started)

    failed_provider = Provider.new(:hold_before_error)
    healthy_provider = Provider.new(:hold_before_return)
    failed = start_runtime(failed_provider, "failed-runtime")
    healthy = start_runtime(healthy_provider, "healthy-runtime")
    refute failed.runtime == healthy.runtime
    refute failed.control == healthy.control

    runtime_processes = [failed.control, healthy.control]
    runtime_leaders = group_leaders(runtime_processes)
    failed_run = prompt(failed, "failed-command")
    healthy_run = prompt(healthy, "healthy-command")

    for provider <- [failed_provider, healthy_provider] do
      assert Provider.eventually(fn -> Provider.reached?(provider, "pre-return-proof") end)

      assert Jason.decode!(File.read!(Provider.marker(provider, "pre-return-proof"))) == %{
               "stream_server_alive" => true,
               "local_group_leader" => true
             }

      assert Jason.decode!(File.read!(Provider.marker(provider, "startup"))) == %{
               "dotenv_absent" => true,
               "tidewave_absent" => true,
               "req_dotenv_disabled" => true,
               "db_dotenv_disabled" => true,
               "no_core" => true
             }

      assert Provider.methods(provider) == ["POST"]
      assert Provider.events(provider) == []
      assert Provider.alive?(Provider.pid(provider))
    end

    refute Provider.pid(failed_provider) == Provider.pid(healthy_provider)
    refute Provider.namespace(failed_provider) == Provider.namespace(healthy_provider)
    assert_host_unchanged(baseline, host_processes, host, :both_calls_held)

    Provider.release(failed_provider)
    failed_events = terminal_events(failed_run.attachment)
    assert List.last(failed_events)["outcome"] == "failed"
    refute Enum.any?(failed_events, &(&1.kind == "assistant.message_appended"))
    assert [{_request, true}] = Provider.events(failed_provider)
    Provider.assert_gone(failed_provider)

    assert Runtime.alive?(healthy.runtime)
    assert Provider.alive?(Provider.pid(healthy_provider))
    assert File.dir?(Provider.namespace(healthy_provider))
    assert Provider.events(healthy_provider) == []
    assert group_leaders(runtime_processes) == runtime_leaders
    assert_host_unchanged(baseline, host_processes, host, :one_runtime_failed)

    Provider.release(healthy_provider)
    healthy_events = terminal_events(healthy_run.attachment)
    assert List.last(healthy_events)["outcome"] == "completed"

    assert Enum.find(healthy_events, &(&1.kind == "assistant.message_appended"))["content"] ==
             "loopex"

    # A fresh public attachment reads the committed result, not a retained
    # callback value or a transient delta from the successful worker.
    assert {:ok, replay} =
             Loopex.attach(healthy.runtime, healthy_run.session_id, after_event_sequence: 0)

    assert terminal_events(replay) == healthy_events

    for {runtime, provider} <- [{failed, failed_provider}, {healthy, healthy_provider}] do
      assert Runtime.alive?(runtime.runtime)
      assert AgentLoopTestExecutor.jobs(runtime.executor) == []
      assert Provider.methods(provider) == ["POST"]
      assert [{_request, true}] = Provider.events(provider)
      Provider.assert_gone(provider)
    end

    assert group_leaders(runtime_processes) == runtime_leaders
    assert_host_unchanged(baseline, host_processes, host, :healthy_result_committed)
    stop_runtime(failed)
    stop_runtime(healthy)
    assert :ok = Application.stop(:loopex_llm_reqllm)
    refute adapter_started?()
    assert_host_unchanged(baseline, host_processes, host, :stopped)
  end

  # This host-owned observer forwards every event unchanged. It installs no
  # primary filter and neither suppresses nor redirects another handler's logs.
  @doc false
  def log(event, %{config: %{observer: observer}}) do
    send(observer, {:host_log, event})
    :ok
  end

  defp host_log_loop do
    receive do
      {:log, phase} ->
        Logger.error("host-runtime-isolation:#{phase}")
        host_log_loop()
    end
  end

  defp assert_host_unchanged(baseline, processes, host, phase) do
    assert host_snapshot(processes) == baseline
    send(host, {:log, phase})
    assert_receive {:host_log, %{meta: %{pid: ^host}, msg: {:string, message}}}, 1_000
    assert IO.chardata_to_string(message) == "host-runtime-isolation:#{phase}"
    assert host_snapshot(processes) == baseline
  end

  defp host_snapshot(processes) do
    {:logger.get_primary_config(), Enum.sort_by(:logger.get_handler_config(), & &1.id),
     group_leaders(processes)}
  end

  defp group_leaders(processes) do
    Enum.map(processes, fn pid ->
      assert is_pid(pid)
      assert {:group_leader, leader} = Process.info(pid, :group_leader)
      {pid, leader}
    end)
  end

  defp adapter_started? do
    Enum.any?(Application.started_applications(), &(elem(&1, 0) == :loopex_llm_reqllm))
  end

  defp start_runtime(provider, id) do
    {store_pid, store} = M1RuntimeTestStore.start_store(label: id)
    executor = AgentLoopTestExecutor.start()
    definition = AgentLoopFixture.tool_definition()

    {:ok, runtime} =
      Loopex.start_link(
        context_token_budget: 8_192,
        runtime_id: id,
        store: store,
        cleanup_grace_ms: 2_000,
        sampling: %{"max_tokens" => 64},
        model: %{module: Adapter, model: Adapter.default_model(), options: provider.options},
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
        active_tools: [definition["tool_id"]],
        policy: Loopex.AgentLoopTestPolicy,
        grant_decision: {:host_policy, :allow},
        bounds: %{max_turns: 2, token_budget: 256, deadline_ms: 30_000}
      )

    {:ok, %{control: control}} = Runtime.children(runtime)
    fixture = %{runtime: runtime, store_pid: store_pid, executor: executor, control: control}
    on_exit(fn -> stop_runtime(fixture) end)
    fixture
  end

  defp stop_runtime(fixture) do
    if Runtime.alive?(fixture.runtime), do: Loopex.stop(fixture.runtime)
    if Process.alive?(fixture.store_pid), do: GenServer.stop(fixture.store_pid)
    if Process.alive?(fixture.executor), do: Agent.stop(fixture.executor)
  end

  defp prompt(fixture, command_id) do
    assert {:ok, session_id} = Loopex.create_session(fixture.runtime, %{}, command_id: "create")
    assert {:ok, attachment} = Loopex.attach(fixture.runtime, session_id, after_event_sequence: 0)

    assert {:accepted, ^command_id} =
             Loopex.command(attachment, %{
               type: :prompt,
               command_id: command_id,
               content: "respond without tools"
             })

    %{session_id: session_id, attachment: attachment}
  end

  defp terminal_events(
         attachment,
         events \\ [],
         deadline \\ System.monotonic_time(:millisecond) + 10_000
       ) do
    case Loopex.next_event(attachment) do
      {:ok, %{kind: "run.finished"} = event} ->
        Enum.reverse([event | events])

      {:ok, event} ->
        terminal_events(attachment, [event | events], deadline)

      _empty ->
        assert System.monotonic_time(:millisecond) < deadline,
               "the runtime did not publish its committed run.finished"

        Process.sleep(5)
        terminal_events(attachment, events, deadline)
    end
  end
end
