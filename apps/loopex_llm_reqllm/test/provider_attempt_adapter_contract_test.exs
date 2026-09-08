Code.require_file("support/provider_isolation_fixture.exs", __DIR__)

defmodule Loopex.LLM.ReqLLM.ProviderAttemptAdapterContractTest do
  @moduledoc false
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO
  alias Loopex.LLM.ReqLLM, as: Adapter
  alias Loopex.LLM.ReqLLM.ProviderIsolationFixture, as: Fixture

  # Concept: ADR 0019 replaces same-VM descendant tracing and credential leases
  # with one owned OS group. The observable ownership, one-dispatch, error, and
  # result-before-cleanup claims remain; the retired registry is not a fake seam.
  # Technical depth: every call below uses Adapter.complete/3 and the actual
  # ProviderWorker.main/1. The protected classification case retains its name
  # and every post-canary failure mode. Loopback HTTP is not live-provider or
  # exact-package evidence.
  setup do
    variable = Adapter.credential_variable()
    previous = System.get_env(variable)
    System.put_env(variable, "credential-shaped-canary-secret")

    on_exit(fn ->
      if previous, do: System.put_env(variable, previous), else: System.delete_env(variable)
    end)

    {:ok, _started} = Application.ensure_all_started(:req_llm)
    parent_state = parent_state()
    on_exit(fn -> assert parent_state() == parent_state end)
    :ok
  end

  test "one durable model attempt invokes the provider transport exactly once" do
    fixture = Fixture.new(:rate_limited)
    assert Fixture.complete(fixture) == {:error, {:dispatched_or_unknown, "model_call_failed"}}
    assert Fixture.canaries(fixture) == 1
    assert Fixture.methods(fixture) == ["POST"]
    assert Fixture.count(fixture) == 1
    assert [{_body, true}] = Fixture.events(fixture)
    Fixture.assert_gone(fixture)
  end

  test "caller death stops the shipped adapter transport worker" do
    fixture = Fixture.new(:unlinked_http)
    call = Fixture.managed(fixture, Fixture.request(), :unmanaged)
    caller = call.caller
    guardian = call.guardian

    assert Fixture.eventually(fn -> Fixture.count(fixture) == 1 end)
    assert Fixture.transport_events(fixture) == [:connected]
    File.write!(Fixture.marker(fixture, "unlink-http"), "unlink")
    assert Fixture.eventually(fn -> Fixture.reached?(fixture, "unlinked-http-proof") end)

    assert Jason.decode!(File.read!(Fixture.marker(fixture, "unlinked-http-proof"))) == %{
             "server_alive" => true,
             "http_task_alive" => true,
             "http_task_supervised" => true,
             "dependency_link_present_before" => true,
             "dependency_link_removed" => true
           }

    assert Fixture.transport_events(fixture) == [:connected]
    assert Process.alive?(guardian)
    assert Fixture.alive?(Fixture.pid(fixture))
    refute_receive {:completed, ^caller, _result}, 0

    Process.exit(caller, :kill)
    caller_monitor = call.caller_monitor
    guardian_monitor = call.monitor
    assert_receive {:DOWN, ^caller_monitor, :process, ^caller, :killed}, 1_000
    assert_receive {:DOWN, ^guardian_monitor, :process, ^guardian, :normal}, 2_500

    assert Fixture.eventually(fn ->
             Fixture.transport_events(fixture) == [:connected, :closed]
           end)

    Fixture.assert_gone(fixture)
    assert Fixture.canaries(fixture) == 1
    assert Fixture.methods(fixture) == ["POST"]
    assert [{_request, true}] = Fixture.events(fixture)
    refute_receive {:completed, ^caller, _result}, 0
  end

  test "provider direct IO is refused locally instead of leaking or blocking" do
    fixture = Fixture.new(:diagnostics_malformed)

    output =
      capture_io(fn ->
        call = Fixture.managed(fixture)
        caller = call.caller

        assert_receive {:completed, ^caller,
                        {:error, {:dispatched_or_unknown, "model_call_failed"}}},
                       5_000

        assert Jason.decode!(File.read!(Fixture.marker(fixture, "io-results"))) ==
                 %{"direct" => "refused", "supervised" => "refused"}

        File.write!(Fixture.marker(fixture, "release-diagnostics"), "release")
        assert Fixture.eventually(fn -> Fixture.reached?(fixture, "delayed-diagnostics") end)
        Fixture.stop(call)
      end)

    assert output == ""
    assert Fixture.reached?(fixture, "diagnostics")
    assert Fixture.canaries(fixture) == 1
    assert Fixture.methods(fixture) == ["POST"]
    assert Fixture.count(fixture) == 0
    Fixture.assert_gone(fixture)

    assert capture_io(Process.whereis(ReqLLM.TaskSupervisor), fn ->
             task =
               Task.Supervisor.async(ReqLLM.TaskSupervisor, fn -> IO.write("host-task-usable") end)

             assert :ok = Task.await(task, 1_000)
           end) == "host-task-usable"
  end

  test "provider cleanup owns an unlinked socket below an externally supervised task" do
    supervisor = Process.whereis(ReqLLM.TaskSupervisor)
    assert is_pid(supervisor)
    assert {:tracer, []} = :erlang.trace_info(supervisor, :tracer)
    fixture = Fixture.new(:detached_descendant_malformed)
    assert Fixture.complete(fixture) == {:error, {:dispatched_or_unknown, "model_call_failed"}}

    assert Jason.decode!(File.read!(Fixture.marker(fixture, "detached-proof"))) ==
             %{"session_dead" => true, "task_dead" => true, "socket_alive" => true}

    assert Fixture.eventually(fn -> Fixture.probe_events(fixture) == [:connected, :closed] end)
    Fixture.assert_gone(fixture)
    assert Fixture.canaries(fixture) == 1
    assert Fixture.methods(fixture) == ["POST"]
    assert Fixture.count(fixture) == 0
    assert Process.alive?(supervisor)
    assert {:tracer, []} = :erlang.trace_info(supervisor, :tracer)
  end

  test "caller death stops the stream server before the request adapter returns" do
    fixture = Fixture.new(:hold_before_return)
    call = Fixture.managed(fixture, Fixture.request(), :unmanaged)
    caller = call.caller
    guardian = call.guardian

    assert Fixture.eventually(fn -> Fixture.reached?(fixture, "pre-return-proof") end)

    assert Jason.decode!(File.read!(Fixture.marker(fixture, "pre-return-proof"))) ==
             %{"stream_server_alive" => true, "local_group_leader" => true}

    assert Fixture.canaries(fixture) == 1
    assert Fixture.methods(fixture) == ["POST"]
    assert Fixture.count(fixture) == 0
    assert Fixture.transport_events(fixture) == []
    refute_receive {:completed, ^caller, _result}, 0

    Process.exit(caller, :kill)
    caller_monitor = call.caller_monitor
    guardian_monitor = call.monitor
    assert_receive {:DOWN, ^caller_monitor, :process, ^caller, :killed}, 1_000
    assert_receive {:DOWN, ^guardian_monitor, :process, ^guardian, :normal}, 2_500
    Fixture.assert_gone(fixture)
    assert Fixture.count(fixture) == 0
    refute_receive {:completed, ^caller, _result}, 0
  end

  test "committed assistant tool history reaches OpenAI in its required function-call shape" do
    fixture = Fixture.new(:http_error)

    request =
      Fixture.request(
        model: "openai:gpt-4-turbo-2024-04-09",
        messages: [
          %{"role" => "user", "content" => "read the file"},
          %{
            "role" => "assistant",
            "content" => "I will read it.",
            "tool_calls" => [
              %{
                "tool_call_id" => "call_MiXeD_123",
                "tool_id" => "loopex.read",
                "arguments" => %{"path" => "README.md"}
              }
            ]
          },
          %{"role" => "tool", "tool_call_id" => "call_MiXeD_123", "content" => "file contents"}
        ]
      )

    assert Fixture.complete(fixture, request) ==
             {:error, {:dispatched_or_unknown, "model_call_failed"}}

    assert [{body, true}] = Fixture.events(fixture)
    assert Fixture.methods(fixture) == ["POST"]
    assistant = Enum.find(body["messages"], &(&1["role"] == "assistant"))

    assert %{
             "tool_calls" => [
               %{
                 "id" => "call_MiXeD_123",
                 "type" => "function",
                 "function" => %{"name" => "read", "arguments" => arguments}
               }
             ]
           } = assistant

    assert Jason.decode!(arguments) == %{"path" => "README.md"}
    tool_result = Enum.find(body["messages"], &(&1["role"] == "tool"))
    assert tool_result["tool_call_id"] == "call_MiXeD_123"
    assert tool_result["content"] == "file contents"
    Fixture.assert_gone(fixture)
  end

  test "the shipped adapter declares not_dispatched only before its transport canary and ambiguity after it" do
    before = Fixture.new()
    System.delete_env(Adapter.credential_variable())
    assert Fixture.complete(before) == {:error, {:not_dispatched, "model_call_failed"}}
    assert Fixture.canaries(before) == 0
    assert Fixture.count(before) == 0
    Fixture.assert_gone(before)
    System.put_env(Adapter.credential_variable(), "credential-shaped-canary-secret")

    for mode <- [
          :closed_port,
          :http_error,
          :malformed_response,
          :incomplete_stream,
          :timeout,
          :raise,
          :throw,
          :exit,
          :malformed_return,
          :tagged_not_dispatched
        ] do
      fixture = Fixture.new(mode)
      result = Fixture.complete(fixture, Fixture.request(deadline_ms: 2_000))
      assert Fixture.canaries(fixture) == 1, "transport latch not entered for #{mode}"
      assert Fixture.methods(fixture) == ["POST"], "wrong transport method for #{mode}"
      assert result == {:error, {:dispatched_or_unknown, "model_call_failed"}}, inspect(mode)
      refute inspect(result) =~ "credential-shaped-canary-secret"
      assert Fixture.count(fixture) <= 1
      Fixture.assert_gone(fixture)
    end
  end

  test "a managed adapter result precedes its retained resource stop acknowledgement" do
    fixture = Fixture.new(:http_error)
    call = Fixture.managed(fixture, Fixture.request(deadline_ms: 2_000))
    caller = call.caller

    assert_receive {:completed, ^caller, {:error, {:dispatched_or_unknown, "model_call_failed"}}},
                   5_000

    assert Fixture.methods(fixture) == ["POST"]
    assert Process.alive?(call.guardian)
    assert Fixture.alive?(Fixture.pid(fixture))
    monitor = call.caller_monitor
    assert_receive {:DOWN, ^monitor, :process, ^caller, :normal}, 1_000
    wrong_stop = make_ref()
    deadline = System.monotonic_time(:millisecond) + 2_000

    send(
      call.guardian,
      {:loopex_provider_resource_stop, make_ref(), wrong_stop, self(), deadline, deadline + 100}
    )

    refute_receive {:loopex_provider_resource_stopped, ^wrong_stop, _resource}, 50
    assert Fixture.alive?(Fixture.pid(fixture))
    guardian = call.guardian
    :erlang.trace(guardian, true, [:receive, :send, {:tracer, self()}])
    Fixture.stop(call)
    observer = self()

    proof =
      queued_message(observer, fn message ->
        match?(
          {:trace, ^guardian, :receive,
           {_port, {:data, {:eol, "cleanup_complete:" <> _binding}}}},
          message
        )
      end)

    acknowledgement =
      queued_message(observer, fn message ->
        match?(
          {:trace, ^guardian, :send, {:loopex_provider_resource_stopped, _stop, ^guardian},
           ^observer},
          message
        )
      end)

    {:messages, messages} = Process.info(observer, :messages)

    assert Enum.find_index(messages, &(&1 == proof)) <
             Enum.find_index(messages, &(&1 == acknowledgement))

    Fixture.assert_gone(fixture)
  end

  # These historical names retain the existing obligation. Credential retention
  # is now the child OS lifetime, not an emulated parent registry or lease API.
  test "retaining owner loss after a managed result releases the credential lease" do
    assert_retainer_loss(:after_result)
  end

  test "retaining owner loss during a managed call stops transport and releases the credential lease" do
    assert_retainer_loss(:during_call)
    assert_retainer_loss(:after_transport)
  end

  test "retaining owner loss during descendant cleanup releases the credential lease" do
    assert_retainer_loss(:during_cleanup)
  end

  test "retaining owner loss before protected entry stops bootstrap without transport" do
    assert_retainer_loss(:before_entry)
  end

  defp assert_retainer_loss(phase) do
    mode =
      case phase do
        :before_entry -> :hold_before_entry
        :after_result -> :http_error
        :during_cleanup -> :hold_before_error
        :during_call -> :hold_before_return
        :after_transport -> :blocked
      end

    fixture = Fixture.new(mode, paused: phase == :during_cleanup)
    {retainer, retainer_monitor} = spawn_monitor(fn -> receive do: (:stop -> :ok) end)
    call = Fixture.managed(fixture, Fixture.request(), retainer)
    guardian = call.guardian
    caller = call.caller
    monitor = call.monitor

    if phase == :during_cleanup do
      :erlang.trace(guardian, true, [:receive, {:tracer, self()}])
      send(caller, :continue)

      assert_receive {:trace, ^guardian, :receive,
                      {:provider_frame, _receiver, {:ok, :dispatch_started, _binding}}},
                     5_000
    end

    # Concept: interrupt bootstrap only after its cleanup observations exist.
    # Technical depth: entry-env is written after the PID and namespace writes
    # complete; hold_before_entry still blocks before ProviderWorker.main/1.
    assert Fixture.eventually(fn ->
             Fixture.reached?(fixture, "pid") and Fixture.reached?(fixture, "entry-env")
           end)

    if phase != :before_entry,
      do: assert(Fixture.eventually(fn -> Fixture.canaries(fixture) == 1 end))

    assert Fixture.methods(fixture) == if(phase == :before_entry, do: [], else: ["POST"])

    if phase in [:after_transport, :after_result],
      do: assert(Fixture.eventually(fn -> Fixture.count(fixture) == 1 end))

    if phase == :during_call do
      assert Fixture.count(fixture) == 0
      assert Fixture.eventually(fn -> Fixture.reached?(fixture, "pre-return-proof") end)

      assert Jason.decode!(File.read!(Fixture.marker(fixture, "pre-return-proof"))) ==
               %{"stream_server_alive" => true, "local_group_leader" => true}
    end

    if phase == :after_result do
      assert_receive {:completed, ^caller,
                      {:error, {:dispatched_or_unknown, "model_call_failed"}}},
                     5_000

      caller_monitor = call.caller_monitor
      assert_receive {:DOWN, ^caller_monitor, :process, ^caller, :normal}, 1_000
    end

    assert Process.alive?(guardian)
    assert {:monitors, monitors} = Process.info(guardian, :monitors)
    assert {:process, retainer} in monitors

    terminal =
      if phase == :during_cleanup do
        assert :erlang.suspend_process(guardian)
        Fixture.release(fixture)

        queued_message(guardian, fn message ->
          match?({:provider_frame, _, {:ok, :terminal, _}}, message)
        end)
      end

    Process.exit(retainer, :kill)
    assert_receive {:DOWN, ^retainer_monitor, :process, ^retainer, :killed}, 1_000

    if phase == :during_cleanup do
      down =
        queued_message(guardian, fn message ->
          match?({:DOWN, _, :process, ^retainer, :killed}, message)
        end)

      {:messages, messages} = Process.info(guardian, :messages)

      assert Enum.find_index(messages, &(&1 == terminal)) <
               Enum.find_index(messages, &(&1 == down))

      assert :erlang.resume_process(guardian)
    end

    assert_receive {:DOWN, ^monitor, :process, ^guardian, :normal}, 2_500
    Fixture.assert_gone(fixture)
    assert Fixture.count(fixture) == if(phase in [:before_entry, :during_call], do: 0, else: 1)

    if phase != :after_result do
      assert_receive {:completed, ^caller,
                      {:error, {:dispatched_or_unknown, "model_call_failed"}}},
                     1_000

      caller_monitor = call.caller_monitor
      assert_receive {:DOWN, ^caller_monitor, :process, ^caller, :normal}, 1_000
    end
  end

  test "an unmanaged adapter result follows guardian credential cleanup" do
    fixture = Fixture.new(:hold_before_error, paused: true)
    call = Fixture.managed(fixture, Fixture.request(deadline_ms: 5_000), :unmanaged)
    guardian = call.guardian
    caller = call.caller
    :erlang.trace(guardian, true, [:receive, {:tracer, self()}])
    send(caller, :continue)

    assert_receive {:trace, ^guardian, :receive,
                    {:provider_frame, _receiver, {:ok, :dispatch_started, _binding}}},
                   5_000

    assert :erlang.suspend_process(guardian)
    Fixture.release(fixture)

    queued_message(guardian, fn message ->
      match?({:provider_frame, _, {:ok, :terminal, _}}, message)
    end)

    pid = Fixture.pid(fixture)
    assert {_output, 0} = System.cmd("/bin/kill", ["-STOP", Integer.to_string(pid)])

    try do
      assert :erlang.resume_process(guardian)

      assert Fixture.eventually(
               fn ->
                 {:status, :waiting} == Process.info(caller, :status)
               end,
               500
             )

      refute_receive {:completed, ^caller, _result}, 100
      assert Fixture.alive?(pid)
    after
      assert {_output, 0} = System.cmd("/bin/kill", ["-CONT", Integer.to_string(pid)])
    end

    assert_receive {:trace, ^guardian, :receive,
                    {_port, {:data, {:eol, "cleanup_complete:" <> _binding}}}},
                   2_000

    monitor = call.monitor
    assert_receive {:DOWN, ^monitor, :process, ^guardian, :normal}, 500

    assert_receive {:completed, ^caller, {:error, {:dispatched_or_unknown, "model_call_failed"}}},
                   1_000

    caller_monitor = call.caller_monitor
    assert_receive {:DOWN, ^caller_monitor, :process, ^caller, :normal}, 1_000
    Fixture.assert_gone(fixture)
    assert Fixture.count(fixture) == 1
    assert Fixture.methods(fixture) == ["POST"]
  end

  test "killing the provider after one HTTP request never relaunches the attempt" do
    fixture = Fixture.new(:blocked)
    call = Fixture.managed(fixture)
    assert Fixture.eventually(fn -> Fixture.count(fixture) == 1 end)

    assert {_output, 0} =
             System.cmd("/bin/kill", ["-KILL", Integer.to_string(Fixture.pid(fixture))])

    caller = call.caller

    assert_receive {:completed, ^caller, {:error, {:dispatched_or_unknown, "model_call_failed"}}},
                   5_000

    Fixture.stop(call)
    Fixture.assert_gone(fixture)
    assert Fixture.canaries(fixture) == 1
    assert Fixture.methods(fixture) == ["POST"]
    assert Fixture.count(fixture) == 1
  end

  defp queued_message(guardian, predicate) do
    assert Fixture.eventually(fn ->
             case Process.info(guardian, :messages) do
               {:messages, messages} -> Enum.any?(messages, predicate)
               nil -> false
             end
           end)

    {:messages, messages} = Process.info(guardian, :messages)
    Enum.find(messages, predicate)
  end

  defp parent_state do
    {
      Map.new(Application.get_all_env(:req_llm)),
      Map.new(Application.get_all_env(:llm_db)),
      :logger.get_primary_config(),
      for name <- [ReqLLM.Supervisor, ReqLLM.TaskSupervisor] do
        pid = Process.whereis(name)
        {name, pid, Process.info(pid, :group_leader)}
      end
    }
  end
end
