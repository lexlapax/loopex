unless System.get_env("LOOPEX_HOME") do
  home = Path.join(System.tmp_dir!(), "ldcc-home-#{Loopex.TestTmp.Daemon.token()}")
  File.mkdir_p!(home)
  System.put_env("LOOPEX_HOME", home)
  System.at_exit(fn _status -> File.rm_rf(home) end)
end

Code.require_file("../../loopex/test/support/m1_runtime_helper.exs", __DIR__)
Code.require_file("../../loopex/test/support/configured_genesis_helper.exs", __DIR__)
Code.require_file("support/daemon_socket_fixture.exs", __DIR__)

defmodule LoopexDaemon.CreationCancellationSocketTest do
  @moduledoc """
  ## Concept

  A creation the runtime durably cancelled is reported over the daemon socket
  as the closed cancelled admission, with no session, no activation and an
  identical answer on every replay.

  ## Technical depth

  Accepted ADRs 0059 and 0061. A predecessor runtime's reservation is left
  uncommitted when its caller dies; the successor resolves that capture as
  cancelled. Over served `loopex.experimental/4` the exact six-member record
  equals the shared codec's projection, never names a session, spends no
  activation and leaves the Store without a session.
  """

  use ExUnit.Case, async: false
  @moduletag capture_log: true

  import LoopexDaemon.Test.DaemonSocketFixture

  alias Loopex.M1RuntimeTestStore, as: StoreFixture
  alias Loopex.Runtime
  alias LoopexProtocol.Session.CreationCancellation
  alias LoopexProtocol.Wire

  test "a durably cancelled creation answers the closed cancelled admission on every replay" do
    {pid, successor} = cancelled_successor()

    assert Runtime.lookup_create_result(successor, "cancelled-create", %{"version" => 1}) ==
             {:ok, :cancelled}

    daemon = start_daemon(successor)
    client = initialized_client(daemon)

    request = %{
      "method" => "session.create",
      "request_id" => "create",
      "command_id" => Wire.encode_identity("cancelled-create"),
      "session_options" => %{"version" => 1}
    }

    {:ok, expected} =
      CreationCancellation.encode_wire(%{
        type: "admission",
        request_id: "create",
        method: "session.create",
        command_id: "cancelled-create",
        status: "refused",
        reason: "creation_cancelled"
      })

    for request_id <- ["create", "replay"] do
      :ok = send_frame(client, %{request | "request_id" => request_id})
      assert [record] = receive_records(client, 1)
      assert record == %{expected | "request_id" => request_id}
      assert {:ok, decoded} = CreationCancellation.decode_wire(record)
      assert decoded.command_id == "cancelled-create"
      refute Map.has_key?(record, "session_id")
    end

    assert %{active_sessions: 0, activations_used: 0} =
             LoopexDaemon.ConnectionRegistry.status(daemon.registry)

    assert StoreFixture.inspect_state(pid).sessions == %{}
    :socket.close(client)
  end

  # Concept: the independent Node daemon client reads the same cancellation.
  # Technical depth: its own closed decoder admits the live reply and twice
  # returns the original opaque command bytes with no session member.
  @tag :node_client
  test "the independent Node client decodes the live cancelled admission" do
    {pid, successor} = cancelled_successor()
    daemon = start_daemon(successor)
    node = System.find_executable("node") || flunk("Node is required for the cancellation check")
    root = Path.expand("../../..", __DIR__)

    script = """
    import { DaemonConnection, wire } from "#{root}/clients/node/daemon-client.mjs";
    import { decodeCreationCancellation } from "#{root}/clients/node/creation-cancellation.mjs";
    const connection = await DaemonConnection.open(process.argv[1]);
    await connection.initialize();
    const decoded = [];
    for (let attempt = 0; attempt < 2; attempt++) {
      const reply = await connection.request("session.create", {
        command_id: wire.identity("cancelled-create"), session_options: { version: 1 },
      });
      const value = decodeCreationCancellation(reply);
      decoded.push(value === null ? null : value.command_id.toString("utf8"));
    }
    process.stdout.write(JSON.stringify({ decoded }) + "\\n");
    connection.close();
    """

    {output, status} =
      System.cmd(node, ["--input-type=module", "-e", script, daemon.path], stderr_to_stdout: true)

    assert status == 0, output
    assert JSON.decode!(output) == %{"decoded" => ["cancelled-create", "cancelled-create"]}

    assert %{active_sessions: 0, activations_used: 0} =
             LoopexDaemon.ConnectionRegistry.status(daemon.registry)

    assert StoreFixture.inspect_state(pid).sessions == %{}
  end

  # Concept: leave a predecessor's creation durably cancelled for a successor.
  # Technical depth: the held reservation linearizes after its caller is
  # killed; the predecessor stops and the successor resolves the capture.
  defp cancelled_successor do
    {pid, store} = StoreFixture.start_store(label: "creation-cancellation-socket")
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal, 1_000) end)
    predecessor = runtime(store)
    {:ok, %{control: control}} = Runtime.children(predecessor)
    ready(control)

    :ok =
      StoreFixture.hold_next_transition_before_linearization(
        pid,
        :runtime_control_reserve_creation,
        self()
      )

    caller =
      spawn(fn -> Runtime.create_session(predecessor, "cancelled-create", %{"version" => 1}) end)

    assert_receive {:record_held_before_linearization, waiter, ^pid,
                    :runtime_control_reserve_creation, _reserve},
                   1_000

    Process.exit(caller, :kill)
    unavailable(control)
    StoreFixture.release(waiter)

    await(fn ->
      Map.has_key?(
        StoreFixture.inspect_state(pid).creation_capsules,
        {"runtime", "cancelled-create"}
      )
    end)

    assert :ok = Runtime.stop(predecessor)
    successor = runtime(store)
    {:ok, %{control: successor_control}} = Runtime.children(successor)
    ready(successor_control)
    {pid, successor}
  end

  defp runtime(store) do
    {:ok, runtime} =
      Loopex.start_link(
        runtime_id: "runtime",
        context_token_budget: 8_192,
        store: store,
        session_creation_defaults:
          Map.drop(Loopex.ConfiguredGenesisFixture.genesis([]), [:kind, "options"]),
        cleanup_grace_ms: 5_000
      )

    on_exit(fn -> if Runtime.alive?(runtime), do: Runtime.stop(runtime) end)
    runtime
  end

  defp ready(control),
    do:
      await(fn ->
        state = :sys.get_state(control)
        state.creation_status == :ready and is_nil(state.creation)
      end)

  defp unavailable(control),
    do:
      await(fn ->
        state = :sys.get_state(control)
        state.creation_status == :unavailable and is_nil(state.creation)
      end)

  defp await(check), do: await(check, System.monotonic_time(:millisecond) + 1_000)

  defp await(check, cutoff) do
    if check.() do
      :ok
    else
      assert System.monotonic_time(:millisecond) < cutoff
      Process.sleep(1)
      await(check, cutoff)
    end
  end
end
