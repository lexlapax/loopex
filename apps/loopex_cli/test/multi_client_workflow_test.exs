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
