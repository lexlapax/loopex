Code.require_file("support/m1_runtime_helper.exs", __DIR__)
Code.require_file("support/agent_loop_helper.exs", __DIR__)
Code.require_file("support/configured_genesis_helper.exs", __DIR__)

defmodule Loopex.ArtifactRuntimeTest do
  use ExUnit.Case, async: true

  alias Loopex.AgentLoopFixture, as: Fixture
  alias Loopex.ArtifactStore
  alias Loopex.Runtime.SessionState
  alias Loopex.Runtime.ArtifactPreparation
  alias Loopex.Store
  alias LoopexProtocol.Canonical

  defmodule RetainedArtifactStore do
    @moduledoc false
    @behaviour Loopex.ArtifactStore

    alias LoopexProtocol.Canonical

    def start do
      Agent.start_link(fn -> %{objects: %{}, uses: %{}} end)
    end

    def put(pid, bytes, %{media_type: media_type, role: role, metadata: metadata}) do
      digest = Canonical.digest_bytes(bytes)
      object = %{digest: digest, size: byte_size(bytes), locator: "runtime:" <> digest}

      artifact_use = %{
        canonicalization_version: Canonical.version(),
        object_digest: object.digest,
        object_size: object.size,
        object_locator: object.locator,
        media_type: media_type,
        role: role,
        metadata: metadata
      }

      use_digest = Canonical.digest(["artifact-use-v2", artifact_use])

      reference =
        Map.merge(object, %{
          media_type: media_type,
          role: role,
          use_canonicalization_version: Canonical.version(),
          use_digest: use_digest,
          use_locator: "use:" <> use_digest
        })

      Agent.update(pid, fn state ->
        %{
          state
          | objects: Map.put(state.objects, object.locator, {object, bytes}),
            uses: Map.put(state.uses, reference.use_locator, artifact_use)
        }
      end)

      {:ok, reference}
    end

    def put(_pid, _bytes, _use), do: {:error, :adapter_received_unnormalized_use}

    def fetch(pid, object) do
      case Agent.get(pid, &Map.fetch(&1.objects, object.locator)) do
        {:ok, {_stored, bytes}} -> {:ok, bytes}
        :error -> {:error, :unknown_artifact}
      end
    end

    def stat(pid, locator) do
      case Agent.get(pid, &Map.fetch(&1.objects, locator)) do
        {:ok, {object, _bytes}} -> {:ok, object}
        :error -> {:error, :unknown_artifact}
      end
    end

    def describe(pid, use_locator) do
      case Agent.get(pid, &Map.fetch(&1.uses, use_locator)) do
        {:ok, artifact_use} -> {:ok, artifact_use}
        :error -> {:error, :unknown_artifact_use}
      end
    end
  end

  test "preparation reservation and completion retain exact source credit through unknown commits" do
    {fixture, state} = preparation_fixture()
    run = state.active_run_id
    assert {:ok, [source]} = SessionState.preparation_sources(state, run)
    now = System.system_time(:millisecond)
    assert {:ok, reservation} = SessionState.propose_preparation_reservation(state, run, now)
    [record] = reservation.records
    assert record["started_at_ms"] == now
    assert record["deadline_ms"] == now + 60_000
    assert record["deadline_origin"] == "preparation"
    assert record["source_count"] == 1
    assert record["source_record_bytes"] == source.record_byte_cost
    assert record["cursor"] == 0
    assert record["source"]["metadata"] == source.metadata

    {:ok, artifact_pid} = RetainedArtifactStore.start()
    on_exit(fn -> if Process.alive?(artifact_pid), do: Agent.stop(artifact_pid) end)
    artifact_store = %{module: RetainedArtifactStore, handle: artifact_pid}
    assert Agent.get(artifact_pid, & &1.objects) == %{}

    reserved = retain_preparation_proposal(fixture, state, reservation, :unknown)
    assert {:ok, recovered} = recover_preparation(fixture, state.session_id)
    assert recovered.artifact_preparations == reserved.artifact_preparations

    assert {:reserved, ^source, episode} =
             SessionState.propose_preparation_reservation(recovered, run, now + 100)

    assert episode["source_count"] == 1
    assert episode["deadline_ms"] == now + 60_000
    assert Agent.get(artifact_pid, & &1.objects) == %{}

    metadata =
      Map.merge(source.metadata, %{"role" => "tool_output", "media_type" => "text/plain"})

    assert {:ok, reference} = ArtifactStore.put(artifact_store, source.content, metadata)
    assert {:ok, retained_bytes} = ArtifactStore.fetch(artifact_store, reference)
    assert retained_bytes == source.content
    assert {:ok, retained_use} = ArtifactStore.describe(artifact_store, reference)
    assert retained_use.metadata == source.metadata

    assert {:ok, completion} =
             SessionState.propose_prepared_reference(
               recovered,
               run,
               reference,
               System.system_time(:millisecond)
             )

    finished = retain_preparation_proposal(fixture, recovered, completion, :unknown)

    assert {:ok, replayed} = recover_preparation(fixture, state.session_id)
    assert replayed.prepared_tool_results == finished.prepared_tool_results
    assert replayed.artifact_preparations == finished.artifact_preparations
    assert replayed.conversation == recovered.conversation
    assert :ready = SessionState.propose_preparation_reservation(replayed, run, now + 200)
    completed = replayed.artifact_preparations[episode["episode_id"]]
    assert completed["source_count"] == 1
    assert completed["source_record_bytes"] == source.record_byte_cost
    assert completed["cursor"] == 1
    assert completed["deadline_ms"] == episode["deadline_ms"]

    assert {:ok, entries, %{"ranges" => [range]}} =
             SessionState.projected_lineage(replayed, run, 40)

    assert range["source_reference"] == source.source_reference
    assert range["artifact_use"] == reference.use_locator
    assert range["source_digest"] == Canonical.digest_bytes(source.content)

    assert Enum.any?(entries, fn {_, message} ->
             message["role"] == "tool" and message["content"] != source.content
           end)

    row =
      Enum.find(
        Fixture.records(fixture, state.session_id),
        &(&1.payload.kind == "tool_result_reference_prepared")
      )

    resolved = replayed.artifact_sources[reference.use_locator]
    assert resolved["source"]["record_kind"] == "tool_result_reference_prepared"
    assert resolved["source"]["record_digest"] == Canonical.digest(row.payload)
    assert resolved["source"]["journal_version"] == row.journal_version

    assert {:ok, %{"resolved_artifact" => ^resolved}} =
             Loopex.Runtime.ArtifactRead.resolve(
               List.last(fixture.definitions),
               %{"artifact_use" => reference.use_locator, "offset" => 0, "length" => 4_096},
               replayed.artifact_sources
             )

    records = Fixture.records(fixture, state.session_id)
    events = Fixture.events(fixture, state.session_id)

    changes = [
      Map.put(row.payload, "version", 2),
      Map.put(row.payload, "completed_at_ms", completed["deadline_ms"]),
      put_in(row.payload, ["source", "source_digest"], String.duplicate("0", 64)),
      put_in(row.payload, ["source", "source_byte_count"], byte_size(source.content) + 1),
      put_in(row.payload, ["reference", "use_digest"], String.duplicate("0", 64))
    ]

    for changed <- changes do
      history =
        Enum.map(records, fn item ->
          if item.journal_version == row.journal_version,
            do: %{item | payload: changed},
            else: item
        end)

      assert {:error, :invalid_artifact_preparation_transition} =
               SessionState.recover(state.session_id, history, events)
    end

    assert {:ok, ^reference} = ArtifactStore.put(artifact_store, source.content, metadata)
    assert Agent.get(artifact_pid, &map_size(&1.objects)) == 1
    assert Agent.get(artifact_pid, &map_size(&1.uses)) == 1
  end

  test "preparation replay refuses altered source identity, counters, deadline and borrowed use" do
    {fixture, state} = preparation_fixture()
    run = state.active_run_id

    assert {:ok, reservation} =
             SessionState.propose_preparation_reservation(
               state,
               run,
               System.system_time(:millisecond)
             )

    reserved = retain_preparation_proposal(fixture, state, reservation)
    records = Fixture.records(fixture, state.session_id)
    events = Fixture.events(fixture, state.session_id)
    [record] = reservation.records

    altered = [
      Map.put(record, "deadline_ms", record["deadline_ms"] + 1),
      Map.put(record, "deadline_origin", "run"),
      Map.put(record, "source_count", 2),
      Map.put(record, "source_record_bytes", record["source_record_bytes"] + 1),
      Map.put(record, "cursor", 1),
      Map.put(record, "projection_revision", 2),
      Map.put(record, "extra", true),
      put_in(record, ["source", "receipt_digest"], String.duplicate("0", 64)),
      put_in(record, ["source", "metadata", "attempt"], 2),
      put_in(record, ["source", "source_reference", "turn"], 2)
    ]

    for changed <- altered do
      history =
        Enum.map(records, fn row ->
          if row.payload.kind == record.kind, do: %{row | payload: changed}, else: row
        end)

      assert {:error, :invalid_artifact_preparation_transition} =
               SessionState.recover(state.session_id, history, events)
    end

    assert {:ok, [source]} = SessionState.preparation_sources(reserved, run)
    {:ok, artifact_pid} = RetainedArtifactStore.start()
    on_exit(fn -> if Process.alive?(artifact_pid), do: Agent.stop(artifact_pid) end)
    artifact_store = %{module: RetainedArtifactStore, handle: artifact_pid}

    metadata =
      Map.merge(source.metadata, %{"role" => "tool_output", "media_type" => "text/plain"})

    assert {:ok, reference} = ArtifactStore.put(artifact_store, source.content, metadata)
    borrowed = Map.put(metadata, "run_id", "another-run")
    assert {:ok, another_use} = ArtifactStore.put(artifact_store, source.content, borrowed)

    assert {:error, :invalid_artifact_prepared_reference} =
             SessionState.propose_prepared_reference(
               reserved,
               run,
               another_use,
               System.system_time(:millisecond)
             )

    for changed <- [
          %{reference | size: reference.size + 1},
          %{reference | digest: String.duplicate("0", 64)},
          %{reference | use_digest: String.duplicate("0", 64)}
        ] do
      assert {:error, :invalid_artifact_prepared_reference} =
               SessionState.propose_prepared_reference(
                 reserved,
                 run,
                 changed,
                 System.system_time(:millisecond)
               )
    end
  end

  test "episode completion preserves fixed deadline and charges each source once" do
    identity = %{"episode_id" => "episode", "run_id" => "run", "turn_id" => "turn"}
    source = preparation_source()
    assert {:ok, reserved} = ArtifactPreparation.reserve(nil, identity, source, 1_000, nil)

    assert {:error, :artifact_preparation_already_reserved} =
             ArtifactPreparation.reserve(reserved, identity, source, 1_001, nil)

    assert {:ok, record} =
             ArtifactPreparation.complete(reserved, source, source_reference(source), 1_002)

    assert {:ok, completed} =
             ArtifactPreparation.replay_completion(
               reserved,
               record,
               source,
               source_reference(source)
             )

    assert {:ok, second} = ArtifactPreparation.reserve(completed, identity, source, 1_100, nil)
    assert second["deadline_ms"] == 61_000
    assert second["started_at_ms"] == 1_000
    assert second["source_count"] == 2
    assert second["source_record_bytes"] == 2 * source.record_byte_cost
    assert second["cursor"] == 1

    assert {:error, :artifact_preparation_deadline} =
             ArtifactPreparation.reserve(completed, identity, source, 61_000, nil)

    assert {:error, :artifact_preparation_deadline} =
             ArtifactPreparation.complete(reserved, source, source_reference(source), 61_000)

    expired = Map.put(record, "completed_at_ms", 61_000)

    assert {:error, :invalid_artifact_preparation_transition} =
             ArtifactPreparation.replay_completion(
               reserved,
               expired,
               source,
               source_reference(source)
             )

    assert {:ok, shortened} = ArtifactPreparation.reserve(nil, identity, source, 1_000, 2_000)
    assert shortened["deadline_ms"] == 2_000
    assert shortened["deadline_origin"] == "run"

    assert {:error, :run_deadline_reached} =
             ArtifactPreparation.complete(shortened, source, source_reference(source), 2_000)

    assert {:error, :run_deadline_reached} =
             ArtifactPreparation.reserve(nil, identity, source, 2_000, 2_000)

    assert {:error, :invalid_artifact_preparation_clock} =
             ArtifactPreparation.reserve(nil, identity, source, -1, nil)

    assert {:error, :invalid_artifact_preparation_clock} =
             ArtifactPreparation.reserve(nil, identity, source, 18_446_744_073_709_551_615, nil)
  end

  test "an outstanding preparation reservation prevents otherwise valid staging on replay" do
    {fixture, state} = preparation_fixture()
    records = Fixture.records(fixture, state.session_id)
    events = Fixture.events(fixture, state.session_id)
    receipt = Enum.find(records, &(&1.payload.kind == "executor_receipt_committed"))
    finished = Enum.find(events, &(&1.kind == "tool.finished"))
    prefix = Enum.take_while(records, &(&1.journal_version <= receipt.journal_version))
    prefix_events = Enum.take_while(events, &(&1.event_sequence <= finished.event_sequence))
    assert {:ok, before_staging} = SessionState.recover(state.session_id, prefix, prefix_events)
    run = before_staging.active_run_id

    assert {:ok, reservation} =
             SessionState.propose_preparation_reservation(
               before_staging,
               run,
               System.system_time(:millisecond)
             )

    assert {:error, :artifact_preparation_pending} =
             SessionState.propose_model_request(reservation.next, run, %{})

    row = %{
      receipt
      | journal_version: receipt.journal_version + 1,
        payload: hd(reservation.records)
    }

    suffix =
      records
      |> Enum.drop(length(prefix))
      |> Enum.map(fn row ->
        %{row | journal_version: row.journal_version + 1}
      end)

    assert {:error, :invalid_model_request_transition} =
             SessionState.recover(state.session_id, prefix ++ [row] ++ suffix, events)
  end

  test "retained preparation failure proves the compact unavailable refusal and terminal" do
    for cause <- [:artifact_preparation_failed, :artifact_preparation_deadline] do
      {fixture, state} = preparation_fixture()
      run = state.active_run_id
      now = System.system_time(:millisecond)
      assert {:ok, reservation} = SessionState.propose_preparation_reservation(state, run, now)
      reserved = retain_preparation_proposal(fixture, state, reservation)
      [episode] = Map.values(reserved.artifact_preparations)
      observed = if cause == :artifact_preparation_deadline, do: episode["deadline_ms"], else: now

      assert {:error, :invalid_context_refusal} =
               SessionState.propose_context_preparation_failure(reserved, run, cause)

      assert {:ok, failure} =
               SessionState.propose_preparation_failure(reserved, run, cause, observed)

      failed = retain_preparation_proposal(fixture, reserved, failure, :unknown)
      assert {:error, ^cause} = SessionState.preflight_run_history(failed, run)

      assert {:error, ^cause} =
               SessionState.propose_preparation_reservation(failed, run, observed + 1)

      assert {:ok, terminal} =
               SessionState.propose_context_preparation_failure(failed, run, cause)

      [refusal, finished] = terminal.records
      assert refusal["projection_state"] == "unavailable"
      assert refusal["failure"]["cause"] == Atom.to_string(cause)

      for field <-
            ~w(provider_estimated_tokens ordered_descriptor_digest system_message_count session_message_count steer_message_count tool_definition_count record_byte_cost) do
        assert is_nil(refusal[field])
      end

      assert finished["failure"] == refusal["failure"]
      final = retain_preparation_proposal(fixture, failed, terminal)
      assert is_nil(final.active_run_id)
      assert final.prepared_tool_results == %{}
      assert final.conversation == state.conversation
      assert {:ok, recovered} = recover_preparation(fixture, state.session_id)
      assert recovered.artifact_preparations == final.artifact_preparations

      records = Fixture.records(fixture, state.session_id)
      events = Fixture.events(fixture, state.session_id)
      [fact] = failure.records

      for altered <- [
            Map.put(fact, "cause", "invented"),
            Map.put(fact, "extra", "hidden"),
            put_in(fact, ["source", "record_byte_cost"], 1)
          ] do
        history =
          Enum.map(records, fn row ->
            if row.payload.kind == fact.kind, do: %{row | payload: altered}, else: row
          end)

        assert {:error, :invalid_artifact_preparation_transition} =
                 SessionState.recover(state.session_id, history, events)
      end

      failure_row = Enum.find(records, &(&1.payload.kind == fact.kind))

      missing =
        records
        |> Enum.reject(&(&1.journal_version == failure_row.journal_version))
        |> Enum.map(fn row ->
          if row.journal_version > failure_row.journal_version,
            do: %{row | journal_version: row.journal_version - 1},
            else: row
        end)

      assert {:error, :invalid_context_refusal} =
               SessionState.recover(state.session_id, missing, events)
    end
  end

  test "episode accepts its exact source and byte caps then refuses more work" do
    identity = %{"episode_id" => "episode", "run_id" => "run", "turn_id" => "turn"}
    source = %{preparation_source() | record_byte_cost: 65_536}

    completed =
      Enum.reduce(1..16, nil, fn number, episode ->
        source = %{source | journal_version: number}

        assert {:ok, reserved} =
                 ArtifactPreparation.reserve(episode, identity, source, 1_000 + number, nil)

        assert reserved["source_count"] == number
        assert reserved["source_record_bytes"] == number * 65_536
        reference = source_reference(source)

        assert {:ok, record} =
                 ArtifactPreparation.complete(reserved, source, reference, 1_000 + number)

        assert {:ok, completed} =
                 ArtifactPreparation.replay_completion(reserved, record, source, reference)

        completed
      end)

    assert completed["source_record_bytes"] == 1_048_576
    assert completed["cursor"] == 16

    assert {:error, :artifact_preparation_count_exhausted} =
             ArtifactPreparation.reserve(completed, identity, source, 1_100, nil)

    assert {:ok, failure} =
             ArtifactPreparation.failure(
               completed,
               identity,
               source,
               1_100,
               :artifact_preparation_count_exhausted
             )

    assert {:ok, failed} =
             ArtifactPreparation.replay_failure(completed, failure, identity, source)

    assert failed["source_count"] == 16
    assert failed["source_record_bytes"] == 1_048_576
    assert failed["cursor"] == 16
    wrong_cause = Map.put(failure, "cause", "artifact_preparation_bytes_exhausted")

    assert {:error, :invalid_artifact_preparation_transition} =
             ArtifactPreparation.replay_failure(completed, wrong_cause, identity, source)

    assert {:error, :context_projection_invalid} =
             ArtifactPreparation.reserve(
               nil,
               identity,
               %{source | record_byte_cost: 65_537},
               1_000,
               nil
             )
  end

  test "one Core-retained use is the exact reference journaled published recovered and privately described" do
    {:ok, artifact_store} = RetainedArtifactStore.start()
    on_exit(fn -> if Process.alive?(artifact_store), do: Agent.stop(artifact_store) end)

    private_metadata = %{
      "media_type" => "text/plain",
      "role" => "tool_output",
      "session_id" => "private-session",
      "run_id" => "private-run",
      "operation_id" => "private-operation",
      "attempt" => 1,
      "tool_call_id" => "private-call"
    }

    assert {:ok, reference} =
             invoke_core(:put, [
               %{module: RetainedArtifactStore, handle: artifact_store},
               "one retained runtime artifact",
               private_metadata
             ])

    assert ArtifactStore.valid_reference?(reference)

    assert {:ok, private_use} =
             invoke_core(:describe, [
               %{module: RetainedArtifactStore, handle: artifact_store},
               reference
             ])

    assert private_use.metadata == Map.drop(private_metadata, ["media_type", "role"])

    fixture =
      Fixture.start(
        script: [
          %{
            text: "write it",
            calls: [
              %{id: "artifact-call", name: "write", arguments: %{"path" => "output.txt"}}
            ]
          },
          %{text: "done", calls: []}
        ],
        artifacts: %{"artifact-call" => [reference]}
      )

    on_exit(fn -> Fixture.stop(fixture) end)

    {session_id, attachment, {:accepted, _command_id}} = Fixture.run(fixture, "make output")
    events = await_run_finished(attachment)

    public_reference = %{
      "digest" => reference.digest,
      "media_type" => reference.media_type,
      "size" => reference.size,
      "role" => reference.role,
      "locator" => reference.locator,
      "use_canonicalization_version" => reference.use_canonicalization_version,
      "use_digest" => reference.use_digest,
      "use_locator" => reference.use_locator
    }

    assert tool_finished = Enum.find(events, &(&1.kind == "tool.finished")), inspect(events)
    assert tool_finished["artifacts"] == [public_reference]

    all_records = Fixture.records(fixture, session_id)
    all_events = Fixture.events(fixture, session_id)

    receipt =
      all_records
      |> Enum.find(&(&1.payload[:kind] == "executor_receipt_committed"))
      |> get_in([:payload, "receipt"])

    assert receipt["artifacts"] == [public_reference]

    public_and_durable_planes = %{
      public_tool_event: tool_finished,
      durable_receipt_output: receipt["output"],
      durable_receipt_artifacts: receipt["artifacts"]
    }

    for {plane, projection} <- public_and_durable_planes,
        private <- Map.values(private_use.metadata) |> Enum.reject(&is_integer/1) do
      refute inspect(projection, limit: :infinity, printable_limit: :infinity) =~ private,
             "#{plane} exposed private artifact-use provenance #{inspect(private)}"
    end

    compact_bytes = Canonical.encode(public_reference)

    for private <- Map.values(private_use.metadata) |> Enum.reject(&is_integer/1) do
      refute compact_bytes =~ private
    end

    assert {:ok, recovered} =
             SessionState.recover(
               session_id,
               Fixture.records(fixture, session_id),
               Fixture.events(fixture, session_id)
             )

    [run_id] = recovered.conversation |> Map.keys()

    assert Enum.any?(SessionState.elements(recovered, run_id), fn
             %{kind: :tool_result, artifacts: [^reference]} -> true
             _element -> false
           end)

    assert {:ok, ^private_use} =
             invoke_core(:describe, [
               %{module: RetainedArtifactStore, handle: artifact_store},
               reference
             ])

    for private <- Map.values(private_use.metadata) |> Enum.reject(&is_integer/1) do
      refute inspect(all_records, limit: :infinity, printable_limit: :infinity) =~ private
      refute inspect(all_events, limit: :infinity, printable_limit: :infinity) =~ private
    end

    [first_request, second_request] = Loopex.AgentLoopTestModel.dispatched(fixture.model)

    assert Enum.any?(
             first_request.messages,
             &(&1 == %{"role" => "user", "content" => "make output"})
           )

    normalized_id =
      "lx_" <>
        (LoopexProtocol.Canonical.encode([tool_finished["run_id"], 1, "artifact-call"])
         |> LoopexProtocol.Canonical.digest_bytes()
         |> binary_part(0, 48))

    assert Enum.any?(second_request.messages, fn
             %{"role" => "tool", "tool_call_id" => ^normalized_id} -> true
             _other -> false
           end),
           "the committed tool result did not reach the next model request"
  end

  test "a malformed or legacy artifact reference fails closed before durable or public success" do
    {reference, _private_use} = compact_reference()

    invalid = [
      Map.drop(reference, [:use_canonicalization_version, :use_digest, :use_locator]),
      %{reference | use_locator: "use:" <> String.duplicate("0", 64)},
      Map.put(reference, :metadata, %{"session_id" => "must-not-inline"})
    ]

    for {candidate, index} <- Enum.with_index(invalid, 1) do
      fixture =
        Fixture.start(
          script: [
            %{
              text: "write it",
              calls: [
                %{id: "artifact-call-#{index}", name: "write", arguments: %{"path" => "x"}}
              ]
            }
          ],
          artifacts: %{"artifact-call-#{index}" => [candidate]}
        )

      on_exit(fn -> Fixture.stop(fixture) end)

      {session_id, attachment, {:accepted, _command_id}} =
        Fixture.run(fixture, "reject malformed artifact #{index}")

      events = await_run_finished(attachment)
      tool = Enum.find(events, &(&1.kind == "tool.finished"))
      finished = Enum.find(events, &(&1.kind == "run.finished"))

      assert tool["outcome"] == "outcome_unknown"
      assert tool["artifacts"] == []
      assert finished["outcome"] == "outcome_unknown"

      records = Fixture.records(fixture, session_id)

      refute Enum.any?(records, &(&1.payload[:kind] == "executor_receipt_committed"))
      refute inspect(records) =~ "must-not-inline"
      refute inspect(events) =~ "must-not-inline"
    end
  end

  defp preparation_fixture do
    [_, range] =
      Path.expand("../priv/vectors/artifact_read.v1.json", __DIR__)
      |> File.read!()
      |> JSON.decode!()
      |> Map.fetch!("vectors")

    id = String.duplicate("\"", 1_000)

    fixture =
      Fixture.start(
        tools: [Fixture.tool_definition(), range["definition"]],
        script: [
          %{text: "work", calls: [%{id: id, name: "write", arguments: %{"path" => "output"}}]},
          %{text: "done", calls: []}
        ]
      )

    on_exit(fn -> Fixture.stop(fixture) end)

    genesis = Loopex.ConfiguredGenesisFixture.genesis(fixture.definitions)

    assert {:ok, session} =
             Loopex.Runtime.create_session_with_genesis(fixture.runtime, "prepare", %{}, genesis)

    assert {:ok, attachment} = Loopex.attach(fixture.runtime, session, after_event_sequence: 0)

    assert {:accepted, "prompt"} =
             Loopex.command(attachment, %{type: :prompt, command_id: "prompt", content: "go"})

    assert List.last(await_run_finished(attachment))["outcome"] == "completed"
    assert :ok = Loopex.stop(fixture.runtime)
    assert {:ok, recovered} = recover_preparation(fixture, session)

    bounds = Map.put(Fixture.bounds(), :context_token_budget, 8_192)

    assert {:ok, prompt} =
             SessionState.propose(
               recovered,
               %{type: :prompt, command_id: "next", content: "continue"},
               bounds
             )

    {fixture, retain_preparation_proposal(fixture, recovered, prompt)}
  end

  defp retain_preparation_proposal(fixture, state, proposal, mode \\ :normal) do
    store = %Store{adapter: Loopex.M1RuntimeTestStore, reference: fixture.store}

    assert {:ok, transaction} =
             Store.session_commit(
               state.session_id,
               "session",
               proposal.tx_id,
               state.owner_epoch,
               state.owner_incarnation_id,
               state.journal_version,
               proposal.records,
               proposal.events
             )

    if mode == :unknown do
      :ok =
        Loopex.M1RuntimeTestStore.inject(
          fixture.store,
          {:session_journal_commit, :after_linearization_before_result}
        )

      assert {:commit_unknown, tx} = Store.transact(store, transaction)
      assert tx == proposal.tx_id

      assert {:terminal, :committed} =
               Store.transaction_status(store, state.session_id, "session", tx)
    end

    assert {:committed, tx, receipt} = Store.transact(store, transaction)
    assert tx == proposal.tx_id
    assert {:ok, committed} = SessionState.commit_proposal(proposal, receipt)
    committed
  end

  defp recover_preparation(fixture, session) do
    SessionState.recover(
      session,
      Fixture.records(fixture, session),
      Fixture.events(fixture, session)
    )
  end

  defp preparation_source do
    %{
      source_reference: %{
        "kind" => "session_tool_result",
        "run_id" => "source-run",
        "turn" => 1,
        "call_id" => "call"
      },
      record_digest: String.duplicate("a", 64),
      record_byte_cost: 8_192,
      journal_version: 5,
      content: String.duplicate("exact \"λ\"\n", 300),
      metadata: %{
        "session_id" => "session",
        "run_id" => "source-run",
        "operation_id" => "operation",
        "attempt" => 1,
        "tool_call_id" => "call"
      }
    }
  end

  defp source_reference(source) do
    digest = Canonical.digest_bytes(source.content)
    object = %{digest: digest, size: byte_size(source.content), locator: "test:" <> digest}

    use = %{
      canonicalization_version: Canonical.version(),
      object_digest: digest,
      object_size: object.size,
      object_locator: object.locator,
      media_type: "text/plain",
      role: "tool_output",
      metadata: source.metadata
    }

    use_digest = Canonical.digest(["artifact-use-v2", use])

    Map.merge(object, %{
      media_type: use.media_type,
      role: use.role,
      use_canonicalization_version: Canonical.version(),
      use_digest: use_digest,
      use_locator: "use:" <> use_digest
    })
  end

  defp compact_reference do
    object = %{
      digest: String.duplicate("a", 64),
      size: 23,
      locator: "opaque-artifact-1"
    }

    private_use = %{
      canonicalization_version: Canonical.version(),
      object_digest: object.digest,
      object_size: object.size,
      object_locator: object.locator,
      media_type: "text/plain",
      role: "tool_output",
      metadata: %{
        "session_id" => "private-session",
        "run_id" => "private-run",
        "operation_id" => "private-operation",
        "attempt" => 1,
        "tool_call_id" => "private-call"
      }
    }

    use_digest = Canonical.digest(["artifact-use-v2", private_use])

    reference =
      Map.merge(object, %{
        media_type: private_use.media_type,
        role: private_use.role,
        use_canonicalization_version: private_use.canonicalization_version,
        use_digest: use_digest,
        use_locator: "use:" <> use_digest
      })

    {reference, private_use}
  end

  defp invoke_core(name, arguments) do
    if function_exported?(ArtifactStore, name, length(arguments)) do
      apply(ArtifactStore, name, arguments)
    else
      {:error, {:artifact_object_use_contract_missing, name, length(arguments)}}
    end
  end

  defp await_run_finished(attachment, deadline_ms \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + deadline_ms
    collect(attachment, deadline, deadline_ms, [])
  end

  defp collect(attachment, deadline, deadline_ms, acc) do
    case Loopex.next_event(attachment) do
      {:ok, event} ->
        acc = [event | acc]

        if event.kind == "run.finished",
          do: Enum.reverse(acc),
          else: collect(attachment, deadline, deadline_ms, acc)

      other ->
        if System.monotonic_time(:millisecond) >= deadline do
          flunk("""
          no run.finished within #{deadline_ms}ms.
          last read: #{inspect(other)}
          events observed: #{inspect(Enum.map(Enum.reverse(acc), & &1.kind))}
          """)
        else
          Process.sleep(10)
          collect(attachment, deadline, deadline_ms, acc)
        end
    end
  end
end
