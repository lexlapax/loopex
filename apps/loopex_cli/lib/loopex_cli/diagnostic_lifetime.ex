defmodule LoopexCli.DiagnosticLifetime do
  @moduledoc false

  # Concept: ask and chat share one diagnostic delivery lifetime proof.
  # Technical depth: the creating caller owns admission and the certificate;
  # every captured writer, supervisor and consumer must join under one cutoff.
  # Composition cleanup remains a separate proof in each command host.
  alias LoopexComposition.DiagnosticConsumer

  def start(device, grace) do
    previous = Process.flag(:trap_exit, true)

    try do
      case DiagnosticConsumer.start_link(device, grace) do
        {:ok, consumer} = started ->
          Process.unlink(consumer)
          started

        refusal ->
          refusal
      end
    after
      Process.flag(:trap_exit, previous)
    end
  end

  defp monitor_diagnostics(pids, monitors) do
    Enum.reduce(pids, monitors, fn pid, monitors ->
      if Map.has_key?(monitors, pid),
        do: monitors,
        else: Map.put(monitors, pid, Process.monitor(pid))
    end)
  end

  def begin_close(consumer, grace, monitors) do
    deadline = System.monotonic_time(:millisecond) + grace
    reference = make_ref()

    case DiagnosticConsumer.begin_close(consumer, reference, deadline) do
      {:ok, owned} -> {reference, deadline, monitor_diagnostics(owned, monitors)}
      _ -> {reference, deadline, monitors}
    end
  end

  def join(consumer, {reference, deadline, monitors}) do
    joined = await_diagnostics(consumer, reference, deadline, monitors, false)
    Enum.each(monitors, fn {_pid, monitor} -> Process.demonitor(monitor, [:flush]) end)
    joined
  end

  defp await_diagnostics(_consumer, _reference, deadline, monitors, true)
       when map_size(monitors) == 0,
       do: System.monotonic_time(:millisecond) <= deadline

  defp await_diagnostics(consumer, reference, deadline, monitors, certified) do
    receive do
      {:diagnostic_consumer_closed, ^consumer, ^reference, {:ok, _counts}} ->
        await_diagnostics(consumer, reference, deadline, monitors, true)

      {:diagnostic_consumer_closed, ^consumer, ^reference, _unproved} ->
        false

      # Concept: callers retain messages from their own independent monitors.
      # Technical depth: match both captured PID and reference in the receive
      # guard, leaving another monitor's DOWN for the same PID in the mailbox.
      {:DOWN, monitor, :process, pid, _reason}
      when is_map_key(monitors, pid) and :erlang.map_get(pid, monitors) == monitor ->
        await_diagnostics(consumer, reference, deadline, Map.delete(monitors, pid), certified)
    after
      max(deadline - System.monotonic_time(:millisecond), 0) -> false
    end
  end
end
