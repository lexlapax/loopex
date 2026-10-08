Code.require_file("support/m1_runtime_helper.exs", __DIR__)
Code.require_file("support/agent_loop_helper.exs", __DIR__)

defmodule Loopex.PrivateTaskShutdownTest do
  use ExUnit.Case, async: false

  alias Loopex.AgentLoopFixture, as: Fixture
  alias Loopex.Runtime.{OwnerGroup, ProviderLifetime}

  @filter :loopex_private_task_shutdown_witness
  @safe_reasons [
    :normal,
    :shutdown,
    :killed,
    :noproc,
    :private_task_fixture_fault,
    :provider_cleanup_unproved
  ]

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
        {:supervisor_report, self(), supervisor, pid, context,
         safe_reason(Keyword.get(report, :reason)), safe_shutdown(shutdown)}
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
      Fixture.stop(fixture)
      if Process.alive?(owner), do: send(owner, :stop)
      for agent <- [fixture.model, fixture.executor], Process.alive?(agent), do: Agent.stop(agent)
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
    observer = self()
    actors = Enum.reduce(runs, %{}, &Map.merge(&2, &1.roles))
    actors = Map.put(actors, observer, "test_observer")
    resources = Map.new(runs, &{&1.resource, {&1.stop_reference, &1.guard}})

    {collector, collector_monitor} =
      spawn_monitor(fn -> collect(observer, [], 0, nil, %{}, actors, resources) end)

    session = :trace.session_create(:loopex_private_task_shutdown, collector, [])
    cutoff = System.monotonic_time(:millisecond) + 1_000
    cleanup_key = {__MODULE__, :collector_joined, collector}
    Process.put(cleanup_key, false)

    try do
      child_pids = runs |> Enum.flat_map(&Map.keys(&1.roles)) |> Enum.uniq()

      receive_patterns =
        for pid <- child_pids,
            reason <- @safe_reasons ++ [{:shutdown, :noproc}],
            shape <- [:exit, :down] do
          message =
            case shape do
              :exit -> {:EXIT, pid, reason}
              :down -> {:DOWN, :_, :process, pid, reason}
            end

          {[:_, :_, message], [], []}
        end

      resource_patterns =
        Enum.flat_map(runs, fn run ->
          [
            {[
               :_,
               :_,
               {:loopex_provider_resource_stop, run.stop_reference, :"$1", run.guard, :_, :_}
             ], [{:is_reference, :"$1"}], []},
            {[:_, :_, {:loopex_provider_resource_stopped, :"$1", run.resource}],
             [{:is_reference, :"$1"}], []}
          ]
        end)

      :trace.recv(session, receive_patterns ++ resource_patterns, [])

      assert :trace.function(
               session,
               {DynamicSupervisor, :monitor_child, 1},
               for(
                 pid <- child_pids,
                 do: {[pid], [], [{:message, {:const, pid}}, {:return_trace}]}
               ),
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

      assert :trace.function(
               session,
               {:erlang, :unlink, 1},
               for(
                 pid <- child_pids,
                 do: {[pid], [], [{:message, {:const, pid}}, {:return_trace}]}
               ),
               []
             ) > 0

      assert :trace.function(
               session,
               {:erlang, :exit, 2},
               for(
                 pid <- child_pids,
                 reason <- [:kill, :shutdown],
                 do: {[pid, reason], [], [{:message, {:const, {pid, reason}}}]}
               ),
               []
             ) > 0

      # Concept: record the exact actors that can stop these retained resources.
      # Technical depth: arity-only calls have fixed-target match specifications;
      # no request arguments or arbitrary messages enter the evidence records.
      for pid <- Map.keys(actors) do
        assert :trace.process(session, pid, true, [
                 :call,
                 :arity,
                 :procs,
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

      # Concept: every observed supervisor report comes from its joined producer.
      # Technical depth: the primary filter runs in the local logging caller.
      # Its send precedes that supervisor's original DOWN, so report custody uses
      # the existing actor fence rather than an added Logger wait allowance.
      for report <- evidence, report["event"] == "supervisor_report" do
        assert report["logger_producer"] == report["supervisor"]

        assert Enum.any?(evidence, fn event ->
                 event["event"] == "original_down" and
                   event["pid"] == report["logger_producer"]
               end)
      end

      if mode == :explicit_stop do
        for run <- runs do
          assert Enum.any?(
                   evidence,
                   &(&1["event"] == "explicit_stop_returned" and &1["pid"] == identity(run.owner))
                 ),
                 "explicit runtime stop did not return successfully: " <>
                   inspect(evidence, limit: :infinity)
        end
      end

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

  # Concept: failed explicit stop retains its causal trace before failing the test.
  # Technical depth: successful stop receipts release their exact owner within
  # the original join cutoff; the unchanged success assertion follows retention.
  defp join_originals(monitors, collector, cutoff, evidence) do
    receive do
      {:explicit_stop_returned, owner} ->
        assert Enum.any?(monitors, fn {_reference, {pid, role}} ->
                 pid == owner and role == "owner"
               end)

        send(owner, :stop)

        record = %{
          "event" => "explicit_stop_returned",
          "pid" => identity(owner),
          "observed_at_ns" => System.monotonic_time(:nanosecond)
        }

        join_originals(monitors, collector, cutoff, [record | evidence])

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

  defp collect(_observer, _records, count, _fence, _targets, _actors, _resources)
       when count >= 8_192,
       do: exit(:private_task_trace_limit)

  defp collect(observer, records, count, fence, targets, actors, resources) do
    receive do
      {:trace_ts, pid, :call, {DynamicSupervisor, :monitor_child, 1}, child, at}
      when is_map_key(actors, pid) and is_map_key(actors, child) ->
        record = %{
          "event" => "monitor_child",
          "supervisor" => identity(pid),
          "pid" => identity(child),
          "at_ns" => trace_time(at)
        }

        collect(
          observer,
          [record | records],
          count + 1,
          fence,
          Map.put(targets, pid, child),
          actors,
          resources
        )

      {:trace_ts, pid, :call, {:erlang, :monitor, 2}, child, at}
      when is_map_key(actors, pid) and is_map_key(actors, child) ->
        record = %{
          "event" => "late_monitor_call",
          "supervisor" => identity(pid),
          "pid" => identity(child),
          "at_ns" => trace_time(at)
        }

        collect(
          observer,
          [record | records],
          count + 1,
          fence,
          Map.put(targets, pid, child),
          actors,
          resources
        )

      {:trace_ts, pid, :return_from, {:erlang, :monitor, 2}, reference, at}
      when is_reference(reference) and is_map_key(actors, pid) ->
        record = %{
          "event" => "late_monitor_installed",
          "supervisor" => identity(pid),
          "pid" => identity(Map.fetch!(targets, pid)),
          "monitor" => identity(reference),
          "at_ns" => trace_time(at)
        }

        collect(observer, [record | records], count + 1, fence, targets, actors, resources)

      {:trace_ts, pid, :return_from, {DynamicSupervisor, :monitor_child, 1}, result, at}
      when is_map_key(actors, pid) ->
        record = %{
          "event" => "monitor_child_return",
          "supervisor" => identity(pid),
          "pid" => identity(Map.fetch!(targets, pid)),
          "result" => safe_monitor_result(result),
          "at_ns" => trace_time(at)
        }

        collect(observer, [record | records], count + 1, fence, targets, actors, resources)

      {:trace_ts, pid, :receive, {:EXIT, child, reason}, at}
      when is_map_key(actors, pid) and is_map_key(actors, child) ->
        record = %{
          "event" => "supervisor_exit_received",
          "supervisor" => identity(pid),
          "pid" => identity(child),
          "reason" => safe_reason(reason),
          "at_ns" => trace_time(at)
        }

        collect(observer, [record | records], count + 1, fence, targets, actors, resources)

      {:trace_ts, pid, :receive, {:DOWN, monitor, :process, child, reason}, at}
      when is_map_key(actors, pid) and is_map_key(actors, child) ->
        record = %{
          "event" => "supervisor_down_received",
          "supervisor" => identity(pid),
          "pid" => identity(child),
          "monitor" => identity(monitor),
          "reason" => safe_reason(reason),
          "at_ns" => trace_time(at)
        }

        collect(observer, [record | records], count + 1, fence, targets, actors, resources)

      {:trace_ts, pid, :call, {:erlang, :unlink, 1}, child, at}
      when is_map_key(actors, pid) and is_map_key(actors, child) ->
        record = %{
          "event" => "unlink_call",
          "actor" => identity(pid),
          "pid" => identity(child),
          "at_ns" => trace_time(at)
        }

        collect(
          observer,
          [record | records],
          count + 1,
          fence,
          Map.put(targets, {:unlink, pid}, child),
          actors,
          resources
        )

      {:trace_ts, pid, :return_from, {:erlang, :unlink, 1}, true, at}
      when is_map_key(actors, pid) ->
        record = %{
          "event" => "unlink_return",
          "actor" => identity(pid),
          "pid" => identity(Map.fetch!(targets, {:unlink, pid})),
          "at_ns" => trace_time(at)
        }

        collect(observer, [record | records], count + 1, fence, targets, actors, resources)

      {:trace_ts, pid, :call, {:erlang, :exit, 2}, {child, reason}, at}
      when is_map_key(actors, pid) and is_map_key(actors, child) and reason in [:kill, :shutdown] ->
        record = %{
          "event" => "exit_signal_sent",
          "sender" => identity(pid),
          "pid" => identity(child),
          "reason" => Atom.to_string(reason),
          "at_ns" => trace_time(at)
        }

        collect(observer, [record | records], count + 1, fence, targets, actors, resources)

      {:trace_ts, pid, :exit, reason, at} when is_map_key(actors, pid) ->
        record = %{
          "event" => "actor_exit",
          "pid" => identity(pid),
          "role" => Map.fetch!(actors, pid),
          "reason" => safe_reason(reason),
          "at_ns" => trace_time(at)
        }

        collect(observer, [record | records], count + 1, fence, targets, actors, resources)

      {:trace_ts, resource, :receive,
       {:loopex_provider_resource_stop, reference, nonce, requester, _, _}, at}
      when is_map_key(resources, resource) and is_reference(nonce) ->
        {^reference, ^requester} = Map.fetch!(resources, resource)

        record = %{
          "event" => "resource_stop_received",
          "pid" => identity(resource),
          "requester" => identity(requester),
          "stop_reference" => identity(reference),
          "stop_nonce" => identity(nonce),
          "at_ns" => trace_time(at)
        }

        collect(observer, [record | records], count + 1, fence, targets, actors, resources)

      {:trace_ts, requester, :receive, {:loopex_provider_resource_stopped, nonce, resource}, at}
      when is_map_key(resources, resource) and is_reference(nonce) ->
        {_reference, ^requester} = Map.fetch!(resources, resource)

        record = %{
          "event" => "resource_stop_ack_received",
          "pid" => identity(resource),
          "requester" => identity(requester),
          "stop_nonce" => identity(nonce),
          "at_ns" => trace_time(at)
        }

        collect(observer, [record | records], count + 1, fence, targets, actors, resources)

      # Concept: process lifecycle metadata cannot discard the shutdown evidence.
      # Technical depth: OTP spawn traces include an entry-point tuple; discard
      # it and names immediately. Retain only pre-captured identities, never
      # extend the actor set, and count every accepted shape toward the same cap.
      {:trace_ts, pid, event, other, {_, _, _}, at}
      when is_map_key(actors, pid) and is_pid(other) and event in [:spawn, :spawned] ->
        records =
          if is_map_key(actors, other) do
            [
              %{
                "event" => "process_" <> Atom.to_string(event),
                "pid" => identity(pid),
                "other" => identity(other),
                "at_ns" => trace_time(at)
              }
              | records
            ]
          else
            records
          end

        collect(observer, records, count + 1, fence, targets, actors, resources)

      {:trace_ts, pid, event, name, at}
      when is_map_key(actors, pid) and is_atom(name) and event in [:register, :unregister] ->
        record = %{
          "event" => "process_" <> Atom.to_string(event),
          "pid" => identity(pid),
          "at_ns" => trace_time(at)
        }

        collect(observer, [record | records], count + 1, fence, targets, actors, resources)

      # Concept: original actor links retain their actual lifecycle order.
      # Technical depth: every accepted shape still counts toward the same cap.
      # Retain fixed metadata only for original actor pairs; these rows do not
      # prove delivery of a later EXIT or extend the captured actor inventory.
      {:trace_ts, pid, event, other, at}
      when is_map_key(actors, pid) and is_pid(other) and
             event in [:link, :unlink, :getting_linked, :getting_unlinked] ->
        records =
          if is_map_key(actors, other) do
            [
              %{
                "event" => "process_" <> Atom.to_string(event),
                "pid" => identity(pid),
                "other" => identity(other),
                "at_ns" => trace_time(at)
              }
              | records
            ]
          else
            records
          end

        collect(observer, records, count + 1, fence, targets, actors, resources)

      {:finish, ^observer, session} when fence == nil ->
        collect(
          observer,
          records,
          count,
          :trace.delivered(session, :all),
          targets,
          actors,
          resources
        )

      {:trace_delivered, :all, reference} when reference == fence ->
        send(observer, {:causal_trace, self(), Enum.reverse(records)})

      _unexpected ->
        exit(:private_task_trace_shape)
    end
  end

  defp trace_time(at), do: System.convert_time_unit(at, :native, :nanosecond)
  defp safe_monitor_result(:ok), do: %{"kind" => "ok"}

  defp safe_monitor_result({:error, reason}),
    do: %{"kind" => "error", "reason" => safe_reason(reason)}

  defp safe_monitor_result(_), do: %{"kind" => "unrecognized"}

  defp drain_reports(runs, records) do
    watched =
      Map.new(
        Enum.flat_map(runs, &[{&1.workers, true}, {&1.owner_groups, true}, {&1.sessions, true}])
      )

    actors = Enum.reduce(runs, %{}, &Map.merge(&2, &1.roles))

    receive do
      {:managed_child_stopping, child, :resource_stop, nonce, requester}
      when is_map_key(actors, child) and is_map_key(actors, requester) and is_reference(nonce) ->
        drain_reports(runs, [
          %{
            "event" => "managed_child_stopping",
            "pid" => identity(child),
            "route" => "resource_stop",
            "requester" => identity(requester),
            "stop_nonce" => identity(nonce)
          }
          | records
        ])

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

      {:supervisor_report, producer, supervisor, child, context, reason, shutdown}
      when is_map_key(watched, supervisor) ->
        drain_reports(runs, [
          %{
            "event" => "supervisor_report",
            "logger_producer" => identity(producer),
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

  defp safe_reason({:shutdown, :noproc}), do: "shutdown:noproc"
  defp safe_reason({:owner_workers_stopped, :killed}), do: "owner_workers_stopped:killed"
  defp safe_reason(reason) when reason in @safe_reasons, do: Atom.to_string(reason)
  defp safe_reason(_), do: "other"
  defp safe_shutdown(:brutal_kill), do: "brutal_kill"
  defp safe_shutdown(value) when is_integer(value) and value >= 0, do: value
  defp safe_shutdown(_), do: "other"
  defp identity(value) when is_pid(value), do: List.to_string(:erlang.pid_to_list(value))
  defp identity(value) when is_reference(value), do: List.to_string(:erlang.ref_to_list(value))
end
