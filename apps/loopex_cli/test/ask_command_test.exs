defmodule LoopexCli.AskCommandTest do
  @moduledoc """
  ## Concept

  Proves that the built command admits both standalone spellings in a separate
  process and exits with their fixed diagnostic and result bytes.

  ## Technical depth

  The invalid-input case builds a fresh escript from this run's compiled beams.
  The tool case calls main/1 in a child VM with a test-only local model
  endpoint seam, since the public command has no endpoint flag. A direct
  Ask.run/2 call is the positive notice control. Public-result seams drive
  failed, bounded and no-ending outcomes through main/1 in separate VMs to
  witness serialization, stderr and exit status, not runtime cleanup. Shell
  capture keeps stdout and stderr apart.
  """

  use ExUnit.Case, async: false

  @moduletag timeout: 120_000

  test "built command refuses invalid input and preserves standard IO bytes" do
    root = temporary_directory()
    on_exit(fn -> File.rm_rf!(root) end)
    command = build_command(root)
    state_root = Path.join(root, "unused-state-root")

    for spelling <- ["ask", "-p"] do
      {status, stdout, stderr} =
        capture(command, [spelling, "--output", "wrong", "fixture"], root, state_root)

      assert status == 1
      assert stdout == ""
      assert stderr == "loopex: invalid_output\n"
      refute File.exists?(state_root)

      {status, stdout, stderr} =
        capture(command, [spelling, "--output", "json", "--unknown", "fixture"], root, state_root)

      assert status == 1
      assert stdout == ""
      assert stderr == "loopex: invalid_arguments\n"
      refute File.exists?(state_root)
    end

    {status, stdout, stderr} = capture(command, [], root, state_root)
    assert status == 1
    assert stdout == ""
    assert String.starts_with?(stderr, "loopex: choose one command:")
    refute File.exists?(state_root)
    assert_boot_io(command, root)
  end

  test "main keeps JSON ask quiet and text ask announces a real tool decision" do
    elixir = System.find_executable("elixir") || flunk("Elixir is unavailable")

    code_paths =
      Enum.flat_map(:code.get_path(), fn path -> ["-pa", List.to_string(path)] end)

    for {mode, policy, command, output} <- [
          {"one-shot", "allow-all", "ask", "json"},
          {"one-shot", "shell-allowlist", "ask", "json"},
          {"one-shot", "allow-all", "-p", "json"},
          {"one-shot-text", "allow-all", "ask", "text"},
          {"direct", "allow-all", "ask", "json"}
        ] do
      root = temporary_directory()
      on_exit(fn -> File.rm_rf!(root) end)
      File.write!(Path.join(root, "note.txt"), "a tool really read this file\n")
      {port, server} = start_tool_server()
      server_monitor = Process.monitor(server)
      state_root = Path.join(root, "unused-state-root")
      started_ms = System.monotonic_time(:millisecond)

      {status, stdout, stderr} =
        capture(
          elixir,
          code_paths ++
            [
              "-e",
              tool_ask_source(),
              "--",
              command,
              "read note.txt",
              "--policy",
              policy,
              "--model",
              "ollama:llama3.2",
              "--tools",
              "read-only",
              "--cwd",
              root,
              "--max-steps",
              "3",
              "--deadline-ms",
              "20000",
              "--output",
              output
            ],
          root,
          state_root,
          [
            {"LOOPEX_TEST_PORT", Integer.to_string(port)},
            {"LOOPEX_TEST_ASK_MODE", mode},
            {"LOOPEX_TEST_POLICY", policy}
          ]
        )

      elapsed_ms = System.monotonic_time(:millisecond) - started_ms
      stdout_excerpt = binary_part(stdout, 0, min(byte_size(stdout), 4_096))
      stderr_excerpt = binary_part(stderr, 0, min(byte_size(stderr), 4_096))
      trace_path = Path.join(root, "ask-trace")
      trace = if File.regular?(trace_path), do: File.read!(trace_path), else: ""

      assert status == 0,
             "ask case #{inspect({mode, policy, command, output})} exited #{status} " <>
               "after #{elapsed_ms} ms; stdout=#{inspect(stdout_excerpt)} " <>
               "stderr=#{inspect(stderr_excerpt)} trace=#{inspect(trace)}"

      if output == "text" do
        assert stdout == "read complete\n"

        assert stderr ==
                 LoopexCli.Policy.AllowAll.notice() <>
                   "\ntool completed \"loopex.read\"\nending completed\n"
      else
        if mode == "one-shot" do
          assert stderr == ""
        else
          assert stderr == LoopexCli.Policy.AllowAll.notice() <> "\n"
        end

        assert [encoded, ""] = String.split(stdout, "\n")

        assert %{
                 "schema" => "loopex.ask/1",
                 "outcome" => "completed",
                 "text" => "read complete",
                 "tools" => [%{"tool_id" => "loopex.read", "outcome" => "completed"}]
               } = JSON.decode!(encoded)
      end

      assert_receive {:model_request, first}, 15_000
      assert first =~ "POST /v1/chat/completions HTTP/1.1"
      assert_receive {:model_request, second}, 15_000
      assert second =~ "a tool really read this file"
      assert_receive {:DOWN, ^server_monitor, :process, ^server, :normal}, 1_000
      refute File.exists?(state_root)
    end
  end

  test "main emits one JSON object and the outcome status from a separate VM" do
    elixir = System.find_executable("elixir") || flunk("Elixir is unavailable")
    code_paths = Enum.flat_map(:code.get_path(), fn path -> ["-pa", List.to_string(path)] end)

    for {case_name, status, outcome, details, stderr} <- [
          {"failed", 2, "failed",
           %{"reason" => "model_call_failed", "failure" => nil, "cleanup_grace_ms" => "5000"},
           ""},
          {"bounded", 3, "bound_reached",
           %{
             "bound" => "max_turns",
             "observed" => "1",
             "declared_limit" => "1",
             "accounting_source" => nil,
             "cleanup_grace_ms" => "5000"
           }, ""},
          {"timeout", 6, "no_ending", %{"reason" => "timeout", "waited_ms" => "25"}, ""},
          {"session-loss", 6, "no_ending",
           %{"reason" => "session_unavailable", "waited_ms" => "25"},
           "loopex: cleanup_unproved root=\"/tmp/ask-retained\" ownership=owned pending=run_ending,root_removal\n" <>
             "loopex: Session cleanup is unconfirmed. Before running ask again, make sure the previous ask process has exited and inspect the root named above; do not remove an unverified path.\n"}
        ] do
      root = temporary_directory()
      on_exit(fn -> File.rm_rf!(root) end)
      state_root = Path.join(root, "unused-state-root")

      {actual_status, stdout, actual_stderr} =
        capture(
          elixir,
          code_paths ++
            [
              "-e",
              outcome_ask_source(),
              "--",
              "ask",
              "question",
              "--policy",
              "allow-all",
              "--output",
              "json"
            ],
          root,
          state_root,
          [{"LOOPEX_TEST_ASK_CASE", case_name}]
        )

      assert actual_status == status
      assert actual_stderr == stderr
      assert [encoded, ""] = String.split(stdout, "\n")
      object = JSON.decode!(encoded)

      assert Enum.sort(Map.keys(object)) ==
               Enum.sort(~w(schema session_id run_id profile outcome text text_truncated tools
                            tools_truncated shadowed_skills cleanup details))

      assert object["schema"] == "loopex.ask/1"
      assert object["profile"] == "ephemeral"
      assert object["outcome"] == outcome
      assert object["details"] == details
      assert object["text"] == "partial answer"
      assert object["tools"] == [%{"tool_id" => nil, "outcome" => "denied"}]
      assert object["run_id"] == if(outcome == "no_ending", do: nil, else: "run-1")

      assert object["cleanup"] ==
               if(case_name == "session-loss",
                 do: %{
                   "proved" => false,
                   "root" => "/tmp/ask-retained",
                   "root_ownership" => "owned",
                   "pending" => ["run_ending", "root_removal"]
                 },
                 else: %{"proved" => true}
               )

      refute File.exists?(state_root)
    end
  end

  test "main reads and writes exact UTF-8 bytes through real standard IO" do
    elixir = System.find_executable("elixir") || flunk("Elixir is unavailable")
    code_paths = Enum.flat_map(:code.get_path(), fn path -> ["-pa", List.to_string(path)] end)
    root = temporary_directory()
    on_exit(fn -> File.rm_rf!(root) end)
    state_root = Path.join(root, "unused-state-root")

    {status, stdout, stderr} =
      capture(
        elixir,
        ["--erl", "-kernel standard_io_encoding latin1"] ++
          code_paths ++
          [
            "-e",
            outcome_ask_source(),
            "--",
            "ask",
            "--policy",
            "refuse-all",
            "--output",
            "text"
          ],
        root,
        state_root,
        [{"LOOPEX_TEST_ASK_CASE", "unicode"}],
        "é"
      )

    assert status == 0, "stderr=#{inspect(stderr)}"
    assert stdout == "réponse π\n"
    assert stderr == "tool denied null\nending completed\n"
    refute File.exists?(state_root)
  end

  defp assert_boot_io(command, root) do
    state_root = Path.join(root, "durable-state")
    {:ok, sections} = :escript.extract(String.to_charlist(command), [])

    assert List.to_string(Keyword.fetch!(sections, :emu_args)) =~
             "-kernel standard_io_encoding latin1"

    # A valid prompt reaches credential admission without making a provider
    # call. OTP 27 eagerly reads stdin before main/1 can change its encoding.
    {status, stdout, stderr} =
      capture(
        command,
        ["ask", "--policy", "refuse-all", "--state-root", state_root, "--output", "json"],
        root,
        state_root,
        [],
        "é π"
      )

    assert status == 1
    assert stdout == ""
    assert stderr == "loopex: provider_credential_required\n"

    {status, stdout, stderr} =
      capture(command, ["ask", "--policy", "refuse-all"], root, state_root, [], <<255>>)

    assert status == 1
    assert stdout == ""
    assert stderr == "loopex: invalid_prompt_invalid_utf8\n"

    {status, stdout, stderr} = capture(command, ["éπ"], root, state_root)
    assert status == 1
    assert stdout == ""
    assert String.starts_with?(stderr, "loopex: unknown command éπ\n")
    assert String.valid?(stderr)
  end

  defp temporary_directory do
    root =
      Path.join(System.tmp_dir!(), "loopex-ask-command-#{System.unique_integer([:positive])}")

    File.mkdir!(root)
    root
  end

  defp build_command(root) do
    {:ok, _} = Application.ensure_all_started(:mix)
    command = Path.join(root, "loopex")

    build = fn ->
      assert Path.expand(Mix.Project.compile_path()) ==
               Path.expand(Application.app_dir(:loopex_cli, "ebin"))

      original = Mix.Project.config()[:escript]
      Mix.ProjectStack.merge_config(escript: Keyword.put(original, :path, command))

      try do
        Mix.Tasks.Escript.Build.run(["--no-compile", "--no-deps-check"])
      after
        Mix.ProjectStack.merge_config(escript: original)
      end
    end

    if Mix.Project.get() == LoopexCli.MixProject do
      build.()
    else
      Mix.Project.in_project(:loopex_cli, Path.expand("..", __DIR__), fn _ -> build.() end)
    end

    assert File.regular?(command)
    assert Bitwise.band(File.stat!(command).mode, 0o111) != 0
    {:ok, sections} = :escript.extract(String.to_charlist(command), [])
    {:ok, entries} = :zip.extract(Keyword.fetch!(sections, :archive), [:memory])

    for module <- [LoopexCli, LoopexCli.Ask] do
      name = Atom.to_string(module) <> ".beam"

      embedded =
        Enum.find_value(entries, fn {path, bytes} ->
          if Path.basename(List.to_string(path)) == name, do: bytes
        end)

      assert {:ok, {^module, embedded_hash}} = :beam_lib.md5(embedded)
      assert {:ok, {^module, current_hash}} = :beam_lib.md5(:code.which(module))
      assert embedded_hash == current_hash
    end

    command
  end

  defp capture(command, argv, root, state_root, extra_env \\ [], stdin_bytes \\ nil) do
    number = System.unique_integer([:positive])
    stdout_path = Path.join(root, "stdout-#{number}")
    stderr_path = Path.join(root, "stderr-#{number}")
    stdin_path = Path.join(root, "stdin-#{number}")

    if is_binary(stdin_bytes), do: File.write!(stdin_path, stdin_bytes)

    script =
      "command=$1; stdout=$2; stderr=$3; stdin=$4; shift 4; " <>
        "if [ -n \"$stdin\" ]; then exec \"$command\" \"$@\" <\"$stdin\" >\"$stdout\" 2>\"$stderr\"; " <>
        "else exec \"$command\" \"$@\" >\"$stdout\" 2>\"$stderr\"; fi"

    {shell_output, status} =
      System.cmd(
        "/bin/sh",
        [
          "-c",
          script,
          "capture",
          command,
          stdout_path,
          stderr_path,
          if(is_binary(stdin_bytes), do: stdin_path, else: "")
        ] ++ argv,
        cd: root,
        env:
          [
            {"LOOPEX_HOME", state_root},
            {"LOOPEX_PROVIDER_API_KEY", nil},
            {"OPENAI_API_KEY", nil},
            {"ANTHROPIC_API_KEY", nil},
            {"OPENROUTER_API_KEY", nil},
            {"OPEN_ROUTER_API_KEY", nil},
            {"ERL_LIBS", nil},
            {"ERL_AFLAGS", nil},
            {"ERL_ZFLAGS", nil},
            {"LOOPEX_TEST_TRACE", Path.join(root, "ask-trace")}
          ] ++ extra_env
      )

    assert shell_output == ""
    {status, File.read!(stdout_path), File.read!(stderr_path)}
  end

  defp tool_ask_source do
    ~S"""
    port = System.fetch_env!("LOOPEX_TEST_PORT")
    mode = System.fetch_env!("LOOPEX_TEST_ASK_MODE")
    policy = System.fetch_env!("LOOPEX_TEST_POLICY")
    trace = System.fetch_env!("LOOPEX_TEST_TRACE")
    manager = spawn(fn -> receive do :release -> :ok end end)
    seams = [
      install_interrupt: fn _, _ -> {:ok, manager} end,
      signal_manager: fn -> manager end,
      handler_live: fn _, _ -> true end,
      interrupt_phase: fn _, _ -> :idle end,
      finish_interrupt: fn _, _ -> {:ok, :ordinary} end,
      start_session: fn options ->
        result = LoopexComposition.Ephemeral.start_session(
          Keyword.merge(options,
            base_url: "http://127.0.0.1:" <> port <> "/v1",
            max_tokens: 128,
            timeout: 15_000
          )
        )
        case result do
          {:error, reason} -> File.write!(trace, "start_session_error=#{inspect(reason, limit: 10)}\n")
          {:ok, _session} -> :ok
        end
        result
      end
    ]
    if mode in ["one-shot", "one-shot-text"] do
      :ok = Application.stop(:logger)
      :ok = Application.put_env(:logger, :level, :debug)
      Process.put({LoopexCli.Ask, :test_seams}, seams)
      LoopexCli.main(System.argv())
    else
      %{status: status, stdout: stdout, stderr: stderr} =
        LoopexCli.Ask.run(System.argv(), seams)

      notice_key = case policy do
        "allow-all" -> {LoopexCli.Policy.AllowAll, :announced}
        "shell-allowlist" -> {LoopexCli.Policy.ShellAllowlist, :notice}
      end
      announced = :persistent_term.get(notice_key, :not_announced)
      if announced == :not_announced,
        do: IO.puts(:stderr, "policy notice was not marked as announced")
      if stdout != "", do: IO.binwrite(:stdio, stdout)
      if stderr != "", do: IO.binwrite(:stderr, stderr)
      System.halt(status)
    end
    """
  end

  defp outcome_ask_source do
    ~S"""
    mode = System.fetch_env!("LOOPEX_TEST_ASK_CASE")
    manager = spawn(fn -> receive do :release -> :ok end end)
    observation = %{
      profile: :ephemeral, outcome: :completed, session_id: "session-1", run_id: "run-1",
      text: if(mode == "unicode", do: "réponse π", else: "partial answer"), text_truncated: false,
      tools: [%{tool_id: nil, outcome: "denied", private: "not public"}],
      tools_truncated: false, shadowed_skills: [], details: %{}, private: "not public"
    }
    snapshot = observation |> Map.drop([:outcome, :details]) |> Map.put(:run_id, nil)
      |> Map.put(:waited_ms, 25)
    ending = case mode do
      "failed" ->
        failed = %{observation | outcome: :failed,
          details: %{"reason" => "model_call_failed", "failure" => nil,
            "cleanup_grace_ms" => 5_000}}
        {:error, {:run, :failed, failed}}
      "bounded" ->
        bounded = %{observation | outcome: :bound_reached,
          details: %{"bound" => "max_turns", "observed" => 1, "declared_limit" => 1,
            "accounting_source" => nil, "cleanup_grace_ms" => 5_000}}
        {:error, {:run, :bound_reached, bounded}}
      "timeout" -> {:error, {:timeout, snapshot}}
      "session-loss" -> {:ok, %{observation | details: %{"cleanup_grace_ms" => 5_000}}}
      "unicode" -> {:ok, %{observation | details: %{"cleanup_grace_ms" => 5_000}}}
    end
    stop = case mode do
      "session-loss" ->
        cleanup = %{root: "/tmp/ask-retained", root_ownership: :owned,
          pending: [:run_ending, :root_removal],
          ending: {:error, {:session_unavailable, snapshot}}}
        {:error, {:cleanup_unproved, cleanup}}
      _ -> :ok
    end
    seams = [
      install_interrupt: fn _, _ -> {:ok, manager} end,
      signal_manager: fn -> manager end,
      handler_live: fn _, _ -> true end,
      interrupt_phase: fn _, _ -> :idle end,
      finish_interrupt: fn _, _ -> {:ok, :ordinary} end,
      start_session: fn _ -> {:ok, :session} end,
      ask: fn _, prompt ->
        if mode == "unicode" and prompt != "é", do: raise("stdin bytes changed")
        ending
      end,
      stop_session: fn _ -> stop end
    ]
    Process.put({LoopexCli.Ask, :test_seams}, seams)
    LoopexCli.main(System.argv())
    """
  end

  defp start_tool_server do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, {_, port}} = :inet.sockname(listener)
    parent = self()

    server =
      spawn(fn ->
        for body <- [tool_reply(), answer_reply()] do
          {:ok, socket} = :gen_tcp.accept(listener, 30_000)
          {:ok, request} = read_request(socket, "")
          send(parent, {:model_request, request})

          :ok =
            :gen_tcp.send(socket, [
              "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: ",
              Integer.to_string(byte_size(body)),
              "\r\nconnection: close\r\n\r\n",
              body
            ])

          :gen_tcp.close(socket)
        end
      end)

    on_exit(fn ->
      if Process.alive?(server), do: Process.exit(server, :kill)
      :gen_tcp.close(listener)
    end)

    {port, server}
  end

  defp tool_reply do
    JSON.encode!(%{
      id: "chatcmpl-tool",
      object: "chat.completion",
      created: 1_800_000_000,
      model: "llama3.2",
      choices: [
        %{
          index: 0,
          message: %{
            role: "assistant",
            content: nil,
            tool_calls: [
              %{
                id: "call-read",
                type: "function",
                function: %{name: "read", arguments: JSON.encode!(%{path: "note.txt"})}
              }
            ]
          },
          finish_reason: "tool_calls"
        }
      ],
      usage: %{prompt_tokens: 12, completion_tokens: 3, total_tokens: 15}
    })
  end

  defp answer_reply do
    JSON.encode!(%{
      id: "chatcmpl-answer",
      object: "chat.completion",
      created: 1_800_000_001,
      model: "llama3.2",
      choices: [
        %{
          index: 0,
          message: %{role: "assistant", content: "read complete"},
          finish_reason: "stop"
        }
      ],
      usage: %{prompt_tokens: 24, completion_tokens: 3, total_tokens: 27}
    })
  end

  defp read_request(socket, buffered) do
    case :binary.match(buffered, "\r\n\r\n") do
      {header_end, 4} ->
        header_size = header_end + 4
        <<headers::binary-size(^header_size), body::binary>> = buffered

        size =
          case Regex.run(~r/content-length:\s*(\d+)/i, headers) do
            [_, digits] -> String.to_integer(digits)
            _ -> 0
          end

        if byte_size(body) >= size,
          do: {:ok, buffered},
          else: read_more(socket, buffered)

      :nomatch ->
        read_more(socket, buffered)
    end
  end

  defp read_more(socket, buffered) do
    with {:ok, chunk} <- :gen_tcp.recv(socket, 0, 15_000),
         true <- byte_size(buffered) + byte_size(chunk) <= 1_048_576 do
      read_request(socket, buffered <> chunk)
    else
      other -> other
    end
  end
end
