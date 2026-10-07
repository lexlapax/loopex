Code.require_file("support/configured_genesis_helper.exs", __DIR__)

defmodule Loopex.RuntimeCreationOptionsTest do
  use ExUnit.Case, async: true

  alias Loopex.ConfiguredGenesisFixture, as: Captured
  alias Loopex.Runtime.CreationOptions
  alias Loopex.Runtime.Instructions
  alias Loopex.Runtime.SessionConfiguration
  alias Loopex.Runtime.SessionGenesis
  alias Loopex.Store
  alias LoopexProtocol.ToolDefinition

  @uint64_max 18_446_744_073_709_551_615
  @refusal {:error, :invalid_session_creation}

  setup do
    [definition] =
      Path.expand("../priv/vectors/artifact_read.v1.json", __DIR__)
      |> File.read!()
      |> JSON.decode!()
      |> Map.fetch!("vectors")
      |> Enum.map(& &1["definition"])

    first = Map.put(definition, "tool_id", "example.first")
    second = first |> Map.put("tool_id", "example.second") |> Map.put("name", "second_read")
    %{definitions: [first, second], defaults: defaults([first, second])}
  end

  test "normalization retains supplied presence, aliases and ordered tools without defaults" do
    input = %{"version" => 1, "configuration" => %{"model" => "alias:é"}, "tools" => ["z", "a"]}
    assert {:ok, %{options: ^input, instructions: nil}} = CreationOptions.normalize(input)
    assert {:ok, %{options: %{"version" => 1}, instructions: nil}} = normalize()
    assert {:ok, empty} = normalize(%{"tools" => []})
    assert empty.options == %{"version" => 1, "tools" => []}
    assert {:ok, nil} = CreationOptions.changes(elem(normalize(), 1))
  end

  test "closed options reject wrong versions, nulls and every host authority member" do
    forbidden =
      ~w(workspace state_root runtime model_module model_options provider_bindings credentials
                   tool_definitions registry cleanup_grace_ms policy_defer_mode helper_roles tracing
                   artifact_read genesis_version initial_configuration)

    for input <-
          [
            nil,
            [],
            %{},
            %{version: 1},
            %{"version" => 1.0},
            %{"version" => "1"},
            %{"version" => nil},
            %{"version" => 0},
            %{"version" => 2}
          ] ++
            Enum.map(forbidden, &%{"version" => 1, &1 => nil}) do
      assert CreationOptions.normalize(input) == @refusal
    end
  end

  test "configuration uses the existing closed mutable domain and native uint64 quantities" do
    for key <- ~w(max_tokens context_token_budget system_class_tokens),
        value <- [1, @uint64_max] do
      assert {:ok, capture} = normalize(%{"configuration" => %{key => value}})
      assert capture.options["configuration"] == %{key => value}
    end

    for key <- ~w(max_tokens context_token_budget system_class_tokens),
        value <- [0, -1, @uint64_max + 1, "1", "01", 1.0, nil] do
      assert normalize(%{"configuration" => %{key => value}}) == @refusal
    end

    for configuration <-
          [
            nil,
            [],
            %{},
            %{"model" => ""},
            %{"model" => <<255>>},
            %{"model" => nil},
            %{"configuration_version" => 1},
            %{"budget_origins" => %{}},
            %{"model_capabilities" => %{}},
            %{"provider_mapping" => %{}},
            %{"maintenance" => %{}},
            %{max_tokens: 1}
          ] do
      assert normalize(%{"configuration" => configuration}) == @refusal
    end
  end

  test "all five authored reasoning levels survive without capability resolution" do
    for level <- ~w(default none low medium high) do
      assert {:ok, capture} = normalize(%{"configuration" => %{"reasoning" => level}})
      assert capture.options["configuration"]["reasoning"] == level
    end

    for level <- [nil, :high, "", "HIGH", "ultra"] do
      assert normalize(%{"configuration" => %{"reasoning" => level}}) == @refusal
    end
  end

  test "instructions preserve exact sections but options retain only their descriptor" do
    raw = instructions(" A\n", "é", "Appendix\n")
    assert {:ok, captured} = Instructions.capture(raw)
    assert {:ok, capture} = normalize(%{"configuration" => %{"instructions" => raw}})
    assert capture.instructions == captured

    assert capture.options["configuration"]["instructions"] ==
             Map.take(captured, ~w(version digest))

    assert {:ok, %{"instructions" => ^captured}} = CreationOptions.changes(capture)
    refute Map.has_key?(capture.options["configuration"]["instructions"], "base")
    assert normalize(%{"configuration" => %{"instructions" => captured}}) == @refusal
  end

  test "instruction byte boundaries and invalid UTF8 are delegated to the shared capture" do
    valid =
      instructions(
        String.duplicate("b", 32_768),
        String.duplicate("é", 2_048),
        String.duplicate("a", 16_384)
      )

    assert {:ok, _capture} = normalize(%{"configuration" => %{"instructions" => valid}})

    for raw <-
          [
            Map.put(valid, "base", String.duplicate("b", 32_769)),
            Map.put(valid, "environment", String.duplicate("é", 2_049)),
            Map.put(valid, "appendix", String.duplicate("a", 16_385)),
            Map.put(valid, "version", String.duplicate("v", 65)),
            Map.put(valid, "base", ""),
            Map.put(valid, "environment", <<255>>),
            Map.put(valid, "extra", ""),
            Map.delete(valid, "appendix")
          ] do
      assert normalize(%{"configuration" => %{"instructions" => raw}}) == @refusal
    end
  end

  test "tool names have exact ASCII bounds, uniqueness and the 1024 admission cap" do
    valid = Enum.map(1..1_024, &("t" <> Integer.to_string(&1)))
    assert {:ok, _} = normalize(%{"tools" => valid})
    assert {:ok, _} = normalize(%{"tools" => [String.duplicate("a", 64)]})

    for tools <-
          [
            nil,
            %{},
            ["a", "a"],
            [""],
            ["A"],
            ["1a"],
            ["a-b"],
            ["é"],
            [<<255>>],
            [String.duplicate("a", 65)],
            [:read],
            ["read\n"],
            ["read" | :tail],
            valid ++ ["one_more"]
          ] do
      assert normalize(%{"tools" => tools}) == @refusal
    end
  end

  test "default, subset, reordered and empty selections retain exact captured generations",
       fixture do
    [first, second] = fixture.definitions

    for {input, expected} <-
          [
            {%{}, [first, second]},
            {%{"tools" => ["second_read", "read"]}, [second, first]},
            {%{"tools" => ["read"]}, [first]},
            {%{"tools" => []}, []}
          ] do
      assert {:ok, capture} = normalize(input)
      assert {:ok, baseline} = CreationOptions.baseline(capture, fixture.defaults)
      assert baseline["tool_selection"]["definitions"] == expected
      assert baseline["tool_selection"]["names"] == names(expected)
      assert baseline["options"] == %{}
      assert baseline["initial_configuration"] == fixture.defaults["initial_configuration"]
      assert {:ok, genesis} = CreationOptions.initial_genesis(capture, baseline, :captured)
      assert genesis["options"] == capture.options
      assert CreationOptions.reconstruct(genesis) == {:ok, capture}
    end
  end

  test "unknown names cannot select a definition outside the captured default set", fixture do
    assert {:ok, capture} = normalize(%{"tools" => ["outside"]})
    assert CreationOptions.baseline(capture, fixture.defaults) == @refusal
    [definition | _] = fixture.definitions
    outside = definition |> Map.put("name", "outside") |> Map.put("tool_id", "example.outside")
    assert ToolDefinition.valid?(outside)
    refute outside in fixture.defaults["tool_selection"]["definitions"]
    assert CreationOptions.baseline(capture, fixture.defaults) == @refusal
  end

  test "ambiguous defaults, mismatched generations and extra host fields refuse", fixture do
    assert {:ok, capture} = normalize()
    [first, second] = fixture.definitions

    for invalid <-
          [
            nil,
            %{},
            Map.put(fixture.defaults, "registry", %{}),
            put_in(fixture.defaults, ["tool_selection", "definitions"], [first, first]),
            put_in(fixture.defaults, ["tool_selection", "definitions"], [
              first,
              Map.put(second, "name", "read")
            ]),
            put_in(fixture.defaults, ["tool_selection", "names", "read", "tool_version"], "99"),
            put_in(fixture.defaults, ["initial_configuration", "configuration_version"], 2)
          ] do
      assert CreationOptions.baseline(capture, invalid) == @refusal
    end
  end

  test "verified alias candidate is rebased by changing only configuration version", fixture do
    input = %{
      "tools" => ["second_read"],
      "configuration" => %{"model" => "alias", "max_tokens" => 512}
    }

    assert {:ok, capture} = normalize(input)
    assert {:ok, baseline} = CreationOptions.baseline(capture, fixture.defaults)
    next = candidate(capture, baseline, "canonical:new")
    assert next["configuration_version"] == 2
    assert {:ok, genesis} = CreationOptions.initial_genesis(capture, baseline, next)
    assert genesis["initial_configuration"] == Map.put(next, "configuration_version", 1)
    assert genesis["initial_configuration"]["model"] == "canonical:new"
    assert genesis["options"]["configuration"]["model"] == "alias"

    assert Map.drop(genesis, ["options", "initial_configuration"]) ==
             Map.drop(baseline, ["options", "initial_configuration"])

    assert SessionGenesis.normalize(genesis) == {:ok, genesis}
    assert CreationOptions.reconstruct(genesis) == {:ok, capture}
  end

  test "candidate cannot retarget omitted model or alter other authored and omitted fields",
       fixture do
    assert {:ok, capture} = normalize(%{"configuration" => %{"max_tokens" => 512}})
    assert {:ok, baseline} = CreationOptions.baseline(capture, fixture.defaults)
    next = candidate(capture, baseline)

    retargeted =
      next |> Map.put("model", "another") |> put_in(["model_capabilities", "model"], "another")

    for invalid <-
          [
            nil,
            :captured,
            %{},
            retargeted,
            Map.put(next, "max_tokens", 513),
            Map.put(next, "configuration_version", 1),
            Map.put(next, "configuration_version", 3),
            Map.put(next, "extra", true),
            Map.delete(next, "provider_mapping"),
            put_in(next, ["budget_origins", "system_class_tokens"], "legacy_default")
          ] do
      assert CreationOptions.initial_genesis(capture, baseline, invalid) == @refusal
    end
  end

  test "default-only and tool-only creation cannot accept a supplied configuration candidate",
       fixture do
    for input <- [%{}, %{"tools" => []}] do
      assert {:ok, capture} = normalize(input)
      assert {:ok, baseline} = CreationOptions.baseline(capture, fixture.defaults)
      assert {:ok, _genesis} = CreationOptions.initial_genesis(capture, baseline, :captured)

      assert CreationOptions.initial_genesis(capture, baseline, baseline["initial_configuration"]) ==
               @refusal

      assert CreationOptions.initial_genesis(
               capture,
               Map.put(baseline, "options", %{"version" => 1}),
               :captured
             ) == @refusal
    end
  end

  test "the baseline and prepared configuration retain strict selected-tool system budgets",
       fixture do
    assert {:ok, capture} = normalize()
    too_small = put_in(fixture.defaults, ["initial_configuration", "system_class_tokens"], 1)
    assert CreationOptions.baseline(capture, too_small) == @refusal
    assert {:ok, authored} = normalize(%{"configuration" => %{"system_class_tokens" => 1}})
    assert {:ok, baseline} = CreationOptions.baseline(authored, fixture.defaults)
    assert {:ok, changes} = CreationOptions.changes(authored)

    assert SessionConfiguration.update(
             baseline["initial_configuration"],
             changes,
             baseline["initial_configuration"]["model_capabilities"],
             baseline["initial_configuration"]["provider_mapping"],
             fixture.definitions
           ) ==
             {:error, :invalid_session_configuration}

    assert CreationOptions.initial_genesis(authored, baseline, %{}) == @refusal
  end

  test "replay authenticates the retained instruction descriptor and complete configuration",
       fixture do
    raw = instructions("New base", "New environment", "Appendix")
    assert {:ok, capture} = normalize(%{"configuration" => %{"instructions" => raw}})
    assert {:ok, baseline} = CreationOptions.baseline(capture, fixture.defaults)

    assert {:ok, genesis} =
             CreationOptions.initial_genesis(capture, baseline, candidate(capture, baseline))

    assert CreationOptions.reconstruct(genesis) == {:ok, capture}

    for invalid <-
          [
            put_in(
              genesis,
              ["options", "configuration", "instructions", "digest"],
              String.duplicate("0", 64)
            ),
            put_in(genesis, ["options", "configuration", "instructions", "version"], "other"),
            put_in(genesis, ["options", "configuration", "instructions", "extra"], true),
            put_in(genesis, ["initial_configuration", "instructions", "base"], "changed")
          ] do
      assert CreationOptions.reconstruct(invalid) == @refusal
    end
  end

  test "rendering collisions retain distinct exact section identities", fixture do
    left = instructions("A\n\nB", "", "")
    right = instructions("A", "B", "")
    assert {:ok, a} = normalize(%{"configuration" => %{"instructions" => left}})
    assert {:ok, b} = normalize(%{"configuration" => %{"instructions" => right}})
    assert a.options == b.options
    assert a.instructions["digest"] == b.instructions["digest"]
    refute a == b
    assert {:ok, baseline} = CreationOptions.baseline(a, fixture.defaults)
    assert {:ok, genesis} = CreationOptions.initial_genesis(a, baseline, candidate(a, baseline))
    assert CreationOptions.reconstruct(genesis) == {:ok, a}
    refute CreationOptions.reconstruct(genesis) == {:ok, b}
  end

  test "rehashed changed sections reconstruct a different identity rather than blessing a retry",
       fixture do
    assert {:ok, capture} =
             normalize(%{"configuration" => %{"instructions" => instructions("First", "", "")}})

    assert {:ok, baseline} = CreationOptions.baseline(capture, fixture.defaults)

    assert {:ok, genesis} =
             CreationOptions.initial_genesis(capture, baseline, candidate(capture, baseline))

    assert {:ok, changed} = Instructions.capture(instructions("Second", "", ""))

    altered =
      genesis
      |> put_in(["initial_configuration", "instructions"], changed)
      |> put_in(
        ["options", "configuration", "instructions"],
        Map.take(changed, ~w(version digest))
      )

    assert {:ok, other} = CreationOptions.reconstruct(altered)
    refute other == capture
  end

  test "retained supplied presence and tool order remain different authored identities",
       fixture do
    assert {:ok, omitted} = normalize()
    assert {:ok, explicit} = normalize(%{"tools" => ["read", "second_read"]})
    assert {:ok, baseline} = CreationOptions.baseline(omitted, fixture.defaults)
    assert {:ok, genesis} = CreationOptions.initial_genesis(omitted, baseline, :captured)
    assert CreationOptions.reconstruct(genesis) == {:ok, omitted}
    refute CreationOptions.reconstruct(genesis) == {:ok, explicit}
    assert {:ok, reordered} = normalize(%{"tools" => ["second_read", "read"]})
    assert reordered != explicit
    assert {:ok, equal_value} = normalize(%{"configuration" => %{"model" => "scripted:v1"}})
    assert equal_value != omitted
    assert {:ok, alias_name} = normalize(%{"configuration" => %{"model" => "alias"}})
    assert alias_name != equal_value
  end

  test "forged captures cannot substitute instruction content, descriptors or extra members" do
    assert {:ok, capture} =
             normalize(%{"configuration" => %{"instructions" => instructions("Base", "", "")}})

    for invalid <-
          [
            Map.put(capture, :extra, true),
            %{capture | instructions: nil},
            put_in(capture, [:instructions, "base"], "tampered"),
            put_in(capture, [:options, "configuration", "instructions", "digest"], "bad"),
            %{options: %{"version" => 1}, instructions: capture.instructions}
          ] do
      assert CreationOptions.changes(invalid) == @refusal
    end
  end

  test "retained closed authored grammar and explicit selection are checked independently",
       fixture do
    assert {:ok, capture} = normalize(%{"tools" => ["read"]})
    assert {:ok, baseline} = CreationOptions.baseline(capture, fixture.defaults)
    assert {:ok, genesis} = CreationOptions.initial_genesis(capture, baseline, :captured)

    for invalid <-
          [
            put_in(genesis, ["options", "version"], 2),
            put_in(genesis, ["options", "unknown"], true),
            put_in(genesis, ["options", "tools"], ["second_read"]),
            put_in(genesis, ["options", "configuration"], %{}),
            Map.put(genesis, :kind, "session_genesis_v2"),
            put_in(genesis, ["initial_configuration", "configuration_version"], 2)
          ] do
      assert CreationOptions.reconstruct(invalid) == @refusal
    end
  end

  test "replay refuses supplied settings that contradict retained values or explicit origins",
       fixture do
    assert {:ok, capture} = normalize(%{"configuration" => %{"max_tokens" => 512}})
    assert {:ok, baseline} = CreationOptions.baseline(capture, fixture.defaults)

    assert {:ok, genesis} =
             CreationOptions.initial_genesis(capture, baseline, candidate(capture, baseline))

    for invalid <- [
          put_in(genesis, ["options", "configuration", "max_tokens"], 513),
          put_in(genesis, ["options", "configuration", "reasoning"], "none"),
          put_in(genesis, ["options", "configuration", "context_token_budget"], 8_192)
        ] do
      assert CreationOptions.reconstruct(invalid) == @refusal
    end

    assert {:ok, explicit} = normalize(%{"configuration" => %{"context_token_budget" => 8_192}})
    next = candidate(explicit, baseline)
    assert {:ok, exact} = CreationOptions.initial_genesis(explicit, baseline, next)
    assert CreationOptions.reconstruct(exact) == {:ok, explicit}

    altered =
      put_in(
        exact,
        ["initial_configuration", "budget_origins", "context_token_budget"],
        "unknown_window"
      )

    assert SessionGenesis.normalize(altered) == {:ok, altered}
    assert CreationOptions.reconstruct(altered) == @refusal
  end

  test "the complete genesis byte ceiling is inclusive and instruction-free alias bytes count" do
    selected = defaults([])
    assert {:ok, small} = normalize(%{"configuration" => %{"model" => "x"}})
    assert {:ok, baseline} = CreationOptions.baseline(small, selected)
    next = candidate(small, baseline)
    assert {:ok, original} = CreationOptions.initial_genesis(small, baseline, next)
    assert {:ok, _, overhead} = Store.normalize_and_measure_item(:record, original)

    for wanted <- [65_535, 65_536, 65_537] do
      authored = %{
        "version" => 1,
        "configuration" => %{"model" => String.duplicate("x", wanted - overhead + 1)}
      }

      assert {:ok, capture} = CreationOptions.normalize(authored)
      expected = Map.put(original, "options", capture.options)
      assert {:ok, _, ^wanted} = Store.normalize_and_measure_item(:record, expected)
      result = CreationOptions.initial_genesis(capture, baseline, next)

      assert result ==
               if(wanted <= 65_536,
                 do: {:ok, expected},
                 else: {:error, :session_configuration_too_large}
               )
    end
  end

  defp normalize(extra \\ %{}), do: CreationOptions.normalize(Map.put(extra, "version", 1))

  defp instructions(base, environment, appendix),
    do: %{
      "version" => "host.v1",
      "base" => base,
      "environment" => environment,
      "appendix" => appendix
    }

  defp defaults(definitions) do
    Captured.genesis(definitions) |> Map.drop([:kind, "options"])
  end

  defp names(definitions) do
    Map.new(definitions, fn definition ->
      {id, version, digest} = ToolDefinition.generation(definition)

      {definition["name"],
       %{"tool_id" => id, "tool_version" => version, "definition_digest" => digest}}
    end)
  end

  defp candidate(capture, baseline, canonical \\ nil) do
    {:ok, changes} = CreationOptions.changes(capture)
    current = baseline["initial_configuration"]
    model = canonical || current["model"]

    effective =
      if Map.has_key?(changes, "model"), do: Map.put(changes, "model", model), else: changes

    capabilities = Map.put(current["model_capabilities"], "model", model)

    {:ok, next} =
      SessionConfiguration.update(
        current,
        effective,
        capabilities,
        current["provider_mapping"],
        baseline["tool_selection"]["definitions"]
      )

    next
  end
end
