defmodule LoopexComposition.Ephemeral.ProviderEnvironmentTest do
  @moduledoc false
  use ExUnit.Case, async: false

  alias LoopexComposition.Ephemeral

  @variables ~w(OPENAI_API_KEY ANTHROPIC_API_KEY OPENROUTER_API_KEY LOOPEX_PROVIDER_API_KEY)

  defmodule Policy do
    @moduledoc false
    @behaviour Loopex.Policy

    @impl true
    def decide(_request), do: {:allow, nil}
  end

  setup do
    original = Map.new(@variables, &{&1, System.get_env(&1)})
    synthetic = Map.new(@variables, &{&1, "synthetic-m6-" <> String.downcase(&1)})
    Enum.each(synthetic, fn {name, value} -> System.put_env(name, value) end)

    workspace =
      Path.join(
        System.tmp_dir!(),
        "loopex-provider-environment-#{System.unique_integer([:positive])}"
      )

    File.mkdir!(workspace)

    on_exit(fn ->
      Enum.each(original, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)

      File.rm_rf!(workspace)
    end)

    {:ok, workspace: workspace, synthetic: synthetic}
  end

  test "every provider admits each tool preset with ambient provider variables", context do
    models = [
      {"ollama:llama3.2", "http://127.0.0.1:1"},
      {"openai:gpt-4o-mini", "https://127.0.0.1:1"},
      {"anthropic:claude-haiku-4-5", "https://127.0.0.1:1"},
      {"openrouter:openai/gpt-4o-mini", "https://127.0.0.1:1"}
    ]

    for {model, base_url} <- models, tools <- [:none, :coding, :read_only] do
      assert {:ok, session} =
               Ephemeral.start_session(
                 policy: Policy,
                 model: model,
                 base_url: base_url,
                 cwd: context.workspace,
                 tools: tools,
                 timeout: 15_000
               )

      try do
        assert :none = Ephemeral.last_result(session)
        assert {:ok, %{entries: [], truncated: false}} = history = Ephemeral.history(session)
        assert_no_synthetic_key({session, history}, context.synthetic)
        assert_ambient_unchanged(context.synthetic)
      after
        assert :ok = Ephemeral.stop_session(session)
      end
    end
  end

  test "ambient keys do not block either local tool preset at dispatch", context do
    File.write!(Path.join(context.workspace, "safe.txt"), "ambient-safe-marker")

    for tools <- [:coding, :read_only] do
      port = start_server()

      assert {:ok, %{outcome: :completed, text: "read complete", tools: entries} = result} =
               Ephemeral.run("read safe.txt",
                 policy: Policy,
                 model: "ollama:llama3.2",
                 base_url: "http://127.0.0.1:#{port}/v1",
                 cwd: context.workspace,
                 tools: tools,
                 max_tokens: 128,
                 timeout: 15_000
               )

      assert [%{tool_id: "loopex.read", outcome: "completed"}] = entries
      assert_receive {:model_request, first}, 15_000
      assert_receive {:model_request, second}, 15_000
      assert first =~ "POST /v1/chat/completions HTTP/1.1"
      assert second =~ "ambient-safe-marker"
      assert_no_synthetic_key({result, first, second}, context.synthetic)
      assert_ambient_unchanged(context.synthetic)
    end
  end

  defp assert_ambient_unchanged(synthetic) do
    Enum.each(synthetic, fn {name, value} ->
      assert System.get_env(name) == value
    end)
  end

  defp assert_no_synthetic_key(value, synthetic) do
    bytes = :erlang.term_to_binary(value)

    Enum.each(synthetic, fn {_name, secret} ->
      assert :binary.match(bytes, secret) == :nomatch
    end)
  end

  defp start_server do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, {_, port}} = :inet.sockname(listener)
    parent = self()

    server =
      spawn(fn ->
        for body <- [tool_response(), answer_response()] do
          {:ok, socket} = :gen_tcp.accept(listener, 15_000)
          {:ok, request} = read_request(socket, <<>>)
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

        :gen_tcp.close(listener)
      end)

    on_exit(fn ->
      :gen_tcp.close(listener)
      if Process.alive?(server), do: Process.exit(server, :kill)
    end)

    port
  end

  defp tool_response do
    JSON.encode!(%{
      id: "tool",
      object: "chat.completion",
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
                function: %{name: "read", arguments: JSON.encode!(%{path: "safe.txt"})}
              }
            ]
          },
          finish_reason: "tool_calls"
        }
      ],
      usage: %{prompt_tokens: 1, completion_tokens: 1, total_tokens: 2}
    })
  end

  defp answer_response do
    JSON.encode!(%{
      id: "answer",
      object: "chat.completion",
      choices: [
        %{
          index: 0,
          message: %{role: "assistant", content: "read complete"},
          finish_reason: "stop"
        }
      ],
      usage: %{prompt_tokens: 1, completion_tokens: 1, total_tokens: 2}
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

        if byte_size(body) >= size, do: {:ok, buffered}, else: read_more(socket, buffered)

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
