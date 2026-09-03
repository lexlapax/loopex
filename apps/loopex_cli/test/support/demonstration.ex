_ = System.fetch_env!("LOOPEX_HOME")

defmodule LoopexCli.Demonstration do
  @moduledoc false

  # Concept: the stack the attended demonstration runs on, with only the model
  # swapped.
  #
  # Technical depth: the deterministic cases need a real workspace, real coding
  # tools, a real executor, and a real store, because what they support is a
  # claim about a coding task that actually changed files. Only the model is
  # scripted, and the shipped composition names one concrete model by design, so
  # this composes the same four boundaries directly rather than pretending the
  # composition is configurable. The real cases use the composition itself.

  alias Loopex.Executor.Local
  alias Loopex.Executor.Local.CodingTools
  alias Loopex.Executor.Local.WorkspaceLease
  alias Loopex.Store

  @doc """
  A disposable Git repository, created inside the task root and never anywhere
  an operator keeps their own work.
  """
  def repository(label) do
    unique = System.unique_integer([:positive])
    root = Path.join(System.tmp_dir!(), "loopex-demo-#{label}-#{unique}")
    workspace = Path.join(root, "repository")
    File.mkdir_p!(workspace)

    {_output, 0} = System.cmd("git", ["init", "--quiet", workspace], stderr_to_stdout: true)
    File.write!(Path.join(workspace, "notes.md"), "# notes\n\nfirst line\n")

    {root, workspace}
  end

  @doc """
  Starts the demonstration stack with a scripted model.
  """
  def start(options) do
    state_root = Keyword.fetch!(options, :state_root)
    workspace = Keyword.fetch!(options, :workspace)
    model_pid = Loopex.AgentLoopTestModel.start(Keyword.fetch!(options, :script))

    :ok = start_applications()
    File.mkdir_p!(state_root)

    {:ok, adapter} = Store.Local.start_link(path: Path.join(state_root, "store.log"))
    {:ok, store} = Store.new(Store.Local, adapter)
    {:ok, executor} = open_executor(state_root, workspace)

    {:ok, runtime} =
      Loopex.start_link(
        context_token_budget: Keyword.get(options, :context_token_budget, 8_192),
        runtime_id: Keyword.get(options, :runtime_id, "demonstration"),
        store: store,
        policy: Keyword.get(options, :policy, LoopexCli.Policy.AllowAll),
        model: %{
          module: Loopex.AgentLoopTestModel,
          model: "scripted:v1",
          options: [script: model_pid, max_tokens: 1024]
        },
        executor: executor,
        tools: CodingTools.definitions(),
        active_tools: Enum.map(CodingTools.definitions(), & &1["tool_id"]),
        progress_to: Keyword.get(options, :progress_to)
      )

    %{runtime: runtime, store: store, adapter: adapter, model: model_pid, workspace: workspace}
  end

  def stop(stack) do
    try do
      Loopex.stop(stack.runtime)
    catch
      :exit, _reason -> :ok
    end

    try do
      GenServer.stop(stack.adapter, :normal, 1_000)
    catch
      :exit, _reason -> :ok
    end
  end

  @doc """
  Submits one prompt and returns the attachment following it.
  """
  def prompt(stack, content) do
    {:ok, session_id} =
      Loopex.create_session(stack.runtime, %{"surface" => "demonstration"},
        command_id: "create-1"
      )

    {:ok, attachment} = Loopex.attach(stack.runtime, session_id, after_event_sequence: 0)

    {:accepted, _id} =
      Loopex.command(attachment, %{type: :prompt, command_id: "prompt-1", content: content})

    {session_id, attachment}
  end

  @doc """
  A scripted tool call naming one of the shipped coding tools.
  """
  def call(id, name, arguments), do: %{id: id, name: name, arguments: arguments}

  @doc """
  Every durable record a session committed, read back through the Store port.
  """
  def records(store, session_id) do
    {:ok, records} = Store.load_records(store, session_id, 0, 1_000)
    records
  end

  @doc """
  Opens a copy of an existing state root's log for reading.

  The log itself is left alone. Its owner holds an exclusive writer lock for as
  long as it lives, and a reader that took that lock would be competing with the
  process whose records it came to read. Reading a copy asks nothing of the
  writer and cannot disturb it.
  """
  def open_store(state_root) do
    copy_root = Path.join(state_root, "read-#{System.unique_integer([:positive])}")
    File.mkdir_p!(copy_root)
    copy = Path.join(copy_root, "store.log")
    File.cp!(Path.join(state_root, "store.log"), copy)

    {:ok, adapter} = Store.Local.start_link(path: copy)
    {:ok, store} = Store.new(Store.Local, adapter)
    {store, adapter}
  end

  defp start_applications do
    Enum.each([:loopex, :loopex_store_local, :loopex_executor_local], fn app ->
      {:ok, _started} = Application.ensure_all_started(app)
    end)

    :ok
  end

  defp open_executor(state_root, workspace) do
    lease_id = "workspace"

    {:ok, lease} = WorkspaceLease.start_link(id: lease_id, path: workspace, fencing_token: 1)

    {:ok, executor} =
      Local.start_link(
        identity: "executor-local",
        epoch: 1,
        fencing_token: 1,
        workspace_leases: %{lease_id => lease},
        ledger_root: Path.join(state_root, "receipts")
      )

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

defmodule LoopexCli.Demonstration.Evidence do
  @moduledoc false

  # Concept: what a real-provider claim has to carry before it may be made.
  #
  # Technical depth: the one field in a reply a deterministic adapter cannot
  # invent is the provider's own identifier for the response, because it exists
  # in the provider's account and an auditor can look it up there. A claim built
  # from replies that carry none is refused rather than recorded, so a fabricated
  # or accidentally-offline run cannot become an attestation with a plausible
  # shape. Nothing here proves a network call happened; no offline check can.

  @doc """
  Builds one real-call attestation from the replies a role actually observed.
  """
  def attest(role, selector, replies) when is_list(replies) do
    ids = Enum.map(replies, &Map.get(&1, "provider_response_id"))

    cond do
      replies == [] ->
        {:error, :no_replies}

      Enum.any?(ids, &(!is_binary(&1) or &1 == "")) ->
        {:error, :no_provider_response_id}

      length(Enum.uniq(ids)) != length(ids) ->
        {:error, :reused_provider_response_id}

      true ->
        {:ok,
         %{
           "role" => role,
           "selector" => selector,
           "calls" => length(ids),
           "provider_response_ids" => Enum.join(ids, "+"),
           "input_tokens" => total(replies, "input_tokens"),
           "output_tokens" => total(replies, "output_tokens")
         }}
    end
  end

  defp total(replies, field) do
    Enum.reduce(replies, 0, fn reply, sum ->
      sum + (get_in(reply, ["usage", field]) || 0)
    end)
  end
end
