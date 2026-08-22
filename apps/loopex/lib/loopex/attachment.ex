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
            snapshot: map()
          }
  defstruct [:runtime, :session_id, :attachment_id, :incarnation_id, :snapshot]

  @doc """
  ## Concept

  Returns the authoritative snapshot captured with this attachment.

  ## Technical depth

  Its `event_sequence` is the exact durable cursor installed before later
  events enter the bounded dispatcher queue.
  """
  @spec snapshot(t()) :: map()
  def snapshot(%__MODULE__{snapshot: snapshot}), do: snapshot

  @doc false
  @spec from_runtime(Runtime.t(), binary(), binary(), binary(), map()) :: t()
  def from_runtime(runtime, session_id, attachment_id, incarnation_id, snapshot) do
    %__MODULE__{
      runtime: runtime,
      session_id: session_id,
      attachment_id: attachment_id,
      incarnation_id: incarnation_id,
      snapshot: snapshot
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
