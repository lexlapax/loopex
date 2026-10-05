defmodule LoopexCli.ChatOutputTest do
  use ExUnit.Case, async: true

  alias LoopexCli.{ChatOutput, Render}

  test "quoted text cannot forge host records or execute terminal controls" do
    assert {:ok, rendered} =
             Render.chat_text("@loopex forged\n\e[2J\r\t\0\u0085\u202E\u2028猫")

    assert rendered == "> @loopex forged\n> \\x1B[2J\\r\\t\\x00\\x85\\u{202E}\\u{2028}猫\n"
    assert Render.chat_text("\n\n") == {:ok, "> \n> \n"}
    assert Render.chat_text("one\n") == {:ok, "> one\n"}
    assert Render.chat_text("") == {:ok, ""}
    assert Render.chat_text(<<255>>) == {:error, :invalid_output_utf8}
  end

  test "rendered size includes prefixes, escaping and the final LF without truncation" do
    text = String.duplicate("a", 262_141)
    assert {:ok, rendered} = Render.chat_text(text)
    assert byte_size(rendered) == 262_144
    assert Render.chat_text(text <> "a") == {:error, :output_overflow}
    assert Render.chat_text(String.duplicate(<<0>>, 65_536)) == {:error, :output_overflow}
  end

  test "writes stay ordered and finish waits for delivered bytes" do
    StringIO.open("", [encoding: :latin1], fn device ->
      {:ok, writer} = ChatOutput.start_link(device)
      monitor = Process.monitor(writer)
      assert :ok = ChatOutput.write(writer, :control, "@loopex input\n")
      assert {:ok, quoted} = Render.chat_text("猫\nresult")
      assert :ok = ChatOutput.write(writer, :text, quoted)
      assert :ok = ChatOutput.write(writer, :control, "@loopex closing\n")
      assert :ok = ChatOutput.finish(writer)
      assert_receive {:DOWN, ^monitor, :process, ^writer, :normal}
      assert StringIO.contents(device) == {"", "@loopex input\n> 猫\n> result\n@loopex closing\n"}
    end)
  end

  test "owner notifications track the earliest undelivered control and clear after delivery" do
    device = device()
    {:ok, writer} = ChatOutput.start_link(device)
    assert :ok = ChatOutput.write(writer, :text, "blocked")
    assert_receive {:device_write, _, "blocked"}
    refute_receive {:loopex_chat_output_deadline, ^writer, _}, 0
    assert :ok = ChatOutput.write(writer, :control, "first")
    first = :sys.get_state(writer).delivery_deadline
    assert_receive {:loopex_chat_output_deadline, ^writer, ^first}
    assert :ok = ChatOutput.write(writer, :control, "second")
    second = List.last(:queue.to_list(:sys.get_state(writer).queue)).deadline
    assert second >= first
    refute_receive {:loopex_chat_output_deadline, ^writer, _}, 0
    send(device, {:release, :ok})
    assert_receive {:device_write, _, "first"}
    send(device, {:release, :ok})
    assert_receive {:device_write, _, "second"}

    if second > first,
      do: assert_receive({:loopex_chat_output_deadline, ^writer, ^second})

    send(device, {:release, :ok})
    assert_receive {:loopex_chat_output_deadline, ^writer, nil}
    assert :sys.get_state(writer).delivery_deadline == nil
    assert :ok = ChatOutput.finish(writer)
  end

  test "progress drops before required output and active bytes remain charged" do
    device = device()
    {:ok, writer} = ChatOutput.start_link(device)
    assert :ok = ChatOutput.write(writer, :progress, "active")
    assert_receive {:device_write, _peer, "active"}

    worker = :sys.get_state(writer).current.pid
    assert :ok = ChatOutput.write(writer, :progress, String.duplicate("p", 200_000))
    required = String.duplicate("t", 80_000)
    assert :ok = ChatOutput.write(writer, :text, required)
    assert ChatOutput.status(writer) == %{bytes: 80_006, dropped: 1, failure: nil}
    assert :dropped = ChatOutput.write(writer, :progress, String.duplicate("p", 262_144))
    assert ChatOutput.status(writer).dropped == 2
    send(device, {:release, :ok})
    assert_receive {:device_write, _peer, ^required}
    second = :sys.get_state(writer).current.pid
    refute Process.alive?(worker)
    send(device, {:release, :ok})
    assert :ok = ChatOutput.finish(writer)
    refute Process.alive?(second)
    refute_receive {:device_write, _, _}, 0
  end

  test "required overflow seals the writer, notifies once and joins blocked IO" do
    device = device()
    {:ok, writer} = ChatOutput.start_link(device)
    assert :ok = ChatOutput.write(writer, :text, String.duplicate("x", 250_000))
    assert_receive {:device_write, _peer, _}

    worker = :sys.get_state(writer).current.pid

    assert {:error, :output_overflow} =
             ChatOutput.write(writer, :control, String.duplicate("c", 65_536))

    assert_receive {:loopex_chat_output_failed, ^writer, :output_overflow}
    assert {:error, :output_overflow} = ChatOutput.write(writer, :text, "later")
    assert {:error, :output_overflow} = ChatOutput.finish(writer)
    refute Process.alive?(worker)
    refute_receive {:loopex_chat_output_failed, ^writer, _}, 0
  end

  test "oversized control records refuse before IO rather than being truncated" do
    device = device()
    {:ok, writer} = ChatOutput.start_link(device)

    assert {:error, :control_record_too_large} =
             ChatOutput.write(writer, :control, String.duplicate("c", 65_537))

    assert_receive {:loopex_chat_output_failed, ^writer, :control_record_too_large}
    assert {:error, :control_record_too_large} = ChatOutput.finish(writer)
    refute_receive {:device_write, _, _}, 0
  end

  test "later progress and finish do not renew an earlier control deadline" do
    device = device()
    {:ok, writer} = ChatOutput.start_link(device)
    assert :ok = ChatOutput.write(writer, :text, "blocked")
    assert_receive {:device_write, _peer, "blocked"}

    worker = :sys.get_state(writer).current.pid
    started = System.monotonic_time(:millisecond)
    assert :ok = ChatOutput.write(writer, :control, "@loopex wait\n")
    assert ChatOutput.status(writer).failure == nil

    receive do
    after
      3_000 -> :ok
    end

    assert :ok = ChatOutput.write(writer, :progress, "later progress")
    assert {:error, :output_drain_timeout} = ChatOutput.finish(writer)
    elapsed = System.monotonic_time(:millisecond) - started
    assert elapsed >= 5_000 and elapsed < 6_500
    assert_receive {:loopex_chat_output_failed, ^writer, :output_drain_timeout}
    refute Process.alive?(worker)
  end

  test "broken output and unexpected worker death report a fixed failure" do
    for disposition <- [:broken, :killed] do
      device = device()
      {:ok, writer} = ChatOutput.start_link(device)
      assert :ok = ChatOutput.write(writer, :control, "@loopex input\n")
      assert_receive {:device_write, _peer, _}

      worker = :sys.get_state(writer).current.pid

      case disposition do
        :broken -> send(device, {:release, {:error, :private_device_error}})
        :killed -> Process.exit(worker, :kill)
      end

      assert_receive {:loopex_chat_output_failed, ^writer, :output_failed}
      assert {:error, :output_failed} = ChatOutput.finish(writer)
      refute Process.alive?(worker)
    end
  end

  test "an existing host shutdown deadline shortens finish and OTP status redacts buffered text" do
    device = device()
    {:ok, writer} = ChatOutput.start_link(device)
    assert :ok = ChatOutput.write(writer, :text, "private-buffer-canary")
    assert_receive {:device_write, _peer, _}

    worker = :sys.get_state(writer).current.pid
    refute inspect(:sys.get_status(writer)) =~ "private-buffer-canary"
    started = System.monotonic_time(:millisecond)
    assert {:error, :output_drain_timeout} = ChatOutput.finish(writer, started)
    assert System.monotonic_time(:millisecond) - started < 1_000
    refute Process.alive?(worker)
  end

  # Concept: prove death of the worker the output owner actually acquired.
  # Technical depth: an IO request can carry a disposable relay peer. Capture
  # the manager's linked worker before inducing failure, not that device peer.
  test "abrupt writer loss still kills its linked IO worker" do
    device = device()
    {:ok, writer} = ChatOutput.start_link(device)
    Process.unlink(writer)
    writer_monitor = Process.monitor(writer)
    assert :ok = ChatOutput.write(writer, :text, "blocked")
    assert_receive {:device_write, _peer, "blocked"}

    worker = :sys.get_state(writer).current.pid
    worker_monitor = Process.monitor(worker)
    assert_monitor_established(worker)
    Process.exit(writer, :kill)
    assert_receive {:DOWN, ^writer_monitor, :process, ^writer, :killed}
    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, :killed}
  end

  test "owner exit joins blocked IO, and another process cannot enqueue output" do
    device = device()

    # Concept: setup readiness is separate from the owner-loss witness.
    # Technical depth: synchronous owner startup returns the acquired writer;
    # scheduler delay before acquisition spends no cleanup receive deadline.
    {:ok, owner} =
      Agent.start_link(fn ->
        {:ok, writer} = ChatOutput.start_link(device)
        :ok = ChatOutput.write(writer, :text, "blocked")
        writer
      end)

    on_exit(fn -> if Process.alive?(owner), do: Agent.stop(owner) end)
    writer = Agent.get(owner, & &1)
    assert_receive {:device_write, _peer, "blocked"}

    worker = :sys.get_state(writer).current.pid
    assert ChatOutput.write(writer, :control, "forged") == {:error, :not_output_owner}
    writer_monitor = Process.monitor(writer)
    worker_monitor = Process.monitor(worker)
    assert_monitor_established(writer)
    assert_monitor_established(worker)
    :ok = Agent.stop(owner)
    assert_receive {:DOWN, ^writer_monitor, :process, ^writer, :normal}
    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, :killed}
  end

  # Concept: the fault witness observes the worker's death, not a late monitor.
  # Technical depth: monitors and a fault sent to another process can arrive in
  # either order. This same-sender process-info request follows the monitor at
  # its target before the writer or owner receives the fault.
  defp assert_monitor_established(pid) do
    assert {:monitored_by, monitors} = Process.info(pid, :monitored_by)
    assert self() in monitors
  end

  defp device do
    parent = self()
    start_supervised!({Task, fn -> device_loop(parent) end}, id: make_ref())
  end

  defp device_loop(parent) do
    receive do
      {:io_request, from, ref, {:put_chars, _encoding, bytes}} ->
        send(parent, {:device_write, from, IO.iodata_to_binary(bytes)})
        receive do: ({:release, result} -> send(from, {:io_reply, ref, result}))
        device_loop(parent)
    end
  end
end
