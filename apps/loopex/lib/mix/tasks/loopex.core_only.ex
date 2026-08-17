defmodule Mix.Tasks.Loopex.CoreOnly do
  @shortdoc "Proves core runs against fakes only, with no adapter and no application-env state"

  @moduledoc """
  ## Concept

  ADR 0001's isolation lane. Core must build and run with no adapter application
  resolved or started, and must not read per-runtime state from application
  environment. Both properties are about what core can reach: an adapter that is
  merely present is a dependency edge waiting to be used, and per-runtime state
  hidden in global application environment collides the moment a second runtime
  starts in the same VM.

  ## Technical depth

  Adapter absence is checked two ways, because they fail differently. `Application.spec/1`
  returning `nil` proves the adapter was never resolved into the build;
  `Application.started_applications/0` proves none is running even if something
  resolved it. An adapter is any application whose name begins with the runtime
  name followed by an underscore, which is the naming ADR 0001 fixes, so a new
  adapter is covered without editing this list.

  The application-environment property is a source property, not a runtime one: a
  read that happens on a code path no test exercises is still a read. Core
  sources are therefore parsed and any `Application.get_env`, `fetch_env`, or
  `fetch_env!` call is rejected. `config/config.exs` is deliberately empty of
  runtime configuration, but an empty config file is not the invariant — not
  reading it is.
  """

  use Mix.Task

  @runtime_app :loopex
  @core_lib "apps/loopex/lib"
  @adapter_prefix "loopex_"
  @contract_app :loopex_protocol
  @env_readers [:get_env, :fetch_env, :fetch_env!]

  @impl Mix.Task
  def run(_args) do
    case check(File.cwd!()) do
      :ok ->
        Mix.shell().info(
          "core-only lane holds: no adapter resolved or started, no env-held state"
        )

      {:error, reasons} ->
        Mix.raise("core-only lane violated:\n  " <> Enum.join(reasons, "\n  "))
    end
  end

  @doc """
  ## Concept

  Checks both core-only properties and reports every violation found.

  ## Technical depth

  Returns `:ok` or `{:error, [reason]}`. The two properties are independent, so
  both are evaluated before reporting; stopping at the first would hide the other.
  """
  @spec check(Path.t()) :: :ok | {:error, [String.t()]}
  def check(root \\ ".") do
    case adapter_reasons() ++ application_env_reasons(Path.join(root, @core_lib)) do
      [] -> :ok
      reasons -> {:error, reasons}
    end
  end

  @doc """
  ## Concept

  The applications that count as adapters: anything named for the runtime with a
  suffix, excluding the contract application.

  ## Technical depth

  Derived from the loaded application list rather than a hardcoded set, so an
  adapter added by a later workstream is covered without changing this code.
  """
  @spec adapter_applications() :: [atom()]
  def adapter_applications do
    Application.loaded_applications()
    |> Enum.map(fn {name, _description, _version} -> name end)
    |> Enum.concat(Enum.map(Application.started_applications(), fn {name, _d, _v} -> name end))
    |> Enum.uniq()
    |> Enum.filter(&adapter?/1)
  end

  defp adapter?(name) do
    string = Atom.to_string(name)

    String.starts_with?(string, @adapter_prefix) and
      name not in [@runtime_app, @contract_app]
  end

  defp adapter_reasons do
    resolved =
      Enum.map(adapter_applications(), fn name ->
        "adapter application #{inspect(name)} is resolved into the core-only lane"
      end)

    started =
      Application.started_applications()
      |> Enum.map(fn {name, _description, _version} -> name end)
      |> Enum.filter(&adapter?/1)
      |> Enum.map(fn name -> "adapter application #{inspect(name)} is started" end)

    Enum.uniq(resolved ++ started)
  end

  # Concept: core must not read per-runtime state from application environment.
  defp application_env_reasons(lib_root) do
    lib_root
    |> sources()
    |> Enum.flat_map(&env_reads_in/1)
  end

  defp sources(root) do
    case File.dir?(root) do
      true -> Path.wildcard(Path.join(root, "**/*.{ex,exs}"))
      false -> []
    end
  end

  defp env_reads_in(file) do
    case File.read(file) do
      {:error, posix} ->
        ["#{file}: could not be read (#{:file.format_error(posix)}); evidence is unavailable"]

      {:ok, source} ->
        case Code.string_to_quoted(source) do
          {:error, _} ->
            ["#{file}: could not be parsed; evidence is unavailable"]

          {:ok, ast} ->
            {_ast, found} =
              Macro.prewalk(ast, [], fn
                {{:., _dmeta, [{:__aliases__, _ameta, [:Application]}, reader]}, meta, _args} =
                    node,
                acc
                when reader in @env_readers ->
                  {node, [{reader, line(meta)} | acc]}

                node, acc ->
                  {node, acc}
              end)

            Enum.map(found, fn {reader, line} ->
              "#{file}:#{line}: core reads per-runtime state via Application.#{reader}"
            end)
        end
    end
  end

  defp line(meta), do: Keyword.get(meta, :line, 0)
end
