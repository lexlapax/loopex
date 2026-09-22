defmodule LoopexDaemon.PeerCredentialTest do
  use ExUnit.Case, async: true

  alias LoopexDaemon.{ListenerSocket, PeerCredential}

  test "the current platform reads and authorizes the uid on an accepted socket" do
    directory = temporary_directory()
    path = Path.join(directory, "daemon.sock")
    daemon_uid = File.stat!(directory).uid
    parent = self()

    on_exit(fn ->
      _ = File.rm(path)
      _ = File.rmdir(directory)
    end)

    assert {:ok, listener} = ListenerSocket.open_parked(path, daemon_uid)

    client =
      Task.async(fn ->
        {:ok, socket} = :socket.open(:local, :stream, :default)
        :ok = :socket.connect(socket, %{family: :local, path: path})
        send(parent, {:client_connected, self()})

        receive do
          :close -> :ok
        end

        :ok = :socket.close(socket)
      end)

    assert_receive {:client_connected, client_pid} when client_pid == client.pid
    assert {:ok, accepted} = :socket.accept(listener, 1_000)

    assert {:ok, ^daemon_uid} = PeerCredential.uid(accepted)
    assert :ok = PeerCredential.authorize(accepted, daemon_uid)

    assert {:error, :peer_credential_unverified} =
             PeerCredential.authorize(accepted, daemon_uid + 1)

    assert :ok = :socket.close(accepted)
    send(client.pid, :close)
    assert :ok = Task.await(client)
    assert :ok = ListenerSocket.close(listener)
  end

  test "Darwin xucred decoding accepts only the complete known structure" do
    valid = darwin_credential(501, 16)
    assert byte_size(valid) == 76
    assert {:ok, 501} = PeerCredential.decode(:darwin, valid)

    for malformed <- [
          binary_part(valid, 0, 75),
          valid <> <<0>>,
          darwin_credential(501, -1),
          darwin_credential(501, 17),
          <<1::native-unsigned-integer-size(32), binary_part(valid, 4, 72)::binary>>
        ] do
      assert {:error, :malformed_peer_credential} =
               PeerCredential.decode(:darwin, malformed)
    end
  end

  test "Linux ucred decoding accepts only the complete native structure" do
    valid =
      <<12_345::native-signed-integer-size(32), 501::native-unsigned-integer-size(32),
        20::native-unsigned-integer-size(32)>>

    assert byte_size(valid) == 12
    assert {:ok, 501} = PeerCredential.decode(:linux, valid)

    for malformed <- [
          binary_part(valid, 0, 11),
          valid <> <<0>>,
          <<-1::native-signed-integer-size(32), 501::native-unsigned-integer-size(32),
            20::native-unsigned-integer-size(32)>>
        ] do
      assert {:error, :malformed_peer_credential} =
               PeerCredential.decode(:linux, malformed)
    end
  end

  defp darwin_credential(uid, group_count) do
    <<0::native-unsigned-integer-size(32), uid::native-unsigned-integer-size(32),
      group_count::native-signed-integer-size(16), 0::size(16), 0::size(64 * 8)>>
  end

  defp temporary_directory do
    path =
      Path.join(
        System.tmp_dir!(),
        "loopex-daemon-peer-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir!(path)
    File.chmod!(path, 0o700)
    path
  end
end
