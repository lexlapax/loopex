defmodule Loopex.Trace.Capability.Handle do
  @moduledoc """
  ## Concept

  An opaque host-owned route to one runtime's trace-exclusion authority.

  ## Technical depth

  The handle contains only a live local process and a random incarnation. It
  carries no runtime reference, trace-session handle, credential, or policy.
  Its exact closed shape is validated at every use so extra fields cannot turn
  it into an ambient data channel.
  """

  @enforce_keys [:pid, :incarnation]
  defstruct [:pid, :incarnation]

  @opaque t :: %__MODULE__{pid: pid(), incarnation: <<_::128>>}
end
