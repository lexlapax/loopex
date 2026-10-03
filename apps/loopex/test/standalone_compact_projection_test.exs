Code.require_file("support/configured_genesis_helper.exs", __DIR__)

defmodule Loopex.Runtime.StandaloneCompactProjectionTest do
  use ExUnit.Case, async: true

  alias Loopex.ConfiguredGenesisFixture, as: Genesis
  alias Loopex.Runtime.{ContextAdmission, SessionState}
  alias Loopex.Store
  alias LoopexProtocol.Session.ContextFailure
  alias LoopexProtocol.ToolDefinition

  test "explicit selection releases every terminal unit even when the whole history fits" do
    for texts <- [[], ["first raw input", "second raw input"]] do
      {state, history, events} = pending(texts)

      assert {:ok, plan} =
               SessionState.preflight_standalone_compaction(state, 61_000, fn -> :ok end)

      assert plan.origin == "explicit"
      assert plan.trigger == "explicit"
      assert plan.targets == nil
      assert plan.last_offending_source == nil
      assert plan.before.failure == nil
      assert plan.before.rendering == :ok
      assert plan.eligible_unit_count == length(texts)
      assert plan.retained_tail == []
      assert plan.tail_tokens == 0
      assert state.maintenance_episodes == %{}
      assert state.deadlines == %{}
      assert {:ok, ^state} = SessionState.recover(state.session_id, history, events)
    end
  end

  test "hard overflow selects ordinary-limit repair under explicit origin" do
    {state, _, _} =
      pending([String.duplicate("x", 34_000)],
        context_token_budget: 1_000,
        system_class_tokens: 512
      )

    assert {:ok, plan} =
             SessionState.preflight_standalone_compaction(state, 61_000, fn -> :ok end)

    assert plan.trigger == "ordinary_limit"
    assert plan.origin == "explicit"
    assert plan.targets == nil
    assert plan.last_offending_source == nil
    assert plan.before.failure["dimension"] == "context_tokens"
    assert plan.eligible_unit_count == 1
    assert plan.retained_tail == []
    assert plan.tail_tokens == 0
  end

  test "cancellation during minimum-tail measurement prevents a selection result" do
    {state, _, _} = pending(["raw input"])
    counter = :counters.new(1, [])

    check = fn ->
      :counters.add(counter, 1, 1)
      if :counters.get(counter, 1) == 5, do: {:error, :cancelled}, else: :ok
    end

    assert {:error, :cancelled} =
             SessionState.preflight_standalone_compaction(state, 61_000, check)

    assert :counters.get(counter, 1) == 5
    assert state.maintenance_episodes == %{}
    assert state.active_maintenance == nil
    assert state.deadlines == %{}
  end

  test "empty history measures the complete command-bound view with an exact self-size" do
    {state, history, events} = pending([])
    assert {:ok, probe} = SessionState.preflight_standalone_context(state, 61_000, fn -> :ok end)
    assert probe.failure == nil
    assert probe.rendering == :ok
    assert probe.request.continuation == nil
    assert length(probe.request.messages) == 1
    assert probe.record["command_id"] == state.pending_compact["command_id"]
    assert probe.record["episode_id"] == state.pending_compact["episode_id"]
    assert probe.record["configuration_version"] == state.configuration["configuration_version"]

    assert MapSet.new(Map.keys(probe.record)) ==
             MapSet.new([
               :kind,
               "command_id",
               "episode_id",
               "configuration_version",
               "request",
               "context_receipt",
               "lineage_projection"
             ])

    assert probe.record.kind == "compact_context_probe_v1"
    assert probe.record["request"]["deadline"] == 61_000
    assert probe.receipt == probe.record["context_receipt"]
    exact_bytes = byte_size(:erlang.term_to_binary(probe.record, [:deterministic]))
    assert probe.receipt["record_byte_cost"] == exact_bytes

    assert {:ok, normalized, ^exact_bytes} =
             Store.normalize_and_measure_item(:record, probe.record)

    assert normalized == probe.record
    assert {:ok, ^state} = SessionState.recover(state.session_id, history, events)

    # Concept: a sizing view grants no authority or durable completion.
    # Technical depth: it is deliberately outside the journal grammar. The
    # owner still needs episode capture, source/dispatch and completion records.
    assert {:error, _} =
             SessionState.recover(state.session_id, history ++ [row(state, probe.record)], events)

    assert state.run_order == []
    assert state.maintenance_episodes == %{}
    assert state.active_run_id == nil
    assert state.deadlines == %{}
  end

  test "whole terminal history and a local minimum tail use the same fixed configuration" do
    {state, _, _} = pending(["first raw input", "second raw input"])
    raw = SessionState.lineage_elements(state, :session)
    assert {:ok, whole} = SessionState.preflight_standalone_context(state, 61_000, fn -> :ok end)

    assert Enum.map(tl(whole.request.messages), & &1["content"]) ==
             ["first raw input", "second raw input"]

    assert {:ok, tail} =
             SessionState.preflight_standalone_context(state, 61_000, fn -> :ok end, %{
               elements: []
             })

    assert tail.request.messages == [hd(whole.request.messages)]
    assert tail.request.model == whole.request.model
    assert tail.request.sampling == whole.request.sampling
    assert tail.request.deadline == whole.request.deadline
    assert tail.receipt["provider_estimated_tokens"] < whole.receipt["provider_estimated_tokens"]
    assert tail.receipt["record_byte_cost"] < whole.receipt["record_byte_cost"]
    assert SessionState.lineage_elements(state, :session) == raw
    assert state.active_maintenance == nil
    assert state.charged |> Map.values() |> Enum.all?(&(&1.tokens == 0))
  end

  test "standalone uses hard input limits even when a new thinking request would need headroom" do
    configuration =
      configuration(context_token_budget: 1_000, system_class_tokens: 512)
      |> put_in(["model_capabilities", "reasoning_levels"], ["default"])
      |> put_in(["provider_mapping", "mapping_revision"], "fixture.continuation.v1")
      |> put_in(["provider_mapping", "continuation_required"], true)

    {state, _, _} = pending([String.duplicate("x", 2_400)], configuration: configuration)
    assert {:ok, probe} = SessionState.preflight_standalone_context(state, 61_000, fn -> :ok end)
    targets = ContextAdmission.thinking_targets(1_000)
    assert probe.receipt["provider_estimated_tokens"] > targets["input_target"]
    assert probe.receipt["provider_estimated_tokens"] <= 1_000
    assert probe.failure == nil
    assert probe.request.continuation == nil
    assert probe.receipt["continuation_cost"] == nil
  end

  test "the captured input ceiling precedes an oversized whole-record view" do
    {state, _, _} =
      pending([String.duplicate("x", 34_000)],
        context_token_budget: 1_000,
        system_class_tokens: 512
      )

    assert {:ok, probe} = SessionState.preflight_standalone_context(state, 61_000, fn -> :ok end)
    assert probe.failure["dimension"] == "context_tokens"
    assert probe.failure["limit"] == 1_000
    assert probe.failure["hard_limit"] == 1_000
    assert probe.failure["measurement_scope"] == "ordinary"
    assert probe.failure["version"] == 2
    assert probe.failure["category"] == "context_budget_exceeded"
    assert probe.failure["retryable"] == false
    assert probe.receipt["record_byte_cost"] > Store.max_item_bytes()
    assert {:ok, _wire} = ContextFailure.project(probe.failure, :encode)
    refute Map.has_key?(probe.failure, "record_byte_cost")
  end

  test "byte refusal reports the exact oversized view without trimming original inputs" do
    {state, _, _} = pending([String.duplicate("x", 34_000)])
    raw = SessionState.lineage_elements(state, :session)
    assert {:ok, probe} = SessionState.preflight_standalone_context(state, 61_000, fn -> :ok end)
    exact_bytes = byte_size(:erlang.term_to_binary(probe.record, [:deterministic]))
    assert probe.receipt["provider_estimated_tokens"] <= 32_768
    assert probe.failure["dimension"] == "context_record_bytes"
    assert probe.failure["observed"] == exact_bytes
    assert probe.receipt["record_byte_cost"] == exact_bytes
    assert probe.failure["limit"] == 65_536
    assert probe.failure["hard_limit"] == 65_536
    assert {:ok, wire} = ContextFailure.project(probe.failure, :encode)
    assert wire["observed"] == Integer.to_string(exact_bytes)
    assert SessionState.lineage_elements(state, :session) == raw
    assert byte_size(List.last(probe.request.messages)["content"]) == 34_000
  end

  test "structural refusal precedes bytes and preserves the unresolved self-size" do
    {state, _, _} =
      pending(List.duplicate("x", Store.max_item_cardinality() - 1),
        definitions: [ToolDefinition.question_definition()]
      )

    assert {:ok, probe} = SessionState.preflight_standalone_context(state, 61_000, fn -> :ok end)
    assert probe.failure["dimension"] == "context_record_cardinality"
    assert probe.failure["observed"] == 1_025
    assert probe.failure["limit"] == 1_024
    assert probe.receipt["record_byte_cost"] == 0
    assert {:ok, _} = ContextFailure.project(probe.failure, :encode)
    assert length(probe.request.messages) == 1_024
    assert length(probe.request.tools) == 1
    assert length(probe.receipt["blocks"]) == 1_025
  end

  test "interruption stops the probe before and after canonical projection or sizing" do
    {state, _, _} = pending(["raw input"])

    for stop_at <- 1..4 do
      counter = :counters.new(1, [])

      check = fn ->
        :counters.add(counter, 1, 1)
        if :counters.get(counter, 1) == stop_at, do: {:error, :cancelled}, else: :ok
      end

      assert {:error, :cancelled} =
               SessionState.preflight_standalone_context(state, 61_000, check)

      assert :counters.get(counter, 1) == stop_at
    end

    assert state.maintenance_episodes == %{}
    assert state.deadlines == %{}
  end

  test "a pending accepted command owns the probe and cannot replace its fixed identity" do
    {state, _, _} = pending([])

    for replacement <- [
          %{run_id: "invented"},
          %{deadline: 999},
          %{configuration_version: 999},
          %{elements: nil},
          %{elements: "invented"}
        ] do
      assert {:error, :context_projection_invalid} =
               SessionState.preflight_standalone_context(
                 state,
                 61_000,
                 fn -> :ok end,
                 replacement
               )
    end

    for deadline <- [nil, 0, -1, 18_446_744_073_709_551_616] do
      assert {:error, :context_projection_invalid} =
               SessionState.preflight_standalone_context(state, deadline, fn -> :ok end)
    end

    for invalid <- [
          %{state | pending_compact: nil},
          %{state | pending_compact: Map.put(state.pending_compact, "abort_command_id", "abort")}
        ] do
      assert {:error, :context_projection_invalid} =
               SessionState.preflight_standalone_context(invalid, 61_000, fn ->
                 flunk("unowned or cancelled compact entered projection")
               end)
    end
  end

  defp configuration(options) do
    Genesis.configuration()
    |> Map.put("context_token_budget", Keyword.get(options, :context_token_budget, 32_768))
    |> Map.put("system_class_tokens", Keyword.get(options, :system_class_tokens, 5_000))
    |> put_in(["budget_origins", "context_token_budget"], "explicit")
  end

  defp pending(texts, options \\ []) do
    configuration = Keyword.get_lazy(options, :configuration, fn -> configuration(options) end)

    history = [
      %{
        journal_version: 1,
        owner_epoch: 0,
        owner_incarnation_id: nil,
        payload: Genesis.genesis(Keyword.get(options, :definitions, []), configuration)
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

    {:ok, initial} = SessionState.recover("compact-projection-session", history, [])

    {state, history, events} =
      Enum.reduce(Enum.with_index(texts), {initial, history, []}, fn {text, index},
                                                                     {state, history, events} ->
        {:ok, prompt} =
          SessionState.propose(
            state,
            %{type: :prompt, command_id: "old-#{index}", content: text},
            %{
              max_turns: 8,
              deadline_ms: 60_000,
              token_budget: 10_000,
              context_token_budget: configuration["context_token_budget"]
            }
          )

        {state, history, events} = commit(state, prompt, history, events)

        {:ok, terminal} =
          SessionState.propose_run_terminal(state, state.active_run_id, "failed", %{
            reason: "model_call_failed"
          })

        commit(state, terminal, history, events)
      end)

    {:ok, compact} =
      SessionState.propose(state, %{
        type: :compact,
        command_id: "compact",
        bounds: %{max_attempts: 4, deadline_ms: 60_000, token_budget: 32_768}
      })

    {state, history, events} = commit(state, compact, history, events)
    assert {:ok, ^state} = SessionState.recover(state.session_id, history, events)
    {state, history, events}
  end

  defp row(state, payload),
    do: %{
      payload: payload,
      journal_version: state.journal_version + 1,
      owner_epoch: state.owner_epoch,
      owner_incarnation_id: state.owner_incarnation_id
    }

  defp commit(state, proposal, history, events) do
    rows =
      Enum.with_index(proposal.records, state.journal_version + 1)
      |> Enum.map(fn {payload, version} -> %{row(state, payload) | journal_version: version} end)

    added =
      Enum.with_index(proposal.events, state.event_sequence + 1)
      |> Enum.map(fn {event, sequence} -> Map.put(event, :event_sequence, sequence) end)

    receipt = %{
      journal_versions: %{
        first: state.journal_version + 1,
        last: state.journal_version + length(rows)
      },
      event_sequences:
        if(added == [],
          do: nil,
          else: %{first: state.event_sequence + 1, last: state.event_sequence + length(added)}
        )
    }

    {:ok, next} = SessionState.commit_proposal(proposal, receipt)
    {next, history ++ rows, events ++ added}
  end
end
