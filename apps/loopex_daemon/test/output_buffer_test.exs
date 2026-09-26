defmodule LoopexDaemon.OutputBufferTest do
  use ExUnit.Case, async: true

  alias LoopexDaemon.OutputBuffer

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
