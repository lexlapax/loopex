defmodule LoopexComposition.Ephemeral.LifecycleTest do
  @moduledoc false
  use ExUnit.Case, async: false

  alias LoopexComposition.Ephemeral
  alias LoopexComposition.Ephemeral.{OwnerActivation, SessionOwner}

  defmodule Policy do
    @moduledoc false
    def decide(_request), do: {:allow, nil}
  end

  defmodule Facade do
    @moduledoc false

    def create_session(_runtime, %{"surface" => "embedded"}, command_id: "create"),
      do: {:ok, "lifecycle-session"}

    def attach(runtime, "lifecycle-session", after_event_sequence: 0) do
      Process.put(:events, [])
      Process.put(:event_sequence, 0)

      {:ok,
       %Loopex.Attachment{
         runtime: runtime,
         session_id: "lifecycle-session",
         attachment_id: "a",
         incarnation_id: "i",
         snapshot: %{}
       }}
    end

    def session_status(_runtime, "lifecycle-session"),
      do:
        {:ok,
         %{
           status: :active,
           owner_epoch: 0,
           active_run_id: nil,
           pending_work_ids: [],
           cleanup_grace_ms: 5_000
         }}

    def command(_attachment, %{type: :prompt} = command) do
      send(test_pid(), {:facade_command, :prompt, command.content, self()})
      run_id = "run-" <> command.content
      Process.put(:run_id, run_id)

      enqueue(%{
        "command_id" => command.command_id,
        "run_id" => run_id,
        "content" => command.content,
        kind: "user.message_appended"
      })

      case command.content do
        "held" ->
          receive do
            :release_held_prompt -> :ok
          end

        "question" ->
          enqueue(%{
            "run_id" => run_id,
            "interaction_id" => "question-1",
            "turn" => 1,
            "tool_call_id" => "call-1",
            "prompt" => "Continue?",
            "choices" => [%{"id" => "yes", "label" => "Yes"}],
            "expires_at" => 1_800_000_000,
            kind: "interaction.requested"
          })

        _ ->
          enqueue(%{
            "run_id" => run_id,
            "content" => "answer: " <> command.content,
            kind: "assistant.message_appended"
          })

          finish(run_id, "completed")
      end

      {:accepted, command.command_id}
    end

    def command(_attachment, %{type: :interaction_answer} = command) do
      send(test_pid(), {:facade_command, :answer, command.choice_id, self()})
      run_id = Process.get(:run_id)

      enqueue(%{
        "run_id" => run_id,
        "content" => "choice: " <> command.choice_id,
        kind: "assistant.message_appended"
      })

      finish(run_id, "completed")
      {:accepted, command.command_id}
    end

    def command(_attachment, %{type: :abort} = command) do
      send(test_pid(), {:facade_command, :abort, nil, self()})
      finish(Process.get(:run_id), "cancelled")
      {:accepted, command.command_id}
    end

    def next_event(_attachment) do
      case :persistent_term.get({__MODULE__, :read_probe}, nil) do
        nil -> :ok
        counter -> :atomics.add_get(counter, 1, 1)
      end

      case Process.get(:events, []) do
        [event | rest] ->
          if event.kind == "run.finished" and
               :persistent_term.get({__MODULE__, :hold_terminal}, false) do
            send(test_pid(), {:terminal_poll_held, self()})

            receive do
              :release_terminal_poll -> :ok
            end
          end

          Process.put(:events, rest)
          {:ok, event}

        [] ->
          if :persistent_term.get({__MODULE__, :hold_empty_poll}, false) do
            send(test_pid(), {:empty_poll_held, self()})

            receive do
              :release_empty_poll -> :ok
            end
          end

          {:error, :empty}
      end
    end

    defp finish(run_id, outcome),
      do:
        enqueue(%{
          "run_id" => run_id,
          "outcome" => outcome,
          "cleanup_grace_ms" => 5_000,
          kind: "run.finished"
        })

    defp enqueue(event) do
      sequence = Process.get(:event_sequence) + 1
      Process.put(:event_sequence, sequence)
      Process.put(:events, Process.get(:events) ++ [Map.put(event, :event_sequence, sequence)])
    end

    defp test_pid, do: :persistent_term.get({__MODULE__, :test_pid})
  end

  setup do
    tmp = Path.join(System.tmp_dir!(), "loopex-lifecycle-#{System.unique_integer([:positive])}")
    File.mkdir!(tmp)
    :persistent_term.put({Facade, :test_pid}, self())

    on_exit(fn ->
      :persistent_term.erase({Facade, :test_pid})
      File.rm_rf!(tmp)
    end)

    {:ok, tmp: tmp}
  end

  test "a pre-grant timeout releases the mutation slot without reaching the facade", %{tmp: tmp} do
    session = start_session(tmp)
    {owner, actor} = owner_and_actor(session)
    suspend(actor)

    first = Task.async(fn -> Ephemeral.ask(session, "first", timeout: 100) end)

    assert %{admission: :pregrant, facade: %{stage: :await_ready} = facade} =
             await_active(owner, &match?(%{facade: %{stage: :await_ready}}, &1))

    assert {:error, :run_open} = Ephemeral.ask(session, "second")
    send(owner, {actor, make_ref(), :ready})
    send(owner, {self(), facade.reference, :ready})
    assert %{facade: %{stage: :await_ready}} = :sys.get_state(owner).session.active

    assert {:error, {:timeout, _}} = Task.await(first, 2_000)

    assert %{facade: %{stage: :cancelling}} =
             await_active(owner, &match?(%{facade: %{stage: :cancelling}}, &1))

    resume(actor)
    assert eventually(fn -> :sys.get_state(owner).session.active == nil end)
    refute_receive {:facade_command, :prompt, "first", _}
    assert :none = Ephemeral.last_result(session)
    assert {:ok, %{text: "answer: next"}} = Ephemeral.ask(session, "next")
    assert :ok = Ephemeral.stop_session(session)
  end

  test "borrower death before grant cancels only its command", %{tmp: tmp} do
    session = start_session(tmp)
    {owner, actor} = owner_and_actor(session)
    suspend(actor)

    {borrower, monitor} =
      spawn_monitor(fn ->
        Ephemeral.ask(session, "borrowed", timeout: 2_000)
      end)

    assert %{admission: :pregrant, facade: %{stage: :await_ready}} =
             await_active(owner, &match?(%{facade: %{stage: :await_ready}}, &1))

    Process.exit(borrower, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^borrower, :killed}

    assert %{facade: %{stage: :cancelling}} =
             await_active(owner, &match?(%{facade: %{stage: :cancelling}}, &1))

    resume(actor)
    assert eventually(fn -> :sys.get_state(owner).session.active == nil end)
    refute_receive {:facade_command, :prompt, "borrowed", _}
    assert {:ok, %{text: "answer: live"}} = Ephemeral.ask(session, "live")
    assert :ok = Ephemeral.stop_session(session)
  end

  test "a missing ready uses the handshake bound and never dispatches", %{tmp: tmp} do
    session = start_session(tmp)
    {owner, actor} = owner_and_actor(session)
    suspend(actor)

    ask = Task.async(fn -> Ephemeral.ask(session, "no-ready", timeout: 5_000) end)

    assert %{facade: %{stage: :await_ready}} =
             await_active(owner, &match?(%{facade: %{stage: :await_ready}}, &1))

    started = System.monotonic_time(:millisecond)

    assert %{facade: %{stage: :cancelling}} =
             await_active(owner, &match?(%{facade: %{stage: :cancelling}}, &1), 400)

    assert System.monotonic_time(:millisecond) - started >= 900
    resume(actor)
    assert {:error, :session_unavailable} = Task.await(ask, 7_000)
    refute_receive {:facade_command, :prompt, "no-ready", _}
    assert :ok = Ephemeral.stop_session(session)
  end

  test "stop before ready cancels the actor and no prompt is admitted", %{tmp: tmp} do
    session = start_session(tmp)
    {owner, actor} = owner_and_actor(session)
    suspend(actor)

    ask = Task.async(fn -> Ephemeral.ask(session, "pre-stop", timeout: 2_000) end)

    assert %{facade: %{stage: :await_ready}} =
             await_active(owner, &match?(%{facade: %{stage: :await_ready}}, &1))

    stop = Task.async(fn -> Ephemeral.stop_session(session) end)
    assert eventually(fn -> :sys.get_state(owner).phase == :stopping end)
    assert %{facade: %{stage: :cancelling}} = :sys.get_state(owner).session.active
    resume(actor)

    assert :ok = Task.await(stop, 7_000)
    assert {:error, :session_unavailable} = Task.await(ask, 7_000)
    refute_receive {:facade_command, :prompt, "pre-stop", _}
    assert :ok = Ephemeral.stop_session(session)
  end

  test "a granted prompt stays possibly admitted until the live actor returns", %{tmp: tmp} do
    session = start_session(tmp)
    {owner, actor} = owner_and_actor(session)
    ask = Task.async(fn -> Ephemeral.ask(session, "held", timeout: 2_000) end)
    assert_receive {:facade_command, :prompt, "held", ^actor}, 2_000

    assert %{admission: :granted, facade: %{stage: :dispatched} = facade} =
             :sys.get_state(owner).session.active

    send(owner, {actor, make_ref(), {:accepted, "forged"}})
    send(owner, {self(), facade.reference, {:accepted, "forged"}})

    assert %{admission: :granted, facade: %{stage: :dispatched}} =
             :sys.get_state(owner).session.active

    assert {:error, :run_open} = Ephemeral.ask(session, "second")

    stop = Task.async(fn -> Ephemeral.stop_session(session) end)
    assert eventually(fn -> :sys.get_state(owner).phase == :stopping end)
    assert %{possible: true, abort_sent: false} = :sys.get_state(owner).stop
    send(actor, :release_held_prompt)

    assert_receive {:facade_command, :abort, nil, ^actor}, 2_000
    assert :ok = Task.await(stop, 7_000)
    assert {:error, {:run, :cancelled, _}} = Task.await(ask, 7_000)
  end

  test "a second answer is refused before the first answer's grant", %{tmp: tmp} do
    session = start_session(tmp)
    {owner, actor} = owner_and_actor(session)

    assert {:error, {:interaction_pending, %{"interaction_id" => "question-1"}}} =
             Ephemeral.ask(session, "question")

    suspend(actor)
    answer = Task.async(fn -> Ephemeral.answer(session, "question-1", "yes") end)

    assert %{kind: :answer, admission: :pregrant, facade: %{stage: :await_ready}} =
             await_active(owner, &match?(%{kind: :answer, facade: %{stage: :await_ready}}, &1))

    assert {:error, :invalid_interaction_answer} =
             Ephemeral.answer(session, "question-1", "yes")

    assert {:error, :run_open} = Ephemeral.ask(session, "other")
    resume(actor)
    assert_receive {:facade_command, :answer, "yes", ^actor}, 2_000
    assert {:ok, %{text: "choice: yes"}} = Task.await(answer, 3_000)
    assert :ok = Ephemeral.stop_session(session)
  end

  test "a dead answer borrower does not cancel the sole interaction reader", %{tmp: tmp} do
    :persistent_term.put({Facade, :hold_empty_poll}, true)
    on_exit(fn -> :persistent_term.erase({Facade, :hold_empty_poll}) end)
    session = start_session(tmp)
    {owner, actor} = owner_and_actor(session)

    assert {:error, {:interaction_pending, %{"interaction_id" => "question-1"}}} =
             Ephemeral.ask(session, "question")

    assert_receive {:empty_poll_held, ^actor}, 2_000
    test = self()

    borrower =
      spawn(fn ->
        send(test, {:borrowed_answer, Ephemeral.answer(session, "question-1", "yes")})
      end)

    monitor = Process.monitor(borrower)

    assert %{kind: :answer, operation: :next_event, queued_command: %{type: :interaction_answer}} =
             await_active(owner, &match?(%{kind: :answer, queued_command: %{}}, &1))

    Process.exit(borrower, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^borrower, :killed}, 2_000
    :persistent_term.erase({Facade, :hold_empty_poll})
    send(actor, :release_empty_poll)

    assert eventually(fn ->
             match?(%{kind: :observe, queued_command: nil}, :sys.get_state(owner).session.active)
           end)

    assert {:ok, %{text: "choice: yes"}} = Ephemeral.answer(session, "question-1", "yes")
    assert_receive {:facade_command, :answer, "yes", ^actor}, 2_000
    refute_receive {:borrowed_answer, _}, 0
    assert :ok = Ephemeral.stop_session(session)
  end

  test "history reads committed entries during an active ask without another facade read", %{
    tmp: tmp
  } do
    session = start_session(tmp)
    {owner, actor} = owner_and_actor(session)
    reads = trace_facade_reads()
    :persistent_term.put({Facade, :hold_terminal}, true)
    on_exit(fn -> :persistent_term.erase({Facade, :hold_terminal}) end)

    ask = Task.async(fn -> Ephemeral.ask(session, "history-current", timeout: 3_000) end)
    assert_receive {:terminal_poll_held, ^actor}, 2_000

    assert %{
             kind: :ask,
             admission: :following,
             operation: :next_event,
             facade: %{stage: :dispatched}
           } =
             :sys.get_state(owner).session.active

    count = :atomics.get(reads, 1)

    assert {:ok,
            %{
              entries: [
                %{role: :user, text: "history-current"},
                %{role: :assistant, text: "answer: history-current"}
              ],
              truncated: false
            }} = Ephemeral.history(session)

    assert :atomics.get(reads, 1) == count
    assert nil == Task.yield(ask, 0)

    :persistent_term.erase({Facade, :hold_terminal})
    send(actor, :release_terminal_poll)
    assert {:ok, %{text: "answer: history-current"}} = Task.await(ask, 3_000)
    assert :ok = Ephemeral.stop_session(session)
  end

  test "history reads committed entries during an active answer without another facade read", %{
    tmp: tmp
  } do
    session = start_session(tmp)
    {owner, actor} = owner_and_actor(session)
    reads = trace_facade_reads()

    assert {:error, {:interaction_pending, %{"interaction_id" => "question-1"}}} =
             Ephemeral.ask(session, "question")

    :persistent_term.put({Facade, :hold_terminal}, true)
    on_exit(fn -> :persistent_term.erase({Facade, :hold_terminal}) end)

    answer = Task.async(fn -> Ephemeral.answer(session, "question-1", "yes") end)
    assert_receive {:terminal_poll_held, ^actor}, 2_000

    assert %{
             kind: :answer,
             admission: :following,
             operation: :next_event,
             facade: %{stage: :dispatched}
           } =
             :sys.get_state(owner).session.active

    count = :atomics.get(reads, 1)

    assert {:ok,
            %{
              entries: [
                %{role: :user, text: "question"},
                %{role: :assistant, text: "choice: yes"}
              ],
              truncated: false
            }} = Ephemeral.history(session)

    assert :atomics.get(reads, 1) == count
    assert nil == Task.yield(answer, 0)

    :persistent_term.erase({Facade, :hold_terminal})
    send(actor, :release_terminal_poll)
    assert {:ok, %{text: "choice: yes"}} = Task.await(answer, 3_000)
    assert :ok = Ephemeral.stop_session(session)
  end

  test "history reads committed entries during a timed-out ask's background drain", %{
    tmp: tmp
  } do
    session = start_session(tmp)
    {owner, actor} = owner_and_actor(session)
    reads = trace_facade_reads()

    ask = Task.async(fn -> Ephemeral.ask(session, "held", timeout: 1_000) end)
    assert_receive {:facade_command, :prompt, "held", ^actor}, 2_000
    send(actor, :release_held_prompt)

    assert eventually(fn ->
             match?(
               {:ok, %{entries: [%{role: :user, text: "held"}], truncated: false}},
               Ephemeral.history(session)
             )
           end)

    assert {:error, {:timeout, _}} = Task.await(ask, 2_000)

    :persistent_term.put({Facade, :hold_empty_poll}, true)
    on_exit(fn -> :persistent_term.erase({Facade, :hold_empty_poll}) end)
    assert_receive {:empty_poll_held, ^actor}, 1_000

    assert %{operation: :next_event, borrower: nil, facade: %{stage: :dispatched}} =
             :sys.get_state(owner).session.active

    count = :atomics.get(reads, 1)

    assert {:ok, %{entries: [%{role: :user, text: "held"}], truncated: false}} =
             Ephemeral.history(session)

    assert :atomics.get(reads, 1) == count
    assert {:error, :run_open} = Ephemeral.ask(session, "later")

    :persistent_term.erase({Facade, :hold_empty_poll})
    send(actor, :release_empty_poll)
    assert :ok = Ephemeral.stop_session(session)
  end

  test "an active owner crash leaves every public handle call unavailable", %{tmp: tmp} do
    session = start_session(tmp)
    {:loopex_ephemeral_session, owner, cell} = session
    {_owner, actor} = owner_and_actor(session)
    %{supervisor: supervisor, startup: startup} = :sys.get_state(owner)
    registered = startup.registered
    subtree_pids = Map.keys(startup.process_monitors)

    assert MapSet.new(subtree_pids) ==
             MapSet.new([
               startup.root,
               actor,
               registered.private_supervisor,
               registered.memory_store,
               registered.workspace_lease,
               registered.executor,
               registered.trace_capability,
               registered.runtime_holder,
               registered.runtime_supervisor
             ])

    assert Enum.all?(subtree_pids, &Process.alive?/1)
    subtree_monitors = Enum.map(subtree_pids, &{&1, Process.monitor(&1)})
    runtime_children = Supervisor.which_children(registered.runtime_supervisor)

    assert length(runtime_children) == 7

    assert MapSet.new(Enum.map(runtime_children, &elem(&1, 0))) ==
             MapSet.new([
               Loopex.ToolRegistry,
               Loopex.Runtime.Control,
               Loopex.Runtime.Workers,
               Loopex.Runtime.OwnerGroups,
               Loopex.Runtime.SessionSupervisor,
               Loopex.Runtime.EventDispatcher,
               Loopex.Trace
             ])

    runtime_child_monitors =
      Enum.map(runtime_children, fn {_id, pid, _type, _modules} ->
        assert is_pid(pid) and Process.alive?(pid)
        {pid, Process.monitor(pid)}
      end)

    ask = Task.async(fn -> Ephemeral.ask(session, "held", timeout: 7_000) end)
    assert_receive {:facade_command, :prompt, "held", ^actor}, 2_000

    assert %{kind: :ask, admission: :granted, facade: %{stage: :dispatched}} =
             :sys.get_state(owner).session.active

    monitor = Process.monitor(owner)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^owner, :killed}, 2_000

    Enum.each(subtree_monitors, fn {pid, child_monitor} ->
      assert_receive {:DOWN, ^child_monitor, :process, ^pid, _reason}, 3_000
    end)

    Enum.each(runtime_child_monitors, fn {pid, child_monitor} ->
      assert_receive {:DOWN, ^child_monitor, :process, ^pid, _reason}, 3_000
    end)

    assert eventually(fn -> DynamicSupervisor.which_children(supervisor) == [] end)
    assert :atomics.get(cell, 1) == 0
    assert {:error, :session_unavailable} = Task.await(ask, 2_000)
    assert {:error, :session_unavailable} = Ephemeral.ask(session, "")
    assert {:error, :session_unavailable} = Ephemeral.answer(session, "", "")
    assert {:error, :session_unavailable} = Ephemeral.last_result(session)
    assert {:error, :session_unavailable} = Ephemeral.history(session)
    assert {:error, :session_unavailable} = Ephemeral.stop_session(session)
  end

  test "creator exit seals a borrowed session and removes its root after cleanup", %{tmp: tmp} do
    test = self()

    creator =
      spawn(fn ->
        session = start_session(tmp, detach_supervisor: true, supervisor_recipient: test)
        {owner, _actor} = owner_and_actor(session)
        startup = :sys.get_state(owner).startup
        send(test, {:created, session, startup.owned_root.path, startup.process_monitors})
        receive do: (:creator_exit -> :ok)
      end)

    assert_receive {:detached_supervisor, supervisor}, 6_000
    on_exit(fn -> if Process.alive?(supervisor), do: Process.exit(supervisor, :shutdown) end)
    assert_receive {:created, session, root, subtree}, 6_000
    {:loopex_ephemeral_session, owner, cell} = session
    {_owner, actor} = owner_and_actor(session)
    owner_monitor = Process.monitor(owner)
    subtree_monitors = Enum.map(Map.keys(subtree), &{&1, Process.monitor(&1)})
    assert File.dir?(root)

    borrower = Task.async(fn -> Ephemeral.ask(session, "held", timeout: 7_000) end)
    assert_receive {:facade_command, :prompt, "held", ^actor}, 2_000

    assert %{admission: :granted, facade: %{stage: :dispatched}} =
             :sys.get_state(owner).session.active

    creator_monitor = Process.monitor(creator)
    send(creator, :creator_exit)
    assert_receive {:DOWN, ^creator_monitor, :process, ^creator, :normal}
    assert eventually(fn -> :atomics.get(cell, 1) == 1 end)
    assert Process.alive?(actor)
    assert File.dir?(root)
    assert {:error, :session_unavailable} = Ephemeral.ask(session, "after-creator-exit")

    send(actor, :release_held_prompt)
    assert_receive {:facade_command, :abort, nil, ^actor}, 2_000
    assert {:error, {:run, :cancelled, _}} = Task.await(borrower, 7_000)
    assert_receive {:DOWN, ^owner_monitor, :process, ^owner, :normal}, 7_000

    Enum.each(subtree_monitors, fn {pid, monitor} ->
      assert_receive {:DOWN, ^monitor, :process, ^pid, _}, 7_000
    end)

    assert :atomics.get(cell, 1) == 2
    refute File.exists?(root)
    assert {:error, :session_closed} = Ephemeral.last_result(session)
  end

  test "creator exit during a failed borrowed stop retires after the first cleanup attempt", %{
    tmp: tmp
  } do
    test = self()

    remove = fn path ->
      send(test, {:removal_entered, self(), path})

      receive do
        :release_removal -> {:error, :eacces}
      end
    end

    creator =
      spawn(fn ->
        session =
          start_session(tmp,
            detach_supervisor: true,
            supervisor_recipient: test,
            rm_rf: remove
          )

        {owner, _actor} = owner_and_actor(session)
        root = :sys.get_state(owner).startup.owned_root.path
        send(test, {:created, session, root})
        receive do: (:creator_exit -> :ok)
      end)

    assert_receive {:detached_supervisor, supervisor}, 6_000
    on_exit(fn -> if Process.alive?(supervisor), do: Process.exit(supervisor, :shutdown) end)
    assert_receive {:created, session, root}, 6_000
    {:loopex_ephemeral_session, owner, cell} = session
    owner_monitor = Process.monitor(owner)
    stop = Task.async(fn -> Ephemeral.stop_session(session) end)

    assert_receive {:removal_entered, worker, ^root}, 3_000

    assert %{phase: :aborting, abort: %{stage: :root_removal}, stop: %{no_retry: false}} =
             :sys.get_state(owner)

    creator_monitor = Process.monitor(creator)
    send(creator, :creator_exit)
    assert_receive {:DOWN, ^creator_monitor, :process, ^creator, :normal}
    assert eventually(fn -> :sys.get_state(owner).stop.no_retry end, 50)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        send(worker, :release_removal)

        assert {:error,
                {:cleanup_unproved,
                 %{
                   pending: [:root_removal],
                   root: ^root,
                   root_ownership: :owned,
                   ending: :none,
                   cause: nil
                 }}} = Task.await(stop, 7_000)

        assert_receive {:DOWN, ^owner_monitor, :process, ^owner, :normal}, 7_000
      end)

    assert log =~ "ephemeral cleanup unproved root=#{inspect(root)} pending=[:root_removal]"
    assert File.dir?(root)
    assert :atomics.get(cell, 1) == 3
    assert {:error, :session_unavailable} = Ephemeral.stop_session(session)
  end

  test "creator exit and a concurrent stop remove the same owned root", %{tmp: tmp} do
    test = self()

    creator =
      spawn(fn ->
        session = start_session(tmp, detach_supervisor: true, supervisor_recipient: test)
        {owner, _actor} = owner_and_actor(session)
        startup = :sys.get_state(owner).startup
        send(test, {:created, session, startup.owned_root.path, self()})
        receive do: (:creator_exit -> :ok)
      end)

    assert_receive {:detached_supervisor, supervisor}, 6_000
    on_exit(fn -> if Process.alive?(supervisor), do: Process.exit(supervisor, :shutdown) end)
    assert_receive {:created, session, root, ^creator}, 6_000
    {:loopex_ephemeral_session, owner, cell} = session
    assert File.dir?(root)
    true = :erlang.suspend_process(owner)

    on_exit(fn ->
      if Process.alive?(owner) and Process.info(owner, :status) == {:status, :suspended},
        do: :erlang.resume_process(owner)
    end)

    stop_ref = make_ref()
    send(owner, {self(), stop_ref, :public, :stop})
    monitor = Process.monitor(creator)
    send(creator, :creator_exit)
    assert_receive {:DOWN, ^monitor, :process, ^creator, :normal}
    true = :erlang.resume_process(owner)

    assert_receive {^owner, ^stop_ref, :ok}, 7_000
    assert :atomics.get(cell, 1) == 2
    refute File.exists?(root)
    assert :ok = Ephemeral.stop_session(session)
  end

  test "a stop joining creator-exit cleanup gets the same proof", %{tmp: tmp} do
    test = self()

    creator =
      spawn(fn ->
        session = start_session(tmp, detach_supervisor: true, supervisor_recipient: test)
        {owner, _actor} = owner_and_actor(session)
        startup = :sys.get_state(owner).startup
        send(test, {:created, session, startup.owned_root.path, self()})
        receive do: (:creator_exit -> :ok)
      end)

    assert_receive {:detached_supervisor, supervisor}, 6_000
    on_exit(fn -> if Process.alive?(supervisor), do: Process.exit(supervisor, :shutdown) end)
    assert_receive {:created, session, root, ^creator}, 6_000
    {:loopex_ephemeral_session, owner, cell} = session
    true = :erlang.suspend_process(owner)

    on_exit(fn ->
      if Process.alive?(owner) and Process.info(owner, :status) == {:status, :suspended},
        do: :erlang.resume_process(owner)
    end)

    monitor = Process.monitor(creator)
    send(creator, :creator_exit)
    assert_receive {:DOWN, ^monitor, :process, ^creator, :normal}
    stop_ref = make_ref()
    send(owner, {self(), stop_ref, :public, :stop})
    true = :erlang.resume_process(owner)

    assert_receive {^owner, ^stop_ref, :ok}, 7_000
    assert :atomics.get(cell, 1) == 2
    refute File.exists?(root)
    assert :ok = Ephemeral.stop_session(session)
  end

  test "an unresponsive owner cannot hold a public stop caller forever", %{tmp: tmp} do
    session = start_session(tmp)
    {:loopex_ephemeral_session, owner, _cell} = session
    true = :erlang.suspend_process(owner)

    on_exit(fn ->
      if Process.alive?(owner) and Process.info(owner, :status) == {:status, :suspended},
        do: :erlang.resume_process(owner)
    end)

    started = System.monotonic_time(:millisecond)
    assert {:error, :session_unavailable} = Ephemeral.stop_session(session)
    elapsed = System.monotonic_time(:millisecond) - started
    assert elapsed >= 11_000 and elapsed < 12_500

    true = :erlang.resume_process(owner)
    assert :ok = Ephemeral.stop_session(session)
    refute_receive {^owner, _reference, _late_reply}, 0
  end

  test "a stop requester retires when its borrower dies", %{tmp: tmp} do
    session = start_session(tmp)
    {:loopex_ephemeral_session, owner, _cell} = session
    true = :erlang.suspend_process(owner)

    on_exit(fn ->
      if Process.alive?(owner) and Process.info(owner, :status) == {:status, :suspended},
        do: :erlang.resume_process(owner)
    end)

    borrower = spawn(fn -> Ephemeral.stop_session(session) end)
    requester = await_stop_requester(borrower, System.monotonic_time(:millisecond) + 1_000)
    requester_monitor = Process.monitor(requester)
    Process.exit(borrower, :kill)
    assert_receive {:DOWN, ^requester_monitor, :process, ^requester, :normal}, 1_000

    true = :erlang.resume_process(owner)
    assert :ok = Ephemeral.stop_session(session)
  end

  defp await_stop_requester(borrower, deadline) do
    {:monitors, monitors} = Process.info(borrower, :monitors)

    case Enum.find(monitors, fn
           {:process, pid} when is_pid(pid) -> true
           _ -> false
         end) do
      {:process, requester} ->
        requester

      nil ->
        if System.monotonic_time(:millisecond) >= deadline do
          flunk("stop requester was not monitored")
        else
          Process.sleep(10)
          await_stop_requester(borrower, deadline)
        end
    end
  end

  defp start_session(tmp, options \\ []) do
    {:ok, _digest, manifest} =
      Loopex.ResourcePack.digest(%{
        "version" => "loopex.resource_pack/1",
        "workspace_ref" => "workspace-ref",
        "revision" => nil,
        "packs" => []
      })

    temp_root =
      if options[:rm_rf],
        do: %{tmp: fn -> tmp end, rm_rf: options[:rm_rf]},
        else: %{tmp: fn -> tmp end}

    configuration = %{
      cwd: tmp,
      model: "ollama:test",
      provider: %{credential_variable: nil},
      base_url: "http://localhost:11434",
      policy: Policy,
      tools: :read_only,
      skills: %{manifest: manifest, shadowed_skills: []},
      max_steps: 16,
      deadline_ms: 60_000,
      max_tokens: 128,
      context_token_budget: 8_192,
      timeout: 60_000,
      test_facade: Facade,
      test_seams: %{
        temp_root: temp_root,
        group_attest: fn _executor, _instance, _nonce, _deadline -> :ok end,
        group_drain: fn executor, instance, owner, nonce, _deadline ->
          send(owner, {executor, instance, nonce, :groups_empty})
          {:ok, nonce}
        end
      }
    }

    {:ok, supervisor} = DynamicSupervisor.start_link(strategy: :one_for_one)

    if options[:detach_supervisor] do
      Process.unlink(supervisor)
      send(options[:supervisor_recipient], {:detached_supervisor, supervisor})
    end

    {:ok, activation} = OwnerActivation.start(supervisor)
    owner = OwnerActivation.owner(activation)
    {:ok, cell} = OwnerActivation.begin(activation)
    assert {:ok, :session_ready} = SessionOwner.start_session(owner, configuration, 6_000)
    {:loopex_ephemeral_session, owner, cell}
  end

  defp owner_and_actor({:loopex_ephemeral_session, owner, _cell}) do
    actor = :sys.get_state(owner).startup.registered.facade_client
    {owner, actor}
  end

  defp suspend(pid) do
    true = :erlang.suspend_process(pid)

    on_exit(fn ->
      if Process.alive?(pid) and Process.info(pid, :status) == {:status, :suspended},
        do: :erlang.resume_process(pid)
    end)
  end

  defp resume(pid), do: true = :erlang.resume_process(pid)

  defp trace_facade_reads do
    counter = :atomics.new(1, [])
    :persistent_term.put({Facade, :read_probe}, counter)
    on_exit(fn -> :persistent_term.erase({Facade, :read_probe}) end)
    counter
  end

  defp await_active(owner, predicate, attempts \\ 200) do
    assert eventually(fn -> predicate.(:sys.get_state(owner).session.active) end, attempts)
    :sys.get_state(owner).session.active
  end

  defp eventually(predicate, attempts \\ 200)
  defp eventually(_predicate, 0), do: false

  defp eventually(predicate, attempts) do
    if predicate.() do
      true
    else
      Process.sleep(5)
      eventually(predicate, attempts - 1)
    end
  end
end
