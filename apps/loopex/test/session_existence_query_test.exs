Code.require_file("support/m1_runtime_helper.exs", __DIR__)
Code.require_file("support/m5_query_fault_store.exs", __DIR__)

defmodule Loopex.SessionExistenceQueryTest do
  use ExUnit.Case, async: false

  alias Loopex.M1RuntimeTestStore
  alias Loopex.M5QueryFaultStore
  alias Loopex.Runtime
  alias Loopex.Store

  test "the four domain results are read-only and runtime loss stays outside them" do
    {store_pid, store} = M1RuntimeTestStore.start_store()
    runtime = start_runtime!("existence-domain", store)

    on_exit(fn -> stop_runtime(runtime) end)
    on_exit(fn -> stop_store(store_pid) end)

    before_invalid = M1RuntimeTestStore.inspect_state(store_pid)
    assert {:ok, :invalid_id} = Runtime.session_existence(runtime, "")
    assert before_invalid == M1RuntimeTestStore.inspect_state(store_pid)

    before_absent = M1RuntimeTestStore.inspect_state(store_pid)
    assert {:ok, :absent} = Runtime.session_existence(runtime, "missing")
    assert before_absent == M1RuntimeTestStore.inspect_state(store_pid)

    assert {:ok, session_id} =
             Loopex.create_session(runtime, %{"purpose" => "existence"}, command_id: "create")

    before_present = M1RuntimeTestStore.inspect_state(store_pid)
    assert {:ok, :present} = Runtime.session_existence(runtime, session_id)
    assert before_present == M1RuntimeTestStore.inspect_state(store_pid)

    :ok = M1RuntimeTestStore.fail_reads(store_pid, true)
    before_unavailable = M1RuntimeTestStore.inspect_state(store_pid)
    assert {:ok, :store_unavailable} = Runtime.session_existence(runtime, session_id)
    assert before_unavailable == M1RuntimeTestStore.inspect_state(store_pid)
  end

  test "malformed adapter output is Store unavailability" do
    {:ok, store} = Store.new(M5QueryFaultStore, :malformed)
    runtime = start_runtime!("existence-malformed", store)
    on_exit(fn -> stop_runtime(runtime) end)

    assert {:ok, :store_unavailable} = Runtime.session_existence(runtime, "session")
  end

  test "loss of the exact Control process is runtime unavailability" do
    {:ok, store} = Store.new(M5QueryFaultStore, :kill_control)
    runtime = start_runtime!("existence-control-loss", store)
    on_exit(fn -> stop_runtime(runtime) end)

    assert {:error, :runtime_unavailable} = Runtime.session_existence(runtime, "session")
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
