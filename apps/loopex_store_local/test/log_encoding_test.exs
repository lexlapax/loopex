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

    assert {:ok, ^frames, :complete} = Log.decode_bytes(bytes)
    File.write!(path, bytes)
    assert {:ok, ^frames, :complete} = Log.read(path)
    assert File.read!(path) == bytes
  end

  test "empty byte decoding and missing-file reads do not create a log", %{path: path} do
    assert {:ok, [], :complete} = Log.decode_bytes(<<>>)
    refute File.exists?(path)
    assert {:ok, [], :complete} = Log.read(path)
    refute File.exists?(path)

    File.write!(path, <<>>)
    assert {:ok, [], :complete} = Log.read(path)
    assert File.read!(path) == <<>>
  end

  test "captured torn evidence agrees with read without repairing the file", %{path: path} do
    frame = %{"prefix" => "retained"}
    {:ok, prefix} = Log.encode(frame)
    {:ok, next} = Log.encode(%{"next" => "incomplete"})
    bytes = prefix <> binary_part(next, 0, byte_size(next) - 1)
    tail = {:torn, byte_size(prefix), byte_size(bytes), :crypto.hash(:sha256, bytes)}

    assert {:ok, [^frame], ^tail} = Log.decode_bytes(bytes)
    File.write!(path, bytes)
    assert {:ok, [^frame], ^tail} = Log.read(path)
    assert File.read!(path) == bytes
  end

  test "a non-header byte prefix is corrupt at its original offset" do
    assert {:ok, [], {:corrupt, 0}} = Log.decode_bytes("invalid")
  end

  test "the byte decoder enforces the actual whole-log ceiling before decoding" do
    ceiling = 256 * 1_048_576
    oversized = :binary.copy(<<0>>, ceiling + 1)

    assert {:error, {:store_log_too_large, observed, ^ceiling}} =
             Log.decode_bytes(oversized)

    assert observed == ceiling + 1
    bounded = binary_part(oversized, 0, ceiling)
    assert {:ok, [], {:corrupt, 0}} = Log.decode_bytes(bounded)
  end

  test "byte decoding loads the fixed envelope schema in a cold VM" do
    executable = System.find_executable("elixir") || raise "elixir executable unavailable"
    core_ebin = Loopex.Store |> :code.which() |> List.to_string() |> Path.dirname()
    local_ebin = Log |> :code.which() |> List.to_string() |> Path.dirname()
    {:ok, bytes} = Log.encode(%{orphan_resolutions: %{}})
    encoded = Base.encode64(bytes)

    script = """
    modules = [Loopex.Store, Loopex.Store.Transitions, Loopex.Store.Local.State]

    if Enum.any?(modules, &Code.loaded?/1) do
      System.halt(20)
    end

    with {:ok, [_frame], :complete} <-
           Loopex.Store.Local.Log.decode_bytes(Base.decode64!(#{inspect(encoded)})),
         true <- Enum.all?(modules, &Code.loaded?/1) do
      IO.write("cold-byte-decode-ok")
    else
      _other -> System.halt(21)
    end
    """

    assert {"cold-byte-decode-ok", 0} =
             System.cmd(
               executable,
               ["--erl", "+S 1:1", "-pa", core_ebin, "-pa", local_ebin, "-e", script],
               stderr_to_stdout: true
             )
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

    assert {:ok, [%{"prefix" => "retained"}], {:corrupt, offset}} =
             Log.decode_bytes(bytes)

    assert {:ok, [%{"prefix" => "retained"}], {:corrupt, ^offset}} = Log.read(path)
    assert offset == byte_size(prefix)
    assert File.read!(path) == bytes
  end
end
