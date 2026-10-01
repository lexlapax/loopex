defmodule Loopex.Runtime.InstructionsTest do
  use ExUnit.Case, async: true

  alias Loopex.Runtime.Instructions

  @input %{
    "version" => "host.v1",
    "base" => "base",
    "environment" => "env",
    "appendix" => "appendix"
  }

  test "exact section bytes produce the pinned text and digest" do
    assert {:ok, captured} = Instructions.capture(@input)

    assert captured["digest"] ==
             "a12d04af57f7eadf94367fb7e7004db9171dfd084efc274e4cdef98ec67f1adf"

    assert Instructions.render(captured) == {:ok, "host.v1: base\n\nenv\n\nappendix"}
    assert Instructions.validate(captured) == :ok

    changed = Map.put(@input, "base", "Base")
    assert {:ok, edited} = Instructions.capture(changed)
    refute edited["digest"] == captured["digest"]
  end

  test "empty sections omit separators while whitespace and line endings remain exact" do
    for {environment, appendix, suffix} <- [
          {"", "", ""},
          {"env", "", "\n\nenv"},
          {"", "appendix", "\n\nappendix"},
          {" ", "\r\n", "\n\n \n\n\r\n"}
        ] do
      input = %{
        @input
        | "base" => " base\r\n",
          "environment" => environment,
          "appendix" => appendix
      }

      assert {:ok, captured} = Instructions.capture(input)
      assert Instructions.render(captured) == {:ok, "host.v1:  base\r\n" <> suffix}
    end
  end

  test "section limits count UTF-8 bytes and admit each exact boundary" do
    for {key, limit} <- [{"base", 32_768}, {"environment", 4_096}, {"appendix", 16_384}] do
      for size <- [limit - 1, limit] do
        assert {:ok, captured} =
                 Instructions.capture(Map.put(@input, key, String.duplicate("a", size)))

        assert Instructions.validate(captured) == :ok
      end

      assert Instructions.capture(Map.put(@input, key, String.duplicate("a", limit + 1))) ==
               {:error, :invalid_instructions}

      assert {:ok, _} =
               Instructions.capture(Map.put(@input, key, String.duplicate("é", div(limit, 2))))

      assert Instructions.capture(Map.put(@input, key, String.duplicate("é", div(limit, 2) + 1))) ==
               {:error, :invalid_instructions}
    end
  end

  test "version grammar is ASCII and consumes the complete identifier" do
    for version <- ["a", "Z0._-", String.duplicate("a", 64)] do
      assert {:ok, _} = Instructions.capture(Map.put(@input, "version", version))
    end

    for version <- ["", String.duplicate("a", 65), "a\n", "a b", "é", "-a", <<255>>, nil] do
      assert Instructions.capture(Map.put(@input, "version", version)) ==
               {:error, :invalid_instructions}
    end
  end

  test "malformed input is refused before capture" do
    for input <- [
          nil,
          [],
          Map.put(@input, "extra", true),
          Map.delete(@input, "appendix"),
          Map.put(@input, "base", ""),
          Map.put(@input, "base", self()),
          Map.put(@input, "environment", <<255>>),
          Map.put(@input, "appendix", <<195>>),
          Map.put(@input, "base", :base)
        ] do
      assert Instructions.capture(input) == {:error, :invalid_instructions}
    end
  end

  test "retained instructions reject substituted content, identity and shape" do
    assert {:ok, captured} = Instructions.capture(@input)

    for changed <- [
          Map.put(captured, "base", "Base"),
          Map.put(captured, "version", "host.v2"),
          Map.put(captured, "digest", String.duplicate("0", 64)),
          Map.put(captured, "digest", nil),
          Map.delete(captured, "digest"),
          Map.put(captured, "extra", true),
          @input,
          nil
        ] do
      assert Instructions.validate(changed) == {:error, :invalid_instructions}
      assert Instructions.render(changed) == {:error, :invalid_instructions}
    end
  end

  test "legacy fallback remains the complete historical system text" do
    assert Instructions.render(Instructions.legacy()) ==
             {:ok,
              "loopex.system.v1: You are a coding agent working in a real workspace. " <>
                "Use the tools you are given to inspect and change files, and run commands " <>
                "when you need to. Continue until the task is done, then stop."}
  end
end
