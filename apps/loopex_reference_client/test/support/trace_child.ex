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
          # M1's two-turn loop never needed more. M2's loop sends the whole
          # conversation and lets the model answer until the task is done, and a
          # reply truncated by a tight ceiling reads to the next turn as work
          # still to do -- which is a repeated tool call, not a bound.
          max_tokens: 512,
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
        # Concept: the prompt names the effect it wants.
        #
        # Technical depth: M1 ran a fixed two-turn loop with forced tool
        # selection, so a vague instruction still produced one determinate call.
        # M2 replaced that with a real loop in which the model chooses its own
        # arguments, and a case that asserts an exact external effect must
        # therefore ask for that exact effect. Nothing about the recovery claim
        # changes: what is under test is the kill, the reconciliation, and the
        # credential-free child, never whether a model can guess a filename.
        "Use the registered tool once to write the file real-recovery.txt " <>
          "with the exact content loopex-real-recovery. When the tool reports it " <>
          "wrote the file, confirm completion in one sentence and make no further " <>
          "tool calls."
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
          # M1's two-turn loop never needed more. M2's loop sends the whole
          # conversation and lets the model answer until the task is done, and a
          # reply truncated by a tight ceiling reads to the next turn as work
          # still to do -- which is a repeated tool call, not a bound.
          max_tokens: 512,
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

    projected =
      records
      |> Enum.filter(&(&1.payload.kind == "model_request_committed"))
      |> List.last()
      |> then(& &1.payload["request"]["messages"])
      |> Enum.map(fn message ->
        {message["role"], String.slice(to_string(message["content"] || ""), 0, 80),
         length(message["tool_calls"] || [])}
      end)

    dispatches = Local.stats(fixture.executor).dispatches

    # M2's loop runs as many turns as the task needs, so the floor is what the
    # claim states -- a second real call after reconciliation -- rather than
    # M1's fixed count.
    true = length(results) >= 2

    # Concept: the reconciled effect is never dispatched again.
    #
    # Technical depth: M1's fixed two-turn loop meant no later call could exist,
    # so "no dispatch at all after the restart" and "this effect was not
    # redispatched" were the same statement. Under M2's real loop they are not:
    # a model that decides to run another tool creates a different effect with
    # its own operation identity, which is ordinary progress rather than a
    # redispatch. The protection is stated as what it always was -- this job_id
    # is never dispatched by the recovered runtime -- so a genuine redispatch
    # still fails here.
    true = Map.get(dispatches, job_id, 0) == 0
    true = Enum.count(events, &(&1.kind == "tool.started")) >= 1
    true = Enum.count(events, &(&1.kind == "tool.finished")) >= 1
    true = List.last(events).kind == "run.finished"

    check!(
      List.last(events)["outcome"] == "completed",
      "the recovered run finished #{inspect(List.last(events))} after #{length(results)} " <>
        "results; the last request projected #{inspect(projected, limit: :infinity)}"
    )

    true = File.read!(Path.join(fixture.workspace, "real-recovery.txt")) == "loopex-real-recovery"
    true = receipt.child_environment_names == ["PATH"]
    false = receipt.provider_credential_present

    evidence = %{
      phase: 2,
      projected_messages: projected,
      provider_identity: identity,
      event_ids: Enum.map(events, & &1.event_id),
      dispatches_after_restart: Map.get(dispatches, job_id, 0),
      dispatch_map: dispatches,
      model_results: length(results),
      provider_response_ids: Enum.map(results, & &1.payload["reply"]["provider_response_id"]),
      usage: Enum.map(results, & &1.payload["reply"]["usage"]),
      tool_started: Enum.count(events, &(&1.kind == "tool.started")),
      tool_finished: Enum.count(events, &(&1.kind == "tool.finished")),
      terminal_outcome: List.last(events)["outcome"],
      child_environment_names: receipt.child_environment_names,
      provider_credential_present: receipt.provider_credential_present
    }

    Fixture.stop(fixture, false)
    emit(evidence)
  end

  # Concept: a failed expectation says what it saw.
  #
  # Technical depth: this child reports through a marker on standard output, so a
  # bare match failure reaches the parent as `false` and nothing else. The parent
  # then reports that its child exited, which is the one fact already known.
  defp check!(true, _message), do: :ok
  defp check!(_false, message), do: raise("real trace expectation failed: " <> message)

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
