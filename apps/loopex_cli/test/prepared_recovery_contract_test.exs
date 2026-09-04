Code.require_file("../../loopex/test/support/m1_runtime_helper.exs", __DIR__)
Code.require_file("../../loopex/test/support/agent_loop_helper.exs", __DIR__)

defmodule LoopexCli.PreparedRecoveryContractTest do
  @moduledoc false

  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Loopex.M1RuntimeTestStore
  alias Loopex.Executor.Local
  alias LoopexCli.Interrupt
  alias LoopexCli.Placement
  alias LoopexCli.Render

  @grace 7_311

  setup do
    on_exit(fn ->
      _ = :gen_event.delete_handler(:erl_signal_server, Interrupt, [])
      _ = :gen_event.add_handler(:erl_signal_server, :erl_signal_handler, [])
      _ = LoopexCli.release_placement()
    end)

    :ok
  end

  test "an active recovered run stays paused until one-use activation and propagates cleanup" do
    fixture =
      recovered_fixture("activation", :admitted,
        script: [
          %{
            text: "",
            calls: [
              %{id: "recovered-call", name: "write", arguments: %{"path" => "recovered.txt"}}
            ]
          },
          %{text: "recovered active run", calls: []}
        ],
        tools: [Loopex.AgentLoopFixture.tool_definition()]
      )

    assert length(Loopex.AgentLoopTestModel.dispatched(fixture.model)) == 0
    assert Loopex.AgentLoopTestExecutor.jobs(fixture.executor) == []

    assert {:ok, {:prepared, activation}} =
             invoke(Loopex, :prepare_resume_known_session, [
               fixture.state_root,
               fixture.runtime,
               fixture.session_id,
               "prepare-once"
             ])

    Process.sleep(100)
    assert length(Loopex.AgentLoopTestModel.dispatched(fixture.model)) == 0
    assert Loopex.AgentLoopTestExecutor.jobs(fixture.executor) == []

    assert {:ok, fixture.session_id} == invoke(Loopex, :activate_resume, [activation])
    assert_refused(invoke(Loopex, :activate_resume, [activation]))

    {:ok, resumed} = Loopex.attach(fixture.runtime, fixture.session_id, after_event_sequence: 0)
    drain(resumed)

    assert [job] = Loopex.AgentLoopTestExecutor.jobs(fixture.executor)
    assert Map.fetch(job, :cleanup_grace_ms) == {:ok, @grace}

    assert {:ok, %{cleanup_grace_ms: @grace, active_run_id: nil}} =
             Loopex.session_status(fixture.runtime, fixture.session_id)
  end

  # Concept: the answer an activation gets and what the runtime then does are the
  # same fact, however long the coordinator took to say it.
  #
  # Technical depth: this is a one-use capability, and the message that carries
  # it is not withdrawn when its caller stops waiting. Under a five-second bound
  # a coordinator that was merely busy answered nothing in time, the caller was
  # told `:session_unavailable`, and the coordinator then handled the queued
  # message and spent the activation anyway -- the recovered run started under a
  # capability its holder had been told it did not have, which is the one
  # outcome a one-use capability may not produce. The coordinator is suspended
  # for longer than that former bound and released by a separate process, so the
  # wait is real rather than simulated; a coordinator that genuinely cannot
  # answer is a dead process, and its exit still becomes a refusal.
  test "an activation delayed past the former bound is answered by what the runtime actually did" do
    fixture =
      recovered_fixture("activation-delay", :admitted,
        script: [%{text: "resumed after the wait", calls: []}]
      )

    assert {:ok, {:prepared, activation}} =
             invoke(Loopex, :prepare_resume_known_session, [
               fixture.state_root,
               fixture.runtime,
               fixture.session_id,
               "prepare-delayed"
             ])

    coordinator = coordinator_of(fixture.runtime)
    holder = self()

    # Only the process that suspended a process may resume it, so the suspension
    # and the release both belong to this one, and the holder waits on it.
    spawn_link(fn ->
      :erlang.suspend_process(coordinator)
      send(holder, :suspended)
      Process.sleep(6_000)
      :erlang.resume_process(coordinator)
      send(holder, :released)
    end)

    assert_receive :suspended, 5_000

    assert {:ok, session_id} = invoke(Loopex, :activate_resume, [activation])
    assert session_id == fixture.session_id
    assert_receive :released, 10_000

    # The capability was spent exactly once, by the caller that was told so.
    assert_refused(invoke(Loopex, :activate_resume, [activation]))

    # And the runtime did what the answer said: the recovered run is running.
    assert await_dispatch(fixture.model)
  end

  test "abandonment of an active prepared owner prevents activation and dispatch" do
    fixture = recovered_fixture("abandon", :active)

    assert {:ok, {:prepared, abandoned}} =
             invoke(Loopex, :prepare_resume_known_session, [
               fixture.state_root,
               fixture.runtime,
               fixture.session_id,
               "prepare-abandon"
             ])

    assert length(Loopex.AgentLoopTestModel.dispatched(fixture.model)) == 1
    assert :ok = invoke(Loopex, :abandon_resume, [abandoned])
    assert_refused(invoke(Loopex, :activate_resume, [abandoned]))
    Process.sleep(100)
    assert length(Loopex.AgentLoopTestModel.dispatched(fixture.model)) == 1
  end

  test "a preparer that dies before holder transfer cannot leave an activatable owner" do
    fixture = recovered_fixture("preparer-death", :active)
    parent = self()

    {preparer, monitor} =
      spawn_monitor(fn ->
        send(
          parent,
          {:prepared_by_short_lived_owner,
           invoke(Loopex, :prepare_resume_known_session, [
             fixture.state_root,
             fixture.runtime,
             fixture.session_id,
             "prepare-short-lived"
           ])}
        )
      end)

    assert_receive {:prepared_by_short_lived_owner, preparation}, 5_000
    assert_receive {:DOWN, ^monitor, :process, ^preparer, :normal}, 1_000
    assert {:ok, {:prepared, activation}} = preparation
    assert_refused(invoke(Loopex, :activate_resume, [activation]))

    # Nor can the handoff rescue it. Installation asks for the transfer from the
    # process that installs, and that process is not the holder either, so the
    # owner refuses to move the capability and the handler is left holding one it
    # will never be answered for. This is the half of ADR 0016 that death before
    # the acknowledgement decides, and it is unchanged by the acknowledgement
    # existing.
    assert :ok = invoke(Interrupt, :install_prepared, [fixture.attachment, @grace, activation])

    assert assert_refused(invoke(Interrupt, :activate_prepared, [activation])) ==
             :resume_activation_holder_mismatch

    Process.sleep(100)
    assert length(Loopex.AgentLoopTestModel.dispatched(fixture.model)) == 1
  end

  test "prepared interrupt transfer survives preparer death and an abort wins before dispatch" do
    fixture = recovered_fixture("prepared-interrupt", :active)
    parent = self()

    {preparer, monitor} =
      spawn_monitor(fn ->
        result =
          with {:ok, {:prepared, activation}} <-
                 invoke(Loopex, :prepare_resume_known_session, [
                   fixture.state_root,
                   fixture.runtime,
                   fixture.session_id,
                   "prepare-interrupt"
                 ]),
               :ok <-
                 invoke(Interrupt, :install_prepared, [
                   fixture.attachment,
                   @grace,
                   activation
                 ]) do
            {:ok, activation}
          end

        send(parent, {:prepared_interrupt_installed, result})
      end)

    assert_receive {:prepared_interrupt_installed, installation}, 5_000
    assert_receive {:DOWN, ^monitor, :process, ^preparer, :normal}, 1_000
    assert {:ok, activation} = installation

    # The capability moved. This process never held it, and the owner names that
    # rather than spending it -- which is also what proves the handoff happened
    # at all, because before it the preparer held it and this refusal would have
    # been the same either way.
    assert assert_refused(invoke(Loopex, :activate_resume, [activation])) ==
             :resume_activation_holder_mismatch

    assert length(Loopex.AgentLoopTestModel.dispatched(fixture.model)) == 1

    :gen_event.notify(:erl_signal_server, :sigterm)

    # Concept: the abort must be admitted before this case attaches to read the
    # terminal.
    #
    # Technical depth: a session has one current attachment and a new attach
    # replaces it, so a command put through the earlier one is refused as
    # unavailable. The handler submits the abort from its own process through
    # the attachment it was installed with, and `run_terminal/2` attaches anew;
    # on a cold virtual machine the attach won the race about one run in four,
    # the abort was refused, and the case read the missing terminal as the
    # handler's failure. Waiting for the admission keeps the ordering the
    # command itself has, where one attachment serves both.
    assert await_interrupt_admission(fixture),
           "the signal's abort did not reach its durable admission"

    # Preparer death did not take the capability with it: the handler is still
    # the holder, and what refuses this presentation is the abort rather than a
    # missing one. `:resume_activation_holder_mismatch` here would mean the
    # capability died with the process that prepared it, which is the divergence
    # from ADR 0016 this case exists to refute; `:prepared_activation_not_
    # installed` would mean it never crossed the boundary at all.
    assert assert_refused(invoke(Interrupt, :activate_prepared, [activation])) ==
             :resume_activation_fenced

    # The abort's terminal lands only after the cleanup observation the committed
    # grace derives (ADR 0016); a literal ten seconds sat under that backstop
    # and read a slow but legitimate cleanup as a missing terminal under load.
    {:ok, bounds} = Loopex.Executor.cancellation_bounds(@grace)
    terminal_bound_ms = bounds.cli_backstop_ms + 2_000
    assert run_terminal(fixture, terminal_bound_ms)["outcome"] in ["cancelled", "outcome_unknown"]
    assert length(Loopex.AgentLoopTestModel.dispatched(fixture.model)) == 1
    assert_refused(invoke(Interrupt, :activate_prepared, [activation]))
    assert_refused(invoke(Loopex, :activate_resume, [activation]))
  end

  # Concept: the other half of the same handoff -- the capability the preparer's
  # death did not invalidate is genuinely spendable, not merely un-refusable for
  # a different reason.
  #
  # Technical depth: the case above proves an abort wins when one has begun. This
  # one proves the capability survived at all, which a refusal alone can never
  # show: no signal is delivered, the preparer is gone, and the handler starts
  # the recovered work on the command's behalf. Under the implementation ADR 0016
  # diverged from, the capability stayed with the preparer and this activation
  # was impossible.
  test "a transferred capability activates through the handler after the preparer dies" do
    fixture =
      recovered_fixture("transfer-activates", :admitted,
        script: [%{text: "recovered by the handler", calls: []}]
      )

    parent = self()
    assert Loopex.AgentLoopTestModel.dispatched(fixture.model) == []

    {preparer, monitor} =
      spawn_monitor(fn ->
        result =
          with {:ok, {:prepared, activation}} <-
                 invoke(Loopex, :prepare_resume_known_session, [
                   fixture.state_root,
                   fixture.runtime,
                   fixture.session_id,
                   "prepare-transfer-activates"
                 ]),
               :ok <-
                 invoke(Interrupt, :install_prepared, [fixture.attachment, @grace, activation]) do
            {:ok, activation}
          end

        send(parent, {:prepared_transfer_installed, result})
      end)

    assert_receive {:prepared_transfer_installed, installation}, 5_000
    assert_receive {:DOWN, ^monitor, :process, ^preparer, :normal}, 1_000
    assert {:ok, activation} = installation

    assert assert_refused(invoke(Loopex, :activate_resume, [activation])) ==
             :resume_activation_holder_mismatch

    assert {:ok, session_id} = invoke(Interrupt, :activate_prepared, [activation])
    assert session_id == fixture.session_id
    assert await_dispatch_count(fixture.model, 1)
    assert run_terminal(fixture, 10_000)["outcome"] == "completed"

    # Exactly once: the owner records the capability as spent, and it stays spent
    # by every route.
    assert_refused(invoke(Interrupt, :activate_prepared, [activation]))

    assert assert_refused(invoke(Loopex, :activate_resume, [activation])) ==
             :resume_activation_spent

    Process.sleep(200)
    assert length(Loopex.AgentLoopTestModel.dispatched(fixture.model)) == 1
  end

  # Concept: only the holder may say who holds the capability next.
  #
  # Technical depth: the handoff is an authority move, so a process that never
  # held the capability must not be able to name a new holder -- otherwise any
  # process reaching the struct could route activation to itself. The refusal is
  # by name, and the capability is untouched afterwards: the true holder still
  # spends it, which is what separates a refused transfer from one that half
  # happened.
  test "a holder transfer asked for by a process that is not the holder is refused" do
    fixture = recovered_fixture("transfer-non-holder", :active)
    parent = self()

    assert {:ok, {:prepared, activation}} =
             invoke(Loopex, :prepare_resume_known_session, [
               fixture.state_root,
               fixture.runtime,
               fixture.session_id,
               "prepare-non-holder-transfer"
             ])

    {stranger, monitor} =
      spawn_monitor(fn ->
        send(
          parent,
          {:stranger_transfer, invoke(Loopex, :transfer_resume, [activation, self()])}
        )
      end)

    assert_receive {:stranger_transfer, refusal}, 5_000
    assert_receive {:DOWN, ^monitor, :process, ^stranger, :normal}, 1_000
    assert assert_refused(refusal) == :resume_activation_holder_mismatch

    # Nothing moved: this process is still the holder and can still spend it.
    assert {:ok, session_id} = invoke(Loopex, :activate_resume, [activation])
    assert session_id == fixture.session_id
  end

  # Concept: a signal and this command's own activation can arrive at the same
  # instant, and exactly one of them decides what the session did.
  #
  # Technical depth: both now travel through the process that holds the
  # capability, so they cannot interleave there; whichever reaches the owner
  # first settles the capability, and the other is answered by what the first
  # did. The assertion is that invariant rather than a fixed winner, because the
  # race is genuine. What makes it decisive is that the answer the caller was
  # given and the state the owner actually reached are checked against each
  # other: a caller told `:ok` must find the capability spent, and one told it
  # was fenced must find it fenced and find that nothing ran. An implementation
  # that answered one thing and did the other -- the failure a one-use capability
  # may never produce -- fails here whichever way the race went.
  test "an interrupt and a handler activation race to exactly one winner" do
    fixture = recovered_fixture("transfer-race", :active)
    before = length(Loopex.AgentLoopTestModel.dispatched(fixture.model))

    assert {:ok, {:prepared, activation}} =
             invoke(Loopex, :prepare_resume_known_session, [
               fixture.state_root,
               fixture.runtime,
               fixture.session_id,
               "prepare-race"
             ])

    assert :ok = invoke(Interrupt, :install_prepared, [fixture.attachment, @grace, activation])

    _racer = spawn(fn -> :gen_event.notify(:erl_signal_server, :sigterm) end)
    result = invoke(Interrupt, :activate_prepared, [activation])

    assert await_interrupt_admission(fixture),
           "the signal's abort did not reach its durable admission"

    # What the owner records now, asked of it directly, is the fact the caller's
    # answer has to agree with.
    settled = assert_refused(invoke(Loopex, :activate_resume, [activation]))

    case result do
      {:ok, session_id} ->
        assert session_id == fixture.session_id
        assert settled == :resume_activation_spent

      other ->
        assert assert_refused(other) == :resume_activation_fenced
        assert settled == :resume_activation_fenced
    end

    # The run reaches a truthful ending either way. A recovered attempt that was
    # already open settles as owner loss under ADR 0018 rather than making a
    # second model call, so `failed` is this fixture's ending where the
    # activation won and the abort's own ending where it did not.
    {:ok, bounds} = Loopex.Executor.cancellation_bounds(@grace)
    terminal = run_terminal(fixture, bounds.cli_backstop_ms + 2_000)
    assert terminal["outcome"] in ["cancelled", "outcome_unknown", "failed"]

    # Whichever won, the capability is settled and the work started at most once.
    assert_refused(invoke(Interrupt, :activate_prepared, [activation]))
    Process.sleep(200)
    assert length(Loopex.AgentLoopTestModel.dispatched(fixture.model)) <= before + 1
  end

  test "the prepared interrupt owner can abandon its capability without activating work" do
    fixture = recovered_fixture("interrupt-abandon", :active)

    assert {:ok, {:prepared, abandoned}} =
             invoke(Loopex, :prepare_resume_known_session, [
               fixture.state_root,
               fixture.runtime,
               fixture.session_id,
               "prepare-abandon"
             ])

    assert :ok =
             invoke(Interrupt, :install_prepared, [fixture.attachment, @grace, abandoned])

    assert :ok = invoke(Interrupt, :abandon_prepared, [abandoned])

    # The owner gave it up, rather than the handler merely forgetting it: a
    # holder mismatch here would mean the abandonment never reached the owner and
    # the recovered work was still activatable by whoever did hold it.
    assert assert_refused(invoke(Loopex, :activate_resume, [abandoned])) ==
             :resume_activation_abandoned

    assert_refused(invoke(Interrupt, :activate_prepared, [abandoned]))
    Process.sleep(100)
    assert length(Loopex.AgentLoopTestModel.dispatched(fixture.model)) == 1
  end

  test "commit unknown abort admission permanently fences prepared activation without dispatch" do
    fixture = recovered_fixture("prepared-commit-unknown", :active)

    assert {:ok, {:prepared, activation}} =
             invoke(Loopex, :prepare_resume_known_session, [
               fixture.state_root,
               fixture.runtime,
               fixture.session_id,
               "prepare-commit-unknown"
             ])

    assert :ok =
             invoke(Interrupt, :install_prepared, [fixture.attachment, @grace, activation])

    :ok =
      M1RuntimeTestStore.inject(
        fixture.store_pid,
        {:session_journal_commit, :after_linearization_before_result}
      )

    :gen_event.notify(:erl_signal_server, :sigterm)

    assert wait_for_record(fixture, "command_admitted"),
           "the abort did not reach its durable command admission boundary"

    Process.sleep(100)
    assert length(Loopex.AgentLoopTestModel.dispatched(fixture.model)) == 1

    # Presented by the holder, so the refusal names the fence rather than the
    # holder. A commit-unknown admission is exactly the case where the abort's
    # own outcome is unproved, and the capability is invalidated anyway.
    assert assert_refused(invoke(Interrupt, :activate_prepared, [activation])) ==
             :resume_activation_fenced
  end

  # Concept: nothing `loopex resume` restarts is ever running while no handler
  # owns stopping it.
  #
  # Technical depth: ADR 0016 makes installation and the prepared handoff one
  # serialized step, and `Interrupt.install_prepared/3` is that step -- but the
  # command spent the activation first and installed afterwards, so between the
  # two the recovered run was live and the emulator's own `SIGTERM` handler was
  # still the one installed. A signal landing there ended the operating-system
  # process where it stood, with a run it had just restarted continuing to no
  # terminal and no abort submitted. This case stands in that interval: the
  # command's own facade seam holds activation at the instant the command reaches
  # it, asserts whose handler is installed, and delivers the signal from there.
  # The handler assertion comes before the signal deliberately -- with the
  # ordering wrong the emulator's handler is still installed and delivering a
  # `sigterm` would stop this suite rather than fail this case.
  #
  # The seam it holds is `Interrupt.activate_prepared/1` rather than
  # `Loopex.activate_resume/1`, and that is itself part of what this case proves:
  # the handoff made the handler's own process the capability's holder, so the
  # command asks the handler to start the work rather than presenting a
  # capability it no longer holds.
  test "resume installs its interrupt handler before it spends the activation" do
    fixture = recovered_fixture("resume-signal-window", :active)
    before = length(Loopex.AgentLoopTestModel.dispatched(fixture.model))
    test = self()
    starter = fn _options -> {:ok, fixture.runtime} end

    observer = fn
      Interrupt, :activate_prepared, [activation] ->
        handlers = :gen_event.which_handlers(:erl_signal_server)

        assert Interrupt in handlers,
               "resume reached activation with no handler of its own owning the stop"

        refute :erl_signal_handler in handlers,
               "the emulator's own handler would have ended this process here"

        send(test, {:activation_reached, activation})
        :gen_event.notify(:erl_signal_server, :sigterm)

        assert await_interrupt_admission(fixture),
               "the signal's abort did not reach its durable admission"

        apply(Interrupt, :activate_prepared, [activation])

      module, function, arguments ->
        apply(module, function, arguments)
    end

    Process.put(:"$loopex_cli_facade_observer", observer)

    output =
      try do
        capture_io(fn ->
          send(
            test,
            {:resume_result,
             LoopexCli.dispatch(
               [
                 "resume",
                 fixture.session_id,
                 "--policy",
                 "allow-all",
                 "--state-root",
                 fixture.state_root,
                 "--workspace",
                 fixture.workspace
               ],
               runtime_starter: starter
             )}
          )
        end)
      after
        Process.delete(:"$loopex_cli_facade_observer")
      end

    assert_receive {:activation_reached, activation}, 5_000
    assert_receive {:resume_result, result}, 5_000

    # The terminal says it did not continue the session, rather than streaming a
    # run it no longer owns, and it says so in the abort's own words rather than
    # in words about who was holding what.
    assert assert_refused(result) == :resume_activation_fenced
    refute output =~ "prepared recovery contract"

    # And the work the activation would have started never started.
    assert length(Loopex.AgentLoopTestModel.dispatched(fixture.model)) == before

    assert assert_refused(invoke(Loopex, :activate_resume, [activation])) ==
             :resume_activation_fenced

    {:ok, bounds} = Loopex.Executor.cancellation_bounds(@grace)
    finished = run_terminal(fixture, bounds.cli_backstop_ms + 2_000)
    assert finished["outcome"] in ["cancelled", "outcome_unknown"]
  end

  test "resume omission recovers the committed cleanup period before active work resumes" do
    fixture = recovered_fixture("cli-omission", :active)
    parent = self()
    stop_runtime(fixture.runtime)

    fresh_runtime_options =
      Keyword.put(fixture.runtime_options, :cleanup_grace_ms, @grace + 1)

    starter = fn options ->
      send(parent, {:runtime_start_options, options})

      case Loopex.start_link(fresh_runtime_options) do
        {:ok, runtime} = started ->
          send(parent, {:fresh_recovery_runtime, runtime})
          started

        error ->
          error
      end
    end

    output =
      capture_io(fn ->
        assert :ok =
                 LoopexCli.dispatch(
                   [
                     "resume",
                     fixture.session_id,
                     "--policy",
                     "allow-all",
                     "--state-root",
                     fixture.state_root,
                     "--workspace",
                     fixture.workspace
                   ],
                   runtime_starter: starter
                 )
      end)

    assert output =~ "prepared recovery contract"
    assert_receive {:runtime_start_options, omitted_options}, 5_000
    refute Keyword.has_key?(omitted_options, :cleanup_grace_ms)
    assert_receive {:fresh_recovery_runtime, fresh_runtime}, 5_000
    refute fresh_runtime == fixture.runtime

    assert {:ok, %{cleanup_grace_ms: @grace}} =
             Loopex.session_status(fresh_runtime, fixture.session_id)
  end

  test "resume and cancel cleanup mismatches abandon their prepared owner without manual release" do
    for command <- ["resume", "cancel"] do
      fixture = recovered_fixture("#{command}-mismatch", :active)

      starter = fn options ->
        send(self(), {:runtime_start_options, command, options})
        {:ok, fixture.runtime}
      end

      arguments =
        [command, fixture.session_id] ++
          if(command == "resume", do: ["--policy", "allow-all"], else: []) ++
          [
            "--state-root",
            fixture.state_root,
            "--workspace",
            fixture.workspace,
            "--cleanup-grace-ms",
            Integer.to_string(@grace + 1)
          ]

      assert {:error, conflict} = LoopexCli.dispatch(arguments, runtime_starter: starter)

      assert inspect(conflict) =~ "cleanup"
      assert_receive {:runtime_start_options, ^command, conflict_options}, 5_000
      assert Keyword.fetch!(conflict_options, :cleanup_grace_ms) == @grace + 1
      assert length(Loopex.AgentLoopTestModel.dispatched(fixture.model)) == 1
      assert Placement.live_owner(fixture.state_root) == :none

      assert {:ok, {:prepared, replacement}} =
               invoke(Loopex, :prepare_resume_known_session, [
                 fixture.state_root,
                 fixture.runtime,
                 fixture.session_id,
                 "prepare-after-#{command}-mismatch"
               ])

      assert :ok = invoke(Loopex, :abandon_resume, [replacement])
    end
  end

  test "resume and cancel refuse an unreadable configuration flag in run's own words" do
    for command <- ["resume", "cancel"],
        {flag, value, sentence} <- [
          {"--cleanup-grace-ms", "abc", "--cleanup-grace-ms takes a positive whole number"},
          {"--context-token-budget", "8k", "--context-token-budget takes a positive whole number"}
        ] do
      label = String.replace(flag, "--", "")
      fixture = recovered_fixture("#{command}-unreadable-#{label}", :active)

      starter = fn options ->
        send(self(), {:unreadable_runtime_started, command, options})
        {:ok, fixture.runtime}
      end

      arguments =
        [command, fixture.session_id] ++
          if(command == "resume", do: ["--policy", "allow-all"], else: []) ++
          [
            "--state-root",
            fixture.state_root,
            "--workspace",
            fixture.workspace,
            flag,
            value
          ]

      # An unparsable value agrees with nothing, and both commands refuse it in
      # the same sentence `run` gives it. `agreed_configuration/2` would read it
      # as an omitted flag and continue silently under the session's committed
      # value; what stops that is that `start_runtime/3` parses both flags to
      # build the runtime, so the refusal arrives before any recovery begins.
      # This locks that ordering: move either parse out of `start_runtime/3` and
      # the swallow behind it becomes reachable.
      assert {:error, refusal} = LoopexCli.dispatch(arguments, runtime_starter: starter)
      assert refusal =~ sentence

      # It costs nothing: no runtime is started, no owner is prepared, and no
      # placement lock is left behind.
      refute_receive {:unreadable_runtime_started, ^command, _options}, 100
      assert Placement.live_owner(fixture.state_root) == :none
    end
  end

  test "explicit cancel recovers the committed cleanup bound and aborts while work stays paused" do
    fixture = recovered_fixture("explicit-cancel", :active)

    starter = fn options ->
      send(self(), {:cancel_runtime_start_options, options})
      {:ok, fixture.runtime}
    end

    result =
      capture_io(:stderr, fn ->
        send(
          self(),
          {:explicit_cancel_result,
           LoopexCli.dispatch(
             [
               "cancel",
               fixture.session_id,
               "--state-root",
               fixture.state_root,
               "--workspace",
               fixture.workspace
             ],
             runtime_starter: starter
           )}
        )
      end)

    assert_received {:explicit_cancel_result, :ok}
    assert result =~ "cancelled" or result =~ "outcome is unknown"
    assert_receive {:cancel_runtime_start_options, options}, 5_000
    refute Keyword.has_key?(options, :cleanup_grace_ms)
    assert length(Loopex.AgentLoopTestModel.dispatched(fixture.model)) == 1

    finished = run_terminal(fixture, 10_000)
    assert finished["outcome"] in ["cancelled", "outcome_unknown"]
    assert finished["cleanup_grace_ms"] == @grace
  end

  test "configured interrupt joins concurrent signals under one abort identity and bound" do
    fixture = recovered_fixture("configured-signal", :running)

    :ok =
      M1RuntimeTestStore.hold_next_record_before_linearization(
        fixture.store_pid,
        "command_admitted",
        self()
      )

    assert :ok = invoke(Interrupt, :install, [fixture.attachment, @grace])
    assert Interrupt in :gen_event.which_handlers(:erl_signal_server)
    assert length(Loopex.AgentLoopTestModel.dispatched(fixture.model)) == 1

    :gen_event.notify(:erl_signal_server, :sigterm)
    :gen_event.notify(:erl_signal_server, {:sigterm, self()})
    store_pid = fixture.store_pid

    assert_receive {:record_held_before_linearization, waiter, ^store_pid, "command_admitted",
                    held_transaction},
                   5_000

    held_interrupt_ids =
      held_transaction.records
      |> Enum.filter(fn record ->
        payload = Map.get(record, :payload, record)

        (payload[:kind] || payload["kind"]) == "command_admitted" and
          String.starts_with?(payload["command_id"] || "", "interrupt-")
      end)
      |> Enum.map(fn record -> Map.get(record, :payload, record)["command_id"] end)

    assert [_one_interrupt_id] = held_interrupt_ids

    :gen_event.notify(:erl_signal_server, :sigterm)
    Process.sleep(100)

    refute wait_for_record(fixture, "command_admitted", 1),
           "a concurrent signal started another admission while the first was blocked"

    M1RuntimeTestStore.release(waiter)

    finished = run_terminal(fixture, 10_000)
    assert finished["outcome"] in ["cancelled", "outcome_unknown"]
    assert finished["cleanup_grace_ms"] == @grace

    interrupt_admissions =
      fixture
      |> records()
      |> Enum.filter(fn record ->
        record.payload[:kind] == "command_admitted" and
          String.starts_with?(record.payload["command_id"] || "", "interrupt-")
      end)

    assert [admission] = interrupt_admissions
    assert finished["command_id"] == admission.payload["command_id"]
  end

  test "a configured signal before any prompt dispatches no work and legacy install remains available" do
    fixture = recovered_fixture("pre-prompt-signal", :idle)

    assert :ok = Interrupt.install(fixture.attachment)
    assert Interrupt in :gen_event.which_handlers(:erl_signal_server)
    assert Interrupt.signals() == [:sigterm, :sighup, :sigquit]
    assert Interrupt.grace_ms() == 10_000

    assert :ok = invoke(Interrupt, :install, [fixture.attachment, @grace])
    :gen_event.notify(:erl_signal_server, :sigterm)
    Process.sleep(100)
    assert Loopex.AgentLoopTestModel.dispatched(fixture.model) == []

    prompt_id = "prompt-after-refused-interrupt"

    assert {:accepted, ^prompt_id} =
             Loopex.command(fixture.attachment, %{
               type: :prompt,
               command_id: prompt_id,
               content: "prepared recovery contract"
             })

    drain(fixture.attachment)
    assert length(Loopex.AgentLoopTestModel.dispatched(fixture.model)) == 1
  end

  test "prepared recovery and separately prepared Local authority stay out of durable and rendered planes" do
    fixture =
      recovered_fixture("security-plane", :admitted,
        progress_to: self(),
        script: [
          %{text: "public security-plane output", calls: []}
        ]
      )

    local_root = Path.join(fixture.state_root, "private-local-ledger")

    assert {:ok, prepared_local} =
             invoke(Local, :prepare_placement, [local_root, "security-plane-local", @grace])

    generation = local_generation_record!(local_root)

    assert {:ok, {:prepared, activation}} =
             invoke(Loopex, :prepare_resume_known_session, [
               fixture.state_root,
               fixture.runtime,
               fixture.session_id,
               "prepare-security-plane"
             ])

    assert {:ok, fixture.session_id} == invoke(Loopex, :activate_resume, [activation])
    activation_reuse = invoke(Loopex, :activate_resume, [activation])
    assert {:error, _reason} = activation_reuse

    terminal = run_terminal(fixture, 10_000)
    assert terminal["outcome"] == "completed"
    assert {:ok, status} = Loopex.session_status(fixture.runtime, fixture.session_id)

    {:ok, event_attachment} =
      Loopex.attach(fixture.runtime, fixture.session_id, after_event_sequence: 0)

    events = collect_terminal_events(event_attachment)
    progress = collect_security_progress()

    {:ok, render_attachment} =
      Loopex.attach(fixture.runtime, fixture.session_id, after_event_sequence: 0)

    parent = self()

    stdout =
      capture_io(fn ->
        stderr =
          capture_io(:stderr, fn ->
            assert :ok = Render.stream(render_attachment, idle_limit_ms: 1_000)
          end)

        send(parent, {:security_plane_stderr, stderr})
      end)

    assert_receive {:security_plane_stderr, stderr}, 5_000
    assert stdout =~ "public security-plane output"

    planes = %{
      durable_records: records(fixture),
      public_events: events,
      progress: progress,
      diagnostic: activation_reuse,
      terminal: terminal,
      session_status: status,
      printable_command_output: {stdout, stderr}
    }

    # Concept: this fixture's model is a scripted in-process double, so a
    # provider credential set in the environment is never read and could not
    # reach a plane. Asserting it here would refute a leak the fixture cannot
    # produce. The genuine credential planes are proved where a credential-shaped
    # value actually enters: the raw-provider-error cases in this file and in
    # `provider_attempt_protocol_test.exs`.
    forbidden_binaries = [
      local_root,
      generation["generation_id"],
      generation["root_binding"]
    ]

    for {plane, projection} <- planes do
      rendered = inspect(projection, limit: :infinity, printable_limit: :infinity)

      for forbidden <- forbidden_binaries do
        refute String.contains?(rendered, forbidden),
               "#{plane} exposed private cancellation authority #{inspect(forbidden)}"
      end

      refute contains_exact_term?(projection, prepared_local),
             "#{plane} exposed the prepared Local publication authority"

      refute contains_exact_term?(projection, activation),
             "#{plane} exposed the prepared recovery activation capability"

      refute contains_private_runtime_term?(projection),
             "#{plane} exposed a pid, monitor/reference, port, or function"

      refute contains_private_security_key?(projection),
             "#{plane} exposed a nonce, monitor, root binding, activation, or publication key"
    end
  end

  test "the operator renderer emits only a generic failure for a credential shaped raw provider error" do
    secret = "renderer-provider-secret-#{System.unique_integer([:positive])}"

    fixture =
      recovered_fixture("raw-error-renderer", :idle,
        script: [%{raw_result: {:error, {:provider_credential, secret}}}]
      )

    assert {:accepted, "render-raw-error"} =
             Loopex.command(fixture.attachment, %{
               type: :prompt,
               command_id: "render-raw-error",
               content: "render only bounded provider failure"
             })

    parent = self()

    stdout =
      capture_io(fn ->
        stderr =
          capture_io(:stderr, fn ->
            assert :ok = Render.stream(fixture.attachment, idle_limit_ms: 1_000)
          end)

        send(parent, {:raw_error_renderer_stderr, stderr})
      end)

    assert_receive {:raw_error_renderer_stderr, stderr}, 5_000
    assert length(Loopex.AgentLoopTestModel.dispatched(fixture.model)) == 1
    assert stdout =~ "render only bounded provider failure"
    assert stderr =~ "model_call_failed"
    refute stdout =~ secret
    refute stderr =~ secret
    refute inspect(records(fixture), limit: :infinity, printable_limit: :infinity) =~ secret
  end

  defp recovered_fixture(label, phase, options \\ []) do
    unique = System.unique_integer([:positive])
    state_root = Path.join(System.tmp_dir!(), "loopex-a4-cli-state-#{label}-#{unique}")
    workspace = Path.join(System.tmp_dir!(), "loopex-a4-cli-workspace-#{label}-#{unique}")
    File.mkdir_p!(state_root)
    File.mkdir_p!(workspace)

    on_exit(fn ->
      File.rm_rf(state_root)
      File.rm_rf(workspace)
    end)

    {:ok, placement} = Loopex.runtime_placement_id(state_root)

    default_script =
      case phase do
        phase when phase in [:active, :running, :admitted] ->
          [
            %{text: "", hold: self(), hold_timeout_ms: 30_000},
            %{text: "prepared recovery contract", calls: []}
          ]

        :idle ->
          [%{text: "prepared recovery contract", calls: []}]
      end

    script = Keyword.get(options, :script, default_script)
    tools = Keyword.get(options, :tools, [])
    model = Loopex.AgentLoopTestModel.start(script)
    executor = Loopex.AgentLoopTestExecutor.start()
    {store_pid, store} = M1RuntimeTestStore.start_store(label: "prepared-recovery")

    runtime_options =
      [
        context_token_budget: 8_192,
        runtime_id: placement,
        store: store,
        model: %{
          module: Loopex.AgentLoopTestModel,
          model: "scripted:v1",
          options: [script: model, max_tokens: 256]
        },
        executor: %{
          module: Loopex.AgentLoopTestExecutor,
          reference: executor,
          identity: "prepared-recovery-executor",
          epoch: 1,
          fencing_token: 1,
          workspace_ref: "prepared-workspace",
          workspace_lease: "prepared-lease"
        },
        tools: tools,
        active_tools: Enum.map(tools, &Map.fetch!(&1, "tool_id")),
        policy: Loopex.AgentLoopTestPolicy,
        grant_decision: {:host_policy, :allow},
        cleanup_grace_ms: @grace,
        progress_to: Keyword.get(options, :progress_to)
      ]

    {:ok, runtime} = Loopex.start_link(runtime_options)

    on_exit(fn ->
      stop_runtime(runtime)
      stop(executor)
      stop(model)
      stop(store_pid)
    end)

    {:ok, session_id} =
      Loopex.create_session(runtime, %{"surface" => "prepared-recovery"},
        command_id: "create-#{unique}"
      )

    {:ok, attachment} = Loopex.attach(runtime, session_id, after_event_sequence: 0)

    # ADR 0018: a recovered attempt that was open and dispatched settles as
    # owner loss with no second call, so an active run that must continue after
    # activation loses its owner at the durable prompt admission, before any
    # attempt opens. The active and running phases hold mid-attempt; active also
    # loses its owner there, the state ADR 0018 settles as owner loss.
    held_worker =
      case phase do
        phase when phase in [:active, :running] ->
          prompt_id = "prompt-#{unique}"

          assert {:accepted, ^prompt_id} =
                   Loopex.command(attachment, %{
                     type: :prompt,
                     command_id: prompt_id,
                     content: "prepared recovery contract"
                   })

          assert_receive {:holding, worker}, 5_000

          if phase == :active do
            coordinator = coordinator_of(runtime)
            monitor = Process.monitor(coordinator)
            Process.exit(coordinator, :kill)
            assert_receive {:DOWN, ^monitor, :process, ^coordinator, _reason}, 5_000
          end

          worker

        :admitted ->
          prompt_id = "prompt-#{unique}"
          :ok = M1RuntimeTestStore.delay_after_record(store_pid, "prompt_admitted_v2", self())

          prompt =
            Task.async(fn ->
              Loopex.command(attachment, %{
                type: :prompt,
                command_id: prompt_id,
                content: "prepared recovery contract"
              })
            end)

          assert_receive {:record_linearized, waiter, _store, "prompt_admitted_v2", _transition,
                          {:committed, _tx_id, _receipt}},
                         5_000

          coordinator = coordinator_of(runtime)
          monitor = Process.monitor(coordinator)
          Process.exit(coordinator, :kill)
          assert_receive {:DOWN, ^monitor, :process, ^coordinator, _reason}, 5_000
          M1RuntimeTestStore.release(waiter)
          _ = Task.yield(prompt, 5_000) || Task.shutdown(prompt, :brutal_kill)
          nil

        _idle ->
          nil
      end

    :ok = Loopex.track_session(state_root, session_id, placement)

    if is_pid(held_worker) do
      on_exit(fn -> send(held_worker, :release) end)
    end

    %{
      runtime: runtime,
      state_root: state_root,
      workspace: workspace,
      session_id: session_id,
      attachment: attachment,
      model: model,
      executor: executor,
      runtime_options: runtime_options,
      store_pid: store_pid,
      held_worker: held_worker
    }
  end

  defp drain(attachment, attempts \\ 1_000)
  defp drain(_attachment, 0), do: flunk("the preparation fixture did not finish its run")

  defp drain(attachment, attempts) do
    case Loopex.next_event(attachment) do
      {:ok, %{kind: "run.finished"}} ->
        :ok

      {:ok, _event} ->
        drain(attachment, attempts - 1)

      _empty ->
        Process.sleep(5)
        drain(attachment, attempts - 1)
    end
  end

  defp run_terminal(fixture, timeout_ms) do
    {:ok, attachment} =
      Loopex.attach(fixture.runtime, fixture.session_id, after_event_sequence: 0)

    deadline = System.monotonic_time(:millisecond) + timeout_ms
    await_terminal(attachment, deadline)
  end

  defp await_terminal(attachment, deadline) do
    case Loopex.next_event(attachment) do
      {:ok, %{kind: "run.finished"} = event} ->
        event

      {:ok, _event} ->
        await_terminal(attachment, deadline)

      _empty ->
        if System.monotonic_time(:millisecond) >= deadline do
          flunk("the prepared recovery fixture did not publish run.finished")
        else
          Process.sleep(5)
          await_terminal(attachment, deadline)
        end
    end
  end

  defp records(fixture) do
    fixture.store_pid
    |> M1RuntimeTestStore.inspect_state()
    |> get_in([:sessions, fixture.session_id, :records])
  end

  # The session already carries an admission for the prompt that ran before
  # recovery, so waiting on the kind alone would answer immediately. The
  # interrupt's own identity is what distinguishes the abort this signal caused.
  defp await_interrupt_admission(fixture, attempts \\ 300)
  defp await_interrupt_admission(_fixture, 0), do: false

  defp await_interrupt_admission(fixture, attempts) do
    admitted =
      Enum.any?(records(fixture), fn record ->
        record.payload[:kind] == "command_admitted" and
          String.starts_with?(record.payload["command_id"] || "", "interrupt-")
      end)

    if admitted do
      true
    else
      Process.sleep(10)
      await_interrupt_admission(fixture, attempts - 1)
    end
  end

  defp wait_for_record(fixture, kind, attempts \\ 200)
  defp wait_for_record(_fixture, _kind, 0), do: false

  defp wait_for_record(fixture, kind, attempts) do
    if Enum.any?(records(fixture), &(&1.payload[:kind] == kind)) do
      true
    else
      Process.sleep(10)
      wait_for_record(fixture, kind, attempts - 1)
    end
  end

  defp collect_terminal_events(attachment, acc \\ [], attempts \\ 1_000)

  defp collect_terminal_events(_attachment, _acc, 0),
    do: flunk("the security-plane inventory did not reach its durable terminal")

  defp collect_terminal_events(attachment, acc, attempts) do
    case Loopex.next_event(attachment) do
      {:ok, %{kind: "run.finished"} = event} ->
        Enum.reverse([event | acc])

      {:ok, event} ->
        collect_terminal_events(attachment, [event | acc], attempts - 1)

      _absent ->
        Process.sleep(5)
        collect_terminal_events(attachment, acc, attempts - 1)
    end
  end

  defp collect_security_progress(acc \\ []) do
    receive do
      {:loopex_progress, item} -> collect_security_progress([item | acc])
      {:loopex_progress, _session_id, item} -> collect_security_progress([item | acc])
    after
      50 -> Enum.reverse(acc)
    end
  end

  defp local_generation_record!(root) do
    root
    |> Path.join("**/*")
    |> Path.wildcard(match_dot: true)
    |> Enum.find_value(fn path ->
      with {:ok, bytes} <- File.read(path),
           record when is_map(record) <- safe_decode(bytes),
           "local_executor_generation_v1" <- Map.get(record, :ledger_kind) do
        record
      else
        _other -> nil
      end
    end)
    |> case do
      nil -> flunk("the prepared Local root has no generation authority")
      record -> record
    end
  end

  defp safe_decode(bytes) do
    :erlang.binary_to_term(bytes, [:safe])
  rescue
    _error -> :invalid
  end

  defp contains_exact_term?(term, forbidden) when term === forbidden, do: true

  defp contains_exact_term?(term, forbidden) when is_map(term) do
    Enum.any?(term, fn {key, value} ->
      contains_exact_term?(key, forbidden) or contains_exact_term?(value, forbidden)
    end)
  end

  defp contains_exact_term?(term, forbidden) when is_list(term),
    do: Enum.any?(term, &contains_exact_term?(&1, forbidden))

  defp contains_exact_term?(term, forbidden) when is_tuple(term),
    do: term |> Tuple.to_list() |> Enum.any?(&contains_exact_term?(&1, forbidden))

  defp contains_exact_term?(_term, _forbidden), do: false

  defp contains_private_runtime_term?(term)
       when is_pid(term) or is_reference(term) or is_port(term) or is_function(term),
       do: true

  defp contains_private_runtime_term?(term) when is_map(term) do
    Enum.any?(term, fn {key, value} ->
      contains_private_runtime_term?(key) or contains_private_runtime_term?(value)
    end)
  end

  defp contains_private_runtime_term?(term) when is_list(term),
    do: Enum.any?(term, &contains_private_runtime_term?/1)

  defp contains_private_runtime_term?(term) when is_tuple(term),
    do: term |> Tuple.to_list() |> Enum.any?(&contains_private_runtime_term?/1)

  defp contains_private_runtime_term?(_term), do: false

  defp contains_private_security_key?(term) when is_map(term) do
    Enum.any?(term, fn {key, value} ->
      private_security_key?(key) or contains_private_security_key?(value)
    end)
  end

  defp contains_private_security_key?(term) when is_list(term),
    do: Enum.any?(term, &contains_private_security_key?/1)

  defp contains_private_security_key?(term) when is_tuple(term),
    do: term |> Tuple.to_list() |> Enum.any?(&contains_private_security_key?/1)

  defp contains_private_security_key?(_term), do: false

  defp private_security_key?(key) when is_atom(key),
    do: key |> Atom.to_string() |> private_security_key?()

  defp private_security_key?(key) when is_binary(key) do
    key in [
      "activation",
      "activation_capability",
      "admission_nonce",
      "claim_nonce",
      "generation_id",
      "monitor",
      "owner_monitor",
      "prepared_authority",
      "prepared_placement",
      "publication_authority",
      "root_binding",
      "root_claim_nonce"
    ]
  end

  defp private_security_key?(_key), do: false

  defp await_dispatch(model, attempts \\ 1_000)
  defp await_dispatch(_model, 0), do: false

  defp await_dispatch(model, attempts) do
    if Loopex.AgentLoopTestModel.dispatched(model) == [] do
      Process.sleep(5)
      await_dispatch(model, attempts - 1)
    else
      true
    end
  end

  # A recovered run that continues dispatches in addition to the calls the
  # session already made before recovery, so the count rather than emptiness is
  # what says the activation started something.
  defp await_dispatch_count(model, count, attempts \\ 1_000)
  defp await_dispatch_count(_model, _count, 0), do: false

  defp await_dispatch_count(model, count, attempts) do
    if length(Loopex.AgentLoopTestModel.dispatched(model)) >= count do
      true
    else
      Process.sleep(5)
      await_dispatch_count(model, count, attempts - 1)
    end
  end

  defp coordinator_of(runtime) do
    {:ok, children} = Loopex.Runtime.Supervisor.children(runtime.supervisor)

    [{_id, pid, _type, _modules} | _rest] =
      DynamicSupervisor.which_children(children.sessions)

    pid
  end

  defp stop_runtime(runtime) do
    try do
      Loopex.stop(runtime)
    catch
      :exit, _reason -> :ok
    end
  end

  defp stop(pid) when is_pid(pid) do
    if Process.alive?(pid) do
      try do
        GenServer.stop(pid, :normal, 1_000)
      catch
        :exit, _reason -> :ok
      end
    end
  end

  # Concept: a refusal is only evidence if the contract entry exists to refuse.
  # `invoke/3` reports an absent entry as an ordinary error, so a bare
  # `{:error, _}` here would be satisfied by the boundary simply not shipping.
  defp assert_refused(result) do
    assert {:error, reason} = result

    refute match?({:contract_entry_missing, _module, _function, _arity}, reason),
           "the contract entry is absent, so this refusal proves nothing: #{inspect(reason)}"

    reason
  end

  defp invoke(module, function, arguments) do
    if Code.ensure_loaded?(module) and function_exported?(module, function, length(arguments)) do
      apply(module, function, arguments)
    else
      {:error, {:contract_entry_missing, module, function, length(arguments)}}
    end
  end
end
