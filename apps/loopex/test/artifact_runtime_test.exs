Code.require_file("support/m1_runtime_helper.exs", __DIR__)
Code.require_file("support/agent_loop_helper.exs", __DIR__)

defmodule Loopex.ArtifactRuntimeTest do
  use ExUnit.Case, async: false

  alias Loopex.AgentLoopFixture, as: Fixture

  test "the exact artifact reference reaches the durable receipt and public tool event" do
    reference = %{
      digest: String.duplicate("a", 64),
      media_type: "text/plain",
      size: 23,
      role: "tool_output",
      locator: "opaque-artifact-1"
    }

    fixture =
      Fixture.start(
        script: [
          %{
            text: "write it",
            calls: [
              %{id: "artifact-call", name: "write", arguments: %{"path" => "output.txt"}}
            ]
          },
          %{text: "done", calls: []}
        ],
        artifacts: %{"artifact-call" => [reference]}
      )

    on_exit(fn -> Fixture.stop(fixture) end)

    {session_id, attachment, {:accepted, _command_id}} = Fixture.run(fixture, "make output")
    events = await_run_finished(attachment)

    public_reference = %{
      "digest" => reference.digest,
      "media_type" => reference.media_type,
      "size" => reference.size,
      "role" => reference.role,
      "locator" => reference.locator
    }

    assert tool_finished = Enum.find(events, &(&1.kind == "tool.finished")), inspect(events)
    assert tool_finished["artifacts"] == [public_reference]

    receipt =
      fixture
      |> Fixture.records(session_id)
      |> Enum.find(&(&1.payload[:kind] == "executor_receipt_committed"))
      |> get_in([:payload, "receipt"])

    assert receipt["artifacts"] == [public_reference]

    [first_request, second_request] = Loopex.AgentLoopTestModel.dispatched(fixture.model)

    assert Enum.any?(
             first_request.messages,
             &(&1 == %{"role" => "user", "content" => "make output"})
           )

    assert Enum.any?(second_request.messages, fn
             %{"role" => "tool", "tool_call_id" => "artifact-call"} -> true
             _other -> false
           end),
           "the committed tool result did not reach the next model request"
  end

  defp await_run_finished(attachment, deadline_ms \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + deadline_ms
    collect(attachment, deadline, deadline_ms, [])
  end

  defp collect(attachment, deadline, deadline_ms, acc) do
    case Loopex.next_event(attachment) do
      {:ok, event} ->
        acc = [event | acc]

        if event.kind == "run.finished",
          do: Enum.reverse(acc),
          else: collect(attachment, deadline, deadline_ms, acc)

      other ->
        if System.monotonic_time(:millisecond) >= deadline do
          flunk("""
          no run.finished within #{deadline_ms}ms.
          last read: #{inspect(other)}
          events observed: #{inspect(Enum.map(Enum.reverse(acc), & &1.kind))}
          """)
        else
          Process.sleep(10)
          collect(attachment, deadline, deadline_ms, acc)
        end
    end
  end
end
