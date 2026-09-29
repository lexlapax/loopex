defmodule Loopex.LLM.ReqLLM.InProcess.CleanupOwner do
  @moduledoc """
  ## Concept

  A managed provider start first creates an inert cleanup-owner candidate. It
  carries no request, credential, pool, caller or dispatch authority.

  ## Technical depth

  The candidate proves its Task.Supervisor parent, callback and proxy, then
  binds one cleanup-only host route delivered with its exact custody identity.
  It acknowledges custody only after the proxy's normal retirement. On callback
  loss it asks that route to record empty retirement before it exits or waits
  for a registered core stop. The cleanup handle has no work grant. Resource
  teardown and core-stop acknowledgement are separate later transitions. After
  activation, this process retains only identities, the credential-free route,
  and cleanup evidence; the callback gives inputs directly to the caller.
  """

  alias Loopex.LLM.ReqLLM.InProcess.Admission
  alias Loopex.LLM.ReqLLM.InProcess.PoolLifecycle
  alias Loopex.LLM.ReqLLM.InProcess.Route
  alias Loopex.LLM.ReqLLM.Deadline

  @cleanup_ms 1_000

  @type spec :: %{
          callback: pid(),
          proxy: pid(),
          start_ref: reference(),
          deadline: integer()
        }

  @doc false
  @spec run(spec()) :: :ok
  def run(%{callback: callback, proxy: proxy, start_ref: start_ref, deadline: deadline} = spec)
      when map_size(spec) == 4 and is_pid(callback) and is_pid(proxy) and
             is_reference(start_ref) and is_integer(deadline) do
    Process.flag(:sensitive, true)

    with {:ok, parent} <- actual_parent(),
         true <- live?(callback) and live?(proxy) and live_deadline?(deadline) do
      parent_mon = Process.monitor(parent)
      callback_mon = Process.monitor(callback)
      proxy_mon = Process.monitor(proxy)

      if live?(callback) and live?(proxy) and live_deadline?(deadline) do
        send(callback, {:model_candidate_ready, self(), start_ref, proxy})

        loop(%{
          callback: callback,
          callback_mon: callback_mon,
          proxy: proxy,
          proxy_mon: proxy_mon,
          parent: parent,
          parent_mon: parent_mon,
          start_ref: start_ref,
          deadline: deadline,
          proxy_retiring: false,
          proxy_down: false,
          custody: nil,
          owner_mon: nil,
          registration_pending: nil,
          cleanup_attempted: false,
          retired: false,
          activation: nil,
          work: nil,
          cleanup: nil,
          core_stop: nil,
          unproved: false
        })
      end
    end

    :ok
  end

  def run(_), do: :ok

  defp actual_parent do
    case {Process.get(:"$ancestors"), Process.info(self(), :links)} do
      {[parent | _], {:links, links}} when is_pid(parent) ->
        if parent in links and live?(parent), do: {:ok, parent}, else: :error

      _ ->
        :error
    end
  end

  defp loop(state) do
    case loop_wait(state) do
      0 ->
        case expired(state) do
          :stop -> :ok
          next -> loop(next)
        end

      timeout ->
        receive do
          message ->
            case dispatch(state, message) do
              :stop ->
                :ok

              {:caller, next, caller} ->
                try do
                  loop(next)
                after
                  Process.exit(caller, :kill)
                end

              next ->
                loop(next)
            end
        after
          timeout -> loop(state)
        end
    end
  end

  defp loop_wait(%{unproved: true}), do: :infinity
  defp loop_wait(%{cleanup: %{deadline: deadline}}), do: remaining_ms(deadline)
  defp loop_wait(%{retired: true, cleanup: nil}), do: :infinity

  defp loop_wait(%{work: %{deadline: deadline}, cleanup: nil}),
    do: remaining_ms(deadline)

  defp loop_wait(%{cleanup_attempted: true}), do: :infinity
  defp loop_wait(%{custody: %{acked: true}}), do: :infinity
  defp loop_wait(%{custody: %{acked: false, deadline: deadline}}), do: remaining_ms(deadline)
  defp loop_wait(%{deadline: deadline}), do: remaining_ms(deadline)

  defp expired(%{cleanup: cleanup} = state) when not is_nil(cleanup),
    do: fail_cleanup(state)

  defp expired(%{work: work} = state) when not is_nil(work),
    do: begin_cleanup(state, :deadline)

  defp expired(%{custody: nil}), do: :stop

  defp expired(state) do
    state = retire_empty(state)
    if state.retired and is_nil(state.registration_pending), do: :stop, else: state
  end

  defp dispatch(state, {:proxy_retiring, proxy, ref})
       when proxy == state.proxy and ref == state.start_ref and
              not state.proxy_retiring and not state.proxy_down,
       do: state |> Map.put(:proxy_retiring, true) |> maybe_ack_custody()

  defp dispatch(state, {:DOWN, mon, :process, proxy, :normal})
       when mon == state.proxy_mon and proxy == state.proxy and state.proxy_retiring,
       do: state |> Map.put(:proxy_down, true) |> maybe_ack_custody()

  defp dispatch(state, {:DOWN, mon, :process, proxy, _})
       when mon == state.proxy_mon and proxy == state.proxy,
       do: :stop

  defp dispatch(state, {:DOWN, mon, :process, callback, _})
       when mon == state.callback_mon and callback == state.callback do
    state = %{state | callback: nil}

    cond do
      state.work ->
        begin_cleanup(state, :callback_loss)

      state.custody ->
        state = retire_empty(state)
        if state.retired and is_nil(state.registration_pending), do: :stop, else: state

      true ->
        :stop
    end
  end

  defp dispatch(state, {:DOWN, mon, :process, parent, _})
       when mon == state.parent_mon and parent == state.parent do
    if state.work, do: begin_cleanup(state, :parent_loss), else: :stop
  end

  defp dispatch(state, {:DOWN, mon, :process, owner, _})
       when mon == state.owner_mon and not is_nil(state.custody) and
              owner == state.custody.owner do
    if state.work, do: begin_cleanup(state, :session_owner_loss), else: :stop
  end

  defp dispatch(
         state,
         {:model_custody_prepare, ref, staging_ref, expiry, module,
          {:model_cleanup_custody, owner, generation, call_ref, candidate, proof_ref}}
       )
       when ref == state.start_ref and is_nil(state.custody) and is_reference(staging_ref) and
              is_integer(expiry) and is_pid(owner) and is_reference(generation) and
              is_reference(call_ref) and candidate == self() and is_reference(proof_ref) do
    if valid_module?(module) and live_control_deadline?(expiry) and live?(owner) and
         state.callback do
      handle = {:model_cleanup_custody, owner, generation, call_ref, candidate, proof_ref}

      state
      |> Map.put(:custody, %{
        module: module,
        handle: handle,
        owner: owner,
        staging: staging_ref,
        generation: generation,
        call: call_ref,
        proof: proof_ref,
        deadline: expiry,
        acked: false
      })
      |> Map.put(:owner_mon, Process.monitor(owner))
      |> maybe_ack_custody()
    else
      state
    end
  end

  defp dispatch(state, {:registration_pending, callback, stop_ref})
       when callback == state.callback and is_reference(stop_ref) and
              not is_nil(state.custody) and state.custody.acked and state.proxy_down and
              is_nil(state.registration_pending) do
    send(callback, {:registration_pending_ack, self(), state.start_ref, stop_ref})
    %{state | registration_pending: stop_ref}
  end

  defp dispatch(state, message), do: active_dispatch(state, message)

  defp active_dispatch(
         state,
         {:in_process_activation_prepare, callback, start_ref, prepare_ref,
          {:managed, retainer, cleanup_grace}, token, proof, module, handle, cell, deadline}
       )
       when callback == state.callback and start_ref == state.start_ref and
              is_reference(prepare_ref) and is_pid(retainer) and is_integer(cleanup_grace) and
              is_reference(token) and is_reference(proof) and is_atom(module) and
              is_reference(cell) and is_integer(deadline) do
    custody = state.custody

    if state.activation == nil and state.work == nil and state.cleanup == nil and
         not state.unproved and not state.retired and state.core_stop == nil and
         is_reference(state.registration_pending) and is_map(custody) and custody.acked and
         state.proxy_down and
         proof == custody.proof and module == custody.module and
         handle == {module, custody.owner, custody.generation, cell} and
         cleanup_grace == Loopex.Executor.default_cleanup_grace_ms() and live?(retainer) and
         live?(callback) and live_deadline?(deadline) and :atomics.get(cell, 1) == 0 do
      activation = %{
        retainer: retainer,
        retainer_mon: Process.monitor(retainer),
        token: token,
        module: module,
        handle: handle,
        cell: cell,
        deadline: deadline
      }

      send(callback, {:in_process_activation_prepared, self(), start_ref, prepare_ref})
      %{state | activation: activation}
    else
      state
    end
  end

  defp active_dispatch(
         state,
         {:in_process_activation_begin, callback, start_ref, begin_ref, token, grant, call,
          base_url, fingerprint, trace_capability, deadline}
       )
       when callback == state.callback and start_ref == state.start_ref and
              is_reference(begin_ref) and is_reference(token) and is_reference(call) and
              is_binary(base_url) and is_map(fingerprint) and is_integer(deadline) do
    activation = state.activation

    if is_map(activation) and state.work == nil and state.cleanup == nil and
         not state.unproved and not state.retired and state.core_stop == nil and
         state.custody.call == call and
         activation.token == token and activation.deadline == deadline and
         live_deadline?(deadline) and live?(callback) and live?(activation.retainer) and
         :atomics.get(activation.cell, 1) == 0 and
         valid_register_grant?(grant, state, callback, deadline) and
         valid_route?(base_url, fingerprint) do
      Process.flag(:trap_exit, true)
      tag = make_ref()
      root_ref = make_ref()
      route = expected_route(base_url, fingerprint)

      work = %{
        call: call,
        deadline: deadline,
        base_url: base_url,
        fingerprint: fingerprint,
        route: route,
        # Concept: A fixed provider route remains bound without a plan marker.
        # Technical depth: ReqLLM writes request-plan metadata only for OpenAI
        # and Anthropic; Ollama/OpenRouter are expected to report nil here.
        surface:
          if(fingerprint.provider in [:ollama, :openrouter],
            do: nil,
            else: fingerprint.surface
          ),
        trace_capability: trace_capability,
        tag: tag,
        root_ref: root_ref,
        root: nil,
        root_mon: nil,
        root_stop_ref: nil,
        root_stopped: false,
        root_down: false,
        worker: nil,
        identity: nil,
        caller: nil,
        caller_mon: nil,
        caller_down: false,
        caller_ready: false,
        input_ref: nil,
        claim_ref: nil,
        inspect_ref: nil,
        dispatched: false,
        teardown_ref: nil,
        teardown_acked: false,
        result: nil,
        result_sent: false,
        revision: 0
      }

      send(callback, {:in_process_activation_begun, self(), start_ref, begin_ref})
      state = %{state | work: work, activation: %{activation | token: nil}}
      start_root(state)
    else
      state
    end
  end

  defp active_dispatch(
         state,
         {:release_empty_invocation, generation, call, candidate, proof, release_ref, deadline}
       )
       when is_reference(release_ref) and is_integer(deadline) and candidate == self() do
    custody = state.custody

    if custody && state.callback == nil && state.work == nil && state.retired &&
         state.registration_pending && state.core_stop == nil &&
         generation == custody.generation && call == custody.call && proof == custody.proof &&
         live_deadline?(deadline) do
      send(custody.owner, {:empty_invocation_released, self(), release_ref})
      :stop
    else
      state
    end
  end

  defp active_dispatch(
         state,
         {:loopex_provider_resource_stop, stop_ref, nonce, core, cooperative_ms, observation_ms}
       )
       when is_reference(stop_ref) and stop_ref == state.registration_pending and
              is_reference(nonce) and is_pid(core) and
              is_integer(cooperative_ms) and is_integer(observation_ms) and
              cooperative_ms <= observation_ms do
    if state.core_stop do
      state
    else
      deadline =
        min(System.convert_time_unit(cooperative_ms, :millisecond, :native), control_deadline())

      state = %{state | core_stop: %{nonce: nonce, core: core, deadline: deadline}}

      cond do
        state.work ->
          begin_cleanup(state, :core_stop)

        state.retired ->
          acknowledge_core_stop(state)

        state.custody ->
          state = retire_empty(state, deadline)
          if state.retired, do: acknowledge_core_stop(state), else: state

        true ->
          state
      end
    end
  end

  defp active_dispatch(state, {:DOWN, mon, :process, retainer, reason}) do
    if state.activation && mon == state.activation.retainer_mon &&
         retainer == state.activation.retainer do
      if state.work, do: begin_cleanup(state, :retainer_loss), else: retire_empty(state)
    else
      active_work_dispatch(state, {:DOWN, mon, :process, retainer, reason})
    end
  end

  defp active_dispatch(state, message), do: active_work_dispatch(state, message)

  defp valid_register_grant?(
         {:session_grant, generation, :register_model, grant_callback, reference, expiry},
         state,
         callback,
         deadline
       )
       when is_reference(reference) and is_integer(expiry),
       do:
         generation == state.custody.generation and grant_callback == callback and
           expiry <= deadline and live_deadline?(expiry)

  defp valid_register_grant?(_, _, _, _), do: false

  defp valid_route?(base_url, %{provider: provider, surface: surface} = fingerprint) do
    Route.base_url(provider, base_url) == {:ok, base_url} and
      Route.fingerprint(provider, surface, base_url) == {:ok, fingerprint}
  end

  defp valid_route?(_, _), do: false

  defp expected_route(base_url, fingerprint) do
    uri = URI.parse(base_url)

    %{
      method: :post,
      scheme: uri.scheme,
      host: uri.host,
      effective_port: uri.port || if(uri.scheme == "https", do: 443, else: 80),
      path: fingerprint.path,
      query: nil
    }
  end

  defp start_root(state) do
    work = state.work
    owner = self()

    {root, monitor} =
      spawn_monitor(fn ->
        PoolLifecycle.run(%{
          owner: owner,
          reference: work.root_ref,
          base_url: work.base_url,
          tag: work.tag,
          deadline: work.deadline
        })
      end)

    state = %{state | work: %{work | root: root, root_mon: monitor}}

    case record_resources(state, [{:process, :root, root}]) do
      {:ok, state} ->
        if live_deadline?(work.deadline) and :atomics.get(state.activation.cell, 1) == 0 do
          send(root, {:loopex_pool_start, self(), work.root_ref})
          state
        else
          begin_cleanup(state, :deadline)
        end

      {:error, state} ->
        begin_cleanup(state, :record_refused)
    end
  end

  defp active_work_dispatch(%{work: nil} = state, _message), do: state

  defp active_work_dispatch(state, {:loopex_pool_record, root, reference, entries})
       when root == state.work.root and is_reference(reference) and is_list(entries) do
    case record_resources(state, entries) do
      {:ok, state} ->
        # Concept: Cleanup records reached children without authorizing setup.
        # Technical depth: after a stop command from this sender, its queued
        # order fences any later receipt from advancing the root.
        if (state.cleanup == nil and not state.unproved) or
             is_reference(state.work.root_stop_ref) do
          send(root, {:loopex_pool_recorded, reference})
        end

        state

      {:error, state} ->
        begin_cleanup(state, :record_refused)
    end
  end

  defp active_work_dispatch(state, {:loopex_pool_ready, root, reference, worker, identity})
       when root == state.work.root and reference == state.work.root_ref and is_pid(worker) do
    if (state.cleanup == nil and state.work.worker == nil and
          identity == expected_identity(state.work) and live?(worker)) &&
         live_deadline?(state.work.deadline) &&
         :atomics.get(state.activation.cell, 1) == 0 do
      work = %{state.work | worker: worker, identity: identity}
      start_caller(%{state | work: work})
    else
      begin_cleanup(state, :pool_refused)
    end
  end

  defp active_work_dispatch(state, {:in_process_caller_ready, caller, reference})
       when caller == state.work.caller and reference == state.work.call do
    work = state.work

    if (state.cleanup == nil and not work.caller_ready and live?(caller)) &&
         live_deadline?(work.deadline) && state.callback && live?(state.callback) &&
         :atomics.get(state.activation.cell, 1) == 0 do
      send(
        state.callback,
        {:in_process_caller_input_ready, self(), work.call, caller, work.input_ref, work.tag}
      )

      send(caller, {:in_process_caller_begin, self(), work.call, work.input_ref})
      %{state | work: %{work | caller_ready: true}}
    else
      begin_cleanup(state, :caller_refused)
    end
  end

  defp active_work_dispatch(
         state,
         {:loopex_one_shot_claim, caller, reference, tag, fingerprint, route, surface}
       )
       when caller == state.work.caller and is_reference(reference) do
    work = state.work

    if (state.cleanup == nil and work.caller_ready and work.claim_ref == nil and
          work.inspect_ref == nil and not work.dispatched and tag == work.tag and
          fingerprint == work.fingerprint and route == work.route and surface == work.surface) &&
         live?(caller) && live?(work.root) && live?(work.worker) &&
         live_deadline?(work.deadline) && :atomics.get(state.activation.cell, 1) == 0 do
      inspect_ref = make_ref()
      send(work.root, {:loopex_pool_inspect, self(), inspect_ref, work.deadline})
      %{state | work: %{work | claim_ref: reference, inspect_ref: inspect_ref}}
    else
      send(caller, {:loopex_one_shot_refused, reference, tag})
      begin_cleanup(state, :dispatch_refused)
    end
  end

  defp active_work_dispatch(state, {:loopex_pool_inspected, root, reference, :ok})
       when root == state.work.root and reference == state.work.inspect_ref do
    work = state.work

    if (state.cleanup == nil and work.claim_ref) && live?(work.caller) && live?(work.worker) &&
         live_deadline?(work.deadline) && :atomics.get(state.activation.cell, 1) == 0 do
      send(work.caller, {:loopex_one_shot_grant, work.claim_ref, work.tag, work.worker})
      %{state | work: %{work | dispatched: true, inspect_ref: nil}}
    else
      send(work.caller, {:loopex_one_shot_refused, work.claim_ref, work.tag})
      begin_cleanup(state, :dispatch_refused)
    end
  end

  defp active_work_dispatch(state, {:loopex_pool_inspected, root, reference, :refused})
       when root == state.work.root and reference == state.work.inspect_ref do
    send(state.work.caller, {:loopex_one_shot_refused, state.work.claim_ref, state.work.tag})
    begin_cleanup(state, :pool_refused)
  end

  defp active_work_dispatch(state, {:loopex_one_shot_teardown, caller, reference, tag})
       when caller == state.work.caller and is_reference(reference) and tag == state.work.tag do
    if state.cleanup == nil and state.work.teardown_ref == nil do
      work = %{state.work | teardown_ref: reference}
      state = %{state | work: work}
      stop_root(state)
    else
      state
    end
  end

  defp active_work_dispatch(state, {:loopex_pool_stopped, root, reference})
       when root == state.work.root and reference == state.work.root_stop_ref do
    maybe_finish(%{state | work: %{state.work | root_stopped: true}})
  end

  defp active_work_dispatch(state, {:loopex_pool_failed, root, reference})
       when root == state.work.root and reference == state.work.root_ref do
    work = %{state.work | root_stopped: true}
    begin_cleanup(%{state | work: work}, :pool_failed)
  end

  defp active_work_dispatch(state, {:loopex_pool_unproved, root, reference})
       when root == state.work.root and reference == state.work.root_ref,
       do: fail_cleanup(state)

  defp active_work_dispatch(state, {caller, reference, result, finished_at_native})
       when caller == state.work.caller and reference == state.work.call and
              is_integer(finished_at_native) do
    work = state.work

    pre_adapter_failure =
      work.claim_ref == nil and match?({:error, {_, "model_call_failed"}}, result)

    returned_from_adapter =
      work.root_down and work.root_stopped and work.teardown_acked and
        is_reference(work.claim_ref)

    if state.cleanup == nil and work.result == nil and valid_result?(result) and
         (pre_adapter_failure or returned_from_adapter) and
         finished_at_native <= work.deadline and :atomics.get(state.activation.cell, 1) == 0 do
      state = %{state | work: %{work | result: result}}

      if pre_adapter_failure and not (work.root_down and work.root_stopped) do
        stop_root(state)
      else
        Process.exit(caller, :kill)
        state
      end
    else
      begin_cleanup(state, :result_refused)
    end
  end

  defp active_work_dispatch(state, {:DOWN, monitor, :process, pid, reason}) do
    work = state.work

    cond do
      monitor == work.root_mon and pid == work.root ->
        work = %{work | root_down: true}

        if reason == :normal and work.root_stopped,
          do: maybe_finish(%{state | work: work}),
          else: begin_cleanup(%{state | work: work}, :pool_down)

      monitor == work.caller_mon and pid == work.caller ->
        maybe_finish(%{state | work: %{work | caller_down: true}})

      true ->
        state
    end
  end

  defp active_work_dispatch(state, {:EXIT, pid, _reason}) do
    if state.work.caller == pid, do: state, else: state
  end

  defp active_work_dispatch(state, _message), do: state

  defp valid_result?({:ok, reply}) when is_map(reply), do: true

  defp valid_result?({:error, {classification, "model_call_failed"}})
       when classification in [:not_dispatched, :dispatched_or_unknown],
       do: true

  defp valid_result?(_result), do: false

  defp expected_identity(work) do
    uri = URI.parse(work.base_url)
    scheme = if uri.scheme == "https", do: :https, else: :http
    {scheme, uri.host, uri.port || if(uri.scheme == "https", do: 443, else: 80), work.tag}
  end

  defp record_resources(state, entries) do
    revision = state.work.revision + 1
    operation = {:record_model_resources, state.work.call, self(), revision, entries}
    activation = state.activation

    deadline =
      if state.cleanup,
        do: min(state.cleanup.deadline, control_deadline()),
        else: control_deadline()

    case Admission.request(activation.module, activation.handle, operation, deadline) do
      {:ok, {:session_grant, generation, :record_model_resources, candidate, _, _}}
      when generation == state.custody.generation and candidate == self() ->
        {:ok, %{state | work: %{state.work | revision: revision}}}

      _failure ->
        {:error, seal_session(state)}
    end
  end

  defp start_caller(state) do
    work = state.work
    input_ref = make_ref()

    spec = %{
      owner: self(),
      callback: state.callback,
      ref: work.call,
      input_ref: input_ref,
      tag: work.tag,
      cell: state.activation.cell,
      trace_capability: work.trace_capability,
      pool_timeout: pool_timeout(work.deadline, System.monotonic_time())
    }

    {caller, monitor} =
      :erlang.spawn_opt(
        fn ->
          Loopex.LLM.ReqLLM.InProcess.Caller.run(spec)
        end,
        [:link, :monitor]
      )

    state = %{state | work: %{work | caller: caller, caller_mon: monitor, input_ref: input_ref}}

    state =
      case record_resources(state, [{:process, :caller, caller}]) do
        {:ok, state} -> state
        {:error, state} -> begin_cleanup(state, :record_refused)
      end

    {:caller, state, caller}
  end

  defp stop_root(%{work: %{root_stop_ref: reference}} = state)
       when is_reference(reference),
       do: state

  defp stop_root(%{work: %{root: root, root_down: false} = work} = state) when is_pid(root) do
    reference = make_ref()
    deadline = if state.cleanup, do: state.cleanup.deadline, else: control_deadline()
    send(root, {:loopex_pool_stop, self(), reference, deadline})
    %{state | work: %{work | root_stop_ref: reference}}
  end

  defp stop_root(state), do: maybe_finish(state)

  defp begin_cleanup(%{unproved: true} = state, _reason), do: state

  defp begin_cleanup(%{cleanup: cleanup, core_stop: %{deadline: deadline}} = state, _reason)
       when not is_nil(cleanup) do
    state = %{state | cleanup: %{cleanup | deadline: min(cleanup.deadline, deadline)}}
    maybe_finish(state)
  end

  defp begin_cleanup(%{cleanup: nil, work: work} = state, reason) when not is_nil(work) do
    deadline =
      if state.core_stop,
        do: min(state.core_stop.deadline, control_deadline()),
        else: control_deadline()

    state = %{state | cleanup: %{deadline: deadline, reason: reason}}
    if work.caller && not work.caller_down, do: Process.exit(work.caller, :kill)
    maybe_finish(state)
  end

  defp begin_cleanup(state, _reason), do: state

  defp maybe_finish(%{work: nil} = state), do: state

  defp maybe_finish(%{cleanup: cleanup} = state) when not is_nil(cleanup) do
    work = state.work

    cond do
      work.caller && not work.caller_down ->
        state

      work.root && not work.root_down ->
        stop_root(state)

      work.root && not work.root_stopped ->
        state

      state.cleanup_attempted ->
        cond do
          state.retired and state.core_stop -> acknowledge_core_stop(state)
          state.retired -> %{state | cleanup: nil}
          true -> fail_cleanup(state)
        end

      true ->
        state = retire_empty(state, cleanup.deadline)

        cond do
          not state.retired -> fail_cleanup(state)
          state.core_stop -> acknowledge_core_stop(state)
          true -> %{state | cleanup: nil}
        end
    end
  end

  defp maybe_finish(state) do
    work = state.work

    cond do
      work.root_down && work.root_stopped && work.teardown_ref && not work.teardown_acked ->
        send(work.caller, {:loopex_one_shot_torn_down, work.teardown_ref, work.tag})
        %{state | work: %{work | teardown_acked: true}}

      work.root_down && work.root_stopped && work.result && not work.caller_down ->
        Process.exit(work.caller, :kill)
        state

      work.root_down && work.root_stopped && work.result && work.caller_down &&
        not work.result_sent && state.callback && live?(state.callback) &&
          :atomics.get(state.activation.cell, 1) == 0 ->
        send(
          state.callback,
          {:in_process_model_result, self(), state.start_ref, work.call, work.result}
        )

        %{state | work: %{work | result_sent: true}}

      work.caller_down && work.result == nil ->
        begin_cleanup(state, :caller_loss)

      true ->
        state
    end
  end

  defp fail_cleanup(state) do
    state = seal_session(state)
    work = state.work
    if work && work.caller && not work.caller_down, do: Process.exit(work.caller, :kill)

    if work && work.root && not work.root_down do
      send(work.root, {:loopex_pool_stop, self(), make_ref(), control_deadline()})
    end

    %{state | cleanup: nil, unproved: true}
  end

  # Concept: failed cleanup seals this session, but cannot revoke proved closure.
  # Technical depth: conditional writes preserve a concurrent slot-1 value 2.
  defp seal_session(%{activation: %{cell: cell}} = state) do
    case :atomics.compare_exchange(cell, 1, 0, 3) do
      1 -> :atomics.compare_exchange(cell, 1, 1, 3)
      _ -> :ok
    end

    state
  end

  defp seal_session(state), do: state

  defp acknowledge_core_stop(
         %{core_stop: %{nonce: nonce, core: core, deadline: deadline}} = state
       ) do
    if state.retired and live_deadline?(deadline) do
      send(core, {:loopex_provider_resource_stopped, nonce, self()})
      :stop
    else
      fail_cleanup(state)
    end
  end

  defp control_deadline,
    do:
      System.monotonic_time() +
        System.convert_time_unit(@cleanup_ms, :millisecond, :native)

  defp maybe_ack_custody(%{custody: %{acked: false} = custody, proxy_down: true} = state) do
    if live_deadline?(custody.deadline) and not state.cleanup_attempted and
         not is_nil(state.callback) and live?(state.callback) do
      send(
        custody.owner,
        {:model_custody_prepared, self(), custody.staging, custody.generation, custody.call,
         custody.proof}
      )

      Map.put(state, :custody, %{custody | acked: true})
    else
      state
    end
  end

  defp maybe_ack_custody(state), do: state

  # The admission edge validates a correlated completion grant. A failed
  # request leaves the candidate alive for the session-subtree failure path;
  # its own exit cannot substitute for a recorded retirement.
  defp retire_empty(state), do: retire_empty(state, control_deadline())

  defp retire_empty(%{custody: custody, cleanup_attempted: false} = state, deadline) do
    deadline = min(deadline, control_deadline())
    operation = {:retire_model, custody.call, self(), custody.proof}

    retired =
      match?(
        {:ok, {:session_grant, _, :retire_model, _, _, _}},
        Admission.request(custody.module, custody.handle, operation, deadline)
      )

    %{state | cleanup_attempted: true, retired: retired}
  end

  defp retire_empty(state, _deadline), do: state

  defp valid_module?(module),
    do: is_atom(module) and function_exported?(module, :request, 3)

  defp live?(pid), do: Process.alive?(pid)
  defp live_deadline?(deadline), do: System.monotonic_time() < deadline

  defp live_control_deadline?(deadline) do
    now = System.monotonic_time()

    deadline > now and
      deadline <= now + System.convert_time_unit(@cleanup_ms, :millisecond, :native)
  end

  @doc false
  def pool_timeout(deadline, sampled_now) when is_integer(deadline) and is_integer(sampled_now) do
    deadline
    |> Deadline.remaining_timeout(sampled_now)
    |> min(1_000)
    |> max(1)
  end

  defp remaining_ms(deadline) do
    native = deadline - System.monotonic_time()

    if native <= 0 do
      0
    else
      min(1_000, max(1, System.convert_time_unit(native, :native, :millisecond)))
    end
  end
end
