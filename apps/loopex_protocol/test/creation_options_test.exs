defmodule LoopexProtocol.CreationOptionsTest do
  use ExUnit.Case, async: true

  alias LoopexProtocol.{Frame, Session.CreationOptions}

  test "literal creation vectors preserve omissions order aliases raw sections and every subset" do
    fixture = read("vectors/creation-options.v1.json")
    assert fixture["contract"] == "creation_options"
    assert length(fixture["cases"]) == 398

    for vector <- fixture["cases"] do
      if vector["error"] do
        assert CreationOptions.decode_wire(vector["input"]) == :error, vector["name"]
      else
        assert {:ok, decoded} = CreationOptions.decode_wire(vector["input"]), vector["name"]
        assert retained(decoded) == vector["decoded"], vector["name"]
      end
    end

    for mode <- ~w(omitted empty ordered) do
      subsets =
        Enum.filter(fixture["cases"], fn vector ->
          String.starts_with?(vector["name"], "configuration-subset-") and
            String.ends_with?(vector["name"], "-tools-" <> mode)
        end)

      assert length(subsets) == 63

      assert subsets
             |> Enum.map(&Enum.sort(Map.keys(&1["input"]["configuration"])))
             |> Enum.uniq()
             |> length() == 63
    end
  end

  test "authored presence stays explicit without adding host defaults or captures" do
    assert CreationOptions.decode_wire(%{"version" => 1}) == {:ok, %{"version" => 1}}

    assert CreationOptions.decode_wire(%{"version" => 1, "tools" => []}) ==
             {:ok, %{"version" => 1, "tools" => []}}

    sections = %{"version" => "v", "base" => "a\n", "environment" => "α", "appendix" => ""}

    options = %{
      "version" => 1,
      "tools" => ["write", "read"],
      "configuration" => %{
        "model" => " authored-alias ",
        "instructions" => sections,
        "max_tokens" => "9007199254740993"
      }
    }

    assert {:ok, decoded} = CreationOptions.decode_wire(options)
    assert decoded["tools"] == ["write", "read"]
    assert decoded["configuration"]["model"] == " authored-alias "
    assert decoded["configuration"]["instructions"] === sections
    assert decoded["configuration"]["max_tokens"] === 9_007_199_254_740_993
    refute Map.has_key?(decoded["configuration"]["instructions"], "digest")
    refute Map.has_key?(decoded["configuration"], "configuration_version")
  end

  test "exact JSON integer revision and duplicate-aware framing precede options decoding" do
    for version <- [nil, "1", 0, 2, -1, true, 1.0, 1.5] do
      assert CreationOptions.decode_wire(%{"version" => version}) == :error
    end

    for vector <- read("vectors/creation-options.v1.json")["frame_cases"] do
      assert Frame.decode(vector["json"], 2_097_152) == {:error, :duplicate_member},
             vector["name"]
    end

    assert {:ok, %{"version" => 1.0} = fractional} = Frame.decode(~s({"version":1.0}), 128)
    assert CreationOptions.decode_wire(fractional) == :error
    bytes = ~s({"version":1,"tools":[]})
    assert {:ok, options} = Frame.decode(bytes, byte_size(bytes))
    assert {:ok, _} = CreationOptions.decode_wire(options)
    assert Frame.decode(bytes, byte_size(bytes) - 1) == {:error, :frame_too_large}
    assert Frame.decode(<<255>>, 128) == {:error, :invalid_utf8}

    oversized = %{"version" => 1, "configuration" => %{"model" => String.duplicate("a", 131_073)}}
    assert Frame.decode(JSON.encode!(oversized), 2_097_152) == {:error, :string_too_large}
  end

  test "native malformed UTF8 structs private keys and improper tool lists refuse" do
    for input <- [nil, [], %URI{}, %{version: 1}, Map.put(%{"version" => 1}, :authority, true)] do
      assert CreationOptions.decode_wire(input) == :error
    end

    for tools <- [["read" | :private], [self()], [fn -> :private end], [<<255>>]] do
      assert CreationOptions.decode_wire(%{"version" => 1, "tools" => tools}) == :error
    end

    assert CreationOptions.decode_wire(%{"version" => 1, "configuration" => %URI{}}) == :error

    assert CreationOptions.decode_wire(%{
             "version" => 1,
             "configuration" => %{"model" => <<255>>}
           }) == :error

    for section <- ~w(base environment appendix) do
      raw = %{"version" => "v", "base" => "a", "environment" => "", "appendix" => ""}
      raw = Map.put(raw, section, <<255>>)

      assert CreationOptions.decode_wire(%{
               "version" => 1,
               "configuration" => %{"instructions" => raw}
             }) == :error
    end
  end

  test "tool count and byte boundaries are exact without selecting a host definition" do
    names = Enum.map(0..1_023, &("tool_" <> Integer.to_string(&1)))

    assert CreationOptions.decode_wire(%{"version" => 1, "tools" => names}) ==
             {:ok, %{"version" => 1, "tools" => names}}

    assert CreationOptions.decode_wire(%{"version" => 1, "tools" => names ++ ["extra"]}) == :error
    assert CreationOptions.decode_wire(%{"version" => 1, "tools" => ["read", "read"]}) == :error

    assert CreationOptions.decode_wire(%{"version" => 1, "tools" => [String.duplicate("a", 64)]}) !=
             :error

    assert CreationOptions.decode_wire(%{"version" => 1, "tools" => [String.duplicate("a", 65)]}) ==
             :error

    assert CreationOptions.decode_wire(%{"version" => 1, "tools" => ["read\n"]}) == :error

    assert CreationOptions.decode_wire(%{"version" => 1, "tools" => ["unknown_host_name"]}) !=
             :error
  end

  test "schema and literal vectors pin authored domains without generation activation" do
    schema = read("schema/creation-options.v1.json")
    assert schema["closed"] == true
    assert schema["required"] == ["version"]
    assert schema["optional"] == ~w(configuration tools)
    assert schema["tools"]["items_max"] == 1_024

    assert schema["configuration"]["members"] ==
             ~w(model reasoning instructions max_tokens context_token_budget system_class_tokens)

    assert schema["configuration"]["instructions"]["required"] ==
             ~w(version base environment appendix)

    assert schema["defaults"] == "none_in_decoder"
    assert schema["generation_activation"] == false

    for {relative, digest} <- [
          {"vectors/creation-options.v1.json",
           "ce9a93a1a3ea92135f914642784467b9dc45cd769b66aaa6b1ae9b0ae003ccbb"},
          {"schema/creation-options.v1.json",
           "017ccd7949985f9ae07aa6dce90e2139ed086040b157dde75fcf396cff64b876"}
        ] do
      assert :crypto.hash(:sha256, File.read!(path(relative))) |> Base.encode16(case: :lower) ==
               digest
    end
  end

  @tag :node_client
  test "independent Node consumes every creation vector and inert array boundary" do
    node = System.find_executable("node") || flunk("Node is required for creation vectors")
    root = Path.expand("../../..", __DIR__)
    runner = Path.join(root, "clients/node/creation-options-vectors.mjs")

    arguments = [
      runner,
      path("vectors/creation-options.v1.json"),
      path("schema/creation-options.v1.json")
    ]

    {output, status} = System.cmd(node, arguments, stderr_to_stdout: true)

    assert status == 0, output
    assert output =~ "\"vectors\":398"
    assert output =~ "\"subset_cases\":189"
  end

  defp retained(value, key \\ nil)

  defp retained(value, _key) when is_map(value),
    do: Map.new(value, fn {member, item} -> {member, retained(item, member)} end)

  defp retained(value, _key) when is_list(value), do: Enum.map(value, &retained/1)

  defp retained(value, key)
       when is_integer(value) and key in ~w(max_tokens context_token_budget system_class_tokens),
       do: Integer.to_string(value)

  defp retained(value, _key), do: value
  defp read(relative), do: JSON.decode!(File.read!(path(relative)))
  defp path(relative), do: Path.join(:code.priv_dir(:loopex_protocol), relative)
end
