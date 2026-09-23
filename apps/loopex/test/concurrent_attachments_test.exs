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

    # A target that names no attachment at all is refused the same way, and
    # nothing the holder already has is disturbed.
    assert {:error, :stale_attachment} =
             Runtime.attach_for_holder(fixture.runtime, session_id, holder,
               request_id: "unknown-replacement",
               replace_attachment_id: "attachment-that-never-existed"
             )

    assert {:error, :empty} = Loopex.next_event(survivor)
    assert {:error, :empty} = Loopex.next_event(replacement)
    assert_maps_agree(fixture.runtime, session_id, 3)
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

  # Concept: a replacement refused because the runtime already holds its full
  # 512 attachment transactions leaves the attachment it named untouched.
  #
  # Technical depth: with the dispatcher suspended, 512 concurrent attaches
  # hold every pending transaction row in Control. A replacement naming a live
  # attachment is then refused `capacity_exceeded` before any row or borrow
  # is taken; the target still reads, the pending attaches all complete once
  # the dispatcher resumes, Control's pending map empties and both live maps
  # agree on the target plus the 512.
  @tag timeout: 120_000
  test "a replacement refused at the 512-transaction ceiling preserves its target", fixture do
    session_id = create_session(fixture.runtime, "replacement-ceiling")
    stable_holder = holder(self())
    {:ok, target} = attach(fixture.runtime, session_id, stable_holder, "target")
    {:ok, %{control: control, dispatcher: dispatcher}} = Runtime.children(fixture.runtime)
    :ok = :sys.suspend(dispatcher)

    pending =
      for index <- 1..512 do
        Task.async(fn -> attach(fixture.runtime, session_id, holder(self()), "p#{index}") end)
      end

    assert_eventually(fn -> map_size(:sys.get_state(control).pending_attachments) == 512 end)

    assert {:error, :capacity_exceeded} =
             Runtime.attach_for_holder(fixture.runtime, session_id, stable_holder,
               request_id: "refused-replacement",
               replace_attachment_id: target.attachment_id
             )

    :ok = :sys.resume(dispatcher)
    assert Enum.all?(Task.await_many(pending, 60_000), &match?({:ok, _attachment}, &1))
    assert {:error, :empty} = Loopex.next_event(target)
    assert map_size(:sys.get_state(control).pending_attachments) == 0
    assert_maps_agree(fixture.runtime, session_id, 513)
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

  test "daemon routing binds a real result to an exact live attachment", fixture do
    session_id = create_session(fixture.runtime, "daemon-route")
    stable_holder = holder(self())
    {:ok, attachment} = attach(fixture.runtime, session_id, stable_holder, "daemon-route")

    assert {:routed, route, {:accepted, "routed-command"}} =
             Runtime.command_for_daemon(attachment, %{
               type: :prompt,
               command_id: "routed-command",
               content: "one routed command"
             })

    assert :before_succession_cut = Runtime.classify_daemon_result(fixture.runtime, route)
    assert {:ok, %{kind: "user.message_appended"}} = Loopex.next_event(attachment)
  end

  test "non-prepared succession cuts routes before the successor starts", fixture do
    session_id = create_session(fixture.runtime, "succession-cut")
    stable_holder = holder(self())
    {:ok, attachment} = attach(fixture.runtime, session_id, stable_holder, "succession-cut")

    assert {:routed, route, {:accepted, "before-cut"}} =
             Runtime.command_for_daemon(attachment, %{
               type: :prompt,
               command_id: "before-cut",
               content: "classified after the cut"
             })

    assert {:ok, ^session_id} =
             Loopex.resume_session(fixture.runtime, session_id, command_id: "ordinary-successor")

    assert {:after_succession_cut, attachment_id, attachment_incarnation} =
             Runtime.classify_daemon_result(fixture.runtime, route)

    assert attachment_id == attachment.attachment_id
    assert attachment_incarnation == attachment.incarnation_id

    assert {:error, {:attachment_route_invalidated, ^attachment_id, ^attachment_incarnation}} =
             Runtime.command_for_daemon(attachment, %{
               type: :prompt,
               command_id: "after-cut",
               content: "must not reach the successor"
             })

    assert_receive {:holder_message, ^stable_holder,
                    {:loopex_attachment_invalidated, ^session_id, ^attachment_id,
                     ^attachment_incarnation, _cursor}},
                   2_000
  end

  test "prepared succession carries the route across its owner generation", fixture do
    session_id = create_session(fixture.runtime, "prepared-carry")
    stable_holder = holder(self())
    {:ok, attachment} = attach(fixture.runtime, session_id, stable_holder, "prepared-carry")

    assert {:routed, route, {:accepted, "before-prepared"}} =
             Runtime.command_for_daemon(attachment, %{
               type: :prompt,
               command_id: "before-prepared",
               content: "the attachment is carried"
             })

    assert {:ok, {:prepared, activation}} =
             Loopex.prepare_resume_session(fixture.runtime, session_id, "prepared-successor")

    assert :before_succession_cut = Runtime.classify_daemon_result(fixture.runtime, route)
    assert {:ok, %{kind: "user.message_appended"}} = Loopex.next_event(attachment)
    assert :ok = Loopex.abandon_resume(activation)
    refute_receive {:holder_message, ^stable_holder, {:loopex_attachment_invalidated, _, _, _, _}}
  end

  test "coordinator loss before and after routing has distinct dispositions", fixture do
    before_session = create_session(fixture.runtime, "coordinator-before-route")
    stable_holder = holder(self())

    {:ok, before_attachment} =
      attach(fixture.runtime, before_session, stable_holder, "coordinator-before-route")

    {:ok, %{control: control}} = Runtime.children(fixture.runtime)
    before_coordinator = :sys.get_state(control).sessions[before_session].coordinator
    before_monitor = Process.monitor(before_coordinator)
    Process.exit(before_coordinator, :kill)
    assert_receive {:DOWN, ^before_monitor, :process, ^before_coordinator, :killed}, 2_000

    assert {:error, :session_unavailable} =
             Runtime.command_for_daemon(before_attachment, %{
               type: :prompt,
               command_id: "never-called",
               content: "the route proves no call began"
             })

    after_session = create_session(fixture.runtime, "coordinator-after-route")

    {:ok, after_attachment} =
      attach(fixture.runtime, after_session, stable_holder, "coordinator-after-route")

    after_coordinator = :sys.get_state(control).sessions[after_session].coordinator
    :ok = :sys.suspend(after_coordinator)

    caller =
      Task.async(fn ->
        Runtime.command_for_daemon(after_attachment, %{
          type: :prompt,
          command_id: "reply-lost",
          content: "the route succeeded before coordinator loss"
        })
      end)

    assert_eventually(fn ->
      match?(
        {:message_queue_len, length} when length > 0,
        Process.info(after_coordinator, :message_queue_len)
      )
    end)

    after_monitor = Process.monitor(after_coordinator)
    Process.exit(after_coordinator, :kill)
    assert_receive {:DOWN, ^after_monitor, :process, ^after_coordinator, :killed}, 2_000
    assert {:error, {:admission_unknown, route}} = Task.await(caller)
    assert :before_succession_cut = Runtime.classify_daemon_result(fixture.runtime, route)
  end

  test "a routed command that loses the nested owner fence proves no admission", fixture do
    session_id = create_session(fixture.runtime, "nested-fence")
    stable_holder = holder(self())
    {:ok, attachment} = attach(fixture.runtime, session_id, stable_holder, "nested-fence")
    {:ok, %{control: control}} = Runtime.children(fixture.runtime)
    predecessor = :sys.get_state(control).sessions[session_id].coordinator
    :ok = :sys.suspend(predecessor)

    on_exit(fn ->
      if Process.alive?(predecessor) do
        try do
          :sys.resume(predecessor)
        catch
          :exit, _reason -> :ok
        end
      end
    end)

    command =
      Task.async(fn ->
        Runtime.command_for_daemon(attachment, %{
          type: :prompt,
          command_id: "lost-fence",
          content: "must not commit"
        })
      end)

    assert_eventually(fn ->
      match?(
        {:message_queue_len, length} when length > 0,
        Process.info(predecessor, :message_queue_len)
      )
    end)

    assert {:ok, ^session_id} =
             Loopex.resume_session(fixture.runtime, session_id, command_id: "fence-successor")

    :ok = :sys.resume(predecessor)
    assert {:error, {:superseded_before_admission, route}} = Task.await(command)

    assert {:after_succession_cut, attachment_id, attachment_incarnation} =
             Runtime.classify_daemon_result(fixture.runtime, route)

    assert attachment_id == attachment.attachment_id
    assert attachment_incarnation == attachment.incarnation_id
  end

  test "classification fails closed when the exact Control is lost", fixture do
    session_id = create_session(fixture.runtime, "classification-control-loss")
    stable_holder = holder(self())

    {:ok, attachment} =
      attach(fixture.runtime, session_id, stable_holder, "classification-control-loss")

    assert {:routed, route, {:accepted, "classified-before-loss"}} =
             Runtime.command_for_daemon(attachment, %{
               type: :prompt,
               command_id: "classified-before-loss",
               content: "the exact Control owns classification"
             })

    {:ok, %{control: control}} = Runtime.children(fixture.runtime)
    monitor = Process.monitor(control)
    Process.exit(control, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^control, :killed}, 2_000

    assert {:error, :runtime_unavailable} =
             Runtime.classify_daemon_result(fixture.runtime, route)
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
