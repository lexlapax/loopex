defmodule Loopex.LLM.ReqLLM.OneShotHTTP1 do
  @moduledoc """
  ## Concept

  Send one model request through the owner's exact HTTP/1 worker and return only
  after the owner proves its tagged pool subtree gone.

  ## Technical depth

  The final Req route and closed transport options are checked before claiming
  dispatch. Only the credential-free route, retained fingerprint and planned
  surface reach the monitored owner. Its correlated grant supplies the recorded
  worker PID; no Finch pool lookup or replacement path is used. The owner owns
  the deadline. Claim and teardown waits use 1,000 ms slices without introducing
  an independent success timeout. Every failure with a valid owner context joins
  teardown, including validation refusal and a raised direct pool call.

  The response collector retains at most 8,388,608 identity-encoded body bytes.
  Overflow and content encoding use fixed private transport sentinels. Other
  dependency failures become fixed exceptions without carrying their causes.
  Req-only owner context never enters Finch telemetry. It remains only in the
  returned Req request so another invocation reaches the owner's one-use fence.
  """

  alias Loopex.LLM.ReqLLM.InProcess.Route

  @max_body 8_388_608
  @surface_atoms [:anthropic_messages, :openai_chat_completions, :openai_responses]
  @routing_options [
    :plug,
    :connect_options,
    :proxy,
    :proxy_headers,
    :hostname,
    :protocols,
    :transport_opts,
    :client_settings,
    :inet6,
    :pool_max_idle_time,
    :unix_socket,
    :finch_request,
    :pool_strategy,
    :pool_tag,
    :pool_timeout,
    :conn_opts,
    :conn_max_idle_time,
    :size,
    :count,
    :start_pool_metrics?
  ]

  @doc """
  ## Concept

  Execute the final admitted Req request through one owner-authorized worker.

  ## Technical depth

  The private context is exactly `finch_private: %{loopex_one_shot:
  {owner_pid, reference_tag, fingerprint}}`. The owner sees neither the Req
  request nor headers, body or credential. Replies bind the request reference
  and tag. A refused claim or lost owner never causes another network dispatch.
  Provider request-id capture stays in this caller's process dictionary under
  `{Loopex.LLM.ReqLLM.InProcess, :response_headers, tag}` for caller-owned removal.
  """
  def run(%Req.Request{} = request) do
    case context(request) do
      {:ok, owner, tag, fingerprint} ->
        monitor = Process.monitor(owner)

        try do
          result = guarded_dispatch(request, owner, monitor, tag, fingerprint)

          case if(result == :owner_down, do: :owner_down, else: teardown(owner, monitor, tag)) do
            :ok ->
              capture_header(result, fingerprint, tag)
              {request, result}

            :owner_down ->
              {request, failed()}
          end
        after
          Process.demonitor(monitor, [:flush])
        end

      :invalid ->
        {request, refused()}
    end
  end

  defp guarded_dispatch(request, owner, monitor, tag, fingerprint) do
    with {:ok, timeout} <- validate(request, tag, fingerprint),
         {:ok, worker} <- claim(owner, monitor, tag, fingerprint, request) do
      transport(request, worker, tag, timeout)
    else
      :owner_down -> :owner_down
      _refused -> refused()
    end
  rescue
    _error -> failed()
  catch
    _class, _reason -> failed()
  end

  defp context(%Req.Request{options: options}) when is_map(options) do
    case options[:finch_private] do
      %{loopex_one_shot: {owner, tag, fingerprint}}
      when is_pid(owner) and is_reference(tag) and is_map(fingerprint) ->
        {:ok, owner, tag, fingerprint}

      _invalid ->
        :invalid
    end
  end

  defp context(_request), do: :invalid

  defp validate(
         %Req.Request{adapter: __MODULE__, into: nil, async: nil} = request,
         tag,
         fingerprint
       ) do
    options = request.options
    finch = options[:finch]

    with true <- Route.matches?(fingerprint, request),
         true <- map_size(options[:finch_private]) == 1,
         true <- Map.get(options, :into) == nil,
         true <- options[:receive_timeout] == :infinity,
         true <- Map.get(options, :request_timeout, :infinity) == :infinity,
         true <- options[:max_retries] == 0 and options[:redirect] == false,
         true <- Map.get(options, :compressed, false) == false,
         true <- Map.get(options, :compress_body, false) == false,
         false <- Enum.any?(@routing_options, &Map.has_key?(options, &1)),
         true <- Keyword.keyword?(finch),
         true <- Enum.sort(Keyword.keys(finch)) == [:name, :pool_tag, :pool_timeout],
         true <- finch[:name] == Req.Finch and finch[:pool_tag] == tag,
         timeout when is_integer(timeout) and timeout in 1..1_000 <- finch[:pool_timeout],
         true <- Req.Request.get_header(request, "accept-encoding") in [[], ["identity"]],
         true <- Req.Request.get_header(request, "content-encoding") == [],
         true <- encoded_body?(request.body) do
      {:ok, timeout}
    else
      _invalid -> :invalid
    end
  end

  defp validate(_request, _tag, _fingerprint), do: :invalid

  defp encoded_body?(nil), do: true

  defp encoded_body?(body) when is_binary(body) or is_list(body) do
    _size = :erlang.iolist_size(body)
    true
  rescue
    _error -> false
  end

  defp encoded_body?(_body), do: false

  defp claim(owner, monitor, tag, fingerprint, request) do
    reference = make_ref()
    uri = request.url

    route = %{
      method: request.method,
      scheme: uri.scheme,
      host: uri.host,
      effective_port: uri.port || if(uri.scheme == "https", do: 443, else: 80),
      path: uri.path,
      query: uri.query
    }

    surface = observed_surface(request)
    send(owner, {:loopex_one_shot_claim, self(), reference, tag, fingerprint, route, surface})
    await_grant(owner, monitor, reference, tag)
  end

  defp observed_surface(request) do
    case request.private do
      %{req_llm_request_plan: %{surface: surface}} when surface in @surface_atoms -> surface
      _absent -> nil
    end
  end

  defp await_grant(owner, monitor, reference, tag) do
    receive do
      {:loopex_one_shot_grant, ^reference, ^tag, worker} when is_pid(worker) -> {:ok, worker}
      {:loopex_one_shot_grant, ^reference, ^tag, _invalid} -> :refused
      {:loopex_one_shot_refused, ^reference, ^tag} -> :refused
      {:DOWN, ^monitor, :process, ^owner, _reason} -> :owner_down
    after
      1_000 -> await_grant(owner, monitor, reference, tag)
    end
  end

  defp teardown(owner, monitor, tag) do
    reference = make_ref()
    send(owner, {:loopex_one_shot_teardown, self(), reference, tag})
    await_teardown(owner, monitor, reference, tag)
  end

  defp await_teardown(owner, monitor, reference, tag) do
    receive do
      {:loopex_one_shot_torn_down, ^reference, ^tag} -> :ok
      {:DOWN, ^monitor, :process, ^owner, _reason} -> :owner_down
    after
      1_000 -> await_teardown(owner, monitor, reference, tag)
    end
  end

  defp transport(request, worker, tag, timeout) do
    transport_request = %{
      request
      | into: nil,
        options: Map.delete(request.options, :finch_private)
    }

    headers =
      transport_request
      |> Req.Request.put_header("accept-encoding", "identity")
      |> Map.fetch!(:headers)
      |> Req.Fields.get_list()

    finch = Finch.build(request.method, request.url, headers, request.body, pool_tag: tag)
    accumulator = %{response: Req.Response.new(), chunks: [], bytes: 0, sentinel: nil}

    case Finch.HTTP1.Pool.request(worker, finch, accumulator, &collect/2, Req.Finch,
           pool_timeout: timeout,
           receive_timeout: :infinity,
           request_timeout: :infinity
         ) do
      {:ok, %{sentinel: nil} = acc} ->
        %{acc.response | body: acc.chunks |> Enum.reverse() |> IO.iodata_to_binary()}

      {:ok, %{sentinel: sentinel}} ->
        %Req.TransportError{reason: sentinel}

      {:error, _error, %{sentinel: nil}} ->
        failed()

      {:error, _error, %{sentinel: sentinel}} ->
        %Req.TransportError{reason: sentinel}

      _other ->
        failed()
    end
  end

  defp collect({:status, status}, acc), do: {:cont, put_in(acc.response.status, status)}

  defp collect({:headers, headers}, acc) do
    if Enum.any?(headers, fn {key, _value} -> String.downcase(key) == "content-encoding" end) do
      {:halt, %{acc | chunks: [], sentinel: :loopex_response_encoding_unsupported}}
    else
      {:cont,
       put_in(acc.response.headers, Req.Fields.new_without_normalize_with_duplicates(headers))}
    end
  end

  defp collect({:data, data}, acc) when is_binary(data) do
    if acc.bytes + byte_size(data) > @max_body do
      {:halt, %{acc | chunks: [], sentinel: :loopex_response_too_large}}
    else
      {:cont, %{acc | chunks: [data | acc.chunks], bytes: acc.bytes + byte_size(data)}}
    end
  end

  defp collect({:trailers, fields}, acc),
    do:
      {:cont,
       put_in(acc.response.trailers, Req.Fields.new_without_normalize_with_duplicates(fields))}

  defp capture_header(%Req.Response{} = response, %{provider: provider}, tag) do
    header =
      case provider do
        :anthropic -> "request-id"
        :openai -> "x-request-id"
        _local_or_router -> nil
      end

    values = if header, do: Req.Response.get_header(response, header), else: []

    captured =
      case values do
        [value | _rest] when is_binary(value) -> [{header, value}]
        _absent -> []
      end

    Process.put({Loopex.LLM.ReqLLM.InProcess, :response_headers, tag}, captured)
    :ok
  end

  defp capture_header(_failure, _fingerprint, _tag), do: :ok

  defp refused, do: %Req.TransportError{reason: :loopex_one_shot_refused}
  defp failed, do: %Req.TransportError{reason: :loopex_one_shot_failed}
end
