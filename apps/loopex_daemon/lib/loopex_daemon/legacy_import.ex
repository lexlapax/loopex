defmodule LoopexDaemon.LegacyImport do
  @moduledoc """
  ## Concept

  Reads a released state root's session directory strictly, so the daemon's
  first index says exactly what that directory records. Where the released
  listing quietly skips an entry it cannot read, the import refuses the whole
  directory: an operator moving a root to the daemon learns about a damaged
  entry now rather than finding a session silently missing from every
  listing later.

  ## Technical depth

  `scan/3` opens `sessions/` without following a symbolic link, requires its
  owner to be the placement owner's uid, and retains its owner, type, device
  and inode. It materializes the names once, excludes only names containing
  `.tmp-`, and rechecks the directory identity. Every remaining name must be a
  contained session ID naming a regular non-symlink file, read identity-stably
  within the released 1 MiB ceiling plus one byte, not a compressed external
  term, safely decoded to exactly `session_id`, `runtime_id` and `commands`,
  with the stored ID equal to the name, a valid runtime ID, at most 4,096
  commands with valid IDs, and every cached result equal to the session ID.
  Any entry failing a check is `session_index_corrupt`; failing to open, list
  or keep the directory's identity is `state_root_unusable`. A missing
  directory is an empty legacy population. The metadata function is a seam so
  tests can prove the owner checks without filesystem privileges.
  """

  import Bitwise, only: [&&&: 2]

  @max_identifier_bytes 256
  @max_entry_bytes 1_048_576
  @max_commands 4_096

  @typedoc false
  @type row :: %{session_id: binary(), placement_identity: binary()}

  @doc false
  @spec scan(Path.t(), non_neg_integer(), (Path.t() -> {:ok, File.Stat.t()} | {:error, term()})) ::
          {:ok, [row()]} | {:error, :state_root_unusable | :session_index_corrupt}
  def scan(state_root, owner_uid, lstat \\ &File.lstat/1) do
    directory = Path.join(state_root, "sessions")

    case lstat.(directory) do
      {:error, :enoent} ->
        {:ok, []}

      {:ok, %File.Stat{type: :directory, uid: ^owner_uid} = stat} ->
        scan_directory(directory, identity(stat), owner_uid, lstat)

      _other ->
        {:error, :state_root_unusable}
    end
  end

  defp scan_directory(directory, expected, owner_uid, lstat) do
    with {:ok, names} <- list(directory),
         {:ok, %File.Stat{type: :directory, uid: ^owner_uid} = stat} <- lstat.(directory),
         true <- identity(stat) == expected do
      names
      |> Enum.reject(&String.contains?(&1, ".tmp-"))
      |> Enum.sort()
      |> Enum.reduce_while({:ok, []}, fn name, {:ok, rows} ->
        case read_entry(directory, name) do
          {:ok, row} -> {:cont, {:ok, [row | rows]}}
          :error -> {:halt, {:error, :session_index_corrupt}}
        end
      end)
      |> case do
        {:ok, rows} -> {:ok, Enum.reverse(rows)}
        error -> error
      end
    else
      _changed -> {:error, :state_root_unusable}
    end
  end

  defp list(directory) do
    case File.ls(directory) do
      {:ok, names} -> {:ok, names}
      {:error, _reason} -> :error
    end
  end

  defp read_entry(directory, name) do
    with true <- contained?(name),
         {:ok, contents} <- stable_read(Path.join(directory, name)),
         false <- compressed?(contents),
         entry = :erlang.binary_to_term(contents, [:safe]),
         %{session_id: ^name, runtime_id: runtime_id, commands: commands} <- entry,
         true <- Enum.sort(Map.keys(entry)) == [:commands, :runtime_id, :session_id],
         true <- identifier?(runtime_id),
         true <- commands?(commands, name) do
      {:ok, %{session_id: name, placement_identity: runtime_id}}
    else
      _invalid -> :error
    end
  rescue
    ArgumentError -> :error
  end

  defp contained?(name) do
    byte_size(name) in 1..@max_identifier_bytes and name not in [".", ".."] and
      not String.contains?(name, ["/", "\\", <<0>>])
  end

  # Concept: an entry is read only while it stays the same regular file.
  defp stable_read(path) do
    with {:ok, %File.Stat{type: :regular, size: size} = before} when size <= @max_entry_bytes <-
           File.lstat(path),
         {:ok, io} <- :file.open(String.to_charlist(path), [:raw, :binary, :read]) do
      try do
        with {:ok, contents} <- read_bounded(io),
             true <- byte_size(contents) <= @max_entry_bytes,
             {:ok, %File.Stat{type: :regular} = later} <- File.lstat(path),
             true <- identity(later) == identity(before) do
          {:ok, contents}
        else
          _changed -> :error
        end
      after
        :file.close(io)
      end
    else
      _other -> :error
    end
  end

  defp read_bounded(io) do
    case :file.read(io, @max_entry_bytes + 1) do
      {:ok, contents} -> {:ok, contents}
      :eof -> {:ok, ""}
      error -> error
    end
  end

  defp compressed?(<<131, 80, _rest::binary>>), do: true
  defp compressed?(_contents), do: false

  defp commands?(commands, session_id) when is_map(commands) do
    map_size(commands) <= @max_commands and
      Enum.all?(commands, fn {command_id, result} ->
        identifier?(command_id) and result == session_id
      end)
  end

  defp commands?(_commands, _session_id), do: false

  defp identifier?(value) do
    is_binary(value) and byte_size(value) in 1..@max_identifier_bytes and String.valid?(value) and
      not String.contains?(value, <<0>>)
  end

  defp identity(%File.Stat{} = stat),
    do: {stat.uid, stat.type, stat.major_device, stat.inode, stat.mode &&& 0o777}
end
