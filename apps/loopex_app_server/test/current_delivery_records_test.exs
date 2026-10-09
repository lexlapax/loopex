defmodule Loopex.AppServer.CurrentDeliveryRecordsTest do
  @moduledoc """
  ## Concept

  The foreground publishes the complete current public event contract and
  detaches before malformed durable data can become client history.

  ## Technical depth

  Existing accepted vectors cover configuration, checkpoint, maintenance,
  compact completion, both interaction producers and terminal outcome families.
  Queue tests retain an earlier active frame across refusal and require its
  exact completion before emitted history or physical credit changes.
  """

  use ExUnit.Case, async: true

  alias Loopex.AppServer.Delivery
  alias LoopexProtocol.{Frame, Wire}

  alias LoopexProtocol.Session.{
    Checkpoint,
    CompactResult,
    Configuration,
    InteractionEvent,
    MaintenanceView,
    Outcome
  }

  test "complete current event payloads reproduce the accepted codec vectors" do
    for {kind, native, wire} <- current_payloads() do
      event = event(kind, native, 1)
      queue = Delivery.new(<<255, 0>>, 0) |> Delivery.event(event)
      refute Delivery.detached?(queue), kind
      assert Delivery.cursor(queue) == 0
      assert Delivery.pulled_cursor(queue) == 1
      {:ok, entry} = Delivery.next(queue)
      record = decode(entry.frame)
      assert record["session_id"] == "_wA"

      assert record["event"] == %{
               "kind" => kind,
               "event_id" => "AP8K",
               "event_sequence" => "1",
               "data" => wire
             }

      reference = make_ref()
      {:ok, active} = Delivery.activate(queue, entry.token, reference)
      {:ok, _entry, joined} = Delivery.joined(active, reference)
      assert Delivery.cursor(joined) == 1
      assert Delivery.usage(joined).durable == {0, 0}
    end
  end

  test "closed event families refuse private extra members without publishing or advancing truth" do
    for {kind, native, _wire} <- current_payloads() do
      rejected =
        Delivery.event(
          Delivery.new("session", 7),
          event(kind, Map.put(native, "private_capture", "PRIVATE_EVENT_CANARY"), 8)
        )

      assert Delivery.detached?(rejected), kind
      assert Delivery.cursor(rejected) == 7
      assert Delivery.pulled_cursor(rejected) == 7
      assert Delivery.usage(rejected).durable == {0, 0}
      assert Delivery.next(rejected) == :empty
      assert Delivery.detachment(rejected)["event_cursor"] == "7"
    end
  end

  test "policy terminal reasons stay private while the accepted terminal tuple survives" do
    vector = Enum.find(vectors("policy-terminal.v1.json"), &is_nil(&1["error"]))
    kind = vector["event_kind"]
    assert {:ok, native} = InteractionEvent.decode(kind, vector["input"])
    native = Map.put(native, "reason", <<255, 0>> <> "PRIVATE_POLICY_REASON")
    queue = Delivery.new("session", 0) |> Delivery.event(event(kind, native, 1))
    refute Delivery.detached?(queue)
    {:ok, entry} = Delivery.next(queue)
    assert decode(entry.frame)["event"]["data"] == vector["input"]
    refute entry.frame =~ "PRIVATE_POLICY_REASON"
  end

  test "nested private captures and missing public members reject the complete durable record" do
    for {kind, native, _wire} <- current_payloads() do
      nested =
        for {field, value} <- native,
            is_map(value),
            do: Map.put(native, field, Map.put(value, "private_capture", "PRIVATE_NESTED_CANARY"))

      missing = for field <- Map.keys(native), do: Map.delete(native, field)

      for invalid <- nested ++ missing do
        rejected = Delivery.event(Delivery.new("session", 7), event(kind, invalid, 8))
        assert Delivery.detached?(rejected), kind
        assert Delivery.cursor(rejected) == 7
        assert Delivery.pulled_cursor(rejected) == 7
        assert Delivery.usage(rejected).durable == {0, 0}
        assert Delivery.next(rejected) == :empty
      end
    end
  end

  test "ordinary conversation tool and resolution events encode only their public fields" do
    identity = <<0, 255, 10>>

    artifact = %{
      "digest" => String.duplicate("a", 64),
      "size" => 18_446_744_073_709_551_615,
      "locator" => "object:opaque",
      "media_type" => "text/plain",
      "role" => "tool_output",
      "use_canonicalization_version" => "loopex.canonical.v1",
      "use_digest" => String.duplicate("b", 64),
      "use_locator" => "use:" <> String.duplicate("b", 64)
    }

    ids = %{
      "run_id" => identity,
      "turn_id" => identity,
      "tool_call_id" => identity,
      "operation_id" => identity,
      "tool_id" => "test.tool"
    }

    cases = [
      {"user.message_appended",
       %{"command_id" => identity, "run_id" => identity, "content" => <<255, 0, 10>>}},
      {"run.started", %{"command_id" => identity, "run_id" => identity}},
      {"assistant.message_appended",
       %{"run_id" => identity, "turn_id" => identity, "content" => <<255, 0, 10>>}},
      {"tool.started", Map.put(ids, "tool_version", "1.2.3")},
      {"tool.finished",
       Map.merge(ids, %{"outcome" => "completed", "reason" => nil, "artifacts" => [artifact]})},
      {"steer.resolved",
       %{
         "command_id" => identity,
         "run_id" => identity,
         "disposition" => "unapplied",
         "reason" => "run_terminal"
       }},
      {"follow_up.resolved",
       %{
         "command_id" => identity,
         "run_id" => identity,
         "disposition" => "cancelled",
         "reason" => "aborted"
       }},
      {"session.settled", %{"run_id" => identity}}
    ]

    for {kind, native} <- cases do
      queue = Delivery.event(Delivery.new("session", 0), event(kind, native, 1))
      refute Delivery.detached?(queue)
      {:ok, entry} = Delivery.next(queue)
      data = decode(entry.frame)["event"]["data"]

      for field <- ~w(command_id run_id turn_id tool_call_id operation_id),
          Map.has_key?(native, field) do
        assert data[field] == "AP8K"
      end

      if Map.has_key?(native, "content") do
        assert data["content_b64"] == "_wAK"
        refute Map.has_key?(data, "content")
      end

      if kind == "tool.finished" do
        assert data["artifacts"] == [Map.put(artifact, "size", "18446744073709551615")]
      end

      for invalid <- [Map.put(native, "private", "PRIVATE_CANARY"), Map.delete(native, "run_id")] do
        assert Delivery.detached?(
                 Delivery.event(Delivery.new("session", 0), event(kind, invalid, 1))
               )
      end
    end
  end

  test "malformed envelope payload union and nested artifact detach while active credit remains" do
    valid = event("run.started", %{"command_id" => "command", "run_id" => "run"}, 8)
    queue = Delivery.new("session", 7) |> Delivery.event(valid)
    {:ok, entry} = Delivery.next(queue)
    reference = make_ref()
    {:ok, active} = Delivery.activate(queue, entry.token, reference)

    malformed = [
      nil,
      Map.put(valid, :__struct__, __MODULE__),
      Map.delete(valid, :event_id),
      Map.put(valid, :event_id, ""),
      Map.put(valid, :event_id, String.duplicate("e", 65_537)),
      Map.put(valid, :event_sequence, -1),
      Map.put(valid, :event_sequence, "9"),
      Map.put(valid, :event_sequence, 18_446_744_073_709_551_616),
      Map.put(valid, :kind, "run.progressed"),
      Map.put(valid, :kind, :run_started),
      Map.put(valid, :private, self()),
      event(
        "tool.started",
        %{
          "run_id" => "run",
          "turn_id" => "turn",
          "tool_call_id" => "call",
          "operation_id" => "operation",
          "tool_id" => "PRIVATE\nTOOL",
          "tool_version" => "1.0.0"
        },
        9
      ),
      event(
        "tool.finished",
        %{
          "run_id" => "run",
          "turn_id" => "turn",
          "tool_call_id" => "call",
          "operation_id" => "operation",
          "tool_id" => "test.tool",
          "outcome" => "completed",
          "reason" => "PRIVATE_REASON",
          "artifacts" => []
        },
        9
      ),
      event(
        "tool.finished",
        %{
          "run_id" => "run",
          "turn_id" => "turn",
          "tool_call_id" => "call",
          "operation_id" => "operation",
          "tool_id" => "test.tool",
          "outcome" => "completed",
          "reason" => nil,
          "artifacts" => [%{"private" => "PRIVATE_ARTIFACT"}]
        },
        9
      ),
      event(
        "run.finished",
        %{
          "run_id" => "run",
          "command_id" => nil,
          "reconciliation_ref" => nil,
          "cleanup_grace_ms" => 5_000,
          "outcome" => "failed",
          "reason" => "model_call_failed",
          "failure" => %{"private" => "PRIVATE_FAILURE"}
        },
        9
      ),
      event(
        "run.finished",
        %{
          "run_id" => "run",
          "command_id" => nil,
          "reconciliation_ref" => nil,
          "cleanup_grace_ms" => 5_000,
          "outcome" => "bound_reached",
          "bound" => "deadline",
          "observed" => 18_446_744_073_709_551_616,
          "declared_limit" => 1,
          "accounting_source" => nil
        },
        9
      )
    ]

    for invalid <- malformed do
      rejected = Delivery.event(active, invalid)
      assert Delivery.detached?(rejected)
      assert Delivery.cursor(rejected) == 7
      assert Delivery.pulled_cursor(rejected) == 8
      assert Delivery.usage(rejected) == Delivery.usage(active)
      assert rejected.active == active.active
      {:ok, _entry, joined} = Delivery.joined(rejected, reference)
      assert Delivery.cursor(joined) == 8
      assert Delivery.pulled_cursor(joined) == 8
      assert Delivery.usage(joined).durable == {0, 0}
      assert Delivery.next(joined) == :empty
      refute entry.frame =~ "PRIVATE"
    end
  end

  test "tool version at the enclosing string cap decodes and cap plus one refuses without releasing active credit" do
    at_cap = String.duplicate("1", 131_068) <> ".0.0"
    above_cap = String.duplicate("1", 131_069) <> ".0.0"
    assert byte_size(at_cap) == 131_072
    assert byte_size(above_cap) == 131_073
    assert Regex.match?(~r/\A[0-9]+\.[0-9]+\.[0-9]+\z/, at_cap)
    assert Regex.match?(~r/\A[0-9]+\.[0-9]+\.[0-9]+\z/, above_cap)

    assert {:ok, %{"tool_version" => ^at_cap}} =
             Frame.decode("{\"tool_version\":\"" <> at_cap <> "\"}", Frame.output_record_bytes())

    assert {:error, :string_too_large} =
             Frame.decode(
               "{\"tool_version\":\"" <> above_cap <> "\"}",
               Frame.output_record_bytes()
             )

    payload = %{
      "run_id" => "run",
      "turn_id" => "turn",
      "tool_call_id" => "call",
      "operation_id" => "operation",
      "tool_id" => "test.tool",
      "tool_version" => at_cap
    }

    queue = Delivery.event(Delivery.new("session", 7), event("tool.started", payload, 8))
    refute Delivery.detached?(queue)
    assert Delivery.cursor(queue) == 7
    assert Delivery.pulled_cursor(queue) == 8
    {:ok, entry} = Delivery.next(queue)
    assert byte_size(entry.frame) <= Frame.output_record_bytes()
    assert decode(entry.frame)["event"]["data"]["tool_version"] == at_cap
    reference = make_ref()
    {:ok, active} = Delivery.activate(queue, entry.token, reference)

    # Concept: the same active queue admits the boundary version at the next sequence.
    # Technical depth: this positive prerequisite rules out a full reservation or
    # stale cursor as the cause of the otherwise identical cap-plus-one refusal.
    control = Delivery.event(active, event("tool.started", payload, 9))
    refute Delivery.detached?(control)
    assert Delivery.pulled_cursor(control) == 9
    assert elem(Delivery.usage(control).durable, 0) == 2

    rejected =
      Delivery.event(
        active,
        event("tool.started", %{payload | "tool_version" => above_cap}, 9)
      )

    assert Delivery.detached?(rejected)
    assert Delivery.cursor(rejected) == 7
    assert Delivery.pulled_cursor(rejected) == 8
    assert Delivery.usage(rejected) == Delivery.usage(active)
    assert rejected.active == active.active
    assert Delivery.detachment(rejected)["event_cursor"] == "7"
    {:ok, joined_entry, joined} = Delivery.joined(rejected, reference)
    assert joined_entry.frame == entry.frame
    assert joined_entry.token == entry.token
    assert Delivery.cursor(joined) == 8
    assert Delivery.pulled_cursor(joined) == 8
    assert Delivery.usage(joined).durable == {0, 0}
    assert Delivery.next(joined) == :empty
  end

  test "both conversation families roundtrip the exact enclosing content cap and refuse the next raw byte while retaining active credit" do
    at_cap = String.duplicate("a", 98_304)
    above_cap = at_cap <> "a"
    expected_at_cap = String.duplicate("YWFh", 32_768)
    expected_above_cap = expected_at_cap <> "YQ"
    assert byte_size(at_cap) == 98_304
    assert byte_size(above_cap) == 98_305
    assert byte_size(expected_at_cap) == 131_072
    assert byte_size(expected_above_cap) == 131_074

    for {kind, identities} <- [
          {"user.message_appended", %{"command_id" => "command", "run_id" => "run"}},
          {"assistant.message_appended", %{"run_id" => "run", "turn_id" => "turn"}}
        ] do
      payload = Map.put(identities, "content", at_cap)
      queue = Delivery.event(Delivery.new("session", 7), event(kind, payload, 8))
      refute Delivery.detached?(queue), kind
      assert Delivery.cursor(queue) == 7
      assert Delivery.pulled_cursor(queue) == 8
      {:ok, entry} = Delivery.next(queue)
      assert byte_size(entry.frame) <= Frame.output_record_bytes()
      record = decode(entry.frame)
      assert record["event"]["data"]["content_b64"] == expected_at_cap
      refute Map.has_key?(record["event"]["data"], "content")
      assert {:ok, ^at_cap} = Wire.bytes(record["event"]["data"]["content_b64"], 98_304)

      oversized_record = put_in(record, ["event", "data", "content_b64"], expected_above_cap)
      {:ok, oversized_iodata} = Frame.encode(oversized_record)
      oversized_frame = IO.iodata_to_binary(oversized_iodata)
      assert byte_size(oversized_frame) <= Frame.output_record_bytes()

      assert {:error, :string_too_large} =
               Frame.decode(
                 String.trim_trailing(oversized_frame, "\n"),
                 Frame.output_record_bytes()
               )

      reference = make_ref()
      {:ok, active} = Delivery.activate(queue, entry.token, reference)

      # Concept: every non-content prerequisite admits from this same active queue.
      # Technical depth: the exact-cap next sequence proves reservation headroom
      # and valid identities before only the raw content changes to cap plus one.
      control = Delivery.event(active, event(kind, payload, 9))
      refute Delivery.detached?(control), kind
      assert Delivery.pulled_cursor(control) == 9
      assert elem(Delivery.usage(control).durable, 0) == 2

      rejected = Delivery.event(active, event(kind, %{payload | "content" => above_cap}, 9))
      assert Delivery.detached?(rejected), kind
      assert Delivery.cursor(rejected) == 7
      assert Delivery.pulled_cursor(rejected) == 8
      assert Delivery.usage(rejected) == Delivery.usage(active)
      assert rejected.active == active.active
      assert Delivery.detachment(rejected)["event_cursor"] == "7"
      {:ok, joined_entry, joined} = Delivery.joined(rejected, reference)
      assert joined_entry.frame == entry.frame
      assert joined_entry.token == entry.token
      assert Delivery.cursor(joined) == 8
      assert Delivery.pulled_cursor(joined) == 8
      assert Delivery.usage(joined).durable == {0, 0}
      assert Delivery.next(joined) == :empty
    end
  end

  defp current_payloads do
    codec_payloads(
      "configuration-projection.v1.json",
      "session.configured",
      &Configuration.decode_change/1,
      &(&1["scope"] == "configured_event")
    ) ++
      codec_payloads(
        "checkpoint-projection.v1.json",
        "context.compacted",
        &Checkpoint.decode_wire/1
      ) ++
      codec_payloads(
        "maintenance-view.v1.json",
        "context.maintenance_changed",
        &MaintenanceView.decode_wire/1
      ) ++
      codec_payloads(
        "standalone-compact-completion.v1.json",
        "context.compaction_finished",
        &CompactResult.decode_completion/1
      ) ++
      interaction_payloads() ++ outcome_payloads()
  end

  defp codec_payloads(file, kind, decoder, select \\ fn _ -> true end) do
    for vector <- vectors(file), is_nil(vector["error"]), select.(vector) do
      assert {:ok, native} = decoder.(vector["input"])
      {kind, native, vector["input"]}
    end
  end

  defp interaction_payloads do
    for {file, fixed} <- [
          {"model-question-requested.v1.json", "interaction.requested"},
          {"model-question-terminal.v1.json", nil},
          {"policy-requested.v1.json", "interaction.requested"},
          {"policy-terminal.v1.json", nil},
          {"policy-answer-admitted.v1.json", "interaction.answer_admitted"}
        ],
        vector <- vectors(file),
        is_nil(vector["error"]) do
      wire = vector["input"]
      kind = fixed || vector["event_kind"] || "interaction." <> wire["disposition"]
      assert {:ok, native} = InteractionEvent.decode(kind, wire)
      {kind, native, wire}
    end
  end

  defp outcome_payloads do
    for file <- ["chat-terminal-outcome.v1.json", "chat-terminal-context-failure.v2.json"],
        vector <- vectors(file),
        is_nil(vector["error"]) do
      wire = vector["input"]
      assert {:ok, native} = Outcome.decode_wire(wire)
      data = flat_outcome(native.details, wire["outcome"], "run")
      expected = flat_outcome(wire["details"], wire["outcome"], Wire.encode_identity("run"))
      {"run.finished", data, expected}
    end
  end

  defp flat_outcome(details, outcome, run) do
    selected =
      if outcome == "failed",
        do: Enum.reject(details, fn {_, value} -> is_nil(value) end) |> Map.new(),
        else: details

    Map.merge(
      %{"run_id" => run, "command_id" => nil, "reconciliation_ref" => nil, "outcome" => outcome},
      selected
    )
  end

  defp vectors(file),
    do:
      :loopex_protocol
      |> :code.priv_dir()
      |> Path.join("vectors/" <> file)
      |> File.read!()
      |> JSON.decode!()
      |> Map.fetch!("cases")

  defp event(kind, data, sequence),
    do: Map.merge(data, %{kind: kind, event_id: <<0, 255, 10>>, event_sequence: sequence})

  defp decode(frame) do
    assert {:ok, record} =
             Frame.decode(String.trim_trailing(frame, "\n"), Frame.output_record_bytes())

    record
  end
end
