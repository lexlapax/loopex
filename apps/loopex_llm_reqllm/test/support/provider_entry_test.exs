Code.require_file("provider_isolation_fixture.exs", __DIR__)

defmodule Loopex.LLM.ReqLLM.ProviderEntryTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO
  import ExUnit.CaptureLog
  require Logger
  alias Loopex.LLM.ReqLLM, as: Adapter
  alias Loopex.LLM.ReqLLM.ProviderIsolationFixture, as: Fixture
  alias Loopex.LLM.ReqLLM.ProviderCodec

  # Supplemental process evidence only. No retained selector is removed or
  # substituted by this file; package and live-provider lanes remain separate.
  setup do
    variable = Adapter.credential_variable()
    previous = System.get_env(variable)
    System.put_env(variable, "synthetic-entry-credential-canary")

    on_exit(fn ->
      if previous, do: System.put_env(variable, previous), else: System.delete_env(variable)
    end)

    {:ok, _started} = Application.ensure_all_started(:req_llm)
    :ok
  end

  test "retainer death after actual callback delivery ends the retained provider lifetime" do
    fixture = Fixture.new()
    {retainer, retainer_monitor} = spawn_monitor(fn -> receive do: (:stop -> :ok) end)
    call = Fixture.managed(fixture, Fixture.request(), retainer)
    caller = call.caller
    guardian = call.guardian
    caller_monitor = call.caller_monitor
    guardian_monitor = call.monitor

    try do
      assert_receive {:completed, ^caller, {:ok, reply}}, 5_000
      assert reply.text == "loopex"
      assert_receive {:DOWN, ^caller_monitor, :process, ^caller, :normal}, 1_000
      assert Process.alive?(guardian)
      assert Fixture.alive?(Fixture.pid(fixture))
      assert File.dir?(Fixture.namespace(fixture))

      # The callback has returned and its process is gone. Only the independently
      # monitored retainer can now cause this real provider tree to be cleaned.
      Process.exit(retainer, :kill)
      assert_receive {:DOWN, ^retainer_monitor, :process, ^retainer, :killed}, 1_000
      assert_receive {:DOWN, ^guardian_monitor, :process, ^guardian, :normal}, 2_500
      Fixture.assert_gone(fixture)
      assert Fixture.canaries(fixture) == 1
      assert Fixture.count(fixture) == 1
    after
      # On assertion failure the guardian still accepts its exact Core stop request;
      # that path cleans only the invocation this detector owns.
      if Process.alive?(guardian), do: Fixture.stop(call)
      if Process.alive?(caller), do: Process.exit(caller, :kill)
      if Process.alive?(retainer), do: Process.exit(retainer, :kill)
    end
  end

  test "actual protected worker preserves the complete loopback reply and is gone before unmanaged success" do
    fixture = Fixture.new()
    request = Fixture.request()
    assert {:ok, reply} = Fixture.complete(fixture, request)
    assert reply.text == "loopex"
    assert reply.usage == %{input_tokens: 4, output_tokens: 2}
    assert reply.provider_response_id == "req-fixture-001"
    assert reply.canonical_request_bytes == request.canonical_request_bytes
    assert reply.staged_request_digest == request.staged_request_digest
    assert reply.streamed
    assert reply.delta_count > 0
    assert Fixture.canaries(fixture) == 1
    assert Fixture.methods(fixture) == ["POST"]
    assert [{_request, true}] = Fixture.events(fixture)
    Fixture.assert_gone(fixture)
  end

  test "protected entry prevents workspace dotenv and development activation before dependency startup" do
    fixture = Fixture.new(:dotenv)
    before = {Application.get_all_env(:req_llm), Application.get_all_env(:llm_db)}
    assert {:ok, _reply} = Fixture.complete(fixture)

    assert Jason.decode!(File.read!(Fixture.marker(fixture, "startup"))) == %{
             "dotenv_absent" => true,
             "tidewave_absent" => true,
             "req_dotenv_disabled" => true,
             "db_dotenv_disabled" => true,
             "no_core" => true
           }

    assert {Application.get_all_env(:req_llm), Application.get_all_env(:llm_db)} == before
    Fixture.assert_gone(fixture)
  end

  test "rate limiting cannot retry one child invocation" do
    fixture = Fixture.new(:rate_limited)
    assert Fixture.complete(fixture) == {:error, {:dispatched_or_unknown, "model_call_failed"}}
    assert Fixture.canaries(fixture) == 1
    assert Fixture.count(fixture) == 1
    assert Fixture.methods(fixture) == ["POST"]
    Fixture.assert_gone(fixture)
  end

  test "child diagnostics are contained through the retained post-result window while parent diagnostics remain usable" do
    fixture = Fixture.new(:diagnostics)
    logger_before = :logger.get_primary_config()

    supervisors =
      for name <- [ReqLLM.Supervisor, ReqLLM.TaskSupervisor] do
        pid = Process.whereis(name)
        {pid, Process.info(pid, :group_leader)}
      end

    log =
      capture_log(fn ->
        output =
          capture_io(fn ->
            call = Fixture.managed(fixture)
            caller = call.caller
            assert_receive {:completed, ^caller, {:ok, _reply}}, 5_000

            assert Jason.decode!(File.read!(Fixture.marker(fixture, "io-results"))) ==
                     %{"direct" => "refused", "supervised" => "refused"}

            File.write!(Fixture.marker(fixture, "release-diagnostics"), "release")
            assert Fixture.eventually(fn -> Fixture.reached?(fixture, "delayed-diagnostics") end)
            Fixture.stop(call)
          end)

        assert output == ""
        Logger.error("parent-diagnostics-still-usable")
      end)

    refute log =~ "synthetic-entry-credential-canary"
    assert log =~ "parent-diagnostics-still-usable"
    assert :logger.get_primary_config() == logger_before

    for {pid, group_leader} <- supervisors,
        do: assert(Process.info(pid, :group_leader) == group_leader)

    assert capture_io(Process.whereis(ReqLLM.TaskSupervisor), fn ->
             task =
               Task.Supervisor.async(ReqLLM.TaskSupervisor, fn ->
                 IO.write("parent-task-usable")
               end)

             assert :ok = Task.await(task, 1_000)
           end) == "parent-task-usable"

    for {pid, group_leader} <- supervisors,
        do: assert(Process.info(pid, :group_leader) == group_leader)

    Fixture.assert_gone(fixture)
  end

  test "cleanup closes an actual unlinked child socket after its supervised task and session have ended" do
    fixture = Fixture.new(:detached_descendant)
    call = Fixture.managed(fixture)
    caller = call.caller
    assert_receive {:completed, ^caller, {:ok, _reply}}, 5_000

    assert Jason.decode!(File.read!(Fixture.marker(fixture, "detached-proof"))) ==
             %{"session_dead" => true, "task_dead" => true, "socket_alive" => true}

    assert Fixture.probe_events(fixture) == [:connected]
    Fixture.stop(call)
    assert Fixture.eventually(fn -> Fixture.probe_events(fixture) == [:connected, :closed] end)
    Fixture.assert_gone(fixture)
  end

  test "diagnostics remain refused and contained after an actual malformed dependency return" do
    fixture = Fixture.new(:diagnostics_malformed)
    logger_before = :logger.get_primary_config()

    log =
      capture_log(fn ->
        assert capture_io(fn ->
                 call = Fixture.managed(fixture)
                 caller = call.caller

                 assert_receive {:completed, ^caller,
                                 {:error, {:dispatched_or_unknown, "model_call_failed"}}},
                                5_000

                 assert Jason.decode!(File.read!(Fixture.marker(fixture, "io-results"))) ==
                          %{"direct" => "refused", "supervised" => "refused"}

                 assert Process.alive?(call.guardian)
                 assert Fixture.alive?(Fixture.pid(fixture))
                 File.write!(Fixture.marker(fixture, "release-diagnostics"), "release")

                 assert Fixture.eventually(fn ->
                          Fixture.reached?(fixture, "delayed-diagnostics")
                        end)

                 Fixture.stop(call)
               end) == ""

        Logger.error("parent-after-malformed-return")
      end)

    refute log =~ "synthetic-entry-credential-canary"
    assert log =~ "parent-after-malformed-return"
    assert :logger.get_primary_config() == logger_before
    assert Fixture.canaries(fixture) == 1
    assert Fixture.count(fixture) == 0
    Fixture.assert_gone(fixture)
  end

  test "unmanaged malformed return closes the detached real socket before returning" do
    fixture = Fixture.new(:detached_descendant_malformed)
    assert Fixture.complete(fixture) == {:error, {:dispatched_or_unknown, "model_call_failed"}}

    assert Jason.decode!(File.read!(Fixture.marker(fixture, "detached-proof"))) ==
             %{"session_dead" => true, "task_dead" => true, "socket_alive" => true}

    assert Fixture.eventually(fn -> Fixture.probe_events(fixture) == [:connected, :closed] end)
    Fixture.assert_gone(fixture)
    assert Fixture.canaries(fixture) == 1
    assert Fixture.count(fixture) == 0
  end

  test "caller death closes the real transport after its dependency-owned HTTP task is unlinked" do
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
    assert [{_request, true}] = Fixture.events(fixture)
    refute_receive {:completed, ^caller, _result}, 0
  end

  test "caller loss before the actual request adapter returns stops pre-HTTP work" do
    fixture = Fixture.new(:hold_before_return)
    call = Fixture.managed(fixture, Fixture.request(), :unmanaged)
    caller = call.caller
    guardian = call.guardian

    assert Fixture.eventually(fn -> Fixture.reached?(fixture, "pre-return-proof") end)

    assert Jason.decode!(File.read!(Fixture.marker(fixture, "pre-return-proof"))) ==
             %{"stream_server_alive" => true, "local_group_leader" => true}

    assert Fixture.canaries(fixture) == 1
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

  for extra <- [:duplicate_invocation, :unknown_byte] do
    @extra extra
    test "actual worker refuses #{@extra} after its one accepted invocation without redispatch" do
      fixture = Fixture.new(:blocked, paused: true)
      request = Fixture.request()
      call = Fixture.managed(fixture, request)
      guardian = call.guardian
      caller = call.caller
      :erlang.trace(guardian, true, [:receive, {:tracer, self()}])
      send(caller, :continue)

      assert_receive {:trace, ^guardian, :receive,
                      {:provider_frame, _receiver, {:ok, :dispatch_started, binding}}},
                     5_000

      assert Fixture.eventually(fn -> Fixture.count(fixture) == 1 end)
      {:links, links} = Process.info(guardian, :links)
      [socket] = Enum.filter(links, &data_socket?/1)

      case @extra do
        :duplicate_invocation ->
          assert :ok =
                   ProviderCodec.send(socket, :invocation, %{
                     "nonce" => binding["nonce"],
                     "request" =>
                       Map.drop(request, [:canonical_request_bytes, :staged_request_digest]),
                     "canonical_request_bytes" => request.canonical_request_bytes,
                     "staged_request_digest" => request.staged_request_digest
                   })

        :unknown_byte ->
          assert :ok = :gen_tcp.send(socket, <<255>>)
      end

      assert_receive {:completed, ^caller,
                      {:error, {:dispatched_or_unknown, "model_call_failed"}}},
                     5_000

      Fixture.stop(call)
      Fixture.assert_gone(fixture)
      assert Fixture.canaries(fixture) == 1
      assert Fixture.count(fixture) == 1
    end
  end

  defp data_socket?(port) when is_port(port) do
    match?({:ok, [send_timeout: :infinity]}, :inet.getopts(port, [:send_timeout]))
  catch
    _, _ -> false
  end

  defp data_socket?(_process), do: false

  test "queued actual terminal before retainer death cannot strand the cleanup owner" do
    fixture = Fixture.new(:hold_before_error, paused: true)
    {retainer, retainer_monitor} = spawn_monitor(fn -> receive do: (:stop -> :ok) end)
    call = Fixture.managed(fixture, Fixture.request(), retainer)
    guardian = call.guardian
    caller = call.caller
    :erlang.trace(guardian, true, [:receive, {:tracer, self()}])
    send(caller, :continue)

    assert_receive {:trace, ^guardian, :receive,
                    {:provider_frame, _, {:ok, :dispatch_started, _}}},
                   5_000

    assert :erlang.suspend_process(guardian)
    Fixture.release(fixture)
    terminal = queued_message(guardian, &match?({:provider_frame, _, {:ok, :terminal, _}}, &1))
    Process.exit(retainer, :kill)
    assert_receive {:DOWN, ^retainer_monitor, :process, ^retainer, :killed}, 1_000
    down = queued_message(guardian, &match?({:DOWN, _, :process, ^retainer, :killed}, &1))
    {:messages, messages} = Process.info(guardian, :messages)
    assert Enum.find_index(messages, &(&1 == terminal)) < Enum.find_index(messages, &(&1 == down))
    assert :erlang.resume_process(guardian)
    monitor = call.monitor
    assert_receive {:DOWN, ^monitor, :process, ^guardian, :normal}, 2_500

    assert_receive {:completed, ^caller, {:error, {:dispatched_or_unknown, "model_call_failed"}}},
                   1_000

    Fixture.assert_gone(fixture)
    assert Fixture.count(fixture) == 1
  end

  test "an actual unmanaged result waits through blocked cleanup until guard cessation proof" do
    fixture = Fixture.new(:hold_before_error, paused: true)
    call = Fixture.managed(fixture, Fixture.request(), :unmanaged)
    guardian = call.guardian
    caller = call.caller
    :erlang.trace(guardian, true, [:receive, {:tracer, self()}])
    send(caller, :continue)

    assert_receive {:trace, ^guardian, :receive,
                    {:provider_frame, _, {:ok, :dispatch_started, _}}},
                   5_000

    assert :erlang.suspend_process(guardian)
    Fixture.release(fixture)
    queued_message(guardian, &match?({:provider_frame, _, {:ok, :terminal, _}}, &1))
    pid = Fixture.pid(fixture)
    assert {_output, 0} = System.cmd("/bin/kill", ["-STOP", Integer.to_string(pid)])

    try do
      assert :erlang.resume_process(guardian)

      assert Fixture.eventually(
               fn -> {:status, :waiting} == Process.info(caller, :status) end,
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

    Fixture.assert_gone(fixture)
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
end
