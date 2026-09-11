Code.require_file("support/provider_isolation_fixture.exs", __DIR__)

defmodule Loopex.LLM.ReqLLM.ProviderBackpressureObserverTest do
  use ExUnit.Case, async: false
  alias Loopex.LLM.ReqLLM, as: Adapter
  alias Loopex.LLM.ReqLLM.ProviderIsolationFixture, as: Fixture

  test "barrier-drained real writer calls remain counted on the next observer iteration" do
    variable = Adapter.credential_variable()
    previous = System.get_env(variable)
    System.put_env(variable, "synthetic-observer-regression")

    on_exit(fn ->
      if previous, do: System.put_env(variable, previous), else: System.delete_env(variable)
    end)

    request = Fixture.request()

    fixture =
      Fixture.new(:backpressure,
        stream_prelude: sse(opening() ++ [delta("p")]),
        stream_parts:
          {sse([delta(String.duplicate("a", 32_768))]), sse([delta("b")]), sse(ending())},
        paused: true
      )

    File.write!(Fixture.marker(fixture, "drain-control"), "enabled")
    observer = self()

    call =
      Fixture.managed(fixture, request, self(), fn delta ->
        send(observer, {:progress, delta})
        :ok
      end)

    guardian = call.guardian
    1 = :erlang.trace(guardian, true, [:receive, {:tracer, self()}])
    send(call.caller, :continue)

    assert_receive {:trace, ^guardian, :receive,
                    {:provider_frame, receiver, {:ok, :dispatch_started, _}}},
                   remaining(request)

    assert await_proof(fixture, "backpressure-ready", request)["actual_writer"]
    Fixture.release(fixture)
    assert_receive {:progress, %{text: "p"}}, remaining(request)
    assert await_proof(fixture, "drain-control-ready", request)["actual_send_calls"] == 1
    assert :erlang.suspend_process(receiver)

    try do
      File.write!(Fixture.marker(fixture, "begin-pressure"), "release")
      assert await_proof(fixture, "drain-control-queued", request)["actual_writer_trace_queued"]
      File.write!(Fixture.marker(fixture, "release-drain-control"), "release")
      assert await_proof(fixture, "drain-control-drained", request)["actual_send_calls"] == 2
      assert await_proof(fixture, "drain-control-carried", request)["actual_send_calls"] == 2
      assert :erlang.resume_process(receiver)
      assert_receive {:progress, %{text: text}}, remaining(request)
      assert text == String.duplicate("a", 32_768)
      File.write!(Fixture.marker(fixture, "fill-writer"), "release")
      assert await_proof(fixture, "drain-control-third", request)["actual_send_calls"] == 3
      assert_receive {:progress, %{text: "b"}}, remaining(request)
      File.write!(Fixture.marker(fixture, "continue-stream"), "release")
      caller = call.caller
      assert_receive {:completed, ^caller, {:ok, reply}}, remaining(request)
      assert reply.text == "p" <> String.duplicate("a", 32_768) <> "b"
      assert Fixture.methods(fixture) == ["POST"]
    after
      if Process.info(receiver, :status) == {:status, :suspended},
        do: :erlang.resume_process(receiver)

      File.write!(Fixture.marker(fixture, "release-drain-control"), "release")
      Fixture.stop(call)
      Fixture.assert_gone(fixture)
    end
  end

  defp remaining(request), do: max(request.deadline - System.system_time(:millisecond), 0)

  defp await_proof(fixture, name, request) do
    assert Fixture.eventually(
             fn ->
               Fixture.reached?(fixture, name) or Fixture.reached?(fixture, "backpressure-error")
             end,
             remaining(request)
           )

    refute Fixture.reached?(fixture, "backpressure-error")
    fixture |> Fixture.marker(name) |> File.read!() |> Jason.decode!()
  end

  defp opening do
    [
      %{
        "type" => "message_start",
        "message" => %{
          "id" => "msg_backpressure",
          "type" => "message",
          "role" => "assistant",
          "model" => "claude-haiku-4-5",
          "content" => [],
          "usage" => %{"input_tokens" => 4, "output_tokens" => 0}
        }
      },
      %{
        "type" => "content_block_start",
        "index" => 0,
        "content_block" => %{"type" => "text", "text" => ""}
      }
    ]
  end

  defp ending do
    [
      %{"type" => "content_block_stop", "index" => 0},
      %{
        "type" => "message_delta",
        "delta" => %{"stop_reason" => "end_turn", "stop_sequence" => nil},
        "usage" => %{"output_tokens" => 2}
      },
      %{"type" => "message_stop"}
    ]
  end

  defp delta(text),
    do: %{
      "type" => "content_block_delta",
      "index" => 0,
      "delta" => %{"type" => "text_delta", "text" => text}
    }

  defp sse(events),
    do:
      Enum.map_join(events, fn event ->
        "event: #{event["type"]}\ndata: #{Jason.encode!(event)}\n\n"
      end)
end
