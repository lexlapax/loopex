defmodule LoopexCli.AskDelegationTest do
  @moduledoc """
  ## Concept

  A separate program can run `loopex -p`, consume its one JSON result and use
  the exit status to distinguish completed, failed, bounded and no-ending runs.

  ## Technical depth

  The delegated child executes the production ask command in its own VM. A
  test-only address seam points its completed Ollama call at a local TCP
  responder, since the public command deliberately has no endpoint flag.
  Public-result seams drive the other outcomes to witness JSON serialization,
  stderr and exit statuses across processes. Those injected cases do not prove
  runtime cleanup.
  """

  use ExUnit.Case, async: false

  @moduletag timeout: 120_000
  @launcher Path.expand("../bin/loopex", __DIR__)

  test "another OS process delegates to loopex -p and parses its JSON answer" do
    root = temporary_directory()
    on_exit(fn -> File.rm_rf!(root) end)
    {port, server} = start_server("delegated answer")
    server_monitor = Process.monitor(server)
    stand_in = build_stand_in(root)

    python = System.find_executable("python3") || flunk("Python 3 is unavailable")

    {summary, delegate_status} =
      System.cmd(
        python,
        ["-c", delegator_source(), @launcher],
        cd: root,
        env: [
          {"LOOPEX_ESCRIPT", stand_in},
          {"LOOPEX_TEST_PORT", Integer.to_string(port)},
          {"LOOPEX_HOME", nil},
          {"LOOPEX_PROVIDER_API_KEY", nil},
          {"OPENAI_API_KEY", nil},
          {"ANTHROPIC_API_KEY", nil},
          {"OPENROUTER_API_KEY", nil},
          {"OPEN_ROUTER_API_KEY", nil},
          {"ERL_AFLAGS", nil},
          {"ERL_ZFLAGS", nil}
        ],
        stderr_to_stdout: true
      )

    assert delegate_status == 0, summary
    assert_receive {:model_request, request}, 15_000
    assert request =~ "POST /v1/chat/completions HTTP/1.1"
    assert request =~ "delegated question"
    assert_receive {:DOWN, ^server_monitor, :process, ^server, :normal}, 1_000

    assert JSON.decode!(String.trim_trailing(summary, "\n")) == %{
             "status" => 0,
             "stderr" => "",
             "schema" => "loopex.ask/1",
             "profile" => "ephemeral",
             "outcome" => "completed",
             "text" => "delegated answer",
             "cleanup" => %{"proved" => true}
           }

    assert String.ends_with?(summary, "\n")
    assert length(String.split(summary, "\n")) == 2
  end

  test "a delegating process serializes injected bounded, failed and no-ending results" do
    root = temporary_directory()
    on_exit(fn -> File.rm_rf!(root) end)
    stand_in = build_stand_in(root)
    python = System.find_executable("python3") || flunk("Python 3 is unavailable")

    {summary, delegate_status} =
      System.cmd(
        python,
        ["-c", outcome_delegator_source(), @launcher],
        cd: root,
        env: [
          {"LOOPEX_ESCRIPT", stand_in},
          {"LOOPEX_HOME", nil},
          {"LOOPEX_PROVIDER_API_KEY", nil},
          {"OPENAI_API_KEY", nil},
          {"ANTHROPIC_API_KEY", nil},
          {"OPENROUTER_API_KEY", nil},
          {"OPEN_ROUTER_API_KEY", nil},
          {"ERL_AFLAGS", nil},
          {"ERL_ZFLAGS", nil}
        ],
        stderr_to_stdout: true
      )

    assert delegate_status == 0, summary
    assert [encoded, ""] = String.split(summary, "\n")

    assert JSON.decode!(encoded) == [
             %{
               "case" => "failed",
               "status" => 2,
               "stderr" => "",
               "outcome" => "failed",
               "details" => %{
                 "reason" => "model_call_failed",
                 "failure" => nil,
                 "cleanup_grace_ms" => "5000"
               },
               "cleanup" => %{"proved" => true}
             },
             %{
               "case" => "bounded",
               "status" => 3,
               "stderr" => "",
               "outcome" => "bound_reached",
               "details" => %{
                 "bound" => "max_turns",
                 "observed" => "1",
                 "declared_limit" => "1",
                 "accounting_source" => nil,
                 "cleanup_grace_ms" => "5000"
               },
               "cleanup" => %{"proved" => true}
             },
             %{
               "case" => "timeout",
               "status" => 6,
               "stderr" => "",
               "outcome" => "no_ending",
               "details" => %{"reason" => "timeout", "waited_ms" => "25"},
               "cleanup" => %{"proved" => true}
             },
             %{
               "case" => "session-loss",
               "status" => 6,
               "stderr" =>
                 "loopex: cleanup_unproved root=\"/tmp/ask-delegated-retained\" ownership=owned pending=run_ending,root_removal\n" <>
                   "loopex: Session cleanup is unconfirmed. Before running ask again, make sure the previous ask process has exited and inspect the root named above; do not remove an unverified path.\n",
               "outcome" => "no_ending",
               "details" => %{"reason" => "session_unavailable", "waited_ms" => "25"},
               "cleanup" => %{
                 "proved" => false,
                 "root" => "/tmp/ask-delegated-retained",
                 "root_ownership" => "owned",
                 "pending" => ["run_ending", "root_removal"]
               }
             }
           ]
  end

  defp build_stand_in(root) do
    stand_in = Path.join(root, "loopex-child")
    File.write!(stand_in, stand_in_source())
    File.chmod!(stand_in, 0o755)
    stand_in
  end

  defp stand_in_source do
    elixir = System.find_executable("elixir") || flunk("Elixir is unavailable")

    paths =
      Enum.map_join(:code.get_path(), " ", fn path ->
        "-pa " <> shell_quote(List.to_string(path))
      end)

    program = """
    mode = System.get_env("LOOPEX_TEST_DELEGATE_CASE", "completed")
    manager = spawn(fn -> receive do :release -> :ok end end)
    base = [
      install_interrupt: fn _, _ -> {:ok, manager} end,
      signal_manager: fn -> manager end,
      handler_live: fn _, _ -> true end,
      interrupt_phase: fn _, _ -> :idle end,
      finish_interrupt: fn _, _ -> {:ok, :ordinary} end
    ]
    seams = if mode == "completed" do
      port = System.fetch_env!("LOOPEX_TEST_PORT")
      Keyword.put(base, :start_session, fn options ->
        LoopexComposition.Ephemeral.start_session(
          Keyword.merge(options,
            base_url: "http://127.0.0.1:" <> port <> "/v1",
            max_tokens: 128, timeout: 15_000
          )
        )
      end)
    else
      observation = %{
        profile: :ephemeral, outcome: :completed, session_id: "session-1",
        run_id: "run-1", text: "partial answer", text_truncated: false,
        tools: [], tools_truncated: false, shadowed_skills: [], details: %{}
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
      end
      stop = case mode do
        "session-loss" ->
          cleanup = %{root: "/tmp/ask-delegated-retained", root_ownership: :owned,
            pending: [:run_ending, :root_removal],
            ending: {:error, {:session_unavailable, snapshot}}}
          {:error, {:cleanup_unproved, cleanup}}
        _ -> :ok
      end
      Keyword.merge(base,
        start_session: fn _ -> {:ok, :session} end,
        ask: fn _, _ -> ending end,
        stop_session: fn _ -> stop end
      )
    end
    Process.put({LoopexCli.Ask, :test_seams}, seams)
    LoopexCli.main(System.argv())
    """

    "#!/bin/sh\nexec #{shell_quote(elixir)} #{paths} -e #{shell_quote(program)} -- \"$@\"\n"
  end

  defp delegator_source do
    """
    import json
    import os
    import subprocess
    import sys

    child_env = os.environ.copy()
    child_env.pop('LOOPEX_TEST_DELEGATE_CASE', None)
    completed = subprocess.run(
        [sys.argv[1], '-p', 'delegated question', '--policy', 'allow-all',
         '--model', 'ollama:llama3.2', '--tools', 'none', '--output', 'json'],
        capture_output=True, text=True, timeout=30, check=False,
        env=child_env)
    assert completed.stdout.endswith('\\n'), repr((completed.returncode, completed.stdout, completed.stderr))
    assert completed.stdout.count('\\n') == 1, repr((completed.returncode, completed.stdout, completed.stderr))
    result = json.loads(completed.stdout)
    print(json.dumps({
        'status': completed.returncode,
        'stderr': completed.stderr,
        'schema': result['schema'],
        'profile': result['profile'],
        'outcome': result['outcome'],
        'text': result['text'],
        'cleanup': result['cleanup'],
    }, separators=(',', ':')))
    """
  end

  defp outcome_delegator_source do
    """
    import json
    import os
    import subprocess
    import sys

    reports = []
    keys = {'schema', 'session_id', 'run_id', 'profile', 'outcome', 'text',
            'text_truncated', 'tools', 'tools_truncated', 'shadowed_skills',
            'cleanup', 'details'}
    for case in ('failed', 'bounded', 'timeout', 'session-loss'):
        child_env = os.environ.copy()
        child_env['LOOPEX_TEST_DELEGATE_CASE'] = case
        completed = subprocess.run(
            [sys.argv[1], '-p', 'delegated question', '--policy', 'allow-all',
             '--model', 'ollama:llama3.2', '--tools', 'none', '--output', 'json'],
            capture_output=True, text=True, timeout=30, check=False,
            env=child_env)
        assert completed.stdout.endswith('\\n'), repr((case, completed.returncode, completed.stdout, completed.stderr))
        assert completed.stdout.count('\\n') == 1, repr((case, completed.returncode, completed.stdout, completed.stderr))
        result = json.loads(completed.stdout)
        assert isinstance(result, dict) and set(result) == keys, repr(result)
        assert result['schema'] == 'loopex.ask/1' and result['profile'] == 'ephemeral', repr(result)
        assert result['text'] == 'partial answer' and result['tools'] == [], repr(result)
        assert result['run_id'] == (None if case in ('timeout', 'session-loss') else 'run-1'), repr(result)
        reports.append({
            'case': case, 'status': completed.returncode, 'stderr': completed.stderr,
            'outcome': result['outcome'], 'details': result['details'],
            'cleanup': result['cleanup']})
    print(json.dumps(reports, separators=(',', ':')))
    """
  end

  defp shell_quote(value), do: "'" <> String.replace(value, "'", "'\\''") <> "'"

  defp temporary_directory do
    path =
      Path.join(System.tmp_dir!(), "loopex-ask-delegate-#{System.unique_integer([:positive])}")

    File.mkdir!(path)
    path
  end

  defp start_server(answer) do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, {_, port}} = :inet.sockname(listener)
    parent = self()

    server =
      spawn(fn ->
        {:ok, socket} = :gen_tcp.accept(listener, 30_000)
        {:ok, request} = read_request(socket, "")
        send(parent, {:model_request, request})

        body =
          JSON.encode!(%{
            id: "chatcmpl-delegated",
            object: "chat.completion",
            created: 1_800_000_000,
            model: "llama3.2",
            choices: [
              %{index: 0, message: %{role: "assistant", content: answer}, finish_reason: "stop"}
            ],
            usage: %{prompt_tokens: 12, completion_tokens: 3, total_tokens: 15}
          })

        :ok =
          :gen_tcp.send(socket, [
            "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: ",
            Integer.to_string(byte_size(body)),
            "\r\nconnection: close\r\n\r\n",
            body
          ])

        :gen_tcp.close(socket)
      end)

    on_exit(fn ->
      if Process.alive?(server), do: Process.exit(server, :kill)
      :gen_tcp.close(listener)
    end)

    {port, server}
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

        if byte_size(body) >= size do
          {:ok, buffered}
        else
          read_more(socket, buffered)
        end

      :nomatch ->
        read_more(socket, buffered)
    end
  end

  defp read_more(socket, buffered) do
    with {:ok, chunk} <- :gen_tcp.recv(socket, 0, 30_000),
         true <- byte_size(buffered) + byte_size(chunk) <= 1_048_576 do
      read_request(socket, buffered <> chunk)
    else
      other -> other
    end
  end
end
