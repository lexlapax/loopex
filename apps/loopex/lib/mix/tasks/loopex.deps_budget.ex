defmodule Loopex.Checks.DepsBudget do
  @moduledoc """
  ## Concept

  Enforces ADR 0001's application roles and inward dependency direction from
  the repository's actual umbrella inventory. The contract stays independent,
  core stays protocol-only, concrete edges point inward, clients compose edges
  only in tests, and the M1 repository contains only its six planned application
  identities. Standalone extension checks retain ADR 0003's protocol-only shape.

  ## Technical depth

  This module is the one parser authority for both the direct pre-Mix gate
  check and `mix loopex.deps_budget`. It requires the physical root/child
  project set to equal ordinary stage-zero Git entries, parses those projects
  as AST without evaluating code, and derives only the fields that carry
  dependency authority. Unrelated Mix metadata, helpers, and `application/0`
  remain implementation detail.

  A project declaration must expose literal application and role identities,
  exact internal or Hex dependency records, and owned literal compile roots.
  The repository overlay permits only the planned M1 identities and only the
  ReqLLM edge's exact direct external requirement. Before all six identities are
  present, that one edge retains its inherited protocol-only internal shape;
  complete M1 inventory requires its runtime edge like every other concrete
  edge. External requirements resolve through the candidate's canonical
  `mix.lock`; the standalone materializer reconstructs only checksum-bound
  cached Hex packages. Unknown, alternate-source, or redirected applications
  fail closed. Aliases for a command the M1 gate locks also fail as defense in
  depth.
  """

  @contract_app :loopex_protocol
  @runtime_app :loopex
  @roles [:contract, :core, :edge, :composition, :client, :extension]
  @m1_planned_roles %{
    loopex_protocol: :contract,
    loopex: :core,
    loopex_store_local: :edge,
    loopex_llm_reqllm: :edge,
    loopex_executor_local: :edge,
    loopex_composition: :composition,
    loopex_reference_client: :client,
    loopex_cli: :client
  }
  @reqllm_requirement "~> 1.17.1"
  @floor_elixir_version Version.parse!("1.17.0")

  @locked_aliases [
    :compile,
    :format,
    :test,
    :"loopex.core_only",
    :"loopex.deps_budget",
    :"loopex.docs_check",
    :"loopex.format_scope",
    :"loopex.hook_registration",
    :"loopex.matrix",
    :"loopex.status",
    :"loopex.version_train"
  ]

  @typedoc false
  @type dependency :: {atom(), String.t() | nil, keyword()}

  @typedoc false
  @type project_record :: %{
          path: Path.t(),
          relative: String.t() | nil,
          app: atom() | nil,
          role: atom() | nil,
          dependencies: [dependency()],
          source_roots: [Path.t()]
        }

  @doc """
  ## Concept

  Runs the source-loaded dependency check before Mix can execute project code.

  ## Technical depth

  With `--context`, emits the selector owner and derived internal closure. With
  `--materialize <cache-root> <destination> <protected-ids-file>`, safely
  reconstructs the literal lock's exact cached Hex packages into an empty
  destination after refusing archives whose physical identity is protected.
  Otherwise it validates the exact supplied project inventory. Every role
  terminates the standalone VM with success or refusal status.
  """
  @spec main([String.t()]) :: no_return()
  def main(["--context", selector | paths]) when paths != [] do
    case execution_context(File.cwd!(), selector, paths) do
      {:ok, context} ->
        internal = context.internal |> Enum.map_join(",", &Atom.to_string/1)
        allowed = context.allowed |> Enum.map_join(",", &Atom.to_string/1)

        IO.puts(
          "LOOPEX_DEPENDENCY_CONTEXT owner=#{context.owner} internal=#{internal} allowed=#{allowed}"
        )

        System.halt(0)

      {:error, reason} ->
        IO.puts(:stderr, "dependency context refused: #{reason}")
        System.halt(1)
    end
  end

  def main(["--materialize", cache_root, destination, protected_ids_file]) do
    case materialize(File.cwd!(), cache_root, destination, protected_ids_file) do
      :ok ->
        System.halt(0)

      {:error, reason} ->
        IO.puts(:stderr, "dependency materialization refused: #{reason}")
        System.halt(1)
    end
  end

  def main(["--materialize", _cache_root, _destination]) do
    IO.puts(:stderr, "dependency materialization refused: protected identities file is required")
    System.halt(1)
  end

  def main(paths) when is_list(paths) do
    case validate(File.cwd!(), paths) do
      :ok ->
        System.halt(0)

      {:error, reason} ->
        IO.puts(:stderr, "dependency preflight refused: #{reason}")
        System.halt(1)
    end
  end

  @doc """
  ## Concept

  Validates an exact supplied project inventory.

  ## Technical depth

  Returns `:ok` or the first deterministic refusal reason from the complete
  inventory and dependency-graph check.
  """
  @spec validate(Path.t(), [String.t()]) :: :ok | {:error, String.t()}
  def validate(root, paths) do
    case check_inventory(root, paths) do
      :ok -> :ok
      {:error, [reason | _rest]} -> {:error, reason}
    end
  end

  @doc """
  ## Concept

  Discovers and checks every tracked umbrella project.

  ## Technical depth

  Compares Git's ordinary project inventory with the physical tree, then applies
  the same complete graph and lock validation used by the direct gate entrypoint
  and Mix adapter.
  """
  @spec check_repository(Path.t()) :: :ok | {:error, [String.t()]}
  def check_repository(root) do
    case tracked_projects(root) do
      {:ok, projects} -> check_inventory(root, projects)
      {:error, reason} -> {:error, [reason]}
    end
  end

  @doc """
  ## Concept

  Checks that `projects` is the complete tracked inventory and enforces its graph.

  ## Technical depth

  Refuses omissions, duplicates, noncanonical project declarations, invalid
  roles, disallowed dependency sources or directions, unsatisfied lock-backed
  requirements, and protocol-to-runtime references.
  """
  @spec check_inventory(Path.t(), [String.t()]) :: :ok | {:error, [String.t()]}
  def check_inventory(root, projects) when is_list(projects) do
    with {:ok, tracked} <- tracked_projects(root),
         {:ok, supplied} <- canonical_supplied_inventory(projects),
         true <- supplied == tracked,
         {:ok, records} <- records(root, tracked) do
      roles =
        records
        |> Enum.reject(&is_nil(&1.app))
        |> Map.new(&{&1.app, &1.role})

      complete_m1_inventory? =
        Enum.all?(Map.keys(@m1_planned_roles), &Map.has_key?(roles, &1))

      reasons =
        duplicate_app_reasons(records) ++
          required_app_reasons(roles) ++
          planned_inventory_reasons(records) ++
          Enum.flat_map(
            records,
            &repository_record_reasons(&1, roles, complete_m1_inventory?)
          ) ++
          m1_external_dependency_reasons(records, roles) ++
          external_lock_reasons(root, records, roles) ++
          Enum.flat_map(records, &source_root_reasons(root, &1)) ++
          reverse_edge_reasons(contract_source_roots(records))

      done(reasons)
    else
      false ->
        {:error, ["the supplied project inventory is incomplete, duplicated, or unordered"]}

      {:error, reason} ->
        {:error, [reason]}
    end
  end

  def check_inventory(_root, _projects),
    do: {:error, ["the supplied project inventory is unavailable"]}

  @doc """
  ## Concept

  Checks one child project against the role budget.

  ## Technical depth

  Parses the project as data and validates its identity, role, dependency
  shape, and locked aliases without evaluating the project module.
  """
  @spec check_mix_exs(Path.t()) :: :ok | {:error, [String.t()]}
  def check_mix_exs(path) do
    with {:ok, record} <- project_record(path, relative_from_path(path)),
         false <- is_nil(record.app) do
      done(record_reasons(record, standalone_roles(record)))
    else
      true -> {:error, ["#{path}: the umbrella root has no application dependency role"]}
      {:error, reason} -> {:error, [reason]}
    end
  end

  @doc """
  ## Concept

  Parses one root or child project without evaluating it.

  ## Technical depth

  Extracts only canonical literal identity, role, dependency, and alias fields
  into a project record; ambiguous or executable authority fails closed.
  """
  @spec project_record(Path.t(), String.t() | nil) ::
          {:ok, project_record()} | {:error, String.t()}
  def project_record(path, relative \\ nil) do
    with {:ok, bytes} <- read(path),
         {:ok, quoted} <- parse(bytes, path),
         {:ok, expressions} <- module_body(quoted),
         :ok <- mix_project?(expressions),
         {:ok, project} <- one_function(expressions, :project),
         true <- Keyword.keyword?(project),
         :ok <- unique_keyword(project, "project/0"),
         {:ok, dependencies} <- dependencies(expressions, Keyword.get(project, :deps)),
         :ok <- locked_aliases(expressions, Keyword.get(project, :aliases)),
         {:ok, source_roots} <- source_roots(path, expressions, project),
         {:ok, record} <- identity(path, relative, project, dependencies, source_roots) do
      {:ok, record}
    else
      false -> {:error, "#{path}: project/0 must return one literal keyword"}
      {:error, reason} -> {:error, prefix(path, reason)}
      _other -> {:error, "#{path}: project configuration is not canonical literal data"}
    end
  end

  @doc """
  ## Concept

  Returns the application that owns a canonical app test selector.

  ## Technical depth

  Resolves ownership through the selector's child project and its literal
  application identity, rather than trusting a caller-provided application.
  """
  @spec owning_application(Path.t(), String.t()) :: {:ok, atom()} | {:error, String.t()}
  def owning_application(root, selector) do
    case String.split(selector, "/") do
      ["apps", directory, "test" | rest] when rest != [] ->
        relative = "apps/#{directory}/mix.exs"

        with {:ok, record} <- project_record(Path.join(root, relative), relative),
             application when is_atom(application) <- record.app do
          {:ok, application}
        else
          {:error, reason} -> {:error, reason}
        end

      _other ->
        {:error, "selector has no owning umbrella application"}
    end
  end

  @doc """
  ## Concept

  Derives a selector's owner and allowed internal dependency closure.

  ## Technical depth

  Validates the complete project inventory first, then returns the discovered
  internal applications and the transitive production closure reachable from
  the selector owner.
  """
  @spec execution_context(Path.t(), String.t(), [String.t()]) ::
          {:ok, %{owner: atom(), internal: [atom()], allowed: [atom()]}} | {:error, String.t()}
  def execution_context(root, selector, projects) do
    with :ok <- validate(root, projects),
         {:ok, tracked} <- tracked_projects(root),
         {:ok, inventory} <- records(root, tracked),
         {:ok, owner} <- owning_application(root, selector),
         by_app <- inventory |> Enum.reject(&is_nil(&1.app)) |> Map.new(&{&1.app, &1}),
         true <- Map.has_key?(by_app, owner) do
      internal = by_app |> Map.keys() |> Enum.sort()
      allowed = allowed_internal_closure(by_app, [owner], MapSet.new()) |> MapSet.to_list()
      {:ok, %{owner: owner, internal: internal, allowed: Enum.sort(allowed)}}
    else
      false -> {:error, "selector owner is outside the discovered project inventory"}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  ## Concept

  Checks that protocol sources do not point back to the runtime.

  ## Technical depth

  Refuses Erlang-family contract inputs and reports static runtime aliases or
  unambiguous structural dynamic dispatch that would reverse the
  contract-to-core dependency direction, while preserving the contract-owned
  `Loopex.Protocol` namespace and ordinary no-parentheses field access.
  """
  @spec reverse_edge_check(Path.t()) :: [String.t()]
  def reverse_edge_check(lib_root), do: reverse_edge_reasons([lib_root])

  # Concept: the gate may reconstruct only the exact Hex sources already bound
  # by the candidate lock and ambient package cache.
  # Technical depth: lock parsing admits literal data only, both Hex checksums
  # are independently checked, protected physical identities are fenced before
  # archive reads, and tar contents are validated in memory before the empty
  # destination is touched.
  defp materialize(root, cache_root, destination, protected_ids_file) do
    lock_path = Path.join(root, "mix.lock")

    with {:ok, protected} <- protected_identities(protected_ids_file),
         {:ok, lock} <- literal_hex_lock(lock_path),
         {:ok, closure} <- materialization_closure(root, lock),
         {:ok, packages} <- load_packages(cache_root, closure, protected),
         :ok <- write_materialized(destination, packages) do
      :ok
    end
  rescue
    exception -> {:error, "materializer failed closed (#{Exception.message(exception)})"}
  catch
    kind, reason -> {:error, "materializer failed closed (#{kind}: #{inspect(reason)})"}
  end

  defp protected_identities(path) do
    with {:ok, %File.Stat{type: :regular}} <- File.lstat(path),
         {:ok, bytes} <- File.read(path),
         {:ok, identities} <- parse_protected_identities(bytes) do
      {:ok, identities}
    else
      {:ok, _stat} ->
        {:error, "protected identities input must be one ordinary regular file"}

      {:error, posix} when is_atom(posix) ->
        {:error, "protected identities input is unavailable (#{:file.format_error(posix)})"}

      _other ->
        {:error, "protected identities input is not canonical sorted unique device:inode data"}
    end
  end

  defp parse_protected_identities(""), do: {:ok, MapSet.new()}

  defp parse_protected_identities(bytes) when is_binary(bytes) do
    lines = String.split(bytes, "\n", trim: false)

    with "" <- List.last(lines),
         records when records != [] <- Enum.drop(lines, -1),
         true <- records == Enum.sort(records),
         true <- length(records) == length(Enum.uniq(records)),
         parsed <- Enum.map(records, &parse_protected_identity/1),
         true <- Enum.all?(parsed, &match?({:ok, _identity}, &1)) do
      identities = Enum.map(parsed, fn {:ok, identity} -> identity end)
      {:ok, MapSet.new(identities)}
    else
      _other -> {:error, :noncanonical_protected_identities}
    end
  end

  defp parse_protected_identity(line) do
    case Regex.run(~r/\A(0|[1-9][0-9]*):(0|[1-9][0-9]*)\z/u, line) do
      [^line, device, inode] -> {:ok, {String.to_integer(device), String.to_integer(inode)}}
      _other -> :error
    end
  end

  defp literal_hex_lock(path) do
    with true <- tracked_ordinary_source?(Path.dirname(path), path),
         {:ok, %File.Stat{type: :regular}} <- File.lstat(path),
         {:ok, bytes} <- File.read(path),
         {:ok, quoted} <- Code.string_to_quoted(bytes, file: path, emit_warnings: false),
         true <- Macro.quoted_literal?(quoted),
         {:ok, lock} <- literal_term(quoted),
         true <- is_map(lock),
         {:ok, records} <- hex_lock_records(lock) do
      {:ok, records}
    else
      {:ok, _stat} ->
        {:error, "mix.lock must be one ordinary regular file"}

      {:error, :enoent} ->
        {:error, "mix.lock is missing"}

      {:error, posix} when is_atom(posix) ->
        {:error, "mix.lock is unavailable (#{:file.format_error(posix)})"}

      false ->
        {:error, "mix.lock must be one tracked ordinary stage-zero 100644 blob"}

      _other ->
        {:error, "mix.lock must contain only one literal map of canonical Hex locks"}
    end
  end

  defp literal_term({:%{}, _meta, pairs}) when is_list(pairs) do
    Enum.reduce_while(pairs, {:ok, %{}}, fn
      {key_ast, value_ast}, {:ok, map} ->
        with {:ok, key} <- literal_term(key_ast),
             {:ok, value} <- literal_term(value_ast),
             false <- Map.has_key?(map, key) do
          {:cont, {:ok, Map.put(map, key, value)}}
        else
          _other -> {:halt, :error}
        end

      _pair, _acc ->
        {:halt, :error}
    end)
  end

  defp literal_term({:{}, _meta, elements}) when is_list(elements) do
    with {:ok, decoded} <- literal_list(elements), do: {:ok, List.to_tuple(decoded)}
  end

  defp literal_term({left, right}) do
    with {:ok, decoded_left} <- literal_term(left),
         {:ok, decoded_right} <- literal_term(right) do
      {:ok, {decoded_left, decoded_right}}
    end
  end

  defp literal_term(value) when is_list(value), do: literal_list(value)

  defp literal_term(value) when is_atom(value) or is_binary(value) or is_number(value),
    do: {:ok, value}

  defp literal_term(_value), do: :error

  defp literal_list(values) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, decoded} ->
      case literal_term(value) do
        {:ok, term} -> {:cont, {:ok, [term | decoded]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, decoded} -> {:ok, Enum.reverse(decoded)}
      :error -> :error
    end
  end

  defp hex_lock_records(lock) do
    lock
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce_while({:ok, []}, fn entry, {:ok, records} ->
      case hex_lock_record(entry) do
        {:ok, record} -> {:cont, {:ok, [record | records]}}
        :error -> {:halt, {:error, "mix.lock contains a noncanonical Hex lock"}}
      end
    end)
    |> case do
      {:ok, records} -> {:ok, Enum.reverse(records)}
      error -> error
    end
  end

  defp hex_lock_record(
         {name_atom,
          {:hex, package, version, inner_sha, managers, dependencies, repo, package_sha}}
       )
       when is_atom(name_atom) and is_atom(package) and is_binary(version) and
              is_binary(inner_sha) and is_list(managers) and is_list(dependencies) and
              is_binary(repo) and is_binary(package_sha) do
    name = Atom.to_string(name_atom)

    if package == name_atom and package_name?(name) and canonical_version?(version) and
         repo == "hexpm" and sha256?(inner_sha) and sha256?(package_sha) and
         canonical_managers?(managers) and canonical_lock_dependencies?(dependencies) do
      {:ok,
       %{
         name: name,
         version: version,
         inner_sha: inner_sha,
         managers: managers,
         dependencies: Enum.map(dependencies, &lock_dependency/1),
         repo: repo,
         package_sha: package_sha
       }}
    else
      :error
    end
  end

  defp hex_lock_record(_entry), do: :error

  defp package_name?(name), do: Regex.match?(~r/\A[a-z][a-z0-9_]*\z/u, name)

  defp canonical_version?(version) do
    case Version.parse(version) do
      {:ok, parsed} -> Version.to_string(parsed) == version
      :error -> false
    end
  end

  defp safe_component?(value) when is_binary(value) do
    value not in ["", ".", ".."] and String.valid?(value) and
      Regex.match?(~r/\A[0-9A-Za-z][0-9A-Za-z._+-]*\z/u, value)
  end

  defp safe_component?(_value), do: false

  defp sha256?(digest), do: Regex.match?(~r/\A[0-9a-f]{64}\z/u, digest)

  defp canonical_managers?(managers) do
    managers != [] and managers == Enum.uniq(managers) and
      Enum.all?(managers, &(&1 in [:mix, :rebar3, :make]))
  end

  defp canonical_lock_dependency?({name, requirement, options})
       when is_atom(name) and is_binary(requirement) and requirement != "" and is_list(options) do
    package_name?(Atom.to_string(name)) and
      match?({:ok, _}, Version.parse_requirement(requirement)) and
      Keyword.keyword?(options) and unique_keyword?(options) and
      Keyword.keys(options) |> Enum.sort() == [:hex, :optional, :repo] and
      Keyword.get(options, :hex) == name and Keyword.get(options, :repo) == "hexpm" and
      is_boolean(Keyword.get(options, :optional))
  end

  defp canonical_lock_dependency?(_dependency), do: false

  defp canonical_lock_dependencies?(dependencies) do
    Enum.all?(dependencies, &canonical_lock_dependency?/1) and
      Enum.map(dependencies, &elem(&1, 0)) ==
        dependencies |> Enum.map(&elem(&1, 0)) |> Enum.uniq()
  end

  defp lock_dependency({name, requirement, options}) do
    %{
      name: Atom.to_string(name),
      requirement: requirement,
      optional: Keyword.fetch!(options, :optional),
      repo: Keyword.fetch!(options, :repo)
    }
  end

  defp materialization_closure(root, lock) do
    with {:ok, tracked} <- tracked_projects(root),
         {:ok, records} <- records(root, tracked),
         {:ok, {root_name, requirement}} <- sole_external_materialization_root(records),
         {:ok, closure} <- exact_nonoptional_lock_closure(lock, root_name, requirement) do
      {:ok, closure}
    end
  end

  defp sole_external_materialization_root(records) do
    internal =
      records
      |> Enum.reject(&is_nil(&1.app))
      |> MapSet.new(& &1.app)

    external =
      for record <- records,
          {name, requirement, options} <- record.dependencies,
          not MapSet.member?(internal, name) and not in_umbrella?(options),
          do: {record.app, name, requirement, options}

    case external do
      [{:loopex_llm_reqllm, :req_llm, @reqllm_requirement, []}] ->
        {:ok, {"req_llm", @reqllm_requirement}}

      _other ->
        {:error,
         "materialization requires the sole direct ReqLLM dependency " <>
           inspect({:req_llm, @reqllm_requirement})}
    end
  end

  defp exact_nonoptional_lock_closure(lock, root_name, root_requirement) do
    by_name = Map.new(lock, &{&1.name, &1})

    with {:ok, names} <-
           visit_lock_closure(by_name, [{root_name, root_requirement}], MapSet.new()),
         lock_names <- MapSet.new(Map.keys(by_name)),
         true <- names == lock_names do
      {:ok, Enum.filter(lock, &MapSet.member?(names, &1.name))}
    else
      false ->
        {:error, "mix.lock contains records outside the exact non-optional ReqLLM closure"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp visit_lock_closure(_by_name, [], seen), do: {:ok, seen}

  defp visit_lock_closure(by_name, [{name, requirement} | rest], seen) do
    with %{version: version} = record <- Map.get(by_name, name),
         {:ok, parsed_version} <- Version.parse(version),
         {:ok, parsed_requirement} <- Version.parse_requirement(requirement),
         true <- Version.match?(parsed_version, parsed_requirement) do
      if MapSet.member?(seen, name) do
        visit_lock_closure(by_name, rest, seen)
      else
        dependencies =
          record.dependencies
          |> Enum.reject(& &1.optional)
          |> Enum.map(&{&1.name, &1.requirement})

        visit_lock_closure(by_name, rest ++ dependencies, MapSet.put(seen, name))
      end
    else
      nil ->
        {:error, "mix.lock is missing required non-optional package #{name}"}

      _other ->
        {:error, "mix.lock package #{name} does not satisfy requirement #{inspect(requirement)}"}
    end
  end

  defp load_packages(cache_root, lock, protected) do
    case File.lstat(cache_root) do
      {:ok, %File.Stat{type: :directory}} ->
        Enum.reduce_while(lock, {:ok, []}, fn record, {:ok, packages} ->
          case load_package(cache_root, record, protected) do
            {:ok, package} -> {:cont, {:ok, [package | packages]}}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)
        |> case do
          {:ok, packages} -> {:ok, Enum.reverse(packages)}
          error -> error
        end

      {:ok, _stat} ->
        {:error, "Hex cache root must be one ordinary directory"}

      {:error, posix} ->
        {:error, "Hex cache root is unavailable (#{:file.format_error(posix)})"}
    end
  end

  defp load_package(cache_root, record, protected) do
    repo_root = Path.join(cache_root, record.repo)
    archive = Path.join(repo_root, "#{record.name}-#{record.version}.tar")

    with {:ok, %File.Stat{type: :directory}} <- File.lstat(repo_root),
         {:ok, %File.Stat{type: :regular} = archive_stat} <- File.lstat(archive),
         :ok <- archive_not_protected(archive, archive_stat, protected),
         {:ok, bytes} <- File.read(archive),
         {:ok, %File.Stat{type: :regular} = after_read_stat} <- File.lstat(archive),
         :ok <- unchanged_archive_identity(archive, archive_stat, after_read_stat),
         :ok <- archive_not_protected(archive, after_read_stat, protected),
         true <- digest(bytes) == record.package_sha,
         {:ok, outer_table} <- tar_table({:binary, bytes}, []),
         :ok <- exact_outer_table(outer_table),
         {:ok, outer_entries} <- tar_extract({:binary, bytes}, []),
         {:ok, outer} <- extracted_map(outer_entries, outer_table),
         "3" <- Map.get(outer, "VERSION"),
         checksum when is_binary(checksum) <- Map.get(outer, "CHECKSUM"),
         true <- checksum == String.upcase(record.inner_sha),
         metadata when is_binary(metadata) <- Map.get(outer, "metadata.config"),
         :ok <- metadata_matches_lock(metadata, record),
         contents when is_binary(contents) <- Map.get(outer, "contents.tar.gz"),
         {:ok, inner_table} <- tar_table({:binary, contents}, [:compressed]),
         :ok <- safe_inner_table(inner_table),
         {:ok, inner_entries} <- tar_extract({:binary, contents}, [:compressed]),
         {:ok, files} <- extracted_files(inner_entries, inner_table) do
      {:ok, %{name: record.name, files: files ++ [hex_scm_marker(record)]}}
    else
      {:ok, _stat} ->
        {:error, "#{archive}: cache repository or package path is not ordinary"}

      {:error, :enoent} ->
        {:error, "#{archive}: cached package is missing"}

      {:error, reason} when is_binary(reason) ->
        {:error, reason}

      {:error, posix} when is_atom(posix) ->
        {:error, "#{archive}: cached package is unavailable (#{:file.format_error(posix)})"}

      false ->
        {:error, "#{archive}: cached package checksum does not match mix.lock"}

      _other ->
        {:error, "#{archive}: cached package is not a canonical safe Hex archive"}
    end
  end

  defp archive_not_protected(archive, stat, protected) do
    identity = physical_identity(stat)

    if MapSet.member?(protected, identity),
      do: {:error, "#{archive}: cached package identity is protected"},
      else: :ok
  end

  defp physical_identity(stat), do: {stat.major_device, stat.inode}

  defp unchanged_archive_identity(archive, before, after_read) do
    if physical_identity(before) == physical_identity(after_read),
      do: :ok,
      else: {:error, "#{archive}: cached package identity changed while being read"}
  end

  defp metadata_matches_lock(bytes, record) do
    with {:ok, terms} <- erlang_literal_terms(bytes),
         {:ok, metadata} <- unique_binary_pairs(terms),
         true <- Map.get(metadata, "name") == record.name,
         true <- Map.get(metadata, "version") == record.version,
         :ok <- metadata_build_tools(metadata, record.managers),
         :ok <- metadata_dependencies(metadata, record.dependencies),
         :ok <- metadata_elixir_floor(metadata, record.managers) do
      :ok
    else
      {:error, reason} -> {:error, "metadata.config #{reason}"}
      false -> {:error, "metadata.config name or version does not match mix.lock"}
      _other -> {:error, "metadata.config is not canonical literal package authority"}
    end
  end

  defp erlang_literal_terms(bytes) when is_binary(bytes) do
    scan_erlang_terms(String.to_charlist(bytes), 1, [])
  rescue
    _exception -> {:error, "is not literal Erlang terms"}
  catch
    _kind, _reason -> {:error, "is not literal Erlang terms"}
  end

  defp scan_erlang_terms([], _line, terms), do: {:ok, Enum.reverse(terms)}

  defp scan_erlang_terms(chars, line, terms) do
    case :erl_scan.tokens([], chars, line) do
      {:done, {:ok, tokens, next_line}, rest} ->
        case :erl_parse.parse_term(tokens) do
          {:ok, term} -> scan_erlang_terms(rest, next_line, [term | terms])
          _other -> {:error, "is not literal Erlang terms"}
        end

      _other ->
        {:error, "is not literal Erlang terms"}
    end
  end

  defp unique_binary_pairs(terms) when terms != [] do
    Enum.reduce_while(terms, {:ok, %{}}, fn
      {key, value}, {:ok, acc} when is_binary(key) ->
        if Map.has_key?(acc, key),
          do: {:halt, {:error, "contains a duplicate #{inspect(key)} field"}},
          else: {:cont, {:ok, Map.put(acc, key, value)}}

      _term, _acc ->
        {:halt, {:error, "must contain only binary-key literal pairs"}}
    end)
  end

  defp unique_binary_pairs(_terms), do: {:error, "is empty"}

  defp metadata_build_tools(metadata, managers) do
    expected = Enum.map(managers, &Atom.to_string/1)

    if Map.get(metadata, "build_tools") == expected,
      do: :ok,
      else: {:error, "build_tools do not match mix.lock"}
  end

  defp metadata_dependencies(metadata, lock_dependencies) do
    with requirements when is_list(requirements) <- Map.get(metadata, "requirements"),
         {:ok, parsed} <- parse_metadata_requirements(requirements),
         expected <- Enum.sort_by(lock_dependencies, & &1.name),
         true <- parsed == expected do
      :ok
    else
      _other -> {:error, "requirements do not match mix.lock"}
    end
  end

  defp parse_metadata_requirements(requirements) do
    Enum.reduce_while(requirements, {:ok, []}, fn requirement, {:ok, acc} ->
      with {:ok, fields} <- unique_binary_pairs(requirement),
           name when is_binary(name) <- Map.get(fields, "name"),
           ^name <- Map.get(fields, "app"),
           optional when is_boolean(optional) <- Map.get(fields, "optional"),
           version_requirement when is_binary(version_requirement) <-
             Map.get(fields, "requirement"),
           "hexpm" <- Map.get(fields, "repository"),
           true <-
             Map.keys(fields) |> Enum.sort() ==
               ["app", "name", "optional", "repository", "requirement"] do
        parsed = %{
          name: name,
          requirement: version_requirement,
          optional: optional,
          repo: "hexpm"
        }

        {:cont, {:ok, [parsed | acc]}}
      else
        _other -> {:halt, {:error, :invalid_requirement}}
      end
    end)
    |> case do
      {:ok, parsed} -> {:ok, Enum.sort_by(parsed, & &1.name)}
      error -> error
    end
  end

  defp metadata_elixir_floor(metadata, managers) do
    requirement = Map.get(metadata, "elixir")

    cond do
      :mix in managers and not is_binary(requirement) ->
        {:error, "must contain exactly one Elixir requirement for a Mix package"}

      is_nil(requirement) ->
        :ok

      is_binary(requirement) ->
        case Version.parse_requirement(requirement) do
          {:ok, parsed} ->
            if Version.match?(@floor_elixir_version, parsed),
              do: :ok,
              else: {:error, "Elixir requirement excludes the bound 1.17.0 floor"}

          :error ->
            {:error, "Elixir requirement is malformed"}
        end

      true ->
        {:error, "Elixir requirement is malformed"}
    end
  end

  # Concept: unpacked source remains the exact locked Hex dependency Mix knows,
  # rather than an anonymous directory that merely contains the same files.
  # Technical depth: Hex SCM recognizes the external-term `.hex` marker. Its
  # authority is derived only after both archive checksums and metadata parity
  # pass, and the package payload is forbidden from supplying a competing file.
  defp hex_scm_marker(record) do
    authority = %{
      name: record.name,
      version: record.version,
      repo: record.repo,
      managers: record.managers,
      inner_checksum: record.inner_sha,
      outer_checksum: record.package_sha
    }

    %{
      name: ".hex",
      mode: 0o644,
      bytes: :erlang.term_to_binary({{:hex, 2, 0}, authority}, [:deterministic])
    }
  end

  defp digest(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  defp tar_table(source, options) do
    case :erl_tar.table(tar_source(source), [:verbose | options]) do
      {:ok, table} when is_list(table) -> {:ok, table}
      _other -> {:error, :invalid_tar_table}
    end
  rescue
    _exception -> {:error, :invalid_tar_table}
  catch
    _kind, _reason -> {:error, :invalid_tar_table}
  end

  defp tar_extract(source, options) do
    case :erl_tar.extract(tar_source(source), [:memory | options]) do
      {:ok, entries} when is_list(entries) -> {:ok, entries}
      _other -> {:error, :invalid_tar_contents}
    end
  rescue
    _exception -> {:error, :invalid_tar_contents}
  catch
    _kind, _reason -> {:error, :invalid_tar_contents}
  end

  defp tar_source({:binary, bytes}), do: {:binary, bytes}
  defp tar_source(path), do: String.to_charlist(path)

  defp exact_outer_table(table) do
    expected = ["VERSION", "CHECKSUM", "metadata.config", "contents.tar.gz"]

    with {:ok, entries} <- table_entries(table),
         true <- Enum.map(entries, & &1.name) == expected,
         true <- Enum.all?(entries, &(&1.type == :regular)) do
      :ok
    else
      _other -> {:error, :noncanonical_outer_table}
    end
  end

  defp safe_inner_table(table) do
    with {:ok, entries} <- table_entries(table),
         true <- entries != [],
         true <- Enum.all?(entries, &(&1.type == :regular and safe_relative_file?(&1.name))),
         names <- Enum.map(entries, & &1.name),
         true <- length(names) == length(Enum.uniq(names)),
         :ok <- no_embedded_hex_marker(names),
         true <- no_file_prefix_collision?(names) do
      :ok
    else
      {:error, reason} when is_binary(reason) -> {:error, reason}
      _other -> {:error, :unsafe_inner_table}
    end
  end

  defp no_embedded_hex_marker(names) do
    if ".hex" in names,
      do: {:error, "package payload must not supply the Hex SCM marker"},
      else: :ok
  end

  defp table_entries(table) do
    Enum.reduce_while(table, {:ok, []}, fn
      {name, type, size, _mtime, mode, _uid, _gid}, {:ok, entries}
      when is_list(name) and is_atom(type) and is_integer(size) and size >= 0 and
             is_integer(mode) ->
        case tar_name(name) do
          {:ok, binary} ->
            {:cont, {:ok, [%{name: binary, type: type, size: size, mode: mode} | entries]}}

          :error ->
            {:halt, {:error, :invalid_tar_name}}
        end

      _entry, _acc ->
        {:halt, {:error, :invalid_tar_entry}}
    end)
    |> case do
      {:ok, entries} -> {:ok, Enum.reverse(entries)}
      error -> error
    end
  end

  defp tar_name(name) do
    case :unicode.characters_to_binary(name) do
      binary when is_binary(binary) -> if String.valid?(binary), do: {:ok, binary}, else: :error
      _other -> :error
    end
  rescue
    _exception -> :error
  end

  defp safe_relative_file?(name) do
    components = String.split(name, "/", trim: false)

    Path.type(name) == :relative and not String.contains?(name, ["\\", <<0>>]) and
      components != [] and Enum.all?(components, &(&1 not in ["", ".", ".."])) and
      Path.join(components) == name
  end

  defp no_file_prefix_collision?(names) do
    names
    |> Enum.sort()
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.all?(fn [left, right] -> not String.starts_with?(right, left <> "/") end)
  end

  defp extracted_map(entries, table) do
    expected = Enum.map(table, fn {name, _type, _size, _mtime, _mode, _uid, _gid} -> name end)

    with true <- length(entries) == length(expected),
         true <- Enum.all?(entries, fn {name, bytes} -> is_list(name) and is_binary(bytes) end),
         true <- Enum.map(entries, &elem(&1, 0)) == expected,
         mapped <- Map.new(entries, fn {name, bytes} -> {List.to_string(name), bytes} end),
         true <- map_size(mapped) == length(expected) do
      {:ok, mapped}
    else
      _other -> {:error, :extracted_table_mismatch}
    end
  end

  defp extracted_files(entries, table) do
    with {:ok, descriptors} <- table_entries(table),
         {:ok, contents} <- extracted_map(entries, table) do
      {:ok,
       Enum.map(descriptors, fn descriptor ->
         %{
           name: descriptor.name,
           mode: descriptor.mode,
           bytes: Map.fetch!(contents, descriptor.name)
         }
       end)}
    end
  end

  defp write_materialized(destination, packages) do
    destination = Path.expand(destination)
    parent = Path.dirname(destination)
    basename = Path.basename(destination)

    with true <- safe_component?(basename),
         {:ok, existed?} <- empty_destination?(destination),
         :ok <- File.mkdir_p(parent),
         {:ok, stage} <- create_stage(parent, basename) do
      result =
        with :ok <- write_stage(stage, packages),
             :ok <- install_stage(stage, destination, existed?) do
          :ok
        end

      if result != :ok, do: File.rm_rf(stage)
      result
    else
      false ->
        {:error, "destination must end in one safe path component"}

      {:error, reason} when is_binary(reason) ->
        {:error, reason}

      {:error, posix} when is_atom(posix) ->
        {:error, "destination could not be materialized (#{:file.format_error(posix)})"}
    end
  end

  defp empty_destination?(destination) do
    case File.lstat(destination) do
      {:error, :enoent} ->
        {:ok, false}

      {:ok, %File.Stat{type: :directory}} ->
        case File.ls(destination) do
          {:ok, []} -> {:ok, true}
          {:ok, _entries} -> {:error, "destination must be empty"}
          {:error, posix} -> {:error, posix}
        end

      {:ok, _stat} ->
        {:error, "destination must be absent or one empty ordinary directory"}

      {:error, posix} ->
        {:error, posix}
    end
  end

  defp create_stage(parent, basename) do
    stage = Path.join(parent, ".#{basename}.loopex-#{System.unique_integer([:positive])}")

    case File.mkdir(stage) do
      :ok -> {:ok, stage}
      {:error, posix} -> {:error, posix}
    end
  end

  defp write_stage(stage, packages) do
    Enum.reduce_while(packages, :ok, fn package, :ok ->
      package_root = Path.join(stage, package.name)

      case File.mkdir(package_root) do
        :ok ->
          case write_package_files(package_root, package.files) do
            :ok -> {:cont, :ok}
            {:error, reason} -> {:halt, {:error, reason}}
          end

        {:error, posix} ->
          {:halt, {:error, posix}}
      end
    end)
  end

  defp write_package_files(package_root, files) do
    Enum.reduce_while(files, :ok, fn file, :ok ->
      path = Path.join(package_root, file.name)

      with :ok <- File.mkdir_p(Path.dirname(path)),
           :ok <- File.write(path, file.bytes, [:binary, :exclusive]),
           :ok <- File.chmod(path, Bitwise.band(file.mode, 0o777)) do
        {:cont, :ok}
      else
        {:error, posix} -> {:halt, {:error, posix}}
      end
    end)
  end

  defp install_stage(stage, destination, existed?) do
    result =
      with :ok <- if(existed?, do: File.rmdir(destination), else: :ok),
           :ok <- File.rename(stage, destination) do
        :ok
      end

    if result != :ok, do: File.rm_rf(stage)
    result
  end

  defp read(path) do
    case File.read(path) do
      {:ok, bytes} -> {:ok, bytes}
      {:error, posix} -> {:error, "could not be read (#{:file.format_error(posix)})"}
    end
  end

  defp parse(bytes, path) do
    case Code.string_to_quoted(bytes, file: path) do
      {:ok, quoted} -> {:ok, quoted}
      {:error, _reason} -> {:error, "could not be parsed; evidence is unavailable"}
    end
  end

  defp module_body({:defmodule, _meta, [_name, [do: body]]}), do: {:ok, block(body)}
  defp module_body(_other), do: {:error, "expected exactly one Mix.Project module"}

  defp block({:__block__, _meta, expressions}), do: expressions
  defp block(expression), do: [expression]

  defp mix_project?(expressions) do
    count =
      Enum.count(expressions, fn
        {:use, _meta, [{:__aliases__, _alias_meta, [:Mix, :Project]}]} -> true
        _other -> false
      end)

    if count == 1, do: :ok, else: {:error, "expected exactly one use Mix.Project declaration"}
  end

  defp one_function(expressions, name) do
    clauses = Enum.flat_map(expressions, &target_clause(&1, name))

    case clauses do
      [{:plain_zero, body}] -> {:ok, body}
      _other -> {:error, "#{name}/0 must have exactly one definition"}
    end
  end

  defp target_clause({kind, _meta, [head, [do: body]]}, name) when kind in [:def, :defp] do
    case head do
      {^name, _name_meta, args} when args in [[], nil] -> [{:plain_zero, body}]
      {^name, _name_meta, _args} -> [:other]
      {:when, _when_meta, [{^name, _name_meta, _args} | _guards]} -> [:other]
      _other -> []
    end
  end

  defp target_clause({:defdelegate, _meta, [{name, _name_meta, _args} | _rest]}, name),
    do: [:other]

  defp target_clause(_expression, _name), do: []

  defp dependencies(expressions, reference) do
    with {:ok, body} <- referenced_body(expressions, :deps, reference),
         true <- is_list(body),
         records <- Enum.map(body, &dependency/1),
         true <- Enum.all?(records, &match?({:ok, _, _, _}, &1)),
         parsed <-
           Enum.map(records, fn {:ok, name, requirement, options} ->
             {name, requirement, options}
           end),
         true <- unique_names?(parsed) do
      {:ok, parsed}
    else
      {:error, reason} -> {:error, reason}
      _other -> {:error, "deps must be one unambiguous record of unique literal dependency data"}
    end
  end

  defp referenced_body(_expressions, _name, body) when is_list(body), do: {:ok, body}

  defp referenced_body(expressions, name, {name, _meta, context}) when context in [[], nil],
    do: one_function(expressions, name)

  defp referenced_body(_expressions, name, _other),
    do: {:error, "project/0 must expose #{name}/0 or literal #{name} data"}

  defp dependency({name, options}) when is_atom(name) and is_list(options) do
    if internal_dependency_options?(options),
      do: {:ok, name, nil, options},
      else: :error
  end

  defp dependency({name, requirement})
       when is_atom(name) and is_binary(requirement) and requirement != "" do
    if valid_requirement?(requirement), do: {:ok, name, requirement, []}, else: :error
  end

  defp dependency(_other), do: :error

  defp internal_dependency_options?(options) do
    Keyword.keyword?(options) and Macro.quoted_literal?(options) and unique_keyword?(options) and
      Keyword.get(options, :in_umbrella) == true and
      Enum.all?(Keyword.keys(options), &(&1 in [:in_umbrella, :only])) and
      environment_option?(Keyword.get(options, :only, :absent))
  end

  defp environment_option?(:absent), do: true
  defp environment_option?(value) when is_atom(value), do: true

  defp environment_option?(values) when is_list(values),
    do:
      values != [] and Enum.all?(values, &is_atom/1) and
        length(values) == length(Enum.uniq(values))

  defp environment_option?(_value), do: false

  defp valid_requirement?(requirement),
    do: match?({:ok, _parsed}, Version.parse_requirement(requirement))

  defp locked_aliases(_expressions, nil), do: :ok

  defp locked_aliases(expressions, reference) do
    with {:ok, aliases} <- referenced_body(expressions, :aliases, reference),
         true <- Keyword.keyword?(aliases),
         :ok <- unique_keyword(aliases, "aliases") do
      forbidden = Enum.filter(Keyword.keys(aliases), &(&1 in @locked_aliases))

      if forbidden == [],
        do: :ok,
        else: {:error, "aliases replace locked commands #{inspect(Enum.sort(forbidden))}"}
    else
      {:error, reason} -> {:error, reason}
      false -> {:error, "aliases must be a literal keyword when present"}
    end
  end

  defp source_roots(path, expressions, project) do
    with {:ok, elixir_paths} <- source_path_field(expressions, project, :elixirc_paths, ["lib"]),
         {:ok, erlang_paths} <- source_path_field(expressions, project, :erlc_paths, ["src"]),
         declared <- elixir_paths ++ erlang_paths,
         true <- length(declared) == length(Enum.uniq(declared)),
         {:ok, roots} <- canonical_source_roots(Path.dirname(path), declared) do
      {:ok, roots}
    else
      false -> {:error, "elixirc_paths and erlc_paths must not name one compile root twice"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp source_path_field(_expressions, project, name, default) do
    if Keyword.has_key?(project, name) do
      with paths <- Keyword.fetch!(project, name),
           true <- is_list(paths) and Enum.all?(paths, &is_binary/1),
           true <- length(paths) == length(Enum.uniq(paths)) do
        {:ok, paths}
      else
        _other -> {:error, "#{name} must be unique literal relative paths"}
      end
    else
      {:ok, default}
    end
  end

  defp canonical_source_roots(owner_root, declared) do
    owner = Path.expand(owner_root)

    declared
    |> Enum.reduce_while({:ok, []}, fn relative, {:ok, roots} ->
      expanded = Path.expand(relative, owner)

      cond do
        Path.type(relative) != :relative or relative in ["", "."] ->
          {:halt, {:error, "compile source roots must be nonempty relative paths"}}

        not inside_path?(expanded, owner) ->
          {:halt,
           {:error, "compile source root #{inspect(relative)} escapes its owning application"}}

        true ->
          case ordinary_directory_prefix?(owner, Path.split(relative)) do
            :ok -> {:cont, {:ok, [expanded | roots]}}
            {:error, reason} -> {:halt, {:error, reason}}
          end
      end
    end)
    |> case do
      {:ok, roots} -> {:ok, Enum.reverse(roots)}
      error -> error
    end
  end

  defp inside_path?(candidate, owner),
    do: candidate != owner and String.starts_with?(candidate <> "/", owner <> "/")

  defp ordinary_directory_prefix?(_prefix, []), do: :ok

  defp ordinary_directory_prefix?(prefix, [component | rest]) do
    path = Path.join(prefix, component)

    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} ->
        ordinary_directory_prefix?(path, rest)

      {:error, :enoent} ->
        :ok

      {:error, posix} ->
        {:error, "compile source root identity is unavailable (#{:file.format_error(posix)})"}

      _other ->
        {:error, "compile source roots must traverse only ordinary directories"}
    end
  end

  defp identity(path, relative, project, dependencies, source_roots) do
    cond do
      relative == "mix.exs" ->
        root_identity(path, project, dependencies, source_roots)

      is_binary(relative) and Regex.match?(~r/\Aapps\/[a-z][a-z0-9_]*\/mix\.exs\z/u, relative) ->
        child_identity(path, relative, project, dependencies, source_roots)

      true ->
        standalone_identity(path, project, dependencies, source_roots)
    end
  end

  defp root_identity(path, project, dependencies, source_roots) do
    cond do
      Keyword.get(project, :apps_path) != "apps" ->
        {:error, "umbrella root apps_path must be the literal path \"apps\""}

      Keyword.has_key?(project, :app) or Keyword.has_key?(project, :loopex_role) ->
        {:error, "umbrella root must not declare an application identity or role"}

      dependencies != [] ->
        {:error, "umbrella root must carry no dependency"}

      true ->
        {:ok,
         %{
           path: path,
           relative: "mix.exs",
           app: nil,
           role: nil,
           dependencies: dependencies,
           source_roots: source_roots
         }}
    end
  end

  defp child_identity(path, relative, project, dependencies, source_roots) do
    directory = relative |> Path.dirname() |> Path.basename()

    with application when is_atom(application) <- Keyword.get(project, :app),
         true <- Atom.to_string(application) == directory,
         role when role in @roles <- Keyword.get(project, :loopex_role),
         :ok <- fixed_role(application, role) do
      {:ok,
       %{
         path: path,
         relative: relative,
         app: application,
         role: role,
         dependencies: dependencies,
         source_roots: source_roots
       }}
    else
      nil -> {:error, "child project omits its literal application identity or loopex_role"}
      false -> {:error, "child application identity does not match its directory"}
      {:error, reason} -> {:error, reason}
      _other -> {:error, "child project has no valid literal loopex_role"}
    end
  end

  defp standalone_identity(path, project, dependencies, source_roots) do
    with application when is_atom(application) <- Keyword.get(project, :app),
         role when role in @roles <- inferred_or_declared_role(application, project),
         :ok <- fixed_role(application, role) do
      {:ok,
       %{
         path: path,
         relative: nil,
         app: application,
         role: role,
         dependencies: dependencies,
         source_roots: source_roots
       }}
    else
      nil -> {:error, "project omits its literal application identity or loopex_role"}
      {:error, reason} -> {:error, reason}
      _other -> {:error, "project has no valid literal loopex_role"}
    end
  end

  defp inferred_or_declared_role(@contract_app, project),
    do: Keyword.get(project, :loopex_role, :contract)

  defp inferred_or_declared_role(@runtime_app, project),
    do: Keyword.get(project, :loopex_role, :core)

  defp inferred_or_declared_role(_application, project), do: Keyword.get(project, :loopex_role)

  defp fixed_role(@contract_app, :contract), do: :ok
  defp fixed_role(@runtime_app, :core), do: :ok

  defp fixed_role(application, role) when application in [@contract_app, @runtime_app],
    do: {:error, "#{inspect(application)} cannot declare role #{inspect(role)}"}

  defp fixed_role(_application, _role), do: :ok

  defp records(root, paths) do
    Enum.reduce_while(paths, {:ok, []}, fn relative, {:ok, acc} ->
      case project_record(Path.join(root, relative), relative) do
        {:ok, record} -> {:cont, {:ok, [record | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp allowed_internal_closure(_by_app, [], seen), do: seen

  defp allowed_internal_closure(by_app, [application | rest], seen) do
    if MapSet.member?(seen, application) do
      allowed_internal_closure(by_app, rest, seen)
    else
      dependencies =
        by_app
        |> Map.fetch!(application)
        |> Map.fetch!(:dependencies)
        |> Enum.flat_map(fn {name, _requirement, options} ->
          if Map.has_key?(by_app, name) and in_umbrella?(options), do: [name], else: []
        end)

      allowed_internal_closure(by_app, rest ++ dependencies, MapSet.put(seen, application))
    end
  end

  defp duplicate_app_reasons(records) do
    duplicates =
      records
      |> Enum.reject(&is_nil(&1.app))
      |> Enum.group_by(& &1.app)
      |> Enum.filter(fn {_app, matches} -> length(matches) > 1 end)
      |> Enum.map(&elem(&1, 0))

    if duplicates == [],
      do: [],
      else: [
        "tracked applications declare duplicate identities #{inspect(Enum.sort(duplicates))}"
      ]
  end

  defp required_app_reasons(roles) do
    if roles[@contract_app] == :contract and roles[@runtime_app] == :core,
      do: [],
      else: ["the inventory must contain the protocol contract and loopex core applications"]
  end

  defp planned_inventory_reasons(records) do
    records
    |> Enum.reject(&is_nil(&1.app))
    |> Enum.flat_map(fn record ->
      case Map.fetch(@m1_planned_roles, record.app) do
        :error ->
          [
            "#{record.path}: application #{inspect(record.app)} is outside the exact M1 planned inventory"
          ]

        {:ok, expected_role} when record.role != expected_role ->
          [
            "#{record.path}: M1 application #{inspect(record.app)} must declare role " <>
              inspect(expected_role)
          ]

        {:ok, _expected_role} ->
          []
      end
    end)
  end

  defp m1_external_dependency_reasons(records, roles) do
    records
    |> Enum.reject(&is_nil(&1.app))
    |> Enum.flat_map(fn record ->
      external =
        Enum.reject(record.dependencies, fn {name, _requirement, options} ->
          Map.has_key?(roles, name) or in_umbrella?(options)
        end)

      case {record.app, external} do
        {:loopex_llm_reqllm, [{:req_llm, @reqllm_requirement, []}]} ->
          []

        {:loopex_llm_reqllm, found} ->
          [
            "#{record.path}: M1 ReqLLM edge must declare exactly external dependency " <>
              "{:req_llm, #{inspect(@reqllm_requirement)}}; found #{inspect(found)}"
          ]

        {_application, []} ->
          []

        {application, found} ->
          [
            "#{record.path}: M1 application #{inspect(application)} may not declare external " <>
              "dependencies; found #{inspect(found)}"
          ]
      end
    end)
  end

  defp repository_record_reasons(
         %{app: :loopex_llm_reqllm, role: :edge} = record,
         roles,
         false
       ) do
    legacy_reqllm_reasons(record, roles)
  end

  defp repository_record_reasons(record, roles, _complete_m1_inventory?),
    do: record_reasons(record, roles)

  defp legacy_reqllm_reasons(record, roles) do
    {known, unknown} = split_internal(record.dependencies, roles)

    cond do
      unknown != [] ->
        unknown_reasons(record, unknown)

      match?([{@contract_app, nil, _options}], known) and
          production_internal?(known |> List.first() |> elem(2)) ->
        []

      true ->
        [
          "#{record.path}: incomplete M1 ReqLLM edge must depend internally only on the " <>
            "production protocol application"
        ]
    end
  end

  defp external_lock_reasons(root, records, roles) do
    external =
      records
      |> Enum.flat_map(& &1.dependencies)
      |> Enum.reject(fn {name, _requirement, options} ->
        Map.has_key?(roles, name) or in_umbrella?(options)
      end)

    if external == [] do
      []
    else
      case literal_hex_lock(Path.join(root, "mix.lock")) do
        {:ok, locks} ->
          by_name = Map.new(locks, &{&1.name, &1})

          Enum.flat_map(external, fn {name, requirement, _options} ->
            lock = Map.get(by_name, Atom.to_string(name))

            with %{version: version} <- lock,
                 {:ok, parsed_version} <- Version.parse(version),
                 {:ok, parsed_requirement} <- Version.parse_requirement(requirement),
                 true <- Version.match?(parsed_version, parsed_requirement) do
              []
            else
              _other ->
                [
                  "external dependency #{inspect(name)} must match one same-name canonical " <>
                    "hexpm lock entry satisfying #{inspect(requirement)}"
                ]
            end
          end)

        {:error, reason} ->
          ["external dependency authority is unavailable: #{reason}"]
      end
    end
  end

  defp record_reasons(%{app: nil}, _roles), do: []
  defp record_reasons(%{role: :contract, dependencies: []}, _roles), do: []

  defp record_reasons(%{role: :contract} = record, _roles),
    do: ["#{record.path}: contract applications must carry no dependency"]

  defp record_reasons(%{role: :core} = record, roles),
    do: exact_protocol_dependency(record, roles, "core")

  defp record_reasons(%{role: :edge} = record, roles), do: edge_reasons(record, roles)
  defp record_reasons(%{role: :extension} = record, roles), do: extension_reasons(record, roles)

  defp record_reasons(%{role: :composition} = record, roles),
    do: composition_reasons(record, roles)

  defp record_reasons(%{role: :client} = record, roles), do: client_reasons(record, roles)

  defp record_reasons(record, _roles),
    do: ["#{record.path}: application has no valid dependency role"]

  defp exact_protocol_dependency(record, roles, label) do
    case record.dependencies do
      [{@contract_app, nil, options}] ->
        if target_role(roles, @contract_app) == :contract and production_internal?(options),
          do: [],
          else: [
            "#{record.path}: #{label} protocol dependency must be production and in-umbrella"
          ]

      _other ->
        [
          "#{record.path}: #{label} applications must depend only on the production protocol application; " <>
            "found #{inspect(names(record.dependencies))}"
        ]
    end
  end

  defp edge_reasons(record, roles) do
    {known, unknown} = split_internal(record.dependencies, roles)
    core = Enum.filter(known, &(elem(&1, 0) == @runtime_app))
    protocol = Enum.filter(known, &(elem(&1, 0) == @contract_app))
    forbidden = Enum.reject(known, &(elem(&1, 0) in [@runtime_app, @contract_app]))

    cond do
      unknown != [] ->
        unknown_reasons(record, unknown)

      not match?([{@runtime_app, nil, _options}], core) ->
        ["#{record.path}: edge applications require exactly one production loopex dependency"]

      length(protocol) > 1 or forbidden != [] ->
        ["#{record.path}: edge applications may depend internally only on core and protocol"]

      not Enum.all?(core ++ protocol, fn {_name, _requirement, options} ->
        production_internal?(options)
      end) ->
        ["#{record.path}: edge internal dependencies must be production and in-umbrella"]

      true ->
        []
    end
  end

  defp extension_reasons(record, roles) do
    {known, unknown} = split_internal(record.dependencies, roles)

    cond do
      unknown != [] ->
        unknown_reasons(record, unknown)

      length(known) != 1 or elem(List.first(known), 0) != @contract_app ->
        ["#{record.path}: extension applications must depend inward only on protocol"]

      not production_internal?(known |> List.first() |> elem(2)) ->
        ["#{record.path}: extension protocol dependency must be production and in-umbrella"]

      true ->
        []
    end
  end

  # Concept: a composition wires the reference stack and nothing else.
  #
  # Technical depth: it is the one production role permitted to declare a
  # dependency on the concrete edges it composes, which is exactly what an
  # `:edge` may not do and exactly what a `:client` may not be depended on for.
  # Inventing the role keeps both of those rules closed; widening either would
  # have applied to every application in that role forever rather than to the one
  # case that needs it. It carries no external dependency in any environment, and
  # depends on no client and on no other composition.
  defp composition_reasons(record, roles) do
    {known, unknown} = split_internal(record.dependencies, roles)
    core = Enum.filter(known, &(elem(&1, 0) == @runtime_app))
    other = known -- core

    external =
      Enum.reject(record.dependencies, fn {name, _requirement, options} ->
        Map.has_key?(roles, name) or in_umbrella?(options)
      end)

    cond do
      unknown != [] ->
        unknown_reasons(record, unknown)

      external != [] ->
        ["#{record.path}: composition applications may not carry external dependencies"]

      not match?([{@runtime_app, nil, _options}], core) ->
        ["#{record.path}: composition applications require one production loopex dependency"]

      not Enum.all?(other, fn {name, _requirement, options} ->
        target_role(roles, name) in [:edge, :contract] and production_internal?(options)
      end) ->
        [
          "#{record.path}: compositions may depend only on core, protocol, and the edges they compose"
        ]

      true ->
        []
    end
  end

  defp client_reasons(record, roles) do
    {known, unknown} = split_internal(record.dependencies, roles)
    core = Enum.filter(known, &(elem(&1, 0) == @runtime_app))
    compositions = Enum.filter(known, &(target_role(roles, elem(&1, 0)) == :composition))
    # The grouping is load-bearing. `--` is right-associative in Elixir, so
    # `known -- core -- compositions` reads as `known -- (core -- compositions)`
    # and leaves the composition in `other`, where the edge-only rule below then
    # rejects the very dependency this role exists to permit.
    other = (known -- core) -- compositions

    external =
      Enum.reject(record.dependencies, fn {name, _requirement, options} ->
        Map.has_key?(roles, name) or in_umbrella?(options)
      end)

    cond do
      unknown != [] ->
        unknown_reasons(record, unknown)

      external != [] ->
        ["#{record.path}: client applications may not carry external dependencies"]

      not match?([{@runtime_app, nil, _options}], core) or
          not Enum.all?(core, fn {_name, _requirement, options} ->
            production_internal?(options)
          end) ->
        ["#{record.path}: client applications require one production loopex dependency"]

      length(compositions) > 1 ->
        ["#{record.path}: clients may depend on at most one composition"]

      not Enum.all?(compositions, fn {_name, _requirement, options} ->
        production_internal?(options)
      end) ->
        ["#{record.path}: a client's composition dependency must be production and in-umbrella"]

      not Enum.all?(other, fn {name, _requirement, options} ->
        target_role(roles, name) == :edge and test_only_internal?(options)
      end) ->
        ["#{record.path}: clients may compose only edge applications and only in tests"]

      true ->
        []
    end
  end

  defp unknown_reasons(record, unknown) do
    [
      "#{record.path}: unknown in-umbrella dependencies are forbidden: " <>
        inspect(names(unknown))
    ]
  end

  defp split_internal(dependencies, roles) do
    Enum.split_with(dependencies, fn {name, _requirement, _options} ->
      Map.has_key?(roles, name)
    end)
    |> then(fn {known, not_known} ->
      unknown =
        Enum.filter(not_known, fn {_name, _requirement, options} -> in_umbrella?(options) end)

      {known, unknown}
    end)
  end

  defp standalone_roles(record) do
    %{
      @contract_app => :contract,
      @runtime_app => :core,
      record.app => record.role
    }
  end

  defp target_role(roles, name), do: Map.get(roles, name)
  defp names(dependencies), do: Enum.map(dependencies, &elem(&1, 0))
  defp in_umbrella?(options), do: Keyword.get(options, :in_umbrella) == true

  defp production_internal?(options),
    do: Map.new(options) == %{in_umbrella: true}

  defp test_only_internal?(options) do
    case Map.new(options) do
      %{in_umbrella: true, only: only} when only in [:test, [:test]] -> true
      _other -> false
    end
  end

  defp unique_names?(dependencies),
    do: dependencies |> names() |> Enum.uniq() |> length() == length(dependencies)

  defp unique_keyword(keyword, label) do
    if unique_keyword?(keyword), do: :ok, else: {:error, "#{label} has duplicate keys"}
  end

  defp unique_keyword?(keyword),
    do: keyword |> Keyword.keys() |> Enum.uniq() |> length() == length(keyword)

  defp contract_source_roots(records) do
    records
    |> Enum.filter(&(&1.role == :contract))
    |> Enum.flat_map(& &1.source_roots)
    |> Enum.uniq()
  end

  defp source_root_reasons(_repository_root, %{app: nil} = record) do
    existing =
      Enum.filter(record.source_roots, &(File.exists?(&1) or File.exists?(Path.dirname(&1))))

    Enum.flat_map(existing, fn source_root ->
      case File.lstat(source_root) do
        {:error, :enoent} ->
          []

        {:ok, _stat} ->
          ["#{record.path}: the umbrella root may not own application source #{source_root}"]

        {:error, posix} ->
          ["#{record.path}: source-root evidence is unavailable (#{:file.format_error(posix)})"]
      end
    end)
  end

  defp source_root_reasons(repository_root, record) do
    Enum.flat_map(record.source_roots, &source_tree_reasons(repository_root, record.path, &1))
  end

  defp source_tree_reasons(repository_root, project, path) do
    case File.lstat(path) do
      {:error, :enoent} ->
        []

      {:ok, %File.Stat{type: :directory}} ->
        case File.ls(path) do
          {:ok, entries} ->
            entries
            |> Enum.sort()
            |> Enum.flat_map(&source_tree_reasons(repository_root, project, Path.join(path, &1)))

          {:error, posix} ->
            ["#{project}: compile source inventory is unavailable (#{:file.format_error(posix)})"]
        end

      {:ok, %File.Stat{type: :regular}} ->
        if executable_source?(path) and not tracked_ordinary_source?(repository_root, path),
          do: ["#{project}: compile source #{path} is not one tracked ordinary 100644 blob"],
          else: []

      {:ok, _stat} ->
        ["#{project}: compile source roots may contain only ordinary directories and files"]

      {:error, posix} ->
        ["#{project}: compile source identity is unavailable (#{:file.format_error(posix)})"]
    end
  end

  defp executable_source?(path),
    do: Path.extname(path) in [".ex", ".exs", ".erl", ".xrl", ".yrl", ".hrl"]

  defp tracked_ordinary_source?(repository_root, path) do
    relative = Path.relative_to(path, repository_root)

    case System.cmd(
           "git",
           ["-C", repository_root, "ls-files", "--stage", "-z", "--", relative],
           stderr_to_stdout: true
         ) do
      {output, 0} when output != "" and is_binary(output) ->
        entry = String.trim_trailing(output, <<0>>)

        case String.split(entry, [" ", "\t"], parts: 4) do
          ["100644", object, "0", ^relative] when byte_size(object) in 40..64 ->
            String.match?(object, ~r/\A[0-9a-f]+\z/)

          _other ->
            false
        end

      _other ->
        false
    end
  rescue
    _exception -> false
  end

  defp tracked_projects(root) do
    args = ["-C", root, "ls-files", "--stage", "-z", "--", "mix.exs", "apps/*/mix.exs"]

    case System.cmd("git", args, stderr_to_stdout: true) do
      {output, 0} when output != "" and is_binary(output) ->
        with {:ok, tracked} <- tracked_entries(root, output),
             {:ok, physical} <- physical_projects(root),
             true <- physical == tracked do
          {:ok, tracked}
        else
          false ->
            {:error, "the physical project inventory differs from tracked canonical projects"}

          {:error, reason} ->
            {:error, reason}
        end

      _other ->
        {:error, "the tracked project inventory is unavailable"}
    end
  rescue
    _exception -> {:error, "the tracked project inventory is unavailable"}
  end

  defp physical_projects(root) do
    apps_root = Path.join(root, "apps")

    with {:ok, %File.Stat{type: :directory}} <- File.lstat(apps_root),
         {:ok, children} <- File.ls(apps_root) do
      children
      |> Enum.sort()
      |> Enum.reduce_while({:ok, ["mix.exs"]}, fn child, {:ok, projects} ->
        relative = "apps/#{child}/mix.exs"
        path = Path.join(root, relative)

        case File.lstat(path) do
          {:error, :enoent} ->
            {:cont, {:ok, projects}}

          {:ok, %File.Stat{type: :regular}} ->
            if canonical_project_path?(relative) and ordinary_project_file?(root, relative),
              do: {:cont, {:ok, [relative | projects]}},
              else:
                {:halt, {:error, "#{relative}: physical project is not canonical and ordinary"}}

          {:ok, _stat} ->
            {:halt, {:error, "#{relative}: physical project is not canonical and ordinary"}}

          {:error, posix} ->
            {:halt,
             {:error,
              "the physical project inventory is unavailable (#{:file.format_error(posix)})"}}
        end
      end)
      |> case do
        {:ok, projects} -> {:ok, Enum.sort(projects)}
        error -> error
      end
    else
      {:error, :enoent} ->
        {:error, "the physical apps directory is missing"}

      {:ok, _stat} ->
        {:error, "the physical apps directory is not ordinary"}

      {:error, posix} ->
        {:error, "the physical project inventory is unavailable (#{:file.format_error(posix)})"}
    end
  end

  defp tracked_entries(root, output) do
    if String.ends_with?(output, <<0>>) do
      output
      |> String.trim_trailing(<<0>>)
      |> String.split(<<0>>, trim: true)
      |> Enum.reduce_while({:ok, []}, fn entry, {:ok, paths} ->
        case String.split(entry, [" ", "\t"], parts: 4) do
          ["100644", object, "0", path] when byte_size(object) in 40..64 ->
            if canonical_project_path?(path) and ordinary_project_file?(root, path) do
              {:cont, {:ok, [path | paths]}}
            else
              {:halt, {:error, "#{path}: tracked project is not one ordinary canonical file"}}
            end

          _other ->
            {:halt, {:error, "the tracked project inventory is malformed"}}
        end
      end)
      |> case do
        {:ok, paths} ->
          paths = Enum.sort(paths)

          if "mix.exs" in paths,
            do: {:ok, paths},
            else: {:error, "the tracked umbrella root mix.exs is missing"}

        error ->
          error
      end
    else
      {:error, "the tracked project inventory is malformed"}
    end
  end

  defp canonical_project_path?("mix.exs"), do: true

  defp canonical_project_path?(path),
    do: Regex.match?(~r/\Aapps\/[a-z][a-z0-9_]*\/mix\.exs\z/u, path)

  defp ordinary_project_file?(root, relative) do
    components = Path.split(relative)
    last = length(components) - 1

    case File.lstat(root) do
      {:ok, %File.Stat{type: :directory}} ->
        components
        |> Enum.with_index()
        |> Enum.reduce_while(root, fn {component, index}, prefix ->
          path = Path.join(prefix, component)
          expected = if index == last, do: :regular, else: :directory

          case File.lstat(path) do
            {:ok, %File.Stat{type: ^expected}} -> {:cont, path}
            _other -> {:halt, :error}
          end
        end)
        |> then(&(&1 != :error))

      _other ->
        false
    end
  end

  defp canonical_supplied_inventory(projects) do
    supplied = if "mix.exs" in projects, do: projects, else: ["mix.exs" | projects]

    if length(supplied) == length(Enum.uniq(supplied)) and
         Enum.all?(supplied, &canonical_project_path?/1),
       do: {:ok, Enum.sort(supplied)},
       else: {:error, "the supplied project inventory is incomplete, duplicated, or unordered"}
  end

  defp relative_from_path(path) do
    normalized = Path.split(Path.expand(path))

    case Enum.take(normalized, -3) do
      ["apps", directory, "mix.exs"] -> "apps/#{directory}/mix.exs"
      _other -> nil
    end
  end

  defp prefix(path, reason) do
    if String.starts_with?(reason, path <> ":"), do: reason, else: "#{path}: #{reason}"
  end

  defp done([]), do: :ok
  defp done(reasons), do: {:error, reasons}

  # Concept: the contract owns the Loopex.Protocol namespace but may not point
  # outward to runtime modules or perform computed module dispatch.
  defp reverse_edge_reasons(lib_roots) do
    lib_roots
    |> Enum.flat_map(&sources/1)
    |> Enum.uniq()
    |> Enum.flat_map(&reverse_edges_in/1)
  end

  defp sources(root) do
    if File.dir?(root) do
      root
      |> Path.join("**/*")
      |> Path.wildcard()
      |> Enum.filter(&(Path.extname(&1) in [".ex", ".exs", ".erl", ".xrl", ".yrl", ".hrl"]))
    else
      []
    end
  end

  defp reverse_edges_in(file) do
    if Path.extname(file) in [".erl", ".xrl", ".yrl", ".hrl"] do
      ["#{file}: contract compile roots are Elixir-only; Erlang-family sources are refused"]
    else
      case File.read(file) do
        {:error, posix} ->
          ["#{file}: could not be read (#{:file.format_error(posix)}); evidence is unavailable"]

        {:ok, source} ->
          case Code.string_to_quoted(source) do
            {:error, _reason} -> ["#{file}: could not be parsed; evidence is unavailable"]
            {:ok, ast} -> static_edges(file, ast) ++ dynamic_dispatches(file, ast)
          end
      end
    end
  end

  defp static_edges(file, ast) do
    {_ast, found} =
      Macro.prewalk(ast, [], fn
        {:__aliases__, _meta, _segments} = node, acc ->
          case runtime_module_name(node) do
            {:runtime, name} -> {node, [name | acc]}
            _other -> {node, acc}
          end

        atom, acc when is_atom(atom) ->
          case runtime_module_name(atom) do
            {:runtime, name} -> {atom, [name | acc]}
            _other -> {atom, acc}
          end

        node, acc ->
          {node, acc}
      end)

    found
    |> Enum.uniq()
    |> Enum.map(fn name ->
      "#{file}: the contract application references the runtime module #{name}"
    end)
  end

  defp dynamic_dispatches(file, ast) do
    {_ast, found} =
      Macro.prewalk(ast, [], fn
        {:apply, meta, [_module, _function, _arguments]} = node, acc ->
          {node, [meta[:line] || 0 | acc]}

        {{:., _dot_meta, [module, :apply]}, meta, [_target, _function, _arguments]} = node, acc ->
          if explicit_apply_module?(module),
            do: {node, [meta[:line] || 0 | acc]},
            else: dynamic_remote_call(node, module, meta, acc)

        {{:., _dot_meta, [module, :capture]}, meta, [_target, _function, _arity]} = node, acc ->
          if module_name(module) == "Elixir.Function",
            do: {node, [meta[:line] || 0 | acc]},
            else: dynamic_remote_call(node, module, meta, acc)

        {{:., _dot_meta, [module, :make_fun]}, meta, [_target, _function, _arity]} = node, acc ->
          if module == :erlang,
            do: {node, [meta[:line] || 0 | acc]},
            else: dynamic_remote_call(node, module, meta, acc)

        {:&, meta,
         [
           {:/, _slash_meta, [{{:., _dot_meta, [module, _function]}, _call_meta, []}, arity]}
         ]} = node,
        acc
        when is_integer(arity) ->
          if static_module_expression?(module),
            do: {node, acc},
            else: {node, [meta[:line] || 0 | acc]}

        {{:., _dot_meta, [module, _function]}, meta, arguments} = node, acc ->
          if static_module_expression?(module) or
               (arguments == [] and Keyword.get(meta, :no_parens) == true),
             do: {node, acc},
             else: {node, [meta[:line] || 0 | acc]}

        node, acc ->
          {node, acc}
      end)

    found
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map(fn line ->
      "#{file}:#{line}: the contract application performs dynamic module dispatch"
    end)
  end

  defp static_module_expression?({:__aliases__, _meta, _segments}), do: true
  defp static_module_expression?({:__MODULE__, _meta, _context}), do: true
  defp static_module_expression?(module) when is_atom(module), do: true
  defp static_module_expression?(_other), do: false

  defp dynamic_remote_call(node, module, meta, acc) do
    if static_module_expression?(module),
      do: {node, acc},
      else: {node, [meta[:line] || 0 | acc]}
  end

  defp explicit_apply_module?(module),
    do: module == :erlang or module_name(module) == "Elixir.Kernel"

  defp runtime_module_name(module) do
    case module_name(module) do
      "Elixir.Loopex.Protocol" <> rest when rest == "" or binary_part(rest, 0, 1) == "." ->
        :protocol

      "Elixir.Loopex" <> rest when rest == "" or binary_part(rest, 0, 1) == "." ->
        {:runtime, "Loopex" <> rest}

      _other ->
        :other
    end
  end

  defp module_name({:__aliases__, _meta, segments}) do
    normalized =
      case segments do
        [Elixir | rest] -> rest
        rest -> rest
      end

    "Elixir." <> Enum.map_join(normalized, ".", &Atom.to_string/1)
  end

  defp module_name(module) when is_atom(module), do: Atom.to_string(module)
  defp module_name(_module), do: nil
end

defmodule Mix.Tasks.Loopex.DepsBudget do
  @shortdoc "Enforces the dependency budget and one-way direction between applications"

  @moduledoc """
  ## Concept

  Exposes the repository dependency check as a Mix task.

  ## Technical depth

  Parsing and policy live in `Loopex.Checks.DepsBudget`, which is also callable
  directly before Mix loads any project or dispatches any alias. This task is a
  thin reporting wrapper and retains the M0 testing API by delegation.
  """

  use Mix.Task

  alias Loopex.Checks.DepsBudget

  @impl Mix.Task
  def run([]), do: report(DepsBudget.check_repository(File.cwd!()))

  def run(["--inventory" | paths]) when paths != [],
    do: report(DepsBudget.check_inventory(File.cwd!(), paths))

  def run([path]), do: report(DepsBudget.check_mix_exs(path))

  def run(other) do
    Mix.raise(
      "usage: mix loopex.deps_budget [path/to/mix.exs] | --inventory apps/*/mix.exs, got #{inspect(other)}"
    )
  end

  def check_repository(root), do: DepsBudget.check_repository(root)
  def check_inventory(root, paths), do: DepsBudget.check_inventory(root, paths)
  def check_mix_exs(path), do: DepsBudget.check_mix_exs(path)
  def reverse_edge_check(root), do: DepsBudget.reverse_edge_check(root)

  defp report(:ok), do: Mix.shell().info("dependency budget and direction hold")

  defp report({:error, reasons}) do
    Mix.raise("dependency budget violated:\n  " <> Enum.join(reasons, "\n  "))
  end
end
