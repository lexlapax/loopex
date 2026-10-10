Code.require_file("support/m1_runtime_helper.exs", __DIR__)
Code.require_file("support/agent_loop_helper.exs", __DIR__)
Code.require_file("support/configured_genesis_helper.exs", __DIR__)

defmodule Loopex.PolicyContextTest do
  use ExUnit.Case, async: false

  alias Loopex.AgentLoopFixture, as: Fixture
  alias Loopex.Policy
  alias LoopexProtocol.ToolDefinition

  defmodule Adapter do
    @moduledoc false
    @behaviour Loopex.Policy
    @impl true
    def decide(_request), do: {:allow, nil}

    @impl true
    def decide(request, {observer, marker, result}) do
      send(observer, {:context_decision, self(), request, marker})

      case result do
        :raise -> raise "private callback failure"
        :exit -> exit(:private_callback_failure)
        :kill -> Process.exit(self(), :kill)
        :block -> receive do: (:release -> {:allow, nil})
        answer -> answer
      end
    end
  end

  defmodule Legacy do
    @moduledoc false
    @behaviour Loopex.Policy
    @impl true
    def decide(_request), do: {:allow, nil}
  end

  test "bare modules keep decide/1 while explicit context selects decide/2 exactly once" do
    request = request()
    assert Policy.evaluate(Adapter, request) == {:allow, nil}
    assert Policy.evaluate(Adapter, request) == {:allow, nil}
    assert Policy.evaluate_callback(Adapter, request, :admit_defer) == {:allow, nil}
    refute_receive {:context_decision, _, _, _}, 0

    for evaluator <- [&Policy.evaluate/2, &Policy.evaluate_callback/2] do
      adapter = %{module: Adapter, context: {self(), "private-context", {:deny, :policy_denied}}}
      assert evaluator.(adapter, request) == {:deny, :policy_denied}
      assert_receive {:context_decision, _, ^request, "private-context"}
      refute_receive {:context_decision, _, _, _}, 0
    end
  end

  test "the contextual callback uses the unchanged decision and defer validators" do
    question = %{
      kind: :choice,
      prompt: "Allow?",
      choices: [%{id: "yes", label: "Yes"}],
      expires_in_ms: 1000
    }

    for {answer, expected} <- [
          {{:allow, nil}, {:allow, nil}},
          {{:allow, %{extra: "private"}}, {:deny, :policy_unavailable}},
          {{:deny, :interaction_unsupported}, {:deny, :interaction_unsupported}},
          {{:deny, :invented}, {:deny, :policy_unavailable}},
          {{:defer, %{}}, {:deny, :policy_unavailable}},
          {:invented, {:deny, :policy_unavailable}},
          {:raise, {:deny, :policy_unavailable}},
          {:exit, {:deny, :policy_unavailable}}
        ] do
      adapter = %{module: Adapter, context: {self(), "exact", answer}}
      assert Policy.evaluate_callback(adapter, request(), :admit_defer) == expected
      assert_receive {:context_decision, _, _, "exact"}
      refute_receive {:context_decision, _, _, _}, 0
    end

    adapter = %{module: Adapter, context: {self(), "defer", {:defer, question}}}
    assert {:defer, %{kind: :choice}} = Policy.evaluate_callback(adapter, request(), :admit_defer)
    assert_receive {:context_decision, _, _, "defer"}

    assert Policy.evaluate_callback(adapter, request(), :refuse_defer) ==
             {:deny, :interaction_unsupported}

    assert_receive {:context_decision, _, _, "defer"}
  end

  test "contextual callback kill is contained by the monitored evaluator" do
    adapter = %{module: Adapter, context: {self(), "kill", :kill}}
    assert Policy.evaluate(adapter, request()) == {:deny, :policy_unavailable}
    assert_receive {:context_decision, worker, _, "kill"}
    refute Process.alive?(worker)
  end

  test "missing contextual callbacks and malformed references never fall back to legacy allow" do
    for adapter <- [
          %{module: Legacy, context: nil},
          %{module: Adapter},
          %{module: Adapter, context: nil, extra: true},
          %{module: "untrusted", context: nil},
          %{module: nil, context: nil}
        ] do
      refute Policy.valid_adapter?(adapter)
      assert Policy.evaluate(adapter, request()) == {:deny, :policy_unavailable}

      assert Policy.evaluate_callback(adapter, request(), :admit_defer) ==
               {:deny, :policy_unavailable}
    end

    assert Policy.valid_adapter?(Legacy)
    assert Policy.valid_adapter?(%{module: Adapter, context: nil})
  end

  test "invalid contextual startup refuses before creating any runtime process" do
    {store_pid, store} = Loopex.M1RuntimeTestStore.start_store()
    on_exit(fn -> GenServer.stop(store_pid) end)
    before = Loopex.M1RuntimeTestStore.inspect_state(store_pid)

    for adapter <- [
          %{module: Legacy, context: nil},
          %{module: Adapter, context: nil, extra: true}
        ] do
      assert Loopex.start_link(
               runtime_id: "invalid-context-policy",
               store: store,
               context_token_budget: 8192,
               policy: adapter,
               policy_identity: %{"id" => "explicit-host-policy", "revision" => "1"}
             ) == {:error, :host_policy_required}
    end

    assert before == Loopex.M1RuntimeTestStore.inspect_state(store_pid)
  end

  test "an actual owner receives runtime-private context and denies before opening a model question" do
    marker = "private-context-must-stay-out-of-history"
    policy = %{module: Adapter, context: {self(), marker, {:deny, :interaction_unsupported}}}

    fixture =
      Fixture.start(
        tools: [ToolDefinition.question_definition()],
        policy: policy,
        script: [
          %{
            text: "Question",
            calls: [%{id: "ask-1", name: "ask", arguments: %{"question" => "Which encoding?"}}]
          },
          %{text: "done", calls: []}
        ]
      )

    on_exit(fn -> Fixture.stop(fixture) end)

    assert {:ok, session} =
             Loopex.create_session(fixture.runtime, %{},
               command_id: "create",
               genesis: Loopex.ConfiguredGenesisFixture.genesis(fixture.definitions)
             )

    assert {:ok, attachment} = Loopex.attach(fixture.runtime, session, after_event_sequence: 0)

    assert {:accepted, "prompt"} =
             Loopex.command(attachment, %{type: :prompt, command_id: "prompt", content: "go"})

    assert_receive {:context_decision, _, request, ^marker}, 5000
    assert request.arguments == %{"question" => "Which encoding?"}
    assert elem(request.generation, 0) == "loopex.ask"
    events = finish(attachment, System.monotonic_time(:millisecond) + 5000, [])
    assert List.last(events).kind == "run.finished"
    refute Enum.any?(events, &(&1.kind == "interaction.requested"))

    assert Enum.any?(
             events,
             &(&1.kind == "tool.finished" and &1["reason"] == "interaction_unsupported")
           )

    assert Agent.get(fixture.executor, & &1.jobs) == []
    records = Fixture.records(fixture, session)
    refute Enum.any?(records, &String.starts_with?(&1.payload.kind, "interaction_pending"))
    refute :erlang.term_to_binary({records, events}) =~ marker
    refute_receive {:context_decision, _, _, _}, 0
  end

  test "ordinary effects retain the same allow and consult their contextual policy once" do
    marker = "ordinary-private-context"

    fixture =
      Fixture.start(
        policy: %{module: Adapter, context: {self(), marker, {:allow, nil}}},
        script: [
          %{
            text: "write",
            calls: [%{id: "write-1", name: "write", arguments: %{"path" => "file.txt"}}]
          },
          %{text: "done", calls: []}
        ]
      )

    on_exit(fn -> Fixture.stop(fixture) end)
    assert {:ok, session} = Loopex.create_session(fixture.runtime, %{}, command_id: "create")
    assert {:ok, attachment} = Loopex.attach(fixture.runtime, session, after_event_sequence: 0)

    assert {:accepted, "prompt"} =
             Loopex.command(attachment, %{type: :prompt, command_id: "prompt", content: "go"})

    assert_receive {:context_decision, _, request, ^marker}, 5000
    assert request.arguments == %{"path" => "file.txt"}
    events = finish(attachment, System.monotonic_time(:millisecond) + 5000, [])
    assert length(Agent.get(fixture.executor, & &1.jobs)) == 1
    refute :erlang.term_to_binary({Fixture.records(fixture, session), events}) =~ marker
    refute_receive {:context_decision, _, _, _}, 0
  end

  test "policy spans name only the adapter module and retain no callback context" do
    observer = self()
    id = {__MODULE__, make_ref()}

    assert :ok =
             :telemetry.attach_many(
               id,
               [[:loopex, :policy, :decide, :start], [:loopex, :policy, :decide, :stop]],
               &__MODULE__.observe_span/4,
               observer
             )

    try do
      marker = "private-context-not-telemetry"
      adapter = %{module: Adapter, context: {self(), marker, {:allow, nil}}}
      assert Policy.evaluate_callback(adapter, request()) == {:allow, nil}
      assert_receive {:context_decision, _, _, ^marker}

      for suffix <- [:start, :stop] do
        assert_receive {:policy_span, [:loopex, :policy, :decide, ^suffix], measurements,
                        metadata}

        assert metadata.policy == inspect(Adapter)
        refute :erlang.term_to_binary({measurements, metadata}) =~ marker
        refute Map.has_key?(metadata, :context)
      end
    after
      :telemetry.detach(id)
    end
  end

  @doc false
  def observe_span(event, measurements, metadata, parent),
    do: send(parent, {:policy_span, event, measurements, metadata})

  test "abort joins a blocked contextual policy worker without opening a question" do
    fixture =
      Fixture.start(
        tools: [ToolDefinition.question_definition()],
        policy: %{module: Adapter, context: {self(), "blocked", :block}},
        script: [
          %{
            text: "question",
            calls: [%{id: "ask-1", name: "ask", arguments: %{"question" => "Wait?"}}]
          }
        ]
      )

    on_exit(fn -> Fixture.stop(fixture) end)

    assert {:ok, session} =
             Loopex.create_session(fixture.runtime, %{},
               command_id: "create",
               genesis: Loopex.ConfiguredGenesisFixture.genesis(fixture.definitions)
             )

    assert {:ok, attachment} = Loopex.attach(fixture.runtime, session, after_event_sequence: 0)

    assert {:accepted, "prompt"} =
             Loopex.command(attachment, %{type: :prompt, command_id: "prompt", content: "go"})

    assert_receive {:context_decision, worker, _, "blocked"}, 5000
    monitor = Process.monitor(worker)
    assert Process.alive?(worker)

    assert {:accepted, "abort"} =
             Loopex.command(attachment, %{type: :abort, command_id: "abort"})

    events = finish(attachment, System.monotonic_time(:millisecond) + 5000, [])
    assert List.last(events)["outcome"] == "cancelled"
    assert_receive {:DOWN, ^monitor, :process, ^worker, :shutdown}, 5000
    refute Process.alive?(worker)
    refute Enum.any?(events, &(&1.kind == "interaction.requested"))
    assert Agent.get(fixture.executor, & &1.jobs) == []
  end

  defp request do
    %{
      session_id: "session",
      run_id: "run",
      tool_call_id: "call",
      generation: {"example.read", "1.0.0", String.duplicate("a", 64)},
      arguments: %{"path" => "file.txt"},
      effect_class: "read_only",
      idempotency_class: "safe_retry",
      workspace_lease: "workspace"
    }
  end

  defp finish(attachment, deadline, events) do
    assert System.monotonic_time(:millisecond) < deadline

    case Loopex.next_event(attachment) do
      {:ok, %{kind: "run.finished"} = event} ->
        Enum.reverse([event | events])

      {:ok, event} ->
        finish(attachment, deadline, [event | events])

      {:error, :empty} ->
        Process.sleep(5)
        finish(attachment, deadline, events)
    end
  end
end
