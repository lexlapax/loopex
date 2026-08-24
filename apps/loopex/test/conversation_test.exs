defmodule Loopex.ConversationTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias Loopex.Conversation

  defp user(content), do: %{kind: :user_message, run_id: "r1", command_id: "c1", content: content}

  defp assistant(turn, calls, content \\ "thinking") do
    %{
      kind: :assistant_message,
      run_id: "r1",
      turn_number: turn,
      content: content,
      tool_calls: calls,
      stop_reason: if(calls == [], do: "end_turn", else: "tool_use"),
      usage: %{}
    }
  end

  defp call(id, name \\ "read"),
    do: %{
      tool_call_id: id,
      name: name,
      generation: {"example.#{name}", "1.0.0", "deadbeef"},
      arguments: %{"path" => id}
    }

  defp result(turn, id, outcome \\ :completed, content \\ "contents") do
    %{
      kind: :tool_result,
      run_id: "r1",
      turn_number: turn,
      tool_call_id: id,
      outcome: outcome,
      content: content,
      artifacts: []
    }
  end

  defp project(elements), do: Conversation.project(elements, system: "SYS")

  test "the projection carries the prompt, the model's own messages, and real tool output" do
    elements = [
      user("fix the bug"),
      assistant(1, [call("a")], "I will read the file"),
      result(1, "a", :completed, "defmodule Foo"),
      assistant(2, [], "Fixed it")
    ]

    assert [
             %{"role" => "system", "content" => "SYS"},
             %{"role" => "user", "content" => "fix the bug"},
             %{"role" => "assistant", "content" => "I will read the file"} = first,
             %{"role" => "tool", "tool_call_id" => "a", "content" => "defmodule Foo"},
             %{"role" => "assistant", "content" => "Fixed it"}
           ] = project(elements)

    # The assistant's call carries the exact generation it resolved through, so
    # the request stays checkable from the journal after the tool changes.
    assert [%{"tool_id" => "example.read", "tool_version" => "1.0.0"}] = first["tool_calls"]
  end

  test "results project in the assistant's call order regardless of completion order" do
    calls = [call("a"), call("b"), call("c")]

    # Committed in the order they finished: c, a, b.
    elements =
      [user("go"), assistant(1, calls)] ++
        [
          result(1, "c", :completed, "C"),
          result(1, "a", :completed, "A"),
          result(1, "b", :completed, "B")
        ]

    ordered =
      elements
      |> project()
      |> Enum.filter(&(&1["role"] == "tool"))
      |> Enum.map(& &1["content"])

    assert ordered == ["A", "B", "C"]
  end

  test "the projection is a pure function of committed elements" do
    elements = [user("go"), assistant(1, [call("a")]), result(1, "a")]

    # Byte-identical across repeated calls: nothing is read from process state
    # and nothing is derived at projection time.
    assert project(elements) == project(elements)
    assert :erlang.term_to_binary(project(elements)) == :erlang.term_to_binary(project(elements))
  end

  test "a turn is unsettled while any call of the latest assistant message is unanswered" do
    calls = [call("a"), call("b")]
    base = [user("go"), assistant(1, calls)]

    refute Conversation.turn_settled?(base)
    refute Conversation.turn_settled?(base ++ [result(1, "a")])
    assert Conversation.turn_settled?(base ++ [result(1, "a"), result(1, "b")])

    # A run with no assistant message yet is trivially settled: there is nothing
    # outstanding to wait for.
    assert Conversation.turn_settled?([user("go")])
  end

  test "results are admitted only for the current turn and only in call order" do
    calls = [call("a"), call("b")]
    elements = [user("go"), assistant(1, calls)]

    assert Conversation.admits_result?(elements, "r1", "a")
    refute Conversation.admits_result?(elements, "r1", "b")
    refute Conversation.admits_result?(elements, "r1", "unknown")
    refute Conversation.admits_result?(elements, "other-run", "a")

    after_a = elements ++ [result(1, "a")]
    refute Conversation.admits_result?(after_a, "r1", "a")
    assert Conversation.admits_result?(after_a, "r1", "b")
  end

  test "every terminal outcome has a bounded model facing form" do
    for outcome <- Conversation.outcomes() do
      content = Conversation.result_content(outcome, "detail")
      assert is_binary(content) and byte_size(content) > 0
    end

    # An unknown outcome must not read as a failure the model might retry.
    unknown = Conversation.result_content(:outcome_unknown, "recon-1")
    assert unknown =~ "unknown"
    assert unknown =~ "recon-1"
    assert unknown =~ "not"

    denied = Conversation.result_content(:denied, "policy_denied")
    assert denied =~ "refused"
    assert denied =~ "Do not retry"
  end

  test "an unknown element is refused rather than silently dropped" do
    assert_raise ArgumentError, fn ->
      project([user("go"), %{kind: :something_else}])
    end
  end

  test "an unanswered call projects no tool message rather than a placeholder" do
    # A partially resolved turn is never staged, but the projection must still
    # be total: it emits what committed and invents nothing for what did not.
    elements = [user("go"), assistant(1, [call("a"), call("b")]), result(1, "a")]

    tools = elements |> project() |> Enum.filter(&(&1["role"] == "tool"))
    assert length(tools) == 1
    assert hd(tools)["tool_call_id"] == "a"
  end
end
