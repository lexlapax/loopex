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
  runtime supervisor's OTP parent. Owner or runtime-supervisor loss ends the
  holder. A test-only process-local seam can replace the runtime starter.
  """

  use GenServer

  alias Loopex.Runtime

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
       runtime_monitor: nil
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
          send(owner, {:phase_result, self(), ref, :runtime, {:ok, runtime}})
          send(state.root, {:phase_result, self(), ref, :runtime, {:ok, runtime}})

          {:noreply, %{state | phase: :started, runtime: runtime, runtime_monitor: monitor}}

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

  def handle_info({:DOWN, monitor, :process, owner, _reason}, state)
      when monitor == state.owner_monitor and owner == state.owner,
      do: {:stop, :normal, state}

  def handle_info({:DOWN, monitor, :process, root, _reason}, state)
      when monitor == state.root_monitor and root == state.root,
      do: {:stop, :normal, state}

  def handle_info({:DOWN, monitor, :process, supervisor, _reason}, state)
      when monitor == state.runtime_monitor and
             is_struct(state.runtime, Runtime) and supervisor == state.runtime.supervisor,
      do: {:stop, :runtime_lost, state}

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{runtime: %Runtime{supervisor: supervisor}}) do
    if Process.alive?(supervisor), do: Process.exit(supervisor, :shutdown)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  defp fresh?(deadline), do: System.monotonic_time() < deadline

  if Mix.env() == :test do
    defp install_test_seams(%{runtime_start: replacement}) when is_function(replacement, 1),
      do: Process.put({__MODULE__, :runtime_start}, replacement)

    defp install_test_seams(_seams), do: :ok

    defp runtime_start(options) do
      Process.get({__MODULE__, :runtime_start}, &Runtime.start_link/1).(options)
    end
  else
    defp install_test_seams(_seams), do: :ok
    defp runtime_start(options), do: Runtime.start_link(options)
  end
end
