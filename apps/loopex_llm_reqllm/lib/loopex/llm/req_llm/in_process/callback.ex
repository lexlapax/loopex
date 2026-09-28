defmodule Loopex.LLM.ReqLLM.InProcess.Callback do
  @moduledoc """
  ## Concept

  Admit one in-process model call, prove its cleanup custody, and return only
  the cleanup owner's settled result.

  ## Technical depth

  The start proxy is unlinked and contains no request or credential. The
  callback alone enters the process-local core registrar. An exact candidate,
  start return, normal proxy DOWN, custody acknowledgement, and managed
  registration precede activation. Request input goes from this callback
  directly to the sensitive caller; the cleanup owner receives no input.
  """

  alias Loopex.LLM.ReqLLM.Deadline
  alias Loopex.LLM.ReqLLM.InProcess
  alias Loopex.LLM.ReqLLM.InProcess.{Admission, CleanupOwner, Route}
  alias Loopex.Runtime.ProviderLifetime

  @not_dispatched {:error, {:not_dispatched, "model_call_failed"}}
  @unknown {:error, {:dispatched_or_unknown, "model_call_failed"}}
  @control_ms 1_000

  @doc false
  def complete(request, options) do
    with {:managed, starter} <- ProviderLifetime.starter(),
         {:ok, config} <- options(options),
         {:ok, prepared} <- InProcess.preflight(request, config.base_url),
         true <- prepared.credential_variable == config.credential_variable,
         {:ok, fingerprint} <-
           Route.fingerprint(prepared.provider, prepared.surface, prepared.base_url),
         deadline <-
           Deadline.invocation_deadline(request.deadline, System.time_offset(:native)),
         true <- live?(deadline),
         call_ref <- make_ref(),
         {:ok, _begin_grant} <-
           Admission.request(
             config.module,
             config.handle,
             {:begin_model, self(), call_ref},
             deadline
           ) do
      start(starter, prepared, fingerprint, config, call_ref, deadline)
    else
      _refused -> @not_dispatched
    end
  end

  defp options(options) do
    if Keyword.keyword?(options) do
      with {:ok, {module, owner, generation, cell} = handle} <-
             Keyword.fetch(options, :session_admission),
           true <- is_atom(module) and is_pid(owner) and is_reference(generation),
           true <- is_reference(cell) and Keyword.get(options, :session_cell) == cell,
           {:ok, base_url} <- Keyword.fetch(options, :base_url),
           {:ok, variable} <- Keyword.fetch(options, :credential_variable),
           {:ok, trace} <- Keyword.fetch(options, :trace_capability) do
        {:ok,
         %{
           module: module,
           handle: handle,
           cell: cell,
           base_url: base_url,
           credential_variable: variable,
           trace: trace
         }}
      else
        _invalid -> :error
      end
    else
      :error
    end
  end

  defp start(starter, prepared, fingerprint, config, call_ref, deadline) do
    callback = self()
    start_ref = make_ref()
    start_deadline = min(deadline, control_deadline())

    {proxy, proxy_monitor} =
      spawn_monitor(fn ->
        proxy(callback, starter, start_ref, start_deadline)
      end)

    state = %{
      proxy: proxy,
      proxy_monitor: proxy_monitor,
      proxy_down: false,
      candidate: nil,
      candidate_monitor: nil,
      candidate_down: false,
      start_ref: start_ref,
      start_return: nil
    }

    case await_start(state, :ready, start_deadline) do
      {:ok, state} ->
        send(proxy, {:model_proxy_begin, callback, start_ref})

        case await_start(state, :return, start_deadline) do
          {:ok, %{start_return: {:ok, candidate}, candidate: candidate} = state}
          when is_pid(candidate) ->
            send(proxy, {:model_proxy_finish, callback, start_ref, candidate})

            case await_start(state, :down, start_deadline) do
              {:ok, %{proxy_down: true, candidate_down: false} = proved} ->
                stage(proved, prepared, fingerprint, config, call_ref, deadline)

              {:error, latest} ->
                unknown_start(latest, config.cell)

              {:ok, latest} ->
                unknown_start(latest, config.cell)
            end

          {:ok, %{start_return: {:error, :unavailable}, candidate: nil} = state} ->
            send(proxy, {:model_proxy_finish, callback, start_ref, :not_started})

            case await_start(state, :down, start_deadline) do
              {:ok, %{proxy_down: true, candidate: nil} = proved} ->
                proof =
                  {:model_start_proof, start_ref, proxy, proxy_monitor, :normal, :not_started,
                   {:error, :unavailable}}

                case Admission.request(
                       config.module,
                       config.handle,
                       {:cancel_model, call_ref, proof},
                       deadline
                     ) do
                  {:ok, _grant} -> @not_dispatched
                  _closed -> unknown_start(proved, config.cell)
                end

              {:error, latest} ->
                unknown_start(latest, config.cell)

              {:ok, latest} ->
                unknown_start(latest, config.cell)
            end

          {:error, latest} ->
            unknown_start(latest, config.cell)

          {:ok, latest} ->
            unknown_start(latest, config.cell)
        end

      {:error, latest} ->
        unknown_start(latest, config.cell)
    end
  end

  # Concept: an unlinked proxy moves only the opaque child-start route.
  # Technical depth: its child closure captures four identities, never the
  # request, activation token, options, result, starter or credential.
  defp proxy(callback, starter, start_ref, deadline) do
    callback_monitor = Process.monitor(callback)
    send(callback, {:model_proxy_ready, self(), start_ref})

    receive do
      {:model_proxy_begin, ^callback, ^start_ref} ->
        if live?(deadline) and Process.alive?(callback) do
          proxy_pid = self()

          result =
            ProviderLifetime.start_child(starter, fn ->
              CleanupOwner.run(%{
                callback: callback,
                proxy: proxy_pid,
                start_ref: start_ref,
                deadline: deadline
              })
            end)

          send(callback, {:model_proxy_return, self(), start_ref, result})

          receive do
            {:model_proxy_finish, ^callback, ^start_ref, candidate}
            when is_pid(candidate) and result == {:ok, candidate} ->
              send(candidate, {:proxy_retiring, self(), start_ref})

            {:model_proxy_finish, ^callback, ^start_ref, :not_started}
            when result == {:error, :unavailable} ->
              :ok

            {:DOWN, ^callback_monitor, :process, ^callback, _reason} ->
              :ok
          after
            remaining(deadline) -> :ok
          end
        end

      {:DOWN, ^callback_monitor, :process, ^callback, _reason} ->
        :ok
    after
      remaining(deadline) -> :ok
    end
  end

  defp await_start(state, phase, deadline) do
    if live?(deadline) do
      if start_ready?(state, phase) do
        {:ok, state}
      else
        receive do
          {:model_proxy_ready, proxy, ref}
          when proxy == state.proxy and ref == state.start_ref and phase == :ready ->
            {:ok, state}

          {:model_candidate_ready, candidate, ref, proxy}
          when ref == state.start_ref and proxy == state.proxy and is_pid(candidate) and
                 is_nil(state.candidate) ->
            await_start(
              %{state | candidate: candidate, candidate_monitor: Process.monitor(candidate)},
              phase,
              deadline
            )

          {:model_proxy_return, proxy, ref, result}
          when proxy == state.proxy and ref == state.start_ref and is_nil(state.start_return) ->
            await_start(%{state | start_return: result}, phase, deadline)

          {:DOWN, monitor, :process, proxy, reason}
          when monitor == state.proxy_monitor and proxy == state.proxy ->
            if reason == :normal and phase == :down do
              {:ok, %{state | proxy_down: true}}
            else
              {:error, state}
            end

          {:DOWN, monitor, :process, candidate, _reason}
          when monitor == state.candidate_monitor and candidate == state.candidate ->
            {:error, %{state | candidate_down: true}}
        after
          remaining(deadline) -> {:error, state}
        end
      end
    else
      {:error, state}
    end
  end

  defp start_ready?(state, :return),
    do:
      not is_nil(state.start_return) and
        (state.start_return == {:error, :unavailable} or
           (match?({:ok, _}, state.start_return) and not is_nil(state.candidate)))

  defp start_ready?(%{proxy_down: true}, :down), do: true
  defp start_ready?(_state, _phase), do: false

  defp stage(state, prepared, fingerprint, config, call_ref, deadline) do
    proof_ref = make_ref()
    stop_ref = make_ref()

    proof =
      {:model_start_proof, state.start_ref, state.proxy, state.proxy_monitor, :normal,
       state.candidate, state.candidate_monitor}

    operation =
      {:stage_model, call_ref, state.candidate, proof_ref, stop_ref, proof}

    case Admission.request(config.module, config.handle, operation, deadline) do
      {:ok, {:session_grant, _generation, :stage_model, _callback, staging_ref, _expiry}} ->
        send(state.candidate, {:registration_pending, self(), stop_ref})

        case await_candidate(
               state,
               {:registration_pending_ack, state.candidate, state.start_ref, stop_ref},
               deadline
             ) do
          :ok ->
            register(
              state,
              prepared,
              fingerprint,
              config,
              call_ref,
              deadline,
              proof_ref,
              stop_ref,
              staging_ref
            )

          {:down, reason} ->
            no_registrar(%{state | candidate_down: true}, config, call_ref, staging_ref, reason)

          :timeout ->
            unknown_start(state, config.cell)
        end

      _closed ->
        unknown_start(state, config.cell)
    end
  end

  defp register(
         state,
         prepared,
         fingerprint,
         config,
         call_ref,
         deadline,
         proof_ref,
         stop_ref,
         staging_ref
       ) do
    if Process.alive?(state.candidate) and live?(deadline) do
      registration =
        try do
          ProviderLifetime.register(state.candidate, stop_ref)
        catch
          _, _ -> :registration_failed
        end

      case registration do
        {:managed, retainer, grace} = managed
        when is_pid(retainer) and is_integer(grace) ->
          if grace == Loopex.Executor.default_cleanup_grace_ms() do
            activate(state, prepared, fingerprint, config, call_ref, deadline, proof_ref, managed)
          else
            reap(state, config.cell)
            exit(:provider_lifetime_registration_failed)
          end

        refused
        when refused == :unmanaged or
               refused == {:error, :provider_resource_refused} ->
          registration_refused(state, config, call_ref, refused)

        _failed ->
          reap(state, config.cell)
          exit(:provider_lifetime_registration_failed)
      end
    else
      reason = candidate_reason(state, control_deadline())

      if reason in [:normal, :killed],
        do:
          no_registrar(
            %{state | candidate_down: true},
            config,
            call_ref,
            staging_ref,
            reason
          ),
        else: unknown_start(state, config.cell)
    end
  end

  defp registration_refused(state, config, call_ref, refused) do
    backup = Process.monitor(state.candidate)
    proof = {:registration_refused, refused, state.candidate, state.candidate_monitor}
    deadline = control_deadline()

    outcome =
      Admission.request(
        config.module,
        config.handle,
        {:cancel_model, call_ref, proof},
        deadline
      )

    if match?({:ok, _}, outcome) do
      Process.demonitor(backup, [:flush])
      @not_dispatched
    else
      reap(state, config.cell, backup, deadline)
      @unknown
    end
  end

  defp no_registrar(state, config, call_ref, staging_ref, reason) do
    proof =
      {:registrar_not_entered, staging_ref, state.candidate, state.candidate_monitor, reason}

    case Admission.request(
           config.module,
           config.handle,
           {:cancel_model, call_ref, proof},
           control_deadline()
         ) do
      {:ok, _grant} -> @not_dispatched
      _closed -> unknown_start(state, config.cell)
    end
  end

  defp activate(
         state,
         prepared,
         fingerprint,
         config,
         call_ref,
         deadline,
         proof_ref,
         {:managed, _retainer, _grace} = managed
       ) do
    token = make_ref()
    prepare_ref = make_ref()

    send(state.candidate, {
      :in_process_activation_prepare,
      self(),
      state.start_ref,
      prepare_ref,
      managed,
      token,
      proof_ref,
      config.module,
      config.handle,
      config.cell,
      deadline
    })

    prepared_ack =
      {:in_process_activation_prepared, state.candidate, state.start_ref, prepare_ref}

    if await_candidate(state, prepared_ack, deadline) == :ok do
      case Admission.request(
             config.module,
             config.handle,
             {:register_model, call_ref, state.candidate, proof_ref},
             deadline
           ) do
        {:ok, grant} ->
          begin_ref = make_ref()

          send(state.candidate, {
            :in_process_activation_begin,
            self(),
            state.start_ref,
            begin_ref,
            token,
            grant,
            call_ref,
            prepared.base_url,
            fingerprint,
            config.trace,
            deadline
          })

          begun_ack =
            {:in_process_activation_begun, state.candidate, state.start_ref, begin_ref}

          if await_candidate(state, begun_ack, deadline) == :ok,
            do: await_result(state, prepared, call_ref, deadline),
            else: exit(:in_process_activation_failed)

        _closed ->
          exit(:in_process_activation_failed)
      end
    else
      exit(:in_process_activation_failed)
    end
  end

  defp await_result(state, prepared, call_ref, deadline) do
    receive do
      {:in_process_caller_input_ready, candidate, ^call_ref, caller, input_ref, tag}
      when candidate == state.candidate and is_pid(caller) and is_reference(input_ref) and
             is_reference(tag) ->
        send(caller, {:in_process_caller_input, self(), call_ref, input_ref, prepared})
        await_settled_result(state, call_ref, deadline)

      {:DOWN, monitor, :process, candidate, _reason}
      when monitor == state.candidate_monitor and candidate == state.candidate ->
        exit(:in_process_cleanup_unproved)
    after
      remaining(deadline) ->
        if live?(deadline),
          do: await_result(state, prepared, call_ref, deadline),
          else: exit(:in_process_activation_failed)
    end
  end

  defp await_settled_result(state, call_ref, deadline) do
    receive do
      {:in_process_model_result, candidate, start_ref, ^call_ref, result}
      when candidate == state.candidate and start_ref == state.start_ref ->
        result

      {:DOWN, monitor, :process, candidate, _reason}
      when monitor == state.candidate_monitor and candidate == state.candidate ->
        exit(:in_process_cleanup_unproved)
    after
      remaining(deadline) ->
        if live?(deadline),
          do: await_settled_result(state, call_ref, deadline),
          else: exit(:in_process_model_timeout)
    end
  end

  defp await_candidate(state, expected, deadline) do
    receive do
      ^expected ->
        :ok

      {:DOWN, monitor, :process, candidate, reason}
      when monitor == state.candidate_monitor and candidate == state.candidate ->
        {:down, reason}
    after
      remaining(deadline) ->
        if live?(deadline), do: await_candidate(state, expected, deadline), else: :timeout
    end
  end

  defp candidate_reason(state, deadline) do
    receive do
      {:DOWN, monitor, :process, candidate, reason}
      when monitor == state.candidate_monitor and candidate == state.candidate ->
        reason
    after
      remaining(deadline) -> :unknown
    end
  end

  defp unknown_start(state, cell) do
    reap(state, cell)
    @unknown
  end

  defp reap(state, cell), do: reap(state, cell, nil, control_deadline())

  defp reap(state, cell, backup, deadline) do
    seal(cell)
    if is_pid(state.proxy), do: Process.exit(state.proxy, :kill)
    if is_pid(state.candidate), do: Process.exit(state.candidate, :kill)

    monitors =
      [
        {if(state.proxy_down, do: nil, else: state.proxy_monitor), state.proxy},
        {if(state.candidate_down or backup, do: nil, else: state.candidate_monitor),
         state.candidate},
        {backup, state.candidate}
      ]
      |> Enum.filter(fn {monitor, pid} -> is_reference(monitor) and is_pid(pid) end)

    await_downs(monitors, deadline)
  end

  defp await_downs([], _deadline), do: :ok

  defp await_downs([{monitor, pid} | rest], deadline) do
    receive do
      {:DOWN, ^monitor, :process, ^pid, _reason} ->
        await_downs(rest, deadline)
    after
      remaining(deadline) -> :unproved
    end
  end

  defp seal(cell) do
    if :atomics.get(cell, 1) != 2, do: :atomics.put(cell, 1, 3)
  end

  defp control_deadline,
    do: System.monotonic_time() + System.convert_time_unit(@control_ms, :millisecond, :native)

  defp live?(deadline), do: System.monotonic_time() < deadline

  defp remaining(deadline),
    do: min(@control_ms, Deadline.remaining_timeout(deadline, System.monotonic_time()))
end
