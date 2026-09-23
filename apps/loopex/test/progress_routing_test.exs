Code.require_file("support/m1_runtime_helper.exs", __DIR__)
Code.require_file("support/agent_loop_helper.exs", __DIR__)

defmodule Loopex.ProgressRoutingTest do
  use ExUnit.Case, async: true

  alias Loopex.AgentLoopFixture

  # Concept: a host serving many sessions receives each transient progress
  # item with the session it belongs to; an embedded caller keeps the untagged
  # shape it has always received.
  test "a session-routed sink receives model progress tagged with its session" do
    fixture =
      AgentLoopFixture.start(
        script: [%{text: "done", calls: [], deltas: ["hello"]}],
        progress_to: {:session, self()}
      )

    {session_id, _attachment, {:accepted, "prompt-1"}} = AgentLoopFixture.run(fixture, "go")

    assert_receive {:loopex_progress, ^session_id, %{kind: :text_delta}}, 5_000
    assert_receive {:loopex_progress, ^session_id, %{kind: :model_stream_closed}}, 5_000
    refute_received {:loopex_progress, %{}}
  end

  test "a plain sink keeps untagged progress" do
    fixture =
      AgentLoopFixture.start(
        script: [%{text: "done", calls: [], deltas: ["hello"]}],
        progress_to: self()
      )

    {_session_id, _attachment, {:accepted, "prompt-1"}} = AgentLoopFixture.run(fixture, "go")

    assert_receive {:loopex_progress, %{kind: :text_delta}}, 5_000
    refute_received {:loopex_progress, _session_id, %{}}
  end

  test "a malformed session sink is refused at start" do
    {store_pid, store} = Loopex.M1RuntimeTestStore.start_store(label: "progress-routing")
    on_exit(fn -> if Process.alive?(store_pid), do: GenServer.stop(store_pid) end)

    assert {:error, :invalid_runtime_options} =
             Loopex.start_link(
               runtime_id: "progress-routing",
               store: store,
               context_token_budget: 8_192,
               progress_to: {:session, :not_a_pid}
             )
  end
end
