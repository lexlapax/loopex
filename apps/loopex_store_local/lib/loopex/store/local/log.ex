defmodule Loopex.Store.Local.Log do
  @moduledoc """
  ## Concept

  The durable local Store's append-only transaction log. One frame contains one
  complete terminal transaction resolution together with every mapping, private
  record, and outbox row that became visible at that linearization point.

  ## Technical depth

  Frames use a fixed magic/version prefix, a bounded 32-bit payload length, a
  SHA-256 checksum, and deterministic external-term bytes. An append syncs the
  file before returning. Recovery accepts only a complete checksummed prefix,
  repairs a strict torn final frame, and surfaces a complete malformed or
  checksum-invalid frame as corruption. Semantic replay is performed separately
  by `Loopex.Store.Local.State`, so a checksummed but illegal owner/version
  history is still refused. The log is a file, not a path: startup establishes
  that file and its identity, and an append that no longer finds it fails closed
  instead of creating a replacement whose only frame is the one in flight.
  Recovery explicitly loads the fixed modules that define envelope atoms before
  safe decoding; caller-controlled records and events cannot contribute durable
  atoms.
  """

  @magic "LXST\x02"
  @digest_bytes 32
  @header_bytes byte_size(@magic) + 4 + @digest_bytes * 2
  @max_frame_bytes 4 * 1_048_576
  @max_log_bytes 256 * 1_048_576
  @envelope_atom_modules [
    Loopex.Store,
    Loopex.Store.Transitions,
    Loopex.Store.Local.State
  ]

  @typep tail ::
           :complete
           | {:torn, non_neg_integer(), pos_integer(), <<_::256>>}
           | {:corrupt, non_neg_integer()}

  # Concept: which physical file this Store's appends belong to.
  #
  # Technical depth: the device and inode of the log established at startup. A
  # path is a name and names are re-bindable; the pair is the file itself, so an
  # unlinked-and-recreated log at the same path is a different log and is
  # refused rather than appended to.
  @typep identity :: {non_neg_integer(), non_neg_integer()}

  @doc false
  @spec prepare_path(Path.t()) :: {:ok, identity()} | {:error, term()}
  def prepare_path(path) when is_binary(path) do
    with :ok <- ensure_parent(path),
         :ok <- validate_store_file(path),
         :ok <- create_log(path),
         {:ok, stat} <- stat_log(path) do
      {:ok, identity(stat)}
    end
  end

  @doc false
  @spec sync_parent(Path.t()) :: :ok | {:error, term()}
  def sync_parent(path) when is_binary(path), do: sync_directory(Path.dirname(path))

  @doc """
  ## Concept

  Reads every complete transaction frame in durable order.

  ## Technical depth

  A missing file is an empty complete log. Safe external-term decoding prevents
  stored bytes from creating atoms during recovery. The fixed envelope modules
  are loaded first so a cold VM has every accepted schema atom; transition
  replay later validates the decoded map's exact schema and semantics.
  """
  @spec read(Path.t()) :: {:ok, [map()], tail()} | {:error, term()}
  def read(path) when is_binary(path) do
    with :ok <- load_envelope_atom_modules() do
      case File.stat(path) do
        {:ok, %File.Stat{type: :regular, size: size}} when size <= @max_log_bytes ->
          read_bounded(path, size)

        {:ok, %File.Stat{type: :regular, size: size}} ->
          {:error, {:store_log_too_large, size, @max_log_bytes}}

        {:ok, _stat} ->
          {:error, {:store_file_invalid, path}}

        {:error, :enoent} ->
          {:ok, [], :complete}

        {:error, reason} ->
          {:error, {:store_unavailable, path, reason}}
      end
    end
  end

  @doc false
  @spec sync_recovered(Path.t()) :: :ok | {:error, term()}
  def sync_recovered(path) when is_binary(path) do
    case :file.open(String.to_charlist(path), [:raw, :read, :write, :binary]) do
      {:ok, io} ->
        result = :file.sync(io)
        close_result = :file.close(io)

        case {result, close_result} do
          {:ok, :ok} -> sync_parent(path)
          {{:error, reason}, _close} -> {:error, {:store_recovery_sync_failed, reason}}
          {:ok, {:error, reason}} -> {:error, {:store_recovery_close_failed, reason}}
        end

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        {:error, {:store_recovery_open_failed, reason}}
    end
  end

  defp read_bounded(path, expected_size) do
    case :file.open(String.to_charlist(path), [:raw, :read, :binary]) do
      {:ok, io} ->
        read_result = :file.pread(io, 0, expected_size + 1)
        close_result = :file.close(io)

        case {read_result, close_result} do
          {{:ok, bytes}, :ok} when byte_size(bytes) == expected_size ->
            decode_bounded(bytes)

          {:eof, :ok} when expected_size == 0 ->
            decode_bounded(<<>>)

          {{:ok, _bytes}, :ok} ->
            {:error, :store_changed_during_read}

          {{:error, reason}, _close} ->
            {:error, {:store_unavailable, path, reason}}

          {_read, {:error, reason}} ->
            {:error, {:store_close_failed, reason}}

          {_other, :ok} ->
            {:error, :store_changed_during_read}
        end

      {:error, reason} ->
        {:error, {:store_unavailable, path, reason}}
    end
  end

  defp decode_bounded(bytes) do
    case decode(bytes, 0, []) do
      {:ok, frames, {:torn, offset}} ->
        {:ok, frames, {:torn, offset, byte_size(bytes), :crypto.hash(:sha256, bytes)}}

      result ->
        result
    end
  end

  @doc """
  ## Concept

  Appends one complete Store transaction and does not return before its bytes
  have been synced.

  ## Technical depth

  The caller adopts the corresponding in-memory state only after this returns
  `:ok`. A failure is commit-ambiguous and makes the Store process terminate so
  recovery re-reads the durable bytes rather than continuing from a speculative
  cache.

  An append writes to the exact log `Loopex.Store.Local.Log.prepare_path/1`
  established for this Store and never brings a log or its parent directory back
  into existence. A log removed or replaced underneath a live Store yields
  `{:error, {:log_unavailable, :enoent | :replaced}}`, which is commit-ambiguous
  like any other append failure.
  """
  @spec append(Path.t(), map(), identity()) :: :ok | {:error, term()}
  def append(path, frame, identity)
      when is_binary(path) and is_map(frame) and is_tuple(identity) do
    with {:ok, bytes} <- encode(frame),
         {:ok, stat} <- stat_log(path),
         :ok <- match_identity(stat, identity),
         :ok <- admit_size(stat.size, byte_size(bytes)),
         {:ok, io} <- open_append(path) do
      result =
        with :ok <- confirm_identity(path, identity),
             :ok <- :file.write(io, bytes),
             :ok <- :file.sync(io) do
          :ok
        end

      close_result = :file.close(io)

      case {result, close_result} do
        {:ok, :ok} -> sync_parent(path)
        {{:error, {:log_unavailable, _detail} = reason}, _close} -> {:error, reason}
        {{:error, reason}, _close} -> {:error, {:store_write_failed, reason}}
        {:ok, {:error, reason}} -> {:error, {:store_close_failed, reason}}
      end
    end
  end

  @doc """
  ## Concept

  Removes only a strict torn tail after recovery has identified the last intact
  transaction boundary.

  ## Technical depth

  The Store admits no new writer before this repair. The cut offset is checked
  against the current file size and synced; complete checksum or semantic
  corruption never reaches this path.
  """
  @spec repair_torn_tail(Path.t(), non_neg_integer(), pos_integer(), <<_::256>>) ::
          :ok | {:error, term()}
  def repair_torn_tail(path, offset, observed_size, observed_digest)
      when is_binary(path) and is_integer(offset) and offset >= 0 and
             is_integer(observed_size) and observed_size > 0 and
             is_binary(observed_digest) and byte_size(observed_digest) == @digest_bytes do
    with {:ok, stat} <- File.stat(path),
         true <- stat.size == observed_size and offset < observed_size,
         {:ok, io} <- :file.open(String.to_charlist(path), [:raw, :read, :write, :binary]) do
      result =
        with {:ok, current_bytes} <- :file.pread(io, 0, observed_size + 1),
             true <- byte_size(current_bytes) == observed_size,
             true <- :crypto.hash_equals(observed_digest, :crypto.hash(:sha256, current_bytes)),
             {:ok, ^offset} <- :file.position(io, offset),
             :ok <- :file.truncate(io),
             :ok <- :file.sync(io) do
          :ok
        end

      close_result = :file.close(io)

      case {result, close_result} do
        {:ok, :ok} -> sync_parent(path)
        {{:error, reason}, _close} -> {:error, {:store_repair_failed, reason}}
        {other, _close} when other != :ok -> {:error, {:store_repair_failed, other}}
        {:ok, {:error, reason}} -> {:error, {:store_repair_close_failed, reason}}
      end
    else
      false -> {:error, :store_changed_during_repair}
      {:error, reason} -> {:error, {:store_repair_failed, reason}}
      other -> {:error, {:store_repair_failed, other}}
    end
  end

  @doc false
  @spec encode(map()) :: {:ok, binary()} | {:error, term()}
  def encode(frame) when is_map(frame) do
    payload = :erlang.term_to_binary(frame, [:deterministic])

    if byte_size(payload) <= @max_frame_bytes do
      size = byte_size(payload)
      size_bytes = <<size::unsigned-big-32>>
      header_digest = :crypto.hash(:sha256, @magic <> size_bytes)
      payload_digest = :crypto.hash(:sha256, payload)

      {:ok,
       <<@magic, size_bytes::binary, header_digest::binary, payload_digest::binary,
         payload::binary>>}
    else
      {:error, :store_frame_too_large}
    end
  end

  defp decode(<<>>, _offset, frames), do: {:ok, Enum.reverse(frames), :complete}

  defp decode(bytes, offset, frames) when byte_size(bytes) < @header_bytes do
    tail = if possible_header_prefix?(bytes), do: {:torn, offset}, else: {:corrupt, offset}
    {:ok, Enum.reverse(frames), tail}
  end

  defp decode(
         <<@magic, size::unsigned-big-32, header_digest::binary-size(@digest_bytes),
           payload_digest::binary-size(@digest_bytes), rest::binary>>,
         offset,
         frames
       ) do
    size_bytes = <<size::unsigned-big-32>>

    cond do
      not :crypto.hash_equals(header_digest, :crypto.hash(:sha256, @magic <> size_bytes)) ->
        {:ok, Enum.reverse(frames), {:corrupt, offset}}

      size > @max_frame_bytes ->
        {:ok, Enum.reverse(frames), {:corrupt, offset}}

      byte_size(rest) < size ->
        {:ok, Enum.reverse(frames), {:torn, offset}}

      true ->
        <<payload::binary-size(^size), tail::binary>> = rest

        with true <- :crypto.hash_equals(payload_digest, :crypto.hash(:sha256, payload)),
             {:ok, frame} <- decode_payload(payload) do
          decode(tail, offset + @header_bytes + size, [frame | frames])
        else
          _other -> {:ok, Enum.reverse(frames), {:corrupt, offset}}
        end
    end
  end

  defp decode(_bytes, offset, frames), do: {:ok, Enum.reverse(frames), {:corrupt, offset}}

  defp possible_header_prefix?(bytes) when byte_size(bytes) < byte_size(@magic) do
    binary_part(@magic, 0, byte_size(bytes)) == bytes
  end

  defp possible_header_prefix?(
         <<@magic, size::unsigned-big-32, header_digest::binary-size(@digest_bytes),
           _partial_payload_digest::binary>>
       ) do
    size <= @max_frame_bytes and
      :crypto.hash_equals(
        header_digest,
        :crypto.hash(:sha256, @magic <> <<size::unsigned-big-32>>)
      )
  end

  defp possible_header_prefix?(<<@magic, _partial_header::binary>>), do: true
  defp possible_header_prefix?(_bytes), do: false

  defp decode_payload(payload) do
    case :erlang.binary_to_term(payload, [:safe]) do
      frame when is_map(frame) -> {:ok, frame}
      _other -> {:error, :invalid_frame}
    end
  rescue
    _error -> {:error, :invalid_frame}
  end

  defp load_envelope_atom_modules do
    Enum.reduce_while(@envelope_atom_modules, :ok, fn module, :ok ->
      case Code.ensure_loaded(module) do
        {:module, ^module} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:store_schema_unavailable, module, reason}}}
      end
    end)
  end

  defp ensure_parent(path), do: ensure_directory(Path.dirname(path))

  # Concept: the log file exists from the moment the Store opens, not from its
  # first commit.
  #
  # Technical depth: an append can then be a pure write to an established file,
  # which is what lets it refuse to create one. Exclusive creation never
  # truncates an existing log, and the parent sync makes the new directory entry
  # durable before recovery reads it.
  defp create_log(path) do
    case :file.open(String.to_charlist(path), [:raw, :write, :binary, :exclusive]) do
      {:ok, io} ->
        case :file.close(io) do
          :ok -> sync_parent(path)
          {:error, reason} -> {:error, {:store_close_failed, reason}}
        end

      {:error, :eexist} ->
        :ok

      {:error, reason} ->
        {:error, {:store_unavailable, path, reason}}
    end
  end

  defp identity(%File.Stat{major_device: device, inode: inode}), do: {device, inode}

  defp stat_log(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular} = stat} -> {:ok, stat}
      {:ok, _stat} -> {:error, {:store_file_invalid, path}}
      {:error, :enoent} -> {:error, {:log_unavailable, :enoent}}
      {:error, reason} -> {:error, {:store_unavailable, path, reason}}
    end
  end

  defp match_identity(stat, identity) do
    if identity(stat) == identity do
      :ok
    else
      {:error, {:log_unavailable, :replaced}}
    end
  end

  # Concept: the fence closes after the handle is open, not before.
  #
  # Technical depth: `:file.open/2` in append mode creates a missing file, so a
  # check that only ran before the open would leave a window in which a removal
  # is answered by a new, empty, history-free log -- the exact shape recovery
  # cannot distinguish from a legitimately fresh Store. Re-reading the path once
  # the handle is held makes detection unconditional: a removed log, or one
  # another writer recreated, no longer carries the established identity and no
  # frame is written. Where the removal raced this open, the recreated file is
  # left in place empty rather than unlinked, because the path no longer names
  # anything this Store is entitled to delete.
  defp confirm_identity(path, identity) do
    with {:ok, stat} <- stat_log(path) do
      match_identity(stat, identity)
    end
  end

  defp validate_store_file(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular, links: 1}} -> :ok
      {:ok, %File.Stat{type: :regular}} -> {:error, {:store_file_aliased, path}}
      {:ok, _stat} -> {:error, {:store_file_invalid, path}}
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, {:store_unavailable, path, reason}}
    end
  end

  defp ensure_directory(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :directory}} ->
        :ok

      {:ok, _stat} ->
        {:error, {:store_unavailable, path, :not_a_directory}}

      {:error, :enoent} ->
        parent = Path.dirname(path)

        with :ok <- ensure_directory(parent),
             :ok <- make_directory(path),
             :ok <- sync_directory(parent) do
          :ok
        end

      {:error, reason} ->
        {:error, {:store_unavailable, path, reason}}
    end
  end

  defp make_directory(path) do
    case File.mkdir(path) do
      :ok -> :ok
      {:error, :eexist} -> ensure_directory(path)
      {:error, reason} -> {:error, {:store_unavailable, path, reason}}
    end
  end

  defp open_append(path) do
    case :file.open(String.to_charlist(path), [:raw, :append, :binary]) do
      {:ok, io} -> {:ok, io}
      {:error, reason} -> {:error, {:store_unavailable, path, reason}}
    end
  end

  defp admit_size(size, append_bytes) do
    if size + append_bytes <= @max_log_bytes do
      :ok
    else
      {:error, {:store_capacity_exceeded, @max_log_bytes}}
    end
  end

  defp sync_directory(path) do
    directory = String.to_charlist(path)

    case :file.open(directory, [:raw, :read, :directory]) do
      {:ok, io} ->
        result = :file.sync(io)
        close_result = :file.close(io)

        case {result, close_result} do
          {:ok, :ok} -> :ok
          {{:error, reason}, _close} -> {:error, {:store_directory_sync_failed, reason}}
          {:ok, {:error, reason}} -> {:error, {:store_directory_close_failed, reason}}
        end

      {:error, reason} ->
        {:error, {:store_directory_unavailable, reason}}
    end
  end
end
