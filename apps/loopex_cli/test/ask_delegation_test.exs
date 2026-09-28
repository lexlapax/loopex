defmodule LoopexCli.AskDelegationTest do
  @moduledoc """
  ## Concept

  A separate program can run `loopex -p`, consume its one JSON result and use
  the exit status to decide whether the delegated question succeeded.

  ## Technical depth

  The delegated child executes the production ask command and ephemeral API in
  its own VM. A test-only address seam points its Ollama call at a local TCP
  responder, since the public command deliberately has no endpoint flag.
  """

  use ExUnit.Case, async: false

  @moduletag timeout: 120_000
  @launcher Path.expand("../bin/loopex", __DIR__)

  test "another OS process delegates to loopex -p and parses its JSON answer" do
    root = temporary_directory()
    on_exit(fn -> File.rm_rf!(root) end)
    {port, server} = start_server("delegated answer")
    server_monitor = Process.monitor(server)
    stand_in = Path.join(root, "loopex-child")
    File.write!(stand_in, stand_in_source())
    File.chmod!(stand_in, 0o755)

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

  defp stand_in_source do
    elixir = System.find_executable("elixir") || flunk("Elixir is unavailable")

    paths =
      Enum.map_join(:code.get_path(), " ", fn path ->
        "-pa " <> shell_quote(List.to_string(path))
      end)

    program = """
    port = System.fetch_env!("LOOPEX_TEST_PORT")
    manager = spawn(fn -> receive do :release -> :ok end end)
    seams = [
      install_interrupt: fn _, _ -> {:ok, manager} end,
      signal_manager: fn -> manager end,
      handler_live: fn _, _ -> true end,
      interrupt_phase: fn _, _ -> :idle end,
      finish_interrupt: fn _, _ -> {:ok, :ordinary} end,
      start_session: fn options ->
        LoopexComposition.Ephemeral.start_session(
          Keyword.merge(options,
            base_url: "http://127.0.0.1:" <> port <> "/v1",
            max_tokens: 128,
            timeout: 15_000
          )
        )
      end
    ]
    %{status: status, stdout: stdout, stderr: stderr} = LoopexCli.Ask.run(System.argv(), seams)
    if stdout != "", do: IO.binwrite(:stdio, stdout)
    if stderr != "", do: IO.binwrite(:stderr, stderr)
    System.halt(status)
    """

    "#!/bin/sh\nexec #{shell_quote(elixir)} #{paths} -e #{shell_quote(program)} -- \"$@\"\n"
  end

  defp delegator_source do
    """
    import json
    import subprocess
    import sys

    completed = subprocess.run(
        [sys.argv[1], '-p', 'delegated question', '--policy', 'allow-all',
         '--model', 'ollama:llama3.2', '--tools', 'none', '--output', 'json'],
        capture_output=True, text=True, timeout=30, check=False)
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
