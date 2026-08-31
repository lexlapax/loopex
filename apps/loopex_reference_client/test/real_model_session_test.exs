Code.require_file("support/runtime_fixture.ex", __DIR__)

defmodule Loopex.ReferenceClient.RealModelSessionTest do
  use ExUnit.Case, async: false

  alias Loopex.ReferenceClient
  alias Loopex.ReferenceClientRuntimeFixture, as: Fixture

  test "model dispatch receives only the committed canonical request bytes and digest" do
    fixture =
      Fixture.start(
        "model-session",
        Loopex.ReferenceClientTestModel,
        observer: self(),
        relative_path: "model-session.txt",
        content: "model-session-effect"
      )
      |> Fixture.create("model-session")

    on_exit(fn -> Fixture.stop(fixture) end)

    assert {:accepted, "prompt-model-session"} =
             ReferenceClient.prompt(fixture.client, "prompt-model-session", "run the tool")

    assert_receive {:model_request, dispatched}, 2_000
    Fixture.await_terminal(fixture)

    records = Fixture.records(fixture, fixture.client.session_id)

    committed =
      Enum.find(records, fn record ->
        record.payload.kind == "model_request_committed" and
          record.payload["request"]["staged_request_digest"] ==
            dispatched.staged_request_digest
      end)

    assert committed

    assert committed.payload["request"]["canonical_request_bytes"] ==
             dispatched.canonical_request_bytes

    assert committed.payload["request"]["staged_request_digest"] ==
             dispatched.staged_request_digest

    assert File.read!(Path.join(fixture.workspace, "model-session.txt")) ==
             "model-session-effect"
  end

  @tag :real_provider
  test "one real non-streaming model call receives the committed canonical request bytes and digest and completes inside a session" do
    fixture =
      Fixture.start(
        "real-model-session",
        Loopex.LLM.ReqLLM,
        max_tokens: 128,
        relative_path: "real-session.txt",
        content: "loopex-real-session"
      )
      |> Fixture.create("real-model-session")

    on_exit(fn -> Fixture.stop(fixture) end)

    assert {:accepted, "prompt-real-model-session"} =
             ReferenceClient.prompt(
               fixture.client,
               "prompt-real-model-session",
               # The prompt names the effect it wants, because M2's loop lets the
               # model choose its own arguments where M1 forced the selection.
               "Use the registered tool once to write the file real-session.txt " <>
                 "with the exact content loopex-real-session. When the tool reports it " <>
                 "wrote the file, confirm completion in one sentence and make no " <>
                 "further tool calls."
             )

    Fixture.await_terminal(fixture, 6_000)
    records = Fixture.records(fixture, fixture.client.session_id)

    requests = Enum.filter(records, &(&1.payload.kind == "model_request_committed"))
    results = Enum.filter(records, &(&1.payload.kind == "model_result_committed"))

    # This is an inherited M1 protection. M2's loop may run for more turns in
    # general, but this task deliberately needs exactly the request that chooses
    # the tool and the request that confirms its durable result. Relaxing that
    # count would let a session stop after the effect without proving the
    # post-tool confirmation call the inherited role closed with.
    assert length(requests) == 2
    assert length(results) == 2

    Enum.zip(requests, results)
    |> Enum.each(fn {request_record, result_record} ->
      assert result_record.payload["reply"]["canonical_request_bytes"] ==
               request_record.payload["request"]["canonical_request_bytes"]

      assert result_record.payload["reply"]["staged_request_digest"] ==
               request_record.payload["request"]["staged_request_digest"]
    end)

    assert File.read!(Path.join(fixture.workspace, "real-session.txt")) ==
             "loopex-real-session"

    events = Fixture.events(fixture, fixture.client.session_id)
    assert List.last(events)["outcome"] == "completed"

    identity = List.last(results).payload["reply"]["identity"]

    announce_attestation(results)

    report_real_path(%{
      "provider" => identity["provider"],
      "model" => identity["model"],
      "endpoint" => identity["endpoint"],
      "adapter_build" => "loopex_llm_reqllm@#{Loopex.version()}"
    })
  end

  # Concept: hand the observed provider identifiers to an attended run.
  #
  # Technical depth: the retained attestation this milestone keeps is written by
  # a person from an attended run, and the identifiers it carries must come from
  # the run rather than a reconstruction. Emitting them on the diagnostic stream
  # is how the run hands them over; nothing here writes a tracked file, because a
  # case that wrote its own evidence would be attesting to itself.
  defp announce_attestation(results) do
    replies = Enum.map(results, & &1.payload["reply"])
    ids = Enum.map(replies, & &1["provider_response_id"])
    input = Enum.reduce(replies, 0, &((&1["usage"]["input_tokens"] || 0) + &2))
    output = Enum.reduce(replies, 0, &((&1["usage"]["output_tokens"] || 0) + &2))

    IO.puts(
      :stderr,
      "loopex attestation inherited_5c: calls=#{length(ids)} ids=#{Enum.join(ids, "+")} " <>
        "input_tokens=#{input} output_tokens=#{output}"
    )
  end

  defp report_real_path(report) do
    if Code.ensure_loaded?(Loopex.M1Gate.RealPathEvidence) do
      assert :ok = apply(Loopex.M1Gate.RealPathEvidence, :report, [report])
    else
      :ok
    end
  end
end
