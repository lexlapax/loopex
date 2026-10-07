# Concept: load the shared real-transport fixture only under a disposable home.
# Technical depth: its Core support guard runs before ExUnit setup.
fixture_home =
  Path.join(System.tmp_dir!(), "native-switch-load-#{System.unique_integer([:positive])}")

File.mkdir_p!(fixture_home)
prior_home = System.get_env("LOOPEX_HOME")
System.put_env("LOOPEX_HOME", fixture_home)

try do
  Code.require_file(
    "../../loopex_llm_reqllm/test/support/provider_isolation_fixture.exs",
    __DIR__
  )

  Code.require_file("../../loopex/test/support/configured_genesis_helper.exs", __DIR__)
after
  if prior_home,
    do: System.put_env("LOOPEX_HOME", prior_home),
    else: System.delete_env("LOOPEX_HOME")

  File.rm_rf!(fixture_home)
end

defmodule LoopexComposition.NativeModelSwitchTest do
  use ExUnit.Case, async: false

  alias Loopex.LLM.ReqLLM.ProviderIsolationFixture, as: Fixture
  alias Loopex.Runtime.{Instructions, OwnerGroup, SessionCoordinator, SessionState}
  alias Loopex.Store.Local
  alias Loopex.Trace.Capability
  alias Loopex.Executor.Local, as: LocalExecutor
  alias Loopex.Executor.Local.WorkspaceLease
  alias LoopexComposition.WorkspaceIdentity
  alias LoopexComposition.{Model, ProviderBindings}

  @model_a "anthropic:claude-fable-5-1"
  @model_b "anthropic:claude-haiku-4-5-20251001"
  @key "native-switch-synthetic-credential"
  @private_a "FIRST_PRIVATE_THINKING_CANARY"
  @signature_a "first-private-signature+/="
  @private_next "SECOND_PRIVATE_THINKING_CANARY"
  @signature_next "second-private-signature+/="

  setup do
    root = Path.join(System.tmp_dir!(), "native-switch-#{System.unique_integer([:positive])}")
    home = Path.join(root, "home")
    workspace = Path.join(root, "workspace")
    File.mkdir_p!(home)
    File.mkdir_p!(workspace)
    previous = Map.new(~w(LOOPEX_HOME LOOPEX_WORKSPACE), &{&1, System.get_env(&1)})
    System.put_env("LOOPEX_HOME", home)
    System.put_env("LOOPEX_WORKSPACE", workspace)

    on_exit(fn ->
      for {name, value} <- previous do
        if value, do: System.put_env(name, value), else: System.delete_env(name)
      end

      File.rm_rf!(root)
    end)

    {:ok, root: root}
  end

  test "real isolated transport preserves A to B to A history across physical Store reopen", %{
    root: root
  } do
    {:links, before_links} = Process.info(self(), :links)
    http_nonce = make_ref()

    fixture =
      Fixture.new(:delayed_entry,
        http_custody: {self(), http_nonce},
        credential: @key,
        response_bodies: [
          response(@model_a, "The gate is cedar.", {@private_a, @signature_a}),
          response(@model_b, "The gate stays cedar; the count is seven.", nil),
          response(
            @model_a,
            "Cedar and seven remain the facts.",
            {@private_next, @signature_next}
          )
        ]
      )

    {:links, after_links} = Process.info(self(), :links)
    fixture_links = after_links -- before_links
    fixture_ports = Enum.filter(fixture_links, &is_port/1)
    assert length(fixture_ports) == 2 and fixture.listener in fixture_ports
    # Concept: original factory actors have caller-scoped identities before work.
    # Technical depth: the fixture creates its hidden probe with spawn_link; the
    # link delta includes that exact actor, without a global trace or new port.
    fixture_actors = Enum.filter(fixture_links, &is_pid/1) ++ [fixture.store_pid]
    {:ok, fixture_children} = Loopex.Runtime.children(fixture.runtime)
    fixture_monitors = monitor(fixture_actors ++ Map.values(fixture_children))
    path = Path.join(root, "state.log")
    # Concept: physical reopen preserves the session's creating runtime identity.
    # Technical depth: process incarnations and tracing capabilities change;
    # the Store's durable placement ID is captured once for both starts.
    runtime_id = "switch-#{System.unique_integer([:positive])}"

    model =
      Model.reference(%{module: Loopex.LLM.ReqLLM, model: @model_a, options: fixture.options},
        provider_bindings: bindings()
      )

    initial = initial_configuration()
    assert initial["context_token_budget"] == 8_192
    assert initial["system_class_tokens"] == 1_000

    try do
      {session, prefix_records, prefix_events, first_runs, configured_b} =
        with_runtime(path, model, runtime_id, fn runtime, store, custody ->
          assert {:ok, session} =
                   Loopex.create_session(runtime, %{},
                     command_id: "create",
                     genesis: Loopex.ConfiguredGenesisFixture.genesis([], initial)
                   )

          assert {:ok, attachment} = Loopex.attach(runtime, session, after_event_sequence: 0)

          first =
            run(runtime, attachment, fixture, custody, "prompt-a", "Remember: the gate is cedar.")

          configured_b =
            configure(attachment, model, initial, "configure-b", %{
              "model" => "anthropic:claude-haiku-4-5",
              "reasoning" => "none"
            })

          assert configured_b["model"] == @model_b
          assert configured_b["context_token_budget"] == 8_192
          assert configured_b["system_class_tokens"] == 1_000

          second =
            run(
              runtime,
              attachment,
              fixture,
              custody,
              "prompt-b",
              "Keep cedar; add the count seven."
            )

          {records, events, state} = history(store, session)
          assert state.configuration == configured_b

          assert Enum.map(
                   state.run_order,
                   &SessionState.run_configuration(state, &1)["configuration_version"]
                 ) == [1, 2]

          assert Enum.map(state.run_order, &SessionState.run_configuration(state, &1)["model"]) ==
                   [@model_a, @model_b]

          assert state.run_order == [first, second]
          [settled_a, _settled_b] = settlements(records)
          capsule = settled_a.payload["result"]["reply"]["continuation"]
          assert is_map(capsule)
          assert capsule["status"] == "closed"
          assert capsule["model"] == @model_a
          assert :erlang.term_to_binary(capsule) =~ @private_a
          assert :erlang.term_to_binary(capsule) =~ @signature_a
          assert_public_private_absence(events, attachment)
          {session, records, events, state.run_order, configured_b}
        end)

      assert length(Fixture.events(fixture)) == 2
      before_reopen = File.read!(path)

      with_runtime(path, model, runtime_id, fn runtime, store, custody ->
        assert {:ok, ^session} = Loopex.resume_session(runtime, session, command_id: "resume")
        {resumed_records, resumed_events, resumed} = history(store, session)
        assert Enum.take(resumed_records, length(prefix_records)) == prefix_records
        assert Enum.take(resumed_events, length(prefix_events)) == prefix_events
        assert resumed.configuration == configured_b
        assert resumed.configuration["context_token_budget"] == 8_192
        assert resumed.configuration["system_class_tokens"] == 1_000
        assert resumed.run_order == first_runs
        assert length(Fixture.events(fixture)) == 2
        assert String.starts_with?(File.read!(path), before_reopen)

        assert {:ok, attachment} =
                 Loopex.attach(runtime, session, after_event_sequence: resumed.event_sequence)

        configured_a =
          configure(attachment, model, configured_b, "configure-a", %{
            "model" => @model_a,
            "reasoning" => "low"
          })

        third =
          run(
            runtime,
            attachment,
            fixture,
            custody,
            "prompt-a-again",
            "Repeat both retained facts."
          )

        {records, events, state} = history(store, session)
        assert state.configuration == configured_a
        assert state.run_order == first_runs ++ [third]
        configurations = Enum.map(state.run_order, &SessionState.run_configuration(state, &1))
        assert configurations == [initial, configured_b, configured_a]
        assert Enum.map(configurations, & &1["configuration_version"]) == [1, 2, 3]
        assert Enum.map(configurations, & &1["model"]) == [@model_a, @model_b, @model_a]
        assert Enum.map(configurations, & &1["reasoning"]) == ["low", "none", "low"]
        assert Enum.all?(configurations, &(&1["max_tokens"] == 1_024))
        assert Enum.all?(configurations, &(&1["context_token_budget"] == 8_192))
        assert Enum.all?(configurations, &(&1["system_class_tokens"] == 1_000))
        [_, _, settled_again] = settlements(records)
        capsule_again = settled_again.payload["result"]["reply"]["continuation"]
        assert capsule_again["status"] == "closed"
        assert capsule_again["model"] == @model_a
        assert :erlang.term_to_binary(capsule_again) =~ @private_next
        assert :erlang.term_to_binary(capsule_again) =~ @signature_next
        assert length(settlements(records)) == 3

        assert length(Enum.filter(records, &(&1.payload.kind == "model_request_committed_v2"))) ==
                 3

        assert_public_private_absence(events, attachment)
      end)

      assert [{body_a, true}, {body_b, true}, {body_again, true}] = Fixture.events(fixture)

      assert Enum.map([body_a, body_b, body_again], & &1["model"]) ==
               ["claude-fable-5-1", "claude-haiku-4-5-20251001", "claude-fable-5-1"]

      assert Enum.all?([body_a, body_b, body_again], &(&1["max_tokens"] == 1_024))
      assert body_a["thinking"] == %{"type" => "adaptive", "display" => "summarized"}
      assert body_again["thinking"] == body_a["thinking"]
      assert body_a["output_config"] == %{"effort" => "low"}
      assert body_again["output_config"] == body_a["output_config"]
      assert body_b["thinking"] == %{"type" => "disabled"}
      refute Map.has_key?(body_b, "output_config")

      assert body_a["messages"] ==
               messages([
                 {"user", "Remember: the gate is cedar."}
               ])

      assert body_b["messages"] ==
               messages([
                 {"user", "Remember: the gate is cedar."},
                 {"assistant", "The gate is cedar."},
                 {"user", "Keep cedar; add the count seven."}
               ])

      assert body_again["messages"] ==
               messages([
                 {"user", "Remember: the gate is cedar."},
                 {"assistant", "The gate is cedar."},
                 {"user", "Keep cedar; add the count seven."},
                 {"assistant", "The gate stays cedar; the count is seven."},
                 {"user", "Repeat both retained facts."}
               ])

      for body <- [body_a, body_b, body_again], private <- private_values() do
        refute Jason.encode!(body) =~ private
      end

      assert Fixture.methods(fixture) == ["POST", "POST", "POST"]
    after
      # Concept: fixture infrastructure is retired before its disposable files.
      # Technical depth: all original factory monitors predate the first request;
      # one captured cleanup endpoint covers sockets, runtime, servers and joins.
      cutoff = now() + 5_000
      for port <- fixture_ports, do: :ok = :gen_tcp.close(port)
      if Loopex.Runtime.alive?(fixture.runtime), do: assert(:ok == Loopex.stop(fixture.runtime))

      for pid <- [
            fixture.workers,
            fixture.capability_pid,
            fixture.store_pid,
            fixture.registry_pid,
            fixture.custody_pid,
            fixture.events,
            fixture.transport_events,
            fixture.probe_events,
            fixture.request_headers
          ] do
        if Process.alive?(pid), do: assert(:ok == GenServer.stop(pid, :normal, left(cutoff)))
      end

      join(fixture_monitors, cutoff)
    end
  end

  defp bindings,
    do: %{"anthropic" => %{"credential" => %{"env" => "NATIVE_SWITCH_HOST_REFERENCE"}}}

  defp initial_configuration do
    {:ok, instructions} =
      Instructions.capture(%{
        "version" => "switch.v1",
        "base" => "Keep the exact committed facts.",
        "environment" => "",
        "appendix" => ""
      })

    assert {:ok, configuration} =
             ProviderBindings.resolve_configuration(
               %{
                 "model" => @model_a,
                 "reasoning" => "low",
                 "configuration_version" => 1,
                 "max_tokens" => 1_024,
                 "context_token_budget" => 8_192,
                 "system_class_tokens" => 1_000,
                 "instructions" => instructions
               },
               bindings(),
               []
             )

    configuration
  end

  defp configure(attachment, model, current, command_id, changes) do
    context = %{deadline_monotonic_ms: now() + 10_000, cleanup_grace_ms: 5_000}

    assert {:ok, candidate} =
             Model.prepare_configuration(current, changes, [], context, model.options)

    assert {:accepted, ^command_id} =
             Loopex.command_with_configuration(
               attachment,
               %{type: :configure, command_id: command_id, changes: changes},
               candidate
             )

    candidate
  end

  defp with_runtime(path, model, runtime_id, fun) do
    custody = make_ref()
    resources = make_ref()
    Process.put(custody, [])
    Process.put(resources, %{runtime: nil, owners: []})

    try do
      # Concept: each reopened runtime owns its own managed tracing capability.
      # Technical depth: preserve the fixture's other adapter options; retain
      # the fresh original actor before obtaining or binding its handle.
      assert {:ok, capability_owner} = Capability.start_link([])
      retain_resource(custody, resources, capability_owner)
      assert {:ok, capability} = Capability.handle(capability_owner)
      adapter_options = Keyword.fetch!(model.options, :adapter_options)

      runtime_model = %{
        model
        | options:
            Keyword.put(
              model.options,
              :adapter_options,
              Keyword.put(adapter_options, :tracing_capability, capability)
            )
      }

      assert {:ok, store} = Local.start_link(path: path)
      retain_resource(custody, resources, store)
      assert {:ok, store_reference} = Loopex.Store.new(Local, store)
      workspace = System.fetch_env!("LOOPEX_WORKSPACE")
      assert {:ok, workspace_ref} = WorkspaceIdentity.reference(workspace)

      assert {:ok, lease} =
               WorkspaceLease.start_link(
                 id: "native-switch-workspace",
                 path: workspace,
                 fencing_token: 1
               )

      retain_resource(custody, resources, lease)

      assert {:ok, executor} =
               LocalExecutor.start_link(
                 identity: "native-switch-local",
                 epoch: 1,
                 fencing_token: 1,
                 workspace_leases: %{"native-switch-workspace" => lease},
                 ledger_root: Path.join(Path.dirname(path), "executor-receipts"),
                 cleanup_grace_ms: 5_000
               )

      retain_resource(custody, resources, executor)

      assert {:ok, runtime} =
               Loopex.start_link(
                 runtime_id: runtime_id,
                 store: store_reference,
                 context_token_budget: 8_192,
                 bounds: %{max_turns: 4, token_budget: 8_192, deadline_ms: 10_000},
                 cleanup_grace_ms: 5_000,
                 model: runtime_model,
                 executor: %{
                   module: LocalExecutor,
                   reference: executor,
                   identity: "native-switch-local",
                   epoch: 1,
                   fencing_token: 1,
                   workspace_ref: workspace_ref,
                   workspace_lease: "native-switch-workspace"
                 },
                 grant_decision: {:host_policy, :allow},
                 tools: [],
                 active_tools: []
               )

      Process.put(resources, %{Process.get(resources) | runtime: runtime})
      Process.put(custody, Process.get(custody) ++ monitor([runtime.supervisor]))
      assert {:ok, children} = Loopex.Runtime.children(runtime)
      Process.put(custody, Process.get(custody) ++ monitor(Map.values(children)))
      assert :ok = Capability.bind(capability, runtime)
      fun.(runtime, store, custody)
    after
      # Concept: failed startup still retires every resource it already opened.
      # Technical depth: retain each original PID immediately after creation;
      # runtime joins precede hand/lease/Store/capability release under one cutoff.
      cutoff = now() + 5_000
      %{runtime: runtime, owners: owners} = Process.delete(resources)
      monitors = Process.delete(custody)

      {resource_monitors, runtime_monitors} =
        Enum.split_with(monitors, fn {pid, _reference} -> pid in owners end)

      if runtime, do: assert(:ok == Loopex.stop(runtime))
      join(runtime_monitors, cutoff)

      if runtime do
        [executor, _lease, _store, _capability_owner] = owners
        assert GenServer.call(executor, :stats, left(cutoff)).dispatches == %{}
      end

      for owner <- owners do
        if Process.alive?(owner), do: assert(:ok == GenServer.stop(owner, :normal, left(cutoff)))
      end

      join(resource_monitors, cutoff)
    end
  end

  defp retain_resource(custody, resources, owner) do
    Process.put(custody, Process.get(custody) ++ monitor([owner]))
    retained = Process.get(resources)
    Process.put(resources, %{retained | owners: [owner | retained.owners]})
  end

  defp run(runtime, attachment, fixture, custody, command_id, content) do
    for name <- ~w(pid namespace release), do: File.rm(Fixture.marker(fixture, name))
    work_cutoff = now() + 10_000
    cleanup_cutoff = work_cutoff + 5_000
    {http_observer, http_nonce} = fixture.http_custody
    assert http_observer == self()
    http_request = make_ref()

    send(
      fixture.acceptor,
      {:fixture_http_bound, self(), http_nonce, http_request, work_cutoff, cleanup_cutoff}
    )

    assert {:accepted, ^command_id} =
             Loopex.command(
               attachment,
               %{type: :prompt, command_id: command_id, content: content}
             )

    await(fn -> Fixture.reached?(fixture, "namespace") end, work_cutoff)
    assert {:ok, children} = Loopex.Runtime.children(runtime)
    [{_, coordinator, :worker, _}] = DynamicSupervisor.which_children(children.sessions)
    [{_, group, :worker, _}] = Supervisor.which_children(children.owner_groups)
    assert {:ok, private_workers} = OwnerGroup.workers(group)

    %{coordinator: ^coordinator, workers: ^private_workers, providers: providers} =
      :sys.get_state(group, left(work_cutoff))

    [{reference, provider}] = Map.to_list(providers)
    assert provider.retainer == coordinator and provider.caretaker == nil
    assert is_pid(provider.resource) and is_pid(provider.worker) and is_pid(provider.guard)

    assert Enum.sort(provider.original_members) ==
             Enum.sort([provider.resource, provider.worker, provider.guard])

    {:dictionary, dictionary} = Process.info(provider.guard, :dictionary)
    callback_key = {{SessionCoordinator, :provider_callback}, reference}
    {^callback_key, callback} = List.keyfind(dictionary, callback_key, 0)
    assert is_pid(callback) and Process.alive?(callback)
    invocation_monitors = monitor([callback | provider.original_members])
    old = Process.get(custody)

    new_actors =
      Enum.reject([coordinator, group, private_workers], fn pid ->
        Enum.any?(old, &(elem(&1, 0) == pid))
      end)

    Process.put(custody, old ++ monitor(new_actors))
    child = Fixture.pid(fixture)
    namespace = Fixture.namespace(fixture)
    assert Fixture.alive?(child) and File.dir?(namespace)
    Fixture.release(fixture)
    acceptor = fixture.acceptor

    {handler, socket} =
      receive do
        {:fixture_http_owned, ^acceptor, ^http_nonce, ^http_request, handler, socket,
         ^work_cutoff, ^cleanup_cutoff} ->
          {handler, socket}
      after
        left(work_cutoff) -> flunk("actual HTTP handler did not reach its original custody gate")
      end

    assert Process.alive?(handler)
    assert is_port(socket)
    assert Port.info(socket, :connected) == {:connected, handler}
    handler_monitor = Process.monitor(handler)
    socket_monitor = :erlang.monitor(:port, socket)
    assert now() < work_cutoff
    send(acceptor, {:fixture_http_release, self(), http_nonce, http_request, handler, socket})
    terminal = finished(attachment, work_cutoff)
    assert terminal["outcome"] == "completed"
    join(invocation_monitors, cleanup_cutoff)

    receive do
      {:DOWN, ^socket_monitor, :port, ^socket, :normal} -> :ok
    after
      left(cleanup_cutoff) -> flunk("original accepted HTTP socket did not close")
    end

    receive do
      {:DOWN, ^handler_monitor, :process, ^handler, :normal} -> refute Process.alive?(handler)
    after
      left(cleanup_cutoff) -> flunk("original accepted HTTP handler did not join")
    end

    Fixture.assert_gone(fixture)
    refute Fixture.alive?(child)
    refute File.exists?(namespace)
    assert now() < cleanup_cutoff

    await(
      fn ->
        :sys.get_state(group, left(cleanup_cutoff)).providers == %{} and
          Supervisor.which_children(private_workers) == []
      end,
      cleanup_cutoff
    )

    terminal["run_id"]
  end

  defp history(store, session) do
    assert {:ok, records} = Local.load_records(store, session, 0, 1_000)
    assert {:ok, events} = Local.load_events(store, session, 0, 1_000)
    assert length(records) < 1_000 and length(events) < 1_000
    assert {:ok, state} = SessionState.recover(session, records, events)
    assert state.journal_version == length(records)
    assert state.event_sequence == length(events)
    {records, events, state}
  end

  defp settlements(records),
    do: Enum.filter(records, &(&1.payload.kind == "model_attempt_settled_v3"))

  defp assert_public_private_absence(events, attachment) do
    assert {:ok, current} =
             Loopex.attach(attachment.runtime, attachment.session_id,
               after_event_sequence: length(events)
             )

    snapshot = Loopex.snapshot(current)
    assert is_map(snapshot)

    for private <- private_values() do
      refute :erlang.term_to_binary(events) =~ private
      refute :erlang.term_to_binary(snapshot) =~ private
    end
  end

  defp private_values, do: [@private_a, @signature_a, @private_next, @signature_next, @key]

  defp messages(pairs),
    do:
      Enum.map(pairs, fn {role, text} ->
        %{"role" => role, "content" => [%{"type" => "text", "text" => text}]}
      end)

  defp finished(attachment, cutoff) do
    case Loopex.next_event(attachment) do
      {:ok, %{kind: "run.finished"} = event} ->
        event

      _ ->
        assert now() < cutoff, "run did not finish within its captured work cutoff"
        Process.sleep(10)
        finished(attachment, cutoff)
    end
  end

  defp monitor(pids),
    do:
      Enum.map(Enum.uniq(pids), fn pid ->
        assert is_pid(pid) and Process.alive?(pid)
        {pid, Process.monitor(pid)}
      end)

  defp join(monitors, cutoff) do
    for {pid, reference} <- monitors do
      receive do
        {:DOWN, ^reference, :process, ^pid, _reason} -> refute Process.alive?(pid)
      after
        left(cutoff) ->
          flunk("original actor did not join within captured cutoff: #{inspect(pid)}")
      end
    end

    assert now() < cutoff
  end

  defp await(check, cutoff) do
    if check.() do
      :ok
    else
      assert now() < cutoff, "native entry did not reach its gate"
      Process.sleep(10)
      await(check, cutoff)
    end
  end

  defp now, do: System.monotonic_time(:millisecond)
  defp left(cutoff), do: max(cutoff - now(), 0)

  defp response(model, text, private) do
    content =
      if private do
        {thinking, signature} = private

        [
          %{"type" => "thinking", "thinking" => thinking, "signature" => signature},
          %{"type" => "text", "text" => text}
        ]
      else
        [%{"type" => "text", "text" => text}]
      end

    start = %{
      "type" => "message_start",
      "message" => %{
        "id" => "switch-reply",
        "type" => "message",
        "role" => "assistant",
        "model" => String.replace_prefix(model, "anthropic:", ""),
        "content" => [],
        "stop_reason" => nil,
        "stop_sequence" => nil,
        "usage" => %{"input_tokens" => 11}
      }
    }

    blocks =
      Enum.flat_map(Enum.with_index(content), fn {block, index} ->
        {initial, deltas} =
          case block do
            %{"type" => "text", "text" => bytes} ->
              {%{"type" => "text", "text" => ""}, [%{"type" => "text_delta", "text" => bytes}]}

            %{"type" => "thinking", "thinking" => bytes, "signature" => signature} ->
              {%{"type" => "thinking", "thinking" => "", "signature" => ""},
               [
                 %{"type" => "thinking_delta", "thinking" => bytes},
                 %{"type" => "signature_delta", "signature" => signature}
               ]}
          end

        [%{"type" => "content_block_start", "index" => index, "content_block" => initial}] ++
          Enum.map(deltas, &%{"type" => "content_block_delta", "index" => index, "delta" => &1}) ++
          [%{"type" => "content_block_stop", "index" => index}]
      end)

    tail = [
      %{
        "type" => "message_delta",
        "delta" => %{"stop_reason" => "end_turn", "stop_sequence" => nil},
        "usage" => %{"output_tokens" => 4}
      },
      %{"type" => "message_stop"}
    ]

    Enum.map_join([start] ++ blocks ++ tail, fn event ->
      "event: #{event["type"]}\ndata: #{Jason.encode!(event)}\n\n"
    end)
  end
end
