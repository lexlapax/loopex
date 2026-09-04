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

  # Concept: what the host decides stays the host's to supply; an option the
  # host did not supply is absent rather than a default this module invented.
  @host_supplied ~w(project_manifest project_decision progress_to diagnostics_to cleanup_grace_ms)a
  @edge :"$loopex_composition_edge_observer"
  @effect :"$loopex_composition_effect_observer"
  @owned :"$loopex_composition_owned"

  @doc """
  ## Concept

  Starts the reference stack and returns a runtime.

  ## Technical depth

  `:policy` is required and has no default. `:state_root` and `:workspace` are
  resolved by the caller rather than discovered here, because where an operator's
  data lives is the host's decision.

  `:recover_stale_writer` defaults to `false` and is forwarded unchanged to the
  durable store. Passing `true` asks for a writer marker left behind by a dead
  holder to be broken; the store establishes that holder's liveness itself and
  refuses a live one whoever asked, so the option cannot evict another live
  runtime on the same state root. Leaving it absent is refused by any marker,
  live holder or not, which is the pre-existing behaviour and stays the default.
  """
  @spec start(keyword()) :: {:ok, Loopex.Runtime.t()} | {:error, term()}
  def start(options) when is_list(options) do
    with {:ok, configuration} <- validate(options), do: start_owner(configuration)
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

  @required_options [:state_root, :workspace, :runtime_id]

  defp validate(options) do
    with {:ok, policy} <- policy(Keyword.get(options, :policy)),
         {:ok, [root, workspace, id]} <- required(options, @required_options),
         :ok <- boolean(options, :recover_stale_writer),
         do: {:ok, {options, root, workspace, id, policy}}
  end

  # An assertion about the world is refused unless it was actually made, rather
  # than read as truthy: only `true` and `false` say anything here.
  defp boolean(options, key) do
    if is_boolean(Keyword.get(options, key, false)),
      do: :ok,
      else: {:error, {:invalid_composition_option, key}}
  end

  defp policy(module) when is_atom(module) and not is_nil(module), do: {:ok, module}
  defp policy(_absent), do: {:error, :host_policy_required}

  defp required(options, keys) do
    Enum.reduce_while(keys, {:ok, []}, fn key, {:ok, values} ->
      case Keyword.fetch(options, key) do
        {:ok, value} when is_binary(value) and byte_size(value) > 0 ->
          {:cont, {:ok, values ++ [value]}}

        _other ->
          {:halt, {:error, {:invalid_composition_option, key}}}
      end
    end)
  end

  # Concept: one private owner acquires every process, so a later failure, a
  # runtime stop, or abnormal runtime death releases all of them. The caller's
  # observer seams travel with it so tests observe effects without global state.
  defp start_owner(configuration) do
    {caller, tag} = {self(), make_ref()}
    seams = {Process.get(@edge, &apply/3), Process.get(@effect, &apply/3)}
    {owner, monitor} = spawn_monitor(fn -> own(caller, tag, configuration, seams) end)

    receive do
      {^tag, result} ->
        Process.demonitor(monitor, [:flush])
        result

      {:DOWN, ^monitor, :process, ^owner, reason} ->
        {:error, {:composition_owner_failed, reason}}
    end
  end

  defp own(caller, tag, configuration, {edge, effect}) do
    Process.flag(:trap_exit, true)

    Enum.each([{@edge, edge}, {@effect, effect}, {@owned, []}], fn {k, v} -> Process.put(k, v) end)

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

  defp compose({options, root, workspace, runtime_id, policy}) do
    with :ok <- start_applications(),
         :ok <- File.mkdir_p(root),
         {:ok, adapter} <- start_edge(Store.Local, store_options(root, options)),
         {:ok, store} <- Store.new(Store.Local, adapter),
         {:ok, executor} <- open_executor(root, workspace, options) do
      tools = CodingTools.definitions()

      start_edge(
        Loopex,
        [runtime_id: runtime_id, store: store, policy: policy, executor: executor, tools: tools] ++
          [model: %{module: ReqLLM, model: ReqLLM.default_model(), options: []}] ++
          [active_tools: Enum.map(tools, & &1["tool_id"])] ++
          context_token_budget(options) ++
          Keyword.take(options, @host_supplied)
      )
    end
  end

  # Concept: whether a stale writer marker may be broken is asked for here and
  # decided by the store, so the option is forwarded rather than acted on.
  defp store_options(root, options),
    do: [
      path: Path.join(root, "store.log"),
      recover_stale_writer: Keyword.get(options, :recover_stale_writer, false)
    ]

  # Concept: the reference stack ships a working context-admission ceiling, and
  # an operator who names their own value gets exactly that value.
  #
  # Technical depth: ADR 0017 inserts 8,192 estimated tokens only when the host
  # omits the option. This is a bounded reference policy, not a claim about
  # Store safety or a selected model's context window, and it is a top-level
  # Runtime option that never enters `:bounds`. An explicitly supplied
  # malformed, non-positive, or above-uint64 value is refused by Runtime under
  # its own name rather than silently replaced by this default.
  defp context_token_budget(options),
    do: [context_token_budget: Keyword.get(options, :context_token_budget, 8_192)]

  defp start_applications do
    Enum.find_value([:loopex, :loopex_store_local, :loopex_executor_local], :ok, fn app ->
      case effect(Application, :ensure_all_started, [app]) do
        {:ok, _started} -> nil
        {:error, reason} -> {:error, {:application_not_started, app, reason}}
      end
    end)
  end

  # The executor's declared period and probe are forwarded, never defaulted here.
  defp open_executor(root, workspace, options) do
    placement = [identity: "executor-local", epoch: 1, fencing_token: 1]
    forwarded = Keyword.take(options, [:cleanup_grace_ms, :process_probe])

    with {:ok, lease} <-
           start_edge(WorkspaceLease, id: "workspace", path: workspace, fencing_token: 1),
         {:ok, spill} <- artifacts(root),
         owned = [
           workspace_leases: %{"workspace" => lease},
           ledger_root: Path.join(root, "receipts")
         ],
         {:ok, executor} <-
           start_edge(Local, placement ++ owned ++ [artifacts: spill] ++ forwarded) do
      identity = %{module: Local, reference: executor, workspace_lease: "workspace"}
      workspace_ref = "workspace:" <> Canonical.digest_bytes(workspace)

      {:ok,
       placement |> Map.new() |> Map.merge(identity) |> Map.put(:workspace_ref, workspace_ref)}
    end
  end

  # Concept: construction stays private while its forwarding remains observable
  # through the caller-local seams; the absent seam delegates through `apply/3`.
  defp effect(module, function, arguments),
    do: Process.get(@effect, &apply/3).(module, function, arguments)

  defp start_edge(module, options) do
    with {:ok, resource} = result <- Process.get(@edge, &apply/3).(module, :start_link, [options]) do
      Process.put(@owned, [{module, resource} | Process.get(@owned)])
      result
    end
  end

  defp cleanup, do: Enum.each(Process.get(@owned, []), &stop_owned/1)
  defp stop_owned({Loopex, runtime}), do: effect(Loopex, :stop, [runtime])

  defp stop_owned({_module, pid}) do
    if Process.alive?(pid) do
      monitor = Process.monitor(pid)
      effect(Process, :exit, [pid, :shutdown])

      receive do
        {:DOWN, ^monitor, :process, ^pid, _reason} -> :ok
      after
        1_000 ->
          effect(Process, :exit, [pid, :kill])
          receive do: ({:DOWN, ^monitor, :process, ^pid, _reason} -> :ok)
      end
    end
  end
end
