defmodule Loopex.LLM.ReqLLM.InProcess.RouteTest do
  use ExUnit.Case, async: true

  alias Loopex.LLM.ReqLLM.InProcess.Route

  defmodule FinalRequestProbe do
    @moduledoc false

    def run(request) do
      {caller, marker} = Req.Request.get_private(request, :route_probe)
      send(caller, {marker, request})
      {request, %Req.TransportError{reason: :closed}}
    end
  end

  @rows [
    {:ollama, :ollama_chat_completions, "http://localhost:11434/v1", "/v1/chat/completions"},
    {:openrouter, :openrouter_chat_completions, "https://openrouter.ai/api/v1",
     "/api/v1/chat/completions"},
    {:openai, :openai_chat_completions, "https://api.openai.com/v1", "/v1/chat/completions"},
    {:openai, :openai_responses, "https://api.openai.com/v1", "/v1/responses"},
    {:anthropic, :anthropic_messages, "https://api.anthropic.com", "/v1/messages"}
  ]

  test "every fixed provider default binds its supported endpoint" do
    for {provider, surface, base, path} <- @rows do
      assert Route.base_url(provider, nil) == {:ok, base}
      assert {:ok, retained} = Route.fingerprint(provider, surface, base)

      assert retained == %{
               provider: provider,
               surface: surface,
               method: :post,
               base_url: base,
               path: path,
               query: nil
             }

      assert Route.matches?(retained, request(retained))
    end
  end

  test "canonical DNS, IPv4, default ports and all trailing slashes normalize" do
    for {provider, input, expected} <- [
          {:ollama, "http://LOCALHOST:80/", "http://localhost"},
          {:ollama, "https://LOCALHOST:443///", "https://localhost"},
          {:openai, "https://API.Example.COM:443/api/v1///", "https://api.example.com/api/v1"},
          {:openai, "https://a-b.EXAMPLE:1/prefix_~.name/-a",
           "https://a-b.example:1/prefix_~.name/-a"},
          {:openai, "https://127.0.0.1:65535/v1", "https://127.0.0.1:65535/v1"},
          {:ollama, "http://0.0.0.0", "http://0.0.0.0"},
          {:openrouter, "https://255.255.255.255", "https://255.255.255.255"},
          {:anthropic, "https://1.2.example", "https://1.2.example"}
        ] do
      assert Route.base_url(provider, input) == {:ok, expected}
      assert Route.base_url(provider, expected) == {:ok, expected}
    end
  end

  test "hosted providers refuse plain HTTP independently of path and port" do
    for provider <- [:openai, :anthropic, :openrouter] do
      assert invalid?(Route.base_url(provider, "http://localhost:11434/v1"))
      assert invalid?(Route.base_url(provider, "http://example.com:443"))
    end

    assert Route.base_url(:ollama, "http://example.com:443") == {:ok, "http://example.com:443"}
  end

  test "unsupported schemes, authorities and numeric normalization candidates refuse" do
    for input <- [
          "",
          "example.com",
          "//example.com",
          "HTTPS://example.com",
          "https:example.com",
          "ftp://example.com",
          "https:///v1",
          "https://",
          "https://user@example.com",
          "https://user:password@example.com",
          "https://[::1]",
          "https://::1",
          "https://é.example",
          "https://%65xample.com",
          "https://example.com.",
          "https://.example.com",
          "https://a..example.com",
          "https://-a.example",
          "https://a-.example",
          "https://a_b.example",
          "https://a+b.example",
          "https://127.00.0.1",
          "https://01.2.3.4",
          "https://256.1.1.1",
          "https://127.1",
          "https://2130706433",
          "https://1.2.3.4.5",
          "https://1.2.3.",
          "https://1..2.3",
          "https://example.com:443:1",
          "https://example.com:",
          "https://example.com:0",
          "https://example.com:01",
          "https://example.com:+1",
          "https://example.com:-1",
          "https://example.com:65536",
          "https://example.com:123456",
          "https://example.com:4x",
          "https://example.com\n",
          "https://example.com "
        ] do
      assert invalid?(Route.base_url(:ollama, input)), input
    end
  end

  test "query, fragment, escaped paths and ambiguous interior segments refuse" do
    for suffix <- [
          "?",
          "?key=value",
          "#",
          "#fragment",
          "/a?key=value",
          "/a#fragment",
          "/%61",
          "/a%2Fb",
          "/a\\b",
          "/a//b",
          "//a",
          "/./",
          "/../",
          "/a/./b",
          "/a/../b",
          "/a:b",
          "/a@b",
          "/a+b",
          "/a b",
          "/é",
          "/a\n",
          <<"/", 0>>,
          <<"/", 255>>
        ] do
      assert invalid?(Route.base_url(:openai, "https://example.com" <> suffix))
    end
  end

  test "DNS label, host and complete address bounds are exact" do
    longest_host =
      Enum.join(
        [
          String.duplicate("a", 63),
          String.duplicate("b", 63),
          String.duplicate("c", 63),
          String.duplicate("d", 61)
        ],
        "."
      )

    assert byte_size(longest_host) == 253
    assert {:ok, _} = Route.base_url(:openai, "https://" <> longest_host)
    assert invalid?(Route.base_url(:openai, "https://" <> longest_host <> "d"))
    assert {:ok, _} = Route.base_url(:openai, "https://" <> String.duplicate("a", 63))
    assert invalid?(Route.base_url(:openai, "https://" <> String.duplicate("a", 64)))

    prefix = "https://example.com/"
    maximum = prefix <> String.duplicate("a", 65_536 - byte_size(prefix))
    assert Route.base_url(:openai, maximum) == {:ok, maximum}
    assert invalid?(Route.base_url(:openai, maximum <> "a"))

    for input <- [false, 1, [], %{}, <<255>>],
        do: assert(invalid?(Route.base_url(:openai, input)))

    assert invalid?(Route.base_url(:unknown, nil))
    assert invalid?(Route.base_url("openai", "https://example.com"))
  end

  test "every endpoint binds explicit ports and prefixes without dropping a prefix" do
    for {provider, surface, _base, path} <- @rows do
      assert {:ok, retained} =
               Route.fingerprint(provider, surface, "https://example.com:8443/prefix")

      endpoint =
        case {provider, surface} do
          {:anthropic, _} -> "/v1/messages"
          {:openai, :openai_responses} -> "/responses"
          _ -> "/chat/completions"
        end

      assert retained.path == "/prefix" <> endpoint
      assert Route.matches?(retained, request(retained))

      refute Route.matches?(retained, %{
               request(retained)
               | url: URI.parse("https://example.com:8443" <> path)
             })
    end
  end

  test "fingerprints require canonical input and the exact supported provider surface" do
    for {provider, surface, base, _path} <- @rows do
      assert {:error, :provider_route_unsupported} =
               Route.fingerprint(provider, surface, base <> "/")

      assert {:error, :provider_route_unsupported} = Route.fingerprint(provider, :unknown, base)
    end

    assert {:error, :provider_route_unsupported} =
             Route.fingerprint(:anthropic, :openai_responses, "https://example.com")

    assert {:error, :provider_route_unsupported} =
             Route.fingerprint(:unknown, :openai_responses, "https://example.com")

    assert {:error, :provider_route_unsupported} =
             Route.fingerprint(:openai, :openai_responses, nil)
  end

  test "final requests reject every substituted URI member and method" do
    assert {:ok, retained} =
             Route.fingerprint(:openai, :openai_responses, "https://example.com/prefix")

    original = request(retained)
    assert Route.matches?(retained, original)
    assert Route.matches?(retained, %{original | url: %{original.url | port: nil}})

    for {field, changed} <- [
          {:scheme, "http"},
          {:host, "other.example.com"},
          {:host, "EXAMPLE.COM"},
          {:port, 444},
          {:path, "/prefix/chat/completions"},
          {:path, "/responses"},
          {:path, "/prefix/responses/"},
          {:query, ""},
          {:query, "x=1"},
          {:fragment, ""},
          {:fragment, "x"},
          {:userinfo, "user"}
        ] do
      refute Route.matches?(retained, %{original | url: Map.put(original.url, field, changed)})
    end

    refute Route.matches?(retained, %{original | method: :get})
    refute Route.matches?(retained, Map.from_struct(original))
    refute Route.matches?(Map.put(retained, :path, "/other"), original)
    refute Route.matches?(Map.put(retained, :extra, true), original)
    refute Route.matches?(%{}, original)
    refute Route.matches?(retained, nil)
  end

  test "Anthropic and OpenAI require the matching locked private plan surface" do
    for {provider, surface, base, _path} <- @rows, provider in [:anthropic, :openai] do
      assert {:ok, retained} = Route.fingerprint(provider, surface, base)
      original = request(retained)
      assert Route.matches?(retained, original)

      for metadata <- [nil, %{}, %{surface: :other}, %{"surface" => surface}, "malformed"] do
        refute Route.matches?(
                 retained,
                 Req.Request.put_private(original, :req_llm_request_plan, metadata)
               )
      end

      refute Route.matches?(retained, %{original | private: %{}})
      refute Route.matches?(retained, %{original | private: nil})
    end
  end

  test "real credential-free plans and prepared requests preserve all three hosted surfaces" do
    {:ok, _} = Application.ensure_all_started(:req_llm)

    for {provider, id, surface, protocol, module} <- [
          {:openai, "gpt-4o-mini", :openai_chat_completions, "openai_chat",
           ReqLLM.Providers.OpenAI},
          {:openai, "gpt-4o-mini", :openai_responses, "openai_responses",
           ReqLLM.Providers.OpenAI},
          {:anthropic, "claude-haiku-4-5", :anthropic_messages, "anthropic_messages",
           ReqLLM.Providers.Anthropic}
        ] do
      {:ok, base} = Route.base_url(provider, "https://example.com:8443/prefix")

      {:ok, model} =
        ReqLLM.model(%{
          provider: provider,
          id: id,
          base_url: base,
          extra: %{wire: %{protocol: protocol}}
        })

      caller = self()
      marker = make_ref()

      options = [
        max_tokens: 32,
        tools: [],
        total_timeout: :infinity,
        receive_timeout: :infinity,
        max_retries: 0,
        base_url: base,
        req_http_options: [adapter: FinalRequestProbe]
      ]

      assert {:ok, %{surface: ^surface, route: %{method: :post}}} =
               ReqLLM.plan(model, :chat, options)

      assert {:ok, prepared} =
               module.prepare_request(:chat, model, "route fixture", [
                 {:api_key, "route-fixture"} | options
               ])

      assert %{surface: ^surface} = Req.Request.get_private(prepared, :req_llm_request_plan)
      assert {:ok, retained} = Route.fingerprint(provider, surface, base)
      prepared = Req.Request.put_private(prepared, :route_probe, {caller, marker})

      assert {:error, %ReqLLM.Error.API.Request{cause: %Req.TransportError{reason: :closed}}} =
               Req.request(prepared)

      assert_receive {^marker, final}
      assert Route.matches?(retained, final)
    end
  end

  defp invalid?({:error, :provider_base_url_unsupported}), do: true
  defp invalid?(_), do: false

  defp request(retained) do
    base = URI.parse(retained.base_url)
    request = %Req.Request{method: :post, url: %{base | path: retained.path}}
    Req.Request.put_private(request, :req_llm_request_plan, %{surface: retained.surface})
  end
end
