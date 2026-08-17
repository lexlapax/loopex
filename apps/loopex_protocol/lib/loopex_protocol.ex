defmodule LoopexProtocol do
  @moduledoc """
  ## Concept

  The versioned boundary an extension or host compiles against. It holds
  protocol types and contract declarations and nothing else: no runtime, no
  transport, no store, and no dependency. A contributor can therefore depend on
  this application without acquiring the runtime, which is what lets the two
  compatibility surfaces version independently.

  ## Technical depth

  This application's dependency list is empty and
  `mix loopex.deps_budget` rejects any addition to it, including a reverse edge
  back to the runtime expressed dynamically. `version/0` reports the umbrella's
  single version, read from the root `VERSION` file at compile time so the two
  applications cannot drift apart by editing one of them.

  M0 proves the boundary exists and holds. The protocol's actual message types
  arrive with the milestone that needs them; declaring them now would freeze a
  shape no consumer has exercised.
  """

  @version Mix.Project.config()[:version]

  @doc """
  ## Concept

  The single version both applications carry.

  ## Technical depth

  Resolved at compile time from the umbrella's `VERSION` file, so a drifted
  version is a build-time impossibility rather than a check-time finding.
  `mix loopex.version_train` verifies the resolved values still agree.
  """
  @spec version() :: String.t()
  def version, do: @version
end
