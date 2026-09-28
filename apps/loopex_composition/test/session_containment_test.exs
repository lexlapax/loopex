defmodule LoopexComposition.SessionContainmentTest do
  use ExUnit.Case, async: false

  Code.require_file(
    Path.expand(
      "../../loopex_llm_reqllm/test/support/provider_register_rendezvous.exs",
      __DIR__
    )
  )

  alias Loopex.Executor
  alias Loopex.Executor.Local
  alias Loopex.LLM.ReqLLM.InProcess.TestRegisterRendezvous
  alias Loopex.Runtime.Supervisor, as: RuntimeSupervisor
  alias LoopexComposition.Ephemeral
  alias LoopexComposition.SessionAdmission

  defmodule Policy do
    @behaviour Loopex.Policy

    @impl true
    def decide(_request), do: {:allow, nil}
  end

  setup do
    workspace =
      Path.join(System.tmp_dir!(), "loopex-containment-#{System.unique_integer([:positive])}")

    File.mkdir!(workspace)
    on_exit(fn -> File.rm_rf!(workspace) end)
    %{workspace: workspace}
  end

  test "stop waits for every actually recorded model process and registry entry", %{
    workspace: workspace
  } do
    {port, server} = held_server()

    assert {:ok, {:loopex_ephemeral_session, owner, cell} = session} =
             Ephemeral.start_session(
               policy: Policy,
               model: "ollama:llama3.2",
               base_url: "http://127.0.0.1:#{port}/v1",
               cwd: workspace,
               tools: :none,
               max_tokens: 128,
               timeout: 15_000
             )

    root = :sys.get_state(owner).startup.owned_root.path
    question = Task.async(fn -> Ephemeral.ask(session, "held call") end)
    assert_receive {:model_request, ^server, request}, 15_000
    assert request =~ "POST /v1/chat/completions HTTP/1.1"

    pending =
      await(owner, fn state ->
        case state.model_census.pending do
          %{resources: resources, registries: registries} = pending
          when map_size(resources) == 5 and map_size(registries) == 2 ->
            {:ok, pending}

          _ ->
            :wait
        end
      end)

    assert Map.keys(pending.resources) |> Enum.sort() ==
             [:anonymous_supervisor, :caller, :http1_worker, :pool_supervisor, :root]

    assert Map.keys(pending.registries) |> Enum.sort() == [:supervisor, :worker]
    assert Enum.all?(pending.resources, fn {_role, pid} -> Process.alive?(pid) end)

    monitors =
      Enum.map(pending.resources, fn {role, pid} -> {role, pid, Process.monitor(pid)} end)

    worker_identity = pending.registries.worker
    supervisor_identity = pending.registries.supervisor
    assert Registry.lookup(Req.Finch, worker_identity) != []
    assert Registry.lookup(Req.Finch.SupervisorRegistry, supervisor_identity) != []

    assert :ok = Ephemeral.stop_session(session)
    assert Enum.all?(monitors, fn {_role, pid, _monitor} -> not Process.alive?(pid) end)
    assert Registry.lookup(Req.Finch, worker_identity) == []
    assert Registry.lookup(Req.Finch.SupervisorRegistry, supervisor_identity) == []
    assert :atomics.get(cell, 2) == 0
    send(server, :release)
    assert {:ok, {:error, {:run, :cancelled, _}}} = Task.yield(question, 5_000)

    for {role, pid, monitor} <- monitors do
      assert_receive {:DOWN, ^monitor, :process, ^pid, _reason},
                     1_000,
                     "recorded #{role} remained alive after proved stop"

      refute Process.alive?(pid)
    end

    assert :atomics.get(cell, 1) == 2
    refute File.exists?(root)
  end

  test "a normal model result waits for every recorded process and registry entry", %{
    workspace: workspace
  } do
    {port, server} = held_server("retired answer")

    assert {:ok, {:loopex_ephemeral_session, owner, cell} = session} =
             Ephemeral.start_session(
               policy: Policy,
               model: "ollama:llama3.2",
               base_url: "http://127.0.0.1:#{port}/v1",
               cwd: workspace,
               tools: :none,
               max_tokens: 128,
               timeout: 15_000
             )

    question = Task.async(fn -> Ephemeral.ask(session, "complete call") end)
    assert_receive {:model_request, ^server, _request}, 15_000

    pending =
      await(owner, fn state ->
        case state.model_census.pending do
          %{resources: resources, registries: registries} = pending
          when map_size(resources) == 5 and map_size(registries) == 2 ->
            {:ok, pending}

          _ ->
            :wait
        end
      end)

    monitors =
      Enum.map(pending.resources, fn {role, pid} -> {role, pid, Process.monitor(pid)} end)

    worker_identity = pending.registries.worker
    supervisor_identity = pending.registries.supervisor
    assert Registry.lookup(Req.Finch, worker_identity) != []
    assert Registry.lookup(Req.Finch.SupervisorRegistry, supervisor_identity) != []

    send(server, :release)

    assert {:ok, {:ok, %{outcome: :completed, text: "retired answer"}}} =
             Task.yield(question, 15_000)

    for {role, pid, monitor} <- monitors do
      assert_receive {:DOWN, ^monitor, :process, ^pid, _reason},
                     1_000,
                     "recorded #{role} remained alive after a returned result"

      refute Process.alive?(pid)
    end

    assert Registry.lookup(Req.Finch, worker_identity) == []
    assert Registry.lookup(Req.Finch.SupervisorRegistry, supervisor_identity) == []
    assert :atomics.get(cell, 2) == 0
    assert :atomics.get(cell, 1) == 0
    assert :ok = Ephemeral.stop_session(session)
  end

  test "a real local tool effect waits for this owner to retire its model slot", %{
    workspace: workspace
  } do
    assert {:ok, {:loopex_ephemeral_session, owner, cell} = session} =
             Ephemeral.start_session(
               policy: Policy,
               model: "ollama:llama3.2",
               cwd: workspace,
               tools: :coding,
               timeout: 15_000
             )

    state = :sys.get_state(owner)
    executor = state.startup.registered.executor
    handle = SessionAdmission.handle(owner, state.startup.generation, cell)
    call = make_ref()

    assert {:ok, {:session_grant, _, :begin_model, _, _, _}} =
             SessionAdmission.request(handle, {:begin_model, self(), call}, future())

    assert :atomics.get(cell, 2) == 1
    {job, grant} = write_job(state, "retired", workspace)
    effect = Task.async(fn -> Local.execute(executor, job, grant) end)

    assert %{envelope: {_requester, _reference, {:tool_grant, ^executor, _, _}, _expiry}} =
             await(owner, fn state ->
               case state.model_census.tool_wait do
                 nil -> :wait
                 wait -> {:ok, wait}
               end
             end)

    assert nil == Task.yield(effect, 25)
    refute File.exists?(Path.join(workspace, "retired.txt"))

    proxy = spawn(fn -> :ok end)
    proxy_monitor = Process.monitor(proxy)
    assert_receive {:DOWN, ^proxy_monitor, :process, ^proxy, :normal}, 1_000
    start_ref = make_ref()

    no_child =
      {:model_start_proof, start_ref, proxy, proxy_monitor, :normal, :not_started,
       {:error, :unavailable}}

    assert {:ok, {:session_grant, _, :cancel_model, _, _, _}} =
             SessionAdmission.request(handle, {:cancel_model, call, no_child}, future())

    assert {:ok, {:ok, %{outcome: :completed, cleanup_confirmation: :confirmed}}} =
             Task.yield(effect, 5_000)

    assert File.read!(Path.join(workspace, "retired.txt")) == "bytes"
    assert :atomics.get(cell, 2) == 0

    # The retained receipt answers a duplicate without replaying the write,
    # even when the host has since changed the workspace file.
    File.write!(Path.join(workspace, "retired.txt"), "host revision")

    assert {:ok, %{outcome: :completed, cleanup_confirmation: :confirmed}} =
             Local.execute(executor, job, grant)

    assert File.read!(Path.join(workspace, "retired.txt")) == "host revision"

    {expired_job, _unused_grant} = write_job(state, "expired", workspace)

    assert {:ok, expired_grant} =
             Executor.issue_grant(
               {:host_policy, :allow},
               expired_job,
               System.system_time(:millisecond) - 1
             )

    assert {:error, {:refused_before_effect, {:binding_mismatch, :expiry}}} =
             Local.execute(executor, expired_job, expired_grant)

    refute File.exists?(Path.join(workspace, "expired.txt"))
    assert :ok = Ephemeral.stop_session(session)
  end

  test "real worker retention keeps an unregistered candidate until exact release and DOWN", %{
    workspace: workspace
  } do
    {port, server} = held_server("second answer")

    assert {:ok, {:loopex_ephemeral_session, owner, cell} = session} =
             Ephemeral.start_session(
               policy: Policy,
               model: "ollama:llama3.2",
               base_url: "http://127.0.0.1:#{port}/v1",
               cwd: workspace,
               tools: :coding,
               max_tokens: 128,
               timeout: 15_000
             )

    :ok = TestRegisterRendezvous.open!()
    release_table = :ets.new(:loopex_test_empty_release, [:named_table, :public, :set])
    nonce = make_ref()
    :ok = TestRegisterRendezvous.arm!(cell, self(), nonce)
    first = Task.async(fn -> Ephemeral.ask(session, "first call") end)

    assert_receive {:before_provider_register, ^nonce, callback, call, candidate}, 5_000
    owner_state = :sys.get_state(owner)
    runtime = owner_state.startup.registered.runtime
    session_id = owner_state.startup.session_id
    {:ok, %{control: control}} = RuntimeSupervisor.children(runtime.supervisor)
    coordinator = :sys.get_state(control).sessions[session_id].coordinator

    [{_task_ref, {:model, run_id, worker, %{guard: guard, reference: reference}}}] =
      await(coordinator, fn state ->
        models =
          Enum.filter(state.in_flight, fn
            {_task_ref, {:model, _run_id, _worker, _tree}} -> true
            _other -> false
          end)

        if models == [], do: :wait, else: {:ok, models}
      end)

    assert Process.alive?(callback)
    assert Process.alive?(candidate)
    assert Process.alive?(worker)
    assert Process.alive?(guard)
    assert is_binary(run_id)
    assert is_reference(reference)
    assert true = :erlang.suspend_process(worker)

    try do
      send(callback, {:continue_provider_register, nonce})

      {:loopex_provider_resource_offered, ^reference, ^callback, ^candidate, stop_ref, offer_ref} =
        await_process_message(worker, fn
          {:loopex_provider_resource_offered, ^reference, ^callback, ^candidate, stop, offer}
          when is_reference(stop) and is_reference(offer) ->
            true

          _other ->
            false
        end)

      assert true = :erlang.suspend_process(callback)

      try do
        assert true = :erlang.resume_process(worker)

        assert {:loopex_provider_resource_retained_by_worker, ^reference, ^offer_ref, ^worker} =
                 await_process_message(callback, fn
                   {:loopex_provider_resource_retained_by_worker, ^reference, ^offer_ref, ^worker} ->
                     true

                   _other ->
                     false
                 end)

        assert {:monitors, worker_monitors} = Process.info(worker, :monitors)
        assert {:process, candidate} in worker_monitors
        assert {:messages, guard_messages} = Process.info(guard, :messages)

        refute Enum.any?(guard_messages, fn
                 {:loopex_provider_resource_register, ^reference, ^callback, ^candidate,
                  ^stop_ref, _registration} ->
                   true

                 _other ->
                   false
               end)

        assert {:dictionary, guard_dictionary} = Process.info(guard, :dictionary)

        refute Enum.any?(guard_dictionary, fn {key, _value} ->
                 key == {{Loopex.Runtime.SessionCoordinator, :provider_resource}, reference}
               end)

        held_state = :sys.get_state(owner)
        executor = held_state.startup.registered.executor
        {job, grant} = write_job(held_state, "held-effect", workspace)
        effect = Task.async(fn -> Local.execute(executor, job, grant) end)

        assert %{envelope: {_requester, _reference, {:tool_grant, ^executor, _, _}, _expiry}} =
                 await(owner, fn state ->
                   case state.model_census.tool_wait do
                     nil -> :wait
                     waiting -> {:ok, waiting}
                   end
                 end)

        assert nil == Task.yield(effect, 0)
        refute File.exists?(Path.join(workspace, "held-effect.txt"))

        release_nonce = make_ref()
        true = :ets.insert_new(release_table, {cell, self(), release_nonce})
        {:ok, attachment} = Loopex.attach(runtime, session_id)

        assert {:accepted, _} =
                 Loopex.command(attachment, %{
                   type: :abort,
                   command_id: "retained-unregistered-abort"
                 })

        assert_receive {:empty_release_deferred, ^release_nonce, ^owner, ^candidate,
                        {:release_empty_invocation, generation, ^call, ^candidate, proof,
                         release_ref, deadline} = release},
                       5_000

        assert is_reference(generation)
        assert is_reference(proof)
        assert is_reference(release_ref)
        assert deadline > System.monotonic_time()
        Process.put({__MODULE__, :held_release}, {candidate, release})
        assert Process.alive?(candidate)
        assert :atomics.get(cell, 2) == 1

        assert %{phase: :retired_wait_down, call: ^call, candidate: ^candidate} =
                 :sys.get_state(owner).model_census.pending

        assert %{stage: :release, run_id: ^run_id, call: ^call, candidate: ^candidate} =
                 :sys.get_state(owner).session.settlement

        assert {:error, :run_open} = Ephemeral.ask(session, "blocked while release held")
        refute_receive {:model_request, ^server, _request}, 0
        pre_release_effect = Task.yield(effect, 0)

        assert pre_release_effect in [
                 nil,
                 {:ok, {:error, {:refused_before_effect, :session_admission_closed}}}
               ]

        refute File.exists?(Path.join(workspace, "held-effect.txt"))

        candidate_monitor = Process.monitor(candidate)
        assert deadline > System.monotonic_time()
        send(candidate, release)
        Process.delete({__MODULE__, :held_release})
        assert_receive {:DOWN, ^candidate_monitor, :process, ^candidate, _reason}, 1_000

        assert :ok =
                 await(owner, fn state ->
                   if state.model_census.pending == nil and :atomics.get(cell, 2) == 0,
                     do: {:ok, :ok},
                     else: :wait
                 end)

        assert {:ok, {:error, {:run, outcome, _detail}}} = Task.yield(first, 5_000)
        assert outcome in [:cancelled, :bound_reached]

        store = :sys.get_state(owner).startup.registered.store_handle
        assert {:ok, records} = Loopex.Store.load_records(store, session_id, 0, 512)

        assert [%{payload: %{"transport" => "dispatched_or_unknown"}}] =
                 Enum.filter(records, fn record ->
                   (record.payload[:kind] || record.payload["kind"]) ==
                     "model_attempt_settled_v2" and record.payload["run_id"] == run_id
                 end)

        effect_result = pre_release_effect || Task.yield(effect, 5_000)

        assert effect_result in [
                 {:ok, {:error, {:refused_before_effect, :session_admission_closed}}},
                 {:ok, {:ok, %{outcome: :completed, cleanup_confirmation: :confirmed}}}
               ]

        if match?({:ok, {:ok, _}}, effect_result) do
          assert File.read!(Path.join(workspace, "held-effect.txt")) == "bytes"
        else
          refute File.exists?(Path.join(workspace, "held-effect.txt"))
        end

        second = Task.async(fn -> Ephemeral.ask(session, "second call") end)
        assert_receive {:model_request, ^server, _request}, 5_000
        send(server, :release)

        assert {:ok, {:ok, %{outcome: :completed, text: "second answer"}}} =
                 Task.yield(second, 5_000)

        assert :ok = Ephemeral.stop_session(session)
      after
        resume_fixture_process(callback)
      end
    after
      resume_fixture_process(worker)
      send(callback, {:continue_provider_register, nonce})
      release_held_by_fixture(owner, candidate)
      :ets.delete(release_table)
      TestRegisterRendezvous.close!()

      if Process.alive?(owner), do: Ephemeral.stop_session(session)
    end
  end

  defp write_job(state, label, workspace) do
    {:ok, tool} = Local.tool("loopex.write")
    now = System.system_time(:millisecond)
    manifest = state.startup.configuration.skills.manifest

    {:ok, job} =
      Executor.job(%{
        protocol_version: 1,
        job_id: "containment-job-#{label}",
        operation_id: "containment-operation-#{label}",
        attempt: 1,
        session_id: state.startup.session_id,
        run_id: "containment-run-#{label}",
        turn_id: "containment-turn-#{label}",
        tool_call_id: "containment-call-#{label}",
        origin_session_epoch: state.startup.owner_epoch,
        origin_executor_epoch: 1,
        executor_identity: "executor-local",
        required_capabilities: ["workspace_write"],
        tool_id: tool.id,
        tool_version: tool.version,
        effect_class: tool.effect_class,
        validated_arguments: %{"path" => "#{label}.txt", "content" => "bytes"},
        workspace_ref: manifest["workspace_ref"],
        workspace_lease: "workspace",
        run_deadline: now + 15_000,
        resource_budgets: %{"max_output_bytes" => 65_536},
        idempotency_class: "effectful",
        fencing_token: 1,
        artifact_policy: %{"retain" => true},
        output_policy: %{"capture" => true}
      })

    assert Path.join(workspace, "#{label}.txt") |> File.exists?() == false
    {:ok, grant} = Executor.issue_grant({:host_policy, :allow}, job, now + 15_000)
    {job, grant}
  end

  defp held_server(answer \\ nil) do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, {_, port}} = :inet.sockname(listener)
    test = self()

    server =
      spawn(fn ->
        with {:ok, socket} <- :gen_tcp.accept(listener, 15_000),
             {:ok, request} <- read_request(socket, <<>>) do
          send(test, {:model_request, self(), request})

          receive do
            :release -> :ok
          end

          if is_binary(answer) do
            body =
              JSON.encode!(%{
                id: "chatcmpl-loopex-containment",
                object: "chat.completion",
                created: 1_800_000_000,
                model: "llama3.2",
                choices: [
                  %{
                    index: 0,
                    message: %{role: "assistant", content: answer},
                    finish_reason: "stop"
                  }
                ],
                usage: %{prompt_tokens: 12, completion_tokens: 3, total_tokens: 15}
              })

            :ok =
              :gen_tcp.send(socket, [
                "HTTP/1.1 200 OK\r\n",
                "content-type: application/json\r\n",
                "content-length: ",
                Integer.to_string(byte_size(body)),
                "\r\nconnection: close\r\n\r\n",
                body
              ])
          end

          :gen_tcp.close(socket)
        end
      end)

    on_exit(fn ->
      :gen_tcp.close(listener)
      if Process.alive?(server), do: Process.exit(server, :kill)
    end)

    {port, server}
  end

  defp read_request(socket, buffered) do
    case :binary.match(buffered, "\r\n\r\n") do
      {header_end, 4} ->
        header_size = header_end + 4
        <<headers::binary-size(^header_size), body::binary>> = buffered

        size =
          case Regex.run(~r/content-length:\s*(\d+)/i, headers) do
            [_, digits] -> String.to_integer(digits)
            _ -> 0
          end

        if byte_size(body) >= size, do: {:ok, buffered}, else: read_more(socket, buffered)

      :nomatch ->
        read_more(socket, buffered)
    end
  end

  defp read_more(socket, buffered) when byte_size(buffered) <= 1_048_576 do
    with {:ok, chunk} <- :gen_tcp.recv(socket, 0, 15_000) do
      read_request(socket, buffered <> chunk)
    end
  end

  defp await(owner, read, attempts \\ 200)
  defp await(_owner, _read, 0), do: flunk("session owner did not reach the observed state")

  defp await(owner, read, attempts) do
    case read.(:sys.get_state(owner)) do
      {:ok, value} ->
        value

      :wait ->
        Process.sleep(5)
        await(owner, read, attempts - 1)
    end
  end

  defp await_process_message(pid, match?, attempts \\ 200)
  defp await_process_message(_pid, _match?, 0), do: flunk("expected process message was absent")

  defp await_process_message(pid, match?, attempts) do
    case Process.info(pid, :messages) do
      {:messages, messages} ->
        case Enum.find(messages, match?) do
          nil ->
            Process.sleep(5)
            await_process_message(pid, match?, attempts - 1)

          message ->
            message
        end

      nil ->
        flunk("process died before its expected message was observed")
    end
  end

  defp resume_fixture_process(pid) do
    try do
      case Process.info(pid, :status) do
        {:status, :suspended} -> :erlang.resume_process(pid)
        _other -> :ok
      end
    catch
      :error, :badarg -> :ok
    end
  end

  defp release_held_by_fixture(owner, candidate) do
    case Process.delete({__MODULE__, :held_release}) do
      {^candidate, release} -> send(candidate, release)
      _none -> :ok
    end

    receive do
      {:empty_release_deferred, _nonce, ^owner, ^candidate, release} ->
        send(candidate, release)
    after
      0 -> :ok
    end
  end

  defp future,
    do: System.monotonic_time() + System.convert_time_unit(1_000, :millisecond, :native)
end
