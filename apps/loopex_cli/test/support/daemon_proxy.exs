defmodule LoopexCli.Test.DaemonProxy do
  @moduledoc false

  # Concept: a loss the client cannot tell apart from a real one. The proxy
  # sits on its own Unix socket in front of a daemon and forwards both ways; a
  # scheduled cut forwards one named request, waits until the daemon has
  # answered it, then discards that answer and closes both sides, so the
  # client must recover from a request the daemon applied but whose reply it
  # never saw.
  #
  # Technical depth: requests are read as JSON lines from the client. A cut is
  # `{method, count}`: the next `count` requests with that method are each
  # followed by one lost reply. `{{:before, method}, count}` instead closes the
  # connection without forwarding the request, so the daemon never sees it. Every other byte is forwarded unchanged. The
  # proxy records each request it saw, in order, for the test to inspect.

  def start(daemon_path, cuts) do
    path = Path.join("/tmp", "ldp-#{System.unique_integer([:positive])}.sock")
    parent = self()

    pid =
      spawn_link(fn ->
        {:ok, listener} =
          :gen_tcp.listen(0, [:binary, {:ifaddr, {:local, path}}, active: false])

        send(parent, {:proxy_listening, self()})
        accept(listener, daemon_path, %{cuts: Map.new(cuts), seen: []})
      end)

    receive do
      {:proxy_listening, ^pid} -> :ok
    after
      5_000 -> raise "the proxy did not listen"
    end

    ExUnit.Callbacks.on_exit(fn -> File.rm(path) end)
    %{pid: pid, path: path}
  end

  def seen(proxy) do
    send(proxy.pid, {:seen, self()})

    receive do
      {:proxy_seen, requests} -> requests
    after
      5_000 -> raise "the proxy did not answer"
    end
  end

  defp accept(listener, daemon_path, state) do
    receive do
      {:seen, caller} ->
        send(caller, {:proxy_seen, state.seen})
        accept(listener, daemon_path, state)
    after
      0 ->
        case :gen_tcp.accept(listener, 50) do
          {:ok, client} ->
            {:ok, daemon} =
              :gen_tcp.connect({:local, daemon_path}, 0, [:binary, active: true, packet: :raw])

            :ok = :inet.setopts(client, active: true, packet: :line, buffer: 4_194_304)
            accept(listener, daemon_path, relay(client, daemon, state))

          {:error, :timeout} ->
            accept(listener, daemon_path, state)
        end
    end
  end

  defp relay(client, daemon, state) do
    receive do
      {:tcp, ^client, line} ->
        method = method(line)
        state = %{state | seen: state.seen ++ [method]}

        case Map.get(state.cuts, {:before, method}, 0) do
          remaining when remaining > 0 ->
            close(client, daemon)
            %{state | cuts: Map.put(state.cuts, {:before, method}, remaining - 1)}

          _none ->
            :ok = :gen_tcp.send(daemon, line)

            case Map.get(state.cuts, method, 0) do
              remaining when remaining > 0 ->
                lose_reply(client, daemon)
                %{state | cuts: Map.put(state.cuts, method, remaining - 1)}

              _none ->
                relay(client, daemon, state)
            end
        end

      {:tcp, ^daemon, bytes} ->
        :ok = :gen_tcp.send(client, bytes)
        relay(client, daemon, state)

      {:tcp_closed, _socket} ->
        close(client, daemon)
        state

      {:seen, caller} ->
        send(caller, {:proxy_seen, state.seen})
        relay(client, daemon, state)
    end
  end

  # The request reached the daemon; its answer, and whatever else the daemon
  # wrote first, never reaches the client.
  defp lose_reply(client, daemon) do
    receive do
      {:tcp, ^daemon, _bytes} -> :ok
    after
      10_000 -> :ok
    end

    close(client, daemon)
  end

  defp close(client, daemon) do
    :gen_tcp.close(client)
    :gen_tcp.close(daemon)
  end

  defp method(line) do
    case JSON.decode(line) do
      {:ok, %{"method" => method}} -> method
      _other -> nil
    end
  end
end
