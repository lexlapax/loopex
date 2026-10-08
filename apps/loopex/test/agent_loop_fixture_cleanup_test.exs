Code.require_file("support/m1_runtime_helper.exs", __DIR__)
Code.require_file("support/agent_loop_helper.exs", __DIR__)

defmodule Loopex.AgentLoopFixtureCleanupTest do
  use ExUnit.Case, async: true
  alias Loopex.AgentLoopFixture, as: Fixture
  alias Loopex.M1RuntimeTestStore, as: Store

  test "an alive standalone catcher joins every acquired actor after runtime admission refuses" do
    with_caller([script: [], bounds_max_turns: 0], fn caller, monitor ->
      assert_receive {:constructor_failed, ^caller, :error, {:badmatch, refused} = reason,
                      receipt},
                     1_000

      assert refused == {:error, :invalid_runtime_options}
      assert elem(receipt.original_failure, 1) == reason
      assert receipt.status == :joined
      assert Enum.sort(Enum.map(receipt.actors, & &1.kind)) == [:executor, :model, :store]
      assert_original_joins(receipt)
      assert Process.alive?(caller)
      refute_received {:DOWN, ^monitor, :process, ^caller, _}
    end)
  end

  test "failed readiness joins the original runtime and agents while preserving a borrowed Store" do
    {store, _boundary} = Store.start_store(label: "borrowed-constructor-failure")
    store_monitor = Process.monitor(store)

    try do
      :ok = Store.fail_reads(store, true)
      :ok = Store.hold_next_creation_recovery(store, self())

      with_caller([script: [], store: store], fn caller, caller_monitor ->
        assert_receive {:creation_read_held, waiter, _original_read_worker, _request}, 1_000
        cutoff = now_ms() + 1_000
        originals = await_originals(caller, cutoff)
        assert Enum.sort(Enum.map(originals, &elem(&1, 0))) == [:executor, :model, :runtime]

        monitors =
          for {kind, pid, _fixture_monitor} <- originals,
              do: {kind, pid, Process.monitor(pid)}

        try do
          Store.release(waiter)

          assert_receive {:constructor_failed, ^caller, :error, %RuntimeError{} = error, receipt},
                         1_000

          assert error.message =~ "fixture creation startup unavailable"
          assert receipt.status == :joined
          assert_original_joins(receipt)

          assert Map.new(receipt.actors, &{&1.kind, &1.pid}) ==
                   Map.new(originals, fn {kind, pid, _} -> {kind, pid} end)

          for {_kind, pid, monitor} <- monitors do
            assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 1_000
          end

          assert Process.alive?(caller)
          refute_received {:DOWN, ^caller_monitor, :process, ^caller, _}
          assert Process.alive?(store)
          assert Store.inspect_state(store).fail_reads
          refute_received {:DOWN, ^store_monitor, :process, ^store, _}
        after
          for {_kind, _pid, monitor} <- monitors, do: Process.demonitor(monitor, [:flush])
          Store.release(waiter)
        end
      end)
    after
      if Process.alive?(store), do: GenServer.stop(store, :normal, 1_000)
      assert_receive {:DOWN, ^store_monitor, :process, ^store, :normal}, 1_000
    end
  end

  test "one blocked original Agent makes cleanup unproved without skipping the other actors" do
    {store, _boundary} = Store.start_store(label: "blocked-constructor-cleanup")

    try do
      :ok = Store.fail_reads(store, true)
      :ok = Store.hold_next_creation_recovery(store, self())

      with_caller([script: [], store: store], fn caller, _monitor ->
        assert_receive {:creation_read_held, waiter, _read_worker, _request}, 1_000
        originals = await_originals(caller, now_ms() + 1_000)
        {:model, model, _original_monitor} = List.keyfind(originals, :model, 0)
        true = :erlang.suspend_process(model)

        try do
          Store.release(waiter)
          # One original 1,000-ms cleanup episode really expires. The separate
          # existing fixture grace observes its receipt without changing it.
          observation_cutoff = now_ms() + 2_000

          assert_receive {:constructor_failed, ^caller, :error, %RuntimeError{} = original,
                          receipt},
                         max(observation_cutoff - now_ms(), 0)

          assert original.message =~ "fixture creation startup unavailable"
          assert elem(receipt.original_failure, 1) == original
          assert receipt.status == :cleanup_unproved
          assert now_ms() >= receipt.cutoff
          model_row = Enum.find(receipt.actors, &(&1.kind == :model))
          assert model_row.pid == model
          assert model_row.original_down == :unproved
          assert Process.alive?(model)

          for actor <- Enum.reject(receipt.actors, &(&1.kind == :model)) do
            assert match?({:down, :normal}, actor.original_down)
            refute Process.alive?(actor.pid)
          end

          assert Process.alive?(caller)
          assert Process.alive?(store)
        after
          if Process.alive?(model) do
            monitor = Process.monitor(model)
            true = :erlang.resume_process(model)

            try do
              GenServer.stop(model, :normal, 1_000)
            catch
              :exit,
              {{:normal, {:sys, :terminate, [^model, :normal, 1_000]}},
               {GenServer, :stop, [^model, :normal, 1_000]}} ->
                :ok

              :exit, {:noproc, _call} ->
                :ok

              :exit, {:normal, _call} ->
                :ok
            end

            assert_receive {:DOWN, ^monitor, :process, ^model, :normal}, 1_000
          end

          Store.release(waiter)
        end
      end)
    after
      if Process.alive?(store), do: GenServer.stop(store, :normal, 1_000)
    end
  end

  test "successful non-ExUnit construction keeps its original returned fixture teardown" do
    with_caller([script: []], fn caller, _monitor ->
      assert_receive {:constructor_ready, ^caller, fixture}, 1_000
      assert Process.alive?(fixture.model)
      assert Process.alive?(fixture.executor)
      assert Process.alive?(fixture.runtime.supervisor)
      assert Process.alive?(fixture.store)
      send(caller, :stop_successful_fixture)
      assert_receive {:successful_fixture_stopped, ^caller}, 1_000
      refute Process.alive?(fixture.runtime.supervisor)
      refute Process.alive?(fixture.store)
      assert Process.alive?(fixture.model)
      assert Process.alive?(fixture.executor)
      assert Process.alive?(caller)
      # Those Agents retain the existing successful-caller ownership. This
      # test explicitly reaps them; construction must not retire them early.
      send(caller, :reap_successful_agents)
      assert_receive {:successful_agents_joined, ^caller}, 1_000
      refute Process.alive?(fixture.model)
      refute Process.alive?(fixture.executor)
    end)
  end

  defp with_caller(options, function) do
    observer = self()

    {caller, monitor} =
      spawn_monitor(fn ->
        try do
          fixture = Fixture.start(options)

          try do
            send(observer, {:constructor_ready, self(), fixture})

            receive do
              :stop_successful_fixture ->
                Fixture.stop(fixture)
                send(observer, {:successful_fixture_stopped, self()})

                receive do
                  :reap_successful_agents ->
                    reap_agents(fixture)
                    send(observer, {:successful_agents_joined, self()})

                    receive do
                      :finish -> :ok
                    end

                  :finish ->
                    :ok
                end

              :finish ->
                :ok
            end
          after
            Fixture.stop(fixture)
            reap_agents(fixture)
          end
        catch
          kind, reason ->
            send(
              observer,
              {:constructor_failed, self(), kind, reason,
               Process.get({Fixture, :constructor_cleanup})}
            )

            receive do
              :finish -> :ok
            end
        end
      end)

    try do
      function.(caller, monitor)
    after
      send(caller, :finish)

      receive do
        {:DOWN, ^monitor, :process, ^caller, :normal} -> :ok
      after
        1_000 ->
          Process.exit(caller, :kill)
          flunk("original constructor caller did not join within fixture grace")
      end
    end
  end

  defp reap_agents(fixture) do
    for pid <- [fixture.model, fixture.executor],
        Process.alive?(pid),
        do: GenServer.stop(pid, :normal, 1_000)
  end

  defp assert_original_joins(receipt) do
    for actor <- receipt.actors do
      assert is_pid(actor.pid)
      assert is_reference(actor.monitor)
      assert match?({:down, :normal}, actor.original_down)
      assert is_pid(actor.worker)
      assert is_reference(actor.worker_monitor)
      assert match?({:down, :normal}, actor.worker_down)
      assert actor.stop_result == :ok
      refute Process.alive?(actor.pid)
      refute Process.alive?(actor.worker)
    end
  end

  defp await_originals(caller, cutoff) do
    {:dictionary, dictionary} = Process.info(caller, :dictionary)

    originals =
      Enum.find_value(dictionary, fn
        {{Fixture, reference}, %{actors: actors}} when is_reference(reference) -> actors
        _ -> nil
      end)

    if originals && List.keymember?(originals, :runtime, 0) do
      originals
    else
      assert now_ms() < cutoff
      Process.sleep(1)
      await_originals(caller, cutoff)
    end
  end

  defp now_ms(), do: System.monotonic_time(:millisecond)
end
