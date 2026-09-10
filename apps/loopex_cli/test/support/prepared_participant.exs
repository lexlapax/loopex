defmodule LoopexCli.PreparedParticipantFixture do
  @moduledoc false

  # This participant knows only the documented local messages and a holder
  # function. It never inspects the activation or imports the CLI handler.
  def start(preparer, observer, holder_fun, mode \\ :automatic) do
    nonce = make_ref()
    starter = self()

    guard =
      spawn(fn ->
        Process.flag(:trap_exit, true)
        preparer_ref = Process.monitor(preparer)
        {holder, holder_ref} = :erlang.spawn_opt(holder_fun, [:link, :monitor])
        send(starter, {:participant_started, self(), holder, nonce})

        state = %{
          preparer: preparer,
          preparer_ref: preparer_ref,
          holder: holder,
          holder_ref: holder_ref,
          observer: observer,
          nonce: nonce,
          coordinator: nil,
          coordinator_ref: nil,
          handoff: nil,
          prepare: nil,
          pending: false,
          ready: false,
          verdict: nil,
          mode: mode
        }

        if mode == :prepare_first do
          receive do
            {:loopex_prepared_owner_prepare, coordinator, ^holder, ^nonce, handoff, prepare} ->
              send(observer, {:prepare_received_first, self()})
              loop(%{state | prepare: {coordinator, handoff, prepare}})

            {:DOWN, ^preparer_ref, :process, ^preparer, _reason} ->
              Process.exit(holder, :kill)

            {:DOWN, ^holder_ref, :process, ^holder, _reason} ->
              :ok
          end
        else
          loop(state)
        end
      end)

    receive do
      {:participant_started, ^guard, holder, ^nonce} -> {guard, holder, nonce}
    end
  end

  defp loop(state) do
    %{
      preparer: preparer,
      preparer_ref: preparer_ref,
      holder: holder,
      holder_ref: holder_ref,
      nonce: nonce,
      coordinator: coordinator,
      coordinator_ref: coordinator_ref,
      handoff: handoff
    } = state

    receive do
      {:loopex_prepared_transfer_pending, ^preparer, owner, ^holder, ^nonce, call}
      when not state.pending ->
        next = %{
          state
          | coordinator: owner,
            coordinator_ref: Process.monitor(owner),
            handoff: call,
            pending: true
        }

        loop(ready(next))

      {:loopex_prepared_owner_prepare, owner, ^holder, ^nonce, call, prepare}
      when not state.ready ->
        loop(ready(%{state | prepare: {owner, call, prepare}}))

      {:loopex_prepared_owner_verdict, ^coordinator, ^holder, ^nonce, ^handoff, verdict_ref,
       :committed}
      when state.ready and is_nil(state.verdict) ->
        Process.demonitor(preparer_ref, [:flush])
        send(state.observer, {:participant_linearized, self()})
        next = %{state | preparer_ref: nil, verdict: {verdict_ref, :committed}}
        loop(if state.mode == :hold_ack, do: next, else: acknowledge(next))

      {:loopex_prepared_owner_verdict, ^coordinator, ^holder, ^nonce, ^handoff, verdict_ref,
       {:refused, _reason} = verdict}
      when state.ready and is_nil(state.verdict) ->
        Process.exit(holder, :kill)
        acknowledge(%{state | verdict: {verdict_ref, verdict}})
        send(state.observer, {:participant_refused, self(), verdict})

      :acknowledge when state.mode == :hold_ack ->
        loop(acknowledge(state))

      :release_ready when state.mode == :await_ready_release ->
        loop(ready(%{state | mode: :automatic}))

      {:loopex_prepared_owner_discard, ^coordinator, ^holder, ^nonce, ^handoff}
      when state.pending ->
        Process.exit(holder, :kill)

      {:loopex_prepared_guard_released, ^coordinator} when state.pending ->
        send(state.observer, {:participant_released, self()})

      {:DOWN, ^preparer_ref, :process, ^preparer, _reason} when is_reference(preparer_ref) ->
        if state.pending do
          send(
            coordinator,
            {:loopex_prepared_transfer_installer_lost, self(), preparer, holder, nonce, handoff}
          )
        end

        Process.exit(holder, :kill)

      {:DOWN, ^coordinator_ref, :process, ^coordinator, _reason}
      when is_reference(coordinator_ref) ->
        Process.exit(holder, :kill)

      {:DOWN, ^holder_ref, :process, ^holder, _reason} ->
        :ok

      _mismatched ->
        loop(state)
    end
  end

  defp ready(%{mode: :await_ready_release} = state), do: state

  defp ready(
         %{
           pending: true,
           ready: false,
           coordinator: coordinator,
           handoff: handoff,
           prepare: {coordinator, handoff, prepare}
         } = state
       ) do
    if state.mode == :hold_ready do
      send(state.observer, {:participant_ready_held, self(), state.holder})
      %{state | mode: :await_ready_release}
    else
      send(
        coordinator,
        {:loopex_prepared_transfer_guard_ready, self(), state.holder, state.nonce, handoff,
         prepare}
      )

      %{state | ready: true}
    end
  end

  defp ready(state), do: state

  defp acknowledge(%{verdict: {reference, verdict}} = state) do
    send(
      state.coordinator,
      {:loopex_prepared_owner_verdict_ack, self(), state.holder, state.nonce, state.handoff,
       reference, verdict}
    )

    state
  end
end
