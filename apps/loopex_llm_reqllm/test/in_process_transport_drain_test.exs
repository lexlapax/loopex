defmodule Loopex.LLM.ReqLLM.InProcessTransportDrainTest do
  use ExUnit.Case, async: false

  alias Loopex.LLM.ReqLLM.InProcess.PoolLifecycle
  alias Loopex.LLM.ReqLLM.InProcess.Route
  alias Loopex.LLM.ReqLLM.OneShotHTTP1

  @drain_ms 5_000

  @tag :long_bound
  test "call-created sockets and TLS controllers drain after caller DOWN" do
    {:ok, _} = Application.ensure_all_started(:req)
    {:ok, _} = Application.ensure_all_started(:ssl)
    {:ok, _} = :inet.gethostbyname(~c"localhost")
    assert is_pid(Process.whereis(Req.Finch))
    assert is_pid(Process.whereis(Req.Finch.SupervisorRegistry))
    ca = trusted_fixture_ca()

    for {transport, tls_version} <-
          [{:http, nil}, {:tls, :"tlsv1.2"}, {:tls, :"tlsv1.3"}],
        mode <- [:normal, :stop, :deadline] do
      run_case(transport, tls_version, mode, ca)
    end
  end

  defp trusted_fixture_ca do
    certificates =
      :public_key.pkix_test_data(%{
        root: [key: {:namedCurve, :secp256r1}, digest: :sha256],
        peer: [
          key: {:namedCurve, :secp256r1},
          digest: :sha256,
          extensions: [{:Extension, {2, 5, 29, 17}, false, [{:dNSName, ~c"localhost"}]}]
        ]
      })

    path = Path.join(System.fetch_env!("LOOPEX_HOME"), "transport-drain-ca.pem")

    pem =
      :public_key.pem_encode(
        Enum.map(certificates[:cacerts], &{:Certificate, &1, :not_encrypted})
      )

    File.write!(path, pem)
    on_exit(fn -> File.rm(path) end)
    :ok = :public_key.cacerts_load(String.to_charlist(path))
    certificates
  end

  defp run_case(transport, tls_version, mode, certificates) do
    fixture = listener(transport, tls_version, mode, certificates)
    tag = make_ref()
    root = start_pool(fixture.base, tag)
    {:ok, fingerprint} = Route.fingerprint(:ollama, :ollama_chat_completions, fixture.base)
    before_processes = MapSet.new(Process.list())
    before_ports = MapSet.new(Port.list())
    test = self()

    request = %Req.Request{
      method: :post,
      url: URI.parse(fixture.base <> "/chat/completions"),
      adapter: OneShotHTTP1,
      body: "{}",
      options: %{
        receive_timeout: :infinity,
        max_retries: 0,
        redirect: false,
        finch: [name: Req.Finch, pool_tag: tag, pool_timeout: 1_000],
        finch_private: %{loopex_one_shot: {test, tag, fingerprint}}
      }
    }

    {caller, caller_monitor} =
      spawn_monitor(fn -> send(test, {:transport_result, self(), OneShotHTTP1.run(request)}) end)

    try do
      assert_receive {:loopex_one_shot_claim, ^caller, claim_ref, ^tag, ^fingerprint, route, nil},
                     2_000

      assert route.host == URI.parse(fixture.base).host
      assert route.path == "/chat/completions"
      send(caller, {:loopex_one_shot_grant, claim_ref, tag, root.worker})
      assert_receive {:drain_request_seen, server, ^mode, ^tls_version}, 2_000
      assert server == fixture.server

      in_flight_processes = process_delta(before_processes)
      in_flight_ports = port_delta(before_ports)
      ports = client_ports(in_flight_ports, fixture.port)
      assert ports != []
      controllers = client_controllers(transport, in_flight_processes, ports)

      if transport == :tls do
        assert controllers != []
      else
        assert controllers == []
      end

      # The anchor precedes the action that can end the caller. A DOWN message
      # can wait in this process's mailbox, so sampling after its receipt would
      # let a transport that drained too late pass this witness.
      {pre_down, result} =
        case mode do
          :normal ->
            pre_down = System.monotonic_time(:millisecond)
            send(server, :respond)
            assert_receive {:loopex_one_shot_teardown, ^caller, teardown_ref, ^tag}, 2_000
            stop_pool(root)
            assert_pool_gone(root)
            send(caller, {:loopex_one_shot_torn_down, teardown_ref, tag})

            assert_receive {:transport_result, ^caller, {^request, %Req.Response{status: 200}}},
                           2_000

            assert_receive {:DOWN, ^caller_monitor, :process, ^caller, :normal}, 2_000
            {pre_down, :completed}

          :stop ->
            pre_down = System.monotonic_time(:millisecond)
            Process.exit(caller, :kill)
            assert_receive {:DOWN, ^caller_monitor, :process, ^caller, :killed}, 2_000
            stop_pool(root)
            assert_pool_gone(root)
            {pre_down, :stopped}

          :deadline ->
            timer = Process.send_after(self(), {:model_deadline, caller}, 25)
            assert_receive {:model_deadline, ^caller}, 1_000
            Process.cancel_timer(timer)
            pre_down = System.monotonic_time(:millisecond)
            Process.exit(caller, :kill)
            assert_receive {:DOWN, ^caller_monitor, :process, ^caller, :killed}, 2_000
            stop_pool(root)
            assert_pool_gone(root)
            {pre_down, :deadline}
        end

      assert_receive {:drain_server_eof, ^server}, @drain_ms
      drained = await_transport_drain(controllers, ports, pre_down + @drain_ms)
      assert drained - pre_down <= @drain_ms

      IO.puts(
        "transport_drain kind=#{transport} tls_version=#{inspect(tls_version)} " <>
          "mode=#{result} pre_down_anchor_ms=#{pre_down} " <>
          "drain_elapsed_ms=#{drained - pre_down} " <>
          "in_flight_processes=#{inspect(in_flight_processes)} " <>
          "in_flight_ports=#{inspect(in_flight_ports)} " <>
          "client_controllers=#{inspect(controllers)} client_ports=#{inspect(ports)} " <>
          "remaining_processes=#{inspect(process_delta(before_processes))} " <>
          "remaining_ports=#{inspect(port_delta(before_ports))} " <>
          "owned_roles=#{inspect(root.roles)}"
      )
    after
      if Process.alive?(caller), do: Process.exit(caller, :kill)
      if Process.alive?(root.pid), do: stop_pool(root)
      close_listener(fixture)
    end
  end

  defp listener(:http, nil, mode, _certificates) do
    {:ok, socket} =
      :gen_tcp.listen(0, [:binary, active: false, packet: :raw, reuseaddr: true])

    {:ok, {_, port}} = :inet.sockname(socket)
    test = self()
    server = spawn(fn -> serve(:http, socket, mode, test) end)
    %{socket: socket, server: server, port: port, base: "http://127.0.0.1:#{port}"}
  end

  defp listener(:tls, tls_version, mode, certificates)
       when tls_version in [:"tlsv1.2", :"tlsv1.3"] do
    {:ok, socket} =
      :ssl.listen(0, [
        :binary,
        active: false,
        reuseaddr: true,
        versions: [tls_version],
        cert: certificates[:cert],
        key: certificates[:key]
      ])

    {:ok, {_, port}} = :ssl.sockname(socket)
    test = self()
    server = spawn(fn -> serve(:tls, socket, mode, test) end)
    %{socket: socket, server: server, port: port, base: "https://localhost:#{port}"}
  end

  defp serve(transport, listener, mode, test) do
    accepted =
      case transport do
        :http -> :gen_tcp.accept(listener, 5_000)
        :tls -> :ssl.transport_accept(listener, 5_000)
      end

    {:ok, socket} = accepted

    socket =
      if transport == :tls do
        {:ok, tls_socket} = :ssl.handshake(socket, 5_000)
        tls_socket
      else
        socket
      end

    negotiated_version =
      if transport == :tls do
        {:ok, information} = :ssl.connection_information(socket, [:protocol])
        Keyword.fetch!(information, :protocol)
      end

    read_request(transport, socket, "")
    send(test, {:drain_request_seen, self(), mode, negotiated_version})

    if mode == :normal do
      receive do
        :respond ->
          :ok =
            send_socket(
              transport,
              socket,
              "HTTP/1.1 200 OK\r\ncontent-length: 2\r\n\r\nok"
            )
      end
    end

    assert {:error, :closed} = recv_socket(transport, socket, 0, 10_000)
    send(test, {:drain_server_eof, self()})
  end

  defp read_request(transport, socket, bytes) do
    case :binary.split(bytes, "\r\n\r\n") do
      [head, body] ->
        length =
          head
          |> String.split("\r\n")
          |> Enum.find_value(0, fn line ->
            case String.split(line, ":", parts: 2) do
              [name, value] ->
                if String.downcase(name) == "content-length",
                  do: String.to_integer(String.trim(value))

              _ ->
                nil
            end
          end)

        if byte_size(body) < length do
          {:ok, chunk} = recv_socket(transport, socket, 0, 5_000)
          read_request(transport, socket, head <> "\r\n\r\n" <> body <> chunk)
        end

      [_partial] ->
        {:ok, chunk} = recv_socket(transport, socket, 0, 5_000)
        read_request(transport, socket, bytes <> chunk)
    end
  end

  defp recv_socket(:http, socket, count, timeout), do: :gen_tcp.recv(socket, count, timeout)
  defp recv_socket(:tls, socket, count, timeout), do: :ssl.recv(socket, count, timeout)
  defp send_socket(:http, socket, bytes), do: :gen_tcp.send(socket, bytes)
  defp send_socket(:tls, socket, bytes), do: :ssl.send(socket, bytes)

  defp close_listener(fixture) do
    case URI.parse(fixture.base).scheme do
      "http" -> :gen_tcp.close(fixture.socket)
      "https" -> :ssl.close(fixture.socket)
    end

    if Process.alive?(fixture.server), do: Process.exit(fixture.server, :kill)
  end

  defp start_pool(base, tag) do
    reference = make_ref()
    deadline = System.monotonic_time() + System.convert_time_unit(10_000, :millisecond, :native)
    test = self()

    {pid, monitor} =
      spawn_monitor(fn ->
        PoolLifecycle.run(%{
          owner: test,
          reference: reference,
          base_url: base,
          tag: tag,
          deadline: deadline
        })
      end)

    send(pid, {:loopex_pool_start, self(), reference})
    await_pool(pid, monitor, reference, %{root: pid})
  end

  defp await_pool(pid, monitor, reference, roles) do
    receive do
      {:loopex_pool_record, ^pid, receipt, entries} ->
        roles =
          Enum.reduce(entries, roles, fn
            {:process, role, process}, acc -> Map.put(acc, role, process)
            {:registry, _, _}, acc -> acc
          end)

        send(pid, {:loopex_pool_recorded, receipt})
        await_pool(pid, monitor, reference, roles)

      {:loopex_pool_ready, ^pid, ^reference, worker, identity} ->
        assert roles.http1_worker == worker
        assert Process.alive?(worker)
        assert Registry.lookup(Req.Finch, identity) == [{worker, Finch.HTTP1.Pool}]
        %{pid: pid, monitor: monitor, worker: worker, identity: identity, roles: roles}

      {:loopex_pool_failed, ^pid, ^reference} ->
        flunk("the tagged pool failed before the transport call")

      {:loopex_pool_unproved, ^pid, ^reference} ->
        flunk("the tagged pool could not prove setup")
    after
      2_000 -> flunk("tagged pool startup did not complete")
    end
  end

  defp stop_pool(root) do
    stop_ref = make_ref()
    deadline = System.monotonic_time() + System.convert_time_unit(1_000, :millisecond, :native)
    send(root.pid, {:loopex_pool_stop, self(), stop_ref, deadline})
    assert_receive {:loopex_pool_stopped, root_pid, ^stop_ref}, 1_000
    assert root_pid == root.pid
    assert_receive {:DOWN, monitor, :process, root_pid, :normal}, 1_000
    assert monitor == root.monitor
    assert root_pid == root.pid
  end

  defp assert_pool_gone(root) do
    for {_role, pid} <- root.roles do
      refute Process.alive?(pid)
    end

    assert Registry.lookup(Req.Finch, root.identity) == []
    assert Registry.lookup(Req.Finch.SupervisorRegistry, root.identity) == []
  end

  defp process_delta(before_processes),
    do: Enum.reject(Process.list(), &MapSet.member?(before_processes, &1))

  defp port_delta(before_ports),
    do: Enum.reject(Port.list(), &MapSet.member?(before_ports, &1))

  defp client_controllers(:http, in_flight_processes, _ports) do
    Enum.filter(in_flight_processes, &ssl_controller?/1)
  end

  # Concept: bind the drain proof to the observed client TLS socket.
  # Technical depth: OTP gives that port to the TLS receiver; a private
  # process-dictionary role marker is not available on every floor version.
  defp client_controllers(:tls, in_flight_processes, ports) do
    ports
    |> Enum.map(fn port ->
      assert {:connected, controller} = Port.info(port, :connected)
      assert controller in in_flight_processes
      assert Process.alive?(controller)
      assert ssl_controller?(controller)
      controller
    end)
    |> Enum.uniq()
  end

  defp ssl_controller?(pid) do
    case Process.info(pid, :dictionary) do
      {:dictionary, dictionary} ->
        Keyword.get(dictionary, :"$initial_call") == {:ssl_gen_statem, :init, 1}

      nil ->
        false
    end
  end

  defp client_ports(in_flight_ports, server_port) do
    in_flight_ports
    |> Enum.filter(fn port ->
      case :inet.peername(port) do
        {:ok, {_address, ^server_port}} -> true
        _ -> false
      end
    end)
  end

  defp await_transport_drain(controllers, ports, deadline) do
    now = System.monotonic_time(:millisecond)

    if Enum.all?(controllers, &(not Process.alive?(&1))) and
         Enum.all?(ports, &(not port_alive?(&1))) do
      now
    else
      assert now < deadline,
             "call-created transport outlived 5,000 ms after caller DOWN: " <>
               inspect({controllers, ports})

      Process.sleep(10)
      await_transport_drain(controllers, ports, deadline)
    end
  end

  defp port_alive?(port), do: port in Port.list()
end
