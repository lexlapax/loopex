defmodule Loopex.Runtime.OwnerGroupRetirementTest do
  use ExUnit.Case, async: false

  alias Loopex.Executor
  alias Loopex.Runtime.OwnerGroup

  @trace_cap 8_192
  @trace_key {__MODULE__, :trace_rows}
  @liveness_mfa {:erts_internal, :is_process_alive, 2}

  test "ordinary actor DOWN retains native child identities until the suspended supervisor removes them" do
    witness(:selected_window)
  end

  test "ordinary retirement records actual native membership progress under the retained window" do
    witness(:live_window)
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
    Process.put(key, %{actors: [], joined: MapSet.new(), traced: false, liveness_pattern: false})
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

      :ok =
        invoke(
          coordinator,
          fn ->
            OwnerGroup.retain_provider(group, guard, reference, 1, bound)
          end,
          cutoff
        )

      :ok =
        invoke(
          coordinator,
          fn -> OwnerGroup.bind_provider(group, reference, worker, bound) end,
          cutoff
        )

      send(guard, {:retain_resource, resource})
      assert_receive {:resource_retained, ^guard}, left(cutoff)

      if mode in [:selected_window, :live_window] do
        {:ok, %{executor_observe_ms: observation}} = Executor.cancellation_bounds(1)
        started = System.monotonic_time(:millisecond)
        window = %{cooperative_deadline: started + 1, observation_deadline: started + observation}

        {:ok, ^window} =
          invoke(
            coordinator,
            fn ->
              OwnerGroup.provider_cleanup(group, reference, window)
            end,
            cutoff
          )
      end

      %{monitor: group_coordinator_monitor, providers: %{^reference => retained} = providers} =
        :sys.get_state(group, left(cutoff))

      expected_down =
        MapSet.new([
          {retained.guard_monitor, guard},
          {retained.worker_monitor, worker},
          {retained.resource_monitor, resource}
        ])

      assert Enum.sort(retained.original_members) == Enum.sort([guard, worker, resource])

      # Concept: validate the captured provider map before observing actor retirement.
      # Technical depth: this real map enumeration initializes its protocol inside
      # the original cutoff; cold dependency loading is outside the fixed trace claim.
      assert Enum.all?(providers, &(&1 == {reference, retained}))

      if mode == :selected_window do
        :ok = :sys.suspend(group, left(cutoff))
        :ok = :sys.suspend(workers, left(cutoff))
      end

      # Concept: native liveness replies require their original target and reference.
      # Technical depth: only this Group gains call tracing; the two fixed heads
      # retain no arbitrary arguments. Mark pattern custody before its mutation
      # so failed setup still restores the initially absent global pattern.
      assert :erlang.trace_info(@liveness_mfa, :match_spec) == {:match_spec, false}
      Process.put(key, %{Process.get(key) | liveness_pattern: true})

      pattern = [
        {[coordinator, :"$1"], [{:is_reference, :"$1"}], [{:return_trace}]},
        {[workers, :"$1"], [{:is_reference, :"$1"}], [{:return_trace}]}
      ]

      assert :erlang.trace_pattern(@liveness_mfa, pattern, []) == 1
      Process.put(key, %{Process.get(key) | traced: true})
      assert :erlang.trace(group, true, [:receive, :send, :call, {:tracer, self()}]) == 1
      for pid <- [guard, worker, resource], do: send(pid, :finish)
      join(key, guard, guard_monitor, :normal, cutoff)
      join(key, worker, worker_monitor, :normal, cutoff)
      join(key, resource, resource_monitor, :normal, cutoff)

      native_budget =
        if mode == :selected_window do
          # Both owners are held before genuine completion. Native EXIT insertion
          # is observed before Group can reduce DOWN and issue its membership query.
          remaining = await_native_exits(workers, [guard, worker, resource], cutoff, 64)
          :ok = :sys.resume(group, left(cutoff))
          remaining
        end

      {rows, action} = await_action(group, workers, coordinator, expected_down, [], cutoff)
      assert original_downs(rows, group) == expected_down

      if mode in [:selected_window, :live_window] do
        assert Enum.all?([group, workers], &Process.alive?/1)
        {:query, request_id} = action

        if mode == :selected_window do
          messages =
            await_native_queue(
              workers,
              group,
              [guard, worker, resource],
              action,
              cutoff,
              native_budget
            )

          assert List.last(messages) ==
                   {:"$gen_call", {group, [:alias | request_id]}, :which_children}
        end

        stopper =
          spawn(fn ->
            result = GenServer.stop(group, :normal, left(cutoff))
            send(parent, {:group_stopped, self(), result})
          end)

        stopper_monitor = retain(key, stopper)
        if mode == :selected_window, do: :ok = :sys.resume(workers, left(cutoff))
        actors = [guard, worker, resource]

        rows =
          await_empty_then_stop(
            group,
            workers,
            actors,
            coordinator,
            group_coordinator_monitor,
            stopper,
            rows,
            cutoff
          )

        assert normal_exit_reply_before_bulk?(rows, group, workers)
        observations = membership_observations(rows, group, workers)
        assert List.last(observations).members == []
        # The live schedule is not retried to obtain a nonempty result. Every
        # actually observed intermediate result must precede genuine absence;
        # zero intermediate results leaves that branch's coverage unproved.
        assert Enum.all?(Enum.drop(observations, -1), &(&1.members != []))
        if mode == :selected_window, do: assert(length(observations) == 1)
        assert_receive {:group_stopped, ^stopper, :ok}, left(cutoff)
        join(key, stopper, stopper_monitor, :normal, cutoff)
        join(key, group, group_monitor, :normal, cutoff)
      else
        {:stop, _stop_reference} = action

        refute Enum.any?(
                 rows,
                 &match?(
                   {:trace, ^group, :send, {:"$gen_call", {^group, _}, :which_children},
                    ^workers},
                   &1
                 )
               )

        join(key, group, group_monitor, :provider_cleanup_unproved, cutoff)
      end

      join(key, workers, workers_monitor, :shutdown, cutoff)
      join(key, coordinator, coordinator_monitor, :shutdown, cutoff)
    after
      cleanup(key, cutoff)
    end
  end

  defp await_native_exits(workers, actors, cutoff, observations) do
    assert observations > 0
    assert System.monotonic_time(:millisecond) < cutoff
    {:message_queue_len, count} = Process.info(workers, :message_queue_len)
    assert count <= 3
    {:messages, messages} = Process.info(workers, :messages)
    assert length(messages) <= 3

    assert Enum.all?(messages, fn
             {:EXIT, pid, :normal} -> pid in actors
             _unexpected -> false
           end)

    if length(messages) == 3 do
      assert MapSet.new(for {:EXIT, pid, :normal} <- messages, do: pid) == MapSet.new(actors)
      observations - 1
    else
      :erlang.yield()
      await_native_exits(workers, actors, cutoff, observations - 1)
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
             {:EXIT, pid, :normal} ->
               pid in actors

             {:"$gen_call", {^group, [:alias | reference]}, :which_children} ->
               action == {:query, reference}

             {:system, {^group, reference}, {:terminate, :shutdown}} ->
               action == {:stop, reference}

             _unexpected ->
               false
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

    {:ok, pid} =
      GenServer.call(workers, {:start_task, args, :temporary, :brutal_kill}, left(cutoff))

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

  defp await_action(group, workers, coordinator, expected, rows, cutoff) do
    assert length(rows) < @trace_cap

    receive do
      {:trace, ^group, :call, {:erts_internal, :is_process_alive, [target, reference]}} = row
      when is_reference(reference) and target in [coordinator, workers] ->
        rows = retain_liveness_row(rows, group, coordinator, workers, row)
        await_action(group, workers, coordinator, expected, rows, cutoff)

      {:trace, ^group, :return_from, {:erts_internal, :is_process_alive, 2}, :ok} = row ->
        rows = retain_liveness_row(rows, group, coordinator, workers, row)
        await_action(group, workers, coordinator, expected, rows, cutoff)

      {:trace, ^group, :receive, {reference, result}} = row
      when is_reference(reference) and is_boolean(result) ->
        rows = retain_liveness_row(rows, group, coordinator, workers, row)
        await_action(group, workers, coordinator, expected, rows, cutoff)

      {:trace, ^group, :receive, {:DOWN, monitor, :process, pid, :normal}} = row ->
        record_trace()
        assert MapSet.member?(expected, {monitor, pid})
        await_action(group, workers, coordinator, expected, rows ++ [row], cutoff)

      {:trace, ^group, :send, {:"$gen_call", {^group, [:alias | request_id]}, :which_children},
       ^workers} = row ->
        record_trace()
        {rows ++ [row], {:query, request_id}}

      {:trace, ^group, :send, {:system, {^group, stop_reference}, {:terminate, :shutdown}},
       ^workers} = row ->
        record_trace()
        {rows ++ [row], {:stop, stop_reference}}

      {:trace, ^group, :receive, {:system, {caller, tag}, :resume}} = row ->
        record_trace()
        assert caller == self() and native_request_tag?(tag)
        await_action(group, workers, coordinator, expected, rows ++ [row], cutoff)

      {:trace, ^group, :send, {tag, :ok}, target} = row ->
        record_trace()
        assert resume_reply?(rows, group, tag, target)
        await_action(group, workers, coordinator, expected, rows ++ [row], cutoff)

      {:trace, ^group, _kind, _term} = row ->
        unexpected_trace("unexpected Group receive trace shape in the fixed actor witness", row)

      {:trace, ^group, :send, _term, _target} = row ->
        unexpected_trace("unexpected Group send trace shape in the fixed actor witness", row)

      {:trace, ^group, _kind, _term, _extra} = row ->
        unexpected_trace("unexpected Group trace shape in the fixed actor witness", row)
    after
      left(cutoff) -> flunk("native membership/stop observation missed the original cutoff")
    end
  end

  defp await_empty_then_stop(
         group,
         workers,
         actors,
         coordinator,
         coordinator_monitor,
         stopper,
         rows,
         cutoff
       ) do
    assert length(rows) < @trace_cap

    receive do
      {:trace, ^group, :call, {:erts_internal, :is_process_alive, [target, reference]}} = row
      when is_reference(reference) and target in [coordinator, workers] ->
        rows = retain_liveness_row(rows, group, coordinator, workers, row)

        await_empty_then_stop(
          group,
          workers,
          actors,
          coordinator,
          coordinator_monitor,
          stopper,
          rows,
          cutoff
        )

      {:trace, ^group, :return_from, {:erts_internal, :is_process_alive, 2}, :ok} = row ->
        rows = retain_liveness_row(rows, group, coordinator, workers, row)

        await_empty_then_stop(
          group,
          workers,
          actors,
          coordinator,
          coordinator_monitor,
          stopper,
          rows,
          cutoff
        )

      {:trace, ^group, :receive, {reference, result}} = row
      when is_reference(reference) and is_boolean(result) ->
        rows = retain_liveness_row(rows, group, coordinator, workers, row)

        await_empty_then_stop(
          group,
          workers,
          actors,
          coordinator,
          coordinator_monitor,
          stopper,
          rows,
          cutoff
        )

      {:trace, ^group, :receive, {[:alias | request_id], members}} = row when is_list(members) ->
        record_trace()
        queries = membership_queries(rows, group, workers)
        assert request_id in queries

        refute Enum.any?(
                 membership_observations(rows, group, workers),
                 &(&1.request_id == request_id)
               )

        assert Enum.all?(members, fn
                 {:undefined, pid, :worker, [Task.Supervised]} -> pid in actors
                 _unexpected -> false
               end)

        assert length(members) <= 3
        assert length(Enum.uniq_by(members, &elem(&1, 1))) == length(members)

        await_empty_then_stop(
          group,
          workers,
          actors,
          coordinator,
          coordinator_monitor,
          stopper,
          rows ++ [row],
          cutoff
        )

      {:trace, ^group, :send, {:"$gen_call", {^group, [:alias | request_id]}, :which_children},
       ^workers} = row ->
        record_trace()
        refute request_id in membership_queries(rows, group, workers)
        assert List.last(membership_observations(rows, group, workers)).members != []

        await_empty_then_stop(
          group,
          workers,
          actors,
          coordinator,
          coordinator_monitor,
          stopper,
          rows ++ [row],
          cutoff
        )

      {:trace, ^group, :send, {:system, {^group, _stop}, {:terminate, :shutdown}}, ^workers} = row ->
        record_trace()
        assert List.last(membership_observations(rows, group, workers)).members == []

        assert Enum.count(rows, fn
                 {:trace, ^group, :call, {:erts_internal, :is_process_alive, _arguments}} -> true
                 _row -> false
               end) ==
                 Enum.count(rows, fn
                   {:trace, ^group, :receive, {reference, result}}
                   when is_reference(reference) and is_boolean(result) ->
                     true

                   _row ->
                     false
                 end)

        rows ++ [row]

      {:trace, ^group, :receive, {:system, {^stopper, tag}, {:terminate, :normal}}} = row ->
        record_trace()
        assert native_request_tag?(tag)

        await_empty_then_stop(
          group,
          workers,
          actors,
          coordinator,
          coordinator_monitor,
          stopper,
          rows ++ [row],
          cutoff
        )

      # Concept: this is the retained stopper's system-request reply, not cleanup proof.
      # Technical depth: require its exact prior caller/tag and alias destination;
      # unrelated or repeated replies still fail under the original cutoff and cap.
      {:trace, ^group, :send, {[:alias | stop_reference] = tag, :ok}, target} = row
      when is_reference(stop_reference) and target == stop_reference ->
        record_trace()

        assert Enum.count(rows, fn
                 {:trace, ^group, :receive, {:system, {^stopper, ^tag}, {:terminate, :normal}}} ->
                   true

                 _row ->
                   false
               end) == 1

        refute row in rows

        await_empty_then_stop(
          group,
          workers,
          actors,
          coordinator,
          coordinator_monitor,
          stopper,
          rows ++ [row],
          cutoff
        )

      {:trace, ^group, :send, {:EXIT, ^group, :shutdown}, ^coordinator} = row ->
        record_trace()

        await_empty_then_stop(
          group,
          workers,
          actors,
          coordinator,
          coordinator_monitor,
          stopper,
          rows ++ [row],
          cutoff
        )

      {:trace, ^group, :receive, {:DOWN, ^coordinator_monitor, :process, ^coordinator, :shutdown}} =
          row ->
        record_trace()

        await_empty_then_stop(
          group,
          workers,
          actors,
          coordinator,
          coordinator_monitor,
          stopper,
          rows ++ [row],
          cutoff
        )

      {:trace, ^group, _kind, _term} = row ->
        unexpected_trace("unexpected native progress receive trace shape", row)

      {:trace, ^group, :send, _term, _target} = row ->
        unexpected_trace("unexpected native progress send trace shape", row)

      {:trace, ^group, _kind, _term, _extra} = row ->
        unexpected_trace("unexpected native progress trace shape", row)
    after
      left(cutoff) -> flunk("positive membership fence did not precede native bulk stop")
    end
  end

  # Concept: an internal Boolean is liveness evidence only for its actual native request.
  # Technical depth: replay only already validated fixed-Group metadata. A unique
  # native2 call, its :ok return and matching receive must appear in strict order;
  # receive tracing can report insertion early, which fails rather than infers a chain.
  defp retain_liveness_row(rows, group, coordinator, workers, row) do
    record_trace()

    state =
      Enum.reduce(rows, %{references: MapSet.new(), pending: nil}, fn
        {:trace, ^group, :call, {:erts_internal, :is_process_alive, [target, reference]}},
        state ->
          %{
            references: MapSet.put(state.references, reference),
            pending: %{target: target, reference: reference, returned: false}
          }

        {:trace, ^group, :return_from, {:erts_internal, :is_process_alive, 2}, :ok}, state ->
          %{state | pending: %{state.pending | returned: true}}

        {:trace, ^group, :receive, {reference, result}}, state
        when is_reference(reference) and is_boolean(result) ->
          %{state | pending: nil}

        _row, state ->
          state
      end)

    valid =
      case row do
        {:trace, ^group, :call, {:erts_internal, :is_process_alive, [target, reference]}} ->
          target in [coordinator, workers] and is_reference(reference) and
            is_nil(state.pending) and not MapSet.member?(state.references, reference)

        {:trace, ^group, :return_from, {:erts_internal, :is_process_alive, 2}, :ok} ->
          match?(%{returned: false}, state.pending)

        {:trace, ^group, :receive, {reference, result}} ->
          is_reference(reference) and is_boolean(result) and
            match?(%{reference: ^reference, returned: true}, state.pending)

        _row ->
          false
      end

    unless valid,
      do:
        unexpected_trace("native liveness call/return/reference correspondence unavailable", row)

    rows ++ [row]
  end

  # Concept: the actual observed row is diagnostic evidence; the clause still fails.
  # Technical depth: an omitted tail remains unavailable. Bounded rendering changes
  # neither accepting clauses nor the original deadline and trace-row cap.
  defp unexpected_trace(label, row) do
    rendered =
      inspect(row,
        structs: false,
        limit: 12,
        printable_limit: 128,
        charlists: :as_lists,
        pretty: false
      )

    flunk(
      label <>
        "; bounded actual row: " <>
        String.slice(rendered, 0, 1_024) <>
        "; any omitted tail is UNAVAILABLE, no complete-shape claim"
    )
  end

  defp membership_queries(rows, group, workers) do
    for {:trace, ^group, :send, {:"$gen_call", {^group, [:alias | request_id]}, :which_children},
         ^workers} <- rows,
        do: request_id
  end

  defp membership_observations(rows, group, workers) do
    queries = membership_queries(rows, group, workers)

    for {:trace, ^group, :receive, {[:alias | request_id], members}} <- rows,
        request_id in queries and is_list(members),
        do: %{request_id: request_id, members: members}
  end

  defp native_request_tag?(tag) when is_reference(tag), do: true
  defp native_request_tag?([:alias | reference]), do: is_reference(reference)
  defp native_request_tag?(_tag), do: false

  defp resume_reply?(rows, group, tag, target) do
    parent = self()

    Enum.any?(rows, fn
      {:trace, ^group, :receive, {:system, {^parent, ^tag}, :resume}} ->
        target == parent or tag == [:alias | target]

      _row ->
        false
    end)
  end

  defp original_downs(rows, group) do
    downs =
      for {:trace, ^group, :receive, {:DOWN, monitor, :process, pid, :normal}} <- rows,
          do: {monitor, pid}

    MapSet.new(downs)
  end

  defp normal_exit_reply_before_bulk?(rows, group, workers) do
    queries = membership_queries(rows, group, workers)

    reply =
      Enum.find_index(rows, fn
        {:trace, ^group, :receive, {[:alias | request_id], []}} -> request_id in queries
        _row -> false
      end)

    stop =
      Enum.find_index(
        rows,
        &match?(
          {:trace, ^group, :send, {:system, {^group, _}, {:terminate, :shutdown}}, ^workers},
          &1
        )
      )

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

    try do
      unjoined =
        Enum.reject(state.actors, fn {_pid, monitor} ->
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
    after
      if state.liveness_pattern do
        :erlang.trace_pattern(@liveness_mfa, false, [])
        assert :erlang.trace_info(@liveness_mfa, :match_spec) == {:match_spec, false}
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
      {:trace_delivered, :all, ^fence} ->
        :ok

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
