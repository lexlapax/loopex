defmodule Loopex.SessionDirectory do
  @moduledoc """
  ## Concept

  Resolves an operator's state root and the durable `runtime_id` placement
  identity a prior process left there, so a fresh operating-system process
  re-presents the same placement. The sessions a root knows about are listed by
  the daemon session index, which offline commands also write; this module
  keeps no session catalog of its own.

  ## Technical depth

  `runtime_id` is one plain file under the resolved root. It is not Store
  durable truth; it is generated once and persisted so a restart does not
  strand every session a fresh random value would orphan.

  Every read here uses `System.fetch_env/1`, never `Application.get_env` or a
  compile-time default, because per-runtime placement identity is exactly the
  state class ADR 0001 and `mix loopex.core_only` forbid core from hiding in
  VM-global application environment.
  """

  @max_identifier_bytes 256
  @max_runtime_id_file_bytes 1_024
  @temporary_name_bytes 16

  # Technical depth: bounded so a pathologically contended entry fails with a
  # reason rather than spinning.
  @runtime_id_filename "runtime_id"
  @runtime_id_prefix "runtime_"
  @runtime_id_random_bytes 16

  @doc """
  ## Concept

  Resolves this host's session-directory state root.

  ## Technical depth

  Reads only the `LOOPEX_HOME` process environment variable and expands it to
  an absolute path; application environment is never consulted; a missing or
  empty value is refused rather than defaulted, because a silently invented
  root would let two hosts collide on `/` or read each other's sessions.
  """
  @spec state_root() :: {:ok, Path.t()} | {:error, :loopex_home_required}
  def state_root do
    case System.fetch_env("LOOPEX_HOME") do
      {:ok, value} when is_binary(value) and byte_size(value) > 0 ->
        {:ok, Path.expand(value)}

      _other ->
        {:error, :loopex_home_required}
    end
  end

  @doc """
  ## Concept

  This host's durable `runtime_id` placement identity for the given state root,
  generating and persisting one on first use.

  ## Technical depth

  The first caller against an empty root wins: the identity file is created
  with POSIX `O_EXCL` semantics, so a concurrent first caller either creates it
  or reads back exactly what the winner wrote, and no caller ever overwrites an
  existing value. Every later call, including one from a fresh operating-system
  process, re-presents that same persisted value -- which is what makes it
  placement identity rather than a per-invocation token.
  """
  @spec runtime_id(Path.t()) :: {:ok, binary()} | {:error, term()}
  def runtime_id(root) when is_binary(root) and byte_size(root) > 0 do
    runtime_id(root, [])
  end

  def runtime_id(_root), do: {:error, :invalid_state_root}

  @doc false
  @spec runtime_id(Path.t(), keyword()) :: {:ok, binary()} | {:error, term()}
  def runtime_id(root, options)
      when is_binary(root) and byte_size(root) > 0 and is_list(options) do
    path = runtime_id_path(root)
    before_publish = Keyword.get(options, :before_publish, fn -> :ok end)

    with :ok <- ensure_directory_durable(root) do
      case read_durable_runtime_id(path) do
        {:ok, runtime_id} ->
          {:ok, runtime_id}

        {:error, :enoent} ->
          generate_and_persist_runtime_id(path, before_publish)

        {:error, :corrupt_runtime_id} = error ->
          error

        {:error, reason} ->
          {:error, {:runtime_id_unreadable, reason}}
      end
    else
      {:error, reason} -> {:error, {:state_root_unavailable, reason}}
    end
  end

  def runtime_id(_root, _options), do: {:error, :invalid_state_root}

  defp runtime_id_path(root), do: Path.join(root, @runtime_id_filename)

  # Concept: only the first writer against an absent identity file may choose
  # the value every later process re-presents.
  #
  # Technical depth: the candidate is written and synced under a private name,
  # then hard-linked into the public name. Link creation is the one no-replace
  # publication step: a reader can see either no `runtime_id` or the complete,
  # synced inode, never the empty/partial interval between `O_EXCL` and write.
  # Two publishers may prepare candidates, but exactly one link succeeds and
  # every loser durably reads the winner. The hook is a test-only seam at that
  # exact election boundary.
  defp generate_and_persist_runtime_id(path, before_publish) do
    candidate = fresh_runtime_id()
    tmp = temporary_path(path)

    case File.open(tmp, [:write, :exclusive]) do
      {:ok, io} ->
        write_result =
          with :ok <- IO.binwrite(io, candidate),
               :ok <- :file.sync(io) do
            :ok
          end

        close_result = File.close(io)

        prepared =
          case {write_result, close_result} do
            {:ok, :ok} -> :ok
            {{:error, reason}, _close} -> {:error, {:runtime_id_write_failed, reason}}
            {:ok, {:error, reason}} -> {:error, {:runtime_id_close_failed, reason}}
          end

        result =
          with :ok <- prepared,
               :ok <- before_publish.() do
            publish_runtime_id(tmp, path)
          end

        case result do
          :ok ->
            {:ok, candidate}

          {:winner, runtime_id} ->
            {:ok, runtime_id}

          {:error, _reason} = error ->
            error
        end
        |> tap(fn _result -> File.rm(tmp) end)

      {:error, reason} ->
        {:error, {:runtime_id_persist_failed, reason}}
    end
  end

  defp publish_runtime_id(tmp, path) do
    case File.ln(tmp, path) do
      :ok ->
        case sync_runtime_id_directory(path) do
          :ok -> :ok
          {:error, _reason} = error -> error
        end

      {:error, :eexist} ->
        case read_durable_runtime_id(path) do
          {:ok, runtime_id} -> {:winner, runtime_id}
          {:error, _reason} = error -> error
        end

      {:error, reason} ->
        {:error, {:runtime_id_persist_failed, reason}}
    end
  end

  defp read_durable_runtime_id(path) do
    with {:ok, contents} <- read_regular_file(path, @max_runtime_id_file_bytes, true),
         {:ok, runtime_id} <- decode_runtime_id(contents),
         :ok <- sync_runtime_id_directory(path) do
      {:ok, runtime_id}
    else
      {:error, :enoent} = error ->
        error

      {:error, :corrupt_runtime_id} = error ->
        error

      {:error, reason} when reason in [:not_regular, :replaced, :too_large] ->
        {:error, :corrupt_runtime_id}

      {:error, {:runtime_id_directory_sync_failed, _reason}} = error ->
        error

      {:error, {:runtime_id_directory_close_failed, _reason}} = error ->
        error

      {:error, {:runtime_id_directory_unavailable, _reason}} = error ->
        error

      {:error, reason} ->
        {:error, {:runtime_id_unreadable, reason}}
    end
  end

  defp sync_runtime_id_directory(path) do
    directory = path |> Path.dirname() |> String.to_charlist()

    case :file.open(directory, [:raw, :read, :directory]) do
      {:ok, io} ->
        result = :file.sync(io)
        close_result = :file.close(io)

        case {result, close_result} do
          {:ok, :ok} -> :ok
          {{:error, reason}, _close} -> {:error, {:runtime_id_directory_sync_failed, reason}}
          {:ok, {:error, reason}} -> {:error, {:runtime_id_directory_close_failed, reason}}
        end

      {:error, reason} ->
        {:error, {:runtime_id_directory_unavailable, reason}}
    end
  end

  defp fresh_runtime_id do
    @runtime_id_prefix <>
      (:crypto.strong_rand_bytes(@runtime_id_random_bytes) |> Base.encode16(case: :lower))
  end

  defp decode_runtime_id(contents) do
    trimmed = String.trim(contents)

    if byte_size(trimmed) > 0 and byte_size(trimmed) <= @max_identifier_bytes do
      {:ok, trimmed}
    else
      {:error, :corrupt_runtime_id}
    end
  end

  defp ensure_directory_durable(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} ->
        parent = Path.dirname(path)
        if parent == path, do: :ok, else: sync_directory(parent)

      {:ok, _other} ->
        {:error, :not_directory}

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
        with :ok <- ensure_directory(path),
             :ok <- sync_directory(parent) do
          :ok
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp ensure_directory(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} -> :ok
      {:ok, _other} -> {:error, :not_directory}
      {:error, reason} -> {:error, reason}
    end
  end

  defp sync_directory(path) do
    case :file.open(String.to_charlist(path), [:raw, :read, :directory]) do
      {:ok, io} ->
        sync_result = :file.sync(io)
        close_result = :file.close(io)

        case {sync_result, close_result} do
          {:ok, :ok} -> :ok
          {{:error, reason}, _close} -> {:error, reason}
          {:ok, {:error, reason}} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp temporary_path(path) do
    suffix = :crypto.strong_rand_bytes(@temporary_name_bytes) |> Base.url_encode64(padding: false)
    path <> ".tmp-" <> suffix
  end

  # Concept: a durable directory entry is read from the ordinary file that the
  # directory still names, never through a link or from an unbounded object.
  #
  # Technical depth: lstat refuses a static symlink, FIFO, device, or directory
  # before open. The opened descriptor is checked against that exact inode
  # before any byte is read and the path is checked again afterwards, so a
  # replacement cannot substitute outside bytes. Reading stops at one byte past
  # the caller's limit and therefore decides oversize without loading the rest
  # of a hostile file.
  defp read_regular_file(path, limit, sync?) do
    directory = Path.dirname(path)

    with {:ok, expected_directory} <- directory_identity(directory),
         {:ok, expected} <- regular_file_identity(path, limit),
         {:ok, io} <- :file.open(String.to_charlist(path), [:raw, :binary, :read]) do
      try do
        with {:ok, ^expected} <- opened_file_identity(io, limit),
             {:ok, ^expected_directory} <- directory_identity(directory),
             {:ok, contents} <- read_bounded(io, limit + 1),
             true <- byte_size(contents) <= limit,
             :ok <- maybe_sync_file(io, sync?),
             {:ok, ^expected_directory} <- directory_identity(directory),
             {:ok, ^expected} <- regular_file_identity(path, limit) do
          {:ok, contents}
        else
          false -> {:error, :too_large}
          {:ok, _different} -> {:error, :replaced}
          {:error, _reason} = error -> error
        end
      after
        :file.close(io)
      end
    else
      {:error, _reason} = error -> error
    end
  end

  defp maybe_sync_file(_io, false), do: :ok
  defp maybe_sync_file(io, true), do: :file.sync(io)

  defp regular_file_identity(path, limit) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular, size: size} = stat} when size <= limit ->
        {:ok, file_identity(stat)}

      {:ok, %File.Stat{type: :regular}} ->
        {:error, :too_large}

      {:ok, _non_regular} ->
        {:error, :not_regular}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp directory_identity(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory} = stat} ->
        {:ok, {stat.major_device, stat.inode}}

      {:ok, _not_directory} ->
        {:error, :not_directory}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp opened_file_identity(io, limit) do
    case :file.read_file_info(io) do
      {:ok, record} ->
        case File.Stat.from_record(record) do
          %File.Stat{type: :regular, size: size} = stat when size <= limit ->
            {:ok, file_identity(stat)}

          %File.Stat{type: :regular} ->
            {:error, :too_large}

          %File.Stat{} ->
            {:error, :not_regular}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp file_identity(stat), do: {stat.major_device, stat.inode, stat.size}

  defp read_bounded(io, remaining, chunks \\ [])

  defp read_bounded(_io, 0, chunks),
    do: {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary()}

  defp read_bounded(io, remaining, chunks) do
    case :file.read(io, remaining) do
      {:ok, bytes} when is_binary(bytes) and byte_size(bytes) > 0 ->
        read_bounded(io, remaining - byte_size(bytes), [bytes | chunks])

      {:ok, ""} ->
        {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary()}

      :eof ->
        {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary()}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
