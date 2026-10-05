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
