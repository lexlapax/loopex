defmodule LoopexComposition.Ephemeral.SessionRoot do
  @moduledoc """
  ## Concept

  Owns one ephemeral session's temporary root and private process tree. It is
  inert when started. The session owner grants each filesystem and child-start
  step after recording the previous step's exact result.

  ## Technical depth

  Ready, grant, result and acknowledgement messages bind the owner PID, root
  PID and startup reference. `candidate_prepare` does no mutation; only the
  later root-claim grant may call `File.mkdir` through `TempRoot`. The private
  supervisor is `:one_for_all` with restart intensity zero. Its exact PID must
  be acknowledged before the first child starts, and each child result must be
  acknowledged before the next phase. A test-only process-local seam controls
  `TempRoot`'s temporary-directory and entropy dependencies.
  """

  use GenServer

  alias Loopex.Executor.Local
  alias Loopex.Executor.Local.WorkspaceLease
  alias Loopex.Runtime
  alias Loopex.Store
  alias Loopex.Store.Memory
  alias Loopex.Trace.Capability
  alias LoopexComposition.Ephemeral.{RuntimeHolder, TempRoot}

  @child_phases [:memory_store, :workspace_lease, :executor, :trace_capability, :runtime_holder]
  @next %{
    private_supervisor: :memory_store,
    memory_store: :workspace_lease,
    workspace_lease: :executor,
    executor: :trace_capability,
    trace_capability: :runtime_holder,
    runtime_holder: :holding
  }

  @doc false
  def start_link(owner, ref, deadline, configuration, test_seams \\ %{})
      when owner == self() and is_reference(ref) and is_integer(deadline) and
             is_map(configuration) do
    GenServer.start_link(__MODULE__, {owner, ref, deadline, configuration, test_seams})
  end

  @impl true
  def init({owner, ref, deadline, configuration, test_seams}) do
    Process.flag(:sensitive, true)
    install_test_seams(test_seams)
    owner_monitor = Process.monitor(owner)
    Process.send_after(self(), {:startup_deadline, ref}, remaining(deadline))

    state = %{
      owner: owner,
      owner_monitor: owner_monitor,
      ref: ref,
      deadline: deadline,
      configuration: configuration,
      phase: :candidate_prepare,
      awaiting_ack: nil,
      candidate: nil,
      collisions: 0,
      owned_root: nil,
      supervisor: nil,
      supervisor_monitor: nil,
      children: %{},
      runtime: nil
    }

    send(owner, {:root_ready, self(), ref})
    ready(state)
    {:ok, state}
  end

  @impl true
  def handle_info(
        {:grant, owner, ref, phase, payload},
        %{owner: owner, ref: ref, phase: phase, awaiting_ack: nil} = state
      ) do
    if fresh?(state.deadline) and Process.alive?(owner) do
      execute(phase, payload, state)
    else
      expired(state)
    end
  end

  def handle_info(
        {:ack, owner, ref, phase, exact_result},
        %{owner: owner, ref: ref, awaiting_ack: {phase, exact_result}} = state
      ) do
    next = Map.fetch!(@next, phase)
    next_state = %{state | phase: next, awaiting_ack: nil}
    if phase == :runtime_holder, do: send(exact_result, {self(), ref, :registered})
    if next != :holding, do: ready(next_state)
    {:noreply, next_state}
  end

  def handle_info(
        {:phase_result, holder, ref, :runtime, {:ok, %Runtime{} = runtime}},
        %{ref: ref, phase: :holding, children: %{runtime_holder: holder}} = state
      ) do
    if fresh?(state.deadline) and is_pid(runtime.supervisor) do
      next_state = %{state | phase: :trace_bind, runtime: runtime}
      ready(next_state)
      {:noreply, next_state}
    else
      {:noreply, %{state | phase: :failed, runtime: runtime}}
    end
  end

  def handle_info(
        {:phase_result, holder, ref, :runtime, _failure},
        %{ref: ref, phase: :holding, children: %{runtime_holder: holder}} = state
      ),
      do: {:noreply, %{state | phase: :failed}}

  def handle_info({:commit, owner, ref}, %{owner: owner, ref: ref, phase: :await_commit} = state) do
    if fresh?(state.deadline) do
      send(owner, {:subtree_committed, self(), ref})
      {:noreply, %{state | phase: :running}}
    else
      expired(state)
    end
  end

  def handle_info({:startup_deadline, ref}, %{ref: ref, phase: phase} = state)
      when phase != :running do
    if fresh?(state.deadline), do: {:noreply, state}, else: expired(state)
  end

  def handle_info({:DOWN, monitor, :process, owner, _reason}, state)
      when monitor == state.owner_monitor and owner == state.owner,
      do: {:stop, :normal, state}

  def handle_info({:DOWN, monitor, :process, supervisor, _reason}, state)
      when monitor == state.supervisor_monitor and supervisor == state.supervisor,
      do: {:stop, :private_supervisor_lost, state}

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{supervisor: supervisor}) when is_pid(supervisor) do
    if Process.alive?(supervisor), do: Process.exit(supervisor, :shutdown)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  defp execute(:candidate_prepare, _payload, state) do
    case TempRoot.candidate() do
      {:ok, candidate} = result ->
        advance(state, :candidate_prepare, result, :root_claim, %{candidate: candidate})

      error ->
        fail_phase(state, :candidate_prepare, error)
    end
  end

  defp execute(:root_claim, _payload, state) do
    case TempRoot.claim(state.candidate) do
      {:ok, owned} = result ->
        advance(state, :root_claim, result, :private_supervisor, %{owned_root: owned})

      {:error, :collision} when state.collisions < 15 ->
        advance(state, :root_claim, {:error, :collision}, :candidate_prepare, %{
          collisions: state.collisions + 1,
          candidate: nil
        })

      {:error, :collision} ->
        fail_phase(state, :root_claim, {:error, :temporary_root_creation_failed})

      error ->
        fail_phase(state, :root_claim, error)
    end
  end

  defp execute(:private_supervisor, _payload, state) do
    case Supervisor.start_link([],
           strategy: :one_for_all,
           max_restarts: 0,
           max_seconds: 1
         ) do
      {:ok, supervisor} ->
        monitor = Process.monitor(supervisor)

        registered(state, :private_supervisor, supervisor, %{
          supervisor: supervisor,
          supervisor_monitor: monitor
        })

      error ->
        fail_phase(state, :private_supervisor, error)
    end
  end

  defp execute(:trace_bind, _payload, state) do
    trace = Map.fetch!(state.children, :trace_capability).handle

    case bind_trace(trace, state.runtime) do
      :ok ->
        send(state.owner, {:phase_result, self(), state.ref, :trace_bind, :ok})

        prepared = %{
          root: state.owned_root,
          supervisor: state.supervisor,
          store: Map.fetch!(state.children, :memory_store),
          workspace_lease: Map.fetch!(state.children, :workspace_lease),
          executor: Map.fetch!(state.children, :executor),
          trace_capability: Map.fetch!(state.children, :trace_capability),
          runtime_holder: Map.fetch!(state.children, :runtime_holder),
          runtime: state.runtime
        }

        send(state.owner, {:subtree_prepared, self(), state.ref, prepared})
        {:noreply, %{state | phase: :await_commit}}

      error ->
        fail_phase(state, :trace_bind, error)
    end
  end

  defp execute(phase, payload, state) when phase in @child_phases do
    case child(phase, payload, state) do
      {:ok, registered} ->
        children = Map.put(state.children, phase, registered)
        registered(state, phase, registered, %{children: children})

      error ->
        fail_phase(state, phase, error)
    end
  end

  defp child(:memory_store, _payload, state) do
    case start_child(state.supervisor, Memory, []) do
      {:ok, pid} ->
        case Store.new(Memory, pid) do
          {:ok, handle} -> {:ok, %{pid: pid, handle: handle}}
          error -> {:error, {:memory_store_handle_unavailable, pid, error}}
        end

      error ->
        error
    end
  end

  defp child(:workspace_lease, _payload, state) do
    options = [id: "workspace", path: Map.fetch!(state.configuration, :cwd), fencing_token: 1]
    start_child(state.supervisor, WorkspaceLease, options)
  end

  defp child(:executor, options, state) when is_list(options) do
    reserved = [:identity, :epoch, :fencing_token, :workspace_leases, :ledger_root, :artifacts]

    if Keyword.keyword?(options) and Enum.all?(reserved, &(not Keyword.has_key?(options, &1))) do
      lease = Map.fetch!(state.children, :workspace_lease)

      fixed = [
        identity: "executor-local",
        epoch: 1,
        fencing_token: 1,
        workspace_leases: %{"workspace" => lease},
        ledger_root: Path.join(state.owned_root.path, "receipts")
      ]

      start_child(state.supervisor, Local, fixed ++ options)
    else
      {:error, :invalid_private_executor_options}
    end
  end

  defp child(:executor, _options, _state), do: {:error, :invalid_private_executor_options}

  defp child(:trace_capability, _payload, state) do
    case start_child(state.supervisor, Capability, []) do
      {:ok, pid} ->
        case Capability.handle(pid) do
          {:ok, handle} -> {:ok, %{pid: pid, handle: handle}}
          error -> {:error, {:trace_handle_unavailable, pid, error}}
        end

      error ->
        error
    end
  end

  defp child(:runtime_holder, _payload, state) do
    spec = %{
      id: RuntimeHolder,
      start:
        {RuntimeHolder, :start_link,
         [state.owner, self(), state.ref, state.deadline, runtime_holder_test_seams()]},
      restart: :permanent,
      type: :worker
    }

    Supervisor.start_child(state.supervisor, spec)
  end

  defp start_child(supervisor, module, options) do
    spec =
      Supervisor.child_spec({module, options},
        id: module,
        restart: :permanent
      )

    Supervisor.start_child(supervisor, spec)
  end

  defp advance(state, phase, result, next, changes) do
    send(state.owner, {:phase_result, self(), state.ref, phase, result})
    next_state = state |> Map.merge(changes) |> Map.put(:phase, next)
    ready(next_state)
    {:noreply, next_state}
  end

  defp registered(state, phase, result, changes) do
    send(state.owner, {:phase_result, self(), state.ref, phase, {:ok, result}})
    next_state = state |> Map.merge(changes) |> Map.put(:awaiting_ack, {phase, result})
    {:noreply, next_state}
  end

  defp fail_phase(state, phase, error) do
    send(state.owner, {:phase_result, self(), state.ref, phase, error})
    {:noreply, %{state | phase: :failed}}
  end

  defp ready(state), do: send(state.owner, {:phase_ready, self(), state.ref, state.phase})

  # Concept: the owner keeps a started private tree alive long enough to prove
  # rollback. A local startup timer must not kill its executor before the owner
  # obtains the direct process-group certificate.
  # Technical depth: before a successful root claim no child can exist, so an
  # expired blocked actor may end itself. After that, reject late grants and
  # leave the tree to the owner's bounded cleanup protocol.
  defp expired(%{owned_root: nil} = state), do: {:stop, :normal, state}
  defp expired(state), do: {:noreply, state}

  defp fresh?(deadline), do: System.monotonic_time() < deadline

  defp remaining(deadline) do
    difference = max(deadline - System.monotonic_time(), 0)
    unit = System.convert_time_unit(1, :millisecond, :native)
    div(difference + unit - 1, unit)
  end

  if Mix.env() == :test do
    defp install_test_seams(seams) when is_map(seams) do
      if is_map(seams[:temp_root]),
        do: Process.put({TempRoot, :dependencies}, seams.temp_root)

      if is_map(seams[:runtime_holder]),
        do: Process.put({__MODULE__, :runtime_holder_test_seams}, seams.runtime_holder)

      if is_function(seams[:trace_bind], 2),
        do: Process.put({__MODULE__, :trace_bind}, seams.trace_bind)

      :ok
    end

    defp install_test_seams(_seams), do: :ok

    defp runtime_holder_test_seams,
      do: Process.get({__MODULE__, :runtime_holder_test_seams}, %{})

    defp bind_trace(handle, runtime),
      do: Process.get({__MODULE__, :trace_bind}, &Capability.bind/2).(handle, runtime)
  else
    defp install_test_seams(_seams), do: :ok
    defp runtime_holder_test_seams, do: %{}
    defp bind_trace(handle, runtime), do: Capability.bind(handle, runtime)
  end
end
