defmodule Loopex.ReferenceClientTestModel do
  @behaviour Loopex.Model

  @impl Loopex.Model
  def complete(request, options, progress \\ nil) do
    if observer = Keyword.get(options, :observer), do: send(observer, {:model_request, request})

    progress = progress || Loopex.Model.discard_progress()

    # The deterministic adapter asks for its tool once and then stops, so the
    # loop terminates on the model's own decision rather than on a turn counter.
    already_called? =
      Enum.any?(request.messages, &(Map.get(&1, "role") == "tool"))

    tool_calls =
      case {already_called?, request.tools} do
        {false, [%{"name" => name} | _rest]} ->
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

        _otherwise ->
          []
      end

    text = if tool_calls == [], do: "terminal", else: "using controlled tool"

    deltas =
      if Keyword.get(options, :stream, false) do
        for chunk <- String.split(text, " "), reduce: 0 do
          count ->
            progress.(%{kind: :text_delta, content_index: 0, text: chunk})
            count + 1
        end
      else
        0
      end

    {:ok,
     %{
       text: text,
       identity: %{
         provider: "deterministic",
         model: request.model,
         endpoint: "in-process"
       },
       # ADR 0018: an attempt whose usage is not a complete reported pair is
       # charged the whole remaining allowance; the scripted model reports.
       usage: %{input_tokens: 1, output_tokens: 1},
       tool_calls: tool_calls,
       delta_count: deltas,
       streamed: deltas > 0,
       canonical_request_bytes: request.canonical_request_bytes,
       staged_request_digest: request.staged_request_digest
     }}
  end
end

defmodule Loopex.ReferenceClientRuntimeFixture do
  alias Loopex.Executor
  alias Loopex.Executor.Local
  alias Loopex.Executor.Local.WorkspaceLease
  alias Loopex.ReferenceClient
  alias Loopex.Store
  alias Loopex.Store.Local, as: LocalStore

  @demo_tool_wall_time_ms 30_000

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
        [
          identity: "executor-local",
          epoch: 11,
          fencing_token: fence,
          workspace_leases: %{lease_id => lease},
          ledger_root: ledger
        ] ++ Keyword.get(options, :executor_options, [])
      )

    # The demonstration tool is an ordinary registered generation now. It keeps
    # M1's exact identity and version so the inherited executor and recovery
    # cases still resolve it, and it reaches the model only because this test
    # composition selects it; nothing in the reference distribution does.
    tool = %{
      "tool_id" => "loopex.demo.write",
      "tool_version" => "1.0.0",
      "name" => "loopex_demo_write",
      "description" => "Write the fixed demonstration bytes beneath the leased workspace.",
      "parameter_schema" => %{
        "type" => "object",
        "properties" => %{
          "relative_path" => %{"type" => "string"},
          "content" => %{"type" => "string"}
        },
        "required" => ["relative_path", "content"]
      },
      "result_shape" => %{"content_type" => "text", "description" => "What was written."},
      "effect_class" => "workspace_write",
      "idempotency_class" => "reconcile_then_retry",
      "budgets" => %{
        "wall_time_ms" => @demo_tool_wall_time_ms,
        "output_bytes" => 1_048_576,
        "artifact_bytes" => 1_048_576
      }
    }

    executor_reference =
      case Keyword.get(options, :executor_reference_builder) do
        nil -> executor
        builder when is_function(builder, 1) -> builder.(executor)
      end

    runtime_options = [
      context_token_budget: 8_192,
      runtime_id: "runtime-#{label}",
      store: store,
      model: %{
        module: model_module,
        model: model_spec(model_module),
        options: Keyword.put_new(model_options, :max_tokens, 256)
      },
      executor: %{
        module: Keyword.get(options, :executor_module, Local),
        reference: executor_reference,
        identity: "executor-local",
        epoch: 11,
        fencing_token: fence,
        workspace_ref: "workspace-#{label}",
        workspace_lease: lease_id
      },
      tool: nil,
      tools: [tool],
      active_tools: ["loopex.demo.write"],
      policy: Loopex.ReferenceClient.Policy.AllowAll,
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

  # Concept: the recovery fault boundary waits for the complete valid tool
  # lifetime rather than an arbitrary fraction of it.
  #
  # Technical depth: the demonstration tool is a controlled process with its
  # own wall bound. A successful answer may then spend the committed cleanup
  # period confirming the process group and the separate receipt-retention
  # reserve before Core can emit the fault hook. The former three-second receive
  # raced that healthy path under suite load. This helper derives its ceiling
  # from the same public cancellation formula, fails early if the run terminates
  # without the hook, and reports the observable runtime and executor state if
  # the complete bound expires.
  def await_executor_receipt_fault(fixture) do
    grace_ms =
      Keyword.get(
        fixture.runtime_options,
        :cleanup_grace_ms,
        Executor.default_cleanup_grace_ms()
      )

    {:ok, bounds} = Executor.cancellation_bounds(grace_ms)

    timeout_ms =
      @demo_tool_wall_time_ms + bounds.executor_observe_ms + bounds.receipt_retention_ms

    await_executor_receipt_fault(
      fixture,
      System.monotonic_time(:millisecond) + timeout_ms,
      timeout_ms
    )
  end

  defp await_executor_receipt_fault(fixture, deadline, timeout_ms) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:loopex_fault, :after_executor_receipt_before_fact, _coordinator, _reference, _receipt} =
          fault ->
        fault
    after
      min(remaining, 100) ->
        status = safely(fn -> ReferenceClient.status(fixture.client) end)

        cond do
          terminal_without_fault?(status) ->
            raise_fault_wait("run terminated without the recovery fault", fixture, status)

          remaining == 0 ->
            raise_fault_wait(
              "recovery fault did not arrive within #{timeout_ms} ms",
              fixture,
              status
            )

          true ->
            await_executor_receipt_fault(fixture, deadline, timeout_ms)
        end
    end
  end

  defp terminal_without_fault?({:ok, %{active_run_id: nil, pending_work_ids: []}}), do: true
  defp terminal_without_fault?(_status), do: false

  defp raise_fault_wait(reason, fixture, status) do
    stats = safely(fn -> Local.stats(fixture.executor) end)

    receipts =
      case stats do
        %{dispatches: dispatches} when is_map(dispatches) ->
          Map.new(dispatches, fn {job_id, _count} ->
            {job_id, safely(fn -> Local.receipt(fixture.executor, job_id) end)}
          end)

        _unavailable ->
          :unavailable
      end

    raise "#{reason}; status=#{inspect(status)} stats=#{inspect(stats)} " <>
            "receipts=#{inspect(receipts)}"
  end

  defp safely(fun) do
    fun.()
  catch
    kind, reason -> {kind, reason}
  end

  def stop_runtime(fixture) do
    if Loopex.Runtime.alive?(fixture.client.runtime), do: ReferenceClient.stop(fixture.client)
    fixture
  end

  def stop(fixture, remove_root \\ true) do
    stop_runtime(fixture)
    stop_if_alive(fixture.executor)
    stop_if_alive(fixture.lease)
    stop_if_alive(fixture.store_pid)
    if remove_root, do: File.rm_rf!(fixture.root)
    :ok
  end

  # Concept: a process already following its parent down is waited for rather
  # than stopped a second time.
  #
  # Technical depth: these processes are linked to the test process that
  # started them, and `on_exit` runs after that process has gone. The store
  # traps exits so that an orderly stop releases its writer marker, which makes
  # its exit an ordered message behind the parent's `:EXIT` rather than an
  # instantaneous link kill; stopping it inside that window exited the caller
  # with the reason the store was already stopping for. The stop is therefore
  # attempted and the exit waited for, and the fixture returns only once the
  # process is really gone, so a restart on the same root never opens against a
  # store that has not yet released it.
  defp stop_if_alive(pid) do
    reference = Process.monitor(pid)

    if Process.alive?(pid) do
      try do
        GenServer.stop(pid)
      catch
        :exit, _already_stopping -> :ok
      end
    end

    receive do
      {:DOWN, ^reference, :process, ^pid, _reason} -> :ok
    after
      5_000 -> raise "#{inspect(pid)} did not stop within five seconds"
    end
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
