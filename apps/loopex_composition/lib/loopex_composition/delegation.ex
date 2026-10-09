defmodule LoopexComposition.Delegation do
  @moduledoc """
  ## Concept

  The host-facing entry point for read-only helper children: open the helper
  owner for a durable root, give the runtime its routing executor, classify
  retained helper history, create helper-enabled parents and guard every
  ordinary mutating route.

  ## Technical depth

  ADR 0046 and ADR 0069. The host that holds the placement lease opens the
  retained-object owner and the serial helper owner, passes the returned
  handle to the reference composition, which wraps its local executor and,
  when helpers are enabled, registers the fixed `loopex.task` generation. After
  the runtime starts, `bind/2` binds the owner to that incarnation and runs the
  bounded startup classification before any durable admission. `guard/3` is
  ADR 0069's host-route guard: it refuses ordinary mutating commands on helper
  child sessions and on every session until classification completes. Hosts
  are responsible for calling it on each mutating route; a raw-runtime embedder
  is trusted host code and can bypass it.
  """

  alias LoopexComposition.Delegation.{Catalog, Helper, RetainedObjects, Router, Tool}
  alias LoopexComposition.{ProviderBindings, SessionInstructions}

  @mutating ~w(prompt steer follow_up configure compact interaction_answer abort resume)a
  @read_only ~w(attach snapshot history artifact status)a

  @doc """
  ## Concept

  Open the helper owner for one durable root and runtime identity.

  ## Technical depth

  `placement` is the host's current placement acquisition handle. Options:
  `enabled` (default false) registers the task generation for new parents;
  `recover_stale_writer` follows the Store's own stale-writer rule. The two
  owned processes are linked to the caller.
  """
  @spec open(Path.t(), binary(), term(), keyword()) :: {:ok, map()} | {:error, term()}
  def open(root, runtime_id, placement, options \\ []) do
    with {:ok, objects} <-
           RetainedObjects.open(root, runtime_id, placement,
             recover_stale_writer: Keyword.get(options, :recover_stale_writer, false)
           ),
         {:ok, helper} <-
           Helper.start_link(
             objects: objects,
             runtime_id: runtime_id,
             fault: Keyword.get(options, :fault, fn _step -> :ok end)
           ) do
      {:ok,
       %{
         objects: objects,
         helper: helper,
         runtime_id: runtime_id,
         enabled: Keyword.get(options, :enabled, false)
       }}
    end
  end

  @doc """
  ## Concept

  Open the helper owner when this host can need one.

  ## Technical depth

  A durable host whose root holds no helper ledger and whose configuration
  enables no helpers has no helper history to classify, so no owner is opened
  and `nil` is returned; every other case opens the owner. ADR 0046's rule that
  retained helper history is classified even when delegation is disabled
  therefore holds whenever any history exists.
  """
  @spec host(Path.t(), binary(), term(), boolean()) :: {:ok, map() | nil} | {:error, term()}
  def host(root, runtime_id, placement, enabled) do
    if enabled or File.dir?(Path.join(root, "delegation")),
      do: open(root, runtime_id, placement, enabled: enabled, recover_stale_writer: true),
      else: {:ok, nil}
  end

  @doc """
  ## Concept

  Stop a host's helper owner after its runtime has stopped.

  ## Technical depth

  Stops the helper owner and its retained-object writer, each with a bounded
  5,000 ms `GenServer.stop`. An owner that already exited is skipped; `nil`
  means the host never opened helpers.
  """
  @spec close(map() | nil) :: :ok
  def close(nil), do: :ok

  def close(%{helper: helper, objects: objects}) do
    for pid <- [helper, objects], Process.alive?(pid) do
      try do
        GenServer.stop(pid, :normal, 5_000)
      catch
        :exit, _ -> :ok
      end
    end

    :ok
  end

  @doc false
  def wrap(%{helper: helper}, executor), do: Router.wrap(executor, helper)

  @doc false
  def definitions(%{enabled: true}), do: [Tool.definition()]
  def definitions(_handle), do: []

  @doc """
  ## Concept

  Bind the helper owner to the started runtime and classify retained history.

  ## Technical depth

  Classification spends at most `budget_ms` (ADR 0046 fixes 60,000 ms). An
  incomplete pass keeps durable admission closed and reports covered and
  enumerated session counts plus any unreadable session.
  """
  @spec bind(map(), Loopex.Runtime.t(), Loopex.Store.t(), pos_integer()) ::
          :ok | {:error, term()}
  def bind(%{helper: helper}, runtime, store, budget_ms \\ 60_000) do
    with :ok <- Helper.bind(helper, runtime, store), do: Helper.classify(helper, budget_ms)
  end

  @doc """
  ## Concept

  Resolve one saved role into its frozen read-only genesis.

  ## Technical depth

  Captures the role's instruction file with the read-only environment facts,
  resolves its exact model through the host's provider routes and selects only
  read/grep/find/ls. The role's reply ceiling and context budgets come from the
  delegation declaration's child settings.
  """
  @spec role(Path.t(), map(), map(), [map()], pos_integer()) ::
          {:ok, map()} | {:error, term()}
  def role(workspace, role, providers, definitions, cleanup_grace_ms) do
    read_only =
      Enum.filter(
        definitions,
        &(&1["tool_id"] in ~w(loopex.read loopex.grep loopex.find loopex.ls))
      )

    with {:ok, instructions} <-
           SessionInstructions.capture_role(workspace, "read-only", role["instructions_file"]),
         {:ok, configuration} <-
           ProviderBindings.resolve_configuration(
             role
             |> Map.take(~w(model reasoning max_tokens context_token_budget system_class_tokens))
             |> Map.merge(%{"configuration_version" => 1, "instructions" => instructions}),
             providers,
             read_only
           ) do
      Catalog.role_genesis(configuration, read_only, cleanup_grace_ms)
    end
  end

  @doc """
  ## Concept

  Create one helper-enabled parent session from its frozen catalog.

  ## Technical depth

  `Catalog.capture/7` freezes every enabled role into its retained read-only
  genesis and validates the catalog bytes before the helper owner creates the
  parent, so the retained objects and the created session cannot drift. Any
  capture refusal returns before creation.
  """
  def create_parent(
        %{helper: helper, runtime_id: runtime_id},
        command,
        providers,
        roles,
        limits,
        options,
        genesis
      ) do
    with {:ok, capture} <-
           Catalog.capture(runtime_id, command, providers, roles, limits, options, genesis),
         do: Helper.create_parent(helper, capture)
  end

  @doc """
  ## Concept

  ADR 0069's guard for every ordinary mutating host route.

  ## Technical depth

  A helper child refuses every ordinary mutation; its owning operation alone
  may prompt, abort or clean it up. Until startup classification completes,
  every mutating route refuses with the covered and enumerated counts. Read-only
  attachment, inspection and history are never guarded here. A refused command
  is decided before admission, so it writes no record and starts no work.
  """
  @spec guard(map() | nil, binary(), atom()) :: :ok | {:error, term()}
  def guard(nil, _session, _command), do: :ok

  def guard(%Loopex.Runtime{supervisor: supervisor}, session, command) do
    case Registry.lookup(LoopexComposition.Delegation.Registry, supervisor) do
      [{helper, _}] -> guard(%{helper: helper}, session, command)
      [] -> :ok
    end
  end

  def guard(%{helper: helper}, session, command) when command not in @read_only do
    case Helper.classify_session(helper, session) do
      {:ok, :helper_child} -> {:error, :helper_session_owned}
      {:ok, _ordinary_or_parent} -> :ok
      {:error, :helper_classification_incomplete} -> incomplete(helper)
    end
  end

  def guard(_handle, _session, _command), do: :ok

  defp incomplete(helper) do
    case Helper.status(helper).classified do
      {:incomplete, covered, enumerated, failed} ->
        {:error, {:helper_classification_incomplete, covered, enumerated, failed}}

      _pending ->
        {:error, {:helper_classification_incomplete, 0, 0, []}}
    end
  end

  @doc false
  def mutating_commands, do: @mutating
end
