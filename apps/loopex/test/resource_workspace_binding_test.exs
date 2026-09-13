Code.require_file("support/m1_runtime_helper.exs", __DIR__)
Code.require_file("support/agent_loop_helper.exs", __DIR__)

defmodule Loopex.ResourceWorkspaceBindingTest do
  use ExUnit.Case, async: false

  alias Loopex.M1RuntimeTestStore

  test "a resource snapshot must match the executor's opaque workspace before startup" do
    {store_pid, store} = M1RuntimeTestStore.start_store()
    on_exit(fn -> if Process.alive?(store_pid), do: GenServer.stop(store_pid) end)
    options = options(store, "workspace:a", manifest("workspace:b"))
    result = Loopex.start_link(options)
    if match?({:ok, _}, result), do: Loopex.stop(elem(result, 1))
    assert result == {:error, :invalid_runtime_options}
    assert M1RuntimeTestStore.observed(store_pid) == MapSet.new()
  end

  test "matching references and absent manifest or executor retain their existing startup semantics" do
    {store_pid, store} = M1RuntimeTestStore.start_store()
    on_exit(fn -> if Process.alive?(store_pid), do: GenServer.stop(store_pid) end)

    for options <- [
          options(store, "workspace:a", manifest("workspace:a")),
          options(store, "workspace:a", nil),
          options(store, "workspace:a", manifest("workspace:b"))
          |> Keyword.drop([:model, :executor])
        ] do
      assert {:ok, runtime} = Loopex.start_link(options)
      assert :ok = Loopex.stop(runtime)
    end
  end

  test "prepared recovery keeps a retained job's legacy workspace reference and digest" do
    {store_pid, store} = M1RuntimeTestStore.start_store()
    executor = Loopex.AgentLoopTestExecutor.start(%{}, 0, :cleaned, self())

    model =
      Loopex.AgentLoopTestModel.start([
        %{text: "write", calls: [%{id: "c1", name: "write", arguments: %{"path" => "c1"}}]}
      ])

    on_exit(fn ->
      for pid <- [store_pid, executor, model], Process.alive?(pid), do: GenServer.stop(pid)
    end)

    legacy_ref = "workspace:" <> LoopexProtocol.Canonical.digest_bytes("/legacy/workspace")

    physical_ref =
      "workspace:" <>
        LoopexProtocol.Canonical.digest(%{
          "canonical_root" => "/legacy/workspace",
          "major_device" => 1,
          "inode" => 2
        })

    writer_options =
      options(store, legacy_ref, nil)
      |> Keyword.put(:model, %{
        module: Loopex.AgentLoopTestModel,
        model: "scripted:test",
        options: [script: model]
      })
      |> Keyword.update!(:executor, &Map.put(&1, :reference, executor))
      |> Keyword.put(:tools, [Loopex.AgentLoopFixture.tool_definition()])
      |> Keyword.put(:active_tools, ["example.write"])

    {:ok, writer} = Loopex.start_link(writer_options)
    on_exit(fn -> if Process.alive?(writer.supervisor), do: Loopex.stop(writer) end)
    {:ok, session} = Loopex.create_session(writer, %{}, command_id: "create")
    {:ok, attachment} = Loopex.attach(writer, session, after_event_sequence: 0)

    assert {:accepted, _} =
             Loopex.command(attachment, %{type: :prompt, command_id: "prompt", content: "write"})

    assert_receive {:tool_progress_emitted, "c1", worker}, 5000
    worker_monitor = Process.monitor(worker)
    assert [job] = Loopex.AgentLoopTestExecutor.jobs(executor)
    assert job.workspace_ref == legacy_ref
    before = M1RuntimeTestStore.inspect_state(store_pid).sessions[session].records
    assert :ok = Loopex.stop(writer)
    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, _}, 5000

    reader_options =
      writer_options
      |> Keyword.update!(:executor, &Map.put(&1, :workspace_ref, physical_ref))
      |> Keyword.put(:resource_manifest, manifest(physical_ref))

    {:ok, reader} = Loopex.start_link(reader_options)
    on_exit(fn -> if Process.alive?(reader.supervisor), do: Loopex.stop(reader) end)

    assert {:ok, {:prepared, activation}} =
             Loopex.prepare_resume_session(reader, session, "resume")

    assert {:ok, ^session} = Loopex.activate_resume(activation)
    {:ok, resumed} = Loopex.attach(reader, session, after_event_sequence: 0)
    assert {:ok, query} = await_reconciliation(resumed, 100)
    assert query.journaled_canonical_request_digest == job.canonical_request_digest
    assert query.journaled_operation_id == job.operation_id
    assert :ok = Loopex.reconcile(resumed, Map.put(query, :evidence, "outcome_unknown"))
    after_records = M1RuntimeTestStore.inspect_state(store_pid).sessions[session].records
    assert Enum.take(after_records, length(before)) == before
    assert Loopex.AgentLoopTestExecutor.jobs(executor) == [job]
  end

  defp await_reconciliation(attachment, attempts) when attempts > 0 do
    case Loopex.reconciliation_query(attachment) do
      {:error, :effect_in_flight} ->
        Process.sleep(10)
        await_reconciliation(attachment, attempts - 1)

      result ->
        result
    end
  end

  defp await_reconciliation(_attachment, 0), do: {:error, :reconciliation_not_ready}

  defp manifest(ref),
    do: %{version: "loopex.resource_pack/1", workspace_ref: ref, revision: nil, packs: []}

  defp options(store, ref, manifest) do
    [
      runtime_id: "workspace-binding",
      store: store,
      context_token_budget: 8192,
      resource_manifest: manifest,
      policy: Loopex.AgentLoopTestPolicy,
      model: %{module: Loopex.AgentLoopTestModel, model: "scripted:test", options: []},
      executor: %{
        module: Loopex.AgentLoopTestExecutor,
        reference: self(),
        identity: "executor",
        epoch: 1,
        fencing_token: 1,
        workspace_ref: ref,
        workspace_lease: "lease"
      }
    ]
  end
end
