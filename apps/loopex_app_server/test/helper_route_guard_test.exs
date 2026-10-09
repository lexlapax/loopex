Code.require_file(
  "../../loopex_composition/test/support/delegation_runtime_fixture.exs",
  __DIR__
)

defmodule Loopex.AppServer.HelperRouteGuardTest do
  use ExUnit.Case, async: false

  alias Loopex.AppServer.Mapping
  alias LoopexComposition.Delegation.Helper
  alias LoopexComposition.DelegationRuntimeFixture, as: Fixture
  alias LoopexProtocol.Wire

  # Concept: ADR 0069 on the foreground route: every mutating method on a helper
  # child refuses before Core admission and writes nothing.
  test "all eight mutating methods refuse a helper child and record nothing" do
    {fixture, parent, child} = helper_child()
    {:ok, attachment} = Loopex.attach(fixture.runtime, child, after_event_sequence: 0)
    context = %{runtime: fixture.runtime, attachment: attachment}
    {:ok, before} = Loopex.Store.load_records(fixture.store, child, 0, 1_000)
    content = Wire.encode_bytes("try to mutate")

    requests = [
      request("session.prompt", "p") |> Map.put("content_b64", content),
      request("session.follow_up", "f") |> Map.put("content_b64", content),
      request("session.steer", "s")
      |> Map.merge(%{"content_b64" => content, "run_id" => Wire.encode_identity("run")}),
      request("session.compact", "c")
      |> Map.put("bounds", %{
        "max_attempts" => "1",
        "deadline_ms" => "1000",
        "token_budget" => "100"
      }),
      request("session.abort", "a"),
      request("session.configure", "g") |> Map.put("changes", %{"max_tokens" => "128"}),
      request("session.respond_interaction", "i")
      |> Map.merge(%{
        "interaction_id" => Wire.encode_identity("interaction"),
        "answer" => %{"choice_id" => Wire.encode_identity("ok")}
      }),
      request("session.resume", "r") |> Map.put("session_id", Wire.encode_identity(child))
    ]

    for request <- requests do
      assert {:ok, reply} = Mapping.call(request, context), request["method"]
      assert reply["status"] == "refused", request["method"]
      assert reply["reason"] == "helper_session_owned", request["method"]
    end

    assert {:ok, ^before} = Loopex.Store.load_records(fixture.store, child, 0, 1_000)

    # Concept: the parent and ordinary inspection remain available.
    {:ok, parent_attachment} = Loopex.attach(fixture.runtime, parent, after_event_sequence: 0)

    assert {:ok, %{"status" => "accepted"}} =
             Mapping.call(
               request("session.prompt", "parent")
               |> Map.put("content_b64", Wire.encode_bytes("next")),
               %{runtime: fixture.runtime, attachment: parent_attachment}
             )

    assert {:ok, _inspected} =
             Mapping.call(
               %{
                 "method" => "session.inspect",
                 "request_id" => "inspect",
                 "session_id" => Wire.encode_identity(child)
               },
               context
             )
  end

  defp helper_child do
    fixture =
      Fixture.start([
        %{text: "go", calls: [Fixture.task_call("call-task")]},
        %{text: "Finding.", calls: []},
        %{text: "done", calls: []},
        %{text: "next", calls: []}
      ])

    parent = Fixture.parent(fixture, "parent-create")
    {_attachment, run} = Fixture.prompt(fixture, parent, "prompt", "investigate")
    assert Fixture.await_terminal(fixture, parent, run).terminal.state == "completed"
    [{child, _}] = Map.to_list(Helper.status(fixture.helper).children)
    {fixture, parent, child}
  end

  defp request(method, command),
    do: %{
      "method" => method,
      "request_id" => "request-" <> command,
      "command_id" => Wire.encode_identity(command)
    }
end
