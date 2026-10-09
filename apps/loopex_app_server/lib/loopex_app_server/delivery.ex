defmodule Loopex.AppServer.Delivery do
  @moduledoc """
  ## Concept

  What a client receives without asking: durable events, which advance its
  cursor, and transient progress, which never does. Both are bounded, and a
  writer that cannot keep up is detached rather than allowed to hold the
  runtime.

  ## Technical depth

  Accepted ADR 0023 keeps the two planes apart and bounds them separately, and
  the reason is the whole point of the separation: a durable event is history a
  client can replay from its cursor, and losing one silently would leave that
  client's view wrong forever, while progress is a rendering aid whose loss
  costs nothing but smoothness. So the queues have different sizes, and only one
  of them advances a cursor.

  Durable reservations, queued entries and the active frame share one finite
  budget. Accepted ADR 0058 retains their charges until the exact writer joins;
  selecting an entry neither frees capacity nor advances its emitted cursor.
  """

  alias LoopexProtocol.Frame
  alias LoopexProtocol.Wire

  @ordinary_progress_fields %{
    text_delta: [
      :kind,
      :turn_id,
      :stream_domain_id,
      :model_sequence,
      :base_event_sequence,
      :content_index,
      :text
    ],
    reasoning_delta: [
      :kind,
      :turn_id,
      :stream_domain_id,
      :model_sequence,
      :base_event_sequence,
      :content_index,
      :text
    ],
    tool_call_delta: [
      :kind,
      :turn_id,
      :stream_domain_id,
      :model_sequence,
      :base_event_sequence,
      :call_index,
      :tool_call_id,
      :name,
      :arguments_fragment
    ],
    tool_progress: [
      :kind,
      :turn_id,
      :stream_domain_id,
      :tool_call_id,
      :progress_sequence,
      :base_event_sequence,
      :stream,
      :byte_offset,
      :chunk
    ],
    model_stream_closed: [
      :kind,
      :turn_id,
      :stream_domain_id,
      :base_event_sequence,
      :disposition,
      :delta_count
    ],
    tool_stream_closed: [
      :kind,
      :turn_id,
      :stream_domain_id,
      :tool_call_id,
      :base_event_sequence,
      :disposition,
      :progress_count
    ]
  }

  @quantity_progress_fields [
    :model_sequence,
    :progress_sequence,
    :base_event_sequence,
    :byte_offset,
    :delta_count,
    :progress_count
  ]

  @durable_records 64
  @durable_bytes 4_194_304
  @progress_records 32
  @progress_bytes 524_288

  defstruct session_id: nil,
            incarnation: nil,
            baseline_joined: true,
            entries: [],
            active: nil,
            durable: {0, 0},
            progress: {0, 0},
            cursor: 0,
            pulled_cursor: 0,
            detached: false

  @type t :: %__MODULE__{}

  @doc """
  ## Concept

  One connection's output custody, optionally anchored to an attached session.

  ## Technical depth

  The supplied cursor is an already emitted baseline. Queued and active entries
  retain their counts and encoded bytes until matching physical completion.
  """
  @spec new(binary() | nil, non_neg_integer()) :: t()
  def new(session_id, cursor)
      when (is_binary(session_id) or is_nil(session_id)) and
             is_integer(cursor) and cursor >= 0 do
    %__MODULE__{session_id: session_id, incarnation: nil, cursor: cursor, pulled_cursor: cursor}
  end

  # Concept: a facade may run only after its maximum reply already fits.
  # Technical depth: a placeholder occupies its FIFO position and the unchanged
  # 2 MiB output ceiling. Encoding can shrink that reservation, never enlarge it.
  @doc false
  def reserve(%__MODULE__{detached: false} = queue) do
    {count, bytes} = queue.durable
    size = Frame.output_record_bytes()

    if count < @durable_records and bytes + size <= @durable_bytes do
      token = make_ref()

      entry = %{
        token: token,
        plane: :durable,
        bytes: size,
        frame: nil,
        incarnation: queue.incarnation,
        sequence: nil,
        baseline: nil,
        lease: nil
      }

      {:ok, token,
       %{
         queue
         | entries: insert_durable(queue.entries, entry),
           durable: {count + 1, bytes + size}
       }}
    else
      :full
    end
  end

  def reserve(_queue), do: :full

  @doc false
  def encode(record) do
    case Frame.encode(record) do
      {:ok, iodata} -> {:ok, IO.iodata_to_binary(iodata)}
      {:error, :output_record_too_large} -> {:error, :output_record_too_large}
    end
  end

  @doc false
  def commit(queue, token, record, metadata \\ %{}) do
    with {:ok, frame} <- encode(record) do
      commit_frame(queue, token, frame, metadata)
    end
  end

  @doc false
  def commit_frame(queue, token, frame, metadata \\ %{}) when is_binary(frame) do
    case Enum.find(queue.entries, &(&1.token == token and is_nil(&1.frame))) do
      nil ->
        {:error, :stale_reservation, queue}

      entry ->
        size = byte_size(frame)

        if size <= entry.bytes and size > 0 and :binary.last(frame) == ?\n do
          entry = %{
            entry
            | frame: frame,
              bytes: size,
              incarnation: Map.get(metadata, :incarnation, entry.incarnation),
              sequence: Map.get(metadata, :sequence),
              baseline: Map.get(metadata, :baseline)
          }

          {count, bytes} = queue.durable

          entries =
            Enum.map(queue.entries, fn old -> if old.token == token, do: entry, else: old end)

          {:ok,
           %{
             queue
             | entries: entries,
               durable: {count, bytes - Frame.output_record_bytes() + size}
           }}
        else
          {:error, :output_record_too_large, queue}
        end
    end
  end

  @doc false
  def cancel(queue, token) do
    case Enum.split_with(queue.entries, &(&1.token != token)) do
      {kept, [entry]} -> subtract(%{queue | entries: kept}, entry)
      _other -> queue
    end
  end

  @doc """
  ## Concept

  Offers one committed event without claiming it has reached the client.

  ## Technical depth

  Reserve before building its envelope. Only the pulled position moves here;
  the emitted cursor changes on the exact joined completion.
  """
  @spec event(t(), map()) :: t()
  def event(%__MODULE__{detached: true} = queue, _event), do: queue

  def event(queue, event) do
    case reserve(queue) do
      {:ok, token, reserved} ->
        with {:ok, record} <- event_record(queue.session_id, event),
             {:ok, committed} <-
               commit(reserved, token, record, %{sequence: event.event_sequence}) do
          %{committed | pulled_cursor: event.event_sequence}
        else
          :error -> %{cancel(reserved, token) | detached: true}
          {:error, _reason, failed} -> %{cancel(failed, token) | detached: true}
        end

      :full ->
        %{queue | detached: true}
    end
  end

  @doc """
  ## Concept

  Queues one validated transient projection without moving durable history.

  ## Technical depth

  Pure projection callers own their input. A foreground consumer additionally
  keeps its native lease on the entry through discard or joined output.
  """
  @spec progress(t(), map()) :: t()
  def progress(queue, item), do: progress(queue, item, nil)

  @doc false
  def progress(%__MODULE__{detached: true} = queue, _item, _lease), do: queue

  def progress(queue, item, lease) do
    case progress_record(queue.session_id, item) do
      :error ->
        queue

      record ->
        {count, bytes} = queue.progress
        size = progress_frame_bytes(record)

        if count < @progress_records and bytes + size <= @progress_bytes do
          case encode(record) do
            {:ok, frame} when byte_size(frame) == size ->
              entry = %{
                token: make_ref(),
                plane: :progress,
                bytes: size,
                frame: frame,
                incarnation: queue.incarnation,
                sequence: nil,
                baseline: nil,
                lease: lease
              }

              %{queue | entries: queue.entries ++ [entry], progress: {count + 1, bytes + size}}

            _invalid ->
              queue
          end
        else
          queue
        end
    end
  end

  @doc false
  def next(%__MODULE__{active: nil, entries: [%{frame: frame} = entry | _]})
      when is_binary(frame),
      do: {:ok, entry}

  def next(_queue), do: :empty

  @doc false
  def activate(
        %__MODULE__{active: nil, entries: [%{token: token} = entry | rest]} = queue,
        token,
        writer_ref
      )
      when is_reference(writer_ref) do
    {:ok, %{queue | entries: rest, active: Map.put(entry, :writer_ref, writer_ref)}}
  end

  def activate(queue, _token, _writer_ref), do: {:error, :stale_entry, queue}

  # Concept: physical JOINED is the only emitted-cursor transition.
  # Technical depth: the writer reference and attachment incarnation must both
  # match. An old snapshot/event cannot establish a fresh attachment's cursor.
  @doc false
  def joined(%__MODULE__{active: %{writer_ref: reference} = entry} = queue, reference) do
    queue = subtract(%{queue | active: nil}, entry)

    queue =
      if entry.incarnation == queue.incarnation do
        cond do
          is_integer(entry.baseline) ->
            %{queue | cursor: entry.baseline, baseline_joined: true}

          is_integer(entry.sequence) ->
            %{queue | cursor: entry.sequence}

          true ->
            queue
        end
      else
        queue
      end

    {:ok, entry, queue}
  end

  def joined(queue, _reference), do: {:error, :stale_completion, queue}

  # Concept: this retirement follows physically proved failed-write cleanup.
  # Technical depth: an unproved writer keeps its active entry and charge while
  # the connection closes; it cannot use this transition to reclaim capacity.
  @doc false
  def failed(%__MODULE__{active: %{writer_ref: reference} = entry} = queue, reference) do
    {:ok, entry, %{subtract(%{queue | active: nil}, entry) | detached: true}}
  end

  def failed(queue, _reference), do: {:error, :stale_completion, queue}

  @doc false
  def discard_queued(queue) do
    entries = queue.entries
    retired = Enum.reduce(entries, %{queue | entries: []}, &subtract(&2, &1))
    {entries, retired}
  end

  @doc false
  def discard_progress(queue) do
    {retired, kept} = Enum.split_with(queue.entries, &(&1.plane == :progress))
    {retired, Enum.reduce(retired, %{queue | entries: kept}, &subtract(&2, &1))}
  end

  @doc false
  def attachment(queue, session_id, cursor, incarnation) do
    %{
      queue
      | session_id: session_id,
        incarnation: incarnation,
        cursor: 0,
        pulled_cursor: cursor,
        baseline_joined: false
    }
  end

  @doc false
  def empty?(queue), do: queue.entries == [] and is_nil(queue.active)
  @doc false
  def active?(queue), do: not is_nil(queue.active)
  @doc false
  def ready?(queue), do: queue.baseline_joined and not queue.detached
  @doc false
  def pulled_cursor(queue), do: queue.pulled_cursor
  @doc false
  def usage(queue), do: %{durable: queue.durable, progress: queue.progress}

  @spec detached?(t()) :: boolean()
  def detached?(queue), do: queue.detached
  @spec cursor(t()) :: non_neg_integer()
  def cursor(queue), do: queue.cursor

  @doc """
  ## Concept

  Describes the last physically joined durable position.

  ## Technical depth

  A writer failure closes output without writing this record into a possibly
  partial frame. A clean pre-write detachment can reserve it normally.
  """
  @spec detachment(t()) :: map()
  def detachment(queue) do
    %{
      "type" => "error",
      "code" => "detached",
      "message" => "delivery stopped because this writer could not keep up",
      "session_id" => Wire.encode_identity(queue.session_id),
      "event_cursor" => Wire.encode_u64(queue.cursor)
    }
  end

  # Concept: reserve the exact progress LF bytes before allocating JSON output.
  # Technical depth: this measures only the validated closed wire projection;
  # its nested owner contains the same primitive kinds. Frame remains the sole
  # encoder and the result must equal this byte count before queue admission.
  defp progress_frame_bytes(record), do: progress_json_bytes(record) + 1
  defp progress_json_bytes(value) when is_binary(value), do: progress_string_bytes(value, 2)

  defp progress_json_bytes(value) when is_integer(value),
    do: byte_size(Integer.to_string(value))

  defp progress_json_bytes(nil), do: 4

  defp progress_json_bytes(value) when is_map(value) do
    2 + max(map_size(value) - 1, 0) +
      Enum.reduce(value, 0, fn {key, member}, size ->
        size + progress_json_bytes(key) + 1 + progress_json_bytes(member)
      end)
  end

  defp progress_string_bytes(<<>>, size), do: size

  defp progress_string_bytes(<<byte, rest::binary>>, size) do
    extra =
      cond do
        byte in [?", ?\\, ?\n, ?\r, ?\t] -> 2
        byte < 32 -> 6
        true -> 1
      end

    progress_string_bytes(rest, size + extra)
  end

  defp insert_durable(entries, entry) do
    {durable, progress} = Enum.split_while(entries, &(&1.plane == :durable))
    durable ++ [entry] ++ progress
  end

  defp subtract(queue, %{plane: plane, bytes: size}) do
    {count, bytes} = Map.fetch!(queue, plane)
    Map.put(queue, plane, {count - 1, bytes - size})
  end

  # Concept: durable history crosses only its kind's complete public projection.
  # Technical depth: reject malformed envelopes and closed payloads before queue
  # admission. Codec failure cancels only this reservation; earlier entries and
  # active write credit remain owned until their exact physical completion.
  defp event_record(session_id, event) when is_map(event) and not is_struct(event) do
    with {:ok, session} <- event_identity(session_id, 256),
         {:ok, id} <- event_identity(Map.get(event, :event_id)),
         sequence
         when is_integer(sequence) and sequence >= 0 and
                sequence <= 18_446_744_073_709_551_615 <- Map.get(event, :event_sequence),
         kind when is_binary(kind) <- Map.get(event, :kind),
         {:ok, data} <- event_data(kind, Map.drop(event, [:kind, :event_id, :event_sequence])) do
      {:ok,
       %{
         "type" => "event",
         "session_id" => session,
         "event" => %{
           "kind" => kind,
           "event_id" => id,
           "event_sequence" => Wire.encode_u64(sequence),
           "data" => data
         }
       }}
    else
      _invalid -> :error
    end
  end

  defp event_record(_session_id, _event), do: :error

  defp event_data("session.configured", data),
    do: LoopexProtocol.Session.Configuration.encode_change(data)

  defp event_data("context.compacted", data),
    do: LoopexProtocol.Session.Checkpoint.encode_wire(data)

  defp event_data("context.maintenance_changed", data),
    do: LoopexProtocol.Session.MaintenanceView.encode_wire(data)

  defp event_data("context.compaction_finished", data),
    do: LoopexProtocol.Session.CompactResult.encode_completion(data)

  defp event_data(kind, data)
       when kind in ~w(interaction.requested interaction.answer_admitted interaction.resolved interaction.expired interaction.cancelled interaction.answered interaction.declined),
       do: LoopexProtocol.Session.InteractionEvent.encode(kind, data)

  defp event_data("user.message_appended", data),
    do: ordinary_event(data, ~w(command_id run_id content))

  defp event_data("assistant.message_appended", data),
    do: ordinary_event(data, ~w(run_id turn_id content))

  defp event_data("run.started", data), do: ordinary_event(data, ~w(command_id run_id))
  defp event_data("session.settled", data), do: ordinary_event(data, ~w(run_id))

  defp event_data("tool.started", data),
    do: ordinary_event(data, ~w(run_id turn_id tool_call_id operation_id tool_id tool_version))

  # Concept: a tool terminal crosses as the variant the session committed.
  # Technical depth: accepted ADR 0067 shares one closed receipt-backed /
  # operation-less payload codec between both transports; refusal is whole.
  defp event_data("tool.finished", data),
    do: LoopexProtocol.Session.ToolFinished.encode_wire(data)

  defp event_data("steer.resolved", data) do
    with true <- data["disposition"] in ~w(applied unapplied cancelled) do
      ordinary_event(data, ~w(command_id run_id disposition reason))
    else
      _invalid -> :error
    end
  end

  defp event_data("follow_up.resolved", data) do
    with "cancelled" <- data["disposition"], "aborted" <- data["reason"] do
      ordinary_event(data, ~w(command_id run_id disposition reason))
    else
      _invalid -> :error
    end
  end

  # Concept: run endings preserve their flat event contract and shared algebra.
  # Technical depth: adapt only the fixed outcome spellings to Outcome, whose
  # codec owns bound precision and context-failure validation. Null envelope
  # references stay explicit; failure and reason never both appear on the wire.
  defp event_data("run.finished", data) do
    base = ~w(run_id outcome reconciliation_ref cleanup_grace_ms command_id)

    outcome =
      Enum.find(
        [:completed, :cancelled, :failed, :bound_reached, :outcome_unknown],
        &(Atom.to_string(&1) == data["outcome"])
      )

    extra =
      case outcome do
        :bound_reached -> ~w(bound observed declared_limit accounting_source)
        :failed -> if Map.has_key?(data, "failure"), do: ["failure"], else: ["reason"]
        _ -> []
      end

    details = Map.take(data, ["cleanup_grace_ms" | extra])

    details =
      case outcome do
        :failed -> Map.merge(%{"reason" => nil, "failure" => nil}, details)
        :outcome_unknown -> Map.put(details, "reconciliation_ref", data["reconciliation_ref"])
        _ -> details
      end

    with true <- event_closed?(data, base ++ extra),
         {:ok, run} <- event_identity(data["run_id"]),
         {:ok, command} <- event_optional_identity(data["command_id"]),
         {:ok, ref} <- event_optional_identity(data["reconciliation_ref"]),
         {:ok, encoded} <-
           LoopexProtocol.Session.Outcome.encode_wire(%{outcome: outcome, details: details}) do
      payload = Map.merge(data, Map.take(encoded["details"], ["cleanup_grace_ms" | extra]))

      {:ok,
       Map.merge(payload, %{"run_id" => run, "command_id" => command, "reconciliation_ref" => ref})}
    else
      _invalid -> :error
    end
  end

  defp event_data(_kind, _data), do: :error

  defp ordinary_event(data, fields) do
    if event_closed?(data, fields) do
      Enum.reduce_while(fields, {:ok, %{}}, fn field, {:ok, payload} ->
        case event_member(field, data[field]) do
          {:ok, encoded} ->
            key = if field == "content", do: "content_b64", else: field
            {:cont, {:ok, Map.put(payload, key, encoded)}}

          :error ->
            {:halt, :error}
        end
      end)
    else
      :error
    end
  end

  defp event_member(field, value)
       when field in ~w(command_id run_id turn_id tool_call_id operation_id),
       do: event_identity(value)

  # Concept: conversation bytes fit the existing enclosing JSON string ceiling.
  # Technical depth: unpadded base64url maps 98,304 raw bytes to 131,072 wire
  # characters. Refuse a larger value before allocating its encoded projection.
  defp event_member("content", value) when is_binary(value) and byte_size(value) <= 98_304,
    do: {:ok, Wire.encode_bytes(value)}

  defp event_member("tool_id", value) when is_binary(value) and byte_size(value) in 1..128 do
    if Regex.match?(~r/\A[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)*\z/, value),
      do: {:ok, value},
      else: :error
  end

  defp event_member("tool_version", value)
       when is_binary(value) and byte_size(value) <= 131_072 do
    if Regex.match?(~r/\A[0-9]+\.[0-9]+\.[0-9]+\z/, value), do: {:ok, value}, else: :error
  end

  defp event_member("reason", nil), do: {:ok, nil}

  defp event_member("reason", value) do
    if is_binary(value) and byte_size(value) <= 131_072 and String.valid?(value),
      do: {:ok, value},
      else: :error
  end

  defp event_member("disposition", value), do: {:ok, value}

  defp event_member(_field, _value), do: :error

  defp event_identity(value, ceiling \\ 65_536)

  defp event_identity(value, ceiling) when is_binary(value) and byte_size(value) in 1..ceiling//1,
    do: {:ok, Wire.encode_identity(value)}

  defp event_identity(_value, _ceiling), do: :error
  defp event_optional_identity(nil), do: {:ok, nil}
  defp event_optional_identity(value), do: event_identity(value)

  defp event_closed?(data, fields),
    do: is_map(data) and not is_struct(data) and Enum.sort(Map.keys(data)) == Enum.sort(fields)

  # Concept: one transient progress item, tied to its stream rather than to the
  # durable history.
  #
  # Technical depth: the domain identity is an equality label a client uses to
  # group deltas, never a capability over the attempt that produced them. The
  # base event sequence places the stream against durable history without
  # advancing it.
  # Concept: maintenance activity crosses only its closed public projection.
  # Technical depth: malformed members drop before generic serialization; the
  # existing offer still applies the unchanged transient record and byte limits.
  defp progress_record(session_id, _item)
       when not is_binary(session_id) or byte_size(session_id) not in 1..256,
       do: :error

  defp progress_record(session_id, %{kind: "context.compaction_progress"} = item),
    do: compaction_progress_record(session_id, item)

  defp progress_record(session_id, %{"kind" => "context.compaction_progress"} = item),
    do: compaction_progress_record(session_id, item)

  defp progress_record(session_id, item), do: ordinary_progress_record(session_id, item)

  defp compaction_progress_record(session_id, item) do
    case LoopexProtocol.Session.CompactionProgress.encode_wire(item) do
      {:ok, progress} ->
        %{
          "type" => "progress",
          "session_id" => Wire.encode_identity(session_id),
          "progress" => progress
        }

      :error ->
        :error
    end
  end

  # Concept: ordinary progress carries exactly its kind's public fields.
  # Technical depth: ADR 0011 supplies native shapes and payload ceilings;
  # ADR 0023 encodes opaque identities, full-range quantities and raw chunks.
  # Refuse the whole item before a private or malformed value reaches a writer.
  defp ordinary_progress_record(session_id, item) do
    with true <- is_binary(session_id) and byte_size(session_id) in 1..256,
         {:ok, progress} <- ordinary_progress(item) do
      %{
        "type" => "progress",
        "session_id" => Wire.encode_identity(session_id),
        "progress" => progress
      }
    else
      _invalid -> :error
    end
  end

  defp ordinary_progress(item) when is_map(item) and not is_struct(item) do
    kind = Map.get(item, :kind)
    fields = if is_atom(kind), do: Map.get(@ordinary_progress_fields, kind), else: nil

    if is_atom(kind) and is_list(fields) and map_size(item) == length(fields) and
         Enum.all?(fields, &Map.has_key?(item, &1)) do
      encoded =
        Enum.reduce_while(item, {:ok, %{}}, fn {field, value}, {:ok, progress} ->
          case progress_member(kind, field, value) do
            {:ok, encoded} ->
              key = if field == :chunk, do: "chunk_b64", else: Atom.to_string(field)
              {:cont, {:ok, Map.put(progress, key, encoded)}}

            :error ->
              {:halt, :error}
          end
        end)

      if match?({:ok, _progress}, encoded) and model_payload_bounded?(item),
        do: encoded,
        else: :error
    else
      :error
    end
  end

  defp ordinary_progress(_item), do: :error

  defp progress_member(kind, :kind, kind), do: {:ok, Atom.to_string(kind)}

  defp progress_member(:tool_call_delta, :tool_call_id, nil), do: {:ok, nil}

  defp progress_member(_kind, field, value)
       when field in [:turn_id, :tool_call_id] and is_binary(value) and
              byte_size(value) in 1..65_536,
       do: {:ok, Wire.encode_identity(value)}

  defp progress_member(_kind, :stream_domain_id, value)
       when is_binary(value) and byte_size(value) == 32 do
    if Enum.all?(:binary.bin_to_list(value), &(&1 in ?0..?9 or &1 in ?a..?f)),
      do: {:ok, Wire.encode_identity(value)},
      else: :error
  end

  defp progress_member(_kind, field, value)
       when field in @quantity_progress_fields and
              is_integer(value) and value >= 0 and value <= 18_446_744_073_709_551_615,
       do: {:ok, Wire.encode_u64(value)}

  defp progress_member(_kind, field, value)
       when field in [:content_index, :call_index] and is_integer(value) and
              value >= 0 and value <= 9_007_199_254_740_991,
       do: {:ok, value}

  defp progress_member(:tool_call_delta, field, nil)
       when field in [:name, :arguments_fragment],
       do: {:ok, nil}

  defp progress_member(_kind, field, value)
       when field in [:text, :name, :arguments_fragment] and is_binary(value) and
              byte_size(value) <= 65_536 do
    if Loopex.ProgressPayload.terminal_safe?(value), do: {:ok, value}, else: :error
  end

  defp progress_member(:tool_progress, :stream, value)
       when value in ["stdout", "stderr", "progress"],
       do: {:ok, value}

  defp progress_member(:tool_progress, :chunk, value)
       when is_binary(value) and byte_size(value) <= 65_536 do
    if Loopex.ProgressPayload.terminal_safe?(value),
      do: {:ok, Wire.encode_bytes(value)},
      else: :error
  end

  defp progress_member(kind, :disposition, value)
       when kind in [:model_stream_closed, :tool_stream_closed] and
              value in [:complete, :abandoned],
       do: {:ok, Atom.to_string(value)}

  defp progress_member(_kind, _field, _value), do: :error

  defp model_payload_bounded?(%{kind: kind} = item)
       when kind in [:text_delta, :reasoning_delta, :tool_call_delta] do
    item
    |> Map.take([:content_index, :call_index, :text, :tool_call_id, :name, :arguments_fragment])
    |> Enum.reduce(0, fn {_field, value}, total ->
      total +
        if is_binary(value), do: byte_size(value), else: byte_size(:erlang.term_to_binary(value))
    end)
    |> Kernel.<=(65_536)
  end

  defp model_payload_bounded?(_item), do: true
end
