Code.require_file("support/m1_runtime_helper.exs", __DIR__)
Code.require_file("support/agent_loop_adapters.exs", __DIR__)
Code.require_file("support/configured_genesis_helper.exs", __DIR__)

defmodule Loopex.RuntimeCreationDefaultsTest do
  use ExUnit.Case, async: false

  alias Loopex.ConfiguredGenesisFixture, as: Captured
  alias Loopex.M1RuntimeTestStore, as: TestStore
  alias Loopex.Runtime
  alias Loopex.Runtime.Instructions
  alias Loopex.Runtime.SessionGenesis
  alias Loopex.Runtime.SessionConfiguration
  alias Loopex.Store
  alias LoopexProtocol.ToolDefinition

  setup do
    {pid, store} = TestStore.start_store()
    on_exit(fn -> join_stop(pid, fn -> GenServer.stop(pid) end) end)
    %{store: store, store_pid: pid}
  end

  test "captured settings stay private and runtime-local across a Control restart", fixture do
    one = defaults([])
    two = defaults([], Captured.configuration("Different captured host instructions."))
    first = start!(fixture, one, runtime_id: "first")
    second = start!(fixture, two, runtime_id: "second")
    assert captured(first) == one
    assert captured(second) == two
    assert {:ok, view} = Runtime.configuration(first)
    refute inspect(view) =~ one["initial_configuration"]["instructions"]["base"]
    refute Map.has_key?(view, :session_creation_defaults)

    {:ok, %{control: control}} = Runtime.children(first)
    monitor = Process.monitor(control)
    Process.exit(control, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^control, :killed}, 5_000
    replacement = replacement_control(first, control, System.monotonic_time(:millisecond) + 5_000)
    assert :sys.get_state(replacement).session_creation_defaults == one
    assert captured(second) == two
    assert TestStore.inspect_state(fixture.store_pid).runtime_commands == %{}
    assert TestStore.inspect_state(fixture.store_pid).sessions == %{}
  end

  test "omitted and nil templates remain explicitly unconfigured", fixture do
    {:ok, runtime} = Loopex.start_link(base(fixture))
    on_exit(fn -> join_stop(runtime.supervisor, fn -> Loopex.stop(runtime) end) end)
    assert captured(runtime) == nil
    assert captured(start!(fixture, nil, runtime_id: "nil")) == nil

    assert Loopex.create_session(runtime, %{}, command_id: "unconfigured") ==
             {:error, :invalid_session_creation}

    assert Runtime.lookup_create_result(runtime, "unconfigured", %{}) == {:ok, :unexpected}
    assert TestStore.inspect_state(fixture.store_pid).sessions == %{}
  end

  test "implicit create and lookup bind normalized metadata and the complete captured template",
       fixture do
    selected = defaults([])
    runtime = start!(fixture, selected)
    assert Runtime.lookup_create_result(runtime, "create", %{tenant: "one"}) == {:ok, :absent}
    assert {:ok, session} = Loopex.create_session(runtime, %{tenant: "one"}, command_id: "create")

    assert {:ok, ^session} =
             Loopex.create_session(runtime, %{"tenant" => "one"}, command_id: "create")

    assert Runtime.lookup_create_result(runtime, "create", %{tenant: "one"}) ==
             {:ok, {:historical, session}}

    assert Runtime.lookup_create_result(runtime, "create", %{tenant: "two"}) == {:ok, :conflict}
    [first | _] = TestStore.inspect_state(fixture.store_pid).sessions[session].records

    assert first.payload ==
             Map.merge(selected, %{
               :kind => "session_genesis_v3",
               "options" => %{"tenant" => "one"}
             })

    join_stop(runtime.supervisor, fn -> Loopex.stop(runtime) end)
    changed = defaults([], Captured.configuration("Changed current host defaults."))
    next = start!(fixture, changed)
    {:ok, %{control: control}} = Runtime.children(next)
    assert :sys.get_state(control).sessions == %{}
    assert Runtime.lookup_create_result(next, "create", %{tenant: "one"}) == {:ok, :conflict}

    assert Runtime.lookup_create_result(next, "create", %{tenant: "one"}, first.payload) ==
             {:ok, {:historical, session}}

    assert {:ok, ^session} =
             Loopex.create_session(next, %{tenant: "one"},
               command_id: "create",
               genesis: first.payload
             )

    assert :sys.get_state(control).sessions == %{}
  end

  test "explicit current genesis needs no defaults and superseded genesis cannot be written",
       fixture do
    runtime = start!(fixture, nil)
    genesis = Captured.genesis([])
    assert {:ok, _} = Loopex.create_session(runtime, %{}, command_id: "current", genesis: genesis)

    old = %{
      :kind => "session_genesis_v2",
      "options" => %{},
      "runtime_configuration" => %{"cleanup_grace_ms" => 5_000}
    }

    assert Loopex.create_session(runtime, %{}, command_id: "old", genesis: old) ==
             {:error, :invalid_session_creation}

    assert Runtime.lookup_create_result(runtime, "old", %{}, old) == {:ok, :unexpected}
    assert map_size(TestStore.inspect_state(fixture.store_pid).sessions) == 1
  end

  test "the startup template has exactly four current plain settings", fixture do
    valid = defaults([])

    for invalid <-
          Enum.map(Map.keys(valid), &Map.delete(valid, &1)) ++
            [
              %{},
              [],
              self(),
              Map.put(valid, "options", %{}),
              Map.put(valid, :kind, "session_genesis_v3"),
              Map.put(valid, "credential", %{"env" => "PRIVATE_KEY"}),
              Map.put(valid, "callback", fn -> :ok end),
              Map.put(valid, :initial_configuration, valid["initial_configuration"]),
              put_in(valid, ["runtime_configuration", "cleanup_grace_ms"], 0),
              put_in(valid, ["runtime_configuration", "extra"], true),
              put_in(valid, ["policy_defer_mode"], "allow"),
              put_in(valid, ["initial_configuration", "model_capabilities", "model"], "other:v1"),
              put_in(valid, ["initial_configuration", "instructions", "base"], "Changed bytes"),
              put_in(valid, ["tool_selection", "artifact_read"], %{})
            ] do
      assert Loopex.start_link(Keyword.put(base(fixture), :session_creation_defaults, invalid)) ==
               {:error, :invalid_runtime_options}
    end

    assert TestStore.inspect_state(fixture.store_pid).runtime_commands == %{}
  end

  test "captured tool generations must be declared exactly at startup", fixture do
    definition = ordinary_definition()
    selected = defaults([definition])

    declared = [
      tools: [definition],
      policy: Loopex.AgentLoopTestPolicy,
      policy_identity: %{"id" => "fixture", "revision" => "1"}
    ]

    assert captured(start!(fixture, selected, declared)) == selected

    changed = Map.put(definition, "description", "A different model-visible declaration")

    for options <- [[], Keyword.put(declared, :tools, [changed])] do
      assert Loopex.start_link(base(fixture) ++ [session_creation_defaults: selected] ++ options) ==
               {:error, :invalid_runtime_options}
    end
  end

  test "the captured model must match the configured route without invoking its adapter",
       fixture do
    selected = defaults([])

    loop = [
      model: %{module: Loopex.AgentLoopTestModel, model: "scripted:v1", options: []},
      executor: %{
        module: Loopex.AgentLoopTestExecutor,
        reference: fixture.store_pid,
        identity: "fixture",
        epoch: 1,
        fencing_token: 1,
        workspace_ref: "workspace",
        workspace_lease: "lease"
      },
      grant_decision: {:host_policy, :allow}
    ]

    assert captured(start!(fixture, selected, loop)) == selected
    changed = put_in(loop, [:model, :model], "other:v1")

    assert Loopex.start_link(base(fixture) ++ [session_creation_defaults: selected] ++ changed) ==
             {:error, :invalid_runtime_options}

    assert TestStore.inspect_state(fixture.store_pid).sessions == %{}
  end

  test "the complete normalized genesis ceiling applies before any runtime starts", fixture do
    {:ok, instructions} =
      Instructions.capture(%{
        "version" => "large.v1",
        "base" => String.duplicate("b", 32_768),
        "environment" => String.duplicate("e", 4_096),
        "appendix" => String.duplicate("a", 16_384)
      })

    configuration =
      Captured.configuration()
      |> Map.put("instructions", instructions)
      |> Map.put("context_token_budget", 200_000)
      |> Map.put("system_class_tokens", 100_000)
      |> Map.put("budget_origins", %{
        "context_token_budget" => "explicit",
        "system_class_tokens" => "explicit"
      })

    definitions =
      for n <- 1..5 do
        ordinary_definition()
        |> Map.put("tool_id", "example.tool#{n}")
        |> Map.put("name", "tool#{n}")
        |> Map.put("description", String.duplicate("d", 4_096))
      end

    names =
      Map.new(definitions, fn d ->
        {id, version, digest} = ToolDefinition.generation(d)
        {d["name"], %{"tool_id" => id, "tool_version" => version, "definition_digest" => digest}}
      end)

    selected =
      defaults([])
      |> Map.put("initial_configuration", configuration)
      |> Map.put("tool_selection", %{
        "definitions" => definitions,
        "names" => names,
        "artifact_read" => nil
      })

    payload = Map.merge(selected, %{:kind => "session_genesis_v3", "options" => %{}})
    assert {:ok, _, bytes} = Store.normalize_and_measure_item(:record, payload)
    base_length = 32_768 - (bytes - 65_537)
    assert base_length in 1..32_768

    {:ok, instructions} =
      instructions
      |> Map.delete("digest")
      |> Map.put("base", String.duplicate("b", base_length))
      |> Instructions.capture()

    selected = put_in(selected, ["initial_configuration", "instructions"], instructions)
    payload = Map.merge(selected, %{:kind => "session_genesis_v3", "options" => %{}})
    assert SessionConfiguration.validate(selected["initial_configuration"], definitions) == :ok
    assert {:ok, _, 65_537} = Store.normalize_and_measure_item(:record, payload)

    assert SessionGenesis.normalize(payload) ==
             {:error, :session_configuration_too_large}

    assert Loopex.start_link(
             base(fixture) ++
               [
                 session_creation_defaults: selected,
                 tools: definitions,
                 policy: Loopex.AgentLoopTestPolicy,
                 policy_identity: %{"id" => "fixture", "revision" => "1"}
               ]
           ) ==
             {:error, :invalid_runtime_options}

    assert TestStore.inspect_state(fixture.store_pid).sessions == %{}
  end

  defp defaults(definitions, configuration \\ Captured.configuration()),
    do: Captured.genesis(definitions, configuration) |> Map.drop([:kind, "options"])

  defp ordinary_definition do
    [definition] =
      Path.expand("../priv/vectors/artifact_read.v1.json", __DIR__)
      |> File.read!()
      |> JSON.decode!()
      |> Map.fetch!("vectors")
      |> Enum.map(& &1["definition"])

    Map.put(definition, "tool_id", "example.read")
  end

  defp base(fixture),
    do: [runtime_id: "defaults", context_token_budget: 8_192, store: fixture.store]

  defp start!(fixture, selected, options \\ []) do
    options =
      Keyword.merge(base(fixture), options) |> Keyword.put(:session_creation_defaults, selected)

    {:ok, runtime} = Loopex.start_link(options)
    on_exit(fn -> join_stop(runtime.supervisor, fn -> Loopex.stop(runtime) end) end)
    runtime
  end

  defp captured(runtime) do
    {:ok, %{control: control}} = Runtime.children(runtime)
    :sys.get_state(control).session_creation_defaults
  end

  defp replacement_control(runtime, previous, cutoff) do
    case Runtime.children(runtime) do
      {:ok, %{control: control}} when control != previous ->
        control

      _ ->
        assert System.monotonic_time(:millisecond) < cutoff

        receive do
        after
          1 -> :ok
        end

        replacement_control(runtime, previous, cutoff)
    end
  end

  defp join_stop(pid, stop) do
    if Process.alive?(pid) do
      monitor = Process.monitor(pid)
      stop.()
      assert_receive {:DOWN, ^monitor, :process, ^pid, _}, 5_000
    end
  end
end
