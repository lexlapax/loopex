defmodule LoopexDaemon do
  @moduledoc """
  ## Concept

  The local durable service owns one runtime generation and its client socket
  for one state root. It keeps session work alive independently of any client
  process while preserving the same core session contract as embedded and
  foreground hosts.

  ## Technical depth

  Lifecycle, transport, residency and collaboration state live in this
  application. Durable session truth remains in `loopex`, concrete Store,
  Model and Executor wiring remains in `loopex_composition`, and wire schemas
  remain in `loopex_protocol`.
  """

  @doc """
  ## Concept

  Returns the daemon application's version.

  ## Technical depth

  Every umbrella application reads the root `VERSION` file through its Mix
  project, so this value participates in the repository's version-train check.
  """
  @spec version() :: String.t()
  def version, do: Application.spec(:loopex_daemon, :vsn) |> to_string()
end
