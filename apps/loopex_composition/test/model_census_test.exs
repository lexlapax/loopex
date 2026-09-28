defmodule LoopexComposition.Ephemeral.ModelCensusTest do
  @moduledoc false
  use ExUnit.Case, async: true
  alias LoopexComposition.Ephemeral.ModelCensus
  alias LoopexComposition.SessionAdmission

  test "closure proof requires both an empty census and cleared slot two" do
    generation = make_ref()
    cell = :atomics.new(2, [])
    empty = ModelCensus.new(generation, cell)
    assert ModelCensus.settled?(empty)

    :atomics.put(cell, 2, 1)
    refute ModelCensus.settled?(empty)
    :atomics.put(cell, 2, 0)

    call = make_ref()
    reference = make_ref()
    operation = {:begin_model, self(), call}

    pending =
      ModelCensus.handle(
        empty,
        {:loopex_session_admission, self(), reference, generation, operation, deadline()}
      )

    assert_receive {:loopex_session_admission_result, _, ^reference, ^generation, ^operation, _,
                    {:ok, _}}

    refute ModelCensus.settled?(pending)
    :atomics.put(cell, 2, 0)
    refute ModelCensus.settled?(pending)
  end

  test "cleanup-only route rejects every work operation without messaging the owner" do
    generation = make_ref()
    call = make_ref()
    proof = make_ref()
    handle = {:model_cleanup_custody, self(), generation, call, self(), proof}

    for operation <- [
          {:begin_model, self(), call},
          {:register_model, call, self(), proof},
          {:record_model_resources, call, self(), 1, []}
        ] do
      assert {:error, :session_admission_closed} =
               Loopex.LLM.ReqLLM.InProcess.Admission.request(
                 SessionAdmission,
                 handle,
                 operation,
                 deadline()
               )
    end

    refute_receive {:loopex_session_admission, _, _, _, _, _}, 20
  end

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

  test "an authoritative failed proxy start and normal DOWN clear a no-candidate call" do
    generation = make_ref()
    cell = :atomics.new(2, [])
    {owner, owner_monitor} = census_owner(generation, cell)
    handle = SessionAdmission.handle(owner, generation, cell)
    call = make_ref()
    start_ref = make_ref()
    {proxy, proxy_monitor} = spawn_monitor(fn -> :ok end)
    assert_receive {:DOWN, ^proxy_monitor, :process, ^proxy, :normal}

    assert {:ok, _} = SessionAdmission.request(handle, {:begin_model, self(), call}, deadline())

    proof =
      {:model_start_proof, start_ref, proxy, proxy_monitor, :normal, :not_started,
       {:error, :unavailable}}

    assert {:error, :session_admission_closed} =
             SessionAdmission.request(
               handle,
               {:cancel_model, call,
                {:model_start_proof, start_ref, proxy, proxy_monitor, :normal, :not_started,
                 {:ok, self()}}},
               deadline()
             )

    assert :atomics.get(cell, 2) == 1
    assert {:ok, _} = SessionAdmission.request(handle, {:cancel_model, call, proof}, deadline())
    assert :atomics.get(cell, 2) == 0
    assert :atomics.get(cell, 1) == 0
    send(owner, :stop)
    assert_receive {:DOWN, ^owner_monitor, :process, ^owner, :normal}
  end

  test "retirement proof cannot reuse any admission message reference" do
    generation = make_ref()
    cell = :atomics.new(2, [])
    {owner, owner_monitor} = census_owner(generation, cell)
    call = make_ref()
    begin_ref = make_ref()
    begin = {:begin_model, self(), call}
    send(owner, {:loopex_session_admission, self(), begin_ref, generation, begin, deadline()})

    assert_receive {:loopex_session_admission_result, ^owner, ^begin_ref, ^generation, ^begin, _,
                    {:ok, _}}

    {proxy, proxy_monitor} = spawn_monitor(fn -> :ok end)
    assert_receive {:DOWN, ^proxy_monitor, :process, ^proxy, :normal}
    test = self()

    candidate =
      spawn(fn ->
        receive do
          {:model_custody_prepare, _, _, _, _, _} -> send(test, :unexpected_custody)
          :stop -> :ok
        end
      end)

    candidate_monitor = Process.monitor(candidate)
    on_exit(fn -> if Process.alive?(candidate), do: Process.exit(candidate, :kill) end)
    start_ref = make_ref()
    stop_ref = make_ref()
    stage_ref = make_ref()

    for bad_proof <- [begin_ref, stage_ref] do
      stage =
        {:stage_model, call, candidate, bad_proof, stop_ref,
         {:model_start_proof, start_ref, proxy, proxy_monitor, :normal, candidate,
          candidate_monitor}}

      send(owner, {:loopex_session_admission, self(), stage_ref, generation, stage, deadline()})

      assert_receive {:loopex_session_admission_result, ^owner, ^stage_ref, ^generation, ^stage,
                      _, {:error, :session_admission_closed}}

      refute_receive :unexpected_custody, 10
    end

    assert :atomics.get(cell, 2) == 1
    send(candidate, :stop)
    assert_receive {:DOWN, ^candidate_monitor, :process, ^candidate, :normal}
    send(owner, :stop)
    assert_receive {:DOWN, ^owner_monitor, :process, ^owner, :normal}
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
          {:model_custody_prepare, ^start_ref, staging_ref, expiry, SessionAdmission,
           {:model_cleanup_custody, ^owner, ^generation, ^call, candidate, ^proof} = custody} ->
            assert candidate == self()
            assert expiry > System.monotonic_time()
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

    assert {:ok, {:session_grant, ^generation, :stage_model, ^callback, staging_ref, _}} =
             SessionAdmission.request(
               handle,
               {:stage_model, call, candidate, proof, stop_ref, start_proof},
               deadline()
             )

    assert_receive {:custody_committed, ^candidate, ^staging_ref}
    assert is_reference(staging_ref)
    send(owner, {:inspect, self()})
    assert_receive {:census_state, %{pending: %{stage_ref: ^staging_ref}}}

    collided_register = {:register_model, call, candidate, proof}
    collided_expiry = deadline()

    send(
      owner,
      {:loopex_session_admission, self(), proof, generation, collided_register, collided_expiry}
    )

    assert_receive {:loopex_session_admission_result, ^owner, ^proof, ^generation,
                    ^collided_register, ^collided_expiry, {:error, :session_admission_closed}}

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
          {:model_custody_prepare, ^start_ref, _staging_ref, _expiry, SessionAdmission, _custody} ->
            :ok
        end
      end)

    assert {:ok, _} = SessionAdmission.request(handle, {:begin_model, self(), call}, deadline())

    assert {:error, :model_stage_cancelled} =
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

  test "the live session owner and request helper complete exact no-registration cancellation" do
    generation = make_ref()
    cell = :atomics.new(2, [])
    {owner, owner_monitor} = census_owner(generation, cell)
    handle = SessionAdmission.handle(owner, generation, cell)
    call = make_ref()
    proof = make_ref()
    start_ref = make_ref()
    {proxy, proxy_monitor} = spawn_monitor(fn -> :ok end)
    assert_receive {:DOWN, ^proxy_monitor, :process, ^proxy, :normal}

    {candidate, candidate_monitor} =
      spawn_monitor(fn ->
        receive do
          {:model_custody_prepare, ^start_ref, staging_ref, _expiry, SessionAdmission,
           {:model_cleanup_custody, ^owner, ^generation, ^call, _candidate, ^proof}} ->
            send(owner, {:model_custody_prepared, self(), staging_ref, generation, call, proof})
            receive do: (:stop -> :ok)
        end
      end)

    assert {:ok, _} = SessionAdmission.request(handle, {:begin_model, self(), call}, deadline())

    start_proof =
      {:model_start_proof, start_ref, proxy, proxy_monitor, :normal, candidate, candidate_monitor}

    assert {:ok, _} =
             SessionAdmission.request(
               handle,
               {:stage_model, call, candidate, proof, make_ref(), start_proof},
               deadline()
             )

    operation =
      {:cancel_model, call,
       {:registration_refused, {:error, :provider_resource_refused}, candidate, candidate_monitor}}

    assert {:ok, {:session_grant, ^generation, :cancel_model, _, _, _}} =
             SessionAdmission.request(handle, operation, deadline())

    refute Process.alive?(candidate)
    assert :atomics.get(cell, 1) == 0
    assert :atomics.get(cell, 2) == 0

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
          {:model_custody_prepare, _start_ref, staging_ref, _expiry, SessionAdmission,
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

  test "identical custody replay is inert but a conflicting replay seals only this session" do
    owner = self()

    {candidate, candidate_monitor} =
      spawn_monitor(fn ->
        receive do
          {:model_custody_prepare, _start_ref, staging_ref, _expiry, SessionAdmission,
           {:model_cleanup_custody, ^owner, generation, call, _candidate, proof}} ->
            send(owner, {:model_custody_prepared, self(), staging_ref, generation, call, proof})
            receive do: (:stop -> :ok)
        end
      end)

    on_exit(fn -> if Process.alive?(candidate), do: Process.exit(candidate, :kill) end)
    {state, cell, generation, call, proof} = direct_staging(candidate, candidate_monitor)

    assert_receive {:model_custody_prepared, ^candidate, staging_ref, ^generation, ^call, ^proof} =
                     custody

    state = ModelCensus.handle(state, custody)
    assert state.pending.phase == :provisional
    state = ModelCensus.handle(state, custody)
    assert state.pending.phase == :provisional
    assert :atomics.get(cell, 1) == 0

    state =
      ModelCensus.handle(
        state,
        {:model_custody_prepared, candidate, staging_ref, generation, call, make_ref()}
      )

    assert state.pending.phase == :unproved
    assert :atomics.get(cell, 1) == 3
    assert :atomics.get(cell, 2) == 1
    send(candidate, :stop)
    assert_receive {:DOWN, ^candidate_monitor, :process, ^candidate, :normal}
  end

  test "conflicting custody acknowledgement before stage grant seals without permission" do
    owner = self()

    {candidate, candidate_monitor} =
      spawn_monitor(fn ->
        receive do
          {:model_custody_prepare, _start_ref, _staging_ref, _expiry, SessionAdmission,
           {:model_cleanup_custody, ^owner, generation, call, _candidate, proof}} ->
            send(owner, {:model_custody_prepared, self(), make_ref(), generation, call, proof})
            receive do: (:stop -> :ok)
        end
      end)

    on_exit(fn -> if Process.alive?(candidate), do: Process.exit(candidate, :kill) end)
    {state, cell, generation, call, proof} = direct_staging(candidate, candidate_monitor)
    assert_receive {:model_custody_prepared, ^candidate, _, ^generation, ^call, ^proof} = bad_ack
    state = ModelCensus.handle(state, bad_ack)
    assert state.pending.phase == :unproved
    assert :atomics.get(cell, 1) == 3
    assert :atomics.get(cell, 2) == 1

    assert_receive {:loopex_session_admission_result, ^owner, _, ^generation,
                    {:stage_model, ^call, ^candidate, ^proof, _, _}, _,
                    {:error, :session_admission_closed}}

    send(candidate, :stop)
    assert_receive {:DOWN, ^candidate_monitor, :process, ^candidate, :normal}
  end

  test "late custody delivery cannot enable a fresh register request" do
    owner = self()

    {candidate, candidate_monitor} =
      spawn_monitor(fn ->
        receive do
          {:model_custody_prepare, _start_ref, staging_ref, _expiry, SessionAdmission,
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

  test "callback death after recorded empty retirement does not seal a held candidate" do
    owner = self()
    generation = make_ref()
    cell = :atomics.new(2, [])
    call = make_ref()
    proof = make_ref()
    start_ref = make_ref()
    stop_ref = make_ref()
    callback = spawn(fn -> receive do: (:stop -> :ok) end)
    {proxy, proxy_monitor} = spawn_monitor(fn -> :ok end)
    assert_receive {:DOWN, ^proxy_monitor, :process, ^proxy, :normal}

    {candidate, candidate_start_monitor} =
      spawn_monitor(fn ->
        receive do
          {:model_custody_prepare, ^start_ref, staging_ref, _expiry, SessionAdmission,
           {:model_cleanup_custody, ^owner, ^generation, ^call, _candidate, ^proof}} ->
            send(owner, {:model_custody_prepared, self(), staging_ref, generation, call, proof})

            receive do
              :retire ->
                operation = {:retire_model, call, self(), proof}

                send(
                  owner,
                  {:loopex_session_admission, self(), make_ref(), generation, operation,
                   deadline()}
                )

                receive do: (:stop -> :ok)
            end
        end
      end)

    state = ModelCensus.new(generation, cell)
    begin = {:begin_model, callback, call}

    state =
      ModelCensus.handle(
        state,
        {:loopex_session_admission, callback, make_ref(), generation, begin, deadline()}
      )

    start_proof =
      {:model_start_proof, start_ref, proxy, proxy_monitor, :normal, candidate,
       candidate_start_monitor}

    stage = {:stage_model, call, candidate, proof, stop_ref, start_proof}

    state =
      ModelCensus.handle(
        state,
        {:loopex_session_admission, callback, make_ref(), generation, stage, deadline()}
      )

    assert_receive {:model_custody_prepared, ^candidate, _, ^generation, ^call, ^proof} = custody
    state = ModelCensus.handle(state, custody)
    assert state.pending.stage_issued

    send(candidate, :retire)

    assert_receive {:loopex_session_admission, ^candidate, _, ^generation,
                    {:retire_model, ^call, ^candidate, ^proof}, _} = retirement

    state = ModelCensus.handle(state, retirement)
    assert state.pending.phase == :retired_wait_down
    assert :atomics.get(cell, 2) == 1

    callback_monitor = state.pending.callback_monitor
    send(callback, :stop)
    assert_receive {:DOWN, ^callback_monitor, :process, ^callback, :normal} = callback_down
    state = ModelCensus.handle(state, callback_down)
    assert state.pending.timer == nil
    assert :atomics.get(cell, 1) == 0

    candidate_owner_monitor = state.pending.candidate_monitor
    send(candidate, :stop)

    assert_receive {:DOWN, ^candidate_owner_monitor, :process, ^candidate, :normal} =
                     candidate_down

    state = ModelCensus.handle(state, candidate_down)
    assert state.pending == nil
    assert :atomics.get(cell, 2) == 0
  end

  test "live callback proves registrar was not entered around genuine candidate DOWN" do
    for order <- [:down_first, :cancel_first] do
      owner = self()

      {candidate, candidate_start_monitor} =
        spawn_monitor(fn ->
          receive do
            {:model_custody_prepare, _start_ref, staging_ref, _expiry, SessionAdmission,
             {:model_cleanup_custody, ^owner, generation, call, _candidate, proof}} ->
              send(owner, {:model_custody_prepared, self(), staging_ref, generation, call, proof})
              receive do: (:stop -> :ok)
          end
        end)

      {state, cell, generation, call, proof} = direct_staging(candidate, candidate_start_monitor)

      assert_receive {:model_custody_prepared, ^candidate, staging_ref, ^generation, ^call,
                      ^proof} = custody

      state = ModelCensus.handle(state, custody)
      assert state.pending.stage_issued

      assert_receive {:loopex_session_admission_result, ^owner, stage_ref_from_grant, ^generation,
                      {:stage_model, ^call, ^candidate, ^proof, _, _}, _,
                      {:ok, {:session_grant, ^generation, :stage_model, ^owner, grant_ref, _}}}

      assert stage_ref_from_grant == staging_ref
      assert grant_ref == stage_ref_from_grant

      operation =
        {:cancel_model, call,
         {:registrar_not_entered, stage_ref_from_grant, candidate, candidate_start_monitor,
          :normal}}

      request =
        {:loopex_session_admission, owner, make_ref(), generation, operation, deadline()}

      state =
        if order == :cancel_first do
          state = ModelCensus.handle(state, request)
          assert state.pending.phase == :cancelling

          refute_receive {:loopex_session_admission_result, ^owner, _, ^generation, ^operation, _,
                          _},
                         10

          state
        else
          state
        end

      owner_monitor = state.pending.candidate_monitor
      send(candidate, :stop)
      assert_receive {:DOWN, ^candidate_start_monitor, :process, ^candidate, :normal}
      assert_receive {:DOWN, ^owner_monitor, :process, ^candidate, :normal} = down
      state = ModelCensus.handle(state, down)

      state =
        if order == :down_first do
          wrong =
            {:cancel_model, call,
             {:registrar_not_entered, staging_ref, candidate, candidate_start_monitor, :killed}}

          state =
            ModelCensus.handle(
              state,
              {:loopex_session_admission, owner, make_ref(), generation, wrong, deadline()}
            )

          assert_receive {:loopex_session_admission_result, ^owner, _, ^generation, ^wrong, _,
                          {:error, :session_admission_closed}}

          ModelCensus.handle(state, request)
        else
          state
        end

      assert_receive {:loopex_session_admission_result, ^owner, _, ^generation, ^operation, _,
                      {:ok, _}}

      assert state.pending == nil
      assert :atomics.get(cell, 1) == 0
      assert :atomics.get(cell, 2) == 0
    end
  end

  test "exact registrar refusal prepares cancellation and grants only after its own candidate DOWN" do
    owner = self()

    {candidate, candidate_start_monitor} =
      spawn_monitor(fn ->
        receive do
          {:model_custody_prepare, _start_ref, staging_ref, _expiry, SessionAdmission,
           {:model_cleanup_custody, ^owner, generation, call, _candidate, proof}} ->
            send(owner, {:model_custody_prepared, self(), staging_ref, generation, call, proof})
            receive do: (:stop -> :ok)
        end
      end)

    {state, cell, generation, call, proof} = direct_staging(candidate, candidate_start_monitor)
    assert_receive {:model_custody_prepared, ^candidate, _, ^generation, ^call, ^proof} = custody
    state = ModelCensus.handle(state, custody)

    assert_receive {:loopex_session_admission_result, ^owner, _, ^generation,
                    {:stage_model, ^call, ^candidate, ^proof, _, _}, _, {:ok, _}}

    operation =
      {:cancel_model, call,
       {:registration_refused, {:error, :provider_resource_refused}, candidate,
        candidate_start_monitor}}

    reference = make_ref()
    expiry = deadline()

    state =
      ModelCensus.handle(
        state,
        {:loopex_session_admission, owner, reference, generation, operation, expiry}
      )

    assert state.pending.phase == :cancelling

    assert_receive {:loopex_session_admission_cancellation_prepared, ^owner, ^reference,
                    ^generation, ^operation, ^expiry, ^candidate}

    state =
      ModelCensus.handle(
        state,
        {:loopex_session_admission, owner, reference, generation, operation, expiry}
      )

    refute_receive {:loopex_session_admission_cancellation_prepared, ^owner, ^reference,
                    ^generation, ^operation, ^expiry, ^candidate},
                   10

    refute_receive {:loopex_session_admission_result, ^owner, ^reference, ^generation, ^operation,
                    ^expiry, _},
                   10

    candidate_owner_monitor = state.pending.candidate_monitor
    send(candidate, :stop)
    assert_receive {:DOWN, ^candidate_start_monitor, :process, ^candidate, :normal}
    assert_receive {:DOWN, ^candidate_owner_monitor, :process, ^candidate, :normal} = down
    state = ModelCensus.handle(state, down)

    assert_receive {:loopex_session_admission_result, ^owner, ^reference, ^generation, ^operation,
                    ^expiry, {:ok, _}}

    assert state.pending == nil
    assert :atomics.get(cell, 1) == 0
    assert :atomics.get(cell, 2) == 0
  end

  test "registrar cancellation refuses unproved results and mismatched candidate identity" do
    owner = self()

    {candidate, candidate_start_monitor} =
      spawn_monitor(fn ->
        receive do
          {:model_custody_prepare, _start_ref, staging_ref, _expiry, SessionAdmission,
           {:model_cleanup_custody, ^owner, generation, call, _candidate, proof}} ->
            send(owner, {:model_custody_prepared, self(), staging_ref, generation, call, proof})
            receive do: (:stop -> :ok)
        end
      end)

    {state, cell, generation, call, proof} = direct_staging(candidate, candidate_start_monitor)
    assert_receive {:model_custody_prepared, ^candidate, _, ^generation, ^call, ^proof} = custody
    state = ModelCensus.handle(state, custody)

    assert_receive {:loopex_session_admission_result, ^owner, _, ^generation,
                    {:stage_model, ^call, ^candidate, ^proof, _, _}, _, {:ok, _}}

    for result <- [
          {:registration_refused, {:error, :provider_guard_unavailable}, candidate,
           candidate_start_monitor},
          {:registration_refused, :unmanaged, self(), candidate_start_monitor},
          {:registration_refused, :unmanaged, candidate, make_ref()},
          {:registration_refused, :unmanaged, candidate, :not_a_monitor}
        ] do
      operation = {:cancel_model, call, result}
      reference = make_ref()
      expiry = deadline()

      next =
        ModelCensus.handle(
          state,
          {:loopex_session_admission, owner, reference, generation, operation, expiry}
        )

      assert_receive {:loopex_session_admission_result, ^owner, ^reference, ^generation,
                      ^operation, ^expiry, {:error, :session_admission_closed}}

      assert next.pending.phase == :provisional
      assert :atomics.get(cell, 2) == 1

      refute_receive {:loopex_session_admission_cancellation_prepared, ^owner, ^reference,
                      ^generation, ^operation, ^expiry, _},
                     10
    end

    send(candidate, :stop)
    assert_receive {:DOWN, ^candidate_start_monitor, :process, ^candidate, :normal}
    Process.demonitor(state.pending.candidate_monitor, [:flush])
  end

  test "candidate DOWN before exact registrar refusal is reconciled without an invented acknowledgement" do
    owner = self()

    {candidate, candidate_start_monitor} =
      spawn_monitor(fn ->
        receive do
          {:model_custody_prepare, _start_ref, staging_ref, _expiry, SessionAdmission,
           {:model_cleanup_custody, ^owner, generation, call, _candidate, proof}} ->
            send(owner, {:model_custody_prepared, self(), staging_ref, generation, call, proof})
            receive do: (:stop -> :ok)
        end
      end)

    {state, cell, generation, call, proof} = direct_staging(candidate, candidate_start_monitor)
    assert_receive {:model_custody_prepared, ^candidate, _, ^generation, ^call, ^proof} = custody
    state = ModelCensus.handle(state, custody)

    assert_receive {:loopex_session_admission_result, ^owner, _, ^generation,
                    {:stage_model, ^call, ^candidate, ^proof, _, _}, _, {:ok, _}}

    candidate_owner_monitor = state.pending.candidate_monitor
    send(candidate, :stop)
    assert_receive {:DOWN, ^candidate_start_monitor, :process, ^candidate, :normal}
    assert_receive {:DOWN, ^candidate_owner_monitor, :process, ^candidate, :normal} = down
    state = ModelCensus.handle(state, down)
    assert state.pending.phase == :provisional
    assert :atomics.get(cell, 2) == 1

    operation =
      {:cancel_model, call,
       {:registration_refused, :unmanaged, candidate, candidate_start_monitor}}

    reference = make_ref()
    expiry = deadline()

    state =
      ModelCensus.handle(
        state,
        {:loopex_session_admission, owner, reference, generation, operation, expiry}
      )

    assert_receive {:loopex_session_admission_cancellation_prepared, ^owner, ^reference,
                    ^generation, ^operation, ^expiry, ^candidate}

    assert_receive {:loopex_session_admission_result, ^owner, ^reference, ^generation, ^operation,
                    ^expiry, {:ok, _}}

    assert state.pending == nil
    assert :atomics.get(cell, 1) == 0
    assert :atomics.get(cell, 2) == 0
  end

  test "accepted no-registrar proof survives callback death before candidate DOWN" do
    owner = self()
    generation = make_ref()
    cell = :atomics.new(2, [])
    call = make_ref()
    proof = make_ref()
    start_ref = make_ref()
    stop_ref = make_ref()
    callback = spawn(fn -> callback_loop(owner) end)
    {proxy, proxy_monitor} = spawn_monitor(fn -> :ok end)
    assert_receive {:DOWN, ^proxy_monitor, :process, ^proxy, :normal}

    {candidate, candidate_start_monitor} =
      spawn_monitor(fn ->
        receive do
          {:model_custody_prepare, ^start_ref, staging_ref, _expiry, SessionAdmission,
           {:model_cleanup_custody, ^owner, ^generation, ^call, _candidate, ^proof}} ->
            send(owner, {:model_custody_prepared, self(), staging_ref, generation, call, proof})
            receive do: (:stop -> :ok)
        end
      end)

    on_exit(fn -> if Process.alive?(callback), do: Process.exit(callback, :kill) end)
    on_exit(fn -> if Process.alive?(candidate), do: Process.exit(candidate, :kill) end)
    state = ModelCensus.new(generation, cell)
    begin = {:begin_model, callback, call}

    state =
      ModelCensus.handle(
        state,
        {:loopex_session_admission, callback, make_ref(), generation, begin, deadline()}
      )

    start_proof =
      {:model_start_proof, start_ref, proxy, proxy_monitor, :normal, candidate,
       candidate_start_monitor}

    stage = {:stage_model, call, candidate, proof, stop_ref, start_proof}

    state =
      ModelCensus.handle(
        state,
        {:loopex_session_admission, callback, make_ref(), generation, stage, deadline()}
      )

    assert_receive {:model_custody_prepared, ^candidate, _, ^generation, ^call, ^proof} = custody
    state = ModelCensus.handle(state, custody)
    assert state.pending.stage_issued

    operation =
      {:cancel_model, call,
       {:registrar_not_entered, state.pending.stage_ref, candidate, candidate_start_monitor,
        :normal}}

    send(callback, {:send_cancel, generation, operation})
    assert_receive {:loopex_session_admission, ^callback, _, ^generation, ^operation, _} = request
    state = ModelCensus.handle(state, request)
    assert state.pending.phase == :cancelling

    callback_monitor = state.pending.callback_monitor
    send(callback, :stop)
    assert_receive {:DOWN, ^callback_monitor, :process, ^callback, :normal} = callback_down
    state = ModelCensus.handle(state, callback_down)
    assert state.pending.callback_down

    candidate_owner_monitor = state.pending.candidate_monitor
    send(candidate, :stop)
    assert_receive {:DOWN, ^candidate_start_monitor, :process, ^candidate, :normal}

    assert_receive {:DOWN, ^candidate_owner_monitor, :process, ^candidate, :normal} =
                     candidate_down

    state = ModelCensus.handle(state, candidate_down)
    assert state.pending == nil
    assert :atomics.get(cell, 1) == 0
    assert :atomics.get(cell, 2) == 0
  end

  test "missing candidate DOWN seals by the earlier cancellation expiry" do
    owner = self()

    {candidate, candidate_monitor} =
      spawn_monitor(fn ->
        receive do
          {:model_custody_prepare, _start_ref, staging_ref, _expiry, SessionAdmission,
           {:model_cleanup_custody, ^owner, generation, call, _candidate, proof}} ->
            send(owner, {:model_custody_prepared, self(), staging_ref, generation, call, proof})
            receive do: (:stop -> :ok)
        end
      end)

    on_exit(fn -> if Process.alive?(candidate), do: Process.exit(candidate, :kill) end)
    {state, cell, generation, call, proof} = direct_staging(candidate, candidate_monitor)
    assert_receive {:model_custody_prepared, ^candidate, _, ^generation, ^call, ^proof} = custody
    state = ModelCensus.handle(state, custody)

    assert_receive {:loopex_session_admission_result, ^owner, stage_ref, ^generation,
                    {:stage_model, ^call, ^candidate, ^proof, _, _}, _, {:ok, _}}

    operation =
      {:cancel_model, call,
       {:registrar_not_entered, stage_ref, candidate, candidate_monitor, :normal}}

    expiry = System.monotonic_time() + System.convert_time_unit(350, :millisecond, :native)

    state =
      ModelCensus.handle(
        state,
        {:loopex_session_admission, owner, make_ref(), generation, operation, expiry}
      )

    assert state.pending.phase == :cancelling
    assert {_, token} = state.pending.timer
    assert_receive {:model_census_lost_callback, ^token} = timeout, 650
    state = ModelCensus.handle(state, timeout)
    assert state.pending.phase == :unproved
    assert :atomics.get(cell, 1) == 3
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

  test "recorded resources require their genuine DOWN before retirement and slot release" do
    {state, cell, generation, call, proof, candidate} = direct_managed()
    root = spawn(fn -> receive do: (:stop -> :ok) end)
    on_exit(fn -> if Process.alive?(root), do: Process.exit(root, :kill) end)
    record = {:record_model_resources, call, candidate, 1, [{:process, :root, root}]}
    state = ModelCensus.handle(state, admission(candidate, generation, record))
    assert state.pending.phase == :active
    assert state.pending.revision == 1
    assert :atomics.get(cell, 2) == 1

    retire = {:retire_model, call, candidate, proof}
    state = ModelCensus.handle(state, admission(candidate, generation, retire))
    assert state.pending.phase == :retiring
    assert :atomics.get(cell, 2) == 1

    [{root_monitor, ^root}] = Map.to_list(state.pending.resource_monitors)
    send(root, :stop)
    assert_receive {:DOWN, ^root_monitor, :process, ^root, :normal} = root_down
    state = ModelCensus.handle(state, root_down)
    assert state.pending.phase == :retired_wait_down
    assert :atomics.get(cell, 1) == 0
    assert :atomics.get(cell, 2) == 1

    candidate_monitor = state.pending.candidate_monitor
    Process.exit(candidate, :kill)
    assert_receive {:DOWN, ^candidate_monitor, :process, ^candidate, :killed} = candidate_down
    state = ModelCensus.handle(state, candidate_down)
    assert state.pending == nil
    assert :atomics.get(cell, 2) == 0
  end

  test "managed candidate DOWN before its queued exact retirement is reconciled" do
    {state, cell, generation, call, proof, candidate} = direct_managed()
    retirement = admission(candidate, generation, {:retire_model, call, candidate, proof})
    candidate_monitor = state.pending.candidate_monitor
    Process.exit(candidate, :kill)
    assert_receive {:DOWN, ^candidate_monitor, :process, ^candidate, :killed} = down
    state = ModelCensus.handle(state, down)
    assert state.pending.phase == :managed
    assert state.pending.timer != nil
    assert :atomics.get(cell, 1) == 0
    assert :atomics.get(cell, 2) == 1

    state = ModelCensus.handle(state, retirement)
    assert state.pending == nil
    assert :atomics.get(cell, 1) == 0
    assert :atomics.get(cell, 2) == 0
  end

  test "retirement polls both exact tagged registries after recorded process DOWN" do
    {:ok, _started} = Application.ensure_all_started(:req)
    {state, cell, generation, call, proof, candidate} = direct_managed()
    root = spawn(fn -> receive do: (:stop -> :ok) end)
    on_exit(fn -> if Process.alive?(root), do: Process.exit(root, :kill) end)
    identity = {:http, "127.0.0.1", 11_434, make_ref()}
    {:ok, _} = Registry.register(Req.Finch, identity, :worker)
    {:ok, _} = Registry.register(Req.Finch.SupervisorRegistry, identity, :supervisor)

    entries = [
      {:process, :root, root},
      {:registry, :worker, identity},
      {:registry, :supervisor, identity}
    ]

    state =
      ModelCensus.handle(
        state,
        admission(candidate, generation, {:record_model_resources, call, candidate, 1, entries})
      )

    state =
      ModelCensus.handle(
        state,
        admission(candidate, generation, {:retire_model, call, candidate, proof})
      )

    [{root_monitor, ^root}] = Map.to_list(state.pending.resource_monitors)
    send(root, :stop)
    assert_receive {:DOWN, ^root_monitor, :process, ^root, :normal} = root_down
    state = ModelCensus.handle(state, root_down)
    assert state.pending.phase == :retiring
    assert :atomics.get(cell, 2) == 1

    Registry.unregister(Req.Finch, identity)
    Registry.unregister(Req.Finch.SupervisorRegistry, identity)
    {_timer, token} = state.pending.retirement_timer
    assert_receive {:model_census_retirement_check, ^token} = check, 100
    state = ModelCensus.handle(state, check)
    assert state.pending.phase == :retired_wait_down
    assert :atomics.get(cell, 1) == 0
  end

  test "a conflicting resource revision seals this session without changing a peer" do
    {state, cell, generation, call, _proof, candidate} = direct_managed()
    peer_cell = :atomics.new(2, [])
    root = spawn(fn -> receive do: (:stop -> :ok) end)
    caller = spawn(fn -> receive do: (:stop -> :ok) end)
    on_exit(fn -> if Process.alive?(root), do: Process.exit(root, :kill) end)
    on_exit(fn -> if Process.alive?(caller), do: Process.exit(caller, :kill) end)

    first = {:record_model_resources, call, candidate, 1, [{:process, :root, root}]}
    state = ModelCensus.handle(state, admission(candidate, generation, first))
    assert state.pending.revision == 1
    state = ModelCensus.handle(state, admission(candidate, generation, first))
    assert state.pending.revision == 1
    duplicate_as_new = {:record_model_resources, call, candidate, 2, [{:process, :root, root}]}
    state = ModelCensus.handle(state, admission(candidate, generation, duplicate_as_new))
    assert state.pending.revision == 1
    assert :atomics.get(cell, 1) == 0

    conflicting = {:record_model_resources, call, candidate, 1, [{:process, :caller, caller}]}
    state = ModelCensus.handle(state, admission(candidate, generation, conflicting))
    assert state.pending.phase == :unproved
    assert state.pending.revision == 1
    assert :atomics.get(cell, 1) == 3
    assert :atomics.get(cell, 2) == 1
    assert :atomics.get(peer_cell, 1) == 0
    assert :atomics.get(peer_cell, 2) == 0
  end

  defp direct_managed do
    owner = self()
    candidate = spawn(fn -> receive do: (:stop -> :ok) end)
    candidate_start_monitor = Process.monitor(candidate)
    on_exit(fn -> if Process.alive?(candidate), do: Process.exit(candidate, :kill) end)
    {state, cell, generation, call, proof} = direct_staging(candidate, candidate_start_monitor)
    stage_ref = state.pending.stage_ref

    state =
      ModelCensus.handle(
        state,
        {:model_custody_prepared, candidate, stage_ref, generation, call, proof}
      )

    assert_receive {:loopex_session_admission_result, ^owner, ^stage_ref, ^generation,
                    {:stage_model, ^call, ^candidate, ^proof, _, _}, _, {:ok, _}}

    register = {:register_model, call, candidate, proof}
    state = ModelCensus.handle(state, admission(owner, generation, register))
    assert state.pending.phase == :managed
    {state, cell, generation, call, proof, candidate}
  end

  defp admission(requester, generation, operation),
    do: {:loopex_session_admission, requester, make_ref(), generation, operation, deadline()}

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

  defp callback_loop(owner) do
    receive do
      {:send_cancel, generation, operation} ->
        send(
          owner,
          {:loopex_session_admission, self(), make_ref(), generation, operation, deadline()}
        )

        callback_loop(owner)

      :stop ->
        :ok

      _other ->
        callback_loop(owner)
    end
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
