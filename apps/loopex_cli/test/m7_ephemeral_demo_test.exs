defmodule LoopexCli.M7EphemeralDemoTest do
  use ExUnit.Case, async: false
  @moduletag capture_log: true

  # Concept: the attended ephemeral host shows the real question and passes the
  # typed answer through the public API. Technical depth: a local
  # OpenAI-compatible HTTP server stands in for the provider; the operator's
  # line comes from an in-memory device.

  alias Mix.Tasks.Loopex.M7Evidence.{
    AttemptEvents,
    AttemptWriter,
    CaseRunner,
    EphemeralDemo,
    FixtureManifest
  }

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "m7-ephemeral-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(Path.join(root, "workspace"))
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  for {line, expected} <- [
        {"literal_null", "literal_null"},
        {"1", "empty"},
        {"decline", nil}
      ] do
    @line line
    @expected expected
    test "the operator's #{@line} line reaches the model through the ephemeral answer path", f do
      port =
        start_server([
          {:tool, "ask",
           %{
             "question" => "Which default should nil_mode use?",
             "choices" => ["empty", "literal_null"]
           }},
          "implemented"
        ])

      {:ok, input} = StringIO.open(@line <> "\n")
      {:ok, output} = StringIO.open("")
      record = Path.join(f.root, "record.json")

      status =
        EphemeralDemo.run(
          [
            "--workspace",
            Path.join(f.root, "workspace"),
            "--operator",
            "Maintainer",
            "--record",
            record,
            "--model",
            "ollama:llama3.2",
            "--base-url",
            "http://127.0.0.1:#{port}/v1"
          ],
          input,
          output,
          provider_bindings: %{"ollama" => %{"credential" => %{"none" => true}}},
          max_tokens: 128,
          timeout: 15_000
        )

      assert status == 0, inspect(StringIO.contents(output))
      {_, shown} = StringIO.contents(output)
      assert shown =~ "question: Which default should nil_mode use?"
      assert shown =~ "1. empty" and shown =~ "2. literal_null"
      retained = JSON.decode!(File.read!(record))
      assert retained["operator"] == "Maintainer" and retained["outcome"] == "completed"
      assert retained["question"]["answer"] == @line
      assert_receive {:model_request, _first}, 15_000
      assert_receive {:model_request, second}, 15_000
      [tool] = Enum.filter(body(second)["messages"], &(&1["role"] == "tool"))

      assert tool["content"] =~ (@expected || "declined")
    end
  end

  test "no question means no operator answer and a nonzero status", f do
    port = start_server(["answered without asking"])
    {:ok, input} = StringIO.open("")
    {:ok, output} = StringIO.open("")
    record = Path.join(f.root, "record.json")

    assert EphemeralDemo.run(
             [
               "--workspace",
               Path.join(f.root, "workspace"),
               "--operator",
               "Maintainer",
               "--record",
               record,
               "--model",
               "ollama:llama3.2",
               "--base-url",
               "http://127.0.0.1:#{port}/v1"
             ],
             input,
             output,
             provider_bindings: %{"ollama" => %{"credential" => %{"none" => true}}},
             max_tokens: 128,
             timeout: 15_000
           ) == 1

    assert JSON.decode!(File.read!(record))["question"] == nil
  end

  # The case runner drives the same host from the operator's configuration and
  # selects the independent oracle branch from the recorded answer.
  for {answer, default} <- [{"choice-1", "empty"}, {"choice-2", "literal_null"}] do
    @answer answer
    @default default
    test "the ephemeral case runs the #{@default} oracle branch from the recorded answer", f do
      result = run_case(f, @answer, encoder(@default))
      assert result.mechanical_result == "pass", inspect(result.record)
      record = JSON.decode!(File.read!(Path.join(result.root, "records/ephemeral.json")))
      assert record["question"]["choice"] == @default
      assert File.read!(Path.join(result.root, "records/oracle.txt")) =~ "status=0"
    end
  end

  test "the pinned fixture policy denies an ephemeral write outside the allowed path", f do
    result = run_case(f, "choice-1", encoder("empty"), "README.md")
    assert result.mechanical_result == "assertion_failed"
    refute File.exists?(Path.join([result.root, "workspace", "README.md"]))

    for _ <- 1..2, do: assert_receive({:model_request, _}, 15_000)
    assert_receive {:model_request, third}, 15_000
    [_answer, write] = Enum.filter(body(third)["messages"], &(&1["role"] == "tool"))
    assert write["content"] =~ "denied"

    execution = JSON.decode!(File.read!(Path.join(result.root, "records/execution.json")))
    assert execution["policy"]["id"] =~ "m7.fixture:m7.feature:"
  end

  test "an ephemeral answer the implementation ignores fails the independent oracle", f do
    result = run_case(f, "choice-1", encoder("literal_null"))
    assert result.mechanical_result == "assertion_failed"
    refute File.read!(Path.join(result.root, "records/oracle.txt")) =~ "status=0"
  end

  test "a piped ephemeral case without the operator's answer refuses before dispatch", f do
    assert run_case(f, nil, encoder("empty")).mechanical_result ==
             "evidence_incomplete_pre_dispatch"
  end

  defp run_case(f, answer, content, path \\ "lib/row_encoder.ex") do
    fixtures = Path.expand("../../../test/fixtures/m7", __DIR__)
    {:ok, catalog} = FixtureManifest.load(fixtures)
    File.mkdir_p!(Path.join(f.root, "runs"))
    File.mkdir_p!(Path.join(f.root, "markers"))
    index = Path.join(f.root, "attempts.jsonl")
    campaign = catalog.catalog["execution_manifest"]["campaign_id"]

    identity = %{
      "writer_id" => "writer-1",
      "host_id" => "host-1",
      "marker_dir" => Path.join(f.root, "markers")
    }

    {:ok, writer} = AttemptWriter.create(index, campaign, identity)
    last = index |> File.read!() |> String.split("\n", trim: true) |> List.last()
    {:ok, designation} = AttemptEvents.decode(last)
    config = Path.join(f.root, "template.json")

    File.write!(
      config,
      :json.encode(%{
        "schema_version" => 1,
        "providers" => %{
          "anthropic" => %{"credential" => %{"env" => "M7_UNUSED_FIXTURE_REFERENCE"}}
        },
        "policy" => "shell-allowlist",
        "paths" => %{"workspace" => f.root, "state_root" => Path.join(f.root, "unused")},
        "session" => %{
          "model" => "anthropic:claude-haiku-4-5",
          "tools" => "coding",
          "system_class_tokens" => 8000,
          "bounds" => %{"max_turns" => 8, "deadline_ms" => 15_000, "token_budget" => 100_000}
        }
      })
    )

    [%{"arguments" => question}] =
      catalog.catalog["fixtures"]["feature"]["required_model_actions"]

    port =
      start_server([
        {:tool, "ask", question},
        {:tool, "write", %{"path" => path, "content" => content}},
        "implemented"
      ])

    manifest =
      catalog.catalog
      |> put_in(["execution_manifest", "lanes", "m7-operator"], ["m7.ephemeral-question"])
      |> put_in(["execution_manifest", "cases", "m7.ephemeral-question", "status"], "ready")

    context = %{
      manifest: manifest,
      manifest_digest: catalog.digest,
      catalog_root: fixtures,
      run_root: Path.join(f.root, "runs"),
      candidate: String.duplicate("1", 40),
      concept: "index-head: #{campaign} #{designation["sequence"]} #{designation["digest"]}",
      config_argv: ["chat", "--config", config],
      cwd: f.root,
      operator: "Maintainer",
      answers: if(answer, do: %{"m7.ephemeral-question" => answer}, else: %{}),
      ephemeral_options: [
        model: "ollama:llama3.2",
        base_url: "http://127.0.0.1:#{port}/v1",
        provider_bindings: %{"ollama" => %{"credential" => %{"none" => true}}},
        max_tokens: 128,
        timeout: 15_000
      ]
    }

    {_, [{:ok, result}]} = CaseRunner.run_lane(writer, "m7-operator", context)
    Map.put_new(result, :root, nil)
  end

  defp encoder(default) do
    """
    defmodule RowEncoder do
      def encode(values, options \\\\ []) do
        mode = Keyword.get(options, :nil_mode, :#{default})
        Enum.map_join(values, ",", &value(&1, mode))
      end

      defp value(nil, :empty), do: ""
      defp value(nil, :literal_null), do: "null"
      defp value(value, _mode), do: to_string(value)
    end
    """
  end

  defp body(request) do
    [_, body] = :binary.split(request, "\r\n\r\n")
    JSON.decode!(body)
  end

  defp start_server(answers) do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, {_, port}} = :inet.sockname(listener)
    parent = self()

    server =
      spawn(fn ->
        Enum.each(answers, fn answer ->
          {:ok, socket} = :gen_tcp.accept(listener, 15_000)
          {:ok, request} = read_request(socket, <<>>)
          send(parent, {:model_request, request})
          body = response(answer)

          :ok =
            :gen_tcp.send(socket, [
              "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: ",
              Integer.to_string(byte_size(body)),
              "\r\nconnection: close\r\n\r\n",
              body
            ])

          :gen_tcp.close(socket)
        end)
      end)

    on_exit(fn ->
      if Process.alive?(server), do: Process.exit(server, :kill)
      :gen_tcp.close(listener)
    end)

    port
  end

  defp read_request(socket, buffered) do
    with {header_end, 4} <- :binary.match(buffered, "\r\n\r\n"),
         [_, digits] <- Regex.run(~r/content-length:\s*(\d+)/i, buffered),
         true <- byte_size(buffered) - header_end - 4 >= String.to_integer(digits) do
      {:ok, buffered}
    else
      _ ->
        {:ok, chunk} = :gen_tcp.recv(socket, 0, 15_000)
        read_request(socket, buffered <> chunk)
    end
  end

  defp response({:tool, name, arguments}) do
    JSON.encode!(%{
      id: "chatcmpl-m7",
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
                id: "call_m7_1",
                type: "function",
                function: %{name: name, arguments: JSON.encode!(arguments)}
              }
            ]
          },
          finish_reason: "tool_calls"
        }
      ],
      usage: %{prompt_tokens: 12, completion_tokens: 3, total_tokens: 15}
    })
  end

  defp response(answer) do
    JSON.encode!(%{
      id: "chatcmpl-m7",
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
