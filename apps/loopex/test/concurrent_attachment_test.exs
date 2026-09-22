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

    %{runtime: runtime}
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
