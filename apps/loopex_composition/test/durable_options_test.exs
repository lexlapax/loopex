defmodule LoopexComposition.DurableOptionsTest do
  use ExUnit.Case, async: false
  @moduletag capture_log: true

  @edge :"$loopex_composition_edge_observer"
  @effect :"$loopex_composition_effect_observer"
  @entries [:start, :with_runtime, :start_edges]
  @uint64 18_446_744_073_709_551_615
  @ids ~w(loopex.read loopex.write loopex.edit loopex.bash loopex.grep loopex.find loopex.ls)
  @generations Enum.sort(
                 Enum.map(@ids, fn id ->
                   {id,
                    if(id in ~w(loopex.read loopex.grep loopex.find loopex.ls),
                      do: "1.1.0",
                      else: "1.0.0"
                    )}
                 end)
               )

  defmodule Policy do
    @moduledoc false
    @behaviour Loopex.Policy
    @impl true
    def decide(_), do: {:deny, :test}
  end

  setup do
    for key <- [@edge, @effect] do
      Process.put(key, fn module, function, _arguments ->
        flunk("invalid options started #{inspect(module)}.#{function}")
      end)
    end

    :ok
  end

  test "all durable entrypoints refuse a malformed model before effects" do
    for entry <- [:start, :with_runtime, :start_edges] do
      assert refusal(entry, model: "missing-colon") ==
               {:error, {:invalid_composition_option, :model}}
    end
  end

  test "all durable entrypoints validate maintenance instructions before effects" do
    block = %{"version" => "host.v1", "body" => "Keep exact bytes 猫\n"}

    for entry <- @entries,
        invalid <- [
          %{},
          Map.put(block, "extra", true),
          %{block | "version" => "bad version"},
          %{block | "body" => String.duplicate("x", 2049)}
        ] do
      assert refusal(entry, maintenance_instructions: invalid) ==
               {:error, :maintenance_instructions_invalid}
    end
  end

  test "explicit maintenance instructions reach every real durable constructor" do
    for entry <- @entries, body <- ["Keep exact bytes 猫\n", String.duplicate("x", 2048)] do
      block = %{"version" => "host.v1", "body" => body}
      assert capture(entry, maintenance_instructions: block)[:maintenance_instructions] == block
      assert capture(entry, maintenance_instructions: nil)[:maintenance_instructions] == nil
    end
  end

  test "an improper active selection is a refusal rather than an exception" do
    for entry <- [:start, :with_runtime, :start_edges] do
      assert refusal(entry, active_tools: ["loopex.read" | :tail]) ==
               {:error, {:invalid_composition_option, :active_tools}}
    end
  end

  test "closed model grammar distinguishes malformed and unsupported providers" do
    for entry <- @entries do
      for value <- [
            nil,
            :model,
            "",
            ":id",
            "openai:",
            <<255>>,
            "openai:" <> String.duplicate("x", 506)
          ] do
        assert refusal(entry, model: value) == {:error, {:invalid_composition_option, :model}}
      end

      assert refusal(entry, model: "ollama:id:variant") ==
               {:error, {:composition, :durable_model_unsupported}}

      for value <- ["other:id", "OpenAI:id", " openai:id"] do
        assert refusal(entry, model: value) == {:error, {:composition, :unknown_provider}}
      end
    end
  end

  test "all bound members enforce the positive uint64 grammar before effects" do
    for entry <- @entries do
      for value <- [nil, [], %{other: 1}, %{"max_turns" => 1}] do
        assert refusal(entry, bounds: value) == {:error, {:invalid_composition_option, :bounds}}
      end

      for key <- [:max_turns, :token_budget, :deadline_ms],
          n <- [0, -1, 1.0, "1", nil, @uint64 + 1] do
        assert refusal(entry, bounds: %{key => n}) ==
                 {:error, {:invalid_composition_option, :bounds}}
      end
    end
  end

  test "sampling has exactly one bounded string key" do
    for entry <- @entries,
        value <- [
          nil,
          [],
          %{},
          %{max_tokens: 1},
          %{"max_tokens" => 1, "temperature" => 0},
          %{"max_tokens" => 0},
          %{"max_tokens" => -1},
          %{"max_tokens" => 1.0},
          %{"max_tokens" => 1_000_001}
        ] do
      assert refusal(entry, sampling: value) == {:error, {:invalid_composition_option, :sampling}}
    end
  end

  test "active ids are exact unique strings" do
    for entry <- @entries,
        value <- [
          nil,
          :none,
          ["read"],
          [:"loopex.read"],
          ["loopex.read", "loopex.read"],
          @ids ++ ["loopex.read"]
        ] do
      assert refusal(entry, active_tools: value) ==
               {:error, {:invalid_composition_option, :active_tools}}
    end
  end

  test "first duplicate is the value validated" do
    for entry <- @entries,
        {key, invalid, valid} <- [
          {:model, "bad", "openai:id"},
          {:bounds, nil, %{}},
          {:sampling, nil, %{"max_tokens" => 1}},
          {:active_tools, nil, []}
        ] do
      assert refusal(entry, [{key, invalid}, {key, valid}]) ==
               {:error, {:invalid_composition_option, key}}
    end
  end

  test "adjacent validation stages preserve released precedence" do
    invalid = [
      policy: nil,
      state_root: nil,
      workspace: nil,
      runtime_id: nil,
      recover_stale_writer: nil,
      artifact_transfers: nil,
      provider_launch: nil,
      resource_manifest: :bad,
      model: "bad",
      bounds: nil,
      sampling: nil,
      active_tools: nil
    ]

    for entry <- @entries, [left, right] <- Enum.chunk_every(invalid, 2, 1, :discard) do
      {key, _} = left

      reason =
        if key == :policy, do: :host_policy_required, else: {:invalid_composition_option, key}

      assert refusal(entry, [left, right]) == {:error, reason}
    end

    for entry <- @entries do
      assert refusal(entry, model: "ollama:id", bounds: nil) ==
               {:error, {:composition, :durable_model_unsupported}}

      assert refusal(entry, model: "other:id", bounds: nil) ==
               {:error, {:composition, :unknown_provider}}
    end
  end

  test "workspace manifest validation precedes new model validation" do
    root =
      Path.join(
        System.tmp_dir!(),
        "loopex-options-manifest-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, ref} = LoopexComposition.WorkspaceIdentity.reference(root)
    {:ok, manifest} = LoopexComposition.ResourcePacks.discover(root, workspace_ref: ref)
    assert {:ok, _, _} = Loopex.ResourcePack.digest(manifest)

    for entry <- @entries do
      assert refusal(entry, resource_manifest: manifest, model: "bad") ==
               {:error, {:invalid_composition_option, :resource_manifest}}
    end
  end

  test "released outer shapes and edge-only stages remain unchanged" do
    assert {:error, :invalid_composition_options} = LoopexComposition.start(%{})

    assert {:error, :invalid_composition_options} =
             LoopexComposition.with_runtime(%{}, fn _ -> :ok end)

    assert {:error, :invalid_composition_options, %{}} = LoopexComposition.start_edges(%{})
    assert {:error, :invalid_composition_options, %{}} = LoopexComposition.start_edges([], %{})

    assert {:error, :invalid_composition_options, %{}} =
             LoopexComposition.start_edges([model: "bad"], interrupt: nil)

    assert {:error, {:invalid_composition_option, :credential_plane}, %{}} =
             LoopexComposition.start_edges(model: "bad")

    assert {:error, :host_policy_required, %{}} =
             LoopexComposition.start_edges(credential_plane: nil, model: "bad")
  end

  test "all 128 active-id subsets retain their selection with current read and search" do
    {:ok, seed} =
      LoopexComposition.DurableOptions.capture_genesis(
        [workspace: System.tmp_dir!(), active_tools: []],
        %{}
      )

    subsets = Enum.reduce(@ids, [[]], fn id, sets -> sets ++ Enum.map(sets, &[id | &1]) end)
    assert length(subsets) == 128

    for entry <- @entries, ids <- subsets do
      options = capture(entry, [active_tools: ids], {2_000, seed})
      assert options[:active_tools] == ids
      definitions = Enum.map(options[:tools], &{&1["tool_id"], &1["tool_version"]})

      assert Enum.sort(definitions) ==
               if(ids == [], do: [], else: @generations)

      assert Enum.filter(options[:tools], &(&1["tool_id"] == "loopex.read"))
             |> Enum.map(& &1["tool_version"]) == if(ids == [], do: [], else: ["1.1.0"])
    end
  end

  test "questions are registered only by explicit selection in every durable constructor" do
    question = LoopexProtocol.ToolDefinition.question_definition()

    for entry <- @entries, ids <- [["loopex.ask"], ["loopex.read", "loopex.ask"]] do
      options = capture(entry, active_tools: ids)
      assert options[:active_tools] == ids
      assert Enum.filter(options[:tools], &(&1["tool_id"] == "loopex.ask")) == [question]

      assert options[:tools]
             |> Enum.reject(&(&1["tool_id"] == "loopex.ask"))
             |> Enum.map(&{&1["tool_id"], &1["tool_version"]})
             |> Enum.sort() == @generations
    end

    for entry <- @entries do
      refute Enum.any?(capture(entry, [])[:tools], &(&1["tool_id"] == "loopex.ask"))

      assert refusal(entry, active_tools: ["loopex.ask", "loopex.ask"]) ==
               {:error, {:invalid_composition_option, :active_tools}}
    end
  end

  test "accepted model and numeric boundaries reach every real constructor" do
    for entry <- @entries do
      for model <- [
            "openai:x",
            "anthropic:x:y",
            "openrouter:x",
            "openai:" <> String.duplicate("x", 505),
            "openai:é"
          ] do
        assert capture(entry, model: model)[:model].model == model
      end

      for key <- [:max_turns, :token_budget, :deadline_ms], n <- [1, @uint64] do
        assert capture(entry, bounds: %{key => n})[:bounds] == %{key => n}
      end

      assert capture(entry, bounds: %{})[:bounds] == %{}

      for n <- [1, 1_000_000] do
        captured =
          capture(entry,
            model: "openai:unregistered-fixture",
            sampling: %{"max_tokens" => n}
          )

        refute Keyword.has_key?(captured, :sampling)
        assert captured[:session_creation_defaults]["initial_configuration"]["max_tokens"] == n
      end
    end
  end

  test "current host defaults bind the canonical model and explicit identities win" do
    for entry <- @entries do
      defaults = capture(entry, [])
      assert defaults[:model].model == "anthropic:claude-haiku-4-5-20251001"

      assert defaults[:session_creation_defaults]["initial_configuration"]["model"] ==
               defaults[:model].model

      assert defaults[:active_tools] == Enum.take(@ids, 4)
      refute Keyword.has_key?(defaults, :bounds)
      refute Keyword.has_key?(defaults, :sampling)
      assert defaults[:policy_identity] == %{"id" => inspect(Policy), "revision" => "0.2.0"}
      identity = %{"id" => "host", "revision" => "explicit"}
      assert capture(entry, policy_identity: identity)[:policy_identity] == identity
    end
  end

  test "every constructor captures selected tools, authored limits and host instructions before startup" do
    for entry <- @entries do
      options =
        capture(entry,
          model: "openai:unregistered-fixture",
          active_tools: ~w(loopex.read loopex.ask),
          sampling: %{"max_tokens" => 512},
          context_token_budget: 32_000,
          cleanup_grace_ms: 137
        )

      template = options[:session_creation_defaults]
      configuration = template["initial_configuration"]
      assert configuration["model"] == options[:model].model
      assert configuration["max_tokens"] == 512
      assert configuration["context_token_budget"] == 32_000
      assert configuration["budget_origins"]["context_token_budget"] == "explicit"
      assert template["runtime_configuration"] == %{"cleanup_grace_ms" => 137}
      assert template["policy_defer_mode"] == "admit"

      assert Enum.map(template["tool_selection"]["definitions"], & &1["tool_id"]) ==
               ~w(loopex.read loopex.ask)

      environment = JSON.decode!(configuration["instructions"]["environment"])
      assert environment["tool_profile"] == "read-only"
      assert Path.type(environment["workspace"]) == :absolute

      assert configuration["instructions"]["version"] == "loopex.reference.v1"

      assert Enum.sort(Map.keys(template)) ==
               ~w(initial_configuration policy_defer_mode runtime_configuration tool_selection)
    end
  end

  test "known model limits refuse an oversized reply reserve before constructor effects" do
    for entry <- @entries do
      assert creation_refusal(entry, sampling: %{"max_tokens" => 1_000_000}) ==
               {:error, :invalid_session_genesis}
    end
  end

  test "a selected tool set that exceeds the reference system ceiling refuses before effects" do
    for entry <- @entries do
      assert creation_refusal(entry, active_tools: @ids) == {:error, :invalid_session_genesis}
    end
  end

  test "valid first duplicates and unknown keys preserve released behavior" do
    for entry <- @entries do
      opts =
        capture(entry,
          model: "openai:id",
          model: nil,
          bounds: %{max_turns: 1},
          bounds: nil,
          sampling: %{"max_tokens" => 1},
          sampling: nil,
          active_tools: [],
          active_tools: nil,
          unknown: :ignored,
          skills: :ignored
        )

      assert opts[:model].model == "openai:id"
      assert opts[:bounds] == %{max_turns: 1}
      refute Keyword.has_key?(opts, :sampling)
      assert opts[:session_creation_defaults]["initial_configuration"]["max_tokens"] == 1
      assert opts[:active_tools] == []
      assert opts[:tools] == []
      refute Keyword.has_key?(opts, :unknown)
      refute Keyword.has_key?(opts, :skills)
    end
  end

  defp capture(entry, extra, fixture_system_ceiling \\ nil) do
    Process.delete(@effect)
    test = self()
    marker = make_ref()

    Process.put(@edge, fn module, function, [opts] = arguments ->
      if module == Loopex, do: send(test, {marker, opts})
      apply(module, function, arguments)
    end)

    root =
      Path.join(System.tmp_dir!(), "loopex-durable-options-#{System.unique_integer([:positive])}")

    workspace = Path.join(root, "workspace")
    File.mkdir_p!(workspace)

    options =
      extra ++
        [
          policy: Policy,
          state_root: Path.join(root, "state"),
          workspace: workspace,
          runtime_id: "durable-options"
        ]

    options =
      if fixture_system_ceiling,
        do: fixture_template(options, fixture_system_ceiling),
        else: options

    try do
      case entry do
        :start ->
          assert {:ok, runtime} = LoopexComposition.TestHost.start(options)
          assert_bounds(runtime, extra)
          assert :ok = Loopex.stop(runtime)

        :with_runtime ->
          assert :done =
                   LoopexComposition.TestHost.with_runtime(options, fn runtime ->
                     assert_bounds(runtime, extra)
                     assert {:ok, _} = Loopex.create_session(runtime, %{}, command_id: "create")
                     :done
                   end)

        :start_edges ->
          {plane, host} = credential_plane()

          try do
            assert {:ok, edges} =
                     LoopexComposition.start_edges([credential_plane: plane] ++ options)

            assert_bounds(edges.runtime, extra)
            assert :ok = Loopex.stop(edges.runtime)

            edges
            |> Map.drop([:runtime, :runtime_supervisor])
            |> Map.values()
            |> Enum.each(&stop_process/1)
          after
            Enum.each(host, &stop_process/1)
          end
      end

      assert_receive {^marker, captured}
      captured
    after
      File.rm_rf!(root)
      Process.delete(@edge)
    end
  end

  # Concept: tool-wiring cases supply an explicitly sufficient current host configuration.
  # Technical depth: the complete selection exceeds the reference default's
  # system ceiling. Capture a bounded fixture ceiling before startup; the
  # separate refusal test retains that default's strict admission obligation.
  defp fixture_template(options, {ceiling, seed}) do
    alias Loopex.Runtime.{SessionGenesis, SessionConfiguration}
    alias LoopexComposition.{DurableOptions, SessionInstructions}
    alias LoopexProtocol.ToolDefinition
    ids = Keyword.fetch!(options, :active_tools)
    definitions = Enum.filter(DurableOptions.definitions(options), &(&1["tool_id"] in ids))

    profile =
      cond do
        ids == [] -> "none"
        Enum.any?(ids, &(&1 in ~w(loopex.write loopex.edit loopex.bash))) -> "coding"
        true -> "read-only"
      end

    {:ok, instructions} = SessionInstructions.capture(options[:workspace], profile)

    configuration =
      seed["initial_configuration"]
      |> Map.put("instructions", instructions)
      |> Map.put("system_class_tokens", ceiling)
      |> put_in(["budget_origins", "system_class_tokens"], "explicit")

    assert SessionConfiguration.validate(configuration, definitions) == :ok

    names =
      Map.new(definitions, fn definition ->
        {id, version, digest} = ToolDefinition.generation(definition)

        {definition["name"],
         %{"tool_id" => id, "tool_version" => version, "definition_digest" => digest}}
      end)

    {:ok, genesis} =
      SessionGenesis.resolve(%{}, %{
        genesis_version: "session_genesis_v3",
        initial_configuration: configuration,
        runtime_configuration: seed["runtime_configuration"],
        policy_defer_mode: "admit",
        tool_selection: %{"definitions" => definitions, "names" => names}
      })

    options
    |> Keyword.put(:session_creation_defaults, Map.drop(genesis, [:kind, "options"]))
    |> Keyword.put(:model, configuration["model"])
  end

  defp assert_bounds(runtime, extra) do
    assert {:ok, configuration} = Loopex.Runtime.configuration(runtime)
    defaults = %{max_turns: 16, token_budget: 1_000_000, deadline_ms: 600_000}
    assert configuration.bounds == Map.merge(defaults, Keyword.get(extra, :bounds, %{}))
    assert {:ok, children} = Loopex.Runtime.children(runtime)

    assert {:ok, expected} =
             Loopex.Runtime.MaintenanceConfiguration.capture_instructions(
               Keyword.get(extra, :maintenance_instructions)
             )

    assert :sys.get_state(children.control).maintenance_instructions == expected
    control = :sys.get_state(children.control)

    environment =
      JSON.decode!(
        control.session_creation_defaults["initial_configuration"]["instructions"]["environment"]
      )

    assert {:ok, reference} =
             LoopexComposition.WorkspaceIdentity.reference(environment["workspace"])

    assert control.executor.workspace_ref == reference
    refute Map.has_key?(configuration, :maintenance_instructions)
  end

  defp credential_plane do
    alias Loopex.LLM.ReqLLM.{CredentialCustody, CredentialRegistry, CredentialToken}
    alias Loopex.Trace.Capability
    {:ok, registry_pid} = CredentialRegistry.start_link([])
    {:ok, registry} = CredentialRegistry.handle(registry_pid)
    {:ok, custody_pid} = CredentialCustody.start_link(credential: "durable-options-canary")
    {:ok, custody} = CredentialCustody.reference(custody_pid)
    token = CredentialToken.new()
    :ok = CredentialRegistry.put(registry, token, custody)
    {:ok, capability_pid} = Capability.start_link([])
    {:ok, capability} = Capability.handle(capability_pid)

    {%{
       capability: capability,
       version: 2,
       excluded_env_names: ["LOOPEX_PROVIDER_API_KEY"],
       model_options: [
         provider_routes: Map.new(~w(anthropic openai openrouter), &{&1, token}),
         credential_registry: registry,
         tracing_capability: capability
       ]
     }, [capability_pid, custody_pid, registry_pid]}
  end

  defp stop_process(pid) do
    Process.unlink(pid)
    if Process.alive?(pid), do: GenServer.stop(pid)
  end

  defp creation_refusal(entry, extra) do
    {plane, owned} = credential_plane()

    try do
      refusal(entry, [{:credential_plane, plane} | extra])
    after
      Enum.each(owned, &stop_process/1)
    end
  end

  defp refusal(entry, extra) do
    options =
      extra ++
        [
          policy: __MODULE__,
          state_root: "/unused",
          workspace: "/unused",
          runtime_id: "options",
          credential_plane: nil
        ]

    case entry do
      :start ->
        LoopexComposition.start(options)

      :with_runtime ->
        LoopexComposition.with_runtime(options, fn _ -> flunk("callback ran") end)

      :start_edges ->
        assert {:error, reason, %{}} = LoopexComposition.start_edges(options)
        {:error, reason}
    end
  end
end
