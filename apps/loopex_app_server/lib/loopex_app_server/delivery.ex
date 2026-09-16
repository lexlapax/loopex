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

  Both dimensions are checked before a record is queued rather than after.
  Checking afterwards would mean the bound is whatever arrived plus one, which
  for a 4 MiB byte budget is not a bound at all.
  """

  alias LoopexProtocol.Frame
  alias LoopexProtocol.Wire

  @durable_records 64
  @durable_bytes 4_194_304
  @progress_records 32
  @progress_bytes 524_288

  @enforce_keys [:session_id]
  defstruct session_id: nil,
            durable: {[], 0, 0},
            progress: {[], 0, 0},
            cursor: 0,
            detached: false

  @type t :: %__MODULE__{}

  @doc """
  ## Concept

  A delivery queue for one attached session, starting at a cursor.

  ## Technical depth

  The queue starts at the cursor the caller supplies rather than at zero, so a
  reattaching client resumes where it stopped instead of replaying what it
  already holds. Both arguments are guarded, because a cursor arriving from the
  wire decides what a session is shown.
  """
  @spec new(binary(), non_neg_integer()) :: t()
  def new(session_id, cursor) when is_binary(session_id) and is_integer(cursor) do
    %__MODULE__{session_id: session_id, cursor: cursor}
  end

  @doc """
  ## Concept

  Offers one durable event for delivery.

  ## Technical depth

  The cursor advances only here, and only when the event is actually queued. An
  event that does not fit detaches the writer at the last cursor it completely
  emitted, so a client reattaching knows exactly where its view ends rather than
  guessing whether the last thing it saw was the last thing sent.
  """
  @spec event(t(), map()) :: t()
  def event(%__MODULE__{detached: true} = queue, _event), do: queue

  def event(%__MODULE__{} = queue, event) do
    record = event_record(queue.session_id, event)

    case offer(queue.durable, record, @durable_records, @durable_bytes) do
      {:ok, durable} ->
        %{queue | durable: durable, cursor: Map.get(event, :event_sequence, queue.cursor)}

      :full ->
        %{queue | detached: true}
    end
  end

  @doc """
  ## Concept

  Offers one transient progress item for delivery.

  ## Technical depth

  A progress item that does not fit is dropped, not a reason to detach. Progress
  is a rendering aid: a client that missed some has a less smooth picture, while
  a client detached over one would lose its durable stream for no reason.
  """
  @spec progress(t(), map()) :: t()
  def progress(%__MODULE__{detached: true} = queue, _item), do: queue

  def progress(%__MODULE__{} = queue, item) do
    record = progress_record(queue.session_id, item)

    case offer(queue.progress, record, @progress_records, @progress_bytes) do
      {:ok, progress} -> %{queue | progress: progress}
      :full -> queue
    end
  end

  @doc """
  ## Concept

  Takes everything queued, durable first.

  ## Technical depth

  Durable records go out ahead of progress so a client's history never trails
  the rendering of it. Within each plane the order is the order they arrived,
  which for durable events is the order they committed.
  """
  @spec take(t()) :: {[map()], t()}
  def take(%__MODULE__{} = queue) do
    {durable, _count, _bytes} = queue.durable
    {progress, _progress_count, _progress_bytes} = queue.progress

    records = Enum.reverse(durable) ++ Enum.reverse(progress)

    {records, %{queue | durable: {[], 0, 0}, progress: {[], 0, 0}}}
  end

  @doc """
  ## Concept

  Whether this writer was detached, and the cursor it reached.

  ## Technical depth

  Detachment is terminal: once it is true the writer emits its one uncorrelated
  error and delivery stops, so this is the flag to consult before offering
  anything further. The cursor it reached is read separately, through
  `cursor/1`.
  """
  @spec detached?(t()) :: boolean()
  def detached?(%__MODULE__{detached: detached}), do: detached

  @spec cursor(t()) :: non_neg_integer()
  def cursor(%__MODULE__{cursor: cursor}), do: cursor

  @doc """
  ## Concept

  The one uncorrelated error a detached writer emits before delivery stops.

  ## Technical depth

  It names the last completely emitted durable cursor, which is what a client
  reattaches at. Nothing after it is sent, because a client that received a
  later event after being told where its view ended would have a gap it could
  not see.
  """
  @spec detachment(t()) :: map()
  def detachment(%__MODULE__{} = queue) do
    %{
      "type" => "error",
      "code" => "detached",
      "message" => "delivery stopped because this writer could not keep up",
      "session_id" => Wire.encode_identity(queue.session_id),
      "event_cursor" => Wire.encode_u64(queue.cursor)
    }
  end

  # Concept: one record joins a plane, or the plane says it is full.
  #
  # Technical depth: both dimensions are measured on the encoded record, because
  # the byte budget is about what has to be written and not about how large the
  # structure looks in memory. A record that cannot be encoded at all counts as
  # not fitting, which is the same outcome for the same reason.
  defp offer({records, count, bytes}, record, max_records, max_bytes) do
    case Frame.encode(record) do
      {:ok, encoded} ->
        size = IO.iodata_length(encoded)

        if count + 1 > max_records or bytes + size > max_bytes,
          do: :full,
          else: {:ok, {[record | records], count + 1, bytes + size}}

      {:error, :output_record_too_large} ->
        :full
    end
  end

  # Concept: a durable event, with only the members its kind carries.
  #
  # Technical depth: the event's own identity and sequence move into the
  # envelope, and everything else stays in `data` exactly as the runtime
  # published it. This layer does not rename a member or add one: a client and a
  # facade reader must be looking at the same fact.
  defp event_record(session_id, event) do
    %{
      "type" => "event",
      "session_id" => Wire.encode_identity(session_id),
      "event" => %{
        "kind" => Map.fetch!(event, :kind),
        "event_id" => Wire.encode_identity(Map.fetch!(event, :event_id)),
        "event_sequence" => Wire.encode_u64(Map.fetch!(event, :event_sequence)),
        "data" => Map.drop(event, [:kind, :event_id, :event_sequence])
      }
    }
  end

  # Concept: one transient progress item, tied to its stream rather than to the
  # durable history.
  #
  # Technical depth: the domain identity is an equality label a client uses to
  # group deltas, never a capability over the attempt that produced them. The
  # base event sequence places the stream against durable history without
  # advancing it.
  defp progress_record(session_id, item) do
    %{
      "type" => "progress",
      "session_id" => Wire.encode_identity(session_id),
      "progress" =>
        item
        |> Map.drop([:stream_domain_id, :base_event_sequence])
        |> Map.merge(%{
          "stream_domain_id" => optional_identity(Map.get(item, :stream_domain_id)),
          "base_event_sequence" => optional_sequence(Map.get(item, :base_event_sequence))
        })
    }
  end

  defp optional_identity(nil), do: nil
  defp optional_identity(value) when is_binary(value), do: Wire.encode_identity(value)

  defp optional_sequence(nil), do: nil
  defp optional_sequence(value) when is_integer(value), do: Wire.encode_u64(value)
end
