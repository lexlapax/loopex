defmodule Loopex.LLM.ReqLLM.InProcess.CleanupOwnerTest do
  use ExUnit.Case, async: false

  alias Loopex.LLM.ReqLLM.InProcess.CleanupOwner
  alias Loopex.LLM.ReqLLM.InProcess
  alias Loopex.LLM.ReqLLM.InProcess.Route
  alias Loopex.Model

  defmodule AdmissionProbe do
    def request(
          {__MODULE__, observer, generation, _cell},
          {:record_model_resources, call, candidate, revision, entries},
          deadline
        )
        when candidate == self() do
      send(observer, {:resources_recorded, candidate, call, revision, entries})

      {:ok,
       {:session_grant, generation, :record_model_resources, candidate, make_ref(), deadline}}
    end

    def request(
          {:model_cleanup_custody, owner, generation, call, candidate, proof},
          {:retire_model, call, candidate, proof},
          deadline
        )
        when candidate == self() do
      send(owner, {:empty_retirement_requested, candidate, call, proof})
      {:ok, {:session_grant, generation, :retire_model, candidate, make_ref(), deadline}}
    end

    def request(_, _, _), do: {:error, :session_admission_closed}
  end

  setup do
    {:ok, supervisor} = Task.Supervisor.start_link()

    on_exit(fn ->
      try do
        Supervisor.stop(supervisor)
      catch
        :exit, _ -> :ok
      end
    end)

    {:ok, supervisor: supervisor}
  end

  test "pool checkout timeout never exceeds the committed call deadline" do
    now = System.monotonic_time()
    milliseconds = &System.convert_time_unit(&1, :millisecond, :native)

    assert CleanupOwner.pool_timeout(now + milliseconds.(2_000), now) == 1_000
    assert CleanupOwner.pool_timeout(now + milliseconds.(250), now) == 250
    assert CleanupOwner.pool_timeout(now + milliseconds.(1) - 1, now) == 1
    assert CleanupOwner.pool_timeout(now, now) == 1
  end

  test "the actual Task.Supervisor child starts inert and reports exact identity", %{
    supervisor: supervisor
  } do
    start_ref = make_ref()
    proxy = proxy()
    deadline = future()
    {:ok, candidate} = start(supervisor, self(), proxy, start_ref, deadline)
    assert_receive {:model_candidate_ready, ^candidate, ^start_ref, ^proxy}
    refute_receive {:model_custody_prepared, _, _, _, _, _}, 20
    Process.exit(proxy, :kill)
    assert_down(candidate)
  end

  test "no custody ACK precedes exact normal proxy retirement", %{supervisor: supervisor} do
    start_ref = make_ref()
    proxy = proxy()
    {:ok, candidate} = start(supervisor, self(), proxy, start_ref, future())
    assert_receive {:model_candidate_ready, ^candidate, ^start_ref, ^proxy}
    staging_ref = make_ref()
    generation = make_ref()
    call_ref = make_ref()
    proof_ref = make_ref()

    send(candidate, {:proxy_retiring, self(), start_ref})
    send(candidate, custody(start_ref, staging_ref, generation, call_ref, candidate, proof_ref))
    refute_receive {:model_custody_prepared, _, _, _, _, _}, 20
    send(proxy, {:retire, candidate, start_ref})

    assert_receive {:model_custody_prepared, ^candidate, ^staging_ref, ^generation, ^call_ref,
                    ^proof_ref},
                   1_000

    send(candidate, custody(start_ref, staging_ref, generation, call_ref, candidate, proof_ref))
    refute_receive {:model_custody_prepared, _, _, _, _, _}, 20
    assert Process.alive?(candidate)
  end

  test "staged cleanup custody can be acknowledged after the model start deadline", %{
    supervisor: supervisor
  } do
    start_ref = make_ref()
    proxy = proxy()

    model_deadline =
      System.monotonic_time() + System.convert_time_unit(300, :millisecond, :native)

    {:ok, candidate} = start(supervisor, self(), proxy, start_ref, model_deadline)
    assert_receive {:model_candidate_ready, ^candidate, ^start_ref, ^proxy}
    candidate_monitor = Process.monitor(candidate)
    staging_ref = make_ref()
    generation = make_ref()
    call_ref = make_ref()
    proof_ref = make_ref()
    cleanup_deadline = future()

    send(
      candidate,
      {:model_custody_prepare, start_ref, staging_ref,
       System.monotonic_time() + System.convert_time_unit(2_000, :millisecond, :native),
       AdmissionProbe,
       {:model_cleanup_custody, self(), generation, call_ref, candidate, proof_ref}}
    )

    refute_receive {:model_custody_prepared, ^candidate, _, _, _, _}, 20

    send(
      candidate,
      {:model_custody_prepare, start_ref, staging_ref, cleanup_deadline, AdmissionProbe,
       {:model_cleanup_custody, self(), generation, call_ref, candidate, proof_ref}}
    )

    Process.sleep(
      max(
        System.convert_time_unit(model_deadline - System.monotonic_time(), :native, :millisecond) +
          10,
        0
      )
    )

    assert System.monotonic_time() > model_deadline
    assert Process.alive?(candidate)
    send(proxy, {:retire, candidate, start_ref})

    assert_receive {:model_custody_prepared, ^candidate, ^staging_ref, ^generation, ^call_ref,
                    ^proof_ref},
                   1_000

    Process.exit(candidate, :kill)
    assert_receive {:DOWN, ^candidate_monitor, :process, ^candidate, :killed}, 1_000
  end

  test "wrong candidate identity cannot acquire custody", %{supervisor: supervisor} do
    start_ref = make_ref()
    proxy = proxy()
    {:ok, candidate} = start(supervisor, self(), proxy, start_ref, future())
    assert_receive {:model_candidate_ready, ^candidate, ^start_ref, ^proxy}
    send(proxy, {:retire, candidate, start_ref})
    send(candidate, custody(start_ref, make_ref(), make_ref(), make_ref(), self(), make_ref()))
    refute_receive {:model_custody_prepared, _, _, _, _, _}, 50
  end

  test "registration pending waits for custody ACK and accepts one exact stop reference", %{
    supervisor: supervisor
  } do
    start_ref = make_ref()
    proxy = proxy()
    {:ok, candidate} = start(supervisor, self(), proxy, start_ref, future())
    assert_receive {:model_candidate_ready, ^candidate, ^start_ref, ^proxy}
    premature = make_ref()
    send(candidate, {:registration_pending, self(), premature})
    refute_receive {:registration_pending_ack, _, _, _}, 20

    staging_ref = make_ref()
    generation = make_ref()
    call_ref = make_ref()
    proof_ref = make_ref()
    send(candidate, custody(start_ref, staging_ref, generation, call_ref, candidate, proof_ref))
    send(candidate, {:registration_pending, self(), premature})
    refute_receive {:registration_pending_ack, _, _, _}, 20
    send(proxy, {:retire, candidate, start_ref})

    assert_receive {:model_custody_prepared, ^candidate, ^staging_ref, ^generation, ^call_ref,
                    ^proof_ref},
                   1_000

    stop_ref = make_ref()
    send(candidate, {:registration_pending, self(), stop_ref})
    assert_receive {:registration_pending_ack, ^candidate, ^start_ref, ^stop_ref}, 1_000
    send(candidate, {:registration_pending, self(), stop_ref})
    send(candidate, {:registration_pending, self(), make_ref()})
    send(candidate, {:registration_pending, proxy, make_ref()})
    refute_receive {:registration_pending_ack, _, _, _}, 20
  end

  test "normal proxy DOWN without its prior retirement notice ends the candidate", %{
    supervisor: supervisor
  } do
    start_ref = make_ref()
    proxy = proxy()
    {:ok, candidate} = start(supervisor, self(), proxy, start_ref, future())
    assert_receive {:model_candidate_ready, ^candidate, ^start_ref, ^proxy}
    send(proxy, :stop)
    assert_down(candidate)
    refute_receive {:model_custody_prepared, _, _, _, _, _}, 20
  end

  test "callback loss after custody records empty retirement before candidate DOWN", %{
    supervisor: supervisor
  } do
    observer = self()

    callback =
      spawn(fn ->
        receive do
          {:model_candidate_ready, candidate, start_ref, proxy} ->
            send(observer, {:ready, candidate, start_ref, proxy})

            receive do
              :stop -> :ok
            end
        end
      end)

    proxy = proxy()
    start_ref = make_ref()
    {:ok, candidate} = start(supervisor, callback, proxy, start_ref, future())
    assert_receive {:ready, ^candidate, ^start_ref, ^proxy}
    send(proxy, {:retire, candidate, start_ref})
    staging_ref = make_ref()
    generation = make_ref()
    call_ref = make_ref()
    proof_ref = make_ref()
    send(candidate, custody(start_ref, staging_ref, generation, call_ref, candidate, proof_ref))

    assert_receive {:model_custody_prepared, ^candidate, ^staging_ref, ^generation, ^call_ref,
                    ^proof_ref},
                   1_000

    callback_mon = Process.monitor(callback)
    send(callback, :stop)
    assert_receive {:DOWN, ^callback_mon, :process, ^callback, :normal}, 1_000
    assert_receive {:empty_retirement_requested, ^candidate, ^call_ref, ^proof_ref}, 1_000
    assert_down(candidate)
  end

  test "callback loss after custody delivery but before custody ACK still retires", %{
    supervisor: supervisor
  } do
    observer = self()

    callback =
      spawn(fn ->
        receive do
          {:model_candidate_ready, candidate, start_ref, proxy} ->
            send(observer, {:ready, candidate, start_ref, proxy})
            receive do: (:stop -> :ok)
        end
      end)

    proxy = proxy()
    start_ref = make_ref()
    {:ok, candidate} = start(supervisor, callback, proxy, start_ref, future())
    assert_receive {:ready, ^candidate, ^start_ref, ^proxy}

    staging_ref = make_ref()
    generation = make_ref()
    call_ref = make_ref()
    proof_ref = make_ref()

    send(candidate, custody(start_ref, staging_ref, generation, call_ref, candidate, proof_ref))
    refute_receive {:model_custody_prepared, ^candidate, _, _, _, _}, 20

    callback_monitor = Process.monitor(callback)
    send(callback, :stop)
    assert_receive {:DOWN, ^callback_monitor, :process, ^callback, :normal}, 1_000
    assert_receive {:empty_retirement_requested, ^candidate, ^call_ref, ^proof_ref}, 1_000
    assert_down(candidate)
    refute_receive {:model_custody_prepared, ^candidate, _, _, _, _}, 20
    send(proxy, :stop)
  end

  test "registered callback loss retires empty census yet holds until exact core stop", %{
    supervisor: supervisor
  } do
    observer = self()

    callback =
      spawn(fn ->
        receive do
          {:model_candidate_ready, candidate, start_ref, proxy} ->
            send(observer, {:ready, candidate, start_ref, proxy})

            receive do
              {:registration_pending_ack, ^candidate, ^start_ref, stop_ref} ->
                send(observer, {:pending_acked, candidate, stop_ref})
                receive do: (:stop -> :ok)
            end
        end
      end)

    proxy = proxy()
    start_ref = make_ref()
    {:ok, candidate} = start(supervisor, callback, proxy, start_ref, future())
    candidate_monitor = Process.monitor(candidate)
    assert_receive {:ready, ^candidate, ^start_ref, ^proxy}
    send(proxy, {:retire, candidate, start_ref})
    generation = make_ref()
    call = make_ref()
    proof = make_ref()
    send(candidate, custody(start_ref, make_ref(), generation, call, candidate, proof))
    assert_receive {:model_custody_prepared, ^candidate, _, ^generation, ^call, ^proof}
    stop_ref = make_ref()
    send(candidate, {:registration_pending, callback, stop_ref})
    assert_receive {:pending_acked, ^candidate, ^stop_ref}
    send(callback, :stop)
    assert_receive {:empty_retirement_requested, ^candidate, ^call, ^proof}, 1_000
    assert Process.alive?(candidate)
    refute_receive {:DOWN, ^candidate_monitor, :process, ^candidate, _}, 30

    nonce = make_ref()
    cooperative_ms = System.monotonic_time(:millisecond) + 3_000

    send(
      candidate,
      {:loopex_provider_resource_stop, make_ref(), nonce, self(), cooperative_ms,
       cooperative_ms + 1_000}
    )

    refute_receive {:loopex_provider_resource_stopped, ^nonce, ^candidate}, 30
    assert Process.alive?(candidate)

    send(
      candidate,
      {:loopex_provider_resource_stop, stop_ref, nonce, self(), cooperative_ms,
       cooperative_ms + 1_000}
    )

    assert_receive {:loopex_provider_resource_stopped, ^nonce, ^candidate}, 1_000
    assert_receive {:DOWN, ^candidate_monitor, :process, ^candidate, :normal}, 1_000
  end

  test "only an exact empty retired invocation can be released", %{supervisor: supervisor} do
    observer = self()

    callback =
      spawn(fn ->
        receive do
          {:model_candidate_ready, candidate, start_ref, proxy} ->
            send(observer, {:ready, candidate, start_ref, proxy})

            receive do
              {:registration_pending_ack, ^candidate, ^start_ref, stop_ref} ->
                send(observer, {:pending_acked, candidate, stop_ref})
                receive do: (:stop -> :ok)
            end
        end
      end)

    proxy = proxy()
    start_ref = make_ref()
    {:ok, candidate} = start(supervisor, callback, proxy, start_ref, future())
    candidate_monitor = Process.monitor(candidate)
    assert_receive {:ready, ^candidate, ^start_ref, ^proxy}
    send(proxy, {:retire, candidate, start_ref})
    generation = make_ref()
    call = make_ref()
    proof = make_ref()
    send(candidate, custody(start_ref, make_ref(), generation, call, candidate, proof))
    assert_receive {:model_custody_prepared, ^candidate, _, ^generation, ^call, ^proof}
    stop_ref = make_ref()
    send(candidate, {:registration_pending, callback, stop_ref})
    assert_receive {:pending_acked, ^candidate, ^stop_ref}

    premature = make_ref()

    send(
      candidate,
      {:release_empty_invocation, generation, call, candidate, proof, premature, future()}
    )

    refute_receive {:empty_invocation_released, ^candidate, ^premature}, 25
    assert Process.alive?(candidate)

    send(callback, :stop)
    assert_receive {:empty_retirement_requested, ^candidate, ^call, ^proof}, 1_000

    for {bad_generation, bad_call, bad_candidate, bad_proof, deadline} <- [
          {make_ref(), call, candidate, proof, future()},
          {generation, make_ref(), candidate, proof, future()},
          {generation, call, self(), proof, future()},
          {generation, call, candidate, make_ref(), future()},
          {generation, call, candidate, proof, System.monotonic_time() - 1}
        ] do
      release_ref = make_ref()

      send(
        candidate,
        {:release_empty_invocation, bad_generation, bad_call, bad_candidate, bad_proof,
         release_ref, deadline}
      )

      refute_receive {:empty_invocation_released, ^candidate, ^release_ref}, 20
      assert Process.alive?(candidate)
    end

    release_ref = make_ref()

    send(
      candidate,
      {:release_empty_invocation, generation, call, candidate, proof, release_ref, future()}
    )

    assert_receive {:empty_invocation_released, ^candidate, ^release_ref}, 1_000
    assert_receive {:DOWN, ^candidate_monitor, :process, ^candidate, :normal}, 1_000
  end

  test "a wrong module or route cannot acknowledge custody", %{supervisor: supervisor} do
    start_ref = make_ref()
    proxy = proxy()
    {:ok, candidate} = start(supervisor, self(), proxy, start_ref, future())
    assert_receive {:model_candidate_ready, ^candidate, ^start_ref, ^proxy}
    send(proxy, {:retire, candidate, start_ref})

    staging_ref = make_ref()
    generation = make_ref()
    call_ref = make_ref()
    proof_ref = make_ref()

    bad_module =
      {:model_custody_prepare, start_ref, staging_ref, future(), Enum,
       {:model_cleanup_custody, self(), generation, call_ref, candidate, proof_ref}}

    send(candidate, bad_module)
    send(candidate, custody(start_ref, staging_ref, generation, call_ref, self(), proof_ref))
    refute_receive {:model_custody_prepared, _, _, _, _, _}, 20

    send(candidate, custody(start_ref, staging_ref, generation, call_ref, candidate, proof_ref))

    assert_receive {:model_custody_prepared, ^candidate, ^staging_ref, ^generation, ^call_ref,
                    ^proof_ref},
                   1_000
  end

  test "cleanup custody cannot request a work operation", %{supervisor: supervisor} do
    start_ref = make_ref()
    proxy = proxy()
    {:ok, candidate} = start(supervisor, self(), proxy, start_ref, future())
    assert_receive {:model_candidate_ready, ^candidate, ^start_ref, ^proxy}
    send(proxy, {:retire, candidate, start_ref})

    staging_ref = make_ref()
    generation = make_ref()
    call_ref = make_ref()
    proof_ref = make_ref()
    send(candidate, custody(start_ref, staging_ref, generation, call_ref, candidate, proof_ref))

    assert_receive {:model_custody_prepared, ^candidate, ^staging_ref, ^generation, ^call_ref,
                    ^proof_ref},
                   1_000

    send(candidate, {:begin, make_ref()})
    send(candidate, {:register_model, call_ref, candidate, proof_ref})
    refute_receive {:session_grant, _, _, _, _, _}, 20
    refute_receive {:empty_retirement_requested, _, _, _}, 20
    assert Process.alive?(candidate)
  end

  test "expired start and callback loss before custody never report success", %{
    supervisor: supervisor
  } do
    proxy = proxy()
    start_ref = make_ref()
    {:ok, expired} = start(supervisor, self(), proxy, start_ref, System.monotonic_time() - 1)
    refute_receive {:model_candidate_ready, ^expired, _, _}, 20
    assert_down(expired)

    callback =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    {:ok, candidate} = start(supervisor, callback, proxy, make_ref(), future())
    send(callback, :stop)
    assert_down(candidate)
  end

  test "active stop proves caller, tagged pool and retirement before core acknowledgement", %{
    supervisor: supervisor
  } do
    {:ok, _started} = Application.ensure_all_started(:req)
    start_ref = make_ref()
    proxy = proxy()
    {:ok, candidate} = start(supervisor, self(), proxy, start_ref, future())
    candidate_monitor = Process.monitor(candidate)
    assert_receive {:model_candidate_ready, ^candidate, ^start_ref, ^proxy}
    send(proxy, {:retire, candidate, start_ref})

    generation = make_ref()
    call = make_ref()
    proof = make_ref()
    stop_ref = make_ref()
    cell = :atomics.new(2, [])
    send(candidate, custody(start_ref, make_ref(), generation, call, candidate, proof))
    assert_receive {:model_custody_prepared, ^candidate, _, ^generation, ^call, ^proof}
    send(candidate, {:registration_pending, self(), stop_ref})
    assert_receive {:registration_pending_ack, ^candidate, ^start_ref, ^stop_ref}

    token = make_ref()
    prepare_ref = make_ref()
    deadline = System.monotonic_time() + System.convert_time_unit(4_000, :millisecond, :native)
    full_handle = {AdmissionProbe, self(), generation, cell}

    send(
      candidate,
      {:in_process_activation_prepare, self(), start_ref, prepare_ref, {:managed, self(), 5_000},
       token, proof, AdmissionProbe, full_handle, cell, deadline}
    )

    assert_receive {:in_process_activation_prepared, ^candidate, ^start_ref, ^prepare_ref}
    base = "http://127.0.0.1:11434"
    {:ok, fingerprint} = Route.fingerprint(:ollama, :ollama_chat_completions, base)
    grant = {:session_grant, generation, :register_model, self(), make_ref(), deadline}
    begin_ref = make_ref()

    send(
      candidate,
      {:in_process_activation_begin, self(), start_ref, begin_ref, token, grant, call, base,
       fingerprint, make_ref(), deadline}
    )

    assert_receive {:in_process_activation_begun, ^candidate, ^start_ref, ^begin_ref}

    assert_receive {:in_process_caller_input_ready, ^candidate, ^call, caller, _input_ref, tag},
                   2_000

    assert is_pid(caller) and Process.alive?(caller)
    assert is_reference(tag)
    assert_received {:resources_recorded, ^candidate, ^call, 1, [{:process, :root, root}]}
    assert is_pid(root)
    assert_received {:resources_recorded, ^candidate, ^call, 6, [{:process, :caller, ^caller}]}

    release_ref = make_ref()

    send(
      candidate,
      {:release_empty_invocation, generation, call, candidate, proof, release_ref, future()}
    )

    refute_receive {:empty_invocation_released, ^candidate, ^release_ref}, 25
    assert Process.alive?(caller)

    nonce = make_ref()
    cooperative_ms = System.monotonic_time(:millisecond) + 4_000

    send(
      candidate,
      {:loopex_provider_resource_stop, stop_ref, nonce, self(), cooperative_ms,
       cooperative_ms + 1_000}
    )

    assert_receive {:empty_retirement_requested, ^candidate, ^call, ^proof}, 2_000
    assert_receive {:loopex_provider_resource_stopped, ^nonce, ^candidate}, 2_000
    assert_receive {:DOWN, ^candidate_monitor, :process, ^candidate, :normal}, 2_000
    refute Process.alive?(caller)
    refute Process.alive?(root)
    refute_receive {:in_process_model_result, ^candidate, _, _, _}, 20
  end

  test "a retired activated invocation cannot be released as empty", %{supervisor: supervisor} do
    {:ok, _started} = Application.ensure_all_started(:req)
    observer = self()
    callback = spawn(fn -> forward_callback(observer) end)
    start_ref = make_ref()
    proxy = proxy()
    {:ok, candidate} = start(supervisor, callback, proxy, start_ref, future())
    candidate_monitor = Process.monitor(candidate)

    assert_receive {:callback, ^callback,
                    {:model_candidate_ready, ^candidate, ^start_ref, ^proxy}}

    send(proxy, {:retire, candidate, start_ref})

    generation = make_ref()
    call = make_ref()
    proof = make_ref()
    stop_ref = make_ref()
    cell = :atomics.new(2, [])
    send(candidate, custody(start_ref, make_ref(), generation, call, candidate, proof))
    assert_receive {:model_custody_prepared, ^candidate, _, ^generation, ^call, ^proof}
    send(candidate, {:registration_pending, callback, stop_ref})

    assert_receive {:callback, ^callback,
                    {:registration_pending_ack, ^candidate, ^start_ref, ^stop_ref}}

    token = make_ref()
    prepare_ref = make_ref()
    deadline = System.monotonic_time() + System.convert_time_unit(4_000, :millisecond, :native)
    full_handle = {AdmissionProbe, self(), generation, cell}

    send(
      candidate,
      {:in_process_activation_prepare, callback, start_ref, prepare_ref,
       {:managed, self(), 5_000}, token, proof, AdmissionProbe, full_handle, cell, deadline}
    )

    assert_receive {:callback, ^callback,
                    {:in_process_activation_prepared, ^candidate, ^start_ref, ^prepare_ref}}

    base = "http://127.0.0.1:11434"
    {:ok, fingerprint} = Route.fingerprint(:ollama, :ollama_chat_completions, base)
    grant = {:session_grant, generation, :register_model, callback, make_ref(), deadline}
    begin_ref = make_ref()

    send(
      candidate,
      {:in_process_activation_begin, callback, start_ref, begin_ref, token, grant, call, base,
       fingerprint, make_ref(), deadline}
    )

    assert_receive {:callback, ^callback,
                    {:in_process_activation_begun, ^candidate, ^start_ref, ^begin_ref}}

    assert_receive {:callback, ^callback,
                    {:in_process_caller_input_ready, ^candidate, ^call, caller, _, _}},
                   2_000

    assert_received {:resources_recorded, ^candidate, ^call, 1, [{:process, :root, root}]}
    assert_received {:resources_recorded, ^candidate, ^call, 6, [{:process, :caller, ^caller}]}
    send(callback, :stop)
    assert_receive {:empty_retirement_requested, ^candidate, ^call, ^proof}, 2_000

    release_ref = make_ref()

    send(
      candidate,
      {:release_empty_invocation, generation, call, candidate, proof, release_ref, future()}
    )

    refute_receive {:empty_invocation_released, ^candidate, ^release_ref}, 50
    assert Process.alive?(candidate)
    refute Process.alive?(caller)
    refute Process.alive?(root)

    nonce = make_ref()
    cooperative_ms = System.monotonic_time(:millisecond) + 1_000

    send(
      candidate,
      {:loopex_provider_resource_stop, stop_ref, nonce, self(), cooperative_ms,
       cooperative_ms + 1_000}
    )

    assert_receive {:loopex_provider_resource_stopped, ^nonce, ^candidate}, 1_000
    assert_receive {:DOWN, ^candidate_monitor, :process, ^candidate, :normal}, 1_000
  end

  test "a bad activation token cannot create the root or caller", %{supervisor: supervisor} do
    start_ref = make_ref()
    proxy = proxy()
    {:ok, candidate} = start(supervisor, self(), proxy, start_ref, future())
    assert_receive {:model_candidate_ready, ^candidate, ^start_ref, ^proxy}
    send(proxy, {:retire, candidate, start_ref})
    generation = make_ref()
    call = make_ref()
    proof = make_ref()
    stop_ref = make_ref()
    cell = :atomics.new(2, [])
    send(candidate, custody(start_ref, make_ref(), generation, call, candidate, proof))
    assert_receive {:model_custody_prepared, ^candidate, _, ^generation, ^call, ^proof}
    send(candidate, {:registration_pending, self(), stop_ref})
    assert_receive {:registration_pending_ack, ^candidate, ^start_ref, ^stop_ref}
    token = make_ref()
    deadline = System.monotonic_time() + System.convert_time_unit(1_000, :millisecond, :native)

    send(
      candidate,
      {:in_process_activation_prepare, self(), start_ref, make_ref(), {:managed, self(), 5_000},
       token, proof, AdmissionProbe, {AdmissionProbe, self(), generation, cell}, cell, deadline}
    )

    assert_receive {:in_process_activation_prepared, ^candidate, ^start_ref, _}
    base = "http://127.0.0.1:11434"
    {:ok, fingerprint} = Route.fingerprint(:ollama, :ollama_chat_completions, base)
    grant = {:session_grant, generation, :register_model, self(), make_ref(), deadline}

    send(
      candidate,
      {:in_process_activation_begin, self(), start_ref, make_ref(), make_ref(), grant, call, base,
       fingerprint, make_ref(), deadline}
    )

    refute_receive {:in_process_activation_begun, ^candidate, _, _}, 30
    refute_receive {:resources_recorded, ^candidate, _, _, _}, 30
  end

  test "a caller refusal before the adapter still proves pool teardown before its result", %{
    supervisor: supervisor
  } do
    previous_dotenv = Application.get_env(:req_llm, :load_dotenv, :not_set)
    Application.put_env(:req_llm, :load_dotenv, false)
    {:ok, _started} = Application.ensure_all_started(:req_llm)

    on_exit(fn ->
      if previous_dotenv == :not_set,
        do: Application.delete_env(:req_llm, :load_dotenv),
        else: Application.put_env(:req_llm, :load_dotenv, previous_dotenv)
    end)

    start_ref = make_ref()
    proxy = proxy()
    {:ok, candidate} = start(supervisor, self(), proxy, start_ref, future())
    candidate_monitor = Process.monitor(candidate)
    assert_receive {:model_candidate_ready, ^candidate, ^start_ref, ^proxy}
    send(proxy, {:retire, candidate, start_ref})
    generation = make_ref()
    call = make_ref()
    proof = make_ref()
    stop_ref = make_ref()
    cell = :atomics.new(2, [])
    send(candidate, custody(start_ref, make_ref(), generation, call, candidate, proof))
    assert_receive {:model_custody_prepared, ^candidate, _, ^generation, ^call, ^proof}
    send(candidate, {:registration_pending, self(), stop_ref})
    assert_receive {:registration_pending_ack, ^candidate, ^start_ref, ^stop_ref}
    token = make_ref()
    deadline = System.monotonic_time() + System.convert_time_unit(4_000, :millisecond, :native)

    send(
      candidate,
      {:in_process_activation_prepare, self(), start_ref, make_ref(), {:managed, self(), 5_000},
       token, proof, AdmissionProbe, {AdmissionProbe, self(), generation, cell}, cell, deadline}
    )

    assert_receive {:in_process_activation_prepared, ^candidate, ^start_ref, _}
    base = "http://127.0.0.1:11434"
    {:ok, fingerprint} = Route.fingerprint(:ollama, :ollama_chat_completions, base)
    grant = {:session_grant, generation, :register_model, self(), make_ref(), deadline}

    send(
      candidate,
      {:in_process_activation_begin, self(), start_ref, make_ref(), token, grant, call, base,
       fingerprint, :invalid, deadline}
    )

    assert_receive {:in_process_activation_begun, ^candidate, ^start_ref, _}

    assert_receive {:in_process_caller_input_ready, ^candidate, ^call, caller, input_ref, _tag},
                   2_000

    {:ok, request} =
      Model.request("ollama:small", [%{"role" => "user", "content" => "hello"}],
        sampling: %{"max_tokens" => 16},
        deadline: System.system_time(:millisecond) + 10_000
      )

    {:ok, prepared} = InProcess.preflight(request, base)
    send(caller, {:in_process_caller_input, self(), call, input_ref, prepared})

    assert_receive {:in_process_model_result, ^candidate, ^start_ref, ^call,
                    {:error, {:not_dispatched, "model_call_failed"}}},
                   2_000

    refute Process.alive?(caller)
    nonce = make_ref()
    cooperative_ms = System.monotonic_time(:millisecond) + 4_000

    send(
      candidate,
      {:loopex_provider_resource_stop, stop_ref, nonce, self(), cooperative_ms,
       cooperative_ms + 1_000}
    )

    assert_receive {:empty_retirement_requested, ^candidate, ^call, ^proof}, 2_000
    assert_receive {:loopex_provider_resource_stopped, ^nonce, ^candidate}, 2_000
    assert_receive {:DOWN, ^candidate_monitor, :process, ^candidate, :normal}, 2_000
  end

  defp start(supervisor, callback, proxy, start_ref, deadline) do
    Task.Supervisor.start_child(supervisor, fn ->
      CleanupOwner.run(%{
        callback: callback,
        proxy: proxy,
        start_ref: start_ref,
        deadline: deadline
      })
    end)
  end

  defp proxy do
    spawn(fn ->
      receive do
        {:retire, candidate, start_ref} -> send(candidate, {:proxy_retiring, self(), start_ref})
        :stop -> :ok
      end
    end)
  end

  defp forward_callback(observer) do
    receive do
      :stop ->
        :ok

      message ->
        send(observer, {:callback, self(), message})
        forward_callback(observer)
    end
  end

  defp custody(start_ref, staging_ref, generation, call_ref, candidate, proof_ref) do
    {:model_custody_prepare, start_ref, staging_ref, future(), AdmissionProbe,
     {:model_cleanup_custody, self(), generation, call_ref, candidate, proof_ref}}
  end

  defp future do
    System.monotonic_time() + System.convert_time_unit(1_000, :millisecond, :native)
  end

  defp assert_down(pid) do
    monitor = Process.monitor(pid)
    assert_receive {:DOWN, ^monitor, :process, ^pid, _}, 1_000
  end
end
