defmodule Loopex.LLM.ReqLLM.InProcess.CleanupOwner do
  @moduledoc """
  ## Concept

  A managed provider start first creates an inert cleanup-owner candidate. It
  carries no request, credential, pool, caller or dispatch authority.

  ## Technical depth

  This checkpoint proves the actual Task.Supervisor parent, callback and proxy
  identities, then accepts at most one cleanup-only census custody message.
  It acknowledges custody only after the proxy's exact normal retirement.
  Registration pending acknowledges only the original callback's first exact
  stop reference after that custody acknowledgement; it grants no work.
  Retirement and core-stop acknowledgement require a host admission route that
  the accepted four-field candidate constructor does not yet provide; neither
  is implemented here. A staged candidate whose callback dies stays inert for
  subtree teardown rather than claiming an unrecorded retirement.
  """

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
          registration_pending: nil
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
    remaining =
      case state.custody do
        {_, _, _, _, _, :acked} -> :infinity
        _ -> remaining_ms(state.deadline)
      end

    if remaining == 0 do
      :ok
    else
      receive do
        {:proxy_retiring, proxy, ref}
        when proxy == state.proxy and ref == state.start_ref and
               not state.proxy_retiring and not state.proxy_down ->
          state |> Map.put(:proxy_retiring, true) |> maybe_ack_custody() |> loop()

        {:DOWN, mon, :process, proxy, :normal}
        when mon == state.proxy_mon and proxy == state.proxy and state.proxy_retiring ->
          state |> Map.put(:proxy_down, true) |> maybe_ack_custody() |> loop()

        {:DOWN, mon, :process, proxy, _}
        when mon == state.proxy_mon and proxy == state.proxy ->
          :ok

        {:DOWN, mon, :process, callback, _}
        when mon == state.callback_mon and callback == state.callback ->
          # Concept: staged custody survives callback death for a later proved
          # retirement; no missing host route can be replaced by a local ACK.
          # Technical depth: keep the inert candidate alive for subtree removal.
          if state.custody, do: loop(Map.put(state, :callback, nil)), else: :ok

        {:DOWN, mon, :process, parent, _}
        when mon == state.parent_mon and parent == state.parent ->
          :ok

        {:DOWN, mon, :process, owner, _}
        when mon == state.owner_mon and not is_nil(state.custody) and
               owner == elem(state.custody, 0) ->
          :ok

        {:model_custody_prepare, ref, staging_ref, expiry,
         {:model_cleanup_custody, owner, generation, call_ref, candidate, proof_ref}}
        when ref == state.start_ref and is_nil(state.custody) and is_reference(staging_ref) and
               is_integer(expiry) and is_pid(owner) and is_reference(generation) and
               is_reference(call_ref) and candidate == self() and is_reference(proof_ref) ->
          if live_deadline?(expiry) and live?(owner) and state.callback != nil do
            owner_mon = Process.monitor(owner)

            state
            |> Map.put(:custody, {owner, staging_ref, generation, call_ref, proof_ref})
            |> Map.put(:owner_mon, owner_mon)
            |> maybe_ack_custody()
            |> loop()
          else
            loop(state)
          end

        {:registration_pending, callback, stop_ref}
        when callback == state.callback and is_reference(stop_ref) and
               tuple_size(state.custody) == 6 and elem(state.custody, 5) == :acked and
               state.proxy_down and
               is_nil(state.registration_pending) ->
          send(callback, {:registration_pending_ack, self(), state.start_ref, stop_ref})
          loop(Map.put(state, :registration_pending, stop_ref))

        _ ->
          loop(state)
      after
        remaining -> :ok
      end
    end
  end

  defp maybe_ack_custody(
         %{custody: {owner, staging, generation, call_ref, proof_ref}, proxy_down: true} = state
       ) do
    if live_deadline?(state.deadline) do
      send(owner, {:model_custody_prepared, self(), staging, generation, call_ref, proof_ref})
      Map.put(state, :custody, {owner, staging, generation, call_ref, proof_ref, :acked})
    else
      state
    end
  end

  defp maybe_ack_custody(state), do: state

  defp live?(pid), do: Process.alive?(pid)
  defp live_deadline?(deadline), do: System.monotonic_time() < deadline

  defp remaining_ms(deadline) do
    native = deadline - System.monotonic_time()

    if native <= 0 do
      0
    else
      min(1_000, max(1, System.convert_time_unit(native, :native, :millisecond)))
    end
  end
end
