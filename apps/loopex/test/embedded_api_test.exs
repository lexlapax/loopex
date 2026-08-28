Code.require_file("support/m1_runtime_helper.exs", __DIR__)

defmodule Loopex.EmbeddedApiTest do
  use ExUnit.Case, async: false

  alias Loopex.Attachment
  alias Loopex.M1RuntimeTestStore
  alias Loopex.Runtime
  alias Loopex.Runtime.SessionState

  test "progress and diagnostics never carry durable truth" do
    fixture = start_fixture("transient-runtime", progress_to: self(), diagnostics_to: self())
    on_exit(fn -> stop_fixture(fixture) end)

    session_id = create_session!(fixture, "create-transient")

    {:ok, attachment} =
      Loopex.attach(fixture.runtime, session_id,
        request_id: "transient-attachment",
        after_event_sequence: 0
      )

    before = durable_store_projection(M1RuntimeTestStore.inspect_state(fixture.store_pid))

    assert :ok = Loopex.progress(attachment, %{"step" => 1, "message" => "working"})
    assert :ok = Loopex.diagnostic(fixture.runtime, %{"component" => "runtime", "level" => 2})

    assert_receive {:loopex_progress, ^session_id, %{"step" => 1, "message" => "working"}}

    assert_receive {:loopex_diagnostic, %{"component" => "runtime", "level" => 2}}

    assert {:error, :invalid_progress} = Loopex.progress(attachment, self())
    assert {:error, :invalid_diagnostic} = Loopex.diagnostic(fixture.runtime, make_ref())

    assert before ==
             durable_store_projection(M1RuntimeTestStore.inspect_state(fixture.store_pid))

    {:ok, %{dispatcher: dispatcher}} = Runtime.children(fixture.runtime)
    Process.exit(dispatcher, :kill)

    eventually(fn ->
      match?(
        {:ok, %{dispatcher: replacement}} when replacement != dispatcher,
        Runtime.children(fixture.runtime)
      )
    end)

    refute_receive {:loopex_progress, _, _}, 20
    refute_receive {:loopex_diagnostic, _}, 20
    assert {:error, :stale_attachment} = Loopex.next_event(attachment)

    {:ok, replacement} =
      Loopex.attach(fixture.runtime, session_id,
        request_id: "transient-attachment",
        after_event_sequence: 0
      )

    assert Attachment.routing(replacement) != Attachment.routing(attachment)

    assert {:accepted, "after-transient-restart"} =
             Loopex.command(replacement, %{
               type: :prompt,
               command_id: "after-transient-restart",
               content: "durable"
             })
  end

  test "committed events survive delivery with stable identity" do
    fixture = start_fixture("delivery-runtime", attachment_capacity: 1)
    on_exit(fn -> stop_fixture(fixture) end)

    session_id = create_session!(fixture, "create-delivery")

    {:ok, command_attachment} =
      Loopex.attach(fixture.runtime, session_id, after_event_sequence: 0)

    assert {:accepted, "delivery-prompt"} =
             Loopex.command(command_attachment, %{
               type: :prompt,
               command_id: "delivery-prompt",
               content: "stable bytes"
             })

    {:ok, attachment} = Loopex.attach(fixture.runtime, session_id, after_event_sequence: 0)
    stored = M1RuntimeTestStore.inspect_state(fixture.store_pid).sessions[session_id].events
    assert Enum.map(stored, & &1.event_sequence) == [1, 2]

    :ok = M1RuntimeTestStore.block_next_event_read(fixture.store_pid, self())

    first_delivery = Task.async(fn -> Loopex.next_event(attachment) end)

    assert {:ok, {:ok, first_event}} = Task.yield(first_delivery, 200)
    assert first_event == Enum.at(stored, 0)
    refute_receive {:event_history_read, _, _, ^session_id, _}, 20

    delivery = Task.async(fn -> Loopex.next_event(attachment) end)

    assert_receive {:event_history_read, waiter, _store, ^session_id, committed_events}
    assert Enum.map(committed_events, & &1.event_sequence) == [2]

    {:ok, %{dispatcher: dispatcher}} = Runtime.children(fixture.runtime)
    Process.exit(dispatcher, :kill)
    M1RuntimeTestStore.release(waiter)
    assert {:error, :runtime_unavailable} = Task.await(delivery)

    eventually(fn ->
      match?(
        {:ok, %{dispatcher: replacement}} when replacement != dispatcher,
        Runtime.children(fixture.runtime)
      )
    end)

    assert {:error, :stale_attachment} = Loopex.next_event(attachment)

    {:ok, resumed} = Loopex.attach(fixture.runtime, session_id, after_event_sequence: 1)
    redelivered = drain_events(resumed)

    assert redelivered == Enum.drop(stored, 1)

    assert Enum.map(redelivered, &{&1.event_sequence, &1.event_id, &1.kind}) ==
             Enum.map(committed_events, &{&1.event_sequence, &1.event_id, &1.kind})
  end

  test "attachment snapshots at N and streams events after N without a gap" do
    fixture = start_fixture("snapshot-runtime")
    on_exit(fn -> stop_fixture(fixture) end)

    session_id = create_session!(fixture, "create-snapshot")
    {:ok, original} = Loopex.attach(fixture.runtime, session_id, after_event_sequence: 0)

    assert {:accepted, "before-snapshot"} =
             Loopex.command(original, %{
               type: :prompt,
               command_id: "before-snapshot",
               content: "before"
             })

    assert Enum.map(drain_events(original), & &1.event_sequence) == [1, 2]

    assert {:accepted, "finish-before-snapshot"} =
             Loopex.command(original, %{type: :abort, command_id: "finish-before-snapshot"})

    assert [%{event_sequence: 3, kind: "run.finished"}] = drain_events(original)
    :ok = M1RuntimeTestStore.block_next_event_read(fixture.store_pid, self())

    attaching =
      Task.async(fn ->
        Loopex.attach(fixture.runtime, session_id,
          request_id: "snapshot-race",
          after_event_sequence: 3
        )
      end)

    assert_receive {:event_history_read, waiter, _store, ^session_id, scanned_at_three}
    assert Enum.map(scanned_at_three, & &1.event_sequence) == [1, 2, 3]

    assert {:accepted, "during-snapshot"} =
             Loopex.command(original, %{
               type: :prompt,
               command_id: "during-snapshot",
               content: "after anchor"
             })

    M1RuntimeTestStore.release(waiter)
    assert {:ok, replacement} = Task.await(attaching)

    assert %{session_id: ^session_id, event_sequence: 3, active_run_id: nil} =
             Loopex.snapshot(replacement)

    streamed = drain_events(replacement)
    assert Enum.map(streamed, & &1.event_sequence) == [4, 5]
    assert Enum.map(streamed, & &1.kind) == ["user.message_appended", "run.started"]

    assert {:error, :stale_attachment} = Loopex.next_event(original)

    stored = M1RuntimeTestStore.inspect_state(fixture.store_pid).sessions[session_id].events
    assert Enum.map(stored, & &1.event_sequence) == [1, 2, 3, 4, 5]
    assert scanned_at_three ++ streamed == stored

    paged = start_fixture("paged-snapshot-runtime")

    try do
      paged_session = create_session!(paged, "create-paged-snapshot")
      {:ok, command_attachment} = Loopex.attach(paged.runtime, paged_session)

      Enum.each(1..342, fn index ->
        prompt_id = "paged-prompt-#{index}"
        abort_id = "paged-abort-#{index}"

        assert {:accepted, ^prompt_id} =
                 Loopex.command(command_attachment, %{
                   type: :prompt,
                   command_id: prompt_id,
                   content: "bounded"
                 })

        assert {:accepted, ^abort_id} =
                 Loopex.command(command_attachment, %{
                   type: :abort,
                   command_id: abort_id
                 })
      end)

      paged_events =
        M1RuntimeTestStore.inspect_state(paged.store_pid).sessions[paged_session].events

      assert length(paged_events) == 1_026

      {:ok, paged_attachment} = Loopex.attach(paged.runtime, paged_session)

      assert %{
               session_id: ^paged_session,
               event_sequence: 1_026,
               active_run_id: nil
             } = Loopex.snapshot(paged_attachment)

      reads =
        paged.store_pid
        |> M1RuntimeTestStore.inspect_state()
        |> Map.fetch!(:event_reads)
        |> Enum.filter(&(&1.session_id == paged_session))

      assert Enum.all?(reads, &(&1.limit <= 1_024))

      assert Enum.any?(reads, &match?(%{after_sequence: 0, returned: 1_024}, &1))
      assert Enum.any?(reads, &match?(%{after_sequence: 1_024, returned: 2}, &1))
      assert Enum.any?(reads, &match?(%{after_sequence: 1_026, returned: 0}, &1))

      {:ok, scan} = SessionState.start_snapshot_scan(paged_session, nil)

      scan =
        paged_events
        |> Enum.chunk_every(257)
        |> Enum.reduce(scan, fn page, current ->
          {:ok, next} = SessionState.scan_snapshot_page(current, page)
          assert :erlang.external_size(next) < 1_024
          next
        end)

      assert {:ok, %{tail: 1_026, snapshot: snapshot}} =
               SessionState.finish_snapshot_scan(scan)

      assert snapshot == Loopex.snapshot(paged_attachment)
    after
      stop_fixture(paged)
    end
  end

  test "a full attachment queue disconnects with a durable-history cursor and resumes gap-free after runtime restart without persisted attachment state" do
    fixture = start_fixture("backpressure-runtime", attachment_capacity: 1)
    on_exit(fn -> stop_fixture(fixture) end)

    session_id = create_session!(fixture, "create-backpressure")
    {:ok, first} = Loopex.attach(fixture.runtime, session_id, after_event_sequence: 0)

    assert {:accepted, "overflow-prompt"} =
             Loopex.command(first, %{
               type: :prompt,
               command_id: "overflow-prompt",
               content: "two events"
             })

    eventually(fn ->
      match?(
        {:ok,
         %{
           status: {:disconnected, :overflow},
           cursor: 0,
           queue_depth: 0,
           max_queue_depth: 1,
           capacity: 1
         }},
        Loopex.attachment_status(first)
      )
    end)

    assert {:disconnected, 0} = Loopex.next_event(first)

    {:ok, live} = Loopex.attach(fixture.runtime, session_id, after_event_sequence: 0)
    assert Enum.map(drain_events(live), & &1.event_sequence) == [1, 2]

    assert {:accepted, "overflow-abort"} =
             Loopex.command(live, %{type: :abort, command_id: "overflow-abort"})

    # The abort's acceptance says it was admitted, not that the run has ended.
    # ADR 0009 orders the admission before the cleanup, so the ending is a second
    # transaction that lands once the cleanup answers -- which is what this waits
    # for rather than assuming it has already happened.
    ended =
      Enum.reduce_while(1..400, [], fn _attempt, acc ->
        case acc ++ drain_events(live) do
          [] -> Process.sleep(5) && {:cont, []}
          drained -> {:halt, drained}
        end
      end)

    assert [%{event_sequence: 3}] = ended

    assert {:accepted, "second-prompt"} =
             Loopex.command(live, %{
               type: :prompt,
               command_id: "second-prompt",
               content: "after reconnect"
             })

    expected = M1RuntimeTestStore.inspect_state(fixture.store_pid).sessions[session_id].events
    assert Enum.map(expected, & &1.event_sequence) == [1, 2, 3, 4, 5]

    assert {:ok, %{status: {:disconnected, :overflow}, cursor: 3, max_queue_depth: 1}} =
             Loopex.attachment_status(live)

    prior_owner_tx = current_owner_transaction_id(fixture.runtime, session_id)
    assert :ok = Loopex.stop(fixture.runtime)

    {:ok, restarted} =
      Loopex.start_link(
        runtime_id: fixture.runtime_id,
        store: fixture.store,
        attachment_capacity: 1
      )

    restarted_fixture = %{fixture | runtime: restarted}

    assert {:ok, ^session_id} =
             Loopex.resume_session(restarted, session_id, command_id: "resume-after-restart")

    assert {session_id, "session", prior_owner_tx} in M1RuntimeTestStore.inspect_state(
             fixture.store_pid
           ).status_queries

    assert {:error, :runtime_unavailable} = Loopex.next_event(live)

    {:ok, after_restart} = Loopex.attach(restarted, session_id, after_event_sequence: 3)
    assert Loopex.snapshot(after_restart).event_sequence == 3
    assert drain_events(after_restart) == Enum.drop(expected, 3)

    assert {:ok, %{status: :active, cursor: 5, max_queue_depth: 1, capacity: 1}} =
             Loopex.attachment_status(after_restart)

    records = M1RuntimeTestStore.inspect_state(fixture.store_pid).sessions[session_id].records

    refute Enum.any?(records, fn row ->
             row.payload.kind in ["attachment", "subscriber", "cursor"]
           end)

    stop_fixture(restarted_fixture)
  end

  defp start_fixture(runtime_id, options \\ []) do
    {store_pid, store} = M1RuntimeTestStore.start_store(label: runtime_id)

    runtime_options =
      options
      |> Keyword.put(:runtime_id, runtime_id)
      |> Keyword.put(:store, store)

    {:ok, runtime} = Loopex.start_link(runtime_options)

    %{
      runtime: runtime,
      runtime_id: runtime_id,
      store: store,
      store_pid: store_pid
    }
  end

  defp stop_fixture(fixture) do
    if Runtime.alive?(fixture.runtime), do: Loopex.stop(fixture.runtime)
    if Process.alive?(fixture.store_pid), do: GenServer.stop(fixture.store_pid)
  end

  defp create_session!(fixture, command_id) do
    assert {:ok, session_id} = Loopex.create_session(fixture.runtime, %{}, command_id: command_id)
    session_id
  end

  defp durable_store_projection(state) do
    Map.take(state, [:next_session, :runtime_commands, :sessions, :resolutions])
  end

  defp current_owner_transaction_id(runtime, session_id) do
    {:ok, %{control: control}} = Runtime.children(runtime)
    :sys.get_state(control).sessions[session_id].owner.transaction_id
  end

  defp drain_events(attachment, accumulated \\ []) do
    case Loopex.next_event(attachment) do
      {:ok, event} -> drain_events(attachment, [event | accumulated])
      {:error, :empty} -> Enum.reverse(accumulated)
    end
  end

  defp eventually(assertion, attempts \\ 400)

  defp eventually(assertion, attempts) when attempts > 0 do
    if assertion.() do
      :ok
    else
      Process.sleep(5)
      eventually(assertion, attempts - 1)
    end
  end

  defp eventually(_assertion, 0), do: flunk("condition did not become true")
end
