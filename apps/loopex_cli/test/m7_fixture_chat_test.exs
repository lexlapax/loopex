defmodule LoopexCli.M7FixtureChatTest do
  use ExUnit.Case, async: false

  alias LoopexCli.M7FixtureChat
  alias LoopexCli.Policy.M7Fixture, as: Policy
  alias LoopexComposition.WorkspaceIdentity
  alias LoopexProtocol.{Canonical, ToolDefinition}
  alias Mix.Tasks.Loopex.M7Evidence.FixtureManifest

  @fixtures Path.expand("../../../test/fixtures/m7", __DIR__)

  setup do
    root = Path.join(System.tmp_dir!(), "m7-preparation-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    catalog_root = Path.join(root, "catalog")
    File.cp_r!(@fixtures, catalog_root)
    config = Path.join(root, "chat.json")
    %{root: root, catalog_root: catalog_root, config: config}
  end

  test "new and resume preparations retain the same exact catalog and policy identities", f do
    fixture = fixture(f, "repair")
    assert {:ok, prepared} = prepare(f, fixture)
    assert {:ok, manifest} = FixtureManifest.load(f.catalog_root)
    assert manifest.bytes == File.read!(manifest.path)
    assert manifest.digest == Canonical.digest_bytes(manifest.bytes)
    assert prepared.capture.manifest_digest == manifest.digest
    assert prepared.capture.argv == ["/bin/sh", fixture.runner]
    assert prepared.invocation.harness_fixture == prepared.capture
    assert prepared.capture.pins[manifest.path].sha256 == manifest.digest

    assert {:ok, resumed} = prepare(f, fixture, ["--resume", "retained-session"])
    assert resumed.invocation.resume_session_id == "retained-session"
    assert resumed.capture.identity == prepared.capture.identity
    long = fixture(f, "long", %{}, "long-trusted")
    assert {:ok, long_prepared} = prepare(f, long)
    assert long_prepared.capture.case_id == "m7.long"
    assert long_prepared.capture.manifest_digest == manifest.digest
    refute File.exists?(Path.join(f.root, "state"))
  end

  test "ordinary configuration and command refusals precede fixture inspection", f do
    fixture = fixture(f, "repair")
    File.write!(f.config, "{}")
    ordinary = LoopexCli.ChatConfiguration.load(argv(f), f.root, nil)
    assert {:error, _} = ordinary
    assert M7FixtureChat.prepare(argv(f), f.root, nil, :not_a_fixture) == ordinary

    assert {:error, {:invalid_arguments, ""}} =
             M7FixtureChat.prepare(["unsupported"], f.root, nil, fixture)

    refute File.exists?(Path.join(f.root, "state"))
  end

  test "catalog bytes remain captured and any later manifest change invalidates its capture", f do
    fixture = fixture(f, "repair")
    assert {:ok, catalog} = FixtureManifest.load(f.catalog_root)
    assert {:ok, prepared} = prepare(f, fixture)
    File.write!(catalog.path, catalog.bytes <> "\n")
    assert Canonical.digest_bytes(catalog.bytes) == catalog.digest
    assert {:ok, newer} = FixtureManifest.load(f.catalog_root)
    refute newer.digest == catalog.digest
    assert Policy.check(prepared.capture) == {:error, :fixture_policy_unavailable}
    assert_refused(f, fixture)
    refreshed = %{fixture | pins: Map.put(fixture.pins, catalog.path, pin(catalog.path))}
    assert {:ok, current} = prepare(f, refreshed)
    assert current.capture.manifest_digest == newer.digest
    refute current.capture.identity == prepared.capture.identity
  end

  test "unknown cases and caller-supplied command vectors are refused", f do
    fixture = fixture(f, "repair")
    assert_refused(f, %{fixture | case_id: "m7.other"})
    assert_refused(f, Map.put(fixture, :argv, ["/bin/sh", fixture.runner, "extra"]))
    assert_refused(f, Map.put(fixture, :command, "elixir oracle.exs"))
  end

  test "a fully pinned alternate runner cannot become the selected catalog oracle", f do
    fixture = fixture(f, "repair")
    File.write!(fixture.runner, "#!/bin/sh\nexec /bin/echo pass\n")
    pins = Map.put(fixture.pins, fixture.runner, pin(fixture.runner))
    pins = Map.put(pins, "/bin/echo", pin("/bin/echo"))
    assert {:ok, manifest} = FixtureManifest.load(f.catalog_root)

    assert {:ok, _generic_capture} =
             Policy.prepare(
               "m7.repair",
               manifest.digest,
               fixture.workspace,
               ["/bin/sh", fixture.runner],
               pins
             )

    assert_refused(f, %{fixture | pins: Map.delete(pins, "/bin/echo")})
    assert_refused(f, %{fixture | pins: pins})
  end

  test "an unrelated fully pinned oracle copy is refused by its catalog digest", f do
    fixture = fixture(f, "repair")
    File.write!(fixture.oracle, "IO.puts(:pass)\n")

    assert_refused(f, %{
      fixture
      | pins: Map.put(fixture.pins, fixture.oracle, pin(fixture.oracle))
    })

    File.cp!(Path.join(f.catalog_root, "repair/oracle.exs"), fixture.oracle)
    File.chmod!(fixture.oracle, 0o755)
    assert_refused(f, fixture)

    assert_refused(f, %{
      fixture
      | pins: Map.put(fixture.pins, fixture.oracle, pin(fixture.oracle))
    })
  end

  test "changed retained runner bytes or modes invalidate preparation and later checks", f do
    fixture = fixture(f, "repair")
    assert {:ok, prepared} = prepare(f, fixture)
    bytes = File.read!(fixture.runner)
    File.write!(fixture.runner, bytes <> "# altered\n")
    assert_refused(f, fixture)
    assert Policy.check(prepared.capture) == {:error, :fixture_policy_unavailable}
    File.write!(fixture.runner, bytes)
    File.chmod!(fixture.runner, 0o755)
    assert_refused(f, fixture)

    assert_refused(f, %{
      fixture
      | pins: Map.put(fixture.pins, fixture.runner, pin(fixture.runner))
    })

    File.chmod!(fixture.runner, 0o644)
    assert {:ok, _} = prepare(f, fixture)
  end

  test "changed executable expectations and extra executable pins cannot alter the fixed toolchain",
       f do
    fixture = fixture(f, "repair")
    {:ok, recipe} = Policy.oracle_runner(fixture.case_id, fixture.workspace, fixture.oracle, %{})
    changed = put_in(fixture, [:pins, recipe.elixir, :sha256], String.duplicate("0", 64))
    assert_refused(f, changed)
    assert_refused(f, %{fixture | pins: Map.put(fixture.pins, "/bin/echo", pin("/bin/echo"))})
  end

  test "ordinary physical workspace identity and the selected fixture must agree", f do
    fixture = fixture(f, "repair")
    other = Path.join(f.root, "other-workspace")
    File.cp_r!(fixture.workspace, other)
    assert_refused(f, fixture, ["--workspace", other])
    alias_path = Path.join(f.root, "workspace-alias")
    File.ln_s!(fixture.workspace, alias_path)
    assert {:ok, _} = prepare(f, fixture, ["--workspace", alias_path])
    File.write!(Path.join(fixture.workspace, "unexpected"), "extra")
    assert_refused(f, fixture)
  end

  test "runner and oracle pins inside the writable workspace refuse even with exact bytes", f do
    fixture = fixture(f, "repair")
    inside_runner = Path.join(fixture.workspace, "lib/ledger.ex")
    File.write!(inside_runner, File.read!(fixture.runner))

    pins =
      fixture.pins |> Map.delete(fixture.runner) |> Map.put(inside_runner, pin(inside_runner))

    assert_refused(f, %{fixture | runner: inside_runner, pins: pins})

    File.cp!(Path.join(f.catalog_root, "repair/workspace/lib/ledger.ex"), inside_runner)
    inside_oracle = Path.join(fixture.workspace, "lib/ledger.ex")
    File.cp!(fixture.oracle, inside_oracle)
    {:ok, recipe} = Policy.oracle_runner(fixture.case_id, fixture.workspace, inside_oracle, %{})
    File.write!(fixture.runner, recipe.bytes)

    pins =
      fixture.pins |> Map.delete(fixture.oracle) |> Map.put(inside_oracle, pin(inside_oracle))

    pins = Map.put(pins, fixture.runner, pin(fixture.runner))
    assert_refused(f, %{fixture | oracle: inside_oracle, pins: pins})
  end

  test "review captures omit both mutation generations and deny their requests", f do
    fixture = fixture(f, "review", %{"M7_FINDING" => Path.join(f.root, "finding.tsv")})
    assert {:ok, prepared} = prepare(f, fixture)
    refute File.exists?(fixture.environment["M7_FINDING"])

    for id <- ~w(loopex.write loopex.edit) do
      definition = LoopexCli.ChatConfiguration.selected_definitions([id]) |> hd()
      generation = ToolDefinition.generation(definition)
      refute Map.has_key?(prepared.capture.generations, generation)

      assert {:deny, :policy_denied} =
               Policy.decide(
                 %{
                   generation: generation,
                   effect_class: definition["effect_class"],
                   workspace_lease: "workspace",
                   arguments: %{"path" => "lib/fees.ex"}
                 },
                 prepared.capture
               )
    end
  end

  test "feature inputs are closed and both catalog defaults render the fixed runner", f do
    fixture = fixture(f, "feature", %{"M7_NIL_DEFAULT" => "empty"})
    assert {:ok, _} = prepare(f, fixture)
    fixture = replace_environment(fixture, %{"M7_NIL_DEFAULT" => "literal_null"})
    assert {:ok, _} = prepare(f, fixture)
    assert_refused(f, %{fixture | environment: %{"M7_NIL_DEFAULT" => "$(arbitrary)"}})
    assert_refused(f, %{fixture | environment: %{"M7_NIL_DEFAULT" => "empty", "EXTRA" => "x"}})
  end

  test "quote-bearing paths and review inputs are shell literals with independent byte expectations",
       f do
    finding = Path.join(f.root, "finding'$(not-a-command)`literal`.tsv")
    fixture = fixture(f, "review", %{"M7_FINDING" => finding}, "quote'$(literal)`path`")

    assert {:ok, recipe} =
             Policy.oracle_runner(
               fixture.case_id,
               fixture.workspace,
               fixture.oracle,
               fixture.environment
             )

    assert recipe.bytes =~
             "M7_FINDING='" <> f.root <> "/finding'\\''$(not-a-command)`literal`.tsv'"

    assert recipe.bytes =~ "M7_WORKSPACE='" <> f.root <> "/quote'\\''$(literal)`path`/workspace'"
    assert {:ok, prepared} = prepare(f, fixture)
    assert prepared.capture.argv == ["/bin/sh", fixture.runner]
    refute File.exists?(finding)
  end

  test "preparation calls no runtime startup, provider completion or external command entrypoint",
       f do
    fixture = fixture(f, "repair")

    mfas = [
      {Loopex.Runtime, :start_link, 1},
      {Loopex.LLM.ReqLLM, :complete, 3},
      {System, :cmd, 2},
      {System, :cmd, 3}
    ]

    for {module, _, _} <- mfas, do: Code.ensure_loaded!(module)
    parent = self()
    {collector, monitor} = spawn_monitor(fn -> collect_calls(parent, []) end)
    deadline = System.monotonic_time(:millisecond) + 5000
    joined_key = {__MODULE__, :trace_collector_joined, monitor}
    Process.put(joined_key, false)

    try do
      for mfa <- mfas, do: assert(:erlang.trace_pattern(mfa, true, [:local]) == 1)
      assert :erlang.trace(self(), true, [:call, {:tracer, collector}]) == 1
      assert {:ok, _} = prepare(f, fixture)
      assert_refused(f, %{fixture | case_id: "m7.other"})
      File.write!(f.config, "{}")
      assert {:error, _} = prepare(f, fixture)
      barrier = :erlang.trace_delivered(self())
      assert_receive {:trace_delivered, _, ^barrier}, remaining(deadline)
      send(collector, {:finish, self()})
      assert_receive {:calls, ^collector, []}, remaining(deadline)
      assert_receive {:DOWN, ^monitor, :process, ^collector, :normal}, remaining(deadline)
      Process.put(joined_key, true)
    after
      :erlang.trace(self(), false, [:call])
      for mfa <- mfas, do: :erlang.trace_pattern(mfa, false, [:local])

      unless Process.delete(joined_key) do
        if Process.alive?(collector), do: Process.exit(collector, :kill)

        receive do
          {:DOWN, ^monitor, :process, ^collector, _} -> :ok
        after
          remaining(deadline) -> flunk("trace collector cleanup not confirmed")
        end
      end
    end

    refute File.exists?(Path.join(f.root, "state"))
  end

  defp collect_calls(parent, calls) do
    receive do
      {:trace, _, :call, call} -> collect_calls(parent, [call | calls])
      {:finish, ^parent} -> send(parent, {:calls, self(), Enum.reverse(calls)})
    end
  end

  defp remaining(deadline), do: max(0, deadline - System.monotonic_time(:millisecond))

  defp fixture(f, name, environment \\ %{}, suffix \\ "trusted") do
    trusted = Path.join(f.root, suffix)
    workspace = Path.join(trusted, "workspace")
    File.mkdir_p!(trusted)
    File.cp_r!(Path.join([f.catalog_root, name, "workspace"]), workspace)
    oracle = Path.join(trusted, "oracle.exs")
    runner = Path.join(trusted, "run.sh")
    File.cp!(Path.join([f.catalog_root, name, "oracle.exs"]), oracle)
    {:ok, recipe} = Policy.oracle_runner("m7." <> name, workspace, oracle, environment)
    File.write!(runner, recipe.bytes)
    File.chmod!(runner, 0o644)
    {:ok, manifest} = FixtureManifest.load(f.catalog_root)

    pins =
      Map.new(
        ["/bin/sh", "/usr/bin/env", recipe.elixir, runner, oracle, manifest.path],
        &{&1, pin(&1)}
      )

    File.write!(f.config, :json.encode(profile(f, workspace)))

    %{
      case_id: "m7." <> name,
      catalog_root: f.catalog_root,
      workspace: workspace,
      runner: runner,
      oracle: oracle,
      environment: environment,
      pins: pins
    }
  end

  defp replace_environment(fixture, environment) do
    {:ok, recipe} =
      Policy.oracle_runner(fixture.case_id, fixture.workspace, fixture.oracle, environment)

    File.write!(fixture.runner, recipe.bytes)

    %{
      fixture
      | environment: environment,
        pins: Map.put(fixture.pins, fixture.runner, pin(fixture.runner))
    }
  end

  defp profile(f, workspace) do
    %{
      "schema_version" => 1,
      "providers" => %{
        "anthropic" => %{"credential" => %{"env" => "M7_UNUSED_FIXTURE_REFERENCE"}}
      },
      "policy" => "shell-allowlist",
      "paths" => %{"workspace" => workspace, "state_root" => Path.join(f.root, "state")},
      "session" => %{
        "model" => "anthropic:claude-haiku-4-5",
        "tools" => "coding",
        "system_class_tokens" => 8000,
        "bounds" => %{"max_turns" => 8, "deadline_ms" => 15000, "token_budget" => 100_000}
      }
    }
  end

  defp pin(path) do
    {:ok, physical} = WorkspaceIdentity.resolve_path(path)
    {:ok, stat} = File.stat(physical)
    %{mode: Bitwise.band(stat.mode, 0o7777), sha256: Canonical.digest_bytes(File.read!(physical))}
  end

  defp argv(f), do: ["chat", "--config", f.config]

  defp prepare(f, fixture, extra \\ []),
    do: M7FixtureChat.prepare(argv(f) ++ extra, f.root, nil, fixture)

  defp assert_refused(f, fixture, extra \\ []) do
    assert prepare(f, fixture, extra) == {:error, :fixture_preparation_unavailable}
    refute File.exists?(Path.join(f.root, "state"))
  end
end
