defmodule Loopex.Store.Local.Artifacts do
  @moduledoc """
  ## Concept

  The local filesystem artifact store: digest-addressed immutable objects under
  a resolved root. Writing the same bytes twice costs one object and yields one
  reference; reading back returns exactly what was written or says plainly that
  it cannot.

  ## Technical depth

  An object's path is derived from its own SHA-256, so storage is
  content-addressed and `put/3` is idempotent by construction rather than by a
  check that could race. Two writers storing identical bytes converge on one
  file; two writers storing different bytes cannot collide, because different
  bytes have different digests.

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
  @default_media_type "application/octet-stream"

  @typedoc """
  ## Concept

  Edge-private placement state: where this adapter keeps its objects.

  ## Technical depth

  Never journaled, published, or transported. It is a path on the machine that
  holds the store, and a path is exactly the kind of thing a durable record must
  not carry across a boundary.
  """
  @type handle :: %{root: binary()}

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
    case File.mkdir_p(root) do
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
  @spec put(handle(), binary(), map()) ::
          {:ok, ArtifactStore.artifact_reference()} | {:error, term()}
  def put(%{root: root}, bytes, metadata) when is_binary(bytes) and is_map(metadata) do
    role = Map.get(metadata, "role", "tool_output")

    cond do
      byte_size(bytes) > @max_bytes ->
        # Fails closed with the truth rather than storing part of it: a truncated
        # artifact is exactly what the spill exists to prevent.
        {:error, {:artifact_too_large, byte_size(bytes), @max_bytes}}

      role not in ArtifactStore.roles() ->
        {:error, {:unknown_artifact_role, role}}

      true ->
        digest = Canonical.digest_bytes(bytes)
        path = object_path(root, digest)

        with :ok <- ensure_object_directory(root, Path.dirname(path)),
             :ok <- write_once(path, bytes, digest) do
          {:ok,
           %{
             digest: digest,
             media_type: Map.get(metadata, "media_type", @default_media_type),
             size: byte_size(bytes),
             role: role,
             locator: digest
           }}
        end
    end
  end

  def put(_handle, _bytes, _metadata), do: {:error, :invalid_artifact}

  @impl Loopex.ArtifactStore
  @spec fetch(handle(), ArtifactStore.artifact_reference()) :: {:ok, binary()} | {:error, term()}
  def fetch(%{root: root}, reference) do
    if ArtifactStore.valid_reference?(reference) and mine?(reference.locator) do
      path = object_path(root, reference.locator)

      case File.read(path) do
        {:ok, bytes} -> verify(bytes, reference.digest)
        {:error, :enoent} -> {:error, :unknown_artifact}
        {:error, reason} -> {:error, {:artifact_unreadable, reason}}
      end
    else
      {:error, :unknown_artifact}
    end
  end

  @impl Loopex.ArtifactStore
  @spec stat(handle(), ArtifactStore.artifact_reference()) ::
          {:ok, ArtifactStore.artifact_reference()} | {:error, term()}
  def stat(%{root: root}, reference) do
    if ArtifactStore.valid_reference?(reference) and mine?(reference.locator) do
      path = object_path(root, reference.locator)

      case File.read(path) do
        {:ok, bytes} ->
          # `stat/2` is the port's locator resolver. This adapter issued a
          # digest-addressed locator, so it derives the canonical digest from its
          # own locator rather than treating a caller's lookup-probe digest as a
          # statement that locator and digest are universally the same thing.
          with {:ok, _bytes} <- verify(bytes, reference.locator) do
            {:ok,
             %{
               reference
               | digest: reference.locator,
                 size: byte_size(bytes)
             }}
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

  defp rename_into_place(path, bytes) do
    temporary = path <> ".tmp-" <> Integer.to_string(System.unique_integer([:positive]))

    with :ok <- write_synced(temporary, bytes),
         :ok <- File.rename(temporary, path),
         :ok <- sync_directory(Path.dirname(path)) do
      :ok
    else
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

  defp ensure_object_directory(root, directory) do
    with :ok <- File.mkdir_p(directory),
         :ok <- sync_directory(root) do
      :ok
    end
  end

  defp verify(bytes, digest) do
    if Canonical.digest_bytes(bytes) == digest,
      do: {:ok, bytes},
      else: {:error, :artifact_integrity_failed}
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
  defp mine?(locator), do: String.match?(locator, ~r/^[0-9a-f]{64}$/)

  # Concept: two levels of fan-out, so a directory does not grow without bound.
  #
  # Technical depth: the first two hex characters name a subdirectory. That keeps
  # any one directory to at most 256 entries at the top level, which matters on
  # filesystems whose directory lookup degrades with size.
  defp object_path(root, digest) do
    Path.join([root, binary_part(digest, 0, 2), digest])
  end
end
