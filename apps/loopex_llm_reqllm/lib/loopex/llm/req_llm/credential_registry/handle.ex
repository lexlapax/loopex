defmodule Loopex.LLM.ReqLLM.CredentialRegistry.Handle do
  @moduledoc """
  ## Concept

  A transient route to one host-owned credential routing registry.

  ## Technical depth

  The exact local pid and sixteen-byte incarnation are the whole handle. It
  contains no token rows, custody reference, credential, or provider data.
  """

  @enforce_keys [:pid, :incarnation]
  defstruct [:pid, :incarnation]

  @opaque t :: %__MODULE__{pid: pid(), incarnation: <<_::128>>}
end
