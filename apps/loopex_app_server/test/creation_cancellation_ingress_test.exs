Code.require_file("../../loopex/test/support/m1_runtime_helper.exs", __DIR__)
Code.require_file("../../loopex/test/support/configured_genesis_helper.exs", __DIR__)

defmodule Loopex.AppServer.CreationCancellationIngressTest do
  @moduledoc """
  ## Concept

  A creation the runtime durably cancelled is reported over the foreground
  connection as the closed cancelled admission, with no session and an
  identical answer on every replay.

  ## Technical depth

  Accepted ADRs 0059 and 0061. A predecessor runtime's reservation is left
  uncommitted when its caller dies; the successor resolves that capture as
  cancelled. The served `loopex.experimental/3` reply equals the shared codec's
  exact six-member projection, and the Store still holds no session.
  """

  use ExUnit.Case, async: false

  alias Loopex.AppServer.Connection
  alias Loopex.M1RuntimeTestStore, as: StoreFixture
  alias Loopex.Runtime
  alias LoopexProtocol.{Session, Wire}
  alias LoopexProtocol.Session.CreationCancellation

  test "a durably cancelled creation answers the closed cancelled admission on every replay" do
    {pid, store} = StoreFixture.start_store(label: "creation-cancellation-ingress")
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

    assert {:ok, %{"selected_generation" => "loopex.experimental/3"}, connection} =
             Connection.initialize(Connection.new(runtime: successor), %{
               "method" => "initialize",
               "request_id" => "initialize",
               "generations" => [Session.generation()],
               "capabilities" => []
             })

    {:ok, expected} =
      CreationCancellation.encode_wire(%{
        type: "admission",
        request_id: "create",
        method: "session.create",
        command_id: "cancelled-create",
        status: "refused",
        reason: "creation_cancelled"
      })

    request = %{
      "method" => "session.create",
      "request_id" => "create",
      "command_id" => Wire.encode_identity("cancelled-create"),
      "session_options" => %{"version" => 1}
    }

    Enum.reduce(["create", "replay"], connection, fn request_id, connection ->
      assert {:ok, reply, connection} =
               Connection.dispatch(connection, %{request | "request_id" => request_id})

      assert reply == %{expected | "request_id" => request_id}
      assert {:ok, %{command_id: "cancelled-create"}} = CreationCancellation.decode_wire(reply)
      connection
    end)

    assert StoreFixture.inspect_state(pid).sessions == %{}
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
