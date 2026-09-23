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

  # Concept: an admission the daemon cannot settle is never guessed at. The
  # command ends non-zero naming the method and command identity left
  # unresolved, and sends no later step of its plan.
  #
  # Technical depth: the proxy presents the prompt's admission as
  # `admission_unknown`; the run also carries a follow-up, which must never
  # be sent.
  @tag timeout: 120_000
  test "an unknown admission ends the command naming what is unresolved", context do
    daemon = start_daemon(context, launch("unknown answer", "unknown"))

    proxy =
      DaemonProxy.start(context.socket, [], fn bytes ->
        bytes
        |> String.split("\n")
        |> Enum.map_join("\n", &unknown_admission/1)
      end)

    {result, _output} =
      run(["run", "--daemon", proxy.path, "--follow-up", "and then", "go"])

    assert {:error, message} = result
    assert message =~ "session.prompt command"
    assert message =~ "is unresolved"
    refute "session.follow_up" in DaemonProxy.seen(proxy)
    stop_daemon(daemon)
  end

  defp unknown_admission(line) do
    case JSON.decode(line) do
      {:ok, %{"type" => "admission", "method" => "session.prompt", "request_id" => id}} ->
        JSON.encode!(%{
          "type" => "error",
          "request_id" => id,
          "code" => "admission_unknown",
          "message" => "admission outcome is unknown"
        })

      _other ->
        line
    end
  end

  # Concept: a follow-up whose reply was lost is re-presented like the prompt
  # before it and applied once.
  @tag timeout: 120_000
  test "a lost follow-up reply is re-presented and applied once", context do
    launch =
      ProviderFixture.new(:reply,
        credential: @credential,
        response_bodies: [
          text_response("first answer", "msg_recovery_first"),
          text_response("second answer", "msg_recovery_second")
        ]
      ).options
      |> Keyword.drop([:credential_token, :credential_registry, :tracing_capability])

    daemon = start_daemon(context, launch)
    proxy = DaemonProxy.start(context.socket, [{"session.follow_up", 1}])

    {result, output} =
      run(["run", "--daemon", proxy.path, "--follow-up", "and then", "go"])

    assert result == :ok, output

    for answer <- ["first answer", "second answer"] do
      assert length(String.split(output, answer)) == 2,
             "expected #{answer} exactly once: #{inspect(output)}"
    end

    assert Enum.count(DaemonProxy.seen(proxy), &(&1 == "session.follow_up")) == 2
    stop_daemon(daemon)
  end

  # Concept: a steer names the run it steers, fixed from the first durable
  # `run.started` the command saw; when its reply is lost it is re-presented
  # with that same run and identity and applied once.
  #
  # Technical depth: the provider holds the run at entry so the steer lands
  # while it is live. The proxy loses the steer's reply; after recovery the
  # command re-presents it, the provider is released, and the run's answer
  # appears once.
  @tag timeout: 120_000
  test "a lost steer reply is re-presented against the same run", context do
    provider =
      ProviderFixture.new(:delayed_entry,
        credential: @credential,
        response_bodies: [text_response("steered answer", "msg_recovery_steer")]
      )

    launch =
      Keyword.drop(provider.options, [
        :credential_token,
        :credential_registry,
        :tracing_capability
      ])

    daemon = start_daemon(context, launch)
    proxy = DaemonProxy.start(context.socket, [{"session.steer", 1}])

    command =
      Task.async(fn -> run(["run", "--daemon", proxy.path, "--steer", "look closer", "go"]) end)

    assert Enum.any?(1..3_000, fn _ ->
             Process.sleep(20)
             Enum.count(DaemonProxy.seen(proxy), &(&1 == "session.steer")) >= 2
           end),
           "the steer was not re-presented"

    ProviderFixture.release(provider)
    {result, output} = Task.await(command, 90_000)
    assert result == :ok, output
    assert length(String.split(output, "steered answer")) == 2
    assert Enum.count(DaemonProxy.seen(proxy), &(&1 == "session.steer")) == 2
    stop_daemon(daemon)
  end

  # Concept: a resume whose reply was lost is re-presented with the same
  # identity; when a replacement daemon replays it as already applied but the
  # session is dormant again, that identity is retired for one new identity,
  # which is itself re-presented after a loss rather than replaced, and exactly
  # one coordinator is activated.
  #
  # Technical depth: a session is created by an earlier daemon lifetime, so it
  # is dormant. The proxy loses the reply to the first resume request and
  # drops the third before it reaches the daemon. After the first loss the
  # daemon is stopped and a replacement started on the same root. The command
  # sends resume identities A, A, B, B, ends successfully, and the replacement
  # daemon reports one activation.
  @tag timeout: 180_000
  test "a resume replayed across a daemon replacement retires one identity for one more",
       context do
    first = start_daemon(context, launch("unused", "resume-first"))
    session_id = create_via_socket(context.socket, "resume-create")
    stop_daemon(first)

    second = start_daemon(context, launch("unused", "resume-second"))

    proxy =
      DaemonProxy.start(context.socket, [
        {"session.resume", {:nth, [1]}},
        {{:before, "session.resume"}, {2, 1}}
      ])

    command = Task.async(fn -> run(["resume", "--daemon", proxy.path, session_id]) end)

    assert_receive {:proxy_lost, "session.resume", 1}, 30_000
    stop_daemon(second)
    replacement = start_daemon(context, launch("unused", "resume-replacement"))

    {result, output} = Task.await(command, 120_000)
    assert result == :ok, output

    resumes =
      for {"session.resume", command_id} <- DaemonProxy.commands(proxy), do: command_id

    assert [a, a, b, b] = resumes
    refute a == b
    assert daemon_status(context.socket)["activations_used"] == 1
    stop_daemon(replacement)
  end

  defp daemon_status(socket) do
    {:ok, client} = LoopexCli.DaemonClient.connect(socket)

    try do
      {:ok, %{"result" => status}, _client} =
        LoopexCli.DaemonClient.request(client, "daemon.status", %{})

      status
    after
      LoopexCli.DaemonClient.close(client)
    end
  end

  defp create_via_socket(socket, label) do
    {:ok, client} = LoopexCli.DaemonClient.connect(socket)

    try do
      {:ok, %{"status" => "accepted", "session_id" => encoded}, _client} =
        LoopexCli.DaemonClient.request(client, "session.create", %{
          "command_id" => LoopexProtocol.Wire.encode_identity(label),
          "session_options" => %{}
        })

      {:ok, session_id} = LoopexProtocol.Wire.identity(encoded)
      session_id
    after
      LoopexCli.DaemonClient.close(client)
    end
  end

  # Concept: recovery has one clock, started at the first loss; a daemon that
  # never becomes reachable again ends the command when it runs out, naming
  # what is unresolved, rather than retrying forever.
  #
  # Technical depth: the prompt's reply is lost, and every later connection is
  # closed before its first request reaches the daemon. The command gives up
  # 35 seconds after the first loss.
  @tag timeout: 120_000
  test "recovery ends on its clock when the daemon stays unreachable", context do
    daemon = start_daemon(context, launch("unreached answer", "unreached"))

    proxy =
      DaemonProxy.start(context.socket, [
        {"session.prompt", 1},
        {{:before, "initialize"}, {1, 10_000}}
      ])

    started = System.monotonic_time(:millisecond)
    {result, _output} = run(["run", "--daemon", proxy.path, "go"])
    elapsed = System.monotonic_time(:millisecond) - started

    assert {:error, message} = result
    assert message =~ "did not recover in time"
    assert message =~ "session.prompt command"
    assert elapsed >= 35_000 and elapsed < 60_000, "gave up after #{elapsed} ms"
    stop_daemon(daemon)
  end

  # Concept: a complete `daemon.stopping` record is terminal: the command ends
  # successfully saying the daemon stopped and does not reconnect, which is
  # what distinguishes it from a bare end-of-file that recovery answers.
  #
  # Technical depth: the proxy replaces the run's `run.started` event with an
  # `operator_stop` record. The command ends `:ok` with the stop message on
  # standard error, and the proxy sees exactly one `initialize`.
  @tag timeout: 120_000
  test "a daemon.stopping record ends the command without reconnecting", context do
    daemon = start_daemon(context, launch("unseen answer", "stopping"))

    stopping =
      ~s({"message":"the daemon is stopping; reconnect after it restarts","reason":"operator_stop","type":"daemon.stopping"})

    proxy =
      DaemonProxy.start(context.socket, [], fn bytes ->
        bytes
        |> String.split("\n")
        |> Enum.map_join("\n", fn line ->
          case JSON.decode(line) do
            {:ok, %{"type" => "event", "event" => %{"kind" => "run.started"}}} -> stopping
            _other -> line
          end
        end)
      end)

    stderr =
      capture_io(:stderr, fn ->
        send(self(), {:result, run(["run", "--daemon", proxy.path, "go"])})
      end)

    assert_received {:result, {result, _output}}
    assert result == :ok
    assert stderr =~ "the daemon stopped"
    assert Enum.count(DaemonProxy.seen(proxy), &(&1 == "initialize")) == 1
    stop_daemon(daemon)
  end

  # Concept: a controller whose renewal is refused keeps following as an
  # observer: it says so, still shows the run to its end, and asks for control
  # no more.
  #
  # Technical depth: the provider holds the run past the first ten-second
  # renewal, and the proxy turns that renewal's grant into `control_not_held`.
  # The command reports the demotion, finishes with the run's answer, and sends
  # no further `session.acquire_control` after the refused one.
  @tag timeout: 120_000
  test "a refused renewal demotes the controller to an observer", context do
    provider =
      ProviderFixture.new(:delayed_entry,
        credential: @credential,
        response_bodies: [text_response("demoted answer", "msg_recovery_demoted")]
      )

    launch =
      Keyword.drop(provider.options, [
        :credential_token,
        :credential_registry,
        :tracing_capability
      ])

    daemon = start_daemon(context, launch)

    proxy =
      DaemonProxy.start(context.socket, [], fn bytes ->
        bytes
        |> String.split("\n")
        |> Enum.map_join("\n", fn line ->
          case JSON.decode(line) do
            {:ok,
             %{
               "method" => "session.acquire_control",
               "request_id" => id,
               "result" => %{"renewed" => true}
             }} ->
              ~s({"code":"control_not_held","message":"control is not held by this connection","request_id":"#{id}","type":"error"})

            _other ->
              line
          end
        end)
      end)

    command =
      Task.async(fn ->
        stderr =
          capture_io(:stderr, fn ->
            send(self(), {:result, run(["run", "--daemon", proxy.path, "go"])})
          end)

        {receive(do: ({:result, result} -> result)), stderr}
      end)

    assert Enum.any?(1..1_000, fn _ ->
             Process.sleep(20)
             Enum.count(DaemonProxy.seen(proxy), &(&1 == "session.acquire_control")) >= 2
           end)

    Process.sleep(500)
    ProviderFixture.release(provider)
    {{result, output}, stderr} = Task.await(command, 90_000)
    assert result == :ok
    assert output =~ "demoted answer"
    assert stderr =~ "continuing as an observer"
    assert Enum.count(DaemonProxy.seen(proxy), &(&1 == "session.acquire_control")) == 2
    stop_daemon(daemon)
  end

  # Concept: a recovering controller never forces a live holder off: when
  # another client took control after its own lease lapsed, it ends saying so
  # rather than retrying against that holder.
  #
  # Technical depth: the prompt's reply is lost, and every reconnection's
  # acquisition is refused while this test's own client waits for the lapsed
  # lease and takes it. The command then ends with an error naming another
  # client as the controller.
  @tag timeout: 120_000
  test "a recovering controller yields to a client that took over", context do
    provider =
      ProviderFixture.new(:delayed_entry,
        credential: @credential,
        response_bodies: [text_response("taken answer", "msg_recovery_taken")]
      )

    launch =
      Keyword.drop(provider.options, [
        :credential_token,
        :credential_registry,
        :tracing_capability
      ])

    daemon = start_daemon(context, launch)
    proxy = DaemonProxy.start(context.socket, [{"session.prompt", 1}])
    command = Task.async(fn -> run(["run", "--daemon", proxy.path, "go"]) end)
    assert_receive {:proxy_lost, "session.prompt", 1}, 30_000
    session_id = listed_session(context.socket)
    {:ok, rival} = LoopexCli.DaemonClient.connect(context.socket)

    # The recovering command and the rival both ask for control until the lost
    # lease lapses, and either could ask first; the command is held still so
    # the rival is the one that takes over, then it resumes and must yield.
    true = :erlang.suspend_process(command.pid)
    assert take_over(rival, session_id, 200)
    true = :erlang.resume_process(command.pid)

    {result, _output} = Task.await(command, 90_000)
    assert result == {:error, "another client now controls this session"}
    LoopexCli.DaemonClient.close(rival)
    ProviderFixture.release(provider)
    stop_daemon(daemon)
  end

  defp take_over(client, session_id, attempts) do
    case LoopexCli.DaemonClient.request(client, "session.acquire_control", %{
           "session_id" => LoopexProtocol.Wire.encode_identity(session_id)
         }) do
      {:ok, %{"type" => "result"}, _client} ->
        true

      {:ok, _refused, _client} when attempts > 0 ->
        Process.sleep(250)
        take_over(client, session_id, attempts - 1)

      _other ->
        false
    end
  end

  defp listed_session(socket) do
    {:ok, client} = LoopexCli.DaemonClient.connect(socket)

    try do
      {:ok, %{"result" => %{"entries" => [%{"session_id" => encoded}]}}, _client} =
        LoopexCli.DaemonClient.request(client, "session.list", %{"limit" => 1})

      {:ok, session_id} = LoopexProtocol.Wire.identity(encoded)
      session_id
    after
      LoopexCli.DaemonClient.close(client)
    end
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
