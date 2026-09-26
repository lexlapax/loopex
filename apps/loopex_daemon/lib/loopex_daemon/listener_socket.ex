defmodule LoopexDaemon.ListenerSocket do
  @moduledoc """
  ## Concept

  The daemon's local socket starts as a bound, permission-checked listener that
  accepts nothing. A later lifecycle cut gives a dedicated listener process the
  authority to accept clients.

  ## Technical depth

  This boundary is called only after the daemon holds both the placement lock
  and the Store writer marker. It removes a retained pathname only after a
  no-follow metadata read proves the same uid and Unix-socket kind, binds with
  OTP's `:socket` backend, fixes and verifies mode `0600`, and listens without
  issuing `accept`. Closing the socket never removes its pathname; the next
  verified owner performs that recovery.
  """

  require Logger

  alias LoopexProtocol.Session.V2

  @socket_kind 0o140000
  @kind_mask 0o170000
  @permission_mask 0o777
  @socket_permissions 0o600

  @typedoc false
  @type refusal ::
          {:socket_permission_unverified, term()}
          | {:listener_start_failed, term()}

  @doc false
  @spec open_parked(Path.t(), non_neg_integer()) ::
          {:ok, :socket.socket()} | {:error, refusal()}
  def open_parked(path, daemon_uid)
      when is_binary(path) and is_integer(daemon_uid) and daemon_uid >= 0 do
    Logger.debug("loopex daemon listener socket start")

    with :ok <- prepare_path(path, daemon_uid),
         {:ok, socket} <- open_socket() do
      bind_and_listen(socket, path, daemon_uid)
    end
  end

  @doc false
  @spec prepare_path(Path.t(), non_neg_integer()) :: :ok | {:error, refusal()}
  def prepare_path(path, daemon_uid)
      when is_binary(path) and is_integer(daemon_uid) and daemon_uid >= 0 do
    case File.lstat(path) do
      {:error, :enoent} ->
        :ok

      {:ok, %File.Stat{uid: ^daemon_uid, type: :other, mode: mode}}
      when Bitwise.band(mode, @kind_mask) == @socket_kind ->
        case File.rm(path) do
          :ok ->
            Logger.debug("loopex daemon retained socket removed")
            :ok

          {:error, reason} ->
            permission_error({:remove_failed, reason})
        end

      {:ok, %File.Stat{}} ->
        permission_error(:unsafe_existing_path)

      {:error, reason} ->
        permission_error({:metadata_failed, reason})
    end
  end

  @doc false
  @spec close(:socket.socket()) :: :ok | {:error, term()}
  def close(socket) do
    result = :socket.close(socket)
    Logger.debug("loopex daemon listener socket closed with pathname retained")
    result
  end

  defp open_socket do
    case :socket.open(:local, :stream, :default) do
      {:ok, socket} -> {:ok, socket}
      {:error, reason} -> listener_error({:open_failed, reason})
    end
  end

  defp bind_and_listen(socket, path, daemon_uid) do
    result =
      with :ok <- bind(socket, path),
           :ok <- set_permissions(path),
           :ok <- verify_bound_path(path, daemon_uid),
           :ok <- listen(socket) do
        Logger.debug("loopex daemon listener socket parked")
        {:ok, socket}
      end

    case result do
      {:ok, ^socket} = success ->
        success

      {:error, _reason} = refusal ->
        _ = close(socket)
        refusal
    end
  end

  defp bind(socket, path) do
    case :socket.bind(socket, %{family: :local, path: path}) do
      :ok -> :ok
      {:error, reason} -> listener_error({:bind_failed, reason})
    end
  end

  defp set_permissions(path) do
    case File.chmod(path, @socket_permissions) do
      :ok -> :ok
      {:error, reason} -> permission_error({:chmod_failed, reason})
    end
  end

  defp verify_bound_path(path, daemon_uid) do
    case File.lstat(path) do
      {:ok, %File.Stat{uid: ^daemon_uid, type: :other, mode: mode}}
      when Bitwise.band(mode, @kind_mask) == @socket_kind and
             Bitwise.band(mode, @permission_mask) == @socket_permissions ->
        :ok

      {:ok, %File.Stat{}} ->
        permission_error(:bound_path_mismatch)

      {:error, reason} ->
        permission_error({:bound_metadata_failed, reason})
    end
  end

  defp listen(socket) do
    backlog = Map.fetch!(V2.limits(), "connections_per_daemon")

    case :socket.listen(socket, backlog) do
      :ok -> :ok
      {:error, reason} -> listener_error({:listen_failed, reason})
    end
  end

  defp permission_error(reason),
    do: {:error, {:socket_permission_unverified, reason}}

  defp listener_error(reason),
    do: {:error, {:listener_start_failed, reason}}
end
