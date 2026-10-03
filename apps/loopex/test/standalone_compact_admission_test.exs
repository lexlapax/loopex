Code.require_file("support/configured_genesis_helper.exs", __DIR__)

defmodule Loopex.Runtime.StandaloneCompactAdmissionTest do
  use ExUnit.Case, async: true

  alias Loopex.ConfiguredGenesisFixture, as: Genesis
  alias Loopex.Runtime.SessionState

  @bounds %{"max_attempts" => 4, "deadline_ms" => 60_000, "token_budget" => 32_768}

  test "admission retains only a bounded command and creates no run, clock or episode" do
    {state, history} = settled()
    assert {:ok, proposal} = SessionState.propose(state, compact())
    assert [record] = proposal.records

    assert MapSet.new(Map.keys(record)) ==
             MapSet.new([
               :kind,
               "command_id",
               "command_digest",
               "command_type",
               "admission",
               "bounds",
               "episode_id"
             ])

    assert record.kind == "compact_command_admitted_v1"
    assert record["bounds"] == @bounds
    assert proposal.events == []
    assert proposal.reply == {:accepted, "compact"}
    assert {:ok, _} = Loopex.Store.admit_bounded(record)
    assert proposal.next.active_run_id == nil
    assert proposal.next.active_maintenance == nil
    assert proposal.next.pending_work == %{}
    assert proposal.next.maintenance_episodes == %{}

    for field <- [
          :run_order,
          :bounds,
          :deadlines,
          :charged,
          :conversation,
          :run_configurations,
          :context_budgets
        ] do
      assert Map.fetch!(proposal.next, field) == Map.fetch!(state, field)
    end

    {next, rows, _} = commit(state, proposal)
    assert {:ok, replay} = SessionState.recover(state.session_id, history ++ rows, [])
    assert replay.pending_compact == next.pending_compact
    assert replay.commands["compact"].run_id == nil

    assert SessionState.command_disposition(replay, "compact") ==
             {:committed, :admitted, :accepted, nil}
  end

  test "closed declarations accept their inclusive endpoints and canonicalize caller keys" do
    {state, _} = settled()

    for bounds <- [@bounds, %{"max_attempts" => 1, "deadline_ms" => 1, "token_budget" => 1}] do
      atom = Map.new(bounds, fn {key, value} -> {String.to_existing_atom(key), value} end)
      mixed = Map.put(Map.delete(bounds, "max_attempts"), :max_attempts, bounds["max_attempts"])

      for input <- [bounds, atom, mixed] do
        assert {:ok, proposal} = SessionState.propose(state, compact(input))
        assert hd(proposal.records)["bounds"] == bounds
        {next, _, _} = commit(state, proposal)

        assert {:replayed, {:accepted, "compact"}} =
                 SessionState.propose(next, %{
                   "type" => "compact",
                   "command_id" => "compact",
                   "bounds" => bounds
                 })
      end
    end
  end

  test "missing, extra, duplicate, narrowed and oversized declarations refuse before admission" do
    {state, _} = settled()

    invalid = [
      nil,
      [],
      %{},
      Map.delete(@bounds, "deadline_ms"),
      Map.put(@bounds, "max_turns", 1),
      Map.put(@bounds, :max_attempts, 4),
      %{"max_attempts" => 4, :max_attempts => 4, "token_budget" => 32_768}
    ]

    invalid =
      invalid ++
        for {key, values} <- [
              {"max_attempts", [0, -1, 5, 4.0, "4", nil]},
              {"deadline_ms", [0, -1, 60_001, 1.0, "1", nil]},
              {"token_budget", [0, -1, 32_769, 1.0, "1", nil]}
            ],
            value <- values,
            do: Map.put(@bounds, key, value)

    for bounds <- invalid do
      assert {:error, :invalid_compact_bounds} = SessionState.normalize_compact_bounds(bounds)
      assert {:error, :invalid_command} = SessionState.propose(state, compact(bounds))
    end

    for command <- [
          Map.delete(compact(), :bounds),
          Map.put(compact(), :prompt, "invented"),
          Map.put(compact(), "type", "compact")
        ] do
      assert {:error, :invalid_command} = SessionState.propose(state, command)
    end
  end

  test "all fresh input mutations refuse while duplicate lookup keeps the original binding" do
    {state, history} = settled()
    original = %{type: :abort, command_id: "old-abort"}
    {:ok, refused} = SessionState.propose(state, original)
    {state, prior, _} = commit(state, refused)
    {:ok, proposal} = SessionState.propose(state, compact())
    {state, admitted, _} = commit(state, proposal)
    history = history ++ prior ++ admitted

    assert {:replayed, {:error, :no_active_run}} = SessionState.propose(state, original)
    assert {:replayed, {:accepted, "compact"}} = SessionState.propose(state, compact())

    assert {:error, :idempotency_conflict} =
             SessionState.propose(state, compact(Map.put(@bounds, "max_attempts", 3)))

    commands = [
      %{type: :prompt, command_id: "new-prompt", content: "new"},
      %{type: :steer, command_id: "new-steer", run_id: "foreign", content: "new"},
      %{type: :follow_up, command_id: "new-follow-up", content: "new"},
      %{type: :configure, command_id: "new-configure", changes: %{"max_tokens" => 32}},
      %{type: :compact, command_id: "new-compact", bounds: @bounds},
      %{
        type: :interaction_answer,
        command_id: "new-answer",
        interaction_id: "foreign",
        choice_id: "yes"
      }
    ]

    for command <- commands do
      assert {:ok, refusal} = SessionState.propose(state, command)
      assert refusal.reply == {:error, :maintenance_active}
      assert refusal.events == []
      assert refusal.next.pending_compact == state.pending_compact
      assert refusal.next.pending_work == %{}
      assert refusal.next.follow_up == nil
      assert refusal.next.configuration == state.configuration
      {next, rows, _} = commit(state, refusal)
      assert {:replayed, {:error, :maintenance_active}} = SessionState.propose(next, command)
      assert {:ok, replay} = SessionState.recover(state.session_id, history ++ rows, [])
      assert replay.pending_compact == state.pending_compact
    end
  end

  test "active-run compact refusal remains idempotent without installing standalone work" do
    {state, history} = settled()

    {:ok, prompt} =
      SessionState.propose(
        state,
        %{type: :prompt, command_id: "prompt", content: "work"},
        run_bounds()
      )

    {state, rows, events} = commit(state, prompt)
    {:ok, proposal} = SessionState.propose(state, compact())
    assert proposal.reply == {:error, :run_active}
    assert proposal.next.pending_compact == nil
    assert proposal.next.active_run_id == state.active_run_id
    assert proposal.next.pending_work == state.pending_work
    assert proposal.events == []
    {_next, compact_rows, _} = commit(state, proposal)

    assert {:ok, replay} =
             SessionState.recover(state.session_id, history ++ rows ++ compact_rows, events)

    assert {:replayed, {:error, :run_active}} = SessionState.propose(replay, compact())
  end

  test "abort binds to the compact identity, preserves the first cancellation and creates no run ending" do
    {state, history} = settled()
    {:ok, proposal} = SessionState.propose(state, compact())
    {state, admitted, _} = commit(state, proposal)
    command = %{type: :abort, command_id: "abort"}
    assert {:ok, abort} = SessionState.propose(state, command)
    assert [record] = abort.records
    assert record.kind == "compact_abort_admitted_v1"
    assert record["episode_id"] == state.pending_compact["episode_id"]
    assert record["compact_command_id"] == "compact"
    assert abort.events == []
    assert abort.next.active_run_id == nil
    assert abort.next.aborting == nil
    {next, rows, _} = commit(state, abort)
    assert next.pending_compact["abort_command_id"] == "abort"
    assert {:replayed, {:accepted, "abort"}} = SessionState.propose(next, command)
    assert {:ok, second} = SessionState.propose(next, %{type: :abort, command_id: "abort-again"})
    assert second.next.pending_compact["abort_command_id"] == "abort"
    assert {:ok, replay} = SessionState.recover(state.session_id, history ++ admitted ++ rows, [])
    assert replay.pending_compact == next.pending_compact

    for transform <- [
          &Map.put(&1, "episode_id", "foreign"),
          &Map.put(&1, "compact_command_id", "foreign"),
          &Map.put(&1, "command_digest", String.duplicate("0", 64)),
          &Map.put(&1, "run_id", "invented"),
          &Map.delete(&1, "episode_id")
        ] do
      changed = Enum.map(rows, &%{&1 | payload: transform.(&1.payload)})

      assert {:error, _} =
               SessionState.recover(state.session_id, history ++ admitted ++ changed, [])
    end
  end

  test "succession retains explicit bounds and the cancellation binding without resetting admission" do
    {state, history} = settled()
    {:ok, proposal} = SessionState.propose(state, compact())
    {state, rows, _} = commit(state, proposal)
    {:ok, abort} = SessionState.propose(state, %{type: :abort, command_id: "abort"})
    {state, abort_rows, _} = commit(state, abort)
    successor = owner_row(state.journal_version + 1, 2, "successor")

    assert {:ok, replay} =
             SessionState.recover(
               state.session_id,
               history ++ rows ++ abort_rows ++ [successor],
               []
             )

    assert replay.owner_epoch == 2
    assert replay.pending_compact == state.pending_compact
    assert replay.pending_compact["bounds"] == @bounds
    assert {:replayed, {:accepted, "compact"}} = SessionState.propose(replay, compact())
  end

  test "replay rejects forged declarations, command digests, episode identities and admissions" do
    {state, history} = settled()
    {:ok, proposal} = SessionState.propose(state, compact())
    {_next, [row], _} = commit(state, proposal)

    for transform <- [
          &put_in(&1, ["bounds", "max_attempts"], 3),
          &put_in(&1, ["bounds", "deadline_ms"], 60_001),
          &Map.put(&1, "command_digest", String.duplicate("0", 64)),
          &Map.put(&1, "episode_id", "foreign"),
          &Map.put(&1, "admission", "rejected_run_active"),
          &Map.put(&1, "admitted_at", 1_000),
          &Map.delete(&1, "bounds"),
          &Map.delete(&1, "episode_id")
        ] do
      assert {:error, _} =
               SessionState.recover(
                 state.session_id,
                 history ++ [%{row | payload: transform.(row.payload)}],
                 []
               )
    end
  end

  test "replay cannot admit a correct ordinary prompt across a pending standalone fence" do
    {state, history} = settled()
    {:ok, compact} = SessionState.propose(state, compact())
    {next, rows, _} = commit(state, compact)

    {:ok, prompt} =
      SessionState.propose(
        state,
        %{type: :prompt, command_id: "prompt", content: "work"},
        run_bounds()
      )

    {_other, [forged], events} = commit(state, prompt)
    forged = %{forged | journal_version: next.journal_version + 1}

    assert {:error, :invalid_standalone_compact_transition} =
             SessionState.recover(state.session_id, history ++ rows ++ [forged], events)
  end

  defp compact(bounds \\ @bounds), do: %{type: :compact, command_id: "compact", bounds: bounds}

  defp run_bounds,
    do: %{max_turns: 8, deadline_ms: 60_000, token_budget: 10_000, context_token_budget: 8_192}

  defp settled do
    history = [
      %{
        journal_version: 1,
        owner_epoch: 0,
        owner_incarnation_id: nil,
        payload: Genesis.genesis([])
      },
      owner_row(2, 1, "owner")
    ]

    {:ok, state} = SessionState.recover("standalone-compact-session", history, [])
    {state, history}
  end

  defp owner_row(version, epoch, incarnation) do
    %{
      journal_version: version,
      owner_epoch: epoch,
      owner_incarnation_id: incarnation,
      payload: %{
        :kind => "owner_advanced",
        "prior_owner_epoch" => epoch - 1,
        "owner_epoch" => epoch,
        "owner_incarnation_id" => incarnation,
        "owner_transaction_id" => "owner-tx-#{epoch}"
      }
    }
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

    events =
      Enum.with_index(proposal.events, state.event_sequence + 1)
      |> Enum.map(fn {event, sequence} -> Map.put(event, :event_sequence, sequence) end)

    receipt = %{
      journal_versions: %{
        first: state.journal_version + 1,
        last: state.journal_version + length(rows)
      },
      event_sequences:
        if(events == [],
          do: nil,
          else: %{first: state.event_sequence + 1, last: state.event_sequence + length(events)}
        )
    }

    {:ok, next} = SessionState.commit_proposal(proposal, receipt)
    {next, rows, events}
  end
end
