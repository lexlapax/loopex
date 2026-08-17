defmodule Mix.Tasks.Loopex.HookRegistration do
  @shortdoc "Proves each client hook is registered under its required event and matcher"

  @moduledoc """
  ## Concept

  A hook that still blocks what it always blocked is worthless if the client no
  longer invokes it. This command proves the opposite side of the guarantee: each
  named hook is registered in the client's configuration under the exact event and
  matcher that makes it run.

  Registration is checked as structure, not as text. Two hooks swapped between
  event blocks leave every individual name and event present in the file, so
  independent searches for each would pass while neither hook ran where it was
  needed.

  ## Technical depth

  The configuration is parsed — the repository's own JSON reader, since core
  carries no dependency — and each required mapping is resolved through it: the
  event block, the entry whose matcher is exactly the required one, and the single
  command that entry registers. A required script must have exactly one
  registration in the whole file, so moving it while leaving a copy behind fails
  too.

  Commands are compared by their trailing hook path rather than in full, because
  the leading component is the client's project-directory variable and belongs to
  the client's invocation contract, not to this check.
  """

  use Mix.Task

  alias Loopex.Checks.Json

  @settings ".claude/settings.json"
  @hook_directory ".claude/hooks"

  # Concept: the exact event, matcher, and script triples the client must carry.
  # Technical depth: expressed as data so the requirement is one table to read and
  # one table to change, and so the failure message can name what was expected.
  @required [
    {"PreToolUse", "Bash", "guard-bash.sh"},
    {"PreToolUse", "Read|Grep|Glob|Edit|Write|NotebookEdit", "guard-filesystem.sh"},
    {"PostToolUse", "Edit|Write", "after-edit.sh"}
  ]

  @impl Mix.Task
  def run(_args) do
    case check(root()) do
      :ok ->
        Mix.shell().info("every hook is registered under its required event and matcher")

      {:error, reasons} ->
        Mix.raise("hook registration violated:\n  " <> Enum.join(reasons, "\n  "))
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

  Checks the client configuration under `root` and reports every registration
  defect found.

  ## Technical depth

  Takes the repository root explicitly because an umbrella child runs with its own
  directory as the working directory. An unreadable or unparsable configuration is
  a violation rather than a skip: a configuration the check cannot read is one
  whose hooks it cannot vouch for.
  """
  @spec check(Path.t()) :: :ok | {:error, [String.t()]}
  def check(root) do
    path = Path.join(root, @settings)

    case File.read(path) do
      {:ok, text} -> report(check_settings(text))
      {:error, posix} -> {:error, ["#{@settings}: cannot be read (#{:file.format_error(posix)})"]}
    end
  end

  @doc """
  ## Concept

  Checks one client configuration document and returns the registration defects it
  carries.

  ## Technical depth

  Public so the protected tests exercise this exact code path against adversarial
  configurations — a hook under the wrong event, a hook with the wrong matcher,
  two hooks swapped — rather than reimplementing the traversal against a fixture
  they also wrote.
  """
  @spec check_settings(binary()) :: [String.t()]
  def check_settings(text) do
    case Json.decode(text) do
      {:error, reason} ->
        ["#{@settings}: is not valid JSON (#{reason})"]

      {:ok, settings} when is_map(settings) ->
        hooks = Map.get(settings, "hooks")

        case is_map(hooks) do
          false -> ["#{@settings}: declares no hooks object"]
          true -> Enum.flat_map(@required, &registration_reasons(hooks, &1))
        end

      {:ok, _other} ->
        ["#{@settings}: top level must be an object"]
    end
  end

  defp report([]), do: :ok
  defp report(reasons), do: {:error, reasons}

  defp registration_reasons(hooks, {event, matcher, script}) do
    expected = "#{@hook_directory}/#{script}"
    registrations = registrations(hooks, script)

    case matching_entry(hooks, event, matcher) do
      {:error, reason} ->
        ["#{script} must be registered under #{event} with matcher #{matcher}: #{reason}"]

      {:ok, commands} ->
        Enum.reject(
          [
            unless(commands == [expected] or single_suffix_match(commands, expected),
              do:
                "#{event} matcher #{matcher} registers #{inspect(commands)} " <>
                  "rather than exactly #{expected}"
            ),
            unless(registrations == [{event, matcher}],
              do:
                "#{script} is registered as #{inspect(registrations)} " <>
                  "rather than exactly once under #{event} with matcher #{matcher}"
            )
          ],
          &is_nil/1
        )
    end
  end

  # Concept: the entry whose matcher is exactly the required one, and the commands
  # it registers.
  # Technical depth: exactly one entry may carry a given matcher. Two entries with
  # the same matcher make the effective hook set depend on the client's merge
  # order, which is not something this repository can assert.
  defp matching_entry(hooks, event, matcher) do
    entries = Map.get(hooks, event)

    cond do
      not is_list(entries) ->
        {:error, "#{event} declares no hook entries"}

      true ->
        matches = Enum.filter(entries, &(is_map(&1) and Map.get(&1, "matcher") == matcher))

        case matches do
          [entry] -> commands(entry)
          [] -> {:error, "no #{event} entry has matcher #{matcher}"}
          _many -> {:error, "#{event} has more than one entry with matcher #{matcher}"}
        end
    end
  end

  defp commands(entry) do
    case Map.get(entry, "hooks") do
      list when is_list(list) ->
        {:ok,
         Enum.map(list, fn
           %{"command" => command} when is_binary(command) -> command
           other -> inspect(other)
         end)}

      _other ->
        {:error, "the matching entry registers no hooks list"}
    end
  end

  # Concept: a command names the hook file; the leading path component is the
  # client's project-directory variable and is not this check's business.
  defp single_suffix_match([command], expected), do: String.ends_with?(command, "/" <> expected)
  defp single_suffix_match(_commands, _expected), do: false

  # Concept: where a script is registered, across every event and matcher.
  # Technical depth: this is what catches a hook moved to a different event while a
  # copy stays behind, which a per-mapping check alone would report as satisfied.
  defp registrations(hooks, script) do
    for {event, entries} <- hooks,
        is_list(entries),
        entry <- entries,
        is_map(entry),
        registered = Map.get(entry, "hooks"),
        is_list(registered),
        %{"command" => command} <- registered,
        is_binary(command),
        String.ends_with?(command, "/" <> @hook_directory <> "/" <> script) or
          command == @hook_directory <> "/" <> script do
      {event, Map.get(entry, "matcher")}
    end
    |> Enum.sort()
  end
end
