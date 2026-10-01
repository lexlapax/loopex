defmodule Loopex.Runtime.SessionGenesisV3Test do
  use ExUnit.Case, async: true

  alias Loopex.Bounds
  alias Loopex.Runtime.Instructions
  alias Loopex.Runtime.SessionConfiguration
  alias Loopex.Runtime.SessionGenesis
  alias Loopex.Runtime.SessionState
  alias Loopex.Store
  alias LoopexProtocol.Canonical
  alias LoopexProtocol.ToolDefinition

  setup do
    manifest =
      Path.expand("../priv/vectors/artifact_read.v1.json", __DIR__)
      |> File.read!()
      |> JSON.decode!()

    [legacy, range] = Enum.map(manifest["vectors"], & &1["definition"])
    %{legacy: legacy, range: range}
  end

  test "v3 resolve derives the capability and retained normalization is idempotent", fixture do
    for definitions <- [[], [fixture.legacy], [fixture.range]], mode <- ["admit", "refuse"] do
      input = input(definitions, configuration(), mode)
      assert {:ok, genesis} = SessionGenesis.resolve(%{tenant: "a"}, input)
      assert genesis["options"] == %{"tenant" => "a"}
      assert genesis["policy_defer_mode"] == mode
      assert genesis["initial_configuration"] == configuration()
      assert genesis["tool_selection"]["names"] == names(definitions)
      assert SessionGenesis.normalize(genesis) == {:ok, genesis}

      if definitions == [fixture.range] do
        assert genesis["tool_selection"]["artifact_read"]["definition_digest"] ==
                 ToolDefinition.definition_digest(fixture.range)
      else
        assert is_nil(genesis["tool_selection"]["artifact_read"])
      end
    end
  end

  test "closed resolver input never accepts a caller capability or inferred settings", fixture do
    valid = input([fixture.range])

    for changed <-
          Enum.map(Map.keys(valid), &Map.delete(valid, &1)) ++
            [
              Map.put(valid, :extra, true),
              put_in(valid, [:tool_selection, "artifact_read"], nil),
              put_in(valid, [:tool_selection, "extra"], true),
              %{valid | policy_defer_mode: "default"},
              %{valid | runtime_configuration: %{}},
              %{valid | initial_configuration: %{}},
              %{valid | tool_selection: nil}
            ] do
      assert SessionGenesis.resolve(%{}, changed) == {:error, :invalid_session_genesis}
    end
  end

  test "pure replay retains complete v3 settings and selection without startup defaults",
       fixture do
    for mode <- ["admit", "refuse"] do
      assert {:ok, genesis} =
               SessionGenesis.resolve(%{}, input([fixture.range], configuration(), mode))

      record = %{journal_version: 1, owner_epoch: 0, owner_incarnation_id: nil, payload: genesis}
      assert {:ok, recovered} = SessionState.recover("session", [record], [])
      assert recovered.configuration == genesis["initial_configuration"]
      assert recovered.tool_selection == genesis["tool_selection"]
      assert recovered.policy_defer_mode == mode
      assert recovered.cleanup_grace_ms == 5_000

      bad = %{record | payload: put_in(genesis, ["tool_selection", "artifact_read"], nil)}
      assert SessionState.recover("session", [bad], []) == {:error, :invalid_session_genesis}
    end
  end

  test "complete retained key sets reject added or missing truth", fixture do
    assert {:ok, genesis} = SessionGenesis.resolve(%{}, input([fixture.range]))

    for changed <-
          Enum.map(Map.keys(genesis), &Map.delete(genesis, &1)) ++
            [
              Map.put(genesis, "extra", true),
              put_in(genesis, ["tool_selection", "artifact_read"], nil),
              put_in(genesis, ["tool_selection", "extra"], true),
              put_in(genesis, ["runtime_configuration", "cleanup_grace_ms"], 0),
              put_in(genesis, ["policy_defer_mode"], "allow")
            ] do
      assert SessionGenesis.normalize(changed) == {:error, :invalid_session_genesis}
    end
  end

  test "tool names are a bijection to exact retained generations", fixture do
    valid = input([fixture.legacy])
    other = %{fixture.legacy | "tool_id" => "example.read", "name" => "other_read"}

    for selection <- [
          %{"definitions" => [fixture.legacy], "names" => %{}},
          %{"definitions" => [], "names" => names([fixture.legacy])},
          %{
            "definitions" => [fixture.legacy, fixture.legacy],
            "names" => names([fixture.legacy])
          },
          %{"definitions" => [fixture.legacy, fixture.range], "names" => names([fixture.range])},
          %{"definitions" => [fixture.legacy], "names" => names([other])},
          put_in(valid.tool_selection, ["names", "read", "tool_version"], "9.0.0"),
          put_in(valid.tool_selection, ["names", "read", "extra"], true),
          %{
            "definitions" => [Map.put(fixture.legacy, "process", self())],
            "names" => names([fixture.legacy])
          }
        ] do
      assert SessionGenesis.resolve(%{}, %{valid | tool_selection: selection}) ==
               {:error, :invalid_session_genesis}
    end

    assert {:ok, _} = SessionGenesis.resolve(%{}, input([fixture.legacy, other]))
  end

  test "configuration has a closed mandatory shape and captured instructions" do
    valid = configuration()
    assert SessionConfiguration.validate(valid, []) == :ok

    for changed <-
          Enum.map(Map.keys(valid), &Map.delete(valid, &1)) ++
            [
              Map.put(valid, "extra", true),
              %{valid | "model" => ""},
              %{valid | "configuration_version" => 0},
              %{valid | "instructions" => put_in(valid["instructions"], ["base"], "changed")},
              %{valid | "max_tokens" => 0},
              %{valid | "context_token_budget" => 0},
              %{valid | "system_class_tokens" => 0},
              %{valid | "system_class_tokens" => 8_193},
              %{valid | "model_capabilities" => %{}}
            ] do
      assert SessionConfiguration.validate(changed, []) ==
               {:error, :invalid_session_configuration}
    end
  end

  test "known window origin subtracts the reply reserve exactly once" do
    valid = known_configuration()
    assert SessionConfiguration.validate(valid, []) == :ok

    for changed <- [
          %{valid | "context_token_budget" => 7_167},
          %{valid | "context_token_budget" => 7_169},
          put_in(valid, ["model_capabilities", "context_window"], 1_024),
          put_in(valid, ["model_capabilities", "output_limit"], 1_023),
          put_in(valid, ["budget_origins", "context_token_budget"], "unknown_window")
        ] do
      assert SessionConfiguration.validate(changed, []) ==
               {:error, :invalid_session_configuration}
    end

    explicit = put_in(valid, ["budget_origins", "context_token_budget"], "explicit")
    assert SessionConfiguration.validate(%{explicit | "context_token_budget" => 7_167}, []) == :ok

    assert SessionConfiguration.validate(%{explicit | "context_token_budget" => 7_169}, []) ==
             {:error, :invalid_session_configuration}
  end

  test "unknown window fallback is 8192 and explicit input proves no capacity" do
    valid = configuration()
    assert SessionConfiguration.validate(valid, []) == :ok

    assert SessionConfiguration.validate(%{valid | "context_token_budget" => 7_168}, []) ==
             {:error, :invalid_session_configuration}

    explicit = put_in(valid, ["budget_origins", "context_token_budget"], "explicit")

    assert SessionConfiguration.validate(%{explicit | "context_token_budget" => 10_000}, []) ==
             :ok

    assert SessionConfiguration.validate(
             put_in(valid, ["budget_origins", "context_token_budget"], "model_window"),
             []
           ) ==
             {:error, :invalid_session_configuration}
  end

  test "capability metadata and mapping fit their combined canonical 2-KiB budget" do
    for wanted <- [2_047, 2_048, 2_049] do
      candidate = padded_metadata(wanted)

      assert byte_size(
               Canonical.encode(Map.take(candidate, ~w(model_capabilities provider_mapping)))
             ) == wanted

      result = SessionConfiguration.validate(candidate, [])

      assert result ==
               if(wanted <= 2_048, do: :ok, else: {:error, :invalid_session_configuration})
    end
  end

  test "metadata source identity, limits and verified level subset are bounded and closed" do
    valid = configuration()

    for {key, value} <- [
          {"model", "different"},
          {"context_window", 0},
          {"output_limit", -1},
          {"reasoning_levels", ["default", "default"]},
          {"reasoning_levels", ["ultra"]},
          {"source_revision", String.duplicate("é", 65)},
          {"source_digest", String.duplicate("A", 64)},
          {"source_digest", "abc"},
          {"extra", true}
        ] do
      changed = put_in(valid, ["model_capabilities", key], value)

      assert SessionConfiguration.validate(changed, []) ==
               {:error, :invalid_session_configuration}
    end

    assert SessionConfiguration.validate(
             put_in(valid, ["model_capabilities", "source_revision"], self()),
             []
           ) ==
             {:error, :invalid_session_configuration}
  end

  test "unknown capability requires default and the complete literal generic descriptor" do
    valid = configuration()

    for changed <- [
          %{valid | "reasoning" => "low"},
          put_in(valid, ["provider_mapping", "continuation_required"], true),
          put_in(valid, ["provider_mapping", "canonical_terminal_tool_history"], true),
          put_in(valid, ["provider_mapping", "thinking_disabled"], true),
          put_in(valid, ["provider_mapping", "thinking"], %{"mode" => "disabled"}),
          put_in(valid, ["provider_mapping", "mapping_revision"], "registered.v1")
        ] do
      assert SessionConfiguration.validate(changed, []) ==
               {:error, :invalid_session_configuration}
    end

    known = put_in(valid, ["model_capabilities", "reasoning_levels"], ["none", "low"])

    assert SessionConfiguration.validate(%{known | "reasoning" => "none"}, []) ==
             {:error, :invalid_session_configuration}

    known = put_in(known, ["provider_mapping", "mapping_revision"], "fixture.registered.v1")
    assert SessionConfiguration.validate(known, []) == {:error, :invalid_session_configuration}
    assert SessionConfiguration.validate(%{known | "reasoning" => "none"}, []) == :ok
  end

  test "provider mapping variants are closed and native semantics remain host-owned" do
    known = put_in(configuration(), ["model_capabilities", "reasoning_levels"], ["default"])
    known = put_in(known, ["provider_mapping", "mapping_revision"], "fixture.registered.v1")

    for thinking <- [
          %{"mode" => "omitted"},
          %{"mode" => "disabled"},
          %{"mode" => "manual", "budget_tokens" => 1_024},
          %{"mode" => "adaptive", "effort" => "low", "display" => "summarized"}
        ] do
      assert SessionConfiguration.validate(
               put_in(known, ["provider_mapping", "thinking"], thinking),
               []
             ) == :ok
    end

    for thinking <- [
          %{"mode" => "omitted", "extra" => true},
          %{"mode" => "manual", "budget_tokens" => 0},
          %{"mode" => "adaptive", "effort" => "ultra", "display" => "summarized"},
          %{"mode" => "adaptive", "effort" => "high", "display" => "hidden"}
        ] do
      assert SessionConfiguration.validate(
               put_in(known, ["provider_mapping", "thinking"], thinking),
               []
             ) ==
               {:error, :invalid_session_configuration}
    end

    for {key, value} <- [
          {"extra", true},
          {"continuation_required", "false"},
          {"renderer_revision", String.duplicate("r", 129)}
        ] do
      assert SessionConfiguration.validate(put_in(known, ["provider_mapping", key], value), []) ==
               {:error, :invalid_session_configuration}
    end
  end

  test "strict system ceiling charges exact instructions plus selected model-facing schemas",
       fixture do
    valid = put_in(configuration(), ["budget_origins", "system_class_tokens"], "explicit")
    {:ok, text} = Instructions.render(valid["instructions"])
    base_cost = Bounds.estimate(Canonical.encode(%{"role" => "system", "content" => text}))
    tool_cost = Bounds.estimate(Canonical.encode(ToolDefinition.model_facing(fixture.range)))
    cost = base_cost + tool_cost

    assert SessionConfiguration.validate(%{valid | "system_class_tokens" => cost + 1}, [
             fixture.range
           ]) == :ok

    assert SessionConfiguration.validate(%{valid | "system_class_tokens" => cost}, [fixture.range]) ==
             {:error, :invalid_session_configuration}

    assert SessionConfiguration.validate(%{valid | "system_class_tokens" => cost - 1}, [
             fixture.range
           ]) ==
             {:error, :invalid_session_configuration}

    assert SessionConfiguration.validate(%{valid | "system_class_tokens" => base_cost + 1}, []) ==
             :ok

    assert SessionConfiguration.validate(%{valid | "system_class_tokens" => base_cost + 1}, [
             fixture.range
           ]) ==
             {:error, :invalid_session_configuration}
  end

  test "complete v3 genesis admits the normalized record ceiling inclusively", fixture do
    assert {:ok, empty} = SessionGenesis.resolve(%{"padding" => ""}, input([fixture.range]))
    assert {:ok, _, overhead} = Store.normalize_and_measure_item(:record, empty)

    for wanted <- [65_535, 65_536, 65_537] do
      options = %{"padding" => String.duplicate("g", wanted - overhead)}
      payload = %{empty | "options" => options}
      assert {:ok, _, ^wanted} = Store.normalize_and_measure_item(:record, payload)

      expected =
        if wanted <= 65_536, do: {:ok, payload}, else: {:error, :session_configuration_too_large}

      assert SessionGenesis.normalize(payload) == expected
      assert SessionGenesis.resolve(options, input([fixture.range])) == expected
    end
  end

  defp configuration do
    %{
      "model" => "fixture:model.v1",
      "reasoning" => "default",
      "configuration_version" => 1,
      "instructions" => Instructions.legacy(),
      "max_tokens" => 1_024,
      "context_token_budget" => 8_192,
      "system_class_tokens" => 1_000,
      "budget_origins" => %{
        "context_token_budget" => "unknown_window",
        "system_class_tokens" => "legacy_default"
      },
      "model_capabilities" => %{
        "model" => "fixture:model.v1",
        "context_window" => nil,
        "output_limit" => nil,
        "reasoning_levels" => [],
        "source_revision" => "fixture.v1",
        "source_digest" => String.duplicate("0", 64)
      },
      "provider_mapping" => %{
        "mapping_revision" => "loopex.unregistered.default.v1",
        "renderer_revision" => "loopex.reqllm.canonical.v1",
        "continuation_required" => false,
        "canonical_terminal_tool_history" => false,
        "thinking_disabled" => false,
        "thinking" => %{"mode" => "omitted"}
      }
    }
  end

  defp known_configuration do
    configuration()
    |> put_in(["model_capabilities", "context_window"], 8_192)
    |> put_in(["model_capabilities", "output_limit"], 1_024)
    |> put_in(["budget_origins", "context_token_budget"], "model_window")
    |> Map.put("context_token_budget", 7_168)
  end

  defp padded_metadata(wanted) do
    base = configuration()
    bytes = byte_size(Canonical.encode(Map.take(base, ~w(model_capabilities provider_mapping))))
    additional = wanted - bytes
    model = base["model"] <> String.duplicate("m", additional)

    base
    |> Map.put("model", model)
    |> put_in(["model_capabilities", "model"], model)
  end

  defp input(definitions, configuration \\ configuration(), mode \\ "admit") do
    %{
      genesis_version: "session_genesis_v3",
      runtime_configuration: %{"cleanup_grace_ms" => 5_000},
      initial_configuration: configuration,
      policy_defer_mode: mode,
      tool_selection: %{"definitions" => definitions, "names" => names(definitions)}
    }
  end

  defp names(definitions) do
    Map.new(definitions, fn definition ->
      {id, version, digest} = ToolDefinition.generation(definition)

      {definition["name"],
       %{"tool_id" => id, "tool_version" => version, "definition_digest" => digest}}
    end)
  end
end
