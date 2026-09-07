Code.require_file("support/provider_isolation_fixture.exs", __DIR__)

defmodule Loopex.LLM.ReqLLM.ProviderBackpressureTest do
  use ExUnit.Case, async: false

  alias Loopex.LLM.ReqLLM, as: Adapter
  alias Loopex.LLM.ReqLLM.ProviderIsolationFixture, as: Fixture

  @head_bytes 32_768
  @tail_count 512

  setup do
    variable = Adapter.credential_variable()
    previous = System.get_env(variable)
    System.put_env(variable, "synthetic-backpressure-credential")

    on_exit(fn ->
      if previous, do: System.put_env(variable, previous), else: System.delete_env(variable)
    end)

    :ok
  end

  test "a blocked actual child writer retains a bounded backlog and the producer's complete reply count" do
    {fixture, request, call, receiver, _socket} = start_blocked()

    try do
      File.write!(Fixture.marker(fixture, "continue-stream"), "release")
      proof = await_proof(fixture, "backpressure-complete", request)
      assert proof["pending_bytes"] > 0
      assert proof["writer_in_send"]
      assert proof["producer_waiting_terminal"]
      assert proof["slot_items"] == 1
      assert proof["delta_items"] == 1
      assert proof["progress_notifications"] == 1
      assert proof["terminal_messages"] == 1
      assert proof["other_messages"] == 0
      assert proof["producer_delta_count"] == @tail_count + 1
      assert proof["terminal_text_bytes"] == @head_bytes + @tail_count

      assert :erlang.resume_process(receiver)
      caller = call.caller
      assert_receive {:completed, ^caller, {:ok, reply}}, remaining(request)

      assert reply.text ==
               String.duplicate("a", @head_bytes) <> String.duplicate("b", @tail_count)

      assert reply.delta_count == @tail_count + 1
      assert reply.streamed
      assert reply.usage == %{input_tokens: 4, output_tokens: 2}
      assert reply.canonical_request_bytes == request.canonical_request_bytes
      assert reply.staged_request_digest == request.staged_request_digest
      # The callback sends every forwarded item from this same caller before
      # its completed message, so that receipt is the delivery barrier here.
      forwarded = forwarded_deltas([])
      assert length(forwarded) in 1..2
      assert length(forwarded) < reply.delta_count
      assert Enum.all?(forwarded, &Loopex.Model.valid_delta?/1)
      Fixture.stop(call)
      assert_one_transport(fixture)

      assert Fixture.eventually(fn ->
               Fixture.transport_events(fixture) == [
                 :connected,
                 :prefix_sent,
                 :writer_fill_sent,
                 :suffix_sent,
                 :closed
               ]
             end)

      Fixture.assert_gone(fixture)
    after
      resume_if_suspended(receiver)
    end
  end

  defp start_blocked(request \\ Fixture.request()) do
    fixture = Fixture.new(:backpressure, stream_parts: stream_parts(), paused: true)
    observer = self()

    call =
      Fixture.managed(fixture, request, self(), fn delta ->
        send(observer, {:forwarded_delta, delta})
        :ok
      end)

    guardian = call.guardian
    :erlang.trace(guardian, true, [:receive, {:tracer, self()}])
    send(call.caller, :continue)

    assert_receive {:trace, ^guardian, :receive,
                    {:provider_frame, receiver, {:ok, :dispatch_started, _}}},
                   remaining(request)

    assert await_proof(fixture, "backpressure-ready", request) ==
             %{"actual_writer" => true, "private_socket" => true}

    [socket] =
      Enum.filter(Port.list(), fn port ->
        Port.info(port, :connected) == {:connected, guardian} and local_socket?(port)
      end)

    :ok = :inet.setopts(socket, recbuf: 1_024, buffer: 1_024)
    assert :erlang.suspend_process(receiver)
    Fixture.release(fixture)
    buffered = await_proof(fixture, "backpressure-buffered", request)
    assert buffered["pending_bytes"] > 0
    refute buffered["writer_in_send"]
    assert buffered["actual_send_calls"] == 1
    assert buffered["slot_items"] == 0
    File.write!(Fixture.marker(fixture, "fill-writer"), "release")
    proof = await_proof(fixture, "backpressure-blocked", request)
    assert proof["pending_bytes"] > 0
    assert proof["writer_in_send"]
    assert proof["kind"] == "delta"
    assert proof["actual_send_calls"] == 2
    {fixture, request, call, receiver, socket}
  end

  defp local_socket?(port) do
    match?({:ok, {:local, _}}, :inet.peername(port))
  catch
    _, _ -> false
  end

  defp await_proof(fixture, name, request) do
    assert Fixture.eventually(
             fn ->
               Fixture.reached?(fixture, name) or Fixture.reached?(fixture, "backpressure-error")
             end,
             remaining(request)
           ),
           "missing actual process witness: #{name}; last observation: " <>
             inspect(File.read(Fixture.marker(fixture, "backpressure-observation")))

    refute Fixture.reached?(fixture, "backpressure-error"), "backpressure observation failed"
    fixture |> Fixture.marker(name) |> File.read!() |> Jason.decode!()
  end

  defp remaining(request), do: max(request.deadline - System.system_time(:millisecond), 0)

  defp resume_if_suspended(pid) do
    if Process.info(pid, :status) == {:status, :suspended}, do: :erlang.resume_process(pid)
  end

  defp forwarded_deltas(acc) do
    receive do
      {:forwarded_delta, delta} -> forwarded_deltas([delta | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp assert_one_transport(fixture) do
    assert Fixture.methods(fixture) == ["POST"]
    assert Fixture.canaries(fixture) == 1
    assert [{_body, true}] = Fixture.events(fixture)
  end

  defp stream_parts do
    opening = [
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
      },
      delta(String.duplicate("a", @head_bytes))
    ]

    ending = [
      %{"type" => "content_block_stop", "index" => 0},
      %{
        "type" => "message_delta",
        "delta" => %{"stop_reason" => "end_turn", "stop_sequence" => nil},
        "usage" => %{"output_tokens" => 2}
      },
      %{"type" => "message_stop"}
    ]

    {sse(opening), sse([delta("b")]), sse(List.duplicate(delta("b"), @tail_count - 1) ++ ending)}
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
