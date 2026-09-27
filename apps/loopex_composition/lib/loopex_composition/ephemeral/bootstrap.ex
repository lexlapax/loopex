defmodule LoopexComposition.Ephemeral.Bootstrap do
  @moduledoc """
  ## Concept

  Starts shared composition infrastructure without giving a disposable worker
  any session input or authority. Success requires the worker's normal exit.

  ## Technical depth

  One unlinked monitored worker receives only its requester and fresh reference.
  The requester admits an exact successful result stamped within its absolute
  five-second decision deadline, then proves normal DOWN within the additional
  one-second reap budget. Failure sends kill and awaits the actual worker's DOWN
  only until the reap deadline. Missing proof remains failure. All receive waits
  are sliced at one second; neither deadline is extended. A late OTP start can
  only finish shared application initialization.
  """

  @failure {:error, {:composition, :composition_application_start_failed}}

  @doc false
  def start, do: start(&ensure_application/2)

  @doc false
  def start(worker_function) when is_function(worker_function, 2) do
    requester = self()
    ref = make_ref()
    decision = System.monotonic_time() + native(5_000)
    reap = decision + native(1_000)
    {worker, monitor} = spawn_monitor(fn -> worker_function.(requester, ref) end)
    await(worker, monitor, ref, decision, reap, false, false)
  end

  defp ensure_application(requester, ref) do
    result =
      try do
        Application.ensure_all_started(:loopex_composition)
      rescue
        _ -> :failed
      catch
        _, _ -> :failed
      end

    send(requester, {self(), ref, result, System.monotonic_time()})
  end

  defp await(_worker, _monitor, _ref, _decision, _reap, true, true), do: :ok

  defp await(worker, monitor, ref, decision, reap, success, down) do
    deadline = if success, do: reap, else: decision

    receive do
      {^worker, ^ref, {:ok, applications}, completed}
      when is_list(applications) and is_integer(completed) ->
        if Enum.all?(applications, &is_atom/1) and completed <= decision and
             completed <= System.monotonic_time() do
          await(worker, monitor, ref, decision, reap, true, down)
        else
          fail(worker, monitor, reap, down)
        end

      {^worker, ^ref, _result, _completed} ->
        fail(worker, monitor, reap, down)

      {:DOWN, ^monitor, :process, ^worker, :normal} ->
        await(worker, monitor, ref, decision, reap, success, true)

      {:DOWN, ^monitor, :process, ^worker, _reason} ->
        @failure
    after
      slice(deadline) ->
        if System.monotonic_time() < deadline do
          await(worker, monitor, ref, decision, reap, success, down)
        else
          boundary(worker, monitor, ref, decision, reap, success, down)
        end
    end
  end

  # Concept: a queued result completed before expiry remains eligible.
  # Technical depth: this final receive never waits or starts another budget.
  defp boundary(worker, monitor, ref, decision, reap, false, down) do
    receive do
      {^worker, ^ref, {:ok, applications}, completed}
      when is_list(applications) and is_integer(completed) ->
        if Enum.all?(applications, &is_atom/1) and completed <= decision and
             completed <= System.monotonic_time() do
          await(worker, monitor, ref, decision, reap, true, down)
        else
          fail(worker, monitor, reap, down)
        end
    after
      0 -> fail(worker, monitor, reap, down)
    end
  end

  defp boundary(worker, monitor, _ref, _decision, reap, true, down),
    do: fail(worker, monitor, reap, down)

  defp fail(_worker, _monitor, _reap, true), do: @failure

  defp fail(worker, monitor, reap, false) do
    Process.exit(worker, :kill)
    await_reap(worker, monitor, reap)
    @failure
  end

  defp await_reap(worker, monitor, reap) do
    receive do
      {:DOWN, ^monitor, :process, ^worker, _reason} -> :ok
    after
      slice(reap) ->
        if System.monotonic_time() < reap do
          await_reap(worker, monitor, reap)
        else
          Process.demonitor(monitor, [:flush])
          :ok
        end
    end
  end

  defp native(ms), do: System.convert_time_unit(ms, :millisecond, :native)

  defp slice(deadline) do
    remaining = max(deadline - System.monotonic_time(), 0)
    min(div(remaining + native(1) - 1, native(1)), 1_000)
  end
end
