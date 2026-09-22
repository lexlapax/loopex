defmodule LoopexProtocol.Session.V2Test do
  @moduledoc """
  ## Concept

  Generation two is one exact daemon protocol, not a partial extension selected
  piecemeal. Its metadata tells an independent client the complete contract it
  is about to speak.

  ## Technical depth

  These assertions are literal vectors. They pin ordering and the digest rather
  than deriving expectations from the module under test. They also compare the
  inherited prefix with generation one so a daemon addition cannot silently
  edit the foreground contract.
  """

  use ExUnit.Case, async: true

  alias LoopexProtocol.Session
  alias LoopexProtocol.Session.V2

  test "the daemon generation and its twenty ordered methods are exact" do
    assert V2.generation() == "loopex.experimental/2"

    assert V2.methods() == [
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
             "artifact.close_transfer",
             "session.list",
             "daemon.status",
             "session.acquire_control",
             "session.release_control"
           ]

    assert Enum.take(V2.methods(), 16) == Session.methods()
  end

  test "the two daemon notification families extend generation one" do
    assert V2.record_families() == [
             "initialized",
             "result",
             "snapshot",
             "admission",
             "error",
             "event",
             "progress",
             "daemon.stopping",
             "daemon.notice"
           ]

    assert Enum.take(V2.record_families(), 7) == Session.record_families()
  end

  test "the twelve daemon refusal codes extend the inherited closed inventory" do
    assert V2.error_codes() == [
             "invalid_frame",
             "invalid_request",
             "not_initialized",
             "already_initialized",
             "unsupported_generation",
             "unsupported_method",
             "not_attached",
             "attachment_conflict",
             "capacity_exceeded",
             "facade_unavailable",
             "recovery_required",
             "admission_unknown",
             "transfer_refused",
             "detached",
             "internal_failure",
             "control_held",
             "control_not_held",
             "control_pending",
             "control_capacity_reached",
             "control_owner_lost",
             "session_dormant",
             "session_unavailable",
             "daemon_stopping",
             "session_unknown",
             "store_unavailable",
             "activation_ceiling_reached",
             "composition_mismatch"
           ]

    assert Enum.take(V2.error_codes(), 15) == Session.error_codes()

    for private <- [
          "session_id_invalid",
          "session_index_too_large",
          "session_index_corrupt",
          "session_index_upgrade_required",
          "attachment_superseded",
          "attachment_route_invalidated"
        ] do
      refute private in V2.error_codes()
    end
  end

  test "generation two retains every generation-one limit and adds exactly seven" do
    additions = %{
      "connections_per_daemon" => 512,
      "initialize_deadline_ms" => 30_000,
      "attachments_per_session" => 64,
      "attachments_per_daemon" => 512,
      "session_list_page_max" => 256,
      "session_index_entries" => 4_096,
      "lease_term_ms" => 30_000
    }

    assert V2.limits() == Map.merge(Session.limits(), additions)
    assert map_size(V2.limits()) == map_size(Session.limits()) + 7
  end

  test "the generation-two digest is a pinned distinct contract identity" do
    assert V2.schema_digest() ==
             "332626803532893558852b6f81bb7ba4b2cc39fd679ba7a4ff3e8145d3eb5f55"

    refute V2.schema_digest() == Session.schema_digest()
  end

  test "the daemon selects only generation two" do
    assert {:ok, reply} =
             V2.negotiate([Session.generation(), V2.generation()], ["future.capability"])

    assert reply == %{
             "type" => "initialized",
             "selected_generation" => V2.generation(),
             "exact_schema_sha256" => V2.schema_digest(),
             "supported_methods" => V2.methods(),
             "record_families" => V2.record_families(),
             "limits" => V2.limits(),
             "unsupported_capabilities" => ["future.capability"]
           }

    assert {:error, :unsupported_generation} = V2.negotiate([Session.generation()], [])

    assert {:error, :unsupported_generation} =
             V2.negotiate(["loopex.session.v1-experimental"], [])
  end
end
