defmodule LoopexDaemon.WireRecordsCurrentEventsTest do
  use ExUnit.Case, async: true

  alias LoopexDaemon.WireRecords
  alias LoopexProtocol.{Frame, Wire}

  alias LoopexProtocol.Session.{
    Checkpoint,
    CompactResult,
    Configuration,
    InteractionEvent,
    MaintenanceView,
    Outcome
  }

  test "complete current durable event sources reproduce every accepted codec vector" do
    for {kind, native, expected} <- current_payloads(),
        sequence <- [0, 18_446_744_073_709_551_615] do
      record = WireRecords.event(<<255, 0>>, event(kind, native, sequence))

      assert record == %{
               "type" => "event",
               "session_id" => "_wA",
               "event" => %{
                 "kind" => kind,
                 "event_id" => "AP8K",
                 "event_sequence" => Integer.to_string(sequence),
                 "data" => expected
               }
             },
             kind

      encoded = frame(record)

      assert {:ok, ^record} =
               Frame.decode(String.trim_trailing(encoded, "\n"), Frame.output_record_bytes())
    end
  end

  test "closed current event sources refuse private members and malformed captures whole" do
    for {kind, native, _wire} <- current_payloads() do
      for invalid <- [
            Map.put(native, "private_capture", "PRIVATE_EVENT_CANARY"),
            Map.put(native, :permit, self()),
            Map.put(native, "owner_handle", fn -> :private end),
            Map.put(native, :__struct__, __MODULE__)
          ] do
        assert :error = WireRecords.event("session", event(kind, invalid, 8)), kind
      end

      optional =
        if kind in ~w(interaction.resolved interaction.expired interaction.cancelled) and
             not Map.has_key?(native, "producer") do
          ~w(reason choice_id)
        else
          []
        end

      for field <- Map.keys(native) -- optional do
        assert :error = WireRecords.event("session", event(kind, Map.delete(native, field), 8)),
               "#{kind}: #{field}"
      end
    end
  end

  test "ordinary conversation tool artifact and resolution fields retain exact bytes and quantities" do
    for {kind, native, expected} <- ordinary_payloads() do
      record = WireRecords.event("session", event(kind, native, 1))
      assert record["event"]["data"] == expected, kind
      assert {:ok, _} = Frame.encode(record)

      assert :error =
               WireRecords.event(
                 "session",
                 event(kind, Map.put(native, "private", "PRIVATE_EVENT_CANARY"), 1)
               )

      for field <- Map.keys(native) do
        assert :error = WireRecords.event("session", event(kind, Map.delete(native, field), 1)),
               "#{kind}: #{field}"
      end
    end

    exact_version = String.duplicate("1", 131_068) <> ".0.0"
    over_version = String.duplicate("1", 131_069) <> ".0.0"
    assert byte_size(exact_version) == 131_072
    assert byte_size(over_version) == 131_073

    native = %{
      "run_id" => "run",
      "turn_id" => "turn",
      "tool_call_id" => "call",
      "operation_id" => "operation",
      "tool_id" => "example.write",
      "tool_version" => exact_version
    }

    record = WireRecords.event("session", event("tool.started", native, 1))
    assert record["event"]["data"]["tool_version"] == exact_version
    encoded = frame(record)

    assert {:ok, ^record} =
             Frame.decode(String.trim_trailing(encoded, "\n"), Frame.output_record_bytes())

    assert :error =
             WireRecords.event(
               "session",
               event("tool.started", Map.put(native, "tool_version", over_version), 1)
             )

    over_record = put_in(record, ["event", "data", "tool_version"], over_version)
    over_encoded = frame(over_record)

    assert {:error, :string_too_large} =
             Frame.decode(String.trim_trailing(over_encoded, "\n"), Frame.output_record_bytes())

    exact_content = String.duplicate("x", 98_304)
    over_content = String.duplicate("x", 98_305)
    exact_content_b64 = Wire.encode_bytes(exact_content)
    over_content_b64 = Wire.encode_bytes(over_content)
    assert byte_size(exact_content) == 98_304
    assert byte_size(over_content) == 98_305
    assert byte_size(exact_content_b64) == 131_072
    assert byte_size(over_content_b64) == 131_074

    for {kind, fields} <- [
          {"user.message_appended", %{"command_id" => "command", "run_id" => "run"}},
          {"assistant.message_appended", %{"run_id" => "run", "turn_id" => "turn"}}
        ] do
      native = Map.put(fields, "content", exact_content)
      record = WireRecords.event("session", event(kind, native, 1))
      assert record["event"]["data"]["content_b64"] == exact_content_b64
      refute Map.has_key?(record["event"]["data"], "content")
      encoded = frame(record)

      assert {:ok, ^record} =
               Frame.decode(String.trim_trailing(encoded, "\n"), Frame.output_record_bytes())

      assert :error =
               WireRecords.event(
                 "session",
                 event(kind, Map.put(native, "content", over_content), 1)
               )

      over_record = put_in(record, ["event", "data", "content_b64"], over_content_b64)
      over_encoded = frame(over_record)

      assert {:error, :string_too_large} =
               Frame.decode(String.trim_trailing(over_encoded, "\n"), Frame.output_record_bytes())
    end
  end

  test "malformed native envelopes unions scalars and nested artifacts never become records" do
    valid = event("run.started", %{"command_id" => "command", "run_id" => "run"}, 9)
    artifact = artifact()

    tool = %{
      "run_id" => "run",
      "turn_id" => "turn",
      "tool_call_id" => "call",
      "operation_id" => "operation",
      "tool_id" => "example.write",
      "outcome" => "completed",
      "reason" => nil,
      "artifacts" => [artifact]
    }

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
        Map.merge(Map.drop(tool, ~w(outcome reason artifacts)), %{
          "tool_id" => "PRIVATE\nTOOL",
          "tool_version" => "1.0.0"
        }),
        9
      ),
      event(
        "tool.started",
        Map.merge(Map.drop(tool, ~w(outcome reason artifacts)), %{
          "tool_version" => "1.0.0-private"
        }),
        9
      ),
      event("tool.finished", Map.put(tool, "reason", "PRIVATE_REASON"), 9),
      event("tool.finished", Map.put(tool, "outcome", "private"), 9),
      event(
        "steer.resolved",
        %{"command_id" => "cmd", "run_id" => "run", "disposition" => "private", "reason" => nil},
        9
      ),
      event(
        "follow_up.resolved",
        %{
          "command_id" => "cmd",
          "run_id" => "run",
          "disposition" => "cancelled",
          "reason" => "private"
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

    for invalid <- malformed, do: assert(:error = WireRecords.event("session", invalid))

    for session <- [nil, "", String.duplicate("s", 257), self()] do
      assert :error = WireRecords.event(session, valid)
    end

    for invalid <- [
          Map.put(artifact, "private", "PRIVATE_ARTIFACT_CANARY"),
          Map.put(artifact, "size", -1),
          Map.put(artifact, "size", 18_446_744_073_709_551_616),
          Map.put(artifact, "digest", String.duplicate("A", 64)),
          Map.put(artifact, "locator", "PRIVATE\nLOCATOR"),
          Map.put(artifact, "role", "private"),
          Map.put(artifact, "use_locator", "use:mismatch")
        ] do
      assert :error =
               WireRecords.event(
                 "session",
                 event("tool.finished", Map.put(tool, "artifacts", [invalid]), 9)
               )
    end
  end

  test "steer reason retains null empty UTF-8 and the exact inherited byte ceiling" do
    native = %{
      "command_id" => "command",
      "run_id" => "run",
      "disposition" => "unapplied",
      "reason" => nil
    }

    for reason <- [nil, "", "é", String.duplicate("a", 131_072)] do
      record =
        WireRecords.event(
          "session",
          event("steer.resolved", Map.put(native, "reason", reason), 1)
        )

      assert record["event"]["data"]["reason"] == reason
    end

    for reason <- [<<255>>, String.duplicate("a", 131_073), 1] do
      assert :error =
               WireRecords.event(
                 "session",
                 event("steer.resolved", Map.put(native, "reason", reason), 1)
               )
    end
  end

  defp ordinary_payloads do
    id = <<0, 255, 10>>

    ids = %{
      "run_id" => id,
      "turn_id" => id,
      "tool_call_id" => id,
      "operation_id" => id,
      "tool_id" => "example.write"
    }

    cases = [
      {"user.message_appended",
       %{"command_id" => id, "run_id" => id, "content" => <<255, 0, 10>>}},
      {"assistant.message_appended",
       %{"run_id" => id, "turn_id" => id, "content" => <<255, 0, 10>>}},
      {"run.started", %{"command_id" => id, "run_id" => id}},
      {"tool.started", Map.put(ids, "tool_version", "1.2.3")},
      {"tool.finished",
       Map.merge(ids, %{"outcome" => "completed", "reason" => nil, "artifacts" => [artifact()]})},
      {"steer.resolved",
       %{
         "command_id" => id,
         "run_id" => id,
         "disposition" => "unapplied",
         "reason" => "run_terminal"
       }},
      {"follow_up.resolved",
       %{"command_id" => id, "run_id" => id, "disposition" => "cancelled", "reason" => "aborted"}},
      {"session.settled", %{"run_id" => id}}
    ]

    for {kind, native} <- cases do
      expected =
        Map.new(native, fn
          {"content", _} ->
            {"content_b64", "_wAK"}

          {"artifacts", [reference]} ->
            {"artifacts", [Map.put(reference, "size", "18446744073709551615")]}

          {key, _value} when key in ~w(command_id run_id turn_id tool_call_id operation_id) ->
            {key, "AP8K"}

          pair ->
            pair
        end)

      {kind, native, expected}
    end
  end

  defp artifact do
    %{
      "digest" => String.duplicate("a", 64),
      "size" => 18_446_744_073_709_551_615,
      "locator" => "object:opaque",
      "media_type" => "text/plain",
      "role" => "tool_output",
      "use_canonicalization_version" => "loopex.canonical.v1",
      "use_digest" => String.duplicate("b", 64),
      "use_locator" => "use:" <> String.duplicate("b", 64)
    }
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

  defp frame(record) do
    assert {:ok, encoded} = Frame.encode(record)
    IO.iodata_to_binary(encoded)
  end
end
