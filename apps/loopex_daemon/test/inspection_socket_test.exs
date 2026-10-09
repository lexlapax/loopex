unless System.get_env("LOOPEX_HOME") do
  home = Path.join(System.tmp_dir!(), "ldis-home-#{Loopex.TestTmp.Daemon.token()}")
  File.mkdir_p!(home)
  System.put_env("LOOPEX_HOME", home)
  System.at_exit(fn _status -> File.rm_rf(home) end)
end

Code.require_file("../../loopex/test/support/m1_runtime_helper.exs", __DIR__)
Code.require_file("../../loopex/test/support/agent_loop_helper.exs", __DIR__)
Code.require_file("support/daemon_socket_fixture.exs", __DIR__)

defmodule LoopexDaemon.InspectionSocketTest do
  @moduledoc """
  ## Concept

  Inspection over the daemon socket returns exactly the members the complete
  contract names, and an answered policy question is visible as answered,
  with its admitted choice and command, until policy resolves it.

  ## Technical depth

  Served `loopex.experimental/4`. The result members equal the manifest's
  `nested.inspection.required` inventory and decode through the shared
  Inspection codec. A host policy that holds its reevaluation keeps the
  question answered: inspection and a fresh snapshot both show the answered
  view at the answer-admission cursor, and the policy's private decision
  reference never appears publicly.
  """

  use ExUnit.Case, async: false
  @moduletag capture_log: true

  import LoopexDaemon.Test.DaemonSocketFixture

  alias Loopex.AgentLoopFixture, as: Fixture
  alias LoopexProtocol.Session.{Inspection, V2}
  alias LoopexProtocol.Wire

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
    daemon = start_daemon(fixture.runtime)
    client = initialized_client(daemon)
    {session, epoch} = controlled(client)

    :ok =
      send_frame(client, %{
        "method" => "session.prompt",
        "request_id" => "prompt",
        "command_id" => Wire.encode_identity("prompt"),
        "content_b64" => Wire.encode_bytes("write"),
        "writer_epoch" => epoch
      })

    requested = records_until(client, &event?(&1, "interaction.requested"))
    [%{"event" => %{"data" => question}}] = events(requested, "interaction.requested")
    pending = inspect_session(client, session, "inspect-pending")
    members = V2.manifest()["payload_definitions"]["nested"]["inspection"]["required"]
    assert Enum.sort(Map.keys(pending)) == Enum.sort(members)
    assert length(members) == 11
    assert {:ok, _decoded} = Inspection.decode_wire(pending)
    assert pending["open_interaction"]["status"] == "pending"

    :ok =
      send_frame(client, %{
        "method" => "session.respond_interaction",
        "request_id" => "answer",
        "command_id" => Wire.encode_identity("answer"),
        "interaction_id" => question["interaction_id"],
        "answer" => %{"choice_id" => Wire.encode_identity("allow")},
        "writer_epoch" => epoch
      })

    assert_receive {:policy_answer_callback, callback, "allow"}, 5_000
    admitted = records_until(client, &event?(&1, "interaction.answer_admitted"))
    [%{"event" => admission}] = events(admitted, "interaction.answer_admitted")
    answered = inspect_session(client, session, "inspect-answered")
    assert {:ok, _decoded} = Inspection.decode_wire(answered)
    assert answered["event_sequence"] == admission["event_sequence"]
    assert answered["open_interaction"]["status"] == "answered"

    assert answered["open_interaction"]["answer_choice_id"] ==
             Wire.encode_identity("allow")

    assert answered["open_interaction"]["answer_command_id"] == Wire.encode_identity("answer")

    for key <- ~w(interaction_id run_id turn tool_call_id answer_choice_id answer_command_id) do
      assert answered["open_interaction"][key] == admission["data"][key], key
    end

    observer = initialized_client(daemon)

    :ok =
      send_frame(observer, %{
        "method" => "session.attach",
        "request_id" => "observe",
        "session_id" => session
      })

    [snapshot] = receive_records(observer, 1)
    assert snapshot["event_cursor"] == admission["event_sequence"]
    assert snapshot["open_interaction"] == answered["open_interaction"]
    assert snapshot["snapshot"]["open_interaction"] == answered["open_interaction"]

    send(callback, :release)
    resolved = records_until(client, &event?(&1, "run.finished"))
    [%{"event" => %{"data" => terminal}}] = events(resolved, "interaction.resolved")
    assert terminal["interaction_id"] == question["interaction_id"]
    assert terminal["answer_command_id"] == Wire.encode_identity("answer")

    refute inspect([requested, pending, admitted, answered, snapshot, resolved], limit: :infinity) =~
             "PRIVATE_POLICY_REFERENCE_CANARY"

    :socket.close(observer)
    :socket.close(client)
  end

  defp inspect_session(client, session, id) do
    :ok =
      send_frame(client, %{
        "method" => "session.inspect",
        "request_id" => id,
        "session_id" => session
      })

    [reply] =
      client
      |> records_until(&Enum.any?(&1, fn record -> record["request_id"] == id end))
      |> Enum.filter(&(&1["request_id"] == id))

    assert reply["type"] == "result"
    reply["result"]
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

  defp events(records, kind), do: Enum.filter(records, &(get_in(&1, ["event", "kind"]) == kind))
  defp event?(records, kind), do: events(records, kind) != []

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
