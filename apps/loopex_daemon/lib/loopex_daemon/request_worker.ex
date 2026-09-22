defmodule LoopexDaemon.RequestWorker do
  @moduledoc """
  ## Concept

  A request worker carries one admitted request's blocking work away from the
  connection that owns the socket, so a slow core answer never stalls another
  request's output. It dies with its connection and never outlives it.

  ## Technical depth

  The connection spawns and monitors the worker. The worker monitors the
  connection, runs its one bounded preparatory function, reports the result
  under its fresh 128-bit incarnation, and then waits for the relay's exact
  `go` for its origin before exiting normally. A relay permit counts the
  worker's exact `DOWN` as its completion, so a normal exit after `go` is part
  of the permit protocol rather than an absence of work. Connection loss ends
  the worker at once. Results and failures carry no request content in logs.
  """

  require Logger

  @incarnation_bytes 16

  @doc false
  @spec start(term(), (-> term())) :: {pid(), reference(), binary()}
  def start(origin, fun) when is_function(fun, 0) do
    connection = self()
    incarnation = :crypto.strong_rand_bytes(@incarnation_bytes)

    {pid, monitor} =
      spawn_monitor(fn -> run(connection, origin, incarnation, fun) end)

    {pid, monitor, incarnation}
  end

  defp run(connection, origin, incarnation, fun) do
    connection_monitor = Process.monitor(connection)
    result = fun.()
    send(connection, {:request_worker_result, origin, incarnation, result})
    await_go(connection, connection_monitor, origin, incarnation)
  end

  defp await_go(connection, connection_monitor, origin, incarnation) do
    receive do
      {:relay_go, ^origin, ^incarnation} ->
        Logger.debug("loopex daemon request worker released")
        :ok

      {:DOWN, ^connection_monitor, :process, ^connection, _reason} ->
        :ok
    end
  end
end
