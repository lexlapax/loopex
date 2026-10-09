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
  alias Loopex.Executor.Local.WorkspaceLease
  alias Loopex.Store.Local.{Artifacts, Transfers}
  alias LoopexComposition.{DurableOptions, Edges, RuntimeOwner, WorkspaceIdentity}

  require Logger

  # Concept: what the host decides stays the host's to supply; an option the
  # host did not supply is absent rather than a default this module invented.
  @host_supplied ~w(project_manifest project_decision resource_manifest progress_sink diagnostics_to cleanup_grace_ms)a
  @edge :"$loopex_composition_edge_observer"
  @effect :"$loopex_composition_effect_observer"
  @owned :"$loopex_composition_owned"

  @doc """
  ## Concept

  Starts the reference stack and returns a runtime.

  ## Technical depth

  `:policy` is required; a contextual reference's identity names only its module.
  `:state_root` and `:workspace` are
  resolved by the caller rather than discovered here, because where an operator's
  data lives is the host's decision.

  `:recover_stale_writer` defaults to `false` and is forwarded unchanged to the
  durable store. Passing `true` asks for a writer marker left behind by a dead
  holder to be broken; the store establishes that holder's liveness itself and
  refuses a live one whoever asked, so the option cannot evict another live
  runtime on the same state root. Leaving it absent is refused by any marker,
  live holder or not, which is the pre-existing behaviour and stays the default.

  `:artifact_transfers` defaults to `false`. Passing `true` hands this
  composition's artifact store to the runtime,
  so a caller may open, read and close a bounded transfer against an artifact a
  tool retained. Left absent, the runtime is handed no artifact store at all and
  refuses the whole transfer family under one name, which is what an embedder
  that only spills and later retrieves through `artifacts/1` wants: a runtime
  that named a store but held no transfer owner would refuse every transfer
  under a second, less obvious name instead. The composition always owns one
  transfer process for executor job ranges, including retained sessions resumed
  without their tools in the current host registry. Public attachment transfers
  and executor jobs share that process's capacity.

  Before owned startup effects, composition captures reference instructions,
  model capabilities, reply/context bounds and the selected tool generations
  into one current session-creation template. Core retains that template for
  implicit creation. A supplied captured template is validated and retained
  without refreshing its instructions or model facts. Reopened sessions keep
  their committed settings even when the new runtime uses different defaults.

  Successful acquisition requires Core's original creation startup barrier,
  before its retained cutoff. Composition owns its runtime while observing
  that barrier, before trace binding or publication. Startup unavailability or
  expiry uses owned cleanup; it issues no create or recovery request.

  `:model` selects a hosted `provider:model` string; Ollama is refused by this
  credential-backed durable profile. `:bounds` accepts positive unsigned-64-bit
  `:max_turns`, `:token_budget` and `:deadline_ms` members. `:sampling` accepts
  exactly `%{"max_tokens" => n}` for 1 through 1,000,000. `:active_tools` accepts
  unique defined tool ids, including an empty list; omission keeps the four
  coding tools active. Default policy identity names revision `"0.2.0"`;
  hosts may supply their own `:policy_identity`.
  Explicit `"loopex.ask"` adds the fixed interaction definition. The session
  owner handles its question through policy without an executor grant or job;
  omission leaves it outside the active selection.

  Optional `:maintenance_instructions` accepts the closed version/body map from
  ADR 0043. Validation precedes owned effects, and Core captures its exact bytes
  once for this runtime. Missing or nil remains unconfigured; composition
  supplies no instruction default.

  Optional `:maintenance_model` resolves once against the admitted provider routes
  with the registered thinking-off mapping and fixed maintenance reply allowance.
  Nil remains unconfigured. Explicit `:provider_bindings` admits only its named
  hosted routes and loads each unique credential slot once. It conflicts with a
  supplied `:credential_plane`. Borrowed version-2 planes retain their exact
  routes, registry and launch exclusions; borrowing never rereads credentials.
  Every supplied plane is validated before owned effects, and its exclusions
  reach the executor privately without entering Core configuration or jobs.
  """
  @spec start(keyword()) :: {:ok, Loopex.Runtime.t()} | {:error, term()}
  def start(options) when is_list(options) do
    with {:ok, configuration} <- DurableOptions.prepare(options),
         do: RuntimeOwner.start(configuration, &compose/1, owner_seams())
  end

  def start(_options), do: {:error, :invalid_composition_options}

  @doc """
  ## Concept

  Runs one callback with a temporary reference runtime and returns only after
  every process owned by that composition has stopped orderly.

  ## Technical depth

  The callback result is returned unchanged after confirmed cleanup. Exceptions,
  throws, and exits are reraised with their original stack after cleanup. A
  forced or unconfirmed stop returns `{:error, {:composition_cleanup_unconfirmed,
  details}}` for a normally returning callback. `start/1` retains its existing
  independent-owner lifecycle. The callback begins only after timely creation
  startup proof; an acquisition refusal never enters it.
  """
  @spec with_runtime(keyword(), (Loopex.Runtime.t() -> result)) ::
          result | {:error, term()}
        when result: term()
  def with_runtime(options, function) when is_list(options) and is_function(function, 1) do
    with {:ok, configuration} <- DurableOptions.prepare(options),
         do: RuntimeOwner.with_runtime(configuration, function, &compose/1, owner_seams())
  end

  def with_runtime(_options, _function), do: {:error, :invalid_composition_options}

  @doc """
  ## Concept

  Starts the reference edges in the caller's own process for a long-lived
  host, which then owns their links and their stop order.

  ## Technical depth

  `options` is `start/1`'s host option set plus the host-started
  `:credential_plane` map carrying `:capability` and the credential
  `:model_options`. `lifecycle` accepts only `:interrupt`, a zero-arity
  function evaluated before each of the Store, transfers, workspace
  lease, executor and runtime, and during creation startup observation;
  `{:stop, reason}` starts nothing further.
  Returns `{:ok, edges}` or `{:error, reason, partial_edges}` naming exactly
  the edges started, as `LoopexComposition.Edges` describes.
  """
  @spec start_edges(keyword(), keyword()) :: {:ok, map()} | {:error, term(), map()}
  def start_edges(options, cycle \\ []),
    do: Edges.start(options, cycle, &DurableOptions.prepare/1, &compose/1)

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

  defp owner_seams,
    do: %{
      edge: Process.get(@edge, &apply/3),
      effect: Process.get(@effect, &apply/3),
      edge_key: @edge,
      effect_key: @effect,
      owned_key: @owned
    }

  defp compose({options, root, workspace, runtime_id, policy}) do
    with {:ok, _restore} <- Loopex.Executor.Local.RestoreGuard.state(root),
         :ok <- WorkspaceIdentity.validate_manifest(options, workspace),
         :ok <- start_applications(),
         :ok <- File.mkdir_p(root),
         {:ok, options} <- LoopexComposition.ResourcePacks.retain_launch_option(options, root),
         {:ok, credential_plane} <- Edges.credential_plane(options, &start_edge/2),
         {:ok, adapter} <-
           start_edge(
             Store.Local,
             store_options(root, options, credential_plane)
           ),
         {:ok, store} <- Store.new(Store.Local, adapter),
         {:ok, spill} <- artifact_placement(root, options),
         {:ok, executor} <- open_executor(root, workspace, options, spill, credential_plane),
         executor = delegated_executor(options, executor) do
      with {:ok, runtime} <-
             start_edge(
               Loopex,
               [
                 runtime_id: runtime_id,
                 store: store,
                 policy: policy,
                 policy_identity: policy_identity(options, policy),
                 executor: executor,
                 tools:
                   DurableOptions.definitions(options) ++
                     LoopexComposition.Delegation.definitions(options[:delegation])
               ] ++
                 [
                   model:
                     LoopexComposition.Model.reference(
                       %{
                         module: ReqLLM,
                         model: Keyword.get(options, :model, ReqLLM.default_model()),
                         options:
                           Keyword.get(options, :provider_launch, []) ++
                             credential_plane.model_options ++
                             [
                               excluded_env_names:
                                 Map.get(credential_plane, :excluded_env_names, [
                                   ReqLLM.credential_variable()
                                 ])
                             ]
                       },
                       options
                     )
                 ] ++
                 DurableOptions.runtime_options(options) ++
                 context_token_budget(options) ++
                 served_artifacts(options, spill) ++
                 Keyword.take(options, @host_supplied)
             ),
           {:ok, startup_deadline} <- LoopexComposition.StartupGate.await(runtime),
           :ok <- bind_delegation(options[:delegation], runtime, store),
           :ok <- Loopex.Trace.Capability.bind(credential_plane.capability, runtime),
           :ok <- LoopexComposition.StartupGate.publication({:ok, startup_deadline}) do
        Logger.debug("reference composition trace capability bound")
        {:ok, runtime}
      end
    end
  end

  # Concept: a helper-capable host routes its executor through the helper owner.
  # Technical depth: ADR 0046's router wraps the opened local executor before the
  # runtime starts; local requests and receipts pass through unchanged.
  defp delegated_executor(options, executor) do
    case options[:delegation] do
      %{helper: _} = handle -> LoopexComposition.Delegation.wrap(handle, executor)
      _ -> executor
    end
  end

  # Concept: classification precedes durable admission but not read-only use.
  # Technical depth: an incomplete bounded pass returns the runtime with every
  # helper and mutating route closed by the guard; a binding refusal fails start.
  defp bind_delegation(nil, _runtime, _store), do: :ok

  defp bind_delegation(handle, runtime, store) do
    case LoopexComposition.Delegation.bind(handle, runtime, store) do
      :ok -> :ok
      {:error, {:helper_classification_incomplete, _, _, _}} -> :ok
      {:error, reason} -> {:error, {:delegation_unavailable, reason}}
    end
  end

  # Concept: whether a stale writer marker may be broken is asked for here and
  # decided by the store, so the option is forwarded rather than acted on.
  # Concept: which policy decided, named by this host rather than invented by the
  # runtime.
  #
  # Technical depth: accepted ADR 0024 compares this identity when a recovered
  # owner resumes an interaction, so the runtime refuses a launch that names a
  # policy without one. This reference host names its own: the module an
  # embedder chose, paired with this host's fixed policy revision. A host-supplied
  # identity takes precedence and governs current recovery checks.
  defp policy_identity(_options, nil), do: nil

  defp policy_identity(options, policy) do
    Keyword.get(options, :policy_identity) ||
      %{"id" => inspect(Loopex.Policy.adapter_module(policy)), "revision" => "0.2.0"}
  end

  defp store_options(root, options, credential_plane),
    do: [
      path: Path.join(root, "store.log"),
      recover_stale_writer: Keyword.get(options, :recover_stale_writer, false),
      excluded_env_names:
        Map.get(credential_plane, :excluded_env_names, [ReqLLM.credential_variable()])
    ]

  # Concept: startup and new sessions use the same captured context capacity.
  # Technical depth: host resolution retains authored ceilings or derives the
  # input allowance from model facts. Core never substitutes its former generic
  # default for that captured value; context capacity remains outside `:bounds`.
  defp context_token_budget(options),
    do: [
      context_token_budget:
        options[:session_creation_defaults]["initial_configuration"]["context_token_budget"]
    ]

  defp start_applications do
    Enum.find_value([:loopex, :loopex_store_local, :loopex_executor_local], :ok, fn app ->
      case effect(Application, :ensure_all_started, [app]) do
        {:ok, _started} -> nil
        {:error, reason} -> {:error, {:application_not_started, app, reason}}
      end
    end)
  end

  # Concept: one artifact store and transfer owner serve the executor's job reads
  # and any public attachment transfers the host enabled.
  #
  # Technical depth: the transfer owner is a process the handle carries rather
  # than a named global, so the descriptors of this placement belong to this
  # composition and stop with it. It is started through the same owned seam as
  # every other process here, which is what makes its cleanup part of the
  # composition's confirmed stop rather than a leak the caller must chase.
  # A resumed session's frozen read generation can be absent from today's host
  # registry. Starting this owner cannot depend on the current active-tool list.
  defp artifact_placement(root, _options) do
    with {:ok, spill} <- artifacts(root),
         {:ok, owner} <- start_edge(Transfers, root: Path.join(root, "artifacts")),
         do: {:ok, %{spill | handle: Map.put(spill.handle, :transfers, owner)}}
  end

  # Concept: the runtime is handed an artifact store exactly when the host asked
  # it to serve transfers, and never as a silent extra.
  defp served_artifacts(options, spill) do
    if Keyword.get(options, :artifact_transfers, false),
      do: [artifact_store: spill],
      else: []
  end

  # The executor's declared period and probe are forwarded, never defaulted here.
  defp open_executor(root, workspace, options, spill, credential_plane) do
    placement = [identity: "executor-local", epoch: 1, fencing_token: 1]
    forwarded = Keyword.take(options, [:cleanup_grace_ms, :process_probe])
    exclusions = Map.get(credential_plane, :excluded_env_names, [ReqLLM.credential_variable()])

    with {:ok, workspace_ref} <- WorkspaceIdentity.reference(workspace),
         {:ok, lease} <-
           start_edge(WorkspaceLease, id: "workspace", path: workspace, fencing_token: 1),
         owned = [
           workspace_leases: %{"workspace" => lease},
           ledger_root: Path.join(root, "receipts")
         ],
         {:ok, executor} <-
           start_edge(
             Local,
             placement ++ owned ++ [artifacts: spill, excluded_env_names: exclusions] ++ forwarded
           ) do
      identity = %{module: Local, reference: executor, workspace_lease: "workspace"}

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
end
