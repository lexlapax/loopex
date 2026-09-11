defmodule LoopexComposition.ResourcePacks do
  @moduledoc """
  ## Concept

  Discovers and imports the one supported resource class: project skills beneath
  `.agents/skills`. Installation makes a pack inspectable. It does not trust,
  select, or execute any of the installed content.

  ## Technical depth

  Local discovery walks one fixed directory without following links. Git import
  runs explicit argv jobs through the existing local executor, verifies the
  requested commit and selected tree, then publishes a verified directory with
  one rename. Retention stores canonical manifests and remote provenance under
  content identities. Core owns manifest and pack identity through
  `Loopex.ResourcePack`; this host never recreates those rules.
  """

  alias Loopex.Executor
  alias Loopex.Executor.Local
  alias Loopex.Executor.Local.WorkspaceLease
  alias LoopexProtocol.Canonical

  @version "loopex.resource_pack/1"
  @max_files 64
  @max_pack_bytes 1_048_576
  @max_text_bytes 65_536
  @max_detail_bytes 1_024
  @max_deadline_ms 30_000
  @git_oid ~r/\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z/
  @skill_name ~r/\A[a-z0-9]+(?:-[a-z0-9]+)*\z/
  @frontmatter_keys ~w(name description license compatibility metadata disable-model-invocation)
  @git_environment [
    "GIT_CONFIG_NOSYSTEM=1",
    "GIT_CONFIG_GLOBAL=/dev/null",
    "GIT_TERMINAL_PROMPT=0"
  ]
  @git_config [
    "-c",
    "core.hooksPath=/dev/null",
    "-c",
    "core.attributesFile=/dev/null",
    "-c",
    "filter.lfs.smudge=",
    "-c",
    "filter.lfs.process=",
    "-c",
    "filter.lfs.required=false",
    "-c",
    "protocol.file.allow=always"
  ]

  @type refusal :: {:error, {atom(), binary()}}

  @doc """
  ## Concept

  Reads every project skill from the fixed workspace directory.

  ## Technical depth

  `:workspace_ref` is required. When `:state_root` is present, exact retained
  provenance is reattached only if the current file labels and digests match.
  """
  @spec discover(binary(), keyword()) :: {:ok, map()} | refusal()
  def discover(workspace, options) when is_binary(workspace) and is_list(options) do
    with {:ok, workspace_ref} <- required_binary(options, :workspace_ref),
         {:ok, root} <- canonical_workspace(workspace),
         {:ok, packs} <- discover_packs(root, Keyword.get(options, :state_root)),
         manifest = %{
           "version" => @version,
           "workspace_ref" => workspace_ref,
           "revision" => nil,
           "packs" => packs
         },
         {:ok, _digest, normalized} <- core_digest(manifest) do
      {:ok, normalized}
    end
  end

  def discover(_workspace, _options),
    do: error(:invalid_options, "workspace and options are required")

  @doc """
  ## Concept

  Imports one selected Git directory at one exact commit into project skills.

  ## Technical depth

  The caller must provide the Git executable, revision, selected path, state
  root, workspace identity, and the explicit host-policy allow decision. Git
  runs with no ambient configuration or credential prompt. The installed
  directory is published only after the complete pack passes validation.
  """
  @spec add(binary(), binary(), keyword()) :: {:ok, map()} | refusal()
  def add(workspace, source, options)
      when is_binary(workspace) and is_binary(source) and is_list(options) do
    with {:ok, config} <- import_config(workspace, source, options),
         do: run_import(config)
  end

  def add(_workspace, _source, _options),
    do: error(:invalid_options, "workspace, source, and options are required")

  defp run_import(config) do
    caller = self()
    tag = make_ref()

    {owner, monitor} =
      spawn_monitor(fn ->
        coordinate_import(caller, tag, config)
      end)

    receive do
      {^tag, result} ->
        Process.demonitor(monitor, [:flush])
        result

      {:DOWN, ^monitor, :process, ^owner, reason} ->
        error(:executor_failed, inspect(reason))
    end
  end

  defp coordinate_import(caller, tag, config) do
    Process.flag(:trap_exit, true)
    caller_monitor = Process.monitor(caller)

    result =
      with {:ok, staging_root} <- create_staging_root(config.workspace) do
        try do
          with {:ok, context} <- open_import_executor(config) do
            coordinate_import_worker(caller, caller_monitor, tag, context, config, staging_root)
          end
        after
          File.rm_rf(staging_root)
        end
      end

    if result != :caller_down do
      Process.demonitor(caller_monitor, [:flush])
      send(caller, {tag, result})
    end
  end

  defp coordinate_import_worker(caller, caller_monitor, tag, context, config, staging_root) do
    coordinator = self()

    {worker, worker_monitor} =
      spawn_monitor(fn ->
        worker_config = Map.put(config, :import_observer, {coordinator, tag})
        send(coordinator, {tag, import_with_executor(context, worker_config, staging_root)})
      end)

    await_import_worker(caller, caller_monitor, tag, context, config, worker, worker_monitor, nil)
  end

  # Concept: caller death or the acquisition deadline wins once its observation
  # reaches this coordinator. A validated staged tree is still provisional.
  #
  # Technical depth: only this coordinator retains provenance and publishes the
  # directory. It first observes worker termination and closes the executor, then
  # checks the caller monitor and deadline before retention and again before the
  # atomic rename. That last check is the cancellation-versus-publication tie.
  defp await_import_worker(
         caller,
         caller_monitor,
         tag,
         context,
         config,
         worker,
         worker_monitor,
         current_job
       ) do
    receive do
      {^tag, :job_started, job_id} ->
        await_import_worker(
          caller,
          caller_monitor,
          tag,
          context,
          config,
          worker,
          worker_monitor,
          job_id
        )

      {^tag, {:ok, pack, selected}} ->
        await_worker_down(worker, worker_monitor)
        close_import_executor(context)

        receive do
          {:DOWN, ^caller_monitor, :process, ^caller, _reason} -> :caller_down
        after
          0 -> finalize_import(pack, selected, config, caller, caller_monitor)
        end

      {^tag, result} ->
        await_worker_down(worker, worker_monitor)
        close_import_executor(context)
        result

      {:DOWN, ^caller_monitor, :process, ^caller, _reason} ->
        cancel_import_worker(context, worker, worker_monitor, current_job, config.deadline)
        :caller_down

      {:DOWN, ^worker_monitor, :process, ^worker, reason} ->
        close_import_executor(context)
        error(:executor_failed, inspect(reason))
    after
      remaining_ms(config.deadline) ->
        cancel_import_worker(context, worker, worker_monitor, current_job, config.deadline)
        error(:git_failed, "resource import deadline reached")
    end
  end

  defp cancel_import_worker(context, worker, worker_monitor, current_job, deadline) do
    cancellation =
      if is_binary(current_job),
        do: Local.cancel(context.executor, current_job),
        else: {:ok, :unconfirmed}

    case cancellation do
      {:ok, :cleaned} ->
        case await_worker_down(worker, worker_monitor, deadline) do
          :ok ->
            :ok

          :timeout ->
            Process.exit(worker, :kill)
            await_worker_down(worker, worker_monitor)
        end

      _unconfirmed ->
        Process.exit(worker, :kill)
        await_worker_down(worker, worker_monitor)
    end

    close_import_executor(context)
  end

  defp await_worker_down(worker, monitor) do
    receive do
      {:DOWN, ^monitor, :process, ^worker, _reason} -> :ok
    end
  end

  defp await_worker_down(worker, monitor, deadline) do
    receive do
      {:DOWN, ^monitor, :process, ^worker, _reason} -> :ok
    after
      remaining_ms(deadline) -> :timeout
    end
  end

  @doc """
  ## Concept

  Retains one complete verified snapshot and answers with its manifest identity.

  ## Technical depth

  Publication uses a sibling exclusive temporary file, sync, and atomic link. Existing content
  must decode to the same canonical manifest. Each imported pack also retains a
  provenance record keyed only by its sorted file label and digest pairs.
  """
  @spec retain(map(), binary()) :: {:ok, binary()} | refusal()
  def retain(manifest, state_root) when is_map(manifest) and is_binary(state_root) do
    with {:ok, digest, normalized} <- core_digest(manifest),
         :ok <- retain_provenance(normalized["packs"], state_root),
         :ok <-
           atomic_term(
             Path.join([retention_root(state_root), "manifests", digest <> ".etf"]),
             normalized
           ) do
      {:ok, digest}
    end
  end

  def retain(_manifest, _state_root),
    do: error(:invalid_options, "manifest and state root are required")

  @doc """
  ## Concept

  Loads the exact retained snapshot named by a manifest digest.

  ## Technical depth

  The retained term is decoded in safe mode and revalidated through core. A
  filename never supplies identity by itself.
  """
  @spec load(binary(), binary()) :: {:ok, map()} | refusal()
  def load(state_root, digest) when is_binary(state_root) and is_binary(digest) do
    path = Path.join([retention_root(state_root), "manifests", digest <> ".etf"])

    with true <- Regex.match?(~r/\A[0-9a-f]{64}\z/, digest),
         {:ok, bytes} <- read_file(path, :retained_manifest_missing),
         {:ok, manifest} <- decode_term(bytes),
         {:ok, ^digest, normalized} <- core_digest(manifest) do
      {:ok, normalized}
    else
      false ->
        error(:invalid_manifest_digest, "manifest digest must be lowercase SHA-256")

      {:ok, _other, _manifest} ->
        error(:retained_manifest_mismatch, "retained manifest identity changed")

      {:error, {_reason, _detail}} = refusal ->
        refusal
    end
  end

  def load(_state_root, _digest),
    do: error(:invalid_options, "state root and digest are required")

  @doc false
  def validate_launch_option(options) do
    case Keyword.fetch(options, :resource_manifest) do
      :error ->
        :ok

      {:ok, nil} ->
        :ok

      {:ok, manifest} when is_map(manifest) ->
        case Loopex.ResourcePack.digest(manifest) do
          {:ok, _digest, _normalized} ->
            :ok

          {:error, _reason, _detail} ->
            {:error, {:invalid_composition_option, :resource_manifest}}
        end

      {:ok, _invalid} ->
        {:error, {:invalid_composition_option, :resource_manifest}}
    end
  end

  @doc false
  def retain_launch_option(options, state_root) do
    case Keyword.fetch(options, :resource_manifest) do
      :error ->
        {:ok, options}

      {:ok, nil} ->
        {:ok, options}

      {:ok, manifest} ->
        with {:ok, _digest} <- retain(manifest, state_root),
             {:ok, _digest, normalized} <- Loopex.ResourcePack.digest(manifest) do
          {:ok, Keyword.put(options, :resource_manifest, normalized)}
        end
    end
  end

  defp discover_packs(workspace, state_root) do
    root = Path.join([workspace, ".agents", "skills"])

    case File.ls(root) do
      {:ok, names} ->
        names
        |> Enum.sort()
        |> Enum.reduce_while({:ok, []}, fn name, {:ok, packs} ->
          path = Path.join(root, name)

          case File.lstat(path) do
            {:ok, %File.Stat{type: :directory}} ->
              case read_pack(path, name, local_identity(name)) do
                {:ok, pack} -> {:cont, {:ok, packs ++ [reattach_provenance(pack, state_root)]}}
                {:error, _reason} = refusal -> {:halt, refusal}
              end

            {:ok, _other} ->
              {:cont, {:ok, packs}}

            {:error, reason} ->
              {:halt, error(:discovery_failed, inspect(reason))}
          end
        end)

      {:error, :enoent} ->
        {:ok, []}

      {:error, reason} ->
        error(:discovery_failed, inspect(reason))
    end
  end

  defp read_pack(root, directory_name, identity) do
    with :ok <- validate_skill_name(directory_name),
         {:ok, paths} <- regular_files(root),
         true <- "SKILL.md" in paths,
         {:ok, files} <- read_files(root, paths),
         {:ok, metadata} <- parse_skill(frontmatter_file(files)),
         :ok <- require_matching_name(metadata, directory_name),
         pack =
           Map.merge(identity, %{
             "name" => metadata["name"],
             "description" => metadata["description"],
             "manual_only" => metadata["disable-model-invocation"] == true,
             "files" => files
           }),
         {:ok, _digest} <- core_pack_digest(pack) do
      {:ok, pack}
    else
      false -> error(:skill_manifest_missing, "SKILL.md is required")
      {:error, {_reason, _detail}} = refusal -> refusal
      {:error, reason} -> error(:invalid_pack, inspect(reason))
    end
  end

  defp regular_files(_root, _path, _files, count, _bytes) when count > @max_files,
    do: error(:pack_file_limit, "a pack may contain at most #{@max_files} files")

  defp regular_files(_root, _path, _files, _count, bytes) when bytes > @max_pack_bytes,
    do: error(:pack_byte_limit, "a pack may contain at most #{@max_pack_bytes} bytes")

  defp regular_files(root, path, files, count, bytes) do
    with {:ok, entries} <- File.ls(path) do
      entries
      |> Enum.sort()
      |> Enum.reduce_while({:ok, files, count, bytes}, fn entry, {:ok, acc, n, total} ->
        full = Path.join(path, entry)

        case File.lstat(full) do
          {:ok, %File.Stat{type: :directory}} ->
            case regular_files(root, full, acc, n, total) do
              {:ok, nested, nested_count, nested_bytes} ->
                {:cont, {:ok, nested, nested_count, nested_bytes}}

              {:error, _reason} = refusal ->
                {:halt, refusal}
            end

          {:ok, %File.Stat{type: :regular, size: size}} ->
            next_count = n + 1
            next_bytes = total + size

            cond do
              next_count > @max_files ->
                {:halt, error(:pack_file_limit, "too many files")}

              next_bytes > @max_pack_bytes ->
                {:halt, error(:pack_byte_limit, "pack is too large")}

              true ->
                {:cont, {:ok, acc ++ [Path.relative_to(full, root)], next_count, next_bytes}}
            end

          {:ok, %File.Stat{type: type}} ->
            {:halt, error(:unsupported_file, "#{Path.relative_to(full, root)} is #{type}")}

          {:error, reason} ->
            {:halt, error(:discovery_failed, inspect(reason))}
        end
      end)
      |> case do
        {:ok, found, found_count, found_bytes} -> {:ok, found, found_count, found_bytes}
        refusal -> refusal
      end
    else
      {:error, reason} -> error(:discovery_failed, inspect(reason))
    end
  end

  defp regular_files(root) do
    case regular_files(root, root, [], 0, 0) do
      {:ok, paths, _count, _bytes} -> {:ok, paths}
      refusal -> refusal
    end
  end

  defp read_files(root, paths) do
    Enum.reduce_while(paths, {:ok, []}, fn label, {:ok, files} ->
      path = Path.join(root, label)

      case File.read(path) do
        {:ok, content} ->
          file = %{
            "label" => label,
            "size" => byte_size(content),
            "digest" => Canonical.digest_bytes(content),
            "content" => content,
            "contained" => true
          }

          {:cont, {:ok, files ++ [file]}}

        {:error, reason} ->
          {:halt, error(:discovery_failed, inspect(reason))}
      end
    end)
  end

  defp frontmatter_file(files),
    do: Enum.find_value(files, &if(&1["label"] == "SKILL.md", do: &1["content"]))

  # The supported YAML subset is deliberately small. It accepts plain/quoted
  # strings, true/false, block strings, and one string-valued metadata map.
  defp parse_skill(content) when is_binary(content) and byte_size(content) <= @max_text_bytes do
    case String.split(content, "\n") do
      ["---" | lines] -> parse_frontmatter(lines, %{}, nil)
      _other -> error(:invalid_frontmatter, "SKILL.md must start with bounded frontmatter")
    end
  end

  defp parse_skill(_content), do: error(:skill_text_limit, "SKILL.md exceeds 65536 bytes")

  defp parse_frontmatter([], _metadata, _state),
    do: error(:invalid_frontmatter, "frontmatter is not closed")

  defp parse_frontmatter(["---" | _body], metadata, nil), do: validate_metadata(metadata)

  defp parse_frontmatter([line | rest], metadata, {:block, key, style, indent, acc}) do
    current_indent = byte_size(line) - byte_size(String.trim_leading(line))

    if String.trim(line) == "" or current_indent >= indent do
      value =
        if String.trim(line) == "",
          do: "",
          else:
            binary_part(
              line,
              min(indent, byte_size(line)),
              byte_size(line) - min(indent, byte_size(line))
            )

      parse_frontmatter(rest, metadata, {:block, key, style, indent, acc ++ [value]})
    else
      joined = if style == "|", do: Enum.join(acc, "\n"), else: Enum.join(acc, " ")
      parse_frontmatter([line | rest], Map.put(metadata, key, joined), nil)
    end
  end

  defp parse_frontmatter([line | rest], metadata, {:metadata, values}) do
    cond do
      String.trim(line) == "" ->
        parse_frontmatter(rest, metadata, {:metadata, values})

      String.starts_with?(line, "  ") ->
        with {:ok, key, value} <- parse_pair(String.trim_leading(line)),
             false <- Map.has_key?(values, key) do
          parse_frontmatter(rest, metadata, {:metadata, Map.put(values, key, value)})
        else
          true -> error(:invalid_frontmatter, "duplicate metadata key")
          {:error, {_reason, _detail}} = refusal -> refusal
        end

      true ->
        parse_frontmatter([line | rest], Map.put(metadata, "metadata", values), nil)
    end
  end

  defp parse_frontmatter([line | rest], metadata, nil) do
    with {:ok, key, value} <- parse_pair(line),
         true <- key in @frontmatter_keys,
         false <- Map.has_key?(metadata, key) do
      case {key, value} do
        {"metadata", ""} ->
          parse_frontmatter(rest, metadata, {:metadata, %{}})

        {_key, style} when style in ["|", ">"] ->
          parse_frontmatter(rest, metadata, {:block, key, style, 2, []})

        _other ->
          parse_frontmatter(rest, Map.put(metadata, key, value), nil)
      end
    else
      false -> error(:unsupported_frontmatter, "unsupported or duplicate frontmatter field")
      {:error, {_reason, _detail}} = refusal -> refusal
    end
  end

  defp parse_pair(line) do
    case String.split(line, ":", parts: 2) do
      [key, value] when key != "" -> {:ok, String.trim(key), scalar(String.trim(value))}
      _other -> error(:invalid_frontmatter, "frontmatter entries must be key-value pairs")
    end
  end

  defp scalar("true"), do: true
  defp scalar("false"), do: false

  defp scalar(<<quote, rest::binary>>) when quote in [?\", ?'] do
    if String.ends_with?(rest, <<quote>>),
      do: binary_part(rest, 0, byte_size(rest) - 1),
      else: rest
  end

  defp scalar(value), do: value

  defp validate_metadata(%{"name" => name, "description" => description} = metadata)
       when is_binary(name) and is_binary(description) do
    with :ok <- validate_skill_name(name),
         true <- byte_size(description) in 1..1_024,
         true <- String.valid?(description),
         true <- valid_metadata_map?(Map.get(metadata, "metadata", %{})),
         true <- Map.get(metadata, "disable-model-invocation", false) in [true, false] do
      {:ok, metadata}
    else
      _other ->
        error(
          :invalid_frontmatter,
          "name, description, or metadata is outside the supported subset"
        )
    end
  end

  defp validate_metadata(_metadata),
    do: error(:invalid_frontmatter, "name and description are required")

  defp valid_metadata_map?(map) when is_map(map),
    do:
      map_size(map) <= 64 and
        Enum.all?(map, fn {key, value} -> is_binary(key) and is_binary(value) end)

  defp valid_metadata_map?(_map), do: false

  defp validate_skill_name(name) when is_binary(name) do
    if String.length(name) in 1..64 and Regex.match?(@skill_name, name),
      do: :ok,
      else: error(:invalid_skill_name, "skill name must match the project skill grammar")
  end

  defp validate_skill_name(_name), do: error(:invalid_skill_name, "skill name must be a string")

  defp require_matching_name(%{"name" => name}, name), do: :ok

  defp require_matching_name(_metadata, _directory),
    do: error(:skill_name_mismatch, "frontmatter name must match its directory")

  defp local_identity(name),
    do: %{
      "source_id" => "project:" <> name,
      "origin" => nil,
      "commit" => nil,
      "tree_digest" => nil
    }

  defp import_config(workspace, source, options) do
    with {:ok, workspace_ref} <- required_binary(options, :workspace_ref),
         {:ok, state_root} <- required_binary(options, :state_root),
         {:ok, rev} <- required_binary(options, :rev),
         true <- Regex.match?(@git_oid, rev),
         {:ok, selected_path} <- safe_relative_path(Keyword.get(options, :path)),
         {:ok, git} <- explicit_git(Keyword.get(options, :git_executable)),
         {:ok, origin} <- sanitized_origin(source),
         {:ok, deadline_ms} <- deadline(Keyword.get(options, :deadline_ms, @max_deadline_ms)),
         deadline = System.system_time(:millisecond) + deadline_ms,
         :ok <- authorization(Keyword.get(options, :executor_authorization)),
         {:ok, root} <- canonical_workspace(workspace) do
      {:ok,
       %{
         workspace: root,
         workspace_ref: workspace_ref,
         state_root: state_root,
         source: source,
         origin: origin,
         rev: rev,
         path: selected_path,
         git: git,
         deadline: deadline,
         authorization: {:host_policy, :allow}
       }}
    else
      false -> error(:invalid_revision, "revision must be one exact lowercase Git object ID")
      {:error, {_reason, _detail}} = refusal -> refusal
    end
  end

  defp authorization({:host_policy, :allow}), do: :ok

  defp authorization(_other),
    do: error(:executor_authorization_required, "explicit host-policy allow is required")

  defp deadline(value) when is_integer(value) and value in 1..@max_deadline_ms, do: {:ok, value}

  defp deadline(_value),
    do: error(:invalid_deadline, "deadline must be between 1 and 30000 milliseconds")

  defp explicit_git(path) when is_binary(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, mode: mode}} ->
        if Bitwise.band(mode, 0o111) != 0 and Path.type(path) == :absolute,
          do: {:ok, path},
          else: error(:git_unavailable, "git executable must be an absolute executable file")

      _other ->
        error(:git_unavailable, "git executable must be an absolute executable file")
    end
  end

  defp explicit_git(_path), do: error(:git_unavailable, "git executable is required")

  defp sanitized_origin(source) do
    uri = URI.parse(source)

    cond do
      byte_size(source) not in 1..1_024 ->
        error(:unsupported_source, "source is outside the supported bound")

      String.contains?(source, <<0>>) ->
        error(:unsupported_source, "source contains a null byte")

      uri.userinfo || uri.query || uri.fragment ->
        error(:unsupported_source, "source may not contain credentials, query, or fragment")

      uri.scheme in [nil, "file", "http", "https", "ssh", "git"] ->
        {:ok, source}

      true ->
        error(:unsupported_source, "source scheme is unsupported")
    end
  end

  defp safe_relative_path(path) when is_binary(path) do
    components = Path.split(path)

    if path != "" and Path.type(path) == :relative and components != [] and
         Enum.all?(components, &(&1 not in [".", ".."])) and not String.contains?(path, <<0>>),
       do: {:ok, Path.join(components)},
       else: error(:invalid_source_path, "selected path must be a contained relative directory")
  end

  defp safe_relative_path(_path), do: error(:invalid_source_path, "selected path is required")

  defp canonical_workspace(workspace) do
    root = Path.expand(workspace)

    case File.mkdir_p(root) do
      :ok -> {:ok, root}
      {:error, reason} -> error(:workspace_unavailable, inspect(reason))
    end
  end

  defp open_import_executor(config) do
    ledger = Path.join([config.state_root, "resource-packs", "receipts"])
    lease_id = "resource-import-" <> nonce()
    identity = "resource-import-executor:" <> Canonical.digest_bytes(Path.expand(ledger))

    with :ok <- ensure_applications(),
         :ok <- File.mkdir_p(ledger),
         {:ok, lease} <-
           WorkspaceLease.start_link(id: lease_id, path: config.workspace, fencing_token: 1) do
      open_executor_after_lease(config, lease, lease_id, identity, ledger)
    else
      {:error, {_reason, _detail}} = refusal -> refusal
      {:error, reason} -> error(:executor_unavailable, inspect(reason))
    end
  end

  defp open_executor_after_lease(config, lease, lease_id, identity, ledger) do
    result =
      with {:ok, artifacts} <- LoopexComposition.artifacts(config.state_root),
           {:ok, executor} <-
             Local.start_link(
               identity: identity,
               epoch: 1,
               fencing_token: 1,
               workspace_leases: %{lease_id => lease},
               ledger_root: ledger,
               artifacts: artifacts
             ) do
        {:ok,
         %{lease: lease, lease_id: lease_id, executor: executor, identity: identity, sequence: 0}}
      else
        {:error, reason} -> error(:executor_unavailable, inspect(reason))
      end

    if match?({:error, _reason}, result), do: stop_process(lease)
    result
  end

  defp close_import_executor(context) do
    Enum.each([context.executor, context.lease], &stop_process/1)

    :ok
  catch
    :exit, _reason -> :ok
  end

  defp stop_process(pid) do
    if is_pid(pid) and Process.alive?(pid), do: GenServer.stop(pid, :normal, 5_000)
  catch
    :exit, _reason -> :ok
  end

  defp import_with_executor(context, config, staging_root) do
    repo = Path.join(staging_root, "repo")
    export = Path.join(staging_root, "export")

    with :ok <- File.mkdir(export),
         {:ok, context, _clone} <-
           git_job(context, config, "clone", [
             "clone",
             "--quiet",
             "--no-checkout",
             "--no-local",
             config.source,
             repo
           ]),
         {:ok, context, commit} <-
           git_job(context, config, "commit", [
             "-C",
             repo,
             "rev-parse",
             "--verify",
             config.rev <> "^{commit}"
           ]),
         true <- first_line(commit) == config.rev,
         {:ok, context, tree_output} <-
           git_job(context, config, "tree", [
             "-C",
             repo,
             "rev-parse",
             config.rev <> ":" <> config.path
           ]),
         tree = first_line(tree_output),
         true <- matching_git_ids?(config.rev, tree),
         {:ok, _context, _checkout} <-
           git_job(context, config, "checkout", [
             "-C",
             repo,
             "--work-tree=" <> export,
             "checkout",
             "--quiet",
             config.rev,
             "--",
             config.path
           ]),
         selected = Path.join(export, config.path),
         {:ok, metadata_name} <- frontmatter_name(selected),
         true <- metadata_name == Path.basename(selected),
         identity = %{
           "source_id" => "git:" <> Canonical.digest_bytes(config.origin),
           "origin" => config.origin,
           "commit" => config.rev,
           "tree_digest" => tree
         },
         {:ok, pack} <- read_pack(selected, metadata_name, identity) do
      {:ok, pack, selected}
    else
      false ->
        error(
          :git_identity_mismatch,
          "Git identity or selected skill directory did not match"
        )

      {:error, {_reason, _detail}} = refusal ->
        refusal

      {:error, reason} ->
        error(:installation_failed, inspect(reason))
    end
  end

  defp finalize_import(pack, selected, config, caller, caller_monitor) do
    with :ok <- caller_available(caller, caller_monitor),
         :ok <- before_deadline(config.deadline),
         :ok <- retain_provenance([pack], config.state_root),
         :ok <- caller_available(caller, caller_monitor),
         :ok <- before_deadline(config.deadline),
         :ok <- publish_pack(selected, config.workspace, pack["name"]) do
      {:ok, pack}
    end
  end

  defp caller_available(caller, caller_monitor) do
    receive do
      {:DOWN, ^caller_monitor, :process, ^caller, _reason} -> :caller_down
    after
      0 -> if Process.alive?(caller), do: :ok, else: :caller_down
    end
  end

  defp before_deadline(deadline) do
    if System.system_time(:millisecond) < deadline,
      do: :ok,
      else: error(:git_failed, "resource import deadline reached")
  end

  defp remaining_ms(deadline), do: max(deadline - System.system_time(:millisecond), 0)

  defp git_job(context, config, label, args) do
    sequence = context.sequence + 1
    deadline = config.deadline
    remaining_ms = max(deadline - System.system_time(:millisecond), 1)
    job_id = "resource-import-#{label}-#{nonce()}"
    argv = ["/usr/bin/env" | @git_environment ++ [config.git] ++ @git_config ++ args]

    fields = %{
      protocol_version: 1,
      job_id: job_id,
      operation_id: job_id,
      attempt: 1,
      session_id: "resource-import",
      run_id: "resource-import-#{sequence}",
      turn_id: "resource-import",
      tool_call_id: job_id,
      origin_session_epoch: 0,
      origin_executor_epoch: 1,
      executor_identity: context.identity,
      required_capabilities: ["process"],
      tool_id: "loopex.bash",
      tool_version: "1.0.0",
      effect_class: "process",
      validated_arguments: %{"argv" => argv},
      workspace_ref: config.workspace_ref,
      workspace_lease: context.lease_id,
      run_deadline: deadline,
      resource_budgets: %{"max_wall_time_ms" => remaining_ms, "max_output_bytes" => 65_536},
      idempotency_class: "never_blind_retry",
      fencing_token: 1,
      artifact_policy: %{"retain" => false},
      output_policy: %{"capture" => true},
      cleanup_grace_ms: 5_000
    }

    with {:ok, job} <- Executor.job(fields),
         {:ok, grant} <-
           Executor.issue_grant(config.authorization, job, deadline, %{
             "purpose" => "resource_pack_import"
           }),
         :ok <- notify_import_started(config, job_id),
         {:ok, receipt} <- Local.execute(context.executor, job, grant),
         :completed <- receipt.outcome do
      {:ok, %{context | sequence: sequence}, receipt.output}
    else
      {:ok, %{outcome: outcome, output: output}} -> error(:git_failed, "#{outcome}: #{output}")
      {:error, reason} -> error(:executor_failed, inspect(reason))
      other -> error(:executor_failed, inspect(other))
    end
  end

  defp notify_import_started(%{import_observer: {observer, tag}}, job_id) do
    send(observer, {tag, :job_started, job_id})
    :ok
  end

  defp first_line(output), do: output |> String.split("\n", parts: 2) |> hd() |> String.trim()

  defp matching_git_ids?(commit, tree),
    do: Regex.match?(@git_oid, tree) and byte_size(commit) == byte_size(tree)

  defp frontmatter_name(selected) do
    with {:ok, content} <- read_file(Path.join(selected, "SKILL.md"), :skill_manifest_missing),
         {:ok, %{"name" => name}} <- parse_skill(content) do
      {:ok, name}
    end
  end

  defp publish_pack(selected, workspace, name) do
    destination_root = Path.join([workspace, ".agents", "skills"])
    destination = Path.join(destination_root, name)

    with :ok <- File.mkdir_p(destination_root),
         false <- File.exists?(destination),
         :ok <- File.rename(selected, destination) do
      :ok
    else
      true -> error(:pack_already_installed, "#{name} is already installed")
      {:error, reason} -> error(:installation_failed, inspect(reason))
    end
  end

  defp retain_provenance(packs, state_root) do
    Enum.reduce_while(packs, :ok, fn pack, :ok ->
      if is_binary(pack["commit"]) do
        record = pack

        path =
          Path.join([retention_root(state_root), "provenance", content_identity(pack) <> ".etf"])

        case atomic_term(path, record) do
          :ok -> {:cont, :ok}
          refusal -> {:halt, refusal}
        end
      else
        {:cont, :ok}
      end
    end)
  end

  defp reattach_provenance(pack, state_root) when is_binary(state_root) do
    path = Path.join([retention_root(state_root), "provenance", content_identity(pack) <> ".etf"])

    with {:ok, bytes} <- File.read(path),
         {:ok, record} <- decode_term(bytes),
         {:ok, _digest} <- core_pack_digest(record),
         true <- provenance_matches?(record, pack) do
      Map.merge(pack, Map.take(record, ["source_id", "origin", "commit", "tree_digest"]))
    else
      _other -> pack
    end
  end

  defp reattach_provenance(pack, _state_root), do: pack

  defp provenance_matches?(record, pack) do
    provenance_file_identity(record["files"]) == provenance_file_identity(pack["files"]) and
      is_binary(record["origin"]) and Regex.match?(@git_oid, record["commit"] || "") and
      matching_git_ids?(record["commit"], record["tree_digest"] || "")
  end

  defp provenance_file_identity(files) when is_list(files),
    do: Enum.map(files, &Map.take(&1, ["label", "digest"]))

  defp provenance_file_identity(_files), do: :invalid

  defp content_identity(pack) do
    value = Enum.map(pack["files"], &[&1["label"], &1["digest"]])

    Canonical.digest(%{
      "encoding" => Canonical.version(),
      "kind" => "loopex.retained_resource_content/1",
      "value" => value
    })
  end

  defp atomic_term(path, value) do
    bytes = :erlang.term_to_binary(value, [:deterministic])
    directory = Path.dirname(path)

    with :ok <- File.mkdir_p(directory),
         {:ok, temp} <- write_exclusive_temp(path, bytes) do
      try do
        case publish_term(temp, path, bytes) do
          :ok -> :ok
          {:error, {_reason, _detail}} = refusal -> refusal
          {:error, reason} -> error(:retention_failed, inspect(reason))
        end
      after
        File.rm(temp)
      end
    else
      {:error, {_reason, _detail}} = refusal -> refusal
      {:error, reason} -> error(:retention_failed, inspect(reason))
    end
  end

  defp create_staging_root(workspace) do
    parent = Path.join(workspace, ".agents")

    with :ok <- File.mkdir_p(parent) do
      create_exclusive_directory(parent, 8)
    else
      {:error, reason} -> error(:installation_failed, inspect(reason))
    end
  end

  defp create_exclusive_directory(_parent, 0),
    do: error(:installation_failed, "could not allocate an exclusive staging directory")

  defp create_exclusive_directory(parent, attempts) do
    path = Path.join(parent, ".loopex-import-" <> nonce())

    case File.mkdir(path) do
      :ok -> {:ok, path}
      {:error, :eexist} -> create_exclusive_directory(parent, attempts - 1)
      {:error, reason} -> error(:installation_failed, inspect(reason))
    end
  end

  defp write_exclusive_temp(path, bytes, attempts \\ 8)

  defp write_exclusive_temp(_path, _bytes, 0),
    do: error(:retention_failed, "could not allocate an exclusive retention temporary")

  defp write_exclusive_temp(path, bytes, attempts) do
    temp = path <> ".tmp-" <> nonce()

    case :file.open(String.to_charlist(temp), [:raw, :write, :binary, :exclusive]) do
      {:ok, device} ->
        write_result =
          with :ok <- :file.write(device, bytes),
               :ok <- :file.sync(device) do
            :ok
          end

        close_result = :file.close(device)

        case {write_result, close_result} do
          {:ok, :ok} ->
            {:ok, temp}

          {{:error, reason}, _close_result} ->
            File.rm(temp)
            error(:retention_failed, inspect(reason))

          {:ok, {:error, reason}} ->
            File.rm(temp)
            error(:retention_failed, inspect(reason))
        end

      {:error, :eexist} ->
        write_exclusive_temp(path, bytes, attempts - 1)

      {:error, reason} ->
        error(:retention_failed, inspect(reason))
    end
  end

  defp nonce, do: Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)

  defp publish_term(temp, path, bytes) do
    case File.ln(temp, path) do
      :ok -> :ok
      {:error, :eexist} -> verify_existing_term(path, bytes)
      {:error, reason} -> {:error, reason}
    end
  end

  defp verify_existing_term(path, expected) do
    case File.read(path) do
      {:ok, ^expected} ->
        :ok

      {:ok, _other} ->
        error(:retained_identity_collision, "existing retained identity has different bytes")

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp decode_term(bytes) do
    {:ok, :erlang.binary_to_term(bytes, [:safe])}
  rescue
    _error -> error(:retained_manifest_invalid, "retained data is not a safe canonical term")
  end

  defp retention_root(state_root), do: Path.join(state_root, "resource-packs")

  defp required_binary(options, key) do
    case Keyword.fetch(options, key) do
      {:ok, value} when is_binary(value) and byte_size(value) in 1..1_024 ->
        if String.valid?(value),
          do: {:ok, value},
          else: error(:invalid_options, "#{key} is required")

      _other ->
        error(:invalid_options, "#{key} is required")
    end
  end

  defp read_file(path, reason) do
    case File.read(path) do
      {:ok, bytes} -> {:ok, bytes}
      {:error, file_reason} -> error(reason, inspect(file_reason))
    end
  end

  defp core_digest(manifest) do
    case Loopex.ResourcePack.digest(manifest) do
      {:ok, digest, normalized} -> {:ok, digest, normalized}
      {:error, reason, detail} -> error(reason, detail)
      other -> error(:invalid_manifest, inspect(other))
    end
  end

  defp core_pack_digest(pack) do
    case Loopex.ResourcePack.pack_digest(pack) do
      {:ok, digest} -> {:ok, digest}
      digest when is_binary(digest) -> {:ok, digest}
      {:error, reason, detail} -> error(reason, detail)
      other -> error(:invalid_pack, inspect(other))
    end
  end

  defp ensure_applications do
    Enum.find_value([:loopex, :loopex_store_local, :loopex_executor_local], :ok, fn app ->
      case Application.ensure_all_started(app) do
        {:ok, _started} -> nil
        {:error, reason} -> error(:application_not_started, inspect({app, reason}))
      end
    end)
  end

  defp error(reason, detail) when is_atom(reason) do
    detail = if is_binary(detail), do: detail, else: inspect(detail)
    {:error, {reason, binary_part(detail, 0, min(byte_size(detail), @max_detail_bytes))}}
  end
end
