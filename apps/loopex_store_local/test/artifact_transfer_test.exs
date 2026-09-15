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

  test "corruption anywhere in the object refuses at open before any chunk exists" do
    %{handle: handle, reference: reference, root: root, bytes: bytes} =
      stored(:binary.copy("z", 4_096))

    path = Path.join([root, binary_part(reference.locator, 0, 2), reference.locator])

    # Corruption outside the requested window still refuses, because the open
    # verifies the whole object rather than the part a caller asked for.
    File.write!(path, binary_part(bytes, 0, byte_size(bytes) - 1) <> "!")

    assert {:error, :artifact_digest_mismatch} =
             Artifacts.open_transfer(handle, object(reference), reference.use_locator, %{
               start: 0,
               length: 16
             })

    # A truncated object is refused as truncation rather than read short.
    File.write!(path, binary_part(bytes, 0, 128))

    assert {:error, :artifact_digest_mismatch} =
             Artifacts.open_transfer(handle, object(reference), reference.use_locator, %{start: 0})

    assert [] = Transfers.live(handle.transfers)
  end

  test "an open that exhausts its deadline or its work budget refuses" do
    %{handle: handle, reference: reference} = stored(:binary.copy("w", 200_000))

    assert {:error, :open_work_budget_exhausted} =
             Transfers.open(
               handle.transfers,
               object(reference),
               reference.use_locator,
               %{start: 0},
               open_work_bytes: 1_024
             )

    assert {:error, :open_deadline_exhausted} =
             Transfers.open(
               handle.transfers,
               object(reference),
               reference.use_locator,
               %{start: 0},
               open_deadline_ms: -1
             )

    # Neither left a transfer behind, so neither spent a slot of the ceiling.
    assert [] = Transfers.live(handle.transfers)
  end

  test "the runtime ceiling bounds how many transfers are live at once" do
    %{handle: handle, reference: reference} = stored("bounded concurrency")
    limits = ArtifactStore.transfer_limits()

    opened =
      for _index <- 1..limits.per_runtime do
        assert {:ok, transfer} =
                 Artifacts.open_transfer(handle, object(reference), reference.use_locator, %{
                   start: 0
                 })

        transfer
      end

    assert length(Transfers.live(handle.transfers)) == limits.per_runtime

    assert {:error, :transfer_limit_reached} =
             Artifacts.open_transfer(handle, object(reference), reference.use_locator, %{start: 0})

    # Closing one makes room for exactly one more.
    assert :ok = Artifacts.close_transfer(handle, hd(opened))

    assert {:ok, replacement} =
             Artifacts.open_transfer(handle, object(reference), reference.use_locator, %{start: 0})

    assert {:error, :transfer_limit_reached} =
             Artifacts.open_transfer(handle, object(reference), reference.use_locator, %{start: 0})

    Enum.each([replacement | tl(opened)], &Artifacts.close_transfer(handle, &1))
    assert [] = Transfers.live(handle.transfers)
  end

  test "a transfer expires on its own lifetime and leaves nothing behind" do
    root = Path.join(System.tmp_dir!(), "loopex-expiry-#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(root)
    limits = Map.put(ArtifactStore.transfer_limits(), :lifetime_ms, 150)
    {:ok, owner} = Transfers.start_link(root: root, limits: limits)
    on_exit(fn -> File.rm_rf(root) end)

    handle = %{root: root, transfers: owner}
    {:ok, reference} = Artifacts.put(handle, "bytes that outlive nothing", @use)

    assert {:ok, transfer} =
             Artifacts.open_transfer(handle, object(reference), reference.use_locator, %{start: 0})

    assert [_live] = Transfers.live(owner)
    Process.sleep(300)

    assert [] = Transfers.live(owner)
    assert {:error, :unknown_transfer} = Artifacts.read_transfer(handle, transfer, 8)

    # The snapshot was unlinked at open, so nothing of it is left to find.
    assert {:ok, []} = File.ls(Path.join(root, "transfers"))
  end

  test "startup scavenges only the regular files the scratch root owns" do
    root = Path.join(System.tmp_dir!(), "loopex-scavenge-#{:erlang.unique_integer([:positive])}")
    scratch = Path.join(root, "transfers")
    File.mkdir_p!(scratch)
    on_exit(fn -> File.rm_rf(root) end)

    stale = Path.join(scratch, "left-behind")
    File.write!(stale, "a snapshot a crash left behind")
    kept_directory = Path.join(scratch, "not-a-snapshot")
    File.mkdir_p!(kept_directory)
    outside = Path.join(root, "outside")
    File.write!(outside, "not the scratch root's business")
    link = Path.join(scratch, "link-out")
    File.ln_s!(outside, link)

    {:ok, owner} = Transfers.start_link(root: root)
    on_exit(fn -> if Process.alive?(owner), do: GenServer.stop(owner) end)

    refute File.exists?(stale)
    assert File.dir?(kept_directory)
    # The link is not followed, and what it pointed at is untouched.
    assert File.exists?(outside)
    assert File.read!(outside) == "not the scratch root's business"
  end

  test "a transfer belongs to the attachment that opened it and is released with it" do
    %{handle: handle, reference: reference, bytes: bytes} = stored("bytes for one attachment")
    %{runtime: runtime, session_id: session_id} = session(handle)

    {:ok, first} = Loopex.attach(runtime, session_id, after_event_sequence: 0)

    request = %{object: object(reference), use_locator: reference.use_locator, start: 0}
    assert {:ok, transfer} = Loopex.open_artifact_transfer(first, request)
    assert transfer.total_size == byte_size(bytes)
    assert transfer.object_digest == reference.digest

    # The open response carries no placement of its own: a caller learns the
    # window and the digests, not where the bytes live.
    refute Map.has_key?(transfer, :object)
    refute Map.has_key?(transfer, :path)

    assert {:ok, chunk} = Loopex.read_artifact_chunk(first, transfer.transfer_ref, 8)
    assert chunk.bytes == binary_part(bytes, 0, 8)

    # A second attachment replaces the first, which releases what the first
    # held; the reference it was using is not readable through either.
    {:ok, second} = Loopex.attach(runtime, session_id, after_event_sequence: 0)

    assert {:error, :unknown_transfer} =
             Loopex.read_artifact_chunk(second, transfer.transfer_ref, 8)

    assert {:error, :stale_attachment} =
             Loopex.read_artifact_chunk(first, transfer.transfer_ref, 8)

    assert [] = Transfers.live(handle.transfers)
  end

  test "a runtime composed without a transfer capable store refuses the family" do
    %{handle: handle, reference: reference} = stored("no transfers here")
    %{runtime: runtime, session_id: session_id} = session(nil)

    {:ok, attachment} = Loopex.attach(runtime, session_id, after_event_sequence: 0)

    assert {:error, :artifact_transfer_unsupported} =
             Loopex.open_artifact_transfer(attachment, %{
               object: object(reference),
               use_locator: reference.use_locator,
               start: 0
             })

    assert [] = Transfers.live(handle.transfers)
  end

  # Concept: one runtime over this store, with the artifact placement composed
  # in beside it when the case is about transfers.
  defp session(artifact_handle) do
    path = Path.join(System.tmp_dir!(), "loopex-store-#{:erlang.unique_integer([:positive])}")
    {:ok, store_pid} = Loopex.Store.Local.start_link(path: path)
    {:ok, store} = Loopex.Store.new(Loopex.Store.Local, store_pid)

    options =
      [context_token_budget: 8_192, runtime_id: "artifact-transfer", store: store]
      |> then(fn options ->
        case artifact_handle do
          nil ->
            options

          handle ->
            Keyword.put(options, :artifact_store, %{
              module: Loopex.Store.Local.Artifacts,
              handle: handle
            })
        end
      end)

    {:ok, runtime} = Loopex.start_link(options)
    {:ok, session_id} = Loopex.create_session(runtime, %{}, command_id: "create")

    on_exit(fn ->
      if Loopex.Runtime.alive?(runtime), do: Loopex.stop(runtime)
      stop_quietly(store_pid)
      File.rm_rf(path)
    end)

    %{runtime: runtime, session_id: session_id}
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

  # A store that is already going down is already down; teardown says so rather
  # than failing a case that has otherwise finished.
  defp stop_quietly(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid)
  catch
    :exit, _reason -> :ok
  end
end
