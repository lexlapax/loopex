defmodule LoopexCli.ChatInputTest do
  use ExUnit.Case, async: true

  alias LoopexCli.ChatInput
  alias LoopexProtocol.Wire

  test "a wait consumes only its own terminated line, leaving the next prompt unread" do
    input("first\r\n/wait\nsecond\n/wait\n/quit\n", fn input ->
      assert ChatInput.read(input) == {:ok, {:prompt, "first"}}
      assert ChatInput.read(input) == {:ok, :wait}
      assert StringIO.contents(input) == {"second\n/wait\n/quit\n", ""}
      assert ChatInput.read(input) == {:ok, {:prompt, "second"}}
      assert ChatInput.read(input) == {:ok, :wait}
      assert ChatInput.read(input) == {:ok, :quit}
      assert ChatInput.read(input) == :eof
    end)
  end

  test "framing preserves split multibyte text, whitespace and literal shell syntax" do
    input("\n 猫 $(echo never); `never` \r\n//status\n", fn input ->
      assert ChatInput.read(input) == :empty
      assert ChatInput.read(input) == {:ok, {:prompt, " 猫 $(echo never); `never` "}}
      assert ChatInput.read(input) == {:ok, {:prompt, "/status"}}
      assert ChatInput.read(input) == :eof
    end)
  end

  test "the cap excludes LF and CRLF but refuses at the first excess content byte" do
    limit = String.duplicate("a", 65_536)

    for terminator <- ["\n", "\r\n"] do
      input(limit <> terminator <> "/wait\n", fn input ->
        assert ChatInput.read(input) == {:ok, {:prompt, limit}}
        assert StringIO.contents(input) == {"/wait\n", ""}
      end)
    end

    input(limit <> "x\n/quit\n", fn input ->
      assert ChatInput.read(input) == {:error, :input_line_too_large}
      assert StringIO.contents(input) == {"\n/quit\n", ""}
    end)
  end

  test "EOF fragments, bare CR, NUL and malformed UTF-8 never become prompts" do
    for {bytes, reason} <- [
          {"fragment", :unterminated_input_line},
          {"fragment\r", :invalid_input_line},
          {"a\rb\n", :invalid_input_line},
          {"a\0b\n", :invalid_input_line},
          {<<0xC3, 10>>, :invalid_input_utf8},
          {<<0xC0, 0xAF, 10>>, :invalid_input_utf8}
        ] do
      input(bytes, fn input -> assert ChatInput.read(input) == {:error, reason} end)
    end
  end

  test "a dead input device reports failure without exposing an IO exception" do
    {:ok, input} = StringIO.open("")
    StringIO.close(input)
    assert ChatInput.read(input) == {:error, :input_failed}
  end

  test "explicit command words preserve payloads and carry no fabricated identities" do
    for action <- [:wait, :status, :abort, :compact, :quit] do
      assert ChatInput.parse("/#{action}") == {:ok, action}
      assert ChatInput.parse("/#{action} extra") == {:error, :invalid_chat_command}
    end

    assert ChatInput.parse("/steer  keep spacing ") == {:ok, {:steer, " keep spacing "}}
    assert ChatInput.parse("/follow-up 猫") == {:ok, {:follow_up, "猫"}}

    for line <- ["/steer", "/steer ", "/follow-up", "/follow-up ", "/unknown", "/"] do
      assert ChatInput.parse(line) == {:error, :invalid_chat_command}
    end
  end

  test "text answers decode once, preserving whitespace and flag-looking text" do
    id = Wire.encode_identity(<<0, 255, 17>>)
    text = "  --choice x \n 猫 \\n  "
    json = :json.encode(text) |> IO.iodata_to_binary()

    assert ChatInput.parse("/answer #{id} --text #{json}") ==
             {:ok, {:answer, <<0, 255, 17>>, %{"text" => text}}}

    for json <- [~s(""), "null", "123", "{}", "[]", ~s("ok" "more"), ~s("\\uD800")] do
      assert ChatInput.parse("/answer #{id} --text #{json}") == {:error, :invalid_chat_answer}
    end

    text = String.duplicate("x", 8193) |> :json.encode() |> IO.iodata_to_binary()
    assert ChatInput.parse("/answer #{id} --text #{text}") == {:error, :invalid_chat_answer}
  end

  test "answers bind explicit opaque IDs and accept no extra options or positional aliases" do
    id = Wire.encode_identity("question")
    choice = Wire.encode_identity(<<1, 2, 255>>)

    assert ChatInput.parse("/answer #{id} --choice #{choice}") ==
             {:ok, {:answer, "question", %{"choice_id" => <<1, 2, 255>>}}}

    assert ChatInput.parse("/decline #{id}") ==
             {:ok, {:answer, "question", %{"disposition" => "declined"}}}

    for line <- [
          "/answer --text \"future\"",
          "/answer #{id}= --choice #{choice}",
          "/answer #{id} --choice #{choice}=",
          "/answer #{id} --choice #{choice} --text \"both\"",
          "/decline #{id} extra"
        ] do
      assert ChatInput.parse(line) == {:error, :invalid_chat_answer}
    end
  end

  test "configure retains exact object values and rejects duplicates and trailing syntax" do
    assert ChatInput.parse(~s(/configure {"max_tokens":8192,"reasoning":"high"})) ==
             {:ok, {:configure, %{"max_tokens" => 8192, "reasoning" => "high"}}}

    for json <- [
          ~s({"max_tokens":1,"max_tokens":2}),
          ~s({"instructions":{"base":"a","base":"b"}}),
          ~s({} {}),
          "[]",
          "null"
        ] do
      assert ChatInput.parse("/configure " <> json) == {:error, :invalid_configure_json}
    end
  end

  defp input(bytes, fun), do: StringIO.open(bytes, [encoding: :latin1], fun)
end
