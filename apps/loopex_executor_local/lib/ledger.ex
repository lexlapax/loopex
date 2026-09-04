defmodule Loopex.Executor.Local.Ledger do
  @moduledoc """
  ## Concept

  The trusted receipt-ledger root: the local executor's private, durable
  authority over whether an effect was ever admitted.

  Two local executors sharing one prepared root share one generation, one
  admission marker per job, one open-authority index, and one refusal or receipt
  per job. That shared durable truth is what makes cancellation linearizable
  across instances and across restart: a deadline or cancellation that wins
  before the effect boundary publishes an exact refusal, and once admission wins,
  nothing may later claim that no effect began.

  ## Technical depth

  Every record is an exact-key canonical external term. Unknown keys, wrong
  relations, invalid encodings, symlinks, replacements, and records above their
  stated ceiling make the ledger *unavailable* rather than absent: absence is a
  positive claim that nothing happened, and none of those conditions supports it.
  The raw file size is checked against the record's ceiling before decoding and
  the canonical re-encoding is checked against the same ceiling afterwards, so a
  hostile file cannot be decoded merely because it re-encodes small.

  Root mutation is serialized by one exclusive administrative claim, taken as an
  atomic directory creation. Claims are never timed out or reaped: a stranded
  claim is bounded unavailability, because elapsed time is not proof that no
  late writer survives.

  This authority is private to the executor edge. It never enters Core Runtime,
  a job, a grant, a receipt, an event, a log, or a diagnostic.
  """

  @generation_kind "local_executor_generation_v1"
  @marker_kind "local_effect_admission_v1"
  @refusal_kind "local_pre_effect_refusal_v1"
  @open_kind "local_open_effect_v1"

  @generation_bytes 2_048
  @record_bytes 65_536
  @snapshot_bytes 4_194_304
  @max_open_entries 1_024
  @max_epoch 115_792_089_237_316_195_423_570_985_008_687_907_853_269_984_665_640_564_039_457_584_007_913_129_639_935
  @max_uint64 18_446_744_073_709_551_615
  @claim_poll_ms 5

  # Concept: each record kind has one closed key set, and an unknown key is a
  # record this ledger did not write.
  #
  # Technical depth: a mutated record that keeps every relation but gains a
  # member still re-encodes canonically and would otherwise validate. The key set
  # is therefore checked directly, so "the fields I know about are right" can
  # never stand in for "these are the fields".
  @kind_keys %{
    @generation_kind => [
      :ledger_kind,
      "executor_epoch",
      "executor_identity",
      "generation_id",
      "root_binding"
    ],
    @marker_kind => [
      :ledger_kind,
      "admission_nonce",
      "attempt",
      "canonical_request_digest",
      "cleanup_grace_ms",
      "job_id",
      "operation_id"
    ],
    @refusal_kind => [
      :ledger_kind,
      "attempt",
      "canonical_request_digest",
      "job_id",
      "operation_id",
      "reason"
    ],
    @open_kind => [
      :ledger_kind,
      "canonical_request_digest",
      "cleanup_grace_ms",
      "executor_identity",
      "job_id",
      "origin_executor_epoch"
    ]
  }

  @refusal_codes ~w(
    cancelled_before_start
    workspace_lease_not_held
    workspace_lease_lost
    workspace_lease_mismatch
    executor_prestart_mismatch
    invalid_job_request
    canonical_job_request_mismatch
    tool_definition_mismatch
    host_policy_allow_required
    invalid_grant
    invalid_tool_arguments
    receipt_record_shape_too_large
    effective_deadline_reached
    effect_start_authority_unavailable
    missing_binding
    binding_mismatch
  )

  @typedoc """
  ## Concept

  The private prepared authority over one ledger root.

  ## Technical depth

  Carries the canonical root path, the generation record's digest, and the exact
  root binding. It is edge-private placement state and is deliberately not
  serializable into any durable, public, progress, or diagnostic plane.
  """
  @type prepared :: %{
          root: binary(),
          generation_digest: binary(),
          root_binding: binary(),
          executor_epoch: pos_integer()
        }

  @doc """
  ## Concept

  Validates an existing prepared root, or exclusively creates one, and returns
  the private authority over it.

  ## Technical depth

  The generation binds the configured executor identity, a nonzero random
  256-bit epoch, and the digest of the expanded root path together with the
  directory's device and inode. An ordinary whole-root move presented at a
  different expanded path, a replacement directory, and an isolated copy of the
  generation file into another root are therefore all refused: the recorded
  binding no longer matches the observation. Partial copy or deletion, snapshot
  rollback, inode reuse, and administrator rewriting of the root are outside this
  boundary and are documented limitations rather than detected faults.

  Creation publishes exclusively without following symlinks, syncs the file and
  then its parent, and reads the bytes back before the authority is returned.
  Each directory this creates is synced into the directory that names it, so a
  crash cannot leave a record durable inside a directory that is not.
  """
  @spec prepare(binary(), binary(), pos_integer()) :: {:ok, prepared()} | {:error, term()}
  def prepare(root, identity, cleanup_grace_ms) do
    with true <- is_binary(root) and root != "",
         true <- is_binary(identity) and identity != "",
         true <- is_integer(cleanup_grace_ms) and cleanup_grace_ms in 1..@max_uint64,
         expanded = Path.expand(root),
         :ok <- mkdir_synced(expanded),
         {:ok, binding} <- root_binding(expanded),
         :ok <- mkdir_synced(open_directory(expanded)),
         :ok <- mkdir_synced(marker_directory(expanded)),
         {:ok, generation} <- read_or_create_generation(expanded, identity, binding) do
      {:ok,
       %{
         root: expanded,
         generation_digest: digest(encode(generation)),
         root_binding: binding,
         executor_epoch: generation["executor_epoch"]
       }}
    else
      {:error, reason} -> {:error, reason}
      _other -> {:error, :invalid_ledger_placement}
    end
  end

  @doc """
  ## Concept

  Re-proves that the prepared root is still the same directory this authority
  was bound to.

  ## Technical depth

  Repeats the exact expansion and stat before a single ledger byte is read, so a
  root replaced or moved under a live executor is refused rather than trusted
  because it was valid at startup.
  """
  @spec revalidate(prepared()) :: :ok | {:error, term()}
  def revalidate(%{root: root, root_binding: binding}) do
    case root_binding(root) do
      {:ok, ^binding} -> :ok
      {:ok, _other} -> {:error, {:ledger_unavailable, :root_binding_changed}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  ## Concept

  Runs one function while holding the root-wide exclusive administrative claim.

  ## Technical depth

  The claim is an atomic directory creation, so two executors on one root cannot
  both hold it and neither can be persuaded by elapsed time that the other has
  finished. A claim this call could not take is bounded unavailability. A raising
  or exiting body releases the claim before the exception continues, so it cannot
  strand it inside one live process; a claim stranded by process death stays,
  because reaping it would turn absence of a process into permission.

  A release that fails replaces the body's result with
  `{:ledger_unavailable, {:root_claim_not_released, reason}}`. The body's
  decision was real, but it was reached on a root this call has just stranded,
  and every later claim on it answers `root_claim_held` until an operator clears
  the claim directory.
  """
  @spec with_claim(prepared(), (-> term()), non_neg_integer()) :: term() | {:error, term()}
  def with_claim(prepared, work, wait_ms \\ 0)

  def with_claim(%{root: root} = prepared, work, wait_ms)
      when is_function(work, 0) and is_integer(wait_ms) and wait_ms >= 0 do
    path = claim_directory(root)

    case File.mkdir(path) do
      :ok ->
        outcome =
          try do
            case revalidate(prepared) do
              :ok -> work.()
              {:error, reason} -> {:error, reason}
            end
          catch
            kind, reason ->
              _released = File.rmdir(path)
              :erlang.raise(kind, reason, __STACKTRACE__)
          end

        # Concept: giving the claim back is part of taking it, so a release that
        # did not happen is part of this call's answer.
        #
        # Technical depth: the release ran in an `after` and its result was
        # discarded. `File.rmdir/1` fails on a claim directory a late writer left
        # something in and on EIO, so the caller was handed the body's success
        # while every later `File.mkdir/1` on this path answered
        # `{:ledger_unavailable, :root_claim_held}` for the life of the root. ADR
        # 0016 clause 7 makes claim refusal bounded ledger-unavailability rather
        # than permission, and a root that will refuse every claim from here on
        # is exactly that fact reaching everyone except the caller that caused
        # it. The rule is that a failed release replaces the body's result: the
        # decision was real, but it was fixed on a root this call has stranded,
        # and reporting success would publish a decision nothing can follow up.
        # No retry is attempted and no claim is reaped, because elapsed time is
        # not proof that no late writer survives; the reason names what an
        # operator has to clear.
        case File.rmdir(path) do
          :ok ->
            outcome

          {:error, reason} ->
            {:error, {:ledger_unavailable, {:root_claim_not_released, reason}}}
        end

      {:error, :eexist} when wait_ms > 0 ->
        # Concept: waiting for a claim someone else is holding is not the same as
        # deciding it has been held long enough.
        #
        # Technical depth: the wait is bounded by the caller's own allowance and
        # ends in unavailability, never in permission: the claim is released by
        # its holder and by nothing else. Polling is what a filesystem lock
        # offers; there is no message to wait on across processes or VMs.
        Process.sleep(min(wait_ms, @claim_poll_ms))
        with_claim(prepared, work, max(wait_ms - @claim_poll_ms, 0))

      {:error, :eexist} ->
        {:error, {:ledger_unavailable, :root_claim_held}}

      {:error, reason} ->
        {:error, {:ledger_unavailable, reason}}
    end
  end

  @doc """
  ## Concept

  Reads one complete bounded snapshot of the open-authority index.

  ## Technical depth

  The caller must already hold the root claim, so the snapshot is closed: no
  entry can appear or vanish between the listing and the reads. Entry count,
  every record's raw and canonical size, and the canonical snapshot's own size
  are all bounded; exceeding any of them, or finding one malformed entry, is
  ledger-unavailable and never permission. Capacity is refused rather than
  evicted, because an unresolved open entry is exactly the truth that must not be
  thrown away to make room.
  """
  @spec open_snapshot(prepared()) :: {:ok, [map()]} | {:error, term()}
  def open_snapshot(%{root: root} = prepared) do
    directory = open_directory(root)

    with {:ok, names} <- list_entries(directory),
         :ok <- within_capacity(names),
         {:ok, entries} <- read_open_entries(directory, Enum.sort(names)),
         {:ok, snapshot} <- bound_snapshot(prepared, entries) do
      {:ok, snapshot}
    end
  end

  @doc """
  ## Concept

  Publishes one job's admission marker and open-authority entry before the
  effect may be permitted.

  ## Technical depth

  Both records are written exclusively, synced, and their parent directory
  synced, before this returns. Publication is first-writer-wins: an existing
  marker or open entry for the same job is reported so the caller can join or
  conflict rather than overwrite newer truth.

  The open entry is published first, and the order is the whole of what a crash
  between the two publications leaves behind. Publishing the marker first left a
  marker with no open entry: the quarantine scan reads open entries, so it saw a
  root with nothing to reconcile, while every later request for that identity
  read the marker as a live admission and joined an operation that would never
  produce a receipt. An open entry with no marker is the opposite and the safe
  one -- the scan sees unresolved authority and quarantines the root, which is
  exactly what an admission nobody can prove either way deserves. Neither order
  makes the pair atomic; this one makes the incomplete state the one that fails
  closed.
  """
  @spec admit(prepared(), map(), map()) :: :ok | {:error, term()}
  def admit(%{root: root}, marker, open) do
    with :ok <- publish(open_path(root, open["job_id"]), encode(open)),
         :ok <- publish(marker_path(root, marker["job_id"]), encode(marker)) do
      :ok
    end
  end

  @doc """
  ## Concept

  Publishes the exact durable pre-effect refusal for a job whose effect never
  began.

  ## Technical depth

  A refusal replaces exactly the marker path it names, which is what lets a
  queued cancellation or a pre-marker deadline record the refusal without
  inventing an admission. It is written to a staging name, synced, atomically
  renamed, and its parent synced, so no reader can observe a partially written
  refusal.

  The replacement is conditional, and the caller must already hold the root
  claim. Renaming over the marker path unconditionally meant a refusal could
  erase an admission another instance had just published for the same job --
  "no effect began" written over the exact record proving one had. Nothing but
  call-site ordering stood between that and a lost effect, and call-site
  ordering is a property of one module rather than of this shared root. An
  admission marker is therefore reported as
  `{:ledger_conflict, :admission_marker_present}` and left exactly as it is. An
  absent marker and an existing refusal both still admit the write, because
  neither of them claims an effect began.
  """
  @spec refuse(prepared(), map()) :: :ok | {:error, term()}
  def refuse(%{root: root} = prepared, refusal) do
    job_id = refusal["job_id"]

    case read_marker(prepared, job_id) do
      :absent ->
        replace(marker_path(root, job_id), refusal)

      {:ok, %{ledger_kind: @refusal_kind}} ->
        replace(marker_path(root, job_id), refusal)

      {:ok, _admission} ->
        {:error, {:ledger_conflict, :admission_marker_present}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  ## Concept

  Removes one job's open-authority entry once its truth is settled.

  ## Technical depth

  Called only after a matching durable refusal or a receipt whose cleanup is
  confirmed. Anything weaker leaves the entry, and therefore the root, in the
  quarantined state that refuses new effects until an operator reconciles it.
  """
  @spec close_open(prepared(), binary()) :: :ok | {:error, term()}
  def close_open(%{root: root}, job_id) do
    path = open_path(root, job_id)

    case File.rm(path) do
      :ok -> sync_parent(Path.dirname(path))
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, {:ledger_unavailable, reason}}
    end
  end

  @doc """
  ## Concept

  The exact admission marker record for one job.

  ## Technical depth

  The nonce is fresh 256-bit randomness rendered as lowercase hexadecimal, so two
  admissions of the same identity are distinguishable in the durable record even
  where every other member matches.
  """
  @spec marker(map()) :: map()
  def marker(job) do
    %{
      :ledger_kind => @marker_kind,
      "job_id" => job.job_id,
      "canonical_request_digest" => job.canonical_request_digest,
      "operation_id" => job.operation_id,
      "attempt" => job.attempt,
      "cleanup_grace_ms" => job.cleanup_grace_ms,
      "admission_nonce" => Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)
    }
  end

  @doc """
  ## Concept

  The exact open-authority entry for one admitted job.

  ## Technical depth

  Its pathname is the lowercase SHA-256 of the decoded job ID, so an unbounded
  identifier cannot become an unbounded filename and two instances agree on where
  one job's authority lives.
  """
  @spec open_entry(map(), binary()) :: map()
  def open_entry(job, identity) do
    %{
      :ledger_kind => @open_kind,
      "job_id" => job.job_id,
      "canonical_request_digest" => job.canonical_request_digest,
      "executor_identity" => identity,
      "origin_executor_epoch" => job.origin_executor_epoch,
      "cleanup_grace_ms" => job.cleanup_grace_ms
    }
  end

  @doc """
  ## Concept

  The exact durable pre-effect refusal record for one job.

  ## Technical depth

  Only the sixteen reason codes ADR 0016 admits are accepted, and `field` is
  non-null only for the two binding codes. An unknown code is refused here rather
  than journaled, because a refusal nobody can read is not proof that no effect
  began.
  """
  @spec refusal(map(), atom() | binary(), atom() | nil) :: {:ok, map()} | :error
  def refusal(job, code, field \\ nil) do
    code = to_string(code)

    if code in @refusal_codes and (is_nil(field) or code in ~w(missing_binding binding_mismatch)) do
      {:ok,
       %{
         :ledger_kind => @refusal_kind,
         "job_id" => job.job_id,
         "canonical_request_digest" => job.canonical_request_digest,
         "operation_id" => job.operation_id,
         "attempt" => job.attempt,
         "reason" => %{"code" => code, "field" => field && to_string(field)}
       }}
    else
      :error
    end
  end

  @doc """
  ## Concept

  Reads the admission-plane record for one job, if any.

  ## Technical depth

  Answers `:absent`, `{:ok, marker}`, `{:ok, refusal}`, or unavailability. A
  present-but-unreadable record is unavailable rather than absent, for the same
  reason the index is.
  """
  @spec read_marker(prepared(), binary()) :: {:ok, map()} | :absent | {:error, term()}
  def read_marker(%{root: root}, job_id) do
    read_record(marker_path(root, job_id), [@marker_kind, @refusal_kind])
  end

  @doc """
  ## Concept

  Whether one job still holds open authority on this root.

  ## Technical depth

  Read under the caller's claim as part of a complete snapshot wherever the
  answer combines with terminal truth.
  """
  @spec open?(prepared(), binary()) :: boolean()
  def open?(%{root: root}, job_id), do: File.regular?(open_path(root, job_id))

  @doc """
  ## Concept

  The kind name of an admission marker record.

  ## Technical depth

  Exposed so the executor can tell an admission from a refusal without repeating
  the literal.
  """
  @spec marker_kind() :: binary()
  def marker_kind, do: @marker_kind

  @doc """
  ## Concept

  The kind name of a durable pre-effect refusal record.

  ## Technical depth

  Exposed for the same reason `marker_kind/0` is.
  """
  @spec refusal_kind() :: binary()
  def refusal_kind, do: @refusal_kind

  # Concept: the root is one directory, identified by where it is and by which
  # directory that path actually names.
  #
  # Technical depth: the expanded path bytes bind the alias the caller supplied,
  # while device and inode bind the directory itself. `File.stat/2` deliberately
  # follows path symlinks, so an administrator-created alias is covered by the
  # documented limitation rather than by this check; a whole-root move presented
  # at another path, a replacement directory, and an isolated generation copy all
  # change one of the three inputs and are refused.
  defp root_binding(expanded) do
    case File.stat(expanded, time: :posix) do
      {:ok, %File.Stat{type: :directory, major_device: device, inode: inode}}
      when is_integer(device) and device >= 0 and device <= @max_uint64 and
             is_integer(inode) and inode >= 0 and inode <= @max_uint64 ->
        {:ok,
         digest(
           <<"loopex:local-root-binding:v1", 0, byte_size(expanded)::unsigned-64-big,
             expanded::binary, device::unsigned-64-big, inode::unsigned-64-big>>
         )}

      {:ok, _other} ->
        {:error, {:ledger_unavailable, :root_not_a_directory}}

      {:error, reason} ->
        {:error, {:ledger_unavailable, reason}}
    end
  end

  defp read_or_create_generation(root, identity, binding) do
    path = generation_path(root)

    case read_record(path, [@generation_kind], @generation_bytes) do
      {:ok, record} -> validate_generation(record, identity, binding)
      :absent -> create_generation(path, identity, binding)
      {:error, reason} -> {:error, reason}
    end
  end

  defp create_generation(path, identity, binding) do
    epoch = draw_epoch()

    record = %{
      :ledger_kind => @generation_kind,
      "executor_identity" => identity,
      "executor_epoch" => epoch,
      "generation_id" => epoch |> Integer.to_string(16) |> String.pad_leading(64, "0"),
      "root_binding" => binding
    }

    bytes = encode(record)

    with true <- byte_size(bytes) <= @generation_bytes,
         :ok <- publish(path, bytes),
         {:ok, ^record} <- read_record(path, [@generation_kind], @generation_bytes) do
      {:ok, record}
    else
      {:error, :eexist} -> {:error, {:ledger_unavailable, :generation_raced}}
      {:error, reason} -> {:error, reason}
      _other -> {:error, {:ledger_unavailable, :generation_unreadable}}
    end
  end

  # A nonzero 256-bit epoch. Zero is excluded so the rendered generation
  # identifier is never all zeroes, which is what an absent or zeroed record
  # would decode to.
  defp draw_epoch do
    case :crypto.strong_rand_bytes(32) do
      <<0::256>> -> draw_epoch()
      <<epoch::unsigned-256>> -> epoch
    end
  end

  defp validate_generation(record, identity, binding) do
    epoch = record["executor_epoch"]

    valid =
      record["executor_identity"] == identity and is_integer(epoch) and epoch > 0 and
        epoch <= @max_epoch and
        record["generation_id"] == epoch |> Integer.to_string(16) |> String.pad_leading(64, "0") and
        record["root_binding"] == binding

    if valid, do: {:ok, record}, else: {:error, {:ledger_unavailable, :generation_mismatch}}
  end

  defp read_open_entries(directory, names) do
    Enum.reduce_while(names, {:ok, []}, fn name, {:ok, entries} ->
      path = Path.join(directory, name)

      case read_record(path, [@open_kind]) do
        {:ok, record} ->
          if valid_open_entry?(record),
            do: {:cont, {:ok, [{name, record} | entries]}},
            else: {:halt, {:error, {:ledger_unavailable, :malformed_open_entry}}}

        :absent ->
          {:halt, {:error, {:ledger_unavailable, :malformed_open_entry}}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, entries} -> {:ok, Enum.reverse(entries)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp valid_open_entry?(record) do
    is_binary(record["job_id"]) and is_binary(record["canonical_request_digest"]) and
      is_binary(record["executor_identity"]) and is_integer(record["origin_executor_epoch"]) and
      is_integer(record["cleanup_grace_ms"]) and record["cleanup_grace_ms"] in 1..@max_uint64
  end

  # Concept: the snapshot is one closed observation, and it is bounded as a whole
  # rather than only entry by entry.
  #
  # Technical depth: a thousand entries each under their own ceiling still make
  # an observation this executor cannot hold or compare, so the canonical
  # snapshot binding generation, root, claim, count, and every entry's basename,
  # raw digest, and decoded members is measured too. Exceeding it is
  # unavailability: an executor that cannot read its complete authority has not
  # proved that authority is empty.
  defp bound_snapshot(prepared, entries) do
    observation = [
      "loopex:local-root-snapshot:v1",
      prepared.generation_digest,
      prepared.root_binding,
      length(entries),
      Enum.map(entries, fn {name, record} -> [name, digest(encode(record)), record] end)
    ]

    if byte_size(:erlang.term_to_binary(observation, [:deterministic])) <= @snapshot_bytes,
      do: {:ok, Enum.map(entries, fn {_name, record} -> record end)},
      else: {:error, {:ledger_unavailable, :snapshot_too_large}}
  end

  defp within_capacity(names) when length(names) <= @max_open_entries, do: :ok
  defp within_capacity(_names), do: {:error, {:ledger_unavailable, :capacity}}

  defp list_entries(directory) do
    case File.ls(directory) do
      {:ok, names} -> {:ok, names}
      {:error, :enoent} -> {:ok, []}
      {:error, reason} -> {:error, {:ledger_unavailable, reason}}
    end
  end

  # Concept: a record is read as bytes with a ceiling before it is read as a
  # term.
  #
  # Technical depth: the raw file size is checked first, so a hostile file cannot
  # be decoded merely because it would re-encode small; the canonical
  # re-encoding is then checked against the same ceiling and against the file's
  # own bytes, so a non-canonical encoding of an admissible term is refused too.
  # A symlink is not a record: `lstat` decides, so a link pointing at valid bytes
  # elsewhere never becomes this root's truth.
  defp read_record(path, kinds, ceiling \\ @record_bytes) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular, size: size}} when size <= ceiling ->
        decode_record(path, kinds, ceiling)

      {:ok, %File.Stat{type: :regular}} ->
        {:error, {:ledger_unavailable, :record_too_large}}

      {:ok, _other} ->
        {:error, {:ledger_unavailable, :record_not_a_regular_file}}

      {:error, :enoent} ->
        :absent

      {:error, reason} ->
        {:error, {:ledger_unavailable, reason}}
    end
  end

  defp decode_record(path, kinds, ceiling) do
    with {:ok, bytes} <- File.read(path),
         record when is_map(record) <- safe_decode(bytes),
         true <- Map.get(record, :ledger_kind) in kinds,
         true <- exact_keys?(record),
         canonical = encode(record),
         true <- canonical == bytes and byte_size(canonical) <= ceiling do
      {:ok, record}
    else
      {:error, reason} -> {:error, {:ledger_unavailable, reason}}
      _other -> {:error, {:ledger_unavailable, :malformed_record}}
    end
  end

  # Concept: every member is either the kind marker or a plain string-keyed
  # field.
  #
  # Technical depth: this is what makes an unknown key refuse. The exact key set
  # per kind is enforced by the caller's own validation; an extra key of any name
  # already changes the canonical bytes, and a key that is neither the kind atom
  # nor a binary is not a shape this ledger writes.
  defp exact_keys?(record) do
    case Map.fetch(@kind_keys, Map.get(record, :ledger_kind)) do
      {:ok, keys} -> Enum.sort(Map.keys(record)) == Enum.sort(keys)
      :error -> false
    end
  end

  defp safe_decode(bytes) do
    :erlang.binary_to_term(bytes, [:safe])
  rescue
    _error -> :invalid
  catch
    _kind, _reason -> :invalid
  end

  # Concept: publication is first-writer-wins, and durable before it returns.
  #
  # Technical depth: exclusive creation without following a symlink is the whole
  # of the ordering claim, and the file is synced before its parent so a reader
  # that can see the name can always read complete bytes. The parent sync after
  # the file sync is the order the retained evidence checks: reversing it makes
  # the directory entry durable before the bytes it names.
  # Concept: a directory this ledger created is not durable until the directory
  # that names it is.
  #
  # Technical depth: `File.mkdir_p/1` returns once the kernel holds the entry, so
  # a crash before the parent's own metadata reached the disk could leave the
  # root, the open index, or the marker directory absent while a record synced
  # into one of them was not. Every publication already syncs the directory its
  # record lands in; this closes the level above, which is the only one that was
  # created without it.
  defp mkdir_synced(path) do
    with :ok <- File.mkdir_p(path) do
      sync_parent(Path.dirname(path))
    end
  end

  defp publish(path, bytes) do
    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- write_synced(path, bytes, [:write, :binary, :exclusive]) do
      sync_parent(Path.dirname(path))
    end
  end

  defp replace(path, record) do
    bytes = encode(record)
    staging = path <> ".tmp-" <> Integer.to_string(System.unique_integer([:positive]))

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- write_synced(staging, bytes, [:write, :binary, :exclusive]),
         :ok <- File.rename(staging, path),
         :ok <- sync_parent(Path.dirname(path)) do
      :ok
    else
      {:error, reason} ->
        File.rm(staging)
        {:error, {:ledger_unavailable, reason}}
    end
  end

  defp write_synced(path, bytes, modes) do
    case File.open(path, modes) do
      {:ok, file} ->
        result =
          with :ok <- IO.binwrite(file, bytes) do
            :file.sync(file)
          end

        closed = File.close(file)

        case {result, closed} do
          {:ok, :ok} -> :ok
          {{:error, reason}, _closed} -> {:error, reason}
          {:ok, {:error, reason}} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp sync_parent(directory) do
    case :file.open(String.to_charlist(directory), [:raw, :read, :directory]) do
      {:ok, file} ->
        result = :file.sync(file)
        closed = :file.close(file)

        case {result, closed} do
          {:ok, :ok} -> :ok
          {{:error, reason}, _closed} -> {:error, {:ledger_unavailable, reason}}
          {:ok, {:error, reason}} -> {:error, {:ledger_unavailable, reason}}
        end

      {:error, reason} ->
        {:error, {:ledger_unavailable, reason}}
    end
  end

  defp encode(record), do: :erlang.term_to_binary(record, [:deterministic])

  defp digest(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  defp generation_path(root), do: Path.join(root, "generation")
  defp claim_directory(root), do: Path.join(root, "claim")
  defp marker_directory(root), do: Path.join(root, "markers")
  defp open_directory(root), do: Path.join(root, "open")
  defp marker_path(root, job_id), do: Path.join(marker_directory(root), digest(job_id))
  defp open_path(root, job_id), do: Path.join(open_directory(root), digest(job_id))
end
