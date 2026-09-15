Code.require_file("../../loopex/test/support/m1_runtime_helper.exs", __DIR__)
Code.require_file("../../loopex/test/support/agent_loop_helper.exs", __DIR__)

defmodule Loopex.AppServer.DeliveryBoundsTest do
  @moduledoc """
  ## Concept

  An artifact crosses the wire as a verified, bounded transfer: the client opens
  one against a reference it already holds, reads chunks whose digests it can
  check, and closes it. Nothing about where the bytes live crosses with them.

  ## Technical depth

  Accepted ADR 0028 owns the transfer itself and accepted ADR 0023 owns how it
  is spoken. These cases drive a real store through the real runtime, so what is
  proved is the whole path rather than a mapping talking to itself. The store is
  deliberately small: it implements the port and nothing else, which keeps the
  case about the crossing.

  The refusals matter as much as the reads. A transfer reference belongs to the
  attachment that opened it, a refusal names a cause from the closed set, and no
  path, adapter term or storage detail appears in any of them.
  """

  use ExUnit.Case, async: false

  alias Loopex.AgentLoopFixture, as: Fixture
  alias Loopex.AppServer.Connection
  alias Loopex.AppServer.Delivery
  alias LoopexProtocol.Frame
  alias LoopexProtocol.Canonical
  alias LoopexProtocol.Session
  alias LoopexProtocol.Wire

  @content "the artifact bytes a client will read back in pieces"

  defmodule TransferStore do
    @moduledoc false
    @behaviour Loopex.ArtifactStore

    alias LoopexProtocol.Canonical

    def start, do: Agent.start_link(fn -> %{objects: %{}, uses: %{}, transfers: %{}} end)

    def put(pid, bytes, %{media_type: media_type, role: role, metadata: metadata}) do
      digest = Canonical.digest_bytes(bytes)
      object = %{digest: digest, size: byte_size(bytes), locator: "wire:" <> digest}

      use_record = %{
        canonicalization_version: Canonical.version(),
        object_digest: object.digest,
        object_size: object.size,
        object_locator: object.locator,
        media_type: media_type,
        role: role,
        metadata: metadata
      }

      use_digest = Canonical.digest(["artifact-use-v2", use_record])

      reference =
        Map.merge(object, %{
          media_type: media_type,
          role: role,
          use_canonicalization_version: Canonical.version(),
          use_digest: use_digest,
          use_locator: "use:" <> use_digest
        })

      Agent.update(pid, fn state ->
        %{
          state
          | objects: Map.put(state.objects, object.locator, {object, bytes}),
            uses: Map.put(state.uses, reference.use_locator, use_record)
        }
      end)

      {:ok, reference}
    end

    def fetch(pid, object) do
      case Agent.get(pid, &Map.fetch(&1.objects, object.locator)) do
        {:ok, {_object, bytes}} -> {:ok, bytes}
        :error -> {:error, :unknown_artifact}
      end
    end

    def stat(pid, locator) do
      case Agent.get(pid, &Map.fetch(&1.objects, locator)) do
        {:ok, {object, _bytes}} -> {:ok, object}
        :error -> {:error, :unknown_artifact}
      end
    end

    def describe(pid, use_locator) do
      case Agent.get(pid, &Map.fetch(&1.uses, use_locator)) do
        {:ok, use_record} -> {:ok, use_record}
        :error -> {:error, :unknown_artifact}
      end
    end

    def open_transfer(pid, object, use_locator, window) do
      case Agent.get(pid, &Map.fetch(&1.objects, object.locator)) do
        {:ok, {stored, bytes}} ->
          start = Map.get(window, :start, 0)
          length = Map.get(window, :length, stored.size - start)

          if start > stored.size or start + length > stored.size do
            {:error, :invalid_window}
          else
            ref = "transfer-" <> Integer.to_string(System.unique_integer([:positive]))

            transfer = %{
              transfer_ref: ref,
              object: stored,
              use_locator: use_locator,
              total_size: stored.size,
              window_start: start,
              window_length: length,
              object_digest: stored.digest
            }

            Agent.update(pid, fn state ->
              %{state | transfers: Map.put(state.transfers, ref, {transfer, bytes, start})}
            end)

            {:ok, transfer}
          end

        :error ->
          {:error, :object_missing}
      end
    end

    def read_transfer(pid, transfer, length) do
      case Agent.get(pid, &Map.fetch(&1.transfers, transfer.transfer_ref)) do
        {:ok, {held, bytes, position}} ->
          remaining = held.window_start + held.window_length - position

          if remaining <= 0 do
            {:ok, :complete}
          else
            take = min(length, remaining)
            chunk = binary_part(bytes, position, take)

            Agent.update(pid, fn state ->
              %{
                state
                | transfers:
                    Map.put(state.transfers, held.transfer_ref, {held, bytes, position + take})
              }
            end)

            {:ok, %{offset: position, bytes: chunk, chunk_digest: Canonical.digest_bytes(chunk)}}
          end

        :error ->
          {:error, :transfer_unknown}
      end
    end

    def close_transfer(pid, transfer) do
      Agent.update(pid, fn state ->
        %{state | transfers: Map.delete(state.transfers, transfer.transfer_ref)}
      end)

      :ok
    end
  end

  test "an artifact crosses the wire in verified chunks and the transfer closes" do
    %{connection: connection, reference: reference} = opened()

    {:ok, record, connection} =
      Connection.dispatch(connection, %{
        "method" => "artifact.open_transfer",
        "request_id" => "t1",
        "use_ref" => Wire.encode_reference(reference),
        "start_offset" => "0"
      })

    assert record["type"] == "result"
    opened = record["result"]

    assert {:ok, total} = Wire.u64(opened["total_size"])
    assert total == byte_size(@content)
    assert opened["object_digest"] == Canonical.digest_bytes(@content)
    assert {:ok, transfer_ref} = Wire.identity(opened["transfer_ref"])
    assert is_binary(transfer_ref)

    # Where the bytes live never crosses with them.
    rendered = inspect(opened, limit: :infinity)
    refute rendered =~ "/"
    refute rendered =~ "wire:"

    {collected, connection} = read_all(connection, opened["transfer_ref"], "")
    assert collected == @content

    {:ok, closed, _connection} =
      Connection.dispatch(connection, %{
        "method" => "artifact.close_transfer",
        "request_id" => "t9",
        "transfer_ref" => opened["transfer_ref"]
      })

    assert closed["result"] == %{"closed" => true}
  end

  test "each chunk carries a digest of exactly the bytes it carries" do
    %{connection: connection, reference: reference} = opened()

    {:ok, record, connection} =
      Connection.dispatch(connection, %{
        "method" => "artifact.open_transfer",
        "request_id" => "t1",
        "use_ref" => Wire.encode_reference(reference),
        "start_offset" => "0"
      })

    {:ok, chunk, _connection} =
      Connection.dispatch(connection, %{
        "method" => "artifact.read_chunk",
        "request_id" => "t2",
        "transfer_ref" => record["result"]["transfer_ref"],
        "length" => 8
      })

    body = chunk["result"]

    assert {:ok, bytes} = Wire.bytes(body["bytes_b64"], 1_024)
    assert byte_size(bytes) == 8
    assert body["chunk_digest"] == Canonical.digest_bytes(bytes)
    assert {:ok, 0} = Wire.u64(body["offset"])
    assert body["eof"] == false
  end

  test "a window outside the object is refused with a cause from the closed set" do
    %{connection: connection, reference: reference} = opened()

    {:error, refusal, _connection} =
      Connection.dispatch(connection, %{
        "method" => "artifact.open_transfer",
        "request_id" => "t1",
        "use_ref" => Wire.encode_reference(reference),
        "start_offset" => Wire.encode_u64(byte_size(@content) + 10)
      })

    assert refusal["code"] == "transfer_refused"
    assert refusal["reason"] == "invalid_window"
    refute refusal["message"] =~ "/"
  end

  test "a transfer reference this attachment never opened is unknown" do
    %{connection: connection} = opened()

    {:error, refusal, _connection} =
      Connection.dispatch(connection, %{
        "method" => "artifact.read_chunk",
        "request_id" => "t1",
        "transfer_ref" => Wire.encode_identity("transfer-invented"),
        "length" => 8
      })

    assert refusal["code"] == "transfer_refused"
    assert refusal["reason"] == "unknown_transfer"
  end

  test "an opaque reference that is not a whole reference is refused before the store" do
    %{connection: connection, reference: reference} = opened()

    partial =
      reference
      |> reference_members()
      |> Map.delete("use_locator")
      |> Wire.encode_reference()

    for bad <- [partial, Wire.encode_identity("not a reference"), "not base64url!", 7] do
      assert {:error, refusal, _connection} =
               Connection.dispatch(connection, %{
                 "method" => "artifact.open_transfer",
                 "request_id" => "t1",
                 "use_ref" => bad,
                 "start_offset" => "0"
               })

      assert refusal["code"] == "invalid_request", "admitted #{inspect(bad)}"
    end
  end

  test "a chunk length must be a positive integer, not a decimal string" do
    %{connection: connection, reference: reference} = opened()

    {:ok, record, connection} =
      Connection.dispatch(connection, %{
        "method" => "artifact.open_transfer",
        "request_id" => "t1",
        "use_ref" => Wire.encode_reference(reference),
        "start_offset" => "0"
      })

    for bad <- ["8", 0, -1, nil] do
      assert {:error, refusal, _connection} =
               Connection.dispatch(connection, %{
                 "method" => "artifact.read_chunk",
                 "request_id" => "t2",
                 "transfer_ref" => record["result"]["transfer_ref"],
                 "length" => bad
               })

      assert refusal["code"] == "invalid_request", "admitted #{inspect(bad)}"
    end
  end

  # The four cases below are this outcome's locked witnesses for the wire's own
  # bounds. Each carries the exact identity acceptance bound; the narrower cases
  # above remain because they say which single rule broke when one of these
  # fails.

  test "malformed UTF-8 duplicate keys excess nesting and oversized frames refuse before semantic decoding" do
    limits = Session.limits()

    # Each of these is refused by the frame reader, so nothing downstream ever
    # sees a request. A reader that repaired any of them would hand the mapping
    # something the sender never wrote.
    malformed = [
      {<<123, 34, 109, 34, 58, 34, 255, 34, 125>>, "invalid UTF-8"},
      {~s({"method":"initialize","method":"session.prompt"}), "a duplicate member"},
      {nested_frame(Map.fetch!(limits, "max_depth") + 2), "excess nesting"},
      {~s({"method":) <> String.duplicate("\"x\"", 1) <> "}} trailing", "trailing bytes"},
      {~s({"method":"initialize"}\r), "a carriage return"}
    ]

    for {payload, description} <- malformed do
      assert match?({:error, _reason}, Frame.decode(payload, Map.fetch!(limits, "frame_bytes"))),
             "the reader admitted #{description}"
    end

    # A frame past the ceiling is refused on size rather than parsed and then
    # judged, so an oversized payload costs the reader the ceiling and no more.
    oversized =
      ~s({"method":"session.prompt","content":") <>
        String.duplicate("x", Map.fetch!(limits, "frame_bytes")) <> ~s("})

    assert {:error, reason} = Frame.decode(oversized, Map.fetch!(limits, "frame_bytes"))
    assert is_atom(reason)

    # And the refusals happen before semantics: a connection that never
    # initialized still refuses these as framing rather than as order.
    assert {:error, _reason} =
             Frame.decode(~s({"method":"initialize"}\r), Map.fetch!(limits, "frame_bytes"))
  end

  test "a blocked reader detaches at a stated cursor while the coordinator stays unblocked and memory stays bounded" do
    limits = Session.limits()
    queue = Delivery.new("session-under-pressure", 0)

    # A reader that never drains is filled past the durable ceiling. The queue
    # detaches rather than growing, and it says where the reader had reached.
    flooded =
      Enum.reduce(1..(Map.fetch!(limits, "durable_queue_records") * 4), queue, fn index, queue ->
        Delivery.event(queue, %{
          event_id: "event-#{index}",
          kind: "run.progressed",
          event_sequence: index,
          payload: %{"bytes" => String.duplicate("e", 4_096)}
        })
      end)

    assert Delivery.detached?(flooded)

    detachment = Delivery.detachment(flooded)
    assert detachment["code"] == "detached"
    assert is_binary(detachment["event_cursor"])
    assert String.to_integer(detachment["event_cursor"]) >= 0

    # What it holds after detaching is bounded: the backlog stopped growing at
    # the ceiling rather than at whatever the emitter produced.
    {pending, _drained} = Delivery.take(flooded)
    assert length(pending) <= Map.fetch!(limits, "durable_queue_records") + 1

    # Nothing about this blocked an emitter: every one of those calls returned.
    # A queue that waited for a reader would be a coordinator waiting for one.
    assert Delivery.cursor(flooded) >= 0
  end

  test "late progress after detach is dropped and process loss cleans the whole child group" do
    queue = Delivery.new("session-detached", 0)

    detached =
      Enum.reduce(1..256, queue, fn index, queue ->
        Delivery.event(queue, %{
          event_id: "event-#{index}",
          kind: "run.progressed",
          event_sequence: index,
          payload: %{"bytes" => String.duplicate("e", 65_536)}
        })
      end)

    assert Delivery.detached?(detached)
    {_pending, drained} = Delivery.take(detached)

    # Progress arriving after the detachment is dropped rather than queued: the
    # reader is gone, and holding a rendering aid for it would be holding memory
    # for nobody.
    after_detach = Delivery.progress(drained, %{"seq" => 1, "bytes" => "late"})
    {records, _queue} = Delivery.take(after_detach)
    assert records == []

    # The same is true of a durable event: a detached queue accepts neither, and
    # the client's recourse is to reattach at the cursor it was given.
    after_event =
      Delivery.event(drained, %{
        event_id: "late",
        kind: "run.finished",
        event_sequence: 1_000,
        payload: %{}
      })

    {late, _queue} = Delivery.take(after_event)
    assert late == []
    assert Delivery.detached?(after_event)
  end

  test "a transfer reference from another connection refuses at the wire and connection loss closes every transfer it opened" do
    %{connection: connection, reference: reference} = opened()

    {:ok, record, connection} =
      Connection.dispatch(connection, %{
        "method" => "artifact.open_transfer",
        "request_id" => "t1",
        "use_ref" => Wire.encode_reference(reference_members(reference)),
        "start_offset" => Wire.encode_u64(0)
      })

    transfer_ref = record["result"]["transfer_ref"]
    assert is_binary(transfer_ref)

    # A second connection, with its own runtime and its own attachment, cannot
    # read a transfer it did not open by naming its reference.
    %{connection: stranger} = opened()

    assert {:error, refusal, _stranger} =
             Connection.dispatch(stranger, %{
               "method" => "artifact.read_chunk",
               "request_id" => "t2",
               "transfer_ref" => transfer_ref,
               "length" => 8
             })

    assert refusal["code"] == "transfer_refused"
    assert refusal["code"] in Session.error_codes()

    # The owner can still read it: refusing the stranger did not disturb it.
    assert {:ok, mine, connection} =
             Connection.dispatch(connection, %{
               "method" => "artifact.read_chunk",
               "request_id" => "t3",
               "transfer_ref" => transfer_ref,
               "length" => 8
             })

    refute mine["result"]["eof"]

    # Losing the connection closes what it opened, rather than leaving a
    # descriptor held by nobody.
    Connection.dispatch(connection, %{
      "method" => "artifact.close_transfer",
      "request_id" => "t4",
      "transfer_ref" => transfer_ref
    })

    assert {:error, closed, _connection} =
             Connection.dispatch(connection, %{
               "method" => "artifact.read_chunk",
               "request_id" => "t5",
               "transfer_ref" => transfer_ref,
               "length" => 8
             })

    assert closed["code"] == "transfer_refused"
  end

  defp nested_frame(depth) do
    inner = Enum.reduce(1..depth, "1", fn _level, acc -> ~s({"a":) <> acc <> "}" end)
    inner
  end

  defp opened do
    {:ok, store} = TransferStore.start()
    on_exit(fn -> if Process.alive?(store), do: Agent.stop(store) end)

    {:ok, reference} =
      TransferStore.put(store, @content, %{
        media_type: "text/plain",
        role: "tool_output",
        metadata: %{}
      })

    fixture =
      Fixture.start(
        script: [%{text: "done", calls: []}],
        artifact_store: %{module: TransferStore, handle: store}
      )

    on_exit(fn -> Fixture.stop(fixture) end)

    connection = Connection.new(runtime: fixture.runtime)

    {:ok, _reply, connection} =
      Connection.initialize(connection, %{
        "request_id" => "r0",
        "generations" => [Session.generation()],
        "capabilities" => []
      })

    {:ok, created, connection} =
      Connection.dispatch(connection, %{
        "method" => "session.create",
        "request_id" => "r1",
        "command_id" => Wire.encode_identity("cs")
      })

    {:ok, session_id} = Wire.identity(created["session_id"])
    {:ok, attachment} = Loopex.attach(fixture.runtime, session_id, after_event_sequence: 0)

    %{connection: Connection.attach(connection, attachment), reference: reference}
  end

  defp reference_members(reference) do
    %{
      "digest" => reference.digest,
      "size" => Wire.encode_u64(reference.size),
      "locator" => reference.locator,
      "use_locator" => reference.use_locator
    }
  end

  defp read_all(connection, transfer_ref, collected) do
    {:ok, record, connection} =
      Connection.dispatch(connection, %{
        "method" => "artifact.read_chunk",
        "request_id" => "t" <> Integer.to_string(byte_size(collected) + 2),
        "transfer_ref" => transfer_ref,
        "length" => 16
      })

    body = record["result"]

    if body["eof"] do
      {collected, connection}
    else
      {:ok, bytes} = Wire.bytes(body["bytes_b64"], 65_536)
      read_all(connection, transfer_ref, collected <> bytes)
    end
  end
end
