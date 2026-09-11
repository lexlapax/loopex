defmodule Loopex.ResourcePackTest do
  use ExUnit.Case, async: true

  alias Loopex.ResourcePack
  alias LoopexProtocol.Canonical

  @version "loopex.resource_pack/1"

  test "canonical order does not change manifest or pack identity" do
    alpha =
      pack("alpha", [
        %{file("SKILL.md") | content: "alpha", size: 5, digest: Canonical.digest_bytes("alpha")}
      ])

    beta = pack("beta", [file("notes.txt"), file("SKILL.md")])

    assert {:ok, first_digest, first} = ResourcePack.digest(manifest([beta, alpha]))
    assert {:ok, ^first_digest, second} = ResourcePack.digest(manifest([alpha, beta]))
    assert first == second
    assert Enum.map(first["packs"], & &1["name"]) == ["alpha", "beta"]
    assert Enum.map(hd(first["packs"])["files"], & &1["label"]) == ["SKILL.md"]

    [first_pack | _] = first["packs"]

    assert ResourcePack.pack_digest(first_pack) ==
             Canonical.digest(%{
               "encoding" => Canonical.version(),
               "kind" => "loopex.resource_pack/1",
               "value" => ResourcePack.metadata(first_pack)
             })

    assert first_digest ==
             Canonical.digest(%{
               "encoding" => Canonical.version(),
               "kind" => "loopex.resource_manifest/1",
               "value" => ResourcePack.metadata(first)
             })
  end

  test "every supporting byte participates in the whole manifest identity" do
    original = manifest([pack("alpha", [file("SKILL.md"), file("notes.txt", "one")])])
    changed = manifest([pack("alpha", [file("SKILL.md"), file("notes.txt", "two")])])

    assert {:ok, original_digest, original_normalized} = ResourcePack.digest(original)
    assert {:ok, changed_digest, changed_normalized} = ResourcePack.digest(changed)
    refute original_digest == changed_digest

    [original_pack] = original_normalized["packs"]
    [changed_pack] = changed_normalized["packs"]
    refute ResourcePack.pack_digest(original_pack) == ResourcePack.pack_digest(changed_pack)

    metadata = ResourcePack.metadata(original_normalized)
    refute inspect(metadata) =~ "support"
    assert get_in(metadata, ["packs", Access.at(0), "files", Access.at(1), "digest"])
  end

  test "atom and string aliases normalize once while duplicates and extra members refuse" do
    string_manifest =
      manifest([pack("alpha", [file("SKILL.md")])])
      |> stringify_map()

    assert {:ok, digest, normalized} = ResourcePack.digest(string_manifest)

    assert {:ok, ^digest, ^normalized} =
             ResourcePack.digest(manifest([pack("alpha", [file("SKILL.md")])]))

    duplicate_alias = Map.put(string_manifest, :version, @version)

    assert {:error, :manifest_rejected, %{"reason" => "invalid_member_set"}} =
             ResourcePack.digest(duplicate_alias)

    assert {:error, :manifest_rejected, %{"reason" => "invalid_member_set"}} =
             ResourcePack.digest(Map.put(string_manifest, "path", "/tmp/skill"))
  end

  test "containment duplicate identities labels and normalized paths fail closed" do
    uncontained =
      manifest([pack("alpha", [%{file("SKILL.md") | contained: false}])])

    assert {:error, :manifest_rejected, %{"reason" => "invalid_file"}} =
             ResourcePack.digest(uncontained)

    duplicate_identity =
      manifest([pack("alpha", [file("SKILL.md")]), pack("alpha", [file("SKILL.md")])])

    assert {:error, :manifest_rejected, %{"reason" => "duplicate_pack_identity"}} =
             ResourcePack.digest(duplicate_identity)

    duplicate_label =
      manifest([pack("alpha", [file("SKILL.md"), file("notes.txt"), file("notes.txt")])])

    assert {:error, :manifest_rejected, %{"reason" => "duplicate_file_label"}} =
             ResourcePack.digest(duplicate_label)

    path_collision =
      manifest([pack("alpha", [file("SKILL.md"), file("Docs/Guide.md"), file("docs/guide.md")])])

    assert {:error, :manifest_rejected, %{"reason" => "normalized_path_collision"}} =
             ResourcePack.digest(path_collision)

    Enum.each(["/absolute", "a/../escape", "a\\windows"], fn hostile ->
      assert {:error, :manifest_rejected, %{"reason" => "invalid_file"}} =
               ResourcePack.digest(manifest([pack("alpha", [file("SKILL.md"), file(hostile)])]))
    end)
  end

  test "remote Git provenance uses one matching native object format" do
    sha1 = String.duplicate("a", 40)
    sha256 = String.duplicate("b", 64)

    Enum.each([{sha1, sha1}, {sha256, sha256}], fn {commit, tree} ->
      remote =
        pack("remote", [file("SKILL.md")])
        |> Map.merge(%{
          origin: "https://example.invalid/repo.git",
          commit: commit,
          tree_digest: tree
        })

      assert {:ok, _digest, _normalized} = ResourcePack.digest(manifest([remote]))
    end)

    Enum.each(
      [
        %{origin: "https://user:secret@example.invalid/repo", commit: sha1, tree_digest: sha1},
        %{origin: "https://example.invalid/repo?token=secret", commit: sha1, tree_digest: sha1},
        %{origin: "https://example.invalid/repo", commit: String.upcase(sha1), tree_digest: sha1},
        %{origin: "https://example.invalid/repo", commit: sha1, tree_digest: sha256},
        %{origin: nil, commit: sha1, tree_digest: sha1}
      ],
      fn provenance ->
        remote = Map.merge(pack("remote", [file("SKILL.md")]), provenance)

        assert {:error, :manifest_rejected, %{"reason" => "invalid_pack"}} =
                 ResourcePack.digest(manifest([remote]))
      end
    )
  end

  test "list shells text bodies metadata and counts are bounded before canonical work" do
    too_many_packs = List.duplicate(pack("alpha", [file("SKILL.md")]), 65)

    assert {:error, :over_limit, %{"dimension" => "packs", "observed" => 65, "limit" => 64}} =
             ResourcePack.digest(manifest(too_many_packs))

    improper = %{manifest([]) | packs: [pack("alpha", [file("SKILL.md")]) | :hostile_tail]}

    assert {:error, :manifest_rejected, %{"reason" => "invalid_list"}} =
             ResourcePack.digest(improper)

    oversized_instruction = String.duplicate("x", 65_537)

    assert {:error, :over_limit,
            %{"dimension" => "instruction_bytes", "observed" => 65_537, "limit" => 65_536}} =
             ResourcePack.digest(
               manifest([pack("alpha", [file("SKILL.md", oversized_instruction)])])
             )

    invalid_text = %{manifest([]) | workspace_ref: <<255>>}

    assert {:error, :manifest_rejected, %{"reason" => "invalid_manifest"}} =
             ResourcePack.digest(invalid_text)

    hostile = String.duplicate("z", 70_000)
    bad_digest = manifest([pack("alpha", [%{file("SKILL.md") | digest: hostile}])])
    result = ResourcePack.digest(bad_digest)
    assert {:error, :manifest_rejected, %{"reason" => "invalid_file"}} = result
    refute inspect(result) =~ hostile
  end

  test "supporting text is limited to 64 KiB while a binary asset may use the pack budget" do
    oversized_text = String.duplicate("t", 65_537)

    assert {:error, :over_limit,
            %{
              "dimension" => "text_resource_bytes",
              "observed" => 65_537,
              "limit" => 65_536
            }} =
             ResourcePack.digest(
               manifest([pack("alpha", [file("SKILL.md"), file("guide.txt", oversized_text)])])
             )

    binary_asset = :binary.copy(<<255>>, 65_537)

    assert {:ok, _digest, normalized} =
             ResourcePack.digest(
               manifest([pack("alpha", [file("SKILL.md"), file("asset.bin", binary_asset)])])
             )

    assert get_in(normalized, ["packs", Access.at(0), "files", Access.at(1), "content"]) ==
             binary_asset
  end

  test "decisions have an exact bounded non-expiring active or revoked shape" do
    {:ok, manifest_digest, normalized} =
      ResourcePack.digest(manifest([pack("alpha", [file("SKILL.md")])]))

    active = decision(manifest_digest)
    assert {:ok, normalized_decision} = ResourcePack.normalize_decision(active)

    assert Enum.sort(Map.keys(normalized_decision)) ==
             ~w(decision_source expires_at issued_at manifest_digest revocation_state trust_scope workspace_ref)

    assert {:ok, %{"revocation_state" => "revoked"}} =
             active |> Map.put(:revocation_state, "revoked") |> ResourcePack.normalize_decision()

    duplicate = active |> Map.put("manifest_digest", manifest_digest)
    assert {:error, :invalid_decision} = ResourcePack.normalize_decision(duplicate)

    Enum.each(
      [
        Map.put(active, :issued_at, "not-an-instant"),
        Map.put(active, :expires_at, "2027-01-01T00:00:00Z"),
        Map.put(active, :revocation_state, "pending"),
        Map.put(active, :trust_scope, "project_resource"),
        Map.put(active, :workspace_ref, String.duplicate("w", 1_025)),
        Map.put(active, :extra, "no")
      ],
      fn invalid ->
        assert {:error, :invalid_decision} = ResourcePack.normalize_decision(invalid)
      end
    )

    assert normalized["workspace_ref"] == normalized_decision["workspace_ref"]
  end

  test "catalog entries have the exact public shape and never carry content" do
    given = manifest([pack("alpha", [file("SKILL.md", "private instructions")])])
    {:ok, manifest_digest, normalized} = ResourcePack.digest(given)

    assert {:declined, :no_decision,
            %{
              "manifest_digest" => ^manifest_digest,
              "decision_disposition" => "no_decision",
              "reason" => nil
            }} = ResourcePack.catalog(given, nil)

    assert {:staged, [entry], receipt} =
             ResourcePack.catalog(given, decision(manifest_digest))

    assert Map.keys(entry) |> Enum.sort() ==
             ~w(description manual_only name pack_digest pack_index source_id)

    assert entry["pack_index"] == 0
    assert entry["source_id"] == "project"
    assert entry["pack_digest"] == ResourcePack.pack_digest(hd(normalized["packs"]))
    assert receipt["decision_disposition"] == "active"
    refute inspect({entry, receipt}) =~ "private instructions"

    revoked = decision(manifest_digest) |> Map.put(:revocation_state, "revoked")

    assert {:declined, :revoked, %{"decision_disposition" => "revoked"}} =
             ResourcePack.catalog(given, revoked)

    stale = decision(String.duplicate("0", 64))
    assert {:declined, :binding_changed, bounded} = ResourcePack.catalog(given, stale)
    assert bounded["reason"] == "decision_binding_mismatch"
    refute Map.has_key?(bounded, "decision")
  end

  test "pure catalog metadata is not refused at the model-visible block limit" do
    packs =
      for index <- 1..64 do
        pack("skill-#{index}", [file("SKILL.md")])
        |> Map.put(:description, String.duplicate("d", 300))
      end

    given = manifest(packs)
    {:ok, manifest_digest, _normalized} = ResourcePack.digest(given)

    assert {:staged, entries, %{"decision_disposition" => "active"}} =
             ResourcePack.catalog(given, decision(manifest_digest))

    assert length(entries) == 64
    assert byte_size(Canonical.encode(entries)) > 16 * 1_024
  end

  defp manifest(packs) do
    %{
      version: "loopex.resource_pack/1",
      workspace_ref: "workspace-1",
      revision: nil,
      packs: packs
    }
  end

  defp pack(name, files) do
    %{
      source_id: "project",
      origin: nil,
      commit: nil,
      tree_digest: nil,
      name: name,
      description: "#{name} skill",
      manual_only: false,
      files: files
    }
  end

  defp file(label, content \\ "support") do
    %{
      label: label,
      size: byte_size(content),
      digest: Canonical.digest_bytes(content),
      content: content,
      contained: true
    }
  end

  defp decision(manifest_digest) do
    %{
      manifest_digest: manifest_digest,
      workspace_ref: "workspace-1",
      trust_scope: "project_skills",
      decision_source: "interactive_operator",
      issued_at: "2026-09-10T12:34:56Z",
      expires_at: nil,
      revocation_state: "active"
    }
  end

  defp stringify_map(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), stringify_map(value)} end)
  end

  defp stringify_map(list) when is_list(list), do: Enum.map(list, &stringify_map/1)
  defp stringify_map(value), do: value
end
