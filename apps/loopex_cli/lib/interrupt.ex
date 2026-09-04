defmodule LoopexCli.Interrupt do
  @moduledoc """
  ## Concept

  Turns an interrupt signal delivered to a running `loopex` process into the
  same public abort any other caller would submit, and then lets the run report
  what actually happened before the process goes. Nothing about stopping a run is
  private to this command: it signals no process, writes no control file, and
  opens no channel of its own.

  ## Technical depth

  `SIGINT` is not among the signals this installs on and cannot be: the emulator
  reserves it for its own break handler and `os:set_signal/2` refuses the name
  outright. That is a fact about `os:set_signal/2` and about this module. It is
  not a fact about what `Ctrl-C` does, and stating it as one described the
  command as unable to keep a promise it does keep.

  `Ctrl-C` reaches this handler, by the only route a reserved signal can be
  reached by: from outside the emulator. `apps/loopex_cli/bin/loopex` is the
  `loopex` an operator runs. It starts the escript as its own child, traps
  `SIGINT`, and forwards `SIGTERM` — which is a signal this module does install
  on, and which it turns into the same public abort as any other. So an
  interrupt at the terminal ends the run through the ordinary cancellation path
  and reports what happened, rather than ending the operating-system process
  where it stands.

  A build run directly, without that launcher, keeps the older behaviour: the
  emulator ends on `Ctrl-C` and nothing here observes it. That is why
  `loopex cancel` exists and why it is not merely a convenience. The session's
  durable truth is in the journal rather than in this process, so an abruptly
  ended terminal leaves a session that is recoverable rather than one that is
  lost, and `loopex cancel <session>` reaches the same public abort by a third
  route. What is lost in that case is the chance to observe cleanup before the
  process goes, which is exactly why the reconciling path reports
  `outcome_unknown` when it cannot confirm one.

  Installing a handler is not enough by itself. The runtime's default signal
  handler stops the emulator on `SIGTERM` immediately, which would race the abort
  this submits and end the process before the run could commit what it observed.
  This command owns its own operating-system process, so it takes that decision
  over: the default handler is removed and termination becomes this module's
  responsibility.

  Owning termination means owning the case where cleanup never finishes. A
  backstop halts the process after a grace period, and it watches the terminal
  that installed it so that a terminal which exited normally is never halted
  after the fact.
  """

  @behaviour :gen_event

  # Concept: the signals an operator or a supervisor actually sends.
  #
  # Technical depth: `SIGTERM` is what `kill` sends by default, what a process
  # supervisor sends on shutdown, and what `bin/loopex` forwards a terminal
  # `Ctrl-C` as; `SIGHUP` is what a closing terminal sends to its foreground
  # group; `SIGQUIT` is the other keyboard interrupt. Each is trappable and each
  # means the same thing here: stop this run and report what happened.
  @signals [:sigterm, :sighup, :sigquit]

  # Concept: how long a stop is allowed to take before the process goes anyway.
  #
  # Technical depth: a terminal that never exits after an interrupt is worse than
  # one that exits without a full report, because an operator who sent a signal
  # and saw nothing has no remaining move. The grace is generous enough for an
  # executor to confirm a cleaned process tree and short enough to stay a
  # terminal rather than a daemon.
  @grace_ms 10_000

  # Concept: what a second interrupt is told, and what the process says when the
  # stop ran out of time.
  #
  # Technical depth: both lines are facts about this process, not claims about
  # the session. Neither names a terminal outcome: the durable answer is in the
  # state root, and `loopex cancel <session>` is what settles it.
  @still_stopping "loopex: still stopping; this run exits when it has reported " <>
                    "or the stop period ends"

  @backstop_note "loopex: stopping did not finish in time; this run's own command " <>
                   "processes were killed"

  @doc """
  ## Concept

  Installs the interrupt handler for one attachment.

  ## Technical depth

  Returns `:ok` even where the platform refuses a signal, because a terminal that
  cannot install a handler should still run the task; the operator's recourse is
  then `loopex cancel`, which needs nothing from this process. The caller is
  recorded as the terminal so the backstop can tell a stalled stop from a
  finished one.
  """
  @spec install(Loopex.Attachment.t()) :: :ok
  def install(attachment), do: do_install(attachment, @grace_ms, nil)

  @doc """
  ## Concept

  Installs the handler under the cleanup period the session actually committed,
  so the backstop that ends this process is sized by the operator's own number
  rather than by a fixed one this module chose.

  ## Technical depth

  ADR 0016 derives every cancellation observation bound from the committed
  cleanup period, and `Loopex.Executor.cancellation_bounds/1` is where that
  formula lives. The command supplies the period it recovered from the session
  and takes `cli_backstop_ms` from there, so a session configured to spend a
  long time stopping is not halted while its executor is still inside the period
  it was promised. A period outside the admitted domain leaves this module's own
  grace in place rather than refusing to install: a terminal that cannot size its
  backstop correctly should still be able to stop its run.
  """
  @spec install(Loopex.Attachment.t(), pos_integer()) :: :ok
  def install(attachment, cleanup_grace_ms),
    do: do_install(attachment, backstop_ms(cleanup_grace_ms), nil)

  @doc """
  ## Concept

  Installs the configured handler and, in the same step, tells it about a
  prepared owner whose recovered work has not started. An interrupt arriving
  before the terminal has decided anything then stops the session rather than
  racing a decision to continue it.

  ## Technical depth

  ADR 0016 makes installation and the prepared handoff one serialized step, and
  this is that step: the handler is installed carrying the activation, so there
  is no instant in which a signal reaches a handler that does not know a
  prepared owner is waiting. What the handler does with it is refuse it. On a
  signal it submits the ordinary public abort, and an admitted abort is what
  permanently invalidates activation, so recovered work cannot start behind the
  operator's back.

  The capability itself stays where preparation put it, with the process that
  prepared the owner, because only that process may spend or abandon it. That is
  what makes a preparer which died before this step unable to leave an
  activatable owner behind, and it is also this implementation's exact
  divergence from ADR 0016's wording: the handoff transfers the responsibility
  for giving the capability up, not the authority to spend it.
  """
  @spec install_prepared(Loopex.Attachment.t(), pos_integer(), term()) :: :ok
  def install_prepared(attachment, cleanup_grace_ms, activation),
    do: do_install(attachment, backstop_ms(cleanup_grace_ms), activation)

  @doc """
  ## Concept

  Gives up the prepared owner's capability from the terminal that holds it, and
  forgets it here, so nothing this handler does later re-presents something the
  operator has already given up.

  ## Technical depth

  The handler is asked first, and it answers only for the exact activation
  installed with it, so this entry cannot be used to give up a capability that
  never crossed this boundary. The abandonment itself then runs in the caller's
  own process, which is the holder: `Loopex` admits abandonment only from the
  process that prepared the owner, so routing it through the signal server would
  present the wrong process and be refused — and would block signal delivery on
  a session call while doing it.
  """
  @spec abandon_resume(Loopex.Attachment.t(), term()) :: :ok | {:error, term()}
  def abandon_resume(_attachment, activation) do
    case forget_prepared(activation) do
      :ok -> Loopex.abandon_resume(activation)
      {:error, reason} -> {:error, reason}
    end
  end

  defp forget_prepared(activation) do
    :gen_event.call(:erl_signal_server, __MODULE__, {:forget_prepared, activation})
  catch
    :exit, _no_handler -> {:error, :prepared_activation_not_installed}
  end

  defp do_install(attachment, grace_ms, activation) do
    Enum.each(@signals, fn signal ->
      try do
        :os.set_signal(signal, :handle)
      rescue
        _unsupported -> :ok
      end
    end)

    remove_handlers(:erl_signal_handler)
    remove_handlers(__MODULE__)

    _ =
      :gen_event.add_handler(:erl_signal_server, __MODULE__, %{
        attachment: attachment,
        terminal: self(),
        grace_ms: grace_ms,
        activation: activation
      })

    :ok
  end

  # Concept: taking over termination means leaving nothing behind that can still
  # end the process on its own.
  #
  # Technical depth: `:gen_event` identifies a handler by module and admits the
  # same module more than once, so one deletion removes one instance and any
  # others keep receiving every signal. A single surviving default handler is
  # enough to stop the emulator before the abort this module submits can commit
  # what it observed, which is exactly the race installation exists to remove.
  # Removal therefore repeats while the module is still listed, bounded so a
  # manager that refuses deletion cannot spin here.
  @max_handler_instances 16

  defp remove_handlers(module, attempts \\ @max_handler_instances)
  defp remove_handlers(_module, 0), do: :ok

  defp remove_handlers(module, attempts) do
    if module in :gen_event.which_handlers(:erl_signal_server) do
      _ = :gen_event.delete_handler(:erl_signal_server, module, [])
      remove_handlers(module, attempts - 1)
    else
      :ok
    end
  end

  defp backstop_ms(cleanup_grace_ms) do
    case Loopex.Executor.cancellation_bounds(cleanup_grace_ms) do
      {:ok, %{cli_backstop_ms: backstop}} -> backstop
      {:error, _outside_the_admitted_domain} -> @grace_ms
    end
  end

  @doc """
  ## Concept

  The signals this command installs on.

  ## Technical depth

  Named rather than inlined so a case can state which signals are covered without
  restating the list and drifting from it.
  """
  @spec signals() :: [atom()]
  def signals, do: @signals

  @doc """
  ## Concept

  How long an interrupted stop is allowed to take.

  ## Technical depth

  Exposed for the same reason as `signals/0`.
  """
  @spec grace_ms() :: pos_integer()
  def grace_ms, do: @grace_ms

  @impl :gen_event
  def init(state) when is_map(state),
    do: {:ok, Map.merge(%{abort: nil, backstop: nil}, state)}

  def init(state), do: {:ok, state}

  # Concept: however many interrupts arrive, one stop is submitted, under one
  # identity, and the process is given one bounded chance to finish it.
  #
  # Technical depth: the submission happens in a separate process because this
  # callback runs inside the signal server, and blocking here would stall
  # delivery of every later signal — including the second interrupt an operator
  # sends when the first appears to have done nothing. That separation is also
  # what makes joining possible: while a submission is still in flight, a further
  # signal is the same stop arriving again, so it neither starts a second
  # admission nor takes a second identity. The backstop is armed here, before the
  # possibly blocking admission call rather than after it, because an admission
  # that never returns is exactly the case the backstop exists for.
  #
  # A further signal is answered rather than absorbed in silence. An operator who
  # interrupts a second time has been told nothing by the first, and silence is
  # what makes them keep signalling a process that is already stopping. The
  # notice is written from a separate process because this callback runs inside
  # the signal server: a write to a stderr nobody is draining would otherwise
  # stall delivery of every later signal, which is the same reason the admission
  # itself is not performed here.
  @impl :gen_event
  def handle_event(signal, state) when signal in @signals do
    if joining?(state) do
      _ = spawn(fn -> IO.puts(:stderr, @still_stopping) end)
      {:ok, state}
    else
      {:ok, submit_abort(state)}
    end
  end

  def handle_event({signal, _pid}, state) when signal in @signals,
    do: handle_event(signal, state)

  def handle_event(_other, state), do: {:ok, state}

  @impl :gen_event
  def handle_call({:forget_prepared, activation}, %{activation: activation} = state),
    do: {:ok, :ok, %{state | activation: nil}}

  def handle_call({:forget_prepared, _other}, state),
    do: {:ok, {:error, :prepared_activation_not_installed}, state}

  def handle_call(_request, state), do: {:ok, :ok, state}

  # Concept: what the submission proved, and what the process may do next.
  #
  # Technical depth: acceptance freezes the identity and buys the post-admission
  # window once. A proved refusal or a submission that could not commit rotates
  # instead, but only once the submitting process is gone, so a later signal
  # cannot overlap a live admission with a fresh one. An answer this handler
  # cannot classify is never treated as a refusal: an unknown result leaves the
  # identity frozen and the backstop armed, because a timeout is not a verdict
  # about whether the abort committed.
  @impl :gen_event
  def handle_info({:loopex_interrupt_result, command_id, result}, state) do
    case state.abort do
      %{command_id: ^command_id} = abort ->
        {:ok, resolve_abort(state, abort, result)}

      _other ->
        {:ok, state}
    end
  end

  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state) do
    case state.abort do
      %{monitor: ^monitor, accepted: false} ->
        disarm(state.backstop)
        {:ok, %{state | abort: nil, backstop: nil}}

      %{monitor: ^monitor} = abort ->
        {:ok, %{state | abort: %{abort | monitor: nil}}}

      _other ->
        {:ok, state}
    end
  end

  def handle_info(_message, state), do: {:ok, state}

  defp joining?(%{abort: %{}}), do: true
  defp joining?(_state), do: false

  defp submit_abort(%{attachment: attachment, terminal: terminal, grace_ms: grace_ms} = state) do
    # An interrupt identifier is the durable name of one abort, and
    # `System.unique_integer/1` restarts with the virtual machine, so a second
    # terminal reissued `interrupt-1` for a different abort against the same
    # session. One hundred twenty-eight random bits name it across processes,
    # as `unique_id/0` in `LoopexCli` does for every other command. It is drawn
    # once per abort and then carried in state, which is what lets the reply
    # this manager matches name the command it actually submitted.
    command_id = "interrupt-" <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
    backstop = state.backstop || spawn(fn -> backstop(terminal, grace_ms) end)
    manager = self()

    worker =
      spawn(fn ->
        result = Loopex.command(attachment, %{type: :abort, command_id: command_id})
        send(manager, {:loopex_interrupt_result, command_id, result})
      end)

    monitor = Process.monitor(worker)

    %{
      state
      | backstop: backstop,
        abort: %{command_id: command_id, monitor: monitor, accepted: nil}
    }
  end

  defp resolve_abort(state, abort, {:accepted, _command_id}) do
    extend(state.backstop, state.grace_ms)
    %{state | abort: %{abort | accepted: true}}
  end

  defp resolve_abort(state, abort, {:error, reason}) when is_atom(reason),
    do: %{state | abort: %{abort | accepted: false}}

  defp resolve_abort(state, abort, _unclassified),
    do: %{state | abort: %{abort | accepted: true}}

  defp extend(backstop, extension) when is_pid(backstop),
    do: send(backstop, {:loopex_interrupt_extend, extension})

  defp extend(_backstop, _extension), do: :ok

  defp disarm(backstop) when is_pid(backstop), do: send(backstop, :loopex_interrupt_disarm)
  defp disarm(_backstop), do: :ok

  # Concept: give the stop a bounded chance to finish, then go.
  #
  # Technical depth: watching the terminal rather than sleeping blindly is what
  # keeps this from halting a process that already reported and moved on. The
  # deadline is one monotonic instant waited out in safe slices, so an admitted
  # cleanup period larger than a single timer's range is honoured rather than
  # silently truncated, and no slice refreshes the allowance. Acceptance extends
  # it exactly once, to whichever is later of the deadline already running and a
  # full post-acceptance window; a replayed acceptance cannot extend it again.
  # 130 is the conventional status for a command ended by a signal.
  @slice_ms 60_000

  defp backstop(terminal, grace_ms) do
    reference = Process.monitor(terminal)
    wait_out(reference, System.monotonic_time(:millisecond) + grace_ms, false)
  end

  defp wait_out(reference, deadline, extended) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      halt_owning_nothing()
    else
      receive do
        {:DOWN, ^reference, :process, _pid, _reason} ->
          :ok

        :loopex_interrupt_disarm ->
          :ok

        {:loopex_interrupt_extend, extension} when not extended ->
          extended_deadline = System.monotonic_time(:millisecond) + extension
          wait_out(reference, max(deadline, extended_deadline), true)

        _replay ->
          wait_out(reference, deadline, extended)
      after
        min(remaining, @slice_ms) -> wait_out(reference, deadline, extended)
      end
    end
  end

  # Concept: the backstop ends this process, and it must not end it standing on
  # top of the work it was asked to stop.
  #
  # Technical depth: `System.halt/1` ends the emulator through `:erlang.halt`,
  # which closes no port and runs nothing afterwards, so every operating-system
  # process the emulator started outlives it — reparented to the init process
  # with nobody's name on it. The backstop only fires where cleanup did not
  # finish, which is exactly when such a process is still there, so halting alone
  # turned a stop that ran out of time into an abandoned child. Closing the ports
  # first would not do it either: that reaches the direct child and not the
  # descendants it forked, which is the whole reason the executor signals a group
  # rather than a leader.
  #
  # The emulator gives each spawned port its child's identifier, and that child
  # is the leader of a process group of its own — the same ownership the local
  # executor's own termination rests on — so the negated identifier names the
  # group and ends the descendants with it. `KILL`, because the cooperative
  # period is precisely what has just run out. This claims nothing about the
  # session: the run reported no terminal, and the note says so rather than
  # calling it a cancellation.
  #
  # How long the killed groups are waited on before halting anyway, and how often
  # they are looked at, are `@release_ms` and `@release_poll_ms` below.
  @release_ms 500
  @release_poll_ms 25

  defp halt_owning_nothing do
    groups = owned_groups()
    Enum.each(groups, &kill_group/1)
    await_release(groups, System.monotonic_time(:millisecond) + @release_ms)
    IO.puts(:stderr, @backstop_note)
    System.halt(130)
  end

  # Concept: halt once the children are actually gone, not the instant they were
  # signalled.
  #
  # Technical depth: the emulator learns that a spawned child has ended through
  # its own helper process, and halting in the middle of that hand-off leaves the
  # helper writing to a pipe nobody reads any more, which it reports on the
  # operator's terminal in place of the answer this backstop is trying to give.
  # A port whose child is gone stops being listed, so the groups just killed are
  # waited out until none of them is a port child. Bounded, because a child that
  # will not die is not a reason to keep alive a process that has already run out
  # of time.
  defp await_release(groups, deadline) do
    still = Enum.filter(groups, &(&1 in owned_groups()))

    if still == [] or System.monotonic_time(:millisecond) >= deadline do
      :ok
    else
      Process.sleep(@release_poll_ms)
      await_release(still, deadline)
    end
  end

  defp owned_groups do
    for port <- Port.list(),
        {:os_pid, os_pid} <- [Port.info(port, :os_pid)],
        is_integer(os_pid) and os_pid > 1,
        do: os_pid
  end

  # A signal this process cannot send is not a reason to keep running: the note
  # and the status still have to reach the operator, so a missing or refusing
  # `kill` leaves the halt itself intact.
  @kill_ms 2_000

  defp kill_group(group) do
    port =
      Port.open({:spawn_executable, "/bin/kill"}, [
        :binary,
        :exit_status,
        :hide,
        args: ["-KILL", "--", "-#{group}"]
      ])

    receive do
      {^port, {:exit_status, _status}} -> :ok
    after
      @kill_ms -> :ok
    end
  rescue
    _no_kill_program -> :ok
  end
end
