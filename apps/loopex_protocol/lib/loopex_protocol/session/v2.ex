defmodule LoopexProtocol.Session.V2 do
  @moduledoc """
  ## Concept

  The second experimental public-session generation served by the durable
  daemon. It keeps generation one's session contract and adds daemon discovery,
  controller leases, and daemon lifecycle records under a distinct exact
  generation and schema digest.

  ## Technical depth

  The M5 plan fixes this ordered metadata and proposed ADR 0032 records its
  rationale. The daemon negotiates only this generation; the foreground server continues to use
  `LoopexProtocol.Session`. The module is pure contract data and validation. It
  owns no connection or runtime state and performs no effects.

  All five digest inputs differ from generation one. Ordering is part of the
  contract, so additions are appended in the order ADR 0032 states them.
  """

  alias LoopexProtocol.Canonical

  @generation "loopex.experimental/2"

  @methods [
    "session.create",
    "session.resume",
    "session.inspect",
    "session.attach",
    "session.prompt",
    "session.steer",
    "session.follow_up",
    "session.abort",
    "session.respond_interaction",
    "resources.catalog",
    "resources.read",
    "session.admit_resources",
    "session.activate_skill",
    "artifact.open_transfer",
    "artifact.read_chunk",
    "artifact.close_transfer",
    "session.list",
    "daemon.status",
    "session.acquire_control",
    "session.release_control"
  ]

  @record_families [
    "initialized",
    "result",
    "snapshot",
    "admission",
    "error",
    "event",
    "progress",
    "daemon.stopping",
    "daemon.notice"
  ]

  @error_codes [
    "invalid_frame",
    "invalid_request",
    "not_initialized",
    "already_initialized",
    "unsupported_generation",
    "unsupported_method",
    "not_attached",
    "attachment_conflict",
    "capacity_exceeded",
    "facade_unavailable",
    "recovery_required",
    "admission_unknown",
    "transfer_refused",
    "detached",
    "internal_failure",
    "control_held",
    "control_not_held",
    "control_pending",
    "control_capacity_reached",
    "control_owner_lost",
    "session_dormant",
    "session_unavailable",
    "daemon_stopping",
    "session_unknown",
    "store_unavailable",
    "activation_ceiling_reached",
    "composition_mismatch"
  ]

  @limits %{
    "frame_bytes_before_initialization" => 65_536,
    "frame_bytes" => 1_048_576,
    "output_record_bytes" => 2_097_152,
    "max_depth" => 16,
    "max_members" => 1_024,
    "max_string_bytes" => 131_072,
    "max_identity_bytes" => 65_536,
    "max_identity_wire_bytes" => 87_382,
    "max_session_identity_bytes" => 256,
    "integer_min" => -9_007_199_254_740_991,
    "integer_max" => 9_007_199_254_740_991,
    "max_requests_in_flight" => 32,
    "durable_queue_records" => 64,
    "durable_queue_bytes" => 4_194_304,
    "progress_queue_records" => 32,
    "progress_queue_bytes" => 524_288,
    "diagnostics_lines" => 64,
    "diagnostics_bytes" => 65_536,
    "raw_chunk_bytes" => 32_768,
    "reply_wait_ms" => 30_000,
    "writer_detach_ms" => 5_000,
    "connections_per_daemon" => 512,
    "initialize_deadline_ms" => 30_000,
    "attachments_per_session" => 64,
    "attachments_per_daemon" => 512,
    "session_list_page_max" => 256,
    "session_index_entries" => 4_096,
    "lease_term_ms" => 30_000
  }

  @doc """
  ## Concept

  The exact daemon protocol generation.

  ## Technical depth

  The daemon selects only this literal. It never silently downgrades to the
  foreground server's generation.
  """
  @spec generation() :: binary()
  def generation, do: @generation

  @doc """
  ## Concept

  The exact methods generation two admits.

  ## Technical depth

  The list is closed and ordered. An absent method is refused before daemon or
  runtime work begins.
  """
  @spec methods() :: [binary()]
  def methods, do: @methods

  @doc """
  ## Concept

  The exact record families generation two may emit.

  ## Technical depth

  The two daemon notification families are uncorrelated. The inherited
  families retain their generation-one meaning.
  """
  @spec record_families() :: [binary()]
  def record_families, do: @record_families

  @doc """
  ## Concept

  The closed generation-two error-code inventory.

  ## Technical depth

  Private daemon and core results must be projected into this list before they
  cross the wire.
  """
  @spec error_codes() :: [binary()]
  def error_codes, do: @error_codes

  @doc """
  ## Concept

  The generation-two schema maxima.

  ## Technical depth

  Generation one's limits are retained byte for byte and the seven daemon
  limits are added under the names fixed by ADR 0032.
  """
  @spec limits() :: %{binary() => integer()}
  def limits, do: @limits

  @doc """
  ## Concept

  The digest that names the complete generation-two contract.

  ## Technical depth

  It covers the generation and the ordered method, family and error inventories
  plus all limits through the repository's canonical encoding.
  """
  @spec schema_digest() :: binary()
  def schema_digest do
    Canonical.digest(%{
      "generation" => @generation,
      "methods" => @methods,
      "record_families" => @record_families,
      "error_codes" => @error_codes,
      "limits" => @limits
    })
  end

  @doc """
  ## Concept

  Negotiates generation two from a client's ordered offer.

  ## Technical depth

  Only the exact generation-two literal can match. Generation one and the
  retired generation-one spelling are both refused when offered alone.
  Capabilities are reported as unsupported and enable no method.
  """
  @spec negotiate([binary()], [binary()]) ::
          {:ok, map()} | {:error, :unsupported_generation}
  def negotiate(generations, capabilities)
      when is_list(generations) and is_list(capabilities) do
    case Enum.find(generations, &(&1 == @generation)) do
      nil ->
        {:error, :unsupported_generation}

      selected ->
        {:ok,
         %{
           "type" => "initialized",
           "selected_generation" => selected,
           "exact_schema_sha256" => schema_digest(),
           "supported_methods" => @methods,
           "record_families" => @record_families,
           "limits" => @limits,
           "unsupported_capabilities" => capabilities
         }}
    end
  end
end
