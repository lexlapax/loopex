unless System.get_env("LOOPEX_HOME") do
  home = Path.join(System.tmp_dir!(), "ldat-home-#{Loopex.TestTmp.Daemon.token()}")
  File.mkdir_p!(home)
  System.put_env("LOOPEX_HOME", home)
  System.at_exit(fn _status -> File.rm_rf(home) end)
end

Code.require_file("../../loopex/test/support/m1_runtime_helper.exs", __DIR__)
Code.require_file("../../loopex/test/support/agent_loop_helper.exs", __DIR__)
Code.require_file("support/daemon_socket_fixture.exs", __DIR__)

defmodule LoopexDaemon.ArtifactTransferSocketTest do
  @moduledoc """
  ## Concept

  Artifact transfers over the daemon socket keep the accepted ceilings: two
  open transfers per connection and four per runtime, with a freed slot usable
  again only after its exact close.

  ## Technical depth

  Accepted ADRs 0028 and 0066 over served `loopex.experimental/4`, against the
  real Local artifact store and its transfer owner. A tool run retains one
  artifact; the controller and two observers open transfers on its use. The
  third open on one connection and the fifth on the runtime refuse with
  `transfer_limit_reached` before admission; an admitted open with an invalid
  window answers at once with unproved cleanup (an ADR 0066 early failure);
  an exact close frees one slot that a refused connection can then use, and
  reads return the original bytes.
  """

  use ExUnit.Case, async: false
  @moduletag capture_log: true

  import LoopexDaemon.Test.DaemonSocketFixture

  alias Loopex.AgentLoopFixture, as: Fixture
  alias LoopexProtocol.Wire

  @content "the file the tool wrote"

  test "two transfers per connection and four per runtime hold over the socket" do
    root = temporary_directory("loopex-artifact-socket")
    {:ok, handle} = Loopex.Store.Local.Artifacts.open(root)
    {:ok, owner} = Loopex.Store.Local.Transfers.start_link(root: root)
    Process.unlink(owner)

    on_exit(fn ->
      monitor = Process.monitor(owner)
      if Process.alive?(owner), do: GenServer.stop(owner, :normal, 5_000)
      assert_receive {:DOWN, ^monitor, :process, ^owner, _reason}, 5_000
    end)

    store = %{module: Loopex.Store.Local.Artifacts, handle: Map.put(handle, :transfers, owner)}

    producer = fn job ->
      {:ok, reference} =
        Loopex.ArtifactStore.put(store, @content, %{
          "media_type" => "text/plain",
          "role" => "tool_output",
          "session_id" => job.session_id,
          "run_id" => job.run_id,
          "operation_id" => job.operation_id,
          "attempt" => job.attempt,
          "tool_call_id" => job.tool_call_id
        })

      [reference]
    end

    fixture =
      Fixture.start(
        artifact_store: store,
        artifacts: %{"call-1" => producer},
        script: [
          %{
            text: "writing",
            calls: [%{id: "call-1", name: "write", arguments: %{"path" => "a"}}]
          },
          %{text: "done", calls: []}
        ]
      )

    on_exit(fn -> Fixture.stop(fixture) end)
    daemon = start_daemon(fixture.runtime)
    controller = initialized_client(daemon)
    {session, epoch} = controlled(controller)

    :ok =
      send_frame(controller, %{
        "method" => "session.prompt",
        "request_id" => "prompt",
        "command_id" => Wire.encode_identity("prompt"),
        "content_b64" => Wire.encode_bytes("write"),
        "writer_epoch" => epoch
      })

    records = records_until(controller, &event?(&1, "run.finished"))

    [%{"event" => %{"data" => %{"artifacts" => [artifact]}}}] =
      Enum.filter(records, &(get_in(&1, ["event", "kind"]) == "tool.finished"))

    use_ref = artifact["use_locator"]
    first = observer(daemon, session)
    second = observer(daemon, session)

    assert {:ok, a1} = open(controller, "a1", use_ref)
    assert {:ok, _a2} = open(controller, "a2", use_ref)
    assert {:refused, "transfer_limit_reached"} = open(controller, "a3", use_ref)
    assert {:ok, _b1} = open(first, "b1", use_ref)
    assert {:ok, _b2} = open(first, "b2", use_ref)
    assert {:refused, "transfer_limit_reached"} = open(second, "c1", use_ref)

    :ok =
      send_frame(controller, %{
        "method" => "artifact.read_chunk",
        "request_id" => "read",
        "transfer_ref" => a1,
        "length" => byte_size(@content)
      })

    read = reply(controller, "read")
    assert {:ok, @content} = Wire.bytes(read["result"]["bytes_b64"], 32_768)

    assert close(controller, a1)["type"] == "result"
    assert {:ok, c2} = open(second, "c2", use_ref)
    assert {:refused, "transfer_limit_reached"} = open(second, "c3", use_ref)
    assert close(second, c2)["type"] == "result"

    # Early admitted failure answers at once; its cleanup is not yet joined.
    assert {:admitted_refusal, "invalid_window", "unproved"} =
             open(second, "c-window", use_ref, Integer.to_string(byte_size(@content) + 1))

    for client <- [controller, first, second], do: :socket.close(client)
  end

  defp close(client, ref) do
    :ok =
      send_frame(client, %{
        "method" => "artifact.close_transfer",
        "request_id" => "close",
        "transfer_ref" => ref
      })

    reply(client, "close")
  end

  defp open(client, id, use_ref, start \\ "0") do
    :ok =
      send_frame(client, %{
        "method" => "artifact.open_transfer",
        "request_id" => id,
        "use_ref" => use_ref,
        "start_offset" => start
      })

    case reply(client, id) do
      %{"type" => "result", "result" => %{"transfer_ref" => ref}} ->
        {:ok, ref}

      %{"code" => "transfer_refused", "cleanup" => cleanup, "reason" => r} ->
        {:admitted_refusal, r, cleanup}

      %{"code" => "transfer_refused", "reason" => reason} ->
        {:refused, reason}

      other ->
        {:unexpected, other}
    end
  end

  defp observer(daemon, session) do
    client = initialized_client(daemon)

    :ok =
      send_frame(client, %{
        "method" => "session.attach",
        "request_id" => "attach",
        "session_id" => session
      })

    [%{"type" => "snapshot"}] = receive_records(client, 1)
    client
  end

  defp controlled(client) do
    :ok =
      send_frame(client, %{
        "method" => "session.create",
        "request_id" => "create",
        "command_id" => Wire.encode_identity("create"),
        "session_options" => %{"version" => 1}
      })

    [%{"session_id" => session}] = receive_records(client, 1)

    :ok =
      send_frame(client, %{
        "method" => "session.acquire_control",
        "request_id" => "acquire",
        "session_id" => session
      })

    [%{"result" => %{"writer_epoch" => epoch}}] = receive_records(client, 1)

    :ok =
      send_frame(client, %{
        "method" => "session.attach",
        "request_id" => "attach",
        "session_id" => session,
        "after_event_sequence" => "0"
      })

    [%{"type" => "snapshot"}] = receive_records(client, 1)
    {session, epoch}
  end

  defp event?(records, kind), do: Enum.any?(records, &(get_in(&1, ["event", "kind"]) == kind))

  defp reply(client, id) do
    client
    |> records_until(&Enum.any?(&1, fn record -> record["request_id"] == id end))
    |> Enum.find(&(&1["request_id"] == id))
  end

  defp records_until(client, complete) do
    records_until(client, complete, System.monotonic_time(:millisecond) + 10_000, [])
  end

  defp records_until(client, complete, cutoff, records) do
    remaining = cutoff - System.monotonic_time(:millisecond)
    assert remaining > 0
    [record] = receive_records(client, 1, remaining)
    records = records ++ [record]
    if complete.(records), do: records, else: records_until(client, complete, cutoff, records)
  end
end
