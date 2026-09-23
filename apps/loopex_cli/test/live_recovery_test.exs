Code.require_file(
  "../../loopex_llm_reqllm/test/support/provider_isolation_fixture.exs",
  __DIR__
)

Code.require_file("support/daemon_proxy.exs", __DIR__)

defmodule LoopexCli.LiveRecoveryTest do
  use ExUnit.Case, async: false
  @moduletag capture_log: true

  import ExUnit.CaptureIO

  alias Loopex.LLM.ReqLLM.ProviderIsolationFixture, as: ProviderFixture
  alias LoopexCli.Test.DaemonProxy
  alias LoopexDaemon.Sentinel

  @credential "live-recovery-placeholder"

  setup do
    root = Path.join(System.tmp_dir!(), "llr-#{System.unique_integer([:positive])}")
    workspace = Path.join(root, "w")
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf(root) end)
    %{root: root, workspace: workspace, socket: Path.join([root, "s", "daemon", "d.sock"])}
  end

  # Concept: a live command whose reply is lost after the daemon applied the
  # request recovers by presenting the same command identity again, so the
  # daemon applies it once and the operator sees the run once.
  #
  # Technical depth: each case puts a proxy between the command and the daemon
  # that forwards one named request, waits for the daemon's answer, discards it
  # and closes the connection. The command must reconnect through the proxy and
  # re-present the request: a create replays to the one session it made, a
  # prompt replays to its one admission (a second run would need a model reply
  # the scripted provider does not have), and a lost listing is asked once more.
  for {method, label} <- [
        {"session.create", "create"},
        {"session.prompt", "prompt"}
      ] do
    @tag timeout: 120_000
    test "a lost #{label} reply is re-presented and applied once", context do
      method = unquote(method)
      daemon = start_daemon(context, launch("#{unquote(label)} answer", unquote(label)))
      proxy = DaemonProxy.start(context.socket, [{method, 1}])

      output =
        capture_io(fn ->
          assert :ok = LoopexCli.dispatch(["run", "--daemon", proxy.path, "go"])
        end)

      assert length(String.split(output, "#{unquote(label)} answer")) == 2,
             "expected the answer exactly once: #{inspect(output)}"

      assert Enum.count(DaemonProxy.seen(proxy), &(&1 == method)) == 2
      assert length(listed_sessions(context.socket)) == 1
      stop_daemon(daemon)
    end
  end

  # Concept: the same re-presentation is a fresh admission when the first
  # write never reached the daemon, and the command then follows the new run.
  @tag timeout: 120_000
  test "a prompt the daemon never saw is sent again and followed to its answer", context do
    daemon = start_daemon(context, launch("fresh answer", "fresh"))
    proxy = DaemonProxy.start(context.socket, [{{:before, "session.prompt"}, 1}])

    output =
      capture_io(fn ->
        assert :ok = LoopexCli.dispatch(["run", "--daemon", proxy.path, "go"])
      end)

    assert length(String.split(output, "fresh answer")) == 2,
           "expected the answer exactly once: #{inspect(output)}"

    assert Enum.count(DaemonProxy.seen(proxy), &(&1 == "session.prompt")) == 2
    stop_daemon(daemon)
  end

  @tag timeout: 120_000
  test "a lost listing reply is asked once more and printed once", context do
    daemon = start_daemon(context, launch("listed answer", "listed"))
    {:ok, _output} = run(["run", "--daemon", context.socket, "go"])
    proxy = DaemonProxy.start(context.socket, [{"session.list", 1}])

    {result, output} = run(["sessions", "--daemon", proxy.path])
    assert result == :ok
    assert [line] = String.split(output, "\n", trim: true)
    assert %{"sessions" => [_one]} = JSON.decode!(line)
    assert Enum.count(DaemonProxy.seen(proxy), &(&1 == "session.list")) == 2
    stop_daemon(daemon)
  end

  defp run(argv) do
    output =
      capture_io(fn ->
        send(self(), {:result, LoopexCli.dispatch(argv)})
      end)

    {receive(do: ({:result, result} -> result)), output}
  end

  defp launch(text, label) do
    ProviderFixture.new(:reply,
      credential: @credential,
      response_bodies: [text_response(text, "msg_recovery_#{label}")]
    ).options
    |> Keyword.drop([:credential_token, :credential_registry, :tracing_capability])
  end

  defp listed_sessions(socket) do
    {:ok, client} = LoopexCli.DaemonClient.connect(socket)

    try do
      {:ok, %{"result" => %{"entries" => entries}}, _client} =
        LoopexCli.DaemonClient.request(client, "session.list", %{"limit" => 256})

      entries
    after
      LoopexCli.DaemonClient.close(client)
    end
  end

  defp start_daemon(context, provider_options) do
    state_root = Path.join(context.root, "s")
    {:ok, output} = StringIO.open("")
    test = self()

    options = [
      state_root: state_root,
      socket_path: context.socket,
      workspace: context.workspace,
      policy: LoopexCli.Policy.AllowAll,
      provider_launch: provider_options,
      credential: @credential
    ]

    task =
      Task.async(fn ->
        Sentinel.run(options, output: output, install_signals: false, notify: test)
      end)

    assert_receive {:loopex_daemon_sentinel, sentinel, owner_ref, _owner}, 5_000
    await_ready(output, 1_000)
    %{task: task, sentinel: sentinel, owner_ref: owner_ref}
  end

  defp stop_daemon(daemon) do
    send(daemon.sentinel, {:daemon_signal, daemon.owner_ref, :sigterm})
    assert Task.await(daemon.task, 30_000) == 0
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
