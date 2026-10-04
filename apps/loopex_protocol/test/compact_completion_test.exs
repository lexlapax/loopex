defmodule LoopexProtocol.CompactCompletionTest do
  use ExUnit.Case, async: true

  alias LoopexProtocol.Frame
  alias LoopexProtocol.Session.CompactResult

  test "literal completion vectors retain the entire result union and opaque outer identities" do
    fixture = read("vectors/standalone-compact-completion.v1.json")
    assert fixture["contract"] == "standalone_compact_completion"
    assert length(fixture["cases"]) == 160

    for vector <- fixture["cases"] do
      if vector["error"] do
        assert CompactResult.decode_completion(vector["input"]) == :error, vector["name"]
      else
        assert {:ok, native} = CompactResult.decode_completion(vector["input"]), vector["name"]
        assert retained(native) == vector["decoded"], vector["name"]
        assert CompactResult.encode_completion(native) == {:ok, vector["input"]}, vector["name"]
      end
    end
  end

  test "both required outer identities retain the complete Wire boundary" do
    reference = :binary.copy(<<255>>, 65_536)
    native = completion()

    for key <- ~w(episode_id command_id) do
      complete = Map.put(native, key, reference)
      assert {:ok, wire} = CompactResult.encode_completion(complete)
      assert CompactResult.decode_completion(wire) == {:ok, complete}

      assert CompactResult.encode_completion(Map.put(complete, key, reference <> "x")) == :error

      assert CompactResult.decode_completion(
               Map.put(wire, key, Base.url_encode64(reference <> "x", padding: false))
             ) == :error

      for invalid <- [nil, "", self(), %{}, 1] do
        assert CompactResult.encode_completion(Map.put(native, key, invalid)) == :error
      end
    end
  end

  test "private members and a corrupted nested result cannot become a completion" do
    native = completion()
    huge = Integer.pow(10, 100)
    exact = put_in(native, ["result", "usage", "reported_tokens"], huge)
    exact = put_in(exact, ["result", "usage", "total_tokens"], huge)
    assert {:ok, wire} = CompactResult.encode_completion(exact)
    assert wire["result"]["usage"]["total_tokens"] == Integer.to_string(huge)
    assert CompactResult.decode_completion(wire) == {:ok, exact}

    assert CompactResult.encode_completion(%URI{}) == :error

    for poisoned <- [
          Map.put(native, "provider_mapping", %{route: self()}),
          Map.put(native, "run_id", "fictional-run"),
          put_in(native, ["result", "source"], "PRIVATE_COMPLETION_CANARY"),
          put_in(native, ["result", "usage", "total_tokens"], 1)
        ] do
      assert CompactResult.encode_completion(poisoned) == :error
    end
  end

  test "schema is closed and contains the exact result definition, with pinned bytes" do
    schema = read("schema/standalone-compact-completion.v1.json")
    assert schema["required"] == ~w(episode_id command_id result)
    assert schema["additional_members"] == "refuse"
    assert schema["result"] == read("schema/standalone-compact-result.v1.json")

    for key <- ~w(episode_id command_id) do
      assert schema[key]["decoded_bytes_max"] == 65_536
      assert schema[key]["nullable"] == false
    end

    for {relative, digest} <- [
          {"schema/standalone-compact-completion.v1.json",
           "f5a20d1876c5a5c2c4731aadb182d68299a7aea7e0636efdf72b65b9bb941e1c"},
          {"vectors/standalone-compact-completion.v1.json",
           "19e32520e725a833bb65bee34418a35bed0af2516c39194b8962004360218cca"}
        ] do
      assert :crypto.hash(:sha256, File.read!(path(relative))) |> Base.encode16(case: :lower) ==
               digest
    end
  end

  @tag :node_client
  test "the independent Node consumer checks completion literals and both identity ceilings" do
    node = System.find_executable("node") || flunk("Node is required for completion conformance")
    root = Path.expand("../../..", __DIR__)
    runner = Path.join(root, "clients/node/compact-result-vectors.mjs")

    {output, status} =
      System.cmd(
        node,
        [
          runner,
          path("vectors/standalone-compact-result.v1.json"),
          path("vectors/standalone-compact-completion.v1.json")
        ],
        stderr_to_stdout: true
      )

    assert status == 0, output
    [_, complete] = String.split(String.trim_trailing(output, "\n"), "\n")

    assert {:ok,
            %{
              "contract" => "standalone_compact_completion",
              "checked" => 160,
              "boundary_checks" => 6
            }} = Frame.decode(complete, 65_536)
  end

  defp completion do
    %{
      "episode_id" => <<0, 255, 10>>,
      "command_id" => <<255>>,
      "result" => %{
        "disposition" => "unchanged",
        "checkpoint_id" => nil,
        "failure" => nil,
        "cleanup" => "confirmed",
        "usage" => %{
          "attempts" => 0,
          "reported_tokens" => 0,
          "estimated_tokens" => 0,
          "total_tokens" => 0
        }
      }
    }
  end

  defp retained(value) when is_map(value) do
    Map.new(value, fn
      {key, bytes} when key in ~w(episode_id command_id checkpoint_id) and not is_nil(bytes) ->
        {key, %{"opaque_hex" => Base.encode16(bytes, case: :lower)}}

      {"version", version} ->
        {"version", version}

      {key, member} ->
        {key, retained(member)}
    end)
  end

  defp retained(value) when is_integer(value), do: Integer.to_string(value)
  defp retained(value), do: value
  defp read(relative), do: JSON.decode!(File.read!(path(relative)))
  defp path(relative), do: Path.join(:code.priv_dir(:loopex_protocol), relative)
end
