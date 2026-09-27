defmodule LoopexComposition.SessionAdmissionTest do
  @moduledoc false
  use ExUnit.Case, async: true
  alias LoopexComposition.SessionAdmission

  test "the same implementation conforms to both inward callback contracts" do
    {:module, SessionAdmission} = Code.ensure_loaded(SessionAdmission)

    for behaviour <- [
          Loopex.LLM.ReqLLM.InProcess.Admission,
          Loopex.Executor.Local.EphemeralAdmission
        ] do
      assert behaviour.behaviour_info(:callbacks) == [request: 3]
      assert function_exported?(SessionAdmission, :request, 3)
      {owner, monitor} = responder(:grant)
      handle = SessionAdmission.handle(owner, make_ref(), :atomics.new(2, []))

      operation =
        case behaviour do
          Loopex.LLM.ReqLLM.InProcess.Admission ->
            {:begin_model, self(), make_ref()}

          Loopex.Executor.Local.EphemeralAdmission ->
            {:tool_grant, self(), make_ref(), make_ref()}
        end

      assert {:ok, _} = behaviour.request(SessionAdmission, handle, operation, future())
      assert_receive {:DOWN, ^monitor, :process, ^owner, :normal}
    end
  end

  test "one monitored request preserves the exact operation and correlation" do
    {owner, monitor} = responder(:grant)
    generation = make_ref()
    handle = SessionAdmission.handle(owner, generation, :atomics.new(2, []))
    operation = {:begin_model, self(), make_ref()}
    deadline = future()

    assert {:ok, {:session_grant, ^generation, :begin_model, requester, reference, ^deadline}} =
             SessionAdmission.request(handle, operation, deadline)

    assert requester == self()
    assert_receive {:observed, ^owner, ^requester, ^reference, ^generation, ^operation, ^deadline}
    assert_receive {:DOWN, ^monitor, :process, ^owner, :normal}
    refute_receive {:DOWN, _, :process, ^owner, _}
  end

  test "forged correlation is ignored until the actual matching response" do
    {owner, monitor} = responder(:forged_then_grant)
    generation = make_ref()
    operation = {:tool_grant, self(), make_ref(), make_ref()}
    handle = SessionAdmission.handle(owner, generation, :atomics.new(2, []))
    deadline = future()

    assert {:ok, {:session_grant, ^generation, :tool_grant, _, _, ^deadline}} =
             SessionAdmission.request(handle, operation, deadline)

    assert_receive {:DOWN, ^monitor, :process, ^owner, :normal}
  end

  test "matching malformed and mismatched grants are fixed refusals" do
    for mode <- [
          :wrong_generation,
          :wrong_reference,
          :wrong_requester,
          :wrong_tag,
          :wrong_expiry,
          :malformed,
          :host_refusal
        ] do
      {owner, monitor} = responder(mode)
      handle = SessionAdmission.handle(owner, make_ref(), :atomics.new(2, []))

      assert {:error, :session_admission_closed} =
               SessionAdmission.request(handle, {:begin_model, self(), make_ref()}, future())

      assert_receive {:DOWN, ^monitor, :process, ^owner, :normal}
    end
  end

  test "expired dequeue and genuine owner death cannot produce a grant" do
    {owner, monitor} = responder(:die)
    handle = SessionAdmission.handle(owner, make_ref(), :atomics.new(2, []))

    assert {:error, :session_admission_closed} =
             SessionAdmission.request(handle, {:begin_model, self(), make_ref()}, future())

    assert_receive {:DOWN, ^monitor, :process, ^owner, :normal}

    {owner, monitor} = responder(:grant)
    handle = SessionAdmission.handle(owner, make_ref(), :atomics.new(2, []))

    assert {:error, :session_admission_closed} =
             SessionAdmission.request(
               handle,
               {:begin_model, self(), make_ref()},
               System.monotonic_time() - 1
             )

    refute_receive {:observed, ^owner, _, _, _, _, _}
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^owner, :killed}
  end

  test "one expiry bounds a silent live owner and does not leak its monitor" do
    {owner, monitor} = responder(:silent)
    handle = SessionAdmission.handle(owner, make_ref(), :atomics.new(2, []))
    deadline = System.monotonic_time() + System.convert_time_unit(20, :millisecond, :native)

    assert {:error, :session_admission_closed} =
             SessionAdmission.request(handle, {:begin_model, self(), make_ref()}, deadline)

    assert System.monotonic_time() >= deadline
    assert Process.alive?(owner)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^owner, :killed}
    refute_receive {:DOWN, _, :process, ^owner, _}
  end

  test "a long enclosing deadline still gives admission only one second" do
    {owner, owner_monitor} = responder(:silent)
    generation = make_ref()
    handle = SessionAdmission.handle(owner, generation, :atomics.new(2, []))
    test = self()
    deadline = System.monotonic_time() + System.convert_time_unit(60, :second, :native)

    borrower =
      start_supervised!(
        {Task,
         fn ->
           result = SessionAdmission.request(handle, {:begin_model, self(), make_ref()}, deadline)
           send(test, {:request_result, self(), result})
         end}
      )

    borrower_monitor = Process.monitor(borrower)

    assert_receive {:observed, ^owner, ^borrower, _reference, ^generation, _operation, expiry},
                   1_000

    assert expiry < deadline
    assert expiry <= System.monotonic_time() + System.convert_time_unit(1, :second, :native)
    assert_receive {:request_result, ^borrower, {:error, :session_admission_closed}}, 2_000
    assert_receive {:DOWN, ^borrower_monitor, :process, ^borrower, :normal}
    assert Process.alive?(owner)
    send(owner, :late_grant)
    assert_receive {:DOWN, ^owner_monitor, :process, ^owner, :normal}
    refute_receive {:request_result, ^borrower, _}
  end

  test "cleanup custody admits only its candidate's matching retirement and cancellation" do
    for type <- [:retire_model, :cancel_model] do
      {owner, monitor} = responder(:grant)
      generation = make_ref()
      call = make_ref()
      proof = make_ref()
      custody = {:model_cleanup_custody, owner, generation, call, self(), proof}

      operation =
        case type do
          :retire_model -> {:retire_model, call, self(), proof}
          :cancel_model -> {:cancel_model, call, :start_proof}
        end

      assert {:ok, {:session_grant, ^generation, ^type, _, _, _}} =
               SessionAdmission.request(custody, operation, future())

      assert_receive {:DOWN, ^monitor, :process, ^owner, :normal}
    end

    {owner, monitor} = responder(:grant)
    call = make_ref()
    proof = make_ref()
    custody = {:model_cleanup_custody, owner, make_ref(), call, self(), proof}

    for operation <- [
          {:begin_model, self(), call},
          {:register_model, call, self(), proof},
          {:record_model_resources, call, self(), 1, []},
          {:retire_model, make_ref(), self(), proof},
          {:retire_model, call, self(), make_ref()}
        ] do
      assert {:error, :session_admission_closed} =
               SessionAdmission.request(custody, operation, future())
    end

    refute_receive {:observed, ^owner, _, _, _, _, _}
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^owner, :killed}
  end

  test "an exact registrar refusal reaps the existing candidate monitor before returning its final grant" do
    for order <- [:down_first, :final_first] do
      test = self()

      {candidate, candidate_monitor} =
        spawn_monitor(fn ->
          receive do
            :unexpected -> send(test, :candidate_survived)
          end
        end)

      generation = make_ref()
      call = make_ref()

      operation =
        {:cancel_model, call, {:registration_refused, :unmanaged, candidate, candidate_monitor}}

      {owner, owner_monitor} =
        spawn_monitor(fn ->
          receive do
            {:loopex_session_admission, requester, reference, ^generation, ^operation, expiry} ->
              send(
                requester,
                {:loopex_session_admission_cancellation_prepared, self(), reference, generation,
                 operation, expiry, candidate}
              )

              token = {:session_grant, generation, :cancel_model, requester, reference, expiry}

              result =
                {:loopex_session_admission_result, self(), reference, generation, operation,
                 expiry, {:ok, token}}

              if order == :final_first, do: send(requester, result)

              monitor = Process.monitor(candidate)

              receive do
                {:DOWN, ^monitor, :process, ^candidate, _} ->
                  send(test, {:candidate_reaped, order})
              end

              if order == :down_first, do: send(requester, result)
              receive do: (:stop -> :ok)
          end
        end)

      handle = SessionAdmission.handle(owner, generation, :atomics.new(2, []))

      assert {:ok, {:session_grant, ^generation, :cancel_model, _, _, _}} =
               SessionAdmission.request(handle, operation, future())

      assert_receive {:candidate_reaped, ^order}
      send(owner, :stop)
      assert_receive {:DOWN, ^owner_monitor, :process, ^owner, :normal}
      refute_receive :candidate_survived
    end
  end

  test "a lost or mismatched preparation leaves the candidate to its owning callback" do
    for mode <- [:lost, :wrong_candidate] do
      test = self()
      unrelated = spawn(fn -> receive do: (:stop -> :ok) end)
      on_exit(fn -> if Process.alive?(unrelated), do: Process.exit(unrelated, :kill) end)

      {candidate, candidate_monitor} =
        spawn_monitor(fn -> receive do: (:stop -> :ok) end)

      generation = make_ref()
      call = make_ref()

      operation =
        {:cancel_model, call, {:registration_refused, :unmanaged, candidate, candidate_monitor}}

      {owner, owner_monitor} =
        spawn_monitor(fn ->
          receive do
            {:loopex_session_admission, requester, reference, ^generation, ^operation, expiry} ->
              if mode == :wrong_candidate do
                send(
                  requester,
                  {:loopex_session_admission_cancellation_prepared, self(), reference, generation,
                   operation, expiry, unrelated}
                )
              end

              monitor = Process.monitor(candidate)

              receive do
                {:DOWN, ^monitor, :process, ^candidate, _} ->
                  send(test, {:candidate_reaped_without_preparation, mode})
              end

              token = {:session_grant, generation, :cancel_model, requester, reference, expiry}

              send(
                requester,
                {:loopex_session_admission_result, self(), reference, generation, operation,
                 expiry, {:ok, token}}
              )
          end
        end)

      handle = SessionAdmission.handle(owner, generation, :atomics.new(2, []))

      assert {:error, :session_admission_closed} =
               SessionAdmission.request(handle, operation, future())

      assert Process.alive?(candidate)
      assert Process.alive?(unrelated)
      Process.exit(candidate, :kill)
      assert_receive {:DOWN, ^candidate_monitor, :process, ^candidate, :killed}
      assert_receive {:candidate_reaped_without_preparation, ^mode}
      assert_receive {:DOWN, ^owner_monitor, :process, ^owner, :normal}
      send(unrelated, :stop)
    end
  end

  test "owner death after final grant but before candidate DOWN cannot grant clean cancellation" do
    {candidate, candidate_monitor} = spawn_monitor(fn -> receive do: (:stop -> :ok) end)
    generation = make_ref()
    call = make_ref()

    operation =
      {:cancel_model, call, {:registration_refused, :unmanaged, candidate, candidate_monitor}}

    {owner, owner_monitor} =
      spawn_monitor(fn ->
        receive do
          {:loopex_session_admission, requester, reference, ^generation, ^operation, expiry} ->
            send(
              requester,
              {:loopex_session_admission_cancellation_prepared, self(), reference, generation,
               operation, expiry, candidate}
            )

            token = {:session_grant, generation, :cancel_model, requester, reference, expiry}

            send(
              requester,
              {:loopex_session_admission_result, self(), reference, generation, operation, expiry,
               {:ok, token}}
            )
        end
      end)

    handle = SessionAdmission.handle(owner, generation, :atomics.new(2, []))

    assert {:error, :session_admission_closed} =
             SessionAdmission.request(handle, operation, future())

    refute Process.alive?(candidate)
    assert_receive {:DOWN, ^owner_monitor, :process, ^owner, :normal}
  end

  test "duplicate preparation and a final acknowledgement without candidate DOWN never substitute for proof" do
    candidate = spawn(fn -> receive do: (:stop -> :ok) end)
    on_exit(fn -> if Process.alive?(candidate), do: Process.exit(candidate, :kill) end)
    fake_monitor = make_ref()
    generation = make_ref()
    call = make_ref()

    operation =
      {:cancel_model, call, {:registration_refused, :unmanaged, candidate, fake_monitor}}

    {owner, owner_monitor} =
      spawn_monitor(fn ->
        receive do
          {:loopex_session_admission, requester, reference, ^generation, ^operation, expiry} ->
            prepared =
              {:loopex_session_admission_cancellation_prepared, self(), reference, generation,
               operation, expiry, candidate}

            send(requester, prepared)
            send(requester, prepared)
            token = {:session_grant, generation, :cancel_model, requester, reference, expiry}

            send(
              requester,
              {:loopex_session_admission_result, self(), reference, generation, operation, expiry,
               {:ok, token}}
            )
        end
      end)

    handle = SessionAdmission.handle(owner, generation, :atomics.new(2, []))
    short = System.monotonic_time() + System.convert_time_unit(50, :millisecond, :native)

    assert {:error, :session_admission_closed} =
             SessionAdmission.request(handle, operation, short)

    assert System.monotonic_time() >= short
    refute Process.alive?(candidate)
    assert_receive {:DOWN, ^owner_monitor, :process, ^owner, :normal}
  end

  test "missing final acknowledgement remains conservative after a real candidate DOWN" do
    test = self()
    {candidate, candidate_monitor} = spawn_monitor(fn -> receive do: (:stop -> :ok) end)
    generation = make_ref()
    call = make_ref()

    operation =
      {:cancel_model, call, {:registration_refused, :unmanaged, candidate, candidate_monitor}}

    {owner, owner_monitor} =
      spawn_monitor(fn ->
        receive do
          {:loopex_session_admission, requester, reference, ^generation, ^operation, expiry} ->
            send(
              requester,
              {:loopex_session_admission_cancellation_prepared, self(), reference, generation,
               operation, expiry, candidate}
            )

            monitor = Process.monitor(candidate)

            receive do
              {:DOWN, ^monitor, :process, ^candidate, _} -> send(test, :candidate_gone)
            end

            receive do: (:stop -> :ok)
        end
      end)

    handle = SessionAdmission.handle(owner, generation, :atomics.new(2, []))
    short = System.monotonic_time() + System.convert_time_unit(50, :millisecond, :native)

    assert {:error, :session_admission_closed} =
             SessionAdmission.request(handle, operation, short)

    assert System.monotonic_time() >= short
    assert_receive :candidate_gone
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^owner_monitor, :process, ^owner, :killed}
  end

  test "a malformed final acknowledgement cannot be repaired by a duplicate grant" do
    {candidate, candidate_monitor} = spawn_monitor(fn -> receive do: (:stop -> :ok) end)
    generation = make_ref()
    call = make_ref()

    operation =
      {:cancel_model, call, {:registration_refused, :unmanaged, candidate, candidate_monitor}}

    {owner, owner_monitor} =
      spawn_monitor(fn ->
        receive do
          {:loopex_session_admission, requester, reference, ^generation, ^operation, expiry} ->
            send(
              requester,
              {:loopex_session_admission_result, self(), reference, generation, operation, expiry,
               {:ok, :malformed}}
            )

            token = {:session_grant, generation, :cancel_model, requester, reference, expiry}

            send(
              requester,
              {:loopex_session_admission_result, self(), reference, generation, operation, expiry,
               {:ok, token}}
            )

            send(
              requester,
              {:loopex_session_admission_cancellation_prepared, self(), reference, generation,
               operation, expiry, candidate}
            )
        end
      end)

    handle = SessionAdmission.handle(owner, generation, :atomics.new(2, []))

    assert {:error, :session_admission_closed} =
             SessionAdmission.request(handle, operation, future())

    assert_receive {:DOWN, ^owner_monitor, :process, ^owner, :normal}
  end

  test "a matching grant queued after expiry is refused by a still-live requester" do
    {owner, owner_monitor} = responder(:silent)
    generation = make_ref()
    handle = SessionAdmission.handle(owner, generation, :atomics.new(2, []))
    test = self()

    {borrower, borrower_monitor} =
      spawn_monitor(fn ->
        deadline = System.monotonic_time() + System.convert_time_unit(100, :millisecond, :native)
        result = SessionAdmission.request(handle, {:begin_model, self(), make_ref()}, deadline)
        send(test, {:queued_grant_result, self(), result})

        receive do
          :stop -> :ok
        end
      end)

    on_exit(fn ->
      if Process.alive?(borrower), do: Process.exit(borrower, :kill)
    end)

    assert_receive {:observed, ^owner, ^borrower, reference, ^generation, operation, expiry}
    assert :erlang.suspend_process(borrower)
    wait_until(expiry)
    send(owner, :late_grant)
    assert_receive {:DOWN, ^owner_monitor, :process, ^owner, :normal}
    token = {:session_grant, generation, :begin_model, borrower, reference, expiry}

    assert {:messages, messages} = Process.info(borrower, :messages)

    assert {:loopex_session_admission_result, owner, reference, generation, operation, expiry,
            {:ok, token}} in messages

    assert Process.alive?(borrower)
    assert :erlang.resume_process(borrower)
    assert_receive {:queued_grant_result, ^borrower, {:error, :session_admission_closed}}
    assert Process.alive?(borrower)
    refute_receive {:queued_grant_result, ^borrower, _}
    send(borrower, :stop)
    assert_receive {:DOWN, ^borrower_monitor, :process, ^borrower, :normal}
  end

  defp wait_until(deadline) do
    if System.monotonic_time() < deadline do
      Process.sleep(1)
      wait_until(deadline)
    end
  end

  defp responder(mode) do
    test = self()

    {pid, monitor} =
      spawn_monitor(fn ->
        receive do
          {:loopex_session_admission, requester, reference, generation, operation, deadline} ->
            send(test, {:observed, self(), requester, reference, generation, operation, deadline})

            if mode == :forged_then_grant do
              send(
                requester,
                {:loopex_session_admission_result, self(), make_ref(), generation, operation,
                 deadline, :ok}
              )
            end

            token =
              {:session_grant, generation, elem(operation, 0), requester, reference, deadline}

            result =
              case mode do
                :wrong_generation -> {:ok, put_elem(token, 1, make_ref())}
                :wrong_reference -> {:ok, put_elem(token, 4, make_ref())}
                :wrong_requester -> {:ok, put_elem(token, 3, self())}
                :wrong_tag -> {:ok, put_elem(token, 2, :other)}
                :wrong_expiry -> {:ok, put_elem(token, 5, deadline + 1)}
                :malformed -> {:ok, "private"}
                :host_refusal -> {:error, "private"}
                _ -> {:ok, token}
              end

            case mode do
              :die ->
                :ok

              :silent ->
                receive do
                  :stop ->
                    :ok

                  :late_grant ->
                    send(
                      requester,
                      {:loopex_session_admission_result, self(), reference, generation, operation,
                       deadline, result}
                    )
                end

              _ ->
                send(
                  requester,
                  {:loopex_session_admission_result, self(), reference, generation, operation,
                   deadline, result}
                )
            end
        end
      end)

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :kill)
    end)

    {pid, monitor}
  end

  defp future, do: System.monotonic_time() + System.convert_time_unit(500, :millisecond, :native)
end
