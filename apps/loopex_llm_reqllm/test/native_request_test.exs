defmodule Loopex.NativeRequestFixtureProvider do
  @moduledoc false
  def attach_stream(_model, _context, options, _finch),
    do: {:ok, Keyword.fetch!(options, :request)}
end

defmodule Loopex.NativeRequestMutationHook do
  @moduledoc false
  def call(request), do: Process.get(:native_request_mutation, &Function.identity/1).(request)
end

defmodule Loopex.LLM.ReqLLM.NativeRequestTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  alias Loopex.LLM.ReqLLM.{NativeContent, NativeRequest}
  alias Loopex.Model
  alias LoopexProtocol.ToolDefinition

  @haiku "anthropic:claude-haiku-4-5-20251001"
  @fable "anthropic:claude-fable-5-1"
  @endpoint URI.parse("https://api.anthropic.com/v1/messages")
  @credential "synthetic-native-request-key"

  setup_all do
    {:ok, _} = Application.ensure_all_started(:req_llm)
    :ok
  end

  test "all nine literal cells preserve reply limits and exact outgoing controls" do
    for {model, level, thinking, required, summary} <- cells() do
      request = request(model, level, thinking, required)
      assert {:ok, profile} = NativeRequest.profile(request)
      assert profile.summary == summary
      assert profile.response_model == String.replace_prefix(model, "anthropic:", "")

      for streaming <- [true, false] do
        assert {:ok, body} =
                 NativeRequest.render(request, baseline(request, streaming), streaming)

        assert body["max_tokens"] == 8_192
        assert Map.get(body, "stream", false) == streaming
        assert body["system"] == [%{"type" => "text", "text" => "captured instructions"}]

        assert body["messages"] == [
                 %{"role" => "user", "content" => [%{"type" => "text", "text" => "go"}]}
               ]

        case thinking do
          %{"mode" => "omitted"} ->
            refute Map.has_key?(body, "thinking")
            refute Map.has_key?(body, "output_config")

          %{"mode" => "disabled"} ->
            assert body["thinking"] == %{"type" => "disabled"}
            refute Map.has_key?(body, "output_config")

          %{"mode" => "manual", "budget_tokens" => tokens} ->
            assert body["thinking"] == %{"type" => "enabled", "budget_tokens" => tokens}
            refute Map.has_key?(body, "output_config")

          %{"mode" => "adaptive", "effort" => effort} ->
            assert body["thinking"] == %{"type" => "adaptive", "display" => "summarized"}
            assert body["output_config"] == %{"effort" => effort}
        end
      end
    end
  end

  test "captured cells reject model, level, revision, disclosure and output-limit substitutions" do
    [_, _, {model, level, thinking, required, _} | _] = cells()
    original = request(model, level, thinking, required)

    for sampling <- [
          Map.put(original.sampling, "reasoning", "none"),
          put_in(original.sampling, ["provider_mapping", "mapping_revision"], "other"),
          put_in(original.sampling, ["provider_mapping", "renderer_revision"], "other"),
          put_in(original.sampling, ["provider_mapping", "continuation_required"], false),
          put_in(original.sampling, ["provider_mapping", "summary"], true),
          put_in(original.sampling, ["provider_mapping", "thinking", "budget_tokens"], 100),
          Map.put(original.sampling, "max_tokens", 1_024)
        ] do
      assert {:ok, changed} =
               Model.request(original.model, original.messages,
                 sampling: sampling,
                 deadline: original.deadline
               )

      assert {:error, :invalid_provider_request} =
               NativeRequest.render(changed, baseline(changed, true), true)
    end

    fable_none = request(@fable, "none", %{"mode" => "disabled"}, false)
    assert {:error, :invalid_provider_request} = NativeRequest.profile(fable_none)

    for body <- [
          Map.put(baseline(original, true), "model", "alias"),
          Map.put(baseline(original, true), "max_tokens", 16_384),
          Map.put(baseline(original, true), "thinking", %{"type" => "adaptive"}),
          Map.put(baseline(original, true), "output_config", %{"effort" => "high"}),
          Map.put(baseline(original, true), "stream", false)
        ] do
      assert {:error, :invalid_provider_request} = NativeRequest.render(original, body, true)
    end
  end

  test "buffered installation seals every cell and admits only its identity encoding header" do
    for {model, level, thinking, required, _} <- cells() do
      request = request(model, level, thinking, required)

      headers =
        finch_request().headers
        |> List.keyreplace("accept", 0, {"accept", "application/json"})
        |> Kernel.++([{"accept-encoding", "identity"}])
        |> Map.new(fn {key, value} -> {key, [value]} end)

      built = %Req.Request{
        method: :post,
        url: @endpoint,
        headers: headers,
        body: Jason.encode!(baseline(request, false))
      }

      assert {:ok, installed} =
               NativeRequest.install_buffered(request, built, @endpoint, @credential)

      assert {:ok, expected} = NativeRequest.render(request, baseline(request, false), false)
      assert Jason.decode!(installed.body) == expected
      assert installed.headers == headers

      for bad <- [
            %{built | method: :get},
            %{built | url: URI.parse("https://other.invalid/v1/messages")},
            %{
              built
              | body:
                  Jason.encode!(
                    Map.put(baseline(request, false), "thinking", %{"type" => "enabled"})
                  )
            },
            %{built | headers: Map.put(headers, "accept-encoding", ["gzip"])},
            %{built | headers: Map.put(headers, "accept", ["text/event-stream"])},
            %{built | headers: Map.put(headers, "x-api-key", [@credential, @credential])},
            %{built | headers: Map.put(headers, "content-length", ["1"])},
            %{
              built
              | headers: Map.put(headers, "anthropic-beta", ["interleaved-thinking-2025-05-14"])
            }
          ] do
        assert {:error, :invalid_provider_request} =
                 NativeRequest.install_buffered(request, bad, @endpoint, @credential)
      end
    end
  end

  test "private request bodies expose only a one-use handle and send exact native bytes" do
    {request, _} = continuation_request()
    assert {:ok, native} = NativeRequest.render(request, baseline(request, false), false)
    body = Jason.encode!(native)
    assert body =~ "sig+/="
    key = {__MODULE__, make_ref()}
    Process.put(key, body)
    finch = Finch.build(:post, @endpoint, [], body)
    private = NativeRequest.private_body(finch, fn -> Process.delete(key) end)
    assert {:stream, stream} = private.body
    assert private.headers == [{"content-length", Integer.to_string(byte_size(body))}]
    refute :erlang.term_to_binary(private) =~ "sig+/="
    refute :erlang.term_to_binary(private) =~ "opaque+/="
    assert Enum.to_list(stream) == [body]
    assert Process.get(key) == nil
    assert_raise RuntimeError, "invalid native request body", fn -> Enum.to_list(stream) end
  end

  test "native arrays replace canonical assistants and map results without rewriting IDs or arguments" do
    {request, native} = continuation_request()
    assert {:ok, rendered} = NativeRequest.render(request, baseline(request, true), true)
    [user, assistant, result] = rendered["messages"]
    assert user["role"] == "user"
    assert assistant == %{"role" => "assistant", "content" => native}

    assert result == %{
             "role" => "user",
             "content" => [
               %{"type" => "tool_result", "tool_use_id" => "native:α", "content" => "result"}
             ]
           }

    [definition] = request.tools

    assert rendered["tools"] == [
             %{
               "name" => definition["name"],
               "description" => definition["description"],
               "input_schema" => definition["parameter_schema"]
             }
           ]

    refute Jason.encode!(rendered) =~ "canonical-call"

    changed =
      update_in(request.continuation, ["entries"], fn [entry] ->
        [
          update_in(entry, ["capsule", "content"], fn nodes ->
            Enum.map(nodes, fn
              %{"kind" => "tool_use_ref"} = node ->
                put_in(node, ["template", "name"], "substituted")

              node ->
                node
            end)
          end)
        ]
      end)

    assert {:ok, forged} =
             Model.request(request.model, request.messages,
               tools: request.tools,
               sampling: request.sampling,
               deadline: request.deadline,
               continuation: changed
             )

    assert {:error, :invalid_provider_request} =
             NativeRequest.render(forged, baseline(forged, true), true)
  end

  test "canonical history uses complete generations and refuses malformed or unresolved calls" do
    {request, _native} = continuation_request()

    assert {:ok, canonical} =
             Model.request(request.model, request.messages,
               tools: request.tools,
               sampling: request.sampling,
               deadline: request.deadline
             )

    assert {:ok, body} = NativeRequest.render(canonical, baseline(canonical, true), true)

    assert Enum.at(body["messages"], 1)["content"] == [
             %{"type" => "text", "text" => "answeré"},
             %{
               "type" => "tool_use",
               "id" => "canonical-call",
               "name" => "ask",
               "input" => %{"question" => "猫?"}
             }
           ]

    for arguments <- [nil, "{}", [], 1] do
      messages =
        List.update_at(request.messages, 2, fn assistant ->
          update_in(assistant, ["tool_calls"], fn [call] ->
            [Map.put(call, "arguments", arguments)]
          end)
        end)

      assert {:ok, invalid} =
               Model.request(request.model, messages,
                 tools: request.tools,
                 sampling: request.sampling,
                 deadline: request.deadline
               )

      assert {:error, :invalid_provider_request} =
               NativeRequest.render(invalid, baseline(invalid, true), true)
    end

    assert {:ok, unanswered} =
             Model.request(request.model, Enum.drop(request.messages, -1),
               tools: request.tools,
               sampling: request.sampling,
               deadline: request.deadline
             )

    assert {:error, :invalid_provider_request} =
             NativeRequest.render(unanswered, baseline(unanswered, true), true)
  end

  test "terminal tool results and a later prompt share one user array across empty completions" do
    {original, _} = continuation_request()

    messages =
      original.messages ++
        [
          %{"role" => "assistant", "content" => ""},
          %{"role" => "user", "content" => "next prompt"}
        ]

    for {model, level, thinking, required, _} <- cells() do
      configured = request(model, level, thinking, required)

      {:ok, request} =
        Model.request(model, messages,
          tools: original.tools,
          sampling: configured.sampling,
          deadline: original.deadline
        )

      assert {:ok, body} = NativeRequest.render(request, baseline(request, true), true)
      assert length(body["messages"]) == 3

      assert Enum.at(body["messages"], 1) == %{
               "role" => "assistant",
               "content" => [
                 %{"type" => "text", "text" => "answeré"},
                 %{
                   "type" => "tool_use",
                   "id" => "canonical-call",
                   "name" => "ask",
                   "input" => %{"question" => "猫?"}
                 }
               ]
             }

      assert List.last(body["messages"]) == %{
               "role" => "user",
               "content" => [
                 %{
                   "type" => "tool_result",
                   "tool_use_id" => "canonical-call",
                   "content" => "result"
                 },
                 %{"type" => "text", "text" => "next prompt"}
               ]
             }
    end
  end

  test "checkpoint provenance stays exact user data through every native mapping and transport" do
    content =
      File.read!(Path.expand("../../../test/fixtures/m7/checkpoint-summary.json", __DIR__))

    for {model, level, thinking, required, _} <- cells() do
      original = request(model, level, thinking, required)
      messages = [hd(original.messages), %{"role" => "user", "content" => content}]

      assert {:ok, staged} =
               Model.request(model, messages,
                 sampling: original.sampling,
                 deadline: original.deadline
               )

      for streaming <- [true, false] do
        assert {:ok, body} = NativeRequest.render(staged, baseline(staged, streaming), streaming)
        assert body["system"] == [%{"type" => "text", "text" => "captured instructions"}]

        assert body["messages"] == [
                 %{"role" => "user", "content" => [%{"type" => "text", "text" => content}]}
               ]
      end
    end
  end

  test "every continuation-required cell expands its own exact ordered native array" do
    for {model, level, thinking, true, _} <- cells() do
      {request, native} = continuation_request(model, level, thinking)

      for streaming <- [true, false] do
        assert {:ok, rendered} =
                 NativeRequest.render(request, baseline(request, streaming), streaming)

        assert Enum.at(rendered["messages"], 1) == %{"role" => "assistant", "content" => native}

        assert List.last(rendered["messages"]) == %{
                 "role" => "user",
                 "content" => [
                   %{"type" => "tool_result", "tool_use_id" => "native:α", "content" => "result"}
                 ]
               }
      end
    end
  end

  test "the final invocation hook refuses global mutations without logging request material" do
    prior = Application.fetch_env(:req_llm, :finch_request_adapter)
    Application.put_env(:req_llm, :finch_request_adapter, Loopex.NativeRequestMutationHook)

    on_exit(fn ->
      case prior do
        {:ok, value} -> Application.put_env(:req_llm, :finch_request_adapter, value)
        :error -> Application.delete_env(:req_llm, :finch_request_adapter)
      end
    end)

    expected = finch_request()
    assert {:ok, guard} = NativeRequest.guard(expected, @endpoint, @credential, false)
    assert guard.(expected) == expected
    model = %LLMDB.Model{provider: :anthropic, id: "fixture"}
    options = [request: expected, on_finch_request: guard]

    assert {:ok, ^expected, _, _} =
             ReqLLM.Streaming.FinchClient.build_stream_request(
               Loopex.NativeRequestFixtureProvider,
               model,
               ReqLLM.Context.new([]),
               options,
               ReqLLM.Finch
             )

    mutations = [
      fn req -> %{req | method: "GET"} end,
      fn req -> %{req | host: "elsewhere.invalid"} end,
      fn req -> %{req | port: 444} end,
      fn req -> %{req | path: "/other"} end,
      fn req -> %{req | query: "injected"} end,
      fn req -> %{req | headers: [{"x-secret", "private-sentinel"} | req.headers]} end,
      fn req -> %{req | body: "private-sentinel"} end,
      fn req -> %{req | unix_socket: "/tmp/other.sock"} end,
      fn req -> %{req | pool_tag: :other} end,
      fn req -> %{req | private: %{other: "private-sentinel"}} end
    ]

    for mutate <- mutations do
      assert guard.(mutate.(expected)) == {:error, :invalid_provider_request}
      Process.put(:native_request_mutation, mutate)

      log =
        capture_log(fn ->
          assert {:error, _} =
                   ReqLLM.Streaming.FinchClient.build_stream_request(
                     Loopex.NativeRequestFixtureProvider,
                     model,
                     ReqLLM.Context.new([]),
                     options,
                     ReqLLM.Finch
                   )
        end)

      refute log =~ @credential
      refute log =~ "private-sentinel"
      assert log =~ "invalid_provider_request"
    end

    Process.delete(:native_request_mutation)
  end

  test "the pinned Anthropic builder joins native installation for each cell without transport" do
    {continued, _} = continuation_request()

    requests =
      Enum.map(cells(), fn {model, level, thinking, required, _} ->
        request(model, level, thinking, required)
      end)

    for request <- requests ++ [continued] do
      model = request.model

      {:ok, inline} =
        ReqLLM.model(%{provider: :anthropic, id: String.replace_prefix(model, "anthropic:", "")})

      {:ok, context} = Loopex.LLM.ReqLLM.Mapping.context_of(request)
      {:ok, tools} = Loopex.LLM.ReqLLM.Mapping.provider_tools(Model.model_facing_tools(request))

      options = [
        api_key: @credential,
        tools: tools,
        max_tokens: 8_192,
        max_retries: 0,
        total_timeout: :infinity,
        stream_idle_timeout: :infinity,
        receive_timeout: :infinity
      ]

      assert {:ok, built} =
               ReqLLM.Providers.Anthropic.attach_stream(inline, context, options, ReqLLM.Finch)

      assert {:ok, expected, guard} =
               NativeRequest.install(request, built, @endpoint, @credential)

      assert guard.(expected) == expected
      {:ok, actual} = Jason.decode(expected.body)
      assert {:ok, ^actual} = NativeRequest.render(request, baseline(request, true), true)
      assert expected.host == built.host and expected.path == built.path
      assert expected.headers == built.headers
    end
  end

  test "normalized tools must exactly preserve the committed definitions" do
    {request, _} = continuation_request()
    body = baseline(request, true)
    [tool] = body["tools"]

    for tools <- [
          [],
          [Map.put(tool, "name", "other")],
          [Map.put(tool, "input_schema", %{})],
          [tool, %{"type" => "web_search_20250305", "name" => "web_search"}]
        ] do
      assert {:error, :invalid_provider_request} =
               NativeRequest.render(request, Map.put(body, "tools", tools), true)
    end
  end

  test "each manual thinking budget must fit strictly below the committed output limit" do
    for {model, level, %{"budget_tokens" => budget} = thinking, required, _} <- cells(),
        limit <- [budget, budget + 1] do
      original = request(model, level, thinking, required)

      {:ok, bounded} =
        Model.request(model, original.messages,
          sampling: Map.put(original.sampling, "max_tokens", limit),
          deadline: original.deadline
        )

      if limit == budget do
        assert {:error, :invalid_provider_request} = NativeRequest.profile(bounded)
      else
        assert {:ok, _} = NativeRequest.profile(bounded)
        assert {:ok, rendered} = NativeRequest.render(bounded, baseline(bounded, true), true)
        assert rendered["max_tokens"] == limit
      end
    end
  end

  test "unregistered default requests retain the dependency body and disclose no thinking" do
    {:ok, request} =
      Model.request(
        "anthropic:unregistered-model",
        [%{"role" => "user", "content" => "go"}],
        sampling: %{"max_tokens" => 123},
        deadline: 123
      )

    body = %{
      "model" => "unregistered-model",
      "max_tokens" => 123,
      "messages" => [%{"role" => "user", "content" => "go"}],
      "stream" => true
    }

    assert {:ok, ^body} = NativeRequest.render(request, body, true)
    assert {:ok, %{response_model: nil, summary: false}} = NativeRequest.profile(request)
  end

  test "initial sealing validates route authentication beta and transport header constraints" do
    original = finch_request()

    for headers <- [
          [{"anthropic-beta", "interleaved-thinking-2025-05-14"} | original.headers],
          [{"anthropic-beta", "tools-2024-05-16"} | original.headers],
          [{"accept-encoding", "identity"} | original.headers],
          [{"X-Api-Key", @credential} | original.headers],
          [{"host", "other.invalid"} | original.headers],
          [{"content-length", "999"} | original.headers],
          List.keyreplace(original.headers, "x-api-key", 0, {"x-api-key", "other"}),
          List.keyreplace(
            original.headers,
            "anthropic-version",
            0,
            {"anthropic-version", "future"}
          )
        ] do
      assert {:error, :invalid_provider_request} =
               NativeRequest.guard(%{original | headers: headers}, @endpoint, @credential, false)
    end

    assert {:ok, _} =
             NativeRequest.guard(
               %{original | headers: [{"anthropic-beta", "tools-2024-05-16"} | original.headers]},
               @endpoint,
               @credential,
               true
             )

    assert {:error, :invalid_provider_request} =
             NativeRequest.guard(
               original,
               URI.parse("https://other.invalid/v1/messages"),
               @credential,
               false
             )
  end

  defp finch_request,
    do:
      Finch.build(
        :post,
        URI.to_string(@endpoint),
        [
          {"accept", "text/event-stream"},
          {"content-type", "application/json"},
          {"anthropic-version", "2023-06-01"},
          {"x-api-key", @credential}
        ],
        "{}"
      )

  defp baseline(request, streaming),
    do: %{
      "model" => String.replace_prefix(request.model, "anthropic:", ""),
      "max_tokens" => request.sampling["max_tokens"],
      "tools" =>
        Enum.map(request.tools, fn tool ->
          %{
            "name" => tool["name"],
            "description" => tool["description"],
            "input_schema" => tool["parameter_schema"]
          }
        end),
      "messages" => [],
      "stream" => streaming
    }

  defp request(model, level, thinking, required) do
    mapping = %{
      "mapping_revision" =>
        if(model == @haiku,
          do: "loopex.anthropic.haiku45.v1",
          else: "loopex.anthropic.fable51.v1"
        ),
      "renderer_revision" => "loopex.anthropic.native.v1",
      "continuation_required" => required,
      "canonical_terminal_tool_history" => true,
      "thinking_disabled" => level == "none",
      "thinking" => thinking
    }

    sampling = %{"max_tokens" => 8_192, "provider_mapping" => mapping}
    sampling = if level == "default", do: sampling, else: Map.put(sampling, "reasoning", level)

    {:ok, request} =
      Model.request(
        model,
        [
          %{"role" => "system", "content" => "captured instructions"},
          %{"role" => "user", "content" => "go"}
        ],
        sampling: sampling,
        deadline: 123
      )

    request
  end

  defp cells do
    [
      {@haiku, "default", %{"mode" => "omitted"}, false, false},
      {@haiku, "none", %{"mode" => "disabled"}, false, false}
    ] ++
      for(
        {level, budget} <- [{"low", 1_024}, {"medium", 2_048}, {"high", 4_096}],
        do: {@haiku, level, %{"mode" => "manual", "budget_tokens" => budget}, true, true}
      ) ++
      [{@fable, "default", %{"mode" => "omitted"}, true, false}] ++
      for level <- ~w(low medium high),
          do:
            {@fable, level, %{"mode" => "adaptive", "effort" => level, "display" => "summarized"},
             true, true}
  end

  defp continuation_request(
         model \\ @fable,
         level \\ "default",
         thinking \\ %{"mode" => "omitted"}
       ) do
    initial = request(model, level, thinking, true)
    tool = ToolDefinition.question_definition()
    {id, version, digest} = ToolDefinition.generation(tool)
    arguments = %{"question" => "猫?"}

    native = [
      %{"type" => "thinking", "thinking" => "private", "signature" => "sig+/="},
      %{"type" => "text", "text" => "answeré"},
      %{"type" => "tool_use", "id" => "native:α", "name" => "ask", "input" => arguments},
      %{"type" => "redacted_thinking", "data" => "opaque+/="}
    ]

    {:ok, reply} = NativeContent.capture(model, "tool_use", native)

    messages =
      initial.messages ++
        [
          %{
            "role" => "assistant",
            "content" => reply.text,
            "tool_calls" => [
              %{
                "tool_call_id" => "canonical-call",
                "tool_id" => id,
                "tool_version" => version,
                "definition_digest" => digest,
                "arguments" => arguments
              }
            ]
          },
          %{
            "role" => "tool",
            "tool_call_id" => "canonical-call",
            "content" => "result",
            "outcome" => "completed"
          }
        ]

    envelope = %{
      "format" => "loopex.anthropic.content_refs.v1",
      "provider" => "anthropic",
      "model" => model,
      "configuration_version" => 1,
      "exchange_id" => "op",
      "base_request_digest" => initial.staged_request_digest,
      "entries" => [
        %{
          "source" => %{
            "run_id" => "run",
            "turn_id" => "turn",
            "operation_id" => "op",
            "attempt" => 1,
            "settlement_digest" => String.duplicate("a", 64)
          },
          "assistant_message_index" => 2,
          "calls" => [
            %{
              "canonical_call_id" => "canonical-call",
              "native_id" => "native:α",
              "result_message_index" => 3
            }
          ],
          "capsule" => reply.continuation
        }
      ]
    }

    {:ok, request} =
      Model.request(model, messages,
        tools: [tool],
        sampling: initial.sampling,
        deadline: initial.deadline,
        continuation: envelope
      )

    {request, native}
  end
end
