Code.require_file("support/m1_runtime_helper.exs", __DIR__)
Code.require_file("support/agent_loop_helper.exs", __DIR__)
Code.require_file("support/configured_genesis_helper.exs", __DIR__)

defmodule Loopex.Runtime.MaintenanceProviderAttemptTest do
  use ExUnit.Case, async: false

  alias Loopex.AgentLoopFixture, as: Fixture
  alias Loopex.AgentLoopTestModel
  alias Loopex.ConfiguredGenesisFixture, as: Genesis
  alias Loopex.M1RuntimeTestStore
  alias Loopex.Runtime.{Control, ProviderAttempt}
  alias Loopex.{Model, Store}

  @uint64_max 18_446_744_073_709_551_615

  test "maintenance opens retain episode identity and never invent an ordinary run or turn" do
    assert {:ok, opened} = ProviderAttempt.opened_record(identity())

    assert opened == %{
             :kind => "maintenance_attempt_opened_v1",
             "episode_id" => "episode-1",
             "summary_ordinal" => 1,
             "purpose" => "compaction",
             "operation_id" => "summary-operation-1",
             "attempt" => 1,
             "staged_request_digest" => String.duplicate("d", 64)
           }

    assert ProviderAttempt.validate_opened(opened) == :ok
    assert {:ok, binding} = ProviderAttempt.binding_from_opened("session-1", opened)
    assert binding == Map.put(Map.delete(opened, :kind), "session_id", "session-1")
    assert ProviderAttempt.validate_binding(binding) == :ok
    refute Map.has_key?(binding, "run_id")
    refute Map.has_key?(binding, "turn_id")

    string_kind = opened |> Map.delete(:kind) |> Map.put("kind", opened.kind)
    assert ProviderAttempt.binding_from_opened("session-1", string_kind) == {:ok, binding}

    for ordinal <- [1, @uint64_max], attempt <- [1, 2] do
      assert {:ok, _} =
               ProviderAttempt.opened_record(%{
                 identity()
                 | summary_ordinal: ordinal,
                   attempt: attempt
               })
    end
  end

  test "maintenance identities and kinds are closed at record and permit boundaries" do
    {:ok, opened} = ProviderAttempt.opened_record(identity())
    {:ok, binding} = ProviderAttempt.binding_from_opened("session-1", opened)

    changed = [
      {"episode_id", ""},
      {"episode_id", String.duplicate("x", 513)},
      {"summary_ordinal", 0},
      {"summary_ordinal", @uint64_max + 1},
      {"summary_ordinal", 1.0},
      {"purpose", "ordinary"},
      {"operation_id", ""},
      {"attempt", 0},
      {"attempt", 3},
      {"staged_request_digest", String.duplicate("D", 64)}
    ]

    for {key, value} <- changed do
      assert {:error, _} = ProviderAttempt.validate_opened(Map.put(opened, key, value))

      assert ProviderAttempt.validate_binding(Map.put(binding, key, value)) ==
               {:error, :invalid_provider_attempt_binding}
    end

    for key <- Map.keys(binding) do
      assert ProviderAttempt.validate_binding(Map.delete(binding, key)) ==
               {:error, :invalid_provider_attempt_binding}
    end

    for {key, value} <- [
          {"run_id", "run-1"},
          {"turn_id", "turn-1"},
          {"extra", true},
          {:kind, "maintenance_attempt_opened_v1"},
          {"kind", "maintenance_attempt_opened_v1"}
        ] do
      assert ProviderAttempt.validate_binding(Map.put(binding, key, value)) ==
               {:error, :invalid_provider_attempt_binding}
    end

    for candidate <- [
          Map.delete(opened, :kind),
          Map.put(opened, :kind, "model_attempt_opened_v1"),
          Map.put(opened, :kind, "maintenance_attempt_settled_v3"),
          Map.put(opened, "run_id", "run-1"),
          Map.put(opened, "turn_id", "turn-1"),
          Map.put(opened, "kind", "maintenance_attempt_opened_v1")
        ] do
      assert ProviderAttempt.binding_from_opened("session-1", candidate) ==
               {:error, :invalid_provider_attempt_binding}
    end

    assert ProviderAttempt.opened_record(%{identity() | purpose: "ordinary"}) ==
             {:error, :invalid_attempt_identity}

    assert ProviderAttempt.opened_record(Map.put(identity(), :run_id, "run-1")) ==
             {:error, :invalid_attempt_identity}

    assert ProviderAttempt.opened_record(Map.put(identity(), :turn_id, "turn-1")) ==
             {:error, :invalid_attempt_identity}
  end

  test "maintenance settlements retain v3 evidence and the closed accounting verdict" do
    {:ok, request} =
      Model.request("summary:v1", [%{"role" => "user", "content" => "source"}],
        sampling: %{"max_tokens" => 1_024},
        deadline: 100_000
      )

    row = settlement(request.staged_request_digest)
    assert ProviderAttempt.maintenance_settled_kind() == row.kind
    assert ProviderAttempt.validate_settled(row) == :ok
    assert ProviderAttempt.validate_settled(row, request, false) == :ok

    ordinary =
      row
      |> Map.drop(~w(episode_id summary_ordinal purpose))
      |> Map.merge(%{:kind => "model_attempt_settled_v3", "run_id" => "run", "turn_id" => "turn"})

    assert :ok = ProviderAttempt.validate_settled(ordinary)

    assert {:error, _} =
             ProviderAttempt.validate_settled(
               put_in(
                 ordinary,
                 ["result", "reply", "staged_request_digest"],
                 String.duplicate("b", 64)
               )
             )

    assert {:error, _} = ProviderAttempt.validate_settled(row, request, true)

    assert {:error, _} =
             ProviderAttempt.validate_settled(
               row,
               %{request | staged_request_digest: String.duplicate("a", 64)},
               false
             )

    for key <- Map.keys(row) do
      assert {:error, _} = ProviderAttempt.validate_settled(Map.delete(row, key))
    end

    for changed <- [
          Map.put(row, "run_id", "invented"),
          Map.put(row, "turn_id", "invented"),
          Map.put(row, "purpose", "ordinary"),
          Map.put(row, "summary_ordinal", 0),
          Map.put(row, "attempt", 3),
          Map.put(row, :kind, "model_attempt_settled_v3"),
          Map.put(row, "kind", row.kind),
          put_in(row, ["result", "reply", "staged_request_digest"], String.duplicate("b", 64)),
          put_in(row, ["result", "reply", "extra"], true),
          put_in(row, ["accounting", "input_tokens"], 4),
          Map.put(row, "transport", "not_dispatched"),
          Map.put(row, "conversation", "evidence_only"),
          Map.put(row, "next", "retry")
        ] do
      assert {:error, _} = ProviderAttempt.validate_settled(changed)
    end

    # A bounded valid reply can still be invalid summary output. Retain and
    # charge it here; the owner must refuse checkpoint publication separately.
    calls = [%{"id" => "tool", "name" => "write", "arguments" => %{}}]
    tools = put_in(row, ["result", "reply", "tool_calls"], calls)
    assert :ok = ProviderAttempt.validate_settled(tools)
    assert tools["next"] == "terminal"
    assert {:error, _} = ProviderAttempt.validate_settled(%{tools | "next" => "continue"})

    assert :ok =
             ProviderAttempt.validate_settled(
               put_in(row, ["result", "reply", "completion"], "limit")
             )

    for termination <- ["abort", "deadline"] do
      late = %{row | "termination" => termination, "conversation" => "evidence_only"}
      assert :ok = ProviderAttempt.validate_settled(late)

      assert {:error, _} =
               ProviderAttempt.validate_settled(%{late | "conversation" => "canonical"})
    end

    for attempt <- [1, 2] do
      not_sent = %{
        row
        | "attempt" => attempt,
          "transport" => "not_dispatched",
          "conversation" => "none",
          "next" => if(attempt == 1, do: "retry", else: "terminal"),
          "result" => %{"kind" => "error", "category" => "model_call_failed"},
          "accounting" => %{"source" => "none", "basis" => "not_dispatched"}
      }

      assert :ok = ProviderAttempt.validate_settled(not_sent)
      wrong = if attempt == 1, do: "terminal", else: "retry"
      assert {:error, _} = ProviderAttempt.validate_settled(%{not_sent | "next" => wrong})

      unknown = %{
        not_sent
        | "transport" => "dispatched_or_unknown",
          "termination" => "owner_loss",
          "next" => "terminal",
          "accounting" => %{"source" => "estimated", "basis" => "remaining_allowance"}
      }

      assert :ok = ProviderAttempt.validate_settled(unknown)
      assert {:error, _} = ProviderAttempt.validate_settled(%{unknown | "next" => "retry"})
    end

    oversized = %{
      row
      | "conversation" => "none",
        "result" => %{
          "kind" => "error",
          "category" => "unreadable_model_answer",
          "accounting_evidence" => %{
            "kind" => "validated_reply_compaction_v1",
            "usage" => row["result"]["reply"]["usage"],
            "dimension" => "record_bytes",
            "observed" => 65_537,
            "limit" => 65_536
          }
        }
    }

    assert :ok = ProviderAttempt.validate_settled(oversized)

    assert {:error, _} =
             ProviderAttempt.validate_settled(
               put_in(oversized, ["accounting", "output_tokens"], 3)
             )

    assert {:error, _} =
             ProviderAttempt.validate_settled(
               put_in(oversized, ["result", "accounting_evidence", "observed"], 65_536)
             )
  end

  test "maintenance deadlines require their exact kind, scope and reached clock" do
    {:ok, opened} = ProviderAttempt.opened_record(identity())

    row =
      Map.merge(opened, %{
        :kind => "maintenance_termination_admitted_v1",
        "cause" => "deadline",
        "deadline" => 1_000,
        "observed" => 1_000
      })

    assert ProviderAttempt.maintenance_termination_kind() == row.kind
    assert ProviderAttempt.validate_termination(row) == :ok
    assert :ok = ProviderAttempt.validate_termination(%{row | "observed" => @uint64_max})

    for key <- Map.keys(row) do
      assert {:error, _} = ProviderAttempt.validate_termination(Map.delete(row, key))
    end

    for changed <- [
          Map.put(row, "run_id", "invented"),
          Map.put(row, "turn_id", "invented"),
          Map.put(row, "purpose", "ordinary"),
          Map.put(row, "summary_ordinal", 0),
          Map.put(row, :kind, "model_termination_admitted_v1"),
          Map.put(row, "cause", "abort"),
          Map.put(row, "observed", 999),
          Map.put(row, "observed", @uint64_max + 1),
          Map.put(row, "deadline", -1)
        ] do
      assert {:error, _} = ProviderAttempt.validate_termination(changed)
    end
  end

  # Concept: the existing Control handler authorizes only the retained summary
  # attempt at the current position, once, under the current owner and deadline.
  # Technical depth: this boundary fixture writes the accepted open row through
  # Store and acknowledges its actual receipt to Control. It submits the same
  # private owner-call envelope used by the ordinary permit tests. It invokes no
  # provider and does not claim episode/request reducer or live compaction proof.
  test "Control spends one maintenance permit from its exact committed row" do
    {fixture, session, control, entry} = fixture()
    {:ok, opened} = ProviderAttempt.opened_record(identity())
    {:ok, binding} = ProviderAttempt.binding_from_opened(session, opened)
    {worker, monitor} = worker()

    assert dispatch(control, entry, binding, worker, entry.journal_version) ==
             {:error, :invalid_provider_attempt_binding}

    refute_received {:permit_received, ^worker, _}

    {:ok, store} = Store.new(M1RuntimeTestStore, fixture.store)

    {:ok, transaction} =
      Store.session_commit(
        session,
        "session",
        "maintenance-open-boundary",
        entry.owner.owner_epoch,
        entry.owner.owner_incarnation_id,
        entry.journal_version,
        [opened],
        []
      )

    assert {:committed, _tx, receipt} = Store.transact(store, transaction)
    position = receipt.journal_versions.last

    assert :ok =
             Control.post_commit(
               control,
               session,
               entry.owner,
               %{journal_version: position, event_sequence: entry.event_sequence},
               receipt
             )

    for changed <- [
          Map.put(binding, "episode_id", "other-episode"),
          Map.put(binding, "summary_ordinal", 2),
          Map.put(binding, "operation_id", "other-operation"),
          Map.put(binding, "attempt", 2),
          Map.put(binding, "staged_request_digest", String.duplicate("a", 64))
        ] do
      assert dispatch(control, entry, changed, worker, position) ==
               {:error, :invalid_provider_attempt_binding}
    end

    assert dispatch(control, entry, binding, worker, position, deadline: 0) ==
             {:error, :deadline_elapsed}

    assert dispatch(control, entry, binding, worker, entry.journal_version) ==
             {:error, :stale_attempt_open_position}

    assert dispatch(control, entry, binding, worker, position) == {:ok, :dispatched}

    assert_receive {:permit_received, ^worker, {:loopex_provider_permit, _reference, ^binding}},
                   5_000

    assert dispatch(control, entry, binding, worker, position) ==
             {:error, :provider_attempt_already_permitted}

    assert Map.keys(:sys.get_state(control).spent_attempts) == [binding]
    assert AgentLoopTestModel.dispatched(fixture.model) == []
    stop_worker(worker, monitor)

    # This is an exact-row permit retirement witness, not summary/checkpoint
    # integration. The worker is joined before its settlement is acknowledged.
    {:ok, transaction} =
      Store.session_commit(
        session,
        "session",
        "maintenance-settled-boundary",
        entry.owner.owner_epoch,
        entry.owner.owner_incarnation_id,
        position,
        [settlement(binding["staged_request_digest"])],
        []
      )

    assert {:committed, _tx, settled_receipt} = Store.transact(store, transaction)
    settled_position = settled_receipt.journal_versions.last

    assert :ok =
             Control.post_commit(
               control,
               session,
               entry.owner,
               %{journal_version: settled_position, event_sequence: entry.event_sequence},
               settled_receipt
             )

    assert :sys.get_state(control).spent_attempts == %{}

    assert dispatch(control, entry, binding, worker, position) ==
             {:error, :stale_attempt_open_position}

    refute_received {:permit_received, ^worker, _}
    stop_fixture(fixture, entry.coordinator, control)
  end

  defp settlement(digest) do
    {:ok, opened} = ProviderAttempt.opened_record(%{identity() | staged_request_digest: digest})

    reply = %{
      "text" => "{\"summary\":\"done\",\"carry_forward\":\"\"}",
      "identity" => %{
        "provider" => "scripted",
        "model" => "summary:v1",
        "endpoint" => "in-process"
      },
      "usage" => %{"status" => "reported", "input_tokens" => 3, "output_tokens" => 2},
      "tool_calls" => [],
      "delta_count" => 0,
      "streamed" => false,
      "provider_response_id" => nil,
      "staged_request_digest" => digest,
      "completion" => "natural",
      "continuation" => nil
    }

    Map.merge(opened, %{
      :kind => "maintenance_attempt_settled_v3",
      "transport" => "dispatched_or_unknown",
      "termination" => nil,
      "conversation" => "canonical",
      "next" => "terminal",
      "result" => %{"kind" => "reply", "reply" => reply},
      "accounting" => %{"source" => "reported", "input_tokens" => 3, "output_tokens" => 2}
    })
  end

  defp identity do
    %{
      episode_id: "episode-1",
      summary_ordinal: 1,
      purpose: "compaction",
      operation_id: "summary-operation-1",
      attempt: 1,
      staged_request_digest: String.duplicate("d", 64)
    }
  end

  defp fixture do
    fixture = Fixture.start(script: [], tools: [])
    on_exit(fn -> Fixture.stop(fixture) end)

    {:ok, session} =
      Loopex.create_session(fixture.runtime, %{},
        command_id: "create",
        genesis: Genesis.genesis([])
      )

    {:ok, %{control: control}} = Loopex.Runtime.children(fixture.runtime)
    entry = :sys.get_state(control).sessions[session]
    {fixture, session, control, entry}
  end

  defp worker do
    observer = self()

    {pid, monitor} =
      spawn_monitor(fn ->
        receive do
          {:loopex_provider_permit, _, _} = permit ->
            send(observer, {:permit_received, self(), permit})
            receive do: (:stop -> :ok)

          :stop ->
            :ok
        end
      end)

    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)
    {pid, monitor}
  end

  defp dispatch(control, entry, binding, worker, position, options \\ []) do
    authority = %{
      runtime_id: :sys.get_state(control).runtime_id,
      owner: entry.owner,
      coordinator: entry.coordinator,
      worker: worker,
      permit_reference: make_ref(),
      journal_version: position,
      attempt_open_version: Keyword.get(options, :attempt_open_version, position),
      deadline: Keyword.get(options, :deadline, System.system_time(:millisecond) + 60_000)
    }

    reply_alias = :erlang.alias([:reply])

    send(
      control,
      {:"$gen_call", {entry.coordinator, [:alias | reply_alias]},
       {:provider_dispatch, binding, authority}}
    )

    assert_receive {[:alias | ^reply_alias], result}, 5_000
    :erlang.unalias(reply_alias)
    result
  end

  defp stop_worker(pid, monitor) do
    send(pid, :stop)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 5_000
  end

  defp stop_fixture(fixture, coordinator, control) do
    monitors = Enum.map([coordinator, control], &{&1, Process.monitor(&1)})
    assert :ok = Loopex.stop(fixture.runtime)

    for {pid, monitor} <- monitors do
      assert_receive {:DOWN, ^monitor, :process, ^pid, reason}, 5_000
      assert reason in [:normal, :shutdown]
    end
  end
end

Code.require_file("support/shutdown_witness.exs", __DIR__)

defmodule Loopex.Runtime.MaintenanceShutdownTest do
  @moduledoc false
  use ExUnit.Case, async: false

  alias Loopex.AgentLoopFixture, as: Fixture
  alias Loopex.AgentLoopTestModel
  alias Loopex.ConfiguredGenesisFixture, as: Genesis
  alias Loopex.Runtime.{OwnerGroup, ProviderAttempt}
  alias Loopex.ShutdownWitness

  test "public stop joins the original coordinator and held maintenance attempt without reports" do
    observer = self()
    saved = ShutdownWitness.install_logger(:loopex_maintenance_shutdown_witness, observer)
    cleanup_key = {__MODULE__, make_ref()}

    try do
      configuration = Genesis.configuration()

      selection = %{
        "model" => configuration["model"],
        "reasoning" => "none",
        "model_capabilities" => %{
          configuration["model_capabilities"]
          | "reasoning_levels" => ["none", "default"]
        },
        "provider_mapping" => %{configuration["provider_mapping"] | "thinking_disabled" => true}
      }

      fixture =
        Fixture.start(
          script: [
            %{text: "retain this fact", calls: [], reply_overrides: natural()},
            %{
              text:
                ~s({"summary":"retain this fact","carry_forward":{"files_read":[],"files_changed":[]}}),
              calls: [],
              hold: observer,
              reply_overrides: natural()
            }
          ],
          tools: [],
          maintenance_model: selection,
          maintenance_instructions: %{"version" => "summary.v1", "body" => "Keep facts"}
        )

      with_original_cleanup(
        [fixture.runtime.supervisor, fixture.model, fixture.executor, fixture.store],
        cleanup_key,
        fn ->
          setup_cutoff = now_ms() + 5_000
          {:ok, session} = Loopex.create_session(fixture.runtime, %{}, command_id: "create")
          {:ok, attachment} = Loopex.attach(fixture.runtime, session, after_event_sequence: 0)

          assert {:accepted, "history"} =
                   Loopex.command(attachment, %{
                     type: :prompt,
                     command_id: "history",
                     content: "retain this fact"
                   })

          await_history(fixture, session, setup_cutoff)

          # Concept: natural callback completion cannot establish this stop result.
          # Technical depth: the adapter's existing five-second hold starts after
          # this conservative cutoff is captured, before the actual compact call.
          hold_cutoff = now_ms() + 5_000

          assert {:accepted, "compact"} =
                   Loopex.command(attachment, %{
                     type: :compact,
                     command_id: "compact",
                     bounds: %{
                       "max_attempts" => 4,
                       "deadline_ms" => 60_000,
                       "token_budget" => 32_768
                     }
                   })

          assert_receive {:holding, callback}, max(setup_cutoff - now_ms(), 0)

          with_original_cleanup([callback], cleanup_key, fn ->
            assert now_ms() < setup_cutoff
            assert {:ok, children} = Loopex.Runtime.children(fixture.runtime)
            [{_, coordinator, _, _}] = Supervisor.which_children(children.sessions)
            [{_, group, _, _}] = Supervisor.which_children(children.owner_groups)
            assert {:ok, workers} = OwnerGroup.workers(group)
            tasks = Task.Supervisor.children(workers)

            {stopper, stopper_monitor} =
              spawn_monitor(fn ->
                receive do
                  :explicit_stop ->
                    assert :ok == Loopex.stop(fixture.runtime)
                    send(observer, {:explicit_stop_returned, self()})
                    receive do: (:stop -> :ok)
                end
              end)

            roles =
              Map.new(children, fn {name, actor} ->
                {actor, "runtime_" <> Atom.to_string(name)}
              end)
              |> Map.merge(Map.new(tasks, &{&1, "task"}))
              |> Map.merge(%{
                callback => "callback",
                workers => "private_supervisor",
                group => "owner_group",
                coordinator => "coordinator",
                children.sessions => "sessions",
                children.owner_groups => "owner_groups",
                fixture.runtime.supervisor => "runtime",
                stopper => "stop_caller"
              })

            with_original_cleanup(Map.keys(roles), cleanup_key, fn ->
              assert {:links, links} = Process.info(callback, :links)
              [guard] = Enum.filter(tasks, &(&1 in links))
              roles = Map.put(roles, guard, "guard")
              refute callback in tasks
              assert callback in elem(Process.info(guard, :links), 1)
              live = :sys.get_state(coordinator, remaining(setup_cutoff))
              assert live.owner_workers == workers
              assert live.durable.active_run_id == nil
              assert live.durable.pending_compact["command_id"] == "compact"

              [opened] =
                for %{payload: %{kind: "maintenance_attempt_opened_v1"} = row} <-
                      Fixture.records(fixture, session),
                    do: row

              assert {:ok, binding} = ProviderAttempt.binding_from_opened(session, opened)
              control = :sys.get_state(children.control, remaining(setup_cutoff))
              assert control.sessions[session].coordinator == coordinator
              assert {permit_worker, permit_reference} =
                       Map.fetch!(control.spent_attempts, binding)
              assert permit_worker in tasks and is_reference(permit_reference)
              [_, request] = AgentLoopTestModel.dispatched(fixture.model)
              assert request.staged_request_digest == binding["staged_request_digest"]
              episode = live.durable.maintenance_episodes[binding["episode_id"]]
              assert episode["operation_id"] == binding["operation_id"]
              assert episode["model_attempt"] == binding["attempt"]
              assert episode["request"].staged_request_digest == request.staged_request_digest

              monitors =
                Map.new(roles, fn {actor, role} ->
                  monitor = if actor == stopper, do: stopper_monitor, else: Process.monitor(actor)
                  assert Process.alive?(actor)
                  assert observer in elem(Process.info(actor, :monitored_by), 1)
                  {monitor, {actor, role}}
                end)

              run = %{
                fixture: fixture,
                owner: stopper,
                owner_monitor: stopper_monitor,
                workers: workers,
                group: group,
                owner_groups: children.owner_groups,
                sessions: children.sessions,
                roles: roles,
                monitors: monitors
              }

              assert now_ms() < setup_cutoff
              assert now_ms() + 1_000 < hold_cutoff

              evidence =
                ShutdownWitness.observe([run], :explicit_stop, "maintenance-held", true, fn _ ->
                  []
                end)

              assert now_ms() < hold_cutoff
              refute Enum.any?(evidence, &(&1["event"] == "supervisor_report"))
              downs = Enum.filter(evidence, &(&1["event"] == "original_down"))
              assert length(downs) == map_size(roles)
              assert length(Enum.uniq_by(downs, & &1["pid"])) == map_size(roles)
              assert length(Enum.uniq_by(downs, & &1["monitor"])) == map_size(roles)

              for down <- downs do
                assert down["reason"] in ["normal", "shutdown", "killed"]

                assert Enum.any?(
                         evidence,
                         &(&1["event"] == "actor_exit" and &1["pid"] == down["pid"] and
                             &1["reason"] == down["reason"])
                       )
              end

              assert Enum.any?(
                       evidence,
                       &(&1["event"] == "explicit_stop_returned" and
                           &1["pid"] == ShutdownWitness.identity(stopper))
                     )
            end)
          end)
        end
      )
    after
      Process.delete(cleanup_key)
      ShutdownWitness.restore_logger(saved)
    end
  end

  defp natural, do: %{completion: "natural", continuation: nil}

  defp await_history(fixture, session, cutoff) do
    remaining(cutoff)
    finished = Enum.any?(Fixture.events(fixture, session), &(&1.kind == "run.finished"))
    remaining(cutoff)

    unless finished do
      receive do
        :unexpected_maintenance_fixture_message -> flunk("unexpected maintenance fixture message")
      after
        min(remaining(cutoff), 1) -> await_history(fixture, session, cutoff)
      end
    end
  end

  # Concept: cleanup keeps its original monitors independently of proof consumption.
  # Technical depth: nested ownership brackets share the first captured cleanup
  # cutoff. Every action is attempted under that one fixed allowance;
  # killing on failure is cleanup only and never becomes a successful stop witness.
  defp with_original_cleanup(actors, cleanup_key, action) do
    originals = for actor <- Enum.uniq(actors), do: {actor, Process.monitor(actor)}

    try do
      action.()
    after
      cutoff =
        case Process.get(cleanup_key) do
          nil ->
            cutoff = now_ms() + 1_000
            Process.put(cleanup_key, cutoff)
            cutoff

          cutoff ->
            cutoff
        end

      ShutdownWitness.cleanup(
        Enum.map(originals, fn {actor, _monitor} ->
          fn ->
            Process.unlink(actor)
            if Process.alive?(actor), do: Process.exit(actor, :kill)
          end
        end) ++
          Enum.map(originals, fn {actor, monitor} ->
            fn ->
              assert_receive {:DOWN, ^monitor, :process, ^actor, _}, max(cutoff - now_ms(), 0)
              assert now_ms() < cutoff
            end
          end)
      )
    end
  end

  defp remaining(cutoff) do
    remaining = cutoff - now_ms()
    assert remaining > 0, "original maintenance fixture setup cutoff exhausted"
    remaining
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
end
