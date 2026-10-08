defmodule Loopex.Runtime.ProgressIngress do
  @moduledoc false

  alias Loopex.ProgressSink

  @executor_fields [
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
    :fencing_token,
    :progress_sequence,
    :stream,
    :byte_offset,
    :chunk
  ]
  @model_fields %{
    text_delta: [:kind, :content_index, :text],
    reasoning_delta: [:kind, :content_index, :text],
    tool_call_delta: [:kind, :call_index, :tool_call_id, :name, :arguments_fragment]
  }
  @owner_fields [:generation, :owner_epoch, :owner_incarnation_id, :transaction_id]
  @max_integer 18_446_744_073_709_551_615

  @doc false
  def gate, do: :atomics.new(4, signed: false)

  @doc false
  def seal(gate) do
    :atomics.put(gate, 1, 2)
    :atomics.put(gate, 3, 1)
    :ok
  end

  @doc false
  def closed?(gate), do: :atomics.get(gate, 3) == 1

  @doc false
  def preflight(:model, item) when is_map(item) and not is_struct(item) do
    case item do
      %{kind: kind} when kind in [:text_delta, :reasoning_delta, :tool_call_delta] ->
        fields = Map.fetch!(@model_fields, kind)

        map_size(item) == length(fields) and
          Enum.all?(fields, &Map.has_key?(item, &1)) and bounded_fields?(item, fields)

      _ ->
        false
    end
  end

  def preflight(:executor, item) when is_map(item) and not is_struct(item) do
    # Concept: only finite plain raw fields may enter the observed prefix.
    # Technical depth: missing or wrong scalar members still reach the existing
    # first-binding validator; unknown/private keys and unbounded terms do not.
    map_size(item) <= length(@executor_fields) and
      Enum.count(@executor_fields, &Map.has_key?(item, &1)) == map_size(item) and
      bounded_fields?(item, @executor_fields)
  end

  def preflight(:activity, item), do: match?({:ok, _}, Loopex.CompactionProgress.project(item))
  def preflight(_kind, _item), do: false

  @doc false
  def route?(control, session, owner, relay, gate, kind, header) do
    is_pid(control) and is_pid(relay) and is_reference(gate) and
      kind in [:model, :executor, :activity] and
      is_binary(session) and byte_size(session) in 1..256 and
      is_map(owner) and not is_struct(owner) and map_size(owner) == 4 and
      Enum.all?(@owner_fields, &Map.has_key?(owner, &1)) and
      bounded_fields?(owner, @owner_fields) and header?(header)
  end

  @doc false
  def reserve(
        _control,
        _session,
        _owner,
        {_relay, nil, _gate, _kind, _captured_control, _captured_session, _captured_owner,
         _header},
        _item
      ) do
    :dropped
  end

  def reserve(
        control,
        session,
        owner,
        {relay, sink, gate, kind, control, session, owner, header},
        item
      ) do
    cond do
      not route?(control, session, owner, relay, gate, kind, header) ->
        :dropped

      not is_pid(ProgressSink.control(sink)) ->
        :dropped

      not preflight(kind, item) ->
        :dropped

      kind == :activity ->
        reserve_item(
          sink,
          session,
          item,
          {ProgressSink.control(sink), relay, session, owner, gate, kind, header, self()}
        )

      :atomics.compare_exchange(gate, 1, 0, 1) != :ok ->
        :atomics.put(gate, 1, 2)
        :dropped

      true ->
        result =
          reserve_item(
            sink,
            session,
            item,
            {ProgressSink.control(sink), relay, session, owner, gate, kind, header, self()}
          )

        case result do
          {:ok, _reference} -> :atomics.compare_exchange(gate, 1, 1, 0)
          _ -> :atomics.put(gate, 1, 2)
        end

        result
    end
  rescue
    ArgumentError -> :dropped
  end

  def reserve(_control, _session, _owner, _relay, _item), do: :dropped

  # Concept: materialization finishes before control custody is published.
  # Technical depth: reserve_raw owns the producer phase until its stack frame
  # returns. No payload accompanies this metadata handoff or its wake.
  defp reserve_item(sink, session, item, route) do
    case ProgressSink.reserve_raw(sink, session, item, route) do
      {:ok, reference} ->
        if ProgressSink.route_stage(
             sink,
             reference,
             :raw_reserved,
             :control_ready,
             elem(route, 0)
           ) do
          {:ok, reference}
        else
          ProgressSink.retire_stage(sink, reference, :raw_reserved)
          :dropped
        end

      _ ->
        :dropped
    end
  end

  defp header?(header) when is_map(header) and not is_struct(header) do
    fields = [:turn_id, :stream_domain_id, :base_event_sequence, :tool_call_id]

    map_size(header) <= 4 and Enum.count(fields, &Map.has_key?(header, &1)) == map_size(header) and
      bounded_fields?(header, fields)
  end

  defp header?(_header), do: false

  defp bounded_fields?(item, fields) do
    Enum.all?(fields, fn field ->
      case Map.fetch(item, field) do
        :error -> true
        {:ok, value} -> bounded_scalar?(value)
      end
    end)
  end

  defp bounded_scalar?(value) when is_binary(value), do: byte_size(value) <= 65_536
  defp bounded_scalar?(value) when is_integer(value), do: value in 0..@max_integer
  defp bounded_scalar?(value) when value in [nil, true, false], do: true

  defp bounded_scalar?(value) when value in [:text_delta, :reasoning_delta, :tool_call_delta],
    do: true

  defp bounded_scalar?(_value), do: false
end
