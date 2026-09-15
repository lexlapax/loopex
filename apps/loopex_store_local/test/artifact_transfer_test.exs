defmodule Loopex.Store.Local.ArtifactTransferTest do
  @moduledoc """
  ## Concept

  A caller retrieves one artifact in bounded pieces: the object is verified
  whole before any piece exists, the window is fixed at open, each piece carries
  its own digest, and closing releases everything the transfer held.

  ## Technical depth

  These cases drive the local artifact store directly, because that is where
  accepted ADR 0028 puts the reading: core never opens a path. What they assert
  about the snapshot is the property the design exists for, that a mutation of
  the original object after verification cannot reach a chunk the open
  response's digest did not cover, and it is proved by rewriting the object
  between the open and the reads.
  """

  use ExUnit.Case, async: true

  alias Loopex.ArtifactStore
  alias Loopex.Store.Local.Artifacts
  alias Loopex.Store.Local.Transfers

  @use %{media_type: "text/plain", role: "tool_output", metadata: %{}}

  test "a whole-object transfer verifies once and emits digested chunks in order" do
    %{handle: handle, reference: reference, bytes: bytes} = stored(:binary.copy("ab", 5_000))

    assert {:ok, transfer} =
             Artifacts.open_transfer(handle, object(reference), reference.use_locator, %{start: 0})

    assert transfer.total_size == byte_size(bytes)
    assert transfer.window_start == 0
    assert transfer.window_length == byte_size(bytes)
    assert transfer.object_digest == reference.digest
    assert is_binary(transfer.transfer_ref)

    chunks = drain(handle, transfer, 4_096)
    assert IO.iodata_to_binary(Enum.map(chunks, & &1.bytes)) == bytes

    # Offsets are contiguous from the window's start and cover it exactly.
    assert Enum.reduce(chunks, 0, fn chunk, offset ->
             assert chunk.offset == offset
             offset + byte_size(chunk.bytes)
           end) == byte_size(bytes)

    # Each chunk names its own bytes, which is a different digest from the one
    # covering the object.
    assert Enum.all?(chunks, fn chunk ->
             chunk.chunk_digest == digest(chunk.bytes)
           end)

    refute Enum.any?(chunks, &(&1.chunk_digest == transfer.object_digest))
    assert :ok = Artifacts.close_transfer(handle, transfer)
  end

  test "a chunk never crosses the window and a window at the end is empty" do
    %{handle: handle, reference: reference, bytes: bytes} = stored("0123456789")

    assert {:ok, first} =
             Artifacts.open_transfer(handle, object(reference), reference.use_locator, %{
               start: 0,
               length: 4
             })

    assert first.window_length == 4
    assert [chunk] = drain(handle, first, 1_000)
    assert chunk.bytes == binary_part(bytes, 0, 4)
    assert :ok = Artifacts.close_transfer(handle, first)

    assert {:ok, last} =
             Artifacts.open_transfer(handle, object(reference), reference.use_locator, %{start: 6})

    assert last.window_start == 6
    assert last.window_length == 4
    assert IO.iodata_to_binary(Enum.map(drain(handle, last, 2), & &1.bytes)) == "6789"
    assert :ok = Artifacts.close_transfer(handle, last)

    # A window that starts exactly at the end is an empty transfer; one that
    # starts past it names bytes that never existed.
    assert {:ok, empty} =
             Artifacts.open_transfer(handle, object(reference), reference.use_locator, %{
               start: byte_size(bytes)
             })

    assert empty.window_length == 0
    assert {:ok, :complete} = Artifacts.read_transfer(handle, empty, 16)
    assert :ok = Artifacts.close_transfer(handle, empty)

    assert {:error, :invalid_window} =
             Artifacts.open_transfer(handle, object(reference), reference.use_locator, %{
               start: byte_size(bytes) + 1
             })

    assert {:error, :invalid_window} =
             Artifacts.open_transfer(handle, object(reference), reference.use_locator, %{
               start: 0,
               length: byte_size(bytes) + 1
             })
  end

  test "a rewrite of the object after open cannot reach a chunk" do
    %{handle: handle, reference: reference, root: root, bytes: bytes} = stored("original-bytes")

    assert {:ok, transfer} =
             Artifacts.open_transfer(handle, object(reference), reference.use_locator, %{start: 0})

    # Same path, same size, different bytes: the snapshot the transfer reads
    # from was taken during verification, so the chunks are still the verified
    # object rather than whatever is on disk now.
    path = Path.join([root, binary_part(reference.locator, 0, 2), reference.locator])
    File.write!(path, String.replace(bytes, "original", "REWRITTEN"))

    assert IO.iodata_to_binary(Enum.map(drain(handle, transfer, 64), & &1.bytes)) == bytes
    assert :ok = Artifacts.close_transfer(handle, transfer)
  end

  test "a use that names another object refuses before anything is opened" do
    %{handle: handle, reference: first} = stored("first object")
    %{reference: second} = stored("second object", handle)

    assert {:error, :artifact_use_mismatch} =
             Artifacts.open_transfer(handle, object(first), second.use_locator, %{start: 0})

    assert {:error, :unknown_artifact_use} =
             Artifacts.open_transfer(
               handle,
               object(first),
               "use:" <> String.duplicate("a", 64),
               %{
                 start: 0
               }
             )
  end

  test "an unknown or closed transfer refuses and releases its descriptor" do
    %{handle: handle, reference: reference} = stored("bytes to release")

    assert {:ok, transfer} =
             Artifacts.open_transfer(handle, object(reference), reference.use_locator, %{start: 0})

    assert [_live] = Transfers.live(handle.transfers)
    assert :ok = Artifacts.close_transfer(handle, transfer)
    assert [] = Transfers.live(handle.transfers)

    assert {:error, :unknown_transfer} = Artifacts.read_transfer(handle, transfer, 16)
    assert :ok = Artifacts.close_transfer(handle, transfer)
  end

  test "a store without a transfer owner refuses the family rather than crashing" do
    %{handle: handle, reference: reference} = stored("no owner here")
    plain = Map.delete(handle, :transfers)

    assert {:error, :transfers_unavailable} =
             Artifacts.open_transfer(plain, object(reference), reference.use_locator, %{start: 0})

    assert ArtifactStore.supports_transfer?(Artifacts)
  end

  defp stored(bytes, handle \\ nil) do
    handle = handle || new_store()
    {:ok, reference} = Artifacts.put(handle, bytes, @use)
    %{handle: handle, reference: reference, bytes: bytes, root: handle.root}
  end

  defp new_store do
    root = Path.join(System.tmp_dir!(), "loopex-transfer-#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(root)
    {:ok, owner} = Transfers.start_link(root: root)

    on_exit(fn ->
      if Process.alive?(owner), do: GenServer.stop(owner)
      File.rm_rf(root)
    end)

    %{root: root, transfers: owner}
  end

  defp object(reference),
    do: %{digest: reference.digest, size: reference.size, locator: reference.locator}

  defp drain(handle, transfer, length, collected \\ []) do
    case Artifacts.read_transfer(handle, transfer, length) do
      {:ok, :complete} -> Enum.reverse(collected)
      {:ok, chunk} -> drain(handle, transfer, length, [chunk | collected])
    end
  end

  defp digest(bytes), do: :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)
end
