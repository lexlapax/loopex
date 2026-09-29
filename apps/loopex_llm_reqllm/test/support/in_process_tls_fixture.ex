defmodule Loopex.LLM.ReqLLM.InProcessTLSFixture do
  @moduledoc """
  ## Concept

  Exercise verified model TLS using generated fixture certificates in a fresh VM.

  ## Technical depth

  OTP's test-data API supplies the fixture CA and localhost server certificate.
  Only the child VM loads that CA. Mint's ordinary peer and hostname verification
  and the exact production retention options remain enabled. The fixture owner
  grants its recorded HTTP/1 worker once and acknowledges only after its pool
  subtree and registry entries are gone. No provider credential is used.
  """

  import ExUnit.Assertions
  alias Loopex.LLM.ReqLLM.InProcess.Route
  alias Loopex.LLM.ReqLLM.OneShotHTTP1

  @retention [reuse_sessions: false, session_tickets: :disabled, keep_secrets: false]

  @doc """
  ## Concept

  Run the verified-TLS witnesses without changing this VM's trusted CA set.

  ## Technical depth

  The child explicitly requires this support source and uses the test build's
  code paths. Its fixed success marker is emitted only after all real TLS calls
  and teardown assertions pass; a nonzero exit is evidence failure.
  """
  def run_in_child do
    System.cmd(
      System.find_executable("elixir"),
      [
        "-pa",
        Path.join([Mix.Project.build_path(), "lib", "*", "ebin"]),
        "-r",
        __ENV__.file,
        "-e",
        "Loopex.LLM.ReqLLM.InProcessTLSFixture.probe()",
        "--",
        "--loopex-tls-fixture"
      ],
      stderr_to_stdout: true
    )
  end

  def run_resumption_in_child(protocol) when protocol in [:tls12, :tls13] do
    run_probe_in_child("resumption_probe()", "--loopex-tls-#{protocol}")
  end

  def run_cache_recovery_in_child do
    run_probe_in_child("cache_recovery_probe()", "--loopex-tls-cache-recovery")
  end

  defp run_probe_in_child(entry, marker) do
    System.cmd(
      System.find_executable("elixir"),
      [
        "-pa",
        Path.join([Mix.Project.build_path(), "lib", "*", "ebin"]),
        "-r",
        Path.expand("tls_session_cache_probe.ex", __DIR__),
        "-r",
        __ENV__.file,
        "-e",
        "Loopex.LLM.ReqLLM.InProcessTLSFixture.#{entry}",
        "--",
        marker
      ],
      stderr_to_stdout: true
    )
  end

  @doc """
  ## Concept

  Verify a real TLS response, provider header selection and peer rejection.

  ## Technical depth

  This entry point requires the fixture child argument before loading its CA.
  Each request owns a new tagged user-managed pool with the complete fixed
  configuration. Untrusted certificates and a mismatched hostname must fail
  before an HTTP write. Test-data APIs are available since OTP 20.1.
  """
  def probe do
    assert System.argv() == ["--loopex-tls-fixture"]
    {:ok, _} = Application.ensure_all_started(:req_llm)
    trusted = certificate()
    directory = Path.join(System.tmp_dir!(), "loopex-tls-#{System.unique_integer([:positive])}")
    File.mkdir!(directory)

    try do
      ca_path = Path.join(directory, "ca.pem")

      pem =
        :public_key.pem_encode(Enum.map(trusted[:cacerts], &{:Certificate, &1, :not_encrypted}))

      File.write!(ca_path, pem)
      :ok = :public_key.cacerts_load(String.to_charlist(ca_path))

      for {provider, surface, endpoint, selected} <- [
            {:openai, :openai_chat_completions, "/chat/completions", "x-request-id"},
            {:openai, :openai_responses, "/responses", "x-request-id"},
            {:anthropic, :anthropic_messages, "/v1/messages", "request-id"}
          ] do
        fixture = start(trusted, "localhost", provider, surface, endpoint)

        assert {_, %Req.Response{body: "tls response", status: 200}} =
                 OneShotHTTP1.run(fixture.request)

        assert_receive {:tls_write, server, headers}, 2_000
        assert server == fixture.server
        assert headers["authorization"] == "Bearer fixture-secret-only"
        assert headers["accept-encoding"] == "identity"

        assert Process.delete({Loopex.LLM.ReqLLM.InProcess, :response_headers, fixture.tag}) ==
                 [{selected, "fixture-id"}]

        assert_receive {:tls_eof, ^server}, 5_000
        gone(fixture)
        stop(fixture)
      end

      for {cert, hostname} <- [{certificate(), "localhost"}, {trusted, "127.0.0.1"}] do
        fixture = start(cert, hostname, :openai, :openai_responses, "/responses")

        assert {_, %Req.TransportError{reason: :loopex_one_shot_failed}} =
                 OneShotHTTP1.run(fixture.request)

        refute_receive {:tls_write, _, _}, 20
        gone(fixture)
        stop(fixture)
      end

      IO.puts("TLS_FIXTURE_VERIFIED")
    after
      File.rm_rf!(directory)
    end
  end

  @doc """
  ## Concept

  Prove that the fixture server can resume TLS while the production call cannot.

  ## Technical depth

  The positive control and two one-shot production calls share one listener,
  hostname, port and TLS version. Only the server restricts protocol versions.
  The TLS 1.2 control waits for both cache writes before its sole reconnect;
  the TLS 1.3 control uses the exact ticket delivered to its first socket.
  """
  def resumption_probe do
    protocol =
      case System.argv() do
        ["--loopex-tls-tls12"] -> :tls12
        ["--loopex-tls-tls13"] -> :tls13
      end

    nonce = make_ref()
    if protocol == :tls12, do: install_cache_probe(nonce, false)
    {:ok, _} = Application.ensure_all_started(:req_llm)

    with_test_ca(fn trusted ->
      listener = resumption_listener(trusted, protocol)
      {:ok, {_, port}} = :ssl.sockname(listener)

      if protocol == :tls12,
        do: Application.put_env(:ssl, :loopex_tls_probe_target, {"localhost", port})

      test = self()
      server = spawn(fn -> accept_resumption(listener, test) end)

      try do
        case protocol do
          :tls12 -> tls12_control(port, nonce)
          :tls13 -> tls13_control(port)
        end

        assert_handshake(2, true)

        for index <- 3..4 do
          fixture =
            start_request(
              listener,
              port,
              server,
              "localhost",
              :openai,
              :openai_responses,
              "/responses"
            )

          assert {_, %Req.Response{body: "tls response", status: 200}} =
                   OneShotHTTP1.run(fixture.request)

          assert_handshake(index, false)
          gone(fixture)
          send(fixture.owner, :stop)
        end

        assert_receive {:tls_resumption_server_done, ^server}, 5_000
        IO.puts("TLS_#{protocol}_NO_RESUMPTION_VERIFIED")
      after
        :ssl.close(listener)
      end
    end)
  end

  @doc """
  ## Concept

  Prove that the TLS 1.2 cache callback survives OTP's real roleless recovery.

  ## Technical depth

  This separate child VM arms a one-shot client `size/1` fault. A real
  handshake triggers registration and recovery; a second real handshake must
  still install a client session through the reinitialized delegate.
  """
  def cache_recovery_probe do
    assert System.argv() == ["--loopex-tls-cache-recovery"]
    nonce = make_ref()
    install_cache_probe(nonce, true)
    {:ok, _} = Application.ensure_all_started(:req_llm)
    assert_receive {:tls_cache_fault_armed, ^nonce, manager}, 5_000
    assert_receive {:tls_cache_client_init, ^nonce, ^manager, true}, 5_000

    with_test_ca(fn trusted ->
      listener = resumption_listener(trusted, :tls12)
      {:ok, {_, port}} = :ssl.sockname(listener)
      Application.put_env(:ssl, :loopex_tls_probe_target, {"localhost", port})
      test = self()
      server = spawn(fn -> accept_control_only(listener, test, 2) end)

      try do
        mint_control(port)
        assert_handshake(1, false)
        assert_receive {:tls_cache_fault_triggered, ^nonce, ^manager}, 5_000
        assert_receive {:tls_cache_reinit, ^nonce, :client, ^manager}, 5_000
        assert_receive {:tls_cache_client_init, ^nonce, ^manager, false}, 5_000
        mint_control(port)
        assert_handshake(2, false)
        assert_receive {:tls_cache_saved, ^nonce, :client}, 5_000
        assert_receive {:tls_resumption_server_done, ^server}, 5_000
        IO.puts("TLS_CACHE_ROLELESS_RECOVERY_VERIFIED")
      after
        :ssl.close(listener)
      end
    end)
  end

  defp install_cache_probe(nonce, fault) do
    probe = LoopexLLMReqLLMTest.TLSSessionCacheProbe
    Application.put_env(:ssl, :client_session_cb, probe)
    Application.put_env(:ssl, :server_session_cb, probe)

    Application.put_env(:ssl, :client_session_cb_init_args,
      observer: self(),
      nonce: nonce,
      fault: fault
    )

    Application.put_env(:ssl, :server_session_cb_init_args, observer: self(), nonce: nonce)

    if String.to_integer(to_string(:erlang.system_info(:otp_release))) < 29 do
      Application.put_env(:ssl, :session_cb, probe)

      Application.put_env(:ssl, :session_cb_init_args,
        observer: self(),
        nonce: nonce,
        fault: fault
      )
    end
  end

  defp with_test_ca(fun) do
    trusted = certificate()

    directory =
      Path.join(System.tmp_dir!(), "loopex-resumption-#{System.unique_integer([:positive])}")

    File.mkdir!(directory)

    try do
      ca_path = Path.join(directory, "ca.pem")

      pem =
        :public_key.pem_encode(Enum.map(trusted[:cacerts], &{:Certificate, &1, :not_encrypted}))

      File.write!(ca_path, pem)
      :ok = :public_key.cacerts_load(String.to_charlist(ca_path))
      fun.(trusted)
    after
      File.rm_rf!(directory)
    end
  end

  defp resumption_listener(trusted, protocol) do
    options = [
      :binary,
      active: false,
      reuseaddr: true,
      cert: trusted[:cert],
      key: trusted[:key],
      versions: [if(protocol == :tls12, do: :"tlsv1.2", else: :"tlsv1.3")]
    ]

    options = if protocol == :tls13, do: options ++ [session_tickets: :stateful], else: options
    {:ok, listener} = :ssl.listen(0, options)
    listener
  end

  defp tls12_control(port, nonce) do
    mint_control(port)
    assert_handshake(1, false)
    assert_receive {:tls_cache_saved, ^nonce, :client}, 5_000
    assert_receive {:tls_cache_saved, ^nonce, :server}, 5_000
    mint_control(port)
  end

  defp mint_control(port) do
    {:ok, connection} = Mint.HTTP.connect(:https, "localhost", port)
    {:ok, _closed} = Mint.HTTP.close(connection)
  end

  defp tls13_control(port) do
    options = [
      :binary,
      active: true,
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      server_name_indication: ~c"localhost",
      session_tickets: :manual
    ]

    {:ok, first} = :ssl.connect(~c"localhost", port, options, 5_000)
    assert_handshake(1, false)

    ticket =
      receive do
        {:ssl, :session_ticket, value} when is_map(value) -> value
      after
        5_000 -> flunk("TLS 1.3 fixture did not deliver a session ticket")
      end

    :ok = :ssl.close(first)
    {:ok, second} = :ssl.connect(~c"localhost", port, options ++ [use_ticket: [ticket]], 5_000)
    :ok = :ssl.close(second)
  end

  defp assert_handshake(index, expected) do
    assert_receive {:tls_handshake, ^index, ^expected}, 5_000
  end

  defp accept_resumption(listener, test) do
    accept_control_only(listener, test, 4)
  end

  defp accept_control_only(listener, test, count) do
    Enum.reduce(1..count, MapSet.new(), fn index, seen_ids ->
      {:ok, transport} = :ssl.transport_accept(listener, 10_000)
      {:ok, socket} = :ssl.handshake(transport, 10_000)

      {:ok, info} =
        :ssl.connection_information(socket, [:protocol, :session_id, :session_resumption])

      {resumed, next_ids} =
        case Keyword.fetch!(info, :protocol) do
          :"tlsv1.2" ->
            # OTP 27 exposes :session_resumption but does not set it for TLS
            # 1.2. Reusing a nonempty server session ID is the real control.
            session_id = Keyword.fetch!(info, :session_id)
            assert is_binary(session_id) and byte_size(session_id) > 0
            {MapSet.member?(seen_ids, session_id), MapSet.put(seen_ids, session_id)}

          :"tlsv1.3" ->
            {Keyword.fetch!(info, :session_resumption), seen_ids}
        end

      send(test, {:tls_handshake, index, resumed})

      if index >= 3 do
        _headers = read_headers(socket, "")
        :ok = :ssl.send(socket, "HTTP/1.1 200 OK\r\ncontent-length: 12\r\n\r\ntls response")
      end

      assert {:error, :closed} = :ssl.recv(socket, 0, 10_000)
      :ok = :ssl.close(socket)
      next_ids
    end)

    send(test, {:tls_resumption_server_done, self()})
  end

  @doc """
  ## Concept

  Generate fixture-only certificate material for verified localhost TLS tests.

  ## Technical depth

  Returns OTP's `cert`, `key` and `cacerts` configuration without installing a
  CA. P-256 and SHA-256 are explicit: OTP's test-data defaults can choose curves
  or SHA-1 signatures rejected by TLS 1.3. The DNS SAN is exactly localhost.
  """
  def certificate do
    :public_key.pkix_test_data(%{
      root: [key: {:namedCurve, :secp256r1}, digest: :sha256],
      peer: [
        key: {:namedCurve, :secp256r1},
        digest: :sha256,
        extensions: [{:Extension, {2, 5, 29, 17}, false, [{:dNSName, ~c"localhost"}]}]
      ]
    })
  end

  defp start(certificates, hostname, provider, surface, endpoint) do
    {:ok, listener} =
      :ssl.listen(0, [
        :binary,
        active: false,
        reuseaddr: true,
        cert: certificates[:cert],
        key: certificates[:key]
      ])

    {:ok, {_, port}} = :ssl.sockname(listener)
    test = self()
    server = spawn(fn -> accept(listener, test) end)
    start_request(listener, port, server, hostname, provider, surface, endpoint)
  end

  defp start_request(listener, port, server, hostname, provider, surface, endpoint) do
    test = self()
    base = "https://#{hostname}:#{port}"
    tag = make_ref()
    {:ok, fingerprint} = Route.fingerprint(provider, surface, base)
    owner = spawn(fn -> owner(test, base, tag) end)
    assert_receive {:tls_owner_ready, ^owner, root, supervisor, worker, key}, 2_000

    request = %Req.Request{
      method: :post,
      url: URI.parse(base <> endpoint),
      adapter: OneShotHTTP1,
      headers: Req.Fields.new([{"authorization", "Bearer fixture-secret-only"}]),
      body: "{}",
      private: %{req_llm_request_plan: %{surface: surface}},
      options: %{
        receive_timeout: :infinity,
        redirect: false,
        max_retries: 0,
        finch: [name: Req.Finch, pool_tag: tag, pool_timeout: 1_000],
        finch_private: %{loopex_one_shot: {owner, tag, fingerprint}}
      }
    }

    %{
      owner: owner,
      root: root,
      supervisor: supervisor,
      worker: worker,
      key: key,
      listener: listener,
      server: server,
      tag: tag,
      request: request
    }
  end

  defp owner(test, base, tag) do
    Process.flag(:trap_exit, true)
    pool = Finch.Pool.new(base, tag: tag)
    key = Finch.Pool.to_name(pool)

    options = [
      finch: Req.Finch,
      pool: pool,
      protocols: [:http1],
      size: 1,
      count: 1,
      start_pool_metrics?: false,
      conn_opts: [transport_opts: @retention]
    ]

    assert options[:conn_opts] == [transport_opts: @retention]
    spec = Finch.Pool.child_spec(options)
    {_, _, [{{:via, Registry, {_, ^key, {Finch.HTTP1.Pool, 1, expected}}}, _}]} = spec.start
    {:ok, root} = DynamicSupervisor.start_link(strategy: :one_for_one)
    {:ok, supervisor} = DynamicSupervisor.start_child(root, spec)
    [{1, worker, :worker, [Finch.HTTP1.Pool]}] = Supervisor.which_children(supervisor)
    send(test, {:tls_owner_ready, self(), root, supervisor, worker, key})

    receive do
      {:loopex_one_shot_claim, caller, reference, ^tag, _fingerprint, _route, _surface} ->
        assert Registry.lookup(Req.Finch, key) == [{worker, Finch.HTTP1.Pool}]

        assert Registry.lookup(Req.Finch.SupervisorRegistry, key) ==
                 [{supervisor, {Finch.HTTP1.Pool, 1, expected}}]

        assert Supervisor.which_children(supervisor) == [{1, worker, :worker, [Finch.HTTP1.Pool]}]
        send(caller, {:loopex_one_shot_grant, reference, tag, worker})
    end

    receive do
      {:loopex_one_shot_teardown, caller, reference, ^tag} ->
        :ok = Supervisor.stop(root, :normal)
        await_removed(key, System.monotonic_time(:millisecond) + 1_000)
        refute Process.alive?(worker)
        refute Process.alive?(supervisor)
        send(caller, {:loopex_one_shot_torn_down, reference, tag})

        receive do
          :stop -> :ok
        end
    end
  end

  defp await_removed(key, deadline) do
    if Registry.lookup(Req.Finch, key) != [] or
         Registry.lookup(Req.Finch.SupervisorRegistry, key) != [] do
      assert System.monotonic_time(:millisecond) < deadline

      receive do
      after
        1 -> await_removed(key, deadline)
      end
    end
  end

  defp gone(fixture) do
    refute Process.alive?(fixture.worker)
    refute Process.alive?(fixture.supervisor)
    refute Process.alive?(fixture.root)
    assert Registry.lookup(Req.Finch, fixture.key) == []
    assert Registry.lookup(Req.Finch.SupervisorRegistry, fixture.key) == []
  end

  defp stop(fixture) do
    :ssl.close(fixture.listener)
    Process.exit(fixture.server, :kill)
    send(fixture.owner, :stop)
  end

  defp accept(listener, test) do
    case :ssl.transport_accept(listener, 5_000) do
      {:ok, socket} ->
        case :ssl.handshake(socket, 5_000) do
          {:ok, socket} ->
            headers = read_headers(socket, "")
            send(test, {:tls_write, self(), headers})

            :ok =
              :ssl.send(
                socket,
                "HTTP/1.1 200 OK\r\ncontent-length: 12\r\nx-request-id: fixture-id\r\nrequest-id: fixture-id\r\n\r\ntls response"
              )

            assert {:error, :closed} = :ssl.recv(socket, 0, 5_000)
            send(test, {:tls_eof, self()})

          {:error, _verification_refusal} ->
            :ok
        end

      {:error, :closed} ->
        :ok
    end
  end

  defp read_headers(socket, bytes) do
    case :binary.split(bytes, "\r\n\r\n") do
      [head, body] ->
        [_line | fields] = String.split(head, "\r\n")

        headers =
          Map.new(fields, fn field ->
            [key, value] = String.split(field, ":", parts: 2)
            {String.downcase(key), String.trim(value)}
          end)

        await_body(socket, byte_size(body), String.to_integer(headers["content-length"] || "0"))
        headers

      [_partial] ->
        {:ok, chunk} = :ssl.recv(socket, 0, 5_000)
        read_headers(socket, bytes <> chunk)
    end
  end

  defp await_body(_socket, received, length) when received >= length, do: :ok

  defp await_body(socket, received, length) do
    {:ok, chunk} = :ssl.recv(socket, 0, 5_000)
    await_body(socket, received + byte_size(chunk), length)
  end
end
