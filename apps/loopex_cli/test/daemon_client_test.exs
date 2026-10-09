defmodule LoopexCli.DaemonClientTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO

  alias LoopexCli.{DaemonClient, ProgressConsumer, Render}
  alias LoopexProtocol.{Frame, Wire}

  @domain "MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY"
  @native_domain "0123456789abcdef0123456789abcdef"

  test "conversation content restores exact UTF-8 and opaque bytes from literal envelopes" do
    for {encoded, bytes} <- [{"aMOpbGxvCg", "héllo\n"}, {"AP8K", <<0, 255, 10>>}, {"", ""}] do
      for {kind, identities} <- [
            {"user.message_appended", %{"command_id" => "AP8K", "run_id" => "_w"}},
            {"assistant.message_appended", %{"run_id" => "_w", "turn_id" => "AP8K"}}
          ] do
        record = event(kind, Map.put(identities, "content_b64", encoded))
        assert {:ok, decoded} = DaemonClient.event(framed(record))
        assert decoded["content"] === bytes
        assert decoded["run_id"] === <<255>>
        assert decoded.event_id === "event"
        assert decoded.event_sequence === 2
        refute Map.has_key?(decoded, "content_b64")
      end
    end
  end

  test "the enclosing string ceiling admits exactly 98304 conversation bytes" do
    record = assistant(String.duplicate("YWFh", 32_768))
    assert {:ok, decoded} = DaemonClient.event(framed(record))
    assert decoded["content"] === String.duplicate("a", 98_304)
    assert :error = DaemonClient.event(assistant(String.duplicate("YWFh", 32_768) <> "YQ"))
  end

  test "conversation refuses alternate encodings and superseded raw content" do
    for content <- [nil, 7, "=", "YQ=", "YR", "not+url", "a"] do
      assert :error = DaemonClient.event(assistant(content))
    end

    raw = event("assistant.message_appended", %{"run_id" => "_w", "turn_id" => "AP8K", "content" => "answer"})
    assert :error = DaemonClient.event(raw)
    assert :error = DaemonClient.event(put_in(assistant("YQ"), ["event", "data", "content"], "a"))
  end

  test "complete event envelopes refuse missing extra private and noncanonical fields" do
    record = assistant("YQ")

    for invalid <- [
          Map.delete(record, "session_id"),
          Map.put(record, "private", "CANARY"),
          put_in(record, ["event", "extra"], true),
          put_in(record, ["event", "data", "private"], "CANARY"),
          put_in(record, ["event", "kind"], "unknown"),
          put_in(record, ["event", "event_id"], "ZXZlbnR"),
          put_in(record, ["event", "event_sequence"], "02"),
          put_in(record, ["event", "event_sequence"], 2),
          put_in(record, ["event", "data"], nil),
          Map.put(record, "session_id", "cx")
        ] do
      assert :error = DaemonClient.event(invalid)
    end
  end

  test "run started announces the original opaque identity used by a steer" do
    record = event("run.started", %{"command_id" => "_w", "run_id" => "AP8K"}, "1")
    assert {:ok, decoded} = DaemonClient.event(record)
    owner = self()
    assert {"", ""} = render([decoded], [], fn id -> send(owner, {:announced, id}) end)
    assert_receive {:announced, <<0, 255, 10>>}
    assert Wire.encode_identity(decoded["run_id"]) === "AP8K"
    refute Wire.encode_identity(decoded["run_id"]) === "QVA4Sw"
  end

  test "native conversation rendering prints the model answer and safely escapes raw controls" do
    assert {:ok, user} = DaemonClient.event(event("user.message_appended", %{
      "command_id" => "AP8K", "run_id" => "_w", "content_b64" => "cHJvbXB0"
    }, "1"))
    assert {:ok, answer} = DaemonClient.event(assistant("bW9kZWwgYW5zd2Vy"))
    assert render([user, answer]) === {"> prompt\n\nmodel answer\n", ""}

    assert {:ok, raw} = DaemonClient.event(assistant("AP8K"))
    {stdout, ""} = render([raw])
    refute stdout =~ <<0>>
    refute stdout =~ "nil"
    refute stdout =~ <<255>>
  end

  test "tool events restore opaque call identities and full-range artifact sizes" do
    assert {:ok, started} = DaemonClient.event(event("tool.started", %{
      "run_id" => "_w", "turn_id" => "AP8K", "tool_call_id" => "Y2FsbA",
      "operation_id" => "b3A", "tool_id" => "loopex.read", "tool_version" => "1.2.3"
    }))
    assert started["tool_call_id"] === "call"
    assert started["operation_id"] === "op"
    version = String.duplicate("1", 131_068) <> ".0.0"
    version_record = event("tool.started", %{
      "run_id" => "_w", "turn_id" => "AP8K", "tool_call_id" => "Y2FsbA",
      "operation_id" => "b3A", "tool_id" => "loopex.read", "tool_version" => version
    })
    assert {:ok, versioned} = DaemonClient.event(framed(version_record))
    assert versioned["tool_version"] === version
    assert :error = DaemonClient.event(put_in(version_record, ["event", "data", "tool_version"], "1" <> version))

    artifact = %{
      "digest" => String.duplicate("a", 64), "size" => "18446744073709551615",
      "locator" => "sha256:object", "media_type" => "text/plain", "role" => "tool_output",
      "use_canonicalization_version" => "loopex.canonical.v1",
      "use_digest" => String.duplicate("b", 64), "use_locator" => "use:" <> String.duplicate("b", 64)
    }
    record = event("tool.finished", %{
      "run_id" => "_w", "turn_id" => "AP8K", "tool_call_id" => "Y2FsbA",
      "operation_id" => "b3A", "tool_id" => "loopex.read", "outcome" => "completed",
      "reason" => nil, "artifacts" => [artifact]
    })
    assert {:ok, finished} = DaemonClient.event(framed(record))
    assert hd(finished["artifacts"])["size"] === 18_446_744_073_709_551_615
    {"", stderr} = render([started, finished])
    assert stderr =~ "loopex.read (call)"
    assert stderr =~ "18446744073709551615 bytes"
    assert :error = DaemonClient.event(put_in(record, ["event", "data", "artifacts"], [Map.put(artifact, "private", "CANARY")]))
    assert :error = DaemonClient.event(put_in(record, ["event", "data", "tool_version"], "PRIVATE"))
  end

  test "settlement and queued input resolutions restore exact original command and run bytes" do
    for {kind, data} <- [
          {"session.settled", %{"run_id" => "AP8K"}},
          {"steer.resolved", %{"command_id" => "_w", "run_id" => "AP8K", "disposition" => "applied", "reason" => nil}},
          {"follow_up.resolved", %{"command_id" => "_w", "run_id" => "AP8K", "disposition" => "cancelled", "reason" => "aborted"}}
        ] do
      assert {:ok, decoded} = DaemonClient.event(event(kind, data))
      assert decoded["run_id"] === <<0, 255, 10>>
      if Map.has_key?(data, "command_id"), do: assert(decoded["command_id"] === <<255>>)
    end
  end

  test "terminal completed and cancelled records retain strings and exact cleanup quantities" do
    for outcome <- ["completed", "cancelled"] do
      assert {:ok, decoded} = DaemonClient.event(terminal(outcome))
      assert decoded["outcome"] === outcome
      assert decoded["cleanup_grace_ms"] === 1_000
      assert decoded["command_id"] === nil
      assert decoded["reconciliation_ref"] === nil
      {"", stderr} = render([decoded])
      assert stderr === if(outcome == "completed", do: "\nloopex: done\n", else: "\nloopex: cancelled\n")
    end
  end

  test "terminal bounds and context failures retain quantities beyond JSON integer precision" do
    huge = 1_267_650_600_228_229_401_496_703_205_376
    record = terminal("bound_reached", %{
      "bound" => "token_budget", "observed" => "1267650600228229401496703205376",
      "declared_limit" => "1267650600228229401496703205375", "accounting_source" => "reported"
    })
    assert {:ok, decoded} = DaemonClient.event(record)
    assert decoded["observed"] === huge
    assert decoded["declared_limit"] === huge - 1

    failure = %{"category" => "context_budget_exceeded", "retryable" => false,
      "dimension" => "context_tokens", "observed" => "9007199254740993", "limit" => "9007199254740992"}
    assert {:ok, failed} = DaemonClient.event(terminal("failed", %{"failure" => failure}))
    assert failed["failure"]["observed"] === 9_007_199_254_740_993
    assert failed["failure"]["limit"] === 9_007_199_254_740_992
    refute Map.has_key?(failed, "reason")
    assert :error = DaemonClient.event(put_in(record, ["event", "data", "observed"], "01"))
  end

  test "terminal uncertainty and model failure retain their exact native identity and reason" do
    record = put_in(terminal("outcome_unknown"), ["event", "data", "reconciliation_ref"], "AP8K")
    assert {:ok, decoded} = DaemonClient.event(record)
    assert decoded["reconciliation_ref"] === <<0, 255, 10>>
    assert decoded["outcome"] === "outcome_unknown"
    assert {:ok, failed} = DaemonClient.event(terminal("failed", %{"reason" => "model_call_failed"}))
    assert failed["reason"] === "model_call_failed"
    refute Map.has_key?(failed, "failure")
    assert :error = DaemonClient.event(terminal("completed", %{"private" => "CANARY"}))
  end

  test "configuration checkpoint maintenance and compact completion reuse literal shared vectors" do
    for {file, kind} <- [
          {"configuration-projection.v1.json", "session.configured"},
          {"checkpoint-projection.v1.json", "context.compacted"},
          {"maintenance-view.v1.json", "context.maintenance_changed"},
          {"standalone-compact-completion.v1.json", "context.compaction_finished"}
        ], vector <- vectors(file) do
      {wire, expected} =
        if file == "configuration-projection.v1.json" and vector["scope"] == "configuration" do
          {%{"command_id" => "AP8K", "configuration" => vector["input"]},
           %{"command_id" => %{"opaque_hex" => "00ff0a"}, "configuration" => vector["decoded"]}}
        else
          {vector["input"], vector["decoded"]}
        end

      if Map.has_key?(vector, "decoded") do
        assert {:ok, decoded} = DaemonClient.event(event(kind, wire)), vector["name"]
        assert retained(Map.drop(decoded, [:kind, :event_id, :event_sequence]), expected) === expected
      else
        assert :error = DaemonClient.event(event(kind, wire)), vector["name"]
      end
    end
  end

  test "both interaction producers retain literal question admission and terminal identities" do
    for {file, default_kind} <- [
          {"model-question-requested.v1.json", "interaction.requested"},
          {"model-question-terminal.v1.json", nil},
          {"policy-requested.v1.json", "interaction.requested"},
          {"policy-answer-admitted.v1.json", "interaction.answer_admitted"},
          {"policy-terminal.v1.json", nil}
        ], vector <- vectors(file), Map.has_key?(vector, "decoded") do
      kind = vector["event_kind"] || default_kind || "interaction." <> vector["input"]["disposition"]
      assert {:ok, decoded} = DaemonClient.event(event(kind, vector["input"])), vector["name"]
      assert retained(Map.drop(decoded, [:kind, :event_id, :event_sequence]), vector["decoded"]) === vector["decoded"]
      assert :error = DaemonClient.event(event(kind, Map.put(vector["input"], "private", "CANARY")))
    end
  end

  test "model deltas and closure restore bytes and counts for exact durable suppression" do
    assert {:ok, delta} = DaemonClient.progress(progress(model_delta("answer")))
    assert delta.turn_id === <<0, 255, 10>>
    assert delta.model_sequence === 0
    assert delta.base_event_sequence === 1
    assert delta.stream_domain_id === @native_domain
    assert {:ok, closed} = DaemonClient.progress(progress(model_closed("1")))
    assert closed.delta_count === 1
    assert closed.disposition === :complete
    assert {:ok, answer} = DaemonClient.event(assistant("YW5zd2Vy"))
    assert render([answer], [delta, closed]) === {"answer", ""}
    {state, [{:stdout, "answer"}]} = ProgressConsumer.consume(ProgressConsumer.new(), delta)
    {state, []} = ProgressConsumer.consume(state, closed)
    assert {_, :suppress} = ProgressConsumer.durable_assistant(state, 2, answer["content"])
  end

  test "gapped mismatched and abandoned closures keep the complete durable answer" do
    for closure <- [model_closed("2"), Map.put(model_closed("1"), "disposition", "abandoned")],
        text <- ["answer", "different"] do
      assert {:ok, delta} = DaemonClient.progress(progress(model_delta(text)))
      assert {:ok, closed} = DaemonClient.progress(progress(closure))
      assert {:ok, answer} = DaemonClient.event(assistant("YW5zd2Vy"))
      {stdout, ""} = render([answer], [delta, closed])
      assert stdout === text <> "\nanswer\n"
    end

    assert {:ok, delta} = DaemonClient.progress(progress(Map.put(model_delta("answer"), "model_sequence", "1")))
    assert {:ok, closed} = DaemonClient.progress(progress(model_closed("2")))
    assert {:ok, answer} = DaemonClient.event(assistant("YW5zd2Vy"))
    assert render([answer], [delta, closed]) === {"\nanswer\n", ""}
  end

  test "reasoning tool call and tool byte progress restore every ordinary native field" do
    assert {:ok, reasoning} = DaemonClient.progress(progress(Map.put(model_delta("reason"), "kind", "reasoning_delta")))
    assert reasoning.kind === :reasoning_delta
    call = %{"kind" => "tool_call_delta", "turn_id" => "AP8K", "stream_domain_id" => @domain,
      "model_sequence" => "18446744073709551615", "base_event_sequence" => "1", "call_index" => 0,
      "tool_call_id" => nil, "name" => nil, "arguments_fragment" => nil}
    assert {:ok, decoded_call} = DaemonClient.progress(progress(call))
    assert decoded_call.model_sequence === 18_446_744_073_709_551_615
    assert decoded_call.tool_call_id === nil
    assert {:ok, named} = DaemonClient.progress(progress(Map.merge(call, %{"tool_call_id" => "_w", "name" => "read", "arguments_fragment" => "{}"})))
    assert named.tool_call_id === <<255>>

    tool = %{"kind" => "tool_progress", "turn_id" => "AP8K", "stream_domain_id" => @domain,
      "tool_call_id" => "Y2FsbA", "progress_sequence" => "0", "base_event_sequence" => "1",
      "stream" => "stderr", "byte_offset" => "9007199254740993", "chunk_b64" => "aMOpbGxvCg"}
    assert {:ok, decoded_tool} = DaemonClient.progress(progress(tool))
    assert decoded_tool.byte_offset === 9_007_199_254_740_993
    assert decoded_tool.chunk === "héllo\n"
    assert decoded_tool.stream === "stderr"
    assert {state, [{:stderr, "héllo\n"}]} = ProgressConsumer.consume(ProgressConsumer.new(), decoded_tool)
    closure = %{"kind" => "tool_stream_closed", "turn_id" => "AP8K", "stream_domain_id" => @domain,
      "tool_call_id" => "Y2FsbA", "base_event_sequence" => "1", "disposition" => "complete", "progress_count" => "1"}
    assert {:ok, closed} = DaemonClient.progress(progress(closure))
    assert closed.progress_count === 1
    assert {state, []} = ProgressConsumer.consume(state, closed)
    assert ProgressConsumer.status(state, @native_domain) === :complete
  end

  test "ordinary progress refuses extras old numeric shapes unsafe text and alternate byte encodings" do
    valid = progress(model_delta("answer"))
    for invalid <- [
          Map.put(valid, "private", "CANARY"),
          put_in(valid, ["progress", "private"], "CANARY"),
          put_in(valid, ["progress", "model_sequence"], 0),
          put_in(valid, ["progress", "model_sequence"], "00"),
          put_in(valid, ["progress", "turn_id"], "AP8L="),
          put_in(valid, ["progress", "stream_domain_id"], "ZG9tYWlu"),
          put_in(valid, ["progress", "text"], "answer\e[2J"),
          put_in(valid, ["progress", "content_index"], 0.0),
          put_in(valid, ["progress", "kind"], "novel"),
          put_in(progress(model_closed("1")), ["progress", "disposition"], "novel")
        ] do
      assert :error = DaemonClient.progress(invalid)
    end

    tool = %{"kind" => "tool_progress", "turn_id" => "AP8K", "stream_domain_id" => @domain,
      "tool_call_id" => "Y2FsbA", "progress_sequence" => "0", "base_event_sequence" => "1",
      "stream" => "stdout", "byte_offset" => "0", "chunk_b64" => "YQ"}
    assert {:ok, %{chunk: "a"}} = DaemonClient.progress(progress(tool))
    for invalid <- [Map.put(tool, "chunk_b64", "YQ="), Map.put(tool, "chunk_b64", "YR"),
                    Map.put(tool, "chunk_b64", "Gw"), Map.put(tool, "chunk", "a")] do
      assert :error = DaemonClient.progress(progress(invalid))
    end
  end

  test "compaction activity preserves both owner kinds and never suppresses conversation" do
    for kind <- ["run", "compact"] do
      item = %{"kind" => "context.compaction_progress", "episode_id" => "AP8K",
        "owner" => %{"kind" => kind, "id" => "_wCA"}, "stream_domain_id" => @domain,
        "progress_sequence" => "0", "base_event_sequence" => "18446744073709551615"}
      assert {:ok, native} = DaemonClient.progress(progress(item))
      assert native.episode_id === <<0, 255, 10>>
      assert native.owner === %{"kind" => kind, "id" => <<255, 0, 128>>}
      assert native.progress_sequence === 0
      assert native.base_event_sequence === 18_446_744_073_709_551_615
      state = ProgressConsumer.new()
      assert {^state, []} = ProgressConsumer.consume(state, native)
      assert :error = DaemonClient.progress(progress(Map.put(item, "private", "CANARY")))
      assert :error = DaemonClient.progress(progress(Map.put(item, "progress_sequence", "1")))
    end
  end

  defp event(kind, data, sequence \\ "2"),
    do: %{"type" => "event", "session_id" => "cw", "event" => %{
      "kind" => kind, "event_id" => "ZXZlbnQ", "event_sequence" => sequence, "data" => data
    }}

  defp assistant(content),
    do: event("assistant.message_appended", %{"run_id" => "_w", "turn_id" => "AP8K", "content_b64" => content})

  defp terminal(outcome, extra \\ %{}),
    do: event("run.finished", Map.merge(%{"run_id" => "_w", "command_id" => nil,
      "reconciliation_ref" => nil, "cleanup_grace_ms" => "1000", "outcome" => outcome}, extra))

  defp progress(item), do: %{"type" => "progress", "session_id" => "cw", "progress" => item}

  defp model_delta(text),
    do: %{"kind" => "text_delta", "turn_id" => "AP8K", "stream_domain_id" => @domain,
      "model_sequence" => "0", "base_event_sequence" => "1", "content_index" => 0, "text" => text}

  defp model_closed(count),
    do: %{"kind" => "model_stream_closed", "turn_id" => "AP8K", "stream_domain_id" => @domain,
      "base_event_sequence" => "1", "disposition" => "complete", "delta_count" => count}

  defp framed(record) do
    assert {:ok, encoded} = Frame.encode(record)
    bytes = IO.iodata_to_binary(encoded)
    assert binary_part(bytes, byte_size(bytes) - 1, 1) === "\n"
    assert {:ok, decoded} = Frame.decode(binary_part(bytes, 0, byte_size(bytes) - 1), Frame.output_record_bytes())
    decoded
  end

  defp vectors(file) do
    Path.expand("../../loopex_protocol/priv/vectors/" <> file, __DIR__)
    |> File.read!()
    |> JSON.decode!()
    |> Map.fetch!("cases")
  end

  defp retained(native, %{"opaque_hex" => _}) when is_binary(native),
    do: %{"opaque_hex" => Base.encode16(native, case: :lower)}

  defp retained(native, expected) when is_map(native) and is_map(expected) do
    assert Enum.sort(Map.keys(native)) === Enum.sort(Map.keys(expected))
    Map.new(native, fn {key, value} -> {key, retained(value, Map.fetch!(expected, key))} end)
  end

  defp retained(native, expected) when is_list(native) and is_list(expected) do
    assert length(native) === length(expected)
    Enum.zip_with(native, expected, &retained/2)
  end

  defp retained(native, expected) when is_binary(expected) do
    if Regex.match?(~r/\A-?(?:0|[1-9][0-9]*)\z/, expected) do
      assert is_integer(native)
      Integer.to_string(native)
    else
      native
    end
  end

  defp retained(native, _expected), do: native

  defp render(events, progress \\ [], on_run_started \\ fn _ -> :ok end) do
    key = make_ref()
    Process.put(key, events)
    Enum.each(progress, &send(self(), {:loopex_progress, &1}))
    owner = self()

    try do
      stdout = capture_io(fn ->
        stderr = capture_io(:stderr, fn ->
          assert :ok = Render.stream(nil,
            next_event: fn _ ->
              case Process.get(key) do
                [event | rest] ->
                  Process.put(key, rest)
                  {:ok, event}

                [] ->
                  :stop
              end
            end,
            on_run_started: on_run_started
          )
        end)
        send(owner, {key, stderr})
      end)
      assert_receive {^key, stderr}
      {stdout, stderr}
    after
      Process.delete(key)
    end
  end
end
