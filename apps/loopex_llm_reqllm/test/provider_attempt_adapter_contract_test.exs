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
             :http_error,
             :malformed_response,
             :incomplete_stream,
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

  alias Loopex.LLM.ReqLLM, as: Adapter
  alias Loopex.Model

  test "committed assistant tool history is normalized before provider encoding" do
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
