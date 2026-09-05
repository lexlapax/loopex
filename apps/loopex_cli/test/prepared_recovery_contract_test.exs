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
    #
    # Installation reports the owner's refusal rather than reporting itself
    # complete: the acknowledgement is the transfer's `:ok`, and there was none.
    assert assert_refused(
             invoke(Interrupt, :install_prepared, [fixture.attachment, @grace, activation])
           ) == :resume_activation_holder_mismatch

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

  # Concept: a presentation the owner takes a long time to decide is waited for,
  # and the answer the caller is handed is the answer the owner recorded.
  #
  # Technical depth: the presentation used to travel as a `:gen_event.call/3`
  # under that function's default five-second bound, and the expiry was reported
  # as `:prepared_activation_not_installed` -- a definite statement that the
  # capability never crossed this boundary. The manager then ran the call anyway
  # and settled the capability, so the caller was told one thing while the owner
  # recorded another. That is exactly the failure the owner's own `:infinity`
  # bound on these three decisions exists to prevent, and nothing standing
  # between a caller and the owner may reintroduce it. Holding the owner inside
  # one Store transaction for longer than the former bound is all it takes to
  # expose it, and the abort held there also fixes what the true answer is, so
  # the two halves can be compared rather than merely observed.
  test "a prepared activation slower than the former handler bound is waited for" do
    fixture = recovered_fixture("slow-activation", :active)
    parent = self()
    store_pid = fixture.store_pid

    assert {:ok, {:prepared, activation}} =
             invoke(Loopex, :prepare_resume_known_session, [
               fixture.state_root,
               fixture.runtime,
               fixture.session_id,
               "prepare-slow-activation"
             ])

    assert :ok = invoke(Interrupt, :install_prepared, [fixture.attachment, @grace, activation])

    :ok =
      M1RuntimeTestStore.hold_next_record_before_linearization(
        store_pid,
        "command_admitted",
        self()
      )

    _blocker =
      spawn(fn ->
        send(
          parent,
          {:blocking_abort,
           Loopex.command(fixture.attachment, %{type: :abort, command_id: "hold-the-owner"})}
        )
      end)

    assert_receive {:record_held_before_linearization, waiter, ^store_pid, "command_admitted",
                    _held},
                   5_000

    presentation = Task.async(fn -> invoke(Interrupt, :activate_prepared, [activation]) end)

    # Two seconds past the bound that used to answer this. An implementation
    # that answers from a deadline of its own has already answered by here, and
    # it answered a refusal it could not know to be true.
    refute Task.yield(presentation, 7_000),
           "the presentation was answered before the owner had decided it"

    M1RuntimeTestStore.release(waiter)
    assert_receive {:blocking_abort, {:accepted, "hold-the-owner"}}, 10_000

    answer =
      Task.yield(presentation, 15_000) ||
        Task.shutdown(presentation, :brutal_kill) ||
        flunk("the presentation was never answered")

    assert {:ok, refusal} = answer

    # The abort fenced the capability before its Store transaction, so the owner
    # had already recorded the answer while it was blocked. What the caller was
    # told and what the owner recorded are one fact, which is precisely what an
    # expiring bound could not promise.
    assert assert_refused(refusal) == :resume_activation_fenced

    assert assert_refused(invoke(Loopex, :activate_resume, [activation])) ==
             :resume_activation_fenced

    assert length(Loopex.AgentLoopTestModel.dispatched(fixture.model)) == 1
  end

  # Concept: an operator can still stop a run whose activation is waiting on the
  # owner.
  #
  # Technical depth: the presentation used to be answered from inside the signal
  # server, so while it waited on the owner no signal was handled at all -- and
  # by then the emulator's own `SIGTERM` handler had been removed, leaving a
  # process that nothing short of `SIGKILL` could end and an executor's captured
  # process group with nobody to clean it up. The backstop that exists to prevent
  # exactly that orphan could not be armed either, because arming it is also work
  # the signal server does. This holds the owner, blocks a presentation on it,
  # and then interrupts: the signal server must answer, the abort must be
  # submitted and reach its durable admission, and the backstop must be armed.
  test "an interrupt is handled while a prepared activation waits on the owner" do
    fixture = recovered_fixture("blocked-activation-signal", :active)
    parent = self()
    store_pid = fixture.store_pid

    assert {:ok, {:prepared, activation}} =
             invoke(Loopex, :prepare_resume_known_session, [
               fixture.state_root,
               fixture.runtime,
               fixture.session_id,
               "prepare-blocked-signal"
             ])

    assert :ok = invoke(Interrupt, :install_prepared, [fixture.attachment, @grace, activation])

    # A follow-up rather than an abort: it is admissible while the recovered run
    # is the active one, it holds the owner inside one Store transaction exactly
    # as any admission does, and it leaves the capability unfenced, so the abort
    # the signal submits is the first abort this session sees and its own durable
    # admission is what this case reads.
    :ok =
      M1RuntimeTestStore.hold_next_record_before_linearization(
        store_pid,
        "command_admitted",
        self()
      )

    _blocker =
      spawn(fn ->
        send(
          parent,
          {:blocking_follow_up,
           Loopex.command(fixture.attachment, %{
             type: :follow_up,
             command_id: "hold-the-owner-open",
             content: "prepared recovery contract"
           })}
        )
      end)

    assert_receive {:record_held_before_linearization, waiter, ^store_pid, "command_admitted",
                    _held},
                   5_000

    presentation = Task.async(fn -> invoke(Interrupt, :activate_prepared, [activation]) end)
    Process.sleep(200)

    :gen_event.notify(:erl_signal_server, :sigterm)
    Process.sleep(50)

    # The probe is unlinked deliberately: under the implementation this refutes,
    # its own read of the signal server expires and takes the reader down, and a
    # linked reader would take this case with it instead of failing it.
    _probe =
      spawn(fn -> send(parent, {:signal_server_answered, :sys.get_state(:erl_signal_server)}) end)

    assert_receive {:signal_server_answered, handlers},
                   500,
                   "the signal server did not answer while a prepared activation was waiting"

    assert [%{abort: %{command_id: interrupt_id}, backstop: backstop}] =
             for({Interrupt, _id, handler_state} <- handlers, do: handler_state)

    assert String.starts_with?(interrupt_id, "interrupt-")
    assert is_pid(backstop) and Process.alive?(backstop)

    M1RuntimeTestStore.release(waiter)
    assert_receive {:blocking_follow_up, {:accepted, "hold-the-owner-open"}}, 10_000

    assert await_interrupt_admission(fixture),
           "the signal's abort did not reach its durable admission"

    answer =
      Task.yield(presentation, 15_000) ||
        Task.shutdown(presentation, :brutal_kill) ||
        flunk("the presentation was never answered")

    # Which of the two won is a genuine race and this does not fix it. What it
    # fixes is that the caller's answer and the owner's record agree, whichever
    # way it went.
    settled = assert_refused(invoke(Loopex, :activate_resume, [activation]))

    case answer do
      {:ok, {:ok, session_id}} ->
        assert session_id == fixture.session_id
        assert settled == :resume_activation_spent

      {:ok, refusal} ->
        assert assert_refused(refusal) == settled
    end
  end

  # Concept: installation answers `:ok` only for a handoff the owner
  # acknowledged, and names the refusal otherwise.
  #
  # Technical depth: the handoff's result used to be discarded, so a caller was
  # told the capability had moved whether or not it had. Two ways it does not
  # move are proved here: an emulator with no signal server, where nothing can
  # hold a handler and therefore nothing can hold the capability, and an
  # acknowledged transfer, after which this process is no longer able to present
  # what it prepared. The second is what makes `:ok` mean something -- a caller
  # that gets it can be certain the owner recorded another holder, because the
  # owner refuses this process by name afterwards.
  test "prepared installation answers ok only for a handoff the owner acknowledged" do
    fixture = recovered_fixture("handoff-answer", :active)

    assert {:ok, {:prepared, unmoved}} =
             invoke(Loopex, :prepare_resume_known_session, [
               fixture.state_root,
               fixture.runtime,
               fixture.session_id,
               "prepare-handoff-answer"
             ])

    manager = Process.whereis(:erl_signal_server)
    assert is_pid(manager)
    Process.unregister(:erl_signal_server)

    refusal =
      try do
        invoke(Interrupt, :install_prepared, [fixture.attachment, @grace, unmoved])
      after
        Process.register(manager, :erl_signal_server)
      end

    assert assert_refused(refusal) == :prepared_activation_not_installed
    refute Interrupt in :gen_event.which_handlers(:erl_signal_server)

    # Nothing moved, so this process is still the holder and the owner still
    # admits it here. Giving it up is how that is proved without starting work.
    assert :ok = invoke(Loopex, :abandon_resume, [unmoved])

    assert {:ok, {:prepared, moved}} =
             invoke(Loopex, :prepare_resume_known_session, [
               fixture.state_root,
               fixture.runtime,
               fixture.session_id,
               "prepare-handoff-answer-acknowledged"
             ])

    assert :ok = invoke(Interrupt, :install_prepared, [fixture.attachment, @grace, moved])

    assert assert_refused(invoke(Loopex, :activate_resume, [moved])) ==
             :resume_activation_holder_mismatch

    Process.sleep(100)
    assert length(Loopex.AgentLoopTestModel.dispatched(fixture.model)) == 1
  end

  # Concept: a handler that goes away leaves the recovered work paused for good
  # rather than paused with nobody able to say so.
  #
  # Technical depth: installing again removes the previous handler, and the
  # removed handler used to drop its copy of the activation while the owner went
  # on recording the old holder. The capability stayed `:prepared`, no live
  # process could present it, and nothing would ever settle it -- a session
  # paused with no remaining move for the operator. The holder the owner
  # acknowledged is stopped with the handler now, and the owner's monitor of it
  # is what turns removal into a permanent, truthful abandonment.
  test "a handler removed after the handoff leaves no prepared capability behind" do
    fixture = recovered_fixture("handler-removed", :active)

    assert {:ok, {:prepared, activation}} =
             invoke(Loopex, :prepare_resume_known_session, [
               fixture.state_root,
               fixture.runtime,
               fixture.session_id,
               "prepare-handler-removed"
             ])

    assert :ok = invoke(Interrupt, :install_prepared, [fixture.attachment, @grace, activation])
    assert :ok = invoke(Interrupt, :install, [fixture.attachment, @grace])

    assert await_settled_capability(activation, :resume_activation_abandoned),
           "the removed handler left a capability the owner still records as prepared"

    Process.sleep(100)
    assert length(Loopex.AgentLoopTestModel.dispatched(fixture.model)) == 1
  end

  # Concept: an abrupt signal-manager loss cannot leave a prepared capability
  # held by a process that no signal handler can reach.
  #
  # Technical depth: a manager crash does not invoke the handler's termination
  # callback. The test temporarily gives the well-known name to an isolated
  # event manager, completes the real prepared handoff through it, and kills
  # only that manager. The holder's independent guard must then end the holder,
  # allowing the session owner's existing monitor to abandon the still-prepared
  # capability. The emulator's actual signal manager is never killed and is
  # restored before any assertion leaves the protected block.
  test "signal manager loss cannot strand its prepared holder" do
    fixture = recovered_fixture("signal-manager-holder", :active)

    assert {:ok, {:prepared, activation}} =
             invoke(Loopex, :prepare_resume_known_session, [
               fixture.state_root,
               fixture.runtime,
               fixture.session_id,
               "prepare-signal-manager-holder"
             ])

    actual_manager = Process.whereis(:erl_signal_server)
    assert is_pid(actual_manager)
    assert {:ok, isolated_manager} = :gen_event.start()
    Process.unlink(isolated_manager)
    Process.unregister(:erl_signal_server)

    try do
      assert Process.register(isolated_manager, :erl_signal_server)
      assert :ok = invoke(Interrupt, :install_prepared, [fixture.attachment, @grace, activation])

      manager_monitor = Process.monitor(isolated_manager)
      Process.exit(isolated_manager, :kill)
      assert_receive {:DOWN, ^manager_monitor, :process, ^isolated_manager, :killed}, 1_000
    after
      case Process.whereis(:erl_signal_server) do
        ^isolated_manager -> Process.unregister(:erl_signal_server)
        _other -> :ok
      end

      if Process.alive?(isolated_manager), do: Process.exit(isolated_manager, :kill)

      if is_nil(Process.whereis(:erl_signal_server)),
        do: Process.register(actual_manager, :erl_signal_server)
    end

    assert await_settled_capability(activation, :resume_activation_abandoned),
           "the dead signal manager left its prepared holder alive"

    Process.sleep(100)
    assert length(Loopex.AgentLoopTestModel.dispatched(fixture.model)) == 1
  end

  # Concept: replacing a prepared handler cannot report success while its prior
  # holder is still presenting the capability to the session owner.
  #
  # Technical depth: handler termination used to enqueue `:loopex_prepared_release`
  # and return immediately. If the holder was already blocked in
  # `activate_resume/1`, the replacement was installed and reported before that
  # presentation had even been decided; releasing the coordinator afterwards
  # could then spend the old capability behind the successful replacement. The
  # coordinator is suspended only to establish that ordering without a timing
  # race. Replacement must remain pending until the earlier presentation and
  # holder have both settled.
  test "handler replacement drains an in flight prepared presentation before it succeeds" do
    fixture = recovered_fixture("handler-replacement-drain", :active)

    assert {:ok, {:prepared, activation}} =
             invoke(Loopex, :prepare_resume_known_session, [
               fixture.state_root,
               fixture.runtime,
               fixture.session_id,
               "prepare-handler-replacement-drain"
             ])

    assert :ok = invoke(Interrupt, :install_prepared, [fixture.attachment, @grace, activation])

    coordinator = coordinator_of(fixture.runtime)
    :erlang.suspend_process(coordinator)

    presentation = Task.async(fn -> invoke(Interrupt, :activate_prepared, [activation]) end)
    capability = activation.capability

    try do
      assert queued_activation?(coordinator, capability),
             "the prepared presentation never reached the suspended coordinator"

      replacement =
        Task.async(fn -> invoke(Interrupt, :install, [fixture.attachment, @grace]) end)

      refute Task.yield(replacement, 250),
             "handler replacement succeeded while its predecessor was still presenting"

      :erlang.resume_process(coordinator)

      assert {:ok, {:ok, session_id}} = Task.yield(presentation, 10_000)
      assert session_id == fixture.session_id
      assert {:ok, :ok} = Task.yield(replacement, 10_000)
    after
      if suspended?(coordinator), do: :erlang.resume_process(coordinator)
    end

    assert_refused(invoke(Interrupt, :activate_prepared, [activation]))
  end

  # Concept: replacing a prepared handler never creates an interval in which an
  # operator interrupt has nobody to receive it.
  #
  # Technical depth: the predecessor holder is blocked in a real activation
  # call while the coordinator is suspended, so replacement cannot finish. A
  # signal delivered in that established drain window must still reach an
  # installed handler and queue its abort at the same coordinator. Deleting the
  # predecessor before installing its successor loses the signal and leaves no
  # abort call in the mailbox, even though the simpler drain test above remains
  # green.
  test "handler replacement keeps interrupt coverage while its predecessor drains" do
    fixture = recovered_fixture("handler-replacement-signal", :active)

    assert {:ok, {:prepared, activation}} =
             invoke(Loopex, :prepare_resume_known_session, [
               fixture.state_root,
               fixture.runtime,
               fixture.session_id,
               "prepare-handler-replacement-signal"
             ])

    assert :ok = invoke(Interrupt, :install_prepared, [fixture.attachment, @grace, activation])

    coordinator = coordinator_of(fixture.runtime)
    :erlang.suspend_process(coordinator)

    presentation = Task.async(fn -> invoke(Interrupt, :activate_prepared, [activation]) end)
    capability = activation.capability

    try do
      assert queued_activation?(coordinator, capability),
             "the prepared presentation never reached the suspended coordinator"

      replacement =
        Task.async(fn -> invoke(Interrupt, :install, [fixture.attachment, @grace]) end)

      refute Task.yield(replacement, 250),
             "handler replacement did not remain in the established drain window"

      assert await_handler_terminal(replacement.pid),
             "the successor handler was not installed before its predecessor drain"

      :gen_event.notify(:erl_signal_server, :sigterm)

      assert queued_abort?(coordinator),
             "an interrupt delivered during replacement reached no installed handler"

      :erlang.resume_process(coordinator)

      assert {:ok, {:ok, session_id}} = Task.yield(presentation, 10_000)
      assert session_id == fixture.session_id
      assert {:ok, :ok} = Task.yield(replacement, 10_000)
    after
      if suspended?(coordinator), do: :erlang.resume_process(coordinator)
    end
  end

  # Concept: concurrent replacements all wait for the oldest presentation they
  # supersede; a later installer cannot route around an earlier drain.
  #
  # Technical depth: the first successor is proved installed while its caller is
  # still waiting for the prepared predecessor. A second installation started
  # then must remain behind the complete first transaction. Serializing only
  # each event-manager call lets it replace the first successor, observe no
  # holder of its own, and report success while the original presentation is
  # still blocked.
  test "concurrent handler replacements cannot outrun the oldest prepared holder" do
    fixture = recovered_fixture("concurrent-handler-replacement", :active)

    assert {:ok, {:prepared, activation}} =
             invoke(Loopex, :prepare_resume_known_session, [
               fixture.state_root,
               fixture.runtime,
               fixture.session_id,
               "prepare-concurrent-handler-replacement"
             ])

    assert :ok = invoke(Interrupt, :install_prepared, [fixture.attachment, @grace, activation])

    coordinator = coordinator_of(fixture.runtime)
    :erlang.suspend_process(coordinator)

    presentation = Task.async(fn -> invoke(Interrupt, :activate_prepared, [activation]) end)
    capability = activation.capability

    try do
      assert queued_activation?(coordinator, capability),
             "the prepared presentation never reached the suspended coordinator"

      first = Task.async(fn -> invoke(Interrupt, :install, [fixture.attachment, @grace]) end)

      assert await_handler_terminal(first.pid),
             "the first successor was not installed before its predecessor drain"

      refute Task.yield(first, 250),
             "the first replacement did not remain in the established drain window"

      second = Task.async(fn -> invoke(Interrupt, :install, [fixture.attachment, @grace]) end)

      refute Task.yield(second, 250),
             "a concurrent replacement outran the oldest prepared holder"

      :erlang.resume_process(coordinator)

      assert {:ok, {:ok, session_id}} = Task.yield(presentation, 10_000)
      assert session_id == fixture.session_id
      assert {:ok, :ok} = Task.yield(first, 10_000)
      assert {:ok, :ok} = Task.yield(second, 10_000)
    after
      if suspended?(coordinator), do: :erlang.resume_process(coordinator)
    end
  end

  # Concept: installing a new attachment cannot erase a stop this process has
  # already begun or turn the next interrupt into a second stop.
  #
  # Technical depth: the abort worker is held inside its real Store admission
  # after the handler has fixed one command identity and armed one backstop. A
  # replacement then crosses the public installation entry. The current handler
  # must remain installed with the same abort and backstop; checking before a
  # separate swap is insufficient because the signal can arrive between them.
  # A second signal must still join that one admission, proved after releasing
  # the transaction by the single interrupt-shaped durable command.
  test "handler replacement cannot discard an in flight interrupt" do
    fixture = recovered_fixture("replacement-active-interrupt", :running)
    store_pid = fixture.store_pid

    assert :ok = invoke(Interrupt, :install, [fixture.attachment, @grace])

    :ok =
      M1RuntimeTestStore.hold_next_record_before_linearization(
        store_pid,
        "command_admitted",
        self()
      )

    :gen_event.notify(:erl_signal_server, :sigterm)

    assert_receive {:record_held_before_linearization, waiter, ^store_pid, "command_admitted",
                    _held},
                   5_000

    [before] = interrupt_handler_states()
    assert %{command_id: command_id} = before.abort
    assert is_pid(before.backstop) and Process.alive?(before.backstop)

    replacement =
      Task.async(fn -> invoke(Interrupt, :install, [fixture.attachment, @grace]) end)

    assert {:ok, :ok} = Task.yield(replacement, 5_000)

    [after_replacement] = interrupt_handler_states()
    assert after_replacement.abort.command_id == command_id
    assert after_replacement.backstop == before.backstop
    assert after_replacement.terminal == before.terminal

    :gen_event.sync_notify(:erl_signal_server, :sigterm)
    [after_second_signal] = interrupt_handler_states()
    assert after_second_signal.abort.command_id == command_id
    assert after_second_signal.backstop == before.backstop

    M1RuntimeTestStore.release(waiter)

    assert await_interrupt_admission(fixture),
           "the retained interrupt did not reach durable admission"

    assert Enum.count(records(fixture), fn record ->
             record.payload[:kind] == "command_admitted" and
               String.starts_with?(record.payload["command_id"] || "", "interrupt-")
           end) == 1
  end

  # Concept: the obligation to drain an older prepared presentation belongs to
  # the installed handler, not to the particular process that started replacing
  # it.
  #
  # Technical depth: the first installer is proved to have swapped its successor
  # in and to be blocked awaiting the old holder, then is killed. A caller-owned
  # lock disappears with that process, so a later installer can proceed; it may
  # report success only after inheriting and draining the same old holder. An
  # implementation that takes the predecessor pid out of handler state before
  # waiting loses the only durable reference at the kill and completes the next
  # installation while the old presentation remains live.
  test "installer death cannot discard an unfinished predecessor drain" do
    fixture = recovered_fixture("installer-death-drain", :active)

    assert {:ok, {:prepared, activation}} =
             invoke(Loopex, :prepare_resume_known_session, [
               fixture.state_root,
               fixture.runtime,
               fixture.session_id,
               "prepare-installer-death-drain"
             ])

    assert :ok = invoke(Interrupt, :install_prepared, [fixture.attachment, @grace, activation])

    coordinator = coordinator_of(fixture.runtime)
    :erlang.suspend_process(coordinator)

    presentation = Task.async(fn -> invoke(Interrupt, :activate_prepared, [activation]) end)
    capability = activation.capability
    parent = self()

    try do
      assert queued_activation?(coordinator, capability),
             "the prepared presentation never reached the suspended coordinator"

      {installer, installer_monitor} =
        spawn_monitor(fn ->
          send(
            parent,
            {:installer_result, invoke(Interrupt, :install, [fixture.attachment, @grace])}
          )
        end)

      assert await_handler_terminal(installer),
             "the successor handler was not installed before the installer drain"

      assert await_installer_drain(installer),
             "the installer never began waiting for its predecessor holder"

      Process.exit(installer, :kill)
      assert_receive {:DOWN, ^installer_monitor, :process, ^installer, :killed}, 1_000
      refute_receive {:installer_result, _result}, 0

      replacement =
        Task.async(fn -> invoke(Interrupt, :install, [fixture.attachment, @grace]) end)

      assert await_handler_terminal(replacement.pid),
             "the replacement did not acquire the released installer transaction"

      refute Task.yield(replacement, 250),
             "replacement forgot the predecessor drain when its installer died"

      :erlang.resume_process(coordinator)

      assert {:ok, {:ok, session_id}} = Task.yield(presentation, 10_000)
      assert session_id == fixture.session_id
      assert {:ok, :ok} = Task.yield(replacement, 10_000)
    after
      if suspended?(coordinator), do: :erlang.resume_process(coordinator)
    end
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

  # Concept: a resume that could not start the recovered work does not walk away
  # leaving the session paused with nobody able to start it.
  #
  # Technical depth: not every refused activation settles the capability. An
  # abort that fenced it and a second presentation that found it spent are the
  # owner's final word already, but a refusal the owner gives for a reason of its
  # own -- a session it cannot answer for, an ownership it has since lost --
  # leaves the capability `:prepared`, and the command used to return there
  # having given up nothing. The handoff had moved the holder by then, so the
  # command could not abandon it directly either: only the handler's holder is
  # admitted. The refusal is forced through the command's own facade seam so the
  # case names the refusal rather than contriving the owner state that produces
  # it, and what is asserted is the owner's record afterwards.
  test "a refused resume activation gives the prepared capability up" do
    fixture = recovered_fixture("resume-refused-activation", :active)
    before = length(Loopex.AgentLoopTestModel.dispatched(fixture.model))
    test = self()
    starter = fn _options -> {:ok, fixture.runtime} end

    observer = fn
      Interrupt, :activate_prepared, [activation] ->
        send(test, {:refused_activation_of, activation})
        {:error, :session_unavailable}

      module, function, arguments ->
        apply(module, function, arguments)
    end

    Process.put(:"$loopex_cli_facade_observer", observer)

    output =
      try do
        capture_io(fn ->
          send(
            test,
            {:refused_resume_result,
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

    assert_receive {:refused_activation_of, activation}, 5_000
    assert_receive {:refused_resume_result, result}, 5_000

    # The operator is told what the activation refused, not what the giving up
    # answered afterwards.
    assert assert_refused(result) == :session_unavailable
    refute output =~ "prepared recovery contract"

    # `:resume_activation_holder_mismatch` here would mean the capability is
    # still prepared and still held by a process this command walked away from.
    assert await_settled_capability(activation, :resume_activation_abandoned),
           "the refused resume left a capability the owner still records as prepared"

    Process.sleep(100)
    assert length(Loopex.AgentLoopTestModel.dispatched(fixture.model)) == before
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

  # The owner learns that an acknowledged holder is gone through a monitor, and
  # a command gives a capability up in its own time, so the settled state is
  # waited for rather than read once. Presenting from here is what makes the
  # answer decisive: a capability still `:prepared` refuses this process as a
  # holder mismatch, so the expected answer can only be reached by the owner
  # actually settling it.
  defp await_settled_capability(activation, expected, attempts \\ 300)
  defp await_settled_capability(_activation, _expected, 0), do: false

  defp await_settled_capability(activation, expected, attempts) do
    if assert_refused(invoke(Loopex, :activate_resume, [activation])) == expected do
      true
    else
      Process.sleep(10)
      await_settled_capability(activation, expected, attempts - 1)
    end
  end

  defp queued_activation?(coordinator, capability, attempts \\ 300)
  defp queued_activation?(_coordinator, _capability, 0), do: false

  defp queued_activation?(coordinator, capability, attempts) do
    queued =
      case Process.info(coordinator, :messages) do
        {:messages, messages} ->
          Enum.any?(messages, fn
            {:"$gen_call", _from, {:activate_resume, _owner, ^capability}} -> true
            _other -> false
          end)

        nil ->
          false
      end

    if queued do
      true
    else
      Process.sleep(10)
      queued_activation?(coordinator, capability, attempts - 1)
    end
  end

  defp queued_abort?(coordinator, attempts \\ 300)
  defp queued_abort?(_coordinator, 0), do: false

  defp queued_abort?(coordinator, attempts) do
    queued =
      case Process.info(coordinator, :messages) do
        {:messages, messages} ->
          Enum.any?(messages, fn
            {:"$gen_call", _from, {:command, _owner, %{type: :abort}}} -> true
            _other -> false
          end)

        nil ->
          false
      end

    if queued do
      true
    else
      Process.sleep(10)
      queued_abort?(coordinator, attempts - 1)
    end
  end

  defp await_handler_terminal(terminal, attempts \\ 300)
  defp await_handler_terminal(_terminal, 0), do: false

  defp await_handler_terminal(terminal, attempts) do
    installed =
      :erl_signal_server
      |> :sys.get_state()
      |> Enum.any?(fn
        {Interrupt, _id, %{terminal: ^terminal}} -> true
        _other -> false
      end)

    if installed do
      true
    else
      Process.sleep(10)
      await_handler_terminal(terminal, attempts - 1)
    end
  end

  defp await_installer_drain(installer, attempts \\ 300)
  defp await_installer_drain(_installer, 0), do: false

  defp await_installer_drain(installer, attempts) do
    draining =
      case Process.info(installer, :current_stacktrace) do
        {:current_stacktrace, stacktrace} ->
          Enum.any?(stacktrace, fn
            {Interrupt, :await_released_holder, _arity_or_args, _location} -> true
            _other -> false
          end)

        nil ->
          false
      end

    if draining do
      true
    else
      Process.sleep(10)
      await_installer_drain(installer, attempts - 1)
    end
  end

  defp interrupt_handler_states do
    :erl_signal_server
    |> :sys.get_state()
    |> Enum.flat_map(fn
      {Interrupt, _id, state} -> [state]
      _other -> []
    end)
  end

  defp suspended?(process) do
    case Process.info(process, :status) do
      {:status, :suspended} -> true
      _other -> false
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
