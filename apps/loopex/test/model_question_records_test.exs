Code.require_file("support/m1_runtime_helper.exs", __DIR__)
Code.require_file("support/agent_loop_helper.exs", __DIR__)
Code.require_file("support/configured_genesis_helper.exs", __DIR__)

defmodule Loopex.ModelQuestionRecordsTest do
  use ExUnit.Case, async: false

  alias Loopex.AgentLoopFixture, as: Fixture
  alias Loopex.Interaction
  alias Loopex.Runtime
  alias Loopex.Runtime.SessionState
  alias LoopexProtocol.ToolDefinition

  # Concept: retained questions bind the exact original request and response.
  # Technical depth: these literal preimages and digests were computed from
  # manually authored plain terms with stdlib ETF/SHA, without calling product
  # encoders. Actual owner clocks stay captured, rather than being substituted
  # with impossible timestamps in a live journal.
  @vectors Path.expand("../priv/vectors/model_question.v1.json", __DIR__)
           |> File.read!()
           |> JSON.decode!()

  @event_schema :loopex_protocol
                |> :code.priv_dir()
                |> Path.join("schema/model-question-events.v1.json")
                |> File.read!()
                |> JSON.decode!()

  for vector <- @vectors["vectors"] do
    @vector vector

    test "#{vector["name"]} records preserve literal bindings and reject altered replay" do
      vector = @vector

      fixture =
        Fixture.start(
          tools: [ToolDefinition.question_definition()],
          script: [
            %{
              text: "question",
              calls: [%{id: "ask-1", name: "ask", arguments: vector["arguments"]}]
            },
            %{text: "done", calls: []}
          ]
        )

      on_exit(fn -> Fixture.stop(fixture) end)

      assert {:ok, session} =
               Runtime.create_session_with_genesis(
                 fixture.runtime,
                 "create",
                 %{},
                 Loopex.ConfiguredGenesisFixture.genesis(fixture.definitions)
               )

      assert session == @vectors["session_id"]
      assert {:ok, attachment} = Loopex.attach(fixture.runtime, session, after_event_sequence: 0)

      assert {:accepted, "prompt"} =
               Loopex.command(attachment, %{
                 type: :prompt,
                 command_id: "prompt",
                 content: "implement"
               })

      requested = await_event(attachment, "interaction.requested")
      records = Fixture.records(fixture, session)
      events = Fixture.events(fixture, session)
      pending_row = Enum.find(records, &(&1.payload.kind == "model_question_requested_v1"))
      pending = pending_row.payload

      assert @event_schema["runtime_exact_fields"] ==
               ~w(answer choices command_digest command_id disposition event_id event_sequence expires_at interaction_id interaction_kind kind producer prompt run_id settlement_sequence status tool_call_id turn)

      assert_model_question_event(requested, vector, pending, "pending")

      expected_open =
        requested
        |> Map.take(
          ~w(interaction_id run_id turn tool_call_id prompt choices expires_at producer)
        )
        |> Map.put("status", "pending")
        |> Map.put("kind", requested["interaction_kind"])

      assert {:ok, pending_attachment} =
               Loopex.attach(fixture.runtime, session,
                 after_event_sequence: requested.event_sequence
               )

      assert pending_attachment.open_interaction == expected_open
      pending_snapshot = Loopex.snapshot(pending_attachment)
      assert pending_snapshot.snapshot_revision == 3
      assert pending_snapshot.open_interaction == expected_open
      assert pending_snapshot.event_sequence == requested.event_sequence
      assert {:ok, pending_wire} = LoopexProtocol.Session.Snapshot.encode_wire(pending_snapshot)
      assert {:ok, ^pending_snapshot} = LoopexProtocol.Session.Snapshot.decode_wire(pending_wire)
      assert expected_open["producer"] == "model_tool"
      assert expected_open["kind"] == vector["interaction_request"]["kind"]

      assert {:ok, state} = SessionState.recover(session, records, events)
      assert state.open_interaction == @vectors["interaction_id"]

      {:ok, expiry} =
        SessionState.propose_model_question_expiry(
          state,
          state.open_interaction,
          pending["expires_at"]
        )

      [expiry_payload] = expiry.records
      assert expiry_payload.kind == "model_question_settled_v2"

      historical_expiry = %{
        journal_version: state.journal_version + 1,
        owner_epoch: state.owner_epoch,
        owner_incarnation_id: state.owner_incarnation_id,
        payload: %{expiry_payload | kind: "model_question_settled_v1"}
      }

      expiry_events =
        expiry.events
        |> Enum.with_index(state.event_sequence + 1)
        |> Enum.map(fn {event, sequence} ->
          Map.put(event, :event_sequence, sequence)
        end)

      assert_model_question_event(
        Enum.find(expiry_events, &(&1.kind == "interaction.expired")),
        vector,
        pending,
        "expired"
      )

      assert {:error, _} =
               SessionState.recover(
                 session,
                 records ++ [historical_expiry],
                 events ++ expiry_events
               )

      assert pending == %{
               "producer" => "model_tool",
               "interaction_id" => @vectors["interaction_id"],
               "run_id" => @vectors["run_id"],
               "turn" => @vectors["turn"],
               "tool_call_id" => @vectors["tool_call_id"],
               "argument_digest" => vector["argument_digest"],
               "interaction_request" => vector["interaction_request"],
               "interaction_request_digest" => vector["interaction_request_digest"],
               "created_at" => pending["created_at"],
               "expires_at" => pending["expires_at"],
               kind: "model_question_requested_v1"
             }

      assert is_integer(pending["created_at"]) and pending["created_at"] >= 0

      assert pending["expires_at"] ==
               min(pending["created_at"] + 600_000, state.deadlines[@vectors["run_id"]])

      assert_preimage(vector, "argument", vector["arguments"])
      assert {:ok, request} = Interaction.model_request(vector["arguments"])
      assert_preimage(vector, "interaction_request", request)
      assert Interaction.digest(vector["arguments"]) == vector["argument_digest"]
      assert Interaction.digest(request) == vector["interaction_request_digest"]

      # Every retained member is required. Dropping one while adding an unknown
      # member also refuses, so cardinality alone cannot prove a closed shape.
      assert_closed_record(session, records, events, pending_row)

      for {field, value} <- [
            {"producer", "policy_defer"},
            {"run_id", "other-run"},
            {"turn", 2},
            {"tool_call_id", "other-call"},
            {"interaction_id", "other-question"},
            {"argument_digest", String.duplicate("0", 64)},
            {"interaction_request_digest", String.duplicate("0", 64)},
            {"interaction_request", Map.put(vector["interaction_request"], "prompt", "changed")},
            {"created_at", -1},
            {"created_at", 18_446_744_073_709_551_616},
            {"expires_at", pending["created_at"]},
            {"expires_at", pending["expires_at"] + 1}
          ] do
        assert_refused(session, records, events, pending_row, Map.put(pending, field, value))
      end

      forged_request = %{request | prompt: "another prompt"}

      forged_pending =
        pending
        |> Map.put("interaction_request", Interaction.to_record(forged_request))
        |> Map.put("interaction_request_digest", Interaction.digest(forged_request))

      assert_refused(session, records, events, pending_row, forged_pending)

      command = %{
        type: :interaction_answer,
        command_id: @vectors["command_id"],
        interaction_id: @vectors["interaction_id"],
        answer: vector["answer"]
      }

      normalized =
        if vector["answer"]["choice_id"],
          do:
            command |> Map.delete(:answer) |> Map.put(:choice_id, vector["answer"]["choice_id"]),
          else: command

      assert_preimage(vector, "command", ["loopex_command_v1", normalized])
      assert {:accepted, "answer"} = Loopex.command(attachment, command)
      settled = await_event(attachment, "interaction." <> vector["disposition"])
      assert_model_question_event(settled, vector, pending, vector["disposition"])
      await_event(attachment, "run.finished")
      records = Fixture.records(fixture, session)
      events = Fixture.events(fixture, session)

      assert {:ok, historical_attachment} =
               Loopex.attach(fixture.runtime, session,
                 after_event_sequence: requested.event_sequence
               )

      assert historical_attachment.open_interaction == expected_open
      assert Loopex.snapshot(historical_attachment) == pending_snapshot

      assert {:ok, settled_attachment} =
               Loopex.attach(fixture.runtime, session,
                 after_event_sequence: settled.event_sequence
               )

      assert settled_attachment.open_interaction == nil
      assert Loopex.snapshot(settled_attachment).open_interaction == nil

      response_row =
        Enum.find(records, &(&1.payload.kind == "model_question_response_admitted_v2"))

      response = response_row.payload

      assert response == %{
               "command_type" => "interaction_answer",
               "admission" => "accepted",
               "command_id" => @vectors["command_id"],
               "command_digest" => vector["command_digest"],
               "interaction_id" => @vectors["interaction_id"],
               "answer" => vector["answer"],
               "disposition" => vector["disposition"],
               "responded_at" => response["responded_at"],
               kind: "model_question_response_admitted_v2"
             }

      assert response["responded_at"] >= pending["created_at"]
      assert response["responded_at"] < pending["expires_at"]
      assert_closed_record(session, records, events, response_row)

      historical_rows =
        records
        |> Enum.take_while(&(&1.journal_version <= response_row.journal_version))
        |> List.update_at(
          -1,
          &put_in(&1, [:payload, :kind], "model_question_response_admitted_v1")
        )

      historical_events =
        events
        |> Enum.take_while(&(&1.event_sequence <= settled.event_sequence))

      assert {:error, _} =
               SessionState.recover(session, historical_rows, historical_events)

      for {field, value} <- [
            {"command_type", "prompt"},
            {"admission", "rejected"},
            {"command_id", "prompt"},
            {"command_digest", String.duplicate("0", 64)},
            {"interaction_id", "other-question"},
            {"disposition", "expired"},
            {"disposition",
             if(vector["disposition"] == "declined", do: "answered", else: "declined")},
            {"answer", %{"text" => "changed"}},
            {"answer", %{"disposition" => "declined", "text" => "ambiguous"}},
            {"responded_at", pending["created_at"] - 1},
            {"responded_at", pending["expires_at"]},
            {"responded_at", "not-an-instant"}
          ] do
        assert_refused(session, records, events, response_row, Map.put(response, field, value))
      end

      # A matching digest is necessary but does not make an unoffered branch
      # answerable. Deliberately forge a consistent command binding here.
      for answer <- [%{"choice_id" => "choice-9"}, %{"text" => ""}, %{"text" => <<255>>}] do
        normalized =
          if answer["choice_id"],
            do: command |> Map.delete(:answer) |> Map.put(:choice_id, answer["choice_id"]),
            else: %{command | answer: answer}

        digest =
          :crypto.hash(
            :sha256,
            :erlang.term_to_binary(["loopex_command_v1", normalized], [:deterministic])
          )
          |> Base.encode16(case: :lower)

        changed = response |> Map.put("answer", answer) |> Map.put("command_digest", digest)
        assert_refused(session, records, events, response_row, changed)
      end

      assert {:ok, recovered} = SessionState.recover(session, records, events)
      assert is_nil(recovered.open_interaction)
      terminal = recovered.interactions[@vectors["interaction_id"]]
      assert terminal.status == vector["disposition"]
      assert terminal.answer == vector["answer"]
      assert terminal.command_digest == vector["command_digest"]
      assert terminal.settlement_sequence == response_row.journal_version
      assert requested["interaction_id"] == settled["interaction_id"]
      assert settled["command_digest"] == vector["command_digest"]
      assert settled["settlement_sequence"] == response_row.journal_version
      assert Agent.get(fixture.executor, & &1.jobs) == []
    end
  end

  test "live abort cancellation preserves terminal payload evidence and joins its fixture" do
    fixture =
      Fixture.start(
        tools: [ToolDefinition.question_definition()],
        script: [
          %{
            text: "question",
            calls: [%{id: "ask-1", name: "ask", arguments: %{"question" => "Explain"}}]
          },
          %{text: "must not dispatch", calls: []}
        ]
      )

    owned =
      Enum.map(
        [fixture.runtime.supervisor, fixture.model, fixture.executor, fixture.store],
        &{&1, Process.monitor(&1)}
      )

    on_exit(fn ->
      Fixture.stop(fixture)

      for pid <- [fixture.model, fixture.executor] do
        try do
          GenServer.stop(pid, :normal, 1_000)
        catch
          :exit, _ -> :ok
        end
      end
    end)

    assert {:ok, session} =
             Runtime.create_session_with_genesis(
               fixture.runtime,
               "create",
               %{},
               Loopex.ConfiguredGenesisFixture.genesis(fixture.definitions)
             )

    assert {:ok, attachment} = Loopex.attach(fixture.runtime, session, after_event_sequence: 0)

    assert {:accepted, "prompt"} =
             Loopex.command(attachment, %{
               type: :prompt,
               command_id: "prompt",
               content: "implement"
             })

    requested = await_event(attachment, "interaction.requested")
    abort_command = %{type: :abort, command_id: "abort"}
    assert {:accepted, "abort"} = Loopex.command(attachment, abort_command)
    terminal = await_event(attachment, "interaction.cancelled")
    assert_terminal_codec(terminal)
    finished = await_event(attachment, "run.finished")
    assert finished["outcome"] == "cancelled"
    assert terminal["interaction_id"] == requested["interaction_id"]
    records = Fixture.records(fixture, session)
    events = Fixture.events(fixture, session)

    assert [abort_row] =
             Enum.filter(records, &(&1.payload.kind == "model_question_abort_admitted_v2"))

    abort = abort_row.payload

    expected_digest =
      :crypto.hash(
        :sha256,
        :erlang.term_to_binary(["loopex_command_v1", abort_command], [:deterministic])
      )
      |> Base.encode16(case: :lower)

    assert abort["command_type"] == "abort"
    assert abort["admission"] == "accepted"
    assert abort["command_id"] == abort_command.command_id
    assert abort["command_digest"] == expected_digest
    assert abort["run_id"] == requested["run_id"]
    assert terminal["run_id"] == abort["run_id"]
    assert terminal["command_id"] == "abort"
    assert terminal["command_digest"] == abort["command_digest"]
    assert terminal["answer"] == nil
    assert terminal["settlement_sequence"] == abort_row.journal_version

    assert {:ok, recovered} = SessionState.recover(session, records, events)
    assert recovered.interactions[terminal["interaction_id"]].command_id == "abort"

    assert recovered.interactions[terminal["interaction_id"]].command_digest ==
             abort["command_digest"]

    assert recovered.interactions[terminal["interaction_id"]].status == "cancelled"

    assert recovered.interactions[terminal["interaction_id"]].settlement_sequence ==
             terminal["settlement_sequence"]

    assert recovered.open_interaction == nil
    assert recovered.active_run_id == nil
    assert :ok = Loopex.stop(fixture.runtime)
    [{runtime, runtime_monitor} | adapters] = owned
    assert_receive {:DOWN, ^runtime_monitor, :process, ^runtime, :normal}, 1_000
    model_calls = Loopex.AgentLoopTestModel.dispatched(fixture.model)
    executor_jobs = Agent.get(fixture.executor, & &1.jobs)

    for {pid, monitor} <- adapters do
      assert :ok = GenServer.stop(pid, :normal, 1_000)
      assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 1_000
    end

    assert length(model_calls) == 1
    assert executor_jobs == []
  end

  defp assert_terminal_codec(event) do
    data = Map.drop(event, [:kind, :event_id, :event_sequence])
    assert {:ok, wire} = LoopexProtocol.Session.ModelQuestionEvent.encode_terminal(data)
    assert {:ok, ^data} = LoopexProtocol.Session.ModelQuestionEvent.decode_terminal(wire)
    assert event.kind == @event_schema["terminal"]["kind_by_disposition"][data["disposition"]]
  end

  defp assert_model_question_event(event, vector, pending, status) do
    fields =
      if status == "answered" and Map.has_key?(vector["answer"], "choice_id"),
        do:
          Enum.sort(
            @event_schema["runtime_exact_fields"] ++
              [@event_schema["terminal"]["choice_only_additional_field"]]
          ),
        else: @event_schema["runtime_exact_fields"]

    assert Enum.sort(Enum.map(Map.keys(event), &to_string/1)) == fields

    assert event["producer"] == "model_tool"
    assert event["interaction_id"] == @vectors["interaction_id"]
    assert event["run_id"] == @vectors["run_id"]
    assert event["turn"] == @vectors["turn"]
    assert event["tool_call_id"] == @vectors["tool_call_id"]
    assert event["interaction_kind"] == vector["interaction_request"]["kind"]
    assert event["prompt"] == vector["interaction_request"]["prompt"]
    assert event["choices"] == vector["interaction_request"]["choices"]
    assert event["expires_at"] == pending["expires_at"]
    assert event["status"] == status
    assert is_binary(event.event_id) and byte_size(event.event_id) in 1..256
    assert is_integer(event.event_sequence) and event.event_sequence > 0

    case status do
      "pending" ->
        assert event.kind == @event_schema["pending"]["kind"]
        assert Enum.all?(@event_schema["pending"]["null_fields"], &is_nil(event[&1]))

      disposition ->
        assert event.kind == @event_schema["terminal"]["kind_by_disposition"][disposition]
        assert event["disposition"] == disposition
        assert_terminal_codec(event)

        assert is_integer(event["settlement_sequence"]) and
                 event["settlement_sequence"] > 0

        if disposition == "expired" do
          assert event["command_id"] == nil
          assert event["command_digest"] == nil
          assert event["answer"] == nil
        else
          assert event["command_id"] == @vectors["command_id"]
          assert event["command_digest"] == vector["command_digest"]

          expected_answer =
            case vector["answer"] do
              %{"choice_id" => id} ->
                choice = Enum.find(event["choices"], &(&1["id"] == id))
                assert event["choice_id"] == id
                %{"choice_id" => id, "label" => choice["label"]}

              answer ->
                answer
            end

          assert event["answer"] == expected_answer
        end
    end

    refute Map.has_key?(event, "decision_ref")
    refute Map.has_key?(event, "policy_request")
    refute Map.has_key?(event, "provider_mapping")
    refute Map.has_key?(event, "credential_ref")
  end

  defp assert_preimage(vector, name, term) do
    bytes = Base.decode64!(vector[name <> "_preimage_base64"])
    assert :erlang.term_to_binary(term, [:deterministic]) == bytes

    assert :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower) ==
             vector[name <> "_digest"]
  end

  defp assert_closed_record(session, records, events, row) do
    for key <- Map.keys(row.payload) do
      missing = Map.delete(row.payload, key)
      assert_refused(session, records, events, row, missing)
      assert_refused(session, records, events, row, Map.put(missing, "unknown", nil))
      assert_refused(session, records, events, row, Map.put(row.payload, key, nil))
    end

    assert_refused(session, records, events, row, Map.put(row.payload, "unknown", nil))
  end

  defp assert_refused(session, records, events, original, payload) do
    changed = Enum.map(records, &if(&1 == original, do: %{&1 | payload: payload}, else: &1))
    assert {:error, _} = SessionState.recover(session, changed, events), inspect(payload)
  end

  defp await_event(attachment, kind, cutoff \\ nil) do
    cutoff = cutoff || System.monotonic_time(:millisecond) + 5_000

    case Loopex.next_event(attachment) do
      {:ok, %{kind: ^kind} = event} ->
        event

      _ ->
        assert System.monotonic_time(:millisecond) < cutoff, "missing #{kind}"
        Process.sleep(10)
        await_event(attachment, kind, cutoff)
    end
  end
end
