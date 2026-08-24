defmodule Loopex.ArtifactStore do
  @moduledoc """
  ## Concept

  Where a tool's output goes when there is more of it than the model should be
  shown. A test suite's full output, a large file, a long build log: the model
  gets a bounded result that says what was truncated, and the whole of it is kept
  somewhere the operator can read back.

  This exists because the alternative is worse than it looks. A bounded result
  that simply discards the remainder is not a bound, it is silent data loss
  dressed as one — the operator asked a tool to run and part of what it produced
  is gone, with nothing recording that it ever existed.

  Fixed by
  [ADR 0009](../../../../docs/adr/0009-tool-executor-and-grant-contracts.md#concept).

  ## Technical depth

  Three callbacks. The `handle` is edge-private placement state and is never
  journaled, published, or transported; the `artifact_reference` is the only
  thing that crosses a boundary.

  Storage is content-addressed and `put/3` is idempotent: the same bytes stored
  twice yield the same reference and one stored object. An adapter compares the
  bytes rather than trusting a digest it was handed, because trusting the digest
  would let two different objects share a reference and the second write would
  silently win.

  `fetch/2` returns exactly the stored bytes or a typed error. A digest mismatch
  is an integrity error and never a silent success, and an unknown or collected
  reference is `{:error, :unknown_artifact}` rather than an empty success — an
  empty artifact and a missing one are different facts and a caller must be able
  to tell them apart.

  Size ceilings belong to the adapter and are declared. A `put/3` over the
  ceiling fails closed with a truthful error rather than storing a truncated
  artifact, for the same reason the spill exists at all.

  M2 collects nothing automatically. Pinning is explicit for an operation's
  retry and recovery window; deciding when an artifact may go is a host and
  adapter duty, and a kernel that quietly reclaimed one could remove the evidence
  a reconciliation was about to need.
  """

  @roles ["tool_output"]

  @typedoc """
  ## Concept

  What a caller holds to fetch an artifact back.

  ## Technical depth

  Bounded plain data. `locator` is opaque to core, which never parses, joins, or
  reconstructs it: how an adapter addresses its own storage is the adapter's
  business, and a core that took it apart would be coupled to one adapter's
  layout.
  """
  @type artifact_reference :: %{
          required(:digest) => binary(),
          required(:media_type) => binary(),
          required(:size) => non_neg_integer(),
          required(:role) => binary(),
          required(:locator) => binary()
        }

  @callback put(handle :: term(), bytes :: binary(), metadata :: map()) ::
              {:ok, artifact_reference()} | {:error, term()}

  @callback fetch(handle :: term(), artifact_reference()) ::
              {:ok, binary()} | {:error, term()}

  @callback stat(handle :: term(), artifact_reference()) ::
              {:ok, artifact_reference()} | {:error, term()}

  @doc """
  ## Concept

  The logical roles an artifact may carry.

  ## Technical depth

  A closed enumeration with one member today. It exists as an enumeration rather
  than a free string so that adding a second role is a visible change to this
  list rather than a value that appears in stored data one day and has to be
  reverse-engineered later.
  """
  @spec roles() :: [binary()]
  def roles, do: @roles

  @doc """
  ## Concept

  Whether a term is a well-formed artifact reference.

  ## Technical depth

  Checked at the boundary rather than trusted, because a reference crosses into
  the durable record and is retained. A malformed one committed now is a
  malformed one a recovery reads back later.
  """
  @spec valid_reference?(term()) :: boolean()
  def valid_reference?(reference) when is_map(reference) and not is_struct(reference) do
    Enum.sort(Map.keys(reference)) == [:digest, :locator, :media_type, :role, :size] and
      is_binary(reference.digest) and
      String.match?(reference.digest, ~r/^[0-9a-f]{64}$/) and
      is_binary(reference.media_type) and reference.media_type != "" and
      is_integer(reference.size) and reference.size >= 0 and
      reference.role in @roles and
      is_binary(reference.locator) and reference.locator != ""
  end

  def valid_reference?(_reference), do: false

  @doc """
  ## Concept

  The bounded result a model is shown when output spilled.

  ## Technical depth

  It says how much was kept, how much there was, and that the rest is retrievable
  — never that the output simply ended. A model told nothing about the truncation
  would reason about a partial result as though it were the whole one, which is
  the specific failure a bound is supposed to prevent rather than cause.
  """
  @spec truncation_notice(binary(), non_neg_integer(), artifact_reference()) :: binary()
  def truncation_notice(kept, total_bytes, reference) do
    kept <>
      "\n\n[loopex: output truncated. " <>
      "#{byte_size(kept)} of #{total_bytes} bytes shown. " <>
      "The complete output is retained as artifact #{reference.digest}.]"
  end
end
