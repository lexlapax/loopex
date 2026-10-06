defmodule Loopex.Runtime.OwnerGroupRetirementTest do
  use ExUnit.Case, async: false

  alias Loopex.Executor
  alias Loopex.Runtime.OwnerGroup

  @trace_cap 8_192
  @trace_key {__MODULE__, :trace_rows}

  test "ordinary actor DOWN retains native child identities until the suspended supervisor removes them" do
    witness(:selected_window)
  end

  test "startup actor DOWN without a selected window stays unproved without a new query allowance" do
    witness(:no_window)
  end

  # Concept: these are real supervised actors and original monitor signals.
  # Technical depth: this private Group mechanism witness holds native EXIT
  # reduction. It does not substitute fixture actors for provider cleanup proof.
  defp witness(mode) do
    cutoff = System.monotonic_time(:millisecond) + 1_000
    key = make_ref()
    Process.put(key, %{actors: [], joined: MapSet.new(), traced: false})
    Process.put(@trace_key, 0)
    parent = self()
    coordinator = spawn(fn -> coordinator_loop(parent) end)
    coordinator_monitor = retain(key, coordinator)

    try do
      {:ok, group} = GenServer.start(OwnerGroup, [], timeout: left(cutoff))
      group_monitor = retain(key, group)
      {:ok, workers} = GenServer.call(group, :workers, left(cutoff))
      workers_monitor = retain(key, workers)
      :ok = GenServer.call(group, {:attach, coordinator}, left(cutoff))
      reference = make_ref()
      bound = {:monotonic, cutoff}

      resource = start_actor(workers, fn -> actor(parent, :resource) end, cutoff)
      resource_monitor = retain(key, resource)
      worker = start_actor(workers, fn -> actor(parent, :worker) end, cutoff)
      worker_monitor = retain(key, worker)
      guard = start_actor(workers, fn -> guard(parent, group, reference, bound) end, cutoff)
      guard_monitor = retain(key, guard)
      for {role, pid} <- [resource: resource, worker: worker, guard: guard] do
        assert_receive {:ready, ^role, ^pid}, left(cutoff)
      end

      :ok = invoke(coordinator, fn ->
        OwnerGroup.retain_provider(group, guard, reference, 1, bound)
      end, cutoff)
      :ok = invoke(coordinator, fn -> OwnerGroup.bind_provider(group, reference, worker, bound) end,
        cutoff)
      send(guard, {:retain_resource, resource})
      assert_receive {:resource_retained, ^guard}, left(cutoff)

      if mode == :selected_window do
        {:ok, %{executor_observe_ms: observation}} = Executor.cancellation_bounds(1)
        started = System.monotonic_time(:millisecond)
        window = %{cooperative_deadline: started + 1, observation_deadline: started + observation}
        {:ok, ^window} = invoke(coordinator, fn ->
          OwnerGroup.provider_cleanup(group, reference, window)
        end, cutoff)
      end

      %{providers: %{^reference => retained}} = :sys.get_state(group, left(cutoff))
      expected_down = MapSet.new([
        {retained.guard_monitor, guard}, {retained.worker_monitor, worker},
        {retained.resource_monitor, resource}
      ])
      assert Enum.sort(retained.original_members) == Enum.sort([guard, worker, resource])
      if mode == :selected_window, do: :ok = :sys.suspend(workers, left(cutoff))
      assert :erlang.trace(group, true, [:receive, :send, {:tracer, self()}]) == 1
      Process.put(key, %{Process.get(key) | traced: true})
      for pid <- [guard, worker, resource], do: send(pid, :finish)
      join(key, guard, guard_monitor, :normal, cutoff)
      join(key, worker, worker_monitor, :normal, cutoff)
      join(key, resource, resource_monitor, :normal, cutoff)
      {rows, action} = await_action(group, workers, expected_down, [], cutoff)
      assert original_downs(rows, group) == expected_down

      # Only the positive fixture's suspended native queue is observed, without
      # consuming it. Keep three exact EXIT identities and one Group query;
      # unexpected shape/population refuses. The no-window control stays live.
      if mode == :selected_window do
        assert Enum.all?([group, workers], &Process.alive?/1)
        messages = await_native_queue(workers, group, [guard, worker, resource], action,
          cutoff, 64)
        {:query, request_id} = action
        assert {:'$gen_call', {group, [:alias | request_id]}, :which_children} in messages
        stopper = spawn(fn ->
          result = GenServer.stop(group, :normal, left(cutoff))
          send(parent, {:group_stopped, self(), result})
        end)
        stopper_monitor = retain(key, stopper)
        :ok = :sys.resume(workers, left(cutoff))
        rows = await_empty_then_stop(group, workers, request_id, rows, cutoff)
        assert normal_exit_reply_before_bulk?(rows, group, workers, request_id)
        assert_receive {:group_stopped, ^stopper, :ok}, left(cutoff)
        join(key, stopper, stopper_monitor, :normal, cutoff)
        join(key, group, group_monitor, :normal, cutoff)
      else
        {:stop, _stop_reference} = action
        refute Enum.any?(rows, &match?({:trace, ^group, :send,
          {:'$gen_call', {^group, _}, :which_children}, ^workers}, &1))
        join(key, group, group_monitor, :provider_cleanup_unproved, cutoff)
      end

      join(key, workers, workers_monitor, :shutdown, cutoff)
      join(key, coordinator, coordinator_monitor, :shutdown, cutoff)
    after
      cleanup(key, cutoff)
    end
  end

  defp await_native_queue(workers, group, actors, action, cutoff, observations) do
    assert observations > 0
    assert System.monotonic_time(:millisecond) < cutoff
    {:message_queue_len, count} = Process.info(workers, :message_queue_len)
    assert count <= 4
    {:messages, messages} = Process.info(workers, :messages)
    assert length(messages) <= 4
    assert Enum.all?(messages, fn
      {:EXIT, pid, :normal} -> pid in actors
      {:'$gen_call', {^group, [:alias | reference]}, :which_children} ->
        action == {:query, reference}
      {:system, {^group, reference}, {:terminate, :shutdown}} ->
        action == {:stop, reference}
      _unexpected -> false
    end)
    if length(messages) == 4 do
      assert MapSet.new(for {:EXIT, pid, :normal} <- messages, do: pid) == MapSet.new(actors)
      messages
    else
      # A send trace precedes actual insertion. Await only this fixed queue's
      # incomplete expected population, under the same cutoff and finite count.
      :erlang.yield()
      await_native_queue(workers, group, actors, action, cutoff, observations - 1)
    end
  end

  defp start_actor(workers, fun, cutoff) do
    # The installed current/floor start_child/3 writers use this exact native
    # Task.Supervisor request. A timed fixture call preserves the same child
    # implementation/spec without its public helper's infinite setup wait.
    owner = {node(), self(), self()}
    args = [owner, [self()], {:erlang, :apply, [fun, []]}]
    {:ok, pid} = GenServer.call(workers, {:start_task, args, :temporary, :brutal_kill},
      left(cutoff))
    pid
  end

  defp actor(parent, role) do
    send(parent, {:ready, role, self()})
    receive do
      :finish -> :ok
    end
  end

  defp guard(parent, group, reference, bound) do
    send(parent, {:ready, :guard, self()})
    receive do
      {:retain_resource, resource} ->
        :ok = OwnerGroup.retain_resource(group, reference, resource, bound)
        send(parent, {:resource_retained, self()})
    end
    receive do
      :finish -> :ok
    end
  end

  defp coordinator_loop(parent) do
    receive do
      {:invoke, nonce, call} ->
        send(parent, {:invoked, nonce, self(), call.()})
        coordinator_loop(parent)
    end
  end

  defp invoke(coordinator, call, cutoff) do
    nonce = make_ref()
    send(coordinator, {:invoke, nonce, call})
    receive do
      {:invoked, ^nonce, ^coordinator, result} -> result
    after
      left(cutoff) -> flunk("fixture coordinator did not return before its original cutoff")
    end
  end

  defp await_action(group, workers, expected, rows, cutoff) do
    assert length(rows) < @trace_cap
    receive do
      {:trace, ^group, :receive, {:DOWN, monitor, :process, pid, :normal}} = row ->
        record_trace()
        assert MapSet.member?(expected, {monitor, pid})
        await_action(group, workers, expected, rows ++ [row], cutoff)

      {:trace, ^group, :send,
       {:'$gen_call', {^group, [:alias | request_id]}, :which_children}, ^workers} = row ->
        record_trace()
        {rows ++ [row], {:query, request_id}}

      {:trace, ^group, :send,
       {:system, {^group, stop_reference}, {:terminate, :shutdown}}, ^workers} = row ->
        record_trace()
        {rows ++ [row], {:stop, stop_reference}}

      {:trace, ^group, _kind, _term} ->
        flunk("unexpected Group receive trace shape in the fixed actor witness")
      {:trace, ^group, :send, _term, _target} ->
        flunk("unexpected Group send trace shape in the fixed actor witness")
    after
      left(cutoff) -> flunk("native membership/stop observation missed the original cutoff")
    end
  end

  defp await_empty_then_stop(group, workers, request_id, rows, cutoff) do
    assert length(rows) < @trace_cap
    receive do
      {:trace, ^group, :receive, {[:alias | ^request_id], []}} = row ->
        record_trace()
        await_empty_then_stop(group, workers, request_id, rows ++ [row], cutoff)
      {:trace, ^group, :send,
       {:system, {^group, _stop}, {:terminate, :shutdown}}, ^workers} = row ->
        record_trace()
        rows ++ [row]
      {:trace, ^group, :receive, {:system, {_stopper, _reference}, {:terminate, :normal}}} = row ->
        record_trace()
        await_empty_then_stop(group, workers, request_id, rows ++ [row], cutoff)
      {:trace, ^group, :send, {:EXIT, ^group, :shutdown}, _coordinator} = row ->
        record_trace()
        await_empty_then_stop(group, workers, request_id, rows ++ [row], cutoff)
    after
      left(cutoff) -> flunk("positive membership fence did not precede native bulk stop")
    end
  end

  defp original_downs(rows, group), do: MapSet.new(for
    {:trace, ^group, :receive, {:DOWN, monitor, :process, pid, :normal}} <- rows,
    do: {monitor, pid})

  defp normal_exit_reply_before_bulk?(rows, group, workers, request_id) do
    reply = Enum.find_index(rows, &match?({:trace, ^group, :receive,
      {[:alias | ^request_id], []}}, &1))
    stop = Enum.find_index(rows, &match?({:trace, ^group, :send,
      {:system, {^group, _}, {:terminate, :shutdown}}, ^workers}, &1))
    is_integer(reply) and is_integer(stop) and reply < stop
  end

  defp retain(key, pid) do
    monitor = Process.monitor(pid)
    state = Process.get(key)
    Process.put(key, %{state | actors: [{pid, monitor} | state.actors]})
    monitor
  end

  defp join(key, pid, monitor, reason, cutoff) do
    assert_receive {:DOWN, ^monitor, :process, ^pid, ^reason}, left(cutoff)
    state = Process.get(key)
    Process.put(key, %{state | joined: MapSet.put(state.joined, monitor)})
  end

  defp cleanup(key, cutoff) do
    state = Process.get(key)
    unjoined = Enum.reject(state.actors, fn {_pid, monitor} ->
      MapSet.member?(state.joined, monitor)
    end)
    for {pid, _monitor} <- unjoined, do: Process.exit(pid, :kill)
    for {pid, monitor} <- unjoined do
      receive do
        {:DOWN, ^monitor, :process, ^pid, _reason} -> :ok
      after
        left(cutoff) -> flunk("original fixture actor join remains unproved")
      end
    end
    if state.traced do
      fence = :erlang.trace_delivered(:all)
      await_fence(fence, cutoff)
    end
    assert System.monotonic_time(:millisecond) < cutoff
    Process.delete(@trace_key)
    Process.delete(key)
  end

  defp await_fence(fence, cutoff) do
    receive do
      {:trace_delivered, :all, ^fence} -> :ok
      {:trace, _pid, _kind, _term} ->
        record_trace()
        await_fence(fence, cutoff)
      {:trace, _pid, _kind, _term, _target} ->
        record_trace()
        await_fence(fence, cutoff)
    after
      left(cutoff) -> flunk("original Group trace delivery remains unproved")
    end
  end

  defp record_trace do
    count = Process.get(@trace_key) + 1
    assert count <= @trace_cap
    Process.put(@trace_key, count)
  end

  defp left(cutoff), do: max(cutoff - System.monotonic_time(:millisecond), 0)
end
