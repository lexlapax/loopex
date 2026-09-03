defmodule Loopex.Runtime.ExecutorStream do
  @moduledoc """
  ## Concept

  The progress stream for one executor job attempt. It derives the attempt's
  domain from the job the coordinator dispatched, validates every event against
  that job and the stream position it claims, and either emits a truthful
  closure or ends the transient plane without one when owner loss leaves the
  effect unproved.

  ## Technical depth

  This is the coordinator's one executor-stream implementation rather than a
  test seam beside it. A job is the complete authority for the stream identity:
  neither an executor event nor a caller supplies a domain or an attempt again.
  The relay remains the sole emitter, including any closing item, so nothing can
  appear after closure or owner-loss discard. Model sequences are gapless;
  executor sequences are carried unchanged and therefore preserve a visible gap
  wherever this boundary refused a current-attempt payload.

  Events that fail one identity, sequence, offset, or bounded-payload binding
  are dropped and counted by the first failed binding. That private attempt
  evidence never crosses the progress plane. A wrong identity or sequence does
  not advance the live attempt; a later payload refusal does consume its already
  validated executor sequence but never its stream bytes.
  """

  alias Loopex.Executor
  alias Loopex.ProgressPayload
  alias Loopex.Runtime.StreamRelay
  alias Loopex.StreamDomain

  @max_progress_chunk_bytes 65_536
  @progress_streams ["stdout", "stderr", "progress"]
  @identity_bindings [
    :protocol_version,
    :job_id,
    :tool_call_id,
    :operation_id,
    :attempt,
    :session_id,
    :run_id,
    :turn_id,
    :canonical_request_digest,
    :session_epoch_at_dispatch,
    :executor_epoch,
    :executor_identity,
    :fencing_token
  ]
  @refusal_bindings @identity_bindings ++
                      [:progress_sequence, :stream, :byte_offset, :chunk]

  @typedoc """
  ## Concept

  The live state of one executor progress domain.

  ## Technical depth

  The relay owns emission order and carries each validated executor-supplied
  sequence unchanged. The atomic counters record refused events by their first
  failed binding until the stream closes; the tool-call identifier names the
  bounded diagnostic emitted for that attempt. Neither becomes durable state.
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
  @spec open(
          Supervisor.supervisor(),
          pid() | nil,
          Executor.job_request(),
          non_neg_integer(),
          publish()
        ) ::
          {:ok, t(), Executor.progress_fun()} | {:error, term()}
  def open(supervisor, sink, job, base_event_sequence, publish)
      when is_map(job) and is_integer(base_event_sequence) and base_event_sequence >= 0 and
             is_function(publish, 2) do
    domain = StreamDomain.for_job(job)
    turn_id = job.turn_id
    tool_call_id = job.tool_call_id
    refused = :atomics.new(length(@refusal_bindings), signed: false)
    bindings = progress_bindings(job)

    with {:ok, relay} <-
           StreamRelay.open_stateful(
             supervisor,
             sink,
             %{
               next_sequence: 0,
               offsets: %{"stdout" => 0, "stderr" => 0, "progress" => 0}
             },
             fn event, _projected_count, validation ->
               case project_progress(event, bindings, validation) do
                 {:ok, projected, next_validation} ->
                   {:emit,
                    Map.merge(projected, %{
                      kind: :tool_progress,
                      turn_id: turn_id,
                      tool_call_id: tool_call_id,
                      stream_domain_id: domain,
                      base_event_sequence: base_event_sequence
                    }), next_validation}

                 {:refused, binding, next_validation} ->
                   increment_refusal(refused, binding)
                   {:drop, next_validation}
               end
             end,
             fn disposition, count ->
               StreamDomain.tool_closed(
                 turn_id,
                 domain,
                 tool_call_id,
                 base_event_sequence,
                 disposition,
                 count
               )
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
        _admitted = publish.(relay, event)
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
  def refused_count(%{refused: refused}) do
    @refusal_bindings
    |> Enum.with_index(1)
    |> Enum.reduce(0, fn {_binding, index}, count -> count + :atomics.get(refused, index) end)
  end

  @doc false
  @spec refused_bindings(t()) :: %{optional(binary()) => pos_integer()}
  def refused_bindings(%{refused: refused}) do
    @refusal_bindings
    |> Enum.with_index(1)
    |> Enum.reduce(%{}, fn {binding, index}, bindings ->
      case :atomics.get(refused, index) do
        0 -> bindings
        count -> Map.put(bindings, Atom.to_string(binding), count)
      end
    end)
  end

  defp progress_bindings(job) do
    [
      protocol_version: job.protocol_version,
      job_id: job.job_id,
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
    ]
  end

  defp project_progress(event, bindings, validation) when is_map(event) do
    case Enum.find(bindings, fn {field, expected} ->
           Map.fetch(event, field) != {:ok, expected}
         end) do
      nil -> sequenced_progress(event, validation)
      {binding, _expected} -> {:refused, binding, validation}
    end
  end

  defp project_progress(_event, _bindings, validation),
    do: {:refused, :protocol_version, validation}

  defp sequenced_progress(event, %{next_sequence: sequence} = validation) do
    event_sequence = Map.get(event, :progress_sequence)

    if not is_integer(event_sequence) or event_sequence < 0 or event_sequence != sequence do
      {:refused, :progress_sequence, validation}
    else
      bounded_progress(event, %{validation | next_sequence: sequence + 1})
    end
  end

  defp bounded_progress(event, %{offsets: offsets} = validation) do
    stream = Map.get(event, :stream)
    offset = Map.get(event, :byte_offset)
    chunk = Map.get(event, :chunk)

    cond do
      stream not in @progress_streams ->
        {:refused, :stream, validation}

      not is_integer(offset) or offset < 0 or Map.fetch!(offsets, stream) != offset ->
        {:refused, :byte_offset, validation}

      not ProgressPayload.terminal_safe?(chunk) or
          byte_size(chunk) > @max_progress_chunk_bytes ->
        {:refused, :chunk, validation}

      true ->
        {:ok,
         %{
           progress_sequence: Map.fetch!(event, :progress_sequence),
           stream: stream,
           byte_offset: offset,
           chunk: chunk
         }, %{validation | offsets: Map.put(offsets, stream, offset + byte_size(chunk))}}
    end
  end

  defp increment_refusal(refused, binding) do
    index = Enum.find_index(@refusal_bindings, &(&1 == binding)) + 1
    :atomics.add(refused, index, 1)
  end
end
