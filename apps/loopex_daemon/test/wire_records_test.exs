defmodule LoopexDaemon.WireRecordsTest do
  use ExUnit.Case, async: true

  alias LoopexDaemon.WireRecords
  alias LoopexProtocol.Frame

  # Concept: what the daemon writes when it stops is byte for byte the
  # generation's literal vector for that reason.
  test "every daemon.stopping vector is exactly the record the daemon writes" do
    vectors =
      :loopex_protocol
      |> Application.app_dir("priv/vectors/loopex-experimental-4.json")
      |> File.read!()
      |> JSON.decode!()
      |> Map.fetch!("cases")
      |> Enum.filter(&String.starts_with?(&1["id"], "daemon_stopping_"))

    assert length(vectors) == 14

    for %{"raw_hex" => hex} <- vectors do
      bytes = Base.decode16!(hex, case: :lower)
      %{"reason" => reason} = JSON.decode!(bytes)
      assert encode(WireRecords.daemon_stopping(reason)) == bytes
    end
  end

  test "control records match the current daemon vectors exactly" do
    epoch = "epoch"

    assert encode(WireRecords.control_acquired("acquire-1", epoch, 30_000, false)) ==
             ~s({"method":"session.acquire_control","request_id":"acquire-1","result":{"expires_in_ms":"30000","writer_epoch":"ZXBvY2g"},"type":"result"}\n)

    assert encode(WireRecords.control_acquired("acquire-2", epoch, 30_000, true)) ==
             ~s({"method":"session.acquire_control","request_id":"acquire-2","result":{"expires_in_ms":"30000","renewed":true,"writer_epoch":"ZXBvY2g"},"type":"result"}\n)

    assert encode(WireRecords.control_released("release-1")) ==
             ~s({"method":"session.release_control","request_id":"release-1","result":{"released":true},"type":"result"}\n)

    assert encode(WireRecords.control_error("error-1", "control_held")) ==
             ~s({"code":"control_held","message":"control held.","request_id":"error-1","type":"error"}\n)

    assert encode(WireRecords.control_error("error-1", "control_not_held")) ==
             ~s({"code":"control_not_held","message":"control is not held by this connection","request_id":"error-1","type":"error"}\n)

    assert encode(WireRecords.control_error("error-1", "control_pending")) ==
             ~s({"code":"control_pending","message":"control pending.","request_id":"error-1","type":"error"}\n)
  end

  test "admitted artifact failures preserve only the closed reason and cleanup" do
    for reason <- [
          :invalid_artifact_request,
          :invalid_open_context,
          :reservation_required,
          :reservation_conflict,
          :unknown_artifact_use,
          :artifact_use_mismatch,
          :artifact_integrity_failed,
          :artifact_digest_mismatch,
          :unknown_artifact,
          :artifact_too_large,
          :invalid_window,
          :open_deadline_exhausted,
          :open_work_budget_exhausted,
          :transfer_limit_reached,
          :transfers_unavailable,
          :artifact_unreadable,
          :cancelled
        ],
        cleanup <- [:proved, :unproved] do
      assert WireRecords.transfer_refused("artifact-open", %{reason: reason, cleanup: cleanup}) ==
               %{
                 "type" => "error",
                 "request_id" => "artifact-open",
                 "code" => "transfer_refused",
                 "reason" => Atom.to_string(reason),
                 "cleanup" => Atom.to_string(cleanup),
                 "message" => "the transfer was refused"
               }
    end
  end

  test "malformed artifact failure maps cannot publish cleanup or private evidence" do
    valid = %{reason: :cancelled, cleanup: :unproved}

    for failure <- [
          Map.delete(valid, :reason),
          Map.delete(valid, :cleanup),
          %{valid | reason: :private_adapter_exception},
          %{valid | cleanup: "proved"},
          %{valid | cleanup: nil},
          Map.put(valid, :receipt_ref, "private-receipt"),
          Map.put(valid, :work, %{source_read_bytes: 0}),
          Map.put(valid, :owner, self()),
          Map.put(valid, :__struct__, __MODULE__)
        ] do
      assert WireRecords.transfer_refused("artifact-open", failure) ==
               WireRecords.request_error("artifact-open", "internal_failure")
    end
  end

  test "non-admitted artifact refusals emit only current owning atom causes" do
    for reason <- [
          :attachment_required,
          :invalid_attachment,
          :stale_attachment,
          :invalid_artifact_request,
          :artifact_transfer_unsupported,
          :transfer_limit_reached,
          :open_work_budget_exhausted,
          :transfers_unavailable,
          :unknown_transfer,
          :invalid_chunk_length,
          :read_deadline_exhausted,
          :artifact_unreadable,
          :runtime_unavailable,
          :cleanup_unproved
        ] do
      assert WireRecords.transfer_refused("artifact-operation", reason) == %{
               "type" => "error",
               "request_id" => "artifact-operation",
               "code" => "transfer_refused",
               "reason" => Atom.to_string(reason),
               "message" => "the transfer was refused"
             }
    end
  end

  test "unknown superseded or admitted-only atom causes cannot cross the wire" do
    for reason <- [
          :cancelled,
          :open_deadline_exhausted,
          :artifact_integrity_failed,
          :object_missing,
          :open_deadline_exceeded,
          :private_adapter_exception,
          "cancelled",
          nil,
          self()
        ] do
      assert WireRecords.transfer_refused("artifact-operation", reason) ==
               WireRecords.request_error("artifact-operation", "internal_failure")
    end
  end

  defp encode(record) do
    assert {:ok, encoded} = Frame.encode(record)
    IO.iodata_to_binary(encoded)
  end

  test "maintenance events share the closed codec with exact quantities and opaque identities" do
    path = Path.join(:code.priv_dir(:loopex_protocol), "vectors/maintenance-view.v1.json")
    cases = JSON.decode!(File.read!(path))["cases"]

    for name <- [
          "inactive",
          "run-captured-null-deadline",
          "compact-captured-ceilings",
          "run-unbounded-bounds.token_budget"
        ] do
      wire = Enum.find(cases, &(&1["name"] == name))["input"]
      assert {:ok, native} = LoopexProtocol.Session.MaintenanceView.decode_wire(wire)

      event =
        Map.merge(native, %{
          kind: "context.maintenance_changed",
          event_id: "view",
          event_sequence: 1
        })

      record = WireRecords.event("session", event)
      assert record["event"]["data"] == wire
      assert record["event"]["kind"] == "context.maintenance_changed"

      assert {:ok, ^native} =
               LoopexProtocol.Session.MaintenanceView.decode_wire(record["event"]["data"])
    end
  end

  test "both checkpoint owner kinds preserve opaque bytes in the daemon envelope" do
    path = Path.join(:code.priv_dir(:loopex_protocol), "vectors/checkpoint-projection.v1.json")
    cases = JSON.decode!(File.read!(path))["cases"]
    complete = Enum.find(cases, &(&1["name"] == "run-covered-prefix"))["input"]

    for kind <- ["run", "compact"] do
      expected = Map.put(complete, "owner", %{"kind" => kind, "id" => "AP8K"})
      assert {:ok, native} = LoopexProtocol.Session.Checkpoint.decode_wire(expected)
      assert native["owner"] == %{"kind" => kind, "id" => <<0, 255, 10>>}

      event =
        Map.merge(native, %{
          kind: "context.compacted",
          event_id: "event",
          event_sequence: 1
        })

      record = WireRecords.event("session", event)
      assert record["event"]["data"] == expected
      assert record["event"]["data"]["owner"] == %{"kind" => kind, "id" => "AP8K"}
      assert record["event"]["event_sequence"] == "1"
      assert {:ok, encoded} = Frame.encode(record)
      assert {:ok, ^record} =
               Frame.decode(
                 IO.iodata_to_binary(encoded) |> String.trim_trailing("\n"),
                 Frame.output_record_bytes()
               )
    end
  end

  test "completed compaction events preserve each closed result and refuse private data" do
    path =
      Path.join(:code.priv_dir(:loopex_protocol), "vectors/standalone-compact-completion.v1.json")

    cases = JSON.decode!(File.read!(path))["cases"]

    for vector <- cases, is_nil(vector["error"]) do
      wire = vector["input"]
      assert {:ok, native} = LoopexProtocol.Session.CompactResult.decode_completion(wire)

      event =
        Map.merge(native, %{
          kind: "context.compaction_finished",
          event_id: "finished",
          event_sequence: 1
        })

      record = WireRecords.event("session", event)
      assert record["event"]["data"] == wire
      assert {:ok, _} = Frame.encode(record)

      assert :error =
               WireRecords.event("session", Map.put(event, "source", "PRIVATE_COMPLETION_CANARY"))
    end
  end

  test "compaction activity matches the closed foreground envelope for both owners and u64 edges" do
    for kind <- ["run", "compact"], base <- [0, 18_446_744_073_709_551_615] do
      item = compaction_item(kind, base)
      record = WireRecords.progress(<<255, 0>>, item)

      assert record == %{
               "type" => "progress",
               "session_id" => "_wA",
               "progress" => %{
                 "kind" => "context.compaction_progress",
                 "episode_id" => "AP8K",
                 "owner" => %{"kind" => kind, "id" => "_wCA"},
                 "stream_domain_id" => "MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY",
                 "progress_sequence" => "0",
                 "base_event_sequence" => Integer.to_string(base)
               }
             }

      assert {:ok, ^item} =
               LoopexProtocol.Session.CompactionProgress.decode_wire(record["progress"])

      assert {:ok, encoded} = Frame.encode(record)

      assert {:ok, ^record} =
               Frame.decode(
                 IO.iodata_to_binary(encoded) |> String.trim_trailing("\n"),
                 Frame.output_record_bytes()
               )
    end
  end

  test "malformed and oversized compaction items refuse whole without serializing private values" do
    item = compaction_item("run", 0)

    for invalid <- [
          Map.put(item, :summary, "PRIVATE_CANARY"),
          Map.put(item, :permit, fn -> :private end),
          Map.delete(item, :episode_id),
          Map.put(item, :owner, %{"kind" => "run", "id" => nil}),
          Map.put(item, :stream_domain_id, String.duplicate("A", 32)),
          Map.put(item, :episode_id, :binary.copy(<<255>>, 65_537)),
          Map.put(item, :base_event_sequence, 18_446_744_073_709_551_616),
          Map.put(item, :__struct__, __MODULE__),
          %{"kind" => "context.compaction_progress", "summary" => fn -> :private end}
        ] do
      assert :error = WireRecords.progress("session", invalid)
    end
  end

  test "maximum valid compaction identities fit the existing individual frame ceiling" do
    bytes = :binary.copy(<<255>>, 65_536)

    item = %{
      compaction_item("compact", 0)
      | episode_id: bytes,
        owner: %{"kind" => "compact", "id" => bytes}
    }

    record = WireRecords.progress("session", item)
    assert {:ok, encoded} = Frame.encode(record)
    assert IO.iodata_length(encoded) < Frame.output_record_bytes()

    assert {:ok, ^item} =
             LoopexProtocol.Session.CompactionProgress.decode_wire(record["progress"])
  end

  test "ordinary progress encodes all six native kinds with exact identities and u64 edges" do
    for quantity <- [0, 18_446_744_073_709_551_615],
        {item, expected} <- ordinary_cases(quantity) do
      assert_ordinary_record(item, expected)
    end
  end

  test "tool call progress preserves every permitted nullable combination" do
    for id <- [nil, <<0, 255, 128>>], name <- [nil, "tool"], fragment <- [nil, "{}"] do
      item = %{
        text_item("unused", 0, 0)
        | kind: :tool_call_delta
      }

      item =
        item
        |> Map.drop([:content_index, :text])
        |> Map.merge(%{
          call_index: 0,
          tool_call_id: id,
          name: name,
          arguments_fragment: fragment
        })

      expected = %{
        "kind" => "tool_call_delta",
        "turn_id" => "AP-A",
        "stream_domain_id" => "MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY",
        "model_sequence" => "0",
        "base_event_sequence" => "0",
        "call_index" => 0,
        "tool_call_id" => if(is_nil(id), do: nil, else: "AP-A"),
        "name" => name,
        "arguments_fragment" => fragment
      }

      assert_ordinary_record(item, expected)
    end
  end

  test "ordinary progress refuses private fields and malformed native members whole" do
    for {item, _expected} <- ordinary_cases(0) do
      for invalid <- [
            Map.put(item, :credential, "PRIVATE_PROGRESS_CANARY"),
            Map.put(item, :permit, fn -> :private end),
            Map.put(item, :owner_pid, self()),
            Map.put(item, :monitor, make_ref()),
            Map.put(item, :__struct__, __MODULE__),
            Map.put(item, :turn_id, nil),
            Map.put(item, :turn_id, ""),
            Map.put(item, :turn_id, :binary.copy(<<255>>, 65_537)),
            Map.put(item, :stream_domain_id, String.duplicate("A", 32)),
            Map.put(item, :stream_domain_id, String.duplicate("a", 31)),
            Map.put(item, :kind, Atom.to_string(item.kind)),
            Map.new(item, fn {key, value} -> {Atom.to_string(key), value} end)
          ] do
        assert_ordinary_refusal(invalid)
      end

      for field <- Map.keys(item), do: assert_ordinary_refusal(Map.delete(item, field))

      if Map.has_key?(item, :tool_call_id) do
        for value <- ["", :binary.copy(<<255>>, 65_537), fn -> :private end] do
          assert_ordinary_refusal(Map.put(item, :tool_call_id, value))
        end

        if item.kind != :tool_call_delta,
          do: assert_ordinary_refusal(Map.put(item, :tool_call_id, nil))
      end

      for field <- [
            :model_sequence,
            :progress_sequence,
            :base_event_sequence,
            :byte_offset,
            :delta_count,
            :progress_count
          ],
          Map.has_key?(item, field),
          invalid <- [nil, -1, 18_446_744_073_709_551_616, "0", 0.0] do
        assert_ordinary_refusal(Map.put(item, field, invalid))
      end

      for field <- [:content_index, :call_index],
          Map.has_key?(item, field),
          invalid <- [nil, -1, 9_007_199_254_740_992, 0.0] do
        assert_ordinary_refusal(Map.put(item, field, invalid))
      end

      for field <- [:text, :name, :arguments_fragment, :chunk],
          Map.has_key?(item, field),
          invalid <- [<<255>>, "\e[31mprivate", fn -> :private end] do
        assert_ordinary_refusal(Map.put(item, field, invalid))
      end
    end

    for invalid <- [nil, [], fn -> :private end, %{kind: :unknown}] do
      assert_ordinary_refusal(invalid)
    end

    [{tool, _}] =
      Enum.filter(ordinary_cases(0), fn {item, _} ->
        item.kind == :tool_progress and item.stream == "stdout"
      end)

    for invalid <- [
          Map.put(tool, :stream, "other"),
          Map.put(tool, :tool_call_id, nil),
          Map.put(tool, :tool_call_id, ""),
          Map.put(tool, :chunk, nil)
        ] do
      assert_ordinary_refusal(invalid)
    end

    for {item, _} <- ordinary_cases(0),
        Map.has_key?(item, :disposition),
        invalid <- [nil, "complete", :other] do
      assert_ordinary_refusal(Map.put(item, :disposition, invalid))
    end
  end

  test "ordinary payload ceilings include model indices and all tool call fragments" do
    text = String.duplicate("x", 65_536 - byte_size(:erlang.term_to_binary(0)))
    item = text_item(text, 0, 0)

    expected = %{
      "kind" => "text_delta",
      "turn_id" => "AP-A",
      "stream_domain_id" => "MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY",
      "model_sequence" => "0",
      "base_event_sequence" => "0",
      "content_index" => 0,
      "text" => text
    }

    assert_ordinary_record(item, expected)
    assert_ordinary_record(%{item | text: ""}, Map.put(expected, "text", ""))
    assert_ordinary_refusal(Map.put(item, :text, text <> "x"))

    [{call, _}] =
      Enum.filter(ordinary_cases(0), fn {item, _} -> item.kind == :tool_call_delta end)

    assert_ordinary_refusal(%{
      call
      | tool_call_id: String.duplicate("i", 32_768),
        name: String.duplicate("n", 32_768),
        arguments_fragment: ""
    })

    [{tool, expected}] =
      Enum.filter(ordinary_cases(0), fn {item, _} ->
        item.kind == :tool_progress and item.stream == "stdout"
      end)

    chunk = String.duplicate("x", 65_536)

    assert_ordinary_record(
      %{tool | chunk: chunk},
      Map.put(expected, "chunk_b64", Base.url_encode64(chunk, padding: false))
    )

    assert_ordinary_record(%{tool | chunk: ""}, Map.put(expected, "chunk_b64", ""))
    assert_ordinary_refusal(%{tool | chunk: chunk <> "x"})
  end

  test "maximum opaque ordinary identities retain bytes and obey existing encoded limits" do
    bytes = :binary.copy(<<255>>, 65_536)

    [{tool, expected}] =
      Enum.filter(ordinary_cases(0), fn {item, _} ->
        item.kind == :tool_progress and item.stream == "stdout"
      end)

    item = %{tool | turn_id: bytes, tool_call_id: bytes}

    expected =
      Map.merge(expected, %{
        "turn_id" => Base.url_encode64(bytes, padding: false),
        "tool_call_id" => Base.url_encode64(bytes, padding: false)
      })

    record = assert_ordinary_record(item, expected)
    assert {:ok, ^bytes} = LoopexProtocol.Wire.identity(record["progress"]["turn_id"])
    assert {:ok, ^bytes} = LoopexProtocol.Wire.identity(record["progress"]["tool_call_id"])

    for {closure, wire} <- ordinary_cases(0), Map.has_key?(closure, :disposition) do
      closure = Map.put(closure, :turn_id, bytes)
      wire = Map.put(wire, "turn_id", Base.url_encode64(bytes, padding: false))

      {closure, wire} =
        if Map.has_key?(closure, :tool_call_id) do
          {Map.put(closure, :tool_call_id, bytes),
           Map.put(wire, "tool_call_id", Base.url_encode64(bytes, padding: false))}
        else
          {closure, wire}
        end

      assert_ordinary_record(closure, wire)
    end

    assert_ordinary_refusal(%{item | turn_id: bytes <> <<255>>})
    assert_ordinary_refusal(%{item | tool_call_id: bytes <> <<255>>})
    assert {:ok, encoded} = Frame.encode(record)
    assert IO.iodata_length(encoded) < Frame.output_record_bytes()
    session = :binary.copy(<<255>>, 256)
    session_record = WireRecords.progress(session, tool)
    assert {:ok, ^session} = LoopexProtocol.Wire.session_identity(session_record["session_id"])
    assert :error = WireRecords.progress(:binary.copy(<<255>>, 257), tool)
  end

  defp text_item(text, sequence, base) do
    %{
      kind: :text_delta,
      turn_id: <<0, 255, 128>>,
      stream_domain_id: "0123456789abcdef0123456789abcdef",
      model_sequence: sequence,
      base_event_sequence: base,
      content_index: 0,
      text: text
    }
  end

  defp ordinary_cases(quantity) do
    anchor = %{
      turn_id: <<0, 255, 128>>,
      stream_domain_id: "0123456789abcdef0123456789abcdef",
      base_event_sequence: quantity
    }

    wire_anchor = %{
      "turn_id" => "AP-A",
      "stream_domain_id" => "MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY",
      "base_event_sequence" => Integer.to_string(quantity)
    }

    models =
      for kind <- [:text_delta, :reasoning_delta] do
        item =
          Map.merge(anchor, %{
            kind: kind,
            model_sequence: quantity,
            content_index: 9_007_199_254_740_991,
            text: "summary\tline\n"
          })

        expected =
          Map.merge(wire_anchor, %{
            "kind" => Atom.to_string(kind),
            "model_sequence" => Integer.to_string(quantity),
            "content_index" => 9_007_199_254_740_991,
            "text" => "summary\tline\n"
          })

        {item, expected}
      end

    call = {
      Map.merge(anchor, %{
        kind: :tool_call_delta,
        model_sequence: quantity,
        call_index: 9_007_199_254_740_991,
        tool_call_id: <<0, 255, 128>>,
        name: "tool",
        arguments_fragment: "{}"
      }),
      Map.merge(wire_anchor, %{
        "kind" => "tool_call_delta",
        "model_sequence" => Integer.to_string(quantity),
        "call_index" => 9_007_199_254_740_991,
        "tool_call_id" => "AP-A",
        "name" => "tool",
        "arguments_fragment" => "{}"
      })
    }

    tools =
      for stream <- ["stdout", "stderr", "progress"] do
        item =
          Map.merge(anchor, %{
            kind: :tool_progress,
            tool_call_id: <<255, 0, 128>>,
            progress_sequence: quantity,
            byte_offset: quantity,
            stream: stream,
            chunk: "chunk\t\n"
          })

        expected =
          Map.merge(wire_anchor, %{
            "kind" => "tool_progress",
            "tool_call_id" => "_wCA",
            "progress_sequence" => Integer.to_string(quantity),
            "byte_offset" => Integer.to_string(quantity),
            "stream" => stream,
            "chunk_b64" => "Y2h1bmsJCg"
          })

        {item, expected}
      end

    closures =
      for disposition <- [:complete, :abandoned],
          kind <- [:model_stream_closed, :tool_stream_closed] do
        item = Map.merge(anchor, %{kind: kind, disposition: disposition})

        expected =
          Map.merge(wire_anchor, %{
            "kind" => Atom.to_string(kind),
            "disposition" => Atom.to_string(disposition)
          })

        if kind == :model_stream_closed do
          {Map.put(item, :delta_count, quantity),
           Map.put(expected, "delta_count", Integer.to_string(quantity))}
        else
          {Map.merge(item, %{tool_call_id: <<255, 0, 128>>, progress_count: quantity}),
           Map.merge(expected, %{
             "tool_call_id" => "_wCA",
             "progress_count" => Integer.to_string(quantity)
           })}
        end
      end

    models ++ [call] ++ tools ++ closures
  end

  defp assert_ordinary_record(item, expected) do
    record = WireRecords.progress(<<255, 0>>, item)
    assert record == %{"type" => "progress", "session_id" => "_wA", "progress" => expected}
    assert {:ok, encoded} = Frame.encode(record)

    assert {:ok, ^record} =
             Frame.decode(
               IO.iodata_to_binary(encoded) |> String.trim_trailing("\n"),
               Frame.output_record_bytes()
             )

    record
  end

  defp assert_ordinary_refusal(item), do: assert(:error == WireRecords.progress("session", item))

  defp compaction_item(kind, base) do
    %{
      kind: "context.compaction_progress",
      episode_id: <<0, 255, 10>>,
      owner: %{"kind" => kind, "id" => <<255, 0, 128>>},
      stream_domain_id: "0123456789abcdef0123456789abcdef",
      progress_sequence: 0,
      base_event_sequence: base
    }
  end
end
