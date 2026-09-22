Code.require_file("support/m1_runtime_helper.exs", __DIR__)

defmodule Loopex.SessionDetailedResultsTest do
  use ExUnit.Case, async: true

  alias Loopex.M1RuntimeTestStore
  alias Loopex.Runtime

  setup do
    fixture = start_fixture("detailed-results")

    on_exit(fn ->
      if Runtime.alive?(fixture.runtime), do: Loopex.stop(fixture.runtime)
      if Process.alive?(fixture.store_pid), do: GenServer.stop(fixture.store_pid)
    end)

    fixture
  end

  test "create distinguishes a started owner from active and dormant replays", fixture do
    assert {:ok,
            %{
              session_id: session_id,
              disposition: :activated,
              control_entry: :active
            }} = Runtime.create_session_detailed(fixture.runtime, "create", %{})

    assert {:ok,
            %{
              session_id: ^session_id,
              disposition: :no_activation,
              control_entry: :active
            }} = Runtime.create_session_detailed(fixture.runtime, "create", %{})

    assert {:ok, ^session_id} = Runtime.create_session(fixture.runtime, "create", %{})

    :ok = Loopex.stop(fixture.runtime)
    {:ok, restarted} = start_runtime(fixture.runtime_id, fixture.store)
    on_exit(fn -> if Runtime.alive?(restarted), do: Loopex.stop(restarted) end)

    assert {:ok,
            %{
              session_id: ^session_id,
              disposition: :no_activation,
              control_entry: :dormant
            }} = Runtime.create_session_detailed(restarted, "create", %{})

    {:ok, %{control: control}} = Runtime.children(restarted)
    assert :sys.get_state(control).sessions == %{}
  end

  test "resume distinguishes fresh activation from a completed replay", fixture do
    session_id = create_session(fixture.runtime, "resume-create")

    assert {:ok,
            %{
              session_id: ^session_id,
              disposition: :activated,
              control_entry: :active
            }} = Runtime.resume_session_detailed(fixture.runtime, session_id, "resume")

    assert {:ok,
            %{
              session_id: ^session_id,
              disposition: :no_activation,
              control_entry: :active
            }} = Runtime.resume_session_detailed(fixture.runtime, session_id, "resume")

    assert {:ok, ^session_id} =
             Runtime.resume_session(fixture.runtime, session_id, "public-shape")
  end

  test "a completed replay observes an independently acquiring entry", fixture do
    session_id = create_session(fixture.runtime, "acquiring-create")

    assert {:ok, %{disposition: :activated}} =
             Runtime.resume_session_detailed(fixture.runtime, session_id, "completed")

    :ok =
      M1RuntimeTestStore.delay_after_commit(
        fixture.store_pid,
        :session_journal_advance_owner,
        self()
      )

    acquiring =
      Task.async(fn ->
        Runtime.resume_session_detailed(fixture.runtime, session_id, "acquiring")
      end)

    assert_receive {:transaction_linearized, waiter, _store, :session_journal_advance_owner,
                    {:committed, _tx_id, _receipt}},
                   5_000

    assert {:ok,
            %{
              session_id: ^session_id,
              disposition: :no_activation,
              control_entry: :acquiring
            }} = Runtime.resume_session_detailed(fixture.runtime, session_id, "completed")

    M1RuntimeTestStore.release(waiter)

    assert {:ok,
            %{
              session_id: ^session_id,
              disposition: :activated,
              control_entry: :active
            }} = Task.await(acquiring, 5_000)
  end

  test "an open resume replay in a replacement runtime starts an owner", fixture do
    session_id = create_session(fixture.runtime, "open-create")

    :ok =
      M1RuntimeTestStore.delay_after_commit(
        fixture.store_pid,
        :runtime_control_stage_owner_attempt,
        self()
      )

    first =
      Task.async(fn ->
        Runtime.resume_session_detailed(fixture.runtime, session_id, "open-resume")
      end)

    assert_receive {:transaction_linearized, waiter, _store, :runtime_control_stage_owner_attempt,
                    {:committed, _tx_id, _receipt}},
                   5_000

    :ok = Loopex.stop(fixture.runtime)
    assert {:error, :runtime_unavailable} = Task.await(first, 5_000)
    M1RuntimeTestStore.release(waiter)

    {:ok, restarted} = start_runtime(fixture.runtime_id, fixture.store)
    on_exit(fn -> if Runtime.alive?(restarted), do: Loopex.stop(restarted) end)

    assert {:ok,
            %{
              session_id: ^session_id,
              disposition: :activated,
              control_entry: :active
            }} = Runtime.resume_session_detailed(restarted, session_id, "open-resume")
  end

  test "placement mismatch is a dormant no-activation domain result", fixture do
    session_id = create_session(fixture.runtime, "placement-create")
    {:ok, other} = start_runtime("different-placement", fixture.store)
    on_exit(fn -> if Runtime.alive?(other), do: Loopex.stop(other) end)

    assert {:error, :runtime_placement_mismatch,
            %{disposition: :no_activation, control_entry: :dormant}} =
             Runtime.resume_session_detailed(other, session_id, "wrong-placement")

    {:ok, %{control: control}} = Runtime.children(other)
    refute Map.has_key?(:sys.get_state(control).sessions, session_id)

    assert {:error, :owner_recovery_failed} =
             Runtime.resume_session(other, session_id, "released-shape")
  end

  test "exact Control loss returns only runtime_unavailable", fixture do
    {:ok, %{control: control}} = Runtime.children(fixture.runtime)
    before = M1RuntimeTestStore.inspect_state(fixture.store_pid)
    :ok = :sys.suspend(control)

    caller =
      Task.async(fn ->
        Runtime.create_session_detailed(fixture.runtime, "lost-control", %{})
      end)

    assert_eventually(fn ->
      case Process.info(control, :messages) do
        {:messages, messages} ->
          Enum.any?(messages, fn
            {:"$gen_call", {caller_pid, _tag},
             {:create_session, _token, "lost-control", %{}, :detailed}} ->
              caller_pid == caller.pid

            _other ->
              false
          end)

        nil ->
          false
      end
    end)

    monitor = Process.monitor(control)
    Process.exit(control, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^control, :killed}, 2_000
    assert {:error, :runtime_unavailable} = Task.await(caller, 5_000)
    assert before == M1RuntimeTestStore.inspect_state(fixture.store_pid)
  end

  test "Control loss after child start still returns no fabricated metadata", fixture do
    session_id = create_session(fixture.runtime, "started-before-control-loss")

    :ok =
      M1RuntimeTestStore.delay_after_commit(
        fixture.store_pid,
        :session_journal_advance_owner,
        self()
      )

    caller =
      Task.async(fn ->
        Runtime.resume_session_detailed(fixture.runtime, session_id, "lost-after-start")
      end)

    assert_receive {:transaction_linearized, waiter, _store, :session_journal_advance_owner,
                    {:committed, _tx_id, _receipt}},
                   5_000

    {:ok, %{control: control}} = Runtime.children(fixture.runtime)
    assert :sys.get_state(control).sessions[session_id].status == :acquiring

    monitor = Process.monitor(control)
    Process.exit(control, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^control, :killed}, 2_000
    assert {:error, :runtime_unavailable} = Task.await(caller, 5_000)
    M1RuntimeTestStore.release(waiter)
  end

  defp start_fixture(runtime_id) do
    {store_pid, store} = M1RuntimeTestStore.start_store(label: runtime_id)
    {:ok, runtime} = start_runtime(runtime_id, store)
    %{runtime: runtime, runtime_id: runtime_id, store: store, store_pid: store_pid}
  end

  defp start_runtime(runtime_id, store) do
    Loopex.start_link(
      context_token_budget: 8_192,
      runtime_id: runtime_id,
      store: store
    )
  end

  defp create_session(runtime, command_id) do
    assert {:ok, session_id} = Runtime.create_session(runtime, command_id, %{})
    session_id
  end

  defp assert_eventually(assertion, attempts \\ 200)
  defp assert_eventually(_assertion, 0), do: flunk("condition did not become true")

  defp assert_eventually(assertion, attempts) do
    if assertion.() do
      :ok
    else
      Process.sleep(5)
      assert_eventually(assertion, attempts - 1)
    end
  end
end
