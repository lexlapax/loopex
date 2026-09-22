Code.require_file("support/m1_runtime_helper.exs", __DIR__)

defmodule Loopex.ConcurrentAttachmentTest do
  use ExUnit.Case, async: true

  alias Loopex.M1RuntimeTestStore
  alias Loopex.Runtime

  setup do
    {store_pid, store} = M1RuntimeTestStore.start_store()

    {:ok, runtime} =
      Loopex.start_link(
        context_token_budget: 8_192,
        runtime_id: "concurrent-attachments",
        store: store
      )

    on_exit(fn ->
      if Runtime.alive?(runtime), do: Loopex.stop(runtime)
      if Process.alive?(store_pid), do: GenServer.stop(store_pid)
    end)

    %{runtime: runtime, store: store_pid}
  end

  test "one holder owns several attachments while another holder remains independent", fixture do
    session_id = create_session(fixture.runtime, "several")
    first_holder = holder(self())
    second_holder = holder(self())

    {:ok, first} = attach(fixture.runtime, session_id, first_holder, "first")
    {:ok, second} = attach(fixture.runtime, session_id, first_holder, "second")
    {:ok, independent} = attach(fixture.runtime, session_id, second_holder, "independent")

    assert MapSet.new(ids([first, second, independent])) |> MapSet.size() == 3
    assert_maps_agree(fixture.runtime, session_id, 3)

    assert {:accepted, "shared-event"} =
             Loopex.command(first, %{
               type: :prompt,
               command_id: "shared-event",
               content: "visible to every attachment"
             })

    assert {:ok, %{event_id: event_id}} = Loopex.next_event(first)
    assert {:ok, %{event_id: ^event_id}} = Loopex.next_event(second)
    assert {:ok, %{event_id: ^event_id}} = Loopex.next_event(independent)

    assert :ok = Runtime.release_holder(fixture.runtime, first_holder)
    assert :ok = Runtime.release_holder(fixture.runtime, first_holder)
    assert {:error, :stale_attachment} = Loopex.next_event(first)
    assert {:error, :stale_attachment} = Loopex.next_event(second)
    assert {:error, :empty} = Loopex.next_event(independent)
    assert_maps_agree(fixture.runtime, session_id, 1)
  end

  test "replacement removes only the named attachment for the same holder", fixture do
    session_id = create_session(fixture.runtime, "replacement")
    holder = holder(self())
    other_holder = holder(self())

    {:ok, first} = attach(fixture.runtime, session_id, holder, "first")
    {:ok, survivor} = attach(fixture.runtime, session_id, holder, "survivor")
    {:ok, independent} = attach(fixture.runtime, session_id, other_holder, "independent")

    assert {:ok, replacement} =
             Runtime.attach_for_holder(fixture.runtime, session_id, holder,
               request_id: "replacement",
               after_event_sequence: 0,
               replace_attachment_id: first.attachment_id
             )

    assert {:error, :stale_attachment} = Loopex.next_event(first)
    assert {:error, :empty} = Loopex.next_event(survivor)
    assert {:error, :empty} = Loopex.next_event(independent)
    assert {:error, :empty} = Loopex.next_event(replacement)
    assert_maps_agree(fixture.runtime, session_id, 3)

    assert {:error, :stale_attachment} =
             Runtime.attach_for_holder(fixture.runtime, session_id, other_holder,
               request_id: "foreign-replacement",
               replace_attachment_id: survivor.attachment_id
             )
  end

  test "a relay can attach for a stable holder without becoming the owner", fixture do
    session_id = create_session(fixture.runtime, "relay")
    stable_holder = holder(self())
    parent = self()

    relay =
      spawn(fn ->
        send(
          parent,
          {:relay_result,
           Runtime.attach_for_holder(
             fixture.runtime,
             session_id,
             stable_holder,
             request_id: "relayed"
           )}
        )
      end)

    relay_monitor = Process.monitor(relay)
    assert_receive {:relay_result, {:ok, attachment}}, 2_000
    assert_receive {:DOWN, ^relay_monitor, :process, ^relay, :normal}, 2_000
    assert {:error, :empty} = Loopex.next_event(attachment)

    public_relay =
      spawn(fn ->
        send(parent, {:public_result, Loopex.attach(fixture.runtime, session_id)})
      end)

    public_monitor = Process.monitor(public_relay)
    assert_receive {:public_result, {:ok, public_attachment}}, 2_000
    assert_receive {:DOWN, ^public_monitor, :process, ^public_relay, :normal}, 2_000

    assert_eventually(fn ->
      Loopex.next_event(public_attachment) == {:error, :stale_attachment}
    end)

    assert {:error, :empty} = Loopex.next_event(attachment)
  end

  test "holder death removes its full set and preserves another holder", fixture do
    session_id = create_session(fixture.runtime, "holder-death")
    doomed = holder(self())
    survivor = holder(self())

    {:ok, doomed_first} = attach(fixture.runtime, session_id, doomed, "doomed-first")
    {:ok, doomed_second} = attach(fixture.runtime, session_id, doomed, "doomed-second")
    {:ok, live} = attach(fixture.runtime, session_id, survivor, "live")

    send(doomed, :stop)

    assert_eventually(fn ->
      Loopex.next_event(doomed_first) == {:error, :stale_attachment} and
        Loopex.next_event(doomed_second) == {:error, :stale_attachment}
    end)

    assert {:error, :empty} = Loopex.next_event(live)
    assert_maps_agree(fixture.runtime, session_id, 1)
  end

  test "an exact concurrent repetition joins one pending transaction", fixture do
    session_id = create_session(fixture.runtime, "pending-repetition")
    stable_holder = holder(self())
    M1RuntimeTestStore.block_next_event_read(fixture.store, self())

    first =
      Task.async(fn ->
        attach(fixture.runtime, session_id, stable_holder, "same-request")
      end)

    assert_receive {:event_history_read, waiter, _, ^session_id, _}, 2_000

    second =
      Task.async(fn ->
        attach(fixture.runtime, session_id, stable_holder, "same-request")
      end)

    assert_eventually(fn ->
      {:ok, %{control: control, dispatcher: dispatcher}} = Runtime.children(fixture.runtime)
      control_state = :sys.get_state(control)
      dispatcher_state = :sys.get_state(dispatcher)

      map_size(control_state.pending_attachments) == 1 and
        map_size(dispatcher_state.staged_attachments) == 1 and
        control_state.pending_attachments
        |> Map.values()
        |> hd()
        |> then(&(map_size(&1.callers) == 2))
    end)

    assert {:error, :attachment_request_conflict} =
             Runtime.attach_for_holder(fixture.runtime, session_id, stable_holder,
               request_id: "same-request",
               after_event_sequence: 1
             )

    M1RuntimeTestStore.release(waiter)
    assert {:ok, first_attachment} = Task.await(first)
    assert {:ok, second_attachment} = Task.await(second)
    assert first_attachment == second_attachment
    assert_maps_agree(fixture.runtime, session_id, 1)
  end

  test "initiating caller loss drops only its reply route", fixture do
    session_id = create_session(fixture.runtime, "caller-loss")
    stable_holder = holder(self())
    M1RuntimeTestStore.block_next_event_read(fixture.store, self())

    caller =
      Task.async(fn ->
        attach(fixture.runtime, session_id, stable_holder, "caller-loss")
      end)

    assert_receive {:event_history_read, waiter, _, ^session_id, _}, 2_000
    Task.shutdown(caller, :brutal_kill)
    M1RuntimeTestStore.release(waiter)

    assert_eventually(fn ->
      {:ok, %{control: control, dispatcher: dispatcher}} = Runtime.children(fixture.runtime)
      control_state = :sys.get_state(control)
      dispatcher_state = :sys.get_state(dispatcher)

      map_size(control_state.pending_attachments) == 0 and
        map_size(dispatcher_state.staged_attachments) == 0 and
        map_size(control_state.sessions[session_id].attachments) == 1 and
        map_size(dispatcher_state.attachments) == 1
    end)

    assert :ok = Runtime.release_holder(fixture.runtime, stable_holder)
    assert_maps_agree(fixture.runtime, session_id, 0)
  end

  test "holder loss before publication cleans both owners before replying", fixture do
    session_id = create_session(fixture.runtime, "holder-loss-before-publication")
    stable_holder = holder(self())
    M1RuntimeTestStore.block_next_event_read(fixture.store, self())

    caller =
      Task.async(fn ->
        attach(fixture.runtime, session_id, stable_holder, "holder-loss")
      end)

    assert_receive {:event_history_read, waiter, _, ^session_id, _}, 2_000
    send(stable_holder, :stop)

    assert {:error, :holder_unavailable} = Task.await(caller)
    M1RuntimeTestStore.release(waiter)

    assert_eventually(fn ->
      {:ok, %{control: control, dispatcher: dispatcher}} = Runtime.children(fixture.runtime)
      control_state = :sys.get_state(control)
      dispatcher_state = :sys.get_state(dispatcher)

      control_state.pending_attachments == %{} and
        dispatcher_state.staged_attachments == %{} and
        control_state.sessions[session_id].attachments == %{} and
        dispatcher_state.attachments == %{}
    end)
  end

  test "concurrent replacements cannot borrow the same target", fixture do
    session_id = create_session(fixture.runtime, "replacement-exclusion")
    stable_holder = holder(self())
    {:ok, target} = attach(fixture.runtime, session_id, stable_holder, "target")
    M1RuntimeTestStore.block_next_event_read(fixture.store, self())

    first =
      Task.async(fn ->
        Runtime.attach_for_holder(fixture.runtime, session_id, stable_holder,
          request_id: "replacement-one",
          replace_attachment_id: target.attachment_id
        )
      end)

    assert_receive {:event_history_read, waiter, _, ^session_id, _}, 2_000

    assert {:error, :attachment_request_conflict} =
             Runtime.attach_for_holder(fixture.runtime, session_id, stable_holder,
               request_id: "replacement-two",
               replace_attachment_id: target.attachment_id
             )

    M1RuntimeTestStore.release(waiter)
    assert {:ok, replacement} = Task.await(first)
    assert {:error, :stale_attachment} = Loopex.next_event(target)
    assert {:error, :empty} = Loopex.next_event(replacement)
    assert_maps_agree(fixture.runtime, session_id, 1)
  end

  test "dispatcher replacement resolves a pending attachment and admits a fresh one", fixture do
    session_id = create_session(fixture.runtime, "dispatcher-replacement")
    stable_holder = holder(self())
    M1RuntimeTestStore.block_next_event_read(fixture.store, self())

    caller =
      Task.async(fn ->
        attach(fixture.runtime, session_id, stable_holder, "predecessor")
      end)

    assert_receive {:event_history_read, waiter, _, ^session_id, _}, 2_000
    {:ok, %{dispatcher: predecessor}} = Runtime.children(fixture.runtime)
    Process.exit(predecessor, :kill)

    assert {:error, :attachment_superseded} = Task.await(caller)
    M1RuntimeTestStore.release(waiter)

    assert_eventually(fn ->
      match?(
        {:ok, %{dispatcher: successor}} when successor != predecessor,
        Runtime.children(fixture.runtime)
      )
    end)

    assert {:ok, successor_attachment} =
             attach(fixture.runtime, session_id, stable_holder, "successor")

    assert {:error, :empty} = Loopex.next_event(successor_attachment)
    assert_maps_agree(fixture.runtime, session_id, 1)
  end

  defp create_session(runtime, command_id) do
    assert {:ok, session_id} = Loopex.create_session(runtime, %{}, command_id: command_id)
    session_id
  end

  defp attach(runtime, session_id, holder, request_id) do
    Runtime.attach_for_holder(runtime, session_id, holder,
      request_id: request_id,
      after_event_sequence: 0
    )
  end

  defp ids(attachments), do: Enum.map(attachments, & &1.attachment_id)

  defp assert_maps_agree(runtime, session_id, expected_count) do
    {:ok, %{control: control, dispatcher: dispatcher}} = Runtime.children(runtime)
    control_state = :sys.get_state(control)
    dispatcher_state = :sys.get_state(dispatcher)
    control_ids = control_state.sessions[session_id].attachments |> Map.keys() |> MapSet.new()

    dispatcher_ids =
      dispatcher_state.attachments
      |> Enum.filter(fn {_id, attachment} -> attachment.session_id == session_id end)
      |> Enum.map(&elem(&1, 0))
      |> MapSet.new()

    assert MapSet.size(control_ids) == expected_count
    assert control_ids == dispatcher_ids
  end

  defp holder(observer) do
    spawn_link(fn -> holder_loop(observer) end)
  end

  defp holder_loop(observer) do
    receive do
      :stop ->
        :ok

      message ->
        send(observer, {:holder_message, self(), message})
        holder_loop(observer)
    end
  end

  defp assert_eventually(assertion, attempts \\ 200)
  defp assert_eventually(_assertion, 0), do: flunk("condition did not become true")

  defp assert_eventually(assertion, attempts) do
    if assertion.() do
      :ok
    else
      Process.sleep(5)
      assert_eventually(assertion, attempts - 1)
    end
  end
end
