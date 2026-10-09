Code.require_file("../../loopex/test/support/configured_genesis_helper.exs", __DIR__)

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

  @use %{
    media_type: "text/plain",
    role: "tool_output",
    metadata: %{
      "session_id" => "transfer-session",
      "run_id" => "transfer-run",
      "operation_id" => "transfer-operation",
      "attempt" => 1,
      "tool_call_id" => "transfer-call"
    }
  }

  test "a whole-object transfer verifies once and emits digested chunks in order" do
    %{handle: handle, reference: reference, bytes: bytes} = stored(:binary.copy("ab", 5_000))

    assert {:ok, transfer} =
             open_transfer(handle, reference.use_locator, %{start: 0})

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
    assert :ok = close_transfer(handle, transfer)
  end

  test "a chunk never crosses the window and a window at the end is empty" do
    %{handle: handle, reference: reference, bytes: bytes} = stored("0123456789")

    assert {:ok, first} =
             open_transfer(handle, reference.use_locator, %{
               start: 0,
               length: 4
             })

    assert first.window_length == 4
    assert [chunk] = drain(handle, first, 1_000)
    assert chunk.bytes == binary_part(bytes, 0, 4)
    assert :ok = close_transfer(handle, first)

    assert {:ok, last} =
             open_transfer(handle, reference.use_locator, %{start: 6})

    assert last.window_start == 6
    assert last.window_length == 4
    assert IO.iodata_to_binary(Enum.map(drain(handle, last, 2), & &1.bytes)) == "6789"
    assert :ok = close_transfer(handle, last)

    # A window that starts exactly at the end is an empty transfer; one that
    # starts past it names bytes that never existed.
    assert {:ok, empty} =
             open_transfer(handle, reference.use_locator, %{
               start: byte_size(bytes)
             })

    assert empty.window_length == 0
    assert {:ok, :complete} = Artifacts.read_transfer(handle, empty, 16)
    assert :ok = close_transfer(handle, empty)

    assert {:error, :invalid_window} =
             open_transfer(handle, reference.use_locator, %{
               start: byte_size(bytes) + 1
             })

    assert {:error, :invalid_window} =
             open_transfer(handle, reference.use_locator, %{
               start: 0,
               length: byte_size(bytes) + 1
             })
  end

  test "a rewrite of the object after open cannot reach a chunk" do
    %{handle: handle, reference: reference, root: root, bytes: bytes} = stored("original-bytes")

    assert {:ok, transfer} =
             open_transfer(handle, reference.use_locator, %{start: 0})

    # Same path, same size, different bytes: the snapshot the transfer reads
    # from was taken during verification, so the chunks are still the verified
    # object rather than whatever is on disk now.
    path = Path.join([root, binary_part(reference.locator, 0, 2), reference.locator])
    File.write!(path, String.replace(bytes, "original", "REWRITTEN"))

    assert IO.iodata_to_binary(Enum.map(drain(handle, transfer, 64), & &1.bytes)) == bytes
    assert :ok = close_transfer(handle, transfer)
  end

  test "a use that names another object refuses before anything is opened" do
    %{handle: handle} = stored("first object")
    %{reference: second} = stored("second object", handle)

    assert {:error, :artifact_use_mismatch} =
             open_transfer(handle, second.use_locator, %{start: 0}, session_id: "wrong-session")

    assert {:error, :unknown_artifact_use} =
             open_transfer(handle, "use:" <> String.duplicate("a", 64), %{
               start: 0
             })
  end

  test "an unknown or closed transfer refuses and releases its descriptor" do
    %{handle: handle, reference: reference} = stored("bytes to release")

    assert {:ok, transfer} =
             open_transfer(handle, reference.use_locator, %{start: 0})

    assert [_live] = Transfers.live(handle.transfers)
    assert :ok = close_transfer(handle, transfer)
    assert [] = Transfers.live(handle.transfers)

    assert {:error, :unknown_transfer} = Artifacts.read_transfer(handle, transfer, 16)
    assert :ok = close_transfer(handle, transfer)
  end

  test "a store without a transfer owner refuses the family rather than crashing" do
    %{handle: handle, reference: reference} = stored("no owner here")
    plain = Map.delete(handle, :transfers)

    assert {:error, :transfers_unavailable} =
             open_transfer(plain, reference.use_locator, %{start: 0})

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
             open_transfer(handle, reference.use_locator, %{
               start: 0,
               length: 16
             })

    # A truncated object is refused as truncation rather than read short.
    File.write!(path, binary_part(bytes, 0, 128))

    assert {:error, :artifact_digest_mismatch} =
             open_transfer(handle, reference.use_locator, %{start: 0})

    assert [] = Transfers.live(handle.transfers)
  end

  test "an open that exhausts its deadline or its work budget refuses" do
    %{handle: handle, reference: reference} = stored(:binary.copy("w", 200_000))

    constrained = budget_store(handle, 1_024)

    assert {:error, :open_work_budget_exhausted} =
             open_transfer(constrained, reference.use_locator, %{start: 0})

    assert {:error, :open_deadline_exhausted} =
             open_transfer(handle, reference.use_locator, %{start: 0}, open_deadline_ms: -1)

    # Neither left a transfer behind, so neither spent a slot of the ceiling.
    assert [] = Transfers.live(handle.transfers)
  end

  test "the runtime ceiling bounds how many transfers are live at once" do
    %{handle: handle, reference: reference} = stored("bounded concurrency")
    limits = ArtifactStore.transfer_limits()

    opened =
      for _index <- 1..limits.per_runtime do
        assert {:ok, transfer} =
                 open_transfer(handle, reference.use_locator, %{
                   start: 0
                 })

        transfer
      end

    assert length(Transfers.live(handle.transfers)) == limits.per_runtime

    assert {:error, :transfer_limit_reached} =
             open_transfer(handle, reference.use_locator, %{start: 0})

    # Closing one makes room for exactly one more.
    assert :ok = close_transfer(handle, hd(opened))

    assert {:ok, replacement} =
             open_transfer(handle, reference.use_locator, %{start: 0})

    assert {:error, :transfer_limit_reached} =
             open_transfer(handle, reference.use_locator, %{start: 0})

    Enum.each([replacement | tl(opened)], &close_transfer(handle, &1))
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
             open_transfer(handle, reference.use_locator, %{start: 0})

    assert [_live] = Transfers.live(owner)
    Process.sleep(300)

    assert [id] = Transfers.live(owner)
    assert id == transfer.transfer_ref
    assert {:error, :unknown_transfer} = Artifacts.read_transfer(handle, transfer, 8)
    assert :ok = close_transfer(handle, transfer)
    assert [] = Transfers.live(owner)

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
    reference = for_session(handle, reference, session_id)

    {:ok, first} = Loopex.attach(runtime, session_id, after_event_sequence: 0)

    request = %{use_locator: reference.use_locator, start: 0}
    assert {:ok, transfer} = Loopex.open_artifact_transfer(first, request)
    assert transfer.total_size == byte_size(bytes)
    assert transfer.object_digest == reference.digest

    # The open response carries no placement of its own: a caller learns the
    # window and the digests, not where the bytes live.
    refute Map.has_key?(transfer, :object)
    refute Map.has_key?(transfer, :path)

    assert {:ok, chunk} = Loopex.read_artifact_chunk(first, transfer.transfer_ref, 8)
    assert chunk.bytes == binary_part(bytes, 0, 8)

    # Replacing the first attachment by name releases what it held; the
    # reference it was using is not readable through either. Attachments under
    # one holder otherwise coexist, so the replacement is explicit.
    cleanup = observe_replacement_cleanup(runtime, handle, transfer)

    {:ok, second} =
      Loopex.Runtime.attach_for_holder(runtime, session_id, self(),
        request_id: "replace-first",
        after_event_sequence: 0,
        replace_attachment_id: first.attachment_id
      )

    assert {:error, :unknown_transfer} =
             Loopex.read_artifact_chunk(second, transfer.transfer_ref, 8)

    assert {:error, :stale_attachment} =
             Loopex.read_artifact_chunk(first, transfer.transfer_ref, 8)

    join_replacement_cleanup(cleanup, handle)
  end

  # Concept: a holder's death releases every transfer its attachments held,
  # and nothing another holder holds.
  #
  # Technical depth: one stand-in holder process owns two attachments to the
  # session and another owns one; each attachment opens a transfer. Killing the
  # first holder leaves exactly the other holder's transfer live and readable.
  test "a holder's death releases all of that holder's transfers and only them" do
    %{handle: handle, reference: reference} = stored("bytes for two holders")
    %{runtime: runtime, session_id: session_id} = session(handle)
    reference = for_session(handle, reference, session_id)
    request = %{use_locator: reference.use_locator, start: 0}
    doomed = spawn(fn -> Process.sleep(:infinity) end)
    survivor = spawn(fn -> Process.sleep(:infinity) end)
    on_exit(fn -> Process.exit(survivor, :kill) end)

    attachments =
      for {holder, id} <- [{doomed, "d1"}, {doomed, "d2"}, {survivor, "s1"}] do
        {:ok, attachment} =
          Loopex.Runtime.attach_for_holder(runtime, session_id, holder,
            request_id: id,
            after_event_sequence: 0
          )

        {:ok, transfer} = Loopex.open_artifact_transfer(attachment, request)
        {holder, attachment, transfer}
      end

    assert length(Transfers.live(handle.transfers)) == 3
    Process.exit(doomed, :kill)

    eventually(fn -> length(Transfers.live(handle.transfers)) == 1 end)
    [{^survivor, attachment, transfer}] = Enum.filter(attachments, &(elem(&1, 0) == survivor))
    assert {:ok, _chunk} = Loopex.read_artifact_chunk(attachment, transfer.transfer_ref, 4)
  end

  defp eventually(predicate, attempts \\ 200) do
    cond do
      predicate.() -> :ok
      attempts == 0 -> flunk("condition never held")
      true -> Process.sleep(10) && eventually(predicate, attempts - 1)
    end
  end

  defmodule LegacyStore do
    @moduledoc false
    @behaviour Loopex.ArtifactStore

    alias Loopex.Store.Local.Artifacts

    @impl Loopex.ArtifactStore
    def put(handle, bytes, use_record), do: Artifacts.put(handle, bytes, use_record)

    @impl Loopex.ArtifactStore
    def fetch(handle, object), do: Artifacts.fetch(handle, object)

    @impl Loopex.ArtifactStore
    def stat(handle, locator), do: Artifacts.stat(handle, locator)

    @impl Loopex.ArtifactStore
    def describe(handle, use_locator), do: Artifacts.describe(handle, use_locator)
  end

  test "an adapter without the capability keeps the prior API and refuses only the transfer family" do
    %{handle: handle, reference: reference, bytes: bytes} = stored("bytes an old adapter holds")

    # The four callbacks that predate the decision answer exactly as before.
    refute ArtifactStore.supports_transfer?(LegacyStore)
    assert {:ok, ^bytes} = LegacyStore.fetch(handle, object(reference))
    assert {:ok, stat} = LegacyStore.stat(handle, reference.locator)
    assert stat.digest == reference.digest
    assert {:ok, described} = LegacyStore.describe(handle, reference.use_locator)
    assert described.object_locator == reference.locator

    %{runtime: runtime, session_id: session_id} = session(handle, LegacyStore)
    reference = for_session(handle, reference, session_id)
    {:ok, attachment} = Loopex.attach(runtime, session_id, after_event_sequence: 0)

    assert {:error, :artifact_transfer_unsupported} =
             Loopex.open_artifact_transfer(attachment, %{
               use_locator: reference.use_locator,
               start: 0
             })
  end

  test "one attachment may hold only its share of the live transfers" do
    %{handle: handle, reference: reference} = stored("bytes for two at a time")
    %{runtime: runtime, session_id: session_id} = session(handle)
    reference = for_session(handle, reference, session_id)
    {:ok, attachment} = Loopex.attach(runtime, session_id, after_event_sequence: 0)

    request = %{use_locator: reference.use_locator, start: 0}
    limits = ArtifactStore.transfer_limits()

    opened =
      for _index <- 1..limits.per_attachment do
        assert {:ok, transfer} = Loopex.open_artifact_transfer(attachment, request)
        transfer
      end

    assert {:error, :transfer_limit_reached} = Loopex.open_artifact_transfer(attachment, request)

    assert :ok = Loopex.close_artifact_transfer(attachment, hd(opened).transfer_ref)
    assert {:ok, _replacement} = Loopex.open_artifact_transfer(attachment, request)
    assert {:error, :transfer_limit_reached} = Loopex.open_artifact_transfer(attachment, request)
  end

  test "a runtime composed without a transfer capable store refuses the family" do
    %{handle: handle, reference: reference} = stored("no transfers here")
    %{runtime: runtime, session_id: session_id} = session(nil)

    {:ok, attachment} = Loopex.attach(runtime, session_id, after_event_sequence: 0)

    assert {:error, :artifact_transfer_unsupported} =
             Loopex.open_artifact_transfer(attachment, %{
               use_locator: reference.use_locator,
               start: 0
             })

    assert [] = Transfers.live(handle.transfers)
  end

  # Concept: one runtime over this store, with the artifact placement composed
  # in beside it when the case is about transfers.
  # The thirteen cases below are this outcome's locked witnesses. Each carries
  # the exact identity acceptance bound and asserts the whole of what its name
  # claims; the narrower cases above remain because they say which single rule
  # broke when one of these fails.

  test "a chunk is returned only after the complete immutable object verifies once per transfer and object and chunk digests stay distinct" do
    bytes = :binary.copy("ab", 5_000)
    %{handle: handle, reference: reference, root: root} = stored(bytes)

    assert {:ok, transfer} =
             open_transfer(handle, reference.use_locator, %{start: 0})

    # The object's digest is settled at open, before any chunk exists.
    assert transfer.object_digest == reference.digest
    assert transfer.total_size == byte_size(bytes)

    chunks = drain(handle, transfer, 4_096)
    assert IO.iodata_to_binary(Enum.map(chunks, & &1.bytes)) == bytes
    assert length(chunks) > 1

    # Each chunk names its own bytes and none of them names the object's.
    assert Enum.all?(chunks, &(&1.chunk_digest == digest(&1.bytes)))
    refute Enum.any?(chunks, &(&1.chunk_digest == transfer.object_digest))
    assert :ok = close_transfer(handle, transfer)

    # Verification is per transfer rather than per chunk, which is why a corrupt
    # object is caught at open and no number of reads is what catches it.
    path = Path.join([root, binary_part(reference.locator, 0, 2), reference.locator])
    File.write!(path, binary_part(bytes, 0, byte_size(bytes) - 1) <> "!")

    assert {:error, :artifact_digest_mismatch} =
             open_transfer(handle, reference.use_locator, %{start: 0})

    assert [] = Transfers.live(handle.transfers)
  end

  test "the attachment owned open read close API refuses another attachment session or runtime and discloses no path" do
    %{handle: handle, reference: reference} = stored("bytes for one attachment")
    %{runtime: runtime, session_id: session_id} = session(handle)
    reference = for_session(handle, reference, session_id)

    {:ok, holder} = Loopex.attach(runtime, session_id, after_event_sequence: 0)
    request = %{use_locator: reference.use_locator, start: 0}

    assert {:ok, transfer} = Loopex.open_artifact_transfer(holder, request)

    # Nothing handed back names a filesystem location. A caller that could read a
    # path could read the object without the store.
    refute Map.has_key?(transfer, :path)
    refute inspect(transfer) =~ handle.root
    refute inspect(transfer) =~ "/tmp"

    assert {:ok, chunk} = Loopex.read_artifact_chunk(holder, transfer.transfer_ref, 16)
    refute Map.has_key?(chunk, :path)
    refute inspect(chunk) =~ handle.root

    # A different runtime holds neither the transfer nor its attachment, and
    # cannot read it by naming its reference.
    %{runtime: elsewhere, session_id: elsewhere_session} = session(handle)
    {:ok, stranger} = Loopex.attach(elsewhere, elsewhere_session, after_event_sequence: 0)

    assert {:error, :unknown_transfer} =
             Loopex.read_artifact_chunk(stranger, transfer.transfer_ref, 16)

    # Replacing the first attachment by name releases what it held: the
    # reference is readable through neither.
    cleanup = observe_replacement_cleanup(runtime, handle, transfer)

    {:ok, replacement} =
      Loopex.Runtime.attach_for_holder(runtime, session_id, self(),
        request_id: "replace-holder",
        after_event_sequence: 0,
        replace_attachment_id: holder.attachment_id
      )

    assert {:error, :unknown_transfer} =
             Loopex.read_artifact_chunk(replacement, transfer.transfer_ref, 16)

    assert {:error, :stale_attachment} =
             Loopex.read_artifact_chunk(holder, transfer.transfer_ref, 16)

    join_replacement_cleanup(cleanup, handle)
  end

  test "whole first last empty and overrun windows and every distinct refusal reason behave exactly as ADR 0028 specifies" do
    bytes = "0123456789"
    %{handle: handle, reference: reference} = stored(bytes)

    for {window, expected} <- [
          {%{start: 0}, bytes},
          {%{start: 0, length: 1}, "0"},
          {%{start: 9, length: 1}, "9"},
          {%{start: 10, length: 0}, ""}
        ] do
      assert {:ok, transfer} =
               open_transfer(handle, reference.use_locator, window)

      read = handle |> drain(transfer, 4) |> Enum.map(& &1.bytes) |> IO.iodata_to_binary()
      assert read == expected, "window #{inspect(window)} read #{inspect(read)}"
      assert :ok = close_transfer(handle, transfer)
    end

    # A window reaching past the object is refused rather than clamped: clamping
    # would return fewer bytes than asked for with no way to tell.
    for overrun <- [%{start: 11}, %{start: 0, length: 11}, %{start: 9, length: 2}] do
      assert {:error, :invalid_window} =
               open_transfer(handle, reference.use_locator, overrun),
             "overrun #{inspect(overrun)} was admitted"
    end

    # The reasons stay distinct from one another, so a client can branch on them.
    %{reference: other} = stored("another object", handle)

    reasons = [
      elem(open_transfer(handle, other.use_locator, %{start: 0}, session_id: "wrong-session"), 1),
      elem(
        open_transfer(handle, "use:" <> String.duplicate("a", 64), %{start: 0}),
        1
      ),
      elem(
        open_transfer(handle, reference.use_locator, %{start: 11}),
        1
      ),
      elem(Artifacts.read_transfer(handle, %{transfer_ref: "never-opened"}, 4), 1)
    ]

    assert length(Enum.uniq(reasons)) == length(reasons), "reasons collided: #{inspect(reasons)}"
  end

  test "an open that exceeds its deadline or work budget refuses before any snapshot bytes are retained" do
    %{handle: handle, reference: reference} = stored(:binary.copy("w", 200_000))

    constrained = budget_store(handle, 1_024)

    for {placement, options, expected} <- [
          {constrained, [], :open_work_budget_exhausted},
          {handle, [open_deadline_ms: -1], :open_deadline_exhausted}
        ] do
      assert {:error, ^expected} =
               open_transfer(placement, reference.use_locator, %{start: 0}, options)

      assert [] = Transfers.live(placement.transfers)
      assert {:ok, []} = File.ls(Path.join(handle.root, "transfers"))
    end
  end

  test "per connection and per runtime transfer limits refuse independently" do
    limits = ArtifactStore.transfer_limits()

    # They are separate numbers, and the per-attachment share is the smaller of
    # the two, so exhausting one is not the same event as exhausting the other.
    assert limits.per_attachment < limits.per_runtime

    %{handle: handle, reference: reference} = stored("shared object")
    %{runtime: runtime, session_id: session_id} = session(handle)
    reference = for_session(handle, reference, session_id)
    {:ok, attachment} = Loopex.attach(runtime, session_id, after_event_sequence: 0)
    request = %{use_locator: reference.use_locator, start: 0}

    held =
      for _index <- 1..limits.per_attachment do
        assert {:ok, transfer} = Loopex.open_artifact_transfer(attachment, request)
        transfer
      end

    # One attachment reaches its own share first, while the runtime still has
    # room: the two ceilings refuse independently.
    assert {:error, :transfer_limit_reached} = Loopex.open_artifact_transfer(attachment, request)
    assert length(Transfers.live(handle.transfers)) == limits.per_attachment
    assert limits.per_attachment < limits.per_runtime

    # The runtime's own ceiling is reached by opening directly against the store,
    # past any one attachment's share.
    direct =
      for _index <- 1..(limits.per_runtime - limits.per_attachment) do
        assert {:ok, transfer} =
                 open_transfer(handle, reference.use_locator, %{start: 0}, session_id: session_id)

        transfer
      end

    assert {:error, :transfer_limit_reached} =
             open_transfer(handle, reference.use_locator, %{start: 0})

    Enum.each(direct, &close_transfer(handle, &1))
    Enum.each(held, &Loopex.close_artifact_transfer(attachment, &1.transfer_ref))
    assert [] = Transfers.live(handle.transfers)
  end

  test "streaming memory stays bounded well above the chunk ceiling and startup scavenging removes only owned regular files without following links" do
    bytes = :binary.copy("m", 1_000_000)
    %{handle: handle, reference: reference} = stored(bytes)

    assert {:ok, transfer} =
             open_transfer(handle, reference.use_locator, %{start: 0})

    # A megabyte read in small pieces never holds a megabyte: each read returns
    # its own chunk and nothing accumulates between them.
    {peak, total} =
      Enum.reduce_while(1..2_000, {0, 0}, fn _index, {peak, total} ->
        case Artifacts.read_transfer(handle, transfer, 4_096) do
          {:ok, :complete} ->
            {:halt, {peak, total}}

          {:ok, chunk} ->
            {:cont, {max(peak, byte_size(chunk.bytes)), total + byte_size(chunk.bytes)}}
        end
      end)

    assert total == byte_size(bytes)
    assert peak <= 4_096
    assert :ok = close_transfer(handle, transfer)

    # Scavenging at startup owns the regular files in its own scratch root and
    # nothing else. A link is not followed, because following one would let a
    # link decide what a store deletes.
    root = Path.join(System.tmp_dir!(), "loopex-owned-#{:erlang.unique_integer([:positive])}")
    scratch = Path.join(root, "transfers")
    File.mkdir_p!(scratch)
    on_exit(fn -> File.rm_rf(root) end)

    stale = Path.join(scratch, "left-behind")
    File.write!(stale, "a snapshot a crash left behind")
    outside = Path.join(root, "outside")
    File.write!(outside, "not the scratch root's business")
    File.ln_s!(outside, Path.join(scratch, "link-out"))

    {:ok, owner} = Transfers.start_link(root: root)
    on_exit(fn -> if Process.alive?(owner), do: GenServer.stop(owner) end)

    refute File.exists?(stale)
    assert File.exists?(outside)
    assert File.read!(outside) == "not the scratch root's business"
  end

  test "genuine old format artifacts remain readable and removing the transfer capability restores the prior API without rewriting data" do
    bytes = "an artifact written before transfers existed"
    %{handle: handle, reference: reference} = stored(bytes)

    # The prior API reads it whole, and describes it, without a transfer.
    assert {:ok, ^bytes} = Artifacts.fetch(handle, object(reference))
    assert {:ok, stat} = Artifacts.stat(handle, reference.locator)
    assert stat.digest == reference.digest
    assert {:ok, described} = Artifacts.describe(handle, reference.use_locator)
    assert described.object_locator == reference.locator

    # An adapter without the transfer family keeps exactly that API and reads the
    # same bytes: nothing was migrated to make transfers possible.
    refute ArtifactStore.supports_transfer?(LegacyStore)
    assert {:ok, ^bytes} = LegacyStore.fetch(handle, object(reference))
    assert {:ok, legacy_stat} = LegacyStore.stat(handle, reference.locator)
    assert legacy_stat.digest == reference.digest
  end

  test "an unsupported ArtifactStore reports unsupported rather than falling back to a whole object fetch" do
    %{handle: handle, reference: reference} = stored("bytes")
    %{runtime: runtime, session_id: session_id} = session(handle, LegacyStore)
    reference = for_session(handle, reference, session_id)
    {:ok, attachment} = Loopex.attach(runtime, session_id, after_event_sequence: 0)

    request = %{use_locator: reference.use_locator, start: 0}

    # The refusal names the missing capability. A fallback that quietly fetched
    # the whole object would defeat the bound the family exists for.
    assert {:error, :artifact_transfer_unsupported} =
             Loopex.open_artifact_transfer(attachment, request)
  end

  test "wrong session use object and use swaps and corruption outside the requested window refuse at open before any bytes" do
    %{handle: handle, reference: first} = stored("first object")
    %{reference: second} = stored("second object", handle)

    # The routed session is checked against the actual immutable use.
    assert {:error, :artifact_use_mismatch} =
             open_transfer(handle, second.use_locator, %{start: 0}, session_id: "wrong-session")

    assert {:error, :artifact_use_mismatch} =
             open_transfer(handle, first.use_locator, %{start: 0}, session_id: "wrong-session")

    assert {:ok, selected} = open_transfer(handle, second.use_locator, %{start: 0})
    assert selected.object_digest == second.digest

    assert IO.iodata_to_binary(Enum.map(drain(handle, selected, 16), & &1.bytes)) ==
             "second object"

    assert :ok = close_transfer(handle, selected)

    assert {:error, :unknown_artifact_use} =
             open_transfer(handle, "use:" <> String.duplicate("a", 64), %{start: 0})

    # Corruption outside the requested window still refuses, because the open
    # verifies the object rather than the part a caller asked for.
    %{handle: corrupt, reference: reference, root: root, bytes: bytes} =
      stored(:binary.copy("z", 4_096))

    path = Path.join([root, binary_part(reference.locator, 0, 2), reference.locator])
    File.write!(path, binary_part(bytes, 0, byte_size(bytes) - 1) <> "!")

    assert {:error, :artifact_digest_mismatch} =
             open_transfer(corrupt, reference.use_locator, %{
               start: 0,
               length: 16
             })

    assert [] = Transfers.live(corrupt.transfers)
  end

  test "a same inode same size rewrite of the original after open never reaches a chunk and every chunk matches the reported object digest" do
    bytes = "original-bytes"
    replacement = "REWRITEN-bytes"
    %{handle: handle, reference: reference, root: root} = stored(bytes)

    assert {:ok, transfer} =
             open_transfer(handle, reference.use_locator, %{start: 0})

    # Same path, same size, different bytes. Only a snapshot taken at open
    # survives this, which is exactly why one is taken.
    path = Path.join([root, binary_part(reference.locator, 0, 2), reference.locator])
    before = File.stat!(path)
    assert byte_size(replacement) == byte_size(bytes)
    File.write!(path, replacement)
    after_write = File.stat!(path)

    assert after_write.size == before.size
    assert after_write.inode == before.inode

    chunks = drain(handle, transfer, 4)
    read = chunks |> Enum.map(& &1.bytes) |> IO.iodata_to_binary()

    assert read == bytes
    assert digest(read) == transfer.object_digest
    assert Enum.all?(chunks, &(&1.chunk_digest == digest(&1.bytes)))
    assert :ok = close_transfer(handle, transfer)
  end

  test "concurrent transfer and connection work exhaustion refuse and close cancellation loss and expiry release every descriptor" do
    %{handle: handle, reference: reference} = stored("bytes for descriptors")
    limits = ArtifactStore.transfer_limits()

    # Exhaustion refuses rather than queues.
    opened =
      for _index <- 1..limits.per_runtime do
        assert {:ok, transfer} =
                 open_transfer(handle, reference.use_locator, %{start: 0})

        transfer
      end

    assert {:error, :transfer_limit_reached} =
             open_transfer(handle, reference.use_locator, %{start: 0})

    # Closing releases: every way a transfer ends gives back what it held, so the
    # ceiling counts live transfers rather than transfers ever opened.
    Enum.each(opened, &close_transfer(handle, &1))
    assert [] = Transfers.live(handle.transfers)
    assert {:ok, []} = File.ls(Path.join(handle.root, "transfers"))

    # Expiry releases the same way, without anyone asking.
    root = Path.join(System.tmp_dir!(), "loopex-release-#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    expiring = Map.put(ArtifactStore.transfer_limits(), :lifetime_ms, 150)
    {:ok, owner} = Transfers.start_link(root: root, limits: expiring)
    on_exit(fn -> if Process.alive?(owner), do: GenServer.stop(owner) end)
    short = %{root: root, transfers: owner}
    {:ok, expiring_reference} = Artifacts.put(short, "bytes that outlive nothing", @use)

    assert {:ok, expired} =
             open_transfer(short, expiring_reference.use_locator, %{start: 0})

    Process.sleep(300)

    assert [id] = Transfers.live(owner)
    assert id == expired.transfer_ref
    assert {:error, :unknown_transfer} = Artifacts.read_transfer(short, expired, 8)
    assert :ok = close_transfer(short, expired)
    assert [] = Transfers.live(owner)
    assert {:ok, []} = File.ls(Path.join(root, "transfers"))
  end

  test "unlinked owner private snapshots leave no bytes in the scratch root across repeated abrupt kill and restart" do
    root = Path.join(System.tmp_dir!(), "loopex-kill-#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)

    bytes = :binary.copy("s", 64_000)

    for _round <- 1..3 do
      {:ok, owner} = Transfers.start_link(root: root)
      handle = %{root: root, transfers: owner}
      {:ok, reference} = Artifacts.put(handle, bytes, @use)

      assert {:ok, transfer} =
               open_transfer(handle, reference.use_locator, %{
                 start: 0
               })

      assert {:ok, _chunk} = Artifacts.read_transfer(handle, transfer, 16)

      # The unlinked snapshot belongs to the original I/O actor. Owner DOWN
      # and an empty scratch directory alone cannot prove that reader retired.
      record = :sys.get_state(owner).transfers[transfer.transfer_ref]
      worker = record.worker
      assert is_pid(worker)
      worker_monitor = Process.monitor(worker)
      ref = Process.monitor(owner)
      key = {__MODULE__, :original_kill_joins, make_ref()}
      Process.put(key, %{owner: false, worker: false})
      actors = [{:owner, owner, ref}, {:worker, worker, worker_monitor}]
      Process.unlink(owner)
      cutoff = System.monotonic_time(:millisecond) + 2_000

      try do
        Process.exit(owner, :kill)
        assert System.monotonic_time(:millisecond) < cutoff

        assert_receive {:DOWN, ^ref, :process, ^owner, :killed},
                       max(cutoff - System.monotonic_time(:millisecond), 0)

        Process.put(key, %{Process.get(key) | owner: true})
        assert System.monotonic_time(:millisecond) < cutoff

        assert_receive {:DOWN, ^worker_monitor, :process, ^worker, :normal},
                       max(cutoff - System.monotonic_time(:millisecond), 0)

        Process.put(key, %{Process.get(key) | worker: true})
        assert System.monotonic_time(:millisecond) < cutoff
      after
        joined = Process.delete(key)
        pending = Enum.reject(actors, fn {kind, _pid, _monitor} -> Map.fetch!(joined, kind) end)
        Enum.each(pending, fn {_kind, pid, _monitor} -> Process.exit(pid, :kill) end)

        cleanup =
          Enum.map(pending, fn {_kind, pid, monitor} ->
            receive do
              {:DOWN, ^monitor, :process, ^pid, _reason} -> :joined
            after
              max(cutoff - System.monotonic_time(:millisecond), 0) -> :unproved
            end
          end)

        Enum.each(actors, fn {_kind, _pid, monitor} -> Process.demonitor(monitor, [:flush]) end)
        refute :unproved in cleanup
      end
    end

    {:ok, restarted} = Transfers.start_link(root: root)
    on_exit(fn -> if Process.alive?(restarted), do: GenServer.stop(restarted) end)

    assert {:ok, []} = File.ls(Path.join(root, "transfers"))
  end

  test "open deadline chunk byte and read deadline budgets bound allocation and a transfer reads at most one verification plus one emit" do
    limits = ArtifactStore.transfer_limits()
    bytes = :binary.copy("b", limits.chunk_bytes + 5_000)
    %{handle: handle, reference: reference} = stored(bytes)

    assert {:ok, transfer} =
             open_transfer(handle, reference.use_locator, %{start: 0})

    # A read asking for more than the chunk ceiling is bounded to it rather than
    # served: a caller cannot widen the bound by asking for more.
    assert {:ok, chunk} = Artifacts.read_transfer(handle, transfer, limits.chunk_bytes * 4)
    assert byte_size(chunk.bytes) <= limits.chunk_bytes

    rest = drain(handle, transfer, limits.chunk_bytes)
    total = byte_size(chunk.bytes) + Enum.sum(Enum.map(rest, &byte_size(&1.bytes)))
    assert total == byte_size(bytes)

    # Every chunk is within the ceiling, so allocation is bounded by it however
    # large the object is.
    assert Enum.all?([chunk | rest], &(byte_size(&1.bytes) <= limits.chunk_bytes))

    # The object was verified once, at open. Reading again does not re-verify:
    # the digest reported at open is the one every chunk is measured against.
    assert transfer.object_digest == reference.digest
    assert :ok = close_transfer(handle, transfer)
  end

  test "reservation does no I/O and binds one original caller request context and one open" do
    %{handle: handle, reference: reference} = stored("reserved bytes")
    request = %{session_id: "transfer-session", use_locator: reference.use_locator, start: 0}
    context = opening_context(60_000)
    assert {:ok, %{transfer_ref: id}} = Artifacts.reserve_transfer(handle, request, context)
    assert id == context.transfer_ref
    record = :sys.get_state(handle.transfers).transfers[id]
    assert record.status == :reserved
    assert record.worker == nil

    assert record.work == %{
             source_read_bytes: 0,
             snapshot_write_debit: 0,
             metadata_read_bytes: 0,
             write_uncertain: false
           }

    assert {:error, :reservation_conflict} = Artifacts.reserve_transfer(handle, request, context)
    other = Task.async(fn -> Artifacts.open_transfer(handle, request, context) end)
    assert {:error, :reservation_conflict} = Task.await(other)

    assert {:error, :reservation_conflict} =
             Artifacts.open_transfer(handle, %{request | start: 1}, context)

    changed = %{context | open_deadline_ms: context.open_deadline_ms + 1}
    assert {:error, :reservation_conflict} = Artifacts.open_transfer(handle, request, changed)
    assert {:ok, %{transfer: transfer}} = Artifacts.open_transfer(handle, request, context)
    assert Process.alive?(:sys.get_state(handle.transfers).transfers[id].worker)
    assert {:error, :reservation_conflict} = Artifacts.open_transfer(handle, request, context)
    assert :ok = retire_and_ack(handle, context)
    assert {:error, :unknown_transfer} = Artifacts.read_transfer(handle, transfer, 1)
    assert [] = Transfers.live(handle.transfers)
  end

  test "retired proof keeps shared capacity until the exact receipt acknowledgement" do
    %{handle: handle, reference: reference} = stored("proof capacity")
    request = %{session_id: "transfer-session", use_locator: reference.use_locator, start: 0}

    contexts =
      for _ <- 1..4 do
        context = opening_context(60_000)
        assert {:ok, %{transfer_ref: id}} = Artifacts.reserve_transfer(handle, request, context)
        assert id == context.transfer_ref
        context
      end

    extra = opening_context(60_000)

    assert {:error, %{reason: :transfer_limit_reached, state: :not_reserved}} =
             Artifacts.reserve_transfer(handle, request, extra)

    assert {:error, :transfer_limit_reached} =
             Transfers.reserve_job(handle.transfers, extra.open_deadline_ms)

    [first | rest] = contexts
    selector = retire_selector(first)

    assert {:retired, %{transfer_ref: id, receipt_ref: receipt, work: work}} =
             Artifacts.close_transfer(handle, selector)

    assert id == first.transfer_ref
    assert work.source_read_bytes == 0
    assert work.snapshot_write_debit == 0
    assert work.metadata_read_bytes == 0
    assert length(Transfers.live(handle.transfers)) == 4

    wrong_receipt = %{
      action: :acknowledge,
      transfer_ref: id,
      receipt_ref: String.duplicate("0", 32)
    }

    assert {:error, :retirement_receipt_mismatch} =
             Artifacts.close_transfer(handle, wrong_receipt)

    assert {:error, %{reason: :transfer_limit_reached}} =
             Artifacts.reserve_transfer(handle, request, extra)

    assert {:retired, %{receipt_ref: ^receipt}} = Artifacts.close_transfer(handle, selector)

    assert :ok =
             Artifacts.close_transfer(handle, %{
               action: :acknowledge,
               transfer_ref: id,
               receipt_ref: receipt
             })

    assert :ok =
             Artifacts.close_transfer(handle, %{
               action: :acknowledge,
               transfer_ref: id,
               receipt_ref: receipt
             })

    assert {:ok, %{transfer_ref: extra_id}} = Artifacts.reserve_transfer(handle, request, extra)
    assert extra_id == extra.transfer_ref
    Enum.each([extra | rest], &retire_and_ack(handle, &1))
    assert [] = Transfers.live(handle.transfers)
  end

  test "expired and malformed original contexts refuse reservation without allocating custody" do
    %{handle: handle, reference: reference} = stored("expired reservation")
    request = %{session_id: "transfer-session", use_locator: reference.use_locator, start: 0}
    expired = opening_context(-1)

    assert {:error, %{reason: :open_deadline_exhausted, state: :not_reserved}} =
             Artifacts.reserve_transfer(handle, request, expired)

    assert {:error, :invalid_open_context} =
             Artifacts.reserve_transfer(handle, request, %{expired | object_work_bytes: 1_024})

    assert {:error, :invalid_artifact_request} =
             Artifacts.reserve_transfer(
               handle,
               Map.put(request, :object, object(reference)),
               opening_context(60_000)
             )

    assert {:error, :invalid_artifact_request} =
             Artifacts.reserve_transfer(
               handle,
               Map.put(request, :length, nil),
               opening_context(60_000)
             )

    assert {:error, :reservation_required} =
             Artifacts.open_transfer(handle, request, opening_context(60_000))

    assert [] = Transfers.live(handle.transfers)
    assert {:ok, []} = File.ls(Path.join(handle.root, "transfers"))
  end

  test "actual metadata corruption and session mismatch refuse before source bytes are read" do
    %{handle: handle, reference: reference} = stored("metadata first")

    assert {:error, :artifact_use_mismatch} =
             open_transfer(handle, reference.use_locator, %{start: 0},
               session_id: "different-session"
             )

    digest = binary_part(reference.use_locator, 4, 64)
    path = Path.join([handle.root, "uses", binary_part(digest, 0, 2), digest])
    File.write!(path, File.read!(path) <> <<0>>)
    File.rm!(Path.join([handle.root, binary_part(reference.locator, 0, 2), reference.locator]))
    request = %{session_id: "transfer-session", use_locator: reference.use_locator, start: 0}
    context = opening_context(60_000)
    assert {:ok, _} = Artifacts.reserve_transfer(handle, request, context)

    assert {:error, %{reason: :artifact_integrity_failed, state: :retired, work: work}} =
             Artifacts.open_transfer(handle, request, context)

    assert work.source_read_bytes == 0
    assert work.snapshot_write_debit == 0
    assert work.metadata_read_bytes > 0
    assert :ok = retire_and_ack(handle, context)
  end

  test "original caller loss retires its actual reader and retains proof until acknowledgement" do
    %{handle: handle, reference: reference} = stored("original custody")
    request = %{session_id: "transfer-session", use_locator: reference.use_locator, start: 0}
    context = opening_context(60_000)
    parent = self()

    {caller, caller_monitor} =
      spawn_monitor(fn ->
        assert {:ok, _} = Artifacts.reserve_transfer(handle, request, context)
        assert {:ok, %{transfer: transfer}} = Artifacts.open_transfer(handle, request, context)
        send(parent, {:adopted, self(), transfer})

        receive do
          :complete -> :ok
        end
      end)

    on_exit(fn -> if Process.alive?(caller), do: Process.exit(caller, :kill) end)
    assert_receive {:adopted, ^caller, transfer}, 5_000
    record = :sys.get_state(handle.transfers).transfers[context.transfer_ref]
    worker = record.worker
    worker_monitor = Process.monitor(worker)
    assert Process.alive?(caller)
    assert Process.alive?(worker)
    cleanup_deadline = System.monotonic_time(:millisecond) + 5_000
    send(caller, :complete)
    remaining = max(0, cleanup_deadline - System.monotonic_time(:millisecond))
    assert_receive {:DOWN, ^caller_monitor, :process, ^caller, :normal}, remaining
    assert System.monotonic_time(:millisecond) < cleanup_deadline
    assert :ok = retire_and_ack(handle, context, cleanup_deadline)
    remaining = max(0, cleanup_deadline - System.monotonic_time(:millisecond))
    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, :normal}, remaining
    assert System.monotonic_time(:millisecond) < cleanup_deadline
    assert {:error, :unknown_transfer} = Artifacts.read_transfer(handle, transfer, 1)
    assert [] = Transfers.live(handle.transfers)
    assert {:ok, []} = File.ls(Path.join(handle.root, "transfers"))
  end

  test "a full 64 MiB object retains exact payload and separately accounted metadata work" do
    bytes = :binary.copy(<<42>>, 67_108_864)
    %{handle: handle, reference: reference} = stored(bytes)
    assert {:ok, transfer} = open_transfer(handle, reference.use_locator, %{start: 0})
    assert transfer.total_size == 67_108_864
    assert transfer.object_digest == digest(bytes)
    assert {:ok, chunk} = Artifacts.read_transfer(handle, transfer, 32_768)
    assert chunk.bytes == :binary.copy(<<42>>, 32_768)
    assert :ok = close_transfer(handle, transfer)
    assert [] = Transfers.live(handle.transfers)
  end

  test "a blocked original retirement reuses one actor slot and one pending close" do
    %{handle: handle, reference: reference} = stored("blocked retirement")
    request = %{session_id: "transfer-session", use_locator: reference.use_locator, start: 0}
    context = opening_context(60_000)
    assert {:ok, _} = Artifacts.reserve_transfer(handle, request, context)
    assert {:ok, _} = Artifacts.open_transfer(handle, request, context)
    worker = :sys.get_state(handle.transfers).transfers[context.transfer_ref].worker
    monitor = Process.monitor(worker)
    selector = retire_selector(context)
    true = :erlang.suspend_process(worker)

    try do
      task = Task.async(fn -> Artifacts.close_transfer(handle, selector) end)
      # Synchronize actual admission through the responsive original owner rather
      # than assuming the Task's send has already been handled.
      eventually(fn ->
        :sys.get_state(handle.transfers).transfers[context.transfer_ref].close_from != nil
      end)

      before = :sys.get_state(handle.transfers).transfers[context.transfer_ref]
      assert before.worker == worker
      assert {:error, :cleanup_unproved} = Artifacts.close_transfer(handle, selector)
      after_close = :sys.get_state(handle.transfers).transfers[context.transfer_ref]
      assert after_close.worker == worker
      assert after_close.worker_monitor == before.worker_monitor
      assert after_close.close_from == before.close_from
      assert after_close.close_deadline == before.close_deadline
      assert length(Transfers.live(handle.transfers)) == 1
      true = :erlang.resume_process(worker)
      assert System.monotonic_time(:millisecond) < selector.close_deadline_ms

      assert {:retired, %{receipt_ref: receipt}} =
               Task.await(
                 task,
                 max(1, selector.close_deadline_ms - System.monotonic_time(:millisecond))
               )

      assert System.monotonic_time(:millisecond) < selector.close_deadline_ms
      remaining = max(0, selector.close_deadline_ms - System.monotonic_time(:millisecond))
      assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, remaining
      assert System.monotonic_time(:millisecond) < selector.close_deadline_ms

      assert :ok =
               Artifacts.close_transfer(handle, %{
                 action: :acknowledge,
                 transfer_ref: context.transfer_ref,
                 receipt_ref: receipt
               })

      assert System.monotonic_time(:millisecond) < selector.close_deadline_ms
      assert [] = Transfers.live(handle.transfers)
    after
      if Process.alive?(worker) do
        try do
          :erlang.resume_process(worker)
        catch
          :error, :badarg -> :ok
        end
      end
    end
  end

  test "original I/O actor loss retains unavailable accounting and occupied capacity" do
    %{handle: handle, reference: reference} = stored("lost accounting")
    request = %{session_id: "transfer-session", use_locator: reference.use_locator, start: 0}
    context = opening_context(60_000)
    assert {:ok, _} = Artifacts.reserve_transfer(handle, request, context)
    assert {:ok, _} = Artifacts.open_transfer(handle, request, context)
    worker = :sys.get_state(handle.transfers).transfers[context.transfer_ref].worker
    monitor = Process.monitor(worker)
    Process.exit(worker, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^worker, :killed}, 2_000

    eventually(fn ->
      :sys.get_state(handle.transfers).transfers[context.transfer_ref].worker_joined
    end)

    record = :sys.get_state(handle.transfers).transfers[context.transfer_ref]
    assert record.work == :unavailable
    assert record.proof == false
    assert record.receipt == nil
    assert [id] = Transfers.live(handle.transfers)
    assert id == context.transfer_ref

    selector = %{
      retire_selector(context)
      | close_deadline_ms: System.monotonic_time(:millisecond)
    }

    assert {:error, :cleanup_unproved} = Artifacts.close_transfer(handle, selector)

    assert {:error, :retirement_receipt_mismatch} =
             Artifacts.close_transfer(
               handle,
               %{action: :acknowledge, transfer_ref: id, receipt_ref: String.duplicate("0", 32)}
             )

    assert [^id] = Transfers.live(handle.transfers)
  end

  defp retire_selector(context),
    do: %{
      action: :retire,
      transfer_ref: context.transfer_ref,
      open_deadline_ms: context.open_deadline_ms,
      close_deadline_ms: System.monotonic_time(:millisecond) + 5_000
    }

  # Concept: replacement retires the original custody asynchronously in both attachment cases.
  # Technical depth: this fixture's BEFORE-trigger cutoff is no later than Core's
  # first C + 5000; it is not an observation of C's selector. All original actors
  # are live/monitored before replacement, and the process-local debug hook emits
  # at most two closed labels before removing itself. A serial state fence after
  # both inputs proves Core consumed its own DOWNs, independently of our monitors.
  defp observe_replacement_cleanup(runtime, handle, transfer) do
    fixture_observation_cutoff =
      System.monotonic_time(:millisecond) + ArtifactStore.transfer_limits().cleanup_deadline_ms

    dispatcher = runtime.artifact_dispatcher
    id = transfer.transfer_ref
    state = :sys.get_state(dispatcher, replacement_remaining(fixture_observation_cutoff))
    original = Map.fetch!(state.artifact_transfers, id)
    assert original.phase === :live
    assert original.cleanup === nil
    assert original.invocation === :idle
    assert original.read === nil
    assert original.lost === false
    assert state.artifact_monitors[original.custodian_monitor] === {id, :custodian, original.custodian}
    assert state.artifact_monitors[original.observer_monitor] === {id, :observer, original.observer}

    local = :sys.get_state(handle.transfers, replacement_remaining(fixture_observation_cutoff))
    record = Map.fetch!(local.transfers, id)
    assert record.status === :live
    assert record.close_deadline === nil
    assert record.close_selector_deadline === nil
    assert record.caller === original.custodian

    actors =
      for {kind, pid} <- [
            {:custodian, original.custodian},
            {:observer, original.observer},
            {:store_worker, record.worker}
          ] do
        assert is_pid(pid)
        assert Process.alive?(pid)
        monitor = Process.monitor(pid)
        assert Process.alive?(pid)
        {kind, pid, monitor}
      end

    original_monitors = %{
      original.custodian_monitor => {original.custodian, :custodian},
      original.observer_monitor => {original.observer, :observer}
    }

    observer = self()
    hook_id = make_ref()

    hook = fn
      seen, {:in, {:DOWN, monitor, :process, pid, :normal}}, _extra ->
        case Map.get(original_monitors, monitor) do
          {^pid, kind} ->
            unless MapSet.member?(seen, kind),
              do: send(observer, {:replacement_cleanup_down, hook_id, self(), id, kind})

            seen = MapSet.put(seen, kind)
            if MapSet.size(seen) === 2, do: :done, else: seen

          _other ->
            seen
        end

      seen, _event, _extra ->
        seen
    end

    assert :ok =
             :sys.install(
               dispatcher,
               {hook_id, hook, MapSet.new()},
               replacement_remaining(fixture_observation_cutoff)
             )

    for {_kind, pid, _monitor} <- actors, do: assert(Process.alive?(pid))
    assert System.monotonic_time(:millisecond) < fixture_observation_cutoff
    %{cutoff: fixture_observation_cutoff, dispatcher: dispatcher, id: id, actors: actors, hook_id: hook_id}
  end

  defp join_replacement_cleanup(cleanup, handle) do
    for {_kind, pid, monitor} <- cleanup.actors do
      remaining = replacement_remaining(cleanup.cutoff)
      assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, remaining
      assert System.monotonic_time(:millisecond) < cleanup.cutoff
    end

    %{dispatcher: dispatcher, id: id, hook_id: hook_id} = cleanup

    for kind <- [:custodian, :observer] do
      remaining = replacement_remaining(cleanup.cutoff)
      assert_receive {:replacement_cleanup_down, ^hook_id, ^dispatcher, ^id, ^kind}, remaining
      assert System.monotonic_time(:millisecond) < cleanup.cutoff
    end

    state = :sys.get_state(dispatcher, replacement_remaining(cleanup.cutoff))
    refute Map.has_key?(state.artifact_transfers, id)
    assert [] = GenServer.call(handle.transfers, :live, replacement_remaining(cleanup.cutoff))
    assert System.monotonic_time(:millisecond) < cleanup.cutoff
  end

  defp replacement_remaining(cutoff) do
    remaining = cutoff - System.monotonic_time(:millisecond)
    assert remaining > 0
    remaining
  end

  defp session(artifact_handle, adapter \\ Loopex.Store.Local.Artifacts) do
    path = Path.join(System.tmp_dir!(), "loopex-store-#{:erlang.unique_integer([:positive])}")
    {:ok, store_pid} = Loopex.Store.Local.start_link(path: path)
    {:ok, store} = Loopex.Store.new(Loopex.Store.Local, store_pid)

    options =
      [
        context_token_budget: 8_192,
        runtime_id: "artifact-transfer",
        store: store,
        session_creation_defaults:
          Loopex.ConfiguredGenesisFixture.genesis([]) |> Map.drop([:kind, "options"])
      ]
      |> then(fn options ->
        case artifact_handle do
          nil ->
            options

          handle ->
            Keyword.put(options, :artifact_store, %{module: adapter, handle: handle})
        end
      end)

    {:ok, runtime} = Loopex.start_link(options)

    on_exit(fn ->
      if Loopex.Runtime.alive?(runtime), do: Loopex.stop(runtime)
      stop_quietly(store_pid)
      File.rm_rf(path)
    end)

    :ok = Loopex.ConfiguredGenesisFixture.await_creation_ready(runtime)
    {:ok, session_id} = Loopex.create_session(runtime, %{}, command_id: "create")
    %{runtime: runtime, session_id: session_id}
  end

  defp open_transfer(handle, use_locator, window, options \\ []) do
    request =
      Map.merge(window, %{
        session_id: Keyword.get(options, :session_id, "transfer-session"),
        use_locator: use_locator
      })

    context = opening_context(Keyword.get(options, :open_deadline_ms, 60_000))

    with {:ok, %{transfer_ref: id}} <- Artifacts.reserve_transfer(handle, request, context) do
      assert id == context.transfer_ref

      case Artifacts.open_transfer(handle, request, context) do
        {:ok, %{transfer: transfer, use: use, work: work}} ->
          assert System.monotonic_time(:millisecond) < context.open_deadline_ms
          assert ArtifactStore.valid_transfer_use?(use, request)
          assert work.source_read_bytes == transfer.total_size
          assert work.snapshot_write_debit == transfer.total_size
          assert work.metadata_read_bytes > 0
          assert work.write_uncertain == false
          Process.put({:transfer_context, transfer.transfer_ref}, context)
          {:ok, transfer}

        {:error, %{reason: reason, transfer_ref: ^id}} ->
          assert :ok = retire_and_ack(handle, context)
          {:error, reason}
      end
    else
      {:error, %{reason: reason, state: :not_reserved}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  defp opening_context(allowance) do
    %{
      transfer_ref: Base.encode16(:crypto.strong_rand_bytes(16), case: :lower),
      open_deadline_ms: System.monotonic_time(:millisecond) + allowance,
      object_work_bytes: 134_217_728,
      metadata_read_bytes: 131_073
    }
  end

  defp close_transfer(handle, transfer) do
    context = Process.get({:transfer_context, transfer.transfer_ref})
    retire_and_ack(handle, context)
  end

  defp retire_and_ack(handle, context, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + 5_000

    selector = %{
      action: :retire,
      transfer_ref: context.transfer_ref,
      open_deadline_ms: context.open_deadline_ms,
      close_deadline_ms: deadline
    }

    case Artifacts.close_transfer(handle, selector) do
      {:retired, %{transfer_ref: id, receipt_ref: receipt, work: work}} ->
        assert id == context.transfer_ref
        assert System.monotonic_time(:millisecond) < selector.close_deadline_ms
        assert ArtifactStore.valid_transfer_work?(work)

        assert :ok =
                 Artifacts.close_transfer(handle, %{
                   action: :acknowledge,
                   transfer_ref: id,
                   receipt_ref: receipt
                 })

        assert System.monotonic_time(:millisecond) < selector.close_deadline_ms
        Process.put({:transfer_acknowledged, id}, true)
        :ok

      {:unregistered, %{transfer_ref: id}} ->
        assert id == context.transfer_ref
        assert Process.get({:transfer_acknowledged, id}) == true
        :ok
    end
  end

  defp budget_store(handle, budget) do
    limits = Map.put(ArtifactStore.transfer_limits(), :open_work_bytes, budget)
    owner = start_supervised!({Transfers, root: handle.root, limits: limits}, id: make_ref())
    %{handle | transfers: owner}
  end

  defp for_session(handle, reference, session_id) do
    assert {:ok, bytes} = Artifacts.fetch(handle, object(reference))
    use = put_in(@use, [:metadata, "session_id"], session_id)
    assert {:ok, bound} = Artifacts.put(handle, bytes, use)
    bound
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
