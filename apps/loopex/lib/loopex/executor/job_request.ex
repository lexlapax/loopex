defmodule Loopex.Executor.JobRequest do
  @moduledoc """
  ## Concept

  One executor request, as one named value rather than a map that happens to
  carry the right keys.

  ## Technical depth

  The struct's members are exactly the ordered semantic fields the canonical
  request digest binds, plus the three members derived from them: the canonical
  bytes, their digest, and the immutable wall-clock instant. Naming the shape is
  what makes an absent or misspelt member a compile-visible or match-visible
  fault instead of a silently missing key, and what lets a caller project the
  members back out with `Map.from_struct/1` and rebuild an independent job from
  them, the derived three being recomputed rather than carried.

  `effective_job_deadline` is a wall-clock instant and is fixed once, when the
  job is built. It is never recomputed, and it is never compared with or added
  to a monotonic instant: ADR 0016 keeps the two clock domains separate, and an
  executor derives its own private monotonic action deadline from the remaining
  wall duration at handoff.
  """

  # Concept: the ordered semantic projection the digest binds.
  #
  # Technical depth: this list is the single source for both the struct's
  # members and `Loopex.Executor.job_fields/0`, so the digested projection and
  # the value that carries it cannot drift apart. Order is significant: the
  # canonical bytes are the ordered pairs in exactly this sequence.
  @semantic_fields [
    :protocol_version,
    :job_id,
    :operation_id,
    :attempt,
    :session_id,
    :run_id,
    :turn_id,
    :tool_call_id,
    :origin_session_epoch,
    :origin_executor_epoch,
    :executor_identity,
    :required_capabilities,
    :tool_id,
    :tool_version,
    :effect_class,
    :validated_arguments,
    :workspace_ref,
    :workspace_lease,
    :run_deadline,
    :resource_budgets,
    :idempotency_class,
    :fencing_token,
    :artifact_policy,
    :output_policy,
    :cleanup_grace_ms
  ]

  defstruct @semantic_fields ++
              [:canonical_request_bytes, :canonical_request_digest, :effective_job_deadline]

  @derived_fields [:canonical_request_bytes, :canonical_request_digest, :effective_job_deadline]

  @typedoc """
  ## Concept

  One immutable executor request with its independently checkable digest.

  ## Technical depth

  Every member is bounded plain data. No pid, reference, function, port, or
  implementation type is admitted, because this value crosses the durable and
  executor boundaries unchanged.
  """
  @type t :: %__MODULE__{}

  @doc """
  ## Concept

  The ordered semantic fields the canonical request digest binds.

  ## Technical depth

  Returned as data so the port, the digest computation, and the durable decoder
  all read one list rather than three copies of it.
  """
  @spec semantic_fields() :: [atom()]
  def semantic_fields, do: @semantic_fields

  @doc """
  ## Concept

  The members this value derives rather than accepts.

  ## Technical depth

  A caller rebuilding a job from another job's projection may hand these back;
  they are recomputed and never trusted. Any other extra member is an unknown
  field and refuses, so a misspelt semantic field cannot be silently dropped
  from the digested projection.
  """
  @spec derived_fields() :: [atom()]
  def derived_fields, do: @derived_fields
end
