Code.require_file("support/event_wait.exs", __DIR__)

defmodule Loopex.Runtime.OwnerGroupsTest do
  import Loopex.EventWait
  use ExUnit.Case, async: false

  alias Loopex.Runtime.OwnerGroup
  alias Loopex.Runtime.OwnerGroups

  test "runtime shutdown signals all owner groups before waiting for any one group" do
    manager = start_supervised!(Supervisor.child_spec({OwnerGroups, []}, restart: :temporary))
    parent = self()

    children =
      for _ <- 1..2 do
        {:ok, group} = :supervisor.start_child(manager, [[]])
        {:ok, workers} = OwnerGroup.workers(group)

        {:ok, task} =
          Loopex.Runtime.TaskSupervisor.start_child(workers, fn ->
            Process.flag(:trap_exit, true)
            send(parent, {:ready, self()})

            receive do
              {:EXIT, _, :shutdown} ->
                send(parent, {:stopping, self()})

                receive do
                  :release -> :ok
                end
            end
          end)

        await_receive({:ready, ^task})
        {group, workers, task}
      end

    on_exit(fn ->
      for {_, _, task} <- children, do: send(task, :release)
    end)

    stop = Task.async(fn -> Supervisor.stop(manager, :normal, :infinity) end)

    for {group, workers, task} <- children do
      await_receive({:stopping, ^task})
      assert Process.alive?(group)
      assert Process.alive?(workers)
    end

    for {_, _, task} <- children, do: send(task, :release)
    assert Task.await(stop, :infinity) == :ok

    for {group, workers, task} <- children do
      refute Process.alive?(group)
      refute Process.alive?(workers)
      refute Process.alive?(task)
    end
  end

  test "a private worker-supervisor fault still reports an actual child failure" do
    # Concept: this test observes a real supervisor fault, including its report.
    # Technical depth: Core does not start the Logger application. This serial
    # test starts it explicitly before enabling SASL supervisor reports, then
    # restores both the filter configuration and the application lifetime.
    {:ok, started} = Application.ensure_all_started(:logger)
    on_exit(fn -> Enum.each(Enum.reverse(started), &Application.stop/1) end)
    filters = :logger.get_primary_config().filters

    enabled =
      Keyword.update!(filters, :logger_translator, fn {callback, configuration} ->
        {callback, %{configuration | sasl: true}}
      end)

    :ok = :logger.set_primary_config(:filters, enabled)
    on_exit(fn -> :logger.set_primary_config(:filters, filters) end)

    manager = start_supervised!({OwnerGroups, []})
    {:ok, group} = :supervisor.start_child(manager, [[]])
    {:ok, workers} = OwnerGroup.workers(group)
    monitor = Process.monitor(group)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        Process.exit(workers, :kill)

        assert_receive {:DOWN, ^monitor, :process, ^group, {:owner_workers_stopped, :killed}},
                       1_000

        await_empty(manager)
      end)

    assert log =~ "Child Loopex.Runtime.OwnerGroup of Supervisor"
    assert log =~ "owner_workers_stopped"
  end

  # Concept: every wait here ends on the supervised actors' own progress.
  # Technical depth: tasks, groups and the manager are freshly scheduled, so a
  # fixed window would race only scheduling; a sequential shutdown still never
  # reaches the second `:stopping`, and ExUnit's per-test timeout is the bound.
  defp await_empty(manager) do
    unless :supervisor.which_children(manager) == [] do
      Process.sleep(1)
      await_empty(manager)
    end
  end
end
