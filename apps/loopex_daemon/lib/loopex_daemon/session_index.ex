defmodule LoopexDaemon.SessionIndex do
  @moduledoc """
  ## Concept

  The daemon keeps a durable, bounded catalogue of sessions it can list. The
  catalogue is discoverability only: exact session existence still comes from
  core, and adding or failing to add a row never creates or reverses a session.

  ## Technical depth

  One unregistered GenServer serializes the in-memory rows and complete snapshot
  replacement. A fresh root gets a persisted empty image; a root whose sessions
  exist only in the retired `sessions/` catalog is refused, never imported.
  Offline commands write the same image under the same rule: only the holder of
  the root's placement lock writes, so the daemon and an offline command are
  never writers at once. Rows are monotonic and keyed by raw session-id bytes. Ordinary publication becomes
  visible only after durable replacement; a post-rename directory-sync failure
  adopts the complete named image but poisons later publication, while a proved
  pre-rename cleanup leaves the prior projection and permits retry.
  """

  use GenServer
  require Logger

  alias LoopexDaemon.SessionIndex.{Codec, Storage}

  @page_limit 256
  @index_limit 4_096

  @typedoc false
  @type page :: %{
          required(:entries) => [Codec.row()],
          required(:index_full) => boolean(),
          optional(:next_after_session_id) => binary()
        }

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options) when is_list(options) do
    GenServer.start_link(__MODULE__, options)
  end

  @doc false
  @spec record(GenServer.server(), binary(), binary()) ::
          :ok
          | {:ok, :index_full}
          | {:error, :composition_mismatch | :index_write_failed | :invalid_index_entry}
  def record(index, session_id, placement_identity) do
    GenServer.call(index, {:record, session_id, placement_identity})
  end

  @doc false
  @spec page(GenServer.server(), binary() | nil, 1..256) ::
          {:ok, page()} | {:error, :invalid_page}
  def page(index, after_session_id, limit) do
    GenServer.call(index, {:page, after_session_id, limit})
  end

  @doc false
  @spec status(GenServer.server()) :: %{
          entries: non_neg_integer(),
          limit: 4_096,
          full: boolean(),
          poisoned: boolean()
        }
  def status(index), do: GenServer.call(index, :status)

  @doc """
  ## Concept

  Records a session an offline command created, in the one catalogue the
  daemon also lists.

  ## Technical depth

  The caller holds the root's placement lock, which is what excludes the
  daemon; every offline command records only inside that hold. The image owner
  is the state root's owner, the same anchor `read_offline/1` uses; the image
  is loaded or initialized, the row decided by the same rules as `record/3`,
  and the whole image published durably. A full index answers
  `{:ok, :index_full}` and records nothing.
  """
  @spec record_offline(Path.t(), binary(), binary()) ::
          :ok
          | {:ok, :index_full}
          | {:error, atom()}
  def record_offline(state_root, session_id, placement_identity) when is_binary(state_root) do
    directory = Path.join(state_root, "daemon")

    with :ok <- validate_entry(session_id, placement_identity),
         {:ok, uid} <- root_uid(state_root),
         :ok <- Storage.prepare(directory, uid),
         {:ok, rows} <- load_or_initialize(state_root, directory, uid) do
      entries = Map.new(rows, &{&1.session_id, &1.placement_identity})

      case decide(entries, session_id, placement_identity) do
        :publish ->
          case Storage.publish(
                 directory,
                 uid,
                 rows(Map.put(entries, session_id, placement_identity))
               ) do
            :ok -> :ok
            {:error, :session_index_full} -> {:ok, :index_full}
            {:error, :invalid_index_entry} -> {:error, :invalid_index_entry}
            {:error, _write_failure} -> {:error, :index_write_failed}
          end

        decided ->
          decided
      end
    end
  end

  @doc """
  ## Concept

  Reads the catalogue for an offline listing or resume.

  ## Technical depth

  A listing holds no placement lock, so the image owner is taken as the state
  root's owner, the uid that created the root. A missing image is an empty
  catalogue unless the retired `sessions/` catalog is present, which refuses.
  """
  @spec read_offline(Path.t()) :: {:ok, [Codec.row()]} | {:error, atom()}
  def read_offline(state_root) when is_binary(state_root) do
    directory = Path.join(state_root, "daemon")

    with {:ok, uid} <- root_uid(state_root),
         {:ok, loaded} <- load_present(directory, uid) do
      case loaded do
        :missing -> missing_rows(state_root)
        rows -> {:ok, rows}
      end
    else
      {:error, reason} when reason in [:session_index_too_large, :session_index_corrupt] ->
        {:error, reason}

      _unusable ->
        {:error, :state_root_unusable}
    end
  end

  @impl true
  def init(options) do
    Logger.debug("loopex daemon session index owner start")

    with {:ok, state_root} <- required_path(options, :state_root),
         {:ok, daemon_uid} <- required_uid(options),
         directory = Path.join(state_root, "daemon"),
         :ok <- Storage.prepare(directory, daemon_uid),
         {:ok, rows} <- load_or_initialize(state_root, directory, daemon_uid) do
      entries = Map.new(rows, &{&1.session_id, &1.placement_identity})
      Logger.debug("loopex daemon session index owner ready")

      {:ok,
       %{
         directory: directory,
         daemon_uid: daemon_uid,
         entries: entries,
         poisoned: false
       }}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call({:record, session_id, placement_identity}, _from, state) do
    case validate_entry(session_id, placement_identity) do
      :ok -> record_validated(state, session_id, placement_identity)
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:page, after_session_id, limit}, _from, state) do
    case validate_page(after_session_id, limit) do
      :ok -> {:reply, {:ok, build_page(state.entries, after_session_id, limit)}, state}
      :error -> {:reply, {:error, :invalid_page}, state}
    end
  end

  def handle_call(:status, _from, state) do
    entries = map_size(state.entries)

    {:reply,
     %{
       entries: entries,
       limit: Codec.max_entries(),
       full: entries == Codec.max_entries(),
       poisoned: state.poisoned
     }, state}
  end

  @impl true
  def terminate(_reason, _state) do
    Logger.debug("loopex daemon session index owner stop")
    :ok
  end

  defp record_validated(state, session_id, placement_identity) do
    case decide(state.entries, session_id, placement_identity) do
      :publish when state.poisoned -> {:reply, {:error, :index_write_failed}, state}
      :publish -> publish_entry(state, session_id, placement_identity)
      decided -> {:reply, decided, state}
    end
  end

  # Concept: one row decision for the daemon and offline writers alike.
  defp decide(entries, session_id, placement_identity) do
    case Map.fetch(entries, session_id) do
      {:ok, ^placement_identity} -> :ok
      {:ok, _other_placement} -> {:error, :composition_mismatch}
      :error when map_size(entries) == @index_limit -> {:ok, :index_full}
      :error -> :publish
    end
  end

  defp load_present(directory, uid) do
    case File.lstat(directory) do
      {:error, :enoent} -> {:ok, :missing}
      _present -> Storage.load(directory, uid)
    end
  end

  defp root_uid(state_root) do
    case File.stat(state_root) do
      {:ok, %File.Stat{type: :directory, uid: uid}} -> {:ok, uid}
      _unusable -> {:error, :state_root_unusable}
    end
  end

  defp publish_entry(state, session_id, placement_identity) do
    next_entries = Map.put(state.entries, session_id, placement_identity)
    rows = rows(next_entries)

    case Storage.publish(state.directory, state.daemon_uid, rows) do
      :ok ->
        {:reply, :ok, %{state | entries: next_entries}}

      {:error, {:session_index_write_failed, :retryable}} ->
        {:reply, {:error, :index_write_failed}, state}

      {:error, {:session_index_write_failed, :poisoned}} ->
        {:reply, {:error, :index_write_failed}, %{state | poisoned: true}}

      {:error, {:session_index_write_failed, :renamed}} ->
        {:reply, {:error, :index_write_failed}, %{state | entries: next_entries, poisoned: true}}

      {:error, :invalid_index_entry} ->
        {:reply, {:error, :invalid_index_entry}, state}

      {:error, :session_index_full} ->
        {:reply, {:ok, :index_full}, state}
    end
  end

  defp build_page(entries, after_session_id, limit) do
    selected =
      entries
      |> rows()
      |> Enum.drop_while(fn row ->
        not is_nil(after_session_id) and row.session_id <= after_session_id
      end)
      |> Enum.take(limit + 1)

    {page_entries, remainder} = Enum.split(selected, limit)

    result = %{
      entries: page_entries,
      index_full: map_size(entries) == Codec.max_entries()
    }

    if remainder == [] do
      result
    else
      Map.put(result, :next_after_session_id, List.last(page_entries).session_id)
    end
  end

  defp rows(entries) do
    entries
    |> Enum.map(fn {session_id, placement_identity} ->
      %{session_id: session_id, placement_identity: placement_identity}
    end)
    |> Enum.sort_by(& &1.session_id)
  end

  defp load_or_initialize(state_root, directory, daemon_uid) do
    case Storage.load(directory, daemon_uid) do
      {:ok, :missing} -> initialize_missing(state_root, directory, daemon_uid)
      {:ok, rows} when is_list(rows) -> {:ok, rows}
      {:error, reason} -> {:error, reason}
    end
  end

  defp initialize_missing(state_root, directory, daemon_uid) do
    with {:ok, []} <- missing_rows(state_root) do
      case Storage.publish(directory, daemon_uid, []) do
        :ok -> {:ok, []}
        {:error, _reason} -> {:error, :session_index_write_failed}
      end
    end
  end

  # Concept: sessions known only to the retired offline catalog are refused.
  defp missing_rows(state_root) do
    case File.lstat(Path.join(state_root, "sessions")) do
      {:error, :enoent} -> {:ok, []}
      {:ok, %File.Stat{type: :directory}} -> {:error, :session_catalog_retired}
      _other -> {:error, :session_index_corrupt}
    end
  end

  defp validate_entry(session_id, placement_identity) do
    if is_binary(session_id) and byte_size(session_id) in 1..256 and
         is_binary(placement_identity) and byte_size(placement_identity) in 1..256,
       do: :ok,
       else: {:error, :invalid_index_entry}
  end

  defp validate_page(after_session_id, limit) do
    valid_cursor =
      is_nil(after_session_id) or
        (is_binary(after_session_id) and byte_size(after_session_id) in 1..256)

    if valid_cursor and is_integer(limit) and limit in 1..@page_limit,
      do: :ok,
      else: :error
  end

  defp required_path(options, key) do
    case Keyword.fetch(options, key) do
      {:ok, path} when is_binary(path) -> {:ok, path}
      _other -> {:error, :invalid_index_configuration}
    end
  end

  defp required_uid(options) do
    case Keyword.fetch(options, :daemon_uid) do
      {:ok, uid} when is_integer(uid) and uid >= 0 -> {:ok, uid}
      _other -> {:error, :invalid_index_configuration}
    end
  end
end
