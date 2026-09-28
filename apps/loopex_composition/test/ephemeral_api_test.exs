defmodule LoopexComposition.Ephemeral.ApiTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias LoopexComposition.Ephemeral
  alias LoopexComposition.Ephemeral.{OwnerActivation, SessionOwner}

  defmodule Policy do
    @moduledoc false
    def decide(_request), do: {:allow, nil}
  end

  defmodule ScriptedFacade do
    @moduledoc false

    def create_session(_runtime, %{"surface" => "embedded"}, command_id: "create"),
      do: {:ok, "ephemeral-session"}

    def attach(runtime, "ephemeral-session", after_event_sequence: 0) do
      Process.put(:event_sequence, 0)
      Process.put(:events, [])

      {:ok,
       %Loopex.Attachment{
         runtime: runtime,
         session_id: "ephemeral-session",
         attachment_id: "a",
         incarnation_id: "i",
         snapshot: %{}
       }}
    end

    def session_status(_runtime, "ephemeral-session"),
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
      run_id = "run-#{Process.get(:event_sequence) + 1}"
      Process.put(:run_id, run_id)
      Process.put(:unending, command.content == "unending")

      enqueue(%{
        :kind => "user.message_appended",
        "command_id" => command.command_id,
        "run_id" => run_id,
        "content" => command.content
      })

      cond do
        command.content in ["slow", "unending"] ->
          :ok

        command.content == "question" ->
          enqueue(%{
            :kind => "interaction.requested",
            "run_id" => run_id,
            "interaction_id" => "interaction-1",
            "turn" => 1,
            "tool_call_id" => "call-1",
            "prompt" => "Continue?",
            "choices" => [%{"id" => "yes", "label" => "Yes"}],
            "expires_at" => 1_800_000_000
          })

        command.content == "unknown" ->
          enqueue(%{
            :kind => "run.finished",
            "run_id" => run_id,
            "outcome" => "outcome_unknown",
            "cleanup_grace_ms" => 5_000,
            "reconciliation_ref" => "reconcile-1"
          })

        true ->
          enqueue(%{
            :kind => "assistant.message_appended",
            "run_id" => run_id,
            "content" => "answer: " <> command.content
          })

          finish(run_id, "completed")
      end

      {:accepted, command.command_id}
    end

    def command(_attachment, %{type: :interaction_answer} = command) do
      run_id = Process.get(:run_id)

      enqueue(%{
        :kind => "assistant.message_appended",
        "run_id" => run_id,
        "content" => "choice: " <> command.choice_id
      })

      finish(run_id, "completed")
      {:accepted, command.command_id}
    end

    def command(_attachment, %{type: :abort} = command) do
      unless Process.get(:unending), do: finish(Process.get(:run_id), "cancelled")
      {:accepted, command.command_id}
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

    defp finish(run_id, outcome),
      do:
        enqueue(%{
          :kind => "run.finished",
          "run_id" => run_id,
          "outcome" => outcome,
          "cleanup_grace_ms" => 5_000
        })

    defp enqueue(event) do
      sequence = Process.get(:event_sequence) + 1
      Process.put(:event_sequence, sequence)
      Process.put(:events, Process.get(:events) ++ [Map.put(event, :event_sequence, sequence)])
    end
  end

  setup do
    tmp = Path.join(System.tmp_dir!(), "loopex-api-#{System.unique_integer([:positive])}")
    File.mkdir!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)
    {:ok, tmp: tmp}
  end

  test "public validation preserves option and prompt precedence" do
    assert {:error, {:invalid_option, :options}} = Ephemeral.run("hello", :bad)
    assert {:error, {:invalid_option, :options}} = Ephemeral.run("", :bad)
    assert {:error, {:invalid_prompt, :empty}} = Ephemeral.run("", policy: Policy)

    assert {:error, {:invalid_prompt, :too_large}} =
             Ephemeral.run(String.duplicate("x", 32_769), policy: Policy)

    assert {:error, :session_unavailable} = Ephemeral.ask(:bad, "")
    assert {:error, :session_unavailable} = Ephemeral.answer(:bad, "", "")
    assert {:error, :session_unavailable} = Ephemeral.stop_session(:bad)
  end

  test "an idle session stops with proved cleanup and an absorbing handle", %{tmp: tmp} do
    session = start_private_session(tmp)
    assert :none = Ephemeral.last_result(session)
    assert {:ok, %{entries: [], truncated: false}} = Ephemeral.history(session)
    assert {:error, {:invalid_option, :unknown_key}} = Ephemeral.ask(session, "hi", model: "x")
    assert {:error, {:invalid_prompt, :empty}} = Ephemeral.ask(session, "")
    assert :ok = Ephemeral.stop_session(session)
    assert :ok = Ephemeral.stop_session(session)
    assert {:error, :session_closed} = Ephemeral.last_result(session)
    assert {:error, :session_closed} = Ephemeral.ask(session, "hello")
  end

  test "ask joins its run and projects terminal text and committed history", %{tmp: tmp} do
    session = start_private_session(tmp, ScriptedFacade)

    assert {:ok,
            %{
              text: "answer: hello",
              run_id: "run-1",
              outcome: :completed,
              details: %{"cleanup_grace_ms" => 5_000}
            }} = Ephemeral.ask(session, "hello")

    assert {:ok, %{text: "answer: hello"}} = Ephemeral.last_result(session)

    assert {:ok,
            %{
              entries: [%{role: :user, text: "hello"}, %{role: :assistant, text: "answer: hello"}],
              truncated: false
            }} =
             Ephemeral.history(session)

    assert :ok = Ephemeral.stop_session(session)
  end

  test "an interaction remains open until an offered answer is accepted", %{tmp: tmp} do
    session = start_private_session(tmp, ScriptedFacade)

    assert {:error,
            {:interaction_pending, %{"interaction_id" => "interaction-1", "status" => "pending"}}} =
             Ephemeral.ask(session, "question")

    assert {:error, :run_open} = Ephemeral.ask(session, "second")
    assert {:error, :invalid_interaction_answer} = Ephemeral.answer(session, "bad", "yes")

    assert {:ok, %{text: "choice: yes", outcome: :completed}} =
             Ephemeral.answer(session, "interaction-1", "yes")

    assert :ok = Ephemeral.stop_session(session)
  end

  test "stop aborts an unanswered interaction and proves its terminal", %{tmp: tmp} do
    session = start_private_session(tmp, ScriptedFacade)

    assert {:error, {:interaction_pending, %{"interaction_id" => "interaction-1"}}} =
             Ephemeral.ask(session, "question")

    assert :ok = Ephemeral.stop_session(session)
    assert :ok = Ephemeral.stop_session(session)
  end

  test "a timed-out ask continues under the one event reader until stop aborts it", %{tmp: tmp} do
    session = start_private_session(tmp, ScriptedFacade)

    assert {:error, {:timeout, %{run_id: "run-1", waited_ms: waited}}} =
             Ephemeral.ask(session, "slow", timeout: 20)

    assert waited >= 0
    assert {:error, {:timeout, %{run_id: "run-1"}}} = Ephemeral.last_result(session)
    assert {:error, :run_open} = Ephemeral.ask(session, "later")
    assert :ok = Ephemeral.stop_session(session)
  end

  test "a missing terminal retains the root and reports only reached proof failures", %{tmp: tmp} do
    session = start_private_session(tmp, ScriptedFacade)

    assert {:error, {:timeout, %{run_id: "run-1"}}} =
             Ephemeral.ask(session, "unending", timeout: 20)

    assert {:error,
            {:cleanup_unproved,
             %{pending: [:run_ending], root: root, root_ownership: :owned, cause: nil}}} =
             Ephemeral.stop_session(session)

    assert File.dir?(root)
    assert {:error, :session_unavailable} = Ephemeral.ask(session, "later")
  end

  test "an unknown outcome keeps effect cleanup unproved after its terminal", %{tmp: tmp} do
    session = start_private_session(tmp, ScriptedFacade)

    assert {:error,
            {:run, :outcome_unknown, %{details: %{"reconciliation_ref" => "reconcile-1"}}}} =
             Ephemeral.ask(session, "unknown")

    assert {:error, {:cleanup_unproved, %{pending: [:effect_cleanup], root: root}}} =
             Ephemeral.stop_session(session)

    assert File.dir?(root)
  end

  defp start_private_session(tmp, facade \\ Loopex) do
    {:ok, _digest, manifest} =
      Loopex.ResourcePack.digest(%{
        "version" => "loopex.resource_pack/1",
        "workspace_ref" => "workspace-ref",
        "revision" => nil,
        "packs" => []
      })

    test = self()

    config = %{
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
      test_facade: facade,
      test_seams: %{
        temp_root: %{tmp: fn -> tmp end},
        group_drain: fn executor, instance, owner, nonce, _deadline ->
          send(test, {:group_drain, executor, instance})
          send(owner, {executor, instance, nonce, :groups_empty})
          {:ok, nonce}
        end
      }
    }

    {:ok, supervisor} = DynamicSupervisor.start_link(strategy: :one_for_one)
    {:ok, activation} = OwnerActivation.start(supervisor)
    owner = OwnerActivation.owner(activation)
    {:ok, cell} = OwnerActivation.begin(activation)
    assert {:ok, :session_ready} = SessionOwner.start_session(owner, config, 6_000)
    {:loopex_ephemeral_session, owner, cell}
  end
end
