defmodule LoopexComposition.ProviderBindingsTest do
  use ExUnit.Case, async: true
  alias LoopexComposition.ProviderBindings

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
      ~w(PATH HOME TMPDIR TMP TEMP SHELL USER LOGNAME PWD OLDPWD SHLVL IFS CDPATH ENV BASH_ENV ZDOTDIR)

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
