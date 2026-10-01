defmodule LoopexCli.ConfigJsonTest do
  use ExUnit.Case, async: true
  alias LoopexCli.ConfigJson

  test "complete object decoding preserves JSON types and full integer precision" do
    assert ConfigJson.decode(
             ~s( \r\n {"schema_version":1,"bounds":{"deadline_ms":18446744073709551615,"max_turns":18446744073709551616},"roles":[],"enabled":true,"disabled":false,"optional":null,"text":"é"} \t)
           ) ==
             {:ok,
              %{
                "schema_version" => 1,
                "bounds" => %{
                  "deadline_ms" => 18_446_744_073_709_551_615,
                  "max_turns" => 18_446_744_073_709_551_616
                },
                "roles" => [],
                "enabled" => true,
                "disabled" => false,
                "optional" => nil,
                "text" => "é"
              }}

    huge = String.duplicate("9", 100)
    assert {:ok, %{"budget" => value}} = ConfigJson.decode(~s({"budget":#{huge}}))
    assert Integer.to_string(value) == huge
  end

  test "fraction and exponent syntax never masquerade as authored integers" do
    for token <- ["1.0", "1e3", "1E+3", "1e-999", "1e999", "-1.25"] do
      assert ConfigJson.decode(~s({"bounds":{"max_turns":#{token}}})) ==
               {:ok, %{"bounds" => %{"max_turns" => {:non_integer_number}}}}
    end
  end

  test "duplicate members refuse before a map can discard either value" do
    assert ConfigJson.decode(~s({"model":"secret-one","model":"secret-two"})) ==
             {:error, {:duplicate_member, "/model"}}

    assert ConfigJson.decode(~S({"session":{"model":1,"mo\u0064el":2}})) ==
             {:error, {:duplicate_member, "/session/model"}}

    assert ConfigJson.decode(~s({"roles":[{}, {"model":1,"model":2}]})) ==
             {:error, {:duplicate_member, "/roles/1/model"}}

    assert ConfigJson.decode(~s({"a/b":{"~name":1,"~name":2}})) ==
             {:error, {:duplicate_member, "/a~1b/~0name"}}

    assert ConfigJson.decode(~s({"":1,"":2})) == {:error, {:duplicate_member, "/"}}
    assert {:ok, _} = ConfigJson.decode(~s({"a":{"model":1},"b":{"model":2}}))
  end

  test "UTF-8, escape and surrogate vectors retain exact decoded strings" do
    assert ConfigJson.decode(~S({"text":"\"\\\/\b\f\n\r\t\u0001\u001f\u00e9\ud83d\ude80"})) ==
             {:ok, %{"text" => "\"\\/\b\f\n\r\t" <> <<1, 31>> <> "é🚀"}}

    assert ConfigJson.decode(<<"{\"value\":\"", 255, "\"}">>) == {:error, {:invalid_utf8, ""}}
    assert ConfigJson.decode(<<255>>) == {:error, {:invalid_utf8, ""}}
  end

  test "malformed input has one redacted root diagnostic" do
    for bytes <- [
          "",
          "{",
          ~s({"secret":"credential-value}),
          ~s({"secret":credential-value}),
          ~s({"x":01}),
          ~s({"x":+1}),
          ~s({"x":1.}),
          ~s({"x":1e}),
          ~s({"x":NaN}),
          ~s({"x":Infinity}),
          ~s({"x":1,}),
          ~s({"x":[1,]}),
          ~S({"x":"\q"}),
          ~S({"x":"\ud800"}),
          ~S({"x":"\udc00"}),
          ~S({"x":"\ud800\u0061"}),
          "{\"x\":\"line\nfeed\"}",
          "{\"x\":\"" <> <<0>> <> "\"}"
        ] do
      assert ConfigJson.decode(bytes) == {:error, {:malformed_json, ""}}
    end
  end

  test "only an object and JSON whitespace may delimit a document" do
    for bytes <- ["null", "[]", "\"value\"", "1", "true", "false"] do
      assert ConfigJson.decode(bytes) == {:error, {:not_an_object, ""}}
    end

    for suffix <- ["{}", "x", <<0>>, "\u00a0"] do
      assert ConfigJson.decode("{}" <> suffix) == {:error, {:trailing_bytes, ""}}
    end

    assert ConfigJson.decode(" \t\r\n{} \t\r\n") == {:ok, %{}}
    assert ConfigJson.decode(nil) == {:error, {:invalid_configuration, ""}}
  end

  test "the UTF-8 input ceiling counts exact bytes before parsing" do
    empty = ~s({"text":""})
    padding = 262_144 - byte_size(empty)

    assert {:ok, %{"text" => text}} =
             ConfigJson.decode(~s({"text":"#{String.duplicate("x", padding)}"}))

    assert byte_size(text) == padding

    assert ConfigJson.decode(~s({"text":"#{String.duplicate("x", padding + 1)}"})) ==
             {:error, {:configuration_too_large, ""}}

    assert ConfigJson.decode(String.duplicate("x", 262_144) <> <<255>>) ==
             {:error, {:configuration_too_large, ""}}
  end

  test "container nesting is stopped by decoder callbacks before construction" do
    assert {:ok, _} = ConfigJson.decode(nested(16))
    assert ConfigJson.decode(nested(17)) == {:error, {:configuration_nesting_too_deep, ""}}
    assert ConfigJson.decode(nested(100_000)) == {:error, {:configuration_nesting_too_deep, ""}}
  end

  defp nested(depth),
    do:
      ~s({"value":) <>
        String.duplicate("[", depth - 1) <> "0" <> String.duplicate("]", depth - 1) <> "}"
end
