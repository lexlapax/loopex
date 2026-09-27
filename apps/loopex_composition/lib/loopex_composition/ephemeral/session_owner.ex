defmodule LoopexComposition.Ephemeral.SessionOwner do
  @moduledoc """
  ## Concept

  Holds one ephemeral session's lifecycle, but does no session work before its
  creator completes owner activation and supplies a one-use begin token.

  ## Technical depth

  The temporary supervisor child receives only process identities, a reference
  and an expiry. It monitors the creator, proxy and supervisor, and treats proxy
  loss as authorized only after the exact retirement notice and normal DOWN.
  The two-slot atomics cell is private to this owner until the begin handshake.
  """

  use GenServer

  @doc false
  def start_link(creator, proxy, ref, expiry) do
    GenServer.start_link(__MODULE__, {creator, proxy, ref, expiry})
  end

  @impl true
  def init({creator, proxy, ref, expiry}) do
    Process.flag(:sensitive, true)
    Process.flag(:trap_exit, true)
    supervisor = supervisor_from_ancestry()

    if is_pid(supervisor) and fresh?(expiry) and
         Enum.all?([creator, proxy, supervisor], &Process.alive?/1) do
      monitors = %{
        creator: Process.monitor(creator),
        proxy: Process.monitor(proxy),
        supervisor: Process.monitor(supervisor)
      }

      cell = :atomics.new(2, signed: false)
      send(creator, {self(), ref, :owner_candidate})
      Process.send_after(self(), {:activation_expired, ref}, remaining(expiry))

      {:ok,
       %{
         creator: creator,
         proxy: proxy,
         supervisor: supervisor,
         ref: ref,
         expiry: expiry,
         monitors: monitors,
         cell: cell,
         retiring: false,
         phase: :blocked,
         token: nil
       }}
    else
      {:stop, :expired_owner_start}
    end
  end

  @impl true
  def handle_info(
        {proxy, ref, :proxy_retiring},
        %{proxy: proxy, ref: ref, phase: :blocked} = state
      ) do
    {:noreply, %{state | retiring: true}}
  end

  def handle_info(
        {:DOWN, monitor, :process, proxy, :normal},
        %{proxy: proxy, monitors: %{proxy: monitor}, retiring: true, phase: :blocked} = state
      ) do
    {:noreply, %{state | phase: :ready}}
  end

  def handle_info(
        {creator, ref, :prepare, token},
        %{creator: creator, ref: ref, phase: :ready} = state
      )
      when is_reference(token) do
    if fresh?(state.expiry) do
      send(creator, {self(), ref, :prepared})
      {:noreply, %{state | phase: :prepared, token: token}}
    else
      {:stop, :expired_owner_start, state}
    end
  end

  def handle_info(
        {creator, ref, :begin, token, reply_ref},
        %{creator: creator, ref: ref, phase: :prepared, token: token} = state
      )
      when is_reference(reply_ref) do
    if fresh?(state.expiry) do
      send(creator, {self(), reply_ref, :begun, state.cell})
      {:noreply, %{state | phase: :begun, token: nil}}
    else
      {:stop, :expired_owner_start, state}
    end
  end

  def handle_info({:activation_expired, ref}, %{ref: ref, phase: phase} = state)
      when phase != :begun do
    if fresh?(state.expiry),
      do: {:noreply, state},
      else: {:stop, :normal, state}
  end

  def handle_info({:DOWN, monitor, :process, pid, _reason}, state) do
    if {monitor, pid} in [
         {state.monitors.creator, state.creator},
         {state.monitors.proxy, state.proxy},
         {state.monitors.supervisor, state.supervisor}
       ] do
      {:stop, :normal, state}
    else
      {:noreply, state}
    end
  end

  def handle_info({:EXIT, supervisor, _reason}, %{supervisor: supervisor} = state),
    do: {:stop, :normal, state}

  def handle_info(_message, state), do: {:noreply, state}

  defp fresh?(expiry), do: is_integer(expiry) and System.monotonic_time() < expiry

  defp supervisor_from_ancestry do
    case {Process.get(:"$ancestors"), Process.info(self(), :links)} do
      {[parent | _], {:links, links}} when is_pid(parent) ->
        if parent in links, do: parent, else: nil

      _ ->
        nil
    end
  end

  defp remaining(expiry) do
    difference = max(expiry - System.monotonic_time(), 0)
    unit = System.convert_time_unit(1, :millisecond, :native)
    div(difference + unit - 1, unit)
  end
end
