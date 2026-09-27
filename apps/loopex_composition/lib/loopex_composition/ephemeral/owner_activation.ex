defmodule LoopexComposition.Ephemeral.OwnerActivation do
  @moduledoc """
  ## Concept

  Reconciles an ephemeral owner's provisional start before any session input can
  reach it. Failed starts do not stop the shared supervisor or peer sessions.

  ## Technical depth

  An unlinked proxy owns the potentially stalled supervisor call. The creator
  requires the owner's direct candidate report, the proxy's matching return,
  its retirement notice and normal DOWN, then a prepared acknowledgement.
  Only the creator keeps the begin token. A failed start kills and reaps known
  processes under one bounded cleanup deadline.
  """

  alias LoopexComposition.Ephemeral.SessionOwner

  @failure {:error, {:composition, :ephemeral_owner_start_failed}}
  @start_ms 1_000
  @reap_ms 1_000

  @doc false
  def start(supervisor, starter \\ &DynamicSupervisor.start_child/2)
      when is_pid(supervisor) and is_function(starter, 2) do
    creator = self()
    ref = make_ref()
    expiry = System.monotonic_time() + native(@start_ms)
    token = make_ref()

    {proxy, proxy_monitor} =
      spawn_monitor(fn -> proxy(creator, ref, expiry, supervisor, starter) end)

    send(proxy, {creator, ref, :start})

    await_start(%{
      creator: creator,
      ref: ref,
      expiry: expiry,
      token: token,
      proxy: proxy,
      proxy_monitor: proxy_monitor,
      candidate: nil,
      candidate_monitor: nil,
      returned: nil,
      direct: false,
      provisional: false,
      matched: false,
      retiring: false,
      proxy_down: false,
      candidate_down: false
    })
  end

  @doc false
  def owner({:owner_activation, owner, _creator, _ref, _token, _monitor}), do: owner

  @doc false
  def begin({:owner_activation, owner, creator, ref, token, monitor})
      when creator == self() do
    reply_ref = make_ref()
    send(owner, {creator, ref, :begin, token, reply_ref})

    receive do
      {^owner, ^reply_ref, :begun, cell} when is_reference(cell) -> {:ok, cell}
      {:DOWN, ^monitor, :process, ^owner, _reason} -> @failure
    after
      @start_ms -> @failure
    end
  end

  def begin(_activation), do: @failure

  defp proxy(creator, ref, expiry, supervisor, starter) do
    creator_monitor = Process.monitor(creator)

    receive do
      {^creator, ^ref, :start} ->
        if Process.alive?(creator) and System.monotonic_time() < expiry do
          spec = %{
            id: SessionOwner,
            start: {SessionOwner, :start_link, [creator, self(), ref, expiry]},
            restart: :temporary
          }

          result =
            try do
              starter.(supervisor, spec)
            catch
              _, _ -> :start_failed
            end

          send(creator, {self(), ref, :provisional, result})

          receive do
            {^creator, ^ref, :finish, owner} when result == {:ok, owner} ->
              send(owner, {self(), ref, :proxy_retiring})
              send(creator, {self(), ref, :proxy_retiring})

            {:DOWN, ^creator_monitor, :process, ^creator, _reason} ->
              :ok
          end
        end

      {:DOWN, ^creator_monitor, :process, ^creator, _reason} ->
        :ok
    end
  end

  defp await_start(state) do
    cond do
      state.proxy_down and state.direct and state.provisional and state.retiring ->
        prepare(state)

      System.monotonic_time() >= state.expiry ->
        fail(state)

      true ->
        wait_start(state)
    end
  end

  defp wait_start(state) do
    %{candidate: candidate, proxy: proxy, ref: ref, proxy_monitor: proxy_monitor} = state

    receive do
      {owner, ^ref, :owner_candidate} when is_pid(owner) ->
        if state.direct or (state.provisional and state.returned != owner) do
          fail(state)
        else
          next = %{state | candidate: owner, direct: true}
          finish_if_ready(next)
        end

      {^proxy, ^ref, :provisional, {:ok, owner}} when is_pid(owner) ->
        if state.provisional or (state.direct and candidate != owner) do
          fail(state)
        else
          next = %{state | returned: owner, provisional: true}
          finish_if_ready(next)
        end

      {^proxy, ^ref, :provisional, _bad} ->
        fail(state)

      {^proxy, ^ref, :proxy_retiring} ->
        await_start(%{state | retiring: true})

      {:DOWN, ^proxy_monitor, :process, ^proxy, :normal} ->
        if state.retiring, do: await_start(%{state | proxy_down: true}), else: fail(state)

      {:DOWN, ^proxy_monitor, :process, ^proxy, _reason} ->
        fail(state)

      {:DOWN, monitor, :process, owner, _reason}
      when monitor == state.candidate_monitor and owner == candidate ->
        fail(%{state | candidate_down: true})
    after
      remaining(state.expiry) -> fail(state)
    end
  end

  defp finish_if_ready(%{direct: true, provisional: true} = state) do
    monitor = Process.monitor(state.candidate)
    next = %{state | matched: true, candidate_monitor: monitor}
    send(state.proxy, {state.creator, state.ref, :finish, state.candidate})
    await_start(next)
  end

  defp finish_if_ready(state), do: await_start(state)

  defp prepare(state) do
    send(state.candidate, {state.creator, state.ref, :prepare, state.token})

    receive do
      {owner, ref, :prepared} when owner == state.candidate and ref == state.ref ->
        {:ok,
         {:owner_activation, owner, state.creator, state.ref, state.token,
          state.candidate_monitor}}

      {:DOWN, monitor, :process, owner, _reason}
      when monitor == state.candidate_monitor and owner == state.candidate ->
        fail(%{state | candidate_down: true})
    after
      remaining(state.expiry) -> fail(state)
    end
  end

  defp fail(state) do
    owned = if state.matched, do: [state.proxy, state.candidate], else: [state.proxy]

    for pid <- owned, is_pid(pid) and Process.alive?(pid) do
      Process.exit(pid, :kill)
    end

    reap_until = System.monotonic_time() + native(@reap_ms)
    unless state.proxy_down, do: await_down(state.proxy_monitor, state.proxy, reap_until)

    if state.matched and not state.candidate_down,
      do: await_down(state.candidate_monitor, state.candidate, reap_until)

    @failure
  end

  defp await_down(nil, _pid, _deadline), do: :ok

  defp await_down(monitor, pid, deadline) do
    receive do
      {:DOWN, ^monitor, :process, ^pid, _reason} -> :ok
    after
      remaining(deadline) -> Process.demonitor(monitor, [:flush])
    end
  end

  defp native(ms), do: System.convert_time_unit(ms, :millisecond, :native)

  defp remaining(deadline) do
    difference = max(deadline - System.monotonic_time(), 0)
    div(difference + native(1) - 1, native(1))
  end
end
