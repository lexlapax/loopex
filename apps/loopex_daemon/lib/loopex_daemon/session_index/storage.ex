defmodule LoopexDaemon.SessionIndex.Storage do
  @moduledoc """
  ## Concept

  The daemon owns one durable session-list image inside its private directory.
  Startup reads only a complete, bounded, identity-stable image; publication
  replaces the whole image atomically and never changes Store bytes.

  ## Technical depth

  The directory is same-uid mode `0700`; canonical and temporary images are
  same-uid regular files at mode `0600`. Reads compare the directory and file's
  no-follow identity before open, the opened descriptor before reading, and the
  named identities after the bounded read. Publication exclusively creates the
  one `.next` sibling, retains its descriptor identity, syncs and closes it,
  renames it over the canonical image, then syncs the directory. A pre-rename
  failure is retryable only when exact-attempt cleanup and directory sync both
  succeed. A post-rename directory-sync failure reports that the complete new
  image is named but its crash durability is unknown.
  """

  require Logger

  alias LoopexDaemon.SessionIndex.Codec

  @directory_permissions 0o700
  @file_permissions 0o600
  @permission_mask 0o777
  @canonical_name "session-index-v1"
  @temporary_name "session-index-v1.next"

  @typedoc false
  @type write_failure ::
          {:session_index_write_failed, :retryable | :poisoned | :renamed}

  @doc false
  @spec prepare(Path.t(), non_neg_integer()) ::
          :ok | {:error, :socket_permission_unverified | :session_index_corrupt}
  def prepare(directory, daemon_uid)
      when is_binary(directory) and is_integer(daemon_uid) and daemon_uid >= 0 do
    Logger.debug("loopex daemon session index directory prepare")

    with :ok <- ensure_directory(directory, daemon_uid),
         :ok <- recover_temporary(directory, daemon_uid) do
      Logger.debug("loopex daemon session index directory ready")
      :ok
    end
  end

  @doc false
  @spec load(Path.t(), non_neg_integer()) ::
          {:ok, :missing | [Codec.row()]}
          | {:error, :session_index_too_large | :session_index_corrupt}
  def load(directory, daemon_uid)
      when is_binary(directory) and is_integer(daemon_uid) and daemon_uid >= 0 do
    Logger.debug("loopex daemon session index load")
    path = Path.join(directory, @canonical_name)

    case stable_read(path, directory, daemon_uid) do
      {:ok, :missing} = missing ->
        missing

      {:ok, bytes} ->
        case Codec.decode(bytes) do
          {:ok, _rows} = loaded ->
            Logger.debug("loopex daemon session index loaded")
            loaded

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Concept: publication's one step a real filesystem cannot be made to fail
  # on demand, syncing the directory after the rename, can be replaced by a
  # caller so its `:renamed` outcome is provable.
  #
  # Technical depth: `options` accepts only `:sync_directory`, a one-argument
  # function returning `:ok` or `{:error, reason}`, used for the post-rename
  # directory sync alone; every other step is the real filesystem.
  @doc false
  @spec publish(Path.t(), non_neg_integer(), [Codec.row()], keyword()) ::
          :ok
          | {:error, :session_index_full | :invalid_index_entry | write_failure()}
  def publish(directory, daemon_uid, rows, options \\ [])
      when is_binary(directory) and is_integer(daemon_uid) and daemon_uid >= 0 and
             is_list(options) do
    Logger.debug("loopex daemon session index publication start")
    sync_after = Keyword.get(options, :sync_directory, &sync_directory/1)

    with {:ok, image} <- Codec.encode(rows) do
      publish_image(directory, daemon_uid, image, sync_after)
    end
  end

  defp ensure_directory(directory, daemon_uid) do
    case File.lstat(directory) do
      {:error, :enoent} ->
        create_directory(directory, daemon_uid)

      {:ok, %File.Stat{} = stat} ->
        verify_directory(stat, daemon_uid)

      {:error, _reason} ->
        {:error, :socket_permission_unverified}
    end
  end

  defp create_directory(directory, daemon_uid) do
    parent = Path.dirname(directory)

    with :ok <- File.mkdir(directory),
         :ok <- File.chmod(directory, @directory_permissions),
         {:ok, %File.Stat{} = stat} <- File.lstat(directory),
         :ok <- verify_directory(stat, daemon_uid),
         :ok <- sync_directory(parent) do
      :ok
    else
      _other -> {:error, :socket_permission_unverified}
    end
  end

  defp verify_directory(%File.Stat{type: :directory, uid: daemon_uid, mode: mode}, daemon_uid) do
    if Bitwise.band(mode, @permission_mask) == @directory_permissions,
      do: :ok,
      else: {:error, :socket_permission_unverified}
  end

  defp verify_directory(%File.Stat{}, _daemon_uid),
    do: {:error, :socket_permission_unverified}

  defp recover_temporary(directory, daemon_uid) do
    path = Path.join(directory, @temporary_name)

    case File.lstat(path) do
      {:error, :enoent} ->
        :ok

      {:ok, %File.Stat{type: :regular, uid: ^daemon_uid}} ->
        with :ok <- File.rm(path),
             :ok <- sync_directory(directory) do
          Logger.debug("loopex daemon session index temporary recovered")
          :ok
        else
          _other -> {:error, :session_index_corrupt}
        end

      _other ->
        {:error, :session_index_corrupt}
    end
  end

  defp stable_read(path, directory, daemon_uid) do
    with {:ok, expected_directory} <- directory_identity(directory, daemon_uid),
         {:ok, expected} <- named_file_identity(path, daemon_uid),
         {:ok, io} <- :file.open(String.to_charlist(path), [:raw, :binary, :read]) do
      result =
        with {:ok, ^expected} <- opened_file_identity(io, daemon_uid),
             {:ok, ^expected_directory} <- directory_identity(directory, daemon_uid),
             {:ok, contents} <- read_bounded(io, Codec.max_file_bytes() + 1),
             true <- byte_size(contents) <= Codec.max_file_bytes(),
             {:ok, ^expected_directory} <- directory_identity(directory, daemon_uid),
             {:ok, ^expected} <- named_file_identity(path, daemon_uid) do
          {:ok, contents}
        else
          false -> {:error, :session_index_too_large}
          {:error, :session_index_too_large} = error -> error
          _other -> {:error, :session_index_corrupt}
        end

      case {result, :file.close(io)} do
        {{:ok, _contents} = success, :ok} -> success
        {{:error, _reason} = error, _close} -> error
        {{:ok, _contents}, {:error, _reason}} -> {:error, :session_index_corrupt}
      end
    else
      {:error, :enoent} -> {:ok, :missing}
      {:error, :session_index_too_large} = error -> error
      _other -> {:error, :session_index_corrupt}
    end
  end

  defp publish_image(directory, daemon_uid, image, sync_after) do
    canonical = Path.join(directory, @canonical_name)
    temporary = Path.join(directory, @temporary_name)

    with {:ok, _identity} <- directory_identity(directory, daemon_uid) do
      case :file.open(String.to_charlist(temporary), [:raw, :binary, :write, :exclusive]) do
        {:ok, io} ->
          publish_opened(io, temporary, canonical, directory, daemon_uid, image, sync_after)

        {:error, _reason} ->
          write_failure(:poisoned)
      end
    else
      _other -> write_failure(:poisoned)
    end
  end

  defp publish_opened(io, temporary, canonical, directory, daemon_uid, image, sync_after) do
    case opened_attempt_identity(io, temporary, daemon_uid) do
      {:ok, identity} ->
        result =
          with :ok <- File.chmod(temporary, @file_permissions),
               {:ok, ^identity} <- publication_identity(temporary, daemon_uid),
               :ok <- :file.write(io, image),
               :ok <- :file.sync(io),
               :ok <- :file.close(io),
               :ok <- File.rename(temporary, canonical) do
            sync_after_rename(directory, sync_after)
          else
            _other -> :pre_rename_failed
          end

        case result do
          :ok ->
            Logger.debug("loopex daemon session index publication complete")
            :ok

          :post_rename_failed ->
            write_failure(:renamed)

          :pre_rename_failed ->
            _ = :file.close(io)
            cleanup_failed_attempt(temporary, directory, daemon_uid, identity)
        end

      {:error, _reason} ->
        _ = :file.close(io)
        write_failure(:poisoned)
    end
  end

  defp sync_after_rename(directory, sync_after) do
    case sync_after.(directory) do
      :ok -> :ok
      {:error, _reason} -> :post_rename_failed
    end
  end

  defp cleanup_failed_attempt(temporary, directory, daemon_uid, identity) do
    with {:ok, ^identity} <- publication_identity(temporary, daemon_uid),
         :ok <- File.rm(temporary),
         :ok <- sync_directory(directory) do
      write_failure(:retryable)
    else
      _other -> write_failure(:poisoned)
    end
  end

  defp opened_attempt_identity(io, path, daemon_uid) do
    with {:ok, record} <- :file.read_file_info(io),
         %File.Stat{type: :regular, uid: ^daemon_uid} = opened <- File.Stat.from_record(record),
         {:ok, %File.Stat{type: :regular, uid: ^daemon_uid} = named} <- File.lstat(path),
         true <- same_inode?(opened, named) do
      {:ok, publication_identity(opened)}
    else
      _other -> {:error, :identity_unverified}
    end
  end

  defp publication_identity(path, daemon_uid) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular, uid: ^daemon_uid} = stat} ->
        {:ok, publication_identity(stat)}

      _other ->
        {:error, :identity_unverified}
    end
  end

  defp publication_identity(stat),
    do: {stat.major_device, stat.minor_device, stat.inode}

  defp named_file_identity(path, daemon_uid) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular, uid: ^daemon_uid, size: size, mode: mode} = stat}
      when size <= 4 * 1_024 * 1_024 ->
        if Bitwise.band(mode, @permission_mask) == @file_permissions,
          do: {:ok, read_identity(stat)},
          else: {:error, :invalid_mode}

      {:ok, %File.Stat{type: :regular, uid: ^daemon_uid}} ->
        {:error, :session_index_too_large}

      {:error, :enoent} ->
        {:error, :enoent}

      _other ->
        {:error, :invalid_file}
    end
  end

  defp opened_file_identity(io, daemon_uid) do
    case :file.read_file_info(io) do
      {:ok, record} ->
        case File.Stat.from_record(record) do
          %File.Stat{type: :regular, uid: ^daemon_uid, size: size, mode: mode} = stat
          when size <= 4 * 1_024 * 1_024 ->
            if Bitwise.band(mode, @permission_mask) == @file_permissions,
              do: {:ok, read_identity(stat)},
              else: {:error, :invalid_mode}

          %File.Stat{type: :regular, uid: ^daemon_uid} ->
            {:error, :session_index_too_large}

          %File.Stat{} ->
            {:error, :invalid_file}
        end

      {:error, _reason} ->
        {:error, :invalid_file}
    end
  end

  defp directory_identity(directory, daemon_uid) do
    case File.lstat(directory) do
      {:ok, %File.Stat{type: :directory, uid: ^daemon_uid, mode: mode} = stat} ->
        if Bitwise.band(mode, @permission_mask) == @directory_permissions,
          do: {:ok, {stat.major_device, stat.minor_device, stat.inode}},
          else: {:error, :invalid_directory}

      _other ->
        {:error, :invalid_directory}
    end
  end

  defp read_identity(stat),
    do: {stat.major_device, stat.minor_device, stat.inode, stat.size}

  defp same_inode?(left, right),
    do:
      left.major_device == right.major_device and
        left.minor_device == right.minor_device and left.inode == right.inode

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

      {:error, _reason} ->
        {:error, :read_failed}
    end
  end

  defp sync_directory(path) do
    case :file.open(String.to_charlist(path), [:raw, :read, :directory]) do
      {:ok, io} ->
        sync_result = :file.sync(io)
        close_result = :file.close(io)

        case {sync_result, close_result} do
          {:ok, :ok} -> :ok
          _other -> {:error, :directory_sync_failed}
        end

      {:error, _reason} ->
        {:error, :directory_sync_failed}
    end
  end

  defp write_failure(disposition) do
    Logger.debug("loopex daemon session index publication failed")
    {:error, {:session_index_write_failed, disposition}}
  end
end
