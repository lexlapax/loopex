Code.require_file("support/runtime_fixture.ex", __DIR__)

defmodule Loopex.ReferenceClient.ModelSessionTest do
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
        record.payload.kind == "model_request_committed_v2" and
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
end
