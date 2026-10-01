defmodule Loopex.LLM.ReqLLM.InProcess.Guards do
  @moduledoc """
  ## Concept

  Refuse host dependency settings that could expose or reroute an ephemeral
  provider call. Model admission selects only four existing provider atoms.

  ## Technical depth

  Composition startup and the shared initializer use the same ordered defaults,
  key-log and Tidewave checks. Call guards additionally require the exact built-in
  provider module. These checks read no provider credential or catalog and start
  no application. The final request adapter independently checks its route.
  """

  @providers %{
    "ollama" => {:ollama, ReqLLM.Providers.Ollama, nil},
    "openai" => {:openai, ReqLLM.Providers.OpenAI, "OPENAI_API_KEY"},
    "anthropic" => {:anthropic, ReqLLM.Providers.Anthropic, "ANTHROPIC_API_KEY"},
    "openrouter" => {:openrouter, ReqLLM.Providers.OpenRouter, "OPENROUTER_API_KEY"}
  }

  @doc false
  def binding_catalog do
    Map.new(@providers, fn {name, {_provider, _module, variable}} ->
      {name, %{credential_required: not is_nil(variable)}}
    end)
  end

  @doc false
  def model(value) when is_binary(value) and byte_size(value) in 1..512 do
    with true <- String.valid?(value),
         [prefix, id] when id != "" <- String.split(value, ":", parts: 2),
         {:ok, {provider, module, variable}} <- Map.fetch(@providers, prefix) do
      {:ok,
       %{
         provider: provider,
         provider_module: module,
         model_id: id,
         credential_variable: variable
       }}
    else
      _ -> {:error, :unknown_provider}
    end
  end

  def model(_), do: {:error, :unknown_provider}

  @doc false
  def pre_start do
    with :ok <- host() do
      if System.get_env("TIDEWAVE_REPL") == "true",
        do: {:error, :req_llm_tidewave_enabled},
        else: :ok
    end
  end

  @doc false
  def host do
    cond do
      Application.get_env(:req, :default_options, []) != [] ->
        {:error, :req_default_options_unsupported}

      System.get_env("SSLKEYLOGFILE") != nil ->
        {:error, :ssl_key_log_enabled}

      true ->
        :ok
    end
  end

  @doc false
  def provider(provider) do
    expected =
      Enum.find_value(@providers, fn {_prefix, {id, module, _variable}} ->
        if id == provider, do: module
      end)

    case expected && ReqLLM.provider(provider) do
      {:ok, ^expected} -> :ok
      _ -> {:error, :provider_module_replaced}
    end
  catch
    _, _ -> {:error, :provider_module_replaced}
  end

  @doc false
  def call(provider) do
    with :ok <- provider(provider), do: host()
  end
end
