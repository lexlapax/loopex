defmodule Loopex.Executor.Local.WorkspaceLease do
  @moduledoc """
  ## Concept

  A live trusted-local claim on one workspace. Jobs bind its plain lease ID and
  fence; the executor privately monitors this holder for the job's full life.

  ## Technical depth

  The pid and filesystem path stay inside the local hand and never enter a job,
  grant, or receipt. Stopping the holder revokes the lease and produces a DOWN
  signal that the executor treats as cancellation evidence, never success.
  """

  use GenServer

  @doc """
  ## Concept

  Starts one lease over an existing workspace directory.

  ## Technical depth

  The caller supplies the durable plain identity and current fence separately
  from the private path and process identity.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options) when is_list(options), do: GenServer.start_link(__MODULE__, options)

  @doc """
  ## Concept

  Resolves the live lease for the local executor that already holds its pid.

  ## Technical depth

  A mismatched ID is refused rather than allowing the pid to define job
  authority. The returned path remains private to the edge.
  """
  @spec resolve(pid(), binary()) :: {:ok, map()} | {:error, term()}
  def resolve(pid, lease_id) when is_pid(pid) and is_binary(lease_id) do
    try do
      GenServer.call(pid, {:resolve, lease_id})
    catch
      :exit, _reason -> {:error, :workspace_lease_lost}
    end
  end

  @doc """
  ## Concept

  Records that one bounded effect reached its completion boundary while this
  workspace lease was still live.

  ## Technical depth

  The effect has already placed its potentially large result in an ephemeral ETS
  row whose table identifier is held only by the bounded-work processes. The
  table is public solely so this separate lease process can update it. This call
  changes only the row's small certificate fields, inside the lease holder
  itself, so lease death and completion cannot be decided by the arrival order
  of independent messages. The caller supplies the owner and already-sampled
  bound fact; a failure to update the row certifies nothing.
  """
  @spec certify_completion(pid(), :ets.tid(), reference(), pid() | nil) ::
          :ok | {:error, :workspace_lease_lost | :completion_certificate_unavailable}
  def certify_completion(pid, table, tag, owner)
      when is_pid(pid) and is_reference(tag) and (is_pid(owner) or is_nil(owner)) do
    try do
      GenServer.call(pid, {:certify_completion, table, tag, owner}, :infinity)
    catch
      :exit, _reason -> {:error, :workspace_lease_lost}
    end
  end

  @impl GenServer
  def init(options) do
    id = Keyword.fetch!(options, :id)
    path = Keyword.fetch!(options, :path)
    fencing_token = Keyword.fetch!(options, :fencing_token)

    if is_binary(id) and byte_size(id) > 0 and is_binary(path) and File.dir?(path) and
         is_integer(fencing_token) and fencing_token >= 0 do
      {:ok, %{id: id, path: Path.expand(path), fencing_token: fencing_token}}
    else
      {:stop, :invalid_workspace_lease}
    end
  end

  @impl GenServer
  def handle_call({:resolve, id}, _from, %{id: id} = state) do
    {:reply, {:ok, Map.take(state, [:id, :path, :fencing_token])}, state}
  end

  def handle_call({:resolve, _wrong}, _from, state),
    do: {:reply, {:error, :workspace_lease_mismatch}, state}

  def handle_call({:certify_completion, table, tag, owner}, _from, state) do
    certified =
      try do
        owner_held = not is_pid(owner) or Process.alive?(owner)

        case :ets.update_element(table, tag, [
               {2, :certified},
               {3, true},
               {4, owner_held}
             ]) do
          true -> :ok
          false -> {:error, :completion_certificate_unavailable}
        end
      rescue
        ArgumentError -> {:error, :completion_certificate_unavailable}
      catch
        _kind, _reason -> {:error, :completion_certificate_unavailable}
      end

    {:reply, certified, state}
  end

  @impl GenServer
  def format_status(status) do
    status
    |> Map.put(:state, :redacted_workspace_lease_state)
    |> Map.put(:message, :redacted_workspace_lease_message)
    |> Map.put(:reason, :redacted_workspace_lease_reason)
  end
end
