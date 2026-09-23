Code.require_file("support/daemon_socket_fixture.exs", __DIR__)

# The shared provider fixture's runtime helper refuses to load without an
# isolated home; this suite supplies a temporary one rather than a real one.
unless System.get_env("LOOPEX_HOME") do
  home = Path.join(System.tmp_dir!(), "ldx-home-#{System.unique_integer([:positive])}")
  File.mkdir_p!(home)
  System.put_env("LOOPEX_HOME", home)
  System.at_exit(fn _status -> File.rm_rf(home) end)
end

Code.require_file(
  "../../loopex_llm_reqllm/test/support/provider_isolation_fixture.exs",
  __DIR__
)

defmodule LoopexDaemon.ExternalSocketWorkflowTest do
  use ExUnit.Case, async: false
  @moduletag capture_log: true

  import LoopexDaemon.Test.DaemonSocketFixture, only: [send_frame: 2, receive_records: 2]

  alias Loopex.LLM.ReqLLM.ProviderIsolationFixture, as: ProviderFixture
  alias LoopexDaemon.Sentinel
  alias LoopexProtocol.{Session.V2, Wire}

  @credential "external-workflow-placeholder"

  defmodule AllowPolicy do
    @moduledoc false
    @behaviour Loopex.Policy

    @impl Loopex.Policy
    def decide(_request), do: {:allow, nil}
  end

  # Concept: an independent client in another language and another operating
  # system process observes a session one client controls, takes it over once
  # that controller is killed and its lease lapses, and aborts the running work.
  @tag :node_client
  @tag timeout: 180_000
  test "a Node observer takes over from a killed controller and aborts its run" do
    node = System.find_executable("node") || flunk("Node is unavailable on this host")
    root = Path.join(System.tmp_dir!(), "ldx-#{System.unique_integer([:positive])}")
    workspace = Path.join(root, "w")
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf(root) end)

    provider =
      ProviderFixture.new(:delayed_entry,
        credential: @credential,
        response_bodies: [text_response("never finished", "msg_external_held")]
      )

    socket = Path.join([root, "s", "daemon", "d.sock"])

    options = [
      state_root: Path.join(root, "s"),
      socket_path: socket,
      workspace: workspace,
      policy: AllowPolicy,
      provider_launch:
        Keyword.drop(provider.options, [
          :credential_token,
          :credential_registry,
          :tracing_capability
        ]),
      credential: @credential
    ]

    {:ok, output} = StringIO.open("")
    test = self()

    daemon =
      Task.async(fn ->
        Sentinel.run(options, output: output, install_signals: false, notify: test)
      end)

    assert_receive {:loopex_daemon_sentinel, sentinel, owner_ref, _owner}, 5_000
    await_ready(output, 1_000)

    controller = spawn(fn -> control(socket, test) end)
    assert_receive {:controlling, session_id}, 30_000
    eventually(fn -> ProviderFixture.reached?(provider, "pid") end)

    script = Path.expand("../../../clients/node/daemon-takeover.mjs", __DIR__)

    port =
      Port.open({:spawn_executable, node}, [
        :binary,
        :exit_status,
        {:line, 65_536},
        args: [script, socket, session_id]
      ])

    assert_receive {^port, {:data, {:eol, ~s({"attached":true})}}}, 30_000
    Process.exit(controller, :kill)

    {status, lines} = collect(port, [])
    assert status == 0, Enum.join(lines, "\n")

    assert %{"granted" => true, "abort" => "accepted", "finished" => true, "attempts" => attempts} =
             lines |> List.last() |> JSON.decode!()

    # The killed controller's lease was never released, so taking over waited.
    assert attempts > 1

    ProviderFixture.release(provider)
    send(sentinel, {:daemon_signal, owner_ref, :sigterm})
    assert Task.await(daemon, 60_000) == 0
  end

  # Concept: a client attached to a session sees its answer as it is produced,
  # as transient progress for that session, before the durable record of it.
  @tag timeout: 120_000
  test "an attached client receives the session's model progress before its durable answer" do
    root = Path.join(System.tmp_dir!(), "ldp-#{System.unique_integer([:positive])}")
    workspace = Path.join(root, "w")
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf(root) end)

    provider =
      ProviderFixture.new(:reply,
        credential: @credential,
        response_bodies: [text_response("streamed answer", "msg_progress")]
      )

    socket = Path.join([root, "s", "daemon", "d.sock"])

    options = [
      state_root: Path.join(root, "s"),
      socket_path: socket,
      workspace: workspace,
      policy: AllowPolicy,
      provider_launch:
        Keyword.drop(provider.options, [
          :credential_token,
          :credential_registry,
          :tracing_capability
        ]),
      credential: @credential
    ]

    {:ok, output} = StringIO.open("")
    test = self()

    daemon =
      Task.async(fn ->
        Sentinel.run(options, output: output, install_signals: false, notify: test)
      end)

    assert_receive {:loopex_daemon_sentinel, sentinel, owner_ref, _owner}, 5_000
    await_ready(output, 1_000)

    {:ok, client} = :socket.open(:local, :stream, :default)
    :ok = :socket.connect(client, %{family: :local, path: socket})
    {encoded, epoch} = drive(client, "progress")

    records = records_until_finished(client, [])
    kinds = Enum.map(records, &record_kind/1)

    assert {:progress, "text_delta"} in kinds

    assert Enum.find_index(kinds, &(&1 == {:progress, "text_delta"})) <
             Enum.find_index(kinds, &(&1 == {:event, "assistant.message_appended"}))

    assert Enum.all?(
             for(%{"type" => "progress"} = record <- records, do: record["session_id"]),
             &(&1 == encoded)
           )

    assert epoch
    send(sentinel, {:daemon_signal, owner_ref, :sigterm})
    assert Task.await(daemon, 60_000) == 0
  end

  defp drive(socket, label) do
    :ok =
      send_frame(socket, %{
        "method" => "initialize",
        "request_id" => "init",
        "generations" => [V2.generation()],
        "capabilities" => []
      })

    [%{"type" => "initialized"}] = receive_records(socket, 1)

    :ok =
      send_frame(socket, %{
        "method" => "session.create",
        "request_id" => "create",
        "command_id" => Wire.encode_identity("#{label}-create"),
        "session_options" => %{}
      })

    [%{"status" => "accepted", "session_id" => encoded}] = receive_records(socket, 1)

    :ok =
      send_frame(socket, %{
        "method" => "session.acquire_control",
        "request_id" => "acquire",
        "session_id" => encoded
      })

    [%{"result" => %{"writer_epoch" => epoch}}] = receive_records(socket, 1)

    :ok =
      send_frame(socket, %{
        "method" => "session.attach",
        "request_id" => "attach",
        "session_id" => encoded,
        "after_event_sequence" => "0"
      })

    [%{"type" => "snapshot"}] = receive_records(socket, 1)

    :ok =
      send_frame(socket, %{
        "method" => "session.prompt",
        "request_id" => "prompt",
        "command_id" => Wire.encode_identity("#{label}-prompt"),
        "content_b64" => Wire.encode_bytes("answer me"),
        "writer_epoch" => epoch
      })

    {encoded, epoch}
  end

  defp records_until_finished(socket, acc) do
    [record] = receive_records(socket, 1)
    acc = acc ++ [record]

    if match?(%{"type" => "event", "event" => %{"kind" => "run.finished"}}, record),
      do: acc,
      else: records_until_finished(socket, acc)
  end

  defp record_kind(%{"type" => "progress", "progress" => %{"kind" => kind}}),
    do: {:progress, kind}

  defp record_kind(%{"type" => "event", "event" => %{"kind" => kind}}), do: {:event, kind}
  defp record_kind(%{"type" => type}), do: {:other, type}

  # The controlling client: create, acquire, attach, prompt, then hold its
  # connection open until it is killed.
  defp control(path, test) do
    {:ok, socket} = :socket.open(:local, :stream, :default)
    :ok = :socket.connect(socket, %{family: :local, path: path})

    :ok =
      send_frame(socket, %{
        "method" => "initialize",
        "request_id" => "init",
        "generations" => [V2.generation()],
        "capabilities" => []
      })

    [%{"type" => "initialized"}] = receive_records(socket, 1)

    :ok =
      send_frame(socket, %{
        "method" => "session.create",
        "request_id" => "create",
        "command_id" => Wire.encode_identity("external-create"),
        "session_options" => %{}
      })

    [%{"status" => "accepted", "session_id" => encoded}] = receive_records(socket, 1)

    :ok =
      send_frame(socket, %{
        "method" => "session.acquire_control",
        "request_id" => "acquire",
        "session_id" => encoded
      })

    [%{"result" => %{"writer_epoch" => epoch}}] = receive_records(socket, 1)

    :ok =
      send_frame(socket, %{
        "method" => "session.attach",
        "request_id" => "attach",
        "session_id" => encoded,
        "after_event_sequence" => "0"
      })

    [%{"type" => "snapshot"}] = receive_records(socket, 1)

    :ok =
      send_frame(socket, %{
        "method" => "session.prompt",
        "request_id" => "prompt",
        "command_id" => Wire.encode_identity("external-prompt"),
        "content_b64" => Wire.encode_bytes("run until aborted"),
        "writer_epoch" => epoch
      })

    [%{"type" => "admission", "status" => "accepted"}] = receive_records(socket, 1)
    {:ok, session_id} = Wire.identity(encoded)
    send(test, {:controlling, session_id})
    Process.sleep(:infinity)
  end

  defp collect(port, lines) do
    receive do
      {^port, {:data, {_flag, line}}} -> collect(port, lines ++ [line])
      {^port, {:exit_status, status}} -> {status, lines}
    after
      150_000 -> flunk("the Node client never exited: #{Enum.join(lines, "\n")}")
    end
  end

  defp await_ready(output, attempts) when attempts > 0 do
    case StringIO.contents(output) do
      {"", line} when byte_size(line) > 0 ->
        :ok

      _empty ->
        Process.sleep(10)
        await_ready(output, attempts - 1)
    end
  end

  defp await_ready(_output, 0), do: flunk("daemon never announced readiness")

  defp eventually(fun, attempts \\ 1_500) do
    cond do
      fun.() -> :ok
      attempts > 0 -> Process.sleep(20) && eventually(fun, attempts - 1)
      true -> flunk("condition never held")
    end
  end

  defp text_response(text, response_id) do
    [
      %{
        "type" => "message_start",
        "message" => %{
          "id" => response_id,
          "type" => "message",
          "role" => "assistant",
          "model" => "claude-haiku-4-5",
          "content" => [],
          "usage" => %{"input_tokens" => 4, "output_tokens" => 0}
        }
      },
      %{
        "type" => "content_block_start",
        "index" => 0,
        "content_block" => %{"type" => "text", "text" => ""}
      },
      %{
        "type" => "content_block_delta",
        "index" => 0,
        "delta" => %{"type" => "text_delta", "text" => text}
      },
      %{"type" => "content_block_stop", "index" => 0},
      %{
        "type" => "message_delta",
        "delta" => %{"stop_reason" => "end_turn", "stop_sequence" => nil},
        "usage" => %{"output_tokens" => 2}
      },
      %{"type" => "message_stop"}
    ]
    |> Enum.map_join(fn event ->
      "event: #{event["type"]}\ndata: #{Jason.encode!(event)}\n\n"
    end)
  end
end
