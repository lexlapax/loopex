defmodule LoopexCli.Interrupt do
  @moduledoc """
  ## Concept

  Turns an interrupt signal delivered to a running `loopex` process into the
  same public abort any other caller would submit, and then lets the run report
  what actually happened before the process goes. Nothing about stopping a run is
  private to this command: it signals no process, writes no control file, and
  opens no channel of its own.

  ## Technical depth

  `SIGINT` is not among the signals this installs on and cannot be made to be.
  The emulator reserves it for its own break handler and `os:set_signal/2`
  refuses the name outright, so a terminal `Ctrl-C` ends the operating-system
  process without reaching this code at all.

  That is a smaller loss than it sounds, and it is the reason `loopex cancel`
  exists. The session's durable truth is in the journal, not in this process, so
  an abruptly ended terminal leaves a session that is recoverable rather than one
  that is lost, and `loopex cancel <session>` reaches the same public abort by a
  different route. What is genuinely lost is the chance to observe cleanup before
  the process goes, which is exactly why the reconciling path reports
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
  # Technical depth: `SIGTERM` is what `kill` sends by default and what a process
  # supervisor sends on shutdown; `SIGHUP` is what a closing terminal sends to its
  # foreground group; `SIGQUIT` is the other keyboard interrupt. Each is trappable
  # and each means the same thing here: stop this run and report what happened.
  @signals [:sigterm, :sighup, :sigquit]

  # Concept: how long a stop is allowed to take before the process goes anyway.
  #
  # Technical depth: a terminal that never exits after an interrupt is worse than
  # one that exits without a full report, because an operator who sent a signal
  # and saw nothing has no remaining move. The grace is generous enough for an
  # executor to confirm a cleaned process tree and short enough to stay a
  # terminal rather than a daemon.
  @grace_ms 10_000

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
  def install(attachment) do
    Enum.each(@signals, fn signal ->
      try do
        :os.set_signal(signal, :handle)
      rescue
        _unsupported -> :ok
      end
    end)

    _ = :gen_event.delete_handler(:erl_signal_server, :erl_signal_handler, [])
    _ = :gen_event.add_handler(:erl_signal_server, __MODULE__, {attachment, self()})
    :ok
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
  def init(state), do: {:ok, state}

  # Concept: a signal becomes an ordinary public abort.
  #
  # Technical depth: the work happens in a separate process because this callback
  # runs inside the signal server, and blocking there would stall delivery of
  # every later signal — including the second interrupt an operator sends when the
  # first appears to have done nothing.
  @impl :gen_event
  def handle_event(signal, {attachment, terminal} = state) when signal in @signals do
    spawn(fn ->
      Loopex.command(attachment, %{
        type: :abort,
        command_id: "interrupt-" <> Integer.to_string(System.unique_integer([:positive]))
      })
    end)

    spawn(fn -> backstop(terminal) end)
    {:ok, state}
  end

  def handle_event({signal, _pid}, state) when signal in @signals,
    do: handle_event(signal, state)

  def handle_event(_other, state), do: {:ok, state}

  @impl :gen_event
  def handle_call(_request, state), do: {:ok, :ok, state}

  @impl :gen_event
  def handle_info(_message, state), do: {:ok, state}

  # Concept: give the stop a bounded chance to finish, then go.
  #
  # Technical depth: watching the terminal rather than sleeping blindly is what
  # keeps this from halting a process that already reported and moved on. 130 is
  # the conventional status for a command ended by a signal.
  defp backstop(terminal) do
    reference = Process.monitor(terminal)

    receive do
      {:DOWN, ^reference, :process, _pid, _reason} -> :ok
    after
      @grace_ms -> System.halt(130)
    end
  end
end
