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
      not live_request?(requester, expiry) or not work_allowed?(state, operation) ->
        reply(state, envelope, closed())
        state

      state.last_reply && elem(state.last_reply, 0) == envelope ->
        reply(state, envelope, elem(state.last_reply, 1))
        state

      true ->
        transition(state, envelope)
    end
  end

  def handle(
        %__MODULE__{pending: %{callback_monitor: monitor, callback: callback} = pending} = state,
        {:DOWN, monitor, :process, callback, _reason}
      ) do
    token = make_ref()
    timer = Process.send_after(self(), {:model_census_lost_callback, token}, 1_000)
    %{state | pending: Map.merge(pending, %{callback_down: true, timer: {timer, token}})}
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
        timer: nil
      }

      :atomics.put(state.cell, 2, 1)
      grant(%{state | pending: pending, last_reply: nil}, envelope)
    else
      refuse(state, envelope)
    end
  end

  defp transition(
         %__MODULE__{pending: %{phase: :begun, callback: requester, call: call} = pending} = state,
         {requester, _reference, {:cancel_model, call, :no_proxy}, _expiry} = envelope
       ) do
    Process.demonitor(pending.callback_monitor, [:flush])
    cancel_timer(pending.timer)
    :atomics.put(state.cell, 2, 0)
    grant(%{state | pending: nil, retired: call, last_reply: nil}, envelope)
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

  defp live_request?(requester, expiry) do
    now = System.monotonic_time()

    Process.alive?(requester) and expiry > now and
      expiry <= now + System.convert_time_unit(1_000, :millisecond, :native)
  end

  # Concept: a reply replay never revives closed work authority.
  # Technical depth: validate lifecycle before consulting the correlated cache;
  # cleanup completion remains admissible while the session is stopping or sealed.
  defp work_allowed?(state, {:begin_model, _, _}), do: :atomics.get(state.cell, 1) == 0
  defp work_allowed?(_state, _operation), do: true

  defp cancel_timer(nil), do: :ok
  defp cancel_timer({timer, _token}), do: Process.cancel_timer(timer)
  defp seal(cell), do: if(:atomics.get(cell, 1) != 2, do: :atomics.put(cell, 1, 3))
  defp closed, do: {:error, :session_admission_closed}
end
