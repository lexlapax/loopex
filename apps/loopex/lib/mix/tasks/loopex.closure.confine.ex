defmodule Mix.Tasks.Loopex.Closure.Confine do
  @shortdoc "Proves the five-path administrative closure commit is confined"

  @moduledoc """
  ## Concept

  Checks that a milestone's administrative closure is the direct child of its
  tested commit and changes only the five authorized files and regions. It
  retains the complete zero-context patch only when every check passes.

  ## Technical depth

  Both revisions are read from Git objects, never from the worktree. The task
  checks path inventory and tree metadata before reconstructing each allowed
  document change byte for byte. It opens the requested patch exclusively only
  after validation, and removes only its own partial output on write failure.
  The separate documentation check validates the meanings of supplied status
  blocks; this task proves the administrative change's confinement.
  """

  use Mix.Task

  @max_patch_bytes 32 * 1024 * 1024
  @git_env [
    {"GIT_NO_LAZY_FETCH", "1"},
    {"GIT_NO_REPLACE_OBJECTS", "1"},
    {"GIT_OPTIONAL_LOCKS", "0"},
    {"LC_ALL", "C"}
  ]

  @impl Mix.Task
  def run(args) do
    case parse(args) do
      {:ok, tested, administrative, name, patch} ->
        case check(File.cwd!(), tested, administrative, name, patch) do
          {:ok, lines} ->
            Enum.each(lines, fn line -> Mix.shell().info(line) end)

          {:error, lines} ->
            Enum.each(lines, fn line -> Mix.shell().info(line) end)
            Mix.raise("closure confinement failed")
        end

      :error ->
        Mix.raise("usage: mix loopex.closure.confine TESTED ADMIN --name NAME --patch PATCH")
    end
  end

  @doc """
  ## Concept

  Checks two committed revisions and retains the administrative patch at a new
  path on success. A failing check leaves no patch behind.

  ## Technical depth

  `root` is a Git repository. Results list one `PASS` or `FAIL` line for each
  check reached, in order. The patch has a 32 MiB ceiling and an exclusive
  destination; a failed write removes only the file this invocation created.
  """
  @spec check(Path.t(), String.t(), String.t(), String.t(), Path.t()) ::
          {:ok, [String.t()]} | {:error, [String.t()]}
  def check(root, tested, administrative, name, patch) do
    check_with_writer(root, tested, administrative, name, patch, &IO.binwrite/2)
  end

  @doc false
  def check_with_writer(root, tested, administrative, name, patch, writer) do
    context = %{
      root: root,
      tested: tested,
      administrative: administrative,
      name: name,
      patch: patch,
      writer: writer
    }

    checks = [
      preflight: &preflight/1,
      parent: &parent/1,
      paths: &paths/1,
      metadata: &metadata/1,
      register: &register/1,
      closure: &closure/1,
      context: &context_append/1,
      evidence: &evidence/1,
      readme: &readme/1,
      patch: &patch/1
    ]

    Enum.reduce_while(checks, {:ok, context, []}, fn {label, verify}, {:ok, state, lines} ->
      case verify.(state) do
        {:ok, next} -> {:cont, {:ok, next, ["PASS #{label}" | lines]}}
        {:error, reason} -> {:halt, {:error, Enum.reverse(["FAIL #{label}: #{reason}" | lines])}}
      end
    end)
    |> case do
      {:ok, _state, lines} -> {:ok, Enum.reverse(lines)}
      error -> error
    end
  end

  defp parse(args) do
    case OptionParser.parse(args, strict: [name: :string, patch: :string]) do
      {[name: name, patch: patch], [tested, administrative], []} ->
        {:ok, tested, administrative, name, patch}

      {[patch: patch, name: name], [tested, administrative], []} ->
        {:ok, tested, administrative, name, patch}

      _ ->
        :error
    end
  end

  defp preflight(c) do
    with true <- Regex.match?(~r/\A(?:M[0-9]+|[a-z0-9]+(?:-[a-z0-9]+)*)\z/, c.name),
         true <- full_sha?(c.tested) and full_sha?(c.administrative),
         {:ok, tested} <- commit(c, c.tested),
         {:ok, administrative} <- commit(c, c.administrative),
         true <- tested != administrative,
         true <- File.dir?(Path.dirname(c.patch)),
         {:error, :enoent} <- File.lstat(c.patch) do
      {:ok, %{c | tested: tested, administrative: administrative}}
    else
      _ -> {:error, "invalid name or revision, or patch parent/output is not new"}
    end
  end

  defp full_sha?(sha), do: Regex.match?(~r/\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z/, sha)

  defp commit(c, sha) do
    case git(c.root, ["rev-parse", "--verify", "--end-of-options", "#{sha}^{commit}"]) do
      {:ok, output} ->
        resolved = String.trim(output)
        if full_sha?(resolved) and resolved == sha, do: {:ok, resolved}, else: :error

      _ ->
        :error
    end
  end

  defp parent(c) do
    case git(c.root, ["rev-list", "--parents", "-n", "1", c.administrative]) do
      {:ok, output} ->
        if String.split(String.trim(output)) == [c.administrative, c.tested],
          do: {:ok, c},
          else: {:error, "administrative revision is not a direct single-parent child"}

      _ ->
        {:error, "parent information unavailable"}
    end
  end

  defp five(c) do
    [
      "docs/plans/README.md",
      "docs/plans/#{c.name}.md",
      "docs/developer/agent-context-map.md",
      "docs/evidence/#{c.name}-closure-runs.md",
      "README.md"
    ]
  end

  defp paths(c) do
    case git(c.root, ["diff", "--name-only", "-z", "--no-renames", c.tested, c.administrative]) do
      {:ok, output} ->
        if nul_paths(output) == Enum.sort(five(c)),
          do: {:ok, c},
          else: {:error, "changed-path inventory differs from the exact five paths"}

      _ ->
        {:error, "changed-path inventory unavailable"}
    end
  end

  defp nul_paths(output) do
    if String.ends_with?(output, <<0>>) do
      output |> String.trim_trailing(<<0>>) |> String.split(<<0>>, trim: true) |> Enum.sort()
    else
      []
    end
  end

  defp metadata(c) do
    with {:ok, tested} <- tree_entries(c, c.tested),
         {:ok, administrative} <- tree_entries(c, c.administrative),
         true <- Enum.all?(five(c), &ordinary_unchanged?(&1, tested, administrative)),
         {:ok, raw} <-
           git(c.root, [
             "diff",
             "--raw",
             "--no-abbrev",
             "-z",
             "--no-renames",
             c.tested,
             c.administrative,
             "--" | five(c)
           ]),
         true <- raw_changes?(raw, five(c)) do
      {:ok, c}
    else
      _ -> {:error, "a path is not an unchanged-mode ordinary blob or raw metadata differs"}
    end
  end

  defp tree_entries(c, sha) do
    case git(c.root, ["ls-tree", "-z", sha, "--" | five(c)]) do
      {:ok, output} ->
        entries =
          output
          |> String.split(<<0>>, trim: true)
          |> Enum.map(fn entry ->
            case Regex.run(~r/\A([0-7]{6}) (blob|tree|commit) ([0-9a-f]{40,64})\t(.+)\z/s, entry) do
              [_, mode, type, _oid, path] -> {path, {mode, type}}
              _ -> {entry, :invalid}
            end
          end)

        {:ok, Map.new(entries)}

      _ ->
        :error
    end
  end

  defp ordinary_unchanged?(path, tested, administrative) do
    case {Map.get(tested, path), Map.get(administrative, path)} do
      {{mode, "blob"}, {mode, "blob"}} when mode in ["100644", "100755"] -> true
      _ -> false
    end
  end

  defp raw_changes?(raw, expected) do
    parts = String.split(raw, <<0>>, trim: true)

    if rem(length(parts), 2) == 0 do
      parts
      |> Enum.chunk_every(2)
      |> Enum.map(fn [header, path] ->
        if Regex.match?(
             ~r/\A:100(?:644|755) 100(?:644|755) [0-9a-f]{40,64} [0-9a-f]{40,64} M\z/,
             header
           ),
           do: path,
           else: :invalid
      end)
      |> Enum.sort()
      |> Kernel.==(Enum.sort(expected))
    else
      false
    end
  end

  defp register(c) do
    path = "docs/plans/README.md"

    with {:ok, before, after_bytes} <- contents(c, path),
         true <- row_within_marker?(before, "| `#{c.name}` |", "milestone-register"),
         true <- row_within_marker?(after_bytes, "| `#{c.name}` |", "milestone-register"),
         {:ok, reconstructed} <-
           replace_row(before, after_bytes, "| `#{c.name}` |", fn row ->
             if String.contains?(row, "| In review |") do
               {:ok, String.replace(row, "| In review |", "| Closed |", global: false)}
             else
               :error
             end
           end),
         {:ok, reconstructed} <- replace_marked(reconstructed, after_bytes, "current-status"),
         true <- reconstructed == after_bytes do
      {:ok, c}
    else
      _ -> {:error, "register row or marked current-status bytes exceed their regions"}
    end
  end

  defp closure(c) do
    path = "docs/plans/#{c.name}.md"

    with {:ok, before, after_bytes} <- contents(c, path),
         {:ok, technical} <-
           git(c.root, ["show", "#{c.tested}:docs/plans/#{c.name}-technical.md"]),
         {:ok, reconstructed} <-
           replace_row(before, after_bytes, "| Closure |", fn row ->
             if row == "| Closure | — | — | — |" do
               new_row = unique_row(after_bytes, "| Closure |")

               if is_binary(new_row) and valid_closure_row?(new_row, c.tested, before, technical),
                 do: {:ok, new_row},
                 else: :error
             else
               :error
             end
           end),
         true <- reconstructed == after_bytes do
      {:ok, c}
    else
      _ -> {:error, "only the populated Closure governance row may change"}
    end
  end

  defp valid_closure_row?(row, tested, concept, technical) do
    cells = String.split(row, "|")
    concept_digest = Base.encode16(:crypto.hash(:sha256, concept), case: :lower)
    technical_digest = Base.encode16(:crypto.hash(:sha256, technical), case: :lower)

    length(cells) == 6 and
      Enum.all?(Enum.slice(cells, 1, 4), &(String.trim(&1) != "")) and
      String.contains?(row, "`#{tested}`") and
      String.contains?(row, "concept `sha256:#{concept_digest}`") and
      String.contains?(row, "technical `sha256:#{technical_digest}`")
  end

  defp context_append(c) do
    path = "docs/developer/agent-context-map.md"
    escaped_name = Regex.escape(String.downcase(c.name))
    heading_name = Regex.escape(c.name)

    pattern =
      ~r/\A\n<a id="disposition-#{escaped_name}-closure-(\d{4}-\d{2}-\d{2})"><\/a>\n### #{heading_name} closure[^\n]*\1\n/s

    with {:ok, before, after_bytes} <- contents(c, path),
         true <- String.starts_with?(after_bytes, before),
         appended when byte_size(appended) > 0 <-
           binary_part(after_bytes, byte_size(before), byte_size(after_bytes) - byte_size(before)),
         [_, date] <- Regex.run(pattern, appended),
         {:ok, _date} <- Date.from_iso8601(date),
         true <- length(Regex.scan(~r/^(?:#|##|###) /m, appended)) == 1,
         true <- length(Regex.scan(~r/^<a id=/m, appended)) == 1,
         true <- String.ends_with?(appended, "\n") do
      {:ok, c}
    else
      _ ->
        {:error,
         "pre-existing context bytes changed or append is not one dated closure subsection"}
    end
  end

  defp evidence(c) do
    path = "docs/evidence/#{c.name}-closure-runs.md"

    with {:ok, before, after_bytes} <- contents(c, path),
         true <- evidence_cells?(before, after_bytes) do
      {:ok, c}
    else
      _ -> {:error, "a scaffold byte outside Pending table cells changed"}
    end
  end

  defp evidence_cells?(before, after_bytes) do
    old_lines = String.split(before, "\n", trim: false)
    new_lines = String.split(after_bytes, "\n", trim: false)

    String.contains?(before, "Pending") and
      length(old_lines) == length(new_lines) and
      Enum.zip(old_lines, new_lines)
      |> Enum.all?(fn {old, new} ->
        cond do
          not String.contains?(old, "Pending") ->
            old == new

          not String.starts_with?(old, "|") ->
            false

          true ->
            pattern =
              "\\A" <>
                (old |> Regex.escape() |> String.replace("Pending", "([^|\\r\\n]+)")) <> "\\z"

            case Regex.run(Regex.compile!(pattern), new, capture: :all_but_first) do
              nil -> false
              replacements -> Enum.all?(replacements, &(String.trim(&1) not in ["", "Pending"]))
            end
        end
      end)
  end

  defp readme(c) do
    with {:ok, before, after_bytes} <- contents(c, "README.md"),
         {:ok, reconstructed} <- replace_marked(before, after_bytes, "readme-status"),
         true <- reconstructed == after_bytes do
      {:ok, c}
    else
      _ -> {:error, "bytes outside marked README status changed"}
    end
  end

  defp replace_marked(before, after_bytes, marker) do
    start_marker = "<!-- loopex:#{marker}:start -->"
    end_marker = "<!-- loopex:#{marker}:end -->"

    with {:ok, first_prefix, _first_middle, first_suffix} <-
           marked_parts(before, start_marker, end_marker),
         {:ok, second_prefix, second_middle, second_suffix} <-
           marked_parts(after_bytes, start_marker, end_marker),
         true <- first_prefix == second_prefix and first_suffix == second_suffix do
      {:ok, first_prefix <> second_middle <> first_suffix}
    else
      _ -> :error
    end
  end

  defp marked_parts(bytes, start_marker, end_marker) do
    with [{start_at, _}] <- :binary.matches(bytes, start_marker),
         [{end_at, _}] <- :binary.matches(bytes, end_marker),
         true <- start_at < end_at do
      middle_end = end_at + byte_size(end_marker)

      {:ok, binary_part(bytes, 0, start_at), binary_part(bytes, start_at, middle_end - start_at),
       binary_part(bytes, middle_end, byte_size(bytes) - middle_end)}
    else
      _ -> :error
    end
  end

  defp replace_row(before, after_bytes, prefix, replacement) do
    with row when is_binary(row) <- unique_row(before, prefix),
         new_row when is_binary(new_row) <- unique_row(after_bytes, prefix),
         {:ok, ^new_row} <- replacement.(row) do
      {:ok, String.replace(before, row, new_row, global: false)}
    else
      _ -> :error
    end
  end

  defp unique_row(bytes, prefix) do
    case bytes |> String.split("\n") |> Enum.filter(&String.starts_with?(&1, prefix)) do
      [row] -> row
      _ -> nil
    end
  end

  defp row_within_marker?(bytes, prefix, marker) do
    start_marker = "<!-- loopex:#{marker}:start -->"
    end_marker = "<!-- loopex:#{marker}:end -->"

    with [{start_at, _}] <- :binary.matches(bytes, start_marker),
         [{end_at, _}] <- :binary.matches(bytes, end_marker),
         true <- start_at < end_at,
         row when is_binary(row) <- unique_row(bytes, prefix),
         {row_at, _} <- :binary.match(bytes, row),
         true <- start_at < row_at and row_at < end_at do
      true
    else
      _ -> false
    end
  end

  defp contents(c, path) do
    with {:ok, before} <- git(c.root, ["show", "#{c.tested}:#{path}"]),
         {:ok, after_bytes} <- git(c.root, ["show", "#{c.administrative}:#{path}"]) do
      {:ok, before, after_bytes}
    else
      _ -> :error
    end
  end

  defp patch(c) do
    with {:ok, bytes} <-
           git(c.root, [
             "diff",
             "--no-ext-diff",
             "--no-renames",
             "--binary",
             "--unified=0",
             c.tested,
             c.administrative,
             "--" | five(c)
           ]),
         true <- byte_size(bytes) > 0 and byte_size(bytes) <= @max_patch_bytes,
         :ok <- exclusive_write(c.patch, bytes, c.writer) do
      {:ok, c}
    else
      _ -> {:error, "bounded patch unavailable or exclusive write failed"}
    end
  end

  defp exclusive_write(path, bytes, writer) do
    case File.open(path, [:write, :binary, :exclusive]) do
      {:ok, io} ->
        stat = File.stat(path)

        write =
          try do
            writer.(io, bytes)
          rescue
            _ -> :error
          catch
            _, _ -> :error
          end

        close = File.close(io)

        if match?({:ok, _}, stat) and write == :ok and close == :ok do
          :ok
        else
          case {stat, File.stat(path)} do
            {{:ok, created}, {:ok, current}}
            when current.inode == created.inode and current.major_device == created.major_device ->
              File.rm(path)

            _ ->
              :ok
          end

          :error
        end

      _ ->
        :error
    end
  end

  defp git(root, args) do
    case System.cmd("git", ["--no-replace-objects" | args],
           cd: root,
           env: @git_env,
           stderr_to_stdout: false
         ) do
      {output, 0} -> {:ok, output}
      _ -> :error
    end
  end
end
