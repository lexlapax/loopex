Code.require_file("support/daemon_socket_fixture.exs", __DIR__)

unless System.get_env("LOOPEX_HOME") do
  home = Path.join(System.tmp_dir!(), "ldca-home-#{Loopex.TestTmp.Daemon.token()}")
  File.mkdir_p!(home)
  System.put_env("LOOPEX_HOME", home)
  System.at_exit(fn _status -> File.rm_rf(home) end)
end

Code.require_file(
  "../../loopex_llm_reqllm/test/support/provider_isolation_fixture.exs",
  __DIR__
)

defmodule LoopexDaemon.CompactionActivitySocketTest do
  @moduledoc """
  ## Concept

  A real explicit compaction in the shipped daemon composition reports its
  activity to the attached controller through the daemon's own progress route.

  ## Technical depth

  Accepted ADR 0054 under served `loopex.experimental/4`. The daemon runs the
  real Service, Registry and provider path; the summary is a provider reply.
  The single closed activity item names the compact owner and the completion's
  episode, is anchored before the checkpoint, and carries no summary text.
  """

  use ExUnit.Case, async: false
  @moduletag capture_log: true

  import LoopexDaemon.Test.DaemonSocketFixture, only: [send_frame: 2, receive_records: 3]

  alias Loopex.LLM.ReqLLM.ProviderIsolationFixture, as: ProviderFixture
  alias LoopexDaemon.Sentinel
  alias LoopexProtocol.Session.{CompactionProgress, CompactResult, V2}
  alias LoopexProtocol.Wire

  @credential "compaction-activity-placeholder"
  @summary ~s({"summary":"retain this fact","carry_forward":{"files_read":[],"files_changed":[]}})

  defmodule AllowPolicy do
    @moduledoc false
    @behaviour Loopex.Policy

    @impl Loopex.Policy
    def decide(_request), do: {:allow, nil}
  end

  @tag timeout: 120_000
  test "a real explicit compaction routes its activity through the daemon socket" do
    %{socket: socket} = started = start_daemon()
    {:ok, client} = :socket.open(:local, :stream, :default)
    :ok = :socket.connect(client, %{family: :local, path: socket})
    {encoded, epoch} = controlled(client)

    :ok =
      send_frame(client, %{
        "method" => "session.prompt",
        "request_id" => "prompt",
        "command_id" => Wire.encode_identity("history"),
        "content_b64" => Wire.encode_bytes(String.duplicate("old ", 2_000)),
        "writer_epoch" => epoch
      })

    records_until(client, &event?(&1, "run.finished"))

    :ok =
      send_frame(client, %{
        "method" => "session.compact",
        "request_id" => "compact",
        "command_id" => Wire.encode_identity("compact"),
        "bounds" => %{"max_attempts" => "4", "deadline_ms" => "60000", "token_budget" => "32768"},
        "writer_epoch" => epoch
      })

    records =
      records_until(client, fn records ->
        event?(records, "context.compaction_finished") and
          Enum.any?(records, &activity?/1)
      end)

    [activity] = Enum.filter(records, &activity?/1)
    assert activity["session_id"] == encoded
    assert {:ok, item} = CompactionProgress.decode_wire(activity["progress"])
    assert item.owner == %{"kind" => "compact", "id" => "compact"}

    [%{"event" => %{"data" => finished}}] = events(records, "context.compaction_finished")
    assert finished["result"]["disposition"] == "checkpointed"
    assert {:ok, completion} = CompactResult.decode_completion(finished)
    assert completion["episode_id"] == item.episode_id

    [%{"event" => compacted}] = events(records, "context.compacted")
    assert item.base_event_sequence < String.to_integer(compacted["event_sequence"])
    refute Enum.any?(records, &(inspect(&1) =~ "retain this fact"))
    :socket.close(client)
    stop_daemon(started)
  end

  # Concept: the independent Node controller observes the same activity.
  # Technical depth: its connection validates every record independently; the
  # summary names the compact owner and the completion's own episode.
  @tag :node_client
  @tag timeout: 120_000
  test "the independent Node controller observes a real compaction's activity" do
    node = System.find_executable("node") || flunk("Node is required for the activity workflow")
    started = start_daemon()
    script = Path.expand("../../../clients/node/compaction-activity-workflow.mjs", __DIR__)

    {output, status} =
      System.cmd(node, [script, "--daemon", started.socket], stderr_to_stdout: true)

    assert status == 0, output

    assert JSON.decode!(output) == %{
             "activities" => 1,
             "owner" => %{"kind" => "compact", "id" => "node-compact"},
             "same_episode" => true,
             "disposition" => "checkpointed"
           }

    stop_daemon(started)
  end

  defp start_daemon do
    root = Path.join(System.tmp_dir!(), "ldca-#{Loopex.TestTmp.Daemon.token()}")
    workspace = Path.join(root, "w")
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf(root) end)

    provider =
      ProviderFixture.new(:reply,
        credential: @credential,
        response_bodies: [
          text_response("done", "msg_history"),
          text_response(@summary, "msg_sum")
        ]
      )

    socket = Path.join([root, "s", "daemon", "d.sock"])

    options = [
      state_root: Path.join(root, "s"),
      socket_path: socket,
      workspace: workspace,
      policy: AllowPolicy,
      provider_launch:
        Keyword.drop(provider.options, [
          :credential_token,
          :credential_registry,
          :tracing_capability
        ]),
      credential: @credential,
      maintenance_model: "anthropic:claude-haiku-4-5",
      maintenance_instructions: %{"version" => "summary.v1", "body" => "Keep facts"}
    ]

    {:ok, output} = StringIO.open("")
    test = self()

    daemon =
      Task.async(fn ->
        Sentinel.run(options, output: output, install_signals: false, notify: test)
      end)

    assert_receive {:loopex_daemon_sentinel, sentinel, owner_ref, _owner}, 5_000
    await_ready(output, 1_000)
    %{socket: socket, sentinel: sentinel, owner_ref: owner_ref, daemon: daemon}
  end

  defp stop_daemon(%{sentinel: sentinel, owner_ref: owner_ref, daemon: daemon}) do
    send(sentinel, {:daemon_signal, owner_ref, :sigterm})
    assert Task.await(daemon, 60_000) == 0
  end

  defp controlled(client) do
    :ok =
      send_frame(client, %{
        "method" => "initialize",
        "request_id" => "init",
        "generations" => [V2.generation()],
        "capabilities" => []
      })

    [%{"type" => "initialized"}] = receive_records(client, 1, 5_000)

    :ok =
      send_frame(client, %{
        "method" => "session.create",
        "request_id" => "create",
        "command_id" => Wire.encode_identity("create"),
        "session_options" => %{"version" => 1}
      })

    [%{"status" => "accepted", "session_id" => encoded}] = receive_records(client, 1, 5_000)

    :ok =
      send_frame(client, %{
        "method" => "session.acquire_control",
        "request_id" => "acquire",
        "session_id" => encoded
      })

    [%{"result" => %{"writer_epoch" => epoch}}] = receive_records(client, 1, 5_000)

    :ok =
      send_frame(client, %{
        "method" => "session.attach",
        "request_id" => "attach",
        "session_id" => encoded,
        "after_event_sequence" => "0"
      })

    [%{"type" => "snapshot"}] = receive_records(client, 1, 5_000)
    {encoded, epoch}
  end

  defp activity?(record),
    do: get_in(record, ["progress", "kind"]) == "context.compaction_progress"

  defp events(records, kind), do: Enum.filter(records, &(get_in(&1, ["event", "kind"]) == kind))
  defp event?(records, kind), do: events(records, kind) != []

  defp records_until(client, complete) do
    records_until(client, complete, System.monotonic_time(:millisecond) + 30_000, [])
  end

  defp records_until(client, complete, cutoff, records) do
    remaining = cutoff - System.monotonic_time(:millisecond)
    assert remaining > 0
    [record] = receive_records(client, 1, remaining)
    records = records ++ [record]
    if complete.(records), do: records, else: records_until(client, complete, cutoff, records)
  end

  defp await_ready(output, attempts) when attempts > 0 do
    case StringIO.contents(output) do
      {"", line} when byte_size(line) > 0 ->
        :ok

      _empty ->
        Process.sleep(10)
        await_ready(output, attempts - 1)
    end
  end

  defp await_ready(_output, 0), do: flunk("daemon never announced readiness")

  defp text_response(text, response_id) do
    [
      %{
        "type" => "message_start",
        "message" => %{
          "id" => response_id,
          "type" => "message",
          "role" => "assistant",
          "model" => "claude-haiku-4-5-20251001",
          "content" => [],
          "stop_reason" => nil,
          "stop_sequence" => nil,
          "usage" => %{"input_tokens" => 4, "output_tokens" => 0}
        }
      },
      %{
        "type" => "content_block_start",
        "index" => 0,
        "content_block" => %{"type" => "text", "text" => ""}
      },
      %{
        "type" => "content_block_delta",
        "index" => 0,
        "delta" => %{"type" => "text_delta", "text" => text}
      },
      %{"type" => "content_block_stop", "index" => 0},
      %{
        "type" => "message_delta",
        "delta" => %{"stop_reason" => "end_turn", "stop_sequence" => nil},
        "usage" => %{"output_tokens" => 2}
      },
      %{"type" => "message_stop"}
    ]
    |> Enum.map_join(fn event ->
      "event: #{event["type"]}\ndata: #{Jason.encode!(event)}\n\n"
    end)
  end
end
