Code.require_file("support/m1_runtime_helper.exs", __DIR__)
Code.require_file("support/m5_query_fault_store.exs", __DIR__)
Code.require_file("support/agent_loop_helper.exs", __DIR__)
Code.require_file("support/configured_genesis_helper.exs", __DIR__)

defmodule Loopex.CreateHistoryQueryTest do
  use ExUnit.Case, async: false

  alias Loopex.M1RuntimeTestStore
  alias Loopex.M5QueryFaultStore
  alias Loopex.Runtime
  alias Loopex.Runtime.SessionGenesis
  alias Loopex.Store
  alias LoopexProtocol.ToolDefinition

  test "retained v2 and v3 lookup survives changed defaults and unavailable current routes" do
    for version <- [2, 3] do
      fixture =
        Loopex.AgentLoopFixture.start(
          tools: [ToolDefinition.question_definition()],
          cleanup_grace_ms: 1_500,
          script: []
        )

      on_exit(fn -> Loopex.AgentLoopFixture.stop(fixture) end)
      options = %{purpose: "retained"}

      before_invalid_create = M1RuntimeTestStore.inspect_state(fixture.store)

      for invalid <- [:legacy, nil, [], "session_genesis_v2"] do
        assert {:error, :invalid_session_creation} =
                 Loopex.create_session(fixture.runtime, options,
                   command_id: "invalid",
                   genesis: invalid
                 )
      end

      assert before_invalid_create == M1RuntimeTestStore.inspect_state(fixture.store)

      genesis =
        case version do
          2 ->
            {:ok, resolved} =
              SessionGenesis.resolve(options, %{
                genesis_version: "session_genesis_v2",
                runtime_configuration: %{"cleanup_grace_ms" => 1_500}
              })

            resolved

          3 ->
            Loopex.ConfiguredGenesisFixture.genesis(fixture.definitions)
            |> Map.put("options", %{"purpose" => "retained"})
            |> put_in(["runtime_configuration", "cleanup_grace_ms"], 1_500)
        end

      assert {:ok, session} =
               Loopex.create_session(fixture.runtime, options,
                 command_id: "exact",
                 genesis: genesis
               )

      assert {:ok, ^session} =
               Loopex.create_session(fixture.runtime, options,
                 command_id: "exact",
                 genesis: genesis
               )

      before_conflict = M1RuntimeTestStore.inspect_state(fixture.store)
      changed = put_in(genesis, ["runtime_configuration", "cleanup_grace_ms"], 1_501)

      assert {:error, :tx_id_conflict} =
               Loopex.create_session(fixture.runtime, options,
                 command_id: "exact",
                 genesis: changed
               )

      assert {:error, :invalid_session_creation} =
               Loopex.create_session(fixture.runtime, %{},
                 command_id: "mismatched",
                 genesis: genesis
               )

      assert {:error, :command_id_required} =
               Loopex.create_session(fixture.runtime, options, genesis: genesis)

      assert {:error, :invalid_session_creation} =
               Loopex.create_session(fixture.runtime, options, ["not-keyword"])

      assert before_conflict == M1RuntimeTestStore.inspect_state(fixture.store)

      :ok = Loopex.stop(fixture.runtime)
      {:ok, store} = Store.new(M1RuntimeTestStore, fixture.store)

      # No selected tools or model route exist in this successor. Historical
      # lookup must require neither fresh registration nor coordinator startup.
      {:ok, successor} =
        Loopex.start_link(
          runtime_id: "agent-loop-runtime",
          context_token_budget: 8_192,
          cleanup_grace_ms: 3_000,
          store: store
        )

      on_exit(fn -> stop_runtime(successor) end)
      {:ok, %{sessions: supervisor}} = Runtime.children(successor)
      assert DynamicSupervisor.which_children(supervisor) == []
      before = M1RuntimeTestStore.inspect_state(fixture.store)

      assert {:ok, {:historical, ^session}} =
               Runtime.lookup_create_result(successor, "exact", options, genesis)

      assert {:ok, {:historical, ^session}} =
               Runtime.lookup_create_result(
                 successor,
                 "exact",
                 %{"purpose" => "retained"},
                 genesis
               )

      assert {:ok, :conflict} = Runtime.lookup_create_result(successor, "exact", options)
      assert {:ok, :absent} = Runtime.lookup_create_result(successor, "missing", options, genesis)

      altered = put_in(genesis, ["runtime_configuration", "cleanup_grace_ms"], 1_501)
      assert {:ok, :conflict} = Runtime.lookup_create_result(successor, "exact", options, altered)

      for invalid <- [
            :legacy,
            nil,
            %{},
            Map.put(genesis, "extra", true),
            Map.delete(genesis, "options")
          ] do
        assert {:ok, :unexpected} =
                 Runtime.lookup_create_result(successor, "exact", options, invalid)
      end

      for invalid <- [nil, %{"purpose" => "other"}, %{purpose: self()}] do
        assert {:ok, :unexpected} =
                 Runtime.lookup_create_result(successor, "exact", invalid, genesis)
      end

      assert {:ok, :unexpected} = Runtime.lookup_create_result(successor, "", options, genesis)
      assert before == M1RuntimeTestStore.inspect_state(fixture.store)
      assert DynamicSupervisor.which_children(supervisor) == []
    end
  end

  test "exact create history is returned without a write or coordinator start" do
    {store_pid, store} = M1RuntimeTestStore.start_store()
    runtime = start_runtime!("history-exact", store)

    on_exit(fn -> stop_runtime(runtime) end)
    on_exit(fn -> stop_store(store_pid) end)

    options = %{"purpose" => "history"}

    assert {:ok, session_id} =
             Loopex.create_session(runtime, options, command_id: "create-history")

    {:ok, %{sessions: supervisor}} = Runtime.children(runtime)
    coordinators_before = DynamicSupervisor.which_children(supervisor)
    store_before = M1RuntimeTestStore.inspect_state(store_pid)

    assert {:ok, {:historical, ^session_id}} =
             Runtime.lookup_create_result(runtime, "create-history", options)

    assert store_before == M1RuntimeTestStore.inspect_state(store_pid)
    assert coordinators_before == DynamicSupervisor.which_children(supervisor)

    assert {:ok, :conflict} =
             Runtime.lookup_create_result(runtime, "create-history", %{"purpose" => "changed"})

    assert store_before == M1RuntimeTestStore.inspect_state(store_pid)
    assert coordinators_before == DynamicSupervisor.which_children(supervisor)
  end

  test "absent, cross-kind conflict, and invalid input have distinct results" do
    {store_pid, store} = M1RuntimeTestStore.start_store()
    runtime = start_runtime!("history-domain", store)

    on_exit(fn -> stop_runtime(runtime) end)
    on_exit(fn -> stop_store(store_pid) end)

    assert {:ok, :absent} = Runtime.lookup_create_result(runtime, "missing", %{})
    assert {:ok, :unexpected} = Runtime.lookup_create_result(runtime, "", %{})
    assert {:ok, :unexpected} = Runtime.lookup_create_result(runtime, "bad-options", :invalid)

    assert {:ok, session_id} =
             Loopex.create_session(runtime, %{}, command_id: "create-session")

    assert {:ok, ^session_id} = Runtime.resume_session(runtime, session_id, "cross-kind")
    assert {:ok, :conflict} = Runtime.lookup_create_result(runtime, "cross-kind", %{})

    assert {:ok, :conflict} =
             Runtime.lookup_create_result(runtime, "cross-kind", %{}, v2_genesis())
  end

  test "Store unavailability and malformed output remain domain results" do
    for reference <- [:unavailable, :malformed] do
      {:ok, store} = Store.new(M5QueryFaultStore, reference)
      runtime = start_runtime!("history-#{reference}", store)
      on_exit(fn -> stop_runtime(runtime) end)

      assert {:ok, :store_unavailable} =
               Runtime.lookup_create_result(runtime, "create", %{})

      assert {:ok, :store_unavailable} =
               Runtime.lookup_create_result(runtime, "create", %{}, v2_genesis())
    end
  end

  test "loss of the exact Control process is runtime unavailability" do
    {:ok, store} = Store.new(M5QueryFaultStore, :kill_control)
    runtime = start_runtime!("history-control-loss", store)
    on_exit(fn -> stop_runtime(runtime) end)

    assert {:error, :runtime_unavailable} =
             Runtime.lookup_create_result(runtime, "create", %{})
  end

  test "exact-history lookup preserves Control loss and requires a live runtime reference" do
    {:ok, store} = Store.new(M5QueryFaultStore, :kill_control)
    runtime = start_runtime!("exact-history-control-loss", store)
    on_exit(fn -> stop_runtime(runtime) end)

    assert {:error, :runtime_unavailable} =
             Runtime.lookup_create_result(runtime, "create", %{}, v2_genesis())

    assert {:error, :runtime_unavailable} =
             Runtime.lookup_create_result(nil, "create", %{}, v2_genesis())
  end

  defp v2_genesis do
    {:ok, genesis} =
      SessionGenesis.resolve(%{}, %{
        genesis_version: "session_genesis_v2",
        runtime_configuration: %{"cleanup_grace_ms" => 5_000}
      })

    genesis
  end

  defp start_runtime!(runtime_id, store) do
    {:ok, runtime} =
      Loopex.start_link(context_token_budget: 8_192, runtime_id: runtime_id, store: store)

    runtime
  end

  defp stop_runtime(runtime) do
    if Runtime.alive?(runtime), do: Loopex.stop(runtime)
  end

  defp stop_store(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid)
  end
end
