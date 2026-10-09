Code.require_file("support/configured_genesis_helper.exs", __DIR__)
Code.require_file("support/m1_runtime_helper.exs", __DIR__)

defmodule Loopex.Runtime.SessionSupervisorTest do
  @moduledoc """
  ## Concept

  A coordinator that ends on its own while the runtime stops is an ordinary
  temporary exit, so root shutdown reports no shutdown failure for it.

  ## Technical depth

  The session supervisor is suspended while the root delivers its shutdown
  signal and the coordinator then exits with `:shutdown`, so both signals are
  queued in that order before the supervisor runs again. Elixir's
  DynamicSupervisor reported that already-queued temporary exit as
  `shutdown_error`; the Erlang supervisor consumes its `EXIT` reason silently.
  """

  use ExUnit.Case, async: false

  alias Loopex.M1RuntimeTestStore
  alias Loopex.Runtime

  test "root shutdown accepts a coordinator exit queued behind its shutdown signal" do
    {store_pid, store} = M1RuntimeTestStore.start_store(label: "session-supervisor")
    on_exit(fn -> if Process.alive?(store_pid), do: GenServer.stop(store_pid) end)

    {:ok, runtime} =
      Loopex.start_link(
        context_token_budget: 8_192,
        session_creation_defaults:
          Loopex.ConfiguredGenesisFixture.genesis([]) |> Map.drop([:kind, "options"]),
        runtime_id: "session-supervisor",
        store: store
      )

    :ok = Loopex.ConfiguredGenesisFixture.await_creation_ready(runtime)
    assert {:ok, _session_id} = Runtime.create_session(runtime, "create-queued-exit", %{})
    {:ok, children} = Runtime.children(runtime)
    assert [{_id, coordinator, :worker, _modules}] = Supervisor.which_children(children.sessions)
    sessions_monitor = Process.monitor(children.sessions)
    coordinator_monitor = Process.monitor(coordinator)
    root_monitor = Process.monitor(runtime.supervisor)

    # Concept: this test observes supervisor reports, so it enables them.
    # Technical depth: Core does not start the Logger application. Start it and
    # SASL supervisor reports for this serial test, then restore both.
    {:ok, started} = Application.ensure_all_started(:logger)
    on_exit(fn -> Enum.each(Enum.reverse(started), &Application.stop/1) end)
    filters = :logger.get_primary_config().filters

    enabled =
      Keyword.update!(filters, :logger_translator, fn {callback, configuration} ->
        {callback, %{configuration | sasl: true}}
      end)

    :ok = :logger.set_primary_config(:filters, enabled)
    on_exit(fn -> :logger.set_primary_config(:filters, filters) end)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        true = :erlang.suspend_process(children.sessions)
        stop = Task.async(fn -> Loopex.stop(runtime) end)
        :ok = await_root_shutdown_of(runtime.supervisor, children)

        Process.exit(coordinator, :shutdown)
        assert_receive {:DOWN, ^coordinator_monitor, :process, ^coordinator, :shutdown}, 1_000
        true = :erlang.resume_process(children.sessions)

        assert Task.await(stop, 5_000) == :ok
        assert_receive {:DOWN, ^sessions_monitor, :process, _sessions, :shutdown}, 1_000
        assert_receive {:DOWN, ^root_monitor, :process, _root, :normal}, 1_000
      end)

    refute log =~ "shut down abnormally"
    refute log =~ "shutdown_error"
    refute log =~ "Loopex.Runtime.SessionCoordinator"
  end

  # Concept: the root has sent its shutdown signal to the session supervisor.
  # Technical depth: the root stops children in reverse start order; once the
  # later dispatcher and tracer are gone and the root waits in its own child
  # shutdown, its signal to the suspended session supervisor is queued.
  defp await_root_shutdown_of(root, children) do
    deadline = System.monotonic_time(:millisecond) + 2_000
    await_root_shutdown_of(root, children, deadline)
  end

  defp await_root_shutdown_of(root, children, deadline) do
    {:current_stacktrace, stack} = Process.info(root, :current_stacktrace)

    waiting? =
      not Process.alive?(children.dispatcher) and not Process.alive?(children.tracer) and
        Enum.any?(stack, &match?({:supervisor, :shutdown, 1, _}, &1))

    cond do
      waiting? ->
        :ok

      System.monotonic_time(:millisecond) < deadline ->
        Process.sleep(1)
        await_root_shutdown_of(root, children, deadline)

      true ->
        flunk("root did not begin session supervisor shutdown")
    end
  end
end
