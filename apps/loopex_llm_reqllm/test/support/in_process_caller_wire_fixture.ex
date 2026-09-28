Code.require_file("../../../loopex/test/support/m1_runtime_helper.exs", __DIR__)
Code.require_file("in_process_tls_fixture.ex", __DIR__)

defmodule Loopex.LLM.ReqLLM.InProcessCallerWireFixture do
  @moduledoc """
  ## Concept

  Drive the sensitive caller against a local provider-wire server without a
  public network call or a real credential.

  ## Technical depth

  The caller receives an actual prepared ReqLLM request and a tagged HTTP/1
  worker. A child VM loads a fixture CA only for hosted-provider TLS cases.
  The fixture records complete request writes and proves pool teardown before
  returning each result.
  """

  import ExUnit.Assertions

  alias Loopex.LLM.ReqLLM.InProcess
  alias Loopex.LLM.ReqLLM.InProcess.{Caller, PoolLifecycle}
  alias Loopex.Trace.Capability

  def runtime do
    {store_pid, store} = Loopex.M1RuntimeTestStore.start_store()

    {:ok, runtime} =
      Loopex.start_link(
        runtime_id: "caller-wire-#{System.unique_integer([:positive])}",
        store: store,
        context_token_budget: 8192,
        diagnostics_to: self()
      )

    {:ok, capability_pid} = Capability.start_link()
    {:ok, capability} = Capability.handle(capability_pid)
    :ok = Capability.bind(capability, runtime)

    %{
      runtime: runtime,
      store_pid: store_pid,
      capability_pid: capability_pid,
      capability: capability
    }
  end

  def close_runtime(fixture) do
    Loopex.stop(fixture.runtime)
    if Process.alive?(fixture.capability_pid), do: GenServer.stop(fixture.capability_pid)
    if Process.alive?(fixture.store_pid), do: GenServer.stop(fixture.store_pid)
  end

  def start(runtime, model, body, options \\ []) do
    tls = Keyword.get(options, :tls)
    listener_options = [:binary, active: false, reuseaddr: true]

    {:ok, listener} =
      if tls do
        :ssl.listen(0, listener_options ++ [cert: tls[:cert], key: tls[:key]])
      else
        :gen_tcp.listen(0, listener_options ++ [ip: {127, 0, 0, 1}])
      end

    {:ok, {_, port}} = if tls, do: :ssl.sockname(listener), else: :inet.sockname(listener)
    base = if tls, do: "https://localhost:#{port}", else: "http://127.0.0.1:#{port}"
    parent = self()
    header_id = Keyword.get(options, :header_id, "fixture-id")
    server = spawn(fn -> serve(listener, parent, body, tls != nil, header_id) end)
    tag = make_ref()
    reference = make_ref()
    deadline = expiry(10_000)

    {root, root_monitor} =
      spawn_monitor(fn ->
        PoolLifecycle.run(%{
          owner: parent,
          reference: reference,
          base_url: base,
          tag: tag,
          deadline: deadline
        })
      end)

    send(root, {:loopex_pool_start, self(), reference})
    {worker, identity} = ready(root, reference)

    messages = Keyword.get(options, :messages, [%{"role" => "user", "content" => "hello"}])

    {:ok, request} =
      Loopex.Model.request(model, messages,
        sampling: %{"max_tokens" => 64},
        deadline: System.system_time(:millisecond) + 10_000
      )

    assert {:ok, prepared} = InProcess.preflight(request, base)
    call_ref = make_ref()
    input_ref = make_ref()
    cell = :atomics.new(2, signed: false)

    arguments = %{
      owner: self(),
      callback: self(),
      ref: call_ref,
      input_ref: input_ref,
      tag: tag,
      cell: cell,
      trace_capability: runtime.capability,
      pool_timeout: 1_000
    }

    {caller, monitor} = spawn_monitor(fn -> Caller.run(arguments) end)
    assert_receive {:in_process_caller_ready, ^caller, ^call_ref}, 1_000

    %{
      root: root,
      root_monitor: root_monitor,
      worker: worker,
      identity: identity,
      server: server,
      listener: listener,
      tls: tls != nil,
      caller: caller,
      monitor: monitor,
      call_ref: call_ref,
      input_ref: input_ref,
      tag: tag,
      cell: cell,
      prepared: prepared,
      deadline: deadline,
      writes: [],
      cleaned: false
    }
  end

  def begin(fixture) do
    send(
      fixture.caller,
      {:in_process_caller_input, self(), fixture.call_ref, fixture.input_ref, fixture.prepared}
    )

    send(
      fixture.caller,
      {:in_process_caller_begin, self(), fixture.call_ref, fixture.input_ref}
    )

    fixture
  end

  def result(fixture) do
    caller = fixture.caller
    call_ref = fixture.call_ref

    receive do
      {:loopex_one_shot_claim, ^caller, claim, tag, fingerprint, route, surface} ->
        assert tag == fixture.tag
        assert fingerprint.surface == fixture.prepared.surface
        assert route.path == fingerprint.path

        if fixture.prepared.provider in [:openai, :anthropic],
          do: assert(surface == fingerprint.surface)

        inspection = make_ref()
        send(fixture.root, {:loopex_pool_inspect, self(), inspection, fixture.deadline})
        root = fixture.root
        assert_receive {:loopex_pool_inspected, ^root, ^inspection, :ok}, 1_000
        send(caller, {:loopex_one_shot_grant, claim, tag, fixture.worker})
        result(fixture)

      {:loopex_one_shot_teardown, ^caller, teardown, tag} ->
        fixture = stop_pool(fixture)
        send(caller, {:loopex_one_shot_torn_down, teardown, tag})
        result(fixture)

      {:caller_wire, server, wire} when server == fixture.server ->
        result(%{fixture | writes: fixture.writes ++ [wire]})

      {^caller, ^call_ref, returned, finished} ->
        assert is_integer(finished)
        {returned, stop_pool(fixture)}
    after
      5_000 -> flunk("caller fixture result unavailable")
    end
  end

  def stop(fixture) do
    fixture = stop_pool(fixture)
    caller = fixture.caller
    monitor = fixture.monitor
    if Process.alive?(caller), do: Process.exit(caller, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^caller, _reason}, 1_000
    if fixture.tls, do: :ssl.close(fixture.listener), else: :gen_tcp.close(fixture.listener)
    if Process.alive?(fixture.server), do: Process.exit(fixture.server, :kill)
    fixture
  end

  def refute_write(fixture) do
    assert fixture.writes == []
    server = fixture.server
    refute_receive {:caller_wire, ^server, _wire}, 50
  end

  def assert_one_write(fixture) do
    assert length(fixture.writes) == 1
    server = fixture.server
    refute_receive {:caller_wire, ^server, _wire}, 50
  end

  defp ready(root, reference) do
    receive do
      {:loopex_pool_record, ^root, receipt, _entries} ->
        send(root, {:loopex_pool_recorded, receipt})
        ready(root, reference)

      {:loopex_pool_ready, ^root, ^reference, worker, identity} ->
        {worker, identity}
    after
      1_000 -> flunk("tagged pool fixture unavailable")
    end
  end

  defp stop_pool(%{cleaned: true} = fixture), do: fixture

  defp stop_pool(fixture) do
    stop = make_ref()
    root = fixture.root
    monitor = fixture.root_monitor
    send(root, {:loopex_pool_stop, self(), stop, expiry(1_000)})
    assert_receive {:DOWN, ^monitor, :process, ^root, :normal}, 2_000
    assert Registry.lookup(Req.Finch, fixture.identity) == []
    assert Registry.lookup(Req.Finch.SupervisorRegistry, fixture.identity) == []
    %{fixture | cleaned: true}
  end

  defp expiry(ms),
    do: System.monotonic_time(:native) + System.convert_time_unit(ms, :millisecond, :native)

  defp serve(listener, parent, body, tls, header_id) do
    accepted =
      if tls do
        with {:ok, socket} <- :ssl.transport_accept(listener, 5_000),
             {:ok, socket} <- :ssl.handshake(socket, 5_000),
             do: {:ok, socket}
      else
        :gen_tcp.accept(listener, 5_000)
      end

    case accepted do
      {:ok, socket} ->
        wire = read(socket, tls, "")
        send(parent, {:caller_wire, self(), wire})

        response =
          "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\nx-request-id: #{header_id}\r\nrequest-id: #{header_id}\r\ncontent-length: #{byte_size(body)}\r\n\r\n#{body}"

        if tls, do: :ssl.send(socket, response), else: :gen_tcp.send(socket, response)
        if tls, do: :ssl.recv(socket, 0, 5_000), else: :gen_tcp.recv(socket, 0, 5_000)
        if tls, do: :ssl.close(socket), else: :gen_tcp.close(socket)
        serve(listener, parent, body, tls, header_id)

      _ ->
        :ok
    end
  end

  defp read(socket, tls, bytes) do
    case :binary.split(bytes, "\r\n\r\n") do
      [headers, body] ->
        [line | lines] = String.split(headers, "\r\n")

        headers =
          Map.new(lines, fn field ->
            [key, value] = String.split(field, ":", parts: 2)
            {String.downcase(key), String.trim(value)}
          end)

        length = String.to_integer(headers["content-length"] || "0")

        if byte_size(body) >= length,
          do: %{line: line, headers: headers, body: binary_part(body, 0, length)},
          else: more(socket, tls, bytes)

      _ ->
        more(socket, tls, bytes)
    end
  end

  defp more(socket, tls, bytes) do
    {:ok, next} = if tls, do: :ssl.recv(socket, 0, 5_000), else: :gen_tcp.recv(socket, 0, 5_000)
    read(socket, tls, bytes <> next)
  end

  def wire(:anthropic, text),
    do:
      Jason.encode!(%{
        "id" => "msg",
        "type" => "message",
        "role" => "assistant",
        "model" => "fixture",
        "content" => [%{"type" => "text", "text" => text}],
        "stop_reason" => "end_turn",
        "usage" => %{"input_tokens" => 1, "output_tokens" => 2}
      })

  def wire(:responses, text),
    do:
      Jason.encode!(%{
        "id" => "resp",
        "object" => "response",
        "status" => "completed",
        "output" => [
          %{
            "type" => "message",
            "role" => "assistant",
            "status" => "completed",
            "content" => [%{"type" => "output_text", "text" => text, "annotations" => []}]
          }
        ],
        "usage" => %{"input_tokens" => 1, "output_tokens" => 2}
      })

  def wire(_, text),
    do:
      Jason.encode!(%{
        "id" => "reply",
        "object" => "chat.completion",
        "choices" => [
          %{
            "index" => 0,
            "message" => %{"role" => "assistant", "content" => text},
            "finish_reason" => "stop"
          }
        ],
        "usage" => %{"prompt_tokens" => 1, "completion_tokens" => 2}
      })

  def hosted_child do
    System.cmd(
      System.find_executable("elixir"),
      [
        "-pa",
        Path.expand("../../../../_build/test/lib/*/ebin", __DIR__),
        "-r",
        __ENV__.file,
        "-e",
        "Loopex.LLM.ReqLLM.InProcessCallerWireFixture.hosted_probe()"
      ],
      stderr_to_stdout: true
    )
  end

  def hosted_probe do
    {:ok, _} = Application.ensure_all_started(:req_llm)
    trusted = Loopex.LLM.ReqLLM.InProcessTLSFixture.certificate()

    directory =
      Path.join(System.tmp_dir!(), "loopex-caller-wire-#{System.unique_integer([:positive])}")

    File.mkdir!(directory)

    pem = :public_key.pem_encode(Enum.map(trusted[:cacerts], &{:Certificate, &1, :not_encrypted}))
    ca_path = Path.join(directory, "ca.pem")
    File.write!(ca_path, pem)
    :ok = :public_key.cacerts_load(String.to_charlist(ca_path))
    runtime = runtime()

    try do
      hosted_paths(runtime, trusted)
      selected_key_bounds(runtime, trusted)
      selected_key_rotation(runtime, trusted)
      selected_key_echo(runtime, trusted)
      IO.puts("IN_PROCESS_CALLER_WIRE_PROBE_PASSED")
    after
      close_runtime(runtime)
      File.rm_rf!(directory)
    end
  end

  defp hosted_paths(runtime, trusted) do
    for {model, variable, surface, kind, path} <- [
          {"openai:gpt-4", "OPENAI_API_KEY", :openai_chat_completions, :chat,
           "/chat/completions"},
          {"openai:gpt-4.1", "OPENAI_API_KEY", :openai_responses, :responses, "/responses"},
          {"anthropic:fixture", "ANTHROPIC_API_KEY", :anthropic_messages, :anthropic,
           "/v1/messages"},
          {"openrouter:fixture/model", "OPENROUTER_API_KEY", :openrouter_chat_completions, :chat,
           "/chat/completions"}
        ] do
      System.put_env(variable, "synthetic-caller-credential")
      call = start(runtime, model, wire(kind, "hosted answer"), tls: trusted)
      {result, call} = call |> begin() |> result()
      assert {:ok, %{text: "hosted answer", streamed: false, tool_calls: []}} = result
      expected_id = if model == "openrouter:fixture/model", do: nil, else: "fixture-id"
      assert elem(result, 1).provider_response_id == expected_id

      assert call.prepared.surface == surface
      assert [written] = call.writes
      assert written.line == "POST #{path} HTTP/1.1"

      selected =
        if kind == :anthropic,
          do: written.headers["x-api-key"],
          else: String.replace_prefix(written.headers["authorization"], "Bearer ", "")

      assert selected == "synthetic-caller-credential"
      stop(call)
    end
  end

  defp selected_key_bounds(runtime, trusted) do
    for key <- [:missing, "", String.duplicate("k", 65_537)] do
      if key == :missing,
        do: System.delete_env("OPENAI_API_KEY"),
        else: System.put_env("OPENAI_API_KEY", key)

      call = start(runtime, "openai:gpt-4", wire(:chat, "unreached"), tls: trusted)
      {result, call} = call |> begin() |> result()
      assert result == {:error, {:not_dispatched, "model_call_failed"}}
      refute_write(call)
      stop(call)
    end

    for key <- ["k", String.duplicate("k", 65_536)] do
      System.put_env("OPENAI_API_KEY", key)
      call = start(runtime, "openai:gpt-4", wire(:chat, "bounded"), tls: trusted)
      {result, call} = call |> begin() |> result()
      assert {:ok, %{text: "bounded"}} = result
      assert [written] = call.writes
      assert byte_size(written.headers["authorization"]) == byte_size(key) + 7
      stop(call)
    end
  end

  defp selected_key_rotation(runtime, trusted) do
    System.put_env("OPENAI_API_KEY", "before-retention")
    call = start(runtime, "openai:gpt-4", wire(:chat, "rotation"), tls: trusted)
    System.put_env("OPENAI_API_KEY", "after-retention")
    {result, call} = call |> begin() |> result()
    assert {:ok, %{text: "rotation"}} = result
    assert [written] = call.writes
    assert written.headers["authorization"] == "Bearer after-retention"
    stop(call)
  end

  defp selected_key_echo(runtime, trusted) do
    key = "synthetic-echo-credential"
    System.put_env("OPENAI_API_KEY", key)

    safe_call =
      start(runtime, "openai:gpt-4", tool_reply("read", "call-safe", %{"path" => "x"}),
        tls: trusted
      )

    {safe_result, safe_call} = safe_call |> begin() |> result()

    assert {:ok,
            %{
              tool_calls: [
                %{id: "call-safe", name: "read", arguments: %{"path" => "x"}}
              ]
            }} = safe_result

    assert_one_write(safe_call)
    stop(safe_call)

    partial = start(runtime, "openai:gpt-4", wire(:chat, "synthetic-echo-cred"), tls: trusted)
    {partial_result, partial} = partial |> begin() |> result()
    assert {:ok, %{text: "synthetic-echo-cred"}} = partial_result
    assert_one_write(partial)
    stop(partial)

    for {body, options} <- [
          {wire(:chat, "echo " <> key), []},
          {wire(:chat, "safe"), [header_id: key]},
          {tool_reply("read", "call-" <> key, %{}), []},
          {tool_reply("read", "call", %{key => "literal-key"}), []},
          {tool_reply("read", "call", %{"nested" => [%{key => "nested-key"}]}), []},
          {tool_reply("read", "call", %{"nested" => [%{"inside" => key}]}), []},
          {usage_echo_reply(key), []}
        ] do
      call = start(runtime, "openai:gpt-4", body, [tls: trusted] ++ options)
      {result, call} = call |> begin() |> result()
      assert result == {:error, {:dispatched_or_unknown, "model_call_failed"}}
      assert_one_write(call)
      stop(call)
    end

    call =
      start(runtime, "openai:gpt-4", wire(:chat, "safe"),
        tls: trusted,
        messages: [%{"role" => "user", "content" => "host input " <> key}]
      )

    {result, call} = call |> begin() |> result()
    assert {:ok, %{text: "safe"}} = result
    assert [written] = call.writes
    assert String.contains?(written.body, key)
    stop(call)
  end

  defp tool_reply(name, id, arguments) do
    body = Jason.decode!(wire(:chat, ""))

    message = %{
      "role" => "assistant",
      "content" => nil,
      "tool_calls" => [
        %{
          "id" => id,
          "type" => "function",
          "function" => %{"name" => name, "arguments" => Jason.encode!(arguments)}
        }
      ]
    }

    body
    |> put_in(["choices", Access.at(0), "message"], message)
    |> put_in(["choices", Access.at(0), "finish_reason"], "tool_calls")
    |> Jason.encode!()
  end

  defp usage_echo_reply(key) do
    wire(:chat, "safe")
    |> Jason.decode!()
    |> Map.put("usage", %{
      "prompt_tokens" => key,
      "completion_tokens" => 2,
      "total_tokens" => 3
    })
    |> Jason.encode!()
  end
end
