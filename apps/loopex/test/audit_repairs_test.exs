Code.require_file("support/m1_runtime_helper.exs", __DIR__)

defmodule Loopex.AuditRepairsTest do
  @moduledoc """
  Drafted cases for the audit repairs to the publication fence, the shared Store
  item normalizer, and command replay. Each case names the production clause it
  would fail without.
  """

  use ExUnit.Case, async: false

  alias Loopex.M1RuntimeTestStore
  alias Loopex.Runtime.SessionState
  alias Loopex.Store

  # Concept: the fence withholds a durable row from a consumer that attached
  # after it was written, not only from one attached before.
  #
  # Technical depth: the store commits the prompt admission and then holds the
  # owner's result, which is exactly the shape of an unresolved commit: the
  # outbox row is durable, the owner has not returned, and Control has therefore
  # not acknowledged it. Deleting the bound in `scan_bound/2`, or the truncation
  # in `scan_event_pages/5`, anchors the new attachment at the durable tail --
  # the snapshot then reports the withheld row's position and `seen` starts past
  # it, so the row is never delivered on the event plane at all.
  test "an attachment installed during an unresolved commit is fenced at the acknowledged position" do
    fixture = start_fixture("fence-attach-runtime")
    on_exit(fn -> stop_fixture(fixture) end)

    session_id = create_session!(fixture, "create-fence-attach")
    {:ok, original} = Loopex.attach(fixture.runtime, session_id, after_event_sequence: 0)

    :ok = M1RuntimeTestStore.delay_after_record(fixture.store_pid, "prompt_admitted_v2", self())

    held =
      Task.async(fn ->
        Loopex.command(original, %{
          type: :prompt,
          command_id: "held-prompt",
          content: "held"
        })
      end)

    assert_receive {:record_linearized, waiter, _store, "prompt_admitted_v2", _transition,
                    {:committed, _tx_id, _receipt}},
                   5_000

    assert committed_event_count(fixture, session_id) == 1

    {:ok, fenced} = Loopex.attach(fixture.runtime, session_id, request_id: "fenced-attach")

    assert %{session_id: ^session_id, event_sequence: 0, active_run_id: nil} =
             Loopex.snapshot(fenced)

    assert {:error, :empty} = Loopex.next_event(fenced)

    M1RuntimeTestStore.release(waiter)
    assert {:accepted, "held-prompt"} = Task.await(held, 5_000)

    assert [%{event_sequence: 1, kind: "user.message_appended"}] = drain_events(fenced)
  end

  # Technical depth: the positive companion. Deleting the watermark clause of
  # `publishable_limit/2` -- the `{:ok, acknowledged}` branch -- makes the first
  # read return the unresolved row, which this case refuses before the release.
  test "an unacknowledged row is withheld from next_event and released after post commit" do
    fixture = start_fixture("fence-pump-runtime")
    on_exit(fn -> stop_fixture(fixture) end)

    session_id = create_session!(fixture, "create-fence-pump")
    {:ok, reader} = Loopex.attach(fixture.runtime, session_id, after_event_sequence: 0)

    :ok = M1RuntimeTestStore.delay_after_record(fixture.store_pid, "prompt_admitted_v2", self())

    held =
      Task.async(fn ->
        Loopex.command(reader, %{
          type: :prompt,
          command_id: "withheld-prompt",
          content: "withheld"
        })
      end)

    assert_receive {:record_linearized, waiter, _store, "prompt_admitted_v2", _transition,
                    {:committed, _tx_id, _receipt}},
                   5_000

    assert committed_event_count(fixture, session_id) == 1
    assert {:error, :empty} = Loopex.next_event(reader)

    M1RuntimeTestStore.release(waiter)
    assert {:accepted, "withheld-prompt"} = Task.await(held, 5_000)

    assert [%{event_sequence: 1, kind: "user.message_appended"}] = drain_events(reader)
  end

  # Concept: one normalizer means one answer to "may this item be stored".
  #
  # Technical depth: the preflight, the builder, and the transaction validator
  # are compared over the same items. Restoring either legacy traversal fails
  # the depth-13 witness (the builder admitted a scalar the preflight refuses)
  # and the 1,025-cell witness (the builder asked `length/1` of an untrusted
  # list and reported an ordinary invalid-data refusal instead of the
  # dimension).
  test "the item preflight, the builders, and transaction validation agree on every item" do
    {store_pid, store} = M1RuntimeTestStore.start_store(label: "normalizer-parity")
    on_exit(fn -> if Process.alive?(store_pid), do: GenServer.stop(store_pid) end)

    depth_13_scalar = nested_maps(12, "leaf")
    admitted_depth = nested_maps(11, "leaf")
    oversized_list = Enum.to_list(1..1_025)
    admitted_list = Enum.to_list(1..1_024)

    values = [
      {"scalar", "plain"},
      {"list", ["a", 1, true, nil]},
      {"nested", %{:atom_key => "normalized", "deep" => %{"list" => [1, 2, 3]}}},
      {"admitted-depth", admitted_depth},
      {"admitted-cardinality", admitted_list},
      {"depth-13-scalar", depth_13_scalar},
      {"cardinality-1025", oversized_list},
      {"improper", improper_list(1_025, {:unvisited, self()})},
      {"runtime-term", self()},
      {"struct", ~D[2026-01-01]}
    ]

    for {label, value} <- values do
      record = %{:kind => "parity", "value" => value}
      event = %{:event_id => "event-#{label}", :kind => "parity", "value" => value}

      assert_agrees(store, :record, record, label)
      assert_agrees(store, :event, event, label)
    end
  end

  # Concept: an unknown durable refusal token is refused, not raised on.
  #
  # Technical depth: restoring `String.to_existing_atom/1` makes this case raise
  # `ArgumentError` out of recovery on any VM that has not already loaded the
  # atom, which is the whole defect: whether durable history replays depended on
  # which modules happened to be loaded.
  test "replaying an unknown command refusal token refuses the record instead of raising" do
    records = [
      %{
        journal_version: 1,
        owner_epoch: 0,
        owner_incarnation_id: nil,
        payload: %{
          :kind => "session_genesis_v2",
          "options" => %{},
          "runtime_configuration" => %{"cleanup_grace_ms" => 1_000}
        }
      },
      %{
        journal_version: 2,
        owner_epoch: 1,
        owner_incarnation_id: "incarnation-1",
        payload: %{
          :kind => "owner_advanced",
          "prior_owner_epoch" => 0,
          "owner_epoch" => 1,
          "owner_incarnation_id" => "incarnation-1",
          "owner_transaction_id" => "owner-transaction-1"
        }
      }
    ]

    for known <- [
          "rejected_run_mismatch",
          "rejected_steer_pending",
          "rejected_no_active_run",
          "rejected_follow_up_pending"
        ] do
      assert {:ok, _state} =
               SessionState.recover("session", records ++ [refusal_record(known)], [])
    end

    assert {:error, :invalid_command_transition} =
             SessionState.recover(
               "session",
               records ++ [refusal_record("rejected_reason_from_another_version")],
               []
             )
  end

  defp refusal_record(admission) do
    %{
      journal_version: 3,
      owner_epoch: 1,
      owner_incarnation_id: "incarnation-1",
      payload: %{
        :kind => "command_admitted",
        "command_id" => "command-1",
        "command_digest" => "digest-1",
        "command_type" => "steer",
        "admission" => admission
      }
    }
  end

  defp assert_agrees(store, :record, record, label) do
    preflight = Store.normalize_and_measure_item(:record, record)
    built = Store.create_session("runtime-#{label}", "command-#{label}", record)

    assert refusal(preflight) == refusal(built),
           "record #{label}: preflight #{inspect(refusal(preflight))} != builder #{inspect(refusal(built))}"

    case {preflight, built} do
      {{:ok, normalized, _bytes}, {:ok, transaction}} ->
        assert transaction.genesis == normalized
        assert :ok = Store.validate_transaction(transaction)
        assert {:committed, _command_id, _receipt} = Store.transact(store, transaction)

      _refused ->
        :ok
    end
  end

  defp assert_agrees(_store, :event, event, label) do
    preflight = Store.normalize_and_measure_item(:event, event)

    built =
      Store.session_commit(
        "session-#{label}",
        "session-#{label}",
        "tx-#{label}",
        0,
        "incarnation",
        0,
        [%{kind: "private"}],
        [event]
      )

    assert refusal(preflight) == refusal(built),
           "event #{label}: preflight #{inspect(refusal(preflight))} != builder #{inspect(refusal(built))}"

    case {preflight, built} do
      {{:ok, normalized, _bytes}, {:ok, transaction}} ->
        assert transaction.outbox == [normalized]
        assert :ok = Store.validate_transaction(transaction)

      _refused ->
        :ok
    end
  end

  # Technical depth: the comparison is the refusal *dimension*, not the atom.
  # A list builder still collapses an ordinary invalid member into its own
  # result, which carries no dimension to disagree about; a structural or size
  # refusal names one and must be identical on both paths.
  defp refusal({:ok, _item, _bytes}), do: :ok
  defp refusal({:ok, _transaction}), do: :ok

  defp refusal({:error, {:item_structure_exceeded, dimension, observed, limit}}),
    do: {:item_structure_exceeded, dimension, observed, limit}

  defp refusal({:error, {:item_too_large, observed, limit}}),
    do: {:item_too_large, observed, limit}

  defp refusal({:error, _ordinary}), do: :invalid_data

  defp nested_maps(0, leaf), do: leaf
  defp nested_maps(depth, leaf), do: %{"deeper" => nested_maps(depth - 1, leaf)}

  defp improper_list(0, tail), do: tail
  defp improper_list(count, tail), do: [count | improper_list(count - 1, tail)]

  defp start_fixture(runtime_id, options \\ []) do
    {store_pid, store} = M1RuntimeTestStore.start_store(label: runtime_id)

    runtime_options =
      options
      |> Keyword.put(:runtime_id, runtime_id)
      |> Keyword.put(:store, store)
      |> Keyword.put_new(:context_token_budget, 8_192)

    {:ok, runtime} = Loopex.start_link(runtime_options)

    %{runtime: runtime, runtime_id: runtime_id, store: store, store_pid: store_pid}
  end

  defp stop_fixture(fixture) do
    if Loopex.Runtime.alive?(fixture.runtime), do: Loopex.stop(fixture.runtime)
    if Process.alive?(fixture.store_pid), do: GenServer.stop(fixture.store_pid)
  end

  defp create_session!(fixture, command_id) do
    assert {:ok, session_id} = Loopex.create_session(fixture.runtime, %{}, command_id: command_id)
    session_id
  end

  defp drain_events(attachment, accumulated \\ []) do
    case Loopex.next_event(attachment) do
      {:ok, event} -> drain_events(attachment, [event | accumulated])
      {:error, :empty} -> Enum.reverse(accumulated)
    end
  end

  defp committed_event_count(fixture, session_id) do
    fixture.store_pid
    |> M1RuntimeTestStore.inspect_state()
    |> Map.fetch!(:sessions)
    |> Map.fetch!(session_id)
    |> Map.fetch!(:events)
    |> length()
  end
end
