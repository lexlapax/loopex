defmodule LoopexCli.ConfigFileTest do
  use ExUnit.Case, async: true
  alias LoopexCli.ConfigFile

  setup do
    root =
      Path.join(System.tmp_dir!(), "loopex-config-file-#{System.unique_integer([:positive])}")

    directory = Path.join(root, "config")
    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root, directory: directory, config_file: Path.join(directory, "profile.json")}
  end

  test "all relative paths resolve against the selected file, retaining authored values",
       fixture do
    profile = profile()
    write(fixture.config_file, profile)
    assert {:ok, loaded} = ConfigFile.load("config/profile.json", fixture.root)
    assert loaded.file == fixture.config_file
    assert loaded.authored == profile

    for {keys, authored} <- [
          {["paths", "workspace"], "workspace"},
          {["paths", "state_root"], "$HOME/state"},
          {["session", "instructions", "system_file"], "~/base.txt"},
          {["session", "instructions", "append_file"], "append.txt"},
          {["roles", "builder", "instructions_file"], "role.txt"}
        ] do
      assert get_in(loaded.resolved, keys) == Path.join(fixture.directory, authored)
    end

    assert loaded.resolved["session"]["skill_dirs"] ==
             [Path.join(fixture.directory, "skills"), "/absolute/skills"]

    refute File.exists?(Path.join(fixture.directory, "workspace"))
    refute File.exists?(Path.join(fixture.directory, "$HOME/state"))
  end

  test "absolute values remain absolute and parent components are not expanded lexically",
       fixture do
    profile = put_in(profile(), ["paths", "workspace"], "/fixed/workspace")
    profile = put_in(profile, ["session", "instructions", "system_file"], "link/../base.txt")
    write(fixture.config_file, profile)
    assert {:ok, loaded} = ConfigFile.load(fixture.config_file, fixture.root)
    assert loaded.resolved["paths"]["workspace"] == "/fixed/workspace"

    assert loaded.resolved["session"]["instructions"]["system_file"] ==
             fixture.directory <> "/link/../base.txt"
  end

  test "regular bounded config selection does not open prompt files", fixture do
    write(fixture.config_file, profile())
    assert {:ok, _} = ConfigFile.load(fixture.config_file, fixture.root)
    refute File.exists?(Path.join(fixture.directory, "append.txt"))

    for file <- [fixture.directory, Path.join(fixture.directory, "absent.json")] do
      assert ConfigFile.load(file, fixture.root) ==
               {:error, {:configuration_file_unusable, "/config"}}
    end

    File.write!(fixture.config_file, String.duplicate("x", 262_145))

    assert ConfigFile.load(fixture.config_file, fixture.root) ==
             {:error, {:configuration_too_large, ""}}
  end

  test "JSON and authored schema refusals happen before relative resolution", fixture do
    File.write!(fixture.config_file, ~s({"schema_version":1,"schema_version":2}))

    assert ConfigFile.load(fixture.config_file, fixture.root) ==
             {:error, {:duplicate_member, "/schema_version"}}

    write(fixture.config_file, put_in(profile(), ["session", "bounds", "deadline_ms"], 0))

    assert ConfigFile.load(fixture.config_file, fixture.root) ==
             {:error, {:invalid_value, "/session/bounds/deadline_ms"}}

    write(fixture.config_file, Map.delete(profile(), "policy"))

    assert ConfigFile.load(fixture.config_file, fixture.root) ==
             {:error, {:missing_member, "/policy"}}
  end

  test "resolved paths must also fit the path byte ceiling", fixture do
    write(
      fixture.config_file,
      put_in(profile(), ["paths", "workspace"], String.duplicate("x", 4_096))
    )

    assert ConfigFile.load(fixture.config_file, fixture.root) ==
             {:error, {:invalid_configuration_path, "/paths/workspace"}}

    write(
      fixture.config_file,
      put_in(profile(), ["session", "skill_dirs"], [String.duplicate("x", 4_096)])
    )

    assert ConfigFile.load(fixture.config_file, fixture.root) ==
             {:error, {:invalid_configuration_path, "/session/skill_dirs/0"}}
  end

  test "file selection and invocation directory errors never echo values", fixture do
    for file <- [nil, "", <<255>>, "/" <> <<0>>, String.duplicate("x", 4_097)] do
      assert ConfigFile.load(file, fixture.root) ==
               {:error, {:invalid_configuration_path, "/config"}}
    end

    for directory <- [nil, "relative", "", <<255>>, "/" <> <<0>>] do
      assert ConfigFile.load(fixture.config_file, directory) ==
               {:error, {:invalid_configuration_path, "/invocation_directory"}}
    end
  end

  defp write(file, profile) do
    {:ok, json} = LoopexProtocol.Frame.encode(profile)
    File.write!(file, json)
  end

  defp profile do
    %{
      "schema_version" => 1,
      "providers" => %{"openai" => %{"credential" => %{"env" => "M7_CONFIG_FILE_KEY"}}},
      "policy" => "allow-all",
      "paths" => %{"workspace" => "workspace", "state_root" => "$HOME/state"},
      "session" => %{
        "model" => "openai:fixture",
        "bounds" => %{"max_turns" => 8, "deadline_ms" => 1_000, "token_budget" => 10_000},
        "instructions" => %{"system_file" => "~/base.txt", "append_file" => "append.txt"},
        "skill_dirs" => ["skills", "/absolute/skills"]
      },
      "roles" => %{"builder" => %{"model" => "openai:fixture", "instructions_file" => "role.txt"}}
    }
  end
end
