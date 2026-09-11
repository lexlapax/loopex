defmodule LoopexComposition.RuntimeOwner do
  @moduledoc false

  @shutdown_wait_ms 1_000

  @doc false
  def start(configuration, compose, seams) do
    caller = self()
    tag = make_ref()

    {owner, monitor} =
      spawn_monitor(fn -> own_started(caller, tag, configuration, compose, seams) end)

    receive do
      {^tag, result} ->
        Process.demonitor(monitor, [:flush])
        result

      {:DOWN, ^monitor, :process, ^owner, reason} ->
        {:error, {:composition_owner_failed, reason}}
    end
  end

  @doc false
  def with_runtime(configuration, function, compose, seams) do
    case open(configuration, compose, seams) do
      {:ok, handle} -> run_callback(handle, function)
      {:error, _reason} = refusal -> refusal
    end
  end

  defp own_started(caller, tag, configuration, compose, seams) do
    initialize(seams)

    case guarded_compose(configuration, compose) do
      {:ok, _runtime} = started ->
        send(caller, {tag, started})
        receive do: ({:EXIT, _pid, _reason} -> cleanup(seams))

      {:error, _reason} = refusal ->
        _ = cleanup(seams)
        send(caller, {tag, refusal})
    end
  end

  defp open(configuration, compose, seams) do
    caller = self()
    tag = make_ref()
    token = make_ref()

    {owner, monitor} =
      spawn_monitor(fn -> own_bracketed(caller, tag, token, configuration, compose, seams) end)

    receive do
      {^tag, {:ok, runtime}} ->
        {:ok, %{owner: owner, monitor: monitor, token: token, runtime: runtime, tag: tag}}

      {^tag, {:error, _reason} = refusal} ->
        await_owner(owner, monitor)
        refusal

      {:DOWN, ^monitor, :process, ^owner, reason} ->
        {:error, {:composition_owner_failed, reason}}
    end
  end

  defp own_bracketed(caller, tag, token, configuration, compose, seams) do
    initialize(seams)
    caller_monitor = Process.monitor(caller)

    case guarded_compose(configuration, compose) do
      {:ok, runtime} ->
        send(caller, {tag, {:ok, runtime}})
        await_stop(caller, caller_monitor, tag, token, runtime, seams)

      {:error, _reason} = refusal ->
        _ = cleanup(seams)
        send(caller, {tag, refusal})
    end
  end

  defp await_stop(caller, caller_monitor, tag, token, runtime, seams) do
    runtime_supervisor = runtime.supervisor

    receive do
      {^token, :stop, ^caller} ->
        result = cleanup(seams)
        send(caller, {tag, :stopped, result})

      {:DOWN, ^caller_monitor, :process, ^caller, _reason} ->
        _ = cleanup(seams)

      {:EXIT, ^runtime_supervisor, reason} ->
        result = cleanup(seams)
        send(caller, {tag, :runtime_stopped, reason, result})
    end
  end

  defp run_callback(handle, function) do
    outcome =
      try do
        {:returned, function.(handle.runtime)}
      rescue
        exception -> {:raised, :error, exception, __STACKTRACE__}
      catch
        kind, reason -> {:raised, kind, reason, __STACKTRACE__}
      end

    cleanup = stop(handle)

    case {outcome, cleanup} do
      {{:returned, result}, :ok} -> result
      {{:returned, _result}, {:error, _reason} = refusal} -> refusal
      {{:raised, kind, reason, stacktrace}, _cleanup} -> :erlang.raise(kind, reason, stacktrace)
    end
  end

  defp stop(handle) do
    send(handle.owner, {handle.token, :stop, self()})

    receive do
      {tag, :stopped, :ok} when tag == handle.tag ->
        await_owner(handle.owner, handle.monitor)
        :ok

      {tag, :stopped, {:error, details}} when tag == handle.tag ->
        await_owner(handle.owner, handle.monitor)
        {:error, {:composition_cleanup_unconfirmed, details}}

      {tag, :runtime_stopped, reason, cleanup} when tag == handle.tag ->
        await_owner(handle.owner, handle.monitor)
        {:error, {:composition_runtime_stopped, reason, cleanup}}

      {:DOWN, monitor, :process, owner, reason}
      when monitor == handle.monitor and owner == handle.owner ->
        {:error, {:composition_owner_failed, reason}}
    end
  end

  defp initialize(seams) do
    Process.flag(:trap_exit, true)
    Process.put(seams.edge_key, seams.edge)
    Process.put(seams.effect_key, seams.effect)
    Process.put(seams.owned_key, [])
  end

  defp guarded_compose(configuration, compose) do
    try do
      compose.(configuration)
    rescue
      exception -> {:error, {:composition_start_raised, exception}}
    catch
      kind, reason -> {:error, {:composition_start_caught, kind, reason}}
    end
  end

  defp cleanup(seams) do
    seams.owned_key
    |> Process.get([])
    |> Enum.reduce([], fn owned, failures ->
      case stop_owned(owned, seams.effect) do
        :ok -> failures
        {:error, detail} -> [detail | failures]
      end
    end)
    |> case do
      [] -> :ok
      failures -> {:error, Enum.reverse(failures)}
    end
  end

  defp stop_owned({Loopex, runtime}, effect) do
    case guarded_effect(effect, Loopex, :stop, [runtime]) do
      :ok -> :ok
      other -> {:error, {:runtime_stop_unconfirmed, other}}
    end
  end

  defp stop_owned({module, pid}, effect) do
    if Process.alive?(pid) do
      monitor = Process.monitor(pid)
      shutdown = guarded_effect(effect, Process, :exit, [pid, :shutdown])

      receive do
        {:DOWN, ^monitor, :process, ^pid, reason} when reason in [:normal, :shutdown] ->
          :ok

        {:DOWN, ^monitor, :process, ^pid, reason} ->
          {:error, {module, :abnormal_stop, reason}}
      after
        @shutdown_wait_ms ->
          forced = guarded_effect(effect, Process, :exit, [pid, :kill])
          forced_stop(module, pid, monitor, shutdown, forced)
      end
    else
      {:error, {module, :already_stopped}}
    end
  end

  defp forced_stop(module, pid, monitor, shutdown, forced) do
    receive do
      {:DOWN, ^monitor, :process, ^pid, reason} ->
        {:error, {module, :forced_stop, shutdown, forced, reason}}
    after
      @shutdown_wait_ms ->
        Process.demonitor(monitor, [:flush])
        {:error, {module, :stop_unconfirmed, shutdown, forced}}
    end
  end

  defp guarded_effect(effect, module, function, arguments) do
    try do
      effect.(module, function, arguments)
    rescue
      exception -> {:raised, exception}
    catch
      kind, reason -> {:caught, kind, reason}
    end
  end

  defp await_owner(owner, monitor) do
    receive do
      {:DOWN, ^monitor, :process, ^owner, _reason} -> :ok
    end
  end
end
