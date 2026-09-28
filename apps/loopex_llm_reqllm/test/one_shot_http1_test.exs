Code.require_file("support/in_process_tls_fixture.ex", __DIR__)

defmodule Loopex.LLM.ReqLLM.OneShotHTTP1Test do
  use ExUnit.Case, async: false

  alias Loopex.LLM.ReqLLM.InProcess.Route
  alias Loopex.LLM.ReqLLM.OneShotHTTP1

  setup do
    {:ok, _} = Application.ensure_all_started(:req_llm)
    :ok
  end

  test "real TLS verifies fixture trust and hostname in a separate VM" do
    {output, status} = Loopex.LLM.ReqLLM.InProcessTLSFixture.run_in_child()
    assert status == 0, output
    assert output =~ "TLS_FIXTURE_VERIFIED"
  end

  test "TLS 1.2 positive control resumes but two one-shot calls do not" do
    {output, status} = Loopex.LLM.ReqLLM.InProcessTLSFixture.run_resumption_in_child(:tls12)
    assert status == 0, output
    assert output =~ "TLS_tls12_NO_RESUMPTION_VERIFIED"
  end

  test "TLS 1.3 manual-ticket positive control resumes but two one-shot calls do not" do
    {output, status} = Loopex.LLM.ReqLLM.InProcessTLSFixture.run_resumption_in_child(:tls13)
    assert status == 0, output
    assert output =~ "TLS_tls13_NO_RESUMPTION_VERIFIED"
  end

  test "TLS cache probe survives actual roleless client recovery" do
    {output, status} = Loopex.LLM.ReqLLM.InProcessTLSFixture.run_cache_recovery_in_child()
    assert status == 0, output
    assert output =~ "TLS_CACHE_ROLELESS_RECOVERY_VERIFIED"
  end

  test "one real HTTP dispatch uses the recorded worker and waits for subtree teardown" do
    fixture = fixture("response", hold_teardown: true)
    request = request(fixture, String.duplicate("q", 70_000))
    test = self()
    caller = spawn(fn -> send(test, {:result, OneShotHTTP1.run(request)}) end)
    assert_receive {:claimed, _, payload}

    assert Map.keys(payload) |> Enum.sort() == [
             :effective_port,
             :host,
             :method,
             :path,
             :query,
             :scheme
           ]

    assert_receive {:http_write, _, written}, 2_000
    assert written.body == String.duplicate("q", 70_000)
    assert written.headers["accept-encoding"] == "identity"
    assert_receive {:teardown_pending, owner, reference}, 2_000
    assert Process.alive?(fixture.worker)
    refute_receive {:result, _}, 1_100
    send(caller, {:loopex_one_shot_torn_down, make_ref(), fixture.tag})
    refute_receive {:result, _}, 20
    send(owner, {:allow_teardown, reference})
    assert_receive {:result, {^request, %Req.Response{body: "response"}}}, 2_000
    assert_receive {:http_eof, _}, 2_000
    assert_gone(fixture)
  end

  test "a second invocation reaches the fence without a second write or recreated pool" do
    fixture = fixture("once")
    request = request(fixture)
    assert {returned, %Req.Response{body: "once"}} = OneShotHTTP1.run(request)
    assert returned.options[:finch_private] == request.options[:finch_private]
    assert returned.into == request.into
    assert {_, %Req.TransportError{reason: :loopex_one_shot_refused}} = OneShotHTTP1.run(returned)
    assert_receive {:http_write, _, _}
    refute_receive {:http_write, _, _}, 100
    assert_gone(fixture)
  end

  test "Finch telemetry receives no private owner context" do
    fixture = fixture("telemetry")
    observer = self()
    handler = make_ref()

    :ok =
      :telemetry.attach(
        handler,
        [:finch, :send, :start],
        fn _, _, metadata, _ ->
          send(observer, {:finch_request, metadata.request})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)
    assert {_, %Req.Response{}} = OneShotHTTP1.run(request(fixture))
    assert_receive {:finch_request, finch}
    assert finch.pool_tag == fixture.tag
    assert finch.private == %{}
    refute inspect(finch.private) =~ inspect(fixture.owner)
    assert_gone(fixture)
  end

  test "every final routing option substitution refuses before a write and joins teardown" do
    substitutions = [
      {:plug, nil},
      {:into, :self},
      {:connect_options, []},
      {:proxy, nil},
      {:proxy_headers, []},
      {:hostname, "other"},
      {:protocols, [:http2]},
      {:transport_opts, []},
      {:client_settings, []},
      {:inet6, false},
      {:pool_max_idle_time, :infinity},
      {:unix_socket, "/tmp/not-used"},
      {:finch_request, nil},
      {:pool_strategy, :random},
      {:pool_tag, :default},
      {:pool_timeout, 1},
      {:conn_opts, []},
      {:conn_max_idle_time, :infinity},
      {:size, 1},
      {:count, 1},
      {:start_pool_metrics?, false},
      {:compressed, true},
      {:compress_body, true},
      {:receive_timeout, 1},
      {:request_timeout, 1},
      {:redirect, true},
      {:max_retries, 1}
    ]

    for {key, value} <- substitutions do
      fixture = fixture("never")
      original = request(fixture)
      changed = %{original | options: Map.put(original.options, key, value)}

      assert {^changed, %Req.TransportError{reason: :loopex_one_shot_refused}} =
               OneShotHTTP1.run(changed)

      refute_receive {:http_write, _, _}, 10
      assert_gone(fixture)
    end
  end

  test "closed nested Finch options, streaming bodies and compression headers refuse" do
    for mutate <- [
          fn r ->
            put_in(r.options.finch, name: Req.Finch, pool_tag: r.options.finch[:pool_tag])
          end,
          fn r ->
            put_in(r.options.finch,
              name: Req.Finch,
              pool_tag: r.options.finch[:pool_tag],
              pool_timeout: 0
            )
          end,
          fn r ->
            put_in(r.options.finch,
              name: Req.Finch,
              pool_tag: r.options.finch[:pool_tag],
              pool_timeout: 1001
            )
          end,
          fn r -> put_in(r.options.finch, Keyword.put(r.options.finch, :name, ReqLLM.Finch)) end,
          fn r ->
            put_in(r.options.finch, Keyword.put(r.options.finch, :pool_tag, make_ref()))
          end,
          fn r -> put_in(r.options.finch, r.options.finch ++ [pool_timeout: 1]) end,
          fn r -> put_in(r.options.finch, r.options.finch ++ [unix_socket: "/tmp/not-used"]) end,
          fn r -> %{r | body: Stream.map(["a"], & &1)} end,
          fn r -> %{r | body: fn _ -> :done end} end,
          fn r -> %{r | body: [self()]} end,
          fn r -> %{r | into: fn _, acc -> {:cont, acc} end} end,
          fn r -> %{r | adapter: Req.Finch} end,
          fn r -> Req.Request.put_header(r, "accept-encoding", "gzip") end,
          fn r -> Req.Request.put_header(r, "content-encoding", "gzip") end,
          fn r ->
            put_in(r.options.finch_private, Map.put(r.options.finch_private, :extra, true))
          end
        ] do
      fixture = fixture("never")
      changed = mutate.(request(fixture))

      assert {_, %Req.TransportError{reason: :loopex_one_shot_refused}} =
               OneShotHTTP1.run(changed)

      assert_gone(fixture)
      refute_receive {:http_write, _, _}, 10
    end
  end

  test "a same-origin route substitution refuses before claim and still tears down" do
    fixture = fixture("never")
    original = request(fixture)
    changed = %{original | url: %{original.url | path: "/other"}}
    assert {_, %Req.TransportError{reason: :loopex_one_shot_refused}} = OneShotHTTP1.run(changed)
    refute_receive {:claimed, _, _}, 10
    assert_gone(fixture)
  end

  test "every final route component remains bound to the retained fingerprint" do
    for mutate <- [
          fn r -> %{r | method: :get} end,
          fn r -> %{r | url: %{r.url | scheme: "https"}} end,
          fn r -> %{r | url: %{r.url | host: "localhost"}} end,
          fn r -> %{r | url: %{r.url | port: 1}} end,
          fn r -> %{r | url: %{r.url | query: "key=fixture"}} end,
          fn r -> %{r | url: %{r.url | fragment: "fragment"}} end,
          fn r -> %{r | url: %{r.url | userinfo: "fixture"}} end
        ] do
      fixture = fixture("never")

      assert {_, %Req.TransportError{reason: :loopex_one_shot_refused}} =
               OneShotHTTP1.run(mutate.(request(fixture)))

      refute_receive {:claimed, _, _}, 10
      assert_gone(fixture)
    end
  end

  test "OpenAI final planner metadata cannot substitute its retained surface" do
    for private <- [
          %{},
          %{req_llm_request_plan: nil},
          %{req_llm_request_plan: %{surface: :openai_chat_completions}}
        ] do
      fixture = fixture("never")
      base = String.replace_prefix(fixture.base, "http:", "https:")
      {:ok, fingerprint} = Route.fingerprint(:openai, :openai_responses, base)
      changed = %{request(fixture) | url: URI.parse(base <> "/responses"), private: private}

      changed =
        put_in(
          changed.options.finch_private,
          %{loopex_one_shot: {fixture.owner, fixture.tag, fingerprint}}
        )

      assert {_, %Req.TransportError{reason: :loopex_one_shot_refused}} =
               OneShotHTTP1.run(changed)

      refute_receive {:claimed, _, _}, 10
      assert_gone(fixture)
    end
  end

  test "Req transient retry and redirect steps cannot send a second request" do
    for status <- [307, 429, 500, 529] do
      fixture =
        fixture("one response",
          status: status,
          headers: [{"location", "http://127.0.0.1:1/replacement"}, {"retry-after", "0"}]
        )

      request =
        Req.new(
          method: :post,
          url: fixture.base <> "/chat/completions",
          body: "{}",
          adapter: OneShotHTTP1,
          headers: [{"accept-encoding", "identity"}],
          compressed: false,
          receive_timeout: :infinity,
          request_timeout: :infinity,
          redirect: false,
          retry: :transient,
          max_retries: 0,
          finch: [name: Req.Finch, pool_tag: fixture.tag, pool_timeout: 1_000],
          finch_private: %{loopex_one_shot: {fixture.owner, fixture.tag, fixture.fingerprint}}
        )

      assert {:ok, %Req.Response{status: ^status}} = Req.request(request)
      assert_receive {:http_write, _, _}
      refute_receive {:http_write, _, _}, 20
      assert_gone(fixture)
    end
  end

  test "fixed-length and chunked bodies admit the exact limit and halt at the next byte" do
    for chunked <- [false, true], extra <- [0, 1] do
      fixture = fixture(String.duplicate("a", 8_388_608 + extra), chunked: chunked)
      {_returned, result} = OneShotHTTP1.run(request(fixture))

      if extra == 0 do
        assert %Req.Response{body: body} = result
        assert byte_size(body) == 8_388_608
      else
        assert %Req.TransportError{reason: :loopex_response_too_large} = result
      end

      assert_gone(fixture)
    end
  end

  test "content-encoded responses halt before returning body data" do
    for encoding <- ["gzip", "identity"] do
      fixture = fixture("do not decode", headers: [{"content-encoding", encoding}])

      assert {_, %Req.TransportError{reason: :loopex_response_encoding_unsupported}} =
               OneShotHTTP1.run(request(fixture))

      assert_gone(fixture)
    end
  end

  test "owner loss during claim returns fixed failure without redispatch" do
    fixture = fixture("never", drop_claim: true)

    assert {_, %Req.TransportError{reason: :loopex_one_shot_failed}} =
             OneShotHTTP1.run(request(fixture))

    refute_receive {:http_write, _, _}, 10
    assert_gone(fixture)
  end

  test "claim waits remain sliced without imposing an independent success timeout" do
    fixture = fixture("after grant", hold_claim: true)
    test = self()
    caller = spawn(fn -> send(test, {:delayed_result, OneShotHTTP1.run(request(fixture))}) end)
    assert_receive {:claim_pending, owner, reference}, 2_000
    refute_receive {:http_write, _, _}, 1_100
    refute_receive {:delayed_result, _}, 10
    assert Process.alive?(caller)
    send(owner, {:allow_claim, reference})
    assert_receive {:delayed_result, {_, %Req.Response{body: "after grant"}}}, 2_000
    assert_gone(fixture)
  end

  test "owner loss after transport withholds the successful response" do
    fixture = fixture("must not publish", drop_teardown: true)

    assert {_, %Req.TransportError{reason: :loopex_one_shot_failed}} =
             OneShotHTTP1.run(request(fixture))

    assert_receive {:http_write, _, _}
    refute_receive {:http_write, _, _}, 20
    assert_gone(fixture)
  end

  test "a real peer disconnect becomes a fixed exception after teardown" do
    fixture = fixture("", disconnect: true)

    assert {_, %Req.TransportError{reason: :loopex_one_shot_failed}} =
             OneShotHTTP1.run(request(fixture))

    assert_receive {:http_write, _, _}
    refute_receive {:http_write, _, _}, 20
    assert_gone(fixture)
  end

  test "the recorded dead worker cannot dispatch through its replacement" do
    fixture = fixture("never", dead_grant: true)

    assert {_, %Req.TransportError{reason: :loopex_one_shot_failed}} =
             OneShotHTTP1.run(request(fixture))

    assert_receive {:replacement_worker, replacement}
    assert replacement != fixture.worker
    refute_receive {:http_write, _, _}, 50
    assert_gone(fixture)
  end

  test "ReqLLM decoding follows the response only after the owned pool is gone" do
    body =
      Jason.encode!(%{
        "id" => "fixture",
        "model" => "fixture",
        "choices" => [
          %{
            "finish_reason" => "stop",
            "message" => %{"role" => "assistant", "content" => "decoded"}
          }
        ]
      })

    fixture =
      fixture(body,
        headers: [{"content-type", "application/json"}, {"x-request-id", "ignored-local-id"}]
      )

    {:ok, model} = ReqLLM.model(%{provider: :ollama, id: "fixture", base_url: fixture.base})

    options = [
      max_tokens: 32,
      tools: [],
      total_timeout: :infinity,
      receive_timeout: :infinity,
      max_retries: 0,
      base_url: fixture.base,
      req_http_options: [
        adapter: OneShotHTTP1,
        redirect: false,
        finch: [name: Req.Finch, pool_tag: fixture.tag, pool_timeout: 1_000],
        finch_private: %{loopex_one_shot: {fixture.owner, fixture.tag, fixture.fingerprint}}
      ]
    ]

    assert {:ok, response} = ReqLLM.generate_text(model, "decode", options)
    assert ReqLLM.Response.text(response) == "decoded"
    assert Process.delete({Loopex.LLM.ReqLLM.InProcess, :response_headers, fixture.tag}) == []
    assert_gone(fixture)
  end

  defp fixture(body, options \\ []) do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, packet: :raw, reuseaddr: true])
    {:ok, {_, port}} = :inet.sockname(listener)
    test = self()
    server = spawn(fn -> accept(listener, test, body, options) end)
    base = "http://127.0.0.1:#{port}/v1"
    tag = make_ref()
    {:ok, fingerprint} = Route.fingerprint(:ollama, :ollama_chat_completions, base)
    owner = spawn(fn -> owner_start(test, base, tag, options) end)
    assert_receive {:owner_ready, ^owner, root, pool_supervisor, worker, pool_key}, 2_000

    on_exit(fn ->
      :gen_tcp.close(listener)
      Process.exit(server, :kill)
      if Process.alive?(owner), do: send(owner, :stop_fixture)
    end)

    %{
      owner: owner,
      root: root,
      pool_supervisor: pool_supervisor,
      worker: worker,
      tag: tag,
      pool_key: pool_key,
      base: base,
      fingerprint: fingerprint
    }
  end

  defp request(fixture, body \\ "{}") do
    %Req.Request{
      method: :post,
      url: URI.parse(fixture.base <> "/chat/completions"),
      adapter: OneShotHTTP1,
      body: body,
      options: %{
        receive_timeout: :infinity,
        max_retries: 0,
        redirect: false,
        finch: [name: Req.Finch, pool_tag: fixture.tag, pool_timeout: 1_000],
        finch_private: %{loopex_one_shot: {fixture.owner, fixture.tag, fixture.fingerprint}}
      }
    }
  end

  defp owner_start(test, base, tag, options) do
    Process.flag(:trap_exit, true)
    pool = Finch.Pool.new(base, tag: tag)
    key = Finch.Pool.to_name(pool)

    spec =
      Finch.Pool.child_spec(
        finch: Req.Finch,
        pool: pool,
        protocols: [:http1],
        size: 1,
        count: 1,
        start_pool_metrics?: false
      )

    {_, _, [{{:via, Registry, {_, ^key, {Finch.HTTP1.Pool, 1, expected}}}, _}]} = spec.start
    {:ok, root} = DynamicSupervisor.start_link(strategy: :one_for_one)
    {:ok, pool_supervisor} = DynamicSupervisor.start_child(root, spec)
    [{1, worker, :worker, [Finch.HTTP1.Pool]}] = Supervisor.which_children(pool_supervisor)
    send(test, {:owner_ready, self(), root, pool_supervisor, worker, key})

    owner_loop(%{
      test: test,
      root: root,
      pool_supervisor: pool_supervisor,
      worker: worker,
      key: key,
      expected: expected,
      tag: tag,
      claimed: false,
      options: options,
      cleaned: false
    })
  end

  defp owner_loop(state) do
    receive do
      {:loopex_one_shot_claim, caller, reference, tag, _fingerprint, route, _surface}
      when tag == state.tag ->
        send(state.test, {:claimed, self(), route})

        if state.claimed or not exact_pool?(state) do
          send(caller, {:loopex_one_shot_refused, reference, tag})
          owner_loop(state)
        else
          cond do
            state.options[:drop_claim] ->
              cleanup(state)

            state.options[:dead_grant] ->
              :ok = Supervisor.terminate_child(state.pool_supervisor, 1)
              {:ok, replacement} = Supervisor.restart_child(state.pool_supervisor, 1)
              send(state.test, {:replacement_worker, replacement})
              send(caller, {:loopex_one_shot_grant, reference, tag, state.worker})
              owner_loop(%{state | claimed: true})

            true ->
              if state.options[:hold_claim] do
                send(state.test, {:claim_pending, self(), reference})

                receive do
                  {:allow_claim, ^reference} -> :ok
                end
              end

              send(caller, {:loopex_one_shot_grant, reference, tag, state.worker})
              owner_loop(%{state | claimed: true})
          end
        end

      {:loopex_one_shot_teardown, caller, reference, tag} when tag == state.tag ->
        if state.options[:hold_teardown] == true and not state.cleaned do
          send(state.test, {:teardown_pending, self(), reference})

          receive do
            {:allow_teardown, ^reference} -> :ok
          end
        end

        cleanup(state)

        unless state.options[:drop_teardown] do
          send(caller, {:loopex_one_shot_torn_down, reference, tag})
          owner_loop(%{state | cleaned: true})
        end

      :stop_fixture ->
        cleanup(state)

      {:EXIT, _, _} ->
        owner_loop(state)
    end
  end

  defp exact_pool?(state) do
    Process.alive?(state.worker) and
      Supervisor.which_children(state.pool_supervisor) == [
        {1, state.worker, :worker, [Finch.HTTP1.Pool]}
      ] and
      Registry.lookup(Req.Finch, state.key) == [{state.worker, Finch.HTTP1.Pool}] and
      Registry.lookup(Req.Finch.SupervisorRegistry, state.key) == [
        {state.pool_supervisor, {Finch.HTTP1.Pool, 1, state.expected}}
      ]
  end

  defp cleanup(state) do
    if Process.alive?(state.root), do: Supervisor.stop(state.root, :normal)
    await_registry_removal(state.key, System.monotonic_time(:millisecond) + 1_000)
    :ok
  end

  defp await_registry_removal(key, deadline) do
    if Registry.lookup(Req.Finch, key) != [] or
         Registry.lookup(Req.Finch.SupervisorRegistry, key) != [] do
      assert System.monotonic_time(:millisecond) < deadline

      receive do
      after
        1 -> await_registry_removal(key, deadline)
      end
    end
  end

  defp assert_gone(fixture) do
    refute Process.alive?(fixture.worker)
    refute Process.alive?(fixture.pool_supervisor)
    refute Process.alive?(fixture.root)
    assert Registry.lookup(Req.Finch, fixture.pool_key) == []
    assert Registry.lookup(Req.Finch.SupervisorRegistry, fixture.pool_key) == []
  end

  defp accept(listener, test, body, options) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        {headers, received} = read_request(socket, "")
        send(test, {:http_write, self(), %{headers: headers, body: received}})

        if options[:disconnect] do
          :gen_tcp.close(socket)
        else
          fields =
            Enum.map(options[:headers] || [], fn {key, value} -> [key, ": ", value, "\r\n"] end)

          framing =
            if options[:chunked],
              do: "transfer-encoding: chunked\r\n",
              else: "content-length: #{byte_size(body)}\r\n"

          status = options[:status] || 200
          :gen_tcp.send(socket, ["HTTP/1.1 #{status} Fixture\r\n", fields, framing, "\r\n"])

          payload =
            if options[:chunked],
              do: [Integer.to_string(byte_size(body), 16), "\r\n", body, "\r\n0\r\n\r\n"],
              else: body

          :gen_tcp.send(socket, payload)
          drain(socket)
        end

        send(test, {:http_eof, self()})
        :gen_tcp.close(socket)
        accept(listener, test, body, options)

      {:error, reason} when reason in [:closed, :einval] ->
        :ok
    end
  end

  defp read_request(socket, bytes) do
    case :binary.split(bytes, "\r\n\r\n") do
      [head, rest] ->
        [_line | fields] = String.split(head, "\r\n")

        headers =
          Map.new(fields, fn field ->
            [key, value] = String.split(field, ":", parts: 2)
            {String.downcase(key), String.trim(value)}
          end)

        length = String.to_integer(headers["content-length"] || "0")
        {headers, read_body(socket, rest, length)}

      [_partial] ->
        {:ok, chunk} = :gen_tcp.recv(socket, 0, 2_000)
        read_request(socket, bytes <> chunk)
    end
  end

  defp read_body(_socket, bytes, length) when byte_size(bytes) >= length,
    do: binary_part(bytes, 0, length)

  defp read_body(socket, bytes, length) do
    {:ok, chunk} = :gen_tcp.recv(socket, 0, 2_000)
    read_body(socket, bytes <> chunk, length)
  end

  defp drain(socket) do
    case :gen_tcp.recv(socket, 0, 1_000) do
      {:error, :closed} -> :ok
      _waiting -> drain(socket)
    end
  end
end
