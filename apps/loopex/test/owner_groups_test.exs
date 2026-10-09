defmodule Loopex.Runtime.OwnerGroupsTest do
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

        assert_receive {:ready, ^task}, 1_000
        {group, workers, task}
      end

    on_exit(fn ->
      for {_, _, task} <- children, do: send(task, :release)
    end)

    stop = Task.async(fn -> Supervisor.stop(manager, :normal, :infinity) end)

    for {group, workers, task} <- children do
      assert_receive {:stopping, ^task}, 1_000
      assert Process.alive?(group)
      assert Process.alive?(workers)
    end

    for {_, _, task} <- children, do: send(task, :release)
    assert Task.await(stop, 1_000) == :ok

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

        await_empty(manager, System.monotonic_time(:millisecond) + 1_000)
      end)

    assert log =~ "Child Loopex.Runtime.OwnerGroup of Supervisor"
    assert log =~ "owner_workers_stopped"
  end

  defp await_empty(manager, deadline) do
    case :supervisor.which_children(manager) do
      [] ->
        :ok

      _ ->
        assert System.monotonic_time(:millisecond) < deadline
        Process.sleep(1)
        await_empty(manager, deadline)
    end
  end
end
