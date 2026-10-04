defmodule LoopexComposition.Ephemeral.ToolPresetBudgetTest do
  use ExUnit.Case, async: false

  alias Loopex.Bounds
  alias Loopex.Executor.Local.CodingTools
  alias LoopexComposition.Ephemeral
  alias LoopexProtocol.{Canonical, ToolDefinition}

  defmodule Policy do
    @moduledoc false
    @behaviour Loopex.Policy
    @impl true
    def decide(_request), do: {:allow, nil}
  end

  test "each literal preset runs and its actual system class stays below ADR 0017's ceiling" do
    definitions = CodingTools.definitions()

    for {preset, ids} <- [
          {:none, []},
          {:coding, ~w(loopex.read loopex.write loopex.edit loopex.bash)},
          {:read_only, ~w(loopex.read loopex.grep loopex.find loopex.ls)}
        ] do
      workspace =
        Path.join(System.tmp_dir!(), "loopex-preset-#{System.unique_integer([:positive])}")

      File.mkdir!(workspace)
      on_exit(fn -> File.rm_rf!(workspace) end)
      port = start_server()

      assert {:ok, %{outcome: :completed, text: "preset admitted"}} =
               Ephemeral.run("check the preset",
                 policy: Policy,
                 model: "ollama:llama3.2",
                 base_url: "http://127.0.0.1:#{port}/v1",
                 cwd: workspace,
                 tools: preset,
                 max_tokens: 128,
                 timeout: 15_000
               )

      assert_receive {:preset_request, body}, 15_000
      request = Jason.decode!(body)
      assert [system | _] = request["messages"]
      assert system["role"] == "system"
      assert String.starts_with?(system["content"], "loopex.reference.v1:")

      selected = Enum.filter(definitions, &(&1["tool_id"] in ids))
      assert Enum.map(selected, & &1["tool_id"]) == ids

      assert Enum.map(request["tools"] || [], &get_in(&1, ["function", "name"])) ==
               Enum.map(selected, & &1["name"])

      system_tokens =
        Bounds.estimate(Canonical.encode(%{"role" => "system", "content" => system["content"]})) +
          Enum.sum(
            Enum.map(selected, fn definition ->
              definition
              |> ToolDefinition.model_facing()
              |> Canonical.encode()
              |> Bounds.estimate()
            end)
          )

      assert system_tokens < 1_000
    end
  end

  defp start_server do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, {_, port}} = :inet.sockname(listener)
    parent = self()

    server =
      spawn(fn ->
        {:ok, socket} = :gen_tcp.accept(listener, 15_000)
        body = read_request(socket, <<>>)
        send(parent, {:preset_request, body})

        response =
          Jason.encode!(%{
            "id" => "preset",
            "object" => "chat.completion",
            "choices" => [
              %{
                "index" => 0,
                "message" => %{"role" => "assistant", "content" => "preset admitted"},
                "finish_reason" => "stop"
              }
            ],
            "usage" => %{"prompt_tokens" => 1, "completion_tokens" => 2}
          })

        :ok =
          :gen_tcp.send(socket, [
            "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: ",
            Integer.to_string(byte_size(response)),
            "\r\nconnection: close\r\n\r\n",
            response
          ])

        :gen_tcp.close(socket)
        :gen_tcp.close(listener)
      end)

    on_exit(fn ->
      :gen_tcp.close(listener)
      if Process.alive?(server), do: Process.exit(server, :kill)
    end)

    port
  end

  defp read_request(socket, bytes) do
    case :binary.split(bytes, "\r\n\r\n") do
      [headers, body] ->
        length =
          headers
          |> String.split("\r\n")
          |> Enum.find_value(fn line ->
            case String.split(line, ":", parts: 2) do
              [name, value] ->
                if String.downcase(name) == "content-length",
                  do: String.to_integer(String.trim(value))

              _ ->
                nil
            end
          end)

        if byte_size(body) >= length,
          do: binary_part(body, 0, length),
          else: read_request(socket, receive_bytes(socket, bytes))

      _ ->
        read_request(socket, receive_bytes(socket, bytes))
    end
  end

  defp receive_bytes(socket, bytes) do
    {:ok, more} = :gen_tcp.recv(socket, 0, 15_000)
    bytes <> more
  end
end
