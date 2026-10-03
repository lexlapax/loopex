Code.require_file("support/m1_runtime_helper.exs", __DIR__)
Code.require_file("support/agent_loop_helper.exs", __DIR__)
Code.require_file("support/m5_query_fault_store.exs", __DIR__)

defmodule Loopex.EffectIntentsQueryTest do
  use ExUnit.Case, async: false

  alias Loopex.AgentLoopFixture, as: Fixture
  alias Loopex.Runtime
  alias Loopex.Store

  defmodule ReadStore do
    @moduledoc false
    @behaviour Store

    @impl Store
    def transact(reference, _), do: forbid(reference, :transact)
    @impl Store
    def transaction_status(reference, _, _, _), do: forbid(reference, :transaction_status)
    @impl Store
    def runtime_command(reference, _), do: forbid(reference, :runtime_command)
    @impl Store
    def load_events(reference, _, _, _), do: forbid(reference, :load_events)

    defp forbid(reference, operation) do
      send(Agent.get(reference, & &1.observer), {:forbidden_store_call, operation})
      raise("unexpected Store callback in history query")
    end

    @impl Store
    def creation_provenance(reference, runtime, %{kind: :session, session_id: session}) do
      state = Agent.get(reference, & &1)

      cond do
        state.provenance != :normal -> state.provenance
        runtime != state.runtime or session != state.session -> :conflict
        true -> {:historical, state.creation}
      end
    end

    @impl Store
    def ownership_head(reference, _, _) do
      Agent.get(reference, fn state ->
        if state.head == :normal,
          do:
            {:ok,
             %{
               owner_epoch: List.last(state.records).owner_epoch,
               journal_version: List.last(state.records).journal_version
             }},
          else: state.head
      end)
    end

    @impl Store
    def load_records(reference, _, after_version, limit) do
      reader = self()

      state =
        Agent.get_and_update(reference, fn state ->
          {state, %{state | reads: state.reads ++ [{after_version, limit, reader}]}}
        end)

      records =
        Enum.filter(state.records, &(&1.journal_version > after_version)) |> Enum.take(limit)

      case state.mode do
        :normal ->
          {:ok, records}

        :short ->
          {:ok, Enum.take(records, 1)}

        :gap ->
          {:ok, Enum.drop(records, 1)}

        :over ->
          {:ok, Enum.filter(state.records, &(&1.journal_version > after_version))}

        :empty ->
          {:ok, []}

        :unavailable ->
          :unavailable

        :raise ->
          raise("unavailable history")

        :block ->
          send(state.observer, {:blocked_history_reader, reader})

          receive do
            :release -> :unavailable
          end
      end
    end
  end

  setup do
    fixture =
      Fixture.start(
        script: [
          %{text: "write", calls: [%{id: "call-1", name: "write", arguments: %{"path" => "a"}}]},
          %{text: "done", calls: []}
        ]
      )

    on_exit(fn -> Fixture.stop(fixture) end)
    {session, attachment, {:accepted, "prompt-1"}} = Fixture.run(fixture, "implement")
    await_finished(attachment, System.monotonic_time(:millisecond) + 5_000)
    records = Fixture.records(fixture, session)
    runtime_id = "agent-loop-runtime"
    {:ok, transaction} = Store.create_session(runtime_id, "create-1", hd(records).payload)

    {:ok, reference} =
      Agent.start_link(fn ->
        %{
          runtime: runtime_id,
          session: session,
          records: records,
          mode: :normal,
          head: :normal,
          provenance: :normal,
          observer: self(),
          reads: [],
          creation: %{
            version: 1,
            runtime_id: runtime_id,
            command_id: "create-1",
            session_id: session,
            genesis_version: 2,
            canonical_create_digest:
              Base.encode16(transaction.canonical_mutation_digest, case: :lower)
          }
        }
      end)

    observer = self()
    Agent.update(reference, &%{&1 | observer: observer})
    {:ok, store} = Store.new(ReadStore, reference)

    {:ok, runtime} =
      Loopex.start_link(runtime_id: runtime_id, context_token_budget: 8_192, store: store)

    on_exit(fn -> stop_runtime(runtime) end)

    [
      fixture: fixture,
      session: session,
      records: records,
      reference: reference,
      runtime: runtime,
      attachment: attachment
    ]
  end

  test "every record advances coverage and only nil next cursor completes it", context do
    %{
      runtime: runtime,
      session: session,
      records: records,
      fixture: fixture,
      reference: reference
    } = context

    before = Loopex.M1RuntimeTestStore.inspect_state(fixture.store)
    jobs = Loopex.AgentLoopTestExecutor.jobs(fixture.executor)
    {:ok, %{sessions: supervisor}} = Runtime.children(runtime)
    assert DynamicSupervisor.which_children(supervisor) == []

    pages = all_pages(runtime, session, nil, 1, [])
    assert length(pages) == length(records)
    assert Enum.map(pages, & &1.scanned_through) == Enum.map(records, & &1.journal_version)
    assert Enum.all?(pages, &(&1.through_version == List.last(records).journal_version))
    assert hd(pages).rows == []
    assert hd(pages).next_cursor != nil
    assert List.last(pages).next_cursor == nil

    for {page, record} <- Enum.zip(pages, records) do
      payload = :erlang.term_to_binary(record.payload, [:deterministic])

      bytes =
        :erlang.term_to_binary(
          {record.journal_version, record.owner_epoch, record.owner_incarnation_id, payload},
          [:deterministic]
        )

      assert page.prefix_token == :crypto.hash(:sha256, bytes)
      assert :erlang.external_size({:ok, page}, [:deterministic]) <= 1_114_112

      assert Enum.sort(Map.keys(page)) ==
               Enum.sort(
                 ~w(version runtime_id session_id through_version scanned_through prefix_token rows next_cursor)a
               )
    end

    assert [
             %{kind: "intent", job: actual},
             %{kind: "terminal", disposition: "receipt_committed", tool_call_id: "call-1"}
           ] = Enum.flat_map(pages, & &1.rows)

    assert actual == Map.from_struct(hd(jobs))
    assert Agent.get(reference, & &1.reads) |> Enum.all?(fn {_, limit, _} -> limit == 1 end)
    assert before == Loopex.M1RuntimeTestStore.inspect_state(fixture.store)
    assert jobs == Loopex.AgentLoopTestExecutor.jobs(fixture.executor)
    assert DynamicSupervisor.which_children(supervisor) == []
    refute_receive {:forbidden_store_call, _}, 0
  end

  test "later appends stay outside a captured cut and resume verifies the retained boundary",
       context do
    %{
      runtime: runtime,
      session: session,
      records: original,
      reference: reference,
      fixture: fixture,
      attachment: attachment
    } = context

    assert {:ok, first} = Runtime.effect_intents(runtime, session, nil, 3)

    assert {:accepted, "prompt-2"} =
             Loopex.command(attachment, %{
               type: :prompt,
               command_id: "prompt-2",
               content: "continue"
             })

    await_finished(attachment, System.monotonic_time(:millisecond) + 5_000)
    later = Fixture.records(fixture, session)
    assert length(later) > length(original)
    Agent.update(reference, &%{&1 | records: later})

    tail = all_pages(runtime, session, first.next_cursor, 3, [])
    assert List.last(tail).scanned_through == List.last(original).journal_version
    assert Enum.all?(tail, &(&1.through_version == first.through_version))

    assert Enum.all?(
             Enum.flat_map(tail, & &1.rows),
             &(&1.journal_version <= first.through_version)
           )

    resume = %{
      version: 1,
      runtime_id: "agent-loop-runtime",
      session_id: session,
      resume_after_version: first.scanned_through,
      prefix_token: first.prefix_token
    }

    Agent.update(reference, &%{&1 | reads: []})
    assert {:ok, resumed} = Runtime.effect_intents(runtime, session, resume, 16)
    assert resumed.through_version == List.last(later).journal_version
    assert resumed.scanned_through > first.scanned_through
    assert [{probe, 1, _}, {scan, count, _}] = Agent.get(reference, & &1.reads)
    assert probe == first.scanned_through - 1
    assert scan == first.scanned_through
    assert count in 1..16

    assert {:error, :invalid_query} =
             Runtime.effect_intents(runtime, session, %{resume | prefix_token: <<0::256>>}, 16)

    # This changes a valid record, so refusal proves the opaque prefix binds
    # retained contents rather than merely the requested numeric position.
    changed =
      Enum.map(later, fn record ->
        if record.journal_version == first.scanned_through,
          do: %{record | payload: Map.put(record.payload, "content", "altered")},
          else: record
      end)

    Agent.update(reference, &%{&1 | records: changed})
    assert {:error, :invalid_query} = Runtime.effect_intents(runtime, session, resume, 16)
  end

  test "invalid limits, closed cursor fields, scope and future positions refuse", context do
    %{runtime: runtime, session: session, reference: reference} = context
    assert {:ok, first} = Runtime.effect_intents(runtime, session, nil, 1)
    cursor = first.next_cursor
    Agent.update(reference, &%{&1 | reads: []})

    for invalid <- [nil, 0, 17, 1.0, "1"],
        do:
          assert(
            {:error, :invalid_query} == Runtime.effect_intents(runtime, session, nil, invalid)
          )

    for invalid <- [
          %{},
          Map.put(cursor, :extra, nil),
          Map.delete(cursor, :through_version),
          %{cursor | version: 2},
          %{cursor | runtime_id: "other"},
          %{cursor | session_id: "other"},
          %{cursor | after_version: -1},
          %{cursor | after_version: cursor.through_version + 1},
          %{cursor | through_version: 18_446_744_073_709_551_616},
          %{
            version: 1,
            runtime_id: "agent-loop-runtime",
            session_id: session,
            resume_after_version: 0,
            prefix_token: <<0::256>>
          },
          %{
            version: 1,
            runtime_id: "agent-loop-runtime",
            session_id: session,
            resume_after_version: 1,
            prefix_token: "not-a-token"
          }
        ],
        do:
          assert({:error, :invalid_query} == Runtime.effect_intents(runtime, session, invalid, 1))

    assert Agent.get(reference, & &1.reads) == []

    assert {:error, :invalid_query} =
             Runtime.effect_intents(
               runtime,
               session,
               %{cursor | through_version: cursor.through_version + 1},
               1
             )

    assert {:error, :invalid_query} = Runtime.effect_intents(runtime, "another-session", nil, 1)
    assert {:error, :invalid_query} = Runtime.effect_intents(runtime, "", nil, 1)
  end

  test "available effect-free history has a literal token and complete empty page", context do
    %{runtime: runtime, session: session, reference: reference} = context

    payload = %{
      "options" => %{},
      "runtime_configuration" => %{"cleanup_grace_ms" => 1_500},
      kind: "session_genesis_v2"
    }

    record = %{journal_version: 1, owner_epoch: 0, owner_incarnation_id: nil, payload: payload}
    Agent.update(reference, &%{&1 | records: [record]})

    expected =
      Base.decode16!("6334e9bd35db1e6e2b33e72716a6a1945b7d2220c8ff305d98248c337c06df55",
        case: :lower
      )

    assert {:ok,
            %{
              rows: [],
              through_version: 1,
              scanned_through: 1,
              prefix_token: ^expected,
              next_cursor: nil
            }} = Runtime.effect_intents(runtime, session, nil, 16)

    cursor = %{
      version: 1,
      runtime_id: "agent-loop-runtime",
      session_id: session,
      through_version: 1,
      after_version: 1
    }

    assert {:ok, %{rows: [], prefix_token: ^expected, next_cursor: nil}} =
             Runtime.effect_intents(runtime, session, cursor, 16)

    resume = %{
      version: 1,
      runtime_id: "agent-loop-runtime",
      session_id: session,
      resume_after_version: 1,
      prefix_token: expected
    }

    assert {:ok, %{rows: [], prefix_token: ^expected, next_cursor: nil}} =
             Runtime.effect_intents(runtime, session, resume, 16)

    {:ok, unsupported} = Store.new(Loopex.M5QueryFaultStore, :absent)

    {:ok, other} =
      Loopex.start_link(
        runtime_id: "unsupported",
        context_token_budget: 8_192,
        store: unsupported
      )

    on_exit(fn -> stop_runtime(other) end)
    assert {:error, :history_unavailable} = Runtime.effect_intents(other, session, nil, 1)
  end

  test "absence, incomplete history, adapter loss and short pages have distinct results",
       context do
    %{runtime: runtime, session: session, reference: reference} = context

    for {provenance, expected} <- [
          {:absent, :session_absent},
          {:conflict, :invalid_query},
          {:unavailable, :history_unavailable}
        ] do
      Agent.update(reference, &%{&1 | provenance: provenance})
      assert {:error, ^expected} = Runtime.effect_intents(runtime, session, nil, 16)
    end

    Agent.update(reference, &%{&1 | provenance: :normal})

    for {mode, expected} <- [
          {:gap, :invalid_history},
          {:empty, :invalid_history},
          {:unavailable, :history_unavailable},
          {:raise, :history_unavailable}
        ] do
      Agent.update(reference, &%{&1 | mode: mode})
      assert {:error, ^expected} = Runtime.effect_intents(runtime, session, nil, 16)
    end

    Agent.update(reference, &%{&1 | mode: :short})
    assert {:ok, page} = Runtime.effect_intents(runtime, session, nil, 16)
    assert page.scanned_through == 1
    assert page.rows == []
    refute is_nil(page.next_cursor)
    assert List.last(all_pages(runtime, session, page.next_cursor, 16, [])).next_cursor == nil

    Agent.update(reference, &%{&1 | head: :unavailable})
    assert {:error, :history_unavailable} = Runtime.effect_intents(runtime, session, nil, 1)
    Agent.update(reference, &%{&1 | mode: :over, head: :normal})
    assert {:error, :invalid_history} = Runtime.effect_intents(runtime, session, nil, 1)
  end

  test "unsupported, expanded and malformed retained facts cannot be skipped", context do
    %{runtime: runtime, session: session, records: records, reference: reference} = context

    for record <- records do
      for payload <- [
            Map.put(record.payload, "extra", nil),
            Map.delete(record.payload, :kind),
            %{record.payload | kind: record.payload.kind <> "_unsupported"}
          ] do
        changed =
          Enum.map(
            records,
            &if(&1.journal_version == record.journal_version,
              do: %{&1 | payload: payload},
              else: &1
            )
          )

        Agent.update(reference, &%{&1 | records: changed})
        assert {:error, :invalid_history} = scan_result(runtime, session)
      end
    end

    Agent.update(reference, &%{&1 | records: records})

    for record <- records,
        record.payload.kind in ~w(effect_intent_committed_v2 executor_receipt_committed_v2) do
      key = if record.payload.kind == "effect_intent_committed_v2", do: "job", else: "receipt"

      changed =
        Enum.map(
          records,
          &if(&1.journal_version == record.journal_version,
            do: %{&1 | payload: Map.put(&1.payload, key, nil)},
            else: &1
          )
        )

      Agent.update(reference, &%{&1 | records: changed})
      assert {:error, :invalid_history} = scan_result(runtime, session)
    end
  end

  test "maintenance attempt opens advance coverage without inventing executor effects", context do
    %{runtime: runtime, session: session, records: records, reference: reference} = context
    before = all_pages(runtime, session, nil, 1, []) |> Enum.flat_map(& &1.rows)

    {:ok, opened} =
      Loopex.Runtime.ProviderAttempt.opened_record(%{
        episode_id: "maintenance-episode",
        summary_ordinal: 1,
        purpose: "compaction",
        operation_id: "summary-operation",
        attempt: 1,
        staged_request_digest: String.duplicate("d", 64)
      })

    last = List.last(records)
    row = %{last | journal_version: last.journal_version + 1, payload: opened}
    Agent.update(reference, &%{&1 | records: records ++ [row]})
    pages = all_pages(runtime, session, nil, 1, [])
    assert Enum.flat_map(pages, & &1.rows) == before
    assert List.last(pages).scanned_through == row.journal_version
    assert List.last(pages).next_cursor == nil

    for payload <- [
          Map.put(opened, "extra", true),
          Map.put(opened, "run_id", "fictional-run"),
          Map.put(opened, "summary_ordinal", 0),
          Map.put(opened, "purpose", "ordinary"),
          Map.delete(opened, "episode_id")
        ] do
      Agent.update(reference, &%{&1 | records: records ++ [%{row | payload: payload}]})
      assert {:error, :invalid_history} = scan_result(runtime, session)
    end
  end

  test "Store-read timeout joins the blocked reader before answering", context do
    %{runtime: runtime, session: session, reference: reference} = context
    Agent.update(reference, &%{&1 | mode: :block})
    task = Task.async(fn -> Runtime.effect_intents(runtime, session, nil, 16) end)
    assert_receive {:blocked_history_reader, reader}, 5_000
    assert {:monitored_by, [guardian]} = Process.info(reader, :monitored_by)
    guardian_monitor = Process.monitor(guardian)
    monitor = Process.monitor(reader)
    assert {:error, :history_unavailable} = Task.await(task, 5_000)
    refute Process.alive?(reader)
    refute Process.alive?(guardian)
    assert_receive {:DOWN, ^monitor, :process, ^reader, :killed}, 5_000
    assert_receive {:DOWN, ^guardian_monitor, :process, ^guardian, :normal}, 5_000
    Agent.update(reference, &%{&1 | mode: :normal})
    assert {:ok, _} = Runtime.effect_intents(runtime, session, nil, 1)
  end

  test "Control death also joins a blocked reader and remains runtime loss", context do
    %{runtime: runtime, session: session, reference: reference} = context
    Agent.update(reference, &%{&1 | mode: :block})
    task = Task.async(fn -> Runtime.effect_intents(runtime, session, nil, 16) end)
    assert_receive {:blocked_history_reader, reader}, 5_000
    assert {:monitored_by, [guardian]} = Process.info(reader, :monitored_by)
    guardian_monitor = Process.monitor(guardian)
    monitor = Process.monitor(reader)
    {:ok, %{control: control}} = Runtime.children(runtime)
    Process.exit(control, :kill)
    assert {:error, :runtime_unavailable} = Task.await(task, 5_000)
    assert_receive {:DOWN, ^monitor, :process, ^reader, :killed}, 5_000
    assert_receive {:DOWN, ^guardian_monitor, :process, ^guardian, :normal}, 5_000
    assert {:error, :runtime_unavailable} = Runtime.effect_intents(nil, session, nil, 1)
  end

  defp all_pages(runtime, session, cursor, limit, reversed) do
    assert {:ok, page} = Runtime.effect_intents(runtime, session, cursor, limit)
    assert page.scanned_through > ((cursor && Map.get(cursor, :after_version)) || 0)

    if page.next_cursor,
      do: all_pages(runtime, session, page.next_cursor, limit, [page | reversed]),
      else: Enum.reverse([page | reversed])
  end

  defp scan_result(runtime, session, cursor \\ nil) do
    case Runtime.effect_intents(runtime, session, cursor, 16) do
      {:ok, %{next_cursor: nil}} -> :complete
      {:ok, %{next_cursor: next}} -> scan_result(runtime, session, next)
      error -> error
    end
  end

  defp await_finished(attachment, deadline) do
    case Loopex.next_event(attachment) do
      {:ok, %{kind: "run.finished"}} ->
        :ok

      observation ->
        assert System.monotonic_time(:millisecond) < deadline,
               "run did not finish: #{inspect(observation)}"

        unless match?({:ok, %{}}, observation), do: Process.sleep(10)
        await_finished(attachment, deadline)
    end
  end

  defp stop_runtime(runtime) do
    Loopex.stop(runtime)
  catch
    :exit, _ -> :ok
  end
end
