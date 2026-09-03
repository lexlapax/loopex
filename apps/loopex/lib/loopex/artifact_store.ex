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

  One artifact has two identities. The *object* is the stored bytes: identical
  bytes are one object however many times they are retained. The *use* is why one
  caller retained them — which session, run, operation, attempt, and tool call
  produced that retention. Content addressing needs the first to be equal for
  identical bytes; auditability needs the second to survive even when two uses
  share an object. Conflating them either destroys deduplication or lets a later
  caller rewrite what an earlier durable receipt meant.

  The reason is retained but never published. The compact reference that reaches
  a receipt, an event, or an operator carries the object triple, the media type
  and role, and a digest-derived handle onto the use — never the opaque
  identifiers themselves. An authorized reader resolves those through
  `describe/2`.

  Fixed by
  [ADR 0009](../../../../docs/adr/0009-tool-executor-and-grant-contracts.md#concept)
  and
  [ADR 0015](../../../../docs/adr/0015-artifact-object-and-use-identity.md#concept).

  ## Technical depth

  Four callbacks and five core-owned facades. The `handle` is edge-private
  placement state and is never journaled, published, or transported; the
  `t:artifact_reference/0` is the only thing that crosses a boundary.

  Adapters never see caller input. `put/3` here normalizes the closed provenance
  record first, so an adapter receives exactly `%{media_type:, role:, metadata:}`
  and cannot be handed an unknown key to copy into durable state. Core then
  computes the expected digest and size from the exact input bytes, requires the
  adapter's answer to match them, reconstructs the complete use record from the
  validated returned object triple, and resolves the adapter's `use_locator`
  through `describe/2` before the reference may reach anything durable. An
  adapter that rewrites provenance and still returns a well-shaped reference is
  refused rather than believed.

  `fetch/2` takes object identity, reads by the opaque locator, and verifies
  exact digest and size. `stat/2` takes an opaque locator and returns object
  facts only; it never invents use labels, and an answer naming a different
  locator is refused. `retrieve/2` is the public locator-only composition of the
  two and constructs no probe reference.

  Storage is content-addressed and `put/3` is idempotent by object and by use:
  the same bytes and the same provenance yield the same compact reference, while
  a second provenance keeps the object and gains a distinct immutable use.

  Size ceilings belong to the adapter and are declared. A `put/3` over the
  ceiling fails closed with a truthful error rather than storing a truncated
  artifact, for the same reason the spill exists at all. The canonical use
  encoding has its own fixed ceiling here, guarded twice: once by a scalar lower
  bound before any output is allocated, and once by the exact encoded size after
  the adapter has named the object.

  M2 collects nothing automatically. Pinning is explicit for an operation's
  retry and recovery window; deciding when an artifact may go is a host and
  adapter duty, and a kernel that quietly reclaimed one could remove the evidence
  a reconciliation was about to need.
  """

  alias LoopexProtocol.Canonical

  @roles ["tool_output"]
  @default_media_type "application/octet-stream"
  @max_media_type_bytes 255
  @max_locator_bytes 1_024
  @max_size 18_446_744_073_709_551_615
  @max_use_bytes 131_072
  @use_tag "artifact-use-v2"
  @use_locator_prefix "use:"
  @use_labels ["attempt", "operation_id", "run_id", "session_id", "tool_call_id"]
  @opaque_use_labels ["operation_id", "run_id", "session_id", "tool_call_id"]
  @unsafe_reference_codepoints ~r/[\p{Cc}\p{Cf}\p{Zl}\p{Zp}]/u
  @hex_digest ~r/^[0-9a-f]{64}$/

  @typedoc """
  ## Concept

  The identity of stored bytes, independent of why anyone kept them.

  ## Technical depth

  Exactly three members. Storing identical bytes twice yields the same triple and
  one immutable stored object. `locator` is opaque to core, which never parses,
  joins, or reconstructs it: how an adapter addresses its own storage is the
  adapter's business, and a core that took it apart would be coupled to one
  adapter's layout. Within one adapter namespace a locator is permanently bound
  to at most this one digest/size pair, so an old locator resolves its original
  object or unavailable — never newer bytes.
  """
  @type artifact_object :: %{
          required(:digest) => binary(),
          required(:size) => non_neg_integer(),
          required(:locator) => binary()
        }

  @typedoc """
  ## Concept

  The closed provenance of one retention: why these bytes were kept.

  ## Technical depth

  Immutable and private. It binds the complete object triple, including the
  opaque locator, so a use sidecar returned for one object cannot validate a
  same-bytes reference naming another. The five metadata labels are exactly the
  admitted set; there is no recursive, note, or credential position, and the four
  identifiers stay lossless opaque binaries because their source contracts make
  them identifiers rather than public text.
  """
  @type artifact_use :: %{
          required(:canonicalization_version) => binary(),
          required(:object_digest) => binary(),
          required(:object_size) => non_neg_integer(),
          required(:object_locator) => binary(),
          required(:media_type) => binary(),
          required(:role) => binary(),
          required(:metadata) => %{optional(binary()) => binary() | pos_integer()}
        }

  @typedoc """
  ## Concept

  What a caller holds to fetch an artifact back, and the only artifact fact that
  crosses a durable or public boundary.

  ## Technical depth

  Bounded plain data, eight members. Digests are exactly one lowercase
  hexadecimal SHA-256, media types are non-empty safe UTF-8 of at most 255 bytes,
  sizes fit in one unsigned 64-bit value, and the role is a closed enumeration.
  Opaque does not mean unbounded or safe to print without validation: locators
  are valid UTF-8 of at most 1,024 bytes and carry no control, format,
  line-separator, or paragraph-separator codepoint.

  `use_locator` is exactly `"use:" <> use_digest` rather than a value an adapter
  chose, so the public handle cannot be made to encode a private provenance
  member. `use_canonicalization_version` is repeated here so a recovering reader
  selects the retained encoding before it verifies the digest instead of decoding
  unknown bytes with the current encoder by assumption.
  """
  @type artifact_reference :: %{
          required(:digest) => binary(),
          required(:size) => non_neg_integer(),
          required(:locator) => binary(),
          required(:media_type) => binary(),
          required(:role) => binary(),
          required(:use_canonicalization_version) => binary(),
          required(:use_digest) => binary(),
          required(:use_locator) => binary()
        }

  @typedoc """
  ## Concept

  What an adapter receives instead of caller input.

  ## Technical depth

  Projected by `put/3` from the closed caller record after both reserved values
  are validated and every unknown key is refused. An adapter therefore never
  holds a rejected free-form value and has nothing to sanitize.
  """
  @type normalized_use :: %{
          required(:media_type) => binary(),
          required(:role) => binary(),
          required(:metadata) => %{optional(binary()) => binary() | pos_integer()}
        }

  @typedoc """
  ## Concept

  A composed artifact store: the implementation and its edge-private placement
  state.

  ## Technical depth

  The shape every other composed port here uses, so a host that supplies a
  different implementation is followed rather than bypassed.
  """
  @type store :: %{required(:module) => module(), required(:handle) => term()}

  @callback put(handle :: term(), bytes :: binary(), normalized_use()) ::
              {:ok, artifact_reference()} | {:error, term()}

  @callback fetch(handle :: term(), artifact_object()) ::
              {:ok, binary()} | {:error, term()}

  @callback stat(handle :: term(), locator :: binary()) ::
              {:ok, artifact_object()} | {:error, term()}

  @callback describe(handle :: term(), use_locator :: binary()) ::
              {:ok, artifact_use()} | {:error, term()}

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

  The ceiling on one canonical use record.

  ## Technical depth

  Declared rather than implicit so a caller can see the boundary it is admitted
  against. It is large enough for the existing 1,024-byte executor identifiers
  plus a tool-call identifier already retained inside one 65,536-byte Store item,
  with deterministic encoding overhead, and is a distinct artifact-use admission
  boundary rather than a restatement of either of those.
  """
  @spec max_use_bytes() :: pos_integer()
  def max_use_bytes, do: @max_use_bytes

  @doc """
  ## Concept

  Whether a term is a well-formed compact artifact reference.

  ## Technical depth

  Checked at the boundary rather than trusted, because a reference crosses into
  the durable record and is retained. A malformed one committed now is a
  malformed one a recovery reads back later. A five-member development reference
  written before the object/use split carries no trustworthy provenance and is
  refused here rather than upgraded with invented labels.
  """
  @spec valid_reference?(term()) :: boolean()
  def valid_reference?(reference) when is_map(reference) and not is_struct(reference) do
    Enum.sort(Map.keys(reference)) == [
      :digest,
      :locator,
      :media_type,
      :role,
      :size,
      :use_canonicalization_version,
      :use_digest,
      :use_locator
    ] and
      valid_digest?(reference.digest) and
      valid_media_type?(reference.media_type) and
      valid_size?(reference.size) and
      reference.role in @roles and
      valid_locator?(reference.locator) and
      reference.use_canonicalization_version == Canonical.version() and
      valid_digest?(reference.use_digest) and
      reference.use_locator == @use_locator_prefix <> reference.use_digest
  end

  def valid_reference?(_reference), do: false

  @doc """
  ## Concept

  Whether a term is a well-formed object identity.

  ## Technical depth

  Exactly the three members a locator resolves to. A compact reference is not an
  object: admitting one here would let use identity into a lookup answer, which
  is the conflation the object/use split exists to remove.
  """
  @spec valid_object?(term()) :: boolean()
  def valid_object?(object) when is_map(object) and not is_struct(object) do
    Enum.sort(Map.keys(object)) == [:digest, :locator, :size] and
      valid_digest?(object.digest) and
      valid_size?(object.size) and
      valid_locator?(object.locator)
  end

  def valid_object?(_object), do: false

  @doc """
  ## Concept

  Retains bytes with the exact reason they were retained, and returns the compact
  reference that names both.

  ## Technical depth

  The only caller-facing way into an adapter's `put/3`. It normalizes the closed
  provenance record, refuses an oversized scalar before any canonical output is
  allocated, and hands the adapter a projected `t:normalized_use/0`.

  Core computes the expected digest and size from the exact input bytes before
  the call, so an adapter that returns a self-consistent false object — its own
  digest, its own size, its own matching sidecar — is refused rather than
  trusted. It then rebuilds the complete use record from the *returned* object
  triple, checks the exact encoded ceiling, and immediately resolves
  `use_locator` through `describe/2`. Success means the adapter's own stored
  answer was read back and agreed, not that it claimed one.
  """
  @spec put(store(), binary(), map()) :: {:ok, artifact_reference()} | {:error, term()}
  def put(%{module: module, handle: handle}, bytes, metadata)
      when is_atom(module) and is_binary(bytes) do
    with {:ok, use} <- normalize_use(metadata),
         {:ok, reference} <- adapter_put(module, handle, bytes, use),
         :ok <- object_matches_input(reference, bytes),
         {:ok, expected} <- expected_use(reference, use),
         :ok <- confirm_use(module, handle, reference, expected) do
      {:ok, reference}
    end
  end

  def put(_store, _bytes, _metadata), do: {:error, :invalid_artifact_metadata}

  @doc """
  ## Concept

  Reads the exact bytes an object identity names.

  ## Technical depth

  Accepts an object or a compact reference and projects the object identity
  before adapter access, so an adapter is never handed use metadata it might read
  as part of byte identity. The digest is recomputed over the returned bytes and
  the size compared, because an adapter that hands back the wrong bytes must fail
  here rather than wherever they are read next. An unknown locator stays
  `{:error, :unknown_artifact}` and is therefore distinguishable from an empty
  artifact, which is a successful zero-byte read.
  """
  @spec fetch(store(), artifact_object() | artifact_reference()) ::
          {:ok, binary()} | {:error, term()}
  def fetch(%{module: module, handle: handle}, artifact) when is_atom(module) do
    with {:ok, object} <- object_identity(artifact) do
      case module.fetch(handle, object) do
        {:ok, bytes} when is_binary(bytes) -> verify_bytes(bytes, object)
        {:error, reason} -> {:error, reason}
        _other -> {:error, :artifact_integrity_failed}
      end
    end
  end

  def fetch(_store, _artifact), do: {:error, :invalid_artifact_reference}

  @doc """
  ## Concept

  Resolves an opaque locator to object facts, and to nothing else.

  ## Technical depth

  A locator can name stored bytes but cannot identify which of several uses a
  caller meant, so this answers with the object triple alone. Choosing one
  retained use would fabricate provenance and returning all of them would turn a
  lookup into an index.

  The returned locator must equal the requested one. An adapter answering with
  another valid object — equal digest and size included — is refused, because a
  locator that can resolve to different bytes is a mutable name rather than an
  identity.
  """
  @spec stat(store(), binary()) :: {:ok, artifact_object()} | {:error, term()}
  def stat(%{module: module, handle: handle}, locator)
      when is_atom(module) and is_binary(locator) do
    if valid_locator?(locator) do
      case module.stat(handle, locator) do
        {:ok, object} ->
          if valid_object?(object) and object.locator == locator,
            do: {:ok, object},
            else: {:error, :invalid_artifact_reference}

        {:error, reason} ->
          {:error, reason}

        _other ->
          {:error, :invalid_artifact_reference}
      end
    else
      {:error, :invalid_artifact_reference}
    end
  end

  def stat(_store, _locator), do: {:error, :invalid_artifact_reference}

  @doc """
  ## Concept

  Resolves the private reason one artifact was retained.

  ## Technical depth

  Projects the reference's fixed use locator, reads the immutable record the
  adapter published beside the object, and revalidates it against everything the
  compact reference already states: the encoding version, the complete object
  triple including its opaque locator, the media type, the role, and the use
  digest. A record that resolves but disagrees is unavailable artifact truth
  rather than provenance — which is what stops a same-bytes reference from
  borrowing another object's use.
  """
  @spec describe(store(), artifact_reference()) :: {:ok, artifact_use()} | {:error, term()}
  def describe(%{module: module, handle: handle}, reference) when is_atom(module) do
    if valid_reference?(reference) do
      case module.describe(handle, reference.use_locator) do
        {:ok, use} -> validate_described_use(use, reference)
        {:error, reason} -> {:error, reason}
        _other -> {:error, :artifact_use_mismatch}
      end
    else
      {:error, :invalid_artifact_reference}
    end
  end

  def describe(_store, _reference), do: {:error, :invalid_artifact_reference}

  @doc """
  ## Concept

  Reads a retained artifact back by the opaque locator an operator was given.

  ## Technical depth

  A caller holds a locator and a composed store, and wants the bytes. Doing that
  by hand means calling an adapter twice, and a caller can name a concrete
  adapter without noticing. The command did exactly that, which coupled a peer
  surface to the reference implementation while the port sat unused beside it.

  It is the composition of the two core facades and nothing else: validated
  locator-only `stat/2`, then `fetch/2` over that exact validated object. The
  superseded form built a lookup probe carrying an invented digest, size, media
  type, and role; that shape passed a validator while proving nothing about the
  locator, so it is gone rather than tolerated.
  """
  @spec retrieve(store(), binary()) :: {:ok, binary()} | {:error, term()}
  def retrieve(%{module: module, handle: _handle} = store, locator)
      when is_atom(module) and is_binary(locator) do
    with {:ok, object} <- stat(store, locator), do: fetch(store, object)
  end

  def retrieve(_store, _locator), do: {:error, :invalid_artifact_reference}

  @doc """
  ## Concept

  The bounded result a model is shown when output spilled.

  ## Technical depth

  It says how much was kept, how much there was, and that the rest is retrievable
  — never that the output simply ended. A model told nothing about the truncation
  would reason about a partial result as though it were the whole one, which is
  the specific failure a bound is supposed to prevent rather than cause. It names
  the opaque locator, which is the retrieval handle, and no private use label.

  The wording is deliberately terse. A caller's declared output ceiling bounds
  this notice as it bounds everything else the model is shown, and a ceiling
  narrow enough to cut the sentence cuts the locator with it — producing a notice
  that names an artifact which does not exist, which is worse than the plain
  truncation marker it would otherwise have had. Every byte here therefore has to
  earn its place against a ceiling as small as the shipped narrow ones, so the
  prose that surrounded the locator is gone and the locator itself is not.
  """
  @spec truncation_notice(binary(), non_neg_integer(), artifact_reference()) :: binary()
  def truncation_notice(kept, total_bytes, reference) do
    kept <>
      "\n\n[loopex: output truncated. " <>
      "#{byte_size(kept)} of #{total_bytes} bytes shown. " <>
      reference.locator <> "]"
  end

  # Concept: the caller's record is closed, and closing it is core's job rather
  # than each adapter's.
  #
  # Technical depth: the two reserved labels become top-level reference members
  # and the remaining five stay together as the private use. The key set must be
  # exactly the admitted one: an unknown `note` or `credential` member is refused
  # instead of copied, so there is no path from a caller-controlled string into a
  # journal, event, artifact, or fixture. The role is checked before the rest
  # because reporting a name this store cannot honour as "invalid metadata" would
  # send a caller looking at the wrong field.
  defp normalize_use(metadata) when is_map(metadata) and not is_struct(metadata) do
    role = Map.get(metadata, "role", "tool_output")
    media_type = Map.get(metadata, "media_type", @default_media_type)
    labels = Map.drop(metadata, ["media_type", "role"])

    cond do
      not Enum.all?(Map.keys(metadata), &is_binary/1) -> {:error, :invalid_artifact_metadata}
      role not in @roles -> {:error, {:unknown_artifact_role, role}}
      not valid_media_type?(media_type) -> {:error, :invalid_artifact_metadata}
      Enum.sort(Map.keys(labels)) != @use_labels -> {:error, :invalid_artifact_metadata}
      not valid_use_labels?(labels) -> {:error, :invalid_artifact_metadata}
      scalar_lower_bound(labels) > @max_use_bytes -> {:error, :artifact_use_too_large}
      true -> {:ok, %{media_type: media_type, role: role, metadata: labels}}
    end
  end

  defp normalize_use(_metadata), do: {:error, :invalid_artifact_metadata}

  # Concept: an opaque identifier is admitted exactly as its source contract
  # produced it.
  #
  # Technical depth: the four identifiers are non-empty binaries and are neither
  # decoded, sanitized, nor rendered — invalid UTF-8 and control bytes already
  # admitted upstream survive here, because the compact reference never publishes
  # them and rewriting one would make the retained provenance a different fact
  # from the identity it came from. `attempt` is an arbitrary positive integer.
  defp valid_use_labels?(labels) do
    Enum.all?(@opaque_use_labels, fn label ->
      value = Map.fetch!(labels, label)
      is_binary(value) and value != ""
    end) and is_integer(labels["attempt"]) and labels["attempt"] > 0
  end

  # Concept: refuse an impossible use before allocating the bytes that would
  # prove it impossible.
  #
  # Technical depth: the exact ceiling cannot be applied until the adapter names
  # the object locator, and canonical encoding of a caller-sized value allocates
  # that value first. Summing each admitted scalar's own footprint — `byte_size`
  # for the four opaque identifiers and `external_size` for an attempt that may
  # be a bignum — gives a lower bound on the encoding without producing it. Every
  # admitted scalar contributes: a term omitted here is a term whose size the
  # guard cannot see.
  defp scalar_lower_bound(labels) do
    byte_size(labels["session_id"]) +
      byte_size(labels["run_id"]) +
      byte_size(labels["operation_id"]) +
      byte_size(labels["tool_call_id"]) +
      :erlang.external_size(labels["attempt"])
  end

  defp adapter_put(module, handle, bytes, use) do
    case module.put(handle, bytes, use) do
      {:ok, reference} ->
        if valid_reference?(reference) and reference.media_type == use.media_type and
             reference.role == use.role,
           do: {:ok, reference},
           else: {:error, :invalid_artifact_reference}

      {:error, reason} ->
        {:error, reason}

      _other ->
        {:error, :invalid_artifact_reference}
    end
  end

  # Concept: the bytes core was handed decide the object, not the answer core was
  # given about them.
  #
  # Technical depth: an adapter that substitutes either object fact can otherwise
  # publish a self-consistent sidecar for the substitution and pass every later
  # comparison, because every later comparison is against that same answer.
  defp object_matches_input(reference, bytes) do
    if reference.digest == Canonical.digest_bytes(bytes) and reference.size == byte_size(bytes),
      do: :ok,
      else: {:error, :artifact_integrity_failed}
  end

  defp expected_use(reference, use) do
    artifact_use = %{
      canonicalization_version: Canonical.version(),
      object_digest: reference.digest,
      object_size: reference.size,
      object_locator: reference.locator,
      media_type: use.media_type,
      role: use.role,
      metadata: use.metadata
    }

    encoded = Canonical.encode([@use_tag, artifact_use])

    if byte_size(encoded) > @max_use_bytes,
      do: {:error, :artifact_use_too_large},
      else: {:ok, {artifact_use, Canonical.digest_bytes(encoded)}}
  end

  # Concept: a reference is durable truth only once the adapter's own stored use
  # has been read back and agreed with it.
  #
  # Technical depth: this is the immediate resolution ADR 0015 requires. Without
  # it an adapter could return a reference whose use it never published, or one
  # it published with different provenance, and the receipt naming that reference
  # would already be committed before anybody tried to resolve it.
  defp confirm_use(module, handle, reference, {expected, expected_digest}) do
    case module.describe(handle, reference.use_locator) do
      {:ok, described} ->
        if described == expected and expected_digest == reference.use_digest,
          do: :ok,
          else: {:error, :artifact_use_mismatch}

      {:error, reason} ->
        {:error, reason}

      _other ->
        {:error, :artifact_use_mismatch}
    end
  end

  defp object_identity(artifact) do
    cond do
      valid_reference?(artifact) -> {:ok, Map.take(artifact, [:digest, :size, :locator])}
      valid_object?(artifact) -> {:ok, artifact}
      true -> {:error, :invalid_artifact_reference}
    end
  end

  defp verify_bytes(bytes, object) do
    if Canonical.digest_bytes(bytes) == object.digest and byte_size(bytes) == object.size,
      do: {:ok, bytes},
      else: {:error, :artifact_integrity_failed}
  end

  defp validate_described_use(use, reference) do
    if well_shaped_use?(use) and
         use.canonicalization_version == reference.use_canonicalization_version and
         use.object_digest == reference.digest and use.object_size == reference.size and
         use.object_locator == reference.locator and use.media_type == reference.media_type and
         use.role == reference.role and
         Canonical.digest([@use_tag, use]) == reference.use_digest do
      {:ok, use}
    else
      {:error, :artifact_use_mismatch}
    end
  end

  # Concept: a record read back from storage is checked before it is encoded.
  #
  # Technical depth: the digest comparison above encodes the described record,
  # and canonical encoding raises on a term outside bounded plain data. Checking
  # the shape first turns an adapter returning a pid or a struct into a typed
  # refusal rather than an exception inside whatever was resolving provenance.
  defp well_shaped_use?(use) when is_map(use) and not is_struct(use) do
    Enum.sort(Map.keys(use)) == [
      :canonicalization_version,
      :media_type,
      :metadata,
      :object_digest,
      :object_locator,
      :object_size,
      :role
    ] and
      is_binary(use.canonicalization_version) and valid_digest?(use.object_digest) and
      valid_size?(use.object_size) and valid_locator?(use.object_locator) and
      valid_media_type?(use.media_type) and use.role in @roles and
      is_map(use.metadata) and not is_struct(use.metadata) and
      Enum.sort(Map.keys(use.metadata)) == @use_labels and valid_use_labels?(use.metadata)
  end

  defp well_shaped_use?(_use), do: false

  defp valid_digest?(digest) when is_binary(digest) do
    byte_size(digest) == 64 and String.valid?(digest) and String.match?(digest, @hex_digest)
  end

  defp valid_digest?(_digest), do: false

  defp valid_size?(size), do: is_integer(size) and size in 0..@max_size

  defp valid_media_type?(media_type) when is_binary(media_type) do
    byte_size(media_type) in 1..@max_media_type_bytes and String.valid?(media_type) and
      not Regex.match?(@unsafe_reference_codepoints, media_type)
  end

  defp valid_media_type?(_media_type), do: false

  defp valid_locator?(locator) when is_binary(locator) do
    byte_size(locator) in 1..@max_locator_bytes and String.valid?(locator) and
      not Regex.match?(@unsafe_reference_codepoints, locator)
  end

  defp valid_locator?(_locator), do: false
end
