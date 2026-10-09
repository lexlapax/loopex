Code.require_file("support/m1_runtime_helper.exs", __DIR__)
Code.require_file("support/agent_loop_helper.exs", __DIR__)
Code.require_file("support/shutdown_witness.exs", __DIR__)

defmodule Loopex.PrivateTaskShutdownTest do
  use ExUnit.Case, async: false

  alias Loopex.AgentLoopFixture, as: Fixture
  alias Loopex.Runtime.{OwnerGroup, ProviderLifetime}

  @filter :loopex_private_task_shutdown_witness
  defmodule HeldModel do
    @moduledoc false
    @behaviour Loopex.Model

    @impl true
    def complete(_request, options, _progress) do
      observer = Keyword.fetch!(options, :observer)
      callback = self()
      hold_cutoff = System.monotonic_time(:millisecond) + 30_000
      stop_reference = make_ref()
      {:managed, starter} = ProviderLifetime.starter()

      {:ok, child} =
        ProviderLifetime.start_child(starter, fn ->
          callback_monitor = Process.monitor(callback)
          send(observer, {:managed_child_ready, callback, self()})
          child_loop(callback, callback_monitor, stop_reference, observer)
        end)

      {:managed, guard, _grace} = ProviderLifetime.register(child, stop_reference)
      send(observer, {:holding, callback, child, guard, stop_reference})
      callback_loop(observer, hold_cutoff)
    end

    defp callback_loop(observer, cutoff) do
      receive do
        {:monitor_installed, reference} ->
          send(observer, {:monitor_confirmed, self(), reference})
          callback_loop(observer, cutoff)
      after
        max(cutoff - System.monotonic_time(:millisecond), 0) ->
          exit(:private_task_fixture_hold_expired)
      end
    end

    defp child_loop(callback, callback_monitor, stop_reference, observer) do
      receive do
        {:monitor_installed, reference} ->
          send(observer, {:monitor_confirmed, self(), reference})
          child_loop(callback, callback_monitor, stop_reference, observer)

        {:loopex_provider_resource_stop, ^stop_reference, stop, requester, _, _} ->
          send(observer, {:managed_child_stopping, self(), :resource_stop, stop, requester})
          send(requester, {:loopex_provider_resource_stopped, stop, self()})
          :ok

        {:DOWN, ^callback_monitor, :process, ^callback, _} ->
          send(observer, {:managed_child_stopping, self(), :callback_down})
          child_loop(callback, callback_monitor, stop_reference, observer)
      end
    end
  end

  setup do
    saved = Loopex.ShutdownWitness.install_logger(@filter, self())
    on_exit(fn -> Loopex.ShutdownWitness.restore_logger(saved) end)
    :ok
  end

  test "actual held provider children retain causal shutdown evidence on serial runtime stop and owner exit" do
    for mode <- [:explicit_stop, :owner_exit], index <- 1..32 do
      fixture = start_fixture(mode, index)
      run = hold(fixture)
      observe_shutdown([run], mode, "serial-#{mode}-#{index}")
    end
  end

  test "32 held provider owners join under one captured cutoff with original exit identities" do
    runs = for index <- 1..32, do: start_fixture(:owner_exit, index) |> hold()
    observe_shutdown(runs, :owner_exit, "concurrent")
  end

  test "a genuine private supervisor fault remains visible and joins real provider descendants" do
    observer = self()

    startup = %{
      msg:
        {:report,
         %{
           label: {:supervisor, :progress},
           report: [supervisor: {observer, Supervisor.Default}, started: [pid: observer]]
         }}
    }

    assert Loopex.ShutdownWitness.observe_report(startup, observer) == startup
    refute_receive {:supervisor_report, ^observer, _, _, _, _, _}, 0

    unknown = %{
      msg:
        {:report,
         %{
           report: [
             supervisor: {observer, Supervisor.Default},
             errorContext: :unknown_shutdown_context,
             reason: :shutdown,
             offender: [pid: observer, shutdown: 5_000]
           ]
         }}
    }

    assert Loopex.ShutdownWitness.observe_report(unknown, observer) == unknown

    assert_receive {:supervisor_report, ^observer, ^observer, ^observer, :unrecognized,
                    "shutdown", 5_000},
                   0

    run = start_fixture(:owner_exit, 1) |> hold()
    evidence = observe_shutdown([run], :supervisor_fault, "fault", false)

    assert Enum.any?(
             evidence,
             &(&1["event"] == "supervisor_report" and
                 &1["context"] == "child_terminated" and
                 &1["pid"] == identity(run.group) and
                 &1["reason"] == "owner_workers_stopped:killed" and
                 &1["shutdown"] == "infinity")
           )

    assert Enum.any?(
             evidence,
             &(&1["event"] == "original_down" and
                 &1["pid"] == identity(run.workers) and &1["reason"] == "killed")
           )
  end

  defp start_fixture(mode, index) do
    observer = self()

    {owner, monitor} =
      spawn_monitor(fn ->
        fixture = Fixture.start(script: [], tools: [])
        :ok = Loopex.stop(fixture.runtime)
        {:ok, store} = Loopex.Store.new(Loopex.M1RuntimeTestStore, fixture.store)

        startup_cutoff = System.monotonic_time(:millisecond) + 1_000

        {:ok, runtime} =
          Loopex.start_link(
            runtime_id: "private-task-shutdown-#{index}",
            store: store,
            session_creation_defaults: Fixture.creation_defaults([]),
            context_token_budget: 8_192,
            model: %{module: HeldModel, model: "scripted:v1", options: [observer: observer]},
            executor: %{
              module: Loopex.AgentLoopTestExecutor,
              reference: fixture.executor,
              identity: "agent-loop-executor",
              epoch: 1,
              fencing_token: 1,
              workspace_ref: "workspace-ref",
              workspace_lease: "workspace-lease"
            },
            tools: [],
            active_tools: [],
            policy: Loopex.AgentLoopTestPolicy,
            policy_identity: %{"id" => "loopex.test.agent_loop_policy", "revision" => "1"},
            grant_decision: {:host_policy, :allow}
          )

        readiness_cutoff = await_fixture_creation_ready(runtime, startup_cutoff)
        fixture_startup_remaining(readiness_cutoff)
        send(observer, {:fixture, self(), %{fixture | runtime: runtime}, readiness_cutoff})

        receive do
          :stop ->
            :ok

          :explicit_stop ->
            :ok = Loopex.stop(runtime)
            send(observer, {:explicit_stop_returned, self()})
            receive do: (:stop -> :ok)
        end
      end)

    assert_receive {:fixture, ^owner, fixture, readiness_cutoff}, 5_000

    on_exit(fn ->
      Loopex.ShutdownWitness.cleanup([
        fn -> Fixture.stop(fixture) end,
        fn -> if Process.alive?(owner), do: send(owner, :stop) end,
        fn -> if Process.alive?(fixture.model), do: Agent.stop(fixture.model) end,
        fn -> if Process.alive?(fixture.executor), do: Agent.stop(fixture.executor) end
      ])
    end)

    %{
      fixture: fixture,
      owner: owner,
      owner_monitor: monitor,
      mode: mode,
      readiness_cutoff: readiness_cutoff
    }
  end

  # Concept: the replacement runtime is ready before its one original create.
  # Technical depth: the existing AgentLoopFixture permits 1,000 ms to observe
  # startup. Capture that allowance before replacement start and spend only the
  # smaller original public Core cutoff, pinning its identity through every read.
  # This changes no shutdown cutoff, retry, quiet assertion or fault control.
  defp await_fixture_creation_ready(runtime, cutoff, pinned \\ nil) do
    remaining = fixture_startup_remaining(cutoff)

    assert {:ok, %{state: state, startup_id: id, startup_deadline_ms: core_cutoff} = snapshot} =
             Loopex.creation_startup_status(runtime, min(1_000, remaining))

    assert map_size(snapshot) == 3
    assert is_binary(id) and byte_size(id) == 32 and is_integer(core_cutoff)
    assert pinned in [nil, {id, core_cutoff}], "original fixture startup identity/cutoff changed"
    assert state in [:starting, :ready], "original fixture creation startup is unavailable"
    cutoff = min(cutoff, core_cutoff)
    remaining = fixture_startup_remaining(cutoff)

    case state do
      :ready ->
        cutoff

      :starting ->
        Process.sleep(min(10, remaining))
        await_fixture_creation_ready(runtime, cutoff, {id, core_cutoff})
    end
  end

  defp fixture_startup_remaining(cutoff) do
    remaining = cutoff - System.monotonic_time(:millisecond)
    assert remaining > 0, "original fixture startup observation cutoff exhausted"
    remaining
  end

  defp hold(run) do
    fixture_startup_remaining(run.readiness_cutoff)
    {_session, _attachment, {:accepted, _}} = Fixture.run(run.fixture, "held shutdown")
    assert_receive {:holding, callback, child, guard, stop_reference}, 5_000
    assert_receive {:managed_child_ready, ^callback, ^child}, 5_000
    assert {:ok, children} = Loopex.Runtime.children(run.fixture.runtime)
    [{_, group, _, _}] = Supervisor.which_children(children.owner_groups)
    [{_, coordinator, _, _}] = Supervisor.which_children(children.sessions)
    assert {:ok, workers} = OwnerGroup.workers(group)
    tasks = Task.Supervisor.children(workers)
    # Concept: the guard owns the ordinary provider callback; the private
    # supervisor owns the guard, bridge and managed resource directly.
    # Technical depth: ordinary callbacks use linked spawn_opt rather than
    # Task.Supervisor.start_child. Prove that exact live link before stopping.
    assert child in tasks and guard in tasks
    refute callback in tasks
    assert guard in elem(Process.info(callback, :links), 1)
    assert callback in elem(Process.info(guard, :links), 1)

    roles =
      Map.new(tasks, &{&1, "task"})
      |> Map.merge(%{
        callback => "callback",
        child => "managed_child",
        guard => "guard",
        workers => "private_supervisor",
        group => "owner_group",
        coordinator => "coordinator",
        run.fixture.runtime.supervisor => "runtime",
        run.owner => "owner"
      })

    roles =
      roles
      |> Map.put(children.owner_groups, "owner_groups")
      |> Map.put(children.sessions, "sessions")

    monitors =
      Map.new(roles, fn {pid, role} ->
        reference = if pid == run.owner, do: run.owner_monitor, else: Process.monitor(pid)
        assert Process.alive?(pid)
        assert self() in elem(Process.info(pid, :monitored_by), 1)
        {reference, {pid, role}}
      end)

    for pid <- [callback, child] do
      reference = make_ref()
      send(pid, {:monitor_installed, reference})
      assert_receive {:monitor_confirmed, ^pid, ^reference}, 5_000
    end

    Map.merge(run, %{
      workers: workers,
      resource: child,
      guard: guard,
      stop_reference: stop_reference,
      group: group,
      owner_groups: children.owner_groups,
      sessions: children.sessions,
      roles: roles,
      monitors: monitors
    })
  end

  defp observe_shutdown(runs, mode, label, require_quiet \\ true) do
    Loopex.ShutdownWitness.observe(runs, mode, label, require_quiet, &causal_classifications/1)
  end

  # Concept: a late noproc observation cannot replace the child's original exit.
  # Technical depth: classify only exact original child, supervisor and new
  # monitor identities. An absent received EXIT proves no raw signal history;
  # the observed unlink/exit branch says only what this fixed trace retained.
  defp causal_classifications(records) do
    for report <- records,
        report["event"] == "supervisor_report" and
          report["context"] == "shutdown_error" and report["reason"] == "noproc" do
      pid = report["pid"]
      supervisor = report["supervisor"]
      original = Enum.find(records, &(&1["event"] == "original_down" and &1["pid"] == pid))

      install =
        Enum.find(
          records,
          &(&1["event"] == "late_monitor_installed" and
              &1["pid"] == pid and &1["supervisor"] == supervisor)
        )

      down =
        Enum.find(
          records,
          &(&1["event"] == "supervisor_down_received" and
              &1["pid"] == pid and &1["supervisor"] == supervisor and &1["reason"] == "noproc" and
              install != nil and &1["monitor"] == install["monitor"])
        )

      returned =
        Enum.find(
          records,
          &(&1["event"] == "monitor_child_return" and
              &1["pid"] == pid and &1["supervisor"] == supervisor and
              &1["result"] == %{"kind" => "ok"})
        )

      linked_exit =
        Enum.find(
          records,
          &(&1["event"] == "supervisor_exit_received" and
              &1["pid"] == pid and &1["supervisor"] == supervisor)
        )

      unlink_called =
        Enum.find(
          records,
          &(&1["event"] == "unlink_call" and
              &1["pid"] == pid and &1["actor"] == supervisor)
        )

      unlinked =
        Enum.find(
          records,
          &(&1["event"] == "unlink_return" and
              &1["pid"] == pid and &1["actor"] == supervisor)
        )

      exited =
        Enum.find(
          records,
          &(&1["event"] == "actor_exit" and &1["pid"] == pid and
              original != nil and &1["reason"] == original["reason"])
        )

      classification =
        cond do
          original != nil and original["reason"] == "noproc" ->
            "original_noproc"

          original != nil and original["reason"] in ["normal", "killed", "shutdown"] and
            install != nil and down != nil and returned != nil and linked_exit != nil and
            linked_exit["reason"] == original["reason"] and
              linked_exit["at_ns"] > returned["at_ns"] ->
            "late_monitor_before_linked_exit"

          original != nil and exited != nil and install != nil and down != nil and
            returned != nil and unlink_called != nil and unlinked != nil and
            linked_exit == nil and exited["at_ns"] <= install["at_ns"] and
            install["at_ns"] <= unlink_called["at_ns"] and
            unlink_called["at_ns"] <= unlinked["at_ns"] and
            unlinked["at_ns"] <= returned["at_ns"] and
              returned["at_ns"] <= down["at_ns"] ->
            "late_monitor_noproc_without_retained_link_exit"

          true ->
            "evidence_incomplete"
        end

      %{
        "event" => "causal_classification",
        "pid" => pid,
        "supervisor" => supervisor,
        "classification" => classification
      }
    end
  end

  defp identity(value), do: Loopex.ShutdownWitness.identity(value)
end
