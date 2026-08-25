# Concept: the locked selector loads what it needs.
#
# Technical depth: the gate compiles a protected selector on its own, without the
# application's test helper, so a case that relied on the helper to load a
# fixture would find the fixture missing there and present everywhere else. The
# kernel's own agent-loop fixture is required rather than copied: `loopex` is a
# declared dependency of this application, and a second scripted model
# maintained here would drift from the one the loop cases use and hide the drift
# behind a passing test.
Code.require_file("../../loopex/test/support/m1_runtime_helper.exs", __DIR__)
Code.require_file("../../loopex/test/support/agent_loop_helper.exs", __DIR__)

defmodule LoopexCliTest do
  @moduledoc false

  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Loopex.AgentLoopFixture
  alias LoopexCli.Interrupt
  alias LoopexCli.Placement
  alias LoopexCli.Policy.AllowAll
  alias LoopexCli.Render

  # Concept: exercise the real command surface in this process, against a real
  # runtime.
  #
  # Technical depth: `dispatch/1` is the command and `main/1` only adds process
  # exit around it, so a case that shelled out to the built escript would be
  # testing the packaging wrapper rather than the behaviour these outcomes name.
  # The runtime behind it is the kernel's own agent-loop fixture rather than a
  # second scripted double maintained here, which would drift from the one the
  # loop cases use and hide the drift behind a passing test.

  setup do
    :persistent_term.erase({AllowAll, :announced})
    :ok
  end

  defp roots do
    unique = System.unique_integer([:positive])
    state_root = Path.join(System.tmp_dir!(), "loopex-cli-#{unique}")
    workspace = Path.join(System.tmp_dir!(), "loopex-cli-ws-#{unique}")
    File.mkdir_p!(state_root)
    File.mkdir_p!(workspace)

    on_exit(fn ->
      File.rm_rf(state_root)
      File.rm_rf(workspace)
    end)

    {state_root, workspace}
  end

  defp fixture(options) do
    fixture = AgentLoopFixture.start(options)
    on_exit(fn -> AgentLoopFixture.stop(fixture) end)
    fixture
  end

  # Concept: a case reads the source it is about, from wherever it was invoked.
  #
  # Technical depth: the gate compiles a protected selector from the repository
  # root, while `mix test` runs it from the application directory. A relative
  # path is a different file in each, so every source this file inspects is
  # resolved against the selector's own location instead.
  defp app_path(relative), do: Path.expand(Path.join([__DIR__, "..", relative]))
  defp repository_path(relative), do: Path.expand(Path.join([__DIR__, "..", "..", relative]))

  defp declared_dependencies do
    # The application's own declaration, read as source. `Mix.Project.config/0`
    # answers for whichever project is loaded, and under the gate no project is.
    ~r/\{:([a-z_]+), in_umbrella: true\}/
    |> Regex.scan(File.read!(app_path("mix.exs")))
    |> Enum.map(fn [_match, name] -> String.to_atom(name) end)
  end

  defp command_sources do
    "lib/**/*.ex"
    |> then(&Path.wildcard(app_path(&1)))
    |> Map.new(&{Path.relative_to(&1, app_path(".")), File.read!(&1)})
  end

  defp call(id \\ "c1"), do: %{id: id, name: "write", arguments: %{"path" => "notes.txt"}}

  # Concept: watch both planes at once, in the order they actually arrive.
  #
  # Technical depth: a case about a transient item reaching the terminal before a
  # durable one cannot assert on two separately collected lists, because the
  # collection order would be the test's rather than the run's. This reads
  # whichever is ready and records one interleaved sequence.
  defp observe(attachment, acc \\ [], idle \\ 0) do
    received =
      receive do
        {:loopex_progress, item} -> {:progress, item}
      after
        0 -> :none
      end

    case received do
      {:progress, _item} = entry ->
        observe(attachment, [entry | acc], 0)

      :none ->
        case Loopex.next_event(attachment) do
          {:ok, %{kind: "run.finished"} = event} ->
            Enum.reverse([{:event, event} | acc])

          {:ok, event} ->
            observe(attachment, [{:event, event} | acc], 0)

          _absent when idle < 400 ->
            Process.sleep(10)
            observe(attachment, acc, idle + 1)

          _absent ->
            Enum.reverse(acc)
        end
    end
  end

  defp events(observed), do: for({:event, event} <- observed, do: event)

  # Concept: read forward only as far as the case needs.
  #
  # Technical depth: `observe/1` runs to the run's end, which a case about a live
  # run cannot do without the run being over first. This stops at the named event
  # and leaves the rest of the stream for the terminal to read.
  defp observe_until(attachment, kind, acc \\ [], idle \\ 0) do
    case Loopex.next_event(attachment) do
      {:ok, %{kind: ^kind} = event} ->
        Enum.reverse([{:event, event} | acc])

      {:ok, event} ->
        observe_until(attachment, kind, [{:event, event} | acc], 0)

      _absent when idle < 200 ->
        Process.sleep(10)
        observe_until(attachment, kind, acc, idle + 1)

      _absent ->
        Enum.reverse(acc)
    end
  end

  test "loopex run submits a prompt and streams the answer with its tool calls and results" do
    fixture =
      fixture(
        script: [
          %{text: "", calls: [call()], deltas: ["work", "ing"]},
          %{text: "the file is written"}
        ]
      )

    {_session_id, attachment, reply} = AgentLoopFixture.run(fixture, "write the notes file")
    assert {:accepted, _id} = reply

    output =
      capture_io(:stderr, fn ->
        send(self(), {:out, capture_io(fn -> Render.stream(attachment) end)})
      end)

    assert_received {:out, answer}

    # The prompt, the answer, the tool call, and its result all reach the
    # terminal, in the plane each belongs to: what the operator reads is on
    # standard output and the running commentary is not.
    assert answer =~ "> write the notes file"
    assert answer =~ "the file is written"
    assert output =~ "example.write"
    assert output =~ "completed"
    assert output =~ "loopex: done"

    # And the command itself submits a prompt: without one it says so rather
    # than starting a session with nothing in it.
    assert {:error, message} = LoopexCli.dispatch(["run", "--policy", "allow-all"])
    assert message =~ "describe the change you want"
  end

  test "the operator steers a running task and queues a follow-up from the same terminal" do
    fixture = fixture(script: [%{text: "", hold: self()}, %{text: "done differently"}])
    {_session_id, attachment, {:accepted, _id}} = AgentLoopFixture.run(fixture, "do the thing")

    assert_receive {:holding, model}, 2_000

    started =
      Enum.find(events(observe_until(attachment, "run.started")), &(&1.kind == "run.started"))

    run_id = started["run_id"]

    # Steering joins the run that is already going.
    assert {:accepted, _steer} =
             Loopex.command(attachment, %{
               type: :steer,
               command_id: "steer-1",
               run_id: run_id,
               content: "actually, do it this way"
             })

    # A follow-up is a different thing said from the same terminal: it queues
    # rather than joining, and is never confused with the steer above.
    assert {:accepted, _follow} =
             Loopex.command(attachment, %{
               type: :follow_up,
               command_id: "follow-1",
               content: "then do this next"
             })

    send(model, :release)

    # Both affordances exist on the command, separately named.
    {flags, []} = LoopexCli.parse(["--steer", "actually, do it this way"])
    assert flags["steer"] == "actually, do it this way"

    {queued, []} = LoopexCli.parse(["--follow-up", "then do this next"])
    assert queued["follow-up"] == "then do this next"
  end

  test "prompt steer follow up and abort have distinct explicit affordances and input naming neither is refused" do
    usage = capture_io(fn -> LoopexCli.dispatch(["nonsense"]) end)
    assert usage =~ "loopex run"
    assert usage =~ "--steer"
    assert usage =~ "--follow-up"
    assert usage =~ "loopex cancel"

    # Naming both leaves the caller unable to say which they meant, and it is
    # refused before a runtime, a store, or an executor is started.
    assert {:error, both} =
             LoopexCli.dispatch([
               "run",
               "--policy",
               "allow-all",
               "--steer",
               "one way",
               "--follow-up",
               "another way",
               "do the thing"
             ])

    assert both =~ "different requests"

    # Input naming neither is refused rather than silently dropped.
    assert {:error, neither} =
             LoopexCli.dispatch(["run", "--policy", "allow-all", "--nudge", "x", "do the thing"])

    assert neither =~ "--nudge"
    assert neither =~ "neither a steer nor a follow-up"
  end

  test "tool progress from a running executor job reaches the operator's terminal before the tool finishes" do
    fixture =
      fixture(
        script: [%{text: "", calls: [call()]}, %{text: "done"}],
        progress_to: self(),
        tool_delay_ms: 30
      )

    {_session_id, attachment, {:accepted, _id}} = AgentLoopFixture.run(fixture, "run the tool")
    observed = observe(attachment)

    progress_at =
      Enum.find_index(observed, fn
        {:progress, %{tool_call_id: "c1"}} -> true
        _other -> false
      end)

    finished_at =
      Enum.find_index(observed, fn
        {:event, %{kind: "tool.finished"}} -> true
        _other -> false
      end)

    assert is_integer(progress_at), "no executor progress reached the terminal"
    assert is_integer(finished_at), "the tool never finished"

    assert progress_at < finished_at,
           "progress must reach the terminal while the tool is still running"

    # And the terminal writes it as it arrives rather than collecting it. The run
    # is already over and its terminal event already consumed, so this names a
    # short window rather than waiting out the shipped patience.
    output =
      capture_io(:stderr, fn ->
        send(self(), {:loopex_progress, %{kind: :tool_progress, chunk: "working"}})
        Render.stream(attachment, idle_limit_ms: 200)
      end)

    assert output =~ "working"
  end

  test "loopex sessions lists the operator's sessions and loopex resume continues one" do
    {state_root, _workspace} = roots()

    empty = capture_io(fn -> LoopexCli.dispatch(["sessions", "--state-root", state_root]) end)
    assert empty =~ "no sessions"

    {:ok, placement} = Loopex.runtime_placement_id(state_root)
    fixture = fixture(script: [%{text: "done"}], runtime_id: placement)

    {:ok, session_id} =
      Loopex.create_session(fixture.runtime, %{"surface" => "cli"}, command_id: "create-1")

    :ok = Loopex.track_session(state_root, session_id, placement)

    listed = capture_io(fn -> LoopexCli.dispatch(["sessions", "--state-root", state_root]) end)
    assert listed =~ session_id

    # Resuming continues that session under the placement identity that created
    # it, which is the identity the directory recorded.
    assert {:ok, _resumed} =
             Loopex.resume_known_session(state_root, fixture.runtime, session_id, "resume-1")

    # And the command needs to be told which one: it never picks for the operator.
    assert {:error, message} = LoopexCli.dispatch(["resume", "--state-root", state_root])
    assert message =~ "session identifier"
  end

  test "an interrupt signal delivered to a running loopex process cancels the task through the public facade" do
    fixture = fixture(script: [%{text: "", hold: self()}, %{text: "unreached"}])
    {_session_id, attachment, {:accepted, _id}} = AgentLoopFixture.run(fixture, "do the thing")
    assert_receive {:holding, model}, 2_000

    Interrupt.install(attachment)
    on_exit(fn -> restore_signal_handlers() end)

    # The handler replaced the runtime's own, which would have stopped the
    # emulator before the abort it submits could be observed.
    handlers = :gen_event.which_handlers(:erl_signal_server)
    assert Interrupt in handlers
    refute :erl_signal_handler in handlers

    # A real signal, delivered to this real operating-system process.
    {_output, 0} = System.cmd("/bin/kill", ["-TERM", System.pid()])

    # Concept: the model call stays held until the interrupt has ended the run.
    #
    # Technical depth: releasing it first raced the abort. The handler submits
    # the command from a separate process so it cannot stall the signal server,
    # so on a machine where the released turn completed before that process was
    # scheduled the run finished `completed` and the case failed -- correctly,
    # about a run that had not been interrupted. Holding the call is also what
    # the claim is about: the abort is admitted during a model call, and it is
    # the abort that ends it rather than the model returning.
    finished = Enum.find(events(observe(attachment)), &(&1.kind == "run.finished"))
    send(model, :release)

    assert finished, "the interrupt never ended the run"
    assert finished["outcome"] in ["cancelled", "outcome_unknown"]

    # It reached the run by the public facade and by no private path: the
    # command opens no channel of its own.
    source = File.read!(app_path("lib/interrupt.ex"))
    assert source =~ "Loopex.command(attachment, %{"
    assert source =~ "type: :abort"
    refute source =~ "GenServer.call"
    refute source =~ "Process.send"
  end

  test "an interrupt whose cleanup cannot be confirmed reports outcome unknown with its reconciliation reference" do
    fixture =
      fixture(
        script: [%{text: "", calls: [call()]}, %{text: "unreached"}],
        tool_delay_ms: 400,
        cleanup: :unconfirmed
      )

    {_session_id, attachment, {:accepted, _id}} = AgentLoopFixture.run(fixture, "run the tool")

    # Abort while the tool is genuinely running, so cleanup is something that has
    # to be confirmed rather than something already settled. The abort waits for
    # the tool to have started rather than for a duration, because a duration is
    # a guess about scheduling and a loaded machine makes it the wrong guess.
    observe_until(attachment, "tool.started")
    {:accepted, _abort} = Loopex.command(attachment, %{type: :abort, command_id: "abort-1"})

    output =
      capture_io(:stderr, fn ->
        send(self(), {:done, Render.stream(attachment)})
      end)

    assert_received {:done, :ok}
    assert output =~ "outcome is unknown"
    assert output =~ "reconcile with"

    # Never reported as a clean stop: an operator told "cancelled" about a
    # process that may still be running has been told something false.
    refute output =~ "loopex: done"
  end

  test "loopex cancel reconciles a session left behind by a dead process and is refused against a live owner" do
    {state_root, _workspace} = roots()

    # A live owner holds the placement key, so cancel refuses rather than racing
    # it: two Runtime Controls on one key is what the lock exists to prevent.
    assert {:ok, lock} = Placement.acquire(state_root)
    assert {:ok, _pid} = Placement.live_owner(state_root)

    assert {:error, message} =
             LoopexCli.dispatch(["cancel", "s_known_1", "--state-root", state_root])

    assert message =~ "live loopex process"

    # A lock left by a process that is gone describes nothing, and the session
    # behind it is reconcilable rather than permanently blocked.
    Placement.release(lock)
    File.write!(Path.join(state_root, "placement.lock"), "999999")
    assert :none = Placement.live_owner(state_root)
    assert {:ok, reclaimed} = Placement.acquire(state_root)
    assert File.read!(reclaimed) == System.pid()

    # Reconciling still reaches the run through the public facade: cancel is a
    # different route to the same abort, not a private one.
    Placement.release(reclaimed)
    {:ok, placement} = Loopex.runtime_placement_id(state_root)
    fixture = fixture(script: [%{text: "", hold: self()}], runtime_id: placement)

    {:ok, session_id} =
      Loopex.create_session(fixture.runtime, %{"surface" => "cli"}, command_id: "create-1")

    :ok = Loopex.track_session(state_root, session_id, placement)
    {:ok, _resumed} = Loopex.resume_known_session(state_root, fixture.runtime, session_id, "r-1")
    {:ok, attachment} = Loopex.attach(fixture.runtime, session_id, after_event_sequence: 0)

    assert {:accepted, _prompt} =
             Loopex.command(attachment, %{
               type: :prompt,
               command_id: "prompt-1",
               content: "do the thing"
             })

    assert_receive {:holding, model}, 2_000
    assert {:accepted, _id} = Loopex.command(attachment, %{type: :abort, command_id: "abort-1"})
    send(model, :release)
  end

  test "the policy option selects the governing host policy and a refusal is reported in the transcript" do
    # There is no default. A command that quietly picked one would answer the
    # authority question on the operator's behalf.
    assert {:error, missing} = LoopexCli.policy(nil)
    assert missing =~ "no default host authority"
    assert {:error, unknown} = LoopexCli.policy("something-else")
    assert unknown =~ "unknown policy"
    assert {:ok, AllowAll} = LoopexCli.policy("allow-all")

    assert {:error, refused} = LoopexCli.dispatch(["run", "do the thing"])
    assert refused =~ "--policy is required"

    # And the policy the operator selected actually governs: a refusal is
    # reported in the transcript rather than swallowed or retried.
    fixture =
      fixture(
        script: [%{text: "", calls: [call()]}, %{text: "I could not do that"}],
        policy: LoopexCliTest.DenyingPolicy
      )

    {_session_id, attachment, {:accepted, _id}} = AgentLoopFixture.run(fixture, "write the file")

    output =
      capture_io(:stderr, fn ->
        send(self(), {:out, capture_io(fn -> Render.stream(attachment) end)})
      end)

    assert_received {:out, answer}
    assert output =~ "denied"
    assert answer =~ "I could not do that"
  end

  test "the command ships its own permissive policy that is named explicitly, prints one notice, and is never an implicit fallback" do
    request = %{
      session_id: "s1",
      run_id: "r1",
      tool_call_id: "c1",
      generation: {"loopex.write", "1.0.0", String.duplicate("a", 64)},
      arguments: %{},
      effect_class: "workspace_write",
      idempotency_class: "safe_retry",
      workspace_lease: "lease"
    }

    output = capture_io(:stderr, fn -> for _ <- 1..4, do: AllowAll.decide(request) end)

    occurrences = output |> String.split(AllowAll.notice()) |> length() |> Kernel.-(1)
    assert occurrences == 1
    assert AllowAll.notice() =~ "permissive local authority"
    assert AllowAll.notice() =~ "not a permission model"

    # It applies only where an operator names it, never as a fallback.
    assert {:error, _refused} = LoopexCli.dispatch(["run", "do the thing"])

    # It is this command's own module rather than the reference client's,
    # because a client may not depend on another client. Two shipped permissive
    # policies is the honest consequence of that rule.
    assert AllowAll == LoopexCli.Policy.AllowAll
    declared = declared_dependencies()
    refute :loopex_reference_client in declared
  end

  test "loopex artifact retrieves a spilled artifact by its opaque reference" do
    {state_root, _workspace} = roots()
    {:ok, handle} = LoopexComposition.artifacts(state_root)

    {:ok, reference} =
      Loopex.Store.Local.Artifacts.put(handle, "the whole output", %{"role" => "tool_output"})

    output =
      capture_io(fn ->
        assert :ok =
                 LoopexCli.dispatch(["artifact", reference.locator, "--state-root", state_root])
      end)

    assert output == "the whole output"

    # A reference to nothing says so rather than printing emptiness.
    assert {:error, message} =
             LoopexCli.dispatch([
               "artifact",
               String.duplicate("0", 64),
               "--state-root",
               state_root
             ])

    assert message =~ "no artifact is retained"
  end

  test "project resource trust is decided at the terminal and a non interactive run without a decision proceeds with the block withheld" do
    # Failing closed withholds content, never the runtime.
    assert {:declined, :no_manifest, %{}} = Loopex.ProjectResource.resolve(nil, nil)

    manifest = %{
      entries: [%{label: "AGENTS.md", content: "always run the tests", contained: true}],
      workspace: %{workspace_ref: "w", repository_origin: nil, revision: nil}
    }

    assert {:declined, :no_decision, _detail} = Loopex.ProjectResource.resolve(manifest, nil)

    # A headless run with a manifest and no decision still does the coding task,
    # and the staged bytes carry none of the withheld content.
    fixture = fixture(script: [%{text: "done"}], project_manifest: manifest)
    {_session_id, attachment, {:accepted, _id}} = AgentLoopFixture.run(fixture, "do the thing")

    finished = Enum.find(events(observe(attachment)), &(&1.kind == "run.finished"))
    assert finished["outcome"] == "completed"

    [request | _rest] = Loopex.AgentLoopTestModel.dispatched(fixture.model)
    refute request.canonical_request_bytes =~ "always run the tests"

    # The decision is the terminal's to take, and this command takes none: a
    # non-interactive run is the declined path by construction rather than by a
    # flag someone must remember to pass.
    refute File.read!(app_path("lib/loopex_cli.ex")) =~ "project_decision"
  end

  test "the command surface drives only the public facade and owns no loop store cursor or authority" do
    sources = command_sources()
    assert map_size(sources) >= 4, "the scan found no command modules to check"

    for {path, source} <- sources do
      refute source =~ "Loopex.Runtime.SessionCoordinator", "#{path} reaches a coordinator"
      refute source =~ "Loopex.Runtime.Control", "#{path} reaches runtime control"
      refute source =~ "Loopex.Runtime.SessionState", "#{path} reaches session state"
      refute source =~ "Loopex.Store.transact", "#{path} reaches the store directly"
      refute source =~ "Loopex.Journal", "#{path} reaches the journal"
      refute source =~ "Loopex.Outbox", "#{path} reaches the outbox"
      refute source =~ "Loopex.Store.Local.start_link", "#{path} names a Store implementation"
      refute source =~ "Loopex.LLM.", "#{path} names a Model implementation"
      refute source =~ "Loopex.Executor.Local.start_link", "#{path} names an Executor"
    end

    # The host policy modules it ships for `--policy` are the single named
    # exception, because policy is the host's own decision and the one decision
    # the shipped composition refuses to make for it.
    command = Map.fetch!(sources, "lib/loopex_cli.ex")
    assert command =~ "LoopexCli.Policy.AllowAll"
    assert command =~ "LoopexComposition."
  end

  test "a dropped stream closure leaves the terminal falling back to the durable record without inferring abandonment or starting a timer" do
    # No progress plane at all, so no closure item can arrive. The terminal must
    # still report the run in full, from the durable record.
    fixture = fixture(script: [%{text: "", calls: [call()]}, %{text: "finished anyway"}])
    {_session_id, attachment, {:accepted, _id}} = AgentLoopFixture.run(fixture, "do the thing")

    output =
      capture_io(:stderr, fn ->
        send(self(), {:out, capture_io(fn -> Render.stream(attachment) end)})
      end)

    assert_received {:out, answer}
    assert answer =~ "finished anyway"
    assert output =~ "example.write"
    assert output =~ "loopex: done"

    # An absence is never read as abandonment, and no timer decides it.
    source = File.read!(app_path("lib/render.ex"))
    assert source =~ "durable record"
    refute source =~ "Process.send_after"
    refute source =~ ":timer."

    # The patience is longer than the runtime's own default wall-clock deadline,
    # so the terminal never reports its own view of a run the runtime is still
    # correctly running.
    assert source =~ "@idle_limit_ms 660_000"

    # Where the terminal reads nothing at all — no closure and no durable event —
    # it reports its own view and never the run's fate.
    {:ok, quiet_session} =
      Loopex.create_session(fixture.runtime, %{"surface" => "cli"}, command_id: "create-quiet")

    {:ok, quiet} = Loopex.attach(fixture.runtime, quiet_session, after_event_sequence: 0)

    # The window is named rather than waited out: the shipped patience is longer
    # than the runtime's own deadline on purpose, and what this case is about is
    # what the terminal says when it does stop, not how long it waits first.
    quiet_output =
      capture_io(:stderr, fn -> Render.stream(quiet, idle_limit_ms: 200) end)

    assert quiet_output =~ "it may still be running"
    assert quiet_output =~ "resume"
    refute quiet_output =~ "cancelled"
    refute quiet_output =~ "loopex: done"
  end

  test "the base system prompt and active tool definitions measure under one thousand tokens" do
    definitions = Loopex.Executor.Local.CodingTools.definitions()
    assert length(definitions) == 4

    # The same block the coordinator stages, quoted rather than recomputed: a
    # budget measured against a copy would pass while the real prompt grew.
    system =
      "loopex.system.v1: You are a coding agent working in a real workspace. " <>
        "Use the tools you are given to inspect and change files, and run commands " <>
        "when you need to. Continue until the task is done, then stop."

    assert File.read!(repository_path("loopex/lib/loopex/runtime/session_coordinator.ex")) =~
             "loopex.system.v1: You are a coding agent working in a real workspace. "

    staged =
      definitions
      |> Enum.map(&LoopexProtocol.ToolDefinition.model_facing/1)
      |> :erlang.term_to_binary()

    measured = Loopex.Bounds.estimate(system <> staged)

    assert measured < 1_000,
           "the base prompt and tool definitions measure #{measured} tokens against a ceiling of 1000"

    # The estimator is named so a reviewer knows which measurement produced the
    # number, and it is the one the token budget charges with.
    assert Loopex.Bounds.estimator() =~ "loopex."
  end

  test "argument parsing and terminal output use only the standard library" do
    assert Enum.sort(declared_dependencies()) == [:loopex, :loopex_composition]

    for {path, source} <- command_sources() do
      refute source =~ "Jason", "#{path} uses an external encoder"
      refute source =~ "Optimus", "#{path} uses an external argument parser"
      refute source =~ "Owl.", "#{path} uses an external terminal library"
    end

    # The parser handles exactly the three forms it declares.
    assert {%{"a" => "1", "b" => "word"}, []} = LoopexCli.parse(["--a=1", "--b", "word"])
    assert {%{"c" => "2"}, []} = LoopexCli.parse(["--c", "2"])
    assert {%{"a" => true, "b" => "1"}, []} = LoopexCli.parse(["--a", "--b=1"])
    assert {%{}, ["one", "two"]} = LoopexCli.parse(["one", "two"])
  end

  # Concept: put the runtime's own signal handler back.
  #
  # Technical depth: installing the command's handler is a decision about this
  # operating-system process, and the test process is shared with every later
  # case. Leaving it removed would mean a stray signal during the rest of the
  # suite went unhandled rather than stopping the runner as it should.
  defp restore_signal_handlers do
    _ = :gen_event.delete_handler(:erl_signal_server, Interrupt, [])
    _ = :gen_event.add_handler(:erl_signal_server, :erl_signal_handler, [])
    :ok
  end
end

defmodule LoopexCliTest.DenyingPolicy do
  @moduledoc false

  # Concept: a host that refuses, so a refusal can be read in the transcript.
  #
  # Technical depth: it denies every decision it is asked, which is enough to
  # prove the terminal reports one; the policy port's own negatives are Outcome
  # 6's lane and are not restated here.

  @behaviour Loopex.Policy

  @impl Loopex.Policy
  def decide(_request), do: {:deny, :not_permitted_here}
end
