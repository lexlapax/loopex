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

    monitor = Process.monitor(child)
    await_child({:provider_child_started, child}, child, monitor)
    assert child in Task.Supervisor.children(workers)
    assert :unmanaged = ProviderLifetime.starter()
    assert :unmanaged = ProviderLifetime.register(child, make_ref())

    send(child, :stop)
    assert down(child, monitor) == :normal
    eventually(fn -> Task.Supervisor.children(workers) == [] end)
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

        receive do
          :monitor_installed -> send(parent, {:provider_child_monitored, self()})
        end

        Process.sleep(:infinity)
      end)

    monitor = Process.monitor(child)
    await_child({:provider_child_started, child}, child, monitor)
    # Concept: Observe the child's actual termination reason after the fault.
    # Technical depth: The acknowledgement follows this caller's monitor signal;
    # a kill propagated by a different process cannot overtake monitor setup.
    send(child, :monitor_installed)
    await_child({:provider_child_monitored, child}, child, monitor)
    Process.exit(workers, :kill)
    assert down(child, monitor) == :killed
  end

  # Concept: each wait ends on the child's own next event, never on a test clock.
  # Technical depth: the child is freshly started, so a fixed window measures only
  # how soon a loaded scheduler runs it. Its DOWN ends a wait early, and ExUnit's
  # per-test timeout is the outer bound.
  defp await_child(message, child, monitor) do
    receive do
      ^message -> :ok
      {:DOWN, ^monitor, :process, ^child, reason} -> flunk("child exited: #{inspect(reason)}")
    end
  end

  defp down(child, monitor) do
    receive do
      {:DOWN, ^monitor, :process, ^child, reason} -> reason
    end
  end

  defp eventually(fun) do
    unless fun.() do
      Process.sleep(5)
      eventually(fun)
    end
  end
end
