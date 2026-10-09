defmodule LoopexDaemon.OutputBufferTest do
  use ExUnit.Case, async: true

  alias LoopexDaemon.OutputBuffer

  test "tagged progress keeps its exact FIFO and charge through a claimed frame" do
    buffer = OutputBuffer.new(64)
    assert {:ok, buffer} = OutputBuffer.enqueue(buffer, "durable-first")
    assert {:ok, progress_ref, buffer} = OutputBuffer.enqueue_progress(buffer, "activity")
    assert {:ok, buffer} = OutputBuffer.enqueue(buffer, "durable-last")
    assert buffer.progress_items == 1 and buffer.progress_bytes == 8
    assert {:ok, durable_ref, "durable-first", buffer} = OutputBuffer.claim(buffer)
    assert {:error, :frame_mismatch} = OutputBuffer.discard_progress(buffer, [durable_ref])
    assert {:ok, buffer} = OutputBuffer.emitted(buffer, durable_ref)
    assert {:ok, ^progress_ref, "activity", buffer} = OutputBuffer.claim(buffer)
    assert buffer.progress_items == 1 and buffer.progress_bytes == 8
    assert {:error, :claimed} = OutputBuffer.discard_progress(buffer, [progress_ref])
    assert {:error, :claim_mismatch} = OutputBuffer.emitted(buffer, make_ref())
    assert {:ok, buffer} = OutputBuffer.emitted(buffer, progress_ref)
    assert buffer.progress_items == 0 and buffer.progress_bytes == 0
    assert {:error, :claim_mismatch} = OutputBuffer.emitted(buffer, progress_ref)
    assert {:ok, last, "durable-last", buffer} = OutputBuffer.claim(buffer)
    assert {:ok, buffer} = OutputBuffer.emitted(buffer, last)
    assert OutputBuffer.empty?(buffer)
  end

  test "progress item and byte ceilings include active output without spending succession reserve" do
    buffer = OutputBuffer.new(1_048_576)
    assert {:ok, buffer} = OutputBuffer.reserve_succession(buffer, 100, 200)

    buffer =
      Enum.reduce(1..32, buffer, fn _, acc ->
        assert {:ok, _, next} = OutputBuffer.enqueue_progress(acc, String.duplicate("p", 16_384))
        next
      end)

    assert buffer.progress_items == 32 and buffer.progress_bytes == 524_288
    assert OutputBuffer.commitment(buffer) == 524_588
    assert {:error, :capacity_exceeded} = OutputBuffer.enqueue_progress(buffer, "extra")
    assert {:ok, ref, _, buffer} = OutputBuffer.claim(buffer)
    assert {:error, :capacity_exceeded} = OutputBuffer.enqueue_progress(buffer, "extra")
    assert {:ok, buffer} = OutputBuffer.emitted(buffer, ref)
    assert {:ok, _, buffer} = OutputBuffer.enqueue_progress(buffer, String.duplicate("q", 16_384))
    assert buffer.progress_items == 32 and buffer.progress_bytes == 524_288

    assert {:ok, _, one} =
             OutputBuffer.enqueue_progress(
               OutputBuffer.new(1_048_576),
               String.duplicate("p", 524_288)
             )

    assert {:error, :capacity_exceeded} = OutputBuffer.enqueue_progress(one, "byte-overflow")
  end

  test "selective progress discard preserves durable order reservation and claimed custody" do
    buffer = OutputBuffer.new(64)
    assert {:ok, first, buffer} = OutputBuffer.enqueue_progress(buffer, "first")
    assert {:ok, buffer} = OutputBuffer.enqueue(buffer, "durable")
    assert {:ok, last, buffer} = OutputBuffer.enqueue_progress(buffer, "last")
    assert {:ok, buffer} = OutputBuffer.reserve_succession(buffer, 4, 8)
    before = buffer

    for refs <- [[make_ref()], [first, first], [first, make_ref()]] do
      assert {:error, :frame_mismatch} = OutputBuffer.discard_progress(buffer, refs)
      assert buffer == before
    end

    assert {:ok, ^first, "first", buffer} = OutputBuffer.claim(buffer)
    assert {:error, :claimed} = OutputBuffer.discard_progress(buffer, [first, last])
    assert {:ok, buffer} = OutputBuffer.discard_progress(buffer, [last])
    assert OutputBuffer.commitment(buffer) == 24
    assert buffer.progress_items == 1 and buffer.progress_bytes == 5
    assert {:ok, buffer} = OutputBuffer.emitted(buffer, first)
    assert {:ok, durable, "durable", buffer} = OutputBuffer.claim(buffer)
    assert {:ok, buffer} = OutputBuffer.emitted(buffer, durable)
    assert OutputBuffer.commitment(buffer) == 12
    assert {:ok, buffer} = OutputBuffer.enqueue_succession_notice(buffer, "note")
    assert {:ok, notice, "note", buffer} = OutputBuffer.claim(buffer)
    assert {:ok, buffer} = OutputBuffer.emitted(buffer, notice)
    assert buffer.succession.phase == :reply_ready
  end

  test "transient discard before durable pressure preserves the active frame and durable FIFO" do
    buffer = OutputBuffer.new(16)
    assert {:ok, first, buffer} = OutputBuffer.enqueue_progress(buffer, "1234")
    assert {:ok, buffer} = OutputBuffer.enqueue(buffer, String.duplicate("d", 12))
    assert {:error, :capacity_exceeded} = OutputBuffer.enqueue(buffer, "e")
    {[^first], cleared} = OutputBuffer.discard_unclaimed_progress(buffer)
    assert {:ok, cleared} = OutputBuffer.enqueue(cleared, "e")
    assert {:ok, durable, bytes, cleared} = OutputBuffer.claim(cleared)
    assert bytes == String.duplicate("d", 12)
    assert {:ok, cleared} = OutputBuffer.emitted(cleared, durable)
    assert {:ok, _, "e", _} = OutputBuffer.claim(cleared)

    assert {:ok, active, active_buffer} =
             OutputBuffer.enqueue_progress(OutputBuffer.new(16), "1234")

    assert {:ok, ^active, "1234", active_buffer} = OutputBuffer.claim(active_buffer)
    assert {:ok, queued, active_buffer} = OutputBuffer.enqueue_progress(active_buffer, "5678")
    assert {[^queued], retained} = OutputBuffer.discard_unclaimed_progress(active_buffer)
    assert retained.claim == active
    assert retained.progress_items == 1 and retained.progress_bytes == 4
    assert {:ok, retained} = OutputBuffer.enqueue(retained, String.duplicate("d", 12))
    assert OutputBuffer.bytes(retained) == 16
    assert {:error, :capacity_exceeded} = OutputBuffer.enqueue(retained, "e")
    assert {:error, :claimed} = OutputBuffer.discard_progress(retained, [active])
  end

  test "ordinary frames stay charged until exact complete-emission acknowledgement" do
    buffer = OutputBuffer.new(10)

    assert {:ok, buffer} = OutputBuffer.enqueue(buffer, ["abc", "def"])
    assert {:ok, buffer} = OutputBuffer.enqueue(buffer, "ghij")
    assert OutputBuffer.bytes(buffer) == 10
    assert OutputBuffer.commitment(buffer) == 10
    assert {:error, :capacity_exceeded} = OutputBuffer.enqueue(buffer, "k")

    assert {:ok, first_ref, "abcdef", buffer} = OutputBuffer.claim(buffer)
    assert {:error, :claimed} = OutputBuffer.claim(buffer)
    assert {:error, :claim_mismatch} = OutputBuffer.emitted(buffer, make_ref())
    assert OutputBuffer.bytes(buffer) == 10

    assert {:ok, buffer} = OutputBuffer.emitted(buffer, first_ref)
    assert OutputBuffer.bytes(buffer) == 4
    assert {:ok, second_ref, "ghij", buffer} = OutputBuffer.claim(buffer)
    assert {:ok, buffer} = OutputBuffer.emitted(buffer, second_ref)
    assert {:empty, ^buffer} = OutputBuffer.claim(buffer)
    assert OutputBuffer.empty?(buffer)
  end

  test "succession reserve protects the notice and one serially reused reply slot" do
    buffer = OutputBuffer.new(20)
    assert {:ok, buffer} = OutputBuffer.enqueue(buffer, String.duplicate("o", 10))
    assert {:ok, buffer} = OutputBuffer.reserve_succession(buffer, 4, 6)
    assert OutputBuffer.commitment(buffer) == 20

    assert {:error, :capacity_exceeded} = OutputBuffer.enqueue(buffer, "x")
    assert {:ok, buffer} = OutputBuffer.enqueue_succession_notice(buffer, "note")
    assert OutputBuffer.bytes(buffer) == 14
    assert OutputBuffer.commitment(buffer) == 20
    assert {:error, :succession_pending} = OutputBuffer.enqueue(buffer, "x")
    assert {:error, :reply_unavailable} = OutputBuffer.enqueue_succession_reply(buffer, "reply1")

    assert {:ok, ordinary_ref, ordinary, buffer} = OutputBuffer.claim(buffer)
    assert ordinary == String.duplicate("o", 10)
    assert {:ok, buffer} = OutputBuffer.emitted(buffer, ordinary_ref)
    assert {:ok, notice_ref, "note", buffer} = OutputBuffer.claim(buffer)
    assert {:ok, buffer} = OutputBuffer.emitted(buffer, notice_ref)
    assert OutputBuffer.commitment(buffer) == 6

    assert {:ok, buffer} = OutputBuffer.enqueue_succession_reply(buffer, "reply1")
    assert OutputBuffer.bytes(buffer) == 6
    assert OutputBuffer.commitment(buffer) == 6

    assert {:error, :reply_unavailable} =
             OutputBuffer.enqueue_succession_reply(buffer, "reply2")

    assert {:ok, reply_ref, "reply1", buffer} = OutputBuffer.claim(buffer)
    assert {:ok, buffer} = OutputBuffer.emitted(buffer, reply_ref)
    assert OutputBuffer.commitment(buffer) == 6

    assert {:ok, buffer} = OutputBuffer.enqueue_succession_reply(buffer, "two")
    assert OutputBuffer.bytes(buffer) == 3
    assert OutputBuffer.commitment(buffer) == 6
    assert {:ok, reply_ref, "two", buffer} = OutputBuffer.claim(buffer)
    assert {:ok, buffer} = OutputBuffer.emitted(buffer, reply_ref)
    assert {:ok, buffer} = OutputBuffer.finish_succession(buffer)
    assert OutputBuffer.commitment(buffer) == 0
  end

  test "a pending attach conflict uses the reply slot and releases unused notice headroom" do
    buffer = OutputBuffer.new(20)
    assert {:ok, buffer} = OutputBuffer.enqueue(buffer, String.duplicate("o", 10))
    assert {:ok, buffer} = OutputBuffer.reserve_succession(buffer, 4, 6)

    assert {:ok, buffer} =
             OutputBuffer.enqueue_succession_reply(buffer, "refuse", without_notice: true)

    assert OutputBuffer.bytes(buffer) == 16
    assert OutputBuffer.commitment(buffer) == 16

    assert {:error, :reply_unavailable} =
             OutputBuffer.enqueue_succession_reply(buffer, "again", without_notice: true)

    assert {:ok, ordinary_ref, _ordinary, buffer} = OutputBuffer.claim(buffer)
    assert {:ok, buffer} = OutputBuffer.emitted(buffer, ordinary_ref)
    assert {:ok, reply_ref, "refuse", buffer} = OutputBuffer.claim(buffer)
    assert {:ok, buffer} = OutputBuffer.emitted(buffer, reply_ref)
    assert OutputBuffer.commitment(buffer) == 6
    assert {:ok, buffer} = OutputBuffer.finish_succession(buffer)
    assert OutputBuffer.commitment(buffer) == 0
  end

  test "reservation and phase transitions refuse impossible reuse" do
    buffer = OutputBuffer.new(20)

    assert {:error, :invalid_reserve} = OutputBuffer.reserve_succession(buffer, 0, 1)
    assert {:error, :capacity_exceeded} = OutputBuffer.reserve_succession(buffer, 10, 10)
    assert {:error, :not_reserved} = OutputBuffer.release_succession(buffer)
    assert {:error, :not_reserved} = OutputBuffer.finish_succession(buffer)

    assert {:ok, buffer} = OutputBuffer.reserve_succession(buffer, 4, 6)
    assert {:error, :already_reserved} = OutputBuffer.reserve_succession(buffer, 4, 6)
    assert {:error, :capacity_exceeded} = OutputBuffer.enqueue_succession_notice(buffer, "large")
    assert {:ok, buffer} = OutputBuffer.enqueue_succession_notice(buffer, "n")
    assert {:error, :succession_pending} = OutputBuffer.release_succession(buffer)
    assert {:error, :succession_pending} = OutputBuffer.finish_succession(buffer)
  end
end
