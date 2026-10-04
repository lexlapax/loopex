Code.require_file("support/configured_genesis_helper.exs", __DIR__)

defmodule Loopex.Runtime.MaintenanceEpisodeAdmissionTest do
  use ExUnit.Case, async: true

  alias Loopex.ConfiguredGenesisFixture
  alias Loopex.Runtime.{MaintenanceConfiguration, SessionState}
  alias LoopexProtocol.Canonical

  @uint64_max 18_446_744_073_709_551_615

  test "the admitted public view excludes captures and is independently authenticated on replay" do
    {state, history, events} = run_state()
    private_body = "PRIVATE_MAINTENANCE_INSTRUCTION_CANARY"

    {:ok, private_instructions} =
      MaintenanceConfiguration.capture_instructions(%{
        "version" => "private-summary.v1",
        "body" => private_body
      })

    assert {:ok, proposal} =
             SessionState.propose_maintenance_episode(
               state,
               state.active_run_id,
               model(),
               private_instructions,
               1_000
             )

    [event] = proposal.events
    view = event["active_maintenance"]

    assert Enum.sort(Map.keys(view)) ==
             Enum.sort(~w(episode_id owner model reasoning configuration_version bounds))

    assert {:ok, _} =
             LoopexProtocol.Session.MaintenanceView.encode_wire(%{"active_maintenance" => view})

    refute inspect(event) =~ private_body
    refute inspect(event) =~ "provider_mapping"
    refute inspect(event) =~ "model_capabilities"
    refute inspect(event) =~ "rendered"

    assert hd(proposal.records)["maintenance_configuration"]["instructions"] ==
             private_instructions

    {_committed, rows} = commit(state, proposal)
    public = append_events(state, events, proposal.events)
    assert {:ok, _} = SessionState.recover(state.session_id, history ++ rows, public)

    changed_views = [
      nil,
      Map.put(view, "instructions", private_body),
      %{view | "model" => "substituted:model"},
      %{view | "owner" => %{"kind" => "compact", "id" => state.active_run_id}},
      put_in(view, ["bounds", "token_budget"], view["bounds"]["token_budget"] + 1)
    ]

    for altered <- changed_views do
      forged = append_events(state, events, [%{event | "active_maintenance" => altered}])

      assert {:error, :private_public_projection_mismatch} =
               SessionState.recover(state.session_id, history ++ rows, forged)
    end

    assert {:error, :private_public_projection_mismatch} =
             SessionState.recover(state.session_id, history ++ rows, events)

    duplicated = append_events(state, events, [event, event])

    assert {:error, :private_public_projection_mismatch} =
             SessionState.recover(state.session_id, history ++ rows, duplicated)
  end

  test "admission freezes the parent, summarizer and fixed preparation clock without dispatch" do
    {state, history, events} = run_state()
    assert {:ok, proposal} = admit(state, 1_000)
    assert [row] = proposal.records
    assert [event] = proposal.events
    assert event.kind == "context.maintenance_changed"
    assert Map.keys(Map.drop(event, [:kind, :event_id])) == ["active_maintenance"]

    assert event["active_maintenance"] == %{
             "episode_id" => row["episode_id"],
             "owner" => %{"kind" => "run", "id" => row["run_id"]},
             "model" => "scripted:v1",
             "reasoning" => "none",
             "configuration_version" => 1,
             "bounds" => row["bounds"]
           }

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

    events = append_events(state, events, proposal.events)
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
    events = append_events(state, events, proposal.events)
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
    events = append_events(state, events, admission.events)
    {committed, rows} = commit(state, admission)

    assert {:ok, ending} = SessionState.propose_run_terminal(committed, run, "failed", detail)
    assert [prefix, terminal] = ending.records
    assert prefix.kind == "maintenance_episode_terminal_v1"

    assert prefix["result"]["failure"] == %{
             "category" => "model_call_failed",
             "retryable" => false
           }

    assert prefix["result"]["usage"] == hd(admission.records)["usage"]
    assert terminal == hd(ordinary_terminal.records)
    assert ending.next.active_maintenance == nil
    assert ending.next.maintenance_terminal == nil
    assert ending.next.maintenance_episodes[committed.active_maintenance]["stage"] == "settled"
    assert {:ok, recovered} = replay_ending(committed, history ++ rows, events, ending)
    assert recovered.maintenance_episodes == ending.next.maintenance_episodes
    assert recovered.active_run_id == nil

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

  test "expiry uses its retained cutoff, zero usage and an adjacent unavailable refusal" do
    {state, history, events} = admitted_state()
    run = state.active_run_id

    assert {:error, :maintenance_preparation_not_elapsed} ==
             SessionState.propose_maintenance_preparation_expiry(state, run, 60_999)

    assert {:ok, ending} = SessionState.propose_maintenance_preparation_expiry(state, run, 61_000)
    assert [prefix, refusal, terminal] = ending.records

    assert Enum.map(ending.records, & &1.kind) == [
             "maintenance_episode_terminal_v1",
             "context_admission_refused_v2",
             "run_terminal_committed"
           ]

    assert prefix["observed_at"] == 61_000
    assert prefix["episode_id"] == state.active_maintenance
    assert refusal["episode_id"] == state.active_maintenance
    assert refusal["failure"] == prefix["result"]["failure"]
    assert refusal["failure"] == terminal["failure"]
    assert refusal["failure"]["cause"] == "compaction_preparation_deadline"
    assert refusal["failure"]["measurement_scope"] == nil
    assert refusal["projection_state"] == "unavailable"
    assert refusal["record_byte_cost"] == nil
    assert terminal["outcome"] == "failed"
    assert terminal["bound"] == nil
    assert terminal["observed"] == nil
    assert terminal["declared_limit"] == nil
    assert prefix["result"]["disposition"] == "failed"
    assert prefix["result"]["cleanup"] == "confirmed"
    assert prefix["result"]["checkpoint_id"] == nil
    assert prefix["result"]["usage"]["total_tokens"] == 0
    assert ending.next.charged == state.charged
    assert ending.next.deadlines == %{}

    assert Enum.map(ending.events, & &1.kind) == [
             "context.maintenance_changed",
             "run.finished",
             "session.settled"
           ]

    assert hd(ending.events)["active_maintenance"] == nil
    assert {:ok, recovered} = replay_ending(state, history, events, ending)
    assert recovered.active_maintenance == nil
    assert recovered.maintenance_terminal == nil
    assert recovered.maintenance_episodes[state.active_maintenance]["result"] == prefix["result"]

    for now <- [-1, @uint64_max + 1, nil] do
      assert {:error, :invalid_maintenance_episode_transition} ==
               SessionState.propose_maintenance_preparation_expiry(state, run, now)
    end
  end

  test "episode terminal prefixes cannot be left at the head or interrupted by any row" do
    {state, history, events} = admitted_state()

    {:ok, ending} =
      SessionState.propose_maintenance_preparation_expiry(state, state.active_run_id, 61_000)

    {_next, rows} = commit(state, ending)
    [prefix, refusal, terminal] = rows

    for tail <- [[prefix], [prefix, refusal]] do
      assert {:error, :incomplete_maintenance_terminal_transaction} ==
               SessionState.recover(state.session_id, history ++ tail, events)
    end

    {:ok, steer} =
      SessionState.propose(state, %{
        type: :steer,
        command_id: "steer",
        run_id: state.active_run_id,
        content: "later"
      })

    {_next, [command]} = commit(state, steer)

    advance = %{
      prefix
      | payload: %{
          :kind => "owner_advanced",
          "prior_owner_epoch" => 1,
          "owner_epoch" => 2,
          "owner_incarnation_id" => "successor",
          "owner_transaction_id" => "next-owner"
        },
        owner_epoch: 2,
        owner_incarnation_id: "successor"
    }

    for inserted <- [prefix, command, advance] do
      for before <- [1, 2] do
        tail = List.insert_at(rows, before, inserted) |> restamp(state)

        assert {:error, :incomplete_maintenance_terminal_transaction} ==
                 SessionState.recover(state.session_id, history ++ tail, events)
      end
    end

    assert {:error, _} =
             SessionState.recover(
               state.session_id,
               history ++ restamp([prefix, terminal], state),
               events
             )

    assert {:error, _} =
             SessionState.recover(
               state.session_id,
               history ++ restamp([refusal, prefix, terminal], state),
               events
             )
  end

  test "replay rejects forged clock, result, identities and refusal attribution" do
    {state, history, events} = admitted_state()

    {:ok, ending} =
      SessionState.propose_maintenance_preparation_expiry(state, state.active_run_id, 61_000)

    {_next, rows} = commit(state, ending)
    all_events = append_events(state, events, ending.events)

    for changed <- [
          put_in(rows, [Access.at(0), :payload, "episode_id"], "other"),
          put_in(rows, [Access.at(0), :payload, "observed_at"], 60_999),
          put_in(rows, [Access.at(0), :payload, "observed_at"], nil),
          put_in(rows, [Access.at(0), :payload, "observed_at"], @uint64_max + 1),
          put_in(rows, [Access.at(0), :payload, "extra"], true),
          put_in(rows, [Access.at(0), :payload, "result", "extra"], true),
          put_in(
            rows,
            [Access.at(0), :payload, "result", "failure", "cause"],
            "compaction_no_progress"
          ),
          put_in(rows, [Access.at(0), :payload, "result", "usage", "total_tokens"], 1),
          put_in(rows, [Access.at(0), :payload, "result", "cleanup"], "unknown"),
          put_in(rows, [Access.at(0), :payload, "result", "checkpoint_id"], "invented"),
          put_in(rows, [Access.at(1), :payload, "episode_id"], nil),
          put_in(rows, [Access.at(1), :payload, "turn_id"], "other"),
          put_in(rows, [Access.at(1), :payload, "failure", "cause"], "compaction_no_progress"),
          put_in(rows, [Access.at(2), :payload, "failure", "cause"], "compaction_no_progress")
        ] do
      assert {:error, _} = SessionState.recover(state.session_id, history ++ changed, all_events)
    end
  end

  test "deadline staging keeps its original pair and a distinct episode failure" do
    {state, history, events} = admitted_state()

    assert {:ok, ending} =
             SessionState.propose_deadline_failure(
               state,
               state.active_run_id,
               "deadline_addition_overflow"
             )

    assert [prefix, failure, terminal] = ending.records
    assert prefix.kind == "maintenance_episode_terminal_v1"
    assert failure.kind == "deadline_staging_failed_v1"
    assert map_size(failure) == 4

    assert terminal["failure"] == %{
             "category" => "deadline_preflight_failed",
             "retryable" => false
           }

    assert prefix["result"]["failure"]["cause"] == "maintenance_deadline_unrepresentable"
    assert {:ok, _} = replay_ending(state, history, events, ending)
  end

  test "an admitted abort closes its episode with the same cancellation" do
    {state, history, events} = admitted_state()
    {:ok, abort} = SessionState.propose(state, %{type: :abort, command_id: "abort"})
    {state, rows} = commit(state, abort)

    events =
      append_events(
        %{state | event_sequence: state.event_sequence - length(abort.events)},
        events,
        abort.events
      )

    assert {:ok, ending} =
             SessionState.propose_run_terminal(state, state.active_run_id, "cancelled", %{})

    assert [prefix, terminal] = ending.records
    assert prefix["result"]["failure"] == %{"category" => "cancelled", "retryable" => false}
    assert terminal["command_id"] == "abort"
    assert {:ok, _} = replay_ending(state, history ++ rows, events, ending)

    assert {:error, :invalid_maintenance_episode_transition} ==
             SessionState.propose_maintenance_preparation_expiry(
               state,
               state.active_run_id,
               61_000
             )
  end

  test "the committed run cutoff wins only when it is earlier or equal" do
    {base, _, _} = run_state()
    run = base.active_run_id

    for deadline <- [2_000, 61_000] do
      prior = %{base | deadlines: %{run => deadline}}
      {:ok, admission} = admit(prior, 1_000)
      {state, _rows} = commit(prior, admission)

      assert {:ok, ending} =
               SessionState.propose_maintenance_preparation_expiry(state, run, deadline)

      assert [prefix, terminal] = ending.records
      assert terminal["outcome"] == "bound_reached"
      assert terminal["bound"] == "deadline"
      assert terminal["declared_limit"] == deadline
      assert terminal["observed"] == deadline

      assert prefix["result"]["failure"] == %{
               "category" => "bound_reached",
               "retryable" => false,
               "bound" => "deadline_ms",
               "declared_limit" => deadline,
               "observed" => deadline,
               "accounting_source" => nil
             }
    end

    prior = %{base | deadlines: %{run => 61_001}}
    {:ok, admission} = admit(prior, 1_000)
    {state, _rows} = commit(prior, admission)
    assert {:ok, ending} = SessionState.propose_maintenance_preparation_expiry(state, run, 70_000)
    assert [prefix, _refusal, terminal] = ending.records
    assert terminal["outcome"] == "failed"
    assert prefix["result"]["failure"]["cause"] == "compaction_preparation_deadline"
  end

  test "a parent-bound ending rejects invented counters, ceilings and accounting" do
    {base, _, _} = run_state()
    run = base.active_run_id
    prior = %{base | deadlines: %{run => 2_000}}
    {:ok, admission} = admit(prior, 1_000)
    {state, _rows} = commit(prior, admission)

    for detail <- [
          %{bound: "deadline", observed: -1, declared_limit: 2_000},
          %{bound: "deadline", observed: 1_999, declared_limit: 2_000},
          %{bound: "deadline", observed: 2_000, declared_limit: 60_000},
          %{
            bound: "deadline",
            observed: 2_000,
            declared_limit: 2_000,
            accounting_source: "reported"
          },
          %{bound: "token_budget", observed: 10_000, declared_limit: 10_000},
          %{bound: "max_turns", observed: 8, declared_limit: 8},
          %{bound: "max_attempts", observed: 4, declared_limit: 4}
        ] do
      assert {:error, :invalid_maintenance_episode_transition} ==
               SessionState.propose_run_terminal(state, run, "bound_reached", detail)
    end
  end

  defp admitted_state do
    {state, history, events} = run_state()
    {:ok, proposal} = admit(state, 1_000)
    {next, rows} = commit(state, proposal)
    {next, history ++ rows, append_events(state, events, proposal.events)}
  end

  defp replay_ending(state, history, events, proposal) do
    {_next, rows} = commit(state, proposal)

    SessionState.recover(
      state.session_id,
      history ++ rows,
      append_events(state, events, proposal.events)
    )
  end

  defp append_events(state, events, added) do
    events ++
      (Enum.with_index(added, state.event_sequence + 1)
       |> Enum.map(fn {event, sequence} -> Map.put(event, :event_sequence, sequence) end))
  end

  defp restamp(rows, state) do
    Enum.with_index(rows, state.journal_version + 1)
    |> Enum.map(fn {row, version} -> %{row | journal_version: version} end)
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
