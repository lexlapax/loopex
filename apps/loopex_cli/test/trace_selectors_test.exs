defmodule LoopexCli.TraceSelectorsUntrustedFixture do
  @moduledoc false
end

defmodule LoopexCli.TraceSelectorsTest do
  use ExUnit.Case, async: false
  alias LoopexComposition.TraceSelectors

  test "wildcards resolve as application identities, with exact compiled modules" do
    assert TraceSelectors.resolve([
             "Loopex.*",
             "LoopexProtocol.*",
             "Loopex.Runtime",
             "Elixir.Loopex.Runtime"
           ]) ==
             {:ok, [:loopex, :loopex_protocol, Loopex.Runtime]}
  end

  test "existing atoms and lookalike names do not grant inventory membership" do
    for name <- [
          "ReqLLM.*",
          "Elixir.Loopex.*",
          "Loopex.UnknownModule",
          "LoopexCli.TraceSelectorsUntrustedFixture",
          "String",
          "System",
          "Loopex.Runtim*"
        ] do
      assert TraceSelectors.resolve([name]) == {:error, {:unsupported_trace_selector, 0}}
    end

    assert TraceSelectors.resolve(["Loopex.*", "unknown"]) ==
             {:error, {:unsupported_trace_selector, 1}}
  end

  test "selector list and string bounds refuse without atom creation" do
    for value <- [nil, [], :loopex, ["Loopex.*" | :tail]] do
      assert TraceSelectors.resolve(value) == {:error, {:invalid_trace_selectors, nil}}
    end

    for name <- [nil, :loopex, "", <<255>>, String.duplicate("x", 129)] do
      assert TraceSelectors.resolve([name]) == {:error, {:invalid_trace_selector, 0}}
    end

    assert {:ok, [:loopex]} = TraceSelectors.resolve(List.duplicate("Loopex.*", 64))

    assert TraceSelectors.resolve(List.duplicate("Loopex.*", 65)) ==
             {:error, {:too_many_trace_selectors, nil}}

    for index <- 1..100 do
      name = "UnknownM7Module#{index}"
      assert {:error, _} = TraceSelectors.resolve([name])
      assert_raise ArgumentError, fn -> String.to_existing_atom(name) end
      assert_raise ArgumentError, fn -> String.to_existing_atom("Elixir." <> name) end
    end
  end

  test "metadata inspection starts no applications" do
    before_started = Application.started_applications() |> Enum.map(&elem(&1, 0)) |> Enum.sort()
    assert {:ok, _} = TraceSelectors.resolve(["Loopex.Runtime"])

    assert Application.started_applications() |> Enum.map(&elem(&1, 0)) |> Enum.sort() ==
             before_started
  end
end
