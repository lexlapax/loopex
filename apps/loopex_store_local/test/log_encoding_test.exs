defmodule Loopex.Store.Local.LogEncodingTest do
  use ExUnit.Case, async: true

  alias Loopex.Store.Local.Log

  setup do
    root = Path.join(System.tmp_dir!(), "store-encoding-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    %{path: Path.join(root, "store.log")}
  end

  test "writer frames retain every canonical map and complete boundary", %{path: path} do
    frames = [%{"a" => 1, "b" => 2}, %{"empty" => %{}, "bytes" => <<0, 255>>}]

    bytes =
      Enum.map_join(frames, fn frame ->
        {:ok, bytes} = Log.encode(frame)
        bytes
      end)

    File.write!(path, bytes)
    assert {:ok, ^frames, :complete} = Log.read(path)
    assert File.read!(path) == bytes
  end

  test "a checksummed compressed payload cannot bypass the expanded frame ceiling", %{path: path} do
    frame = %{"bytes" => :binary.copy("x", 4 * 1_048_576 + 1)}
    payload = :erlang.term_to_binary(frame, [:compressed])
    assert <<131, 80, _::binary>> = payload
    assert byte_size(payload) < 4 * 1_048_576
    assert {:error, :store_frame_too_large} = Log.encode(frame)
    assert_corrupt_payload(path, payload)
  end

  test "a checksummed payload must consume all its declared bytes", %{path: path} do
    payload = :erlang.term_to_binary(%{"a" => 1}, [:deterministic]) <> "trailing"
    assert_corrupt_payload(path, payload)
  end

  test "a checksummed map must use the writer's deterministic encoding", %{path: path} do
    # Concept: equivalent decoded maps do not make alternate physical histories valid.
    # Technical depth: two reversed map entries form valid uncompressed ETF;
    # both digests below are correct, so refusal must come from payload validation.
    payload = <<131, 116, 2::32, 109, 1::32, "b", 97, 2, 109, 1::32, "a", 97, 1>>
    assert :erlang.binary_to_term(payload, [:safe]) == %{"a" => 1, "b" => 2}
    refute payload == :erlang.term_to_binary(%{"a" => 1, "b" => 2}, [:deterministic])
    assert_corrupt_payload(path, payload)
  end

  defp assert_corrupt_payload(path, payload) do
    {:ok, prefix} = Log.encode(%{"prefix" => "retained"})
    header = <<"LXST", 2, byte_size(payload)::32>>

    bytes =
      prefix <>
        header <> :crypto.hash(:sha256, header) <> :crypto.hash(:sha256, payload) <> payload

    File.write!(path, bytes)

    assert {:ok, [%{"prefix" => "retained"}], {:corrupt, offset}} = Log.read(path)
    assert offset == byte_size(prefix)
    assert File.read!(path) == bytes
  end
end
