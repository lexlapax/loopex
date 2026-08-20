defmodule Mix.Tasks.Loopex.SelfHosting do
  @shortdoc "Measures the self-hosted validation replacement and names what it dropped"

  @moduledoc """
  ## Concept

  Reports what the self-hosting migration cost and what it gave up. The accepted
  plan requires the replacement to state its own measured size and to name every
  behavior it dropped with the reason, so an independent reviewer can weigh one
  against the other and decide whether the result is proportionate.

  The size figure is audit and review material. **No run passes or fails on it.**
  A line ceiling would reward compressed code, hidden complexity, and deleted
  coverage, which is the opposite of what the budget is for.

  This command does not claim the retirement happened. A task cannot be the
  evidence for its own retirement, so absence and inventory are proved by the gate
  runner, which shadows the retired entrypoints and inspects the tree directly.
  What this command owns is the measurement and the dropped-behavior list, kept
  together in one place so the two cannot drift apart.

  ## Technical depth

  Every measured path is read and counted. A path that cannot be read fails the
  command: a measurement that silently skipped a file would understate the size,
  and an understated figure is worse than none because it reads as evidence.

  Lines are classified into documentation, comment, blank, and code so the figure
  can be interpreted. That composition matters for this particular comparison: the
  documentation contract requires every module and every documented function to
  carry both depths, which the retired bridge's language did not, and the
  replacement also contains readers for two formats that the retired bridge got
  from dependencies rather than from its own lines.
  """

  use Mix.Task

  # Concept: the retired bridge's size, exactly as the accepted gate records it.
  # Technical depth: transcribed rather than recomputed, because the files are gone
  # -- recomputing would report zero and the comparison would be meaningless.
  @retired [
    {"scripts/check_status.py", 2104},
    {"scripts/test_check_status.py", 2119},
    {"scripts/check-status.sh", 8},
    {"scripts/check-agent-bootstrap.py", 231}
  ]

  @replacement [
    "apps/loopex/lib/mix/tasks/status/adr.ex",
    "apps/loopex/lib/mix/tasks/status/bootstrap.ex",
    "apps/loopex/lib/mix/tasks/status/documents.ex",
    "apps/loopex/lib/mix/tasks/status/git.ex",
    "apps/loopex/lib/mix/tasks/status/history.ex",
    "apps/loopex/lib/mix/tasks/status/invalid.ex",
    "apps/loopex/lib/mix/tasks/status/json.ex",
    "apps/loopex/lib/mix/tasks/status/markdown.ex",
    "apps/loopex/lib/mix/tasks/status/names.ex",
    "apps/loopex/lib/mix/tasks/status/paths.ex",
    "apps/loopex/lib/mix/tasks/status/plan.ex",
    "apps/loopex/lib/mix/tasks/status/records.ex",
    "apps/loopex/lib/mix/tasks/status/register.ex",
    "apps/loopex/lib/mix/tasks/status/status.ex",
    "apps/loopex/lib/mix/tasks/status/toml.ex",
    "apps/loopex/lib/mix/tasks/loopex.status.ex",
    "apps/loopex/lib/mix/tasks/loopex.agent_bootstrap.ex",
    "apps/loopex/lib/mix/tasks/loopex.hook_registration.ex",
    "apps/loopex/lib/mix/tasks/loopex.docs_check.ex",
    "apps/loopex/lib/mix/tasks/loopex.self_hosting.ex",
    "apps/loopex/test/support/status_fixtures_helper.exs",
    "apps/loopex/test/status_check_test.exs",
    "apps/loopex/test/history_anchoring_test.exs",
    "apps/loopex/test/hook_registration_test.exs",
    "scripts/check-status.sh",
    "scripts/json-field.sh"
  ]

  # Concept: every behavior the replacement does not preserve, with the reason and
  # what protects the property instead.
  # Technical depth: ADR 0002 forbids dropping a tested behavior without an
  # explicit disposition. This list is the material that disposition is decided
  # from, so it is carried in the command that reports the measurement rather than
  # written once in prose that the measurement could drift away from.
  @dropped [
    {"Untracked-file enumeration in the adapter check",
     "the retired checker listed .claude/agents and .agents/skills from the filesystem, so an " <>
       "untracked stray file failed the exactly-these-files assertion; enumeration now reads the " <>
       "Git index, because a worktree created inside a scanned directory is a second copy of the " <>
       "repository and a filesystem walk reads it as project content. A tracked stray still " <>
       "fails; untracked state belongs to the ignore policy and the hygiene check."},
    {"Interpreter self-assertions",
     "the retired checker asserted that assertions were enabled and that the interpreter was " <>
       "recent enough for its own standard-library reader. Both described the retired runtime " <>
       "and have nothing to preserve."},
    {"Standalone configuration-syntax validation",
     "validity of the client configuration was a separate step run by the retired document " <>
       "processor. It is now implied: mix loopex.hook_registration and mix loopex.agent_bootstrap " <>
       "parse the whole document with the repository's own reader and reject malformed text, " <>
       "duplicate keys, and unescaped control characters, which is strictly more than validity."},
    {"General path queries in the client hooks",
     "the guards resolved their field with a general query language. They now use a " <>
       "repository-owned reader that enumerates JSON string tokens and counts container depth: " <>
       "path aware for the depth-two shape every hook uses, but not a general expression " <>
       "language. A hook runs before every tool call, so a language runtime per call is not " <>
       "viable. Escapes, including \\uXXXX and surrogate pairs, ARE resolved, in keys as well " <>
       "as values, and a duplicate key takes the last occurrence -- all matching a real parser. " <>
       "Leaving them escaped was a detection loss a review demonstrated: an ordinary JSON " <>
       "spelling of a protected path walked past the guard. What remains dropped is the general " <>
       "query language, not escape handling. Behaviour differs from a real parser only for input " <>
       "no valid document produces: malformed escapes pass through, and NUL and lone surrogates " <>
       "become U+FFFD rather than being emitted as bytes no consumer can decode."},
    {"The input-not-mutated assertion",
     "one retired test asserted the checker did not mutate the document set it was given. The " <>
       "property is unrepresentable here, because the data is immutable. Its positive half -- the " <>
       "fixture repository passes every check -- is preserved."},
    {"Introspection-based capsule assertion",
     "one retired test asserted, by naming convention, that no derivation function existed for a " <>
       "register state without lifecycle enforcement. The derivation is now one function with a " <>
       "failing catch-all clause, so the test asserts the same property directly at the call " <>
       "site instead of through reflection."},
    {"The read-only-reviewer property of the bootstrap aggregate",
     "the aggregate now calls Mix, which needs a writable build directory, so it no longer runs " <>
       "under an effectively read-only reviewer without one. That follows from the accepted " <>
       "migration itself. The read-only inspection lane is the gate runner's prefix before it " <>
       "allocates storage, and a reviewer may direct the build into an explicit isolated task " <>
       "root rather than an ambient temporary directory; DEVELOPMENT.md records both."},
    {"A gitignore probe naming a retired path",
     "one visibility probe named a retired file. It is replaced by two probes that keep the same " <>
       "pattern classes covered: the new shell entrypoint, and a source file under a fixture " <>
       "directory whose name the ignore rules mention."}
  ]

  @impl Mix.Task
  def run(_args) do
    case measure(root()) do
      {:ok, report} ->
        Mix.shell().info(render(report))

      {:error, reasons} ->
        Mix.raise("self-hosting measurement failed:\n  " <> Enum.join(reasons, "\n  "))
    end
  end

  defp root do
    case System.cmd("git", ["rev-parse", "--show-toplevel"], stderr_to_stdout: false) do
      {output, 0} -> String.trim(output)
      _other -> File.cwd!()
    end
  end

  @doc """
  ## Concept

  Measures every replacement file under `root` and returns the composition of each
  along with the totals.

  ## Technical depth

  Returns `{:error, reasons}` when a measured path cannot be read, so an incomplete
  measurement is reported as unavailable rather than printed as a smaller number.
  """
  @spec measure(Path.t()) :: {:ok, map()} | {:error, [String.t()]}
  def measure(root) do
    results = Enum.map(@replacement, &compose(root, &1))
    missing = for {:error, reason} <- results, do: reason

    case missing do
      [] ->
        files = for {:ok, entry} <- results, do: entry

        {:ok,
         %{
           files: files,
           total: sum(files),
           retired: Enum.sum(Enum.map(@retired, &elem(&1, 1))),
           retired_files: @retired,
           dropped: @dropped
         }}

      reasons ->
        {:error, reasons}
    end
  end

  defp compose(root, relative) do
    case File.read(Path.join(root, relative)) do
      {:error, posix} ->
        {:error, "#{relative}: cannot be measured (#{:file.format_error(posix)})"}

      {:ok, text} ->
        lines = text |> String.split("\n") |> drop_trailing_empty()

        counts =
          Enum.reduce(lines, {0, 0, 0, 0, false}, &classify/2)
          |> then(fn {doc, comment, blank, code, _open} ->
            %{doc: doc, comment: comment, blank: blank, code: code}
          end)

        {:ok, Map.merge(counts, %{path: relative, total: length(lines)})}
    end
  end

  defp drop_trailing_empty(lines) do
    case List.last(lines) do
      "" -> Enum.drop(lines, -1)
      _other -> lines
    end
  end

  # Concept: which bucket one line falls into.
  # Technical depth: a documentation heredoc is tracked across lines, because its
  # body is documentation regardless of what the individual line looks like. The
  # closing delimiter counts as documentation too, so the block's own bytes are not
  # attributed to code.
  defp classify(line, {doc, comment, blank, code, true}) do
    case String.trim(line) == ~s(""") do
      true -> {doc + 1, comment, blank, code, false}
      false -> {doc + 1, comment, blank, code, true}
    end
  end

  defp classify(line, {doc, comment, blank, code, false}) do
    trimmed = String.trim(line)

    cond do
      Regex.match?(~r/\A@(?:module)?doc(?:[ \t]+~S)?[ \t]+"""\z/u, trimmed) ->
        {doc + 1, comment, blank, code, true}

      String.starts_with?(trimmed, ["@doc ", "@moduledoc ", "@shortdoc "]) ->
        {doc + 1, comment, blank, code, false}

      String.starts_with?(trimmed, "#") ->
        {doc, comment + 1, blank, code, false}

      trimmed == "" ->
        {doc, comment, blank + 1, code, false}

      true ->
        {doc, comment, blank, code + 1, false}
    end
  end

  defp sum(files) do
    Enum.reduce(files, %{doc: 0, comment: 0, blank: 0, code: 0, total: 0}, fn entry, acc ->
      Map.new(acc, fn {key, value} -> {key, value + Map.fetch!(entry, key)} end)
    end)
  end

  defp render(report) do
    header =
      pad("path", 54) <>
        pad_left("doc", 7) <>
        pad_left("cmt", 6) <> pad_left("blank", 7) <> pad_left("code", 7) <> pad_left("total", 7)

    rows =
      Enum.map(report.files, fn entry ->
        pad(entry.path, 54) <>
          pad_left(entry.doc, 7) <>
          pad_left(entry.comment, 6) <>
          pad_left(entry.blank, 7) <> pad_left(entry.code, 7) <> pad_left(entry.total, 7)
      end)

    total = report.total

    totals =
      pad("TOTAL", 54) <>
        pad_left(total.doc, 7) <>
        pad_left(total.comment, 6) <>
        pad_left(total.blank, 7) <> pad_left(total.code, 7) <> pad_left(total.total, 7)

    retired =
      Enum.map(report.retired_files, fn {path, lines} -> "  #{pad_left(lines, 6)}  #{path}" end)

    dropped =
      Enum.with_index(report.dropped, 1)
      |> Enum.map(fn {{title, reason}, index} -> "  #{index}. #{title}\n     #{reason}" end)

    Enum.join(
      [
        "measured size of the self-hosted replacement",
        "",
        header,
        Enum.join(rows, "\n"),
        totals,
        "",
        "retired bridge, as the accepted gate records it:",
        Enum.join(retired, "\n"),
        "  #{pad_left(report.retired, 6)}  total",
        "",
        "The figure is audit and review material, not a pass condition.",
        "",
        "dropped behaviors, each with its reason:",
        Enum.join(dropped, "\n")
      ],
      "\n"
    )
  end

  defp pad(value, width), do: String.pad_trailing(to_string(value), width)
  defp pad_left(value, width), do: String.pad_leading(to_string(value), width)
end
