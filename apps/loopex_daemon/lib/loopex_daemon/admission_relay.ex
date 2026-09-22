defmodule LoopexDaemon.AdmissionRelay do
  @moduledoc """
  ## Concept

  One daemon process decides whether a post-initialize request entered service
  before shutdown. It retains the request's origin until the worker and its
  disposition are accounted for, so losing a socket never turns unfinished
  work into forgotten work.

  ## Technical depth

  This first relay surface owns the lightweight query, read and artifact
  permit path. A registered connection may hold at most 32 origin rows, each
  named by its 128-bit connection incarnation, local slot and strictly
  increasing sequence. A worker is monitored and receives `go` only after the
  relay has atomically changed its row from pending to executing. Result,
  worker loss, connection loss, shutdown cancellation and the worker's exact
  `DOWN` are serialized here.

  The ref-tagged `cut` barrier changes admission to draining immediately,
  returns the exact frozen permit set and one absolute monotonic deadline, and
  refuses every later row as `daemon_stopping`. Pending rows crossing that
  deadline are cancelled without dispatch. Executing non-lease work remains
  tracked for its real result or connection retirement, as the accepted M5
  shutdown order requires. Ticketed calls and lease-operation permits extend
  this same bounded ledger in later slices.
  """

  use GenServer
  require Logger

  alias LoopexProtocol.Frame

  @connection_limit 512
  @origins_per_connection 32
  @origin_limit @connection_limit * @origins_per_connection
  @control_timeout_ms 5_000
  @max_timer_ms 4_294_967_295
  @uint64_max 18_446_744_073_709_551_615

  @permit_classes [
    :session_inspect,
    :resources_catalog,
    :resources_read,
    :artifact_open_transfer,
    :artifact_read_chunk,
    :artifact_close_transfer,
    :session_list,
    :daemon_status
  ]

  @session_classes [:session_inspect, :resources_catalog, :resources_read]

  @typedoc false
  @type origin_id :: {binary(), 0..31, pos_integer()}

  @typedoc false
  @type permit_class ::
          :session_inspect
          | :resources_catalog
          | :resources_read
          | :artifact_open_transfer
          | :artifact_read_chunk
          | :artifact_close_transfer
          | :session_list
          | :daemon_status

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options), do: GenServer.start_link(__MODULE__, options)

  @doc false
  @spec register_connection(pid(), binary(), pid()) ::
          :ok
          | {:error,
             :capacity_exceeded
             | :connection_unavailable
             | :daemon_stopping
             | :invalid_connection}
  def register_connection(relay, incarnation, retirement_recipient) do
    GenServer.call(
      relay,
      {:register_connection, incarnation, retirement_recipient},
      @control_timeout_ms
    )
  end

  @doc false
  @spec open_permit(pid(), origin_id(), permit_class(), binary() | nil) ::
          {:ok, origin_id()}
          | {:error,
             :capacity_exceeded
             | :connection_unavailable
             | :daemon_stopping
             | :invalid_origin
             | :permit_conflict}
  def open_permit(relay, origin_id, class, session_id \\ nil) do
    GenServer.call(
      relay,
      {:open_permit, origin_id, class, session_id},
      @control_timeout_ms
    )
  end

  @doc false
  @spec bind_worker(pid(), origin_id(), pid(), binary()) ::
          :ok
          | {:error,
             :connection_unavailable
             | :daemon_stopping
             | :invalid_worker
             | :permit_unavailable}
  def bind_worker(relay, origin_id, worker, worker_incarnation) do
    GenServer.call(
      relay,
      {:bind_worker, origin_id, worker, worker_incarnation},
      @control_timeout_ms
    )
  end

  @doc false
  @spec complete_permit(pid(), origin_id(), binary(), map()) ::
          :ok | {:error, :connection_lost | :invalid_result | :permit_unavailable}
  def complete_permit(relay, origin_id, worker_incarnation, result) do
    GenServer.call(
      relay,
      {:complete_permit, origin_id, worker_incarnation, result},
      @control_timeout_ms
    )
  end

  @doc false
  @spec status(pid()) :: %{
          phase: :serving | :draining,
          connections: non_neg_integer(),
          permits: non_neg_integer(),
          pending: non_neg_integer(),
          executing: non_neg_integer(),
          settling: non_neg_integer(),
          connection_limit: 512,
          origin_limit: 16_384,
          admission_deadline_set: boolean()
        }
  def status(relay), do: GenServer.call(relay, :status, @control_timeout_ms)

  @impl true
  def init(options) do
    Process.flag(:trap_exit, true)
    owner = Keyword.fetch!(options, :owner)
    admission_wait_ms = Keyword.fetch!(options, :admission_wait_ms)

    if is_pid(owner) and is_integer(admission_wait_ms) and admission_wait_ms > 0 and
         admission_wait_ms <= @max_timer_ms do
      Process.link(owner)
      Logger.debug("loopex daemon admission relay start")

      {:ok,
       %{
         owner: owner,
         admission_wait_ms: admission_wait_ms,
         phase: :serving,
         cut_ref: nil,
         cut_payload: nil,
         frozen_permits: MapSet.new(),
         admission_deadline: nil,
         deadline_timer: nil,
         connections: %{},
         connection_pids: %{},
         connection_monitors: %{},
         permits: %{},
         worker_monitors: %{}
       }}
    else
      {:stop, :invalid_admission_relay_options}
    end
  end

  @impl true
  def handle_call(
        {:register_connection, incarnation, retirement_recipient},
        {caller, _tag},
        state
      ) do
    cond do
      not valid_incarnation?(incarnation) or not is_pid(retirement_recipient) ->
        {:reply, {:error, :invalid_connection}, state}

      exact_connection?(state, incarnation, caller, retirement_recipient) ->
        {:reply, :ok, state}

      state.phase != :serving ->
        {:reply, {:error, :daemon_stopping}, state}

      Map.has_key?(state.connections, incarnation) or
          Map.has_key?(state.connection_pids, caller) ->
        {:reply, {:error, :connection_unavailable}, state}

      map_size(state.connections) >= @connection_limit ->
        {:reply, {:error, :capacity_exceeded}, state}

      true ->
        monitor = Process.monitor(caller)

        connection = %{
          pid: caller,
          monitor: monitor,
          retirement_recipient: retirement_recipient,
          phase: :live,
          origins: MapSet.new(),
          sequence_by_slot: %{}
        }

        state = %{
          state
          | connections: Map.put(state.connections, incarnation, connection),
            connection_pids: Map.put(state.connection_pids, caller, incarnation),
            connection_monitors: Map.put(state.connection_monitors, monitor, incarnation)
        }

        Logger.debug("loopex daemon admission relay connection registered")
        {:reply, :ok, state}
    end
  end

  def handle_call({:open_permit, origin_id, class, session_id}, {caller, _tag}, state) do
    case existing_permit(state, origin_id, class, session_id, caller) do
      :exact ->
        {:reply, {:ok, origin_id}, state}

      :conflict ->
        {:reply, {:error, :permit_conflict}, state}

      :absent ->
        with :ok <- serving(state),
             {:ok, incarnation, slot, sequence} <- validate_origin(origin_id),
             {:ok, connection} <- caller_connection(state, incarnation, caller),
             :ok <- validate_class(class, session_id),
             :ok <- origin_capacity(state, connection),
             :ok <- sequence_available(connection, slot, sequence) do
          permit = %{
            origin_id: origin_id,
            class: class,
            session_id: session_id,
            connection_incarnation: incarnation,
            connection_pid: caller,
            phase: :pending,
            worker_pid: nil,
            worker_incarnation: nil,
            worker_monitor: nil,
            disposition: nil,
            result: nil
          }

          connection = %{
            connection
            | origins: MapSet.put(connection.origins, origin_id),
              sequence_by_slot: Map.put(connection.sequence_by_slot, slot, sequence)
          }

          state =
            state
            |> put_in([:connections, incarnation], connection)
            |> put_in([:permits, origin_id], permit)

          Logger.debug("loopex daemon admission relay permit opened")
          {:reply, {:ok, origin_id}, state}
        else
          {:error, reason} -> {:reply, {:error, reason}, state}
        end
    end
  end

  def handle_call(
        {:bind_worker, origin_id, worker, worker_incarnation},
        {caller, _tag},
        state
      ) do
    state = expire_if_due(state)

    if admission_expired?(state) do
      {:reply, {:error, :daemon_stopping}, state}
    else
      with {:ok, permit} <- pending_permit(state, origin_id),
           {:ok, _connection} <-
             caller_connection(state, permit.connection_incarnation, caller),
           :ok <- bind_admitted(state, origin_id),
           :ok <- valid_worker(worker, worker_incarnation, caller) do
        monitor = Process.monitor(worker)

        permit = %{
          permit
          | phase: :executing,
            worker_pid: worker,
            worker_incarnation: worker_incarnation,
            worker_monitor: monitor
        }

        state =
          state
          |> put_in([:permits, origin_id], permit)
          |> put_in([:worker_monitors, monitor], origin_id)

        send(worker, {:relay_go, origin_id, worker_incarnation})
        Logger.debug("loopex daemon admission relay permit executing")
        {:reply, :ok, state}
      else
        {:error, reason} -> {:reply, {:error, reason}, state}
      end
    end
  end

  def handle_call(
        {:complete_permit, origin_id, worker_incarnation, result},
        {caller, _tag},
        state
      ) do
    case Map.fetch(state.permits, origin_id) do
      {:ok,
       %{
         phase: :executing,
         worker_pid: ^caller,
         worker_incarnation: ^worker_incarnation,
         disposition: nil
       } = permit} ->
        if bounded_record?(result) do
          permit = %{permit | phase: :settling, disposition: :result, result: result}
          state = put_in(state, [:permits, origin_id], permit)

          send(permit.connection_pid, {:relay_permit_result, origin_id, result})
          Logger.debug("loopex daemon admission relay permit result")
          {:reply, :ok, state}
        else
          {:reply, {:error, :invalid_result}, state}
        end

      {:ok, %{disposition: :connection_lost}} ->
        {:reply, {:error, :connection_lost}, state}

      _other ->
        {:reply, {:error, :permit_unavailable}, state}
    end
  end

  def handle_call(:status, _from, state) do
    counts =
      Enum.reduce(state.permits, %{pending: 0, executing: 0, settling: 0}, fn
        {_id, %{phase: :pending}}, counts -> Map.update!(counts, :pending, &(&1 + 1))
        {_id, %{phase: :executing}}, counts -> Map.update!(counts, :executing, &(&1 + 1))
        {_id, %{phase: :settling}}, counts -> Map.update!(counts, :settling, &(&1 + 1))
      end)

    {:reply,
     %{
       phase: state.phase,
       connections: map_size(state.connections),
       permits: map_size(state.permits),
       pending: counts.pending,
       executing: counts.executing,
       settling: counts.settling,
       connection_limit: @connection_limit,
       origin_limit: @origin_limit,
       admission_deadline_set: not is_nil(state.admission_deadline)
     }, state}
  end

  @impl true
  def handle_info({:relay_barrier, barrier_ref, :cut}, %{phase: :serving} = state)
      when is_reference(barrier_ref) do
    now = monotonic_ms()
    deadline = now + state.admission_wait_ms
    payload = cut_payload(state, deadline)
    frozen_permits = payload.permits |> Enum.map(&elem(&1, 0)) |> MapSet.new()

    timer =
      Process.send_after(self(), {:admission_deadline, barrier_ref}, state.admission_wait_ms)

    state = %{
      state
      | phase: :draining,
        cut_ref: barrier_ref,
        cut_payload: payload,
        frozen_permits: frozen_permits,
        admission_deadline: deadline,
        deadline_timer: timer
    }

    send(state.owner, {:relay_barrier_ack, barrier_ref, :cut, payload})
    Logger.debug("loopex daemon admission relay cut")
    {:noreply, state}
  end

  def handle_info(
        {:relay_barrier, barrier_ref, :cut},
        %{phase: :draining, cut_ref: barrier_ref} = state
      ) do
    send(state.owner, {:relay_barrier_ack, barrier_ref, :cut, state.cut_payload})
    {:noreply, state}
  end

  def handle_info({:relay_barrier, _barrier_ref, :cut}, state) do
    Logger.debug("loopex daemon admission relay stale barrier ignored")
    {:noreply, state}
  end

  def handle_info(
        {:admission_deadline, barrier_ref},
        %{phase: :draining, cut_ref: barrier_ref} = state
      ) do
    now = monotonic_ms()

    if now >= state.admission_deadline do
      state = expire_pending(state)
      Logger.debug("loopex daemon admission relay deadline reached")
      {:noreply, %{state | deadline_timer: nil}}
    else
      remaining = state.admission_deadline - now
      timer = Process.send_after(self(), {:admission_deadline, barrier_ref}, remaining)
      {:noreply, %{state | deadline_timer: timer}}
    end
  end

  def handle_info({:admission_deadline, _barrier_ref}, state), do: {:noreply, state}

  def handle_info(
        {:DOWN, monitor, :process, pid, reason},
        %{connection_monitors: connection_monitors} = state
      ) do
    case Map.fetch(connection_monitors, monitor) do
      {:ok, incarnation} ->
        state = connection_down(state, incarnation, pid)
        Logger.debug("loopex daemon admission relay connection retiring")
        {:noreply, state}

      :error ->
        worker_down(state, monitor, pid, reason)
    end
  end

  def handle_info({:EXIT, owner, _reason}, %{owner: owner} = state),
    do: {:stop, :owner_lost, state}

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    Enum.each(state.permits, fn
      {_origin, %{worker_pid: worker}} when is_pid(worker) -> Process.exit(worker, :kill)
      _other -> :ok
    end)

    Logger.debug("loopex daemon admission relay stop")
    :ok
  end

  @impl GenServer
  def format_status(status) do
    status
    |> Map.put(:state, :redacted_admission_relay_state)
    |> Map.put(:message, :redacted_admission_relay_message)
    |> Map.put(:reason, :redacted_admission_relay_reason)
    |> Map.put(:log, [])
  end

  defp serving(%{phase: :serving}), do: :ok
  defp serving(_state), do: {:error, :daemon_stopping}

  defp validate_origin({incarnation, slot, sequence})
       when is_binary(incarnation) and byte_size(incarnation) == 16 and
              is_integer(slot) and slot in 0..31 and is_integer(sequence) and
              sequence in 1..@uint64_max,
       do: {:ok, incarnation, slot, sequence}

  defp validate_origin(_origin_id), do: {:error, :invalid_origin}

  defp validate_class(class, session_id) when class in @session_classes do
    if is_binary(session_id) and byte_size(session_id) in 1..256,
      do: :ok,
      else: {:error, :invalid_origin}
  end

  defp validate_class(class, nil) when class in @permit_classes, do: :ok
  defp validate_class(_class, _session_id), do: {:error, :invalid_origin}

  defp origin_capacity(state, connection) do
    cond do
      MapSet.size(connection.origins) >= @origins_per_connection ->
        {:error, :capacity_exceeded}

      map_size(state.permits) >= @origin_limit ->
        {:error, :capacity_exceeded}

      true ->
        :ok
    end
  end

  defp sequence_available(connection, slot, sequence) do
    case Map.get(connection.sequence_by_slot, slot) do
      nil -> :ok
      previous when sequence > previous -> :ok
      _previous -> {:error, :invalid_origin}
    end
  end

  defp existing_permit(state, origin_id, class, session_id, caller) do
    case Map.fetch(state.permits, origin_id) do
      {:ok, %{class: ^class, session_id: ^session_id, connection_pid: ^caller}} -> :exact
      {:ok, _other} -> :conflict
      :error -> :absent
    end
  end

  defp pending_permit(state, origin_id) do
    case Map.fetch(state.permits, origin_id) do
      {:ok, %{phase: :pending} = permit} -> {:ok, permit}
      _other -> {:error, :permit_unavailable}
    end
  end

  defp bind_admitted(%{phase: :serving}, _origin_id), do: :ok

  defp bind_admitted(%{phase: :draining} = state, origin_id) do
    if monotonic_ms() < state.admission_deadline and frozen_permit?(state, origin_id),
      do: :ok,
      else: {:error, :daemon_stopping}
  end

  defp valid_worker(worker, worker_incarnation, caller) do
    if is_pid(worker) and worker != caller and valid_incarnation?(worker_incarnation),
      do: :ok,
      else: {:error, :invalid_worker}
  end

  defp caller_connection(state, incarnation, caller) do
    case Map.fetch(state.connections, incarnation) do
      {:ok, %{pid: ^caller, phase: :live} = connection} -> {:ok, connection}
      _other -> {:error, :connection_unavailable}
    end
  end

  defp exact_connection?(state, incarnation, caller, retirement_recipient) do
    match?(
      %{pid: ^caller, retirement_recipient: ^retirement_recipient, phase: :live},
      Map.get(state.connections, incarnation)
    )
  end

  defp valid_incarnation?(incarnation),
    do: is_binary(incarnation) and byte_size(incarnation) == 16

  defp bounded_record?(result) when is_map(result) and not is_struct(result) do
    try do
      match?({:ok, _encoded}, Frame.encode(result))
    rescue
      _error -> false
    catch
      _kind, _reason -> false
    end
  end

  defp bounded_record?(_result), do: false

  defp cut_payload(state, deadline) do
    permits =
      state.permits
      |> Enum.map(fn {origin_id, permit} -> {origin_id, frozen_phase(permit.phase)} end)
      |> Enum.sort()

    %{
      admission_deadline: deadline,
      tickets: [],
      permits: permits
    }
  end

  defp frozen_phase(:pending), do: :pending
  defp frozen_phase(:executing), do: :executing
  defp frozen_phase(:settling), do: :settling

  defp frozen_permit?(state, origin_id) do
    MapSet.member?(state.frozen_permits, origin_id)
  end

  defp expire_if_due(%{phase: :draining} = state) do
    if monotonic_ms() >= state.admission_deadline, do: expire_pending(state), else: state
  end

  defp expire_if_due(state), do: state

  defp admission_expired?(%{phase: :draining} = state),
    do: monotonic_ms() >= state.admission_deadline

  defp admission_expired?(_state), do: false

  defp expire_pending(state) do
    state.permits
    |> Enum.filter(fn {_origin, permit} -> permit.phase == :pending end)
    |> Enum.reduce(state, fn {origin_id, permit}, acc ->
      send(permit.connection_pid, {:relay_permit_cancelled, origin_id, :daemon_stopping})
      remove_permit(acc, origin_id)
    end)
  end

  defp connection_down(state, incarnation, pid) do
    case Map.fetch(state.connections, incarnation) do
      {:ok, %{pid: ^pid} = connection} ->
        connection = %{connection | phase: :closing}

        state =
          state
          |> put_in([:connections, incarnation], connection)
          |> update_in([:connection_pids], &Map.delete(&1, pid))
          |> update_in([:connection_monitors], &Map.delete(&1, connection.monitor))

        Enum.reduce(connection.origins, state, fn origin_id, acc ->
          lose_connection_permit(acc, origin_id)
        end)
        |> maybe_retire_connection(incarnation)

      _other ->
        state
    end
  end

  defp lose_connection_permit(state, origin_id) do
    case Map.fetch(state.permits, origin_id) do
      {:ok, %{phase: :pending}} ->
        remove_permit(state, origin_id)

      {:ok, %{worker_pid: worker} = permit} when is_pid(worker) ->
        if Process.alive?(worker), do: Process.exit(worker, :kill)

        disposition = permit.disposition || :connection_lost
        permit = %{permit | phase: :settling, disposition: disposition, result: nil}
        put_in(state, [:permits, origin_id], permit)

      _other ->
        state
    end
  end

  defp worker_down(state, monitor, pid, _reason) do
    case Map.pop(state.worker_monitors, monitor) do
      {nil, _worker_monitors} ->
        {:noreply, state}

      {origin_id, worker_monitors} ->
        state = %{state | worker_monitors: worker_monitors}

        case Map.fetch(state.permits, origin_id) do
          {:ok, %{worker_pid: ^pid} = permit} ->
            state =
              if permit.disposition do
                remove_permit(state, origin_id)
              else
                if Process.alive?(permit.connection_pid) do
                  send(
                    permit.connection_pid,
                    {:relay_permit_failed, origin_id, :worker_lost}
                  )
                end

                remove_permit(state, origin_id)
              end

            Logger.debug("loopex daemon admission relay worker reaped")
            {:noreply, maybe_retire_connection(state, permit.connection_incarnation)}

          _other ->
            {:noreply, state}
        end
    end
  end

  defp remove_permit(state, origin_id) do
    case Map.pop(state.permits, origin_id) do
      {nil, _permits} ->
        state

      {permit, permits} ->
        connections =
          case Map.fetch(state.connections, permit.connection_incarnation) do
            {:ok, connection} ->
              connection = %{connection | origins: MapSet.delete(connection.origins, origin_id)}
              Map.put(state.connections, permit.connection_incarnation, connection)

            :error ->
              state.connections
          end

        %{state | permits: permits, connections: connections}
    end
  end

  defp maybe_retire_connection(state, incarnation) do
    case Map.fetch(state.connections, incarnation) do
      {:ok, %{phase: :closing, origins: origins} = connection} ->
        if MapSet.size(origins) == 0 do
          send(
            connection.retirement_recipient,
            {:relay_connection_retired, self(), incarnation}
          )

          Logger.debug("loopex daemon admission relay connection retired")
          %{state | connections: Map.delete(state.connections, incarnation)}
        else
          state
        end

      _other ->
        state
    end
  end

  defp monotonic_ms, do: System.monotonic_time(:millisecond)
end
