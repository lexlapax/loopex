unless System.get_env("LOOPEX_HOME") do
  home = Path.join(System.tmp_dir!(), "ldcc-home-#{Loopex.TestTmp.Daemon.token()}")
  File.mkdir_p!(home)
  System.put_env("LOOPEX_HOME", home)
  System.at_exit(fn _status -> File.rm_rf(home) end)
end

Code.require_file("../../loopex/test/support/m1_runtime_helper.exs", __DIR__)
Code.require_file("../../loopex/test/support/agent_loop_helper.exs", __DIR__)
Code.require_file("../../loopex/test/support/model_preparation_conformance.exs", __DIR__)
Code.require_file("support/daemon_socket_fixture.exs", __DIR__)

defmodule LoopexDaemon.ConfigureCompactSocketTest do
  @moduledoc """
  ## Concept

  A daemon controller configures and compacts its session through the actual
  `loopex.experimental/4` socket, under the same native admission, central
  preparation and duplicate identity as an embedded caller.

  ## Technical depth

  Accepted ADRs 0050 and 0053: a stale writer epoch refuses before native
  preparation or Store mutation; the authored alias resolves once through the
  runtime's Model preparation; the public `session.configured` projection is
  the closed configuration DTO; an exact retry replays the historical admission
  without preparing again. Standalone compaction completes through the same
  socket with its closed completion event and replays once.
  """

  use ExUnit.Case, async: false
  @moduletag capture_log: true

  import LoopexDaemon.Test.DaemonSocketFixture

  alias Loopex.AgentLoopFixture, as: Fixture
  alias LoopexProtocol.Session.{CompactResult, Configuration, V2}
  alias LoopexProtocol.Wire

  defmodule Preparing do
    @moduledoc false
    @behaviour Loopex.Model

    @impl true
    def complete(request, options, progress) do
      Loopex.AgentLoopTestModel.complete(
        request,
        Keyword.take(options, [:script, :max_tokens]),
        progress
      )
    end

    @impl true
    def prepare_configuration(current, authored, definitions, _context, options) do
      Agent.update(Keyword.fetch!(options, :controller), &(&1 + 1))
      Loopex.ModelPreparationConformance.candidate(current, authored, definitions, "scripted:v1")
    end
  end

  test "configure and compact settle once through the controller socket" do
    fixture = fixture()
    daemon = start_daemon(fixture.runtime)
    client = initialized_client(daemon)
    {encoded, session, epoch} = controlled(client)

    configure = %{
      "method" => "session.configure",
      "request_id" => "configure",
      "command_id" => Wire.encode_identity(<<0, 255, 128>>),
      "changes" => %{"model" => "fast-alias", "max_tokens" => "512"},
      "writer_epoch" => epoch
    }

    before = Fixture.records(fixture, session)
    :ok = send_frame(client, %{configure | "request_id" => "stale", "writer_epoch" => "c3RhbGU"})

    assert [%{"type" => "error", "request_id" => "stale", "code" => "control_not_held"}] =
             receive_records(client, 1)

    assert Fixture.records(fixture, session) == before
    assert Agent.get(fixture.controller, & &1) == 0

    :ok = send_frame(client, configure)
    records = records_until(client, &event?(&1, "session.configured"))
    [admission] = Enum.filter(records, &(&1["request_id"] == "configure"))

    assert admission == %{
             "type" => "admission",
             "request_id" => "configure",
             "method" => "session.configure",
             "command_id" => configure["command_id"],
             "status" => "accepted",
             "reason" => nil
           }

    assert Agent.get(fixture.controller, & &1) == 1
    [%{"event" => %{"data" => configured}}] = events(records, "session.configured")
    assert {:ok, change} = Configuration.decode_change(configured)
    assert change["command_id"] == <<0, 255, 128>>
    assert change["configuration"]["model"] == "scripted:v1"
    assert change["configuration"]["max_tokens"] == 512
    assert configured["configuration"]["max_tokens"] == "512"
    refute inspect(records) =~ "provider_mapping"

    assert {:ok, %{configuration: configuration}} =
             Loopex.session_status(fixture.runtime, session)

    assert configuration["max_tokens"] == 512
    settled = Fixture.records(fixture, session)
    :ok = send_frame(client, %{configure | "request_id" => "retry"})
    assert [retry] = receive_records(client, 1)
    assert retry == %{admission | "request_id" => "retry"}
    assert Fixture.records(fixture, session) == settled
    assert Agent.get(fixture.controller, & &1) == 1

    compact = %{
      "method" => "session.compact",
      "request_id" => "compact",
      "command_id" => Wire.encode_identity("compact"),
      "bounds" => %{"max_attempts" => "4", "deadline_ms" => "60000", "token_budget" => "32768"},
      "writer_epoch" => epoch
    }

    :ok = send_frame(client, compact)
    records = records_until(client, &event?(&1, "context.compaction_finished"))
    [compacted] = Enum.filter(records, &(&1["request_id"] == "compact"))
    assert compacted["status"] == "accepted"
    [%{"event" => %{"data" => finished}}] = events(records, "context.compaction_finished")
    assert {:ok, completion} = CompactResult.decode_completion(finished)
    assert completion["command_id"] == "compact"
    assert finished["result"]["disposition"] == "unchanged"
    settled = Fixture.records(fixture, session)
    :ok = send_frame(client, %{compact | "request_id" => "compact-retry"})
    assert [compact_retry] = receive_records(client, 1)
    assert compact_retry == %{compacted | "request_id" => "compact-retry"}
    assert Fixture.records(fixture, session) == settled
    assert Loopex.AgentLoopTestModel.dispatched(fixture.model) == []
    assert Loopex.AgentLoopTestExecutor.jobs(fixture.executor) == []
    assert encoded == Wire.encode_identity(session)
    :socket.close(client)
  end

  # Concept: the independent daemon client performs the same workflow.
  # Technical depth: Node decodes every record through its own validators; the
  # native records it caused are checked here against one central preparation.
  @tag :node_client
  test "the independent Node controller configures and compacts through the socket" do
    fixture = fixture()
    daemon = start_daemon(fixture.runtime)
    node = System.find_executable("node") || flunk("Node is required for the daemon workflow")
    script = Path.expand("../../../clients/node/maintenance-workflow.mjs", __DIR__)

    {output, status} =
      System.cmd(node, [script, "fast-alias", "--daemon", daemon.path], stderr_to_stdout: true)

    assert status == 0, output

    assert JSON.decode!(output) == %{
             "stale" => "control_not_held",
             "model" => "scripted:v1",
             "max_tokens" => "512",
             "configure_retry_matches" => true,
             "disposition" => "unchanged",
             "compact_retry_matches" => true,
             "configured_events" => 1
           }

    assert Agent.get(fixture.controller, & &1) == 1
    assert Loopex.AgentLoopTestModel.dispatched(fixture.model) == []
  end

  # Concept: an uncertain configure commit is reported unknown, never refused,
  # and its exact retry settles the original command once.
  # Technical depth: accepted ADR 0050 over /4. The Store commits after
  # linearization but loses the result; the controller is told
  # `admission_unknown`. The retry returns the accepted admission, preparation
  # ran once, and one configuration record and one public change exist.
  test "an uncertain configure commit answers admission_unknown and its retry settles once" do
    fixture = fixture()
    daemon = start_daemon(fixture.runtime)
    client = initialized_client(daemon)
    {_encoded, session, epoch} = controlled(client)

    configure = %{
      "method" => "session.configure",
      "request_id" => "configure",
      "command_id" => Wire.encode_identity("uncertain-configure"),
      "changes" => %{"model" => "fast-alias", "max_tokens" => "512"},
      "writer_epoch" => epoch
    }

    assert :ok =
             Loopex.M1RuntimeTestStore.inject(
               fixture.store,
               {:session_journal_commit, :after_linearization_before_result}
             )

    :ok = send_frame(client, configure)

    records =
      records_until(client, &Enum.any?(&1, fn record -> record["request_id"] == "configure" end))

    [unknown] = Enum.filter(records, &(&1["request_id"] == "configure"))
    assert %{"type" => "error", "code" => "admission_unknown"} = unknown
    refute Map.has_key?(unknown, "status")

    retry =
      eventually_admitted(client, %{configure | "request_id" => "retry"}, "retry", 50)

    assert retry["status"] == "accepted"
    assert retry["command_id"] == configure["command_id"]
    assert Agent.get(fixture.controller, & &1) == 1

    assert [_one] =
             fixture
             |> Fixture.records(session)
             |> Enum.filter(&(&1.payload.kind == "session_configuration_admitted_v2"))

    assert [_change] =
             Enum.filter(Fixture.events(fixture, session), &(&1.kind == "session.configured"))

    :socket.close(client)
  end

  # Concept: one command identity names one command over the controller socket.
  # Technical depth: exact prompt retries replay their admission without new
  # records; a changed prompt, configure or compact under a used identity is
  # refused without mutation; a stale epoch cannot compact.
  test "duplicate and changed commands under one identity replay or refuse without mutation" do
    fixture = fixture()
    daemon = start_daemon(fixture.runtime)
    client = initialized_client(daemon)
    {_encoded, session, epoch} = controlled(client)

    prompt = %{
      "method" => "session.prompt",
      "request_id" => "prompt",
      "command_id" => Wire.encode_identity("prompt-once"),
      "content_b64" => Wire.encode_bytes("go"),
      "writer_epoch" => epoch
    }

    :ok = send_frame(client, prompt)
    records = records_until(client, &event?(&1, "session.settled"))
    [admitted] = Enum.filter(records, &(&1["request_id"] == "prompt"))
    assert admitted["status"] == "accepted"
    settled = Fixture.records(fixture, session)

    :ok = send_frame(client, %{prompt | "request_id" => "prompt-retry"})
    retry = reply(client, "prompt-retry")
    assert retry == %{admitted | "request_id" => "prompt-retry"}

    changed_prompt = %{
      prompt
      | "request_id" => "prompt-changed",
        "content_b64" => Wire.encode_bytes("other")
    }

    configure = %{
      "method" => "session.configure",
      "request_id" => "configure",
      "command_id" => Wire.encode_identity("configure-once"),
      "changes" => %{"max_tokens" => "512"},
      "writer_epoch" => epoch
    }

    compact = %{
      "method" => "session.compact",
      "request_id" => "compact",
      "command_id" => Wire.encode_identity("compact-once"),
      "bounds" => %{"max_attempts" => "4", "deadline_ms" => "60000", "token_budget" => "32768"},
      "writer_epoch" => epoch
    }

    :ok = send_frame(client, configure)
    records_until(client, &event?(&1, "session.configured"))
    :ok = send_frame(client, compact)
    records_until(client, &event?(&1, "context.compaction_finished"))
    settled = Fixture.records(fixture, session) |> tap(&assert(length(&1) > length(settled)))

    for changed <- [
          changed_prompt,
          %{
            configure
            | "request_id" => "configure-changed",
              "changes" => %{"max_tokens" => "256"}
          },
          %{
            compact
            | "request_id" => "compact-changed",
              "bounds" => %{
                "max_attempts" => "3",
                "deadline_ms" => "60000",
                "token_budget" => "32768"
              }
          }
        ] do
      :ok = send_frame(client, changed)
      refused = reply(client, changed["request_id"])
      assert refused["request_id"] == changed["request_id"]
      assert refused["status"] == "refused"
      assert refused["reason"] == "idempotency_conflict"
    end

    :ok =
      send_frame(client, %{
        compact
        | "request_id" => "compact-stale",
          "command_id" => Wire.encode_identity("compact-stale"),
          "writer_epoch" => Wire.encode_identity("stale")
      })

    assert %{"type" => "error", "code" => "control_not_held"} = reply(client, "compact-stale")
    assert Fixture.records(fixture, session) == settled
    :socket.close(client)
  end

  # Concept: a daemon client creates a session with authored remote options.
  # Technical depth: accepted ADR 0055 over /4. Raw instructions and exact
  # decimals cross once through central native preparation; the authored alias
  # is retained in the private genesis; an exact retry replays the admission;
  # changed options under the same command are a runtime command conflict; no
  # public record carries the private instruction text.
  test "remote creation options cross the socket once through central preparation" do
    fixture = fixture()
    daemon = start_daemon(fixture.runtime)
    client = initialized_client(daemon)

    options = %{
      "version" => 1,
      "tools" => [],
      "configuration" => %{
        "model" => " alias/model ",
        "instructions" => %{
          "version" => "current.v1",
          "base" => "SOCKET_PRIVATE_INSTRUCTIONS 猫\n",
          "environment" => "",
          "appendix" => "tail"
        },
        "max_tokens" => "512"
      }
    }

    create = %{
      "method" => "session.create",
      "request_id" => "create",
      "command_id" => Wire.encode_identity(<<0, 255, 1, 128>>),
      "session_options" => options
    }

    :ok = send_frame(client, create)
    admitted = reply(client, "create")
    assert admitted["status"] == "accepted"
    assert Agent.get(fixture.controller, & &1) == 1
    {:ok, session} = Wire.identity(admitted["session_id"])
    [genesis | _] = Fixture.records(fixture, session)
    assert genesis.payload["options"]["configuration"]["model"] == " alias/model "
    assert genesis.payload["initial_configuration"]["max_tokens"] == 512
    assert genesis.payload["initial_configuration"]["model"] == "scripted:v1"

    :ok = send_frame(client, %{create | "request_id" => "retry"})
    assert reply(client, "retry") == %{admitted | "request_id" => "retry"}
    assert Agent.get(fixture.controller, & &1) == 1

    changed = put_in(options, ["configuration", "max_tokens"], "256")
    :ok = send_frame(client, %{create | "request_id" => "changed", "session_options" => changed})
    conflict = reply(client, "changed")
    assert conflict["status"] == "refused"
    assert conflict["reason"] == "runtime_command_conflict"

    :ok =
      send_frame(client, %{
        "method" => "session.inspect",
        "request_id" => "inspect",
        "session_id" => admitted["session_id"]
      })

    inspected = reply(client, "inspect")
    assert inspected["result"]["configuration"]["max_tokens"] == "512"
    refute inspect([admitted, conflict, inspected]) =~ "SOCKET_PRIVATE_INSTRUCTIONS"
    :socket.close(client)
  end

  defp reply(client, id) do
    [reply] =
      client
      |> records_until(&Enum.any?(&1, fn record -> record["request_id"] == id end))
      |> Enum.filter(&(&1["request_id"] == id))

    reply
  end

  defp eventually_admitted(client, request, id, attempts) do
    :ok = send_frame(client, request)

    [reply] =
      Enum.filter(
        records_until(client, &Enum.any?(&1, fn r -> r["request_id"] == id end)),
        &(&1["request_id"] == id)
      )

    cond do
      reply["type"] == "admission" -> reply
      attempts > 0 -> Process.sleep(20) && eventually_admitted(client, request, id, attempts - 1)
      true -> flunk("the uncertain configure never resolved: #{inspect(reply)}")
    end
  end

  defp controlled(client) do
    :ok =
      send_frame(client, %{
        "method" => "session.create",
        "request_id" => "create",
        "command_id" => Wire.encode_identity("create"),
        "session_options" => %{"version" => 1}
      })

    assert [%{"status" => "accepted", "session_id" => encoded}] = receive_records(client, 1)
    {:ok, session} = Wire.identity(encoded)

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
    {encoded, session, epoch}
  end

  defp events(records, kind), do: Enum.filter(records, &(get_in(&1, ["event", "kind"]) == kind))
  defp event?(records, kind), do: events(records, kind) != []

  defp records_until(client, complete) do
    records_until(client, complete, System.monotonic_time(:millisecond) + 5_000, [])
  end

  defp records_until(client, complete, cutoff, records) do
    remaining = cutoff - System.monotonic_time(:millisecond)
    assert remaining > 0
    [record] = receive_records(client, 1, remaining)
    records = records ++ [record]
    if complete.(records), do: records, else: records_until(client, complete, cutoff, records)
  end

  defp fixture do
    {:ok, controller} = Agent.start_link(fn -> 0 end)
    model = Loopex.AgentLoopTestModel.start([])
    executor = Loopex.AgentLoopTestExecutor.start()
    {store, handle} = Loopex.M1RuntimeTestStore.start_store(label: "configure-compact-socket")

    on_exit(fn ->
      for actor <- [controller, model, executor, store] do
        monitor = Process.monitor(actor)
        if Process.alive?(actor), do: GenServer.stop(actor, :normal, 1_000)
        assert_receive {:DOWN, ^monitor, :process, ^actor, _reason}, 1_000
      end
    end)

    {:ok, runtime} =
      Loopex.start_link(
        runtime_id: "configure-compact-socket",
        store: handle,
        context_token_budget: 8_192,
        cleanup_grace_ms: 5_000,
        session_creation_defaults: Fixture.creation_defaults([]),
        model: %{
          module: Preparing,
          model: "scripted:v1",
          options: [controller: controller, script: model, max_tokens: 256]
        },
        executor: %{
          module: Loopex.AgentLoopTestExecutor,
          reference: executor,
          identity: "agent-loop-executor",
          epoch: 1,
          fencing_token: 1,
          workspace_ref: "workspace-ref",
          workspace_lease: "workspace-lease"
        },
        tools: [],
        active_tools: [],
        policy: Loopex.AgentLoopTestPolicy,
        policy_identity: %{"id" => "test", "revision" => "1"},
        grant_decision: {:host_policy, :allow},
        bounds: Fixture.bounds()
      )

    on_exit(fn ->
      monitor = Process.monitor(runtime.supervisor)
      if Process.alive?(runtime.supervisor), do: Loopex.stop(runtime)
      assert_receive {:DOWN, ^monitor, :process, _supervisor, _reason}, 5_000
    end)

    :ok = Loopex.ConfiguredGenesisFixture.await_creation_ready(runtime)
    assert V2.generation() == "loopex.experimental/4"

    %{runtime: runtime, controller: controller, model: model, executor: executor, store: store}
  end
end
