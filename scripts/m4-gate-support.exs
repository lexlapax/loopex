# Concept: M4 routing reuses the bound M3 support machinery for everything that
# is not milestone-specific: identity, reports, build digests, the register-
# derived aggregate plan and ledger accounting.
# Technical depth: only the outcome manifest, the path-to-outcome map and the
# M4 labels live here. This module never executes a gate or reads provider input.
Code.require_file("m3-gate-support.exs", __DIR__)

defmodule Loopex.M4Gate.Support do
  alias Loopex.M3Gate.Support, as: Shared

  @all [1, 2, 3, 4, 5, 6]
  @selector ~r/\Aapps\/[a-z][a-z0-9_]*\/test\/[A-Za-z0-9_.\/-]+_test\.exs\z/
  @real_path "apps/loopex_app_server/test/external_workflow_real_test.exs"

  def select_outcomes(paths) do
    paths |> Enum.flat_map(&outcome/1) |> Enum.uniq() |> Enum.sort()
  end

  defp outcome("apps/loopex_app_server/test/initialization_test.exs"), do: [1]
  defp outcome("apps/loopex_app_server/test/session_mapping_test.exs"), do: [2]
  defp outcome("apps/loopex_app_server/test/foundation_mapping_test.exs"), do: [3]
  defp outcome("apps/loopex_app_server/test/delivery_bounds_test.exs"), do: [4]
  defp outcome("apps/loopex_app_server/test/external_workflow_test.exs"), do: [5]
  defp outcome("apps/loopex_app_server/test/external_workflow_real_test.exs"), do: [5]
  defp outcome("apps/loopex/test/interaction_lifecycle_test.exs"), do: [3]
  defp outcome("apps/loopex_store_local/test/artifact_transfer_test.exs"), do: [4]
  defp outcome("apps/loopex_protocol/test/public_schema_conformance_test.exs"), do: [6]
  defp outcome("apps/loopex/test/m4_gate_support_test.exs"), do: [6]
  # Concept: shared contract, store and server paths select every outcome that
  # can observe them; only leaf test files select one outcome.
  defp outcome("apps/loopex/lib/loopex/runtime/interaction" <> _), do: [2, 3, 5]
  defp outcome("apps/loopex/lib/loopex/policy.ex"), do: [3, 5]
  defp outcome("apps/loopex/lib/loopex/artifact_store.ex"), do: [4, 5]
  defp outcome("apps/loopex_store_local/lib/loopex/store/local/artifacts.ex"), do: [4, 5]
  defp outcome("apps/loopex_store_local/lib/" <> _), do: @all
  defp outcome("apps/loopex_protocol/" <> _), do: @all
  defp outcome("apps/loopex_app_server/lib/" <> _), do: @all
  defp outcome("clients/" <> _), do: [5, 6]
  defp outcome("scripts/fixtures/m4/" <> _), do: @all
  defp outcome(_), do: @all

  def manifest(root) do
    {data, _} = Code.eval_file(Path.join(root, "scripts/m4-outcomes.exs"))

    ensure(
      is_map(data) and Enum.sort(Map.keys(data)) == [:outcomes, :real],
      "invalid M4 outcome manifest"
    )

    ensure(
      is_list(data.outcomes) and Enum.map(data.outcomes, & &1.id) == @all,
      "outcome manifest must cover 1 through 6 once in order"
    )

    for row <- data.outcomes do
      ensure(
        Enum.sort(Map.keys(row)) == [:id, :selectors] and is_list(row.selectors) and
          row.selectors != [],
        "outcome selectors missing"
      )
    end

    selectors = Enum.flat_map(data.outcomes, & &1.selectors) ++ [data.real]

    for selector <- selectors do
      ensure(
        is_map(selector) and Enum.sort(Map.keys(selector)) == [:names, :path],
        "invalid selector declaration"
      )

      ensure(
        is_binary(selector.path) and Regex.match?(@selector, selector.path) and
          not Enum.any?(String.split(selector.path, "/"), &(&1 in [".", "..", ""])),
        "noncanonical selector path"
      )

      ensure(
        is_list(selector.names) and selector.names != [] and
          Enum.uniq(selector.names) == selector.names and
          Enum.all?(
            selector.names,
            &(is_binary(&1) and byte_size(&1) > 0 and
                not String.contains?(&1, ["\n", "\r", <<0>>]))
          ),
        "selector requires unique exact case names"
      )
    end

    ensure(
      length(Enum.uniq_by(selectors, & &1.path)) == length(selectors),
      "selector repeated across outcomes"
    )

    ensure(data.real.path == @real_path, "real selector must be the dedicated workflow file")
    data
  end

  def selected(root, ids) do
    manifest(root).outcomes |> Enum.filter(&(&1.id in ids)) |> Enum.flat_map(& &1.selectors)
  end

  # Concept: a reached selector must be a tracked ordinary file with its declared
  # exact case names; nothing else may stand in for it.
  # Technical depth: the argument vector feeds the bound M1 runner unchanged.
  def selector_arguments(root, build, path) do
    declarations = Enum.flat_map(manifest(root).outcomes, & &1.selectors) ++ [manifest(root).real]

    selector =
      Enum.find(declarations, &(&1.path == path)) || raise ArgumentError, "undeclared selector"

    entry = git(root, ["ls-files", "--stage", "--", path])

    ensure(
      Regex.match?(~r/\A100644 [0-9a-f]{40,64} 0\t#{Regex.escape(path)}\n\z/, entry) and
        File.regular?(Path.join(root, path)),
      "required selector must be tracked and present: #{path}"
    )

    Code.require_file(Path.join(root, "apps/loopex/lib/mix/tasks/loopex.deps_budget.ex"))

    projects =
      git(root, ["ls-files", "-z", "--", "mix.exs", "apps/*/mix.exs"])
      |> String.trim_trailing(<<0>>)
      |> String.split(<<0>>, trim: true)

    {:ok, context} = apply(Loopex.Checks.DepsBudget, :execution_context, [root, path, projects])

    [
      root,
      build,
      path,
      to_string(context.owner),
      Enum.map_join(context.internal, ",", &to_string/1),
      Enum.map_join(context.allowed, ",", &to_string/1),
      "3107",
      to_string(length(selector.names)),
      "zero"
    ] ++ Enum.map(selector.names, &("passed=" <> &1))
  end

  # Concept: one authoritative report per selector, parsed and judged once
  # against the complete M4 schema for its kind.
  # Technical depth: the M3-bound verifier fixes `@0.0.0` build identities and
  # rejects real-path fields on a non-real schema, so M4 owns the whole check:
  # exact key set for the kind, no duplicates, nonce/selector/seed identity,
  # minimum executed count, digest form, and build identities that name the
  # source tree's `VERSION` so a truthful 0.1.0 closure passes and a stale or
  # foreign version fails.
  @base_fields ~w(nonce selector seed executed digest)
  @real_fields ~w(provider model endpoint adapter_build executor_build executor_identity tool_identity recorded)

  def verify_report(root, log, nonce, path, minimum, real?) do
    reports =
      String.split(log, "\n") |> Enum.filter(&String.starts_with?(&1, "LOOPEX_EXUNIT_REPORT "))

    ensure(length(reports) == 1, "selector did not emit one authoritative report")
    [report] = reports
    fields = String.split(report, " ") |> tl() |> Enum.map(&String.split(&1, "=", parts: 2))
    ensure(Enum.all?(fields, &(length(&1) == 2)), "malformed authoritative report")
    map = Map.new(fields, fn [key, value] -> {key, value} end)
    expected = @base_fields ++ if(real?, do: @real_fields, else: [])

    ensure(
      map_size(map) == length(fields) and Enum.sort(Map.keys(map)) == Enum.sort(expected),
      "duplicate, missing or unexpected authoritative report fields"
    )

    ensure(
      map["nonce"] == nonce and map["selector"] == path and map["seed"] == "3107",
      "authoritative report identity mismatch"
    )

    ensure(
      Regex.match?(~r/\A\d+\z/, map["executed"]) and String.to_integer(map["executed"]) >= minimum and
        Regex.match?(~r/\Asha256:[0-9a-f]{64}\z/, map["digest"]),
      "authoritative count or digest missing"
    )

    if real?, do: verify_real_identities(root, map)
    :ok
  end

  defp verify_real_identities(root, map) do
    version = File.read!(Path.join(root, "VERSION")) |> String.trim()
    ensure(Regex.match?(~r/\A\d+\.\d+\.\d+\z/, version), "source VERSION is malformed")

    ensure(
      Enum.all?(
        @real_fields,
        &(is_binary(map[&1]) and map[&1] != "" and
            String.downcase(map[&1]) not in ~w(tbd todo pending unknown -) and
            Enum.all?(:binary.bin_to_list(map[&1]), fn byte -> byte in 0x21..0x7E end))
      ) and map["adapter_build"] == "loopex_llm_reqllm@#{version}" and
        map["executor_build"] == "loopex_executor_local@#{version}" and
        match?({:ok, _, 0}, DateTime.from_iso8601(map["recorded"])),
      "combined real-path report incomplete or names another source version"
    )
  end

  # Concept: the retained final report has one exact grammar.
  # Technical depth: fields are validated by name, order, count and form before
  # the runner prints the line, so a missing or duplicated identity cannot be
  # retained as evidence.
  @report_grammar [
    {"source", ~r/\A[0-9a-f]{40}\z/},
    {"gate", ~r/\Asha256:[0-9a-f]{64}\z/},
    {"version", ~r/\A\d+\.\d+\.\d+\z/},
    {"role", ~r/\Afull\z/},
    {"seed", ~r/\A3107\z/},
    {"outcome_ids", ~r/\A1,2,3,4,5,6\z/},
    {"selectors", ~r/\A[1-9]\d*\z/},
    {"elapsed_seconds", ~r/\A\d+\z/},
    {"elixir", ~r/\A\d+\.\d+\.\d+(-[0-9A-Za-z.]+)?\z/},
    {"otp", ~r/\A\d+(\.\d+)+\z/},
    {"erts", ~r/\A\d+(\.\d+)+\z/},
    {"platform", ~r/\A[A-Za-z0-9_.-]+\z/},
    {"node", ~r/\A\d+\.\d+\.\d+\z/},
    {"python", ~r/\A\d+\.\d+\.\d+\z/},
    {"clients", ~r/\Asha256:[0-9a-f]{64}\z/},
    {"schema", ~r/\Asha256:[0-9a-f]{64}\z/},
    {"inherited", ~r/\Atrue\z/},
    {"real_workflow", ~r/\Atrue\z/},
    {"result", ~r/\APASS\z/}
  ]

  # Concept: evidence names the exact runtime, not its major release.
  # Technical depth: `otp_release` is the major number only; the installed
  # release's `OTP_VERSION` file carries the exact version the pins name.
  def exact_otp_version do
    [:code.root_dir(), "releases", :erlang.system_info(:otp_release), "OTP_VERSION"]
    |> Path.join()
    |> File.read!()
    |> String.trim()
  end

  def verify_final_report(line) do
    [prefix | fields] = String.split(String.trim_trailing(line, "\n"), " ")
    ensure(prefix == "LOOPEX_M4_GATE_REPORT", "final report prefix is not the M4 gate report")
    pairs = Enum.map(fields, &String.split(&1, "=", parts: 2))
    ensure(Enum.all?(pairs, &(length(&1) == 2)), "malformed final report field")

    ensure(
      Enum.map(pairs, &hd/1) == Enum.map(@report_grammar, &elem(&1, 0)),
      "final report fields are missing, duplicated or reordered"
    )

    for {[key, value], {key, pattern}} <- Enum.zip(pairs, @report_grammar) do
      ensure(Regex.match?(pattern, value), "final report field is malformed: #{key}")
    end

    :ok
  end

  defp ensure(true, _), do: :ok
  defp ensure(false, reason), do: raise(ArgumentError, reason)

  defp git(root, args) do
    case System.cmd("git", ["-C", root | args], stderr_to_stdout: false) do
      {output, 0} -> output
      _ -> raise ArgumentError, "Git evidence unavailable: #{hd(args)}"
    end
  end

  def main(args) do
    case args do
      ["prepare-build", task, mix_home, state, workspace] ->
        Shared.prepare_build(task, mix_home, state, workspace)

      ["inspect", root] ->
        manifest(root)
        Shared.no_bootstrap_backedge!(File.read!(Path.join(root, "scripts/check-bootstrap.sh")))

      ["selection", root, sha] ->
        Shared.changed_paths(root, sha) |> select_outcomes() |> Enum.join(",") |> IO.puts()

      ["identity", root, mode] when mode in ["committed", "working"] ->
        {sha, digest} = Shared.source_identity(root, String.to_existing_atom(mode))

        IO.puts(
          "LOOPEX_M4_SOURCE sha=#{sha} working_digest=sha256:#{digest} seed=3107 elixir=#{System.version()} otp=#{exact_otp_version()} erts=#{:erlang.system_info(:version)} platform=#{:erlang.system_info(:system_architecture)}"
        )

      ["selectors", root, ids] ->
        selected(root, parse_ids(ids)) |> Enum.each(&IO.puts(&1.path))

      ["real", root] ->
        IO.puts(manifest(root).real.path)

      ["args", root, build, path] ->
        selector_arguments(root, build, path) |> Enum.each(&IO.binwrite([&1, <<0>>]))

      ["report", root, log, nonce, path, minimum, real] ->
        verify_report(
          root,
          File.read!(log),
          nonce,
          path,
          String.to_integer(minimum),
          real == "real"
        )

      ["build", build] ->
        IO.puts("LOOPEX_M4_BUILD digest=sha256:#{Shared.build_digest(build)}")

      ["evidence", line] ->
        verify_final_report(line)

      ["selector-account", expected_path, observed_path] ->
        expected = File.read!(expected_path) |> String.split("\n", trim: true)
        observed = File.read!(observed_path) |> String.split("\n", trim: true)
        {expected_count, observed_count} = Shared.verify_selector_account(expected, observed)

        IO.puts(
          "LOOPEX_M4_SELECTOR_ACCOUNT expected=#{expected_count} observed=#{observed_count} result=PASS"
        )

      _ ->
        raise ArgumentError, "invalid M4 support command"
    end
  rescue
    error ->
      IO.puts(:stderr, "M4 gate UNAVAILABLE: #{Exception.message(error)}")
      System.halt(2)
  end

  defp parse_ids(""), do: []

  defp parse_ids(ids) do
    values = String.split(ids, ",") |> Enum.map(&String.to_integer/1)
    ensure(Enum.all?(values, &(&1 in @all)), "invalid outcome selection")
    values
  end
end

case System.argv() do
  ["--m4-gate-support" | args] -> Loopex.M4Gate.Support.main(args)
  _ -> :ok
end
