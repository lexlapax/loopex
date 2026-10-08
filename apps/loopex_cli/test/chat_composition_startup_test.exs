defmodule LoopexCli.ChatCompositionStartupTest do
  use ExUnit.Case, async: false
  @moduletag capture_log: true

  alias Loopex.LLM.ReqLLM
  alias Loopex.LLM.ReqLLM.{CredentialCustody, CredentialRegistry}
  alias Loopex.Store.Local.Log
  alias Loopex.Trace.Capability
  alias LoopexCli.{Chat, ChatDriver, Interrupt}
  alias LoopexComposition.{DiagnosticConsumer, StartupGate}
  alias __MODULE__.HeldLocal

  @edge :"$loopex_composition_edge_observer"
  @slot "M7_CHAT_STARTUP_SLOT"
  @calls [
    {Loopex, :create_session, 3},
    {ChatDriver, :bind, 4},
    {DiagnosticConsumer, :settings_report, 2}
  ]
  @returns [{ChatDriver, :bootstrap, 3}, {Interrupt, :install_chat, 3}]

  test "fresh chat waits for actual Local creation startup before creating or consuming input" do
    test = self()
    root = Path.join(System.tmp_dir!(), "chat-composition-startup-#{System.unique_integer([:positive])}")
    workspace = Path.join(root, "workspace")
    home = Path.join(root, "home")
    state_root = Path.join(root, "state")
    for path <- [workspace, home], do: File.mkdir_p!(path)
    File.write!(Path.join(root, "system.txt"), "Keep this chat local.\n")
    config = Path.join(root, "chat.json")
    File.write!(config, JSON.encode!(profile()))
    previous = System.get_env(@slot)
    legacy_name = ReqLLM.credential_variable()
    legacy = System.get_env(legacy_name)
    System.put_env(@slot, "m7-chat-startup-synthetic-credential")
    {:ok, bytes} = StringIO.open("/quit\n", encoding: :latin1)
    {:ok, output} = StringIO.open("", encoding: :latin1)
    {:ok, diagnostic} = StringIO.open("", encoding: :latin1)
    input = spawn(fn -> input_relay(bytes, test, true) end)
    handler = make_ref()

    on_exit(fn ->
      :telemetry.detach(handler)
      for boundary <- @calls ++ @returns, do: :erlang.trace_pattern(boundary, false, [:local])
      Process.exit(input, :kill)
      for device <- [bytes, output, diagnostic], do: StringIO.close(device)
      restore_env(@slot, previous)
      restore_env(legacy_name, legacy)
      File.rm_rf!(root)
    end)

    :ok = :telemetry.attach(handler, [:loopex, :model, :complete, :start], &__MODULE__.model_start/4, test)
    for module <- Enum.uniq(Enum.map(@calls ++ @returns, &elem(&1, 0))) do
      assert {:module, ^module} = Code.ensure_loaded(module)
    end
    for boundary <- @calls, do: assert(:erlang.trace_pattern(boundary, true, [:local]) == 1)
    for boundary <- @returns do
      assert :erlang.trace_pattern(boundary, [{:_, [], [{:return_trace}]}], [:local]) == 1
    end

    {host, host_down} = spawn_monitor(fn ->
      observe_edges(test)
      :erlang.trace(self(), true, [:call, {:tracer, test}])
      result = Chat.run(["chat", "--config", config],
        cwd: root, home: home, input: input, output: output,
        diagnostic_device: diagnostic, mode: :pipe)
      send(test, {:chat_result, self(), result})
      receive do: (:finish -> :ok)
    end)
    on_exit(fn -> if Process.alive?(host), do: Process.exit(host, :kill) end)

    assert_receive {:trace, ^host, :return_from, {ChatDriver, :bootstrap, 3}, {:ok, driver}}, 5_000
    assert_receive {:runtime_owned, owner, runtime, consumer}, 5_000
    assert_receive {:startup_read, body, %{command_id: nil}}, 1_000
    assert_receive {:startup_task, observer, ^owner, _initial}, 1_000
    assert_receive {:startup_first_read, ^observer, ^runtime}, 1_000
    assert_receive {:startup_snapshot_pinned, ^owner, ^observer,
      {:ok, %{state: :starting, startup_id: startup_id, startup_deadline_ms: cutoff}}}, 1_000

    edges = for module <- [CredentialRegistry, CredentialCustody, Capability,
      Loopex.Store.Local, Loopex.Store.Local.Transfers, Loopex.Executor.Local.WorkspaceLease,
      Loopex.Executor.Local] do
      assert_receive {:edge_started, ^module, pid}, 1_000
      pid
    end
    {:ok, children} = Loopex.Runtime.children(runtime)
    workers = Task.Supervisor.children(children.workers)
    assert length(workers) >= 2
    assert observer in workers
    {carrier, group} = held_carrier(body, workers)
    assert carrier in workers
    boot = :sys.get_state(driver)
    actors = Enum.uniq([owner, runtime.supervisor, driver, boot.writer, consumer, body, group | edges ++ workers])
    monitors = Enum.map(actors, fn pid ->
      assert Process.alive?(pid)
      {pid, Process.monitor(pid)}
    end)
    {^observer, observer_down} = List.keyfind(monitors, observer, 0)
    on_exit(fn ->
      for pid <- actors, Process.alive?(pid), do: Process.exit(pid, :kill)
    end)

    assert {:ok, %{state: :starting, startup_id: ^startup_id, startup_deadline_ms: ^cutoff}} =
      Loopex.creation_startup_status(runtime, 1_000)
    assert boot.runtime == nil and boot.session == nil and boot.input_worker == nil
    assert boot.workers == %{}
    assert StringIO.contents(bytes) == {"/quit\n", ""}
    assert StringIO.contents(output) == {"", ""}
    refute elem(StringIO.contents(diagnostic), 1) =~ "/session/model"
    assert genesis(state_root) == []
    assert System.get_env(@slot) == nil
    trace_fence(host)
    refute_received {:trace, ^host, :call, {Loopex, :create_session, _}}
    refute_received {:trace, ^host, :call, {ChatDriver, :bind, _}}
    refute_received {:trace, ^host, :call, {DiagnosticConsumer, :settings_report, _}}
    refute_received {:trace, ^host, :call, {Interrupt, :install_chat, _}}
    refute_received :model_started
    refute_receive {:input_held, ^input, _, _}, 40
    refute_received {:chat_result, ^host, _}

    send(body, :release_startup)
    assert_receive {:DOWN, ^observer_down, :process, ^observer, _}, 1_000
    assert {:ok, %{state: :ready, startup_id: ^startup_id, startup_deadline_ms: ^cutoff}} =
      Loopex.creation_startup_status(runtime, 1_000)
    assert System.monotonic_time(:millisecond) < cutoff
    assert_receive {:trace, ^host, :call, {Loopex, :create_session, [^runtime, _, create_options]}}, 1_000
    assert is_binary(create_options[:command_id])
    assert_receive {:trace, ^host, :call, {ChatDriver, :bind, [^driver, ^runtime, session, _]}}, 1_000
    assert_receive {:trace, ^host, :call, {Interrupt, :install_chat, [^driver, signal_ref, 5_000]}}, 1_000
    assert_receive {:trace, ^host, :return_from, {Interrupt, :install_chat, 3}, {:ok, manager}}, 1_000
    assert Interrupt.chat_live(manager, signal_ref)
    assert_receive {:input_held, ^input, input_worker, input_ref}, 1_000
    input_down = Process.monitor(input_worker)
    assert StringIO.contents(bytes) == {"/quit\n", ""}
    assert [_] = genesis(state_root)
    send(input, {:release_input, input_ref})
    assert_receive {:chat_result, ^host, 0}, 5_000

    trace_fence(host)
    refute_received {:trace, ^host, :call, {Loopex, :create_session, _}}
    refute_received :model_started
    assert StringIO.contents(bytes) == {"", ""}
    controls = controls(output)
    assert [closing] = Enum.filter(controls, &(&1["event"] == "closing"))
    assert closing["exit_code"] == 0 and closing["cleanup"] == "confirmed"
    assert closing["last_outcome"] == nil
    assert [admitted] = Enum.filter(controls, &(&1["event"] == "input"))
    assert admitted["disposition"] == "admitted"
    assert admitted["session_id"] == LoopexProtocol.Wire.encode_identity(session)
    refute Enum.any?(controls, &(&1["event"] == "error"))
    assert elem(StringIO.contents(diagnostic), 1) =~ "/session/model"
    refute Interrupt.chat_live(manager, signal_ref)
    assert {:ok, [%{session_id: ^session}]} = Loopex.list_sessions(state_root)
    assert [_] = genesis(state_root)
    refute Enum.any?(records(state_root), &(Map.get(&1, :kind) in
      ["run.started", "model_request_committed_v2", "model_request_committed_resources_v2",
       "model_attempt_opened_v1"]))
    for {actor, monitor} <- monitors, actor != observer do
      assert_receive {:DOWN, ^monitor, :process, ^actor, _}, 1_000
    end
    assert_receive {:DOWN, ^input_down, :process, ^input_worker, _}, 1_000
    send(host, :finish)
    assert_receive {:DOWN, ^host_down, :process, ^host, :normal}, 1_000
    refute_received :model_started
  end

  # Concept: this serial caller case refuses every actual model-start event.
  # Technical depth: ExUnit runs async:false cases after async cases. The span
  # identifies session/run/attempt, so no absent runtime_id field is filtered.
  @doc false
  def model_start(_event, _measurements, _metadata, test),
    do: send(test, :model_started)

  defp observe_edges(test) do
    reads = :atomics.new(1, [])
    Process.put(@edge, fn module, function, arguments ->
      result = if {module, function} == {Loopex, :start_link} do
        [options] = arguments
        Process.put({StartupGate, :test_listener}, test)
        original = Keyword.fetch!(options, :store)
        assert original.adapter == Loopex.Store.Local
        {:ok, store} = Loopex.Store.new(HeldLocal, %{store: original, test: test, reads: reads})
        result = Loopex.start_link(Keyword.put(options, :store, store))
        case result do
          {:ok, runtime} -> send(test, {:runtime_owned, self(), runtime,
            options[:diagnostics_to]})
          _ -> :ok
        end
        result
      else
        apply(module, function, arguments)
      end
      case result do
        {:ok, pid} when is_pid(pid) -> send(test, {:edge_started, module, pid})
        _ -> :ok
      end
      result
    end)
  end

  # Concept: retain the nested Store body separately from its direct carrier.
  # Technical depth: the carrier's actual body/group monitors and group links
  # identify original actors while the callback is held, without Control reads.
  defp held_carrier(body, workers) do
    {:monitored_by, owners} = Process.info(body, :monitored_by)
    [carrier] = Enum.filter(workers, &(&1 in owners))
    {:monitors, monitors} = Process.info(carrier, :monitors)
    assert {:process, body} in monitors
    {:links, links} = Process.info(body, :links)
    [group] = for {:process, pid} <- monitors, pid in links, do: pid
    {:links, group_links} = Process.info(group, :links)
    assert body in group_links and carrier in group_links
    refute body in workers
    refute group in workers
    {carrier, group}
  end

  # Concept: ordinary quit input remains unread until actual readiness is inspected.
  # Technical depth: only the first standard IO request is held; its original
  # request and response are relayed unchanged to the actual Latin-1 StringIO.
  defp input_relay(bytes, test, hold?) do
    receive do
      {:io_request, reader, reply, request} ->
        if hold? do
          send(test, {:input_held, self(), reader, reply})
          receive do: ({:release_input, ^reply} -> :ok)
        end
        forwarded = make_ref()
        send(bytes, {:io_request, self(), forwarded, request})
        receive do
          {:io_reply, ^forwarded, result} -> send(reader, {:io_reply, reply, result})
        end
        input_relay(bytes, test, false)
    end
  end

  defp trace_fence(host) do
    delivered = :erlang.trace_delivered(host)
    assert_receive {:trace_delivered, ^host, ^delivered}, 1_000
  end

  defp genesis(root), do: Enum.filter(records(root), &(Map.get(&1, :kind) == "session_genesis_v3"))
  defp records(root) do
    assert {:ok, frames, :complete} = Log.read(Path.join(root, "store.log"))
    for frame <- frames, record <- frame.records, do: record.payload
  end

  defp controls(output) do
    {_, transcript} = StringIO.contents(output)
    for "@loopex " <> json <- String.split(transcript, "\n"), do: JSON.decode!(json)
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)

  defp profile do
    %{
      "schema_version" => 1,
      "providers" => %{"anthropic" => %{"credential" => %{"env" => @slot}}},
      "policy" => "allow-all",
      "paths" => %{"workspace" => "workspace", "state_root" => "state"},
      "session" => %{
        "model" => "anthropic:claude-haiku-4-5", "tools" => "none", "max_tokens" => 128,
        "system_class_tokens" => 8000, "cleanup_grace_ms" => 5_000,
        "instructions" => %{"system_file" => "system.txt"},
        "bounds" => %{"max_turns" => 8, "deadline_ms" => 60_000, "token_budget" => 10_000}
      }
    }
  end

  # Concept: startup reads real Local data and every creation remains real.
  # Technical depth: this Store wrapper holds only the original first recovery
  # read, then delegates every callback unchanged to the captured Local Store.
  defmodule HeldLocal do
    @moduledoc false
    @behaviour Loopex.Store
    for {function, arity} <- [transact: 2, transaction_status: 4, runtime_command: 2,
      ownership_head: 3, load_records: 4, load_events: 4, creation_provenance: 3] do
      arguments = Macro.generate_arguments(arity - 1, __MODULE__)
      @impl true
      def unquote(function)(reference, unquote_splicing(arguments)),
        do: delegate(reference, unquote(function), [unquote_splicing(arguments)])
    end
    @impl true
    def creation_recovery(reference, request) do
      if :atomics.add_get(reference.reads, 1, 1) == 1 do
        send(reference.test, {:startup_read, self(), request})
        receive do: (:release_startup -> :ok)
      end
      delegate(reference, :creation_recovery, [request])
    end
    defp delegate(reference, function, arguments),
      do: apply(reference.store.adapter, function, [reference.store.reference | arguments])
  end
end
