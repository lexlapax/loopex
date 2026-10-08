defmodule Loopex.ProgressSink do
  @moduledoc """
  ## Concept

  A host-owned native progress sink retains a bounded transient view. Taking an
  item transfers custody, while its lease holds capacity until the host proves
  discard or its output worker's full write and join. No item grants authority.

  ## Technical depth

  ADR 0058 fixes 32 slots, 524,288 charged bytes and finite atomic admission.
  One unnamed guardian owns an ETS arena. Its compare-and-replace state row
  contains metadata only; payloads occupy separate fixed slot keys. Admission
  reserves before payload insertion and uses at most 32 comparisons in total.
  A reservation remains charged until publication, producer completion or DOWN.
  Owner-restricted take/release/close carry opaque native incarnations/tokens.
  Ready notifications are coalesced, contain no payload, and are consumed by
  take. A fixed guardian scan discovers unfinished custody without offer messages.

  Private runtime ingress uses this same arena through producer, Control and
  relay phases. Control fences captured metadata before payload lookup; the
  relay retains its charge until projection frames have returned. Domain gates
  seal payload tails under pressure. External fanout and writer cleanup remain
  host obligations; native close proves neither stdout nor socket cleanup.
  """

  use GenServer

  alias Loopex.CompactionProgress
  alias Loopex.Model
  alias Loopex.ProgressPayload

  @slots 32
  @bytes 524_288
  @comparisons 32
  @overhead 8_192
  @uint64 18_446_744_073_709_551_615
  @safe_integer 9_007_199_254_740_991
  @common [:kind, :turn_id, :stream_domain_id, :base_event_sequence]
  @fields %{
    text_delta: @common ++ [:model_sequence, :content_index, :text],
    reasoning_delta: @common ++ [:model_sequence, :content_index, :text],
    tool_call_delta:
      @common ++ [:model_sequence, :call_index, :tool_call_id, :name, :arguments_fragment],
    tool_progress: @common ++ [:tool_call_id, :progress_sequence, :stream, :byte_offset, :chunk],
    model_stream_closed: @common ++ [:disposition, :delta_count],
    tool_stream_closed: @common ++ [:tool_call_id, :disposition, :progress_count]
  }

  @typedoc """
  ## Concept

  One host's progress custody capability.

  ## Technical depth

  Only a guardian PID, native incarnation reference and unnamed arena identity.
  Never serialize this trusted handle or put it in a job or durable record.
  """
  @opaque t :: {pid(), reference(), :ets.tid()}

  @typedoc """
  ## Concept

  One-use evidence of a taken item's native custody.

  ## Technical depth

  Incarnation, fixed slot index and fresh native token distinguish reuse.
  """
  @opaque lease :: {reference(), 0..31, reference()}

  @doc """
  ## Concept

  Opens one sink owned by this calling host process.

  ## Technical depth

  The guardian and arena are unregistered and monitor their opening owner.
  Runtime binding and producer fencing belong to the runtime integration.
  """
  @spec open() :: {:ok, t()} | {:error, :unavailable}
  def open do
    case GenServer.start(__MODULE__, self()) do
      {:ok, guardian} -> {:ok, GenServer.call(guardian, :handle)}
      {:error, _reason} -> {:error, :unavailable}
    end
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  @doc """
  ## Concept

  Offers one already projected closed native item without waiting for a consumer.

  ## Technical depth

  Preflight is finite and precedes copying or admission. The slot includes
  conservative native backing and encoded expansion credit. Failure sends no
  message. Ordinary-domain sealing is a separate runtime ingress obligation.
  """
  @spec try_offer(t(), binary(), map()) :: :ok | :dropped
  def try_offer(sink, session_id, item) do
    with true <- valid_sink?(sink),
         true <- is_binary(session_id) and byte_size(session_id) in 1..256,
         true <- projected?(item),
         charge <- @overhead + binary_charge(session_id) + item_charge(item),
         true <- charge <= @bytes,
         {_guardian, incarnation, arena} <- sink,
         {:ok, slot, token, remaining} <- reserve(arena, incarnation, charge, @comparisons) do
      payload = {{:payload, slot}, token, session_id, item}

      if :ets.insert_new(arena, payload) and
           publish(arena, incarnation, slot, token, remaining) do
        :ok
      else
        delete_payload(arena, slot, token)
        :ets.insert(arena, {{:retired, slot}, token})
        :dropped
      end
    else
      _ -> :dropped
    end
  rescue
    ArgumentError -> :dropped
  end

  @doc """
  ## Concept

  Takes one item while retaining its capacity through a lease.

  ## Technical depth

  Only the opening owner may take. The ready notification is consumed here;
  its atomic flag clears only after the actual message was received. Native
  payload lookup follows the charged ready-to-leased transition.
  """
  @spec take(t()) :: {:ok, lease(), binary(), map()} | :empty | :closed
  def take(sink) do
    with true <- valid_sink?(sink),
         {_guardian, incarnation, arena} <- sink,
         [{:state, ^incarnation, owner, :open, _bytes, _slots, _ready}] <-
           :ets.lookup(arena, :state),
         true <- owner == self() do
      acknowledge_ready(sink, arena)
      take_ready(arena, incarnation, @comparisons)
    else
      _ -> :closed
    end
  rescue
    ArgumentError -> :closed
  end

  @doc """
  ## Concept

  Releases custody after the host has proved all retained copies discarded or joined.

  ## Technical depth

  One exact leased-to-retiring transition invalidates the lease before resident
  deletion. Credit is freed only after that deletion; a delayed retirement stays
  charged for the guardian to finish. Closing still permits this exact release.
  """
  @spec release(t(), lease()) :: :ok | {:error, :stale_lease}
  def release(sink, lease) do
    with true <- valid_sink?(sink),
         {_guardian, incarnation, arena} <- sink,
         {^incarnation, slot, token} <- lease,
         true <- is_integer(slot) and slot in 0..31 and is_reference(token),
         true <- retire_lease(arena, incarnation, slot, token, @comparisons) do
      # Concept: retirement remains discoverable without a late marker write.
      # Technical depth: the guardian may already have freed and reused this
      # retiring slot. Only conditional deletion/free may follow the custody cut.
      delete_payload(arena, slot, token)
      free_slot(arena, incarnation, slot, token, @comparisons)
      :ok
    else
      _ -> {:error, :stale_lease}
    end
  rescue
    ArgumentError -> {:error, :stale_lease}
  end

  @doc """
  ## Concept

  Closes admission and proves native custody gone before acknowledging cleanup.

  ## Technical depth

  Ready items are discarded. Outstanding leases or live unfinished producers
  keep cleanup unproved. The sink remains closed while those holders settle;
  the owner may release its lease and close again. Success joins the guardian.
  This cannot acknowledge an external output worker's cleanup.
  """
  @spec close(t()) :: :ok | {:error, :cleanup_unproved}
  def close(sink) do
    if valid_sink?(sink) do
      {guardian, incarnation, _arena} = sink
      monitor = Process.monitor(guardian)

      try do
        case GenServer.call(guardian, {:close, incarnation}) do
          :ok ->
            receive do
              {:DOWN, ^monitor, :process, ^guardian, :normal} -> :ok
              {:DOWN, ^monitor, :process, ^guardian, _reason} -> {:error, :cleanup_unproved}
            end

          _unproved ->
            Process.demonitor(monitor, [:flush])
            {:error, :cleanup_unproved}
        end
      catch
        :exit, _reason ->
          Process.demonitor(monitor, [:flush])
          {:error, :cleanup_unproved}
      end
    else
      {:error, :cleanup_unproved}
    end
  end

  @doc false
  def available?(sink) do
    with true <- valid_sink?(sink),
         {_guardian, incarnation, arena} <- sink,
         [{:state, ^incarnation, _owner, :open, _bytes, _slots, _ready}] <-
           :ets.lookup(arena, :state) do
      :ets.lookup(arena, :runtime_binding) == []
    else
      _ -> false
    end
  rescue
    ArgumentError -> false
  end

  @doc false
  def bind_runtime(nil, _token), do: :ok

  def bind_runtime(sink, token) when is_reference(token) do
    if valid_sink?(sink) and :ets.insert_new(elem(sink, 2), {:runtime_binding, token}),
      do: :ok,
      else: {:error, :invalid_runtime_options}
  rescue
    ArgumentError -> {:error, :invalid_runtime_options}
  end

  @doc false
  def register_control(nil, _token, _control), do: :ok

  def register_control({_guardian, _incarnation, arena}, token, control) do
    case :ets.lookup(arena, :runtime_binding) do
      [{:runtime_binding, ^token}] ->
        case :ets.lookup(arena, :control_binding) do
          [] ->
            if :ets.insert_new(arena, {:control_binding, token, control}), do: :ok, else: :error

          [{:control_binding, ^token, prior} = old] ->
            if prior == control or not Process.alive?(prior) do
              if prior == control or
                   :ets.select_replace(arena, [
                     {old, [], [{:const, {:control_binding, token, control}}]}
                   ]) == 1 do
                :ok
              else
                :error
              end
            else
              :error
            end

          _ ->
            :error
        end

      _ ->
        :error
    end
  rescue
    ArgumentError -> :error
  end

  @doc false
  def control({_guardian, _incarnation, arena}) do
    case :ets.lookup(arena, :control_binding) do
      [{:control_binding, _token, control}] -> control
      _ -> nil
    end
  rescue
    ArgumentError -> nil
  end

  @doc false
  def reserve_raw(
        sink,
        session,
        item,
        {control, relay, session, owner, gate, kind, header, producer} = route
      ) do
    with true <- valid_sink?(sink),
         true <- producer == self(),
         true <-
           Loopex.Runtime.ProgressIngress.route?(
             control,
             session,
             owner,
             relay,
             gate,
             kind,
             header
           ),
         true <- Loopex.Runtime.ProgressIngress.preflight(kind, item),
         false <- Loopex.Runtime.ProgressIngress.closed?(gate),
         charge <-
           8_192 + raw_charge(session) + raw_map_charge(item) + raw_map_charge(owner) +
             raw_map_charge(header),
         true <- charge <= @bytes,
         {_guardian, incarnation, arena} <- sink,
         order <- :atomics.add_get(gate, 4, 1),
         {:ok, slot, token} <-
           reserve_raw_slot(arena, incarnation, charge, {route, order}, @comparisons) do
      reference = {incarnation, slot, token}

      if :ets.insert_new(arena, {{:payload, slot}, token, session, item}) do
        {:ok, reference}
      else
        # The producer is still the charged holder; insert_new never overwrites
        # a different generation's resident or failed-publication marker.
        :ets.insert_new(arena, {{:retired, slot}, token})
        :dropped
      end
    else
      _ -> :dropped
    end
  rescue
    ArgumentError -> :dropped
  end

  defp reserve_raw_slot(_arena, _incarnation, _charge, _route, 0), do: :dropped

  defp reserve_raw_slot(arena, incarnation, charge, {route, order}, remaining) do
    case :ets.lookup(arena, :state) do
      [{:state, ^incarnation, _owner, :open, bytes, slots, _ready} = old]
      when bytes + charge <= @bytes ->
        if Loopex.Runtime.ProgressIngress.closed?(elem(route, 4)) do
          :dropped
        else
          case Enum.find(0..31, &is_nil(elem(slots, &1))) do
            nil ->
              :dropped

            slot ->
              token = make_ref()
              entry = {token, :raw_reserved, self(), charge, {route, order}}

              next =
                old |> put_elem(4, bytes + charge) |> put_elem(5, put_elem(slots, slot, entry))

              if replace(arena, old, next),
                do: {:ok, slot, token},
                else: reserve_raw_slot(arena, incarnation, charge, {route, order}, remaining - 1)
          end
        end

      _ ->
        :dropped
    end
  end

  @doc false
  def references(nil, _holder, _stage), do: []

  def references(sink, holder, stage) do
    {_guardian, incarnation, arena} = sink

    case :ets.lookup(arena, :state) do
      [{:state, ^incarnation, _owner, _status, _bytes, slots, _ready}] ->
        for slot <- 0..31,
            {token, ^stage, ^holder, _charge, {_route, order}} <- [elem(slots, slot)],
            do: {order, {incarnation, slot, token}}

      _ ->
        []
    end
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(&elem(&1, 1))
  rescue
    ArgumentError -> []
  end

  # Concept: a failed finite claim can leave an earlier reservation live.
  # Technical depth: blocked exhaustion differs from an absent generation.
  # Ordered consumers must stop that prefix and retain the existing custody;
  # the distinction adds no comparison or successful cleanup acknowledgement.
  @doc false
  def claim_stage(sink, reference, expected, next) do
    case stage_change(sink, reference, expected, next, self(), @comparisons) do
      {:ok, route} -> {:ok, route}
      :exhausted -> :blocked
      _ -> :stale
    end
  end

  @doc false
  def route_stage(sink, reference, expected, next, holder) when is_pid(holder) do
    match?({:ok, _}, stage_change(sink, reference, expected, next, holder, @comparisons))
  end

  defp stage_change(_sink, _reference, _expected, _next, _holder, 0), do: :exhausted

  defp stage_change(
         {_guardian, incarnation, arena} = sink,
         {incarnation, slot, token} = reference,
         expected,
         next,
         holder,
         remaining
       )
       when slot in 0..31 do
    case :ets.lookup(arena, :state) do
      [{:state, ^incarnation, _owner, :open, _bytes, slots, _ready} = old] ->
        case elem(slots, slot) do
          {^token, ^expected, current, charge, {route, order}} when current == self() ->
            revoked =
              expected == :raw_reserved and Loopex.Runtime.ProgressIngress.closed?(elem(route, 4))

            if revoked do
              :stale
            else
              entry = {token, next, holder, charge, {route, order}}
              replacement = put_elem(old, 5, put_elem(slots, slot, entry))

              if replace(arena, old, replacement),
                do: {:ok, route},
                else: stage_change(sink, reference, expected, next, holder, remaining - 1)
            end

          _ ->
            :stale
        end

      _ ->
        :stale
    end
  rescue
    ArgumentError -> :stale
  end

  defp stage_change(_sink, _reference, _expected, _next, _holder, _remaining), do: :stale

  @doc false
  def stage_payload({_guardian, incarnation, arena}, {incarnation, slot, token}) do
    case :ets.lookup(arena, :state) do
      [{:state, ^incarnation, _owner, _status, _bytes, slots, _ready}] ->
        case elem(slots, slot) do
          {^token, :relay_owned, holder, _charge, _route} when holder == self() ->
            case :ets.lookup(arena, {:payload, slot}) do
              [{{:payload, ^slot}, ^token, session, item}] -> {:ok, session, item}
              _ -> :stale
            end

          _ ->
            :stale
        end

      _ ->
        :stale
    end
  rescue
    ArgumentError -> :stale
  end

  @doc false
  def replace_payload({_guardian, incarnation, arena}, {incarnation, slot, token}, item) do
    with true <- projected?(item),
         [{:state, ^incarnation, _owner, _status, _bytes, slots, _ready}] <-
           :ets.lookup(arena, :state),
         {^token, :relay_owned, holder, charge, _route} <- elem(slots, slot),
         true <- holder == self(),
         [{{:payload, ^slot}, ^token, session, _raw} = old] <-
           :ets.lookup(arena, {:payload, slot}),
         true <- @overhead + binary_charge(session) + item_charge(item) <= charge do
      next = {{:payload, slot}, token, session, item}
      :ets.select_replace(arena, [{old, [], [{:const, next}]}]) == 1
    else
      _ -> false
    end
  rescue
    ArgumentError -> false
  end

  @doc false
  def ready_stage(sink, reference), do: ready_stage(sink, reference, @comparisons)
  defp ready_stage(_sink, _reference, 0), do: false

  defp ready_stage(
         {_guardian, incarnation, arena} = sink,
         {incarnation, slot, token} = reference,
         remaining
       ) do
    case :ets.lookup(arena, :state) do
      [{:state, ^incarnation, owner, :open, _bytes, slots, ready} = old] ->
        case elem(slots, slot) do
          {^token, :relay_owned, holder, charge, _route} when holder == self() ->
            next =
              old
              |> put_elem(5, put_elem(slots, slot, {token, :ready, owner, charge}))
              |> put_elem(6, ready ++ [slot])

            if replace(arena, old, next),
              do: true,
              else: ready_stage(sink, reference, remaining - 1)

          _ ->
            false
        end

      _ ->
        false
    end
  rescue
    ArgumentError -> false
  end

  @doc false
  def withdraw_raw({_guardian, incarnation, arena}, {incarnation, slot, token}) do
    case :ets.lookup(arena, :state) do
      [{:state, ^incarnation, _owner, _status, _bytes, slots, _ready}] ->
        case elem(slots, slot) do
          {^token, :control_ready, _holder, _charge, {{_, _, _, _, _, _, _, producer}, _}} = entry
          when producer == self() ->
            # Only a not-yet-claimed metadata transfer can be withdrawn. The
            # consumer never looked up its body in this phase; a claimed or
            # routed reference is already that consumer's custody decision.
            if claim_retirement(arena, incarnation, slot, entry, @comparisons) do
              delete_payload(arena, slot, token)
              free_slot(arena, incarnation, slot, token, @comparisons)
            end

          _ ->
            :stale
        end

      _ ->
        :stale
    end
  rescue
    ArgumentError -> :stale
  end

  @doc false
  def retire_stage({_guardian, incarnation, arena}, {incarnation, slot, token}, expected) do
    case :ets.lookup(arena, :state) do
      [{:state, ^incarnation, _owner, _status, _bytes, slots, _ready}] ->
        case elem(slots, slot) do
          {^token, ^expected, holder, _charge, _route} = entry when holder == self() ->
            if claim_retirement(arena, incarnation, slot, entry, @comparisons) do
              delete_payload(arena, slot, token)
              free_slot(arena, incarnation, slot, token, @comparisons)
            end

          _ ->
            :stale
        end

      _ ->
        :stale
    end
  rescue
    ArgumentError -> :stale
  end

  # Concept: reserve every simultaneous raw, projected, leased and encoded copy.
  # Technical depth: eight backing charges and twelve escaped bytes per original
  # byte deliberately overcount shared storage. No subsequent representation can
  # grow the reserved credit; projection exceeding it is dropped in place.
  defp raw_charge(value), do: 8 * :binary.referenced_byte_size(value) + 12 * byte_size(value)

  defp raw_map_charge(item),
    do:
      Enum.reduce(item, 0, fn {_key, value}, total ->
        total +
          cond do
            is_binary(value) -> raw_charge(value)
            is_map(value) -> raw_map_charge(value)
            true -> 0
          end
      end)

  @impl true
  def init(owner) do
    arena =
      :ets.new(__MODULE__, [:set, :public, {:read_concurrency, true}, {:write_concurrency, true}])

    incarnation = make_ref()
    flag = :atomics.new(1, signed: false)
    raw_flag = :atomics.new(1, signed: false)

    :ets.insert(arena, [
      {:state, incarnation, owner, :open, 0, List.duplicate(nil, @slots) |> List.to_tuple(), []},
      {:notification, flag},
      {:raw_notification, raw_flag}
    ])

    Process.send_after(self(), :scan, 10)

    {:ok,
     %{
       arena: arena,
       incarnation: incarnation,
       owner: owner,
       owner_monitor: Process.monitor(owner),
       monitors: %{},
       flag: flag,
       raw_flag: raw_flag,
       raw_target: nil
     }}
  end

  @impl true
  def handle_call(:handle, {owner, _tag}, %{owner: owner} = state),
    do: {:reply, {self(), state.incarnation, state.arena}, state}

  def handle_call(
        {:close, incarnation},
        {owner, _tag},
        %{owner: owner, incarnation: incarnation} = state
      ) do
    # Concept: close revokes every unfinished route before any cleanup scan.
    # Technical depth: atomic field update invalidates old open-row CAS preimages.
    # An in-flight producer cannot publish after this cut, even if it copied first.
    :ets.update_element(state.arena, :state, {4, :closed})
    state = scan(state)

    if empty_slots?(state.arena) do
      {:stop, :normal, :ok, state}
    else
      {:reply, {:error, :cleanup_unproved}, state}
    end
  end

  def handle_call(_request, _from, state), do: {:reply, {:error, :cleanup_unproved}, state}

  @impl true
  def handle_info(
        {:DOWN, reference, :process, owner, _reason},
        %{owner_monitor: reference, owner: owner} = state
      ),
      do: {:stop, :normal, state}

  def handle_info({:DOWN, reference, :process, producer, _reason}, state) do
    monitors =
      case state.monitors[producer] do
        {^reference, :live} -> Map.put(state.monitors, producer, {reference, :down})
        _ -> state.monitors
      end

    {:noreply, scan(%{state | monitors: monitors})}
  end

  def handle_info(:scan, state) do
    state = scan(state)
    state = notify_raw(state)
    notify_ready(state)
    Process.send_after(self(), :scan, 10)
    {:noreply, state}
  end

  defp valid_sink?({guardian, incarnation, arena})
       when is_pid(guardian) and is_reference(incarnation) and is_reference(arena) do
    :ets.info(arena, :owner) == guardian and
      match?(
        [{:state, ^incarnation, _owner, _status, _bytes, _slots, _ready}],
        :ets.lookup(arena, :state)
      )
  rescue
    ArgumentError -> false
  end

  defp valid_sink?(_sink), do: false

  # Concept: all credit and captured custody move together in one state row.
  # Technical depth: this row never contains a payload. Other offering processes
  # copy only the fixed metadata, not resident native items or binary backing.
  defp reserve(_arena, _incarnation, _charge, 0), do: :dropped

  defp reserve(arena, incarnation, charge, remaining) do
    case :ets.lookup(arena, :state) do
      [{:state, ^incarnation, _owner, :open, bytes, slots, _ready} = old]
      when bytes + charge <= @bytes ->
        case Enum.find(0..31, &is_nil(elem(slots, &1))) do
          nil ->
            :dropped

          slot ->
            token = make_ref()

            next =
              old
              |> put_elem(4, bytes + charge)
              |> put_elem(5, put_elem(slots, slot, {token, :reserved, self(), charge}))

            if replace(arena, old, next),
              do: {:ok, slot, token, remaining - 1},
              else: reserve(arena, incarnation, charge, remaining - 1)
        end

      _ ->
        :dropped
    end
  end

  defp publish(_arena, _incarnation, _slot, _token, 0), do: false

  defp publish(arena, incarnation, slot, token, remaining) do
    case :ets.lookup(arena, :state) do
      [{:state, ^incarnation, owner, :open, _bytes, slots, ready} = old] ->
        case elem(slots, slot) do
          {^token, :reserved, producer, charge} when producer == self() ->
            next =
              old
              |> put_elem(5, put_elem(slots, slot, {token, :ready, owner, charge}))
              |> put_elem(6, ready ++ [slot])

            if replace(arena, old, next),
              do: true,
              else: publish(arena, incarnation, slot, token, remaining - 1)

          _ ->
            false
        end

      _ ->
        false
    end
  end

  defp take_ready(_arena, _incarnation, 0), do: :empty

  defp take_ready(arena, incarnation, remaining) do
    case :ets.lookup(arena, :state) do
      [{:state, ^incarnation, owner, :open, _bytes, slots, [slot | ready]} = old]
      when owner == self() ->
        {token, :ready, ^owner, charge} = elem(slots, slot)

        next =
          old
          |> put_elem(5, put_elem(slots, slot, {token, :leased, owner, charge}))
          |> put_elem(6, ready)

        if replace(arena, old, next) do
          [{{:payload, ^slot}, ^token, session_id, item}] = :ets.lookup(arena, {:payload, slot})
          {:ok, {incarnation, slot, token}, session_id, item}
        else
          take_ready(arena, incarnation, remaining - 1)
        end

      [{:state, ^incarnation, owner, :open, _bytes, _slots, []}] when owner == self() ->
        :empty

      _ ->
        :closed
    end
  end

  defp retire_lease(_arena, _incarnation, _slot, _token, 0), do: false

  defp retire_lease(arena, incarnation, slot, token, remaining) do
    case :ets.lookup(arena, :state) do
      [{:state, ^incarnation, owner, _status, _bytes, slots, _ready} = old]
      when owner == self() ->
        case elem(slots, slot) do
          {^token, :leased, ^owner, charge} ->
            next = put_elem(old, 5, put_elem(slots, slot, {token, :retiring, owner, charge}))

            if replace(arena, old, next),
              do: true,
              else: retire_lease(arena, incarnation, slot, token, remaining - 1)

          _ ->
            false
        end

      _ ->
        false
    end
  end

  defp free_slot(_arena, _incarnation, _slot, _token, 0), do: :unproved

  defp free_slot(arena, incarnation, slot, token, remaining) do
    [{:state, ^incarnation, _owner, _status, bytes, slots, ready} = old] =
      :ets.lookup(arena, :state)

    case elem(slots, slot) do
      {^token, :retiring, _holder, charge} ->
        next =
          old
          |> put_elem(4, bytes - charge)
          |> put_elem(5, put_elem(slots, slot, nil))
          |> put_elem(6, List.delete(ready, slot))

        if replace(arena, old, next) do
          :ets.select_delete(arena, [{{{:retired, slot}, token}, [], [true]}])
          :ok
        else
          free_slot(arena, incarnation, slot, token, remaining - 1)
        end

      nil ->
        :ok

      _ ->
        :unproved
    end
  end

  defp replace(arena, old, next),
    do: :ets.select_replace(arena, [{old, [], [{:const, next}]}]) == 1

  defp delete_payload(arena, slot, token),
    do: :ets.select_delete(arena, [{{{:payload, slot}, token, :_, :_}, [], [true]}])

  defp scan(state) do
    [{:state, _incarnation, _owner, status, _bytes, slots, _ready}] =
      :ets.lookup(state.arena, :state)

    producers =
      for entry <- Tuple.to_list(slots),
          entry != nil,
          tuple_size(entry) == 5 or elem(entry, 1) == :reserved,
          uniq: true,
          do: elem(entry, 2)

    monitors =
      Enum.reduce(state.monitors, %{}, fn {pid, {reference, phase}}, kept ->
        if pid in producers do
          Map.put(kept, pid, {reference, phase})
        else
          Process.demonitor(reference, [:flush])
          kept
        end
      end)

    monitors =
      Enum.reduce(producers, monitors, fn pid, current ->
        if Map.has_key?(current, pid),
          do: current,
          else: Map.put(current, pid, {Process.monitor(pid), :live})
      end)

    for slot <- 0..31 do
      case elem(slots, slot) do
        entry when is_tuple(entry) ->
          token = elem(entry, 0)
          stage = elem(entry, 1)
          holder = elem(entry, 2)
          retired = :ets.lookup(state.arena, {:retired, slot}) == [{{:retired, slot}, token}]
          dead = match?({_reference, :down}, monitors[holder])
          raw = tuple_size(entry) == 5

          if (retired or stage == :retiring or (stage == :ready and status == :closed) or
                ((stage == :reserved or raw) and dead)) and
               claim_retirement(state.arena, state.incarnation, slot, entry, @comparisons) do
            delete_payload(state.arena, slot, token)
            free_slot(state.arena, state.incarnation, slot, token, @comparisons)
          end

        nil ->
          :ok
      end
    end

    %{state | monitors: monitors}
  end

  # Concept: an old scan cannot revoke newly transferred custody.
  # Technical depth: the exact captured stage, holder and token must still match
  # in the state row before resident deletion. A producer DOWN after publication
  # cannot retire that owner's ready or leased copy through an older snapshot.
  defp claim_retirement(_arena, _incarnation, _slot, _expected, 0), do: false

  defp claim_retirement(
         arena,
         incarnation,
         slot,
         expected,
         remaining
       ) do
    [{:state, ^incarnation, _owner, _status, _bytes, slots, _ready} = old] =
      :ets.lookup(arena, :state)

    token = elem(expected, 0)
    stage = elem(expected, 1)
    holder = elem(expected, 2)
    charge = elem(expected, 3)

    if elem(slots, slot) == expected do
      if stage == :retiring do
        true
      else
        next = put_elem(old, 5, put_elem(slots, slot, {token, :retiring, holder, charge}))

        if replace(arena, old, next),
          do: true,
          else: claim_retirement(arena, incarnation, slot, expected, remaining - 1)
      end
    else
      false
    end
  end

  defp empty_slots?(arena) do
    [{:state, _incarnation, _owner, _status, _bytes, slots, _ready}] = :ets.lookup(arena, :state)
    Enum.all?(Tuple.to_list(slots), &is_nil/1)
  end

  defp acknowledge_ready(sink, arena) do
    receive do
      {:loopex_progress_ready, ^sink} ->
        [{:notification, flag}] = :ets.lookup(arena, :notification)
        :atomics.put(flag, 1, 0)
    after
      0 -> :ok
    end
  end

  defp notify_ready(state) do
    [{:state, _incarnation, _owner, status, _bytes, _slots, ready}] =
      :ets.lookup(state.arena, :state)

    if status == :open and ready != [] and :atomics.compare_exchange(state.flag, 1, 0, 1) == :ok do
      send(state.owner, {:loopex_progress_ready, {self(), state.incarnation, state.arena}})
    end
  end

  @doc false
  def acknowledge_ingress({_guardian, _incarnation, arena}) do
    [{:raw_notification, flag}] = :ets.lookup(arena, :raw_notification)
    :atomics.put(flag, 1, 0)
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp notify_raw(state) do
    [{:state, _incarnation, _owner, status, _bytes, slots, _ready}] =
      :ets.lookup(state.arena, :state)

    control_entries =
      for {_, :control_ready, control, _, {{_, _, _, _, _, _, _, producer}, _}} <-
            Tuple.to_list(slots),
          not Process.alive?(producer),
          uniq: true,
          do: control

    target = List.first(control_entries)

    if state.raw_target != nil and not Process.alive?(state.raw_target),
      do: :atomics.put(state.raw_flag, 1, 0)

    sink = {self(), state.incarnation, state.arena}

    if status == :open and is_pid(target) and
         :atomics.compare_exchange(state.raw_flag, 1, 0, 1) == :ok,
       do: send(target, {:loopex_progress_ingress, sink})

    relay_entries =
      for {_, :relay_ready, relay, _,
           {{_control, _route_relay, _session, _owner, gate, _kind, _header, _producer}, _order}} <-
            Tuple.to_list(slots),
          uniq: true,
          do: {relay, gate}

    Enum.each(relay_entries, fn {relay, gate} ->
      if status == :open and :atomics.compare_exchange(gate, 2, 0, 1) == :ok,
        do: send(relay, {:loopex_progress_stage, sink, gate})
    end)

    %{state | raw_target: target || state.raw_target}
  end

  defp projected?(item) when is_map(item) and not is_struct(item) and map_size(item) <= 9 do
    case item do
      %{kind: "context.compaction_progress"} ->
        match?({:ok, _}, CompactionProgress.project(item))

      %{kind: kind} when is_atom(kind) ->
        # Concept: a closed item never spends work comparing unknown keys.
        # Technical depth: lookup hashes only an atom kind and fixed atom fields;
        # equal size plus all required keys proves the map has no extra member.
        case @fields[kind] do
          fields when is_list(fields) ->
            map_size(item) == length(fields) and
              Enum.all?(fields, &Map.has_key?(item, &1)) and
              Enum.all?(fields, fn field -> member?(kind, field, Map.fetch!(item, field)) end) and
              model_payload?(item)

          _ ->
            false
        end

      _ ->
        false
    end
  end

  defp projected?(_item), do: false

  defp member?(kind, :kind, kind), do: true

  defp member?(:tool_call_delta, field, nil)
       when field in [:tool_call_id, :name, :arguments_fragment] do
    true
  end

  defp member?(_kind, field, value) when field in [:turn_id, :tool_call_id],
    do: is_binary(value) and byte_size(value) in 1..65_536

  defp member?(_kind, :stream_domain_id, value) when is_binary(value) and byte_size(value) == 32,
    do: hexadecimal?(value)

  defp member?(_kind, field, value)
       when field in [
              :model_sequence,
              :progress_sequence,
              :base_event_sequence,
              :byte_offset,
              :delta_count,
              :progress_count
            ],
       do: is_integer(value) and value in 0..@uint64

  defp member?(_kind, field, value) when field in [:content_index, :call_index],
    do: is_integer(value) and value in 0..@safe_integer

  defp member?(_kind, field, value) when field in [:text, :name, :arguments_fragment, :chunk],
    do: is_binary(value) and byte_size(value) <= 65_536 and ProgressPayload.terminal_safe?(value)

  defp member?(:tool_progress, :stream, value), do: value in ["stdout", "stderr", "progress"]

  defp member?(kind, :disposition, value)
       when kind in [:model_stream_closed, :tool_stream_closed],
       do: value in [:complete, :abandoned]

  defp member?(_kind, _field, _value), do: false

  defp model_payload?(%{kind: kind} = item)
       when kind in [:text_delta, :reasoning_delta, :tool_call_delta],
       do: Model.valid_delta?(Map.take(item, Model.delta_fields(kind)))

  defp model_payload?(_item), do: true

  # Concept: custody spans native projection, encoding and the joined output worker.
  # Technical depth: 8 KiB covers fixed map/lease/frame/control structure. For
  # total visible bytes V and backing B, each closed wire kind has encoded size
  # at most 2V plus 1 KiB of framing. After encoder scope returns, native backing
  # plus host flat, driver and two proxy copies costs at most B + 8V + 8 KiB.
  # Two backing charges plus twelve visible charges dominate that peak and the
  # earlier bounded binary-encoder cut. A per-byte list encoder must be replaced
  # before its host uses this profile. Count shared backing per field. The host
  # still retains its lease through actual worker/group retirement.
  defp binary_charge(value), do: 2 * :binary.referenced_byte_size(value) + 12 * byte_size(value)

  defp item_charge(item),
    do: Enum.reduce(item, 0, fn {_key, value}, total -> total + value_charge(value) end)

  defp value_charge(value) when is_binary(value), do: binary_charge(value)
  defp value_charge(value) when is_map(value), do: item_charge(value)
  defp value_charge(_value), do: 0

  defp hexadecimal?(<<>>), do: true

  defp hexadecimal?(<<byte, remaining::binary>>) when byte in ?0..?9 or byte in ?a..?f,
    do: hexadecimal?(remaining)

  defp hexadecimal?(_value), do: false
end
