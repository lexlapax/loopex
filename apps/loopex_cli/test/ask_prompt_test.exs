defmodule LoopexCli.AskPromptTest do
  use ExUnit.Case, async: true
  alias LoopexCli.AskPrompt

  test "positional words join with one ASCII space and do not read stdin" do
    {:ok, input} = StringIO.open("unused stdin")
    assert AskPrompt.admit(["alpha", "", "β"], input) == {:ok, "alpha  β"}
    assert IO.binread(input, 12) == "unused stdin"
  end

  test "zero words read and preserve exact stdin bytes" do
    {:ok, input} = StringIO.open("  α\n")
    assert AskPrompt.admit([], input) == {:ok, "  α\n"}
  end

  test "stdin stops at byte 32,769 and leaves later bytes unread" do
    exact = String.duplicate("a", 32_768)
    {:ok, admitted} = StringIO.open(exact)
    assert AskPrompt.admit([], admitted) == {:ok, exact}

    {:ok, oversized} = StringIO.open(exact <> "XY")
    assert AskPrompt.admit([], oversized) == {:error, :invalid_prompt_too_large}
    assert IO.binread(oversized, 1) == "Y"
  end

  test "empty, oversized and invalid UTF-8 prompts keep the embedded grammar order" do
    {:ok, empty} = StringIO.open("")
    assert AskPrompt.admit([], empty) == {:error, :invalid_prompt_empty}
    assert AskPrompt.admit([""], :ignored) == {:error, :invalid_prompt_empty}

    bad = <<255>>
    {:ok, invalid} = StringIO.open(bad)
    assert AskPrompt.admit([], invalid) == {:error, :invalid_prompt_invalid_utf8}
    assert AskPrompt.admit([bad], :ignored) == {:error, :invalid_prompt_invalid_utf8}

    too_large_and_invalid = bad <> String.duplicate("a", 32_768)
    {:ok, oversized} = StringIO.open(too_large_and_invalid)
    assert AskPrompt.admit([], oversized) == {:error, :invalid_prompt_too_large}

    assert AskPrompt.admit([too_large_and_invalid], :ignored) ==
             {:error, :invalid_prompt_too_large}
  end

  test "a failed input device returns only the fixed command diagnostic" do
    {:ok, closed} = StringIO.open("secret reader term")
    {:ok, _contents} = StringIO.close(closed)
    assert AskPrompt.admit([], closed) == {:error, :command_failed}
    assert AskPrompt.admit(["positional"], closed) == {:ok, "positional"}
  end
end
