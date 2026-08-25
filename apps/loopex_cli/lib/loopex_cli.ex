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
  def main(argv), do: halt(dispatch(argv))

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
  def dispatch(["run" | rest]), do: admitted(rest, &run/1)
  def dispatch(["sessions" | rest]), do: admitted(rest, &sessions/1)
  def dispatch(["resume" | rest]), do: admitted(rest, &resume/1)
  def dispatch(["cancel" | rest]), do: admitted(rest, &cancel/1)
  def dispatch(["artifact" | rest]), do: admitted(rest, &artifact/1)
  def dispatch(_unrecognised), do: usage()

  # Concept: input naming nothing this command offers is refused, whichever
  # subcommand it was typed after.
  #
  # Technical depth: the check was reached only from `run`, so `loopex sessions
  # --nudge x` dropped the flag silently -- which is the failure the refusal
  # exists to prevent, surviving in four of the five subcommands. Refusing at
  # dispatch means a subcommand added later inherits it rather than having to
  # remember it.
  defp admitted(arguments, command) do
    {flags, words} = parse(arguments)

    with :ok <- known_flags(flags) do
      command.({flags, words})
    end
  end

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
  # it, and why a terminal Ctrl-C is not one of them, is `LoopexCli.Interrupt`.
  defp run({flags, words}) do
    with :ok <- one_input(flags),
         {:ok, policy} <- policy(Map.get(flags, "policy")),
         {:ok, prompt} <- prompt_of(words),
         {:ok, runtime} <- start_runtime(flags, policy),
         {:ok, session_id} <- create(runtime),
         {:ok, attachment} <- Loopex.attach(runtime, session_id, after_event_sequence: 0) do
      Interrupt.install(attachment)

      case Loopex.command(attachment, %{type: :prompt, command_id: "run-1", content: prompt}) do
        {:accepted, _id} ->
          track(flags, session_id, runtime)
          follow_with_input(attachment, flags)

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
        case Loopex.command(attachment, %{
               type: :steer,
               command_id: unique_id(),
               run_id: run_id,
               content: content
             }) do
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
    case Loopex.command(attachment, %{
           type: :follow_up,
           command_id: unique_id(),
           content: content
         }) do
      {:accepted, _id} -> Render.stream(attachment)
      {:error, reason} -> {:error, "the follow-up was refused: #{inspect(reason)}"}
    end
  end

  defp track(flags, session_id, runtime) do
    with {:ok, root} <- state_root(flags),
         {:ok, placement} <- Loopex.runtime_placement_id(root) do
      Loopex.track_session(root, session_id, placement)
    end

    _ = runtime
    :ok
  end

  defp sessions({flags, _words}) do
    with {:ok, root} <- state_root(flags),
         {:ok, entries} <- Loopex.list_sessions(root) do
      Render.sessions(entries)
    end
  end

  defp resume({flags, words}) do
    with {:ok, session_id} <- positional(words, "a session identifier"),
         {:ok, policy} <- policy(Map.get(flags, "policy")),
         {:ok, runtime} <- start_runtime(flags, policy),
         {:ok, root} <- state_root(flags),
         {:ok, _resumed} <-
           Loopex.resume_known_session(root, runtime, session_id, unique_id()),
         {:ok, attachment} <- Loopex.attach(runtime, session_id, after_event_sequence: 0) do
      Interrupt.install(attachment)
      Render.stream(attachment)
    end
  end

  # Concept: reconcile a session a dead process left behind.
  #
  # Technical depth: narrower than an interrupt and deliberately so. It applies
  # only where no live Runtime Control holds the session's placement key, and it
  # is refused against a live owner rather than racing one — two Controls on one
  # placement key is precisely what ADR 0008 makes the host responsible for
  # preventing.
  defp cancel({flags, words}) do
    with {:ok, session_id} <- positional(words, "a session identifier"),
         {:ok, root} <- state_root(flags),
         :none <- Placement.live_owner(root),
         {:ok, runtime} <- start_runtime(flags, reconciling_policy(flags)),
         {:ok, _resumed} <-
           Loopex.resume_known_session(root, runtime, session_id, unique_id()),
         {:ok, attachment} <- Loopex.attach(runtime, session_id, after_event_sequence: 0) do
      case Loopex.command(attachment, %{type: :abort, command_id: unique_id()}) do
        {:accepted, _id} -> Render.stream(attachment)
        {:error, reason} -> {:error, "the session could not be reconciled: #{inspect(reason)}"}
      end
    else
      {:ok, owner} ->
        {:error,
         "a live loopex process (pid #{owner}) owns this state root; " <>
           "cancel from that terminal, or stop it first"}

      {:error, reason} when is_binary(reason) ->
        {:error, reason}

      {:error, reason} ->
        {:error, "the session could not be reconciled: #{inspect(reason)}"}
    end
  end

  defp artifact({flags, words}) do
    with {:ok, reference} <- positional(words, "an artifact reference"),
         {:ok, root} <- state_root(flags),
         {:ok, handle} <- LoopexComposition.artifacts(root),
         {:ok, bytes} <- fetch_artifact(handle, reference) do
      IO.binwrite(bytes)
      :ok
    end
  end

  defp fetch_artifact(handle, reference) do
    case Loopex.Store.Local.Artifacts.stat(handle, %{
           digest: reference,
           media_type: "application/octet-stream",
           size: 0,
           role: "tool_output",
           locator: reference
         }) do
      {:ok, resolved} -> Loopex.Store.Local.Artifacts.fetch(handle, resolved)
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

  # Concept: the authority a reconciling command needs is none.
  #
  # Technical depth: `cancel` submits an abort and runs no tool, so requiring a
  # host policy made every documented invocation of it fail before it reached the
  # session it was asked to reconcile. The runtime still refuses to start with no
  # policy at all where tools are active, so one is named here rather than
  # omitted -- and an operator who names their own still gets theirs.
  defp reconciling_policy(flags) do
    case policy(Map.get(flags, "policy")) do
      {:ok, module} -> module
      {:error, _absent} -> AllowAll
    end
  end

  # Concept: one live command owns a state root while it is using it.
  #
  # Technical depth: the lock was implemented and never taken, so the exclusion
  # it describes never engaged and `cancel` never found a live owner to refuse.
  # It is taken for the life of the command and released when it ends; a lock
  # left by a process that died is reclaimed by the next acquirer through the
  # liveness check rather than needing this to have run.
  defp own_placement(root) do
    case Placement.acquire(root) do
      {:ok, lock} ->
        System.at_exit(fn _status -> Placement.release(lock) end)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp start_runtime(flags, policy) do
    with {:ok, workspace} <- workspace(flags),
         {:ok, root} <- state_root(flags),
         :ok <- own_placement(root) do
      {:ok, placement} = Loopex.runtime_placement_id(root)

      # Concept: what a workspace says about how an agent should behave is shown
      # to the operator before the run starts.
      #
      # Technical depth: discovery is the host's job and this command is the
      # host. The manifest is carried into the runtime with no decision beside
      # it, which is the declined path: the kernel journals a receipt naming the
      # manifest it withheld rather than one saying nothing was ever found.
      manifest = ProjectResources.discover(workspace)
      ProjectResources.announce(manifest, workspace)

      LoopexComposition.start(
        runtime_id: placement,
        state_root: root,
        workspace: workspace,
        policy: policy,
        project_manifest: manifest,
        progress_to: self()
      )
    end
  end

  defp create(runtime) do
    Loopex.create_session(runtime, %{"surface" => "cli"}, command_id: unique_id())
  end

  defp state_root(flags) do
    case Map.get(flags, "state-root") do
      root when is_binary(root) -> {:ok, root}
      _absent -> Loopex.state_root()
    end
  end

  # Concept: input naming neither a prompt, a steer, nor a follow-up is refused.
  #
  # Technical depth: the runtime never infers which kind of input it was handed,
  # and a surface that accepted an unrecognised flag would be inferring on its
  # behalf — silently, by dropping it. An operator who typed `--nudge` meant
  # something, and being told nothing happened is the only answer that is true.
  @known_flags ~w(policy state-root workspace steer follow-up)

  defp known_flags(flags) do
    case Map.keys(flags) -- @known_flags do
      [] -> :ok
      [unknown | _rest] -> {:error, "--#{unknown} names neither a steer nor a follow-up"}
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

  defp positional([], expected), do: {:error, "this command needs #{expected}"}
  defp positional([word | _rest], _expected), do: {:ok, word}

  defp unique_id, do: "cli-" <> Integer.to_string(System.unique_integer([:positive]))

  defp usage do
    IO.puts("""
    loopex — run a coding task from your terminal

      loopex run --policy allow-all "describe the change"
      loopex run --policy allow-all --steer "actually, do it this way"
      loopex run --policy allow-all --follow-up "then do this next"
      loopex sessions
      loopex resume <session> --policy allow-all
      loopex cancel <session>
      loopex artifact <reference>

    --policy is required for anything that runs tools. There is no default.

    Ctrl-C ends this process without cleanup: the emulator reserves that signal.
    The session survives it — `loopex cancel <session>` reconciles the run.
    """)

    :ok
  end

  defp halt(:ok), do: System.halt(0)

  defp halt({:error, message}) do
    IO.puts(:stderr, "loopex: #{message}")
    System.halt(1)
  end
end
