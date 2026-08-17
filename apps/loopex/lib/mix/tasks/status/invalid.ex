defmodule Loopex.Checks.Invalid do
  @moduledoc """
  ## Concept

  The single failure signal every repository status check raises. A check that
  cannot establish a property reports that property as unmet rather than
  returning a partial answer, so unavailable evidence never reads as success.

  ## Technical depth

  Carries only a message, because callers report the first failure and stop:
  a structural defect usually cascades, and a list of derived complaints buries
  the one that matters. `Loopex.Checks.Status.validate/2` catches this exception
  at the boundary and returns it as a one-element error list.
  """

  defexception [:message]
end
