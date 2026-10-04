defmodule LoopexComposition.Ephemeral.PreflightTest do
  use ExUnit.Case, async: false

  alias LoopexComposition.Ephemeral.Preflight

  defmodule Policy do
    @behaviour Loopex.Policy
    def decide(_request), do: {:allow, nil}
  end

  test "option grammar wins before workspace and provider selection" do
    absent = Path.join(System.tmp_dir!(), "loopex-m6-preflight-absent-#{System.unique_integer()}")

    assert {:error, {:invalid_option, :unknown_key}} =
             Preflight.prepare(policy: Policy, cwd: absent, model: "missing:model", unknown: true)

    assert {:error, {:invalid_option, :duplicate_key}} =
             Preflight.prepare(policy: Policy, policy: Policy, cwd: absent)
  end

  test "workspace failure precedes skill, provider and shared startup" do
    absent = Path.join(System.tmp_dir!(), "loopex-m6-preflight-absent-#{System.unique_integer()}")

    assert {:error, {:composition, :workspace_unusable}} =
             Preflight.prepare(
               policy: Policy,
               cwd: absent,
               skills: ["missing"],
               model: "missing:model"
             )
  end

  test "invalid maintenance instructions refuse before workspace or owner allocation" do
    before_children =
      DynamicSupervisor.count_children(LoopexComposition.Ephemeral.OwnerSupervisor)

    assert {:error, :maintenance_instructions_invalid} =
             LoopexComposition.Ephemeral.start_session(
               policy: Policy,
               cwd: "/nonexistent-maintenance-workspace",
               maintenance_instructions: %{}
             )

    assert DynamicSupervisor.count_children(LoopexComposition.Ephemeral.OwnerSupervisor) ==
             before_children
  end

  test "named skill failure precedes provider selection" do
    assert {:error, {:composition, :skill_directory_unusable}} =
             Preflight.prepare(
               policy: Policy,
               cwd: File.cwd!(),
               skills: [".agents/skills/loopex-m6-absent-#{System.unique_integer()}"],
               model: "missing:model"
             )
  end

  test "provider selection precedes host-global guards" do
    previous = System.get_env("SSLKEYLOGFILE")
    System.put_env("SSLKEYLOGFILE", "/tmp/loopex-preflight-keylog-never-opened")

    try do
      assert {:error, {:composition, :unknown_provider}} =
               Preflight.prepare(policy: Policy, cwd: File.cwd!(), model: "missing:model")
    after
      restore_env("SSLKEYLOGFILE", previous)
    end
  end

  test "host guard refuses before starting a provider dependency" do
    previous = System.get_env("SSLKEYLOGFILE")
    System.put_env("SSLKEYLOGFILE", "/tmp/loopex-preflight-keylog-never-opened")

    try do
      assert {:error, {:composition, :ssl_key_log_enabled}} =
               Preflight.prepare(policy: Policy, cwd: File.cwd!(), model: "ollama:llama3.2")
    after
      restore_env("SSLKEYLOGFILE", previous)
    end
  end

  test "local selection reaches the guarded dependency and returns an explicit address" do
    assert {:ok, selection} =
             Preflight.prepare(policy: Policy, cwd: File.cwd!(), model: "ollama:llama3.2")

    assert selection.provider.provider == :ollama
    assert selection.provider.credential_variable == nil
    assert String.starts_with?(selection.base_url, "http://")
    assert selection.skills.shadowed_skills == []
    assert is_map(selection.skills.manifest)
  end

  test "a hosted address refuses HTTP without reading a key" do
    assert {:error, {:composition, :provider_base_url_unsupported}} =
             Preflight.prepare(
               policy: Policy,
               cwd: File.cwd!(),
               model: "openai:gpt-4o-mini",
               base_url: "http://example.test/v1"
             )
  end

  test "prepared genesis binds exact host configuration and only selected tools" do
    instructions = %{
      "version" => "host.exact.v1",
      "base" => "Keep these bytes 猫\n",
      "environment" => "retained host facts",
      "appendix" => "trusted appendix"
    }

    routes = %{"openai" => %{"credential" => %{"env" => "M7_NEVER_READ_GENESIS_KEY"}}}

    assert {:ok, selected} =
             Preflight.prepare(
               policy: Policy,
               cwd: File.cwd!(),
               model: "openai:gpt-4o-mini",
               provider_bindings: routes,
               instructions: instructions,
               tools: :read_only,
               questions: true,
               max_tokens: 128
             )

    genesis = selected.genesis
    configuration = genesis["initial_configuration"]
    assert genesis.kind == "session_genesis_v3"
    assert genesis["options"] == %{"surface" => "embedded"}
    assert Map.delete(configuration["instructions"], "digest") == instructions
    assert configuration["reasoning"] == "default"
    assert configuration["system_class_tokens"] == 1000
    assert configuration["budget_origins"]["context_token_budget"] == "model_window"

    assert selected.context_token_budget ==
             configuration["model_capabilities"]["context_window"] - 128

    assert Enum.map(genesis["tool_selection"]["definitions"], & &1["tool_id"]) ==
             ~w(loopex.read loopex.grep loopex.find loopex.ls loopex.ask)

    refute inspect(genesis) =~ "M7_NEVER_READ_GENESIS_KEY"
    assert {:ok, ^genesis} = Loopex.Runtime.SessionGenesis.normalize(genesis)
  end

  test "unsupported reasoning and invalid system cost refuse before owner allocation" do
    before_children =
      DynamicSupervisor.count_children(LoopexComposition.Ephemeral.OwnerSupervisor)

    assert {:error, :invalid_model_mapping} =
             Preflight.prepare(
               policy: Policy,
               cwd: File.cwd!(),
               model: "ollama:llama3.2",
               reasoning: "high"
             )

    assert {:error, :invalid_session_configuration} =
             Preflight.prepare(
               policy: Policy,
               cwd: File.cwd!(),
               model: "ollama:llama3.2",
               system_class_tokens: 1
             )

    assert DynamicSupervisor.count_children(LoopexComposition.Ephemeral.OwnerSupervisor) ==
             before_children

    assert {:ok, selected} =
             Preflight.prepare(
               policy: Policy,
               cwd: File.cwd!(),
               model: "ollama:llama3.2",
               context_token_budget: 8192,
               system_class_tokens: 1000
             )

    assert selected.genesis["initial_configuration"]["budget_origins"] ==
             %{"context_token_budget" => "explicit", "system_class_tokens" => "explicit"}
  end

  test "default workspace capture cannot silently enlarge the question profile ceiling" do
    {:ok, selected} =
      LoopexComposition.Ephemeral.Options.parse(
        policy: Policy,
        model: "ollama:llama3.2",
        tools: :read_only,
        questions: true,
        max_tokens: 128
      )

    bindings = %{"ollama" => %{"credential" => %{"none" => true}}}
    workspace = "/workspace/" <> String.duplicate("w", 1000)

    assert {:error, :invalid_session_configuration} =
             Preflight.genesis(selected, workspace, bindings)

    {:ok, captured} =
      Loopex.Runtime.Instructions.capture(%{
        "version" => "host.questions.v1",
        "base" => "Ask the operator, then answer.",
        "environment" => "",
        "appendix" => ""
      })

    assert {:ok, genesis} =
             Preflight.genesis(Map.put(selected, :instructions, captured), workspace, bindings)

    assert genesis["initial_configuration"]["system_class_tokens"] == 1000

    assert genesis["initial_configuration"]["budget_origins"]["system_class_tokens"] ==
             "legacy_default"
  end

  test "explicit routes admit the ordinary and maintenance models without resolving values" do
    routes = %{
      "openai" => %{"credential" => %{"env" => "M7_UNUSED_FIRST_REFERENCE"}},
      "anthropic" => %{"credential" => %{"env" => "M7_UNUSED_SECOND_REFERENCE"}}
    }

    options = [
      policy: Policy,
      cwd: File.cwd!(),
      model: "openai:gpt-4o-mini",
      provider_bindings: routes,
      maintenance_model: "anthropic:claude-haiku-4-5"
    ]

    assert {:ok, selection} = Preflight.prepare(options)
    assert selection.provider_bindings == routes
    assert selection.maintenance_model["model"] == "anthropic:claude-haiku-4-5-20251001"
    assert selection.maintenance_model["reasoning"] == "none"
    assert selection.provider_base_url == nil

    assert {:error, :provider_route_unavailable} =
             Preflight.prepare(
               Keyword.put(options, :provider_bindings, Map.delete(routes, "openai"))
             )

    assert {:error, :provider_route_unavailable} =
             Preflight.prepare(
               Keyword.put(options, :provider_bindings, Map.delete(routes, "anthropic"))
             )

    assert {:error, :provider_route_unavailable} =
             Preflight.prepare(Keyword.delete(options, :provider_bindings))

    assert {:error, :maintenance_reasoning_unsupported} =
             Preflight.prepare(
               Keyword.put(options, :maintenance_model, "anthropic:claude-fable-5-1")
             )

    assert {:error, {:invalid_provider_bindings, "/providers"}} =
             Preflight.prepare(Keyword.put(options, :provider_bindings, nil))
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
end
