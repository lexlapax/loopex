defmodule LoopexComposition.Ephemeral.ApiFaultTest do
  @moduledoc false
  use ExUnit.Case, async: false

  alias LoopexComposition.Ephemeral
  alias LoopexComposition.Ephemeral.{OwnerActivation, SessionOwner}

  @uint64_max 18_446_744_073_709_551_615
  @nonce String.duplicate("n", 32)
  @first_prompt_id "e-aedd225c7f21201d6906ec3f62ff70ca920c21534f66d9d3083577c63dd96a"
  @answer_id "e-2b86ab4ad4e0e94e5132a19ed27d43dcfd60d684748c17490cf860565f2af3"
  @second_prompt_id "e-fdbd86c2263dccfb35dfff39757d83f8509e0f2c013f715e6221ca1ee1ee72"
  @abort_id "e-17714b8f5af92cd5c6ca55f59d9c6a62372231ebe8d299a4d02003ce2513da"

  defmodule Policy do
    @moduledoc false
    def decide(_request), do: {:allow, nil}
  end

  defmodule Facade do
    @moduledoc false
    @uint64_max 18_446_744_073_709_551_615

    def create_session(_runtime, %{"surface" => "embedded"},
          command_id: "create",
          genesis: _genesis
        ) do
      Process.put(:events, [])
      Process.put(:sequence, 0)
      {:ok, "fault-session"}
    end

    def attach(runtime, "fault-session", after_event_sequence: 0) do
      {:ok,
       %Loopex.Attachment{
         runtime: runtime,
         session_id: "fault-session",
         attachment_id: "fault-attachment",
         incarnation_id: "fault-incarnation",
         snapshot: %{}
       }}
    end

    def session_status(_runtime, "fault-session") do
      {:ok,
       %{
         status: :active,
         owner_epoch: 0,
         active_run_id: nil,
         pending_work_ids: [],
         cleanup_grace_ms: 5_000
       }}
    end

    def command(_attachment, %{type: :prompt} = command) do
      send(test_pid(), {:prompt_dispatched, self(), command.command_id, command.content})
      Process.put(:mode, command.content)
      Process.put(:command_id, command.command_id)
      Process.put(:finished, false)

      case command.content do
        "pre-refuse" ->
          {:error, :run_open}

        "held-reply" ->
          receive do
            :release_reply -> :ok
          end

          begin_run(command)
          finish_run(command.command_id, 5_000)
          {:accepted, command.command_id}

        "disconnect" ->
          begin_run(command)
          Process.put(:disconnect, true)
          {:accepted, command.command_id}

        "bad-terminal" ->
          begin_run(command)
          finish_run(command.command_id, 0)
          {:accepted, command.command_id}

        "stale-terminal" ->
          begin_run(command)

          enqueue(%{
            "run_id" => "previous-run",
            "outcome" => "completed",
            "cleanup_grace_ms" => 5_000,
            kind: "run.finished"
          })

          finish_run(command.command_id, 5_000)
          {:accepted, command.command_id}

        mode when mode in ["continue", "background-disconnect"] ->
          begin_run(command)
          {:accepted, command.command_id}

        "identity-question" ->
          begin_run(command)

          enqueue(%{
            "run_id" => Process.get(:run_id),
            "interaction_id" => "identity-interaction",
            "turn" => 1,
            "tool_call_id" => "identity-call",
            "prompt" => "Continue?",
            "choices" => [%{"id" => "yes", "label" => "Yes"}],
            "expires_at" => 1_800_000_000,
            kind: "interaction.requested"
          })

          {:accepted, command.command_id}

        "malformed-question" ->
          begin_run(command)

          question = %{
            "run_id" => Process.get(:run_id),
            "interaction_id" => "malformed-interaction",
            "turn" => 1,
            "tool_call_id" => "malformed-call",
            "prompt" => "Continue?",
            "choices" => [%{"id" => "yes", "label" => "Yes"}],
            "expires_at" => 1_800_000_000,
            kind: "interaction.requested"
          }

          enqueue(:persistent_term.get({__MODULE__, :question_mutation}).(question))
          {:accepted, command.command_id}

        mode
        when mode in [
               "question-max",
               "turn-zero",
               "turn-overflow",
               "expiry-zero",
               "expiry-overflow"
             ] ->
          begin_run(command)

          {turn, expires_at} =
            case mode do
              "question-max" -> {@uint64_max, @uint64_max}
              "turn-zero" -> {0, 1}
              "turn-overflow" -> {@uint64_max + 1, 1}
              "expiry-zero" -> {1, 0}
              "expiry-overflow" -> {1, @uint64_max + 1}
            end

          enqueue(%{
            "run_id" => Process.get(:run_id),
            "interaction_id" => "numeric-interaction",
            "turn" => turn,
            "tool_call_id" => "numeric-call",
            "prompt" => "Continue?",
            "choices" => [%{"id" => "yes", "label" => "Yes"}],
            "expires_at" => expires_at,
            kind: "interaction.requested"
          })

          {:accepted, command.command_id}

        "identity-abort" ->
          begin_run(command)
          {:accepted, command.command_id}

        "wrong-accept" ->
          begin_run(command)
          finish_run(command.command_id, 5_000)
          {:accepted, "another-command"}

        _ ->
          begin_run(command)
          finish_run(command.command_id, 5_000)
          {:accepted, command.command_id}
      end
    end

    def command(_attachment, %{type: :interaction_answer} = command) do
      send(test_pid(), {:answer_dispatched, self(), command.command_id})
      finish_run(Process.get(:command_id), 5_000)
      {:accepted, command.command_id}
    end

    def command(_attachment, %{type: :abort} = command) do
      send(test_pid(), {:abort_dispatched, self(), command.command_id})

      if Process.get(:mode) == "identity-abort" do
        enqueue(%{
          "run_id" => Process.get(:run_id),
          "outcome" => "cancelled",
          "cleanup_grace_ms" => 5_000,
          kind: "run.finished"
        })

        {:accepted, command.command_id}
      else
        {:error, :no_active_run}
      end
    end

    def next_event(_attachment) do
      case Process.get(:events, []) do
        [event | rest] ->
          Process.put(:events, rest)
          {:ok, event}

        [] ->
          cond do
            Process.get(:disconnect, false) ->
              {:disconnected, Process.get(:sequence)}

            Process.get(:mode) == "background-disconnect" and
                :persistent_term.get({__MODULE__, :fail_background}, false) ->
              {:disconnected, Process.get(:sequence)}

            Process.get(:mode) == "continue" and
              :persistent_term.get({__MODULE__, :finish_now}, false) and
                not Process.get(:finished) ->
              Process.put(:finished, true)
              finish_run(Process.get(:command_id), 5_000)
              next_event(nil)

            true ->
              {:error, :empty}
          end
      end
    end

    defp begin_run(command) do
      Process.put(:run_id, "run-" <> command.command_id)

      enqueue(%{
        "command_id" => command.command_id,
        "run_id" => Process.get(:run_id),
        "content" => command.content,
        kind: "user.message_appended"
      })
    end

    defp finish_run(command_id, grace) do
      enqueue(%{
        "run_id" => "run-" <> command_id,
        "content" => "answer",
        kind: "assistant.message_appended"
      })

      enqueue(%{
        "run_id" => "run-" <> command_id,
        "outcome" => "completed",
        "cleanup_grace_ms" => grace,
        kind: "run.finished"
      })
    end

    defp enqueue(event) do
      sequence = Process.get(:sequence) + 1
      Process.put(:sequence, sequence)
      Process.put(:events, Process.get(:events) ++ [Map.put(event, :event_sequence, sequence)])
    end

    defp test_pid, do: :persistent_term.get({__MODULE__, :test_pid})
  end

  setup do
    tmp = Path.join(System.tmp_dir!(), "loopex-api-fault-#{System.unique_integer([:positive])}")
    File.mkdir!(tmp)
    :persistent_term.put({Facade, :test_pid}, self())

    on_exit(fn ->
      :persistent_term.erase({Facade, :test_pid})
      File.rm_rf!(tmp)
    end)

    {:ok, tmp: tmp}
  end

  test "public prompt and wait bounds admit exact maxima and refuse max plus one", %{tmp: tmp} do
    session = start_session(tmp)
    prompt = String.duplicate("x", 32_768)

    assert {:ok, %{outcome: :completed}} = Ephemeral.ask(session, prompt, timeout: @uint64_max)
    assert_receive {:prompt_dispatched, _, first_id, ^prompt}

    assert {:error, {:invalid_prompt, :too_large}} = Ephemeral.ask(session, prompt <> "x")

    assert {:error, {:invalid_option, :timeout}} =
             Ephemeral.ask(session, "never dispatched", timeout: @uint64_max + 1)

    assert {:ok, %{entries: [%{role: :user, text: ^prompt} | _]}} = Ephemeral.history(session)
    assert {:ok, %{outcome: :completed}} = Ephemeral.last_result(session)
    refute_receive {:prompt_dispatched, _, _, "never dispatched"}
    assert is_binary(first_id)
    assert :ok = Ephemeral.stop_session(session)
  end

  test "a fixed nonce pins prompt, answer, later prompt and abort identities", %{tmp: tmp} do
    session = start_session(tmp, command_nonce: @nonce)

    assert {:error, {:interaction_pending, %{"interaction_id" => "identity-interaction"}}} =
             Ephemeral.ask(session, "identity-question")

    assert_receive {:prompt_dispatched, _, @first_prompt_id, "identity-question"}

    assert {:ok, %{outcome: :completed}} =
             Ephemeral.answer(session, "identity-interaction", "yes")

    assert_receive {:answer_dispatched, _, @answer_id}

    assert {:error, {:timeout, %{run_id: _}}} =
             Ephemeral.ask(session, "identity-abort", timeout: 30)

    assert_receive {:prompt_dispatched, _, @second_prompt_id, "identity-abort"}
    assert :ok = Ephemeral.stop_session(session)
    assert_receive {:abort_dispatched, _, @abort_id}
  end

  test "malformed pending interaction numbers never become a public question", %{tmp: tmp} do
    for mode <- ["turn-zero", "turn-overflow", "expiry-zero", "expiry-overflow"] do
      session = start_session(tmp)

      assert {:error, {:cleanup_unproved, %{pending: pending, ending: :none, root: root}}} =
               Ephemeral.ask(session, mode)

      assert :run_ending in pending
      assert File.dir?(root)
      assert {:error, :session_unavailable} = Ephemeral.last_result(session)
    end

    session = start_session(tmp)

    assert {:error,
            {:interaction_pending,
             %{
               "interaction_id" => "numeric-interaction",
               "turn" => @uint64_max,
               "expires_at" => @uint64_max
             }}} = Ephemeral.ask(session, "question-max")

    assert {:ok, %{outcome: :completed}} =
             Ephemeral.answer(session, "numeric-interaction", "yes")

    assert :ok = Ephemeral.stop_session(session)
  end

  test "malformed interaction members and choices never become public questions", %{tmp: tmp} do
    mutation_key = {Facade, :question_mutation}
    on_exit(fn -> :persistent_term.erase(mutation_key) end)

    malformed = [
      {"missing interaction id", &Map.delete(&1, "interaction_id")},
      {"empty interaction id", &Map.put(&1, "interaction_id", "")},
      {"invalid UTF-8 interaction id", &Map.put(&1, "interaction_id", <<255>>)},
      {"oversized interaction id", &Map.put(&1, "interaction_id", String.duplicate("x", 257))},
      {"missing call id", &Map.delete(&1, "tool_call_id")},
      {"oversized call id", &Map.put(&1, "tool_call_id", String.duplicate("x", 65_537))},
      {"empty prompt", &Map.put(&1, "prompt", "")},
      {"invalid UTF-8 prompt", &Map.put(&1, "prompt", <<255>>)},
      {"missing choices", &Map.delete(&1, "choices")},
      {"empty choices", &Map.put(&1, "choices", [])},
      {"too many distinct choices", &Map.put(&1, "choices", choices(9))},
      {"duplicate choice ids",
       &Map.put(&1, "choices", [
         %{"id" => "yes", "label" => "Yes"},
         %{"id" => "yes", "label" => "Again"}
       ])},
      {"choice with extra member",
       &Map.put(&1, "choices", [%{"id" => "yes", "label" => "Yes", "grant" => true}])},
      {"oversized choice id",
       &Map.put(&1, "choices", [%{"id" => String.duplicate("x", 65), "label" => "Yes"}])},
      {"invalid choice label", &Map.put(&1, "choices", [%{"id" => "yes", "label" => <<255>>}])}
    ]

    for {shape, mutate} <- malformed do
      :persistent_term.put(mutation_key, mutate)
      session = start_session(tmp)

      assert {:error,
              {:cleanup_unproved,
               %{pending: pending, ending: :none, root: root, root_ownership: :owned}}} =
               Ephemeral.ask(session, "malformed-question"),
             shape

      assert :run_ending in pending, shape
      assert File.dir?(root), shape
      assert {:error, :session_unavailable} = Ephemeral.last_result(session), shape
      refute_receive {:answer_dispatched, _, _}
    end

    :persistent_term.put(mutation_key, &Map.put(&1, "choices", choices(8)))
    session = start_session(tmp)

    assert {:error,
            {:interaction_pending,
             %{"interaction_id" => "malformed-interaction", "choices" => offered} = question}} =
             Ephemeral.ask(session, "malformed-question")

    assert offered == choices(8)
    assert {:error, {:interaction_pending, ^question}} = Ephemeral.last_result(session)

    assert {:ok, %{outcome: :completed}} =
             Ephemeral.answer(session, "malformed-interaction", "choice-8")

    assert :ok = Ephemeral.stop_session(session)
  end

  test "invalid answer ids leave the exact pending question unchanged", %{tmp: tmp} do
    session = start_session(tmp)

    assert {:error, {:interaction_pending, question}} =
             Ephemeral.ask(session, "identity-question")

    for interaction_id <- [nil, 17, "", <<255>>, String.duplicate("x", 257), "stale"] do
      assert {:error, :invalid_interaction_answer} =
               Ephemeral.answer(session, interaction_id, "yes")

      assert {:error, {:interaction_pending, ^question}} = Ephemeral.last_result(session)
    end

    for choice_id <- [nil, 17, "", <<255>>, String.duplicate("x", 65), "unoffered"] do
      assert {:error, :invalid_interaction_answer} =
               Ephemeral.answer(session, "identity-interaction", choice_id)

      assert {:error, {:interaction_pending, ^question}} = Ephemeral.last_result(session)
    end

    assert {:error, :run_open} = Ephemeral.ask(session, "second prompt")
    refute_receive {:answer_dispatched, _, _}
    refute_receive {:prompt_dispatched, _, _, "second prompt"}

    assert {:ok, %{outcome: :completed}} =
             Ephemeral.answer(session, "identity-interaction", "yes")

    assert_receive {:answer_dispatched, _, _}
    assert :ok = Ephemeral.stop_session(session)
  end

  test "an admitted timeout continues to a later ending without a second prompt", %{tmp: tmp} do
    session = start_session(tmp)

    assert {:error, {:timeout, %{run_id: run_id} = partial}} =
             Ephemeral.ask(session, "continue", timeout: 30)

    assert_receive {:prompt_dispatched, _actor, command_id, "continue"}
    assert run_id == "run-" <> command_id
    assert {:error, {:timeout, ^partial}} = Ephemeral.last_result(session)
    assert {:error, :run_open} = Ephemeral.ask(session, "not yet")

    :persistent_term.put({Facade, :finish_now}, true)
    on_exit(fn -> :persistent_term.erase({Facade, :finish_now}) end)

    assert eventually(fn ->
             match?({:ok, %{outcome: :completed}}, Ephemeral.last_result(session))
           end)

    assert {:ok, %{outcome: :completed, run_id: ^run_id}} = Ephemeral.last_result(session)
    refute_receive {:prompt_dispatched, _, _, "not yet"}
    assert {:ok, %{outcome: :completed}} = Ephemeral.ask(session, "next")
    assert :ok = Ephemeral.stop_session(session)
  end

  test "a post-timeout background disconnect retains its root and exposes only lifecycle failure",
       %{
         tmp: tmp
       } do
    session = start_session(tmp)
    {:loopex_ephemeral_session, owner, cell} = session
    root = :sys.get_state(owner).startup.owned_root.path
    owner_monitor = Process.monitor(owner)

    assert {:error, {:timeout, %{run_id: run_id} = partial}} =
             Ephemeral.ask(session, "background-disconnect", timeout: 30)

    assert_receive {:prompt_dispatched, _actor, command_id, "background-disconnect"}
    assert run_id == "run-" <> command_id
    assert {:error, {:timeout, ^partial}} = Ephemeral.last_result(session)
    assert :sys.get_state(owner).session.active.borrower == nil
    assert File.dir?(root)

    on_exit(fn -> :persistent_term.erase({Facade, :fail_background}) end)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        :persistent_term.put({Facade, :fail_background}, true)
        assert_receive {:DOWN, ^owner_monitor, :process, ^owner, :normal}, 7_000
      end)

    assert log =~ "ephemeral cleanup unproved root=#{inspect(root)} pending=[:run_ending]"
    assert :atomics.get(cell, 1) == 3
    assert File.dir?(root)
    assert {:error, :session_unavailable} = Ephemeral.last_result(session)
    assert {:error, :session_unavailable} = Ephemeral.ask(session, "later")
    assert {:error, :session_unavailable} = Ephemeral.stop_session(session)
  end

  test "a timed-out granted call keeps its one command identity through a late reply", %{tmp: tmp} do
    session = start_session(tmp)
    {:loopex_ephemeral_session, owner, _cell} = session

    pending = Task.async(fn -> Ephemeral.ask(session, "held-reply", timeout: 30) end)
    assert_receive {:prompt_dispatched, actor, command_id, "held-reply"}

    assert %{session: %{active: %{command_id: ^command_id, admission: :granted}}} =
             :sys.get_state(owner)

    assert {:error, {:timeout, %{run_id: nil}}} = Task.await(pending, 2_000)
    assert {:error, :run_open} = Ephemeral.ask(session, "other")
    send(actor, :release_reply)

    assert eventually(fn ->
             match?({:ok, %{run_id: "run-" <> ^command_id}}, Ephemeral.last_result(session))
           end)

    refute_receive {:prompt_dispatched, _, _, "held-reply"}
    refute_receive {:prompt_dispatched, _, _, "other"}
    assert :ok = Ephemeral.stop_session(session)
  end

  test "a mismatched accepted id cannot complete or regenerate a prompt", %{tmp: tmp} do
    session = start_session(tmp, command_nonce: @nonce)

    assert {:error,
            {:cleanup_unproved,
             %{
               pending: pending,
               ending: {:error, {:session_unavailable, %{run_id: nil}}},
               root: root
             }}} =
             Ephemeral.ask(session, "wrong-accept")

    assert_receive {:prompt_dispatched, _, @first_prompt_id, "wrong-accept"}
    assert :run_ending in pending
    assert File.dir?(root)
    refute_receive {:prompt_dispatched, _, _, "wrong-accept"}
    assert {:error, :session_unavailable} = Ephemeral.last_result(session)
  end

  test "pre-admission refusal stays local, while an invalid terminal fails the session", %{
    tmp: tmp
  } do
    session = start_session(tmp)
    assert {:error, :run_open} = Ephemeral.ask(session, "pre-refuse")
    assert_receive {:prompt_dispatched, _, _, "pre-refuse"}
    assert :none = Ephemeral.last_result(session)

    assert {:ok, %{outcome: :completed}} = Ephemeral.ask(session, "after-refuse")
    assert {:ok, %{outcome: :completed}} = Ephemeral.last_result(session)
    assert :ok = Ephemeral.stop_session(session)

    bad = start_session(tmp)

    assert {:error, {:cleanup_unproved, %{pending: pending, ending: :none, root: root}}} =
             Ephemeral.ask(bad, "bad-terminal")

    assert :run_ending in pending
    assert File.dir?(root)
    assert {:error, :session_unavailable} = Ephemeral.last_result(bad)
  end

  test "a terminal for another run cannot end the current one", %{tmp: tmp} do
    session = start_session(tmp)

    assert {:ok, %{outcome: :completed, run_id: run_id}} =
             Ephemeral.ask(session, "stale-terminal")

    assert run_id != "previous-run"
    assert {:ok, %{run_id: ^run_id}} = Ephemeral.last_result(session)
    assert :ok = Ephemeral.stop_session(session)
  end

  test "a lost attachment after admission reports an ending inside cleanup failure", %{tmp: tmp} do
    session = start_session(tmp)

    assert {:error,
            {:cleanup_unproved,
             %{
               pending: pending,
               ending: {:error, {:session_unavailable, snapshot}},
               root: root
             }}} = Ephemeral.ask(session, "disconnect")

    assert :run_ending in pending
    assert snapshot.profile == :ephemeral
    assert snapshot.run_id != nil
    assert snapshot.waited_ms >= 0
    assert File.dir?(root)
    assert {:error, :session_unavailable} = Ephemeral.last_result(session)
  end

  defp start_session(tmp, opts \\ []) do
    {:ok, _digest, manifest} =
      Loopex.ResourcePack.digest(%{
        "version" => "loopex.resource_pack/1",
        "workspace_ref" => "workspace-ref",
        "revision" => nil,
        "packs" => []
      })

    test = self()

    configuration =
      %{
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
          command_nonce: Keyword.get(opts, :command_nonce),
          temp_root: %{tmp: fn -> tmp end},
          group_attest: fn _executor, _instance, _nonce, _deadline -> :ok end,
          group_drain: fn executor, instance, owner, nonce, _deadline ->
            send(test, {:group_drain, executor, instance})
            send(owner, {executor, instance, nonce, :groups_empty})
            {:ok, nonce}
          end
        }
      }
      |> LoopexComposition.PreparedSessionFixture.capture()

    {:ok, supervisor} = DynamicSupervisor.start_link(strategy: :one_for_one)
    {:ok, activation} = OwnerActivation.start(supervisor)
    owner = OwnerActivation.owner(activation)
    {:ok, cell} = OwnerActivation.begin(activation)
    assert {:ok, :session_ready} = SessionOwner.start_session(owner, configuration, 6_000)
    {:loopex_ephemeral_session, owner, cell}
  end

  defp eventually(predicate, attempts \\ 100)
  defp eventually(_predicate, 0), do: false

  defp eventually(predicate, attempts) do
    if predicate.() do
      true
    else
      Process.sleep(10)
      eventually(predicate, attempts - 1)
    end
  end

  defp choices(count),
    do: for(index <- 1..count, do: %{"id" => "choice-#{index}", "label" => "Choice #{index}"})
end
