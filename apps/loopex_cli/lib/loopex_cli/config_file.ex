defmodule LoopexCli.ConfigFile do
  @moduledoc """
  ## Concept

  Load one explicitly selected configuration file and retain its authored
  profile before resolving relative paths. Loading discovers no project config,
  credential, policy default or application startup.

  ## Technical depth

  The composition's regular-file reader binds the opened identity and reads at
  most 256 KiB plus one byte. JSON and closed-schema validation precede path
  resolution. Relative file values use the selected file's absolute directory;
  the file selector itself uses the explicit invocation directory. `Path.absname`
  preserves tilde/environment text and symlink-sensitive parent components.
  The result retains authored and resolved profiles separately. Model-capability
  admission and prompt-file capture remain later effective-profile stages.
  """

  alias LoopexCli.{ConfigJson, ConfigSchema}
  alias LoopexComposition.ProjectResources.ResourceReader

  @doc """
  ## Concept

  Read and validate the selected file without starting its configured services.

  ## Technical depth

  The caller supplies its absolute invocation directory. Errors contain only a
  class and pointer. Every resolved path stays within 4,096 UTF-8 bytes; no
  credential value or ambient configuration alias is read. Only the selected
  JSON file is opened here, while trace schema checks may load trusted metadata.
  """
  @spec load(term(), term()) :: {:ok, map()} | {:error, {atom(), binary()}}
  def load(file, invocation_directory) do
    with :ok <- path(file, "/config"),
         :ok <- absolute_directory(invocation_directory),
         file <- Path.absname(file, invocation_directory),
         :ok <- path(file, "/config"),
         {:ok, bytes} <- read(file),
         {:ok, authored} <- ConfigJson.decode(bytes),
         {:ok, ^authored} <- ConfigSchema.validate(authored),
         {:ok, resolved} <- resolve(authored, Path.dirname(file)) do
      {:ok, %{file: file, authored: authored, resolved: resolved}}
    end
  end

  defp read(file) do
    case ResourceReader.read(file, 262_144) do
      {:ok, bytes} -> {:ok, bytes}
      _ -> {:error, {:configuration_file_unusable, "/config"}}
    end
  end

  defp resolve(profile, directory) do
    paths =
      [
        ["paths", "workspace"],
        ["paths", "state_root"],
        ["session", "instructions", "system_file"],
        ["session", "instructions", "append_file"]
      ] ++
        Enum.map(
          Map.keys(Map.get(profile, "roles", %{})) |> Enum.sort(),
          &["roles", &1, "instructions_file"]
        )

    with {:ok, resolved} <- resolve_paths(profile, paths, directory),
         {:ok, resolved} <- resolve_skills(resolved, directory) do
      {:ok, resolved}
    end
  end

  defp resolve_paths(profile, paths, directory) do
    Enum.reduce_while(paths, {:ok, profile}, fn keys, {:ok, resolved} ->
      case get_in(resolved, keys) do
        nil ->
          {:cont, {:ok, resolved}}

        value ->
          absolute = Path.absname(value, directory)
          pointer = Enum.map_join(keys, "", &("/" <> escape(&1)))

          case path(absolute, pointer) do
            :ok -> {:cont, {:ok, put_in(resolved, keys, absolute)}}
            {:error, _} = error -> {:halt, error}
          end
      end
    end)
  end

  defp resolve_skills(%{"session" => %{"skill_dirs" => skills}} = profile, directory) do
    result =
      skills
      |> Enum.with_index()
      |> Enum.reduce_while({:ok, []}, fn {value, index}, {:ok, resolved} ->
        absolute = Path.absname(value, directory)

        case path(absolute, "/session/skill_dirs/#{index}") do
          :ok -> {:cont, {:ok, [absolute | resolved]}}
          {:error, _} = error -> {:halt, error}
        end
      end)

    case result do
      {:ok, paths} -> {:ok, put_in(profile, ["session", "skill_dirs"], Enum.reverse(paths))}
      {:error, _} = error -> error
    end
  end

  defp resolve_skills(profile, _), do: {:ok, profile}

  defp absolute_directory(directory) do
    with :ok <- path(directory, "/invocation_directory") do
      if Path.type(directory) == :absolute,
        do: :ok,
        else: {:error, {:invalid_configuration_path, "/invocation_directory"}}
    end
  end

  defp path(value, pointer) when is_binary(value) and byte_size(value) in 1..4_096 do
    if String.valid?(value) and not String.contains?(value, <<0>>),
      do: :ok,
      else: {:error, {:invalid_configuration_path, pointer}}
  end

  defp path(_, pointer), do: {:error, {:invalid_configuration_path, pointer}}
  defp escape(key), do: key |> String.replace("~", "~0") |> String.replace("/", "~1")
end
