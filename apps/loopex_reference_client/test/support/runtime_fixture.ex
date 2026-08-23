defmodule Loopex.ReferenceClientTestModel do
  @behaviour Loopex.Model

  @impl Loopex.Model
  def complete(request, options) do
    if observer = Keyword.get(options, :observer), do: send(observer, {:model_request, request})

    tool_calls =
      case request.tools do
        [%{"name" => name}] ->
          [
            %{
              id: "deterministic-tool-call",
              name: name,
              arguments: %{
                "relative_path" => Keyword.get(options, :relative_path, "trace.txt"),
                "content" => Keyword.get(options, :content, "loopex-effect")
              }
            }
          ]

        [] ->
          []
      end

    {:ok,
     %{
       text: if(tool_calls == [], do: "terminal", else: "using controlled tool"),
       identity: %{
         provider: "deterministic",
         model: request.model,
         endpoint: "in-process"
       },
       usage: %{input_tokens: nil, output_tokens: nil},
       tool_calls: tool_calls,
       canonical_request_bytes: request.canonical_request_bytes,
       canonical_request_digest: request.canonical_request_digest
     }}
  end
end

defmodule Loopex.ReferenceClientRuntimeFixture do
  alias Loopex.Executor.Local
  alias Loopex.Executor.Local.WorkspaceLease
  alias Loopex.ReferenceClient
  alias Loopex.Store
  alias Loopex.Store.Local, as: LocalStore

  def start(label, model_module, model_options \\ [], options \\ []) do
    root =
      Keyword.get_lazy(options, :root, fn ->
        Path.join(
          System.tmp_dir!(),
          "loopex-reference-#{label}-#{System.unique_integer([:positive])}"
        )
      end)

    workspace = Path.join(root, "workspace")
    ledger = Path.join(root, "executor-ledger")
    store_path = Path.join(root, "store.log")
    File.mkdir_p!(workspace)

    lease_id = "lease-#{label}"
    fence = 73

    {:ok, store_pid} =
      LocalStore.start_link(
        path: store_path,
        recover_stale_writer: Keyword.get(options, :recover_stale_writer, false)
      )

    {:ok, store} = Store.new(LocalStore, store_pid)

    {:ok, lease} =
      WorkspaceLease.start_link(id: lease_id, path: workspace, fencing_token: fence)

    {:ok, executor} =
      Local.start_link(
        identity: "executor-local",
        epoch: 11,
        fencing_token: fence,
        workspace_leases: %{lease_id => lease},
        ledger_root: ledger
      )

    tool = %{
      "name" => "loopex_demo_write",
      "description" => "Write the fixed demonstration bytes beneath the leased workspace.",
      "input_schema" => %{
        "type" => "object",
        "properties" => %{
          "relative_path" => %{
            "type" => "string",
            "const" => Keyword.get(model_options, :relative_path, "trace.txt")
          },
          "content" => %{
            "type" => "string",
            "const" => Keyword.get(model_options, :content, "loopex-effect")
          }
        },
        "required" => ["relative_path", "content"],
        "additionalProperties" => false
      },
      "tool_id" => "loopex.demo.write",
      "tool_version" => "1.0.0",
      "effect_class" => "workspace_write"
    }

    runtime_options = [
      runtime_id: "runtime-#{label}",
      store: store,
      model: %{module: model_module, model: model_spec(model_module), options: model_options},
      executor: %{
        module: Local,
        reference: executor,
        identity: "executor-local",
        epoch: 11,
        fencing_token: fence,
        workspace_ref: "workspace-#{label}",
        workspace_lease: lease_id
      },
      tool: tool,
      grant_decision: {:host_policy, :allow},
      fault_to: Keyword.get(options, :fault_to)
    ]

    {:ok, client} = ReferenceClient.start(runtime_options)

    %{
      root: root,
      workspace: workspace,
      ledger: ledger,
      store_path: store_path,
      store_pid: store_pid,
      store: store,
      lease: lease,
      executor: executor,
      client: client,
      runtime_options: runtime_options
    }
  end

  def create(fixture, label) do
    {:ok, client} =
      ReferenceClient.create(fixture.client, %{"fixture" => label}, "create-#{label}")

    %{fixture | client: client}
  end

  def resume(fixture, session_id, cursor \\ 0) do
    {:ok, client} =
      ReferenceClient.resume(fixture.client, session_id, "resume-#{session_id}", cursor)

    %{fixture | client: client}
  end

  def records(fixture, session_id),
    do: load_pages(&Store.load_records(fixture.store, session_id, &1, 1_024), 0, [])

  def events(fixture, session_id),
    do: load_pages(&Store.load_events(fixture.store, session_id, &1, 1_024), 0, [])

  def await_terminal(fixture, attempts \\ 1_000)
  def await_terminal(_fixture, 0), do: raise("session did not reach terminal state")

  def await_terminal(fixture, attempts) do
    case ReferenceClient.status(fixture.client) do
      {:ok, %{active_run_id: nil, pending_work_ids: []}} ->
        :ok

      _other ->
        Process.sleep(10)
        await_terminal(fixture, attempts - 1)
    end
  end

  def stop_runtime(fixture) do
    if Loopex.Runtime.alive?(fixture.client.runtime), do: ReferenceClient.stop(fixture.client)
    fixture
  end

  def stop(fixture, remove_root \\ true) do
    stop_runtime(fixture)
    if Process.alive?(fixture.executor), do: GenServer.stop(fixture.executor)
    if Process.alive?(fixture.lease), do: GenServer.stop(fixture.lease)
    if Process.alive?(fixture.store_pid), do: GenServer.stop(fixture.store_pid)
    if remove_root, do: File.rm_rf!(fixture.root)
    :ok
  end

  defp model_spec(Loopex.LLM.ReqLLM), do: Loopex.LLM.ReqLLM.default_model()
  defp model_spec(_module), do: "deterministic:test"

  defp load_pages(loader, position, accumulated) do
    case loader.(position) do
      {:ok, []} ->
        Enum.reverse(accumulated)

      {:ok, rows} ->
        next =
          rows
          |> List.last()
          |> Map.get(:journal_version, Map.get(List.last(rows), :event_sequence))

        load_pages(loader, next, Enum.reverse(rows, accumulated))
    end
  end
end
