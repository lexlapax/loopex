Code.require_file("support/m1_runtime_helper.exs", __DIR__)
Code.require_file("support/agent_loop_helper.exs", __DIR__)
Code.require_file("support/configured_genesis_helper.exs", __DIR__)

defmodule Loopex.PreparedSessionStartupTest do
  use ExUnit.Case, async: false

  alias Loopex.AgentLoopFixture, as: Fixture
  alias Loopex.AgentLoopTestModel
  alias Loopex.ConfiguredGenesisFixture, as: Genesis
  alias Loopex.Runtime.SessionState
  alias Loopex.Store

  defmodule QuestionPolicy do
    @moduledoc false
    @behaviour Loopex.Policy

    @impl true
    def decide(_request), do: {:deny, :policy_denied}

    @impl true
    def decide(request, observer) do
      if Map.has_key?(request, :interaction_response) do
        send(observer, {:policy_reevaluation, self()})
        receive do: (:release -> {:deny, :policy_denied})
      else
        {:defer,
         %{
           kind: :choice,
           prompt: "May this effect proceed?",
           choices: [%{id: "allow", label: "Allow"}, %{id: "deny", label: "Deny"}],
           expires_in_ms: 60_000
         }}
      end
    end
  end

  test "restart returns exact options and admitted model rather than new launch defaults" do
    fixture = start(script: [])
    options = %{"surface" => "fixture", "opaque_host_binding" => "retained options canary"}
    {session, attachment} = create(fixture, options)

    {:ok, {:prepared, activation}} =
      Loopex.prepare_resume_session(fixture.runtime, session, "pause")

    assert {:accepted, "prompt"} =
             Loopex.command(attachment, %{type: :prompt, command_id: "prompt", content: "paused"})

    assert AgentLoopTestModel.dispatched(fixture.model) == []
    :ok = Loopex.abandon_resume(activation)
    :ok = Loopex.stop(fixture.runtime)
    successor = start(store: fixture.store, script: [], tools: [], model: "changed:model")

    {:ok, {:prepared, recovered}} =
      Loopex.prepare_resume_session(successor.runtime, session, "recover")

    expected = %{
      session_options: options,
      pending_policy_identity: nil,
      admitted_models: ["scripted:v1"],
      admitted_workspace_refs: []
    }

    before = facts(successor, session)
    assert Loopex.prepared_session_startup(recovered) == {:ok, expected}
    assert Loopex.prepared_session_startup(recovered) == {:ok, expected}
    assert facts(successor, session) == before
    assert AgentLoopTestModel.dispatched(successor.model) == []
    assert Agent.get(successor.executor, & &1.jobs) == []
    :ok = Loopex.abandon_resume(recovered)
  end

  for status <- [:pending, :answered] do
    @status status
    test "#{status} policy question retains its binding before successor reevaluation" do
      policy = %{"id" => "retained.policy", "revision" => "exact-revision"}

      fixture =
        start(
          script: tool_script(),
          policy: %{module: QuestionPolicy, context: self()},
          policy_identity: policy
        )

      {session, attachment} = create(fixture)

      assert {:accepted, "prompt"} =
               Loopex.command(attachment, %{
                 type: :prompt,
                 command_id: "prompt",
                 content: "effect"
               })

      question = await_question(fixture.runtime, session, now() + 5_000)

      if @status == :answered do
        assert {:accepted, "answer"} =
                 Loopex.command(attachment, %{
                   type: :interaction_answer,
                   command_id: "answer",
                   interaction_id: question["interaction_id"],
                   choice_id: "allow"
                 })

        assert_receive {:policy_reevaluation, _worker}, 5_000
      end

      :ok = Loopex.stop(fixture.runtime)

      successor =
        start(
          store: fixture.store,
          script: [],
          policy_identity: %{"id" => "changed", "revision" => "2"}
        )

      {:ok, {:prepared, activation}} =
        Loopex.prepare_resume_session(successor.runtime, session, "recover")

      before = facts(successor, session)

      assert {:ok,
              %{
                pending_policy_identity: ^policy,
                admitted_models: ["scripted:v1"],
                admitted_workspace_refs: []
              }} = Loopex.prepared_session_startup(activation)

      assert facts(successor, session) == before
      assert AgentLoopTestModel.dispatched(successor.model) == []
      assert Agent.get(successor.executor, & &1.jobs) == []
      refute_receive {:policy_reevaluation, _}, 0
      :ok = Loopex.abandon_resume(activation)
    end
  end

  test "a retained pending intent names its workspace without redispatching its effect" do
    fixture = start(script: tool_script())
    {session, attachment} = create(fixture)

    :ok =
      Loopex.M1RuntimeTestStore.delay_after_record(
        fixture.store,
        "effect_intent_committed_v2",
        self()
      )

    assert {:accepted, "prompt"} =
             Loopex.command(attachment, %{type: :prompt, command_id: "prompt", content: "effect"})

    assert_receive {:record_linearized, waiter, _store, "effect_intent_committed_v2", _tx,
                    {:committed, _, _}},
                   5_000

    {:ok, children} = Loopex.Runtime.children(fixture.runtime)
    coordinator = :sys.get_state(children.control).sessions[session].coordinator
    monitor = Process.monitor(coordinator)
    Process.exit(coordinator, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^coordinator, :killed}, 5_000
    Loopex.M1RuntimeTestStore.release(waiter)

    {:ok, {:prepared, activation}} =
      Loopex.prepare_resume_session(fixture.runtime, session, "recover")

    before = facts(fixture, session)
    dispatched = AgentLoopTestModel.dispatched(fixture.model)
    assert length(dispatched) == 1

    assert {:ok, %{admitted_models: ["scripted:v1"], admitted_workspace_refs: ["workspace-ref"]}} =
             Loopex.prepared_session_startup(activation)

    assert facts(fixture, session) == before
    assert AgentLoopTestModel.dispatched(fixture.model) == dispatched
    assert Agent.get(fixture.executor, & &1.jobs) == []
    :ok = Loopex.abandon_resume(activation)
  end

  test "capture excludes completed effects, keeps exact staged identities and sorts unique arrays" do
    state = %SessionState{
      session_options: %{},
      pending_work: %{
        "b" => %{
          stage: "effect_dispatched",
          job: %{workspace_ref: "workspace-b"},
          grant: %{},
          request: %{model: "provider:old", continuation: %{"private" => "continuation-canary"}}
        },
        "a" => %{stage: "model_pending", staged: %{request: %{model: "provider:new"}}}
      },
      run_configurations: %{
        "a" => %{"model" => "provider:old"},
        "b" => %{"model" => "provider:old"},
        "completed" => %{"model" => "provider:completed"}
      }
    }

    assert {:ok,
            %{
              admitted_models: ["provider:new", "provider:old"],
              admitted_workspace_refs: ["workspace-b"]
            } = capture} = SessionState.prepared_startup_capture(state)

    refute :erlang.term_to_binary(capture) =~ "continuation-canary"

    question = %{producer: "model_tool", status: "pending", policy_identity: nil}
    state = %{state | open_interaction: "question", interactions: %{"question" => question}}
    assert {:ok, %{pending_policy_identity: nil}} = SessionState.prepared_startup_capture(state)

    assert {:error, :prepared_startup_unavailable} =
             SessionState.prepared_startup_capture(%{state | run_configurations: %{}})

    assert {:error, :prepared_startup_unavailable} =
             SessionState.prepared_startup_capture(%{state | interactions: %{}})

    for invalid <- [
          nil,
          %{"a" => nil},
          %{"a" => %{stage: "model_pending", request: nil}},
          %{"a" => %{stage: "model_request_pending_attempt_open", staged: 42}},
          %{"a" => %{stage: "model_request_pending_attempt_open", staged: %{request: nil}}},
          %{"a" => %{stage: "effect_dispatched", job: %{}, grant: %{}}}
        ] do
      assert {:error, :prepared_startup_unavailable} =
               SessionState.prepared_startup_capture(%{state | pending_work: invalid})
    end
  end

  test "whole capture fits at exactly 65536 bytes and refuses one byte above without truncation" do
    state = %SessionState{session_options: %{"padding" => ""}}
    {:ok, empty} = SessionState.prepared_startup_capture(state)
    {:ok, overhead} = Store.admit_bounded(empty)
    padding = String.duplicate("p", 65_536 - overhead)
    state = %{state | session_options: %{"padding" => padding}}
    assert {:ok, exact} = SessionState.prepared_startup_capture(state)
    assert Store.admit_bounded(exact) == {:ok, 65_536}
    assert exact.session_options["padding"] == padding

    assert {:error, :prepared_startup_too_large} =
             SessionState.prepared_startup_capture(%{
               state
               | session_options: %{"padding" => padding <> "p"}
             })
  end

  test "holder transfer, spending, abandonment, abort and supersession fence the read" do
    fixture = start(script: [])
    {session, _attachment} = create(fixture)

    {:ok, {:prepared, activation}} =
      Loopex.prepare_resume_session(fixture.runtime, session, "prepare")

    parent = self()

    {holder, monitor} =
      spawn_monitor(fn ->
        send(parent, {:nonholder, Loopex.prepared_session_startup(activation)})

        receive do: (:read ->
                       send(parent, {:holder, Loopex.prepared_session_startup(activation)}))

        receive do: (:stop -> Loopex.abandon_resume(activation))
      end)

    assert_receive {:nonholder, {:error, :resume_activation_holder_mismatch}}, 5_000
    assert :ok = Loopex.transfer_resume(activation, holder)

    assert {:error, :resume_activation_holder_mismatch} =
             Loopex.prepared_session_startup(activation)

    send(holder, :read)
    assert_receive {:holder, {:ok, %{session_options: %{}}}}, 5_000
    send(holder, :stop)
    assert_receive {:DOWN, ^monitor, :process, ^holder, :normal}, 5_000
    assert {:error, :resume_activation_abandoned} = Loopex.prepared_session_startup(activation)

    for {command, action, refusal} <- [
          {"spend", :activate_resume, :resume_activation_spent},
          {"abandon", :abandon_resume, :resume_activation_abandoned}
        ] do
      {:ok, {:prepared, current}} =
        Loopex.prepare_resume_session(fixture.runtime, session, command)

      _ = apply(Loopex, action, [current])
      assert {:error, ^refusal} = Loopex.prepared_session_startup(current)
    end

    {:ok, {:prepared, current}} = Loopex.prepare_resume_session(fixture.runtime, session, "abort")
    {:ok, attachment} = Loopex.attach(fixture.runtime, session)

    assert {:error, :no_active_run} =
             Loopex.command(attachment, %{type: :abort, command_id: "abort"})

    assert {:error, :resume_activation_fenced} = Loopex.prepared_session_startup(current)

    {:ok, {:prepared, successor}} =
      Loopex.prepare_resume_session(fixture.runtime, session, "supersede")

    assert {:error, :session_unavailable} = Loopex.prepared_session_startup(current)

    assert {:error, :superseded_owner} =
             Loopex.prepared_session_startup(%{successor | owner: %{}})

    assert {:error, :resume_activation_unknown} =
             Loopex.prepared_session_startup(%{successor | capability: make_ref()})

    assert {:error, :invalid_resume_activation} =
             Loopex.prepared_session_startup(%{successor | coordinator: nil})

    :ok = Loopex.abandon_resume(successor)
  end

  defp create(fixture, options \\ %{}) do
    genesis = Genesis.genesis(fixture.definitions) |> Map.put("options", options)

    {:ok, session} =
      Loopex.create_session(fixture.runtime, options, command_id: "create", genesis: genesis)

    {:ok, attachment} = Loopex.attach(fixture.runtime, session)
    {session, attachment}
  end

  defp tool_script do
    [
      %{
        text: "proposed",
        calls: [%{id: "call", name: "write", arguments: %{"path" => "owned.txt"}}]
      }
    ]
  end

  defp start(options) do
    fixture = Fixture.start(options)
    on_exit(fn -> Fixture.stop(fixture) end)
    fixture
  end

  defp facts(fixture, session),
    do: {Fixture.records(fixture, session), Fixture.events(fixture, session)}

  defp now, do: System.monotonic_time(:millisecond)

  defp await_question(runtime, session, deadline) do
    {:ok, status} = Loopex.session_status(runtime, session)

    cond do
      status.open_interaction != nil ->
        status.open_interaction

      now() >= deadline ->
        flunk("policy question was not retained before the fixture cutoff")

      true ->
        receive do
        after
          10 -> :ok
        end

        await_question(runtime, session, deadline)
    end
  end
end
