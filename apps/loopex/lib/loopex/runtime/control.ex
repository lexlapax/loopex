defmodule Loopex.Runtime.Control do
  @moduledoc """
  ## Concept

  The serial runtime-local owner of session creation, current coordinator
  routing, and post-commit consequences. It makes a Store commit durable truth
  without letting the process that received its reply decide whether it is
  still the current owner.

  ## Technical depth

  Session creation uses one retained runtime-control `Store.OwnerLane` and does
  not cache a mapping before the transaction is terminal. Starting or resuming
  a coordinator is serialized here; the DynamicSupervisor child completes
  `advance_owner` before this process marks it active.

  `current_owner_post_commit_fence/3` is the single production gate after every
  ordinary session Store result. While this GenServer handles one message, the
  exact active generation and owner pair cannot be replaced concurrently. Only
  an admitted result installs only the runtime-local current cache and makes
  committed pending work visible through the current route. Public delivery
  reads the Store outbox independently; no reply-driven publication or
  Store-head read is inserted after commit.
  """

  use GenServer

  alias Loopex.Runtime.EventDispatcher
  alias Loopex.Runtime.SessionCoordinator
  alias Loopex.Runtime.Supervisor, as: RuntimeSupervisor
  alias Loopex.Owner
  alias Loopex.Store
  alias Loopex.Store.OwnerLane

  @max_identifier_bytes 256

  @doc """
  ## Concept

  Starts the unnamed control process for one runtime.

  ## Technical depth

  Configuration is already validated by `Loopex.Runtime`. The Store and token
  remain private process state and are redacted from OTP reports.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options) when is_list(options), do: GenServer.start_link(__MODULE__, options)

  @doc false
  @spec current_owner?(pid(), binary(), SessionCoordinator.owner()) :: boolean()
  def current_owner?(control, session_id, owner) do
    try do
      GenServer.call(control, {:current_owner, session_id, owner})
    catch
      :exit, _reason -> false
    end
  end

  @doc false
  @spec post_commit(pid(), binary(), SessionCoordinator.owner(), map(), map()) ::
          :ok | {:error, term()}
  def post_commit(control, session_id, owner, positions, receipt) do
    try do
      GenServer.call(
        control,
        {:post_commit, session_id, owner, positions, receipt},
        :infinity
      )
    catch
      :exit, _reason -> {:error, :runtime_unavailable}
    end
  end

  @impl GenServer
  def init(options) do
    {:ok,
     %{
       root: Keyword.fetch!(options, :root),
       token: Keyword.fetch!(options, :token),
       runtime_id: Keyword.fetch!(options, :runtime_id),
       store: Keyword.fetch!(options, :store),
       attachment_capacity: Keyword.fetch!(options, :attachment_capacity),
       model: Keyword.fetch!(options, :model),
       executor: Keyword.fetch!(options, :executor),
       tool: Keyword.fetch!(options, :tool),
       grant_decision: Keyword.fetch!(options, :grant_decision),
       fault_to: Keyword.fetch!(options, :fault_to),
       lane: OwnerLane.new(Keyword.fetch!(options, :store)),
       sessions: %{},
       monitor_to_session: %{},
       generation_counter: 0
     }}
  end

  @impl GenServer
  def handle_call({:configuration, token}, _from, state) do
    if token == state.token do
      configuration = %{
        runtime_id: state.runtime_id,
        attachment_capacity: state.attachment_capacity,
        model_configured: is_map(state.model),
        executor_identity: if(is_map(state.executor), do: state.executor.identity, else: nil)
      }

      {:reply, {:ok, configuration}, state}
    else
      {:reply, {:error, :runtime_unavailable}, state}
    end
  end

  def handle_call({:create_session, token, command_id, genesis}, _from, state) do
    if token == state.token do
      create_session(state, command_id, genesis)
    else
      {:reply, {:error, :runtime_unavailable}, state}
    end
  end

  def handle_call({:resume_session, token, session_id, command_id}, _from, state) do
    if token == state.token and valid_identifier?(session_id) and valid_identifier?(command_id) do
      case start_owner(state, session_id, succession_id("resume", session_id, command_id)) do
        {:ok, next} -> {:reply, {:ok, session_id}, next}
        {:error, reason, next} -> {:reply, {:error, reason}, next}
      end
    else
      {:reply, {:error, :invalid_session_id}, state}
    end
  end

  def handle_call(
        {:route_command, token, session_id, attachment_id, incarnation_id},
        _from,
        state
      ) do
    reply =
      with true <- token == state.token,
           {:ok, %{status: :active, coordinator: coordinator, owner: owner} = entry} <-
             Map.fetch(state.sessions, session_id),
           :ok <- current_attachment?(entry.attachment, attachment_id, incarnation_id),
           true <- Process.alive?(coordinator),
           {:ok, %{dispatcher: dispatcher}} <- RuntimeSupervisor.children(state.root),
           :ok <-
             EventDispatcher.validate(
               dispatcher,
               state.token,
               session_id,
               attachment_id,
               incarnation_id
             ) do
        {:ok, coordinator, owner}
      else
        _other -> {:error, :session_unavailable}
      end

    {:reply, reply, state}
  end

  def handle_call({:current_owner, session_id, owner}, _from, state) do
    {:reply, current_owner_post_commit_fence(state, session_id, owner) == :ok, state}
  end

  def handle_call({:post_commit, session_id, owner, positions, receipt}, _from, state) do
    case current_owner_post_commit_fence(state, session_id, owner) do
      :ok ->
        entry = Map.fetch!(state.sessions, session_id)

        if valid_post_commit?(positions, receipt) do
          next_entry = %{
            entry
            | journal_version: positions.journal_version,
              event_sequence: positions.event_sequence
          }

          next = %{state | sessions: Map.put(state.sessions, session_id, next_entry)}
          {:reply, :ok, next}
        else
          {:reply, {:error, :invalid_store_receipt}, state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:session_status, token, session_id}, _from, state) do
    reply =
      with true <- token == state.token,
           {:ok, %{status: :active, coordinator: coordinator, owner: owner}} <-
             Map.fetch(state.sessions, session_id) do
        SessionCoordinator.session_status(coordinator, owner)
      else
        _other -> {:error, :session_unavailable}
      end

    {:reply, reply, state}
  end

  def handle_call({:begin_attach, token, session_id, options}, _from, state) do
    if token == state.token do
      begin_attach(state, session_id, options)
    else
      {:reply, {:error, :runtime_unavailable}, state}
    end
  end

  def handle_call(
        {:finish_attach, token, session_id, generation, options, attachment},
        _from,
        state
      ) do
    if token == state.token do
      finish_attach(state, session_id, generation, options, attachment)
    else
      {:reply, {:error, :runtime_unavailable}, state}
    end
  end

  @impl GenServer
  def handle_cast({:owner_ready, coordinator, owner, durable}, state) do
    case Map.get(state.sessions, durable.session_id) do
      %{
        status: :acquiring,
        coordinator: ^coordinator,
        generation: generation,
        previous: previous
      } = entry
      when generation == owner.generation ->
        active =
          entry
          |> Map.drop([:generation, :previous, :durable])
          |> Map.merge(%{
            status: :active,
            owner: owner,
            journal_version: durable.journal_version,
            event_sequence: durable.event_sequence,
            attachment: nil
          })

        next = %{state | sessions: Map.put(state.sessions, durable.session_id, active)}
        notify_superseded(previous, owner.generation)
        EventDispatcher.invalidate(state.root, durable.session_id)
        {:noreply, next}

      %{status: :active, coordinator: ^coordinator, owner: ^owner} ->
        {:noreply, state}

      _other ->
        GenServer.cast(coordinator, {:superseded, "not-current"})
        {:noreply, state}
    end
  end

  @impl GenServer
  def handle_info({:DOWN, reference, :process, pid, _reason}, state) do
    case Map.pop(state.monitor_to_session, reference) do
      {nil, _monitors} ->
        {:noreply, state}

      {session_id, monitors} ->
        sessions =
          case Map.fetch(state.sessions, session_id) do
            {:ok, %{coordinator: ^pid} = entry} ->
              Map.put(state.sessions, session_id, %{entry | status: :unavailable})

            _other ->
              state.sessions
          end

        {:noreply, %{state | sessions: sessions, monitor_to_session: monitors}}
    end
  end

  @impl GenServer
  def format_status(status) do
    status
    |> Map.put(:state, :redacted_runtime_control_state)
    |> Map.put(:message, :redacted_runtime_control_message)
    |> Map.put(:reason, :redacted_runtime_control_reason)
    |> Map.put(:log, [])
  end

  defp create_session(state, command_id, genesis) do
    with true <- valid_identifier?(command_id),
         {:ok, transaction} <- Store.create_session(state.runtime_id, command_id, genesis) do
      {outcome, lane} = resolve_transaction(state.lane, transaction)
      state = %{state | lane: lane}

      case outcome do
        {:committed, ^command_id, %{type: :create_session, session_id: session_id}} ->
          case Map.fetch(state.sessions, session_id) do
            {:ok, %{status: :active}} ->
              {:reply, {:ok, session_id}, state}

            _other ->
              case start_owner(state, session_id, succession_id("create", session_id, command_id)) do
                {:ok, next} -> {:reply, {:ok, session_id}, next}
                {:error, reason, next} -> {:reply, {:error, reason}, next}
              end
          end

        {:not_committed, reason} ->
          {:reply, {:error, reason}, state}

        {:commit_unknown, _tx_id} ->
          {:reply, {:error, :commit_unknown}, state}

        {:fenced, :commit_unknown} ->
          {:reply, {:error, :commit_unknown}, state}
      end
    else
      _other -> {:reply, {:error, :invalid_session_creation}, state}
    end
  end

  defp start_owner(state, session_id, succession_id) do
    case Map.get(state.sessions, session_id) do
      %{status: :acquiring} ->
        {:error, :owner_acquiring, state}

      _other ->
        do_start_owner(state, session_id, succession_id)
    end
  end

  defp do_start_owner(state, session_id, succession_id) do
    with {:ok, %{sessions: session_supervisor, workers: workers}} <-
           RuntimeSupervisor.children(state.root) do
      counter = state.generation_counter + 1
      generation = fresh_id("generation", state.runtime_id, counter)

      prior_tx_id =
        case Map.get(state.sessions, session_id) do
          %{owner: %{transaction_id: transaction_id}} when is_binary(transaction_id) ->
            transaction_id

          _other ->
            nil
        end

      options = [
        control: self(),
        store: state.store,
        session_id: session_id,
        generation: generation,
        succession_id: succession_id,
        prior_tx_id: prior_tx_id,
        workers: workers,
        model: state.model,
        executor: state.executor,
        tool: state.tool,
        grant_decision: state.grant_decision,
        fault_to: state.fault_to
      ]

      case DynamicSupervisor.start_child(session_supervisor, {SessionCoordinator, options}) do
        {:ok, coordinator} ->
          activate_owner(state, session_id, generation, coordinator, counter)

        {:error, reason} ->
          unavailable = %{status: :unavailable, durable: nil}

          next = %{
            state
            | sessions: Map.put(state.sessions, session_id, unavailable),
              generation_counter: counter
          }

          {:error, normalize_start_error(reason), next}
      end
    else
      _other -> {:error, :runtime_unavailable, state}
    end
  end

  defp activate_owner(state, session_id, generation, coordinator, counter) do
    case SessionCoordinator.describe(coordinator) do
      {:ok, %{generation: ^generation} = owner, durable} ->
        old = Map.get(state.sessions, session_id)
        monitor = Process.monitor(coordinator)

        entry = %{
          status: :active,
          coordinator: coordinator,
          owner: owner,
          journal_version: durable.journal_version,
          event_sequence: durable.event_sequence,
          attachment: nil,
          monitor: monitor
        }

        next = %{
          state
          | sessions: Map.put(state.sessions, session_id, entry),
            monitor_to_session: Map.put(state.monitor_to_session, monitor, session_id),
            generation_counter: counter
        }

        notify_superseded(old, generation)
        EventDispatcher.invalidate(state.root, session_id)
        {:ok, next}

      {:error, :owner_acquiring} ->
        monitor = Process.monitor(coordinator)

        entry = %{
          status: :acquiring,
          coordinator: coordinator,
          generation: generation,
          previous: Map.get(state.sessions, session_id),
          monitor: monitor,
          durable: nil
        }

        next = %{
          state
          | sessions: Map.put(state.sessions, session_id, entry),
            monitor_to_session: Map.put(state.monitor_to_session, monitor, session_id),
            generation_counter: counter
        }

        {:error, :owner_acquiring, next}

      _other ->
        Process.exit(coordinator, :shutdown)
        {:error, :owner_recovery_failed, state}
    end
  end

  defp notify_superseded(%{coordinator: coordinator}, generation) when is_pid(coordinator),
    do: GenServer.cast(coordinator, {:superseded, generation})

  defp notify_superseded(_old, _generation), do: :ok

  defp begin_attach(state, session_id, options) when is_list(options) do
    with {:ok, entry} <- Map.fetch(state.sessions, session_id),
         true <- entry.status == :active,
         {:ok, attach_options} <- validate_attach_options(options),
         :new <- attachment_repetition(state, session_id, entry, attach_options) do
      {:reply, {:new, entry.owner.generation, attach_options}, state}
    else
      {:same, response} -> {:reply, {:ok, response}, state}
      :conflict -> {:reply, {:error, :attachment_request_conflict}, state}
      :error -> {:reply, {:error, :session_unavailable}, state}
      false -> {:reply, {:error, :session_unavailable}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp begin_attach(state, _session_id, _options),
    do: {:reply, {:error, :invalid_attachment_options}, state}

  defp finish_attach(
         state,
         session_id,
         generation,
         options,
         %{id: id, incarnation_id: incarnation_id, snapshot: snapshot} = attachment
       )
       when is_binary(id) and is_binary(incarnation_id) and is_map(snapshot) do
    with {:ok, %{status: :active, owner: %{generation: ^generation}} = entry} <-
           Map.fetch(state.sessions, session_id),
         {:ok, attach_options} <- validate_attach_options(options),
         {:ok, %{dispatcher: dispatcher}} <- RuntimeSupervisor.children(state.root),
         :ok <-
           EventDispatcher.validate(
             dispatcher,
             state.token,
             session_id,
             id,
             incarnation_id
           ) do
      current_attachment = %{
        status: :active,
        id: id,
        incarnation_id: incarnation_id,
        request_id: attach_options[:request_id],
        binding: attachment_binding(attach_options),
        response: attachment
      }

      next_entry = %{entry | attachment: current_attachment}
      next = %{state | sessions: Map.put(state.sessions, session_id, next_entry)}
      {:reply, {:ok, attachment}, next}
    else
      _other -> {:reply, {:error, :attachment_superseded}, state}
    end
  end

  defp finish_attach(state, _session_id, _generation, _options, _attachment),
    do: {:reply, {:error, :invalid_attachment}, state}

  defp validate_attach_options(options) do
    defaults = [
      after_event_sequence: nil,
      request_id: nil,
      client_id: nil,
      attachment_key: nil
    ]

    with {:ok, validated} <- Keyword.validate(options, defaults),
         :ok <- validate_optional_cursor(validated[:after_event_sequence]),
         :ok <- validate_optional_identifier(validated[:request_id]),
         :ok <- validate_optional_identifier(validated[:client_id]),
         :ok <- validate_optional_identifier(validated[:attachment_key]) do
      {:ok, validated}
    else
      _other -> {:error, :invalid_attachment_options}
    end
  end

  defp attachment_repetition(_state, _session_id, %{attachment: nil}, _options), do: :new

  defp attachment_repetition(state, session_id, %{attachment: current}, options) do
    request_id = options[:request_id]
    binding = attachment_binding(options)

    cond do
      is_nil(request_id) ->
        :new

      current.request_id == request_id and current.binding == binding ->
        if live_attachment?(state, session_id, current) do
          {:same, current.response}
        else
          :new
        end

      current.request_id == request_id ->
        :conflict

      true ->
        :new
    end
  end

  defp live_attachment?(state, session_id, current) do
    with {:ok, %{dispatcher: dispatcher}} <- RuntimeSupervisor.children(state.root),
         :ok <-
           EventDispatcher.validate(
             dispatcher,
             state.token,
             session_id,
             current.id,
             current.incarnation_id
           ) do
      true
    else
      _other -> false
    end
  end

  defp attachment_binding(options) do
    {
      options[:request_id],
      options[:client_id],
      options[:attachment_key],
      options[:after_event_sequence]
    }
  end

  defp current_owner_post_commit_fence(state, session_id, owner) do
    current = Map.get(state.sessions, session_id)

    case Owner.current_owner_post_commit_fence(current, owner) do
      :ok ->
        if Process.alive?(current.coordinator), do: :ok, else: {:error, :superseded_owner}

      {:error, :superseded_owner} = error ->
        error
    end
  end

  defp current_attachment?(
         %{status: :active, id: attachment_id, incarnation_id: incarnation_id},
         attachment_id,
         incarnation_id
       ),
       do: :ok

  defp current_attachment?(_attachment, _attachment_id, _incarnation_id),
    do: {:error, :stale_attachment}

  defp valid_post_commit?(
         %{journal_version: journal, event_sequence: event},
         %{
           type: :session_commit,
           journal_versions: %{last: journal}
         } = receipt
       )
       when is_integer(journal) and journal > 0 and is_integer(event) and event >= 0 do
    event_receipt_matches?(event, receipt)
  end

  defp valid_post_commit?(_positions, _receipt), do: false

  defp event_receipt_matches?(_event, %{event_sequences: nil}), do: true

  defp event_receipt_matches?(event, %{event_sequences: %{first: first, last: event}}),
    do: is_integer(first) and first > 0 and first <= event

  defp event_receipt_matches?(_event, _receipt), do: false

  defp resolve_transaction(lane, transaction) do
    case OwnerLane.transact(lane, transaction) do
      {{:commit_unknown, _tx_id}, next_lane} -> OwnerLane.transact(next_lane, transaction)
      result -> result
    end
  end

  defp fresh_id(namespace, scope, counter) do
    bytes = :erlang.term_to_binary([namespace, scope, counter, make_ref()], [:deterministic])
    encoded = :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
    String.replace(namespace, "-", "_") <> "_" <> binary_part(encoded, 0, 30)
  end

  defp succession_id(kind, session_id, command_id) do
    bytes =
      :erlang.term_to_binary(["loopex_owner_operation_v1", kind, session_id, command_id], [
        :deterministic
      ])

    encoded = :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
    "succession_" <> binary_part(encoded, 0, 40)
  end

  defp normalize_start_error({:shutdown, reason}), do: normalize_start_error(reason)
  defp normalize_start_error(reason) when is_atom(reason), do: reason
  defp normalize_start_error(_reason), do: :owner_start_failed

  defp valid_identifier?(value),
    do: is_binary(value) and byte_size(value) > 0 and byte_size(value) <= @max_identifier_bytes

  defp validate_optional_identifier(nil), do: :ok

  defp validate_optional_identifier(value),
    do: if(valid_identifier?(value), do: :ok, else: :error)

  defp validate_optional_cursor(nil), do: :ok
  defp validate_optional_cursor(value) when is_integer(value) and value >= 0, do: :ok
  defp validate_optional_cursor(_value), do: :error
end
