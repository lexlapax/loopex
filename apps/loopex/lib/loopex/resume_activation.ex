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

  Only the current holder may ask, from its own process, and only while the
  capability is unspent, unabandoned, and unfenced. On the ordinary path the
  coordinator records the new holder before returning `:ok`; if the caller dies
  before receiving that reply, the transfer may still have happened and the
  missing reply is not a refusal.

  This entry never selects a protocol from ambient process state. Its PID domain
  is unchanged. The initial preparer and every acknowledged holder are monitored;
  loss permanently abandons an unspent capability. Use `transfer/3` when the new
  holder also depends on an explicit local lifetime participant.
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

  @doc """
  ## Concept

  Transfers the capability to a local holder under an explicit lifetime
  participant. The participant protects the holder until the coordinator records
  the handoff, and keeps watching its required dependencies afterwards.

  ## Technical depth

  Let P be this calling holder, H the receiving holder, G the participant and C
  the coordinator. All four must be distinct local PIDs. N is the supplied fresh
  correlation reference. Invalid shape or role aliasing returns
  `{:error, :invalid_resume_handoff}`; any non-local role returns
  `{:error, :non_local_resume_participant}` before liveness checks or mutation.

  G knows P/H/N and monitors P/H before H is exposed. This call creates Q and
  sends `{:loopex_prepared_transfer_pending, P, C, H, N, Q}` to G. Independently C
  creates T and sends `{:loopex_prepared_owner_prepare, C, H, N, Q, T}`. Either
  message may arrive first. Only after both match and all host dependencies are
  established does G send
  `{:loopex_prepared_transfer_guard_ready, G, H, N, Q, T}` to C.

  C creates V and authorizes one verdict, which this calling process forwards as
  `{:loopex_prepared_owner_verdict, C, H, N, Q, V, verdict}`. The verdict is
  `:committed` or `{:refused, reason}` with an atom refusal category. On commit G
  retires P's monitor and sends
  `{:loopex_prepared_owner_verdict_ack, G, H, N, Q, V, :committed}` to C. On refusal
  G ends H, sends the same acknowledgement with the refused verdict and exits.
  Accepting the forwarded commit is the lifetime linearization. G must consume
  forwarded verdict and P's DOWN in one receive state preserving their sender
  order; a later P death cannot revoke an accepted commit even if P loses its
  public reply. Before that acceptance P loss ends H and, once C/Q are known,
  sends `{:loopex_prepared_transfer_installer_lost, G, P, H, N, Q}` to C.

  Matching `{:loopex_prepared_owner_discard, C, H, N, Q}`, C loss, or required
  host-dependency loss ends H. H loss ends G. After commit G keeps observing
  C/H/host dependencies. `{:loopex_prepared_guard_released, C}` retires this
  relationship without acting on a successor holder. Duplicate and mismatched
  messages change nothing. Ending H never retracts a submitted presentation or
  terminates session work whose activation already succeeded.

  C remains responsive throughout. It records H after G's exact acknowledgement
  and only then returns `:ok`, preserving any intervening abort or owner fence.
  Definitive refusal proves no transfer. Loss after possible handoff returns
  `{:unresolved, :resume_handoff_unresolved}`; keep recovery fenced and do not
  infer non-transfer, failed activation or permission to retry. This call waits
  for the exact result without a separate timeout. PIDs, references and the
  opaque capability enter no journal, event, snapshot, progress or diagnostic.
  """
  @spec transfer(t(), pid(), {pid(), reference()}) ::
          :ok | {:error, atom()} | {:unresolved, atom()}
  def transfer(%__MODULE__{} = activation, holder, participant),
    do:
      SessionCoordinator.transfer_resume(
        activation.coordinator,
        activation.owner,
        activation.capability,
        holder,
        participant
      )

  def transfer(_activation, _holder, _participant), do: {:error, :invalid_resume_handoff}
end
