Code.require_file("support/m1_runtime_helper.exs", __DIR__)
Code.require_file("support/agent_loop_helper.exs", __DIR__)

defmodule Loopex.ToolRegistryTest do
  @moduledoc false

  use ExUnit.Case, async: false

  alias Loopex.M1RuntimeTestStore
  alias Loopex.ToolRegistry
  alias LoopexProtocol.ToolDefinition

  defp definition(overrides) do
    Map.merge(
      %{
        "tool_id" => "example.read",
        "tool_version" => "1.0.0",
        "name" => "read",
        "description" => "Read a file beneath the workspace root.",
        "parameter_schema" => %{
          "type" => "object",
          "properties" => %{"path" => %{"type" => "string", "description" => "Relative path."}},
          "required" => ["path"]
        },
        "result_shape" => %{"content_type" => "text", "description" => "File contents."},
        "effect_class" => "read_only",
        "idempotency_class" => "safe_retry",
        "budgets" => %{
          "wall_time_ms" => 30_000,
          "output_bytes" => 65_536,
          "artifact_bytes" => 1_048_576
        }
      },
      overrides
    )
  end

  defp start_runtime(label, options) do
    {store_pid, store} = M1RuntimeTestStore.start_store(label: label)

    {:ok, runtime} =
      Loopex.start_link([runtime_id: label, store: store] ++ options)

    on_exit(fn ->
      try do
        Loopex.stop(runtime)
      catch
        :exit, _reason -> :ok
      end

      try do
        GenServer.stop(store_pid, :normal, 1_000)
      catch
        :exit, _reason -> :ok
      end
    end)

    runtime
  end

  test "a runtime-scoped registry resolves a tool id and version and refuses an unknown id" do
    one = definition(%{})
    two = definition(%{"tool_version" => "1.10.0", "description" => "Read a file, revised."})
    older = definition(%{"tool_version" => "1.9.0", "description" => "Read a file, earlier."})

    runtime = start_runtime("registry-resolve", tools: [one, older, two])

    # The highest registered version wins, and version order is numeric rather
    # than lexical: 1.10.0 must resolve above 1.9.0.
    assert {:ok, %{generation: {"example.read", "1.10.0", digest}}} =
             ToolRegistry.resolve(runtime, "example.read")

    assert digest == ToolDefinition.definition_digest(two)

    assert {:ok, %{generation: {"example.read", "1.0.0", _digest}}} =
             ToolRegistry.resolve(runtime, "example.read", "1.0.0")

    # An unknown identifier and a known identifier at an unknown version say
    # different things and must not be collapsed into one reason.
    assert {:error, :unknown_tool} = ToolRegistry.resolve(runtime, "example.absent")
    assert {:error, :unknown_tool} = ToolRegistry.resolve(runtime, "example.absent", "1.0.0")

    assert {:error, :unknown_tool_generation} =
             ToolRegistry.resolve(runtime, "example.read", "2.0.0")
  end

  test "two runtimes carry independent tool registries with no global registration" do
    registered_before = MapSet.new(Process.registered())
    environment_before = Application.get_all_env(:loopex)

    alpha_tool = definition(%{"tool_id" => "example.alpha", "name" => "alpha"})
    beta_tool = definition(%{"tool_id" => "example.beta", "name" => "beta"})

    alpha = start_runtime("registry-alpha", tools: [alpha_tool])
    beta = start_runtime("registry-beta", tools: [beta_tool])

    {:ok, alpha_registry} = Loopex.Runtime.tool_registry(alpha)
    {:ok, beta_registry} = Loopex.Runtime.tool_registry(beta)
    assert alpha_registry != beta_registry

    # Each runtime resolves only its own set. Neither can name the other's.
    assert {:ok, %{generation: {"example.alpha", _version, _digest}}} =
             ToolRegistry.resolve(alpha, "example.alpha")

    assert {:error, :unknown_tool} = ToolRegistry.resolve(alpha, "example.beta")

    assert {:ok, %{generation: {"example.beta", _version, _digest}}} =
             ToolRegistry.resolve(beta, "example.beta")

    assert {:error, :unknown_tool} = ToolRegistry.resolve(beta, "example.alpha")

    # Registering into one runtime is invisible to the other.
    assert :ok = ToolRegistry.register(alpha, definition(%{"tool_id" => "example.late"}))
    assert {:ok, _entry} = ToolRegistry.resolve(alpha, "example.late")
    assert {:error, :unknown_tool} = ToolRegistry.resolve(beta, "example.late")

    # The claim is structural, not incidental: no VM-global name and no
    # application-environment key appeared, so there is nothing a second runtime
    # could have displaced or read.
    assert MapSet.difference(MapSet.new(Process.registered()), registered_before)
           |> MapSet.size() == 0

    assert Application.get_all_env(:loopex) == environment_before
  end

  test "a conflicting tool id and version registration is refused with an explicit reason" do
    original = definition(%{})
    runtime = start_runtime("registry-conflict", tools: [original])

    # An identical definition is idempotent rather than a conflict.
    assert :ok = ToolRegistry.register(runtime, original)

    # A different definition under an identity already held is refused. The
    # comparison is over canonical bytes, so a change to any field conflicts —
    # here the model-visible name, which is exactly the field a caller might
    # expect to be able to edit in place.
    assert {:error, :tool_definition_conflict} =
             ToolRegistry.register(runtime, definition(%{"name" => "renamed"}))

    assert {:error, :tool_definition_conflict} =
             ToolRegistry.register(runtime, definition(%{"description" => "Something else."}))

    # A new version of a known tool is admitted additively, leaving the original
    # generation exactly as it was.
    assert :ok = ToolRegistry.register(runtime, definition(%{"tool_version" => "2.0.0"}))

    assert {:ok, %{canonical_bytes: bytes}} =
             ToolRegistry.resolve(runtime, "example.read", "1.0.0")

    assert bytes == ToolDefinition.canonical_bytes(original)

    # The reserved namespace is admitted only as the runtime's own composed set,
    # never from a later caller.
    assert {:error, :reserved_tool_namespace} =
             ToolRegistry.register(runtime, definition(%{"tool_id" => "loopex.smuggled"}))

    assert {:error, :invalid_tool_name} =
             ToolRegistry.register(
               runtime,
               definition(%{"tool_id" => "example.bad", "name" => "Not A Name"})
             )
  end

  test "a model request records the exact tool definition generation it used" do
    definition = Loopex.AgentLoopFixture.tool_definition()

    fixture =
      Loopex.AgentLoopFixture.start(script: [%{text: "done", calls: []}], tools: [definition])

    on_exit(fn -> Loopex.AgentLoopFixture.stop(fixture) end)

    {session_id, _attachment, _reply} = Loopex.AgentLoopFixture.run(fixture, "go")

    wait_settled(fixture, session_id)

    [record] =
      fixture
      |> Loopex.AgentLoopFixture.records(session_id)
      |> Enum.filter(&(&1.payload[:kind] == "model_request_committed"))

    # The staged request carries the complete definition record, so the
    # generation it used is recomputable from the journal alone rather than by
    # asking a registry that may since have changed.
    assert [staged] = record.payload["request"]["tools"]
    assert ToolDefinition.generation(staged) == ToolDefinition.generation(definition)

    {tool_id, tool_version, digest} = ToolDefinition.generation(staged)
    assert tool_id == "example.write"
    assert tool_version == "1.0.0"
    assert String.match?(digest, ~r/^[0-9a-f]{64}$/)
  end

  defp wait_settled(fixture, session_id, attempts \\ 300) do
    case Loopex.session_status(fixture.runtime, session_id) do
      {:ok, %{active_run_id: nil}} ->
        :settled

      _other when attempts > 0 ->
        Process.sleep(10)
        wait_settled(fixture, session_id, attempts - 1)

      _other ->
        :never_settled
    end
  end

  test "a session binds one active model visible name to one generation and refuses a name conflict at start" do
    read_one = definition(%{})
    read_two = definition(%{"tool_version" => "2.0.0", "description" => "Read a file, v2."})
    writer = definition(%{"tool_id" => "example.write", "name" => "write"})
    shadow = definition(%{"tool_id" => "example.other", "name" => "read"})

    runtime =
      start_runtime("registry-active-set", tools: [read_one, read_two, writer, shadow])

    # Composition maps each model-visible name to exactly one generation.
    assert {:ok, active} =
             ToolRegistry.compose_active_set(runtime, ["example.read", "example.write"])

    assert active == %{
             "read" => ToolDefinition.generation(read_two),
             "write" => ToolDefinition.generation(writer)
           }

    # An exact generation can be selected instead of the highest version.
    assert {:ok, %{"read" => pinned}} =
             ToolRegistry.compose_active_set(runtime, [{"example.read", "1.0.0"}])

    assert pinned == ToolDefinition.generation(read_one)

    # Two generations claiming one name is refused at composition, naming both
    # claimants. Registration allowed them to coexist; being simultaneously
    # active is what is refused, and there is no precedence rule that would
    # quietly pick one.
    assert {:error, {:duplicate_tool_name, "read", first, second}} =
             ToolRegistry.compose_active_set(runtime, ["example.read", "example.other"])

    assert first == ToolDefinition.generation(read_two)
    assert second == ToolDefinition.generation(shadow)

    # A selection the registry cannot resolve refuses the whole composition
    # rather than yielding a partial active set.
    assert {:error, {:unknown_tool, "example.absent"}} =
             ToolRegistry.compose_active_set(runtime, ["example.read", "example.absent"])

    assert {:error, {:unknown_tool_generation, "example.read", "9.9.9"}} =
             ToolRegistry.compose_active_set(runtime, [{"example.read", "9.9.9"}])
  end
end
