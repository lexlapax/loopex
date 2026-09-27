defmodule Loopex.LLM.ReqLLM.InProcess.GuardsTest do
  @moduledoc false
  use ExUnit.Case, async: false
  alias Loopex.LLM.ReqLLM.InProcess.Guards

  defmodule ReplacedProvider do
    @moduledoc false
    use ReqLLM.Provider, id: :openai, default_base_url: "https://host.example"
  end

  setup do
    defaults = Application.fetch_env(:req, :default_options)
    keylog = System.get_env("SSLKEYLOGFILE")
    tidewave = System.get_env("TIDEWAVE_REPL")
    registry = :persistent_term.get(:req_llm_providers, :absent)
    Application.delete_env(:req, :default_options)
    System.delete_env("SSLKEYLOGFILE")
    System.delete_env("TIDEWAVE_REPL")

    on_exit(fn ->
      case defaults do
        {:ok, value} -> Application.put_env(:req, :default_options, value)
        :error -> Application.delete_env(:req, :default_options)
      end

      restore("SSLKEYLOGFILE", keylog)
      restore("TIDEWAVE_REPL", tidewave)

      if registry == :absent,
        do: :persistent_term.erase(:req_llm_providers),
        else: :persistent_term.put(:req_llm_providers, registry)
    end)

    :ok
  end

  test "pre-start guard precedence is defaults then keylog then Tidewave" do
    assert Guards.pre_start() == :ok
    Application.put_env(:req, :default_options, auth: "fixture")
    System.put_env("SSLKEYLOGFILE", "fixture")
    System.put_env("TIDEWAVE_REPL", "true")
    assert Guards.pre_start() == {:error, :req_default_options_unsupported}
    Application.delete_env(:req, :default_options)
    assert Guards.pre_start() == {:error, :ssl_key_log_enabled}
    System.delete_env("SSLKEYLOGFILE")
    assert Guards.pre_start() == {:error, :req_llm_tidewave_enabled}
    System.put_env("TIDEWAVE_REPL", "TRUE")
    assert Guards.pre_start() == :ok
  end

  test "model admission uses a closed atom table and retains the first-colon remainder" do
    for {prefix, provider, module, variable} <- [
          {"ollama", :ollama, ReqLLM.Providers.Ollama, nil},
          {"openai", :openai, ReqLLM.Providers.OpenAI, "OPENAI_API_KEY"},
          {"anthropic", :anthropic, ReqLLM.Providers.Anthropic, "ANTHROPIC_API_KEY"},
          {"openrouter", :openrouter, ReqLLM.Providers.OpenRouter, "OPENROUTER_API_KEY"}
        ] do
      assert Guards.model(prefix <> ":name:tag") ==
               {:ok,
                %{
                  provider: provider,
                  provider_module: module,
                  model_id: "name:tag",
                  credential_variable: variable
                }}
    end

    assert Guards.model("unlisted:name") == {:error, :unknown_provider}
    assert Guards.model("OpenAI:name") == {:error, :unknown_provider}

    for value <- [nil, "", "missing", ":x", "openai:", <<255>>] do
      assert Guards.model(value) == {:error, :unknown_provider}
    end
  end

  test "every nonempty or malformed Req default and even an empty keylog variable refuses" do
    initial = Application.started_applications() |> Enum.map(&elem(&1, 0)) |> Enum.sort()

    for value <- [nil, false, :invalid, %{}, [plugins: [String]], [auth: "fixture"]] do
      Application.put_env(:req, :default_options, value)
      assert Guards.host() == {:error, :req_default_options_unsupported}
    end

    Application.put_env(:req, :default_options, [])
    assert Guards.host() == :ok
    System.put_env("SSLKEYLOGFILE", "")
    assert Guards.host() == {:error, :ssl_key_log_enabled}
    final = Application.started_applications() |> Enum.map(&elem(&1, 0)) |> Enum.sort()
    assert final == initial
  end

  test "call guard requires each actual built-in registration and catches replacement" do
    for module <- [
          ReqLLM.Providers.Ollama,
          ReqLLM.Providers.OpenAI,
          ReqLLM.Providers.Anthropic,
          ReqLLM.Providers.OpenRouter
        ] do
      assert {:ok, provider} = ReqLLM.Providers.register(module)
      assert Guards.provider(provider) == :ok
      assert Guards.call(provider) == :ok
    end

    assert {:ok, :openai} = ReqLLM.Providers.register(ReplacedProvider)
    assert Guards.provider(:openai) == {:error, :provider_module_replaced}
    Application.put_env(:req, :default_options, auth: "fixture")
    assert Guards.call(:openai) == {:error, :provider_module_replaced}
    assert Guards.call(:anthropic) == {:error, :req_default_options_unsupported}
    assert Guards.provider(:unsupported) == {:error, :provider_module_replaced}
    :ok = ReqLLM.Providers.unregister(:ollama)
    assert Guards.provider(:ollama) == {:error, :provider_module_replaced}
  end

  defp restore(name, nil), do: System.delete_env(name)
  defp restore(name, value), do: System.put_env(name, value)
end
