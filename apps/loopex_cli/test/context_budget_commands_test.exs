Code.require_file("../../loopex/test/support/m1_runtime_helper.exs", __DIR__)
Code.require_file("../../loopex/test/support/agent_loop_helper.exs", __DIR__)

defmodule LoopexCli.ContextBudgetCommandsTest do
  @moduledoc false

  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Loopex.AgentLoopTestExecutor
  alias Loopex.AgentLoopTestModel
  alias Loopex.M1RuntimeTestStore
  alias Loopex.Runtime
  alias LoopexCli.Interrupt
  alias LoopexCli.Render

  @cleanup_grace 137
  @context_budget 321
  @uint64_max 18_446_744_073_709_551_615
  @uint64_overflow "18446744073709551616"

  setup do
    on_exit(fn ->
      restore_signal_handlers()
      _ = LoopexCli.release_placement()
    end)

    :ok
  end

  test "the reference commands default only omission and reject or forward one top-level context budget" do
    invalid_values = [
      ["--context-token-budget"],
      ["--context-token-budget", "not-a-number"],
      ["--context-token-budget", "0"],
      ["--context-token-budget", "-1"],
      ["--context-token-budget", @uint64_overflow],
      ["--context-token-budget", "1", "--context-token-budget", "2"]
    ]

    for command <- ~w(run resume cancel),
        {argv, index} <- Enum.with_index(invalid_values) do
      {state_root, workspace} = roots("invalid-option-#{command}-#{index}")

      command_argv =
        case command do
          "run" -> ["run"]
          resumed -> [resumed, "session-invalid-context-budget"]
        end

      assert {:error, message} =
               LoopexCli.dispatch(
                 command_argv ++
                   [
                     "--policy",
                     "allow-all",
                     "--state-root",
                     state_root,
                     "--workspace",
                     workspace
                   ] ++ argv ++ if(command == "run", do: ["do not start"], else: []),
                 runtime_starter: fn _options ->
                   flunk("an invalid context budget reached Runtime")
                 end
               )

      assert message =~ "--context-token-budget"
      assert :ok = LoopexCli.release_placement()
    end

    {omitted_root, omitted_workspace} = roots("omitted-option")
    test = self()

    assert {:error, :stop_after_context_option_capture} =
             LoopexCli.dispatch(
               [
                 "run",
                 "--policy",
                 "allow-all",
                 "--state-root",
                 omitted_root,
                 "--workspace",
                 omitted_workspace,
                 "capture omission"
               ],
               runtime_starter: fn options ->
                 send(test, {:omitted_context_runtime_options, options})
                 {:error, :stop_after_context_option_capture}
               end
             )

    assert_receive {:omitted_context_runtime_options, omitted_options}
    refute Keyword.has_key?(omitted_options, :context_token_budget)
    assert :ok = LoopexCli.release_placement()

    {state_root, workspace} = roots("explicit-option")

    assert {:error, :stop_after_context_option_capture} =
             LoopexCli.dispatch(
               [
                 "run",
                 "--policy",
                 "allow-all",
                 "--state-root",
                 state_root,
                 "--workspace",
                 workspace,
                 "--context-token-budget",
                 "4096",
                 "capture explicit"
               ],
               runtime_starter: fn options ->
                 send(test, {:context_runtime_options, options})
                 {:error, :stop_after_context_option_capture}
               end
             )

    assert_receive {:context_runtime_options, options}
    assert Keyword.fetch!(options, :context_token_budget) == 4_096
    refute options |> Keyword.get(:bounds, []) |> Keyword.has_key?(:context_token_budget)

    {maximum_root, maximum_workspace} = roots("maximum-option")

    assert {:error, :stop_after_context_option_capture} =
             LoopexCli.dispatch(
               [
                 "run",
                 "--policy",
                 "allow-all",
                 "--state-root",
                 maximum_root,
                 "--workspace",
                 maximum_workspace,
                 "--context-token-budget",
                 Integer.to_string(@uint64_max),
                 "capture maximum"
               ],
               runtime_starter: fn maximum_options ->
                 send(test, {:maximum_context_runtime_options, maximum_options})
                 {:error, :stop_after_context_option_capture}
               end
             )

    assert_receive {:maximum_context_runtime_options, maximum_options}
    assert Keyword.fetch!(maximum_options, :context_token_budget) == @uint64_max
    refute maximum_options |> Keyword.get(:bounds, []) |> Keyword.has_key?(:context_token_budget)
  end

  test "CLI renders only the exact safe context failure projection" do
    private_descriptor = "private-descriptor-\e]52;c;must-not-render\a"

    terminal = %{
      "outcome" => "failed",
      "failure" => %{
        "category" => "context_budget_exceeded",
        "retryable" => false,
        "dimension" => "context_tokens",
        "observed" => 9,
        "limit" => 8,
        "private_descriptor" => private_descriptor
      },
      "source_reference" => private_descriptor,
      "content" => private_descriptor,
      kind: "run.finished",
      event_sequence: 1
    }

    {:ok, source} = Agent.start_link(fn -> [terminal] end)
    on_exit(fn -> stop(source) end)

    next_event = fn _attachment ->
      Agent.get_and_update(source, fn
        [event | rest] -> {{:ok, event}, rest}
        [] -> {:absent, []}
      end)
    end

    parent = self()

    stdout =
      capture_io(fn ->
        stderr =
          capture_io(:stderr, fn ->
            assert :ok = Render.stream(:context_failure, next_event: next_event)
          end)

        send(parent, {:context_failure_stderr, stderr})
      end)

    assert_receive {:context_failure_stderr, stderr}
    assert stdout == ""
    assert stderr =~ "context_budget_exceeded"
    assert stderr =~ "false"
    assert stderr =~ "context_tokens"
    assert stderr =~ "9"
    assert stderr =~ "8"
    refute stderr =~ "private-descriptor"
    refute stderr =~ "source_reference"
    refute stderr =~ "private_descriptor"
    refute stderr =~ "\e"
  end

  test "resume recovers an omitted or equal active context and abandons an unequal owner before dispatch" do
    for {label, explicit} <- [{"omitted", nil}, {"equal", @context_budget}] do
      fixture = active_fixture("resume-#{label}")
      before = length(AgentLoopTestModel.dispatched(fixture.model))

      output =
        capture_io(fn ->
          assert :ok = dispatch_context_command(:resume, fixture, explicit)
        end)

      assert output =~ "context resume completed"
      assert length(AgentLoopTestModel.dispatched(fixture.model)) == before + 1
      assert :ok = LoopexCli.release_placement()
      restore_signal_handlers()
    end

    conflict = active_fixture("resume-conflict")
    before = length(AgentLoopTestModel.dispatched(conflict.model))

    assert {:error, :context_token_budget_configuration_conflict} =
             dispatch_context_command(:resume, conflict, @context_budget + 1)

    assert length(AgentLoopTestModel.dispatched(conflict.model)) == before
    refute abort_admitted?(conflict)

    both = active_fixture("resume-cleanup-first")

    assert {:error, cleanup_conflict} =
             dispatch_context_command(:resume, both, @context_budget + 1,
               cleanup_grace_ms: @cleanup_grace + 1
             )

    assert inspect(cleanup_conflict) =~ "cleanup"
    refute inspect(cleanup_conflict) =~ "context_token_budget"
    assert length(AgentLoopTestModel.dispatched(both.model)) == 0
    refute abort_admitted?(both)
  end

  test "cancel recovers an omitted or equal active context and refuses an unequal owner before abort" do
    for {label, explicit} <- [{"omitted", nil}, {"equal", @context_budget}] do
      fixture = active_fixture("cancel-#{label}")
      before = length(AgentLoopTestModel.dispatched(fixture.model))

      output =
        capture_io(:stderr, fn ->
          assert :ok = dispatch_context_command(:cancel, fixture, explicit)
        end)

      assert output =~ "loopex: cancelled"
      assert length(AgentLoopTestModel.dispatched(fixture.model)) == before
      assert abort_admitted?(fixture)
      assert :ok = LoopexCli.release_placement()
    end

    conflict = active_fixture("cancel-conflict")
    before = length(AgentLoopTestModel.dispatched(conflict.model))

    assert {:error, :context_token_budget_configuration_conflict} =
             dispatch_context_command(:cancel, conflict, @context_budget + 1)

    assert length(AgentLoopTestModel.dispatched(conflict.model)) == before
    refute abort_admitted?(conflict)

    both = active_fixture("cancel-cleanup-first")

    assert {:error, cleanup_conflict} =
             dispatch_context_command(:cancel, both, @context_budget + 1,
               cleanup_grace_ms: @cleanup_grace + 1
             )

    assert inspect(cleanup_conflict) =~ "cleanup"
    refute inspect(cleanup_conflict) =~ "context_token_budget"
    assert length(AgentLoopTestModel.dispatched(both.model)) == 0
    refute abort_admitted?(both)
  end

  test "resume and cancel report context conflict owner unconfirmed before activation or abort" do
    for command <- [:resume, :cancel] do
      fixture = active_fixture("#{command}-context-owner-unconfirmed")
      before = length(AgentLoopTestModel.dispatched(fixture.model))
      marker = make_ref()
      abandon_reason = :prepared_owner_abandonment_unconfirmed
      test = self()

      # Concept: Outcome 10 permits observing the command's public facade
      # boundary so the reference surface can prove how it handles a real
      # facade result without growing a second session state machine.
      #
      # Technical depth: this process-local observer is the same general shape
      # as the composition edge observer: every public call delegates unchanged
      # through apply/3 unless a case overrides one boundary. This case replaces
      # only Loopex.abandon_resume/1, the fallible result the CLI must map. Core's
      # one-use abandonment and no-dispatch facts are protected separately by
      # the prepared-recovery and context-admission corpora; this selector owns
      # the CLI branch, exact composite, and ordering before activation or abort.
      observer = fn
        Loopex, :abandon_resume, [activation] ->
          send(test, {marker, Loopex, :abandon_resume, [activation]})
          {:error, abandon_reason}

        module, function, arguments ->
          send(test, {marker, module, function, arguments})
          apply(module, function, arguments)
      end

      Process.put(:"$loopex_cli_facade_observer", observer)

      result =
        try do
          dispatch_context_command(command, fixture, @context_budget + 1)
        after
          Process.delete(:"$loopex_cli_facade_observer")
        end

      assert result ==
               {:error,
                {:context_token_budget_configuration_conflict_owner_unconfirmed, abandon_reason}}

      assert_receive {^marker, Loopex, :runtime_placement_id, [state_root]}
      assert state_root == fixture.state_root

      assert_receive {^marker, Loopex, :prepare_resume_known_session,
                      [prepared_root, prepared_runtime, prepared_session, command_id]}

      assert prepared_root == fixture.state_root
      assert prepared_runtime == fixture.runtime
      assert prepared_session == fixture.session_id
      assert is_binary(command_id) and command_id != ""

      assert_receive {^marker, Loopex, :session_status, [status_runtime, status_session]}

      assert status_runtime == fixture.runtime
      assert status_session == fixture.session_id
      assert_receive {^marker, Loopex, :abandon_resume, [_activation]}
      refute_receive {^marker, _module, _function, _arguments}

      assert length(AgentLoopTestModel.dispatched(fixture.model)) == before
      assert AgentLoopTestExecutor.jobs(fixture.executor) == []
      refute abort_admitted?(fixture)
      refute Interrupt in :gen_event.which_handlers(:erl_signal_server)
      assert :ok = LoopexCli.release_placement()
    end
  end

  test "a settled prepared owner with no active context accepts omission or an explicit future default" do
    for {label, explicit} <- [{"omitted", nil}, {"explicit", 4_096}],
        command <- [:resume, :cancel] do
      fixture = settled_fixture("settled-#{command}-#{label}")
      before = length(AgentLoopTestModel.dispatched(fixture.model))
      selected_default = explicit || 8_192
      test = self()

      stop_runtime(fixture.runtime)

      starter = fn options ->
        configured = Keyword.get(options, :context_token_budget, 8_192)
        send(test, {:settled_runtime_context_default, command, label, configured})

        {:ok, replacement} =
          fixture.runtime_options
          |> Keyword.put(:context_token_budget, configured)
          |> Loopex.start_link()

        send(test, {:settled_replacement_runtime, command, label, replacement})
        {:ok, replacement}
      end

      result =
        capture_io(fn ->
          send(self(), {
            :settled_context_result,
            dispatch_context_command(command, fixture, explicit, runtime_starter: starter)
          })
        end)

      assert_receive {:settled_context_result, :ok}
      assert_receive {:settled_runtime_context_default, ^command, ^label, ^selected_default}
      assert_receive {:settled_replacement_runtime, ^command, ^label, replacement}
      on_exit(fn -> stop_runtime(replacement) end)

      refute result =~ "configuration_conflict"
      assert length(AgentLoopTestModel.dispatched(fixture.model)) == before

      {:ok, attachment} =
        Loopex.attach(replacement, fixture.session_id, after_event_sequence: 0)

      prompt_id = "settled-future-#{command}-#{label}"

      assert {:accepted, ^prompt_id} =
               Loopex.command(attachment, %{
                 type: :prompt,
                 command_id: prompt_id,
                 content: "the selected process default governs this later prompt"
               })

      assert_receive {:holding, model_worker}, 5_000

      assert {:ok, %{active_context_token_budget: ^selected_default}} =
               Loopex.session_status(replacement, fixture.session_id)

      [admission] =
        fixture.store_pid
        |> M1RuntimeTestStore.inspect_state()
        |> get_in([:sessions, fixture.session_id, :records])
        |> Enum.filter(fn record ->
          kind = Map.get(record.payload, :kind) || Map.get(record.payload, "kind")
          kind == "prompt_admitted_v2" and record.payload["command_id"] == prompt_id
        end)

      assert admission.payload["context_token_budget"] == selected_default
      send(model_worker, :release)
      assert :ok = LoopexCli.release_placement()
      restore_signal_handlers()
    end
  end

  defp dispatch_context_command(command, fixture, explicit, extra \\ []) do
    context =
      if is_integer(explicit),
        do: ["--context-token-budget", Integer.to_string(explicit)],
        else: []

    cleanup =
      case Keyword.fetch(extra, :cleanup_grace_ms) do
        {:ok, value} -> ["--cleanup-grace-ms", Integer.to_string(value)]
        :error -> []
      end

    LoopexCli.dispatch(
      [
        Atom.to_string(command),
        fixture.session_id,
        "--policy",
        "allow-all",
        "--state-root",
        fixture.state_root,
        "--workspace",
        fixture.workspace
      ] ++ context ++ cleanup,
      runtime_starter: fn options ->
        assert Keyword.fetch!(options, :runtime_id) == fixture.placement

        if is_integer(explicit) do
          assert Keyword.fetch!(options, :context_token_budget) == explicit
        else
          refute Keyword.has_key?(options, :context_token_budget)
        end

        case Keyword.fetch(extra, :runtime_starter) do
          {:ok, starter} -> starter.(options)
          :error -> {:ok, fixture.runtime}
        end
      end
    )
  end

  # ADR 0018: an attempt inherited open and dispatched settles as owner loss, so
  # the active run loses its owner at the durable prompt admission, before any
  # attempt opens, and the recovered run continues from there.
  defp active_fixture(label) do
    fixture = start_fixture(label, [%{text: "context resume completed"}])
    command_id = "active-#{label}"
    :ok = M1RuntimeTestStore.delay_after_record(fixture.store_pid, "prompt_admitted_v2", self())

    prompt =
      Task.async(fn ->
        Loopex.command(fixture.attachment, %{
          type: :prompt,
          command_id: command_id,
          content: "retain an active context budget"
        })
      end)

    assert_receive {:record_linearized, waiter, _store, "prompt_admitted_v2", _transition,
                    {:committed, _tx_id, _receipt}},
                   5_000

    :ok = Loopex.track_session(fixture.state_root, fixture.session_id, fixture.placement)
    coordinator = coordinator_of(fixture.runtime)
    monitor = Process.monitor(coordinator)
    Process.exit(coordinator, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^coordinator, :killed}, 5_000
    M1RuntimeTestStore.release(waiter)
    _ = Task.yield(prompt, 5_000) || Task.shutdown(prompt, :brutal_kill)
    fixture
  end

  defp settled_fixture(label) do
    fixture =
      start_fixture(label, [
        %{text: "settled context"},
        %{text: "later default", hold: self(), hold_timeout_ms: 30_000}
      ])

    command_id = "settled-#{label}"

    assert {:accepted, ^command_id} =
             Loopex.command(fixture.attachment, %{
               type: :prompt,
               command_id: command_id,
               content: "settle before prepared recovery"
             })

    drain(fixture.attachment)
    :ok = Loopex.track_session(fixture.state_root, fixture.session_id, fixture.placement)
    coordinator = coordinator_of(fixture.runtime)
    monitor = Process.monitor(coordinator)
    Process.exit(coordinator, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^coordinator, :killed}, 5_000
    fixture
  end

  defp start_fixture(label, script) do
    {state_root, workspace} = roots(label)
    {:ok, placement} = Loopex.runtime_placement_id(state_root)
    model = AgentLoopTestModel.start(script)
    executor = AgentLoopTestExecutor.start()
    {store_pid, store} = M1RuntimeTestStore.start_store(label: "context-cli-#{label}")

    runtime_options =
      [
        runtime_id: placement,
        store: store,
        model: %{
          module: AgentLoopTestModel,
          model: "scripted:v1",
          options: [script: model, max_tokens: 256]
        },
        executor: %{
          module: AgentLoopTestExecutor,
          reference: executor,
          identity: "context-cli-executor",
          epoch: 1,
          fencing_token: 1,
          workspace_ref: "context-cli-workspace",
          workspace_lease: "context-cli-lease"
        },
        tools: [],
        active_tools: [],
        policy: Loopex.AgentLoopTestPolicy,
        grant_decision: {:host_policy, :allow},
        cleanup_grace_ms: @cleanup_grace,
        context_token_budget: @context_budget
      ]

    {:ok, runtime} = Loopex.start_link(runtime_options)

    {:ok, session_id} =
      Loopex.create_session(runtime, %{"surface" => "context-cli"}, command_id: "create-#{label}")

    {:ok, attachment} = Loopex.attach(runtime, session_id, after_event_sequence: 0)

    on_exit(fn ->
      stop_runtime(runtime)
      stop(executor)
      stop(model)
      stop(store_pid)
    end)

    %{
      runtime: runtime,
      store_pid: store_pid,
      model: model,
      executor: executor,
      store: store,
      state_root: state_root,
      workspace: workspace,
      placement: placement,
      session_id: session_id,
      attachment: attachment,
      runtime_options: runtime_options
    }
  end

  defp abort_admitted?(fixture) do
    fixture.store_pid
    |> M1RuntimeTestStore.inspect_state()
    |> get_in([:sessions, fixture.session_id, :records])
    |> Enum.any?(fn record ->
      kind = Map.get(record.payload, :kind) || Map.get(record.payload, "kind")

      command_type =
        Map.get(record.payload, :command_type) || Map.get(record.payload, "command_type")

      kind == "command_admitted" and command_type == "abort"
    end)
  end

  defp coordinator_of(runtime) do
    {:ok, %{sessions: sessions}} = Runtime.children(runtime)

    sessions
    |> DynamicSupervisor.which_children()
    |> Enum.find_value(fn
      {_id, pid, :worker, _modules} when is_pid(pid) -> pid
      _other -> nil
    end)
  end

  defp drain(attachment, attempts \\ 1_000)
  defp drain(_attachment, 0), do: flunk("the context fixture did not settle")

  defp drain(attachment, attempts) do
    case Loopex.next_event(attachment) do
      {:ok, %{kind: "run.finished"}} -> :ok
      {:ok, _event} -> drain(attachment, attempts - 1)
      _empty -> Process.sleep(5) && drain(attachment, attempts - 1)
    end
  end

  defp roots(label) do
    unique = System.unique_integer([:positive])
    root = Path.join(System.tmp_dir!(), "loopex-context-cli-#{label}-#{unique}")
    state_root = Path.join(root, "state")
    workspace = Path.join(root, "workspace")
    File.mkdir_p!(state_root)
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf(root) end)
    {state_root, workspace}
  end

  defp restore_signal_handlers do
    _ = :gen_event.delete_handler(:erl_signal_server, Interrupt, [])

    if :erl_signal_handler not in :gen_event.which_handlers(:erl_signal_server) do
      _ = :gen_event.add_handler(:erl_signal_server, :erl_signal_handler, [])
    end

    :ok
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
end
