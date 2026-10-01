defmodule LoopexCli.ConfigSchemaTest do
  use ExUnit.Case, async: true
  alias LoopexCli.{ConfigJson, ConfigSchema}
  @uint64 18_446_744_073_709_551_615

  test "required profile is retained exactly without defaults or environment resolution" do
    config = profile()
    assert ConfigSchema.validate(config) == {:ok, config}
    refute Map.has_key?(config["session"], "max_tokens")
    refute Map.has_key?(config, "maintenance")
  end

  test "every admitted optional object stays closed and retains authored data" do
    config = complete()
    assert ConfigSchema.validate(config) == {:ok, config}
    assert config["paths"]["workspace"] == "relative/workspace"
    assert config["session"]["instructions"]["system_file"] == "base.txt"
  end

  test "unknown members at every fixed object level return the precise pointer" do
    for path <- [
          [],
          ["paths"],
          ["session"],
          ["session", "bounds"],
          ["session", "instructions"],
          ["maintenance"],
          ["roles", "builder"],
          ["delegation"],
          ["delegation", "child_bounds"],
          ["trace"]
        ] do
      config = update(complete(), path, &Map.put(&1, "secret/field~", "private-value"))
      pointer = Enum.map_join(path, "", &("/" <> &1)) <> "/secret~1field~0"
      assert ConfigSchema.validate(config) == {:error, {:unknown_member, pointer}}
    end

    config = put_in(complete(), ["providers", "openai", "credential", "value"], "private-value")

    assert ConfigSchema.validate(config) ==
             {:error, {:invalid_credential_binding, "/providers/openai/credential"}}
  end

  test "required bounds are authored even when an override could supply them later" do
    for field <- ~w(schema_version providers policy session) do
      assert ConfigSchema.validate(Map.delete(profile(), field)) ==
               {:error, {:missing_member, "/#{field}"}}
    end

    for field <- ~w(model bounds) do
      config = update(profile(), ["session"], &Map.delete(&1, field))
      assert ConfigSchema.validate(config) == {:error, {:missing_member, "/session/#{field}"}}
    end

    for field <- ~w(max_turns deadline_ms token_budget) do
      config = update(profile(), ["session", "bounds"], &Map.delete(&1, field))

      assert ConfigSchema.validate(config) ==
               {:error, {:missing_member, "/session/bounds/#{field}"}}
    end
  end

  test "null optional fields cannot masquerade as omitted settings" do
    for path <- [
          ["paths"],
          ["policy"],
          ["session"],
          ["session", "instructions"],
          ["session", "reasoning"],
          ["session", "cleanup_grace_ms"],
          ["session", "instructions", "system_file"],
          ["session", "skill_dirs", Access.at(0)],
          ["maintenance"],
          ["roles", "builder"],
          ["roles", "builder", "reasoning"],
          ["delegation", "enabled"],
          ["delegation", "roles", Access.at(0)],
          ["trace", "enabled"],
          ["trace", "modules", Access.at(0)],
          ["output"]
        ] do
      config = put_in(complete(), path, nil)
      assert {:error, {:null_not_allowed, _}} = ConfigSchema.validate(config)
    end
  end

  test "version is an integer and does not accept rounded fraction or exponent syntax" do
    assert ConfigSchema.validate(%{profile() | "schema_version" => 2}) ==
             {:error, {:unsupported_schema_version, "/schema_version"}}

    for value <- ["1", {:non_integer_number}, true, []] do
      assert ConfigSchema.validate(%{profile() | "schema_version" => value}) ==
               {:error, {:invalid_type, "/schema_version"}}
    end

    assert {:ok, decoded} =
             ConfigJson.decode(
               ~s({"schema_version":1.0,"providers":{"openai":{"credential":{"env":"HOST_KEY"}}},"policy":"allow-all","session":{"model":"openai:fixture","bounds":{"max_turns":1,"deadline_ms":1,"token_budget":1}}})
             )

    assert ConfigSchema.validate(decoded) == {:error, {:invalid_type, "/schema_version"}}
  end

  test "turn and token bounds retain integers above uint64 while deadlines keep their limit" do
    for field <- ~w(max_turns token_budget) do
      config = put_in(profile(), ["session", "bounds", field], @uint64 + 1)
      assert ConfigSchema.validate(config) == {:ok, config}
    end

    config = put_in(profile(), ["session", "bounds", "deadline_ms"], @uint64)
    assert ConfigSchema.validate(config) == {:ok, config}
    config = put_in(config, ["session", "bounds", "deadline_ms"], @uint64 + 1)

    assert ConfigSchema.validate(config) ==
             {:error, {:invalid_value, "/session/bounds/deadline_ms"}}

    for field <- ~w(max_turns deadline_ms token_budget),
        value <- [0, -1, "1", {:non_integer_number}, true] do
      assert {:error, {class, "/session/bounds/" <> ^field}} =
               ConfigSchema.validate(put_in(profile(), ["session", "bounds", field], value))

      assert class in [:invalid_value, :invalid_type]
    end
  end

  test "all numeric optional settings refuse zero and wrong types" do
    for field <- ~w(max_tokens context_token_budget system_class_tokens cleanup_grace_ms),
        value <- [0, -1, "1", {:non_integer_number}] do
      config = put_in(profile(), ["session", field], value)
      assert {:error, {class, "/session/" <> ^field}} = ConfigSchema.validate(config)
      assert class in [:invalid_value, :invalid_type]
    end

    for field <- ~w(context_token_budget system_class_tokens cleanup_grace_ms) do
      assert ConfigSchema.validate(put_in(profile(), ["session", field], @uint64 + 1)) ==
               {:error, {:invalid_value, "/session/#{field}"}}
    end
  end

  test "system ceiling checks the authored default as well as explicit values" do
    config = put_in(profile(), ["session", "context_token_budget"], 999)

    assert ConfigSchema.validate(config) ==
             {:error, {:system_ceiling_exceeds_context, "/session/system_class_tokens"}}

    config = put_in(config, ["session", "system_class_tokens"], 999)
    assert ConfigSchema.validate(config) == {:ok, config}
    config = put_in(config, ["session", "system_class_tokens"], 1_000)

    assert ConfigSchema.validate(config) ==
             {:error, {:system_ceiling_exceeds_context, "/session/system_class_tokens"}}
  end

  test "selected parent and maintenance models require exact admitted routes" do
    for path <- [["session", "model"], ["maintenance", "model"]] do
      config = put_in(complete(), path, "openrouter:fixture")
      pointer = Enum.map_join(path, "", &("/" <> &1))
      assert ConfigSchema.validate(config) == {:error, {:missing_provider_binding, pointer}}
    end

    for value <- [
          "missing-colon",
          "openai:",
          ":model",
          "unknown:model",
          <<255>>,
          String.duplicate("x", 513)
        ] do
      assert ConfigSchema.validate(put_in(profile(), ["session", "model"], value)) ==
               {:error, {:invalid_model, "/session/model"}}
    end

    local =
      profile()
      |> Map.put("providers", %{"ollama" => %{"credential" => %{"none" => true}}})
      |> put_in(["session", "model"], "ollama:fixture")

    assert ConfigSchema.validate(local) == {:ok, local}
  end

  test "policy, tools, reasoning and output have closed registries" do
    for {path, value} <- [
          {["policy"], "automatic"},
          {["policy"], true},
          {["session", "tools"], "read_only"},
          {["session", "reasoning"], "maximum"},
          {["roles", "builder", "reasoning"], "inherit"},
          {["output"], "json"}
        ] do
      assert {:error, {class, _}} = ConfigSchema.validate(put_in(complete(), path, value))
      assert class in [:invalid_value, :invalid_type]
    end
  end

  test "path validation counts UTF-8 bytes and does not perform substitution" do
    for path <- ["~/workspace", "$HOME/workspace", "../workspace", String.duplicate("é", 2_048)] do
      config = put_in(complete(), ["paths", "workspace"], path)
      assert ConfigSchema.validate(config) == {:ok, config}
    end

    for path <- ["", "/" <> <<0>>, <<255>>, String.duplicate("é", 2_048) <> "x"] do
      assert {:error, {_, "/paths/workspace"}} =
               ConfigSchema.validate(put_in(complete(), ["paths", "workspace"], path))
    end
  end

  test "array limits refuse before later file reads" do
    for {path, values} <- [
          {["session", "skill_dirs"], List.duplicate("skill", 17)},
          {["trace", "modules"], List.duplicate("Loopex.*", 65)},
          {["delegation", "roles"], List.duplicate("builder", 17)}
        ] do
      assert {:error, {:too_many_items, _}} =
               ConfigSchema.validate(put_in(complete(), path, values))
    end

    assert {:error, {:invalid_type, "/session/skill_dirs"}} =
             ConfigSchema.validate(put_in(complete(), ["session", "skill_dirs"], ["a" | :tail]))
  end

  test "roles cannot carry policy, tool, spending or credential overrides" do
    for field <- ~w(policy tools token_budget providers credentials paths instructions) do
      config = put_in(complete(), ["roles", "builder", field], "private-value")

      assert ConfigSchema.validate(config) ==
               {:error, {:unknown_member, "/roles/builder/#{field}"}}
    end

    for name <- ["Builder", "bad/name", "a" <> String.duplicate("x", 64), "é"] do
      config = Map.put(profile(), "roles", %{name => role()})
      assert {:error, {class, _}} = ConfigSchema.validate(config)
      assert class in [:invalid_identifier, :invalid_value]
    end

    assert ConfigSchema.validate(Map.put(profile(), "roles", %{builder: role()})) ==
             {:error, {:invalid_type, "/roles"}}

    assert ConfigSchema.validate(Map.put(profile(), "roles", Map.new(1..17, &{"r#{&1}", role()}))) ==
             {:error, {:too_many_members, "/roles"}}
  end

  test "enabled delegation requires complete spending limits, known roles and tools" do
    for key <- ~w(roles max_children token_budget child_bounds) do
      config = update(complete(), ["delegation"], &Map.delete(&1, key))
      assert ConfigSchema.validate(config) == {:error, {:missing_member, "/delegation/#{key}"}}
    end

    for {path, value, class, pointer} <- [
          {["delegation", "roles"], [], :invalid_value, "/delegation/roles"},
          {["delegation", "roles"], ["missing"], :unknown_role, "/delegation/roles/0"},
          {["delegation", "roles"], ["builder", "builder"], :duplicate_role, "/delegation/roles"},
          {["delegation", "max_children"], 129, :invalid_value, "/delegation/max_children"},
          {["delegation", "child_bounds", "deadline_ms"], 600_001, :invalid_value,
           "/delegation/child_bounds/deadline_ms"},
          {["session", "tools"], "none", :delegation_requires_tools, "/delegation/enabled"},
          {["roles", "builder", "model"], "openrouter:fixture", :missing_provider_binding,
           "/roles/builder/model"}
        ] do
      assert ConfigSchema.validate(put_in(complete(), path, value)) == {:error, {class, pointer}}
    end
  end

  test "disabled delegation still validates supplied fields and child bounds" do
    config = put_in(complete(), ["delegation", "enabled"], false)
    config = put_in(config, ["session", "tools"], "none")
    assert ConfigSchema.validate(config) == {:ok, config}

    assert ConfigSchema.validate(
             put_in(config, ["delegation", "child_bounds", "deadline_ms"], 600_001)
           ) ==
             {:error, {:invalid_value, "/delegation/child_bounds/deadline_ms"}}

    assert ConfigSchema.validate(Map.put(profile(), "delegation", %{"enabled" => false})) ==
             {:ok, Map.put(profile(), "delegation", %{"enabled" => false})}
  end

  test "trace settings can only lower existing ceilings even when disabled" do
    for {key, limit} <- [
          {"max_entry_bytes", 4_096},
          {"max_entries_per_second", 2_000},
          {"max_queue_entries", 8_192}
        ] do
      config = put_in(complete(), ["trace", key], limit)
      assert ConfigSchema.validate(config) == {:ok, config}

      assert ConfigSchema.validate(put_in(config, ["trace", key], limit + 1)) ==
               {:error, {:invalid_value, "/trace/#{key}"}}
    end

    assert ConfigSchema.validate(put_in(complete(), ["trace", "modules"], ["ReqLLM.*"])) ==
             {:error, {:unsupported_trace_selector, "/trace/modules/0"}}
  end

  defp profile do
    %{
      "schema_version" => 1,
      "providers" => %{"openai" => %{"credential" => %{"env" => "M7_HOST_KEY"}}},
      "policy" => "allow-all",
      "session" => %{"model" => "openai:fixture", "bounds" => bounds()}
    }
  end

  defp complete do
    profile()
    |> Map.put("paths", %{"workspace" => "relative/workspace", "state_root" => "state"})
    |> Map.put("maintenance", %{"model" => "openai:summary"})
    |> Map.put("roles", %{"builder" => role()})
    |> Map.put("delegation", %{
      "enabled" => true,
      "roles" => ["builder"],
      "max_children" => 2,
      "token_budget" => 2_000,
      "child_bounds" => bounds(),
      "max_tokens" => 512,
      "context_token_budget" => 4_096,
      "system_class_tokens" => 500
    })
    |> Map.put("trace", %{
      "enabled" => false,
      "level" => "calls",
      "modules" => ["Loopex.*"],
      "max_entry_bytes" => 512,
      "max_entries_per_second" => 20,
      "max_queue_entries" => 64
    })
    |> Map.put("output", "text")
    |> update(
      ["session"],
      &Map.merge(&1, %{
        "reasoning" => "default",
        "max_tokens" => 1_024,
        "context_token_budget" => 8_192,
        "system_class_tokens" => 1_000,
        "instructions" => %{"system_file" => "base.txt", "append_file" => "append.txt"},
        "tools" => "coding",
        "skill_dirs" => ["skills"],
        "cleanup_grace_ms" => 5_000
      })
    )
  end

  defp bounds, do: %{"max_turns" => 8, "deadline_ms" => 600_000, "token_budget" => 10_000}

  defp role,
    do: %{"model" => "openai:child", "instructions_file" => "role.txt", "reasoning" => "default"}

  defp update(value, [], function), do: function.(value)
  defp update(value, path, function), do: update_in(value, path, function)
end
