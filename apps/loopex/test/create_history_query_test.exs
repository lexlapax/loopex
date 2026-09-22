Code.require_file("support/m1_runtime_helper.exs", __DIR__)
Code.require_file("support/m5_query_fault_store.exs", __DIR__)

defmodule Loopex.CreateHistoryQueryTest do
  use ExUnit.Case, async: false

  alias Loopex.M1RuntimeTestStore
  alias Loopex.M5QueryFaultStore
  alias Loopex.Runtime
  alias Loopex.Store

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
  end

  test "Store unavailability and malformed output remain domain results" do
    for reference <- [:unavailable, :malformed] do
      {:ok, store} = Store.new(M5QueryFaultStore, reference)
      runtime = start_runtime!("history-#{reference}", store)
      on_exit(fn -> stop_runtime(runtime) end)

      assert {:ok, :store_unavailable} =
               Runtime.lookup_create_result(runtime, "create", %{})
    end
  end

  test "loss of the exact Control process is runtime unavailability" do
    {:ok, store} = Store.new(M5QueryFaultStore, :kill_control)
    runtime = start_runtime!("history-control-loss", store)
    on_exit(fn -> stop_runtime(runtime) end)

    assert {:error, :runtime_unavailable} =
             Runtime.lookup_create_result(runtime, "create", %{})
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
