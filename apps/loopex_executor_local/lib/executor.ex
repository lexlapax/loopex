defmodule Loopex.Executor.Local do
  @moduledoc """
  ## Concept

  The M1 trusted-local executor. It resolves a host-held workspace lease,
  validates every ADR 0007 binding at one serialized final boundary, launches a
  fixed controlled OS tool with a credential-free environment, and durably
  retains the terminal receipt before replying.

  ## Technical depth

  One GenServer serializes final validation and process start. The fixed tool
  registry is code-owned rather than model-owned. `/usr/bin/env -i` constructs
  the child environment from nothing, then a fixed shell program receives only
  validated bounded arguments. A monitored lease loss closes the owned port and
  is retained as cancellation evidence. Receipts are synced to one file per job
  and exact duplicate jobs return the retained receipt without another start.
  """

  use GenServer

  @behaviour Loopex.Executor

  alias Loopex.Executor
  alias Loopex.Executor.Local.CodingTools
  alias Loopex.Executor.Local.WorkspaceLease

  @max_output_bytes 1_048_576
  @tool_version "1.0.0"
  @write_tool "loopex.demo.write"
  @wait_write_tool "loopex.demo.wait_write"
  @credential_name "LOOPEX_PROVIDER_API_KEY"
  @search_path_name "PATH"
  @search_path_value "/usr/bin:/bin"

  @typedoc """
  ## Concept

  The explicit reference to one local executor instance.

  ## Technical depth

  This pid is transient placement state and never enters durable or public
  protocol data.
  """
  @type t :: pid()

  @doc """
  ## Concept

  Starts one explicitly configured trusted-local executor.

  ## Technical depth

  Lease pids and the ledger path are edge-private. Identity, epoch, and fence
  are the plain values jobs and receipts bind.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options) when is_list(options), do: GenServer.start_link(__MODULE__, options)

  @doc """
  ## Concept

  Runs or recalls one exact controlled job.

  ## Technical depth

  Duplicate job IDs return a matching retained receipt. A different digest
  under the same ID is refused and never starts a process.
  """
  @impl Loopex.Executor
  @spec execute(t(), Executor.job_request(), Executor.grant(), keyword(), Executor.progress_fun()) ::
          {:ok, map()} | {:error, term()}
  def execute(executor, job, grant, options \\ [], progress \\ nil)

  def execute(executor, job, grant, options, progress)
      when is_pid(executor) and is_map(job) and is_map(grant) and is_list(options) do
    # Concept: an executor that emits nothing is conformant.
    #
    # Technical depth: this executor does not stream yet, so it accepts the
    # progress function, never calls it, and reports `progress_count: 0`. The
    # coordinator then closes that operation's domain with a truthful count
    # rather than with an absent item a consumer would have to interpret.
    _progress = progress || Executor.discard_progress()
    GenServer.call(executor, {:execute, job, grant, options}, :infinity)
  end

  @doc """
  ## Concept

  Stops one running job's process tree and reports whether it is gone.

  ## Technical depth

  Runs in the caller rather than in this executor's GenServer, because that
  server is blocked for the duration of the job being cancelled. The operating
  system effect still belongs to this application — the hand owns effects, and
  this is the hand's code — but it must not be queued behind the very work it is
  meant to end.

  Signals the job's owned process group and then confirms by looking for
  survivors. A job this executor has no record of is trivially clean: it either
  never started or already finished, and in both cases there is nothing running.
  """
  @impl Loopex.Executor
  @spec cancel(t(), binary()) :: {:ok, :cleaned} | {:ok, :unconfirmed}
  def cancel(executor, job_id) when is_pid(executor) and is_binary(job_id) do
    case lookup_inflight(executor, job_id) do
      {:ok, group} ->
        terminate_group(group)

        if confirm_group_terminated(group),
          do: {:ok, :cleaned},
          else: {:ok, :unconfirmed}

      :error ->
        {:ok, :cleaned}
    end
  end

  defp lookup_inflight(executor, job_id) do
    with {:dictionary, dictionary} <- Process.info(executor, :dictionary),
         table when not is_nil(table) <- Keyword.get(dictionary, :loopex_inflight_table),
         [{^job_id, group}] <- :ets.lookup(table, job_id) do
      {:ok, group}
    else
      _absent -> :error
    end
  end

  @doc """
  ## Concept

  Reads a terminal receipt retained by this executor.

  ## Technical depth

  Reads through the serialized owner, which validates the on-disk job binding
  before returning plain data.
  """
  @spec receipt(t(), binary()) :: {:ok, map()} | :absent | {:error, term()}
  def receipt(executor, job_id) when is_pid(executor) and is_binary(job_id),
    do: GenServer.call(executor, {:receipt, job_id})

  @doc false
  @spec stats(t()) :: map()
  def stats(executor) when is_pid(executor), do: GenServer.call(executor, :stats)

  @doc false
  @spec tool(binary()) :: {:ok, map()} | :error
  def tool(@write_tool),
    do: {:ok, %{id: @write_tool, version: @tool_version, effect_class: "workspace_write"}}

  def tool(@wait_write_tool),
    do: {:ok, %{id: @wait_write_tool, version: @tool_version, effect_class: "workspace_write"}}

  # Concept: the four coding tools an operator actually uses.
  #
  # Technical depth: routed here beside the two demonstration tools rather than
  # replacing them. M1's inherited executor and recovery cases still resolve the
  # demonstrations, and the registry must prove it resolves a generation outside
  # any active profile; deleting them to tidy up would break proved protection to
  # save two clauses.
  def tool(id) do
    case Enum.find(CodingTools.definitions(), &(&1["tool_id"] == id)) do
      nil ->
        :error

      definition ->
        {:ok,
         %{
           id: id,
           version: definition["tool_version"],
           effect_class: definition["effect_class"],
           coding: definition
         }}
    end
  end

  @impl GenServer
  def init(options) do
    identity = Keyword.fetch!(options, :identity)
    epoch = Keyword.fetch!(options, :epoch)
    fencing_token = Keyword.fetch!(options, :fencing_token)
    leases = Keyword.fetch!(options, :workspace_leases)
    ledger_root = Keyword.fetch!(options, :ledger_root) |> Path.expand()

    valid =
      is_binary(identity) and byte_size(identity) > 0 and is_integer(epoch) and epoch >= 0 and
        is_integer(fencing_token) and fencing_token >= 0 and is_map(leases) and
        Enum.all?(leases, fn {id, pid} -> is_binary(id) and is_pid(pid) end)

    with true <- valid,
         :ok <- File.mkdir_p(ledger_root) do
      {:ok,
       %{
         identity: identity,
         epoch: epoch,
         fencing_token: fencing_token,
         leases: leases,
         ledger_root: ledger_root,
         dispatches: %{}
       }}
    else
      _other -> {:stop, :invalid_executor_configuration}
    end
  end

  @impl GenServer
  def handle_call({:receipt, job_id}, _from, state),
    do: {:reply, read_receipt(state.ledger_root, job_id), state}

  def handle_call(:stats, _from, state),
    do: {:reply, %{dispatches: state.dispatches}, state}

  def handle_call({:execute, job, grant, options}, _from, state) do
    case read_receipt(state.ledger_root, Map.get(job, :job_id, "")) do
      {:ok, receipt} ->
        if Map.get(receipt, :canonical_request_digest) ==
             Map.get(job, :canonical_request_digest) do
          {:reply, {:ok, receipt}, state}
        else
          {:reply, {:error, :job_id_conflict}, state}
        end

      :absent ->
        execute_new(state, job, grant, options)

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl GenServer
  def format_status(status) do
    status
    |> Map.put(:state, :redacted_local_executor_state)
    |> Map.put(:message, :redacted_local_executor_message)
    |> Map.put(:reason, :redacted_local_executor_reason)
    |> Map.put(:log, [])
  end

  # Concept: this function is the one final serialized authority boundary.
  #
  # Technical depth: mutation evidence names this mechanism
  # `executor_final_prestart_validation`. No Port is opened before it has
  # independently validated job bytes, tool metadata, live lease, fence,
  # audience, expiry, and all ten grant bindings.
  defp final_prestart_validation(state, job, grant) do
    with :ok <- Executor.validate_job(job),
         {:ok, tool} <- resolve_tool(job),
         {:ok, lease_pid} <- Map.fetch(state.leases, job.workspace_lease),
         true <- Process.alive?(lease_pid),
         {:ok, lease} <- WorkspaceLease.resolve(lease_pid, job.workspace_lease),
         true <- lease.fencing_token == state.fencing_token,
         :ok <-
           Executor.validate_grant(job, grant, %{
             executor_identity: state.identity,
             workspace_lease: lease.id,
             fencing_token: state.fencing_token,
             now: System.system_time(:millisecond)
           }),
         true <- job.executor_identity == state.identity,
         true <- job.origin_executor_epoch == state.epoch,
         true <- job.run_deadline > System.system_time(:millisecond),
         {:ok, arguments} <- validate_arguments(tool, job.validated_arguments) do
      {:ok, tool, lease_pid, lease.path, arguments}
    else
      :error -> {:error, :workspace_lease_not_held}
      false -> {:error, :executor_prestart_mismatch}
      {:error, reason} -> {:error, reason}
    end
  end

  defp execute_new(state, job, grant, options) do
    case final_prestart_validation(state, job, grant) do
      {:ok, tool, lease_pid, workspace, arguments} ->
        next_state =
          update_in(state.dispatches, fn dispatches ->
            Map.update(dispatches, job.job_id, 1, &(&1 + 1))
          end)

        receipt = run_tool(next_state, job, tool, lease_pid, workspace, arguments, options)

        case retain_receipt(next_state.ledger_root, receipt) do
          :ok -> {:reply, {:ok, receipt}, next_state}
          {:error, reason} -> {:reply, {:error, {:receipt_not_retained, reason}}, next_state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp resolve_tool(job) do
    case tool(job.tool_id) do
      {:ok, %{version: version, effect_class: effect_class} = found}
      when version == job.tool_version and effect_class == job.effect_class ->
        {:ok, found}

      _other ->
        {:error, :tool_definition_mismatch}
    end
  end

  defp validate_arguments(%{id: @write_tool}, arguments),
    do: write_arguments(arguments, 0)

  defp validate_arguments(%{id: @wait_write_tool}, %{
         "relative_path" => path,
         "content" => content,
         "delay_ms" => delay
       })
       when is_integer(delay) and delay in 1..30_000,
       do: write_arguments(%{"relative_path" => path, "content" => content}, delay)

  defp validate_arguments(%{coding: %{"tool_id" => "loopex.read"}}, %{"path" => path})
       when is_binary(path),
       do: {:ok, %{kind: :read, path: path}}

  defp validate_arguments(%{coding: %{"tool_id" => "loopex.write"}}, %{
         "path" => path,
         "content" => content
       })
       when is_binary(path) and is_binary(content),
       do: {:ok, %{kind: :write, path: path, content: content}}

  defp validate_arguments(%{coding: %{"tool_id" => "loopex.edit"}}, %{
         "path" => path,
         "old" => old,
         "new" => new
       })
       when is_binary(path) and is_binary(old) and is_binary(new),
       do: {:ok, %{kind: :edit, path: path, old: old, new: new}}

  # Concept: argv and a raw shell command are two operations, not one with a
  # convenience.
  #
  # Technical depth: an argv vector is passed through without a shell, so no
  # character in an argument is interpreted; a raw command asks for a shell and
  # gets one. Accepting both at once would leave a caller unable to say which
  # they meant, so supplying both is refused.
  defp validate_arguments(%{coding: %{"tool_id" => "loopex.bash"}}, arguments)
       when is_map(arguments) do
    argv = Map.get(arguments, "argv")
    command = Map.get(arguments, "command")

    cond do
      is_list(argv) and Enum.all?(argv, &is_binary/1) and argv != [] and is_nil(command) ->
        {:ok, %{kind: :bash, argv: argv}}

      is_binary(command) and command != "" and is_nil(argv) ->
        {:ok, %{kind: :bash, command: command}}

      true ->
        {:error, :invalid_tool_arguments}
    end
  end

  defp validate_arguments(_tool, _arguments), do: {:error, :invalid_tool_arguments}

  defp write_arguments(%{"relative_path" => path, "content" => content}, delay)
       when is_binary(path) and is_binary(content) and byte_size(content) <= 65_536 do
    safe =
      byte_size(path) in 1..255 and path not in [".", ".."] and
        Path.basename(path) == path and not String.contains?(path, <<0>>)

    if safe,
      do: {:ok, %{path: path, content: content, delay_ms: delay}},
      else: {:error, :invalid_tool_arguments}
  end

  defp write_arguments(_arguments, _delay), do: {:error, :invalid_tool_arguments}

  defp run_tool(
         state,
         job,
         %{coding: _definition} = tool,
         _lease_pid,
         workspace,
         arguments,
         options
       ) do
    {outcome, output} = run_coding_tool(job, tool, workspace, arguments, options)
    receipt(state, job, tool, outcome, output, coding_tool_environment(arguments))
  end

  defp run_tool(state, job, tool, lease_pid, workspace, arguments, options) do
    monitor = Process.monitor(lease_pid)
    args = launcher_arguments(arguments)

    port =
      Port.open(
        {:spawn_executable, String.to_charlist("/usr/bin/env")},
        [
          :binary,
          :exit_status,
          :use_stdio,
          :stderr_to_stdout,
          :hide,
          args: Enum.map(args, &String.to_charlist/1),
          cd: String.to_charlist(workspace)
        ]
      )

    notify(options, {:executor_process_started, job.job_id, tool.id, [@search_path_name]})
    {outcome, output} = await_port(port, monitor, lease_pid, <<>>)
    Process.demonitor(monitor, [:flush])

    receipt(state, job, tool, outcome, output, demonstration_environment())
  end

  # Concept: the three filesystem tools start no child, so they hold no
  # environment; `bash` holds the one this executor constructed.
  #
  # Technical depth: reporting `PATH` for a tool that never spawned anything
  # would be as untrue as reporting the wrong one for a tool that did. A tool
  # with no child reports no environment names, which is what happened.
  defp coding_tool_environment(%{kind: :bash}), do: child_environment()
  defp coding_tool_environment(_arguments), do: []

  # Concept: the three filesystem tools do not need a process, so they do not
  # start one.
  #
  # Technical depth: spawning a shell to read a file would put an operating
  # system process, a signal path, and a termination story between the operator
  # and a `File.read`. `bash` is the tool that genuinely needs a child, and it is
  # the only one that gets one.
  # Concept: a filesystem tool is bounded by the same instant a shell tool is.
  #
  # Technical depth: these three start no child, so nothing could be terminated
  # mid-flight and they carried no deadline at all -- a run whose deadline had
  # already passed still read, wrote, or edited. They cannot be interrupted once
  # begun, so the honest bound is refusing to begin: the deadline is checked
  # before the effect rather than pretended to be enforced during it.
  defp run_coding_tool(job, tool, workspace, %{kind: kind} = arguments, options)
       when kind in [:read, :write, :edit] do
    if System.system_time(:millisecond) >= effective_deadline(job, tool) do
      {:failed, "the effective deadline passed before this tool began"}
    else
      run_bounded_tool(job, tool, workspace, arguments, options)
    end
  end

  defp run_coding_tool(job, tool, workspace, %{kind: :bash} = arguments, options) do
    run_owned_process(job, tool, workspace, arguments, options)
  end

  defp run_bounded_tool(_job, _tool, workspace, %{kind: :read, path: path}, _options) do
    with {:ok, resolved} <- CodingTools.resolve(workspace, path) do
      case File.read(resolved) do
        {:ok, content} ->
          case CodingTools.bound_output(content, CodingTools.limits().read_bytes) do
            {:complete, bounded} -> {:completed, bounded}
            {:truncated, kept, _full} -> {:completed, truncation_marker(kept, byte_size(content))}
          end

        {:error, reason} ->
          {:failed, "read failed: #{:file.format_error(reason)}"}
      end
    else
      {:error, reason} -> {:failed, containment_message(reason)}
    end
  end

  defp run_bounded_tool(
         _job,
         _tool,
         workspace,
         %{kind: :write, path: path, content: content},
         _opts
       ) do
    with {:ok, resolved} <- CodingTools.resolve(workspace, path),
         :ok <- File.mkdir_p(Path.dirname(resolved)),
         :ok <- File.write(resolved, content) do
      {:completed, "wrote #{byte_size(content)} bytes to #{path}"}
    else
      {:error, reason} when is_atom(reason) ->
        {:failed, "write failed: #{:file.format_error(reason)}"}

      {:error, reason} ->
        {:failed, containment_message(reason)}
    end
  end

  # Concept: an edit that cannot be made says what it found instead.
  #
  # Technical depth: a blank failure costs a model a guess and another turn. The
  # diagnostics below distinguish absent from ambiguous, and an absent match
  # reports the nearest line it did find, because "your string is not here" and
  # "your string is here twice" call for different corrections.
  defp run_bounded_tool(_job, _tool, workspace, %{kind: :edit} = arguments, _options) do
    %{path: path, old: old, new: new} = arguments

    with {:ok, resolved} <- CodingTools.resolve(workspace, path),
         {:ok, content} <- read_for_edit(resolved) do
      case occurrences(content, old) do
        1 ->
          updated = String.replace(content, old, new)

          case File.write(resolved, updated) do
            :ok -> {:completed, "replaced 1 occurrence in #{path}"}
            {:error, reason} -> {:failed, "edit failed: #{:file.format_error(reason)}"}
          end

        0 ->
          {:failed,
           "edit failed: the exact text was not found in #{path}. " <>
             nearest_hint(content, old)}

        count ->
          {:failed,
           "edit failed: the text appears #{count} times in #{path}. " <>
             "Include more surrounding context so exactly one occurrence matches."}
      end
    else
      {:error, reason} when is_atom(reason) ->
        {:failed, "edit failed: #{:file.format_error(reason)}"}

      {:error, reason} ->
        {:failed, containment_message(reason)}
    end
  end

  # Concept: a command runs as a group this executor owns and can end.
  #
  # Technical depth: the child is started under `setsid`, so it becomes a process
  # group leader and every descendant it spawns joins that group. Termination
  # then signals the negated group id rather than the leader, which is the
  # difference between ending the work and ending the one process that happened
  # to be on top of it. A leader that forks and exits would otherwise leave its
  # children running with nobody's name on them.
  #
  # The group id is captured by the child itself and printed on its first line,
  # because the BEAM gives a port's os_pid but not the group the child chose. A
  # captured identity is the only one termination can honestly claim to have
  # confirmed.
  defp run_owned_process(job, tool, workspace, arguments, options) do
    deadline = effective_deadline(job, tool)
    environment = child_environment()
    {launcher, command_arguments} = process_launcher(arguments, environment)

    port =
      Port.open(
        {:spawn_executable, launcher},
        [
          :binary,
          :exit_status,
          :use_stdio,
          :stderr_to_stdout,
          :hide,
          args: Enum.map(command_arguments, &String.to_charlist/1),
          cd: String.to_charlist(workspace)
        ]
      )

    os_pid = port |> Port.info(:os_pid) |> elem(1)

    notify(
      options,
      {:executor_process_started, job.job_id, job.tool_id, environment_names(environment)}
    )

    register_inflight(job.job_id, os_pid)

    case collect_output(port, os_pid, deadline, <<>>, options, job) do
      {:completed, output} ->
        bound_process_output(output)

      {:cancelled, output, group} ->
        confirmed = confirm_group_terminated(group)

        {if(confirmed, do: :cancelled, else: :outcome_unknown),
         output <>
           "\n[loopex: the deadline passed and the command was terminated." <>
           if(confirmed,
             do: " Its process group is confirmed cleaned.]",
             else: " Cleanup could not be confirmed.]"
           )}
    end
  end

  # Concept: an in-flight job publishes the group it owns, so a cancel can reach
  # it without calling a server that is busy running it.
  #
  # Technical depth: `execute/5` blocks this executor's GenServer for the whole
  # job, so a concurrent `cancel/2` cannot be a call. The table is created per
  # executor process and its identifier is kept in that process's own dictionary
  # rather than under a registered name, because a named table is VM-global and
  # two executors in one VM would collide on it — the same reason nothing else in
  # this project hides per-runtime state in a global name. Reading another
  # process's dictionary is unusual, and it is used here precisely because it
  # reads state that process owns without waiting for it to be free.
  defp inflight_table do
    case Process.get(:loopex_inflight_table) do
      nil ->
        table = :ets.new(:loopex_inflight, [:public, :set])
        Process.put(:loopex_inflight_table, table)
        table

      table ->
        table
    end
  end

  defp register_inflight(job_id, group) do
    :ets.insert(inflight_table(), {job_id, group})
    :ok
  end

  defp forget_inflight(job_id) do
    :ets.delete(inflight_table(), job_id)
    :ok
  end

  defp bound_process_output(output) do
    case CodingTools.bound_output(output, CodingTools.limits().output_bytes) do
      {:complete, bounded} -> {:completed, bounded}
      {:truncated, kept, _full} -> {:completed, truncation_marker(kept, byte_size(output))}
    end
  end

  # Concept: the effective deadline is the earlier of the run's and the tool's.
  #
  # Technical depth: a tool's own wall-time budget can only make a job end
  # sooner, never later. Taking the minimum is what stops a tool budget from
  # outliving the run that authorised it.
  # Concept: the earlier of the run's committed instant and the tool's own
  # declared wall-time budget.
  #
  # Technical depth: the budget was a literal two minutes, so a tool's declared
  # `wall_time_ms` was never read anywhere in the tree -- it happened to equal
  # `loopex.bash`'s declaration and was wrong for the other three. Reading it
  # from the definition is what makes the declaration mean something, and a
  # definition that declares none falls back to the run's instant alone rather
  # than to a number invented here.
  defp effective_deadline(job, tool) do
    case declared_wall_time(tool) do
      nil -> job.run_deadline
      budget -> min(job.run_deadline, System.system_time(:millisecond) + budget)
    end
  end

  defp declared_wall_time(%{coding: %{"budgets" => %{"wall_time_ms" => budget}}})
       when is_integer(budget) and budget > 0,
       do: budget

  defp declared_wall_time(_tool), do: nil

  # Concept: a tool child receives an environment this executor constructed, not
  # the one this operating-system process happens to be holding.
  #
  # Technical depth: a port opened without `env:` inherits the emulator's whole
  # environment. The demonstration tools were launched through `/usr/bin/env -i`
  # and so received nothing; the coding tools were not, so every `bash` call this
  # milestone added ran with the operator's variables -- the provider credential
  # among them, because the operator must export it for the command to run at
  # all. The receipt then journalled `provider_credential_present: false`, which
  # made the durable record assert an absence that was not true.
  #
  # `env:` replaces rather than extends, and clearing a name is `{name, false}`.
  # The credential is cleared explicitly as well as omitted, so the intent is
  # visible at the boundary rather than resting on the list being complete.
  # Concept: the demonstration tools construct their environment in argv.
  #
  # Technical depth: `launcher_arguments/1` passes `-i` and one assignment to
  # `/usr/bin/env`, so the child's environment is that one name. It is expressed
  # here in the same shape the coding tools use so one function reports both.
  defp demonstration_environment do
    [{String.to_charlist(@search_path_name), String.to_charlist(@search_path_value)}]
  end

  defp child_environment do
    [
      {String.to_charlist(@search_path_name), String.to_charlist(@search_path_value)},
      {String.to_charlist(@credential_name), false}
    ]
  end

  # Concept: what the receipt reports is what the child was given.
  #
  # Technical depth: the names were a hardcoded list, so the receipt said `PATH`
  # whatever the child actually received. Deriving them from the environment that
  # was passed makes the journalled claim an observation, which is the only thing
  # that makes it worth journalling.
  defp environment_names(environment) do
    for {name, value} <- environment, value != false, do: List.to_string(name)
  end

  defp credential_present?(environment) do
    Enum.any?(environment, fn {name, value} ->
      List.to_string(name) == @credential_name and value != false
    end)
  end

  # Concept: argv runs without a shell; a raw command runs in one.
  #
  # Technical depth: `setsid` wraps both so the child leads its own group. For
  # argv the program and its arguments are passed through untouched, so a `$` or
  # a space in an argument is data. For a raw command a shell is asked for
  # explicitly, which is the whole point of that form.
  defp process_launcher(%{argv: [program | rest]}, environment) do
    {setsid_path(),
     env_prefix(environment) ++
       ["sh", "-c", group_preamble() <> "exec \"$0\" \"$@\"", program] ++ rest}
  end

  defp process_launcher(%{command: command}, environment) do
    {setsid_path(), env_prefix(environment) ++ ["sh", "-c", group_preamble() <> command]}
  end

  # Concept: the child's environment is built, not filtered.
  #
  # Technical depth: a port's `env:` option adds to the inherited environment
  # rather than replacing it, so clearing one name there leaves every other
  # variable of this operating-system process readable by the child. `env -i`
  # starts from nothing and takes only the assignments that follow it, which is
  # how the demonstration tools were always launched and is the construction the
  # operator documentation describes. Filtering would need this executor to know
  # every name worth removing; constructing needs it to know only the names worth
  # keeping.
  defp env_prefix(environment) do
    ["/usr/bin/env", "-i"] ++
      for {name, value} <- environment,
          value != false,
          do: List.to_string(name) <> "=" <> List.to_string(value)
  end

  # The child announces the group it actually leads before doing anything else,
  # so termination confirms a group the operating system assigned rather than one
  # this executor assumed.
  defp group_preamble, do: "printf 'loopex-pgid:%s\\n' \"$(ps -o pgid= -p $$ | tr -d ' ')\" >&2; "

  defp setsid_path do
    case System.find_executable("setsid") do
      nil -> "/usr/bin/env"
      path -> path
    end
  end

  defp collect_output(port, os_pid, deadline, acc, options, job) do
    remaining = deadline - System.system_time(:millisecond)

    if remaining <= 0 do
      group = group_of(acc, os_pid)
      terminate_group(group)
      forget_inflight(job.job_id)
      {:cancelled, strip_group_line(acc), group}
    else
      receive do
        {^port, {:data, chunk}} ->
          notify(options, {:executor_progress, job.job_id, byte_size(chunk)})
          combined = acc <> chunk
          register_inflight(job.job_id, group_of(combined, os_pid))
          collect_output(port, os_pid, deadline, combined, options, job)

        {^port, {:exit_status, _status}} ->
          forget_inflight(job.job_id)
          {:completed, strip_group_line(acc)}
      after
        min(remaining, 50) ->
          collect_output(port, os_pid, deadline, acc, options, job)
      end
    end
  end

  defp group_of(output, os_pid) do
    case Regex.run(~r/loopex-pgid:(\d+)/, output) do
      [_all, group] -> String.to_integer(group)
      nil -> os_pid
    end
  end

  defp strip_group_line(output), do: String.replace(output, ~r/loopex-pgid:\d+\n/, "")

  # Concept: end the group, not the leader.
  #
  # Technical depth: a negative pid names the process group. TERM first so a
  # child can finish a write, then KILL, because a command interrupted mid-write
  # leaves a half-written file the operator has to notice for themselves.
  defp terminate_group(group) when is_integer(group) and group > 1 do
    _ = System.cmd("/bin/kill", ["-TERM", "-#{group}"], stderr_to_stdout: true)
    Process.sleep(50)
    _ = System.cmd("/bin/kill", ["-KILL", "-#{group}"], stderr_to_stdout: true)
    :ok
  end

  defp terminate_group(_group), do: :ok

  # Concept: cleanup is confirmed by looking, not by assuming the signal worked.
  #
  # Technical depth: the confirmation is that no member of the group remains. A
  # descendant that left the group is outside both the kill and this check, which
  # is stated rather than papered over: the claim is about the group this
  # executor owns and no wider.
  defp confirm_group_terminated(group) when is_integer(group) and group > 1 do
    case System.cmd("/bin/ps", ["-o", "pid=", "-g", Integer.to_string(group)],
           stderr_to_stdout: true
         ) do
      {output, _status} -> String.trim(output) == ""
    end
  rescue
    _error -> false
  end

  defp confirm_group_terminated(_group), do: true

  defp read_for_edit(resolved) do
    case File.read(resolved) do
      {:ok, content} -> {:ok, content}
      {:error, reason} -> {:error, reason}
    end
  end

  defp occurrences(content, needle) when needle != "" do
    content |> String.split(needle) |> length() |> Kernel.-(1)
  end

  defp occurrences(_content, _needle), do: 0

  # Concept: point at the nearest thing that looks like what was asked for.
  #
  # Technical depth: matching the first line of the requested text against the
  # file's lines finds the common case — the model had the right place and the
  # wrong whitespace or a stale neighbouring line — without pretending to be a
  # diff engine.
  defp nearest_hint(content, old) do
    first = old |> String.split("\n", parts: 2) |> List.first() |> String.trim()

    if first == "" do
      "The file has #{content |> String.split("\n") |> length()} lines."
    else
      # Concept: the closest line, not merely one that contains the whole request.
      #
      # Technical depth: an exact containment check finds nothing in the common
      # case, because the model's text differs from the file's by exactly the
      # detail that made the edit fail. Ranking by shared prefix points at the
      # line it probably meant, which is what turns a blank failure into one
      # retry rather than several.
      content
      |> String.split("\n")
      |> Enum.reject(&(String.trim(&1) == ""))
      |> Enum.max_by(&shared_prefix_length(String.trim(&1), first), fn -> nil end)
      |> case do
        nil -> "The file is empty."
        line -> "The closest line is #{inspect(String.trim(line))}."
      end
    end
  end

  defp shared_prefix_length(left, right) do
    left
    |> String.graphemes()
    |> Enum.zip(String.graphemes(right))
    |> Enum.take_while(fn {a, b} -> a == b end)
    |> length()
  end

  defp containment_message({:path_escapes_workspace, path}),
    do: "refused: #{path} resolves outside the workspace root"

  defp containment_message({:invalid_path, _path}), do: "refused: the path is not a string"
  defp containment_message(reason), do: "refused: #{inspect(reason)}"

  defp truncation_marker(kept, total) do
    kept <>
      "\n\n[loopex: output truncated. #{byte_size(kept)} of #{total} bytes shown.]"
  end

  # Concept: a tool that did something says what it did.
  #
  # Technical depth: this demonstration tool wrote its file and printed nothing,
  # so the model received an empty result. Under M1's fixed two turns nothing
  # depended on the model understanding it. Under M2's real loop it does: a
  # result that says nothing is indistinguishable from a call that failed
  # silently, and a real provider answered it by writing the same file again,
  # several times, in a live recovery trace. The four operator-facing coding
  # tools already report what they did; this one now does too.
  defp launcher_arguments(%{path: path, content: content, delay_ms: delay}) do
    script =
      "if [ \"${#{@credential_name}+x}\" = x ]; then exit 97; fi; " <>
        "delay=$1; target=$2; content=$3; " <>
        "if [ \"$delay\" -gt 0 ]; then sleep \"$delay\"; fi; " <>
        "umask 077; printf %s \"$content\" > \"$target\"; " <>
        "printf 'wrote the requested content to %s' \"$target\""

    [
      "-i",
      @search_path_name <> "=" <> @search_path_value,
      "/bin/sh",
      "-c",
      script,
      "loopex-controlled-tool",
      Integer.to_string(div(delay + 999, 1_000)),
      path,
      content
    ]
  end

  defp await_port(port, monitor, lease_pid, output) do
    receive do
      {^port, {:data, data}} ->
        combined = output <> data

        if byte_size(combined) <= @max_output_bytes do
          await_port(port, monitor, lease_pid, combined)
        else
          Port.close(port)
          {:failed_output_limit, binary_part(combined, 0, @max_output_bytes)}
        end

      {^port, {:exit_status, 0}} ->
        {:completed, output}

      {^port, {:exit_status, status}} ->
        {{:failed, status}, output}

      {:DOWN, ^monitor, :process, ^lease_pid, _reason} ->
        if Port.info(port), do: Port.close(port)
        {:cancelled_workspace_lease_lost, output}
    end
  end

  defp receipt(state, job, tool, outcome, output, environment) do
    %{
      protocol_version: 1,
      job_id: job.job_id,
      operation_id: job.operation_id,
      attempt: job.attempt,
      session_id: job.session_id,
      run_id: job.run_id,
      turn_id: job.turn_id,
      tool_call_id: job.tool_call_id,
      session_epoch_at_dispatch: job.origin_session_epoch,
      executor_epoch: state.epoch,
      executor_identity: state.identity,
      canonical_request_digest: job.canonical_request_digest,
      fencing_token: state.fencing_token,
      tool_id: tool.id,
      tool_version: tool.version,
      outcome: outcome,
      output: output,
      progress_count: 0,
      observed_at_ms: System.system_time(:millisecond),
      child_environment_names: environment_names(environment),
      provider_credential_present: credential_present?(environment)
    }
  end

  defp retain_receipt(root, receipt) do
    path = receipt_path(root, receipt.job_id)
    temporary = path <> ".tmp-" <> Integer.to_string(System.unique_integer([:positive]))
    bytes = :erlang.term_to_binary(receipt, [:deterministic])

    result =
      with {:ok, file} <- File.open(temporary, [:write, :binary, :exclusive]),
           :ok <- IO.binwrite(file, bytes),
           :ok <- :file.sync(file),
           :ok <- File.close(file),
           :ok <- File.rename(temporary, path) do
        :ok
      end

    if result != :ok, do: File.rm(temporary)
    result
  end

  defp read_receipt(_root, ""), do: :absent

  defp read_receipt(root, job_id) do
    case File.read(receipt_path(root, job_id)) do
      {:ok, bytes} -> decode_receipt(bytes, job_id)
      {:error, :enoent} -> :absent
      {:error, reason} -> {:error, {:receipt_read_failed, reason}}
    end
  end

  defp decode_receipt(bytes, job_id) do
    receipt = :erlang.binary_to_term(bytes, [:safe])

    if is_map(receipt) and Map.get(receipt, :job_id) == job_id,
      do: {:ok, receipt},
      else: {:error, :invalid_retained_receipt}
  rescue
    _error -> {:error, :invalid_retained_receipt}
  end

  defp receipt_path(root, job_id) do
    name = :crypto.hash(:sha256, job_id) |> Base.encode16(case: :lower)
    Path.join(root, name <> ".receipt")
  end

  defp notify(options, message) do
    case Keyword.get(options, :notify) do
      pid when is_pid(pid) -> send(pid, message)
      _other -> :ok
    end
  end
end
