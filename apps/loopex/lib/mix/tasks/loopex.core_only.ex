defmodule Mix.Tasks.Loopex.CoreOnly do
  @shortdoc "Runs core in an isolated lane with no adapter resolved or started"

  @moduledoc """
  ## Concept

  ADR 0001's isolation lane. Core must build and run with no adapter application
  resolved or started, and must not read per-runtime state from application
  environment. Both properties are about what core can reach: an adapter that is
  merely reachable is a dependency edge waiting to be used, and per-runtime state
  hidden in global application environment collides the moment a second runtime
  starts in the same VM.

  ## Technical depth

  The lane is a **separate VM running core's own project**, not the VM this task
  happens to occupy. An earlier version inspected the ambient VM, which made the
  outcome unsatisfiable and, worse, wrong: at an umbrella root every compiled
  child is on the load path, so any adapter failed the check by merely existing,
  and `mix test` at the root starts the children in dependency order before core's
  tests run. The gate's evidence table names that exact anti-pattern — "root suite
  standing for core" — and the ambient check was an instance of it. Outcome 7 and
  outcome 9 appeared mutually exclusive only because the measurement was taken in
  the wrong place.

  Running `mix` with the working directory set to core's own application resolves
  core's dependency closure alone. The adapter's artifacts sit in the shared
  `_build`, and the lane still does not see them, because the load path comes from
  the project's declared dependencies rather than from what is present on disk.

  The lane also asserts that core itself is started. A subprocess that loaded
  nothing would otherwise satisfy "no adapter is started" vacuously, which is the
  same class of error as measuring in the wrong VM.

  The application-environment property is a source property, not a runtime one: a
  read on a code path no test exercises is still a read. Core sources are parsed
  and any `Application.get_env`, `fetch_env`, or `fetch_env!` call is rejected.
  """

  use Mix.Task

  @runtime_app :loopex
  @contract_app :loopex_protocol
  @core_app_path "apps/loopex"
  @core_lib "apps/loopex/lib"
  @adapter_prefix "loopex_"
  @env_readers [:get_env, :fetch_env, :fetch_env!]
  @lane_marker "LOOPEX_CORE_ONLY_LANE"

  # Concept: printed by the lane subprocess and parsed by the caller. Kept as one
  # line with a marker so unrelated compiler or Mix output cannot be mistaken for
  # the report, and a missing marker is unavailable evidence rather than a pass.
  # Technical depth: a non-interpolating sigil, because every #{} here belongs to
  # the subprocess. An ordinary heredoc evaluated them in this module instead.
  @lane_script ~S"""
               loaded = Application.loaded_applications() |> Enum.map(&Atom.to_string(elem(&1, 0)))
               started = Application.started_applications() |> Enum.map(&Atom.to_string(elem(&1, 0)))

               IO.puts(
                 "MARKER loaded=" <>
                   Enum.join(loaded, ",") <> " started=" <> Enum.join(started, ",")
               )
               """
               |> String.replace("MARKER", @lane_marker)

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
    case lane_reasons(root) ++ application_env_reasons(Path.join(root, @core_lib)) do
      [] -> :ok
      reasons -> {:error, reasons}
    end
  end

  @doc """
  ## Concept

  Runs core in its own VM and reports which applications are loaded and started
  there.

  ## Technical depth

  Public so the protected test observes the same lane the task does rather than
  reimplementing it. Returns `{:ok, %{loaded: [String.t()], started: [String.t()]}}`
  or `{:error, reason}`; a subprocess that fails, or succeeds without emitting the
  marker line, is an error, because evidence that could not be collected is not
  evidence of absence.

  `MIX_ENV` is set explicitly so the lane is the same whether it is invoked from a
  task or from inside a test run.
  """
  @spec isolated_lane(Path.t()) ::
          {:ok, %{loaded: [String.t()], started: [String.t()]}} | {:error, String.t()}
  def isolated_lane(root \\ ".") do
    core = Path.join(root, @core_app_path)

    if File.dir?(core) do
      run_lane(core)
    else
      {:error, "#{core} does not exist; the core-only lane cannot run"}
    end
  end

  defp run_lane(core) do
    {output, status} =
      System.cmd("mix", ["run", "-e", @lane_script],
        cd: core,
        stderr_to_stdout: true,
        env: [{"MIX_ENV", "dev"}]
      )

    cond do
      status != 0 ->
        {:error, "the core-only lane exited #{status}: #{String.trim(output)}"}

      true ->
        parse_lane(output)
    end
  end

  defp parse_lane(output) do
    line =
      output
      |> String.split("\n")
      |> Enum.find(&String.starts_with?(&1, @lane_marker))

    case line do
      nil ->
        {:error, "the core-only lane emitted no report; evidence is unavailable"}

      line ->
        {:ok,
         %{
           loaded: field(line, "loaded="),
           started: field(line, "started=")
         }}
    end
  end

  defp field(line, key) do
    line
    |> String.split(" ")
    |> Enum.find_value([], fn token ->
      case String.starts_with?(token, key) do
        true -> token |> String.replace_prefix(key, "") |> String.split(",", trim: true)
        false -> nil
      end
    end)
  end

  defp lane_reasons(root) do
    case isolated_lane(root) do
      {:error, reason} ->
        [reason]

      {:ok, %{loaded: loaded, started: started}} ->
        adapters_in("resolved into", loaded) ++
          adapters_in("started in", started) ++ core_started(started)
    end
  end

  defp adapters_in(relation, applications) do
    applications
    |> Enum.filter(&adapter?/1)
    |> Enum.map(fn name -> "adapter application #{name} is #{relation} the core-only lane" end)
  end

  # Concept: a lane that started nothing would satisfy every absence vacuously.
  defp core_started(started) do
    case Atom.to_string(@runtime_app) in started do
      true -> []
      false -> ["the core-only lane did not start #{@runtime_app}; the lane proved nothing"]
    end
  end

  @doc """
  ## Concept

  Whether an application name is an adapter: named for the runtime with a suffix,
  excluding the runtime and the contract.

  ## Technical depth

  Derived from the name rather than a hardcoded list, so an adapter added by a
  later workstream is covered without changing this code. ADR 0001 fixes the
  naming this relies on.
  """
  @spec adapter?(String.t() | atom()) :: boolean()
  def adapter?(name) when is_atom(name), do: adapter?(Atom.to_string(name))

  def adapter?(name) when is_binary(name) do
    String.starts_with?(name, @adapter_prefix) and
      name not in [Atom.to_string(@runtime_app), Atom.to_string(@contract_app)]
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
