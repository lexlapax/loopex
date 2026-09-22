Code.require_file(
  "../../loopex_llm_reqllm/test/support/provider_isolation_fixture.exs",
  __DIR__
)

defmodule LoopexCli.LiveDaemonTest do
  use ExUnit.Case, async: false
  @moduletag capture_log: true

  import ExUnit.CaptureIO

  alias Loopex.LLM.ReqLLM.ProviderIsolationFixture, as: ProviderFixture
  alias LoopexDaemon.Sentinel

  @credential "live-daemon-placeholder"

  setup do
    root = Path.join(System.tmp_dir!(), "lld-#{System.unique_integer([:positive])}")
    workspace = Path.join(root, "w")
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf(root) end)
    %{root: root, workspace: workspace, socket: Path.join([root, "s", "daemon", "d.sock"])}
  end

  test "every refused live form names its reason and never dials", %{socket: socket} do
    refused = [
      {"run", ["--daemon", socket, "--policy", "allow-all", "p"], "unrecognised option"},
      {"run", ["--daemon", socket, "--state-root", "x", "p"], "unrecognised option"},
      {"run", ["--daemon", socket, "--skill", "x", "p"], "unrecognised option"},
      {"run", ["--daemon", socket, "--skill-resource", "x", "p"], "unrecognised option"},
      {"run", ["--daemon", socket, "--workspace", "x", "p"], "unrecognised option"},
      {"run", ["--daemon", socket, "--cleanup-grace-ms", "1", "p"], "unrecognised option"},
      {"run", ["--daemon", socket, "--context-token-budget", "1", "p"], "unrecognised option"},
      {"run", ["--daemon", socket, "--steer", "a", "--follow-up", "b", "p"],
       "cannot be combined"},
      {"run", ["--daemon", socket, "--follow-up", "b", "--steer", "a", "p"],
       "cannot be combined"},
      {"run", ["--daemon", socket, "--daemon", socket, "p"], "only once"},
      {"run", ["--daemon", socket, "--steer"], "requires a value"},
      {"run", ["--daemon", socket, "--steer", "", "p"], "requires a value"},
      {"run", ["--daemon=", "p"], "requires a value"},
      {"run", ["--daemon", socket], "exactly one prompt"},
      {"run", ["--daemon", socket, "a", "b"], "exactly one prompt"},
      {"resume", ["--daemon", socket, "--policy", "allow-all", "s"], "unrecognised option"},
      {"resume", ["--daemon", socket], "one session id"},
      {"sessions", ["--daemon", socket, "--state-root", "x"], "unrecognised option"},
      {"sessions", ["--daemon", socket, "--status", "--limit", "1"], "cannot be combined"},
      {"sessions", ["--daemon", socket, "--status", "--after", "s"], "cannot be combined"},
      {"sessions", ["--daemon", socket, "--limit", "0"], "from 1 to 256"},
      {"sessions", ["--daemon", socket, "--limit", "257"], "from 1 to 256"},
      {"sessions", ["--daemon", socket, "--limit", "x"], "from 1 to 256"},
      {"sessions", ["--daemon", socket, "--status=yes"], "takes no value"},
      {"sessions", ["--daemon", socket, "extra"], "takes no arguments"},
      {"attach", ["s", "--daemon", socket, "--observe", "--take-over"], "cannot be combined"},
      {"attach", ["s", "--daemon", socket, "--prompt", "p"], "requires --take-over"},
      {"attach", ["s", "--daemon", socket, "--observe", "--prompt", "p"], "requires --take-over"},
      {"attach", ["s", "--daemon", socket, "--after", "-1"], "unsigned event sequence"},
      {"attach", ["s", "--daemon", socket, "--after", "18446744073709551616"],
       "unsigned event sequence"},
      {"attach", ["s", "--daemon", socket, "--take-over", "--take-over"], "only once"},
      {"attach", ["--daemon", socket], "one session id"},
      {"attach", ["a", "b", "--daemon", socket], "one session id"}
    ]

    for {form, arguments, reason} <- refused do
      assert {:error, message} = LoopexCli.dispatch([form | arguments]),
             "#{form} #{inspect(arguments)} was not refused"

      assert message =~ reason, "#{form} #{inspect(arguments)}: #{message}"
    end

    refute File.exists?(socket)

    # `--` ends options, so a prompt spelled `--daemon` stays an offline prompt.
    refute LoopexCli.Live.daemon_form?(["--policy", "allow-all", "--", "--daemon"])
    assert LoopexCli.Live.daemon_form?(["--daemon=#{socket}", "p"])

    for {form, arguments} <- [
          {"run", ["--daemon", socket, "p"]},
          {"run", ["--daemon=#{socket}", "--steer=a", "p"]},
          {"sessions", ["--daemon", socket, "--limit", "256", "--after", "s"]},
          {"sessions", ["--daemon", socket, "--limit", "1"]},
          {"attach", ["s", "--daemon", socket, "--after", "18446744073709551615"]},
          {"attach", ["s", "--daemon", socket, "--take-over"]},
          {"attach", ["--daemon", socket, "--", "--s"]}
        ] do
      assert LoopexCli.dispatch([form | arguments]) ==
               {:error, "cannot reach a daemon at that socket"},
             "#{form} #{inspect(arguments)}"
    end
  end

  test "run, sessions, resume and attach drive one daemon session end to end", context do
    provider =
      ProviderFixture.new(:reply,
        credential: @credential,
        response_bodies: [
          text_response("first answer", "msg_live_first"),
          text_response("second answer", "msg_live_second")
        ]
      )

    launch =
      Keyword.drop(provider.options, [
        :credential_token,
        :credential_registry,
        :tracing_capability
      ])

    daemon = start_daemon(context, launch)
    socket = context.socket

    output =
      capture_io(fn -> assert :ok = LoopexCli.dispatch(["run", "--daemon", socket, "go"]) end)

    assert output =~ "first answer"

    listing =
      capture_io(fn -> assert :ok = LoopexCli.dispatch(["sessions", "--daemon", socket]) end)

    assert [session_id] = String.split(listing, "\n", trim: true)

    status =
      capture_io(fn ->
        assert :ok = LoopexCli.dispatch(["sessions", "--daemon", socket, "--status"])
      end)

    assert status =~ "active_sessions 1"
    assert status =~ "attachments 0"

    # An idle session shows its history and ends; the finished run is history.
    observed =
      capture_io(fn ->
        assert :ok = LoopexCli.dispatch(["attach", session_id, "--daemon", socket])
      end)

    assert observed =~ "first answer"

    resumed =
      capture_io(fn ->
        assert :ok = LoopexCli.dispatch(["resume", "--daemon", socket, session_id])
      end)

    assert resumed =~ "first answer"

    taken =
      capture_io(fn ->
        assert :ok =
                 LoopexCli.dispatch([
                   "attach",
                   session_id,
                   "--daemon",
                   socket,
                   "--take-over",
                   "--prompt",
                   "again"
                 ])
      end)

    assert taken =~ "second answer"

    # Every controller released its lease: a fresh take-over is granted at once.
    assert {:ok, _} =
             :timer.tc(fn ->
               capture_io(fn ->
                 assert :ok =
                          LoopexCli.dispatch([
                            "attach",
                            session_id,
                            "--daemon",
                            socket,
                            "--take-over"
                          ])
               end)
             end)
             |> then(fn {micros, _output} ->
               if micros < 900_000, do: {:ok, micros}, else: :slow
             end)

    stop_daemon(daemon)

    # A new daemon lifetime holds the session dormant: attach refuses, and
    # resume takes the verified dormant branch, then shows the history.
    daemon = start_daemon(context, launch)

    assert {:error, dormant} = LoopexCli.dispatch(["attach", session_id, "--daemon", socket])
    assert dormant =~ "dormant"

    reactivated =
      capture_io(fn ->
        assert :ok = LoopexCli.dispatch(["resume", "--daemon", socket, session_id])
      end)

    assert reactivated =~ "first answer"
    assert reactivated =~ "second answer"

    observed =
      capture_io(fn ->
        assert :ok = LoopexCli.dispatch(["attach", session_id, "--daemon", socket, "--observe"])
      end)

    assert observed =~ "second answer"
    stop_daemon(daemon)
  end

  test "attach refuses a session this daemon lifetime has not activated", context do
    daemon = start_daemon(context, [])
    socket = context.socket

    assert {:error, message} =
             LoopexCli.dispatch(["attach", "no-such-session", "--daemon", socket])

    assert message =~ "refused" or message =~ "dormant"
    stop_daemon(daemon)
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
