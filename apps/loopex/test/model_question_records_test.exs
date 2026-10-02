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

      assert {:ok, state} = SessionState.recover(session, records, events)
      assert state.open_interaction == @vectors["interaction_id"]

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
      await_event(attachment, "run.finished")
      records = Fixture.records(fixture, session)
      events = Fixture.events(fixture, session)

      response_row =
        Enum.find(records, &(&1.payload.kind == "model_question_response_admitted_v1"))

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
               kind: "model_question_response_admitted_v1"
             }

      assert response["responded_at"] >= pending["created_at"]
      assert response["responded_at"] < pending["expires_at"]
      assert_closed_record(session, records, events, response_row)

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
