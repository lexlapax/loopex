defmodule Loopex.LLM.ReqLLM.InProcess.Route do
  @moduledoc """
  ## Concept

  Bind an in-process model call to its admitted provider address and endpoint.

  ## Technical depth

  This private adapter helper admits a bounded ASCII URL grammar before any URI
  library parses it. It normalizes DNS case, default ports and trailing slashes.
  Numeric hosts must be canonical IPv4. Hosted providers require HTTPS. The
  retained fingerprint contains no credential, and final requests must match
  its method, origin, path and absent query, fragment and user information.
  Anthropic and OpenAI must also retain the planned ReqLLM execution surface.
  """

  @providers %{
    ollama: ReqLLM.Providers.Ollama,
    openai: ReqLLM.Providers.OpenAI,
    anthropic: ReqLLM.Providers.Anthropic,
    openrouter: ReqLLM.Providers.OpenRouter
  }
  @invalid {:error, :provider_base_url_unsupported}

  @doc """
  ## Concept

  Admit and canonicalize a provider base address, using its explicit default
  when no override was supplied.

  ## Technical depth

  The caller verifies the provider registry before using the fixed module's
  default. This parser itself consults no registry or environment. Only Ollama
  may use HTTP; all inputs are bounded to 65,536 bytes.
  """
  def base_url(provider, nil) when is_map_key(@providers, provider),
    do: base_url(provider, Map.fetch!(@providers, provider).default_base_url())

  def base_url(provider, input)
      when is_map_key(@providers, provider) and is_binary(input) and
             byte_size(input) in 1..65_536 do
    with {:ok, scheme, host, port, path} <- parse(provider, input) do
      port_suffix = if port == default_port(scheme), do: "", else: ":#{port}"
      {:ok, scheme <> "://" <> host <> port_suffix <> path}
    else
      _invalid -> @invalid
    end
  end

  def base_url(_provider, _input), do: @invalid

  @doc """
  ## Concept

  Retain the exact endpoint selected for one admitted model call.

  ## Technical depth

  The address must already be canonical. OpenAI and Anthropic surfaces come
  from credential-free ReqLLM planning; Ollama and OpenRouter use their fixed
  chat-completions rows. Unknown provider/surface pairs refuse.
  """
  def fingerprint(provider, surface, canonical_url) do
    with {:ok, ^canonical_url} <- base_url(provider, canonical_url),
         {:ok, _scheme, _host, _port, prefix} <- parse(provider, canonical_url),
         {:ok, route} <- endpoint(provider, surface) do
      {:ok,
       %{
         provider: provider,
         surface: surface,
         method: :post,
         base_url: canonical_url,
         path: prefix <> route,
         query: nil
       }}
    else
      _invalid -> {:error, :provider_route_unsupported}
    end
  end

  @doc """
  ## Concept

  Refuse a final request that substitutes any bound route member.

  ## Technical depth

  Req's final URI must match the retained origin, effective port and fixed
  endpoint. Its private `:req_llm_request_plan` must name the same surface for
  Anthropic and OpenAI. This check grants no dispatch authority by itself.
  """
  def matches?(
        %{provider: provider, surface: surface, base_url: base_url} = retained,
        %Req.Request{method: :post, url: %URI{} = uri} = request
      ) do
    with {:ok, ^retained} <- fingerprint(provider, surface, base_url),
         {:ok, scheme, host, port, _prefix} <- parse(provider, base_url) do
      uri.scheme == scheme and uri.host == host and effective_port(uri) == port and
        uri.path == retained.path and uri.query == nil and uri.fragment == nil and
        uri.userinfo == nil and plan_matches?(provider, surface, request)
    else
      _invalid -> false
    end
  end

  def matches?(_fingerprint, _request), do: false

  defp parse(provider, input) do
    with {:ok, scheme, remainder} <- scheme(input, provider),
         {authority, path} <- authority_path(remainder),
         {:ok, host, port} <- authority(authority, scheme),
         {:ok, path} <- path(path) do
      {:ok, scheme, host, port, path}
    end
  end

  defp scheme("http://" <> remainder, :ollama), do: {:ok, "http", remainder}
  defp scheme("https://" <> remainder, _provider), do: {:ok, "https", remainder}
  defp scheme(_input, _provider), do: :invalid

  defp authority_path(remainder) do
    case :binary.split(remainder, "/") do
      [authority] -> {authority, ""}
      [authority, path] -> {authority, "/" <> path}
    end
  end

  defp authority(value, scheme) do
    case :binary.split(value, ":", [:global]) do
      [host] ->
        with {:ok, canonical} <- host(host), do: {:ok, canonical, default_port(scheme)}

      [host, port] ->
        with {:ok, canonical} <- host(host),
             {:ok, port} <- port(port) do
          {:ok, canonical, port}
        end

      _invalid ->
        :invalid
    end
  end

  defp host(value) when byte_size(value) in 1..253 do
    labels = :binary.split(value, ".", [:global])

    admitted =
      if Regex.match?(~r/\A[0-9.]+\z/, value) do
        length(labels) == 4 and Enum.all?(labels, &ipv4_octet?/1)
      else
        Enum.all?(labels, &dns_label?/1)
      end

    if admitted, do: {:ok, String.downcase(value)}, else: :invalid
  end

  defp host(_value), do: :invalid

  defp ipv4_octet?(value) when byte_size(value) in 1..3 do
    Regex.match?(~r/\A(?:0|[1-9][0-9]*)\z/, value) and String.to_integer(value) <= 255
  end

  defp ipv4_octet?(_value), do: false

  defp dns_label?(value) when byte_size(value) in 1..63,
    do: Regex.match?(~r/\A[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?\z/, value)

  defp dns_label?(_value), do: false

  defp port(value) when byte_size(value) in 1..5 do
    if Regex.match?(~r/\A[1-9][0-9]*\z/, value) do
      case String.to_integer(value) do
        port when port <= 65_535 -> {:ok, port}
        _invalid -> :invalid
      end
    else
      :invalid
    end
  end

  defp port(_value), do: :invalid

  defp path(value) do
    canonical = String.trim_trailing(value, "/")

    case canonical do
      "" ->
        {:ok, ""}

      "/" <> segments ->
        if Enum.all?(:binary.split(segments, "/", [:global]), &path_segment?/1),
          do: {:ok, canonical},
          else: :invalid
    end
  end

  defp path_segment?(value),
    do: value not in ["", ".", ".."] and Regex.match?(~r/\A[A-Za-z0-9._~-]+\z/, value)

  defp default_port("http"), do: 80
  defp default_port("https"), do: 443

  defp effective_port(%URI{scheme: "http", port: nil}), do: 80
  defp effective_port(%URI{scheme: "https", port: nil}), do: 443
  defp effective_port(%URI{port: port}), do: port

  defp endpoint(:ollama, :ollama_chat_completions), do: {:ok, "/chat/completions"}
  defp endpoint(:openrouter, :openrouter_chat_completions), do: {:ok, "/chat/completions"}
  defp endpoint(:openai, :openai_chat_completions), do: {:ok, "/chat/completions"}
  defp endpoint(:openai, :openai_responses), do: {:ok, "/responses"}
  defp endpoint(:anthropic, :anthropic_messages), do: {:ok, "/v1/messages"}
  defp endpoint(_provider, _surface), do: :invalid

  defp plan_matches?(provider, surface, request) when provider in [:anthropic, :openai] do
    case request.private do
      %{req_llm_request_plan: %{surface: ^surface}} -> true
      _missing_or_changed -> false
    end
  end

  defp plan_matches?(_provider, _surface, _request), do: true
end
