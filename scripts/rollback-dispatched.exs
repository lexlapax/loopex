# Concept: a dispatched M6-only tool is never silently run again by v0.2.
# Technical depth: the candidate delegates one real grep to its shipped Local
# executor, retains the exact resulting receipt, then holds the reply so the
# caller VM can be killed after effect dispatch but before core settlement.
# A released runtime is started with either shipped Local or an explicit
# test-owned executor port that returns one controlled retained answer.
defmodule LoopexRollbackModel do
  @behaviour Loopex.Model

  @impl Loopex.Model
  def complete(request, _options, _progress) do
    done? =
      Enum.any?(request.messages, fn message ->
        Map.get(message, :role, Map.get(message, "role")) in [:tool, "tool"]
      end)

    {:ok,
     %{
       canonical_request_bytes: request.canonical_request_bytes,
       staged_request_digest: request.staged_request_digest,
       text: if(done?, do: "dispatched rollback complete", else: "searching"),
       identity: %{provider: "fixture", model: request.model, endpoint: "local"},
       usage: %{input_tokens: 1, output_tokens: 1},
       tool_calls:
         if(done?,
           do: [],
           else: [%{id: "rollback-dispatched-grep", name: "grep", arguments: %{"path" => "notes.md", "pattern" => "rollback"}}]
         ),
       delta_count: 0,
       streamed: false
     }}
  end
end

defmodule LoopexRollbackExecutorPort do
  @behaviour Loopex.Executor

  @impl Loopex.Executor
  def execute(%{mode: :writer} = reference, job, grant, options, progress) do
    File.write!(reference.job_path, :erlang.term_to_binary(job))
    {:ok, receipt} = Loopex.Executor.Local.execute(reference.local, job, grant, options, progress)
    {:ok, ^receipt} = Loopex.Executor.Local.retained_receipt(reference.local, job.job_id)
    File.write!(reference.receipt_path, :erlang.term_to_binary(receipt))
    receive do
      :release -> {:ok, receipt}
    end
  end

  def execute(%{mode: :reader}, _job, _grant, _options, _progress),
    do: raise("recovered dispatched work was executed a second time")

  @impl Loopex.Executor
  def cancel(_reference, _job_id), do: {:ok, :cleaned}

  @impl Loopex.Executor
  def retained_receipt(%{mode: :reader, answer: :matching, receipt_path: path}, _job_id),
    do: {:ok, path |> File.read!() |> :erlang.binary_to_term([:safe])}

  def retained_receipt(%{mode: :reader, answer: :absent}, _job_id), do: :absent
  def retained_receipt(%{mode: :reader, answer: answer}, _job_id), do: {:error, answer}
end

defmodule LoopexRollbackDispatched do
  alias Loopex.Executor.Local
  alias Loopex.Executor.Local.{CodingTools, WorkspaceLease}
  alias Loopex.Store
  alias Loopex.Store.Local, as: LocalStore

  def main(["writer", case_root, workspace]) do
    {runtime, _local, _lease, _store} = start(case_root, workspace, :writer)
    {:ok, session_id} = Loopex.create_session(runtime, %{}, command_id: "rollback-dispatched-create")
    File.write!(Path.join(case_root, "session-id"), session_id)
    {:ok, attachment} = Loopex.attach(runtime, session_id)
    {:accepted, "rollback-dispatched-prompt"} =
      Loopex.command(attachment, %{
        type: :prompt, command_id: "rollback-dispatched-prompt",
        content: "run the new grep tool", bounds: %{deadline_ms: 120_000}
      })
    wait_file(Path.join(case_root, "receipt.etf"), 60_000)
    IO.puts("rollback-dispatched: M6 Local retained a real grep receipt before core settlement")
    System.halt(0)
  end

  def main(["reader", case_root, workspace, answer]) do
    selected = String.to_existing_atom(answer)
    {runtime, local, lease, store} = start(case_root, workspace, {:reader, selected})
    session_id = File.read!(Path.join(case_root, "session-id"))
    if selected == :invalid_retained_receipt do
      job = case_root |> Path.join("job.etf") |> File.read!() |> :erlang.binary_to_term([:safe])
      {:error, :invalid_retained_receipt} = Local.retained_receipt(local, job.job_id)
    end
    {:ok, {:prepared, activation}} =
      Loopex.prepare_resume_session(runtime, session_id, "rollback-dispatched-resume")
    {:ok, attachment} = Loopex.attach(runtime, session_id, after_event_sequence: 0)
    {:ok, ^session_id} = Loopex.activate_resume(activation)
    case selected do
      :matching ->
        events = await_finished(attachment, 60_000)
        true = Enum.any?(events, &(&1.kind == "tool.finished" and &1["outcome"] == "completed"))
        true = Enum.any?(events, &(&1.kind == "run.finished" and &1["outcome"] == "completed"))
        IO.puts("rollback-dispatched: test-owned port admitted exact M6 Local receipt without redispatch")

      mode when mode in [:absent, :effect_unresolved, :effect_settling] ->
        events = await_finished(attachment, 60_000)
        true = Enum.any?(events, &(&1.kind == "run.finished" and &1["outcome"] == "outcome_unknown"))
        IO.puts("rollback-dispatched: #{mode} committed outcome_unknown without redispatch")

      mode when mode in [:effect_in_flight, :invalid_retained_receipt] ->
        Process.sleep(300)
        {:ok, status} = Loopex.session_status(runtime, session_id)
        true = is_binary(status.active_run_id)
        events = drain(attachment, [])
        false = Enum.any?(events, &(&1.kind == "run.finished"))
        IO.puts("rollback-dispatched: #{mode} kept the dispatched run pending without redispatch")
    end
    :ok = Loopex.stop(runtime)
    GenServer.stop(local)
    GenServer.stop(lease)
    GenServer.stop(store)
  end

  def main(_), do: raise("invalid rollback-dispatched arguments")

  defp start(case_root, workspace, mode) do
    {:ok, _} = Application.ensure_all_started(:loopex_app_server)
    state_root = Path.join(case_root, "state")
    {:ok, store_pid} =
      LocalStore.start_link(path: Path.join(state_root, "store.log"), recover_stale_writer: true)
    {:ok, store} = Store.new(LocalStore, store_pid)
    {:ok, lease} = WorkspaceLease.start_link(id: "workspace", path: workspace, fencing_token: 1)
    {:ok, local} =
      Local.start_link(
        identity: "rollback-executor", epoch: 1, fencing_token: 1,
        workspace_leases: %{"workspace" => lease},
        ledger_root: Path.join(state_root, "receipts")
      )
    {:ok, workspace_ref} = LoopexComposition.WorkspaceIdentity.reference(workspace)
    reference = %{
      mode: if(mode == :writer, do: :writer, else: :reader),
      answer: if(mode == :writer, do: nil, else: elem(mode, 1)),
      local: local,
      job_path: Path.join(case_root, "job.etf"),
      receipt_path: Path.join(case_root, "receipt.etf")
    }
    module = if(mode == {:reader, :invalid_retained_receipt}, do: Local, else: LoopexRollbackExecutorPort)
    configured_reference = if(module == Local, do: local, else: reference)
    definitions = CodingTools.definitions()
    active = if(mode == :writer, do: ["loopex.grep"], else: Enum.map(definitions, & &1["tool_id"]))
    {:ok, runtime} =
      Loopex.start_link(
        runtime_id: "rollback-dispatched-runtime",
        store: store,
        model: %{module: LoopexRollbackModel, model: "scripted:v1", options: [max_tokens: 256]},
        executor: %{
          module: module, reference: configured_reference,
          identity: "rollback-executor", epoch: 1, fencing_token: 1,
          workspace_ref: workspace_ref, workspace_lease: "workspace"
        },
        tools: definitions, active_tools: active,
        policy: Loopex.AppServer.Policy.AllowAll,
        policy_identity: %{"id" => "rollback-dispatched-policy", "revision" => "0.2.0"},
        bounds: %{max_turns: 3, token_budget: 10_000, deadline_ms: 120_000},
        sampling: %{"max_tokens" => 256}, context_token_budget: 8_192
      )
    {runtime, local, lease, store_pid}
  end

  defp wait_file(path, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    wait_file_until(path, deadline)
  end
  defp wait_file_until(path, deadline) do
    if File.exists?(path) do
      :ok
    else
      if System.monotonic_time(:millisecond) < deadline do
        Process.sleep(20)
        wait_file_until(path, deadline)
      else
        raise("candidate Local did not retain a grep receipt")
      end
    end
  end

  defp await_finished(attachment, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    await_finished_until(attachment, deadline, [])
  end
  defp await_finished_until(attachment, deadline, events) do
    case Loopex.next_event(attachment) do
      {:ok, %{kind: "run.finished"} = event} -> Enum.reverse([event | events])
      {:ok, event} -> await_finished_until(attachment, deadline, [event | events])
      _ ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(20)
          await_finished_until(attachment, deadline, events)
        else
          raise("released runtime did not finish dispatched recovery")
        end
    end
  end
  defp drain(attachment, events) do
    case Loopex.next_event(attachment) do
      {:ok, event} -> drain(attachment, [event | events])
      _ -> Enum.reverse(events)
    end
  end
end

LoopexRollbackDispatched.main(System.argv())
