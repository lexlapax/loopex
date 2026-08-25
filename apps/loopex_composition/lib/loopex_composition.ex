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

  alias Loopex.Executor.Local
  alias Loopex.Executor.Local.CodingTools
  alias Loopex.Executor.Local.WorkspaceLease
  alias Loopex.LLM.ReqLLM
  alias Loopex.Store
  alias Loopex.Store.Local.Artifacts

  @doc """
  ## Concept

  Starts the reference stack and returns a runtime.

  ## Technical depth

  `:policy` is required and has no default. `:state_root` and `:workspace` are
  resolved by the caller rather than discovered here, because where an operator's
  data lives is the host's decision.
  """
  @spec start(keyword()) :: {:ok, Loopex.Runtime.t()} | {:error, term()}
  def start(options) do
    with {:ok, policy} <- fetch_policy(options),
         state_root = Keyword.fetch!(options, :state_root),
         workspace = Keyword.fetch!(options, :workspace),
         :ok <- start_applications(),
         {:ok, store} <- open_store(state_root),
         {:ok, executor} <- open_executor(state_root, workspace) do
      Loopex.start_link(
        runtime_id: Keyword.fetch!(options, :runtime_id),
        store: store,
        policy: policy,
        model: %{module: ReqLLM, model: ReqLLM.default_model(), options: []},
        executor: executor,
        tools: CodingTools.definitions(),
        active_tools: Enum.map(CodingTools.definitions(), & &1["tool_id"]),
        progress_to: Keyword.get(options, :progress_to),
        diagnostics_to: Keyword.get(options, :diagnostics_to)
      )
    end
  end

  @doc """
  ## Concept

  The artifact store this stack composes, for a caller retrieving a spill.

  ## Technical depth

  Returned separately because an artifact outlives the run that produced it, so
  an operator retrieving one later needs the store without needing a runtime.
  """
  @spec artifacts(binary()) :: {:ok, map()} | {:error, term()}
  def artifacts(state_root), do: Artifacts.open(Path.join(state_root, "artifacts"))

  defp fetch_policy(options) do
    case Keyword.get(options, :policy) do
      module when is_atom(module) and not is_nil(module) -> {:ok, module}
      _absent -> {:error, :host_policy_required}
    end
  end

  defp start_applications do
    Enum.reduce_while([:loopex, :loopex_store_local, :loopex_executor_local], :ok, fn app, :ok ->
      case Application.ensure_all_started(app) do
        {:ok, _started} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:application_not_started, app, reason}}}
      end
    end)
  end

  defp open_store(state_root) do
    with {:ok, adapter} <- Store.Local.start_link(root: Path.join(state_root, "store")) do
      Store.new(Store.Local, adapter)
    end
  end

  defp open_executor(state_root, workspace) do
    lease_id = "workspace"

    with {:ok, lease} <-
           WorkspaceLease.start_link(id: lease_id, path: workspace, fencing_token: 1),
         {:ok, executor} <-
           Local.start_link(
             identity: "executor-local",
             epoch: 1,
             fencing_token: 1,
             workspace_leases: %{lease_id => lease},
             ledger_root: Path.join(state_root, "receipts")
           ) do
      {:ok,
       %{
         module: Local,
         reference: executor,
         identity: "executor-local",
         epoch: 1,
         fencing_token: 1,
         workspace_ref: workspace,
         workspace_lease: lease_id
       }}
    end
  end
end
