Code.require_file("support/m1_runtime_helper.exs", __DIR__)
Code.require_file("support/agent_loop_helper.exs", __DIR__)
Code.require_file("support/model_preparation_conformance.exs", __DIR__)

defmodule Loopex.ModelConfigurationPreparationTest do
  use ExUnit.Case, async: false
  alias Loopex.AgentLoopFixture, as: Fixture
  alias Loopex.Runtime.{SessionState, ProviderLifetime}
  alias Loopex.ModelPreparationConformance, as: Conformance

  defmodule Preparing do
    @moduledoc false
    @behaviour Loopex.Model
    @impl true
    def complete(request, options, progress) do
      Loopex.AgentLoopTestModel.complete(
        request,
        Keyword.take(options, [:script, :max_tokens]),
        progress
      )
    end

    @impl true
    def prepare_configuration(current, authored, definitions, context, options) do
      controller = Keyword.fetch!(options, :controller)

      selection =
        Agent.get_and_update(controller, fn state ->
          {state, %{state | calls: state.calls + 1}}
        end)

      send(
        selection.observer,
        {:preparing, self(), current, authored, definitions, context, options}
      )

      cond do
        selection.mode == :refuse ->
          {:error, %{private: "PRIVATE_PREPARATION_CANARY"}}

        selection.mode == :malformed ->
          {:ok, %{private: "PRIVATE_PREPARATION_CANARY"}}

        true ->
          case selection.mode do
            :raise ->
              raise "PRIVATE_PREPARATION_CANARY"

            :hold ->
              receive do
                :release -> :ok
              end

            mode when mode in [:descendant, :unproved, :hold_descendant] ->
              {:managed, starter} = ProviderLifetime.starter()

              {:ok, child} =
                ProviderLifetime.start_child(starter, fn ->
                  Process.flag(:trap_exit, true)

                  receive do
                    :never -> :ok
                  end
                end)

              send(selection.observer, {:preparation_child, child})

              if mode == :unproved do
                {:managed, _guard, _grace} = ProviderLifetime.register(child, make_ref())
              end

              if mode == :hold_descendant,
                do:
                  (receive do
                     :release -> :ok
                   end)

            :normal ->
              :ok
          end

          Conformance.candidate(current, authored, definitions, selection.model)
      end
    end
  end

  test "public configuration preserves alias identity, canonical capture and exact callback options" do
    f = fixture()
    command = configure("first")
    assert {:accepted, "first"} = Loopex.command(f.attachment, command)
    assert_receive {:preparing, worker, current, changes, [], context, options}, 1_000
    Conformance.assert_context(context, 5_000)
    assert current == f.initial
    assert changes == command.changes
    assert options == f.options
    refute Process.alive?(worker)
    assert [record] = configuration_records(f)
    assert record.payload.kind == "session_configuration_admitted_v2"
    assert record.payload["changes"] == command.changes
    assert record.payload["configuration"]["model"] == "scripted:v1"
    assert map_size(record.payload) == 8
    assert Loopex.AgentLoopTestModel.dispatched(f.model) == []
    assert Loopex.AgentLoopTestExecutor.jobs(f.executor) == []

    assert {:ok, replay} =
             SessionState.recover(
               f.session,
               Fixture.records(f, f.session),
               Fixture.events(f, f.session)
             )

    assert replay.configuration == record.payload["configuration"]
    refute :erlang.term_to_binary(Fixture.events(f, f.session)) =~ "PRIVATE_PREPARATION_CANARY"
    refute :erlang.term_to_binary(Fixture.records(f, f.session)) =~ "PRIVATE_PREPARATION_CANARY"
  end

  test "catalog drift cannot change an identical duplicate; fresh authored identity captures anew" do
    f = fixture()
    command = configure("same")
    assert {:accepted, "same"} = Loopex.command(f.attachment, command)
    assert_receive {:preparing, _, _, _, _, _, _}, 1_000
    Agent.update(f.controller, &%{&1 | model: "scripted:v2"})
    assert {:accepted, "same"} = Loopex.command(f.attachment, command)
    assert Agent.get(f.controller, & &1.calls) == 1

    assert {:error, :idempotency_conflict} =
             Loopex.command(
               f.attachment,
               %{command | changes: %{"model" => "scripted:v1"}}
             )

    assert Agent.get(f.controller, & &1.calls) == 1
    assert {:accepted, "fresh"} = Loopex.command(f.attachment, configure("fresh"))
    assert_receive {:preparing, _, _, _, _, _, _}, 1_000
    assert Agent.get(f.controller, & &1.calls) == 2

    assert Enum.map(configuration_records(f), & &1.payload["configuration"]["model"]) ==
             ["scripted:v1", "scripted:v2"]
  end

  test "normal refusal and malformed or raising private callbacks retain unchanged v2 dispositions" do
    for mode <- [:raise, :malformed, :refuse] do
      f = fixture(mode: mode)

      assert {:error, :invalid_session_configuration} =
               Loopex.command(f.attachment, configure("bad"))

      assert {:error, :invalid_session_configuration} =
               Loopex.command(f.attachment, configure("bad"))

      assert Agent.get(f.controller, & &1.calls) == 1
      assert [row] = configuration_records(f)
      assert row.payload["configuration"] == nil
      assert row.payload["changes"] == configure("bad").changes
      assert {:ok, recovered} = SessionState.recover(f.session, Fixture.records(f, f.session), [])
      assert recovered.configuration == f.initial
      refute :erlang.term_to_binary(Fixture.records(f, f.session)) =~ "PRIVATE_PREPARATION_CANARY"
    end
  end

  test "missing optional callback refuses while the prepared alias facade remains usable" do
    f = fixture(adapter: Loopex.AgentLoopTestModel)
    command = configure("unsupported")
    assert {:error, :configuration_not_prepared} = Loopex.command(f.attachment, command)
    assert Agent.get(f.controller, & &1.calls) == 0
    assert {:ok, candidate} = Conformance.candidate(f.initial, command.changes, [], "scripted:v1")

    assert {:accepted, "prepared"} =
             Loopex.command_with_configuration(
               f.attachment,
               %{command | command_id: "prepared"},
               candidate
             )

    assert {:accepted, "prepared"} =
             Loopex.command_with_configuration(
               f.attachment,
               %{command | command_id: "prepared"},
               %{}
             )

    assert Loopex.AgentLoopTestModel.dispatched(f.model) == []
  end

  test "a runtime without a Model port retains missing preparation capability without dispatch" do
    f = fixture(no_model: true)

    assert {:error, :configuration_not_prepared} =
             Loopex.command(f.attachment, configure("no-port"))

    assert {:error, :configuration_not_prepared} =
             Loopex.command(f.attachment, configure("no-port"))

    assert Agent.get(f.controller, & &1.calls) == 0
    assert [record] = configuration_records(f)
    assert record.payload["configuration"] == nil
    assert {:ok, _status} = Loopex.session_status(f.runtime, f.session)
    assert Loopex.AgentLoopTestModel.dispatched(f.model) == []
    assert Loopex.AgentLoopTestExecutor.jobs(f.executor) == []
  end

  test "attachment authority and settledness refuse before the callback" do
    f = fixture()
    assert {:error, :attachment_required} = Loopex.command(nil, configure("none"))
    stale = %{f.attachment | incarnation_id: "stale-incarnation"}
    assert {:error, :session_unavailable} = Loopex.command(stale, configure("stale"))
    assert Agent.get(f.controller, & &1.calls) == 0

    assert {:accepted, "prompt"} =
             Loopex.command(
               f.attachment,
               %{type: :prompt, command_id: "prompt", content: "hold"}
             )

    assert_receive {:holding, model_worker}, 1_000

    assert {:error, :configuration_not_settled} =
             Loopex.command(f.attachment, configure("active"))

    assert Agent.get(f.controller, & &1.calls) == 0
    send(model_worker, :release)
  end

  test "successful callback cannot acknowledge before its managed descendant is joined" do
    f = fixture(mode: :descendant)
    assert {:accepted, "children"} = Loopex.command(f.attachment, configure("children"))
    assert_receive {:preparation_child, child}, 1_000
    refute Process.alive?(child)
    assert {:accepted, "children"} = Loopex.command(f.attachment, configure("children"))
  end

  test "stalled preparation keeps status serviceable and abort joins before later admission" do
    f = fixture(mode: :hold)
    caller = Task.async(fn -> Loopex.command(f.attachment, configure("held")) end)
    assert_receive {:preparing, worker, _, _, _, _, _}, 1_000
    monitor = Process.monitor(worker)
    assert {:ok, status} = Loopex.session_status(f.runtime, f.session)
    assert status.active_run_id == nil

    assert {:error, :configuration_not_settled} =
             Loopex.command(f.attachment, configure("competing"))

    assert {:error, :no_active_run} =
             Loopex.command(
               f.attachment,
               %{type: :abort, command_id: "cancel"}
             )

    assert {:error, :invalid_session_configuration} = Task.await(caller, 5_000)
    assert_receive {:DOWN, ^monitor, :process, ^worker, :killed}, 1_000
    assert Agent.get(f.controller, & &1.calls) == 1
  end

  test "retained or malformed abort commands cannot cancel a pending preparation" do
    f = fixture()

    assert {:accepted, "retained-configuration"} =
             Loopex.command(
               f.attachment,
               configure("retained-configuration")
             )

    assert_receive {:preparing, _, _, _, _, _, _}, 1_000
    abort = %{type: :abort, command_id: "retained-abort"}
    assert {:error, :no_active_run} = Loopex.command(f.attachment, abort)
    Agent.update(f.controller, &%{&1 | mode: :hold})
    caller = Task.async(fn -> Loopex.command(f.attachment, configure("held-after-abort")) end)
    assert_receive {:preparing, worker, _, _, _, _, _}, 1_000
    assert {:error, :no_active_run} = Loopex.command(f.attachment, abort)

    assert {:error, :idempotency_conflict} =
             Loopex.command(
               f.attachment,
               %{type: :abort, command_id: "retained-configuration"}
             )

    assert {:error, :invalid_command} = Loopex.command(f.attachment, %{type: :abort})
    assert Process.alive?(worker)
    assert Agent.get(f.controller, & &1.calls) == 2
    assert length(configuration_records(f)) == 1
    send(worker, :release)
    assert {:accepted, "held-after-abort"} = Task.await(caller, 5_000)
    assert {:error, :no_active_run} = Loopex.command(f.attachment, abort)
  end

  test "caller death retires callback and descendants without retaining a successful candidate" do
    f = fixture(mode: :hold_descendant)
    caller = spawn(fn -> Loopex.command(f.attachment, configure("lost")) end)
    assert_receive {:preparing, worker, _, _, _, _, _}, 1_000
    assert_receive {:preparation_child, child}, 1_000
    monitor = Process.monitor(worker)
    child_monitor = Process.monitor(child)
    caller_monitor = Process.monitor(caller)
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^caller_monitor, :process, ^caller, :killed}, 1_000
    assert_receive {:DOWN, ^monitor, :process, ^worker, :killed}, 5_000
    assert_receive {:DOWN, ^child_monitor, :process, ^child, :killed}, 1_000
    assert configuration_records(f) == []
  end

  test "runtime stop joins stalled preparation and descendants without model or executor dispatch" do
    f = fixture(mode: :hold_descendant)
    caller = Task.async(fn -> Loopex.command(f.attachment, configure("stop")) end)
    assert_receive {:preparing, worker, _, _, _, _, _}, 1_000
    assert_receive {:preparation_child, child}, 1_000
    monitor = Process.monitor(worker)
    child_monitor = Process.monitor(child)
    assert :ok = Loopex.stop(f.runtime)
    refute Process.alive?(worker)
    refute Process.alive?(child)
    assert_receive {:DOWN, ^monitor, :process, ^worker, _reason}, 5_000
    assert_receive {:DOWN, ^child_monitor, :process, ^child, _reason}, 1_000
    assert {:error, _} = Task.await(caller, 5_000)
    assert Loopex.AgentLoopTestModel.dispatched(f.model) == []
    assert configuration_records(f) == []
  end

  test "quiesce retires pending preparation before returning its committed owner fence" do
    f = fixture(mode: :hold_descendant)
    caller = Task.async(fn -> Loopex.command(f.attachment, configure("quiesce")) end)
    assert_receive {:preparing, worker, _, _, _, _, _}, 1_000
    assert_receive {:preparation_child, child}, 1_000
    monitors = Enum.map([worker, child], &{&1, Process.monitor(&1)})
    session = f.session
    assert {:ok, %{fences: %{^session => :committed}}} = Loopex.Runtime.quiesce(f.runtime)
    assert {:error, :invalid_session_configuration} = Task.await(caller, 5_000)

    for {pid, monitor} <- monitors do
      refute Process.alive?(pid)
      assert_receive {:DOWN, ^monitor, :process, ^pid, _reason}, 1_000
    end

    assert [record] = configuration_records(f)
    assert record.payload["configuration"] == nil
    assert Loopex.AgentLoopTestModel.dispatched(f.model) == []
    assert Loopex.AgentLoopTestExecutor.jobs(f.executor) == []
  end

  test "captured instruction changes retain their authored digest and reconstruct on pure replay" do
    f = fixture()

    {:ok, instructions} =
      Loopex.Runtime.Instructions.capture(%{
        "version" => "prepared.v2",
        "base" => "exact preparation instruction bytes 猫\n",
        "environment" => "",
        "appendix" => "tail"
      })

    command = configure("instructions")
    command = %{command | changes: Map.put(command.changes, "instructions", instructions)}
    assert {:accepted, "instructions"} = Loopex.command(f.attachment, command)
    assert_receive {:preparing, _, _, authored, _, _, _}, 1_000
    assert authored == command.changes
    assert [row] = configuration_records(f)
    assert row.payload["changes"]["instructions"] == Map.take(instructions, ~w(version digest))
    assert row.payload["configuration"]["instructions"] == instructions

    assert {:ok, recovered} =
             SessionState.recover(
               f.session,
               Fixture.records(f, f.session),
               Fixture.events(f, f.session)
             )

    assert recovered.configuration["instructions"] == instructions
    assert {:replayed, {:accepted, "instructions"}} = SessionState.propose(recovered, command)
    substituted = put_in(row, [:payload, "configuration", "instructions", "base"], "substituted")

    records =
      Fixture.records(f, f.session)
      |> Enum.map(fn record ->
        if record.journal_version == row.journal_version, do: substituted, else: record
      end)

    assert {:error, _} = SessionState.recover(f.session, records, Fixture.events(f, f.session))
  end

  test "restart and identical alias replay need no preparation callback or fresh catalog" do
    f = fixture()
    command = configure("before-restart")
    assert {:accepted, "before-restart"} = Loopex.command(f.attachment, command)
    assert_receive {:preparing, _, _, _, _, _, _}, 1_000
    assert :ok = Loopex.stop(f.runtime)
    model = %{module: Loopex.AgentLoopTestModel, model: "scripted:v1", options: f.options}
    assert {:ok, restarted} = Loopex.start_link(Keyword.put(f.runtime_options, :model, model))

    on_exit(fn ->
      monitor = Process.monitor(restarted.supervisor)
      if Process.alive?(restarted.supervisor), do: Loopex.stop(restarted)
      assert_receive {:DOWN, ^monitor, :process, _pid, _reason}, 5_000
    end)

    assert {:ok, session} = Loopex.resume_session(restarted, f.session, command_id: "resume")
    assert session == f.session
    assert {:ok, attachment} = Loopex.attach(restarted, session, after_event_sequence: 0)
    assert {:accepted, "before-restart"} = Loopex.command(attachment, command)
    assert Agent.get(f.controller, & &1.calls) == 1
    assert [row] = configuration_records(f)
    assert row.payload["configuration"]["model"] == "scripted:v1"
    assert {:ok, status} = Loopex.session_status(restarted, session)
    assert status.configuration["model"] == "scripted:v1"
    assert Loopex.AgentLoopTestModel.dispatched(f.model) == []
  end

  test "unknown configuration presents the frozen original transaction without another callback" do
    f = fixture()
    kind = "session_configuration_admitted_v2"
    :ok = Loopex.M1RuntimeTestStore.hold_next_record_before_linearization(f.store, kind, self())
    :ok = Loopex.M1RuntimeTestStore.observe_representations(f.store, self())
    parent = self()

    caller =
      spawn(fn ->
        send(parent, {:configured, self(), Loopex.command(f.attachment, configure("unknown"))})
      end)

    caller_monitor = Process.monitor(caller)
    assert_receive {:preparing, callback, _, _, _, _, _}, 1_000
    assert_receive {:record_held_before_linearization, waiter, store, ^kind, transaction}, 5_000
    assert store == f.store
    refute Process.alive?(callback)
    assert Agent.get(f.controller, & &1.calls) == 1
    Agent.update(f.controller, &%{&1 | model: "scripted:v2"})

    :ok =
      Loopex.M1RuntimeTestStore.inject(
        f.store,
        {:session_journal_commit, :after_linearization_before_result}
      )

    Loopex.M1RuntimeTestStore.release(waiter)
    assert_receive {:configured, ^caller, {:error, :commit_unknown}}, 5_000
    assert_receive {:DOWN, ^caller_monitor, :process, ^caller, :normal}, 1_000
    assert_receive {:transaction_represented, ^store, ^transaction, {:committed, _, _}}, 5_000
    await_disposition(f.attachment, "unknown", {:committed, :admitted, :accepted, nil})
    assert {:accepted, "unknown"} = Loopex.command(f.attachment, configure("unknown"))
    assert Agent.get(f.controller, & &1.calls) == 1
    assert [row] = configuration_records(f)
    assert row.payload == hd(transaction.records)
    assert row.payload["configuration"]["model"] == "scripted:v1"

    assert {:ok, recovered} =
             SessionState.recover(
               f.session,
               Fixture.records(f, f.session),
               Fixture.events(f, f.session)
             )

    assert recovered.configuration == row.payload["configuration"]
  end

  test "owner loss joins callback and managed descendants before a successor can prepare" do
    f = fixture(mode: :hold_descendant)
    caller = Task.async(fn -> Loopex.command(f.attachment, configure("old-owner")) end)
    assert_receive {:preparing, callback, _, _, _, _, _}, 1_000
    assert_receive {:preparation_child, child}, 1_000
    {:ok, children} = Loopex.Runtime.Supervisor.children(f.runtime.supervisor)
    [{_, owner, _, _}] = DynamicSupervisor.which_children(children.sessions)
    owner_state = :sys.get_state(owner)
    pending = owner_state.configuration_preparation
    members = [pending.task.pid, callback, child]
    assert Enum.all?(members, &(&1 in Task.Supervisor.children(owner_state.owner_workers)))
    owner_monitor = Process.monitor(owner)
    monitored = Enum.map(members, &{&1, Process.monitor(&1)})
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^owner_monitor, :process, ^owner, :killed}, 5_000
    Agent.update(f.controller, &%{&1 | mode: :normal})
    assert {:ok, session} = Loopex.resume_session(f.runtime, f.session, command_id: "successor")
    assert session == f.session
    assert Enum.all?(members, &(not Process.alive?(&1)))
    assert {:error, _} = Task.await(caller, 5_000)

    for {pid, monitor} <- monitored do
      assert_receive {:DOWN, ^monitor, :process, ^pid, _reason}, 1_000
    end

    assert configuration_records(f) == []
    assert {:ok, successor} = Loopex.attach(f.runtime, session, after_event_sequence: 0)
    assert {:accepted, "new-owner"} = Loopex.command(successor, configure("new-owner"))
    assert Agent.get(f.controller, & &1.calls) == 2
    assert [row] = configuration_records(f)
    assert row.payload["command_id"] == "new-owner"
  end

  # Concept: owner loss before async startup is reachable through the real runtime.
  # Technical depth: hold only this private supervisor's first start and reply;
  # retain the actual owner monitor chain and shutdown report, not a claim about
  # earlier reports or registered-resource cleanup. Every new wait shares 1,000 ms.
  test "configuration owner loss before task startup retains the actual compound shutdown chain" do
    cutoff = System.monotonic_time(:millisecond) + 1_000
    f = fixture()
    observer = self()
    nonce = make_ref()
    key = {__MODULE__, :startup_witness, nonce}
    Process.put(key, %{pending: %{}, joined: []})

    for pid <- [f.runtime.supervisor, f.controller, f.model, f.executor, f.store] do
      startup_monitor(key, pid)
    end

    filters = :logger.get_primary_config().filters
    filter = :loopex_configuration_startup_witness
    Process.put({key, :resources}, %{collector: nil, session: nil, filters: filters})
    Process.put({key, :complete}, false)

    try do
      resolved =
        GenServer.call(f.runtime.supervisor, :which_children, startup_left(cutoff))
        |> Map.new(fn {id, pid, _type, _modules} -> {id, pid} end)

      for id <- [
            Loopex.ToolRegistry,
            Loopex.Runtime.Control,
            Loopex.Runtime.Workers,
            Loopex.Runtime.OwnerGroups,
            Loopex.Runtime.SessionSupervisor,
            Loopex.Runtime.EventDispatcher,
            Loopex.Trace
          ] do
        assert is_pid(Map.get(resolved, id))
      end

      control = :sys.get_state(Map.fetch!(resolved, Loopex.Runtime.Control), startup_left(cutoff))
      %{coordinator: owner, owner_group: group} = Map.fetch!(control.sessions, f.session)
      owner_monitor = startup_monitor(key, owner)
      startup_monitor(key, group)
      %{owner_workers: workers} = :sys.get_state(owner, startup_left(cutoff))
      startup_monitor(key, workers)

      assert %{workers: ^workers, coordinator: ^owner, monitor: group_owner_monitor} =
               :sys.get_state(group, startup_left(cutoff))

      actors = MapSet.new([owner, group, workers])

      {collector, collector_monitor} =
        spawn_monitor(fn ->
          startup_acquire(observer, owner, group, workers, actors, cutoff, [])
        end)

      startup_track(key, collector_monitor, collector)
      Process.put({key, :resources}, %{collector: collector, session: nil, filters: filters})
      session = :trace.session_create(:loopex_configuration_startup_witness, collector, [])
      Process.put({key, :resources}, %{collector: collector, session: session, filters: filters})

      assert [] == GenServer.call(workers, :which_children, startup_left(cutoff))
      startup_install_trace(session, owner, group, workers)

      enabled =
        Enum.map(filters, fn
          {:logger_translator, {callback, config}} ->
            {:logger_translator, {callback, %{config | sasl: true}}}

          entry ->
            entry
        end)

      :ok = :logger.set_primary_config(:filters, enabled)

      :ok =
        :logger.add_primary_filter(
          filter,
          {&__MODULE__.observe_startup_report/2, {observer, workers}}
        )

      debug = {observer, owner, nonce, cutoff, :before_start}
      :ok = :sys.install(workers, {nonce, &startup_barrier/3, debug}, startup_left(cutoff))

      {caller, caller_monitor} =
        spawn_monitor(fn ->
          send(
            observer,
            {:startup_command_result, nonce, self(),
             Loopex.command(f.attachment, configure("pre-start-owner-loss"))}
          )
        end)

      startup_track(key, caller_monitor, caller)
      assert_receive {:startup_blocked, ^nonce, ^workers}, startup_left(cutoff)
      Process.exit(owner, :kill)
      assert_receive {:DOWN, ^owner_monitor, :process, ^owner, :killed}, startup_left(cutoff)
      startup_joined(key, owner_monitor, owner, :killed)

      assert_receive {:startup_stop_sent, ^collector, ^group, ^workers, stop_reference},
                     startup_left(cutoff)

      {observed_at, observations} =
        startup_queued_stop(workers, group, stop_reference, cutoff, 64)

      send(
        collector,
        {:startup_stop_observed, observer, group, workers, stop_reference, observed_at,
         observations}
      )

      assert_receive {:startup_stop_enqueued, ^collector, ^group, ^workers}, startup_left(cutoff)
      send(workers, {:startup_release, nonce, :start})
      assert_receive {:startup_started, ^nonce, ^workers, child}, startup_left(cutoff)
      # Concept: the child join can be late; its traced exit preserves the cause.
      # Technical depth: accept noproc only for this test monitor, never in place
      # of the child's own exact owner-monitor DOWN and compound exit below.
      child_monitor = startup_monitor(key, child)

      assert_receive {:startup_child_exited, ^collector, ^child, {:shutdown, :noproc}},
                     startup_left(cutoff)

      assert_receive {:DOWN, ^child_monitor, :process, ^child, child_reason}
                     when child_reason in [{:shutdown, :noproc}, :noproc],
                     startup_left(cutoff)

      startup_joined(key, child_monitor, child, child_reason)
      assert startup_queued(workers, group, child)
      send(workers, {:startup_release, nonce, :finish})

      assert_receive {:startup_supervisor_report, ^workers, ^child, {:shutdown, :noproc}, 5_000},
                     startup_left(cutoff)

      assert_receive {:startup_command_result, ^nonce, ^caller, {:error, _}}, startup_left(cutoff)
      assert Agent.get(f.controller, & &1.calls, startup_left(cutoff)) == 0

      records =
        GenServer.call(f.store, :inspect_state, startup_left(cutoff)).sessions
        |> Map.get(f.session, %{records: []})
        |> Map.fetch!(:records)

      assert Enum.filter(records, &(&1.payload.kind == "session_configuration_admitted_v2")) == []
      assert Agent.get(f.model, & &1.seen, startup_left(cutoff)) |> Enum.reverse() == []
      assert Agent.get(f.executor, & &1.jobs, startup_left(cutoff)) |> Enum.reverse() == []

      startup_join_set(key, MapSet.new([group, workers, caller]), cutoff)
      :ok = Supervisor.stop(f.runtime.supervisor, :normal, startup_left(cutoff))

      for pid <- [f.controller, f.model, f.executor, f.store] do
        :ok = GenServer.stop(pid, :normal, startup_left(cutoff))
      end

      startup_join_set(
        key,
        MapSet.new([f.runtime.supervisor, f.controller, f.model, f.executor, f.store]),
        cutoff
      )

      send(collector, {:startup_finish, observer, session})
      assert_receive {:startup_trace, ^collector, records}, startup_left(cutoff)

      assert_receive {:DOWN, ^collector_monitor, :process, ^collector, :normal},
                     startup_left(cutoff)

      startup_joined(key, collector_monitor, collector, :normal)

      evidence =
        records ++
          [
            %{
              "event" => "supervisor_report",
              "supervisor" => startup_identity(workers),
              "pid" => startup_identity(child),
              "reason" => "shutdown:noproc",
              "shutdown" => 5_000
            }
          ]

      startup_retain("runtime-startup-chain", evidence)
      startup_assert_chain(records, owner, group, workers, child, group_owner_monitor)
      assert Process.get(key).pending == %{}
      assert System.monotonic_time(:millisecond) <= cutoff
      Process.put({key, :complete}, true)
    after
      %{collector: collector, session: session} = Process.get({key, :resources})
      # Concept: a failed assertion retains incomplete evidence and original joins.
      # Technical depth: no fresh monitor, timeout or successful-cleanup fiction
      # replaces an original DOWN. Test-owned linked actors are unlinked only for
      # failure disposal; the runtime ownership schedule above is left intact.
      for {_reference, pid} <- Process.get(key).pending,
          pid != collector and Process.alive?(pid) do
        Process.unlink(pid)
        Process.exit(pid, :kill)
      end

      cleanup =
        try do
          startup_join_set(
            key,
            MapSet.new(Map.values(Process.get(key).pending)) |> MapSet.delete(collector),
            cutoff
          )

          if is_pid(collector) and Process.alive?(collector) do
            send(collector, {:startup_finish, observer, session})

            receive do
              {:startup_trace, ^collector, records} ->
                startup_retain("runtime-startup-partial", records)
            after
              startup_left(cutoff) -> :unproved
            end
          end

          startup_join_set(key, MapSet.new([collector]), cutoff)
          :joined
        catch
          _, _ -> :unproved
        end

      if session != nil, do: :trace.session_destroy(session)
      :logger.remove_primary_filter(filter)
      :ok = :logger.set_primary_config(:filters, filters)
      evidence = Process.delete(key)

      startup_retain("runtime-startup-cleanup", %{
        "joined" => Enum.reverse(evidence.joined),
        "unjoined" =>
          Enum.map(evidence.pending, fn {reference, pid} ->
            %{"pid" => startup_identity(pid), "monitor" => startup_identity(reference)}
          end),
        "status" => Atom.to_string(cleanup),
        "cutoff_met" => System.monotonic_time(:millisecond) <= cutoff
      })

      Process.delete({key, :resources})

      if Process.delete({key, :complete}) do
        assert cleanup == :joined
        assert evidence.pending == %{}
        assert System.monotonic_time(:millisecond) <= cutoff
      end
    end
  end

  test "uncertain registered cleanup never admits a candidate or another mutation" do
    f = fixture(mode: :unproved)
    caller = Task.async(fn -> Loopex.command(f.attachment, configure("unproved")) end)
    assert_receive {:preparation_child, child}, 1_000
    monitor = Process.monitor(child)
    assert {:error, :provider_call_failed} = Task.await(caller, 10_000)
    assert_receive {:DOWN, ^monitor, :process, ^child, :killed}, 1_000
    assert configuration_records(f) == []

    assert {:error, :runtime_unavailable} =
             Loopex.command(f.attachment, configure("after-unproved"))

    assert {:ok, _status} = Loopex.session_status(f.runtime, f.session)
    assert Agent.get(f.controller, & &1.calls) == 1
    assert Loopex.AgentLoopTestModel.dispatched(f.model) == []
    assert Loopex.AgentLoopTestExecutor.jobs(f.executor) == []
  end

  @tag long_bound: true
  @tag timeout: 75_000
  test "the actual captured 60000 millisecond preparation cutoff retires a stalled callback" do
    f = fixture(mode: :hold)
    caller = Task.async(fn -> Loopex.command(f.attachment, configure("deadline")) end)
    assert_receive {:preparing, worker, _, _, _, context, _}, 1_000
    monitor = Process.monitor(worker)
    start = System.monotonic_time(:millisecond)
    Conformance.assert_context(context, 5_000)
    assert {:error, :invalid_session_configuration} = Task.await(caller, 70_000)
    assert System.monotonic_time(:millisecond) >= context.deadline_monotonic_ms
    assert System.monotonic_time(:millisecond) - start >= 59_000
    assert_receive {:DOWN, ^monitor, :process, ^worker, :killed}, 1_000
    assert hd(configuration_records(f)).payload["configuration"] == nil
  end

  defp startup_left(cutoff), do: max(cutoff - System.monotonic_time(:millisecond), 0)
  defp startup_identity(pid) when is_pid(pid), do: List.to_string(:erlang.pid_to_list(pid))
  defp startup_identity(ref) when is_reference(ref), do: List.to_string(:erlang.ref_to_list(ref))
  defp startup_reason({:shutdown, :noproc}), do: "shutdown:noproc"

  defp startup_reason(reason) when reason in [:normal, :shutdown, :noproc, :killed],
    do: Atom.to_string(reason)

  defp startup_reason(_), do: "other"

  defp startup_monitor(key, pid) do
    reference = Process.monitor(pid)
    startup_track(key, reference, pid)
    reference
  end

  defp startup_track(key, reference, pid) do
    state = Process.get(key)
    Process.put(key, %{state | pending: Map.put(state.pending, reference, pid)})
  end

  defp startup_joined(key, reference, pid, reason) do
    state = Process.get(key)
    ^pid = Map.fetch!(state.pending, reference)

    record = %{
      "pid" => startup_identity(pid),
      "monitor" => startup_identity(reference),
      "reason" => startup_reason(reason),
      "observed_at_ns" => System.monotonic_time(:nanosecond)
    }

    Process.put(key, %{
      pending: Map.delete(state.pending, reference),
      joined: [record | state.joined]
    })
  end

  defp startup_join_set(key, actors, cutoff) do
    pending =
      Map.filter(Process.get(key).pending, fn {_ref, pid} -> MapSet.member?(actors, pid) end)

    if map_size(pending) > 0 do
      receive do
        {:DOWN, reference, :process, pid, reason} when is_map_key(pending, reference) ->
          startup_joined(key, reference, pid, reason)
          startup_join_set(key, actors, cutoff)
      after
        startup_left(cutoff) -> exit(:runtime_startup_join_unproved)
      end
    end
  end

  defp startup_barrier(
         {observer, owner, nonce, cutoff, :before_start},
         {:in, {:"$gen_call", {owner, _tag}, {:start_task, _args, _restart, _shutdown}}},
         _name
       ) do
    send(observer, {:startup_blocked, nonce, self()})
    startup_release(nonce, :start, cutoff)
    {observer, owner, nonce, cutoff, :after_start}
  end

  defp startup_barrier(
         {observer, owner, nonce, cutoff, :after_start},
         {:out, {:ok, child}, {owner, _tag}, _state},
         _name
       ) do
    send(observer, {:startup_started, nonce, self(), child})
    startup_release(nonce, :finish, cutoff)
    :done
  end

  defp startup_barrier(state, _event, _name), do: state

  defp startup_release(nonce, phase, cutoff) do
    receive do
      {:startup_release, ^nonce, ^phase} -> :ok
    after
      startup_left(cutoff) -> exit(:runtime_startup_barrier_unproved)
    end
  end

  defp startup_install_trace(session, owner, group, workers) do
    patterns =
      for reason <- [:normal, :shutdown, :noproc, :killed, {:shutdown, :noproc}] do
        [
          {[:_, :_, {:EXIT, :"$1", reason}], [{:is_pid, :"$1"}], []},
          {[:_, :_, {:DOWN, :"$1", :process, :"$2", reason}],
           [{:is_reference, :"$1"}, {:is_pid, :"$2"}], []}
        ]
      end

    :trace.recv(session, List.flatten(patterns), [])

    assert :trace.function(
             session,
             {:erlang, :monitor, 2},
             [
               {[:process, owner], [], [{:message, {:const, owner}}, {:return_trace}]},
               {[:process, :"$1"], [{:"=:=", {:self}, workers}, {:is_pid, :"$1"}],
                [{:message, :"$1"}, {:return_trace}]}
             ],
             []
           ) > 0

    assert :trace.function(
             session,
             {DynamicSupervisor, :monitor_child, 1},
             [
               {[:"$1"], [{:"=:=", {:self}, workers}, {:is_pid, :"$1"}],
                [{:message, :"$1"}, {:return_trace}]}
             ],
             [:local]
           ) > 0

    assert :trace.send(
             session,
             [
               {[workers, {:system, {group, :"$1"}, {:terminate, :shutdown}}],
                [{:"=:=", {:self}, group}, {:is_reference, :"$1"}], []}
             ],
             []
           ) == 1

    assert :trace.function(
             session,
             {:erlang, :unlink, 1},
             [
               {[:"$1"], [{:"=:=", {:self}, workers}, {:is_pid, :"$1"}],
                [{:message, :"$1"}, {:return_trace}]}
             ],
             []
           ) > 0

    for pid <- [owner, group] do
      assert :trace.process(session, pid, true, [
               :call,
               :arity,
               :procs,
               :receive,
               :monotonic_timestamp
             ]) == 1
    end

    assert :trace.process(session, group, true, [:send]) == 1

    assert :trace.process(session, workers, true, [
             :call,
             :arity,
             :procs,
             :receive,
             :monotonic_timestamp,
             :set_on_first_spawn
           ]) == 1
  end

  # Concept: acquire only this supervisor's one async child after the real stop.
  # Technical depth: retain the exact group's send event and the separate bounded
  # queue observation before spawn. Child frames wait for acquisition and the actor
  # set then seals; no arguments, requests or recursively discovered actors persist.
  defp startup_acquire(_observer, _owner, _group, _workers, _actors, _cutoff, records)
       when length(records) >= 8_192 do
    startup_retain("runtime-startup-partial", Enum.reverse(records))
    exit(:runtime_startup_trace_limit)
  end

  defp startup_acquire(observer, owner, group, workers, actors, cutoff, records) do
    receive do
      {:trace_ts, ^group, :send, {:system, {^group, reference}, {:terminate, :shutdown}},
       ^workers, at}
      when is_reference(reference) ->
        assert not Enum.any?(records, &(&1["event"] == "stop_send"))

        record =
          Map.put(
            startup_record("stop_send", group, workers, at),
            "monitor",
            startup_identity(reference)
          )

        send(observer, {:startup_stop_sent, self(), group, workers, reference})
        startup_acquire(observer, owner, group, workers, actors, cutoff, [record | records])

      {:startup_stop_observed, ^observer, ^group, ^workers, reference, at, observations}
      when is_reference(reference) and is_integer(at) and observations in 1..64 ->
        assert Enum.any?(
                 records,
                 &(&1["event"] == "stop_send" and &1["monitor"] == startup_identity(reference))
               )

        assert not Enum.any?(records, &(&1["event"] == "stop_enqueued"))

        record =
          startup_record("stop_enqueued", group, workers, at)
          |> Map.put("monitor", startup_identity(reference))
          |> Map.put("observations", observations)

        send(observer, {:startup_stop_enqueued, self(), group, workers})
        startup_acquire(observer, owner, group, workers, actors, cutoff, [record | records])

      {:trace_ts, ^workers, :spawn, child, {Task.Supervised, :reply, _args}, at}
      when is_pid(child) ->
        record = startup_record("child_acquired", workers, child, at)

        startup_collect(
          observer,
          owner,
          group,
          workers,
          child,
          MapSet.put(actors, child),
          cutoff,
          [record | records],
          %{},
          nil
        )

      {:trace_ts, ^workers, :spawn, _child, _mfa, _at} ->
        startup_retain("runtime-startup-partial", Enum.reverse(records))
        exit(:runtime_startup_unexpected_spawn)
    after
      startup_left(cutoff) ->
        startup_retain("runtime-startup-partial", Enum.reverse(records))
        exit(:runtime_startup_acquisition_unproved)
    end
  end

  defp startup_record(event, actor, target, at) do
    %{
      "event" => event,
      "actor" => startup_identity(actor),
      "target" => startup_identity(target),
      "at_ns" => System.convert_time_unit(at, :native, :nanosecond)
    }
  end

  defp startup_collect(
         _observer,
         _owner,
         _group,
         _workers,
         _child,
         _actors,
         _cutoff,
         records,
         _targets,
         _fence
       )
       when length(records) >= 8_192 do
    startup_retain("runtime-startup-partial", Enum.reverse(records))
    exit(:runtime_startup_trace_limit)
  end

  defp startup_collect(
         observer,
         owner,
         group,
         workers,
         child,
         actors,
         cutoff,
         records,
         targets,
         fence
       ) do
    receive do
      {:startup_finish, ^observer, session} when fence == nil ->
        startup_collect(
          observer,
          owner,
          group,
          workers,
          child,
          actors,
          cutoff,
          records,
          targets,
          :trace.delivered(session, :all)
        )

      {:trace_delivered, :all, reference} when reference == fence and fence != nil ->
        startup_retain("runtime-startup-trace", Enum.reverse(records))
        send(observer, {:startup_trace, self(), Enum.reverse(records)})

      frame ->
        {record, updated} =
          try do
            startup_frame(frame, actors, targets, child, observer)
          catch
            kind, reason ->
              startup_retain("runtime-startup-partial", Enum.reverse(records))
              :erlang.raise(kind, reason, __STACKTRACE__)
          end

        startup_collect(
          observer,
          owner,
          group,
          workers,
          child,
          actors,
          cutoff,
          [record | records],
          updated,
          fence
        )
    after
      startup_left(cutoff) ->
        startup_retain("runtime-startup-partial", Enum.reverse(records))
        exit(:runtime_startup_trace_deadline)
    end
  end

  defp startup_frame(
         {:trace_ts, pid, :call, {DynamicSupervisor, :monitor_child, 1}, target, at},
         actors,
         targets,
         _child,
         _observer
       ) do
    assert MapSet.member?(actors, pid) and MapSet.member?(actors, target)

    {startup_record("monitor_child_call", pid, target, at),
     Map.put(targets, {pid, :monitor_child}, target)}
  end

  defp startup_frame(
         {:trace_ts, pid, :return_from, {DynamicSupervisor, :monitor_child, 1}, result, at},
         actors,
         targets,
         _child,
         _observer
       ) do
    assert MapSet.member?(actors, pid)

    rendered =
      case result do
        :ok -> "ok"
        {:error, {:shutdown, :noproc}} -> "error:shutdown:noproc"
        _ -> "other"
      end

    record =
      Map.put(
        startup_record(
          "monitor_child_return",
          pid,
          Map.fetch!(targets, {pid, :monitor_child}),
          at
        ),
        "result",
        rendered
      )

    {record, targets}
  end

  defp startup_frame(
         {:trace_ts, pid, :call, {:erlang, function, arity}, target, at},
         actors,
         targets,
         _child,
         _observer
       )
       when (function == :monitor and arity == 2) or (function == :unlink and arity == 1) do
    assert MapSet.member?(actors, pid) and MapSet.member?(actors, target)

    {startup_record(Atom.to_string(function) <> "_call", pid, target, at),
     Map.put(targets, {pid, function}, target)}
  end

  defp startup_frame(
         {:trace_ts, pid, :return_from, {:erlang, :monitor, 2}, ref, at},
         actors,
         targets,
         _child,
         _observer
       )
       when is_reference(ref) do
    assert MapSet.member?(actors, pid)
    target = Map.fetch!(targets, {pid, :monitor})

    record =
      Map.put(
        startup_record("monitor_installed", pid, target, at),
        "monitor",
        startup_identity(ref)
      )

    {record, targets}
  end

  defp startup_frame(
         {:trace_ts, pid, :return_from, {:erlang, :unlink, 1}, true, at},
         actors,
         targets,
         _child,
         _observer
       ) do
    assert MapSet.member?(actors, pid)
    {startup_record("unlink_return", pid, Map.fetch!(targets, {pid, :unlink}), at), targets}
  end

  defp startup_frame(
         {:trace_ts, pid, :receive, {:DOWN, ref, :process, target, reason}, at},
         actors,
         targets,
         _child,
         _observer
       ) do
    assert MapSet.member?(actors, pid) and MapSet.member?(actors, target)

    record =
      startup_record("down_received", pid, target, at)
      |> Map.put("monitor", startup_identity(ref))
      |> Map.put("reason", startup_reason(reason))

    {record, targets}
  end

  defp startup_frame(
         {:trace_ts, pid, :receive, {:EXIT, target, reason}, at},
         actors,
         targets,
         _child,
         _observer
       ) do
    assert MapSet.member?(actors, pid) and MapSet.member?(actors, target)

    {Map.put(startup_record("exit_received", pid, target, at), "reason", startup_reason(reason)),
     targets}
  end

  defp startup_frame({:trace_ts, pid, :exit, reason, at}, actors, targets, child, observer) do
    assert MapSet.member?(actors, pid)

    if pid == child do
      notice = if reason == {:shutdown, :noproc}, do: {:shutdown, :noproc}, else: :other
      send(observer, {:startup_child_exited, self(), child, notice})
    end

    {Map.put(startup_record("actor_exit", pid, pid, at), "reason", startup_reason(reason)),
     targets}
  end

  defp startup_frame(
         {:trace_ts, pid, :spawned, parent, {Task.Supervised, :reply, _args}, at},
         actors,
         targets,
         child,
         _observer
       )
       when pid == child do
    assert MapSet.member?(actors, parent)
    {startup_record("child_spawned", pid, parent, at), targets}
  end

  defp startup_frame({:trace_ts, pid, event, target, at}, actors, targets, _child, _observer)
       when event in [:link, :unlink, :getting_linked, :getting_unlinked] do
    assert MapSet.member?(actors, pid)

    record = %{
      "event" => Atom.to_string(event),
      "actor" => startup_identity(pid),
      "selected_target" => MapSet.member?(actors, target),
      "at_ns" => System.convert_time_unit(at, :native, :nanosecond)
    }

    {record, targets}
  end

  defp startup_frame({:trace_ts, pid, event, _name, at}, actors, targets, _child, _observer)
       when event in [:register, :unregister] do
    assert MapSet.member?(actors, pid)
    {startup_record(Atom.to_string(event), pid, pid, at), targets}
  end

  defp startup_frame(_frame, _actors, _targets, _child, _observer),
    do: exit(:runtime_startup_trace_shape)

  # Concept: a send trace and a queued request are separate observations.
  # Technical depth: while before-start is held, make at most 64 observations.
  # Only an empty queue may yield within the same cutoff; nonempty queues must
  # contain the sole exact stop/reference. No message is consumed or retained.
  defp startup_queued_stop(workers, group, reference, cutoff, remaining) do
    assert remaining in 1..64 and startup_left(cutoff) > 0

    case Process.info(workers, :message_queue_len) do
      {:message_queue_len, 0} ->
        assert remaining > 1
        :erlang.yield()
        startup_queued_stop(workers, group, reference, cutoff, remaining - 1)

      {:message_queue_len, 1} ->
        assert {:messages, [{:system, {^group, ^reference}, {:terminate, :shutdown}}]} =
                 Process.info(workers, :messages)

        observed_at = System.monotonic_time()
        assert startup_left(cutoff) > 0
        {observed_at, 65 - remaining}

      _ ->
        flunk("runtime startup stop queue has an unexpected population")
    end
  end

  # Concept: the queue read observes this controlled schedule without consuming it.
  # Technical depth: inspect only two messages on this fixture's held supervisor,
  # require its known group's stop and exact child EXIT, and discard all raw terms.
  defp startup_queued(workers, group, child) do
    assert {:message_queue_len, 2} = Process.info(workers, :message_queue_len)
    assert {:messages, messages} = Process.info(workers, :messages)
    assert length(messages) == 2

    assert Enum.all?(messages, fn
             {:system, {^group, _tag}, {:terminate, :shutdown}} -> true
             {:EXIT, ^child, {:shutdown, :noproc}} -> true
             _ -> false
           end)

    assert Enum.any?(messages, &match?({:system, {^group, _}, {:terminate, :shutdown}}, &1))
    Enum.any?(messages, &match?({:EXIT, ^child, {:shutdown, :noproc}}, &1))
  end

  defp startup_assert_chain(records, owner, group, workers, child, group_owner_monitor) do
    select = fn event, actor, target ->
      Enum.find(
        records,
        &(&1["event"] == event and &1["actor"] == startup_identity(actor) and
            &1["target"] == startup_identity(target))
      )
    end

    call = select.("monitor_call", child, owner)
    installed = select.("monitor_installed", child, owner)
    down = select.("down_received", child, owner)
    exited = select.("actor_exit", child, child)
    assert call != nil and installed != nil and down != nil and exited != nil
    assert down["monitor"] == installed["monitor"]
    assert down["reason"] == "noproc" and exited["reason"] == "shutdown:noproc"
    assert call["at_ns"] <= installed["at_ns"] and call["at_ns"] <= down["at_ns"]
    assert installed["at_ns"] <= exited["at_ns"] and down["at_ns"] <= exited["at_ns"]
    stop = select.("stop_enqueued", group, workers)
    acquired = select.("child_acquired", workers, child)
    owner_exit = select.("actor_exit", owner, owner)
    sent = select.("stop_send", group, workers)
    assert stop != nil and sent != nil and acquired != nil and owner_exit != nil
    assert stop["monitor"] == sent["monitor"]
    assert owner_exit["at_ns"] <= sent["at_ns"] and sent["at_ns"] <= stop["at_ns"]
    assert stop["at_ns"] <= acquired["at_ns"]
    group_down = select.("down_received", group, owner)
    assert group_down != nil and group_down["monitor"] == startup_identity(group_owner_monitor)
    assert group_down["reason"] == "killed" and group_down["at_ns"] <= sent["at_ns"]
    assert stop["observations"] in 1..64
    received = select.("exit_received", workers, child)
    assert received != nil and received["reason"] == "shutdown:noproc"
    unlink = select.("unlink_call", workers, child)
    assert unlink != nil and select.("unlink_return", workers, child) != nil
    returned = select.("monitor_child_return", workers, child)
    assert returned != nil and returned["result"] == "error:shutdown:noproc"
  end

  # Concept: observe the real report while preserving its Logger event unchanged.
  # Technical depth: copy only the selected supervisor's exact child and literal
  # reason/shutdown metadata. Offender MFA, request, options and formatted text
  # never enter the witness's retained trace.
  @doc false
  def observe_startup_report(%{msg: {:report, %{report: report}}} = event, {observer, workers})
      when is_list(report) do
    offender = Keyword.get(report, :offender, [])

    supervisor =
      case Keyword.get(report, :supervisor) do
        {pid, _} when is_pid(pid) -> pid
        pid when is_pid(pid) -> pid
        _ -> nil
      end

    if supervisor == workers and Keyword.get(report, :errorContext) == :shutdown_error and
         is_list(offender) do
      child = Keyword.get(offender, :pid)
      reason = Keyword.get(report, :reason)
      shutdown = Keyword.get(offender, :shutdown)

      if is_pid(child) and reason == {:shutdown, :noproc} and shutdown == 5_000,
        do: send(observer, {:startup_supervisor_report, workers, child, reason, shutdown})
    end

    event
  end

  def observe_startup_report(event, _configuration), do: event

  defp startup_retain(label, records) do
    case System.get_env("LOOPEX_RUNTIME_STARTUP_EVIDENCE_DIR") do
      nil ->
        :ok

      directory ->
        expanded = Path.expand(directory)
        assert String.starts_with?(expanded, Path.expand(System.tmp_dir!()) <> "/")
        File.write!(Path.join(expanded, label <> ".json"), JSON.encode!(records))
    end
  end

  defp configure(id),
    do: %{
      type: :configure,
      command_id: id,
      changes: %{"model" => "host-alias", "max_tokens" => 512}
    }

  defp fixture(options \\ []) do
    initial = Loopex.ConfiguredGenesisFixture.configuration()
    observer = self()

    {:ok, controller} =
      Agent.start_link(fn ->
        %{
          mode: Keyword.get(options, :mode, :normal),
          model: "scripted:v1",
          calls: 0,
          observer: observer
        }
      end)

    model = Loopex.AgentLoopTestModel.start([%{hold: observer, text: "done", calls: []}])
    executor = Loopex.AgentLoopTestExecutor.start(%{}, 0, :cleaned, nil, %{})
    {store, handle} = Loopex.M1RuntimeTestStore.start_store(label: "model-preparation")

    original = [
      controller: controller,
      script: model,
      max_tokens: 1_024,
      private_canary: "PRIVATE_PREPARATION_CANARY"
    ]

    runtime_options = [
      runtime_id: "model-preparation",
      context_token_budget: 8_192,
      store: handle,
      cleanup_grace_ms: 5_000,
      model: %{
        module: Keyword.get(options, :adapter, Preparing),
        model: "scripted:v1",
        options: original
      },
      executor: %{
        module: Loopex.AgentLoopTestExecutor,
        reference: executor,
        identity: "agent-loop-executor",
        epoch: 1,
        fencing_token: 1,
        workspace_ref: "workspace-ref",
        workspace_lease: "workspace-lease"
      },
      bounds: Fixture.bounds(),
      sampling: %{"max_tokens" => 1_024},
      tools: [],
      active_tools: [],
      policy: Loopex.AgentLoopTestPolicy,
      policy_identity: %{"id" => "test", "revision" => "1"},
      grant_decision: {:host_policy, :allow}
    ]

    runtime_options =
      if Keyword.get(options, :no_model, false),
        do: Keyword.drop(runtime_options, [:model, :executor]),
        else: runtime_options

    {:ok, runtime} = Loopex.start_link(runtime_options)

    on_exit(fn ->
      runtime_monitor = Process.monitor(runtime.supervisor)
      if Process.alive?(runtime.supervisor), do: Loopex.stop(runtime)
      assert_receive {:DOWN, ^runtime_monitor, :process, _supervisor, _reason}, 5_000

      for actor <- [controller, model, executor, store] do
        monitor = Process.monitor(actor)
        if Process.alive?(actor), do: GenServer.stop(actor, :normal, 1_000)
        assert_receive {:DOWN, ^monitor, :process, ^actor, _reason}, 1_000
      end
    end)

    {:ok, session} =
      Loopex.Runtime.create_session_with_genesis(
        runtime,
        "create",
        %{},
        Loopex.ConfiguredGenesisFixture.genesis([], initial)
      )

    {:ok, attachment} = Loopex.attach(runtime, session, after_event_sequence: 0)

    %{
      runtime: runtime,
      controller: controller,
      model: model,
      executor: executor,
      store: store,
      session: session,
      attachment: attachment,
      initial: initial,
      options: original,
      runtime_options: runtime_options
    }
  end

  defp await_disposition(attachment, command, expected, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + 5_000
    actual = Loopex.command_disposition(attachment, command)

    unless actual == {:ok, expected} do
      assert System.monotonic_time(:millisecond) < deadline, inspect(actual)
      Process.sleep(10)
      await_disposition(attachment, command, expected, deadline)
    end
  end

  defp configuration_records(f),
    do:
      Enum.filter(
        Fixture.records(f, f.session),
        &(&1.payload.kind == "session_configuration_admitted_v2")
      )
end
