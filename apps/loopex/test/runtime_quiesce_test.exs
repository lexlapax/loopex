Code.require_file("support/m1_runtime_helper.exs", __DIR__)

defmodule Loopex.RuntimeQuiesceTest do
  @moduledoc """
  ## Concept

  Orderly runtime shutdown begins with one terminal admission gate. The gate
  freezes the sessions that have ever owned a writer in this runtime and makes
  later session creation, activation, attachment and command routes refuse.

  ## Technical depth

  These foundation cases exercise the serialized Control transition directly.
  Later cases in this module drive the complete `Runtime.quiesce/1` phase owner,
  drain and fence path while retaining these cut-order witnesses.
  """

  use ExUnit.Case, async: true

  alias Loopex.M1RuntimeTestStore
  alias Loopex.Runtime
  alias Loopex.Runtime.Control
  alias Loopex.Runtime.SessionCoordinator
  alias Loopex.Runtime.SessionState

  test "the first gate freezes writer domains and later admission refuses before Store access" do
    fixture = fixture("quiesce-gate")
    session_id = create_session(fixture.runtime, "create")
    {:ok, attachment} = Loopex.attach(fixture.runtime, session_id)
    {:ok, %{control: control}} = Runtime.children(fixture.runtime)

    assert {:ok,
            [
              %{
                session_id: ^session_id,
                status: :active,
                coordinator: coordinator,
                owner: owner,
                writer_started?: true
              }
            ]} = Control.begin_quiesce(control, fixture.runtime.token, "drain-one", 5_000)

    assert is_pid(coordinator)
    assert is_map(owner)

    before = M1RuntimeTestStore.inspect_state(fixture.store_pid)

    assert {:error, :runtime_unavailable} =
             Runtime.create_session_detailed(fixture.runtime, "after-gate", %{})

    assert {:error, :runtime_unavailable} =
             Runtime.resume_session_detailed(fixture.runtime, session_id, "after-gate")

    assert {:error, :runtime_unavailable} = Loopex.attach(fixture.runtime, session_id)

    assert {:error, :runtime_unavailable} =
             Loopex.command(attachment, %{
               type: :prompt,
               command_id: "after-gate",
               content: "must not be admitted"
             })

    assert {:error, :runtime_unavailable} = Runtime.session_status(fixture.runtime, session_id)
    assert before == M1RuntimeTestStore.inspect_state(fixture.store_pid)

    assert {:ok, [%{session_id: ^session_id}]} =
             Control.quiesce_projection(control, fixture.runtime.token, "drain-one", 5_000)

    assert {:error, :runtime_unavailable} =
             Control.begin_quiesce(control, fixture.runtime.token, "drain-two", 5_000)

    assert :sys.get_state(control).quiescing == "drain-one"
  end

  test "the projection omits dormant no-writer rows and refuses an impossible 65-writer census" do
    dormant = fixture("quiesce-dormant")
    session_id = create_session(dormant.runtime, "create")
    {:ok, %{control: dormant_control}} = Runtime.children(dormant.runtime)

    dormant_rows =
      Map.new(1..70, fn index ->
        {"dormant-#{index}", %{status: :unavailable, durable: nil, generation: "none"}}
      end)

    :sys.replace_state(dormant_control, fn state ->
      %{state | sessions: Map.merge(state.sessions, dormant_rows)}
    end)

    assert {:ok, [%{session_id: ^session_id}]} =
             Control.begin_quiesce(
               dormant_control,
               dormant.runtime.token,
               "bounded-dormant",
               5_000
             )

    oversized = fixture("quiesce-oversized")
    {:ok, %{control: oversized_control}} = Runtime.children(oversized.runtime)
    writer_domains = MapSet.new(Enum.map(1..65, &"writer-#{&1}"))

    :sys.replace_state(oversized_control, fn state ->
      %{state | writer_domains: writer_domains}
    end)

    assert {:error, :runtime_unavailable} =
             Control.begin_quiesce(
               oversized_control,
               oversized.runtime.token,
               "bounded-refusal",
               5_000
             )

    state = :sys.get_state(oversized_control)
    assert state.quiescing == "bounded-refusal"
    assert state.sessions == %{}
  end

  test "an idle drain refusal closes ordinary coordinator admission" do
    fixture = fixture("quiesce-idle-admission")
    session_id = create_session(fixture.runtime, "create")
    {:ok, %{control: control}} = Runtime.children(fixture.runtime)

    assert {:ok, [%{coordinator: coordinator, owner: owner}]} =
             Control.begin_quiesce(control, fixture.runtime.token, "idle-drain", 5_000)

    assert :rejected_no_active_run =
             SessionCoordinator.admit_quiesce_abort(
               coordinator,
               owner,
               "idle-drain",
               self()
             )

    assert {:error, :runtime_unavailable} =
             SessionCoordinator.command(coordinator, owner, %{
               type: :prompt,
               command_id: "late-prompt",
               content: "must remain outside the journal"
             })

    command_id = SessionState.drain_abort_command_id(session_id, owner.owner_epoch)
    assert command_id == SessionState.drain_abort_command_id(session_id, owner.owner_epoch)
    refute command_id == SessionState.drain_abort_command_id(session_id, owner.owner_epoch + 1)

    {:ok, records} = M1RuntimeTestStore.load_records(fixture.store_pid, session_id, 0, 1_024)
    command_records = Enum.filter(records, &(&1.payload[:kind] == "command_admitted"))

    assert [%{payload: rejected}] = command_records
    assert rejected["command_id"] == command_id
    assert rejected["command_type"] == "abort"
    assert rejected["admission"] == "rejected_no_active_run"
  end

  test "an active drain abort pauses cleanup until the phase owner releases it" do
    fixture = fixture("quiesce-paused-cleanup")
    session_id = create_session(fixture.runtime, "create")
    {:ok, attachment} = Loopex.attach(fixture.runtime, session_id)

    assert {:accepted, "prompt"} =
             Loopex.command(attachment, %{
               type: :prompt,
               command_id: "prompt",
               content: "remain active until drain release"
             })

    {:ok, %{control: control}} = Runtime.children(fixture.runtime)

    assert {:ok, [%{coordinator: coordinator, owner: owner}]} =
             Control.begin_quiesce(control, fixture.runtime.token, "active-drain", 5_000)

    assert {:admitted,
            %{
              command_id: command_id,
              run_id: run_id,
              cleanup_grace_ms: cleanup_grace_ms,
              owner_epoch: owner_epoch
            }} =
             SessionCoordinator.admit_quiesce_abort(
               coordinator,
               owner,
               "active-drain",
               self()
             )

    assert command_id == SessionState.drain_abort_command_id(session_id, owner.owner_epoch)
    assert owner_epoch == owner.owner_epoch
    assert is_binary(run_id)
    assert is_integer(cleanup_grace_ms) and cleanup_grace_ms > 0

    paused = :sys.get_state(coordinator)
    assert paused.drain.status == :paused
    assert paused.drain.run_id == run_id
    assert paused.pending_cleanup == %{}
    assert paused.executor_reserves == %{}

    assert {:error, :runtime_unavailable} =
             SessionCoordinator.command(coordinator, owner, %{
               type: :prompt,
               command_id: "after-drain",
               content: "must not pass the coordinator cut"
             })

    assert :ok =
             SessionCoordinator.release_quiesce_cleanup(
               coordinator,
               owner,
               "active-drain"
             )

    assert_eventually(fn ->
      case SessionCoordinator.session_status(coordinator, owner) do
        {:ok, %{active_run_id: nil, pending_work_ids: []}} -> true
        _other -> false
      end
    end)
  end

  test "an ambiguous drain abort is presented once and releases no cleanup" do
    fixture = fixture("quiesce-ambiguous-admission")
    session_id = create_session(fixture.runtime, "create")
    {:ok, attachment} = Loopex.attach(fixture.runtime, session_id)

    assert {:accepted, "prompt"} =
             Loopex.command(attachment, %{
               type: :prompt,
               command_id: "prompt",
               content: "hold for an ambiguous drain"
             })

    after_linearization = {:session_journal_commit, :after_linearization_before_result}
    recovery_representation = {:session_journal_commit, :recovery_representation}
    :ok = M1RuntimeTestStore.inject(fixture.store_pid, after_linearization)
    :ok = M1RuntimeTestStore.inject(fixture.store_pid, recovery_representation)

    {:ok, %{control: control}} = Runtime.children(fixture.runtime)

    assert {:ok, [%{coordinator: coordinator, owner: owner}]} =
             Control.begin_quiesce(control, fixture.runtime.token, "unknown-drain", 5_000)

    assert {:unknown, %{command_id: command_id, head: head}} =
             SessionCoordinator.admit_quiesce_abort(
               coordinator,
               owner,
               "unknown-drain",
               self()
             )

    assert command_id == SessionState.drain_abort_command_id(session_id, owner.owner_epoch)
    assert head.owner_epoch == owner.owner_epoch
    assert is_integer(head.journal_version)

    observed = M1RuntimeTestStore.observed(fixture.store_pid)
    assert MapSet.member?(observed, after_linearization)
    refute MapSet.member?(observed, recovery_representation)

    state = :sys.get_state(coordinator)
    assert state.drain.status == {:unknown, head}
    assert state.pending_cleanup == %{}

    assert {:error, :runtime_unavailable} =
             SessionCoordinator.release_quiesce_cleanup(
               coordinator,
               owner,
               "unknown-drain"
             )
  end

  defp fixture(runtime_id) do
    {store_pid, store} = M1RuntimeTestStore.start_store(label: runtime_id)

    {:ok, runtime} =
      Loopex.start_link(
        context_token_budget: 8_192,
        runtime_id: runtime_id,
        store: store
      )

    on_exit(fn ->
      if Runtime.alive?(runtime), do: Loopex.stop(runtime)
      if Process.alive?(store_pid), do: GenServer.stop(store_pid)
    end)

    %{runtime: runtime, store_pid: store_pid}
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
