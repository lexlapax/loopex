defmodule Loopex.LLM.ReqLLM.ProviderIsolationFixture do
  @moduledoc false

  import ExUnit.Assertions
  alias Loopex.LLM.ReqLLM.{ProviderConfiguration, ProviderWorker}
  alias Loopex.LLM.ReqLLM, as: Adapter
  alias Loopex.{Model, Runtime.ProviderLifetime}

  # Concept: these fixtures exercise the public adapter, actual protected worker
  # entry, dependency stream, and controlled HTTP transport in a separate OS VM.
  # Technical depth: the escript loads the test VM's compiled code paths and
  # supplies literal synthetic transport configuration and a test manifest.
  # This is process conformance, never evidence of a self-contained package.
  def new(mode \\ :reply, options \\ []) do
    root = Path.join(System.tmp_dir!(), "loopex-provider-isolation-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    {:ok, events} = Agent.start_link(fn -> [] end)
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}, reuseaddr: true])
    {:ok, {_address, port}} = :inet.sockname(listener)
    expected = Keyword.get(options, :credential, System.get_env(Adapter.credential_variable()))
    acceptor = spawn_link(fn -> accept_loop(listener, events, mode, expected) end)
    if mode == :closed_port, do: :gen_tcp.close(listener)

    fixture = %{root: root, events: events, listener: listener, acceptor: acceptor, mode: mode}
    launch = write_worker(root, mode, port)

    ExUnit.Callbacks.on_exit(fn ->
      if Process.alive?(acceptor), do: Process.exit(acceptor, :kill)
      :gen_tcp.close(listener)
      if Process.alive?(events), do: Agent.stop(events)
      File.rm_rf!(root)
    end)

    Map.put(fixture, :options, launch)
  end

  def request(options \\ []) do
    {:ok, request} = Model.request(Keyword.get(options, :model, Adapter.default_model()),
      Keyword.get(options, :messages, [%{"role" => "user", "content" => "hello"}]),
      sampling: %{"max_tokens" => 64},
      deadline: System.system_time(:millisecond) + Keyword.get(options, :deadline_ms, 10_000))
    request
  end

  def complete(fixture, request \\ request(), progress \\ Model.discard_progress()),
    do: Adapter.complete(request, fixture.options, progress)

  def managed(fixture, request \\ request(), retainer \\ self()) do
    observer = self()
    {caller, caller_monitor} = spawn_monitor(fn ->
      result = ProviderLifetime.scoped(fn guardian, stop_reference ->
        send(observer, {:registered, self(), guardian, stop_reference})
        {:managed, retainer, 2_000}
      end, fn -> complete(fixture, request) end)
      send(observer, {:completed, self(), result})
    end)
    assert_receive {:registered, ^caller, guardian, stop_reference}, 1_000
    %{caller: caller, caller_monitor: caller_monitor, guardian: guardian,
      monitor: Process.monitor(guardian), stop_reference: stop_reference}
  end

  def stop(call) do
    stop = make_ref()
    deadline = System.monotonic_time(:millisecond) + 2_000
    send(call.guardian, {:loopex_provider_resource_stop, call.stop_reference, stop,
      self(), deadline, deadline + 100})
    guardian = call.guardian
    monitor = call.monitor
    assert_receive {:loopex_provider_resource_stopped, ^stop, ^guardian}, 2_000
    assert_receive {:DOWN, ^monitor, :process, ^guardian, :normal}, 500
  end

  def events(fixture), do: Agent.get(fixture.events, &Enum.reverse/1)
  def count(fixture), do: length(events(fixture))
  def marker(fixture, name), do: Path.join(fixture.root, name)
  def reached?(fixture, name), do: File.regular?(marker(fixture, name))
  def release(fixture), do: File.write!(marker(fixture, "release"), "release")
  def canaries(fixture) do
    case File.read(marker(fixture, "canary")) do
      {:ok, content} -> length(String.split(content, "\n", trim: true))
      {:error, :enoent} -> 0
    end
  end
  def pid(fixture), do: fixture |> marker("pid") |> File.read!() |> String.to_integer()
  def namespace(fixture), do: fixture |> marker("namespace") |> File.read!()

  def assert_gone(fixture) do
    assert eventually(fn -> not alive?(pid(fixture)) end, 2_500)
    refute File.exists?(namespace(fixture))
  end

  def alive?(pid) do
    case System.cmd("/bin/ps", ["-p", Integer.to_string(pid), "-o", "stat="]) do
      {state, 0} -> not String.starts_with?(String.trim(state), "Z")
      {_output, 1} -> false
      result -> flunk("process observation unavailable: #{inspect(result)}")
    end
  end

  def eventually(fun, timeout \\ 5_000),
    do: await(fun, System.monotonic_time(:millisecond) + timeout)

  defp await(fun, deadline) do
    cond do
      fun.() -> true
      System.monotonic_time(:millisecond) >= deadline -> false
      true -> Process.sleep(10); await(fun, deadline)
    end
  end

  defp write_worker(root, mode, port) do
    manifest = %{"source" => "synthetic-process-fixture", "version" => "fixture",
      "dependency_lock_sha256" => String.duplicate("0", 64),
      "packaged_input_sha256" => String.duplicate("1", 64),
      "elixir" => System.version(), "otp" => ProviderWorker.otp_version()}
    source = """
    defmodule Loopex.LLM.ReqLLM.ProviderBuildIdentity do
      def manifest, do: #{inspect(manifest)}
    end
    defmodule LoopexProviderFixtureTransport do
      @behaviour ReqLLM.FinchRequestAdapter
      require Logger
      def call(%Finch.Request{} = request) do
        root = #{inspect(root)}
        mode = #{inspect(mode)}
        File.write!(Path.join(root, "canary"), "POST\\n", [:append])
        if mode in [:hold_before_return, :descendant] do
          if mode == :descendant do
            spawn(fn ->
              Port.open({:spawn_executable, ~c"/bin/sh"}, [
                :binary, :exit_status,
                {:args, [~c"-c", String.to_charlist("echo $$ > " <> Path.join(root, "descendant") <> "; exec /bin/sleep 120")]}])
              Process.sleep(:infinity)
            end)
          end
          Stream.repeatedly(fn -> File.exists?(Path.join(root, "release")) end)
          |> Enum.reduce_while(nil, fn ready, _ ->
            if ready, do: {:halt, :ready}, else: (Process.sleep(10); {:cont, nil})
          end)
        end
        if mode == :diagnostics do
          key = Enum.find_value(request.headers, fn {name, value} ->
            if String.downcase(name) in ["x-api-key", "authorization"], do: value
          end)
          for action <- [fn -> IO.write(key) end, fn -> IO.write(:stderr, key) end,
            fn -> Logger.error(key, diagnostic: %{key => key}) end,
            fn -> :logger.error(~c"~ts", [key]) end] do
            try do action.() catch _, _ -> :ok end
          end
          spawn(fn -> raise key end)
          spawn(fn -> Process.sleep(100); Logger.error(key) end)
          File.write!(Path.join(root, "diagnostics"), "attempted")
        end
        case mode do
          :raise -> raise "synthetic provider failure"
          :throw -> throw(:synthetic_provider_failure)
          :exit -> exit(:synthetic_provider_failure)
          :malformed_return -> {:not_a_finch_request, request.host}
          :tagged_not_dispatched -> {:error, {:not_dispatched, "model_call_failed"}}
          _ -> %{request | scheme: :http, host: "127.0.0.1", port: #{port}, path: "/", query: nil}
        end
      end
    end
    Application.put_env(:req_llm, :finch_request_adapter, LoopexProviderFixtureTransport)
    [path | _] = Enum.map(arguments, &List.to_string/1)
    File.write!(#{inspect(Path.join(root, "pid"))}, System.pid())
    File.write!(#{inspect(Path.join(root, "namespace"))}, Path.dirname(path))
    File.write!(#{inspect(Path.join(root, "entry-env"))}, inspect(Enum.sort(Map.keys(System.get_env()))))
    if #{inspect(mode)} == :pre_entry_crash, do: System.halt(71)
    if #{inspect(mode)} == :hold_before_entry, do: Process.sleep(:infinity)
    Loopex.LLM.ReqLLM.ProviderWorker.main(Enum.map(arguments, &List.to_string/1))
    """
    paths = :io_lib.format(~c"~tp", [:code.get_path()]) |> IO.iodata_to_binary()
    script = Path.join(root, "worker.escript")
    File.write!(script, """
    #!/usr/bin/env escript
    %%! +S 2:2 +SDcpu 1 +SDio 1 +A 2
    main(Arguments) ->
      ok = code:add_paths(#{paths}),
      {ok, _} = application:ensure_all_started(elixir),
      'Elixir.Code':eval_string(base64:decode("#{Base.encode64(source)}"), [{arguments, Arguments}]),
      ok.
    """)
    {:ok, digest} = ProviderConfiguration.file_digest(script)
    [worker_path: script, interpreter_path: Path.join(List.to_string(:code.root_dir()), "bin/escript"),
      worker_sha256: digest,
      build_manifest_sha256: :crypto.hash(:sha256, :erlang.term_to_binary(manifest, [:deterministic])) |> Base.encode16(case: :lower),
      cleanup_grace_ms: 2_000]
  end

  defp accept_loop(listener, events, mode, expected) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        handler = spawn_link(fn ->
          receive do
            {:socket, ^socket} -> serve(socket, events, mode, expected)
          end
        end)
        :ok = :gen_tcp.controlling_process(socket, handler)
        send(handler, {:socket, socket})
        accept_loop(listener, events, mode, expected)
      {:error, :closed} -> :ok
    end
  end

  defp serve(socket, events, mode, expected) do
    with {:ok, headers, body} <- read_request(socket, "") do
      authorized = is_binary(expected) and String.contains?(headers, expected)
      Agent.update(events, &[{Jason.decode!(body), authorized} | &1])
      case mode do
        mode when mode in [:blocked, :timeout] -> wait_closed(socket)
        :rate_limited -> respond(socket, "429 Too Many Requests", "application/json", "{}")
        :http_error -> respond(socket, "500 Internal Server Error", "application/json", "{}")
        :malformed_response -> respond(socket, "200 OK", "application/json", "{not-json")
        :incomplete_stream -> respond(socket, "200 OK", "text/event-stream", "data: {\"type\":\"message_start\"")
        :closed_port -> :ok
        _ -> respond(socket, "200 OK", "text/event-stream", stream_body())
      end
    end
    :gen_tcp.close(socket)
  end

  defp read_request(socket, bytes) do
    case :binary.split(bytes, "\r\n\r\n") do
      [headers, body] ->
        [_, length] = Regex.run(~r/content-length:\s*(\d+)/i, headers)
        read_body(socket, headers, body, String.to_integer(length))
      [_partial] ->
        case :gen_tcp.recv(socket, 0, 5_000) do
          {:ok, more} -> read_request(socket, bytes <> more)
          error -> error
        end
    end
  end

  defp read_body(_socket, headers, body, length) when byte_size(body) >= length,
    do: {:ok, headers, binary_part(body, 0, length)}
  defp read_body(socket, headers, body, length) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, more} -> read_body(socket, headers, body <> more, length)
      error -> error
    end
  end

  defp wait_closed(socket) do
    case :gen_tcp.recv(socket, 0, 100) do
      {:error, :timeout} -> wait_closed(socket)
      _closed -> :ok
    end
  end

  defp respond(socket, status, type, body), do: :gen_tcp.send(socket,
    "HTTP/1.1 #{status}\r\ncontent-type: #{type}\r\ncontent-length: #{byte_size(body)}\r\nrequest-id: req-fixture-001\r\nconnection: close\r\n\r\n#{body}")

  defp stream_body do
    [
      %{"type" => "message_start", "message" => %{"id" => "msg_fixture", "type" => "message", "role" => "assistant", "model" => "claude-haiku-4-5", "content" => [], "usage" => %{"input_tokens" => 4, "output_tokens" => 0}}},
      %{"type" => "content_block_start", "index" => 0, "content_block" => %{"type" => "text", "text" => ""}},
      %{"type" => "content_block_delta", "index" => 0, "delta" => %{"type" => "text_delta", "text" => "loopex"}},
      %{"type" => "content_block_stop", "index" => 0},
      %{"type" => "message_delta", "delta" => %{"stop_reason" => "end_turn", "stop_sequence" => nil}, "usage" => %{"output_tokens" => 2}},
      %{"type" => "message_stop"}
    ] |> Enum.map_join(fn event -> "event: #{event["type"]}\ndata: #{Jason.encode!(event)}\n\n" end)
  end
end
