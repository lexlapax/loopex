defmodule LoopexCli.SessionCatalog do
  @moduledoc """
  ## Concept

  Offline commands keep one session catalogue per state root: the daemon
  session index. A session an offline command creates is listed by `loopex
  sessions` and by the daemon alike, and `resume` reaches a session only under
  the placement identity that created it.

  ## Technical depth

  Accepted ADR 0070 retires the separate offline `sessions/` directory; a root
  whose sessions exist only there is refused as `session_catalog_retired`, never
  imported. Writing follows the daemon's discipline: the command holds the
  root's placement lock, which excludes the daemon, and publishes the complete
  image through `LoopexDaemon.SessionIndex.record_offline/3`. A listing reads
  the image without the lock. Resume checks the row's placement identity
  against this root's before any Store call, so a mismatched runtime contests
  no owner.
  """

  alias LoopexDaemon.SessionIndex

  @doc """
  ## Concept

  Records a session this command created under its held placement lock.

  ## Technical depth

  A full index records nothing and answers `{:error, :session_index_full}`, so
  the caller reports that the session cannot be listed or resumed.
  """
  @spec record(Path.t(), binary(), binary()) :: :ok | {:error, atom()}
  def record(state_root, session_id, placement_identity) do
    case SessionIndex.record_offline(state_root, session_id, placement_identity) do
      :ok -> :ok
      {:ok, :index_full} -> {:error, :session_index_full}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  ## Concept

  Lists the sessions this state root knows about, in raw identifier order.
  """
  @spec list(Path.t()) ::
          {:ok, [%{session_id: binary(), runtime_id: binary()}]} | {:error, atom()}
  def list(state_root) do
    with {:ok, rows} <- SessionIndex.read_offline(state_root) do
      {:ok, Enum.map(rows, &%{session_id: &1.session_id, runtime_id: &1.placement_identity})}
    end
  end

  @doc """
  ## Concept

  Prepared recovery for a session this root knows about, enforcing ADR 0008
  placement: only the runtime identity that created the session may resume it.

  ## Technical depth

  An unlisted session is `:session_unknown`; a runtime whose configured
  `runtime_id` differs from the row's placement is refused with a sentence
  naming the identity the session requires, before any Store call. Otherwise this is `Loopex.prepare_resume_session/3`.
  """
  @spec prepare_resume(Path.t(), Loopex.Runtime.t(), binary(), binary()) ::
          {:ok, {:prepared, Loopex.ResumeActivation.t()}}
          | {:ok, {:replayed, binary()}}
          | {:error, term()}
  def prepare_resume(state_root, runtime, session_id, command_id) do
    with {:ok, rows} <- SessionIndex.read_offline(state_root),
         {:ok, creator} <- placement(rows, session_id),
         {:ok, current} <- runtime_id(runtime),
         :ok <- same_placement(creator, current) do
      Loopex.prepare_resume_session(runtime, session_id, command_id)
    end
  end

  defp placement(rows, session_id) do
    case Enum.find(rows, &(&1.session_id == session_id)) do
      %{placement_identity: creator} -> {:ok, creator}
      nil -> {:error, :session_unknown}
    end
  end

  defp runtime_id(runtime) do
    case Loopex.Runtime.configuration(runtime) do
      {:ok, %{runtime_id: runtime_id}} -> {:ok, runtime_id}
      {:error, reason} -> {:error, {:runtime_unavailable, reason}}
    end
  end

  defp same_placement(creator, creator), do: :ok

  defp same_placement(creator, current) do
    {:error,
     {:runtime_placement_mismatch,
      "this session is bound to runtime_id #{inspect(creator)}, not #{inspect(current)}; " <>
        "resume it from a runtime started with runtime_id: #{inspect(creator)}, " <>
        "or start a new session here instead"}}
  end
end
