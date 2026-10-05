defmodule LoopexCli.Model.M7CancellationGate do
  @moduledoc """
  ## Concept

  The trusted M7 fixture host's one-shot pre-transport cancellation gate. It
  holds the second distinct staged request without changing the model call.

  ## Technical depth

  This private harness module has no config grammar or persistence. Retries of
  the first digest pass. The held callback stays in its existing ProviderLifetime
  scope; delegation invokes complete/3 in that same process with the original
  request, adapter options, progress function and result. Core has already
  permitted this callback, so cancellation remains dispatched_or_unknown even
  when the downstream transport has not entered. Only callback identity, digest
  and permitted counts leave the gate as fixture observations.
  """

  use GenServer
  @behaviour Loopex.Model

  @doc false
  def start_link(host), do: GenServer.start_link(__MODULE__, host)

  @doc false
  def bind_control(gate, control), do: GenServer.call(gate, {:bind_control, control})

  @doc false
  def options(gate, module, options),
    do: [gate: gate, delegate: module, delegate_options: options]

  @doc false
  def release(gate, callback, digest, token),
    do: GenServer.call(gate, {:release, callback, digest, token})

  @doc false
  def status(gate), do: GenServer.call(gate, :status)

  @doc false
  # Concept: Fixture cleanup confirms the owner has ended before proceeding.
  # Technical depth: The host supplies one existing cleanup cutoff; stop and
  # exact DOWN consume that same remaining grace, including a suspended owner.
  def stop(gate, cleanup_cutoff_ms) do
    monitor = Process.monitor(gate)

    try do
      GenServer.stop(
        gate,
        :normal,
        max(cleanup_cutoff_ms - System.monotonic_time(:millisecond), 0)
      )
    catch
      :exit, _already_stopped -> :ok
    end

    receive do
      {:DOWN, ^monitor, :process, ^gate, _reason} -> :ok
    after
      max(cleanup_cutoff_ms - System.monotonic_time(:millisecond), 0) ->
        Process.demonitor(monitor, [:flush])
        {:error, :m7_cancellation_gate_stop_unconfirmed}
    end
  end

  @impl Loopex.Model
  def complete(request, options, progress) do
    gate = Keyword.fetch!(options, :gate)
    module = Keyword.fetch!(options, :delegate)
    forwarded = Keyword.fetch!(options, :delegate_options)

    case admission(gate, request.staged_request_digest, request.deadline) do
      :ok ->
        if System.system_time(:millisecond) < request.deadline and Process.alive?(gate),
          do: module.complete(request, forwarded, progress),
          else: {:error, :m7_cancellation_gate_closed}

      {:error, _reason} = error ->
        error
    end
  end

  # Concept: Gate admission cannot extend the model request's lifetime.
  # Technical depth: A suspended owner spends only the captured request deadline;
  # its delayed request is independently rejected when the owner resumes.
  defp admission(gate, digest, deadline) do
    remaining = max(deadline - System.system_time(:millisecond), 0)
    GenServer.call(gate, {:admit, digest, deadline}, remaining)
  catch
    :exit, {:timeout, _call} -> {:error, :m7_cancellation_gate_deadline}
    :exit, _gate_closed -> {:error, :m7_cancellation_gate_closed}
  end

  @impl GenServer
  def init(host) when is_pid(host) and node(host) == node() do
    {:ok,
     %{
       host: host,
       host_monitor: Process.monitor(host),
       control: nil,
       control_monitor: nil,
       first: nil,
       mode: :await_second,
       held: nil,
       permitted: 0
     }}
  end

  def init(_host), do: {:stop, :invalid_fixture_host}

  @impl GenServer
  def handle_call({:bind_control, control}, {caller, _}, %{host: caller, control: nil} = state)
      when is_pid(control) and node(control) == node() do
    if Process.alive?(control) do
      {:reply, :ok, %{state | control: control, control_monitor: Process.monitor(control)}}
    else
      {:reply, {:error, :m7_cancellation_gate_closed}, state}
    end
  end

  def handle_call(
        {:bind_control, control},
        {caller, _},
        %{host: caller, control: control} = state
      ),
      do: {:reply, :ok, state}

  def handle_call({:bind_control, _}, _from, state),
    do: {:reply, {:error, :invalid_gate_binding}, state}

  def handle_call(:status, _from, state),
    do: {:reply, %{permitted: state.permitted, mode: state.mode}, state}

  def handle_call({:admit, digest, deadline}, from, state) do
    cond do
      is_nil(state.control) or not alive?(state) ->
        {:reply, {:error, :m7_cancellation_gate_closed}, state}

      not is_binary(digest) or byte_size(digest) != 64 or not is_integer(deadline) ->
        {:reply, {:error, :invalid_gate_request}, state}

      System.system_time(:millisecond) >= deadline ->
        {:reply, {:error, :m7_cancellation_gate_deadline}, state}

      state.mode == :spent or is_nil(state.first) or state.first == digest ->
        {callback, _} = from
        count = state.permitted + 1
        send(state.host, {:loopex_m7_gate, :permitted, self(), callback, digest, count})
        {:reply, :ok, %{state | first: state.first || digest, permitted: count}}

      state.mode == :holding ->
        {:reply, {:error, :m7_cancellation_gate_occupied}, state}

      true ->
        {callback, _} = from
        token = make_ref()
        monitor = Process.monitor(callback)

        timer =
          Process.send_after(
            self(),
            {:deadline, token},
            max(deadline - System.system_time(:millisecond), 0)
          )

        held = %{
          from: from,
          callback: callback,
          digest: digest,
          token: token,
          monitor: monitor,
          timer: timer,
          deadline: deadline
        }

        send(state.host, {:loopex_m7_gate, :held, self(), callback, digest, token})
        {:noreply, %{state | mode: :holding, held: held}}
    end
  end

  def handle_call(
        {:release, callback, digest, token},
        {caller, _},
        %{host: caller, held: %{callback: callback, digest: digest, token: token} = held} = state
      ) do
    if alive?(state) and Process.alive?(callback) and
         System.system_time(:millisecond) < held.deadline do
      count = state.permitted + 1
      send(state.host, {:loopex_m7_gate, :permitted, self(), callback, digest, count})
      GenServer.reply(held.from, :ok)
      {:reply, :ok, %{clear_held(state) | permitted: count}}
    else
      GenServer.reply(held.from, {:error, :m7_cancellation_gate_deadline})
      {:reply, {:error, :m7_cancellation_gate_closed}, clear_held(state)}
    end
  end

  def handle_call({:release, _, _, _}, _from, state),
    do: {:reply, {:error, :invalid_gate_release}, state}

  @impl GenServer
  def handle_info({:deadline, token}, %{held: %{token: token} = held} = state) do
    GenServer.reply(held.from, {:error, :m7_cancellation_gate_deadline})
    {:noreply, clear_held(state)}
  end

  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state)
      when monitor == state.host_monitor or monitor == state.control_monitor,
      do: {:stop, :normal, state}

  def handle_info(
        {:DOWN, monitor, :process, _pid, _reason},
        %{held: %{monitor: monitor}} = state
      ),
      do: {:noreply, clear_held(state)}

  def handle_info(_stale, state), do: {:noreply, state}

  defp clear_held(%{held: held} = state) do
    Process.cancel_timer(held.timer)
    Process.demonitor(held.monitor, [:flush])
    %{state | held: nil, mode: :spent}
  end

  defp alive?(state), do: Process.alive?(state.host) and Process.alive?(state.control)
end
