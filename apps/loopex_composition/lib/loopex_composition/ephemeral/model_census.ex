defmodule LoopexComposition.Ephemeral.ModelCensus do
  @moduledoc false

  # Concept: one session owner reserves at most one model invocation.
  # Technical depth: these functions run in that owner's receive loop, never
  # another actor. State carries identities and monitor evidence, not requests,
  # model options, credentials or results. Slot two stays set until exact cleanup
  # evidence clears the reservation. Unknown operations fail closed.
  defstruct [:generation, :cell, :pending, :retired, :last_reply]

  def new(generation, cell) when is_reference(generation) and is_reference(cell),
    do: %__MODULE__{generation: generation, cell: cell}

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

      state.last_reply && elem(state.last_reply, 0) == envelope ->
        reply(state, envelope, elem(state.last_reply, 1))
        state

      state.pending && state.pending.stage && elem(state.pending.stage, 0) == envelope ->
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
        {:DOWN, monitor, :process, candidate, _reason}
      ) do
    case pending.phase do
      :retired_wait_down -> clear_pending(state)
      _ -> lost_candidate(%{state | pending: %{pending | candidate_down: true}})
    end
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
        start_ref: nil,
        proxy: nil,
        proxy_monitor: nil,
        candidate_start_monitor: nil,
        proof: nil,
        stop_ref: nil,
        stage: nil,
        stage_ref: nil,
        stage_issued: false,
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
    if distinct_start?(
         requester,
         candidate,
         proxy,
         proof,
         stop_ref,
         start_ref,
         proxy_monitor,
         candidate_monitor
       ) do
      staging_ref = make_ref()
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

      send(candidate, {:model_custody_prepare, start_ref, staging_ref, expiry, custody})
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
           pending: %{phase: phase, call: call, candidate: requester, proof: proof} = pending
         } = state,
         {requester, _reference, {:retire_model, call, requester, proof}, _expiry} = envelope
       )
       when phase in [:staging, :provisional, :managed] do
    if pending.stage do
      {stage_envelope, _staging_ref} = pending.stage
      reply(state, stage_envelope, closed())
    end

    cancel_timer(pending.timer)

    pending = %{
      pending
      | phase: :retired_wait_down,
        stage: nil,
        timer: nil,
        seen_refs: MapSet.put(pending.seen_refs, elem(envelope, 1))
    }

    state = grant(%{state | pending: pending}, envelope)
    if pending.candidate_down, do: clear_pending(state), else: state
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

  defp clear_pending(%{pending: pending} = state) do
    Process.demonitor(pending.callback_monitor, [:flush])
    if pending.candidate_monitor, do: Process.demonitor(pending.candidate_monitor, [:flush])
    cancel_timer(pending.timer)
    :atomics.put(state.cell, 2, 0)
    %{state | pending: nil, retired: pending.call, last_reply: nil}
  end

  defp lost_candidate(%{pending: %{timer: nil} = pending} = state) do
    token = make_ref()
    timer = Process.send_after(self(), {:model_census_lost_callback, token}, 1_000)
    %{state | pending: %{pending | timer: {timer, token}}}
  end

  defp lost_candidate(state), do: state

  defp cancel_timer(nil), do: :ok
  defp cancel_timer({timer, _token}), do: Process.cancel_timer(timer)
  defp seal(cell), do: if(:atomics.get(cell, 1) != 2, do: :atomics.put(cell, 1, 3))
  defp closed, do: {:error, :session_admission_closed}
end
