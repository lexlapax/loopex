defmodule LoopexCli.ConfigSelection do
  @moduledoc """
  ## Concept

  Compose a new-session declaration from validated file values, explicit flags
  and the permitted state-root environment reference. Preserve the origin of
  every selected value so inspection can explain the selection.

  ## Technical depth

  ADR 0049's precedence is flag, LOOPEX_HOME for state root, file, then harmless
  literal defaults. Authored schema validation precedes merging. Flag paths use
  the supplied invocation directory; file paths are already config-relative.
  Array overrides replace file arrays, and no-helpers only disables delegation.
  The result is host-private data, including credential references; a renderer
  must redact those references. Model-window/reasoning conformance, prompt-file
  capture and whole-request admission remain later preparation stages. Context
  budgets are left unresolved when absent, and maintenance never inherits a model.
  Resume uses committed truth through a separate preparation path.
  """

  alias LoopexCli.ConfigSchema

  @fields %{
    "workspace" => ~w(paths workspace),
    "state-root" => ~w(paths state_root),
    "model" => ~w(session model),
    "reasoning" => ~w(session reasoning),
    "compaction-model" => ~w(maintenance model),
    "max-steps" => ~w(session bounds max_turns),
    "deadline-ms" => ~w(session bounds deadline_ms),
    "token-budget" => ~w(session bounds token_budget),
    "max-tokens" => ~w(session max_tokens),
    "context-token-budget" => ~w(session context_token_budget),
    "system-class-tokens" => ~w(session system_class_tokens),
    "cleanup-grace-ms" => ~w(session cleanup_grace_ms),
    "system-prompt-file" => ~w(session instructions system_file),
    "append-system-prompt-file" => ~w(session instructions append_file),
    "tools" => ~w(session tools),
    "skill-dir" => ~w(session skill_dirs),
    "policy" => ["policy"],
    "output" => ["output"],
    "no-helpers" => ~w(delegation enabled),
    "trace" => ~w(trace enabled),
    "trace-level" => ~w(trace level),
    "trace-module" => ~w(trace modules),
    "trace-max-entry-bytes" => ~w(trace max_entry_bytes),
    "trace-max-entries-per-second" => ~w(trace max_entries_per_second),
    "trace-max-queue-entries" => ~w(trace max_queue_entries)
  }
  @path_flags ~w(workspace state-root system-prompt-file append-system-prompt-file)

  @doc """
  ## Concept

  Select a new-session or inspection profile without opening its configured services.

  ## Technical depth

  Takes ConfigFile's retained authored/resolved profiles and ConfigOptions'
  normalized result. LOOPEX_HOME is supplied explicitly by the host, which reads
  no other setting alias. A present invalid environment path refuses unless an
  explicit state-root flag supersedes it. Origins are JSON-pointer keys with
  flag, env, file#pointer or default values. No committed origin is fabricated.
  An argv resume selection refuses here rather than replacing captured settings.
  """
  @spec compose(term(), term(), term(), term()) :: {:ok, map()} | {:error, {atom(), binary()}}
  def compose(
        %{authored: authored, resolved: resolved},
        %{resume: nil, overrides: flags},
        cwd,
        home
      )
      when is_map(flags) do
    with {:ok, ^authored} <- ConfigSchema.validate(authored),
         {:ok, ^resolved} <- ConfigSchema.validate(resolved),
         :ok <- absolute_path(cwd, "/invocation_directory"),
         {:ok, selection} <- environment(selection(resolved), flags, cwd, home),
         {:ok, selection} <- flags(selection, flags, cwd),
         selection <- defaults(selection),
         {:ok, _} <- ConfigSchema.validate(selection.profile) do
      {:ok, selection}
    end
  end

  def compose(_, %{resume: resume}, _, _) when not is_nil(resume),
    do: {:error, {:committed_profile_required, "/flags/resume"}}

  def compose(_, _, _, _), do: {:error, {:invalid_configuration_selection, ""}}

  defp selection(profile) do
    %{profile: profile, origins: origins(profile, "", fn pointer -> "file#" <> pointer end)}
  end

  defp environment(selection, flags, cwd, home) do
    if Map.has_key?(flags, "state-root") or is_nil(home) do
      {:ok, selection}
    else
      with {:ok, absolute} <- resolve_path(home, cwd, "/env/LOOPEX_HOME") do
        {:ok, put(selection, ~w(paths state_root), absolute, "env")}
      end
    end
  end

  defp flags(selection, flags, cwd) do
    flags
    |> Enum.sort()
    |> Enum.reduce_while({:ok, selection}, fn {name, value}, {:ok, selection} ->
      with {:ok, keys} <- field(name),
           {:ok, value} <- flag_value(name, value, cwd) do
        {:cont, {:ok, put(selection, keys, value, "flag")}}
      else
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp field(name) do
    case Map.fetch(@fields, name) do
      {:ok, keys} -> {:ok, keys}
      :error -> {:error, {:invalid_configuration_selection, "/flags"}}
    end
  end

  defp flag_value(name, value, cwd) when name in @path_flags,
    do: resolve_path(value, cwd, "/flags/" <> name)

  defp flag_value("skill-dir", values, cwd) when is_list(values) do
    values
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {value, index}, {:ok, result} ->
      case resolve_path(value, cwd, "/flags/skill-dir/#{index}") do
        {:ok, absolute} -> {:cont, {:ok, [absolute | result]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      {:error, _} = error -> error
    end
  end

  defp flag_value("no-helpers", true, _), do: {:ok, false}

  defp flag_value("no-helpers", _, _),
    do: {:error, {:invalid_configuration_selection, "/flags/no-helpers"}}

  defp flag_value(_, value, _), do: {:ok, value}

  defp defaults(selection) do
    ceilings = Loopex.Trace.Config.ceilings()

    defaults = [
      {~w(session reasoning), "default"},
      {~w(session max_tokens), 4_096},
      {~w(session system_class_tokens), 1_000},
      {~w(session tools), "coding"},
      {~w(session skill_dirs), []},
      {~w(session cleanup_grace_ms), Loopex.Executor.default_cleanup_grace_ms()},
      {["roles"], %{}},
      {~w(delegation enabled), false},
      {~w(delegation roles), []},
      {~w(delegation max_tokens), 4_096},
      {~w(delegation system_class_tokens), 1_000},
      {~w(trace enabled), false},
      {~w(trace level), "calls"},
      {~w(trace modules), ["Loopex.*", "LoopexProtocol.*"]},
      {~w(trace max_entry_bytes), ceilings.entry_bytes},
      {~w(trace max_entries_per_second), ceilings.entries_per_second},
      {~w(trace max_queue_entries), ceilings.queued},
      {["output"], "text"}
    ]

    selection =
      Enum.reduce(defaults, selection, fn {keys, value}, selection ->
        if is_nil(get_in(selection.profile, keys)),
          do: put(selection, keys, value, "default"),
          else: selection
      end)

    Enum.reduce(Map.keys(selection.profile["roles"]), selection, fn role, selection ->
      keys = ["roles", role, "reasoning"]

      if is_nil(get_in(selection.profile, keys)),
        do: put(selection, keys, "default", "default"),
        else: selection
    end)
  end

  defp put(selection, keys, value, origin) do
    pointer = Enum.map_join(keys, "", &("/" <> escape(&1)))

    retained =
      Map.reject(selection.origins, fn {key, _} ->
        key == pointer or String.starts_with?(key, pointer <> "/")
      end)

    %{
      profile: nested_put(selection.profile, keys, value),
      origins: Map.merge(retained, origins(value, pointer, fn _ -> origin end))
    }
  end

  defp nested_put(map, [key], value), do: Map.put(map, key, value)

  defp nested_put(map, [key | rest], value),
    do: Map.put(map, key, nested_put(Map.get(map, key, %{}), rest, value))

  defp origins(value, pointer, origin) when is_map(value) and map_size(value) > 0 do
    Enum.reduce(value, %{}, fn {key, member}, result ->
      Map.merge(result, origins(member, pointer <> "/" <> escape(key), origin))
    end)
  end

  defp origins(value, pointer, origin) when is_list(value) and value != [] do
    value
    |> Enum.with_index()
    |> Enum.reduce(%{pointer => origin.(pointer)}, fn {member, index}, result ->
      Map.merge(result, origins(member, pointer <> "/#{index}", origin))
    end)
  end

  defp origins(_, pointer, origin), do: %{pointer => origin.(pointer)}

  defp resolve_path(value, cwd, pointer) do
    with :ok <- path(value, pointer),
         absolute <- Path.absname(value, cwd),
         :ok <- absolute_path(absolute, pointer) do
      {:ok, absolute}
    end
  end

  defp absolute_path(value, pointer) do
    with :ok <- path(value, pointer) do
      if Path.type(value) == :absolute, do: :ok, else: path_error(pointer)
    end
  end

  defp path(value, pointer) when is_binary(value) and byte_size(value) in 1..4_096 do
    if String.valid?(value) and not String.contains?(value, <<0>>),
      do: :ok,
      else: path_error(pointer)
  end

  defp path(_, pointer), do: path_error(pointer)
  defp path_error(pointer), do: {:error, {:invalid_configuration_path, pointer}}
  defp escape(key), do: key |> String.replace("~", "~0") |> String.replace("/", "~1")
end
