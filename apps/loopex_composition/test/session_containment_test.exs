defmodule LoopexComposition.SessionContainmentTest do
  use ExUnit.Case, async: false

  alias Loopex.Executor
  alias Loopex.Executor.Local
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

  defp held_server do
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

  defp future,
    do: System.monotonic_time() + System.convert_time_unit(1_000, :millisecond, :native)
end
