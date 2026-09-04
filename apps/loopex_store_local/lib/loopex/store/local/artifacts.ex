defmodule Loopex.Store.Local.Artifacts do
  @moduledoc """
  ## Concept

  The local filesystem artifact store: digest-addressed immutable objects under
  a resolved root, each with the immutable record of why it was retained beside
  it. Writing the same bytes twice costs one object and yields one reference;
  writing them under a second reason keeps the one object and adds a second
  record; reading back returns exactly what was written or says plainly that it
  cannot.

  ## Technical depth

  An object's path is derived from its own SHA-256, so storage is
  content-addressed and `put/3` is idempotent by construction rather than by a
  check that could race. Two writers storing identical bytes converge on one
  file; two writers storing different bytes cannot collide, because different
  bytes have different digests. The object locator *is* that digest, which is
  what makes it permanently bound to one digest/size pair: there is no naming
  step that could later hand the same locator to different bytes.

  A use record lives under `uses/` and is named by its own digest for the same
  reason. Its file holds exactly the canonical bytes the use digest covers, so a
  reader recomputes rather than trusts. The object is published first and the use
  second; success is returned only once both are durable. A crash between the two
  leaves an object nothing references, which costs disk and misleads nobody,
  while a reference to a use that was never published would be a durable claim
  about provenance that cannot be resolved.

  Use publication never overwrites. An existing sidecar with identical bytes is
  the same immutable fact and is accepted after its durability is reconfirmed;
  an existing different, partial, or unreadable one is unavailable and is left
  exactly as it is. Concurrent identical writers therefore converge on one
  byte-identical record instead of racing to be last.

  Writes go to a temporary name in the same directory, sync the complete file,
  rename it into place, and sync the containing directory where the platform
  supports directory sync. A reader therefore never observes a partially
  written object: the rename is atomic within a filesystem, and a crash
  mid-write leaves a temporary file that belongs to nothing rather than a
  truncated artifact that looks complete.

  An existing object is verified before it is treated as a hit. Trusting the
  filename's digest alone would mean a corrupted or truncated file kept its
  identity, and `fetch/2` would hand back bytes that are not what was stored.

  Nothing here collects. An artifact stays until a host removes it, because the
  kernel cannot know whether a reconciliation is about to need it.
  """

  @behaviour Loopex.ArtifactStore

  alias Loopex.ArtifactStore
  alias LoopexProtocol.Canonical

  @max_bytes 64 * 1024 * 1024
  @temporary_attempts 8
  @use_tag "artifact-use-v2"
  @use_locator_prefix "use:"
  @use_directory "uses"
  @digest_shape ~r/^[0-9a-f]{64}$/

  @typedoc """
  ## Concept

  Edge-private placement state: where this adapter keeps its objects.

  ## Technical depth

  Never journaled, published, or transported. It is a path on the machine that
  holds the store, and a path is exactly the kind of thing a durable record must
  not carry across a boundary.

  `fault_probe` is private test seam state and is absent in production. Where a
  conformance case supplies one, use publication announces each semantic phase to
  it and waits for permission to continue, which is how "no reference was
  returned before this phase completed" is proved without racing a filesystem.
  """
  @type handle :: %{required(:root) => binary(), optional(:fault_probe) => pid()}

  @doc """
  ## Concept

  Opens an artifact store under a resolved root.

  ## Technical depth

  The root is created if absent. It is supplied by the host rather than derived
  here, because where an operator's data lives is the host's decision and a
  kernel that chose would be choosing for every host at once.
  """
  @spec open(binary()) :: {:ok, handle()} | {:error, term()}
  def open(root) when is_binary(root) do
    case ensure_directory_durable(root) do
      :ok -> {:ok, %{root: root}}
      {:error, reason} -> {:error, {:artifact_root_unavailable, reason}}
    end
  end

  @doc """
  ## Concept

  The declared ceiling for one artifact.

  ## Technical depth

  Declared rather than implicit so a caller can refuse before producing bytes it
  cannot store.
  """
  @spec max_bytes() :: pos_integer()
  def max_bytes, do: @max_bytes

  @impl Loopex.ArtifactStore
  @spec put(handle(), binary(), ArtifactStore.normalized_use()) ::
          {:ok, ArtifactStore.artifact_reference()} | {:error, term()}
  def put(%{root: root} = handle, bytes, %{media_type: media_type, role: role, metadata: metadata})
      when is_binary(bytes) and is_binary(media_type) and is_binary(role) and is_map(metadata) do
    cond do
      byte_size(bytes) > @max_bytes ->
        # Fails closed with the truth rather than storing part of it: a truncated
        # artifact is exactly what the spill exists to prevent.
        {:error, {:artifact_too_large, byte_size(bytes), @max_bytes}}

      role not in ArtifactStore.roles() ->
        {:error, {:unknown_artifact_role, role}}

      true ->
        digest = Canonical.digest_bytes(bytes)
        object = %{digest: digest, size: byte_size(bytes), locator: digest}
        path = object_path(root, digest)

        with :ok <- ensure_directory(root, Path.dirname(path)),
             :ok <- write_once(path, bytes, digest) do
          retain_use(handle, object, media_type, role, metadata)
        end
    end
  end

  def put(_handle, _bytes, _use), do: {:error, :adapter_received_unnormalized_use}

  @impl Loopex.ArtifactStore
  @spec fetch(handle(), ArtifactStore.artifact_object()) :: {:ok, binary()} | {:error, term()}
  def fetch(%{root: root}, object) do
    if ArtifactStore.valid_object?(object) and mine?(object.locator) do
      case File.read(object_path(root, object.locator)) do
        {:ok, bytes} -> verify(bytes, object.digest, object.size)
        {:error, :enoent} -> {:error, :unknown_artifact}
        {:error, reason} -> {:error, {:artifact_unreadable, reason}}
      end
    else
      {:error, :unknown_artifact}
    end
  end

  @impl Loopex.ArtifactStore
  @spec stat(handle(), binary()) ::
          {:ok, ArtifactStore.artifact_object()} | {:error, term()}
  def stat(%{root: root}, locator) when is_binary(locator) do
    if mine?(locator) do
      case File.read(object_path(root, locator)) do
        {:ok, bytes} ->
          # This adapter issued a digest-addressed locator, so the locator itself
          # is the digest the stored bytes must produce. Nothing about the caller
          # is consulted: a locator names bytes or it names nothing.
          with {:ok, _bytes} <- verify(bytes, locator) do
            {:ok, %{digest: locator, size: byte_size(bytes), locator: locator}}
          end

        {:error, :enoent} ->
          {:error, :unknown_artifact}

        {:error, reason} ->
          {:error, {:artifact_unreadable, reason}}
      end
    else
      {:error, :unknown_artifact}
    end
  end

  def stat(_handle, _locator), do: {:error, :unknown_artifact}

  @impl Loopex.ArtifactStore
  @spec describe(handle(), binary()) :: {:ok, ArtifactStore.artifact_use()} | {:error, term()}
  def describe(%{root: root}, @use_locator_prefix <> use_digest) when is_binary(use_digest) do
    if mine?(use_digest) do
      case File.read(use_path(root, use_digest)) do
        {:ok, bytes} -> decode_use(bytes)
        {:error, :enoent} -> {:error, :unknown_artifact_use}
        {:error, reason} -> {:error, {:artifact_unreadable, reason}}
      end
    else
      {:error, :unknown_artifact_use}
    end
  end

  def describe(_handle, _use_locator), do: {:error, :unknown_artifact_use}

  # Concept: the object is durable before its reason is written, and the
  # reference exists only once both are.
  #
  # Technical depth: the use record binds the complete object triple, so it
  # cannot be built until the object identity is settled. Ordering it after
  # publication means a crash in between orphans an object rather than leaving a
  # returned reference pointing at a use nobody wrote. The exact encoded ceiling
  # is applied here rather than before, because the object locator is one of the
  # bytes being measured.
  defp retain_use(%{root: root} = handle, object, media_type, role, metadata) do
    artifact_use = %{
      canonicalization_version: Canonical.version(),
      object_digest: object.digest,
      object_size: object.size,
      object_locator: object.locator,
      media_type: media_type,
      role: role,
      metadata: metadata
    }

    use_bytes = Canonical.encode([@use_tag, artifact_use])

    if byte_size(use_bytes) > ArtifactStore.max_use_bytes() do
      {:error, :artifact_use_too_large}
    else
      use_digest = Canonical.digest_bytes(use_bytes)
      path = use_path(root, use_digest)

      with :ok <- ensure_directory(root, Path.dirname(path)),
           :ok <- publish_use(handle, path, use_bytes) do
        {:ok,
         Map.merge(object, %{
           media_type: media_type,
           role: role,
           use_canonicalization_version: Canonical.version(),
           use_digest: use_digest,
           use_locator: @use_locator_prefix <> use_digest
         })}
      end
    end
  end

  # Concept: an immutable record is written once and afterwards only confirmed.
  #
  # Technical depth: the file is named by the digest of its own contents, so a
  # value already there is either the same fact or evidence that something else
  # holds this name. Identical bytes are reconfirmed durable and accepted;
  # anything else — different, half-written, or not a readable file at all — is
  # unavailable and left untouched. Overwriting instead would make the last
  # concurrent writer authoritative over a record the first one already returned
  # a reference for.
  defp publish_use(handle, path, use_bytes) do
    case File.read(path) do
      {:ok, existing} ->
        with :ok <- fault_point(handle, :existing_value_compare) do
          if existing == use_bytes,
            do: sync_existing(path),
            else: {:error, {:artifact_use_unavailable, :conflicting_use}}
        end

      {:error, :enoent} ->
        with :ok <- fault_point(handle, :staging_write),
             do: stage_use(handle, path, use_bytes, 0)

      {:error, reason} ->
        {:error, {:artifact_use_unavailable, reason}}
    end
  end

  defp stage_use(_handle, _path, _use_bytes, @temporary_attempts),
    do: {:error, {:artifact_use_unavailable, :temporary_name_collision}}

  defp stage_use(handle, path, use_bytes, attempt) do
    temporary = temporary_path(path, attempt)

    case :file.open(String.to_charlist(temporary), [:write, :binary, :raw, :exclusive]) do
      {:ok, io_device} ->
        case write_synced_use(handle, io_device, use_bytes) do
          :ok -> publish_use_staging(handle, temporary, path)
          {:error, reason} -> discard_staging(temporary, reason)
        end

      # The name belongs to another writer or to a prior crashed process. It must
      # not be removed by this writer; use another exclusive name.
      {:error, :eexist} ->
        stage_use(handle, path, use_bytes, attempt + 1)

      {:error, reason} ->
        {:error, {:artifact_use_unavailable, reason}}
    end
  end

  defp write_synced_use(handle, io_device, use_bytes) do
    result =
      with :ok <- use_result(:file.write(io_device, use_bytes)),
           :ok <- fault_point(handle, :file_sync),
           :ok <- use_result(:file.sync(io_device)) do
        :ok
      end

    close_result = use_result(:file.close(io_device))

    case {result, close_result} do
      {:ok, :ok} -> :ok
      {:ok, {:error, reason}} -> {:error, reason}
      {{:error, reason}, _close} -> {:error, reason}
    end
  end

  defp publish_use_staging(handle, temporary, path) do
    with :ok <- fault_point(handle, :atomic_publication),
         :ok <- use_result(File.rename(temporary, path)),
         :ok <- fault_point(handle, :parent_directory_sync),
         :ok <- use_result(sync_directory(Path.dirname(path))) do
      :ok
    else
      {:error, reason} -> discard_staging(temporary, reason)
    end
  end

  defp discard_staging(temporary, reason) do
    _ = File.rm(temporary)
    {:error, reason}
  end

  defp use_result(:ok), do: :ok
  defp use_result({:error, reason}), do: {:error, {:artifact_use_unavailable, reason}}

  # Concept: a conformance case needs to stop publication at an exact semantic
  # phase, and production must not pay for that.
  #
  # Technical depth: the seam is one private handle member. Absent — which is
  # every composed handle — this is a compile-time-shaped no-op clause. Present,
  # each phase announces itself and blocks until the probe answers, so a case can
  # assert that no reference had been returned while the phase was still
  # outstanding. A correlation reference distinguishes this call's answer from
  # any other's rather than trusting message order.
  defp fault_point(%{fault_probe: probe}, phase) when is_pid(probe) do
    correlation = make_ref()

    send(
      probe,
      {:loopex_artifact_fault_point, self(), correlation, {:artifact_use_publication, phase}}
    )

    receive do
      {:loopex_artifact_fault_action, ^correlation, :continue} ->
        :ok

      {:loopex_artifact_fault_action, ^correlation, :return_error} ->
        {:error, {:artifact_use_unavailable, phase}}
    end
  end

  defp fault_point(_handle, _phase), do: :ok

  # Concept: a stored use is trusted only after the bytes reproduce it exactly.
  #
  # Technical depth: `Canonical.encode/1` projects maps to key-sorted pairs, so
  # decoding reverses that projection and then re-encodes. The comparison against
  # the bytes on disk is what makes the file's own name a verified digest rather
  # than a label. `:safe` refuses a term carrying a pid, port, reference,
  # function, or an atom this VM does not already know, and a truncated or
  # foreign file raises rather than decoding into a plausible record.
  defp decode_use(bytes) do
    with [@use_tag, ordered] <- :erlang.binary_to_term(bytes, [:safe]),
         artifact_use when is_map(artifact_use) <- unorder(ordered),
         ^bytes <- Canonical.encode([@use_tag, artifact_use]) do
      {:ok, artifact_use}
    else
      _mismatch -> {:error, :artifact_integrity_failed}
    end
  rescue
    ArgumentError -> {:error, :artifact_integrity_failed}
  end

  defp unorder({:loopex_map, pairs}) when is_list(pairs) do
    if Enum.all?(pairs, &match?({_key, _value}, &1)),
      do: Map.new(pairs, fn {key, value} -> {unorder(key), unorder(value)} end),
      else: :invalid_artifact_use
  end

  defp unorder(term) when is_list(term), do: Enum.map(term, &unorder/1)
  defp unorder(term), do: term

  # Concept: an object already present must be the object it claims to be.
  #
  # Technical depth: the filename carries the digest, so a corrupted or truncated
  # file would otherwise keep its identity and be served as a hit. Reading and
  # comparing costs one read on the idempotent path and is what makes "identical
  # bytes twice yield one object" a fact rather than an assumption.
  defp write_once(path, bytes, digest) do
    case File.read(path) do
      {:ok, ^bytes} ->
        sync_existing(path)

      {:ok, _different} ->
        rename_into_place(path, bytes)

      {:error, :enoent} ->
        rename_into_place(path, bytes)

      {:error, reason} ->
        {:error, {:artifact_unwritable, reason, digest}}
    end
  end

  defp sync_existing(path) do
    case :file.open(String.to_charlist(path), [:read, :binary, :raw]) do
      {:ok, io_device} ->
        result = :file.sync(io_device)
        close_result = :file.close(io_device)

        with :ok <- result,
             :ok <- close_result,
             :ok <- sync_directory(Path.dirname(path)) do
          :ok
        end

      {:error, reason} ->
        {:error, {:artifact_unwritable, reason}}
    end
  end

  defp rename_into_place(path, bytes), do: rename_into_place(path, bytes, 0)

  defp rename_into_place(_path, _bytes, @temporary_attempts) do
    {:error, {:artifact_unwritable, :temporary_name_collision}}
  end

  defp rename_into_place(path, bytes, attempt) do
    temporary = temporary_path(path, attempt)

    case write_synced(temporary, bytes) do
      :ok ->
        publish_temporary(temporary, path, bytes)

      {:error, :eexist} ->
        # The path belongs to another writer or to a prior crashed process. It
        # must not be removed by this writer; use another exclusive name.
        rename_into_place(path, bytes, attempt + 1)

      {:error, reason} ->
        {:error, {:artifact_unwritable, reason}}
    end
  end

  defp temporary_path(path, 0), do: path <> ".tmp-" <> List.to_string(:os.getpid())

  defp temporary_path(path, attempt) do
    instant = System.system_time(:nanosecond)
    unique = System.unique_integer([:monotonic, :positive])

    path <>
      ".tmp-" <> List.to_string(:os.getpid()) <> "-#{instant}-#{unique}-#{attempt}"
  end

  defp publish_temporary(temporary, path, bytes) do
    case File.rename(temporary, path) do
      :ok ->
        sync_directory(Path.dirname(path))

      {:error, :eexist} ->
        # Windows does not replace an existing destination. A concurrent writer
        # of the same content may have won after this writer checked; verify the
        # winner and retain the ordinary idempotent result.
        _ = File.rm(temporary)

        case File.read(path) do
          {:ok, ^bytes} -> sync_existing(path)
          {:ok, _different} -> {:error, {:artifact_unwritable, :integrity_conflict}}
          {:error, reason} -> {:error, {:artifact_unwritable, reason}}
        end

      {:error, reason} ->
        _ = File.rm(temporary)
        {:error, {:artifact_unwritable, reason}}
    end
  end

  defp write_synced(path, bytes) do
    case :file.open(String.to_charlist(path), [:write, :binary, :raw, :exclusive]) do
      {:ok, io_device} ->
        result =
          with :ok <- :file.write(io_device, bytes),
               :ok <- :file.sync(io_device) do
            :ok
          end

        close_result = :file.close(io_device)

        case {result, close_result} do
          {:ok, :ok} -> :ok
          {{:error, reason}, _close} -> {:error, reason}
          {:ok, {:error, reason}} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Concept: success means the publication survives more than this VM.
  #
  # Technical depth: syncing the file before rename preserves its bytes; syncing
  # the directory afterwards preserves the name that makes those bytes
  # reachable. Some Unix filesystems reject directory sync explicitly, and
  # Windows does not expose this directory-open discipline through `:file`; those
  # platforms retain atomic visibility but cannot supply this extra durability
  # confirmation through the portable adapter.
  defp sync_directory(path) do
    case :os.type() do
      {:win32, _name} ->
        :ok

      {:unix, _name} ->
        do_sync_directory(path)
    end
  end

  defp do_sync_directory(path) do
    case :file.open(String.to_charlist(path), [:read, :raw, :directory]) do
      {:ok, io_device} ->
        result = :file.sync(io_device)
        close_result = :file.close(io_device)

        case {result, close_result} do
          {:ok, :ok} -> :ok
          {{:error, reason}, _close} when reason in [:einval, :enotsup] -> :ok
          {{:error, reason}, _close} -> {:error, reason}
          {:ok, {:error, reason}} -> {:error, reason}
        end

      {:error, reason} when reason in [:eisdir, :einval, :enotsup] ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Concept: every directory this store creates is durable, not only the one the
  # published file sits in.
  #
  # Technical depth: `mkdir_p/1` creates as many components as are missing, while
  # syncing the root alone proves only the entry directly beneath it. A use
  # sidecar lives two levels down at `uses/<xx>`, so the entry naming its fan-out
  # directory was never synced: a crash after a successful `put` could lose that
  # whole subtree although the sidecar and its own directory were synced, leaving
  # a returned reference to a use nobody can read -- exactly what publishing the
  # use before returning exists to prevent. Each component below the root is
  # therefore created and its parent synced before the next one is considered,
  # and an existing component reconfirms that entry so a retry cannot inherit an
  # earlier unproved publication. The root itself is `open/1`'s obligation and is
  # never created here: a store whose root has gone is unavailable, not something
  # a write quietly re-establishes unsynced.
  defp ensure_directory(root, directory) do
    parent = Path.dirname(directory)

    cond do
      Path.split(directory) == Path.split(root) ->
        :ok

      parent == directory ->
        {:error, :enoent}

      true ->
        with :ok <- ensure_directory(root, parent) do
          case File.stat(directory) do
            {:ok, %File.Stat{type: :directory}} -> sync_directory(parent)
            {:ok, _other} -> {:error, :enotdir}
            {:error, :enoent} -> create_and_sync_directory(directory, parent)
            {:error, reason} -> {:error, reason}
          end
        end
    end
  end

  # Concept: creating the artifact root is itself a durable publication.
  #
  # Technical depth: `mkdir_p/1` alone can leave a newly visible directory name
  # outside the filesystem's durable namespace after a crash. Create each absent
  # component and sync its parent before moving to the next one. A racing creator
  # is accepted only after the resulting path is confirmed to be a directory.
  defp ensure_directory_durable(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :directory}} ->
        parent = Path.dirname(path)

        # A previous caller may have created this component and then received a
        # parent-sync failure. Reconfirm the nearest existing boundary so a
        # retry cannot turn that earlier unproved publication into success.
        if parent == path, do: :ok, else: sync_directory(parent)

      {:ok, _other} ->
        {:error, :enotdir}

      {:error, :enoent} ->
        parent = Path.dirname(path)

        if parent == path do
          {:error, :enoent}
        else
          with :ok <- ensure_directory_durable(parent),
               :ok <- create_and_sync_directory(path, parent) do
            :ok
          end
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp create_and_sync_directory(path, parent) do
    case File.mkdir(path) do
      :ok ->
        sync_directory(parent)

      {:error, :eexist} ->
        case File.stat(path) do
          {:ok, %File.Stat{type: :directory}} -> sync_directory(parent)
          {:ok, _other} -> {:error, :enotdir}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp verify(bytes, digest) do
    if Canonical.digest_bytes(bytes) == digest,
      do: {:ok, bytes},
      else: {:error, :artifact_integrity_failed}
  end

  defp verify(bytes, digest, size) do
    with {:ok, ^bytes} <- verify(bytes, digest),
         true <- byte_size(bytes) == size do
      {:ok, bytes}
    else
      _mismatch -> {:error, :artifact_integrity_failed}
    end
  end

  # Concept: a locator is opaque to the port and meaningful only to the store
  # that issued it.
  #
  # Technical depth: the port bounds locators but does not constrain an adapter's
  # safe shape. This one issues content digests and derives a path by slicing the
  # first two characters, so a reference carrying any other shape -- one this
  # store never wrote, or a shorter string a caller constructed -- used to raise
  # out of `binary_part/3` during retrieval or recovery instead of failing with a
  # value. A locator this store did not issue is simply an artifact it does not
  # hold.
  defp mine?(locator), do: String.match?(locator, @digest_shape)

  # Concept: two levels of fan-out, so a directory does not grow without bound.
  #
  # Technical depth: the first two hex characters name a subdirectory. That keeps
  # any one directory to at most 256 entries at the top level, which matters on
  # filesystems whose directory lookup degrades with size.
  defp object_path(root, digest) do
    Path.join([root, binary_part(digest, 0, 2), digest])
  end

  # Concept: use records live in their own namespace, named by their own digest.
  #
  # Technical depth: the extra `uses` component keeps them out of the object
  # fan-out, whose top-level names are exactly two hex characters and so can
  # never collide with it. Naming a sidecar by the digest of its contents is what
  # makes concurrent identical writers converge on one file, and what makes the
  # public use locator derivable rather than chosen.
  defp use_path(root, use_digest) do
    Path.join([root, @use_directory, binary_part(use_digest, 0, 2), use_digest])
  end
end
