Code.require_file(
  "../../loopex_composition/test/support/delegation_runtime_fixture.exs",
  __DIR__
)

defmodule LoopexDaemon.HelperRouteGuardTest do
  use ExUnit.Case, async: false

  alias LoopexComposition.Delegation.Helper
  alias LoopexComposition.DelegationRuntimeFixture, as: Fixture
  alias LoopexDaemon.SocketConnection

  # Concept: ADR 0069 on the daemon route: the relay's Core mutation and resume
  # calls refuse a helper child before admission and record nothing.
  test "all eight mutating commands refuse a helper child and record nothing" do
    fixture =
      Fixture.start([
        %{text: "go", calls: [Fixture.task_call("call-task")]},
        %{text: "Finding.", calls: []},
        %{text: "done", calls: []}
      ])

    parent = Fixture.parent(fixture, "parent-create")
    {_attachment, run} = Fixture.prompt(fixture, parent, "prompt", "investigate")
    assert Fixture.await_terminal(fixture, parent, run).terminal.state == "completed"
    [{child, _}] = Map.to_list(Helper.status(fixture.helper).children)
    {:ok, attachment} = Loopex.attach(fixture.runtime, child, after_event_sequence: 0)
    {:ok, before} = Loopex.Store.load_records(fixture.store, child, 0, 1_000)

    commands = [
      {"session.prompt", %{type: :prompt, command_id: "p", content: "x"}},
      {"session.follow_up", %{type: :follow_up, command_id: "f", content: "x"}},
      {"session.steer", %{type: :steer, command_id: "s", content: "x", run_id: "run"}},
      {"session.compact", %{type: :compact, command_id: "c"}},
      {"session.abort", %{type: :abort, command_id: "a"}},
      {"session.configure", %{type: :configure, command_id: "g", changes: %{}}},
      {"session.respond_interaction",
       %{type: :interaction_answer, command_id: "i", interaction_id: "x", answer: %{}}}
    ]

    for {method, command} <- commands do
      assert {:refused, record} =
               SocketConnection.run_mutation(attachment, command, "request", method, nil)

      assert inspect(record) =~ "helper_session_owned", method
    end

    resume = SocketConnection.resume_task(%{runtime: fixture.runtime}, "request", child, "r")
    assert {:refused, :no_activation, record} = resume.()
    assert inspect(record) =~ "helper_session_owned"
    assert {:ok, ^before} = Loopex.Store.load_records(fixture.store, child, 0, 1_000)
    assert SocketConnection.route_guard(fixture.runtime, parent, :prompt) == :ok
  end
end
