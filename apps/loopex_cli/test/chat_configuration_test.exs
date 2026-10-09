defmodule LoopexCli.ChatConfigurationTest do
  use ExUnit.Case, async: false
  @moduletag capture_log: true

  alias LoopexCli.ChatConfiguration
  alias Loopex.Runtime
  alias Loopex.Runtime.SessionGenesis
  alias LoopexProtocol.ToolDefinition

  setup do
    root =
      Path.join(System.tmp_dir!(), "chat-config-#{Base.encode16(:crypto.strong_rand_bytes(8))}")

    File.mkdir_p!(Path.join(root, "workspace"))
    file = Path.join(root, "chat.json")
    File.write!(file, :json.encode(profile()))
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root, config_path: file, argv: ["chat", "--config", file]}
  end

  test "creation captures the verified physical identity and preserves alias identity", f do
    workspace = Path.join(f.root, "workspace")
    alias_path = Path.join(f.root, "workspace-alias")
    File.ln_s!(workspace, alias_path)
    assert {:ok, reference} = LoopexComposition.WorkspaceIdentity.reference(workspace)
    assert {:ok, prepared} = load(f)

    assert prepared.session_options == %{
             "surface" => "chat",
             "workspace_binding" => %{"revision" => 1, "workspace_ref" => reference}
           }

    assert prepared.genesis["options"] == prepared.session_options
    assert {:ok, aliased} = load(f, ["--workspace", alias_path])
    assert aliased.session_options == prepared.session_options
    refute File.exists?(Path.join(f.root, "state"))
  end

  test "creation requires an existing physical workspace and never creates it", f do
    absent = Path.join(f.root, "absent-workspace")
    assert load(f, ["--workspace", absent]) == {:error, :enoent}
    refute File.exists?(absent)
    file = Path.join(f.root, "ordinary-file")
    File.write!(file, "not a directory")
    assert load(f, ["--workspace", file]) == {:error, :workspace_root_not_directory}
    refute File.exists?(Path.join(f.root, "state"))
  end

  test "each chat profile freezes exactly its tools, including opt-in questions", fixture do
    for {profile, expected} <- [
          {"none", []},
          {"coding", ~w(loopex.read loopex.write loopex.edit loopex.bash loopex.ask)},
          {"read-only", ~w(loopex.read loopex.grep loopex.find loopex.ls loopex.ask)}
        ] do
      assert {:ok, prepared} = load(fixture, ["--tools", profile])
      assert prepared.active_tools == expected
      assert {:ok, normalized} = SessionGenesis.normalize(prepared.genesis)
      assert normalized == prepared.genesis
      definitions = prepared.genesis["tool_selection"]["definitions"]
      assert Enum.sort(Enum.map(definitions, & &1["tool_id"])) == Enum.sort(expected)
      assert map_size(prepared.genesis["tool_selection"]["names"]) == length(expected)

      if profile != "none" do
        assert Enum.find(definitions, &(&1["tool_id"] == "loopex.ask")) ==
                 ToolDefinition.question_definition()

        assert prepared.genesis["tool_selection"]["artifact_read"] == %{
                 "revision" => "loopex.artifact_read.v1",
                 "tool_id" => "loopex.read",
                 "tool_version" => "1.1.0",
                 "definition_digest" =>
                   "858956b73d7059ffaf18943d28bb0654ee3ca935f86cec3a136ba8e93b6e3c9e"
               }

        assert Enum.find(definitions, &(&1["tool_id"] == "loopex.read"))["tool_version"] ==
                 "1.1.0"

        for definition <- definitions,
            definition["tool_id"] in ~w(loopex.grep loopex.find loopex.ls) do
          assert definition["tool_version"] == "1.1.0"
          assert definition["budgets"]["output_bytes"] == 16_384
          assert definition["budgets"]["artifact_bytes"] == 16_384
        end
      else
        assert is_nil(prepared.genesis["tool_selection"]["artifact_read"])
      end

      assert prepared.genesis["policy_defer_mode"] == "admit"
      refute :erlang.term_to_binary(prepared.genesis) =~ "M7_CHAT_CONFIG_SLOT"
      refute File.exists?(Path.join(fixture.root, "state"))
    end
  end

  test "capture binds exact prompt bytes and canonical model without consuming a credential",
       fixture do
    prompt = Path.join(fixture.root, "prompt.txt")
    File.write!(prompt, "Exact instructions 猫\n")
    profile = put_in(profile(), ["session", "instructions"], %{"system_file" => "prompt.txt"})
    File.write!(fixture.config_path, :json.encode(profile))
    previous = System.get_env("M7_CHAT_CONFIG_SLOT")
    System.put_env("M7_CHAT_CONFIG_SLOT", "capture-must-not-consume")

    try do
      assert {:ok, prepared} = load(fixture)
      File.write!(prompt, "Changed after capture")
      captured = prepared.genesis["initial_configuration"]
      assert captured["model"] == "anthropic:claude-haiku-4-5-20251001"
      assert captured["instructions"]["base"] == "Exact instructions 猫\n"
      assert prepared.selection.configuration == captured
      assert System.get_env("M7_CHAT_CONFIG_SLOT") == "capture-must-not-consume"
      assert prepared.selection.origins["/session/model"] == "file#/session/model"
      refute :erlang.term_to_binary(prepared.genesis) =~ "capture-must-not-consume"
      refute File.exists?(Path.join(fixture.root, "state"))
    after
      restore("M7_CHAT_CONFIG_SLOT", previous)
    end
  end

  test "complete chat preparation captures every registered reasoning cell in exact genesis",
       fixture do
    haiku = "anthropic:claude-haiku-4-5-20251001"
    fable = "anthropic:claude-fable-5-1"

    for {authored, model, levels, level, thinking, continuation} <- [
          {"anthropic:claude-haiku-4-5", haiku, ~w(default none low medium high), "default",
           %{"mode" => "omitted"}, false},
          {haiku, haiku, ~w(default none low medium high), "none", %{"mode" => "disabled"},
           false},
          {haiku, haiku, ~w(default none low medium high), "low",
           %{"mode" => "manual", "budget_tokens" => 1024}, true},
          {haiku, haiku, ~w(default none low medium high), "medium",
           %{"mode" => "manual", "budget_tokens" => 2048}, true},
          {haiku, haiku, ~w(default none low medium high), "high",
           %{"mode" => "manual", "budget_tokens" => 4096}, true},
          {fable, fable, ~w(default low medium high), "default", %{"mode" => "omitted"}, true},
          {fable, fable, ~w(default low medium high), "low",
           %{"mode" => "adaptive", "effort" => "low", "display" => "summarized"}, true},
          {fable, fable, ~w(default low medium high), "medium",
           %{"mode" => "adaptive", "effort" => "medium", "display" => "summarized"}, true},
          {fable, fable, ~w(default low medium high), "high",
           %{"mode" => "adaptive", "effort" => "high", "display" => "summarized"}, true}
        ] do
      assert {:ok, prepared} =
               load(fixture, ["--model", authored, "--reasoning", level, "--max-tokens", "8192"])

      configuration = prepared.genesis["initial_configuration"]
      assert configuration == prepared.selection.configuration
      assert configuration["model"] == model
      assert configuration["reasoning"] == level
      assert configuration["max_tokens"] == 8192
      assert configuration["model_capabilities"]["reasoning_levels"] == levels

      assert configuration["context_token_budget"] ==
               if(model == haiku, do: 191_808, else: 991_808)

      assert configuration["provider_mapping"] == %{
               "mapping_revision" =>
                 if(model == haiku,
                   do: "loopex.anthropic.haiku45.v1",
                   else: "loopex.anthropic.fable51.v1"
                 ),
               "renderer_revision" => "loopex.anthropic.native.v1",
               "continuation_required" => continuation,
               "canonical_terminal_tool_history" => true,
               "thinking_disabled" => level == "none",
               "thinking" => thinking
             }

      assert prepared.selection.origins["/session/model"] == "flag"
      assert prepared.selection.origins["/session/reasoning"] == "flag"
      assert prepared.selection.origins["/session/max_tokens"] == "flag"
      assert {:ok, normalized} = SessionGenesis.normalize(prepared.genesis)
      assert normalized == prepared.genesis
      assert prepared.selection.maintenance_model == nil
      refute File.exists?(Path.join(fixture.root, "state"))
    end
  end

  test "chat preparation refuses unsupported cells and never enlarges manual reply allowances",
       fixture do
    for {level, budget} <- [{"low", 1024}, {"medium", 2048}, {"high", 4096}] do
      assert load(fixture, ["--reasoning", level, "--max-tokens", Integer.to_string(budget)]) ==
               {:error, :invalid_model_mapping}

      assert {:ok, prepared} =
               load(fixture, ["--reasoning", level, "--max-tokens", Integer.to_string(budget + 1)])

      assert prepared.selection.configuration["max_tokens"] == budget + 1

      assert prepared.selection.configuration["provider_mapping"]["thinking"]["budget_tokens"] ==
               budget
    end

    for {model, level} <- [
          {"anthropic:claude-fable-5-1", "none"},
          {"anthropic:claude-haiku-latest", "high"},
          {"anthropic:unregistered-fixture", "low"}
        ] do
      assert load(fixture, ["--model", model, "--reasoning", level, "--max-tokens", "8192"]) ==
               {:error, :invalid_model_mapping}
    end

    refute File.exists?(Path.join(fixture.root, "state"))
  end

  test "missing paths and authored bounds refuse before startup and cannot be repaired later",
       fixture do
    File.write!(fixture.config_path, :json.encode(Map.delete(profile(), "paths")))
    assert load(fixture) == {:error, {:missing_configuration_path, "/paths/workspace"}}

    File.write!(fixture.config_path, :json.encode(put_in(profile(), ["session", "bounds"], %{})))
    assert {:error, _} = load(fixture, ["--max-steps", "10"])
    refute File.exists?(Path.join(fixture.root, "state"))
  end

  test "each authored run bound is required even when every matching flag is supplied", fixture do
    flags = ["--max-steps", "20", "--deadline-ms", "2000", "--token-budget", "20000"]

    for field <- ~w(max_turns deadline_ms token_budget) do
      invalid = update_in(profile(), ["session", "bounds"], &Map.delete(&1, field))
      File.write!(fixture.config_path, :json.encode(invalid))
      assert load(fixture, flags) == {:error, {:missing_member, "/session/bounds/" <> field}}
      refute File.exists?(Path.join(fixture.root, "state"))
    end

    File.write!(fixture.config_path, :json.encode(profile()))
    assert {:ok, prepared} = load(fixture, flags)

    assert prepared.selection.profile["session"]["bounds"] == %{
             "max_turns" => 20,
             "deadline_ms" => 2_000,
             "token_budget" => 20_000
           }

    for field <- ~w(max_turns deadline_ms token_budget) do
      assert prepared.selection.origins["/session/bounds/" <> field] == "flag"
    end

    refute File.exists?(Path.join(fixture.root, "state"))
  end

  test "resume cannot replace retained configuration with a freshly prepared profile", fixture do
    assert {:error, {:committed_profile_required, "/flags/resume"}} =
             load(fixture, ["--resume", "retained-session"])

    assert {:error, :invalid_chat_invocation} =
             ChatConfiguration.load(
               ["config", "validate", "--config", fixture.config_path],
               fixture.root,
               nil
             )
  end

  test "configure preparation uses confirmed settings, canonical aliases and derived budgets",
       fixture do
    assert {:ok, prepared} = load(fixture)
    initial = prepared.selection.configuration

    assert {:ok, changes, candidate} =
             ChatConfiguration.update(prepared, %{
               "model" => "anthropic:claude-haiku-4-5",
               "max_tokens" => 4096
             })

    assert changes == %{
             "model" => "anthropic:claude-haiku-4-5",
             "max_tokens" => 4096
           }

    assert candidate["model"] == "anthropic:claude-haiku-4-5-20251001"
    assert candidate["configuration_version"] == 2
    assert candidate["context_token_budget"] == 200_000 - 4096
    assert candidate["budget_origins"]["context_token_budget"] == "model_window"
    assert candidate["system_class_tokens"] == initial["system_class_tokens"]
    assert candidate["instructions"] == initial["instructions"]
    assert prepared.selection.configuration == initial
    refute File.exists?(Path.join(fixture.root, "state"))

    prepared = put_in(prepared, [:selection, :configuration], candidate)

    assert {:ok, _, next} =
             ChatConfiguration.update(prepared, %{"context_token_budget" => 16_000})

    assert next["configuration_version"] == 3
    assert next["context_token_budget"] == 16_000
    assert next["budget_origins"]["context_token_budget"] == "explicit"
  end

  test "configure preparation refuses host metadata, missing routes and unsupported reasoning",
       fixture do
    assert {:ok, prepared} = load(fixture)

    for changes <- [%{}, [], %{"model_capabilities" => %{}}, %{"maintenance_model" => "x"}] do
      assert {:error, :invalid_configuration_update} = ChatConfiguration.update(prepared, changes)
    end

    assert {:error, :provider_route_unavailable} =
             ChatConfiguration.update(prepared, %{"model" => "openai:gpt-4o"})

    assert {:error, :invalid_model_mapping} =
             ChatConfiguration.update(prepared, %{
               "model" => "anthropic:claude-fable-5-1",
               "reasoning" => "none"
             })

    assert {:error, :invalid_session_configuration} =
             ChatConfiguration.update(nil, %{"max_tokens" => 2048})

    refute File.exists?(Path.join(fixture.root, "state"))
  end

  test "the complete selected tool schema contributes to the admitted system ceiling", fixture do
    assert {:ok, _} = load(fixture, ["--tools", "none", "--system-class-tokens", "200"])
    assert {:error, _} = load(fixture, ["--tools", "coding", "--system-class-tokens", "200"])
    refute File.exists?(Path.join(fixture.root, "state"))
  end

  test "durable chat refuses credential-free routes before creating state", fixture do
    profile =
      profile()
      |> Map.put("providers", %{"ollama" => %{"credential" => %{"none" => true}}})
      |> put_in(["session", "model"], "ollama:fixture")
      |> put_in(["session", "context_token_budget"], 16000)

    File.write!(fixture.config_path, :json.encode(profile))
    assert {:ok, ^profile} = LoopexCli.ConfigSchema.validate(profile)
    assert {:error, {:composition, :durable_model_unsupported}} = load(fixture)
    refute File.exists?(Path.join(fixture.root, "state"))
  end

  test "enabled delegation selects the fixed task generation without reading roles yet",
       fixture do
    profile =
      profile()
      |> Map.put("roles", %{
        "reviewer" => %{
          "model" => "anthropic:claude-haiku-4-5",
          "instructions_file" => "not-read-yet.txt"
        }
      })
      |> Map.put("delegation", %{
        "enabled" => true,
        "roles" => ["reviewer"],
        "max_children" => 1,
        "token_budget" => 10000,
        "child_bounds" => %{"max_turns" => 1, "deadline_ms" => 1000, "token_budget" => 1000}
      })

    File.write!(fixture.config_path, :json.encode(profile))
    assert {:ok, prepared} = load(fixture)
    assert prepared.helpers

    assert LoopexComposition.Delegation.Tool.definition() in prepared.genesis["tool_selection"][
             "definitions"
           ]

    environment = prepared.selection.configuration["instructions"]["environment"]
    assert environment =~ ~s("enabled_roles":["reviewer"])
    assert environment =~ "sha256:" <> String.duplicate("0", 64)
    refute File.exists?(Path.join(fixture.root, "state"))
  end

  test "captured chat genesis creates a real durable session and survives runtime restart",
       fixture do
    assert {:ok, prepared} = load(fixture)
    profile = prepared.selection.profile
    configuration = prepared.genesis["initial_configuration"]
    previous = System.get_env("M7_CHAT_CONFIG_SLOT")
    legacy = System.get_env("LOOPEX_PROVIDER_API_KEY")

    options = [
      runtime_id: "chat-configuration-test",
      state_root: profile["paths"]["state_root"],
      workspace: profile["paths"]["workspace"],
      policy: LoopexCli.Policy.AllowAll,
      provider_bindings: profile["providers"],
      model: configuration["model"],
      sampling: %{"max_tokens" => configuration["max_tokens"]},
      context_token_budget: configuration["context_token_budget"],
      session_creation_defaults: Map.drop(prepared.genesis, [:kind, "options"]),
      active_tools: prepared.active_tools,
      cleanup_grace_ms: prepared.genesis["runtime_configuration"]["cleanup_grace_ms"],
      recover_stale_writer: true
    ]

    try do
      System.put_env("M7_CHAT_CONFIG_SLOT", "chat-creation-canary")

      session =
        LoopexComposition.with_runtime(options, fn runtime ->
          assert {:ok, session} =
                   Loopex.create_session(runtime, prepared.session_options,
                     command_id: "chat-create",
                     genesis: prepared.genesis
                   )

          assert retained_genesis(runtime, session) == prepared.genesis
          session
        end)

      assert is_binary(session)
      System.put_env("M7_CHAT_CONFIG_SLOT", "chat-restart-canary")

      assert :resumed =
               LoopexComposition.with_runtime(options, fn runtime ->
                 assert {:ok, ^session} =
                          Loopex.resume_session(runtime, session, command_id: "resume")

                 assert retained_genesis(runtime, session) == prepared.genesis
                 :resumed
               end)
    after
      restore("M7_CHAT_CONFIG_SLOT", previous)
      restore("LOOPEX_PROVIDER_API_KEY", legacy)
    end
  end

  defp retained_genesis(runtime, session) do
    {:ok, children} = Runtime.children(runtime)
    store = :sys.get_state(children.control).store
    {:ok, [genesis | _]} = Loopex.Store.load_records(store, session, 0, 100)
    genesis.payload
  end

  defp load(fixture, flags \\ []),
    do: ChatConfiguration.load(fixture.argv ++ flags, fixture.root, nil)

  defp restore(name, nil), do: System.delete_env(name)
  defp restore(name, value), do: System.put_env(name, value)

  defp profile do
    %{
      "schema_version" => 1,
      "providers" => %{"anthropic" => %{"credential" => %{"env" => "M7_CHAT_CONFIG_SLOT"}}},
      "policy" => "allow-all",
      "paths" => %{"workspace" => "workspace", "state_root" => "state"},
      "session" => %{
        "model" => "anthropic:claude-haiku-4-5",
        "system_class_tokens" => 8000,
        "bounds" => %{"max_turns" => 8, "deadline_ms" => 1000, "token_budget" => 10000}
      }
    }
  end
end
