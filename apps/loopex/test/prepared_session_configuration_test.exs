Code.require_file("support/m1_runtime_helper.exs", __DIR__)
Code.require_file("support/agent_loop_helper.exs", __DIR__)
Code.require_file("support/configured_genesis_helper.exs", __DIR__)

defmodule Loopex.PreparedSessionConfigurationTest do
  use ExUnit.Case, async: false

  alias Loopex.AgentLoopFixture, as: Fixture
  alias Loopex.AgentLoopTestModel
  alias Loopex.ConfiguredGenesisFixture, as: Genesis
  alias Loopex.Runtime.SessionConfiguration

  test "restart reads the latest captured configuration and definitions without current defaults" do
    fixture = start(script: [])
    initial = Genesis.configuration("retained instruction canary")

    genesis =
      Genesis.genesis(fixture.definitions, initial) |> Map.put("policy_defer_mode", "refuse")

    {:ok, session} =
      Loopex.create_session(fixture.runtime, %{}, command_id: "create", genesis: genesis)

    {:ok, attachment} = Loopex.attach(fixture.runtime, session)
    changes = %{"max_tokens" => 2048}

    {:ok, candidate} =
      SessionConfiguration.update(
        initial,
        changes,
        initial["model_capabilities"],
        initial["provider_mapping"],
        fixture.definitions
      )

    assert {:accepted, "configure"} =
             Loopex.command_with_configuration(
               attachment,
               %{type: :configure, command_id: "configure", changes: changes},
               candidate
             )

    assert :ok = Loopex.stop(fixture.runtime)

    restarted =
      start(store: fixture.store, tools: [], max_tokens: 3, cleanup_grace_ms: 1, script: [])

    {:ok, {:prepared, activation}} =
      Loopex.prepare_resume_session(restarted.runtime, session, "resume")

    expected = %{
      configuration: candidate,
      tool_selection: genesis["tool_selection"],
      policy_defer_mode: "refuse",
      cleanup_grace_ms: 5000
    }

    before = facts(restarted, session)
    assert Loopex.prepared_session_configuration(activation) == {:ok, expected}
    assert Loopex.prepared_session_configuration(activation) == {:ok, expected}
    assert facts(restarted, session) == before
    assert AgentLoopTestModel.dispatched(restarted.model) == []
    assert Agent.get(restarted.executor, & &1.jobs) == []
    {:ok, status} = Loopex.session_status(restarted.runtime, session)
    refute :erlang.term_to_binary(status) =~ "retained instruction canary"
    assert :ok = Loopex.abandon_resume(activation)
  end

  test "implicit current creation preserves captures and retained grace on prepared recovery" do
    fixture = start(script: [], cleanup_grace_ms: 321)
    {:ok, session} = Loopex.create_session(fixture.runtime, %{}, command_id: "captured")

    {:ok, {:prepared, activation}} =
      Loopex.prepare_resume_session(fixture.runtime, session, "resume")

    before = facts(fixture, session)
    defaults = Fixture.creation_defaults(fixture.definitions, cleanup_grace_ms: 321)

    assert {:ok,
            %{
              configuration: configuration,
              tool_selection: selection,
              policy_defer_mode: "admit",
              cleanup_grace_ms: 321
            }} =
             Loopex.prepared_session_configuration(activation)

    assert configuration == defaults["initial_configuration"]
    assert selection == defaults["tool_selection"]

    assert facts(fixture, session) == before
    assert :ok = Loopex.abandon_resume(activation)
  end

  test "only the current holder can read and transfer revokes the previous holder" do
    {fixture, session, activation} = prepared()
    {:ok, expected} = Loopex.prepared_session_configuration(activation)
    before = facts(fixture, session)
    parent = self()

    {holder, monitor} =
      spawn_monitor(fn ->
        send(parent, {:nonholder_read, Loopex.prepared_session_configuration(activation)})

        receive do
          :read ->
            send(parent, {:holder_read, Loopex.prepared_session_configuration(activation)})
        end

        receive do
          :finish -> send(parent, {:holder_abandon, Loopex.abandon_resume(activation)})
        end
      end)

    assert_receive {:nonholder_read, {:error, :resume_activation_holder_mismatch}}
    assert :ok = Loopex.transfer_resume(activation, holder)

    assert {:error, :resume_activation_holder_mismatch} =
             Loopex.prepared_session_configuration(activation)

    send(holder, :read)
    assert_receive {:holder_read, {:ok, ^expected}}
    assert facts(fixture, session) == before
    send(holder, :finish)
    assert_receive {:holder_abandon, :ok}
    assert_receive {:DOWN, ^monitor, :process, ^holder, :normal}
    assert AgentLoopTestModel.dispatched(fixture.model) == []
    assert Agent.get(fixture.executor, & &1.jobs) == []
  end

  test "abandonment and activation refuse later reads without changing their disposition" do
    for {operation, refusal} <- [
          abandon_resume: :resume_activation_abandoned,
          activate_resume: :resume_activation_spent
        ] do
      {fixture, session, activation} = prepared()
      assert {:ok, _capture} = Loopex.prepared_session_configuration(activation)
      result = apply(Loopex, operation, [activation])
      assert result == if(operation == :activate_resume, do: {:ok, session}, else: :ok)
      before = facts(fixture, session)
      assert {:error, ^refusal} = Loopex.prepared_session_configuration(activation)
      assert facts(fixture, session) == before
      assert AgentLoopTestModel.dispatched(fixture.model) == []
      assert Agent.get(fixture.executor, & &1.jobs) == []
    end
  end

  test "abort fences the prepared read before any later activation" do
    {fixture, session, activation} = prepared()
    {:ok, attachment} = Loopex.attach(fixture.runtime, session)

    assert {:error, :no_active_run} =
             Loopex.command(attachment, %{type: :abort, command_id: "abort"})

    before = facts(fixture, session)
    assert {:error, :resume_activation_fenced} = Loopex.prepared_session_configuration(activation)
    assert {:error, :resume_activation_fenced} = Loopex.activate_resume(activation)
    assert facts(fixture, session) == before
    assert AgentLoopTestModel.dispatched(fixture.model) == []
    assert Agent.get(fixture.executor, & &1.jobs) == []
  end

  test "supersession and owner mismatch refuse the old capability" do
    {fixture, session, old} = prepared()

    assert {:error, :superseded_owner} =
             Loopex.prepared_session_configuration(%{old | owner: %{}})

    assert {:error, :resume_activation_unknown} =
             Loopex.prepared_session_configuration(%{old | capability: make_ref()})

    {:ok, {:prepared, current}} =
      Loopex.prepare_resume_session(fixture.runtime, session, "successor")

    before = facts(fixture, session)
    assert {:error, :session_unavailable} = Loopex.prepared_session_configuration(old)
    assert {:ok, _capture} = Loopex.prepared_session_configuration(current)
    assert facts(fixture, session) == before
    assert :ok = Loopex.abandon_resume(current)
  end

  test "reading a recovered pending prompt neither activates it nor dispatches its model" do
    fixture = start(script: [%{text: "must remain paused", calls: []}])

    {:ok, session} =
      Loopex.create_session(fixture.runtime, %{},
        command_id: "create",
        genesis: Genesis.genesis(fixture.definitions)
      )

    {:ok, attachment} = Loopex.attach(fixture.runtime, session)

    :ok =
      Loopex.M1RuntimeTestStore.delay_after_record(fixture.store, "prompt_admitted_v3", self())

    admission =
      Task.async(fn ->
        Loopex.command(attachment, %{type: :prompt, command_id: "prompt", content: "paused"})
      end)

    assert_receive {:record_linearized, waiter, _store, "prompt_admitted_v3", _transition,
                    {:committed, _tx, _receipt}},
                   5000

    {:ok, children} = Loopex.Runtime.children(fixture.runtime)
    coordinator = :sys.get_state(children.control).sessions[session].coordinator
    monitor = Process.monitor(coordinator)
    Process.exit(coordinator, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^coordinator, :killed}, 5000
    Loopex.M1RuntimeTestStore.release(waiter)
    assert {:ok, _disposition} = Task.yield(admission, 5000)

    {:ok, {:prepared, activation}} =
      Loopex.prepare_resume_session(fixture.runtime, session, "resume")

    before = facts(fixture, session)

    assert {:ok, %{configuration: configuration}} =
             Loopex.prepared_session_configuration(activation)

    assert configuration == Genesis.configuration()
    assert facts(fixture, session) == before
    assert AgentLoopTestModel.dispatched(fixture.model) == []
    assert Agent.get(fixture.executor, & &1.jobs) == []
    assert :ok = Loopex.abandon_resume(activation)

    assert {:error, :resume_activation_abandoned} =
             Loopex.prepared_session_configuration(activation)

    assert facts(fixture, session) == before
  end

  test "malformed capabilities refuse without revealing their members" do
    {fixture, session, activation} = prepared()
    before = facts(fixture, session)

    for malformed <- [
          nil,
          %{},
          activation.owner,
          %{activation | coordinator: nil},
          %{activation | owner: nil},
          %{activation | capability: nil}
        ] do
      assert {:error, :invalid_resume_activation} =
               Loopex.prepared_session_configuration(malformed)
    end

    assert facts(fixture, session) == before
    assert :ok = Loopex.abandon_resume(activation)
  end

  defp prepared do
    fixture = start(script: [])

    {:ok, session} =
      Loopex.create_session(fixture.runtime, %{},
        command_id: "create",
        genesis: Genesis.genesis(fixture.definitions)
      )

    {:ok, {:prepared, activation}} =
      Loopex.prepare_resume_session(fixture.runtime, session, "resume")

    {fixture, session, activation}
  end

  defp facts(fixture, session),
    do: {Fixture.records(fixture, session), Fixture.events(fixture, session)}

  defp start(options) do
    fixture = Fixture.start(options)
    on_exit(fn -> Fixture.stop(fixture) end)
    fixture
  end
end
