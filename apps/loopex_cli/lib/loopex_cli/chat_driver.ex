defmodule LoopexCli.ChatDriver do
  @moduledoc """
  ## Concept

  Own the local chat transport while the runtime owns the durable conversation.
  Read one input at a time, acknowledge admission before showing its events,
  and stop reading at a wait barrier until committed evidence settles it.

  ## Technical depth

  This private driver joins an already created session. It opens no placement,
  credential or provider. Two linked, monitored workers hold separate facade
  attachments for commands and events. Each has at most one outstanding reply;
  the event worker waits for an explicit grant. A separate input worker reads
  one bounded line. Blocking IO and facade calls cannot block the driver's
  cancellation mailbox. Quit captures the existing session cleanup backstop
  once. A confirmed local result requires every owned worker DOWN. On a spent cutoff
  or second interrupt, an unknown result returns while this private owner retains
  any outstanding monitors, without a further runtime result route.
  The host calls close only after composition and credential cleanup, so a
  closing record cannot precede those proofs. Status reads committed settings
  and runtime trace counters through the command worker. Its continuation
  warning requires an exact confirmed configuration cache. Active maintenance
  and completed compact observations come from committed public facts.
  Configuration, maintenance,
  tracing and process-signal startup are joined by the outer command host.
  """

  use GenServer
  alias LoopexCli.{ChatControl, ChatInput, Output, Render}
  alias LoopexProtocol.Session.{CompactResult, Outcome}

  @outcomes %{
    "completed" => :completed,
    "cancelled" => :cancelled,
    "failed" => :failed,
    "bound_reached" => :bound_reached,
    "outcome_unknown" => :outcome_unknown
  }
  @details %{
    completed: ~w(cleanup_grace_ms),
    cancelled: ~w(cleanup_grace_ms),
    failed: ~w(reason failure cleanup_grace_ms),
    bound_reached: ~w(bound observed declared_limit accounting_source cleanup_grace_ms),
    outcome_unknown: ~w(reconciliation_ref cleanup_grace_ms)
  }

  @doc """
  ## Concept

  Start a disposable transport owner for one explicit session.

  ## Technical depth

  Input is an existing Latin-1 byte device. Output is a target this driver
  acquires as its command's output owner: `:stdio` or an owned custom target. Options select pipe or interactive refusal handling, already validated
  invocation run bounds, an optional prepared new-session configuration and
  the private facade test seam. A supplied cleanup grace must be validated and
  match the session; it sizes cancellation before the first status reply.
  The command holder resolves configure changes
  against its last confirmed candidate; refusal never updates that cache.
  Optional status_policy supplies the trusted wrapper's closed inspection
  provenance; ordinary prepared configuration uses the existing policy registry
  identity. Neither value grants command authority. Only fresh prompts
  receive those bounds; follow-ups inherit their active run through Core. The creating caller is monitored even on a normal exit.
  """
  def start_link(runtime, session_id, input, output, options \\ []) do
    grace = Keyword.get(options, :cleanup_grace_ms)

    if grace == nil or match?({:ok, _}, Loopex.Executor.cancellation_bounds(grace)) do
      GenServer.start_link(__MODULE__, {self(), runtime, session_id, input, output, options})
    else
      {:error, :invalid_chat_cleanup_grace}
    end
  end

  # Concept: own output before composition starts any runtime or provider work.
  # Technical depth: an unbound driver owns only its output owner and native
  # sink. The creating host binds the exact runtime/session before
  # attachments, activation or input.
  @doc false
  def bootstrap(input, output, options), do: start_link(nil, nil, input, output, options)

  # Concept: the serving runtime offers progress into this driver's sink.
  @doc false
  def progress_sink(driver), do: GenServer.call(driver, :progress_sink)

  @doc false
  def bind(driver, runtime, session, options),
    do: GenServer.call(driver, {:bind, runtime, session, options})

  @doc false
  def seal_progress(driver), do: GenServer.call(driver, :seal_progress)

  @doc """
  ## Concept

  Open the chat attachments before the host activates a resumed session.

  ## Technical depth

  Only the creating caller may prepare. Readiness returns the public session
  status without consuming input or granting event reads. The host can then
  finish its checks and signal installation before run. A startup failure
  returns an error containing the provisional cleanup result; close still
  belongs after outer cleanup. Cancellation never restarts attachment workers.
  """
  def prepare(driver), do: GenServer.call(driver, :prepare, :infinity)

  @doc """
  ## Concept

  Drive the conversation until quit, EOF or transport failure.

  ## Technical depth

  The returned map is provisional. Its local worker proof cannot establish
  composition cleanup. The driver and output manager remain alive for close.
  """
  def run(driver), do: GenServer.call(driver, :run, :infinity)

  @doc """
  ## Concept

  Emit the final record after the outer host has established cleanup.

  ## Technical depth

  Unknown cleanup forces a nonzero exit. Output failure also forces nonzero;
  successful delivery is separate from the supplied runtime cleanup proof.
  The host may supply a minimum nonzero exit after its signal handler has
  serialized the final decision; that cannot erase an earlier failure.
  """
  def close(driver, cleanup, minimum_exit_code \\ 0),
    do: GenServer.call(driver, {:close, cleanup, minimum_exit_code}, :infinity)

  @doc """
  ## Concept

  Notify this transport owner of host cancellation.

  ## Technical depth

  The first notification captures one cleanup cutoff. A second stops waiting
  and reports unknown cleanup; neither notification bypasses admission fencing.
  The outer host installs the operating-system signal route separately.
  """
  def interrupt(driver), do: send(driver, :interrupt)

  # Concept: startup refusal uses the driver's existing bounded output and stop.
  # Technical depth: the owner supplies a fixed host code before any input read;
  # the reply is provisional until the outer host has cleaned composition.
  @doc false
  def refuse_startup(driver, code),
    do: GenServer.call(driver, {:refuse_startup, code}, :infinity)

  @impl true
  def init({owner, runtime, session, input, target, options}) do
    Process.flag(:trap_exit, true)

    case Output.open(target, Output.acquisition(),
           mode: :chat,
           progress_device: Keyword.get(options, :progress_device, :stderr)
         ) do
      {:ok, output, sink} -> init_state(owner, runtime, session, input, output, sink, options)
      {:error, _code} -> {:stop, :normal}
    end
  end

  defp init_state(owner, runtime, session, input, output, sink, options) do
    grace = Keyword.get(options, :cleanup_grace_ms)
    facade = Keyword.get(options, :facade, &apply/3)

    state = %{
      owner: owner,
      owner_monitor: Process.monitor(owner),
      runtime: runtime,
      session: session,
      input: input,
      mode: Keyword.get(options, :mode, :pipe),
      default_bounds: Keyword.get(options, :bounds),
      configuration: Keyword.get(options, :configuration),
      status_policy: Keyword.get(options, :status_policy),
      output: output,
      sink: sink,
      held_assistant: nil,
      progress_sealed: false,
      progress_reported: false,
      progress_dropped: nil,
      output_deadline: nil,
      facade: facade,
      workers: %{},
      command: nil,
      reader: nil,
      input_worker: nil,
      waiting_event: nil,
      reader_busy: false,
      pending: nil,
      ready: MapSet.new(),
      from: nil,
      prepare_from: nil,
      startup: :idle,
      sequence: 0,
      cursor: 0,
      last_run: nil,
      known_run: nil,
      last_outcome: nil,
      last_compact: nil,
      compact_commands: MapSet.new(),
      barrier: nil,
      status: nil,
      exit_code: 0,
      stopping: false,
      stop_abort_sent: false,
      reaping: false,
      give_up: false,
      closed: false,
      deadline: nil,
      cutoff_timer: nil,
      local_cleanup: :confirmed,
      cleanup_grace_ms: grace,
      timer: nil,
      finished: false,
      transport: nil,
      unresolved: nil
    }

    {:ok, state}
  end

  @impl true
  def handle_call(
        {:bind, runtime, session, options},
        {caller, _},
        %{owner: caller, runtime: nil, session: nil, startup: :idle, stopping: false} = state
      )
      when is_binary(session) and is_list(options) do
    {:reply, :ok,
     %{
       state
       | runtime: runtime,
         session: session,
         configuration: Keyword.get(options, :configuration),
         status_policy: Keyword.get(options, :status_policy),
         default_bounds: Keyword.get(options, :bounds),
         cleanup_grace_ms: Keyword.get(options, :cleanup_grace_ms, state.cleanup_grace_ms)
     }}
  end

  def handle_call(:progress_sink, {caller, _}, %{owner: caller} = state),
    do: {:reply, state.sink, state}

  def handle_call(:seal_progress, {caller, _}, %{owner: caller} = state) do
    first = not state.progress_reported
    state = seal_progress_state(state)
    {:reply, {state.progress_dropped, first}, %{state | progress_reported: true}}
  end

  def handle_call(operation, {caller, _}, %{owner: caller, runtime: nil} = state)
      when operation in [:prepare, :run],
      do: {:reply, {:error, :chat_not_bound}, state}

  def handle_call(
        operation,
        {caller, _} = from,
        %{owner: caller, finished: false, stopping: true} = state
      )
      when operation in [:prepare, :run] do
    {:noreply, state |> startup_caller(operation, from) |> maybe_finished()}
  end

  def handle_call(
        :prepare,
        {caller, _},
        %{owner: caller, startup: :ready, finished: false} = state
      ),
      do: {:reply, {:ok, state.status}, state}

  def handle_call(:prepare, {caller, _} = from, %{owner: caller, startup: :idle} = state),
    do: {:noreply, state |> startup_caller(:prepare, from) |> start_attachments()}

  def handle_call(
        :run,
        {caller, _} = from,
        %{owner: caller, startup: :ready, from: nil, finished: false} = state
      ),
      do: {:noreply, %{state | from: from} |> read_input() |> grant_event()}

  def handle_call(:run, {caller, _} = from, %{owner: caller, from: nil, finished: false} = state) do
    {:noreply, state |> startup_caller(:run, from) |> start_attachments()}
  end

  def handle_call(
        {:refuse_startup, code},
        {caller, _} = from,
        %{owner: caller, startup: :idle, from: nil, finished: false, workers: workers} = state
      )
      when is_atom(code) and code not in [nil, true, false] and map_size(workers) == 0 do
    {:noreply,
     %{state | from: from, stopping: true, reaping: true, exit_code: 1}
     |> error(code)
     |> maybe_finished()}
  end

  def handle_call(
        {:refuse_startup, code},
        {caller, _} = from,
        %{owner: caller, startup: :ready, from: nil, finished: false} = state
      )
      when is_atom(code) and code not in [nil, true, false] do
    # Concept: startup owns only local attachments until the host activates.
    # Technical depth: capture the ordinary join cutoff, then reap without a
    # session abort. Even output refusal sees stopping=true before it can fail.
    {:noreply,
     %{state | from: from, transport: code, exit_code: max(state.exit_code, 1)}
     |> capture_stop_deadline()
     |> error(code)
     |> reap()
     |> maybe_finished()}
  end

  def handle_call(
        {:close, cleanup, minimum_exit_code},
        {caller, _},
        %{owner: caller, finished: true} = state
      )
      when cleanup in [:confirmed, :unknown] and minimum_exit_code in [0, 1] do
    cleanup = if state.local_cleanup == :unknown, do: :unknown, else: cleanup
    state = release_held(state)
    code = max(state.exit_code, minimum_exit_code)
    code = if cleanup == :confirmed, do: code, else: max(code, 1)

    result =
      emit(state, :closing, %{exit_code: code, cleanup: cleanup, last_outcome: state.last_outcome})

    delivered = finish_output(state)
    code = if result == :ok and delivered == :ok, do: code, else: max(code, 1)

    if map_size(state.workers) == 0,
      do: {:stop, :normal, code, state},
      else: {:reply, code, %{state | closed: true}}
  end

  def handle_call(_, _from, state), do: {:reply, {:error, :invalid_chat_driver_call}, state}

  @impl true
  def handle_info({pid, ref, :ready, _attachment}, state) do
    case owned(state, pid, ref) do
      kind when kind in [:command, :reader] and not state.reaping ->
        state = %{state | ready: MapSet.put(state.ready, kind)}

        state =
          if MapSet.size(state.ready) == 2,
            do: %{ask_status(state) | pending: :startup_status},
            else: state

        {:noreply, state}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({pid, ref, :input, result}, state) do
    if owned(state, pid, ref) == :input do
      workers = Map.update!(state.workers, pid, &Map.put(&1, :result, result))
      {:noreply, %{state | workers: workers}}
    else
      {:noreply, state}
    end
  end

  def handle_info({pid, ref, :event, result}, state) do
    if owned(state, pid, ref) == :reader do
      state = %{state | waiting_event: result, reader_busy: false}

      {:noreply,
       if(state.pending == nil or match?({:inspect_tail, _, _}, state.pending),
         do: consume_event(state),
         else: state
       )}
    else
      {:noreply, state}
    end
  end

  def handle_info({pid, ref, :reply, result}, state) do
    if owned(state, pid, ref) == :command do
      {:noreply, command_reply(state, result)}
    else
      {:noreply, state}
    end
  end

  def handle_info({:DOWN, monitor, :process, pid, reason}, state) do
    case Map.get(state.workers, pid) do
      %{monitor: ^monitor, kind: :input, result: result} ->
        state = %{state | workers: Map.delete(state.workers, pid), input_worker: nil}

        state =
          cond do
            state.stopping -> state
            reason == :normal -> input_result(state, result)
            true -> stop_input(state, :input_failed)
          end

        join_reply(maybe_finished(state))

      %{monitor: ^monitor, kind: kind} ->
        state = %{
          state
          | workers: Map.delete(state.workers, pid),
            ready: MapSet.delete(state.ready, kind)
        }

        state = Map.put(state, kind, nil)

        state =
          if state.finished or state.reaping do
            state
          else
            state |> fail(:chat_worker_failed) |> unknown_cleanup() |> reap()
          end

        join_reply(maybe_finished(state))

      _ when monitor == state.owner_monitor and pid == state.owner ->
        state = reap(%{state | from: nil, prepare_from: nil, finished: true, closed: true})
        join_reply(state)

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:EXIT, _, _}, state), do: {:noreply, state}

  def handle_info(
        {:loopex_cli_output_deadline, incarnation, deadline},
        %{output: {:loopex_cli_output, _, incarnation}} = state
      )
      when is_integer(deadline) or is_nil(deadline) do
    state = retain_display_deadline(state, deadline)
    {:noreply, shorten_stop(%{state | output_deadline: deadline}, deadline)}
  end

  def handle_info(
        {:loopex_cli_output_failed, incarnation, code},
        %{output: {:loopex_cli_output, _, incarnation}} = state
      ),
      do: {:noreply, fail(state, code)}

  def handle_info(
        {:compact_displayed, id, cutoff},
        %{pending: {:compact_display, %{command_id: id} = command, cutoff}} = state
      ) do
    if not state.stopping and System.monotonic_time(:millisecond) < cutoff do
      state = %{state | pending: nil, compact_commands: MapSet.put(state.compact_commands, id)}
      {:noreply, admit(state, command)}
    else
      {:noreply, fail(state, :output_drain_timeout)}
    end
  end

  def handle_info(
        {:compact_displayed, id, _},
        %{pending: {:compact_display, %{command_id: id}, _}} = state
      ),
      do: {:noreply, schedule(state)}

  def handle_info({:compact_displayed, _, _}, state), do: {:noreply, state}

  def handle_info(:poll, %{pending: {:compact_display, _, _}} = state),
    do: {:noreply, poll_compact_display(%{state | timer: nil})}

  def handle_info(:poll, state) do
    state = %{state | timer: nil}

    {:noreply,
     if(state.pending == nil and state.barrier != nil,
       do: ask_status(state),
       else: grant_event(state)
     )}
  end

  def handle_info(:cutoff, %{finished: true} = state), do: {:noreply, state}

  def handle_info(:cutoff, state),
    do: {:noreply, state |> unknown_cleanup() |> reap() |> maybe_finished()}

  def handle_info(:interrupt, %{finished: true} = state), do: {:noreply, state}

  def handle_info(:interrupt, %{stopping: true} = state),
    do: {:noreply, state |> unknown_cleanup() |> reap() |> maybe_finished()}

  def handle_info(:interrupt, state),
    do: {:noreply, begin_stop(%{state | exit_code: max(state.exit_code, 1)})}

  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    Enum.each(state.workers, fn {pid, _} -> Process.exit(pid, :kill) end)
  end

  @impl true
  def format_status(status) do
    Map.new(status, fn
      {:state, state} ->
        {:state, Map.take(state, [:sequence, :cursor, :exit_code, :stopping, :finished])}

      {:message, _} ->
        {:message, :redacted}

      {:log, _} ->
        {:log, []}

      other ->
        other
    end)
  end

  defp spawn_owned(state, kind, function) do
    parent = self()
    ref = make_ref()
    {pid, monitor} = :erlang.spawn_opt(fn -> function.(parent, ref) end, [:link, :monitor])

    state = %{
      state
      | workers:
          Map.put(state.workers, pid, %{monitor: monitor, ref: ref, kind: kind, result: nil})
    }

    Map.put(state, if(kind == :input, do: :input_worker, else: kind), pid)
  end

  defp startup_caller(state, :prepare, from), do: %{state | prepare_from: from}
  defp startup_caller(state, :run, from), do: %{state | from: from}

  defp start_attachments(state) do
    state = %{state | startup: :starting}
    state = spawn_owned(state, :command, fn parent, ref -> command_worker(parent, ref, state) end)
    spawn_owned(state, :reader, fn parent, ref -> event_worker(parent, ref, state) end)
  end

  defp owned(state, pid, ref) do
    case state.workers[pid] do
      %{ref: ^ref, kind: kind} -> kind
      _ -> nil
    end
  end

  defp command_worker(parent, ref, state) do
    case state.facade.(Loopex, :attach, [state.runtime, state.session, []]) do
      {:ok, attachment} ->
        send(parent, {self(), ref, :ready, attachment})
        command_loop(parent, ref, attachment, state)

      _ ->
        exit(:attachment_failed)
    end
  end

  # Concept: status combines committed session values with this host's choices.
  # Technical depth: only the command worker performs facade reads. The retained
  # mapping cache must name the public configuration version before it can supply
  # a continuation warning; an external configure cannot silently reuse it.
  defp inspect_status(state) do
    with {:ok, %{compact_pending: busy} = status} when is_boolean(busy) <-
           state.facade.(Loopex, :session_status, [state.runtime, state.session]),
         {:ok, trace} <- inspected_trace(state),
         {:ok, maintenance} <- inspected_maintenance(state.configuration, status),
         policy when is_map(policy) <- inspected_policy(state) do
      configuration = status.configuration || %{}

      {:ok,
       %{
         run_id: status.active_run_id,
         state: status.status,
         configuration_version: configuration["configuration_version"],
         model: configuration["model"],
         reasoning: configuration["reasoning"],
         bounds: status.active_bounds,
         interaction_id:
           if(status.open_interaction, do: status.open_interaction["interaction_id"]),
         trace: trace,
         maintenance: maintenance,
         policy: policy,
         event_sequence: status.event_sequence
       }}
    else
      _ -> {:error, :chat_status_unavailable}
    end
  end

  defp inspected_trace(state) do
    case state.facade.(Loopex, :trace_status, [state.runtime]) do
      {:ok, %{emitted: emitted, dropped: dropped}} ->
        {:ok, %{enabled: true, emitted: emitted, dropped: dropped}}

      {:error, :no_trace_session} ->
        {:ok, %{enabled: false, emitted: 0, dropped: 0}}

      _ ->
        {:error, :chat_status_unavailable}
    end
  end

  defp inspected_maintenance(nil, %{configuration: nil}),
    do: {:ok, %{configured_model: nil, active_model: nil, warning: nil, last_compact: nil}}

  defp inspected_maintenance(%{selection: selection}, %{configuration: public} = status)
       when is_map(public) do
    captured = selection.configuration

    if Loopex.Runtime.SessionConfiguration.public_view(captured) == public do
      configured = if selection.maintenance_model, do: selection.maintenance_model["model"]

      warning =
        if captured["provider_mapping"]["continuation_required"] and configured == nil,
          do: :maintenance_unconfigured

      {:ok,
       %{
         configured_model: configured,
         active_model: if(status.active_maintenance, do: status.active_maintenance["model"]),
         warning: warning,
         last_compact: nil
       }}
    else
      {:error, :chat_status_unavailable}
    end
  end

  defp inspected_maintenance(_, _), do: {:error, :chat_status_unavailable}

  defp inspected_policy(%{status_policy: policy}) when is_map(policy), do: policy

  defp inspected_policy(%{configuration: %{selection: %{profile: %{"policy" => name}}}}) do
    case Map.fetch(LoopexCli.AskOptions.policy_profiles(), name) do
      {:ok, module} ->
        %{origin: :registry, id: inspect(module), revision: "0.2.0", fixture_manifest_digest: nil}

      _ ->
        nil
    end
  end

  defp inspected_policy(_), do: nil

  defp command_loop(parent, ref, attachment, state) do
    receive do
      {^parent, ^ref, :configure, command} ->
        {result, prepared} = configure(attachment, command, state)
        send(parent, {self(), ref, :reply, result})
        command_loop(parent, ref, attachment, %{state | configuration: prepared})

      {^parent, ^ref, :command, command} ->
        send(
          parent,
          {self(), ref, :reply, submit_command(attachment, command, state)}
        )

        command_loop(parent, ref, attachment, state)

      {^parent, ^ref, :status} ->
        send(
          parent,
          {self(), ref, :reply,
           state.facade.(Loopex, :session_status, [state.runtime, state.session])}
        )

        command_loop(parent, ref, attachment, state)

      {^parent, ^ref, :inspect_status} ->
        send(parent, {self(), ref, :reply, inspect_status(state)})
        command_loop(parent, ref, attachment, state)

      {^parent, ^ref, :observe, id} ->
        send(
          parent,
          {self(), ref, :reply, state.facade.(Loopex, :command_disposition, [attachment, id])}
        )

        command_loop(parent, ref, attachment, state)
    end
  end

  # Concept: terminal steering names the run observed by this command holder.
  # Technical depth: events can lag admission, including on resume. Read the
  # public active run before submission; Core refuses if it changes before
  # admission, rather than putting the input into another run.
  # Concept: ADR 0069's host-route guard runs before every chat mutation.
  # Technical depth: a helper child refuses here, before Core admission, so the
  # refused command commits nothing; ordinary sessions pass through unchanged.
  defp submit_command(attachment, command, state) do
    case LoopexComposition.Delegation.guard(state.runtime, state.session, command.type) do
      :ok -> submit(attachment, command, state)
      refusal -> refusal
    end
  end

  defp submit(attachment, %{type: :steer} = command, state) do
    case state.facade.(Loopex, :session_status, [state.runtime, state.session]) do
      {:ok, %{active_run_id: run}} when is_binary(run) ->
        state.facade.(Loopex, :command, [attachment, Map.put(command, :run_id, run)])

      {:ok, %{active_run_id: nil}} ->
        {:error, :no_active_run}

      {:error, _} = error ->
        error
    end
  end

  defp submit(attachment, command, state),
    do: state.facade.(Loopex, :command, [attachment, command])

  defp configure(attachment, command, state) do
    with :ok <- LoopexComposition.Delegation.guard(state.runtime, state.session, :configure),
         {:ok, changes, candidate} <-
           LoopexCli.ChatConfiguration.update(state.configuration, command.changes) do
      result =
        state.facade.(Loopex, :command_with_configuration, [
          attachment,
          %{command | changes: changes},
          candidate
        ])

      prepared =
        if result == {:accepted, command.command_id},
          do: put_in(state.configuration, [:selection, :configuration], candidate),
          else: state.configuration

      {result, prepared}
    else
      {:error, _} = result -> {result, state.configuration}
    end
  end

  defp event_worker(parent, ref, state) do
    case state.facade.(Loopex, :attach, [state.runtime, state.session, [after_event_sequence: 0]]) do
      {:ok, attachment} ->
        send(parent, {self(), ref, :ready, attachment})
        event_loop(parent, ref, attachment, state.facade)

      _ ->
        exit(:attachment_failed)
    end
  end

  defp event_loop(parent, ref, attachment, facade) do
    receive do
      {^parent, ^ref, :next} ->
        send(parent, {self(), ref, :event, facade.(Loopex, :next_event, [attachment])})
        event_loop(parent, ref, attachment, facade)
    end
  end

  defp read_input(%{stopping: false, barrier: nil, pending: nil, input_worker: nil} = state),
    do:
      spawn_owned(state, :input, fn parent, ref ->
        send(parent, {self(), ref, :input, ChatInput.read(state.input)})
      end)

  defp read_input(state), do: state

  defp input_result(state, :empty), do: read_input(state)
  defp input_result(state, :eof), do: begin_stop(state)

  defp input_result(state, {:error, code})
       when code in [:invalid_chat_command, :invalid_chat_answer, :invalid_configure_json] do
    state = %{state | sequence: state.sequence + 1}

    state
    |> acknowledge(:crypto.strong_rand_bytes(24), :refused, code)
    |> error(code)
    |> local_refusal()
  end

  defp input_result(state, {:error, code}), do: stop_input(state, code)

  defp input_result(state, {:ok, action}) do
    state = %{state | sequence: state.sequence + 1}
    id = :crypto.strong_rand_bytes(24)

    case action do
      :status ->
        state = acknowledge(state, id, :admitted, :accepted)
        send_worker(state, :command, {:inspect_status})
        %{state | pending: :inspect_status}

      :wait ->
        state = acknowledge(state, id, :admitted, :accepted)
        ask_status(%{state | barrier: state.sequence})

      :quit ->
        begin_stop(acknowledge(state, id, :admitted, :accepted))

      :abort ->
        admit(state, %{type: :abort, command_id: id})

      :compact ->
        # Concept: display the fixed reference bounds before submitting compact.
        # Technical depth: the output owner charges the active write until its
        # joined write. One captured output ceiling gates submission;
        # input and event grants stay paused without another owner or receipt.
        cutoff = System.monotonic_time(:millisecond) + 5_000
        cutoff = if state.output_deadline, do: min(cutoff, state.output_deadline), else: cutoff

        state =
          write_text(
            state,
            "Compaction bounds: max_attempts=4, deadline_ms=60000, token_budget=32768"
          )

        if state.stopping do
          state
        else
          command = %{
            type: :compact,
            command_id: id,
            bounds: %{"max_attempts" => 4, "deadline_ms" => 60_000, "token_budget" => 32_768}
          }

          schedule(%{state | pending: {:compact_display, command, cutoff}})
        end

      {:configure, changes} ->
        send_worker(
          state,
          :command,
          {:configure, %{type: :configure, command_id: id, changes: changes}}
        )

        %{state | pending: {:admission, id}}

      {type, content} when type in [:prompt, :steer, :follow_up] ->
        command = %{type: type, content: content, command_id: id}

        command =
          if type == :prompt and state.default_bounds != nil,
            do: Map.put(command, :bounds, state.default_bounds),
            else: command

        admit(state, command)

      {:answer, interaction, answer} ->
        admit(state, %{
          type: :interaction_answer,
          command_id: id,
          interaction_id: interaction,
          answer: answer
        })

      _ ->
        state
        |> acknowledge(id, :refused, :chat_action_unavailable)
        |> error(:chat_action_unavailable)
        |> local_refusal()
    end
  end

  defp retain_display_deadline(
         %{pending: {:compact_display, command, captured}} = state,
         deadline
       )
       when is_integer(deadline),
       do: %{state | pending: {:compact_display, command, min(captured, deadline)}}

  defp retain_display_deadline(state, _deadline), do: state

  defp poll_compact_display(%{pending: {:compact_display, command, cutoff}} = state) do
    remaining = cutoff - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      fail(state, :output_drain_timeout)
    else
      # Concept: inspect the same output owner without renewing its deadline.
      # Technical depth: status is the owner's non-blocking counter view; the
      # captured cutoff above, not a fresh default wait, bounds this display.
      case Output.status(state.output) do
        %{bytes: 0, failure: nil} ->
          if not state.stopping and System.monotonic_time(:millisecond) < cutoff do
            # Concept: already queued cancellation wins before compact submission.
            # Technical depth: the self message follows the successful IO/join
            # observation, so an interrupt skipped by the synchronous status
            # receive is handled before this final original-cutoff gate.
            send(self(), {:compact_displayed, command.command_id, cutoff})
            state
          else
            fail(state, :output_drain_timeout)
          end

        %{failure: nil} ->
          schedule(state)

        %{failure: code} ->
          fail(state, code)

        _ ->
          fail(state, :output_failed)
      end
    end
  catch
    :exit, _ -> fail(state, :output_failed)
  end

  defp admit(state, command) do
    send_worker(state, :command, {:command, command})
    %{state | pending: {:admission, command.command_id}}
  end

  defp ask_status(%{reaping: true} = state), do: state

  defp ask_status(%{pending: nil} = state) do
    send_worker(state, :command, {:status})
    %{state | pending: :status}
  end

  defp ask_status(state), do: state

  defp command_reply(%{reaping: true} = state, _), do: state

  defp command_reply(
         %{pending: :startup_status} = state,
         {:ok, %{compact_pending: busy} = status}
       )
       when is_boolean(busy) do
    if state.cleanup_grace_ms != nil and state.cleanup_grace_ms != status.cleanup_grace_ms do
      state
      |> Map.put(:pending, nil)
      |> Map.put(:transport, :chat_cleanup_grace_mismatch)
      |> unknown_cleanup()
      |> reap()
      |> maybe_finished()
    else
      state = %{
        state
        | pending: nil,
          status: status,
          cleanup_grace_ms: status.cleanup_grace_ms,
          startup: :ready
      }

      cond do
        state.stopping ->
          state |> abort_for_stop() |> grant_event()

        state.prepare_from != nil ->
          GenServer.reply(state.prepare_from, {:ok, status})
          %{state | prepare_from: nil}

        true ->
          state |> read_input() |> grant_event()
      end
    end
  end

  defp command_reply(%{pending: :startup_status} = state, _),
    do:
      state
      |> Map.put(:transport, :session_unavailable)
      |> unknown_cleanup()
      |> reap()
      |> maybe_finished()

  defp command_reply(%{pending: {:shutdown, id}} = state, {:accepted, id}),
    do: %{state | pending: nil} |> consume_event() |> ask_status()

  defp command_reply(%{pending: {:shutdown, id}} = state, {:error, code})
       when code == :commit_unknown or (is_tuple(code) and elem(code, 0) == :commit_unknown),
       do: %{state | pending: nil, unresolved: id} |> observe()

  defp command_reply(%{pending: {:shutdown, _}} = state, {:error, _}),
    do: %{state | pending: nil} |> consume_event() |> ask_status()

  defp command_reply(%{pending: {:admission, id}} = state, {:accepted, id}) do
    state = acknowledge(%{state | pending: nil}, id, :admitted, :accepted)
    state |> consume_event() |> after_command()
  end

  defp command_reply(%{pending: {:admission, id}} = state, {:error, code})
       when code == :commit_unknown or (is_tuple(code) and elem(code, 0) == :commit_unknown) do
    state =
      acknowledge(
        %{state | pending: nil, unresolved: id, exit_code: max(state.exit_code, 1)},
        id,
        :unknown,
        :commit_unknown
      )

    state |> begin_stop() |> observe()
  end

  defp command_reply(%{pending: {:admission, id}} = state, {:error, code}) do
    state =
      state
      |> Map.put(:pending, nil)
      |> Map.update!(:compact_commands, &MapSet.delete(&1, id))
      |> acknowledge(id, :refused, stable_code(code))
      |> error(stable_code(code))

    state |> consume_event() |> local_refusal()
  end

  defp command_reply(%{pending: :status} = state, {:ok, %{compact_pending: busy} = status})
       when is_boolean(busy) do
    state = %{state | pending: nil, status: status}
    state = consume_event(state)
    check_barrier(state)
  end

  defp command_reply(%{pending: :inspect_status} = state, {:ok, %{event_sequence: tail} = fields})
       when is_integer(tail) and tail >= state.cursor do
    # Concept: last compact and status share one committed public prefix.
    # Technical depth: keep input blocked until the existing reader reaches the
    # native status cursor. No new reader or live private result fills the view.
    state = %{state | pending: {:inspect_tail, Map.delete(fields, :event_sequence), tail}}
    state |> finish_inspection() |> consume_inspection_event()
  end

  defp command_reply(%{pending: :inspect_status} = state, _) do
    state |> Map.put(:pending, nil) |> error(:chat_status_unavailable) |> local_refusal()
  end

  defp command_reply(%{pending: :observe} = state, {:ok, {:committed, :admitted, _, _}}),
    do: %{state | pending: nil, unresolved: nil} |> abort_for_stop()

  defp command_reply(%{pending: :observe} = state, {:ok, {:committed, :refused, code, _}}),
    do: %{state | pending: nil, unresolved: nil} |> error(stable_code(code)) |> abort_for_stop()

  defp command_reply(%{pending: :observe} = state, {:ok, {:not_committed, _, _, _}}),
    do:
      %{state | pending: nil, unresolved: nil}
      |> error(:admission_not_committed)
      |> abort_for_stop()

  defp command_reply(%{pending: :observe} = state, _), do: schedule(%{state | pending: nil})

  defp command_reply(state, _), do: fail(%{state | pending: nil}, :session_unavailable)

  defp local_refusal(%{mode: :interactive, stopping: false} = state), do: read_input(state)
  defp local_refusal(state), do: begin_stop(%{state | exit_code: max(state.exit_code, 1)})

  defp after_command(%{stopping: true} = state), do: ask_status(state)
  defp after_command(state), do: read_input(state)

  defp consume_event(%{reaping: true} = state), do: state

  defp consume_event(%{waiting_event: nil} = state), do: state

  defp consume_event(%{waiting_event: {:error, :empty}} = state),
    do: schedule(%{state | waiting_event: nil})

  defp consume_event(
         %{pending: {:inspect_tail, _, tail}, waiting_event: {:ok, %{event_sequence: seq}}} =
           state
       )
       when seq > tail,
       do: fail(%{state | pending: nil, waiting_event: nil}, :chat_status_unavailable)

  defp consume_event(%{waiting_event: {:ok, %{event_sequence: seq} = event}} = state)
       when is_integer(seq) and seq > state.cursor do
    state = release_held(%{state | waiting_event: nil, cursor: seq})

    # Concept: an answer waits for the next durable event before it is shown.
    # Technical depth: Core offers the stream closure after committing the
    # answer and before its next durable event, so by then the output owner's
    # native sink holds it. No timer decides that disposition.
    state =
      if event.kind == "assistant.message_appended" do
        %{state | held_assistant: event}
      else
        state = project_event(state, event)
        _ = Output.advance(state.output, seq)
        state
      end

    # Concept: input or output failure still requires observing cancellation truth.
    # Technical depth: reader grants continue until the existing barrier/reap join;
    # the captured shutdown cutoff remains the bound on unavailable truth.
    state |> finish_inspection() |> grant_event()
  end

  defp consume_event(state), do: fail(%{state | waiting_event: nil}, :event_reader_failed)

  # Concept: a durable answer is shown unless its streamed copy already was.
  # Technical depth: the output owner suppresses it only for the exact complete
  # domain whose every quoted fragment joined; otherwise this full quoted
  # fallback is written.
  defp release_held(%{held_assistant: nil} = state), do: state

  defp release_held(%{held_assistant: %{"content" => text} = event} = state) do
    state = %{state | held_assistant: nil}

    with {:ok, rendered} <- Render.chat_text(text),
         :ok <- Output.assistant(state.output, event.event_sequence, text, rendered),
         do: state,
         else: ({:error, code} -> fail(state, code))
  end

  defp project_event(state, %{"run_id" => run, kind: "run.started"}),
    do: %{state | known_run: run}

  defp project_event(state, %{kind: "interaction.requested"} = event) do
    producer = if event["producer"] == "model_tool", do: :model_tool, else: :policy_defer
    kind = if event["interaction_kind"] == "text", do: :text, else: :choice
    choices = Enum.map(event["choices"], &%{id: &1["id"], label: &1["label"]})

    checked_emit(state, :question, %{
      session_id: state.session,
      run_id: event["run_id"],
      interaction_id: event["interaction_id"],
      producer: producer,
      kind: kind,
      question: event["prompt"],
      choices: choices,
      expires_at_ms: event["expires_at"]
    })
  end

  defp project_event(state, %{kind: "run.finished"} = event) do
    outcome = @outcomes[event["outcome"]]
    details = Map.take(event, Map.get(@details, outcome, []))

    details =
      if outcome == :failed,
        do: details |> Map.put_new("reason", nil) |> Map.put_new("failure", nil),
        else: details

    terminal = %{outcome: outcome, details: details}

    case Outcome.encode_wire(terminal) do
      {:ok, _} ->
        code = if outcome == :completed, do: state.exit_code, else: max(state.exit_code, 1)

        %{
          state
          | last_run: event["run_id"],
            known_run: event["run_id"],
            last_outcome: terminal,
            exit_code: code
        }

      _ ->
        fail(state, :invalid_terminal_event)
    end
  end

  defp project_event(state, %{kind: "context.compaction_finished"} = event) do
    completion = Map.drop(event, [:kind, :event_id, :event_sequence])

    case CompactResult.encode_completion(completion) do
      {:ok, encoded} ->
        # Concept: a past compact failure is history, not this invocation's failure.
        # Technical depth: retain only unsettled locally submitted identities and
        # retire each on refusal/completion; replay never fabricates a run outcome.
        owned = MapSet.member?(state.compact_commands, completion["command_id"])

        state = %{
          state
          | compact_commands: MapSet.delete(state.compact_commands, completion["command_id"]),
            last_compact: %{
              episode_id: completion["episode_id"],
              command_id: completion["command_id"],
              result: completion["result"]
            }
        }

        state =
          if owned and completion["result"]["disposition"] == "failed",
            do: %{state | exit_code: max(state.exit_code, 1)},
            else: state

        write_text(state, "Compaction result: " <> IO.iodata_to_binary(:json.encode(encoded)))

      _ ->
        fail(state, :invalid_terminal_event)
    end
  end

  defp project_event(state, _), do: state

  defp write_text(state, text) do
    with {:ok, rendered} <- Render.chat_text(text),
         :ok <- Output.write(state.output, :text, :stdout, rendered),
         do: state,
         else: ({:error, code} -> fail(state, code))
  end

  defp finish_inspection(%{pending: {:inspect_tail, fields, tail}, cursor: cursor} = state)
       when cursor == tail do
    fields = put_in(fields, [:maintenance, :last_compact], state.last_compact)

    state
    |> Map.put(:pending, nil)
    |> checked_emit(
      :status,
      Map.merge(fields, %{input_sequence: state.sequence, session_id: state.session})
    )
    |> after_command()
  end

  defp finish_inspection(state), do: state

  defp consume_inspection_event(%{pending: {:inspect_tail, _, _}} = state),
    do: state |> consume_event() |> grant_event()

  defp consume_inspection_event(%{pending: nil} = state),
    do: state |> consume_event() |> grant_event()

  defp consume_inspection_event(state), do: state

  defp grant_event(%{reaping: true} = state), do: state

  defp grant_event(%{pending: :inspect_status} = state), do: state
  defp grant_event(%{pending: {:compact_display, _, _}} = state), do: state

  defp grant_event(
         %{reader: pid, waiting_event: nil, reader_busy: false, finished: false} = state
       )
       when is_pid(pid) do
    send_worker(state, :reader, {:next})
    %{state | reader_busy: true}
  end

  defp grant_event(state), do: state

  defp check_barrier(%{unresolved: id} = state) when is_binary(id), do: observe(state)

  # Concept: an interrupt retains its abort intent while a status read is pending.
  # Technical depth: submit it once when the command worker becomes available,
  # after uncertainty resolution and before waiting for terminal evidence.
  defp check_barrier(
         %{stopping: true, reaping: false, stop_abort_sent: false, pending: nil} = state
       ),
       do: abort_for_stop(state)

  defp check_barrier(%{status: %{event_sequence: tail}} = state) when state.cursor < tail,
    do: grant_event(state)

  defp check_barrier(
         %{
           last_outcome: %{outcome: :outcome_unknown},
           status: %{active_run_id: nil, compact_pending: false}
         } = state
       ) do
    state = barrier_record(state, :uncertain, nil, state.last_run, state.last_outcome)
    state |> Map.put(:exit_code, max(state.exit_code, 1)) |> reap() |> maybe_finished()
  end

  # Concept: standalone compact work owns the session before an episode exists.
  # Technical depth: only definitive same-owner status can prove its slot clear;
  # the public tail alone cannot reveal pre-episode admission. Drain that tail
  # before checking the committed compact, run, follow-up and interaction facts.
  defp check_barrier(
         %{
           status: %{
             active_run_id: nil,
             compact_pending: false,
             pending_work_ids: [],
             open_interaction: nil
           },
           barrier: barrier
         } = state
       )
       when barrier != nil do
    state = barrier_record(state, :settled, nil, state.last_run, state.last_outcome)

    if state.stopping,
      do: state |> reap() |> maybe_finished(),
      else: read_input(%{state | barrier: nil, status: nil})
  end

  defp check_barrier(%{status: %{open_interaction: interaction}, stopping: false} = state)
       when is_map(interaction) do
    state =
      barrier_record(
        state,
        :question,
        interaction["interaction_id"],
        state.status.active_run_id,
        nil
      )

    read_input(%{state | barrier: nil, status: nil})
  end

  defp check_barrier(state), do: schedule(state)

  defp begin_stop(%{pending: {:compact_display, _, cutoff}} = state) do
    # Concept: cancellation before display has no compact command to resolve.
    # Technical depth: retain the already selected ceiling in ordinary shutdown;
    # clearing this local wait neither submits a command nor renews delivery time.
    deadline = if state.output_deadline, do: min(cutoff, state.output_deadline), else: cutoff
    begin_stop(%{state | pending: nil, output_deadline: deadline})
  end

  defp begin_stop(%{stopping: true} = state), do: state

  defp begin_stop(state) do
    state = capture_stop_deadline(state)
    if state.pending == nil and state.unresolved == nil, do: abort_for_stop(state), else: state
  end

  # Concept: startup refusal and ordinary cancellation share one join budget.
  # Technical depth: this helper captures only local lifetime mechanics. The
  # ordinary stop path separately submits its runtime abort; startup reaps.
  defp capture_stop_deadline(%{stopping: true} = state), do: state

  defp capture_stop_deadline(state) do
    grace = state.cleanup_grace_ms || Loopex.Executor.default_cleanup_grace_ms()

    {:ok, bounds} = Loopex.Executor.cancellation_bounds(grace)
    now = System.monotonic_time(:millisecond)
    deadline = now + bounds.cli_backstop_ms
    deadline = if state.output_deadline, do: min(deadline, state.output_deadline), else: deadline
    cutoff_timer = Process.send_after(self(), :cutoff, max(deadline - now, 0))

    state = %{
      state
      | stopping: true,
        deadline: deadline,
        cutoff_timer: cutoff_timer,
        barrier: max(state.sequence, 1)
    }

    if state.input_worker, do: Process.exit(state.input_worker, :kill)
    state
  end

  # Concept: a late output-owner notification may shorten an active shutdown.
  # Technical depth: queue admission and this owner's mailbox are independent.
  # Preserve the minimum once stopping starts, even when output later drains
  # or provisional unknown cleanup already returned. Closing shares that cutoff;
  # only an unfinished shutdown needs its timer rearmed.
  defp shorten_stop(%{stopping: true, deadline: captured} = state, deadline)
       when is_integer(captured) and is_integer(deadline) and deadline < captured do
    if state.finished do
      %{state | deadline: deadline}
    else
      if state.cutoff_timer, do: Process.cancel_timer(state.cutoff_timer)
      remaining = max(deadline - System.monotonic_time(:millisecond), 0)
      timer = Process.send_after(self(), :cutoff, remaining)
      %{state | deadline: deadline, cutoff_timer: timer}
    end
  end

  defp shorten_stop(state, _deadline), do: state

  defp abort_for_stop(%{stop_abort_sent: true} = state), do: ask_status(state)

  defp abort_for_stop(state) do
    if MapSet.member?(state.ready, :command) do
      id = :crypto.strong_rand_bytes(24)
      state = admit(state, %{type: :abort, command_id: id})
      %{state | pending: {:shutdown, id}, stop_abort_sent: true}
    else
      state |> unknown_cleanup() |> reap() |> maybe_finished()
    end
  end

  defp observe(%{pending: nil, unresolved: id} = state) when is_binary(id) do
    send_worker(state, :command, {:observe, id})
    %{state | pending: :observe}
  end

  defp observe(state), do: state

  defp unknown_cleanup(%{pending: {:admission, id}} = state) do
    state = acknowledge(%{state | pending: nil, unresolved: id}, id, :unknown, :commit_unknown)
    unknown_cleanup(state)
  end

  defp unknown_cleanup(%{pending: {:shutdown, id}} = state),
    do: unknown_cleanup(%{state | pending: nil, unresolved: id})

  defp unknown_cleanup(state) do
    outcome = if state.unresolved, do: :commit_unknown, else: :cleanup_unknown

    state =
      barrier_record(
        state,
        :uncertain,
        nil,
        state.known_run,
        outcome
      )

    %{state | exit_code: max(state.exit_code, 1), local_cleanup: :unknown, give_up: true}
  end

  defp reap(state) do
    Enum.each(state.workers, fn {pid, _} -> Process.exit(pid, :kill) end)
    %{state | stopping: true, reaping: true, pending: nil}
  end

  defp maybe_finished(%{stopping: true, workers: workers, finished: false} = state)
       when (map_size(workers) == 0 or state.give_up) and
              (state.from != nil or state.prepare_from != nil) do
    if state.cutoff_timer, do: Process.cancel_timer(state.cutoff_timer)
    state = seal_progress_state(state)

    result = %{
      exit_code: state.exit_code,
      last_outcome: state.last_outcome,
      cleanup: state.local_cleanup,
      transport: state.transport
    }

    if state.from, do: GenServer.reply(state.from, result)
    if state.prepare_from, do: GenServer.reply(state.prepare_from, {:error, result})

    %{state | finished: true, from: nil, prepare_from: nil}
  end

  defp maybe_finished(state), do: state

  defp seal_progress_state(%{progress_sealed: true} = state), do: state

  defp seal_progress_state(state) do
    case Output.seal_progress(state.output) do
      dropped when is_integer(dropped) ->
        %{state | progress_sealed: true, progress_dropped: dropped}

      _ ->
        %{state | progress_sealed: true, progress_dropped: nil}
    end
  end

  defp join_reply(%{closed: true, workers: workers} = state) when map_size(workers) == 0,
    do: {:stop, :normal, state}

  defp join_reply(state), do: {:noreply, state}

  defp stop_input(state, code), do: state |> error(code) |> fail(code)

  defp fail(state, code),
    do: begin_stop(%{state | transport: code, exit_code: max(state.exit_code, 1)})

  defp acknowledge(state, id, disposition, code),
    do:
      checked_emit(state, :input, %{
        input_sequence: state.sequence,
        command_id: id,
        disposition: disposition,
        code: code
      })

  defp error(state, code),
    do:
      checked_emit(state, :error, %{
        input_sequence: if(state.sequence > 0, do: state.sequence),
        code: code
      })

  defp barrier_record(%{sequence: 0} = state, _, _, _, _), do: state

  defp barrier_record(state, kind, interaction, run, outcome),
    do:
      checked_emit(state, :wait, %{
        input_sequence: state.barrier,
        state: kind,
        session_id: state.session,
        run_id: run,
        interaction_id: interaction,
        command_id: if(outcome == :commit_unknown, do: state.unresolved),
        outcome: outcome
      })

  defp checked_emit(state, event, fields) do
    case emit(state, event, fields) do
      :ok -> state
      {:error, code} -> fail(state, code)
    end
  end

  defp emit(state, event, fields) do
    with {:ok, bytes} <- ChatControl.encode(event, fields),
         do: Output.write(state.output, :control, :stdout, bytes)
  end

  defp finish_output(state) do
    if state.deadline,
      do: Output.finish(state.output, state.deadline),
      else: Output.finish(state.output)
  end

  defp stable_code(code) when is_atom(code), do: code
  defp stable_code(_), do: :admission_failed

  defp schedule(%{timer: nil} = state),
    do: %{state | timer: Process.send_after(self(), :poll, 10)}

  defp schedule(state), do: state

  defp send_worker(state, kind, operation) do
    pid = Map.fetch!(state, kind)
    ref = state.workers[pid].ref
    send(pid, List.to_tuple([self(), ref | Tuple.to_list(operation)]))
  end
end
