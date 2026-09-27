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
                  :stop -> :ok
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

  defp future, do: System.monotonic_time() + System.convert_time_unit(2, :second, :native)
end
