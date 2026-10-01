defmodule LoopexComposition.ProviderBindingsTest do
  use ExUnit.Case, async: true
  alias LoopexComposition.ProviderBindings

  test "launch exclusions retain the whole closed credential-name policy" do
    legacy = "LOOPEX_PROVIDER_API_KEY"
    assert :ok = ProviderBindings.validate_exclusions([legacy])

    assert :ok =
             ProviderBindings.validate_exclusions(
               Enum.sort([legacy | Enum.map(1..16, &"KEY_#{&1}")])
             )

    for names <- [
          nil,
          [],
          ["KEY"],
          [legacy, legacy],
          ["Z_KEY", legacy],
          Enum.sort([legacy | Enum.map(1..17, &"KEY_#{&1}")]),
          Enum.sort([legacy, "HOME"]),
          Enum.sort([legacy, "LC_ALL"]),
          Enum.sort([legacy, "LD_PRELOAD"]),
          Enum.sort([legacy, "LOOPEX_OTHER"]),
          [legacy, "bad=name"],
          [legacy, 7],
          [legacy, String.duplicate("x", 129)]
        ] do
      assert {:error, :invalid_credential_exclusions} =
               ProviderBindings.validate_exclusions(names)
    end
  end

  test "maintenance selection is explicit, routed and requires a registered thinking-off mapping" do
    routes = %{
      "anthropic" => env("HOST_REFERENCE_ONLY_KEY"),
      "openai" => env("OTHER_REFERENCE_ONLY_KEY")
    }

    assert {:ok, nil} = ProviderBindings.resolve_maintenance_model(nil, routes)

    assert {:ok, selected} =
             ProviderBindings.resolve_maintenance_model("anthropic:claude-haiku-4-5", routes)

    assert Enum.sort(Map.keys(selected)) ==
             ~w(model model_capabilities provider_mapping reasoning)

    assert selected["model"] == "anthropic:claude-haiku-4-5-20251001"
    assert selected["reasoning"] == "none"
    assert selected["provider_mapping"]["thinking"] == %{"mode" => "disabled"}
    assert selected["provider_mapping"]["thinking_disabled"]
    refute selected["provider_mapping"]["continuation_required"]
    refute :erlang.term_to_binary(selected) =~ "REFERENCE_ONLY_KEY"

    for model <- ["anthropic:claude-fable-5-1", "openai:unregistered-summary"] do
      assert {:error, :maintenance_reasoning_unsupported} =
               ProviderBindings.resolve_maintenance_model(model, routes)
    end

    assert {:error, :provider_route_unavailable} =
             ProviderBindings.resolve_maintenance_model("anthropic:claude-haiku-4-5", %{
               "openai" => env("KEY")
             })
  end

  test "configuration resolution joins admitted routes, exact cells and captured instructions" do
    routes = %{"anthropic" => env("HOST_REFERENCE_ONLY_KEY")}

    for {model, levels} <- [
          {"anthropic:claude-haiku-4-5", ~w(default none low medium high)},
          {"anthropic:claude-fable-5-1", ~w(default low medium high)}
        ],
        level <- levels do
      declaration = declaration(model, level)

      assert {:ok, configuration} =
               ProviderBindings.resolve_configuration(declaration, routes, [])

      exact = if model == "anthropic:claude-haiku-4-5", do: model <> "-20251001", else: model
      assert configuration["model"] == exact
      assert configuration["reasoning"] == level
      assert configuration["instructions"] == declaration["instructions"]
      assert configuration["max_tokens"] == 8192

      assert configuration["context_token_budget"] ==
               configuration["model_capabilities"]["context_window"] - 8192

      refute :erlang.term_to_binary(configuration) =~ "HOST_REFERENCE_ONLY_KEY"
      assert :ok == Loopex.Runtime.SessionConfiguration.validate(configuration, [])
    end
  end

  test "missing routes, unverified modes and authored metadata refuse before startup" do
    routes = %{"anthropic" => env("HOST_REFERENCE_ONLY_KEY")}
    original = declaration("anthropic:claude-haiku-4-5", "high")

    assert {:error, :provider_route_unavailable} =
             ProviderBindings.resolve_configuration(original, %{"openai" => env("KEY")}, [])

    assert {:error, {:invalid_credential_reference, _}} =
             ProviderBindings.resolve_configuration(
               original,
               Map.put(routes, "openai", env("HOME")),
               []
             )

    for changed <- [
          Map.put(original, "max_tokens", 4096),
          Map.put(original, "reasoning", "unsupported"),
          %{original | "model" => "anthropic:claude-fable-5-1", "reasoning" => "none"}
        ] do
      assert {:error, :invalid_model_mapping} =
               ProviderBindings.resolve_configuration(changed, routes, [])
    end

    for changed <- [
          Map.put(original, "provider_mapping", %{}),
          Map.put(original, "model_capabilities", %{}),
          Map.put(original, "max_tokens", 64_001),
          Map.put(original, "context_token_budget", 200_000)
        ] do
      assert {:error, :invalid_session_configuration} =
               ProviderBindings.resolve_configuration(changed, routes, [])
    end
  end

  test "unknown model limits and explicit ceilings keep their distinct origins" do
    declared = declaration("ollama:m7-unknown-model", "default")
    routes = %{"ollama" => %{"credential" => %{"none" => true}}}
    assert {:ok, inferred} = ProviderBindings.resolve_configuration(declared, routes, [])
    assert inferred["context_token_budget"] == 8192
    assert inferred["model_capabilities"]["output_limit"] == nil
    assert inferred["budget_origins"]["context_token_budget"] == "unknown_window"
    assert inferred["provider_mapping"]["mapping_revision"] == "loopex.unregistered.default.v1"

    assert {:ok, explicit} =
             ProviderBindings.resolve_configuration(
               Map.put(declared, "context_token_budget", 8192),
               routes,
               []
             )

    assert explicit["budget_origins"]["context_token_budget"] == "explicit"
  end

  test "whole configuration admission measures the selected tools with instructions" do
    declaration = declaration("anthropic:claude-haiku-4-5", "default")
    routes = %{"anthropic" => env("HOST_REFERENCE_ONLY_KEY")}
    tool = LoopexProtocol.ToolDefinition.question_definition()
    {:ok, text} = Loopex.Runtime.Instructions.render(declaration["instructions"])

    system =
      Loopex.Bounds.estimate(
        LoopexProtocol.Canonical.encode(%{"role" => "system", "content" => text})
      )

    declaration = Map.put(declaration, "system_class_tokens", system + 1)
    assert {:ok, _} = ProviderBindings.resolve_configuration(declaration, routes, [])

    assert {:error, :invalid_session_configuration} =
             ProviderBindings.resolve_configuration(declaration, routes, [tool])
  end

  defp declaration(model, level) do
    %{
      "model" => model,
      "reasoning" => level,
      "configuration_version" => 1,
      "max_tokens" => 8192,
      "instructions" => Loopex.Runtime.Instructions.legacy()
    }
  end

  test "complete explicit references retain routes and sorted launch exclusions" do
    bindings = %{
      "openai" => env("HOST_Z_KEY"),
      "anthropic" => env("HOST_A_KEY"),
      "openrouter" => env("HOST_Z_KEY")
    }

    assert ProviderBindings.validate(bindings) ==
             {:ok,
              %{
                bindings: bindings,
                excluded_env_names: ["HOST_A_KEY", "HOST_Z_KEY", "LOOPEX_PROVIDER_API_KEY"]
              }}

    legacy = %{"openai" => env("LOOPEX_PROVIDER_API_KEY")}

    assert {:ok, %{bindings: ^legacy, excluded_env_names: ["LOOPEX_PROVIDER_API_KEY"]}} =
             ProviderBindings.validate(legacy)
  end

  test "only the existing credential-free catalog route admits none" do
    free = %{"ollama" => %{"credential" => %{"none" => true}}}
    assert {:ok, %{bindings: ^free}} = ProviderBindings.validate(free)

    for provider <- ~w(openai anthropic openrouter) do
      assert ProviderBindings.validate(%{provider => %{"credential" => %{"none" => true}}}) ==
               {:error, {:credential_required, "/providers/#{provider}/credential"}}
    end
  end

  test "closed binding shapes and reference errors never echo authored values" do
    for binding <- [
          nil,
          %{},
          %{"credential" => nil},
          %{"credential" => %{}},
          %{"credential" => %{"value" => "secret-value"}},
          %{"credential" => %{"env" => "KEY", "none" => true}},
          %{"credential" => %{"none" => false}},
          %{"credential" => %{"env" => "KEY"}, "other" => "secret-value"},
          %{credential: %{env: "KEY"}}
        ] do
      assert {:error, {class, pointer}} = ProviderBindings.validate(%{"openai" => binding})
      assert class == :invalid_credential_binding
      assert pointer in ["/providers/openai", "/providers/openai/credential"]
    end

    assert ProviderBindings.validate(%{"openai" => env("credential-value!")}) ==
             {:error, {:invalid_credential_reference, "/providers/openai/credential/env"}}
  end

  test "route inventory rejects empty, oversized, unknown and atom-key maps" do
    for routes <- [nil, [], %{}, Map.new(1..17, &{"p#{&1}", env("KEY")}), %{openai: env("KEY")}] do
      assert ProviderBindings.validate(routes) ==
               {:error, {:invalid_provider_bindings, "/providers"}}
    end

    for provider <- ["unknown", "openai:alias", "OPENAI", <<255>>, "secret-value"] do
      assert ProviderBindings.validate(%{provider => env("KEY")}) ==
               {:error, {:unsupported_provider, "/providers"}}
    end
  end

  test "every operational name and prefix refuses before resolution" do
    names =
      ~w(LC_ALL PATH HOME TMPDIR TMP TEMP SHELL USER LOGNAME PWD OLDPWD SHLVL IFS CDPATH ENV BASH_ENV ZDOTDIR)

    prefixes = ~w(LD_ DYLD_ ERL_ ELIXIR_ MIX_ RELEASE_ BASH_ LOOPEX_)

    for name <- names ++ Enum.flat_map(prefixes, &[&1, &1 <> "CUSTOM_KEY"]) do
      refute ProviderBindings.valid_env_name?(name)

      assert ProviderBindings.validate(%{"openai" => env(name)}) ==
               {:error, {:invalid_credential_reference, "/providers/openai/credential/env"}}
    end
  end

  test "environment syntax uses exact ASCII byte boundaries" do
    for name <- [
          "KEY",
          "_KEY",
          "Host_Key_1",
          String.duplicate("A", 128),
          "LOOPEX_PROVIDER_API_KEY"
        ] do
      assert ProviderBindings.valid_env_name?(name)
    end

    for name <- [
          nil,
          :KEY,
          "",
          "1KEY",
          "KEY-1",
          "KEY=1",
          "KEY\n",
          "é_KEY",
          <<255>>,
          String.duplicate("A", 129)
        ] do
      refute ProviderBindings.valid_env_name?(name)
    end
  end

  test "validation is pure with respect to populated and absent host slots" do
    name = "M7_BINDING_PURITY_#{System.unique_integer([:positive])}"
    System.put_env(name, "private-value")
    on_exit(fn -> System.delete_env(name) end)
    routes = %{"openai" => env(name), "anthropic" => env(name <> "_ABSENT")}
    assert {:ok, _} = ProviderBindings.validate(routes)
    assert System.get_env(name) == "private-value"
    assert System.get_env(name <> "_ABSENT") == nil
    assert {:error, _} = ProviderBindings.validate(Map.put(routes, "ollama", env("PATH")))
    assert System.get_env(name) == "private-value"
  end

  defp env(name), do: %{"credential" => %{"env" => name}}
end
