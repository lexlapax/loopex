Code.require_file("support/m1_runtime_helper.exs", __DIR__)
Code.require_file("support/agent_loop_helper.exs", __DIR__)
Code.require_file("support/configured_genesis_helper.exs", __DIR__)

defmodule Loopex.Runtime.MaintenanceProviderAttemptTest do
  use ExUnit.Case, async: false

  alias Loopex.AgentLoopFixture, as: Fixture
  alias Loopex.AgentLoopTestModel
  alias Loopex.ConfiguredGenesisFixture, as: Genesis
  alias Loopex.M1RuntimeTestStore
  alias Loopex.Runtime.{Control, ProviderAttempt}
  alias Loopex.Store

  @uint64_max 18_446_744_073_709_551_615

  test "maintenance opens retain episode identity and never invent an ordinary run or turn" do
    assert {:ok, opened} = ProviderAttempt.opened_record(identity())

    assert opened == %{
             :kind => "maintenance_attempt_opened_v1",
             "episode_id" => "episode-1",
             "summary_ordinal" => 1,
             "purpose" => "compaction",
             "operation_id" => "summary-operation-1",
             "attempt" => 1,
             "staged_request_digest" => String.duplicate("d", 64)
           }

    assert ProviderAttempt.validate_opened(opened) == :ok
    assert {:ok, binding} = ProviderAttempt.binding_from_opened("session-1", opened)
    assert binding == Map.put(Map.delete(opened, :kind), "session_id", "session-1")
    assert ProviderAttempt.validate_binding(binding) == :ok
    refute Map.has_key?(binding, "run_id")
    refute Map.has_key?(binding, "turn_id")

    string_kind = opened |> Map.delete(:kind) |> Map.put("kind", opened.kind)
    assert ProviderAttempt.binding_from_opened("session-1", string_kind) == {:ok, binding}

    for ordinal <- [1, @uint64_max], attempt <- [1, 2] do
      assert {:ok, _} =
               ProviderAttempt.opened_record(%{
                 identity()
                 | summary_ordinal: ordinal,
                   attempt: attempt
               })
    end
  end

  test "maintenance identities and kinds are closed at record and permit boundaries" do
    {:ok, opened} = ProviderAttempt.opened_record(identity())
    {:ok, binding} = ProviderAttempt.binding_from_opened("session-1", opened)

    changed = [
      {"episode_id", ""},
      {"episode_id", String.duplicate("x", 513)},
      {"summary_ordinal", 0},
      {"summary_ordinal", @uint64_max + 1},
      {"summary_ordinal", 1.0},
      {"purpose", "ordinary"},
      {"operation_id", ""},
      {"attempt", 0},
      {"attempt", 3},
      {"staged_request_digest", String.duplicate("D", 64)}
    ]

    for {key, value} <- changed do
      assert {:error, _} = ProviderAttempt.validate_opened(Map.put(opened, key, value))

      assert ProviderAttempt.validate_binding(Map.put(binding, key, value)) ==
               {:error, :invalid_provider_attempt_binding}
    end

    for key <- Map.keys(binding) do
      assert ProviderAttempt.validate_binding(Map.delete(binding, key)) ==
               {:error, :invalid_provider_attempt_binding}
    end

    for {key, value} <- [
          {"run_id", "run-1"},
          {"turn_id", "turn-1"},
          {"extra", true},
          {:kind, "maintenance_attempt_opened_v1"},
          {"kind", "maintenance_attempt_opened_v1"}
        ] do
      assert ProviderAttempt.validate_binding(Map.put(binding, key, value)) ==
               {:error, :invalid_provider_attempt_binding}
    end

    for candidate <- [
          Map.delete(opened, :kind),
          Map.put(opened, :kind, "model_attempt_opened_v1"),
          Map.put(opened, :kind, "maintenance_attempt_settled_v3"),
          Map.put(opened, "run_id", "run-1"),
          Map.put(opened, "turn_id", "turn-1"),
          Map.put(opened, "kind", "maintenance_attempt_opened_v1")
        ] do
      assert ProviderAttempt.binding_from_opened("session-1", candidate) ==
               {:error, :invalid_provider_attempt_binding}
    end

    assert ProviderAttempt.opened_record(%{identity() | purpose: "ordinary"}) ==
             {:error, :invalid_attempt_identity}

    assert ProviderAttempt.opened_record(Map.put(identity(), :run_id, "run-1")) ==
             {:error, :invalid_attempt_identity}

    assert ProviderAttempt.opened_record(Map.put(identity(), :turn_id, "turn-1")) ==
             {:error, :invalid_attempt_identity}
  end

  # Concept: the existing Control handler authorizes only the retained summary
  # attempt at the current position, once, under the current owner and deadline.
  # Technical depth: this boundary fixture writes the accepted open row through
  # Store and acknowledges its actual receipt to Control. It submits the same
  # private owner-call envelope used by the ordinary permit tests. It invokes no
  # provider and does not claim episode/request reducer or live compaction proof.
  test "Control spends one maintenance permit from its exact committed row" do
    {fixture, session, control, entry} = fixture()
    {:ok, opened} = ProviderAttempt.opened_record(identity())
    {:ok, binding} = ProviderAttempt.binding_from_opened(session, opened)
    {worker, monitor} = worker()

    assert dispatch(control, entry, binding, worker, entry.journal_version) ==
             {:error, :invalid_provider_attempt_binding}

    refute_received {:permit_received, ^worker, _}

    {:ok, store} = Store.new(M1RuntimeTestStore, fixture.store)

    {:ok, transaction} =
      Store.session_commit(
        session,
        "session",
        "maintenance-open-boundary",
        entry.owner.owner_epoch,
        entry.owner.owner_incarnation_id,
        entry.journal_version,
        [opened],
        []
      )

    assert {:committed, _tx, receipt} = Store.transact(store, transaction)
    position = receipt.journal_versions.last

    assert :ok =
             Control.post_commit(
               control,
               session,
               entry.owner,
               %{journal_version: position, event_sequence: entry.event_sequence},
               receipt
             )

    for changed <- [
          Map.put(binding, "episode_id", "other-episode"),
          Map.put(binding, "summary_ordinal", 2),
          Map.put(binding, "operation_id", "other-operation"),
          Map.put(binding, "attempt", 2),
          Map.put(binding, "staged_request_digest", String.duplicate("a", 64))
        ] do
      assert dispatch(control, entry, changed, worker, position) ==
               {:error, :invalid_provider_attempt_binding}
    end

    assert dispatch(control, entry, binding, worker, position, deadline: 0) ==
             {:error, :deadline_elapsed}

    assert dispatch(control, entry, binding, worker, entry.journal_version) ==
             {:error, :stale_attempt_open_position}

    assert dispatch(control, entry, binding, worker, position) == {:ok, :dispatched}

    assert_receive {:permit_received, ^worker, {:loopex_provider_permit, _reference, ^binding}},
                   5_000

    assert dispatch(control, entry, binding, worker, position) ==
             {:error, :provider_attempt_already_permitted}

    assert Map.keys(:sys.get_state(control).spent_attempts) == [binding]
    assert AgentLoopTestModel.dispatched(fixture.model) == []
    stop_worker(worker, monitor)
    stop_fixture(fixture, entry.coordinator, control)
  end

  defp identity do
    %{
      episode_id: "episode-1",
      summary_ordinal: 1,
      purpose: "compaction",
      operation_id: "summary-operation-1",
      attempt: 1,
      staged_request_digest: String.duplicate("d", 64)
    }
  end

  defp fixture do
    fixture = Fixture.start(script: [], tools: [])
    on_exit(fn -> Fixture.stop(fixture) end)

    {:ok, session} =
      Loopex.create_session(fixture.runtime, %{},
        command_id: "create",
        genesis: Genesis.genesis([])
      )

    {:ok, %{control: control}} = Loopex.Runtime.children(fixture.runtime)
    entry = :sys.get_state(control).sessions[session]
    {fixture, session, control, entry}
  end

  defp worker do
    observer = self()

    {pid, monitor} =
      spawn_monitor(fn ->
        receive do
          {:loopex_provider_permit, _, _} = permit ->
            send(observer, {:permit_received, self(), permit})
            receive do: (:stop -> :ok)

          :stop ->
            :ok
        end
      end)

    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)
    {pid, monitor}
  end

  defp dispatch(control, entry, binding, worker, position, options \\ []) do
    authority = %{
      runtime_id: :sys.get_state(control).runtime_id,
      owner: entry.owner,
      coordinator: entry.coordinator,
      worker: worker,
      permit_reference: make_ref(),
      journal_version: position,
      deadline: Keyword.get(options, :deadline, System.system_time(:millisecond) + 60_000)
    }

    reply_alias = :erlang.alias([:reply])

    send(
      control,
      {:"$gen_call", {entry.coordinator, [:alias | reply_alias]},
       {:provider_dispatch, binding, authority}}
    )

    assert_receive {[:alias | ^reply_alias], result}, 5_000
    :erlang.unalias(reply_alias)
    result
  end

  defp stop_worker(pid, monitor) do
    send(pid, :stop)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 5_000
  end

  defp stop_fixture(fixture, coordinator, control) do
    monitors = Enum.map([coordinator, control], &{&1, Process.monitor(&1)})
    assert :ok = Loopex.stop(fixture.runtime)

    for {pid, monitor} <- monitors do
      assert_receive {:DOWN, ^monitor, :process, ^pid, reason}, 5_000
      assert reason in [:normal, :shutdown]
    end
  end
end
