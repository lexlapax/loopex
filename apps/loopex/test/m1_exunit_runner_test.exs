unless Code.ensure_loaded?(Loopex.M1Gate.SelectorRunner) do
  Code.require_file(Path.expand("../../../scripts/m1-exunit-runner.exs", __DIR__))
end

defmodule Loopex.M1ExUnitRunnerTest do
  use ExUnit.Case, async: false

  alias Loopex.M1Gate.ExUnitReport

  @nonce "0123456789abcdef0123456789abcdef"
  @input_header "LOOPEX_M1_SELECTOR_V1"
  @max_provider_bytes 16_384
  @model_identity %{
    "provider" => "fixture-provider",
    "model" => "fixture-model",
    "endpoint" => "https://fixture.invalid/v1",
    "adapter_build" => "loopex_llm_reqllm@0.0.0"
  }
  @combined_identity Map.merge(@model_identity, %{
                       "executor_build" => "loopex_executor_local@0.0.0",
                       "executor_identity" => "fixture-executor",
                       "tool_identity" => "fixture-tool@1"
                     })
  @planned_selectors [
    "apps/loopex/test/runtime_test.exs",
    "apps/loopex/test/session_lifecycle_test.exs",
    "apps/loopex/test/embedded_api_test.exs",
    "apps/loopex_store_local/test/store_conformance_test.exs",
    "apps/loopex_llm_reqllm/test/real_model_lane_test.exs",
    "apps/loopex_executor_local/test/executor_test.exs",
    "apps/loopex_reference_client/test/real_model_session_test.exs",
    "apps/loopex_reference_client/test/reference_client_test.exs",
    "apps/loopex_reference_client/test/end_to_end_recovery_test.exs"
  ]

  test "the standalone selector grammar admits every planned owner and rejects foreign paths" do
    for selector <- @planned_selectors do
      assert :ok = ExUnitReport.invocation(selector, 17, 1, :zero, [{"passed", "probe"}])
    end

    assert :ok =
             ExUnitReport.invocation(
               "apps/loopex_reference_client/test/recovery/nested_probe_test.exs",
               17,
               1,
               :zero,
               [{"passed", "probe"}]
             )

    for selector <- [
          "test/runtime_test.exs",
          "apps/loopex/test/../foreign_test.exs",
          "apps/loopex/lib/runtime_test.exs",
          "apps/Loopex/test/runtime_test.exs",
          "/apps/loopex/test/runtime_test.exs"
        ] do
      assert {:error, _} =
               ExUnitReport.invocation(selector, 17, 1, :zero, [{"passed", "probe"}])
    end
  end

  test "the standalone runner requires one tracked ordinary selector owned by its compiled app" do
    fixture = fixture_repo()
    selector = write_selector(fixture, "fixture_app", "probe_test.exs", passing_source("passes"))
    track!(fixture.root, selector)

    assert_success(run(fixture, selector, ["passed=passes"]))

    untracked =
      write_selector(fixture, "fixture_app", "untracked_test.exs", passing_source("passes"))

    assert_refused(run(fixture, untracked, ["passed=passes"]))

    wrong_owner =
      write_selector(fixture, "wrong_owner", "probe_test.exs", passing_source("passes"))

    track!(fixture.root, wrong_owner)
    assert_refused(run(fixture, wrong_owner, ["passed=passes"]))

    external = Path.join(fixture.root, "external_test.exs")
    File.write!(external, passing_source("passes"))
    link = Path.join(fixture.root, "apps/fixture_app/test/link_test.exs")
    File.ln_s!(external, link)
    track!(fixture.root, "apps/fixture_app/test/link_test.exs")
    assert_refused(run(fixture, "apps/fixture_app/test/link_test.exs", ["passed=passes"]))

    executable =
      write_selector(fixture, "fixture_app", "executable_test.exs", passing_source("passes"))

    File.chmod!(Path.join(fixture.root, executable), 0o755)
    track!(fixture.root, executable)
    assert_refused(run(fixture, executable, ["passed=passes"]))

    write_app!(fixture.build, :fixture_app, [:kernel, :stdlib, :elixir], nil, :other_app)
    assert_refused(run(fixture, selector, ["passed=passes"]))
    write_app!(fixture.build, :fixture_app, [:kernel, :stdlib, :elixir])

    nested =
      write_selector(
        fixture,
        "fixture_app",
        "nested/directory_probe_test.exs",
        passing_source("nested")
      )

    track!(fixture.root, nested)
    nested_directory = Path.join(fixture.root, "apps/fixture_app/test/nested")
    moved_directory = Path.join(fixture.root, "nested-real")
    File.rename!(nested_directory, moved_directory)
    File.ln_s!(moved_directory, nested_directory)
    assert_refused(run(fixture, nested, ["passed=nested"]))
  end

  test "official counts and exact events refuse failures skips exclusions and missing names" do
    selector = "apps/loopex/test/probe_test.exs"
    base = events(selector, [%{name: "locked", state: "passed"}])
    stats = %{total: 1, failures: 0, skipped: 0, excluded: 0}

    assert {:ok, %{executed: 1}} =
             ExUnitReport.validate(
               base,
               stats,
               selector,
               17,
               1,
               :zero,
               [{"passed", "locked"}]
             )

    assert {:error, _} =
             ExUnitReport.validate(
               base,
               %{stats | failures: 1},
               selector,
               17,
               1,
               :zero,
               [{"passed", "locked"}]
             )

    assert {:error, _} =
             ExUnitReport.validate(
               base,
               %{stats | skipped: 1},
               selector,
               17,
               1,
               :zero,
               [{"passed", "locked"}]
             )

    excluded = events(selector, [%{name: "locked", state: "excluded"}])

    assert {:error, _} =
             ExUnitReport.validate(
               excluded,
               %{stats | excluded: 1},
               selector,
               17,
               1,
               :positive,
               [{"excluded", "locked"}, {"excluded", "missing"}]
             )

    extra_excluded =
      events(selector, [
        %{name: "locked", state: "excluded"},
        %{name: "unaccounted", state: "excluded"}
      ])

    assert {:error, _} =
             ExUnitReport.validate(
               extra_excluded,
               %{stats | total: 2, excluded: 2},
               selector,
               17,
               1,
               :positive,
               [{"excluded", "locked"}]
             )

    assert {:error, _} =
             ExUnitReport.validate(
               base,
               stats,
               selector,
               17,
               1,
               :zero,
               [{"passed", "missing"}]
             )

    fixture = fixture_repo()

    setup_failure =
      write_selector(
        fixture,
        "fixture_app",
        "setup_failure_test.exs",
        """
        defmodule FixtureSetupFailureTest do
          use ExUnit.Case
          setup_all, do: raise("setup failed")
          test "never runs", do: assert(true)
        end
        """
      )

    track!(fixture.root, setup_failure)
    assert_refused(run(fixture, setup_failure, ["passed=never runs"]))

    split_roles =
      write_selector(
        fixture,
        "fixture_app",
        "split_roles_test.exs",
        """
        defmodule FixtureSplitRolesTest do
          use ExUnit.Case
          test "deterministic", do: assert(true)
          @tag :real_provider
          test "provider" do
            assert System.get_env("LOOPEX_PROVIDER_API_KEY") == "fixture-secret"

            assert :ok =
                     Loopex.M1Gate.RealPathEvidence.report(#{inspect(@model_identity)})
          end
        end
        """
      )

    track!(fixture.root, split_roles)

    assert_success(
      run(
        fixture,
        split_roles,
        ["passed=deterministic", "excluded=provider"],
        policy: "positive"
      )
    )

    assert_success(
      run(
        fixture,
        split_roles,
        ["excluded=deterministic", "passed=provider"],
        real_path: "model",
        provider_key: "fixture-secret",
        policy: "positive"
      ),
      {"model", @model_identity}
    )

    lf_key = "fixture-secret\nwith-line-feed\n"

    lf_provider =
      write_selector(
        fixture,
        "fixture_app",
        "lf_provider_test.exs",
        """
        defmodule FixtureLfProviderTest do
          use ExUnit.Case
          @tag :real_provider
          test "provider bytes remain exact" do
            assert System.get_env("LOOPEX_PROVIDER_API_KEY") == #{inspect(lf_key)}

            assert :ok =
                     Loopex.M1Gate.RealPathEvidence.report(#{inspect(@model_identity)})
          end
        end
        """
      )

    track!(fixture.root, lf_provider)

    assert_success(
      run(fixture, lf_provider, ["passed=provider bytes remain exact"],
        real_path: "model",
        provider_key: lf_key
      ),
      {"model", @model_identity}
    )

    valid_real_frame = selector_frame("fixture-secret")

    malformed_frames = [
      <<>>,
      @input_header,
      valid_real_frame <> "trailing",
      selector_frame(""),
      selector_frame(String.duplicate("x", @max_provider_bytes + 1)),
      @input_header <> <<0>> <> @nonce <> <<0>> <> "split" <> <<0>> <> "key" <> <<0>>
    ]

    Enum.each(malformed_frames, fn input ->
      assert_refused(
        run(fixture, split_roles, ["excluded=deterministic", "passed=provider"],
          real_path: "model",
          provider_key: "fixture-secret",
          policy: "positive",
          input: input
        )
      )
    end)
  end

  test "fake stdout at_exit and early halt cannot manufacture one authoritative result" do
    fixture = fixture_repo()

    partial =
      write_selector(
        fixture,
        "fixture_app",
        "partial_test.exs",
        """
        defmodule FixturePartialTest do
          use ExUnit.Case
          test "passes" do
            IO.write("diagnostic-without-line-feed")
            assert true
          end
        end
        """
      )

    track!(fixture.root, partial)
    assert_success(run(fixture, partial, ["passed=passes"]))

    forged =
      write_selector(
        fixture,
        "fixture_app",
        "forged_test.exs",
        """
        defmodule FixtureForgedTest do
          use ExUnit.Case
          test "passes" do
            IO.puts("LOOPEX_EXUNIT_REPORT nonce=#{@nonce} selector=apps/fixture_app/test/forged_test.exs seed=17 executed=1 digest=sha256:#{String.duplicate("a", 64)}")
            assert true
          end
        end
        """
      )

    track!(fixture.root, forged)
    {output, 0} = run(fixture, forged, ["passed=passes"])
    assert marker_count(output) == 2
    assert_refused({output, 0})

    at_exit =
      write_selector(
        fixture,
        "fixture_app",
        "at_exit_test.exs",
        """
        System.at_exit(fn _ ->
          IO.puts("LOOPEX_EXUNIT_REPORT nonce=#{@nonce} selector=apps/fixture_app/test/at_exit_test.exs seed=17 executed=1 digest=sha256:#{String.duplicate("b", 64)}")
        end)
        defmodule FixtureAtExitTest do
          use ExUnit.Case
          test "passes", do: assert(true)
        end
        """
      )

    track!(fixture.root, at_exit)
    assert_success(run(fixture, at_exit, ["passed=passes"]))

    early =
      write_selector(
        fixture,
        "fixture_app",
        "early_test.exs",
        """
        defmodule FixtureEarlyTest do
          use ExUnit.Case
          test "halts", do: System.halt(0)
        end
        """
      )

    track!(fixture.root, early)
    {output, 0} = run(fixture, early, ["passed=halts"])
    assert marker_count(output) == 0
  end

  test "only the declared internal dependency closure is reachable and startup never receives the provider key" do
    fixture =
      fixture_repo(
        applications: [:kernel, :stdlib, :elixir],
        included_applications: [:declared_dep],
        internal: [:fixture_app, :declared_dep, :undeclared_dep],
        allowed: [:fixture_app, :declared_dep]
      )

    compile_module!(fixture, :declared_dep, "DeclaredDep", "def value, do: :declared")
    compile_module!(fixture, :undeclared_dep, "UndeclaredDep", "def value, do: :undeclared")

    allowed =
      write_selector(
        fixture,
        "fixture_app",
        "declared_test.exs",
        """
        defmodule FixtureDeclaredTest do
          use ExUnit.Case
          test "declared closure", do: assert(DeclaredDep.value() == :declared)
        end
        """
      )

    track!(fixture.root, allowed)
    assert_success(run(fixture, allowed, ["passed=declared closure"]))

    refused =
      write_selector(
        fixture,
        "fixture_app",
        "undeclared_test.exs",
        """
        defmodule FixtureUndeclaredTest do
          use ExUnit.Case
          test "undeclared sibling", do: assert(UndeclaredDep.value() == :undeclared)
        end
        """
      )

    track!(fixture.root, refused)
    assert_refused(run(fixture, refused, ["passed=undeclared sibling"]))

    # A compiled .app can name an undeclared sibling through extra_applications
    # even though the sibling never appeared in the literal Mix dependency
    # graph. The source-derived context remains the authority.
    write_app!(
      fixture.build,
      :fixture_app,
      [:kernel, :stdlib, :elixir, :declared_dep, :undeclared_dep]
    )

    assert_refused(run(fixture, allowed, ["passed=declared closure"]))

    compile_startup_probe!(fixture)

    provider =
      write_selector(
        fixture,
        "fixture_app",
        "provider_test.exs",
        """
        defmodule FixtureProviderTest do
          use ExUnit.Case
          @tag :real_provider
          test "provider arrives after startup" do
            assert System.get_env("LOOPEX_PROVIDER_API_KEY") == "fixture-secret"
            assert File.read!(System.fetch_env!("STARTUP_PROBE")) == "clean"

            assert :ok =
                     Loopex.M1Gate.RealPathEvidence.report(#{inspect(@combined_identity)})
          end
        end
        """
      )

    track!(fixture.root, provider)

    assert_success(
      run(
        fixture,
        provider,
        ["passed=provider arrives after startup"],
        real_path: "combined",
        provider_key: "fixture-secret",
        env: [
          {"STARTUP_PROBE", fixture.startup_probe},
          {"LOOPEX_PROVIDER_API_KEY", "ambient-secret-must-be-removed"}
        ]
      ),
      {"combined", @combined_identity}
    )

    invalid_reports = [
      {"missing", "model", [Map.delete(@model_identity, "endpoint")]},
      {"extra-runner-fields", "model",
       [Map.merge(@model_identity, %{"nonce" => @nonce, "recorded" => "2026-01-01T00:00:00Z"})]},
      {"adapter-build", "model",
       [Map.put(@model_identity, "adapter_build", "loopex_llm_reqllm@0.0.1")]},
      {"executor-build", "combined",
       [Map.put(@combined_identity, "executor_build", "loopex_executor_local@0.0.1")]},
      {"non-ascii", "model", [Map.put(@model_identity, "provider", "prøvider")]},
      {"space", "model", [Map.put(@model_identity, "model", "fixture model")]},
      {"control", "model", [Map.put(@model_identity, "endpoint", "bad\nendpoint")]},
      {"nonbinary", "model", [Map.put(@model_identity, "provider", 42)]},
      {"placeholder", "model", [Map.put(@model_identity, "model", "TODO")]},
      {"wrong-profile", "combined", [@model_identity]},
      {"duplicate-representation", "model", [[{"provider", "one"}, {"provider", "two"}]]},
      {"multiple", "model", [@model_identity, @model_identity]},
      {"no-report", "model", []},
      {"credential", "model",
       [Map.put(@model_identity, "provider", "prefix-fixture-secret-suffix")]}
    ]

    for {label, profile, reports} <- invalid_reports do
      selector =
        write_selector(
          fixture,
          "fixture_app",
          "invalid_real_path_#{label}_test.exs",
          real_path_source("refuses #{label}", reports)
        )

      track!(fixture.root, selector)

      assert_refused(
        run(fixture, selector, ["passed=refuses #{label}"],
          real_path: profile,
          provider_key: "fixture-secret"
        )
      )
    end

    default_report =
      write_selector(
        fixture,
        "fixture_app",
        "default_report_test.exs",
        real_path_source("default may not report", [@model_identity], real_provider: false)
      )

    track!(fixture.root, default_report)
    assert_refused(run(fixture, default_report, ["passed=default may not report"]))

    assert_refused(
      run(fixture, provider, ["passed=provider arrives after startup"],
        role_args: ["--only-real-provider"],
        provider_key: "fixture-secret",
        env: [{"STARTUP_PROBE", fixture.startup_probe}]
      )
    )
  end

  defp fixture_repo(options \\ []) do
    root = Path.join(System.tmp_dir!(), "m1-exunit-#{System.unique_integer([:positive])}")
    build = Path.join(root, "build")
    File.mkdir_p!(Path.join(root, "apps/fixture_app/test"))
    File.mkdir_p!(Path.join(build, "lib/fixture_app/ebin"))
    git!(root, ["init", "-q"])
    git!(root, ["config", "user.name", "Loopex Test"])
    git!(root, ["config", "user.email", "loopex-test@example.invalid"])
    applications = Keyword.get(options, :applications, [:kernel, :stdlib, :elixir])
    included_applications = Keyword.get(options, :included_applications, [])
    write_app!(build, :fixture_app, applications, nil, nil, included_applications)
    startup_probe = Path.join(root, "startup-probe")
    on_exit(fn -> File.rm_rf(root) end)

    %{
      root: root,
      build: build,
      startup_probe: startup_probe,
      internal: Keyword.get(options, :internal, [:fixture_app]),
      allowed: Keyword.get(options, :allowed, [:fixture_app])
    }
  end

  defp write_selector(fixture, app, name, source) do
    relative = "apps/#{app}/test/#{name}"
    path = Path.join(fixture.root, relative)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, source)
    relative
  end

  defp passing_source(name) do
    """
    defmodule FixturePassingTest do
      use ExUnit.Case
      test #{inspect(name)}, do: assert(true)
    end
    """
  end

  defp real_path_source(name, reports, options \\ []) do
    tag = if Keyword.get(options, :real_provider, true), do: "@tag :real_provider", else: ""

    calls =
      Enum.map_join(reports, "\n", fn report ->
        "assert :ok = Loopex.M1Gate.RealPathEvidence.report(#{inspect(report)})"
      end)

    """
    defmodule FixtureRealPathTest do
      use ExUnit.Case
      #{tag}
      test #{inspect(name)} do
        #{calls}
        assert true
      end
    end
    """
  end

  defp events(selector, tests) do
    entries =
      tests
      |> Enum.with_index()
      |> Map.new(fn {%{name: name, state: state}, index} ->
        {index, %{file: selector, module: "FixtureTest", name: name, state: state}}
      end)

    %{
      selector: selector,
      seed: 17,
      suite_started: 1,
      suite_finished: 1,
      owned_formatter: true,
      max_failures: false,
      selector_mismatches: 0,
      duplicate_tests: 0,
      unknown_events: 0,
      tests: entries
    }
  end

  defp write_app!(
         build,
         app,
         applications,
         module \\ nil,
         declared_app \\ nil,
         included_applications \\ []
       ) do
    ebin = Path.join([build, "lib", Atom.to_string(app), "ebin"])
    File.mkdir_p!(ebin)
    properties = [applications: applications]

    properties =
      if included_applications == [],
        do: properties,
        else: Keyword.put(properties, :included_applications, included_applications)

    properties = if module, do: Keyword.put(properties, :mod, {module, []}), else: properties
    spec = {:application, declared_app || app, properties}
    File.write!(Path.join(ebin, "#{app}.app"), :io_lib.format("~p.~n", [spec]))
  end

  defp compile_module!(fixture, app, module, body) do
    ebin = Path.join([fixture.build, "lib", Atom.to_string(app), "ebin"])
    File.mkdir_p!(ebin)
    source = "defmodule #{module} do\n#{body}\nend\n"
    [{compiled, beam}] = Code.compile_string(source)
    File.write!(Path.join(ebin, "#{compiled}.beam"), beam)
    write_app!(fixture.build, app, [:kernel, :stdlib, :elixir])
  end

  defp compile_startup_probe!(fixture) do
    source = """
    defmodule FixtureStartup do
      use Application
      def start(_type, _args) do
        value = if System.get_env("LOOPEX_PROVIDER_API_KEY"), do: "leaked", else: "clean"
        File.write!(System.fetch_env!("STARTUP_PROBE"), value)
        Supervisor.start_link([], strategy: :one_for_one)
      end
    end
    """

    [{FixtureStartup, beam}] = Code.compile_string(source)
    ebin = Path.join([fixture.build, "lib/fixture_app/ebin"])
    File.write!(Path.join(ebin, "Elixir.FixtureStartup.beam"), beam)

    write_app!(
      fixture.build,
      :fixture_app,
      [:kernel, :stdlib, :elixir, :declared_dep],
      FixtureStartup
    )
  end

  defp run(fixture, selector, expectations, options \\ []) do
    real_path = Keyword.get(options, :real_path)

    role =
      Keyword.get_lazy(options, :role_args, fn ->
        if real_path,
          do: ["--only-real-provider", "--real-path", real_path],
          else: []
      end)

    key = Keyword.get(options, :provider_key, "")
    input = Keyword.get(options, :input, selector_frame(key))
    input_path = Path.join(fixture.root, "runner-input-#{System.unique_integer([:positive])}")
    File.write!(input_path, input)
    script = Path.expand("../../../scripts/m1-exunit-runner.exs", __DIR__)

    args =
      role ++
        [
          fixture.root,
          fixture.build,
          selector,
          Keyword.get(options, :owner, "fixture_app"),
          fixture.internal |> Enum.sort() |> Enum.join(","),
          fixture.allowed |> Enum.sort() |> Enum.join(","),
          "17",
          "1",
          Keyword.get(options, :policy, "zero")
        ] ++ expectations

    command = "exec \"$2\" \"$3\" --loopex-m1-selector \"\${@:4}\" <\"$1\""

    System.cmd(
      "/bin/bash",
      [
        "-c",
        command,
        "m1-runner",
        input_path,
        System.find_executable("elixir"),
        script | args
      ],
      env:
        [
          {"ERL_CRASH_DUMP", "/dev/null"},
          {"ERL_CRASH_DUMP_SECONDS", "0"}
        ] ++ Keyword.get(options, :env, []),
      stderr_to_stdout: true
    )
  end

  defp selector_frame(key), do: @input_header <> <<0>> <> @nonce <> <<0>> <> key <> <<0>>

  defp assert_success(result, expected_identity \\ nil)

  defp assert_success({output, status}, expected_identity) do
    assert status == 0, output
    assert marker_count(output) == 1, output
    parse_marker(output, expected_identity)
  end

  defp assert_refused({output, status}) do
    refute status == 0 and marker_count(output) == 1, output
  end

  defp marker_count(output) do
    output
    |> String.split("\n")
    |> Enum.count(&String.starts_with?(&1, "LOOPEX_EXUNIT_REPORT nonce=#{@nonce} "))
  end

  defp parse_marker(output, expected_identity) do
    [line] =
      output
      |> String.split("\n")
      |> Enum.filter(&String.starts_with?(&1, "LOOPEX_EXUNIT_REPORT nonce=#{@nonce} "))

    ["LOOPEX_EXUNIT_REPORT" | encoded_fields] = String.split(line, " ")

    pairs =
      Enum.map(encoded_fields, fn encoded ->
        assert [key, value] = String.split(encoded, "=", parts: 2)
        {key, value}
      end)

    expected_keys =
      ~w(nonce selector seed executed digest) ++
        identity_keys(expected_identity) ++
        if(expected_identity, do: ["recorded"], else: [])

    assert Enum.map(pairs, &elem(&1, 0)) == expected_keys
    assert pairs |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> length() == length(pairs)

    fields = Map.new(pairs)
    assert fields["nonce"] == @nonce
    assert fields["seed"] == "17"
    assert fields["executed"] =~ ~r/\A[1-9][0-9]*\z/u
    assert fields["digest"] =~ ~r/\Asha256:[0-9a-f]{64}\z/u

    if expected_identity do
      {profile, identity} = expected_identity
      assert profile in ["model", "combined"]

      for key <- identity_keys(expected_identity) do
        assert fields[key] == identity[key]
      end

      assert fields["recorded"] =~
               ~r/\A[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\z/u

      assert {:ok, parsed, 0} = DateTime.from_iso8601(fields["recorded"])
      assert DateTime.to_iso8601(parsed) == fields["recorded"]
    end

    fields
  end

  defp identity_keys(nil), do: []

  defp identity_keys({"model", _identity}),
    do: ~w(provider model endpoint adapter_build)

  defp identity_keys({"combined", _identity}),
    do: ~w(provider model endpoint adapter_build executor_build executor_identity tool_identity)

  defp track!(root, relative) do
    git!(root, ["add", "--", relative])
  end

  defp git!(root, args) do
    case System.cmd("git", args, cd: root, stderr_to_stdout: true) do
      {output, 0} -> output
      {output, status} -> flunk("git #{Enum.join(args, " ")} exited #{status}: #{output}")
    end
  end
end
