defmodule Loopex.Journal do
  @moduledoc """
  ## Concept

  The append-only log a session's durable truth is reconstructed from. Nothing
  observable happens before the journal has it: an effect's intent is journaled
  before it is dispatched, and a fact is journaled before it is published. After
  a restart the journal — not any process's memory — is what the runtime
  believes.

  A journal is named by a filesystem path and nothing else. There is no handle and
  no registry, so the caller holds the reference explicitly and two runtimes in one
  VM cannot collide through a global name. There IS an owning process: a claimed
  journal is mutable only by the process that claimed it, and that process is the
  Coordinator. What this module avoids is a global name for it, not ownership.

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

  @typedoc """
  ## Concept

  Proof that the holder claimed this journal, and the only thing that authorises
  writing to it or truncating it.

  ## Technical depth

  Not a bearer value. Holding the token was once sufficient, and that is the defect
  this replaced: a token outlives the claim it came from, so stale-token appends
  landed after a new owner had taken over. The token is one of three identities a
  mutation must present -- the token, the OS process, and the Erlang process -- so
  a second process that copies it is still refused.

  It is nonetheless never written anywhere a second process could read it. The
  sentinel carries a SHA-256 digest instead, which identifies the owner to an
  operator without handing over what the owner holds. `nil` is accepted by the
  writing functions and always refused, so a caller that never claimed gets an
  error rather than a match.
  """
  @type claim :: binary()

  # Concept: recovery must survive a malformed write without unbounded allocation.
  #
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
  @spec append(Path.t(), entry(), claim()) :: :ok | {:error, term()}
  def append(path, record, token) when is_map(record) do
    with :ok <- validate(record),
         :ok <- require_active_claim(path, token),
         {:ok, frame} <- frame(record) do
      write(path, frame)
    end
  end

  # Concept: only the live holder of the active claim may change a journal.
  #
  # Technical depth: identity is checked three ways because each one alone has a
  # hole. The token proves knowledge, but a token outlives the claim it came from
  # -- stale-token appends landed after a new owner had taken over. The OS pid
  # proves the same VM, but two unnamed BEAMs are both `nonode@nohost`, so it is
  # what distinguishes them. The Erlang pid proves the same PROCESS, which is what
  # makes the Coordinator the ownership boundary rather than the file: a second
  # process in this VM holding a copied token is refused.
  #
  # There is no unclaimed mutation path. Writing to a journal nobody has claimed
  # used to be allowed "for tools and tests", and that was the hole every other
  # rule was layered on top of: an unclaimed write cannot be attributed, cannot be
  # fenced, and cannot be refused later.
  #
  # This does not make check-and-write atomic. A window remains between reading
  # the sentinel and writing, and closing it needs store-level owner-epoch
  # fencing, deferred to M1. What it does remove is every way a caller that is not
  # the live owning process reaches a mutation.
  defp require_active_claim(path, token) do
    with {:ok, lock} <- lock_path(path),
         {:ok, contents} <- read_claim(lock),
         {:ok, owner} <- parse_claim(contents, lock) do
      cond do
        # A claim exists -- read_claim/1 proved it -- so presenting nothing is not
        # "unclaimed", it is not being the owner. `:journal_unclaimed` is reserved
        # for a journal with no sentinel at all.
        not is_binary(token) ->
          {:error, {:not_the_session_owner, path}}

        not token_matches?(owner.token_digest, token) ->
          {:error, {:not_the_session_owner, path}}

        owner.os_pid != System.pid() ->
          {:error, {:not_the_session_owner, path}}

        owner.erl_pid != inspect(self()) ->
          {:error, {:not_the_session_owner, path}}

        true ->
          :ok
      end
    end
  end

  # A journal with no readable claim is not writable. Unavailable evidence of
  # ownership is refusal, not permission.
  defp read_claim(lock) do
    case File.read(lock) do
      {:ok, contents} -> {:ok, contents}
      {:error, :enoent} -> {:error, {:journal_unclaimed, lock}}
      {:error, posix} -> {:error, {:claim_unreadable, lock, posix}}
    end
  end

  defp parse_claim(contents, lock) do
    case parse_owner(contents) do
      {:ok, owner} -> {:ok, owner}
      :error -> {:error, {:claim_unreadable, lock, :malformed}}
    end
  end

  @doc """
  ## Concept

  Reads every intact record in order, and reports whether the journal ended
  cleanly.

  ## Technical depth

  A journal that does not exist yet reads as an empty complete journal, so a
  first start needs no separate creation step. Decoding stops at the first frame
  it cannot accept and reports the records before it, but WHICH tail is reported
  matters: a short frame is `{:torn, offset}`, an append that did not finish, and
  is safe to discard. A frame that is complete and fails its checksum, or that
  decodes to something other than a plain record map, is `{:corrupt, offset}` --
  bytes changed under a record that was acknowledged, and the records past it may
  be intact. Reporting the second as torn made repair delete durable truth to
  make startup succeed, so callers must distinguish them.

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
  everything it cannot prove is a torn append. Three refusals apply, and each
  exists because a review found data being destroyed without it:

  * A complete frame that fails its checksum is corruption, not a tear. A killed
    writer leaves a strict prefix of one frame; it cannot leave a whole frame with
    changed bytes, and records beyond such a frame may be perfectly intact.
  * A tail that reads as a strict prefix is still scanned for any frame that
    decodes and passes its checksum, because a corrupted length prefix can claim
    more bytes than remain while intact records sit past it.
  * The cut is refused if the file changed size since verification.

  ## What this proves, and what it does not

  M0 is a feasibility milestone and outcomes 4 through 6 are disposable
  experiments, so this states its boundary rather than implying durability
  guarantees it has not earned.

  Proved: on one machine, every append, repair, truncation and release is bound to
  the live owning process. Identity is checked three ways -- the claim token, the
  OS process, and the Erlang process -- so a caller that knows the token but is not
  the owning process is refused, a token that outlived its claim is refused, and a
  release holding a superseded token cannot delete the live claim. There is no
  unclaimed mutation path: a journal nobody holds cannot be written at all. That is
  what makes the Coordinator the ownership boundary rather than this file, which is
  why a later store can replace the claim without moving who owns session truth.

  Not proved, and not claimed:

  * Anything across hosts. The claim is a local file, so two machines sharing a
    journal over a network filesystem are outside every guarantee here.
  * Exclusion between processes that disagree about the temporary directory, since
    the claim lives there and its path is derived from that directory.
  * Exclusion against tampering. A process that edits or deletes the sentinel
    directly, rather than going through this module, defeats all of it.
  * Durability of the truncation across power loss. Records are synced; the
    truncation's length update is not separately synced, and no barrier or
    fsync-of-directory discipline is established.

  One residual race is known and deferred rather than hidden: reading the sentinel
  and performing the write are still separable, so a window remains in which
  ownership changes between the check and the mutation. Closing it needs
  store-level owner-epoch fencing, where a stale writer's records are refused at
  replay rather than prevented at write, and that belongs to M1 with the store
  port. Every path by which a caller that is not the live owning process reached a
  mutation is closed here.
  """
  @spec discard_torn_tail(Path.t(), non_neg_integer(), claim()) :: :ok | {:error, term()}
  def discard_torn_tail(path, offset, token) when is_integer(offset) and offset >= 0 do
    with :ok <- require_active_claim(path, token) do
      open_and_truncate(path, offset)
    end
  end

  # Concept: the destructive path is inside the capability, not beside it.
  #
  # Technical depth: this took no lock and checked no token, on the reasoning that
  # the coordinator holds the claim for its lifetime. That reasoning covered the
  # coordinator and nothing else: a review repaired -- and truncated -- a journal
  # while another process held its live claim. It now takes the same triple
  # identity as an append, and there is no unclaimed repair path: a journal with no
  # live claim cannot be truncated at all. The one operation that deletes
  # durable bytes was the one operation outside the mechanism built to protect
  # them. It now requires the same token as an append, so an unclaimed journal is
  # still repairable directly by a tool, and a claimed one only by its owner.
  defp open_and_truncate(path, offset) do
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
  end

  @doc """
  ## Concept

  Claims a journal for one session owner, for as long as that owner lives.

  ## Technical depth

  This replaces a lock held only around the repair. Held there, `append/2` could
  only *check* for a sentinel and then write, and a check is not exclusion: a
  repair could begin between the look and the write, and the append it then
  destroyed had already been acknowledged. Narrowing that window does not close
  it.

  Held for the owner's whole lifetime, the sentinel makes a second owner
  impossible rather than unlikely, and every write comes from the one process
  holding it. Within that process the coordinator is a GenServer, so its own
  appends and its recovery are already serialised. That is the product's "one
  serial session owner" invariant enforced by construction rather than restated.

  Creation is exclusive, so the claim is atomic at the filesystem and holds across
  processes and across VMs.
  """
  @spec claim_session(Path.t()) :: {:ok, claim()} | {:error, term()}
  def claim_session(path) do
    with :ok <- ensure_directory(path),
         :ok <- ensure_file(path),
         {:ok, lock} <- lock_path(path) do
      claim_lock(lock, token())
    end
  end

  # Concept: the claim is a capability, not a fact about a path.
  # Technical depth: ownership used to be "a sentinel exists", which anyone could
  # delete and anyone could work around. A token is held only by the claimer, so
  # releasing and writing require having claimed -- the two operations that must be
  # owner-only stop depending on inferring who the owner is. Sixteen random bytes,
  # because the token only has to be unguessable by accident, not by an attacker
  # with the file.
  defp token, do: :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)

  # Concept: the sentinel proves a token without carrying one.
  # Technical depth: the token was written into the sentinel, which is deliberately
  # readable so an operator can see who holds a journal. That published the bearer
  # value to every process running as the same user, and a review used it: read the
  # token, release the live owner, claim the journal. Randomness protects a secret,
  # not a secret that is printed.
  #
  # The digest goes in the file instead. A holder presents its token and the digest
  # of what it presents is compared; a reader of the file learns a value it cannot
  # present. The operator-facing fields -- node, OS process, time -- are unchanged,
  # so the recovery procedure still works.
  defp token_digest(token), do: :crypto.hash(:sha256, token) |> Base.encode16(case: :lower)

  # Constant-time comparison, so a caller cannot learn the digest by timing repeated
  # guesses. The cost is negligible and the alternative is a subtle dependency on
  # how the runtime compares binaries.
  defp token_matches?(digest, token) do
    :crypto.hash_equals(digest, token_digest(token))
  rescue
    _error -> digest == token_digest(token)
  end

  @doc """
  ## Concept

  Releases a session claim.

  ## Technical depth

  A failed release is returned rather than swallowed, because a sentinel that
  survives its owner blocks the next one with nothing explaining why.
  """
  @spec release_session(Path.t(), claim()) :: :ok | {:error, term()}
  def release_session(path, token) when is_binary(token) do
    # Releasing is a mutation and takes the same triple identity as writing.
    # Verifying only the token let a delayed release delete a LIVE claim: two
    # legitimate releases both read the old sentinel, the first removed it, a new
    # owner claimed, and the second deleted the new owner's file. Requiring the
    # OS and Erlang pid as well means the second release is looking at a sentinel
    # that is not its own and refuses.
    case lock_path(path) do
      {:error, {:journal_unavailable, _path, :enoent}} ->
        :ok

      {:error, reason} ->
        {:error, reason}

      {:ok, lock} ->
        case require_active_claim(path, token) do
          :ok -> remove_lock(lock)
          {:error, {:journal_unclaimed, _what}} -> :ok
          {:error, {:not_the_session_owner, _path}} -> {:error, {:not_the_claim_holder, lock}}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @doc """
  ## Concept

  Where a journal's session sentinel lives.

  ## Technical depth

  Public because an operator needs it. A sentinel left by a process killed while
  it held the journal blocks the next owner, deliberately: a human decides whether
  the previous owner is really gone, since expiry by age or pid can evict a live
  one. That trade is only acceptable if the file can be found and says who claimed
  it, so this returns the path and the sentinel records node, OS pid, and time.
  Removing it by hand is the recovery procedure.
  """
  @spec session_lock_path(Path.t()) :: {:ok, Path.t()} | {:error, term()}
  def session_lock_path(path), do: lock_path(path)

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

  defp claim_lock(lock, token) do
    case File.open(lock, [:write, :exclusive]) do
      {:ok, io} ->
        IO.write(io, owner_line(token))
        :file.sync(io)
        File.close(io)
        {:ok, token}

      {:error, :eexist} ->
        reclaim_if_owner_is_gone(lock, token)

      {:error, posix} ->
        {:error, {:journal_unavailable, lock, posix}}
    end
  end

  defp owner_line(token) do
    "node=#{node()} os_pid=#{System.pid()} erl_pid=#{inspect(self())} " <>
      "token_digest=#{token_digest(token)} at=#{System.system_time(:second)}\n"
  end

  # Concept: a claim may be taken over only when its owner is provably gone, and
  # the takeover itself must be exclusive.
  # Technical depth: two defects lived here. Deleting and recreating let two
  # contenders both see the same dead claim, and one then deleted the other's
  # newly created LIVE claim while both reported success -- a plain ABA. And an
  # Erlang pid was interpreted in the current VM, but two unnamed VMs are both
  # `nonode@nohost`, so a live owner in another VM was declared dead and evicted.
  #
  # Both are closed by narrowing what "provably gone" means and by serialising the
  # takeover. The owner must be on this node AND in this OS process before its
  # Erlang pid means anything here; anything else is unverifiable and refused. The
  # takeover runs under its own exclusively-created file, and re-reads the claim
  # under it, so a claim that changed between inspection and deletion aborts.
  defp reclaim_if_owner_is_gone(lock, token) do
    takeover = lock <> ".takeover"

    case File.open(takeover, [:write, :exclusive]) do
      {:error, :eexist} ->
        {:error, {:repair_already_held, lock, File.read(lock)}}

      {:error, posix} ->
        {:error, {:journal_unavailable, takeover, posix}}

      {:ok, io} ->
        File.close(io)

        try do
          take_over_dead_claim(lock, token)
        after
          File.rm(takeover)
        end
    end
  end

  defp take_over_dead_claim(lock, token) do
    with {:ok, before} <- File.read(lock),
         {:ok, owner} <- parse_owner(before),
         true <- verifiable_here?(owner),
         false <- pid_alive?(owner.erl_pid),
         {:ok, ^before} <- File.read(lock),
         :ok <- remove_lock(lock) do
      claim_lock(lock, token)
    else
      _other -> {:error, {:repair_already_held, lock, File.read(lock)}}
    end
  end

  defp ensure_file(path) do
    case File.exists?(path) do
      true ->
        :ok

      false ->
        case File.open(path, [:write, :append]) do
          {:ok, io} -> File.close(io)
          {:error, posix} -> {:error, {:journal_unavailable, path, posix}}
        end
    end
  end

  defp parse_owner(contents) do
    fields =
      contents
      |> String.trim()
      |> String.split()
      |> Map.new(fn pair ->
        case String.split(pair, "=", parts: 2) do
          [key, value] -> {key, value}
          _other -> {pair, ""}
        end
      end)

    case fields do
      %{"node" => n, "os_pid" => o, "erl_pid" => e, "token_digest" => d} ->
        {:ok, %{node: n, os_pid: o, erl_pid: e, token_digest: d}}

      _other ->
        :error
    end
  end

  defp pid_alive?(text) do
    case Regex.run(~r/\A#PID(<\d+\.\d+\.\d+>)\z/, text) do
      [_all, inner] ->
        try do
          Process.alive?(:erlang.list_to_pid(String.to_charlist(inner)))
        rescue
          _error -> true
        end

      nil ->
        true
    end
  end

  # An Erlang pid only means something in the VM that produced it. Node names do
  # not distinguish unnamed VMs -- both are nonode@nohost -- so the OS process is
  # what makes the pid interpretable here.
  defp verifiable_here?(owner) do
    owner.node == Atom.to_string(node()) and owner.os_pid == System.pid()
  end

  defp remove_lock(lock) do
    case File.rm(lock) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, posix} -> {:error, {:claim_not_released, lock, posix}}
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
  # sit beyond it, which `discard_torn_tail/3` checks before removing anything.
  defp decode(_short, offset, read), do: {:ok, Enum.reverse(read), {:torn, offset}}

  # Concept: a frame is intact only if its bytes and its shape both survive.
  #
  # Technical depth: a torn append can leave any bytes at all, so the checksum is
  # verified before the payload is decoded and the decode itself is guarded --
  # recovery must not crash on its own log. A complete frame that fails either
  # check is reported CORRUPT, not torn: its bytes changed under a record that was
  # acknowledged, and the records past it may be intact, so discarding from there
  # would destroy durable truth to make startup succeed. This comment previously
  # said such a frame was "treated as torn", which the clause below disproves and
  # which would have licensed exactly that repair.
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
