defmodule Loopex.Runtime.ExecutorStream do
  @moduledoc """
  ## Concept

  The progress stream for one executor job attempt. It derives the attempt's
  domain from the job the coordinator dispatched, validates every event against
  that job, assigns the per-domain sequence, and either emits a truthful closure
  or ends the transient plane without one when owner loss leaves the effect
  unproved.

  ## Technical depth

  This is the coordinator's one executor-stream implementation rather than a
  test seam beside it. A job is the complete authority for the stream identity:
  neither an executor event nor a caller supplies a domain or an attempt again.
  The relay remains the sole emitter, including any closing item, so sequences
  are gapless within the domain and nothing can appear after its closure or
  after an owner-loss discard.

  Events that fail one identity binding or the bounded payload projection are
  dropped and counted. The count is private attempt evidence; it never consumes
  a sequence or crosses the progress plane.
  """

  alias Loopex.Executor
  alias Loopex.Runtime.StreamRelay
  alias Loopex.StreamDomain

  @max_progress_chunk_bytes 65_536
  @progress_streams ["stdout", "stderr", "progress"]

  @typedoc """
  ## Concept

  The live state of one executor progress domain.

  ## Technical depth

  The relay owns emission and sequence. The atomic counter records only events
  this boundary refused; the tool-call identifier is retained for the private
  refusal record written when the stream closes.
  """
  @opaque t :: %{
            required(:domain) => StreamDomain.id(),
            required(:turn_id) => binary(),
            required(:relay) => StreamRelay.t(),
            required(:refused) => term(),
            required(:tool_call_id) => binary()
          }

  @typedoc false
  @type publish :: (StreamRelay.t(), term() -> :ok | {:error, term()})

  @doc false
  @spec open(Supervisor.supervisor(), pid() | nil, Executor.job_request(), publish()) ::
          {:ok, t(), Executor.progress_fun()} | {:error, term()}
  def open(supervisor, sink, job, publish) when is_map(job) and is_function(publish, 2) do
    domain = StreamDomain.for_job(job)
    turn_id = job.turn_id
    tool_call_id = job.tool_call_id
    refused = :atomics.new(1, signed: false)
    bindings = progress_bindings(job)

    with {:ok, relay} <-
           StreamRelay.open(
             supervisor,
             sink,
             fn projected, sequence ->
               Map.merge(projected, %{
                 kind: :tool_progress,
                 turn_id: turn_id,
                 tool_call_id: tool_call_id,
                 stream_domain_id: domain,
                 progress_sequence: sequence
               })
             end,
             fn disposition, count ->
               StreamDomain.tool_closed(turn_id, domain, tool_call_id, 0, disposition, count)
             end
           ) do
      stream = %{
        domain: domain,
        turn_id: turn_id,
        relay: relay,
        refused: refused,
        tool_call_id: tool_call_id
      }

      progress = fn event ->
        case project_progress(event, bindings) do
          {:ok, projected} ->
            _admitted = publish.(relay, projected)

          :refused ->
            :atomics.add(refused, 1, 1)
        end

        :ok
      end

      {:ok, stream, progress}
    end
  end

  @doc false
  @spec relay(t()) :: StreamRelay.t()
  def relay(%{relay: relay}), do: relay

  @doc """
  ## Concept

  Closes one executor domain with the disposition its attempt earned.

  ## Technical depth

  Delegates to the same relay that emitted every item. A complete disposition
  states the validated receipt's own count; an abandoned disposition states the
  number this relay actually emitted.
  """
  @spec close(t(), StreamRelay.disposition()) :: non_neg_integer() | :unavailable
  def close(%{relay: relay}, disposition), do: StreamRelay.close(relay, disposition)

  @doc """
  ## Concept

  Ends an executor progress plane without claiming how its effect ended.

  ## Technical depth

  A live owner that has been superseded still owns the effectful worker but no
  longer owns a truthful durable disposition. Delegating to the relay's discard
  path stops projection without constructing an `abandoned` closure from that
  loss of authority.
  """
  @spec discard(t()) :: :ok | :unavailable
  def discard(%{relay: relay}), do: StreamRelay.discard(relay)

  @doc """
  ## Concept

  Reports how many offered events this domain refused.

  ## Technical depth

  Read only after the relay has closed, when no further event can be judged for
  the attempt and the value is stable enough to retain.
  """
  @spec refused_count(t()) :: non_neg_integer()
  def refused_count(%{refused: refused}), do: :atomics.get(refused, 1)

  defp progress_bindings(job) do
    %{
      tool_call_id: job.tool_call_id,
      operation_id: job.operation_id,
      attempt: job.attempt,
      session_id: job.session_id,
      run_id: job.run_id,
      turn_id: job.turn_id,
      canonical_request_digest: job.canonical_request_digest,
      session_epoch_at_dispatch: job.origin_session_epoch,
      executor_epoch: job.origin_executor_epoch,
      executor_identity: job.executor_identity,
      fencing_token: job.fencing_token
    }
  end

  defp project_progress(event, bindings) when is_map(event) do
    bound? =
      Enum.all?(bindings, fn {field, expected} -> Map.fetch(event, field) == {:ok, expected} end)

    if bound?, do: bounded_progress(event), else: :refused
  end

  defp project_progress(_event, _bindings), do: :refused

  defp bounded_progress(%{stream: stream, byte_offset: offset, chunk: chunk})
       when stream in @progress_streams and is_integer(offset) and offset >= 0 and
              is_binary(chunk) and byte_size(chunk) <= @max_progress_chunk_bytes,
       do: {:ok, %{stream: stream, byte_offset: offset, chunk: chunk}}

  defp bounded_progress(_event), do: :refused
end
