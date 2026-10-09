defmodule LoopexCli.M7ExecutionManifestTest do
  use ExUnit.Case, async: true

  # Concept: the committed execution manifest fixes one owner for every V1–V13
  # step before any execution, and its gaps stay visible as pending.

  alias Mix.Tasks.Loopex.M7Evidence.{ExecutionManifest, FixtureManifest}

  @repository Path.expand("../../..", __DIR__)
  @fixtures Path.join(@repository, "test/fixtures/m7")

  setup do
    {:ok, catalog} = FixtureManifest.load(@fixtures)
    %{manifest: catalog.catalog["execution_manifest"], digest: catalog.digest}
  end

  test "the committed manifest covers all 74 numbered steps with literal test owners", f do
    assert ExecutionManifest.validate(f.manifest) == :ok
    assert ExecutionManifest.verify_owners(f.manifest, @repository) == :ok
    assert length(ExecutionManifest.steps()) == 74
    keys = Map.keys(f.manifest["operator_step_evidence"])

    for step <- ExecutionManifest.steps() do
      assert Enum.any?(keys, &(&1 == step or String.starts_with?(&1, step <> "."))), step
    end

    for step <- ExecutionManifest.mandatory() do
      attended =
        for {key, %{"classification" => "attended", "owner" => "case:" <> id}} <-
              f.manifest["operator_step_evidence"],
            key == step or String.starts_with?(key, step <> "."),
            do: f.manifest["cases"][id]["lane"]

      assert attended != [] and Enum.all?(attended, &(&1 == "m7-operator")), step
    end
  end

  test "the pinned genesis digest is the plain SHA-256 of the canonical genesis record", f do
    campaign = f.manifest["campaign_id"]

    preimage =
      ~s({"body":{"campaign_id":"#{campaign}","codec_version":1,"kind":"genesis","version":1},) <>
        ~s("campaign_id":"#{campaign}","previous_digest":null,"sequence":1,"version":1})

    assert f.manifest["genesis_digest"] ==
             Base.encode16(:crypto.hash(:sha256, preimage), case: :lower)

    assert ExecutionManifest.validate(
             Map.put(f.manifest, "genesis_digest", String.duplicate("0", 64))
           ) ==
             {:error, :invalid_campaign_genesis}
  end

  test "missing, foreign and reclassified step keys refuse", f do
    evidence = f.manifest["operator_step_evidence"]
    drop = fn key -> Map.put(f.manifest, "operator_step_evidence", Map.delete(evidence, key)) end
    put = fn key, value -> put_in(f.manifest, ["operator_step_evidence", key], value) end

    assert {:error, {:invalid_operator_step_evidence, ["V9.5"]}} =
             ExecutionManifest.validate(drop.("V9.5"))

    for key <- ["V14.1", "V2.8", "V1.1.Bad", "v1.1"] do
      assert {:error, {:invalid_operator_step_evidence, _}} =
               ExecutionManifest.validate(
                 put.(key, %{"classification" => "automated", "owner" => "pending:x"})
               )
    end

    for value <- [
          %{"classification" => "automated", "owner" => "case:m7.repair"},
          %{"classification" => "retired", "owner" => "retired:anchor"},
          %{"classification" => "attended", "owner" => "pending:later"},
          %{"classification" => "attended", "owner" => "case:m7.pipe-answer"}
        ] do
      assert {:error, _} = ExecutionManifest.validate(put.("V2.1", value))
    end

    assert {:error, {:invalid_operator_step_evidence, _}} =
             ExecutionManifest.validate(
               put.("V2.1", %{
                 "classification" => "attended",
                 "owner" => "case:m7.repair",
                 "extra" => 1
               })
             )
  end

  test "case lanes, attendance and owned keys must agree exactly", f do
    cases = f.manifest["cases"]

    for changed <- [
          put_in(
            f.manifest,
            ["cases", "m7.repair", "steps"],
            List.delete(cases["m7.repair"]["steps"], "V2.5")
          ),
          put_in(f.manifest, ["cases", "m7.repair", "lane"], "m7-provider"),
          put_in(f.manifest, ["cases", "m7.repair", "attended"], false),
          put_in(f.manifest, ["cases", "m7.repair", "driver"], "anything"),
          put_in(f.manifest, ["cases", "m7.repair", "status"], "done"),
          put_in(
            f.manifest,
            ["lanes", "m7-operator"],
            List.delete(f.manifest["lanes"]["m7-operator"], "m7.repair")
          ),
          put_in(
            f.manifest,
            ["lanes", "m7-operator"],
            f.manifest["lanes"]["m7-operator"] ++ ["m7.repair"]
          ),
          Map.put(f.manifest, "status", "pending"),
          Map.put(f.manifest, "extra", true)
        ] do
      assert {:error, _} = ExecutionManifest.validate(changed)
    end
  end

  test "test owners must name a literal test in an application test file", f do
    for owner <- [
          "test:apps/loopex/test/configured_session_test.exs#no such test name",
          "test:apps/loopex/test/absent_test.exs#anything",
          "test:scripts/check.sh#anything"
        ] do
      changed = put_in(f.manifest, ["operator_step_evidence", "V3.5", "owner"], owner)
      assert ExecutionManifest.validate(changed) == :ok

      assert ExecutionManifest.verify_owners(changed, @repository) ==
               {:error, {:m7_test_owner_missing, ["V3.5"]}}
    end
  end

  test "lane selections pin each case's specification and refuse pending cases", f do
    assert {:error, {:m7_cases_pending, pending}} =
             ExecutionManifest.selection(
               f.manifest,
               f.digest,
               "m7-provider",
               String.duplicate("1", 40),
               nil
             )

    assert "m7.thinking-bound" in pending and "m7.pipe-answer" not in pending

    assert {:error, :unknown_m7_lane} =
             ExecutionManifest.selection(f.manifest, f.digest, "m7-x", "a", nil)

    ready =
      f.manifest
      |> put_in(["lanes", "m7-operator"], ["m7.repair", "m7.external"])
      |> put_in(["cases", "m7.repair", "status"], "ready")

    assert {:ok, selection} =
             ExecutionManifest.selection(
               ready,
               f.digest,
               "m7-operator",
               String.duplicate("1", 40),
               nil
             )

    assert Enum.map(selection["cases"], & &1["case_key"]) == ["m7.repair", "m7.external"]
    [repair, _] = selection["cases"]

    assert repair["specification_digest"] ==
             ExecutionManifest.specification_digest(ready, "m7.repair")

    changed = put_in(ready, ["cases", "m7.repair", "credential"], false)

    refute ExecutionManifest.specification_digest(changed, "m7.repair") ==
             repair["specification_digest"]

    assert %{owners: owners} = ExecutionManifest.pending(f.manifest)
    assert owners == ["V8.5", "V8.6"]
  end
end
