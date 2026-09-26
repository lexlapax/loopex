defmodule Loopex.LLM.ReqLLM.CredentialCustody.Ref do
  @moduledoc """
  ## Concept

  A private route from one invocation sender to a host-owned credential
  custodian.

  ## Technical depth

  The exact local process and random incarnation prevent a stale or malformed
  route from selecting a different producer. The reference is transient
  composition data and never enters durable, public, or diagnostic planes.
  """

  @enforce_keys [:pid, :incarnation]
  defstruct [:pid, :incarnation]

  @opaque t :: %__MODULE__{pid: pid(), incarnation: <<_::128>>}
end
