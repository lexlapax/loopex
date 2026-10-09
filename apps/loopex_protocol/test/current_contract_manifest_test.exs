defmodule LoopexProtocol.CurrentContractManifestTest do
  @moduledoc """
  ## Concept

  The exact current foreground and daemon contracts bind their complete payloads
  before connection owners may dispatch session requests.

  ## Technical depth

  Literal canonical preimages and digests are independent of the module getters.
  Existing payload conformance populations remain required. Node additionally
  verifies full manifests, approved payload vectors and actual client gates.
  """

  use ExUnit.Case, async: true

  alias LoopexProtocol.{Canonical, Frame, Session}
  alias LoopexProtocol.Session.{Manifest, V2}

  @priv Path.expand("../priv", __DIR__)
  @vectors_path Path.join(@priv, "vectors/current-contract-manifests.v1.json")
  @fixture @vectors_path |> File.read!() |> JSON.decode!()

  test "seven exact manifest keys bind literal canonical bytes and every inventory" do
    for {contract, vector} <- Enum.zip([Session, V2], @fixture["manifests"]) do
      manifest = contract.manifest()

      assert Enum.sort(Map.keys(manifest)) ==
               Enum.sort(
                 ~w(generation canonicalization_revision methods record_families error_codes limits payload_definitions)
               )

      assert contract.generation() == vector["generation"]
      assert manifest["canonicalization_revision"] == "loopex.canonical.v1"
      assert manifest["methods"] == vector["methods"]
      assert manifest["record_families"] == vector["record_families"]
      assert manifest["error_codes"] == vector["error_codes"]
      bytes = Canonical.encode(manifest)
      assert Base.encode16(bytes, case: :lower) == vector["canonical_hex"]
      assert byte_size(bytes) == vector["canonical_bytes"]
      assert contract.schema_digest() == vector["sha256"]

      assert File.read!(Path.join([@priv, "schema", vector["schema"]]))
             |> Canonical.digest_bytes() == vector["schema_file_sha256"]
    end
  end

  test "each contract refuses old-only and wrong-server offers and admits both mixed orders" do
    for {contract, vector} <- Enum.zip([Session, V2], @fixture["manifests"]),
        negotiation <- vector["negotiation"] do
      if negotiation["expect"] == "unsupported_generation" do
        assert {:error, :unsupported_generation} = contract.negotiate(negotiation["offered"], [])
      else
        assert {:ok, reply} = contract.negotiate(negotiation["offered"], [])
        assert reply["selected_generation"] == negotiation["expect"]
        assert reply["exact_schema_sha256"] == vector["sha256"]
      end
    end
  end

  test "the reader refuses duplicate keys, extra keys and another canonicalization recipe" do
    encoded = Session.manifest() |> JSON.encode!()
    assert Manifest.decode!(encoded) == Session.manifest()

    for manifest <- [
          Map.put(Session.manifest(), "unknown", true),
          Map.put(Session.manifest(), "canonicalization_revision", "unknown"),
          Map.put(Session.manifest(), "payload_definitions", %{}),
          Map.put(Session.manifest(), "methods", ["session.create", "session.create"])
        ] do
      assert_raise ArgumentError, fn -> Manifest.decode!(JSON.encode!(manifest)) end
    end

    duplicate = String.replace_prefix(encoded, "{", ~s({"generation":"loopex.experimental/3",))
    assert_raise ArgumentError, fn -> Manifest.decode!(duplicate) end
  end

  test "all current methods and record families have closed payload definitions" do
    for contract <- [Session, V2] do
      definitions = contract.manifest()["payload_definitions"]
      requests = definitions["requests"]["methods"]
      assert Enum.sort(Map.keys(requests)) == Enum.sort(["initialize" | contract.methods()])
      for request <- Map.values(requests), do: assert(request["closed"] == true)
      assert Enum.sort(Map.keys(definitions["records"])) == Enum.sort(contract.record_families())
      for record <- Map.values(definitions["records"]), do: assert(record["closed"] == true)
      nested = definitions["nested"]
      assert nested["session_snapshot"]["snapshot_revision"] == 3
      assert length(nested["session_snapshot"]["required"]) == 10
      assert length(nested["inspection"]["required"]) == 11
      assert nested["inspection"]["closed"]
      assert nested["creation_options"]["version"]["exact"] == 1
      assert nested["configure_request"]["changes"]["members_min"] == 1
      assert nested["compaction_progress"]["owner"] == nested["checkpoint_owner"]

      assert nested["standalone_compact_completion"]["result"] ==
               nested["standalone_compact_result"]

      changed =
        put_in(
          contract.manifest(),
          ["payload_definitions", "nested", "creation_options", "version", "exact"],
          2
        )

      refute Canonical.digest(changed) == contract.schema_digest()
    end
  end

  test "owned artifact opening failure variants and the two added limits are exact" do
    admitted_reasons =
      ~w(invalid_artifact_request invalid_open_context reservation_required reservation_conflict unknown_artifact_use artifact_use_mismatch artifact_integrity_failed artifact_digest_mismatch unknown_artifact artifact_too_large invalid_window open_deadline_exhausted open_work_budget_exhausted transfer_limit_reached transfers_unavailable artifact_unreadable cancelled)

    ordinary_reasons = %{
      "open_preadmission" =>
        ~w(attachment_required invalid_attachment stale_attachment invalid_artifact_request artifact_transfer_unsupported transfer_limit_reached open_work_budget_exhausted transfers_unavailable),
      "read" =>
        ~w(attachment_required invalid_attachment stale_attachment unknown_transfer invalid_chunk_length open_work_budget_exhausted transfers_unavailable read_deadline_exhausted artifact_unreadable runtime_unavailable),
      "close" =>
        ~w(attachment_required invalid_attachment stale_attachment unknown_transfer cleanup_unproved)
    }

    for {contract, generation} <- [{Session, 3}, {V2, 4}] do
      definitions = contract.manifest()["payload_definitions"]
      error = definitions["records"]["error"]

      assert error["transfer_refused_admitted_open"] == %{
               "required" => ~w(type request_id code message reason cleanup),
               "code" => "transfer_refused",
               "reason_enum" => admitted_reasons,
               "cleanup_enum" => ~w(proved unproved),
               "closed" => true
             }

      assert error["transfer_refused_without_cleanup"] == %{
               "required" => ~w(type request_id code message reason),
               "code" => "transfer_refused",
               "reason_enum_by_operation" => ordinary_reasons,
               "cleanup" => "absent",
               "closed" => true
             }

      assert error["transfer_refused_forms_are_mutually_exclusive"]
      assert error["transfer_refused_reason_enum_scope"] == "without_cleanup_only"
      limits = definitions["payload_limits"]
      assert limits["artifact_open_storage_work_bytes"] == 134_217_728
      assert limits["artifact_open_metadata_read_bytes"] == 131_073
      assert limits["artifact_cleanup_observation_ms"] == 5_000

      for key <- ["artifact_open_metadata_read_bytes", "artifact_cleanup_observation_ms"] do
        changed = put_in(contract.manifest(), ["payload_definitions", "payload_limits", key], 0)
        refute Canonical.digest(changed) == contract.schema_digest()
      end

      cases =
        @priv
        |> Path.join("vectors/loopex-experimental-#{generation}.json")
        |> File.read!()
        |> JSON.decode!()
        |> Map.fetch!("cases")
        |> Enum.filter(&Map.has_key?(&1, "artifact_refusal_scope"))

      assert length(cases) == 108

      admitted =
        Enum.filter(cases, fn vector ->
          vector["artifact_refusal_scope"] == "open_admitted" and
            vector["artifact_refusal_valid"]
        end)

      assert length(admitted) == 34

      for reason <- admitted_reasons, cleanup <- ~w(proved unproved) do
        matches =
          Enum.filter(admitted, fn vector ->
            record = vector["raw_hex"] |> Base.decode16!(case: :lower) |> JSON.decode!()
            record["reason"] == reason and record["cleanup"] == cleanup
          end)

        assert length(matches) == 1
      end

      for vector <- cases do
        bytes = Base.decode16!(vector["raw_hex"], case: :lower)
        assert String.ends_with?(bytes, "\n")
        line = binary_part(bytes, 0, byte_size(bytes) - 1)
        assert {:ok, _record} = Frame.decode(line, 65_536)
      end
    end
  end

  @tag :node_client
  test "Node independently reproduces complete identities and accepted payload populations" do
    report = run_node("current-contract-manifest-vectors.mjs", [@vectors_path])
    assert report["manifests"] == 2
    assert report["payload_vectors"] > 3_000
    assert report["embedded_definition_changes"] >= 40
    assert report["artifact_refusal_vectors"] == 216
    assert report["artifact_refusal_positive"] == 114
    assert report["artifact_refusal_negative"] == 102
  end

  @tag :node_client
  test "both real client implementations gate session traffic before initialization and on mismatch" do
    report = run_node("contract-negotiation-tests.mjs", [])
    assert report["transports"] == 2
    assert report["scenarios"] == 12
    assert report["mismatch_session_frames"] == 0
  end

  defp run_node(script, arguments) do
    node =
      System.find_executable("node") || flunk("Node is required for current contract conformance")

    root = Path.expand("../../..", __DIR__)

    {output, status} =
      System.cmd(node, [Path.join([root, "clients", "node", script]) | arguments],
        stderr_to_stdout: true
      )

    assert status == 0, output
    assert {:ok, report} = Frame.decode(String.trim_trailing(output, "\n"), 65_536)
    report
  end
end
