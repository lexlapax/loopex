defmodule LoopexCli.ChatProgressTest do
  use ExUnit.Case, async: true
  alias LoopexCli.ProgressConsumer

  test "chat candidate needs an exact complete domain and reports answer writes separately" do
    first = delta("answer", 0, "a")
    summary = %{delta("summary", 1, "a") | kind: :reasoning_delta}
    {state, [{:stdout, "answer"}]} = ProgressConsumer.consume(ProgressConsumer.new(:chat), first)
    {state, [{:stderr, "summary"}]} = ProgressConsumer.consume(state, summary)
    {state, []} = ProgressConsumer.consume(state, closed("a", 2, :complete))
    assert {_, {"a", 1}} = ProgressConsumer.chat_assistant(state, 2, "answer")
    assert {_, nil} = ProgressConsumer.chat_assistant(state, 2, "different")
    assert {_, nil} = ProgressConsumer.chat_assistant(state, 3, "answer")
  end

  test "missing, gapped, abandoned and mismatched closure domains require durable fallback" do
    for closure <- [nil, closed("a", 1, :abandoned), closed("a", 2, :complete)] do
      {state, _} = ProgressConsumer.consume(ProgressConsumer.new(:chat), delta("answer", 0, "a"))
      {state, _} = ProgressConsumer.consume(state, closure)
      assert {_, nil} = ProgressConsumer.chat_assistant(state, 2, "answer")
    end

    {state, _} = ProgressConsumer.consume(ProgressConsumer.new(:chat), delta("answer", 1, "a"))
    {state, []} = ProgressConsumer.consume(state, closed("a", 2, :complete))
    assert {_, nil} = ProgressConsumer.chat_assistant(state, 2, "answer")
  end

  test "mid-line fragment framing cannot suppress the complete durable answer" do
    {state, _} = ProgressConsumer.consume(ProgressConsumer.new(:chat), delta("hel", 0, "a"))
    {state, _} = ProgressConsumer.consume(state, delta("lo", 1, "a"))
    {state, _} = ProgressConsumer.consume(state, closed("a", 2, :complete))
    assert {_, nil} = ProgressConsumer.chat_assistant(state, 2, "hello")
  end

  test "empty deltas spend sequence without accumulating retained fragments" do
    state =
      Enum.reduce(0..999, ProgressConsumer.new(:chat), fn sequence, state ->
        {next, _} = ProgressConsumer.consume(state, delta("", sequence, "a"))
        next
      end)

    assert %{fragments: 0, bytes: 0, next_sequence: 1000} = state.domains["a"]
  end

  test "retired cursor domains cannot accumulate or repair themselves with late progress" do
    {state, _} = ProgressConsumer.consume(ProgressConsumer.new(:chat), delta("answer", 0, "a"))
    {state, ["a"]} = ProgressConsumer.advance(state, 2)
    assert state.domains == %{}

    for item <- [delta("late", 0, "b"), closed("b", 0, :complete)] do
      assert {^state, []} = ProgressConsumer.consume(state, item)
    end

    future = %{delta("next", 0, "c") | base_event_sequence: 2}
    {state, [{:stdout, "next"}]} = ProgressConsumer.consume(state, future)
    assert Map.keys(state.domains) == ["c"]
  end

  test "retained chat fragments stay within the existing display ceiling and fall back whole" do
    chunk = String.duplicate("x", 65_536)

    state =
      Enum.reduce(0..3, ProgressConsumer.new(:chat), fn sequence, state ->
        {next, [{:stdout, ^chunk}]} = ProgressConsumer.consume(state, delta(chunk, sequence, "a"))
        next
      end)

    {state, []} = ProgressConsumer.consume(state, delta("overflow", 4, "a"))
    assert ProgressConsumer.status(state, "a") == :invalid
    {state, []} = ProgressConsumer.consume(state, closed("a", 5, :complete))
    assert {_, nil} = ProgressConsumer.chat_assistant(state, 2, chunk)
  end

  defp delta(text, sequence, domain),
    do: %{
      kind: :text_delta,
      turn_id: "turn",
      stream_domain_id: domain,
      model_sequence: sequence,
      base_event_sequence: 1,
      content_index: 0,
      text: text
    }

  defp closed(domain, count, disposition),
    do: %{
      kind: :model_stream_closed,
      turn_id: "turn",
      stream_domain_id: domain,
      base_event_sequence: 1,
      delta_count: count,
      disposition: disposition
    }
end
