defmodule Loopex.ResumeActivation do
  @moduledoc """
  ## Concept

  The one-use capability a prepared resume hands back. A prepared owner has
  already contested and won ownership of the session and rebuilt its complete
  durable history, but it is not allowed to schedule the recovered work. This
  capability is the only thing that lets it, and the only thing that can give it
  up. Holding it is what makes an operator's next decision — continue, or stop —
  reach a session that has not moved in the meantime.

  ## Technical depth

  ADR 0016 requires the capability to be opaque, non-serializable, and usable
  once by its current holder only. It is a runtime-local pair: an unforgeable
  reference minted by `Loopex.Runtime.Control` when it starts the prepared
  owner, and the process that holds it — the process that asked for the
  preparation, until `transfer/2` moves it to one the owner has acknowledged.
  Neither member can be encoded into a Store record, a public event, a snapshot,
  a progress item, or a diagnostic, and this module puts neither into a refusal
  it returns, so a caller that prints an error cannot print the capability.

  Every operation is answered by the coordinator that holds the matching
  reference, under its ordinary current-owner fence. A superseded coordinator,
  one that has already spent or abandoned the capability, or a caller that is not
  the holder is refused; refusals name what was wrong and carry nothing private.
  """

  alias Loopex.Runtime.SessionCoordinator

  @typedoc """
  ## Concept

  One prepared owner's activation capability.

  ## Technical depth

  The struct is opaque: its members are transient BEAM values reachable only
  inside the runtime that created them, and no member is admissible on a durable
  or public plane.
  """
  @opaque t :: %__MODULE__{coordinator: pid(), owner: map(), capability: reference()}
  defstruct [:coordinator, :owner, :capability]

  @doc false
  @spec new(pid(), map(), reference()) :: t()
  def new(coordinator, owner, capability)
      when is_pid(coordinator) and is_map(owner) and is_reference(capability),
      do: %__MODULE__{coordinator: coordinator, owner: owner, capability: capability}

  @doc """
  ## Concept

  Lets the prepared owner resume the work it recovered, exactly once.

  ## Technical depth

  Answers `{:ok, session_id}` only when the coordinator still holds this exact
  reference unspent, the calling process is its holder, and the coordinator is
  still the runtime's current owner of the session. A second presentation, an
  abandoned capability, a capability an admitted abort has fenced, a caller that
  is not the holder, and a coordinator that is gone or superseded are each
  refused by name and schedule nothing.
  """
  @spec activate(t()) :: {:ok, binary()} | {:error, term()}
  def activate(%__MODULE__{} = activation),
    do:
      SessionCoordinator.activate_resume(
        activation.coordinator,
        activation.owner,
        activation.capability
      )

  def activate(_activation), do: {:error, :invalid_resume_activation}

  @doc """
  ## Concept

  Gives the capability up, leaving the recovered work permanently paused.

  ## Technical depth

  Abandonment is idempotent and irreversible: the coordinator keeps its
  ownership and stays reachable for an abort, but no later presentation of this
  capability — or of a replacement minted for the same coordinator — can start
  the recovered work. A capability already activated cannot be abandoned,
  because the work it authorized is already the session's own.
  """
  @spec abandon(t()) :: :ok | {:error, term()}
  def abandon(%__MODULE__{} = activation),
    do:
      SessionCoordinator.abandon_resume(
        activation.coordinator,
        activation.owner,
        activation.capability
      )

  def abandon(_activation), do: {:error, :invalid_resume_activation}

  @doc """
  ## Concept

  Hands the capability to another process, which from then on is the only one
  that may spend or give it up.

  ## Technical depth

  ADR 0016 makes interrupt installation and holder transfer one serialized
  handoff, and this is the half that moves the holder. Only the current holder
  may ask, from its own process, and only while the capability is unspent,
  unabandoned, and unfenced; the `:ok` reply is the acknowledgement, because the
  owner has recorded the new holder by the time it answers. A preparer that dies
  before that answer leaves a capability no live process can present, exactly as
  before; one that dies after it leaves the new holder able to spend or abandon
  it. The new holder is monitored, so its own death permanently pauses the
  recovered work rather than leaving a capability waiting on a process that is
  gone.
  """
  @spec transfer(t(), pid()) :: :ok | {:error, term()}
  def transfer(%__MODULE__{} = activation, holder) when is_pid(holder),
    do:
      SessionCoordinator.transfer_resume(
        activation.coordinator,
        activation.owner,
        activation.capability,
        holder
      )

  def transfer(_activation, _holder), do: {:error, :invalid_resume_activation}
end
