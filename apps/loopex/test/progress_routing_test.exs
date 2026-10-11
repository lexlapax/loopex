Code.require_file("support/progress_test_consumer.exs", __DIR__)
Code.require_file("support/m1_runtime_helper.exs", __DIR__)
Code.require_file("support/agent_loop_helper.exs", __DIR__)

defmodule Loopex.ProgressRoutingTest do
  use ExUnit.Case, async: true
  import Loopex.ProgressTestConsumer

  alias Loopex.AgentLoopFixture

  # Concept: every native lease carries the session it belongs to.
  # Technical depth: progress has one current capability route and sends no
  # bare or tagged payload to a caller mailbox.
  test "a session-routed sink receives model progress tagged with its session" do
    fixture =
      AgentLoopFixture.start(
        script: [%{text: "done", calls: [], deltas: ["hello"]}],
        progress_sink: Loopex.ProgressTestConsumer.open_sink()
      )

    {session_id, _attachment, {:accepted, "prompt-1"}} = AgentLoopFixture.run(fixture, "go")

    await_model_closure(session_id)
    assert_progress({:loopex_progress, ^session_id, %{kind: :text_delta}}, 0)
    refute_received {:loopex_progress, _item}
  end

  test "native take always retains its session and foreign owners cannot take" do
    sink = open_sink()

    fixture =
      AgentLoopFixture.start(
        script: [%{text: "done", calls: [], deltas: ["hello"]}],
        progress_sink: sink
      )

    {session_id, _attachment, {:accepted, "prompt-1"}} = AgentLoopFixture.run(fixture, "go")

    assert Task.await(Task.async(fn -> Loopex.ProgressSink.take(sink) end)) == :closed
    await_model_closure(session_id)
    assert_progress({:loopex_progress, session, %{kind: :text_delta}}, 0)
    assert session == session_id
    refute_received {:loopex_progress, _session_id, %{}}
  end

  test "superseded PID configuration and malformed capability are refused at start" do
    {store_pid, store} = Loopex.M1RuntimeTestStore.start_store(label: "progress-routing")
    on_exit(fn -> if Process.alive?(store_pid), do: GenServer.stop(store_pid) end)

    assert {:error, :invalid_runtime_options} =
             Loopex.start_link(
               runtime_id: "progress-routing-pid",
               store: store,
               context_token_budget: 8_192,
               progress_to: self()
             )

    assert {:error, :invalid_runtime_options} =
             Loopex.start_link(
               runtime_id: "progress-routing",
               store: store,
               context_token_budget: 8_192,
               progress_sink: {:session, :not_a_pid}
             )
  end

  # Concept: each wait ends on the relay's own last act, never on a test clock.
  # Technical depth: ADR 0011 makes the closure the last item of its domain.
  # The relay offers it only after draining every fenced earlier item to ready,
  # so a delta the turn emitted is already held once the closure is. A window
  # started at acceptance instead measured how soon the loaded scheduler ran the
  # model, Control, relay and sink guardian; the case's ExUnit timeout bounds a
  # closure that never comes.
  defp await_model_closure(session_id),
    do: assert_progress({:loopex_progress, ^session_id, %{kind: :model_stream_closed}}, :infinity)
end
