defmodule LoopexCli.Daemon do
  @moduledoc """
  ## Concept

  `loopex daemon` starts one daemon for a state root in the foreground and
  exits with a status an operator or service manager can act on. Every
  mistake an operator can make in its inputs is refused before the daemon
  takes any lock, marker or socket, so a refused start leaves nothing behind.

  ## Technical depth

  The command parses its closed grammar with `LoopexDaemon.Command`, then
  resolves each composition input from its fixed source: a present flag wins
  over its environment variable, an empty flag never falls back, and a missing
  or invalid mandatory input maps to its own exit class. The provider
  credential is read once from `LOOPEX_PROVIDER_API_KEY` and deleted from the
  environment before composition. The root `AGENTS.md` decision is taken
  before the sentinel installs its signal route, and the policy registry is
  exactly the reference CLI's `allow-all` and `shell-allowlist`. The resolved
  inputs go to `LoopexDaemon.Sentinel`, whose status is returned. Diagnostics
  are one fixed line on standard error written by a disposable helper; no
  input value, path or credential is printed.
  """

  alias LoopexComposition.{ProjectResources, ResourcePacks}
  alias LoopexDaemon.{Command, ExitStatus, Paths, Sentinel}

  @credential_variable "LOOPEX_PROVIDER_API_KEY"
  @max_u64 18_446_744_073_709_551_615
  @max_credential_bytes 65_536
  @diagnostic_wait_ms 1_000

  @doc """
  ## Concept

  The operating-system entry point: standard output carries at most the one
  readiness line, so every log line goes to standard error.

  ## Technical depth

  The default log handler is moved to standard error at level `info` before
  anything else runs; the process then halts with `run/2`'s status.
  """
  @spec main([binary()]) :: no_return()
  def main(arguments) do
    _ = :logger.update_handler_config(:default, :config, %{type: :standard_error})
    :ok = Logger.configure(level: :info)
    System.halt(run(arguments))
  end

  @doc """
  ## Concept

  Runs one `loopex daemon` invocation and returns its exit status.

  ## Technical depth

  `options` exists for tests: `:env` replaces environment reads, `:output`
  replaces standard output for the readiness line, and `:install_signals` and
  `:notify` pass through to the sentinel. Parser refusals are status `1`.
  """
  @spec run([binary()], keyword()) :: non_neg_integer()
  def run(arguments, options \\ []) when is_list(arguments) do
    # The credential leaves the environment before any input is checked or any
    # child can start, whichever form this is.
    credential = credential(options)

    case Command.parse(arguments) do
      {:ok, {:start, flags}} ->
        start(flags, Keyword.put(options, :resolved_credential, credential))

      {:ok, {:prepare_index, flags}} ->
        prepare_index(flags, options)

      {:error, :invalid_daemon_arguments} ->
        diagnostic(usage())
        ExitStatus.parser_refusal()
    end
  end

  defp start(flags, options) do
    env = Keyword.get(options, :env, &System.get_env/1)

    with {:ok, root} <- input(flags, env, "state-root", "LOOPEX_HOME", :state_root_required),
         {:ok, paths} <- paths(root, Map.get(flags, "socket")),
         {:ok, workspace} <- workspace(flags, env),
         {:ok, launch} <- provider_launch(flags, env),
         {:ok, policy} <- policy(flags, env),
         {:ok, grace} <- cleanup_grace(flags),
         {:ok, credential} <- Keyword.fetch!(options, :resolved_credential),
         {:ok, skills} <- resource_manifest(workspace, paths.state_root) do
      discovered = ProjectResources.discover(workspace)

      service_options =
        [
          state_root: paths.state_root,
          socket_path: paths.socket_path,
          workspace: workspace,
          policy: policy,
          provider_launch: launch,
          credential: credential,
          project_manifest: ProjectResources.runtime_manifest(discovered),
          project_decision: ProjectResources.decide(discovered, workspace),
          resource_manifest: skills
        ] ++ grace

      Sentinel.run(
        service_options,
        Keyword.take(options, [:output, :diagnostic, :install_signals, :notify])
      )
    else
      {:error, class} ->
        diagnostic("loopex daemon refused to start: #{class}")
        {:ok, status} = ExitStatus.fetch(class)
        status
    end
  end

  # Concept: the offline import needs only the state root, and says what it
  # recorded or why it refused on standard error.
  defp prepare_index(flags, options) do
    env = Keyword.get(options, :env, &System.get_env/1)

    result =
      with {:ok, root} <- input(flags, env, "state-root", "LOOPEX_HOME", :state_root_required),
           {:ok, root} <- LoopexDaemon.Paths.state_root(root) do
        LoopexDaemon.PrepareIndex.run(root, Keyword.take(options, [:install_signals, :notify]))
      end

    case result do
      {:ok, count} ->
        diagnostic("loopex daemon prepare-index recorded #{count} sessions")
        ExitStatus.success()

      {:error, class} ->
        diagnostic("loopex daemon prepare-index refused: #{class}")
        {:ok, status} = ExitStatus.fetch(class)
        status
    end
  end

  # Concept: a present flag wins; an absent flag falls back to its environment
  # variable, and an empty environment value is as missing as an absent one.
  defp input(flags, env, flag, variable, missing) do
    case Map.fetch(flags, flag) do
      {:ok, value} ->
        {:ok, value}

      :error ->
        case env.(variable) do
          value when is_binary(value) and value != "" -> {:ok, value}
          _missing -> {:error, missing}
        end
    end
  end

  defp paths(root, socket) do
    case Paths.startup(root, socket) do
      {:ok, paths} -> {:ok, paths}
      {:error, {:socket_path_too_long, _limit}} -> {:error, :socket_path_too_long}
      {:error, :state_root_required} -> {:error, :state_root_required}
      {:error, :unsupported_platform} -> {:error, :state_root_unusable}
      {:error, class} -> {:error, class}
    end
  end

  defp workspace(flags, env) do
    with {:ok, workspace} <-
           input(flags, env, "workspace", "LOOPEX_WORKSPACE", :workspace_required) do
      expanded = Path.expand(workspace)

      if String.valid?(workspace) and File.dir?(expanded),
        do: {:ok, expanded},
        else: {:error, :workspace_unusable}
    end
  end

  # Concept: the provider launch configuration is data an operator names;
  # it is read once as Erlang terms and must be one keyword list.
  defp provider_launch(flags, env) do
    with {:ok, path} <-
           input(
             flags,
             env,
             "provider-launch",
             "LOOPEX_PROVIDER_LAUNCH",
             :provider_launch_required
           ) do
      case :file.consult(String.to_charlist(Path.expand(path))) do
        {:ok, [configuration]} when is_list(configuration) ->
          if Keyword.keyword?(configuration),
            do: {:ok, configuration},
            else: {:error, :provider_launch_invalid}

        _unreadable ->
          {:error, :provider_launch_invalid}
      end
    end
  end

  defp policy(flags, env) do
    with {:ok, name} <- input(flags, env, "policy", "LOOPEX_POLICY", :policy_required) do
      case LoopexCli.policy(name) do
        {:ok, module} -> {:ok, module}
        {:error, _message} -> {:error, :policy_unknown}
      end
    end
  end

  defp cleanup_grace(flags) do
    case Map.fetch(flags, "cleanup-grace-ms") do
      :error ->
        {:ok, []}

      {:ok, value} ->
        case Integer.parse(value) do
          {grace, ""} when grace >= 1 and grace <= @max_u64 -> {:ok, [cleanup_grace_ms: grace]}
          _invalid -> {:error, :cleanup_grace_invalid}
        end
    end
  end

  # Concept: the credential is consumed once into the daemon's custody and
  # never remains in this process's environment.
  defp credential(options) do
    value =
      case Keyword.fetch(options, :credential) do
        {:ok, supplied} -> supplied
        :error -> System.get_env(@credential_variable)
      end

    System.delete_env(@credential_variable)

    if is_binary(value) and byte_size(value) in 1..@max_credential_bytes,
      do: {:ok, value},
      else: {:error, :provider_credential_required}
  end

  defp resource_manifest(workspace, root) do
    with {:ok, workspace_ref} <- ProjectResources.workspace_reference(workspace),
         {:ok, manifest} <-
           ResourcePacks.discover(workspace, workspace_ref: workspace_ref, state_root: root) do
      {:ok, manifest}
    else
      _unusable -> {:error, :project_skills_unusable}
    end
  end

  # Concept: a diagnostic is attempted, never awaited past a fixed bound, so
  # a blocked standard error cannot hold the exit.
  defp diagnostic(line) do
    {helper, monitor} = spawn_monitor(fn -> IO.puts(:stderr, line) end)

    receive do
      {:DOWN, ^monitor, :process, ^helper, _reason} -> :ok
    after
      @diagnostic_wait_ms ->
        Process.exit(helper, :kill)
        :ok
    end
  end

  defp usage do
    """
    usage: loopex daemon [--state-root <directory>] [--workspace <directory>]
                         [--provider-launch <configuration-path>] [--policy <name>]
                         [--cleanup-grace-ms <milliseconds>] [--socket <path>]
           loopex daemon prepare-index [--state-root <directory>]
    """
  end
end
