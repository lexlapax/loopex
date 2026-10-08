Code.require_file("support/configured_genesis_helper.exs", __DIR__)
Code.require_file("support/m1_runtime_helper.exs", __DIR__)

defmodule Loopex.RuntimeStartTest do
  use ExUnit.Case, async: true

  alias Loopex.M1RuntimeTestStore
  alias Loopex.Runtime

  # Concept: start_link returns a ready dispatcher, and native callers separately
  # observe the original creation startup before issuing their one create.
  # Technical depth: accepted ADR0063 distinguishes dispatcher readiness from
  # creation eligibility. Each of twenty starts preserves the dispatcher check,
  # pins the public startup identity/cutoff and spends one 1,000-ms fixture bound
  # observing it before the unchanged create/resume and owned cleanup sequence.
  test "a started runtime has a ready dispatcher and creates after original startup proof" do
    for index <- 1..20 do
      {store_pid, store} = M1RuntimeTestStore.start_store()

      {:ok, runtime} =
        Loopex.start_link(
          context_token_budget: 8_192,
          session_creation_defaults:
            Loopex.ConfiguredGenesisFixture.genesis([]) |> Map.drop([:kind, "options"]),
          runtime_id: "runtime-start-#{index}",
          store: store
        )

      {:ok, %{control: control}} = Runtime.children(runtime)
      assert %{status: :ready} = :sys.get_state(control).dispatcher

      assert :ok = await_startup(runtime)

      assert {:ok, session_id} = Runtime.create_session(runtime, "start-create-#{index}", %{})

      assert {:ok, ^session_id} =
               Loopex.resume_session(runtime, session_id, command_id: "r#{index}")

      :ok = Loopex.stop(runtime)
      GenServer.stop(store_pid)
    end
  end

  defp await_startup(runtime) do
    cutoff = System.monotonic_time(:millisecond) + 1_000
    assert {:ok, snapshot} = Runtime.creation_startup_status(runtime, 1_000)
    await_startup(runtime, snapshot, min(cutoff, snapshot.startup_deadline_ms))
  end

  defp await_startup(runtime, snapshot, cutoff) do
    remaining = cutoff - System.monotonic_time(:millisecond)
    assert remaining > 0

    case snapshot.state do
      :ready ->
        :ok

      :starting ->
        receive do
        after
          min(10, remaining) -> :ok
        end

        remaining = cutoff - System.monotonic_time(:millisecond)
        assert remaining > 0
        assert {:ok, next} = Runtime.creation_startup_status(runtime, min(1_000, remaining))
        assert next.startup_id == snapshot.startup_id
        assert next.startup_deadline_ms == snapshot.startup_deadline_ms
        await_startup(runtime, next, cutoff)

      unavailable ->
        flunk("original creation startup unavailable: #{inspect(unavailable)}")
    end
  end
end
