defmodule LoopexComposition.Delegation.Receipt do
  @moduledoc """
  ## Concept

  Build the executor receipt a helper call returns, and the retained object
  that keeps its exact bytes for later reconciliation.

  ## Technical depth

  The receipt binds the original JobRequest's identity tuple exactly as Core's
  executor contract requires and is validated by Core's own
  `SessionState.validate_executor_receipt/2` before it is retained or
  returned. The retained object is ADR 0056's closed `receipt` object: the
  stored job projection plus the plain receipt map as a three-member ETF
  envelope. Opaque binaries never become JSON text.
  """

  alias Loopex.Runtime.SessionState
  alias LoopexComposition.Delegation.LedgerCodec

  @encoding "loopex.ledger.plain_etf.v1.base64"

  @doc false
  @spec build(map(), atom(), binary(), :confirmed | :unconfirmed, integer()) ::
          {:ok, map()} | {:error, :invalid_executor_receipt}
  def build(job, outcome, output, cleanup, observed_at_ms) do
    SessionState.validate_executor_receipt(
      %{
        protocol_version: job.protocol_version,
        job_id: job.job_id,
        operation_id: job.operation_id,
        attempt: job.attempt,
        session_id: job.session_id,
        run_id: job.run_id,
        turn_id: job.turn_id,
        tool_call_id: job.tool_call_id,
        session_epoch_at_dispatch: job.origin_session_epoch,
        executor_epoch: job.origin_executor_epoch,
        executor_identity: job.executor_identity,
        canonical_request_digest: job.canonical_request_digest,
        fencing_token: job.fencing_token,
        tool_id: job.tool_id,
        tool_version: job.tool_version,
        outcome: outcome,
        output: output,
        progress_count: 0,
        observed_at_ms: observed_at_ms,
        child_environment_names: [],
        provider_credential_present: false,
        artifacts: [],
        cleanup_grace_ms: job.cleanup_grace_ms,
        cleanup_confirmation: Atom.to_string(cleanup)
      },
      job
    )
  end

  @doc false
  @spec object(binary(), map(), map(), map()) :: {:ok, binary()} | {:error, term()}
  def object(runtime_id, operation_identity, job_projection, receipt) do
    plain = plain(receipt)
    bytes = :erlang.term_to_binary(plain, [:deterministic])

    LedgerCodec.encode_json(
      %{
        "version" => 1,
        "kind" => "receipt",
        "runtime_id" => Base.encode64(runtime_id),
        "operation_identity" => operation_identity,
        "job" => job_projection,
        "receipt" => %{
          "encoding" => @encoding,
          "bytes" => Base.encode64(bytes),
          "sha256" => :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
        }
      },
      :object
    )
  end

  @doc false
  @spec plain(map()) :: map()
  def plain(receipt) do
    Map.new(receipt, fn
      {key, value} when is_atom(value) and value not in [nil, true, false] ->
        {Atom.to_string(key), Atom.to_string(value)}

      {key, value} ->
        {Atom.to_string(key), value}
    end)
  end
end
