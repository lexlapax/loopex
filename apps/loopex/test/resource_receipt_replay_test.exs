defmodule Loopex.ResourceReceiptReplayTest do
  use ExUnit.Case, async: true

  alias Loopex.Bounds
  alias Loopex.Model
  alias Loopex.Runtime.SessionState
  alias Loopex.Store
  alias LoopexProtocol.Canonical

  @digest String.duplicate("a", 64)

  test "resource preflight is pure and the distinct record replays exact staged bytes" do
    fixture = resource_history()
    receipt = resource_receipt(fixture)

    assert {:ok, fixed} =
             SessionState.preflight_model_request(fixture.state, fixture.run_id, fixture.request,
               context_receipt: receipt
             )

    assert fixed.kind == "model_request_committed_resources_v1"
    assert fixed["context_receipt"]["provider_revision"] == 3
    assert fixed["context_receipt"]["record_byte_cost"] > 0
    assert {:ok, ^fixed, bytes} = Store.normalize_and_measure_item(:record, fixed)
    assert fixed["context_receipt"]["record_byte_cost"] == bytes
    assert fixture.state.pending_work[fixture.run_id].stage == "model_pending"

    assert {:ok, proposal} =
             SessionState.propose_model_request(fixture.state, fixture.run_id, fixture.request,
               context_receipt: receipt
             )

    assert Enum.map(proposal.records, & &1.kind) == [
             "model_request_committed_resources_v1",
             "model_attempt_opened_v1"
           ]

    {state, records, events} = append_proposal(fixture, proposal)
    assert state.pending_work[fixture.run_id].stage == "model_attempt_open"
    assert {:ok, recovered} = SessionState.recover(fixture.session_id, records, events)
    assert recovered.pending_work[fixture.run_id].request.messages == fixture.request.messages
  end

  test "replay rejects changed selection identity, row order, content, and open receipt shapes" do
    fixture = resource_history()
    receipt = resource_receipt(fixture)

    {:ok, proposal} =
      SessionState.propose_model_request(fixture.state, fixture.run_id, fixture.request,
        context_receipt: receipt
      )

    {_state, records, events} = append_proposal(fixture, proposal)

    mutations = [
      fn payload ->
        put_in(payload, ["context_receipt", "resource_packs", "selection_digest"], @digest)
      end,
      fn payload ->
        update_in(payload, ["context_receipt", "resource_packs", "blocks"], fn [first | rest] ->
          [first | Enum.reverse(rest)]
        end)
      end,
      fn payload -> put_in(payload, ["context_receipt", "resource_packs", "extra"], true) end,
      fn payload ->
        payload
        |> put_in(["context_receipt", "resource_packs", "status"], "no_decision")
        |> put_in(["context_receipt", "resource_packs", "blocks"], [])
      end,
      fn payload ->
        request = decode_request(payload["request"])
        changed = put_in(request, [:messages, Access.at(2), "content"], "changed instruction")
        {:ok, changed} = restage(changed)

        payload
        |> Map.put("request", plain(changed))
        |> Map.put("staged_request_digest", changed.staged_request_digest)
      end
    ]

    Enum.each(mutations, fn mutate ->
      malformed = mutate_resource_record(records, mutate)
      assert {:error, _reason} = SessionState.recover(fixture.session_id, malformed, events)
    end)
  end

  test "final replay rejects provisional rows, more than 37 rows, and an oversized header" do
    fixture = resource_history()
    receipt = resource_receipt(fixture)

    {:ok, proposal} =
      SessionState.propose_model_request(fixture.state, fixture.run_id, fixture.request,
        context_receipt: receipt
      )

    {_state, records, events} = append_proposal(fixture, proposal)
    row = %{"pack" => 0, "file" => 0, "status" => "not_evaluated"}

    mutations = [
      fn payload ->
        payload
        |> put_in(["context_receipt", "resource_packs", "status"], "evaluated")
        |> put_in(["context_receipt", "resource_packs", "blocks"], [row])
      end,
      fn payload ->
        put_in(payload, ["context_receipt", "resource_packs", "blocks"], List.duplicate(row, 38))
      end,
      fn payload ->
        huge_index = :binary.decode_unsigned(:binary.copy(<<255>>, 9_000))

        put_in(
          payload,
          ["context_receipt", "resource_packs", "blocks"],
          [%{"pack" => huge_index, "file" => 0, "status" => "staged"}]
        )
      end
    ]

    Enum.each(mutations, fn mutate ->
      assert {:error, _reason} =
               SessionState.recover(
                 fixture.session_id,
                 mutate_resource_record(records, mutate),
                 events
               )
    end)
  end

  test "replay enforces the supporting size and 16 KiB class without narrowing instructions" do
    oversized_support = resource_history(support: String.duplicate("s", 16_385))
    oversized_receipt = resource_receipt(oversized_support)

    assert {:ok, fixed} =
             SessionState.preflight_model_request(
               oversized_support.state,
               oversized_support.run_id,
               oversized_support.request,
               context_receipt: oversized_receipt
             )

    assert {:error, :invalid_model_request_transition} =
             SessionState.propose_model_request(
               oversized_support.state,
               oversized_support.run_id,
               oversized_support.request,
               context_receipt: oversized_receipt
             )

    baseline = resource_history()
    baseline_receipt = resource_receipt(baseline)

    {:ok, baseline_proposal} =
      SessionState.propose_model_request(baseline.state, baseline.run_id, baseline.request,
        context_receipt: baseline_receipt
      )

    [_request, opened] = baseline_proposal.records

    opened =
      Map.put(opened, "staged_request_digest", oversized_support.request.staged_request_digest)

    {forged_records, forged_events} =
      stamp_records(oversized_support, [fixed, opened], baseline_proposal.events)

    assert {:error, _reason} =
             SessionState.recover(
               oversized_support.session_id,
               forged_records,
               forged_events
             )

    wrong_size = resource_history(support_size: 1)

    assert {:error, :invalid_model_request_transition} =
             SessionState.propose_model_request(
               wrong_size.state,
               wrong_size.run_id,
               wrong_size.request,
               context_receipt: resource_receipt(wrong_size)
             )

    long_instruction = resource_history(instruction: String.duplicate("i", 16_385))

    assert {:ok, proposal} =
             SessionState.propose_model_request(
               long_instruction.state,
               long_instruction.run_id,
               long_instruction.request,
               context_receipt: resource_receipt(long_instruction)
             )

    {_state, records, events} = append_proposal(long_instruction, proposal)
    assert {:ok, _recovered} = SessionState.recover(long_instruction.session_id, records, events)
  end

  defp resource_history(options \\ []) do
    session_id = "resource-replay"
    incarnation = "owner-one"

    records = [
      %{
        journal_version: 1,
        owner_epoch: 0,
        owner_incarnation_id: nil,
        payload: %{
          "options" => %{},
          "runtime_configuration" => %{"cleanup_grace_ms" => 1_000},
          kind: "session_genesis_v2"
        }
      },
      %{
        journal_version: 2,
        owner_epoch: 1,
        owner_incarnation_id: incarnation,
        payload: %{
          "prior_owner_epoch" => 0,
          "owner_epoch" => 1,
          "owner_incarnation_id" => incarnation,
          "owner_transaction_id" => "owner-tx",
          kind: "owner_advanced"
        }
      }
    ]

    {:ok, state} = SessionState.recover(session_id, records, [])

    decision = %{
      "manifest_digest" => @digest,
      "workspace_ref" => "workspace-ref",
      "trust_scope" => "project_skills",
      "decision_source" => "host_supplied",
      "issued_at" => "2026-09-10T00:00:00Z",
      "expires_at" => nil,
      "revocation_state" => "active"
    }

    admit = %{
      type: :admit_resources,
      command_id: "admit",
      manifest_digest: @digest,
      decision: decision
    }

    {:ok, proposal} =
      SessionState.propose_resource_command(
        state,
        admit,
        {:accepted, %{"workspace_ref" => "workspace-ref", "manifest_digest" => @digest}}
      )

    {state, records, events} =
      append_proposal(%{state: state, records: records, events: []}, proposal)

    instruction = Keyword.get(options, :instruction, "Use the exact retained instruction.")
    support = Keyword.get(options, :support, "Supporting context.")
    support_size = Keyword.get(options, :support_size, byte_size(support))

    activate = %{
      type: :activate_skill,
      command_id: "activate",
      manifest_digest: @digest,
      source_id: "fixture/source",
      name: "fixture-skill",
      pack_digest: String.duplicate("b", 64),
      supporting_labels: ["reference.txt"]
    }

    resolution = %{
      "pack_index" => 0,
      "instruction_file_index" => 0,
      "instruction_digest" => Canonical.digest_bytes(instruction),
      "supporting_files" => [
        %{
          "file_index" => 1,
          "digest" => Canonical.digest_bytes(support),
          "size" => support_size
        }
      ]
    }

    {:ok, proposal} =
      SessionState.propose_resource_command(state, activate, {:accepted, resolution})

    {state, records, events} =
      append_proposal(%{state: state, records: records, events: events}, proposal)

    {:ok, prompt} =
      SessionState.propose(
        state,
        %{type: :prompt, command_id: "prompt", content: "operator prompt"},
        %{max_turns: 2, token_budget: 100, deadline_ms: 30_000, context_token_budget: 8_192}
      )

    {state, records, events} =
      append_proposal(%{state: state, records: records, events: events}, prompt)

    run_id = state.active_run_id

    catalog =
      "Available project skills\n\nName: fixture-skill\nSource: fixture/source\n" <>
        "Description: Fixture skill\nPack digest: #{String.duplicate("b", 64)}\nManual only: true\n"

    messages = [
      %{"role" => "system", "content" => "system"},
      %{"role" => "user", "content" => catalog},
      %{"role" => "user", "content" => instruction},
      %{"role" => "user", "content" => support},
      %{"role" => "user", "content" => "operator prompt"}
    ]

    {:ok, request} =
      Model.request("fixture:model", messages,
        tools: [],
        sampling: %{"max_tokens" => 1},
        deadline: 1
      )

    %{
      state: state,
      records: records,
      events: events,
      session_id: session_id,
      run_id: run_id,
      request: request,
      catalog: catalog,
      instruction: instruction,
      support: support
    }
  end

  defp resource_receipt(fixture) do
    resources = fixture.state.run_resources[fixture.run_id]

    resource_rows = [
      %{"pack" => 64, "file" => 64, "status" => "staged"},
      %{"pack" => 0, "file" => 0, "status" => "staged"},
      %{"pack" => 0, "file" => 1, "status" => "staged"}
    ]

    sources = [
      source(%{"kind" => "system", "identity" => "loopex.system.v1"}, "system"),
      resource_source(resources, 64, 64, Canonical.digest_bytes(fixture.catalog)),
      resource_source(resources, 0, 0, Canonical.digest_bytes(fixture.instruction)),
      resource_source(resources, 0, 1, Canonical.digest_bytes(fixture.support)),
      source(
        %{"kind" => "session_command", "run_id" => fixture.run_id, "command_id" => "prompt"},
        "session"
      )
    ]

    blocks =
      Enum.zip(fixture.request.messages, sources)
      |> Enum.map(fn {message, source} ->
        bytes = Canonical.encode(message)

        Map.merge(source, %{
          "content_digest" => Canonical.digest_bytes(bytes),
          "byte_cost" => byte_size(bytes),
          "token_cost" => Bounds.estimate(bytes)
        })
      end)

    totals = totals(blocks)

    %{
      "provider_identity" => "loopex.context.reference",
      "provider_revision" => 3,
      "transformer_identity" => nil,
      "transformer_revision" => nil,
      "selector_identity" => nil,
      "selector_revision" => nil,
      "token_estimator" => Bounds.estimator(),
      "descriptor_canonicalization_version" => Canonical.version(),
      "blocks" => blocks,
      "totals" => totals,
      "project_resource" => %{
        "class" => "project_resource",
        "receipt_revision" => 2,
        "disposition" => "no_manifest",
        "detail" => %{}
      },
      "resource_packs" => %{
        "version" => 1,
        "manifest_digest" => resources["manifest_digest"],
        "selection_digest" => SessionState.resource_selection_digest(resources),
        "status" => "evaluated",
        "blocks" => resource_rows
      },
      "context_token_budget" => 8_192,
      "provider_estimated_tokens" => totals["token_cost"],
      "context_record_byte_ceiling" => Store.max_item_bytes(),
      "record_byte_cost" => 0,
      "ordered_descriptor_digest" => descriptor_digest(blocks)
    }
  end

  defp source(reference, provenance) do
    trust =
      if provenance == "system",
        do: "host_owned_trusted_brain_content",
        else:
          if(provenance == "session",
            do: "session_owned_durable_truth",
            else: "untrusted_behavior_shaping_data"
          )

    %{"source_reference" => reference, "provenance_class" => provenance, "trust_class" => trust}
  end

  defp resource_source(resources, pack, file, digest) do
    source(
      %{
        "kind" => "resource_pack",
        "manifest_digest" => resources["manifest_digest"],
        "pack" => pack,
        "file" => file,
        "file_digest" => digest
      },
      "resource_pack"
    )
  end

  defp totals(blocks) do
    sum =
      &Enum.reduce(&1, %{"byte_cost" => 0, "token_cost" => 0}, fn block, acc ->
        %{
          "byte_cost" => acc["byte_cost"] + block["byte_cost"],
          "token_cost" => acc["token_cost"] + block["token_cost"]
        }
      end)

    Map.put(
      sum.(blocks),
      "by_provenance",
      Map.new(~w(system session project_resource resource_pack), fn provenance ->
        {provenance, sum.(Enum.filter(blocks, &(&1["provenance_class"] == provenance)))}
      end)
    )
  end

  defp descriptor_digest(blocks) do
    blocks
    |> Enum.reduce(
      :crypto.hash_update(:crypto.hash_init(:sha256), "loopex.context.descriptors.v1" <> <<0>>),
      fn block, context ->
        bytes = Canonical.encode(block)

        context
        |> :crypto.hash_update(<<byte_size(bytes)::unsigned-big-integer-size(64)>>)
        |> :crypto.hash_update(bytes)
      end
    )
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  defp append_proposal(fixture, proposal) do
    first_version = fixture.state.journal_version + 1

    records =
      Enum.with_index(proposal.records, first_version)
      |> Enum.map(fn {payload, version} ->
        %{
          journal_version: version,
          owner_epoch: fixture.state.owner_epoch,
          owner_incarnation_id: fixture.state.owner_incarnation_id,
          payload: payload
        }
      end)

    first_event = fixture.state.event_sequence + 1

    events =
      Enum.with_index(proposal.events, first_event)
      |> Enum.map(fn {event, sequence} -> Map.put(event, :event_sequence, sequence) end)

    receipt = %{
      journal_versions: %{first: first_version, last: first_version + length(records) - 1},
      event_sequences:
        if(events == [],
          do: nil,
          else: %{first: first_event, last: first_event + length(events) - 1}
        )
    }

    {:ok, state} = SessionState.commit_proposal(proposal, receipt)
    {state, fixture.records ++ records, fixture.events ++ events}
  end

  defp stamp_records(fixture, payloads, proposed_events) do
    first_version = fixture.state.journal_version + 1

    records =
      payloads
      |> Enum.with_index(first_version)
      |> Enum.map(fn {payload, version} ->
        %{
          journal_version: version,
          owner_epoch: fixture.state.owner_epoch,
          owner_incarnation_id: fixture.state.owner_incarnation_id,
          payload: payload
        }
      end)

    first_event = fixture.state.event_sequence + 1

    events =
      proposed_events
      |> Enum.with_index(first_event)
      |> Enum.map(fn {event, sequence} -> Map.put(event, :event_sequence, sequence) end)

    {fixture.records ++ records, fixture.events ++ events}
  end

  defp mutate_resource_record(records, mutate) do
    Enum.map(records, fn record ->
      if record.payload[:kind] == "model_request_committed_resources_v1",
        do: %{record | payload: mutate.(record.payload)},
        else: record
    end)
  end

  defp restage(request) do
    Model.request(request.model, request.messages,
      tools: request.tools,
      sampling: request.sampling,
      deadline: request.deadline
    )
  end

  defp decode_request(encoded) do
    Map.new(encoded, fn {key, value} -> {String.to_existing_atom(key), value} end)
  end

  defp plain(value) when value in [nil, true, false], do: value
  defp plain(value) when is_atom(value), do: Atom.to_string(value)
  defp plain(value) when is_binary(value) or is_number(value), do: value
  defp plain(value) when is_list(value), do: Enum.map(value, &plain/1)

  defp plain(value) when is_map(value),
    do: Map.new(value, fn {key, item} -> {plain(key), plain(item)} end)
end
