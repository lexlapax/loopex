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

  Four required callbacks and five core-owned facades, with optional attachment
  transfers and job-range retrieval. The `handle` is edge-private
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

  alias Loopex.Instrumentation
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
  @hex_transfer_ref ~r/^[0-9a-f]{32}$/
  @max_transfer_object_bytes 67_108_864
  @object_work_bytes 134_217_728
  @metadata_read_bytes 131_073
  @transfer_reasons [
    :invalid_artifact_request,
    :invalid_open_context,
    :reservation_required,
    :reservation_conflict,
    :unknown_artifact_use,
    :artifact_use_mismatch,
    :artifact_integrity_failed,
    :artifact_digest_mismatch,
    :unknown_artifact,
    :artifact_too_large,
    :invalid_window,
    :open_deadline_exhausted,
    :open_work_budget_exhausted,
    :transfer_limit_reached,
    :transfers_unavailable,
    :artifact_unreadable,
    :cancelled
  ]

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

  @typedoc """
  ## Concept

  One authorized, verified transfer of one immutable artifact object, and the
  window of it a caller asked for.

  ## Technical depth

  Accepted ADR 0028 verifies the whole object once at open and emits chunks
  afterwards, so the digest this carries covers every byte a later chunk can
  contain. `window_start` and `window_length` are fixed at open: a chunk never
  crosses the window, and the window cannot be moved afterwards. The reference
  is opaque and belongs to the attachment that opened it.
  """
  @type transfer :: %{
          required(:transfer_ref) => binary(),
          required(:object) => artifact_object(),
          required(:use_locator) => binary(),
          required(:total_size) => non_neg_integer(),
          required(:window_start) => non_neg_integer(),
          required(:window_length) => non_neg_integer(),
          required(:object_digest) => binary()
        }

  @typedoc """
  ## Concept

  One bounded piece of a transfer, with its own digest.

  ## Technical depth

  The chunk digest covers exactly the bytes in this chunk, and is distinct from
  the object digest the open response carried; a reader can check what it just
  received without holding the whole object to check the one that covers it.
  """
  @type chunk :: %{
          required(:offset) => non_neg_integer(),
          required(:bytes) => binary(),
          required(:chunk_digest) => binary()
        }

  @typedoc """
  ## Concept

  An authorized use and immutable requested window.

  ## Technical depth

  Closed request; session identity is lossless Store-owned binary data. Length may be absent, never nil.
  """
  @type transfer_request :: %{
          required(:session_id) => binary(),
          required(:use_locator) => binary(),
          required(:start) => non_neg_integer(),
          optional(:length) => non_neg_integer()
        }

  @typedoc """
  ## Concept

  The original opening identity, originating-VM cutoff and declared work.

  ## Technical depth

  Reserve and open share this exact record; pure validation does not decide timeliness or caller authority.
  """
  @type open_context :: %{
          required(:transfer_ref) => binary(),
          required(:open_deadline_ms) => integer(),
          required(:object_work_bytes) => 134_217_728,
          required(:metadata_read_bytes) => 131_073
        }

  @typedoc """
  ## Concept

  Conservative work retained for one opening, including failure.

  ## Technical depth

  Payload work and separately bounded metadata are distinct; unavailable accounting is never a zero record.
  """
  @type transfer_work :: %{
          required(:source_read_bytes) => non_neg_integer(),
          required(:snapshot_write_debit) => non_neg_integer(),
          required(:metadata_read_bytes) => non_neg_integer(),
          required(:write_uncertain) => boolean()
        }

  @typedoc """
  ## Concept

  The closed reason for a current admitted transfer refusal.

  ## Technical depth

  Private exceptions and malformed producer results remain uncertainty, outside this result grammar.
  """
  @type transfer_reason ::
          :invalid_artifact_request
          | :invalid_open_context
          | :reservation_required
          | :reservation_conflict
          | :unknown_artifact_use
          | :artifact_use_mismatch
          | :artifact_integrity_failed
          | :artifact_digest_mismatch
          | :unknown_artifact
          | :artifact_too_large
          | :invalid_window
          | :open_deadline_exhausted
          | :open_work_budget_exhausted
          | :transfer_limit_reached
          | :transfers_unavailable
          | :artifact_unreadable
          | :cancelled

  @typedoc """
  ## Concept

  Retire original custody or acknowledge its retained physical proof.

  ## Technical depth

  Selectors are closed. Receipt correlation cannot itself prove retirement or grant authority.
  """
  @type close_context ::
          %{
            required(:action) => :retire,
            required(:transfer_ref) => binary(),
            required(:open_deadline_ms) => integer(),
            required(:close_deadline_ms) => integer()
          }
          | %{
              required(:action) => :acknowledge,
              required(:transfer_ref) => binary(),
              required(:receipt_ref) => binary()
            }

  @typedoc """
  ## Concept

  The bounded non-I/O reservation reply.

  ## Technical depth

  A valid not_reserved refusal proves no admitted entry remains; exceptions do not.
  """
  @type reserve_result ::
          {:ok, %{required(:transfer_ref) => binary()}}
          | {:error,
             %{
               required(:reason) => transfer_reason(),
               required(:transfer_ref) => binary(),
               required(:state) => :not_reserved
             }}

  @typedoc """
  ## Concept

  Verified opening evidence or retained retiring work.

  ## Technical depth

  Core must still validate authority, original clocks, adoption and exact custody; grammar alone proves none of them.
  """
  @type open_result ::
          {:ok,
           %{
             required(:transfer) => transfer(),
             required(:use) => artifact_use(),
             required(:work) => transfer_work()
           }}
          | {:error,
             %{
               required(:reason) => transfer_reason(),
               required(:transfer_ref) => binary(),
               required(:work) => transfer_work(),
               required(:state) => :retiring | :retired
             }}

  @typedoc """
  ## Concept

  Physical retirement evidence retained until its exact acknowledgement.

  ## Technical depth

  Unregistered is absence information, not cleanup proof. A retired record may explicitly lack accounting.
  """
  @type close_result ::
          {:retired,
           %{
             required(:transfer_ref) => binary(),
             required(:receipt_ref) => binary(),
             required(:work) => transfer_work() | :unavailable
           }}
          | {:unregistered, %{required(:transfer_ref) => binary()}}
          | :ok
          | {:error, :cleanup_unproved | :invalid_close_context | :retirement_receipt_mismatch}

  @callback put(handle :: term(), bytes :: binary(), normalized_use()) ::
              {:ok, artifact_reference()} | {:error, term()}

  @callback fetch(handle :: term(), artifact_object()) ::
              {:ok, binary()} | {:error, term()}

  @callback stat(handle :: term(), locator :: binary()) ::
              {:ok, artifact_object()} | {:error, term()}

  @callback describe(handle :: term(), use_locator :: binary()) ::
              {:ok, artifact_use()} | {:error, term()}

  # Concept: admission precedes storage and remains responsive to cancellation.
  # Technical depth: reserve does no I/O; only the same original caller and
  # acknowledged request/context can open once. ADR 0066 owns their lifetimes.
  @callback reserve_transfer(handle :: term(), transfer_request(), open_context()) ::
              reserve_result()
              | {:error,
                 :invalid_artifact_request
                 | :invalid_open_context
                 | :reservation_conflict
                 | :reservation_required
                 | :transfers_unavailable}

  @callback open_transfer(handle :: term(), transfer_request(), open_context()) ::
              open_result()
              | {:error,
                 :invalid_artifact_request
                 | :invalid_open_context
                 | :reservation_conflict
                 | :reservation_required
                 | :transfers_unavailable}

  @callback read_transfer(handle :: term(), transfer(), length :: pos_integer()) ::
              {:ok, chunk()} | {:ok, :complete} | {:error, term()}

  @callback close_transfer(handle :: term(), close_context()) :: close_result()

  # Concept: an approved job retrieves one verified range without an attachment.
  # Technical depth: the executor validates its grant before this optional call.
  # The adapter verifies the resolved object/use and session provenance, reserves
  # shared runtime capacity and job work before storage, and owns deadline,
  # cancellation and descriptor cleanup. Success returns exactly the requested
  # raw bytes, shortened only at EOF, after cleanup. It never falls back to fetch.
  # Invoke in the executor's disposable I/O process: deadline enforcement may
  # terminate that process, whose DOWN is the executor's cleanup evidence.
  @callback read_job_range(handle :: term(), Loopex.Executor.JobRequest.t()) ::
              {:ok, binary()} | {:error, term()}

  # Concept: a store may omit the whole bounded attachment-transfer capability.
  # Technical depth: current capability requires all four callbacks together.
  # Unsupported stores refuse boundedly; no fetch fallback or mixed generation.
  @optional_callbacks reserve_transfer: 3,
                      open_transfer: 3,
                      read_transfer: 3,
                      close_transfer: 2,
                      read_job_range: 2

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

  The exact ceilings a bounded transfer runs under.

  ## Technical depth

  Accepted ADRs 0028 and 0066 retain the object, payload-work, read, lifetime
  and capacity ceilings. Opening spends one original 60-second deadline;
  `metadata_read_bytes` is explicitly additional to `open_work_bytes`.
  Cleanup observation spends one first-anchored `cleanup_deadline_ms` without
  extending opening. Pending, live, retiring and unacknowledged proof retain
  capacity. These are safety ceilings, not measured service-level promises.
  """
  @spec transfer_limits() :: %{atom() => pos_integer()}
  def transfer_limits do
    %{
      object_bytes: 67_108_864,
      open_deadline_ms: 60_000,
      open_work_bytes: 134_217_728,
      metadata_read_bytes: 131_073,
      cleanup_deadline_ms: 5_000,
      chunk_bytes: 32_768,
      read_deadline_ms: 5_000,
      lifetime_ms: 600_000,
      per_attachment: 2,
      per_runtime: 4
    }
  end

  @doc """
  ## Concept

  Whether a composed store implements the whole current transfer capability.

  ## Technical depth

  All four current callbacks must be present. The facade refuses an omitted
  capability without storage fallback; a partial callback set cannot reserve
  custody it cannot open, read and retire.
  """
  @spec supports_transfer?(module()) :: boolean()
  def supports_transfer?(module) when is_atom(module) do
    Code.ensure_loaded?(module) and
      function_exported?(module, :reserve_transfer, 3) and
      function_exported?(module, :open_transfer, 3) and
      function_exported?(module, :read_transfer, 3) and
      function_exported?(module, :close_transfer, 2)
  end

  def supports_transfer?(_module), do: false

  @doc """
  ## Concept

  Whether an opening request is closed and bounded.

  ## Technical depth

  Lossless session identity obeys Store’s existing 256-byte limit. Window integers are unsigned64; absence alone selects remaining length.
  """
  @spec valid_transfer_request?(term()) :: boolean()
  def valid_transfer_request?(request) do
    closed =
      closed_transfer_map?(request, [:session_id, :use_locator, :start]) or
        closed_transfer_map?(request, [:session_id, :use_locator, :start, :length])

    closed and is_binary(request.session_id) and byte_size(request.session_id) in 1..256 and
      valid_transfer_use_locator?(request.use_locator) and valid_size?(request.start) and
      (not Map.has_key?(request, :length) or valid_size?(request.length))
  end

  @doc """
  ## Concept

  Whether the original opening context has the accepted shape.

  ## Technical depth

  Signed monotonic deadlines belong to the originating VM. This pure check neither reads a clock nor authorizes opening.
  """
  @spec valid_open_context?(term()) :: boolean()
  def valid_open_context?(context) do
    closed_transfer_map?(context, [
      :transfer_ref,
      :open_deadline_ms,
      :object_work_bytes,
      :metadata_read_bytes
    ]) and valid_transfer_ref?(context.transfer_ref) and is_integer(context.open_deadline_ms) and
      context.object_work_bytes === @object_work_bytes and
      context.metadata_read_bytes === @metadata_read_bytes
  end

  @doc """
  ## Concept

  Whether a retirement or proof acknowledgement selector is closed.

  ## Technical depth

  Selectors retain original identities and signed cutoffs. Clock order, proof and caller custody are enforced by their owners.
  """
  @spec valid_close_context?(term()) :: boolean()
  def valid_close_context?(context) do
    cond do
      closed_transfer_map?(context, [
        :action,
        :transfer_ref,
        :open_deadline_ms,
        :close_deadline_ms
      ]) ->
        context.action == :retire and valid_transfer_ref?(context.transfer_ref) and
          is_integer(context.open_deadline_ms) and is_integer(context.close_deadline_ms)

      closed_transfer_map?(context, [:action, :transfer_ref, :receipt_ref]) ->
        context.action == :acknowledge and valid_transfer_ref?(context.transfer_ref) and
          valid_transfer_ref?(context.receipt_ref)

      true ->
        false
    end
  end

  @doc """
  ## Concept

  Whether returned use evidence exactly matches the authorized request.

  ## Technical depth

  Local opening and Core adoption share the existing scalar/canonical/digest check. No live describe or I/O occurs; valid provenance never grants authority.
  """
  @spec valid_transfer_use?(term(), term()) :: boolean()
  def valid_transfer_use?(use, request) do
    valid_transfer_request?(request) and well_shaped_use?(use) and
      use.object_size <= @max_transfer_object_bytes and
      use.metadata["session_id"] == request.session_id and
      validate_described_use(use, %{
        digest: use.object_digest,
        size: use.object_size,
        locator: use.object_locator,
        media_type: use.media_type,
        role: use.role,
        use_canonicalization_version: Canonical.version(),
        use_digest: binary_part(request.use_locator, 4, 64)
      }) == {:ok, use}
  end

  @doc """
  ## Concept

  Whether reported opening work obeys the accepted closed accounting grammar.

  ## Technical depth

  Source and attempted snapshot writes are payload work; metadata is additional. Unavailable accounting is not accepted as a zero map.
  """
  @spec valid_transfer_work?(term()) :: boolean()
  def valid_transfer_work?(work) do
    closed_transfer_map?(work, [
      :source_read_bytes,
      :snapshot_write_debit,
      :metadata_read_bytes,
      :write_uncertain
    ]) and is_integer(work.source_read_bytes) and
      work.source_read_bytes in 0..@max_transfer_object_bytes and
      is_integer(work.snapshot_write_debit) and
      work.snapshot_write_debit in 0..@max_transfer_object_bytes and
      work.source_read_bytes + work.snapshot_write_debit <= @object_work_bytes and
      is_integer(work.metadata_read_bytes) and work.metadata_read_bytes in 0..@metadata_read_bytes and
      is_boolean(work.write_uncertain)
  end

  @doc """
  ## Concept

  Whether a transfer projection retains the exact original request and context.

  ## Technical depth

  Whole-object facts remain bounded; the requested window is exact and never clamped. This shape check does not prove stored bytes or adoption.
  """
  @spec valid_transfer?(term(), term(), term()) :: boolean()
  def valid_transfer?(transfer, request, context) do
    valid_transfer_request?(request) and valid_open_context?(context) and
      closed_transfer_map?(transfer, [
        :transfer_ref,
        :object,
        :use_locator,
        :total_size,
        :window_start,
        :window_length,
        :object_digest
      ]) and valid_object?(transfer.object) and
      transfer.object.size <= @max_transfer_object_bytes and
      transfer.transfer_ref == context.transfer_ref and
      transfer.use_locator == request.use_locator and
      transfer.total_size === transfer.object.size and
      transfer.object_digest == transfer.object.digest and request.start <= transfer.total_size and
      transfer.window_start === request.start and
      transfer.window_length == Map.get(request, :length, transfer.total_size - request.start) and
      valid_size?(transfer.window_length) and
      transfer.window_length <= transfer.total_size - request.start
  end

  @doc """
  ## Concept

  Whether a reservation reply has the exact original identity.

  ## Technical depth

  A not_reserved refusal is closed evidence, not a replacement for original callback completion and joins.
  """
  @spec valid_reserve_result?(term(), term()) :: boolean()
  def valid_reserve_result?(result, context) do
    valid_open_context?(context) and
      case result do
        {:ok, reservation} ->
          closed_transfer_map?(reservation, [:transfer_ref]) and
            reservation.transfer_ref == context.transfer_ref

        {:error, refusal} ->
          closed_transfer_map?(refusal, [:reason, :transfer_ref, :state]) and
            refusal.reason in @transfer_reasons and refusal.transfer_ref == context.transfer_ref and
            refusal.state == :not_reserved

        _ ->
          false
      end
  end

  @doc """
  ## Concept

  Whether an opening reply retains exact use, object, window and work evidence.

  ## Technical depth

  Only the existing pure ArtifactStore checks validate use bytes. Admitted failure retains bounded work; exceptions remain uncertainty.
  """
  @spec valid_open_result?(term(), term(), term()) :: boolean()
  def valid_open_result?(result, request, context) do
    valid_transfer_request?(request) and valid_open_context?(context) and
      case result do
        {:ok, opened} ->
          closed_transfer_map?(opened, [:transfer, :use, :work]) and
            valid_transfer_use?(opened.use, request) and
            valid_transfer?(opened.transfer, request, context) and
            opened.transfer.object == %{
              digest: opened.use.object_digest,
              size: opened.use.object_size,
              locator: opened.use.object_locator
            } and valid_transfer_work?(opened.work) and
            opened.work.source_read_bytes == opened.transfer.object.size and
            opened.work.snapshot_write_debit == opened.transfer.object.size and
            opened.work.write_uncertain == false

        {:error, refusal} ->
          closed_transfer_map?(refusal, [:reason, :transfer_ref, :work, :state]) and
            refusal.reason in @transfer_reasons and refusal.transfer_ref == context.transfer_ref and
            refusal.state in [:retiring, :retired] and valid_transfer_work?(refusal.work)

        _ ->
          false
      end
  end

  @doc """
  ## Concept

  Whether close evidence matches the original retire or acknowledgement selector.

  ## Technical depth

  A retired record binds its Store receipt and bounded or explicitly unavailable work. Unregistered and ack success alone do not prove cleanup.
  """
  @spec valid_close_result?(term(), term()) :: boolean()
  def valid_close_result?(result, context) do
    valid_close_context?(context) and
      case {context.action, result} do
        {:retire, {:retired, retired}} ->
          closed_transfer_map?(retired, [:transfer_ref, :receipt_ref, :work]) and
            retired.transfer_ref == context.transfer_ref and
            valid_transfer_ref?(retired.receipt_ref) and
            (retired.work == :unavailable or valid_transfer_work?(retired.work))

        {:retire, {:unregistered, absent}} ->
          closed_transfer_map?(absent, [:transfer_ref]) and
            absent.transfer_ref == context.transfer_ref

        {:retire, {:error, reason}} ->
          reason in [:cleanup_unproved, :invalid_close_context]

        {:acknowledge, :ok} ->
          true

        {:acknowledge, {:error, reason}} ->
          reason in [:retirement_receipt_mismatch, :invalid_close_context]

        _ ->
          false
      end
  end

  @doc """
  ## Concept

  Whether a public admitted failure has the closed reason and cleanup disposition.

  ## Technical depth

  Private work, receipts and identities cannot leak through this facade projection. Proved cleanup still requires original owner evidence.
  """
  @spec valid_transfer_failure?(term()) :: boolean()
  def valid_transfer_failure?({:error, refusal}) do
    closed_transfer_map?(refusal, [:reason, :cleanup]) and
      refusal.reason in @transfer_reasons and refusal.cleanup in [:proved, :unproved]
  end

  def valid_transfer_failure?(_result), do: false

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
    span([:artifact, :put], %{bytes: byte_size(bytes)}, fn ->
      put_verified(module, handle, bytes, metadata)
    end)
  end

  def put(_store, _bytes, _metadata), do: {:error, :invalid_artifact_metadata}

  defp put_verified(module, handle, bytes, metadata) do
    with {:ok, use} <- normalize_use(metadata),
         {:ok, reference} <- adapter_put(module, handle, bytes, use),
         :ok <- object_matches_input(reference, bytes),
         {:ok, expected} <- expected_use(reference, use),
         :ok <- confirm_use(module, handle, reference, expected) do
      {:ok, reference}
    end
  end

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
      span([:artifact, :fetch], %{locator: object.locator, bytes: object.size}, fn ->
        case module.fetch(handle, object) do
          {:ok, bytes} when is_binary(bytes) -> verify_bytes(bytes, object)
          {:error, reason} -> {:error, reason}
          _other -> {:error, :artifact_integrity_failed}
        end
      end)
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
      span([:artifact, :stat], %{locator: locator}, fn ->
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
      end)
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
      span([:artifact, :describe], %{use_locator: reference.use_locator}, fn ->
        case module.describe(handle, reference.use_locator) do
          {:ok, use} -> validate_described_use(use, reference)
          {:error, reason} -> {:error, reason}
          _other -> {:error, :artifact_use_mismatch}
        end
      end)
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
  # Concept: one instrumented artifact-store dispatch, named in the accepted
  # inventory.
  #
  # Technical depth: the span wraps the verified operation, not just the adapter
  # call, because a store that answers with the wrong bytes has not succeeded and
  # the span must not say it did. Metadata carries object and use references and
  # byte totals; the bytes themselves and a caller's own metadata never reach it.
  defp span(event, metadata, work) do
    Instrumentation.span(event, metadata, work, &Instrumentation.outcome/1)
  end

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
    if well_shaped_use?(use) and scalar_lower_bound(use.metadata) <= @max_use_bytes and
         use.canonicalization_version == reference.use_canonicalization_version and
         use.object_digest == reference.digest and use.object_size == reference.size and
         use.object_locator == reference.locator and use.media_type == reference.media_type and
         use.role == reference.role and
         bounded_use_digest?(use, reference.use_digest) do
      {:ok, use}
    else
      {:error, :artifact_use_mismatch}
    end
  end

  # Concept: described uses obey the same byte ceiling as newly retained uses.
  # Technical depth: scalar preflight bounds the allocation; the complete
  # canonical encoding then checks overhead and supplies the exact digest.
  defp bounded_use_digest?(use, digest) do
    encoded = Canonical.encode([@use_tag, use])
    byte_size(encoded) <= @max_use_bytes and Canonical.digest_bytes(encoded) == digest
  end

  # Concept: a record read back from storage is checked before it is encoded.
  #
  # Technical depth: the digest comparison above encodes the described record,
  # and canonical encoding raises on a term outside bounded plain data. Checking
  # the shape first turns an adapter returning a pid or a struct into a typed
  # refusal rather than an exception inside whatever was resolving provenance.
  defp well_shaped_use?(use) when is_map(use) and not is_struct(use) do
    map_size(use) == 7 and
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
      is_map(use.metadata) and not is_struct(use.metadata) and map_size(use.metadata) == 5 and
      Enum.sort(Map.keys(use.metadata)) == @use_labels and valid_use_labels?(use.metadata)
  end

  defp well_shaped_use?(_use), do: false

  # Concept: each transfer record has one exact plain-data grammar.
  # Technical depth: count bounds key sorting; each value is checked by its
  # owning scalar or ArtifactStore validator before it is inspected further.
  defp closed_transfer_map?(value, keys) do
    is_map(value) and not is_struct(value) and map_size(value) == length(keys) and
      Enum.sort(Map.keys(value)) == Enum.sort(keys)
  end

  defp valid_transfer_ref?(value) do
    is_binary(value) and byte_size(value) == 32 and String.match?(value, @hex_transfer_ref)
  end

  defp valid_transfer_use_locator?("use:" <> digest), do: valid_digest?(digest)
  defp valid_transfer_use_locator?(_value), do: false

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
