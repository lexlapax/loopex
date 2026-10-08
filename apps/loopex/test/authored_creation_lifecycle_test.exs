Code.require_file("support/m1_runtime_helper.exs", __DIR__)
Code.require_file("support/agent_loop_adapters.exs", __DIR__)
Code.require_file("support/configured_genesis_helper.exs", __DIR__)
Code.require_file("support/model_preparation_conformance.exs", __DIR__)

defmodule Loopex.AuthoredCreationLifecycleTest do
  use ExUnit.Case, async: false
  alias Loopex.ConfiguredGenesisFixture, as: Captured
  alias Loopex.M1RuntimeTestStore, as: Fixture
  alias Loopex.ModelPreparationConformance, as: Conformance
  alias Loopex.Runtime
  alias Loopex.Store

  defmodule Preparing do
    @moduledoc false
    @behaviour Loopex.Model
    alias Loopex.Runtime.ProviderLifetime

    @impl true
    def complete(_request, options, _progress) do
      send(Keyword.fetch!(options, :observer), :unexpected_model_dispatch)
      {:error, :unavailable}
    end

    @impl true
    def prepare_configuration(current, changes, definitions, context, options) do
      controller = Keyword.fetch!(options, :controller)

      selection =
        Agent.get_and_update(controller, fn state ->
          {state, %{state | calls: state.calls + 1}}
        end)

      send(
        selection.observer,
        {:preparing, self(), current, changes, definitions, context, options}
      )

      canonical =
        if Map.has_key?(changes, "model"), do: selection.canonical, else: current["model"]

      case selection.mode do
        :raise ->
          raise "PRIVATE_AUTHORED_PREPARATION_CANARY"

        :refuse ->
          {:error, %{private: "PRIVATE_AUTHORED_PREPARATION_CANARY"}}

        :malformed ->
          {:ok, %{private: "PRIVATE_AUTHORED_PREPARATION_CANARY"}}

        :hold ->
          receive do
            :release -> :ok
          end

          Conformance.candidate(current, changes, definitions, canonical)

        mode ->
          lifetime(mode, selection)
          Conformance.candidate(current, changes, definitions, canonical)
      end
    end

    defp lifetime(mode, selection) when mode in [:descendant, :nested, :hold_descendant] do
      {:managed, starter} = ProviderLifetime.starter()
      observer = selection.observer
      callback = self()

      {:ok, child} =
        ProviderLifetime.start_child(starter, fn ->
          Process.flag(:trap_exit, true)

          if mode == :nested do
            {:ok, grandchild} = ProviderLifetime.start_child(starter, fn -> actor(observer) end)
            send(observer, {:grandchild, grandchild})
            send(callback, {:nested_started, self()})
          end

          send(observer, {:child_started, self()})

          receive do
            {:EXIT, _owner, :shutdown} -> :ok
          end
        end)

      send(observer, {:managed_child, child})

      if mode == :nested,
        do:
          (receive do
             {:nested_started, ^child} -> :ok
           end)

      if mode == :hold_descendant,
        do:
          (receive do
             :release -> :ok
           end)
    end

    defp lifetime(mode, selection)
         when mode in [:resource_ack, :resource_hold, :resource_noack] do
      observer = selection.observer
      reference = make_ref()

      resource =
        spawn(fn ->
          receive do
            {:loopex_provider_resource_stop, ^reference, stop, stopper, cooperative, observe} ->
              send(observer, {:resource_stopping, self(), stop, stopper, cooperative, observe})

              if mode == :resource_hold,
                do:
                  (receive do
                     :release -> :ok
                   end)

              if mode != :resource_noack,
                do: send(stopper, {:loopex_provider_resource_stopped, stop, self()})
          end
        end)

      {:managed, guardian, 5_000} = ProviderLifetime.register(resource, reference)
      send(observer, {:registered_resource, resource, guardian})
    end

    defp lifetime(:late_first_offer, selection) do
      Process.flag(:trap_exit, true)
      send(selection.observer, {:late_callback_ready, self()})

      receive do
        {:EXIT, _owner, :shutdown} -> :ok
      end

      send(selection.observer, {:late_cleanup_started, self()})

      receive do
        :offer_resource -> :ok
      end

      reference = make_ref()
      resource = held_resource(selection.observer, reference)
      result = ProviderLifetime.register(resource, reference)
      send(selection.observer, {:late_offer_result, self(), resource, result})
    end

    defp lifetime(:held_first_offer, selection) do
      send(selection.observer, {:offer_callback_ready, self()})

      receive do
        :offer_resource -> :ok
      end

      reference = make_ref()
      resource = held_resource(selection.observer, reference)
      send(selection.observer, {:first_offer_created, self(), resource, reference})
      _result = ProviderLifetime.register(resource, reference)
    end

    defp lifetime(:duplicate_resource, selection) do
      reference = make_ref()
      resource = held_resource(selection.observer, reference)
      {:managed, guardian, 5_000} = ProviderLifetime.register(resource, reference)
      send(selection.observer, {:registered_resource, resource, guardian})
      # The refused distinct offer remains the adapter's resource. Its link
      # protects the pre-offer/refusal gap if this real callback is killed.
      {duplicate, monitor} =
        :erlang.spawn_opt(
          fn ->
            receive do
              :adapter_reap -> :ok
            end
          end,
          [:link, :monitor]
        )

      result = ProviderLifetime.register(duplicate, make_ref())
      send(selection.observer, {:duplicate_refused, self(), duplicate, result})

      receive do
        :reap_duplicate -> :ok
      end

      send(duplicate, :adapter_reap)

      receive do
        {:DOWN, ^monitor, :process, ^duplicate, :normal} ->
          send(selection.observer, {:duplicate_reaped, duplicate})
      after
        1_000 -> raise "host-owned duplicate did not join"
      end
    end

    defp lifetime(:managed_duplicate, selection) do
      reference = make_ref()
      resource = held_resource(selection.observer, reference)
      {:managed, guardian, 5_000} = ProviderLifetime.register(resource, reference)
      send(selection.observer, {:registered_resource, resource, guardian})
      {:managed, starter} = ProviderLifetime.starter()
      callback = self()
      observer = selection.observer

      {:ok, duplicate} =
        ProviderLifetime.start_child(starter, fn ->
          Process.flag(:trap_exit, true)
          send(callback, {:duplicate_child_ready, self()})

          receive do
            {:EXIT, _owner, :shutdown} ->
              send(observer, {:duplicate_child_stopping, self()})

              receive do
                :release -> :ok
              end
          end
        end)

      receive do
        {:duplicate_child_ready, ^duplicate} -> :ok
      end

      result = ProviderLifetime.register(duplicate, make_ref())
      send(observer, {:managed_duplicate_refused, duplicate, result})
    end

    defp lifetime(:normal, _selection), do: :ok

    defp held_resource(observer, reference) do
      spawn(fn ->
        receive do
          {:loopex_provider_resource_stop, ^reference, stop, stopper, cooperative, observe} ->
            send(observer, {:resource_stopping, self(), stop, stopper, cooperative, observe})

            receive do
              :release -> :ok
            end

            send(stopper, {:loopex_provider_resource_stopped, stop, self()})
        end
      end)
    end

    defp actor(observer) do
      Process.flag(:trap_exit, true)
      send(observer, {:child_started, self()})

      receive do
        {:EXIT, _owner, :shutdown} -> :ok
      end
    end
  end

  defmodule WithoutPreparation do
    @moduledoc false
    @behaviour Loopex.Model
    @impl true
    def complete(_request, options, _progress) do
      send(Keyword.fetch!(options, :observer), :unexpected_model_dispatch)
      {:error, :unavailable}
    end
  end

  test "default and explicitly empty tools use captured genesis without preparation" do
    f = fixture()

    for {command, options} <- [
          {"default", %{"version" => 1}},
          {"none", %{"version" => 1, "tools" => []}}
        ] do
      assert {:ok, session} = create(f.runtime, command, options)
      ready(f.control)
      [first | rest] = records(f, session)
      assert first.payload.kind == "session_genesis_v3"
      assert first.payload["options"] == options
      assert first.payload["tool_selection"]["definitions"] == []
      assert first.payload["initial_configuration"]["configuration_version"] == 1
      refute Enum.any?(rest, &(&1.payload.kind == "session_configuration_admitted_v2"))
    end

    assert calls(f) == 0
    refute_received {:preparing, _, _, _, _, _, _}
    refute_received :unexpected_model_dispatch
  end

  test "initial alias is resolved once and the returned complete v2 changes only its version" do
    f = fixture()
    input = options(%{"model" => "authored-alias", "max_tokens" => 1_111})
    assert {:ok, session} = create(f.runtime, "prepared", input)
    assert_receive {:preparing, worker, current, changes, [], context, callback_options}, 1_000
    Conformance.assert_context(context, 5_000)
    assert changes == input["configuration"]
    assert callback_options == f.model.options
    {:ok, candidate} = Conformance.candidate(current, changes, [], "resolved:v2")
    [first | rest] = records(f, session)

    assert first.payload["initial_configuration"] ==
             Map.put(candidate, "configuration_version", 1)

    assert first.payload["options"] == input
    assert first.payload["initial_configuration"]["model"] == "resolved:v2"
    refute Enum.any?(rest, &(&1.payload.kind == "session_configuration_admitted_v2"))
    refute Process.alive?(worker)
    assert calls(f) == 1
    refute_received :unexpected_model_dispatch
  end

  test "ordered subsets retain exact admitted definitions and reject absent tool authority" do
    [first] =
      Path.expand("../priv/vectors/artifact_read.v1.json", __DIR__)
      |> File.read!()
      |> JSON.decode!()
      |> Map.fetch!("vectors")
      |> Enum.map(& &1["definition"])

    second = first |> Map.put("tool_id", "example.second") |> Map.put("name", "second_read")
    f = fixture(definitions: [first, second])
    input = %{"version" => 1, "tools" => ["second_read", "read"]}
    assert {:ok, session} = create(f.runtime, "ordered", input)
    ready(f.control)
    [record | _] = records(f, session)
    assert record.payload["tool_selection"]["definitions"] == [second, first]
    assert {:ok, ^session} = create(f.runtime, "ordered", input)

    assert {:error, :runtime_command_conflict} =
             create(f.runtime, "ordered", %{"version" => 1, "tools" => ["read", "second_read"]})

    before_calls = Fixture.inspect_state(f.store_pid).creation_calls

    assert {:error, :invalid_session_creation} =
             create(f.runtime, "unknown-tool", %{"version" => 1, "tools" => ["unadmitted"]})

    assert Fixture.inspect_state(f.store_pid).creation_calls == before_calls
    assert calls(f) == 0
  end

  test "omitted equal configuration tools and canonical spelling remain distinct retry identities" do
    f = fixture()
    input = options(%{"model" => "alias"})
    assert {:ok, session} = create(f.runtime, "presence", input)
    ready(f.control)

    for changed <- [
          %{"version" => 1},
          options(%{"model" => "resolved:v2"}),
          Map.put(input, "tools", [])
        ] do
      assert {:error, :runtime_command_conflict} = create(f.runtime, "presence", changed)
    end

    assert {:ok, ^session} = create(f.runtime, "presence", input)
    assert calls(f) == 1
  end

  test "all authored instruction sections are committed and compared on exact replay" do
    f = fixture()

    raw = %{
      "version" => "authored.v1",
      "base" => "Base\n",
      "environment" => "é",
      "appendix" => "Appendix"
    }

    input = options(%{"instructions" => raw})
    assert {:ok, session} = create(f.runtime, "instructions", input)
    ready(f.control)
    [first | _] = records(f, session)
    instructions = first.payload["initial_configuration"]["instructions"]
    assert Map.take(instructions, Map.keys(raw)) == raw

    assert first.payload["options"]["configuration"]["instructions"] ==
             Map.take(instructions, ~w(version digest))

    assert {:ok, ^session} = create(f.runtime, "instructions", input)

    for field <- ~w(version base environment appendix) do
      changed = options(%{"instructions" => Map.update!(raw, field, &(&1 <> "x"))})
      assert {:error, :runtime_command_conflict} = create(f.runtime, "instructions", changed)
    end

    assert calls(f) == 1
  end

  test "retained authored replay ignores changed defaults and model resolver" do
    f = fixture()
    input = options(%{"model" => "alias", "max_tokens" => 1_111})
    assert {:ok, session} = create(f.runtime, "replay", input)
    ready(f.control)
    before_calls = Fixture.inspect_state(f.store_pid).creation_calls

    :sys.replace_state(f.control, fn state ->
      %{state | session_creation_defaults: %{private: :unusable}, model: nil}
    end)

    Agent.update(f.controller, &%{&1 | mode: :raise, canonical: "changed:v9"})
    assert {:ok, ^session} = create(f.runtime, "replay", input)
    assert Fixture.inspect_state(f.store_pid).creation_calls == before_calls
    assert calls(f) == 1
    refute_received :unexpected_model_dispatch
  end

  test "an empty-default historical key is a conflict rather than a new authored preparation" do
    f = fixture()
    assert {:ok, _session} = Runtime.create_session(f.runtime, "occupied", %{})
    ready(f.control)
    before_calls = Fixture.inspect_state(f.store_pid).creation_calls

    assert {:error, :runtime_command_conflict} =
             create(f.runtime, "occupied", options(%{"max_tokens" => 1_111}))

    assert Fixture.inspect_state(f.store_pid).creation_calls == before_calls
    assert calls(f) == 0
  end

  test "changed authored identity conflicts before another worker or mutable host read" do
    f = fixture(mode: :hold)
    input = options(%{"model" => "alias"})
    caller = request(f, "held", input)
    assert_receive {:preparing, worker, _, _, _, _, _}, 1_000
    original = :sys.get_state(f.control).creation
    store_before = Fixture.inspect_state(f.store_pid)
    assert {:error, :creation_in_progress} = create(f.runtime, "held", input)

    assert {:error, :runtime_command_conflict} =
             create(f.runtime, "held", options(%{"model" => "changed"}))

    assert {:error, :creation_in_progress} =
             Runtime.create_session_with_genesis(f.runtime, "complete", %{}, Captured.genesis([]))

    assert {:ok, %{runtime_id: "runtime"}} = Runtime.configuration(f.runtime)
    assert :sys.get_state(f.control).creation == original
    assert Fixture.inspect_state(f.store_pid) == store_before
    assert calls(f) == 1
    send(worker, :release)
    assert_receive {:authored_answer, ^caller, {:ok, _}}, 1_000
  end

  test "closed malformed input refuses before Store and optional callback" do
    f = fixture()
    before = Fixture.inspect_state(f.store_pid)

    for input <- [
          %{"version" => nil},
          %{"version" => 2},
          %{"version" => 1, "configuration" => %{}},
          %{"version" => 1, "tools" => ["read", "read"]},
          %{"version" => 1, "credentials" => "secret"}
        ] do
      assert {:error, :invalid_session_creation} = create(f.runtime, "bad", input)
    end

    assert Fixture.inspect_state(f.store_pid) == before
    assert calls(f) == 0
  end

  test "missing optional capability refuses explicit changes but leaves default creation usable" do
    f = fixture(module: WithoutPreparation)

    assert {:error, :invalid_session_creation} =
             create(f.runtime, "changed", options(%{"max_tokens" => 1_111}))

    assert {:ok, _} = create(f.runtime, "default", %{"version" => 1})
    assert calls(f) == 0
    refute_received :unexpected_model_dispatch
  end

  test "refused raised and malformed candidates do not reserve or persist private failure data" do
    f = fixture()

    for mode <- [:refuse, :raise, :malformed] do
      Agent.update(f.controller, &%{&1 | mode: mode})
      before_calls = Fixture.inspect_state(f.store_pid).creation_calls

      assert {:error, :invalid_session_creation} =
               create(f.runtime, Atom.to_string(mode), options(%{"max_tokens" => 1_111}))

      assert Fixture.inspect_state(f.store_pid).creation_calls == before_calls
      assert Fixture.inspect_state(f.store_pid).sessions == %{}
      ready(f.control)
    end

    assert calls(f) == 3
  end

  test "managed descendants and nested starters are joined before prepared reservation" do
    f = fixture()

    for mode <- [:descendant, :nested] do
      Agent.update(f.controller, &%{&1 | mode: mode})

      :ok =
        Fixture.hold_next_transition_before_linearization(
          f.store_pid,
          :runtime_control_reserve_creation,
          self()
        )

      caller = request(f, Atom.to_string(mode), options(%{"max_tokens" => 1_111}))
      assert_receive {:managed_child, child}, 1_000
      child_monitor = Process.monitor(child)

      grandchild =
        if mode == :nested do
          assert_receive {:grandchild, pid}, 1_000
          {pid, Process.monitor(pid)}
        end

      assert_receive {:record_held_before_linearization, waiter, _,
                      :runtime_control_reserve_creation, _},
                     1_000

      on_exit(fn -> Fixture.release(waiter) end)
      assert_receive {:DOWN, ^child_monitor, :process, ^child, _}, 1_000

      if grandchild do
        {pid, monitor} = grandchild
        assert_receive {:DOWN, ^monitor, :process, ^pid, _}, 1_000
      end

      refute :sys.get_state(f.control).creation.stopped
      Fixture.release(waiter)
      assert_receive {:authored_answer, ^caller, {:ok, _}}, 1_000
      ready(f.control)
    end
  end

  test "an arbitrary registered resource must acknowledge and join before reservation" do
    f = fixture(mode: :resource_hold)
    caller = request(f, "resource", options(%{"max_tokens" => 1_111}))
    assert_receive {:registered_resource, resource, guardian}, 1_000
    monitor = Process.monitor(resource)
    assert_receive {:resource_stopping, ^resource, _stop, stopper, cooperative, observe}, 1_000
    assert stopper != guardian
    capture = %{cooperative: cooperative, observe: observe}
    capture_cutoff = now() + 1_000
    await(fn -> :sys.get_state(f.control).creation.cleanup == capture end, capture_cutoff)
    state = :sys.get_state(f.control)
    assert state.creation.cleanup == %{cooperative: cooperative, observe: observe}
    refute state.creation.stopped
    assert state.creation.phase == :prepared_configuration
    assert Fixture.inspect_state(f.store_pid).sessions == %{}
    assert {:error, :creation_in_progress} = create(f.runtime, "other", %{"version" => 1})
    send(resource, :release)
    assert_receive {:DOWN, ^monitor, :process, ^resource, :normal}, 1_000
    assert_receive {:authored_answer, ^caller, {:ok, _}}, 1_000
  end

  test "naked resource death fences preparation instead of treating group DOWN as cleanup" do
    f = fixture(mode: :resource_noack)
    caller = request(f, "no-ack", options(%{"max_tokens" => 1_111}))
    assert_receive {:registered_resource, resource, _}, 1_000
    monitor = Process.monitor(resource)
    assert_receive {:DOWN, ^monitor, :process, ^resource, _}, 1_000
    assert_receive {:authored_answer, ^caller, {:error, :store_unavailable}}, 1_000
    state = :sys.get_state(f.control)
    assert state.creation.cleanup_unproved
    assert state.creation_status == :unavailable
    assert state.sessions == %{}
    assert Fixture.inspect_state(f.store_pid).sessions == %{}
  end

  test "actual guardian death retires its root-owned group and managed child without publication" do
    f = fixture(mode: :hold_descendant)
    caller = request(f, "guardian-loss", options(%{"max_tokens" => 1_111}))
    assert_receive {:managed_child, child}, 1_000
    action = :sys.get_state(f.control).creation.action
    monitors = actor_monitors([action.pid, action.group, action.worker, child])
    Process.exit(action.pid, :kill)
    join(monitors, now() + 1_000)
    await(fn -> :sys.get_state(f.control).creation_status == :unavailable end)
    assert Fixture.inspect_state(f.store_pid).sessions == %{}
    refute_received {:authored_answer, ^caller, {:ok, _}}
  end

  test "actual group death forces guardian fallback joins for the arbitrary resource" do
    f = fixture(mode: :resource_hold)
    caller = request(f, "group-loss", options(%{"max_tokens" => 1_111}))
    assert_receive {:registered_resource, resource, _}, 1_000
    assert_receive {:resource_stopping, ^resource, _, _, _, _}, 1_000
    action = :sys.get_state(f.control).creation.action
    monitors = actor_monitors([action.pid, action.group, action.worker, resource])
    Process.exit(action.group, :kill)
    join(monitors, now() + 1_000)
    assert_receive {:authored_answer, ^caller, {:error, :store_unavailable}}, 1_000
    assert :sys.get_state(f.control).creation.cleanup_unproved
    assert Fixture.inspect_state(f.store_pid).sessions == %{}
  end

  test "caller loss stops preparation before reservation and joins its actual child" do
    f = fixture(mode: :hold_descendant)
    caller = request(f, "caller-loss", options(%{"max_tokens" => 1_111}))
    assert_receive {:managed_child, child}, 1_000
    action = :sys.get_state(f.control).creation.action
    monitors = actor_monitors([action.pid, action.group, action.worker, child])
    Process.exit(caller, :kill)
    join(monitors, now() + 1_000)
    await(fn -> is_nil(:sys.get_state(f.control).creation) end)
    assert Fixture.inspect_state(f.store_pid).sessions == %{}
    refute_received :unexpected_model_dispatch
  end

  test "a known-final unknown presentation reuses the prepared exact F without resolving twice" do
    f = fixture()

    :ok =
      Fixture.inject(
        f.store_pid,
        {:runtime_control_create_session, :after_linearization_before_result}
      )

    assert {:ok, session} = create(f.runtime, "unknown", options(%{"model" => "alias"}))
    ready(f.control)

    finals =
      Enum.filter(
        Fixture.inspect_state(f.store_pid).creation_calls,
        &(&1.type == :create_session)
      )

    assert [first, second] = finals
    assert first == second
    assert {:ok, _} = Store.immutable_binding(first)
    assert first.genesis["initial_configuration"]["configuration_version"] == 1
    assert Map.fetch!(Fixture.inspect_state(f.store_pid).sessions, session).records != []
    assert calls(f) == 1
  end

  test "stale preparation notices cannot change the retained episode or admit a candidate" do
    f = fixture(mode: :hold)
    caller = request(f, "stale", options(%{"model" => "alias"}))
    assert_receive {:preparing, worker, _, _, _, _, _}, 1_000
    state = :sys.get_state(f.control)
    entry = state.creation

    send(
      f.control,
      {:creation_preparation_cleanup, state.creation_incarnation, entry.invocation, make_ref(),
       entry.action.pid, %{cooperative: 0, observe: 0}}
    )

    send(
      entry.action.pid,
      {:creation_preparation_reply, self(), entry.action.permit, make_ref(), {:ok, %{}}}
    )

    assert :sys.get_state(f.control).creation == entry
    send(worker, :release)
    assert_receive {:authored_answer, ^caller, {:ok, _}}, 1_000
    assert calls(f) == 1
  end

  @tag long_bound: true
  @tag timeout: 25_000
  test "held reserve and final consume the cleanup capture without renewing either cutoff" do
    for phase <- [:runtime_control_reserve_creation, :runtime_control_create_session] do
      f = fixture(mode: :resource_ack)
      :ok = Fixture.hold_next_transition_before_linearization(f.store_pid, phase, self())
      caller = request(f, Atom.to_string(phase), options(%{"max_tokens" => 1_111}))
      assert_receive {:resource_stopping, _, _, _, cooperative, observe}, 1_000
      assert_receive {:record_held_before_linearization, waiter, _, ^phase, _}, 1_000
      on_exit(fn -> Fixture.release(waiter) end)
      before = :sys.get_state(f.control).creation
      assert before.cleanup == %{cooperative: cooperative, observe: observe}
      refute before.stopped
      monitors = actor_monitors([before.action.pid, before.action.group, before.action.worker])
      assert before.cutoff > observe
      assert {:error, :creation_in_progress} = create(f.runtime, "overlap", %{"version" => 1})

      receive do
      after
        max(observe + 1 - now(), 0) -> :ok
      end

      join(monitors, observe + 1_000)
      await(fn -> :sys.get_state(f.control).creation.cleanup_unproved end)
      retained = :sys.get_state(f.control).creation
      assert retained.cutoff == before.cutoff
      assert retained.cleanup == before.cleanup
      assert retained.invocation == before.invocation
      assert retained.action.permit == before.action.permit
      assert :sys.get_state(f.control).sessions == %{}
      refute_received {:authored_answer, ^caller, {:ok, _}}
      Fixture.release(waiter)
    end
  end

  @tag long_bound: true
  @tag timeout: 75_000
  test "actual sixty second authored cutoff stops the original callback without a fresh allowance" do
    f = fixture(mode: :hold)
    caller = request(f, "deadline", options(%{"max_tokens" => 1_111}))
    assert_receive {:preparing, worker, _, _, _, context, _}, 1_000
    Conformance.assert_context(context, 5_000)
    original = :sys.get_state(f.control).creation
    monitors = actor_monitors([original.action.pid, original.action.group, worker])
    assert_receive {:authored_answer, ^caller, {:error, _}}, 70_000
    assert now() >= context.deadline_monotonic_ms
    assert original.cutoff == context.deadline_monotonic_ms
    join(monitors, now() + 1_000)
    assert Fixture.inspect_state(f.store_pid).sessions == %{}
    assert calls(f) == 1
  end

  test "first offer after actual caller-loss cleanup retains the original captured window" do
    late_first_offer(:caller)
  end

  test "first offer after actual guardian-loss cleanup survives callback DOWN" do
    late_first_offer(:guardian)
  end

  test "group loss before registration acknowledgement transfers the first-offer inventory" do
    f = fixture(mode: :held_first_offer)
    caller = request(f, "offered-group-loss", options(%{"max_tokens" => 1_111}))
    assert_receive {:offer_callback_ready, worker}, 1_000
    action = :sys.get_state(f.control).creation.action
    monitors = actor_monitors([action.pid, action.group, worker, caller])
    assert :erlang.suspend_process(action.pid)

    try do
      send(worker, :offer_resource)
      assert_receive {:first_offer_created, ^worker, resource, reference}, 1_000
      retain_fixture_actor(resource)
      resource_monitor = Process.monitor(resource)
      inventory = :sys.get_state(action.group).inventory
      cutoff = now() + 1_000

      await(
        fn -> :ets.lookup(inventory, :resource) == [{:resource, resource, reference}] end,
        cutoff
      )

      Process.exit(action.group, :kill)
      await(fn -> :ets.info(inventory, :owner) == action.pid end, cutoff)
      assert :erlang.resume_process(action.pid)
      assert_receive {:DOWN, ^resource_monitor, :process, ^resource, :killed}, 1_000
      join(monitors, now() + 1_000)
      assert_receive {:authored_answer, ^caller, {:error, :store_unavailable}}, 1_000
      assert :sys.get_state(f.control).creation.cleanup_unproved
      no_prepared_dispatch(f)
    after
      if Process.alive?(action.pid) do
        try do
          :erlang.resume_process(action.pid)
        catch
          :error, :badarg -> :ok
        end
      end
    end
  end

  test "a duplicate distinct offer is refused and the adapter joins its host-owned process" do
    f = fixture(mode: :duplicate_resource)
    caller = request(f, "duplicate", options(%{"max_tokens" => 1_111}))
    assert_receive {:registered_resource, resource, _guardian}, 1_000
    retain_fixture_actor(resource)
    resource_monitor = Process.monitor(resource)
    assert_receive {:duplicate_refused, worker, duplicate, {:error, :unavailable}}, 1_000
    retain_fixture_actor(duplicate)
    duplicate_monitor = Process.monitor(duplicate)
    action = :sys.get_state(f.control).creation.action
    inventory = :sys.get_state(action.group).inventory
    assert [{:resource, ^resource, _}] = :ets.lookup(inventory, :resource)
    no_prepared_dispatch(f)
    send(worker, :reap_duplicate)
    assert_receive {:duplicate_reaped, ^duplicate}, 1_000
    assert_receive {:DOWN, ^duplicate_monitor, :process, ^duplicate, :normal}, 1_000
    assert_receive {:resource_stopping, ^resource, _stop, _stopper, _cooperative, _observe}, 1_000
    assert [{:resource, ^resource, _}] = :ets.lookup(inventory, :resource)
    send(resource, :release)
    assert_receive {:DOWN, ^resource_monitor, :process, ^resource, :normal}, 1_000
    assert_receive {:authored_answer, ^caller, {:ok, _session}}, 1_000
    ready(f.control)
    refute Process.alive?(worker)
    refute_received :unexpected_model_dispatch
  end

  defp late_first_offer(fault) do
    f = fixture(mode: :late_first_offer)
    caller = request(f, "late-#{fault}", options(%{"max_tokens" => 1_111}))
    assert_receive {:late_callback_ready, worker}, 1_000
    action = :sys.get_state(f.control).creation.action
    monitors = actor_monitors([action.pid, action.group, worker, caller])
    if fault == :caller, do: Process.exit(caller, :kill), else: Process.exit(action.pid, :kill)
    assert_receive {:late_cleanup_started, ^worker}, 1_000
    cutoff = now() + 1_000
    await(fn -> not is_nil(:sys.get_state(f.control).creation.cleanup) end, cutoff)
    captured = :sys.get_state(f.control).creation.cleanup
    await(fn -> :sys.get_state(action.group).cleanup == captured end, cutoff)
    send(worker, :offer_resource)
    assert_receive {:late_offer_result, ^worker, resource, {:error, :unavailable}}, 1_000
    retain_fixture_actor(resource)
    monitor = Process.monitor(resource)
    assert_receive {:resource_stopping, ^resource, _stop, stopper, cooperative, observe}, 1_000
    assert stopper == action.group
    assert captured == %{cooperative: cooperative, observe: observe}
    assert :sys.get_state(f.control).creation.cleanup == captured
    no_prepared_dispatch(f)
    send(resource, :release)
    assert_receive {:DOWN, ^monitor, :process, ^resource, :normal}, 1_000
    join(monitors, now() + 1_000)

    if fault == :caller do
      await(fn -> is_nil(:sys.get_state(f.control).creation) end)
    else
      assert calls(f) == 1
      assert_receive {:authored_answer, ^caller, {:error, :invalid_session_creation}}, 1_000
      await(fn -> :sys.get_state(f.control).creation_status == :unavailable end)
    end

    no_prepared_dispatch(f)
  end

  test "a refused duplicate already admitted by Starter keeps its managed-child custody" do
    f = fixture(mode: :managed_duplicate)
    caller = request(f, "managed-duplicate", options(%{"max_tokens" => 1_111}))
    assert_receive {:registered_resource, resource, _guardian}, 1_000
    retain_fixture_actor(resource)
    resource_monitor = Process.monitor(resource)
    assert_receive {:managed_duplicate_refused, duplicate, {:error, :unavailable}}, 1_000
    retain_fixture_actor(duplicate)
    duplicate_monitor = Process.monitor(duplicate)
    action = :sys.get_state(f.control).creation.action
    retained = :sys.get_state(action.group)
    assert Map.has_key?(retained.children, duplicate)
    assert [{:resource, ^resource, _}] = :ets.lookup(retained.inventory, :resource)
    assert_receive {:duplicate_child_stopping, ^duplicate}, 1_000
    assert_receive {:resource_stopping, ^resource, _stop, _stopper, _cooperative, _observe}, 1_000
    no_prepared_dispatch(f)
    send(duplicate, :release)
    assert_receive {:DOWN, ^duplicate_monitor, :process, ^duplicate, :normal}, 1_000
    no_prepared_dispatch(f)
    send(resource, :release)
    assert_receive {:DOWN, ^resource_monitor, :process, ^resource, :normal}, 1_000
    assert_receive {:authored_answer, ^caller, {:ok, _session}}, 1_000
    ready(f.control)
    refute_received :unexpected_model_dispatch
  end

  defp no_prepared_dispatch(f) do
    state = Fixture.inspect_state(f.store_pid)
    assert state.sessions == %{}
    refute Enum.any?(state.creation_calls, &(&1.type in [:reserve_creation, :create_session]))
    refute_received :unexpected_model_dispatch
  end

  defp retain_fixture_actor(pid) do
    on_exit(fn ->
      monitor = Process.monitor(pid)
      if Process.alive?(pid), do: Process.exit(pid, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^pid, _reason}, 1_000
    end)
  end

  defp fixture(settings \\ []) do
    {store_pid, store} = Fixture.start_store()
    on_exit(fn -> if Process.alive?(store_pid), do: GenServer.stop(store_pid) end)

    {:ok, controller} =
      Agent.start_link(fn ->
        %{
          observer: self(),
          calls: 0,
          mode: Keyword.get(settings, :mode, :normal),
          canonical: "resolved:v2"
        }
      end)

    # Agent's initializer executes in the Agent; the observation owner is this test.
    observer = self()
    Agent.update(controller, &%{&1 | observer: observer})

    model = %{
      module: Keyword.get(settings, :module, Preparing),
      model: "scripted:v1",
      options: [controller: controller, observer: observer]
    }

    definitions = Keyword.get(settings, :definitions, [])

    # Concept: preparation runs in a fully declared native runtime.
    # Technical depth: reuse the existing process-backed executor and host policy
    # for startup admission; authored creation still dispatches no model or tool.
    executor = Loopex.AgentLoopTestExecutor.start()

    on_exit(fn ->
      if Process.alive?(executor), do: GenServer.stop(executor, :normal, 1_000)
    end)

    {:ok, runtime} =
      Loopex.start_link(
        runtime_id: "runtime",
        context_token_budget: 8_192,
        store: store,
        model: model,
        executor: %{
          module: Loopex.AgentLoopTestExecutor,
          reference: executor,
          identity: "agent-loop-executor",
          epoch: 1,
          fencing_token: 1,
          workspace_ref: "workspace-ref",
          workspace_lease: "workspace-lease"
        },
        cleanup_grace_ms: 5_000,
        tools: definitions,
        policy: Loopex.AgentLoopTestPolicy,
        policy_identity: %{"id" => "loopex.test.authored_creation_policy", "revision" => "1"},
        session_creation_defaults: Map.drop(Captured.genesis(definitions), [:kind, "options"])
      )

    on_exit(fn -> if Runtime.alive?(runtime), do: Runtime.stop(runtime) end)
    {:ok, %{control: control}} = Runtime.children(runtime)
    ready(control)

    %{
      store_pid: store_pid,
      store: store,
      controller: controller,
      model: model,
      runtime: runtime,
      control: control
    }
  end

  defp options(changes), do: %{"version" => 1, "configuration" => changes}

  defp create(runtime, command, input),
    do: Loopex.create_session(runtime, input, command_id: command)

  defp calls(f), do: Agent.get(f.controller, & &1.calls)

  defp records(f, session),
    do: Map.fetch!(Fixture.inspect_state(f.store_pid).sessions, session).records

  defp request(f, command, input) do
    observer = self()

    caller =
      spawn(fn ->
        send(observer, {:authored_answer, self(), create(f.runtime, command, input)})
      end)

    on_exit(fn -> if Process.alive?(caller), do: Process.exit(caller, :kill) end)
    caller
  end

  defp actor_monitors(pids), do: Enum.map(pids, &{&1, Process.monitor(&1)})

  defp join(monitors, cutoff) do
    for {pid, monitor} <- monitors do
      assert_receive {:DOWN, ^monitor, :process, ^pid, _}, max(cutoff - now(), 0)
    end
  end

  defp ready(control),
    do:
      await(fn ->
        state = :sys.get_state(control)
        state.creation_status == :ready and is_nil(state.creation)
      end)

  defp await(predicate), do: await(predicate, now() + 1_000)

  defp await(predicate, cutoff) do
    if predicate.() do
      :ok
    else
      assert now() < cutoff

      receive do
      after
        1 -> :ok
      end

      await(predicate, cutoff)
    end
  end

  defp now, do: System.monotonic_time(:millisecond)
end
