defmodule Loopex.ShutdownWitness do
  @moduledoc false

  import ExUnit.Assertions

  @safe_reasons [
    :normal,
    :shutdown,
    :killed,
    :noproc,
    :private_task_fixture_fault,
    :provider_cleanup_unproved
  ]

  def install_logger(filter, observer) do
    {:ok, started} = Application.ensure_all_started(:logger)
    filters = :logger.get_primary_config().filters
    saved = {filter, filters, started}

    try do
      enabled =
        Keyword.update!(filters, :logger_translator, fn {callback, configuration} ->
          {callback, %{configuration | sasl: true}}
        end)

      :ok = :logger.set_primary_config(:filters, enabled)
      :ok = :logger.add_primary_filter(filter, {&__MODULE__.observe_report/2, observer})
      saved
    catch
      kind, reason ->
        stack = __STACKTRACE__
        cleanup_errors([fn -> restore_logger(saved) end])
        :erlang.raise(kind, reason, stack)
    end
  end

  def restore_logger({filter, filters, started}) do
    cleanup([
      fn -> :logger.remove_primary_filter(filter) end,
      fn -> assert :ok == :logger.set_primary_config(:filters, filters) end
      | Enum.map(Enum.reverse(started), fn application ->
          fn -> assert :ok == Application.stop(application) end
        end)
    ])
  end

  # Concept: cleanup attempts every owned action while retaining the first failure.
  # Technical depth: callers keep their original actions and bounds; this helper
  # does not turn later cleanup success into an observation result.
  def cleanup(actions), do: actions |> cleanup_errors() |> raise_cleanup()

  defp cleanup_errors(actions) do
    Enum.flat_map(actions, fn action ->
      try do
        action.()
        []
      catch
        kind, reason -> [{kind, reason, __STACKTRACE__}]
      end
    end)
  end

  defp raise_cleanup([]), do: :ok
  defp raise_cleanup([{kind, reason, stack} | _]), do: :erlang.raise(kind, reason, stack)

  # Concept: this observer preserves the original Logger event and its visibility.
  # Technical depth: the primary filter copies only fixed supervisor metadata;
  # no offender start function, options, request or formatted report is retained.
  def observe_report(%{msg: {:report, %{report: report} = envelope}} = event, observer)
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

    # Concept: only the complete supervisor startup shape is excluded from termination evidence.
    # Technical depth: the original label, two report members and started PID
    # identify startup progress. Missing or unknown contexts on every other
    # supervisor report remain retained and fail the strict classifier.
    started = Keyword.get(report, :started)

    startup_progress =
      envelope[:label] == {:supervisor, :progress} and is_pid(supervisor) and
        Enum.sort(Keyword.keys(report)) == [:started, :supervisor] and
        is_list(started) and Keyword.keyword?(started) and is_pid(Keyword.get(started, :pid))

    if (is_pid(supervisor) or context in [:shutdown_error, :child_terminated]) and
         not startup_progress do
      shutdown = if is_list(offender), do: Keyword.get(offender, :shutdown)

      send(
        observer,
        {:supervisor_report, self(), supervisor, pid, safe_context(context),
         safe_reason(Keyword.get(report, :reason)), safe_shutdown(shutdown)}
      )
    end

    event
  end

  def observe_report(event, _), do: event

  def observe(runs, mode, label, require_quiet, classify) do
    observer = self()
    actors = Enum.reduce(runs, %{}, &Map.merge(&2, &1.roles))
    actors = Map.put(actors, observer, "test_observer")
    managed = Enum.filter(runs, &Map.has_key?(&1, :resource))
    resources = Map.new(managed, &{&1.resource, {&1.stop_reference, &1.guard}})

    {collector, collector_monitor} =
      spawn_monitor(fn -> collect(observer, [], 0, nil, %{}, actors, resources) end)

    cutoff = System.monotonic_time(:millisecond) + 1_000
    cleanup_key = {__MODULE__, :collector_joined, collector}
    Process.put(cleanup_key, false)
    Process.put({cleanup_key, :session}, nil)
    Process.put({__MODULE__, :partial_evidence}, [])

    result =
      try do
        session = :trace.session_create(:loopex_private_task_shutdown, collector, [])
        Process.put({cleanup_key, :session}, session)
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
          Enum.flat_map(managed, fn run ->
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
        evidence = evidence ++ classify.(evidence)
        assert length(evidence) < 8_192
        Process.put({__MODULE__, :partial_evidence}, evidence)
        retain(label, evidence)

        # Concept: every observed supervisor report comes from its joined producer.
        # Technical depth: the primary filter runs in the local logging caller.
        # Its send precedes that supervisor's original DOWN, so report custody uses
        # the existing actor fence rather than an added Logger wait allowance.
        for report <- evidence, report["event"] == "supervisor_report" do
          assert report["logger_producer"] == report["supervisor"]
          assert report["context"] in ["shutdown_error", "child_terminated"]
          assert report["pid"] in Enum.map(Map.keys(actors), &identity/1)
          assert report["reason"] != "other" and report["shutdown"] != "other"

          assert Enum.any?(evidence, fn event ->
                   event["event"] == "original_down" and
                     event["pid"] == report["logger_producer"]
                 end)
        end

        if mode == :explicit_stop do
          for run <- runs do
            assert Enum.any?(
                     evidence,
                     &(&1["event"] == "explicit_stop_returned" and
                         &1["pid"] == identity(run.owner))
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

        {:ok, evidence}
      catch
        kind, reason -> {:error, kind, reason, __STACKTRACE__}
      end

    cleanup_errors =
      cleanup_errors([
        fn ->
          if session = Process.delete({cleanup_key, :session}),
            do: :trace.session_destroy(session)
        end,
        fn ->
          unless Process.delete(cleanup_key) do
            if Process.alive?(collector), do: Process.exit(collector, :kill)

            assert_receive {:DOWN, ^collector_monitor, :process, ^collector, _},
                           max(cutoff - System.monotonic_time(:millisecond), 0)
          end
        end
      ])

    partial = Process.delete({__MODULE__, :partial_evidence})

    case result do
      {:error, kind, reason, stack} ->
        # Concept: an observation failure remains the first failure after cleanup.
        # Technical depth: retention is attempted with bounded metadata only;
        # trace/collector cleanup has already attempted every acquired resource.
        cleanup_errors([fn -> retain(label, partial ++ [%{"event" => "observation_failed"}]) end])
        :erlang.raise(kind, reason, stack)

      {:ok, evidence} ->
        raise_cleanup(cleanup_errors)
        assert System.monotonic_time(:millisecond) <= cutoff
        evidence
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
                 pid == owner and role in ["owner", "stop_caller"]
               end)

        send(owner, :stop)

        record = %{
          "event" => "explicit_stop_returned",
          "pid" => identity(owner),
          "observed_at_ns" => System.monotonic_time(:nanosecond)
        }

        Process.put({__MODULE__, :partial_evidence}, Enum.reverse([record | evidence]))
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

        Process.put({__MODULE__, :partial_evidence}, Enum.reverse([record | evidence]))
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
    actors = Enum.reduce(runs, %{}, &Map.merge(&2, &1.roles))
    watched = Map.new(Map.keys(actors), &{&1, true})
    assert length(records) < 8_192

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
      when is_map_key(watched, supervisor) or is_map_key(watched, producer) ->
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
  defp safe_shutdown(:infinity), do: "infinity"
  defp safe_shutdown(value) when is_integer(value) and value >= 0, do: value
  defp safe_shutdown(_), do: "other"
  def identity(value) when is_pid(value), do: List.to_string(:erlang.pid_to_list(value))
  def identity(value) when is_reference(value), do: List.to_string(:erlang.ref_to_list(value))
  def identity(_value), do: "missing"

  defp safe_context(value) when value in [:shutdown_error, :child_terminated], do: value
  defp safe_context(_value), do: :unrecognized
end
