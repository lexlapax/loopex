defmodule Mix.Tasks.Loopex.VersionTrain do
  @shortdoc "Proves every application carries the umbrella's single version"

  @moduledoc """
  ## Concept

  Every application in the umbrella carries one version. Two applications that
  version independently by accident would make a compatibility claim nobody
  decided to make, and ADR 0003 keeps the contract and runtime as separately
  versioned *published* surfaces only through an explicit decision — not through
  drift.

  ## Technical depth

  Drift is prevented by construction rather than detected: each `mix.exs` reads
  the root `VERSION` file at compile time, so there is one source and no second
  place to edit. This check exists for the case construction cannot cover — a
  future application that hardcodes its version instead of reading the file.

  Versions are read from each application's resolved project configuration via
  `Mix.Project.in_project/4`, not by matching text, so an application that
  computes its version some other way is still compared on the value it actually
  reports.
  """

  use Mix.Task

  @version_file "VERSION"

  @impl Mix.Task
  def run(_args) do
    case check(File.cwd!()) do
      {:ok, version} ->
        Mix.shell().info("every application carries version #{version}")

      {:error, reason} ->
        Mix.raise("version train is broken: #{reason}")
    end
  end

  @doc """
  ## Concept

  Confirms every application under `apps/` reports the version recorded in the
  root `VERSION` file.

  ## Technical depth

  Returns the shared version on success. An umbrella with no applications is an
  error rather than a vacuous pass, because a check that reports success over an
  empty set is indistinguishable from one that ran.
  """
  @spec check(Path.t()) :: {:ok, String.t()} | {:error, String.t()}
  def check(root) do
    with {:ok, expected} <- expected_version(root),
         {:ok, apps} <- app_paths(root) do
      case Enum.reject(Enum.map(apps, &app_version(root, &1)), &match?({_app, ^expected}, &1)) do
        [] -> {:ok, expected}
        wrong -> {:error, describe(expected, wrong)}
      end
    end
  end

  defp expected_version(root) do
    path = Path.join(root, @version_file)

    case File.read(path) do
      {:ok, contents} ->
        case String.trim(contents) do
          "" -> {:error, "#{path} is empty"}
          version -> {:ok, version}
        end

      {:error, posix} ->
        {:error, "#{path}: #{:file.format_error(posix)}"}
    end
  end

  defp app_paths(root) do
    case Path.wildcard(Path.join([root, "apps", "*", "mix.exs"])) do
      [] -> {:error, "no application found under apps/; the version train covers nothing"}
      found -> {:ok, Enum.map(found, &Path.dirname/1)}
    end
  end

  defp app_version(_root, app_path) do
    app = Path.basename(app_path)

    version =
      Mix.Project.in_project(String.to_atom(app), app_path, fn _module ->
        Mix.Project.config()[:version]
      end)

    {app, version}
  end

  defp describe(expected, wrong) do
    detail =
      wrong
      |> Enum.map(fn {app, version} -> "#{app} reports #{inspect(version)}" end)
      |> Enum.join(", ")

    "expected every application at #{expected}; #{detail}"
  end
end
