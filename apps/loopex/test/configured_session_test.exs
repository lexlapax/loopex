Code.require_file("support/m1_runtime_helper.exs", __DIR__)
Code.require_file("support/agent_loop_helper.exs", __DIR__)
Code.require_file("support/configured_genesis_helper.exs", __DIR__)

defmodule Loopex.ConfiguredSessionDeferringPolicy do
  @moduledoc false
  @behaviour Loopex.Policy
  @impl Loopex.Policy
  def decide(_request) do
    {:defer,
     %{
       kind: :choice,
       prompt: "Allow this write?",
       choices: [%{id: "allow", label: "Allow"}],
       expires_in_ms: 700
     }}
  end
end

defmodule Loopex.ConfiguredQuestionCountingPolicy do
  @moduledoc false
  @behaviour Loopex.Policy
  @impl Loopex.Policy
  def decide(request) do
    send(
      Process.whereis(:m7_question_policy_observer),
      {:question_policy_call, request.tool_call_id}
    )

    {:allow, nil}
  end
end

defmodule Loopex.ConfiguredSessionTest do
  use ExUnit.Case, async: false

  import Loopex.ConfiguredGenesisFixture,
    only: [configuration: 0, configuration: 1, genesis: 1, genesis: 2]

  alias Loopex.AgentLoopFixture, as: Fixture
  alias Loopex.AgentLoopTestModel
  alias Loopex.Runtime
  alias Loopex.Runtime.ContextAdmission
  alias Loopex.Runtime.Instructions
  alias Loopex.Runtime.SessionConfiguration
  alias Loopex.Runtime.SessionState
  alias LoopexProtocol.ToolDefinition
  alias LoopexProtocol.Canonical

  test "required v3 capsules commit atomically through unknown replies and survive restart" do
    for phase <- [:before, :after] do
      capsule = closed_capsule("done")

      fixture =
        start(
          progress_to: self(),
          script: [
            %{text: "done", reply_overrides: %{completion: "natural", continuation: capsule}}
          ]
        )

      captured = continuation_configuration()

      assert {:ok, session} =
               Runtime.create_session_with_genesis(
                 fixture.runtime,
                 "create",
                 %{},
                 genesis(fixture.definitions, captured)
               )

      assert {:ok, attachment} = Loopex.attach(fixture.runtime, session, after_event_sequence: 0)
      hold_record_commit(fixture, "model_attempt_settled_v3", phase)

      assert {:accepted, "prompt"} =
               Loopex.command(attachment, %{type: :prompt, command_id: "prompt", content: "go"})

      {waiter, exact} = await_record_commit(fixture, session, "model_attempt_settled_v3", phase)
      assert exact["result"]["reply"]["continuation"] == capsule
      assert exact["result"]["reply"]["completion"] == "natural"

      refute_receive {:loopex_progress, %{kind: :model_stream_closed}}, 0

      if phase == :before do
        refute Enum.any?(
                 Fixture.events(fixture, session),
                 &(&1.kind == "assistant.message_appended")
               )
      end

      assert Agent.get(fixture.executor, & &1.jobs) == []

      if phase == :before,
        do:
          assert(
            Enum.all?(
              Fixture.records(fixture, session),
              &(&1.payload.kind != "model_attempt_settled_v3")
            )
          )

      if phase == :before do
        Loopex.M1RuntimeTestStore.inject(
          fixture.store,
          {:session_journal_commit, :after_linearization_before_result}
        )
      end

      Loopex.M1RuntimeTestStore.release(waiter)
      events = finish(attachment)
      assert Enum.find(events, &(&1.kind == "run.finished"))["outcome"] == "completed"
      assert Enum.count(events, &(&1.kind == "assistant.message_appended")) == 1
      assert_receive {:loopex_progress, %{kind: :model_stream_closed}}, 5_000
      assert length(AgentLoopTestModel.dispatched(fixture.model)) == 1

      settlements =
        Enum.filter(
          Fixture.records(fixture, session),
          &(&1.payload.kind == "model_attempt_settled_v3")
        )

      assert Enum.map(settlements, & &1.payload) == [exact]
      assert :ok = Loopex.stop(fixture.runtime)
      restarted = start(store: fixture.store, script: [])

      assert {:ok, ^session} =
               Loopex.resume_session(restarted.runtime, session, command_id: "resume")

      assert {:ok, recovered} =
               SessionState.recover(
                 session,
                 Fixture.records(restarted, session),
                 Fixture.events(restarted, session)
               )

      assert recovered.provider_settlement_version == 3
      assert AgentLoopTestModel.dispatched(restarted.model) == []
      assert SessionState.run_configuration(recovered, hd(recovered.run_order)) == captured
    end
  end

  test "required continuation refuses v2 and malformed v3 before tools or reported accounting" do
    for overrides <- [
          %{},
          %{completion: "natural", continuation: closed_capsule("different")},
          %{completion: "limit", continuation: closed_capsule("done")}
        ] do
      fixture =
        start(
          script: [
            %{
              text: "done",
              calls: [%{id: "write-1", name: "write", arguments: %{}}],
              usage: %{input_tokens: 7, output_tokens: 5},
              reply_overrides: overrides
            }
          ]
        )

      captured = continuation_configuration()

      assert {:ok, session} =
               Runtime.create_session_with_genesis(
                 fixture.runtime,
                 "create",
                 %{},
                 genesis(fixture.definitions, captured)
               )

      assert {:ok, attachment} = Loopex.attach(fixture.runtime, session, after_event_sequence: 0)

      assert {:accepted, "prompt"} =
               Loopex.command(attachment, %{type: :prompt, command_id: "prompt", content: "go"})

      events = finish(attachment)
      assert Enum.find(events, &(&1.kind == "run.finished"))["outcome"] == "failed"
      refute Enum.any?(events, &(&1.kind in ["assistant.message_appended", "tool.started"]))
      assert Agent.get(fixture.executor, & &1.jobs) == []

      [settlement] =
        Enum.filter(
          Fixture.records(fixture, session),
          &(&1.payload.kind == "model_attempt_settled_v3")
        )

      assert settlement.payload["result"] == %{
               "kind" => "error",
               "category" => "unreadable_model_answer",
               "accounting_evidence" => %{"kind" => "none"}
             }

      assert settlement.payload["accounting"] == %{
               "source" => "estimated",
               "basis" => "remaining_allowance"
             }

      assert {:ok, recovered} =
               SessionState.recover(
                 session,
                 Fixture.records(fixture, session),
                 Fixture.events(fixture, session)
               )

      assert recovered.provider_settlement_version == 3
    end
  end

  test "open exchanges retain source-bound envelopes and independently measured costs" do
    fixture =
      start(
        script: [
          open_turn("first"),
          open_turn("second"),
          %{
            text: "done",
            reply_overrides: %{completion: "natural", continuation: closed_capsule("done")}
          },
          %{
            text: "next",
            reply_overrides: %{completion: "natural", continuation: closed_capsule("next")}
          }
        ]
      )

    assert {:ok, session} =
             Runtime.create_session_with_genesis(
               fixture.runtime,
               "create",
               %{},
               genesis(fixture.definitions, continuation_configuration())
             )

    assert {:ok, attachment} = Loopex.attach(fixture.runtime, session, after_event_sequence: 0)
    prompt(attachment, "first-prompt", "work")
    [first, second, third] = AgentLoopTestModel.dispatched(fixture.model)
    assert first.continuation == nil
    assert Enum.take(second.messages, length(first.messages)) == first.messages
    assert Enum.take(third.messages, length(second.messages)) == second.messages
    assert length(second.continuation["entries"]) == 1
    assert length(third.continuation["entries"]) == 2
    assert hd(third.continuation["entries"]) == hd(second.continuation["entries"])
    records = Fixture.records(fixture, session)

    settlements =
      for row <- records, row.payload.kind == "model_attempt_settled_v3", do: row.payload

    staged = for row <- records, row.payload.kind == "model_request_committed_v2", do: row.payload

    for {request, row} <- Enum.zip([second, third], tl(staged)) do
      assert request.continuation["base_request_digest"] == first.staged_request_digest
      assert request.continuation["exchange_id"] == hd(settlements)["operation_id"]

      for {entry, settlement} <- Enum.zip(request.continuation["entries"], settlements) do
        assert entry["source"] ==
                 Map.put(
                   Map.take(settlement, ~w(run_id turn_id operation_id attempt)),
                   "settlement_digest",
                   Canonical.digest(settlement)
                 )

        assert entry["capsule"] == settlement["result"]["reply"]["continuation"]
        [binding] = entry["calls"]
        assert binding["native_id"] == hd(settlement["result"]["reply"]["tool_calls"])["id"]
        refute binding["native_id"] == binding["canonical_call_id"]

        assert Enum.at(request.messages, binding["result_message_index"])["tool_call_id"] ==
                 binding["canonical_call_id"]
      end

      assert {:ok, expanded} =
               Loopex.Model.Continuation.expand(
                 request.continuation,
                 request.model,
                 request.messages
               )

      bytes = Canonical.encode(expanded)

      cost = %{
        "content_digest" => Canonical.digest_bytes(bytes),
        "byte_cost" => byte_size(bytes),
        "token_cost" => div(byte_size(bytes) + 2, 3)
      }

      receipt = row["context_receipt"]
      assert receipt["continuation_cost"] == cost

      assert receipt["provider_estimated_tokens"] ==
               receipt["totals"]["token_cost"] + cost["token_cost"]

      assert receipt["totals"]["token_cost"] ==
               Enum.sum(Enum.map(receipt["blocks"], & &1["token_cost"]))
    end

    assert {:ok, _} = SessionState.recover(session, records, Fixture.events(fixture, session))

    for changed <- [
          put_in(second.continuation, ["base_request_digest"], String.duplicate("b", 64)),
          Map.put(second.continuation, "configuration_version", 2),
          update_in(second.continuation, ["entries"], fn [entry] ->
            [put_in(entry, ["source", "settlement_digest"], String.duplicate("c", 64))]
          end)
        ] do
      assert {:ok, request} =
               Loopex.Model.request(second.model, second.messages,
                 tools: second.tools,
                 sampling: second.sampling,
                 deadline: second.deadline,
                 continuation: changed
               )

      substituted =
        Enum.map(records, fn row ->
          if row.payload.kind == "model_request_committed_v2" and
               row.payload["staged_request_digest"] == second.staged_request_digest do
            row
            |> put_in([:payload, "request", "continuation"], changed)
            |> put_in(
              [:payload, "request", "canonical_request_bytes"],
              request.canonical_request_bytes
            )
            |> put_in(
              [:payload, "request", "staged_request_digest"],
              request.staged_request_digest
            )
            |> put_in([:payload, "staged_request_digest"], request.staged_request_digest)
          else
            row
          end
        end)

      assert {:error, :invalid_model_request_transition} =
               SessionState.recover(session, substituted, Fixture.events(fixture, session))
    end

    for member <- ~w(content_digest byte_cost token_cost) do
      substituted =
        Enum.map(records, fn row ->
          if row.payload.kind == "model_request_committed_v2" and
               row.payload["staged_request_digest"] == second.staged_request_digest do
            update_in(row, [:payload, "context_receipt", "continuation_cost", member], fn value ->
              if is_binary(value), do: String.duplicate("f", 64), else: value + 1
            end)
          else
            row
          end
        end)

      assert {:error, :invalid_model_request_transition} =
               SessionState.recover(session, substituted, Fixture.events(fixture, session))
    end

    prompt(attachment, "next-prompt", "more")
    assert List.last(AgentLoopTestModel.dispatched(fixture.model)).continuation == nil
    assert length(Agent.get(fixture.executor, & &1.jobs)) == 2
  end

  test "native reuse freezes previously staged excerpt bytes and source ranges" do
    [_, vector] =
      Path.expand("../priv/vectors/artifact_read.v1.json", __DIR__)
      |> File.read!()
      |> JSON.decode!()
      |> Map.fetch!("vectors")

    digest = String.duplicate("b", 64)

    reference = %{
      digest: digest,
      size: 8_192,
      locator: digest,
      media_type: "text/plain",
      role: "tool_output",
      use_canonicalization_version: Canonical.version(),
      use_digest: digest,
      use_locator: "use:" <> digest
    }

    fixture =
      start(
        tools: [Fixture.tool_definition(), vector["definition"]],
        artifacts: %{"first" => [reference], "second" => [reference]},
        script: [
          open_turn("first"),
          open_turn("second"),
          %{
            text: "done",
            hold: self(),
            reply_overrides: %{completion: "natural", continuation: closed_capsule("done")}
          }
        ]
      )

    assert {:ok, session} =
             Runtime.create_session_with_genesis(
               fixture.runtime,
               "create",
               %{},
               genesis(fixture.definitions, continuation_configuration())
             )

    assert {:ok, attachment} = Loopex.attach(fixture.runtime, session, after_event_sequence: 0)

    assert {:accepted, "prompt"} =
             Loopex.command(
               attachment,
               %{type: :prompt, command_id: "prompt", content: "work"}
             )

    assert_receive {:holding, provider}, 5_000
    [_, second, third] = AgentLoopTestModel.dispatched(fixture.model)
    assert Enum.take(third.messages, length(second.messages)) == second.messages

    assert {:ok, state} =
             SessionState.recover(
               session,
               Fixture.records(fixture, session),
               Fixture.events(fixture, session)
             )

    assert {:ok, entries, projection} =
             SessionState.projected_lineage(state, state.active_run_id, 0)

    [old, appended] = for {_, %{"role" => "tool"} = message} <- entries, do: message
    assert old == Enum.find(second.messages, &(&1["role"] == "tool"))
    assert {:ok, notice} = LoopexProtocol.Frame.decode(appended["content"], 2_048)
    assert notice["excerpt_byte_count"] == 0
    [frozen, new] = projection["ranges"]
    assert frozen["byte_count"] > 0
    assert new["byte_count"] == 0
    send(provider, :release)
    assert List.last(finish(attachment))["outcome"] == "completed"

    assert {:ok, _} =
             SessionState.recover(
               session,
               Fixture.records(fixture, session),
               Fixture.events(fixture, session)
             )
  end

  test "native identity collision refuses a later reply before another tool intent" do
    fixture = start(script: [open_turn("same"), open_turn("same")])

    assert {:ok, session} =
             Runtime.create_session_with_genesis(
               fixture.runtime,
               "create",
               %{},
               genesis(fixture.definitions, continuation_configuration())
             )

    assert {:ok, attachment} = Loopex.attach(fixture.runtime, session, after_event_sequence: 0)

    assert {:accepted, "prompt"} =
             Loopex.command(
               attachment,
               %{type: :prompt, command_id: "prompt", content: "work"}
             )

    events = finish(attachment)
    assert Enum.find(events, &(&1.kind == "run.finished"))["outcome"] == "failed"
    assert length(Agent.get(fixture.executor, & &1.jobs)) == 1

    settlements =
      for row <- Fixture.records(fixture, session),
          row.payload.kind == "model_attempt_settled_v3",
          do: row.payload

    assert List.last(settlements)["result"] == %{
             "kind" => "error",
             "category" => "unreadable_model_answer",
             "accounting_evidence" => %{"kind" => "none"}
           }

    assert {:ok, _} = SessionState.recover(session, Fixture.records(fixture, session), events)
  end

  test "owner recovery reuses frozen project content without the original host manifest" do
    content = "Retain this project guidance during the exchange."

    project = %{
      workspace: %{workspace_ref: "workspace-ref", repository_origin: nil, revision: nil},
      entries: [
        %{
          label: "AGENTS.md",
          content: content,
          byte_size: byte_size(content),
          content_digest: Canonical.digest_bytes(content),
          contained: true
        }
      ]
    }

    {:ok, digest, _} = Loopex.ProjectResource.digest(project)

    decision = %{
      manifest_digest: digest,
      workspace_ref: "workspace-ref",
      trust_scope: "project_resource",
      decision_source: "host_supplied",
      issued_at: "2026-09-10T00:00:00Z",
      expires_at: nil,
      revocation_state: "active"
    }

    fixture =
      start(script: [open_turn("write")], project_manifest: project, project_decision: decision)

    assert {:ok, session} =
             Runtime.create_session_with_genesis(
               fixture.runtime,
               "create",
               %{},
               genesis(fixture.definitions, continuation_configuration())
             )

    assert {:ok, attachment} = Loopex.attach(fixture.runtime, session, after_event_sequence: 0)
    hold_record_commit(fixture, "executor_receipt_committed", :after)

    assert {:accepted, "prompt"} =
             Loopex.command(
               attachment,
               %{type: :prompt, command_id: "prompt", content: "work"}
             )

    {waiter, _} = await_record_commit(fixture, session, "executor_receipt_committed", :after)
    [first] = AgentLoopTestModel.dispatched(fixture.model)
    assert Enum.any?(first.messages, &String.contains?(&1["content"], content))
    {:ok, children} = Runtime.Supervisor.children(fixture.runtime.supervisor)
    [{_, owner, _, _}] = DynamicSupervisor.which_children(children.sessions)
    monitor = Process.monitor(owner)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^owner, :killed}, 5_000
    assert :ok = Loopex.stop(fixture.runtime)

    restarted =
      start(
        store: fixture.store,
        script: [
          %{
            text: "done",
            reply_overrides: %{completion: "natural", continuation: closed_capsule("done")}
          }
        ]
      )

    assert {:ok, ^session} =
             Loopex.resume_session(restarted.runtime, session, command_id: "successor")

    Loopex.M1RuntimeTestStore.release(waiter)
    assert {:ok, successor} = Loopex.attach(restarted.runtime, session, after_event_sequence: 0)
    assert Enum.find(finish(successor), &(&1.kind == "run.finished"))["outcome"] == "completed"
    [second] = AgentLoopTestModel.dispatched(restarted.model)
    assert Enum.take(second.messages, length(first.messages)) == first.messages
    assert second.continuation["base_request_digest"] == first.staged_request_digest
    assert Agent.get(restarted.executor, & &1.jobs) == []

    rows =
      for row <- Fixture.records(restarted, session),
          row.payload.kind == "model_request_committed_v2",
          do: row.payload

    assert Enum.at(rows, 1)["context_receipt"]["project_resource"] ==
             hd(rows)["context_receipt"]["project_resource"]

    assert {:ok, _} =
             SessionState.recover(
               session,
               Fixture.records(restarted, session),
               Fixture.events(restarted, session)
             )
  end

  test "aggregate continuation overflow records an unavailable projection before another attempt" do
    turns =
      for id <- ["first", "second"] do
        update_in(open_turn(id), [:reply_overrides, :continuation, "content"], fn nodes ->
          [
            %{"kind" => "literal", "value" => %{"private" => String.duplicate("x", 9_000)}}
            | nodes
          ]
        end)
      end

    fixture = start(script: turns)

    assert {:ok, session} =
             Runtime.create_session_with_genesis(
               fixture.runtime,
               "create",
               %{},
               genesis(fixture.definitions, continuation_configuration())
             )

    assert {:ok, attachment} = Loopex.attach(fixture.runtime, session, after_event_sequence: 0)

    assert {:accepted, "prompt"} =
             Loopex.command(
               attachment,
               %{type: :prompt, command_id: "prompt", content: "work"}
             )

    events = finish(attachment)
    assert Enum.find(events, &(&1.kind == "run.finished"))["outcome"] == "failed"
    assert length(AgentLoopTestModel.dispatched(fixture.model)) == 2

    [refusal] =
      for row <- Fixture.records(fixture, session),
          row.payload.kind == "context_admission_refused_v2",
          do: row.payload

    assert refusal["projection_state"] == "unavailable"
    assert refusal["failure"]["cause"] == "context_projection_invalid"
    assert refusal["provider_estimated_tokens"] == nil
    assert {:ok, _} = SessionState.recover(session, Fixture.records(fixture, session), events)
  end

  defp open_turn(id) do
    capsule =
      closed_capsule("working")
      |> Map.put("status", "open")
      |> Map.update!(
        "content",
        &(&1 ++
            [
              %{
                "kind" => "tool_use_ref",
                "call_index" => 0,
                "native_id" => id,
                "template" => %{"type" => "tool_use", "id" => id, "name" => "write"},
                "field" => "input"
              }
            ])
      )

    %{
      text: "working",
      calls: [%{id: id, name: "write", arguments: %{"path" => id}}],
      reply_overrides: %{completion: "natural", continuation: capsule}
    }
  end

  defp continuation_configuration do
    configuration()
    |> put_in(["model_capabilities", "reasoning_levels"], ["default"])
    |> put_in(["provider_mapping", "mapping_revision"], "fixture.continuation.v1")
    |> put_in(["provider_mapping", "continuation_required"], true)
  end

  defp closed_capsule(text),
    do: %{
      "format" => "loopex.anthropic.content_refs.v1",
      "provider" => "anthropic",
      "model" => "scripted:v1",
      "status" => "closed",
      "content" => [
        %{
          "kind" => "text_ref",
          "byte_length" => byte_size(text),
          "template" => %{"type" => "text"},
          "field" => "text"
        }
      ]
    }

  test "orderly runtime shutdown joins owner groups without shutdown errors" do
    log =
      ExUnit.CaptureLog.capture_log(fn ->
        for index <- 1..32 do
          fixture = start(script: [%{text: "done", calls: []}])

          assert {:ok, session} =
                   Runtime.create_session_with_genesis(
                     fixture.runtime,
                     "shutdown-#{index}",
                     %{},
                     genesis(fixture.definitions)
                   )

          assert {:ok, attachment} =
                   Loopex.attach(fixture.runtime, session, after_event_sequence: 0)

          prompt(attachment, "prompt", "go")

          assert {:ok, children} = Runtime.children(fixture.runtime)
          [{_, group, :worker, _}] = Supervisor.which_children(children.owner_groups)
          assert {:ok, workers} = Loopex.Runtime.OwnerGroup.workers(group)
          assert :ok = Loopex.stop(fixture.runtime)
          refute Process.alive?(group)
          refute Process.alive?(workers)
        end
      end)

    refute log =~ "shutdown_error", log
  end

  test "live configuration commits one version and restart preserves new and earlier run captures" do
    fixture = start(script: [%{text: "first", calls: []}, %{text: "second", calls: []}])

    assert {:ok, session} =
             Runtime.create_session_with_genesis(
               fixture.runtime,
               "create",
               %{},
               genesis(fixture.definitions)
             )

    assert {:ok, attachment} = Loopex.attach(fixture.runtime, session, after_event_sequence: 0)
    prompt(attachment, "first", "first prompt")

    {:ok, instructions} =
      Instructions.capture(%{
        "version" => "host.v2",
        "base" => "host-switch-canary",
        "environment" => "",
        "appendix" => ""
      })

    initial = configuration()

    changes = %{
      "model" => "scripted:v2",
      "max_tokens" => 512,
      "instructions" => instructions,
      "context_token_budget" => 6_000
    }

    {:ok, candidate} =
      SessionConfiguration.update(
        initial,
        changes,
        Map.put(initial["model_capabilities"], "model", "scripted:v2"),
        initial["provider_mapping"],
        fixture.definitions
      )

    command = %{type: :configure, command_id: "configure", changes: changes}

    assert {:accepted, "configure"} =
             Runtime.command_with_configuration(attachment, command, candidate)

    before_duplicate = Fixture.records(fixture, session)
    assert {:accepted, "configure"} = Runtime.command_with_configuration(attachment, command, %{})
    assert Fixture.records(fixture, session) == before_duplicate

    assert {:error, :idempotency_conflict} =
             Runtime.command_with_configuration(
               attachment,
               %{command | changes: %{"max_tokens" => 256}},
               candidate
             )

    assert length(AgentLoopTestModel.dispatched(fixture.model)) == 1
    prompt(attachment, "second", "second prompt")
    [first, second] = AgentLoopTestModel.dispatched(fixture.model)
    assert first.model == "scripted:v1"
    assert second.model == "scripted:v2"
    {:ok, rendered} = Instructions.render(instructions)
    assert hd(second.messages)["content"] == rendered
    assert second.sampling == SessionConfiguration.sampling(candidate)

    {:ok, recovered} =
      SessionState.recover(
        session,
        Fixture.records(fixture, session),
        Fixture.events(fixture, session)
      )

    [first_run, second_run] = recovered.run_order
    assert {:ok, selection_units} = SessionState.compaction_units(recovered, second_run)
    assert Enum.map(selection_units, & &1.run_id) == [first_run, second_run]
    assert Enum.all?(selection_units, & &1.complete?)
    refute Enum.any?(selection_units, & &1.protected?)
    assert recovered.configuration == candidate
    assert SessionState.run_configuration(recovered, first_run) == initial
    assert SessionState.run_configuration(recovered, second_run) == candidate
    configured = Enum.filter(Fixture.events(fixture, session), &(&1.kind == "session.configured"))
    assert length(configured) == 1
    assert hd(configured)["configuration"] == SessionConfiguration.public_view(candidate)
    refute :erlang.term_to_binary(configured) =~ "host-switch-canary"
    assert :ok = Loopex.stop(fixture.runtime)

    restarted =
      start(store: fixture.store, tools: [], max_tokens: 3, script: [%{text: "third", calls: []}])

    assert {:ok, ^session} =
             Loopex.resume_session(restarted.runtime, session, command_id: "resume")

    assert {:ok, restarted_state} =
             SessionState.recover(
               session,
               Fixture.records(restarted, session),
               Fixture.events(restarted, session)
             )

    assert SessionState.compaction_units(restarted_state, second_run) == {:ok, selection_units}

    assert {:ok, next_attachment} =
             Loopex.attach(restarted.runtime, session,
               after_event_sequence: List.last(Fixture.events(restarted, session)).event_sequence
             )

    assert {:accepted, "configure"} =
             Runtime.command_with_configuration(next_attachment, command, nil)

    prompt(next_attachment, "third", "third prompt")
    [third] = AgentLoopTestModel.dispatched(restarted.model)
    assert third.model == "scripted:v2"
    assert hd(third.messages)["content"] == rendered
    assert third.sampling == SessionConfiguration.sampling(candidate)
    assert third.tools == fixture.definitions
  end

  test "live configure reports removable history capacity without model work or projection changes" do
    fixture = start(script: [%{text: String.duplicate("a", 7_000), calls: []}])
    initial = configuration()

    assert {:ok, session} =
             Runtime.create_session_with_genesis(
               fixture.runtime,
               "create",
               %{},
               genesis(fixture.definitions)
             )

    assert {:ok, attachment} = Loopex.attach(fixture.runtime, session, after_event_sequence: 0)
    prompt(attachment, "prompt", String.duplicate("p", 7_000))
    changes = %{"context_token_budget" => 600, "system_class_tokens" => 500}

    {:ok, candidate} =
      SessionConfiguration.update(
        initial,
        changes,
        initial["model_capabilities"],
        initial["provider_mapping"],
        fixture.definitions
      )

    command = %{type: :configure, command_id: "too-small", changes: changes}

    assert {:error, :compaction_required} =
             Runtime.command_with_configuration(attachment, command, candidate)

    assert {:error, :compaction_required} =
             Runtime.command_with_configuration(attachment, command, nil)

    records = Fixture.records(fixture, session)
    assert Enum.count(records, &(&1.payload.kind == "session_configuration_admitted_v1")) == 1
    {:ok, recovered} = SessionState.recover(session, records, Fixture.events(fixture, session))
    assert recovered.configuration == initial
    refute Enum.any?(Fixture.events(fixture, session), &(&1.kind == "session.configured"))
    assert length(AgentLoopTestModel.dispatched(fixture.model)) == 1
  end

  test "live configure refuses unwritable minimum request even when its configuration record fits" do
    fixture = start(script: [])
    initial = configuration()

    assert {:ok, session} =
             Runtime.create_session_with_genesis(
               fixture.runtime,
               "create",
               %{},
               genesis(fixture.definitions)
             )

    assert {:ok, attachment} = Loopex.attach(fixture.runtime, session, after_event_sequence: 0)

    {:ok, instructions} =
      Instructions.capture(%{
        "version" => "large",
        "base" => String.duplicate("b", 32_768),
        "environment" => "",
        "appendix" => ""
      })

    changes = %{
      "instructions" => instructions,
      "system_class_tokens" => 12_000,
      "context_token_budget" => 20_000
    }

    {:ok, candidate} =
      SessionConfiguration.update(
        initial,
        changes,
        initial["model_capabilities"],
        initial["provider_mapping"],
        fixture.definitions
      )

    assert {:ok, _} = Loopex.Store.admit_bounded(candidate)
    command = %{type: :configure, command_id: "unwritable", changes: changes}

    assert {:error, :invalid_session_configuration} =
             Runtime.command_with_configuration(attachment, command, candidate)

    assert {:error, :invalid_session_configuration} =
             Runtime.command_with_configuration(attachment, command, nil)

    {:ok, recovered} =
      SessionState.recover(
        session,
        Fixture.records(fixture, session),
        Fixture.events(fixture, session)
      )

    assert recovered.configuration == initial
    assert AgentLoopTestModel.dispatched(fixture.model) == []
    assert Agent.get(fixture.executor, & &1.jobs) == []
  end

  test "live configure refusal while a provider is active remains stable after it settles" do
    fixture = start(script: [%{text: "done", calls: [], hold: self()}])
    initial = configuration()

    assert {:ok, session} =
             Runtime.create_session_with_genesis(
               fixture.runtime,
               "create",
               %{},
               genesis(fixture.definitions)
             )

    assert {:ok, attachment} = Loopex.attach(fixture.runtime, session, after_event_sequence: 0)

    assert {:accepted, "prompt"} =
             Loopex.command(attachment, %{type: :prompt, command_id: "prompt", content: "go"})

    assert_receive {:holding, model}, 5_000
    changes = %{"max_tokens" => 512}

    {:ok, candidate} =
      SessionConfiguration.update(
        initial,
        changes,
        initial["model_capabilities"],
        initial["provider_mapping"],
        fixture.definitions
      )

    command = %{type: :configure, command_id: "busy", changes: changes}

    assert {:error, :configuration_not_settled} =
             Runtime.command_with_configuration(attachment, command, candidate)

    send(model, :release)
    finish(attachment)

    assert {:error, :configuration_not_settled} =
             Runtime.command_with_configuration(attachment, command, candidate)

    assert {:accepted, "settled"} =
             Runtime.command_with_configuration(
               attachment,
               %{command | command_id: "settled"},
               candidate
             )

    assert {:error, :invalid_command} =
             Runtime.command_with_configuration(
               attachment,
               %{type: :prompt, command_id: "invalid", content: "never dispatch"},
               :unprepared
             )

    assert length(AgentLoopTestModel.dispatched(fixture.model)) == 1
  end

  test "configuration commit unknown retains exact proposal before acknowledgement and publication" do
    fixture = start(script: [%{text: "done", calls: []}])
    initial = configuration()

    assert {:ok, session} =
             Runtime.create_session_with_genesis(
               fixture.runtime,
               "create",
               %{},
               genesis(fixture.definitions)
             )

    assert {:ok, attachment} = Loopex.attach(fixture.runtime, session, after_event_sequence: 0)
    changes = %{"max_tokens" => 512}

    {:ok, candidate} =
      SessionConfiguration.update(
        initial,
        changes,
        initial["model_capabilities"],
        initial["provider_mapping"],
        fixture.definitions
      )

    command = %{type: :configure, command_id: "configure", changes: changes}
    kind = "session_configuration_admitted_v1"
    hold_record_commit(fixture, kind, :before)
    parent = self()

    caller =
      spawn(fn ->
        send(
          parent,
          {:configure_result, self(),
           Runtime.command_with_configuration(attachment, command, candidate)}
        )
      end)

    {waiter, proposed} = await_record_commit(fixture, session, kind, :before)
    refute_receive {:configure_result, ^caller, _}, 20
    refute Enum.any?(Fixture.events(fixture, session), &(&1.kind == "session.configured"))
    assert AgentLoopTestModel.dispatched(fixture.model) == []

    :ok =
      Loopex.M1RuntimeTestStore.inject(
        fixture.store,
        {:session_journal_commit, :after_linearization_before_result}
      )

    Loopex.M1RuntimeTestStore.release(waiter)
    assert_receive {:configure_result, ^caller, {:accepted, "configure"}}, 5_000

    assert Enum.filter(Fixture.records(fixture, session), &(&1.payload.kind == kind))
           |> Enum.map(& &1.payload) == [proposed]

    assert Enum.count(Fixture.events(fixture, session), &(&1.kind == "session.configured")) == 1
    assert {:accepted, "configure"} = Runtime.command_with_configuration(attachment, command, nil)
    prompt(attachment, "next", "go")
    [request] = AgentLoopTestModel.dispatched(fixture.model)
    assert request.sampling == SessionConfiguration.sampling(candidate)

    assert {:ok, recovered} =
             SessionState.recover(
               session,
               Fixture.records(fixture, session),
               Fixture.events(fixture, session)
             )

    assert recovered.configuration == candidate
  end

  test "owner crashes at configuration commit boundaries retain one version and original disposition" do
    for phase <- [:before, :after] do
      fixture = start(script: [%{text: "done", calls: []}])
      initial = configuration()

      assert {:ok, session} =
               Runtime.create_session_with_genesis(
                 fixture.runtime,
                 "create",
                 %{},
                 genesis(fixture.definitions)
               )

      assert {:ok, attachment} = Loopex.attach(fixture.runtime, session, after_event_sequence: 0)
      changes = %{"max_tokens" => 512}

      {:ok, candidate} =
        SessionConfiguration.update(
          initial,
          changes,
          initial["model_capabilities"],
          initial["provider_mapping"],
          fixture.definitions
        )

      command = %{type: :configure, command_id: "configure", changes: changes}
      kind = "session_configuration_admitted_v1"
      hold_record_commit(fixture, kind, phase)
      parent = self()

      caller =
        spawn(fn ->
          result =
            try do
              Runtime.command_with_configuration(attachment, command, candidate)
            catch
              :exit, reason -> {:caller_exit, reason}
            end

          send(parent, {:configure_crash_result, self(), result})
        end)

      {waiter, proposed} = await_record_commit(fixture, session, kind, phase)

      assert Enum.count(Fixture.records(fixture, session), &(&1.payload.kind == kind)) ==
               if(phase == :after, do: 1, else: 0)

      assert AgentLoopTestModel.dispatched(fixture.model) == []
      {:ok, children} = Runtime.Supervisor.children(fixture.runtime.supervisor)
      [{_, owner, _, _}] = DynamicSupervisor.which_children(children.sessions)
      monitor = Process.monitor(owner)
      Process.exit(owner, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^owner, :killed}, 5_000

      assert {:ok, ^session} =
               Loopex.resume_session(fixture.runtime, session, command_id: "successor")

      Loopex.M1RuntimeTestStore.release(waiter)
      assert_receive {:configure_crash_result, ^caller, result}, 5_000
      assert result == {:error, :session_unavailable} or match?({:caller_exit, _}, result)
      assert {:ok, successor} = Loopex.attach(fixture.runtime, session, after_event_sequence: 0)

      admitted_id = if phase == :before, do: "successor-configure", else: "configure"

      if phase == :before do
        assert {:terminal, {:not_committed, :stale_owner_epoch}} =
                 await_session_transaction(fixture.store, session, "configure")

        assert {:error, :tx_id_conflict} =
                 Runtime.command_with_configuration(successor, command, candidate)

        assert {:accepted, ^admitted_id} =
                 Runtime.command_with_configuration(
                   successor,
                   %{command | command_id: admitted_id},
                   candidate
                 )
      else
        assert {:accepted, ^admitted_id} =
                 Runtime.command_with_configuration(successor, command, nil)
      end

      records = Fixture.records(fixture, session)
      admissions = Enum.filter(records, &(&1.payload.kind == kind))
      assert length(admissions) == 1
      if phase == :after, do: assert(hd(admissions).payload == proposed)
      assert Enum.count(Fixture.events(fixture, session), &(&1.kind == "session.configured")) == 1

      assert {:ok, recovered} =
               SessionState.recover(session, records, Fixture.events(fixture, session))

      assert recovered.configuration == candidate
      assert candidate["configuration_version"] == initial["configuration_version"] + 1
      prompt(successor, "next", "go")
      [request] = AgentLoopTestModel.dispatched(fixture.model)
      assert request.sampling == SessionConfiguration.sampling(candidate)
      assert Agent.get(fixture.executor, & &1.jobs) == []
    end
  end

  test "the admitted question generation never dispatches an executor effect" do
    for {policy, reason} <- [
          {Loopex.ConfiguredSessionDeferringPolicy, "policy_unavailable"}
        ] do
      fixture =
        start(
          tools: [ToolDefinition.question_definition()],
          policy: policy,
          policy_identity: %{"id" => "loopex.test.question-policy", "revision" => "1"},
          script: [
            %{
              text: "I have a question",
              calls: [%{id: "ask-1", name: "ask", arguments: %{"question" => "Which encoding?"}}]
            },
            %{text: "done", calls: []}
          ]
        )

      assert {:ok, session} =
               Runtime.create_session_with_genesis(
                 fixture.runtime,
                 "create-question",
                 %{},
                 genesis(fixture.definitions)
               )

      assert {:ok, attachment} = Loopex.attach(fixture.runtime, session, after_event_sequence: 0)

      assert {:accepted, "prompt"} =
               Loopex.command(attachment, %{
                 type: :prompt,
                 command_id: "prompt",
                 content: "implement"
               })

      events = finish(attachment)
      terminal = Enum.find(events, &(&1.kind == "tool.finished"))
      assert terminal["outcome"] == "denied"
      assert terminal["reason"] == reason
      assert Enum.find(events, &(&1.kind == "run.finished"))["outcome"] == "completed"
      refute Enum.any?(events, &(&1.kind == "interaction.requested"))
      assert Agent.get(fixture.executor, & &1.jobs) == []

      refute Enum.any?(
               Fixture.records(fixture, session),
               &String.starts_with?(&1.payload.kind, "effect_")
             )
    end
  end

  test "model questions settle exact text, choice and decline in one transaction" do
    Process.register(self(), :m7_question_policy_observer)
    text = String.duplicate("é", 4_096)

    for {arguments, answer, content, disposition} <- [
          {%{"question" => "Explain"}, %{"text" => text}, text, "answered"},
          {%{"question" => "Choose", "choices" => ["empty", "literal_null"]},
           %{"choice_id" => "choice-2"}, "literal_null", "answered"},
          {%{"question" => "Explain"}, %{"disposition" => "declined"}, "question_declined",
           "declined"}
        ] do
      fixture =
        start(
          tools: [ToolDefinition.question_definition()],
          policy: Loopex.ConfiguredQuestionCountingPolicy,
          script: [
            %{text: "question", calls: [%{id: "ask-1", name: "ask", arguments: arguments}]},
            %{text: "done", calls: []}
          ]
        )

      assert {:ok, session} =
               Runtime.create_session_with_genesis(
                 fixture.runtime,
                 "create",
                 %{},
                 genesis(fixture.definitions)
               )

      assert {:ok, attachment} = Loopex.attach(fixture.runtime, session, after_event_sequence: 0)

      assert {:accepted, "prompt"} =
               Loopex.command(attachment, %{
                 type: :prompt,
                 command_id: "prompt",
                 content: "implement"
               })

      question = await_question(attachment)
      assert_received {:question_policy_call, _}
      assert question["producer"] == "model_tool"

      assert question["interaction_kind"] ==
               if(Map.has_key?(arguments, "choices"), do: "choice", else: "text")

      assert length(AgentLoopTestModel.dispatched(fixture.model)) == 1

      assert {:ok, pending} =
               SessionState.recover(
                 session,
                 Fixture.records(fixture, session),
                 Fixture.events(fixture, session)
               )

      assert pending.open_interaction == question["interaction_id"]

      assert SessionState.propose_interaction_resolution(
               pending,
               pending.open_interaction,
               "expired",
               "legacy-bypass"
             ) == {:error, :invalid_interaction_transition}

      pending_interaction = pending.interactions[question["interaction_id"]]

      if pending_interaction.request.kind == :choice do
        assert SessionState.propose_interaction_answer(
                 pending,
                 pending.open_interaction,
                 "legacy-bypass",
                 "choice-1"
               ) == {:error, :invalid_interaction_transition}
      end

      assert pending_interaction.expires_at ==
               min(
                 pending_interaction.created_at + 600_000,
                 pending.deadlines[pending_interaction.run_id]
               )

      assert SessionState.propose_model_question_expiry(
               pending,
               question["interaction_id"],
               pending_interaction.expires_at - 1
             ) == {:error, :invalid_model_question_transition}

      pending_records = Fixture.records(fixture, session)

      for {field, changed} <- [
            {"argument_digest", String.duplicate("0", 64)},
            {"interaction_id", "forged"},
            {"tool_call_id", "forged-call"},
            {"turn", 999},
            {"expires_at", pending_interaction.expires_at + 1},
            {"interaction_request", %{}},
            {"producer", "policy_defer"}
          ] do
        altered =
          Enum.map(pending_records, fn row ->
            if row.payload.kind == "model_question_requested_v1",
              do: %{row | payload: Map.put(row.payload, field, changed)},
              else: row
          end)

        assert SessionState.recover(session, altered, Fixture.events(fixture, session)) ==
                 {:error, :invalid_model_question_transition}
      end

      command = %{
        type: :interaction_answer,
        command_id: "answer",
        interaction_id: question["interaction_id"],
        answer: answer
      }

      assert {:ok, late} =
               SessionState.propose(pending, %{command | command_id: "late"}, %{
                 admitted_at: pending_interaction.expires_at
               })

      assert late.reply == {:error, :interaction_resolved}
      assert late.next.open_interaction == pending.open_interaction

      assert {:ok, expired} =
               SessionState.propose_model_question_expiry(
                 pending,
                 pending.open_interaction,
                 pending_interaction.expires_at
               )

      assert length(expired.records) == 1
      assert is_nil(expired.next.open_interaction)
      assert expired.next.interactions[pending.open_interaction].status == "expired"

      assert {:error, :invalid_command} =
               Loopex.command(
                 attachment,
                 %{
                   command
                   | command_id: "oversized",
                     answer: %{"text" => String.duplicate("x", 8_193)}
                 }
               )

      wrong_answer =
        if Map.has_key?(arguments, "choices"),
          do: %{"text" => "wrong kind"},
          else: %{"choice_id" => "choice-1"}

      assert {:error, :invalid_interaction_answer} =
               Loopex.command(
                 attachment,
                 %{command | command_id: "wrong-kind", answer: wrong_answer}
               )

      assert {:accepted, "answer"} = Loopex.command(attachment, command)

      assert {:error, :idempotency_conflict} =
               Loopex.command(
                 attachment,
                 %{command | interaction_id: "different-question"}
               )

      events = finish(attachment)
      assert {:accepted, "answer"} = Loopex.command(attachment, command)

      assert {:error, :interaction_resolved} =
               Loopex.command(
                 attachment,
                 %{command | command_id: "second-answer"}
               )

      terminal = Enum.find(events, &(&1.kind in ["interaction.answered", "interaction.declined"]))
      assert terminal["disposition"] == disposition
      assert Agent.get(fixture.executor, & &1.jobs) == []
      refute_received {:question_policy_call, _}
      [_first, second] = AgentLoopTestModel.dispatched(fixture.model)
      result = Enum.find(second.messages, &(&1["role"] == "tool"))

      assert result["content"] ==
               if(disposition == "answered",
                 do: content,
                 else: Loopex.Conversation.result_content(:denied, content)
               )

      records = Fixture.records(fixture, session)
      response = Enum.find(records, &(&1.payload.kind == "model_question_response_admitted_v1"))
      assert Enum.count(records, &(&1.payload.kind == "model_question_response_admitted_v1")) == 1
      assert response.payload["answer"] == answer
      assert terminal["command_id"] == response.payload["command_id"]
      assert terminal["command_digest"] == response.payload["command_digest"]
      assert terminal["settlement_sequence"] == response.journal_version

      assert {:ok, recovered} =
               SessionState.recover(session, records, Fixture.events(fixture, session))

      assert is_nil(recovered.open_interaction)
      assert recovered.interactions[question["interaction_id"]].status == disposition

      refute Enum.any?(
               records,
               &(&1.payload.kind in [
                   "effect_intent_committed",
                   "executor_receipt_committed",
                   "interaction_resolved_v1"
                 ])
             )
    end
  end

  test "commit unknown re-presents exact question and response bytes before publication" do
    fixture =
      start(
        tools: [ToolDefinition.question_definition()],
        script: [
          %{
            text: "question",
            calls: [%{id: "ask-1", name: "ask", arguments: %{"question" => "Explain"}}]
          },
          %{text: "done", calls: []}
        ]
      )

    assert {:ok, session} =
             Runtime.create_session_with_genesis(
               fixture.runtime,
               "create",
               %{},
               genesis(fixture.definitions)
             )

    assert {:ok, attachment} = Loopex.attach(fixture.runtime, session, after_event_sequence: 0)
    hold_record_commit(fixture, "model_question_requested_v1", :before)

    assert {:accepted, "prompt"} =
             Loopex.command(attachment, %{type: :prompt, command_id: "prompt", content: "go"})

    {pending_waiter, pending_proposal} =
      await_record_commit(fixture, session, "model_question_requested_v1", :before)

    refute Enum.any?(Fixture.events(fixture, session), &(&1.kind == "interaction.requested"))
    assert length(AgentLoopTestModel.dispatched(fixture.model)) == 1

    :ok =
      Loopex.M1RuntimeTestStore.inject(
        fixture.store,
        {:session_journal_commit, :after_linearization_before_result}
      )

    Loopex.M1RuntimeTestStore.release(pending_waiter)
    question = await_question(attachment)
    assert question["interaction_id"] == pending_proposal["interaction_id"]
    assert question["expires_at"] == pending_proposal["expires_at"]
    hold_record_commit(fixture, "model_question_response_admitted_v1", :before)
    parent = self()

    caller =
      spawn(fn ->
        send(
          parent,
          {:unknown_answer_result, self(),
           Loopex.command(attachment, question_answer(question["interaction_id"]))}
        )
      end)

    {answer_waiter, answer_proposal} =
      await_record_commit(fixture, session, "model_question_response_admitted_v1", :before)

    refute_receive {:unknown_answer_result, ^caller, _}, 20
    refute Enum.any?(Fixture.events(fixture, session), &(&1.kind == "interaction.answered"))
    assert length(AgentLoopTestModel.dispatched(fixture.model)) == 1

    :ok =
      Loopex.M1RuntimeTestStore.inject(
        fixture.store,
        {:session_journal_commit, :after_linearization_before_result}
      )

    Loopex.M1RuntimeTestStore.release(answer_waiter)
    assert_receive {:unknown_answer_result, ^caller, {:accepted, "answer"}}, 5_000
    events = finish(attachment)
    assert Enum.count(events, &(&1.kind == "interaction.answered")) == 1
    records = Fixture.records(fixture, session)

    assert Enum.filter(records, &(&1.payload.kind == "model_question_requested_v1"))
           |> Enum.map(& &1.payload) == [pending_proposal]

    assert Enum.filter(records, &(&1.payload.kind == "model_question_response_admitted_v1"))
           |> Enum.map(& &1.payload) == [answer_proposal]

    assert Enum.count(Fixture.events(fixture, session), &(&1.kind == "interaction.requested")) ==
             1

    assert length(AgentLoopTestModel.dispatched(fixture.model)) == 2
    assert Agent.get(fixture.executor, & &1.jobs) == []

    assert {:accepted, "answer"} =
             Loopex.command(attachment, question_answer(question["interaction_id"]))

    assert {:ok, recovered} =
             SessionState.recover(session, records, Fixture.events(fixture, session))

    assert is_nil(recovered.open_interaction)
  end

  test "owner crashes before and after question and response commits retain one settlement" do
    for target <- [:pending, :response], phase <- [:before, :after] do
      fixture =
        start(
          tools: [ToolDefinition.question_definition()],
          script: [
            %{
              text: "question",
              calls: [%{id: "ask-1", name: "ask", arguments: %{"question" => "Explain"}}]
            },
            %{text: "done", calls: []}
          ]
        )

      assert {:ok, session} =
               Runtime.create_session_with_genesis(
                 fixture.runtime,
                 "create",
                 %{},
                 genesis(fixture.definitions)
               )

      assert {:ok, attachment} = Loopex.attach(fixture.runtime, session, after_event_sequence: 0)

      kind =
        if target == :pending,
          do: "model_question_requested_v1",
          else: "model_question_response_admitted_v1"

      if target == :pending, do: hold_record_commit(fixture, kind, phase)

      assert {:accepted, "prompt"} =
               Loopex.command(attachment, %{type: :prompt, command_id: "prompt", content: "go"})

      question = if target == :response, do: await_question(attachment)
      parent = self()

      caller =
        if target == :response do
          hold_record_commit(fixture, kind, phase)

          spawn(fn ->
            result =
              try do
                Loopex.command(attachment, question_answer(question["interaction_id"]))
              catch
                :exit, reason -> {:caller_exit, reason}
              end

            send(parent, {:question_caller_finished, self(), result})
          end)
        end

      {waiter, proposed} = await_record_commit(fixture, session, kind, phase)
      id = proposed["interaction_id"]
      matching = Enum.filter(Fixture.records(fixture, session), &(&1.payload.kind == kind))
      assert length(matching) == if(phase == :after, do: 1, else: 0)
      assert length(AgentLoopTestModel.dispatched(fixture.model)) == 1
      assert Agent.get(fixture.executor, & &1.jobs) == []

      {:ok, children} = Loopex.Runtime.Supervisor.children(fixture.runtime.supervisor)
      [{_, owner, _, _}] = DynamicSupervisor.which_children(children.sessions)
      monitor = Process.monitor(owner)
      Process.exit(owner, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^owner, :killed}, 5_000

      assert {:ok, ^session} =
               Loopex.resume_session(fixture.runtime, session, command_id: "successor")

      Loopex.M1RuntimeTestStore.release(waiter)

      if caller do
        assert_receive {:question_caller_finished, ^caller, result}, 5_000
        assert result == {:error, :session_unavailable} or match?({:caller_exit, _}, result)
      end

      assert {:ok, successor} = Loopex.attach(fixture.runtime, session, after_event_sequence: 0)
      retained_question = await_question(successor)
      assert retained_question["interaction_id"] == id

      if target == :pending and phase == :after do
        assert retained_question["expires_at"] == proposed["expires_at"]
        assert retained_question["choices"] == proposed["interaction_request"]["choices"]
      end

      answer_command_id =
        if target == :response and phase == :before, do: "successor-answer", else: "answer"

      if target == :response and phase == :before do
        # Concept: a proved non-commit is terminal for its transaction identity.
        # Technical depth: ADR 0006 requires a fresh logical transaction after
        # succession; the old ID cannot acquire new owner or timestamp bindings.
        assert {:terminal, {:not_committed, :stale_owner_epoch}} =
                 await_session_transaction(fixture.store, session, "answer")

        assert {:error, :tx_id_conflict} = Loopex.command(successor, question_answer(id))
      end

      assert {:accepted, ^answer_command_id} =
               Loopex.command(successor, question_answer(id, answer_command_id))

      events = finish(successor)
      assert Enum.count(events, &(&1.kind == "interaction.answered")) == 1
      assert Enum.count(events, &(&1.kind == "tool.finished")) == 1
      assert length(AgentLoopTestModel.dispatched(fixture.model)) == 2
      assert Agent.get(fixture.executor, & &1.jobs) == []

      records = Fixture.records(fixture, session)
      pending = Enum.filter(records, &(&1.payload.kind == "model_question_requested_v1"))

      responses =
        Enum.filter(records, &(&1.payload.kind == "model_question_response_admitted_v1"))

      assert length(pending) == 1
      assert length(responses) == 1

      if phase == :after,
        do: assert(hd(if(target == :pending, do: pending, else: responses)).payload == proposed)

      assert {:ok, recovered} =
               SessionState.recover(session, records, Fixture.events(fixture, session))

      assert is_nil(recovered.open_interaction)
      assert recovered.interactions[id].answer == %{"text" => "retained answer"}

      assert {:accepted, ^answer_command_id} =
               Loopex.command(successor, question_answer(id, answer_command_id))
    end
  end

  defp question_answer(id, command_id \\ "answer"),
    do: %{
      type: :interaction_answer,
      command_id: command_id,
      interaction_id: id,
      answer: %{"text" => "retained answer"}
    }

  defp hold_record_commit(fixture, kind, :before),
    do:
      Loopex.M1RuntimeTestStore.hold_next_record_before_linearization(fixture.store, kind, self())

  defp hold_record_commit(fixture, kind, :after),
    do: Loopex.M1RuntimeTestStore.delay_after_record(fixture.store, kind, self())

  defp await_record_commit(_fixture, _session, kind, :before) do
    assert_receive {:record_held_before_linearization, waiter, _store, ^kind, transaction}, 5_000
    {waiter, Enum.find(transaction.records, &(&1.kind == kind))}
  end

  defp await_record_commit(fixture, session, kind, :after) do
    assert_receive {:record_linearized, waiter, _store, ^kind, :session_journal_commit,
                    {:committed, _, _receipt}},
                   5_000

    records = Fixture.records(fixture, session)
    {waiter, Enum.find(records, &(&1.payload.kind == kind)).payload}
  end

  defp await_session_transaction(store, session, tx_id, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + 5_000

    case Loopex.M1RuntimeTestStore.transaction_status(store, session, "session", tx_id) do
      :absent ->
        if System.monotonic_time(:millisecond) >= deadline, do: flunk("transaction unresolved")
        Process.sleep(10)
        await_session_transaction(store, session, tx_id, deadline)

      result ->
        result
    end
  end

  test "aborting a pending model question settles its slot and preserves a cancelled result" do
    fixture =
      start(
        tools: [ToolDefinition.question_definition()],
        script: [
          %{
            text: "question",
            calls: [%{id: "ask-1", name: "ask", arguments: %{"question" => "Explain"}}]
          },
          %{text: "next prompt", calls: []}
        ]
      )

    assert {:ok, session} =
             Runtime.create_session_with_genesis(
               fixture.runtime,
               "create",
               %{},
               genesis(fixture.definitions)
             )

    assert {:ok, attachment} = Loopex.attach(fixture.runtime, session, after_event_sequence: 0)

    assert {:accepted, "prompt"} =
             Loopex.command(attachment, %{
               type: :prompt,
               command_id: "prompt",
               content: "implement"
             })

    question = await_question(attachment)
    assert {:accepted, "abort"} = Loopex.command(attachment, %{type: :abort, command_id: "abort"})
    events = finish(attachment)
    assert Enum.find(events, &(&1.kind == "run.finished"))["outcome"] == "cancelled"
    cancelled = Enum.find(events, &(&1.kind == "interaction.cancelled"))
    assert cancelled["interaction_id"] == question["interaction_id"]
    assert cancelled["producer"] == "model_tool"
    assert cancelled["disposition"] == "cancelled"
    assert cancelled["command_id"] == "abort"
    assert is_binary(cancelled["command_digest"])

    assert {:ok, recovered} =
             SessionState.recover(
               session,
               Fixture.records(fixture, session),
               Fixture.events(fixture, session)
             )

    assert is_nil(recovered.open_interaction)

    assert Enum.find(
             SessionState.elements(recovered, question["run_id"]),
             &(&1.kind == :tool_result)
           ).outcome == :cancelled

    changes = %{"max_tokens" => 512}
    command = %{type: :configure, command_id: "after-cancel", changes: changes}
    current = recovered.configuration

    {:ok, unsupported} =
      Loopex.Runtime.SessionConfiguration.update(
        current,
        changes,
        current["model_capabilities"],
        current["provider_mapping"],
        recovered.tool_selection["definitions"]
      )

    assert {:ok, refusal} =
             SessionState.propose(recovered, command, %{configuration_candidate: unsupported})

    assert refusal.reply == {:error, :invalid_session_configuration}
    assert refusal.next.configuration == current
    assert refusal.events == []

    {:ok, compatible} =
      Loopex.Runtime.SessionConfiguration.update(
        current,
        changes,
        Map.put(current["model_capabilities"], "reasoning_levels", ["default"]),
        current["provider_mapping"]
        |> Map.put("mapping_revision", "fixture.terminal-history.v1")
        |> Map.put("canonical_terminal_tool_history", true),
        recovered.tool_selection["definitions"]
      )

    assert {:ok, accepted} =
             SessionState.propose(recovered, command, %{configuration_candidate: compatible})

    assert accepted.reply == {:accepted, "after-cancel"}
    [payload] = accepted.records

    row = %{
      payload: payload,
      journal_version: recovered.journal_version + 1,
      owner_epoch: recovered.owner_epoch,
      owner_incarnation_id: recovered.owner_incarnation_id
    }

    retained_events =
      Enum.with_index(accepted.events, recovered.event_sequence + 1)
      |> Enum.map(fn {event, sequence} -> Map.put(event, :event_sequence, sequence) end)

    records = Fixture.records(fixture, session)
    events = Fixture.events(fixture, session) ++ retained_events
    assert {:ok, _} = SessionState.recover(session, records ++ [row], events)

    incompatible_row = put_in(row, [:payload, "configuration"], unsupported)

    assert SessionState.recover(session, records ++ [incompatible_row], events) ==
             {:error, :invalid_configuration_transition}

    assert Agent.get(fixture.executor, & &1.jobs) == []

    assert {:error, :interaction_resolved} =
             Loopex.command(
               attachment,
               %{
                 type: :interaction_answer,
                 command_id: "late",
                 interaction_id: question["interaction_id"],
                 answer: %{"text" => "too late"}
               }
             )

    assert {:accepted, "next"} =
             Loopex.command(attachment, %{type: :prompt, command_id: "next", content: "continue"})

    terminal = Enum.find(finish(attachment), &(&1.kind == "run.finished"))
    assert terminal["outcome"] == "failed"

    assert terminal["failure"] == %{
             "version" => 2,
             "category" => "context_preparation_failed",
             "retryable" => false,
             "measurement_scope" => nil,
             "cause" => "canonical_history_rendering_unsupported"
           }

    assert length(AgentLoopTestModel.dispatched(fixture.model)) == 1
    records = Fixture.records(fixture, session)
    events = Fixture.events(fixture, session)
    assert {:ok, _} = SessionState.recover(session, records, events)
    refusal = Enum.find(records, &(&1.payload.kind == "context_admission_refused_v2"))
    assert refusal.payload["projection_state"] == "unavailable"

    refute Enum.any?(records, fn row ->
             row.payload["run_id"] == refusal.payload["run_id"] and
               row.payload.kind in ["model_request_committed_v2", "model_attempt_opened_v1"]
           end)

    for field <- ~w(system_message_count session_message_count steer_message_count
                    tool_definition_count provider_estimated_tokens record_byte_cost
                    ordered_descriptor_digest measurement_scope) do
      assert is_nil(refusal.payload[field])

      altered =
        Enum.map(records, fn row ->
          if row == refusal, do: put_in(row, [:payload, field], 0), else: row
        end)

      assert SessionState.recover(session, altered, events) == {:error, :invalid_context_refusal}
    end

    for {path, value} <- [
          {["failure", "cause"], "artifact_preparation_failed"},
          {["failure", "measurement_scope"], "ordinary"},
          {["failure", "observed"], 0},
          {["failure", "extra"], true},
          {["configuration_version"], 2},
          {["projection_state"], "measured"},
          {["project_disposition"], "staged_empty"}
        ] do
      altered =
        Enum.map(records, fn row ->
          if row == refusal, do: %{row | payload: put_in(row.payload, path, value)}, else: row
        end)

      assert SessionState.recover(session, altered, events) == {:error, :invalid_context_refusal}
    end

    refusal_index = Enum.find_index(records, &(&1 == refusal))
    assert Enum.at(records, refusal_index + 1).payload.kind == "run_terminal_committed"

    assert {:error, :incomplete_context_refusal_pair} =
             SessionState.recover(session, Enum.take(records, refusal_index + 1), [])
  end

  test "a captured compatible renderer keeps cancelled terminal results in the next run" do
    fixture =
      start(
        tools: [ToolDefinition.question_definition()],
        script: [
          %{
            text: "question",
            calls: [%{id: "ask", name: "ask", arguments: %{"question" => "Explain"}}]
          },
          %{text: "continued", calls: []}
        ]
      )

    compatible =
      configuration()
      |> put_in(["model_capabilities", "reasoning_levels"], ["default"])
      |> put_in(["provider_mapping", "mapping_revision"], "fixture.terminal-history.v1")
      |> put_in(["provider_mapping", "canonical_terminal_tool_history"], true)

    assert {:ok, session} =
             Runtime.create_session_with_genesis(
               fixture.runtime,
               "create",
               %{},
               genesis(fixture.definitions, compatible)
             )

    assert {:ok, attachment} = Loopex.attach(fixture.runtime, session, after_event_sequence: 0)

    assert {:accepted, "prompt"} =
             Loopex.command(attachment, %{type: :prompt, command_id: "prompt", content: "go"})

    await_question(attachment)
    assert {:accepted, "abort"} = Loopex.command(attachment, %{type: :abort, command_id: "abort"})
    assert Enum.find(finish(attachment), &(&1.kind == "run.finished"))["outcome"] == "cancelled"
    prompt(attachment, "next", "continue")

    [_first, second] = AgentLoopTestModel.dispatched(fixture.model)
    assert Enum.find(second.messages, &(&1["role"] == "tool"))["outcome"] == "cancelled"
    records = Fixture.records(fixture, session)

    assert {:ok, recovered} =
             SessionState.recover(session, records, Fixture.events(fixture, session))

    refute Enum.any?(records, &(&1.payload.kind == "context_admission_refused_v2"))

    assert SessionState.propose_context_preparation_failure(
             recovered,
             List.last(recovered.run_order),
             :canonical_history_rendering_unsupported
           ) == {:error, :invalid_context_refusal}
  end

  test "invalid question arguments fail before policy or executor admission" do
    for arguments <- [
          %{"question" => ""},
          %{"question" => "Pick", "choices" => ["same", "same"]},
          %{"question" => "Pick", "choices" => []}
        ] do
      fixture =
        start(
          tools: [ToolDefinition.question_definition()],
          policy: Loopex.AgentLoopUnexpectedPolicy,
          policy_identity: %{"id" => "loopex.test.question-policy", "revision" => "1"},
          script: [
            %{text: "question", calls: [%{id: "ask-invalid", name: "ask", arguments: arguments}]},
            %{text: "done", calls: []}
          ]
        )

      assert {:ok, session} =
               Runtime.create_session_with_genesis(
                 fixture.runtime,
                 "create-invalid-question",
                 %{},
                 genesis(fixture.definitions)
               )

      assert {:ok, attachment} = Loopex.attach(fixture.runtime, session, after_event_sequence: 0)

      assert {:accepted, "prompt"} =
               Loopex.command(attachment, %{
                 type: :prompt,
                 command_id: "prompt",
                 content: "implement"
               })

      events = finish(attachment)
      terminal = Enum.find(events, &(&1.kind == "tool.finished"))
      assert terminal["outcome"] == "failed"
      assert terminal["reason"] == "invalid_tool_arguments"
      refute Enum.any?(events, &(&1.kind == "interaction.requested"))
      assert Agent.get(fixture.executor, & &1.jobs) == []
    end
  end

  test "two prompts and restart stage captured host instructions, settings and tools" do
    [_, range] =
      Path.expand("../priv/vectors/artifact_read.v1.json", __DIR__)
      |> File.read!()
      |> JSON.decode!()
      |> Map.fetch!("vectors")

    fixture =
      start(
        tools: [Fixture.tool_definition(), range["definition"]],
        script: [%{text: "first answer", calls: []}, %{text: "second answer", calls: []}],
        max_tokens: 7
      )

    configuration = configuration(String.duplicate("captured ", 400))
    genesis = genesis(fixture.definitions, configuration)

    assert {:ok, session} =
             Runtime.create_session_with_genesis(fixture.runtime, "create-v3", %{}, genesis)

    assert {:ok, attachment} = Loopex.attach(fixture.runtime, session, after_event_sequence: 0)
    prompt(attachment, "first", "first prompt")
    prompt(attachment, "second", "second prompt")
    [first, second] = AgentLoopTestModel.dispatched(fixture.model)
    {:ok, text} = Instructions.render(configuration["instructions"])

    for request <- [first, second] do
      assert hd(request.messages) == %{"role" => "system", "content" => text}
      assert request.sampling == SessionConfiguration.sampling(configuration)
      assert request.tools == fixture.definitions
    end

    assert Enum.map(tl(second.messages), & &1["content"]) == [
             "first prompt",
             "first answer",
             "second prompt"
           ]

    records = Fixture.records(fixture, session)
    assert hd(records).payload == genesis

    assert {:ok, recovered} =
             SessionState.recover(session, records, Fixture.events(fixture, session))

    for run <- recovered.run_order do
      assert SessionState.run_configuration(recovered, run) == configuration
    end

    staged = Enum.filter(records, &(&1.payload.kind == "model_request_committed_v2"))
    assert length(staged) == 2

    for row <- staged do
      assert row.payload["configuration_version"] == 1

      assert hd(row.payload["context_receipt"]["blocks"])["source_reference"] ==
               SessionConfiguration.instruction_source(configuration)
    end

    assert :ok = Loopex.stop(fixture.runtime)

    restarted =
      start(
        store: fixture.store,
        tools: [],
        max_tokens: 3,
        cleanup_grace_ms: 1,
        script: [%{text: "third answer", calls: []}]
      )

    before_duplicate = Fixture.records(restarted, session)

    assert {:ok, ^session} =
             Runtime.create_session_with_genesis(restarted.runtime, "create-v3", %{}, genesis)

    assert Fixture.records(restarted, session) == before_duplicate

    assert {:ok, ^session} =
             Loopex.resume_session(restarted.runtime, session, command_id: "resume-v3")

    assert {:ok, attachment} =
             Loopex.attach(restarted.runtime, session,
               after_event_sequence: List.last(Fixture.events(restarted, session)).event_sequence
             )

    prompt(attachment, "third", "third prompt")
    [third] = AgentLoopTestModel.dispatched(restarted.model)
    assert hd(third.messages) == hd(first.messages)
    assert third.sampling == first.sampling
    assert third.tools == first.tools

    assert Enum.map(tl(third.messages), & &1["content"]) == [
             "first prompt",
             "first answer",
             "second prompt",
             "second answer",
             "third prompt"
           ]

    assert {:ok, final} =
             SessionState.recover(
               session,
               Fixture.records(restarted, session),
               Fixture.events(restarted, session)
             )

    assert final.cleanup_grace_ms == 5_000
    assert final.tool_selection["artifact_read"] == genesis["tool_selection"]["artifact_read"]

    assert final.tool_selection["artifact_read"]["definition_digest"] ==
             range["definition_digest"]

    assert Loopex.ToolRegistry.resolve(restarted.runtime, "loopex.read") ==
             {:error, :unknown_tool}
  end

  test "fresh creation validates admitted definitions and normalized original options" do
    fixture = start(script: [])
    definition = Map.put(Fixture.tool_definition(), "description", "unregistered bytes")

    assert Runtime.create_session_with_genesis(
             fixture.runtime,
             "unregistered",
             %{},
             genesis([definition])
           ) ==
             {:error, :invalid_session_creation}

    assert Runtime.create_session_with_genesis(
             fixture.runtime,
             "options-mismatch",
             %{tenant: "other"},
             genesis(fixture.definitions)
           ) ==
             {:error, :invalid_session_creation}

    assert Fixture.run_ids(fixture) == {}

    selected = genesis(fixture.definitions) |> Map.put("options", %{"tenant" => "a"})

    assert {:ok, session} =
             Runtime.create_session_with_genesis(
               fixture.runtime,
               "normalized",
               %{tenant: "a"},
               selected
             )

    assert hd(Fixture.records(fixture, session)).payload == selected

    assert {:ok, ^session} =
             Runtime.create_session_with_genesis(
               fixture.runtime,
               "normalized",
               %{"tenant" => "a"},
               selected
             )
  end

  test "one create identity cannot substitute changed captured genesis" do
    fixture = start(script: [])
    original = genesis(fixture.definitions)

    assert {:ok, session} =
             Runtime.create_session_with_genesis(fixture.runtime, "identity", %{}, original)

    changed = put_in(original, ["runtime_configuration", "cleanup_grace_ms"], 1)

    assert {:error, _reason} =
             Runtime.create_session_with_genesis(fixture.runtime, "identity", %{}, changed)

    assert hd(Fixture.records(fixture, session)).payload == original
  end

  test "replay rejects configuration-version substitution despite unchanged request receipts" do
    fixture = start(script: [%{text: "answer", calls: []}])

    assert {:ok, session} =
             Runtime.create_session_with_genesis(
               fixture.runtime,
               "create",
               %{},
               genesis(fixture.definitions)
             )

    assert {:ok, attachment} = Loopex.attach(fixture.runtime, session, after_event_sequence: 0)
    prompt(attachment, "prompt", "input")
    records = Fixture.records(fixture, session)
    events = Fixture.events(fixture, session)
    assert {:ok, _} = SessionState.recover(session, records, events)

    for kind <- ["prompt_admitted_v3", "model_request_committed_v2"] do
      substituted =
        Enum.map(records, fn record ->
          if record.payload.kind == kind,
            do: put_in(record, [:payload, "configuration_version"], 2),
            else: record
        end)

      assert {:error, _reason} = SessionState.recover(session, substituted, events)
    end
  end

  test "configured input overflow commits a v2 numeric refusal without a provider call" do
    fixture = start(script: [%{text: "must not run", calls: []}])

    config =
      configuration()
      |> Map.put("context_token_budget", 700)
      |> Map.put("system_class_tokens", 600)
      |> put_in(["budget_origins", "context_token_budget"], "explicit")

    assert {:ok, session} =
             Runtime.create_session_with_genesis(
               fixture.runtime,
               "create",
               %{},
               genesis(fixture.definitions, config)
             )

    assert {:ok, attachment} = Loopex.attach(fixture.runtime, session, after_event_sequence: 0)

    assert {:accepted, "overflow"} =
             Loopex.command(attachment, %{
               type: :prompt,
               command_id: "overflow",
               content: String.duplicate("p", 2_100)
             })

    events = finish(attachment)
    terminal = Enum.find(events, &(&1.kind == "run.finished"))
    assert terminal["outcome"] == "failed"
    assert terminal["failure"]["version"] == 2
    assert terminal["failure"]["measurement_scope"] == "ordinary"
    assert terminal["failure"]["dimension"] == "context_tokens"
    assert terminal["failure"]["limit"] == 700
    assert terminal["failure"]["hard_limit"] == 700
    assert AgentLoopTestModel.dispatched(fixture.model) == []
    records = Fixture.records(fixture, session)
    refusal = Enum.find(records, &(&1.payload.kind == "context_admission_refused_v2"))
    assert refusal.payload["configuration_version"] == 1
    assert refusal.payload["projection_state"] == "measured"
    assert refusal.payload["episode_id"] == nil
    assert {:ok, _} = SessionState.recover(session, records, Fixture.events(fixture, session))

    invalid =
      Enum.map(records, fn row ->
        if row.payload.kind == "context_admission_refused_v2",
          do: put_in(row, [:payload, "failure", "hard_limit"], 701),
          else: row
      end)

    assert {:error, _} = SessionState.recover(session, invalid, Fixture.events(fixture, session))
  end

  test "captured refuse mode denies policy deferral without an interaction or executor effect" do
    fixture =
      start(
        policy: Loopex.ConfiguredSessionDeferringPolicy,
        script: [
          %{
            text: "try write",
            calls: [%{id: "write-call", name: "write", arguments: %{"path" => "a"}}]
          },
          %{text: "write was denied", calls: []}
        ]
      )

    retained = genesis(fixture.definitions) |> Map.put("policy_defer_mode", "refuse")

    assert {:ok, session} =
             Runtime.create_session_with_genesis(fixture.runtime, "create", %{}, retained)

    assert {:ok, attachment} = Loopex.attach(fixture.runtime, session, after_event_sequence: 0)

    assert {:accepted, "prompt"} =
             Loopex.command(attachment, %{type: :prompt, command_id: "prompt", content: "write a"})

    events = finish(attachment)
    assert Enum.find(events, &(&1.kind == "run.finished"))["outcome"] == "completed"
    denial = Enum.find(events, &(&1.kind == "tool.finished"))
    assert denial["outcome"] == "denied"
    assert denial["reason"] == "interaction_unsupported"
    refute Enum.any?(events, &(&1.kind == "interaction.requested"))

    assert {:ok, recovered} =
             SessionState.recover(
               session,
               Fixture.records(fixture, session),
               Fixture.events(fixture, session)
             )

    assert recovered.policy_defer_mode == "refuse"
    assert is_nil(recovered.open_interaction)
    assert Agent.get(fixture.executor, & &1.jobs) == []
  end

  test "self-consistent renamed instruction provenance cannot replace captured source identity" do
    fixture = start(script: [%{text: "answer", calls: []}])

    assert {:ok, session} =
             Runtime.create_session_with_genesis(
               fixture.runtime,
               "create",
               %{},
               genesis(fixture.definitions)
             )

    assert {:ok, attachment} = Loopex.attach(fixture.runtime, session, after_event_sequence: 0)
    prompt(attachment, "prompt", "input")

    records =
      Enum.map(Fixture.records(fixture, session), fn record ->
        if record.payload.kind == "model_request_committed_v2" do
          receipt = record.payload["context_receipt"]
          [first | rest] = receipt["blocks"]
          changed = put_in(first, ["source_reference", "version"], "host.v2")
          blocks = [changed | rest]

          receipt = %{
            receipt
            | "blocks" => blocks,
              "ordered_descriptor_digest" => descriptor_digest(blocks)
          }

          put_in(record, [:payload, "context_receipt"], receipt)
        else
          record
        end
      end)

    assert {:error, :invalid_model_request_transition} =
             SessionState.recover(session, records, Fixture.events(fixture, session))
  end

  test "captured system ceilings retain strict edges and the legacy fallback" do
    observations = %{
      system_class_tokens: 4_999,
      system_class_token_ceiling: 5_000,
      provider_estimated_tokens: 6_000,
      context_token_budget: 8_192,
      context_record_byte_ceiling: 65_536,
      context_record_depth_limit: 12,
      context_record_cardinality_limit: 1_024
    }

    record = %{kind: "candidate"}
    assert ContextAdmission.preflight_required_candidate(record, observations) == :ok

    for observed <- [5_000, 5_001] do
      assert {:refused,
              %{"dimension" => "system_class_tokens", "observed" => ^observed, "limit" => 5_000}} =
               ContextAdmission.preflight_required_candidate(record, %{
                 observations
                 | system_class_tokens: observed
               })
    end

    legacy = Map.delete(observations, :system_class_token_ceiling)

    assert ContextAdmission.preflight_required_candidate(record, %{
             legacy
             | system_class_tokens: 999
           }) == :ok

    assert {:refused, %{"limit" => 1_000}} =
             ContextAdmission.preflight_required_candidate(record, %{
               legacy
               | system_class_tokens: 1_000
             })

    for limit <- [nil, 0, -1, 1.0, "5000", 18_446_744_073_709_551_616] do
      assert ContextAdmission.preflight_required_candidate(record, %{
               observations
               | system_class_token_ceiling: limit
             }) ==
               {:error, :invalid_system_class_ceiling}
    end

    for observed <- [nil, -1, "4999"] do
      assert ContextAdmission.preflight_required_candidate(record, %{
               observations
               | system_class_tokens: observed
             }) ==
               {:error, :invalid_system_class_observation}
    end
  end

  defp descriptor_digest(blocks) do
    blocks
    |> Enum.reduce(
      :crypto.hash_update(:crypto.hash_init(:sha256), "loopex.context.descriptors.v1" <> <<0>>),
      fn block, digest ->
        bytes = Canonical.encode(block)

        digest
        |> :crypto.hash_update(<<byte_size(bytes)::unsigned-big-integer-size(64)>>)
        |> :crypto.hash_update(bytes)
      end
    )
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  defp start(options) do
    fixture = Fixture.start(options)
    on_exit(fn -> Fixture.stop(fixture) end)
    fixture
  end

  defp prompt(attachment, id, content) do
    assert {:accepted, ^id} =
             Loopex.command(attachment, %{type: :prompt, command_id: id, content: content})

    assert Enum.find(finish(attachment), &(&1.kind == "run.finished"))["outcome"] == "completed"
  end

  defp await_question(attachment, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + 5_000

    case Loopex.next_event(attachment) do
      {:ok, %{kind: "interaction.requested"} = event} ->
        event

      _ ->
        if System.monotonic_time(:millisecond) >= deadline, do: flunk("no model question")
        Process.sleep(10)
        await_question(attachment, deadline)
    end
  end

  defp finish(attachment),
    do: collect(attachment, System.monotonic_time(:millisecond) + 5_000, [])

  defp collect(attachment, deadline, events) do
    case Loopex.next_event(attachment) do
      {:ok, event} ->
        if event.kind == "run.finished",
          do: Enum.reverse([event | events]),
          else: collect(attachment, deadline, [event | events])

      other ->
        if System.monotonic_time(:millisecond) >= deadline do
          flunk(
            "configured run did not finish: #{inspect(other)}; #{inspect(Enum.map(events, & &1.kind))}"
          )
        else
          Process.sleep(10)
          collect(attachment, deadline, events)
        end
    end
  end
end
