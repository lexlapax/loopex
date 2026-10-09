Code.require_file("../../loopex/test/support/m1_runtime_helper.exs", __DIR__)
Code.require_file("../../loopex/test/support/agent_loop_helper.exs", __DIR__)
Code.require_file("../../loopex/test/support/model_preparation_conformance.exs", __DIR__)

defmodule Loopex.AppServer.CurrentConnectionIngressTest do
  use ExUnit.Case, async: false

  alias Loopex.AppServer.Connection
  alias Loopex.AgentLoopFixture, as: Fixture
  alias LoopexProtocol.{Session, ToolDefinition, Wire}
  alias LoopexProtocol.Session.{CreationOptions, Inspection}

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

  test "malformed initialize leaves one attempt available while well-formed refusal fences all session traffic" do
    fixture = fixture()
    fresh = Connection.new(runtime: fixture.runtime)
    valid = initialize()

    before =
      Map.take(:sys.get_state(fixture.store), [:sessions, :runtime_commands, :creation_calls])

    for invalid <- [
          Map.delete(valid, "method"),
          Map.put(valid, "private", "INITIALIZE_CANARY"),
          Map.put(valid, "capabilities", nil)
        ] do
      assert {:error, refusal, ^fresh} = Connection.initialize(fresh, invalid)
      assert refusal["code"] == "invalid_request"
      refute :erlang.term_to_binary(refusal) =~ "INITIALIZE_CANARY"
    end

    assert {:ok, _initialized, _connection} = Connection.initialize(fresh, valid)

    for offered <- [
          ["loopex.experimental/1"],
          ["loopex.experimental/2"],
          ["loopex.experimental/4"]
        ] do
      assert {:error, %{"code" => "unsupported_generation"}, refused} =
               Connection.initialize(fresh, %{valid | "generations" => offered})

      assert {:error, %{"code" => "already_initialized"}, ^refused} =
               Connection.initialize(refused, valid)

      for request <-
            requests() ++
              [
                request("session.create", "create")
                |> Map.put("session_options", %{"version" => 1}),
                %{
                  "method" => "session.attach",
                  "request_id" => "attach",
                  "session_id" => Wire.encode_identity("no-session")
                }
              ] do
        assert {:error, %{"code" => "not_initialized"}, ^refused} =
                 Connection.dispatch(refused, request)
      end
    end

    for offered <- [
          ["loopex.experimental/1", "loopex.experimental/4", "loopex.experimental/3"],
          ["loopex.experimental/3", "loopex.experimental/4", "loopex.experimental/1"]
        ] do
      assert {:ok, reply, connection} =
               Connection.initialize(fresh, %{valid | "generations" => offered})

      assert reply["selected_generation"] == "loopex.experimental/3"
      assert Connection.generation(connection) == "loopex.experimental/3"
    end

    assert Map.take(:sys.get_state(fixture.store), [:sessions, :runtime_commands, :creation_calls]) ==
             before

    assert Agent.get(fixture.controller, & &1) == 0
    assert Loopex.AgentLoopTestModel.dispatched(fixture.model) == []
    assert Loopex.AgentLoopTestExecutor.jobs(fixture.executor) == []
    assert {:ok, configuration} = Loopex.Runtime.configuration(fixture.runtime)
    assert configuration.runtime_id == "current-connection"
  end

  test "missing and stale attachment authority cannot prepare mutate or dispatch current commands" do
    {fixture, session, attachment, connection} = attached_fixture()
    before = Fixture.records(fixture, session)

    for request <- requests() do
      assert {:error, %{"code" => "not_attached"}, _connection} =
               Connection.dispatch(connection, request)
    end

    stale = Connection.attach(connection, %{attachment | incarnation_id: "stale-incarnation"})

    for request <- requests() do
      assert {:ok, refusal, _connection} = Connection.dispatch(stale, request)
      assert refusal["status"] == "refused"
      assert refusal["reason"] == "session_unavailable"
      assert refusal["command_id"] == request["command_id"]
    end

    assert Fixture.records(fixture, session) == before
    assert Fixture.events(fixture, session) == []
    assert Agent.get(fixture.controller, & &1) == 0
    assert Loopex.AgentLoopTestModel.dispatched(fixture.model) == []
    assert Loopex.AgentLoopTestExecutor.jobs(fixture.executor) == []
  end

  test "closed command envelopes refuse missing identities unknown authority and nested alternatives before Store or effects" do
    {fixture, session, attachment, connection} = attached_fixture()
    connection = Connection.attach(connection, attachment)
    before = Fixture.records(fixture, session)

    for request <- requests(),
        invalid <- [
          Map.delete(request, "command_id"),
          Map.delete(request, "request_id"),
          Map.put(request, "request_id", "bad id"),
          Map.put(request, "writer_epoch", Wire.encode_identity("not-foreground-authority")),
          Map.put(request, "allow", false)
        ] do
      assert {:error, refusal, returned} = Connection.dispatch(connection, invalid)
      assert refusal["code"] == "invalid_request"
      assert Connection.in_flight(returned) == []
      assert returned.attachment == connection.attachment
      refute Map.has_key?(refusal, "status")
    end

    invalid_nested = [
      request("session.prompt", "bad-prompt")
      |> Map.merge(%{"content_b64" => Wire.encode_bytes("go"), "bounds" => nil}),
      request("session.follow_up", "bad-follow")
      |> Map.merge(%{"content_b64" => Wire.encode_bytes("go"), "bounds" => %{"max_turns" => "1"}}),
      request("session.steer", "bad-steer")
      |> Map.merge(%{
        "content_b64" => Wire.encode_bytes("go"),
        "run_id" => Wire.encode_identity("run"),
        "bounds" => %{}
      }),
      request("session.compact", "bad-compact")
      |> Map.put("bounds", %{
        "max_attempts" => "5",
        "deadline_ms" => "60000",
        "token_budget" => "32768"
      }),
      request("session.configure", "bad-configure")
      |> Map.put("changes", %{"provider_mapping" => %{"allow" => false}}),
      request("session.respond_interaction", "bad-answer")
      |> Map.merge(%{
        "interaction_id" => Wire.encode_identity("interaction"),
        "answer" => %{"text" => "allow", "choice_id" => Wire.encode_identity("allow")}
      })
    ]

    for invalid <- invalid_nested do
      assert {:error, %{"code" => "invalid_request"}, returned} =
               Connection.dispatch(connection, invalid)

      assert Connection.in_flight(returned) == []
    end

    for options <- [
          nil,
          %{},
          %{"version" => 1, "credentials" => "CREATE_CANARY"},
          %{"version" => 1, "configuration" => %{"max_tokens" => 512}}
        ] do
      invalid = request("session.create", "bad-create") |> Map.put("session_options", options)

      assert {:error, %{"code" => "invalid_request"}, _returned} =
               Connection.dispatch(connection, invalid)
    end

    assert Fixture.records(fixture, session) == before
    assert Fixture.events(fixture, session) == []
    assert Agent.get(fixture.controller, & &1) == 0
    assert Loopex.AgentLoopTestModel.dispatched(fixture.model) == []
    assert Loopex.AgentLoopTestExecutor.jobs(fixture.executor) == []
  end

  test "current Connection configure and compact use native admission and duplicate identity" do
    {fixture, session, attachment, connection} = attached_fixture()
    connection = Connection.attach(connection, attachment)

    request =
      request("session.configure", <<0, 255, 128>>)
      |> Map.put("changes", %{"max_tokens" => "512"})

    assert {:ok, admitted, connection} = Connection.dispatch(connection, request)
    assert admitted["status"] == "accepted"
    assert admitted["command_id"] == request["command_id"]
    assert Agent.get(fixture.controller, & &1) == 1

    assert {:ok, %{configuration: configuration}} =
             Loopex.session_status(fixture.runtime, session)

    assert configuration["max_tokens"] == 512
    {native, native_session, native_attachment, _native_connection} = attached_fixture()

    assert {:accepted, native_id} =
             Loopex.command(native_attachment, %{
               type: :configure,
               command_id: <<0, 255, 128>>,
               changes: %{"max_tokens" => 512}
             })

    assert native_id == <<0, 255, 128>>

    configured = fn source, id ->
      source
      |> Fixture.records(id)
      |> Enum.filter(&(&1.payload.kind == "session_configuration_admitted_v2"))
      |> Enum.map(& &1.payload)
    end

    assert configured.(fixture, session) == configured.(native, native_session)
    before = Fixture.records(fixture, session)

    assert {:ok, replay, connection} =
             Connection.dispatch(connection, %{request | "request_id" => "retry"})

    assert replay == %{admitted | "request_id" => "retry"}
    assert Fixture.records(fixture, session) == before
    assert Agent.get(fixture.controller, & &1) == 1
    assert Connection.in_flight(connection) == []

    compact = Enum.find(requests(), &(&1["method"] == "session.compact"))
    assert {:ok, compact_admission, connection} = Connection.dispatch(connection, compact)
    assert compact_admission["status"] == "accepted"
    refute Map.has_key?(compact_admission, "result")
    finished = await_event(fixture, session, "context.compaction_finished")
    assert finished["result"]["disposition"] == "unchanged"
    assert finished["command_id"] == "compact"

    assert {:accepted, "compact"} =
             Loopex.command(native_attachment, %{
               type: :compact,
               command_id: "compact",
               bounds: %{"max_attempts" => 4, "deadline_ms" => 60_000, "token_budget" => 32_768}
             })

    native_finished = await_event(native, native_session, "context.compaction_finished")

    assert Map.take(finished, ~w(episode_id command_id result)) ==
             Map.take(native_finished, ~w(episode_id command_id result))

    assert {:ok, _replay, _connection} =
             Connection.dispatch(connection, %{compact | "request_id" => "compact-retry"})

    assert Loopex.AgentLoopTestModel.dispatched(fixture.model) == []
    assert Loopex.AgentLoopTestExecutor.jobs(fixture.executor) == []
  end

  test "remote creation captures raw instructions and exact decimals once through central native preparation" do
    fixture = fixture()
    connection = initialized(fixture)

    raw = %{
      "version" => "current.v1",
      "base" => "CONNECTION_PRIVATE_INSTRUCTIONS 猫\n",
      "environment" => "",
      "appendix" => "tail"
    }

    options = %{
      "version" => 1,
      "tools" => [],
      "configuration" => %{
        "model" => " alias/model ",
        "instructions" => raw,
        "max_tokens" => "512",
        "context_token_budget" => "8192",
        "system_class_tokens" => "5000"
      }
    }

    assert {:ok, native} = CreationOptions.decode_wire(options)
    request = request("session.create", <<0, 255, 1, 128>>) |> Map.put("session_options", options)
    assert {:ok, admitted, connection} = Connection.dispatch(connection, request)
    assert admitted["status"] == "accepted"
    assert Agent.get(fixture.controller, & &1) == 1
    assert {:ok, session} = Wire.identity(admitted["session_id"])
    [genesis | _] = Fixture.records(fixture, session)
    assert genesis.payload["options"]["configuration"]["model"] == " alias/model "

    assert genesis.payload["options"]["configuration"]["max_tokens"] ==
             native["configuration"]["max_tokens"]

    assert genesis.payload["initial_configuration"]["max_tokens"] == 512
    assert genesis.payload["initial_configuration"]["configuration_version"] == 1
    direct = fixture()

    assert {:ok, direct_session} =
             Loopex.create_session(direct.runtime, native, command_id: <<0, 255, 1, 128>>)

    [direct_genesis | _] = Fixture.records(direct, direct_session)
    assert genesis.payload == direct_genesis.payload

    assert Map.take(
             genesis.payload["initial_configuration"]["instructions"],
             ~w(version base environment appendix)
           ) == raw

    assert {:ok, inspected, connection} =
             Connection.dispatch(connection, %{
               "method" => "session.inspect",
               "request_id" => "inspect",
               "session_id" => admitted["session_id"]
             })

    assert {:ok, _native_inspection} = Inspection.decode_wire(inspected["result"])
    refute :erlang.term_to_binary({admitted, inspected}) =~ "CONNECTION_PRIVATE_INSTRUCTIONS"
    before = Fixture.records(fixture, session)

    assert {:ok, retry, _connection} =
             Connection.dispatch(connection, %{request | "request_id" => "retry"})

    assert retry == %{admitted | "request_id" => "retry"}
    assert Fixture.records(fixture, session) == before
    assert Agent.get(fixture.controller, & &1) == 1
    assert Loopex.AgentLoopTestModel.dispatched(fixture.model) == []
    assert Loopex.AgentLoopTestExecutor.jobs(fixture.executor) == []
  end

  test "a current Connection prompt and model text answer preserve run question and answer-command identities" do
    tools = [ToolDefinition.question_definition()]

    {fixture, session, attachment, connection} =
      attached_fixture(
        tools: tools,
        script: [
          %{
            text: "question",
            calls: [%{id: "ask-1", name: "ask", arguments: %{"question" => "Explain"}}]
          },
          %{text: "done", calls: []}
        ]
      )

    connection = Connection.attach(connection, attachment)

    prompt =
      request("session.prompt", "prompt")
      |> Map.merge(%{"content_b64" => Wire.encode_bytes("go"), "bounds" => %{"max_turns" => "3"}})

    assert {:ok, %{"status" => "accepted"}, connection} = Connection.dispatch(connection, prompt)
    pending = await_event(fixture, session, "interaction.requested")

    answer =
      request("session.respond_interaction", <<0, 255, 128>>)
      |> Map.merge(%{
        "interaction_id" => Wire.encode_identity(pending["interaction_id"]),
        "answer" => %{"text" => "exact response 猫\n"}
      })

    assert {:ok, admission, connection} = Connection.dispatch(connection, answer)
    assert admission["status"] == "accepted"
    settled = await_event(fixture, session, "interaction.answered")
    assert settled["interaction_id"] == pending["interaction_id"]
    assert settled["run_id"] == pending["run_id"]
    assert settled["tool_call_id"] == "ask-1"
    assert settled["answer"] == %{"text" => "exact response 猫\n"}
    assert settled["command_id"] == <<0, 255, 128>>
    await_event(fixture, session, "run.finished")
    assert Connection.in_flight(connection) == []
    assert Loopex.AgentLoopTestExecutor.jobs(fixture.executor) == []
  end

  defp initialize,
    do: %{
      "method" => "initialize",
      "request_id" => "initialize",
      "generations" => [Session.generation()],
      "capabilities" => []
    }

  defp request(method, id),
    do: %{"method" => method, "request_id" => "request", "command_id" => Wire.encode_identity(id)}

  defp requests do
    [
      request("session.configure", "configure") |> Map.put("changes", %{"max_tokens" => "512"}),
      request("session.compact", "compact")
      |> Map.put("bounds", %{
        "max_attempts" => "4",
        "deadline_ms" => "60000",
        "token_budget" => "32768"
      }),
      request("session.prompt", "prompt") |> Map.put("content_b64", Wire.encode_bytes("go")),
      request("session.follow_up", "follow") |> Map.put("content_b64", Wire.encode_bytes("next")),
      request("session.respond_interaction", "answer")
      |> Map.merge(%{
        "interaction_id" => Wire.encode_identity("interaction"),
        "answer" => %{"disposition" => "declined"}
      })
    ]
  end

  defp fixture(options \\ []) do
    tools = Keyword.get(options, :tools, [])
    {:ok, controller} = Agent.start_link(fn -> 0 end)
    model = Loopex.AgentLoopTestModel.start(Keyword.get(options, :script, []))
    executor = Loopex.AgentLoopTestExecutor.start()
    {store, handle} = Loopex.M1RuntimeTestStore.start_store(label: "current-connection")

    on_exit(fn ->
      for actor <- [controller, model, executor, store] do
        monitor = Process.monitor(actor)
        if Process.alive?(actor), do: GenServer.stop(actor, :normal, 1_000)
        assert_receive {:DOWN, ^monitor, :process, ^actor, _reason}, 1_000
      end
    end)

    {:ok, runtime} =
      Loopex.start_link(
        runtime_id: "current-connection",
        store: handle,
        context_token_budget: 8_192,
        cleanup_grace_ms: 5_000,
        session_creation_defaults: Fixture.creation_defaults(tools),
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
        tools: tools,
        active_tools: Enum.map(tools, & &1["tool_id"]),
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

    # Concept: current command fixtures use the original ready creation startup.
    # Technical depth: the existing shared observer pins the original Control and
    # startup identity within its unchanged 1,000 ms observation cutoff. Cleanup
    # registration above remains in place before the fallible observation.
    :ok = Loopex.ConfiguredGenesisFixture.await_creation_ready(runtime)

    %{runtime: runtime, controller: controller, model: model, executor: executor, store: store}
  end

  defp initialized(fixture) do
    assert {:ok, reply, connection} =
             Connection.initialize(Connection.new(runtime: fixture.runtime), initialize())

    assert reply["selected_generation"] == "loopex.experimental/3"
    connection
  end

  defp attached_fixture(options \\ []) do
    fixture = fixture(options)

    assert {:ok, session} =
             Loopex.create_session(fixture.runtime, %{"version" => 1}, command_id: "create")

    assert {:ok, attachment} = Loopex.attach(fixture.runtime, session, after_event_sequence: 0)
    {fixture, session, attachment, initialized(fixture)}
  end

  defp await_event(fixture, session, kind) do
    await_event_until(fixture, session, kind, System.monotonic_time(:millisecond) + 5_000)
  end

  defp await_event_until(fixture, session, kind, cutoff) do
    assert System.monotonic_time(:millisecond) < cutoff
    event = Enum.find(Fixture.events(fixture, session), &(&1.kind == kind))
    assert System.monotonic_time(:millisecond) <= cutoff

    if event,
      do: event,
      else:
        (
          Process.sleep(min(10, max(cutoff - System.monotonic_time(:millisecond), 0)))
          await_event_until(fixture, session, kind, cutoff)
        )
  end
end
