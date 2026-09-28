defmodule LoopexComposition.Ephemeral.ModelIntegrationTest do
  use ExUnit.Case, async: false

  alias LoopexComposition.Ephemeral

  defmodule Policy do
    @moduledoc false
    @behaviour Loopex.Policy

    @impl true
    def decide(_request), do: {:allow, nil}
  end

  test "a real in-process model turn retires custody before a second ask and stop" do
    root = Path.join(System.tmp_dir!(), "loopex-model-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, {_, port}} = :inet.sockname(listener)
    parent = self()

    server =
      spawn(fn ->
        for answer <- ["first answer", "second answer"] do
          {:ok, socket} = :gen_tcp.accept(listener, 15_000)
          {:ok, request} = read_request(socket, <<>>)
          send(parent, {:model_request, request})
          body = response(answer)

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
      end)

    on_exit(fn ->
      :gen_tcp.close(listener)
      if Process.alive?(server), do: Process.exit(server, :kill)
    end)

    assert {:ok, session} =
             Ephemeral.start_session(
               policy: Policy,
               model: "ollama:llama3.2",
               base_url: "http://127.0.0.1:#{port}/v1",
               cwd: root,
               tools: :none,
               max_tokens: 128,
               timeout: 15_000
             )

    assert {:ok, %{outcome: :completed, text: "first answer"}} =
             Ephemeral.ask(session, "first prompt")

    assert_receive {:model_request, first_request}, 15_000
    assert first_request =~ "POST /v1/chat/completions HTTP/1.1"

    # The owner-start ticket expires after one second; a running session must
    # outlive it and admit another model call.
    Process.sleep(1_100)

    assert {:ok, %{outcome: :completed, text: "second answer"}} =
             Ephemeral.ask(session, "second prompt")

    assert_receive {:model_request, second_request}, 15_000
    assert second_request =~ "POST /v1/chat/completions HTTP/1.1"
    assert :ok = Ephemeral.stop_session(session)
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
    with {:ok, chunk} <- :gen_tcp.recv(socket, 0, 15_000),
         true <- byte_size(buffered) + byte_size(chunk) <= 1_048_576 do
      read_request(socket, buffered <> chunk)
    else
      other -> other
    end
  end

  defp response(answer) do
    JSON.encode!(%{
      id: "chatcmpl-loopex-fixture",
      object: "chat.completion",
      created: 1_800_000_000,
      model: "llama3.2",
      choices: [
        %{index: 0, message: %{role: "assistant", content: answer}, finish_reason: "stop"}
      ],
      usage: %{prompt_tokens: 12, completion_tokens: 3, total_tokens: 15}
    })
  end
end
