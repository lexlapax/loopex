defmodule LoopexDaemon.WireRecordsTest do
  use ExUnit.Case, async: true

  alias LoopexDaemon.WireRecords
  alias LoopexProtocol.Frame

  test "control records match the generation-two vectors exactly" do
    epoch = "epoch"

    assert encode(WireRecords.control_acquired("acquire-1", epoch, 30_000, false)) ==
             ~s({"method":"session.acquire_control","request_id":"acquire-1","result":{"expires_in_ms":"30000","writer_epoch":"ZXBvY2g"},"type":"result"}\n)

    assert encode(WireRecords.control_acquired("acquire-2", epoch, 30_000, true)) ==
             ~s({"method":"session.acquire_control","request_id":"acquire-2","result":{"expires_in_ms":"30000","renewed":true,"writer_epoch":"ZXBvY2g"},"type":"result"}\n)

    assert encode(WireRecords.control_released("release-1")) ==
             ~s({"method":"session.release_control","request_id":"release-1","result":{"released":true},"type":"result"}\n)

    assert encode(WireRecords.control_error("error-1", "control_held")) ==
             ~s({"code":"control_held","message":"control held.","request_id":"error-1","type":"error"}\n)

    assert encode(WireRecords.control_error("error-1", "control_not_held")) ==
             ~s({"code":"control_not_held","message":"control is not held by this connection","request_id":"error-1","type":"error"}\n)

    assert encode(WireRecords.control_error("error-1", "control_pending")) ==
             ~s({"code":"control_pending","message":"control pending.","request_id":"error-1","type":"error"}\n)
  end

  defp encode(record) do
    assert {:ok, encoded} = Frame.encode(record)
    IO.iodata_to_binary(encoded)
  end
end
