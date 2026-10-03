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

  test "compaction groups preceding inputs and every result in call order" do
    prompt = user("go")
    steer = %{user("use both") | command_id: "steer"}
    first = assistant(1, [call("a"), call("b")])
    a = result(1, "a", :failed)
    b = result(1, "b", :cancelled)
    next_input = %{user("continue") | command_id: "continue"}
    last = assistant(2, [], "done")
    elements = [prompt, steer, first, b, next_input, a, last]

    assert {:ok, [group, completion]} =
             Conversation.compaction_units(elements, "r2", ["r1"], [])

    assert group == %{
             kind: :assistant_group,
             run_id: "r1",
             complete?: true,
             protected?: false,
             elements: [prompt, steer, first, a, b]
           }

    assert completion.elements == [next_input, last]
    assert completion.complete?
    refute completion.protected?
  end

  test "terminal input-only runs keep failed and cancelled prompts eligible" do
    first = user("failed before reply")
    second = %{user("cancelled before reply") | run_id: "r2", command_id: "c2"}
    current = %{user("now") | run_id: "r3", command_id: "c3"}

    assert {:ok, [a, b, c]} =
             Conversation.compaction_units([first, second, current], "r3", ["r1", "r2"], [])

    assert a.kind == :inputs
    assert a.elements == [first]
    assert b.elements == [second]
    refute a.protected?
    refute b.protected?
    assert c.protected?
  end

  test "minimum tail releases terminal groups and later inputs oldest-first without regrowth" do
    old = [user("old"), assistant(1, [], "answer"), %{user("later") | command_id: "later"}]
    current = %{user("protected") | run_id: "r2", command_id: "current"}

    assert {:ok, [group, trailing, protected] = units} =
             Conversation.compaction_units(old ++ [current], "r2", ["r1"], [])

    observer = self()

    fit = fn tail ->
      send(observer, {:measured_tail, tail})
      if tail == [protected], do: {:ok, 17}, else: {:refused, :context_record_bytes}
    end

    assert {:ok, selected} = Conversation.compaction_tail(units, :automatic, fit)

    assert selected == %{
             eligible_unit_count: 2,
             retained_tail: [protected],
             released_unit_count: 2,
             tail_tokens: 17
           }

    assert_receive {:measured_tail, [^group, ^trailing, ^protected]}
    assert_receive {:measured_tail, [^trailing, ^protected]}
    assert_receive {:measured_tail, [^protected]}
    refute_received {:measured_tail, _}
  end

  test "explicit selection releases all terminal units even when the current candidate fits" do
    units = tail_units()
    protected = List.last(units)
    observer = self()

    fit = fn tail ->
      send(observer, {:explicit_tail, tail})
      {:ok, 1}
    end

    assert {:ok, selected} = Conversation.compaction_tail(units, :explicit, fit)
    assert selected.eligible_unit_count == 3
    assert selected.retained_tail == [protected]
    assert_receive {:explicit_tail, [^protected]}
    refute_received {:explicit_tail, _}
  end

  test "optional growth keeps complete units up to the exact token preference" do
    units = tail_units()
    fit = fn tail -> {:ok, length(tail) * 512} end
    assert {:ok, selected} = Conversation.compaction_tail(units, :automatic, fit)
    assert selected.eligible_unit_count == 0
    assert selected.retained_tail == units
    assert selected.tail_tokens == 2_048
    assert selected.released_unit_count == 0
    fit = fn tail -> {:ok, length(tail) * 513} end
    assert {:ok, selected} = Conversation.compaction_tail(units, :automatic, fit)
    assert selected.eligible_unit_count == 1
    assert selected.retained_tail == Enum.drop(units, 1)
    assert selected.tail_tokens == 1_539
  end

  test "optional growth stops at a complete-request or rendering refusal" do
    units = tail_units()

    for reason <- [:context_record_bytes, :canonical_history_rendering_unsupported] do
      fit = fn tail -> if length(tail) <= 2, do: {:ok, 7}, else: {:refused, reason} end
      assert {:ok, selected} = Conversation.compaction_tail(units, :automatic, fit)
      assert selected.eligible_unit_count == 2
      assert selected.retained_tail == Enum.drop(units, 2)
    end
  end

  test "protected units never release and terminal units beyond them cannot cross the cut" do
    elements = Enum.flat_map(tail_units(), & &1.elements)

    assert {:ok, units} =
             Conversation.compaction_units(elements, "r2", ["r1"], [
               %{"kind" => "session_assistant", "run_id" => "r1", "turn" => 2}
             ])

    observer = self()

    fit = fn tail ->
      send(observer, {:protected_tail, tail})
      {:refused, :irreducible}
    end

    assert {:refused, :irreducible} = Conversation.compaction_tail(units, :automatic, fit)
    assert_receive {:protected_tail, tail}
    assert tail == Enum.drop(units, 1)
    refute_received {:protected_tail, _}
  end

  test "interruption survives required release and optional growth without selecting a fallback" do
    units = tail_units()

    assert {:error, :cancelled} =
             Conversation.compaction_tail(units, :automatic, fn _ -> {:error, :cancelled} end)

    fit = fn tail ->
      if length(tail) <= 2, do: {:ok, 1}, else: {:error, :compaction_preparation_deadline}
    end

    assert {:error, :compaction_preparation_deadline} =
             Conversation.compaction_tail(units, :automatic, fit)

    assert {:error, :context_projection_invalid} =
             Conversation.compaction_tail(units, :automatic, fn _ -> {:ok, -1} end)
  end

  test "the mandatory newest group may exceed preference while still fitting hard limits" do
    units = tail_units()
    observer = self()

    fit = fn tail ->
      send(observer, {:large_minimum, tail})
      {:ok, 2_049}
    end

    assert {:ok, selected} = Conversation.compaction_tail(units, :automatic, fit)
    assert selected.eligible_unit_count == 2
    assert selected.retained_tail == Enum.drop(units, 2)
    assert selected.tail_tokens == 2_049
    assert_receive {:large_minimum, _tail}
    refute_received {:large_minimum, _}
  end

  test "empty history still measures fixed required inputs and cannot hide an irreducible refusal" do
    assert {:refused, :system_class_tokens} =
             Conversation.compaction_tail([], :automatic, fn [] ->
               {:refused, :system_class_tokens}
             end)

    assert {:ok,
            %{eligible_unit_count: 0, retained_tail: [], released_unit_count: 0, tail_tokens: 0}} =
             Conversation.compaction_tail([], :explicit, fn [] -> {:ok, 0} end)
  end

  defp tail_units do
    elements = [
      user("old"),
      assistant(1, [], "first"),
      assistant(2, [], "middle"),
      assistant(3, [], "newest"),
      %{user("current") | run_id: "r2", command_id: "current"}
    ]

    {:ok, units} = Conversation.compaction_units(elements, "r2", ["r1"], [])
    units
  end

  test "all current-run groups and trailing inputs remain protected" do
    elements = [
      user("go"),
      assistant(1, []),
      %{user("steer") | command_id: "s"},
      assistant(2, []),
      %{user("tail") | command_id: "t"}
    ]

    assert {:ok, units} = Conversation.compaction_units(elements, "r1", ["r1"], [])
    assert length(units) == 3
    assert Enum.all?(units, & &1.protected?)
  end

  test "unfinished groups retain available results and block contiguous coverage" do
    first = [user("old"), assistant(1, [])]
    unfinished = [assistant(2, [call("a"), call("b")]), result(2, "b")]

    later = [
      %{user("later") | run_id: "r2", command_id: "c2"},
      %{assistant(1, []) | run_id: "r2"}
    ]

    assert {:ok, [old, pending, trailing] = units} =
             Conversation.compaction_units(first ++ unfinished ++ later, "r3", ["r1", "r2"], [])

    refute old.protected?
    assert pending.protected?
    refute pending.complete?
    assert pending.elements == unfinished
    refute trailing.protected?
    assert Enum.take_while(units, &(not &1.protected?)) == [old]
  end

  test "any frozen native-prefix source protects its complete unit" do
    elements = [user("go"), assistant(1, [call("a")]), result(1, "a")]
    assert {:ok, entries} = Conversation.lineage_entries(elements)

    for {source, _message} <- entries do
      assert {:ok, [unit]} = Conversation.compaction_units(elements, "r2", ["r1"], [source])
      assert unit.protected?
      assert unit.elements == elements
    end

    assert {:ok, [unit]} =
             Conversation.compaction_units(elements, "r2", ["r1"], [
               %{"kind" => "session_command", "run_id" => "r9", "command_id" => "c1"}
             ])

    refute unit.protected?
  end

  test "nonterminal runs cannot release their input-only units" do
    assert {:ok, [unit]} = Conversation.compaction_units([user("waiting")], "r2", [], [])
    assert unit.protected?
    assert unit.kind == :inputs
  end

  test "compaction refuses orphan, duplicate and noncontiguous lineage" do
    valid = [user("go"), assistant(1, [call("a")]), result(1, "a")]
    other = %{user("other") | run_id: "r2", command_id: "c2"}

    for invalid <- [
          [result(1, "a")],
          valid ++ [result(1, "a")],
          valid ++ [other, assistant(2, [])],
          [:invalid]
        ] do
      assert Conversation.compaction_units(invalid, "r3", ["r1", "r2"], []) ==
               {:error, :context_projection_invalid}
    end

    assert Conversation.compaction_units(nil, "r1", [], []) ==
             {:error, :context_projection_invalid}

    assert Conversation.compaction_units([], "r1", [], []) == {:ok, []}
  end

  test "owner derives protected runs and native-prefix sources from its state" do
    alias Loopex.Runtime.SessionState
    old = [user("old"), assistant(1, [])]
    current = [%{user("new") | run_id: "r2", command_id: "c2"}]
    assert {:ok, entries} = Conversation.lineage_entries(old)

    exchange = %{
      base_request: %{messages: Enum.map(entries, &elem(&1, 1))},
      base_receipt: %{
        "blocks" =>
          Enum.map(entries, fn {source, _} ->
            %{"provenance_class" => "session", "source_reference" => source}
          end)
      }
    }

    state = %SessionState{
      run_order: ["r1", "r2"],
      active_run_id: "r2",
      conversation: %{"r1" => old, "r2" => current},
      pending_work: %{"r2" => %{continuation_exchange: exchange}}
    }

    assert {:ok, units} = SessionState.compaction_units(state, "r2")
    assert Enum.all?(units, & &1.protected?)
    assert SessionState.compaction_units(state, :session) == {:ok, units}
    assert {:ok, [earlier]} = SessionState.compaction_units(state, "r1")
    assert earlier.protected?
    state = %{state | pending_work: %{}}
    assert {:ok, [a, b]} = SessionState.compaction_units(state, "r2")
    refute a.protected?
    assert b.protected?
    idle = %{state | active_run_id: nil}
    assert {:ok, idle_units} = SessionState.compaction_units(idle, "r2")
    refute Enum.any?(idle_units, & &1.protected?)
    state = %{state | open_interaction: "i", interactions: %{"i" => %{run_id: "r1"}}}
    assert {:ok, [a, _]} = SessionState.compaction_units(state, "r2")
    assert a.protected?
    assert {:ok, [session_a, _]} = SessionState.compaction_units(state, :session)
    assert session_a.protected?

    assert SessionState.compaction_units(state, "missing") ==
             {:error, :context_projection_invalid}
  end

  test "terminal tool history requires capability through empty completions and later runs" do
    tool_turn = [user("go"), assistant(1, [call("a")]), result(1, "a")]
    assert Conversation.terminal_tool_history(tool_turn, ["r1"]) == {:ok, true}
    assert Conversation.terminal_tool_history(tool_turn, []) == {:ok, false}

    empty_completion = tool_turn ++ [assistant(2, [], "")]
    assert Conversation.terminal_tool_history(empty_completion, ["r1"]) == {:ok, true}

    later_run =
      empty_completion ++
        [
          %{user("next") | run_id: "r2", command_id: "c2"},
          %{assistant(1, [], "later completion") | run_id: "r2"}
        ]

    assert Conversation.terminal_tool_history(later_run, ["r1", "r2"]) == {:ok, true}
    assert Conversation.terminal_tool_history(later_run, ["r2"]) == {:ok, false}

    completed = tool_turn ++ [assistant(2, [], "done")]
    assert Conversation.terminal_tool_history(completed, ["r1"]) == {:ok, false}
    assert Conversation.terminal_tool_history([user("no model reply")], ["r1"]) == {:ok, false}
  end

  test "terminal history inspects the latest meaningful assistant turn of each run" do
    elements = [
      user("go"),
      assistant(1, [call("a")]),
      result(1, "a"),
      assistant(2, [], "intermediate completion"),
      assistant(3, [call("b")], ""),
      result(3, "b", :cancelled)
    ]

    assert Conversation.terminal_tool_history(elements, ["r1"]) == {:ok, true}

    assert Conversation.terminal_tool_history(elements ++ [assistant(4, [], " ")], ["r1"]) ==
             {:ok, false}
  end

  test "rendering repair pins the last original offender and exposes earlier runs after completion" do
    elements = [
      user("first"),
      assistant(1, [call("a")]),
      result(1, "a"),
      %{user("second") | run_id: "r2", command_id: "c2"},
      %{assistant(1, [call("b")]) | run_id: "r2"},
      %{result(1, "b") | run_id: "r2"},
      %{assistant(2, [], "") | run_id: "r2"},
      %{user("third") | run_id: "r3", command_id: "c3"},
      %{assistant(1, [], "later completion") | run_id: "r3"}
    ]

    first = %{"kind" => "session_assistant", "run_id" => "r1", "turn" => 1}
    last = %{"kind" => "session_assistant", "run_id" => "r2", "turn" => 1}
    assert Conversation.last_terminal_tool_source(elements, ["r1", "r2", "r3"]) == {:ok, last}
    assert Conversation.last_terminal_tool_source(elements, ["r1", "r3"]) == {:ok, first}
    assert Conversation.last_terminal_tool_source(elements, ["r3"]) == {:ok, nil}

    completed = elements ++ [%{assistant(3, [], "second completed") | run_id: "r2"}]
    assert Conversation.last_terminal_tool_source(completed, ["r1", "r2", "r3"]) == {:ok, first}

    assert Conversation.last_terminal_tool_source(
             completed ++ [assistant(2, [], "first completed")],
             ["r1", "r2", "r3"]
           ) == {:ok, nil}

    assert Conversation.last_terminal_tool_source([user("go"), assistant(1, [call("a")])], ["r1"]) ==
             {:error, :context_projection_invalid}
  end

  test "terminal history refuses incomplete or duplicated lineage" do
    unfinished = [user("go"), assistant(1, [call("a")])]

    assert Conversation.terminal_tool_history(unfinished, ["r1"]) ==
             {:error, :context_projection_invalid}

    duplicate = unfinished ++ [result(1, "a"), result(1, "a")]

    assert Conversation.terminal_tool_history(duplicate, ["r1"]) ==
             {:error, :context_projection_invalid}
  end

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

  test "reused turns and call IDs join only results from their own run" do
    first = [user("first"), assistant(1, [call("a")]), result(1, "a", :completed, "FIRST")]

    second =
      [user("second"), assistant(1, [call("a")]), result(1, "a", :completed, "SECOND")]
      |> Enum.map(&Map.put(&1, :run_id, "r2"))

    assert first
           |> Kernel.++(second)
           |> project()
           |> Enum.filter(&(&1["role"] == "tool"))
           |> Enum.map(& &1["content"]) == ["FIRST", "SECOND"]
  end

  test "an earlier run's result cannot settle or skip a later run's call" do
    first = [user("first"), assistant(1, [call("a")]), result(1, "a")]

    second =
      [user("second"), assistant(1, [call("a"), call("b")])]
      |> Enum.map(&Map.put(&1, :run_id, "r2"))

    elements = first ++ second
    refute Conversation.turn_settled?(elements)
    assert Conversation.admits_result?(elements, "r2", "a")
    refute Conversation.admits_result?(elements, "r2", "b")

    second_a = result(1, "a") |> Map.put(:run_id, "r2")
    second_b = result(1, "b") |> Map.put(:run_id, "r2")
    refute Conversation.turn_settled?(elements ++ [second_a])
    assert Conversation.turn_settled?(elements ++ [second_a, second_b])
  end

  test "lineage projection normalizes reused native IDs and retains canonical source identities" do
    first = [user("first"), assistant(1, [call("a")]), result(1, "a", :completed, "FIRST")]

    second =
      [user("second"), assistant(1, [call("a")]), result(1, "a", :completed, "SECOND")]
      |> Enum.map(&Map.put(&1, :run_id, "r2"))

    assert {:ok, entries} = Conversation.lineage_entries(first ++ second)

    [{first_source, first_result}, {second_source, second_result}] =
      Enum.filter(entries, fn {_source, message} -> message["role"] == "tool" end)

    assert first_source == %{
             "kind" => "session_tool_result",
             "run_id" => "r1",
             "turn" => 1,
             "call_id" => "a"
           }

    assert second_source == %{first_source | "run_id" => "r2"}
    assert first_result["content"] == "FIRST"
    assert second_result["content"] == "SECOND"

    assert first_result["tool_call_id"] ==
             "lx_adfbf624bd36e582d5fc4c575141eb5cb0efcb5b04be3b5b"

    assert second_result["tool_call_id"] ==
             "lx_8f8e0a74b2435a40929d61a60348fe748b4c06843285c87f"

    assistant_ids =
      for {_source, %{"role" => "assistant", "tool_calls" => [call]}} <- entries,
          do: call["tool_call_id"]

    assert assistant_ids == [first_result["tool_call_id"], second_result["tool_call_id"]]
    assert {:ok, ^entries} = Conversation.lineage_entries(first ++ second)
    assert Enum.at(project(first), 2)["tool_calls"] |> hd() |> Map.fetch!("tool_call_id") == "a"
  end

  test "lineage projection refuses incomplete, duplicate and orphan canonical facts" do
    base = [user("go"), assistant(1, [call("a")]), result(1, "a")]

    for invalid <- [
          Enum.take(base, 2),
          base ++ [result(1, "a")],
          base ++ [result(1, "orphan")],
          [user("go"), result(1, "a"), assistant(1, [call("a")])],
          [user("go"), assistant(1, [call("a"), call("a")]), result(1, "a")],
          base ++ [assistant(1, [])],
          base ++ [%{kind: :unrecognized}],
          base ++ [Map.put(result(1, "a"), :run_id, "other-run")]
        ] do
      assert {:error, :context_projection_invalid} = Conversation.lineage_entries(invalid)
    end

    assert {:ok, []} = Conversation.lineage_entries([])
    assert {:error, :context_projection_invalid} = Conversation.lineage_entries(:invalid)
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
      assert byte_size(content) > 0
    end

    # An unknown outcome must not read as a failure the model might retry.
    unknown = Conversation.result_content(:outcome_unknown, "recon-1")
    assert unknown =~ "unknown"
    assert unknown =~ "recon-1"
    assert unknown =~ "not"

    denied = Conversation.result_content(:denied, "policy_denied")
    assert denied =~ "refused"
    assert denied =~ "Do not retry"

    # A completed call that produced no output still says it completed. Saying
    # nothing reads as a call that did nothing, and a model's reasonable answer
    # to that is to make the call again.
    silent = Conversation.result_content(:completed, "")
    assert silent =~ "completed"
    assert byte_size(silent) > 0
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
