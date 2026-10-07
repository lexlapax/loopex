defmodule Loopex.StreamDomainTest do
  use ExUnit.Case, async: true

  alias Loopex.StreamDomain
  alias LoopexProtocol.Canonical

  test "compaction uses the accepted binary kind and opaque length-aware tuple" do
    # Independent ETF bytes: tuple arity five, four length-prefixed binaries,
    # and SMALL_INTEGER_EXT one. No production Canonical or domain constructor
    # supplies these bytes.
    bytes =
      <<131, 104, 5, 109, 0, 0, 0, 23, "loopex.stream_domain.v1", 109, 0, 0, 0, 10, "compaction",
        109, 0, 0, 0, 8, "session", 0, 109, 0, 0, 0, 10, "operation", 255, 97, 1>>

    expected = :crypto.hash(:sha256, bytes) |> binary_part(0, 16) |> Base.encode16(case: :lower)
    assert StreamDomain.derive(:compaction, <<"session", 0>>, <<"operation", 255>>, 1) == expected
    assert expected == "0b02c7af5f776c8f0e098f343348e89e"
    assert byte_size(expected) == 32
  end

  test "retry and further summary separate domains without changing ordinary domain bytes" do
    first = StreamDomain.derive(:compaction, "session", "operation", 1)
    retry = StreamDomain.derive(:compaction, "session", "operation", 2)
    next = StreamDomain.derive(:compaction, "session", "next-operation", 1)
    assert length(Enum.uniq([first, retry, next])) == 3

    for kind <- [:model, :executor] do
      existing =
        {"loopex.stream_domain.v1", kind, "session", "operation", 1}
        |> Canonical.encode()
        |> then(&:crypto.hash(:sha256, &1))
        |> binary_part(0, 16)
        |> Base.encode16(case: :lower)

      assert StreamDomain.derive(kind, "session", "operation", 1) == existing
      refute existing in [first, retry, next]
    end
  end

  test "length-aware identities cannot collide across an identifier boundary" do
    refute StreamDomain.derive(:compaction, "a", "b:c", 1) ==
             StreamDomain.derive(:compaction, "a:b", "c", 1)

    assert_raise FunctionClauseError, fn ->
      apply(StreamDomain, :derive, [:unknown, "a", "b", 1])
    end
  end
end
