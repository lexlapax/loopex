defmodule LoopexProtocol.ConfigureRequestTest do
  use ExUnit.Case, async: true

  alias LoopexProtocol.{Frame, Session.ConfigureRequest}

  test "literal configure vectors cover both exact envelopes and every nonempty update subset" do
    fixture = read("vectors/configure-request.v1.json")
    assert length(fixture["cases"]) == 381

    for vector <- fixture["cases"] do
      transport = transport(vector["transport"])

      if vector["error"] do
        assert ConfigureRequest.decode_wire(vector["input"], transport) == :error, vector["name"]
      else
        assert {:ok, decoded} = ConfigureRequest.decode_wire(vector["input"], transport)
        assert retained(decoded) == vector["decoded"], vector["name"]
      end
    end

    for name <- ["foreground", "daemon"] do
      subsets =
        Enum.filter(fixture["cases"], &String.starts_with?(&1["name"], name <> "-subset-"))

      assert length(subsets) == 63

      assert subsets
             |> Enum.map(&Enum.sort(Map.keys(&1["input"]["changes"])))
             |> Enum.uniq()
             |> length() == 63
    end
  end

  test "Frame rejects duplicate members before either configure adapter can see a map" do
    for vector <- read("vectors/configure-request.v1.json")["frame_cases"] do
      assert Frame.decode(vector["json"], 2_097_152) == {:error, :duplicate_member},
             vector["name"]
    end

    request = request()
    bytes = JSON.encode!(request)
    assert {:ok, admitted} = Frame.decode(bytes, byte_size(bytes))
    assert {:ok, _} = ConfigureRequest.decode_wire(admitted, :foreground)
    assert Frame.decode(bytes, byte_size(bytes) - 1) == {:error, :frame_too_large}

    oversized = put_in(request, ["changes", "model"], String.duplicate("m", 131_073))
    assert Frame.decode(JSON.encode!(oversized), 2_097_152) == {:error, :string_too_large}
    assert Frame.decode(<<255>>, 2_097_152) == {:error, :invalid_utf8}
  end

  test "raw native input refuses invalid UTF8 structs private fields and invalid transport selectors" do
    request = request()
    raw = request["changes"]["instructions"]

    for key <- ~w(base environment appendix) do
      invalid = put_in(request, ["changes", "instructions"], Map.put(raw, key, <<255>>))
      assert ConfigureRequest.decode_wire(invalid, :foreground) == :error
    end

    for invalid <- [
          nil,
          [],
          %URI{},
          Map.put(request, :authority, "private"),
          %{request | "changes" => %URI{}}
        ] do
      assert ConfigureRequest.decode_wire(invalid, :foreground) == :error
    end

    assert ConfigureRequest.decode_changes(%{"model" => <<255>>}) == :error

    assert ConfigureRequest.decode_changes(%{"instructions" => %{raw | "version" => "v\n"}}) ==
             :error

    assert ConfigureRequest.decode_wire(request, :other) == :error
    assert ConfigureRequest.decode_wire(request, "foreground") == :error
  end

  test "standalone schema and vectors pin current authored domains without activating a generation" do
    schema = read("schema/configure-request.v1.json")
    assert schema["closed"] == true
    assert schema["generation_activation"] == false

    assert schema["changes"]["members"] ==
             ~w(model reasoning instructions max_tokens context_token_budget system_class_tokens)

    assert schema["changes"]["instructions"]["required"] == ~w(version base environment appendix)
    assert schema["writer_epoch"]["original_bytes_max"] == 64

    for {file, digest} <- [
          {"vectors/configure-request.v1.json",
           "fff66292cb2904ccb6fc4260de370a969e9bfc0eda478b6f0c726ecffed944fe"},
          {"schema/configure-request.v1.json",
           "970400e653364af023918ceb960a499d6f6b1654646de5fc10330953e56a0ef4"}
        ] do
      assert :crypto.hash(:sha256, File.read!(path(file))) |> Base.encode16(case: :lower) ==
               digest
    end
  end

  @tag :node_client
  test "independent Node consumes every configure vector with exact BigInt and opaque bytes" do
    node = System.find_executable("node") || flunk("Node is required for configure vectors")
    root = Path.expand("../../..", __DIR__)

    argv = [
      Path.join(root, "clients/node/configure-request-vectors.mjs"),
      path("vectors/configure-request.v1.json"),
      path("schema/configure-request.v1.json")
    ]

    {output, status} = System.cmd(node, argv, stderr_to_stdout: true)
    assert status == 0, output
    assert output =~ "\"vectors\":381"
    assert output =~ "\"subset_cases\":126"
  end

  defp request do
    Enum.find(
      read("vectors/configure-request.v1.json")["cases"],
      &(&1["name"] == "foreground-subset-63")
    )["input"]
  end

  defp transport("foreground"), do: :foreground
  defp transport("daemon"), do: :daemon
  defp retained(value, key \\ nil)

  defp retained(value, _key) when is_map(value),
    do: Map.new(value, fn {key, member} -> {to_string(key), retained(member, to_string(key))} end)

  defp retained(value, key) when is_binary(value) and key in ~w(command_id writer_epoch),
    do: %{"opaque_hex" => Base.encode16(value, case: :lower)}

  defp retained(value, _key) when is_integer(value), do: Integer.to_string(value)
  defp retained(value, _key), do: value
  defp read(relative), do: JSON.decode!(File.read!(path(relative)))
  defp path(relative), do: Path.join(:code.priv_dir(:loopex_protocol), relative)
end
