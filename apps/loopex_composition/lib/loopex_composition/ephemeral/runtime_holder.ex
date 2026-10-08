defmodule LoopexComposition.Ephemeral.RuntimeHolder do
  @moduledoc """
  ## Concept

  Keeps one ephemeral runtime beneath its session's private supervisor. Starting
  the holder does not start a runtime. Only the creating session owner may grant
  that separate step.

  ## Technical depth

  The owner registers and monitors the holder from SessionRoot's returned PID.
  Only SessionRoot's later registration notice releases its ready report. A matching
  grant starts `Loopex.Runtime` in this process, so the holder remains the
  runtime supervisor's OTP parent. Before reporting that runtime, an owned
  observer reads creation startup under the earlier of the original caller
  deadline and Core's exactly converted cutoff. The holder processes owner,
  root and runtime loss while a read is held, and retires the observer through
  its exact monitor before publication. Test-only process-local seams can
  replace the runtime starter and startup reader.
  """

  use GenServer

  alias Loopex.Runtime
  alias LoopexComposition.StartupGate

  @doc false
  def start_link(owner, root, ref, deadline, test_seams \\ %{})
      when is_pid(owner) and is_pid(root) and is_reference(ref) and is_integer(deadline) do
    GenServer.start_link(__MODULE__, {owner, root, ref, deadline, test_seams})
  end

  @impl true
  def init({owner, root, ref, deadline, test_seams}) do
    Process.flag(:sensitive, true)
    install_test_seams(test_seams)
    owner_monitor = Process.monitor(owner)
    root_monitor = Process.monitor(root)

    {:ok,
     %{
       owner: owner,
       root: root,
       ref: ref,
       deadline: deadline,
       owner_monitor: owner_monitor,
       root_monitor: root_monitor,
       phase: :blocked,
       runtime: nil,
       runtime_monitor: nil,
       observer: nil,
       observation_result: nil,
       stop_reason: nil
     }}
  end

  @impl true
  def handle_info({root, ref, :registered}, %{root: root, ref: ref, phase: :blocked} = state) do
    if fresh?(state.deadline) do
      send(state.owner, {:phase_ready, self(), ref, :runtime})
      {:noreply, %{state | phase: :ready}}
    else
      send(
        state.owner,
        {:phase_result, self(), ref, :runtime, {:error, :startup_deadline_expired}}
      )

      send(root, {:phase_result, self(), ref, :runtime, {:error, :startup_deadline_expired}})
      {:noreply, %{state | phase: :failed}}
    end
  end

  def handle_info(
        {:grant, owner, ref, :runtime, options},
        %{owner: owner, ref: ref, phase: :ready} = state
      )
      when is_list(options) do
    if fresh?(state.deadline) do
      case runtime_start(options) do
        {:ok, %Runtime{supervisor: supervisor} = runtime} when is_pid(supervisor) ->
          monitor = Process.monitor(supervisor)
          send(owner, {:runtime_custody, self(), ref, runtime})
          send(state.root, {:runtime_custody, self(), ref, runtime})

          {:noreply,
           %{state | phase: :owned, runtime: runtime, runtime_monitor: monitor}}

        result ->
          send(owner, {:phase_result, self(), ref, :runtime, result})
          send(state.root, {:phase_result, self(), ref, :runtime, result})
          {:noreply, %{state | phase: :failed}}
      end
    else
      send(owner, {:phase_result, self(), ref, :runtime, {:error, :startup_deadline_expired}})

      send(
        state.root,
        {:phase_result, self(), ref, :runtime, {:error, :startup_deadline_expired}}
      )

      {:noreply, %{state | phase: :failed}}
    end
  end

  # Concept: custody is known before startup observation can be held.
  # Technical depth: only the original owner's exact acknowledgement releases
  # the reader. This reports no readiness and advances no startup phase.
  def handle_info({:runtime_custody_ack, owner, ref, runtime},
        %{owner: owner, ref: ref, phase: :owned, runtime: runtime} = state) do
    observer = StartupGate.start(runtime, state.deadline, status_reader())
    {:noreply, %{state | phase: :observing, observer: observer}}
  end

  def handle_info({tag, result}, %{phase: :observing, observer: %{tag: tag} = observer} = state) do
    Process.unlink(observer.pid)
    {:noreply, %{state | observation_result: result}}
  end

  def handle_info({:DOWN, monitor, :process, pid, _reason},
        %{phase: :observing, observer: %{pid: pid, monitor: monitor}, stop_reason: reason} = state)
      when reason != nil do
    {:stop, reason, %{state | observer: nil}}
  end

  def handle_info({:DOWN, monitor, :process, pid, _reason},
        %{phase: :observing, observer: %{pid: pid, monitor: monitor}} = state) do
    publish_observation(%{state | observer: nil})
  end

  def handle_info({:DOWN, monitor, :process, owner, _reason}, state)
      when monitor == state.owner_monitor and owner == state.owner,
      do: stop_observation(state, :normal)

  def handle_info({:DOWN, monitor, :process, root, _reason}, state)
      when monitor == state.root_monitor and root == state.root,
      do: stop_observation(state, :normal)

  def handle_info({:DOWN, monitor, :process, supervisor, _reason}, state)
      when monitor == state.runtime_monitor and
             is_struct(state.runtime, Runtime) and supervisor == state.runtime.supervisor,
      do: stop_observation(state, :runtime_lost)

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{runtime: %Runtime{supervisor: supervisor}} = state) do
    if state.observer, do: StartupGate.cancel_async(state.observer)
    if Process.alive?(supervisor), do: Process.exit(supervisor, :shutdown)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  defp publish_observation(state) do
    result = state.observation_result || {:error, :runtime_unavailable}

    result =
      if Process.alive?(state.owner) and Process.alive?(state.root) and
           Process.alive?(state.runtime.supervisor) do
        case StartupGate.publication(result) do
          :ok -> {:ok, state.runtime}
          error -> error
        end
      else
        {:error, :runtime_unavailable}
      end

    send(state.owner, {:phase_result, self(), state.ref, :runtime, result})
    send(state.root, {:phase_result, self(), state.ref, :runtime, result})
    phase = if match?({:ok, _}, result), do: :started, else: :failed
    {:noreply, %{state | phase: phase, observer: nil}}
  end

  defp stop_observation(%{observer: nil} = state, reason), do: {:stop, reason, state}

  defp stop_observation(state, reason) do
    StartupGate.cancel_async(state.observer)
    {:noreply, %{state | stop_reason: reason}}
  end

  defp fresh?(deadline), do: System.monotonic_time() < deadline

  if Mix.env() == :test do
    defp install_test_seams(seams) when is_map(seams) do
      if is_function(seams[:runtime_start], 1),
        do: Process.put({__MODULE__, :runtime_start}, seams.runtime_start)

      if is_function(seams[:creation_startup_status], 2),
        do: Process.put({__MODULE__, :creation_startup_status}, seams.creation_startup_status)

      :ok
    end

    defp install_test_seams(_seams), do: :ok

    defp runtime_start(options) do
      Process.get({__MODULE__, :runtime_start}, &Runtime.start_link/1).(options)
    end

    defp status_reader,
      do: Process.get({__MODULE__, :creation_startup_status}, &Loopex.creation_startup_status/2)
  else
    defp install_test_seams(_seams), do: :ok
    defp runtime_start(options), do: Runtime.start_link(options)
    defp status_reader, do: &Loopex.creation_startup_status/2
  end
end
