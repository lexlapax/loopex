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
  alias Loopex.Runtime.OwnerGroup
  alias Loopex.Runtime.SessionCoordinator
  alias Loopex.Runtime.StreamRelay
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

  # Concept: whether this owner still speaks for the session -- and, separately,
  # whether the runtime was reachable enough to answer at all.
  #
  # Technical depth: a boolean could not carry that difference, so an
  # unreachable control read as "not the owner" and the caller fenced a live
  # owner out of its own session permanently. Supersession is a verdict control
  # returns; unavailability is the absence of one, and the two may never share a
  # value. The call waits rather than bounding itself, exactly as `post_commit/5`
  # below it does: control is the serial authority on ownership, so a slow answer
  # is still the answer, while a deadline here would manufacture a verdict out of
  # scheduling latency. With no bound, `:runtime_unavailable` means control is
  # genuinely gone, and a caller that cannot reach control does nothing rather
  # than deciding anything.
  @doc false
  @spec current_owner(pid(), binary(), SessionCoordinator.owner()) ::
          :ok | {:error, :superseded_owner} | {:error, :runtime_unavailable}
  def current_owner(control, session_id, owner) do
    try do
      GenServer.call(control, {:current_owner, session_id, owner}, :infinity)
    catch
      :exit, _reason -> {:error, :runtime_unavailable}
    end
  end

  # Concept: an item crosses a transient session plane only while the process
  # that opened its domain is still the runtime-local current owner.
  #
  # Technical depth: checking here and emitting here are one serialized Control
  # operation. A separate `current_owner/3` call followed by a send leaves a
  # handoff-sized gap in which a successor can begin acquisition between the
  # answer and the emission. Control already serializes that handoff, so an item
  # is either admitted before the session entry moves away from the exact owner
  # or refused afterwards; it is never checked on one side and emitted on the
  # other.
  @doc false
  @spec project_progress(pid(), binary(), SessionCoordinator.owner(), StreamRelay.t(), term()) ::
          :ok | {:error, :superseded_owner} | {:error, :runtime_unavailable}
  def project_progress(control, session_id, owner, relay, item) when is_pid(relay) do
    try do
      GenServer.call(
        control,
        {:project_progress, session_id, owner, relay, item},
        :infinity
      )
    catch
      :exit, _reason -> {:error, :runtime_unavailable}
    end
  end

  # Concept: an ordinary stream closure is admitted under the same ownership
  # decision as the items it closes.
  #
  # Technical depth: the relay's bounded close runs inside Control's serialized
  # ownership operation. A succession therefore linearizes either after the
  # closure or before its refusal. The recognized-supersession model path is the
  # deliberate exception: its old coordinator has already received the handoff
  # and closes that model domain directly as abandoned after draining the model
  # worker.
  @doc false
  @spec close_progress(
          pid(),
          binary(),
          SessionCoordinator.owner(),
          StreamRelay.t(),
          StreamRelay.disposition()
        ) ::
          {:ok, non_neg_integer()}
          | {:error, :stream_unavailable}
          | {:error, :superseded_owner}
          | {:error, :runtime_unavailable}
  def close_progress(control, session_id, owner, relay, disposition) when is_pid(relay) do
    try do
      GenServer.call(
        control,
        {:close_progress, session_id, owner, relay, disposition},
        :infinity
      )
    catch
      :exit, _reason -> {:error, :runtime_unavailable}
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
       tools: Keyword.get(options, :tools, []),
       active_tools: Keyword.get(options, :active_tools, []),
       bounds: Keyword.get(options, :bounds),
       policy: Keyword.get(options, :policy),
       project_manifest: Keyword.get(options, :project_manifest),
       project_decision: Keyword.get(options, :project_decision),
       sampling: Keyword.get(options, :sampling),
       grant_decision: Keyword.fetch!(options, :grant_decision),
       fault_to: Keyword.fetch!(options, :fault_to),
       cleanup_grace_ms: Keyword.fetch!(options, :cleanup_grace_ms),
       context_token_budget: Keyword.fetch!(options, :context_token_budget),
       progress_to: Keyword.get(options, :progress_to),
       diagnostics_to: Keyword.get(options, :diagnostics_to),
       lane: OwnerLane.new(Keyword.fetch!(options, :store)),
       sessions: %{},
       monitor_to_session: %{},
       generation_counter: 0
     }}
  end

  # Concept: the tool set this session will offer the model, fixed at start.
  #
  # Technical depth: composed once here rather than resolved per turn, because a
  # session's name-to-generation mapping is immutable for its lifetime. A
  # registration made mid-run can therefore neither add, remove, nor repoint a
  # name the model has already been shown. An empty selection is legitimate and
  # means this runtime offers no tools at all.
  defp active_tool_definitions(%{active_tools: []}), do: []

  defp active_tool_definitions(state) do
    selected = MapSet.new(state.active_tools)

    Enum.filter(state.tools, fn definition ->
      MapSet.member?(selected, Map.fetch!(definition, "tool_id")) or
        MapSet.member?(
          selected,
          {Map.fetch!(definition, "tool_id"), Map.fetch!(definition, "tool_version")}
        )
    end)
  end

  @impl GenServer
  def handle_call({:configuration, token}, _from, state) do
    if token == state.token do
      configuration = %{
        runtime_id: state.runtime_id,
        attachment_capacity: state.attachment_capacity,
        model_configured: is_map(state.model),
        executor_identity: if(is_map(state.executor), do: state.executor.identity, else: nil),
        bounds: state.bounds,
        context_token_budget: state.context_token_budget
      }

      {:reply, {:ok, configuration}, state}
    else
      {:reply, {:error, :runtime_unavailable}, state}
    end
  end

  def handle_call({:create_session, token, command_id, session_options}, from, state) do
    if token == state.token do
      create_session(state, command_id, session_options, from)
    else
      {:reply, {:error, :runtime_unavailable}, state}
    end
  end

  def handle_call({:resume_session, token, session_id, command_id}, from, state) do
    if token == state.token and valid_identifier?(session_id) and valid_identifier?(command_id) do
      command = resume_command(state.runtime_id, session_id, command_id)

      case Store.runtime_command(state.store, command) do
        {:completed, %{result: ^session_id}} ->
          {:reply, {:ok, session_id}, state}

        {:completed, _changed_result} ->
          {:reply, {:error, :runtime_command_conflict}, state}

        {:open, open} ->
          start_resume_owner(state, session_id, from, Map.put(command, :open, open))

        :absent ->
          start_resume_owner(state, session_id, from, Map.put(command, :open, nil))

        :unavailable ->
          {:reply, {:error, :store_unavailable}, state}

        {:error, :runtime_command_conflict} ->
          {:reply, {:error, :runtime_command_conflict}, state}
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
    {:reply, current_owner_post_commit_fence(state, session_id, owner), state}
  end

  def handle_call({:project_progress, session_id, owner, relay, item}, _from, state) do
    case current_owner_post_commit_fence(state, session_id, owner) do
      :ok ->
        :ok = StreamRelay.emit(relay, item)
        {:reply, :ok, state}

      {:error, :superseded_owner} = error ->
        {:reply, error, state}
    end
  end

  def handle_call({:close_progress, session_id, owner, relay, disposition}, _from, state) do
    case current_owner_post_commit_fence(state, session_id, owner) do
      :ok ->
        case StreamRelay.close(relay, disposition) do
          :unavailable -> {:reply, {:error, :stream_unavailable}, state}
          count -> {:reply, {:ok, count}, state}
        end

      {:error, :superseded_owner} = error ->
        {:reply, error, state}
    end
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

  # Concept: control hands back the route to the owner; it does not carry the
  # question there and wait.
  #
  # Technical depth: brokering the call made control block inside its own
  # `handle_call` on a process that calls control back, which is the coupling the
  # deferred owner reply removed everywhere else. Even bounded it was
  # head-of-line blocking: one busy coordinator stalled every unrelated session's
  # control traffic for the whole bound and then reported a session that was
  # merely busy as unavailable. `reconciliation_query/1` already resolves a route
  # and calls the coordinator from the caller's own process; this does the same.
  def handle_call({:session_status, token, session_id}, _from, state) do
    reply =
      with true <- token == state.token,
           {:ok, %{status: :active, coordinator: coordinator, owner: owner}} <-
             Map.fetch(state.sessions, session_id) do
        {:ok, coordinator, owner}
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

  defp start_resume_owner(state, session_id, from, command) do
    case start_owner(state, session_id, command.succession_id, from, command) do
      {:waiting, next} -> {:noreply, next}
      {:error, reason, next} -> {:reply, {:error, reason}, next}
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
          |> Map.drop([:generation, :previous, :durable, :waiting])
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
        reply_waiting(entry, {:ok, durable.session_id})
        {:noreply, next}

      %{status: :active, coordinator: ^coordinator, owner: ^owner} ->
        {:noreply, state}

      _other ->
        GenServer.cast(coordinator, {:superseded, "not-current"})
        {:noreply, state}
    end
  end

  # Concept: an owner that gave up says why, so the caller waiting on it hears
  # the reason that is true instead of the one the monitor can infer.
  #
  # Technical depth: the coordinator casts this and then stops, so this message
  # and the coordinator monitor's `:DOWN` both arrive. Signals from one process
  # to another keep their order and the `:DOWN` is one of them, so this runs first: it
  # answers the waiter with the coordinator's own reason and clears `waiting`,
  # which is what makes the answer exactly one rather than this reason followed
  # by `:owner_recovery_failed` from the `:DOWN` behind it. Clearing the waiter
  # is not belt-and-braces around that ordering; it is the whole mechanism, and
  # it holds even if the two ever arrived the other way round. The coordinator
  # pid is matched because a superseded generation's late report must not answer
  # a caller waiting on the current one.
  def handle_cast({:owner_unavailable, coordinator, session_id, reason}, state) do
    case Map.fetch(state.sessions, session_id) do
      {:ok, %{status: :acquiring, coordinator: ^coordinator} = entry} ->
        reply_waiting(entry, {:error, reason})
        answered = %{entry | status: :unavailable, waiting: nil}
        {:noreply, %{state | sessions: Map.put(state.sessions, session_id, answered)}}

      _other ->
        {:noreply, state}
    end
  end

  def handle_cast({:owner_replayed, coordinator, session_id}, state) do
    case Map.fetch(state.sessions, session_id) do
      {:ok, %{status: :acquiring, coordinator: ^coordinator} = entry} ->
        reply_waiting(entry, {:ok, session_id})
        {:noreply, %{state | sessions: Map.delete(state.sessions, session_id)}}

      _other ->
        {:noreply, state}
    end
  end

  @impl GenServer
  def handle_info({:DOWN, reference, :process, pid, _reason}, state) do
    case Map.pop(state.monitor_to_session, reference) do
      {nil, _monitors} ->
        {:noreply, state}

      {{:coordinator, session_id, ^pid}, monitors} ->
        state = %{state | monitor_to_session: monitors}

        case Map.fetch(state.sessions, session_id) do
          {:ok, %{status: :acquiring, coordinator: ^pid} = entry} ->
            reply_waiting(entry, {:error, :owner_recovery_failed})
            unavailable = entry |> Map.put(:status, :unavailable) |> Map.put(:waiting, nil)
            {:noreply, %{state | sessions: Map.put(state.sessions, session_id, unavailable)}}

          _other ->
            {:noreply, state}
        end

      {{:owner_group, session_id, ^pid}, monitors} ->
        state = %{state | monitor_to_session: monitors}

        case Map.fetch(state.sessions, session_id) do
          {:ok,
           %{
             status: :awaiting_owner_barrier,
             owner_group: ^pid,
             succession_id: succession_id,
             waiting: waiting,
             owner_command: owner_command
           }} ->
            cleared = %{state | sessions: Map.delete(state.sessions, session_id)}

            case do_start_owner(cleared, session_id, succession_id, waiting, owner_command) do
              {:waiting, next} ->
                {:noreply, next}

              {:error, reason, next} ->
                Enum.each(waiting, &GenServer.reply(&1, {:error, reason}))
                {:noreply, next}
            end

          {:ok, %{status: :active, owner_group: ^pid} = entry} ->
            unavailable = Map.put(entry, :status, :unavailable)
            {:noreply, %{state | sessions: Map.put(state.sessions, session_id, unavailable)}}

          _other ->
            {:noreply, state}
        end
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

  # Concept: the session's committed cleanup period is written into the record
  # that creates the session, and the complete record is measured before
  # anything acquires authority over that session.
  #
  # Technical depth: ADR 0016 fixes `session_genesis_v2` with two closed key
  # sets and a 65,536-byte ceiling on the complete canonical item. The
  # measurement happens here, before `Store.create_session/3` and therefore
  # before any owner is started, so an over-ceiling configuration receives its
  # declared `session_configuration_too_large` refusal rather than an incidental
  # Store error attributed to a session that already exists. The period is this
  # runtime's option, which ADR 0016 makes a default for new sessions only:
  # recovery reconstructs the committed value from this record instead.
  defp create_session(state, command_id, session_options, from) do
    with true <- valid_identifier?(command_id),
         {:ok, genesis} <- session_genesis(session_options, state.cleanup_grace_ms),
         {:ok, transaction} <- Store.create_session(state.runtime_id, command_id, genesis) do
      {outcome, lane} = resolve_transaction(state.lane, transaction)
      state = %{state | lane: lane}

      case outcome do
        {:committed, ^command_id, %{type: :create_session, session_id: session_id}} ->
          case Map.fetch(state.sessions, session_id) do
            {:ok, %{status: :active}} ->
              {:reply, {:ok, session_id}, state}

            _other ->
              case start_owner(
                     state,
                     session_id,
                     succession_id(state.runtime_id, "create", session_id, command_id),
                     from
                   ) do
                {:waiting, next} -> {:noreply, next}
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
      {:error, :session_configuration_too_large} ->
        {:reply, {:error, :session_configuration_too_large}, state}

      _other ->
        {:reply, {:error, :invalid_session_creation}, state}
    end
  end

  @genesis_item_bytes 65_536

  defp session_genesis(session_options, cleanup_grace_ms) when is_map(session_options) do
    genesis = %{
      "options" => session_options,
      "runtime_configuration" => %{"cleanup_grace_ms" => cleanup_grace_ms},
      kind: "session_genesis_v2"
    }

    if canonical_item_bytes(genesis) <= @genesis_item_bytes,
      do: {:ok, genesis},
      else: {:error, :session_configuration_too_large}
  end

  defp session_genesis(_session_options, _cleanup_grace_ms),
    do: {:error, :invalid_session_creation}

  defp canonical_item_bytes(item),
    do: item |> :erlang.term_to_binary([:deterministic]) |> byte_size()

  defp start_owner(state, session_id, succession_id, from, owner_command \\ nil) do
    case Map.get(state.sessions, session_id) do
      %{
        status: :acquiring,
        owner_command: %{succession_id: ^succession_id}
      } = entry
      when not is_nil(owner_command) ->
        waiting = Map.update!(entry, :waiting, &[from | &1])
        {:waiting, %{state | sessions: Map.put(state.sessions, session_id, waiting)}}

      %{status: :acquiring} ->
        {:error, :owner_acquiring, state}

      %{status: :awaiting_owner_barrier} ->
        {:error, :owner_acquiring, state}

      %{coordinator: coordinator, owner_group: owner_group} = entry
      when is_pid(coordinator) and is_pid(owner_group) ->
        if not Process.alive?(coordinator) and Process.alive?(owner_group) do
          waiting =
            entry
            |> Map.put(:status, :awaiting_owner_barrier)
            |> Map.put(:succession_id, succession_id)
            |> Map.put(:owner_command, owner_command)
            |> Map.put(:waiting, [from])

          {:waiting, %{state | sessions: Map.put(state.sessions, session_id, waiting)}}
        else
          do_start_owner(state, session_id, succession_id, [from], owner_command)
        end

      _other ->
        do_start_owner(state, session_id, succession_id, [from], owner_command)
    end
  end

  defp do_start_owner(state, session_id, succession_id, waiting, owner_command) do
    with {:ok, %{sessions: session_supervisor, owner_groups: owner_groups, workers: workers}} <-
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

      owner_group_options = [generation: generation]

      with {:ok, owner_group} <-
             DynamicSupervisor.start_child(owner_groups, {OwnerGroup, owner_group_options}),
           {:ok, owner_workers} <- OwnerGroup.workers(owner_group) do
        options = [
          control: self(),
          store: state.store,
          session_id: session_id,
          generation: generation,
          succession_id: succession_id,
          owner_command: owner_command,
          prior_tx_id: prior_tx_id,
          workers: workers,
          owner_workers: owner_workers,
          model: state.model,
          executor: state.executor,
          tool: state.tool,
          active_tools: active_tool_definitions(state),
          progress_to: state.progress_to,
          diagnostics_to: state.diagnostics_to,
          bounds: state.bounds,
          policy: state.policy,
          project_manifest: state.project_manifest,
          project_decision: state.project_decision,
          sampling: state.sampling,
          grant_decision: state.grant_decision,
          fault_to: state.fault_to,
          cleanup_grace_ms: state.cleanup_grace_ms,
          context_token_budget: state.context_token_budget
        ]

        case DynamicSupervisor.start_child(session_supervisor, {SessionCoordinator, options}) do
          {:ok, coordinator} ->
            case OwnerGroup.attach(owner_group, coordinator) do
              :ok ->
                await_owner(
                  state,
                  session_id,
                  generation,
                  coordinator,
                  owner_group,
                  counter,
                  waiting,
                  owner_command
                )

              {:error, reason} ->
                _ = DynamicSupervisor.terminate_child(session_supervisor, coordinator)
                _ = DynamicSupervisor.terminate_child(owner_groups, owner_group)
                unavailable_owner(state, session_id, counter, reason)
            end

          {:error, reason} ->
            _ = DynamicSupervisor.terminate_child(owner_groups, owner_group)
            unavailable_owner(state, session_id, counter, reason)
        end
      else
        {:error, reason} -> unavailable_owner(state, session_id, counter, reason)
      end
    else
      _other -> {:error, :runtime_unavailable, state}
    end
  end

  defp unavailable_owner(state, session_id, counter, reason) do
    unavailable = %{status: :unavailable, durable: nil}

    next = %{
      state
      | sessions: Map.put(state.sessions, session_id, unavailable),
        generation_counter: counter
    }

    {:error, normalize_start_error(reason), next}
  end

  # Concept: control records the new owner and waits for it to announce itself,
  # rather than asking it a question control cannot afford to wait for.
  #
  # Technical depth: control used to call the coordinator here, from inside its
  # own `handle_call`. A coordinator reaches `advance_work` -- which calls
  # control -- before it services that call, so the two blocked on each other and
  # neither could answer. The five-second bounds hid the cycle by timing out into
  # a wrong answer: control killed a healthy coordinator and reported a durable
  # recovery it never attempted. The reply is deferred instead. Nothing is
  # answered here; the `:owner_ready` cast every successful acquisition already
  # sends completes it, and a coordinator that dies first is answered by the
  # monitor. Control therefore never makes a synchronous call into a coordinator,
  # which is what makes the cycle unconstructible rather than merely unlikely.
  defp await_owner(
         state,
         session_id,
         generation,
         coordinator,
         owner_group,
         counter,
         waiting,
         owner_command
       ) do
    coordinator_monitor = Process.monitor(coordinator)
    owner_group_monitor = Process.monitor(owner_group)

    entry = %{
      status: :acquiring,
      coordinator: coordinator,
      owner_group: owner_group,
      owner_command: owner_command,
      generation: generation,
      previous: Map.get(state.sessions, session_id),
      coordinator_monitor: coordinator_monitor,
      owner_group_monitor: owner_group_monitor,
      durable: nil,
      waiting: waiting
    }

    monitors =
      state.monitor_to_session
      |> Map.put(coordinator_monitor, {:coordinator, session_id, coordinator})
      |> Map.put(owner_group_monitor, {:owner_group, session_id, owner_group})

    next = %{
      state
      | sessions: Map.put(state.sessions, session_id, entry),
        monitor_to_session: monitors,
        generation_counter: counter
    }

    {:waiting, next}
  end

  # Concept: whoever is waiting on this session's owner gets exactly one answer.
  #
  # Technical depth: callers that re-present the same Store-owned resume
  # command wait for the same acquisition result. A distinct command remains
  # refused with `:owner_acquiring`, preserving per-session serialization.
  defp reply_waiting(%{waiting: waiters}, reply) when is_list(waiters),
    do: Enum.each(waiters, &GenServer.reply(&1, reply))

  defp reply_waiting(%{waiting: from}, reply) when not is_nil(from),
    do: GenServer.reply(from, reply)

  defp reply_waiting(_entry, _reply), do: :ok

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

  defp resume_command(runtime_id, session_id, command_id) do
    canonical =
      :erlang.term_to_binary(
        ["loopex_runtime_command_v1", runtime_id, command_id, :resume, session_id, "session"],
        [:deterministic]
      )

    %{
      runtime_id: runtime_id,
      command_id: command_id,
      command_kind: :resume,
      session_id: session_id,
      mutation_domain: "session",
      succession_id: succession_id(runtime_id, "resume", session_id, command_id),
      canonical_command_bytes: canonical,
      canonical_command_digest: :crypto.hash(:sha256, canonical)
    }
  end

  defp succession_id(runtime_id, kind, session_id, command_id) do
    bytes =
      :erlang.term_to_binary(
        ["loopex_owner_operation_v1", runtime_id, kind, session_id, command_id],
        [:deterministic]
      )

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
