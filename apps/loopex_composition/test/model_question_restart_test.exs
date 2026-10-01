Code.require_file("../../loopex/test/support/configured_genesis_helper.exs", __DIR__)

defmodule LoopexComposition.ModelQuestionRestartTest do
  use ExUnit.Case, async: false

  alias Loopex.Runtime
  alias Loopex.Runtime.SessionState
  alias Loopex.Store.Local
  alias LoopexProtocol.ToolDefinition

  defmodule Model do
    @moduledoc false
    @behaviour Loopex.Model

    @impl Loopex.Model
    def complete(request, options, _progress) do
      calls =
        Agent.get_and_update(options[:observer], fn seen ->
          calls =
            if seen == [],
              do: [
                %{
                  id: "ask-1",
                  name: "ask",
                  arguments: %{
                    "question" => "Which encoding?",
                    "choices" => ["empty", "literal null"]
                  }
                }
              ],
              else: []

          {calls, seen ++ [request]}
        end)

      {:ok,
       %{
         text: "done",
         identity: %{provider: "scripted", model: request.model, endpoint: "in-process"},
         usage: %{input_tokens: 1, output_tokens: 1},
         tool_calls: calls,
         delta_count: 0,
         streamed: false,
         canonical_request_bytes: request.canonical_request_bytes,
         staged_request_digest: request.staged_request_digest
       }}
    end
  end

  defmodule Policy do
    @moduledoc false
    @behaviour Loopex.Policy
    @impl Loopex.Policy
    def decide(_request), do: {:allow, nil}
  end

  defmodule Executor do
    @moduledoc false
    @behaviour Loopex.Executor
    @impl Loopex.Executor
    def execute(observer, _job, _grant, _options, _progress) do
      Agent.update(observer, &["unexpected effect" | &1])
      {:error, {:refused_before_effect, :unexpected_effect}}
    end

    @impl Loopex.Executor
    def cancel(_observer, _job), do: {:ok, :cleaned}
  end

  test "a local Store process restart retains the exact pending question and terminal answer" do
    root =
      Path.join(
        System.tmp_dir!(),
        "loopex-m7-question-#{Base.encode16(:crypto.strong_rand_bytes(12))}"
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    path = Path.join(root, "store.log")
    {:ok, model} = Agent.start_link(fn -> [] end)
    {:ok, effects} = Agent.start_link(fn -> [] end)
    definition = ToolDefinition.question_definition()
    {:ok, store} = Local.start_link(path: path)
    runtime = start_runtime(store, model, effects, [definition])

    assert {:ok, session} =
             Runtime.create_session_with_genesis(
               runtime,
               "create",
               %{},
               Loopex.ConfiguredGenesisFixture.genesis([definition])
             )

    assert {:ok, attachment} = Loopex.attach(runtime, session, after_event_sequence: 0)

    assert {:accepted, "prompt"} =
             Loopex.command(attachment, %{
               type: :prompt,
               command_id: "prompt",
               content: "implement"
             })

    question = await_event(attachment, "interaction.requested")
    {:ok, before_records} = Local.load_records(store, session, 0, 1_000)
    pending = Enum.find(before_records, &(&1.payload.kind == "model_question_requested_v1"))
    assert Agent.get(model, &length/1) == 1
    assert Agent.get(effects, & &1) == []
    assert :ok = Loopex.stop(runtime)
    assert :ok = GenServer.stop(store)
    refute Process.alive?(store)

    {:ok, second_store} = Local.start_link(path: path)
    second_runtime = start_runtime(second_store, model, effects, [])
    assert {:ok, ^session} = Loopex.resume_session(second_runtime, session, command_id: "resume")

    assert {:ok, second_attachment} =
             Loopex.attach(second_runtime, session, after_event_sequence: 0)

    assert await_event(second_attachment, "interaction.requested") == question
    assert Agent.get(model, &length/1) == 1

    answer = %{
      type: :interaction_answer,
      command_id: "answer",
      interaction_id: question["interaction_id"],
      choice_id: "choice-2"
    }

    assert {:accepted, "answer"} = Loopex.command(second_attachment, answer)
    terminal = await_event(second_attachment, "interaction.answered")
    assert terminal["answer"] == %{"choice_id" => "choice-2", "label" => "literal null"}
    assert await_event(second_attachment, "run.finished")["outcome"] == "completed"
    [_, next_request] = Agent.get(model, & &1)
    assert Enum.find(next_request.messages, &(&1["role"] == "tool"))["content"] == "literal null"
    assert :ok = Loopex.stop(second_runtime)
    assert :ok = GenServer.stop(second_store)

    {:ok, third_store} = Local.start_link(path: path)
    third_runtime = start_runtime(third_store, model, effects, [])

    assert {:ok, ^session} =
             Loopex.resume_session(third_runtime, session, command_id: "resume-final")

    assert {:ok, final_attachment} =
             Loopex.attach(third_runtime, session, after_event_sequence: 0)

    assert {:accepted, "answer"} = Loopex.command(final_attachment, answer)
    {:ok, records} = Local.load_records(third_store, session, 0, 1_000)
    {:ok, events} = Local.load_events(third_store, session, 0, 1_000)
    assert Enum.filter(records, &(&1.payload.kind == "model_question_requested_v1")) == [pending]
    assert Enum.count(records, &(&1.payload.kind == "model_question_response_admitted_v1")) == 1
    assert Enum.count(events, &(&1.kind == "interaction.answered")) == 1
    assert {:ok, recovered} = SessionState.recover(session, records, events)
    assert is_nil(recovered.open_interaction)

    assert recovered.interactions[question["interaction_id"]].answer == %{
             "choice_id" => "choice-2"
           }

    assert Agent.get(model, &length/1) == 2
    assert Agent.get(effects, & &1) == []
    assert :ok = Loopex.stop(third_runtime)
    assert :ok = GenServer.stop(third_store)
  end

  defp start_runtime(store_pid, model, effects, definitions) do
    {:ok, store} = Loopex.Store.new(Local, store_pid)

    {:ok, runtime} =
      Loopex.start_link(
        runtime_id: "m7-question-restart",
        store: store,
        context_token_budget: 8_192,
        model: %{
          module: Model,
          model: "scripted:v1",
          options: [observer: model, max_tokens: 1_024]
        },
        executor: %{
          module: Executor,
          reference: effects,
          identity: "question-test",
          epoch: 1,
          fencing_token: 1,
          workspace_ref: "workspace",
          workspace_lease: "lease"
        },
        tools: definitions,
        active_tools: Enum.map(definitions, & &1["tool_id"]),
        policy: Policy,
        policy_identity: %{"id" => "question-policy", "revision" => "1"},
        grant_decision: {:host_policy, :allow}
      )

    on_exit(fn ->
      if Process.alive?(runtime.supervisor), do: Loopex.stop(runtime)
      if Process.alive?(store_pid), do: GenServer.stop(store_pid)
    end)

    runtime
  end

  defp await_event(attachment, kind, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + 5_000

    case Loopex.next_event(attachment) do
      {:ok, %{kind: ^kind} = event} ->
        event

      _ ->
        if System.monotonic_time(:millisecond) >= deadline, do: flunk("missing #{kind}")
        Process.sleep(10)
        await_event(attachment, kind, deadline)
    end
  end
end
