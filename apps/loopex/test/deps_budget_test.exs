defmodule Mix.Tasks.Loopex.DepsBudgetTest do
  use ExUnit.Case, async: true

  alias Loopex.Checks.DepsBudget, as: Budget
  alias Mix.Tasks.Loopex.DepsBudget

  @fixture "scripts/fixtures/deps-budget-invalid/mix.exs"
  @reqllm_requirement "~> 1.17.1"

  defp repo_root, do: Path.expand("../../..", __DIR__)

  setup do
    dir = Path.join(System.tmp_dir!(), "deps-budget-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, dir: dir}
  end

  test "the repository satisfies the dependency budget and direction" do
    assert DepsBudget.check_repository(repo_root()) == :ok
  end

  test "a forbidden core dependency is rejected" do
    # The bound adversarial fixture declares app: :loopex with a provider
    # dependency, which the runtime application may never carry.
    fixture = Path.join(repo_root(), @fixture)
    assert File.exists?(fixture), "the bound fixture #{@fixture} is missing"
    assert {:error, reasons} = DepsBudget.check_mix_exs(fixture)
    assert Enum.any?(reasons, &String.contains?(&1, "req_llm"))
  end

  test "an extension may carry external dependencies but not the runtime", %{dir: dir} do
    # ADR 0003: an extension compiles against the contract, never the runtime.
    good = Path.join(dir, "good.exs")

    File.write!(good, """
    defmodule Good.MixProject do
      use Mix.Project
      def project,
        do: [app: :loopex_probe_extension, loopex_role: :extension, version: "0.0.0", deps: deps()]
      defp deps, do: [{:loopex_protocol, in_umbrella: true}, {:external_probe, "~> 1.0"}]
    end
    """)

    assert DepsBudget.check_mix_exs(good) == :ok

    bad = Path.join(dir, "bad.exs")

    File.write!(bad, """
    defmodule Bad.MixProject do
      use Mix.Project
      def project,
        do: [app: :loopex_bad_extension, loopex_role: :extension, version: "0.0.0", deps: deps()]
      defp deps, do: [{:loopex, in_umbrella: true}]
    end
    """)

    assert {:error, reasons} = DepsBudget.check_mix_exs(bad)
    assert Enum.any?(reasons, &String.contains?(&1, "depend inward only"))
  end

  test "dependency identity and role come only from the canonical project declaration", %{
    dir: dir
  } do
    fixture = Path.join(dir, "decoy.exs")

    File.write!(fixture, """
    defmodule Decoy.MixProject do
      use Mix.Project
      def decoy, do: [app: :loopex, loopex_role: :core]
      def project,
        do: [app: :loopex_probe_extension, loopex_role: :extension, version: "0.0.0", deps: deps()]
      defp deps, do: [{:loopex_protocol, in_umbrella: true}]
    end
    """)

    assert DepsBudget.check_mix_exs(fixture) == :ok
  end

  test "internal dependencies cannot redirect canonical umbrella source ownership", %{dir: dir} do
    write_inventory(dir)

    write_child(dir, "loopex", :core, [
      {:loopex_protocol, [in_umbrella: true, path: "../shadow-core"]}
    ])

    track!(dir)
    assert {:error, reasons} = Budget.check_repository(dir)
    assert Enum.any?(reasons, &String.contains?(&1, "literal dependency data"))

    external = Path.join(dir, "external.exs")

    File.write!(external, """
    defmodule External.MixProject do
      use Mix.Project
      def project,
        do: [app: :loopex_probe_extension, loopex_role: :extension, deps: deps()]
      defp deps,
        do: [{:loopex_protocol, in_umbrella: true}, {:external_probe, "~> 1.0", path: "vendor/probe"}]
    end
    """)

    assert {:error, _reasons} = DepsBudget.check_mix_exs(external)

    for dependency <- [
          ~s|{:external_probe, [only: :test]}|,
          ~s|{:external_probe, "~> 1.0", path: "vendor/probe"}|,
          ~s|{:external_probe, "~> 1.0", git: "https://example.invalid/probe.git"}|,
          ~s|{:external_probe, "~> 1.0", github: "owner/probe"}|,
          ~s|{:external_probe, "~> 1.0", scm: Mix.SCM.Git}|,
          ~s|{:external_probe, "not a requirement"}|
        ] do
      File.write!(external, """
      defmodule External.MixProject do
        use Mix.Project
        def project,
          do: [app: :loopex_probe_extension, loopex_role: :extension, deps: deps()]
        defp deps,
          do: [{:loopex_protocol, in_umbrella: true}, #{dependency}]
      end
      """)

      assert {:error, _reasons} = DepsBudget.check_mix_exs(external)
    end

    File.write!(external, """
    defmodule External.MixProject do
      use Mix.Project
      def project,
        do: [app: :loopex_probe_extension, loopex_role: :extension, deps: deps()]
      defp deps,
        do: [{:loopex_protocol, in_umbrella: true}, {:external_probe, "~> 1.0", only: :test, optional: true, runtime: false}]
    end
    """)

    assert {:error, _reasons} = DepsBudget.check_mix_exs(external)
  end

  test "compiled source roots remain inside their owning application", %{dir: dir} do
    write_inventory(dir)
    core_mix = Path.join(dir, "apps/loopex/mix.exs")
    core_source = Path.join(dir, "apps/loopex/lib/core.ex")
    support_source = Path.join(dir, "apps/loopex/test/support/helper.ex")
    File.mkdir_p!(Path.dirname(core_source))
    File.mkdir_p!(Path.dirname(support_source))
    File.write!(core_source, "defmodule Fixture.CoreSource, do: nil\n")
    File.write!(support_source, "defmodule Fixture.SupportSource, do: nil\n")
    File.write!(Path.join(dir, "apps/loopex/lib/tracked.hrl"), "-define(TRACKED, true).\n")

    original = File.read!(core_mix)

    local =
      String.replace(
        original,
        "deps: deps()",
        ~s|elixirc_paths: ["lib", "test/support"], deps: deps()|
      )

    File.write!(core_mix, local)
    track!(dir)
    assert Budget.check_repository(dir) == :ok

    for replacement <- [
          ~s|elixirc_paths: ["../loopex_protocol/lib"], deps: deps()|,
          ~s|elixirc_paths: ["../../outside"], deps: deps()|,
          ~s|elixirc_paths: ["/tmp/outside"], deps: deps()|,
          "elixirc_paths: source_paths(), deps: deps()"
        ] do
      File.write!(core_mix, String.replace(original, "deps: deps()", replacement))
      assert {:error, reasons} = Budget.check_repository(dir)

      assert Enum.any?(reasons, fn reason ->
               String.contains?(reason, "compile source") or
                 String.contains?(reason, "elixirc_paths")
             end)
    end

    File.write!(core_mix, local)

    contract_header = Path.join(dir, "apps/loopex_protocol/lib/contract.hrl")
    File.mkdir_p!(Path.dirname(contract_header))
    File.write!(contract_header, "-define(CONTRACT, true).\n")
    git!(dir, ["add", "apps/loopex_protocol/lib/contract.hrl"])

    assert {:error, reasons} = Budget.check_repository(dir)
    assert Enum.any?(reasons, &String.contains?(&1, "Elixir-only"))
  end

  test "duplicate dependency names are rejected", %{dir: dir} do
    fixture = Path.join(dir, "duplicate.exs")

    File.write!(fixture, """
    defmodule Duplicate.MixProject do
      use Mix.Project
      def project,
        do: [app: :loopex_probe_extension, loopex_role: :extension, version: "0.0.0", deps: deps()]
      defp deps,
        do: [{:loopex_protocol, in_umbrella: true}, {:loopex_protocol, in_umbrella: true}]
    end
    """)

    assert {:error, reasons} = DepsBudget.check_mix_exs(fixture)
    assert Enum.any?(reasons, &String.contains?(&1, "unambiguous record"))
  end

  test "the tracked inventory is dynamic and includes its ordinary root", %{dir: dir} do
    write_inventory(dir)
    track!(dir)

    assert Budget.check_repository(dir) == :ok

    core_directory = Path.join(dir, "apps/loopex")
    moved_core = Path.join(dir, "apps/loopex_real")
    File.rename!(core_directory, moved_core)
    File.ln_s!(moved_core, core_directory)

    assert {:error, reasons} = Budget.check_repository(dir)
    assert Enum.any?(reasons, &String.contains?(&1, "ordinary canonical file"))

    File.rm!(core_directory)
    File.rename!(moved_core, core_directory)

    write_child(dir, "new_boundary", :edge, [
      {:loopex, [in_umbrella: true]},
      {:unregistered_sibling, [in_umbrella: true]}
    ])

    git!(dir, ["add", "apps/new_boundary/mix.exs"])

    assert {:error, reasons} = Budget.check_repository(dir)
    assert Enum.any?(reasons, &String.contains?(&1, "unregistered_sibling"))

    assert {:error, reasons} =
             Budget.check_inventory(dir, List.delete(project_paths(dir), "mix.exs"))

    assert Enum.any?(reasons, &String.contains?(&1, "unknown in-umbrella"))

    write_child(dir, "new_boundary", :edge, [{:loopex, [in_umbrella: true]}])

    ignored = Path.join(dir, "apps/ignored/mix.exs")
    File.mkdir_p!(Path.dirname(ignored))
    File.write!(Path.join(dir, ".gitignore"), "apps/ignored/mix.exs\n")
    File.write!(ignored, child_project("ignored", :edge, [{:loopex, [in_umbrella: true]}]))
    git!(dir, ["add", ".gitignore"])

    assert {:error, reasons} = Budget.check_repository(dir)
    assert Enum.any?(reasons, &String.contains?(&1, "physical project inventory"))
  end

  test "the dynamic inventory cannot omit the fixed contract or core", %{dir: dir} do
    write_inventory(dir)
    File.rm!(Path.join(dir, "apps/loopex_protocol/mix.exs"))
    track!(dir)

    assert {:error, reasons} = Budget.check_repository(dir)
    assert Enum.any?(reasons, &String.contains?(&1, "protocol contract and loopex core"))
  end

  test "unrelated project metadata helpers application data and ordinary aliases are permitted",
       %{
         dir: dir
       } do
    write_inventory(dir)

    root_mix = Path.join(dir, "mix.exs")

    File.write!(root_mix, """
    defmodule Fixture.Root do
      use Mix.Project
      def project do
        [apps_path: "apps", description: description(), aliases: [docs: "docs"], deps: deps()]
      end
      defp description, do: "fixture"
      defp deps, do: []
    end
    """)

    core_mix = Path.join(dir, "apps/loopex/mix.exs")

    File.write!(core_mix, """
    defmodule Fixture.Core do
      use Mix.Project
      def project do
        [
          app: :loopex,
          loopex_role: :core,
          description: helper(),
          compilers: Mix.compilers(),
          aliases: [docs: "docs"],
          deps: deps()
        ]
      end
      def application, do: [extra_applications: runtime_apps(), mod: {Fixture.Application, []}]
      defp runtime_apps, do: [:logger]
      defp helper, do: "ordinary metadata"
      defp deps, do: [{:loopex_protocol, in_umbrella: true}]
    end
    """)

    track!(dir)
    assert Budget.check_repository(dir) == :ok
  end

  test "root and child aliases may not interpose on locked commands", %{dir: dir} do
    write_inventory(dir)
    track!(dir)

    root_mix = Path.join(dir, "mix.exs")
    root = File.read!(root_mix)

    File.write!(
      root_mix,
      String.replace(root, "deps: deps()", "deps: deps(), aliases: [test: \"hidden\"]")
    )

    assert {:error, reasons} = Budget.check_repository(dir)
    assert Enum.any?(reasons, &String.contains?(&1, "aliases replace locked commands"))
    File.write!(root_mix, root)

    child_mix = Path.join(dir, "apps/loopex/mix.exs")
    child = File.read!(child_mix)

    File.write!(
      child_mix,
      String.replace(
        child,
        "deps: deps()",
        "deps: deps(), aliases: [\"loopex.status\": \"hidden\"]"
      )
    )

    assert {:error, reasons} = Budget.check_repository(dir)
    assert Enum.any?(reasons, &String.contains?(&1, "loopex.status"))
  end

  test "M1 planned applications accept only their declared dependency shapes", %{dir: dir} do
    positive = Path.join(dir, "positive")
    write_m1_inventory(positive)
    track!(positive)
    assert Budget.check_repository(positive) == :ok

    negative_cases = [
      {"extra-extension", "outside the exact M1 planned inventory",
       fn root ->
         write_child(root, "loopex_probe_extension", :extension, [
           {:loopex_protocol, [in_umbrella: true]}
         ])
       end},
      {"extra-edge", "outside the exact M1 planned inventory",
       fn root ->
         write_child(root, "loopex_other_edge", :edge, [{:loopex, [in_umbrella: true]}])
       end},
      {"store-external", "may not declare external dependencies",
       fn root ->
         write_child(root, "loopex_store_local", :edge, [
           {:loopex, [in_umbrella: true]},
           {:sqlite_ecto2, "~> 0.6"}
         ])
       end},
      {"wrong-role", "must declare role :edge",
       fn root ->
         write_child(root, "loopex_store_local", :client, [
           {:loopex, [in_umbrella: true]}
         ])
       end},
      {"complete-legacy-reqllm", "require exactly one production loopex dependency",
       fn root ->
         write_child(root, "loopex_llm_reqllm", :edge, [
           {:loopex_protocol, [in_umbrella: true]},
           {:req_llm, @reqllm_requirement}
         ])
       end},
      {"another-external", "must declare exactly external dependency",
       fn root ->
         write_child(root, "loopex_llm_reqllm", :edge, [
           {:loopex, [in_umbrella: true]},
           {:loopex_protocol, [in_umbrella: true]},
           {:req_llm, @reqllm_requirement},
           {:external_probe, "~> 1.0"}
         ])
       end},
      {"wrong-requirement", "must declare exactly external dependency",
       fn root ->
         write_child(root, "loopex_llm_reqllm", :edge, [
           {:loopex, [in_umbrella: true]},
           {:loopex_protocol, [in_umbrella: true]},
           {:req_llm, "~> 1.19"}
         ])
       end}
    ]

    for {name, expected_reason, mutate} <- negative_cases do
      root = Path.join(dir, name)
      write_m1_inventory(root)
      mutate.(root)
      track!(root)

      assert {:error, reasons} = Budget.check_repository(root)
      assert Enum.any?(reasons, &String.contains?(&1, expected_reason))
    end
  end

  test "dependency context separates discovered apps from the selector's declared closure", %{
    dir: dir
  } do
    write_inventory(dir)

    write_child(dir, "loopex_llm_reqllm", :edge, [
      {:loopex_protocol, [in_umbrella: true]},
      {:req_llm, @reqllm_requirement}
    ])

    write_lock!(dir, [{:req_llm, "1.17.1"}])
    core = Path.join(dir, "apps/loopex/mix.exs")

    File.write!(
      core,
      File.read!(core)
      |> String.replace(
        "def application, do: application_metadata()",
        "def application, do: [extra_applications: [:loopex_llm_reqllm]]"
      )
    )

    track!(dir)

    assert {:ok, context} =
             Budget.execution_context(
               dir,
               "apps/loopex/test/runtime_test.exs",
               project_paths(dir)
             )

    assert context.owner == :loopex
    assert context.internal == [:loopex, :loopex_llm_reqllm, :loopex_protocol]
    assert context.allowed == [:loopex, :loopex_protocol]

    source = Path.join(repo_root(), "apps/loopex/lib/mix/tasks/loopex.deps_budget.ex")

    args = [
      "-r",
      source,
      "-e",
      "Loopex.Checks.DepsBudget.main(System.argv())",
      "--",
      "--context",
      "apps/loopex/test/runtime_test.exs"
      | project_paths(dir)
    ]

    assert {output, 0} = System.cmd("elixir", args, cd: dir, stderr_to_stdout: true)

    assert output ==
             "LOOPEX_DEPENDENCY_CONTEXT owner=loopex " <>
               "internal=loopex,loopex_llm_reqllm,loopex_protocol " <>
               "allowed=loopex,loopex_protocol\n"
  end

  test "each role rejects an adjacent outward or wrong-environment edge", %{dir: dir} do
    write_inventory(dir)
    write_child(dir, "loopex_store_local", :edge, [{:loopex, [in_umbrella: true]}])

    client =
      write_child(dir, "loopex_reference_client", :client, [
        {:loopex, [in_umbrella: true]},
        {:loopex_store_local, [in_umbrella: true, only: :test]}
      ])

    extension = Path.join(dir, "extension.exs")

    File.write!(
      extension,
      child_project("loopex_probe_extension", :extension, [
        {:loopex_protocol, [in_umbrella: true]}
      ])
    )

    track!(dir)
    assert Budget.check_repository(dir) == :ok

    write_child(dir, "loopex_reference_client", :client, [
      {:loopex, [in_umbrella: true]},
      {:loopex_store_local, [in_umbrella: true]}
    ])

    assert {:error, reasons} = Budget.check_repository(dir)
    assert Enum.any?(reasons, &String.contains?(&1, "only in tests"))

    write_child(dir, "loopex_reference_client", :client, [
      {:loopex, [in_umbrella: true]},
      {:loopex_store_local, [in_umbrella: true, only: :test]},
      {:external_client, "~> 1.0"}
    ])

    assert {:error, reasons} = Budget.check_repository(dir)
    assert Enum.any?(reasons, &String.contains?(&1, "external dependencies"))

    File.write!(
      client,
      child_project("loopex_reference_client", :client, [
        {:loopex, [in_umbrella: true]},
        {:loopex_store_local, [in_umbrella: true, only: :test]}
      ])
    )

    write_child(dir, "loopex_store_local", :edge, [
      {:loopex, [in_umbrella: true]},
      {:loopex_reference_client, [in_umbrella: true]}
    ])

    assert {:error, reasons} = Budget.check_repository(dir)
    assert Enum.any?(reasons, &String.contains?(&1, "only on core and protocol"))
    write_child(dir, "loopex_store_local", :edge, [{:loopex, [in_umbrella: true]}])

    File.write!(
      extension,
      child_project("loopex_probe_extension", :extension, [{:loopex, [in_umbrella: true]}])
    )

    assert {:error, reasons} = Budget.check_mix_exs(extension)
    assert Enum.any?(reasons, &String.contains?(&1, "inward only on protocol"))

    core = Path.join(dir, "apps/loopex/mix.exs")

    File.write!(
      core,
      child_project("loopex", :core, [
        {:loopex_protocol, [in_umbrella: true]},
        {:test_probe, "~> 1.0", [only: :test]}
      ])
    )

    assert {:error, reasons} = Budget.check_repository(dir)
    assert Enum.any?(reasons, &String.contains?(&1, "literal dependency data"))
  end

  test "child identity must match its directory and decoys cannot supply it", %{dir: dir} do
    write_inventory(dir)
    path = Path.join(dir, "apps/loopex/mix.exs")

    File.write!(path, """
    defmodule Fixture.Decoy do
      use Mix.Project
      @decoy [app: :loopex, loopex_role: :core]
      def decoy, do: @decoy
      def project,
        do: [app: :different, loopex_role: :core, deps: deps(), description: decoy()]
      defp deps, do: [{:loopex_protocol, in_umbrella: true}]
    end
    """)

    track!(dir)
    assert {:error, reasons} = Budget.check_repository(dir)
    assert Enum.any?(reasons, &String.contains?(&1, "does not match its directory"))
  end

  test "an extra guarded project clause cannot hide behind one literal clause", %{dir: dir} do
    write_inventory(dir)
    path = Path.join(dir, "apps/loopex/mix.exs")

    File.write!(path, """
    defmodule Fixture.Guarded do
      use Mix.Project
      def project() when true,
        do: [app: :different, loopex_role: :edge, deps: []]
      def project,
        do: [app: :loopex, loopex_role: :core, deps: deps()]
      defp deps, do: [{:loopex_protocol, in_umbrella: true}]
    end
    """)

    track!(dir)
    assert {:error, reasons} = Budget.check_repository(dir)
    assert Enum.any?(reasons, &String.contains?(&1, "project/0 must have exactly one definition"))
  end

  test "the bound dependency verdict bypasses evaluated Mix tasks", %{dir: dir} do
    write_inventory(dir)
    track!(dir)
    source = Path.join(repo_root(), "apps/loopex/lib/mix/tasks/loopex.deps_budget.ex")

    assert [_, load_package_source] =
             Regex.run(
               ~r/^  defp load_package\(cache_root, record, protected\) do\n(.*?)^  defp archive_not_protected\(/ms,
               File.read!(source)
             )

    ordered_archive_guards = [
      ":ok <- archive_not_protected(archive, archive_stat, protected)",
      "{:ok, bytes} <- File.read(archive)",
      "{:ok, %File.Stat{type: :regular} = after_read_stat} <- File.lstat(archive)",
      ":ok <- unchanged_archive_identity(archive, archive_stat, after_read_stat)",
      ":ok <- archive_not_protected(archive, after_read_stat, protected)",
      "true <- digest(bytes) == record.package_sha"
    ]

    guard_indices =
      Enum.map(ordered_archive_guards, fn guard ->
        case :binary.match(load_package_source, guard) do
          {index, _length} -> index
          :nomatch -> nil
        end
      end)

    assert Enum.all?(guard_indices, &is_integer/1)

    assert guard_indices
           |> Enum.chunk_every(2, 1, :discard)
           |> Enum.all?(fn [left, right] -> left < right end)

    args = [
      "-r",
      source,
      "-e",
      "Loopex.Checks.DepsBudget.main(System.argv())",
      "--"
      | project_paths(dir)
    ]

    assert {"", 0} = System.cmd("elixir", args, cd: dir, stderr_to_stdout: true)

    core_mix = Path.join(dir, "apps/loopex/mix.exs")

    File.write!(
      core_mix,
      child_project("loopex", :core, [
        {:loopex_protocol, [in_umbrella: true, path: "../shadow-contract"]}
      ])
      |> String.replace(
        "use Mix.Project",
        """
        use Mix.Project
        if true do
          defmodule Mix.Tasks.Loopex.Status do
            use Mix.Task
            def run(_arguments), do: :ok
          end
        end
        """
      )
    )

    assert {output, status} = System.cmd("elixir", args, cd: dir, stderr_to_stdout: true)
    assert status != 0
    assert output =~ "literal dependency data"

    File.write!(
      core_mix,
      child_project("loopex", :core, [{:loopex_protocol, [in_umbrella: true]}])
    )

    write_child(dir, "loopex_llm_reqllm", :edge, [
      {:loopex_protocol, [in_umbrella: true]},
      {:req_llm, @reqllm_requirement}
    ])

    git!(dir, ["add", "apps/loopex/mix.exs", "apps/loopex_llm_reqllm/mix.exs"])

    cache = Path.join(dir, "hex-cache")
    destination = Path.join(dir, "materialized")
    protected_ids = Path.join(dir, "protected-ids")
    File.write!(protected_ids, "")

    write_hex_fixture!(dir, cache, [
      {"lib/probe.ex", "defmodule Probe, do: :ok\n"},
      {"mix.exs", "defmodule Probe.MixProject, do: nil\n"}
    ])

    materialize_args = [
      "-r",
      source,
      "-e",
      "Loopex.Checks.DepsBudget.main(System.argv())",
      "--",
      "--materialize",
      cache,
      destination,
      protected_ids
    ]

    assert {"", 0} = System.cmd("elixir", materialize_args, cd: dir, stderr_to_stdout: true)
    assert File.read!(Path.join(destination, "req_llm/lib/probe.ex")) =~ "defmodule Probe"

    archive = Path.join([cache, "hexpm", "req_llm-1.17.1.tar"])
    protected_fixture = Path.join(dir, "protected-fixture.tar")
    File.ln!(archive, protected_fixture)
    stat = File.lstat!(protected_fixture)
    File.write!(protected_ids, "#{stat.major_device}:#{stat.inode}\n")
    protected_destination = Path.join(dir, "protected-materialized")
    protected_args = List.replace_at(materialize_args, -2, protected_destination)

    assert {refusal, status} =
             System.cmd("elixir", protected_args, cd: dir, stderr_to_stdout: true)

    assert status != 0
    assert refusal =~ "protected"
    refute File.exists?(protected_destination)
    File.rm!(protected_fixture)
    File.write!(protected_ids, "")

    unsafe_destination = Path.join(dir, "unsafe-materialized")
    write_hex_fixture!(dir, cache, [{"../escaped", "not allowed"}])

    unsafe_args = List.replace_at(materialize_args, -2, unsafe_destination)
    assert {refusal, status} = System.cmd("elixir", unsafe_args, cd: dir, stderr_to_stdout: true)
    assert status != 0
    assert refusal =~ "materialization refused"
    refute File.exists?(Path.join(dir, "escaped"))

    File.write!(Path.join(dir, "mix.lock"), "System.put_env(\"LOOPEX_EVALUATED\", \"yes\")\n")
    git!(dir, ["add", "mix.lock"])
    literal_destination = Path.join(dir, "literal-materialized")
    literal_args = List.replace_at(materialize_args, -2, literal_destination)

    assert {_refusal, status} =
             System.cmd("elixir", literal_args, cd: dir, stderr_to_stdout: true)

    assert status != 0
    refute File.exists?(literal_destination)
  end

  test "offline materializer proves the exact floor-compatible lock closure", %{dir: dir} do
    valid_root = Path.join(dir, "valid")
    valid_cache = Path.join(dir, "valid-cache")
    valid_packages = materializer_packages()
    write_materializer_fixture!(valid_root, valid_cache, valid_packages)
    valid_destination = Path.join(dir, "valid-materialized")

    assert {"", 0} = materialize(valid_root, valid_cache, valid_destination)
    assert File.exists?(Path.join(valid_destination, "req_llm/lib/req_llm.ex"))
    assert File.exists?(Path.join(valid_destination, "bridge/lib/bridge.ex"))
    assert File.exists?(Path.join(valid_destination, "leaf/lib/leaf.ex"))

    for package <- valid_packages do
      marker =
        valid_destination
        |> Path.join(package.name)
        |> Path.join(".hex")
        |> File.read!()
        |> :erlang.binary_to_term()

      archive = Path.join([valid_cache, "hexpm", "#{package.name}-#{package.version}.tar"])
      outer_checksum = :crypto.hash(:sha256, File.read!(archive)) |> Base.encode16(case: :lower)

      assert marker ==
               {{:hex, 2, 0},
                %{
                  name: package.name,
                  version: package.version,
                  repo: "hexpm",
                  managers: package.managers,
                  inner_checksum: String.duplicate("a", 64),
                  outer_checksum: outer_checksum
                }}
    end

    cases = [
      {"transitive-floor", "excludes the bound 1.17.0 floor",
       fn packages -> update_package(packages, "bridge", &Map.put(&1, :elixir, "~> 1.18")) end},
      {"malformed-elixir", "Elixir requirement is malformed",
       fn packages -> update_package(packages, "bridge", &Map.put(&1, :elixir, "not a range")) end},
      {"duplicate-elixir", "duplicate \"elixir\" field",
       fn packages ->
         update_package(packages, "bridge", &Map.put(&1, :duplicate_elixir, true))
       end},
      {"missing-elixir", "exactly one Elixir requirement",
       fn packages -> update_package(packages, "bridge", &Map.put(&1, :elixir, nil)) end},
      {"name-mismatch", "name or version does not match mix.lock",
       fn packages ->
         update_package(packages, "bridge", &Map.put(&1, :metadata_name, "other"))
       end},
      {"version-mismatch", "name or version does not match mix.lock",
       fn packages ->
         update_package(packages, "bridge", &Map.put(&1, :metadata_version, "2.0.1"))
       end},
      {"build-tool-mismatch", "build_tools do not match mix.lock",
       fn packages ->
         update_package(packages, "bridge", &Map.put(&1, :metadata_managers, [:rebar3]))
       end},
      {"dependency-mismatch", "requirements do not match mix.lock",
       fn packages -> update_package(packages, "req_llm", &Map.put(&1, :metadata_deps, [])) end},
      {"payload-scm-marker", "must not supply the Hex SCM marker",
       fn packages ->
         update_package(packages, "bridge", &Map.put(&1, :payload_hex_marker, true))
       end},
      {"missing-lock", "missing required non-optional package bridge",
       fn [root | rest] -> [root | Enum.reject(rest, &(&1.name == "bridge"))] end},
      {"unsatisfied-requirement", "does not satisfy requirement \"~> 9.0\"",
       fn packages ->
         update_package(packages, "req_llm", fn package ->
           Map.put(package, :deps, [lock_dependency("bridge", "~> 9.0")])
         end)
       end},
      {"unreachable-lock", "outside the exact non-optional ReqLLM closure",
       fn packages -> packages ++ [package("orphan", "4.0.0", [:mix], "~> 1.17", [])] end}
    ]

    for {name, expected_reason, mutate} <- cases do
      root = Path.join(dir, name)
      cache = Path.join(dir, "#{name}-cache")
      destination = Path.join(dir, "#{name}-materialized")
      write_materializer_fixture!(root, cache, mutate.(valid_packages))

      assert {output, status} = materialize(root, cache, destination), name
      assert status != 0, name
      assert output =~ expected_reason, "#{name}: #{output}"
      refute File.exists?(destination), name
    end
  end

  test "the contract protocol namespace is not a runtime reverse edge", %{dir: dir} do
    lib = Path.join(dir, "lib")
    File.mkdir_p!(lib)

    File.write!(Path.join(lib, "protocol.ex"), """
    defmodule Loopex.Protocol.Envelope do
      def value(record), do: {Loopex.Protocol.Value, Elixir.Loopex.Protocol.Value, record.name}
      def literal, do: :"Elixir.Loopex.Protocol.Value"
    end
    """)

    assert reverse_edges(lib) == :ok
  end

  test "static runtime references outside the protocol namespace are rejected", %{dir: dir} do
    lib = Path.join(dir, "lib")
    File.mkdir_p!(lib)

    File.write!(Path.join(lib, "leak.ex"), """
    defmodule LoopexProtocol.Leak do
      alias Loopex.Runtime, as: Runtime
      def call, do: {Loopex.version(), Elixir.Loopex.Session, Runtime, :"Elixir.Loopex.Store"}
    end
    """)

    assert {:error, reasons} = reverse_edges(lib)
    assert Enum.any?(reasons, &String.contains?(&1, "runtime module Loopex"))
    assert Enum.any?(reasons, &String.contains?(&1, "Loopex.Session"))
    assert Enum.any?(reasons, &String.contains?(&1, "Loopex.Store"))
  end

  test "a reverse edge from contract to runtime is rejected", %{dir: dir} do
    lib = Path.join(dir, "lib")
    File.mkdir_p!(lib)
    File.write!(Path.join(lib, "m0-static.ex"), "defmodule M0.Static, do: Loopex.version()\n")

    assert {:error, reasons} = reverse_edges(lib)
    assert Enum.any?(reasons, &String.contains?(&1, "runtime module Loopex"))
  end

  test "dynamic module dispatch is rejected independent of formatting", %{dir: dir} do
    lib = Path.join(dir, "lib")
    File.mkdir_p!(lib)

    File.write!(Path.join(lib, "dynamic.ex"), """
    defmodule LoopexProtocol.Dynamic do
      def call do
        name =
          ["Elixir", "Loopex"]
          |> Enum.join(".")

        apply(
          String.to_atom(name),
          :version,
          []
        )
      end

      def remote(module) do
        {
          module.version(),
          (module).version(),
          Kernel.apply(module, :version, []),
          :erlang.apply(module, :version, []),
          Function.capture(module, :version, 0),
          :erlang.make_fun(module, :version, 0),
          &module.version/0,
          &module.version(&1)
        }
      end
    end
    """)

    assert {:error, reasons} = reverse_edges(lib)
    assert Enum.any?(reasons, &String.contains?(&1, "dynamic module dispatch"))
  end

  test "a dynamic module reference across the boundary is rejected", %{dir: dir} do
    lib = Path.join(dir, "lib")
    File.mkdir_p!(lib)

    File.write!(Path.join(lib, "m0-dynamic.ex"), """
    defmodule M0.Dynamic do
      def call, do: apply(String.to_atom("Elixir.Loopex"), :version, [])
    end
    """)

    assert {:error, reasons} = reverse_edges(lib)
    assert Enum.any?(reasons, &String.contains?(&1, "dynamic module dispatch"))
  end

  test "plain module-like data is not treated as an executable reference", %{dir: dir} do
    lib = Path.join(dir, "lib")
    File.mkdir_p!(lib)

    File.write!(Path.join(lib, "data.ex"), """
    defmodule LoopexProtocol.Data do
      def value, do: "Elixir.Loopex"
    end
    """)

    assert reverse_edges(lib) == :ok
  end

  test "all declared contract compile roots receive reverse-edge checks", %{dir: dir} do
    write_inventory(dir)
    protocol_mix = Path.join(dir, "apps/loopex_protocol/mix.exs")

    File.write!(
      protocol_mix,
      File.read!(protocol_mix)
      |> String.replace("deps: deps()", ~s|elixirc_paths: ["lib", "schema"], deps: deps()|)
    )

    schema = Path.join(dir, "apps/loopex_protocol/schema/leak.ex")
    File.mkdir_p!(Path.dirname(schema))
    File.write!(schema, "defmodule Contract.Leak, do: def(call, do: Loopex.version())\n")
    track!(dir)

    assert {:error, reasons} = Budget.check_repository(dir)
    assert Enum.any?(reasons, &String.contains?(&1, "runtime module Loopex"))
  end

  # The reverse-edge scan is scoped to the contract application's lib directory,
  # so a fixture tree is exercised through the same code path by pointing the
  # scan at it rather than by duplicating the logic in the test.
  defp reverse_edges(lib) do
    case DepsBudget.reverse_edge_check(lib) do
      [] -> :ok
      reasons -> {:error, reasons}
    end
  end

  defp write_inventory(root) do
    File.mkdir_p!(root)

    File.write!(Path.join(root, "mix.exs"), """
    defmodule Fixture.Umbrella do
      use Mix.Project
      def project, do: [apps_path: "apps", deps: deps()]
      defp deps, do: []
    end
    """)

    write_child(root, "loopex_protocol", :contract, [])

    write_child(root, "loopex", :core, [
      {:loopex_protocol, [in_umbrella: true]}
    ])
  end

  defp write_m1_inventory(root) do
    write_inventory(root)

    write_child(root, "loopex_store_local", :edge, [
      {:loopex, [in_umbrella: true]},
      {:loopex_protocol, [in_umbrella: true]}
    ])

    write_child(root, "loopex_llm_reqllm", :edge, [
      {:loopex, [in_umbrella: true]},
      {:loopex_protocol, [in_umbrella: true]},
      {:req_llm, @reqllm_requirement}
    ])

    write_child(root, "loopex_executor_local", :edge, [
      {:loopex, [in_umbrella: true]}
    ])

    write_child(root, "loopex_reference_client", :client, [
      {:loopex, [in_umbrella: true]},
      {:loopex_store_local, [in_umbrella: true, only: :test]},
      {:loopex_llm_reqllm, [in_umbrella: true, only: :test]},
      {:loopex_executor_local, [in_umbrella: true, only: :test]}
    ])

    write_lock!(root, [{:req_llm, "1.17.1"}])
  end

  defp write_child(root, directory, role, dependencies) do
    directory_path = Path.join([root, "apps", directory])
    File.mkdir_p!(directory_path)
    path = Path.join(directory_path, "mix.exs")
    File.write!(path, child_project(directory, role, dependencies))
    path
  end

  defp child_project(directory, role, dependencies) do
    """
    defmodule Fixture.#{Macro.camelize(directory)} do
      use Mix.Project
      def project do
        [app: :#{directory}, loopex_role: :#{role}, description: description(), deps: deps()]
      end
      def application, do: application_metadata()
      defp application_metadata, do: [extra_applications: []]
      defp description, do: "fixture"
      defp deps, do: #{inspect(dependencies, pretty: true)}
    end
    """
  end

  defp track!(root) do
    git!(root, ["init", "-q"])
    git!(root, ["add", "."])
  end

  defp project_paths(root) do
    ["mix.exs" | Path.wildcard(Path.join(root, "apps/*/mix.exs"))]
    |> Enum.map(fn path ->
      if path == "mix.exs", do: path, else: Path.relative_to(path, root)
    end)
    |> Enum.sort()
  end

  defp git!(root, args) do
    case System.cmd("git", ["-C", root | args], stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, status} -> flunk("git #{Enum.join(args, " ")} failed #{status}: #{output}")
    end
  end

  defp write_hex_fixture!(root, cache, inner_entries) do
    contents_path = Path.join(root, "fixture-contents.tar.gz")

    tar_entries =
      Enum.map(inner_entries, fn {name, contents} -> {String.to_charlist(name), contents} end)

    :ok = :erl_tar.create(String.to_charlist(contents_path), tar_entries, [:compressed])
    contents = File.read!(contents_path)
    checksum = String.duplicate("a", 64)
    archive_path = Path.join([cache, "hexpm", "req_llm-1.17.1.tar"])
    File.mkdir_p!(Path.dirname(archive_path))

    metadata =
      [
        {"name", "req_llm"},
        {"version", "1.17.1"},
        {"elixir", "~> 1.17"},
        {"requirements", []},
        {"build_tools", ["mix"]}
      ]
      |> Enum.map_join(fn term -> :io_lib.format("~tp.~n", [binary_term(term)]) end)
      |> IO.iodata_to_binary()

    :ok =
      :erl_tar.create(
        String.to_charlist(archive_path),
        [
          {~c"VERSION", "3"},
          {~c"CHECKSUM", String.upcase(checksum)},
          {~c"metadata.config", metadata},
          {~c"contents.tar.gz", contents}
        ],
        []
      )

    archive_sha = :crypto.hash(:sha256, File.read!(archive_path)) |> Base.encode16(case: :lower)

    File.write!(Path.join(root, "mix.lock"), """
    %{
      "req_llm": {:hex, :req_llm, "1.17.1", "#{checksum}", [:mix], [], "hexpm", "#{archive_sha}"}
    }
    """)

    git!(root, ["add", "mix.lock"])
  end

  defp binary_term({key, value}) when is_binary(key), do: {key, binary_term(value)}
  defp binary_term(values) when is_list(values), do: Enum.map(values, &binary_term/1)
  defp binary_term(value) when is_binary(value), do: value
  defp binary_term(value), do: value

  defp materializer_packages do
    [
      package("req_llm", "1.17.1", [:mix], "~> 1.17", [
        lock_dependency("bridge", "~> 2.0")
      ]),
      package("bridge", "2.0.0", [:mix], ">= 1.17.0", [
        lock_dependency("leaf", "~> 3.0")
      ]),
      package("leaf", "3.0.0", [:rebar3], nil, [])
    ]
  end

  defp package(name, version, managers, elixir, dependencies) do
    %{
      name: name,
      version: version,
      managers: managers,
      elixir: elixir,
      deps: dependencies
    }
  end

  defp lock_dependency(name, requirement, optional \\ false) do
    %{name: name, requirement: requirement, optional: optional}
  end

  defp update_package(packages, name, update) do
    Enum.map(packages, fn package ->
      if package.name == name, do: update.(package), else: package
    end)
  end

  defp write_materializer_fixture!(root, cache, packages) do
    write_m1_inventory(root)
    lock_entries = Enum.map(packages, &write_package_archive!(root, cache, &1))
    File.write!(Path.join(root, "mix.lock"), "%{\n#{Enum.join(lock_entries, ",\n")}\n}\n")
    track!(root)
  end

  defp write_package_archive!(root, cache, package) do
    contents_path = Path.join(root, "#{package.name}-contents.tar.gz")
    module = Macro.camelize(package.name)

    contents_entries =
      [
        {String.to_charlist("lib/#{package.name}.ex"), "defmodule #{module}, do: :ok\n"},
        {~c"mix.exs", "defmodule #{module}.MixProject, do: nil\n"}
      ]

    contents_entries =
      if Map.get(package, :payload_hex_marker, false),
        do: contents_entries ++ [{~c".hex", "forged authority"}],
        else: contents_entries

    :ok =
      :erl_tar.create(
        String.to_charlist(contents_path),
        contents_entries,
        [:compressed]
      )

    contents = File.read!(contents_path)
    File.rm!(contents_path)
    checksum = String.duplicate("a", 64)
    archive_path = Path.join([cache, "hexpm", "#{package.name}-#{package.version}.tar"])
    File.mkdir_p!(Path.dirname(archive_path))

    metadata_dependencies = Map.get(package, :metadata_deps, package.deps)

    metadata_terms = [
      {"name", Map.get(package, :metadata_name, package.name)},
      {"version", Map.get(package, :metadata_version, package.version)}
    ]

    metadata_terms =
      if is_nil(package.elixir),
        do: metadata_terms,
        else: metadata_terms ++ [{"elixir", package.elixir}]

    metadata_terms =
      if Map.get(package, :duplicate_elixir, false),
        do: metadata_terms ++ [{"elixir", package.elixir}],
        else: metadata_terms

    metadata_terms =
      metadata_terms ++
        [
          {"requirements", Enum.map(metadata_dependencies, &metadata_dependency/1)},
          {"build_tools",
           package |> Map.get(:metadata_managers, package.managers) |> Enum.map(&Atom.to_string/1)}
        ]

    metadata =
      metadata_terms
      |> Enum.map_join(fn term -> :io_lib.format("~tp.~n", [binary_term(term)]) end)
      |> IO.iodata_to_binary()

    :ok =
      :erl_tar.create(
        String.to_charlist(archive_path),
        [
          {~c"VERSION", "3"},
          {~c"CHECKSUM", String.upcase(checksum)},
          {~c"metadata.config", metadata},
          {~c"contents.tar.gz", contents}
        ],
        []
      )

    archive_sha = :crypto.hash(:sha256, File.read!(archive_path)) |> Base.encode16(case: :lower)
    dependencies = Enum.map_join(package.deps, ", ", &lock_dependency_source/1)

    ~s|  "#{package.name}": {:hex, :#{package.name}, "#{package.version}", "#{checksum}", #{inspect(package.managers)}, [#{dependencies}], "hexpm", "#{archive_sha}"}|
  end

  defp metadata_dependency(dependency) do
    [
      {"name", dependency.name},
      {"app", dependency.name},
      {"optional", dependency.optional},
      {"requirement", dependency.requirement},
      {"repository", "hexpm"}
    ]
  end

  defp lock_dependency_source(dependency) do
    ~s|{:#{dependency.name}, #{inspect(dependency.requirement)}, [hex: :#{dependency.name}, repo: "hexpm", optional: #{dependency.optional}]}|
  end

  defp materialize(root, cache, destination) do
    source = Path.join(repo_root(), "apps/loopex/lib/mix/tasks/loopex.deps_budget.ex")
    protected = Path.join(root, "protected-ids")
    File.write!(protected, "")

    System.cmd(
      "elixir",
      [
        "-r",
        source,
        "-e",
        "Loopex.Checks.DepsBudget.main(System.argv())",
        "--",
        "--materialize",
        cache,
        destination,
        protected
      ],
      cd: root,
      stderr_to_stdout: true
    )
  end

  defp write_lock!(root, packages) do
    entries =
      Enum.map_join(packages, ",\n", fn {name, version} ->
        checksum = String.duplicate("a", 64)
        package_sha = String.duplicate("b", 64)

        ~s|  "#{name}": {:hex, :#{name}, "#{version}", "#{checksum}", [:mix], [], "hexpm", "#{package_sha}"}|
      end)

    File.write!(Path.join(root, "mix.lock"), "%{\n#{entries}\n}\n")
  end
end
