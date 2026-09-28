defmodule Loopex.LLM.ReqLLM.InProcess.CleanupOwnerTest do
  use ExUnit.Case, async: false

  alias Loopex.LLM.ReqLLM.InProcess.CleanupOwner

  defmodule AdmissionProbe do
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

    send(callback, :stop)
    callback_mon = Process.monitor(callback)
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
