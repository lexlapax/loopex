Code.require_file("support/m1_runtime_helper.exs", __DIR__)

defmodule Loopex.EventDispatcherAvailabilityTest do
  use ExUnit.Case, async: false

  alias Loopex.M1RuntimeTestStore, as: TestStore
  alias Loopex.Runtime
  alias Loopex.Runtime.EventDispatcher

  test "a held Store read does not delay unrelated session acknowledgement" do
    for entry <- [:next_event, :attachment_status, :attach_scan, :attach_prefetch] do
      fixture = fixture()
      {session_a, attachment_a} = session(fixture, "a")
      {session_b, attachment_b} = session(fixture, "b")
      prompt(attachment_a, "prompt-a")

      {reader, waiter} = held_read(fixture, session_a, attachment_a, entry)

      # The Store reply remains withheld until after the other command has
      # returned and its exact durable row has crossed the publication fence.
      # A synchronous dispatcher read cannot satisfy this ordering.
      prompt(attachment_b, "prompt-b")
      assert {:ok, event_b} = Loopex.next_event(attachment_b)
      assert event_b == hd(events(fixture, session_b))
      assert :sys.get_state(fixture.dispatcher).acknowledged[session_b] == 1

      TestStore.release(waiter)

      case entry do
        :next_event ->
          assert {:ok, event_a} = Task.await(reader)
          assert event_a == hd(events(fixture, session_a))

        :attachment_status ->
          assert {:ok, %{status: :active, queue_depth: 1}} = Task.await(reader)
          assert {:ok, event_a} = Loopex.next_event(attachment_a)
          assert event_a == hd(events(fixture, session_a))

        _attach ->
          assert {:ok, replacement} = Task.await(reader)
          assert {:ok, event_a} = Loopex.next_event(replacement)
          assert event_a == hd(events(fixture, session_a))
      end
    end
  end

  test "late reads after detach replacement or overflow cannot publish under a stale owner or cursor" do
    for disposition <- [:detach, :replacement, :owner_succession, :overflow] do
      fixture = fixture(attachment_capacity: 1)
      {session_id, attachment} = session(fixture, "late")
      prompt(attachment, "prompt")

      if disposition == :overflow do
        assert {:accepted, "abort"} =
                 Loopex.command(attachment, %{type: :abort, command_id: "abort"})

        await(fn -> :sys.get_state(fixture.dispatcher).acknowledged[session_id] == 2 end)
      end

      {reader, waiter} = held_read(fixture, session_id, attachment, :attachment_status)
      pending = :sys.get_state(fixture.dispatcher).pending_reads[attachment.attachment_id]
      worker_monitor = Process.monitor(pending.worker)

      case disposition do
        :detach ->
          # Queue invalidation first, then the real worker's completion. The
          # dispatcher must discard that already-sent result when resumed.
          :ok = :sys.suspend(fixture.dispatcher)
          1 = :erlang.trace(pending.worker, true, [:send, {:tracer, self()}])
          :ok = EventDispatcher.invalidate(fixture.runtime.supervisor, session_id)
          TestStore.release(waiter)
          worker = pending.worker
          dispatcher = fixture.dispatcher

          assert_receive {:trace, ^worker, :send, {:attachment_read_finished, _, _, _},
                          ^dispatcher},
                         2_000

          1 = :erlang.trace(worker, false, [:send])
          :ok = :sys.resume(fixture.dispatcher)
          assert {:error, :stale_attachment} = Task.await(reader)
          assert_receive {:DOWN, ^worker_monitor, :process, _, :killed}, 2_000
          assert {:error, :stale_attachment} = Loopex.next_event(attachment)

          assert {:ok, replacement} =
                   Loopex.attach(fixture.runtime, session_id, after_event_sequence: 0)

          assert drain(replacement) == events(fixture, session_id)

        replacement_kind when replacement_kind in [:replacement, :owner_succession] ->
          if replacement_kind == :owner_succession do
            {:ok, %{control: control}} = Runtime.children(fixture.runtime)
            before = :sys.get_state(control).sessions[session_id]

            assert {:ok, ^session_id} =
                     Loopex.resume_session(fixture.runtime, session_id, command_id: "successor")

            after_succession = :sys.get_state(control).sessions[session_id]
            assert after_succession.coordinator != before.coordinator
            assert after_succession.owner.owner_epoch == before.owner.owner_epoch + 1
          end

          assert {:ok, replacement} =
                   Loopex.attach(fixture.runtime, session_id, after_event_sequence: 0)

          assert {:error, :stale_attachment} = Task.await(reader)
          assert_receive {:DOWN, ^worker_monitor, :process, _, :killed}, 2_000
          TestStore.release(waiter)
          assert {:error, :stale_attachment} = Loopex.next_event(attachment)
          assert drain(replacement) == events(fixture, session_id)

        :overflow ->
          TestStore.release(waiter)

          assert {:ok, %{status: {:disconnected, :overflow}, cursor: 0, queue_depth: 0}} =
                   Task.await(reader)

          assert_receive {:DOWN, ^worker_monitor, :process, _, :normal}, 2_000
          assert {:disconnected, 0} = Loopex.next_event(attachment)

          # A duplicate completion retains the exact old read token and bytes.
          # Its worker no longer owns the disconnected attachment's cursor.
          send(fixture.dispatcher, {
            :attachment_read_finished,
            attachment.attachment_id,
            pending.read_id,
            %{pending.attachment | status: :active}
          })

          assert {:disconnected, 0} = Loopex.next_event(attachment)

          assert {:ok, replacement} =
                   Loopex.attach(fixture.runtime, session_id, after_event_sequence: 0)

          assert drain(replacement) == events(fixture, session_id)
      end

      assert :sys.get_state(fixture.dispatcher).pending_reads == %{}
    end

    # Concept: losing an attach caller stops its reader before it gets a handle.
    # Technical depth: hold both the initial scan and the later queue prefetch,
    # then observe the exact worker's death before starting a replacement attach.
    for entry <- [:attach_scan, :attach_prefetch] do
      fixture = fixture()
      {session_id, attachment} = session(fixture, "lost-attach-caller")
      prompt(attachment, "prompt")
      {caller, waiter} = held_read(fixture, session_id, attachment, entry)
      state = :sys.get_state(fixture.dispatcher)

      pending =
        case entry do
          :attach_scan -> state.pending_scans
          :attach_prefetch -> state.pending_reads
        end
        |> Map.values()

      assert [%{worker: worker}] = pending
      assert Process.alive?(worker)
      monitor = Process.monitor(worker)
      Task.shutdown(caller, :brutal_kill)
      assert_receive {:DOWN, ^monitor, :process, ^worker, :killed}, 2_000

      state = :sys.get_state(fixture.dispatcher)
      assert state.pending_scans == %{}
      assert state.pending_reads == %{}
      assert state.read_monitors == %{}
      TestStore.release(waiter)

      assert {:ok, replacement} =
               Loopex.attach(fixture.runtime, session_id, after_event_sequence: 0)

      assert drain(replacement) == events(fixture, session_id)
    end
  end

  test "read callers serialize per attachment and caller loss releases their worker" do
    fixture = fixture()
    {session_id, attachment} = session(fixture, "readers")
    prompt(attachment, "prompt")
    {first, waiter} = held_read(fixture, session_id, attachment, :next_event)
    readers = for _index <- 1..16, do: Task.async(fn -> Loopex.next_event(attachment) end)
    pending = :sys.get_state(fixture.dispatcher).pending_reads[attachment.attachment_id]

    await(fn ->
      {:monitored_by, monitors} = Process.info(pending.worker, :monitored_by)
      Enum.all?(readers, &(&1.pid in monitors))
    end)

    assert map_size(:sys.get_state(fixture.dispatcher).pending_reads) == 1
    assert map_size(:sys.get_state(fixture.dispatcher).read_monitors) == 1
    monitor = Process.monitor(pending.worker)
    Task.shutdown(first, :brutal_kill)
    assert_receive {:DOWN, ^monitor, :process, _, :killed}, 2_000
    delivered = Enum.map(readers, &Task.await/1)

    assert Enum.filter(delivered, &match?({:ok, _}, &1)) == [
             {:ok, hd(events(fixture, session_id))}
           ]

    assert Enum.count(delivered, &(&1 == {:error, :empty})) == 15
    TestStore.release(waiter)
    assert {:error, :empty} = Loopex.next_event(attachment)
    assert :sys.get_state(fixture.dispatcher).pending_reads == %{}
  end

  test "a timed out status caller cancels its read while the caller remains alive" do
    fixture = fixture()
    {session_id, attachment} = session(fixture, "timeout")
    prompt(attachment, "prompt")
    TestStore.block_next_event_read(fixture.store, self())
    parent = self()

    caller =
      spawn_link(fn ->
        send(parent, {:status_result, Loopex.attachment_status(attachment)})
        receive do: (:finish -> :ok)
      end)

    assert_receive {:event_history_read, waiter, _, ^session_id, _}, 2_000
    pending = :sys.get_state(fixture.dispatcher).pending_reads[attachment.attachment_id]
    monitor = Process.monitor(pending.worker)
    assert_receive {:status_result, {:error, :runtime_unavailable}}, 7_000
    assert Process.alive?(caller)
    assert_receive {:DOWN, ^monitor, :process, _, :killed}, 2_000
    assert :sys.get_state(fixture.dispatcher).pending_reads == %{}
    assert :sys.get_state(fixture.dispatcher).read_monitors == %{}
    TestStore.release(waiter)
    assert {:ok, event} = Loopex.next_event(attachment)
    assert event == hd(events(fixture, session_id))
    send(caller, :finish)
  end

  test "a newly installed fence rejects overflow inferred from an unacknowledged extra row" do
    fixture = fixture(attachment_capacity: 1)
    {session_id, attachment} = session(fixture, "fence")
    prompt(attachment, "prompt")

    assert {:accepted, "abort"} =
             Loopex.command(attachment, %{type: :abort, command_id: "abort"})

    await(fn -> :sys.get_state(fixture.dispatcher).acknowledged[session_id] == 2 end)
    :ok = EventDispatcher.release_fence(fixture.runtime.supervisor, session_id)
    refute Map.has_key?(:sys.get_state(fixture.dispatcher).acknowledged, session_id)
    {reader, waiter} = held_read(fixture, session_id, attachment, :attachment_status)
    :ok = EventDispatcher.acknowledge(fixture.runtime.supervisor, session_id, 1)
    TestStore.release(waiter)

    assert {:ok, %{status: :active, queue_depth: 1}} = Task.await(reader)
    assert {:ok, first} = Loopex.next_event(attachment)
    assert first == hd(events(fixture, session_id))
    assert {:error, :empty} = Loopex.next_event(attachment)

    :ok = EventDispatcher.acknowledge(fixture.runtime.supervisor, session_id, 2)
    assert {:ok, second} = Loopex.next_event(attachment)
    assert second == List.last(events(fixture, session_id))
  end

  defp fixture(options \\ []) do
    {store_pid, store} = TestStore.start_store()

    {:ok, runtime} =
      Loopex.start_link(
        Keyword.merge(
          [context_token_budget: 8_192, runtime_id: "dispatcher-availability", store: store],
          options
        )
      )

    {:ok, %{dispatcher: dispatcher}} = Runtime.children(runtime)

    on_exit(fn ->
      resume_dispatcher(dispatcher)
      if Runtime.alive?(runtime), do: Loopex.stop(runtime)
      if Process.alive?(store_pid), do: GenServer.stop(store_pid)
    end)

    %{runtime: runtime, store: store_pid, dispatcher: dispatcher}
  end

  defp resume_dispatcher(dispatcher) do
    try do
      :sys.resume(dispatcher)
    catch
      :exit, {:noproc, _call} -> :ok
      :exit, {:normal, _call} -> :ok
      :exit, {:shutdown, _call} -> :ok
    end
  end

  defp session(fixture, id) do
    {:ok, session_id} = Loopex.create_session(fixture.runtime, %{}, command_id: id)
    {:ok, attachment} = Loopex.attach(fixture.runtime, session_id, after_event_sequence: 0)
    {session_id, attachment}
  end

  defp prompt(attachment, id) do
    assert {:accepted, ^id} =
             Loopex.command(attachment, %{type: :prompt, command_id: id, content: "content"})
  end

  defp held_read(fixture, session_id, attachment, entry) do
    TestStore.block_next_event_read(fixture.store, self())

    reader =
      Task.async(fn ->
        case entry do
          :next_event -> Loopex.next_event(attachment)
          :attachment_status -> Loopex.attachment_status(attachment)
          _attach -> Loopex.attach(fixture.runtime, session_id, after_event_sequence: 0)
        end
      end)

    assert_receive {:event_history_read, waiter, _, ^session_id, _}, 2_000

    if entry == :attach_prefetch do
      [pending] = Map.values(:sys.get_state(fixture.dispatcher).pending_scans)
      monitor = Process.monitor(pending.worker)
      :ok = :sys.suspend(fixture.dispatcher)
      TestStore.release(waiter)
      assert_receive {:DOWN, ^monitor, :process, _, :normal}, 2_000
      TestStore.block_next_event_read(fixture.store, self())
      :ok = :sys.resume(fixture.dispatcher)
      assert_receive {:event_history_read, prefetch_waiter, _, ^session_id, _}, 2_000
      {reader, prefetch_waiter}
    else
      {reader, waiter}
    end
  end

  defp events(fixture, session_id),
    do: TestStore.inspect_state(fixture.store).sessions[session_id].events

  defp drain(attachment, events \\ []) do
    case Loopex.next_event(attachment) do
      {:ok, event} -> drain(attachment, [event | events])
      {:error, :empty} -> Enum.reverse(events)
    end
  end

  defp await(condition, attempts \\ 400)
  defp await(_condition, 0), do: flunk("expected dispatcher transition did not complete")

  defp await(condition, attempts) do
    if condition.(), do: :ok, else: Process.sleep(5) && await(condition, attempts - 1)
  end
end
