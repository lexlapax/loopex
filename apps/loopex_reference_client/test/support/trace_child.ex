defmodule Loopex.ReferenceClientTraceChild do
  alias Loopex.Executor.Local
  alias Loopex.ReferenceClient
  alias Loopex.ReferenceClient.Recovery
  alias Loopex.ReferenceClientRuntimeFixture, as: Fixture

  @marker "LOOPEX_TRACE_V1 "
  @credential_limit 16_384

  def run do
    credential = read_credential!()
    System.put_env("LOOPEX_PROVIDER_API_KEY", credential)

    case System.argv() do
      ["phase1", root] -> phase1(root)
      ["phase2", root, session_id, job_id] -> phase2(root, session_id, job_id)
      _other -> raise "invalid real trace phase"
    end
  end

  defp phase1(root) do
    ensure_started!()

    fixture =
      Fixture.start(
        "real-recovery",
        Loopex.LLM.ReqLLM,
        [
          max_tokens: 128,
          relative_path: "real-recovery.txt",
          content: "loopex-real-recovery"
        ],
        root: root,
        fault_to: self()
      )
      |> Fixture.create("real-recovery")

    {:accepted, "prompt-real-recovery"} =
      ReferenceClient.prompt(
        fixture.client,
        "prompt-real-recovery",
        "Use the registered tool, then confirm completion."
      )

    receive do
      {:loopex_fault, :after_executor_receipt_before_fact, _coordinator, _reference, receipt} ->
        records = Fixture.records(fixture, fixture.client.session_id)
        events = Fixture.events(fixture, fixture.client.session_id)
        first_result = model_results(records) |> List.first()
        identity = first_result.payload["reply"]["identity"]
        tool_calls = first_result.payload["reply"]["tool_calls"]

        true = length(model_results(records)) == 1
        true = length(tool_calls) == 1
        true = List.first(tool_calls)["name"] == "loopex_demo_write"
        true = Local.stats(fixture.executor).dispatches == %{receipt.job_id => 1}
        :completed = receipt.outcome
        true = receipt.child_environment_names == ["PATH"]
        false = receipt.provider_credential_present

        emit(%{
          phase: 1,
          session_id: fixture.client.session_id,
          job_id: receipt.job_id,
          provider_identity: identity,
          acknowledged_event_ids: Enum.map(events, & &1.event_id),
          dispatches: 1,
          child_environment_names: receipt.child_environment_names,
          provider_credential_present: receipt.provider_credential_present
        })

        receive do
        after
          :infinity -> :ok
        end
    after
      120_000 -> raise "real trace did not reach the receipt fault point"
    end
  end

  defp phase2(root, session_id, job_id) do
    ensure_started!()

    fixture =
      Fixture.start(
        "real-recovery",
        Loopex.LLM.ReqLLM,
        [
          max_tokens: 128,
          relative_path: "real-recovery.txt",
          content: "loopex-real-recovery"
        ],
        root: root,
        recover_stale_writer: true
      )
      |> Fixture.resume(session_id)

    before = Fixture.events(fixture, session_id)
    true = Enum.count(before, &(&1.kind == "tool.started")) == 1
    true = Enum.count(before, &(&1.kind == "tool.finished")) == 0
    true = Local.stats(fixture.executor).dispatches == %{}

    {:ok, query} = ReferenceClient.reconciliation_query(fixture.client)
    {:ok, receipt} = Local.receipt(fixture.executor, job_id)
    :ok = ReferenceClient.reconcile(fixture.client, Recovery.receipt(query, receipt))
    Fixture.await_terminal(fixture, 12_000)

    records = Fixture.records(fixture, session_id)
    events = Fixture.events(fixture, session_id)
    results = model_results(records)
    identity = List.last(results).payload["reply"]["identity"]

    true = length(results) == 2
    true = Local.stats(fixture.executor).dispatches == %{}
    true = Enum.count(events, &(&1.kind == "tool.started")) == 1
    true = Enum.count(events, &(&1.kind == "tool.finished")) == 1
    true = List.last(events).kind == "run.finished"
    true = List.last(events)["outcome"] == "completed"
    true = File.read!(Path.join(fixture.workspace, "real-recovery.txt")) == "loopex-real-recovery"
    true = receipt.child_environment_names == ["PATH"]
    false = receipt.provider_credential_present

    evidence = %{
      phase: 2,
      provider_identity: identity,
      event_ids: Enum.map(events, & &1.event_id),
      dispatches_after_restart: 0,
      model_results: length(results),
      tool_started: Enum.count(events, &(&1.kind == "tool.started")),
      tool_finished: Enum.count(events, &(&1.kind == "tool.finished")),
      terminal_outcome: List.last(events)["outcome"],
      child_environment_names: receipt.child_environment_names,
      provider_credential_present: receipt.provider_credential_present
    }

    Fixture.stop(fixture, false)
    emit(evidence)
  end

  defp ensure_started! do
    {:ok, _started} = Application.ensure_all_started(:loopex_reference_client)
  end

  defp model_results(records),
    do: Enum.filter(records, &(&1.payload.kind == "model_result_committed"))

  defp read_credential! do
    <<size::unsigned-big-32>> = read_exact!(4)
    true = size in 1..@credential_limit
    read_exact!(size)
  end

  defp read_exact!(size), do: read_exact!(size, <<>>)
  defp read_exact!(size, bytes) when byte_size(bytes) == size, do: bytes

  defp read_exact!(size, bytes) do
    case IO.binread(:stdio, size - byte_size(bytes)) do
      data when is_binary(data) -> read_exact!(size, bytes <> data)
      _other -> raise "real trace credential frame ended early"
    end
  end

  defp emit(evidence) do
    encoded =
      evidence
      |> :erlang.term_to_binary([:deterministic])
      |> Base.url_encode64(padding: false)

    IO.binwrite(@marker <> encoded <> "\n")
  end
end
