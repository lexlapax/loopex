Code.require_file("../../loopex/test/support/m1_runtime_helper.exs", __DIR__)
Code.require_file("../../loopex/test/support/agent_loop_helper.exs", __DIR__)

defmodule Loopex.AppServer.CurrentCommandsMappingTest do
  use ExUnit.Case, async: false

  alias Loopex.AgentLoopFixture, as: Fixture
  alias Loopex.AppServer.{Connection, Mapping}
  alias Loopex.Runtime.SessionState
  alias LoopexProtocol.Session.{CompactResult, CreationOptions, Inspection}
  alias LoopexProtocol.{ToolDefinition, Wire}

  test "current bounds vectors reach attachment validation only after exact decoding" do
    {fixture, session, attachment} = attached_fixture()
    stale = %{attachment | incarnation_id: "stale-incarnation"}
    context = %{runtime: fixture.runtime, attachment: stale}
    before = Fixture.records(fixture, session)

    for vector <- vectors("command-bounds")["cases"],
        vector["kind"] in ~w(prompt follow_up compact) do
      request =
        request("session." <> vector["kind"], <<0, 255, 1, 128>>)
        |> Map.put("bounds", vector["input"])
        |> then(fn request ->
          if vector["kind"] == "compact",
            do: request,
            else: Map.put(request, "content_b64", Wire.encode_bytes("exact content"))
        end)

      if vector["error"] do
        assert {:error, %{"code" => "invalid_request"}} = Mapping.call(request, context),
               vector["name"]
      else
        assert {:ok, reply} = Mapping.call(request, context), vector["name"]
        assert reply["status"] == "refused"
        assert reply["reason"] == "session_unavailable"
        assert reply["command_id"] == request["command_id"]
      end
    end

    assert Fixture.records(fixture, session) == before
    assert Fixture.events(fixture, session) == []
    assert Loopex.AgentLoopTestModel.dispatched(fixture.model) == []
    assert Loopex.AgentLoopTestExecutor.jobs(fixture.executor) == []
  end

  test "prompt partial quantities remain exact and duplicate replay ignores changed defaults" do
    huge = 1_267_650_600_228_229_401_496_703_205_376
    {fixture, session, attachment} = attached_fixture(script: [%{hold: self(), text: "done"}])
    context = %{runtime: fixture.runtime, attachment: attachment}

    command =
      request("session.prompt", <<0, 255, 1, 128>>)
      |> Map.put("content_b64", Wire.encode_bytes("exact 猫\n"))
      |> Map.put("bounds", %{"max_turns" => Integer.to_string(huge)})

    assert {:ok, admission} = Mapping.call(command, context)
    assert admission["status"] == "accepted"
    assert admission["command_id"] == command["command_id"]
    assert_receive {:holding, worker}, 5_000
    worker_monitor = Process.monitor(worker)

    [record] = command_records(fixture, session, <<0, 255, 1, 128>>)
    assert record.payload["command_revision"] == 2
    assert record.payload["authored_bounds"] == %{"max_turns" => huge}
    assert record.payload["content"] == "exact 猫\n"
    assert {:ok, native} = Loopex.session_status(fixture.runtime, session)
    assert native.active_bounds.max_turns == huge
    assert native.active_bounds.token_budget == 1_000_000

    assert {:ok, inspected} =
             Mapping.call(
               %{
                 "method" => "session.inspect",
                 "request_id" => "inspect",
                 "session_id" => Wire.encode_identity(session)
               },
               context
             )

    projection = inspected["result"]
    assert projection["active_bounds"]["max_turns"] == Integer.to_string(huge)
    assert {:ok, decoded} = Inspection.decode_wire(projection)
    assert decoded.active_bounds == native.active_bounds
    assert decoded.configuration == native.configuration
    assert map_size(projection) == 11
    refute Map.has_key?(projection, "compact_pending")
    refute Map.has_key?(projection, "owner_epoch")
    refute Map.has_key?(projection["configuration"], "provider_mapping")
    refute Map.has_key?(projection["configuration"], "model_capabilities")

    {:ok, children} = Loopex.Runtime.children(fixture.runtime)
    owner = :sys.get_state(children.control).sessions[session].coordinator
    :sys.replace_state(owner, &%{&1 | bounds: %{max_turns: 1, token_budget: 2, deadline_ms: 3}})
    before = Fixture.records(fixture, session)
    assert {:ok, retried} = Mapping.call(%{command | "request_id" => "retry"}, context)
    assert retried == %{admission | "request_id" => "retry"}
    changed = put_in(command, ["bounds", "max_turns"], "2")
    assert {:ok, refused} = Mapping.call(changed, context)
    assert refused["reason"] == "idempotency_conflict"
    assert Fixture.records(fixture, session) == before
    assert {:ok, captured} = Loopex.session_status(fixture.runtime, session)
    assert captured.active_bounds == native.active_bounds
    send(worker, :release)
    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, _reason}, 5_000
    await_event(fixture, session, "run.finished")
  end

  test "omitted and empty prompt bounds remain distinct while follow-up retains its own ceiling" do
    for authored <- [:omitted, %{}] do
      {fixture, session, attachment} =
        attached_fixture(script: [%{hold: self(), text: "done"}, %{text: "next"}])

      context = %{runtime: fixture.runtime, attachment: attachment}

      prompt =
        request("session.prompt", "prompt") |> Map.put("content_b64", Wire.encode_bytes("go"))

      prompt = if authored == :omitted, do: prompt, else: Map.put(prompt, "bounds", authored)
      assert {:ok, %{"status" => "accepted"}} = Mapping.call(prompt, context)
      assert_receive {:holding, worker}, 5_000
      monitor = Process.monitor(worker)
      [record] = command_records(fixture, session, "prompt")
      assert record.payload["authored_bounds"] == if(authored == :omitted, do: nil, else: %{})
      ceiling = System.system_time(:millisecond) + 60_000

      follow =
        request("session.follow_up", "follow")
        |> Map.put("content_b64", Wire.encode_bytes("next"))
        |> Map.put("bounds", %{"deadline_at_ms" => ceiling})

      assert {:ok, %{"status" => "accepted"}} = Mapping.call(follow, context)
      [queued] = command_records(fixture, session, "follow")
      assert queued.payload["authored_bounds"] == %{"deadline_at_ms" => ceiling}
      send(worker, :release)
      assert_receive {:DOWN, ^monitor, :process, ^worker, _reason}, 5_000
      run = SessionState.command_run_id(session, "follow")
      await_event(fixture, session, "run.finished", run)

      assert {:ok, recovered} =
               SessionState.recover(
                 session,
                 Fixture.records(fixture, session),
                 Fixture.events(fixture, session)
               )

      {bounds, _accounting} = SessionState.accounting(recovered, run)
      assert bounds.deadline_at_ms == ceiling
      assert bounds.max_turns == 8
      assert bounds.token_budget == 1_000_000
      assert bounds.deadline_ms == 600_000
    end
  end

  test "steer bounds and missing compact bounds refuse without durable work" do
    {fixture, session, attachment} = attached_fixture()
    context = %{runtime: fixture.runtime, attachment: attachment}
    before = Fixture.records(fixture, session)

    for request <- [
          request("session.compact", "compact"),
          request("session.steer", "steer")
          |> Map.merge(%{
            "content_b64" => Wire.encode_bytes("steer"),
            "run_id" => Wire.encode_identity("run"),
            "bounds" => %{}
          })
        ] do
      assert {:error, %{"code" => "invalid_request"}} = Mapping.call(request, context)
    end

    assert {:error, %{"code" => "not_attached"}} =
             Mapping.call(request("session.compact", "compact"), %{runtime: fixture.runtime})

    assert Fixture.records(fixture, session) == before
  end

  test "creation requires current closed options and refuses all invalid literal vectors before native work" do
    for vector <- vectors("creation-options")["cases"], vector["error"] do
      request = request("session.create", "create") |> Map.put("session_options", vector["input"])
      assert {:error, %{"code" => "invalid_request"}} = Mapping.call(request, %{}), vector["name"]
    end

    request = request("session.create", "create")
    assert {:error, %{"code" => "invalid_request"}} = Mapping.call(request, %{})
    valid = Map.put(request, "session_options", %{"version" => 1})

    for private <- ~w(session_id writer_epoch genesis credentials workspace) do
      assert {:error, %{"code" => "invalid_request"}} =
               Mapping.call(Map.put(valid, private, "PRIVATE_CREATION_CANARY"), %{})
    end
  end

  test "ordered remote tool selection creates one exact genesis and replay retains authored presence" do
    first = Fixture.tool_definition()
    second = first |> Map.put("name", "second") |> Map.put("tool_id", "example.second")
    fixture = fixture(tools: [first, second])
    options = %{"version" => 1, "tools" => ["second", "write"]}
    request = request("session.create", <<0, 255, 128>>) |> Map.put("session_options", options)
    context = %{runtime: fixture.runtime}
    assert {:ok, admission} = Mapping.call(request, context)
    assert admission["status"] == "accepted"
    assert {:ok, session} = Wire.identity(admission["session_id"])
    [genesis | _] = Fixture.records(fixture, session)
    assert genesis.payload.kind == "session_genesis_v3"
    assert genesis.payload["options"] == options
    assert genesis.payload["tool_selection"]["definitions"] == [second, first]
    before = Fixture.records(fixture, session)
    assert {:ok, replay} = Mapping.call(%{request | "request_id" => "retry"}, context)
    assert replay == %{admission | "request_id" => "retry"}
    changed = put_in(request, ["session_options", "tools"], ["write", "second"])
    assert {:ok, refused} = Mapping.call(changed, context)
    assert refused["reason"] == "runtime_command_conflict"
    assert Fixture.records(fixture, session) == before

    for options <- [%{"version" => 1}, %{"version" => 1, "tools" => []}] do
      request =
        request("session.create", :erlang.term_to_binary(options))
        |> Map.put("session_options", options)

      assert {:ok, %{"status" => "accepted", "session_id" => id}} = Mapping.call(request, context)
      assert {:ok, created} = Wire.identity(id)
      [retained | _] = Fixture.records(fixture, created)
      assert retained.payload["options"] == options
    end

    decoded = %{"version" => 1, "configuration" => %{"max_tokens" => 9_007_199_254_740_993}}
    wire_options = put_in(decoded, ["configuration", "max_tokens"], "9007199254740993")
    assert CreationOptions.decode_wire(wire_options) == {:ok, decoded}

    assert {:error, native_reason} =
             Loopex.create_session(fixture.runtime, decoded, command_id: "explicit")

    request = request("session.create", "explicit") |> Map.put("session_options", wire_options)
    assert {:ok, refused} = Mapping.call(request, context)
    assert refused["reason"] == Atom.to_string(native_reason)
  end

  test "all literal answers preserve their branch and malformed unions refuse before owner admission" do
    {fixture, session, attachment} = attached_fixture()
    stale = %{attachment | incarnation_id: "stale-incarnation"}
    context = %{runtime: fixture.runtime, attachment: stale}
    before = Fixture.records(fixture, session)

    for vector <- vectors("question-answer")["cases"] do
      request =
        request("session.respond_interaction", "answer")
        |> Map.put("interaction_id", Wire.encode_identity(<<0, 255>>))
        |> Map.put("answer", vector["input"])

      if vector["error"] do
        assert {:error, %{"code" => "invalid_request"}} = Mapping.call(request, context),
               vector["name"]
      else
        assert {:ok, reply} = Mapping.call(request, context), vector["name"]
        assert reply["reason"] == "session_unavailable"
        assert reply["status"] == "refused"
      end
    end

    assert Fixture.records(fixture, session) == before
  end

  test "model question literal response identities survive mapped choice text and decline" do
    path = Path.expand("../../loopex/priv/vectors/model_question.v1.json", __DIR__)
    corpus = path |> File.read!() |> JSON.decode!()

    for vector <- corpus["vectors"] do
      {fixture, session, attachment} =
        attached_fixture(
          tools: [ToolDefinition.question_definition()],
          script: [
            %{
              text: "question",
              calls: [%{id: "ask-1", name: "ask", arguments: vector["arguments"]}]
            },
            %{text: "done", calls: []}
          ]
        )

      context = %{runtime: fixture.runtime, attachment: attachment}

      assert {:accepted, "prompt"} =
               Loopex.command(attachment, %{
                 type: :prompt,
                 command_id: "prompt",
                 content: "implement"
               })

      opened = await_event(fixture, session, "interaction.requested")
      assert opened["producer"] == "model_tool"
      answer = vector["answer"]

      wire_answer =
        if Map.has_key?(answer, "choice_id"),
          do: Map.update!(answer, "choice_id", &Wire.encode_identity/1),
          else: answer

      request =
        request("session.respond_interaction", corpus["command_id"])
        |> Map.put("interaction_id", Wire.encode_identity(opened["interaction_id"]))
        |> Map.put("answer", wire_answer)

      assert {:ok, admitted} = Mapping.call(request, context)
      assert admitted["status"] == "accepted"
      settled = await_event(fixture, session, "interaction." <> vector["disposition"])
      assert settled["answer"] == answer
      [record] = command_records(fixture, session, corpus["command_id"])
      assert record.payload.kind == "model_question_response_admitted_v2"
      assert record.payload["answer"] == answer
      assert record.payload["command_digest"] == vector["command_digest"]
      assert record.payload["interaction_id"] == opened["interaction_id"]
      assert settled["run_id"] == opened["run_id"]
      assert settled["tool_call_id"] == "ask-1"
      before = Fixture.records(fixture, session)
      assert {:ok, retry} = Mapping.call(%{request | "request_id" => "retry"}, context)
      assert retry == %{admitted | "request_id" => "retry"}
      assert Fixture.records(fixture, session) == before
      await_event(fixture, session, "run.finished")
      assert Loopex.AgentLoopTestExecutor.jobs(fixture.executor) == []
    end
  end

  test "an uncertain prompt admission remains an error under its original command identity" do
    {fixture, session, attachment} = attached_fixture()
    context = %{runtime: fixture.runtime, attachment: attachment}

    request =
      request("session.prompt", "uncertain")
      |> Map.put("content_b64", Wire.encode_bytes("go"))
      |> Map.put("bounds", %{"max_turns" => "3"})

    assert :ok =
             Loopex.M1RuntimeTestStore.inject(
               fixture.store,
               {:session_journal_commit, :after_linearization_before_result}
             )

    assert {:error, unknown} = Mapping.call(request, context)

    assert unknown == %{
             "type" => "error",
             "code" => "admission_unknown",
             "message" => "the outcome of this command is not yet known",
             "request_id" => "request"
           }

    refute Map.has_key?(unknown, "status")
    await_event(fixture, session, "run.finished")
    assert {:ok, replay} = Mapping.call(%{request | "request_id" => "retry"}, context)
    assert replay["status"] == "accepted"
    assert replay["command_id"] == request["command_id"]
    [retained] = command_records(fixture, session, "uncertain")
    assert retained.payload["authored_bounds"] == %{"max_turns" => 3}
  end

  test "compact maps explicit admission separately from its committed unchanged result through the current generation" do
    {fixture, session, attachment} = attached_fixture()
    context = %{runtime: fixture.runtime, attachment: attachment}

    request =
      request("session.compact", <<0, 255, 128>>)
      |> Map.put("bounds", %{
        "max_attempts" => "4",
        "deadline_ms" => "60000",
        "token_budget" => "32768"
      })

    assert Mapping.implemented?("session.compact")
    assert "session.compact" in LoopexProtocol.Session.methods()
    assert {:ok, admission} = Mapping.call(request, context)
    assert admission["status"] == "accepted"
    refute Map.has_key?(admission, "result")
    finished = await_event(fixture, session, "context.compaction_finished")
    completion = Map.take(finished, ~w(episode_id command_id result))
    assert finished["command_id"] == <<0, 255, 128>>
    assert {:ok, encoded} = CompactResult.encode_completion(completion)
    assert encoded["result"]["disposition"] == "unchanged"
    assert encoded["result"]["cleanup"] == "confirmed"
    assert CompactResult.decode_completion(encoded) == {:ok, completion}
    assert Loopex.AgentLoopTestModel.dispatched(fixture.model) == []
    assert Loopex.AgentLoopTestExecutor.jobs(fixture.executor) == []
    before = Fixture.records(fixture, session)
    assert {:ok, retried} = Mapping.call(%{request | "request_id" => "retry"}, context)
    assert retried == %{admission | "request_id" => "retry"}
    assert Fixture.records(fixture, session) == before

    connection = Connection.new(runtime: fixture.runtime)

    assert {:ok, _initialized, connection} =
             Connection.initialize(connection, %{
               "method" => "initialize",
               "request_id" => "initialize",
               "generations" => [LoopexProtocol.Session.generation()],
               "capabilities" => []
             })

    connection = Connection.attach(connection, attachment)
    assert {:ok, connected_replay, ^connection} = Connection.dispatch(connection, request)
    assert connected_replay == admission
    refute Map.has_key?(connected_replay, "result")
    assert Fixture.records(fixture, session) == before
  end

  defp request(method, command),
    do: %{
      "method" => method,
      "request_id" => "request",
      "command_id" => Wire.encode_identity(command)
    }

  defp vectors(name) do
    :loopex_protocol
    |> :code.priv_dir()
    |> Path.join("vectors/" <> name <> ".v1.json")
    |> File.read!()
    |> JSON.decode!()
  end

  defp fixture(options \\ []) do
    fixture = Fixture.start(Keyword.put_new(options, :script, [%{text: "done", calls: []}]))
    on_exit(fn -> Fixture.stop(fixture) end)
    fixture
  end

  defp attached_fixture(options \\ []) do
    fixture = fixture(options)

    assert {:ok, session} =
             Loopex.create_session(fixture.runtime, %{"version" => 1}, command_id: "create")

    assert {:ok, attachment} = Loopex.attach(fixture.runtime, session, after_event_sequence: 0)
    {fixture, session, attachment}
  end

  defp command_records(fixture, session, command) do
    fixture |> Fixture.records(session) |> Enum.filter(&(&1.payload["command_id"] == command))
  end

  defp await_event(fixture, session, kind, run \\ nil) do
    await_event_until(fixture, session, kind, run, System.monotonic_time(:millisecond) + 5_000)
  end

  defp await_event_until(fixture, session, kind, run, cutoff) do
    assert System.monotonic_time(:millisecond) < cutoff

    event =
      Enum.find(
        Fixture.events(fixture, session),
        &(&1.kind == kind and (run == nil or &1["run_id"] == run))
      )

    assert System.monotonic_time(:millisecond) <= cutoff

    if event do
      event
    else
      Process.sleep(min(10, max(cutoff - System.monotonic_time(:millisecond), 0)))
      await_event_until(fixture, session, kind, run, cutoff)
    end
  end
end
