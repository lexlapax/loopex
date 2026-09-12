Code.require_file("support/provider_isolation_fixture.exs", __DIR__)

defmodule Loopex.LLM.ReqLLM.ProviderAttemptAdapterContractTest do
  @moduledoc false
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO
  alias Loopex.LLM.ReqLLM, as: Adapter
  alias Loopex.LLM.ReqLLM.ProviderIsolationFixture, as: Fixture

  # Concept: a completed failing suite reports its seed alongside the refusal.
  # Technical depth: the authoritative runner owns the verdict and formatter.
  # This ordinary ExUnit callback reports only its suite-wide failure count and
  # seed, never a case verdict, reply, credential or exception. A whole-app run
  # can fail in another file, so the diagnostic does not attribute a failing
  # case to this module. It neither changes nor substitutes for the result,
  # and does not cover failures before this module or the suite can finish.
  ExUnit.after_suite(fn %{failures: failures} ->
    if failures > 0 do
      seed = ExUnit.configuration()[:seed]
      IO.puts(:stderr, "LOOPEX_TEST_DIAGNOSTIC seed=#{seed} suite_failures=#{failures}")
    end
  end)

  # Concept: ADR 0019 replaces same-VM descendant tracing and credential leases
  # with one owned OS group. The observable ownership, one-dispatch, error, and
  # result-before-cleanup claims remain; the retired registry is not a fake seam.
  # Technical depth: every call below uses Adapter.complete/3 and the actual
  # ProviderWorker.main/1. The protected classification case retains its name
  # and every post-canary failure mode. Loopback HTTP is not live-provider or
  # exact-package evidence.
  setup %{test: case_name} do
    variable = Adapter.credential_variable()
    previous = System.get_env(variable)
    System.put_env(variable, "credential-shaped-canary-secret")

    on_exit(fn ->
      try do
        if previous, do: System.put_env(variable, previous), else: System.delete_env(variable)
      catch
        kind, reason ->
          stack = __STACKTRACE__
          Fixture.report_failure(case_name, :credential_restore, stack)
          :erlang.raise(kind, reason, stack)
      end
    end)

    {:ok, _started} = Application.ensure_all_started(:req_llm)
    parent_state = parent_state()

    on_exit(fn ->
      try do
        assert parent_state() == parent_state
      catch
        kind, reason ->
          stack = __STACKTRACE__
          Fixture.report_failure(case_name, :parent_state_cleanup, stack)
          :erlang.raise(kind, reason, stack)
      end
    end)

    :ok
  catch
    kind, reason ->
      stack = __STACKTRACE__
      Fixture.report_failure(case_name, :setup, stack)
      :erlang.raise(kind, reason, stack)
  end

  test "one durable model attempt invokes the provider transport exactly once", %{test: case_name} do
    fixture = Fixture.new(:rate_limited, diagnostic_case: case_name)
    assert Fixture.complete(fixture) == {:error, {:dispatched_or_unknown, "model_call_failed"}}
    assert Fixture.canaries(fixture) == 1
    assert Fixture.methods(fixture) == ["POST"]
    assert Fixture.count(fixture) == 1
    assert [{_body, true}] = Fixture.events(fixture)
    Fixture.assert_gone(fixture)
  catch
    kind, reason ->
      stack = __STACKTRACE__
      Fixture.report_failure(case_name, :body, stack)
      :erlang.raise(kind, reason, stack)
  end

  test "caller death stops the shipped adapter transport worker", %{test: case_name} do
    fixture = Fixture.new(:unlinked_http, diagnostic_case: case_name)
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
  catch
    kind, reason ->
      stack = __STACKTRACE__
      Fixture.report_failure(case_name, :body, stack)
      :erlang.raise(kind, reason, stack)
  end

  test "provider direct IO is refused locally instead of leaking or blocking", %{test: case_name} do
    fixture = Fixture.new(:diagnostics_malformed, diagnostic_case: case_name)

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
  catch
    kind, reason ->
      stack = __STACKTRACE__
      Fixture.report_failure(case_name, :body, stack)
      :erlang.raise(kind, reason, stack)
  end

  test "provider cleanup owns an unlinked socket below an externally supervised task", %{
    test: case_name
  } do
    supervisor = Process.whereis(ReqLLM.TaskSupervisor)
    assert is_pid(supervisor)
    assert {:tracer, []} = :erlang.trace_info(supervisor, :tracer)
    fixture = Fixture.new(:detached_descendant_malformed, diagnostic_case: case_name)
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
  catch
    kind, reason ->
      stack = __STACKTRACE__
      Fixture.report_failure(case_name, :body, stack)
      :erlang.raise(kind, reason, stack)
  end

  test "caller death stops the stream server before the request adapter returns", %{
    test: case_name
  } do
    fixture = Fixture.new(:hold_before_return, diagnostic_case: case_name)
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
  catch
    kind, reason ->
      stack = __STACKTRACE__
      Fixture.report_failure(case_name, :body, stack)
      :erlang.raise(kind, reason, stack)
  end

  test "committed assistant tool history reaches OpenAI in its required function-call shape", %{
    test: case_name
  } do
    fixture = Fixture.new(:http_error, diagnostic_case: case_name)

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
  catch
    kind, reason ->
      stack = __STACKTRACE__
      Fixture.report_failure(case_name, :body, stack)
      :erlang.raise(kind, reason, stack)
  end

  test "the shipped adapter declares not_dispatched only before its transport canary and ambiguity after it",
       %{test: case_name} do
    before = Fixture.new(:reply, diagnostic_case: case_name)
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
      fixture = Fixture.new(mode, diagnostic_case: case_name)
      result = Fixture.complete(fixture, Fixture.request(deadline_ms: 2_000))
      assert Fixture.canaries(fixture) == 1, "transport latch not entered for #{mode}"
      assert Fixture.methods(fixture) == ["POST"], "wrong transport method for #{mode}"
      assert result == {:error, {:dispatched_or_unknown, "model_call_failed"}}, inspect(mode)
      refute inspect(result) =~ "credential-shaped-canary-secret"
      assert Fixture.count(fixture) <= 1
      Fixture.assert_gone(fixture)
    end
  catch
    kind, reason ->
      stack = __STACKTRACE__
      Fixture.report_failure(case_name, :body, stack)
      :erlang.raise(kind, reason, stack)
  end

  test "a managed adapter result precedes its retained resource stop acknowledgement", %{
    test: case_name
  } do
    fixture = Fixture.new(:http_error, diagnostic_case: case_name)
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
  catch
    kind, reason ->
      stack = __STACKTRACE__
      Fixture.report_failure(case_name, :body, stack)
      :erlang.raise(kind, reason, stack)
  end

  # These historical names retain the existing obligation. Credential retention
  # is now the child OS lifetime, not an emulated parent registry or lease API.
  test "retaining owner loss after a managed result releases the credential lease", %{
    test: case_name
  } do
    assert_retainer_loss(:after_result, case_name)
  catch
    kind, reason ->
      stack = __STACKTRACE__
      Fixture.report_failure(case_name, :body, stack)
      :erlang.raise(kind, reason, stack)
  end

  test "retaining owner loss during a managed call stops transport and releases the credential lease",
       %{test: case_name} do
    assert_retainer_loss(:during_call, case_name)
    assert_retainer_loss(:after_transport, case_name)
  catch
    kind, reason ->
      stack = __STACKTRACE__
      Fixture.report_failure(case_name, :body, stack)
      :erlang.raise(kind, reason, stack)
  end

  test "retaining owner loss during descendant cleanup releases the credential lease", %{
    test: case_name
  } do
    assert_retainer_loss(:during_cleanup, case_name)
  catch
    kind, reason ->
      stack = __STACKTRACE__
      Fixture.report_failure(case_name, :body, stack)
      :erlang.raise(kind, reason, stack)
  end

  test "retaining owner loss before protected entry stops bootstrap without transport", %{
    test: case_name
  } do
    assert_retainer_loss(:before_entry, case_name)
  catch
    kind, reason ->
      stack = __STACKTRACE__
      Fixture.report_failure(case_name, :body, stack)
      :erlang.raise(kind, reason, stack)
  end

  defp assert_retainer_loss(phase, case_name) do
    mode =
      case phase do
        :before_entry -> :hold_before_entry
        :after_result -> :http_error
        :during_cleanup -> :hold_before_error
        :during_call -> :hold_before_return
        :after_transport -> :blocked
      end

    fixture =
      Fixture.new(mode, paused: phase == :during_cleanup, diagnostic_case: case_name)

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

  test "an unmanaged adapter result follows guardian credential cleanup", %{test: case_name} do
    fixture = Fixture.new(:hold_before_error, paused: true, diagnostic_case: case_name)
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
  catch
    kind, reason ->
      stack = __STACKTRACE__
      Fixture.report_failure(case_name, :body, stack)
      :erlang.raise(kind, reason, stack)
  end

  test "killing the provider after one HTTP request never relaunches the attempt", %{
    test: case_name
  } do
    fixture = Fixture.new(:blocked, diagnostic_case: case_name)
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
  catch
    kind, reason ->
      stack = __STACKTRACE__
      Fixture.report_failure(case_name, :body, stack)
      :erlang.raise(kind, reason, stack)
  end

  @tag :failure_categories
  test "private worker preserves finite secret-free stream causes before outer fallback" do
    fixture = Fixture.new(:reply)
    run_category_probe(fixture, nil)
  end

  @tag :failure_categories
  test "private worker attributes returned incomplete completion and HTTP stream failures" do
    for {mode, stage, class} <- [
          {:incomplete_stream, "completion", "stream_incomplete"},
          {:http_error, "stream", "stream_http_server"},
          {:reply, "handoff", "returned_error"}
        ] do
      fixture = Fixture.new(mode)
      run_category_probe(fixture, %{"stage" => stage, "class" => class})
    end
  end

  @tag :failure_categories
  test "public stream results retain their tags while private stage labels stay finite" do
    run_category_probe(Fixture.new(:reply), :stream_controls)
  end

  defp run_category_probe(fixture, expected) do
    {:ok, {_, http_port}} = :inet.sockname(fixture.listener)
    script = Path.join(fixture.root, "failure-category-probe.exs")
    File.write!(script, category_probe_source(Fixture.request(), http_port, expected))
    {owner, reference, monitor} = start_category_probe(script, fixture.root, self())
    output = if expected, do: "STAGE_OK\n", else: "CONTROL_OK\nFINITE_CATEGORIES_OK\n"

    assert_receive {^reference, :started, _pid}, 5_000
    assert_receive {^reference, :result, result, cleanup}, 30_000
    assert {result, cleanup} == {{output, 0}, :clean}
    assert_receive {:DOWN, ^monitor, :process, ^owner, :normal}, 5_000
  end

  @tag :failure_categories
  test "synthetic probe owner survives caller death and proves child cessation" do
    fixture = Fixture.new(:reply)
    script = Path.join(fixture.root, "blocked-category-probe.exs")
    File.write!(script, "Process.sleep(:infinity)")

    caller =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    on_exit(fn -> if Process.alive?(caller), do: Process.exit(caller, :kill) end)
    {owner, reference, monitor} = start_category_probe(script, fixture.root, caller)
    assert_receive {^reference, :started, pid}, 5_000
    Process.exit(caller, :kill)
    assert_receive {^reference, :result, {:caller_down, 1}, :clean}, 5_000
    assert_receive {:DOWN, ^monitor, :process, ^owner, :normal}, 5_000

    {_output, status} =
      System.cmd("/bin/kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true)

    assert status != 0
  end

  @tag :failure_categories
  test "synthetic probe stop retains port ownership until child exit" do
    fixture = Fixture.new(:reply)
    script = Path.join(fixture.root, "blocked-category-probe.exs")
    File.write!(script, "Process.sleep(:infinity)")
    {owner, reference, monitor} = start_category_probe(script, fixture.root, self())
    assert_receive {^reference, :started, _pid}, 5_000
    send(owner, {reference, :stop})
    assert_receive {^reference, :result, {:stopped, 1}, :clean}, 5_000
    assert_receive {:DOWN, ^monitor, :process, ^owner, :normal}, 5_000
  end

  # Concept: the independent owner keeps its port through test-process death.
  # Technical depth: it watches the caller before launch, clears ambient env,
  # and kills only the child still attached to its port. Exit status, rather
  # than a lost port or a saved PID, proves cleanup. No raw output is returned.
  defp start_category_probe(script, root, caller) do
    controller = self()
    reference = make_ref()

    owner =
      spawn(fn ->
        Process.flag(:trap_exit, true)
        caller_monitor = Process.monitor(caller)

        receive do
          {^reference, :start} ->
            category_probe_owner(script, root, caller_monitor, controller, reference)

          {:DOWN, ^caller_monitor, :process, ^caller, _} ->
            :ok
        end
      end)

    monitor = Process.monitor(owner)

    on_exit(fn ->
      cleanup_monitor = Process.monitor(owner)
      send(owner, {reference, :stop})
      assert_receive {:DOWN, ^cleanup_monitor, :process, ^owner, _}, 5_000
    end)

    send(owner, {reference, :start})
    {owner, reference, monitor}
  end

  defp category_probe_owner(script, root, caller_monitor, controller, reference) do
    runner = Path.join(root, "category-probe.escript")
    paths = :io_lib.format(~c"~tp", [:code.get_path()]) |> IO.iodata_to_binary()
    source = "Code.eval_file(" <> inspect(script) <> ")"

    File.write!(runner, """
    #!/usr/bin/env escript
    %%! +S 2:2 +SDcpu 1 +SDio 1 +A 2
    main([]) ->
      ok = code:add_paths(#{paths}),
      {ok, _} = application:ensure_all_started(elixir),
      'Elixir.Code':eval_string(base64:decode("#{Base.encode64(source)}")),
      ok.
    """)

    environment =
      Loopex.LLM.ReqLLM.ProviderLauncher.spawn_environment()
      |> Map.new()
      |> Map.merge(
        Map.new(
          %{
            "HOME" => root,
            "TMPDIR" => root,
            "LANG" => "C.UTF-8",
            "LC_ALL" => "C.UTF-8",
            "ERL_CRASH_DUMP" => "/dev/null",
            "ERL_CRASH_DUMP_SECONDS" => "0"
          },
          fn {key, value} -> {String.to_charlist(key), String.to_charlist(value)} end
        )
      )
      |> Map.to_list()

    executable = Path.join(List.to_string(:code.root_dir()), "bin/escript")

    port =
      Port.open({:spawn_executable, "/bin/sh"}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        cd: root,
        env: environment,
        args: ["-c", "exec \"$1\" \"$2\" </dev/null", "category-probe", executable, runner]
      ])

    {:os_pid, pid} = Port.info(port, :os_pid)
    send(controller, {reference, :started, pid})

    result =
      category_probe_result(
        port,
        "",
        System.monotonic_time(:millisecond) + 30_000,
        caller_monitor,
        reference
      )

    cleanup = stop_category_probe(port, result)

    outcome =
      case result do
        {:exited, output, status} -> {output, status}
        other -> other
      end

    send(controller, {reference, :result, outcome, cleanup})
  end

  defp stop_category_probe(_port, {:exited, _, _}), do: :clean

  defp stop_category_probe(port, _result) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} ->
        System.cmd("/bin/kill", ["-KILL", Integer.to_string(pid)], stderr_to_stdout: true)

        receive do
          {^port, {:exit_status, _}} -> :clean
        after
          2_000 -> :cleanup_unavailable
        end

      nil ->
        receive do
          {^port, {:exit_status, _}} -> :clean
        after
          0 -> :cleanup_unavailable
        end
    end
  end

  defp category_probe_result(port, output, deadline, caller_monitor, reference) do
    receive do
      {^port, {:data, data}} when byte_size(output) + byte_size(data) <= 128 ->
        category_probe_result(port, output <> data, deadline, caller_monitor, reference)

      {^port, {:exit_status, status}} ->
        safe =
          if output in [
               "STAGE_OK\n",
               "CONTROL_OK\nFINITE_CATEGORIES_OK\n",
               "CONTROL_OK\nFINITE_CATEGORIES_FAILED\n",
               "FINITE_CATEGORIES_FAILED\n",
               "CONTROL_PREFLIGHT_REFUSED\n",
               "CONTROL_UNKNOWN\n",
               "CONTROL_OTHER\n",
               "STAGE_NOT_DISPATCHED\n",
               "STAGE_UNEXPECTED_SUCCESS\n",
               "STAGE_INVALID_RESULT\n"
             ] or finite_stage_output?(output), do: output, else: :invalid_output

        {:exited, safe, status}

      {^port, {:data, data}} ->
        {:invalid_output, probe_output_class(output <> data)}

      {:DOWN, ^caller_monitor, :process, _, _} ->
        {:caller_down, 1}

      {^reference, :stop} ->
        {:stopped, 1}
    after
      max(deadline - System.monotonic_time(:millisecond), 0) -> {:probe_timeout, 1}
    end
  end

  defp category_classes do
    ~w(stream_http_auth stream_http_rate_limit stream_http_server stream_http_status
      stream_transport_timeout stream_transport_tls stream_transport_error
      stream_http_protocol_error stream_finch_error stream_http_task_failed
      stream_wait_timeout stream_task_call_timeout stream_decode_error stream_other_error
      genserver_timeout raised exited thrown caught provider_status stream_failed
      stream_incomplete assembly_failed returned_error unclassified)
  end

  defp finite_stage_output?(output) do
    case String.split(output, ":") do
      ["STAGE_RESULT", stage, class] ->
        stage in ~w(handoff stream metadata completion assembly calls unavailable) and
          String.ends_with?(class, "\n") and
          String.trim_trailing(class, "\n") in category_classes()

      _ ->
        false
    end
  end

  defp probe_output_class(output) do
    cond do
      String.contains?(output, "warning:") -> :compiler_warning
      String.contains?(output, "SyntaxError") -> :syntax_error
      String.contains?(output, "CompileError") -> :compile_error
      String.contains?(output, "escript:") -> :escript_error
      String.contains?(output, "[error]") -> :dependency_error_log
      String.contains?(output, "error:") -> :compiler_error
      String.contains?(output, "Error") -> :exception_text
      String.contains?(output, "[warning]") -> :dependency_warning_log
      String.contains?(output, "FINITE_CATEGORIES_FAILED") -> :probe_failed
      true -> :unrecognized_output
    end
  end

  defp stream_category_controls do
    ~S"""
    {:ok, model} = ReqLLM.model(request.model)
    {:ok, identity} = Loopex.LLM.ReqLLM.identity(request.model)
    clean = %{finish_reason: :stop, status: 200, headers: []}
    text = [ReqLLM.StreamChunk.text("control")]
    broken_calls = [
      ReqLLM.StreamChunk.tool_call("write", %{}, %{id: "toolu_1", index: 1, start: true}),
      ReqLLM.StreamChunk.meta(%{tool_call_args: %{index: 1, fragment: "{\"path\":\"a"}})
    ]
    dead = spawn(fn -> :ok end)
    dead_monitor = Process.monitor(dead)
    receive do {:DOWN, ^dead_monitor, :process, ^dead, _} -> :ok end
    cases = [
      {clean, text, "none", "none", :ok},
      {:dead, text, "metadata", "exited", :stream_interrupted},
      {%{clean | status: 429}, text, "completion", "provider_status", :stream_failed},
      {Map.put(clean, :error, "unused-secret-never-retained"), text, "completion", "stream_failed", :stream_failed},
      {%{clean | finish_reason: :incomplete}, text, "completion", "stream_incomplete", :stream_incomplete},
      {Map.put(clean, :usage, :not_a_usage_map), text, "assembly", "assembly_failed", :reply_not_assembled},
      {%{clean | finish_reason: :length}, broken_calls, "calls", "returned_error", :tool_call_not_reconstructible}
    ]
    for {metadata, chunks, stage, class, tag} <- cases do
      handle = if metadata == :dead do
        dead
      else
        {:ok, handle} = ReqLLM.StreamResponse.MetadataHandle.start_link(fn -> metadata end)
        handle
      end
      response = %ReqLLM.StreamResponse{stream: chunks, metadata_handle: handle,
        cancel: fn -> :ok end, model: model,
        context: ReqLLM.Context.new([ReqLLM.Context.user("hello")])}
      caller = self()
      collector = spawn_link(fn ->
        loop = fn recur, {count, unexpected} ->
          receive do
            {:trace, ^caller, :call, {Loopex.LLM.ReqLLM, :failure_pair, 2}, :normalization_match} ->
              recur.(recur, {min(count + 1, 2), unexpected})
            {:trace, ^caller, :call, {Loopex.LLM.ReqLLM, :failure_pair, 2}, :unexpected_normalization} ->
              recur.(recur, {count, min(unexpected + 1, 2)})
            {:collect, reference} -> send(caller, {reference, {count, unexpected}})
          end
        end
        loop.(loop, {0, 0})
      end)
      target = {Loopex.LLM.ReqLLM, :failure_pair, 2}
      true = :erlang.trace_pattern(target, [{[stage, class], [], [{:message, :normalization_match}]},
        {[:_, :_], [], [{:message, :unexpected_normalization}]}], [:local]) > 0
      1 = :erlang.trace(self(), true, [:call, :arity, {:tracer, collector}])
      try do
        result = Loopex.LLM.ReqLLM.reply_from_stream(response, request, identity, fn _ -> :ok end)
        if tag == :ok do
          {:ok, %{text: "control"}} = result
        else
          {:error, {^tag, "model_call_failed"}} = result
        end
        barrier = :erlang.trace_delivered(self())
        receive do {:trace_delivered, _, ^barrier} -> :ok after 1_000 -> raise "trace barrier unavailable" end
        reference = make_ref()
        send(collector, {:collect, reference})
        expected_count = {if(tag == :ok, do: 0, else: 1), 0}
        receive do {^reference, ^expected_count} -> :ok after 1_000 -> raise "trace control failed" end
      after
        :erlang.trace(self(), false, [:call])
        :erlang.trace_pattern(target, false, [:local])
        if Process.alive?(collector), do: Process.exit(collector, :normal)
        if metadata != :dead and Process.alive?(handle), do: GenServer.stop(handle)
      end
    end
    """
  end

  defp category_probe_source(request, http_port, expected) do
    encoded = request |> :erlang.term_to_binary() |> Base.encode64()

    """
    defmodule CategoryProbeTransport do
      def call(request) do
        if Application.get_env(:req_llm, :category_probe_handoff) do
          raise "synthetic handoff failure"
        else
          %{request | scheme: :http, host: "127.0.0.1", port: #{http_port}, path: "/", query: nil}
        end
      end
    end
    try do
      :logger.set_primary_config(:level, :emergency)
      expected_configuration = :erlang.binary_to_term(Base.decode64!("#{Base.encode64(:erlang.term_to_binary(expected))}"))
      Application.put_env(:req_llm, :category_probe_handoff,
        match?(%{"stage" => "handoff"}, expected_configuration), persistent: true)
      Application.put_env(:req_llm, :load_dotenv, false, persistent: true)
      Application.put_env(:llm_db, :load_dotenv, false, persistent: true)
      Application.put_env(:req_llm, :finch_request_adapter, CategoryProbeTransport)
      {:ok, _} = Application.ensure_all_started(:req_llm)
      :ok = :logger.set_primary_config(:level, :none)
      request = :erlang.binary_to_term(Base.decode64!("#{encoded}"))
      credential = "credential-shaped-canary-secret"
      invoke = fn progress ->
        {:ok, current} = Loopex.Model.request(request.model, request.messages,
          sampling: request.sampling, deadline: System.system_time(:millisecond) + 10_000)
        Loopex.LLM.ReqLLM.worker_invoke(current, credential, progress, fn -> :ok end)
      end
      if expected_configuration == :stream_controls do
        #{stream_category_controls()}
        IO.puts("STAGE_OK")
        System.halt(0)
      end
      if expected_configuration != nil do
        expected = {:error, {:dispatched_or_unknown, "model_call_failed"}, expected_configuration}
        case invoke.(fn _ -> :ok end) do
          ^expected -> IO.puts("STAGE_OK")
          {:error, {:dispatched_or_unknown, "model_call_failed"}, %{"stage" => stage, "class" => class}}
            when stage in #{inspect(~w(handoff stream metadata completion assembly calls unavailable))}
              and class in #{inspect(category_classes())} ->
            IO.puts("STAGE_RESULT:" <> stage <> ":" <> class)
            System.halt(1)
          {:error, {:not_dispatched, "model_call_failed"}} ->
            IO.puts("STAGE_NOT_DISPATCHED"); System.halt(1)
          {:ok, _} -> IO.puts("STAGE_UNEXPECTED_SUCCESS"); System.halt(1)
          _ -> IO.puts("STAGE_INVALID_RESULT"); System.halt(1)
        end
        System.halt(0)
      end
      case invoke.(fn _ -> :ok end) do
        {:ok, %{text: "loopex", delta_count: count}} when count > 0 -> :ok
        {:error, {:not_dispatched, _}} -> IO.puts("CONTROL_PREFLIGHT_REFUSED"); System.halt(1)
        {:error, {:dispatched_or_unknown, _}} -> IO.puts("CONTROL_UNKNOWN"); System.halt(1)
        _ -> IO.puts("CONTROL_OTHER"); System.halt(1)
      end
      IO.puts("CONTROL_OK")
      {:ok, fallback_request} = Loopex.Model.request(request.model, request.messages,
        sampling: request.sampling, deadline: System.system_time(:millisecond) + 10_000)
      {:error, {:dispatched_or_unknown, "model_call_failed"},
       %{"stage" => "unavailable", "class" => "unclassified"}} =
        Loopex.LLM.ReqLLM.worker_invoke(fallback_request, credential, fn _ -> :ok end,
          fn -> raise "synthetic start failure" end)
      secret = "unused-secret-never-retained"
      causes = [
        {%ReqLLM.Error.API.Request{status: 401, reason: secret}, "stream_http_auth"},
        {%ReqLLM.Error.API.Request{status: 403, headers: secret}, "stream_http_auth"},
        {%ReqLLM.Error.API.Request{status: 429, response_body: secret}, "stream_http_rate_limit"},
        {%ReqLLM.Error.API.Request{status: 503, request_body: secret}, "stream_http_server"},
        {%ReqLLM.Error.API.Request{status: 418, reason: secret}, "stream_http_status"},
        {%Finch.TransportError{reason: :timeout, source: secret}, "stream_transport_timeout"},
        {%Finch.TransportError{reason: {:tls_alert, secret}}, "stream_transport_tls"},
        {%Finch.TransportError{reason: secret}, "stream_transport_error"},
        {%Mint.TransportError{reason: :timeout}, "stream_transport_timeout"},
        {%Mint.TransportError{reason: {:tls_alert, secret}}, "stream_transport_tls"},
        {%Mint.TransportError{reason: secret}, "stream_transport_error"},
        {%Finch.HTTPError{reason: secret}, "stream_http_protocol_error"},
        {%Finch.Error{reason: secret}, "stream_finch_error"},
        {{:http_task_failed, secret}, "stream_http_task_failed"},
        {:timeout, "stream_wait_timeout"},
        {{:exit, {:timeout, {GenServer, :call, secret}}}, "stream_task_call_timeout"},
        {%Jason.DecodeError{data: secret}, "stream_decode_error"},
        {{:error, %Jason.DecodeError{data: secret}}, "stream_decode_error"},
        {secret, "stream_other_error"}
      ]
      for {cause, class} <- causes do
        exception = %ReqLLM.Error.API.Stream{cause: cause, reason: secret}
        expected = {:error, {:dispatched_or_unknown, "model_call_failed"}, %{"stage" => "stream", "class" => class}}
        ^expected = invoke.(fn _ -> raise exception end)
      end
      for {action, class} <- [
        {fn -> raise secret end, "raised"},
        {fn -> exit({:timeout, {GenServer, :call, secret}}) end, "genserver_timeout"},
        {fn -> exit(secret) end, "exited"},
        {fn -> throw(secret) end, "thrown"}
      ] do
        expected = {:error, {:dispatched_or_unknown, "model_call_failed"}, %{"stage" => "stream", "class" => class}}
        ^expected = invoke.(fn _ -> action.() end)
      end
      IO.puts("FINITE_CATEGORIES_OK")
    rescue
      _ -> IO.puts("FINITE_CATEGORIES_FAILED"); System.halt(1)
    catch
      _, _ -> IO.puts("FINITE_CATEGORIES_FAILED"); System.halt(1)
    end
    """
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
