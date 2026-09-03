Code.require_file("support/runtime_fixture.ex", __DIR__)

defmodule Loopex.ReferenceClientTest do
  use ExUnit.Case, async: false

  alias Loopex.ReferenceClient
  alias Loopex.ReferenceClientRuntimeFixture, as: Fixture

  test "the client drives the loop through the embedded API only" do
    fixture =
      Fixture.start(
        "thin-client",
        Loopex.ReferenceClientTestModel,
        relative_path: "thin-client.txt",
        content: "thin-client-effect"
      )
      |> Fixture.create("thin-client")

    on_exit(fn -> Fixture.stop(fixture) end)

    assert {:accepted, "prompt-thin-client"} =
             ReferenceClient.prompt(fixture.client, "prompt-thin-client", "do the work")

    Fixture.await_terminal(fixture)

    events = drain(fixture.client, [])

    assert Enum.map(events, & &1.kind) == [
             "user.message_appended",
             "run.started",
             "assistant.message_appended",
             "tool.started",
             "tool.finished",
             "assistant.message_appended",
             "run.finished"
           ]

    assert File.read!(Path.join(fixture.workspace, "thin-client.txt")) ==
             "thin-client-effect"

    source = File.read!(Path.join(__DIR__, "../lib/reference_client.ex"))

    calls =
      ~r/Loopex\.([a-z_]+)\(/
      |> Regex.scan(source)
      |> Enum.map(fn [_match, function] -> function end)
      |> MapSet.new()

    assert calls ==
             MapSet.new(
               ~w(start_link create_session attach resume_session command next_event reconciliation_query reconcile session_status stop)
             )
  end

  test "the reference prompt commits a five minute duration and derives its instant at staging" do
    fixture =
      Fixture.start(
        "prompt-deadline",
        Loopex.ReferenceClientTestModel,
        observer: self(),
        relative_path: "prompt-deadline.txt",
        content: "prompt-deadline-effect"
      )
      |> Fixture.create("prompt-deadline")

    on_exit(fn -> Fixture.stop(fixture) end)

    staging_floor = System.system_time(:millisecond)

    assert {:accepted, "prompt-deadline"} =
             ReferenceClient.prompt(fixture.client, "prompt-deadline", "do the work")

    assert_receive {:model_request, request}, 2_000
    staging_ceiling = System.system_time(:millisecond)
    Fixture.await_terminal(fixture)

    records = Fixture.records(fixture, fixture.client.session_id)
    # ADR 0013: a prompt admission is `prompt_admitted_v2`, which commits the declared
    # `deadline_ms` duration rather than a `deadline` instant fixed at admission.
    admitted = Enum.find(records, &(&1.payload.kind == "prompt_admitted_v2"))
    staged = Enum.find(records, &(&1.payload.kind == "model_request_committed"))

    assert admitted.payload["deadline_ms"] == 300_000
    refute Map.has_key?(admitted.payload, "deadline")
    assert staged.payload["request"]["deadline"] == request.deadline
    assert request.deadline >= staging_floor + 300_000
    assert request.deadline <= staging_ceiling + 300_000
    assert request.deadline < staging_floor + 600_000
  end

  test "the reference prompt refuses an unknown bound key before admitting a command" do
    fixture =
      Fixture.start("unknown-prompt-bound", Loopex.ReferenceClientTestModel)
      |> Fixture.create("unknown-prompt-bound")

    on_exit(fn -> Fixture.stop(fixture) end)

    assert {:error, :invalid_declared_bounds} =
             ReferenceClient.prompt(fixture.client, "prompt-typo", "do the work",
               bounds: %{
                 max_turns: 8,
                 token_budget: 1_000_000,
                 deadline_ms: 300_000,
                 deadine_ms: 300_000
               }
             )

    # ADR 0013: the refused prompt must leave no `prompt_admitted_v2` record; the
    # pre-rename kind this checked is now written only by non-prompt commands.
    refute Enum.any?(Fixture.records(fixture, fixture.client.session_id), fn record ->
             record.payload.kind == "prompt_admitted_v2"
           end)
  end

  test "the reference client owns no policy durable state or alternate loop" do
    source = File.read!(Path.join(__DIR__, "../lib/reference_client.ex"))
    recovery = File.read!(Path.join(__DIR__, "../lib/recovery.ex"))

    refute String.contains?(source, "use GenServer")
    refute String.contains?(source, "handle_call")
    refute String.contains?(source, "Loopex.Store")
    refute String.contains?(source, "Loopex.Runtime.Session")
    refute String.contains?(source, "Loopex.Executor")
    refute String.contains?(source, "Loopex.Model")

    refute String.contains?(recovery, "use GenServer")
    refute String.contains?(recovery, "execute(")
    refute String.contains?(recovery, "dispatch(")

    assert Map.keys(%ReferenceClient{}) |> Enum.sort() ==
             [:__struct__, :attachment, :runtime, :session_id]
  end

  defp drain(client, accumulated) do
    case ReferenceClient.next_event(client) do
      {:ok, event} -> drain(client, [event | accumulated])
      {:error, :empty} -> Enum.reverse(accumulated)
    end
  end
end
