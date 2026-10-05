Code.require_file("../../loopex/test/support/m1_runtime_helper.exs", __DIR__)
Code.require_file("../../loopex/test/support/agent_loop_helper.exs", __DIR__)

defmodule LoopexCli.ChatPipeTest do
  use ExUnit.Case, async: false
  @moduletag timeout: 120_000
  @launcher Path.expand("../bin/loopex", __DIR__)

  setup_all do
    root = Path.join(System.tmp_dir!(), "chat-pipe-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    beams = Path.join(root, "beams")
    File.mkdir!(beams)

    # Concept: both transport suites reuse one driver without replacing VM code.
    # Technical depth: each suite compiles its own private module name, so the
    # complete PTY and pipe files can run together without module redefinition.
    driver_path = Path.join(__DIR__, "support/chat_pty_driver.txt")

    source =
      File.read!(driver_path)
      |> String.replace(
        "defmodule LoopexCli.ChatPTYDriver do",
        "defmodule LoopexCli.ChatPipeDriver do",
        global: false
      )

    for {module, bytes} <- Code.compile_string(source, driver_path) do
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
    exec #{shell_quote(elixir)} --erl '+B -kernel standard_io_encoding latin1' #{paths} -r #{shell_quote(store)} -r #{shell_quote(loop)} -e 'LoopexCli.ChatPipeDriver.main()' -- "$@"
    """)

    File.chmod!(stand_in, 0o755)
    %{root: root, stand_in: stand_in}
  end

  test "fragmented UTF-8 and CRLF admit only after the terminator and settled stdin half-close succeeds",
       f do
    state = start_case(f, "pipe-prompt")
    state = write_pipe(state, "h" <> <<0xC3>>)
    state = write_pipe(state, <<0xA9>> <> "llo\r")
    snapshot = inspect_pipe(state)
    assert snapshot["sequence"] == 0 and snapshot["model_calls"] == 0
    assert snapshot["input_worker_present"] and snapshot["input_worker_alive"]
    state = write_pipe(state, "\n/wait\r\n")
    state = await_record(state, &(&1["event"] == "wait" and &1["state"] == "settled"))
    state = half_close(state)
    {state, evidence, _} = finish_case(state, 0)
    assert [request] = evidence.requests
    assert Enum.any?(request["messages"], &(&1["content"] == "héllo"))
    assert Enum.map(inputs(state), & &1["input_sequence"]) == ["1", "2"]
    assert completed(evidence)["outcome"] == "completed"
  end

  for disposition <- [:answer, :decline] do
    test "pipe #{disposition} uses the emitted question ID across fragmented CRLF and JSON", f do
      state = start_case(f, Atom.to_string(unquote(disposition)))
      state = write_pipe(state, "question prompt\r\n/wait\n")
      state = await_record(state, &(&1["event"] == "wait" and &1["state"] == "question"))
      question = Enum.find(records(state.transcript), &(&1["event"] == "question"))
      barrier = Enum.find(records(state.transcript), &(&1["event"] == "wait"))
      assert question["interaction_id"] == barrier["interaction_id"]
      assert question["run_id"] == barrier["run_id"]
      assert question["producer"] == "model_tool"
      assert before_record?(state, "input", "question")
      text = " keep --choice héllo \n literal "

      line =
        if unquote(disposition) == :answer,
          do: "/answer " <> question["interaction_id"] <> " --text " <> JSON.encode!(text),
          else: "/decline " <> question["interaction_id"]

      split =
        if unquote(disposition) == :answer do
          {index, 2} = :binary.match(line, "é")
          index + 1
        else
          div(byte_size(line), 2)
        end

      state = write_pipe(state, binary_part(line, 0, split))
      state = write_pipe(state, binary_part(line, split, byte_size(line) - split) <> "\r")
      snapshot = inspect_pipe(state)
      assert snapshot["sequence"] == 2 and snapshot["model_calls"] == 1
      assert snapshot["input_worker_alive"]
      state = write_pipe(state, "\n/wait\n")
      state = await_record(state, &(&1["event"] == "wait" and &1["state"] == "settled"))
      state = half_close(state)
      {state, evidence, _} = finish_case(state, 0)
      assert [_asked, responded] = evidence.requests
      assert evidence.jobs == []

      kind =
        if unquote(disposition) == :answer,
          do: "interaction.answered",
          else: "interaction.declined"

      assert Enum.any?(
               evidence.events,
               &(&1["kind"] == kind and
                   LoopexProtocol.Wire.encode_identity(&1["interaction_id"]) ==
                     question["interaction_id"])
             )

      if unquote(disposition) == :answer do
        assert Enum.any?(responded["messages"], &(&1["role"] == "tool" and &1["content"] == text))
      else
        assert Enum.any?(
                 responded["messages"],
                 &(&1["role"] == "tool" and &1["content"] =~ "declined")
               )
      end

      assert Enum.map(inputs(state), & &1["input_sequence"]) == ~w(1 2 3 4)
      assert completed(evidence)["outcome"] == "completed"
    end
  end

  test "wait holds the next supplied line under actual kernel input pressure until held work releases",
       f do
    state = start_case(f, "pipe-held")
    state = write_pipe(state, "one\n/wait\n")
    assert control(state.socket) == :holding
    state = await_record(state, &(&1["event"] == "input" and &1["input_sequence"] == "2"))
    before_pressure = inspect_pipe(state)
    assert before_pressure["sequence"] == 2 and before_pressure["barrier"] == 2
    assert before_pressure["callback_alive"] and before_pressure["model_calls"] == 1
    assert is_binary(before_pressure["active_run_id"])
    refute before_pressure["input_worker_present"]
    pipe_command(state, %{"action" => "fill_input"})
    {state, pressure} = await_pipe_event(state, "input_pressure")
    assert pressure["blocked"] and pressure["written_bytes"] > 0
    after_pressure = inspect_pipe(state)
    assert after_pressure == before_pressure
    assert :ok = :gen_tcp.send(state.socket, :erlang.term_to_binary(:release))
    state = await_record(state, &(&1["event"] == "input" and &1["input_sequence"] == "3"))
    first_future = Enum.find(inputs(state), &(&1["input_sequence"] == "3"))
    assert first_future["disposition"] == "admitted"
    controls = records(state.transcript)

    wait_index =
      Enum.find_index(controls, &(&1["event"] == "wait" and &1["input_sequence"] == "2"))

    future_index = Enum.find_index(controls, &(&1 == first_future))
    assert is_integer(wait_index) and wait_index < future_index
    {state, evidence, messages} = finish_case(state, 1)
    assert {:model_down, :normal} in messages
    assert Enum.map(inputs(state), & &1["input_sequence"]) == ~w(1 2 3 4)
    assert List.last(inputs(state))["disposition"] == "refused"

    assert Enum.map(
             Enum.filter(evidence.events, &(&1["kind"] == "user.message_appended")),
             & &1["content"]
           ) == ["one", "next prompt"]
  end

  for {fragment, code} <- [
        {"", nil},
        {"incomplete", "unterminated_input_line"},
        {"incomplete\r", "invalid_input_line"}
      ] do
    test "stdin half-close with #{inspect(fragment)} joins active work without admitting its fragment",
         f do
      state = start_case(f, "pipe-eof")
      state = write_pipe(state, "one\n")
      assert control(state.socket) == :holding
      state = write_pipe(state, unquote(fragment))
      snapshot = inspect_pipe(state)
      assert snapshot["sequence"] == 1 and snapshot["model_calls"] == 1
      assert snapshot["callback_alive"] and snapshot["input_worker_alive"]
      assert :ok = :gen_tcp.send(state.socket, :erlang.term_to_binary(:inspect_reader))
      assert control(state.socket) == :reader_blocked
      state = half_close(state)
      {state, evidence, messages} = finish_case(state, 1)
      assert {:model_down, :killed} in messages
      assert {:reader_down, :normal} in messages
      assert length(evidence.requests) == 1 and evidence.jobs == []
      assert completed(evidence)["outcome"] == "cancelled"
      assert Enum.map(inputs(state), & &1["input_sequence"]) == ["1"]

      if unquote(code) do
        assert Enum.any?(
                 records(state.transcript),
                 &(&1["event"] == "error" and &1["code"] == unquote(code))
               )
      else
        refute Enum.any?(records(state.transcript), &(&1["event"] == "error"))
      end

      refute Enum.any?(evidence.events, &(&1["kind"] == "assistant.message_appended"))
    end
  end

  test "a kernel-stalled stdout writer cannot prevent independent cleanup and exact actor and OS joins",
       f do
    state = start_case(f, "pipe-stall")
    state = write_pipe(state, "large reply\n/wait\n")
    assert control(state.socket) == :holding
    state = await_record(state, &(&1["event"] == "input" and &1["input_sequence"] == "2"))
    snapshot = inspect_pipe(state)
    assert snapshot["sequence"] == 2 and snapshot["barrier"] == 2
    assert snapshot["callback_alive"] and snapshot["model_calls"] == 1
    refute snapshot["input_worker_present"]
    # Concept: admit the wait before the shared standard IO device can stall.
    # Technical depth: the real completed reply then queues its settled control,
    # whose existing enqueue deadline bounds cleanup independently of stdout.
    pipe_command(state, %{"action" => "pause_output"})
    {state, _} = await_pipe_event(state, "output_paused")
    assert :ok = :gen_tcp.send(state.socket, :erlang.term_to_binary(:release))
    pipe_command(state, %{"action" => "probe_output"})
    {state, blocked} = await_pipe_event(state, "output_blocked")
    assert blocked["kernel_writable"] == false and blocked["kernel_readable"] == true
    assert {:model_down, :normal} = control(state.socket)
    assert :ok = :gen_tcp.send(state.socket, :erlang.term_to_binary(:inspect_writer))
    assert {:writer_blocked, writer} = control(state.socket)
    assert writer["worker_waiting"] and writer["worker_alive"] and writer["result_pending"]
    assert writer["kind"] in ["text", "control"]
    assert writer["bytes"] > 0 and writer["bytes"] <= 262_144
    assert writer["retained_bytes"] <= 262_144
    state = half_close(state)
    cutoff = System.monotonic_time(:millisecond) + 15_000
    messages = collect_controls(state.socket, [], cutoff)
    assert {:writer_down, :killed} in messages
    assert {:evidence, evidence, 1} = Enum.find(messages, &match?({:evidence, _, _}, &1))
    assert evidence.runtime_joined and evidence.transport_joined
    assert evidence.provisional["cleanup"] == "confirmed"
    assert completed(evidence)["outcome"] == "completed"
    assert evidence.jobs == [] and length(evidence.requests) == 1
    # Concept: the independent control socket proves cleanup while stdout stays full.
    # Technical depth: release output only after every reported owned actor join;
    # drained stdout supplies no successful cleanup acknowledgement in this case.
    pipe_command(state, %{"action" => "resume_output"})
    {state, _} = await_pipe_event(state, "output_resumed")
    state = collect_pipe(state, 1)
    assert_os_down(state, 1)

    refute Enum.any?(
             records(state.transcript),
             &(&1["event"] == "closing" and &1["cleanup"] == "confirmed")
           )
  end

  defp start_case(f, scenario) do
    root =
      Path.join(f.root, scenario <> "-" <> Integer.to_string(System.unique_integer([:positive])))

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
        args: [Path.join(__DIR__, "support/chat_pty.py"), "--pipe", @launcher, "chat"],
        env: [
          {~c"LOOPEX_ESCRIPT", String.to_charlist(f.stand_in)},
          {~c"LOOPEX_HOME", String.to_charlist(Path.join(root, "home"))},
          {~c"LOOPEX_CHAT_PTY_PORT", Integer.to_charlist(control_port)},
          {~c"LOOPEX_CHAT_PTY_SCENARIO", String.to_charlist(scenario)},
          {~c"LOOPEX_CHAT_PTY_TRANSPORT", ~c"pipe"},
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
    assert {:ready, :pipe, 0, ^child} = control(socket)

    %{
      port: port,
      socket: socket,
      monitor: monitor,
      group: group,
      python_pid: python_pid,
      child: child,
      transcript: "",
      diagnostics: ""
    }
  end

  defp write_pipe(state, bytes) do
    pipe_command(state, %{"action" => "write", "bytes" => Base.encode64(bytes)})
    {state, event} = await_pipe_event(state, "written")
    assert event["bytes"] == byte_size(bytes)
    state
  end

  defp half_close(state) do
    pipe_command(state, %{"action" => "half_close"})
    {state, _} = await_pipe_event(state, "half_closed")
    state
  end

  defp pipe_command(state, command),
    do: true = Port.command(state.port, JSON.encode!(command) <> "\n")

  defp inspect_pipe(state) do
    assert :ok = :gen_tcp.send(state.socket, :erlang.term_to_binary(:inspect_pipe))
    assert {:pipe_state, snapshot} = control(state.socket)
    snapshot
  end

  defp await_pipe_event(state, kind) do
    event = port_event(state.port)

    case event do
      %{"event" => ^kind} ->
        {state, event}

      %{"event" => "output", "bytes" => bytes} ->
        await_pipe_event(%{state | transcript: state.transcript <> Base.decode64!(bytes)}, kind)

      %{"event" => "diagnostic", "bytes" => bytes} ->
        await_pipe_event(%{state | diagnostics: state.diagnostics <> Base.decode64!(bytes)}, kind)

      other ->
        flunk("unexpected pipe fixture event: #{inspect(other)}")
    end
  end

  defp await_record(state, predicate) do
    if Enum.any?(records(state.transcript), predicate) do
      state
    else
      case port_event(state.port) do
        %{"event" => "output", "bytes" => bytes} ->
          await_record(
            %{state | transcript: state.transcript <> Base.decode64!(bytes)},
            predicate
          )

        %{"event" => "diagnostic", "bytes" => bytes} ->
          await_record(
            %{state | diagnostics: state.diagnostics <> Base.decode64!(bytes)},
            predicate
          )

        event ->
          flunk("unexpected pipe fixture event: #{inspect(event)}")
      end
    end
  end

  defp inputs(state), do: Enum.filter(records(state.transcript), &(&1["event"] == "input"))
  defp completed(evidence), do: Enum.find(evidence.events, &(&1["kind"] == "run.finished"))

  defp before_record?(state, before_kind, after_kind) do
    controls = records(state.transcript)

    Enum.find_index(controls, &(&1["event"] == before_kind)) <
      Enum.find_index(controls, &(&1["event"] == after_kind))
  end

  defp finish_case(state, expected_code) do
    messages = collect_controls(state.socket, [], System.monotonic_time(:millisecond) + 15_000)

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

    state = collect_pipe(state, expected_code)
    assert_os_down(state, expected_code)
    closing = List.last(records(state.transcript))
    assert closing["event"] == "closing" and closing["cleanup"] == "confirmed"
    assert closing["exit_code"] == expected_code

    {state, evidence, messages}
  end

  defp assert_os_down(state, expected_code) do
    assert_receive {port, {:exit_status, ^expected_code}} when port == state.port, 10_000

    assert_receive {:DOWN, reference, :port, port, :normal}
                   when reference == state.monitor and port == state.port,
                   5_000

    for pid <- [state.python_pid, state.group, String.to_integer(state.child)] do
      assert {_, status} =
               System.cmd("/bin/kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true)

      assert status != 0
    end

    :ok
  end

  defp collect_controls(socket, messages, cutoff) do
    case control(socket, cutoff) do
      :helpers_joined -> Enum.reverse(messages)
      message -> collect_controls(socket, [message | messages], cutoff)
    end
  rescue
    failure in ExUnit.AssertionError ->
      observations = Enum.reject(messages, &match?({:evidence, _, _}, &1))

      reraise ExUnit.AssertionError,
              [
                message:
                  failure.message <>
                    "\nretained control observations: " <> inspect(Enum.reverse(observations))
              ],
              __STACKTRACE__
  end

  defp collect_pipe(state, expected_code) do
    case port_event(state.port) do
      %{"event" => "output", "bytes" => bytes} ->
        collect_pipe(
          %{state | transcript: state.transcript <> Base.decode64!(bytes)},
          expected_code
        )

      %{"event" => "diagnostic", "bytes" => bytes} ->
        collect_pipe(
          %{state | diagnostics: state.diagnostics <> Base.decode64!(bytes)},
          expected_code
        )

      %{"event" => "exited", "status" => ^expected_code, "group_gone" => true} ->
        state

      event ->
        flunk("unexpected pipe event: #{inspect(event)}")
    end
  end

  defp records(transcript) do
    for [_, json] <- Regex.scan(~r/@loopex ([^\r\n]+)/, transcript), do: JSON.decode!(json)
  end

  defp control(socket, cutoff \\ System.monotonic_time(:millisecond) + 15_000) do
    case :gen_tcp.recv(socket, 0, max(cutoff - System.monotonic_time(:millisecond), 0)) do
      {:ok, bytes} ->
        :erlang.binary_to_term(bytes, [:safe])

      error ->
        flunk(
          "pipe control failed #{inspect(error)}: #{failed_terminal(Process.get(:pty_port), "")}"
        )
    end
  end

  defp failed_terminal(port, transcript) do
    receive do
      {^port, {:data, {:eol, json}}} ->
        case JSON.decode!(json) do
          %{"event" => "output", "bytes" => bytes} ->
            failed_terminal(port, transcript <> Base.decode64!(bytes))

          %{"event" => "diagnostic", "bytes" => bytes} ->
            failed_terminal(port, transcript <> "\nchild diagnostic: " <> Base.decode64!(bytes))

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
      {^port, {:exit_status, status}} -> flunk("pipe exited early: #{status}")
    after
      15_000 -> flunk("pipe driver did not report an event")
    end
  end

  defp shell_quote(text), do: "'" <> String.replace(text, "'", "'\\''") <> "'"

  defp await_group_down(group, cutoff) do
    case System.cmd("/bin/kill", ["-0", "--", "-#{group}"], stderr_to_stdout: true) do
      {_, 0} ->
        if System.monotonic_time(:millisecond) >= cutoff,
          do: flunk("pipe process group survived cleanup")

        receive do
        after
          10 -> await_group_down(group, cutoff)
        end

      {_, _} ->
        :ok
    end
  end
end
