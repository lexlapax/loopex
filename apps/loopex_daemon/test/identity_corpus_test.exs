# The core runtime helper refuses to load without an isolated home; this suite
# supplies a temporary one rather than a real one.
unless System.get_env("LOOPEX_HOME") do
  home =
    Path.join(
      System.tmp_dir!(),
      "ldi-home-#{Loopex.TestTmp.Daemon.token()}"
    )

  File.mkdir_p!(home)
  System.put_env("LOOPEX_HOME", home)
  System.at_exit(fn _status -> File.rm_rf(home) end)
end

Code.require_file("../../loopex/test/support/m1_runtime_helper.exs", __DIR__)
Code.require_file("../../loopex/test/support/agent_loop_helper.exs", __DIR__)
Code.require_file("support/daemon_socket_fixture.exs", __DIR__)

defmodule LoopexDaemon.IdentityCorpusTest do
  use ExUnit.Case, async: false
  @moduletag capture_log: true

  import LoopexDaemon.Test.DaemonSocketFixture

  alias Loopex.AgentLoopFixture, as: Fixture
  alias LoopexProtocol.Wire

  # Concept: the daemon is a surface over the same session contract, so the
  # same commands sent through its socket commit exactly what an embedded
  # caller's commands commit: the same session, the same records, the same
  # events with the same identities.
  #
  # Technical depth: two runtimes with the same runtime identity and the same
  # scripted model each receive one corpus — create `cs`, then prompt `p1` —
  # once through the facade and once through a daemon socket (with the lease
  # and attachment the socket requires). The session identity, every committed
  # record kind and every durable event, including its event and run
  # identities, are compared whole. The lease's writer epoch never reaches core,
  # so nothing in the durable history differs.
  test "the same corpus through the socket and the facade commits identical identities" do
    facade = fixture()
    {:ok, facade_session} = Loopex.create_session(facade.runtime, %{}, command_id: "cs")
    {:ok, attachment} = Loopex.attach(facade.runtime, facade_session)

    {:accepted, "p1"} =
      Loopex.command(attachment, %{type: :prompt, command_id: "p1", content: "hello"})

    settle(facade, facade_session)

    socket = fixture()
    daemon = start_daemon(socket.runtime)
    client = initialized_client(daemon)

    :ok =
      send_frame(client, %{
        "method" => "session.create",
        "request_id" => "create",
        "command_id" => Wire.encode_identity("cs"),
        "session_options" => %{}
      })

    assert [%{"status" => "accepted", "session_id" => encoded}] = receive_records(client, 1)
    {:ok, socket_session} = Wire.identity(encoded)
    assert socket_session == facade_session

    :ok =
      send_frame(client, %{
        "method" => "session.acquire_control",
        "request_id" => "acquire",
        "session_id" => encoded
      })

    assert [%{"result" => %{"writer_epoch" => epoch}}] = receive_records(client, 1)

    :ok =
      send_frame(client, %{
        "method" => "session.attach",
        "request_id" => "attach",
        "session_id" => encoded,
        "after_event_sequence" => "0"
      })

    assert [%{"type" => "snapshot"}] = receive_records(client, 1)

    :ok =
      send_frame(client, %{
        "method" => "session.prompt",
        "request_id" => "prompt",
        "command_id" => Wire.encode_identity("p1"),
        "content_b64" => Wire.encode_bytes("hello"),
        "writer_epoch" => epoch
      })

    settle(socket, socket_session)

    assert kinds(socket, socket_session) == kinds(facade, facade_session)
    assert Fixture.events(socket, socket_session) == Fixture.events(facade, facade_session)
    assert length(Fixture.events(socket, socket_session)) > 2
  end

  # Concept: a client that disconnects is lost transport, nothing more: the
  # run it started is not cancelled, answers no interaction, and finishes on
  # its own.
  #
  # Technical depth: over a daemon socket a controller prompts a run whose tool
  # takes half a second, then closes its socket abruptly while the tool runs.
  # The run still commits its tool result and `run.finished` with outcome
  # `completed`, and no cancellation is recorded.
  test "a client disconnect mid-run is transport loss, not cancellation" do
    socket_fixture =
      Fixture.start(
        script: [
          %{text: "one call", calls: [%{id: "c1", name: "write", arguments: %{"path" => "c1"}}]},
          %{text: "done", calls: []}
        ],
        tool_delay_ms: 500
      )

    on_exit(fn -> Fixture.stop(socket_fixture) end)
    daemon = start_daemon(socket_fixture.runtime)
    client = initialized_client(daemon)

    :ok =
      send_frame(client, %{
        "method" => "session.create",
        "request_id" => "create",
        "command_id" => Wire.encode_identity("disconnect-create"),
        "session_options" => %{}
      })

    assert [%{"status" => "accepted", "session_id" => encoded}] = receive_records(client, 1)
    {:ok, session_id} = Wire.identity(encoded)

    :ok =
      send_frame(client, %{
        "method" => "session.acquire_control",
        "request_id" => "acquire",
        "session_id" => encoded
      })

    assert [%{"result" => %{"writer_epoch" => epoch}}] = receive_records(client, 1)

    :ok =
      send_frame(client, %{
        "method" => "session.attach",
        "request_id" => "attach",
        "session_id" => encoded,
        "after_event_sequence" => "0"
      })

    assert [%{"type" => "snapshot"}] = receive_records(client, 1)

    :ok =
      send_frame(client, %{
        "method" => "session.prompt",
        "request_id" => "prompt",
        "command_id" => Wire.encode_identity("disconnect-prompt"),
        "content_b64" => Wire.encode_bytes("go"),
        "writer_epoch" => epoch
      })

    assert eventually_event(socket_fixture, session_id, "tool.started")
    :ok = :socket.close(client)

    settle(socket_fixture, session_id)
    events = Fixture.events(socket_fixture, session_id)
    finished = Enum.find(events, &(&1.kind == "run.finished"))
    assert finished["outcome"] == "completed"
    assert Enum.find(events, &(&1.kind == "tool.finished"))["outcome"] == "completed"

    refute Enum.any?(
             Fixture.records(socket_fixture, session_id),
             &(Map.get(&1.payload, "command_type") == "abort")
           )
  end

  defp eventually_event(fixture, session_id, kind, attempts \\ 500) do
    cond do
      Enum.any?(Fixture.events(fixture, session_id), &(&1.kind == kind)) -> true
      attempts == 0 -> false
      true -> Process.sleep(10) && eventually_event(fixture, session_id, kind, attempts - 1)
    end
  end

  defp fixture do
    fixture = Fixture.start(script: [%{text: "done", calls: []}])
    on_exit(fn -> Fixture.stop(fixture) end)
    fixture
  end

  defp kinds(fixture, session_id),
    do: fixture |> Fixture.records(session_id) |> Enum.map(& &1.payload.kind)

  defp settle(fixture, session_id, attempts \\ 500) do
    finished? = Enum.any?(Fixture.events(fixture, session_id), &(&1.kind == "run.finished"))

    cond do
      finished? -> :ok
      attempts == 0 -> flunk("the run did not finish")
      true -> Process.sleep(10) && settle(fixture, session_id, attempts - 1)
    end
  end
end
