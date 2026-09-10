# Concept: M3 routing and evidence reuse ordinary tracked selectors and the
# existing standalone runner. Future selectors are required only when reached.
# Technical depth: this module never executes a gate or reads provider input.
defmodule Loopex.M3Gate.Support do
  @all [1, 2, 3, 4, 5]
  @selector ~r/\Aapps\/[a-z][a-z0-9_]*\/test\/[A-Za-z0-9_.\/-]+_test\.exs\z/
  @milestone ~r/\A(?:M[0-9]+|v?[0-9]+(?:\.[0-9]+)+|[a-z0-9]+(?:-[a-z0-9]+)*)\z/

  def select_outcomes(paths) do
    paths |> Enum.flat_map(&outcome/1) |> Enum.uniq() |> Enum.sort()
  end

  defp outcome("apps/loopex/test/m3_gate_support_test.exs"), do: [5]
  defp outcome("apps/loopex/test/history_anchoring_test.exs"), do: [5]
  defp outcome("apps/loopex/test/skill_context_test.exs"), do: [2]

  defp outcome("apps/loopex/test/" <> name)
       when name in [
              "context_admission_test.exs",
              "provider_attempt_protocol_test.exs",
              "event_dispatcher_availability_test.exs"
            ],
       do: [4]

  defp outcome("apps/loopex/lib/loopex/runtime/" <> name)
       when name in ["provider_attempt.ex", "event_dispatcher.ex"],
       do: [4]

  defp outcome("apps/loopex/lib/loopex/skill" <> _), do: [2, 3]
  defp outcome("apps/loopex_composition/test/skill_acquisition_test.exs"), do: [1, 3]

  defp outcome("apps/loopex_composition/lib/loopex_composition/skill_acquisition.ex"),
    do: [1, 3]

  defp outcome("apps/loopex_cli/test/foundation_workflow_test.exs"), do: [3]
  defp outcome(_), do: @all

  def closed_prefix(text, caller) do
    [_, section] =
      required_match(
        ~r/<!-- loopex:milestone-register:start -->\n(.*?)<!-- loopex:milestone-register:end -->/s,
        text,
        "canonical register missing"
      )

    rows =
      for line <- String.split(section, "\n"), String.starts_with?(line, "| `") do
        [_, name, state] =
          required_match(
            ~r/^\| `([^`]+)` \| (Closed|Open|Accepted|In progress|In review|Blocked) \|/,
            line,
            "malformed register row"
          )

        folded = String.downcase(name)

        reserved =
          ~w(planning seed readme con prn aux nul) ++
            for prefix <- ["com", "lpt"], number <- 1..9, do: "#{prefix}#{number}"

        ensure(
          Regex.match?(@milestone, name) and byte_size(name) <= 64 and folded not in reserved and
            not String.ends_with?(folded, ["-gate", "-technical"]),
          "invalid or reserved milestone name"
        )

        {name, state}
      end

    ensure(
      rows != [] and
        length(Enum.uniq_by(rows, &(elem(&1, 0) |> String.downcase()))) == length(rows),
      "empty or duplicate register"
    )

    prefix =
      if caller == :all do
        Enum.take_while(rows, &(elem(&1, 1) == "Closed"))
      else
        ensure(Enum.any?(rows, &(elem(&1, 0) == caller)), "caller is absent from register")
        Enum.take_while(rows, &(elem(&1, 0) != caller))
      end

    ensure(Enum.all?(prefix, &(elem(&1, 1) == "Closed")), "predecessor is not Closed")

    if caller == :all,
      do:
        ensure(
          Enum.count(rows, &(elem(&1, 1) == "Closed")) == length(prefix),
          "Closed rows are not a prefix"
        )

    Enum.map(prefix, &elem(&1, 0))
  end

  def gate_command(name, text) do
    path = "scripts/check-#{String.downcase(name)}-gate.sh"
    forms = [["bash", path], ["/bin/bash", "-p", path]]

    candidates =
      Regex.scan(~r/```text\n(.*?)\n```/s, text)
      |> Enum.flat_map(fn [_, block] -> String.split(block, "\n") end)
      |> Enum.map(&String.split/1)
      |> Enum.filter(&(&1 in forms))
      |> Enum.uniq()

    ensure(length(candidates) == 1, "gate command absent or ambiguous for #{name}")
    [command] = candidates
    ensure(name != "M1" or command == ["/bin/bash", "-p", path], "M1 requires privileged Bash")
    command
  end

  def no_bootstrap_backedge!(source) do
    ensure(
      not String.contains?(source, "check-closed-gates.sh"),
      "bootstrap must not invoke the closed-gate aggregate"
    )

    :ok
  end

  def verify_invocations(expected, records) do
    ensure(
      records == Enum.map(expected, &{&1, 0}),
      "closed gate invocations are omitted, duplicated, reordered or unsuccessful"
    )

    :ok
  end

  def verify_selector_account(expected, observed) do
    ensure(
      expected == observed,
      "selector lanes are omitted, duplicated, reordered or unexpected"
    )

    {length(expected), length(observed)}
  end

  def manifest(root) do
    {data, _} = Code.eval_file(Path.join(root, "scripts/m3-outcomes.exs"))

    ensure(
      is_map(data) and Enum.sort(Map.keys(data)) == [:outcomes, :real],
      "invalid M3 outcome manifest"
    )

    ensure(
      is_list(data.outcomes) and Enum.map(data.outcomes, & &1.id) == @all,
      "outcome manifest must cover 1 through 5 once in order"
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

    ensure(
      data.real.path == "apps/loopex_cli/test/foundation_workflow_real_test.exs",
      "real selector must be the dedicated foundation workflow file"
    )

    data
  end

  def selected(root, ids) do
    manifest(root).outcomes |> Enum.filter(&(&1.id in ids)) |> Enum.flat_map(& &1.selectors)
  end

  def changed_paths(root, comparison) do
    ensure(
      Regex.match?(~r/\A[0-9a-f]{40}\z/, comparison),
      "comparison must be a complete commit SHA"
    )

    ensure(git(root, ["cat-file", "-e", comparison <> "^{commit}"]) == "", "invalid comparison")

    ensure(
      git(root, ["merge-base", "--is-ancestor", comparison, "HEAD"]) == "",
      "comparison is not retained by HEAD"
    )

    tracked = git(root, ["diff", "--name-only", "-z", comparison, "--"]) |> nul_paths!()
    untracked = git(root, ["ls-files", "--others", "--exclude-standard", "-z"]) |> nul_paths!()
    Enum.uniq(tracked ++ untracked) |> Enum.sort()
  end

  def source_identity(root, mode) when mode in [:committed, :working] do
    if mode == :committed do
      ensure(
        git(root, ["status", "--porcelain", "--untracked-files=all"]) == "",
        "committed-source role requires an exact clean tree"
      )
    end

    sha = git(root, ["rev-parse", "HEAD"]) |> String.trim()
    ensure(Regex.match?(~r/\A[0-9a-f]{40}\z/, sha), "source commit identity is malformed")

    paths =
      git(root, ["ls-files", "--cached", "--others", "--exclude-standard", "-z"])
      |> nul_paths!()
      |> Enum.uniq()
      |> Enum.sort()

    digest =
      Enum.map(paths, fn path ->
        case File.lstat(Path.join(root, path)) do
          {:ok, %{type: :regular}} -> {path, File.read!(Path.join(root, path))}
          {:ok, %{type: :symlink}} -> {path, :symlink, File.read_link!(Path.join(root, path))}
          {:error, :enoent} -> {path, :deleted}
          _ -> raise ArgumentError, "nonordinary source entry"
        end
      end)
      |> term_digest()

    {sha, digest}
  end

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
      |> nul_paths!()

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

  def verify_report(log, nonce, path, minimum, real?) do
    reports =
      String.split(log, "\n") |> Enum.filter(&String.starts_with?(&1, "LOOPEX_EXUNIT_REPORT "))

    ensure(length(reports) == 1, "selector did not emit one authoritative report")
    [report] = reports
    fields = String.split(report, " ") |> tl() |> Enum.map(&String.split(&1, "=", parts: 2))
    ensure(Enum.all?(fields, &(length(&1) == 2)), "malformed authoritative report")
    map = Map.new(fields, fn [key, value] -> {key, value} end)

    expected_fields =
      ~w(nonce selector seed executed digest) ++
        if(real?,
          do:
            ~w(provider model endpoint adapter_build executor_build executor_identity tool_identity recorded),
          else: []
        )

    ensure(
      map_size(map) == length(fields) and Enum.sort(Map.keys(map)) == Enum.sort(expected_fields),
      "duplicate or unexpected authoritative report fields"
    )

    ensure(
      map["nonce"] == nonce and map["selector"] == path and map["seed"] == "3107",
      "authoritative report identity mismatch"
    )

    ensure(
      String.to_integer(map["executed"]) >= minimum and
        Regex.match?(~r/\Asha256:[0-9a-f]{64}\z/, map["digest"]),
      "authoritative count or digest missing"
    )

    if real?,
      do:
        ensure(
          Enum.all?(
            ~w(provider model endpoint adapter_build executor_build executor_identity tool_identity recorded),
            &(is_binary(map[&1]) and map[&1] != "" and
                String.downcase(map[&1]) not in ~w(tbd todo pending unknown -) and
                Enum.all?(:binary.bin_to_list(map[&1]), fn byte -> byte in 0x21..0x7E end))
          ) and map["adapter_build"] == "loopex_llm_reqllm@0.0.0" and
            map["executor_build"] == "loopex_executor_local@0.0.0" and
            match?({:ok, _, 0}, DateTime.from_iso8601(map["recorded"])),
          "combined real-path report incomplete"
        )

    :ok
  end

  def build_digest(build) do
    files = Path.wildcard(Path.join(build, "lib/*/ebin/*")) |> Enum.sort()
    ensure(files != [], "compiled build inventory empty")

    Enum.map(files, fn file ->
      ensure(File.lstat!(file).type == :regular, "nonordinary compiled build entry")
      {Path.relative_to(file, build), File.read!(file)}
    end)
    |> term_digest()
  end

  defp term_digest(term),
    do:
      term
      |> :erlang.term_to_binary([:deterministic])
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

  defp ensure(true, _), do: :ok
  defp ensure(false, reason), do: raise(ArgumentError, reason)

  defp required_match(regex, text, reason),
    do: Regex.run(regex, text) || raise(ArgumentError, reason)

  defp git(root, args) do
    case System.cmd("git", ["-C", root | args], stderr_to_stdout: false) do
      {output, 0} -> output
      _ -> raise ArgumentError, "Git evidence unavailable: #{hd(args)}"
    end
  end

  defp nul_paths!(""), do: []

  defp nul_paths!(output) do
    ensure(String.ends_with?(output, <<0>>), "Git path inventory is truncated")

    output
    |> String.trim_trailing(<<0>>)
    |> String.split(<<0>>, trim: true)
    |> Enum.map(fn path ->
      ensure(
        String.valid?(path) and Path.type(path) == :relative and
          not Enum.any?(String.split(path, "/"), &(&1 in ["", ".", ".."])),
        "Git path inventory contains a noncanonical path"
      )

      path
    end)
  end

  # Concept: build prerequisites use nonsecret tool snapshots and locked packages.
  # Technical depth: metadata-only protected identities cover the operator roots;
  # ordinary tool trees reject links, special nodes and protected hard-link aliases.
  def prepare_build(task, mix_home, state_root, workspace_root) do
    identities =
      [state_root, workspace_root]
      |> Enum.flat_map(&protected_files(&1, true))
      |> MapSet.new()

    records =
      identities |> Enum.map(fn {device, inode} -> "#{device}:#{inode}" end) |> Enum.sort()

    File.write!(Path.join(task, "protected-file-ids"), Enum.map(records, &[&1, "\n"]))
    destination = Path.join(task, "home/.mix")
    File.mkdir_p!(Path.join(destination, "archives"))
    archives = Path.wildcard(Path.join(mix_home, "archives/hex-*"))
    ensure(archives != [], "installed Hex archive unavailable")
    rebar = Path.join(mix_home, "elixir")
    ensure(File.dir?(rebar), "installed per-Elixir Rebar archive unavailable")

    for source <- archives ++ [rebar] do
      validate_tool_tree!(source, identities)

      target =
        if source == rebar,
          do: Path.join(destination, "elixir"),
          else: Path.join([destination, "archives", Path.basename(source)])

      File.cp_r!(source, target)
      validate_tool_tree!(target, identities)
    end
  end

  defp protected_files(path, follow_root) do
    result = if follow_root, do: File.stat(path), else: File.lstat(path)

    case result do
      {:ok, %{type: :regular, major_device: device, inode: inode}} ->
        [{device, inode}]

      {:ok, %{type: :directory}} ->
        File.ls!(path) |> Enum.flat_map(&protected_files(Path.join(path, &1), false))

      {:ok, _} ->
        []

      {:error, :enoent} when follow_root ->
        []

      {:error, reason} ->
        raise ArgumentError, "protected root inventory unavailable: #{inspect(reason)}"
    end
  end

  defp validate_tool_tree!(path, protected) do
    case File.lstat!(path) do
      %{type: :directory} ->
        File.ls!(path) |> Enum.each(&validate_tool_tree!(Path.join(path, &1), protected))

      %{type: :regular, major_device: device, inode: inode} ->
        ensure(
          not MapSet.member?(protected, {device, inode}),
          "tool archive aliases protected operator data"
        )

      _ ->
        raise ArgumentError, "tool archive contains a symlink or special node"
    end
  end

  def main(args) do
    case args do
      ["prepare-build", task, mix_home, state, workspace] ->
        prepare_build(task, mix_home, state, workspace)

      ["inspect", root] ->
        manifest(root)
        no_bootstrap_backedge!(File.read!(Path.join(root, "scripts/check-bootstrap.sh")))

      ["selection", root, sha] ->
        changed_paths(root, sha) |> select_outcomes() |> Enum.join(",") |> IO.puts()

      ["identity", root, mode] when mode in ["committed", "working"] ->
        {sha, digest} = source_identity(root, String.to_existing_atom(mode))

        IO.puts(
          "LOOPEX_M3_SOURCE sha=#{sha} working_digest=sha256:#{digest} seed=3107 elixir=#{System.version()} otp=#{:erlang.system_info(:otp_release)} erts=#{:erlang.system_info(:version)} platform=#{:erlang.system_info(:system_architecture)}"
        )

      ["selectors", root, ids] ->
        selected(root, parse_ids(ids)) |> Enum.each(&IO.puts(&1.path))

      ["real", root] ->
        IO.puts(manifest(root).real.path)

      ["args", root, build, path] ->
        selector_arguments(root, build, path) |> Enum.each(&IO.binwrite([&1, <<0>>]))

      ["report", log, nonce, path, minimum, real] ->
        verify_report(File.read!(log), nonce, path, String.to_integer(minimum), real == "real")

      ["build", build] ->
        IO.puts("LOOPEX_M3_BUILD digest=sha256:#{build_digest(build)}")

      ["closed", root, caller] ->
        no_bootstrap_backedge!(File.read!(Path.join(root, "scripts/check-bootstrap.sh")))

        closed_prefix(
          File.read!(Path.join(root, "docs/plans/README.md")),
          if(caller == "all", do: :all, else: caller)
        )
        |> Enum.each(fn name ->
          command = gate_command(name, File.read!(Path.join(root, "docs/plans/#{name}-gate.md")))

          ensure(
            File.regular?(Path.join(root, List.last(command))),
            "closed gate runner absent: #{name}"
          )

          IO.puts(Enum.join([name | command], "\t"))
        end)

      ["account", plan, ledger] ->
        expected =
          File.read!(plan)
          |> String.split("\n", trim: true)
          |> Enum.map(&(String.split(&1, "\t") |> hd()))

        records =
          File.read!(ledger)
          |> String.split("\n", trim: true)
          |> Enum.map(fn line ->
            [name, status] = String.split(line, "\t")
            {name, String.to_integer(status)}
          end)

        verify_invocations(expected, records)

      ["selector-account", expected_path, observed_path] ->
        expected = File.read!(expected_path) |> String.split("\n", trim: true)
        observed = File.read!(observed_path) |> String.split("\n", trim: true)
        {expected_count, observed_count} = verify_selector_account(expected, observed)

        IO.puts(
          "LOOPEX_M3_SELECTOR_ACCOUNT expected=#{expected_count} observed=#{observed_count} result=PASS"
        )

      _ ->
        raise ArgumentError, "invalid M3 support command"
    end
  rescue
    error ->
      IO.puts(:stderr, "M3 gate UNAVAILABLE: #{Exception.message(error)}")
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
  ["--m3-gate-support" | args] -> Loopex.M3Gate.Support.main(args)
  _ -> :ok
end
