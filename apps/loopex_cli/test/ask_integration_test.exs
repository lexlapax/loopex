defmodule LoopexCli.AskIntegrationTest do
  use ExUnit.Case, async: false

  alias LoopexCli.Ask
  alias LoopexComposition.Ephemeral

  setup do
    original = Process.whereis(:erl_signal_server)
    {:ok, manager} = :gen_event.start()
    :ok = :gen_event.add_handler(manager, :erl_signal_handler, [])
    Process.unregister(:erl_signal_server)
    true = Process.register(manager, :erl_signal_server)

    on_exit(fn ->
      if Process.whereis(:erl_signal_server) == manager,
        do: Process.unregister(:erl_signal_server)

      if Process.alive?(manager), do: :gen_event.stop(manager)

      if is_pid(original) and Process.alive?(original),
        do: Process.register(original, :erl_signal_server)
    end)

    %{manager: manager}
  end

  test "the command completes one real in-process model call and proves cleanup" do
    workspace = temporary_workspace()
    {port, _server} = start_server("command answer")

    result =
      Ask.run(
        [
          "-p",
          "one question",
          "--policy",
          "allow-all",
          "--model",
          "ollama:llama3.2",
          "--tools",
          "none",
          "--cwd",
          workspace,
          "--output",
          "json"
        ],
        command_seams(port)
      )

    assert %{status: 0, stderr: "", stdout: stdout} = result
    assert_receive {:model_request, request}, 15_000
    assert request =~ "POST /v1/chat/completions HTTP/1.1"
    assert [encoded, ""] = String.split(stdout, "\n")

    assert %{
             "schema" => "loopex.ask/1",
             "profile" => "ephemeral",
             "outcome" => "completed",
             "text" => "command answer",
             "cleanup" => %{"proved" => true}
           } = JSON.decode!(encoded)

    assert :gen_event.which_handlers(:erl_signal_server) == [:erl_signal_handler]
  end

  test "a signal stops an in-flight real model call before the command emits an answer", %{
    manager: manager
  } do
    workspace = temporary_workspace()
    {port, _server} = start_server(:hold)
    parent = self()

    seams =
      command_seams(port) ++
        [
          stop_session: fn session ->
            result = Ephemeral.stop_session(session)
            send(parent, {:stop_returned, result})
            result
          end
        ]

    {runner, runner_monitor} =
      spawn_monitor(fn ->
        result =
          Ask.run(
            [
              "ask",
              "one question",
              "--policy",
              "allow-all",
              "--model",
              "ollama:llama3.2",
              "--tools",
              "none",
              "--cwd",
              workspace,
              "--output",
              "text"
            ],
            seams
          )

        send(parent, {:ask_returned, result})
      end)

    assert_receive {:model_request, request}, 15_000
    assert request =~ "POST /v1/chat/completions HTTP/1.1"
    assert :ok = :gen_event.sync_notify(manager, :sigterm)
    assert_receive {:stop_returned, :ok}, 15_000

    assert_receive {:ask_returned, %{status: 130, stdout: "", stderr: stderr}}, 15_000
    assert stderr in ["", "ending cancelled\n"]

    assert_receive {:DOWN, ^runner_monitor, :process, ^runner, :normal}, 1_000
    assert :gen_event.which_handlers(manager) == [:erl_signal_handler]
  end

  test "a signal before handle creation is held until the real session starts", %{
    manager: manager
  } do
    workspace = temporary_workspace()
    {port, _server} = start_server(:hold)
    parent = self()

    seams =
      Keyword.merge(command_seams(port),
        start_session: fn options ->
          send(parent, :startup_entered_without_handle)

          receive do
            :release_start ->
              Ephemeral.start_session(
                Keyword.merge(options,
                  base_url: "http://127.0.0.1:#{port}/v1",
                  max_tokens: 128,
                  timeout: 15_000
                )
              )
          end
        end,
        ask: fn _session, _prompt ->
          send(parent, :worker_started)
          flunk("worker started after pre-handle signal")
        end,
        stop_session: fn session ->
          result = Ephemeral.stop_session(session)
          send(parent, {:stop_returned, result})
          result
        end
      )

    {runner, runner_monitor} =
      spawn_monitor(fn ->
        result =
          Ask.run(
            [
              "-p",
              "one question",
              "--policy",
              "allow-all",
              "--model",
              "ollama:llama3.2",
              "--tools",
              "none",
              "--cwd",
              workspace
            ],
            seams
          )

        send(parent, {:ask_returned, result})
      end)

    assert_receive :startup_entered_without_handle, 15_000
    assert :ok = :gen_event.sync_notify(manager, :sigterm)
    send(runner, :release_start)
    assert_receive {:stop_returned, :ok}, 15_000
    assert_receive {:ask_returned, %{status: 130, stdout: ""}}, 15_000
    assert_receive {:DOWN, ^runner_monitor, :process, ^runner, :normal}, 1_000
    refute_receive :worker_started, 0
    refute_receive {:model_request, _}, 0
    assert :gen_event.which_handlers(manager) == [:erl_signal_handler]
  end

  test "a signal after handle creation is retained until startup returns", %{manager: manager} do
    workspace = temporary_workspace()
    {port, _server} = start_server(:hold)
    parent = self()

    seams =
      Keyword.merge(command_seams(port),
        start_session: fn options ->
          result =
            Ephemeral.start_session(
              Keyword.merge(options,
                base_url: "http://127.0.0.1:#{port}/v1",
                max_tokens: 128,
                timeout: 15_000
              )
            )

          send(parent, {:handle_started, result})

          receive do
            :release_start -> result
          end
        end,
        ask: fn session, prompt ->
          send(parent, :worker_started)
          Ephemeral.ask(session, prompt)
        end,
        stop_session: fn session ->
          result = Ephemeral.stop_session(session)
          send(parent, {:stop_returned, result})
          result
        end
      )

    {runner, runner_monitor} =
      spawn_monitor(fn ->
        result =
          Ask.run(
            [
              "-p",
              "one question",
              "--policy",
              "allow-all",
              "--model",
              "ollama:llama3.2",
              "--tools",
              "none",
              "--cwd",
              workspace
            ],
            seams
          )

        send(parent, {:ask_returned, result})
      end)

    assert_receive {:handle_started, {:ok, _handle}}, 15_000
    assert :ok = :gen_event.sync_notify(manager, :sigterm)
    send(runner, :release_start)
    assert_receive {:stop_returned, :ok}, 15_000
    assert_receive {:ask_returned, %{status: 130, stdout: ""}}, 15_000
    assert_receive {:DOWN, ^runner_monitor, :process, ^runner, :normal}, 1_000
    refute_receive :worker_started, 0
    refute_receive {:model_request, _}, 0
    assert :gen_event.which_handlers(manager) == [:erl_signal_handler]
  end

  test "a copied exact-reference notice cannot stop an idle handler", %{manager: manager} do
    workspace = temporary_workspace()
    {port, server} = start_server({:hold, "forged notice ignored"})
    parent = self()

    seams =
      Keyword.merge(command_seams(port),
        install_interrupt: fn main, reference ->
          send(parent, {:ask_reference, reference})
          LoopexCli.Interrupt.install_ask(main, reference)
        end
      )

    {runner, runner_monitor} =
      spawn_monitor(fn ->
        result =
          Ask.run(
            [
              "ask",
              "one question",
              "--policy",
              "allow-all",
              "--model",
              "ollama:llama3.2",
              "--tools",
              "none",
              "--cwd",
              workspace,
              "--output",
              "json"
            ],
            seams
          )

        send(parent, {:ask_returned, result})
      end)

    assert_receive {:ask_reference, reference}, 15_000
    assert_receive {:model_request, request}, 15_000
    assert request =~ "POST /v1/chat/completions HTTP/1.1"
    send(runner, {manager, reference, :interrupt})
    assert LoopexCli.Interrupt.ask_phase(manager, reference) == :idle
    send(server, :release)

    assert_receive {:ask_returned, %{status: 0, stdout: stdout, stderr: ""}}, 15_000

    assert %{"outcome" => "completed", "text" => "forged notice ignored"} =
             JSON.decode!(String.trim_trailing(stdout, "\n"))

    assert_receive {:DOWN, ^runner_monitor, :process, ^runner, :normal}, 1_000
    assert :gen_event.which_handlers(manager) == [:erl_signal_handler]
  end

  defp command_seams(port) do
    [
      quiet_logger: fn -> :ok end,
      start_session: fn options ->
        Ephemeral.start_session(
          Keyword.merge(options,
            base_url: "http://127.0.0.1:#{port}/v1",
            max_tokens: 128,
            timeout: 15_000
          )
        )
      end
    ]
  end

  defp temporary_workspace do
    path = Path.join(System.tmp_dir!(), "loopex-ask-#{System.unique_integer([:positive])}")
    File.mkdir!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end

  defp start_server(answer) do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, {_, port}} = :inet.sockname(listener)
    parent = self()

    server =
      spawn(fn ->
        case :gen_tcp.accept(listener, 15_000) do
          {:ok, socket} ->
            serve(socket, parent, answer)

          {:error, :closed} ->
            :ok
        end
      end)

    on_exit(fn ->
      monitor = Process.monitor(server)
      if Process.alive?(server), do: Process.exit(server, :kill)

      receive do
        {:DOWN, ^monitor, :process, ^server, _reason} -> :ok
      after
        1_000 -> :ok
      end

      :gen_tcp.close(listener)
    end)

    {port, server}
  end

  defp serve(socket, parent, answer) do
    {:ok, request} = read_request(socket, <<>>)
    send(parent, {:model_request, request})

    reply =
      case answer do
        :hold ->
          receive do
            :release -> "unexpected answer"
          end

        {:hold, value} ->
          receive do
            :release -> value
          end

        value ->
          value
      end

    body =
      JSON.encode!(%{
        id: "chatcmpl-loopex-ask",
        object: "chat.completion",
        created: 1_800_000_000,
        model: "llama3.2",
        choices: [
          %{index: 0, message: %{role: "assistant", content: reply}, finish_reason: "stop"}
        ],
        usage: %{prompt_tokens: 12, completion_tokens: 3, total_tokens: 15}
      })

    :ok =
      :gen_tcp.send(socket, [
        "HTTP/1.1 200 OK\r\n",
        "content-type: application/json\r\n",
        "content-length: ",
        Integer.to_string(byte_size(body)),
        "\r\nconnection: close\r\n\r\n",
        body
      ])

    :gen_tcp.close(socket)
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
