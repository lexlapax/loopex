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
