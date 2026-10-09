Code.require_file("support/foreground_output_fixture.txt", __DIR__)

defmodule Loopex.AppServer.ForegroundOutputLifecycleTest do
  @moduledoc """
  ## Concept

  Foreground output retains capacity and attachment custody until actual joins.
  A blocked stdout does not turn EOF into an abort or let output pressure reach
  a facade without a reply reservation.

  ## Technical depth

  Queue transition cases explicitly simulate joins and claim no OS evidence.
  Separate subprocess cases drive the real inherited FIFO, actual Store and
  native sink, observe bounded actor metadata, and require owner/writer DOWN.
  A stopped real leader creates WRITTEN without JOINED; no acknowledgement or
  process-table answer is fabricated. The original 30 s request and 5+5 s
  output limits remain unchanged, with the existing 1 s fixture join grace.
  """
  use ExUnit.Case, async: false
  alias Loopex.AppServer.Delivery
  alias Loopex.AppServer.ForegroundOutputHarness, as: Harness
  alias LoopexProtocol.{Frame, Session, Wire}

  @moduletag timeout: 60_000

  test "two maximum reservations occupy the byte budget before any reply is encoded" do
    queue = Delivery.new(nil, 0)
    {:ok, first, queue} = Delivery.reserve(queue)
    {:ok, second, queue} = Delivery.reserve(queue)
    assert Delivery.usage(queue).durable == {2, 4_194_304}
    assert Delivery.reserve(queue) == :full
    {:ok, queue} = Delivery.commit(queue, second, %{"request_id" => "second", "type" => "result"})
    assert Delivery.next(queue) == :empty
    {:ok, queue} = Delivery.commit(queue, first, %{"request_id" => "first", "type" => "result"})
    {:ok, entry} = Delivery.next(queue)
    assert decode(entry.frame)["request_id"] == "first"
    reference = make_ref()
    {:ok, active} = Delivery.activate(queue, entry.token, reference)
    assert Delivery.usage(active) == Delivery.usage(queue)
    {:ok, _entry, queue} = Delivery.joined(active, reference)
    {:ok, next} = Delivery.next(queue)
    assert decode(next.frame)["request_id"] == "second"
  end

  test "all64 durable slots include the active frame and only its exact join reopens one" do
    queue =
      Enum.reduce(1..64, Delivery.new("session", 0), fn sequence, queue ->
        Delivery.event(queue, event(sequence))
      end)

    {:ok, entry} = Delivery.next(queue)
    reference = make_ref()
    {:ok, active} = Delivery.activate(queue, entry.token, reference)
    assert elem(Delivery.usage(active).durable, 0) == 64
    assert Delivery.reserve(active) == :full
    assert Delivery.cursor(active) == 0
    assert Delivery.pulled_cursor(active) == 64
    assert {:error, :stale_completion, ^active} = Delivery.joined(active, make_ref())
    {:ok, _entry, joined} = Delivery.joined(active, reference)
    assert Delivery.cursor(joined) == 1
    assert {:ok, _reservation, reopened} = Delivery.reserve(joined)
    assert elem(Delivery.usage(reopened).durable, 0) == 64
  end

  test "all32 transient slots retain their active charge without moving the emitted cursor" do
    queue =
      Enum.reduce(1..32, Delivery.new("session", 7), fn _, queue ->
        Delivery.progress(queue, text_item("x"))
      end)

    {:ok, entry} = Delivery.next(queue)
    reference = make_ref()
    {:ok, active} = Delivery.activate(queue, entry.token, reference)
    assert elem(Delivery.usage(active).progress, 0) == 32
    assert Delivery.progress(active, text_item("overflow")) == active
    {:ok, _entry, joined} = Delivery.joined(active, reference)
    assert Delivery.cursor(joined) == 7
    assert elem(Delivery.usage(joined).progress, 0) == 31
    assert elem(Delivery.usage(Delivery.progress(joined, text_item("new"))).progress, 0) == 32
  end

  test "an old incarnation's completed event cannot advance a fresh snapshot baseline" do
    queue = Delivery.new("old", 3) |> Delivery.event(event(4))
    {:ok, entry} = Delivery.next(queue)
    reference = make_ref()
    {:ok, active} = Delivery.activate(queue, entry.token, reference)
    fresh = Delivery.attachment(active, "new", 9, {"attachment", "incarnation"})
    {:ok, _old, joined} = Delivery.joined(fresh, reference)
    assert Delivery.cursor(joined) == 0
    refute Delivery.ready?(joined)
    {:ok, reservation, reserved} = Delivery.reserve(joined)

    {:ok, snapshot} =
      Delivery.commit(reserved, reservation, %{"type" => "snapshot"}, %{
        incarnation: {"attachment", "incarnation"},
        baseline: 9
      })

    {:ok, next} = Delivery.next(snapshot)
    next_ref = make_ref()
    {:ok, active} = Delivery.activate(snapshot, next.token, next_ref)
    {:ok, _snapshot, joined} = Delivery.joined(active, next_ref)
    assert Delivery.ready?(joined)
    assert Delivery.cursor(joined) == 9
  end

  test "write failure retains the previously joined cursor and progress discards return the exact leases" do
    lease = {make_ref(), 0, make_ref()}
    queue = Delivery.new("session", 7) |> Delivery.progress(text_item("delta"), lease)
    {retired, empty} = Delivery.discard_progress(queue)
    assert Enum.map(retired, & &1.lease) == [lease]
    assert Delivery.usage(empty).progress == {0, 0}
    queue = Delivery.event(empty, event(8))
    {:ok, entry} = Delivery.next(queue)
    reference = make_ref()
    {:ok, active} = Delivery.activate(queue, entry.token, reference)
    {:ok, _entry, failed} = Delivery.failed(active, reference)
    assert Delivery.cursor(failed) == 7
    assert Delivery.detached?(failed)
    assert Delivery.detachment(failed)["event_cursor"] == "7"
  end

  test "actual wire creation retains its original command and snapshot joins before live progress" do
    Harness.with_fixture(:file, :runtime, fn fixture ->
      prepare(fixture)

      Harness.send_frame(fixture, %{
        "session_options" => %{"version" => 1},
        "method" => "session.create",
        "request_id" => "create",
        "command_id" => Wire.encode_identity("wire-created")
      })

      records = Harness.await_lines(fixture, 3) |> Enum.map(&decode_payload/1)
      assert [initialized, snapshot, admission] = records
      assert initialized["type"] == "initialized"
      assert snapshot["type"] == "snapshot"
      assert snapshot["snapshot"]["snapshot_revision"] == 3
      assert snapshot["snapshot"]["event_sequence"] == snapshot["event_cursor"]
      assert admission["status"] == "accepted"
      assert {:ok, "wire-created"} == Wire.identity(admission["command_id"])
      :file.close(fixture.input)
      summary = Harness.finished(fixture)
      assert summary.result == :ok
      assert "wire-created" in summary.command_ids
      assert_released_custody(summary)
      assert summary.sink_closed
    end)
  end

  # Concept: model questions settle through the actual foreground attachment.
  # Technical depth: each literal answer vector crosses real stdio once. A
  # malformed union refuses without settlement; accepted ADR 0067's
  # operation-less tool terminal precedes the interaction terminal without
  # detachment; an identical retry replays the historical admission and adds no
  # event. Custody is released at EOF.
  @question_corpus Path.expand("../../loopex/priv/vectors/model_question.v1.json", __DIR__)
                   |> File.read!()
                   |> JSON.decode!()

  for vector <- @question_corpus["vectors"] do
    @question_vector vector

    test "an actual model question #{vector["name"]} answer settles once over foreground stdio" do
      vector = @question_vector

      Harness.with_fixture(:file, String.to_atom("question_" <> vector["name"]), fn fixture ->
        prepare(fixture)

        Harness.send_frame(fixture, %{
          "method" => "session.prompt",
          "request_id" => "prompt",
          "command_id" => Wire.encode_identity("question-prompt"),
          "content_b64" => Wire.encode_bytes("go")
        })

        requested =
          await_record(fixture, &(get_in(&1, ["event", "kind"]) == "interaction.requested"))

        opened = requested["event"]["data"]
        assert opened["producer"] == "model_tool"
        assert opened["interaction_kind"] == vector["interaction_request"]["kind"]
        assert opened["status"] == "pending"

        answer = %{
          "method" => "session.respond_interaction",
          "request_id" => "answer",
          "command_id" => Wire.encode_identity("question-answer"),
          "interaction_id" => opened["interaction_id"],
          "answer" => question_wire_answer(vector["answer"])
        }

        Harness.send_frame(
          fixture,
          answer
          |> Map.put("request_id", "malformed")
          |> Map.put("answer", %{"text" => "ambiguous", "disposition" => "declined"})
        )

        malformed = await_record(fixture, &(&1["request_id"] == "malformed"))
        assert malformed["type"] == "error"
        assert malformed["code"] == "invalid_request"
        refute Enum.any?(output_records(fixture), &terminal_question?/1)

        Harness.send_frame(fixture, answer)
        await_record(fixture, &(get_in(&1, ["event", "kind"]) == "run.finished"))
        records = output_records(fixture)
        refute Enum.any?(records, &(&1["code"] == "detached"))
        kinds = for %{"type" => "event", "event" => %{"kind" => kind}} <- records, do: kind
        terminal_kind = "interaction." <> vector["disposition"]

        # The atomic settlement appends the original tool result before the
        # interaction terminal; the run ends after both.
        assert Enum.find_index(kinds, &(&1 == "tool.finished")) <
                 Enum.find_index(kinds, &(&1 == terminal_kind))

        assert Enum.find_index(kinds, &(&1 == terminal_kind)) <
                 Enum.find_index(kinds, &(&1 == "run.finished"))

        [finished] =
          for %{"event" => %{"kind" => "tool.finished", "data" => data}} <- records, do: data

        {outcome, reason} =
          if vector["disposition"] == "declined",
            do: {"denied", "question_declined"},
            else: {"completed", nil}

        assert finished == %{
                 "run_id" => opened["run_id"],
                 "turn_id" => finished["turn_id"],
                 "tool_call_id" => Wire.encode_identity("ask-1"),
                 "tool_id" => "loopex.ask",
                 "outcome" => outcome,
                 "reason" => reason,
                 "artifacts" => []
               }

        assert {:ok, _turn} = Wire.identity(finished["turn_id"])
        assert {:ok, native} = LoopexProtocol.Session.ToolFinished.decode_wire(finished)
        refute Map.has_key?(native, "operation_id")

        [settled] =
          for %{"event" => %{"kind" => ^terminal_kind, "data" => data}} <- records, do: data

        assert settled["interaction_id"] == opened["interaction_id"]
        assert settled["status"] == vector["disposition"]
        assert settled["command_id"] == Wire.encode_identity("question-answer")
        assert settled["command_digest"] =~ ~r/\A[0-9a-f]{64}\z/

        assert settled["answer"] ==
                 (case answer["answer"] do
                    %{"choice_id" => choice} ->
                      %{"choice_id" => choice, "label" => "literal_null"}

                    other ->
                      other
                  end)

        [%{"event" => %{"data" => run}}] =
          for %{"event" => %{"kind" => "run.finished"}} = record <- records, do: record

        assert run["outcome"] == "completed"
        [admission] = Enum.filter(records, &(&1["request_id"] == "answer"))

        assert admission == %{
                 "type" => "admission",
                 "request_id" => "answer",
                 "method" => "session.respond_interaction",
                 "command_id" => Wire.encode_identity("question-answer"),
                 "status" => "accepted",
                 "reason" => nil
               }

        await_record(fixture, &(get_in(&1, ["event", "kind"]) == "session.settled"))
        settled_events = for %{"type" => "event"} = record <- output_records(fixture), do: record
        Harness.send_frame(fixture, Map.put(answer, "request_id", "retry"))
        retry = await_record(fixture, &(&1["request_id"] == "retry"))
        assert retry == %{admission | "request_id" => "retry"}
        after_retry = for %{"type" => "event"} = record <- output_records(fixture), do: record
        assert after_retry == settled_events
        :file.close(fixture.input)
        summary = Harness.finished(fixture)
        assert summary.result == :ok
        assert_released_custody(summary)
        assert summary.sink_closed
      end)
    end
  end

  # Concept: a real explicit compaction's activity reaches the foreground client.
  # Technical depth: accepted ADR 0054. The permitted summary attempt's single
  # closed activity item crosses the actual Stdio sink route. Durable output is
  # served ahead of queued transient frames, so the item is located by its own
  # base cursor rather than by arrival order. It names the compact owner and the
  # completion's episode, carries no summary text, and custody is released.
  test "an actual explicit compaction routes its activity over foreground stdio" do
    Harness.with_fixture(:file, :compaction, fn fixture ->
      prepare(fixture)

      Harness.send_frame(fixture, %{
        "method" => "session.prompt",
        "request_id" => "prompt",
        "command_id" => Wire.encode_identity("history"),
        "content_b64" => Wire.encode_bytes(String.duplicate("old ", 2_000))
      })

      await_record(fixture, &(get_in(&1, ["event", "kind"]) == "session.settled"))

      Harness.send_frame(fixture, %{
        "method" => "session.compact",
        "request_id" => "compact",
        "command_id" => Wire.encode_identity("compact"),
        "bounds" => %{"max_attempts" => "4", "deadline_ms" => "60000", "token_budget" => "32768"}
      })

      await_record(fixture, &(get_in(&1, ["event", "kind"]) == "context.compaction_finished"))

      activity =
        await_record(
          fixture,
          &(get_in(&1, ["progress", "kind"]) == "context.compaction_progress")
        )

      records = output_records(fixture)
      refute Enum.any?(records, &(&1["code"] == "detached"))

      assert [^activity] =
               Enum.filter(
                 records,
                 &(get_in(&1, ["progress", "kind"]) == "context.compaction_progress")
               )

      assert {:ok, item} =
               LoopexProtocol.Session.CompactionProgress.decode_wire(activity["progress"])

      assert item.owner == %{"kind" => "compact", "id" => "compact"}
      assert activity["session_id"] == Wire.encode_identity(fixture.session)

      [%{"event" => %{"data" => finished}}] =
        for %{"event" => %{"kind" => "context.compaction_finished"}} = record <- records,
            do: record

      assert finished["result"]["disposition"] == "checkpointed"
      assert {:ok, completion} = LoopexProtocol.Session.CompactResult.decode_completion(finished)
      assert completion["episode_id"] == item.episode_id

      # The activity is anchored at the committed cursor before the checkpoint.
      [compacted] =
        for %{"event" => %{"kind" => "context.compacted"} = event} <- records, do: event

      assert item.base_event_sequence < String.to_integer(compacted["event_sequence"])
      refute Enum.any?(records, &(inspect(&1) =~ "retain this fact"))

      :file.close(fixture.input)
      summary = Harness.finished(fixture)
      assert summary.result == :ok
      assert_released_custody(summary)
      assert summary.sink_closed
    end)
  end

  # Concept: a snapshot taken while maintenance is in flight shows the same
  # active view as the last maintenance change at the same public cursor.
  # Technical depth: the summary is held by the controller; a replacing attach
  # takes a fresh snapshot over the real stdio. Its cursor and active view equal
  # the last `context.maintenance_changed` at or before that cursor, and no
  # summary text or private delta is ever written.
  test "a foreground snapshot during maintenance matches the last maintenance change" do
    Harness.with_fixture(:file, :compaction_held, fn fixture ->
      prepare(fixture)
      history(fixture)
      Harness.send_frame(fixture, compact_request("compact"))
      assert Harness.command(fixture, :await_hold, &(&1 == :holding)) == :holding

      await_record(fixture, &(get_in(&1, ["event", "kind"]) == "context.maintenance_changed"))

      Harness.send_frame(fixture, %{
        "method" => "session.attach",
        "request_id" => "replacement",
        "session_id" => Wire.encode_identity(fixture.session),
        "replace" => true
      })

      snapshot = await_record(fixture, &(&1["request_id"] == "replacement"))
      assert snapshot["type"] == "snapshot"
      cursor = String.to_integer(snapshot["event_cursor"])
      assert snapshot["snapshot"]["event_sequence"] == snapshot["event_cursor"]

      [last | _] =
        fixture
        |> output_records()
        |> Enum.filter(fn record ->
          get_in(record, ["event", "kind"]) == "context.maintenance_changed" and
            String.to_integer(record["event"]["event_sequence"]) <= cursor
        end)
        |> Enum.reverse()

      assert last["event"]["event_sequence"] == snapshot["event_cursor"]
      refute is_nil(snapshot["snapshot"]["active_maintenance"])

      assert last["event"]["data"] == %{
               "active_maintenance" => snapshot["snapshot"]["active_maintenance"]
             }

      assert Harness.command(fixture, :release_hold, &(&1 == :hold_released)) == :hold_released
      await_record(fixture, &(get_in(&1, ["event", "kind"]) == "context.compaction_finished"))
      public = File.read!(fixture.output)
      refute public =~ "retain this fact"
      refute public =~ "PRIVATE"
      :file.close(fixture.input)
      summary = Harness.finished(fixture)
      assert summary.result == :ok
      assert_released_custody(summary)
    end)
  end

  # Concept: Store uncertainty on the compact admission never duplicates or
  # loses a public maintenance change over stdio.
  # Technical depth: each of the three fault phases is injected on the next
  # journal commit; the uncertain attempt is retried under its original command
  # until admitted. Event identities and sequences stay unique and ordered, the
  # completion appears once and the final maintenance view is inactive.
  for phase <- [
        :before_linearization,
        :after_linearization_before_result,
        :recovery_representation
      ] do
    @phase phase
    test "#{phase} on the foreground compact admission keeps maintenance changes exact" do
      Harness.with_fixture(:file, :compaction, fn fixture ->
        prepare(fixture)
        history(fixture)

        assert Harness.command(fixture, {:inject, @phase}, &(&1 == :injected)) == :injected
        Harness.send_frame(fixture, compact_request("uncertain"))
        settle_compact(fixture, await_record(fixture, &(&1["request_id"] == "uncertain")), 100)
        await_record(fixture, &(get_in(&1, ["event", "kind"]) == "context.compaction_finished"))

        assert {:observed_faults, observed} =
                 Harness.command(fixture, :observed_faults, &match?({:observed_faults, _}, &1))

        assert {:session_journal_commit, @phase} in observed
        events = for %{"type" => "event", "event" => event} <- output_records(fixture), do: event
        ids = Enum.map(events, & &1["event_id"])
        sequences = Enum.map(events, &String.to_integer(&1["event_sequence"]))
        assert ids == Enum.uniq(ids)
        assert sequences == Enum.sort(Enum.uniq(sequences))
        changes = Enum.filter(events, &(&1["kind"] == "context.maintenance_changed"))
        assert List.last(changes)["data"] == %{"active_maintenance" => nil}
        assert [_once] = Enum.filter(events, &(&1["kind"] == "context.compaction_finished"))
        refute File.read!(fixture.output) =~ "retain this fact"
        :file.close(fixture.input)
        summary = Harness.finished(fixture)
        assert summary.result == :ok
      end)
    end
  end

  defp history(fixture) do
    Harness.send_frame(fixture, %{
      "method" => "session.prompt",
      "request_id" => "history",
      "command_id" => Wire.encode_identity("history"),
      "content_b64" => Wire.encode_bytes(String.duplicate("old ", 2_000))
    })

    await_record(fixture, &(get_in(&1, ["event", "kind"]) == "session.settled"))
  end

  defp compact_request(id),
    do: %{
      "method" => "session.compact",
      "request_id" => id,
      "command_id" => Wire.encode_identity("compact"),
      "bounds" => %{"max_attempts" => "4", "deadline_ms" => "60000", "token_budget" => "32768"}
    }

  defp settle_compact(_fixture, %{"type" => "admission"} = reply, _attempts) do
    assert reply["status"] == "accepted"
  end

  defp settle_compact(fixture, _unknown, attempts) when attempts > 0 do
    Process.sleep(20)
    id = "retry-#{attempts}"
    Harness.send_frame(fixture, compact_request(id))
    settle_compact(fixture, await_record(fixture, &(&1["request_id"] == id)), attempts - 1)
  end

  for kind <- [
        :text_delta,
        :reasoning_delta,
        :tool_call_delta,
        :tool_progress,
        :model_stream_closed,
        :tool_stream_closed,
        :activity
      ] do
    @kind kind
    test "actual #{@kind} frame retains native lease credit until the writer joins" do
      Harness.with_fixture(:file, :runtime, fn fixture ->
        prepare(fixture)

        assert {:offered, :ok} =
                 Harness.command(fixture, {:offer, @kind, 16}, &match?({:offered, _}, &1))

        records = Harness.await_lines(fixture, 3) |> Enum.map(&decode_payload/1)
        assert Enum.map(records, & &1["type"]) == ["initialized", "snapshot", "progress"]

        expected =
          if @kind == :activity, do: "context.compaction_progress", else: Atom.to_string(@kind)

        assert List.last(records)["progress"]["kind"] == expected
        await_credit_empty(fixture)
        :file.close(fixture.input)
        summary = Harness.finished(fixture)
        assert summary.result == :ok
        assert summary.writer_joined
        assert summary.owner_joined
        assert summary.sink_closed
      end)
    end
  end

  test "EOF retires a real blocked progress worker and actual holder without appending an error" do
    Harness.with_fixture(:fifo, :runtime, fn fixture ->
      prepare(fixture)

      assert {:offered, :ok} =
               Harness.command(fixture, {:offer, :text_delta, 32_768}, &match?({:offered, _}, &1))

      metadata = Harness.blocked(fixture)
      assert metadata.credit.slots == 1
      assert metadata.credit.bytes > 0 and metadata.credit.bytes <= 524_288
      prefix = Harness.read_fifo_chunk(fixture)
      assert byte_size(prefix) == 4_096
      refute String.contains?(prefix, "\n")
      assert prefix =~ "{"
      :file.close(fixture.input)
      summary = Harness.finished(fixture)
      assert summary.result == :ok
      assert summary.observed_at < metadata.active.cleanup_cutoff + 1_000
      assert_released_custody(summary)
      assert summary.sink_closed
      Harness.assert_group_absent(metadata.active.group)
    end)
  end

  test "real WRITTEN without JOINED keeps native credit and EOF joins the stopped leader" do
    Harness.with_fixture(:fifo, :runtime, fn fixture ->
      prepare(fixture)

      assert {:offered, :ok} =
               Harness.command(fixture, {:offer, :text_delta, 32_768}, &match?({:offered, _}, &1))

      blocked = Harness.blocked(fixture)
      assert Harness.command(fixture, :stop_leader, &(&1 == :leader_stopped)) == :leader_stopped
      frame = Harness.read_fifo_frame(fixture)
      assert decode(frame)["type"] == "progress"
      written = await_written(fixture)
      assert written.active.reference == blocked.active.reference
      assert written.active.joined_at == nil
      assert written.credit.slots == 1
      :file.close(fixture.input)
      summary = Harness.finished(fixture)
      assert summary.result == :ok
      assert summary.observed_at < blocked.active.cleanup_cutoff + 1_000
      assert summary.sink_closed
      Harness.assert_group_absent(blocked.active.group)
    end)
  end

  test "replacement waits behind a real WRITTEN frame and retains its exact prior holder until join" do
    Harness.with_fixture(:fifo, :runtime, fn fixture ->
      prepare(fixture)
      {:metadata, before} = Harness.metadata(fixture)
      assert [original] = before.attachments

      assert {:offered, :ok} =
               Harness.command(fixture, {:offer, :text_delta, 32_768}, &match?({:offered, _}, &1))

      blocked = Harness.blocked(fixture)
      assert Harness.command(fixture, :stop_leader, &(&1 == :leader_stopped)) == :leader_stopped
      assert decode(Harness.read_fifo_frame(fixture))["type"] == "progress"
      written = await_written(fixture)
      assert written.active.reference == blocked.active.reference
      assert written.active.joined_at == nil

      Harness.send_frame(fixture, %{
        "method" => "session.attach",
        "request_id" => "replacement",
        "session_id" => Wire.encode_identity(fixture.session),
        "replace" => true
      })

      {:metadata, waiting} = Harness.metadata(fixture)
      assert waiting.attachments == [original]
      assert waiting.credit.slots == 1
      assert waiting.active.reference == written.active.reference

      assert Harness.command(fixture, :continue_leader, &(&1 == :leader_continued)) ==
               :leader_continued

      replacement = Harness.read_fifo_frame(fixture) |> decode()
      assert replacement["type"] == "snapshot"
      assert replacement["request_id"] == "replacement"
      assert replacement["snapshot"]["event_sequence"] == replacement["event_cursor"]
      {:metadata, replaced} = Harness.metadata(fixture)
      assert [current] = replaced.attachments
      refute current == original
      :file.close(fixture.input)
      summary = Harness.finished(fixture)
      assert summary.result == :ok
      assert_released_custody(summary)
      assert summary.sink_closed
      Harness.assert_group_absent(blocked.active.group)
    end)
  end

  test "an actual broken output pipe retires the original group and lease without a successor write" do
    Harness.with_fixture(:fifo, :runtime, fn fixture ->
      prepare(fixture)

      # Concept: the write must still be blocked after the 4,096-byte read on
      # every host. Technical depth: the about 65.8 KB frame alone fits a
      # Linux FIFO (65,536 bytes) once 4,096 bytes are read. The harness, which
      # holds the FIFO open, first places 8,192 filler bytes in it, so the frame
      # cannot fit after that read on Linux or Darwin; closing every reader then
      # breaks the actual write.
      filler = :binary.copy("f", 8_192)
      assert :file.write(fixture.fifo, filler) == :ok

      assert {:offered, :ok} =
               Harness.command(fixture, {:offer, :text_delta, 32_768}, &match?({:offered, _}, &1))

      blocked = Harness.blocked(fixture)
      assert blocked.credit.slots == 1
      prefix = Harness.read_fifo_chunk(fixture)
      assert prefix == binary_part(filler, 0, 4_096)
      assert :file.close(fixture.fifo) == :ok
      summary = Harness.finished(fixture)
      # The leader waiting for CONTINUE and the writer share the original 5 s
      # cutoff. Their actual EOF/expiry race has these two closed failure causes;
      # cleanup uncertainty is never a successful negative control.
      assert {:error, reason} = summary.result
      assert reason in [:control_eof, :write_expired]
      assert summary.observed_at < blocked.active.cleanup_cutoff + 1_000
      assert_released_custody(summary)
      assert summary.writer_joined
      assert summary.owner_joined
      assert summary.sink_closed
      Harness.assert_group_absent(blocked.active.group)
    end)
  end

  test "output pressure closes before a later real creation reaches Store and releases its transfer holder" do
    Harness.with_fixture(:fifo, :runtime, fn fixture ->
      prepare(fixture)

      Harness.send_frame(fixture, %{
        "method" => "artifact.open_transfer",
        "request_id" => "open",
        "use_ref" => fixture.reference.use_locator,
        "start_offset" => "0"
      })

      opened = Harness.read_fifo_frame(fixture) |> decode()
      transfer = opened["result"]["transfer_ref"]

      for index <- 1..3 do
        Harness.send_frame(fixture, %{
          "method" => "artifact.read_chunk",
          "request_id" => "chunk#{index}",
          "transfer_ref" => transfer,
          "length" => 32_768
        })
      end

      metadata = Harness.blocked(fixture)

      for index <- 1..100 do
        Harness.send_frame(fixture, %{
          "method" => "session.inspect",
          "request_id" => "query#{index}",
          "session_id" => Wire.encode_identity(fixture.session)
        })
      end

      Harness.send_frame(fixture, %{
        "session_options" => %{"version" => 1},
        "method" => "session.create",
        "request_id" => "denied",
        "command_id" => Wire.encode_identity("must-not-reach-store")
      })

      summary = Harness.finished(fixture)
      assert summary.result == {:error, :output_pressure}
      refute "must-not-reach-store" in summary.command_ids
      assert summary.command_ids == ["bootstrap"]
      # One MiB is read and snapshotted at opening; metadata and at most the
      # three requested chunks add debit. Pressure may stop queued reads.
      assert_released_custody(summary, 2_097_152..(2_097_152 + 131_073 + 3 * 32_768))
      assert summary.observed_at < metadata.active.cleanup_cutoff + 1_000
      Harness.assert_group_absent(metadata.active.group)
    end)
  end

  test "EOF is serviced while a real Store final creation call is held and supplies no fabricated refusal" do
    Harness.with_fixture(:file, :runtime, fn fixture ->
      prepare(fixture)

      assert Harness.command(fixture, :hold_create, &(&1 == :holding_next_create)) ==
               :holding_next_create

      Harness.send_frame(fixture, %{
        "session_options" => %{"version" => 1},
        "method" => "session.create",
        "request_id" => "held",
        "command_id" => Wire.encode_identity("held-original")
      })

      assert {:held, :runtime_control_create_session, tx_id} =
               Harness.next(fixture, &match?({:held, _, _}, &1))

      assert is_binary(tx_id)
      :file.close(fixture.input)
      summary = Harness.finished(fixture)
      assert summary.result == :ok
      assert_released_custody(summary)

      records =
        File.read!(fixture.output)
        |> String.split("\n", trim: true)
        |> Enum.map(&decode_payload/1)

      assert Enum.map(records, & &1["type"]) == ["initialized", "snapshot"]
      refute Enum.any?(records, &(&1["request_id"] == "held"))
    end)
  end

  test "an actual holder worker joined while its owner is suspended cannot reopen expired cleanup" do
    Harness.with_fixture(:file, :runtime, fn fixture ->
      prepare(fixture)
      {:metadata, before} = Harness.metadata(fixture)
      assert [_original] = before.attachments

      assert Harness.command(fixture, :hold_holder_cleanup, &(&1 == :holder_cleanup_held)) ==
               :holder_cleanup_held

      :file.close(fixture.input)

      assert {:cleanup_joined_while_owner_suspended, cutoff} =
               Harness.command(
                 fixture,
                 :suspend_cleanup_owner,
                 &match?({:cleanup_joined_while_owner_suspended, _}, &1)
               )

      assert {:owner_resumed_after_cutoff, observed} =
               Harness.command(
                 fixture,
                 :resume_expired_owner,
                 &match?({:owner_resumed_after_cutoff, _}, &1)
               )

      assert observed >= cutoff
      summary = Harness.finished(fixture)
      assert summary.result == {:error, :cleanup_unproved}
      assert summary.observed_at >= cutoff
      assert_released_custody(summary)
      assert summary.writer_joined
      assert summary.owner_joined
      assert summary.sink_closed
      assert summary.command_ids == ["bootstrap"]
    end)
  end

  test "a caller catches actual writer loss and remains alive after its original input and holder retire" do
    Harness.with_fixture(:file, :writer_failure, fn fixture ->
      prepare(fixture)
      {:metadata, before} = Harness.metadata(fixture)
      assert [_original] = before.attachments

      assert Harness.command(fixture, :suspend_idle_writer, &(&1 == :idle_writer_suspended)) ==
               :idle_writer_suspended

      Harness.send_frame(fixture, %{
        "method" => "session.inspect",
        "request_id" => "caught",
        "session_id" => Wire.encode_identity(fixture.session)
      })

      assert Harness.command(
               fixture,
               :kill_blocked_writer,
               &(&1 == :original_blocked_writer_killed)
             ) == :original_blocked_writer_killed

      summary = Harness.finished(fixture)
      assert summary.result == {:caught_exit, :killed}
      assert summary.caller_survived
      assert summary.original_input_joined
      assert summary.writer_joined
      assert summary.owner_joined
      assert_released_custody(summary)
      assert summary.sink_closed
      assert summary.command_ids == ["bootstrap"]
      assert length(Harness.await_lines(fixture, 2)) == 2
    end)
  end

  # Concept: physical custody is empty while the original live caller retains
  # its connection account.
  # Technical depth: every custody entry counts, regardless of phase. Retained
  # reserved credit or a sealed account fails these exact observations.
  defp assert_released_custody(summary, debit_range \\ 0..0) do
    assert summary.bindings === %{pending: 0, staged: 0, attached: 0, holder_attached: 0}
    assert summary.core_artifact_custody === 0
    assert summary.local_occupancy === %{transfers: 0, jobs: 0}
    assert summary.caller_survived
    debit = summary.accounting.debit
    assert is_integer(debit) and debit in debit_range

    assert summary.accounting === %{
             retained_rows: 1,
             original_alive: true,
             debit: debit,
             reserved: 0,
             sealed: false
           }
  end

  defp prepare(fixture) do
    Harness.send_frame(fixture, %{
      "method" => "initialize",
      "request_id" => "init",
      "generations" => [Session.generation()],
      "capabilities" => []
    })

    Harness.send_frame(fixture, %{
      "method" => "session.attach",
      "request_id" => "attach",
      "session_id" => Wire.encode_identity(fixture.session)
    })

    records =
      if fixture.fifo do
        [Harness.read_fifo_frame(fixture), Harness.read_fifo_frame(fixture)]
        |> Enum.map(&decode/1)
      else
        Harness.await_lines(fixture, 2) |> Enum.map(&decode_payload/1)
      end

    assert Enum.map(records, & &1["type"]) == ["initialized", "snapshot"]
    [_initialized, snapshot] = records
    assert {:ok, session} = Wire.identity(snapshot["session_id"])
    assert session == fixture.session
    assert {:ok, cursor} = Wire.u64(snapshot["event_cursor"])

    assert {:baseline_joined, ^session, ^cursor} =
             Harness.command(
               fixture,
               {:await_baseline_joined, session, cursor},
               &match?({:baseline_joined, _, _}, &1)
             )
  end

  defp await_credit_empty(fixture) do
    {:metadata, metadata} = Harness.metadata(fixture)

    if metadata.credit.slots == 0 do
      assert metadata.credit.bytes == 0
      :ok
    else
      Process.sleep(1)
      await_credit_empty(fixture)
    end
  end

  defp await_written(fixture) do
    {:metadata, metadata} = Harness.metadata(fixture)

    if metadata.active && is_integer(metadata.active.written_at) do
      metadata
    else
      Process.sleep(1)
      await_written(fixture)
    end
  end

  defp event(sequence),
    do: %{
      "run_id" => "run",
      kind: "session.settled",
      event_id: "event#{sequence}",
      event_sequence: sequence
    }

  defp text_item(text),
    do: %{
      kind: :text_delta,
      turn_id: "turn",
      stream_domain_id: "0123456789abcdef0123456789abcdef",
      model_sequence: 0,
      base_event_sequence: 7,
      content_index: 0,
      text: text
    }

  defp question_wire_answer(%{"choice_id" => choice}),
    do: %{"choice_id" => Wire.encode_identity(choice)}

  defp question_wire_answer(answer), do: answer

  defp terminal_question?(record),
    do:
      get_in(record, ["event", "kind"]) in ~w(interaction.answered interaction.declined tool.finished)

  defp output_records(fixture) do
    bytes = if File.exists?(fixture.output), do: File.read!(fixture.output), else: ""
    bytes |> String.split("\n") |> Enum.drop(-1) |> Enum.map(&decode_payload/1)
  end

  # Concept: wait for one record on the actual stdout within the original cutoff.
  # Technical depth: only complete newline-terminated lines are decoded; the
  # fixture's existing 30 s request deadline bounds the poll.
  defp await_record(fixture, predicate) do
    case Enum.find(output_records(fixture), predicate) do
      nil ->
        assert System.monotonic_time(:millisecond) < fixture.cutoff
        Process.sleep(10)
        await_record(fixture, predicate)

      record ->
        record
    end
  end

  defp decode(frame), do: frame |> String.trim_trailing("\n") |> decode_payload()

  defp decode_payload(payload) do
    assert {:ok, record} = Frame.decode(payload, 2_097_152)
    record
  end
end
