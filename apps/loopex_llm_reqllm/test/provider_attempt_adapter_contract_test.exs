defmodule Loopex.LLM.ReqLLM.ProviderAttemptCanaryAdapter do
  @moduledoc false

  @behaviour ReqLLM.FinchRequestAdapter

  @impl ReqLLM.FinchRequestAdapter
  def call(%Finch.Request{} = request) do
    observer = Application.fetch_env!(:loopex_llm_reqllm, :provider_attempt_canary_observer)
    send(observer, {:provider_transport_canary, self(), request.method, request.host})

    mode = Application.fetch_env!(:loopex_llm_reqllm, :provider_attempt_canary_mode)

    if mode == :capture_closed_port do
      body = ReqLLM.Streaming.Fixtures.canonical_json_from_finch_request(request)
      send(observer, {:provider_transport_body, self(), body})
    end

    case mode do
      mode
      when mode in [
             :closed_port,
             :capture_closed_port,
             :rate_limited,
             :http_error,
             :malformed_response,
             :incomplete_stream,
             :blocked,
             :timeout
           ] ->
        port = Application.fetch_env!(:loopex_llm_reqllm, :provider_attempt_closed_port)
        %{request | scheme: :http, host: "127.0.0.1", port: port, path: "/", query: nil}

      :raise ->
        raise "provider library raised after the transport canary"

      :throw ->
        throw(:provider_library_threw_after_canary)

      :exit ->
        exit(:provider_library_exited_after_canary)

      :hold_before_return ->
        receive do
          :provider_attempt_canary_never_returns -> request
        end

      :io_then_malformed ->
        result =
          try do
            IO.write("credential-shaped-provider-io")
            :written
          rescue
            ArgumentError -> :refused
          end

        send(observer, {:provider_io_result, result})
        {:not_a_finch_request, request.host}

      :detached_descendant ->
        task =
          Task.Supervisor.async(ReqLLM.TaskSupervisor, fn ->
            owner = self()

            session =
              spawn_link(fn ->
                socket =
                  spawn(fn ->
                    receive do
                      :provider_detached_socket_never_stops -> :unreachable
                    end
                  end)

                send(observer, {:provider_private_chain, self(), socket})

                receive do
                  :finish_provider_private_session -> :ok
                end
              end)

            session_monitor = Process.monitor(session)
            send(observer, {:provider_private_task, owner})
            send(session, :finish_provider_private_session)

            receive do
              {:DOWN, ^session_monitor, :process, ^session, :normal} -> :ok
            end
          end)

        :ok = Task.await(task, 1_000)
        {:not_a_finch_request, request.host}

      :malformed_return ->
        {:not_a_finch_request, request.host}

      :tagged_not_dispatched ->
        {:error, {:not_dispatched, "model_call_failed"}}
    end
  end
end

defmodule Loopex.LLM.ReqLLM.ProviderAttemptAdapterContractTest do
  @moduledoc false

  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Loopex.LLM.ReqLLM, as: Adapter
  alias Loopex.Model

  test "one durable model attempt invokes the provider transport exactly once" do
    variable = Adapter.credential_variable()
    previous_credential = System.get_env(variable)
    previous_adapter = Application.get_env(:req_llm, :finch_request_adapter)
    previous_observer = Application.get_env(:loopex_llm_reqllm, :provider_attempt_canary_observer)
    previous_port = Application.get_env(:loopex_llm_reqllm, :provider_attempt_closed_port)
    previous_mode = Application.get_env(:loopex_llm_reqllm, :provider_attempt_canary_mode)
    rate_limited_port = start_rate_limited_server(self())

    Application.put_env(
      :req_llm,
      :finch_request_adapter,
      Loopex.LLM.ReqLLM.ProviderAttemptCanaryAdapter
    )

    Application.put_env(:loopex_llm_reqllm, :provider_attempt_canary_observer, self())
    Application.put_env(:loopex_llm_reqllm, :provider_attempt_closed_port, rate_limited_port)
    Application.put_env(:loopex_llm_reqllm, :provider_attempt_canary_mode, :rate_limited)

    try do
      System.put_env(variable, "credential-shaped-canary-secret")

      {:ok, request} =
        Model.request(
          Adapter.default_model(),
          [%{"role" => "user", "content" => "one transport only"}],
          sampling: %{"max_tokens" => 1},
          deadline: System.system_time(:millisecond) + 10_000
        )

      assert Adapter.complete(request, [], Model.discard_progress()) ==
               {:error, {:dispatched_or_unknown, "model_call_failed"}}

      assert_receive {:provider_transport_attempt, _worker}, 5_000
      refute_receive {:provider_transport_attempt, _worker}, 0
    after
      restore_env(variable, previous_credential)
      restore_application_env(:req_llm, :finch_request_adapter, previous_adapter)

      restore_application_env(
        :loopex_llm_reqllm,
        :provider_attempt_canary_observer,
        previous_observer
      )

      restore_application_env(
        :loopex_llm_reqllm,
        :provider_attempt_closed_port,
        previous_port
      )

      restore_application_env(
        :loopex_llm_reqllm,
        :provider_attempt_canary_mode,
        previous_mode
      )
    end
  end

  # Concept: cancelling the process that called the shipped adapter cancels the
  # provider work it owns rather than leaving a detached request behind.
  #
  # Technical depth: `complete/3` deliberately isolates provider-library exits
  # from its caller. That isolation must still carry lifetime ownership in the
  # other direction. ReqLLM starts the StreamServer below this adapter but starts
  # the HTTP task under a shared TaskSupervisor and links it afterwards. The case
  # severs that dependency-owned link after the guardian had to observe it, so a
  # cleanup implementation that owns only spawned descendants deterministically
  # leaves the transport task and socket alive.
  test "caller death stops the shipped adapter transport worker" do
    variable = Adapter.credential_variable()
    previous_credential = System.get_env(variable)
    previous_adapter = Application.get_env(:req_llm, :finch_request_adapter)
    previous_observer = Application.get_env(:loopex_llm_reqllm, :provider_attempt_canary_observer)
    previous_port = Application.get_env(:loopex_llm_reqllm, :provider_attempt_closed_port)
    previous_mode = Application.get_env(:loopex_llm_reqllm, :provider_attempt_canary_mode)
    blocked_port = start_blocked_transport_server(self())

    Application.put_env(
      :req_llm,
      :finch_request_adapter,
      Loopex.LLM.ReqLLM.ProviderAttemptCanaryAdapter
    )

    Application.put_env(:loopex_llm_reqllm, :provider_attempt_canary_observer, self())
    Application.put_env(:loopex_llm_reqllm, :provider_attempt_closed_port, blocked_port)
    Application.put_env(:loopex_llm_reqllm, :provider_attempt_canary_mode, :blocked)

    try do
      System.put_env(variable, "credential-shaped-canary-secret")
      observer = self()

      caller =
        spawn(fn ->
          {:ok, request} =
            Model.request(
              Adapter.default_model(),
              [%{"role" => "user", "content" => "block in provider transport"}],
              sampling: %{"max_tokens" => 1},
              deadline: System.system_time(:millisecond) + 10_000
            )

          send(
            observer,
            {:provider_caller_result, Adapter.complete(request, [], Model.discard_progress())}
          )
        end)

      caller_monitor = Process.monitor(caller)

      assert_receive {:provider_transport_canary, stream_server, "POST", _provider_host}, 5_000
      assert_receive :provider_transport_connected, 5_000

      stream_state = :sys.get_state(stream_server)
      http_task = stream_state.http_task
      assert is_pid(http_task)
      refute http_task == stream_server

      assert {:initial_call, {Task.Supervised, _function, _arity}} =
               Process.info(http_task, :initial_call)

      # Run inside StreamServer so the link between the two dependency-owned
      # processes, rather than a link involving this test, is the one removed.
      :sys.replace_state(stream_server, fn state ->
        true = Process.unlink(state.http_task)
        state
      end)

      guardian = caller |> monitored_processes() |> exactly_one_process!()
      guardian_monitor = Process.monitor(guardian)
      stream_server_monitor = Process.monitor(stream_server)
      http_task_monitor = Process.monitor(http_task)
      Process.exit(caller, :kill)

      assert_receive {:DOWN, ^caller_monitor, :process, ^caller, :killed}, 5_000

      assert_receive {:DOWN, ^guardian_monitor, :process, ^guardian, :normal}, 1_000
      refute Process.alive?(stream_server)
      refute Process.alive?(http_task)

      assert_receive {:DOWN, ^stream_server_monitor, :process, ^stream_server, _reason}, 1_000
      assert_receive {:DOWN, ^http_task_monitor, :process, ^http_task, _reason}, 1_000
      assert_receive :provider_transport_closed, 1_000
      refute_receive {:provider_caller_result, _result}, 0
    after
      restore_env(variable, previous_credential)
      restore_application_env(:req_llm, :finch_request_adapter, previous_adapter)

      restore_application_env(
        :loopex_llm_reqllm,
        :provider_attempt_canary_observer,
        previous_observer
      )

      restore_application_env(
        :loopex_llm_reqllm,
        :provider_attempt_closed_port,
        previous_port
      )

      restore_application_env(
        :loopex_llm_reqllm,
        :provider_attempt_canary_mode,
        previous_mode
      )
    end
  end

  test "provider direct IO is refused locally instead of leaking or blocking" do
    variable = Adapter.credential_variable()
    previous_credential = System.get_env(variable)
    previous_adapter = Application.get_env(:req_llm, :finch_request_adapter)
    previous_observer = Application.get_env(:loopex_llm_reqllm, :provider_attempt_canary_observer)
    previous_mode = Application.get_env(:loopex_llm_reqllm, :provider_attempt_canary_mode)

    Application.put_env(
      :req_llm,
      :finch_request_adapter,
      Loopex.LLM.ReqLLM.ProviderAttemptCanaryAdapter
    )

    Application.put_env(:loopex_llm_reqllm, :provider_attempt_canary_observer, self())
    Application.put_env(:loopex_llm_reqllm, :provider_attempt_canary_mode, :io_then_malformed)

    try do
      System.put_env(variable, "credential-shaped-canary-secret")
      observer = self()

      {:ok, request} =
        Model.request(
          Adapter.default_model(),
          [%{"role" => "user", "content" => "provider direct io"}],
          sampling: %{"max_tokens" => 1},
          deadline: System.system_time(:millisecond) + 10_000
        )

      output =
        capture_io(fn ->
          assert Adapter.complete(request, [], Model.discard_progress()) ==
                   {:error, {:dispatched_or_unknown, "model_call_failed"}}

          task =
            Task.Supervisor.async(ReqLLM.TaskSupervisor, fn ->
              try do
                IO.write("credential-shaped-provider-task-io")
                :written
              rescue
                ArgumentError -> :refused
              end
            end)

          send(observer, {:provider_supervised_io_result, Task.await(task, 1_000)})
        end)

      assert output == ""
      assert_receive {:provider_io_result, :refused}, 1_000
      assert_receive {:provider_supervised_io_result, :refused}, 1_000
    after
      restore_env(variable, previous_credential)
      restore_application_env(:req_llm, :finch_request_adapter, previous_adapter)

      restore_application_env(
        :loopex_llm_reqllm,
        :provider_attempt_canary_observer,
        previous_observer
      )

      restore_application_env(
        :loopex_llm_reqllm,
        :provider_attempt_canary_mode,
        previous_mode
      )
    end
  end

  test "provider cleanup owns an unlinked socket below an externally supervised task" do
    variable = Adapter.credential_variable()
    previous_credential = System.get_env(variable)
    previous_adapter = Application.get_env(:req_llm, :finch_request_adapter)
    previous_observer = Application.get_env(:loopex_llm_reqllm, :provider_attempt_canary_observer)
    previous_mode = Application.get_env(:loopex_llm_reqllm, :provider_attempt_canary_mode)

    Application.put_env(
      :req_llm,
      :finch_request_adapter,
      Loopex.LLM.ReqLLM.ProviderAttemptCanaryAdapter
    )

    Application.put_env(:loopex_llm_reqllm, :provider_attempt_canary_observer, self())
    Application.put_env(:loopex_llm_reqllm, :provider_attempt_canary_mode, :detached_descendant)

    try do
      System.put_env(variable, "credential-shaped-canary-secret")
      task_supervisor = Process.whereis(ReqLLM.TaskSupervisor)
      assert is_pid(task_supervisor)
      assert {:tracer, []} = :erlang.trace_info(task_supervisor, :tracer)

      {:ok, request} =
        Model.request(
          Adapter.default_model(),
          [%{"role" => "user", "content" => "own the complete private transport tree"}],
          sampling: %{"max_tokens" => 1},
          deadline: System.system_time(:millisecond) + 10_000
        )

      assert Adapter.complete(request, [], Model.discard_progress()) ==
               {:error, {:dispatched_or_unknown, "model_call_failed"}}

      assert_receive {:provider_private_task, task}, 1_000
      assert_receive {:provider_private_chain, session, socket}, 1_000

      on_exit(fn ->
        for process <- [task, session, socket], Process.alive?(process) do
          Process.exit(process, :kill)
        end
      end)

      task_monitor = Process.monitor(task)
      session_monitor = Process.monitor(session)
      socket_monitor = Process.monitor(socket)

      assert_receive {:DOWN, ^task_monitor, :process, ^task, _reason}, 1_000
      assert_receive {:DOWN, ^session_monitor, :process, ^session, _reason}, 1_000
      assert_receive {:DOWN, ^socket_monitor, :process, ^socket, _reason}, 1_000
      refute Process.alive?(socket)
      assert Process.alive?(task_supervisor)
      assert {:tracer, []} = :erlang.trace_info(task_supervisor, :tracer)
    after
      restore_env(variable, previous_credential)
      restore_application_env(:req_llm, :finch_request_adapter, previous_adapter)

      restore_application_env(
        :loopex_llm_reqllm,
        :provider_attempt_canary_observer,
        previous_observer
      )

      restore_application_env(
        :loopex_llm_reqllm,
        :provider_attempt_canary_mode,
        previous_mode
      )
    end
  end

  test "caller death stops the stream server before the request adapter returns" do
    variable = Adapter.credential_variable()
    previous_credential = System.get_env(variable)
    previous_adapter = Application.get_env(:req_llm, :finch_request_adapter)
    previous_observer = Application.get_env(:loopex_llm_reqllm, :provider_attempt_canary_observer)
    previous_mode = Application.get_env(:loopex_llm_reqllm, :provider_attempt_canary_mode)

    Application.put_env(
      :req_llm,
      :finch_request_adapter,
      Loopex.LLM.ReqLLM.ProviderAttemptCanaryAdapter
    )

    Application.put_env(:loopex_llm_reqllm, :provider_attempt_canary_observer, self())
    Application.put_env(:loopex_llm_reqllm, :provider_attempt_canary_mode, :hold_before_return)

    try do
      System.put_env(variable, "credential-shaped-canary-secret")
      observer = self()

      caller =
        spawn(fn ->
          {:ok, request} =
            Model.request(
              Adapter.default_model(),
              [%{"role" => "user", "content" => "block before provider request return"}],
              sampling: %{"max_tokens" => 1},
              deadline: System.system_time(:millisecond) + 10_000
            )

          send(
            observer,
            {:provider_caller_result, Adapter.complete(request, [], Model.discard_progress())}
          )
        end)

      caller_monitor = Process.monitor(caller)

      assert_receive {:provider_transport_canary, stream_server, "POST", _provider_host}, 5_000
      assert {:group_leader, local_leader} = Process.info(stream_server, :group_leader)
      assert node(local_leader) == node()

      stream_server_monitor = Process.monitor(stream_server)
      Process.exit(caller, :kill)

      assert_receive {:DOWN, ^caller_monitor, :process, ^caller, :killed}, 5_000

      assert_receive {:DOWN, ^stream_server_monitor, :process, ^stream_server, _reason},
                     1_000

      refute_receive {:provider_caller_result, _result}, 0
    after
      restore_env(variable, previous_credential)
      restore_application_env(:req_llm, :finch_request_adapter, previous_adapter)

      restore_application_env(
        :loopex_llm_reqllm,
        :provider_attempt_canary_observer,
        previous_observer
      )

      restore_application_env(
        :loopex_llm_reqllm,
        :provider_attempt_canary_mode,
        previous_mode
      )
    end
  end

  test "committed assistant tool history reaches OpenAI in its required function-call shape" do
    variable = Adapter.credential_variable()
    previous_credential = System.get_env(variable)
    previous_adapter = Application.get_env(:req_llm, :finch_request_adapter)
    previous_observer = Application.get_env(:loopex_llm_reqllm, :provider_attempt_canary_observer)
    previous_port = Application.get_env(:loopex_llm_reqllm, :provider_attempt_closed_port)
    previous_mode = Application.get_env(:loopex_llm_reqllm, :provider_attempt_canary_mode)
    closed_port = reserve_closed_port()

    Application.put_env(
      :req_llm,
      :finch_request_adapter,
      Loopex.LLM.ReqLLM.ProviderAttemptCanaryAdapter
    )

    Application.put_env(:loopex_llm_reqllm, :provider_attempt_canary_observer, self())
    Application.put_env(:loopex_llm_reqllm, :provider_attempt_closed_port, closed_port)
    Application.put_env(:loopex_llm_reqllm, :provider_attempt_canary_mode, :capture_closed_port)

    try do
      System.put_env(variable, "credential-shaped-canary-secret")

      {:ok, request} =
        Model.request(
          "openai:gpt-4-turbo-2024-04-09",
          [
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
            %{
              "role" => "tool",
              "tool_call_id" => "call_MiXeD_123",
              "content" => "file contents"
            }
          ],
          sampling: %{"max_tokens" => 1},
          deadline: System.system_time(:millisecond) + 10_000
        )

      assert Adapter.complete(request, [], Model.discard_progress()) ==
               {:error, {:dispatched_or_unknown, "model_call_failed"}}

      assert_receive {:provider_transport_body, _worker, body}, 5_000

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
    after
      restore_env(variable, previous_credential)
      restore_application_env(:req_llm, :finch_request_adapter, previous_adapter)

      restore_application_env(
        :loopex_llm_reqllm,
        :provider_attempt_canary_observer,
        previous_observer
      )

      restore_application_env(
        :loopex_llm_reqllm,
        :provider_attempt_closed_port,
        previous_port
      )

      restore_application_env(
        :loopex_llm_reqllm,
        :provider_attempt_canary_mode,
        previous_mode
      )
    end
  end

  test "the shipped adapter declares not_dispatched only before its transport canary and ambiguity after it" do
    variable = Adapter.credential_variable()
    previous_credential = System.get_env(variable)
    previous_adapter = Application.get_env(:req_llm, :finch_request_adapter)
    previous_observer = Application.get_env(:loopex_llm_reqllm, :provider_attempt_canary_observer)
    previous_port = Application.get_env(:loopex_llm_reqllm, :provider_attempt_closed_port)
    previous_mode = Application.get_env(:loopex_llm_reqllm, :provider_attempt_canary_mode)
    closed_port = reserve_closed_port()

    Application.put_env(
      :req_llm,
      :finch_request_adapter,
      Loopex.LLM.ReqLLM.ProviderAttemptCanaryAdapter
    )

    Application.put_env(:loopex_llm_reqllm, :provider_attempt_canary_observer, self())
    Application.put_env(:loopex_llm_reqllm, :provider_attempt_closed_port, closed_port)
    Application.put_env(:loopex_llm_reqllm, :provider_attempt_canary_mode, :closed_port)

    try do
      System.delete_env(variable)

      assert Adapter.complete(Adapter.default_model(), "never handed off") ==
               {:error, {:not_dispatched, "model_call_failed"}}

      refute_receive {:provider_transport_canary, _worker, _method, _host}, 0

      System.put_env(variable, "credential-shaped-canary-secret")

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
        port = server_port_for(mode, closed_port)
        Application.put_env(:loopex_llm_reqllm, :provider_attempt_canary_mode, mode)
        Application.put_env(:loopex_llm_reqllm, :provider_attempt_closed_port, port)

        {:ok, request} =
          Model.request(
            Adapter.default_model(),
            [%{"role" => "user", "content" => "post-canary #{mode}"}],
            sampling: %{"max_tokens" => 1},
            deadline: System.system_time(:millisecond) + 2_000
          )

        result = Adapter.complete(request, [], Model.discard_progress())
        assert_receive {:provider_transport_canary, _worker, "POST", _provider_host}, 5_000
        assert result == {:error, {:dispatched_or_unknown, "model_call_failed"}}
        refute inspect(result) =~ "credential-shaped-canary-secret"
      end
    after
      restore_env(variable, previous_credential)
      restore_application_env(:req_llm, :finch_request_adapter, previous_adapter)

      restore_application_env(
        :loopex_llm_reqllm,
        :provider_attempt_canary_observer,
        previous_observer
      )

      restore_application_env(
        :loopex_llm_reqllm,
        :provider_attempt_closed_port,
        previous_port
      )

      restore_application_env(
        :loopex_llm_reqllm,
        :provider_attempt_canary_mode,
        previous_mode
      )
    end
  end

  defp reserve_closed_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, {_address, port}} = :inet.sockname(socket)
    :ok = :gen_tcp.close(socket)
    port
  end

  defp start_rate_limited_server(observer) do
    caller = self()

    spawn_link(fn ->
      {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
      {:ok, {_address, port}} = :inet.sockname(listener)
      send(caller, {:rate_limited_port, port})
      serve_rate_limits(listener, observer)
    end)

    receive do
      {:rate_limited_port, port} -> port
    after
      5_000 -> flunk("the rate-limit fixture did not start")
    end
  end

  defp start_blocked_transport_server(observer) do
    caller = self()

    spawn_link(fn ->
      {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
      {:ok, {_address, port}} = :inet.sockname(listener)
      send(caller, {:blocked_transport_port, port})
      {:ok, socket} = :gen_tcp.accept(listener)
      :ok = :gen_tcp.close(listener)
      send(observer, :provider_transport_connected)
      await_transport_close(socket, observer, System.monotonic_time(:millisecond) + 5_000)
    end)

    receive do
      {:blocked_transport_port, port} -> port
    after
      5_000 -> flunk("the blocked transport fixture did not start")
    end
  end

  defp monitored_processes(process) do
    case Process.info(process, :monitors) do
      {:monitors, monitors} ->
        Enum.flat_map(monitors, fn
          {:process, monitored} when is_pid(monitored) -> [monitored]
          _other -> []
        end)

      nil ->
        []
    end
  end

  defp exactly_one_process!([process]), do: process

  defp exactly_one_process!(processes) do
    flunk("expected exactly one provider guardian, got: #{inspect(processes)}")
  end

  defp await_transport_close(socket, observer, deadline) do
    case :gen_tcp.recv(socket, 0, 100) do
      {:ok, _bytes} ->
        await_transport_close(socket, observer, deadline)

      {:error, :timeout} ->
        if System.monotonic_time(:millisecond) < deadline do
          await_transport_close(socket, observer, deadline)
        else
          send(observer, {:provider_transport_not_closed, :timeout})
          :gen_tcp.close(socket)
        end

      {:error, :closed} ->
        send(observer, :provider_transport_closed)

      {:error, reason} ->
        send(observer, {:provider_transport_not_closed, reason})
    end
  end

  defp serve_rate_limits(listener, observer) do
    case :gen_tcp.accept(listener, 1_000) do
      {:ok, socket} ->
        _request = :gen_tcp.recv(socket, 0, 1_000)
        send(observer, {:provider_transport_attempt, self()})

        :ok =
          :gen_tcp.send(
            socket,
            "HTTP/1.1 429 Too Many Requests\r\nretry-after: 0\r\ncontent-length: 0\r\nconnection: close\r\n\r\n"
          )

        :gen_tcp.close(socket)
        serve_rate_limits(listener, observer)

      {:error, :timeout} ->
        :gen_tcp.close(listener)
    end
  end

  defp server_port_for(:closed_port, port), do: port

  defp server_port_for(mode, _closed_port)
       when mode in [:raise, :throw, :exit, :malformed_return, :tagged_not_dispatched] do
    1
  end

  defp server_port_for(mode, _closed_port) do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, {_address, port}} = :inet.sockname(listener)

    spawn_link(fn ->
      {:ok, socket} = :gen_tcp.accept(listener)
      _request = :gen_tcp.recv(socket, 0, 2_000)

      case mode do
        :http_error ->
          :gen_tcp.send(
            socket,
            "HTTP/1.1 500 Internal Server Error\r\ncontent-length: 0\r\nconnection: close\r\n\r\n"
          )

        :malformed_response ->
          body = "{not-json"

          :gen_tcp.send(
            socket,
            "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: #{byte_size(body)}\r\nconnection: close\r\n\r\n#{body}"
          )

        :incomplete_stream ->
          body = "data: {\"type\":\"message_start\""

          :gen_tcp.send(
            socket,
            "HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\ncontent-length: #{byte_size(body)}\r\nconnection: close\r\n\r\n#{body}"
          )

        :timeout ->
          Process.sleep(2_500)
      end

      :gen_tcp.close(socket)
      :gen_tcp.close(listener)
    end)

    port
  end

  defp restore_env(variable, nil), do: System.delete_env(variable)
  defp restore_env(variable, value), do: System.put_env(variable, value)

  defp restore_application_env(application, key, nil),
    do: Application.delete_env(application, key)

  defp restore_application_env(application, key, value),
    do: Application.put_env(application, key, value)
end
