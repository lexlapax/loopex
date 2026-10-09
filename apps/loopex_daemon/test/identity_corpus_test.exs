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
        "session_options" => %{"version" => 1}
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
        "session_options" => %{"version" => 1}
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

  # Concept: model questions settle through the controller's actual socket route.
  # Technical depth: independent literal vectors bind the original question and
  # command, while actual Core records and the next model request prove the
  # answer became one tool result. Refused control and malformed unions leave
  # those records unchanged; replay returns the original admission once.
  @question_corpus Path.expand("../../loopex/priv/vectors/model_question.v1.json", __DIR__)
                   |> File.read!()
                   |> JSON.decode!()

  for vector <- @question_corpus["vectors"] do
    @question_vector vector

    test "a model question #{vector["name"]} answer settles once through the controller socket" do
      vector = @question_vector

      fixture =
        Fixture.start(
          tools: [LoopexProtocol.ToolDefinition.question_definition()],
          script: [
            %{
              text: "question",
              calls: [%{id: "ask-1", name: "ask", arguments: vector["arguments"]}]
            },
            %{text: "done", calls: []}
          ]
        )

      actors =
        question_monitors([
          fixture.runtime.supervisor,
          fixture.store,
          fixture.model,
          fixture.executor
        ])

      try do
        question_over_daemon(fixture, vector)
      after
        try do
          Fixture.stop(fixture)
        after
          question_close_actors(actors)
        end
      end
    end
  end

  defp question_over_daemon(fixture, vector) do
    daemon = start_daemon(fixture.runtime)
    actors = question_monitors([daemon.listener, daemon.owner, daemon.registry, daemon.relay])

    try do
      client = connect(daemon)

      try do
        :ok =
          send_frame(client, %{
            "method" => "initialize",
            "request_id" => "init",
            "generations" => ["loopex.experimental/4"],
            "capabilities" => []
          })

        assert [initialized] = receive_records(client, 1)
        assert initialized["selected_generation"] == "loopex.experimental/4"

        assert initialized["exact_schema_sha256"] ==
                 "9306e4aeb2ffb9aab3cf4dac94db5a1e4699f09d3f58cc57e2fa79a7e63ef7b9"

        [row] = daemon.registry |> :sys.get_state() |> Map.fetch!(:rows) |> Map.values()
        connection = row.connection_pid
        monitor = Process.monitor(connection)

        try do
          question_round_trip(client, connection, fixture, vector)
        after
          :socket.close(client)
          assert_receive {:DOWN, ^monitor, :process, ^connection, _reason}, 5_000
        end
      after
        :socket.close(client)
      end
    after
      question_close_actors(actors)
    end
  end

  defp question_round_trip(client, connection, fixture, vector) do
    :ok =
      send_frame(client, %{
        "method" => "session.create",
        "request_id" => "create",
        "command_id" => "Y3JlYXRl",
        "session_options" => %{"version" => 1}
      })

    assert [%{"status" => "accepted", "session_id" => "c190ZXN0XzE"}] =
             receive_records(client, 1)

    session = @question_corpus["session_id"]
    assert session == "s_test_1"

    :ok =
      send_frame(client, %{
        "method" => "session.acquire_control",
        "request_id" => "acquire",
        "session_id" => "c190ZXN0XzE"
      })

    assert [%{"request_id" => "acquire", "result" => %{"writer_epoch" => epoch}}] =
             receive_records(client, 1)

    :ok =
      send_frame(client, %{
        "method" => "session.attach",
        "request_id" => "attach",
        "session_id" => "c190ZXN0XzE",
        "after_event_sequence" => "0"
      })

    assert [%{"type" => "snapshot"}] = receive_records(client, 1)
    %{attachment: %{pump: pump}} = :sys.get_state(connection)
    pump_monitor = Process.monitor(pump)

    try do
      :ok =
        send_frame(client, %{
          "method" => "session.prompt",
          "request_id" => "prompt",
          "command_id" => "cHJvbXB0",
          "content_b64" => "aW1wbGVtZW50",
          "writer_epoch" => epoch
        })

      opened_records =
        question_records_until(client, &question_event?(&1, "interaction.requested"))

      [%{"event" => %{"data" => opened}}] =
        question_events(opened_records, "interaction.requested")

      [pending] = question_rows(fixture, session, "model_question_requested_v1")

      expected_open = %{
        "interaction_id" => "bW9kZWwtcXVfOTg1MTc3NDJlOTM2NDczNWUyYWEwZmQzODIyZjU1",
        "run_id" => "cnVuXzlhNWJmMDFhYzdkNDUxNjE4NGNkNDhmZmIyOWRiNg",
        "turn" => "1",
        "tool_call_id" => "YXNrLTE",
        "producer" => "model_tool",
        "interaction_kind" => vector["interaction_request"]["kind"],
        "status" => "pending",
        "prompt" => vector["interaction_request"]["prompt"],
        "choices" => question_wire_choices(vector["interaction_request"]),
        "expires_at" => Integer.to_string(pending.payload["expires_at"]),
        "answer" => nil,
        "command_id" => nil,
        "command_digest" => nil,
        "disposition" => nil,
        "settlement_sequence" => nil
      }

      assert opened == expected_open
      assert pending.payload["interaction_id"] == @question_corpus["interaction_id"]
      assert pending.payload["run_id"] == @question_corpus["run_id"]
      assert pending.payload["tool_call_id"] == "ask-1"
      assert pending.payload["turn"] == @question_corpus["turn"]
      assert pending.payload["argument_digest"] == vector["argument_digest"]
      assert pending.payload["interaction_request"] == vector["interaction_request"]
      assert pending.payload["interaction_request_digest"] == vector["interaction_request_digest"]
      before_answer = Fixture.records(fixture, session)
      before_events = Fixture.events(fixture, session)

      request = %{
        "method" => "session.respond_interaction",
        "request_id" => "answer",
        "command_id" => "YW5zd2Vy",
        "interaction_id" => opened["interaction_id"],
        "answer" => question_wire_answer(vector["answer"]),
        "writer_epoch" => epoch
      }

      stale = request |> Map.put("request_id", "stale") |> Map.put("writer_epoch", "c3RhbGU")
      :ok = send_frame(client, stale)
      stale_records = question_records_until(client, &question_reply?(&1, "stale"))

      assert [%{"type" => "error", "code" => "control_not_held"}] =
               question_replies(stale_records, "stale")

      assert Fixture.records(fixture, session) == before_answer
      assert Fixture.events(fixture, session) == before_events

      malformed =
        request
        |> Map.put("request_id", "malformed")
        |> Map.put("answer", %{"text" => "ambiguous", "disposition" => "declined"})

      :ok = send_frame(client, malformed)
      malformed_records = question_records_until(client, &question_reply?(&1, "malformed"))

      assert [%{"type" => "error", "code" => "invalid_request"}] =
               question_replies(malformed_records, "malformed")

      assert Fixture.records(fixture, session) == before_answer
      assert Fixture.events(fixture, session) == before_events

      :ok = send_frame(client, request)

      settled_records =
        question_records_until(client, fn records ->
          question_reply?(records, "answer") and question_event?(records, "run.finished")
        end)

      [admitted] = question_replies(settled_records, "answer")

      assert admitted == %{
               "type" => "admission",
               "request_id" => "answer",
               "method" => "session.respond_interaction",
               "command_id" => "YW5zd2Vy",
               "status" => "accepted",
               "reason" => nil
             }

      [%{"event" => %{"data" => settled}}] =
        question_events(settled_records, "interaction." <> vector["disposition"])

      [response] = question_rows(fixture, session, "model_question_response_admitted_v2")

      assert response.payload == %{
               "command_type" => "interaction_answer",
               "admission" => "accepted",
               "command_id" => @question_corpus["command_id"],
               "command_digest" => vector["command_digest"],
               "interaction_id" => @question_corpus["interaction_id"],
               "answer" => vector["answer"],
               "disposition" => vector["disposition"],
               "responded_at" => response.payload["responded_at"],
               kind: "model_question_response_admitted_v2"
             }

      expected_terminal =
        expected_open
        |> Map.merge(%{
          "status" => vector["disposition"],
          "disposition" => vector["disposition"],
          "answer" => question_terminal_answer(request["answer"]),
          "command_id" => "YW5zd2Vy",
          "command_digest" => vector["command_digest"],
          "settlement_sequence" => Integer.to_string(response.journal_version)
        })
        |> question_terminal_choice(request["answer"])

      assert settled == expected_terminal
      assert response.payload["responded_at"] >= pending.payload["created_at"]
      assert response.payload["responded_at"] < pending.payload["expires_at"]
      [%{"event" => %{"data" => finished}}] = question_events(settled_records, "run.finished")
      assert finished["run_id"] == opened["run_id"]
      assert finished["outcome"] == "completed"

      records = Fixture.records(fixture, session)
      events = Fixture.events(fixture, session)

      [terminal_event] =
        Enum.filter(events, &(&1.kind == "interaction." <> vector["disposition"]))

      assert terminal_event["answer"] == question_native_terminal_answer(vector["answer"])
      assert terminal_event["interaction_id"] == @question_corpus["interaction_id"]
      assert terminal_event["run_id"] == @question_corpus["run_id"]
      assert terminal_event["tool_call_id"] == @question_corpus["tool_call_id"]
      assert terminal_event["command_id"] == @question_corpus["command_id"]
      assert terminal_event["command_digest"] == vector["command_digest"]
      assert terminal_event["settlement_sequence"] == response.journal_version
      assert {:ok, recovered} = Loopex.Runtime.SessionState.recover(session, records, events)
      assert recovered.open_interaction == nil
      terminal = recovered.interactions[@question_corpus["interaction_id"]]
      assert terminal.answer == vector["answer"]
      assert terminal.command_id == @question_corpus["command_id"]
      assert terminal.command_digest == vector["command_digest"]
      assert terminal.status == vector["disposition"]
      assert terminal.settlement_sequence == response.journal_version

      results =
        recovered
        |> Loopex.Runtime.SessionState.elements(@question_corpus["run_id"])
        |> Enum.filter(&(&1.kind == :tool_result))

      {outcome, content} = question_tool_result(vector["answer"])

      assert results == [
               %{
                 kind: :tool_result,
                 run_id: @question_corpus["run_id"],
                 turn_number: 1,
                 tool_call_id: "ask-1",
                 outcome: outcome,
                 content: content,
                 artifacts: []
               }
             ]

      [_first, second] = Loopex.AgentLoopTestModel.dispatched(fixture.model)
      [model_result] = Enum.filter(second.messages, &(&1["role"] == "tool"))
      [assistant] = Enum.filter(second.messages, &(&1["role"] == "assistant"))
      [call] = assistant["tool_calls"]
      assert call["tool_id"] == "loopex.ask"
      assert call["arguments"] == vector["arguments"]
      assert model_result["tool_call_id"] == call["tool_call_id"]
      assert model_result["content"] == content
      assert model_result["outcome"] == Atom.to_string(outcome)
      assert Loopex.AgentLoopTestExecutor.jobs(fixture.executor) == []

      :ok = send_frame(client, Map.put(request, "request_id", "retry"))
      retry_records = question_records_until(client, &question_reply?(&1, "retry"))
      assert question_replies(retry_records, "retry") == [%{admitted | "request_id" => "retry"}]
      assert Fixture.records(fixture, session) == records
      assert Fixture.events(fixture, session) == events
      assert length(Loopex.AgentLoopTestModel.dispatched(fixture.model)) == 2
    after
      :socket.close(client)
      assert_receive {:DOWN, ^pump_monitor, :process, ^pump, _reason}, 5_000
    end
  end

  defp question_wire_choices(%{"kind" => "text"}), do: []

  defp question_wire_choices(%{"kind" => "choice"}) do
    [
      %{"id" => "Y2hvaWNlLTE", "label" => "empty"},
      %{"id" => "Y2hvaWNlLTI", "label" => "literal_null"}
    ]
  end

  defp question_wire_answer(%{"choice_id" => "choice-2"}),
    do: %{"choice_id" => "Y2hvaWNlLTI"}

  defp question_wire_answer(answer), do: answer

  defp question_terminal_answer(%{"choice_id" => "Y2hvaWNlLTI"}),
    do: %{"choice_id" => "Y2hvaWNlLTI", "label" => "literal_null"}

  defp question_terminal_answer(answer), do: answer

  defp question_native_terminal_answer(%{"choice_id" => "choice-2"}),
    do: %{"choice_id" => "choice-2", "label" => "literal_null"}

  defp question_native_terminal_answer(answer), do: answer

  defp question_terminal_choice(terminal, %{"choice_id" => "Y2hvaWNlLTI"}),
    do: Map.put(terminal, "choice_id", "Y2hvaWNlLTI")

  defp question_terminal_choice(terminal, _answer), do: terminal

  defp question_tool_result(%{"text" => text}), do: {:completed, text}
  defp question_tool_result(%{"choice_id" => "choice-2"}), do: {:completed, "literal_null"}

  defp question_tool_result(%{"disposition" => "declined"}),
    do: {:denied, "The host refused this call: question_declined. Do not retry it."}

  defp question_rows(fixture, session, kind),
    do: fixture |> Fixture.records(session) |> Enum.filter(&(&1.payload.kind == kind))

  defp question_events(records, kind),
    do: Enum.filter(records, &(get_in(&1, ["event", "kind"]) == kind))

  defp question_event?(records, kind), do: question_events(records, kind) != []

  defp question_replies(records, request),
    do: Enum.filter(records, &(&1["request_id"] == request))

  defp question_reply?(records, request), do: question_replies(records, request) != []

  defp question_records_until(client, complete) do
    question_records_until(client, complete, System.monotonic_time(:millisecond) + 5_000, [])
  end

  defp question_records_until(client, complete, cutoff, records) do
    remaining = cutoff - System.monotonic_time(:millisecond)
    assert remaining > 0
    [record] = receive_records(client, 1, remaining)
    records = records ++ [record]
    assert System.monotonic_time(:millisecond) <= cutoff

    if complete.(records),
      do: records,
      else: question_records_until(client, complete, cutoff, records)
  end

  defp question_monitors(actors), do: Enum.map(actors, &{&1, Process.monitor(&1)})

  # Concept: a failed assertion still retires every original fixture actor.
  # Technical depth: attempt every stop before asserting any original DOWN;
  # all stops and joins spend one existing five-second observation bound.
  defp question_close_actors(actors) do
    cutoff = System.monotonic_time(:millisecond) + 5_000

    for {actor, _monitor} <- actors do
      try do
        if Process.alive?(actor) do
          GenServer.stop(actor, :normal, max(cutoff - System.monotonic_time(:millisecond), 0))
        end
      catch
        :exit, _reason -> :ok
      end
    end

    for {actor, monitor} <- actors do
      remaining = max(cutoff - System.monotonic_time(:millisecond), 0)
      assert_receive {:DOWN, ^monitor, :process, ^actor, _reason}, remaining
    end

    assert System.monotonic_time(:millisecond) <= cutoff
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
