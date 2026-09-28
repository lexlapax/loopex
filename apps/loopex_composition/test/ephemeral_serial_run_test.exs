defmodule LoopexComposition.Ephemeral.SerialRunTest do
  use ExUnit.Case, async: false

  alias LoopexComposition.Ephemeral

  defmodule Policy do
    @behaviour Loopex.Policy
    @impl true
    def decide(_request), do: {:allow, nil}
  end

  test "real core settles an injected empty candidate before a second ask" do
    real_core_barrier_case(:waiting)
  end

  test "a timed-out real-core ask stays open through empty-candidate settlement" do
    real_core_barrier_case(:background)
  end

  defp real_core_barrier_case(mode) do
    workspace =
      Path.join(System.tmp_dir!(), "loopex-serial-#{System.unique_integer([:positive])}")

    File.mkdir!(workspace)
    on_exit(fn -> File.rm_rf!(workspace) end)
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

    startup = :sys.get_state(owner).startup
    facade = startup.registered.facade_client
    runtime = startup.registered.runtime
    session_id = startup.session_id
    {:ok, children} = Loopex.Runtime.Supervisor.children(runtime.supervisor)
    coordinator = :sys.get_state(children.control).sessions[session_id].coordinator
    root = startup.owned_root.path

    on_exit(fn ->
      resume(facade)
      resume(coordinator)
      if Process.alive?(owner), do: Ephemeral.stop_session(session)
    end)

    test = self()

    first =
      Task.async(fn ->
        result =
          Ephemeral.ask(
            session,
            "first prompt",
            timeout: if(mode == :background, do: 700, else: 15_000)
          )

        if mode == :background do
          send(test, {:first_ask_result, self(), result})

          receive do
            :audit_borrower_mailbox ->
              {:messages, messages} = Process.info(self(), :messages)
              {result, messages}
          end
        else
          result
        end
      end)

    assert_receive {:model_request, ^server, 1, first_request}, 15_000
    assert first_request =~ "POST /v1/chat/completions HTTP/1.1"
    assert first_request =~ "first prompt"
    first_wait_deadline = :sys.get_state(owner).session.active.wait_deadline

    first_pending =
      await(owner, fn state ->
        case state.model_census.pending do
          %{resources: resources, registries: registries} = pending
          when map_size(resources) == 5 and map_size(registries) == 2 ->
            {:ok, pending}

          _ ->
            :wait
        end
      end)

    assert :erlang.suspend_process(facade)
    send(server, {:reply, 1})

    await(owner, fn state ->
      if state.model_census.pending == nil and :atomics.get(cell, 2) == 0,
        do: {:ok, :settled},
        else: :wait
    end)

    await_core(runtime, session_id, fn status ->
      status.event_sequence >= 2 and status.active_run_id == nil and
        status.pending_work_ids == []
    end)

    for {_role, pid} <- first_pending.resources, do: refute(Process.alive?(pid))
    assert Registry.lookup(Req.Finch, first_pending.registries.worker) == []

    assert Registry.lookup(Req.Finch.SupervisorRegistry, first_pending.registries.supervisor) ==
             []

    # The actual HTTP call and its pool have already retired. Only the held
    # empty-candidate state is injected; the facade, terminal event, status
    # read and following run all remain the real core workflow.
    assert :erlang.suspend_process(coordinator)
    state = :sys.get_state(owner)
    generation = state.model_census.generation
    call = state.session.model_binding.call
    proof = make_ref()

    candidate =
      spawn(fn ->
        receive do
          {:release_empty_invocation, ^generation, ^call, pid, ^proof, release_ref, deadline}
          when pid == self() ->
            send(test, {:empty_release, self(), release_ref, deadline})

            receive do
              :ack_release ->
                send(owner, {:empty_invocation_released, self(), release_ref})

                receive do
                  :finish -> :ok
                end

              :finish ->
                :ok
            end
        end
      end)

    candidate_monitor = Process.monitor(candidate)
    on_exit(fn -> if Process.alive?(candidate), do: Process.exit(candidate, :kill) end)

    :sys.replace_state(owner, fn state ->
      pending = %{
        phase: :retired_wait_down,
        call: call,
        proof: proof,
        candidate: candidate,
        candidate_monitor: Process.monitor(candidate),
        candidate_down: false,
        callback_down: true,
        callback_monitor: make_ref(),
        revision: 0,
        resources: %{},
        registries: %{},
        resource_monitors: %{},
        timer: nil,
        retirement_timer: nil
      }

      :atomics.put(cell, 2, 1)
      %{state | model_census: %{state.model_census | pending: pending}}
    end)

    resume(facade)

    await(owner, fn state ->
      case state.session.settlement do
        %{stage: :status} -> {:ok, :status}
        _ -> :wait
      end
    end)

    assert :sys.get_state(owner).session.active.wait_deadline == first_wait_deadline

    timed_out_run_id =
      if mode == :background do
        assert_receive {:first_ask_result, first_pid, {:error, {:timeout, %{run_id: run_id}}}},
                       2_000

        assert first_pid == first.pid
        assert is_binary(run_id)
        assert {:error, {:timeout, %{run_id: ^run_id}}} = Ephemeral.last_result(session)
        assert {:error, :run_open} = Ephemeral.ask(session, "premature second prompt")
        run_id
      else
        assert nil == Task.yield(first, 10)
        nil
      end

    refute_receive {:empty_release, ^candidate, _, _}, 10
    resume(coordinator)

    assert_receive {:empty_release, ^candidate, release_ref, deadline}, 1_000
    assert is_reference(release_ref)
    assert deadline > System.monotonic_time()
    if mode == :waiting, do: assert(nil == Task.yield(first, 10))
    assert Process.alive?(candidate)

    if mode == :waiting,
      do: assert(:sys.get_state(owner).session.active.wait_deadline == first_wait_deadline)

    owner_monitor = :sys.get_state(owner).model_census.pending.candidate_monitor
    send(owner, {:DOWN, make_ref(), :process, candidate, :normal})
    send(owner, {:DOWN, owner_monitor, :process, self(), :normal})
    assert :sys.get_state(owner).model_census.pending.candidate == candidate
    assert :atomics.get(cell, 2) == 1

    send(owner, {:empty_invocation_released, candidate, make_ref()})
    send(owner, {:empty_invocation_released, self(), release_ref})

    refute :sys.get_state(owner).session.settlement.acked

    if mode == :waiting, do: assert(nil == Task.yield(first, 25))
    assert :atomics.get(cell, 2) == 1
    assert {:error, :run_open} = Ephemeral.ask(session, "premature second prompt")

    if mode == :waiting do
      send(candidate, :ack_release)

      await(owner, fn state ->
        if state.session.settlement.acked, do: {:ok, :acked}, else: :wait
      end)
    else
      refute :sys.get_state(owner).session.settlement.acked
    end

    if mode == :waiting, do: assert(nil == Task.yield(first, 10))
    assert :atomics.get(cell, 2) == 1
    assert {:error, :run_open} = Ephemeral.ask(session, "premature second prompt")

    if mode == :background do
      assert {:error, {:timeout, _}} = Ephemeral.last_result(session)
    end

    send(candidate, :finish)
    assert_receive {:DOWN, ^candidate_monitor, :process, ^candidate, :normal}, 1_000

    if mode == :waiting do
      assert {:ok, {:ok, %{outcome: :completed, text: "first answer"}}} =
               Task.yield(first, 2_000)
    else
      await(owner, fn _state ->
        case Ephemeral.last_result(session) do
          {:ok, %{outcome: :completed, text: "first answer", run_id: ^timed_out_run_id} = result} ->
            {:ok, result}

          _ ->
            :wait
        end
      end)

      send(first.pid, :audit_borrower_mailbox)

      assert {{:error, {:timeout, %{run_id: ^timed_out_run_id}}}, messages} =
               Task.await(first, 2_000)

      refute Enum.any?(messages, &match?({^owner, _, _}, &1))
    end

    assert :atomics.get(cell, 2) == 0
    second = Task.async(fn -> Ephemeral.ask(session, "second prompt") end)
    assert_receive {:model_request, ^server, 2, second_request}, 15_000
    assert second_request =~ "second prompt"

    second_pending =
      await(owner, fn state ->
        case state.model_census.pending do
          %{resources: resources, registries: registries} = pending
          when map_size(resources) == 5 and map_size(registries) == 2 ->
            {:ok, pending}

          _ ->
            :wait
        end
      end)

    assert second_pending.call != first_pending.call
    assert second_pending.registries.worker != first_pending.registries.worker
    send(server, {:reply, 2})

    assert {:ok, {:ok, %{outcome: :completed, text: "second answer"}}} =
             Task.yield(second, 5_000)

    assert :atomics.get(cell, 2) == 0
    assert :sys.get_state(owner).model_census.pending == nil
    for {_role, pid} <- second_pending.resources, do: refute(Process.alive?(pid))
    assert Registry.lookup(Req.Finch, second_pending.registries.worker) == []

    assert Registry.lookup(Req.Finch.SupervisorRegistry, second_pending.registries.supervisor) ==
             []

    assert :ok = Ephemeral.stop_session(session)
    refute File.exists?(root)
  end

  test "a timed-out real-core ask later settles and permits a second prompt" do
    workspace =
      Path.join(System.tmp_dir!(), "loopex-serial-timeout-#{System.unique_integer([:positive])}")

    File.mkdir!(workspace)
    on_exit(fn -> File.rm_rf!(workspace) end)
    {port, server} = held_server()

    assert {:ok, {:loopex_ephemeral_session, owner, _cell} = session} =
             Ephemeral.start_session(
               policy: Policy,
               model: "ollama:llama3.2",
               base_url: "http://127.0.0.1:#{port}/v1",
               cwd: workspace,
               tools: :none,
               max_tokens: 128,
               timeout: 15_000
             )

    on_exit(fn -> if Process.alive?(owner), do: Ephemeral.stop_session(session) end)

    first = Task.async(fn -> Ephemeral.ask(session, "first prompt", timeout: 100) end)
    assert_receive {:model_request, ^server, 1, first_request}, 15_000
    assert first_request =~ "first prompt"
    assert {:error, {:timeout, %{run_id: run_id}}} = Task.await(first, 3_000)
    assert is_binary(run_id)
    assert {:error, :run_open} = Ephemeral.ask(session, "premature second prompt")

    send(server, {:reply, 1})

    assert %{outcome: :completed, text: "first answer", run_id: ^run_id} =
             await(owner, fn _state ->
               case Ephemeral.last_result(session) do
                 {:ok, result} -> {:ok, result}
                 _ -> :wait
               end
             end)

    second = Task.async(fn -> Ephemeral.ask(session, "second prompt") end)
    assert_receive {:model_request, ^server, 2, second_request}, 15_000
    assert second_request =~ "second prompt"
    send(server, {:reply, 2})

    assert {:ok, {:ok, %{outcome: :completed, text: "second answer"}}} =
             Task.yield(second, 5_000)

    assert :ok = Ephemeral.stop_session(session)
  end

  defp held_server do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, {_, port}} = :inet.sockname(listener)
    test = self()

    server =
      spawn(fn ->
        for index <- 1..2 do
          {:ok, socket} = :gen_tcp.accept(listener, 15_000)
          {:ok, request} = read_request(socket, <<>>)
          send(test, {:model_request, self(), index, request})

          receive do
            {:reply, ^index} -> :ok
          end

          body = response(if(index == 1, do: "first answer", else: "second answer"))

          :ok =
            :gen_tcp.send(socket, [
              "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: ",
              Integer.to_string(byte_size(body)),
              "\r\nconnection: close\r\n\r\n",
              body
            ])

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
      {end_of_headers, 4} ->
        header_size = end_of_headers + 4
        <<headers::binary-size(^header_size), body::binary>> = buffered

        length =
          case Regex.run(~r/content-length:\s*(\d+)/i, headers) do
            [_, digits] -> String.to_integer(digits)
            _ -> 0
          end

        if byte_size(body) >= length, do: {:ok, buffered}, else: read_more(socket, buffered)

      :nomatch ->
        read_more(socket, buffered)
    end
  end

  defp read_more(socket, buffered) when byte_size(buffered) <= 1_048_576 do
    with {:ok, chunk} <- :gen_tcp.recv(socket, 0, 15_000) do
      read_request(socket, buffered <> chunk)
    end
  end

  defp response(text) do
    JSON.encode!(%{
      id: "chatcmpl-serial",
      object: "chat.completion",
      created: 1_800_000_000,
      model: "llama3.2",
      choices: [
        %{index: 0, message: %{role: "assistant", content: text}, finish_reason: "stop"}
      ],
      usage: %{prompt_tokens: 12, completion_tokens: 3, total_tokens: 15}
    })
  end

  defp await(owner, read, attempts \\ 300)
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

  defp await_core(runtime, session_id, ready?, attempts \\ 300)
  defp await_core(_runtime, _session_id, _ready?, 0), do: flunk("core never finished the run")

  defp await_core(runtime, session_id, ready?, attempts) do
    case Loopex.session_status(runtime, session_id) do
      {:ok, status} ->
        if ready?.(status) do
          status
        else
          Process.sleep(5)
          await_core(runtime, session_id, ready?, attempts - 1)
        end

      _ ->
        Process.sleep(5)
        await_core(runtime, session_id, ready?, attempts - 1)
    end
  end

  defp resume(pid) when is_pid(pid) do
    :erlang.resume_process(pid)
  catch
    :error, :badarg -> :ok
  end
end
