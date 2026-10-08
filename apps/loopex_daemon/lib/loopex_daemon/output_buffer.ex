defmodule LoopexDaemon.OutputBuffer do
  @moduledoc """
  ## Concept

  A daemon connection retains complete encoded records without letting a slow
  client make the connection process wait. Attachment delivery keeps a fixed
  part of the same bounded buffer available for the succession notice and one
  serial reply even when ordinary output has reached its allowance.

  ## Technical depth

  The connection registry owns this pure state. Frames remain charged until
  the socket owner acknowledges complete emission of the exact claimed frame.
  An attachment reservation lowers the ordinary allowance by the notice and
  reply capacities. Succession converts those unused capacities into actual
  bytes: the notice must be completely emitted before the single reply slot is
  used, and that slot becomes reusable only after its current reply is emitted.
  `commitment/1` counts retained encoded bytes plus the unused part of either
  reserved slot, so conversion never creates an aggregate-accounting gap.
  """

  @enforce_keys [:max_bytes]
  defstruct max_bytes: nil,
            frames: :queue.new(),
            bytes: 0,
            progress_items: 0,
            progress_bytes: 0,
            claim: nil,
            succession: :none

  @typedoc false
  @type frame_ref :: reference()

  @typedoc false
  @type succession ::
          :none
          | %{
              notice_bytes: pos_integer(),
              reply_bytes: pos_integer(),
              phase:
                :reserved
                | {:notice_pending, frame_ref(), pos_integer()}
                | :reply_ready
                | {:reply_pending, frame_ref(), pos_integer()}
            }

  @typedoc false
  @type t :: %__MODULE__{
          max_bytes: pos_integer(),
          frames: :queue.queue({frame_ref(), binary(), :ordinary | :progress | :notice | :reply}),
          bytes: non_neg_integer(),
          progress_items: non_neg_integer(),
          progress_bytes: non_neg_integer(),
          claim: frame_ref() | nil,
          succession: succession()
        }

  @doc false
  @spec new(pos_integer()) :: t()
  def new(max_bytes) when is_integer(max_bytes) and max_bytes > 0,
    do: %__MODULE__{max_bytes: max_bytes}

  @doc false
  @spec enqueue(t(), iodata()) :: {:ok, t()} | {:error, :capacity_exceeded | :succession_pending}
  def enqueue(%__MODULE__{} = buffer, encoded) do
    with {:ok, bytes} <- encoded_binary(encoded),
         :ok <- ordinary_admissible(buffer, byte_size(bytes)) do
      {:ok, push(buffer, bytes, :ordinary)}
    end
  end

  @doc """
  ## Concept

  Retain one credited transient frame in the same output FIFO as durable data.

  ## Technical depth

  Return its exact frame identity. Resident progress includes the claimed frame
  and stays within 32 items and 524,288 bytes; succession allowance remains
  reserved. Refusal never removes another frame or changes the buffer.
  """
  @spec enqueue_progress(t(), iodata()) :: {:ok, frame_ref(), t()} | {:error, atom()}
  def enqueue_progress(%__MODULE__{} = buffer, encoded) do
    with {:ok, bytes} <- encoded_binary(encoded),
         true <-
           buffer.progress_items < 32 and buffer.progress_bytes + byte_size(bytes) <= 524_288,
         :ok <- ordinary_admissible(buffer, byte_size(bytes)) do
      {frame_ref, buffer} = push_with_ref(buffer, bytes, :progress)
      {:ok, frame_ref, buffer}
    else
      false -> {:error, :capacity_exceeded}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  ## Concept

  Discard only explicitly named transient frames whose output has not started.

  ## Technical depth

  Exact unique references must all name resident progress frames. A claimed
  frame is still an active writer copy and refuses the whole discard. Durable
  frames, succession reservations and FIFO order are preserved. The caller
  separately fences late admission before treating this as release evidence.
  """
  @spec discard_progress(t(), [frame_ref()]) :: {:ok, t()} | {:error, atom()}
  def discard_progress(%__MODULE__{} = buffer, refs) when is_list(refs) and length(refs) <= 32 do
    requested = MapSet.new(refs)
    frames = :queue.to_list(buffer.frames)
    present = MapSet.new(for {ref, _bytes, :progress} <- frames, do: ref)

    cond do
      MapSet.size(requested) != length(refs) or not Enum.all?(refs, &is_reference/1) or
          not MapSet.subset?(requested, present) ->
        {:error, :frame_mismatch}

      MapSet.member?(requested, buffer.claim) ->
        {:error, :claimed}

      true ->
        {discarded, kept} =
          Enum.split_with(frames, fn {ref, _, _} -> MapSet.member?(requested, ref) end)

        bytes = Enum.reduce(discarded, 0, fn {_, bytes, _}, total -> total + byte_size(bytes) end)

        {:ok,
         %{
           buffer
           | frames: :queue.from_list(kept),
             bytes: buffer.bytes - bytes,
             progress_items: buffer.progress_items - length(discarded),
             progress_bytes: buffer.progress_bytes - bytes
         }}
    end
  end

  def discard_progress(%__MODULE__{}, _refs), do: {:error, :frame_mismatch}

  @doc false
  @spec reserve_succession(t(), pos_integer(), pos_integer()) ::
          {:ok, t()} | {:error, :already_reserved | :capacity_exceeded | :invalid_reserve}
  def reserve_succession(%__MODULE__{succession: :none} = buffer, notice_bytes, reply_bytes)
      when is_integer(notice_bytes) and notice_bytes > 0 and is_integer(reply_bytes) and
             reply_bytes > 0 do
    reserve_bytes = notice_bytes + reply_bytes

    if reserve_bytes < buffer.max_bytes and buffer.bytes <= buffer.max_bytes - reserve_bytes do
      {:ok,
       %{
         buffer
         | succession: %{
             notice_bytes: notice_bytes,
             reply_bytes: reply_bytes,
             phase: :reserved
           }
       }}
    else
      {:error, :capacity_exceeded}
    end
  end

  def reserve_succession(%__MODULE__{succession: :none}, _notice_bytes, _reply_bytes),
    do: {:error, :invalid_reserve}

  def reserve_succession(%__MODULE__{}, _notice_bytes, _reply_bytes),
    do: {:error, :already_reserved}

  @doc false
  @spec release_succession(t()) :: {:ok, t()} | {:error, :succession_pending | :not_reserved}
  def release_succession(%__MODULE__{succession: %{phase: :reserved}} = buffer),
    do: {:ok, %{buffer | succession: :none}}

  def release_succession(%__MODULE__{succession: :none}), do: {:error, :not_reserved}
  def release_succession(%__MODULE__{}), do: {:error, :succession_pending}

  @doc false
  @spec enqueue_succession_notice(t(), iodata()) ::
          {:ok, t()} | {:error, :capacity_exceeded | :notice_unavailable}
  def enqueue_succession_notice(
        %__MODULE__{succession: %{phase: :reserved, notice_bytes: allowance} = succession} =
          buffer,
        encoded
      ) do
    with {:ok, bytes} <- encoded_binary(encoded),
         size = byte_size(bytes),
         true <- size <= allowance and buffer.bytes + size <= buffer.max_bytes do
      {frame_ref, buffer} = push_with_ref(buffer, bytes, :notice)

      {:ok,
       %{
         buffer
         | succession: %{succession | phase: {:notice_pending, frame_ref, size}}
       }}
    else
      false -> {:error, :capacity_exceeded}
      {:error, _reason} -> {:error, :capacity_exceeded}
    end
  end

  def enqueue_succession_notice(%__MODULE__{}, _encoded),
    do: {:error, :notice_unavailable}

  @doc false
  @spec enqueue_succession_reply(t(), iodata(), keyword()) ::
          {:ok, t()} | {:error, :capacity_exceeded | :reply_unavailable}
  def enqueue_succession_reply(%__MODULE__{} = buffer, encoded, options \\ []) do
    without_notice = Keyword.get(options, :without_notice, false)

    case buffer.succession do
      %{phase: :reply_ready} = succession when not without_notice ->
        enqueue_reply(buffer, succession, encoded)

      %{phase: :reserved} = succession when without_notice ->
        enqueue_reply(buffer, succession, encoded)

      _other ->
        {:error, :reply_unavailable}
    end
  end

  @doc false
  @spec finish_succession(t()) :: {:ok, t()} | {:error, :succession_pending | :not_reserved}
  def finish_succession(%__MODULE__{succession: %{phase: :reply_ready}} = buffer),
    do: {:ok, %{buffer | succession: :none}}

  def finish_succession(%__MODULE__{succession: :none}), do: {:error, :not_reserved}
  def finish_succession(%__MODULE__{}), do: {:error, :succession_pending}

  @doc false
  @spec claim(t()) :: {:ok, frame_ref(), binary(), t()} | {:empty, t()} | {:error, :claimed}
  def claim(%__MODULE__{claim: nil} = buffer) do
    case :queue.peek(buffer.frames) do
      {:value, {frame_ref, bytes, _kind}} ->
        {:ok, frame_ref, bytes, %{buffer | claim: frame_ref}}

      :empty ->
        {:empty, buffer}
    end
  end

  def claim(%__MODULE__{}), do: {:error, :claimed}

  @doc false
  @spec emitted(t(), frame_ref()) :: {:ok, t()} | {:error, :claim_mismatch}
  def emitted(%__MODULE__{claim: frame_ref} = buffer, frame_ref) when is_reference(frame_ref) do
    case :queue.out(buffer.frames) do
      {{:value, {^frame_ref, bytes, kind}}, frames} ->
        buffer = %{
          buffer
          | frames: frames,
            bytes: buffer.bytes - byte_size(bytes),
            claim: nil
        }

        buffer =
          if kind == :progress,
            do: %{
              buffer
              | progress_items: buffer.progress_items - 1,
                progress_bytes: buffer.progress_bytes - byte_size(bytes)
            },
            else: buffer

        {:ok, advance_succession(buffer, kind, frame_ref)}

      _other ->
        {:error, :claim_mismatch}
    end
  end

  def emitted(%__MODULE__{}, _frame_ref), do: {:error, :claim_mismatch}

  @doc false
  @spec bytes(t()) :: non_neg_integer()
  def bytes(%__MODULE__{} = buffer), do: buffer.bytes

  @doc false
  @spec commitment(t()) :: non_neg_integer()
  def commitment(%__MODULE__{succession: :none} = buffer), do: buffer.bytes

  def commitment(%__MODULE__{succession: succession} = buffer) do
    unused =
      case succession.phase do
        :reserved ->
          succession.notice_bytes + succession.reply_bytes

        {:notice_pending, _frame_ref, size} ->
          succession.notice_bytes - size + succession.reply_bytes

        :reply_ready ->
          succession.reply_bytes

        {:reply_pending, _frame_ref, size} ->
          succession.reply_bytes - size
      end

    buffer.bytes + unused
  end

  @doc false
  @spec empty?(t()) :: boolean()
  def empty?(%__MODULE__{} = buffer), do: buffer.bytes == 0

  @doc false
  @spec succession?(t()) :: boolean()
  def succession?(%__MODULE__{succession: :none}), do: false
  def succession?(%__MODULE__{}), do: true

  defp ordinary_admissible(%__MODULE__{succession: :none} = buffer, size) do
    if buffer.bytes + size <= buffer.max_bytes,
      do: :ok,
      else: {:error, :capacity_exceeded}
  end

  defp ordinary_admissible(
         %__MODULE__{
           succession: %{phase: :reserved, notice_bytes: notice, reply_bytes: reply}
         } = buffer,
         size
       ) do
    if buffer.bytes + size <= buffer.max_bytes - notice - reply,
      do: :ok,
      else: {:error, :capacity_exceeded}
  end

  defp ordinary_admissible(%__MODULE__{}, _size), do: {:error, :succession_pending}

  defp enqueue_reply(buffer, succession, encoded) do
    with {:ok, bytes} <- encoded_binary(encoded),
         size = byte_size(bytes),
         true <- size <= succession.reply_bytes and buffer.bytes + size <= buffer.max_bytes do
      {frame_ref, buffer} = push_with_ref(buffer, bytes, :reply)

      {:ok,
       %{
         buffer
         | succession: %{succession | phase: {:reply_pending, frame_ref, size}}
       }}
    else
      false -> {:error, :capacity_exceeded}
      {:error, _reason} -> {:error, :capacity_exceeded}
    end
  end

  defp push(buffer, bytes, kind) do
    {_frame_ref, buffer} = push_with_ref(buffer, bytes, kind)
    buffer
  end

  defp push_with_ref(buffer, bytes, kind) do
    frame_ref = make_ref()
    frames = :queue.in({frame_ref, bytes, kind}, buffer.frames)
    buffer = %{buffer | frames: frames, bytes: buffer.bytes + byte_size(bytes)}

    buffer =
      if kind == :progress,
        do: %{
          buffer
          | progress_items: buffer.progress_items + 1,
            progress_bytes: buffer.progress_bytes + byte_size(bytes)
        },
        else: buffer

    {frame_ref, buffer}
  end

  defp advance_succession(
         %{succession: %{phase: {:notice_pending, frame_ref, _size}} = succession} = buffer,
         :notice,
         frame_ref
       ),
       do: %{buffer | succession: %{succession | phase: :reply_ready}}

  defp advance_succession(
         %{succession: %{phase: {:reply_pending, frame_ref, _size}} = succession} = buffer,
         :reply,
         frame_ref
       ),
       do: %{buffer | succession: %{succession | phase: :reply_ready}}

  defp advance_succession(buffer, _kind, _frame_ref), do: buffer

  defp encoded_binary(encoded) do
    try do
      bytes = IO.iodata_to_binary(encoded)

      if byte_size(bytes) > 0,
        do: {:ok, bytes},
        else: {:error, :capacity_exceeded}
    rescue
      ArgumentError -> {:error, :capacity_exceeded}
    end
  end
end
