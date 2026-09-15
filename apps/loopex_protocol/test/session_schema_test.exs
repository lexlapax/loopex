defmodule LoopexProtocol.SessionTest do
  @moduledoc """
  ## Concept

  The generation-one contract is exactly what accepted ADR 0023 states, and its
  digest names the whole of it, so a client in another language can check that
  it is talking to the contract it was written against.

  ## Technical depth

  These are schema vectors. They assert the literal names, the literal order and
  a literal digest rather than recomputing them from the module under test,
  because a test that derives its expectation from the implementation proves
  only that the implementation is self-consistent. The digest is written out so
  that any change to a method, a family, a code or a maximum fails here and has
  to be a deliberate change to the contract.
  """

  use ExUnit.Case, async: true

  alias LoopexProtocol.Session

  test "the generation names itself experimental and is the only one offered" do
    assert Session.generation() == "loopex.session.v1-experimental"
  end

  test "the sixteen methods are exactly these, in this order" do
    assert Session.methods() == [
             "session.create",
             "session.resume",
             "session.inspect",
             "session.attach",
             "session.prompt",
             "session.steer",
             "session.follow_up",
             "session.abort",
             "session.respond_interaction",
             "resources.catalog",
             "resources.read",
             "session.admit_resources",
             "session.activate_skill",
             "artifact.open_transfer",
             "artifact.read_chunk",
             "artifact.close_transfer"
           ]

    assert length(Session.methods()) == 16
    assert Enum.uniq(Session.methods()) == Session.methods()
  end

  test "the record families are the five correlated types and the two asynchronous ones" do
    assert Session.record_families() == [
             "initialized",
             "result",
             "snapshot",
             "admission",
             "error",
             "event",
             "progress"
           ]
  end

  test "the error code set is closed and contains no code a method could invent" do
    codes = Session.error_codes()

    assert length(codes) == 15
    assert Enum.uniq(codes) == codes

    for code <- [
          "invalid_frame",
          "invalid_request",
          "not_initialized",
          "already_initialized",
          "unsupported_generation",
          "unsupported_method",
          "admission_unknown",
          "detached",
          "internal_failure"
        ] do
      assert code in codes
    end

    refute "unknown" in codes
    refute "ok" in codes
  end

  test "the schema maxima are the exact numbers the decision states" do
    limits = Session.limits()

    assert limits["frame_bytes_before_initialization"] == 65_536
    assert limits["frame_bytes"] == 1_048_576
    assert limits["output_record_bytes"] == 2_097_152
    assert limits["max_depth"] == 16
    assert limits["max_members"] == 1_024
    assert limits["max_string_bytes"] == 131_072
    assert limits["max_session_identity_bytes"] == 256
    assert limits["max_requests_in_flight"] == 32
    assert limits["reply_wait_ms"] == 30_000
    assert limits["writer_detach_ms"] == 5_000

    # The integer interval is the IEEE-754-safe one, stated on both sides, so a
    # client cannot send a number it can hold but cannot round-trip.
    assert limits["integer_max"] == 9_007_199_254_740_991
    assert limits["integer_min"] == -9_007_199_254_740_991
  end

  test "the digest names the whole contract and is stable across builds" do
    digest = Session.schema_digest()

    assert String.length(digest) == 64
    assert digest == String.downcase(digest)
    assert digest =~ ~r/^[0-9a-f]{64}$/

    # The vector. A change to any method, family, code or maximum changes this
    # and must be a deliberate change to the contract.
    assert digest == "3a1723e370bf392e2a6e9d2709c22735577d8cfbf946d63ac22e12a8fa1708f4"

    assert Session.schema_digest() == digest
  end

  test "a client offering this generation gets it, with the contract attached" do
    assert {:ok, reply} = Session.negotiate([Session.generation()], [])

    assert reply["type"] == "initialized"
    assert reply["selected_generation"] == Session.generation()
    assert reply["exact_schema_sha256"] == Session.schema_digest()
    assert reply["supported_methods"] == Session.methods()
    assert reply["record_families"] == Session.record_families()
    assert reply["limits"] == Session.limits()
  end

  test "a client's own preference order decides, among generations this server has" do
    assert {:ok, reply} =
             Session.negotiate(["loopex.session.v9-imaginary", Session.generation()], [])

    assert reply["selected_generation"] == Session.generation()
  end

  test "no common generation refuses rather than choosing something neither side named" do
    assert {:error, :unsupported_generation} =
             Session.negotiate(["loopex.session.v9-imaginary"], [])

    assert {:error, :unsupported_generation} = Session.negotiate([""], [])
  end

  test "a declared capability is reported back and enables no method" do
    assert {:ok, reply} = Session.negotiate([Session.generation()], ["daemon.residency"])

    assert reply["unsupported_capabilities"] == ["daemon.residency"]
    assert reply["supported_methods"] == Session.methods()
    refute "daemon.residency" in reply["supported_methods"]
  end
end
