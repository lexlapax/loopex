defmodule LoopexComposition.Ephemeral.ModelCensus do
  @moduledoc false

  alias LoopexComposition.SessionAdmission

  # Concept: one session owner reserves at most one model invocation.
  # Technical depth: these functions run in that owner's receive loop, never
  # another actor. State carries identities and monitor evidence, not requests,
  # model options, credentials or results. Slot two stays set until exact cleanup
  # evidence clears the reservation. Unknown operations fail closed.
  defstruct [:generation, :cell, :pending, :retired, :last_reply]

  def new(generation, cell) when is_reference(generation) and is_reference(cell),
    do: %__MODULE__{generation: generation, cell: cell}

  # Concept: a stopped session cannot claim cleanup while model custody is
  # pending, even if the runtime subtree has already gone down.
  # Technical depth: clear_pending/1 follows the exact resource and registry
  # proofs and clears slot two; neither condition alone is sufficient.
  def settled?(%__MODULE__{pending: nil, cell: cell}), do: :atomics.get(cell, 2) == 0
  def settled?(%__MODULE__{}), do: false

  def handle(
        %__MODULE__{generation: generation} = state,
        {:loopex_session_admission, requester, reference, generation, operation, expiry}
      )
      when is_pid(requester) and is_reference(reference) and is_integer(expiry) do
    envelope = {requester, reference, operation, expiry}

    cond do
      not live_request?(requester, expiry, operation) or not work_allowed?(state, operation) ->
        reply(state, envelope, closed())
        state

      state.pending && state.pending.proof == reference ->
        reply(state, envelope, closed())
        state

      state.last_reply && elem(state.last_reply, 0) == envelope ->
        reply(state, envelope, elem(state.last_reply, 1))
        state

      state.pending && state.pending.stage && elem(state.pending.stage, 0) == envelope ->
        state

      state.pending && state.pending.cancel && state.pending.cancel == envelope ->
        state

      state.pending && MapSet.member?(state.pending.seen_refs, reference) ->
        reply(state, envelope, closed())
        state

      true ->
        transition(state, envelope)
    end
  end

  def handle(
        %__MODULE__{pending: %{callback_monitor: monitor, callback: callback} = pending} = state,
        {:DOWN, monitor, :process, callback, _reason}
      ) do
    cond do
      pending.callback_down ->
        state

      pending.phase in [:active, :retired_wait_down, :unproved] ->
        %{state | pending: %{pending | callback_down: true}}

      true ->
        lost_candidate(%{state | pending: %{pending | callback_down: true}})
    end
  end

  def handle(
        %__MODULE__{
          pending:
            %{
              phase: :staging,
              candidate: candidate,
              proof: proof,
              call: call,
              stage: {envelope, staging_ref}
            } = pending
        } = state,
        {:model_custody_prepared, candidate, staging_ref, generation, call, proof}
      )
      when generation == state.generation do
    if Process.alive?(candidate) do
      pending = %{pending | phase: :provisional, stage: nil}
      state = %{state | pending: pending}

      if live_envelope?(envelope) and pending.callback_down == nil and
           :atomics.get(state.cell, 1) == 0 do
        grant(%{state | pending: %{pending | stage_issued: true}}, envelope)
      else
        state
      end
    else
      # The candidate's already-issued DOWN settles an ungranted staging
      # record, even when its custody acknowledgement reached us first.
      state
    end
  end

  def handle(
        %__MODULE__{pending: %{candidate: candidate, stage_ref: stage_ref} = pending} = state,
        {:model_custody_prepared, reported_candidate, reported_stage_ref, generation, call, proof}
      )
      when is_pid(candidate) and is_reference(stage_ref) and
             (reported_candidate == candidate or reported_stage_ref == stage_ref) do
    if reported_candidate == candidate and reported_stage_ref == stage_ref and
         generation == state.generation and call == pending.call and proof == pending.proof do
      state
    else
      if pending.stage do
        {stage_envelope, _staging_ref} = pending.stage
        reply(state, stage_envelope, closed())
      end

      if pending.cancel, do: reply(state, pending.cancel, closed())
      cancel_timer(pending.timer)
      seal(state.cell)
      %{state | pending: %{pending | phase: :unproved, stage: nil, cancel: nil, timer: nil}}
    end
  end

  def handle(
        %__MODULE__{
          pending: %{candidate_monitor: monitor, candidate: candidate, phase: :staging} = pending
        } = state,
        {:DOWN, monitor, :process, candidate, _reason}
      ) do
    # Concept: no staging acknowledgement means no registrar permission escaped.
    # Technical depth: independent candidate DOWN plus the reconciled start proof
    # settles this empty invocation. Never send its now-stale staging grant.
    {envelope, _staging_ref} = pending.stage
    reply(state, envelope, closed())
    clear_pending(state)
  end

  def handle(
        %__MODULE__{pending: %{candidate_monitor: monitor, candidate: candidate} = pending} =
          state,
        {:DOWN, monitor, :process, candidate, reason}
      ) do
    case pending.phase do
      :retired_wait_down ->
        clear_pending(state)

      phase when phase in [:managed, :active] ->
        state = %{state | pending: %{pending | candidate_down: true}}
        lost_candidate(state)

      :retiring ->
        finish_retirement(%{state | pending: %{pending | candidate_down: true}})

      _ ->
        reason = if reason in [:normal, :killed], do: reason, else: :other

        state =
          %{state | pending: %{pending | candidate_down: true, candidate_down_reason: reason}}

        finish_no_registrar_cancel(state)
    end
  end

  def handle(
        %__MODULE__{pending: %{resource_monitors: monitors} = pending} = state,
        {:DOWN, monitor, :process, pid, _reason}
      )
      when is_map_key(monitors, monitor) do
    if monitors[monitor] == pid do
      pending = %{pending | resource_down: MapSet.put(pending.resource_down, monitor)}
      finish_retirement(%{state | pending: pending})
    else
      state
    end
  end

  def handle(
        %__MODULE__{pending: %{retirement_timer: {_timer, token}} = pending} = state,
        {:model_census_retirement_check, token}
      ) do
    finish_retirement(%{state | pending: %{pending | retirement_timer: nil}})
  end

  def handle(
        %__MODULE__{pending: %{timer: {_timer, token}} = pending} = state,
        {:model_census_lost_callback, token}
      ) do
    seal(state.cell)
    %{state | pending: %{pending | phase: :unproved, timer: nil}}
  end

  def handle(state, _message), do: state

  defp transition(
         %__MODULE__{pending: nil} = state,
         {requester, _reference, {:begin_model, requester, call}, _expiry} = envelope
       )
       when is_reference(call) do
    if :atomics.get(state.cell, 1) == 0 and call != state.retired do
      pending = %{
        phase: :begun,
        call: call,
        callback: requester,
        callback_monitor: Process.monitor(requester),
        callback_down: nil,
        timer: nil,
        candidate: nil,
        candidate_monitor: nil,
        candidate_down: false,
        candidate_down_reason: nil,
        start_ref: nil,
        proxy: nil,
        proxy_monitor: nil,
        candidate_start_monitor: nil,
        proof: nil,
        stop_ref: nil,
        stage: nil,
        stage_ref: nil,
        stage_issued: false,
        cancel: nil,
        revision: 0,
        last_resource_entries: nil,
        resources: %{},
        resource_monitors: %{},
        resource_down: MapSet.new(),
        registries: %{},
        retirement: nil,
        retirement_timer: nil,
        seen_refs: MapSet.new([elem(envelope, 1)])
      }

      :atomics.put(state.cell, 2, 1)
      grant(%{state | pending: pending, last_reply: nil}, envelope)
    else
      refuse(state, envelope)
    end
  end

  defp transition(
         %__MODULE__{pending: %{phase: :begun, callback: requester, call: call} = pending} = state,
         {requester, _reference,
          {:stage_model, call, candidate, proof, stop_ref,
           {:model_start_proof, start_ref, proxy, proxy_monitor, :normal, candidate,
            candidate_monitor}}, expiry} = envelope
       )
       when is_pid(candidate) and is_pid(proxy) and is_reference(proof) and
              is_reference(stop_ref) and is_reference(start_ref) and
              is_reference(proxy_monitor) and is_reference(candidate_monitor) do
    if proof != elem(envelope, 1) and not MapSet.member?(pending.seen_refs, proof) and
         distinct_start?(
           requester,
           candidate,
           proxy,
           proof,
           stop_ref,
           start_ref,
           proxy_monitor,
           candidate_monitor
         ) do
      # The callback needs the stage identity for a later pre-registrar
      # cancellation. Reuse its fresh admission request reference, which the
      # correlated grant returns, rather than minting an undisclosed reference.
      staging_ref = elem(envelope, 1)
      custody = {:model_cleanup_custody, self(), state.generation, call, candidate, proof}

      pending = %{
        pending
        | phase: :staging,
          candidate: candidate,
          candidate_monitor: Process.monitor(candidate),
          proof: proof,
          stop_ref: stop_ref,
          start_ref: start_ref,
          proxy: proxy,
          proxy_monitor: proxy_monitor,
          candidate_start_monitor: candidate_monitor,
          stage: {envelope, staging_ref},
          stage_ref: staging_ref,
          seen_refs: MapSet.put(pending.seen_refs, elem(envelope, 1))
      }

      # The session owner supplies its own private admission implementation.
      # The callback's start proof identifies the candidate, not the route.
      send(
        candidate,
        {:model_custody_prepare, start_ref, staging_ref, expiry, SessionAdmission, custody}
      )

      %{state | pending: pending, last_reply: nil}
    else
      refuse(state, envelope)
    end
  end

  defp transition(
         %__MODULE__{
           pending:
             %{
               phase: :provisional,
               callback: requester,
               call: call,
               candidate: candidate,
               proof: proof,
               callback_down: nil
             } = pending
         } = state,
         {requester, _reference, {:register_model, call, candidate, proof}, _expiry} = envelope
       ) do
    if pending.stage_issued and Process.alive?(candidate) and not pending.candidate_down do
      pending = %{
        pending
        | phase: :managed,
          seen_refs: MapSet.put(pending.seen_refs, elem(envelope, 1))
      }

      grant(%{state | pending: pending}, envelope)
    else
      refuse(state, envelope)
    end
  end

  defp transition(
         %__MODULE__{pending: %{phase: :begun, callback: requester, call: call}} = state,
         {requester, _reference, {:cancel_model, call, :no_proxy}, _expiry} = envelope
       ) do
    grant(clear_pending(state), envelope)
  end

  defp transition(
         %__MODULE__{
           pending:
             %{
               phase: :provisional,
               callback: requester,
               call: call,
               candidate: candidate,
               candidate_start_monitor: candidate_monitor,
               stage_ref: stage_ref,
               stage_issued: true,
               callback_down: nil,
               cancel: nil
             } = pending
         } = state,
         {requester, _reference,
          {:cancel_model, call,
           {:registrar_not_entered, stage_ref, candidate, candidate_monitor, reason}}, _expiry} =
           envelope
       )
       when reason in [:normal, :killed] do
    if Process.alive?(requester) and
         (not pending.candidate_down or pending.candidate_down_reason == reason) do
      state =
        %{
          state
          | pending: %{
              pending
              | phase: :cancelling,
                cancel: envelope,
                seen_refs: MapSet.put(pending.seen_refs, elem(envelope, 1))
            }
        }

      finish_no_registrar_cancel(state)
    else
      refuse(state, envelope)
    end
  end

  defp transition(
         %__MODULE__{
           pending:
             %{
               phase: :provisional,
               callback: requester,
               call: call,
               candidate: candidate,
               candidate_start_monitor: candidate_monitor,
               stage_issued: true,
               callback_down: nil,
               cancel: nil
             } = pending
         } = state,
         {requester, reference,
          {:cancel_model, call,
           {:registration_refused, registration, candidate, candidate_monitor}} = operation,
          expiry} = envelope
       )
       when registration == :unmanaged or
              registration == {:error, :provider_resource_refused} do
    pending = %{
      pending
      | phase: :cancelling,
        cancel: envelope,
        seen_refs: MapSet.put(pending.seen_refs, reference)
    }

    state = %{state | pending: pending}

    send(
      requester,
      {:loopex_session_admission_cancellation_prepared, self(), reference, state.generation,
       operation, expiry, candidate}
    )

    finish_no_registrar_cancel(state)
  end

  defp transition(
         %__MODULE__{pending: %{phase: :begun, callback: requester, call: call}} = state,
         {requester, _reference,
          {:cancel_model, call,
           {:model_start_proof, start_ref, proxy, proxy_monitor, :normal, :not_started,
            {:error, :unavailable}}}, _expiry} = envelope
       )
       when is_reference(start_ref) and is_pid(proxy) and is_reference(proxy_monitor) do
    # The callback owns this proxy monitor and attests its exact normal DOWN.
    # The owner's independent check is that the reported proxy is no longer
    # live; only the starter's authoritative no-child return can close the slot.
    if proxy != requester and not Process.alive?(proxy) do
      grant(clear_pending(state), envelope)
    else
      refuse(state, envelope)
    end
  end

  defp transition(
         %__MODULE__{
           pending: %{phase: phase, candidate: requester, call: call} = pending
         } = state,
         {requester, reference, {:record_model_resources, call, requester, revision, entries},
          _expiry} = envelope
       )
       when phase in [:managed, :active] do
    cond do
      revision == pending.revision and entries == pending.last_resource_entries ->
        pending = %{pending | seen_refs: MapSet.put(pending.seen_refs, reference)}
        grant(%{state | pending: pending}, envelope)

      revision == pending.revision and entries != pending.last_resource_entries ->
        seal_record(state, envelope)

      revision == pending.revision + 1 and valid_resource_entries?(pending, entries) ->
        pending = retain_resource_entries(pending, entries)

        pending = %{
          pending
          | phase: :active,
            revision: revision,
            last_resource_entries: entries,
            seen_refs: MapSet.put(pending.seen_refs, reference)
        }

        grant(%{state | pending: pending}, envelope)

      true ->
        refuse(state, envelope)
    end
  end

  defp transition(
         %__MODULE__{
           pending: %{phase: phase, call: call, candidate: requester, proof: proof} = pending
         } = state,
         {requester, _reference, {:retire_model, call, requester, proof}, _expiry} = envelope
       )
       when phase in [:staging, :provisional, :managed, :active] do
    if pending.stage do
      {stage_envelope, _staging_ref} = pending.stage
      reply(state, stage_envelope, closed())
    end

    cancel_timer(pending.timer)

    pending = %{
      pending
      | phase: :retiring,
        stage: nil,
        timer: nil,
        retirement: envelope,
        seen_refs: MapSet.put(pending.seen_refs, elem(envelope, 1))
    }

    finish_retirement(%{state | pending: pending})
  end

  defp transition(state, envelope), do: refuse(state, envelope)

  defp grant(state, {requester, reference, operation, expiry} = envelope) do
    result =
      {:ok, {:session_grant, state.generation, elem(operation, 0), requester, reference, expiry}}

    reply(state, envelope, result)
    %{state | last_reply: {envelope, result}}
  end

  defp refuse(state, envelope) do
    reply(state, envelope, closed())
    state
  end

  defp reply(state, {requester, reference, operation, expiry}, result) do
    send(
      requester,
      {:loopex_session_admission_result, self(), reference, state.generation, operation, expiry,
       result}
    )
  end

  defp live_request?(requester, expiry, operation) do
    now = System.monotonic_time()

    (cleanup_operation?(operation) or Process.alive?(requester)) and expiry > now and
      expiry <= now + System.convert_time_unit(1_000, :millisecond, :native)
  end

  # Concept: a reply replay never revives closed work authority.
  # Technical depth: validate lifecycle before consulting the correlated cache;
  # cleanup completion remains admissible while the session is stopping or sealed.
  defp work_allowed?(state, {:begin_model, _, _}), do: :atomics.get(state.cell, 1) == 0
  defp work_allowed?(state, {:register_model, _, _, _}), do: :atomics.get(state.cell, 1) == 0
  defp work_allowed?(_state, _operation), do: true

  defp cleanup_operation?({:stage_model, _, _, _, _, _}), do: true
  defp cleanup_operation?({:cancel_model, _, _}), do: true
  defp cleanup_operation?({:retire_model, _, _, _}), do: true
  defp cleanup_operation?(_), do: false

  defp live_envelope?({requester, _reference, operation, expiry}),
    do: live_request?(requester, expiry, operation)

  defp distinct_start?(
         callback,
         candidate,
         proxy,
         proof,
         stop_ref,
         start_ref,
         proxy_monitor,
         candidate_monitor
       ) do
    callback != candidate and callback != proxy and candidate != proxy and
      proof != stop_ref and proof != start_ref and stop_ref != start_ref and
      proxy_monitor != candidate_monitor
  end

  @process_roles [:root, :anonymous_supervisor, :pool_supervisor, :http1_worker, :caller]
  @registry_kinds [:worker, :supervisor]

  defp valid_resource_entries?(pending, entries) when is_list(entries) and entries != [] do
    length(entries) <= 7 and
      Enum.reduce_while(entries, {pending.resources, pending.registries}, fn entry,
                                                                             {processes,
                                                                              registries} ->
        case entry do
          {:process, role, pid} when role in @process_roles and is_pid(pid) ->
            cond do
              Map.has_key?(processes, role) ->
                {:halt, :invalid}

              Enum.any?(processes, fn {other, known} -> other != role and known == pid end) ->
                {:halt, :invalid}

              true ->
                {:cont, {Map.put(processes, role, pid), registries}}
            end

          {:registry, kind, {scheme, host, port, tag} = identity}
          when kind in @registry_kinds and scheme in [:http, :https] and is_binary(host) and
                 byte_size(host) in 1..253 and is_integer(port) and port in 1..65_535 and
                 is_reference(tag) ->
            cond do
              Map.has_key?(registries, kind) ->
                {:halt, :invalid}

              Enum.any?(registries, fn {_other, known} -> known != identity end) ->
                {:halt, :invalid}

              true ->
                {:cont, {processes, Map.put(registries, kind, identity)}}
            end

          _invalid ->
            {:halt, :invalid}
        end
      end) != :invalid
  end

  defp valid_resource_entries?(_pending, _entries), do: false

  defp retain_resource_entries(pending, entries) do
    Enum.reduce(entries, pending, fn
      {:process, role, pid}, pending ->
        if Map.has_key?(pending.resources, role) do
          pending
        else
          monitor = Process.monitor(pid)

          %{
            pending
            | resources: Map.put(pending.resources, role, pid),
              resource_monitors: Map.put(pending.resource_monitors, monitor, pid)
          }
        end

      {:registry, kind, identity}, pending ->
        %{pending | registries: Map.put(pending.registries, kind, identity)}
    end)
  end

  defp finish_retirement(%{pending: %{phase: :retiring, retirement: envelope} = pending} = state) do
    cond do
      not live_envelope?(envelope) ->
        fail_retirement(state)

      (pending.candidate_down or Process.alive?(pending.candidate)) and
        resource_down?(pending) and registries_empty?(pending.registries) ->
        cancel_timer(pending.retirement_timer)

        if pending.candidate_down do
          reply(state, envelope, {:ok, retirement_grant(state, envelope)})
          clear_pending(state)
        else
          pending = %{pending | phase: :retired_wait_down, retirement: nil, retirement_timer: nil}
          grant(%{state | pending: pending}, envelope)
        end

      true ->
        schedule_retirement(state)
    end
  end

  defp finish_retirement(state), do: state

  defp retirement_grant(state, {requester, reference, operation, expiry}) do
    {:session_grant, state.generation, elem(operation, 0), requester, reference, expiry}
  end

  defp resource_down?(pending),
    do: map_size(pending.resource_monitors) == MapSet.size(pending.resource_down)

  defp registries_empty?(registries) do
    Enum.all?(registries, fn
      {:worker, identity} -> Registry.lookup(Req.Finch, identity) == []
      {:supervisor, identity} -> Registry.lookup(Req.Finch.SupervisorRegistry, identity) == []
    end)
  rescue
    _error -> false
  catch
    _kind, _reason -> false
  end

  defp schedule_retirement(
         %{pending: %{retirement_timer: nil, retirement: envelope} = pending} = state
       ) do
    {_requester, _reference, _operation, expiry} = envelope
    native_per_ms = System.convert_time_unit(1, :millisecond, :native)
    remaining = max(expiry - System.monotonic_time(), 0)
    delay = max(1, min(10, div(remaining + native_per_ms - 1, native_per_ms)))
    token = make_ref()
    timer = Process.send_after(self(), {:model_census_retirement_check, token}, delay)
    %{state | pending: %{pending | retirement_timer: {timer, token}}}
  end

  defp schedule_retirement(state), do: state

  defp fail_retirement(%{pending: %{retirement: envelope} = pending} = state) do
    reply(state, envelope, closed())
    cancel_timer(pending.retirement_timer)
    seal(state.cell)
    %{state | pending: %{pending | phase: :unproved, retirement: nil, retirement_timer: nil}}
  end

  defp seal_record(%{pending: pending} = state, envelope) do
    reply(state, envelope, closed())
    cancel_timer(pending.timer)
    cancel_timer(pending.retirement_timer)
    seal(state.cell)
    %{state | pending: %{pending | phase: :unproved, timer: nil, retirement_timer: nil}}
  end

  defp clear_pending(%{pending: pending} = state) do
    Process.demonitor(pending.callback_monitor, [:flush])
    if pending.candidate_monitor, do: Process.demonitor(pending.candidate_monitor, [:flush])
    Enum.each(Map.keys(pending.resource_monitors), &Process.demonitor(&1, [:flush]))
    cancel_timer(pending.timer)
    cancel_timer(pending.retirement_timer)
    :atomics.put(state.cell, 2, 0)
    %{state | pending: nil, retired: pending.call, last_reply: nil}
  end

  defp lost_candidate(%{pending: %{timer: nil} = pending} = state) do
    token = make_ref()
    native_per_ms = System.convert_time_unit(1, :millisecond, :native)

    milliseconds =
      case pending.cancel do
        {_requester, _reference, _operation, expiry} ->
          remaining = max(0, expiry - System.monotonic_time())
          min(1_000, div(remaining + native_per_ms - 1, native_per_ms))

        nil ->
          1_000
      end

    timer = Process.send_after(self(), {:model_census_lost_callback, token}, milliseconds)
    %{state | pending: %{pending | timer: {timer, token}}}
  end

  defp lost_candidate(state), do: state

  defp finish_no_registrar_cancel(
         %__MODULE__{
           pending: %{
             phase: :cancelling,
             cancel:
               {_callback, _reference,
                {:cancel_model, _call,
                 {:registrar_not_entered, _stage_ref, _candidate, _monitor, reason}}, _expiry} =
                 envelope,
             candidate_down: true,
             candidate_down_reason: reason
           }
         } = state
       ) do
    if live_envelope?(envelope) do
      grant(clear_pending(state), envelope)
    else
      lost_candidate(state)
    end
  end

  defp finish_no_registrar_cancel(
         %__MODULE__{
           pending: %{
             phase: :cancelling,
             cancel:
               {_callback, _reference,
                {:cancel_model, _call, {:registration_refused, _result, _candidate, _monitor}},
                _expiry} = envelope,
             candidate_down: true
           }
         } = state
       ) do
    if live_envelope?(envelope) do
      grant(clear_pending(state), envelope)
    else
      lost_candidate(state)
    end
  end

  defp finish_no_registrar_cancel(
         %__MODULE__{
           pending:
             %{
               phase: :cancelling,
               cancel: envelope,
               candidate_down: true
             } = pending
         } = state
       ) do
    reply(state, envelope, closed())
    lost_candidate(%{state | pending: %{pending | phase: :provisional, cancel: nil}})
  end

  defp finish_no_registrar_cancel(state), do: lost_candidate(state)

  defp cancel_timer(nil), do: :ok
  defp cancel_timer({timer, _token}), do: Process.cancel_timer(timer)
  defp seal(cell), do: if(:atomics.get(cell, 1) != 2, do: :atomics.put(cell, 1, 3))
  defp closed, do: {:error, :session_admission_closed}
end
