Code.require_file("support/m1_runtime_helper.exs", __DIR__)
Code.require_file("support/agent_loop_helper.exs", __DIR__)
Code.require_file("support/configured_genesis_helper.exs", __DIR__)

defmodule Loopex.ArtifactReadAdmissionTest do
  use ExUnit.Case, async: false

  alias Loopex.AgentLoopFixture, as: Fixture
  alias Loopex.AgentLoopTestExecutor
  alias Loopex.Runtime
  alias Loopex.Runtime.SessionState
  alias LoopexProtocol.Canonical

  defmodule Policy do
    @moduledoc false
    @behaviour Loopex.Policy

    @impl true
    def decide(request) do
      send(Process.whereis(Loopex.ArtifactReadAdmissionTest), {:policy, request})

      case {request.tool_call_id, request[:interaction_response]} do
        {"deferred", nil} ->
          {:defer,
           %{
             kind: :choice,
             prompt: "Read this range?",
             choices: [%{id: "allow", label: "Allow"}],
             expires_in_ms: 60_000
           }}

        {"denied", _} ->
          {:deny, :policy_denied}

        _ ->
          {:allow, nil}
      end
    end
  end

  setup do
    Process.register(self(), __MODULE__)

    [range] =
      Path.expand("../priv/vectors/artifact_read.v1.json", __DIR__)
      |> File.read!()
      |> JSON.decode!()
      |> Map.fetch!("vectors")

    reference = %{
      digest: String.duplicate("a", 64),
      size: 8_192,
      locator: "artifact-admission-fixture",
      media_type: "text/plain",
      role: "tool_output",
      use_canonicalization_version: Canonical.version(),
      use_digest: String.duplicate("b", 64),
      use_locator: "use:" <> String.duplicate("b", 64)
    }

    %{definitions: [Fixture.tool_definition(), range["definition"]], reference: reference}
  end

  test "allowed ranges bind the exact preceding receipt while policy sees original arguments",
       context do
    args = range(context.reference)
    fixture = start(context, [call("write", %{"path" => "output"}), call("read", args)])
    {session, attachment} = run(fixture, "create")
    assert List.last(finish(attachment))["outcome"] == "completed"
    assert_receive {:policy, %{tool_call_id: "write"}}
    assert_receive {:policy, %{tool_call_id: "read", arguments: ^args}}

    [write, read] = AgentLoopTestExecutor.jobs(fixture.executor)
    assert write.artifact_policy == %{"retain" => true}

    assert read.artifact_policy ==
             Loopex.Executor.JobRequest.artifact_policy(
               "loopex.read",
               "1.1.0",
               Loopex.ConfiguredGenesisFixture.genesis(context.definitions)["tool_selection"][
                 "artifact_read"
               ],
               Loopex.Conversation.normalized_call_id(read.run_id, 1, read.tool_call_id)
             )

    assert Map.delete(read.validated_arguments, "resolved_artifact") == args
    records = Fixture.records(fixture, session)
    source = Enum.find(records, &(&1.payload.kind == "executor_receipt_committed_v2"))

    expected = %{
      "reference" => plain(context.reference),
      "source" => %{
        "record_kind" => "executor_receipt_committed_v2",
        "journal_version" => source.journal_version,
        "record_digest" => Canonical.digest(source.payload),
        "run_id" => write.run_id,
        "operation_id" => write.operation_id,
        "attempt" => write.attempt,
        "tool_call_id" => write.tool_call_id
      }
    }

    assert read.validated_arguments["resolved_artifact"] == expected
    assert :ok = Loopex.Executor.validate_job(read)

    assert {:ok, recovered} =
             SessionState.recover(session, records, Fixture.events(fixture, session))

    assert recovered.artifact_sources[context.reference.use_locator] == expected

    for replacement <- [
          put_in(read.artifact_policy, ["projection", "artifact_read"], nil),
          put_in(
            read.artifact_policy,
            ["projection", "normalized_call_id"],
            "lx_" <> String.duplicate("0", 48)
          )
        ] do
      assert {:ok, substituted} =
               Loopex.Executor.job(%{Map.from_struct(read) | artifact_policy: replacement})

      assert :ok = Loopex.Executor.validate_job(substituted)

      changed =
        Enum.map(records, fn row ->
          if row.payload.kind == "effect_intent_committed_v2" and
               row.payload["job"]["tool_call_id"] == "read",
             do: put_in(row, [:payload, "job"], plain(Map.from_struct(substituted))),
             else: row
        end)

      assert {:error, :invalid_effect_intent_transition} =
               SessionState.recover(session, changed, Fixture.events(fixture, session))
    end

    # A new self-consistent job digest cannot legitimize a substituted source.
    altered_arguments =
      put_in(
        read.validated_arguments,
        ["resolved_artifact", "source", "record_digest"],
        String.duplicate("0", 64)
      )

    fields =
      read
      |> Map.from_struct()
      |> Map.drop([:canonical_request_bytes, :canonical_request_digest, :effective_job_deadline])
      |> Map.put(:validated_arguments, altered_arguments)

    assert {:ok, altered} = Loopex.Executor.job(fields)
    assert :ok = Loopex.Executor.validate_job(altered)

    changed =
      Enum.map(records, fn row ->
        if row.payload.kind == "effect_intent_committed_v2" and
             row.payload["job"]["tool_call_id"] == "read",
           do: put_in(row, [:payload, "job"], plain(Map.from_struct(altered))),
           else: row
      end)

    assert SessionState.recover(session, changed, Fixture.events(fixture, session)) ==
             {:error, :invalid_effect_intent_transition}
  end

  test "preparation sources retain exact committed receipt provenance and measured bytes",
       context do
    id = String.duplicate("\"", 1_000)

    fixture =
      Fixture.start(
        tools: context.definitions,
        bounds_max_turns: 1,
        script: [
          %{text: "work", calls: [%{id: id, name: "write", arguments: %{"path" => "output"}}]},
          %{text: "done", calls: []}
        ]
      )

    on_exit(fn -> Fixture.stop(fixture) end)
    {session, attachment} = run(fixture, "prepare-source")
    assert List.last(finish(attachment))["outcome"] == "bound_reached"

    records = Fixture.records(fixture, session)
    receipt = Enum.find(records, &(&1.payload.kind == "executor_receipt_committed_v2"))
    events = Fixture.events(fixture, session)
    assert {:ok, recovered} = SessionState.recover(session, records, events)
    [run] = recovered.run_order
    assert {:ok, [source]} = SessionState.preparation_sources(recovered, run)

    assert source.record_digest == Canonical.digest(receipt.payload)
    assert source.journal_version == receipt.journal_version

    assert {:ok, normalized, cost} =
             Loopex.Store.normalize_and_measure_item(:record, receipt.payload)

    assert source.record_byte_cost == cost
    assert cost == byte_size(:erlang.term_to_binary(normalized, [:deterministic]))
    assert source.content == receipt.payload["receipt"]["output"]

    assert source.source_reference == %{
             "kind" => "session_tool_result",
             "run_id" => run,
             "turn" => 1,
             "call_id" => id
           }

    assert source.metadata ==
             Map.take(
               receipt.payload["receipt"],
               ~w(session_id run_id operation_id attempt tool_call_id)
             )

    assert map_size(source.metadata) == 5
    assert byte_size(source.content) < 2_048

    # Concept: excluded units consume no storage allowance.
    # Technical depth: the selected projection, not the whole receipt index,
    # determines candidates after future compaction/tail selection.
    selected =
      Enum.filter(SessionState.lineage_elements(recovered, run), &(&1.kind == :user_message))

    assert {:ok, []} = SessionState.preparation_sources(recovered, run, selected)
    assert {:ok, []} = SessionState.preparation_sources(%{recovered | tool_selection: nil}, run)

    assert {:error, :context_projection_invalid} =
             SessionState.preparation_sources(%{recovered | tool_result_sources: %{}}, run)

    refute Enum.any?(records, &(&1.payload.kind == "tool_result_reference_prepared"))
    assert {:ok, repeated} = SessionState.recover(session, records, events)
    assert repeated.tool_result_sources == recovered.tool_result_sources
    assert repeated.conversation == recovered.conversation
  end

  test "uncommitted receipts grant no membership and uncertain commits retain one source",
       context do
    for phase <- [:before_linearization, :after_linearization_before_result] do
      fixture =
        start(context, [
          call("write", %{"path" => "output"}),
          call("read", range(context.reference))
        ])

      :ok =
        Loopex.M1RuntimeTestStore.hold_next_record_before_linearization(
          fixture.store,
          "executor_receipt_committed_v2",
          self()
        )

      {session, attachment} = run(fixture, "create")

      assert_receive {:record_held_before_linearization, waiter, _store,
                      "executor_receipt_committed_v2", transaction},
                     5_000

      refute Enum.any?(
               Fixture.records(fixture, session),
               &(&1.payload.kind == "executor_receipt_committed_v2")
             )

      assert_receive {:policy, %{tool_call_id: "write"}}
      refute_receive {:policy, %{tool_call_id: "read"}}, 20
      assert [%{tool_call_id: "write"}] = AgentLoopTestExecutor.jobs(fixture.executor)
      :ok = Loopex.M1RuntimeTestStore.inject(fixture.store, {:session_journal_commit, phase})
      Loopex.M1RuntimeTestStore.release(waiter)
      assert List.last(finish(attachment))["outcome"] == "completed"
      assert_receive {:policy, %{tool_call_id: "read"}}
      assert [_, read] = AgentLoopTestExecutor.jobs(fixture.executor)

      assert read.validated_arguments["resolved_artifact"]["source"]["record_digest"] ==
               Canonical.digest(hd(transaction.records))

      records = Fixture.records(fixture, session)

      assert Enum.count(
               records,
               &(&1.payload.kind == "executor_receipt_committed_v2" and
                   &1.payload["receipt"]["tool_call_id"] == "write")
             ) == 1

      assert {:ok, recovered} =
               SessionState.recover(session, records, Fixture.events(fixture, session))

      assert map_size(recovered.artifact_sources) == 1
    end
  end

  test "the path branch remains closed and conflicting uses never replace their first source",
       context do
    definition = List.last(context.definitions)
    args = %{"path" => "λ/output.txt"}
    fixture = start(context, [call("read", args)])
    {_session, attachment} = run(fixture, "create")
    assert List.last(finish(attachment))["outcome"] == "completed"
    assert_receive {:policy, %{tool_call_id: "read", arguments: ^args}}
    assert [%{validated_arguments: ^args}] = AgentLoopTestExecutor.jobs(fixture.executor)

    assert Loopex.Runtime.ArtifactRead.resolve(definition, %{"path" => <<255>>}, %{}) ==
             {:error, :invalid_tool_arguments}

    record = %{kind: "executor_receipt_committed_v2"}
    job = %{run_id: "run", operation_id: "operation", attempt: 1, tool_call_id: "call"}
    sources = Loopex.Runtime.ArtifactRead.retain(%{}, [context.reference], record, 2, job)

    assert Loopex.Runtime.ArtifactRead.retain(sources, [context.reference], record, 3, job) ==
             sources

    conflicting = %{context.reference | digest: String.duplicate("c", 64)}
    sources = Loopex.Runtime.ArtifactRead.retain(sources, [conflicting], record, 4, job)
    sources = Loopex.Runtime.ArtifactRead.retain(sources, [context.reference], record, 5, job)

    assert Loopex.Runtime.ArtifactRead.resolve(definition, range(context.reference), sources) ==
             {:error, :invalid_tool_arguments}
  end

  test "malformed, injected and unresolved ranges fail before even a deferring policy", context do
    valid = range(context.reference)

    invalid = [
      %{},
      %{"path" => ""},
      Map.put(valid, "path", "output"),
      Map.put(valid, "extra", true),
      Map.put(valid, "resolved_artifact", %{}),
      Map.delete(valid, "offset"),
      Map.delete(valid, "length"),
      %{valid | "offset" => -1},
      %{valid | "offset" => 18_446_744_073_709_551_616},
      %{valid | "offset" => 8_193},
      %{valid | "offset" => 0.0},
      %{valid | "length" => 0},
      %{valid | "length" => 4_097},
      %{valid | "artifact_use" => "use:" <> String.duplicate("c", 64)},
      %{valid | "artifact_use" => "forged"}
    ]

    for args <- invalid do
      fixture = start(context, [call("write", %{"path" => "output"}), call("deferred", args)])
      {_session, attachment} = run(fixture, "create")
      events = finish(attachment)
      assert_receive {:policy, %{tool_call_id: "write"}}
      refute_receive {:policy, %{tool_call_id: "deferred"}}, 0
      refute Enum.any?(events, &(&1.kind == "interaction.requested"))

      assert Enum.any?(
               events,
               &(&1.kind == "tool.finished" and &1["outcome"] == "failed" and
                   &1["reason"] == "invalid_tool_arguments")
             )

      assert [%{tool_call_id: "write"}] = AgentLoopTestExecutor.jobs(fixture.executor)
    end
  end

  test "a use committed in another session grants no membership", context do
    fixture =
      start(context, [call("write", %{"path" => "output"})], [
        call("read", range(context.reference))
      ])

    {_first, attachment} = run(fixture, "first")
    finish(attachment)
    {_second, attachment} = run(fixture, "second")
    events = finish(attachment)
    assert_receive {:policy, %{tool_call_id: "write"}}
    refute_receive {:policy, %{tool_call_id: "read"}}, 0

    assert Enum.any?(
             events,
             &(&1.kind == "tool.finished" and &1["reason"] == "invalid_tool_arguments")
           )

    assert [%{tool_call_id: "write"}] = AgentLoopTestExecutor.jobs(fixture.executor)
  end

  test "policy denial and deferred approval preserve original arguments and dispatch only after allow",
       context do
    for id <- ["denied", "deferred"] do
      args = range(context.reference)
      fixture = start(context, [call("write", %{"path" => "output"}), call(id, args)])
      {session, attachment} = run(fixture, "create")
      assert_receive {:policy, %{tool_call_id: "write"}}, 5_000
      assert_receive {:policy, %{tool_call_id: ^id, arguments: ^args}}, 5_000

      if id == "deferred" do
        requested = await_kind(attachment, "interaction.requested") |> List.last()
        assert [%{tool_call_id: "write"}] = AgentLoopTestExecutor.jobs(fixture.executor)

        assert {:accepted, "answer"} =
                 Loopex.command(attachment, %{
                   type: :interaction_answer,
                   command_id: "answer",
                   interaction_id: requested["interaction_id"],
                   choice_id: "allow"
                 })

        assert_receive {:policy,
                        %{
                          tool_call_id: ^id,
                          arguments: ^args,
                          interaction_response: %{answer: %{choice_id: "allow"}}
                        }},
                       5_000

        finish(attachment)
        assert [_, job] = AgentLoopTestExecutor.jobs(fixture.executor)
        assert Map.has_key?(job.validated_arguments, "resolved_artifact")
      else
        finish(attachment)
        assert [%{tool_call_id: "write"}] = AgentLoopTestExecutor.jobs(fixture.executor)
      end

      assert {:ok, _} =
               SessionState.recover(
                 session,
                 Fixture.records(fixture, session),
                 Fixture.events(fixture, session)
               )
    end
  end

  test "restart reconstructs receipt membership with no current host read registry", context do
    fixture = start(context, [call("write", %{"path" => "output"})])
    {session, attachment} = run(fixture, "create")
    finish(attachment)
    assert :ok = Loopex.stop(fixture.runtime)

    restarted =
      Fixture.start(
        store: fixture.store,
        tools: [],
        policy: Policy,
        script: [
          %{text: "read", calls: [call("read", %{range(context.reference) | "offset" => 8_192})]},
          %{text: "done", calls: []}
        ]
      )

    on_exit(fn -> Fixture.stop(restarted) end)

    assert {:ok, ^session} =
             Loopex.resume_session(restarted.runtime, session, command_id: "resume")

    assert {:ok, attachment} =
             Loopex.attach(restarted.runtime, session,
               after_event_sequence: List.last(Fixture.events(restarted, session)).event_sequence
             )

    assert {:accepted, "next"} =
             Loopex.command(attachment, %{
               type: :prompt,
               command_id: "next",
               content: "read the retained result"
             })

    finish(attachment)
    assert [job] = AgentLoopTestExecutor.jobs(restarted.executor)
    assert job.validated_arguments["resolved_artifact"]["reference"] == plain(context.reference)
    assert job.validated_arguments["offset"] == 8_192

    assert job.artifact_policy["projection"] == %{
             "revision" => 1,
             "artifact_read" =>
               Loopex.ConfiguredGenesisFixture.genesis(context.definitions)["tool_selection"][
                 "artifact_read"
               ],
             "normalized_call_id" =>
               Loopex.Conversation.normalized_call_id(job.run_id, 1, job.tool_call_id)
           }

    assert {:ok, recovered} =
             SessionState.recover(
               session,
               Fixture.records(restarted, session),
               Fixture.events(restarted, session)
             )

    assert recovered.artifact_sources[context.reference.use_locator] ==
             job.validated_arguments["resolved_artifact"]
  end

  test "ordinary allocation chooses the largest shared allowance fitting the actual budget",
       context do
    script = [
      %{text: "tools", calls: [call("write", %{"path" => "output"})]},
      %{text: "done", calls: []}
    ]

    fixture =
      Fixture.start(
        tools: context.definitions,
        artifacts: %{"write" => [context.reference]},
        script: script ++ script
      )

    on_exit(fn -> Fixture.stop(fixture) end)
    {baseline, attachment} = run(fixture, "baseline")
    assert List.last(finish(attachment))["outcome"] == "completed"

    original =
      Fixture.records(fixture, baseline)
      |> Enum.filter(&(&1.payload.kind == "model_request_committed_v2"))
      |> List.last()

    target = original.payload["context_receipt"]["provider_estimated_tokens"] - 3
    initial = Loopex.ConfiguredGenesisFixture.configuration()

    assert {:ok, configuration} =
             Loopex.Runtime.SessionConfiguration.update(
               initial,
               %{"context_token_budget" => target, "system_class_tokens" => target},
               initial["model_capabilities"],
               initial["provider_mapping"],
               fixture.definitions
             )

    genesis = Loopex.ConfiguredGenesisFixture.genesis(fixture.definitions, configuration)

    assert {:ok, session} =
             Runtime.create_session_with_genesis(fixture.runtime, "bounded", %{}, genesis)

    assert {:ok, attachment} = Loopex.attach(fixture.runtime, session, after_event_sequence: 0)

    assert {:accepted, "prompt"} =
             Loopex.command(
               attachment,
               %{type: :prompt, command_id: "prompt", content: "use the tool"}
             )

    assert List.last(finish(attachment))["outcome"] == "completed"

    row =
      Fixture.records(fixture, session)
      |> Enum.filter(&(&1.payload.kind == "model_request_committed_v2"))
      |> List.last()

    receipt = row.payload["context_receipt"]
    projection = row.payload["lineage_projection"]
    assert map_size(receipt) == 17
    refute Map.has_key?(receipt, "lineage_projection")
    assert receipt["provider_estimated_tokens"] == target
    assert projection["allowance"] in 0..20
    source = "tool output for write"
    message = List.last(row.payload["request"]["messages"])
    raw = %{message | "content" => source}

    assert {:ok, larger} =
             Loopex.Runtime.ToolResultExcerpt.encode(
               raw,
               context.reference,
               projection["allowance"] + 1
             )

    delta =
      Loopex.Bounds.estimate(Canonical.encode(larger.message)) -
        Loopex.Bounds.estimate(Canonical.encode(message))

    assert delta > 0
    assert receipt["provider_estimated_tokens"] + delta > target

    assert {:ok, _} =
             SessionState.recover(
               session,
               Fixture.records(fixture, session),
               Fixture.events(fixture, session)
             )
  end

  test "historical staging remains readable but projection provenance cannot disappear after cutover",
       context do
    fixture = Fixture.start(tools: context.definitions, script: [%{text: "one"}, %{text: "two"}])
    on_exit(fn -> Fixture.stop(fixture) end)
    {session, attachment} = run(fixture, "compatibility")
    assert List.last(finish(attachment))["outcome"] == "completed"

    assert {:accepted, "next"} =
             Loopex.command(
               attachment,
               %{type: :prompt, command_id: "next", content: "again"}
             )

    assert List.last(finish(attachment))["outcome"] == "completed"
    records = Fixture.records(fixture, session)
    events = Fixture.events(fixture, session)
    [first, second] = Enum.filter(records, &(&1.payload.kind == "model_request_committed_v2"))
    assert second.payload["lineage_projection"]["ranges"] == []

    malformed =
      Enum.map(records, fn row ->
        if row.journal_version == first.journal_version do
          payload = Map.put(row.payload, "lineage_projection", nil)
          %{row | payload: fix_record_cost(payload)}
        else
          row
        end
      end)

    assert {:error, :invalid_model_request_transition} =
             SessionState.recover(session, malformed, events)

    historical = remove_projection(records, first.journal_version)
    assert {:ok, state} = SessionState.recover(session, historical, events)
    assert state.lineage_projection_revision == 1

    assert {:error, :invalid_model_request_transition} =
             SessionState.recover(
               session,
               remove_projection(records, second.journal_version),
               events
             )
  end

  defp remove_projection(records, version) do
    Enum.map(records, fn row ->
      if row.journal_version == version do
        payload =
          Map.delete(row.payload, "lineage_projection")

        %{row | payload: fix_record_cost(payload)}
      else
        row
      end
    end)
  end

  defp fix_record_cost(payload) do
    {:ok, _, bytes} = Loopex.Store.normalize_and_measure_item(:record, payload)

    if payload["context_receipt"]["record_byte_cost"] == bytes,
      do: payload,
      else: fix_record_cost(put_in(payload, ["context_receipt", "record_byte_cost"], bytes))
  end

  defp start(context, calls, later \\ []) do
    script = [%{text: "tools", calls: calls}, %{text: "done", calls: []}]

    script =
      if later == [],
        do: script,
        else: script ++ [%{text: "more", calls: later}, %{text: "done", calls: []}]

    fixture =
      Fixture.start(
        tools: context.definitions,
        policy: Policy,
        artifacts: %{"write" => [context.reference]},
        script: script
      )

    on_exit(fn -> Fixture.stop(fixture) end)
    fixture
  end

  defp run(fixture, id) do
    genesis = Loopex.ConfiguredGenesisFixture.genesis(fixture.definitions)
    assert {:ok, session} = Runtime.create_session_with_genesis(fixture.runtime, id, %{}, genesis)
    assert {:ok, attachment} = Loopex.attach(fixture.runtime, session, after_event_sequence: 0)

    assert {:accepted, "prompt"} =
             Loopex.command(attachment, %{
               type: :prompt,
               command_id: "prompt",
               content: "use the tool"
             })

    {session, attachment}
  end

  defp call("write" = id, args), do: %{id: id, name: "write", arguments: args}
  defp call(id, args), do: %{id: id, name: "read", arguments: args}

  defp range(reference),
    do: %{"artifact_use" => reference.use_locator, "offset" => 0, "length" => 4_096}

  defp plain(map), do: Map.new(map, fn {key, value} -> {Atom.to_string(key), value} end)
  defp finish(attachment), do: await_kind(attachment, "run.finished")

  defp await_kind(attachment, kind),
    do: collect(attachment, kind, System.monotonic_time(:millisecond) + 5_000, [])

  defp collect(attachment, kind, deadline, events) do
    assert System.monotonic_time(:millisecond) < deadline

    case Loopex.next_event(attachment) do
      {:ok, event} ->
        if event.kind == kind,
          do: Enum.reverse([event | events]),
          else: collect(attachment, kind, deadline, [event | events])

      _ ->
        Process.sleep(5)
        collect(attachment, kind, deadline, events)
    end
  end
end
