Code.require_file("../../loopex/test/support/configured_genesis_helper.exs", __DIR__)

defmodule LoopexComposition.ArtifactRangeSessionTest do
  use ExUnit.Case, async: false

  alias Loopex.Runtime.SessionState
  alias Loopex.Executor.Local, as: Executor
  alias Loopex.Executor.Local.{CodingTools, WorkspaceLease}
  alias Loopex.Store.Local, as: Store
  alias Loopex.Store.Local.{Artifacts, Transfers}
  alias LoopexProtocol.{Canonical, Frame}

  defmodule Model do
    @moduledoc false
    @behaviour Loopex.Model

    @impl true
    def complete(request, options, _progress) do
      index = Agent.get_and_update(options[:observer], &{length(&1), &1 ++ [request]})

      calls =
        if rem(index, 2) == 0 do
          prompt = Enum.find(Enum.reverse(request.messages), &(&1["role"] == "user"))
          {:ok, arguments} = Frame.decode(prompt["content"], 8_192)

          case arguments do
            %{"finish" => true} ->
              []

            %{"tool" => name, "arguments" => selected} ->
              [%{id: "read-#{index}", name: name, arguments: selected}]

            _read ->
              [%{id: "read-#{index}", name: "read", arguments: arguments}]
          end
        else
          []
        end

      {:ok,
       %{
         text: "done",
         identity: %{provider: "scripted", model: request.model, endpoint: "in-process"},
         usage: %{input_tokens: 1, output_tokens: 1},
         tool_calls: calls,
         delta_count: 0,
         streamed: false,
         provider_response_id: nil,
         canonical_request_bytes: request.canonical_request_bytes,
         staged_request_digest: request.staged_request_digest
       }}
    end
  end

  for {id, arguments} <- [
        {"loopex.ls", %{}},
        {"loopex.find", %{"pattern" => "**"}},
        {"loopex.grep", %{"pattern" => "needle"}}
      ] do
    test "#{id} early spill retains full captured output through real Store restart" do
      id = unquote(id)
      arguments = unquote(Macro.escape(arguments))
      fixture = fixture("1.1.0", id)

      for number <- 1..300,
          do:
            File.write!(
              Path.join(fixture.workspace, "entry-#{number}-" <> String.duplicate("n", 64)),
              "needle\n"
            )

      {:ok, selected} = Loopex.Executor.Local.ReadOnlyTools.arguments(id, arguments)

      {:completed, captured} =
        Loopex.Executor.Local.ReadOnlyTools.execute(fixture.workspace, selected, 16_384)

      assert byte_size(captured) > 16_000 and byte_size(captured) <= 16_384

      assert {:ok, attachment} =
               Loopex.attach(fixture.runtime, fixture.session, after_event_sequence: 0)

      events =
        run(attachment, "search", %{
          "tool" => String.replace_prefix(id, "loopex.", ""),
          "arguments" => arguments
        })

      assert List.last(events)["outcome"] == "completed", inspect(events, limit: :infinity)
      [reference] = Enum.find(events, &(&1.kind == "tool.finished"))["artifacts"]
      assert reference["size"] == byte_size(captured)
      assert {:ok, records} = Store.load_records(fixture.store, fixture.session, 0, 1_000)
      [source] = Enum.filter(records, &(&1.payload.kind == "executor_receipt_committed_v2"))
      [intent] = Enum.filter(records, &(&1.payload.kind == "effect_intent_committed_v2"))
      job = intent.payload["job"]
      assert job["tool_id"] == id and job["tool_version"] == "1.1.0"
      assert job["artifact_policy"]["projection"]["artifact_read"]["tool_version"] == "1.1.0"

      assert source.payload["receipt"]["canonical_request_digest"] ==
               job["canonical_request_digest"]

      artifact = Map.new(reference, fn {key, value} -> {String.to_existing_atom(key), value} end)

      assert {:ok, ^captured} =
               Loopex.ArtifactStore.fetch(
                 %{
                   module: Artifacts,
                   handle: %{root: fixture.artifact_root, transfers: fixture.transfers}
                 },
                 artifact
               )

      {runtime, store, attachment} =
        restart(
          fixture.runtime,
          fixture.path,
          fixture.executor_options,
          fixture.observer,
          fixture.session,
          fixture.workspace
        )

      assert List.last(run(attachment, "finish", %{"finish" => true}))["outcome"] == "completed"
      assert {:ok, retained} = Store.load_records(store, fixture.session, 0, 1_000)
      assert source in retained
      assert intent in retained
      assert Enum.count(retained, &(&1.payload.kind == "executor_receipt_committed_v2")) == 1
      assert {:ok, public} = Store.load_events(store, fixture.session, 0, 1_000)
      assert {:ok, _recovered} = SessionState.recover(fixture.session, retained, public)
      requests = Agent.get(fixture.observer, & &1)
      assert length(requests) == 3
      assert_excerpt_provenance(fixture.session, retained, public, requests, source.payload)

      fields =
        Map.new(Loopex.Executor.job_fields(), fn key -> {key, job[Atom.to_string(key)]} end)

      assert {:ok, changed} =
               Loopex.Executor.job(%{
                 fields
                 | tool_version: "1.0.0",
                   artifact_policy: %{"retain" => true}
               })

      substituted =
        Map.new(Map.from_struct(changed), fn {key, value} -> {Atom.to_string(key), value} end)

      altered =
        Enum.map(retained, fn row ->
          if row.journal_version == intent.journal_version,
            do: put_in(row, [:payload, "job"], substituted),
            else: row
        end)

      assert {:error, :invalid_effect_intent_transition} =
               SessionState.recover(fixture.session, altered, public)

      assert :sys.get_state(fixture.transfers).jobs == %{}
      assert :ok = Loopex.stop(runtime)
    end
  end

  defmodule Policy do
    @moduledoc false
    @behaviour Loopex.Policy
    @impl true
    def decide(_request), do: {:allow, nil}
  end

  for restart_after <- [:file, :range] do
    test "a retained range survives restart after #{restart_after} without projection changes" do
      workflow(unquote(restart_after))
    end
  end

  test "current read keeps a small result inline across empty-registry restart" do
    fixture = fixture("1.1.0")
    inline = String.duplicate("inline 猫\n", 64)
    File.write!(Path.join(fixture.workspace, "source.txt"), inline)

    assert {:ok, attachment} =
             Loopex.attach(fixture.runtime, fixture.session, after_event_sequence: 0)

    assert List.last(run(attachment, "file", %{"path" => "source.txt"}))["outcome"] == "completed"
    [_, request] = Agent.get(fixture.observer, & &1)
    message = Enum.find(request.messages, &(&1["role"] == "tool"))
    assert {:ok, records} = Store.load_records(fixture.store, fixture.session, 0, 1_000)
    [receipt] = Enum.filter(records, &(&1.payload.kind == "executor_receipt_committed_v2"))
    assert receipt.payload["receipt"]["artifacts"] == []
    assert message["content"] == receipt.payload["receipt"]["output"]
    assert message["content"] =~ inline
    assert message["outcome"] == "completed"
    File.rm_rf!(fixture.artifact_root)

    {runtime, store, attachment} =
      restart(
        fixture.runtime,
        fixture.path,
        fixture.executor_options,
        fixture.observer,
        fixture.session,
        fixture.workspace
      )

    assert List.last(run(attachment, "finish", %{"finish" => true}))["outcome"] == "completed"
    requests = Agent.get(fixture.observer, & &1)
    assert length(requests) == 3
    assert message in List.last(requests).messages
    assert {:ok, records} = Store.load_records(store, fixture.session, 0, 1_000)
    assert {:ok, events} = Store.load_events(store, fixture.session, 0, 1_000)
    assert {:ok, _recovered} = SessionState.recover(fixture.session, records, events)
    assert_projection_contract(records)
    refute File.exists?(fixture.artifact_root)
    assert :ok = Loopex.stop(runtime)
  end

  test "a prepared oversized inline result becomes readable after empty-registry restart" do
    fixture = fixture("1.1.0", "loopex.bash")
    full = String.duplicate("quoted \"line\" 猫\n", 200)
    assert byte_size(full) > 2_048 and byte_size(full) < 16_384
    File.write!(Path.join(fixture.workspace, "source.txt"), full)

    assert {:ok, attachment} =
             Loopex.attach(fixture.runtime, fixture.session, after_event_sequence: 0)

    events =
      run(attachment, "inline", %{
        "tool" => "bash",
        "arguments" => %{"argv" => ["/bin/cat", "source.txt"]}
      })

    assert List.last(events)["outcome"] == "completed", inspect(events, limit: :infinity)
    assert Enum.find(events, &(&1.kind == "tool.finished"))["artifacts"] == []
    assert {:ok, records} = Store.load_records(fixture.store, fixture.session, 0, 1_000)
    [receipt] = Enum.filter(records, &(&1.payload.kind == "executor_receipt_committed_v2"))
    [prepared] = Enum.filter(records, &(&1.payload.kind == "tool_result_reference_prepared"))
    [reservation] = Enum.filter(records, &(&1.payload.kind == "tool_result_preparation_state_v1"))
    [intent] = Enum.filter(records, &(&1.payload.kind == "effect_intent_committed_v2"))
    assert receipt.payload["receipt"]["output"] == full
    assert receipt.payload["receipt"]["artifacts"] == []
    assert intent.payload["job"]["artifact_policy"] == %{"retain" => true}
    assert reservation.payload["source_count"] == 1
    assert prepared.payload["source"]["source_digest"] == Canonical.digest_bytes(full)
    assert prepared.payload["source"]["source_byte_count"] == byte_size(full)
    reference = prepared.payload["reference"]
    assert reference["size"] == byte_size(full)
    assert receipt.journal_version < reservation.journal_version
    assert reservation.journal_version < prepared.journal_version
    requests = Agent.get(fixture.observer, & &1)
    assert length(requests) == 2
    message = Enum.find(List.last(requests).messages, &(&1["role"] == "tool"))
    assert {:ok, encoded} = Frame.encode(message)
    assert IO.iodata_length(encoded) - 1 <= 2_048
    assert {:ok, notice} = Frame.decode(message["content"], 2_048)
    assert notice["use_locator"] == reference["use_locator"]
    assert notice["excerpt_source"] == "receipt_content"

    {runtime, store, attachment} =
      restart(
        fixture.runtime,
        fixture.path,
        fixture.executor_options,
        fixture.observer,
        fixture.session,
        fixture.workspace
      )

    assert File.read!(Path.join(fixture.workspace, "source.txt")) == "changed workspace"

    range_events =
      run(attachment, "prepared-range", %{
        "artifact_use" => reference["use_locator"],
        "offset" => 0,
        "length" => 4_096
      })

    assert List.last(range_events)["outcome"] == "completed",
           inspect(range_events, limit: :infinity)

    assert Enum.find(range_events, &(&1.kind == "tool.finished"))["artifacts"] == []
    after_read = Agent.get(fixture.observer, &List.last(&1))
    result = Enum.find(Enum.reverse(after_read.messages), &(&1["role"] == "tool"))
    assert {:ok, range} = Frame.decode(result["content"], 8_192)
    assert range["excerpt_source"] == "artifact_object"
    assert range["artifact"] == reference
    assert range["byte_count"] > 0 and range["byte_count"] <= 4_096
    assert range["content"] == binary_part(full, 0, range["byte_count"])
    assert range["next_offset"] == range["byte_count"]
    assert {:ok, retained} = Store.load_records(store, fixture.session, 0, 1_000)
    assert receipt in retained and prepared in retained and intent in retained
    assert Enum.count(retained, &(&1.payload.kind == "tool_result_reference_prepared")) == 1
    [_, read] = Enum.filter(retained, &(&1.payload.kind == "effect_intent_committed_v2"))

    assert read.payload["job"]["validated_arguments"]["resolved_artifact"]["source"] == %{
             "record_kind" => "tool_result_reference_prepared",
             "record_digest" => Canonical.digest(prepared.payload),
             "journal_version" => prepared.journal_version,
             "run_id" => receipt.payload["receipt"]["run_id"],
             "operation_id" => receipt.payload["receipt"]["operation_id"],
             "attempt" => receipt.payload["receipt"]["attempt"],
             "tool_call_id" => receipt.payload["receipt"]["tool_call_id"]
           }

    assert {:ok, public} = Store.load_events(store, fixture.session, 0, 1_000)
    assert {:ok, recovered} = SessionState.recover(fixture.session, retained, public)

    assert recovered.artifact_sources[reference["use_locator"]]["source"]["record_kind"] ==
             "tool_result_reference_prepared"

    assert :sys.get_state(fixture.transfers).jobs == %{}
    assert :ok = Loopex.stop(runtime)
  end

  defp fixture(version, search \\ nil) do
    root =
      Path.join(System.tmp_dir!(), "loopex-range-session-#{System.unique_integer([:positive])}")

    workspace = Path.join(root, "workspace")
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf!(root) end)
    bytes = :binary.copy("abcdefgh", 4_096)
    File.write!(Path.join(workspace, "source.txt"), bytes)
    artifact_root = Path.join(root, "artifacts")
    transfers = start_supervised!({Transfers, root: artifact_root})
    artifacts = %{module: Artifacts, handle: %{root: artifact_root, transfers: transfers}}
    lease = start_supervised!({WorkspaceLease, id: "lease", path: workspace, fencing_token: 1})

    executor_options = [
      identity: "range-session",
      epoch: 1,
      fencing_token: 1,
      workspace_leases: %{"lease" => lease},
      ledger_root: Path.join(root, "receipts"),
      artifacts: artifacts
    ]

    executor = start_supervised!({Executor, executor_options})
    observer = start_supervised!({Agent, fn -> [] end})
    path = Path.join(root, "store.log")
    store = start_supervised!({Store, path: path})

    definition =
      Enum.find(
        CodingTools.definitions(),
        &(&1["tool_id"] == "loopex.read" and &1["tool_version"] == version)
      )

    definitions =
      if is_nil(search),
        do: [definition],
        else: [
          definition,
          Enum.find(
            CodingTools.definitions(),
            &(&1["tool_id"] == search and
                &1["tool_version"] == if(search == "loopex.bash", do: "1.0.0", else: "1.1.0"))
          )
        ]

    runtime = runtime(store, executor, observer, definitions, artifacts)

    created =
      Loopex.create_session(runtime, %{},
        command_id: "create",
        genesis: Loopex.ConfiguredGenesisFixture.genesis(definitions)
      )

    assert {:ok, session} = created

    %{
      runtime: runtime,
      store: store,
      observer: observer,
      session: session,
      transfers: transfers,
      path: path,
      executor_options: executor_options,
      workspace: workspace,
      bytes: bytes,
      artifact_root: artifact_root
    }
  end

  defp workflow(restart_after) do
    %{
      runtime: runtime,
      store: store,
      observer: observer,
      session: session,
      transfers: transfers,
      path: path,
      executor_options: executor_options,
      workspace: workspace,
      bytes: bytes
    } = fixture("1.1.0")

    assert {:ok, attachment} = Loopex.attach(runtime, session, after_event_sequence: 0)
    first = run(attachment, "file", %{"path" => "source.txt"})
    assert List.last(first)["outcome"] == "completed", inspect(first, limit: :infinity)
    [reference] = Enum.find(first, &(&1.kind == "tool.finished"))["artifacts"]
    assert reference["size"] == byte_size(bytes)
    use = reference["use_locator"]

    {runtime, store, attachment} =
      if restart_after == :file,
        do: restart(runtime, path, executor_options, observer, session, workspace),
        else: {runtime, store, attachment}

    arguments = %{"artifact_use" => use, "offset" => 20_000, "length" => 4_096}
    second = run(attachment, "range", arguments)
    assert List.last(second)["outcome"] == "completed"
    assert Enum.find(second, &(&1.kind == "tool.finished"))["artifacts"] == []
    [_, _, _, after_range] = Agent.get(observer, & &1)
    range_message = Enum.find(Enum.reverse(after_range.messages), &(&1["role"] == "tool"))
    assert {:ok, range} = Frame.decode(range_message["content"], 8_192)
    assert range["excerpt_source"] == "artifact_object"
    assert range["artifact"] == reference
    assert range["offset"] == 20_000
    assert range["byte_count"] == 4_096
    assert range["next_offset"] == 24_096
    assert range["content"] == binary_part(bytes, 20_000, 4_096)
    assert {:ok, encoded_message} = Frame.encode(range_message)
    assert IO.iodata_length(encoded_message) - 1 <= 8_192

    assert {:ok, records} = Store.load_records(store, session, 0, 1_000)
    [source, result] = Enum.filter(records, &(&1.payload.kind == "executor_receipt_committed_v2"))
    [_, range_intent] = Enum.filter(records, &(&1.payload.kind == "effect_intent_committed_v2"))
    resolved = range_intent.payload["job"]["validated_arguments"]["resolved_artifact"]
    assert resolved["reference"] == reference
    assert resolved["source"]["record_digest"] == Canonical.digest(source.payload)
    assert resolved["source"]["journal_version"] == source.journal_version
    assert result.payload["receipt"]["output"] == range_message["content"]

    {runtime, store, attachment} =
      if restart_after == :range,
        do: restart(runtime, path, executor_options, observer, session, workspace),
        else: {runtime, store, attachment}

    third = run(attachment, "next-range", %{arguments | "offset" => 24_096})
    assert List.last(third)["outcome"] == "completed", inspect(third, limit: :infinity)
    fourth = run(attachment, "finish", %{"finish" => true})
    assert List.last(fourth)["outcome"] == "completed", inspect(fourth, limit: :infinity)
    requests = Agent.get(observer, & &1)
    assert length(requests) == 7
    assert range_message in List.last(requests).messages

    assert {:ok, records} = Store.load_records(store, session, 0, 1_000)
    assert {:ok, events} = Store.load_events(store, session, 0, 1_000)
    assert {:ok, recovered} = SessionState.recover(session, records, events)
    assert recovered.artifact_sources[use] == resolved
    assert Enum.count(records, &(&1.payload.kind == "executor_receipt_committed_v2")) == 3
    assert_projection_contract(records)
    assert_excerpt_provenance(session, records, events, requests, source.payload)
    assert :sys.get_state(transfers).jobs == %{}
    assert :ok = Loopex.stop(runtime)
  end

  defp assert_projection_contract(records) do
    requests =
      Enum.filter(
        records,
        &(&1.payload.kind in [
            "model_request_committed_v2",
            "model_request_committed_resources_v2"
          ])
      )

    assert requests != []

    for row <- requests do
      projection = row.payload["lineage_projection"]
      assert Enum.sort(Map.keys(projection)) == ~w(allowance ranges revision)
      assert projection["revision"] == 1
      assert projection["allowance"] in 0..2_048
      assert is_list(projection["ranges"])
    end
  end

  defp assert_excerpt_provenance(session, records, events, requests, source) do
    first_result = Enum.find(Enum.at(requests, 1).messages, &(&1["role"] == "tool"))
    assert {:ok, notice} = Frame.decode(first_result["content"], 2_048)
    assert notice["excerpt_source"] == "receipt_content"
    assert notice["omitted"]
    original = source["receipt"]["output"]
    assert byte_size(original) > 2_048
    assert notice["excerpt"] == binary_part(original, 0, notice["excerpt_byte_count"])
    assert {:ok, bytes} = Frame.encode(first_result)
    assert IO.iodata_length(bytes) - 1 <= 2_048

    row =
      Enum.find(records, fn row ->
        match?([_ | _], get_in(row.payload, ["lineage_projection", "ranges"]))
      end)

    projection = row.payload["lineage_projection"]
    [range] = projection["ranges"]
    assert range["source_digest"] == Canonical.digest_bytes(original)
    assert range["byte_count"] == notice["excerpt_byte_count"]

    # Equal-width substitutions preserve request bytes, receipt totals and
    # measured record size. Replay must reject the false source provenance itself.
    for changed <- [
          Map.put(range, "offset", 1),
          Map.put(range, "source_digest", String.duplicate("f", 64)),
          Map.put(range, "artifact_use", "use:" <> String.duplicate("f", 64))
        ] do
      forged =
        Enum.map(records, fn record ->
          if record.journal_version == row.journal_version,
            do:
              put_in(record, [:payload, "lineage_projection", "ranges"], [
                changed
              ]),
            else: record
        end)

      assert {:error, :invalid_model_request_transition} =
               SessionState.recover(session, forged, events)
    end
  end

  defp restart(runtime, path, executor_options, observer, session, workspace) do
    assert :ok = Loopex.stop(runtime)
    assert :ok = stop_supervised(Store)
    assert :ok = stop_supervised(Executor)
    File.write!(Path.join(workspace, "source.txt"), "changed workspace")
    store = start_supervised!({Store, path: path})
    executor = start_supervised!({Executor, executor_options})

    restarted =
      runtime(store, executor, observer, [], Keyword.fetch!(executor_options, :artifacts))

    assert {:ok, ^session} = Loopex.resume_session(restarted, session, command_id: "resume")
    assert {:ok, attachment} = Loopex.attach(restarted, session, after_event_sequence: 0)
    drain(attachment)
    {restarted, store, attachment}
  end

  defp runtime(store_pid, executor, observer, definitions, artifacts) do
    {:ok, store} = Loopex.Store.new(Store, store_pid)

    {:ok, runtime} =
      Loopex.start_link(
        runtime_id: "range-session",
        store: store,
        artifact_store: artifacts,
        context_token_budget: 8_192,
        model: %{
          module: Model,
          model: "scripted:v1",
          options: [observer: observer, max_tokens: 1_024]
        },
        executor: %{
          module: Executor,
          reference: executor,
          identity: "range-session",
          epoch: 1,
          fencing_token: 1,
          workspace_ref: "workspace",
          workspace_lease: "lease"
        },
        tools: definitions,
        active_tools: Enum.map(definitions, & &1["tool_id"]),
        policy: Policy,
        policy_identity: %{"id" => "range-policy", "revision" => "1"},
        grant_decision: {:host_policy, :allow}
      )

    on_exit(fn -> if Process.alive?(runtime.supervisor), do: Loopex.stop(runtime) end)
    runtime
  end

  defp run(attachment, id, arguments) do
    {:ok, json} = Frame.encode(arguments)

    assert {:accepted, ^id} =
             Loopex.command(attachment, %{
               type: :prompt,
               command_id: id,
               content: json |> IO.iodata_to_binary() |> String.trim_trailing("\n")
             })

    collect(attachment, System.monotonic_time(:millisecond) + 10_000, [])
  end

  defp collect(attachment, deadline, events) do
    assert System.monotonic_time(:millisecond) < deadline, "run did not finish"

    case Loopex.next_event(attachment) do
      {:ok, %{kind: "run.finished"} = event} ->
        Enum.reverse([event | events])

      {:ok, event} ->
        collect(attachment, deadline, [event | events])

      _ ->
        Process.sleep(10)
        collect(attachment, deadline, events)
    end
  end

  defp drain(attachment) do
    case Loopex.next_event(attachment) do
      {:ok, _} -> drain(attachment)
      _ -> :ok
    end
  end
end
