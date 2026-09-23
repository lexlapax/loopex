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

  alias Loopex.Instrumentation
  alias Loopex.ResumeActivation
  alias Loopex.Runtime.DaemonRoute
  alias Loopex.Runtime.EventDispatcher
  alias Loopex.Runtime.OwnerGroup
  alias Loopex.Runtime.ProviderAttempt
  alias Loopex.Runtime.SessionCoordinator
  alias Loopex.Runtime.StreamRelay
  alias Loopex.Runtime.Supervisor, as: RuntimeSupervisor
  alias Loopex.Owner
  alias Loopex.Store
  alias Loopex.Store.OwnerLane
  alias Loopex.Trace.Config, as: TraceConfig

  require Logger

  @max_identifier_bytes 256
  @attachment_transaction_limit 512
  @max_quiesce_writer_domains 64

  # Technical depth: this is Control's private responsiveness bound for the
  # Store evidence that rebuilds a provider binding or closes one receipt range.
  # It is deliberately independent of the run deadline: expiry proves only that
  # the Store did not answer inside Control's local allowance, so it refuses
  # without manufacturing a dispatch verdict.
  @position_read_timeout_ms 1_000

  @run_terminal_keys [
    "accounting_source",
    "bound",
    "cleanup_grace_ms",
    "command_id",
    "declared_limit",
    "observed",
    "outcome",
    "reason",
    "reconciliation_ref",
    "run_id",
    :kind
  ]

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
  @spec trace_start(pid(), reference(), term()) :: {:ok, map()} | {:error, term()}
  def trace_start(control, token, config) when is_pid(control) do
    control_call(control, {:trace_start, token, config})
  end

  @doc false
  @spec trace_stop(pid(), reference()) :: :ok | {:error, term()}
  def trace_stop(control, token) when is_pid(control) do
    control_call(control, {:trace_stop, token})
  end

  @doc false
  @spec trace_status(pid(), reference()) :: {:ok, map()} | {:error, term()}
  def trace_status(control, token) when is_pid(control) do
    control_call(control, {:trace_status, token})
  end

  @doc false
  @spec begin_quiesce(pid(), reference(), binary(), timeout()) ::
          {:ok, [map()]} | {:error, :runtime_unavailable}
  def begin_quiesce(control, token, drain_id, timeout)
      when is_pid(control) and is_binary(drain_id) do
    bounded_control_call(control, {:begin_quiesce, token, drain_id}, timeout)
  end

  @doc false
  @spec quiesce_projection(pid(), reference(), binary(), timeout()) ::
          {:ok, [map()]} | {:error, :runtime_unavailable}
  def quiesce_projection(control, token, drain_id, timeout)
      when is_pid(control) and is_binary(drain_id) do
    bounded_control_call(control, {:quiesce_projection, token, drain_id}, timeout)
  end

  @doc false
  @spec start_quiesce_fence(
          pid(),
          reference(),
          binary(),
          reference(),
          pid(),
          binary(),
          integer(),
          term()
        ) :: :ok
  def start_quiesce_fence(
        control,
        token,
        drain_id,
        operation_ref,
        phase_owner,
        session_id,
        deadline,
        abort_resolution
      )
      when is_pid(control) and is_reference(operation_ref) and is_pid(phase_owner) and
             is_binary(drain_id) and is_binary(session_id) and is_integer(deadline) do
    send(
      control,
      {:start_quiesce_fence, token, drain_id, operation_ref, phase_owner, session_id, deadline,
       abort_resolution}
    )

    :ok
  end

  @doc false
  @spec authorize_quiesce_fence(pid(), reference(), binary(), reference(), pid(), integer()) ::
          :ok
  def authorize_quiesce_fence(
        control,
        token,
        drain_id,
        operation_ref,
        phase_owner,
        deadline
      ) do
    send(
      control,
      {:authorize_quiesce_fence, token, drain_id, operation_ref, phase_owner, deadline}
    )

    :ok
  end

  @doc false
  @spec cancel_quiesce_fence(pid(), reference(), binary(), reference(), pid()) :: :ok
  def cancel_quiesce_fence(control, token, drain_id, operation_ref, phase_owner) do
    send(
      control,
      {:cancel_quiesce_fence, token, drain_id, operation_ref, phase_owner}
    )

    :ok
  end

  @doc false
  @spec exclude_trace_process(pid(), reference(), pid(), list(), GenServer.from()) :: :ok
  def exclude_trace_process(control, token, caller, functions, reply_to)
      when is_pid(control) and is_pid(caller) and is_list(functions) do
    send(control, {:trace_exclude, token, caller, functions, reply_to})
    :ok
  end

  defp control_call(control, message) do
    try do
      GenServer.call(control, message, :infinity)
    catch
      :exit, _reason -> {:error, :runtime_unavailable}
    end
  end

  defp bounded_control_call(control, message, timeout) do
    try do
      GenServer.call(control, message, timeout)
    catch
      :exit, _reason -> {:error, :runtime_unavailable}
    end
  end

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

  # Concept: authorizing one provider attempt and sending its one-use permit are
  # the same serialized Control operation.
  #
  # Technical depth: ADR 0018 makes Control's direct send to the blocked worker
  # the provider-dispatch linearization point. Returning the authorization to the
  # coordinator so it could wake its own worker would leave a handoff-sized gap
  # between the ownership check and the send, and a worker that asked Control for
  # itself would let its call overtake the coordinator's readiness messages. The
  # call is unbounded for the same reason `current_owner/3` is: a finite timeout
  # here would manufacture a dispatch verdict out of scheduling latency, and
  # ambiguity is never `not_dispatched`.
  @doc false
  @spec provider_dispatch(pid(), map(), map()) :: {:ok, :dispatched} | {:error, term()}
  def provider_dispatch(control, binding, authority) do
    try do
      GenServer.call(control, {:provider_dispatch, binding, authority}, :infinity)
    catch
      :exit, _reason -> {:error, :runtime_unavailable}
    end
  end

  @doc false
  @spec post_commit(pid(), binary(), SessionCoordinator.owner(), map(), map()) ::
          :ok | {:error, term()}
  def post_commit(control, session_id, owner, positions, receipt) do
    # Concept: accepted ADR 0030's receipt-and-publication cut.
    #
    # Technical depth: this is where a committed receipt becomes readable
    # history, so the span measures the whole installation of the publication
    # fence rather than the dispatcher call inside it. The cursor the commit
    # reached is an identity; no event body and no receipt field crosses into
    # the metadata.
    Instrumentation.span(
      [:events, :publish],
      %{
        session_id: session_id,
        journal_version: Map.get(positions, :journal_version),
        event_sequence: Map.get(positions, :event_sequence)
      },
      fn ->
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
    )
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
       policy_identity: Keyword.get(options, :policy_identity),
       project_manifest: Keyword.get(options, :project_manifest),
       project_decision: Keyword.get(options, :project_decision),
       resource_snapshot: Keyword.get(options, :resource_snapshot),
       sampling: Keyword.get(options, :sampling),
       grant_decision: Keyword.fetch!(options, :grant_decision),
       fault_to: Keyword.fetch!(options, :fault_to),
       cleanup_grace_ms: Keyword.fetch!(options, :cleanup_grace_ms),
       context_token_budget: Keyword.fetch!(options, :context_token_budget),
       progress_to: Keyword.get(options, :progress_to),
       diagnostics_to: Keyword.get(options, :diagnostics_to),
       # Concept: every provider-permit decision reads one runtime-local wall clock.
       #
       # Technical depth: the function stays in private process state so the exact
       # send boundary can be exercised deterministically without widening runtime
       # configuration or changing production's System clock.
       wall_clock: fn -> System.system_time(:millisecond) end,
       lane: OwnerLane.new(Keyword.fetch!(options, :store)),
       sessions: %{},
       writer_domains: MapSet.new(),
       quiescing: nil,
       quiesce_writer_domains: nil,
       quiesce_fences: %{},
       quiesce_fence_monitors: %{},
       monitor_to_session: %{},
       attachment_holders: %{},
       attachment_monitor_to_holder: %{},
       pending_attachments: %{},
       attachment_caller_monitors: %{},
       attachment_counter: 0,
       holder_release_waiters: %{},
       dispatcher: nil,
       dispatcher_waiting_attaches: :queue.new(),
       dispatcher_ready_waiters: [],
       # Concept: the unresolved attempt identities this runtime has authorized,
       # and the one worker and reference each was bound to.
       #
       # Technical depth: ADR 0027 retains a spend across coordinator and worker
       # replacement until a matching committed settlement closes its durable
       # authorization domain. A missing entry never grants a permit: the current
       # owner, journal position and exact attempt-open row remain mandatory.
       spent_attempts: %{},
       generation_counter: 0,
       trace: nil,
       trace_session: nil,
       trace_version: 0,
       trace_excluded: %{},
       trace_exclusion_monitors: %{},
       trace_mfa_counts: %{},
       trace_pending: %{},
       trace_waiting: :queue.new()
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
  def handle_call({:trace_start, token, config}, from, state) do
    if token == state.token do
      case TraceConfig.validate(config) do
        {:ok, validated} -> enqueue_trace_operation(state, {:start, validated}, from)
        {:error, reason} -> {:reply, {:error, reason}, state}
      end
    else
      {:reply, {:error, :runtime_unavailable}, state}
    end
  end

  def handle_call({:trace_stop, token}, from, state) do
    if token == state.token do
      enqueue_trace_operation(state, :stop, from)
    else
      {:reply, {:error, :runtime_unavailable}, state}
    end
  end

  def handle_call({:trace_status, token}, from, state) do
    if token == state.token do
      enqueue_trace_operation(state, :status, from)
    else
      {:reply, {:error, :runtime_unavailable}, state}
    end
  end

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

  def handle_call({:begin_quiesce, token, drain_id}, _from, state) do
    cond do
      token != state.token or not valid_identifier?(drain_id) ->
        {:reply, {:error, :runtime_unavailable}, state}

      not is_nil(state.quiescing) ->
        Logger.debug("runtime quiesce gate refused")
        {:reply, {:error, :runtime_unavailable}, state}

      true ->
        next =
          state
          |> Map.put(:quiescing, drain_id)
          |> Map.put(:quiesce_writer_domains, state.writer_domains)
          |> refuse_dispatcher_waiting_attaches()

        Logger.debug("runtime quiesce gate installed",
          writer_domains: MapSet.size(next.writer_domains)
        )

        if MapSet.size(next.writer_domains) <= @max_quiesce_writer_domains do
          {:reply, {:ok, quiesce_projection(next)}, next}
        else
          {:reply, {:error, :runtime_unavailable}, next}
        end
    end
  end

  def handle_call({:quiesce_projection, token, drain_id}, _from, state) do
    reply =
      if token == state.token and state.quiescing == drain_id and
           state.writer_domains == state.quiesce_writer_domains and
           MapSet.size(state.quiesce_writer_domains) <= @max_quiesce_writer_domains do
        {:ok, quiesce_projection(state)}
      else
        {:error, :runtime_unavailable}
      end

    {:reply, reply, state}
  end

  def handle_call({:create_session, token, command_id, session_options, mode}, from, state) do
    cond do
      token != state.token ->
        {:reply, {:error, :runtime_unavailable}, state}

      not is_nil(state.quiescing) ->
        {:reply, {:error, :runtime_unavailable}, state}

      true ->
        create_session(state, command_id, session_options, from, mode)
    end
  end

  def handle_call({:session_existence, token, session_id}, _from, state) do
    reply =
      if token == state.token and valid_identifier?(session_id) do
        case Store.ownership_head(state.store, session_id, "session") do
          {:ok, _head} -> {:ok, :present}
          :absent -> {:ok, :absent}
          :unavailable -> {:ok, :store_unavailable}
        end
      else
        {:error, :runtime_unavailable}
      end

    {:reply, reply, state}
  end

  def handle_call(
        {:lookup_create_result, token, command_id, session_options},
        _from,
        state
      ) do
    reply =
      if token == state.token do
        {:ok, lookup_create_result(state, command_id, session_options)}
      else
        {:error, :runtime_unavailable}
      end

    {:reply, reply, state}
  end

  def handle_call({:resume_session, token, session_id, command_id, mode}, from, state) do
    if token == state.token and is_nil(state.quiescing) and valid_identifier?(session_id) and
         valid_identifier?(command_id) do
      command = resume_command(state.runtime_id, session_id, command_id)

      case Store.runtime_command(state.store, command) do
        {:completed, %{result: ^session_id}} ->
          reply = completed_resume_reply(mode, session_id)
          {:reply, detailed_session_reply(reply, mode, :no_activation, state, session_id), state}

        {:completed, _changed_result} ->
          reply =
            detailed_session_reply(
              {:error, :runtime_command_conflict},
              mode,
              :no_activation,
              state,
              session_id
            )

          {:reply, reply, state}

        {:open, open} ->
          start_resume_owner(state, session_id, from, Map.put(command, :open, open), mode)

        :absent ->
          start_resume_owner(state, session_id, from, Map.put(command, :open, nil), mode)

        :unavailable ->
          reply =
            detailed_session_reply(
              {:error, :store_unavailable},
              mode,
              :no_activation,
              state,
              session_id
            )

          {:reply, reply, state}

        {:error, :runtime_command_conflict} ->
          reply =
            detailed_session_reply(
              {:error, :runtime_command_conflict},
              mode,
              :no_activation,
              state,
              session_id
            )

          {:reply, reply, state}
      end
    else
      if not is_nil(state.quiescing) do
        {:reply, {:error, :runtime_unavailable}, state}
      else
        reply =
          detailed_session_reply(
            {:error, :invalid_session_id},
            mode,
            :no_activation,
            state,
            session_id
          )

        {:reply, reply, state}
      end
    end
  end

  def handle_call(
        {:route_command, token, session_id, attachment_id, incarnation_id},
        _from,
        state
      ) do
    reply =
      with true <- token == state.token and is_nil(state.quiescing),
           {:ok, %{status: :active, coordinator: coordinator, owner: owner} = entry} <-
             Map.fetch(state.sessions, session_id),
           :ok <- current_attachment?(entry.attachments, attachment_id, incarnation_id),
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
        _other when not is_nil(state.quiescing) -> {:error, :runtime_unavailable}
        _other -> {:error, :session_unavailable}
      end

    {:reply, reply, state}
  end

  def handle_call(
        {:route_command_for_daemon, token, session_id, attachment_id, incarnation_id},
        _from,
        state
      ) do
    reply =
      cond do
        token != state.token ->
          {:error, :runtime_unavailable}

        not is_nil(state.quiescing) ->
          {:error, :runtime_unavailable}

        true ->
          entry = Map.get(state.sessions, session_id)

          cond do
            not attachment_live_in_entry?(entry, attachment_id, incarnation_id) ->
              {:error, {:attachment_route_invalidated, attachment_id, incarnation_id}}

            not match?(%{status: :active}, entry) ->
              {:error, :session_unavailable}

            not Process.alive?(entry.coordinator) ->
              {:error, :session_unavailable}

            true ->
              route =
                DaemonRoute.new(
                  self(),
                  state.token,
                  session_id,
                  attachment_id,
                  incarnation_id,
                  entry.coordinator,
                  entry.owner.generation
                )

              {:ok, entry.coordinator, entry.owner, route}
          end
      end

    {:reply, reply, state}
  end

  def handle_call(
        {:classify_daemon_result, token, session_id, attachment_id, incarnation_id, coordinator,
         owner_generation},
        _from,
        state
      ) do
    reply =
      if token == state.token do
        entry = Map.get(state.sessions, session_id)

        cond do
          attachment_live_in_entry?(entry, attachment_id, incarnation_id) ->
            :before_succession_cut

          owner_generation_advanced?(entry, coordinator, owner_generation) ->
            {:after_succession_cut, attachment_id, incarnation_id}

          true ->
            {:error, :runtime_unavailable}
        end
      else
        {:error, :runtime_unavailable}
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

  # Concept: one attempt, one permit, sent from here and nowhere else.
  #
  # Technical depth: every member of the request is compared with this Control's
  # own serialized state before anything is sent — the caller is still the
  # prepared current owner, the journal position carrying the open row is
  # current, the worker is the one the coordinator started, the deadline has not
  # elapsed, and the full attempt identity has never been permitted. The spend
  # and the send happen together, so a succession linearizes either entirely
  # before the send or entirely after it. A refusal here is ephemeral: it is the
  # coordinator's to retain durably, and only while that coordinator is still
  # authoritative. Exact already-spent bindings refuse from local state before
  # a Store read; re-presenting one cannot spend another serialized read wait.
  #
  # The deadline is checked twice on purpose. The first check refuses an already
  # expired attempt before Control spends a Store read on it. The final helper
  # samples the clock only after the permit tuple and spent-map update have been
  # allocated, then sends directly when that sample is still inside the bound.
  # That removes every controllable check-to-send action from this process, but
  # a clock read and an Erlang send are not one atomic instruction: Control can
  # still be preempted between them. The worker therefore applies the same
  # committed deadline after receiving the permit and immediately before calling
  # the adapter. A refusal from this helper is exact pre-transport evidence and
  # settles `not_dispatched`; a refusal at the receiver comes after a possible
  # send and settles conservatively as `dispatched_or_unknown`.
  def handle_call({:provider_dispatch, binding, authority}, {caller, _tag}, state) do
    with {:ok, session_id} <- provider_binding_session(binding),
         {:ok, entry} <- provider_current_owner(state, session_id, authority, caller),
         :ok <- provider_position_current(entry, authority),
         :ok <- provider_worker_ready(authority),
         :ok <- provider_before_deadline(authority, state.wall_clock),
         :ok <- provider_attempt_unspent(state, binding),
         :ok <- provider_position_binding(state, session_id, authority, binding) do
      %{worker: worker, permit_reference: reference} = authority
      permit = {:loopex_provider_permit, reference, binding}
      spent = Map.put(state.spent_attempts, binding, {worker, reference})

      case send_provider_permit_before_deadline(worker, permit, authority, state.wall_clock) do
        :ok -> {:reply, {:ok, :dispatched}, %{state | spent_attempts: spent}}
        {:error, reason} -> {:reply, {:error, reason}, state}
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
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

          next =
            state
            |> Map.put(:sessions, Map.put(state.sessions, session_id, next_entry))
            |> retire_settled_attempts(session_id, next_entry, receipt)

          EventDispatcher.acknowledge(state.root, session_id, positions.event_sequence)
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
      with true <- token == state.token and is_nil(state.quiescing),
           {:ok, %{status: :active, coordinator: coordinator, owner: owner}} <-
             Map.fetch(state.sessions, session_id) do
        {:ok, coordinator, owner}
      else
        _other when not is_nil(state.quiescing) -> {:error, :runtime_unavailable}
        _other -> {:error, :session_unavailable}
      end

    {:reply, reply, state}
  end

  def handle_call({:attach, token, session_id, holder, options}, from, state) do
    if token == state.token and is_nil(state.quiescing) do
      case state.dispatcher do
        %{status: :ready} ->
          begin_attach(state, session_id, holder, options, from)

        _initializing_or_restarting ->
          if :queue.len(state.dispatcher_waiting_attaches) < @attachment_transaction_limit do
            waiting =
              :queue.in({from, session_id, holder, options}, state.dispatcher_waiting_attaches)

            {:noreply, %{state | dispatcher_waiting_attaches: waiting}}
          else
            {:reply, {:error, :capacity_exceeded}, state}
          end
      end
    else
      {:reply, {:error, :runtime_unavailable}, state}
    end
  end

  def handle_call(
        {:begin_dispatcher_registration, token, dispatcher, incarnation},
        _from,
        state
      ) do
    if token == state.token and is_pid(dispatcher) and is_reference(incarnation) do
      state = clear_attachment_generation(state)
      registration_ref = make_ref()
      monitor = Process.monitor(dispatcher)

      registered = %{
        pid: dispatcher,
        incarnation: incarnation,
        monitor: monitor,
        registration_ref: registration_ref,
        ready_token: nil,
        status: :initializing
      }

      seed = dispatcher_acknowledgement_seed(state)
      {:reply, {:ok, registration_ref, seed}, %{state | dispatcher: registered}}
    else
      {:reply, {:error, :runtime_unavailable}, state}
    end
  end

  # Concept: a runtime is handed to its caller only once its dispatcher can
  # serve, so a resume or attach issued straight after start is not refused
  # for a dispatcher that has not finished registering.
  #
  # Technical depth: the dispatcher registers asynchronously after the
  # supervisor starts it. A caller asking before `:dispatcher_ready` is kept
  # and answered when that message arrives; a runtime that dies first ends the
  # call, which the caller maps to `:runtime_unavailable`.
  def handle_call({:await_dispatcher_ready, token}, from, state) do
    cond do
      token != state.token ->
        {:reply, {:error, :runtime_unavailable}, state}

      match?(%{status: :ready}, state.dispatcher) ->
        {:reply, :ok, state}

      true ->
        {:noreply, %{state | dispatcher_ready_waiters: [from | state.dispatcher_ready_waiters]}}
    end
  end

  def handle_call(
        {:finalize_dispatcher_registration, token, dispatcher, incarnation, registration_ref},
        _from,
        state
      ) do
    case state.dispatcher do
      %{
        pid: ^dispatcher,
        incarnation: ^incarnation,
        registration_ref: ^registration_ref,
        status: :initializing
      } = registered
      when token == state.token ->
        ready_token = make_ref()
        next = %{registered | status: :ready_pending, ready_token: ready_token}
        {:reply, {:ok, ready_token}, %{state | dispatcher: next}}

      _other ->
        {:reply, {:error, :runtime_unavailable}, state}
    end
  end

  def handle_call({:release_holder, token, holder}, from, state) do
    if token == state.token and is_pid(holder) do
      next = mark_control_holder_down(state, holder)

      if Enum.any?(next.pending_attachments, fn {_attach_ref, pending} ->
           pending.holder == holder
         end) do
        waiters = Map.get(next.holder_release_waiters, holder, [])

        {:noreply,
         %{
           next
           | holder_release_waiters:
               Map.put(next.holder_release_waiters, holder, [from | waiters])
         }}
      else
        {:reply, :ok, next}
      end
    else
      {:reply, {:error, :runtime_unavailable}, state}
    end
  end

  defp start_resume_owner(state, session_id, from, command, mode) do
    case start_owner(state, session_id, command.succession_id, from, command, mode) do
      {:waiting, next} ->
        {:noreply, next}

      {:error, reason, next, disposition} ->
        reply =
          detailed_session_reply(
            {:error, reason},
            mode,
            disposition,
            next,
            session_id
          )

        {:reply, reply, next}
    end
  end

  # Concept: a prepared resume answers with a capability instead of a session
  # identifier, because the owner it acquired is not yet allowed to work.
  #
  # Technical depth: the capability is a runtime-local reference paired with the
  # exact process that asked for it. Neither is serializable and neither is
  # reachable from a durable, public, progress, or diagnostic plane; the pair is
  # created here, handed once to the coordinator that will honour it, and
  # returned to the preparer as the only route to activation or abandonment.
  defp prepared_capability(:prepared, {holder, _tag}) when is_pid(holder),
    do: %{capability: make_ref(), holder: holder}

  defp prepared_capability(_mode, _from), do: nil

  defp completed_resume_reply(:prepared, session_id), do: {:ok, {:replayed, session_id}}
  defp completed_resume_reply(_mode, session_id), do: {:ok, session_id}

  defp owner_ready_reply(%{prepared: %{capability: capability}}, coordinator, owner, _durable),
    do: {:ok, {:prepared, ResumeActivation.new(coordinator, owner, capability)}}

  defp owner_ready_reply(_entry, _coordinator, _owner, durable), do: {:ok, durable.session_id}

  defp replayed_reply(%{prepared: prepared}, session_id) when is_map(prepared),
    do: {:ok, {:replayed, session_id}}

  defp replayed_reply(_entry, session_id), do: {:ok, session_id}

  # Concept: an ordinary succession takes the session away from whoever was
  # attached to it; a prepared one hands the same session back to them.
  #
  # Technical depth: attachment invalidation exists so a caller attached under
  # one owner cannot go on commanding a session that has moved to another. A
  # prepared owner has not moved anything: it acquired ownership and rebuilt
  # history without scheduling a single piece of the recovered work, precisely so
  # the terminal that asked for it can decide what happens next. Dropping that
  # terminal's attachment would leave it holding a route to a session it had just
  # been given, and its interrupt would have nowhere to send an abort. So the
  # prepared case carries the previous attachment forward and skips the
  # dispatcher's invalidation; every other succession keeps invalidating exactly
  # as before. Activation and abandonment stay fenced by the capability, which is
  # what an attachment is not and never becomes.
  defp carried_owner_attachments(state, %{prepared: prepared}, previous)
       when is_map(prepared) do
    {state, Map.get(previous || %{}, :attachments, %{})}
  end

  defp carried_owner_attachments(state, _entry, _previous), do: {state, %{}}

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
        {state, attachments} = carried_owner_attachments(state, entry, previous)

        active =
          entry
          |> Map.drop([:generation, :previous, :durable, :waiting, :prepared])
          |> Map.merge(%{
            status: :active,
            owner: owner,
            journal_version: durable.journal_version,
            event_sequence: durable.event_sequence,
            attachments: attachments
          })

        next = %{state | sessions: Map.put(state.sessions, durable.session_id, active)}
        notify_superseded(previous, owner.generation)
        EventDispatcher.acknowledge(state.root, durable.session_id, durable.event_sequence)

        reply_waiting(
          entry,
          owner_ready_reply(entry, coordinator, owner, durable),
          next,
          durable.session_id
        )

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
        EventDispatcher.release_fence(state.root, session_id)
        answered = %{entry | status: :unavailable, waiting: nil}

        sessions =
          if reason == :runtime_placement_mismatch and is_nil(state.quiescing),
            do: Map.delete(state.sessions, session_id),
            else: Map.put(state.sessions, session_id, answered)

        next = %{state | sessions: sessions}
        reply_waiting(entry, {:error, reason}, next, session_id)
        {:noreply, next}

      _other ->
        {:noreply, state}
    end
  end

  def handle_cast({:owner_replayed, coordinator, session_id}, state) do
    case Map.fetch(state.sessions, session_id) do
      {:ok, %{status: :acquiring, coordinator: ^coordinator} = entry} ->
        EventDispatcher.release_fence(state.root, session_id)

        answered = %{entry | status: :unavailable, waiting: nil}

        next = %{
          state
          | sessions:
              if(is_nil(state.quiescing),
                do: Map.delete(state.sessions, session_id),
                else: Map.put(state.sessions, session_id, answered)
              ),
            spent_attempts: forget_spent_attempts(state.spent_attempts, session_id)
        }

        reply_waiting(entry, replayed_reply(entry, session_id), next, session_id)
        {:noreply, next}

      _other ->
        {:noreply, state}
    end
  end

  # Concept: releasing a session clears any unresolved attempt identities that
  # could not be retired from committed settlement evidence.
  #
  # Technical depth: ADR 0027 retires proven settled identities earlier, but a
  # missing, unreadable or malformed settlement retains the spend across owner
  # succession. The residual entries leave memory only when Control releases the
  # session itself, preserving the existing owner-epoch fence.
  defp forget_spent_attempts(spent, session_id) do
    spent
    |> Enum.reject(fn {binding, _bound} -> Map.get(binding, "session_id") == session_id end)
    |> Map.new()
  end

  # Concept: a settled provider attempt stops consuming runtime memory only once
  # durable truth proves both its settlement and the authorization domain after it.
  #
  # Technical depth: the acknowledged Store receipt fixes one bounded committed
  # range and `next_entry` fixes its authoritative last version. Every candidate
  # settlement is validated with ProviderAttempt before it can match a spent key.
  # The final row either registers one exact current attempt-open binding or no
  # binding; a matching settlement never retires that current identity. Any
  # missing, delayed, malformed or oversized read preserves the complete map.
  # Sessions without their own spent attempt need no retirement read; another
  # session's live work must not make their acknowledgements wait on the Store.
  defp retire_settled_attempts(%{spent_attempts: spent} = state, _session_id, _entry, _receipt)
       when map_size(spent) == 0,
       do: state

  defp retire_settled_attempts(state, session_id, entry, receipt) do
    with true <-
           Enum.any?(state.spent_attempts, fn {binding, _bound} ->
             Map.get(binding, "session_id") == session_id
           end),
         {:ok, records} <- committed_receipt_records(state.store, session_id, entry, receipt),
         {:ok, current} <- current_provider_binding(session_id, List.last(records)),
         {:ok, settled} <- settled_spent_bindings(records, session_id, state.spent_attempts) do
      retired = if is_nil(current), do: settled, else: List.delete(settled, current)
      %{state | spent_attempts: Map.drop(state.spent_attempts, retired)}
    else
      _unproved -> state
    end
  end

  defp committed_receipt_records(store, session_id, %{journal_version: current}, %{
         journal_versions: %{first: first, last: current}
       })
       when is_integer(first) and first > 0 and first <= current do
    count = current - first + 1

    if count <= Store.max_item_cardinality() do
      case bounded_receipt_records_read(store, session_id, first - 1, count) do
        {:ok, records} ->
          if Enum.map(records, & &1.journal_version) == Enum.to_list(first..current),
            do: {:ok, records},
            else: {:error, :incomplete_settlement_range}

        _unavailable ->
          {:error, :settlement_range_unavailable}
      end
    else
      {:error, :settlement_range_too_large}
    end
  end

  defp committed_receipt_records(_store, _session_id, _entry, _receipt),
    do: {:error, :invalid_settlement_range}

  defp current_provider_binding(session_id, %{payload: payload}) do
    if record_kind(payload) == ProviderAttempt.opened_kind(),
      do: ProviderAttempt.binding_from_opened(session_id, payload),
      else: {:ok, nil}
  end

  defp current_provider_binding(_session_id, _record),
    do: {:error, :invalid_current_provider_record}

  defp settled_spent_bindings(records, session_id, spent)
       when is_list(records) and is_map(spent) do
    records
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn
      {%{payload: payload}, index}, {:ok, retired} ->
        if record_kind(payload) == ProviderAttempt.settled_kind() do
          with :ok <- ProviderAttempt.validate_settled(payload),
               :ok <- settlement_domain_closed(payload, Enum.at(records, index + 1)) do
            matching =
              spent
              |> Map.keys()
              |> Enum.filter(&settlement_matches_binding?(&1, session_id, payload))

            {:cont, {:ok, matching ++ retired}}
          else
            {:error, _reason} -> {:halt, {:error, :invalid_attempt_settlement}}
          end
        else
          {:cont, {:ok, retired}}
        end

      _invalid_record, _acc ->
        {:halt, {:error, :invalid_settlement_records}}
    end)
  end

  defp settled_spent_bindings(_records, _session_id, _spent),
    do: {:error, :invalid_settlement_records}

  defp settlement_domain_closed(%{"next" => "terminal"} = settlement, %{
         payload: terminal
       }) do
    with true <- MapSet.new(Map.keys(terminal)) == MapSet.new(@run_terminal_keys),
         "run_terminal_committed" <- record_kind(terminal),
         true <- terminal["run_id"] == settlement["run_id"],
         true <- terminal["outcome"] == settlement_terminal_outcome(settlement),
         true <- valid_terminal_bound?(terminal, settlement["termination"]),
         true <- is_integer(terminal["cleanup_grace_ms"]) and terminal["cleanup_grace_ms"] > 0,
         true <- is_nil(terminal["command_id"]) or is_binary(terminal["command_id"]),
         true <-
           is_nil(terminal["reconciliation_ref"]) or is_binary(terminal["reconciliation_ref"]),
         true <- is_nil(terminal["reason"]) or is_binary(terminal["reason"]) do
      :ok
    else
      _invalid -> {:error, :invalid_attempt_terminal}
    end
  end

  defp settlement_domain_closed(%{"next" => "terminal"}, _next),
    do: {:error, :missing_attempt_terminal}

  defp settlement_domain_closed(_settlement, _next), do: :ok

  defp settlement_terminal_outcome(%{"termination" => "abort"}), do: "cancelled"
  defp settlement_terminal_outcome(%{"termination" => "deadline"}), do: "bound_reached"
  defp settlement_terminal_outcome(%{"result" => %{"kind" => "reply"}}), do: "completed"
  defp settlement_terminal_outcome(_settlement), do: "failed"

  defp valid_terminal_bound?(terminal, "deadline") do
    terminal["bound"] == "deadline" and is_integer(terminal["observed"]) and
      terminal["observed"] >= 0 and terminal["declared_limit"] == terminal["observed"] and
      is_nil(terminal["accounting_source"])
  end

  defp valid_terminal_bound?(terminal, _termination) do
    terminal["bound"] == false and terminal["observed"] == false and
      terminal["declared_limit"] == false and is_nil(terminal["accounting_source"])
  end

  defp settlement_matches_binding?(binding, session_id, settlement) do
    ProviderAttempt.validate_binding(binding) == :ok and binding["session_id"] == session_id and
      Enum.all?(binding, fn
        {"session_id", ^session_id} -> true
        {key, value} -> settlement[key] == value
      end)
  end

  defp record_kind(record) when is_map(record),
    do: Map.get(record, :kind, Map.get(record, "kind"))

  defp record_kind(_record), do: nil

  @impl GenServer
  def handle_info(
        {:start_quiesce_fence, token, drain_id, operation_ref, phase_owner, session_id, deadline,
         abort_resolution},
        state
      ) do
    valid? =
      token == state.token and state.quiescing == drain_id and
        match?(%MapSet{}, state.quiesce_writer_domains) and
        MapSet.member?(state.quiesce_writer_domains, session_id) and
        deadline > System.monotonic_time(:millisecond) and Process.alive?(phase_owner) and
        not Map.has_key?(state.quiesce_fences, operation_ref) and
        not Enum.any?(state.quiesce_fences, fn {_ref, fence} ->
          fence.session_id == session_id
        end)

    if valid? do
      {pid, monitor} =
        SessionCoordinator.start_quiesce_fence(
          self(),
          state.store,
          session_id,
          operation_ref,
          phase_owner,
          deadline,
          abort_resolution
        )

      fence = %{
        pid: pid,
        monitor: monitor,
        phase_owner: phase_owner,
        session_id: session_id,
        drain_id: drain_id,
        deadline: deadline,
        status: :starting,
        result: nil
      }

      Logger.debug("runtime quiesce fence started")

      {:noreply,
       %{
         state
         | quiesce_fences: Map.put(state.quiesce_fences, operation_ref, fence),
           quiesce_fence_monitors: Map.put(state.quiesce_fence_monitors, monitor, operation_ref)
       }}
    else
      send(phase_owner, {:loopex_quiesce_fence_refused, operation_ref, session_id})
      {:noreply, state}
    end
  end

  def handle_info({:quiesce_fence_waiting, operation_ref, pid}, state) do
    case Map.get(state.quiesce_fences, operation_ref) do
      %{pid: ^pid, status: :starting, phase_owner: phase_owner, session_id: session_id} = fence ->
        send(phase_owner, {:loopex_quiesce_fence_started, operation_ref, session_id, pid})

        {:noreply, put_in(state.quiesce_fences[operation_ref], %{fence | status: :waiting})}

      _other ->
        if Process.alive?(pid), do: Process.exit(pid, :kill)
        {:noreply, state}
    end
  end

  def handle_info(
        {:authorize_quiesce_fence, token, drain_id, operation_ref, phase_owner, deadline},
        state
      ) do
    case Map.get(state.quiesce_fences, operation_ref) do
      %{
        phase_owner: ^phase_owner,
        drain_id: ^drain_id,
        deadline: ^deadline,
        status: :waiting,
        pid: pid
      } = fence
      when token == state.token ->
        if deadline > System.monotonic_time(:millisecond) do
          send(pid, {:loopex_quiesce_fence_go, operation_ref, deadline})

          {:noreply, put_in(state.quiesce_fences[operation_ref], %{fence | status: :authorized})}
        else
          Process.exit(pid, :kill)

          {:noreply, put_in(state.quiesce_fences[operation_ref], %{fence | status: :cancelling})}
        end

      _other ->
        {:noreply, state}
    end
  end

  def handle_info(
        {:cancel_quiesce_fence, token, drain_id, operation_ref, phase_owner},
        state
      ) do
    case Map.get(state.quiesce_fences, operation_ref) do
      %{phase_owner: ^phase_owner, drain_id: ^drain_id, pid: pid} = fence
      when token == state.token ->
        if Process.alive?(pid), do: Process.exit(pid, :kill)

        {:noreply, put_in(state.quiesce_fences[operation_ref], %{fence | status: :cancelling})}

      _other ->
        if token == state.token and state.quiescing == drain_id do
          send(phase_owner, {:loopex_quiesce_fence_cancelled, operation_ref})
        end

        {:noreply, state}
    end
  end

  def handle_info(
        {:quiesce_fence_head, operation_ref, pid, head},
        state
      ) do
    case Map.get(state.quiesce_fences, operation_ref) do
      %{pid: ^pid, phase_owner: phase_owner, session_id: session_id}
      when is_map(head) ->
        send(phase_owner, {:loopex_quiesce_fence_head, operation_ref, session_id, pid, head})
        {:noreply, state}

      _other ->
        {:noreply, state}
    end
  end

  def handle_info(
        {:quiesce_fence_result, operation_ref, pid, result},
        state
      ) do
    case Map.get(state.quiesce_fences, operation_ref) do
      %{pid: ^pid, phase_owner: phase_owner, session_id: session_id} = fence ->
        Logger.debug("runtime quiesce fence completed")
        send(phase_owner, {:loopex_quiesce_fence_result, operation_ref, session_id, pid, result})

        {:noreply,
         put_in(state.quiesce_fences[operation_ref], %{fence | result: result, status: :done})}

      _other ->
        {:noreply, state}
    end
  end

  def handle_info({:trace_hello, tracer, incarnation}, state)
      when is_pid(tracer) and is_binary(incarnation) and byte_size(incarnation) == 16 do
    {:noreply, register_tracer(state, tracer, incarnation)}
  end

  def handle_info(
        {:trace_reply, tracer, incarnation, request_ref, result, metadata, applied_version},
        %{trace: %{pid: tracer, incarnation: incarnation}} = state
      ) do
    case Map.pop(state.trace_pending, request_ref) do
      {nil, _pending} ->
        {:noreply, state}

      {item, pending} ->
        state = %{state | trace_pending: pending}

        if result in [:ok] or match?({:ok, _}, result) do
          if applied_version == state.trace_version do
            {:noreply, finish_trace_operation(state, item, result, metadata)}
          else
            {:noreply, dispatch_trace_sync(state, item, result, metadata)}
          end
        else
          {:noreply, finish_trace_operation(state, item, result, metadata)}
        end
    end
  end

  def handle_info(
        {:trace_reply, _tracer, _incarnation, _request_ref, _result, _metadata, _applied_version},
        state
      ) do
    {:noreply, state}
  end

  def handle_info({:trace_exclude, token, caller, functions, reply_to}, state) do
    cond do
      token != state.token ->
        GenServer.reply(reply_to, {:error, :unavailable})
        {:noreply, state}

      not Process.alive?(caller) ->
        GenServer.reply(reply_to, {:error, :unavailable})
        {:noreply, state}

      not valid_trace_functions?(functions) ->
        GenServer.reply(reply_to, {:error, :unavailable})
        {:noreply, state}

      true ->
        functions = functions |> Enum.uniq() |> MapSet.new()
        state = register_trace_exclusion(state, caller, functions)
        {:noreply, queue_trace_operation(state, {:exclude, caller}, reply_to)}
    end
  end

  def handle_info(
        {:dispatcher_ready, dispatcher, incarnation, registration_ref, ready_token},
        state
      ) do
    case state.dispatcher do
      %{
        pid: ^dispatcher,
        incarnation: ^incarnation,
        registration_ref: ^registration_ref,
        ready_token: ^ready_token,
        status: :ready_pending
      } = registered ->
        Enum.each(state.dispatcher_ready_waiters, &GenServer.reply(&1, :ok))

        next = %{
          state
          | dispatcher: %{registered | status: :ready},
            dispatcher_ready_waiters: []
        }

        {:noreply, drain_dispatcher_waiting_attaches(next)}

      _other ->
        {:noreply, state}
    end
  end

  def handle_info(
        {:attachment_staged, dispatcher, dispatcher_incarnation, attach_ref, attachment_id,
         incarnation_id, response},
        state
      ) do
    case Map.get(state.pending_attachments, attach_ref) do
      %{
        dispatcher: ^dispatcher,
        dispatcher_incarnation: ^dispatcher_incarnation,
        phase: :reserved,
        id: ^attachment_id,
        incarnation_id: ^incarnation_id
      } = pending ->
        with false <- pending.holder_down,
             {:ok, %{status: :active, owner: %{generation: generation}} = entry} <-
               Map.fetch(state.sessions, pending.session_id),
             true <- generation == pending.generation,
             :ok <- replacement_target(entry.attachments, pending.holder, pending.options) do
          EventDispatcher.authorize_attachment(
            dispatcher,
            dispatcher_incarnation,
            self(),
            attach_ref,
            attachment_id,
            incarnation_id
          )

          next_pending = %{pending | phase: :authorized, response: response}

          {:noreply,
           %{
             state
             | pending_attachments: Map.put(state.pending_attachments, attach_ref, next_pending)
           }}
        else
          _other ->
            {:noreply,
             discard_pending_attachment(
               state,
               attach_ref,
               if(pending.holder_down,
                 do: :holder_unavailable,
                 else: :attachment_superseded
               )
             )}
        end

      _other ->
        EventDispatcher.discard_staged_attachment(
          dispatcher,
          dispatcher_incarnation,
          self(),
          attach_ref
        )

        {:noreply, state}
    end
  end

  def handle_info(
        {:attachment_stage_failed, dispatcher, dispatcher_incarnation, attach_ref, reason},
        state
      ) do
    case Map.get(state.pending_attachments, attach_ref) do
      %{dispatcher: ^dispatcher, dispatcher_incarnation: ^dispatcher_incarnation} = pending ->
        terminal =
          cond do
            pending.holder_down -> :holder_unavailable
            reason in [:holder_unavailable, :attachment_superseded, :stale_attachment] -> reason
            true -> reason
          end

        {:noreply, finish_pending_attachment(state, attach_ref, {:error, terminal})}

      _other ->
        {:noreply, state}
    end
  end

  def handle_info(
        {:attachment_published, dispatcher, dispatcher_incarnation, attach_ref, attachment_id,
         incarnation_id, response},
        state
      ) do
    case Map.get(state.pending_attachments, attach_ref) do
      %{
        dispatcher: ^dispatcher,
        dispatcher_incarnation: ^dispatcher_incarnation,
        phase: phase,
        id: ^attachment_id,
        incarnation_id: ^incarnation_id
      } = pending
      when phase in [:authorized, :discarding] ->
        case Map.get(state.sessions, pending.session_id) do
          %{status: :active, owner: %{generation: generation}} = entry
          when phase == :authorized and is_nil(pending.terminal) and
                 generation == pending.generation and not pending.holder_down ->
            current_attachment = %{
              status: :active,
              id: attachment_id,
              incarnation_id: incarnation_id,
              holder: pending.holder,
              dispatcher: dispatcher,
              dispatcher_incarnation: pending.dispatcher_incarnation,
              request_id: pending.request_id,
              binding: pending.binding,
              response: response
            }

            attachments =
              entry.attachments
              |> Map.delete(pending.options[:replace_attachment_id])
              |> Map.put(attachment_id, current_attachment)

            next =
              state
              |> Map.put(
                :sessions,
                Map.put(state.sessions, pending.session_id, %{entry | attachments: attachments})
              )
              |> complete_control_attachment(
                pending.holder,
                attach_ref,
                attachment_id,
                pending.options[:replace_attachment_id]
              )

            {:noreply,
             next
             |> reply_attachment_callers(pending, {:ok, response})
             |> maybe_reply_holder_release(pending.holder)}

          _other ->
            terminal =
              if pending.holder_down,
                do: :holder_unavailable,
                else: :attachment_superseded

            EventDispatcher.remove_published_attachment(
              dispatcher,
              dispatcher_incarnation,
              self(),
              attach_ref,
              attachment_id,
              incarnation_id
            )

            next_pending = %{pending | phase: :cleanup, terminal: terminal, response: response}

            {:noreply,
             %{
               state
               | pending_attachments: Map.put(state.pending_attachments, attach_ref, next_pending)
             }}
        end

      _other ->
        EventDispatcher.remove_published_attachment(
          dispatcher,
          dispatcher_incarnation,
          self(),
          attach_ref,
          attachment_id,
          incarnation_id
        )

        {:noreply, state}
    end
  end

  def handle_info(
        {:attachment_discarded, dispatcher, dispatcher_incarnation, attach_ref},
        state
      ) do
    case Map.get(state.pending_attachments, attach_ref) do
      %{
        dispatcher: ^dispatcher,
        dispatcher_incarnation: ^dispatcher_incarnation,
        phase: :cleanup
      } ->
        {:noreply, state}

      %{dispatcher: ^dispatcher, dispatcher_incarnation: ^dispatcher_incarnation} = pending ->
        reason = pending.terminal || :attachment_superseded
        {:noreply, finish_pending_attachment(state, attach_ref, {:error, reason})}

      _other ->
        {:noreply, state}
    end
  end

  def handle_info(
        {:attachment_removed, dispatcher, dispatcher_incarnation, attach_ref, attachment_id,
         incarnation_id},
        state
      ) do
    case Map.get(state.pending_attachments, attach_ref) do
      %{
        dispatcher: ^dispatcher,
        dispatcher_incarnation: ^dispatcher_incarnation,
        id: ^attachment_id,
        incarnation_id: ^incarnation_id
      } = pending ->
        reason = pending.terminal || :holder_unavailable
        {:noreply, finish_pending_attachment(state, attach_ref, {:error, reason})}

      _other ->
        {:noreply, state}
    end
  end

  def handle_info(
        {:DOWN, monitor, :process, dispatcher, _reason},
        %{dispatcher: %{pid: dispatcher, monitor: monitor}} = state
      ) do
    {:noreply, %{clear_attachment_generation(state) | dispatcher: nil}}
  end

  def handle_info(
        {:DOWN, monitor, :process, tracer, _reason},
        %{trace: %{pid: tracer, monitor: monitor}} = state
      ) do
    {:noreply, trace_process_down(state)}
  end

  def handle_info({:DOWN, monitor, :process, pid, _reason}, state)
      when is_map_key(state.quiesce_fence_monitors, monitor) do
    {operation_ref, monitor_index} = Map.pop(state.quiesce_fence_monitors, monitor)
    {fence, fences} = Map.pop(state.quiesce_fences, operation_ref)

    if is_map(fence) and fence.pid == pid do
      case fence.status do
        :cancelling ->
          send(fence.phase_owner, {:loopex_quiesce_fence_cancelled, operation_ref})

        :done ->
          send(fence.phase_owner, {:loopex_quiesce_fence_closed, operation_ref})

        _failed ->
          send(
            fence.phase_owner,
            {:loopex_quiesce_fence_failed, operation_ref, fence.session_id}
          )
      end
    end

    {:noreply, %{state | quiesce_fences: fences, quiesce_fence_monitors: monitor_index}}
  end

  def handle_info({:DOWN, reference, :process, pid, _reason}, state) do
    case Map.pop(state.trace_exclusion_monitors, reference) do
      {^pid, monitors} ->
        next =
          state
          |> Map.put(:trace_exclusion_monitors, monitors)
          |> remove_trace_exclusion(pid)
          |> sync_trace_membership()

        {:noreply, next}

      {nil, _trace_monitors} ->
        handle_non_trace_down(reference, pid, state)
    end
  end

  defp handle_non_trace_down(reference, pid, state) do
    case Map.pop(state.attachment_monitor_to_holder, reference) do
      {^pid, monitors} ->
        next =
          state
          |> Map.put(:attachment_monitor_to_holder, monitors)
          |> mark_control_holder_down(pid)

        {:noreply, next}

      {nil, _monitors} ->
        case Map.pop(state.attachment_caller_monitors, reference) do
          {attach_ref, caller_monitors} when is_reference(attach_ref) ->
            {:noreply,
             state
             |> Map.put(:attachment_caller_monitors, caller_monitors)
             |> drop_attachment_caller(attach_ref, reference)}

          {nil, _caller_monitors} ->
            handle_session_monitor_down(reference, pid, state)
        end
    end
  end

  defp enqueue_trace_operation(state, operation, from) do
    {:noreply, queue_trace_operation(state, operation, from)}
  end

  defp queue_trace_operation(
         %{trace: %{status: :ready}, trace_pending: pending} = state,
         operation,
         from
       )
       when map_size(pending) == 0 do
    dispatch_trace_operation(state, operation, %{kind: :caller, from: from, operation: operation})
  end

  defp queue_trace_operation(state, operation, from) do
    %{state | trace_waiting: :queue.in({operation, from}, state.trace_waiting)}
  end

  defp dispatch_trace_operation(state, operation, item) do
    request_ref = make_ref()
    %{pid: tracer, incarnation: incarnation} = state.trace

    send(
      tracer,
      {:trace_operation, self(), incarnation, request_ref, operation, trace_snapshot(state)}
    )

    %{state | trace_pending: Map.put(state.trace_pending, request_ref, item)}
  end

  defp dispatch_trace_sync(state, item, result, metadata) do
    dispatch_trace_operation(
      state,
      :sync,
      %{kind: :after_sync, original: item, result: result, metadata: metadata}
    )
  end

  defp finish_trace_operation(state, %{kind: :registration}, :ok, metadata) do
    trace = %{state.trace | status: :ready}
    state = %{state | trace: trace, trace_session: metadata}
    drain_trace_waiting(state)
  end

  defp finish_trace_operation(state, %{kind: :registration}, _error, _metadata) do
    %{state | trace: %{state.trace | status: :ready}, trace_session: nil}
    |> drain_trace_waiting()
  end

  defp finish_trace_operation(
         state,
         %{kind: :after_sync, original: original, result: result, metadata: metadata},
         :ok,
         sync_metadata
       ) do
    metadata = sync_metadata || metadata
    finish_trace_operation(state, original, result, metadata)
  end

  defp finish_trace_operation(state, %{kind: :after_sync, original: original}, error, _metadata) do
    finish_trace_operation(state, original, error, nil)
  end

  defp finish_trace_operation(state, %{kind: :internal_sync}, _result, _metadata),
    do: drain_trace_waiting(state)

  defp finish_trace_operation(
         state,
         %{kind: :caller, from: from, operation: operation},
         result,
         metadata
       ) do
    state = update_trace_session(state, operation, result, metadata)

    state =
      if match?({:exclude, _pid}, operation) and result != :ok do
        {:exclude, pid} = operation
        GenServer.reply(from, {:error, :unavailable})
        state |> remove_trace_exclusion(pid) |> sync_trace_membership()
      else
        GenServer.reply(from, result)
        state
      end

    drain_trace_waiting(state)
  end

  defp update_trace_session(state, {:start, _config}, {:ok, _description}, metadata),
    do: %{state | trace_session: metadata}

  defp update_trace_session(state, :stop, :ok, _metadata),
    do: %{state | trace_session: nil}

  defp update_trace_session(state, _operation, _result, _metadata), do: state

  defp register_tracer(state, tracer, incarnation) do
    state =
      case state.trace do
        %{pid: ^tracer, incarnation: ^incarnation} ->
          state

        %{pid: old, monitor: monitor} when is_pid(old) ->
          if Process.alive?(old) do
            state
          else
            Process.demonitor(monitor, [:flush])
            trace_process_down(state)
          end

        _none ->
          state
      end

    case state.trace do
      %{pid: ^tracer, incarnation: ^incarnation} ->
        state

      nil ->
        monitor = Process.monitor(tracer)
        trace = %{pid: tracer, incarnation: incarnation, monitor: monitor, status: :pending}
        state = %{state | trace: trace}

        dispatch_trace_operation(
          state,
          {:reconcile, state.trace_session},
          %{kind: :registration}
        )

      _other ->
        state
    end
  end

  defp trace_process_down(state) do
    waiting =
      Enum.reduce(state.trace_pending, state.trace_waiting, fn
        {_ref, %{kind: :caller, operation: operation, from: from}}, queue ->
          :queue.in({operation, from}, queue)

        {_ref, %{kind: :after_sync, original: %{kind: :caller} = original}}, queue ->
          :queue.in({original.operation, original.from}, queue)

        _internal, queue ->
          queue
      end)

    %{state | trace: nil, trace_pending: %{}, trace_waiting: waiting}
  end

  defp drain_trace_waiting(%{trace: %{status: :ready}} = state) do
    if map_size(state.trace_pending) == 0 do
      case :queue.out(state.trace_waiting) do
        {{:value, {operation, :internal}}, waiting} ->
          state
          |> Map.put(:trace_waiting, waiting)
          |> dispatch_trace_operation(operation, %{kind: :internal_sync})

        {{:value, {operation, from}}, waiting} ->
          state
          |> Map.put(:trace_waiting, waiting)
          |> dispatch_trace_operation(operation, %{
            kind: :caller,
            from: from,
            operation: operation
          })

        {:empty, _queue} ->
          state
      end
    else
      state
    end
  end

  defp drain_trace_waiting(state), do: state

  defp register_trace_exclusion(state, pid, functions) do
    case Map.fetch(state.trace_excluded, pid) do
      {:ok, %{functions: existing}} ->
        added = MapSet.difference(functions, existing)
        entry = Map.fetch!(state.trace_excluded, pid)

        %{
          state
          | trace_excluded:
              Map.put(state.trace_excluded, pid, %{
                entry
                | functions: MapSet.union(existing, functions)
              }),
            trace_mfa_counts: increment_trace_mfas(state.trace_mfa_counts, added),
            trace_version: state.trace_version + if(MapSet.size(added) > 0, do: 1, else: 0)
        }

      :error ->
        monitor = Process.monitor(pid)

        %{
          state
          | trace_excluded:
              Map.put(state.trace_excluded, pid, %{monitor: monitor, functions: functions}),
            trace_exclusion_monitors: Map.put(state.trace_exclusion_monitors, monitor, pid),
            trace_mfa_counts: increment_trace_mfas(state.trace_mfa_counts, functions),
            trace_version: state.trace_version + 1
        }
    end
  end

  defp remove_trace_exclusion(state, pid) do
    case Map.pop(state.trace_excluded, pid) do
      {nil, _excluded} ->
        state

      {%{monitor: monitor, functions: functions}, excluded} ->
        Process.demonitor(monitor, [:flush])

        %{
          state
          | trace_excluded: excluded,
            trace_exclusion_monitors: Map.delete(state.trace_exclusion_monitors, monitor),
            trace_mfa_counts: decrement_trace_mfas(state.trace_mfa_counts, functions),
            trace_version: state.trace_version + 1
        }
    end
  end

  defp increment_trace_mfas(counts, functions) do
    Enum.reduce(functions, counts, fn mfa, acc -> Map.update(acc, mfa, 1, &(&1 + 1)) end)
  end

  defp decrement_trace_mfas(counts, functions) do
    Enum.reduce(functions, counts, fn mfa, acc ->
      case Map.get(acc, mfa) do
        1 -> Map.delete(acc, mfa)
        count when is_integer(count) and count > 1 -> Map.put(acc, mfa, count - 1)
        _absent -> acc
      end
    end)
  end

  defp sync_trace_membership(%{trace: %{status: :ready}, trace_pending: pending} = state)
       when map_size(pending) == 0 do
    dispatch_trace_operation(state, :sync, %{kind: :internal_sync})
  end

  defp sync_trace_membership(%{trace: %{status: :ready}} = state) do
    %{state | trace_waiting: :queue.in({:sync, :internal}, state.trace_waiting)}
  end

  defp sync_trace_membership(state), do: state

  defp trace_snapshot(state) do
    %{
      version: state.trace_version,
      excluded_pids: state.trace_excluded |> Map.keys() |> MapSet.new(),
      excluded_mfas: state.trace_mfa_counts |> Map.keys() |> MapSet.new()
    }
  end

  defp valid_trace_functions?([]), do: true

  defp valid_trace_functions?([{module, function, arity} | rest])
       when is_atom(module) and is_atom(function) and is_integer(arity) and arity >= 0,
       do: valid_trace_functions?(rest)

  defp valid_trace_functions?(_invalid), do: false

  defp handle_session_monitor_down(reference, pid, state) do
    case Map.pop(state.monitor_to_session, reference) do
      {nil, _monitors} ->
        {:noreply, state}

      {{:coordinator, session_id, ^pid}, monitors} ->
        state = %{state | monitor_to_session: monitors}

        case Map.fetch(state.sessions, session_id) do
          {:ok, %{status: :acquiring, coordinator: ^pid} = entry} ->
            EventDispatcher.release_fence(state.root, session_id)
            unavailable = entry |> Map.put(:status, :unavailable) |> Map.put(:waiting, nil)
            next = %{state | sessions: Map.put(state.sessions, session_id, unavailable)}
            reply_waiting(entry, {:error, :owner_recovery_failed}, next, session_id)
            {:noreply, next}

          {:ok, %{status: :active, coordinator: ^pid}} ->
            EventDispatcher.release_fence(state.root, session_id)
            {:noreply, state}

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
             owner_command: owner_command,
             prepared: prepared
           } = entry} ->
            if is_nil(state.quiescing) do
              cleared = %{state | sessions: Map.delete(state.sessions, session_id)}

              case do_start_owner(
                     cleared,
                     session_id,
                     succession_id,
                     waiting,
                     owner_command,
                     prepared
                   ) do
                {:waiting, next} ->
                  {:noreply, next}

                {:error, reason, next, disposition} ->
                  reply_session_waiters(
                    waiting,
                    {:error, reason},
                    next,
                    session_id,
                    disposition
                  )

                  {:noreply, next}
              end
            else
              unavailable = entry |> Map.put(:status, :unavailable) |> Map.put(:waiting, nil)
              next = %{state | sessions: Map.put(state.sessions, session_id, unavailable)}

              reply_session_waiters(
                waiting,
                {:error, :runtime_unavailable},
                next,
                session_id,
                :no_activation
              )

              {:noreply, next}
            end

          {:ok, %{status: :active, owner_group: ^pid} = entry} ->
            EventDispatcher.release_fence(state.root, session_id)
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
  defp create_session(state, command_id, session_options, from, mode) do
    with true <- valid_identifier?(command_id),
         {:ok, genesis} <- session_genesis(session_options, state.cleanup_grace_ms),
         {:ok, transaction} <- Store.create_session(state.runtime_id, command_id, genesis),
         {:ok, fresh?} <- create_command_absent?(state, command_id, transaction) do
      {outcome, lane} = resolve_transaction(state.lane, transaction)
      state = %{state | lane: lane}
      transaction_session_id = Map.get(transaction, :session_id)

      case outcome do
        {:committed, ^command_id, %{type: :create_session, session_id: session_id}} ->
          cond do
            match?({:ok, %{status: :active}}, Map.fetch(state.sessions, session_id)) ->
              reply =
                detailed_session_reply(
                  {:ok, session_id},
                  mode,
                  :no_activation,
                  state,
                  session_id
                )

              {:reply, reply, state}

            not fresh? ->
              reply =
                detailed_session_reply(
                  {:ok, session_id},
                  mode,
                  :no_activation,
                  state,
                  session_id
                )

              {:reply, reply, state}

            true ->
              case start_owner(
                     state,
                     session_id,
                     succession_id(state.runtime_id, "create", session_id, command_id),
                     from,
                     nil,
                     mode
                   ) do
                {:waiting, next} ->
                  {:noreply, next}

                {:error, reason, next, disposition} ->
                  reply =
                    detailed_session_reply(
                      {:error, reason},
                      mode,
                      disposition,
                      next,
                      session_id
                    )

                  {:reply, reply, next}
              end
          end

        {:not_committed, reason} ->
          reply =
            detailed_session_reply(
              {:error, reason},
              mode,
              :no_activation,
              state,
              transaction_session_id
            )

          {:reply, reply, state}

        {:commit_unknown, _tx_id} ->
          reply =
            detailed_session_reply(
              {:error, :commit_unknown},
              mode,
              :no_activation,
              state,
              transaction_session_id
            )

          {:reply, reply, state}

        {:fenced, :commit_unknown} ->
          reply =
            detailed_session_reply(
              {:error, :commit_unknown},
              mode,
              :no_activation,
              state,
              transaction_session_id
            )

          {:reply, reply, state}
      end
    else
      {:error, :session_configuration_too_large} ->
        reply =
          detailed_session_reply(
            {:error, :session_configuration_too_large},
            mode,
            :no_activation,
            state,
            nil
          )

        {:reply, reply, state}

      {:error, :store_unavailable} ->
        reply =
          detailed_session_reply(
            {:error, :store_unavailable},
            mode,
            :no_activation,
            state,
            nil
          )

        {:reply, reply, state}

      _other ->
        reply =
          detailed_session_reply(
            {:error, :invalid_session_creation},
            mode,
            :no_activation,
            state,
            nil
          )

        {:reply, reply, state}
    end
  end

  # Concept: only a create whose command key the Store proves was absent an
  # instant ago may take ownership of the session it creates.
  #
  # Technical depth: ADR 0008 makes a completed create replay historical only --
  # it "returns its original result without advancing the epoch" and "does not
  # recreate a dead coordinator" -- and reserves ownership acquisition for the
  # staged resume paths. `Store.transact/2` cannot carry that distinction: an
  # exact re-presentation returns the retained receipt byte-for-byte, so a
  # runtime that lost its process-local session table read its own replay as a
  # first commit and advanced the epoch through the create path's unstaged
  # succession. The runtime-command read is the one API keyed by exactly
  # `runtime_id + command_id`, and `:absent` is the only answer that proves this
  # transaction is the one committing now. Every other answer -- a retained
  # entry, an open candidate, or a binding an adapter cannot project -- means
  # the freshness cannot be proved, so the command is answered from its durable
  # result and starts nothing. `:unavailable` decides nothing at all and commits
  # nothing.
  defp create_command_absent?(state, command_id, transaction) do
    case Store.runtime_command(
           state.store,
           create_command(state.runtime_id, command_id, transaction)
         ) do
      :absent -> {:ok, true}
      :unavailable -> {:error, :store_unavailable}
      _retained -> {:ok, false}
    end
  end

  defp create_command(runtime_id, command_id, transaction) do
    %{
      runtime_id: runtime_id,
      command_id: command_id,
      command_kind: :create,
      mutation_domain: "session",
      succession_id: succession_id(runtime_id, "create", "", command_id),
      canonical_command_bytes: transaction.canonical_record_bytes,
      canonical_command_digest: transaction.canonical_mutation_digest
    }
  end

  defp lookup_create_result(state, command_id, session_options) do
    with true <- valid_identifier?(command_id),
         {:ok, genesis} <- session_genesis(session_options, state.cleanup_grace_ms),
         {:ok, transaction} <- Store.create_session(state.runtime_id, command_id, genesis) do
      command = create_command(state.runtime_id, command_id, transaction)

      case Store.runtime_command(state.store, command) do
        {:completed, %{result: session_id}} when is_binary(session_id) ->
          {:historical, session_id}

        :absent ->
          :absent

        {:error, :runtime_command_conflict} ->
          :conflict

        :unavailable ->
          :store_unavailable

        _other ->
          :unexpected
      end
    else
      _invalid -> :unexpected
    end
  end

  @genesis_item_bytes 65_536
  @uint64_max 18_446_744_073_709_551_615

  # Technical depth: the period is checked again on the way into the genesis,
  # because this is the last clause before `Store.create_session/3` and therefore
  # the last place a value outside ADR 0016's `1..2^64-1` can be stopped from
  # becoming durable. Replay enforces the same domain, so a record naming a
  # larger period is a session that exists and can never be owned. The refusal is
  # this path's own `invalid_session_creation`: the create is what is refused,
  # and no new reason enters the public reply shape.
  defp session_genesis(_session_options, cleanup_grace_ms)
       when not (is_integer(cleanup_grace_ms) and cleanup_grace_ms > 0 and
                   cleanup_grace_ms <= @uint64_max),
       do: {:error, :invalid_session_creation}

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

  defp start_owner(
         %{quiescing: quiescing} = state,
         _session_id,
         _succession_id,
         _from,
         _owner_command,
         _mode
       )
       when not is_nil(quiescing),
       do: {:error, :runtime_unavailable, state, :no_activation}

  defp start_owner(
         state,
         session_id,
         succession_id,
         from,
         owner_command,
         mode
       ) do
    prepared = prepared_capability(mode, from)

    case Map.get(state.sessions, session_id) do
      %{
        status: :acquiring,
        owner_command: %{succession_id: ^succession_id}
      } = entry
      when not is_nil(owner_command) ->
        waiter = session_waiter(from, mode, :no_activation)
        waiting = Map.update!(entry, :waiting, &[waiter | &1])
        {:waiting, %{state | sessions: Map.put(state.sessions, session_id, waiting)}}

      %{status: :acquiring} ->
        {:error, :owner_acquiring, state, :no_activation}

      %{status: :awaiting_owner_barrier} ->
        {:error, :owner_acquiring, state, :no_activation}

      _other ->
        begin_new_owner(state, session_id, succession_id, from, owner_command, prepared, mode)
    end
  end

  defp begin_new_owner(
         state,
         session_id,
         succession_id,
         from,
         owner_command,
         prepared,
         mode
       ) do
    with {:ok, state} <- begin_owner_succession(state, session_id, prepared) do
      case Map.get(state.sessions, session_id) do
        %{coordinator: coordinator, owner_group: owner_group} = entry
        when is_pid(coordinator) and is_pid(owner_group) ->
          if not Process.alive?(coordinator) and Process.alive?(owner_group) do
            waiting =
              entry
              |> Map.put(:status, :awaiting_owner_barrier)
              |> Map.put(:succession_id, succession_id)
              |> Map.put(:owner_command, owner_command)
              |> Map.put(:prepared, prepared)
              |> Map.put(:waiting, [{from, mode}])

            {:waiting, %{state | sessions: Map.put(state.sessions, session_id, waiting)}}
          else
            do_start_owner(
              state,
              session_id,
              succession_id,
              [{from, mode}],
              owner_command,
              prepared
            )
          end

        _other ->
          do_start_owner(
            state,
            session_id,
            succession_id,
            [{from, mode}],
            owner_command,
            prepared
          )
      end
    else
      {:error, reason, next} -> {:error, reason, next, :no_activation}
    end
  end

  defp begin_owner_succession(state, _session_id, prepared) when is_map(prepared),
    do: {:ok, state}

  defp begin_owner_succession(state, session_id, _ordinary) do
    case Map.get(state.sessions, session_id) do
      nil ->
        {:ok, state}

      previous ->
        cleared_entry = clear_entry_attachments(previous)
        routes_cleared = %{state | sessions: Map.put(state.sessions, session_id, cleared_entry)}

        case current_dispatcher(state) do
          {:ok, dispatcher} ->
            case EventDispatcher.invalidate_session(dispatcher.pid, session_id) do
              {:ok, removed} ->
                next = drop_session_attachments(routes_cleared, previous, session_id)

                Enum.each(removed, fn attachment ->
                  send(
                    attachment.holder,
                    {:loopex_attachment_invalidated, session_id, attachment.attachment_id,
                     attachment.attachment_incarnation, attachment.cursor}
                  )
                end)

                {:ok, next}

              {:error, :dispatcher_unavailable} ->
                {:error, :runtime_unavailable, routes_cleared}
            end

          {:error, :runtime_unavailable} ->
            {:error, :runtime_unavailable, routes_cleared}
        end
    end
  end

  defp do_start_owner(state, session_id, succession_id, waiting, owner_command, prepared) do
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
          policy_identity: state.policy_identity,
          project_manifest: state.project_manifest,
          project_decision: state.project_decision,
          resource_snapshot: state.resource_snapshot,
          sampling: state.sampling,
          grant_decision: state.grant_decision,
          fault_to: state.fault_to,
          cleanup_grace_ms: state.cleanup_grace_ms,
          context_token_budget: state.context_token_budget,
          runtime_id: state.runtime_id,
          prepared: prepared
        ]

        case DynamicSupervisor.start_child(session_supervisor, {SessionCoordinator, options}) do
          {:ok, coordinator} ->
            state = record_writer_domain(state, session_id)

            case OwnerGroup.attach(owner_group, coordinator) do
              :ok ->
                await_owner(
                  state,
                  session_id,
                  generation,
                  coordinator,
                  owner_group,
                  counter,
                  activate_session_waiters(waiting),
                  owner_command,
                  prepared
                )

              {:error, reason} ->
                _ = DynamicSupervisor.terminate_child(session_supervisor, coordinator)
                _ = DynamicSupervisor.terminate_child(owner_groups, owner_group)

                unavailable_owner(
                  state,
                  session_id,
                  generation,
                  counter,
                  reason,
                  :activated
                )
            end

          {:error, reason} ->
            _ = DynamicSupervisor.terminate_child(owner_groups, owner_group)

            unavailable_owner(
              state,
              session_id,
              generation,
              counter,
              reason,
              :no_activation
            )
        end
      else
        {:error, reason} ->
          unavailable_owner(
            state,
            session_id,
            generation,
            counter,
            reason,
            :no_activation
          )
      end
    else
      _other -> {:error, :runtime_unavailable, state, :no_activation}
    end
  end

  defp unavailable_owner(state, session_id, generation, counter, reason, disposition) do
    unavailable = %{status: :unavailable, durable: nil, generation: generation}

    sessions =
      if normalize_start_error(reason) == :runtime_placement_mismatch,
        do: Map.delete(state.sessions, session_id),
        else: Map.put(state.sessions, session_id, unavailable)

    next = %{
      state
      | sessions: sessions,
        generation_counter: counter
    }

    {:error, normalize_start_error(reason), next, disposition}
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
         owner_command,
         prepared
       ) do
    coordinator_monitor = Process.monitor(coordinator)
    owner_group_monitor = Process.monitor(owner_group)

    entry = %{
      status: :acquiring,
      coordinator: coordinator,
      owner_group: owner_group,
      owner_command: owner_command,
      prepared: prepared,
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

  # Concept: the shutdown census covers every session for which this runtime
  # ever started a serial writer, including one that failed before readiness.
  #
  # Technical depth: membership is recorded in the same Control callback that
  # receives `DynamicSupervisor.start_child/2` success and is never removed.
  # `begin_quiesce/1` therefore freezes a monotonic writer-domain set without
  # inferring writer history from an entry's later status.
  defp record_writer_domain(state, session_id) do
    %{state | writer_domains: MapSet.put(state.writer_domains, session_id)}
  end

  # Concept: every invocation learns whether it started the shared owner it
  # waited for, independently of the result that owner eventually produced.
  #
  # Technical depth: the first waiter becomes `activated` only after the
  # coordinator child starts. An exact concurrent repetition joins as
  # `no_activation`. The reply observes Control's entry only after the callback
  # has installed its terminal state, so one shared owner result may carry
  # different dispositions without inventing a process or a Store fact.
  defp session_waiter(from, mode, disposition),
    do: %{from: from, mode: mode, disposition: disposition}

  defp activate_session_waiters(waiters) do
    Enum.map(waiters, fn
      %{from: _from, mode: _mode, disposition: _disposition} = waiter -> waiter
      {from, mode} -> session_waiter(from, mode, :activated)
    end)
  end

  defp reply_waiting(%{waiting: waiters}, reply, state, session_id)
       when is_list(waiters) do
    reply_session_waiters(waiters, reply, state, session_id, :activated)
  end

  defp reply_waiting(_entry, _reply, _state, _session_id), do: :ok

  defp reply_session_waiters(waiters, reply, state, session_id, default_disposition) do
    Enum.each(waiters, fn
      %{from: from, mode: mode, disposition: disposition} ->
        GenServer.reply(
          from,
          detailed_session_reply(reply, mode, disposition, state, session_id)
        )

      {from, mode} ->
        GenServer.reply(
          from,
          detailed_session_reply(reply, mode, default_disposition, state, session_id)
        )
    end)
  end

  defp detailed_session_reply({:ok, session_id}, :detailed, disposition, state, session_id)
       when disposition in [:activated, :no_activation] do
    {:ok,
     %{
       session_id: session_id,
       disposition: disposition,
       control_entry: session_control_entry(state, session_id)
     }}
  end

  defp detailed_session_reply({:error, reason}, :detailed, disposition, state, session_id)
       when disposition in [:activated, :no_activation] do
    disposition = detailed_error_disposition(reason, disposition)

    {:error, reason,
     %{
       disposition: disposition,
       control_entry: session_control_entry(state, session_id)
     }}
  end

  defp detailed_session_reply(
         {:error, :runtime_placement_mismatch},
         mode,
         _disposition,
         _state,
         _session_id
       )
       when mode in [:ordinary, :prepared],
       do: {:error, :owner_recovery_failed}

  defp detailed_session_reply(reply, _mode, _disposition, _state, _session_id), do: reply

  defp detailed_error_disposition(:runtime_placement_mismatch, _started), do: :no_activation
  defp detailed_error_disposition(_reason, disposition), do: disposition

  defp session_control_entry(state, session_id) do
    case Map.get(state.sessions, session_id) do
      %{status: :active} -> :active
      %{status: :acquiring} -> :acquiring
      _other -> :dormant
    end
  end

  defp notify_superseded(%{coordinator: coordinator}, generation) when is_pid(coordinator),
    do: GenServer.cast(coordinator, {:superseded, generation})

  defp notify_superseded(_old, _generation), do: :ok

  defp begin_attach(state, session_id, holder, options, from)
       when is_pid(holder) and is_list(options) do
    case current_dispatcher(state) do
      {:ok, dispatcher} ->
        begin_attach_with_dispatcher(state, session_id, holder, options, dispatcher, from)

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp begin_attach(state, _session_id, _holder, _options, _from),
    do: {:reply, {:error, :invalid_attachment_options}, state}

  defp begin_attach_with_dispatcher(state, session_id, holder, options, dispatcher, from) do
    with {:ok, entry} <- Map.fetch(state.sessions, session_id),
         true <- entry.status == :active,
         :ok <- holder_available(holder),
         {:ok, attach_options} <- validate_attach_options(options),
         :ok <- replacement_target(entry.attachments, holder, attach_options),
         :ok <- replacement_available(state, attach_options),
         :new <-
           attachment_repetition(
             state,
             session_id,
             entry,
             holder,
             attach_options,
             dispatcher
           ),
         :ok <- attachment_transaction_capacity(state) do
      {:noreply,
       reserve_attachment(
         state,
         session_id,
         entry,
         holder,
         attach_options,
         dispatcher,
         from
       )}
    else
      {:same, response} -> {:reply, {:ok, response}, state}
      {:pending, attach_ref} -> {:noreply, add_attachment_caller(state, attach_ref, from)}
      :conflict -> {:reply, {:error, :attachment_request_conflict}, state}
      :error -> {:reply, {:error, :session_unavailable}, state}
      false -> {:reply, {:error, :session_unavailable}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp validate_attach_options(options) do
    defaults = [
      after_event_sequence: nil,
      request_id: nil,
      client_id: nil,
      attachment_key: nil,
      replace_attachment_id: nil
    ]

    with {:ok, validated} <- Keyword.validate(options, defaults),
         :ok <- validate_optional_cursor(validated[:after_event_sequence]),
         :ok <- validate_optional_identifier(validated[:request_id]),
         :ok <- validate_optional_identifier(validated[:client_id]),
         :ok <- validate_optional_identifier(validated[:attachment_key]),
         :ok <- validate_optional_identifier(validated[:replace_attachment_id]) do
      {:ok, validated}
    else
      _other -> {:error, :invalid_attachment_options}
    end
  end

  defp attachment_repetition(
         state,
         session_id,
         %{attachments: attachments},
         holder,
         options,
         dispatcher
       ) do
    request_id = options[:request_id]
    binding = attachment_binding(options)

    current =
      Enum.find_value(attachments, fn {_id, attachment} ->
        if attachment.holder == holder and attachment.request_id == request_id,
          do: attachment
      end)

    pending =
      Enum.find(state.pending_attachments, fn {_attach_ref, attachment} ->
        attachment.session_id == session_id and attachment.holder == holder and
          attachment.request_id == request_id
      end)

    cond do
      is_nil(request_id) ->
        :new

      is_map(current) and current.binding == binding and
          current.dispatcher_incarnation == dispatcher.incarnation ->
        {:same, current.response}

      is_map(current) ->
        if current.binding == binding, do: :new, else: :conflict

      match?({_, %{binding: ^binding}}, pending) ->
        {attach_ref, _attachment} = pending
        {:pending, attach_ref}

      not is_nil(pending) ->
        :conflict

      true ->
        :new
    end
  end

  defp attachment_binding(options) do
    {
      options[:request_id],
      options[:client_id],
      options[:attachment_key],
      options[:after_event_sequence],
      options[:replace_attachment_id]
    }
  end

  defp replacement_target(attachments, holder, options) do
    case options[:replace_attachment_id] do
      nil ->
        :ok

      target ->
        case Map.get(attachments, target) do
          %{holder: ^holder} -> :ok
          _other -> {:error, :stale_attachment}
        end
    end
  end

  defp replacement_available(state, options) do
    case options[:replace_attachment_id] do
      nil ->
        :ok

      target ->
        if Enum.any?(state.pending_attachments, fn {_attach_ref, pending} ->
             pending.options[:replace_attachment_id] == target
           end) do
          {:error, :attachment_request_conflict}
        else
          :ok
        end
    end
  end

  defp attachment_transaction_capacity(state) do
    if map_size(state.pending_attachments) < @attachment_transaction_limit,
      do: :ok,
      else: {:error, :capacity_exceeded}
  end

  defp holder_available(holder) do
    if Process.alive?(holder), do: :ok, else: {:error, :holder_unavailable}
  end

  defp current_dispatcher(state) do
    case state.dispatcher do
      %{pid: dispatcher, incarnation: incarnation, status: :ready}
      when is_pid(dispatcher) and is_reference(incarnation) ->
        {:ok, %{pid: dispatcher, incarnation: incarnation}}

      _other ->
        {:error, :runtime_unavailable}
    end
  end

  defp drain_dispatcher_waiting_attaches(state) do
    case :queue.out(state.dispatcher_waiting_attaches) do
      {:empty, _queue} ->
        state

      {{:value, {from, session_id, holder, options}}, waiting} ->
        state = %{state | dispatcher_waiting_attaches: waiting}

        next =
          case begin_attach(state, session_id, holder, options, from) do
            {:reply, reply, updated} ->
              GenServer.reply(from, reply)
              updated

            {:noreply, updated} ->
              updated
          end

        drain_dispatcher_waiting_attaches(next)
    end
  end

  defp refuse_dispatcher_waiting_attaches(state) do
    state.dispatcher_waiting_attaches
    |> :queue.to_list()
    |> Enum.each(fn {from, _session_id, _holder, _options} ->
      GenServer.reply(from, {:error, :runtime_unavailable})
    end)

    %{state | dispatcher_waiting_attaches: :queue.new()}
  end

  defp quiesce_projection(state) do
    (state.quiesce_writer_domains || state.writer_domains)
    |> Enum.sort()
    |> Enum.map(fn session_id ->
      case Map.get(state.sessions, session_id) do
        nil ->
          %{
            session_id: session_id,
            status: :absent,
            coordinator: nil,
            owner: nil,
            writer_started?: true
          }

        entry ->
          %{
            session_id: session_id,
            status: Map.get(entry, :status, :unavailable),
            coordinator: Map.get(entry, :coordinator),
            owner: Map.get(entry, :owner),
            writer_started?: true
          }
      end
    end)
  end

  defp clear_attachment_generation(state) do
    state =
      Enum.reduce(state.pending_attachments, state, fn {_attach_ref, pending}, current ->
        reply_attachment_callers(current, pending, {:error, :attachment_superseded})
      end)

    Enum.each(state.attachment_holders, fn {_holder, entry} ->
      Process.demonitor(entry.monitor, [:flush])
    end)

    Enum.each(state.holder_release_waiters, fn {_holder, waiters} ->
      Enum.each(waiters, &GenServer.reply(&1, :ok))
    end)

    case state.dispatcher do
      %{monitor: monitor} -> Process.demonitor(monitor, [:flush])
      _other -> :ok
    end

    sessions =
      Map.new(state.sessions, fn {session_id, entry} ->
        {session_id, clear_entry_attachments(entry)}
      end)

    %{
      state
      | sessions: sessions,
        pending_attachments: %{},
        attachment_caller_monitors: %{},
        attachment_holders: %{},
        attachment_monitor_to_holder: %{},
        holder_release_waiters: %{}
    }
  end

  defp clear_entry_attachments(entry) when is_map(entry) do
    entry =
      if Map.has_key?(entry, :attachments), do: Map.put(entry, :attachments, %{}), else: entry

    case Map.get(entry, :previous) do
      previous when is_map(previous) ->
        Map.put(entry, :previous, clear_entry_attachments(previous))

      _other ->
        entry
    end
  end

  defp dispatcher_acknowledgement_seed(state) do
    state.sessions
    |> Enum.filter(fn {_session_id, entry} ->
      entry.status == :active and is_integer(entry.event_sequence) and entry.event_sequence >= 0
    end)
    |> Map.new(fn {session_id, entry} -> {session_id, entry.event_sequence} end)
  end

  defp reserve_attachment(state, session_id, entry, holder, options, dispatcher, from) do
    attach_ref = make_ref()
    counter = state.attachment_counter + 1
    attachment_id = fresh_id("attachment", session_id, counter)
    incarnation_id = fresh_id("incarnation", session_id, counter)

    state = ensure_control_holder(state, holder)

    holder_entry = Map.fetch!(state.attachment_holders, holder)
    holder_entry = %{holder_entry | pending: MapSet.put(holder_entry.pending, attach_ref)}

    pending = %{
      session_id: session_id,
      generation: entry.owner.generation,
      holder: holder,
      options: options,
      request_id: options[:request_id],
      binding: attachment_binding(options),
      dispatcher: dispatcher.pid,
      dispatcher_incarnation: dispatcher.incarnation,
      id: attachment_id,
      incarnation_id: incarnation_id,
      phase: :reserved,
      holder_down: false,
      terminal: nil,
      response: nil,
      callers: %{}
    }

    next =
      %{
        state
        | attachment_holders: Map.put(state.attachment_holders, holder, holder_entry),
          pending_attachments: Map.put(state.pending_attachments, attach_ref, pending),
          attachment_counter: counter
      }
      |> add_attachment_caller(attach_ref, from)

    EventDispatcher.stage_attachment(dispatcher.pid, self(), attach_ref, %{
      session_id: session_id,
      holder: holder,
      options: options,
      id: attachment_id,
      incarnation_id: incarnation_id,
      dispatcher_incarnation: dispatcher.incarnation
    })

    next
  end

  defp add_attachment_caller(state, attach_ref, from) do
    case Map.get(state.pending_attachments, attach_ref) do
      nil ->
        GenServer.reply(from, {:error, :attachment_superseded})
        state

      pending ->
        monitor = Process.monitor(elem(from, 0))
        caller = %{from: from, monitor: monitor}
        pending = %{pending | callers: Map.put(pending.callers, monitor, caller)}

        %{
          state
          | pending_attachments: Map.put(state.pending_attachments, attach_ref, pending),
            attachment_caller_monitors:
              Map.put(state.attachment_caller_monitors, monitor, attach_ref)
        }
    end
  end

  defp ensure_control_holder(state, holder) do
    case Map.get(state.attachment_holders, holder) do
      nil ->
        monitor = Process.monitor(holder)

        entry = %{
          monitor: monitor,
          pending: MapSet.new(),
          attachments: MapSet.new()
        }

        %{
          state
          | attachment_holders: Map.put(state.attachment_holders, holder, entry),
            attachment_monitor_to_holder:
              Map.put(state.attachment_monitor_to_holder, monitor, holder)
        }

      _entry ->
        state
    end
  end

  defp complete_control_attachment(state, holder, attach_ref, attachment_id, replaced_id) do
    state = %{state | pending_attachments: Map.delete(state.pending_attachments, attach_ref)}

    update_control_holder(state, holder, fn entry ->
      %{
        entry
        | pending: MapSet.delete(entry.pending, attach_ref),
          attachments:
            entry.attachments
            |> MapSet.delete(replaced_id)
            |> MapSet.put(attachment_id)
      }
    end)
  end

  defp discard_pending_attachment(state, attach_ref, reason) do
    case Map.get(state.pending_attachments, attach_ref) do
      nil ->
        state

      %{phase: phase} = pending when phase in [:discarding, :cleanup] ->
        next_pending = %{pending | terminal: pending.terminal || reason}

        %{
          state
          | pending_attachments: Map.put(state.pending_attachments, attach_ref, next_pending)
        }

      pending ->
        EventDispatcher.discard_staged_attachment(
          pending.dispatcher,
          pending.dispatcher_incarnation,
          self(),
          attach_ref
        )

        next_pending = %{pending | phase: :discarding, terminal: reason}

        %{
          state
          | pending_attachments: Map.put(state.pending_attachments, attach_ref, next_pending)
        }
    end
  end

  defp finish_pending_attachment(state, attach_ref, reply) do
    case Map.get(state.pending_attachments, attach_ref) do
      nil ->
        state

      pending ->
        state
        |> drop_control_pending(pending.holder, attach_ref)
        |> reply_attachment_callers(pending, reply)
        |> maybe_reply_holder_release(pending.holder)
    end
  end

  defp reply_attachment_callers(state, pending, reply) do
    Enum.reduce(pending.callers, state, fn {monitor, caller}, current ->
      Process.demonitor(monitor, [:flush])
      GenServer.reply(caller.from, reply)

      %{
        current
        | attachment_caller_monitors: Map.delete(current.attachment_caller_monitors, monitor)
      }
    end)
  end

  defp drop_attachment_caller(state, attach_ref, monitor) do
    case Map.get(state.pending_attachments, attach_ref) do
      nil ->
        state

      pending ->
        callers = Map.delete(pending.callers, monitor)

        %{
          state
          | pending_attachments:
              Map.put(state.pending_attachments, attach_ref, %{pending | callers: callers})
        }
    end
  end

  defp drop_control_pending(state, holder, attach_ref)
       when is_pid(holder) and is_reference(attach_ref) do
    state = %{state | pending_attachments: Map.delete(state.pending_attachments, attach_ref)}

    update_control_holder(state, holder, fn entry ->
      %{entry | pending: MapSet.delete(entry.pending, attach_ref)}
    end)
  end

  defp drop_control_pending(state, _holder, _attach_ref), do: state

  defp update_control_holder(state, holder, update) do
    case Map.get(state.attachment_holders, holder) do
      nil ->
        state

      entry ->
        updated = update.(entry)

        if MapSet.size(updated.pending) == 0 and MapSet.size(updated.attachments) == 0 do
          Process.demonitor(updated.monitor, [:flush])

          %{
            state
            | attachment_holders: Map.delete(state.attachment_holders, holder),
              attachment_monitor_to_holder:
                Map.delete(state.attachment_monitor_to_holder, updated.monitor)
          }
        else
          %{state | attachment_holders: Map.put(state.attachment_holders, holder, updated)}
        end
    end
  end

  defp mark_control_holder_down(state, holder) do
    case Map.get(state.attachment_holders, holder) do
      nil ->
        state

      entry ->
        sessions =
          Map.new(state.sessions, fn {session_id, session_entry} ->
            {session_id, remove_holder_from_session_entry(session_entry, holder)}
          end)

        Process.demonitor(entry.monitor, [:flush])

        next = %{
          state
          | sessions: sessions,
            attachment_holders: Map.delete(state.attachment_holders, holder),
            attachment_monitor_to_holder:
              Map.delete(state.attachment_monitor_to_holder, entry.monitor)
        }

        Enum.reduce(entry.pending, next, fn attach_ref, current ->
          case Map.get(current.pending_attachments, attach_ref) do
            nil ->
              current

            pending ->
              current = %{
                current
                | pending_attachments:
                    Map.put(
                      current.pending_attachments,
                      attach_ref,
                      %{pending | holder_down: true}
                    )
              }

              discard_pending_attachment(current, attach_ref, :holder_unavailable)
          end
        end)
    end
  end

  defp maybe_reply_holder_release(state, holder) do
    pending_for_holder? =
      Enum.any?(state.pending_attachments, fn {_attach_ref, pending} ->
        pending.holder == holder
      end)

    if pending_for_holder? do
      state
    else
      {waiters, retained} = Map.pop(state.holder_release_waiters, holder, [])
      Enum.each(waiters, &GenServer.reply(&1, :ok))
      %{state | holder_release_waiters: retained}
    end
  end

  defp remove_holder_from_session_entry(entry, holder) when is_map(entry) do
    entry =
      case Map.fetch(entry, :attachments) do
        {:ok, attachments} ->
          retained =
            attachments
            |> Enum.reject(fn {_id, attachment} -> attachment.holder == holder end)
            |> Map.new()

          Map.put(entry, :attachments, retained)

        :error ->
          entry
      end

    case Map.get(entry, :previous) do
      previous when is_map(previous) ->
        Map.put(entry, :previous, remove_holder_from_session_entry(previous, holder))

      _other ->
        entry
    end
  end

  defp remove_holder_from_session_entry(entry, _holder), do: entry

  defp drop_session_attachments(state, previous, session_id) do
    attachment_ids = previous |> then(&Map.get(&1 || %{}, :attachments, %{})) |> Map.keys()

    state =
      Enum.reduce(attachment_ids, state, fn attachment_id, current ->
        drop_control_attachment_from_holders(current, attachment_id)
      end)

    pending_refs =
      state.pending_attachments
      |> Enum.filter(fn {_ref, pending} -> pending.session_id == session_id end)
      |> Enum.map(&elem(&1, 0))

    Enum.reduce(pending_refs, state, fn attach_ref, current ->
      case Map.get(current.pending_attachments, attach_ref) do
        %{holder: _holder} ->
          discard_pending_attachment(current, attach_ref, :attachment_superseded)

        _other ->
          current
      end
    end)
  end

  defp drop_control_attachment_from_holders(state, attachment_id) do
    case Enum.find(state.attachment_holders, fn {_holder, entry} ->
           MapSet.member?(entry.attachments, attachment_id)
         end) do
      {holder, _entry} ->
        update_control_holder(state, holder, fn entry ->
          %{entry | attachments: MapSet.delete(entry.attachments, attachment_id)}
        end)

      nil ->
        state
    end
  end

  # Concept: the identity Control spends is the identity Control checked.
  #
  # Technical depth: the spent-permit key is this map, so reading only
  # `"session_id"` out of it left every other member free to vary: a binding
  # with an extra key, a missing key, or another attempt is a different map,
  # passed the unspent check, and was reported dispatched -- a second permit for
  # one attempt under a second spelling. ADR 0018 requires "every identity
  # equals its registered state" before the spend, and the coordinator builds
  # this map from the committed attempt-open record, so Control admits exactly
  # that closed six-member shape. The session member is then compared against
  # Control's own registered owner entry by the lookup below; the remaining
  # members name a journal position `authority` does not carry, which is why
  # their shape, not their value, is what Control can settle here.
  defp provider_binding_session(binding) do
    with :ok <- ProviderAttempt.validate_binding(binding) do
      {:ok, binding["session_id"]}
    end
  end

  defp provider_current_owner(state, session_id, %{coordinator: coordinator} = authority, caller)
       when is_pid(coordinator) do
    with %{status: :active, coordinator: ^coordinator, owner: owner} = entry <-
           Map.get(state.sessions, session_id),
         true <- caller == coordinator,
         true <- owner == Map.get(authority, :owner),
         true <- state.runtime_id == Map.get(authority, :runtime_id) do
      {:ok, entry}
    else
      _other -> {:error, :superseded_owner}
    end
  end

  defp provider_current_owner(_state, _session_id, _authority, _caller),
    do: {:error, :superseded_owner}

  defp provider_position_current(%{journal_version: current}, %{journal_version: named}) do
    if current == named, do: :ok, else: {:error, :stale_attempt_open_position}
  end

  defp provider_position_current(_entry, _authority), do: {:error, :stale_attempt_open_position}

  defp provider_worker_ready(%{worker: worker}) when is_pid(worker) do
    if Process.alive?(worker), do: :ok, else: {:error, :provider_worker_unavailable}
  end

  defp provider_worker_ready(_authority), do: {:error, :provider_worker_unavailable}

  defp provider_before_deadline(%{deadline: deadline}, wall_clock)
       when is_integer(deadline) and is_function(wall_clock, 0) do
    if wall_clock.() < deadline,
      do: :ok,
      else: {:error, :deadline_elapsed}
  end

  defp provider_before_deadline(_authority, _wall_clock), do: {:error, :deadline_elapsed}

  # Technical depth: callers allocate the message and the state they will
  # publish before entering this helper. Its only successful-path actions are
  # the final clock sample, comparison, and direct send; the receiver-side fence
  # covers the irreducible scheduler boundary between that sample and the send.
  defp send_provider_permit_before_deadline(worker, permit, %{deadline: deadline}, wall_clock)
       when is_pid(worker) and is_integer(deadline) and is_function(wall_clock, 0) do
    if wall_clock.() < deadline do
      send(worker, permit)
      :ok
    else
      {:error, :deadline_elapsed}
    end
  end

  defp send_provider_permit_before_deadline(_worker, _permit, _authority, _wall_clock),
    do: {:error, :deadline_elapsed}

  # Concept: the permit names the attempt the journal committed, never the
  # attempt the caller described.
  #
  # Technical depth: this answered `:ok` whenever nothing had been permitted at
  # the position yet, so the first request at any position was authorized on the
  # caller's own map. A request carrying a genuine owner, the genuine current
  # journal version and a live worker, but an invented run, turn, operation,
  # attempt and digest -- with no committed `model_attempt_opened_v1` row
  # anywhere in the session -- was replied `{:ok, :dispatched}` and handed a
  # permit. ADR 0018 requires "every identity equals its registered state"
  # before the spend, and Control registers no attempt identity of its own: its
  # session entry holds the journal position and the owner, and the post-commit
  # receipt holds positions only. The one honest registered state is therefore
  # the committed record, read here through the Store at exactly
  # `authority.journal_version` -- the position `provider_position_current/2`
  # has already proved is this session's current one, and the position each
  # attempt-open commits at. The binding is admitted only when it equals the six
  # members rebuilt from that row: the attempt-open record's five plus the
  # session it was read from. A row that is absent, of another kind, or
  # unreadable registers no identity, so it refuses; treating it as a pass is
  # the defect itself. Nothing has been sent at this point, so the coordinator
  # settles the refusal as ADR 0018's exact pre-transport `not_dispatched`. The
  # read costs one single-row Store page, bounded in both senses by
  # `bounded_position_read/3`, inside Control's serialized handler, which is the
  # price of comparing against durable truth rather than against the argument
  # being checked. An exact already-spent re-presentation is refused by
  # `provider_attempt_unspent/2` before this read, retaining its own refusal name.
  defp provider_position_binding(state, session_id, %{journal_version: version}, binding)
       when is_integer(version) and version > 0 do
    with {:ok, [%{journal_version: ^version, payload: payload}]} <-
           bounded_position_read(state.store, session_id, version),
         {:ok, ^binding} <- ProviderAttempt.binding_from_opened(session_id, payload) do
      :ok
    else
      _other -> {:error, :invalid_provider_attempt_binding}
    end
  end

  defp provider_position_binding(_state, _session_id, _authority, _binding),
    do: {:error, :invalid_provider_attempt_binding}

  # Concept: Control waits a bounded moment for that row, and a store that does
  # not answer inside it registers no identity.
  #
  # Technical depth: `Store.load_records/4` invokes the adapter in the calling
  # process, and the shipped local store answers through its own serialized
  # GenServer under a thirty-second call timeout. Read directly, that timeout
  # became Control's: one slow page could hold the runtime-wide ownership
  # serialization point, and burn a provider attempt's whole remaining
  # authority, before the deadline was re-established. The read therefore runs in
  # a monitored throwaway process and is awaited for `@position_read_timeout_ms`.
  # An exhausted bound is not a verdict about the row -- it is the absence of
  # one -- so it refuses exactly as an unreadable row does. A separate guardian
  # owns the Store-call worker and monitors Control itself. Timeout cancellation
  # and Control death both make the guardian kill and await that worker; a result
  # is forwarded only after the worker has exited. That keeps a blocked adapter
  # from surviving the private authority process that requested its read, while
  # preserving the rule that a missing answer is never a dispatch verdict. An
  # adapter that raises or exits is contained the same way instead of taking the
  # whole runtime's Control down with it.
  defp bounded_position_read(store, session_id, version) do
    bounded_records_read(store, session_id, version - 1, 1)
  end

  defp bounded_records_read(store, session_id, after_position, limit) do
    bounded_store_read(fn -> Store.load_records(store, session_id, after_position, limit) end)
  end

  defp bounded_receipt_records_read(store, session_id, after_position, limit) do
    # A Store page may be shorter than the caller's limit. Keep the complete
    # finite receipt scan under one guardian and therefore one existing deadline.
    bounded_store_read(fn ->
      collect_receipt_records(store, session_id, after_position, limit, [])
    end)
  end

  defp collect_receipt_records(_store, _session_id, _after_position, 0, records),
    do: {:ok, Enum.reverse(records)}

  defp collect_receipt_records(store, session_id, after_position, remaining, records) do
    case Store.load_records(store, session_id, after_position, remaining) do
      {:ok, []} ->
        {:error, :incomplete_settlement_range}

      {:ok, page} ->
        last = List.last(page).journal_version

        collect_receipt_records(
          store,
          session_id,
          last,
          remaining - length(page),
          Enum.reverse(page, records)
        )

      other ->
        other
    end
  end

  defp bounded_store_read(read) when is_function(read, 0) do
    control = self()
    tag = make_ref()

    {guardian, monitor} =
      spawn_monitor(fn ->
        guard_position_read(control, tag, read)
      end)

    receive do
      {^tag, result} ->
        receive do
          {:DOWN, ^monitor, :process, ^guardian, _reason} -> :ok
        end

        result

      {:DOWN, ^monitor, :process, ^guardian, _reason} ->
        :unavailable
    after
      @position_read_timeout_ms ->
        send(guardian, {:cancel_position_read, tag})

        receive do
          {:DOWN, ^monitor, :process, ^guardian, _reason} -> :ok
        end

        receive do
          {^tag, _late} -> :ok
        after
          0 -> :ok
        end

        :unavailable
    end
  end

  defp guard_position_read(control, tag, read) do
    control_monitor = Process.monitor(control)
    guardian = self()
    result_tag = make_ref()

    {reader, reader_monitor} =
      spawn_monitor(fn ->
        result = read.()
        send(guardian, {result_tag, result})
      end)

    await_position_read(
      control,
      control_monitor,
      tag,
      reader,
      reader_monitor,
      result_tag
    )
  end

  defp await_position_read(
         control,
         control_monitor,
         tag,
         reader,
         reader_monitor,
         result_tag
       ) do
    receive do
      {^result_tag, result} ->
        receive do
          {:DOWN, ^reader_monitor, :process, ^reader, _reason} -> :ok
        end

        Process.demonitor(control_monitor, [:flush])
        send(control, {tag, result})

      {:DOWN, ^reader_monitor, :process, ^reader, _reason} ->
        Process.demonitor(control_monitor, [:flush])
        :ok

      {:DOWN, ^control_monitor, :process, ^control, _reason} ->
        stop_position_reader(reader, reader_monitor)

      {:cancel_position_read, ^tag} ->
        Process.demonitor(control_monitor, [:flush])
        stop_position_reader(reader, reader_monitor)
    end
  end

  defp stop_position_reader(reader, monitor) do
    Process.exit(reader, :kill)

    receive do
      {:DOWN, ^monitor, :process, ^reader, _reason} -> :ok
    end
  end

  defp provider_attempt_unspent(state, binding) do
    if Map.has_key?(state.spent_attempts, binding),
      do: {:error, :provider_attempt_already_permitted},
      else: :ok
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
         attachments,
         attachment_id,
         incarnation_id
       ) do
    case Map.get(attachments, attachment_id) do
      %{status: :active, incarnation_id: ^incarnation_id} -> :ok
      _other -> {:error, :stale_attachment}
    end
  end

  defp attachment_live_in_entry?(entry, attachment_id, incarnation_id) when is_map(entry) do
    attachments = Map.get(entry, :attachments, %{})

    case current_attachment?(attachments, attachment_id, incarnation_id) do
      :ok ->
        true

      {:error, :stale_attachment} ->
        case {Map.get(entry, :prepared), Map.get(entry, :previous)} do
          {prepared, previous} when is_map(prepared) and is_map(previous) ->
            attachment_live_in_entry?(previous, attachment_id, incarnation_id)

          _other ->
            false
        end
    end
  end

  defp attachment_live_in_entry?(_entry, _attachment_id, _incarnation_id), do: false

  defp owner_generation_advanced?(entry, coordinator, owner_generation) when is_map(entry) do
    current_generation =
      case entry do
        %{status: :active, owner: %{generation: generation}} -> generation
        %{generation: generation} -> generation
        _other -> nil
      end

    is_binary(current_generation) and
      (current_generation != owner_generation or Map.get(entry, :coordinator) != coordinator)
  end

  defp owner_generation_advanced?(_entry, _coordinator, _owner_generation), do: false

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
