defmodule Loopex.Journal do
  @moduledoc """
  ## Concept

  The append-only log a session's durable truth is reconstructed from. Nothing
  observable happens before the journal has it: an effect's intent is journaled
  before it is dispatched, and a fact is journaled before it is published. After
  a restart the journal — not any process's memory — is what the runtime
  believes.

  A journal is named by a filesystem path and nothing else. There is no handle,
  no registry, and no owning process, so the caller holds the reference
  explicitly and two runtimes in one VM cannot collide through a global name.

  ## Technical depth

  M0 selects no durable store, so this is the smallest thing that carries the
  property under test: framed records appended to one file and fsynced before
  the call returns. It is deliberately not a store abstraction and no behaviour
  is declared for it, because only one implementation exists; when a real store
  is chosen it replaces this module rather than implementing it.

  Each record is written as `size::32, crc32::32, payload`, where `payload` is
  the record in the `:deterministic` external term format so equal records
  produce equal bytes. The length prefix alone cannot detect a torn write: a
  process killed mid-append can leave a plausible length followed by truncated
  bytes, so the checksum is what makes a torn tail recognisable. `read/1` stops
  at the first frame that is short or fails its checksum and reports the byte
  offset of the last good record. Skipping the bad frame and continuing would
  silently drop a record, which is the one recovery outcome worse than a short
  journal.

  Records are validated as plain boundary data before they are encoded, so a
  pid, port, reference, function, or struct is refused at the write instead of
  decoding after a restart into something that refers to nothing.
  """

  @typedoc """
  ## Concept

  One durable record. Always a map carrying a `:kind` that says how the reducer
  must interpret it.

  ## Technical depth

  Named `entry` because Erlang reserves the type name `record`; the prose calls
  these records throughout and the two words mean the same thing here.

  Every value in the map is plain boundary data as `plain_data?/1` defines it.
  The record is not a struct: a struct is an implementation type, and a durable
  record outlives the module that shaped it.
  """
  @type entry :: %{required(:kind) => atom(), optional(atom()) => term()}

  @typedoc """
  ## Concept

  Whether the journal ended on a record boundary, or was cut short.

  ## Technical depth

  `{:torn, offset}` carries the byte offset just past the last intact record,
  which is where a crashed append began. It is diagnostic: the records returned
  alongside it are the complete prefix and are safe to replay.
  """
  @type tail :: :complete | {:torn, non_neg_integer()} | {:corrupt, non_neg_integer()}

  # Technical depth: a durable record is bounded so one malformed write cannot
  # make recovery allocate without limit. Both ceilings are far above anything
  # this milestone's records need; they exist as a refusal, not as a tuning knob.
  @max_record_bytes 64 * 1024
  @max_depth 12
  @header_bytes 8

  @doc """
  ## Concept

  Appends one record and does not return until it is durable.

  ## Technical depth

  Validates before writing, so a record the reducer could never accept never
  reaches the file. The write is `:append` on a `:raw` handle followed by
  `:file.sync/1`, which is what makes "intent commits before dispatch" a real
  ordering rather than a hopeful one: the caller may only dispatch after this
  returns `:ok`.

  Creates the containing directory if it is missing, because a journal path is
  chosen by the caller and a missing parent is a setup detail rather than a
  durability failure. Every error is returned, never raised: recovery code
  distinguishes an unavailable journal from a rejected record.
  """
  @spec append(Path.t(), entry()) :: :ok | {:error, term()}
  def append(path, record) when is_map(record) do
    with :ok <- validate(record),
         :ok <- refuse_during_repair(path),
         {:ok, frame} <- frame(record) do
      write(path, frame)
    end
  end

  # Concept: an append during a repair is a record the repair is about to delete.
  # Technical depth: the repair verifies a tear and then truncates. An append that
  # lands between those two steps is synced, acknowledged, and then destroyed, and
  # the repair's own record-count check cannot see it because the surviving prefix
  # count is unchanged. Refusing here is what makes the sentinel mean something to
  # a writer; taking it only in the repair left `append/2` free to ignore it.
  #
  # A journal that does not exist yet cannot be under repair, so a missing file is
  # not an error here -- the first append creates it.
  defp refuse_during_repair(path) do
    case lock_path(path) do
      {:error, {:journal_unavailable, _path, :enoent}} ->
        :ok

      {:error, reason} ->
        {:error, reason}

      {:ok, lock} ->
        case File.exists?(lock) do
          false -> :ok
          true -> {:error, {:repair_in_progress, path, lock}}
        end
    end
  end

  @doc """
  ## Concept

  Reads every intact record in order, and reports whether the journal ended
  cleanly.

  ## Technical depth

  A journal that does not exist yet reads as an empty complete journal, so a
  first start needs no separate creation step. Decoding stops at the first frame
  that is short, fails its checksum, or does not decode to a plain record map,
  and reports `{:torn, offset}` with the records before it.

  Payloads decode with `:safe`, so a journal cannot introduce an atom the VM
  does not already have. That matters because the decoded record's `:kind`
  selects reducer behaviour.
  """
  @spec read(Path.t()) :: {:ok, [entry()], tail()} | {:error, term()}
  def read(path) do
    case File.read(path) do
      {:ok, bytes} -> decode(bytes, 0, [])
      {:error, :enoent} -> {:ok, [], :complete}
      {:error, posix} -> {:error, {:journal_unavailable, path, posix}}
    end
  end

  @doc """
  ## Concept

  Discards a torn tail, so the journal ends at its last intact record and the
  next append is reachable.

  ## Technical depth

  This exists because a torn tail is otherwise permanent. `append/2` writes at the
  end of the file and `read/1` stops decoding at the first bad frame, so every
  record written after a tear is unreachable forever. Recovery that replayed the
  intact prefix and then carried on would acknowledge and publish facts that
  vanish on the next restart — durable truth that is not durable.

  Only bytes at or after `offset` are removed, and `offset` must come from a
  `{:torn, offset}` tail, which `read/1` defines as just past the last intact
  record. Nothing acknowledged is therefore discarded: a torn frame was never a
  complete record, so no caller was ever told it committed.

  Truncation is the one destructive operation in this module, so it refuses
  everything it cannot prove is a torn append. Three separate refusals apply, and
  each exists because a review found data being destroyed without it:

  * A complete frame that fails its checksum is corruption, not a tear. A killed
    writer leaves a strict prefix of one frame; it cannot leave a whole frame with
    changed bytes, and records beyond such a frame may be perfectly intact.
  * A tail that reads as a strict prefix is still scanned for any frame that
    decodes and passes its checksum, because a corrupted length prefix can claim
    more bytes than remain while intact records sit past it.
  * Verification and truncation happen through one handle, under a sentinel created
    exclusively and named by the journal's device and inode, so every alias of one
    journal contends for one sentinel. `append/2` refuses while that sentinel
    exists, which is what makes it mean something to a writer rather than only to
    another repairer. The cut is additionally refused if the file changed size
    since verification.

  The exclusion covers writers that go through this module. A process writing to
  the journal by other means is outside it, and so is a `kill -9` between claiming
  the sentinel and recording who claimed it. `repair_lock_path/1` names the file so
  an operator can inspect and remove a stale one; that is the recovery procedure,
  and it is deliberately manual because expiry by age or pid can evict a live
  owner.
  """
  @spec discard_torn_tail(Path.t(), non_neg_integer()) :: :ok | {:error, term()}
  def discard_torn_tail(path, offset) when is_integer(offset) and offset >= 0 do
    # One handle for the whole operation. Re-reading the path and then separately
    # opening it to truncate left a window in which another writer could repair the
    # tear and append records that this truncation would then delete. Verifying and
    # cutting through the same descriptor closes that window for this process; the
    # one-serial-owner invariant is what excludes a second writer, and the
    # coordinator enforces it per journal.
    with :ok <- acquire_lock(path) do
      # Released even if something raises. Releasing only on the normal return
      # would strand the lock after any unexpected failure, and a stranded lock
      # fails every later repair closed -- turning a transient fault into a journal
      # that needs a human before it can recover again.
      try do
        case File.open(path, [:read, :write, :binary]) do
          {:error, posix} ->
            {:error, {:journal_unavailable, path, posix}}

          {:ok, io} ->
            try do
              verify_and_truncate(io, path, offset)
            after
              :file.close(io)
            end
        end
      after
        release_lock(path)
      end
    end
  end

  # Concept: only one writer may repair a journal, and the exclusion is real rather
  # than a narrow window.
  # Technical depth: verifying through one handle removes the gap between checking
  # and cutting *within* a process, but two coordinators could still interleave —
  # one verifies a tear, the other repairs and appends, the first truncates and
  # deletes the new records. Post-hoc record counting cannot detect that, because
  # the surviving prefix count is unchanged. A lock file created with `:exclusive`
  # is an atomic create-or-fail at the filesystem, so exclusion holds across
  # processes and across VMs, which a VM-global registry would not.
  #
  # A stale lock left by a killed process fails the next repair closed. That is the
  # correct direction for durable truth: a human decides whether the previous owner
  # is really gone, and the lock records who claimed it so they can tell.
  @doc """
  ## Concept

  Where the repair sentinel for a journal lives.

  ## Technical depth

  Public because an operator needs it. A stale sentinel — left by a process killed
  mid-repair — fails every later repair closed, deliberately: a human decides
  whether the previous owner is really gone, since automatic expiry by age or pid
  can evict a live one. That trade is only acceptable if the operator can find the
  file and see who claimed it, so this returns the path and the sentinel records
  node, OS pid, and claim time. Removing it by hand is the recovery procedure.

  The path is derived from the journal's device and inode, so every alias of one
  journal resolves to one sentinel.
  """
  @spec repair_lock_path(Path.t()) :: {:ok, Path.t()} | {:error, term()}
  def repair_lock_path(path), do: lock_path(path)

  defp acquire_lock(path) do
    with {:ok, lock} <- lock_path(path) do
      claim_lock(lock)
    end
  end

  # Concept: the lock names the FILE, not the spelling of its path.
  # Technical depth: deriving it as `path <> ".repair-lock"` made the identity
  # lexical, so two aliases of one journal -- a symlink, a bind mount, a relative
  # spelling -- produced two different locks and two repairers each believed they
  # held it exclusively. Device and inode identify the file itself, so every alias
  # of one journal contends for one sentinel. It lives in the temporary directory
  # rather than beside the journal because aliases can sit in different
  # directories, and a lock next to one of them would not be seen from the other.
  defp lock_path(path) do
    case File.stat(path) do
      {:ok, %File.Stat{major_device: device, inode: inode}} ->
        {:ok, Path.join(System.tmp_dir!(), "loopex-repair-#{device}-#{inode}.lock")}

      {:error, posix} ->
        {:error, {:journal_unavailable, path, posix}}
    end
  end

  defp claim_lock(lock) do
    case File.open(lock, [:write, :exclusive]) do
      {:ok, io} ->
        # Written and synced before the repair begins, so a process killed during
        # the repair still leaves a sentinel that says who to ask. A kill between
        # the create and this write can still leave an empty one; that is a smaller
        # window than leaving the whole claim implicit, not a closed one.
        IO.write(io, "node=#{node()} os_pid=#{System.pid()} at=#{System.system_time(:second)}\n")
        :file.sync(io)
        File.close(io)
        :ok

      {:error, :eexist} ->
        {:error, {:repair_already_held, lock, File.read(lock)}}

      {:error, posix} ->
        {:error, {:journal_unavailable, lock, posix}}
    end
  end

  # A failed release is reported, not swallowed. Silently returning success while
  # the sentinel survives leaves the next repair blocked with nothing explaining
  # why, which is the worst of both directions.
  defp release_lock(path) do
    with {:ok, lock} <- lock_path(path) do
      case File.rm(lock) do
        :ok -> :ok
        {:error, :enoent} -> :ok
        {:error, posix} -> {:error, {:repair_lock_not_released, lock, posix}}
      end
    end
  end

  defp verify_and_truncate(io, path, offset) do
    with {:ok, bytes} <- read_all(io, path),
         {:ok, records} <- expect_torn_at(bytes, path, offset),
         :ok <- refuse_intact_tail(bytes, path, offset),
         :ok <- truncate_to(io, path, offset, byte_size(bytes)) do
      confirm_prefix(io, path, records)
    end
  end

  defp read_all(io, path) do
    with {:ok, _position} <- :file.position(io, 0) do
      case IO.binread(io, :eof) do
        :eof -> {:ok, <<>>}
        {:error, posix} -> {:error, {:journal_unavailable, path, posix}}
        bytes when is_binary(bytes) -> {:ok, bytes}
      end
    else
      {:error, posix} -> {:error, {:journal_unavailable, path, posix}}
    end
  end

  # The tail must be exactly the tear this offset describes, read through the same
  # handle that will cut it — not through a separate read that may since have gone
  # stale.
  defp expect_torn_at(bytes, path, offset) do
    case decode(bytes, 0, []) do
      {:ok, records, {:torn, ^offset}} ->
        {:ok, records}

      {:ok, _records, :complete} ->
        {:error, {:not_torn, path}}

      {:ok, _records, {:corrupt, at}} ->
        {:error, {:corrupt_not_torn, path, at}}

      {:ok, _records, other} ->
        {:error, {:torn_offset_moved, path, other, offset}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Concept: never delete an intact record.
  # Technical depth: a corrupted length prefix can claim more bytes than remain, so
  # the tail reads as a strict prefix while whole, checksum-valid records sit beyond
  # it. Truncating then destroys acknowledged durable truth, which is exactly the
  # defect this guard exists for. Every byte position in the tail is tried, and any
  # frame that decodes and passes its checksum makes this corruption rather than a
  # torn append — corruption is refused and left for an operator.
  defp refuse_intact_tail(bytes, path, offset) do
    tail = binary_part(bytes, offset, byte_size(bytes) - offset)

    case scan_for_intact(tail) do
      false -> :ok
      true -> {:error, {:intact_record_beyond_tear, path, offset}}
    end
  end

  defp scan_for_intact(<<>>), do: false

  defp scan_for_intact(<<size::unsigned-big-32, crc::unsigned-big-32, rest::binary>> = candidate)
       when byte_size(rest) >= size do
    <<payload::binary-size(^size), _remaining::binary>> = rest

    case intact(payload, crc) do
      {:ok, _record} -> true
      :error -> scan_next(candidate)
    end
  end

  defp scan_for_intact(candidate), do: scan_next(candidate)

  defp scan_next(<<_skipped, rest::binary>>), do: scan_for_intact(rest)
  defp scan_next(<<>>), do: false

  # Concept: cut only if the file is still exactly what was verified.
  # Technical depth: the sentinel excludes a cooperating writer, and this excludes
  # the rest. Between verification and the cut the file must not have changed size
  # at all -- if it has, something appended and truncating would delete it. The
  # window is now a size comparison rather than a whole second read, but a
  # difference is refused rather than repaired.
  defp truncate_to(io, path, offset, verified_size) do
    with {:ok, current} <- :file.position(io, :eof) do
      cond do
        current != verified_size ->
          {:error, {:journal_grew_during_repair, path, verified_size, current}}

        true ->
          with {:ok, _position} <- :file.position(io, offset),
               :ok <- :file.truncate(io) do
            :ok
          else
            {:error, posix} -> {:error, {:journal_unavailable, path, posix}}
          end
      end
    else
      {:error, posix} -> {:error, {:journal_unavailable, path, posix}}
    end
  end

  # The prefix must survive exactly, compared through the same handle.
  defp confirm_prefix(io, path, expected) do
    with {:ok, bytes} <- read_all(io, path) do
      case decode(bytes, 0, []) do
        {:ok, ^expected, :complete} -> :ok
        {:ok, _records, :complete} -> {:error, {:truncation_changed_prefix, path}}
        {:ok, _records, tail} -> {:error, {:still_torn_after_truncation, path, tail}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc """
  ## Concept

  Whether a term may appear inside a durable record.

  ## Technical depth

  Permits integers, floats, atoms, binaries, and lists, tuples, and maps of
  permitted terms, to a bounded depth. Refuses pids, ports, references,
  functions, non-byte-aligned bitstrings, and structs. The first four decode
  after a restart into a value that no longer designates anything; a struct is
  an implementation type whose shape may change while the record on disk does
  not.
  """
  @spec plain_data?(term()) :: boolean()
  def plain_data?(term), do: plain?(term, 0)

  defp plain?(_term, depth) when depth > @max_depth, do: false
  defp plain?(term, _depth) when is_integer(term) or is_float(term), do: true
  defp plain?(term, _depth) when is_atom(term), do: true
  defp plain?(term, _depth) when is_binary(term), do: true
  defp plain?(term, depth) when is_list(term), do: Enum.all?(term, &plain?(&1, depth + 1))

  defp plain?(term, depth) when is_tuple(term) do
    term |> Tuple.to_list() |> Enum.all?(&plain?(&1, depth + 1))
  end

  defp plain?(%{__struct__: _shape}, _depth), do: false

  defp plain?(term, depth) when is_map(term) do
    Enum.all?(term, fn {key, value} ->
      plain?(key, depth + 1) and plain?(value, depth + 1)
    end)
  end

  defp plain?(_term, _depth), do: false

  defp validate(record) do
    cond do
      not is_map_key(record, :kind) -> {:error, {:invalid_record, :missing_kind}}
      not is_atom(Map.fetch!(record, :kind)) -> {:error, {:invalid_record, :kind_not_an_atom}}
      not plain_data?(record) -> {:error, {:invalid_record, :not_plain_data}}
      true -> :ok
    end
  end

  defp frame(record) do
    payload = :erlang.term_to_binary(record, [:deterministic])
    size = byte_size(payload)

    case size > @max_record_bytes do
      true ->
        {:error, {:invalid_record, {:too_large, size, @max_record_bytes}}}

      false ->
        {:ok, <<size::unsigned-big-32, :erlang.crc32(payload)::unsigned-big-32, payload::binary>>}
    end
  end

  defp write(path, frame) do
    with :ok <- ensure_directory(path),
         {:ok, io} <- open(path) do
      result =
        case :file.write(io, frame) do
          :ok -> :file.sync(io)
          other -> other
        end

      :file.close(io)
      posix(result, path)
    end
  end

  defp open(path) do
    case :file.open(String.to_charlist(path), [:append, :binary, :raw]) do
      {:ok, io} -> {:ok, io}
      {:error, posix} -> {:error, {:journal_unavailable, path, posix}}
    end
  end

  defp ensure_directory(path) do
    directory = Path.dirname(path)

    case File.mkdir_p(directory) do
      :ok -> :ok
      {:error, posix} -> {:error, {:journal_unavailable, directory, posix}}
    end
  end

  defp posix(:ok, _path), do: :ok
  defp posix({:error, posix}, path), do: {:error, {:journal_unavailable, path, posix}}

  defp decode(<<>>, _offset, read), do: {:ok, Enum.reverse(read), :complete}

  defp decode(<<size::unsigned-big-32, crc::unsigned-big-32, rest::binary>>, offset, read)
       when byte_size(rest) >= size do
    <<payload::binary-size(^size), remaining::binary>> = rest

    case intact(payload, crc) do
      {:ok, record} ->
        decode(remaining, offset + @header_bytes + size, [record | read])

      # A COMPLETE frame that fails its checksum is corruption, not a torn append.
      # A torn append leaves a strict prefix of one frame; it cannot leave a whole
      # frame with bad bytes inside it. The distinction decides whether the tail
      # may be discarded, so it is made here rather than by the caller guessing.
      :error ->
        {:ok, Enum.reverse(read), {:corrupt, offset}}
    end
  end

  # Fewer bytes remain than the frame claims, so the tail is a strict prefix. That
  # is the shape a killed writer leaves. It is still only provisionally torn: a
  # corrupted length prefix can claim more bytes than exist while intact records
  # sit beyond it, which `discard_torn_tail/2` checks before removing anything.
  defp decode(_short, offset, read), do: {:ok, Enum.reverse(read), {:torn, offset}}

  # Technical depth: a torn append can leave any bytes at all, so the checksum is
  # verified before the payload is decoded and the decode itself is guarded. A
  # frame that decodes to something other than a plain record map is treated as
  # torn rather than raised on, because recovery must not crash on its own log.
  defp intact(payload, crc) do
    case :erlang.crc32(payload) == crc do
      false -> :error
      true -> decode_payload(payload)
    end
  end

  defp decode_payload(payload) do
    record = :erlang.binary_to_term(payload, [:safe])

    case is_map(record) and is_map_key(record, :kind) and plain_data?(record) do
      true -> {:ok, record}
      false -> :error
    end
  rescue
    ArgumentError -> :error
  end
end
