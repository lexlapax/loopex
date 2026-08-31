defmodule LoopexComposition do
  @moduledoc """
  ## Concept

  One page of shipped code that starts the reference local stack: the OTP
  application tree, a durable store, a provider adapter, a trusted-local
  executor, an artifact store, and a runtime an embedder can create a session on
  immediately.

  It ships as an application rather than as a snippet in a guide because a
  snippet is re-derived once per embedder and goes stale silently the first time
  the kernel's start-up shape changes. A shipped application changes once and
  breaks the build of every dependant that must change with it.

  It is the reference stack wired, and not a generic wiring toolkit. Because it
  names four concrete implementations, an embedder who wants a different Store,
  Model, Executor, or ArtifactStore cannot use it and composes the public ports
  and the `Loopex` facade directly. A layer general enough to serve both waits
  until a second real composition exists to give evidence for one.

  It owns wiring and never authority. The host supplies the policy that governs
  the run, and `start/1` refuses without one — a permissive default shipped here
  would answer the host's question once for every embedder that depends on this.

  ## Technical depth

  `start/1` starts the applications an `escript` does not start for it, opens the
  durable store and artifact store under an explicitly resolved state root, and
  returns a runtime. Every concrete module named here is named in this one place,
  which is what makes the dependency direction checkable: `mix loopex.deps_budget`
  reads this application's declared dependencies, and this is the only production
  application permitted to declare them.
  """

  alias Loopex.{Executor.Local, LLM.ReqLLM, Store}
  alias Loopex.Executor.Local.{CodingTools, WorkspaceLease}
  alias Loopex.Store.Local.Artifacts
  alias LoopexProtocol.Canonical

  # Concept: what the host decides stays the host's to supply.
  #
  # Technical depth: taken rather than defaulted, so a key the host did not
  # supply is absent instead of an explicit `nil` this module invented. The
  # trust decision travels beside the manifest it binds: a composition that
  # forwarded only the manifest could never stage a project block at all, which
  # made the withheld path the only path an embedder could reach.
  # `:cleanup_grace_ms` reaches both halves: the session declares it, and the
  # executor that performs the cleanup is handed the same option, so the period a
  # run's terminal reports is the period the hand actually stopped under. Neither
  # is defaulted here -- an option the host did not supply stays absent, and each
  # side falls back to the one number the port declares.
  @host_supplied ~w(project_manifest project_decision progress_to diagnostics_to
                    cleanup_grace_ms)a

  @edge_observer :"$loopex_composition_edge_observer"
  @effect_observer :"$loopex_composition_effect_observer"
  @owned :"$loopex_composition_owned"
  @stop_timeout 1_000

  @doc """
  ## Concept

  Starts the reference stack and returns a runtime.

  ## Technical depth

  `:policy` is required and has no default. `:state_root` and `:workspace` are
  resolved by the caller rather than discovered here, because where an operator's
  data lives is the host's decision.
  """
  @spec start(keyword()) :: {:ok, Loopex.Runtime.t()} | {:error, term()}
  def start(options) when is_list(options) do
    with {:ok, configuration} <- validate(options),
         do: start_owner(configuration)
  end

  def start(_options), do: {:error, :invalid_composition_options}

  @doc """
  ## Concept

  The artifact store this stack composes, for a caller retrieving a spill.

  ## Technical depth

  Returned separately because an artifact outlives the run that produced it, so
  an operator retrieving one later needs the store without needing a runtime.
  """
  @spec artifacts(binary()) :: {:ok, map()} | {:error, term()}
  def artifacts(state_root) do
    with {:ok, handle} <- Artifacts.open(Path.join(state_root, "artifacts")),
         do: {:ok, %{module: Artifacts, handle: handle}}
  end

  defp fetch_policy(options), do: policy(Keyword.get(options, :policy))
  defp policy(module) when is_atom(module) and not is_nil(module), do: {:ok, module}
  defp policy(_absent), do: {:error, :host_policy_required}

  defp validate(options) do
    with {:ok, policy} <- fetch_policy(options),
         {:ok, state_root} <- required_binary(options, :state_root),
         {:ok, workspace} <- required_binary(options, :workspace),
         {:ok, runtime_id} <- required_binary(options, :runtime_id) do
      {:ok, {options, state_root, workspace, runtime_id, policy}}
    end
  end

  defp required_binary(options, key) do
    case Keyword.fetch(options, key) do
      {:ok, value} when is_binary(value) and byte_size(value) > 0 -> {:ok, value}
      _other -> {:error, {:invalid_composition_option, key}}
    end
  end

  defp start_owner(configuration) do
    caller = self()
    tag = make_ref()
    observer = Process.get(@edge_observer, &apply/3)
    effect_observer = Process.get(@effect_observer, &apply/3)

    {owner, monitor} =
      spawn_monitor(fn -> own(caller, tag, configuration, observer, effect_observer) end)

    receive do
      {^tag, result} ->
        Process.demonitor(monitor, [:flush])
        result

      {:DOWN, ^monitor, :process, ^owner, reason} ->
        {:error, {:composition_owner_failed, reason}}
    end
  end

  defp own(caller, tag, configuration, observer, effect_observer) do
    Process.flag(:trap_exit, true)
    Process.put(@edge_observer, observer)
    Process.put(@effect_observer, effect_observer)
    Process.put(@owned, [])

    result =
      try do
        compose(configuration)
      rescue
        exception -> {:error, {:composition_start_raised, exception}}
      catch
        kind, reason -> {:error, {:composition_start_caught, kind, reason}}
      end

    case result do
      {:ok, _runtime} ->
        send(caller, {tag, result})
        receive do: ({:EXIT, _pid, _reason} -> cleanup())

      {:error, _reason} ->
        cleanup()
        send(caller, {tag, result})
    end
  end

  defp compose({options, state_root, workspace, runtime_id, policy}) do
    with :ok <- start_applications(),
         {:ok, store} <- open_store(state_root),
         {:ok, executor} <- open_executor(state_root, workspace, options) do
      start_edge(
        Loopex,
        [
          runtime_id: runtime_id,
          store: store,
          policy: policy,
          model: %{module: ReqLLM, model: ReqLLM.default_model(), options: []},
          executor: executor,
          tools: CodingTools.definitions(),
          active_tools: Enum.map(CodingTools.definitions(), & &1["tool_id"])
        ] ++ Keyword.take(options, @host_supplied)
      )
    end
  end

  defp open_store(state_root) do
    with :ok <- File.mkdir_p(state_root),
         {:ok, adapter} <- start_edge(Store.Local, path: Path.join(state_root, "store.log")),
         do: Store.new(Store.Local, adapter)
  end

  defp start_applications do
    Enum.reduce_while([:loopex, :loopex_store_local, :loopex_executor_local], :ok, fn app, :ok ->
      case effect(Application, :ensure_all_started, [app]) do
        {:ok, _started} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:application_not_started, app, reason}}}
      end
    end)
  end

  # Concept: tests observe effects without replacing the public composition.
  #
  # Technical depth: the caller-local function defaults to the real operation
  # and follows the composition owner, so production behavior and global state
  # remain unchanged while prevalidation and cleanup ordering stay observable.
  defp effect(module, function, arguments),
    do: Process.get(@effect_observer, &apply/3).(module, function, arguments)

  # The executor's declared periods and programs are forwarded rather than
  # defaulted here, so an embedder that supplies neither gets the executor's own
  # defaults and one that supplies either gets exactly what it asked for. ADR
  # 0009 requires the cleanup grace to be session configuration; forwarding it is
  # what makes a composed session able to declare one at all.
  defp open_executor(state_root, workspace, options) do
    lease_id = "workspace"
    placement = [identity: "executor-local", epoch: 1, fencing_token: 1]
    workspace_ref = "workspace:" <> Canonical.digest_bytes(workspace)

    with {:ok, lease} <-
           start_edge(WorkspaceLease, id: lease_id, path: workspace, fencing_token: 1),
         {:ok, spill} <- artifacts(state_root),
         {:ok, executor} <-
           start_edge(
             Local,
             placement ++
               [
                 workspace_leases: %{lease_id => lease},
                 ledger_root: Path.join(state_root, "receipts"),
                 artifacts: spill
               ] ++ Keyword.take(options, [:cleanup_grace_ms, :process_probe])
           ) do
      {:ok,
       Map.merge(Map.new(placement), %{
         module: Local,
         reference: executor,
         workspace_ref: workspace_ref,
         workspace_lease: lease_id
       })}
    end
  end

  # Concept: construction stays private while its forwarding remains observable.
  #
  # Technical depth: the caller-local observer exists for conformance evidence;
  # the absent key delegates directly through `apply/3`, and no exported runtime
  # accessor or VM-global test state becomes part of the reference stack.
  defp start_edge(module, options) do
    case Process.get(@edge_observer, &apply/3).(module, :start_link, [options]) do
      {:ok, resource} = result ->
        remember(module, resource)
        result

      error ->
        error
    end
  end

  defp remember(Loopex, runtime),
    do: Process.put(@owned, [{:runtime, runtime} | Process.get(@owned)])

  defp remember(_module, pid) when is_pid(pid),
    do: Process.put(@owned, [{:process, pid} | Process.get(@owned)])

  defp cleanup, do: Enum.each(Process.get(@owned, []), &stop_owned/1)

  defp stop_owned({:runtime, runtime}), do: effect(Loopex, :stop, [runtime])

  defp stop_owned({:process, pid}) do
    if Process.alive?(pid) do
      monitor = Process.monitor(pid)
      effect(Process, :exit, [pid, :shutdown])

      receive do
        {:DOWN, ^monitor, :process, ^pid, _reason} -> :ok
      after
        @stop_timeout ->
          effect(Process, :exit, [pid, :kill])
          receive do: ({:DOWN, ^monitor, :process, ^pid, _reason} -> :ok)
      end
    end
  end
end
