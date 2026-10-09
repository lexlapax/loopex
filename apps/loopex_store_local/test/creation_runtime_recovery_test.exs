Code.require_file("support/creation_runtime_recovery_helper.exs", __DIR__)

defmodule Loopex.Store.CreationRuntimeRecoveryTest do
  @moduledoc """
  ## Concept

  A replacement runtime resolves the original physical creation after its root
  or VM ends, preserving its exact settings without activating its history.

  ## Technical depth

  Actual Runtime requests select the Local claim, reservation and final bytes.
  Local's existing post-sync fault checkpoint withholds the original reply.
  Original process joins or terminal VM exit precede exclusive reopening of the
  same log. Successor startup uses its native readiness read. These cases prove
  current-format placement recovery, not backup/restore or active-active hosts.
  """

  use ExUnit.Case, async: false

  alias Loopex.ConfiguredGenesisFixture
  alias Loopex.Runtime
  alias Loopex.Store
  alias Loopex.Store.Local
  alias LoopexStoreLocalTest.CreationRuntimeRecovery, as: Fixture

  setup do
    directory =
      Path.join(
        System.tmp_dir!(),
        "loopex-creation-runtime-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)
    %{path: Path.join(directory, "state.log")}
  end

  for terminal <- [:reserved, :created] do
    @terminal terminal

    test "root loss recovers the original #{@terminal} Local creation", %{path: path} do
      terminal = @terminal
      target = Fixture.target(terminal)
      probe = Fixture.probe(self(), target)
      on_exit(fn -> stop_probe(probe) end)
      {local, store} = local(path, fault_probe: probe)
      runtime = runtime(store)
      :ok = ConfiguredGenesisFixture.await_creation_ready(runtime)
      observer = self()

      {caller, caller_monitor} =
        spawn_monitor(fn ->
          send(
            observer,
            {:original_reply,
             Runtime.create_session(runtime, Fixture.command_id(), Fixture.options())}
          )
        end)

      on_exit(fn -> if Process.alive?(caller), do: Process.exit(caller, :kill) end)

      assert_receive {:creation_checkpoint, ^probe, ^local, reference, ^target}, 1_000
      on_exit(fn -> send(probe, {:release, reference}) end)
      original = Fixture.capture(runtime, path, terminal)

      actors =
        [runtime.supervisor | Map.values(original.children)] ++
          [original.action.pid, original.action.group, original.action.worker]

      monitors = Enum.map(Enum.uniq(actors), &{&1, Process.monitor(&1)})
      Process.unlink(runtime.supervisor)
      cutoff = System.monotonic_time(:millisecond) + 1_000
      Process.exit(runtime.supervisor, :kill)
      join(monitors, cutoff)
      assert_receive {:original_reply, {:error, :runtime_unavailable}}, remaining(cutoff)
      assert_receive {:DOWN, ^caller_monitor, :process, ^caller, :normal}, remaining(cutoff)
      refute Runtime.alive?(runtime)
      send(probe, {:release, reference})
      stop_local(local)
      frames = original.frames
      assert {:ok, ^frames, :complete} = Local.Log.read(path)
      verify_successor(path, original, terminal)
    end

    test "VM loss recovers the original #{@terminal} Local creation", %{path: path} do
      terminal = @terminal
      executable = System.find_executable("elixir") || raise "elixir executable unavailable"

      ebins =
        Enum.map([Store, Local.Log, LoopexProtocol.ToolDefinition, :telemetry], fn module ->
          module |> :code.which() |> List.to_string() |> Path.dirname()
        end)

      helper = Path.expand("support/creation_runtime_recovery_helper.exs", __DIR__)

      script = """
      {:ok, _} = Application.ensure_all_started(:loopex)
      Code.require_file(#{inspect(helper)})
      LoopexStoreLocalTest.CreationRuntimeRecovery.halt_original_vm(#{inspect(path)}, #{inspect(terminal)})
      """

      args = ["--erl", "+S 1:1"] ++ Enum.flat_map(ebins, &["-pa", &1]) ++ ["-e", script]
      # Concept: reopening follows positive original VM exclusion.
      # Technical depth: System.cmd returns only after the original OS process
      # exits and its output closes; no status value substitutes for that fact.
      {"creation-recovery-capture:" <> encoded, 0} =
        System.cmd(executable, args, stderr_to_stdout: true)

      assert String.ends_with?(encoded, "\n")

      original =
        encoded
        |> String.trim_trailing("\n")
        |> Base.decode64!()
        |> :erlang.binary_to_term([:safe])

      frames = original.frames
      assert {:ok, ^frames, :complete} = Local.Log.read(path)
      assert File.regular?(path <> ".writer")
      verify_successor(path, original, terminal, recover_stale_writer: true)
    end
  end

  test "lost physical Store keeps successor creation unavailable without a fallback", %{
    path: path
  } do
    {local, store} = local(path)
    stop_local(local)
    runtime = runtime(store)
    :ok = ConfiguredGenesisFixture.await_creation_unavailable(runtime)
    assert {:ok, %{state: :unavailable}} = Runtime.creation_startup_status(runtime)
    before = File.read!(path)

    assert {:error, :store_unavailable} =
             Runtime.create_session(runtime, Fixture.command_id(), Fixture.options())

    assert {:ok, :store_unavailable} =
             Runtime.lookup_create_result(runtime, Fixture.command_id(), Fixture.options())

    assert {:ok, %{sessions: sessions}} = Runtime.children(runtime)
    assert DynamicSupervisor.which_children(sessions) == []
    assert File.read!(path) == before
  end

  defp verify_successor(path, original, terminal, options \\ []) do
    {local, store} = local(path, options)
    changed = Fixture.genesis("Replacement defaults must not rebuild original capture.")
    successor = runtime(store, changed)
    :ok = ConfiguredGenesisFixture.await_creation_ready(successor)

    assert {:ok, %{state: :ready, startup_id: startup, startup_deadline_ms: deadline}} =
             Runtime.creation_startup_status(successor)

    assert byte_size(startup) == 32 and is_integer(deadline)

    assert {:ok, %{head: head, command: capsule}} =
             Store.creation_recovery(store, %{
               runtime_id: Fixture.runtime_id(),
               command_id: Fixture.command_id()
             })

    assert capsule.genesis == original.capsule.genesis
    assert capsule.reservation_tx_id == original.capsule.reservation_tx_id
    assert capsule.reservation_owner_generation == original.capsule.reservation_owner_generation
    assert capsule.reservation_owner_selection == original.capsule.reservation_owner_selection
    assert capsule.reservation_domain_version == original.capsule.reservation_domain_version
    assert head.owner_selection != original.head.owner_selection
    assert head.active_command_id == nil

    assert head.owner_generation ==
             original.head.owner_generation + if(terminal == :reserved, do: 2, else: 1)

    assert head.domain_version ==
             original.head.domain_version + if(terminal == :reserved, do: 1, else: 0)

    {:ok, %{sessions: sessions}} = Runtime.children(successor)
    assert DynamicSupervisor.which_children(sessions) == []
    before = File.read!(path)

    case terminal do
      :reserved ->
        assert capsule.state == :not_committed
        assert capsule.final_resolution == {:not_committed, :creation_cancelled}
        assert capsule.session_id == nil
        assert :sys.get_state(local).store.sessions == %{}

        assert {:error, :creation_cancelled} =
                 Runtime.create_session(successor, Fixture.command_id(), Fixture.options())

        assert {:error, :creation_cancelled} =
                 Runtime.create_session_with_genesis(
                   successor,
                   Fixture.command_id(),
                   Fixture.options(),
                   original.final.genesis
                 )

      :created ->
        assert capsule == original.capsule
        session = capsule.session_id
        assert map_size(:sys.get_state(local).store.sessions) == 1

        assert {:ok, %{owner_epoch: 0, journal_version: 1}} =
                 Store.ownership_head(store, session, session)

        assert :sys.get_state(local).store.sessions[session].owner_incarnation_id == nil

        assert {:ok, :conflict} =
                 Runtime.lookup_create_result(successor, Fixture.command_id(), Fixture.options())

        assert {:ok, {:historical, ^session}} =
                 Runtime.lookup_create_result(
                   successor,
                   Fixture.command_id(),
                   Fixture.options(),
                   original.final.genesis
                 )

        assert {:ok, ^session} =
                 Runtime.create_session(successor, Fixture.command_id(), Fixture.options())

        assert {:ok, ^session} =
                 Runtime.create_session_with_genesis(
                   successor,
                   Fixture.command_id(),
                   Fixture.options(),
                   original.final.genesis
                 )

        assert {:error, :session_unavailable} = Runtime.session_status(successor, session)
    end

    assert {:error, :runtime_command_conflict} =
             Runtime.create_session(successor, Fixture.command_id(), %{"original" => "changed"})

    assert {:error, :runtime_command_conflict} =
             Runtime.create_session_with_genesis(
               successor,
               Fixture.command_id(),
               Fixture.options(),
               Map.put(changed, "options", Fixture.options())
             )

    assert DynamicSupervisor.which_children(sessions) == []
    assert File.read!(path) == before

    assert {:ok, %{state: :ready, startup_id: ^startup, startup_deadline_ms: ^deadline}} =
             Runtime.creation_startup_status(successor)
  end

  defp local(path, options \\ []) do
    {:ok, local} = Local.start_link([path: path] ++ options)
    on_exit(fn -> stop_local(local) end)
    {:ok, store} = Store.new(Local, local)
    {local, store}
  end

  defp runtime(store, genesis \\ Fixture.genesis()) do
    {:ok, runtime} = Fixture.start_runtime(store, genesis)
    on_exit(fn -> if Runtime.alive?(runtime), do: Runtime.stop(runtime) end)
    runtime
  end

  defp stop_local(local) do
    if Process.alive?(local) do
      cutoff = System.monotonic_time(:millisecond) + 1_000
      monitor = Process.monitor(local)
      GenServer.stop(local)
      assert_receive {:DOWN, ^monitor, :process, ^local, _}, remaining(cutoff)
    end
  end

  defp stop_probe(probe) do
    if Process.alive?(probe) do
      cutoff = System.monotonic_time(:millisecond) + 1_000
      monitor = Process.monitor(probe)
      send(probe, :stop)
      assert_receive {:DOWN, ^monitor, :process, ^probe, _}, remaining(cutoff)
    end
  end

  defp join(monitors, cutoff) do
    for {actor, monitor} <- monitors do
      assert_receive {:DOWN, ^monitor, :process, ^actor, _}, remaining(cutoff)
    end
  end

  defp remaining(cutoff), do: max(cutoff - System.monotonic_time(:millisecond), 0)
end
