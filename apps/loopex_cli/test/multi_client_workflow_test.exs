Code.require_file(
  "../../loopex_llm_reqllm/test/support/provider_isolation_fixture.exs",
  __DIR__
)

defmodule LoopexCli.MultiClientWorkflowTest do
  use ExUnit.Case, async: false
  @moduletag capture_log: true

  alias Loopex.LLM.ReqLLM.ProviderIsolationFixture, as: ProviderFixture

  @credential "multi-client-placeholder"

  # Concept: the operator workflow with every step a command an operator
  # types, each in its own operating-system process: import a released root,
  # start the daemon, run a task through it, list, refuse to observe a session
  # this daemon has not activated, resume, and stop.
  @tag timeout: 300_000
  test "an operator moves a released root to a daemon and drives it from separate processes" do
    root = Path.join(System.tmp_dir!(), "lmw-#{System.unique_integer([:positive])}")
    state_root = Path.join(root, "s")
    workspace = Path.join(root, "w")
    File.mkdir_p!(state_root)
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf(root) end)

    # A released root with one recorded session and no daemon index.
    {:ok, placement} = Loopex.runtime_placement_id(state_root)
    :ok = Loopex.track_session(state_root, "s-legacy", placement)

    assert {0, _output} = cli(["daemon", "prepare-index", "--state-root", state_root])

    provider =
      ProviderFixture.new(:reply,
        credential: @credential,
        response_bodies: [text_response("workflow answer", "msg_workflow")]
      )

    launch = Path.join(root, "provider.launch")

    File.write!(
      launch,
      :io_lib.format(~c"~tp.~n", [
        Keyword.drop(provider.options, [
          :credential_token,
          :credential_registry,
          :tracing_capability
        ])
      ])
    )

    socket = Path.join([state_root, "daemon", "d.sock"])

    {daemon, daemon_pid} =
      start(
        [
          "daemon",
          "--state-root",
          state_root,
          "--workspace",
          workspace,
          "--provider-launch",
          launch,
          "--policy",
          "allow-all",
          "--socket",
          socket
        ],
        [:use_stdio]
      )

    assert %{"record" => "daemon_ready", "version" => "0.2.0"} =
             daemon |> await_line(60_000) |> JSON.decode!()

    {0, run_output} = cli(["run", "--daemon", socket, "go"])
    assert run_output =~ "workflow answer"
    [_, session_id] = Regex.run(~r/loopex: session (\S+)/, run_output)

    {0, listing} = cli(["sessions", "--daemon", socket])

    %{"sessions" => sessions} =
      listing |> String.split("\n", trim: true) |> List.last() |> JSON.decode!()

    residency = Map.new(sessions, &{&1["session_id"], &1["residency"]})
    assert residency == %{"s-legacy" => "dormant", session_id => "active"}

    {status, refusal} = cli(["attach", "s-legacy", "--daemon", socket])
    assert status == 1
    assert refusal =~ "dormant"

    assert {0, _resumed} = cli(["resume", "--daemon", socket, session_id])

    {_output, 0} = System.cmd("/bin/kill", ["-TERM", Integer.to_string(daemon_pid)])
    assert await_exit(daemon, 60_000) == 0
  end

  # Concept: the cross-process takeover an operator relies on, with every
  # participant its own operating-system process: the reference CLI controls a
  # running session through a daemon, the independent Node client observes
  # it, the CLI is killed, and the observer waits out the lease, takes control
  # and aborts the work the killed controller started.
  #
  # Technical depth: the scripted provider holds its companion at entry, so
  # the run is still in flight when the controller dies. `SIGKILL` sends no
  # release, so the Node client's first acquisitions are refused until the
  # thirty-second term lapses; the case asserts more than one attempt, the
  # accepted abort and the durable `run.finished`, then that the daemon still
  # stops orderly.
  @tag :node_client
  @tag timeout: 300_000
  test "a Node observer takes over and aborts after the controlling CLI is killed" do
    node = System.find_executable("node") || flunk("Node is unavailable on this host")
    root = Path.join(System.tmp_dir!(), "lmt-#{System.unique_integer([:positive])}")
    state_root = Path.join(root, "s")
    workspace = Path.join(root, "w")
    File.mkdir_p!(state_root)
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf(root) end)

    provider =
      ProviderFixture.new(:delayed_entry,
        credential: @credential,
        response_bodies: [text_response("never finished", "msg_takeover_held")]
      )

    launch = Path.join(root, "provider.launch")

    File.write!(
      launch,
      :io_lib.format(~c"~tp.~n", [
        Keyword.drop(provider.options, [
          :credential_token,
          :credential_registry,
          :tracing_capability
        ])
      ])
    )

    socket = Path.join([state_root, "daemon", "d.sock"])

    {daemon, daemon_pid} =
      start(
        [
          "daemon",
          "--state-root",
          state_root,
          "--workspace",
          workspace,
          "--provider-launch",
          launch,
          "--policy",
          "allow-all",
          "--socket",
          socket
        ],
        [:use_stdio]
      )

    assert %{"record" => "daemon_ready"} = daemon |> await_line(60_000) |> JSON.decode!()

    {controller, controller_pid} =
      start(["run", "--daemon", socket, "hold the line"], [:stderr_to_stdout])

    session_id = await_session(controller, 60_000)
    eventually(fn -> ProviderFixture.reached?(provider, "pid") end)

    script = Path.expand("../../../clients/node/daemon-takeover.mjs", __DIR__)

    observer =
      Port.open({:spawn_executable, node}, [
        :binary,
        :exit_status,
        {:line, 65_536},
        args: [script, socket, session_id]
      ])

    assert_receive {^observer, {:data, {:eol, ~s({"attached":true})}}}, 30_000
    {_output, 0} = System.cmd("/bin/kill", ["-KILL", Integer.to_string(controller_pid)])
    assert await_exit(controller, 10_000) != 0

    {status, lines} = collect(observer, [])
    assert status == 0, lines

    assert %{"granted" => true, "abort" => "accepted", "finished" => true, "attempts" => attempts} =
             lines |> String.split("\n", trim: true) |> List.last() |> JSON.decode!()

    # The killed controller released nothing, so taking over had to wait.
    assert attempts > 1

    ProviderFixture.release(provider)
    {_output, 0} = System.cmd("/bin/kill", ["-TERM", Integer.to_string(daemon_pid)])
    assert await_exit(daemon, 120_000) == 0
  end

  defp await_session(port, bound) do
    receive do
      {^port, {:data, {:eol, line}}} ->
        case Regex.run(~r/loopex: session (\S+)/, line) do
          [_, session_id] -> session_id
          nil -> await_session(port, bound)
        end

      {^port, {:exit_status, status}} ->
        flunk("the controller exited #{status} before naming its session")
    after
      bound -> flunk("the controller never named its session")
    end
  end

  defp eventually(predicate, attempts \\ 3_000) do
    cond do
      predicate.() -> :ok
      attempts == 0 -> flunk("condition never held")
      true -> Process.sleep(10) && eventually(predicate, attempts - 1)
    end
  end

  defp cli(argv) do
    {port, _pid} = start(argv, [:stderr_to_stdout])
    collect(port, [])
  end

  defp start(argv, extra) do
    executable = System.find_executable("elixir") || raise "elixir executable unavailable"

    port =
      Port.open(
        {:spawn_executable, String.to_charlist(executable)},
        [
          :binary,
          :exit_status,
          :hide,
          {:line, 65_536},
          env: [{~c"LOOPEX_PROVIDER_API_KEY", String.to_charlist(@credential)}]
        ] ++
          extra ++
          [
            args:
              Enum.flat_map(:code.get_path(), fn dir -> ["-pa", List.to_string(dir)] end) ++
                ["-e", "LoopexCli.main(#{inspect(argv)})"]
          ]
      )

    {:os_pid, os_pid} = Port.info(port, :os_pid)

    on_exit(fn ->
      System.cmd("/bin/kill", ["-KILL", Integer.to_string(os_pid)], stderr_to_stdout: true)
    end)

    {port, os_pid}
  end

  defp collect(port, lines) do
    receive do
      {^port, {:data, {_flag, line}}} -> collect(port, [line | lines])
      {^port, {:exit_status, status}} -> {status, lines |> Enum.reverse() |> Enum.join("\n")}
    after
      120_000 -> flunk("a command did not exit: #{Enum.join(Enum.reverse(lines), "\n")}")
    end
  end

  defp await_line(port, bound) do
    receive do
      {^port, {:data, {:eol, line}}} -> line
      {^port, {:exit_status, status}} -> flunk("the daemon exited #{status} before readiness")
    after
      bound -> flunk("the daemon never announced readiness")
    end
  end

  defp await_exit(port, bound) do
    receive do
      {^port, {:exit_status, status}} -> status
      {^port, {:data, _line}} -> await_exit(port, bound)
    after
      bound -> flunk("the daemon never exited")
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
