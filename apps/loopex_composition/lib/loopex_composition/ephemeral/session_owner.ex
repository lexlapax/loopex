defmodule LoopexComposition.Ephemeral.SessionOwner do
  @moduledoc """
  ## Concept

  Holds one ephemeral session's lifecycle, but does no session work before its
  creator completes owner activation and supplies a one-use begin token. After
  begin it grants each startup step and returns no subtree before exact commit.

  ## Technical depth

  The temporary supervisor child receives only process identities, a reference
  and an expiry. It monitors the creator, proxy and supervisor, and treats proxy
  loss as authorized only after the exact retirement notice and normal DOWN.
  The two-slot atomics cell is private to this owner until the begin handshake.
  A single absolute startup deadline covers the root candidate, child
  registration, runtime and subtree commit. A returned process is monitored
  before the root receives its acknowledgement.
  """

  use GenServer
  require Logger

  alias Loopex.Runtime
  alias Loopex.Store
  alias Loopex.Trace.Capability.Handle, as: TraceHandle
  alias Loopex.Attachment
  alias Loopex.ResourcePack
  alias LoopexComposition.SessionAdmission
  alias LoopexComposition.Ephemeral.{FacadeClient, ModelCensus, SessionRoot, TempRoot}

  @startup_ms 5_000
  @startup_wait_ms 16_000
  @uint64_max 18_446_744_073_709_551_615
  @observed_max 55_340_232_221_128_654_844
  @text_max 65_536
  @tool_max 256
  @history_max 256
  @tool_outcomes ~w(completed failed denied cancelled cancelled_workspace_lease_lost outcome_unknown)
  @run_outcomes %{
    "completed" => :completed,
    "failed" => :failed,
    "bound_reached" => :bound_reached,
    "outcome_unknown" => :outcome_unknown,
    "cancelled" => :cancelled
  }
  @phase_order [
    :candidate_prepare,
    :root_claim,
    :private_supervisor,
    :memory_store,
    :store_handle,
    :workspace_lease,
    :executor,
    :trace_capability,
    :trace_handle,
    :runtime_holder,
    :runtime,
    :trace_bind
  ]
  @coding ~w(loopex.read loopex.write loopex.edit loopex.bash)
  @read_only ~w(loopex.read loopex.grep loopex.find loopex.ls)

  @doc false
  def start_link(creator, proxy, ref, expiry) do
    GenServer.start_link(__MODULE__, {creator, proxy, ref, expiry})
  end

  @doc false
  @spec start_session(pid(), map(), pos_integer()) ::
          {:ok, :session_ready} | {:error, term()}
  def start_session(owner, configuration, timeout_ms)
      when is_pid(owner) and is_map(configuration) and is_integer(timeout_ms) and timeout_ms > 0 do
    reference = make_ref()
    monitor = Process.monitor(owner)
    send(owner, {self(), reference, :start_session, configuration})

    receive do
      {^owner, ^reference, result} ->
        Process.demonitor(monitor, [:flush])
        result

      {:DOWN, ^monitor, :process, ^owner, _reason} ->
        {:error, :session_unavailable}
    after
      max(timeout_ms, @startup_wait_ms) ->
        send(owner, {self(), reference, :cancel_start})
        Process.demonitor(monitor, [:flush])
        {:error, :session_unavailable}
    end
  end

  def start_session(_owner, _configuration, _timeout_ms),
    do: {:error, :session_unavailable}

  @impl true
  def init({creator, proxy, ref, expiry}) do
    Process.flag(:sensitive, true)
    Process.flag(:trap_exit, true)
    supervisor = supervisor_from_ancestry()

    if is_pid(supervisor) and fresh?(expiry) and
         Enum.all?([creator, proxy, supervisor], &Process.alive?/1) do
      monitors = %{
        creator: Process.monitor(creator),
        proxy: Process.monitor(proxy),
        supervisor: Process.monitor(supervisor)
      }

      cell = :atomics.new(2, signed: false)
      identity = make_ref()
      send(creator, {self(), ref, :owner_candidate, identity})
      Process.send_after(self(), {:activation_expired, ref}, remaining(expiry))

      {:ok,
       %{
         creator: creator,
         proxy: proxy,
         supervisor: supervisor,
         ref: ref,
         expiry: expiry,
         monitors: monitors,
         cell: cell,
         cleanup_grace_ms: Loopex.Executor.default_cleanup_grace_ms(),
         identity: identity,
         retiring: false,
         phase: :blocked,
         token: nil,
         startup_deadline: nil,
         startup: nil,
         abort: nil,
         model_census: nil,
         session: nil,
         stop: nil
       }}
    else
      {:stop, :expired_owner_start}
    end
  end

  @impl true
  def handle_info({:loopex_session_admission, _, _, _, _, _} = message, state),
    do: {:noreply, handle_model_message(state, message)}

  def handle_info({:model_custody_prepared, _, _, _, _, _} = message, state),
    do: {:noreply, handle_model_message(state, message)}

  def handle_info({:model_census_retirement_check, _} = message, state),
    do: {:noreply, handle_model_message(state, message)}

  def handle_info({:model_census_lost_callback, _} = message, state),
    do: {:noreply, handle_model_message(state, message)}

  def handle_info({:model_tool_reconcile, _} = message, state),
    do: {:noreply, handle_model_message(state, message)}

  def handle_info(
        {:model_settlement_deadline, reference},
        %{phase: :ready, session: %{settlement: %{reference: reference}}} = state
      ),
      do: {:noreply, fail_model_settlement(state)}

  def handle_info(
        {:empty_invocation_released, candidate, reference},
        %{
          phase: :ready,
          session:
            %{settlement: %{stage: :release, candidate: candidate, release_ref: reference}} =
              session
        } = state
      ) do
    settlement = %{session.settlement | acked: true}
    {:noreply, %{state | session: %{session | settlement: settlement}}}
  end

  def handle_info(
        {creator, ref, :identify, identity, challenge},
        %{creator: creator, ref: ref, identity: identity, phase: :blocked} = state
      )
      when is_reference(challenge) do
    send(creator, {self(), ref, :candidate_identity, challenge})
    {:noreply, state}
  end

  def handle_info(
        {proxy, ref, :proxy_retiring},
        %{proxy: proxy, ref: ref, phase: :blocked} = state
      ) do
    {:noreply, %{state | retiring: true}}
  end

  def handle_info(
        {:DOWN, monitor, :process, proxy, :normal},
        %{proxy: proxy, monitors: %{proxy: monitor}, retiring: true, phase: :blocked} = state
      ) do
    {:noreply, %{state | phase: :ready}}
  end

  def handle_info(
        {creator, ref, :prepare, token},
        %{creator: creator, ref: ref, phase: :ready} = state
      )
      when is_reference(token) do
    if fresh?(state.expiry) do
      send(creator, {self(), ref, :prepared})
      {:noreply, %{state | phase: :prepared, token: token}}
    else
      {:stop, :expired_owner_start, state}
    end
  end

  def handle_info(
        {creator, ref, :begin, token, reply_ref},
        %{creator: creator, ref: ref, phase: :prepared, token: token} = state
      )
      when is_reference(reply_ref) do
    if fresh?(state.expiry) do
      send(creator, {self(), reply_ref, :begun, state.cell})
      deadline = System.monotonic_time() + native(@startup_ms)
      Process.send_after(self(), {:startup_deadline, ref}, @startup_ms)
      {:noreply, %{state | phase: :begun, token: nil, startup_deadline: deadline}}
    else
      {:stop, :expired_owner_start, state}
    end
  end

  # Concept: the owner-start ticket expires, not a session that has already
  # started. `:ready` is also the live-session phase.
  # Technical depth: only the pre-start state has no startup record; its timer
  # must be inert after the begin token has been consumed.
  def handle_info({:activation_expired, ref}, %{ref: ref, phase: phase, startup: nil} = state)
      when phase in [:blocked, :ready, :prepared] do
    if fresh?(state.expiry),
      do: {:noreply, state},
      else: {:stop, :normal, state}
  end

  def handle_info(
        {creator, request, :start_session, configuration},
        %{creator: creator, phase: :begun, startup: nil} = state
      )
      when is_reference(request) and is_map(configuration) do
    if fresh?(state.startup_deadline) do
      start_subtree(state, request, configuration)
    else
      send(creator, {self(), request, {:error, :session_unavailable}})
      {:noreply, close_proved(state)}
    end
  end

  def handle_info(
        {creator, request, :cancel_start},
        %{creator: creator, startup: %{request: request}, phase: :starting} = state
      ) do
    {:noreply, fail_start(state, :session_unavailable, :unknown)}
  end

  def handle_info({:startup_deadline, ref}, %{ref: ref, phase: :begun} = state) do
    if fresh?(state.startup_deadline) do
      {:noreply, state}
    else
      {:noreply, close_proved(state)}
    end
  end

  def handle_info({:startup_deadline, ref}, %{ref: ref, phase: :starting} = state) do
    if fresh?(state.startup_deadline),
      do: {:noreply, state},
      else: {:noreply, fail_start(state, timeout_cause(state.startup), :unknown)}
  end

  def handle_info(
        {:root_ready, root, reference},
        %{startup: %{root: root, reference: reference} = startup, phase: :starting} = state
      ) do
    {:noreply, %{state | startup: %{startup | root_ready: true}} |> maybe_grant()}
  end

  def handle_info(
        {:phase_ready, sender, reference, phase},
        %{startup: %{reference: reference, expected: phase} = startup, phase: :starting} = state
      ) do
    if sender == expected_sender(startup, phase) and not startup.granted do
      {:noreply, %{state | startup: %{startup | ready: true}} |> maybe_grant()}
    else
      {:noreply, state}
    end
  end

  # RuntimeHolder and SessionRoot have different senders. The latter may send
  # trace_bind ready before the owner's runtime-result message is processed.
  def handle_info(
        {:phase_ready, root, reference, :trace_bind},
        %{
          startup: %{root: root, reference: reference, expected: :runtime} = startup,
          phase: :starting
        } = state
      ) do
    {:noreply, %{state | startup: %{startup | early_trace_bind: true}}}
  end

  def handle_info(
        {:phase_result, sender, reference, phase, result},
        %{
          startup: %{reference: reference, expected: phase, granted: true} = startup,
          phase: :starting
        } = state
      ) do
    if sender == expected_sender(startup, phase) do
      # The exact return ends this grant, including a returned failure. A
      # later rollback must not classify it as an unknown child start.
      state = %{state | startup: %{startup | granted: false}}
      {:noreply, accept_phase_result(state, phase, result)}
    else
      {:noreply, state}
    end
  end

  def handle_info(
        {:subtree_prepared, root, reference, prepared},
        %{
          startup: %{root: root, reference: reference, expected: :prepared} = startup,
          phase: :starting
        } = state
      ) do
    if prepared_matches?(startup, prepared) and live_subtree?(startup) and
         fresh?(startup.deadline) do
      send(root, {:commit, self(), reference})
      {:noreply, %{state | startup: %{startup | expected: :committed, prepared: prepared}}}
    else
      {:noreply, fail_start(state, :dependency_start_failed, :unknown)}
    end
  end

  def handle_info(
        {:DOWN, monitor, :process, pid, reason},
        %{phase: :aborting, startup: startup, abort: abort} = state
      ) do
    cond do
      abort.worker && abort.worker.pid == pid && abort.worker.monitor == monitor ->
        {:noreply, finish_abort_worker(state, reason)}

      {monitor, pid} == {state.monitors.creator, state.creator} ->
        {:noreply, put_in(state.stop.no_retry, true)}

      Map.get(startup.process_monitors, pid) == monitor ->
        next = %{state | abort: %{abort | down: MapSet.put(abort.down, pid)}}
        {:noreply, continue_abort(next)}

      true ->
        {:noreply, handle_model_message(state, {:DOWN, monitor, :process, pid, reason})}
    end
  end

  def handle_info(
        {:abort_deadline, reference},
        %{phase: :aborting, startup: %{reference: reference}} = state
      ) do
    if fresh?(state.abort.deadline) do
      {:noreply, state}
    else
      if state.abort.worker, do: Process.exit(state.abort.worker.pid, :kill)
      {:noreply, state |> mark_abort_timeout() |> finish_abort()}
    end
  end

  def handle_info(
        {:abort_facade_deadline, reference},
        %{phase: :aborting, startup: %{reference: reference}, abort: %{stage: :facade_reap}} =
          state
      ) do
    {:noreply, state |> mark_abort_timeout() |> finish_abort()}
  end

  def handle_info(
        {:abort_operation_cutoff, reference},
        %{phase: :aborting, abort: %{worker: %{reference: reference} = worker}} = state
      ) do
    if not worker.finish_sent, do: Process.exit(worker.pid, :kill)
    {:noreply, state}
  end

  def handle_info(
        {:abort_slot_deadline, reference},
        %{phase: :aborting, abort: %{worker: %{reference: reference} = worker}} = state
      ) do
    Process.exit(worker.pid, :kill)
    {:noreply, state |> mark_abort_timeout() |> finish_abort()}
  end

  def handle_info(
        {worker_pid, reference, phase, :result, result, completed_at},
        %{
          phase: :aborting,
          abort:
            %{worker: %{pid: worker_pid, reference: reference, phase: phase} = worker} = abort
        } = state
      ) do
    valid = completed_at <= worker.cutoff and valid_abort_result?(phase, result, worker.nonce)
    updated = %{worker | result: valid}
    next = %{state | abort: %{abort | worker: updated}}

    if valid,
      do: {:noreply, maybe_finish_abort_worker(next)},
      else:
        (
          Process.exit(worker_pid, :kill)
          {:noreply, next}
        )
  end

  def handle_info(
        {executor, instance, nonce, :groups_empty},
        %{
          phase: :aborting,
          startup: %{executor_instance: instance, registered: %{executor: executor}},
          abort: %{worker: %{phase: :process_groups, nonce: nonce} = worker} = abort
        } = state
      ) do
    next = %{state | abort: %{abort | worker: %{worker | certificate: true}}}
    {:noreply, maybe_finish_abort_worker(next)}
  end

  def handle_info(
        {:subtree_committed, root, reference},
        %{
          startup: %{root: root, reference: reference, expected: :committed} = startup,
          phase: :starting
        } = state
      ) do
    if fresh?(startup.deadline) and live_subtree?(startup) do
      {:noreply, start_facade(state)}
    else
      {:noreply, fail_start(state, :dependency_start_failed, :unknown)}
    end
  end

  def handle_info(
        {client, reference, :ready},
        %{
          phase: :starting,
          startup:
            %{facade: %{pid: client, reference: reference, stage: :await_ready} = facade} =
              startup
        } = state
      ) do
    if fresh?(startup.deadline) and fresh?(facade.handshake_deadline) do
      operation_deadline = System.monotonic_time() + native(5_000)
      send(client, {self(), reference, :dispatch, operation_deadline})
      next_facade = %{facade | stage: :dispatched, operation_deadline: operation_deadline}
      {:noreply, %{state | startup: %{startup | facade: next_facade}}}
    else
      {:noreply, cancel_facade(state)}
    end
  end

  def handle_info(
        {client, reference, :cancelled},
        %{
          phase: :starting,
          startup: %{facade: %{pid: client, reference: reference, stage: :cancelling} = facade}
        } = state
      ) do
    {:noreply, fail_start(state, facade_failure(facade.operation), :known)}
  end

  def handle_info(
        {client, reference, result},
        %{
          phase: :starting,
          startup: %{facade: %{pid: client, reference: reference, stage: :dispatched}}
        } = state
      ) do
    {:noreply, accept_facade_result(state, result)}
  end

  def handle_info(
        {:facade_handshake_deadline, reference},
        %{
          phase: :starting,
          startup: %{facade: %{reference: reference, stage: :await_ready} = facade}
        } = state
      ) do
    if fresh?(facade.handshake_deadline),
      do: {:noreply, state},
      else: {:noreply, cancel_facade(state)}
  end

  def handle_info(
        {:facade_cancel_deadline, reference},
        %{
          phase: :starting,
          startup: %{facade: %{reference: reference, stage: :cancelling} = facade}
        } = state
      ) do
    {:noreply, fail_start(state, facade_failure(facade.operation), :known)}
  end

  def handle_info(
        {:DOWN, monitor, :process, root, _reason},
        %{phase: :starting, startup: %{root: root, process_monitors: monitors}} = state
      ) do
    if Map.get(monitors, root) == monitor do
      failed = fail_start(state, :dependency_start_failed, :unknown)
      abort = %{failed.abort | down: MapSet.put(failed.abort.down, root)}
      {:noreply, continue_abort(%{failed | abort: abort})}
    else
      {:noreply, state}
    end
  end

  def handle_info({borrower, request, :public, :last_result}, %{phase: :ready} = state)
      when is_pid(borrower) and is_reference(request) do
    send(borrower, {self(), request, state.session.last_result})
    {:noreply, state}
  end

  def handle_info({borrower, request, :public, :history}, %{phase: :ready} = state)
      when is_pid(borrower) and is_reference(request) do
    history = %{entries: state.session.history, truncated: state.session.history_truncated}
    send(borrower, {self(), request, {:ok, history}})
    {:noreply, state}
  end

  def handle_info({borrower, request, :public, :stop}, %{phase: :ready} = state)
      when is_pid(borrower) and is_reference(request),
      do: {:noreply, begin_stop(state, {borrower, request})}

  def handle_info({borrower, request, :public, :stop}, %{phase: phase, stop: stop} = state)
      when phase in [:stopping, :aborting] and is_pid(borrower) and is_reference(request) and
             not is_nil(stop),
      do: {:noreply, put_in(state.stop.waiters, [{borrower, request} | stop.waiters])}

  def handle_info({borrower, request, :public, :stop}, %{phase: :failed_stop} = state)
      when is_pid(borrower) and is_reference(request),
      do: {:noreply, retry_stop(state, {borrower, request})}

  def handle_info({borrower, request, :public, :stop}, %{phase: :sealed, stop: stop} = state)
      when is_pid(borrower) and is_reference(request) and not is_nil(stop) do
    result = if :atomics.get(state.cell, 1) == 2, do: :ok, else: stop.result
    send(borrower, {self(), request, result})
    {:noreply, state}
  end

  def handle_info({borrower, request, :public, {:ask, prompt, timeout}}, %{phase: :ready} = state)
      when is_pid(borrower) and is_reference(request) and is_binary(prompt) do
    if state.session.active || state.session.run_open do
      send(borrower, {self(), request, {:error, :run_open}})
      {:noreply, state}
    else
      {command_id, session} = next_command_id(state.session, :prompt)
      command = %{type: :prompt, command_id: command_id, content: prompt}
      wait = timeout || state.startup.configuration.timeout
      next = %{state | session: session}
      {:noreply, begin_live_command(next, borrower, request, :ask, command, wait)}
    end
  end

  def handle_info(
        {borrower, request, :public, {:answer, interaction_id, choice_id}},
        %{phase: :ready} = state
      )
      when is_pid(borrower) and is_reference(request) do
    interaction = state.session.interaction

    if state.session.active || not answer_matches?(interaction, interaction_id, choice_id) do
      send(borrower, {self(), request, {:error, :invalid_interaction_answer}})
      {:noreply, state}
    else
      {command_id, session} = next_command_id(state.session, :answer)

      command = %{
        type: :interaction_answer,
        command_id: command_id,
        interaction_id: interaction_id,
        choice_id: choice_id
      }

      next = %{state | session: session}

      {:noreply,
       begin_live_command(
         next,
         borrower,
         request,
         :answer,
         command,
         state.startup.configuration.timeout
       )}
    end
  end

  def handle_info({borrower, request, :public, _operation}, state)
      when is_pid(borrower) and is_reference(request) do
    send(borrower, {self(), request, {:error, :session_unavailable}})
    {:noreply, state}
  end

  def handle_info(
        {client, reference, :ready},
        %{
          phase: phase,
          session: %{
            active:
              %{facade: %{pid: client, reference: reference, stage: :await_ready} = facade} =
                active
          }
        } = state
      )
      when phase in [:ready, :stopping] do
    cond do
      phase == :stopping and active.kind != :abort and
          (active.admission == :pregrant or active.operation == :next_event) ->
        send(client, {self(), reference, :cancel})
        Process.send_after(self(), {:live_cancel_deadline, reference}, 1_000)
        {:noreply, put_in(state.session.active.facade.stage, :cancelling)}

      fresh?(facade.handshake_deadline) ->
        deadline =
          System.monotonic_time() +
            native(if(active.operation == :next_event, do: 1_000, else: 5_000))

        deadline = if state.stop, do: min(deadline, state.stop.deadline), else: deadline
        send(client, {self(), reference, :dispatch, deadline})
        Process.send_after(self(), {:live_operation_deadline, reference}, remaining(deadline))
        facade = %{facade | stage: :dispatched, operation_deadline: deadline}

        active = %{
          active
          | facade: facade,
            admission: if(active.operation == :command, do: :granted, else: active.admission)
        }

        {:noreply, put_in(state.session.active, active)}

      true ->
        send(client, {self(), reference, :cancel})
        Process.send_after(self(), {:live_cancel_deadline, reference}, 1_000)
        {:noreply, put_in(state.session.active.facade.stage, :cancelling)}
    end
  end

  def handle_info(
        {client, reference, :cancelled},
        %{
          phase: phase,
          session: %{active: %{facade: %{pid: client, reference: reference, stage: :cancelling}}}
        } = state
      )
      when phase in [:ready, :stopping] do
    {:noreply, cancel_live_command(state)}
  end

  def handle_info(
        {client, reference, result},
        %{
          phase: phase,
          session: %{active: %{facade: %{pid: client, reference: reference, stage: :dispatched}}}
        } = state
      )
      when phase in [:ready, :stopping] do
    {:noreply, accept_live_result(state, result)}
  end

  def handle_info(
        {:live_handshake_deadline, reference},
        %{
          phase: phase,
          session: %{active: %{facade: %{reference: reference, stage: :await_ready} = facade}}
        } = state
      )
      when phase in [:ready, :stopping] do
    if fresh?(facade.handshake_deadline) do
      {:noreply, state}
    else
      send(facade.pid, {self(), reference, :cancel})
      Process.send_after(self(), {:live_cancel_deadline, reference}, 1_000)
      {:noreply, put_in(state.session.active.facade.stage, :cancelling)}
    end
  end

  def handle_info(
        {:live_cancel_deadline, reference},
        %{
          phase: phase,
          session: %{active: %{facade: %{reference: reference, stage: :cancelling}}}
        } = state
      )
      when phase in [:ready, :stopping],
      do: {:noreply, live_failure(state)}

  def handle_info(
        {:live_operation_deadline, reference},
        %{
          phase: phase,
          session: %{active: %{facade: %{reference: reference, stage: :dispatched} = facade}}
        } = state
      )
      when phase in [:ready, :stopping] do
    if fresh?(facade.operation_deadline),
      do: {:noreply, state},
      else: {:noreply, live_failure(state)}
  end

  def handle_info({:live_poll, marker}, %{phase: phase, session: %{poll_marker: marker}} = state)
      when phase in [:ready, :stopping] do
    if state.session.active && state.session.active.operation == :next_event,
      do: {:noreply, state},
      else: {:noreply, begin_live_poll(state)}
  end

  def handle_info(
        {:public_tick, request},
        %{phase: :ready, session: %{active: %{request: request} = active}} = state
      ) do
    if is_pid(active.borrower) and System.monotonic_time() >= active.wait_deadline,
      do: {:noreply, timeout_live_request(state)},
      else: {:noreply, schedule_public_tick(state)}
  end

  def handle_info(
        {:stop_grace_deadline, reference},
        %{phase: :stopping, stop: %{reference: reference}} = state
      ),
      do: {:noreply, finish_stop_run(state)}

  def handle_info(
        {:DOWN, monitor, :process, pid, _reason},
        %{phase: :failed_stop, abort: %{worker: %{pid: pid, monitor: monitor}}} = state
      ) do
    state = put_in(state.abort.worker, nil)
    if state.stop.no_retry, do: {:noreply, retry_stop(state, nil)}, else: {:noreply, state}
  end

  def handle_info(
        {:DOWN, monitor, :process, creator, _reason},
        %{phase: :failed_stop, creator: creator, monitors: %{creator: monitor}} = state
      ) do
    state = put_in(state.stop.no_retry, true)

    case state.abort.worker do
      %{pid: worker} ->
        Process.exit(worker, :kill)
        {:noreply, state}

      nil ->
        {:noreply, retry_stop(state, nil)}
    end
  end

  def handle_info(
        {:DOWN, monitor, :process, pid, reason},
        %{phase: :failed_stop, startup: %{process_monitors: monitors}} = state
      ) do
    if Map.get(monitors, pid) == monitor,
      do: {:noreply, put_in(state.abort.down, MapSet.put(state.abort.down, pid))},
      else: {:noreply, handle_model_message(state, {:DOWN, monitor, :process, pid, reason})}
  end

  def handle_info(
        {:DOWN, monitor, :process, pid, reason},
        %{phase: :ready, startup: startup} = state
      ) do
    cond do
      {monitor, pid} == {state.monitors.creator, state.creator} ->
        {:noreply, begin_stop(state, nil)}

      {monitor, pid} in [
        {state.monitors.proxy, state.proxy},
        {state.monitors.supervisor, state.supervisor}
      ] ->
        {:stop, :normal, state}

      Map.get(startup.process_monitors, pid) == monitor ->
        {:noreply, begin_stop(state, nil) |> mark_stopped_child_down(pid)}

      (state.session.active && state.session.active.borrower_monitor == monitor) and
          state.session.active.borrower == pid ->
        {:noreply, borrower_down(state)}

      true ->
        {:noreply, handle_model_message(state, {:DOWN, monitor, :process, pid, reason})}
    end
  end

  def handle_info(
        {:DOWN, monitor, :process, pid, reason},
        %{phase: :stopping, startup: startup} = state
      ) do
    cond do
      {monitor, pid} == {state.monitors.creator, state.creator} ->
        {:noreply, put_in(state.stop.no_retry, true)}

      Map.get(startup.process_monitors, pid) == monitor ->
        {:noreply, mark_stopped_child_down(state, pid)}

      true ->
        {:noreply, handle_model_message(state, {:DOWN, monitor, :process, pid, reason})}
    end
  end

  def handle_info({:DOWN, monitor, :process, pid, reason}, state) do
    cond do
      state.phase == :starting and
          {monitor, pid} ==
            {state.monitors.creator, state.creator} ->
        {:noreply, fail_start(state, :session_unavailable, :known)}

      {monitor, pid} in [
        {state.monitors.creator, state.creator},
        {state.monitors.proxy, state.proxy},
        {state.monitors.supervisor, state.supervisor}
      ] ->
        {:stop, :normal, state}

      state.phase == :starting and
          Map.get(state.startup.process_monitors, pid) == monitor ->
        failed = fail_start(state, :dependency_start_failed, :unknown)
        abort = %{failed.abort | down: MapSet.put(failed.abort.down, pid)}
        {:noreply, continue_abort(%{failed | abort: abort})}

      true ->
        {:noreply, handle_model_message(state, {:DOWN, monitor, :process, pid, reason})}
    end
  end

  def handle_info({:EXIT, supervisor, _reason}, %{supervisor: supervisor} = state),
    do: {:stop, :normal, state}

  def handle_info(:retire_sealed, %{phase: :sealed} = state), do: {:stop, :normal, state}

  def handle_info(
        {:model_settle_check, reference},
        %{phase: :aborting, abort: %{stage: {:await_model, reference}}} = state
      ) do
    {:noreply, after_subtree(%{state | abort: %{state.abort | stage: :await_subtree}})}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp handle_model_message(%{model_census: %ModelCensus{} = census} = state, message) do
    state = %{state | model_census: ModelCensus.handle(census, message)}
    state = bind_model_call(state)

    if state.phase == :aborting and match?({:await_model, _}, state.abort.stage) and
         ModelCensus.settled?(state.model_census) do
      after_subtree(%{state | abort: %{state.abort | stage: :await_subtree}})
    else
      advance_model_settlement(state)
    end
  end

  defp handle_model_message(state, _message), do: state

  # Concept: one observed model call belongs to the prompt whose run is being
  # followed, including when its begin request precedes the prompt acceptance.
  # Technical depth: answer retains the original prompt/run identity. A changed
  # call reference is a new invocation of that same serial run, never a new run.
  defp bind_model_call(
         %{phase: phase, model_census: %{pending: %{call: call}}, session: session} = state
       )
       when phase in [:ready, :stopping] do
    if match?(%{call: ^call}, session.model_binding) do
      state
    else
      active = session.active
      run = session.run

      command_id =
        cond do
          active && active.kind == :ask -> active.command_id
          run -> run.command_id
          true -> nil
        end

      if is_binary(command_id) do
        run_id = if run && run.command_id == command_id, do: run.run_id, else: nil
        binding = %{call: call, command_id: command_id, run_id: run_id}
        put_in(state.session.model_binding, binding)
      else
        state
      end
    end
  end

  defp bind_model_call(state), do: state

  defp begin_model_settlement(state, result, sequence) do
    if ModelCensus.settled?(state.model_census) do
      settle_live(state, result, nil)
    else
      run = state.session.run
      binding = state.session.model_binding
      pending = state.model_census.pending

      if run && pending && binding && binding.call == pending.call &&
           binding.command_id == run.command_id && binding.run_id == run.run_id do
        reference = make_ref()
        deadline = System.monotonic_time() + native(1_000)
        Process.send_after(self(), {:model_settlement_deadline, reference}, 1_000)

        settlement = %{
          terminal: result,
          sequence: sequence,
          command_id: run.command_id,
          run_id: run.run_id,
          call: pending.call,
          reference: reference,
          deadline: deadline,
          stage: :waiting,
          candidate: nil,
          release_ref: nil,
          acked: false
        }

        state = put_in(state.session.settlement, settlement)
        state = put_in(state.session.active.operation, :model_settlement)
        advance_model_settlement(state)
      else
        state
        |> put_in([:session, :settlement], %{terminal: result})
        |> fail_model_settlement()
      end
    end
  end

  defp advance_model_settlement(
         %{phase: :ready, session: %{settlement: %{stage: stage} = settlement}} = state
       )
       when stage in [:waiting, :status, :status_proved, :release] do
    cond do
      not fresh?(settlement.deadline) ->
        fail_model_settlement(state)

      ModelCensus.settled?(state.model_census) and stage != :status ->
        state = put_in(state.session.settlement, nil)
        settle_live(state, settlement.terminal, nil)

      state.model_census.pending && state.model_census.pending.call != settlement.call ->
        fail_model_settlement(state)

      state.model_census.pending && state.model_census.pending.phase == :unproved ->
        fail_model_settlement(state)

      stage == :waiting and empty_retired_candidate?(state.model_census.pending) ->
        state = put_in(state.session.settlement.stage, :status)
        live_facade_operation(state, :session_status, :settlement_status)

      stage == :status_proved and empty_retired_candidate?(state.model_census.pending) ->
        pending = state.model_census.pending
        release_ref = make_ref()

        send(
          pending.candidate,
          {:release_empty_invocation, state.model_census.generation, pending.call,
           pending.candidate, pending.proof, release_ref, settlement.deadline}
        )

        state
        |> put_in([:session, :settlement, :stage], :release)
        |> put_in([:session, :settlement, :candidate], pending.candidate)
        |> put_in([:session, :settlement, :release_ref], release_ref)

      true ->
        state
    end
  end

  defp advance_model_settlement(state), do: state

  defp empty_retired_candidate?(%{
         phase: :retired_wait_down,
         callback_down: true,
         candidate_down: false,
         candidate: candidate,
         revision: 0,
         resources: resources,
         registries: registries
       })
       when is_pid(candidate) and map_size(resources) == 0 and map_size(registries) == 0,
       do: Process.alive?(candidate)

  defp empty_retired_candidate?(_), do: false

  defp accept_settlement_status(state, {:ok, status}) when is_map(status) do
    settlement = state.session.settlement

    if status[:status] == :active and status[:owner_epoch] == state.startup.owner_epoch and
         is_integer(status[:event_sequence]) and
         status[:event_sequence] >= settlement.sequence and
         Map.has_key?(status, :active_run_id) and
         (is_nil(status[:active_run_id]) or bounded_id?(status[:active_run_id], 256)) and
         status[:active_run_id] != settlement.run_id and
         is_list(status[:pending_work_ids]) and
         Enum.all?(status[:pending_work_ids], &bounded_id?(&1, 256)) and
         not Enum.member?(status[:pending_work_ids], settlement.run_id) do
      state
      |> put_in([:session, :settlement, :stage], :status_proved)
      |> put_in([:session, :active, :operation], :model_settlement)
      |> advance_model_settlement()
    else
      fail_model_settlement(state)
    end
  end

  defp accept_settlement_status(state, _result), do: fail_model_settlement(state)

  defp fail_model_settlement(%{phase: :ready, session: %{settlement: %{terminal: _}}} = state),
    do: begin_stop(state, nil)

  defp fail_model_settlement(state), do: state

  defp start_subtree(state, request, configuration) do
    reference = make_ref()
    seams = test_seams(configuration)

    case SessionRoot.start_link(self(), reference, state.startup_deadline, configuration, seams) do
      {:ok, root} ->
        monitor = Process.monitor(root)

        startup = %{
          request: request,
          replied: false,
          owner: self(),
          reference: reference,
          deadline: state.startup_deadline,
          configuration: configuration,
          root: root,
          root_ready: false,
          expected: :candidate_prepare,
          ready: false,
          granted: false,
          early_trace_bind: false,
          candidate: nil,
          owned_root: nil,
          registered: %{},
          process_monitors: %{root => monitor},
          prepared: nil,
          generation: make_ref(),
          executor_instance: make_ref(),
          facade: nil,
          session_id: nil,
          attachment: nil,
          skill_index: 0,
          manifest_digest: nil,
          owner_epoch: nil
        }

        census = ModelCensus.new(startup.generation, state.cell)
        {:noreply, %{state | phase: :starting, startup: startup, model_census: census}}

      _failure ->
        send(state.creator, {self(), request, {:error, {:composition, :dependency_start_failed}}})
        {:noreply, close_proved(state)}
    end
  end

  defp start_facade(state) do
    startup = state.startup

    case ResourcePack.digest(startup.configuration.skills.manifest) do
      {:ok, digest, %{"packs" => packs}} when is_list(packs) ->
        try do
          {client, monitor} =
            FacadeClient.start(
              self(),
              startup.registered.runtime,
              test_facade(startup.configuration)
            )

          process_monitors = Map.put(startup.process_monitors, client, monitor)

          state = %{
            state
            | startup: %{
                startup
                | manifest_digest: digest,
                  process_monitors: process_monitors,
                  registered: Map.put(startup.registered, :facade_client, client)
              }
          }

          start_facade_operation(state, :create)
        catch
          _, _ -> fail_start(state, :client_start_failed, :known)
        end

      _ ->
        fail_start(state, :resource_admission_failed, :known)
    end
  end

  defp start_facade_operation(state, operation) do
    startup = state.startup
    client = Map.fetch!(startup.registered, :facade_client)
    reference = make_ref()
    handshake_deadline = min(System.monotonic_time() + native(1_000), startup.deadline)
    send(client, {self(), reference, operation})

    Process.send_after(
      self(),
      {:facade_handshake_deadline, reference},
      remaining(handshake_deadline)
    )

    facade = %{
      pid: client,
      reference: reference,
      operation: operation,
      stage: :await_ready,
      handshake_deadline: handshake_deadline,
      operation_deadline: nil
    }

    %{state | startup: %{startup | facade: facade}}
  end

  defp cancel_facade(state) do
    startup = state.startup
    facade = startup.facade
    send(facade.pid, {self(), facade.reference, :cancel})

    Process.send_after(
      self(),
      {:facade_cancel_deadline, facade.reference},
      min(1_000, remaining(startup.deadline))
    )

    %{state | startup: %{startup | facade: %{facade | stage: :cancelling}}}
  end

  defp accept_facade_result(state, result) do
    startup = state.startup

    if fresh?(startup.deadline) do
      case facade_transition(state, startup.facade.operation, result) do
        {:next, next_state, operation} ->
          start_facade_operation(next_state, operation)

        {:ready, ready_state} ->
          census =
            ModelCensus.activate_tools(
              ready_state.model_census,
              ready_state.startup.configuration.tools != :none
            )

          ready_state = %{ready_state | model_census: census}
          send(state.creator, {self(), startup.request, {:ok, :session_ready}})

          %{
            ready_state
            | phase: :ready,
              startup: %{ready_state.startup | replied: true},
              session: new_session(ready_state.startup)
          }

        {:error, cause} ->
          fail_start(state, cause, :known)
      end
    else
      fail_start(state, facade_failure(startup.facade.operation), :known)
    end
  end

  defp facade_transition(state, :create, {:ok, session_id})
       when is_binary(session_id) and byte_size(session_id) in 1..256 do
    if String.valid?(session_id) do
      {:next, put_in(state.startup.session_id, session_id), :attach}
    else
      {:error, :session_create_failed}
    end
  end

  defp facade_transition(state, :attach, {:ok, %Attachment{session_id: session_id} = attachment}) do
    if session_id == state.startup.session_id and
         attachment.runtime == state.startup.registered.runtime and
         is_binary(attachment.attachment_id) and
         is_binary(attachment.incarnation_id) and is_map(attachment.snapshot) do
      state = put_in(state.startup.attachment, attachment)
      packs = state.startup.configuration.skills.manifest["packs"]

      if packs == [],
        do: {:next, state, :session_status},
        else: {:next, state, {:command, admit_command(state)}}
    else
      {:error, :attach_failed}
    end
  end

  defp facade_transition(
         state,
         {:command, %{type: :admit_resources, command_id: id}},
         {:accepted, id}
       ) do
    {:next, state, :resource_catalog}
  end

  defp facade_transition(state, :resource_catalog, {:ok, catalog}) do
    if catalog_matches?(state.startup, catalog) do
      {:next, state, {:command, activation_command(state, 0)}}
    else
      {:error, :resource_admission_failed}
    end
  end

  defp facade_transition(
         state,
         {:command, %{type: :activate_skill, command_id: id}},
         {:accepted, id}
       ) do
    next_index = state.startup.skill_index + 1
    state = put_in(state.startup.skill_index, next_index)
    packs = state.startup.configuration.skills.manifest["packs"]

    if next_index == length(packs),
      do: {:next, state, :session_status},
      else: {:next, state, {:command, activation_command(state, next_index)}}
  end

  defp facade_transition(state, :session_status, {:ok, status}) when is_map(status) do
    owner_epoch = Map.get(status, :owner_epoch)

    if Map.get(status, :status) == :active and is_integer(owner_epoch) and
         owner_epoch >= 0 and Map.has_key?(status, :active_run_id) and
         Map.get(status, :active_run_id) == nil and
         Map.get(status, :pending_work_ids) == [] do
      {:ready, put_in(state.startup.owner_epoch, owner_epoch)}
    else
      {:error, :attach_failed}
    end
  end

  defp facade_transition(_state, operation, _result), do: {:error, facade_failure(operation)}

  defp admit_command(state) do
    manifest = state.startup.configuration.skills.manifest
    digest = state.startup.manifest_digest
    issued_at = issued_at(state.startup.configuration)

    %{
      type: :admit_resources,
      command_id: "admit-resources",
      manifest_digest: digest,
      decision: %{
        manifest_digest: digest,
        workspace_ref: manifest["workspace_ref"],
        trust_scope: "project_skills",
        decision_source: "host_supplied",
        issued_at: issued_at,
        expires_at: nil,
        revocation_state: "active"
      }
    }
  end

  defp activation_command(state, index) do
    pack = state.startup.configuration.skills.manifest["packs"] |> Enum.at(index)

    %{
      type: :activate_skill,
      command_id: "activate-skill-#{index + 1}",
      manifest_digest: state.startup.manifest_digest,
      source_id: pack["source_id"],
      name: pack["name"],
      pack_digest: ResourcePack.pack_digest(pack),
      supporting_labels: []
    }
  end

  defp catalog_matches?(startup, %{
         "configured_manifest_digest" => configured,
         "admitted_manifest_digest" => admitted,
         "decision_disposition" => "active",
         "entries" => entries
       })
       when is_list(entries) do
    digest = startup.manifest_digest
    packs = startup.configuration.skills.manifest["packs"]
    expected = Enum.map(packs, &{&1["source_id"], &1["name"], ResourcePack.pack_digest(&1)})
    actual = Enum.map(entries, &catalog_tuple/1)

    configured == digest and admitted == digest and length(actual) == length(expected) and
      Enum.sort(actual) == Enum.sort(expected)
  end

  defp catalog_matches?(_startup, _catalog), do: false

  defp catalog_tuple(%{"source_id" => source, "name" => name, "pack_digest" => digest})
       when is_binary(source) and is_binary(name) and is_binary(digest),
       do: {source, name, digest}

  defp catalog_tuple(_entry), do: :invalid

  defp facade_failure(:create), do: :session_create_failed
  defp facade_failure(:attach), do: :attach_failed
  defp facade_failure(:session_status), do: :attach_failed
  defp facade_failure(:resource_catalog), do: :resource_admission_failed
  defp facade_failure({:command, %{type: :admit_resources}}), do: :resource_admission_failed
  defp facade_failure({:command, %{type: :activate_skill}}), do: :skill_activation_failed

  # Concept: closing admission is immediate; run-ending and teardown remain
  # separate proof obligations. The facade actor stays serial during abort.
  # Technical depth: an in-flight borrower is moved into stop state before its
  # operation can produce a second public reply.
  defp begin_stop(state, waiter) do
    :atomics.put(state.cell, 1, 1)
    now = System.monotonic_time()
    grace_deadline = now + native(state.cleanup_grace_ms)
    deadline = grace_deadline + native(5_000)
    reference = make_ref()
    Process.send_after(self(), {:stop_grace_deadline, reference}, remaining(grace_deadline))
    active = state.session.active

    possible =
      state.session.run_open or
        (not is_nil(active) and active.admission in [:granted, :following])

    prior_interaction =
      if state.session.interaction && active == nil,
        do: {:error, {:interaction_pending, state.session.interaction}},
        else: :none

    waiters = if waiter, do: [waiter], else: []

    stop = %{
      reference: reference,
      deadline: deadline,
      grace_deadline: grace_deadline,
      waiters: waiters,
      waiting: active,
      no_retry: waiter == nil,
      possible: possible,
      run_proved: not possible,
      effect_proved: not possible and not state.session.effect_unproved,
      ending: prior_interaction,
      down: MapSet.new(),
      malformed: false,
      abort_sent: false
    }

    active =
      if active do
        if is_reference(active.borrower_monitor),
          do: Process.demonitor(active.borrower_monitor, [:flush])

        %{active | borrower: nil, borrower_monitor: nil}
      end

    state = %{
      state
      | phase: :stopping,
        stop: stop,
        session: %{state.session | active: active, poll_marker: nil}
    }

    cond do
      state.session.settlement != nil ->
        terminal_stop(state)

      active == nil ->
        stop_abort_or_cleanup(state)

      active.operation == :poll_scheduled ->
        state |> put_in([:session, :active], nil) |> stop_abort_or_cleanup()

      active.facade.stage == :await_ready ->
        send(active.facade.pid, {self(), active.facade.reference, :cancel})
        Process.send_after(self(), {:live_cancel_deadline, active.facade.reference}, 1_000)
        put_in(state.session.active.facade.stage, :cancelling)

      true ->
        state
    end
  end

  defp terminal_stop(%{phase: :stopping, session: %{settlement: %{terminal: terminal}}} = state) do
    outcome = terminal_outcome(terminal)

    stop = %{
      state.stop
      | run_proved: true,
        effect_proved: outcome != :outcome_unknown,
        ending: terminal
    }

    %{state | stop: stop} |> finish_stop_run()
  end

  defp stop_abort_or_cleanup(%{stop: %{possible: false}} = state), do: finish_stop_run(state)

  defp stop_abort_or_cleanup(%{stop: %{abort_sent: true}} = state), do: begin_live_poll(state)

  defp stop_abort_or_cleanup(%{session: %{run_open: false}} = state),
    do: finish_stop_run(state)

  defp stop_abort_or_cleanup(state) do
    {id, session} = next_command_id(state.session, :abort)

    active = %{
      borrower: nil,
      borrower_monitor: nil,
      request: nil,
      kind: :abort,
      command_id: id,
      started_at: System.monotonic_time(),
      wait_deadline: state.stop.grace_deadline,
      admission: :pregrant,
      operation: :command,
      facade: nil,
      timed_out: nil,
      cancel_reason: nil
    }

    state = %{
      state
      | session: %{session | active: active},
        stop: %{state.stop | abort_sent: true}
    }

    live_facade_operation(state, {:command, %{type: :abort, command_id: id}}, :command)
  end

  defp finish_stop_run(%{phase: :stopping} = state) do
    # A failed or missing terminal never promotes a run-ending proof. The
    # teardown still proceeds to prove independent process and root facts.
    ending = stop_ending(state)
    state = state |> put_in([:session, :poll_marker], nil) |> put_in([:stop, :ending], ending)
    failed = fail_start(state, :session_unavailable, :known)
    down = MapSet.union(failed.abort.down, state.stop.down)

    %{failed | startup: %{failed.startup | cause: nil}, abort: %{failed.abort | down: down}}
    |> continue_abort()
  end

  defp mark_stopped_child_down(%{phase: :stopping} = state, pid) do
    state = put_in(state.stop.down, MapSet.put(state.stop.down, pid))

    if pid == Map.get(state.startup.registered, :facade_client),
      do: finish_stop_run(state),
      else: state
  end

  defp mark_stopped_child_down(%{phase: :aborting} = state, pid) do
    state = put_in(state.abort.down, MapSet.put(state.abort.down, pid))
    continue_abort(state)
  end

  defp mark_stopped_child_down(state, _pid), do: state

  defp stop_ending(%{stop: %{malformed: true}}), do: :none
  defp stop_ending(%{stop: %{run_proved: true, ending: ending}}), do: ending
  defp stop_ending(%{stop: %{ending: {:error, {:interaction_pending, _}} = ending}}), do: ending
  defp stop_ending(%{stop: %{possible: false}}), do: :none

  defp stop_ending(state) do
    active = state.stop.waiting || state.session.active

    cond do
      active && match?({:error, {:timeout, _}}, active.timed_out) ->
        active.timed_out

      active && active.admission in [:granted, :following] ->
        {:error, {:session_unavailable, no_ending_snapshot(state, active)}}

      match?({:error, {:timeout, _}}, state.session.last_result) ->
        state.session.last_result

      true ->
        :none
    end
  end

  defp borrower_down(state) do
    active = state.session.active

    cond do
      active.admission == :pregrant and active.facade.stage == :await_ready ->
        send(active.facade.pid, {self(), active.facade.reference, :cancel})
        Process.send_after(self(), {:live_cancel_deadline, active.facade.reference}, 1_000)

        state
        |> put_in([:session, :active, :borrower], nil)
        |> put_in([:session, :active, :borrower_monitor], nil)
        |> put_in([:session, :active, :facade, :stage], :cancelling)

      true ->
        state
        |> put_in([:session, :active, :borrower], nil)
        |> put_in([:session, :active, :borrower_monitor], nil)
    end
  end

  defp retry_stop(state, waiter) do
    pending = state.stop.pending

    if Enum.all?(pending, &(&1 in [:session_subtree, :root_removal])) and
         state.abort.worker == nil do
      deadline = System.monotonic_time() + native(state.cleanup_grace_ms + 5_000)
      Process.send_after(self(), {:abort_deadline, state.startup.reference}, remaining(deadline))
      stop = %{state.stop | waiters: List.wrap(waiter), deadline: deadline}

      abort = %{
        state.abort
        | deadline: deadline,
          stage: :facade_reap,
          worker: nil,
          subtree_failed: false,
          root_failed: false
      }

      %{state | phase: :aborting, stop: stop, abort: abort} |> continue_abort()
    else
      if waiter do
        send(elem(waiter, 0), {self(), elem(waiter, 1), state.stop.result})
        state
      else
        Logger.error(
          "ephemeral cleanup unproved root=#{inspect(state.startup.possible_root)} pending=#{inspect(pending)}"
        )

        send(self(), :retire_sealed)
        %{state | phase: :sealed}
      end
    end
  end

  defp new_session(startup) do
    %{
      nonce: command_nonce(startup.configuration),
      counter: 0,
      run_open: false,
      run: nil,
      effect_unproved: false,
      interaction: nil,
      last_result: :none,
      history: [],
      history_truncated: false,
      cursor: 0,
      active: nil,
      poll_marker: nil,
      model_binding: nil,
      settlement: nil
    }
  end

  defp next_command_id(session, type) when type in [:prompt, :answer, :abort] do
    counter = session.counter + 1
    bytes = :erlang.term_to_binary([session.nonce, counter, type], [:deterministic])
    digest = :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
    {"e-" <> binary_part(digest, 0, 62), %{session | counter: counter}}
  end

  if Mix.env() == :test do
    defp command_nonce(configuration) do
      case get_in(configuration, [:test_seams, :command_nonce]) do
        value when is_binary(value) and byte_size(value) == 32 -> value
        _ -> :crypto.strong_rand_bytes(32)
      end
    end
  else
    defp command_nonce(_configuration), do: :crypto.strong_rand_bytes(32)
  end

  defp answer_matches?(%{"interaction_id" => id, "choices" => choices}, id, choice)
       when is_list(choices), do: Enum.any?(choices, &(Map.get(&1, "id") == choice))

  defp answer_matches?(_interaction, _id, _choice), do: false

  defp begin_live_command(state, borrower, request, kind, command, wait_ms) do
    started_at = System.monotonic_time()
    wait_deadline = started_at + native(wait_ms)
    monitor = Process.monitor(borrower)

    active = %{
      borrower: borrower,
      borrower_monitor: monitor,
      request: request,
      kind: kind,
      command_id: command.command_id,
      started_at: started_at,
      wait_deadline: wait_deadline,
      admission: :pregrant,
      operation: :command,
      facade: nil,
      timed_out: nil,
      cancel_reason: nil
    }

    state = put_in(state.session.active, active)
    state = if kind == :ask, do: put_in(state.session.model_binding, nil), else: state
    state = live_facade_operation(state, {:command, command}, :command)
    schedule_public_tick(state)
  end

  defp live_facade_operation(state, operation, kind) do
    client = Map.fetch!(state.startup.registered, :facade_client)
    reference = make_ref()
    handshake_deadline = System.monotonic_time() + native(1_000)
    send(client, {self(), reference, operation})
    Process.send_after(self(), {:live_handshake_deadline, reference}, 1_000)

    facade = %{
      pid: client,
      reference: reference,
      operation: operation,
      stage: :await_ready,
      handshake_deadline: handshake_deadline,
      operation_deadline: nil
    }

    active = %{state.session.active | operation: kind, facade: facade}
    put_in(state.session.active, active)
  end

  defp schedule_public_tick(%{session: %{active: %{borrower: borrower} = active}} = state)
       when is_pid(borrower) do
    delay = min(10, remaining(active.wait_deadline))
    Process.send_after(self(), {:public_tick, active.request}, delay)
    state
  end

  defp schedule_public_tick(state), do: state

  defp timeout_live_request(state) do
    active = state.session.active
    snapshot = no_ending_snapshot(state, active)
    result = {:error, {:timeout, snapshot}}
    send(active.borrower, {self(), active.request, result})
    Process.demonitor(active.borrower_monitor, [:flush])
    active = %{active | borrower: nil, borrower_monitor: nil, timed_out: result}
    state = put_in(state.session.active, active)

    cond do
      active.operation == :command and active.admission == :pregrant and
          active.facade.stage == :await_ready ->
        send(active.facade.pid, {self(), active.facade.reference, :cancel})
        Process.send_after(self(), {:live_cancel_deadline, active.facade.reference}, 1_000)

        state
        |> put_in([:session, :active, :facade, :stage], :cancelling)
        |> put_in([:session, :active, :cancel_reason], :wait_timeout)

      active.admission in [:accepted, :following] ->
        put_in(state.session.last_result, result)

      true ->
        state
    end
  end

  defp cancel_live_command(state) do
    active = state.session.active

    cond do
      state.phase == :stopping ->
        state |> put_in([:session, :active], nil) |> stop_abort_or_cleanup()

      active.cancel_reason == :wait_timeout or is_nil(active.borrower) ->
        if is_reference(active.borrower_monitor),
          do: Process.demonitor(active.borrower_monitor, [:flush])

        put_in(state.session.active, nil)

      true ->
        live_failure(state)
    end
  end

  defp accept_live_result(%{session: %{active: %{operation: :command} = active}} = state, result) do
    case result do
      {:accepted, id} when id == active.command_id ->
        accepted_live_command(state)

      {:error, reason}
      when (active.kind == :ask and reason == :run_open) or
             (active.kind == :answer and reason == :invalid_interaction_answer) ->
        refusal =
          if active.kind == :ask,
            do: {:error, :run_open},
            else: {:error, :invalid_interaction_answer}

        if state.phase == :stopping do
          state |> put_in([:session, :active], nil) |> stop_abort_or_cleanup()
        else
          if is_pid(active.borrower), do: send(active.borrower, {self(), active.request, refusal})

          if is_reference(active.borrower_monitor),
            do: Process.demonitor(active.borrower_monitor, [:flush])

          put_in(state.session.active, nil)
        end

      {:error, :no_active_run} when active.kind == :abort and state.phase == :stopping ->
        begin_live_poll(state)

      _ ->
        live_failure(state)
    end
  end

  defp accept_live_result(%{session: %{active: %{operation: :next_event}}} = state, result),
    do: accept_live_event(state, result)

  defp accept_live_result(
         %{session: %{active: %{operation: :settlement_status}}} = state,
         result
       ),
       do: accept_settlement_status(state, result)

  defp accepted_live_command(state) do
    active = state.session.active
    session = state.session

    session =
      if active.kind == :ask do
        %{
          session
          | run_open: true,
            run:
              new_run(
                state.startup.session_id,
                active.command_id,
                state.startup.configuration.skills.shadowed_skills
              )
        }
      else
        %{session | interaction: nil}
      end

    last_result = active.timed_out || :none

    session = %{session | last_result: last_result, active: %{active | admission: :following}}

    state = %{state | session: session}

    if state.phase == :stopping and active.kind != :abort,
      do: stop_abort_or_cleanup(state),
      else: begin_live_poll(state)
  end

  defp new_run(session_id, command_id, shadows) do
    %{
      command_id: command_id,
      run_id: nil,
      observation: %{
        text: "",
        text_truncated: false,
        profile: :ephemeral,
        session_id: session_id,
        run_id: nil,
        tools: [],
        tools_truncated: false,
        shadowed_skills: shadows
      }
    }
  end

  defp begin_live_poll(%{session: %{active: nil}} = state), do: state

  defp begin_live_poll(state) do
    state |> live_facade_operation(:next_event, :next_event)
  end

  defp schedule_live_poll(%{phase: :stopping, stop: %{abort_sent: false}} = state),
    do: stop_abort_or_cleanup(state)

  defp schedule_live_poll(%{phase: :stopping} = state) do
    probe_stop_poll(state)

    if fresh?(state.stop.grace_deadline),
      do: schedule_live_poll_fresh(state),
      else: finish_stop_run(state)
  end

  defp schedule_live_poll(state), do: schedule_live_poll_fresh(state)

  if Mix.env() == :test do
    defp probe_stop_poll(state) do
      case get_in(state.startup.configuration, [:test_seams, :stop_poll_probe]) do
        callback when is_function(callback, 0) -> callback.()
        _ -> :ok
      end
    end
  else
    defp probe_stop_poll(_state), do: :ok
  end

  defp schedule_live_poll_fresh(state) do
    marker = make_ref()
    Process.send_after(self(), {:live_poll, marker}, 10)
    state = put_in(state.session.poll_marker, marker)
    put_in(state.session.active.operation, :poll_scheduled)
  end

  defp accept_live_event(state, {:error, :empty}), do: schedule_live_poll(state)

  defp accept_live_event(state, {:ok, event}) do
    with {:ok, sequence} <- event_sequence(event, state.session.cursor),
         {:ok, state} <- project_history(state, event),
         {:ok, state, ending} <- project_live_run(state, event) do
      state = put_in(state.session.cursor, sequence)

      case ending do
        nil ->
          schedule_live_poll(state)

        {:question, question} ->
          if state.phase == :stopping,
            do: state |> put_in([:session, :interaction], question) |> stop_abort_or_cleanup(),
            else: settle_live(state, {:error, {:interaction_pending, question}}, question)

        {:terminal, result} ->
          if state.phase == :stopping do
            outcome = terminal_outcome(result)

            stop = %{
              state.stop
              | run_proved: true,
                effect_proved: outcome != :outcome_unknown,
                ending: result
            }

            %{state | stop: stop} |> finish_stop_run()
          else
            begin_model_settlement(state, result, sequence)
          end
      end
    else
      _ -> live_failure(state, true)
    end
  end

  defp accept_live_event(state, {:disconnected, _sequence}), do: live_failure(state)
  defp accept_live_event(state, {:error, _reason}), do: live_failure(state)
  defp accept_live_event(state, _unexpected), do: live_failure(state, true)

  defp terminal_outcome({:ok, _observation}), do: :completed
  defp terminal_outcome({:error, {:run, outcome, _observation}}), do: outcome

  defp event_sequence(%{event_sequence: sequence, kind: kind}, cursor)
       when is_integer(sequence) and sequence > cursor and sequence <= @uint64_max and
              is_binary(kind),
       do: {:ok, sequence}

  defp event_sequence(_event, _cursor), do: :error

  defp project_history(state, %{kind: kind} = event)
       when kind in ["user.message_appended", "assistant.message_appended"] do
    content = Map.get(event, "content")

    if is_binary(content) and String.valid?(content) do
      {text, truncated} = bounded_text(content)
      role = if(kind == "user.message_appended", do: :user, else: :assistant)
      {:ok, append_history(state, %{role: role, text: text, text_truncated: truncated})}
    else
      :error
    end
  end

  defp project_history(state, %{kind: "tool.finished"} = event) do
    id = Map.get(event, "tool_id")
    outcome = Map.get(event, "outcome")

    if (is_nil(id) or bounded_id?(id, 128)) and outcome in @tool_outcomes,
      do: {:ok, append_history(state, %{role: :tool, tool_id: id, outcome: outcome})},
      else: :error
  end

  defp project_history(state, _event), do: {:ok, state}

  defp append_history(state, entry) do
    entries = state.session.history ++ [entry]
    truncated = length(entries) > @history_max
    entries = if truncated, do: tl(entries), else: entries

    session = %{
      state.session
      | history: entries,
        history_truncated: state.session.history_truncated or truncated
    }

    %{state | session: session}
  end

  defp project_live_run(state, %{kind: "user.message_appended"} = event) do
    run = state.session.run

    if Map.get(event, "command_id") == run.command_id do
      id = Map.get(event, "run_id")

      if is_nil(run.run_id) and bounded_id?(id, 256) do
        run = %{run | run_id: id, observation: %{run.observation | run_id: id}}
        state = put_in(state.session.run, run)

        state =
          case state.session.model_binding do
            %{command_id: command_id, run_id: nil} = binding when command_id == run.command_id ->
              put_in(state.session.model_binding, %{binding | run_id: id})

            _ ->
              state
          end

        {:ok, state, nil}
      else
        :error
      end
    else
      {:ok, state, nil}
    end
  end

  defp project_live_run(state, event) do
    run = state.session.run

    if run && run.run_id && Map.get(event, "run_id") == run.run_id,
      do: project_selected_event(state, event),
      else: {:ok, state, nil}
  end

  defp project_selected_event(state, %{kind: "assistant.message_appended"} = event) do
    case Map.get(event, "content") do
      content when is_binary(content) ->
        if String.valid?(content) do
          {text, truncated} = bounded_text(content)
          run = state.session.run
          observation = %{run.observation | text: text, text_truncated: truncated}
          {:ok, put_in(state.session.run.observation, observation), nil}
        else
          :error
        end

      _ ->
        :error
    end
  end

  defp project_selected_event(state, %{kind: "tool.finished"} = event) do
    id = Map.get(event, "tool_id")
    outcome = Map.get(event, "outcome")

    if (is_nil(id) or bounded_id?(id, 128)) and outcome in @tool_outcomes do
      observation = state.session.run.observation
      tools = observation.tools ++ [%{tool_id: id, outcome: outcome}]
      truncated = length(tools) > @tool_max
      tools = if truncated, do: tl(tools), else: tools

      observation = %{
        observation
        | tools: tools,
          tools_truncated: observation.tools_truncated or truncated
      }

      {:ok, put_in(state.session.run.observation, observation), nil}
    else
      :error
    end
  end

  defp project_selected_event(state, %{kind: "interaction.requested"} = event) do
    question =
      event
      |> Map.take(~w(interaction_id run_id turn tool_call_id prompt choices expires_at))
      |> Map.put("status", "pending")

    if valid_interaction?(question), do: {:ok, state, {:question, question}}, else: :error
  end

  defp project_selected_event(state, %{kind: "run.finished"} = event) do
    with {:ok, outcome} <- Map.fetch(@run_outcomes, Map.get(event, "outcome")),
         {:ok, details} <- terminal_details(outcome, event) do
      observation =
        Map.merge(state.session.run.observation, %{outcome: outcome, details: details})

      result =
        if outcome == :completed,
          do: {:ok, observation},
          else: {:error, {:run, outcome, observation}}

      {:ok, state, {:terminal, result}}
    else
      _ -> :error
    end
  end

  defp project_selected_event(state, _event), do: {:ok, state, nil}

  defp settle_live(state, result, interaction) do
    active = state.session.active
    if is_pid(active.borrower), do: send(active.borrower, {self(), active.request, result})

    if is_reference(active.borrower_monitor),
      do: Process.demonitor(active.borrower_monitor, [:flush])

    session = %{
      state.session
      | active: nil,
        poll_marker: nil,
        last_result: result,
        interaction: interaction,
        run_open: not is_nil(interaction),
        effect_unproved:
          state.session.effect_unproved or match?({:error, {:run, :outcome_unknown, _}}, result)
    }

    %{state | session: session}
  end

  defp valid_interaction?(question) when is_map(question) do
    choices = Map.get(question, "choices")

    Enum.sort(Map.keys(question)) ==
      Enum.sort(~w(interaction_id run_id turn tool_call_id status prompt choices expires_at)) and
      bounded_id?(question["interaction_id"], 256) and
      bounded_id?(question["run_id"], 256) and
      positive_uint64?(question["turn"]) and
      bounded_id?(question["tool_call_id"], 65_536) and
      question["status"] == "pending" and
      bounded_id?(question["prompt"], 2_048) and
      is_list(choices) and length(choices) in 1..8 and
      Enum.all?(choices, fn choice ->
        is_map(choice) and Enum.sort(Map.keys(choice)) == ["id", "label"] and
          bounded_id?(choice["id"], 64) and bounded_id?(choice["label"], 256)
      end) and
      length(Enum.uniq_by(choices, & &1["id"])) == length(choices) and
      positive_uint64?(question["expires_at"])
  end

  defp terminal_details(outcome, event) do
    grace = Map.get(event, "cleanup_grace_ms")

    if positive_uint64?(grace) do
      case outcome do
        :completed ->
          {:ok, %{"cleanup_grace_ms" => grace}}

        :cancelled ->
          {:ok, %{"cleanup_grace_ms" => grace}}

        :outcome_unknown ->
          ref = Map.get(event, "reconciliation_ref")

          if bounded_id?(ref, 1_024),
            do: {:ok, %{"reconciliation_ref" => ref, "cleanup_grace_ms" => grace}},
            else: :error

        :bound_reached ->
          bound_details(event, grace)

        :failed ->
          failed_details(event, grace)
      end
    else
      :error
    end
  end

  defp bound_details(event, grace) do
    bound = Map.get(event, "bound")
    observed = Map.get(event, "observed")
    limit = Map.get(event, "declared_limit")
    source = Map.get(event, "accounting_source")

    if bound in ~w(max_turns token_budget deadline) and observed_quantity?(observed) and
         uint64?(limit) and source in ["reported", "estimated", nil] do
      {:ok,
       %{
         "bound" => bound,
         "observed" => observed,
         "declared_limit" => limit,
         "accounting_source" => source,
         "cleanup_grace_ms" => grace
       }}
    else
      :error
    end
  end

  defp failed_details(event, grace) do
    reason = Map.get(event, "reason")
    failure = Map.get(event, "failure")

    cond do
      reason in ["model_call_failed", "unreadable_model_answer"] and is_nil(failure) ->
        {:ok, %{"reason" => reason, "failure" => nil, "cleanup_grace_ms" => grace}}

      is_nil(reason) and valid_failure?(failure) ->
        {:ok,
         %{"reason" => nil, "failure" => normalize_failure(failure), "cleanup_grace_ms" => grace}}

      true ->
        :error
    end
  end

  defp valid_failure?(
         %{"category" => "deadline_preflight_failed", "retryable" => false} = failure
       ),
       do: Enum.all?(~w(dimension observed limit), &is_nil(Map.get(failure, &1)))

  defp valid_failure?(%{"category" => "context_budget_exceeded", "retryable" => false} = failure),
    do:
      Map.get(failure, "dimension") in ~w(system_class_tokens context_tokens context_record_bytes context_record_depth context_record_cardinality) and
        observed_quantity?(Map.get(failure, "observed")) and
        positive_uint64?(Map.get(failure, "limit"))

  defp valid_failure?(_), do: false

  defp normalize_failure(failure) do
    Map.take(failure, ~w(category retryable dimension observed limit))
    |> Map.put_new("dimension", nil)
    |> Map.put_new("observed", nil)
    |> Map.put_new("limit", nil)
  end

  if Mix.env() == :test do
    @doc """
    ## Concept

    Exposes the bounded text projection to test its UTF-8 byte boundary.

    ## Technical depth

    This function is absent from production builds. The Store event envelope cannot
    admit a text event large enough to exercise the boundary through a session.
    """
    def text_projection_probe(content) when is_binary(content), do: bounded_text(content)
  end

  defp bounded_text(content) when byte_size(content) <= @text_max, do: {content, false}
  defp bounded_text(content), do: {valid_prefix(binary_part(content, 0, @text_max)), true}

  defp valid_prefix(prefix) do
    if String.valid?(prefix),
      do: prefix,
      else: valid_prefix(binary_part(prefix, 0, byte_size(prefix) - 1))
  end

  defp bounded_id?(value, max),
    do: is_binary(value) and byte_size(value) in 1..max and String.valid?(value)

  defp uint64?(value), do: is_integer(value) and value >= 0 and value <= @uint64_max
  defp positive_uint64?(value), do: is_integer(value) and value > 0 and value <= @uint64_max

  defp observed_quantity?(value),
    do: is_integer(value) and value >= 0 and value <= @observed_max

  defp no_ending_snapshot(state, active) do
    current_run? =
      state.session.run != nil and
        (active.kind in [:answer, :abort] or
           state.session.run.command_id == active.command_id)

    observation =
      if current_run?,
        do: state.session.run.observation,
        else:
          new_run(
            state.startup.session_id,
            active.command_id,
            state.startup.configuration.skills.shadowed_skills
          ).observation

    Map.put(
      observation,
      :waited_ms,
      min(
        @uint64_max,
        max(
          0,
          System.convert_time_unit(
            System.monotonic_time() - active.started_at,
            :native,
            :millisecond
          )
        )
      )
    )
  end

  defp live_failure(state), do: live_failure(state, false)

  defp live_failure(%{phase: :ready, session: %{settlement: %{}}} = state, _malformed),
    do: begin_stop(state, nil)

  defp live_failure(state, malformed) do
    case state.phase do
      :ready ->
        state |> begin_stop(nil) |> fail_stopping_operation(malformed)

      :stopping ->
        fail_stopping_operation(state, malformed)
    end
  end

  defp fail_stopping_operation(%{phase: :stopping} = state, malformed) do
    state = if malformed, do: put_in(state.stop.malformed, true), else: state
    finish_stop_run(state)
  end

  if Mix.env() == :test do
    defp test_facade(configuration), do: Map.get(configuration, :test_facade, Loopex)

    defp issued_at(configuration) do
      now = Map.get(configuration, :test_now, fn -> DateTime.utc_now() end).()
      now |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    end
  else
    defp test_facade(_configuration), do: Loopex

    defp issued_at(_configuration),
      do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
  end

  defp maybe_grant(%{phase: :starting, startup: startup} = state) do
    if startup.ready and startup.root_ready and not startup.granted and
         fresh?(startup.deadline) do
      phase = startup.expected
      sender = expected_sender(startup, phase)
      send(sender, {:grant, self(), startup.reference, phase, phase_payload(state, phase)})
      %{state | startup: %{startup | ready: false, granted: true}}
    else
      state
    end
  end

  defp maybe_grant(state), do: state

  defp accept_phase_result(
         state,
         :candidate_prepare,
         {:ok, %{path: path, nonce: nonce} = candidate}
       )
       when is_binary(path) and is_binary(nonce) and byte_size(nonce) == 32 do
    advance(state, :root_claim, %{candidate: candidate})
  end

  defp accept_phase_result(state, :root_claim, {:error, :collision}),
    do: advance(state, :candidate_prepare, %{candidate: nil})

  defp accept_phase_result(
         state,
         :root_claim,
         {:error, {:claim_unproved, %{candidate: candidate, ownership: ownership} = claim}}
       )
       when ownership in [:owned, :unknown] do
    startup = state.startup

    if candidate.path == startup.candidate.path and candidate.nonce == startup.candidate.nonce do
      owned =
        if ownership == :owned and is_map(Map.get(claim, :identity)),
          do: Map.put(candidate, :identity, claim.identity),
          else: nil

      %{state | startup: %{startup | candidate: candidate, owned_root: owned}}
      |> fail_start(:temporary_root_creation_failed, ownership)
    else
      fail_start(state, :temporary_root_creation_failed, :unknown)
    end
  end

  defp accept_phase_result(state, :root_claim, {:ok, %{identity: identity} = owned})
       when is_map(identity) do
    if owned.path == state.startup.candidate.path and
         owned.nonce == state.startup.candidate.nonce do
      advance(state, :private_supervisor, %{owned_root: owned})
    else
      fail_start(state, :temporary_root_creation_failed, :unknown)
    end
  end

  defp accept_phase_result(state, :trace_bind, :ok), do: advance(state, :prepared, %{})

  defp accept_phase_result(state, :candidate_prepare, {:error, :temporary_root_unusable}),
    do: fail_start(state, :temporary_root_unusable, :known)

  defp accept_phase_result(state, phase, {:ok, value}) when phase in @phase_order do
    case register_result(state.startup, phase, value) do
      {:ok, startup} ->
        census =
          if phase == :executor do
            ModelCensus.bind_executor(state.model_census, value, startup.executor_instance)
          else
            state.model_census
          end

        if phase != :runtime,
          do: send(startup.root, {:ack, self(), startup.reference, phase, value})

        next = next_phase(phase)
        %{state | startup: startup, model_census: census} |> advance(next, %{})

      :error ->
        fail_start(state, failure_cause(phase), :unknown, true)
    end
  end

  defp accept_phase_result(state, phase, result) when phase in @phase_order do
    ownership =
      if phase == :root_claim and match?({:error, {:claim_unproved, _}}, result),
        do: :unknown,
        else: :known

    fail_start(state, failure_cause(phase), ownership)
  end

  defp advance(state, phase, changes) do
    startup =
      state.startup
      |> Map.merge(changes)
      |> Map.merge(%{
        expected: phase,
        ready: phase == :trace_bind and state.startup.early_trace_bind,
        granted: false
      })

    %{state | startup: startup} |> maybe_grant()
  end

  defp register_result(startup, phase, value)
       when phase in [
              :private_supervisor,
              :memory_store,
              :workspace_lease,
              :executor,
              :trace_capability,
              :runtime_holder
            ] and is_pid(value) do
    if Process.alive?(value) do
      monitor = Process.monitor(value)

      {:ok,
       %{
         startup
         | registered: Map.put(startup.registered, phase, value),
           process_monitors: Map.put(startup.process_monitors, value, monitor)
       }}
    else
      :error
    end
  end

  defp register_result(startup, :store_handle, %Store{reference: reference} = value)
       when reference == startup.registered.memory_store,
       do: {:ok, %{startup | registered: Map.put(startup.registered, :store_handle, value)}}

  defp register_result(startup, :trace_handle, %TraceHandle{pid: pid} = value)
       when pid == startup.registered.trace_capability,
       do: {:ok, %{startup | registered: Map.put(startup.registered, :trace_handle, value)}}

  defp register_result(startup, :runtime, %Runtime{supervisor: supervisor} = runtime)
       when is_pid(supervisor) do
    if Process.alive?(supervisor) do
      monitor = Process.monitor(supervisor)

      {:ok,
       %{
         startup
         | registered:
             Map.merge(startup.registered, %{runtime: runtime, runtime_supervisor: supervisor}),
           process_monitors: Map.put(startup.process_monitors, supervisor, monitor)
       }}
    else
      :error
    end
  end

  defp register_result(_startup, _phase, _value), do: :error

  defp next_phase(:private_supervisor), do: :memory_store
  defp next_phase(:memory_store), do: :store_handle
  defp next_phase(:store_handle), do: :workspace_lease
  defp next_phase(:workspace_lease), do: :executor
  defp next_phase(:executor), do: :trace_capability
  defp next_phase(:trace_capability), do: :trace_handle
  defp next_phase(:trace_handle), do: :runtime_holder
  defp next_phase(:runtime_holder), do: :runtime
  defp next_phase(:runtime), do: :trace_bind

  defp expected_sender(startup, :runtime), do: Map.get(startup.registered, :runtime_holder)
  defp expected_sender(startup, _phase), do: startup.root

  defp phase_payload(state, :executor) do
    [
      session_owner: self(),
      session_instance: state.startup.executor_instance,
      session_generation: state.startup.generation,
      session_cell: state.cell,
      session_admission: SessionAdmission.handle(self(), state.startup.generation, state.cell),
      cleanup_grace_ms: state.cleanup_grace_ms
    ]
  end

  defp phase_payload(state, :runtime), do: runtime_options(state)
  defp phase_payload(_state, _phase), do: nil

  defp runtime_options(state) do
    startup = state.startup
    config = startup.configuration

    tools =
      if config.tools == :none, do: [], else: Loopex.Executor.Local.CodingTools.definitions()

    active =
      if config.tools == :read_only,
        do: @read_only,
        else: if(config.tools == :none, do: [], else: @coding)

    trace = Map.fetch!(startup.registered, :trace_handle)

    model = %{
      module: Loopex.LLM.ReqLLM.InProcess,
      model: config.model,
      options: [
        base_url: config.base_url,
        credential_variable: config.provider.credential_variable,
        trace_capability: trace,
        session_admission: SessionAdmission.handle(self(), startup.generation, state.cell),
        session_cell: state.cell
      ]
    }

    [
      runtime_id: TempRoot.runtime_id(startup.owned_root.nonce),
      store: Map.fetch!(startup.registered, :store_handle),
      policy: config.policy,
      policy_identity: %{"id" => inspect(config.policy), "revision" => "0.2.0"},
      executor: %{
        module: Loopex.Executor.Local,
        reference: Map.fetch!(startup.registered, :executor),
        identity: "executor-local",
        epoch: 1,
        fencing_token: 1,
        workspace_ref: config.skills.manifest["workspace_ref"],
        workspace_lease: "workspace"
      },
      tools: tools,
      active_tools: active,
      model: model,
      bounds: %{max_turns: config.max_steps, deadline_ms: config.deadline_ms},
      sampling: %{"max_tokens" => config.max_tokens},
      context_token_budget: config.context_token_budget,
      resource_manifest: config.skills.manifest,
      cleanup_grace_ms: state.cleanup_grace_ms
    ]
  end

  defp prepared_matches?(startup, prepared) when is_map(prepared) do
    registered = startup.registered

    Map.get(prepared, :root) == startup.owned_root and
      Map.get(prepared, :supervisor) == registered.private_supervisor and
      Map.get(prepared, :store) ==
        %{pid: registered.memory_store, handle: registered.store_handle} and
      Map.get(prepared, :workspace_lease) == registered.workspace_lease and
      Map.get(prepared, :executor) == registered.executor and
      Map.get(prepared, :trace_capability) ==
        %{pid: registered.trace_capability, handle: registered.trace_handle} and
      Map.get(prepared, :runtime_holder) == registered.runtime_holder and
      Map.get(prepared, :runtime) == registered.runtime
  end

  defp prepared_matches?(_startup, _prepared), do: false

  defp live_subtree?(startup) do
    Enum.all?(Map.keys(startup.process_monitors), &Process.alive?/1)
  end

  defp failure_cause(phase) when phase in [:candidate_prepare, :root_claim],
    do: :temporary_root_creation_failed

  defp failure_cause(:private_supervisor), do: :dependency_start_failed

  defp failure_cause(phase) when phase in [:memory_store, :store_handle],
    do: :store_start_failed

  defp failure_cause(:workspace_lease), do: :workspace_lease_failed
  defp failure_cause(:executor), do: :executor_start_failed

  defp failure_cause(phase) when phase in [:trace_capability, :trace_handle],
    do: :trace_capability_start_failed

  defp failure_cause(:runtime_holder), do: :dependency_start_failed
  defp failure_cause(:runtime), do: :runtime_start_failed
  defp failure_cause(:trace_bind), do: :trace_capability_bind_failed

  defp timeout_cause(%{facade: %{operation: operation}}), do: facade_failure(operation)
  defp timeout_cause(%{expected: phase}) when phase in @phase_order, do: failure_cause(phase)
  defp timeout_cause(_startup), do: :dependency_start_failed

  # Concept: rollback observes the same one-session proof obligations as stop.
  # Technical depth: an exact returned failure is not a lost grant. Cleanup
  # attempts never block this receive loop and never remove an unowned path.
  # A returned success that cannot be registered is still uncertain, but a
  # timeout before the phase's grant cannot invent a child start.
  defp fail_start(state, cause, ownership), do: fail_start(state, cause, ownership, false)

  defp fail_start(%{startup: startup} = state, cause, ownership, unregistered_granted_result?) do
    :atomics.put(state.cell, 1, 1)

    deadline =
      if state.stop,
        do: state.stop.deadline,
        else: System.monotonic_time() + native(state.cleanup_grace_ms + 5_000)

    Process.send_after(self(), {:abort_deadline, startup.reference}, remaining(deadline))

    unknown_start =
      startup.expected in @phase_order and
        startup.expected not in [:candidate_prepare, :root_claim] and
        (startup.granted or
           (unregistered_granted_result? and ownership == :unknown and
              cause == failure_cause(startup.expected)))

    possible_root =
      cond do
        is_map(startup.owned_root) ->
          startup.owned_root.path

        startup.expected == :root_claim and is_map(startup.candidate) and
            (startup.granted or ownership in [:owned, :unknown]) ->
          startup.candidate.path

        true ->
          nil
      end

    next = %{
      state
      | phase: :aborting,
        startup:
          Map.merge(startup, %{
            cause: startup_cause(cause),
            ownership: ownership,
            possible_root: possible_root
          }),
        abort: %{
          deadline: deadline,
          stage: :facade_reap,
          down: MapSet.new(),
          worker: nil,
          unknown_start: unknown_start,
          group_proved: false,
          group_failed: false,
          subtree_failed: false,
          root_failed: false,
          root_proved: false,
          root_removal_attempted: false
        }
    }

    case Map.get(startup.registered, :facade_client) do
      client when is_pid(client) ->
        Process.exit(client, :kill)
        Process.send_after(self(), {:abort_facade_deadline, startup.reference}, 1_000)

      _ ->
        :ok
    end

    continue_abort(next)
  end

  defp continue_abort(%{abort: %{stage: :facade_reap} = abort} = state) do
    client = Map.get(state.startup.registered, :facade_client)

    if not is_pid(client) or MapSet.member?(abort.down, client),
      do: start_group_drain(state),
      else: state
  end

  defp continue_abort(%{abort: %{stage: :await_subtree} = abort} = state) do
    if all_subtree_down?(state.startup, abort.down), do: after_subtree(state), else: state
  end

  defp continue_abort(state), do: state

  defp start_group_drain(state) do
    startup = state.startup
    abort = state.abort
    executor = Map.get(startup.registered, :executor)

    cond do
      abort.group_proved ->
        start_runtime_stop(state)

      not is_pid(executor) and startup.expected == :executor and startup.granted ->
        start_runtime_stop(%{state | abort: %{abort | group_failed: true}})

      not is_pid(executor) ->
        start_runtime_stop(%{state | abort: %{abort | group_proved: true}})

      MapSet.member?(abort.down, executor) or not Process.alive?(executor) ->
        start_runtime_stop(%{state | abort: %{abort | group_failed: true}})

      true ->
        start_abort_worker(state, :process_groups, make_ref())
    end
  end

  defp start_runtime_stop(state) do
    runtime = Map.get(state.startup.registered, :runtime)

    if match?(%Runtime{}, runtime) and
         not MapSet.member?(state.abort.down, runtime.supervisor) do
      start_abort_worker(state, :runtime_stop, nil)
    else
      start_subtree_stop(state)
    end
  end

  defp start_subtree_stop(state) do
    if MapSet.member?(state.abort.down, state.startup.root),
      do: await_subtree(state),
      else: start_abort_worker(state, :subtree_stop, nil)
  end

  defp await_subtree(state) do
    next = %{state | abort: %{state.abort | stage: :await_subtree}}
    continue_abort(next)
  end

  defp after_subtree(%{abort: abort, startup: startup} = state) do
    cond do
      abort.unknown_start or abort.group_failed or abort.subtree_failed ->
        finish_abort(state)

      state.stop && (not state.stop.run_proved or not state.stop.effect_proved) ->
        finish_abort(state)

      not model_settled?(state) and fresh?(abort.deadline) ->
        reference = make_ref()

        Process.send_after(
          self(),
          {:model_settle_check, reference},
          min(10, remaining(abort.deadline))
        )

        %{state | abort: %{abort | stage: {:await_model, reference}}}

      not model_settled?(state) ->
        finish_abort(state)

      is_map(startup.owned_root) ->
        start_abort_worker(state, :root_removal, nil)

      startup.possible_root != nil ->
        finish_abort(%{state | abort: %{abort | root_failed: true}})

      true ->
        finish_abort(%{state | abort: %{abort | root_proved: true}})
    end
  end

  defp start_abort_worker(state, phase, nonce) do
    owner = self()
    reference = make_ref()
    now = System.monotonic_time()
    cutoff = min(now + native(500), state.abort.deadline)
    slot = min(now + native(1_000), state.abort.deadline)

    {pid, monitor} =
      :erlang.spawn_opt(
        fn ->
          Process.flag(:sensitive, true)
          install_temp_root_test_seam(state.startup.configuration)

          result =
            try do
              abort_operation(state, phase, nonce, cutoff)
            rescue
              _ -> {:error, :operation_failed}
            catch
              _, _ -> {:error, :operation_failed}
            end

          send(owner, {self(), reference, phase, :result, result, System.monotonic_time()})

          receive do
            {^owner, ^reference, :finish} -> :ok
          after
            remaining(slot) -> exit(:finish_not_received)
          end
        end,
        [:link, :monitor]
      )

    Process.send_after(self(), {:abort_operation_cutoff, reference}, remaining(cutoff))
    Process.send_after(self(), {:abort_slot_deadline, reference}, remaining(slot))

    worker = %{
      pid: pid,
      monitor: monitor,
      reference: reference,
      phase: phase,
      nonce: nonce,
      cutoff: cutoff,
      result: false,
      certificate: false,
      finish_sent: false
    }

    abort = %{
      state.abort
      | stage: phase,
        worker: worker,
        root_removal_attempted: state.abort.root_removal_attempted or phase == :root_removal
    }

    %{state | abort: abort}
  end

  if Mix.env() == :test do
    defp install_temp_root_test_seam(configuration) do
      case get_in(configuration, [:test_seams, :temp_root]) do
        seams when is_map(seams) -> Process.put({TempRoot, :dependencies}, seams)
        _ -> :ok
      end
    end
  else
    defp install_temp_root_test_seam(_configuration), do: :ok
  end

  defp abort_operation(state, :process_groups, nonce, deadline) do
    startup = state.startup

    group_drain(startup.configuration).(
      startup.registered.executor,
      startup.executor_instance,
      self_owner(state),
      nonce,
      deadline
    )
  end

  defp abort_operation(state, :runtime_stop, _nonce, _deadline),
    do: Loopex.stop(state.startup.registered.runtime)

  defp abort_operation(state, :subtree_stop, _nonce, _deadline) do
    Process.exit(state.startup.root, :shutdown)
    :ok
  end

  defp abort_operation(state, :root_removal, _nonce, _deadline),
    do: TempRoot.remove(state.startup.owned_root, state.abort.root_removal_attempted)

  defp abort_operation(state, :root_absence, _nonce, _deadline) do
    case File.lstat(state.startup.owned_root.path) do
      {:error, :enoent} -> :ok
      _ -> {:error, :root_removal_unproved}
    end
  end

  defp self_owner(state), do: state.startup.owner

  defp valid_abort_result?(:process_groups, {:ok, nonce}, nonce), do: true

  defp valid_abort_result?(phase, :ok, _nonce)
       when phase in [:runtime_stop, :subtree_stop, :root_removal, :root_absence], do: true

  defp valid_abort_result?(_phase, _result, _nonce), do: false

  defp maybe_finish_abort_worker(%{abort: %{worker: worker}} = state) do
    if worker.result and (worker.phase != :process_groups or worker.certificate) and
         not worker.finish_sent do
      send(worker.pid, {self(), worker.reference, :finish})
      put_in(state.abort.worker.finish_sent, true)
    else
      state
    end
  end

  defp finish_abort_worker(%{abort: %{worker: worker} = abort} = state, reason) do
    success =
      worker.result and worker.finish_sent and reason == :normal and
        (worker.phase != :process_groups or worker.certificate)

    next = %{state | abort: %{abort | worker: nil}}

    case worker.phase do
      :process_groups ->
        next = %{next | abort: %{next.abort | group_proved: success, group_failed: not success}}
        start_runtime_stop(next)

      :runtime_stop ->
        start_subtree_stop(next)

      :subtree_stop ->
        next = %{next | abort: %{next.abort | subtree_failed: not success}}
        await_subtree(next)

      :root_removal ->
        if success,
          do: start_abort_worker(next, :root_absence, nil),
          else: finish_abort(%{next | abort: %{next.abort | root_failed: true}})

      :root_absence ->
        finish_abort(%{
          next
          | abort: %{next.abort | root_proved: success, root_failed: not success}
        })
    end
  end

  defp mark_abort_timeout(state) do
    phase = state.abort.stage
    abort = state.abort

    abort =
      cond do
        phase == :process_groups ->
          %{abort | group_failed: true}

        phase in [:root_removal, :root_absence] ->
          %{abort | root_failed: true}

        phase in [:runtime_stop, :subtree_stop, :await_subtree, :facade_reap] ->
          %{abort | subtree_failed: true}

        true ->
          abort
      end

    %{state | abort: abort}
  end

  defp all_subtree_down?(startup, down) do
    Enum.all?(Map.keys(startup.process_monitors), &MapSet.member?(down, &1))
  end

  defp model_settled?(%{model_census: nil}), do: true
  defp model_settled?(%{model_census: census}), do: ModelCensus.settled?(census)

  defp finish_abort(%{phase: :aborting, startup: startup, abort: abort} = state) do
    pending =
      []
      |> maybe_pending(not is_nil(state.stop) and not state.stop.run_proved, :run_ending)
      |> maybe_pending(
        not is_nil(state.stop) and state.stop.run_proved and not state.stop.effect_proved,
        :effect_cleanup
      )
      |> maybe_pending(abort.group_failed, :process_groups)
      |> maybe_pending(
        abort.unknown_start or abort.subtree_failed or
          not model_settled?(state) or
          not all_subtree_down?(startup, abort.down) or
          (abort.worker != nil and abort.worker.phase not in [:root_removal, :root_absence]),
        :session_subtree
      )
      |> maybe_pending(abort.root_failed, :root_removal)

    result =
      if pending == [] and (abort.root_proved or startup.possible_root == nil) do
        if state.stop, do: :ok, else: {:error, startup.cause}
      else
        {:error,
         {:cleanup_unproved,
          %{
            root: startup.possible_root,
            root_ownership: if(is_map(startup.owned_root), do: :owned, else: :unknown),
            pending: pending,
            ending: if(state.stop, do: state.stop.ending, else: :none),
            cause: startup.cause
          }}}
      end

    :atomics.put(
      state.cell,
      1,
      if(match?({:error, {:cleanup_unproved, _}}, result), do: 3, else: 2)
    )

    if state.stop do
      finish_stop_abort(state, result, pending)
    else
      unless startup.replied, do: send(state.creator, {self(), startup.request, result})
      send(self(), :retire_sealed)
      %{state | phase: :sealed}
    end
  end

  defp finish_stop_abort(state, result, pending) do
    Enum.each(state.stop.waiters, fn {pid, reference} ->
      send(pid, {self(), reference, result})
    end)

    if state.stop.waiting && is_pid(state.stop.waiting.borrower) do
      reply =
        case result do
          :ok ->
            if state.stop.run_proved and state.stop.ending != :none,
              do: state.stop.ending,
              else: {:error, :session_unavailable}

          _ ->
            result
        end

      send(state.stop.waiting.borrower, {self(), state.stop.waiting.request, reply})
    end

    if pending != [] and Enum.all?(pending, &(&1 in [:session_subtree, :root_removal])) and
         not state.stop.no_retry do
      %{
        state
        | phase: :failed_stop,
          stop:
            Map.merge(state.stop, %{waiters: [], waiting: nil, pending: pending, result: result})
      }
    else
      if pending != [] and state.stop.no_retry,
        do:
          Logger.error(
            "ephemeral cleanup unproved root=#{inspect(state.startup.possible_root)} pending=#{inspect(pending)}"
          )

      send(self(), :retire_sealed)

      %{
        state
        | phase: :sealed,
          stop: Map.merge(state.stop, %{waiters: [], waiting: nil, result: result})
      }
    end
  end

  defp maybe_pending(pending, true, item), do: pending ++ [item]
  defp maybe_pending(pending, false, _item), do: pending

  defp startup_cause(:session_create_failed), do: {:session_create, :failed}
  defp startup_cause(:client_start_failed), do: {:client_start, :failed}
  defp startup_cause(:attach_failed), do: {:attach, :failed}
  defp startup_cause(:resource_admission_failed), do: {:resource_admission, :failed}
  defp startup_cause(:skill_activation_failed), do: {:skill_activation, :failed}
  defp startup_cause(cause), do: {:composition, cause}

  if Mix.env() == :test do
    defp group_drain(configuration),
      do:
        get_in(configuration, [:test_seams, :group_drain]) ||
          default_group_drain()
  else
    defp group_drain(_configuration), do: default_group_drain()
  end

  defp default_group_drain do
    fn executor, instance, owner, nonce, deadline ->
      apply(Loopex.Executor.Local, :drain_process_groups, [
        executor,
        instance,
        owner,
        nonce,
        deadline
      ])
    end
  end

  defp close_proved(state) do
    :atomics.put(state.cell, 1, 2)
    send(self(), :retire_sealed)
    %{state | phase: :sealed}
  end

  if Mix.env() == :test do
    defp test_seams(configuration), do: Map.get(configuration, :test_seams, %{})
  else
    defp test_seams(_configuration), do: %{}
  end

  defp native(ms), do: System.convert_time_unit(ms, :millisecond, :native)

  defp fresh?(expiry), do: is_integer(expiry) and System.monotonic_time() < expiry

  defp supervisor_from_ancestry do
    case {Process.get(:"$ancestors"), Process.info(self(), :links)} do
      {[parent | _], {:links, links}} when is_pid(parent) ->
        if parent in links, do: parent, else: nil

      {[name | _], {:links, links}} when is_atom(name) ->
        case Process.whereis(name) do
          parent when is_pid(parent) -> if(parent in links, do: parent, else: nil)
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp remaining(expiry) do
    difference = max(expiry - System.monotonic_time(), 0)
    unit = System.convert_time_unit(1, :millisecond, :native)
    div(difference + unit - 1, unit)
  end
end
