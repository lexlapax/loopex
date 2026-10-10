defmodule LoopexCli.M7ProfilesTest do
  use ExUnit.Case, async: false

  # Concept: every reference profile an M7 case stages is declared in the
  # committed manifest, and its system class stays below the profile's ceiling
  # at the case's real workspace and at a 512-byte workspace path.
  # Technical depth: `Profiles.measure/4` builds each case's genesis through
  # its own composition path; the preimage digests (instruction version, base,
  # appendix and tool generations, without per-attempt environment) are pinned
  # here, so a changed description or schema needs a deliberate repin. The
  # plan's target is below 1,000; the maintainer's recorded override admits
  # 1,500 for the two question-enabled coding chats and 2,000 for the helper
  # parent. No credential is read and no provider is called.

  alias Mix.Tasks.Loopex.M7Evidence.{FixtureManifest, Profiles}

  @fixtures Path.expand("../../../test/fixtures/m7", __DIR__)
  @workspace_bytes 512

  @pinned %{
    "chat-coding" =>
      {1_500, ["8b691d14f3d074349f782037d0cfa9576892b8563b41a335642bf6eb7d9656c6"]},
    "chat-coding-appendix" =>
      {1_500,
       [
         "8e8b7d9e3e980e5393e757294a5c1ba659aaed46c08e2d2df71b82dc07084e65",
         "aec13e0034a4fd0dadda10c8037a99d29d9e137e5de6ae62ac215ac014642fe5"
       ]},
    "chat-coding-helpers" =>
      {2_000, ["6e4be2450e74c4b74fd27d484117201f2bd8c0c08d7247d440905a522686ce1e"]},
    "chat-read-only" =>
      {1_000, ["3e31a652f4915828f1b7953818b65a16f7a8bfcad10d22c3923d83fc61beff8f"]},
    "daemon-coding" =>
      {1_000, ["06ff722b14a5084b1aaa7ee467ddb4a15dbdd3b3b919fc385f2fba38db0dc3b5"]},
    "ask-coding" => {1_000, ["06ff722b14a5084b1aaa7ee467ddb4a15dbdd3b3b919fc385f2fba38db0dc3b5"]},
    "ask-read-only" =>
      {1_000, ["48f116bc20607c3c794f98ecdbe378fcc84e9545cfd65f5f9b2074f13808bb02"]},
    "ephemeral-question" =>
      {1_000, ["b2c67a0244ac201cc9d272a9d555b7f91692959d6fd23d87614ba468220bfc0e"]},
    "helper-investigate" =>
      {1_000, ["5fb824f7d2a96c78c00561a327c83d82b819d09ed0cfed2228954c3e67823643"]},
    "helper-review" =>
      {1_000, ["60a2011b68faa7767fabbfe03d994fe07d04ab5bd639004ab6f50102b68571a1"]}
  }

  # The operator's explicit configuration, as the M7 validation runbook asks.
  @config %{
    "schema_version" => 1,
    "providers" => %{"anthropic" => %{"credential" => %{"env" => "LOOPEX_PROVIDER_API_KEY"}}},
    "policy" => "allow-all",
    "paths" => %{"workspace" => "workspace", "state_root" => "state"},
    "session" => %{
      "model" => "anthropic:claude-haiku-4-5-20251001",
      "max_tokens" => 4096,
      "bounds" => %{"max_turns" => 40, "deadline_ms" => 600_000, "token_budget" => 2_000_000}
    }
  }

  setup do
    {:ok, catalog} = FixtureManifest.load(@fixtures)
    base = Path.join(System.tmp_dir!(), "m7-profiles-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(base) end)
    %{catalog: catalog.catalog, base: base}
  end

  test "the manifest declares exactly the pinned profile keys and ceilings", f do
    declared =
      Map.new(f.catalog["execution_manifest"]["profiles"], fn {key, entry} ->
        {key, entry["system_class_tokens"]}
      end)

    assert declared == Map.new(@pinned, fn {key, {ceiling, _}} -> {key, ceiling} end)
  end

  test "each case stages exactly its profiles below their ceilings at real and 512-byte paths",
       f do
    context = %{manifest: f.catalog}

    for {case_id, entry} <- f.catalog["execution_manifest"]["cases"],
        root <- [
          Path.join(f.base, "real-" <> case_id),
          long_root(Path.join(f.base, "long-" <> case_id))
        ] do
      assert {:ok, measurements} = Profiles.measure(case_id, root, context, @config), case_id

      matched =
        for measurement <- measurements, uniq: true do
          keys =
            for key <- entry["profiles"],
                measurement["preimage_digest"] in elem(@pinned[key], 1),
                do: key

          assert keys != [], "#{case_id} #{measurement["scope"]} is not a declared profile"

          for key <- keys,
              do:
                assert(
                  measurement["estimate"] < elem(@pinned[key], 0),
                  "#{case_id} #{key} #{measurement["estimate"]}"
                )

          keys
        end

      assert Enum.sort(Enum.uniq(List.flatten(matched))) == Enum.sort(entry["profiles"]),
             case_id

      if String.starts_with?(root, Path.join(f.base, "long-")) and measurements != [] do
        assert Enum.all?(measurements, &(byte_size(&1["workspace"]) == @workspace_bytes))
      end
    end
  end

  # A root whose workspace path is exactly 512 bytes, in components a file
  # system accepts.
  defp long_root(prefix), do: extend(prefix, @workspace_bytes - byte_size("/workspace"))

  defp extend(path, target) when byte_size(path) >= target, do: path

  defp extend(path, target) do
    last = target - byte_size(path) - 1

    length =
      cond do
        last <= 100 -> last
        last <= 102 -> 50
        true -> 100
      end

    extend(Path.join(path, String.duplicate("d", length)), target)
  end
end
