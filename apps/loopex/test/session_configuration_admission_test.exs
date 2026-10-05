Code.require_file("support/configured_genesis_helper.exs", __DIR__)

defmodule Loopex.Runtime.SessionConfigurationAdmissionTest do
  use ExUnit.Case, async: true

  alias Loopex.ConfiguredGenesisFixture
  alias Loopex.Runtime.SessionConfiguration
  alias Loopex.Runtime.SessionState

  test "one row retains exact changes, advances one version and projects only public fields" do
    {state, records} = state()
    changes = %{"max_tokens" => 2_048}
    candidate = prepare(state, changes)
    command = %{type: :configure, command_id: "configure-1", changes: changes}

    assert {:ok, proposal} =
             SessionState.propose(state, command, %{configuration_candidate: candidate})

    assert proposal.reply == {:accepted, "configure-1"}
    assert [record] = proposal.records
    assert record.kind == "session_configuration_admitted_v2"
    assert record["prior_configuration_version"] == 1
    assert record["changes"] == changes
    assert record["configuration"] == candidate
    assert proposal.next.configuration == candidate
    assert [event] = proposal.events
    assert event.kind == "session.configured"
    assert event["configuration"] == SessionConfiguration.public_view(candidate)

    assert Map.keys(event["configuration"]) |> Enum.sort() ==
             Enum.sort(
               ~w(configuration_version model reasoning max_tokens context_token_budget system_class_tokens instructions)
             )

    assert event["configuration"]["instructions"] ==
             Map.take(candidate["instructions"], ~w(version digest))

    refute :erlang.term_to_binary(event) =~ candidate["instructions"]["base"]
    refute Map.has_key?(event["configuration"], "model_capabilities")
    refute Map.has_key?(event["configuration"], "provider_mapping")

    {committed, retained, events} = commit(state, proposal)
    assert {:ok, recovered} = SessionState.recover(state.session_id, records ++ retained, events)
    assert recovered.configuration == candidate

    assert {:replayed, {:accepted, "configure-1"}} =
             SessionState.propose(committed, command, %{configuration_candidate: %{}})

    assert {:error, :idempotency_conflict} =
             SessionState.propose(committed, %{command | changes: %{"max_tokens" => 512}})
  end

  test "missing preparation and invalid candidates retain one unchanged refusal" do
    {state, _records} = state()
    command = %{type: :configure, command_id: "configure", changes: %{"max_tokens" => 512}}

    for {resolved, reason} <- [
          {%{}, :configuration_not_prepared},
          {%{configuration_candidate: %{state.configuration | "max_tokens" => 512}},
           :invalid_session_configuration}
        ] do
      assert {:ok, proposal} = SessionState.propose(state, command, resolved)
      assert proposal.reply == {:error, reason}
      assert proposal.next.configuration == state.configuration
      assert proposal.events == []
      assert hd(proposal.records)["configuration"] == nil
      {committed, _, _} = commit(state, proposal)

      assert {:replayed, {:error, ^reason}} =
               SessionState.propose(committed, command, %{
                 configuration_candidate: prepare(state, command.changes)
               })
    end
  end

  test "private owner-busy and history-capacity refusals replay their original unchanged response" do
    {state, records} = state()
    command = %{type: :configure, command_id: "configure", changes: %{"max_tokens" => 512}}
    candidate = prepare(state, command.changes)

    for {resolution, admission, reason} <- [
          {%{configuration_candidate: candidate, configuration_owner_settled: false},
           "rejected_configuration_owner_busy", :configuration_not_settled},
          {%{configuration_candidate: candidate, configuration_preflight: :compaction_required},
           "rejected_configuration_compaction_required", :compaction_required}
        ] do
      assert {:ok, proposal} = SessionState.propose(state, command, resolution)
      assert proposal.reply == {:error, reason}
      assert proposal.next.configuration == state.configuration
      assert proposal.events == []
      assert hd(proposal.records)["admission"] == admission
      {committed, retained, []} = commit(state, proposal)
      assert {:ok, recovered} = SessionState.recover(state.session_id, records ++ retained, [])
      assert recovered.configuration == state.configuration

      assert {:replayed, {:error, ^reason}} =
               SessionState.propose(committed, command, %{
                 configuration_candidate: candidate,
                 configuration_owner_settled: true
               })
    end
  end

  test "large instruction changes retain one full copy and replay the exact authored preimage" do
    {state, records} = state()

    {:ok, instructions} =
      Loopex.Runtime.Instructions.capture(%{
        "version" => "host.large",
        "base" => String.duplicate("b", 32_768),
        "environment" => String.duplicate("e", 4_096),
        "appendix" => String.duplicate("a", 8_192)
      })

    changes = %{
      "instructions" => instructions,
      "context_token_budget" => 20_000,
      "system_class_tokens" => 16_000
    }

    candidate = prepare(state, changes)
    command = %{type: :configure, command_id: "large-instructions", changes: changes}

    assert {:ok, proposal} =
             SessionState.propose(state, command, %{configuration_candidate: candidate})

    assert proposal.reply == {:accepted, "large-instructions"}

    assert hd(proposal.records)["changes"]["instructions"] ==
             Map.take(instructions, ~w(version digest))

    assert hd(proposal.records)["configuration"]["instructions"] == instructions
    assert {:ok, _} = Loopex.Store.admit_bounded(hd(proposal.records))
    {committed, retained, events} = commit(state, proposal)
    assert {:ok, recovered} = SessionState.recover(state.session_id, records ++ retained, events)
    assert recovered.configuration["instructions"] == instructions

    assert {:replayed, {:accepted, "large-instructions"}} =
             SessionState.propose(committed, command)

    [row] = retained

    changed =
      put_in(row, [:payload, "changes", "instructions", "digest"], String.duplicate("0", 64))

    assert SessionState.recover(state.session_id, records ++ [changed], events) ==
             {:error, :invalid_configuration_transition}
  end

  test "active work, interactions, aborts and unresolved effects cannot be configured" do
    {state, _} = state()
    command = %{type: :configure, command_id: "configure", changes: %{"max_tokens" => 512}}
    candidate = prepare(state, command.changes)

    for unsettled <- [
          %{state | active_run_id: "run"},
          %{state | pending_work: %{"run" => %{stage: "model_pending"}}},
          %{state | open_interaction: "question"},
          %{state | aborting: %{run_id: "run"}},
          %{state | follow_up: %{command_id: "queued"}},
          %{state | context_refusal: %{}},
          %{state | conversation: %{"run" => [%{kind: :tool_result, outcome: :outcome_unknown}]}}
        ] do
      assert {:ok, proposal} =
               SessionState.propose(unsettled, command, %{configuration_candidate: candidate})

      assert proposal.reply == {:error, :configuration_not_settled}
      assert proposal.next.configuration == state.configuration
      assert proposal.events == []
    end
  end

  test "replay refuses a settled-only refusal category while a run is active" do
    {state, records} = state()

    assert {:ok, prompt} =
             SessionState.propose(
               state,
               %{type: :prompt, command_id: "prompt", content: "continue"},
               %{
                 max_turns: 8,
                 token_budget: 10_000,
                 deadline_ms: 60_000,
                 context_token_budget: 8_192
               }
             )

    {active, prompt_records, prompt_events} = commit(state, prompt)

    assert {:ok, refusal} =
             SessionState.propose(active, %{
               type: :configure,
               command_id: "configure",
               changes: %{"max_tokens" => 512}
             })

    assert refusal.reply == {:error, :configuration_not_settled}
    {_, [row], []} = commit(active, refusal)

    assert {:ok, _} =
             SessionState.recover(
               state.session_id,
               records ++ prompt_records ++ [row],
               prompt_events
             )

    for admission <- [
          "rejected_configuration_not_prepared",
          "rejected_invalid_session_configuration"
        ] do
      changed = put_in(row, [:payload, "admission"], admission)

      assert SessionState.recover(
               state.session_id,
               records ++ prompt_records ++ [changed],
               prompt_events
             ) == {:error, :invalid_configuration_transition}
    end
  end

  test "replay refuses substituted version, authored changes, digest, candidate and extra fields" do
    {state, records} = state()
    command = %{type: :configure, command_id: "configure", changes: %{"max_tokens" => 512}}

    assert {:ok, proposal} =
             SessionState.propose(state, command, %{
               configuration_candidate: prepare(state, command.changes)
             })

    {_, [retained], events} = commit(state, proposal)

    for changed <- [
          put_in(retained, [:payload, "prior_configuration_version"], 2),
          put_in(retained, [:payload, "changes", "max_tokens"], 256),
          put_in(retained, [:payload, "command_digest"], String.duplicate("0", 64)),
          put_in(retained, [:payload, "configuration", "configuration_version"], 3),
          put_in(retained, [:payload, "configuration", "context_token_budget"], 1_024),
          put_in(retained, [:payload, "configuration", "extra"], true),
          put_in(retained, [:payload, "extra"], true)
        ] do
      assert SessionState.recover(state.session_id, records ++ [changed], events) ==
               {:error, :invalid_configuration_transition}
    end
  end

  test "later prompt admission captures the new version without changing an earlier run capture" do
    {state, _} = state()
    earlier = state.configuration
    state = %{state | run_configurations: %{"earlier" => earlier}}
    changes = %{"max_tokens" => 512}

    assert {:ok, configure} =
             SessionState.propose(
               state,
               %{type: :configure, command_id: "configure", changes: changes},
               %{configuration_candidate: prepare(state, changes)}
             )

    {committed, _, _} = commit(state, configure)
    assert SessionState.run_configuration(committed, "earlier") == earlier

    assert {:ok, prompt} =
             SessionState.propose(
               committed,
               %{type: :prompt, command_id: "next", content: "continue"},
               %{
                 max_turns: 8,
                 token_budget: 10_000,
                 deadline_ms: 60_000,
                 context_token_budget: committed.configuration["context_token_budget"]
               }
             )

    run = hd(prompt.records)["run_id"]
    assert SessionState.run_configuration(prompt.next, run) == committed.configuration
    assert SessionState.run_configuration(prompt.next, "earlier") == earlier
  end

  test "configure cannot author internal facts or exploit mixed top-level spellings" do
    {state, _} = state()

    for command <- [
          %{type: :configure, command_id: "configure", changes: %{}},
          %{type: :configure, command_id: "configure", changes: %{"configuration_version" => 2}},
          %{
            type: :configure,
            command_id: "configure",
            changes: %{"max_tokens" => 512},
            configuration_candidate: state.configuration
          },
          %{
            :type => :configure,
            "type" => "configure",
            :command_id => "configure",
            :changes => %{"max_tokens" => 512}
          }
        ] do
      assert SessionState.propose(state, command) == {:error, :invalid_command}
    end

    assert SessionConfiguration.public_view(nil) == nil
  end

  test "v2 binds authored alias to canonical candidate and keeps its independent digest preimage" do
    {state, history} = state()
    authored = %{"model" => "host-alias"}
    command = %{type: :configure, command_id: "alias-vector", changes: authored}
    candidate = prepare(state, %{"model" => state.configuration["model"]})

    # Concept: alias identity is independent of the retained canonical spelling.
    # Technical depth: this literal ETF and SHA-256 vector was encoded separately
    # from the reducer. Substituting the canonical model changes the preimage.
    bytes =
      Base.decode64!(
        "g2wAAAACbQAAABFsb29wZXhfY29tbWFuZF92MXQAAAADdwdjaGFuZ2VzdAAAAAFtAAAABW1vZGVsbQAAAApob3N0LWFsaWFzdwpjb21tYW5kX2lkbQAAAAxhbGlhcy12ZWN0b3J3BHR5cGV3CWNvbmZpZ3VyZWo="
      )

    assert :erlang.term_to_binary(["loopex_command_v1", command], [:deterministic]) == bytes

    assert {:ok, proposal} =
             SessionState.propose(state, command, %{configuration_candidate: candidate})

    assert proposal.reply == {:accepted, command.command_id}
    assert [record] = proposal.records
    assert map_size(record) == 8
    assert record.kind == "session_configuration_admitted_v2"
    assert record["changes"] == authored
    assert record["configuration"]["model"] == "scripted:v1"

    assert record["command_digest"] ==
             "9c0ee5fd98c16fd2d070f504eaeb252bfd614aa8c529aeed7e07cb3f676c692e"

    {committed, rows, events} = commit(state, proposal)
    assert {:ok, recovered} = SessionState.recover(state.session_id, history ++ rows, events)
    assert recovered.configuration == candidate
    assert {:replayed, {:accepted, "alias-vector"}} = SessionState.propose(recovered, command)

    assert {:replayed, {:accepted, "alias-vector"}} =
             SessionState.propose(committed, command, %{configuration_candidate: %{}})

    assert {:error, :idempotency_conflict} =
             SessionState.propose(
               committed,
               %{command | changes: %{"model" => candidate["model"]}}
             )

    [row] = rows
    superseded = put_in(row, [:payload, :kind], "session_configuration_admitted_v1")
    assert {:error, _} = SessionState.recover(state.session_id, history ++ [superseded], events)
  end

  test "alias binding cannot rewrite other authored settings or retarget an omitted model" do
    {state, _} = state()
    current = state.configuration
    alias_changes = %{"model" => "host-alias", "max_tokens" => 512}
    substituted = prepare(state, %{"model" => current["model"], "max_tokens" => 768})

    assert {:error, :invalid_configuration_transition} =
             SessionConfiguration.validate_candidate(current, alias_changes, substituted, [])

    capabilities = Map.put(current["model_capabilities"], "model", "scripted:v2")

    assert {:ok, retargeted} =
             SessionConfiguration.update(
               current,
               %{"model" => "scripted:v2", "max_tokens" => 512},
               capabilities,
               current["provider_mapping"],
               []
             )

    assert {:error, :invalid_configuration_transition} =
             SessionConfiguration.validate_candidate(
               current,
               %{"max_tokens" => 512},
               retargeted,
               []
             )

    assert :ok = SessionConfiguration.validate_candidate(current, alias_changes, retargeted, [])

    command = %{type: :configure, command_id: "retarget", changes: %{"max_tokens" => 512}}

    assert {:ok, rejected} =
             SessionState.propose(state, command, %{configuration_candidate: retargeted})

    assert rejected.reply == {:error, :invalid_session_configuration}
    assert rejected.next.configuration == current
  end

  test "fresh preparation gate checks retained disposition and settledness before host resolution" do
    {state, history} = state()

    command = %{
      type: :configure,
      command_id: "alias-refused",
      changes: %{"model" => "host-alias"}
    }

    assert {:new, ^command} = SessionState.prepare_configuration_command(state, command, true)
    assert {:ok, refused} = SessionState.propose(state, command)
    {committed, rows, events} = commit(state, refused)
    assert {:ok, recovered} = SessionState.recover(state.session_id, history ++ rows, events)

    assert {:replayed, {:error, :configuration_not_prepared}} =
             SessionState.prepare_configuration_command(recovered, command, true)

    assert {:error, :idempotency_conflict} =
             SessionState.prepare_configuration_command(
               committed,
               %{command | changes: %{"model" => "scripted:v1"}},
               true
             )

    assert {:ok, busy} = SessionState.prepare_configuration_command(state, command, false)
    assert busy.reply == {:error, :configuration_not_settled}

    assert {:ok, active} =
             SessionState.prepare_configuration_command(
               %{state | active_run_id: "run"},
               command,
               true
             )

    assert active.reply == {:error, :configuration_not_settled}
  end

  defp state do
    genesis = ConfiguredGenesisFixture.genesis([])

    records = [
      %{journal_version: 1, owner_epoch: 0, owner_incarnation_id: nil, payload: genesis},
      %{
        journal_version: 2,
        owner_epoch: 1,
        owner_incarnation_id: "owner",
        payload: %{
          "prior_owner_epoch" => 0,
          "owner_epoch" => 1,
          "owner_incarnation_id" => "owner",
          "owner_transaction_id" => "owner-tx",
          kind: "owner_advanced"
        }
      }
    ]

    {:ok, state} = SessionState.recover("configuration-session", records, [])
    {state, records}
  end

  defp prepare(state, changes) do
    current = state.configuration

    {:ok, candidate} =
      SessionConfiguration.update(
        current,
        changes,
        current["model_capabilities"],
        current["provider_mapping"],
        state.tool_selection["definitions"]
      )

    candidate
  end

  defp commit(state, proposal) do
    records =
      Enum.with_index(proposal.records, state.journal_version + 1)
      |> Enum.map(fn {payload, version} ->
        %{
          payload: payload,
          journal_version: version,
          owner_epoch: state.owner_epoch,
          owner_incarnation_id: state.owner_incarnation_id
        }
      end)

    events =
      Enum.with_index(proposal.events, state.event_sequence + 1)
      |> Enum.map(fn {event, sequence} -> Map.put(event, :event_sequence, sequence) end)

    receipt = %{
      journal_versions: %{
        first: state.journal_version + 1,
        last: state.journal_version + length(records)
      },
      event_sequences:
        if(events == [],
          do: nil,
          else: %{first: state.event_sequence + 1, last: state.event_sequence + length(events)}
        )
    }

    {:ok, committed} = SessionState.commit_proposal(proposal, receipt)
    {committed, records, events}
  end
end
