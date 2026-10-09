Code.require_file("../../loopex/test/support/m1_runtime_helper.exs", __DIR__)
Code.require_file("../../loopex/test/support/agent_loop_helper.exs", __DIR__)

defmodule Loopex.AppServer.InspectionIngressTest do
  @moduledoc """
  ## Concept

  Inspection through the foreground connection returns exactly the members
  the complete contract names, and an answered policy question stays visible
  as answered until policy resolves it.

  ## Technical depth

  Served `loopex.experimental/3` through the real Connection. The result
  members equal the manifest's `nested.inspection.required` inventory and
  decode through the shared codec; a host policy holding its reevaluation keeps
  the answered view, with admitted choice and command, at the answer-admission
  cursor. The policy's private decision reference is never public.
  """

  use ExUnit.Case, async: false

  alias Loopex.AgentLoopFixture, as: Fixture
  alias Loopex.AppServer.Connection
  alias LoopexProtocol.{Session, Wire}
  alias LoopexProtocol.Session.Inspection

  defmodule HeldPolicy do
    @moduledoc false
    @behaviour Loopex.Policy

    @impl Loopex.Policy
    def decide(request) do
      case Map.get(request, :interaction_response) do
        nil ->
          {:defer,
           %{
             kind: :choice,
             prompt: "Allow this write?",
             choices: [%{id: "allow", label: "Allow"}, %{id: "deny", label: "Deny"}],
             decision_ref: "PRIVATE_POLICY_REFERENCE_CANARY",
             expires_in_ms: 60_000
           }}

        %{answer: %{choice_id: choice}} ->
          send(Process.whereis(__MODULE__), {:policy_answer_callback, self(), choice})

          receive do
            :release -> {:allow, nil}
          after
            10_000 -> {:deny, :policy_unavailable}
          end
      end
    end
  end

  test "inspection members match the contract and answered policy questions stay visible" do
    Process.register(self(), HeldPolicy)

    fixture =
      Fixture.start(
        script: [
          %{text: "write", calls: [%{id: "c1", name: "write", arguments: %{"path" => "a"}}]},
          %{text: "done", calls: []}
        ],
        policy: HeldPolicy
      )

    on_exit(fn -> Fixture.stop(fixture) end)
    {:ok, session} = Loopex.create_session(fixture.runtime, %{}, command_id: "create")
    {:ok, attachment} = Loopex.attach(fixture.runtime, session, after_event_sequence: 0)

    {:ok, _reply, connection} =
      Connection.initialize(Connection.new(runtime: fixture.runtime), %{
        "method" => "initialize",
        "request_id" => "initialize",
        "generations" => [Session.generation()],
        "capabilities" => []
      })

    connection = Connection.attach(connection, attachment)

    {:ok, %{"status" => "accepted"}, connection} =
      Connection.dispatch(connection, %{
        "method" => "session.prompt",
        "request_id" => "prompt",
        "command_id" => Wire.encode_identity("prompt"),
        "content_b64" => Wire.encode_bytes("write")
      })

    requested = await_event(fixture, session, "interaction.requested")
    {pending, connection} = inspect_session(connection, session, "inspect-pending")
    members = Session.manifest()["payload_definitions"]["nested"]["inspection"]["required"]
    assert Enum.sort(Map.keys(pending)) == Enum.sort(members)
    assert length(members) == 11
    assert {:ok, _decoded} = Inspection.decode_wire(pending)
    assert pending["open_interaction"]["status"] == "pending"

    {:ok, %{"status" => "accepted"}, connection} =
      Connection.dispatch(connection, %{
        "method" => "session.respond_interaction",
        "request_id" => "answer",
        "command_id" => Wire.encode_identity("answer"),
        "interaction_id" => Wire.encode_identity(requested["interaction_id"]),
        "answer" => %{"choice_id" => Wire.encode_identity("allow")}
      })

    assert_receive {:policy_answer_callback, callback, "allow"}, 5_000
    admitted = await_event(fixture, session, "interaction.answer_admitted")
    {answered, _connection} = inspect_session(connection, session, "inspect-answered")
    assert {:ok, _decoded} = Inspection.decode_wire(answered)
    assert answered["event_sequence"] == Integer.to_string(admitted.event_sequence)
    assert answered["open_interaction"]["status"] == "answered"
    assert answered["open_interaction"]["answer_choice_id"] == Wire.encode_identity("allow")
    assert answered["open_interaction"]["answer_command_id"] == Wire.encode_identity("answer")
    refute inspect([pending, answered]) =~ "PRIVATE_POLICY_REFERENCE_CANARY"
    send(callback, :release)
    await_event(fixture, session, "run.finished")
  end

  defp inspect_session(connection, session, id) do
    {:ok, reply, connection} =
      Connection.dispatch(connection, %{
        "method" => "session.inspect",
        "request_id" => id,
        "session_id" => Wire.encode_identity(session)
      })

    assert reply["type"] == "result"
    {reply["result"], connection}
  end

  defp await_event(fixture, session, kind, attempts \\ 500) do
    case Enum.find(Fixture.events(fixture, session), &(&1.kind == kind)) do
      nil when attempts > 0 ->
        Process.sleep(10)
        await_event(fixture, session, kind, attempts - 1)

      nil ->
        flunk("no #{kind}")

      event ->
        event
    end
  end
end
