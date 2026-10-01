defmodule LoopexProtocol.Session.AnswerTest do
  use ExUnit.Case, async: true

  alias LoopexProtocol.Frame
  alias LoopexProtocol.Session.Answer

  test "literal language-neutral answer vectors retain bytes and distinct branches" do
    fixture = read_contract("vectors/question-answer.v1.json")
    assert fixture["format"] == "loopex.experimental.payload-vectors/1"

    for vector <- fixture["cases"] do
      expected =
        cond do
          vector["error"] ->
            :error

          vector["decoded_choice_hex"] ->
            {:ok, %{"choice_id" => Base.decode16!(vector["decoded_choice_hex"], case: :lower)}}

          true ->
            {:ok, vector["decoded"]}
        end

      assert Answer.decode_wire(vector["input"]) == expected, vector["name"]
    end
  end

  test "literal contract fixes the complete closed response union" do
    schema = read_contract("schema/question-answer.v1.json")
    assert schema["additional_members"] == "refuse"

    assert schema["one_of"] == [
             %{
               "required" => ["choice_id"],
               "choice_id" => %{
                 "encoding" => "unpadded_base64url_of_original_opaque_bytes",
                 "original_min_bytes" => 1,
                 "original_max_bytes" => 65_536
               }
             },
             %{
               "required" => ["text"],
               "text" => %{"encoding" => "utf8", "min_bytes" => 1, "max_bytes" => 8_192}
             },
             %{"required" => ["disposition"], "disposition" => %{"enum" => ["declined"]}}
           ]
  end

  test "core atom spellings normalize but wire atom keys and mixed spellings refuse" do
    assert Answer.normalize(%{text: "answer"}) == {:ok, %{"text" => "answer"}}
    assert Answer.normalize(%{choice_id: <<0, 255>>}) == {:ok, %{"choice_id" => <<0, 255>>}}
    assert Answer.normalize(%{disposition: "declined"}) == {:ok, %{"disposition" => "declined"}}
    assert Answer.decode_wire(%{text: "answer"}) == :error
    assert Answer.normalize(%{:text => "a", "text" => "a"}) == :error
    assert Answer.normalize(%{"text" => "a", "disposition" => "declined"}) == :error
    assert Answer.normalize(%{"text" => <<255>>}) == :error
  end

  test "limits count UTF-8 bytes and opaque decoded bytes at exact edges" do
    text = String.duplicate("é", 4_096)
    assert Answer.decode_wire(%{"text" => text}) == {:ok, %{"text" => text}}
    assert Answer.decode_wire(%{"text" => text <> "x"}) == :error
    bytes = :binary.copy(<<255>>, 65_536)

    assert Answer.decode_wire(%{"choice_id" => Base.url_encode64(bytes, padding: false)}) ==
             {:ok, %{"choice_id" => bytes}}

    assert Answer.decode_wire(%{"choice_id" => Base.url_encode64(bytes <> "x", padding: false)}) ==
             :error

    assert Answer.normalize(%{choice_id: bytes <> "x"}) == :error
  end

  @tag :node_client
  test "the independent Node decoder passes the same literal payload vectors" do
    node = System.find_executable("node") || flunk("Node is required for payload conformance")
    root = Path.expand("../../..", __DIR__)
    runner = Path.join(root, "clients/node/question-answer-vectors.mjs")
    vectors = Path.join(root, "apps/loopex_protocol/priv/vectors/question-answer.v1.json")
    {output, status} = System.cmd(node, [runner, vectors], stderr_to_stdout: true)
    assert status == 0, output

    assert {:ok, %{"contract" => "interaction_answer", "checked" => 20, "boundary_checks" => 5}} =
             Frame.decode(String.trim_trailing(output, "\n"), 65_536)
  end

  defp read_contract(relative) do
    path = Path.join([:code.priv_dir(:loopex_protocol), relative])
    {:ok, value} = path |> File.read!() |> String.trim_trailing("\n") |> Frame.decode(65_536)
    value
  end
end
