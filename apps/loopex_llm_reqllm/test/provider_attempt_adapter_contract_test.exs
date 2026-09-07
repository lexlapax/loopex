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
          {:provider_attempt_canary_return, response} -> response
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
  alias Loopex.LLM.ReqLLM.CredentialFilter
  alias Loopex.Model
  alias Loopex.Runtime.ProviderLifetime

  test "one durable model attempt invokes the provider transport exactly once" do
    variable = Adapter.credential_variable()
    previous_credential = System.get_env(variable)
    previous_adapter = Application.get_env(:req_llm, :finch_request_adapter)
    previous_observer = Application.get_env(:loopex_llm_reqllm, :provider_attempt_canary_observer)
    previous_port = Application.get_env(:loopex_llm_reqllm, :provider_attempt_closed_port)
    previous_mode = Application.get_env(:loopex_llm_reqllm, :provider_attempt_canary_mode)
    {rate_limited_server, rate_limited_port} = start_rate_limited_server()

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

      assert snapshot_rate_limited_server(rate_limited_server) == 1
    after
      stop_fixture_server(rate_limited_server)
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

  test "a managed adapter result precedes its retained resource stop acknowledgement" do
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
      System.put_env(variable, "credential-shaped-canary-secret")

      {:ok, request} =
        Model.request(
          Adapter.default_model(),
          [%{"role" => "user", "content" => "managed adapter lifetime"}],
          sampling: %{"max_tokens" => 1},
          deadline: System.system_time(:millisecond) + 2_000
        )

      observer = self()

      {caller, caller_monitor} =
        spawn_monitor(fn ->
          result =
            ProviderLifetime.scoped(
              fn resource, stop_reference ->
                send(observer, {:managed_adapter_resource, resource, stop_reference})
                {:managed, observer}
              end,
              fn -> Adapter.complete(request, [], Model.discard_progress()) end
            )

          send(observer, {:managed_adapter_result, self(), result})
        end)

      assert_receive {:managed_adapter_resource, resource, stop_reference}, 5_000
      resource_monitor = Process.monitor(resource)

      try do
        assert_receive {:provider_transport_canary, _worker, "POST", _provider_host}, 5_000

        assert_receive {:managed_adapter_result, ^caller,
                        {:error, {:dispatched_or_unknown, "model_call_failed"}}},
                       5_000

        assert Process.alive?(resource), "the managed adapter resource exited before release"
        assert_receive {:DOWN, ^caller_monitor, :process, ^caller, :normal}, 5_000

        credential_registry = Process.whereis(Loopex.LLM.ReqLLM.CredentialFilter.Registry)
        assert is_pid(credential_registry)
        assert 1 = :erlang.trace(resource, true, [:send])

        stop = make_ref()
        send(resource, {:loopex_provider_resource_stop, stop_reference, stop, self()})

        assert_receive {:trace, ^resource, :send, first_stop_message, first_stop_destination},
                       5_000

        assert {true, true} ==
                 {
                   match?({:"$gen_call", _from, {:release, _lease}}, first_stop_message),
                   first_stop_destination == credential_registry
                 }

        assert_receive {:trace, ^resource, :send,
                        {:loopex_provider_resource_stopped, ^stop, ^resource}, stop_destination},
                       5_000

        assert stop_destination == self()
        assert_receive {:loopex_provider_resource_stopped, ^stop, ^resource}, 5_000

        assert :ignore ==
                 CredentialFilter.filter(
                   %{msg: {:string, "credential filter is idle"}},
                   :loopex_req_llm_v3
                 )

        assert_receive {:DOWN, ^resource_monitor, :process, ^resource, :normal}, 5_000
      after
        if Process.alive?(caller), do: Process.exit(caller, :kill)
        if Process.alive?(resource), do: Process.exit(resource, :kill)
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

  test "retaining owner loss after a managed result releases the credential lease" do
    assert_retaining_owner_loss(:after_result)
  end

  test "retaining owner loss during a managed call stops transport and releases the credential lease" do
    assert_retaining_owner_loss(:during_call)
  end

  test "retaining owner loss during descendant cleanup releases the credential lease" do
    assert_retaining_owner_loss(:during_cleanup)
  end

  defp assert_retaining_owner_loss(phase) do
    variable = Adapter.credential_variable()
    previous_credential = System.get_env(variable)

    configuration = [
      {:req_llm, :finch_request_adapter, Loopex.LLM.ReqLLM.ProviderAttemptCanaryAdapter},
      {:loopex_llm_reqllm, :provider_attempt_canary_observer, self()},
      {:loopex_llm_reqllm, :provider_attempt_closed_port, reserve_closed_port()},
      {:loopex_llm_reqllm, :provider_attempt_canary_mode,
       if(phase == :after_result, do: :closed_port, else: :hold_before_return)}
    ]

    previous =
      Enum.map(configuration, fn {app, key, value} ->
        old = Application.get_env(app, key)
        Application.put_env(app, key, value)
        {app, key, old}
      end)

    {retainer, retainer_monitor} =
      spawn_monitor(fn ->
        receive do
          :finish_retainer -> :ok
        end
      end)

    observer = self()

    try do
      System.put_env(variable, "credential-shaped-canary-secret")

      {:ok, request} =
        Model.request(
          Adapter.default_model(),
          [%{"role" => "user", "content" => "retaining owner loss"}],
          sampling: %{"max_tokens" => 1},
          deadline: System.system_time(:millisecond) + 10_000
        )

      {caller, caller_monitor} =
        spawn_monitor(fn ->
          result =
            ProviderLifetime.scoped(
              fn resource, stop_reference ->
                send(observer, {:orphan_check_resource, self(), resource, stop_reference})
                {:managed, retainer}
              end,
              fn -> Adapter.complete(request, [], Model.discard_progress()) end
            )

          send(observer, {:orphan_check_result, self(), result})
        end)

      assert_receive {:orphan_check_resource, ^caller, resource, _stop_reference}, 5_000
      resource_monitor = Process.monitor(resource)

      try do
        assert_receive {:provider_transport_canary, transport, "POST", _provider_host}, 5_000
        transport_monitor = Process.monitor(transport)

        if phase == :after_result do
          assert_receive {:orphan_check_result, ^caller,
                          {:error, {:dispatched_or_unknown, "model_call_failed"}}},
                         5_000

          assert_receive {:DOWN, ^caller_monitor, :process, ^caller, :normal}, 5_000
        end

        assert Process.alive?(resource)
        assert {:monitors, monitors} = Process.info(resource, :monitors)
        assert {:process, retainer} in monitors

        refute :ignore ==
                 CredentialFilter.filter(
                   %{msg: {:string, "credential-shaped-canary-secret"}},
                   :loopex_req_llm_v3
                 )

        outcome =
          if phase == :during_cleanup do
            # Establish the result-before-death ordering in the real guardian's
            # mailbox. Cleanup must not consume the only evidence of retainer
            # death and then enter its post-result wait forever.
            assert :erlang.suspend_process(resource)

            send(
              transport,
              {:provider_attempt_canary_return, {:not_a_finch_request, "api.anthropic.com"}}
            )

            await_queued_message(resource, fn message ->
              match?({Adapter, :worker_outcome, _reference, _worker, _result}, message)
            end)
          end

        Process.exit(retainer, :kill)
        assert_receive {:DOWN, ^retainer_monitor, :process, ^retainer, :killed}, 5_000

        if phase == :during_cleanup do
          down =
            await_queued_message(resource, fn message ->
              match?({:DOWN, _monitor, :process, ^retainer, :killed}, message)
            end)

          assert {:messages, messages} = Process.info(resource, :messages)

          assert Enum.find_index(messages, &(&1 == outcome)) <
                   Enum.find_index(messages, &(&1 == down))

          assert :erlang.resume_process(resource)
        end

        assert_receive {:DOWN, ^resource_monitor, :process, ^resource, :normal}, 5_000
        assert_receive {:DOWN, ^transport_monitor, :process, ^transport, _reason}, 5_000

        assert :ignore ==
                 CredentialFilter.filter(
                   %{msg: {:string, "host logging after provider owner loss"}},
                   :loopex_req_llm_v3
                 )

        if phase != :after_result do
          assert_receive {:orphan_check_result, ^caller,
                          {:error, {:dispatched_or_unknown, "model_call_failed"}}},
                         5_000

          assert_receive {:DOWN, ^caller_monitor, :process, ^caller, :normal}, 5_000
        end
      after
        if Process.alive?(caller), do: Process.exit(caller, :kill)
        if Process.alive?(resource), do: Process.exit(resource, :kill)
      end
    after
      if Process.alive?(retainer), do: Process.exit(retainer, :kill)
      restore_env(variable, previous_credential)

      Enum.each(previous, fn {app, key, value} ->
        restore_application_env(app, key, value)
      end)
    end
  end

  defp await_queued_message(process, matches) do
    await_queued_message(process, matches, System.monotonic_time(:millisecond) + 5_000)
  end

  defp await_queued_message(process, matches, deadline) do
    assert {:messages, messages} = Process.info(process, :messages)

    case Enum.find(messages, matches) do
      nil ->
        assert System.monotonic_time(:millisecond) < deadline,
               "the suspended guardian did not receive the required ordering message"

        Process.sleep(1)
        await_queued_message(process, matches, deadline)

      message ->
        message
    end
  end

  test "an unmanaged adapter result follows guardian credential cleanup" do
    variable = Adapter.credential_variable()
    previous_credential = System.get_env(variable)
    previous_adapter = Application.get_env(:req_llm, :finch_request_adapter)
    previous_observer = Application.get_env(:loopex_llm_reqllm, :provider_attempt_canary_observer)
    previous_port = Application.get_env(:loopex_llm_reqllm, :provider_attempt_closed_port)
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

      {:ok, request} =
        Model.request(
          Adapter.default_model(),
          [%{"role" => "user", "content" => "unmanaged adapter lifetime"}],
          sampling: %{"max_tokens" => 1},
          deadline: System.system_time(:millisecond) + 5_000
        )

      observer = self()

      {caller, caller_monitor} =
        spawn_monitor(fn ->
          result = Adapter.complete(request, [], Model.discard_progress())
          send(observer, {:unmanaged_adapter_result, self(), result})
        end)

      assert_receive {:provider_transport_canary, worker, "POST", provider_host}, 5_000
      guardian = caller |> monitored_processes() |> exactly_one_process!()
      guardian_monitor = Process.monitor(guardian)
      credential_registry = Process.whereis(Loopex.LLM.ReqLLM.CredentialFilter.Registry)
      assert is_pid(credential_registry)
      assert 1 = :erlang.trace(caller, true, [:receive])
      assert 1 = :erlang.trace(guardian, true, [:send])
      :ok = :sys.suspend(credential_registry)

      try do
        send(worker, {:provider_attempt_canary_return, {:not_a_finch_request, provider_host}})

        assert_receive {:trace, ^guardian, :send,
                        {Adapter, ^guardian, adapter_reference, adapter_outcome}, ^caller},
                       5_000

        assert is_reference(adapter_reference)
        assert adapter_outcome == :provider_call_failed

        assert_receive {:trace, ^guardian, :send, {:"$gen_call", _from, {:release, _lease}},
                        ^credential_registry},
                       5_000

        assert_receive {:trace, ^caller, :receive,
                        {Adapter, ^guardian, ^adapter_reference, ^adapter_outcome}},
                       5_000

        assert_caller_waiting_for_guardian(
          caller,
          caller_monitor,
          System.monotonic_time(:millisecond) + 500
        )

        :ok = :sys.resume(credential_registry)

        assert_receive {:DOWN, ^guardian_monitor, :process, ^guardian, :normal}, 5_000

        assert_receive {:unmanaged_adapter_result, ^caller,
                        {:error, {:dispatched_or_unknown, "model_call_failed"}}},
                       5_000

        assert_receive {:DOWN, ^caller_monitor, :process, ^caller, :normal}, 5_000
      after
        resume_if_suspended(credential_registry)
        if Process.alive?(caller), do: Process.exit(caller, :kill)
        if Process.alive?(guardian), do: Process.exit(guardian, :kill)
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

  defp start_rate_limited_server do
    caller = self()

    server =
      spawn(fn ->
        {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
        {:ok, {_address, port}} = :inet.sockname(listener)
        controller = self()

        {acceptor, acceptor_monitor} =
          spawn_monitor(fn -> serve_rate_limits(listener, controller) end)

        send(caller, {:rate_limited_server, self(), port})
        control_rate_limited_server(listener, acceptor, acceptor_monitor, 0)
      end)

    monitor = Process.monitor(server)

    receive do
      {:rate_limited_server, ^server, port} ->
        Process.demonitor(monitor, [:flush])
        {server, port}

      {:DOWN, ^monitor, :process, ^server, reason} ->
        flunk("the rate-limit fixture exited before startup: #{inspect(reason)}")
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

  defp assert_caller_waiting_for_guardian(caller, caller_monitor, deadline) do
    receive do
      {:unmanaged_adapter_result, ^caller, result} ->
        flunk("the unmanaged adapter returned before guardian cleanup: #{inspect(result)}")

      {:DOWN, ^caller_monitor, :process, ^caller, reason} ->
        flunk("the unmanaged adapter caller exited before guardian cleanup: #{inspect(reason)}")
    after
      0 ->
        case {
          Process.info(caller, :status),
          Process.info(caller, :message_queue_len)
        } do
          {{:status, :waiting}, {:message_queue_len, 0}} ->
            :ok

          {nil, nil} ->
            flunk("the unmanaged adapter caller exited before guardian cleanup")

          state ->
            if System.monotonic_time(:millisecond) < deadline do
              Process.sleep(1)
              assert_caller_waiting_for_guardian(caller, caller_monitor, deadline)
            else
              flunk(
                "the unmanaged adapter caller did not settle at its cleanup barrier: #{inspect(state)}"
              )
            end
        end
    end
  end

  defp resume_if_suspended(process) do
    :sys.resume(process)
  catch
    :exit, _reason -> :ok
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

  defp serve_rate_limits(listener, controller) do
    # The request's own deadline bounds this interaction. A fixture-local accept
    # timer starts before catalog resolution and guardian setup, so it can close
    # a healthy listener before the adapter has had a chance to connect.
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        _request = :gen_tcp.recv(socket, 0, 1_000)
        send(controller, {:rate_limited_attempt, self()})

        :ok =
          :gen_tcp.send(
            socket,
            "HTTP/1.1 429 Too Many Requests\r\nretry-after: 0\r\ncontent-length: 0\r\nconnection: close\r\n\r\n"
          )

        :gen_tcp.close(socket)
        serve_rate_limits(listener, controller)

      {:error, :closed} ->
        :ok

      {:error, reason} ->
        exit({:rate_limited_accept_failed, reason})
    end
  end

  defp control_rate_limited_server(listener, acceptor, acceptor_monitor, attempts) do
    receive do
      {:rate_limited_attempt, ^acceptor} ->
        control_rate_limited_server(listener, acceptor, acceptor_monitor, attempts + 1)

      {:snapshot_and_stop_rate_limited_server, requester, reference}
      when is_pid(requester) and is_reference(reference) ->
        :ok = :gen_tcp.close(listener)

        await_rate_limited_acceptor(
          acceptor,
          acceptor_monitor,
          attempts,
          requester,
          reference
        )

      {:DOWN, ^acceptor_monitor, :process, ^acceptor, reason} ->
        exit({:rate_limited_acceptor_exited, reason})
    end
  end

  defp await_rate_limited_acceptor(
         acceptor,
         acceptor_monitor,
         attempts,
         requester,
         reference
       ) do
    receive do
      {:rate_limited_attempt, ^acceptor} ->
        await_rate_limited_acceptor(
          acceptor,
          acceptor_monitor,
          attempts + 1,
          requester,
          reference
        )

      {:DOWN, ^acceptor_monitor, :process, ^acceptor, :normal} ->
        send(requester, {:rate_limited_server_stopped, reference, self(), attempts})

      {:DOWN, ^acceptor_monitor, :process, ^acceptor, reason} ->
        exit({:rate_limited_acceptor_exited, reason})
    end
  end

  defp snapshot_rate_limited_server(server) when is_pid(server) do
    reference = make_ref()
    monitor = Process.monitor(server)
    send(server, {:snapshot_and_stop_rate_limited_server, self(), reference})

    receive do
      {:rate_limited_server_stopped, ^reference, ^server, attempts} ->
        Process.demonitor(monitor, [:flush])
        attempts

      {:DOWN, ^monitor, :process, ^server, reason} ->
        flunk("the rate-limit fixture exited before its snapshot: #{inspect(reason)}")
    after
      5_000 -> flunk("the rate-limit fixture did not stop after its snapshot")
    end
  end

  defp stop_fixture_server(server) when is_pid(server) do
    monitor = Process.monitor(server)
    Process.exit(server, :kill)

    receive do
      {:DOWN, ^monitor, :process, ^server, _reason} -> :ok
    after
      1_000 -> flunk("the rate-limit fixture did not stop")
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
