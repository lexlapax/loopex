defmodule LoopexCli.ConfigSelectionTest do
  use ExUnit.Case, async: true
  alias LoopexCli.{ConfigFile, ConfigOptions, ConfigSelection}

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "loopex-config-selection-#{System.unique_integer([:positive])}"
      )

    config_dir = Path.join(root, "configuration")
    invocation = Path.join(root, "invocation")
    File.mkdir_p!(config_dir)
    File.mkdir_p!(invocation)
    on_exit(fn -> File.rm_rf!(root) end)

    %{
      root: root,
      config_dir: config_dir,
      invocation: invocation,
      config_path: Path.join(config_dir, "profile.json")
    }
  end

  test "an always-on conversation uses only its explicitly selected thinking-off summarizer",
       fixture do
    profile =
      Map.put(profile(), "providers", %{
        "openai" => env("OLD_SLOT"),
        "anthropic" => env("ANTHROPIC_SLOT")
      })

    loaded = load(fixture, profile)
    flags = parse(fixture, ["--model=anthropic:claude-fable-5-1", "--tools=none"])
    assert {:ok, selection} = ConfigSelection.compose(loaded, flags, fixture.invocation, nil)
    instructions = Loopex.Runtime.Instructions.legacy()
    assert {:ok, unconfigured} = ConfigSelection.resolve_session(selection, instructions, [])
    assert unconfigured.configuration["provider_mapping"]["continuation_required"]
    assert unconfigured.maintenance_model == nil

    flags =
      parse(fixture, [
        "--model=anthropic:claude-fable-5-1",
        "--tools=none",
        "--compaction-model=anthropic:claude-haiku-4-5"
      ])

    assert {:ok, selection} = ConfigSelection.compose(loaded, flags, fixture.invocation, nil)
    assert {:ok, prepared} = ConfigSelection.resolve_session(selection, instructions, [])
    assert prepared.configuration == unconfigured.configuration
    assert prepared.maintenance_model["model"] == "anthropic:claude-haiku-4-5-20251001"
    assert prepared.maintenance_model["reasoning"] == "none"
    assert prepared.origins["/maintenance/model"] == "flag"
  end

  test "session preparation joins file and flag selection with one captured instruction block",
       fixture do
    profile =
      Map.put(profile(), "providers", %{
        "openai" => env("OLD_HOST_SLOT"),
        "anthropic" => env("UNRESOLVED_HOST_SLOT")
      })

    base = Path.join(fixture.config_dir, "base.txt")
    File.write!(base, "Captured base 猫\n")
    profile = put_in(profile, ["session", "instructions"], %{"system_file" => "base.txt"})
    loaded = load(fixture, profile)

    flags =
      parse(fixture, [
        "--model=anthropic:claude-haiku-4-5",
        "--reasoning=high",
        "--max-tokens=8192",
        "--tools=none"
      ])

    assert {:ok, selected} = ConfigSelection.compose(loaded, flags, fixture.invocation, nil)

    assert {:ok, instructions} =
             LoopexCli.SessionInstructions.capture(
               selected.profile["paths"]["workspace"],
               "none",
               selected.profile["session"]["instructions"]
             )

    File.write!(base, "Changed after capture")
    assert {:ok, prepared} = ConfigSelection.resolve_session(selected, instructions, [])
    assert prepared.configuration["instructions"] == instructions
    assert prepared.configuration["instructions"]["base"] == "Captured base 猫\n"
    assert prepared.configuration["model"] == "anthropic:claude-haiku-4-5-20251001"
    assert prepared.configuration["context_token_budget"] == 191_808

    assert prepared.configuration["provider_mapping"]["thinking"] == %{
             "mode" => "manual",
             "budget_tokens" => 4096
           }

    assert prepared.origins["/session/model"] == "flag"
    assert prepared.origins["/session/context_token_budget"] == "default"

    assert prepared.origins["/session/instructions/system_file"] ==
             "file#/session/instructions/system_file"

    refute :erlang.term_to_binary(prepared.configuration) =~ "UNRESOLVED_HOST_SLOT"
    refute File.exists?(prepared.profile["paths"]["state_root"])
  end

  test "session preparation preserves explicit budget origins and refuses an unbound override",
       fixture do
    loaded = load(fixture, profile())

    flags =
      parse(fixture, ["--context-token-budget=9000", "--system-class-tokens=900", "--tools=none"])

    assert {:ok, selected} = ConfigSelection.compose(loaded, flags, fixture.invocation, nil)
    instructions = Loopex.Runtime.Instructions.legacy()
    assert {:ok, prepared} = ConfigSelection.resolve_session(selected, instructions, [])
    assert prepared.configuration["context_token_budget"] == 9000
    assert prepared.configuration["system_class_tokens"] == 900
    assert prepared.origins["/session/context_token_budget"] == "flag"
    assert prepared.origins["/session/system_class_tokens"] == "flag"
    assert prepared.configuration["budget_origins"]["context_token_budget"] == "explicit"

    assert {:error, {:missing_provider_binding, "/session/model"}} =
             ConfigSelection.compose(
               loaded,
               parse(fixture, ["--model=anthropic:claude-haiku-4-5"]),
               fixture.invocation,
               nil
             )
  end

  test "file selection retains precise origins while literal defaults stay distinct", fixture do
    loaded = load(fixture, profile())
    parsed = parse(fixture, [])
    assert {:ok, selected} = ConfigSelection.compose(loaded, parsed, fixture.invocation, nil)
    assert selected.profile["session"]["max_tokens"] == 4_096
    assert selected.profile["session"]["reasoning"] == "default"
    assert selected.profile["session"]["tools"] == "coding"
    assert selected.profile["output"] == "text"
    assert selected.origins["/session/max_tokens"] == "default"
    assert selected.origins["/session/model"] == "file#/session/model"
    assert selected.origins["/session/bounds/token_budget"] == "file#/session/bounds/token_budget"

    assert selected.origins["/providers/openai/credential/env"] ==
             "file#/providers/openai/credential/env"

    assert selected.profile["paths"]["workspace"] == Path.join(fixture.config_dir, "workspace")
    assert selected.origins["/paths/workspace"] == "file#/paths/workspace"
    refute Map.has_key?(selected.profile, "maintenance")
    refute Map.has_key?(selected.profile["session"], "context_token_budget")
    refute Enum.any?(selected.origins, fn {_, origin} -> origin == "committed" end)
  end

  test "flag wins environment wins file for state root, without another alias", fixture do
    loaded = load(fixture, profile())

    assert {:ok, file} =
             ConfigSelection.compose(loaded, parse(fixture, []), fixture.invocation, nil)

    assert file.profile["paths"]["state_root"] == Path.join(fixture.config_dir, "state")
    assert file.origins["/paths/state_root"] == "file#/paths/state_root"

    assert {:ok, env} =
             ConfigSelection.compose(loaded, parse(fixture, []), fixture.invocation, "env-state")

    assert env.profile["paths"]["state_root"] == Path.join(fixture.invocation, "env-state")
    assert env.origins["/paths/state_root"] == "env"

    assert {:ok, flag} =
             ConfigSelection.compose(
               loaded,
               parse(fixture, ["--state-root=flag-state"]),
               fixture.invocation,
               "env-state"
             )

    assert flag.profile["paths"]["state_root"] == Path.join(fixture.invocation, "flag-state")
    assert flag.origins["/paths/state_root"] == "flag"
    assert flag.profile["session"]["model"] == "openai:fixture"
  end

  test "flag path selections use invocation cwd and preserve literal substitution syntax",
       fixture do
    loaded = load(fixture, profile())

    parsed =
      parse(fixture, [
        "--workspace=~/work",
        "--system-prompt-file=$HOME/base.txt",
        "--append-system-prompt-file=link/../append.txt"
      ])

    assert {:ok, selected} = ConfigSelection.compose(loaded, parsed, fixture.invocation, nil)
    assert selected.profile["paths"]["workspace"] == fixture.invocation <> "/~/work"

    assert selected.profile["session"]["instructions"]["system_file"] ==
             fixture.invocation <> "/$HOME/base.txt"

    assert selected.profile["session"]["instructions"]["append_file"] ==
             fixture.invocation <> "/link/../append.txt"

    assert selected.origins["/session/instructions/system_file"] == "flag"
    refute File.exists?(fixture.invocation <> "/~/work")
  end

  test "array overrides replace file arrays and remove obsolete indexed origins", fixture do
    profile =
      profile()
      |> put_in(["session", "skill_dirs"], ["file-one", "file-two", "file-three"])
      |> Map.put("trace", %{"modules" => ["Loopex.*", "LoopexProtocol.*"]})

    loaded = load(fixture, profile)

    parsed =
      parse(fixture, [
        "--skill-dir=flag-two",
        "--skill-dir=flag-one",
        "--trace-module=Loopex.Runtime"
      ])

    assert {:ok, selected} = ConfigSelection.compose(loaded, parsed, fixture.invocation, nil)

    assert selected.profile["session"]["skill_dirs"] == [
             fixture.invocation <> "/flag-two",
             fixture.invocation <> "/flag-one"
           ]

    assert selected.origins["/session/skill_dirs"] == "flag"
    assert selected.origins["/session/skill_dirs/0"] == "flag"
    refute Map.has_key?(selected.origins, "/session/skill_dirs/2")
    assert selected.profile["trace"]["modules"] == ["Loopex.Runtime"]
    refute Map.has_key?(selected.origins, "/trace/modules/1")
  end

  test "all scalar selections replace only their declared fields", fixture do
    profile =
      Map.put(profile(), "providers", %{
        "openai" => env("OPENAI_SLOT"),
        "anthropic" => env("ANTHROPIC_SLOT")
      })

    loaded = load(fixture, profile)

    parsed =
      parse(fixture, [
        "--model=anthropic:other",
        "--reasoning=low",
        "--compaction-model=openai:summary",
        "--max-steps=12",
        "--deadline-ms=999",
        "--token-budget=888",
        "--max-tokens=2222",
        "--context-token-budget=7777",
        "--system-class-tokens=999",
        "--cleanup-grace-ms=100",
        "--tools=read-only",
        "--policy=refuse-all",
        "--output=text",
        "--trace",
        "--trace-level=returns",
        "--trace-max-entry-bytes=100",
        "--trace-max-entries-per-second=2",
        "--trace-max-queue-entries=3"
      ])

    assert {:ok, selected} = ConfigSelection.compose(loaded, parsed, fixture.invocation, nil)
    assert selected.profile["session"]["model"] == "anthropic:other"
    assert selected.profile["maintenance"]["model"] == "openai:summary"

    assert selected.profile["session"]["bounds"] == %{
             "max_turns" => 12,
             "deadline_ms" => 999,
             "token_budget" => 888
           }

    assert selected.profile["session"]["max_tokens"] == 2222
    assert selected.profile["session"]["context_token_budget"] == 7777
    assert selected.profile["session"]["system_class_tokens"] == 999
    assert selected.profile["session"]["cleanup_grace_ms"] == 100

    assert selected.profile["trace"] == %{
             "enabled" => true,
             "level" => "returns",
             "modules" => ["Loopex.*", "LoopexProtocol.*"],
             "max_entry_bytes" => 100,
             "max_entries_per_second" => 2,
             "max_queue_entries" => 3
           }

    assert selected.origins["/maintenance/model"] == "flag"
    assert selected.origins["/trace/modules"] == "default"
    assert selected.origins["/trace/enabled"] == "flag"
    assert loaded.authored == profile
  end

  test "invalid authored values cannot be repaired by overrides", fixture do
    loaded = load(fixture, profile())
    bad = %{loaded | authored: put_in(loaded.authored, ["session", "bounds", "deadline_ms"], 0)}
    parsed = parse(fixture, ["--deadline-ms=100"])

    assert ConfigSelection.compose(bad, parsed, fixture.invocation, nil) ==
             {:error, {:invalid_value, "/session/bounds/deadline_ms"}}

    bad = %{loaded | authored: put_in(loaded.authored, ["session", "context_token_budget"], 999)}

    assert ConfigSelection.compose(
             bad,
             parse(fixture, ["--system-class-tokens=500"]),
             fixture.invocation,
             nil
           ) == {:error, {:system_ceiling_exceeds_context, "/session/system_class_tokens"}}
  end

  test "merged relationship conflicts refuse without changing captured file choices", fixture do
    loaded = load(fixture, profile())

    assert ConfigSelection.compose(
             loaded,
             parse(fixture, ["--model=anthropic:other"]),
             fixture.invocation,
             nil
           ) == {:error, {:missing_provider_binding, "/session/model"}}

    assert ConfigSelection.compose(
             loaded,
             parse(fixture, ["--context-token-budget=999"]),
             fixture.invocation,
             nil
           ) == {:error, {:system_ceiling_exceeds_context, "/session/system_class_tokens"}}

    assert loaded.authored["session"]["model"] == "openai:fixture"
  end

  test "no-helpers narrows an admitted declaration without changing role or allowance data",
       fixture do
    declaration = %{
      "enabled" => true,
      "roles" => ["builder"],
      "max_children" => 2,
      "token_budget" => 2000,
      "child_bounds" => %{"max_turns" => 4, "deadline_ms" => 1000, "token_budget" => 2000}
    }

    profile =
      profile()
      |> Map.put("roles", %{
        "builder" => %{"model" => "openai:child", "instructions_file" => "role.txt"}
      })
      |> Map.put("delegation", declaration)

    loaded = load(fixture, profile)

    assert {:ok, selected} =
             ConfigSelection.compose(
               loaded,
               parse(fixture, ["--no-helpers", "--tools=none"]),
               fixture.invocation,
               nil
             )

    assert selected.profile["delegation"]["enabled"] == false

    assert Map.take(
             selected.profile["delegation"],
             ~w(roles max_children token_budget child_bounds)
           ) == Map.take(declaration, ~w(roles max_children token_budget child_bounds))

    assert selected.profile["roles"]["builder"]["model"] == "openai:child"
    assert selected.origins["/delegation/enabled"] == "flag"
    assert selected.origins["/delegation/token_budget"] == "file#/delegation/token_budget"
    assert selected.origins["/roles/builder/reasoning"] == "default"
  end

  test "invalid state-root environment refuses unless a flag supersedes it", fixture do
    loaded = load(fixture, profile())

    for home <- ["", <<255>>, "/" <> <<0>>, String.duplicate("x", 4097)] do
      assert ConfigSelection.compose(loaded, parse(fixture, []), fixture.invocation, home) ==
               {:error, {:invalid_configuration_path, "/env/LOOPEX_HOME"}}

      assert {:ok, _} =
               ConfigSelection.compose(
                 loaded,
                 parse(fixture, ["--state-root=selected"]),
                 fixture.invocation,
                 home
               )
    end
  end

  test "inspection composition starts no app and creates no path", fixture do
    loaded = load(fixture, profile())

    assert {:ok, parsed} =
             ConfigOptions.parse([
               "config",
               "show",
               "--config=" <> fixture.config_path,
               "--effective"
             ])

    before_apps = Application.started_applications() |> Enum.map(&elem(&1, 0)) |> Enum.sort()
    assert {:ok, _} = ConfigSelection.compose(loaded, parsed, fixture.invocation, nil)

    assert Application.started_applications() |> Enum.map(&elem(&1, 0)) |> Enum.sort() ==
             before_apps

    refute File.exists?(Path.join(fixture.config_dir, "workspace"))
    refute File.exists?(Path.join(fixture.config_dir, "state"))
  end

  test "resume cannot accidentally substitute a new-session profile", fixture do
    loaded = load(fixture, profile())
    parsed = parse(fixture, ["--resume=existing", "--model=openai:new"])

    assert ConfigSelection.compose(loaded, parsed, fixture.invocation, nil) ==
             {:error, {:committed_profile_required, "/flags/resume"}}
  end

  defp load(fixture, profile) do
    {:ok, encoded} = LoopexProtocol.Frame.encode(profile)
    File.write!(fixture.config_path, encoded)
    {:ok, loaded} = ConfigFile.load(fixture.config_path, fixture.invocation)
    loaded
  end

  defp parse(fixture, overrides) do
    {:ok, parsed} = ConfigOptions.parse(["chat", "--config=" <> fixture.config_path] ++ overrides)
    parsed
  end

  defp env(name), do: %{"credential" => %{"env" => name}}

  defp profile do
    %{
      "schema_version" => 1,
      "providers" => %{"openai" => env("M7_SELECTION_SLOT")},
      "policy" => "allow-all",
      "paths" => %{"workspace" => "workspace", "state_root" => "state"},
      "session" => %{
        "model" => "openai:fixture",
        "bounds" => %{"max_turns" => 8, "deadline_ms" => 1000, "token_budget" => 10000}
      }
    }
  end
end
