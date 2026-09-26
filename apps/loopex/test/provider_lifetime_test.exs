defmodule Loopex.Runtime.ProviderLifetimeTest do
  @moduledoc """
  ## Concept

  A managed model callback can start short-lived provider bridge members under
  the current session owner's worker supervisor without learning or retaining
  that supervisor.

  ## Technical depth

  The process-local starter fixes temporary restart and brutal-kill shutdown,
  coexists with the existing resource registrar for exactly one callback scope,
  and disappears when that scope returns. Supervisor loss synchronously ends
  every child reached through it.
  """

  use ExUnit.Case, async: true

  alias Loopex.Runtime.ProviderLifetime
  alias Loopex.Runtime.ProviderLifetime.Starter

  test "a managed scope starts temporary children under its exact owner worker supervisor" do
    workers = start_supervised!({Task.Supervisor, []})
    parent = self()

    starter =
      Starter.new(fn child ->
        Task.Supervisor.start_child(workers, child,
          restart: :temporary,
          shutdown: :brutal_kill
        )
      end)

    registrar = fn resource, stop_reference ->
      send(parent, {:registered, resource, stop_reference})
      {:managed, parent, 1_000}
    end

    child =
      ProviderLifetime.scoped(registrar, starter, fn ->
        assert {:managed, ^starter} = ProviderLifetime.starter()

        {:ok, child} =
          ProviderLifetime.start_child(starter, fn ->
            send(parent, {:provider_child_started, self()})
            receive do: (:stop -> :ok)
          end)

        stop_reference = make_ref()
        assert {:managed, ^parent, 1_000} = ProviderLifetime.register(child, stop_reference)
        assert_receive {:registered, ^child, ^stop_reference}
        child
      end)

    assert_receive {:provider_child_started, ^child}
    assert child in Task.Supervisor.children(workers)
    assert :unmanaged = ProviderLifetime.starter()
    assert :unmanaged = ProviderLifetime.register(child, make_ref())

    monitor = Process.monitor(child)
    send(child, :stop)
    assert_receive {:DOWN, ^monitor, :process, ^child, :normal}
    assert eventually(fn -> Task.Supervisor.children(workers) == [] end)
  end

  test "owner worker supervisor loss reaps a bridge child" do
    {:ok, workers} = Task.Supervisor.start_link()
    Process.unlink(workers)
    parent = self()

    starter =
      Starter.new(fn child ->
        Task.Supervisor.start_child(workers, child,
          restart: :temporary,
          shutdown: :brutal_kill
        )
      end)

    {:ok, child} =
      ProviderLifetime.start_child(starter, fn ->
        send(parent, {:provider_child_started, self()})
        Process.sleep(:infinity)
      end)

    assert_receive {:provider_child_started, ^child}
    monitor = Process.monitor(child)
    Process.exit(workers, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^child, :killed}
  end

  defp eventually(fun, attempts \\ 100)

  defp eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      true
    else
      Process.sleep(5)
      eventually(fun, attempts - 1)
    end
  end

  defp eventually(_fun, 0), do: false
end
