# Concept: run one source binary at a time against a disposable, physically
# durable session. An old reader must reject version 2 before readiness or
# semantic work; a version-1 control proves the same binary can recover valid
# state. This is a compatibility probe, not a journal migration.
#
# Technical depth: invoke with `mix run --no-start <this-script> <mode> <root>`.
# Modes write-v1/write-v2 assert what the production writer actually emits;
# read-v1/read-v2-refused use the real facade, Store and session coordinator.
# Stop every owner between modes. The read copies the complete log before
# acquiring its own writer. All roots must be dedicated temporary directories.

defmodule Loopex.AccountingRollbackProbe.Model do
  @moduledoc false
  @behaviour Loopex.Model

  @impl Loopex.Model
  def complete(request, options, _progress) do
    Agent.update(Keyword.fetch!(options, :counter), &Map.update!(&1, :model, fn n -> n + 1 end))

    {:ok,
     %{
       text: "durable rollback control",
       identity: %{provider: "scripted", model: request.model, endpoint: "in-process"},
       usage: %{input_tokens: 7, output_tokens: 3},
       tool_calls: [],
       delta_count: 0,
       streamed: false,
       provider_response_id: nil,
       canonical_request_bytes: request.canonical_request_bytes,
       staged_request_digest: request.staged_request_digest
     }}
  end
end

defmodule Loopex.AccountingRollbackProbe.Executor do
  @moduledoc false
  @behaviour Loopex.Executor

  @impl Loopex.Executor
  def execute(counter, _job, _grant, _lease, _progress) do
    Agent.update(counter, &Map.update!(&1, :executor, fn n -> n + 1 end))
    raise "a rollback control with no tools must never execute an effect"
  end

  @impl Loopex.Executor
  def cancel(_counter, _job_id), do: {:ok, :cleaned}
end

defmodule Loopex.AccountingRollbackProbe do
  @moduledoc false
  import ExUnit.Assertions
  alias Loopex.Store
  alias Loopex.AccountingRollbackProbe.Model

  @marker "LOOPEX_ACCOUNTING_ROLLBACK_PROBE_V1\n"

  def run(mode, root) do
    root = Path.expand(root)
    temporary_roots = Enum.map([System.tmp_dir!(), "/tmp", "/private/tmp"], &Path.expand/1)

    assert Enum.any?(temporary_roots, &String.starts_with?(root, &1 <> "/")),
           "probe requires its own temporary root"

    refute root in temporary_roots
    assert File.dir?(root)
    {:ok, _applications} = Application.ensure_all_started(:loopex_store_local)

    if mode in ["write-v1", "write-v2"] do
      assert File.ls!(root) == [], "writer refuses a used probe root"
      File.write!(Path.join(root, "probe-owned"), @marker, [:exclusive])
    else
      assert File.read!(Path.join(root, "probe-owned")) == @marker
      backup = Path.join(root, "before-reader.log")
      refute File.exists?(backup), "reader requires a fresh backup destination"
      :ok = File.cp(Path.join(root, "store.log"), backup)
    end

    {:ok, store_pid} = Store.Local.start_link(path: Path.join(root, "store.log"))
    {:ok, store} = Store.new(Store.Local, store_pid)
    {:ok, counter} = Agent.start_link(fn -> %{model: 0, executor: 0} end)

    {:ok, runtime} =
      Loopex.start_link(
        runtime_id: "rollback-#{mode}",
        store: store,
        context_token_budget: 8_192,
        cleanup_grace_ms: 250,
        model: %{
          module: Model,
          model: "scripted:rollback",
          options: [counter: counter, max_tokens: 256]
        },
        executor: %{
          module: Loopex.AccountingRollbackProbe.Executor,
          reference: counter,
          identity: "rollback-no-effects",
          epoch: 1,
          fencing_token: 1,
          workspace_ref: "rollback-no-tools",
          workspace_lease: "rollback-no-tools"
        },
        policy: Loopex.AccountingRollbackProbe.Policy,
        tools: [],
        active_tools: [],
        bounds: %{max_turns: 2, token_budget: 10_000, deadline_ms: 30_000}
      )

    try do
      case mode do
        "write-v1" -> write(runtime, store, counter, root, "model_attempt_settled_v1")
        "write-v2" -> write(runtime, store, counter, root, "model_attempt_settled_v2")
        "read-v1" -> read(runtime, store, counter, root, :ready)
        "read-v2-refused" -> read(runtime, store, counter, root, :refused)
      end
    after
      :ok = Loopex.stop(runtime)
      :ok = GenServer.stop(store_pid, :normal, 5_000)
      :ok = Agent.stop(counter)
    end
  end

  defp write(runtime, store, counter, root, expected_kind) do
    {:ok, session_id} =
      Loopex.create_session(runtime, %{"purpose" => "rollback-control"}, command_id: "create")

    {:ok, attachment} = Loopex.attach(runtime, session_id, after_event_sequence: 0)

    assert {:accepted, "prompt"} =
             Loopex.command(attachment, %{
               type: :prompt,
               command_id: "prompt",
               content: "finish the rollback control"
             })

    observer = Task.async(fn -> await_terminal(attachment) end)

    terminal =
      case Task.yield(observer, 30_000) do
        {:ok, event} -> event
        nil ->
          Task.shutdown(observer, :brutal_kill)
          flunk("writer terminal observation unavailable after 30 seconds")
      end
    assert terminal["outcome"] == "completed"
    assert Agent.get(counter, & &1) == %{model: 1, executor: 0}
    records = records(store, session_id)
    [settlement] = Enum.filter(records, &String.starts_with?(kind(&1), "model_attempt_settled_"))
    assert kind(settlement) == expected_kind
    File.write!(Path.join(root, "session-id"), session_id <> "\n", [:exclusive])
    IO.puts("ROLLBACK writer=#{expected_kind} ready=true model_calls=1 records=#{length(records)}")
  end

  defp read(runtime, store, counter, root, expected) do
    session_id = root |> Path.join("session-id") |> File.read!() |> String.trim()
    before_records = records(store, session_id)
    before_events = events(store, session_id)
    result = Loopex.resume_session(runtime, session_id, command_id: "reader-resume")

    case expected do
      :ready ->
        assert result == {:ok, session_id}
        assert {:ok, _attachment} = Loopex.attach(runtime, session_id)

      :refused ->
        assert {:error, _reason} = result
        assert {:error, _reason} = Loopex.attach(runtime, session_id)
    end

    after_records = records(store, session_id)
    assert Enum.take(after_records, length(before_records)) == before_records
    added = Enum.drop(after_records, length(before_records))
    assert Enum.all?(added, &(kind(&1) == "owner_advanced"))
    assert events(store, session_id) == before_events
    assert Agent.get(counter, & &1) == %{model: 0, executor: 0}

    IO.puts(
      "ROLLBACK reader=#{expected} model_calls=0 semantic_records=0 public_events=0 " <>
        "ownership_records=#{length(added)} original_records_unchanged=true " <>
        "session_state_beam=#{:code.which(Loopex.Runtime.SessionState)}"
    )
  end

  defp await_terminal(attachment) do
    case Loopex.next_event(attachment) do
      {:ok, %{kind: "run.finished"} = event} -> event
      {:ok, _event} -> await_terminal(attachment)
      other -> flunk("unexpected writer event result: #{inspect(other)}")
    end
  end

  defp records(store, session_id), do: pages(store, session_id, :load_records, :journal_version, 0)
  defp events(store, session_id), do: pages(store, session_id, :load_events, :event_sequence, 0)

  defp pages(store, session_id, operation, position_key, position) do
    assert {:ok, page} = apply(Store, operation, [store, session_id, position, 128])

    case page do
      [] -> []
      _ -> page ++ pages(store, session_id, operation, position_key, Map.fetch!(List.last(page), position_key))
    end
  end

  defp kind(record), do: Map.fetch!(record.payload, :kind)
end

defmodule Loopex.AccountingRollbackProbe.Policy do
  @moduledoc false
  @behaviour Loopex.Policy
  @impl Loopex.Policy
  def decide(_request), do: {:deny, :policy_denied}
end

case System.argv() do
  [mode, root] when mode in ["write-v1", "write-v2", "read-v1", "read-v2-refused"] ->
    Loopex.AccountingRollbackProbe.run(mode, root)

  _ ->
    raise "usage: provider-accounting-rollback.exs write-v1|write-v2|read-v1|read-v2-refused <fresh-temporary-root>"
end
