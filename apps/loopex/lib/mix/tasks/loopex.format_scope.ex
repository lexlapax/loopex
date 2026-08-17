defmodule Mix.Tasks.Loopex.FormatScope do
  @shortdoc "Proves the effective formatter configuration resolves to application sources"

  @moduledoc """
  ## Concept

  An umbrella root formats nothing of its own. A `.formatter.exs` that lists only
  root paths therefore lets `mix format --check-formatted` report success having
  checked no application file, so formatting cleanliness would be a claim about
  an empty set. This proves the effective configuration actually reaches
  application sources.

  ## Technical depth

  The check resolves `inputs` and expands each glob against the filesystem,
  then requires at least one matched file under `apps/`. Matching the text
  `apps/**` inside the file is not enough: the glob could sit in a comment, in an
  unrelated key, or point at a directory with no sources. Expansion is the only
  evidence that the scope resolves.

  `check/1` takes the directory holding the configuration so the protected test
  can point it at a root-only fixture in a temporary directory, and returns
  `:ok` or `{:error, reason}`. The task wraps it and raises `Mix.Error`.
  """

  use Mix.Task

  @impl Mix.Task
  def run(_args) do
    case check(File.cwd!()) do
      {:ok, count} ->
        Mix.shell().info("formatter scope resolves to #{count} application source(s)")

      {:error, reason} ->
        Mix.raise("formatter scope is not proved: #{reason}")
    end
  end

  @doc """
  ## Concept

  Confirms the formatter configuration in `root` resolves to at least one file
  under `apps/`.

  ## Technical depth

  Reads the configuration as a term rather than importing it, so a malformed or
  missing file is a reported error instead of a raised exception that a caller
  might mistake for an unrelated failure.
  """
  @spec check(Path.t()) :: {:ok, non_neg_integer()} | {:error, String.t()}
  def check(root) do
    config_path = Path.join(root, ".formatter.exs")

    with {:ok, config} <- read_config(config_path),
         {:ok, inputs} <- inputs(config, config_path) do
      case matched_app_sources(root, inputs) do
        [] ->
          {:error,
           "#{config_path} inputs resolve to no file under apps/; " <>
             "an umbrella root formats nothing of its own, so this scope checks nothing"}

        matched ->
          {:ok, length(matched)}
      end
    end
  end

  defp read_config(path) do
    case File.exists?(path) do
      false ->
        {:error, "#{path} does not exist"}

      true ->
        try do
          {config, _bindings} = Code.eval_file(path)
          {:ok, config}
        rescue
          error -> {:error, "#{path} could not be read: #{Exception.message(error)}"}
        end
    end
  end

  defp inputs(config, path) when is_list(config) do
    case Keyword.fetch(config, :inputs) do
      {:ok, inputs} when is_list(inputs) -> {:ok, inputs}
      {:ok, other} -> {:error, "#{path} inputs is not a list: #{inspect(other)}"}
      :error -> {:error, "#{path} declares no inputs, so it formats nothing"}
    end
  end

  defp inputs(_config, path), do: {:error, "#{path} did not evaluate to a keyword list"}

  # Concept: expand every glob and keep only real files under apps/.
  defp matched_app_sources(root, inputs) do
    apps_root = Path.expand(Path.join(root, "apps"))

    inputs
    |> Enum.flat_map(fn glob -> Path.wildcard(Path.join(root, glob)) end)
    |> Enum.map(&Path.expand/1)
    |> Enum.filter(fn path ->
      File.regular?(path) and String.starts_with?(path, apps_root <> "/")
    end)
    |> Enum.uniq()
  end
end
