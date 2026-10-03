Code.require_file("support/configured_genesis_helper.exs", __DIR__)

defmodule Loopex.Runtime.MaintenanceEpisodeAdmissionTest do
  use ExUnit.Case, async: true

  alias Loopex.ConfiguredGenesisFixture
  alias Loopex.Runtime.{MaintenanceConfiguration, SessionState}
  alias LoopexProtocol.Canonical

  @uint64_max 18_446_744_073_709_551_615

  test "admission freezes the parent, summarizer and fixed preparation clock without dispatch" do
    {state, history, events} = run_state()
    assert {:ok, proposal} = admit(state, 1_000)
    assert [row] = proposal.records
    assert proposal.events == []
    assert row.kind == "maintenance_episode_admitted_v1"
    assert row["preparation_deadline"] == 61_000

    assert row["bounds"] == %{
             "max_attempts" => 4,
             "max_turns" => 8,
             "token_budget" => 10_000,
             "deadline_ms" => 60_000,
             "run_deadline" => nil
           }

    assert row["configuration_version"] == 1
    assert row["trigger"] == "ordinary_limit"
    assert row["origin"] == "automatic"
    assert row["attempts"] == 0
    assert row["summary_ordinal"] == 1
    assert row["usage"]["total_tokens"] == 0
    assert row["checkpoint_id"] == nil
    assert proposal.next.pending_work == state.pending_work
    assert proposal.next.charged == state.charged
    assert proposal.next.conversation == state.conversation
    assert proposal.next.deadlines == state.deadlines
    assert {:ok, _} = Loopex.Store.admit_bounded(row)

    {committed, rows} = commit(state, proposal)
    assert {:ok, recovered} = SessionState.recover(state.session_id, history ++ rows, events)
    assert recovered.maintenance_episodes == committed.maintenance_episodes
    assert recovered.active_maintenance == row["episode_id"]

    assert {:retained, episode} =
             SessionState.propose_maintenance_episode(
               recovered,
               recovered.active_run_id,
               nil,
               nil,
               @uint64_max
             )

    assert episode["preparation_deadline"] == 61_000
    assert episode["maintenance_configuration"] == row["maintenance_configuration"]
    assert episode["stage"] == "source_preparation"

    assert {:error, :maintenance_active} =
             SessionState.preflight_model_request(recovered, recovered.active_run_id, %{})
  end

  test "input cap and both origins are independently derived from the retained parent" do
    parent = ConfiguredGenesisFixture.configuration()

    for {window, parent_cap, expected, origin} <- [
          {16_384, 8_192, 8_192, "model_window"},
          {2_048, 8_192, 1_024, "model_window"},
          {nil, 10_000, 8_192, "unknown_window"},
          {nil, 2_000, 2_000, "unknown_window"}
        ] do
      selection = put_in(model(), ["model_capabilities", "context_window"], window)
      parent = %{parent | "context_token_budget" => parent_cap}
      assert {:ok, capture} = MaintenanceConfiguration.capture(selection, instructions(), parent)
      assert capture["context_token_budget"] == expected
      assert capture["system_class_tokens"] == parent["system_class_tokens"]
      assert capture["budget_origins"]["parent"] == parent["budget_origins"]
      assert capture["budget_origins"]["summarizer"] == origin
      assert capture["digest"] == digest(Map.delete(capture, "digest"))
      assert :ok == MaintenanceConfiguration.validate_capture(capture, parent)

      changed = %{capture | "context_token_budget" => expected + 1}
      changed = %{changed | "digest" => digest(Map.delete(changed, "digest"))}

      assert {:error, :invalid_maintenance_configuration} ==
               MaintenanceConfiguration.validate_capture(changed, parent)
    end
  end

  test "owner succession retains the admission clock and frozen host capture" do
    {state, history, events} = run_state()
    {:ok, proposal} = admit(state, 1_000)
    {committed, rows} = commit(state, proposal)

    succession = %{
      journal_version: committed.journal_version + 1,
      owner_epoch: 2,
      owner_incarnation_id: "successor",
      payload: %{
        :kind => "owner_advanced",
        "prior_owner_epoch" => 1,
        "owner_epoch" => 2,
        "owner_incarnation_id" => "successor",
        "owner_transaction_id" => "successor-tx"
      }
    }

    assert {:ok, recovered} =
             SessionState.recover(state.session_id, history ++ rows ++ [succession], events)

    assert recovered.owner_epoch == 2

    assert {:retained, episode} =
             SessionState.propose_maintenance_episode(
               recovered,
               recovered.active_run_id,
               nil,
               nil,
               1_000_000
             )

    assert episode["admitted_at"] == 1_000
    assert episode["preparation_deadline"] == 61_000

    assert episode["maintenance_configuration"] ==
             hd(proposal.records)["maintenance_configuration"]

    assert recovered.deadlines == %{}
  end

  test "a run terminal cannot orphan an admitted maintenance episode" do
    {state, history, events} = run_state()
    run = state.active_run_id
    detail = %{reason: "model_call_failed"}

    assert {:ok, ordinary_terminal} =
             SessionState.propose_run_terminal(state, run, "failed", detail)

    {:ok, admission} = admit(state, 1_000)
    {committed, rows} = commit(state, admission)

    assert {:error, :invalid_maintenance_episode_transition} ==
             SessionState.propose_run_terminal(committed, run, "failed", detail)

    terminal_row = %{
      journal_version: committed.journal_version + 1,
      owner_epoch: committed.owner_epoch,
      owner_incarnation_id: committed.owner_incarnation_id,
      payload: hd(ordinary_terminal.records)
    }

    assert {:error, :invalid_maintenance_episode_transition} ==
             SessionState.recover(state.session_id, history ++ rows ++ [terminal_row], events)
  end

  test "every derived episode member and closed capture is checked during replay" do
    {state, history, events} = run_state()
    {:ok, proposal} = admit(state, 1_000)
    {_committed, [row]} = commit(state, proposal)
    capture = row.payload["maintenance_configuration"]
    changed_capture = %{capture | "context_token_budget" => 1_024}

    changed_capture = %{
      changed_capture
      | "digest" => digest(Map.delete(changed_capture, "digest"))
    }

    for changed <- [
          put_in(row, [:payload, "episode_id"], "other"),
          put_in(row, [:payload, "staging_turn_id"], "other"),
          put_in(row, [:payload, "configuration_version"], 2),
          put_in(row, [:payload, "trigger"], "thinking_headroom"),
          put_in(row, [:payload, "origin"], "explicit"),
          put_in(row, [:payload, "preparation_deadline"], 61_001),
          put_in(row, [:payload, "attempts"], 1),
          put_in(row, [:payload, "summary_ordinal"], 2),
          put_in(row, [:payload, "checkpoint_id"], "fabricated"),
          put_in(row, [:payload, "usage", "reported_tokens"], 1),
          put_in(row, [:payload, "bounds", "max_attempts"], 5),
          put_in(row, [:payload, "maintenance_configuration"], changed_capture),
          put_in(row, [:payload, "extra"], true),
          update_in(row, [:payload], &Map.delete(&1, "usage"))
        ] do
      assert {:error, :invalid_maintenance_episode_transition} ==
               SessionState.recover(state.session_id, history ++ [changed], events)
    end

    duplicate = %{row | journal_version: row.journal_version + 1}

    assert {:error, :invalid_maintenance_episode_transition} ==
             SessionState.recover(state.session_id, history ++ [row, duplicate], events)
  end

  test "clock overflow, missing settings and unsupported mapping admit no episode" do
    {state, _history, _events} = run_state()

    for clock <- [-1, @uint64_max - 59_999, @uint64_max + 1, nil] do
      assert {:error, :maintenance_deadline_unrepresentable} == admit(state, clock)
    end

    assert {:ok, proposal} = admit(state, @uint64_max - 60_000)
    assert hd(proposal.records)["preparation_deadline"] == @uint64_max

    assert {:error, :maintenance_model_unconfigured} ==
             SessionState.propose_maintenance_episode(state, state.active_run_id, nil, nil, 1_000)

    assert {:error, :maintenance_instructions_unconfigured} ==
             SessionState.propose_maintenance_episode(
               state,
               state.active_run_id,
               model(),
               nil,
               1_000
             )

    assert {:error, :maintenance_reasoning_unsupported} ==
             SessionState.propose_maintenance_episode(
               state,
               state.active_run_id,
               %{model() | "reasoning" => "default"},
               instructions(),
               1_000
             )

    assert state.maintenance_episodes == %{}
    assert state.active_maintenance == nil
  end

  test "a committed run cutoff remains separate and elapsed cutoffs win" do
    {state, _, _} = run_state()
    state = %{state | deadlines: %{state.active_run_id => 2_000}}
    assert {:ok, proposal} = admit(state, 1_000)
    assert hd(proposal.records)["preparation_deadline"] == 61_000
    assert hd(proposal.records)["bounds"]["run_deadline"] == 2_000
    assert {:error, :run_deadline_reached} == admit(state, 2_000)
  end

  test "no episode overlaps an open exchange, interaction, abort or provider/effect stage" do
    {state, _, _} = run_state()
    run = state.active_run_id
    work = state.pending_work[run]

    for busy <- [
          %{state | active_run_id: nil},
          %{state | open_interaction: "question"},
          %{state | aborting: %{run_id: run}},
          put_in(state.pending_work[run], %{work | stage: "effect_pending"}),
          put_in(state.pending_work[run], %{work | stage: "model_attempt_open"}),
          put_in(state.pending_work[run], Map.put(work, :continuation_exchange, %{}))
        ] do
      assert {:error, :maintenance_not_quiescent} == admit(busy, 1_000)
    end
  end

  defp admit(state, now),
    do:
      SessionState.propose_maintenance_episode(
        state,
        state.active_run_id,
        model(),
        instructions(),
        now
      )

  defp model do
    source = ConfiguredGenesisFixture.configuration()

    %{
      "model" => source["model"],
      "reasoning" => "none",
      "model_capabilities" => %{source["model_capabilities"] | "reasoning_levels" => ["none"]},
      "provider_mapping" => %{source["provider_mapping"] | "thinking_disabled" => true}
    }
  end

  defp instructions do
    {:ok, captured} =
      MaintenanceConfiguration.capture_instructions(%{
        "version" => "summary.v1",
        "body" => "Keep facts 猫"
      })

    captured
  end

  defp digest(value),
    do: :crypto.hash(:sha256, Canonical.encode(value)) |> Base.encode16(case: :lower)

  defp run_state do
    history = [
      %{
        journal_version: 1,
        owner_epoch: 0,
        owner_incarnation_id: nil,
        payload: ConfiguredGenesisFixture.genesis([])
      },
      %{
        journal_version: 2,
        owner_epoch: 1,
        owner_incarnation_id: "owner",
        payload: %{
          :kind => "owner_advanced",
          "prior_owner_epoch" => 0,
          "owner_epoch" => 1,
          "owner_incarnation_id" => "owner",
          "owner_transaction_id" => "owner-tx"
        }
      }
    ]

    {:ok, state} = SessionState.recover("maintenance-session", history, [])

    {:ok, prompt} =
      SessionState.propose(state, %{type: :prompt, command_id: "prompt", content: "continue"}, %{
        max_turns: 8,
        token_budget: 10_000,
        deadline_ms: 60_000,
        context_token_budget: 8_192
      })

    {state, rows} = commit(state, prompt)

    events =
      Enum.with_index(prompt.events, 1)
      |> Enum.map(fn {event, sequence} -> Map.put(event, :event_sequence, sequence) end)

    {state, history ++ rows, events}
  end

  defp commit(state, proposal) do
    rows =
      Enum.with_index(proposal.records, state.journal_version + 1)
      |> Enum.map(fn {payload, version} ->
        %{
          payload: payload,
          journal_version: version,
          owner_epoch: state.owner_epoch,
          owner_incarnation_id: state.owner_incarnation_id
        }
      end)

    receipt = %{
      journal_versions: %{
        first: state.journal_version + 1,
        last: state.journal_version + length(rows)
      },
      event_sequences:
        if(proposal.events == [],
          do: nil,
          else: %{
            first: state.event_sequence + 1,
            last: state.event_sequence + length(proposal.events)
          }
        )
    }

    {:ok, next} = SessionState.commit_proposal(proposal, receipt)
    {next, rows}
  end
end
