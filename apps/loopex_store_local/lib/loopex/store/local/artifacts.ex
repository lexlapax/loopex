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

  Writes go to a temporary name in the same directory and are renamed into place,
  which is the same discipline the local store already uses for its journal. A
  reader therefore never observes a partially written object: the rename is
  atomic within a filesystem, and a crash mid-write leaves a temporary file that
  belongs to nothing rather than a truncated artifact that looks complete.

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

        with :ok <- File.mkdir_p(Path.dirname(path)),
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
    if ArtifactStore.valid_reference?(reference) do
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
  def stat(%{root: root} = handle, reference) do
    if ArtifactStore.valid_reference?(reference) do
      path = object_path(root, reference.locator)

      case File.stat(path) do
        {:ok, %File.Stat{size: size}} ->
          # The size is read from the object rather than echoed from the
          # reference, so a reference claiming a size the object does not have is
          # caught here rather than believed.
          if size == reference.size,
            do: {:ok, reference},
            else: verify_by_reading(handle, reference)

        {:error, :enoent} ->
          {:error, :unknown_artifact}

        {:error, reason} ->
          {:error, {:artifact_unreadable, reason}}
      end
    else
      {:error, :unknown_artifact}
    end
  end

  defp verify_by_reading(handle, reference) do
    case fetch(handle, reference) do
      {:ok, _bytes} -> {:ok, reference}
      {:error, reason} -> {:error, reason}
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
        :ok

      {:ok, _different} ->
        rename_into_place(path, bytes)

      {:error, :enoent} ->
        rename_into_place(path, bytes)

      {:error, reason} ->
        {:error, {:artifact_unwritable, reason, digest}}
    end
  end

  defp rename_into_place(path, bytes) do
    temporary = path <> ".tmp-" <> Integer.to_string(System.unique_integer([:positive]))

    with :ok <- File.write(temporary, bytes),
         :ok <- File.rename(temporary, path) do
      :ok
    else
      {:error, reason} ->
        _ = File.rm(temporary)
        {:error, {:artifact_unwritable, reason}}
    end
  end

  defp verify(bytes, digest) do
    if Canonical.digest_bytes(bytes) == digest,
      do: {:ok, bytes},
      else: {:error, :artifact_integrity_failed}
  end

  # Concept: two levels of fan-out, so a directory does not grow without bound.
  #
  # Technical depth: the first two hex characters name a subdirectory. That keeps
  # any one directory to at most 256 entries at the top level, which matters on
  # filesystems whose directory lookup degrades with size.
  defp object_path(root, digest) do
    Path.join([root, binary_part(digest, 0, 2), digest])
  end
end
