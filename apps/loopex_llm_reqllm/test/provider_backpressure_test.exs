Code.require_file("support/provider_isolation_fixture.exs", __DIR__)

defmodule Loopex.LLM.ReqLLM.ProviderBackpressureTest do
  use ExUnit.Case, async: false

  alias Loopex.LLM.ReqLLM, as: Adapter
  alias Loopex.LLM.ReqLLM.ProviderBridge
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

  test "the committed deadline stops an actually blocked child writer through independent cleanup" do
    # Observe the actual guardian's offset snapshot and state. An unrelated
    # offset read before fixture startup could legitimately differ and is not
    # this invocation's clock anchor.
    assert {:module, ProviderBridge} = Code.ensure_loaded(ProviderBridge)
    assert :erlang.trace_pattern({ProviderBridge, :launch, 1}, true, [:local]) == 1

    assert :erlang.trace_pattern(
             {:erlang, :time_offset, 1},
             [{:_, [], [{:return_trace}]}],
             []
           ) == 1

    on_exit(fn ->
      :erlang.trace_pattern({ProviderBridge, :launch, 1}, false, [:local])
      :erlang.trace_pattern({:erlang, :time_offset, 1}, false, [])
    end)

    {fixture, request, call, receiver, _socket} = start_blocked(Fixture.request(), true)
    guardian = call.guardian
    delivered = :erlang.trace_delivered(guardian)
    assert_receive {:trace_delivered, ^guardian, ^delivered}, remaining(request)

    assert_receive {:trace, ^guardian, :return_from, {:erlang, :time_offset, 1}, offset}, 0

    assert_receive {:trace, ^guardian, :call,
                    {ProviderBridge, :launch, [%{deadline: invocation_deadline}]}},
                   0

    assert invocation_deadline ==
             System.convert_time_unit(request.deadline, :millisecond, :native) - offset

    assert :erlang.trace(guardian, true, [:send, :monotonic_timestamp]) == 1
    receiver_monitor = Process.monitor(receiver)
    cooperative = System.monotonic_time(:millisecond) + remaining(request) + 2_000
    observation = cooperative + 100
    caller = call.caller
    expected_error = {:error, {:dispatched_or_unknown, "model_call_failed"}}

    # The suffix stays unreleased: neither HTTP completion nor private-socket
    # drainage can unblock the real writer before the committed deadline.
    assert_receive {:completed, ^caller, ^expected_error}, until(cooperative)

    # Timestamp publication by the guardian, not the observer's later mailbox
    # read. The delivery barrier makes the zero-time trace match causal.
    result_trace = :erlang.trace_delivered(guardian)
    assert_receive {:trace_delivered, ^guardian, ^result_trace}, until(cooperative)

    assert_receive {:trace_ts, ^guardian, :send,
                    {:provider_result, result_reference, ^guardian, ^expected_error}, ^caller,
                    published_at},
                   0

    assert is_reference(result_reference)
    assert is_integer(published_at)
    assert published_at >= invocation_deadline
    assert_receive {:DOWN, ^receiver_monitor, :process, ^receiver, :killed}, until(cooperative)
    stop_at(call, cooperative, observation)
    assert_one_transport(fixture)

    assert Fixture.eventually(
             fn ->
               Fixture.transport_events(fixture) ==
                 [:connected, :prefix_sent, :writer_fill_sent, :closed]
             end,
             until(observation)
           )

    Fixture.assert_gone(fixture)
  end

  test "channel loss after admitted progress rejects the full terminal queued behind a blocked child writer" do
    request = Fixture.request()

    fixture =
      Fixture.new(:backpressure,
        stream_prelude: sse(opening() ++ [delta("p")]),
        stream_parts:
          {sse([delta(String.duplicate("a", @head_bytes))]), sse([delta("b")]),
           sse(List.duplicate(delta("b"), @tail_count - 2) ++ ending())},
        paused: true
      )

    {call, receiver, socket} = start_observed(fixture, request)
    Fixture.release(fixture)

    assert_receive {:forwarded_delta, %{kind: :text_delta, content_index: 0, text: "p"}},
                   remaining(request)

    assert :erlang.suspend_process(receiver)

    try do
      File.write!(Fixture.marker(fixture, "begin-pressure"), "release")
      block_writer(fixture, request, 2)
      File.write!(Fixture.marker(fixture, "continue-stream"), "release")
      proof = await_proof(fixture, "backpressure-complete", request)
      assert proof["writer_in_send"] and proof["producer_waiting_terminal"]
      assert proof["terminal_messages"] == 1
      assert proof["producer_delta_count"] == @tail_count + 1
      assert proof["terminal_text_bytes"] == @head_bytes + @tail_count

      cooperative = System.monotonic_time(:millisecond) + 2_000
      observation = cooperative + 100
      :ok = :gen_tcp.close(socket)
      assert Port.info(socket) == nil
      assert :erlang.resume_process(receiver)
      caller = call.caller

      assert_receive {:completed, ^caller,
                      {:error, {:dispatched_or_unknown, "model_call_failed"}}},
                     until(cooperative)

      assert forwarded_deltas([]) == []
      stop_at(call, cooperative, observation)
      assert_one_transport(fixture)

      assert Fixture.eventually(
               fn ->
                 Fixture.transport_events(fixture) ==
                   [
                     :connected,
                     :prelude_sent,
                     :prefix_sent,
                     :writer_fill_sent,
                     :suffix_sent,
                     :closed
                   ]
               end,
               until(observation)
             )

      Fixture.assert_gone(fixture)
    after
      resume_if_suspended(receiver)
    end
  end

  defp start_blocked(request \\ Fixture.request(), observe_clock \\ false) do
    fixture = Fixture.new(:backpressure, stream_parts: stream_parts(), paused: true)
    {call, receiver, socket} = start_observed(fixture, request, observe_clock)
    assert :erlang.suspend_process(receiver)
    Fixture.release(fixture)
    block_writer(fixture, request, 1)
    {fixture, request, call, receiver, socket}
  end

  defp start_observed(fixture, request, observe_clock \\ false) do
    observer = self()

    call =
      Fixture.managed(fixture, request, self(), fn delta ->
        send(observer, {:forwarded_delta, delta})
        :ok
      end)

    guardian = call.guardian
    flags = if observe_clock, do: [:call, :receive], else: [:receive]
    :erlang.trace(guardian, true, flags ++ [{:tracer, self()}])
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
    {call, receiver, socket}
  end

  defp block_writer(fixture, request, buffered_calls) do
    buffered = await_proof(fixture, "backpressure-buffered", request)
    assert buffered["pending_bytes"] > 0
    refute buffered["writer_in_send"]
    assert buffered["actual_send_calls"] == buffered_calls
    assert buffered["slot_items"] == 0
    refute Fixture.reached?(fixture, "backpressure-blocked")
    File.write!(Fixture.marker(fixture, "fill-writer"), "release")
    proof = await_proof(fixture, "backpressure-blocked", request)
    assert proof["pending_bytes"] > 0
    assert proof["writer_in_send"]
    assert proof["kind"] == "delta"
    assert proof["actual_send_calls"] == buffered_calls + 1
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

  defp until(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)

  defp stop_at(call, cooperative, observation) do
    stop = make_ref()
    guardian = call.guardian
    monitor = call.monitor

    send(
      guardian,
      {:loopex_provider_resource_stop, call.stop_reference, stop, self(), cooperative,
       observation}
    )

    assert_receive {:loopex_provider_resource_stopped, ^stop, ^guardian}, until(cooperative)
    assert_receive {:DOWN, ^monitor, :process, ^guardian, :normal}, until(observation)
  end

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
    {sse(opening() ++ [delta(String.duplicate("a", @head_bytes))]), sse([delta("b")]),
     sse(List.duplicate(delta("b"), @tail_count - 1) ++ ending())}
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
