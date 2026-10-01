defmodule Loopex.LLM.ReqLLM.NativeTransportTest do
  use ExUnit.Case, async: false
  alias Loopex.LLM.ReqLLM.{Mapping, NativeContent, NativeTransport}
  alias Loopex.Model
  import ExUnit.CaptureLog

  @model "anthropic:claude-fable-5-1"
  @key "synthetic-native-transport-key"

  setup_all do
    {:ok, _} = Application.ensure_all_started(:req_llm)
    :ok
  end

  test "real local HTTP captures complete native blocks and preserves outgoing limits" do
    body = encode(events())
    {server, base} = server([body])
    prepared = prepared(base) |> put_in([:profile, :summary], true)
    parent = self()

    assert {:ok, built} =
             ReqLLM.Providers.Anthropic.attach_stream(
               prepared.model,
               prepared.context,
               Keyword.put(prepared.options, :api_key, @key),
               ReqLLM.Finch
             )

    assert {:ok, _, _} =
             Loopex.LLM.ReqLLM.NativeRequest.install(
               prepared.request,
               built,
               prepared.endpoint,
               @key
             ),
           inspect({Jason.decode!(built.body), built.headers, prepared.endpoint})

    assert {:ok, captured} = NativeTransport.complete(prepared, @key, &send(parent, {:delta, &1}))
    assert captured.native.usage == %{input_tokens: 11, output_tokens: 4}

    assert captured.native.content == [
             %{"type" => "thinking", "thinking" => "private thought", "signature" => "sig+/="},
             %{"type" => "text", "text" => "hello"}
           ]

    assert captured.delta_count == 1
    assert_receive {:delta, %{kind: :text_delta, text: "hello"}}
    refute_receive {:delta, _}

    assert {:ok, reply} =
             NativeContent.capture(@model, captured.native.stop_reason, captured.native.content)

    assert reply.text == "hello"
    assert reply.continuation["status"] == "closed"
    assert_receive {:request, ^server, headers, request}
    assert headers =~ "x-api-key: #{@key}"
    assert request["max_tokens"] == 8192
    refute Map.has_key?(request, "thinking")
    refute Map.has_key?(request, "output_config")
  end

  test "the worker returns a strict native reply after its dispatch handoff" do
    {server, base} = server([encode(events())])
    prepared = prepared(base)
    original = prepared.request

    {:ok, request} =
      Model.request(original.model, original.messages,
        sampling: original.sampling,
        deadline: System.system_time(:millisecond) + 10_000
      )

    prior = Application.fetch_env(:req_llm, :anthropic)
    Application.put_env(:req_llm, :anthropic, base_url: base)

    on_exit(fn ->
      case prior do
        {:ok, value} -> Application.put_env(:req_llm, :anthropic, value)
        :error -> Application.delete_env(:req_llm, :anthropic)
      end
    end)

    parent = self()

    assert {:ok, reply} =
             Loopex.LLM.ReqLLM.worker_invoke(
               request,
               @key,
               &send(parent, {:worker_delta, &1}),
               fn -> send(parent, :started) end
             )

    assert_receive :started
    assert_receive {:request, ^server, _, _}
    assert_receive {:worker_delta, %{kind: :text_delta, text: "hello"}}
    assert reply.completion == "natural"
    assert reply.continuation["status"] == "closed"
    assert reply.provider_response_id == "native-fixture"
    assert reply.delta_count == 1
    assert reply.usage == %{input_tokens: 11, output_tokens: 4}
    assert reply.staged_request_digest == request.staged_request_digest
  end

  test "malformed input cancels and joins a drain blocked inside progress" do
    prefix = events() |> Enum.drop(-3) |> encode()
    bad = "event: content_block_delta\ndata: {malformed-private-sentinel\n\n"
    {server, base} = server([prefix, :wait, bad, :wait])
    prepared = prepared(base)
    parent = self()

    {owner, monitor} =
      spawn_monitor(fn ->
        result =
          NativeTransport.complete(prepared, @key, fn delta ->
            send(parent, {:blocked_drain, self(), delta})

            receive do
              :never -> :ok
            end
          end)

        send(parent, {:result, result})
      end)

    assert_receive {:blocked_drain, drain, %{text: "hello"}}, 3000
    send(server, :continue)
    assert_receive {:result, {:error, :invalid_native_stream, _failure}}, 3000
    refute Process.alive?(drain)
    assert_receive {:DOWN, ^monitor, :process, ^owner, :normal}, 3000
  end

  test "incomplete EOF cannot acquire completion from the dependency's synthetic flush" do
    for body <- [encode(Enum.drop(events(), -1)), String.trim_trailing(encode(events()), "\n")] do
      {_server, base} = server([body])

      assert {:error, :invalid_native_stream, _failure} =
               NativeTransport.complete(prepared(base), @key, fn _ -> :ok end)
    end
  end

  test "response identity and invalid summary controls fail before disclosure" do
    changed = List.update_at(events(), 0, &put_in(&1, ["message", "model"], "other-model"))
    {_server, base} = server([encode(changed)])
    parent = self()

    assert {:error, :invalid_native_stream, _failure} =
             NativeTransport.complete(prepared(base), @key, &send(parent, {:delta, &1}))

    refute_receive {:delta, _}
  end

  test "only the captured summarized mode projects thinking and invalid eligible text fails" do
    parent = self()

    for text <- ["private thought", "bad\e[31m"] do
      changed = List.update_at(events(), 2, &put_in(&1, ["delta", "thinking"], text))
      {server, base} = server([encode(changed)])
      result = NativeTransport.complete(prepared(base, "low"), @key, &send(parent, {:delta, &1}))

      if text == "private thought" do
        assert {:ok, %{delta_count: 2}} = result
        assert_receive {:delta, %{kind: :reasoning_delta, text: ^text}}
        assert_receive {:delta, %{kind: :text_delta, text: "hello"}}
      else
        assert {:error, :invalid_native_stream, _} = result
        refute_receive {:delta, _}
      end

      assert_receive {:request, ^server, _, outgoing}
      assert outgoing["thinking"] == %{"type" => "adaptive", "display" => "summarized"}
      assert outgoing["output_config"] == %{"effort" => "low"}
    end
  end

  test "raw comment overflow wakes and joins a blocked drain without provider progress" do
    prefix = events() |> Enum.drop(-3) |> encode()
    {server, base} = server([prefix, :wait, ":" <> String.duplicate("x", 8_388_608), :wait])
    prepared = prepared(base)
    parent = self()

    {owner, monitor} =
      spawn_monitor(fn ->
        result =
          NativeTransport.complete(prepared, @key, fn _ ->
            send(parent, {:blocked_drain, self()})

            receive do
              :never -> :ok
            end
          end)

        send(parent, {:result, result})
      end)

    assert_receive {:blocked_drain, drain}, 3000
    send(server, :continue)
    assert_receive {:result, {:error, :invalid_native_stream, _}}, 3000
    refute Process.alive?(drain)
    assert_receive {:DOWN, ^monitor, :process, ^owner, :normal}, 3000
  end

  test "owner death also stops a drain blocked inside the progress callback" do
    prefix = events() |> Enum.drop(-3) |> encode()
    {_server, base} = server([prefix, :wait])
    prepared = prepared(base)
    parent = self()

    log =
      capture_log(fn ->
        {owner, monitor} =
          spawn_monitor(fn ->
            NativeTransport.complete(prepared, @key, fn _ ->
              send(parent, {:blocked_drain, self()})

              receive do
                :never -> :ok
              end
            end)
          end)

        assert_receive {:blocked_drain, drain}, 3000
        {:links, links} = Process.info(owner, :links)
        assert drain in links
        assert length(links) >= 3
        owned = Enum.map(links, &{&1, Process.monitor(&1)})
        Process.exit(owner, :kill)
        assert_receive {:DOWN, ^monitor, :process, ^owner, :killed}, 3000

        for {pid, reference} <- owned do
          assert_receive {:DOWN, ^reference, :process, ^pid, _}, 3000
        end
      end)

    refute log =~ @key
    refute log =~ "private thought"
    refute log =~ "sig+/="
  end

  test "global raw telemetry settings cannot expose private capture or its invocation handle" do
    prior = Application.fetch_env(:req_llm, :telemetry)
    Application.put_env(:req_llm, :telemetry, payloads: :raw)
    tag = make_ref()

    :ok =
      :telemetry.attach_many(
        tag,
        [[:req_llm, :request, :start], [:req_llm, :request, :stop]],
        &__MODULE__.telemetry_event/4,
        self()
      )

    on_exit(fn ->
      :telemetry.detach(tag)

      case prior do
        {:ok, value} -> Application.put_env(:req_llm, :telemetry, value)
        :error -> Application.delete_env(:req_llm, :telemetry)
      end
    end)

    {_server, base} = server([encode(events())])
    assert {:ok, _} = NativeTransport.complete(prepared(base), @key, fn _ -> :ok end)

    for kind <- [:start, :stop] do
      assert_receive {:sdk_telemetry, [:req_llm, :request, ^kind], metadata}
      refute Map.has_key?(metadata, :request_payload)
      refute Map.has_key?(metadata, :response_payload)
      refute Map.has_key?(metadata.model.extra || %{}, :loopex_native_invocation)
      text = inspect(metadata, limit: :infinity, printable_limit: :infinity)
      refute text =~ "private thought"
      refute text =~ "sig+/="
      refute text =~ @key
    end
  end

  test "byte-framed HTTP preserves tool JSON and redacted blocks while projecting only public fragments" do
    tool = LoopexProtocol.ToolDefinition.question_definition()

    middle = [
      %{
        "type" => "content_block_start",
        "index" => 2,
        "content_block" => %{"type" => "redacted_thinking", "data" => "redacted-private-canary"}
      },
      %{"type" => "content_block_stop", "index" => 2},
      %{
        "type" => "content_block_start",
        "index" => 3,
        "content_block" => %{
          "type" => "tool_use",
          "id" => "native:α",
          "name" => "ask",
          "input" => %{}
        }
      },
      %{
        "type" => "content_block_delta",
        "index" => 3,
        "delta" => %{"type" => "input_json_delta", "partial_json" => ~s({"question":"猫)}
      },
      %{
        "type" => "content_block_delta",
        "index" => 3,
        "delta" => %{"type" => "input_json_delta", "partial_json" => ~s(?"})}
      },
      %{"type" => "content_block_stop", "index" => 3}
    ]

    ending =
      events()
      |> Enum.take(-2)
      |> List.update_at(0, &put_in(&1, ["delta", "stop_reason"], "tool_use"))

    wire = encode(Enum.drop(events(), -2) ++ middle ++ ending)
    {server, base} = server(for <<byte <- wire>>, do: <<byte>>)
    parent = self()

    assert {:ok, captured} =
             NativeTransport.complete(
               prepared(base, "default", [tool]),
               @key,
               &send(parent, {:delta, &1})
             )

    assert {:ok, reply} =
             NativeContent.capture(@model, captured.native.stop_reason, captured.native.content)

    assert reply.tool_calls == [%{id: "native:α", name: "ask", arguments: %{"question" => "猫?"}}]

    assert Enum.at(captured.native.content, 2) == %{
             "type" => "redacted_thinking",
             "data" => "redacted-private-canary"
           }

    assert captured.delta_count == 4
    assert_receive {:delta, %{kind: :text_delta, text: "hello"}}

    assert_receive {:delta,
                    %{
                      kind: :tool_call_delta,
                      call_index: 0,
                      tool_call_id: "native:α",
                      name: "ask",
                      arguments_fragment: nil
                    }}

    assert_receive {:delta, %{arguments_fragment: first}}
    assert_receive {:delta, %{arguments_fragment: last}}
    assert Jason.decode!(first <> last) == %{"question" => "猫?"}
    refute_receive {:delta, _}
    assert_receive {:request, ^server, _, outgoing}
    assert [%{"name" => "ask"}] = outgoing["tools"]
  end

  def telemetry_event(event, _measurements, metadata, recipient),
    do: send(recipient, {:sdk_telemetry, event, metadata})

  defp prepared(base, level \\ "default", tools \\ []) do
    mapping = %{
      "mapping_revision" => "loopex.anthropic.fable51.v1",
      "renderer_revision" => "loopex.anthropic.native.v1",
      "continuation_required" => true,
      "canonical_terminal_tool_history" => true,
      "thinking_disabled" => false,
      "thinking" =>
        if(level == "default",
          do: %{"mode" => "omitted"},
          else: %{"mode" => "adaptive", "effort" => level, "display" => "summarized"}
        )
    }

    {:ok, request} =
      Model.request(@model, [%{"role" => "user", "content" => "go"}],
        tools: tools,
        sampling: %{"max_tokens" => 8192, "provider_mapping" => mapping, "reasoning" => level},
        deadline: 123
      )

    {:ok, context} = Mapping.context_of(request)
    {:ok, provider_tools} = Mapping.provider_tools(Model.model_facing_tools(request))

    {:ok, prepared} =
      NativeTransport.prepare(request, context,
        base_url: base,
        max_tokens: 8192,
        tools: provider_tools,
        max_retries: 0,
        total_timeout: :infinity,
        stream_idle_timeout: :infinity,
        receive_timeout: :infinity
      )

    prepared
  end

  defp events do
    [
      %{
        "type" => "message_start",
        "message" => %{
          "id" => "message-id",
          "type" => "message",
          "role" => "assistant",
          "model" => "claude-fable-5-1",
          "content" => [],
          "stop_reason" => nil,
          "stop_sequence" => nil,
          "usage" => %{"input_tokens" => 11}
        }
      },
      %{
        "type" => "content_block_start",
        "index" => 0,
        "content_block" => %{"type" => "thinking", "thinking" => "", "signature" => ""}
      },
      %{
        "type" => "content_block_delta",
        "index" => 0,
        "delta" => %{"type" => "thinking_delta", "thinking" => "private thought"}
      },
      %{
        "type" => "content_block_delta",
        "index" => 0,
        "delta" => %{"type" => "signature_delta", "signature" => "sig+"}
      },
      %{
        "type" => "content_block_delta",
        "index" => 0,
        "delta" => %{"type" => "signature_delta", "signature" => "/="}
      },
      %{"type" => "content_block_stop", "index" => 0},
      %{
        "type" => "content_block_start",
        "index" => 1,
        "content_block" => %{"type" => "text", "text" => ""}
      },
      %{
        "type" => "content_block_delta",
        "index" => 1,
        "delta" => %{"type" => "text_delta", "text" => "hello"}
      },
      %{"type" => "content_block_stop", "index" => 1},
      %{
        "type" => "message_delta",
        "delta" => %{"stop_reason" => "end_turn", "stop_sequence" => nil},
        "usage" => %{"output_tokens" => 4}
      },
      %{"type" => "message_stop"}
    ]
  end

  defp encode(events),
    do: Enum.map_join(events, fn e -> "event: #{e["type"]}\ndata: #{Jason.encode!(e)}\n\n" end)

  defp server(chunks) do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}, reuseaddr: true])

    {:ok, {_, port}} = :inet.sockname(listener)
    parent = self()

    pid =
      spawn(fn ->
        {:ok, socket} = :gen_tcp.accept(listener)
        {headers, body} = read_request(socket, "")
        send(parent, {:request, self(), headers, Jason.decode!(body)})

        :ok =
          :gen_tcp.send(
            socket,
            "HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\nrequest-id: native-fixture\r\ntransfer-encoding: chunked\r\nconnection: close\r\n\r\n"
          )

        Enum.each(chunks, fn
          :wait ->
            receive do
              :continue -> :ok
            end

          chunk ->
            :gen_tcp.send(socket, [Integer.to_string(byte_size(chunk), 16), "\r\n", chunk, "\r\n"])
        end)

        :gen_tcp.send(socket, "0\r\n\r\n")
        :gen_tcp.close(socket)
      end)

    on_exit(fn ->
      Process.exit(pid, :kill)
      :gen_tcp.close(listener)
    end)

    {pid, "http://127.0.0.1:#{port}"}
  end

  defp read_request(socket, bytes) do
    case :binary.split(bytes, "\r\n\r\n") do
      [headers, body] ->
        [_, length] = Regex.run(~r/content-length: (\d+)/i, headers)
        length = String.to_integer(length)
        body = read_body(socket, body, length)
        {headers, body}

      _ ->
        {:ok, more} = :gen_tcp.recv(socket, 0, 3000)
        read_request(socket, bytes <> more)
    end
  end

  defp read_body(_, body, length) when byte_size(body) >= length, do: body

  defp read_body(socket, body, length) do
    {:ok, more} = :gen_tcp.recv(socket, 0, 3000)
    read_body(socket, body <> more, length)
  end
end
