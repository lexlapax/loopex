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
  alias Loopex.Executor.Local.WorkspaceLease

  @max_output_bytes 1_048_576
  @tool_version "1.0.0"
  @write_tool "loopex.demo.write"
  @wait_write_tool "loopex.demo.wait_write"
  @credential_name "LOOPEX_PROVIDER_API_KEY"

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
  @spec execute(t(), Executor.job_request(), Executor.grant(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def execute(executor, job, grant, options \\ [])
      when is_pid(executor) and is_map(job) and is_map(grant) and is_list(options) do
    GenServer.call(executor, {:execute, job, grant, options}, :infinity)
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

  def tool(_id), do: :error

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
         true <- job.deadline > System.system_time(:millisecond),
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

    notify(options, {:executor_process_started, job.job_id, tool.id, ["PATH"]})
    {outcome, output} = await_port(port, monitor, lease_pid, <<>>)
    Process.demonitor(monitor, [:flush])

    receipt(state, job, tool, outcome, output)
  end

  defp launcher_arguments(%{path: path, content: content, delay_ms: delay}) do
    script =
      "if [ \"${#{@credential_name}+x}\" = x ]; then exit 97; fi; " <>
        "delay=$1; target=$2; content=$3; " <>
        "if [ \"$delay\" -gt 0 ]; then sleep \"$delay\"; fi; " <>
        "umask 077; printf %s \"$content\" > \"$target\""

    [
      "-i",
      "PATH=/usr/bin:/bin",
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

  defp receipt(state, job, tool, outcome, output) do
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
      observed_at_ms: System.system_time(:millisecond),
      child_environment_names: ["PATH"],
      provider_credential_present: false
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
