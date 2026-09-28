defmodule LoopexCli.AskRealTest do
  @moduledoc """
  ## Concept

  The release lane proves that a separate operating-system process can ask a
  local Ollama model through the shipped command without a state root or key.

  ## Technical depth

  The runner builds the escript from its fresh source archive before this case.
  Its credential-clearing wrapper is repeated here so a direct invocation has
  the same boundary. Only the closed public JSON object and process exit are
  observed; no in-process session handle is shared with the test.
  """

  use ExUnit.Case, async: false

  @tag :real_provider
  @tag timeout: 180_000
  test "ephemeral ask answers from a local Ollama model through a separate process" do
    command = Path.expand("../loopex", __DIR__)
    assert File.regular?(command) and Bitwise.band(File.stat!(command).mode, 0o111) != 0

    workspace =
      Path.join(System.tmp_dir!(), "loopex-ask-real-#{System.unique_integer([:positive])}")

    File.mkdir!(workspace)
    on_exit(fn -> File.rm_rf!(workspace) end)

    model = System.fetch_env!("LOOPEX_RELEASE_OLLAMA_MODEL")
    assert String.starts_with?(model, "ollama:") and byte_size(model) > byte_size("ollama:")
    assert_local_model_available!(model)

    {output, status} =
      System.cmd(
        "env",
        [
          "-u",
          "LOOPEX_PROVIDER_API_KEY",
          "-u",
          "OPENAI_API_KEY",
          "-u",
          "ANTHROPIC_API_KEY",
          "-u",
          "OPENROUTER_API_KEY",
          "-u",
          "OPEN_ROUTER_API_KEY",
          "-u",
          "LOOPEX_HOME",
          "-u",
          "OLLAMA_HOST",
          command,
          "-p",
          "Answer in one short sentence: what is two plus two?",
          "--policy",
          "allow-all",
          "--model",
          model,
          "--tools",
          "none",
          "--cwd",
          workspace,
          "--deadline-ms",
          "90000",
          "--output",
          "json"
        ],
        stderr_to_stdout: false
      )

    assert status == 0
    assert [encoded, ""] = String.split(output, "\n")
    result = JSON.decode!(encoded)

    assert Enum.sort(Map.keys(result)) ==
             Enum.sort(~w(schema session_id run_id profile outcome text text_truncated tools
                          tools_truncated shadowed_skills cleanup details))

    assert result["schema"] == "loopex.ask/1"
    assert result["profile"] == "ephemeral"
    assert result["outcome"] == "completed"
    assert result["cleanup"] == %{"proved" => true}
    assert is_binary(result["text"]) and String.trim(result["text"]) != ""
    assert result["tools"] == []
    IO.puts(:stderr, "loopex M6 delegated local ask completed with proved cleanup")
  end

  defp assert_local_model_available!(model) do
    body = JSON.encode!(%{"model" => String.replace_prefix(model, "ollama:", "")})

    available =
      case :gen_tcp.connect(
             {127, 0, 0, 1},
             11_434,
             [:binary, active: false, packet: :line],
             3_000
           ) do
        {:ok, socket} ->
          try do
            request = [
              "POST /api/show HTTP/1.1\r\n",
              "host: 127.0.0.1:11434\r\n",
              "content-type: application/json\r\n",
              "content-length: ",
              Integer.to_string(byte_size(body)),
              "\r\nconnection: close\r\n\r\n",
              body
            ]

            with :ok <- :gen_tcp.send(socket, request),
                 {:ok, <<"HTTP/1.", version, " 200 ", _::binary>>} <-
                   :gen_tcp.recv(socket, 0, 3_000),
                 true <- version in [?0, ?1] do
              true
            else
              _ -> false
            end
          after
            :gen_tcp.close(socket)
          end

        _ ->
          false
      end

    assert available,
           "release evidence unavailable: local Ollama does not have #{model} on 127.0.0.1:11434"
  end
end
