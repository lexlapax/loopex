Code.require_file("../../../loopex/test/support/configured_genesis_helper.exs", __DIR__)

defmodule LoopexStoreLocalTest.CreationRuntimeRecovery do
  @moduledoc false

  alias Loopex.ConfiguredGenesisFixture
  alias Loopex.Runtime
  alias Loopex.Store
  alias Loopex.Store.Local

  def runtime_id, do: "physical-creation-recovery-runtime"
  def command_id, do: "original-create"
  def options, do: %{"original" => "retained physical candidate"}

  def genesis(instructions \\ "Original host instructions.") do
    ConfiguredGenesisFixture.genesis([], ConfiguredGenesisFixture.configuration(instructions))
  end

  def start_runtime(store, captured \\ genesis()) do
    Loopex.start_link(
      runtime_id: runtime_id(),
      context_token_budget: 8_192,
      store: store,
      session_creation_defaults: Map.drop(captured, [:kind, "options"]),
      cleanup_grace_ms: 5_000
    )
  end

  def target(:reserved),
    do: {:runtime_control_reserve_creation, :after_linearization_before_result}

  def target(:created),
    do: {:runtime_control_create_session, :after_linearization_before_result}

  def probe(observer, target) do
    spawn_link(fn -> probe_loop(observer, target) end)
  end

  defp probe_loop(observer, target) do
    receive do
      {:loopex_store_fault_point, store, reference, ^target} ->
        send(observer, {:creation_checkpoint, self(), store, reference, target})

        receive do
          {:release, ^reference} ->
            send(store, {:loopex_store_fault_action, reference, :continue})
            probe_loop(observer, nil)

          {:release_all, caller, release_reference} ->
            send(store, {:loopex_store_fault_action, reference, :continue})
            send(caller, {:creation_probe_released, self(), release_reference})
            probe_loop(observer, nil)

          :stop ->
            send(store, {:loopex_store_fault_action, reference, :continue})
        end

      {:loopex_store_fault_point, store, reference, _pair} ->
        send(store, {:loopex_store_fault_action, reference, :continue})
        probe_loop(observer, target)

      {:release_all, caller, reference} ->
        send(caller, {:creation_probe_released, self(), reference})
        probe_loop(observer, nil)

      :stop ->
        :ok
    end
  end

  # Concept: the durable candidate is selected by the live original Control.
  # Technical depth: read the synced physical log while Local withholds its reply,
  # and match it to Control's permitted transaction before any owner is lost.
  def capture(runtime, path, terminal) do
    {:ok, children} = Runtime.children(runtime)
    control = :sys.get_state(children.control)
    entry = control.creation
    {:transaction, transaction} = entry.action.operation
    true = entry.action.permitted
    true = transaction == if(terminal == :reserved, do: entry.reservation, else: entry.final)
    {:ok, binding} = Store.immutable_binding(transaction)
    true = control.lane.fences == %{{:runtime_control, runtime_id()} => binding}
    {:ok, frames, :complete} = Local.Log.read(path)
    {:ok, physical} = Local.State.replay(frames)

    {:ok, %{head: head, command: capsule}} =
      Local.State.creation_recovery(physical, %{
        runtime_id: runtime_id(),
        command_id: command_id()
      })

    true = capsule.genesis == entry.final.genesis
    true = capsule.reservation_tx_id == entry.reservation.tx_id
    true = capsule.state == terminal
    true = head.owner_selection == entry.head.owner_selection
    true = head.owner_generation == entry.head.owner_generation + 1
    true = head.domain_version == entry.head.domain_version + 1
    true = map_size(physical.sessions) == if(terminal == :reserved, do: 0, else: 1)
    true = DynamicSupervisor.which_children(children.sessions) == []
    true = control.sessions == %{}

    if terminal == :created do
      session = physical.sessions[capsule.session_id]
      true = session.owner_epoch == 0 and session.owner_incarnation_id == nil
      true = session.journal_version == 1 and session.events == []
      [%{payload: retained}] = session.records
      true = retained == entry.final.genesis
      {:ok, final_binding} = Store.immutable_binding(entry.final)
      true = physical.runtime_commands[runtime_id()][command_id()].binding == final_binding
    end

    %{
      head: head,
      capsule: capsule,
      final: entry.final,
      reservation: entry.reservation,
      frames: frames,
      children: children,
      action: entry.action
    }
  end

  # Concept: a terminal child VM is the host's dead-placement fact.
  # Technical depth: halt at the real post-sync checkpoint without releasing the
  # original Store reply. The parent waits for System.cmd's exit before reopening
  # that exact path; the writer marker is deliberately left for stale recovery.
  def halt_original_vm(path, terminal) do
    target = target(terminal)
    probe = probe(self(), target)
    {:ok, local} = Local.start_link(path: path, fault_probe: probe)
    {:ok, store} = Store.new(Local, local)
    {:ok, runtime} = start_runtime(store)
    :ok = ConfiguredGenesisFixture.await_creation_ready(runtime)

    spawn_link(fn -> Runtime.create_session(runtime, command_id(), options()) end)

    receive do
      {:creation_checkpoint, ^probe, ^local, _reference, ^target} ->
        captured = capture(runtime, path, terminal)
        retained = Map.take(captured, [:head, :capsule, :final, :reservation, :frames])
        bytes = :erlang.term_to_binary(retained, [:deterministic])
        IO.write("creation-recovery-capture:" <> Base.encode64(bytes) <> "\n")
        System.halt(0)
    after
      1_000 -> raise "original VM did not reach its creation checkpoint"
    end
  end
end
