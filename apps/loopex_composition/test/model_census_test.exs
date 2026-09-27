defmodule LoopexComposition.Ephemeral.ModelCensusTest do
  @moduledoc false
  use ExUnit.Case, async: true
  alias LoopexComposition.Ephemeral.ModelCensus
  alias LoopexComposition.SessionAdmission

  test "one live callback reserves the sole pending record and exact no-proxy cancellation clears it" do
    generation = make_ref()
    cell = :atomics.new(2, [])
    {owner, monitor} = census_owner(generation, cell)
    handle = SessionAdmission.handle(owner, generation, cell)
    call = make_ref()

    assert {:ok, _} = SessionAdmission.request(handle, {:begin_model, self(), call}, deadline())
    assert :atomics.get(cell, 2) == 1

    assert {:error, :session_admission_closed} =
             SessionAdmission.request(handle, {:begin_model, self(), make_ref()}, deadline())

    assert {:ok, _} =
             SessionAdmission.request(handle, {:cancel_model, call, :no_proxy}, deadline())

    assert :atomics.get(cell, 2) == 0

    assert {:error, :session_admission_closed} =
             SessionAdmission.request(handle, {:begin_model, self(), call}, deadline())

    assert {:ok, _} =
             SessionAdmission.request(handle, {:begin_model, self(), make_ref()}, deadline())

    send(owner, :stop)
    assert_receive {:DOWN, ^monitor, :process, ^owner, :normal}
  end

  test "a cached work grant cannot be replayed after the lifecycle closes" do
    for lifecycle <- [1, 2, 3] do
      generation = make_ref()
      cell = :atomics.new(2, [])
      state = ModelCensus.new(generation, cell)
      owner = self()
      operation = {:begin_model, self(), make_ref()}
      reference = make_ref()
      expiry = deadline()
      message = {:loopex_session_admission, self(), reference, generation, operation, expiry}
      state = ModelCensus.handle(state, message)

      assert_receive {:loopex_session_admission_result, ^owner, ^reference, ^generation,
                      ^operation, ^expiry, {:ok, _}}

      :atomics.put(cell, 1, lifecycle)
      ModelCensus.handle(state, message)

      assert_receive {:loopex_session_admission_result, ^owner, ^reference, ^generation,
                      ^operation, ^expiry, {:error, :session_admission_closed}}

      Process.demonitor(state.pending.callback_monitor, [:flush])
    end
  end

  test "a different operation cannot reuse the begin message reference" do
    generation = make_ref()
    cell = :atomics.new(2, [])
    {owner, monitor} = census_owner(generation, cell)
    call = make_ref()
    reference = make_ref()
    expiry = deadline()
    begin = {:begin_model, self(), call}
    send(owner, {:loopex_session_admission, self(), reference, generation, begin, expiry})

    assert_receive {:loopex_session_admission_result, ^owner, ^reference, ^generation, ^begin,
                    ^expiry, {:ok, _}}

    cancel = {:cancel_model, call, :no_proxy}
    send(owner, {:loopex_session_admission, self(), reference, generation, cancel, expiry})

    assert_receive {:loopex_session_admission_result, ^owner, ^reference, ^generation, ^cancel,
                    ^expiry, {:error, :session_admission_closed}}

    assert :atomics.get(cell, 2) == 1

    handle = SessionAdmission.handle(owner, generation, cell)
    assert {:ok, _} = SessionAdmission.request(handle, cancel, deadline())
    assert :atomics.get(cell, 2) == 0
    send(owner, :stop)
    assert_receive {:DOWN, ^monitor, :process, ^owner, :normal}
  end

  test "a queued exact no-proxy cancellation settles when its callback exits first" do
    generation = make_ref()
    cell = :atomics.new(2, [])
    {owner, monitor} = census_owner(generation, cell)
    test = self()
    call = make_ref()

    {callback, callback_monitor} =
      spawn_monitor(fn ->
        handle = SessionAdmission.handle(owner, generation, cell)
        {:ok, _} = SessionAdmission.request(handle, {:begin_model, self(), call}, deadline())
        send(test, :begin_completed)

        send(
          owner,
          {:loopex_session_admission, self(), make_ref(), generation,
           {:cancel_model, call, :no_proxy}, deadline()}
        )
      end)

    assert_receive :begin_completed
    assert_receive {:DOWN, ^callback_monitor, :process, ^callback, :normal}
    await_slot(owner, cell, 0)
    assert :atomics.get(cell, 1) == 0
    send(owner, :stop)
    assert_receive {:DOWN, ^monitor, :process, ^owner, :normal}
  end

  test "a repeated callback DOWN cannot renew its single cleanup window" do
    generation = make_ref()
    cell = :atomics.new(2, [])
    {owner, monitor} = census_owner(generation, cell)
    test = self()

    {callback, callback_monitor} =
      spawn_monitor(fn ->
        handle = SessionAdmission.handle(owner, generation, cell)

        send(
          test,
          {:begun,
           SessionAdmission.request(handle, {:begin_model, self(), make_ref()}, deadline())}
        )
      end)

    assert_receive {:begun, {:ok, _}}
    assert_receive {:DOWN, ^callback_monitor, :process, ^callback, :normal}
    await_callback_down(owner)
    send(owner, {:inspect, self()})
    assert_receive {:census_state, %{pending: %{callback_monitor: owner_monitor}}}
    Process.sleep(550)
    send(owner, {:DOWN, owner_monitor, :process, callback, :normal})

    await_sealed(
      owner,
      cell,
      System.monotonic_time() + System.convert_time_unit(700, :millisecond, :native)
    )

    assert :atomics.get(cell, 1) == 3
    send(owner, :stop)
    assert_receive {:DOWN, ^monitor, :process, ^owner, :normal}
  end

  test "stage acknowledges only after the exact candidate commits cleanup custody" do
    generation = make_ref()
    cell = :atomics.new(2, [])
    {owner, owner_monitor} = census_owner(generation, cell)
    handle = SessionAdmission.handle(owner, generation, cell)
    call = make_ref()
    start_ref = make_ref()
    proof = make_ref()
    stop_ref = make_ref()
    {proxy, proxy_monitor} = spawn_monitor(fn -> :ok end)
    assert_receive {:DOWN, ^proxy_monitor, :process, ^proxy, :normal}
    callback = self()

    {candidate, candidate_monitor} =
      spawn_monitor(fn ->
        receive do
          {:model_custody_prepare, ^start_ref, staging_ref, expiry,
           {:model_cleanup_custody, ^owner, ^generation, ^call, candidate, ^proof} = custody} ->
            assert candidate == self()
            assert expiry > System.monotonic_time()
            send(owner, {:model_custody_prepared, self(), make_ref(), generation, call, proof})
            send(owner, {:model_custody_prepared, self(), staging_ref, generation, call, proof})
            send(callback, {:custody_committed, self(), staging_ref})

            receive do
              :retire ->
                result =
                  SessionAdmission.request(
                    custody,
                    {:retire_model, call, self(), proof},
                    deadline()
                  )

                send(callback, {:retirement_recorded, self(), result})
                receive do: (:stop -> :ok)
            end
        end
      end)

    assert {:ok, _} = SessionAdmission.request(handle, {:begin_model, self(), call}, deadline())

    assert {:error, :session_admission_closed} =
             SessionAdmission.request(
               handle,
               {:register_model, call, candidate, proof},
               deadline()
             )

    start_proof =
      {:model_start_proof, start_ref, proxy, proxy_monitor, :normal, candidate, candidate_monitor}

    assert {:ok, _} =
             SessionAdmission.request(
               handle,
               {:stage_model, call, candidate, proof, stop_ref, start_proof},
               deadline()
             )

    assert_receive {:custody_committed, ^candidate, staging_ref}
    assert is_reference(staging_ref)

    assert {:ok, _} =
             SessionAdmission.request(
               handle,
               {:register_model, call, candidate, proof},
               deadline()
             )

    assert :atomics.get(cell, 2) == 1
    send(candidate, :retire)
    assert_receive {:retirement_recorded, ^candidate, {:ok, _}}
    assert :atomics.get(cell, 2) == 1
    send(candidate, :stop)
    assert_receive {:DOWN, ^candidate_monitor, :process, ^candidate, :normal}
    await_slot(owner, cell, 0)
    send(owner, :stop)
    assert_receive {:DOWN, ^owner_monitor, :process, ^owner, :normal}
  end

  test "candidate death before staging acknowledgement clears an empty unregistered call" do
    generation = make_ref()
    cell = :atomics.new(2, [])
    {owner, owner_monitor} = census_owner(generation, cell)
    handle = SessionAdmission.handle(owner, generation, cell)
    call = make_ref()
    start_ref = make_ref()
    {proxy, proxy_monitor} = spawn_monitor(fn -> :ok end)
    assert_receive {:DOWN, ^proxy_monitor, :process, ^proxy, :normal}

    {candidate, candidate_monitor} =
      spawn_monitor(fn ->
        receive do
          {:model_custody_prepare, ^start_ref, _staging_ref, _expiry, _custody} -> :ok
        end
      end)

    assert {:ok, _} = SessionAdmission.request(handle, {:begin_model, self(), call}, deadline())

    assert {:error, :session_admission_closed} =
             SessionAdmission.request(
               handle,
               {:stage_model, call, candidate, make_ref(), make_ref(),
                {:model_start_proof, start_ref, proxy, proxy_monitor, :normal, candidate,
                 candidate_monitor}},
               deadline()
             )

    assert_receive {:DOWN, ^candidate_monitor, :process, ^candidate, :normal}
    await_slot(owner, cell, 0)
    assert :atomics.get(cell, 1) == 0

    assert {:ok, _} =
             SessionAdmission.request(handle, {:begin_model, self(), make_ref()}, deadline())

    send(owner, :stop)
    assert_receive {:DOWN, ^owner_monitor, :process, ^owner, :normal}
  end

  test "candidate death after sending custody but before its delivery clears an ungranted call" do
    owner = self()

    {candidate, candidate_monitor} =
      spawn_monitor(fn ->
        receive do
          {:model_custody_prepare, _start_ref, staging_ref, _expiry,
           {:model_cleanup_custody, ^owner, generation, call, _candidate, proof}} ->
            send(owner, {:model_custody_prepared, self(), staging_ref, generation, call, proof})
        end
      end)

    {state, cell, _generation, _call, _proof} = direct_staging(candidate, candidate_monitor)
    owner_monitor = state.pending.candidate_monitor

    assert_receive {:model_custody_prepared, ^candidate, _, _, _, _} = custody
    assert_receive {:DOWN, ^candidate_monitor, :process, ^candidate, :normal}
    assert_receive {:DOWN, ^owner_monitor, :process, ^candidate, :normal} = down

    state = ModelCensus.handle(state, custody)
    refute state.pending.stage_issued
    state = ModelCensus.handle(state, down)
    assert state.pending == nil
    assert :atomics.get(cell, 2) == 0
    assert :atomics.get(cell, 1) == 0
  end

  test "late custody delivery cannot enable a fresh register request" do
    owner = self()

    {candidate, candidate_monitor} =
      spawn_monitor(fn ->
        receive do
          {:model_custody_prepare, _start_ref, staging_ref, _expiry,
           {:model_cleanup_custody, ^owner, generation, call, _candidate, proof}} ->
            send(owner, {:candidate_ready, self()})

            receive do
              :commit ->
                send(
                  owner,
                  {:model_custody_prepared, self(), staging_ref, generation, call, proof}
                )

                receive do: (:stop -> :ok)
            end
        end
      end)

    expiry = System.monotonic_time() + System.convert_time_unit(400, :millisecond, :native)

    {state, cell, generation, call, proof} =
      direct_staging(candidate, candidate_monitor, expiry)

    assert_receive {:candidate_ready, ^candidate}
    assert state.pending.phase == :staging

    remaining =
      System.convert_time_unit(max(0, expiry - System.monotonic_time()), :native, :millisecond)

    Process.sleep(remaining + 10)
    send(candidate, :commit)
    assert_receive {:model_custody_prepared, ^candidate, _, ^generation, ^call, ^proof} = custody

    state = ModelCensus.handle(state, custody)
    assert state.pending.phase == :provisional
    refute state.pending.stage_issued

    register = {:register_model, call, candidate, proof}
    request = {:loopex_session_admission, self(), make_ref(), generation, register, deadline()}
    state = ModelCensus.handle(state, request)

    assert_receive {:loopex_session_admission_result, ^owner, _, ^generation, ^register, _,
                    {:error, :session_admission_closed}}

    assert state.pending.phase == :provisional
    assert :atomics.get(cell, 2) == 1
    send(candidate, :stop)
    assert_receive {:DOWN, ^candidate_monitor, :process, ^candidate, :normal}
  end

  test "callback loss retains no arbitrary exit value and keeps pending until proof" do
    generation = make_ref()
    cell = :atomics.new(2, [])
    {owner, monitor} = census_owner(generation, cell)
    test = self()
    canary = "request-bearing-callback-exit"

    {callback, callback_monitor} =
      spawn_monitor(fn ->
        handle = SessionAdmission.handle(owner, generation, cell)

        send(
          test,
          {:begun,
           SessionAdmission.request(handle, {:begin_model, self(), make_ref()}, deadline())}
        )

        receive do: (:exit -> exit({:private, canary}))
      end)

    assert_receive {:begun, {:ok, _}}
    send(callback, :exit)
    assert_receive {:DOWN, ^callback_monitor, :process, ^callback, {:private, ^canary}}
    await_callback_down(owner)
    send(owner, {:inspect, self()})
    assert_receive {:census_state, state}
    refute inspect(state) =~ canary
    assert :atomics.get(cell, 2) == 1
    send(owner, :stop)
    assert_receive {:DOWN, ^monitor, :process, ^owner, :normal}
  end

  test "missing callback cleanup seals only its cell after the bounded reconciliation window" do
    generation = make_ref()
    cell = :atomics.new(2, [])
    peer_cell = :atomics.new(2, [])
    {owner, monitor} = census_owner(generation, cell)
    test = self()

    {callback, callback_monitor} =
      spawn_monitor(fn ->
        handle = SessionAdmission.handle(owner, generation, cell)

        send(
          test,
          {:begun,
           SessionAdmission.request(handle, {:begin_model, self(), make_ref()}, deadline())}
        )
      end)

    assert_receive {:begun, {:ok, _}}
    assert_receive {:DOWN, ^callback_monitor, :process, ^callback, :normal}
    await_callback_down(owner)
    assert :atomics.get(cell, 1) == 0
    assert :atomics.get(cell, 2) == 1
    await_sealed(owner, cell, deadline() + System.convert_time_unit(250, :millisecond, :native))
    assert :atomics.get(cell, 1) == 3
    assert :atomics.get(cell, 2) == 1
    assert :atomics.get(peer_cell, 1) == 0
    assert :atomics.get(peer_cell, 2) == 0
    assert Process.alive?(owner)
    send(owner, :stop)
    assert_receive {:DOWN, ^monitor, :process, ^owner, :normal}
  end

  defp await_sealed(owner, cell, expiry) do
    if :atomics.get(cell, 1) != 3 do
      assert System.monotonic_time() < expiry
      send(owner, {:inspect, self()})
      assert_receive {:census_state, _state}
      Process.sleep(1)
      await_sealed(owner, cell, expiry)
    end
  end

  defp direct_staging(candidate, candidate_monitor, stage_expiry \\ nil) do
    generation = make_ref()
    cell = :atomics.new(2, [])
    call = make_ref()
    proof = make_ref()
    stop_ref = make_ref()
    start_ref = make_ref()
    owner = self()
    {proxy, proxy_monitor} = spawn_monitor(fn -> :ok end)
    assert_receive {:DOWN, ^proxy_monitor, :process, ^proxy, :normal}

    state = ModelCensus.new(generation, cell)
    begin = {:begin_model, owner, call}

    state =
      ModelCensus.handle(
        state,
        {:loopex_session_admission, owner, make_ref(), generation, begin, deadline()}
      )

    assert_receive {:loopex_session_admission_result, ^owner, _, ^generation, ^begin, _, {:ok, _}}

    start_proof =
      {:model_start_proof, start_ref, proxy, proxy_monitor, :normal, candidate, candidate_monitor}

    stage = {:stage_model, call, candidate, proof, stop_ref, start_proof}

    state =
      ModelCensus.handle(
        state,
        {:loopex_session_admission, owner, make_ref(), generation, stage,
         stage_expiry || deadline()}
      )

    assert state.pending.phase == :staging
    assert state.pending.proxy == proxy
    assert state.pending.proxy_monitor == proxy_monitor
    assert state.pending.candidate_start_monitor == candidate_monitor
    assert state.pending.start_ref == start_ref
    assert state.pending.stop_ref == stop_ref
    {state, cell, generation, call, proof}
  end

  defp await_callback_down(owner) do
    send(owner, {:inspect, self()})
    assert_receive {:census_state, state}

    if state.pending.callback_down == nil do
      await_callback_down(owner)
    end
  end

  defp await_slot(owner, cell, value), do: await_slot(owner, cell, value, deadline())

  defp await_slot(owner, cell, value, expiry) do
    if :atomics.get(cell, 2) != value do
      assert System.monotonic_time() < expiry
      send(owner, {:inspect, self()})
      assert_receive {:census_state, _state}
      Process.sleep(1)
      await_slot(owner, cell, value, expiry)
    end
  end

  defp census_owner(generation, cell) do
    {owner, monitor} =
      spawn_monitor(fn ->
        state = ModelCensus.new(generation, cell)
        census_loop(state)
      end)

    on_exit(fn -> if Process.alive?(owner), do: Process.exit(owner, :kill) end)
    {owner, monitor}
  end

  defp census_loop(state) do
    receive do
      :stop ->
        :ok

      {:inspect, requester} ->
        send(requester, {:census_state, state})
        census_loop(state)

      message ->
        census_loop(ModelCensus.handle(state, message))
    end
  end

  defp deadline,
    do: System.monotonic_time() + System.convert_time_unit(1_000, :millisecond, :native)
end
