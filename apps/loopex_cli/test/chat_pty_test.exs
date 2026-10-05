Code.require_file("../../loopex/test/support/m1_runtime_helper.exs", __DIR__)
Code.require_file("../../loopex/test/support/agent_loop_helper.exs", __DIR__)

defmodule LoopexCli.ChatPTYTest do
  use ExUnit.Case, async: false
  @moduletag timeout: 120_000
  @launcher Path.expand("../bin/loopex", __DIR__)

  setup_all do
    root = Path.join(System.tmp_dir!(), "chat-pty-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    beams = Path.join(root, "beams")
    File.mkdir!(beams)

    for {module, bytes} <- Code.compile_file(Path.join(__DIR__, "support/chat_pty_driver.txt")) do
      File.write!(Path.join(beams, Atom.to_string(module) <> ".beam"), bytes)
    end

    paths =
      [beams | Enum.map(:code.get_path(), &List.to_string/1)]
      |> Enum.map_join(" ", &("-pa " <> shell_quote(&1)))

    elixir = System.find_executable("elixir") || flunk("elixir executable unavailable")
    store = Path.expand("../../loopex/test/support/m1_runtime_helper.exs", __DIR__)
    loop = Path.expand("../../loopex/test/support/agent_loop_helper.exs", __DIR__)
    stand_in = Path.join(root, "stand-in")

    # Concept: the fixture keeps the product escript's terminal signal startup.
    # Technical depth: both supported escript launchers supply +B. Plain Elixir
    # would reinstall the VM break handler over the shell's inherited SIG_IGN.
    # Keep that escript default and the product's Latin-1 boot encoding here.
    File.write!(stand_in, """
    #!/bin/sh
    exec #{shell_quote(elixir)} --erl '+B -kernel standard_io_encoding latin1' #{paths} -r #{shell_quote(store)} -r #{shell_quote(loop)} -e 'LoopexCli.ChatPTYDriver.main()' -- "$@"
    """)

    File.chmod!(stand_in, 0o755)
    %{root: root, stand_in: stand_in}
  end

  test "terminal refusal stays usable while steer and queued follow-up preserve wait ordering",
       f do
    state = start_case(f, "controls")
    write_terminal(state, "one\n")
    assert control(state.socket) == :holding

    write_terminal(
      state,
      "implicit active prompt\n/steer PTY steer\n/follow-up PTY follow-up\n/wait\n/status\n"
    )

    state = await_record(state, &(&1["event"] == "input" and &1["input_sequence"] == "5"))
    inputs = Enum.filter(records(state.transcript), &(&1["event"] == "input"))
    assert Enum.map(inputs, & &1["input_sequence"]) == ~w(1 2 3 4 5)
    assert Enum.at(inputs, 1)["disposition"] == "refused"
    assert Enum.at(inputs, 2)["disposition"] == "admitted"
    assert Enum.at(inputs, 3)["disposition"] == "admitted"
    refute Enum.any?(records(state.transcript), &(&1["event"] == "status"))
    assert :ok = :gen_tcp.send(state.socket, :erlang.term_to_binary(:release))
    state = await_record(state, &(&1["event"] == "status"))
    barriers = Enum.filter(records(state.transcript), &(&1["event"] == "wait"))
    assert [barrier] = barriers
    assert barrier["state"] == "settled"
    assert barrier["outcome"]["outcome"] == "completed"
    controls = records(state.transcript)

    assert Enum.find_index(controls, &(&1 == barrier)) <
             Enum.find_index(controls, &(&1["event"] == "input" and &1["input_sequence"] == "6"))

    write_terminal(state, "/quit\n")
    {state, evidence, messages} = finish_case(state, 0)
    assert {:model_down, :normal} in messages
    assert [first, steered, followed] = evidence.requests
    assert Enum.any?(first["messages"], &(&1["content"] == "one"))
    assert Enum.any?(steered["messages"], &(&1["content"] == "PTY steer"))

    assert Enum.any?(
             steered["messages"],
             &(&1["role"] == "tool" and &1["content"] == "tool output for pty-write")
           )

    assert Enum.any?(followed["messages"], &(&1["content"] == "PTY follow-up"))

    refute Enum.any?(
             Enum.flat_map(evidence.requests, & &1["messages"]),
             &(&1["content"] == "implicit active prompt")
           )

    assert [job] = evidence.jobs
    assert job["tool_call_id"] == "pty-write"
    assert job["validated_arguments"] == %{"path" => "note.txt", "content" => "retained"}

    assert Enum.any?(
             evidence.events,
             &(&1["kind"] == "tool.finished" and &1["outcome"] == "completed")
           )

    assert [first_terminal, follow_terminal] =
             Enum.filter(evidence.events, &(&1["kind"] == "run.finished"))

    assert first_terminal["outcome"] == "completed"
    assert follow_terminal["outcome"] == "completed"
    assert first_terminal["run_id"] != follow_terminal["run_id"]
    assert LoopexProtocol.Wire.encode_identity(follow_terminal["run_id"]) == barrier["run_id"]
    assert List.last(records(state.transcript))["last_outcome"] == barrier["outcome"]
  end

  test "terminal answers the actual question identity and preserves exact text", f do
    state = start_case(f, "answer")
    write_terminal(state, "one\n/wait\n")
    state = await_record(state, &(&1["event"] == "wait" and &1["state"] == "question"))
    question = Enum.find(records(state.transcript), &(&1["event"] == "question"))
    assert_question_order(state, question)
    answer = " keep --choice literal "

    write_terminal(
      state,
      "/answer " <>
        question["interaction_id"] <> " --text " <> JSON.encode!(answer) <> "\n/wait\n/quit\n"
    )

    {_, evidence, _} = finish_case(state, 0)
    assert [_asked, answered] = evidence.requests
    assert Enum.any?(answered["messages"], &(&1["role"] == "tool" and &1["content"] == answer))
    assert evidence.jobs == []

    assert Enum.any?(
             evidence.events,
             &(&1["kind"] == "interaction.answered" and
                 LoopexProtocol.Wire.encode_identity(&1["interaction_id"]) ==
                   question["interaction_id"])
           )
  end

  test "terminal declines the actual pending question without dispatching an executor effect",
       f do
    state = start_case(f, "decline")
    write_terminal(state, "one\n/wait\n")
    state = await_record(state, &(&1["event"] == "wait" and &1["state"] == "question"))
    question = Enum.find(records(state.transcript), &(&1["event"] == "question"))
    assert_question_order(state, question)
    write_terminal(state, "/decline " <> question["interaction_id"] <> "\n/wait\n/quit\n")
    {_, evidence, _} = finish_case(state, 0)
    assert [_asked, declined] = evidence.requests

    assert Enum.any?(
             declined["messages"],
             &(&1["role"] == "tool" and &1["content"] =~ "declined")
           )

    assert evidence.jobs == []

    assert Enum.any?(
             evidence.events,
             &(&1["kind"] == "interaction.declined" and &1["disposition"] == "declined" and
                 LoopexProtocol.Wire.encode_identity(&1["interaction_id"]) ==
                   question["interaction_id"])
           )
  end

  test "foreground terminal Ctrl-C cancels an active run and joins its blocked reader and OS group",
       f do
    state = start_case(f, "interrupt")
    write_terminal(state, "one\n")
    assert control(state.socket) == :holding
    assert :ok = :gen_tcp.send(state.socket, :erlang.term_to_binary(:inspect_reader))
    assert control(state.socket) == :reader_blocked
    terminal_command(state, %{"action" => "interrupt"})
    {_, evidence, messages} = finish_case(state, 1)
    assert {:reader_down, :killed} in messages
    assert {:model_down, :killed} in messages
    assert length(evidence.requests) == 1
    assert evidence.jobs == []
    assert [terminal] = Enum.filter(evidence.events, &(&1["kind"] == "run.finished"))
    assert terminal["outcome"] == "cancelled"
  end

  defp assert_question_order(state, question) do
    assert question["producer"] == "model_tool" and question["kind"] == "text"
    assert question["question"] == "PTY question?"
    assert question["choices"] == []
    controls = records(state.transcript)
    assert [barrier] = Enum.filter(controls, &(&1["event"] == "wait"))
    assert barrier["interaction_id"] == question["interaction_id"]
    assert barrier["run_id"] == question["run_id"]

    assert Enum.find_index(controls, &(&1["event"] == "input" and &1["input_sequence"] == "1")) <
             Enum.find_index(controls, &(&1 == question))
  end

  defp start_case(f, scenario) do
    root = Path.join(f.root, scenario)
    File.mkdir_p!(Path.join(root, "workspace"))
    File.mkdir!(Path.join(root, "state"))
    File.mkdir!(Path.join(root, "home"))
    path = Path.join(root, "config.json")

    profile = %{
      "schema_version" => 1,
      "providers" => %{"anthropic" => %{"credential" => %{"env" => "M7_PTY_SLOT"}}},
      "policy" => "allow-all",
      "paths" => %{"workspace" => "workspace", "state_root" => "state"},
      "session" => %{
        "model" => "anthropic:claude-haiku-4-5",
        "tools" => "coding",
        "system_class_tokens" => 8000,
        "bounds" => %{"max_turns" => 8, "deadline_ms" => 1000, "token_budget" => 10000}
      }
    }

    File.write!(path, JSON.encode!(profile))

    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, packet: 4, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, {_, control_port}} = :inet.sockname(listener)
    python = System.find_executable("python3") || flunk("python3 is unavailable")

    port =
      Port.open({:spawn_executable, python}, [
        :binary,
        :exit_status,
        {:line, 131_072},
        args: [Path.join(__DIR__, "support/chat_pty.py"), @launcher, "chat"],
        env: [
          {~c"LOOPEX_ESCRIPT", String.to_charlist(f.stand_in)},
          {~c"LOOPEX_HOME", String.to_charlist(Path.join(root, "home"))},
          {~c"LOOPEX_CHAT_PTY_PORT", Integer.to_charlist(control_port)},
          {~c"LOOPEX_CHAT_PTY_SCENARIO", String.to_charlist(scenario)},
          {~c"LOOPEX_CHAT_PTY_CONFIG", String.to_charlist(path)},
          {~c"ERL_CRASH_DUMP", ~c"/dev/null"},
          {~c"ERL_CRASH_DUMP_SECONDS", ~c"0"}
        ]
      ])

    monitor = :erlang.monitor(:port, port)
    Process.put(:pty_port, port)
    assert {:os_pid, python_pid} = Port.info(port, :os_pid)
    started = port_event(port)
    assert started["event"] == "started"
    assert started["launcher"] == started["group"]
    group = started["group"]

    on_exit(fn ->
      System.cmd("/bin/kill", ["-KILL", "--", "-#{group}"], stderr_to_stdout: true)
      await_group_down(group, System.monotonic_time(:millisecond) + 5000)
      if Port.info(port), do: Port.close(port)
      :gen_tcp.close(listener)
    end)

    assert {:ok, socket} = :gen_tcp.accept(listener, 15_000)
    on_exit(fn -> :gen_tcp.close(socket) end)
    assert {:pid, child} = control(socket)
    assert {:ready, :interactive, 0, ^child} = control(socket)

    %{
      port: port,
      socket: socket,
      monitor: monitor,
      group: group,
      python_pid: python_pid,
      child: child,
      transcript: ""
    }
  end

  defp write_terminal(state, bytes),
    do:
      terminal_command(
        state,
        %{"action" => "write", "bytes" => Base.encode64(bytes)}
      )

  defp terminal_command(state, command),
    do: true = Port.command(state.port, JSON.encode!(command) <> "\n")

  defp await_record(state, predicate) do
    if Enum.any?(records(state.transcript), predicate) do
      state
    else
      event = port_event(state.port)
      assert event["event"] == "output", inspect(event)

      await_record(
        %{state | transcript: state.transcript <> Base.decode64!(event["bytes"])},
        predicate
      )
    end
  end

  defp finish_case(state, expected_code) do
    messages = collect_controls(state.socket, [])

    assert {:evidence, evidence, ^expected_code} =
             Enum.find(messages, &match?({:evidence, _, _}, &1))

    assert evidence.runtime_joined and evidence.transport_joined
    assert evidence.provisional["cleanup"] == "confirmed"

    for request <- evidence.requests do
      assert Base.encode16(:crypto.hash(:sha256, request["canonical_request_bytes"]),
               case: :lower
             ) ==
               request["staged_request_digest"]
    end

    state = collect_terminal(state, expected_code)
    assert_receive {port, {:exit_status, ^expected_code}} when port == state.port, 10_000

    assert_receive {:DOWN, reference, :port, port, :normal}
                   when reference == state.monitor and port == state.port,
                   5_000

    closing = List.last(records(state.transcript))
    assert closing["event"] == "closing" and closing["cleanup"] == "confirmed"
    assert closing["exit_code"] == expected_code

    for pid <- [state.python_pid, state.group, String.to_integer(state.child)] do
      assert {_, status} =
               System.cmd("/bin/kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true)

      assert status != 0
    end

    {state, evidence, messages}
  end

  defp collect_controls(socket, messages) do
    case control(socket) do
      :helpers_joined -> Enum.reverse(messages)
      message -> collect_controls(socket, [message | messages])
    end
  end

  defp collect_terminal(state, expected_code) do
    case port_event(state.port) do
      %{"event" => "output", "bytes" => bytes} ->
        collect_terminal(
          %{state | transcript: state.transcript <> Base.decode64!(bytes)},
          expected_code
        )

      %{"event" => "interrupt", "isig" => true, "foreground" => group} ->
        assert group == state.group
        collect_terminal(state, expected_code)

      %{"event" => "exited", "status" => ^expected_code, "group_gone" => true} ->
        state

      event ->
        flunk("unexpected PTY event: #{inspect(event)}")
    end
  end

  defp records(transcript) do
    for [_, json] <- Regex.scan(~r/@loopex ([^\r\n]+)/, transcript), do: JSON.decode!(json)
  end

  defp control(socket) do
    case :gen_tcp.recv(socket, 0, 15_000) do
      {:ok, bytes} ->
        :erlang.binary_to_term(bytes, [:safe])

      error ->
        flunk(
          "PTY control failed #{inspect(error)}: #{failed_terminal(Process.get(:pty_port), "")}"
        )
    end
  end

  defp failed_terminal(port, transcript) do
    receive do
      {^port, {:data, {:eol, json}}} ->
        case JSON.decode!(json) do
          %{"event" => "output", "bytes" => bytes} ->
            failed_terminal(port, transcript <> Base.decode64!(bytes))

          %{"event" => "exited"} ->
            transcript

          _ ->
            failed_terminal(port, transcript)
        end

      {^port, {:exit_status, _}} ->
        transcript
    after
      5000 -> transcript
    end
  end

  defp port_event(port) do
    receive do
      {^port, {:data, {:eol, json}}} -> JSON.decode!(json)
      {^port, {:exit_status, status}} -> flunk("PTY exited early: #{status}")
    after
      15_000 -> flunk("PTY driver did not report an event")
    end
  end

  defp shell_quote(text), do: "'" <> String.replace(text, "'", "'\\''") <> "'"

  defp await_group_down(group, cutoff) do
    case System.cmd("/bin/kill", ["-0", "--", "-#{group}"], stderr_to_stdout: true) do
      {_, 0} ->
        if System.monotonic_time(:millisecond) >= cutoff,
          do: flunk("PTY process group survived cleanup")

        receive do
        after
          10 -> await_group_down(group, cutoff)
        end

      {_, _} ->
        :ok
    end
  end
end
