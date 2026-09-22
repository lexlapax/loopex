defmodule LoopexDaemon.ConnectionRegistry do
  @moduledoc """
  ## Concept

  The daemon has one bounded inventory of accepted client sockets. A slot is
  charged from kernel accept until every process and socket owner for that
  incarnation has been accounted for.

  ## Technical depth

  The registry serializes reservation, waiting-child creation, socket-transfer
  disposition, promotion, initialization and teardown. It starts each waiting
  connection linked inside its callback, records and monitors the returned pid
  before unlinking it, and retains `listener_owned`, `transferring`, or
  `connection_owned` until cleanup has exact evidence for the real owner. The
  accept-time initialization deadline is calculated once and its timer only
  prompts a monotonic-clock check. Private pids, references and tokens are
  redacted from formatted process status.
  """

  use GenServer
  require Logger

  alias LoopexDaemon.SocketConnection
  alias LoopexProtocol.Session.V2

  @connection_limit 512

  @typedoc false
  @type reservation :: %{
          rollback_token: binary(),
          initialize_deadline: integer()
        }

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options), do: GenServer.start_link(__MODULE__, options)

  @doc false
  @spec reserve(pid(), pid(), reference(), integer()) ::
          {:ok, reservation()}
          | {:error, :capacity_exceeded | :initialize_deadline_expired | :reservation_unavailable}
  def reserve(registry, listener, listener_incarnation, accepted_at) do
    GenServer.call(
      registry,
      {:reserve, listener, listener_incarnation, accepted_at}
    )
  end

  @doc false
  @spec start_connection(pid(), binary()) ::
          {:ok, pid(), binary()} | {:error, atom()}
  def start_connection(registry, rollback_token) do
    GenServer.call(registry, {:start_connection, rollback_token})
  end

  @doc false
  @spec begin_transfer(pid(), binary(), binary()) :: :ok | {:error, atom()}
  def begin_transfer(registry, rollback_token, connection_incarnation) do
    GenServer.call(registry, {:begin_transfer, rollback_token, connection_incarnation})
  end

  @doc false
  @spec transfer_result(pid(), binary(), binary(), :ok | {:error, term()}) ::
          :ok | {:error, atom()}
  def transfer_result(registry, rollback_token, connection_incarnation, result) do
    GenServer.call(
      registry,
      {:transfer_result, rollback_token, connection_incarnation, result}
    )
  end

  @doc false
  @spec promote(pid(), binary(), binary()) :: :ok | {:error, atom()}
  def promote(registry, rollback_token, connection_incarnation) do
    GenServer.call(registry, {:promote, rollback_token, connection_incarnation})
  end

  @doc false
  @spec initialize_complete(pid(), binary(), binary()) :: :ok | {:error, atom()}
  def initialize_complete(registry, rollback_token, connection_incarnation) do
    GenServer.call(registry, {:initialize_complete, rollback_token, connection_incarnation})
  end

  @doc false
  @spec abort_provisional(pid(), binary(), :peer_credential_unverified | :handoff_failed) ::
          :ok | {:error, :abort_unavailable}
  def abort_provisional(registry, rollback_token, reason) do
    GenServer.call(registry, {:abort_provisional, rollback_token, reason})
  end

  @doc false
  @spec listener_closed(pid(), binary()) :: :ok | {:error, :close_acknowledgement_unavailable}
  def listener_closed(registry, rollback_token) do
    GenServer.call(registry, {:listener_closed, rollback_token})
  end

  @doc false
  @spec abort_provisional_for(pid(), reference()) :: :ok | {:error, :owner_mismatch}
  def abort_provisional_for(registry, listener_incarnation) do
    GenServer.call(registry, {:abort_provisional_for, listener_incarnation})
  end

  @doc false
  @spec status(pid()) :: %{
          occupied: non_neg_integer(),
          provisional: non_neg_integer(),
          live: non_neg_integer(),
          closing: non_neg_integer(),
          limit: 512
        }
  def status(registry), do: GenServer.call(registry, :status)

  @impl true
  def init(options) do
    Process.flag(:trap_exit, true)
    owner = Keyword.fetch!(options, :owner)
    Process.link(owner)

    deadline_ms =
      Keyword.get(
        options,
        :initialize_deadline_ms,
        Map.fetch!(V2.limits(), "initialize_deadline_ms")
      )

    if is_integer(deadline_ms) and deadline_ms > 0 and
         deadline_ms <= Map.fetch!(V2.limits(), "initialize_deadline_ms") do
      Logger.debug("loopex daemon connection registry start")

      {:ok,
       %{
         owner: owner,
         connection_module: Keyword.get(options, :connection_module, SocketConnection),
         initialize_deadline_ms: deadline_ms,
         rows: %{},
         child_monitors: %{},
         listeners: %{}
       }}
    else
      {:stop, :invalid_initialize_deadline}
    end
  end

  @impl true
  def handle_call(
        {:reserve, listener, listener_incarnation, accepted_at},
        {caller, _tag},
        state
      ) do
    now = now_ms()
    deadline = accepted_at + state.initialize_deadline_ms

    cond do
      map_size(state.rows) >= @connection_limit ->
        {:reply, {:error, :capacity_exceeded}, state}

      caller != listener or not is_pid(listener) or not is_reference(listener_incarnation) or
        not is_integer(accepted_at) or accepted_at > now or now >= deadline ->
        reason =
          if caller == listener,
            do: :initialize_deadline_expired,
            else: :reservation_unavailable

        {:reply, {:error, reason}, state}

      true ->
        with {:ok, state} <- retain_listener(state, listener, listener_incarnation) do
          token = :crypto.strong_rand_bytes(16)
          timer = schedule_deadline(token, deadline, now)

          row = %{
            token: token,
            listener: listener,
            listener_incarnation: listener_incarnation,
            accepted_at: accepted_at,
            initialize_deadline: deadline,
            timer: timer,
            phase: :handing_off,
            transfer_disposition: :listener_owned,
            connection_pid: nil,
            connection_incarnation: nil,
            connection_monitor: nil,
            listener_closed: false,
            listener_down: false,
            connection_down: false,
            initialized: false,
            listener_close_requested: false,
            connection_abort_requested: false
          }

          state =
            state
            |> put_in([:rows, token], row)
            |> add_listener_token(listener_incarnation, token)

          Logger.debug("loopex daemon accepted slot reserved")

          {:reply, {:ok, %{rollback_token: token, initialize_deadline: deadline}}, state}
        else
          {:error, reason} -> {:reply, {:error, reason}, state}
        end
    end
  end

  def handle_call({:start_connection, token}, {caller, _tag}, state) do
    case Map.fetch(state.rows, token) do
      {:ok, %{phase: :handing_off, connection_pid: nil, listener: ^caller} = row} ->
        if before_deadline?(row) do
          start_waiting_connection(state, row)
        else
          state = request_abort(state, token, :initialize_deadline)
          {:reply, {:error, :initialize_deadline_expired}, state}
        end

      _other ->
        {:reply, {:error, :reservation_unavailable}, state}
    end
  end

  def handle_call({:begin_transfer, token, incarnation}, {caller, _tag}, state) do
    case Map.fetch(state.rows, token) do
      {:ok,
       %{
         phase: :handing_off,
         listener: ^caller,
         connection_incarnation: ^incarnation,
         transfer_disposition: :listener_owned
       } = row} ->
        if before_deadline?(row) do
          row = %{row | transfer_disposition: :transferring}
          {:reply, :ok, put_in(state, [:rows, token], row)}
        else
          state = request_abort(state, token, :initialize_deadline)
          {:reply, {:error, :initialize_deadline_expired}, state}
        end

      _other ->
        {:reply, {:error, :transfer_unavailable}, state}
    end
  end

  def handle_call({:transfer_result, token, incarnation, result}, {caller, _tag}, state) do
    case Map.fetch(state.rows, token) do
      {:ok,
       %{
         listener: ^caller,
         connection_incarnation: ^incarnation,
         transfer_disposition: :transferring
       } = row} ->
        transfer_result_reply(state, row, result)

      _other ->
        {:reply, {:error, :transfer_unavailable}, state}
    end
  end

  def handle_call({:promote, token, incarnation}, {caller, _tag}, state) do
    case Map.fetch(state.rows, token) do
      {:ok,
       %{
         phase: :handing_off,
         transfer_disposition: :connection_owned,
         connection_pid: ^caller,
         connection_incarnation: ^incarnation
       } = row} ->
        if before_deadline?(row) do
          row = %{row | phase: :live}
          state = put_in(state, [:rows, token], row)
          state = release_listener_token(state, row.listener_incarnation, token)
          {:reply, :ok, state}
        else
          state = request_abort(state, token, :initialize_deadline)
          {:reply, {:error, :initialize_deadline_expired}, state}
        end

      _other ->
        {:reply, {:error, :promotion_unavailable}, state}
    end
  end

  def handle_call({:initialize_complete, token, incarnation}, {caller, _tag}, state) do
    case Map.fetch(state.rows, token) do
      {:ok,
       %{
         phase: :live,
         initialized: false,
         connection_pid: ^caller,
         connection_incarnation: ^incarnation
       } = row} ->
        if before_deadline?(row) do
          cancel_timer(row.timer, token)
          row = %{row | initialized: true, timer: nil}
          {:reply, :ok, put_in(state, [:rows, token], row)}
        else
          state = close_live(state, token, :initialize_deadline)
          {:reply, {:error, :initialize_deadline_expired}, state}
        end

      _other ->
        {:reply, {:error, :initialize_unavailable}, state}
    end
  end

  def handle_call(
        {:abort_provisional, token, reason},
        {caller, _tag},
        state
      )
      when reason in [:peer_credential_unverified, :handoff_failed] do
    case Map.fetch(state.rows, token) do
      {:ok, %{listener: ^caller, phase: phase}} when phase in [:handing_off, :aborting] ->
        {:reply, :ok, request_abort(state, token, reason)}

      :error ->
        {:reply, :ok, state}

      _other ->
        {:reply, {:error, :abort_unavailable}, state}
    end
  end

  def handle_call({:abort_provisional, _token, _reason}, _from, state),
    do: {:reply, {:error, :abort_unavailable}, state}

  def handle_call(
        {:abort_provisional_for, listener_incarnation},
        {owner, _tag},
        %{owner: owner} = state
      ) do
    tokens =
      state.rows
      |> Enum.filter(fn {_token, row} ->
        row.listener_incarnation == listener_incarnation and
          row.phase in [:handing_off, :aborting]
      end)
      |> Enum.map(&elem(&1, 0))

    state = Enum.reduce(tokens, state, &request_abort(&2, &1, :listener_lost))
    {:reply, :ok, state}
  end

  def handle_call({:abort_provisional_for, _listener_incarnation}, _from, state),
    do: {:reply, {:error, :owner_mismatch}, state}

  def handle_call({:listener_closed, token}, {caller, _tag}, state) do
    case Map.fetch(state.rows, token) do
      {:ok,
       %{
         phase: :aborting,
         listener: ^caller,
         transfer_disposition: :listener_owned,
         listener_close_requested: true
       } = row} ->
        state = put_in(state, [:rows, token], %{row | listener_closed: true})
        {:reply, :ok, maybe_finish_abort(state, token)}

      :error ->
        {:reply, :ok, state}

      _other ->
        {:reply, {:error, :close_acknowledgement_unavailable}, state}
    end
  end

  def handle_call(:status, _from, state) do
    counts = Enum.frequencies_by(state.rows, fn {_token, row} -> row.phase end)

    {:reply,
     %{
       occupied: map_size(state.rows),
       provisional: Map.get(counts, :handing_off, 0) + Map.get(counts, :aborting, 0),
       live: Map.get(counts, :live, 0),
       closing: Map.get(counts, :closing, 0),
       limit: @connection_limit
     }, state}
  end

  @impl true
  def handle_info({:initialize_deadline, token}, state) do
    case Map.fetch(state.rows, token) do
      {:ok, %{initialized: false} = row} ->
        if before_deadline?(row) do
          timer = schedule_deadline(token, row.initialize_deadline, now_ms())
          {:noreply, put_in(state, [:rows, token, :timer], timer)}
        else
          state =
            if row.phase in [:live, :closing],
              do: close_live(state, token, :initialize_deadline),
              else: request_abort(state, token, :initialize_deadline)

          {:noreply, state}
        end

      _other ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, monitor, :process, pid, _reason}, state) do
    cond do
      Map.has_key?(state.child_monitors, monitor) ->
        token = Map.fetch!(state.child_monitors, monitor)
        state = %{state | child_monitors: Map.delete(state.child_monitors, monitor)}
        state = update_row(state, token, &%{&1 | connection_down: true})
        {:noreply, connection_down(state, token)}

      listener_entry = listener_for_monitor(state, monitor, pid) ->
        {incarnation, _entry} = listener_entry
        {:noreply, listener_down(state, incarnation)}

      true ->
        {:noreply, state}
    end
  end

  def handle_info({:EXIT, owner, reason}, %{owner: owner} = state),
    do: {:stop, reason, state}

  def handle_info({:EXIT, pid, _reason}, state) do
    if tracked_connection_pid?(state, pid) do
      {:noreply, state}
    else
      {:stop, :unexpected_linked_exit, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    Enum.each(state.rows, fn {_token, row} ->
      if row.connection_pid, do: Process.exit(row.connection_pid, :kill)
    end)

    Logger.debug("loopex daemon connection registry stop")
    :ok
  end

  @impl GenServer
  def format_status(status) do
    status
    |> Map.put(:state, :redacted_connection_registry_state)
    |> Map.put(:message, :redacted_connection_registry_message)
    |> Map.put(:reason, :redacted_connection_registry_reason)
    |> Map.put(:log, [])
  end

  defp start_waiting_connection(state, row) do
    incarnation = :crypto.strong_rand_bytes(16)

    options = [
      registry: self(),
      listener: row.listener,
      rollback_token: row.token,
      connection_incarnation: incarnation,
      initialize_deadline: row.initialize_deadline
    ]

    result =
      try do
        state.connection_module.start_link(options)
      catch
        :exit, _reason -> {:error, :connection_start_failed}
      end

    case result do
      {:ok, pid} ->
        monitor = Process.monitor(pid)

        row = %{
          row
          | connection_pid: pid,
            connection_incarnation: incarnation,
            connection_monitor: monitor
        }

        state =
          state
          |> put_in([:rows, row.token], row)
          |> put_in([:child_monitors, monitor], row.token)

        Process.unlink(pid)
        flush_temporary_exit(pid)

        if before_deadline?(row) do
          {:reply, {:ok, pid, incarnation}, state}
        else
          state = request_abort(state, row.token, :initialize_deadline)
          {:reply, {:error, :initialize_deadline_expired}, state}
        end

      {:error, _reason} ->
        state = request_abort(state, row.token, :connection_start_failed)
        {:reply, {:error, :connection_start_failed}, state}
    end
  end

  defp transfer_result_reply(state, row, :ok) do
    row = %{row | transfer_disposition: :connection_owned}
    state = put_in(state, [:rows, row.token], row)

    state =
      if row.phase == :aborting,
        do: request_abort(state, row.token, :transfer_aborted),
        else: state

    {:reply, :ok, state}
  end

  defp transfer_result_reply(state, row, {:error, _reason}) do
    row = %{row | transfer_disposition: :listener_owned}
    state = put_in(state, [:rows, row.token], row)
    state = request_abort(state, row.token, :transfer_failed)
    {:reply, {:error, :transfer_failed}, state}
  end

  defp transfer_result_reply(state, _row, _result),
    do: {:reply, {:error, :transfer_unavailable}, state}

  defp request_abort(state, token, reason) do
    case Map.fetch(state.rows, token) do
      {:ok, %{phase: phase} = row} when phase in [:handing_off, :aborting] ->
        abort_connection =
          not is_nil(row.connection_pid) and
            (row.transfer_disposition != :transferring or row.listener_down) and
            not row.connection_abort_requested

        close_listener =
          row.transfer_disposition == :listener_owned and not row.listener_down and
            not row.listener_close_requested

        row = %{
          row
          | phase: :aborting,
            connection_abort_requested: row.connection_abort_requested or abort_connection,
            listener_close_requested: row.listener_close_requested or close_listener
        }

        state = put_in(state, [:rows, token], row)

        if abort_connection,
          do: send(row.connection_pid, {:connection_abort, token, reason})

        if close_listener,
          do: send(row.listener, {:close_accepted, token})

        maybe_finish_abort(state, token)

      _other ->
        state
    end
  end

  defp maybe_finish_abort(state, token) do
    case Map.fetch(state.rows, token) do
      {:ok, %{phase: :aborting} = row} ->
        connection_gone = is_nil(row.connection_pid) or row.connection_down
        listener_evidence = row.listener_closed or row.listener_down

        complete =
          case row.transfer_disposition do
            :listener_owned -> connection_gone and listener_evidence
            :connection_owned -> connection_gone
            :transferring -> connection_gone and row.listener_down
          end

        if complete, do: remove_row(state, token), else: state

      _other ->
        state
    end
  end

  defp close_live(state, token, reason) do
    case Map.fetch(state.rows, token) do
      {:ok, %{phase: phase} = row} when phase in [:live, :closing] ->
        row = %{row | phase: :closing}
        if row.connection_pid, do: send(row.connection_pid, {:connection_abort, token, reason})
        put_in(state, [:rows, token], row)

      _other ->
        state
    end
  end

  defp connection_down(state, token) do
    case Map.fetch(state.rows, token) do
      {:ok, %{phase: phase}} when phase in [:live, :closing] -> remove_row(state, token)
      {:ok, %{phase: :handing_off}} -> request_abort(state, token, :connection_lost)
      {:ok, %{phase: :aborting}} -> maybe_finish_abort(state, token)
      _other -> state
    end
  end

  defp listener_down(state, incarnation) do
    tokens =
      state.rows
      |> Enum.filter(fn {_token, row} -> row.listener_incarnation == incarnation end)
      |> Enum.map(&elem(&1, 0))

    state = update_in(state.listeners, &Map.delete(&1, incarnation))

    Enum.reduce(tokens, state, fn token, acc ->
      acc = update_row(acc, token, &%{&1 | listener_down: true})

      case get_in(acc, [:rows, token, :phase]) do
        phase when phase in [:handing_off, :aborting] ->
          acc |> request_abort(token, :listener_lost) |> maybe_finish_abort(token)

        _other ->
          acc
      end
    end)
  end

  defp remove_row(state, token) do
    case Map.pop(state.rows, token) do
      {nil, _rows} ->
        state

      {row, rows} ->
        cancel_timer(row.timer, token)

        child_monitors =
          if row.connection_monitor,
            do: Map.delete(state.child_monitors, row.connection_monitor),
            else: state.child_monitors

        state = %{state | rows: rows, child_monitors: child_monitors}
        state = release_listener_token(state, row.listener_incarnation, token)
        state
    end
  end

  defp retain_listener(state, listener, incarnation) do
    case Map.fetch(state.listeners, incarnation) do
      {:ok, %{pid: ^listener}} ->
        {:ok, state}

      {:ok, _different} ->
        {:error, :reservation_unavailable}

      :error ->
        monitor = Process.monitor(listener)
        entry = %{pid: listener, monitor: monitor, tokens: MapSet.new()}
        {:ok, put_in(state, [:listeners, incarnation], entry)}
    end
  end

  defp add_listener_token(state, incarnation, token) do
    update_in(state, [:listeners, incarnation, :tokens], &MapSet.put(&1, token))
  end

  defp release_listener_token(state, incarnation, token) do
    case Map.fetch(state.listeners, incarnation) do
      {:ok, entry} ->
        tokens = MapSet.delete(entry.tokens, token)

        if MapSet.size(tokens) == 0 do
          Process.demonitor(entry.monitor, [:flush])
          update_in(state.listeners, &Map.delete(&1, incarnation))
        else
          put_in(state, [:listeners, incarnation, :tokens], tokens)
        end

      :error ->
        state
    end
  end

  defp listener_for_monitor(state, monitor, pid) do
    Enum.find(state.listeners, fn {_incarnation, entry} ->
      entry.monitor == monitor and entry.pid == pid
    end)
  end

  defp tracked_connection_pid?(state, pid),
    do: Enum.any?(state.rows, fn {_token, row} -> row.connection_pid == pid end)

  defp update_row(state, token, function) do
    case Map.fetch(state.rows, token) do
      {:ok, row} -> put_in(state, [:rows, token], function.(row))
      :error -> state
    end
  end

  defp before_deadline?(row), do: now_ms() < row.initialize_deadline

  defp now_ms, do: System.monotonic_time(:millisecond)

  defp schedule_deadline(token, deadline, now) do
    Process.send_after(self(), {:initialize_deadline, token}, max(deadline - now, 0))
  end

  defp cancel_timer(nil, _token), do: :ok

  defp cancel_timer(timer, token) do
    _ = Process.cancel_timer(timer)

    receive do
      {:initialize_deadline, ^token} -> :ok
    after
      0 -> :ok
    end
  end

  defp flush_temporary_exit(pid) do
    receive do
      {:EXIT, ^pid, _reason} -> :ok
    after
      0 -> :ok
    end
  end
end
