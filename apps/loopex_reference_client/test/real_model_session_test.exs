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
               "Use the registered tool, then confirm completion."
             )

    Fixture.await_terminal(fixture, 6_000)
    records = Fixture.records(fixture, fixture.client.session_id)

    requests = Enum.filter(records, &(&1.payload.kind == "model_request_committed"))
    results = Enum.filter(records, &(&1.payload.kind == "model_result_committed"))

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

    identity = List.last(results).payload["reply"]["identity"]

    report_real_path(%{
      "provider" => identity["provider"],
      "model" => identity["model"],
      "endpoint" => identity["endpoint"],
      "adapter_build" => "loopex_llm_reqllm@#{Loopex.version()}"
    })
  end

  defp report_real_path(report) do
    if Code.ensure_loaded?(Loopex.M1Gate.RealPathEvidence) do
      assert :ok = apply(Loopex.M1Gate.RealPathEvidence, :report, [report])
    else
      :ok
    end
  end
end
