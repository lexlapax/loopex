defmodule LoopexDaemon.AttachmentPump do
  @moduledoc """
  ## Concept

  One reader per daemon attachment pulls the durable events core has already
  named for that attachment and hands them to the connection one at a time,
  so a slow socket never becomes an unbounded queue and never delays a
  journal transaction.

  ## Technical depth

  Core owns the cursor: each `next_event/1` answer is the next contiguous
  event after the attachment's snapshot, and the pump holds at most one event
  the connection has not yet accepted. An empty answer waits with a bounded
  doubling backoff between 10 and 160 milliseconds; any event resets it. A
  core disconnection reports its cursor and ends the pump; any other failure
  reports a fixed class. The pump monitors its connection and exits when the
  connection does. It logs fixed, identity-free lines only.
  """

  require Logger

  alias Loopex.Runtime

  @min_backoff_ms 10
  @max_backoff_ms 160

  @doc false
  @spec start(Loopex.Attachment.t()) :: {pid(), reference()}
  def start(attachment) do
    connection = self()
    spawn_monitor(fn -> run(connection, attachment) end)
  end

  @doc false
  @spec continue(pid()) :: :ok
  def continue(pump) do
    send(pump, {:pump_continue, self()})
    :ok
  end

  defp run(connection, attachment) do
    monitor = Process.monitor(connection)
    Logger.debug("loopex daemon attachment pump start")
    loop(connection, monitor, attachment, @min_backoff_ms)
  end

  defp loop(connection, monitor, attachment, backoff) do
    case Runtime.next_event(attachment) do
      {:ok, event} ->
        send(connection, {:attachment_event, self(), event})

        receive do
          {:pump_continue, ^connection} ->
            loop(connection, monitor, attachment, @min_backoff_ms)

          {:DOWN, ^monitor, :process, ^connection, _reason} ->
            :ok
        end

      {:error, :empty} ->
        receive do
          {:DOWN, ^monitor, :process, ^connection, _reason} -> :ok
        after
          backoff ->
            loop(connection, monitor, attachment, min(backoff * 2, @max_backoff_ms))
        end

      {:disconnected, cursor} ->
        Logger.debug("loopex daemon attachment pump disconnected")
        send(connection, {:attachment_disconnected, self(), cursor})

      {:error, _reason} ->
        Logger.debug("loopex daemon attachment pump failed")
        send(connection, {:attachment_failed, self()})
    end
  end
end
