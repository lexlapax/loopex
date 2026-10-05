Code.require_file("support/m1_runtime_helper.exs", __DIR__)
Code.require_file("support/agent_loop_helper.exs", __DIR__)
Code.require_file("support/m5_query_fault_store.exs", __DIR__)
Code.require_file("support/configured_genesis_helper.exs", __DIR__)

defmodule Loopex.EffectIntentsQueryTest do
  use ExUnit.Case, async: false

  alias Loopex.AgentLoopFixture, as: Fixture
  alias Loopex.Runtime
  alias Loopex.Store
  alias Loopex.ConfiguredGenesisFixture, as: Genesis
  alias Loopex.Runtime.{MaintenanceConfiguration, SessionState}

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
            genesis_version: 3,
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

  test "ordinary coverage requires current captured admission and request shapes", context do
    %{runtime: runtime, session: session, reference: reference, records: records} = context
    events = Fixture.events(context.fixture, session)
    assert {:ok, _} = SessionState.recover(session, records, events)
    assert :complete = scan_result(runtime, session)

    for {current, retired} <- [
          {"prompt_admitted_v3", "prompt_admitted_v2"},
          {"model_request_committed_v2", "model_request_committed"}
        ] do
      assert Enum.any?(records, &(&1.payload.kind == current))

      retired_rows =
        change_payload(records, current, fn payload ->
          payload |> Map.put(:kind, retired) |> Map.delete("configuration_version")
        end)

      install_history(reference, retired_rows)
      assert {:error, :invalid_history} = scan_result(runtime, session)
      assert {:error, _} = SessionState.recover(session, retired_rows, events)
      assert_invalid_configuration_versions(reference, runtime, session, records, current)
    end

    {:ok, children} = Runtime.children(runtime)
    assert :sys.get_state(children.control).sessions == %{}
    refute_received {:forbidden_store_call, _}
  end

  test "resource request coverage requires its current captured shape", context do
    %{runtime: runtime, session: session, reference: reference, records: original} = context
    history = Enum.take(original, 2)
    history = List.update_at(history, 0, &%{&1 | payload: Genesis.genesis([])})
    {:ok, state} = SessionState.recover(session, history, [])
    digest = String.duplicate("a", 64)

    command = %{
      type: :admit_resources,
      command_id: "admit-current-resources",
      manifest_digest: digest,
      decision: %{
        "manifest_digest" => digest,
        "workspace_ref" => "workspace-ref",
        "trust_scope" => "project_skills",
        "decision_source" => "host_supplied",
        "issued_at" => "2026-09-10T00:00:00Z",
        "expires_at" => nil,
        "revocation_state" => "active"
      }
    }

    {:ok, admitted} =
      SessionState.propose_resource_command(
        state,
        command,
        {:accepted, %{"workspace_ref" => "workspace-ref", "manifest_digest" => digest}}
      )

    {state, history, events} = retain(state, admitted, history, [])

    {:ok, prompt} =
      SessionState.propose(
        state,
        %{type: :prompt, command_id: "resources-prompt", content: "inspect resources"},
        %{max_turns: 8, deadline_ms: 60_000, token_budget: 10_000, context_token_budget: 8_192}
      )

    {state, history, events} = retain(state, prompt, history, events)
    run_id = state.active_run_id
    resources = state.run_resources[run_id]

    header = %{
      "version" => 1,
      "manifest_digest" => digest,
      "selection_digest" => SessionState.resource_selection_digest(resources),
      "status" => "evaluated",
      "blocks" => [%{"pack" => 64, "file" => 64, "status" => "staged"}]
    }

    catalog = "Available project skills: none selected."

    selected = [
      {catalog,
       %{
         "source_reference" => %{
           "kind" => "resource_pack",
           "manifest_digest" => digest,
           "pack" => 64,
           "file" => 64,
           "file_digest" => LoopexProtocol.Canonical.digest_bytes(catalog)
         },
         "provenance_class" => "resource_pack",
         "trust_class" => "untrusted_behavior_shaping_data"
       }}
    ]

    staging = %{
      run_id: run_id,
      elements: SessionState.elements(state, run_id),
      steer: nil,
      deadline: 1
    }

    project = %{
      "class" => "project_resource",
      "receipt_revision" => 2,
      "disposition" => "no_manifest",
      "detail" => %{}
    }

    {:ok, candidate} =
      SessionState.reference_model_candidate(state, staging, selected, project, header)

    {:ok, requested} =
      SessionState.propose_model_request(state, run_id, candidate.request,
        context_receipt: candidate.receipt,
        lineage_projection: candidate.projection
      )

    {_state, records, events} = retain(state, requested, history, events)
    assert {:ok, _} = SessionState.recover(session, records, events)
    current = "model_request_committed_resources_v2"
    assert Enum.any?(records, &(&1.payload.kind == current))
    install_history(reference, records)
    assert :complete = scan_result(runtime, session)

    retired =
      change_payload(records, current, fn payload ->
        payload
        |> Map.put(:kind, "model_request_committed_resources_v1")
        |> Map.drop(["configuration_version", "lineage_projection"])
      end)

    install_history(reference, retired)
    assert {:error, :invalid_history} = scan_result(runtime, session)
    assert {:error, _} = SessionState.recover(session, retired, events)
    assert_invalid_configuration_versions(reference, runtime, session, records, current)
    {:ok, children} = Runtime.children(runtime)
    assert :sys.get_state(children.control).sessions == %{}
    refute_received {:forbidden_store_call, _}
  end

  test "compact admission, fences and episode-bound abort advance private coverage without effect rows",
       context do
    %{runtime: runtime, session: session, reference: reference, records: original} = context
    history = Enum.take(original, 2)
    history = List.update_at(history, 0, &%{&1 | payload: Genesis.genesis([])})
    {:ok, state} = SessionState.recover(session, history, [])
    bounds = %{"max_attempts" => 4, "deadline_ms" => 60_000, "token_budget" => 32_768}

    commands = [
      %{type: :compact, command_id: "compact", bounds: bounds},
      %{type: :compact, command_id: "compact-fenced", bounds: bounds},
      %{type: :configure, command_id: "configure-fenced", changes: %{"max_tokens" => 32}},
      %{type: :abort, command_id: "compact-abort"}
    ]

    {state, records, []} =
      Enum.reduce(commands, {state, history, []}, fn command, {state, rows, events} ->
        {:ok, proposal} = SessionState.propose(state, command)
        retain(state, proposal, rows, events)
      end)

    assert {:ok, replay} = SessionState.recover(session, records, [])
    assert replay.pending_compact == state.pending_compact
    install_history(reference, records)
    pages = all_pages(runtime, session, nil, 1, [])
    assert length(pages) == length(records)
    assert List.last(pages).next_cursor == nil
    assert List.last(pages).scanned_through == length(records)
    assert Enum.all?(pages, &(&1.rows == []))
    refute_receive {:forbidden_store_call, _}, 0

    for {kind, transform} <- [
          {"compact_command_admitted_v1", &put_in(&1, ["bounds", "max_attempts"], 5)},
          {"compact_command_admitted_v1", &put_in(&1, ["bounds", "token_budget"], "32768")},
          {"compact_command_admitted_v1", &Map.put(&1, "admitted_at", 1_000)},
          {"compact_command_admitted_v1", &Map.put(&1, "command_type", "prompt")},
          {"compact_command_admitted_v1",
           &Map.put(&1, "admission", "rejected_maintenance_active")},
          {"compact_abort_admitted_v1", &Map.put(&1, "episode_id", nil)},
          {"compact_abort_admitted_v1", &Map.put(&1, "compact_command_id", nil)},
          {"compact_abort_admitted_v1", &Map.put(&1, "run_id", "invented")}
        ] do
      install_history(reference, change_payload(records, kind, transform))
      assert {:error, :invalid_history} = Runtime.effect_intents(runtime, session, nil, 16)
    end
  end

  test "standalone episode capture advances private coverage and rejects malformed captures",
       context do
    %{runtime: runtime, session: session, reference: reference, records: original} = context
    history = Enum.take(original, 2)
    history = List.update_at(history, 0, &%{&1 | payload: Genesis.genesis([])})
    {:ok, state} = SessionState.recover(session, history, [])

    {:ok, prompt} =
      SessionState.propose(
        state,
        %{type: :prompt, command_id: "old", content: "retained fact"},
        %{max_turns: 8, deadline_ms: 60_000, token_budget: 10_000, context_token_budget: 8_192}
      )

    {state, history, events} = retain(state, prompt, history, [])

    {:ok, terminal} =
      SessionState.propose_run_terminal(state, state.active_run_id, "failed", %{
        reason: "model_call_failed"
      })

    {state, history, events} = retain(state, terminal, history, events)

    {:ok, compact} =
      SessionState.propose(state, %{
        type: :compact,
        command_id: "compact",
        bounds: %{max_attempts: 4, deadline_ms: 60_000, token_budget: 32_768}
      })

    {state, history, events} = retain(state, compact, history, events)
    parent = state.configuration

    selection = %{
      "model" => parent["model"],
      "reasoning" => "none",
      "model_capabilities" => %{parent["model_capabilities"] | "reasoning_levels" => ["none"]},
      "provider_mapping" => %{parent["provider_mapping"] | "thinking_disabled" => true}
    }

    {:ok, instructions} =
      MaintenanceConfiguration.capture_instructions(%{
        "version" => "summary.v1",
        "body" => "Retain facts"
      })

    {:ok, capture} =
      SessionState.propose_standalone_maintenance_episode(
        state,
        selection,
        instructions,
        1_000,
        fn -> :ok end
      )

    {state, records, events} = retain(state, capture, history, events)
    assert {:ok, ^state} = SessionState.recover(session, records, events)
    install_history(reference, records)
    pages = all_pages(runtime, session, nil, 1, [])
    assert length(pages) == length(records)
    assert Enum.all?(pages, &(&1.rows == []))
    assert List.last(pages).next_cursor == nil
    assert List.last(pages).scanned_through == length(records)
    refute_receive {:forbidden_store_call, _}, 0

    {:ok, staged} = SessionState.propose_selected_maintenance_request(state, 1_500, fn -> :ok end)
    {opened, staged_records, staged_events} = retain(state, staged, records, events)
    assert {:ok, ^opened} = SessionState.recover(session, staged_records, staged_events)
    assert hd(staged.records)["covered_range"]["first_kept"] == nil
    assert opened.deadlines == %{}
    install_history(reference, staged_records)
    pages = all_pages(runtime, session, nil, 1, [])
    assert length(pages) == length(staged_records)
    assert Enum.all?(pages, &(&1.rows == []))
    assert List.last(pages).scanned_through == length(staged_records)
    assert List.last(pages).next_cursor == nil
    refute_receive {:forbidden_store_call, _}, 0

    for transform <- [
          &put_in(&1, ["covered_range", "first_kept"], "invented"),
          &Map.put(&1, "eligible_unit_count", 2),
          &put_in(&1, ["covered_range", "first"], nil),
          &put_in(&1, ["covered_range", "last"], nil),
          &put_in(&1, ["request", "sampling", "max_tokens"], 1_025)
        ] do
      install_history(
        reference,
        change_payload(staged_records, "maintenance_request_committed_v1", transform)
      )

      assert {:error, :invalid_history} = scan_result(runtime, session)
    end

    {:ok, ended} = SessionState.propose_maintenance_attempt_settled(opened, :owner_loss, 2_000)

    {completed, completed_records, completed_events} =
      retain(opened, ended, staged_records, staged_events)

    assert {:ok, ^completed} = SessionState.recover(session, completed_records, completed_events)
    assert List.last(ended.records)["result"]["cleanup"] == "unknown"
    assert List.last(ended.records)["result"]["usage"]["attempts"] == 1
    assert List.last(ended.records)["result"]["usage"]["estimated_tokens"] == 32_768
    install_history(reference, completed_records)
    pages = all_pages(runtime, session, nil, 1, [])
    assert length(pages) == length(completed_records)
    assert Enum.all?(pages, &(&1.rows == []))
    assert List.last(pages).scanned_through == length(completed_records)
    assert List.last(pages).next_cursor == nil
    refute_receive {:forbidden_store_call, _}, 0

    for transform <- [
          &Map.put(&1, "observed_at", nil),
          &put_in(&1, ["result", "usage", "attempts"], 0),
          &put_in(&1, ["result", "usage", "total_tokens"], 0),
          &put_in(&1, ["result", "usage", "estimated_tokens"], -1),
          &put_in(&1, ["result", "disposition"], "unchanged")
        ] do
      install_history(
        reference,
        change_payload(completed_records, "compact_command_completed_v1", transform)
      )

      assert {:error, :invalid_history} = scan_result(runtime, session)
    end

    for transform <- [
          &Map.put(&1, "run_id", "invented"),
          &Map.put(&1, "preparation_deadline", 61_000),
          &Map.delete(&1, "deadline"),
          &Map.put(&1, "deadline", 61_001),
          &Map.put(&1, "admitted_at", -1),
          &put_in(&1, ["bounds", "max_attempts"], 5),
          &put_in(&1, ["bounds", "token_budget"], "32768"),
          &Map.put(&1, "origin", "automatic"),
          &Map.put(&1, "trigger", "thinking_headroom"),
          &Map.put(&1, "targets", %{}),
          &Map.put(&1, "last_offending_source", %{}),
          &Map.put(&1, "attempts", 1),
          &Map.put(&1, "checkpoint_id", "invented"),
          &put_in(&1, ["usage", "total_tokens"], 1),
          &put_in(&1, ["maintenance_configuration", "digest"], String.duplicate("0", 64))
        ] do
      install_history(
        reference,
        change_payload(records, "standalone_maintenance_episode_admitted_v1", transform)
      )

      assert {:error, :invalid_history} = scan_result(runtime, session)
    end
  end

  test "unchanged compact completion advances bounded coverage without effects", context do
    %{runtime: runtime, session: session, reference: reference, records: original} = context
    history = Enum.take(original, 2)
    history = List.update_at(history, 0, &%{&1 | payload: Genesis.genesis([])})
    {:ok, state} = SessionState.recover(session, history, [])

    {:ok, compact} =
      SessionState.propose(state, %{
        type: :compact,
        command_id: "compact",
        bounds: %{max_attempts: 1, deadline_ms: 1, token_budget: 1}
      })

    {state, history, events} = retain(state, compact, history, [])
    {:ok, completion} = SessionState.propose_unchanged_compact(state, 1_000, fn -> :ok end)
    {state, records, events} = retain(state, completion, history, events)
    assert {:ok, ^state} = SessionState.recover(session, records, events)
    install_history(reference, records)
    pages = all_pages(runtime, session, nil, 1, [])
    assert length(pages) == length(records)
    assert Enum.all?(pages, &(&1.rows == []))
    assert List.last(pages).next_cursor == nil
    refute_receive {:forbidden_store_call, _}, 0

    for transform <- [
          &Map.put(&1, "run_id", "invented"),
          &Map.delete(&1, "command_id"),
          &Map.put(&1, "observed_at", -1),
          &Map.put(&1, "observed_at", 18_446_744_073_709_551_616),
          &put_in(&1, ["result", "disposition"], "failed"),
          &put_in(&1, ["result", "cleanup"], "unknown"),
          &put_in(&1, ["result", "checkpoint_id"], "invented"),
          &put_in(&1, ["result", "usage", "attempts"], 1),
          &put_in(&1, ["result", "usage", "reported_tokens"], 1),
          &put_in(&1, ["result", "extra"], nil)
        ] do
      install_history(
        reference,
        change_payload(records, "compact_command_completed_v1", transform)
      )

      assert {:error, :invalid_history} = scan_result(runtime, session)
    end
  end

  test "undispatched compact failures retain bounded neutral coverage and closed clocks",
       context do
    %{runtime: runtime, session: session, reference: reference, records: original} = context
    history = Enum.take(original, 2)
    history = List.update_at(history, 0, &%{&1 | payload: Genesis.genesis([])})
    {:ok, state} = SessionState.recover(session, history, [])

    {:ok, compact} =
      SessionState.propose(state, %{
        type: :compact,
        command_id: "compact",
        bounds: %{max_attempts: 4, deadline_ms: 60_000, token_budget: 32_768}
      })

    {state, history, events} = retain(state, compact, history, [])

    for cause <- [:invalid_clock, :cancelled] do
      {pending, rows, public, failure} =
        if cause == :cancelled do
          {:ok, abort} = SessionState.propose(state, %{type: :abort, command_id: "stop"})
          {pending, rows, public} = retain(state, abort, history, events)
          {pending, rows, public, %{"category" => "cancelled", "retryable" => false}}
        else
          {state, history, events,
           %{
             "version" => 2,
             "category" => "context_preparation_failed",
             "retryable" => false,
             "measurement_scope" => nil,
             "cause" => "maintenance_deadline_unrepresentable"
           }}
        end

      {:ok, completion} = SessionState.propose_standalone_compact_failure(pending, failure, nil)
      {completed, rows, public} = retain(pending, completion, rows, public)
      assert {:ok, ^completed} = SessionState.recover(session, rows, public)
      install_history(reference, rows)
      pages = all_pages(runtime, session, nil, 1, [])
      assert length(pages) == length(rows)
      assert Enum.all?(pages, &(&1.rows == []))
      assert List.last(pages).next_cursor == nil
      refute_receive {:forbidden_store_call, _}, 0

      for transform <- [
            &Map.put(&1, "observed_at", -1),
            &Map.delete(&1, "observed_at"),
            &put_in(&1, ["result", "failure"], nil),
            &put_in(&1, ["result", "failure"], %{
              "version" => 2,
              "category" => "context_preparation_failed",
              "retryable" => false,
              "measurement_scope" => nil,
              "cause" => "context_projection_invalid"
            }),
            &put_in(&1, ["result", "usage", "attempts"], 1),
            &put_in(&1, ["result", "cleanup"], "unknown")
          ] do
        install_history(
          reference,
          change_payload(rows, "compact_command_completed_v1", transform)
        )

        assert {:error, :invalid_history} = scan_result(runtime, session)
      end
    end
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

    payload =
      Genesis.genesis([])
      |> put_in(["runtime_configuration", "cleanup_grace_ms"], 1_500)

    record = %{journal_version: 1, owner_epoch: 0, owner_incarnation_id: nil, payload: payload}
    Agent.update(reference, &%{&1 | records: [record]})

    expected =
      Base.decode16!("fb9c75d5aca85c0436740273444dfb455a069307689e1677ffca75d8daa2fa98",
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

  test "maintenance deadlines and settlements advance validated history coverage", context do
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

    deadline =
      Map.merge(opened, %{
        :kind => "maintenance_termination_admitted_v1",
        "cause" => "deadline",
        "deadline" => 100,
        "observed" => 100
      })

    settled =
      Map.merge(opened, %{
        :kind => "maintenance_attempt_settled_v3",
        "transport" => "not_dispatched",
        "termination" => "deadline",
        "conversation" => "none",
        "next" => "terminal",
        "result" => %{"kind" => "error", "category" => "model_call_failed"},
        "accounting" => %{"source" => "none", "basis" => "not_dispatched"}
      })

    last = List.last(records)

    added =
      [opened, deadline, settled]
      |> Enum.with_index(last.journal_version + 1)
      |> Enum.map(fn {payload, version} ->
        %{last | journal_version: version, payload: payload}
      end)

    Agent.update(reference, &%{&1 | records: records ++ added})
    pages = all_pages(runtime, session, nil, 1, [])
    assert Enum.flat_map(pages, & &1.rows) == before
    assert List.last(pages).scanned_through == List.last(added).journal_version
    assert List.last(pages).next_cursor == nil

    for {index, payload} <- [
          {1, Map.put(deadline, "observed", 99)},
          {1, Map.put(deadline, "run_id", "invented")},
          {1, Map.delete(deadline, "purpose")},
          {2, Map.put(settled, "next", "retry")},
          {2, Map.put(settled, "transport", "dispatched_or_unknown")},
          {2, Map.put(settled, "turn_id", "invented")},
          {2, Map.delete(settled, "episode_id")}
        ] do
      changed = List.update_at(added, index, &%{&1 | payload: payload})
      Agent.update(reference, &%{&1 | records: records ++ changed})
      assert {:error, :invalid_history} = scan_result(runtime, session)
    end
  end

  test "complete retained maintenance history advances every page without activation or effects",
       context do
    %{runtime: runtime, session: session, reference: reference} = context
    {records, events} = maintenance_history(session)
    assert {:ok, replayed} = SessionState.recover(session, records, events)
    assert replayed.active_maintenance == nil
    assert replayed.active_run_id == nil
    install_history(reference, records)

    pages = all_pages(runtime, session, nil, 1, [])
    assert length(pages) == length(records)
    assert Enum.map(pages, & &1.scanned_through) == Enum.to_list(1..length(records))
    assert Enum.all?(pages, &(&1.rows == []))
    assert List.last(pages).next_cursor == nil
    assert List.last(pages).through_version == length(records)

    cursor = %{
      version: 1,
      runtime_id: "agent-loop-runtime",
      session_id: session,
      resume_after_version: List.last(pages).scanned_through,
      prefix_token: List.last(pages).prefix_token
    }

    assert {:ok, %{rows: [], next_cursor: nil}} =
             Runtime.effect_intents(runtime, session, cursor, 16)

    {:ok, children} = Runtime.children(runtime)
    assert :sys.get_state(children.control).sessions == %{}
    refute_received {:forbidden_store_call, _}
  end

  test "standalone checkpoint and completion advance private coverage without owner acquisition",
       context do
    %{runtime: runtime, session: session, reference: reference} = context
    {history, events} = maintenance_history(session, :parent_turn_bound)
    {:ok, state} = SessionState.recover(session, history, events)
    before = state

    {:ok, compact} =
      SessionState.propose(state, %{
        type: :compact,
        command_id: "compact",
        bounds: %{"max_attempts" => 4, "deadline_ms" => 60_000, "token_budget" => 32_768}
      })

    {state, history, events} = retain(state, compact, history, events)
    configuration = state.configuration

    selection = %{
      "model" => configuration["model"],
      "reasoning" => "none",
      "model_capabilities" => %{
        configuration["model_capabilities"]
        | "reasoning_levels" => ["none"]
      },
      "provider_mapping" => %{configuration["provider_mapping"] | "thinking_disabled" => true}
    }

    {:ok, instructions} =
      MaintenanceConfiguration.capture_instructions(%{
        "version" => "summary.v1",
        "body" => "Retain facts"
      })

    {:ok, admitted} =
      SessionState.propose_standalone_maintenance_episode(
        state,
        selection,
        instructions,
        3_000,
        fn -> :ok end
      )

    {state, history, events} = retain(state, admitted, history, events)

    {:ok, request} =
      SessionState.propose_selected_maintenance_request(state, 3_001, fn -> :ok end)

    {state, history, events} = retain(state, request, history, events)
    captured = state.maintenance_episodes[state.active_maintenance]["request"]

    reply = %{
      text: ~s({"summary":"retained facts","carry_forward":{"files_read":[],"files_changed":[]}}),
      identity: %{provider: "scripted", model: captured.model, endpoint: "in-process"},
      usage: %{input_tokens: 37, output_tokens: 19},
      tool_calls: [],
      delta_count: 0,
      streamed: false,
      provider_response_id: nil,
      canonical_request_bytes: captured.canonical_request_bytes,
      staged_request_digest: captured.staged_request_digest,
      completion: "natural",
      continuation: nil
    }

    {:ok, settled} =
      SessionState.propose_maintenance_attempt_settled(state, {:reply, reply}, 4_000)

    {state, history, events} = retain(state, settled, history, events)
    {:ok, checkpoint} = SessionState.propose_maintenance_checkpoint(state, 4_001, fn -> :ok end)
    {state, history, events} = retain(state, checkpoint, history, events)

    {:ok, completed} =
      SessionState.propose_maintenance_checkpoint_completion(state, 4_002, fn -> :ok end)

    {state, history, events} = retain(state, completed, history, events)
    assert {:ok, ^state} = SessionState.recover(session, history, events)
    assert state.charged == before.charged
    assert state.run_order == before.run_order
    assert state.commands["compact"].result["disposition"] == "checkpointed"
    install_history(reference, history)
    pages = all_pages(runtime, session, nil, 1, [])
    assert Enum.all?(pages, &(&1.rows == []))
    assert Enum.map(pages, & &1.scanned_through) == Enum.to_list(1..length(history))
    assert List.last(pages).next_cursor == nil
    {:ok, children} = Runtime.children(runtime)
    assert :sys.get_state(children.control).sessions == %{}
    refute_received {:forbidden_store_call, _}

    completed_row = List.last(history)

    for payload <- [
          Map.put(completed_row.payload, "run_id", "invented"),
          put_in(completed_row.payload, ["result", "checkpoint_id"], nil),
          put_in(completed_row.payload, ["result", "usage"], %{
            "attempts" => 0,
            "reported_tokens" => 0,
            "estimated_tokens" => 0,
            "total_tokens" => 0
          })
        ] do
      install_history(reference, List.update_at(history, -1, &%{&1 | payload: payload}))
      assert {:error, :invalid_history} = scan_result(runtime, session)
    end
  end

  test "bounded maintenance coverage requires current closed headroom targets", context do
    %{runtime: runtime, session: session, reference: reference} = context
    {records, _events} = maintenance_history(session)
    episode = Enum.find(records, &(&1.payload.kind == "maintenance_episode_admitted_v1"))

    targets = %{
      "revision" => "loopex.thinking_headroom.v1",
      "record_target" => 32_768,
      "input_target" => 4_096
    }

    headroom =
      Map.merge(episode.payload, %{"trigger" => "thinking_headroom", "targets" => targets})

    for payload <- [episode.payload, headroom, Map.put(headroom, "trigger", "ordinary_limit")] do
      install_history(
        reference,
        List.replace_at(records, episode.journal_version - 1, %{episode | payload: payload})
      )

      assert :complete = scan_result(runtime, session)
    end

    for payload <- [
          Map.delete(episode.payload, "targets"),
          Map.put(headroom, "targets", nil),
          put_in(headroom, ["targets", "revision"], "future"),
          put_in(headroom, ["targets", "record_target"], 32_769),
          put_in(headroom, ["targets", "input_target"], 0),
          put_in(headroom, ["targets", "input_target"], 18_446_744_073_709_551_616),
          put_in(headroom, ["targets", "extra"], true)
        ] do
      install_history(
        reference,
        List.replace_at(records, episode.journal_version - 1, %{episode | payload: payload})
      )

      assert {:error, :invalid_history} = scan_result(runtime, session)
    end

    {:ok, children} = Runtime.children(runtime)
    assert :sys.get_state(children.control).sessions == %{}
    refute_received {:forbidden_store_call, _}
  end

  test "measured nonprogress history advances every page without an effect or owner", context do
    %{runtime: runtime, session: session, reference: reference} = context
    {records, events} = maintenance_history(session, :nonprogress)
    assert {:ok, replayed} = SessionState.recover(session, records, events)
    assert replayed.active_maintenance == nil
    assert replayed.active_run_id == nil
    assert replayed.active_checkpoint == nil
    assert Enum.map(Map.values(replayed.charged), & &1.tokens) |> Enum.sum() == 56
    refusal = Enum.find(records, &(&1.payload.kind == "context_admission_refused_v2"))
    assert refusal.payload["projection_state"] == "measured"
    assert refusal.payload["failure"]["cause"] == "compaction_no_progress"
    install_history(reference, records)
    pages = all_pages(runtime, session, nil, 1, [])
    assert Enum.map(pages, & &1.scanned_through) == Enum.to_list(1..length(records))
    assert Enum.all?(pages, &(&1.rows == []))
    assert List.last(pages).next_cursor == nil
    {:ok, children} = Runtime.children(runtime)
    assert :sys.get_state(children.control).sessions == %{}
    refute_received {:forbidden_store_call, _}
  end

  test "run-owned parent turn bounds retain complete private coverage and reject substitutions",
       context do
    %{runtime: runtime, session: session, reference: reference} = context
    {records, events} = maintenance_history(session, :parent_turn_bound)
    assert {:ok, replayed} = SessionState.recover(session, records, events)
    assert replayed.active_run_id == nil
    install_history(reference, records)
    pages = all_pages(runtime, session, nil, 1, [])
    assert length(pages) == length(records)
    assert List.last(pages).next_cursor == nil
    assert Enum.all?(pages, &(&1.rows == []))
    terminal = Enum.find(records, &(&1.payload.kind == "maintenance_episode_terminal_v1"))
    assert terminal.payload["result"]["failure"]["bound"] == "max_turns"

    for forged <- [
          put_in(terminal.payload, ["result", "failure", "observed"], 0),
          put_in(terminal.payload, ["result", "failure", "declared_limit"], 0),
          put_in(terminal.payload, ["result", "failure", "extra"], true),
          put_in(terminal.payload, ["result", "usage", "total_tokens"], 57)
        ] do
      install_history(
        reference,
        List.replace_at(records, terminal.journal_version - 1, %{terminal | payload: forged})
      )

      cursor = %{
        version: 1,
        runtime_id: "agent-loop-runtime",
        session_id: session,
        through_version: length(records),
        after_version: terminal.journal_version - 1
      }

      assert {:error, :invalid_history} = Runtime.effect_intents(runtime, session, cursor, 1)
    end
  end

  test "checkpoint and completed episode advance private coverage without owning or dispatching",
       context do
    %{runtime: runtime, session: session, reference: reference} = context
    {records, events} = maintenance_history(session, :checkpointed)
    assert {:ok, replayed} = SessionState.recover(session, records, events)
    assert replayed.active_checkpoint != nil
    assert replayed.active_maintenance == nil
    assert replayed.active_run_id != nil
    install_history(reference, records)
    pages = all_pages(runtime, session, nil, 1, [])
    assert length(pages) == length(records)
    assert List.last(pages).next_cursor == nil
    assert Enum.all?(pages, &(&1.rows == []))
    {:ok, children} = Runtime.children(runtime)
    assert :sys.get_state(children.control).sessions == %{}
    refute_received {:forbidden_store_call, _}

    checkpoint = Enum.find(records, &(&1.payload.kind == "compaction_checkpoint_committed_v1"))

    for forged <- [
          Map.put(checkpoint.payload, "extra", true),
          put_in(checkpoint.payload, ["summary", "extra"], true),
          put_in(
            checkpoint.payload,
            ["summary", "covered_range_digest"],
            String.duplicate("0", 64)
          ),
          put_in(checkpoint.payload, ["usage", "total_tokens"], 57),
          Map.put(checkpoint.payload, "strategy_revision", 4),
          Map.put(checkpoint.payload, "prior_checkpoint_id", checkpoint.payload["checkpoint_id"])
        ] do
      install_history(
        reference,
        List.replace_at(records, checkpoint.journal_version - 1, %{checkpoint | payload: forged})
      )

      cursor = %{
        version: 1,
        runtime_id: "agent-loop-runtime",
        session_id: session,
        through_version: length(records),
        after_version: checkpoint.journal_version - 1
      }

      assert {:error, :invalid_history} = Runtime.effect_intents(runtime, session, cursor, 1)
    end
  end

  test "successive checkpoints advance bounded private history and reject cycles or enlarged raw cuts",
       context do
    %{runtime: runtime, session: session, reference: reference} = context
    {records, events} = maintenance_history(session, :two_checkpoints)
    assert {:ok, replayed} = SessionState.recover(session, records, events)
    assert replayed.active_maintenance == nil
    assert map_size(replayed.checkpoints) == 2

    assert [first, second] =
             Enum.filter(records, &(&1.payload.kind == "compaction_checkpoint_committed_v1"))

    assert second.payload["prior_checkpoint_id"] == first.payload["checkpoint_id"]
    assert second.payload["consumed_range"]["unit_count"] == 1
    assert second.payload["covered_range"]["unit_count"] == 2
    install_history(reference, records)
    pages = all_pages(runtime, session, nil, 1, [])
    assert Enum.map(pages, & &1.scanned_through) == Enum.to_list(1..length(records))
    assert Enum.all?(pages, &(&1.rows == []))
    assert List.last(pages).next_cursor == nil

    for forged <- [
          Map.put(second.payload, "prior_checkpoint_id", second.payload["checkpoint_id"]),
          Map.put(second.payload, "consumed_range", second.payload["covered_range"]),
          put_in(second.payload, ["consumed_range", "unit_count"], 0),
          put_in(second.payload, ["consumed_range", "first_kept"], %{})
        ] do
      altered = List.replace_at(records, second.journal_version - 1, %{second | payload: forged})
      install_history(reference, altered)

      cursor = %{
        version: 1,
        runtime_id: "agent-loop-runtime",
        session_id: session,
        through_version: length(records),
        after_version: second.journal_version - 1
      }

      assert {:error, :invalid_history} = Runtime.effect_intents(runtime, session, cursor, 1)
    end

    {:ok, children} = Runtime.children(runtime)
    assert :sys.get_state(children.control).sessions == %{}
    refute_received {:forbidden_store_call, _}
  end

  test "maintenance history refuses malformed captured rows and request byte substitutions",
       context do
    %{runtime: runtime, session: session, reference: reference} = context
    {records, _events} = maintenance_history(session)
    install_history(reference, records)

    for kind <-
          ~w(maintenance_episode_admitted_v1 maintenance_request_committed_v1 maintenance_episode_terminal_v1),
        transform <- [
          fn row -> Map.put(row, "extra", true) end,
          fn row -> Map.delete(row, "episode_id") end
        ] do
      changed = change_payload(records, kind, transform)
      Agent.update(reference, &%{&1 | records: changed})
      assert {:error, :invalid_history} = scan_result(runtime, session)
    end

    for {kind, transform} <- [
          {"maintenance_episode_admitted_v1", &Map.put(&1, "usage", %{})},
          {"maintenance_episode_admitted_v1", &Map.put(&1, "preparation_deadline", 60_999)},
          {"maintenance_episode_admitted_v1",
           &put_in(&1, ["maintenance_configuration", "digest"], String.duplicate("0", 64))},
          {"maintenance_episode_admitted_v1",
           &put_in(&1, ["maintenance_configuration", "instructions"], nil)},
          {"maintenance_request_committed_v1",
           &Map.put(&1, "source_digest", String.duplicate("0", 64))},
          {"maintenance_request_committed_v1",
           &Map.put(&1, "staged_request_digest", String.duplicate("0", 64))},
          {"maintenance_request_committed_v1",
           &put_in(&1, ["request", "canonical_request_bytes"], "changed")},
          {"maintenance_request_committed_v1", &Map.put(&1, "eligible_unit_count", 0)},
          {"maintenance_request_committed_v1", &put_in(&1, ["covered_range", "extra"], true)},
          {"maintenance_request_committed_v1", &put_in(&1, ["covered_range", "unit_count"], 2)},
          {"maintenance_episode_terminal_v1",
           &put_in(&1, ["result", "usage", "total_tokens"], 0)},
          {"maintenance_episode_terminal_v1",
           &put_in(&1, ["result", "failure", "cause"], "invented")}
        ] do
      Agent.update(reference, &%{&1 | records: change_payload(records, kind, transform)})
      assert {:error, :invalid_history} = scan_result(runtime, session)
    end
  end

  test "configured refusal counts travel together and do not fabricate effect rows", context do
    %{runtime: runtime, session: session, reference: reference} = context
    {records, _} = maintenance_history(session)
    install_history(reference, records)

    pair = fn row ->
      Map.merge(row, %{"project_resource_count" => 0, "resource_pack_count" => 0})
    end

    valid = change_payload(records, "context_admission_refused_v2", pair)
    Agent.update(reference, &%{&1 | records: valid})
    assert :complete = scan_result(runtime, session)

    for transform <- [
          &Map.put(&1, "project_resource_count", 0),
          &Map.put(&1, "resource_pack_count", 0),
          &Map.merge(&1, %{"project_resource_count" => -1, "resource_pack_count" => 0}),
          &Map.merge(&1, %{"project_resource_count" => 0, "resource_pack_count" => "0"})
        ] do
      Agent.update(
        reference,
        &%{&1 | records: change_payload(records, "context_admission_refused_v2", transform)}
      )

      assert {:error, :invalid_history} = scan_result(runtime, session)
    end
  end

  test "refusal coverage requires its current captured shape", context do
    %{runtime: runtime, session: session, reference: reference, records: original} = context

    configuration =
      Genesis.configuration()
      |> Map.put("context_token_budget", 64)
      |> Map.put("system_class_tokens", 64)
      |> put_in(["budget_origins", "context_token_budget"], "explicit")

    history = Enum.take(original, 2)
    history = List.update_at(history, 0, &%{&1 | payload: Genesis.genesis([], configuration)})
    {:ok, state} = SessionState.recover(session, history, [])

    {:ok, prompt} =
      SessionState.propose(
        state,
        %{type: :prompt, command_id: "oversized-context", content: String.duplicate("p", 4_096)},
        %{max_turns: 8, deadline_ms: 60_000, token_budget: 10_000, context_token_budget: 64}
      )

    {state, history, events} = retain(state, prompt, history, [])
    run_id = state.active_run_id

    staging = %{
      run_id: run_id,
      elements: SessionState.elements(state, run_id),
      steer: nil,
      deadline: 1
    }

    project = %{
      "class" => "project_resource",
      "receipt_revision" => 2,
      "disposition" => "no_manifest",
      "detail" => %{}
    }

    {:ok, candidate} = SessionState.reference_model_candidate(state, staging, [], project, nil)

    {:refused, refusal} =
      SessionState.propose_model_request(state, run_id, candidate.request,
        context_receipt: candidate.receipt,
        lineage_projection: candidate.projection
      )

    assert refusal["failure"]["category"] == "context_budget_exceeded"
    assert refusal["failure"]["observed"] > refusal["failure"]["limit"]
    {:ok, refused} = SessionState.propose_context_refusal(state, run_id, refusal)
    {_state, records, events} = retain(state, refused, history, events)
    assert {:ok, _} = SessionState.recover(session, records, events)
    current = "context_admission_refused_v2"
    assert Enum.any?(records, &(&1.payload.kind == current))
    install_history(reference, records)
    assert :complete = scan_result(runtime, session)

    retired =
      change_payload(records, current, fn payload ->
        payload
        |> Map.drop(
          ~w(failure configuration_version episode_id targets projection_state measurement_scope)
        )
        |> Map.merge(Map.take(payload["failure"], ~w(category dimension observed limit)))
        |> Map.put(:kind, "context_admission_refused_v1")
      end)

    legacy = Enum.find(retired, &(&1.payload.kind == "context_admission_refused_v1"))

    assert Enum.sort(Map.keys(legacy.payload)) ==
             Enum.sort([
               :kind
               | ~w(run_id turn_id category dimension token_estimator descriptor_canonicalization_version project_disposition system_message_count session_message_count steer_message_count tool_definition_count provider_estimated_tokens context_token_budget record_byte_cost context_record_byte_ceiling ordered_descriptor_digest observed limit)
             ])

    install_history(reference, retired)
    assert {:error, :invalid_history} = scan_result(runtime, session)
    assert {:error, _} = SessionState.recover(session, retired, events)
    assert_invalid_configuration_versions(reference, runtime, session, records, current)
    {:ok, children} = Runtime.children(runtime)
    assert :sys.get_state(children.control).sessions == %{}
    refute_received {:forbidden_store_call, _}
  end

  defp assert_invalid_configuration_versions(reference, runtime, session, records, kind) do
    for transform <- [
          &Map.delete(&1, "configuration_version"),
          &Map.put(&1, "configuration_version", nil),
          &Map.put(&1, "configuration_version", 0),
          &Map.put(&1, "configuration_version", -1),
          &Map.put(&1, "configuration_version", "1"),
          &Map.put(&1, "configuration_version", 18_446_744_073_709_551_616)
        ] do
      install_history(reference, change_payload(records, kind, transform))
      assert {:error, :invalid_history} = scan_result(runtime, session)
    end
  end

  defp change_payload(records, kind, transform),
    do:
      Enum.map(records, fn row ->
        if row.payload.kind == kind, do: %{row | payload: transform.(row.payload)}, else: row
      end)

  defp install_history(reference, records) do
    {:ok, transaction} =
      Store.create_session("agent-loop-runtime", "create-maintenance", hd(records).payload)

    Agent.update(reference, fn state ->
      %{
        state
        | records: records,
          creation: %{
            version: 1,
            runtime_id: state.runtime,
            command_id: "create-maintenance",
            session_id: state.session,
            genesis_version: 3,
            canonical_create_digest:
              Base.encode16(transaction.canonical_mutation_digest, case: :lower)
          }
      }
    end)
  end

  defp maintenance_history(session, ending \\ :failed) do
    history = [
      %{
        journal_version: 1,
        owner_epoch: 0,
        owner_incarnation_id: nil,
        payload: Genesis.genesis([])
      },
      %{
        journal_version: 2,
        owner_epoch: 1,
        owner_incarnation_id: "owner",
        payload: %{
          :kind => "owner_advanced",
          "prior_owner_epoch" => 0,
          "owner_epoch" => 1,
          "owner_incarnation_id" => "owner",
          "owner_transaction_id" => "owner-tx"
        }
      }
    ]

    {:ok, state} = SessionState.recover(session, history, [])

    bounds = %{
      max_turns: 8,
      token_budget: 10_000,
      deadline_ms: 60_000,
      context_token_budget: 8_192
    }

    {:ok, old} =
      SessionState.propose(
        state,
        %{
          type: :prompt,
          command_id: "old",
          content:
            cond do
              ending in [:failed, :nonprogress] -> "old facts"
              ending == :two_checkpoints -> String.duplicate("old", 10_000)
              true -> String.duplicate("old", 1_000)
            end
        },
        bounds
      )

    {state, history, events} = retain(state, old, history, [])

    {:ok, ended} =
      SessionState.propose_run_terminal(state, state.active_run_id, "failed", %{
        reason: "model_call_failed"
      })

    {state, history, events} = retain(state, ended, history, events)

    {state, history, events} =
      if ending == :two_checkpoints do
        {:ok, middle} =
          SessionState.propose(
            state,
            %{type: :prompt, command_id: "middle", content: String.duplicate("middle", 5_000)},
            bounds
          )

        {state, history, events} = retain(state, middle, history, events)

        {:ok, terminal} =
          SessionState.propose_run_terminal(state, state.active_run_id, "failed", %{
            reason: "model_call_failed"
          })

        retain(state, terminal, history, events)
      else
        {state, history, events}
      end

    {:ok, current} =
      SessionState.propose(
        state,
        %{type: :prompt, command_id: "current", content: "protected"},
        if(ending == :parent_turn_bound, do: %{bounds | max_turns: 1}, else: bounds)
      )

    {state, history, events} = retain(state, current, history, events)
    parent = state.configuration

    selection = %{
      "model" => parent["model"],
      "reasoning" => "none",
      "model_capabilities" => %{parent["model_capabilities"] | "reasoning_levels" => ["none"]},
      "provider_mapping" => %{parent["provider_mapping"] | "thinking_disabled" => true}
    }

    {:ok, instructions} =
      MaintenanceConfiguration.capture_instructions(%{
        "version" => "summary.v1",
        "body" => "Retain facts"
      })

    {:ok, admitted} =
      SessionState.propose_maintenance_episode(
        state,
        state.active_run_id,
        selection,
        instructions,
        1_000
      )

    {state, history, events} = retain(state, admitted, history, events)
    {:ok, request} = SessionState.propose_maintenance_request(state, 1, 1_001, fn -> :ok end)
    {state, history, events} = retain(state, request, history, events)
    captured = state.maintenance_episodes[state.active_maintenance]["request"]

    reply = %{
      text:
        if(ending == :failed,
          do: "invalid JSON",
          else: ~s({"summary":"retained","carry_forward":{"files_read":[],"files_changed":[]}})
        ),
      identity: %{provider: "scripted", model: captured.model, endpoint: "in-process"},
      usage: %{input_tokens: 37, output_tokens: 19},
      tool_calls: [],
      delta_count: 0,
      streamed: false,
      provider_response_id: nil,
      canonical_request_bytes: captured.canonical_request_bytes,
      staged_request_digest: captured.staged_request_digest,
      completion: "natural",
      continuation: nil
    }

    {:ok, settled} = SessionState.propose_maintenance_attempt_settled(state, {:reply, reply})
    {state, history, events} = retain(state, settled, history, events)

    {history, events} =
      cond do
        ending == :failed ->
          {:ok, refused} =
            SessionState.propose_context_preparation_failure(
              state,
              state.active_run_id,
              :maintenance_summary_invalid
            )

          {_state, history, events} = retain(state, refused, history, events)
          {history, events}

        ending == :nonprogress ->
          {:ok, refused} =
            SessionState.propose_maintenance_nonprogress(state, 2_000, fn -> :ok end)

          {_state, history, events} = retain(state, refused, history, events)
          {history, events}

        ending == :parent_turn_bound ->
          {:ok, terminal} =
            SessionState.propose_maintenance_parent_bound(state, state.active_run_id)

          {_state, history, events} = retain(state, terminal, history, events)
          {history, events}

        true ->
          {:ok, checkpoint} =
            SessionState.propose_maintenance_checkpoint(state, 2_000, fn -> :ok end)

          {state, history, events} = retain(state, checkpoint, history, events)

          {state, history, events} =
            if ending == :two_checkpoints do
              {:ok, request} =
                SessionState.propose_maintenance_request(state, 1, 2_001, fn -> :ok end)

              {state, history, events} = retain(state, request, history, events)
              request = state.maintenance_episodes[state.active_maintenance]["request"]

              reply = %{
                reply
                | canonical_request_bytes: request.canonical_request_bytes,
                  staged_request_digest: request.staged_request_digest
              }

              {:ok, settlement} =
                SessionState.propose_maintenance_attempt_settled(state, {:reply, reply})

              {state, history, events} = retain(state, settlement, history, events)

              {:ok, checkpoint} =
                SessionState.propose_maintenance_checkpoint(state, 2_002, fn -> :ok end)

              retain(state, checkpoint, history, events)
            else
              {state, history, events}
            end

          {:ok, completed} =
            SessionState.propose_maintenance_checkpoint_completion(state, 2_003, fn -> :ok end)

          {_state, history, events} = retain(state, completed, history, events)
          {history, events}
      end

    {history, events}
  end

  defp retain(state, proposal, history, events) do
    rows =
      proposal.records
      |> Enum.with_index(state.journal_version + 1)
      |> Enum.map(fn {payload, version} ->
        %{
          payload: payload,
          journal_version: version,
          owner_epoch: state.owner_epoch,
          owner_incarnation_id: state.owner_incarnation_id
        }
      end)

    added =
      proposal.events
      |> Enum.with_index(state.event_sequence + 1)
      |> Enum.map(fn {event, sequence} -> Map.put(event, :event_sequence, sequence) end)

    receipt = %{
      journal_versions: %{
        first: state.journal_version + 1,
        last: state.journal_version + length(rows)
      },
      event_sequences:
        if(added == [],
          do: nil,
          else: %{first: state.event_sequence + 1, last: state.event_sequence + length(added)}
        )
    }

    {:ok, next} = SessionState.commit_proposal(proposal, receipt)
    {next, history ++ rows, events ++ added}
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
