defmodule Loopex do
  @moduledoc """
  ## Concept

  The runtime application. In M0 it carries the milestone's feasibility
  experiments and the repository's own validation entrypoints, not a public API:
  the plan's scope makes outcomes 4 through 6 disposable code that answers
  whether the intended OTP semantics hold.

  ## Technical depth

  Its only dependency is `:loopex_protocol`, enforced by
  `mix loopex.deps_budget`. It reads no per-runtime state from application
  environment, which `mix loopex.core_only` enforces, because a runtime
  reference must be explicit rather than hidden in global state that a second
  runtime in the same VM would collide with.
  """

  @version Mix.Project.config()[:version]

  @doc """
  ## Concept

  The single version both applications carry.

  ## Technical depth

  Read from the umbrella's `VERSION` file at compile time, so it cannot diverge
  from `LoopexProtocol.version/0` without changing one source.
  """
  @spec version() :: String.t()
  def version, do: @version
end
