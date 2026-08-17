defmodule Mix.Tasks.Loopex.DepsBudget do
  @shortdoc "Enforces the dependency budget and one-way direction between applications"

  @moduledoc """
  ## Concept

  Proves ADR 0001's dependency rule mechanically: the contract application
  carries no dependency, the runtime application depends on the contract and
  nothing else, and no edge runs backwards from contract to runtime. A host or
  adapter depends inward on Loopex; core never reaches outward.

  Run it with no arguments to check the repository. Pass a `mix.exs` path to
  check that file instead, which is how the protected test points it at an
  adversarial fixture.

  ## Technical depth

  Dependencies are read by parsing each `mix.exs` to AST and extracting the
  literal list returned by its `deps` function. The file is never evaluated: a
  budget check that executes the thing it is judging can be made to lie by the
  file under test, and parsing also lets the check run against a fixture that
  would not compile in place.

  The reverse-edge check covers dynamic references, not only declared ones. A
  contract module naming the runtime through `apply/3`, `Module.concat/1`, or a
  string that resolves to a runtime module is the same architectural violation
  as a dependency tuple, and it is invisible to a deps-list check.

  Returns `:ok` or `{:error, [reason]}` from `check/1` so tests can assert on
  reasons; the task wraps it and raises `Mix.Error` so a failure is a non-zero
  exit for the gate runner and the client hook.
  """

  use Mix.Task

  @contract_app :loopex_protocol
  @runtime_app :loopex
  @contract_mix "apps/loopex_protocol/mix.exs"
  @runtime_mix "apps/loopex/mix.exs"
  @contract_lib "apps/loopex_protocol/lib"

  # Concept: the runtime may depend on the contract and nothing else. Expressed
  # as data so the allowance is one line to read and one line to change.
  @runtime_allowed [@contract_app]

  @impl Mix.Task
  def run([]), do: report(check_repository(File.cwd!()))
  def run([path]), do: report(check_mix_exs(path))

  def run(other) do
    Mix.raise("usage: mix loopex.deps_budget [path/to/mix.exs], got #{inspect(other)}")
  end

  defp report(:ok), do: Mix.shell().info("dependency budget and direction hold")

  defp report({:error, reasons}) do
    Mix.raise("dependency budget violated:\n  " <> Enum.join(reasons, "\n  "))
  end

  @doc """
  ## Concept

  Checks the repository's two applications and the contract's sources, resolved
  against `root`.

  ## Technical depth

  Takes the repository root explicitly because an umbrella child runs with its
  own directory as the working directory, so a relative path resolved at call
  time would silently look inside `apps/loopex` when a test invoked it.

  Accumulates every violation rather than stopping at the first, so one run
  reports the whole picture. An unreadable or unparsable file is a violation,
  not a pass: unavailable evidence never reports success.
  """
  @spec check_repository(Path.t()) :: :ok | {:error, [String.t()]}
  def check_repository(root) do
    reasons =
      contract_reasons(Path.join(root, @contract_mix)) ++
        runtime_reasons(Path.join(root, @runtime_mix)) ++
        reverse_edge_reasons(Path.join(root, @contract_lib))

    done(reasons)
  end

  @doc """
  ## Concept

  Checks one `mix.exs` against the budget for whichever application it declares.

  ## Technical depth

  The declared `:app` selects the rule, so the same command judges the contract
  application and the runtime application correctly without the caller saying
  which it is. An unrecognised application is an error, not a skip.
  """
  @spec check_mix_exs(Path.t()) :: :ok | {:error, [String.t()]}
  def check_mix_exs(path) do
    case declared_app(path) do
      {:ok, @contract_app} -> done(contract_reasons(path))
      {:ok, @runtime_app} -> done(runtime_reasons(path))
      {:ok, other} -> done(["#{path} declares unknown application #{inspect(other)}"])
      {:error, reason} -> done([reason])
    end
  end

  defp done([]), do: :ok
  defp done(reasons), do: {:error, reasons}

  defp contract_reasons(path) do
    case deps(path) do
      {:ok, []} ->
        []

      {:ok, found} ->
        ["#{path}: the contract application must declare no dependency, found #{inspect(found)}"]

      {:error, reason} ->
        [reason]
    end
  end

  defp runtime_reasons(path) do
    case deps(path) do
      {:ok, found} ->
        case found -- @runtime_allowed do
          [] ->
            []

          extra ->
            [
              "#{path}: the runtime application may depend only on " <>
                "#{inspect(@runtime_allowed)}, found extra #{inspect(extra)}"
            ]
        end

      {:error, reason} ->
        [reason]
    end
  end

  @doc """
  ## Concept

  Scans a contract-application source tree for edges back to the runtime and
  returns one reason per edge found, static or dynamic.

  ## Technical depth

  Public so the protected tests exercise this exact code path against a fixture
  tree instead of reimplementing the scan. Returns `[]` when the tree is clean,
  which is why it returns a list rather than an ok tuple: callers accumulate it
  with other reasons.
  """
  @spec reverse_edge_check(Path.t()) :: [String.t()]
  def reverse_edge_check(lib_root), do: reverse_edge_reasons(lib_root)

  # Concept: a contract module must not name the runtime, however it names it.
  defp reverse_edge_reasons(lib_root) do
    lib_root
    |> sources()
    |> Enum.flat_map(&reverse_edges_in/1)
  end

  defp sources(root) do
    case File.dir?(root) do
      true -> Path.wildcard(Path.join(root, "**/*.{ex,exs}"))
      false -> []
    end
  end

  defp reverse_edges_in(file) do
    case File.read(file) do
      {:error, posix} ->
        ["#{file}: could not be read (#{:file.format_error(posix)}); evidence is unavailable"]

      {:ok, source} ->
        case Code.string_to_quoted(source) do
          {:error, _} -> ["#{file}: could not be parsed; evidence is unavailable"]
          {:ok, ast} -> static_edges(file, ast) ++ dynamic_edges(file, source)
        end
    end
  end

  # Concept: a compile-time alias naming the runtime namespace.
  defp static_edges(file, ast) do
    {_ast, found} =
      Macro.prewalk(ast, [], fn
        {:__aliases__, _meta, [:Loopex | _rest]} = node, acc ->
          {node, [Macro.to_string(node) | acc]}

        node, acc ->
          {node, acc}
      end)

    Enum.map(found, fn name ->
      "#{file}: the contract application references the runtime module #{name}"
    end)
  end

  # Concept: the same edge built at runtime from text, which no alias walk sees.
  # Technical depth: matching source text is the only option here, because the
  # module name does not exist as an alias node in the AST at all. A false
  # positive is a review conversation; a missed reverse edge is a broken
  # architectural invariant, so this errs toward reporting.
  @dynamic_forms ~r/(?:Module\.concat|apply|String\.to_(?:existing_)?atom|Kernel\.function_exported\?)/
  @runtime_name ~r/(?:"|:)(?:Elixir\.)?Loopex(?:\.|"|\b)/

  defp dynamic_edges(file, source) do
    source
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.filter(fn {line, _number} ->
      Regex.match?(@dynamic_forms, line) and Regex.match?(@runtime_name, line)
    end)
    |> Enum.map(fn {_line, number} ->
      "#{file}:#{number}: the contract application builds a dynamic reference to the runtime"
    end)
  end

  # --- mix.exs AST reading -------------------------------------------------

  defp declared_app(path) do
    with {:ok, ast} <- ast(path) do
      case literal_value(ast, :app) do
        {:ok, app} when is_atom(app) -> {:ok, app}
        _other -> {:error, "#{path}: no literal :app declaration found"}
      end
    end
  end

  defp deps(path) do
    with {:ok, ast} <- ast(path) do
      case deps_list(ast) do
        {:ok, list} -> {:ok, list}
        :error -> {:error, "#{path}: no literal deps list found; the budget cannot be read"}
      end
    end
  end

  defp ast(path) do
    with {:ok, source} <- read(path) do
      case Code.string_to_quoted(source) do
        {:ok, ast} -> {:ok, ast}
        {:error, _} -> {:error, "#{path}: could not be parsed; evidence is unavailable"}
      end
    end
  end

  defp read(path) do
    case File.read(path) do
      {:ok, source} ->
        {:ok, source}

      {:error, posix} ->
        {:error, "#{path}: could not be read (#{:file.format_error(posix)})"}
    end
  end

  # Concept: find the `deps` function and collect the dependency names it lists.
  # Technical depth: only the top-level elements of the returned list are read.
  # Walking the whole body instead collected every 2-tuple in sight, including
  # the `do` block itself and option pairs like `in_umbrella: true`, which made
  # a correct mix.exs report phantom dependencies named :do and :in_umbrella.
  defp deps_list(ast) do
    {_ast, found} =
      Macro.prewalk(ast, nil, fn
        {def_kind, _meta, [{:deps, _dmeta, args}, body]} = node, acc
        when def_kind in [:def, :defp] and args in [nil, []] ->
          {node, acc || {:body, body}}

        node, acc ->
          {node, acc}
      end)

    case found do
      {:body, body} -> names_from_body(body)
      nil -> :error
    end
  end

  defp names_from_body(body) when is_list(body) do
    case Keyword.fetch(body, :do) do
      {:ok, list} when is_list(list) -> {:ok, Enum.flat_map(list, &dep_name/1)}
      _other -> :error
    end
  end

  defp names_from_body(_body), do: :error

  # A dependency is {name, requirement}, {name, opts}, or {name, requirement, opts}.
  defp dep_name({:{}, _meta, [name | _rest]}) when is_atom(name), do: [name]
  defp dep_name({name, _second}) when is_atom(name), do: [name]
  defp dep_name(_other), do: []

  defp literal_value(ast, key) do
    {_ast, found} =
      Macro.prewalk(ast, nil, fn
        {^key, value} = node, acc when is_atom(value) -> {node, acc || value}
        node, acc -> {node, acc}
      end)

    case found do
      nil -> :error
      value -> {:ok, value}
    end
  end
end
