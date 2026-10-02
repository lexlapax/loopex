defmodule LoopexComposition.Ephemeral.TraceTest do
  @moduledoc false
  use ExUnit.Case, async: false

  alias LoopexComposition.Ephemeral
  alias LoopexComposition.Ephemeral.{OwnerActivation, SessionOwner}
  alias LoopexComposition.TraceConfiguration

  defmodule Policy do
    @moduledoc false
    def decide(_), do: {:allow, nil}
  end

  # These ordinary lifecycle tests use a scripted conversation with a real
  # runtime, capability, tracer and diagnostic tree. No provider is dispatched.
  defmodule Facade do
    @moduledoc false
    def create_session(_runtime, _, _), do: {:ok, "trace-session"}

    def attach(runtime, session_id, _) do
      Process.put(:events, [])
      Process.put(:sequence, 0)

      {:ok,
       %Loopex.Attachment{
         runtime: runtime,
         session_id: session_id,
         attachment_id: "attachment",
         incarnation_id: "incarnation",
         snapshot: %{}
       }}
    end

    def session_status(_, _),
      do:
        {:ok,
         %{
           status: :active,
           owner_epoch: 0,
           active_run_id: nil,
           pending_work_ids: [],
           cleanup_grace_ms: 5_000
         }}

    def command(attachment, %{type: :prompt} = command) do
      {:ok, _} = Loopex.Runtime.configuration(attachment.runtime)
      run = "run-" <> command.content

      enqueue(%{
        :kind => "user.message_appended",
        "command_id" => command.command_id,
        "run_id" => run,
        "content" => command.content
      })

      enqueue(%{
        :kind => "assistant.message_appended",
        "run_id" => run,
        "content" => "answer: " <> command.content
      })

      enqueue(%{
        :kind => "run.finished",
        "run_id" => run,
        "outcome" => "completed",
        "cleanup_grace_ms" => 5_000
      })

      {:accepted, command.command_id}
    end

    def next_event(_) do
      case Process.get(:events) do
        [event | rest] ->
          Process.put(:events, rest)
          {:ok, event}

        [] ->
          {:error, :empty}
      end
    end

    defp enqueue(event) do
      sequence = Process.get(:sequence) + 1
      Process.put(:sequence, sequence)
      Process.put(:events, Process.get(:events) ++ [Map.put(event, :event_sequence, sequence)])
    end
  end

  setup do
    tmp = Path.join(System.tmp_dir!(), "loopex-m7-trace-#{System.unique_integer([:positive])}")
    File.mkdir!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)
    %{tmp: tmp}
  end

  test "invalid trace refuses before workspace checks and owner allocation", %{tmp: tmp} do
    before = DynamicSupervisor.count_children(Ephemeral.OwnerSupervisor)

    assert Ephemeral.start_session(
             policy: Policy,
             cwd: Path.join(tmp, "absent"),
             trace: %{"enabled" => false, "sink" => self()}
           ) ==
             {:error, {:invalid_option, :trace}}

    assert DynamicSupervisor.count_children(Ephemeral.OwnerSupervisor) == before
    assert File.ls!(tmp) == []
  end

  test "absent and disabled trace retain the original eight owned edges", %{tmp: tmp} do
    for trace <- [nil, normalized(%{"enabled" => false})] do
      {session, owner} = start_session(tmp, trace)
      startup = :sys.get_state(owner).startup
      assert startup.registered.diagnostics == nil
      refute Map.has_key?(startup.registered, :diagnostic_supervisor)
      assert map_size(startup.process_monitors) == 9
      assert {:error, :no_trace_session} = Loopex.trace_status(startup.registered.runtime)
      assert :ok = Ephemeral.stop_session(session)
    end

    assert File.ls!(tmp) == []
  end

  test "both diagnostic actors are registered before granted trace activation", %{tmp: tmp} do
    parent = self()
    device = device(:ack)

    seams = %{
      diagnostic_device: device,
      trace_start: fn runtime, configuration ->
        send(parent, {:activating, self(), runtime, configuration})
        receive do: (:activate -> Loopex.trace(runtime, configuration))
      end
    }

    {owner, cell, configuration} = prepare(tmp, enabled(), seams)
    request = :erlang.alias([:reply])
    on_exit(fn -> :erlang.unalias(request) end)
    send(owner, {self(), request, :start_session, configuration})

    assert_receive {:activating, root, runtime, selection}
    state = :sys.get_state(owner)
    registered = state.startup.registered
    assert state.startup.expected == :trace_start and state.startup.granted
    assert is_pid(registered.diagnostics)
    assert is_pid(registered.diagnostic_supervisor)
    assert Map.has_key?(state.startup.process_monitors, registered.diagnostics)
    assert Map.has_key?(state.startup.process_monitors, registered.diagnostic_supervisor)
    assert map_size(state.startup.process_monitors) == 10
    assert selection.modules == [Loopex.Runtime.Control]
    assert selection.sink == :diagnostics
    assert {:error, :no_trace_session} = Loopex.trace_status(runtime)
    refute Map.has_key?(registered, :facade_client)
    send(root, :activate)
    assert_receive {^owner, ^request, {:ok, :session_ready}}
    assert {:ok, _} = Loopex.trace_status(runtime)
    assert :ok = Ephemeral.stop_session({:loopex_ephemeral_session, owner, cell})
    assert File.ls!(tmp) == []
  end

  test "real trace survives successive prompts and joins every owned actor on stop", %{tmp: tmp} do
    device = device(:ack)
    {session, owner} = start_session(tmp, enabled(), %{diagnostic_device: device})
    startup = :sys.get_state(owner).startup
    runtime = startup.registered.runtime
    assert {:ok, first} = Loopex.trace_status(runtime)
    assert {:ok, _} = Ephemeral.ask(session, "first")
    assert {:ok, _} = Ephemeral.ask(session, "second")
    assert {:ok, later} = Loopex.trace_status(runtime)
    assert Map.drop(later, [:emitted, :dropped]) == Map.drop(first, [:emitted, :dropped])
    assert later.emitted > first.emitted
    assert_receive {:device_write, _, bytes}
    assert bytes =~ "trace_call"
    assert bytes =~ "Loopex.Runtime.Control"
    monitors = Map.new(Map.keys(startup.process_monitors), &{&1, Process.monitor(&1)})
    assert :ok = Ephemeral.stop_session(session)

    for {pid, ref} <- monitors do
      assert_receive {:DOWN, ^ref, :process, ^pid, _}
      refute Process.alive?(pid)
    end

    assert File.ls!(tmp) == []
  end

  test "requested trace startup failure unwinds the registered composition", %{tmp: tmp} do
    parent = self()

    seams = %{
      diagnostic_device: device(:ack),
      trace_start: fn runtime, _ ->
        send(parent, {:trace_refused, runtime})
        {:error, :unsupported_trace_capability}
      end
    }

    {owner, cell, configuration} = prepare(tmp, enabled(), seams)
    monitor = Process.monitor(owner)

    assert SessionOwner.start_session(owner, configuration, 6_000) ==
             {:error, {:composition, :trace_start_failed}}

    assert_receive {:trace_refused, runtime}
    assert_receive {:DOWN, ^monitor, :process, ^owner, :normal}
    refute Process.alive?(runtime.supervisor)
    assert :atomics.get(cell, 1) == 2
    assert File.ls!(tmp) == []
  end

  test "stopping one trace owner leaves a peer runtime and its writer active", %{tmp: tmp} do
    first_device = device(:hold)
    {first, first_owner} = start_session(tmp, enabled(), %{diagnostic_device: first_device})
    assert_receive {:device_write, first_writer, _}
    first_runtime = :sys.get_state(first_owner).startup.registered.runtime
    second_device = device(:hold)
    {second, second_owner} = start_session(tmp, enabled(), %{diagnostic_device: second_device})
    assert_receive {:device_write, second_writer, _}
    second_runtime = :sys.get_state(second_owner).startup.registered.runtime
    assert first_runtime.supervisor != second_runtime.supervisor
    assert :ok = Ephemeral.stop_session(first)
    refute Process.alive?(first_writer)
    assert Process.alive?(second_writer)
    assert {:ok, _} = Loopex.trace_status(second_runtime)
    assert {:ok, _} = Ephemeral.ask(second, "peer-remains-live")
    assert :ok = Ephemeral.stop_session(second)
    refute Process.alive?(second_writer)
    assert File.ls!(tmp) == []
  end

  test "stalled stderr cannot delay prompts or retain a writer after confirmed stop", %{tmp: tmp} do
    device = device(:hold)
    {session, owner} = start_session(tmp, enabled(), %{diagnostic_device: device})
    startup = :sys.get_state(owner).startup
    consumer = startup.registered.diagnostics
    assert_receive {:device_write, writer, _}
    writer_ref = Process.monitor(writer)
    for _ <- 1..400, do: send(consumer, {:loopex_diagnostic, %{"kind" => "trace_call"}})
    assert {:ok, _} = Ephemeral.ask(session, "while-stalled")
    assert eventually(fn -> :sys.get_state(consumer).pending == 256 end)
    assert Process.alive?(writer)
    started = System.monotonic_time(:millisecond)
    assert :ok = Ephemeral.stop_session(session)
    assert System.monotonic_time(:millisecond) - started < 2_000
    assert_receive {:DOWN, ^writer_ref, :process, ^writer, _}
    refute Process.alive?(consumer)
    refute Process.alive?(startup.registered.diagnostic_supervisor)
    assert Process.alive?(device)
    assert File.ls!(tmp) == []
  end

  test "drain loss cannot fabricate a cleanup certificate on a later stop", %{tmp: tmp} do
    parent = self()

    seams = %{
      diagnostic_device: device(:hold),
      group_drain: fn executor, instance, owner, nonce, deadline ->
        send(parent, {:draining, self()})
        receive do: (:drain -> :ok)
        Loopex.Executor.Local.drain_process_groups(executor, instance, owner, nonce, deadline)
      end
    }

    {session, owner} = start_session(tmp, enabled(), seams)
    startup = :sys.get_state(owner).startup
    assert_receive {:device_write, writer, _}
    stop = Task.async(fn -> Ephemeral.stop_session(session) end)
    assert_receive {:draining, worker}
    Process.exit(startup.registered.diagnostics, :kill)
    send(worker, :drain)
    assert {:error, {:cleanup_unproved, %{pending: pending}}} = Task.await(stop)
    assert :session_subtree in pending
    assert eventually(fn -> :atomics.get(elem(session, 2), 1) == 3 end)
    assert {:error, {:cleanup_unproved, %{pending: pending}}} = Ephemeral.stop_session(session)
    assert :session_subtree in pending
    refute Process.alive?(writer)
    refute Process.alive?(startup.registered.diagnostic_supervisor)
    assert File.exists?(startup.owned_root.path)
  end

  test "writer loss seals output while its owning composition remains stoppable", %{tmp: tmp} do
    {session, owner} = start_session(tmp, enabled(), %{diagnostic_device: device(:hold)})
    startup = :sys.get_state(owner).startup
    consumer = startup.registered.diagnostics
    assert_receive {:device_write, writer, _}
    Process.exit(writer, :kill)
    assert eventually(fn -> :sys.get_state(consumer).failure == :diagnostic_output_failed end)
    assert {:ok, _} = Ephemeral.ask(session, "after-writer-loss")
    refute_receive {:device_write, _, _}, 50
    assert :ok = Ephemeral.stop_session(session)
    refute Process.alive?(consumer)
    refute Process.alive?(startup.registered.diagnostic_supervisor)
    assert File.ls!(tmp) == []
  end

  test "private writer supervisor loss joins its active worker before cleanup succeeds", %{
    tmp: tmp
  } do
    {session, owner} = start_session(tmp, enabled(), %{diagnostic_device: device(:hold)})
    startup = :sys.get_state(owner).startup
    assert_receive {:device_write, writer, _}
    writer_ref = Process.monitor(writer)
    Process.exit(startup.registered.diagnostic_supervisor, :kill)
    assert eventually(fn -> :atomics.get(elem(session, 2), 1) == 2 end)
    assert_receive {:DOWN, ^writer_ref, :process, ^writer, _}
    assert :ok = Ephemeral.stop_session(session)
    refute Process.alive?(startup.registered.diagnostics)
    refute Process.alive?(startup.registered.runtime.supervisor)
    assert File.ls!(tmp) == []
  end

  test "a held activation spends the original startup deadline and retains uncertainty", %{
    tmp: tmp
  } do
    parent = self()

    seams = %{
      diagnostic_device: device(:ack),
      trace_start: fn runtime, _ ->
        send(parent, {:held_trace_start, self(), runtime})
        receive do: (:activate -> {:error, :late_activation})
      end
    }

    {owner, cell, configuration} = prepare(tmp, enabled(), seams)
    request = :erlang.alias([:reply])
    on_exit(fn -> :erlang.unalias(request) end)
    send(owner, {self(), request, :start_session, configuration})
    assert_receive {:held_trace_start, root, runtime}
    startup = :sys.get_state(owner).startup
    owned = Map.keys(startup.process_monitors)

    assert_receive {^owner, ^request,
                    {:error,
                     {:cleanup_unproved,
                      %{pending: pending, cause: {:composition, :trace_start_failed}}}}},
                   6_000

    assert :session_subtree in pending
    assert :atomics.get(cell, 1) == 3
    for pid <- owned, do: refute(Process.alive?(pid))
    refute Process.alive?(root)
    refute Process.alive?(runtime.supervisor)
    assert File.exists?(startup.owned_root.path)
  end

  defp enabled, do: normalized(%{"enabled" => true, "modules" => ["Loopex.Runtime.Control"]})

  defp normalized(value) do
    {:ok, selection} = TraceConfiguration.validate(value)
    selection
  end

  defp start_session(tmp, trace, seams \\ %{}) do
    {owner, cell, configuration} = prepare(tmp, trace, seams)
    assert {:ok, :session_ready} = SessionOwner.start_session(owner, configuration, 6_000)
    {{:loopex_ephemeral_session, owner, cell}, owner}
  end

  defp prepare(tmp, trace, seams) do
    {:ok, _, manifest} =
      Loopex.ResourcePack.digest(%{
        "version" => "loopex.resource_pack/1",
        "workspace_ref" => "workspace-ref",
        "revision" => nil,
        "packs" => []
      })

    configuration = %{
      cwd: tmp,
      model: "ollama:test",
      provider: %{credential_variable: nil},
      base_url: "http://localhost:11434",
      policy: Policy,
      tools: :read_only,
      skills: %{manifest: manifest, shadowed_skills: []},
      max_steps: 16,
      deadline_ms: 60_000,
      max_tokens: 128,
      context_token_budget: 8192,
      timeout: 60_000,
      trace: trace,
      test_facade: Facade,
      test_seams: Map.merge(%{temp_root: %{tmp: fn -> tmp end}}, seams)
    }

    supervisor = start_supervised!({DynamicSupervisor, strategy: :one_for_one}, id: make_ref())
    {:ok, activation} = OwnerActivation.start(supervisor)
    owner = OwnerActivation.owner(activation)
    {:ok, cell} = OwnerActivation.begin(activation)
    {owner, cell, configuration}
  end

  defp device(mode) do
    parent = self()
    start_supervised!({Task, fn -> device_loop(parent, mode) end}, id: make_ref())
  end

  defp device_loop(parent, mode) do
    receive do
      {:io_request, from, ref, {:put_chars, _, bytes}} ->
        send(parent, {:device_write, from, IO.iodata_to_binary(bytes)})
        if mode == :ack, do: send(from, {:io_reply, ref, :ok})
        device_loop(parent, mode)
    end
  end

  defp eventually(fun), do: eventually(fun, System.monotonic_time(:millisecond) + 2_000)

  defp eventually(fun, deadline) do
    cond do
      fun.() ->
        true

      System.monotonic_time(:millisecond) >= deadline ->
        false

      true ->
        Process.sleep(5)
        eventually(fun, deadline)
    end
  end
end
