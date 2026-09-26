defmodule LoopexDaemon.SessionIndex.CodecTest do
  use ExUnit.Case, async: true

  alias LoopexDaemon.SessionIndex.Codec
  alias LoopexProtocol.Wire

  test "empty and populated images are canonical and sort by decoded identity" do
    assert {:ok, empty} = Codec.encode([])

    assert empty ==
             "{\"format\":\"loopex-session-index\",\"version\":1}\n" <>
               "{\"sha256\":\"b53b68fc66bb4a1d3d743115caed14f8716b9ea9286fa1472c33661d1e59bda2\"}\n"

    assert byte_size(empty) == 46 + 78
    assert {:ok, []} = Codec.decode(empty)

    rows = [
      %{session_id: <<255>>, placement_identity: "placement-b"},
      %{session_id: <<0>>, placement_identity: "placement-a"}
    ]

    assert {:ok, image} = Codec.encode(rows)
    assert {:ok, decoded} = Codec.decode(image)
    assert Enum.map(decoded, & &1.session_id) == [<<0>>, <<255>>]
    assert {:ok, ^image} = Codec.encode(decoded)
  end

  test "the maximal canonical row is 726 bytes and one added byte corrupts it" do
    identity = :binary.copy(<<255>>, 256)
    placement = :binary.copy(<<254>>, 256)

    assert {:ok, image} =
             Codec.encode([%{session_id: identity, placement_identity: placement}])

    [_header, row, _trailer, ""] = :binary.split(image, "\n", [:global])
    assert byte_size(row) + 1 == 726

    assert {:ok, [%{session_id: ^identity, placement_identity: ^placement}]} =
             Codec.decode(image)

    oversized_row = row <> "x"
    domain = header() <> "\n" <> oversized_row <> "\n"
    corrupt = domain <> trailer(domain)
    assert {:error, :session_index_corrupt} = Codec.decode(corrupt)
  end

  test "entry and file ceilings have distinct results" do
    rows =
      for value <- 0..(Codec.max_entries() - 1) do
        %{session_id: <<value::unsigned-integer-size(16)>>, placement_identity: "p"}
      end

    assert {:ok, image} = Codec.encode(rows)
    assert {:ok, decoded} = Codec.decode(image)
    assert length(decoded) == Codec.max_entries()

    assert {:error, :session_index_full} =
             Codec.encode([
               %{session_id: <<255, 255, 255>>, placement_identity: "p"} | rows
             ])

    assert {:error, :session_index_too_large} =
             Codec.decode(:binary.copy("x", Codec.max_file_bytes() + 1))
  end

  test "alternate or damaged persisted spellings are corrupt" do
    first = %{session_id: <<1>>, placement_identity: "p"}
    second = %{session_id: <<2>>, placement_identity: "p"}
    assert {:ok, image} = Codec.encode([first, second])
    [header, row_one, row_two, trailer, ""] = :binary.split(image, "\n", [:global])

    padded = String.replace(row_one, Wire.encode_identity(<<1>>), "AQ==")
    invalid_alphabet = String.replace(row_one, Wire.encode_identity(<<1>>), "+")

    corrupt_images = [
      String.replace(image, header, "{\"version\":1,\"format\":\"loopex-session-index\"}"),
      String.replace(image, row_one, String.replace(row_one, "\":\"", "\": \"", global: false)),
      String.replace(image, row_one, padded),
      String.replace(image, row_one, invalid_alphabet),
      assemble([row_two, row_one]),
      assemble([row_one, row_one]),
      header <> "\r\n" <> row_one <> "\n" <> row_two <> "\n" <> trailer <> "\n",
      binary_part(image, 0, byte_size(image) - 1),
      String.replace(image, trailer, "{\"sha256\":\"#{String.duplicate("0", 64)}\"}"),
      String.duplicate("\n", Codec.max_entries() + 3)
    ]

    for corrupt <- corrupt_images do
      assert {:error, :session_index_corrupt} = Codec.decode(corrupt)
    end
  end

  test "live encoding refuses invalid identities and duplicate session rows" do
    assert {:error, :invalid_index_entry} =
             Codec.encode([%{session_id: "", placement_identity: "p"}])

    assert {:error, :invalid_index_entry} =
             Codec.encode([
               %{session_id: "s", placement_identity: "one"},
               %{session_id: "s", placement_identity: "two"}
             ])

    assert {:error, :invalid_index_entry} =
             Codec.encode([
               %{session_id: :not_bytes, placement_identity: "p"}
             ])
  end

  defp assemble(rows) do
    domain = header() <> "\n" <> Enum.join(rows, "\n") <> "\n"
    domain <> trailer(domain)
  end

  defp trailer(domain) do
    digest = :crypto.hash(:sha256, domain) |> Base.encode16(case: :lower)
    "{\"sha256\":\"#{digest}\"}\n"
  end

  defp header, do: "{\"format\":\"loopex-session-index\",\"version\":1}"
end
