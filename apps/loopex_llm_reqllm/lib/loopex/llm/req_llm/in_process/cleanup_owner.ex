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
  teardown and core-stop acknowledgement are separate later transitions.
  """

  alias Loopex.LLM.ReqLLM.InProcess.Admission

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
          retired: false
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
      if state.cleanup_attempted or (state.custody && state.custody.acked) do
        :infinity
      else
        remaining_ms(state.deadline)
      end

    if remaining == 0 do
      if state.custody, do: retire_empty(state)
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
          if state.custody do
            state = state |> Map.put(:callback, nil) |> retire_empty()

            if state.retired and is_nil(state.registration_pending),
              do: :ok,
              else: loop(state)
          else
            :ok
          end

        {:DOWN, mon, :process, parent, _}
        when mon == state.parent_mon and parent == state.parent ->
          :ok

        {:DOWN, mon, :process, owner, _}
        when mon == state.owner_mon and not is_nil(state.custody) and
               owner == state.custody.owner ->
          :ok

        {:model_custody_prepare, ref, staging_ref, expiry, module,
         {:model_cleanup_custody, owner, generation, call_ref, candidate, proof_ref}}
        when ref == state.start_ref and is_nil(state.custody) and is_reference(staging_ref) and
               is_integer(expiry) and is_pid(owner) and is_reference(generation) and
               is_reference(call_ref) and candidate == self() and is_reference(proof_ref) ->
          if valid_module?(module) and live_deadline?(expiry) and live?(owner) and
               state.callback != nil do
            owner_mon = Process.monitor(owner)

            handle =
              {:model_cleanup_custody, owner, generation, call_ref, candidate, proof_ref}

            state
            |> Map.put(:custody, %{
              module: module,
              handle: handle,
              owner: owner,
              staging: staging_ref,
              generation: generation,
              call: call_ref,
              proof: proof_ref,
              acked: false
            })
            |> Map.put(:owner_mon, owner_mon)
            |> maybe_ack_custody()
            |> loop()
          else
            loop(state)
          end

        {:registration_pending, callback, stop_ref}
        when callback == state.callback and is_reference(stop_ref) and
               not is_nil(state.custody) and state.custody.acked and
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

  defp maybe_ack_custody(%{custody: %{acked: false} = custody, proxy_down: true} = state) do
    if live_deadline?(state.deadline) and not state.cleanup_attempted and
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
  defp retire_empty(%{custody: custody, cleanup_attempted: false} = state) do
    deadline =
      System.monotonic_time() + System.convert_time_unit(1_000, :millisecond, :native)

    operation = {:retire_model, custody.call, self(), custody.proof}

    retired =
      match?(
        {:ok, {:session_grant, _, :retire_model, _, _, _}},
        Admission.request(custody.module, custody.handle, operation, deadline)
      )

    %{state | cleanup_attempted: true, retired: retired}
  end

  defp retire_empty(state), do: state

  defp valid_module?(module),
    do: is_atom(module) and function_exported?(module, :request, 3)

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
