defmodule LoopexProtocol.WireTest do
  @moduledoc """
  ## Concept

  Each wire value type has exactly one representation, and a near miss is
  refused rather than repaired.

  ## Technical depth

  The negatives carry the weight. A decoder that accepted padded and unpadded
  base64url, or a leading zero in a decimal, or an uppercase digest, would give
  a client two ways to name one thing and a server two strings that compare
  unequal while meaning the same bytes. Each of those is asserted as a refusal
  beside the form that is admitted.
  """

  use ExUnit.Case, async: true

  alias LoopexProtocol.Wire

  test "an identity round-trips through its unpadded encoding" do
    for bytes <- ["s", "session-1", <<0, 1, 2, 255>>, String.duplicate("x", 1_000)] do
      encoded = Wire.encode_identity(bytes)

      refute String.contains?(encoded, "=")
      assert {:ok, ^bytes} = Wire.identity(encoded)
    end
  end

  test "a padded identity is refused, because one thing may not have two spellings" do
    bytes = "abcde"
    padded = Base.url_encode64(bytes, padding: true)

    assert String.contains?(padded, "=")
    assert :error = Wire.identity(padded)
    assert {:ok, ^bytes} = Wire.identity(Base.url_encode64(bytes, padding: false))
  end

  test "an identity outside the admitted length is refused at both ends" do
    assert :error = Wire.identity("")
    assert :error = Wire.identity(Wire.encode_identity(String.duplicate("x", 65_537)))
    assert {:ok, _bytes} = Wire.identity(Wire.encode_identity(String.duplicate("x", 65_536)))
  end

  test "a session identity carries the tighter bound" do
    assert {:ok, _bytes} =
             Wire.session_identity(Wire.encode_identity(String.duplicate("s", 256)))

    assert :error = Wire.session_identity(Wire.encode_identity(String.duplicate("s", 257)))
  end

  test "standard base64 is not base64url, and is refused" do
    bytes = <<251, 255, 190>>
    standard = Base.encode64(bytes, padding: false)

    assert String.contains?(standard, "+") or String.contains?(standard, "/")
    assert :error = Wire.identity(standard)
  end

  test "a quantity travels as canonical decimal and reaches the whole range" do
    assert {:ok, 0} = Wire.u64("0")
    assert {:ok, 1} = Wire.u64("1")
    assert {:ok, 18_446_744_073_709_551_615} = Wire.u64("18446744073709551615")

    assert Wire.encode_u64(0) == "0"
    assert Wire.encode_u64(18_446_744_073_709_551_615) == "18446744073709551615"
  end

  test "a quantity in any other spelling is refused, including a number" do
    for rejected <- [
          "",
          "01",
          "+1",
          "-1",
          " 1",
          "1 ",
          "1.0",
          "0x1",
          "one",
          "18446744073709551616"
        ] do
      assert :error = Wire.u64(rejected), "admitted #{inspect(rejected)}"
    end

    # A JSON number is refused even where it would fit, because the contract
    # admits exactly one representation.
    assert :error = Wire.u64(1)
    assert :error = Wire.u64(nil)
  end

  test "a digest is sixty-four lowercase hexadecimal characters and nothing else" do
    digest = String.duplicate("ab", 32)

    assert {:ok, ^digest} = Wire.digest(digest)
    assert :error = Wire.digest(String.upcase(digest))
    assert :error = Wire.digest(String.duplicate("ab", 31))
    assert :error = Wire.digest(String.duplicate("ag", 32))
    assert :error = Wire.digest(nil)
  end

  test "bytes cross intact, including bytes that are not text" do
    content = <<0, 159, 146, 150>>

    refute String.valid?(content)

    encoded = Wire.encode_bytes(content)
    assert {:ok, ^content} = Wire.bytes(encoded, 1_024)
  end

  test "bytes beyond the supplied bound are refused" do
    encoded = Wire.encode_bytes(String.duplicate("x", 100))

    assert :error = Wire.bytes(encoded, 99)
    assert {:ok, _decoded} = Wire.bytes(encoded, 100)
  end
end
