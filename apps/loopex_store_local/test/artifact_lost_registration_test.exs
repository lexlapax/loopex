Code.require_file("../../loopex/test/support/configured_genesis_helper.exs", __DIR__)

defmodule Loopex.Store.Local.ArtifactLostRegistrationTest do
  @moduledoc """
  ## Concept

  A lost registration releases capacity only after the original custodian has
  joined, opening permission was never issued, the original deadline expired
  and the same original Store owner supplies a new absence observation.

  ## Technical depth

  One real sixty-second episode drives independent Runtime/Local placements.
  Actual queued calls, owner loss and native actor joins supply the evidence.
  Store callbacks are never replaced. An original observation dispatched early
  stays ineligible even when its actual absence reply arrives after expiry.
  The 1,000 ms fixture observation below is local to these new cases; it supplies
  no production grace and makes no claim about the separate Core custody suite.
  """

  use ExUnit.Case, async: true

  alias Loopex.ArtifactStore
  alias Loopex.Runtime
  alias Loopex.Runtime.EventDispatcher
  alias Loopex.Store.Local
  alias Loopex.Store.Local.Artifacts
  alias Loopex.Store.Local.Transfers

  @fixture_observation_ms 1_000

  @tag :long_bound
  @tag timeout: 70_000
  test "original expiry and owner absence reclaim only a complete lost-registration barrier" do
    assert ArtifactStore.transfer_limits().open_deadline_ms == 60_000
    assert ArtifactStore.transfer_limits().cleanup_deadline_ms == 5_000
    early = pending()
    late = pending()
    alive = pending()
    lost_observer = pending()
    lost_owner = pending()
    permitted = permitted()

    kill_custodian(early)
    first_selector = entry(early).cleanup
    assert entry(early).observation_proof == nil
    resume(early.owner)
    await(fn -> entry(early).observation == :idle end)
    first_absence = observed_close(early)
    assert first_absence.observer == early.original.observer
    assert first_absence.selector == first_selector
    assert first_absence.at < early.original.context.open_deadline_ms
    assert entry(early).custodian_down.reason == :killed
    assert entry(early).loss_kind == :custodian
    refute entry(early).not_reserved
    assert occupied(early)

    kill_custodian(late)
    assert entry(late).observation == :retire
    assert entry(late).observation_proof == nil
    late_selector = entry(late).cleanup
    late_monitors = core(late).artifact_monitors

    assert :ok =
             EventDispatcher.release_attachment(
               alive.dispatcher,
               alive.attachment.attachment_id,
               alive.attachment.incarnation_id
             )

    await_owner_call(
      alive.owner,
      alive.original.observer,
      {:close, entry(alive).cleanup},
      fixture_cutoff()
    )

    assert {:error, %{reason: :cancelled, cleanup: :unproved}} =
             Task.await(alive.caller, @fixture_observation_ms)

    assert entry(alive).custodian_down == nil
    assert Process.alive?(alive.original.custodian)
    assert entry(alive).observation_proof == nil

    kill_custodian(lost_observer)
    Process.exit(lost_observer.original.observer, :kill)

    join(
      lost_observer.original.observer,
      lost_observer.observer_monitor,
      :killed,
      fixture_cutoff()
    )

    await(fn -> entry(lost_observer).observer_down != nil end)
    assert entry(lost_observer).loss_kind == :other
    resume(lost_observer.owner)

    kill_custodian(lost_owner)
    owner_monitor = Process.monitor(lost_owner.owner)
    Process.exit(lost_owner.owner, :kill)
    join(lost_owner.owner, owner_monitor, :killed, fixture_cutoff())
    await(fn -> entry(lost_owner).observation == :idle end)
    {:ok, successor} = Transfers.start_link(root: lost_owner.artifacts.root)
    Process.unlink(successor)
    on_exit(fn -> stop_owner(successor, fn -> GenServer.stop(successor) end) end)
    successor_handle = %{lost_owner.artifacts | transfers: successor}

    assert {:unregistered, %{transfer_ref: successor_id}} =
             Artifacts.close_transfer(successor_handle, entry(lost_owner).cleanup)

    assert successor_id == lost_owner.original.id
    assert entry(lost_owner).store.handle.transfers == lost_owner.owner
    refute entry(lost_owner).store.handle.transfers == successor
    assert occupied(lost_owner)

    # Permission is sticky. Even physical retirement and acknowledgement by
    # the actual Store owner cannot turn a previously opened transfer into a
    # never-permitted registration when Core subsequently observes absence.
    suspend(permitted.original.observer)
    kill_custodian(permitted)
    await(fn -> store_entry(permitted).status == :retired end)
    join(permitted.worker, permitted.worker_monitor, :normal, fixture_cutoff())
    permitted_selector = entry(permitted).cleanup

    assert {:retired, %{receipt_ref: receipt}} =
             Artifacts.close_transfer(permitted.artifacts, permitted_selector)

    assert now() < permitted_selector.close_deadline_ms

    assert :ok =
             Artifacts.close_transfer(permitted.artifacts, %{
               action: :acknowledge,
               transfer_ref: permitted.original.id,
               receipt_ref: receipt
             })

    assert now() < permitted_selector.close_deadline_ms
    resume(permitted.original.observer)
    await(fn -> entry(permitted).observation == :idle end)
    assert entry(permitted).permission
    assert entry(permitted).loss_kind == :custodian
    refute entry(permitted).not_reserved

    fixtures = [early, late, alive, lost_observer, lost_owner, permitted]
    deadline = fixtures |> Enum.map(& &1.original.context.open_deadline_ms) |> Enum.max()
    wait_until(deadline)

    # The original expiry initiates one qualifying observation on the same
    # surviving observer. Earlier cancellation and its expired D_close remain.
    join(early.original.observer, early.observer_monitor, :normal, fixture_cutoff())
    await(fn -> released?(early) end)
    second_absence = observed_close(early)
    assert second_absence.observer == early.original.observer
    assert second_absence.selector == first_selector
    assert second_absence.at >= early.original.context.open_deadline_ms
    assert now() >= first_selector.close_deadline_ms
    assert Transfers.live(early.owner) == []
    assert core(early).artifact_monitors == %{}
    assert ledger(early).transfer_debit == 1_048_576
    assert ledger(early).transfer_reserved == 0

    assert {:error, :unknown_transfer} =
             Loopex.close_artifact_transfer(early.attachment, early.original.id)

    assert ledger(early).transfer_debit == 1_048_576
    assert_no_io_or_ack(early)

    # A blocked invocation retains one observer and one occupied entry across
    # expiry. Its eventual unregistered reply cannot acquire new eligibility.
    assert entry(late).observation == :retire
    assert entry(late).observation_proof == nil
    assert entry(late).observer == late.original.observer
    assert entry(late).observer_monitor == late.original.observer_monitor
    assert core(late).artifact_monitors == late_monitors
    assert occupied(late)

    assert {:error, :cleanup_unproved} =
             Loopex.close_artifact_transfer(late.attachment, late.original.id)

    assert entry(late).cleanup == late_selector
    assert core(late).artifact_monitors == late_monitors
    resume(late.owner)
    await(fn -> entry(late).observation == :idle end)
    old_absence = observed_close(late)
    assert old_absence.at >= late.original.context.open_deadline_ms
    assert occupied(late)
    refute entry(late).not_reserved
    assert entry(late).custodian_down.reason == :killed

    assert {:error, :cleanup_unproved} =
             Loopex.close_artifact_transfer(late.attachment, late.original.id)

    join(late.original.observer, late.observer_monitor, :normal, fixture_cutoff())
    await(fn -> released?(late) end)
    new_absence = observed_close(late)
    assert new_absence.observer == old_absence.observer
    assert new_absence.selector == old_absence.selector
    assert new_absence.selector == late_selector
    assert ledger(late).transfer_debit == 1_048_576
    assert ledger(late).transfer_reserved == 0
    assert core(late).artifact_monitors == %{}
    assert_no_io_or_ack(late)

    assert entry(alive).custodian_down == nil
    assert entry(alive).no_reservation_proof == nil
    assert Process.alive?(alive.original.custodian)
    assert occupied(alive)
    resume(alive.owner)
    join(alive.original.custodian, alive.custodian_monitor, :normal, fixture_cutoff())
    join(alive.original.observer, alive.observer_monitor, :normal, fixture_cutoff())
    await(fn -> released?(alive) end)
    assert_no_io_or_ack(alive)

    assert occupied(lost_observer)
    assert entry(lost_observer).observer == lost_observer.original.observer
    assert entry(lost_observer).observer_down.reason == :killed
    assert entry(lost_observer).loss_kind == :other
    refute entry(lost_observer).not_reserved

    assert {:unregistered, %{transfer_ref: lost_observer_id}} =
             Artifacts.close_transfer(lost_observer.artifacts, entry(lost_observer).cleanup)

    assert lost_observer_id == lost_observer.original.id

    assert {:error, :cleanup_unproved} =
             Loopex.close_artifact_transfer(lost_observer.attachment, lost_observer.original.id)

    assert occupied(lost_observer)

    assert {:error, :cleanup_unproved} =
             Loopex.close_artifact_transfer(lost_owner.attachment, lost_owner.original.id)

    await(fn -> entry(lost_owner).observation == :idle end)
    assert entry(lost_owner).store.handle.transfers == lost_owner.owner
    assert occupied(lost_owner)

    assert {:error, :transfers_unavailable} =
             Artifacts.close_transfer(lost_owner.artifacts, entry(lost_owner).cleanup)

    assert ledger(lost_owner).transfer_reserved == 134_348_801
    refute entry(lost_owner).not_reserved
    assert Transfers.live(successor) == []

    assert {:error, :cleanup_unproved} =
             Loopex.close_artifact_transfer(permitted.attachment, permitted.original.id)

    await(fn -> entry(permitted).observation == :idle end)
    assert entry(permitted).permission
    assert entry(permitted).no_reservation_proof == nil
    assert occupied(permitted)
    assert Transfers.live(permitted.owner) == []

    # Concept: containment joins every remaining original actor after the proof.
    # Technical depth: these stops follow all occupied/unavailable assertions.
    # Exact original observer monitors still belong to this live test process;
    # root destruction is teardown evidence and supplies no transfer reclamation.
    for fixture <- [early, late, alive, lost_observer], do: stop_runtime(fixture, [])

    for fixture <- [lost_owner, permitted] do
      assert Process.alive?(fixture.original.observer)
      assert entry(fixture).observer_down == nil

      stop_runtime(fixture, [
        {fixture.original.observer, fixture.observer_monitor}
      ])
    end
  end

  defp pending do
    fixture = fixture()
    suspend(fixture.owner)
    cutoff = fixture_cutoff()

    caller =
      Task.async(fn ->
        Loopex.open_artifact_transfer(fixture.attachment, fixture.request)
      end)

    await(fn -> map_size(core(fixture).artifact_transfers) == 1 end, cutoff)
    [original] = Map.values(core(fixture).artifact_transfers)
    assert original.invocation == :reserve
    refute original.permission
    assert original.context.open_deadline_ms - original.invocation_started_at <= 60_000

    await_owner_call(
      fixture.owner,
      original.custodian,
      {:reserve, original.request, original.context},
      cutoff
    )

    Map.merge(fixture, %{
      caller: caller,
      original: original,
      custodian_monitor: Process.monitor(original.custodian),
      observer_monitor: Process.monitor(original.observer)
    })
  end

  defp permitted do
    fixture = fixture()
    assert {:ok, transfer} = Loopex.open_artifact_transfer(fixture.attachment, fixture.request)
    original = Map.fetch!(core(fixture).artifact_transfers, transfer.transfer_ref)
    record = :sys.get_state(fixture.owner).transfers[transfer.transfer_ref]
    assert original.permission
    assert Process.alive?(record.worker)

    Map.merge(fixture, %{
      original: original,
      custodian_monitor: Process.monitor(original.custodian),
      observer_monitor: Process.monitor(original.observer),
      worker: record.worker,
      worker_monitor: Process.monitor(record.worker)
    })
  end

  defp fixture do
    root =
      Path.join(
        System.tmp_dir!(),
        "loopex-lost-registration-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, owner} = Transfers.start_link(root: Path.join(root, "artifacts"))
    Process.unlink(owner)
    on_exit(fn -> stop_owner(owner, fn -> GenServer.stop(owner) end) end)
    artifacts = %{root: Path.join(root, "artifacts"), transfers: owner}
    {:ok, store_pid} = Local.start_link(path: Path.join(root, "state"))
    Process.unlink(store_pid)
    on_exit(fn -> stop_owner(store_pid, fn -> GenServer.stop(store_pid) end) end)
    {:ok, store} = Loopex.Store.new(Local, store_pid)

    {:ok, runtime} =
      Loopex.start_link(
        runtime_id: "lost-registration",
        context_token_budget: 8_192,
        store: store,
        artifact_store: %{module: Artifacts, handle: artifacts},
        session_creation_defaults:
          Loopex.ConfiguredGenesisFixture.genesis([]) |> Map.drop([:kind, "options"])
      )

    Process.unlink(runtime.supervisor)
    on_exit(fn -> stop_owner(runtime.supervisor, fn -> Loopex.stop(runtime) end) end)
    :ok = Loopex.ConfiguredGenesisFixture.await_creation_ready(runtime)
    {:ok, session_id} = Loopex.create_session(runtime, %{}, command_id: "create")
    {:ok, attachment} = Loopex.attach(runtime, session_id, after_event_sequence: 0)
    {:ok, %{dispatcher: dispatcher}} = Runtime.children(runtime)

    assert {:ok, reference} =
             Artifacts.put(artifacts, "never opened", %{
               media_type: "text/plain",
               role: "tool_output",
               metadata: %{
                 "session_id" => session_id,
                 "run_id" => "run",
                 "operation_id" => "operation",
                 "attempt" => 1,
                 "tool_call_id" => "call"
               }
             })

    observer = self()
    hook_id = make_ref()

    hook = fn
      count, {:in, {:"$gen_call", {caller, _tag}, {:close, selector}}}, _extra ->
        send(observer, {:original_store_close, self(), caller, selector, now()})
        if count == 7, do: :done, else: count + 1

      count, _event, _extra ->
        count
    end

    assert :ok = :sys.install(owner, {hook_id, hook, 0}, @fixture_observation_ms)
    assert 1 = :erlang.trace(owner, true, [:procs, {:tracer, self()}])

    %{
      runtime: runtime,
      dispatcher: dispatcher,
      owner: owner,
      artifacts: artifacts,
      attachment: attachment,
      request: %{use_locator: reference.use_locator, start: 0}
    }
  end

  defp kill_custodian(fixture) do
    cutoff = fixture_cutoff()
    Process.exit(fixture.original.custodian, :kill)
    join(fixture.original.custodian, fixture.custodian_monitor, :killed, cutoff)
    await(fn -> entry(fixture).custodian_down != nil end, cutoff)
    assert entry(fixture).custodian_down.reason == :killed

    if Map.has_key?(fixture, :caller) do
      await_owner_call(
        fixture.owner,
        fixture.original.observer,
        {:close, entry(fixture).cleanup},
        cutoff
      )

      assert {:error, %{reason: :transfers_unavailable, cleanup: :unproved}} =
               Task.await(fixture.caller, remaining!(cutoff))
    end
  end

  # Concept: a Core dispatch label does not prove that its original call arrived.
  # Technical depth: the suspended actual Store owner retains the native call in
  # its mailbox. Match original callback PID and exact request/context or selector
  # before actor loss or expiry; this observation returns no replacement result.
  defp await_owner_call(owner, caller, request, cutoff) do
    await(
      fn ->
        case Process.info(owner, :messages) do
          {:messages, messages} ->
            Enum.any?(messages, fn
              {:"$gen_call", {^caller, _tag}, ^request} -> true
              _other -> false
            end)

          _other ->
            false
        end
      end,
      cutoff
    )
  end

  defp observed_close(fixture) do
    owner = fixture.owner

    assert_receive {:original_store_close, ^owner, observer, selector, at},
                   @fixture_observation_ms

    %{observer: observer, selector: selector, at: at}
  end

  defp assert_no_io_or_ack(fixture) do
    owner = fixture.owner
    assert :sys.get_state(owner).transfers == %{}
    fence = :erlang.trace_delivered(owner)
    assert_receive {:trace_delivered, ^owner, ^fence}, @fixture_observation_ms
    refute_received {:trace, ^owner, :spawn, _worker, _entry}
    refute_received {:original_store_close, ^owner, _caller, %{action: :acknowledge}, _at}
    assert {:ok, []} = File.ls(Path.join(fixture.artifacts.root, "transfers"))
  end

  defp suspend(pid) do
    true = :erlang.suspend_process(pid)
    on_exit(fn -> resume(pid) end)
  end

  defp resume(pid) do
    if Process.alive?(pid) do
      try do
        :erlang.resume_process(pid)
      catch
        :error, :badarg -> :ok
      end
    end
  end

  defp wait_until(deadline) do
    remaining = max(0, deadline - now())

    receive do
      :unexpected_fixture_message -> flunk("unexpected fixture message")
    after
      remaining -> :ok
    end

    assert now() >= deadline
  end

  defp join(pid, monitor, reason, cutoff) do
    remaining = remaining!(cutoff)
    assert_receive {:DOWN, ^monitor, :process, ^pid, ^reason}, remaining
    assert now() < cutoff
  end

  defp await(predicate), do: await(predicate, fixture_cutoff())

  defp await(predicate, cutoff) do
    assert now() < cutoff
    result = predicate.()
    assert now() < cutoff

    if result do
      :ok
    else
      Process.sleep(1)
      await(predicate, cutoff)
    end
  end

  defp remaining!(cutoff) do
    remaining = cutoff - now()
    assert remaining > 0
    remaining
  end

  defp stop_owner(pid, stop) do
    if Process.alive?(pid) do
      monitor = Process.monitor(pid)
      assert :ok = stop.()
      assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, @fixture_observation_ms
    end
  end

  defp stop_runtime(fixture, remaining_actors) do
    cutoff = fixture_cutoff()
    root = fixture.runtime.supervisor
    root_monitor = Process.monitor(root)
    assert :ok = Loopex.stop(fixture.runtime)
    join(root, root_monitor, :normal, cutoff)

    for {pid, monitor} <- remaining_actors do
      remaining = remaining!(cutoff)
      assert_receive {:DOWN, ^monitor, :process, ^pid, _reason}, remaining
      assert now() < cutoff
      refute Process.alive?(pid)
    end
  end

  defp fixture_cutoff, do: now() + @fixture_observation_ms
  defp now, do: System.monotonic_time(:millisecond)
  defp core(fixture), do: :sys.get_state(fixture.dispatcher)
  defp entry(fixture), do: Map.fetch!(core(fixture).artifact_transfers, fixture.original.id)

  defp store_entry(fixture),
    do: Map.fetch!(:sys.get_state(fixture.owner).transfers, fixture.original.id)

  defp released?(fixture),
    do: not Map.has_key?(core(fixture).artifact_transfers, fixture.original.id)

  defp occupied(fixture), do: map_size(core(fixture).artifact_transfers) == 1
  defp ledger(fixture), do: Map.fetch!(core(fixture).holders, self())
end
