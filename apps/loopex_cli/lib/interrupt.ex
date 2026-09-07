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

  @observation_ms 1_000
  @manager_claim {__MODULE__, :installed}

  @doc """
  ## Concept

  Installs the interrupt handler for one attachment.

  ## Technical depth

  Returns `:ok` even where the platform refuses a signal or the emulator has no
  signal server to hold a handler, because a terminal that cannot install a
  handler should still run the task; the operator's recourse is then
  `loopex cancel`, which needs nothing from this process. The caller is
  recorded as the terminal so the backstop can tell a stalled stop from a
  finished one. `install_prepared/3` cannot make that trade, because a prepared
  owner's capability has nowhere to go without a handler, and it reports the
  refusal instead.
  """
  @spec install(Loopex.Attachment.t()) :: :ok
  def install(attachment) do
    _ = do_install(attachment, @grace_ms, nil, nil)
    :ok
  end

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
  def install(attachment, cleanup_grace_ms) do
    _ = do_install(attachment, backstop_ms(cleanup_grace_ms), nil, nil)
    :ok
  end

  @doc """
  ## Concept

  Installs the configured handler and, in the same step, tells it about a
  prepared owner whose recovered work has not started. An interrupt arriving
  before the terminal has decided anything then stops the session rather than
  racing a decision to continue it.

  ## Technical depth

  ADR 0016 makes installation and the prepared handoff one serialized step, and
  this is that step. The handler is installed carrying the activation first, so
  there is no instant in which a signal reaches a handler that does not know a
  prepared owner is waiting; the capability is then handed to a process started
  here for that single purpose — the handler's holder. The owner sends its
  transfer verdict to this installer, which forwards it to the manager-lifetime
  guard. The guard acknowledges the forwarded verdict to the owner; only then
  does the owner record the holder and return the public answer.

  The holder is a process of its own rather than the signal server, because the
  signal server is the one process in this emulator that must never be blocked.
  Presenting the capability blocks its presenter for the length of a session
  call, and by this point `do_install/4` has already removed the emulator's own
  `SIGTERM` handler: a blocked signal server is a process no interrupt can stop,
  because no signal would be handled, no abort submitted, and no backstop armed,
  leaving `SIGKILL` and exactly the orphaned process group the backstop exists
  to prevent. The holder blocks instead, and `handle_event/2` keeps submitting
  the abort and arming the backstop as it does for an ordinary run.

  Separating them costs no serialization, because the serialization ADR 0016
  requires was never this process's to provide. An admitted abort fences the
  capability at the owner before its Store transaction, so an activation that
  reaches the owner after it is refused as `:resume_activation_fenced`, and one
  that reaches the owner first spends a capability the abort then finds spent.
  Exactly one of the two decides what the session did, and the owner is the
  single serial writer that decides which — an answer that holds even across a
  presenting process that dies, which one shared blocking process could not give.

  A temporary one-way guard ties the holder to the installer, so it cannot
  survive a death before the exact signal manager is guarded, the handler is
  installed, and the session owner's committed verdict reaches the guard, while
  a holder killed by manager loss cannot kill the public installer in return.
  The manager guard is armed before installation makes the holder reachable.
  Receipt of the installer-forwarded verdict ends the temporary installer
  lifetime before the guard acknowledges the owner, so installer death after
  that point cannot undo the handoff even if the public reply is lost. Installer
  death before forwarding still fails closed, while abrupt manager loss cannot
  strand a holder. Each manager atomically admits one initial installation;
  duplicates return `interrupt_already_installed` and preserve its holder, abort
  identity and backstop. Orderly removal releases only that handler's holder
  asynchronously. Ending a holder cannot retract a presentation already received
  by the owner or stop session work whose activation succeeded.

  The handoff's own result is what this returns. A handoff the owner refuses —
  most often because a signal beat it and the abort already fenced the
  capability, or because this process is not the holder it would have to be —
  releases the unacknowledged holder, clears it from the interrupt handler, and
  names the owner's refusal. The handler remains live to carry an abort already
  in flight or accept a later signal, but advertises no holder the owner refused.
  An unresolved handoff is returned unchanged. Its cleanup relationship stays
  active and recovered work stays fenced; callers must report uncertainty and
  cannot activate or retry installation as though no transfer happened.
  """
  @spec install_prepared(Loopex.Attachment.t(), pos_integer(), term()) ::
          :ok | {:error, term()} | {:unresolved, atom()}
  def install_prepared(attachment, cleanup_grace_ms, activation) do
    with {:ok, holder_lifetime} <- prepare_holder(activation) do
      holder = holder_lifetime.holder

      case do_install(attachment, backstop_ms(cleanup_grace_ms), activation, holder_lifetime) do
        {:ok, _signal_server} ->
          :ok

        {:error, reason} ->
          release(holder)
          {:error, reason}

        {:unresolved, _reason} = unresolved ->
          unresolved
      end
    end
  end

  # Concept: a not-yet-installed holder belongs to its installer and disappears
  # with it.
  #
  # Technical depth: the lifetime guard monitors the installer before it creates
  # the holder. The holder stays linked to the guard so even guard loss while a
  # presentation blocks ends that owned holder immediately. The guard traps
  # exits and monitors the holder; no link reaches the public caller. Thus no
  # capability-bearing process exists in a spawn-before-guard interval and no
  # holder failure can propagate an exit into the public installer. The holder also
  # monitors this exact guard, so concurrent loss of the manager guard and
  # session owner cannot leave it orphaned. It exists until the session owner and
  # guard acknowledge the prepared capability transfer together.
  defp prepare_holder(activation) do
    installer = self()
    nonce = make_ref()
    ready = make_ref()

    {guard, guard_monitor} =
      spawn_monitor(fn -> guard_pending_holder(installer, activation, nonce, ready) end)

    receive do
      {^ready, ^guard, holder} when is_pid(holder) ->
        Process.demonitor(guard_monitor, [:flush])
        {:ok, %{holder: holder, lifetime_guard: guard, transfer_nonce: nonce}}

      {:DOWN, ^guard_monitor, :process, ^guard, reason} ->
        {:error, {:prepared_holder_installer_guard_failed, reason}}
    end
  end

  defp guard_pending_holder(installer, activation, nonce, ready) do
    Process.flag(:trap_exit, true)
    installer_ref = Process.monitor(installer)
    {holder, holder_ref} = :erlang.spawn_opt(fn -> hold(activation) end, [:link, :monitor])
    holder_ready = make_ref()
    send(holder, {:loopex_prepared_holder_guard, self(), holder_ready})

    receive do
      {^holder_ready, ^holder} ->
        send(installer, {ready, self(), holder})

        guard_uninstalled_holder(holder, holder_ref, installer, installer_ref, nonce)

      {:DOWN, ^installer_ref, :process, ^installer, _reason} ->
        Process.exit(holder, :kill)

      {:DOWN, ^holder_ref, :process, ^holder, _reason} ->
        :ok
    end
  end

  defp guard_uninstalled_holder(holder, holder_ref, installer, installer_ref, nonce) do
    receive do
      {:loopex_prepared_manager_arm, ^installer, signal_server, tag}
      when is_pid(signal_server) ->
        signal_server_ref = Process.monitor(signal_server)
        send(installer, {tag, self()})

        guard_armed_holder(
          holder,
          holder_ref,
          installer,
          installer_ref,
          signal_server,
          signal_server_ref,
          nonce
        )

      {:DOWN, ^installer_ref, :process, ^installer, _reason} ->
        Process.exit(holder, :kill)

      {:DOWN, ^holder_ref, :process, ^holder, _reason} ->
        :ok
    end
  end

  defp guard_armed_holder(
         holder,
         holder_ref,
         installer,
         installer_ref,
         signal_server,
         signal_server_ref,
         nonce
       ) do
    receive do
      {:loopex_prepared_transfer_pending, ^installer, coordinator, ^holder, ^nonce, handoff}
      when is_pid(coordinator) and is_reference(handoff) ->
        coordinator_ref = Process.monitor(coordinator)

        guard_pending_owner_prepare(
          holder,
          holder_ref,
          installer,
          installer_ref,
          signal_server,
          signal_server_ref,
          coordinator,
          coordinator_ref,
          nonce,
          handoff
        )

      {:DOWN, ^installer_ref, :process, ^installer, _reason} ->
        Process.exit(holder, :kill)

      {:DOWN, ^signal_server_ref, :process, ^signal_server, _reason} ->
        Process.exit(holder, :kill)

      {:DOWN, ^holder_ref, :process, ^holder, _reason} ->
        :ok
    end
  end

  defp guard_pending_owner_prepare(
         holder,
         holder_ref,
         installer,
         installer_ref,
         signal_server,
         signal_server_ref,
         coordinator,
         coordinator_ref,
         nonce,
         handoff
       ) do
    receive do
      {:loopex_prepared_owner_discard, ^coordinator, ^holder, ^nonce, ^handoff} ->
        Process.exit(holder, :kill)

      {:loopex_prepared_owner_prepare, ^coordinator, ^holder, ^nonce, ^handoff, prepare}
      when is_reference(prepare) ->
        send(
          coordinator,
          {:loopex_prepared_transfer_guard_ready, self(), holder, nonce, handoff, prepare}
        )

        guard_pending_owner_verdict(
          holder,
          holder_ref,
          installer,
          installer_ref,
          signal_server,
          signal_server_ref,
          coordinator,
          coordinator_ref,
          nonce,
          handoff
        )

      {:DOWN, ^installer_ref, :process, ^installer, _reason} when is_reference(installer_ref) ->
        send(
          coordinator,
          {:loopex_prepared_transfer_installer_lost, self(), installer, holder, nonce, handoff}
        )

        Process.exit(holder, :kill)

      {:DOWN, ^signal_server_ref, :process, ^signal_server, _reason} ->
        Process.exit(holder, :kill)

      {:DOWN, ^coordinator_ref, :process, ^coordinator, _reason} ->
        Process.exit(holder, :kill)

      {:DOWN, ^holder_ref, :process, ^holder, _reason} ->
        :ok
    end
  end

  defp guard_pending_owner_verdict(
         holder,
         holder_ref,
         installer,
         installer_ref,
         signal_server,
         signal_server_ref,
         coordinator,
         coordinator_ref,
         nonce,
         handoff
       ) do
    receive do
      {:loopex_prepared_owner_discard, ^coordinator, ^holder, ^nonce, ^handoff} ->
        Process.exit(holder, :kill)

      {:loopex_prepared_owner_verdict, ^coordinator, ^holder, ^nonce, ^handoff, commit,
       :committed}
      when is_reference(commit) ->
        if installer_ref, do: Process.demonitor(installer_ref, [:flush])

        send(
          coordinator,
          {:loopex_prepared_owner_verdict_ack, self(), holder, nonce, handoff, commit, :committed}
        )

        guard_installed_holder(
          holder,
          holder_ref,
          signal_server,
          signal_server_ref,
          coordinator,
          coordinator_ref,
          nonce,
          handoff
        )

      {:loopex_prepared_owner_verdict, ^coordinator, ^holder, ^nonce, ^handoff, commit,
       {:refused, reason} = verdict}
      when is_reference(commit) and is_atom(reason) ->
        Process.exit(holder, :kill)

        send(
          coordinator,
          {:loopex_prepared_owner_verdict_ack, self(), holder, nonce, handoff, commit, verdict}
        )

        :ok

      {:DOWN, ^installer_ref, :process, ^installer, _reason} when is_reference(installer_ref) ->
        send(
          coordinator,
          {:loopex_prepared_transfer_installer_lost, self(), installer, holder, nonce, handoff}
        )

        Process.exit(holder, :kill)

      {:DOWN, ^signal_server_ref, :process, ^signal_server, _reason} ->
        Process.exit(holder, :kill)

      {:DOWN, ^coordinator_ref, :process, ^coordinator, _reason} ->
        Process.exit(holder, :kill)

      {:DOWN, ^holder_ref, :process, ^holder, _reason} ->
        :ok
    end
  end

  defp guard_installed_holder(
         holder,
         holder_ref,
         signal_server,
         signal_server_ref,
         coordinator,
         coordinator_ref,
         nonce,
         handoff
       ) do
    receive do
      {:loopex_prepared_guard_released, ^coordinator} ->
        :ok

      {:loopex_prepared_owner_discard, ^coordinator, ^holder, ^nonce, ^handoff} ->
        Process.exit(holder, :kill)

      {:DOWN, ^signal_server_ref, :process, ^signal_server, _reason} ->
        Process.exit(holder, :kill)

      {:DOWN, ^coordinator_ref, :process, ^coordinator, _reason} ->
        Process.exit(holder, :kill)

      {:DOWN, ^holder_ref, :process, ^holder, _reason} ->
        :ok
    end
  end

  # Concept: the process that holds the capability and presents it to the owner.
  #
  # Technical depth: before accepting presentations it monitors the exact
  # one-way lifetime guard that created it and acknowledges that relationship to
  # the installer. The guard already monitors the holder. Either participant's
  # loss therefore ends the other side of the transient authority even if the
  # session owner disappears at the same instant. The holder then does one thing,
  # so there is nothing it can be blocked by except the presentation it was asked
  # to make. It carries the activation rather than accepting one per request, so
  # the only capability it can ever present is the one the handoff moved to it.
  # It answers every presentation and keeps holding: one-use is the owner's own
  # state machine to enforce, and forgetting after a refusal would leave a caller
  # no way to give up something the owner still records as prepared.
  defp hold(activation) do
    receive do
      {:loopex_prepared_holder_guard, guard, tag}
      when is_pid(guard) and is_reference(tag) ->
        guard_ref = Process.monitor(guard)
        send(guard, {tag, self()})
        hold(activation, guard, guard_ref)

      :loopex_prepared_release ->
        :ok
    end
  end

  defp hold(activation, guard, guard_ref) do
    receive do
      {:loopex_prepared_presentation, caller, tag, request} ->
        send(caller, {tag, present(request, activation)})
        hold(activation, guard, guard_ref)

      :loopex_prepared_release ->
        :ok

      {:DOWN, ^guard_ref, :process, ^guard, _reason} ->
        :ok
    end
  end

  # Concept: the holder cannot outlive the process responsible for it, before or
  # after installation.
  #
  # Technical depth: before the handler is made visible, the pending lifetime
  # guard begins monitoring the exact signal manager selected inside the
  # serialized installation. Manager loss kills the holder; holder loss ends the
  # guard. Only receipt of the installer-forwarded committed verdict releases
  # the installer monitor; the guard then acknowledges the owner, which records
  # and monitors the holder and permanently abandons a capability that is still
  # prepared when it goes.
  defp arm_holder(nil, _signal_server), do: :ok

  defp arm_holder(%{holder: holder, lifetime_guard: guard}, signal_server)
       when is_pid(holder) and is_pid(guard) and is_pid(signal_server) do
    tag = Process.monitor(guard)
    send(guard, {:loopex_prepared_manager_arm, self(), signal_server, tag})

    receive do
      {^tag, ^guard} ->
        Process.demonitor(tag, [:flush])
        :ok

      {:DOWN, ^tag, :process, ^guard, reason} ->
        {:error, {:prepared_holder_guard_failed, reason}}
    end
  end

  defp complete_prepared_handoff(nil, _activation, _signal_server), do: :ok

  defp complete_prepared_handoff(holder_lifetime, activation, signal_server),
    do: complete_live_prepared_handoff(holder_lifetime, activation, signal_server)

  defp complete_live_prepared_handoff(
         %{holder: holder, lifetime_guard: guard, transfer_nonce: nonce},
         activation,
         signal_server
       )
       when is_pid(holder) and is_pid(signal_server) do
    result = Loopex.transfer_resume(activation, holder, {guard, nonce})

    if match?({:error, _reason}, result) do
      discard_failed_prepared_holder(signal_server, activation, holder)
    end

    result
  end

  defp discard_failed_prepared_holder(signal_server, activation, holder) do
    :gen_event.call(
      signal_server,
      __MODULE__,
      {:discard_failed_prepared_holder, activation, holder},
      :infinity
    )
  catch
    :exit, _manager_gone -> :ok
  end

  defp present(:activate, activation),
    do: presentation_result(Loopex.activate_resume(activation))

  defp present(:abandon, activation),
    do: presentation_result(Loopex.abandon_resume(activation))

  # Concept: losing the coordinator while presenting cannot prove that the
  # submitted mutation was refused.
  # Technical depth: Core's compatibility entry reports unavailable when its
  # call loses the owner. The holder may relay that answer before its independent
  # guardian sees the same loss; both orders remain unresolved at this boundary.
  defp presentation_result({:error, :session_unavailable}),
    do: {:unresolved, :prepared_activation_unavailable}

  defp presentation_result(result), do: result

  # Concept: asking the holder, with no deadline of this module's invention.
  #
  # Technical depth: the monitor reference is the reply tag, so a reply can only
  # be matched to the request that asked for it and a holder that goes is
  # observed rather than waited out. There is no timeout because there is no
  # honest one: the message that carries a presentation is not withdrawn when its
  # caller stops waiting, so an expiring wait would report a refusal while the
  # owner went on to spend the very capability the caller was told it had not
  # spent. A holder that dies without answering is reported as exactly that and
  # never as a verdict about the capability, because the owner may have answered
  # the presentation before the holder went.
  defp ask(holder, request) do
    tag = Process.monitor(holder)
    send(holder, {:loopex_prepared_presentation, self(), tag, request})

    receive do
      {^tag, reply} ->
        Process.demonitor(tag, [:flush])
        reply

      {:DOWN, ^tag, :process, ^holder, _reason} ->
        {:unresolved, :prepared_activation_holder_lost}
    end
  end

  # Concept: the holder stops when it can no longer be asked for anything.
  #
  # Technical depth: a message rather than an exit signal, so a holder that is
  # inside a presentation finishes answering it first. Killing it there would
  # abandon a call the owner may already have decided, which is the one thing a
  # one-use capability may never do. The owner monitors an acknowledged holder,
  # so this is also what abandons a still-prepared capability when the handler
  # goes: fail closed, decided by the owner rather than announced from here.
  defp release(holder) when is_pid(holder) do
    send(holder, :loopex_prepared_release)
    :ok
  end

  @doc """
  ## Concept

  Starts the prepared owner's recovered work, from the process that holds the
  capability, so an interrupt arriving at the same moment cannot start it twice
  or start it behind an abort.

  ## Technical depth

  The handler names the holder for exactly the activation installed with it, so
  this entry cannot present a capability that never crossed this boundary, and
  the holder presents the one it was handed. The read-only manager lookup is
  bounded and reports unavailable on expiry. The presentation itself waits for
  an exact decision without a deadline: its message cannot be withdrawn by a
  timeout. Holder or coordinator loss while presenting is unresolved, never
  failed activation. A missing coordinator reply reports
  `{:unresolved, :prepared_activation_unavailable}`; the bounded read-only lookup
  instead returns `{:error, :prepared_activation_unavailable}` before submitting
  this presentation.
  The owner's fence decides ordering with a signal.

  One use is the owner's own state machine to enforce, and it does: success or a
  refusal as spent, abandoned, or fenced settles the capability and releases the
  holder after that exact answer has crossed it. A refusal that settles nothing
  keeps the holder, which leaves a caller able to try again or give the
  capability up instead of turning an unavailable owner into permanent loss.
  """
  @spec activate_prepared(term()) :: {:ok, binary()} | {:error, term()} | {:unresolved, atom()}
  def activate_prepared(activation) do
    case holder(activation) do
      {:ok, holder} ->
        reply = ask(holder, :activate)
        if settled_prepared_reply?(reply), do: release(holder)
        reply

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  ## Concept

  Gives up the prepared owner's capability from the process that holds it, so
  nothing this handler does later re-presents something the operator has already
  given up.

  ## Technical depth

  Abandonment travels the same route as activation and for the same reason: the
  handoff made the holder the only process whose abandonment the owner admits.
  A holder whose abandonment the owner accepted has nothing left to present, so
  it is released rather than left running; the owner has already recorded the
  answer, and its monitor of a holder that is now gone changes nothing it has
  not already decided.
  """
  @spec abandon_prepared(term()) :: :ok | {:error, term()} | {:unresolved, atom()}
  def abandon_prepared(activation) do
    with {:ok, holder} <- holder(activation) do
      reply = ask(holder, :abandon)
      if settled_prepared_reply?(reply), do: release(holder)
      reply
    end
  end

  defp settled_prepared_reply?({:ok, _session_id}), do: true
  defp settled_prepared_reply?(:ok), do: true

  defp settled_prepared_reply?({:error, reason})
       when reason in [
              :resume_activation_spent,
              :resume_activation_abandoned,
              :resume_activation_fenced
            ],
       do: true

  defp settled_prepared_reply?(_unsettled), do: false

  @doc """
  ## Concept

  ADR 0016's additive entry for giving a prepared capability up, kept at the
  shape the decision names.

  ## Technical depth

  The attachment is the one the handler was installed with and carries no
  authority of its own; the capability is what the owner checks, and it is
  presented from its holder exactly as `abandon_prepared/1` presents it. The
  entry exists so that the accepted decision's named surface stays true rather
  than being retired by a changelog line.
  """
  @spec abandon_resume(Loopex.Attachment.t(), term()) ::
          :ok | {:error, term()} | {:unresolved, atom()}
  def abandon_resume(_attachment, activation), do: abandon_prepared(activation)

  # Concept: which process holds this exact capability now.
  #
  # Technical depth: the handler answers from its manager's own process, and the
  # answer is a lookup rather than a session call, so the signal server is never
  # held for longer than it takes to read one map. A suspended live manager is
  # unavailable after the bounded observation; that is not proof of absence or
  # of a mutation's result. Every definitive absence -- no handler of this
  # module, a handler carrying a different activation, a handler that crashed --
  # comes back as a value and reads as nothing installed for this capability.
  defp holder(activation) do
    request = {:prepared_holder, activation}

    case :gen_event.call(:erl_signal_server, __MODULE__, request, @observation_ms) do
      {:ok, holder} when is_pid(holder) -> {:ok, holder}
      _absent -> {:error, :prepared_activation_not_installed}
    end
  catch
    :exit, _unavailable -> {:error, :prepared_activation_unavailable}
  end

  defp do_install(attachment, grace_ms, activation, holder_lifetime) do
    case Process.whereis(:erl_signal_server) do
      manager when is_pid(manager) ->
        install_on(manager, attachment, grace_ms, activation, holder_lifetime)

      nil ->
        {:error, :prepared_activation_not_installed}
    end
  end

  # Concept: installation claims one handler in the exact manager that owns
  # signal delivery. Concurrent candidates cannot replace the incumbent.
  #
  # Technical depth: init/1 performs the claim in the manager's serialized turn.
  # The default handler is swapped during initial installation so signal
  # coverage remains continuous. A stale handler snapshot cannot grant a second
  # claim. Session calls and participant waits occur only in the installer.
  defp install_on(manager, attachment, grace_ms, activation, holder_lifetime) do
    state = %{
      attachment: attachment,
      terminal: self(),
      grace_ms: grace_ms,
      activation: activation,
      holder: prepared_holder(holder_lifetime)
    }

    with :ok <- arm_holder(holder_lifetime, manager),
         {:ok, handlers} <- observe_handlers(manager),
         :ok <- install_handler(manager, handlers, state) do
      Enum.each(@signals, fn signal ->
        try do
          :os.set_signal(signal, :handle)
        rescue
          _unsupported -> :ok
        end
      end)

      remove_default_handlers(manager)

      case complete_prepared_handoff(holder_lifetime, activation, manager) do
        :ok -> {:ok, manager}
        result -> result
      end
    end
  catch
    :exit, _lost_mutation_result -> {:unresolved, :resume_handoff_unresolved}
  end

  defp prepared_holder(nil), do: nil
  defp prepared_holder(%{holder: holder}) when is_pid(holder), do: holder

  defp install_handler(manager, handlers, state) do
    if :erl_signal_handler in handlers do
      # OTP wraps an init refusal once more on swap than on add. Both paths
      # expose the same atomic-claim refusal, including a stale default snapshot.
      case :gen_event.swap_handler(
             manager,
             {:erl_signal_handler, :loopex_handler_installed},
             {__MODULE__, state}
           ) do
        {:error, {:error, :interrupt_already_installed}} ->
          {:error, :interrupt_already_installed}

        result ->
          result
      end
    else
      :gen_event.add_handler(manager, __MODULE__, state)
    end
  end

  # which_handlers/1 has no timeout argument. Its owned observation worker
  # bounds only this read; no installation or session mutation runs there.
  defp observe_handlers(manager) do
    observer = self()
    tag = make_ref()

    {worker, monitor} =
      :erlang.spawn_opt(
        fn ->
          result =
            try do
              {:ok, :gen_event.which_handlers(manager)}
            catch
              :exit, _manager_lost -> {:error, :prepared_activation_unavailable}
            end

          send(observer, {tag, result})
        end,
        [:link, :monitor]
      )

    receive do
      {^tag, result} ->
        Process.unlink(worker)
        Process.demonitor(monitor, [:flush])
        result

      {:DOWN, ^monitor, :process, ^worker, _reason} ->
        {:error, :prepared_activation_unavailable}
    after
      @observation_ms ->
        Process.unlink(worker)
        Process.exit(worker, :kill)

        receive do
          {:DOWN, ^monitor, :process, ^worker, _reason} -> :ok
        end

        receive do
          {^tag, _late_observation} -> :ok
        after
          0 -> :ok
        end

        {:error, :prepared_activation_unavailable}
    end
  end

  defp remove_default_handlers(manager) do
    case :gen_event.delete_handler(manager, :erl_signal_handler, []) do
      {:error, :module_not_found} -> :ok
      _removed -> remove_default_handlers(manager)
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
  def init({state, _previous}) when is_map(state), do: init(state)

  def init(state) when is_map(state) do
    case Process.get(@manager_claim) do
      nil ->
        claim = make_ref()
        Process.put(@manager_claim, claim)

        {:ok,
         %{abort: nil, backstop: nil, activation: nil, holder: nil}
         |> Map.merge(state)
         |> Map.put(:claim, claim)}

      _incumbent ->
        {:error, :interrupt_already_installed}
    end
  end

  # Concept: orderly removal retires only this installation and releases its
  # holder without blocking delivery of other signals.
  #
  # Technical depth: the matching claim lives only in the manager. Abrupt
  # manager loss destroys it and is independently observed by the participant.
  @impl :gen_event
  def terminate(_reason, state) when is_map(state) do
    if Map.get(state, :claim) == Process.get(@manager_claim),
      do: Process.delete(@manager_claim)

    case Map.get(state, :holder) do
      holder when is_pid(holder) -> release(holder)
      _none -> :ok
    end
  end

  def terminate(_reason, _state), do: :ok

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
  # Creation and monitoring are atomic so even an immediate refusal cannot end
  # before the handler owns the DOWN signal that retires its backstop.
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

  # Concept: the handler says who holds the capability; it never presents it.
  #
  # Technical depth: this callback runs inside the signal server, so whatever it
  # does is time during which no signal is handled, no abort is submitted, and no
  # backstop is armed -- and by installation time the emulator's own `SIGTERM`
  # handler is gone, so that interval is one in which nothing short of `SIGKILL`
  # can stop this process. Presenting the capability from here blocked it for the
  # length of a session call, which is the interval the abort exists to fit
  # inside. Answering a map lookup is bounded by nothing outside this process.
  #
  # The activation is compared rather than trusted, so the holder named is the
  # holder of exactly the capability that crossed this boundary and no other. The
  # answer is a pid the caller then asks directly; a caller that has one and
  # presents it is presenting the owner's own acknowledged holder, and a caller
  # that never had one gets no route to the capability at all.
  @impl :gen_event
  def handle_call(
        {:prepared_holder, activation},
        %{activation: activation, holder: holder} = state
      )
      when not is_nil(activation) and is_pid(holder),
      do: {:ok, {:ok, holder}, state}

  def handle_call({:prepared_holder, _other}, state),
    do: {:ok, {:error, :prepared_activation_not_installed}, state}

  # Concept: a failed owner handoff leaves the interrupt path live but advertises
  # no process as a capability holder.
  #
  # Technical depth: the exact activation and holder pair prevents a stale
  # installer from clearing a replacement. The abort and backstop fields remain
  # untouched, because a signal may have fenced the capability and begun the
  # stop that caused the transfer refusal.
  def handle_call(
        {:discard_failed_prepared_holder, activation, holder},
        %{activation: activation, holder: holder} = state
      )
      when not is_nil(activation) and is_pid(holder),
      do: {:ok, :ok, %{state | activation: nil, holder: nil}}

  def handle_call({:discard_failed_prepared_holder, _activation, _holder}, state),
    do: {:ok, :ok, state}

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

    {_worker, monitor} =
      spawn_monitor(fn ->
        result = Loopex.command(attachment, %{type: :abort, command_id: command_id})
        send(manager, {:loopex_interrupt_result, command_id, result})
      end)

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
