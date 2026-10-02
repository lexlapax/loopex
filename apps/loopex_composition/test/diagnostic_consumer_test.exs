defmodule LoopexComposition.DiagnosticConsumerTest do
  use ExUnit.Case, async: true

  alias LoopexComposition.DiagnosticConsumer

  test "supervised startup binds the explicit host and asynchronous closing seals dispatch" do
    device = device()
    consumer = start_supervised!({DiagnosticConsumer, {self(), device, 1_000}})
    assert {:ok, [^consumer, supervisor]} = DiagnosticConsumer.owned_processes(consumer)
    send(consumer, {:loopex_diagnostic, %{"kind" => "trace_call"}})
    assert_receive {:device_write, writer, _}
    send(consumer, {:loopex_diagnostic, %{"kind" => "ordinary"}})
    ref = make_ref()
    consumer_ref = Process.monitor(consumer)
    supervisor_ref = Process.monitor(supervisor)
    writer_ref = Process.monitor(writer)

    assert {:ok, [^consumer, ^supervisor, ^writer]} =
             DiagnosticConsumer.begin_close(consumer, ref, deadline())

    assert_receive {:diagnostic_consumer_closed, ^consumer, ^ref, {:ok, final}}
    assert final.counts.trace == %{emitted: 0, dropped: 0, unconfirmed: 1}
    assert final.counts.diagnostic == %{emitted: 0, dropped: 1, unconfirmed: 0}
    refute Process.alive?(writer)
    refute Process.alive?(supervisor)
    assert_receive {:DOWN, ^writer_ref, :process, ^writer, _}
    assert_receive {:DOWN, ^supervisor_ref, :process, ^supervisor, _}
    assert_receive {:DOWN, ^consumer_ref, :process, ^consumer, :normal}
    refute_receive {:device_write, _, _}, 0
    refute_receive {:diagnostic_consumer_closed, ^consumer, ^ref, _}, 0
  end

  test "private registration and asynchronous shutdown remain owner-only" do
    device = device()
    {:ok, consumer} = DiagnosticConsumer.start_link(device, 1_000)

    task =
      Task.async(fn ->
        {DiagnosticConsumer.owned_processes(consumer),
         DiagnosticConsumer.begin_close(consumer, make_ref(), deadline())}
      end)

    assert Task.await(task) == {{:error, :not_diagnostic_owner}, {:error, :not_diagnostic_owner}}
    assert DiagnosticConsumer.status(consumer).failure == nil
    assert {:ok, _} = DiagnosticConsumer.close(consumer, deadline())
  end

  test "observed mailbox growth stays distinct from the proved explicit output bound" do
    device = device()
    {:ok, consumer} = DiagnosticConsumer.start_link(device, 1_000)
    send(consumer, {:loopex_diagnostic, %{"kind" => "ordinary"}})
    assert_receive {:device_write, _, _}
    :ok = :sys.suspend(consumer)
    for _ <- 1..6_000, do: send(consumer, {:loopex_diagnostic, %{"kind" => "ordinary"}})
    assert {:message_queue_len, mailbox} = Process.info(consumer, :message_queue_len)
    assert mailbox >= 6_000
    :ok = :sys.resume(consumer)
    view = DiagnosticConsumer.status(consumer)
    assert view.pending == 256 and view.active
    assert view.counts.diagnostic == %{emitted: 0, dropped: 5_744, unconfirmed: 0}
    assert {:ok, final} = DiagnosticConsumer.close(consumer, deadline())
    assert final.counts.diagnostic == %{emitted: 0, dropped: 6_000, unconfirmed: 1}
  end

  test "a stalled writer holds one entry while the drain consumes and counts excess by kind" do
    device = device()
    {:ok, consumer} = DiagnosticConsumer.start_link(device, 1_000)
    send(consumer, {:loopex_diagnostic, %{"kind" => "trace_call", "function" => "first"}})
    assert_receive {:device_write, worker, _}

    for i <- 1..128 do
      send(consumer, {:loopex_diagnostic, %{"kind" => "trace_call", "number" => i}})
      send(consumer, {:loopex_diagnostic, %{"kind" => "ordinary", "number" => i}})
    end

    for _ <- 1..23, do: send(consumer, {:loopex_diagnostic, %{"kind" => "trace_dropped"}})
    for _ <- 1..17, do: send(consumer, {:loopex_diagnostic, %{"kind" => "ordinary"}})

    view = DiagnosticConsumer.status(consumer)
    assert view.pending == 256
    assert view.active
    assert view.counts.trace == %{emitted: 0, dropped: 23, unconfirmed: 0}
    assert view.counts.diagnostic == %{emitted: 0, dropped: 17, unconfirmed: 0}
    assert is_integer(view.mailbox) and view.mailbox >= 0
    refute_receive {:device_write, _, _}, 0

    assert {:ok, final} = DiagnosticConsumer.close(consumer, deadline())
    assert final.pending == 0 and final.active == false
    assert final.counts.trace == %{emitted: 0, dropped: 151, unconfirmed: 1}
    assert final.counts.diagnostic == %{emitted: 0, dropped: 145, unconfirmed: 0}
    refute Process.alive?(worker)
    refute Process.alive?(consumer)
  end

  test "each acknowledged write and worker termination precedes the next entry" do
    device = device()
    {:ok, consumer} = DiagnosticConsumer.start_link(device, 1_000)
    send(consumer, {:loopex_diagnostic, %{"kind" => "trace_call", "function" => "first"}})
    send(consumer, {:loopex_diagnostic, %{"kind" => "ordinary", "message" => "second"}})
    assert_receive {:device_write, first, bytes}
    assert bytes =~ "first"
    assert DiagnosticConsumer.status(consumer).pending == 1
    refute_receive {:device_write, _, _}, 0
    send(device, {:release, :ok})
    assert_receive {:device_write, second, bytes}
    assert bytes =~ "second"
    refute Process.alive?(first)
    assert DiagnosticConsumer.status(consumer).counts.trace.emitted == 1
    send(device, {:release, :ok})
    await_idle(consumer)
    assert {:ok, final} = DiagnosticConsumer.close(consumer, deadline())
    assert final.counts.trace == %{emitted: 1, dropped: 0, unconfirmed: 0}
    assert final.counts.diagnostic == %{emitted: 1, dropped: 0, unconfirmed: 0}
    refute Process.alive?(second)
  end

  test "a sustained ordered stream leaves no writer overlap or task-capacity race" do
    StringIO.open("", [encoding: :latin1], fn device ->
      {:ok, consumer} = DiagnosticConsumer.start_link(device, 1_000)

      for i <- 1..200 do
        send(consumer, {:loopex_diagnostic, %{"kind" => "ordinary", "number" => i}})
        await_idle(consumer)
      end

      assert {:ok, final} = DiagnosticConsumer.close(consumer, deadline())
      assert final.counts.diagnostic == %{emitted: 200, dropped: 0, unconfirmed: 0}
      {"", output} = StringIO.contents(device)
      assert length(:binary.matches(output, "\n")) == 200
    end)
  end

  test "rendering is bounded and redacted before IO or process status inspection" do
    device = device()
    {:ok, consumer} = DiagnosticConsumer.start_link(device, 1_000)

    entry = %{
      "kind" => "trace_call",
      "credential_ref" => "credential-canary",
      "arguments" => "arguments-canary",
      "text" => "text-canary",
      "wide" => Enum.to_list(1..1_000),
      "message" => String.duplicate("猫", 4_000)
    }

    send(consumer, {:loopex_diagnostic, entry})
    assert_receive {:device_write, _, bytes}
    send(consumer, {:loopex_diagnostic, %{"kind" => "ordinary", "message" => "buffer-canary"}})
    assert DiagnosticConsumer.status(consumer).pending == 1
    assert byte_size(bytes) <= 4_096
    assert String.ends_with?(bytes, "\n")

    for canary <- ["credential-canary", "arguments-canary", "text-canary"] do
      refute bytes =~ canary
      refute inspect(:sys.get_status(consumer)) =~ canary
    end

    refute inspect(:sys.get_status(consumer)) =~ "buffer-canary"
    assert {:ok, _} = DiagnosticConsumer.close(consumer, deadline())
  end

  test "private supervisor loss seals delivery and leaves the drain responsive" do
    device = device()
    {:ok, consumer} = DiagnosticConsumer.start_link(device, 1_000)
    send(consumer, {:loopex_diagnostic, %{"kind" => "trace_call"}})
    assert_receive {:device_write, worker, _}
    worker_ref = Process.monitor(worker)
    send(consumer, {:loopex_diagnostic, %{"kind" => "ordinary"}})
    supervisor = :sys.get_state(consumer).supervisor
    Process.exit(supervisor, :kill)
    assert_receive {:DOWN, ^worker_ref, :process, ^worker, _}
    wait_for(consumer, fn view -> view.failure != nil and view.active == false end)
    assert {:ok, final} = DiagnosticConsumer.close(consumer, deadline())
    assert final.counts.trace == %{emitted: 0, dropped: 0, unconfirmed: 1}
    assert final.counts.diagnostic == %{emitted: 0, dropped: 1, unconfirmed: 0}
  end

  test "broken IO and writer death are unconfirmed and seal only diagnostic delivery" do
    for disposition <- [:broken, :killed] do
      device = device()
      {:ok, consumer} = DiagnosticConsumer.start_link(device, 1_000)
      send(consumer, {:loopex_diagnostic, %{"kind" => "trace_call"}})
      assert_receive {:device_write, worker, _}
      send(consumer, {:loopex_diagnostic, %{"kind" => "ordinary"}})

      case disposition do
        :broken -> send(device, {:release, {:error, :private_device_error}})
        :killed -> Process.exit(worker, :kill)
      end

      await_failure(consumer)
      send(consumer, {:loopex_diagnostic, %{"kind" => "trace_dropped"}})
      view = DiagnosticConsumer.status(consumer)
      assert view.failure == :diagnostic_output_failed
      assert view.counts.trace == %{emitted: 0, dropped: 1, unconfirmed: 1}
      assert view.counts.diagnostic == %{emitted: 0, dropped: 1, unconfirmed: 0}
      assert view.pending == 0 and view.active == false
      assert {:ok, final} = DiagnosticConsumer.close(consumer, deadline())
      assert final.counts == view.counts
      refute inspect(final) =~ "private_device_error"
      refute_receive {:device_write, _, _}, 0
    end
  end

  test "only the creating host can inspect or close the drain" do
    device = device()
    {:ok, consumer} = DiagnosticConsumer.start_link(device, 1_000)

    task =
      Task.async(fn ->
        {DiagnosticConsumer.status(consumer), DiagnosticConsumer.close(consumer, deadline())}
      end)

    assert Task.await(task) == {{:error, :not_diagnostic_owner}, {:error, :not_diagnostic_owner}}
    assert Process.alive?(consumer)
    assert {:ok, _} = DiagnosticConsumer.close(consumer, deadline())
  end

  test "owner death and abrupt drain loss terminate the private supervisor and blocked writer" do
    for disposition <- [:owner, :drain] do
      device = device()
      parent = self()

      owner =
        spawn(fn ->
          Process.flag(:trap_exit, true)
          {:ok, consumer} = DiagnosticConsumer.start_link(device, 1_000)
          send(consumer, {:loopex_diagnostic, %{"kind" => "ordinary"}})
          send(parent, {:consumer, consumer})
          receive do: (:stop -> :ok)
        end)

      assert_receive {:consumer, consumer}
      assert_receive {:device_write, worker, _}
      state = :sys.get_state(consumer)
      supervisor = state.supervisor
      worker_ref = Process.monitor(worker)
      supervisor_ref = Process.monitor(supervisor)
      consumer_ref = Process.monitor(consumer)

      cutoff = System.monotonic_time(:millisecond) + 1_000

      case disposition do
        :owner ->
          send(owner, :stop)

        :drain ->
          Process.exit(consumer, :kill)
          send(owner, :stop)
      end

      for {pid, monitor} <- [
            {worker, worker_ref},
            {supervisor, supervisor_ref},
            {consumer, consumer_ref}
          ] do
        remaining = max(cutoff - System.monotonic_time(:millisecond), 0)
        assert_receive {:DOWN, ^monitor, :process, ^pid, _}, remaining
      end

      assert System.monotonic_time(:millisecond) <= cutoff
    end
  end

  test "an expired shared deadline refuses to invent joined cleanup" do
    device = device()
    {:ok, consumer} = DiagnosticConsumer.start_link(device, 1_000)
    send(consumer, {:loopex_diagnostic, %{"kind" => "ordinary"}})
    assert_receive {:device_write, worker, _}
    worker_ref = Process.monitor(worker)
    started = System.monotonic_time(:millisecond)
    reply = DiagnosticConsumer.close(consumer, started - 1)
    assert System.monotonic_time(:millisecond) - started < 1_000
    assert {:error, :cleanup_unknown, final} = reply
    assert final.counts.diagnostic.unconfirmed == 1
    assert final.counts.diagnostic.emitted == 0
    assert_receive {:DOWN, ^worker_ref, :process, ^worker, _}
  end

  test "closing asks the supervisor to terminate its blocked writer before collecting joins" do
    parent = self()
    device = device()

    owner =
      spawn(fn ->
        Process.flag(:trap_exit, true)
        {:ok, consumer} = DiagnosticConsumer.start_link(device, 1_000)
        send(consumer, {:loopex_diagnostic, %{"kind" => "ordinary"}})
        send(parent, {:consumer, consumer})

        receive do
          :close ->
            send(parent, :closing)
            send(parent, {:closed, DiagnosticConsumer.close(consumer, deadline())})
        end
      end)

    assert_receive {:consumer, consumer}
    assert_receive {:device_write, worker, _}
    supervisor = :sys.get_state(consumer).supervisor
    :sys.get_state(supervisor)
    worker_ref = Process.monitor(worker)
    supervisor_ref = Process.monitor(supervisor)
    true = :erlang.suspend_process(supervisor)

    try do
      send(owner, :close)
      assert_receive :closing
      await_supervisor_shutdown(supervisor, deadline())
      assert Process.alive?(worker)
    after
      :erlang.resume_process(supervisor)
    end

    assert_receive {:closed, {:ok, final}}
    assert final.counts.diagnostic == %{emitted: 0, dropped: 0, unconfirmed: 1}
    assert_receive {:DOWN, ^worker_ref, :process, ^worker, _}
    assert_receive {:DOWN, ^supervisor_ref, :process, ^supervisor, :normal}
  end

  defp await_supervisor_shutdown(supervisor, cutoff) do
    case Process.info(supervisor, :message_queue_len) do
      {:message_queue_len, count} when count > 0 ->
        :ok

      _ ->
        assert System.monotonic_time(:millisecond) < cutoff
        Process.sleep(1)
        await_supervisor_shutdown(supervisor, cutoff)
    end
  end

  defp await_idle(consumer) do
    wait_for(consumer, fn view -> view.pending == 0 and view.active == false end)
  end

  defp await_failure(consumer) do
    wait_for(consumer, fn view -> view.failure != nil end)
  end

  defp wait_for(consumer, predicate, cutoff \\ deadline()) do
    view = DiagnosticConsumer.status(consumer)

    if predicate.(view) do
      view
    else
      assert System.monotonic_time(:millisecond) < cutoff
      Process.sleep(1)
      wait_for(consumer, predicate, cutoff)
    end
  end

  defp deadline, do: System.monotonic_time(:millisecond) + 1_000

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
