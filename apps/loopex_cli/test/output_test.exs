Code.require_file("support/held_output_target.exs", __DIR__)

defmodule LoopexCli.OutputTest do
  use ExUnit.Case, async: true

  alias Loopex.ProgressSink
  alias LoopexCli.{Output, Render}
  alias LoopexCli.Output.Memory
  alias LoopexCli.Test.HeldOutputTarget, as: Held

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

  test "writes stay ordered per destination and finish waits for joined writes" do
    {:ok, target} = Memory.start()
    {:ok, output, _sink} = Output.open(Memory.target(target), Output.acquisition())
    {:loopex_cli_output, owner, _} = output
    monitor = Process.monitor(owner)
    assert :ok = Output.write(output, :control, :stdout, "@loopex input\n")
    assert :ok = Output.write(output, :text, :stderr, "note\n")
    assert {:ok, quoted} = Render.chat_text("猫\nresult")
    assert :ok = Output.write(output, :text, :stdout, quoted)
    assert :ok = Output.write(output, :text, :stdout, "")
    assert :ok = Output.write(output, :control, :stdout, <<0, 255, 10>>)
    assert :ok = Output.finish(output)
    assert_receive {:DOWN, ^monitor, :process, ^owner, :normal}

    assert Memory.contents(target) ==
             {"@loopex input\n> 猫\n> result\n" <> <<0, 255, 10>>, "note\n"}

    assert Memory.status(target) == :retired
  end

  test "owner notifications track the earliest undelivered control and clear after delivery" do
    held = Held.start()
    {:ok, output, _sink} = Output.open(held.target, Output.acquisition())
    incarnation = elem(output, 2)
    assert :ok = Output.write(output, :text, :stdout, "blocked")
    assert_receive {:held_target_write, :stdout, "blocked"}
    refute_receive {:loopex_cli_output_deadline, ^incarnation, _}, 0
    assert :ok = Output.write(output, :control, :stdout, "first")
    assert_receive {:loopex_cli_output_deadline, ^incarnation, first} when is_integer(first)
    assert :ok = Output.write(output, :control, :stdout, "second")
    refute_receive {:loopex_cli_output_deadline, ^incarnation, ^first}, 0
    Held.release(held, :ok)
    assert_receive {:held_target_write, :stdout, "first"}
    Held.release(held, :ok)
    assert_receive {:held_target_write, :stdout, "second"}
    Held.release(held, :ok)
    assert_receive {:loopex_cli_output_deadline, ^incarnation, nil}
    assert :ok = Output.finish(output)
    assert_receive {:held_target_retire, :idle}
  end

  test "progress drops before required output and the active write remains charged" do
    held = Held.start()
    {:ok, output, _sink} = Output.open(held.target, Output.acquisition())
    assert :ok = Output.write(output, :progress, :stdout, "active")
    assert_receive {:held_target_write, :stdout, "active"}
    assert :ok = Output.write(output, :progress, :stdout, String.duplicate("p", 200_000))
    required = String.duplicate("t", 80_000)
    assert :ok = Output.write(output, :text, :stdout, required)
    assert Output.status(output) == %{bytes: 80_006, dropped: 1, failure: nil}

    assert :dropped =
             Output.write(output, :progress, :stdout, String.duplicate("p", 262_144))

    assert Output.status(output).dropped == 2
    Held.release(held, :ok)
    assert_receive {:held_target_write, :stdout, ^required}
    Held.release(held, :ok)
    assert :ok = Output.finish(output)
    refute_receive {:held_target_write, _, _}, 0
  end

  test "required overflow seals the output, notifies once and retires a held target" do
    held = Held.start()
    {:ok, output, _sink} = Output.open(held.target, Output.acquisition())
    incarnation = elem(output, 2)
    assert :ok = Output.write(output, :text, :stdout, String.duplicate("x", 250_000))
    assert_receive {:held_target_write, :stdout, _}

    assert {:error, :output_overflow} =
             Output.write(output, :control, :stdout, String.duplicate("c", 65_536))

    assert_receive {:loopex_cli_output_failed, ^incarnation, :output_overflow}
    assert_receive {:held_target_retire, :holding}
    assert {:error, :output_overflow} = Output.write(output, :text, :stdout, "later")
    assert {:error, :output_overflow} = Output.finish(output)
    refute_receive {:loopex_cli_output_failed, ^incarnation, _}, 0
  end

  test "stdout and stderr progress share one charged queue and joined delivery proof" do
    held = Held.start()
    {:ok, output, _sink} = Output.open(held.target, Output.acquisition())
    assert :ok = Output.progress(output, delta("answer", 0, "model-a"))
    assert_receive {:held_target_write, :stdout, "answer"}
    assert :ok = Output.progress(output, reasoning("summary", 1, "model-a"))
    assert Output.status(output).bytes == 13
    refute_receive {:held_target_write, _, "summary"}, 0
    assert Output.settle(output, "model-a") == %{admitted: 1, delivered: 0, dropped: 0}
    Held.release(held, :ok)
    assert_receive {:held_target_write, :stderr, "summary"}
    assert :ok = Output.progress(output, delta("delivered", 0, "model-b"))
    Held.release(held, :ok)
    assert_receive {:held_target_write, :stdout, "delivered"}
    Held.release(held, :ok)
    assert :ok = Output.write(output, :control, :stdout, "barrier")
    assert_receive {:held_target_write, :stdout, "barrier"}
    assert Output.settle(output, "model-b") == %{admitted: 1, delivered: 1, dropped: 0}
    Held.release(held, :ok)
    assert :ok = Output.finish(output)
  end

  test "settling a domain and sealing progress preserve the charged active write" do
    held = Held.start()
    {:ok, output, _sink} = Output.open(held.target, Output.acquisition())
    assert :ok = Output.write(output, :text, :stdout, "active")
    assert_receive {:held_target_write, :stdout, "active"}
    assert :ok = Output.progress(output, delta("old", 0, "old-domain"))
    assert :ok = Output.progress(output, delta("other", 0, "other-domain"))
    assert Output.settle(output, "old-domain") == %{admitted: 1, delivered: 0, dropped: 1}
    assert Output.status(output) == %{bytes: 11, dropped: 1, failure: nil}
    assert Output.seal_progress(output) == 2
    assert Output.status(output) == %{bytes: 6, dropped: 2, failure: nil}
    assert :ok = Output.progress(output, delta("late", 0, "late-domain"))
    assert :dropped = Output.write(output, :progress, :stdout, "also late")
    assert Output.seal_progress(output) == 2
    assert :ok = Output.write(output, :control, :stdout, "closing")
    Held.release(held, :ok)
    assert_receive {:held_target_write, :stdout, "closing"}
    refute_receive {:held_target_write, _, "old"}, 0
    refute_receive {:held_target_write, _, "other"}, 0
    refute_receive {:held_target_write, _, "late"}, 0
    Held.release(held, :ok)
    assert :ok = Output.finish(output)
  end

  test "oversized control records refuse before any write rather than being truncated" do
    held = Held.start()
    {:ok, output, _sink} = Output.open(held.target, Output.acquisition())
    incarnation = elem(output, 2)

    assert {:error, :control_record_too_large} =
             Output.write(output, :control, :stdout, String.duplicate("c", 65_537))

    assert_receive {:loopex_cli_output_failed, ^incarnation, :control_record_too_large}
    assert {:error, :control_record_too_large} = Output.finish(output)
    refute_receive {:held_target_write, _, _}, 0
  end

  test "later progress and finish do not renew an earlier control deadline" do
    held = Held.start()
    {:ok, output, _sink} = Output.open(held.target, Output.acquisition())
    incarnation = elem(output, 2)
    assert :ok = Output.write(output, :text, :stdout, "blocked")
    assert_receive {:held_target_write, :stdout, "blocked"}
    started = System.monotonic_time(:millisecond)
    assert :ok = Output.write(output, :control, :stdout, "@loopex wait\n")
    assert Output.status(output).failure == nil

    receive do
    after
      3_000 -> :ok
    end

    assert :ok = Output.write(output, :progress, :stdout, "later progress")
    assert {:error, :output_drain_timeout} = Output.finish(output)
    elapsed = System.monotonic_time(:millisecond) - started
    assert elapsed >= 5_000 and elapsed < 6_500
    assert_receive {:loopex_cli_output_failed, ^incarnation, :output_drain_timeout}
    assert_receive {:held_target_retire, :holding}
  end

  test "a wrong, duplicate or lost acknowledgement is never confirmed delivery" do
    for disposition <- [:wrong_nonce, :duplicate] do
      held = Held.start()
      {:ok, output, _sink} = Output.open(held.target, Output.acquisition())
      incarnation = elem(output, 2)
      assert :ok = Output.write(output, :control, :stdout, "@loopex input\n")
      assert_receive {:held_target_write, :stdout, _}
      Held.release(held, disposition)
      assert_receive {:loopex_cli_output_failed, ^incarnation, :output_failed}
      assert {:error, :output_failed} = Output.finish(output)
    end

    held = Held.start()
    {:ok, output, _sink} = Output.open(held.target, Output.acquisition())
    assert :ok = Output.write(output, :text, :stdout, "lost")
    assert_receive {:held_target_write, :stdout, "lost"}
    Held.release(held, :lost)
    started = System.monotonic_time(:millisecond)
    assert {:error, :cleanup_unproved} = Output.finish(output, started + 300)
    assert System.monotonic_time(:millisecond) - started < 1_000
  end

  test "a foreign actor's acknowledgement retires the target" do
    held = Held.start()
    {:ok, output, _sink} = Output.open(held.target, Output.acquisition())
    {:loopex_cli_output, owner, incarnation} = output
    assert :ok = Output.write(output, :text, :stdout, "held")
    assert_receive {:held_target_write, :stdout, "held"}
    send(owner, {:loopex_cli_output_target, :written, self(), make_ref(), make_ref()})
    assert_receive {:loopex_cli_output_failed, ^incarnation, :output_failed}
    assert_receive {:held_target_retire, :holding}
    assert {:error, :output_failed} = Output.finish(output)
  end

  test "an existing host shutdown deadline shortens finish and OTP status redacts text" do
    held = Held.start()
    {:ok, output, _sink} = Output.open(held.target, Output.acquisition())
    {:loopex_cli_output, owner, _} = output
    assert :ok = Output.write(output, :text, :stdout, "private-buffer-canary")
    assert_receive {:held_target_write, :stdout, _}
    assert :ok = Output.write(output, :text, :stdout, "queued-private-canary")
    refute inspect(:sys.get_status(owner)) =~ "canary"
    started = System.monotonic_time(:millisecond)
    assert {:error, :cleanup_unproved} = Output.finish(output, started)
    assert System.monotonic_time(:millisecond) - started < 1_000
  end

  test "command loss retires a target still holding a request; only the command may write" do
    held = Held.start()
    test = self()

    command =
      spawn(fn ->
        {:ok, output, _sink} = Output.open(held.target, Output.acquisition())
        :ok = Output.write(output, :text, :stdout, "blocked")
        send(test, {:opened, output})
        Process.sleep(:infinity)
      end)

    assert_receive {:opened, {:loopex_cli_output, owner, _} = output}
    assert_receive {:held_target_write, :stdout, "blocked"}
    assert Output.write(output, :control, :stdout, "forged") == {:error, :not_output_owner}
    owner_monitor = Process.monitor(owner)
    Process.exit(command, :kill)
    assert_receive {:held_target_retire, :holding}
    assert_receive {:DOWN, ^owner_monitor, :process, ^owner, :normal}
    Held.stop(held)
  end

  test "acquisition refuses IO names, bare devices and a target already owned" do
    acquisition = Output.acquisition()
    assert {:error, :output_target_refused} = Output.open(:standard_io, acquisition)
    assert {:error, :output_target_refused} = Output.open(Process.group_leader(), acquisition)
    assert {:error, :output_target_refused} = Output.open({:owned, self()}, acquisition)

    {:ok, target} = Memory.start()
    {:ok, first, _sink} = Output.open(Memory.target(target), Output.acquisition())

    assert {:error, :output_target_refused} =
             Output.open(Memory.target(target), Output.acquisition())

    assert :ok = Output.finish(first)
  end

  test "a borrowed device never completes acquisition within the original cutoff" do
    {:ok, device} = StringIO.open("")
    acquisition = Output.acquisition()
    assert {:error, :output_acquisition_expired} = Output.open({:owned, device}, acquisition)
    elapsed = System.monotonic_time(:millisecond) - acquisition.started
    assert elapsed >= 5_000 and elapsed < 5_500
    assert StringIO.contents(device) == {"", ""}
  end

  test "a late target acknowledgement fails acquisition and the owner retires" do
    held = Held.start(acquire: {:delay, 5_100})
    acquisition = Output.acquisition()
    assert {:error, :output_acquisition_expired} = Output.open(held.target, acquisition)
    elapsed = System.monotonic_time(:millisecond) - acquisition.started
    assert elapsed >= 5_000 and elapsed < 5_500
    assert_receive {:held_target_acquire, owner, _id}
    monitor = Process.monitor(owner)
    assert_receive {:DOWN, ^monitor, :process, ^owner, _}, 6_000
    Held.stop(held)
  end

  test "a publication queued before the cutoff but received after it is refused" do
    held = Held.start(acquire: :hold)
    test = self()

    command =
      spawn(fn ->
        acquisition = Output.acquisition()
        send(test, {:acquisition, acquisition})
        send(test, {:opened, Output.open(held.target, acquisition)})
      end)

    assert_receive {:acquisition, acquisition}
    assert_receive {:held_target_acquire, owner, _id}
    owner_monitor = Process.monitor(owner)

    # Concept: the owner publishes inside the interval; the caller reads it later.
    # Technical depth: the caller is suspended before the target acknowledges.
    # The owner answers the sys request only after its acquisition step, so its
    # successful publication is already queued; the caller resumes after the cutoff.
    true = :erlang.suspend_process(command)
    Held.release(held, :acquired)
    _ = :sys.get_state(owner)
    {:messages, queued} = Process.info(command, :messages)
    assert [{:loopex_cli_output_opened, ^owner, _, {:ok, _, _}}] = queued
    Process.sleep(max(acquisition.cutoff + 1 - System.monotonic_time(:millisecond), 0))
    true = :erlang.resume_process(command)

    assert_receive {:opened, {:error, :output_acquisition_expired}}, 2_000
    assert_receive {:held_target_retire, :idle}, 5_000
    assert_receive {:DOWN, ^owner_monitor, :process, ^owner, :normal}, 5_000
    Held.stop(held)
  end

  test "a refused output starts no command or runtime work" do
    held = Held.start(acquire: :refuse)
    test = self()

    result =
      LoopexCli.dispatch(["run", "--policy", "allow-all", "never started"],
        output_target: held.target,
        runtime_starter: fn _options ->
          send(test, :runtime_started)
          {:error, :not_reached}
        end
      )

    assert result == {:error, "the command's output is unavailable (output_target_refused)"}
    refute_received :runtime_started
    refute_received {:held_target_write, _, _}
    Held.stop(held)
  end

  test "an expired cutoff refuses before any acquisition effect" do
    held = Held.start()
    acquisition = %{Output.acquisition() | cutoff: System.monotonic_time(:millisecond)}
    assert {:error, :output_acquisition_expired} = Output.open(held.target, acquisition)
    refute_receive {:held_target_acquire, _, _}, 100
    Held.stop(held)
  end

  test "caller loss during acquisition leaves no published owner" do
    held = Held.start(acquire: :silent)
    test = self()

    caller =
      spawn(fn ->
        send(test, {:result, Output.open(held.target, Output.acquisition())})
      end)

    assert_receive {:held_target_acquire, owner, _id}
    owner_monitor = Process.monitor(owner)
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^owner_monitor, :process, ^owner, _}, 6_000
    refute_received {:result, _}
    Held.stop(held)
  end

  test "native progress keeps its lease through queued copies until each write joins" do
    held = Held.start()
    {:ok, output, sink} = Output.open(held.target, Output.acquisition())
    assert :ok = ProgressSink.try_offer(sink, "session", native(0))
    assert :ok = Output.write(output, :control, :stdout, "barrier")
    assert_receive {:held_target_write, :stdout, "0"}

    for sequence <- 1..31 do
      assert :ok = ProgressSink.try_offer(sink, "session", native(sequence))
    end

    assert Output.status(output).failure == nil
    assert :dropped = ProgressSink.try_offer(sink, "session", native(32))

    Held.release(held, :ok)
    assert_receive {:held_target_write, :stdout, "barrier"}
    Held.release(held, :ok)

    for sequence <- 1..31 do
      expected = Integer.to_string(sequence)
      assert_receive {:held_target_write, :stdout, ^expected}
      Held.release(held, :ok)
    end

    assert :ok = Output.write(output, :control, :stdout, "again")
    assert_receive {:held_target_write, :stdout, "again"}
    assert :ok = ProgressSink.try_offer(sink, "session", native(32))
    Held.release(held, :ok)
    assert_receive {:held_target_write, :stdout, "32"}
    Held.release(held, :ok)
    assert :ok = Output.finish(output)
  end

  test "a durable answer is suppressed only when its exact streamed fragments all joined" do
    cases = [
      {[delta("answer", 0, "a"), closed("a", 1)], "answer", "answer"},
      {[delta("answer", 0, "a")], "answer", "answer\nanswer\n"},
      {[delta("answer", 0, "a"), closed("a", 2)], "answer", "answer\nanswer\n"},
      {[delta("answer", 0, "a"), closed("a", 1)], "different", "answer\ndifferent\n"}
    ]

    for {items, content, expected} <- cases do
      {:ok, target} = Memory.start()
      {:ok, output, _sink} = Output.open(Memory.target(target), Output.acquisition())
      Enum.each(items, &(:ok = Output.progress(output, &1)))
      assert :ok = Output.assistant(output, 2, content, "\n#{content}\n")
      assert :ok = Output.finish(output)
      assert Memory.contents(target) == {expected, ""}
    end
  end

  test "a dropped streamed fragment forces the durable fallback" do
    held = Held.start()
    {:ok, output, _sink} = Output.open(held.target, Output.acquisition())
    assert :ok = Output.write(output, :text, :stdout, String.duplicate("x", 200_000))
    assert_receive {:held_target_write, :stdout, _}
    content = String.duplicate("a", 70_000)
    assert :ok = Output.progress(output, delta(content, 0, "a"))
    assert :ok = Output.progress(output, closed("a", 1))
    assert Output.status(output).dropped == 1
    Held.release(held, :ok)
    assert :ok = Output.write(output, :control, :stdout, "barrier")
    assert_receive {:held_target_write, :stdout, "barrier"}
    Held.release(held, :ok)
    assert :ok = Output.assistant(output, 2, content, "\n" <> content <> "\n")
    expected = "\n" <> content <> "\n"
    assert_receive {:held_target_write, :stdout, ^expected}
    Held.release(held, :ok)
    assert :ok = Output.finish(output)
  end

  defp native(sequence),
    do: delta(Integer.to_string(sequence), sequence, "0123456789abcdef0123456789abcdef")

  defp delta(text, sequence, domain),
    do: %{
      kind: :text_delta,
      turn_id: "turn",
      stream_domain_id: domain,
      model_sequence: sequence,
      base_event_sequence: 1,
      content_index: 0,
      text: text
    }

  defp reasoning(text, sequence, domain),
    do: %{delta(text, sequence, domain) | kind: :reasoning_delta}

  defp closed(domain, count),
    do: %{
      kind: :model_stream_closed,
      turn_id: "turn",
      stream_domain_id: domain,
      base_event_sequence: 1,
      delta_count: count,
      disposition: :complete
    }
end
