defmodule Loopex.Trace.Capability do
  @moduledoc """
  ## Concept

  A host starts this token-free bridge before it composes a runtime, then binds
  it once to the runtime whose senders may exclude themselves from tracing.

  ## Technical depth

  Binding is idempotent for the exact same runtime and refuses a different
  runtime permanently. The process holds no exclusion membership: it only
  authenticates its incarnation and forwards the caller pid and adapter-owned
  MFA inventory to that runtime's `Control` process. `Control` remains the
  durable owner across tracer replacement.
  """

  use GenServer

  alias Loopex.Runtime
  alias Loopex.Runtime.Control
  alias Loopex.Runtime.Supervisor, as: RuntimeSupervisor
  alias Loopex.Trace.Capability.Handle

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options \\ []) when is_list(options),
    do: GenServer.start_link(__MODULE__, options)

  @doc false
  @spec handle(pid()) :: {:ok, Handle.t()} | {:error, :unavailable}
  def handle(pid) when is_pid(pid) do
    try do
      GenServer.call(pid, :handle)
    catch
      :exit, _reason -> {:error, :unavailable}
    end
  end

  def handle(_pid), do: {:error, :unavailable}

  @doc false
  @spec bind(Handle.t(), Runtime.t()) :: :ok | {:error, atom()}
  def bind(handle, %Runtime{} = runtime) do
    with :ok <- validate(handle) do
      call(handle, {:bind, handle.incarnation, runtime})
    end
  end

  def bind(_handle, _runtime), do: {:error, :invalid_tracing_capability}

  @doc false
  @spec exclude(Handle.t(), pid(), [{module(), atom(), non_neg_integer()}]) ::
          :ok | {:error, :unavailable}
  def exclude(handle, caller, functions) when is_pid(caller) and is_list(functions) do
    with :ok <- validate(handle) do
      call(handle, {:exclude, handle.incarnation, caller, functions})
    else
      {:error, _reason} -> {:error, :unavailable}
    end
  end

  @doc false
  @spec validate(term()) :: :ok | {:error, :invalid_tracing_capability}
  def validate(%Handle{} = handle) do
    exact_keys = Map.keys(handle) |> Enum.sort()

    if map_size(handle) == 3 and exact_keys == [:__struct__, :incarnation, :pid] and
         is_pid(handle.pid) and node(handle.pid) == node() and Process.alive?(handle.pid) and
         is_binary(handle.incarnation) and byte_size(handle.incarnation) == 16 do
      :ok
    else
      {:error, :invalid_tracing_capability}
    end
  end

  def validate(_handle), do: {:error, :invalid_tracing_capability}

  @impl GenServer
  def init(_options) do
    incarnation = :crypto.strong_rand_bytes(16)
    {:ok, %{incarnation: incarnation, binding: nil}}
  end

  @impl GenServer
  def handle_call(:handle, _from, state) do
    {:reply, {:ok, %Handle{pid: self(), incarnation: state.incarnation}}, state}
  end

  def handle_call({:bind, incarnation, runtime}, _from, %{incarnation: incarnation} = state) do
    case state.binding do
      nil ->
        case RuntimeSupervisor.control(runtime.supervisor) do
          {:ok, _control} -> {:reply, :ok, %{state | binding: runtime}}
          {:error, _reason} -> {:reply, {:error, :runtime_unavailable}, state}
        end

      ^runtime ->
        {:reply, :ok, state}

      %Runtime{} ->
        {:reply, {:error, :capability_already_bound}, state}
    end
  end

  def handle_call({:bind, _incarnation, _runtime}, _from, state) do
    {:reply, {:error, :invalid_tracing_capability}, state}
  end

  def handle_call(
        {:exclude, incarnation, caller, functions},
        from,
        %{incarnation: incarnation, binding: %Runtime{} = runtime} = state
      ) do
    case RuntimeSupervisor.control(runtime.supervisor) do
      {:ok, control} ->
        Control.exclude_trace_process(control, runtime.token, caller, functions, from)
        {:noreply, state}

      {:error, _reason} ->
        {:reply, {:error, :unavailable}, state}
    end
  end

  def handle_call({:exclude, _incarnation, _caller, _functions}, _from, state) do
    {:reply, {:error, :unavailable}, state}
  end

  @impl GenServer
  def format_status(status) do
    status
    |> Map.put(:state, :redacted_trace_capability_state)
    |> Map.put(:message, :redacted_trace_capability_message)
    |> Map.put(:reason, :redacted_trace_capability_reason)
    |> Map.put(:log, [])
  end

  defp call(%Handle{pid: pid}, message) do
    try do
      GenServer.call(pid, message, :infinity)
    catch
      :exit, _reason -> {:error, :unavailable}
    end
  end
end
