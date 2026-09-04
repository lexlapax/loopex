defmodule LoopexCli do
  @moduledoc """
  ## Concept

  `loopex` — the command an operator actually runs. They stand in a Git
  repository, describe a change in ordinary words, and watch the session read
  files, edit them, and run commands until the work is done. The answer arrives
  as it is produced. An interrupt stops the work and reports what actually
  happened. Tomorrow, `loopex sessions` finds it again and `loopex resume`
  continues it.

  It is a peer surface, not the product. Every flow it offers is a projection of
  the same embedded API an embedder calls: it owns no loop, no durable session
  truth, no cursor truth, no Store access, and no authority decision. If this
  command disappeared, everything it does would still be reachable.

  ## Technical depth

  The command drives only the public `Loopex` facade and the one composition
  entry point. Beyond those it names only the host policy modules an operator may
  select with `--policy`, which is the host's own decision and the one decision
  the shipped composition deliberately refuses to make for anybody.

  Argument parsing and terminal output use the standard library only. A
  dependency here would land in the operator's install for the sake of flag
  parsing, which is not a trade this milestone makes.

  Steering and follow-up have separate flags rather than one input the command
  interprets. The runtime never guesses which of the two an input is, so the
  surface must not guess either: an input naming neither is refused rather than
  resolved from the state of the session.
  """

  alias LoopexCli.Policy.AllowAll
  alias LoopexCli.Policy.ShellAllowlist
  alias LoopexCli.Interrupt
  alias LoopexCli.Placement
  alias LoopexCli.ProjectResources
  alias LoopexCli.Render

  @doc """
  ## Concept

  The escript entry point.

  ## Technical depth

  Dispatches on the first argument and prints usage for anything it does not
  recognise, rather than guessing. Exit status is explicit so a shell script
  wrapping this command can tell success from failure.
  """
  @spec main([binary()]) :: no_return()
  def main(argv) do
    result = dispatch(argv)
    release_placement()
    halt(result)
  end

  @doc """
  ## Concept

  Runs one command and returns its result, without exiting.

  ## Technical depth

  Separated from `main/1` so the locked cases exercise the real command surface
  rather than a rehearsal of it. A case that had to spawn an operating-system
  process to observe a flag would be testing the escript wrapper, not the
  behaviour the outcome names.
  """
  @spec dispatch([binary()]) :: :ok | {:error, binary()}
  def dispatch(argv), do: dispatch(argv, [])

  @doc false
  @spec dispatch([binary()], keyword()) :: :ok | {:error, binary()}
  def dispatch(["run" | rest], options), do: admitted("run", rest, &run(&1, options))
  def dispatch(["sessions" | rest], _options), do: admitted("sessions", rest, &sessions/1)
  def dispatch(["resume" | rest], options), do: admitted("resume", rest, &resume(&1, options))
  def dispatch(["cancel" | rest], options), do: admitted("cancel", rest, &cancel(&1, options))
  def dispatch(["artifact" | rest], _options), do: admitted("artifact", rest, &artifact/1)

  def dispatch([], _options),
    do: {:error, "choose one command: run, sessions, resume, cancel, or artifact\n\n" <> usage()}

  def dispatch([unknown | _rest], _options),
    do: {:error, "unknown command #{unknown}\n\n" <> usage()}

  @command_flags %{
    "run" =>
      ~w(policy state-root workspace steer follow-up cleanup-grace-ms context-token-budget),
    "sessions" => ~w(state-root),
    "resume" => ~w(policy state-root workspace cleanup-grace-ms context-token-budget),
    "cancel" => ~w(policy state-root workspace cleanup-grace-ms context-token-budget),
    "artifact" => ~w(state-root)
  }

  # Concept: input naming nothing this command offers is refused, whichever
  # subcommand it was typed after.
  #
  # Technical depth: the check was reached only from `run`, so `loopex sessions
  # --nudge x` dropped the flag silently -- which is the failure the refusal
  # exists to prevent, surviving in four of the five subcommands. Refusing at
  # dispatch means a subcommand added later inherits it rather than having to
  # remember it.
  defp admitted(name, arguments, command) do
    with {:ok, flags, words} <- parse_command(name, arguments) do
      command.({flags, words})
    end
  end

  defp parse_command(name, arguments),
    do: parse_command(name, Map.fetch!(@command_flags, name), arguments, %{}, [])

  defp parse_command(_name, _allowed, [], flags, words),
    do: {:ok, flags, Enum.reverse(words)}

  # Concept: an opaque positional value remains data even when it starts with
  # the command-line flag prefix.
  #
  # Technical depth: artifact locators belong to the composed store and the
  # port deliberately does not constrain their grammar. `--` therefore ends
  # option parsing and preserves every remaining byte as a positional word.
  # Without this arm a conforming locator such as `--remote-token` was
  # impossible to retrieve through the shipped command.
  defp parse_command(_name, _allowed, ["--" | rest], flags, words),
    do: {:ok, flags, Enum.reverse(words) ++ rest}

  defp parse_command(name, allowed, ["--" <> flag | rest], flags, words) do
    case String.split(flag, "=", parts: 2) do
      [key, value] ->
        with :ok <- admit_flag(name, allowed, flags, key),
             :ok <- require_flag_value(key, value) do
          parse_command(name, allowed, rest, Map.put(flags, key, value), words)
        end

      [key] ->
        with :ok <- admit_flag(name, allowed, flags, key),
             {:ok, value, tail} <- take_flag_value(key, rest) do
          parse_command(name, allowed, tail, Map.put(flags, key, value), words)
        end
    end
  end

  defp parse_command(name, allowed, [word | rest], flags, words),
    do: parse_command(name, allowed, rest, flags, [word | words])

  defp admit_flag(name, allowed, flags, key) do
    cond do
      key not in allowed -> {:error, "--#{key} is not valid for loopex #{name}"}
      Map.has_key?(flags, key) -> {:error, "--#{key} was supplied more than once"}
      true -> :ok
    end
  end

  defp require_flag_value(key, ""), do: {:error, "--#{key} requires a value"}
  defp require_flag_value(_key, _value), do: :ok

  defp take_flag_value(key, [value | rest]) do
    cond do
      flag?(value) -> {:error, "--#{key} requires a value"}
      value == "" -> {:error, "--#{key} requires a value"}
      true -> {:ok, value, rest}
    end
  end

  defp take_flag_value(key, []), do: {:error, "--#{key} requires a value"}

  @doc """
  ## Concept

  The host policy an operator selected.

  ## Technical depth

  There is no default. A command that quietly picked one would be answering the
  authority question on the operator's behalf, which is the decision the kernel
  refuses to make and the composition refuses to make.
  """
  @spec policy(binary() | nil) :: {:ok, module()} | {:error, binary()}
  def policy("allow-all"), do: {:ok, AllowAll}
  def policy("shell-allowlist"), do: {:ok, ShellAllowlist}
  def policy(nil), do: {:error, "--policy is required; there is no default host authority"}
  def policy(other), do: {:error, "unknown policy #{other}"}

  @doc """
  ## Concept

  Parses argv into flags and positional words.

  ## Technical depth

  Standard library only, and deliberately small: `--flag value`, `--flag=value`,
  and bare words. Anything richer would be a dependency or a parser this command
  has no use for.
  """
  @spec parse([binary()]) :: {map(), [binary()]}
  def parse(argv), do: parse(argv, {%{}, []})

  defp parse([], {flags, words}), do: {flags, Enum.reverse(words)}

  defp parse(["--" <> flag | rest], {flags, words}) do
    case String.split(flag, "=", parts: 2) do
      [name, value] ->
        parse(rest, {Map.put(flags, name, value), words})

      [name] ->
        # A guard cannot call String.starts_with?/2, and the distinction matters:
        # `--steer` followed by another flag is a bare switch, while `--steer
        # "text"` takes that text as its value.
        case rest do
          [value | tail] ->
            if flag?(value),
              do: parse(rest, {Map.put(flags, name, true), words}),
              else: parse(tail, {Map.put(flags, name, value), words})

          [] ->
            parse(rest, {Map.put(flags, name, true), words})
        end
    end
  end

  defp parse([word | rest], {flags, words}), do: parse(rest, {flags, [word | words]})

  defp flag?(value), do: is_binary(value) and String.starts_with?(value, "--")

  # Concept: start the stack the operator asked for, then drive it through the
  # facade and nothing else.
  #
  # Technical depth: the interrupt is trapped and turned into the same public
  # abort any other caller would submit. It signals no process, writes no control
  # file, and opens no channel of its own, which is what keeps cancellation
  # same-process by construction rather than by convention. Which signals reach
  # it, and by what route a terminal Ctrl-C becomes one of them, is
  # `LoopexCli.Interrupt`.
  defp run({flags, words}, options) do
    # A ceiling the operator got wrong is refused before the prompt is even
    # read, so the answer names the flag rather than the missing words.
    with {:ok, _context} <- context_token_budget(flags),
         :ok <- one_input(flags),
         {:ok, policy} <- policy(Map.get(flags, "policy")),
         {:ok, prompt} <- prompt_of(words),
         {:ok, runtime} <- start_runtime(flags, policy, options),
         {:ok, session_id} <- create(runtime),
         {:ok, attachment} <-
           facade(Loopex, :attach, [runtime, session_id, [after_event_sequence: 0]]),
         {:ok, status} <- facade(Loopex, :session_status, [runtime, session_id]) do
      # Technical depth: the backstop is sized from the cleanup period this
      # session committed, exactly as `resume` sizes its own, because a fixed
      # ten seconds ends the process before an executor given a longer period
      # can reach its own kill, leaving `cancelled` unreachable at any grace
      # above that number and the operator holding the backstop every time.
      Interrupt.install(attachment, Map.fetch!(status, :cleanup_grace_ms))

      case facade(Loopex, :command, [
             attachment,
             %{type: :prompt, command_id: "run-1", content: prompt}
           ]) do
        {:accepted, _id} ->
          case track(flags, session_id) do
            :ok ->
              follow_with_input(attachment, flags)

            # Technical depth: the stream still runs, because the session is
            # live and what it does is still the operator's answer. Its own
            # result is discarded in favour of the recording failure, which is
            # the one that outlives this terminal.
            {:error, message} ->
              _ = follow_with_input(attachment, flags)
              {:error, message}
          end

        {:error, reason} ->
          {:error, "the prompt was refused: #{inspect(reason)}"}
      end
    end
  end

  # Concept: steering and following up are separate things the operator says
  # separately.
  #
  # Technical depth: the runtime never infers which of the two an input is, so
  # this surface must not either. Each has its own flag, a steer names the run it
  # is steering, and an input naming neither is refused rather than resolved from
  # the state of the session. Passing both is refused for the same reason: a
  # caller who supplied both has not said which they meant.
  defp follow_with_input(attachment, flags) do
    steer = Map.get(flags, "steer")
    follow_up = Map.get(flags, "follow-up")

    cond do
      is_binary(steer) ->
        submit_steer(attachment, steer)

      is_binary(follow_up) ->
        submit_follow_up(attachment, follow_up)

      true ->
        Render.stream(attachment)
    end
  end

  # Concept: a steer must name a run, and the operator should not have to.
  #
  # Technical depth: the run identifier is taken from the `run.started` event on
  # the durable plane as the terminal reads it, rather than remembered by this
  # process or read from an attachment snapshot, which is anchored to the sequence
  # it attached at and never advances. The steer therefore names the run the
  # session actually started.
  defp submit_steer(attachment, content) do
    Render.stream(attachment,
      on_run_started: fn run_id ->
        case facade(Loopex, :command, [
               attachment,
               %{type: :steer, command_id: unique_id(), run_id: run_id, content: content}
             ]) do
          {:accepted, _id} ->
            :ok

          {:error, reason} ->
            IO.puts(:stderr, "loopex: the steer was refused: #{inspect(reason)}")
        end
      end
    )
  end

  # Concept: a follow-up is queued, not joined.
  #
  # Technical depth: it names no run because it starts one, after the active run
  # and its steering settle. Submitting it before the stream begins is what makes
  # it queued rather than a second prompt racing the first.
  defp submit_follow_up(attachment, content) do
    case facade(Loopex, :command, [
           attachment,
           %{type: :follow_up, command_id: unique_id(), content: content}
         ]) do
      {:accepted, _id} -> Render.stream(attachment)
      {:error, reason} -> {:error, "the follow-up was refused: #{inspect(reason)}"}
    end
  end

  # Technical depth: the state root was resolved and used by `start_runtime/2`
  # before this is reached, so a failure to resolve it here is not a case to
  # handle but a contradiction to fail on.
  defp track(flags, session_id) do
    {:ok, root} = state_root(flags)
    record_session(root, session_id)
  end

  @doc """
  ## Concept

  Records a session in the state root, so `loopex sessions` lists it and
  `loopex resume` can reach it — and says plainly when it could not.

  ## Technical depth

  Answers `:ok` only when the state root actually holds the entry, and otherwise
  reports the reason on standard error and returns it.

  It ran its `with` for the effect, discarded whatever it returned, and answered
  `:ok` unconditionally. Every reason recording can fail --
  `{:session_entry_persist_failed, :eacces}` against a read-only state root, a
  placement identity that cannot be read, a `sessions` name something else
  already occupies -- therefore became success. The run streamed exactly as it
  does when everything worked, and the first the operator learned of it was
  `loopex sessions` not listing the session and `loopex resume` refusing to
  reach it, with nothing left by then to say which run it had been.

  The failure is reported here, where it is observed, rather than only at the
  exit status, because the run this belongs to may stream for a long time
  afterwards and an operator who is told at once can still act on it. The
  session itself is not abandoned over it: the prompt is already accepted and
  the Store already holds the session, so the stream still reports what the
  session did and the command fails at the end because part of what it was asked
  to do was not done.
  """
  @spec record_session(Path.t(), binary()) :: :ok | {:error, binary()}
  def record_session(root, session_id) do
    with {:ok, placement} <- facade(Loopex, :runtime_placement_id, [root]),
         :ok <- facade(Loopex, :track_session, [root, session_id, placement]) do
      :ok
    else
      {:error, reason} ->
        message =
          "the session ran but was not recorded in #{root} (#{inspect(reason)}); " <>
            "`loopex sessions` will not list #{session_id} and " <>
            "`loopex resume #{session_id}` cannot reach it"

        IO.puts(:stderr, "loopex: #{terminal_message(message)}")
        {:error, message}
    end
  end

  defp sessions({flags, words}) do
    with :ok <- no_positionals(words, "sessions"),
         {:ok, root} <- state_root(flags),
         {:ok, entries} <- facade(Loopex, :list_sessions, [root]) do
      Render.sessions(entries)
    end
  end

  defp resume({flags, words}, options) do
    with {:ok, session_id} <- positional(words, "session identifier"),
         {:ok, policy} <- policy(Map.get(flags, "policy")),
         {:ok, runtime} <- start_runtime(flags, policy, options),
         {:ok, root} <- state_root(flags) do
      recover(:resume, root, runtime, session_id, flags)
    end
  end

  # Concept: an operator continuing or stopping a session gets that session's
  # own configuration back, and finds out before anything moves if what they
  # asked for disagrees with it.
  #
  # Technical depth: ADR 0016's prepared recovery. Ownership is acquired and the
  # session's complete history rebuilt, but the recovered work stays paused, so
  # the committed cleanup period and active context ceiling can be read from the
  # owner itself and compared with what the operator named. An omitted flag takes
  # the committed value; an equal one agrees; a different one is refused — and
  # refused only after the prepared owner has been given up and this command's
  # placement lock released, because a refusal that left an owner holding a
  # paused session and a lock naming this process would cost the operator their
  # next move as well as this one. Cleanup is compared before context so a
  # command that got both wrong is told about the one it must fix first, rather
  # than about a ceiling it may not have to change at all. A settled session
  # reports no active context and therefore compares none: an explicit ceiling
  # there governs the next run, not one that already ended.
  defp recover(command, root, runtime, session_id, flags) do
    case facade(Loopex, :prepare_resume_known_session, [root, runtime, session_id, unique_id()]) do
      {:ok, {:prepared, activation}} ->
        settle(command, runtime, session_id, flags, activation)

      {:ok, {:replayed, _resumed}} ->
        settle(command, runtime, session_id, flags, nil)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp settle(command, runtime, session_id, flags, activation) do
    case facade(Loopex, :session_status, [runtime, session_id]) do
      {:ok, status} ->
        case agreed_configuration(flags, status) do
          :ok -> continue(command, runtime, session_id, status, activation)
          {:conflict, conflict} -> refuse_configuration(conflict, activation)
        end

      {:error, reason} ->
        _ = give_up(activation)
        {:error, reason}
    end
  end

  defp continue(command, runtime, session_id, status, activation) do
    case facade(Loopex, :attach, [runtime, session_id, [after_event_sequence: 0]]) do
      {:ok, attachment} -> continue_attached(command, attachment, status, activation)
      {:error, reason} -> {:error, reason}
    end
  end

  # Concept: continuing starts the paused work; reconciling never does. Nothing
  # this command resumes is ever running while no handler owns stopping it.
  #
  # Technical depth: `resume` installs the interrupt handler first, carrying the
  # prepared activation, and spends the activation only after that -- ADR 0016's
  # serialized handoff. The order used to be the other way around, and the
  # interval between them was the one moment where recovered work was live and
  # the emulator's own `SIGTERM` handler was still installed: a signal landing
  # there stopped the operating-system process where it stood, with the run it
  # had just restarted continuing to no terminal and no abort submitted. Now a
  # signal that lands first reaches this command's handler, which submits the
  # ordinary public abort; an admitted abort permanently invalidates the
  # activation, so the work never starts and `activate/1` reports the refusal
  # rather than the terminal claiming a run it does not own. The backstop costs
  # nothing until a signal arrives, so installing earlier changes only which
  # handler is holding when one does. The handler is sized by the period this
  # session committed rather than by a number the command invented.
  #
  # `cancel` spends nothing: it admits the ordinary public abort while the
  # recovered work is still paused, which is what keeps a reconciling command
  # from starting the very run it was asked to end. A session with no active run
  # has nothing to abort, so `cancel` reports its settled history instead of
  # refusing over an abort the session cannot accept.
  defp continue_attached(:resume, attachment, status, activation) do
    Interrupt.install_prepared(attachment, Map.fetch!(status, :cleanup_grace_ms), activation)

    case activate(activation) do
      {:ok, _session_id} -> Render.stream(attachment)
      {:error, reason} -> {:error, reason}
    end
  end

  defp continue_attached(:cancel, attachment, %{active_run_id: nil}, _activation),
    do: Render.stream(attachment)

  defp continue_attached(:cancel, attachment, _status, _activation) do
    case facade(Loopex, :command, [attachment, %{type: :abort, command_id: unique_id()}]) do
      {:accepted, _id} -> Render.stream(attachment)
      {:error, reason} -> {:error, reconciliation_of(reason, attachment.session_id)}
    end
  end

  defp activate(nil), do: {:ok, :replayed}
  defp activate(activation), do: facade(Loopex, :activate_resume, [activation])

  defp give_up(nil), do: :ok
  defp give_up(activation), do: facade(Loopex, :abandon_resume, [activation])

  defp refuse_configuration(conflict, activation) do
    refusal =
      case give_up(activation) do
        :ok -> {:error, conflict}
        {:error, reason} -> {:error, {unconfirmed_conflict(conflict), reason}}
      end

    _ = release_placement()
    refusal
  end

  defp unconfirmed_conflict(:cleanup_grace_ms_configuration_conflict),
    do: :cleanup_grace_ms_configuration_conflict_owner_unconfirmed

  defp unconfirmed_conflict(:context_token_budget_configuration_conflict),
    do: :context_token_budget_configuration_conflict_owner_unconfirmed

  defp agreed_configuration(flags, status) do
    with :ok <-
           agrees(
             cleanup_grace(flags),
             :cleanup_grace_ms,
             Map.get(status, :cleanup_grace_ms),
             :cleanup_grace_ms_configuration_conflict
           ) do
      agrees(
        context_token_budget(flags),
        :context_token_budget,
        Map.get(status, :active_context_token_budget),
        :context_token_budget_configuration_conflict
      )
    end
  end

  defp agrees({:ok, supplied}, key, committed, conflict) do
    case Keyword.fetch(supplied, key) do
      :error -> :ok
      {:ok, _named} when is_nil(committed) -> :ok
      {:ok, ^committed} -> :ok
      {:ok, _different} -> {:conflict, conflict}
    end
  end

  defp agrees({:error, _refusal}, _key, _committed, _conflict), do: :ok

  # Concept: reconcile a session a dead process left behind.
  #
  # Technical depth: narrower than an interrupt and deliberately so. It applies
  # only where no live Runtime Control holds the session's placement key, and it
  # is refused against a live owner rather than racing one — two Controls on one
  # placement key is precisely what ADR 0008 makes the host responsible for
  # preventing.
  defp cancel({flags, words}, options) do
    with {:ok, session_id} <- positional(words, "session identifier") do
      cancel_session(session_id, flags, options)
    end
  end

  # Concept: the session identifier stays in scope for the failure paths, so a
  # refusal can say which session it is about.
  #
  # Technical depth: `else` sees no binding made by its own `with`, so naming the
  # session in a refusal means resolving the operator's positional argument
  # first. Everything after it keeps the order it had: the policy is resolved
  # before the placement key is read, and the live-owner refusal still arrives
  # before any composition starts.
  defp cancel_session(session_id, flags, options) do
    with {:ok, policy} <- reconciling_policy(flags),
         {:ok, root} <- state_root(flags),
         :none <- Placement.live_owner(root),
         {:ok, runtime} <- start_runtime(flags, policy, options) do
      recover(:cancel, root, runtime, session_id, flags)
    else
      {:ok, owner} ->
        {:error,
         "a live loopex process (pid #{owner}) owns this state root; " <>
           "cancel from that terminal, or stop it first"}

      # Concept: a refusal keeps the words it was refused in.
      #
      # Technical depth: the recovery pipeline reports configuration conflicts
      # and facade refusals in their own terms, and wrapping those in a sentence
      # about reconciliation would rename a decision the operator has to act on.
      # Only the abort itself, which is the reconciliation, is described that way,
      # and it says so where it happens. A store that could not be opened or
      # replayed refused in no words at all, so that one class is given some
      # rather than inspected into the terminal.
      {:error, reason} ->
        {:error, stated(reason, session_id)}
    end
  end

  @store_unreadable "its state store could not be opened or read"

  # Concept: an operator is told which session failed and what kind of thing
  # failed, and is never shown the runtime term that carried it.
  #
  # Technical depth: a store that cannot open or replay refuses with an internal
  # tuple, and one reached a terminal verbatim as `{:invalid_history, 0,
  # :frame_does_not_match_transition}` -- a statement about the log's replay
  # audit, addressed to nobody who can act on it, carrying durable bytes into a
  # terminal on the way. The classes an operator acts on differently are named
  # here and nothing else is. `stated/2` leaves every other refusal exactly as it
  # was written, because those already arrived in words; `reconciliation_of/2`
  # answers for the abort itself, which has no other sentence to fall back to.
  # Neither keeps the term: this command configures no diagnostics sink, and
  # stderr is not one.
  defp stated(reason, session_id) do
    case failure_class(reason) do
      nil -> reason
      class -> reconciliation_refusal(session_id, class)
    end
  end

  defp reconciliation_of(reason, session_id),
    do: reconciliation_refusal(session_id, failure_class(reason))

  defp reconciliation_refusal(session_id, nil),
    do: "session #{session_id} could not be reconciled"

  defp reconciliation_refusal(session_id, class),
    do: "session #{session_id} could not be reconciled: " <> class

  defp failure_class({:invalid_history, _index, _detail}),
    do: "its recorded history could not be replayed"

  defp failure_class({:store_unavailable, _path, _reason}), do: @store_unreadable
  defp failure_class({:log_unavailable, _detail}), do: @store_unreadable
  defp failure_class(:store_unavailable), do: @store_unreadable
  defp failure_class({:store_file_invalid, _path}), do: @store_unreadable
  defp failure_class({:store_log_too_large, _size, _limit}), do: @store_unreadable

  defp failure_class({:store_writer_active, _path}),
    do: "another process is already writing this state root's store"

  defp failure_class(_reason), do: nil

  defp artifact({flags, words}) do
    with {:ok, reference} <- positional(words, "artifact reference"),
         {:ok, root} <- state_root(flags),
         {:ok, store} <- LoopexComposition.artifacts(root),
         {:ok, bytes} <- fetch_artifact(store, reference) do
      IO.binwrite(bytes)
      :ok
    end
  end

  # Concept: retrieval goes through the port, so a host that composed a different
  # artifact store is followed rather than bypassed.
  #
  # Technical depth: this named the reference adapter directly and called its
  # `stat` and `fetch`. The composition stayed valid and the port stayed
  # implemented, and `loopex artifact` was still coupled to one implementation --
  # a facade-only claim that the command's own locked check omitted rather than
  # caught.
  defp fetch_artifact(store, reference) do
    case Loopex.ArtifactStore.retrieve(store, reference) do
      {:ok, bytes} -> {:ok, bytes}
      {:error, :unknown_artifact} -> {:error, "no artifact is retained for #{reference}"}
      {:error, reason} -> {:error, "the artifact could not be read: #{inspect(reason)}"}
    end
  end

  # Concept: check what the operator named before starting anything.
  #
  # Technical depth: the workspace becomes a lease held by the executor, and a
  # lease over a path that is not a directory fails inside a linked start-up,
  # which reaches an operator as an exit signal rather than as a sentence. Where
  # the path came from the operator, so should the answer.
  defp workspace(flags) do
    path = Map.get(flags, "workspace", File.cwd!())

    if File.dir?(path),
      do: {:ok, path},
      else: {:error, "the workspace #{path} is not a directory"}
  end

  # Concept: the authority a reconciling command needs is none, and what it falls
  # back to must not be permission.
  #
  # Technical depth: `cancel` submits an abort and runs no tool, so requiring a
  # host policy made every documented invocation of it fail before it reached the
  # session it was asked to reconcile. The runtime still refuses to start with no
  # policy at all, so one is named here rather than omitted.
  #
  # It is a refusing one. Falling back to the permissive policy would have made
  # that policy exactly what it is documented never to be -- an implicit default
  # an operator did not name and is not told about, since its notice only fires
  # at a tool call this command never makes. A reconciling run that somehow
  # reached a tool should be refused, so refusing is both the safe default and
  # the true one. An operator who names a policy still gets theirs.
  defp reconciling_policy(flags) do
    case Map.fetch(flags, "policy") do
      :error -> {:ok, LoopexCli.Policy.RefuseAll}
      {:ok, selected} -> policy(selected)
    end
  end

  # Concept: one live command owns a state root while it is using it, and gives
  # it back when it stops.
  #
  # Technical depth: the lock was implemented and never taken, so the exclusion
  # it describes never engaged. Taking it without releasing it would have been
  # worse than leaving it dormant: `System.halt/1` ends the emulator through
  # `:erlang.halt`, which runs no Erlang afterwards, so an `at_exit` release
  # never fires and every successful run would leave a lock naming a dead
  # process. The operating system reuses process identifiers, so that lock
  # eventually names something live and unrelated, and the operator is refused
  # their own state root and told to stop a process that is not theirs.
  #
  # The lock is therefore recorded where the entry point can find it and released
  # explicitly before halting. A lock left behind by a genuine crash is still
  # reclaimed by the next acquirer through the liveness check.
  @placement_key {__MODULE__, :placement_lock}

  defp own_placement(root) do
    case Placement.acquire(root) do
      {:ok, lock} ->
        :persistent_term.put(@placement_key, lock)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  ## Concept

  Gives back the placement lock this command took, if it took one.

  ## Technical depth

  Called on the way out rather than registered to run at exit, because the exit
  path halts the emulator and nothing registered runs then. Safe to call when no
  lock was taken, so every path out can call it without asking first.
  """
  @spec release_placement() :: :ok
  def release_placement do
    case :persistent_term.get(@placement_key, nil) do
      nil ->
        :ok

      lock ->
        :persistent_term.erase(@placement_key)
        Placement.release(lock)
    end
  end

  defp start_runtime(flags, policy, options) do
    with {:ok, workspace} <- workspace(flags),
         {:ok, root} <- state_root(flags),
         {:ok, cleanup} <- cleanup_grace(flags),
         {:ok, context} <- context_token_budget(flags),
         :ok <- own_placement(root) do
      {:ok, placement} = facade(Loopex, :runtime_placement_id, [root])

      # Concept: what a workspace says about how an agent should behave is shown
      # to the operator before the run starts.
      #
      # Technical depth: discovery is the host's job and this command is the
      # host, so it looks, shows what it found, and -- where an operator is at
      # the terminal -- asks. Both the manifest and whatever decision was taken
      # are carried in: with no decision the kernel journals a receipt naming
      # the manifest it withheld, rather than one saying nothing was found.
      discovered = ProjectResources.discover(workspace)
      decision = ProjectResources.decide(discovered, workspace)
      manifest = ProjectResources.runtime_manifest(discovered)

      runtime_starter = Keyword.get(options, :runtime_starter, &LoopexComposition.start/1)

      # Concept: yesterday's session can be resumed today, and the file the
      # previous run left behind is not what decides that.
      #
      # Technical depth: the store's writer marker is physical exclusion and
      # survives its holder's death by design, because nothing portable can
      # compare-and-delete it. An `escript` halts the emulator, so the marker
      # outlives every completed run, and a later `resume` or `cancel` used to be
      # refused with `{:store_writer_active, path}` by a process that had already
      # proved nobody was there. `own_placement/1` above is that proof: the
      # placement lock is only granted after the recorded owner's process
      # incarnation is probed and found absent, and a live owner is refused
      # instead. Asserting the recovery here, after that succeeded and nowhere
      # else, is the trusted-local operation `WriterLock` describes; the option
      # stays absent for an embedder that has established nothing.
      runtime_starter.(
        [
          runtime_id: placement,
          state_root: root,
          workspace: workspace,
          policy: policy,
          project_manifest: manifest,
          project_decision: decision,
          progress_to: self(),
          recover_stale_writer: true
        ] ++ cleanup ++ context
      )
    end
  end

  @cleanup_grace_refusal "--cleanup-grace-ms takes a positive whole number of milliseconds"

  # Concept: the operator can say how long a stopped run may spend stopping.
  #
  # Technical depth: ADR 0009 makes the cleanup grace a declared session
  # configuration value with a default, and a host that cannot name it leaves an
  # operator with whatever the default happens to be on a workspace where the
  # default is wrong -- a build that always needs eight seconds to unwind, or a
  # terminal session where waiting five is already too long. The flag is absent
  # by default rather than defaulted here, so an operator who names nothing gets
  # the one number the port declares rather than a second one this command
  # invented. A value that is not a positive whole number of milliseconds is
  # refused before a runtime starts, because a cleanup period is the kind of
  # mistake that only shows up when something has already gone wrong.
  defp cleanup_grace(flags) do
    case Map.get(flags, "cleanup-grace-ms") do
      nil ->
        {:ok, []}

      value when is_binary(value) ->
        case Integer.parse(value) do
          {milliseconds, ""} when milliseconds > 0 ->
            {:ok, [cleanup_grace_ms: milliseconds]}

          _other ->
            {:error, @cleanup_grace_refusal}
        end

      # A bare `--cleanup-grace-ms` parses as a switch rather than a value, and
      # a switch is not a period. It is refused with the same sentence, because
      # what the operator has to do about it is the same.
      _bare_switch ->
        {:error, @cleanup_grace_refusal}
    end
  end

  @context_budget_refusal "--context-token-budget takes a positive whole number of estimated tokens no greater than 18446744073709551615"
  @uint64_max 18_446_744_073_709_551_615

  # Concept: the operator can say how large one provider request may be.
  #
  # Technical depth: ADR 0017 makes this a top-level runtime option separate
  # from the run's cumulative token budget, and it never enters `:bounds`. The
  # flag is absent by default rather than defaulted here, so an operator who
  # names nothing gets the one reference value the composition inserts rather
  # than a second one this command invented -- which is also what lets a
  # prepared owner's already committed budget be recovered instead of compared
  # against a process default. A value that is not a positive whole number
  # inside the unsigned 64-bit domain is refused before a runtime, store, or
  # executor starts, because a ceiling an operator got wrong should cost
  # nothing to reject.
  defp context_token_budget(flags) do
    case Map.get(flags, "context-token-budget") do
      nil ->
        {:ok, []}

      value when is_binary(value) ->
        case Integer.parse(value) do
          {tokens, ""} when tokens > 0 and tokens <= @uint64_max ->
            {:ok, [context_token_budget: tokens]}

          _other ->
            {:error, @context_budget_refusal}
        end

      # A bare `--context-token-budget` parses as a switch rather than a value,
      # and a switch is not a ceiling.
      _bare_switch ->
        {:error, @context_budget_refusal}
    end
  end

  defp create(runtime) do
    facade(Loopex, :create_session, [runtime, %{"surface" => "cli"}, [command_id: unique_id()]])
  end

  defp state_root(flags) do
    case Map.get(flags, "state-root") do
      root when is_binary(root) -> {:ok, root}
      _absent -> facade(Loopex, :state_root, [])
    end
  end

  # Concept: a caller who asked for both has not said which they meant.
  #
  # Technical depth: refused before a runtime, a store, or an executor is
  # started, because an ambiguous request should cost nothing to reject.
  defp one_input(flags) do
    case {Map.get(flags, "steer"), Map.get(flags, "follow-up")} do
      {steer, follow_up} when is_binary(steer) and is_binary(follow_up) ->
        {:error, "--steer and --follow-up are different requests; name one"}

      _one_or_neither ->
        :ok
    end
  end

  defp prompt_of([]), do: {:error, "describe the change you want, in ordinary words"}
  defp prompt_of(words), do: {:ok, Enum.join(words, " ")}

  defp no_positionals([], _command), do: :ok

  defp no_positionals(_words, command),
    do: {:error, "loopex #{command} takes no positional arguments"}

  defp positional([], expected), do: {:error, "this command needs a #{expected}"}
  defp positional([word], _expected), do: {:ok, word}

  defp positional(_words, expected),
    do: {:error, "this command takes exactly one #{expected}"}

  # Concept: two `loopex` processes running at different times against one state
  # root must never present the journal with the same command identifier for
  # different commands.
  #
  # Technical depth: `System.unique_integer/1` counts from the start of each
  # virtual machine, so a fresh process reissued `cli-1`, and the Store -- which
  # scopes a runtime command to the runtime identifier and the command
  # identifier -- correctly refused the second one as
  # `:runtime_command_conflict`. A completed session could then be neither
  # resumed nor cancelled from a new terminal. One hundred twenty-eight random
  # bits name one command across processes and time with no coordinator and
  # nothing carried between calls, so each call site can keep asking for an
  # identifier at the moment it builds its command. Idempotent replay is
  # untouched: a command that must be re-presented carries the identifier it was
  # already given rather than asking for a second one. The prefix stays visible
  # for transcripts, and the result is thirty-six bounded ASCII bytes, well
  # inside the Store's 256-byte identifier ceiling.
  defp unique_id, do: "cli-" <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)

  # Concept: every facade call this command makes goes through one seam, so a
  # case can watch the real command decide, in order, without a second command
  # written for the test to drive.
  #
  # Technical depth: the same shape the composition uses for its edge and effect
  # seams. The default is `apply/3`, so the shipped path is the ordinary call and
  # nothing about it is conditional on a test being present. It is process-local
  # rather than global, so an observer installed by one case cannot reach
  # another. It observes; it grants nothing: what a facade call is allowed to do
  # is decided inside the kernel, which this command does not run.
  @facade :"$loopex_cli_facade_observer"

  defp facade(module, function, arguments),
    do: Process.get(@facade, &apply/3).(module, function, arguments)

  defp usage do
    """
    loopex — run a coding task from your terminal

      loopex run --policy allow-all "describe the change"
      loopex run --policy allow-all --steer "actually, do it this way"
      loopex run --policy allow-all --follow-up "then do this next"
      loopex run --policy allow-all --cleanup-grace-ms 8000 "describe the change"
      loopex sessions
      loopex resume <session> --policy allow-all
      loopex cancel <session> [--policy <name>]
      loopex artifact <reference>

    --policy is required for anything that runs tools. There is no default.

    Ctrl-C stops the run and reports what happened, when this command is started
    through `bin/loopex`; the escript run directly cannot see that signal. Either
    way the session survives — `loopex cancel <session>` reconciles the run.
    """
  end

  defp halt(:ok), do: System.halt(0)

  defp halt({:error, message}) do
    IO.puts(:stderr, "loopex: #{terminal_message(message)}")
    System.halt(1)
  end

  defp terminal_message(value) when is_binary(value) do
    if Loopex.ProgressPayload.terminal_safe?(value),
      do: value,
      else: inspect(value, binaries: :as_strings, printable_limit: :infinity, limit: :infinity)
  end

  defp terminal_message(value), do: inspect(value, printable_limit: :infinity, limit: :infinity)
end
