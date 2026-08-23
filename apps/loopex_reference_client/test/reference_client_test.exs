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
