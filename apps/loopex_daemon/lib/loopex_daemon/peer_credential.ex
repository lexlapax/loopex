defmodule LoopexDaemon.PeerCredential do
  @moduledoc """
  ## Concept

  A daemon connection belongs to the same operating-system user as the daemon.
  Filesystem permissions are the primary boundary; every accepted socket also
  passes the supported platform's peer-credential check before a frame is read.

  ## Technical depth

  Darwin supplies a 76-byte `xucred` through `LOCAL_PEERCRED` at `SOL_LOCAL`.
  Linux supplies a 12-byte `ucred` through `SO_PEERCRED` at `SOL_SOCKET`.
  Both structures use native byte order. The decoder accepts only the complete
  fixed structure and, on Darwin, the known version and group-count range.
  Missing options, malformed bytes and uid mismatch all collapse to one
  fail-closed result without putting peer details in diagnostics.
  """

  require Logger

  @darwin_sol_local 0
  @darwin_local_peercred 1
  @darwin_option_buffer_bytes 128
  @darwin_xucred_version 0
  @darwin_groups 16

  @linux_sol_socket 1
  @linux_so_peercred 17
  @linux_ucred_bytes 12

  @doc false
  @spec authorize(:socket.socket(), non_neg_integer()) ::
          :ok | {:error, :peer_credential_unverified}
  def authorize(socket, daemon_uid)
      when is_integer(daemon_uid) and daemon_uid >= 0 do
    case uid(socket) do
      {:ok, ^daemon_uid} ->
        Logger.debug("loopex daemon peer credential verified")
        :ok

      {:ok, _other_uid} ->
        refuse()

      {:error, _reason} ->
        refuse()
    end
  end

  @doc false
  @spec uid(:socket.socket()) :: {:ok, non_neg_integer()} | {:error, atom()}
  def uid(socket) do
    case :os.type() do
      {:unix, :darwin} -> read(socket, :darwin)
      {:unix, :linux} -> read(socket, :linux)
      _other -> {:error, :unsupported_platform}
    end
  end

  @doc false
  @spec decode(:darwin | :linux, binary()) ::
          {:ok, non_neg_integer()} | {:error, :malformed_peer_credential}
  def decode(:darwin, bytes) when is_binary(bytes) do
    case bytes do
      <<@darwin_xucred_version::native-unsigned-integer-size(32),
        uid::native-unsigned-integer-size(32), group_count::native-signed-integer-size(16),
        _padding::binary-size(2), _groups::binary-size(64)>>
      when group_count >= 0 and group_count <= @darwin_groups ->
        {:ok, uid}

      _other ->
        {:error, :malformed_peer_credential}
    end
  end

  def decode(:linux, bytes) when is_binary(bytes) do
    case bytes do
      <<pid::native-signed-integer-size(32), uid::native-unsigned-integer-size(32),
        _gid::native-unsigned-integer-size(32)>>
      when pid >= 0 ->
        {:ok, uid}

      _other ->
        {:error, :malformed_peer_credential}
    end
  end

  defp read(socket, :darwin) do
    read_native(
      socket,
      {@darwin_sol_local, @darwin_local_peercred},
      @darwin_option_buffer_bytes,
      :darwin
    )
  end

  defp read(socket, :linux) do
    read_native(socket, {@linux_sol_socket, @linux_so_peercred}, @linux_ucred_bytes, :linux)
  end

  defp read_native(socket, option, bytes, platform) do
    case :socket.getopt_native(socket, option, bytes) do
      {:ok, credential} -> decode(platform, credential)
      {:error, _reason} -> {:error, :peer_credential_unavailable}
    end
  end

  defp refuse do
    Logger.debug("loopex daemon peer credential refused")
    {:error, :peer_credential_unverified}
  end
end
