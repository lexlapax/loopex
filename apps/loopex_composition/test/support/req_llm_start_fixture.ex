defmodule LoopexComposition.ReqLLMStartFixture do
  @moduledoc false
  import ExUnit.Assertions
  alias LoopexComposition.ReqLLMStarter, as: Starter

  @initializer {Starter, :initializer}
  @provenance {Starter, :provenance}

  def run(scenario) do
    Application.put_env(:req, :default_options, [])
    Application.put_env(:req_llm, :llm_db, untouched: true)
    Application.put_env(:req_llm, :warn_unverified_models, :untouched)
    {:ok, _} = Application.ensure_all_started(:logger)
    Logger.configure(level: :none)
    execute(scenario)
    assert System.get_env("LOOPEX_M6_START_CANARY") == nil
    assert Application.get_env(:req_llm, :llm_db) == [untouched: true]
    assert Application.get_env(:req_llm, :warn_unverified_models) == :untouched
    IO.puts("M6_REQ_LLM_START_OK #{inspect(scenario)}")
  end

  defp execute(:first_start) do
    Application.put_env(:req_llm, :load_dotenv, true)
    {_parent, service, _sentinel} = parent()
    trace_persistent_writes(true)
    assert :ok == request(service)
    startup_writes = persistent_writes()
    assert Enum.any?(startup_writes, &match?({:put, [@initializer, _]}, &1))
    assert Enum.any?(startup_writes, &match?({:put, [@provenance, _]}, &1))
    assert Enum.any?(startup_writes, &match?({:erase, [@initializer]}, &1))
    assert Application.get_env(:req_llm, :load_dotenv) == false
    assert {:started, pid, ref} = :persistent_term.get(@provenance)
    assert pid == Process.whereis(ReqLLM.Supervisor)
    assert is_reference(ref)
    assert :absent == :persistent_term.get(@initializer, :absent)
    before = :persistent_term.get(@provenance)
    Enum.each(1..3, fn _ -> assert :ok == request(service) end)
    assert persistent_writes() == []
    trace_persistent_writes(false)
    assert :persistent_term.get(@provenance) == before
    assert :sys.get_state(service).origin.pid == pid
    assert Process.alive?(pid)
  end

  defp execute(:host_state_table) do
    {_parent, service, _sentinel} = parent()
    assert {:error, :req_llm_host_declaration_invalid} == request(service, :host_started)
    assert :absent == :persistent_term.get(@initializer, :absent)
    assert :absent == :persistent_term.get(@provenance, :absent)
    Application.put_env(:req_llm, :load_dotenv, false, persistent: true)
    assert {:ok, _} = Application.ensure_all_started(:req_llm)
    assert {:error, :req_llm_already_started} == request(service)
    assert :ok == request(service, :host_started)
    assert :absent == :persistent_term.get(@provenance, :absent)
    assert :absent == :persistent_term.get(@initializer, :absent)
    Application.put_env(:req_llm, :load_dotenv, true)
    assert {:error, :req_llm_dotenv_enabled} == request(service, :host_started)
    assert Application.get_env(:req_llm, :load_dotenv) == true
  end

  defp execute(:provenance_restart) do
    {_parent, service, _sentinel} = parent()
    assert :ok == request(service)
    first = :persistent_term.get(@provenance)
    :ok = Application.stop(:req_llm)
    Application.put_env(:req_llm, :load_dotenv, true)
    assert {:error, :req_llm_dotenv_enabled} == request(service)
    assert :persistent_term.get(@provenance) == first
    Application.put_env(:req_llm, :load_dotenv, false, persistent: true)
    assert :ok == request(service)
    second = :persistent_term.get(@provenance)
    refute second == first
    :ok = Application.stop(:req_llm)
    assert {:ok, _} = Application.ensure_all_started(:req_llm)
    host_pid = Process.whereis(ReqLLM.Supervisor)
    refute host_pid == elem(second, 1)
    assert {:error, :req_llm_already_started} == request(service)
    assert :ok == request(service, :host_started)
    assert :persistent_term.get(@provenance) == second

    origin = :sys.get_state(service).origin
    assert is_nil(origin) or origin.pid == elem(second, 1)
  end

  defp execute(:guards) do
    {_parent, service, _sentinel} = parent()
    System.put_env("SSLKEYLOGFILE", "")
    Application.put_env(:req, :default_options, adapter: :forbidden)
    System.put_env("TIDEWAVE_REPL", "true")
    assert {:error, :ssl_key_log_enabled} == request(service)
    System.delete_env("SSLKEYLOGFILE")
    assert {:error, :req_default_options_unsupported} == request(service)
    Application.put_env(:req, :default_options, %{})
    assert {:error, :req_default_options_unsupported} == request(service)
    Application.put_env(:req, :default_options, [])
    assert {:error, :req_llm_tidewave_enabled} == request(service)
    assert Process.whereis(ReqLLM.Supervisor) == nil
    assert :absent == :persistent_term.get(@initializer, :absent)
    assert :absent == :persistent_term.get(@provenance, :absent)
    System.put_env("TIDEWAVE_REPL", "TRUE")
    assert :ok == request(service)
  end

  defp execute(:concurrent_cohorts) do
    {_parent, service, _sentinel} = parent()
    hold = hold_start()
    one = requester(service, nil, 5_000)
    held(hold)
    identity = :persistent_term.get(@initializer)
    two = requester(service, nil, 5_000)
    other = requester(service, :host_started, 5_000)

    wait_state(service, fn state ->
      length(state.operation.waiters) == 2 and length(state.queued) == 1
    end)

    assert :persistent_term.get(@initializer) == identity
    release(hold)
    assert :ok == result(one)
    assert :ok == result(two)
    assert :ok == result(other)
    assert {:started, _, ref} = :persistent_term.get(@provenance)
    assert ref == elem(identity, 2)
    assert :persistent_term.get(@initializer, :absent) == :absent
    refute_receive {:start_held, _, _, _}, 0

    # Reverse order pins declaration isolation before any successful startup.
    :ok = Application.stop(:req_llm)
    :persistent_term.erase(@provenance)
    :ok = :sys.suspend(:application_controller)
    declared = requester(service, :host_started, 5_000)

    wait_state(service, fn state ->
      not is_nil(state.operation) and state.operation.declaration == :host_started
    end)

    undeclared = requester(service, nil, 5_000)
    wait_state(service, &(length(&1.queued) == 1))
    :ok = :sys.resume(:application_controller)
    assert {:error, :req_llm_host_declaration_invalid} == result(declared)
    assert :ok == result(undeclared)
  end

  defp execute(:waiter_loss) do
    {_parent, service, _sentinel} = parent()
    hold = hold_start()
    expires = requester(service, nil, 80)
    held(hold)
    {:preparing, initializer, _} = :persistent_term.get(@initializer)
    monitor = Process.monitor(initializer)
    assert {:error, :req_llm_start_failed} == result(expires)
    dies = requester(service, nil, 5_000)

    wait_state(
      service,
      &Enum.any?(&1.operation.waiters, fn waiter -> waiter.pid == elem(dies, 0) end)
    )

    Process.exit(elem(dies, 0), :kill)
    assert_receive {:DOWN, monitor_id, :process, dead, :killed}, 1_000
    assert monitor_id == elem(dies, 1)
    assert dead == elem(dies, 0)
    assert Process.alive?(initializer)
    live = requester(service, nil, 5_000)
    release(hold)
    assert :ok == result(live)
    assert_receive {:DOWN, ^monitor, :process, ^initializer, :normal}, 1_000
    assert :ok == request(service)
  end

  defp execute(:service_reconciliation) do
    {parent, service, sentinel} = parent()
    hold = hold_start()
    waiter = requester(service, nil, 5_000)
    held(hold)
    identity = {:preparing, initializer, _ref} = :persistent_term.get(@initializer)
    initializer_monitor = Process.monitor(initializer)
    kill(service)
    assert {:error, :req_llm_start_failed} == result(waiter)
    assert Process.alive?(initializer)
    assert Process.alive?(sentinel)
    assert {:ok, replacement} = Supervisor.start_child(parent, {Starter, []})
    assert :sys.get_state(replacement).reconciliation.identity == identity
    later = requester(replacement, nil, 5_000)
    wait_state(replacement, &(length(&1.queued) == 1))
    assert :persistent_term.get(@initializer) == identity
    release(hold)
    assert_receive {:DOWN, ^initializer_monitor, :process, ^initializer, :normal}, 5_000
    assert :ok == result(later)
    assert {:started, _, ref} = :persistent_term.get(@provenance)
    assert ref == elem(identity, 2)
    assert :persistent_term.get(@initializer, :absent) == :absent
    assert Process.alive?(sentinel)
  end

  defp execute(:temporary_crash_loop) do
    {parent, service, sentinel} = parent()
    assert Starter.child_spec([]).restart == :temporary
    assert Starter.child_spec([]).significant == false
    kill(service)

    Enum.each(1..8, fn _ ->
      assert {:ok, next} = Supervisor.start_child(parent, {Starter, []})
      kill(next)
      assert Process.alive?(sentinel)
      assert Process.alive?(parent)
    end)

    assert {:ok, recovered} = Supervisor.start_child(parent, {Starter, []})
    assert :ok == request(recovered)
  end

  defp execute(:worker_loss) do
    {_parent, service, _sentinel} = parent()
    hold = hold_start()
    waiter = requester(service, nil, 5_000)
    held(hold)
    {:preparing, initializer, _} = :persistent_term.get(@initializer)
    monitor = Process.monitor(initializer)
    Process.exit(initializer, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^initializer, :killed}, 1_000
    assert {:error, :req_llm_start_failed} == result(waiter)
    assert :persistent_term.get(@initializer, :absent) == :absent
    assert :persistent_term.get(@provenance, :absent) == :absent
    release(hold)
    wait_controller()
    # A real controller start can finish after its waiting worker died. There
    # is no positive worker proof, so only a fresh host declaration can adopt it.
    assert {:error, :req_llm_already_started} == request(service)
    assert :ok == request(service, :host_started)
  end

  defp execute(:malformed_records) do
    {_parent, service, _sentinel} = parent()

    Enum.each(
      [:starting, {:preparing, self(), :not_a_reference}, {:preparing, :not_a_pid, make_ref()}],
      fn record ->
        :persistent_term.put(@initializer, record)
        assert {:error, :req_llm_start_failed} == request(service)
        assert :persistent_term.get(@initializer) == record
        :persistent_term.erase(@initializer)
      end
    )

    :persistent_term.put(@provenance, {:started, self(), :not_a_reference})
    assert {:error, :req_llm_start_failed} == request(service)
    assert Process.whereis(ReqLLM.Supervisor) == nil
    :persistent_term.erase(@provenance)
    dead = spawn(fn -> :ok end)
    dead_monitor = Process.monitor(dead)
    assert_receive {:DOWN, ^dead_monitor, :process, ^dead, _}, 1_000
    :persistent_term.put(@initializer, {:preparing, dead, make_ref()})
    assert :ok == request(service)
    assert :persistent_term.get(@initializer, :absent) == :absent
  end

  defp execute(:stalled_controller) do
    {_parent, service, _sentinel} = parent()
    :ok = :sys.suspend(:application_controller)
    first = requester(service, nil, 80)
    wait_state(service, &(not is_nil(&1.operation)))
    assert {:error, :req_llm_start_failed} == result(first)
    assert Process.alive?(service)
    assert :persistent_term.get(@initializer, :absent) == :absent
    expired = requester(service, :host_started, 40)
    assert {:error, :req_llm_start_failed} == result(expired)
    :ok = :sys.resume(:application_controller)
    wait_state(service, &is_nil(&1.operation))
    assert Process.whereis(ReqLLM.Supervisor) == nil
    assert :ok == request(service)
  end

  defp execute(:queue_bound) do
    {_parent, service, _sentinel} = parent()
    hold = hold_start()
    first = requester(service, nil, 5_000)
    held(hold)
    identity = :persistent_term.get(@initializer)
    queued = Enum.map(1..127, fn _ -> requester(service, :host_started, 5_000) end)
    wait_state(service, &(length(&1.queued) == 127))
    assert {:error, :req_llm_start_failed} == request(service)
    assert :persistent_term.get(@initializer) == identity
    release(hold)
    assert :ok == result(first)
    Enum.each(queued, &assert(:ok == result(&1)))
    assert :ok == request(service)
  end

  defp execute(:result_and_down) do
    {_parent, service, _sentinel} = parent()
    hold = hold_start()
    first = requester(service, nil, 5_000)
    held(hold)
    {:preparing, worker, reference} = :persistent_term.get(@initializer)
    worker_monitor = Process.monitor(worker)
    assert true == :erlang.suspend_process(worker)
    release(hold)
    wait_controller()

    # Concept: an untrusted-shaped result cannot establish success.
    # Technical depth: the real initializer remains suspended with its real
    # controller reply queued. A matching malformed result is failed closed;
    # its later genuine result and normal DOWN cannot replace that result.
    send(service, {:validation_result, worker, reference, {:error, {:raw, :dependency_reason}}})
    assert :sys.get_state(service).operation.result == {:error, :req_llm_start_failed}
    assert true == :erlang.resume_process(worker)
    assert {:error, :req_llm_start_failed} == result(first)
    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, :normal}, 1_000

    send(
      service,
      {:validation_result, worker, reference, {:ok, Process.whereis(ReqLLM.Supervisor)}}
    )

    assert :ok == request(service)

    :ok = Application.stop(:req_llm)
    hold = hold_start()
    expires = requester(service, nil, 1_000)
    held(hold)
    {:preparing, delayed, delayed_ref} = :persistent_term.get(@initializer)
    delayed_monitor = Process.monitor(delayed)
    assert true == :erlang.suspend_process(delayed)
    release(hold)
    wait_controller()
    reply_pid = Process.whereis(ReqLLM.Supervisor)
    send(service, {:validation_result, delayed, delayed_ref, {:ok, reply_pid}})
    assert :sys.get_state(service).operation.result == {:ok, reply_pid}
    assert {:error, :req_llm_start_failed} == result(expires)
    assert Process.alive?(delayed)
    refute_receive {:DOWN, ^delayed_monitor, :process, ^delayed, _}, 0
    assert true == :erlang.resume_process(delayed)
    assert_receive {:DOWN, ^delayed_monitor, :process, ^delayed, :normal}, 1_000
    assert :ok == request(service)

    :ok = Application.stop(:req_llm)
    hold = hold_start()
    tampered = requester(service, nil, 5_000)
    held(hold)
    {:preparing, final_worker, _} = :persistent_term.get(@initializer)
    assert true == :erlang.suspend_process(final_worker)
    release(hold)
    wait_controller()
    :persistent_term.put(@initializer, :malformed_after_admission)
    assert true == :erlang.resume_process(final_worker)
    assert {:error, :req_llm_start_failed} == result(tampered)
    assert :persistent_term.get(@initializer) == :malformed_after_admission
    :persistent_term.erase(@initializer)
    assert :ok == request(service)
  end

  defp execute(:pre_grant_service_loss) do
    {parent, service, sentinel} = parent()
    :ok = :sys.suspend(:application_controller)
    first = requester(service, nil, 5_000)
    operation = wait_state(service, &(not is_nil(&1.operation))).operation
    assert operation.phase == :validating
    worker_monitor = Process.monitor(operation.pid)
    assert :persistent_term.get(@initializer, :absent) == :absent
    kill(service)
    assert {:error, :req_llm_start_failed} == result(first)
    assert {:ok, replacement} = Supervisor.start_child(parent, {Starter, []})
    :ok = :sys.resume(:application_controller)
    assert_receive {:DOWN, ^worker_monitor, :process, worker, :normal}, 1_000
    assert worker == operation.pid
    assert Process.whereis(ReqLLM.Supervisor) == nil
    assert :persistent_term.get(@provenance, :absent) == :absent
    assert Process.alive?(sentinel)
    assert :ok == request(replacement)
  end

  defp execute(:empty_start_list) do
    {_parent, service, _sentinel} = parent()
    assert :ok == request(service)
    prior = :persistent_term.get(@provenance)
    :ok = Application.stop(:req_llm)
    observer = self()
    token = make_ref()

    hook = fn state, event, _ ->
      case event do
        {:in, {:"$gen_call", {worker, _}, {:set_env, :req_llm, :load_dotenv, false, _}}} ->
          {:preparing, ^worker, _} = :persistent_term.get(@initializer)
          true = :erlang.suspend_process(worker)
          send(observer, {:dotenv_write_held, worker, token})

        {:in, {:resume_initializer, worker, ^token}} ->
          true = :erlang.resume_process(worker)
          send(observer, {:initializer_resumed, worker, token})

        _ ->
          :ok
      end

      state
    end

    assert :ok == :sys.install(:application_controller, {token, hook, nil})
    waiter = requester(service, nil, 5_000)
    assert_receive {:dotenv_write_held, worker, ^token}, 1_000
    assert Application.get_env(:req_llm, :load_dotenv) == false
    assert {:ok, applications} = Application.ensure_all_started(:req_llm)
    assert :req_llm in applications
    refute Process.whereis(ReqLLM.Supervisor) == elem(prior, 1)
    # Suspension belongs to its suspending process. The debug hook, not this
    # observer, performs the matching resume in the actual controller.
    send(:application_controller, {:resume_initializer, worker, token})
    assert_receive {:initializer_resumed, ^worker, ^token}, 1_000
    assert :ok == :sys.remove(:application_controller, token)
    assert {:error, :req_llm_start_failed} == result(waiter)
    assert :persistent_term.get(@provenance) == prior
    assert :persistent_term.get(@initializer, :absent) == :absent
    assert {:error, :req_llm_already_started} == request(service)
    assert :ok == request(service, :host_started)
    assert :persistent_term.get(@provenance) == prior
  end

  defp execute(:failure_and_protocol) do
    {_parent, service, _sentinel} = parent()
    assert {:error, :req_llm_start_failed} == Starter.request(service, :other, deadline())

    assert {:error, :req_llm_start_failed} ==
             Starter.request(service, nil, System.monotonic_time() - 1)

    assert {:error, :req_llm_start_failed} == Starter.request(nil, nil, deadline())
    send(service, {:request, self(), make_ref(), :other, deadline()})
    send(service, {:validation_result, self(), make_ref(), {:ok, self()}})
    send(service, {:start_requested, self(), make_ref()})
    send(service, {:DOWN, make_ref(), :process, self(), :normal})
    assert Process.alive?(service)
    Application.put_env(:req_llm, :finch, :malformed)
    assert {:error, :req_llm_start_failed} == request(service)
    assert :persistent_term.get(@provenance, :absent) == :absent
    Application.delete_env(:req_llm, :finch)
    assert :ok == request(service)
  end

  defp parent do
    sentinel = %{
      id: :sentinel,
      start:
        {Task, :start_link,
         [
           fn ->
             receive do
               :stop -> :ok
             end
           end
         ]},
      restart: :temporary,
      significant: false
    }

    {:ok, parent} =
      Supervisor.start_link([{Starter, []}, sentinel],
        strategy: :one_for_one,
        auto_shutdown: :never,
        max_restarts: 1,
        max_seconds: 5
      )

    service = Process.whereis(Starter)

    {_, sentinel, _, _} =
      Enum.find(Supervisor.which_children(parent), &(elem(&1, 0) == :sentinel))

    {parent, service, sentinel}
  end

  defp request(service, declaration \\ nil), do: Starter.request(service, declaration, deadline())

  defp deadline(ms \\ 5_000),
    do: System.monotonic_time() + System.convert_time_unit(ms, :millisecond, :native)

  defp requester(service, declaration, ms) do
    observer = self()
    tag = make_ref()

    {pid, monitor} =
      spawn_monitor(fn ->
        started = System.monotonic_time(:millisecond)
        result = Starter.request(service, declaration, deadline(ms))
        elapsed = System.monotonic_time(:millisecond) - started
        send(observer, {tag, result, elapsed})
      end)

    {pid, monitor, tag, ms}
  end

  defp result({pid, monitor, tag, bound}) do
    {result, elapsed} =
      receive do
        {^tag, result, elapsed} -> {result, elapsed}
      after
        7_000 -> flunk("startup requester did not return")
      end

    assert elapsed <= min(bound, 5_000) + 1_000
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 1_000
    result
  end

  defp kill(pid) do
    monitor = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}, 1_000
  end

  defp hold_start do
    observer = self()
    token = make_ref()

    hook = fn state, event, _ ->
      case event do
        {:in, {:"$gen_call", from, {:start_application, :req_llm, _}}} ->
          send(observer, {:start_held, self(), token, from})

          receive do
            {:release_start, ^token} -> :ok
          end

        _ ->
          :ok
      end

      state
    end

    assert :ok == :sys.install(:application_controller, {token, hook, nil})
    {Process.whereis(:application_controller), token}
  end

  defp held({_controller, token}) do
    assert_receive {:start_held, controller, ^token, from}, 5_000
    assert controller == Process.whereis(:application_controller)
    assert is_tuple(from)
    :ok
  end

  defp release({controller, token}) do
    send(controller, {:release_start, token})
    assert :ok == :sys.remove(controller, token)
  end

  defp wait_controller do
    wait_controller(deadline(1_000))
  end

  defp trace_persistent_writes(true) do
    :erlang.trace_pattern({:persistent_term, :put, 2}, true, [])
    :erlang.trace_pattern({:persistent_term, :erase, 1}, true, [])
    :erlang.trace(:all, true, [:call, :set_on_spawn, {:tracer, self()}])
  end

  defp trace_persistent_writes(false) do
    :erlang.trace(:all, false, [:call, :set_on_spawn])
    :erlang.trace_pattern({:persistent_term, :put, 2}, false, [])
    :erlang.trace_pattern({:persistent_term, :erase, 1}, false, [])
  end

  defp persistent_writes do
    delivery = :erlang.trace_delivered(:all)
    assert_receive {:trace_delivered, :all, ^delivery}, 1_000
    persistent_writes([])
  end

  defp persistent_writes(records) do
    receive do
      {:trace, _pid, :call, {:persistent_term, action, [key | _] = arguments}} ->
        records =
          if key in [@initializer, @provenance],
            do: [{action, arguments} | records],
            else: records

        persistent_writes(records)
    after
      0 -> Enum.reverse(records)
    end
  end

  defp wait_controller(bound) do
    if Enum.any?(Application.started_applications(), &(elem(&1, 0) == :req_llm)) do
      :ok
    else
      if System.monotonic_time() >= bound,
        do: flunk("admitted controller operation did not finish")

      receive do
      after
        1 -> wait_controller(bound)
      end
    end
  end

  defp wait_state(service, predicate, bound \\ nil) do
    bound = bound || deadline(1_000)
    state = :sys.get_state(service, 1_000)

    if predicate.(state) do
      state
    else
      if System.monotonic_time() >= bound, do: flunk("startup protocol state did not settle")

      receive do
      after
        1 -> wait_state(service, predicate, bound)
      end
    end
  end
end
