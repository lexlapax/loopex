unless System.get_env("LOOPEX_HOME") do
  home = Path.join(System.tmp_dir!(), "ldms-home-#{Loopex.TestTmp.Daemon.token()}")
  File.mkdir_p!(home)
  System.put_env("LOOPEX_HOME", home)
  System.at_exit(fn _status -> File.rm_rf(home) end)
end

Code.require_file("../../loopex/test/support/m1_runtime_helper.exs", __DIR__)
Code.require_file("../../loopex/test/support/agent_loop_helper.exs", __DIR__)
Code.require_file("support/daemon_socket_fixture.exs", __DIR__)

defmodule LoopexDaemon.MaintenanceSocketTest do
  @moduledoc """
  ## Concept

  Active maintenance is visible over the daemon socket exactly as committed:
  each change is one `context.maintenance_changed` event, and a snapshot taken
  while maintenance is in flight shows that same view at the same public
  cursor. Store uncertainty never duplicates or loses a change, and no summary
  or private capture is ever public.

  ## Technical depth

  Served `loopex.experimental/4`. A real explicit compaction runs a scripted
  summary held in flight while an observer attaches; the observer's snapshot
  cursor equals the last maintenance event the controller saw, and its active
  view equals that event's view. For each of the three Store fault phases on
  the compact admission commit, the controller sees no admission on the
  uncertain attempt, its exact retry settles once, every maintenance event is
  unique in identity and sequence, and the final snapshot is inactive at the
  last public cursor.
  """

  use ExUnit.Case, async: false
  @moduletag capture_log: true

  import LoopexDaemon.Test.DaemonSocketFixture

  alias Loopex.AgentLoopFixture, as: Fixture
  alias LoopexProtocol.Session.MaintenanceView
  alias LoopexProtocol.Wire

  @canary "retain this fact"

  test "a snapshot during maintenance shows the last maintenance view at its own cursor" do
    held = Map.merge(Fixture.summary_reply(), %{hold: self(), deltas: ["PRIVATE summary delta"]})
    fixture = fixture([%{text: "done", calls: []}, held])
    daemon = start_daemon(fixture.runtime)
    client = initialized_client(daemon)
    {session, epoch} = controlled(client)
    history(client, epoch)
    :ok = send_frame(client, compact("compact", epoch))
    assert_receive {:holding, worker}, 5_000

    records =
      records_until(client, fn records ->
        Enum.any?(records, &(get_in(&1, ["event", "kind"]) == "context.maintenance_changed"))
      end)

    [last | _] =
      records
      |> Enum.filter(&(get_in(&1, ["event", "kind"]) == "context.maintenance_changed"))
      |> Enum.reverse()

    assert {:ok, %{"active_maintenance" => active}} =
             MaintenanceView.decode_wire(last["event"]["data"])

    refute is_nil(active)

    observer = initialized_client(daemon)

    :ok =
      send_frame(observer, %{
        "method" => "session.attach",
        "request_id" => "observe",
        "session_id" => session
      })

    [snapshot] = receive_records(observer, 1)
    assert snapshot["type"] == "snapshot"
    assert snapshot["event_cursor"] == last["event"]["event_sequence"]
    assert snapshot["snapshot"]["event_sequence"] == last["event"]["event_sequence"]

    assert %{"active_maintenance" => snapshot["snapshot"]["active_maintenance"]} ==
             last["event"]["data"]

    send(worker, :release)
    finished = records_until(client, &event?(&1, "context.compaction_finished"))
    refute inspect([records, snapshot, finished], limit: :infinity) =~ @canary
    refute inspect([records, snapshot, finished], limit: :infinity) =~ "PRIVATE"
    :socket.close(observer)
    :socket.close(client)
  end

  for phase <- [
        :before_linearization,
        :after_linearization_before_result,
        :recovery_representation
      ] do
    @phase phase
    test "#{phase} on the compact admission never duplicates or loses a maintenance change" do
      fixture = fixture([%{text: "done", calls: []}, Fixture.summary_reply()])
      daemon = start_daemon(fixture.runtime)
      client = initialized_client(daemon)
      {session, epoch} = controlled(client)
      before = history(client, epoch)

      assert :ok =
               Loopex.M1RuntimeTestStore.inject(fixture.store, {:session_journal_commit, @phase})

      request = compact("uncertain", epoch)
      :ok = send_frame(client, request)
      first = reply(client, "uncertain")
      refute first["status"] == "refused"
      settled = settle(client, request, first, 100)
      assert settled["status"] == "accepted"

      assert {:session_journal_commit, @phase} in Loopex.M1RuntimeTestStore.observed(
               fixture.store
             )

      records = before ++ records_until(client, &event?(&1, "context.compaction_finished"))

      events = for %{"type" => "event", "event" => event} <- records, do: event
      ids = Enum.map(events, & &1["event_id"])
      sequences = Enum.map(events, &String.to_integer(&1["event_sequence"]))
      assert ids == Enum.uniq(ids)
      assert sequences == Enum.sort(Enum.uniq(sequences))

      changes = Enum.filter(events, &(&1["kind"] == "context.maintenance_changed"))
      assert changes != []

      assert {:ok, %{"active_maintenance" => nil}} =
               MaintenanceView.decode_wire(List.last(changes)["data"])

      assert [_one] = Enum.filter(events, &(&1["kind"] == "context.compaction_finished"))

      observer = initialized_client(daemon)

      :ok =
        send_frame(observer, %{
          "method" => "session.attach",
          "request_id" => "observe",
          "session_id" => session
        })

      [snapshot] = receive_records(observer, 1)
      assert snapshot["snapshot"]["active_maintenance"] == nil
      assert String.to_integer(snapshot["event_cursor"]) >= List.last(sequences)
      refute inspect([records, snapshot], limit: :infinity) =~ @canary
      :socket.close(observer)
      :socket.close(client)
    end
  end

  # An uncertain admission is retried with the same command until the original
  # outcome is known; only an admission may end the loop.
  defp settle(_client, _request, %{"type" => "admission"} = reply, _attempts), do: reply

  defp settle(client, request, _unknown, attempts) when attempts > 0 do
    Process.sleep(20)
    id = "retry-#{attempts}"
    :ok = send_frame(client, %{request | "request_id" => id})
    settle(client, request, reply(client, id), attempts - 1)
  end

  defp settle(_client, _request, reply, 0), do: flunk("never settled: #{inspect(reply)}")

  defp compact(id, epoch),
    do: %{
      "method" => "session.compact",
      "request_id" => id,
      "command_id" => Wire.encode_identity("compact"),
      "bounds" => %{"max_attempts" => "4", "deadline_ms" => "60000", "token_budget" => "32768"},
      "writer_epoch" => epoch
    }

  defp history(client, epoch) do
    :ok =
      send_frame(client, %{
        "method" => "session.prompt",
        "request_id" => "history",
        "command_id" => Wire.encode_identity("history"),
        "content_b64" => Wire.encode_bytes(String.duplicate("old ", 2_000)),
        "writer_epoch" => epoch
      })

    records_until(client, &event?(&1, "session.settled"))
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

  defp event?(records, kind), do: Enum.any?(records, &(get_in(&1, ["event", "kind"]) == kind))

  defp reply(client, id) do
    client
    |> records_until(&Enum.any?(&1, fn record -> record["request_id"] == id end))
    |> Enum.find(&(&1["request_id"] == id))
  end

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

  defp fixture(script) do
    fixture = Fixture.start([script: script, tools: []] ++ Fixture.maintenance_options())
    on_exit(fn -> Fixture.stop(fixture) end)
    fixture
  end
end
