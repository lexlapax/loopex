defmodule Loopex.LLM.ReqLLM.ProviderPhaseDiagnostic do
  @moduledoc false
  alias Loopex.LLM.ReqLLM.ProviderBridge

  @labels ~w(dispatch_started terminal_ok terminal_unknown terminal_not_dispatched cleanup_ok cleanup_unknown cleanup_other cleanup_proved fail port_lost deliver_ok deliver_unknown deliver_not_dispatched)a
  @functions [
    loop: 1,
    begin_cleanup: 2,
    cleanup_proved: 1,
    fail: 1,
    port_lost: 1,
    deliver: 2,
    observe_failure: 2
  ]
  # Only literal finite messages cross the trace boundary. Repeated or unknown
  # evidence discards the pair; it cannot overwrite an earlier classification.
  @failure_stages ~w(handoff stream metadata completion assembly calls)
  @failure_classes ~w(stream_http_auth stream_http_rate_limit stream_http_server stream_http_status stream_transport_timeout stream_transport_tls stream_transport_error stream_http_protocol_error stream_finch_error stream_http_task_failed stream_wait_timeout stream_task_call_timeout stream_decode_error stream_other_error genserver_timeout raised exited thrown caught provider_status stream_failed stream_incomplete assembly_failed returned_error unclassified)
  @failure_pairs for(stage <- @failure_stages, class <- @failure_classes, do: {stage, class}) ++
                   [{"unavailable", "unclassified"}]

  @flags [:call, :arity, :monotonic_timestamp, :set_on_spawn]

  # Concept: diagnostics retain the original caller and preserve its failure.
  # Technical depth: static labels and arity-only traces exclude state and secrets.
  # A successful callback still requires complete diagnostics and confirmed cleanup.
  def capture(fun, module \\ ProviderBridge) do
    handle = start(module)

    outcome =
      try do
        {:ok, fun.()}
      catch
        kind, reason -> {:failed, kind, reason, __STACKTRACE__}
      end

    report = snapshot(handle)
    cleaned = stop(handle)
    report = Map.put(report, :cleanup_confirmed, cleaned)

    case outcome do
      {:failed, kind, reason, stack} ->
        emit(report)
        :erlang.raise(kind, reason, stack)

      {:ok, result} ->
        if report[:available] and not report[:incomplete] and report[:healthy] and cleaned do
          result
        else
          emit(report)
          raise "provider phase diagnostic unavailable or incomplete"
        end
    end
  end

  def specifications do
    message = fn pattern, label -> {pattern, [], [{:message, label}]} end

    failure_specs =
      Enum.map(@failure_pairs, fn {stage, class} ->
        {[stage, class], [], [{:message, {:const, {:failure, stage, class}}}]}
      end)

    [
      {:observe_failure, 2, failure_specs ++ [message.([:_, :_], :failure_invalid)]},
      {:loop, 1,
       [
         message.([%{phase: :running}], :dispatch_started),
         message.([%{phase: :terminal_end, result: {:ok, :_}}], :terminal_ok),
         message.(
           [%{phase: :terminal_end, result: {:error, {:dispatched_or_unknown, :_}}}],
           :terminal_unknown
         ),
         message.(
           [%{phase: :terminal_end, result: {:error, {:not_dispatched, :_}}}],
           :terminal_not_dispatched
         )
       ]},
      {:begin_cleanup, 2,
       [
         message.([%{result: {:ok, :_}}, :_], :cleanup_ok),
         message.([%{result: {:error, {:dispatched_or_unknown, :_}}}, :_], :cleanup_unknown),
         message.([:_, :_], :cleanup_other)
       ]},
      {:cleanup_proved, 1, [message.([:_], :cleanup_proved)]},
      {:fail, 1, [message.([:_], :fail)]},
      {:port_lost, 1, [message.([:_], :port_lost)]},
      {:deliver, 2,
       [
         message.([:_, {:ok, :_}], :deliver_ok),
         message.([:_, {:error, {:dispatched_or_unknown, :_}}], :deliver_unknown),
         message.([:_, {:error, {:not_dispatched, :_}}], :deliver_not_dispatched)
       ]}
    ]
  end

  defp start(module) do
    {:module, ^module} = Code.ensure_loaded(module)

    true =
      Enum.all?(@functions, fn {f, a} ->
        :erlang.trace_info({module, f, a}, :traced) == {:traced, false}
      end)

    {:flags, []} = :erlang.trace_info(self(), :flags)
    owner = self()
    start = System.monotonic_time()

    {tracer, tracer_monitor} =
      spawn_monitor(fn ->
        try do
          collect(owner, Process.monitor(owner), module, start, %{}, %{}, false)
        after
          unless remove_patterns(module), do: exit(:diagnostic_cleanup_failed)
        end
      end)

    try do
      for {f, a, spec} <- specifications(),
          do: 1 = :erlang.trace_pattern({module, f, a}, spec, [:local])

      1 = :erlang.trace(self(), true, @flags ++ [{:tracer, tracer}])
      {module, tracer, tracer_monitor}
    catch
      _, _ ->
        stop({module, tracer, tracer_monitor})
        :unavailable
    end
  rescue
    _ -> :unavailable
  end

  defp collect(
         owner,
         monitor,
         module,
         start,
         first,
         counts,
         incomplete,
         failure \\ nil,
         pending \\ nil
       ) do
    receive do
      {:trace_ts, _pid, :call, {^module, :observe_failure, 2}, {:failure, stage, class},
       timestamp}
      when {stage, class} in @failure_pairs and is_integer(timestamp) ->
        next_failure = if failure == nil, do: {stage, class}, else: :invalid

        collect(
          owner,
          monitor,
          module,
          start,
          first,
          counts,
          incomplete or next_failure == :invalid,
          next_failure,
          pending
        )

      {:trace_ts, _pid, :call, {^module, :observe_failure, 2}, :failure_invalid, timestamp}
      when is_integer(timestamp) ->
        collect(owner, monitor, module, start, first, counts, true, :invalid, pending)

      {:trace_ts, _pid, :call, {^module, function, arity}, label, timestamp}
      when {function, arity} in @functions and label in @labels and is_integer(timestamp) ->
        n = Map.get(counts, label, 0) + 1

        first =
          Map.put_new(
            first,
            label,
            System.convert_time_unit(timestamp - start, :native, :microsecond)
          )

        collect(
          owner,
          monitor,
          module,
          start,
          first,
          Map.put(counts, label, min(n, 10_000)),
          incomplete or n >= 10_000,
          failure,
          pending
        )

      {:snapshot, ^owner, reference} ->
        barrier = :erlang.trace_delivered(:all)

        collect(
          owner,
          monitor,
          module,
          start,
          first,
          counts,
          incomplete,
          failure,
          {reference, barrier}
        )

      {:trace_delivered, :all, barrier} when is_tuple(pending) ->
        {reference, ^barrier} = pending

        owner_flags =
          case :erlang.trace_info(owner, :flags) do
            {:flags, flags} -> flags
            :undefined -> []
          end

        incomplete = incomplete or owner_flags == []

        healthy =
          map_size(first) > 0 and Enum.all?(@flags, &(&1 in owner_flags)) and
            :erlang.trace_info(owner, :tracer) == {:tracer, self()} and
            Enum.all?(@functions, fn {f, a} ->
              :erlang.trace_info({module, f, a}, :traced) == {:traced, :local}
            end)

        accepted_failure =
          case failure do
            {stage, class} -> %{stage: stage, class: class}
            _ -> nil
          end

        send(
          owner,
          {reference,
           %{
             phases: first,
             counts: counts,
             incomplete: incomplete,
             healthy: healthy,
             failure: accepted_failure
           }}
        )

        collect(owner, monitor, module, start, first, counts, incomplete, failure)

      {:stop, ^owner, reference} ->
        send(owner, {:stopped, reference})
        :ok

      {:DOWN, ^monitor, :process, ^owner, _} ->
        :ok
    end
  end

  defp snapshot(:unavailable), do: %{available: false}

  defp snapshot({_module, tracer, monitor}) do
    reference = make_ref()
    send(tracer, {:snapshot, self(), reference})

    receive do
      {^reference, report} -> Map.put(report, :available, true)
      {:DOWN, ^monitor, :process, ^tracer, _} -> %{available: false}
    after
      1_000 -> %{available: false}
    end
  catch
    _, _ -> %{available: false}
  end

  defp emit(report) do
    IO.puts("provider phase diagnostic " <> Jason.encode!(report))
  catch
    _, _ -> :ok
  end

  defp remove_patterns(module) do
    for {f, a} <- @functions, do: 1 = :erlang.trace_pattern({module, f, a}, false, [:local])

    Enum.all?(@functions, fn {f, a} ->
      :erlang.trace_info({module, f, a}, :traced) == {:traced, false}
    end)
  catch
    _, _ -> false
  end

  defp stop(:unavailable), do: false

  defp stop({module, tracer, monitor}) do
    :erlang.trace(self(), false, @flags)
    patterns_removed = remove_patterns(module)
    reference = make_ref()
    send(tracer, {:stop, self(), reference})

    stopped =
      receive do
        {:stopped, ^reference} ->
          receive do
            {:DOWN, ^monitor, :process, ^tracer, :normal} -> true
          after
            1_000 -> false
          end

        {:DOWN, ^monitor, :process, ^tracer, _} ->
          false
      after
        1_000 -> false
      end

    unless stopped, do: Process.exit(tracer, :kill)
    Process.demonitor(monitor, [:flush])
    patterns_removed and stopped
  catch
    _, _ -> false
  end
end
