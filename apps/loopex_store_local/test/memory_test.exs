Code.require_file("../../loopex/test/support/configured_genesis_helper.exs", __DIR__)

defmodule Loopex.Store.MemoryTest do
  use ExUnit.Case, async: false

  alias Loopex.Store
  alias Loopex.Store.Memory
  alias Loopex.Store.Transitions

  test "startup links an unnamed store and a replacement has no prior history" do
    {:ok, first} = Memory.start_link()
    assert {:links, links} = Process.info(first, :links)
    assert self() in links
    assert {:registered_name, []} = Process.info(first, :registered_name)

    {:ok, store} = Store.new(Memory, first)

    {:ok, create} =
      Store.create_session(
        "memory-runtime",
        "create",
        Loopex.ConfiguredGenesisFixture.genesis([])
      )

    {:ok, claim} = Store.claim_creation_domain("memory-runtime", 0, String.duplicate("a", 64))
    assert {:committed, _, claimed} = Store.transact(store, claim)

    {:ok, reserve} =
      Store.reserve_creation(
        "memory-runtime",
        "create",
        claimed.owner_generation,
        claimed.owner_selection,
        claimed.domain_version,
        create.genesis
      )

    assert {:committed, _, _} = Store.transact(store, reserve)
    assert {:committed, "create", receipt} = Store.transact(store, create)
    assert {:ok, [_]} = Store.load_records(store, receipt.session_id, 0, 10)

    monitor = Process.monitor(first)
    GenServer.stop(first)
    assert_receive {:DOWN, ^monitor, :process, ^first, :normal}

    {:ok, second} = Memory.start_link()

    try do
      {:ok, replacement} = Store.new(Memory, second)
      assert {:ok, []} = Store.load_records(replacement, receipt.session_id, 0, 10)
      assert {:ok, []} = Store.load_events(replacement, receipt.session_id, 0, 10)
      assert :absent = Store.ownership_head(replacement, receipt.session_id, "session_journal")
    after
      GenServer.stop(second)
    end
  end

  test "a probe answer is correlated and an unknown action refuses the transaction" do
    test_process = self()

    probe =
      spawn(fn ->
        receive do
          {:loopex_store_fault_point, store, reference, pair} ->
            send(test_process, {:observed_checkpoint, pair})
            send(store, {:loopex_store_fault_action, make_ref(), :continue})
            send(store, {:loopex_store_fault_action, reference, :not_an_action})
        end
      end)

    {:ok, pid} = Memory.start_link(fault_probe: probe)
    Process.unlink(pid)

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
      if Process.alive?(probe), do: Process.exit(probe, :kill)
    end)

    monitor = Process.monitor(pid)
    {:ok, store} = Store.new(Memory, pid)

    {:ok, transaction} =
      Store.create_session("memory-runtime", "refused", %{kind: :session_genesis})

    {:ok, transition} = Transitions.id(transaction)
    {:ok, tx_id} = Store.transaction_id(transaction)

    assert {:commit_unknown, ^tx_id} = Store.transact(store, transaction)
    assert_receive {:observed_checkpoint, {^transition, :before_linearization}}
    assert_receive {:DOWN, ^monitor, :process, ^pid, :unknown_fault_action}
  end

  test "OTP formatting excludes private state, last message, reason and debug log" do
    canary = "private-memory-store-canary"

    assert %{
             state: :redacted_store_state,
             message: :redacted_store_message,
             reason: :redacted_store_reason,
             log: [],
             unrelated: :preserved
           } =
             Memory.format_status(%{
               state: %{private_record: canary},
               message: {:transact, canary},
               reason: {:failure, canary},
               log: [canary],
               unrelated: :preserved
             })
  end

  test "every Store callback applies the explicit thirty-second call timeout" do
    {:ok, pid} = Memory.start_link()

    {:ok, transaction} =
      Store.create_session("timeout-runtime", "timeout-create", %{kind: :session_genesis})

    parent = self()

    {caller, monitor} =
      spawn_monitor(fn ->
        receive do
          :invoke ->
            Memory.transact(pid, transaction)
            Memory.transaction_status(pid, "absent", "session_journal", "tx")
            Memory.ownership_head(pid, "absent", "session_journal")
            Memory.runtime_command(pid, %{runtime_id: "absent", command_id: "command"})
            Memory.creation_recovery(pid, %{runtime_id: "absent", command_id: nil})
            Memory.creation_provenance(pid, "absent", %{kind: :command, command_id: "command"})
            Memory.load_records(pid, "absent", 0, 1)
            Memory.load_events(pid, "absent", 0, 1)
            send(parent, {:callbacks_done, self()})
        end
      end)

    # Concept: assert the timer argument without waiting thirty seconds.
    # Technical depth: only this disposable caller is traced, and every call
    # reaches the real shipped adapter. The module is serial for the VM-wide
    # trace pattern, which is removed on every return or assertion failure.
    :erlang.trace_pattern({GenServer, :call, 3}, true, [:local])
    :erlang.trace(caller, true, [:call, {:tracer, self()}])

    try do
      send(caller, :invoke)

      for operation <-
            [
              :transact,
              :transaction_status,
              :ownership_head,
              :runtime_command,
              :creation_recovery,
              :creation_provenance,
              :load_records,
              :load_events
            ] do
        assert_receive {:trace, ^caller, :call, {GenServer, :call, [^pid, request, 30_000]}},
                       2_000

        assert elem(request, 0) == operation
      end

      assert_receive {:callbacks_done, ^caller}
      assert_receive {:DOWN, ^monitor, :process, ^caller, :normal}
    after
      :erlang.trace_pattern({GenServer, :call, 3}, false, [:local])
      if Process.alive?(caller), do: Process.exit(caller, :kill)
      GenServer.stop(pid)
    end
  end
end
