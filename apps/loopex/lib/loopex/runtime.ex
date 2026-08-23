defmodule Loopex.Runtime do
  @moduledoc """
  ## Concept

  An explicit supervised Loopex instance. Each runtime carries its own Store,
  session ownership, attachment queues, and transient sinks. Callers retain the
  returned reference; no registered name, application environment value, or
  process-global default can stand in for it.

  ## Technical depth

  The opaque reference contains only the root supervisor pid and an unforgeable
  runtime-local token. Every operation resolves the current unnamed child from
  that supervisor and presents the token to runtime control. This lets a
  supervised child restart without turning a stale child pid into the public
  instance identity.

  The root uses `:rest_for_one`: losing runtime control also removes every
  session and attachment process; losing the session supervisor removes the
  dispatcher; losing only the dispatcher preserves coordinators and durable
  truth. Session and attachment recovery always comes from the explicit Store.
  """

  alias Loopex.Attachment
  alias Loopex.Runtime.SessionCoordinator
  alias Loopex.Runtime.Supervisor, as: RuntimeSupervisor
  alias Loopex.Store

  @max_identifier_bytes 256
  @max_attachment_capacity 65_536

  @typedoc """
  ## Concept

  The caller-held identity of one independently configured runtime.

  ## Technical depth

  The pid and reference token are transient BEAM values. They never enter a
  Store transaction, public event, snapshot, progress item, or diagnostic.
  """
  @opaque t :: %__MODULE__{supervisor: pid(), token: reference()}
  defstruct [:supervisor, :token]

  @typedoc """
  ## Concept

  Explicit configuration for one runtime instance.

  ## Technical depth

  A Store handle and bounded runtime ID are required. Attachment capacity is a
  positive finite limit. Optional sinks receive best-effort transient messages
  and are not supervised, persisted, or consulted for runtime behavior.
  """
  @type option ::
          {:runtime_id, binary()}
          | {:store, Store.t()}
          | {:attachment_capacity, pos_integer()}
          | {:progress_to, pid() | nil}
          | {:diagnostics_to, pid() | nil}
          | {:model, map() | nil}
          | {:executor, map() | nil}
          | {:tool, map() | nil}
          | {:grant_decision, term()}
          | {:fault_to, pid() | nil}

  @doc """
  ## Concept

  Starts one unnamed supervised runtime from explicit configuration.

  ## Technical depth

  Validation completes before any child starts. The returned reference is the
  sole route to instance-owned processes; it is not registered anywhere.
  """
  @spec start_link([option()]) :: {:ok, t()} | {:error, term()}
  def start_link(options) when is_list(options) do
    with {:ok, configuration} <- validate_options(options) do
      token = make_ref()

      case RuntimeSupervisor.start_link(Keyword.put(configuration, :token, token)) do
        {:ok, supervisor} -> {:ok, %__MODULE__{supervisor: supervisor, token: token}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  def start_link(_options), do: {:error, :invalid_runtime_options}

  @doc """
  ## Concept

  Stops this runtime and every process it owns.

  ## Technical depth

  The Store handle itself may be hosted outside the runtime tree. Stopping the
  runtime removes coordinators and ephemeral attachments but never fabricates a
  Store mutation or deletes durable history.
  """
  @spec stop(t()) :: :ok | {:error, :runtime_unavailable}
  def stop(%__MODULE__{supervisor: supervisor}) when is_pid(supervisor) do
    try do
      Supervisor.stop(supervisor, :normal)
    catch
      :exit, _reason -> {:error, :runtime_unavailable}
    end
  end

  def stop(_runtime), do: {:error, :runtime_unavailable}

  @doc """
  ## Concept

  Reports whether the explicit runtime tree is currently reachable.

  ## Technical depth

  Health is a transient observation. It does not infer another runtime when a
  supplied reference is missing, malformed, foreign, or stopped.
  """
  @spec alive?(t()) :: boolean()
  def alive?(%__MODULE__{} = runtime), do: match?({:ok, _configuration}, configuration(runtime))
  def alive?(_runtime), do: false

  @doc """
  ## Concept

  Returns this runtime's non-secret explicit configuration.

  ## Technical depth

  The Store handle, runtime token, pids, and transient sinks are omitted. The
  result is informational and grants no session or mutation authority.
  """
  @spec configuration(t()) :: {:ok, map()} | {:error, :runtime_unavailable}
  def configuration(%__MODULE__{} = runtime),
    do: control_call(runtime, {:configuration, runtime.token})

  def configuration(_runtime), do: {:error, :runtime_unavailable}

  @doc false
  @spec create_session(t(), binary(), map()) :: {:ok, binary()} | {:error, term()}
  def create_session(%__MODULE__{} = runtime, command_id, genesis) do
    control_call(runtime, {:create_session, runtime.token, command_id, genesis}, :infinity)
  end

  def create_session(_runtime, _command_id, _genesis),
    do: {:error, :runtime_reference_required}

  @doc false
  @spec resume_session(t(), binary(), binary()) :: {:ok, binary()} | {:error, term()}
  def resume_session(%__MODULE__{} = runtime, session_id, command_id) do
    control_call(runtime, {:resume_session, runtime.token, session_id, command_id}, :infinity)
  end

  def resume_session(_runtime, _session_id, _command_id),
    do: {:error, :runtime_reference_required}

  @doc false
  @spec attach(t(), binary(), keyword()) :: {:ok, Attachment.t()} | {:error, term()}
  def attach(%__MODULE__{} = runtime, session_id, options) when is_list(options) do
    case control_call(runtime, {:begin_attach, runtime.token, session_id, options}) do
      {:ok, attachment} ->
        build_attachment(runtime, session_id, attachment)

      {:new, generation, validated_options} ->
        finish_attachment(runtime, session_id, generation, validated_options)

      {:error, reason} ->
        {:error, reason}
    end
  end

  def attach(_runtime, _session_id, _options), do: {:error, :runtime_reference_required}

  @doc false
  @spec command(Attachment.t(), map()) :: {:accepted, binary()} | {:error, term()}
  def command(%Attachment{} = attachment, command) when is_map(command) do
    with {:ok, runtime, session_id, attachment_id, incarnation_id} <-
           Attachment.routing(attachment),
         {:ok, coordinator, owner} <-
           control_call(
             runtime,
             {:route_command, runtime.token, session_id, attachment_id, incarnation_id}
           ),
         reply <- SessionCoordinator.command(coordinator, owner, command) do
      reply
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def command(_attachment, _command), do: {:error, :attachment_required}

  @doc false
  @spec next_event(Attachment.t()) ::
          {:ok, Store.outbox_event()} | {:disconnected, non_neg_integer()} | {:error, term()}
  def next_event(%Attachment{} = attachment) do
    with {:ok, runtime, session_id, attachment_id, incarnation_id} <-
           Attachment.routing(attachment) do
      dispatcher_call(
        runtime,
        {:next_event, runtime.token, session_id, attachment_id, incarnation_id},
        :infinity
      )
    end
  end

  def next_event(_attachment), do: {:error, :attachment_required}

  @doc false
  @spec attachment_status(Attachment.t()) :: {:ok, map()} | {:error, term()}
  def attachment_status(%Attachment{} = attachment) do
    with {:ok, runtime, session_id, attachment_id, incarnation_id} <-
           Attachment.routing(attachment) do
      dispatcher_call(
        runtime,
        {:attachment_status, runtime.token, session_id, attachment_id, incarnation_id}
      )
    end
  end

  def attachment_status(_attachment), do: {:error, :attachment_required}

  @doc false
  @spec progress(Attachment.t(), term()) :: :ok | {:error, term()}
  def progress(%Attachment{} = attachment, item) do
    with {:ok, runtime, session_id, attachment_id, incarnation_id} <-
           Attachment.routing(attachment) do
      dispatcher_call(
        runtime,
        {:progress, runtime.token, session_id, attachment_id, incarnation_id, item}
      )
    end
  end

  def progress(_attachment, _item), do: {:error, :attachment_required}

  @doc false
  @spec diagnostic(t(), term()) :: :ok | {:error, term()}
  def diagnostic(%__MODULE__{} = runtime, item) do
    dispatcher_call(runtime, {:diagnostic, runtime.token, item})
  end

  def diagnostic(_runtime, _item), do: {:error, :runtime_reference_required}

  @doc false
  @spec session_status(t(), binary()) :: {:ok, map()} | {:error, term()}
  def session_status(%__MODULE__{} = runtime, session_id) do
    control_call(runtime, {:session_status, runtime.token, session_id})
  end

  def session_status(_runtime, _session_id), do: {:error, :runtime_reference_required}

  @doc false
  @spec reconciliation_query(Attachment.t()) :: {:ok, map()} | {:error, term()}
  def reconciliation_query(%Attachment{} = attachment) do
    with {:ok, runtime, session_id, attachment_id, incarnation_id} <-
           Attachment.routing(attachment),
         {:ok, coordinator, owner} <-
           control_call(
             runtime,
             {:route_command, runtime.token, session_id, attachment_id, incarnation_id}
           ) do
      SessionCoordinator.reconciliation_query(coordinator, owner)
    end
  end

  def reconciliation_query(_attachment), do: {:error, :attachment_required}

  @doc false
  @spec reconcile(Attachment.t(), map()) :: :ok | {:error, term()}
  def reconcile(%Attachment{} = attachment, response) when is_map(response) do
    with {:ok, runtime, session_id, attachment_id, incarnation_id} <-
           Attachment.routing(attachment),
         {:ok, coordinator, owner} <-
           control_call(
             runtime,
             {:route_command, runtime.token, session_id, attachment_id, incarnation_id}
           ) do
      SessionCoordinator.reconcile(coordinator, owner, response)
    end
  end

  def reconcile(_attachment, _response), do: {:error, :attachment_required}

  @doc false
  @spec children(t()) :: {:ok, map()} | {:error, :runtime_unavailable}
  def children(%__MODULE__{supervisor: supervisor}) do
    RuntimeSupervisor.children(supervisor)
  end

  def children(_runtime), do: {:error, :runtime_unavailable}

  defp control_call(%__MODULE__{supervisor: supervisor}, message, timeout \\ 5_000) do
    with {:ok, %{control: control}} <- RuntimeSupervisor.children(supervisor) do
      safe_call(control, message, timeout)
    else
      _other -> {:error, :runtime_unavailable}
    end
  end

  defp dispatcher_call(%__MODULE__{supervisor: supervisor}, message, timeout \\ 5_000) do
    with {:ok, %{dispatcher: dispatcher}} <- RuntimeSupervisor.children(supervisor) do
      safe_call(dispatcher, message, timeout)
    else
      _other -> {:error, :runtime_unavailable}
    end
  end

  defp safe_call(server, message, timeout) do
    try do
      GenServer.call(server, message, timeout)
    catch
      :exit, _reason -> {:error, :runtime_unavailable}
    end
  end

  defp finish_attachment(runtime, session_id, generation, options) do
    case dispatcher_call(runtime, {:attach, runtime.token, session_id, options}, :infinity) do
      {:ok, attachment} ->
        case control_call(
               runtime,
               {:finish_attach, runtime.token, session_id, generation, options, attachment}
             ) do
          {:ok, installed} -> build_attachment(runtime, session_id, installed)
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_attachment(runtime, session_id, attachment) do
    {:ok,
     Attachment.from_runtime(
       runtime,
       session_id,
       attachment.id,
       attachment.incarnation_id,
       attachment.snapshot
     )}
  end

  defp validate_options(options) do
    with {:ok, validated} <-
           Keyword.validate(options,
             runtime_id: nil,
             store: nil,
             attachment_capacity: 64,
             progress_to: nil,
             diagnostics_to: nil,
             model: nil,
             executor: nil,
             tool: nil,
             grant_decision: nil,
             fault_to: nil
           ),
         {:ok, runtime_id} <- fetch_identifier(validated, :runtime_id),
         {:ok, %Store{} = store} <- Keyword.fetch(validated, :store),
         {:ok, attachment_capacity} <- validate_capacity(validated[:attachment_capacity]),
         {:ok, progress_to} <- validate_sink(validated[:progress_to]),
         {:ok, diagnostics_to} <- validate_sink(validated[:diagnostics_to]),
         {:ok, model} <- validate_model(validated[:model]),
         {:ok, executor} <- validate_executor(validated[:executor]),
         {:ok, tool} <- validate_tool(validated[:tool]),
         {:ok, grant_decision} <- validate_grant_decision(validated[:grant_decision]),
         {:ok, fault_to} <- validate_sink(validated[:fault_to]),
         :ok <- validate_loop_configuration(model, executor, tool, grant_decision) do
      {:ok,
       [
         runtime_id: runtime_id,
         store: store,
         attachment_capacity: attachment_capacity,
         progress_to: progress_to,
         diagnostics_to: diagnostics_to,
         model: model,
         executor: executor,
         tool: tool,
         grant_decision: grant_decision,
         fault_to: fault_to
       ]}
    else
      _other -> {:error, :invalid_runtime_options}
    end
  end

  defp fetch_identifier(options, key) do
    case Keyword.fetch(options, key) do
      {:ok, value}
      when is_binary(value) and byte_size(value) > 0 and byte_size(value) <= @max_identifier_bytes ->
        {:ok, value}

      _other ->
        {:error, :invalid_identifier}
    end
  end

  defp validate_capacity(value)
       when is_integer(value) and value > 0 and value <= @max_attachment_capacity,
       do: {:ok, value}

  defp validate_capacity(_value), do: {:error, :invalid_attachment_capacity}

  defp validate_sink(nil), do: {:ok, nil}
  defp validate_sink(pid) when is_pid(pid), do: {:ok, pid}
  defp validate_sink(_sink), do: {:error, :invalid_sink}

  defp validate_model(nil), do: {:ok, nil}

  defp validate_model(%{module: module, model: model, options: options} = configuration)
       when is_atom(module) and is_binary(model) and byte_size(model) > 0 and is_list(options) do
    if Map.keys(configuration) |> Enum.sort() == [:model, :module, :options],
      do: {:ok, configuration},
      else: {:error, :invalid_model_configuration}
  end

  defp validate_model(_configuration), do: {:error, :invalid_model_configuration}

  defp validate_executor(
         %{
           module: module,
           reference: reference,
           identity: identity,
           epoch: epoch,
           fencing_token: fencing_token,
           workspace_ref: workspace_ref,
           workspace_lease: workspace_lease
         } = configuration
       )
       when is_atom(module) and is_binary(identity) and is_integer(epoch) and epoch >= 0 and
              is_integer(fencing_token) and fencing_token >= 0 and is_binary(workspace_ref) and
              is_binary(workspace_lease) do
    expected = [
      :epoch,
      :fencing_token,
      :identity,
      :module,
      :reference,
      :workspace_lease,
      :workspace_ref
    ]

    if Map.keys(configuration) |> Enum.sort() == expected and not is_nil(reference),
      do: {:ok, configuration},
      else: {:error, :invalid_executor_configuration}
  end

  defp validate_executor(nil), do: {:ok, nil}
  defp validate_executor(_configuration), do: {:error, :invalid_executor_configuration}

  defp validate_tool(
         %{
           "name" => name,
           "description" => description,
           "input_schema" => input_schema,
           "tool_id" => tool_id,
           "tool_version" => tool_version,
           "effect_class" => effect_class
         } = tool
       )
       when is_binary(name) and is_binary(description) and is_map(input_schema) and
              is_binary(tool_id) and is_binary(tool_version) and is_binary(effect_class) do
    if Enum.all?([name, description, tool_id, tool_version, effect_class], &(byte_size(&1) > 0)),
      do: {:ok, tool},
      else: {:error, :invalid_tool_configuration}
  end

  defp validate_tool(nil), do: {:ok, nil}
  defp validate_tool(_tool), do: {:error, :invalid_tool_configuration}

  defp validate_grant_decision(nil), do: {:ok, nil}
  defp validate_grant_decision({:host_policy, :allow} = decision), do: {:ok, decision}
  defp validate_grant_decision(_decision), do: {:error, :invalid_grant_decision}

  defp validate_loop_configuration(nil, nil, nil, nil), do: :ok

  defp validate_loop_configuration(model, executor, tool, {:host_policy, :allow})
       when is_map(model) and is_map(executor) and is_map(tool),
       do: :ok

  defp validate_loop_configuration(_model, _executor, _tool, _decision),
    do: {:error, :incomplete_loop_configuration}
end
