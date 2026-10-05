Code.require_file("support/m1_runtime_helper.exs", __DIR__)
Code.require_file("support/agent_loop_helper.exs", __DIR__)

defmodule Loopex.PrivateTaskShutdownTest do
  use ExUnit.Case, async: false

  alias Loopex.AgentLoopFixture, as: Fixture
  alias Loopex.Runtime.{OwnerGroup, ProviderLifetime}

  @filter :loopex_private_task_shutdown_witness
  @safe_reasons [:normal, :shutdown, :killed, :noproc, :private_task_fixture_fault]

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
      send(observer, {:holding, callback, child, guard})
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
          send(observer, {:managed_child_stopping, self(), :resource_stop})
          send(requester, {:loopex_provider_resource_stopped, stop, self()})
          :ok

        {:DOWN, ^callback_monitor, :process, ^callback, _} ->
          send(observer, {:managed_child_stopping, self(), :callback_down})
          child_loop(callback, callback_monitor, stop_reference, observer)
      end
    end
  end

  setup do
    {:ok, started} = Application.ensure_all_started(:logger)
    filters = :logger.get_primary_config().filters

    enabled =
      Keyword.update!(filters, :logger_translator, fn {callback, configuration} ->
        {callback, %{configuration | sasl: true}}
      end)

    :ok = :logger.set_primary_config(:filters, enabled)
    observer = self()
    :ok = :logger.add_primary_filter(@filter, {&__MODULE__.observe_report/2, observer})

    on_exit(fn ->
      :ok = :logger.remove_primary_filter(@filter)
      :ok = :logger.set_primary_config(:filters, filters)
      Enum.each(Enum.reverse(started), &Application.stop/1)
    end)

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
    run = start_fixture(:owner_exit, 1) |> hold()
    evidence = observe_shutdown([run], :supervisor_fault, "fault", false)

    assert Enum.any?(
             evidence,
             &(&1["event"] == "supervisor_report" and
                 &1["context"] == "child_terminated" and
                 &1["pid"] == identity(run.group) and
                 &1["reason"] == "owner_workers_stopped:killed")
           )

    assert Enum.any?(
             evidence,
             &(&1["event"] == "original_down" and
                 &1["pid"] == identity(run.workers) and &1["reason"] == "killed")
           )
  end

  # Concept: this observer preserves the original Logger event and its visibility.
  # Technical depth: the primary filter copies only fixed supervisor metadata;
  # no offender start function, options, request or formatted report is retained.
  def observe_report(%{msg: {:report, %{report: report}}} = event, observer)
      when is_list(report) do
    offender = Keyword.get(report, :offender, [])
    context = Keyword.get(report, :errorContext)
    pid = if is_list(offender), do: Keyword.get(offender, :pid)

    supervisor =
      case Keyword.get(report, :supervisor) do
        {pid, _} when is_pid(pid) -> pid
        pid when is_pid(pid) -> pid
        _ -> nil
      end

    if is_pid(pid) and is_pid(supervisor) and context in [:shutdown_error, :child_terminated] do
      shutdown = if is_list(offender), do: Keyword.get(offender, :shutdown)

      send(
        observer,
        {:supervisor_report, supervisor, pid, context, safe_reason(Keyword.get(report, :reason)),
         safe_shutdown(shutdown)}
      )
    end

    event
  end

  def observe_report(event, _), do: event

  defp start_fixture(mode, index) do
    observer = self()

    {owner, monitor} =
      spawn_monitor(fn ->
        fixture = Fixture.start(script: [], tools: [])
        :ok = Loopex.stop(fixture.runtime)
        {:ok, store} = Loopex.Store.new(Loopex.M1RuntimeTestStore, fixture.store)

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

        send(observer, {:fixture, self(), %{fixture | runtime: runtime}})

        receive do
          :stop ->
            :ok

          :explicit_stop ->
            :ok = Loopex.stop(runtime)
            send(observer, {:explicit_stop_returned, self()})
            receive do: (:stop -> :ok)
        end
      end)

    assert_receive {:fixture, ^owner, fixture}, 5_000

    on_exit(fn ->
      Fixture.stop(fixture)
      if Process.alive?(owner), do: send(owner, :stop)
      for agent <- [fixture.model, fixture.executor], Process.alive?(agent), do: Agent.stop(agent)
    end)

    %{fixture: fixture, owner: owner, owner_monitor: monitor, mode: mode}
  end

  defp hold(run) do
    {_session, _attachment, {:accepted, _}} = Fixture.run(run.fixture, "held shutdown")
    assert_receive {:holding, callback, child, guard}, 5_000
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

    roles = Map.put(roles, children.owner_groups, "owner_groups")

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
      group: group,
      owner_groups: children.owner_groups,
      roles: roles,
      monitors: monitors
    })
  end

  defp observe_shutdown(runs, mode, label, require_quiet \\ true) do
    observer = self()
    {collector, collector_monitor} = spawn_monitor(fn -> collect(observer, [], 0, nil, %{}) end)
    session = :trace.session_create(:loopex_private_task_shutdown, collector, [])
    cutoff = System.monotonic_time(:millisecond) + 1_000
    cleanup_key = {__MODULE__, :collector_joined, collector}
    Process.put(cleanup_key, false)

    try do
      child_pids = runs |> Enum.flat_map(&Map.keys(&1.roles)) |> Enum.uniq()

      receive_patterns =
        for pid <- child_pids, reason <- @safe_reasons, shape <- [:exit, :down] do
          message =
            case shape do
              :exit -> {:EXIT, pid, reason}
              :down -> {:DOWN, :_, :process, pid, reason}
            end

          {[:_, :_, message], [], []}
        end

      :trace.recv(session, receive_patterns, [])

      assert :trace.function(
               session,
               {DynamicSupervisor, :monitor_child, 1},
               [{[:"$1"], [], [{:message, :"$1"}, {:return_trace}]}],
               [:local]
             ) > 0

      assert :trace.function(
               session,
               {:erlang, :monitor, 2},
               for(
                 pid <- child_pids,
                 do: {[:process, pid], [], [{:message, {:const, pid}}, {:return_trace}]}
               ),
               []
             ) > 0

      for run <- runs do
        assert :trace.process(session, run.workers, true, [
                 :call,
                 :arity,
                 :receive,
                 :monotonic_timestamp
               ]) == 1
      end

      for run <- runs do
        case mode do
          :explicit_stop -> send(run.owner, :explicit_stop)
          :owner_exit -> send(run.owner, :stop)
          :supervisor_fault -> Process.exit(run.workers, :kill)
        end
      end

      monitors = Enum.reduce(runs, %{}, &Map.merge(&2, &1.monitors))

      monitors =
        if mode == :explicit_stop do
          for run <- runs do
            assert_receive {:explicit_stop_returned, owner} when owner == run.owner,
                           max(cutoff - System.monotonic_time(:millisecond), 0)

            send(run.owner, :stop)
          end

          monitors
        else
          monitors
        end

      {monitors, first_evidence} =
        if mode == :supervisor_fault do
          [run] = runs
          {reference, _} = Enum.find(run.monitors, fn {_, {pid, _}} -> pid == run.group end)

          assert_receive {:DOWN, ^reference, :process, group, {:owner_workers_stopped, :killed}}
                         when group == run.group,
                         max(cutoff - System.monotonic_time(:millisecond), 0)

          send(run.owner, :stop)

          {Map.delete(monitors, reference),
           [
             %{
               "event" => "original_down",
               "pid" => identity(run.group),
               "monitor" => identity(reference),
               "role" => "owner_group",
               "reason" => "owner_workers_stopped:killed"
             }
           ]}
        else
          {monitors, []}
        end

      evidence = join_originals(monitors, collector, cutoff, first_evidence)
      send(collector, {:finish, observer, session})

      assert_receive {:causal_trace, ^collector, records},
                     max(cutoff - System.monotonic_time(:millisecond), 0)

      assert_receive {:DOWN, ^collector_monitor, :process, ^collector, :normal},
                     max(cutoff - System.monotonic_time(:millisecond), 0)

      Process.put(cleanup_key, true)
      assert System.monotonic_time(:millisecond) <= cutoff
      evidence = evidence ++ records ++ drain_reports(runs, [])
      evidence = evidence ++ causal_classifications(evidence)
      retain(label, evidence)

      if require_quiet,
        do:
          refute(
            Enum.any?(
              evidence,
              &(&1["event"] == "supervisor_report" and
                  &1["context"] == "shutdown_error")
            ),
            inspect(evidence, limit: :infinity)
          )

      evidence
    after
      :trace.session_destroy(session)

      unless Process.delete(cleanup_key) do
        Process.exit(collector, :kill)

        assert_receive {:DOWN, ^collector_monitor, :process, ^collector, _},
                       max(cutoff - System.monotonic_time(:millisecond), 0)
      end
    end
  end

  defp join_originals(monitors, _collector, _cutoff, evidence) when map_size(monitors) == 0,
    do: Enum.reverse(evidence)

  defp join_originals(monitors, collector, cutoff, evidence) do
    receive do
      {:DOWN, reference, :process, pid, reason} when is_map_key(monitors, reference) ->
        {^pid, role} = Map.fetch!(monitors, reference)

        record = %{
          "event" => "original_down",
          "pid" => identity(pid),
          "monitor" => identity(reference),
          "role" => role,
          "reason" => safe_reason(reason),
          "observed_at_ns" => System.monotonic_time(:nanosecond)
        }

        join_originals(Map.delete(monitors, reference), collector, cutoff, [record | evidence])
    after
      max(cutoff - System.monotonic_time(:millisecond), 0) ->
        flunk("original actor monitor did not join")
    end
  end

  defp collect(_observer, _records, count, _fence, _targets) when count >= 8_192,
    do: exit(:private_task_trace_limit)

  defp collect(observer, records, count, fence, targets) do
    receive do
      {:trace_ts, pid, :call, {DynamicSupervisor, :monitor_child, 1}, child, at} ->
        record = %{
          "event" => "monitor_child",
          "supervisor" => identity(pid),
          "pid" => identity(child),
          "at_ns" => trace_time(at)
        }

        collect(observer, [record | records], count + 1, fence, Map.put(targets, pid, child))

      {:trace_ts, pid, :call, {:erlang, :monitor, 2}, child, at} ->
        record = %{
          "event" => "late_monitor_call",
          "supervisor" => identity(pid),
          "pid" => identity(child),
          "at_ns" => trace_time(at)
        }

        collect(observer, [record | records], count + 1, fence, Map.put(targets, pid, child))

      {:trace_ts, pid, :return_from, {:erlang, :monitor, 2}, reference, at}
      when is_reference(reference) ->
        record = %{
          "event" => "late_monitor_installed",
          "supervisor" => identity(pid),
          "pid" => identity(Map.fetch!(targets, pid)),
          "monitor" => identity(reference),
          "at_ns" => trace_time(at)
        }

        collect(observer, [record | records], count + 1, fence, targets)

      {:trace_ts, pid, :return_from, {DynamicSupervisor, :monitor_child, 1}, result, at} ->
        record = %{
          "event" => "monitor_child_return",
          "supervisor" => identity(pid),
          "pid" => identity(Map.fetch!(targets, pid)),
          "result" => safe_monitor_result(result),
          "at_ns" => trace_time(at)
        }

        collect(observer, [record | records], count + 1, fence, targets)

      {:trace_ts, pid, :receive, {:EXIT, child, reason}, at} ->
        record = %{
          "event" => "supervisor_exit_received",
          "supervisor" => identity(pid),
          "pid" => identity(child),
          "reason" => safe_reason(reason),
          "at_ns" => trace_time(at)
        }

        collect(observer, [record | records], count + 1, fence, targets)

      {:trace_ts, pid, :receive, {:DOWN, monitor, :process, child, reason}, at} ->
        record = %{
          "event" => "supervisor_down_received",
          "supervisor" => identity(pid),
          "pid" => identity(child),
          "monitor" => identity(monitor),
          "reason" => safe_reason(reason),
          "at_ns" => trace_time(at)
        }

        collect(observer, [record | records], count + 1, fence, targets)

      {:finish, ^observer, session} when fence == nil ->
        collect(observer, records, count, :trace.delivered(session, :all), targets)

      {:trace_delivered, :all, reference} when reference == fence ->
        send(observer, {:causal_trace, self(), Enum.reverse(records)})
    end
  end

  defp trace_time(at), do: System.convert_time_unit(at, :native, :nanosecond)
  defp safe_monitor_result(:ok), do: %{"kind" => "ok"}

  defp safe_monitor_result({:error, reason}),
    do: %{"kind" => "error", "reason" => safe_reason(reason)}

  defp safe_monitor_result(_), do: %{"kind" => "unrecognized"}

  defp drain_reports(runs, records) do
    watched = Map.new(Enum.flat_map(runs, &[{&1.workers, true}, {&1.owner_groups, true}]))
    actors = Enum.reduce(runs, %{}, &Map.merge(&2, &1.roles))

    receive do
      {:managed_child_stopping, child, route}
      when is_map_key(actors, child) and
             route in [:resource_stop, :callback_down] ->
        drain_reports(runs, [
          %{
            "event" => "managed_child_stopping",
            "pid" => identity(child),
            "route" => Atom.to_string(route)
          }
          | records
        ])

      {:supervisor_report, supervisor, child, context, reason, shutdown}
      when is_map_key(watched, supervisor) ->
        drain_reports(runs, [
          %{
            "event" => "supervisor_report",
            "supervisor" => identity(supervisor),
            "pid" => identity(child),
            "context" => Atom.to_string(context),
            "reason" => reason,
            "shutdown" => shutdown
          }
          | records
        ])
    after
      0 -> Enum.reverse(records)
    end
  end

  # Concept: a late noproc observation cannot replace the child's original exit.
  # Technical depth: classify only exact original child, supervisor and new
  # monitor identities; incomplete ordering evidence remains explicitly unknown.
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

      classification =
        cond do
          original != nil and original["reason"] == "noproc" ->
            "original_noproc"

          original != nil and original["reason"] in ["normal", "killed", "shutdown"] and
            install != nil and down != nil and returned != nil and linked_exit != nil and
            linked_exit["reason"] == original["reason"] and
              linked_exit["at_ns"] > returned["at_ns"] ->
            "late_monitor_before_linked_exit"

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

  defp retain(label, records) do
    case System.get_env("LOOPEX_PRIVATE_TASK_SHUTDOWN_EVIDENCE_DIR") do
      nil ->
        :ok

      directory ->
        expanded = Path.expand(directory)
        temporary = Path.expand(System.tmp_dir!())
        assert String.starts_with?(expanded, temporary <> "/")
        File.write!(Path.join(expanded, label <> ".json"), JSON.encode!(records))
    end
  end

  defp safe_reason({:owner_workers_stopped, :killed}), do: "owner_workers_stopped:killed"
  defp safe_reason(reason) when reason in @safe_reasons, do: Atom.to_string(reason)
  defp safe_reason(_), do: "other"
  defp safe_shutdown(:brutal_kill), do: "brutal_kill"
  defp safe_shutdown(value) when is_integer(value) and value >= 0, do: value
  defp safe_shutdown(_), do: "other"
  defp identity(value) when is_pid(value), do: List.to_string(:erlang.pid_to_list(value))
  defp identity(value) when is_reference(value), do: List.to_string(:erlang.ref_to_list(value))
end
