defmodule LoopexComposition.Ephemeral.SettlementTest do
  use ExUnit.Case, async: false

  alias LoopexComposition.Ephemeral
  alias LoopexComposition.Ephemeral.{OwnerActivation, SessionOwner}

  defmodule Policy do
    @behaviour Loopex.Policy
    @impl true
    def decide(_request), do: {:allow, nil}
  end

  defmodule Facade do
    def create_session(_runtime, %{"surface" => "embedded"}, command_id: "create") do
      Process.put(:test, Application.fetch_env!(:loopex_composition, :settlement_test))
      {:ok, "settlement-session"}
    end

    def attach(runtime, "settlement-session", after_event_sequence: 0) do
      Process.put(:events, [])

      {:ok,
       %Loopex.Attachment{
         runtime: runtime,
         session_id: "settlement-session",
         attachment_id: "settlement-attachment",
         incarnation_id: "settlement-incarnation",
         snapshot: %{}
       }}
    end

    def session_status(_runtime, "settlement-session") do
      count = Process.get(:status_count, 0) + 1
      Process.put(:status_count, count)

      if count > 1 do
        send(Process.get(:test), {:settlement_status_requested, self()})

        receive do
          :release_settlement_status -> :ok
          {:release_settlement_status, response} -> {:reply, response}
        end
        |> case do
          {:reply, response} -> response
          :ok -> status(count)
        end
      else
        status(count)
      end
    end

    defp status(count) do
      {:ok,
       %{
         status: :active,
         owner_epoch: 0,
         event_sequence: if(count == 1, do: 0, else: 2),
         active_run_id: nil,
         pending_work_ids: [],
         cleanup_grace_ms: 5_000
       }}
    end

    def command(_attachment, %{type: :prompt, command_id: id, content: "prompt"}) do
      send(Process.get(:test), {:settlement_prompt_dispatched, self(), id})

      receive do
        :release_settlement_prompt -> :ok
      end

      Process.put(:events, [
        %{
          :kind => "user.message_appended",
          :event_sequence => 1,
          "command_id" => id,
          "run_id" => "settlement-run",
          "content" => "prompt"
        },
        %{
          :kind => "run.finished",
          :event_sequence => 2,
          "run_id" => "settlement-run",
          "outcome" => "completed",
          "cleanup_grace_ms" => 5_000
        }
      ])

      {:accepted, id}
    end

    def next_event(_attachment) do
      case Process.get(:events, []) do
        [event | rest] ->
          Process.put(:events, rest)
          {:ok, event}

        [] ->
          {:error, :empty}
      end
    end
  end

  test "a terminal waits for status, exact empty release and candidate DOWN" do
    root = Path.join(System.tmp_dir!(), "loopex-settlement-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    Application.put_env(:loopex_composition, :settlement_test, self())

    on_exit(fn ->
      Application.delete_env(:loopex_composition, :settlement_test)
      File.rm_rf!(root)
    end)

    {:loopex_ephemeral_session, owner, cell} = session = start_private_session(root)

    question = Task.async(fn -> Ephemeral.ask(session, "prompt") end)
    assert_receive {:settlement_prompt_dispatched, facade, command_id}, 2_000

    call = make_ref()
    proof = make_ref()
    test = self()

    candidate =
      spawn(fn ->
        receive do
          {:release_empty_invocation, generation, ^call, pid, ^proof, release_ref, deadline}
          when pid == self() ->
            send(test, {:candidate_released, generation, release_ref, deadline})
            send(owner, {:empty_invocation_released, self(), release_ref})

            receive do
              :finish_candidate -> :ok
            end
        end
      end)

    on_exit(fn -> if Process.alive?(candidate), do: Process.exit(candidate, :kill) end)

    :sys.replace_state(owner, fn state ->
      pending = %{
        phase: :retired_wait_down,
        call: call,
        proof: proof,
        candidate: candidate,
        candidate_monitor: Process.monitor(candidate),
        candidate_down: false,
        callback_down: true,
        callback_monitor: make_ref(),
        revision: 0,
        resources: %{},
        registries: %{},
        resource_monitors: %{},
        timer: nil,
        retirement_timer: nil
      }

      :atomics.put(cell, 2, 1)
      %{state | model_census: %{state.model_census | pending: pending}}
    end)

    send(owner, {:model_census_retirement_check, make_ref()})

    assert %{session: %{model_binding: %{call: ^call, command_id: ^command_id}}} =
             :sys.get_state(owner)

    send(facade, :release_settlement_prompt)
    assert_receive {:settlement_status_requested, ^facade}, 2_000
    assert nil == Task.yield(question, 25)
    refute_receive {:candidate_released, _, _, _}, 25

    send(facade, :release_settlement_status)
    assert_receive {:candidate_released, generation, release_ref, deadline}, 2_000
    assert is_reference(generation)
    assert is_reference(release_ref)
    assert deadline > System.monotonic_time()
    assert nil == Task.yield(question, 25)

    send(candidate, :finish_candidate)

    assert {:ok, {:ok, %{outcome: :completed, run_id: "settlement-run"}}} =
             Task.yield(question, 2_000)

    assert :ok = Ephemeral.stop_session(session)
  end

  test "stop wins over an in-flight settlement status read" do
    {session, _owner, cell, question, facade, candidate} = start_pending_ask()
    send(facade, :release_settlement_prompt)
    assert_receive {:settlement_status_requested, ^facade}, 2_000

    stop = Task.async(fn -> Ephemeral.stop_session(session) end)

    assert {:ok, :ok} = Task.yield(stop, 4_000)

    assert {:ok, {:ok, %{outcome: :completed, run_id: "settlement-run"}}} =
             Task.yield(question, 2_000)

    assert :atomics.get(cell, 1) > 0
    refute Process.alive?(candidate)
    refute_receive {:candidate_released, _, _, _}, 25
    assert {:error, :session_closed} = Ephemeral.ask(session, "later")
  end

  test "an invalid serialized status closes only its session and retains the terminal" do
    {session, _owner, cell, question, facade, candidate} = start_pending_ask()
    send(facade, :release_settlement_prompt)
    assert_receive {:settlement_status_requested, ^facade}, 2_000

    send(
      facade,
      {:release_settlement_status,
       {:ok,
        %{
          status: :active,
          owner_epoch: 0,
          event_sequence: 2,
          active_run_id: "settlement-run",
          pending_work_ids: []
        }}}
    )

    assert {:ok, {:ok, %{outcome: :completed, run_id: "settlement-run"}}} =
             Task.yield(question, 4_000)

    assert :atomics.get(cell, 1) > 0
    refute Process.alive?(candidate)
    refute_receive {:candidate_released, _, _, _}, 25
    assert :ok = Ephemeral.stop_session(session)
    assert {:error, :session_closed} = Ephemeral.last_result(session)
  end

  test "a status missing active_run_id cannot prove that the run ended" do
    {session, _owner, cell, question, facade, candidate} = start_pending_ask()
    send(facade, :release_settlement_prompt)
    assert_receive {:settlement_status_requested, ^facade}, 2_000

    send(
      facade,
      {:release_settlement_status,
       {:ok,
        %{
          status: :active,
          owner_epoch: 0,
          event_sequence: 2,
          pending_work_ids: []
        }}}
    )

    refute_receive {:candidate_released, _, _, _}, 50

    assert {:ok, {:ok, %{outcome: :completed, run_id: "settlement-run"}}} =
             Task.yield(question, 4_000)

    assert :atomics.get(cell, 1) > 0
    refute Process.alive?(candidate)
    refute_receive {:candidate_released, _, _, _}, 25
    assert :ok = Ephemeral.stop_session(session)
  end

  test "wrong epoch, stale sequence, malformed run ids, pending run and status error cannot release the candidate" do
    valid = %{
      status: :active,
      owner_epoch: 0,
      event_sequence: 2,
      active_run_id: nil,
      pending_work_ids: []
    }

    for response <- [
          {:ok, %{valid | owner_epoch: 1}},
          {:ok, %{valid | event_sequence: 1}},
          {:ok, %{valid | active_run_id: false}},
          {:ok, %{valid | active_run_id: :unknown}},
          {:ok, %{valid | active_run_id: String.duplicate("x", 257)}},
          {:ok, %{valid | pending_work_ids: [false]}},
          {:ok, %{valid | pending_work_ids: [:unknown]}},
          {:ok, %{valid | pending_work_ids: [String.duplicate("x", 257)]}},
          {:ok, %{valid | pending_work_ids: ["settlement-run"]}},
          {:error, :status_unavailable}
        ] do
      {session, _owner, cell, question, facade, candidate} = start_pending_ask()
      send(facade, :release_settlement_prompt)
      assert_receive {:settlement_status_requested, ^facade}, 2_000
      send(facade, {:release_settlement_status, response})

      refute_receive {:candidate_released, _, _, _}, 25

      assert {:ok, {:ok, %{outcome: :completed, run_id: "settlement-run"}}} =
               Task.yield(question, 4_000)

      assert :atomics.get(cell, 1) > 0
      refute Process.alive?(candidate)
      refute_receive {:candidate_released, _, _, _}, 25
      assert :ok = Ephemeral.stop_session(session)
    end
  end

  test "a model call bound to a different reference cannot enter the status barrier" do
    {session, owner, cell, question, facade, candidate} = start_pending_ask()

    :sys.replace_state(owner, fn state ->
      put_in(state.session.model_binding.call, make_ref())
    end)

    send(facade, :release_settlement_prompt)
    refute_receive {:settlement_status_requested, ^facade}, 25
    refute_receive {:candidate_released, _, _, _}, 25

    assert {:ok, {:ok, %{outcome: :completed, run_id: "settlement-run"}}} =
             Task.yield(question, 4_000)

    assert :atomics.get(cell, 1) > 0
    refute Process.alive?(candidate)
    refute_receive {:settlement_status_requested, ^facade}, 25
    refute_receive {:candidate_released, _, _, _}, 25
    assert :ok = Ephemeral.stop_session(session)
  end

  test "a forged facade status reply cannot release a candidate" do
    {session, owner, _cell, question, facade, candidate} = start_pending_ask()
    send(facade, :release_settlement_prompt)
    assert_receive {:settlement_status_requested, ^facade}, 2_000

    send(
      owner,
      {facade, make_ref(),
       {:ok,
        %{
          status: :active,
          owner_epoch: 0,
          event_sequence: 2,
          active_run_id: nil,
          pending_work_ids: []
        }}}
    )

    assert %{session: %{active: %{operation: :settlement_status}}} = :sys.get_state(owner)
    refute_receive {:candidate_released, _, _, _}, 25

    send(facade, :release_settlement_status)
    assert_receive {:candidate_released, _, _, _}, 2_000
    send(candidate, :finish_candidate)

    assert {:ok, {:ok, %{outcome: :completed, run_id: "settlement-run"}}} =
             Task.yield(question, 2_000)

    assert :ok = Ephemeral.stop_session(session)
  end

  test "an unresponsive status read is bounded and retains the terminal" do
    {session, _owner, cell, question, facade, candidate} = start_pending_ask()
    send(facade, :release_settlement_prompt)
    assert_receive {:settlement_status_requested, ^facade}, 2_000

    assert {:ok, {:ok, %{outcome: :completed, run_id: "settlement-run"}}} =
             Task.yield(question, 4_000)

    assert :atomics.get(cell, 1) > 0
    refute Process.alive?(candidate)
    refute_receive {:candidate_released, _, _, _}, 25
    assert :ok = Ephemeral.stop_session(session)
  end

  test "a release acknowledgement without candidate DOWN cannot prove settlement" do
    {session, _owner, cell, question, facade, candidate} = start_pending_ask()
    send(facade, :release_settlement_prompt)
    assert_receive {:settlement_status_requested, ^facade}, 2_000
    send(facade, :release_settlement_status)

    assert_receive {:candidate_released, _, _, _}, 2_000
    assert Process.alive?(candidate)
    assert nil == Task.yield(question, 25)

    assert {:ok, {:ok, %{outcome: :completed, run_id: "settlement-run"}}} =
             Task.yield(question, 4_000)

    assert :atomics.get(cell, 1) > 0
    refute Process.alive?(candidate)
    assert :ok = Ephemeral.stop_session(session)
  end

  test "genuine candidate DOWN proves settlement when the release acknowledgement is lost" do
    {session, _owner, cell, question, facade, candidate} = start_pending_ask(:drop_release_ack)
    send(facade, :release_settlement_prompt)
    assert_receive {:settlement_status_requested, ^facade}, 2_000
    send(facade, :release_settlement_status)

    assert_receive {:candidate_released, _, _, _}, 2_000

    assert {:ok, {:ok, %{outcome: :completed, run_id: "settlement-run"}}} =
             Task.yield(question, 2_000)

    refute Process.alive?(candidate)
    assert :atomics.get(cell, 2) == 0
    assert :ok = Ephemeral.stop_session(session)
  end

  defp start_pending_ask(mode \\ :ack) do
    root = Path.join(System.tmp_dir!(), "loopex-settlement-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    Application.put_env(:loopex_composition, :settlement_test, self())

    on_exit(fn ->
      Application.delete_env(:loopex_composition, :settlement_test)
      File.rm_rf!(root)
    end)

    {:loopex_ephemeral_session, owner, cell} = session = start_private_session(root)
    question = Task.async(fn -> Ephemeral.ask(session, "prompt") end)
    assert_receive {:settlement_prompt_dispatched, facade, command_id}, 2_000

    call = make_ref()
    proof = make_ref()
    test = self()
    candidate = spawn(fn -> candidate_loop(owner, cell, test, call, proof, mode) end)
    on_exit(fn -> if Process.alive?(candidate), do: Process.exit(candidate, :kill) end)

    :sys.replace_state(owner, fn state ->
      pending = %{
        phase: :retired_wait_down,
        call: call,
        proof: proof,
        candidate: candidate,
        candidate_monitor: Process.monitor(candidate),
        candidate_down: false,
        callback_down: true,
        callback_monitor: make_ref(),
        revision: 0,
        resources: %{},
        registries: %{},
        resource_monitors: %{},
        timer: nil,
        retirement_timer: nil
      }

      :atomics.put(cell, 2, 1)
      %{state | model_census: %{state.model_census | pending: pending}}
    end)

    send(owner, {:model_census_retirement_check, make_ref()})

    assert %{session: %{model_binding: %{call: ^call, command_id: ^command_id}}} =
             :sys.get_state(owner)

    {session, owner, cell, question, facade, candidate}
  end

  defp candidate_loop(owner, cell, test, call, proof, mode) do
    receive do
      {:release_empty_invocation, generation, ^call, candidate, ^proof, release_ref, deadline}
      when candidate == self() ->
        send(test, {:candidate_released, generation, release_ref, deadline})

        if mode == :ack do
          send(owner, {:empty_invocation_released, self(), release_ref})
          candidate_loop(owner, cell, test, call, proof, mode)
        end

      :finish_candidate ->
        :ok
    after
      10 ->
        if :atomics.get(cell, 1) == 0,
          do: candidate_loop(owner, cell, test, call, proof, mode),
          else: :ok
    end
  end

  defp start_private_session(root) do
    {:ok, _digest, manifest} =
      Loopex.ResourcePack.digest(%{
        "version" => "loopex.resource_pack/1",
        "workspace_ref" => "workspace-ref",
        "revision" => nil,
        "packs" => []
      })

    configuration = %{
      cwd: root,
      model: "ollama:test",
      provider: %{credential_variable: nil},
      base_url: "http://localhost:11434",
      policy: Policy,
      tools: :none,
      skills: %{manifest: manifest, shadowed_skills: []},
      max_steps: 16,
      deadline_ms: 10_000,
      max_tokens: 128,
      context_token_budget: 8_192,
      timeout: 10_000,
      test_facade: Facade,
      test_seams: %{temp_root: %{tmp: fn -> root end}}
    }

    {:ok, supervisor} = DynamicSupervisor.start_link(strategy: :one_for_one)
    {:ok, activation} = OwnerActivation.start(supervisor)
    owner = OwnerActivation.owner(activation)
    {:ok, cell} = OwnerActivation.begin(activation)
    assert {:ok, :session_ready} = SessionOwner.start_session(owner, configuration, 6_000)
    {:loopex_ephemeral_session, owner, cell}
  end
end
