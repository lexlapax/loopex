defmodule Loopex.Attachment do
  @moduledoc """
  ## Concept

  A transient handle for one caller's bounded view of a session. It carries the
  authoritative snapshot captured when the runtime installed its durable-event
  cursor, but it does not own or extend the session lifetime.

  ## Technical depth

  Attachment and incarnation IDs are checked by the current runtime dispatcher.
  Dispatcher restart, explicit disconnect, or runtime stop makes an old handle
  stale. None of the handle fields is written to private records or the public
  outbox; recovery uses only the last stable durable event sequence.
  """

  alias Loopex.Runtime

  @typedoc """
  ## Concept

  An opaque runtime-local attachment and its initial snapshot.

  ## Technical depth

  The embedded Runtime reference and incarnation are capabilities only inside
  the current BEAM process tree. The snapshot is bounded plain public data.
  """
  @opaque t :: %__MODULE__{
            runtime: Runtime.t(),
            session_id: binary(),
            attachment_id: binary(),
            incarnation_id: binary(),
            snapshot: map(),
            open_interaction: map() | nil
          }
  defstruct [
    :runtime,
    :session_id,
    :attachment_id,
    :incarnation_id,
    :snapshot,
    :open_interaction
  ]

  @doc """
  ## Concept

  Returns the authoritative snapshot captured with this attachment.

  ## Technical depth

  Its `event_sequence` is the exact durable cursor installed before later
  events enter the bounded dispatcher queue.
  """
  @spec snapshot(t()) :: map()
  def snapshot(%__MODULE__{snapshot: snapshot}), do: snapshot

  @doc """
  ## Concept

  Returns the question that was open at this attachment's own cursor, if any.

  ## Technical depth

  Accepted ADR 0023 makes this a sibling of the snapshot rather than a member of
  it, because accepted ADR 0017 fixes the snapshot's members exactly. It is
  projected from the same public events a client replays, so two attachments at
  one cursor cannot disagree about whether a question was waiting there; live
  coordinator state answers a different question, which is what is open now.
  """
  @spec open_interaction(t()) :: map() | nil
  def open_interaction(%__MODULE__{open_interaction: open_interaction}), do: open_interaction

  @doc false
  @spec from_runtime(Runtime.t(), binary(), binary(), binary(), map(), map() | nil) :: t()
  def from_runtime(
        runtime,
        session_id,
        attachment_id,
        incarnation_id,
        snapshot,
        open_interaction \\ nil
      ) do
    %__MODULE__{
      runtime: runtime,
      session_id: session_id,
      attachment_id: attachment_id,
      incarnation_id: incarnation_id,
      snapshot: snapshot,
      open_interaction: open_interaction
    }
  end

  @doc false
  @spec routing(t()) :: {:ok, Runtime.t(), binary(), binary(), binary()} | {:error, term()}
  def routing(%__MODULE__{
        runtime: %Runtime{} = runtime,
        session_id: session_id,
        attachment_id: attachment_id,
        incarnation_id: incarnation_id
      })
      when is_binary(session_id) and is_binary(attachment_id) and is_binary(incarnation_id) do
    {:ok, runtime, session_id, attachment_id, incarnation_id}
  end

  def routing(_attachment), do: {:error, :invalid_attachment}
end
