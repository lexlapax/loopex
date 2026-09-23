Code.require_file("support/m1_runtime_helper.exs", __DIR__)

defmodule Loopex.RuntimeStartTest do
  use ExUnit.Case, async: true

  alias Loopex.M1RuntimeTestStore
  alias Loopex.Runtime

  # Concept: `start_link/1` hands back a runtime that can already serve, so a
  # resume issued at once is not refused for a dispatcher still registering.
  #
  # Technical depth: the dispatcher registers with Control asynchronously after
  # the supervisor starts it. Before `start_link/1` waited for that, Control
  # still held the dispatcher as `:initializing` in almost every start, and an
  # ordinary succession — a resume of an active session — answered
  # `:runtime_unavailable`. Each of twenty starts here asserts the ready
  # dispatcher and then creates and resumes a session straight away.
  test "a started runtime has a ready dispatcher and resumes an active session at once" do
    for index <- 1..20 do
      {store_pid, store} = M1RuntimeTestStore.start_store()

      {:ok, runtime} =
        Loopex.start_link(
          context_token_budget: 8_192,
          runtime_id: "runtime-start-#{index}",
          store: store
        )

      {:ok, %{control: control}} = Runtime.children(runtime)
      assert %{status: :ready} = :sys.get_state(control).dispatcher

      assert {:ok, session_id} = Runtime.create_session(runtime, "start-create-#{index}", %{})

      assert {:ok, ^session_id} =
               Loopex.resume_session(runtime, session_id, command_id: "r#{index}")

      :ok = Loopex.stop(runtime)
      GenServer.stop(store_pid)
    end
  end
end
