defmodule Loopex.Executor.Local.RestoreCodec do
  @moduledoc """
  ## Concept

  The private current-format physical restore grammar shared by the Local edge
  and its composing host. Valid bytes describe retained evidence, not authority.

  ## Technical depth

  ADR 0051 fixes closed string-key records, deterministic uncompressed ETF and
  independent whole-record ceilings. This module performs no filesystem IO,
  creates no generation and imports no host implementation. Physical history,
  placement and old-authority validation remain the administrative caller's work.
  """

  @u64 18_446_744_073_709_551_615
  @epoch_max 115_792_089_237_316_195_423_570_985_008_687_907_853_269_984_665_640_564_039_457_584_007_913_129_639_935
  @phases ~w(claim inventory baseline_copy destination_intent source_retirement destination_generations destination_proofs claim_release complete)
  @reasons ~w(none deadline caller_lost io_error readback_mismatch fsync_unconfirmed worker_unjoined descriptor_unclosed authority_unconfirmed history_invalid claim_release_unconfirmed)
  @refusals ~w(invalid_plan invalid_placement restore_conflict authority_unconfirmed destination_not_empty inventory_unavailable inventory_limit_exceeded inventory_mismatch invalid_current_history source_changed)
  @lookup_codes ~w(invalid_query administrative_path_unavailable restore_history_invalid restore_conflict physical_destination_changed inventory_limit_exceeded deadline cleanup_unconfirmed)

  @schemas %{
    placement: [{"expanded_root", :absolute}, {"major_device", :u64}, {"inode", :u64}],
    ledger_descriptor: [
      {"relative_root", :relative},
      {"executor_identity", :label},
      {"source_generation_sha256", :hex},
      {"source_placement", :placement}
    ],
    store_descriptor: [{"relative_path", :relative}, {"sha256", :hex}],
    workspace: [{"root", :absolute}, {"workspace_ref", :workspace_ref}],
    attestation: [
      {"latest_cut", {:literal, true}},
      {"no_post_cut_activity", {:literal, true}},
      {"all_other_copies_excluded", {:literal, true}},
      {"old_authority_termination", {:enum, ~w(joined host_rebooted)}},
      {"host_ledgers_validated", {:literal, true}},
      {"evidence_sha256", :hex}
    ],
    plan: [
      {"version", {:literal, 1}},
      {"tx_id", :hex},
      {"source_state_root", :absolute},
      {"source_state_placement", :placement},
      {"source_status", {:enum, ~w(available lost)}},
      {"backup_state_root", :absolute},
      {"destination_state_root", :absolute},
      {"manifest_sha256", :hex},
      {"cut_id", :hex},
      {"prior_restore_count", {:range, 0, 64}},
      {"prior_lineage_sha256", :hex},
      {"runtime_ids", {:sorted, :runtime_id, 256, nil}},
      {"stores", {:sorted, :store_descriptor, 1024, "relative_path"}},
      {"ledgers", {:sorted, :ledger_descriptor, 128, "relative_root"}},
      {"workspace", :workspace},
      {"host_attestation", :attestation}
    ],
    invocation: [
      {"work_ms", :positive},
      {"cleanup_grace_ms", :positive},
      {"max_total_file_bytes", :u64},
      {"prior_admin_authority", {:enum, ~w(none joined host_rebooted)}},
      {"prior_admin_evidence_sha256", {:nullable, :hex}}
    ],
    limits: [{"work_ms", :positive}, {"cleanup_grace_ms", :positive}],
    entry: [
      {"path", :manifest_path},
      {"kind", {:enum, ~w(directory regular)}},
      {"mode", {:range, 0, 4095}},
      {"size", :u64},
      {"sha256", {:nullable, :hex}}
    ],
    candidate: [
      {"relative_root", :relative},
      {"executor_identity", :label},
      {"source_generation_bytes", :generation_bytes},
      {"destination_generation_bytes", :generation_bytes},
      {"source_ledger_binding", :hex},
      {"destination_ledger_placement", :placement},
      {"destination_ledger_binding", :hex}
    ],
    intent: [
      {"kind", {:literal, "loopex_current_restore_intent_v1"}},
      {"ordinal", :ordinal},
      {"tx_id", :hex},
      {"plan_digest", :hex},
      {"plan", :plan},
      {"prior_lineage_sha256", :hex},
      {"source_state_binding", :hex},
      {"destination_state_placement", :placement},
      {"destination_state_binding", :hex},
      {"generations", {:sorted, :candidate, 128, "relative_root"}}
    ],
    ledger_intent: [
      {"kind", {:literal, "loopex_current_restore_ledger_intent_v1"}},
      {"ordinal", :ordinal},
      {"tx_id", :hex},
      {"intent_sha256", :hex},
      {"relative_root", :relative},
      {"source_state_binding", :hex},
      {"destination_state_binding", :hex},
      {"source_generation_sha256", :hex},
      {"destination_generation_sha256", :hex},
      {"source_ledger_binding", :hex},
      {"destination_ledger_binding", :hex}
    ],
    ledger_retired: [
      {"kind", {:literal, "loopex_current_restore_ledger_retired_v1"}},
      {"ordinal", :ordinal},
      {"tx_id", :hex},
      {"intent_sha256", :hex},
      {"ledger_intent_sha256", :hex},
      {"relative_root", :relative},
      {"source_state_binding", :hex},
      {"source_ledger_binding", :hex},
      {"source_generation_sha256", :hex},
      {"destination_state_binding", :hex},
      {"destination_generation_sha256", :hex}
    ],
    retirement_entry: [{"relative_root", :relative}, {"record_sha256", {:nullable, :hex}}],
    source_retirement: [
      {"kind", {:literal, "loopex_current_restore_source_retirement_v1"}},
      {"ordinal", :ordinal},
      {"tx_id", :hex},
      {"intent_sha256", :hex},
      {"disposition", {:enum, ~w(source_retired lost_source_host_excluded)}},
      {"source_state_binding", :hex},
      {"destination_state_binding", :hex},
      {"host_evidence_sha256", :hex},
      {"ledger_retirements", {:sorted, :retirement_entry, 128, "relative_root"}}
    ],
    ledger_committed: [
      {"kind", {:literal, "loopex_current_restore_ledger_committed_v1"}},
      {"ordinal", :ordinal},
      {"tx_id", :hex},
      {"intent_sha256", :hex},
      {"relative_root", :relative},
      {"ledger_intent_sha256", :hex},
      {"source_retirement_sha256", :hex},
      {"destination_state_binding", :hex},
      {"destination_ledger_binding", :hex},
      {"destination_generation_sha256", :hex}
    ],
    proof_entry: [{"relative_root", :relative}, {"record_sha256", :hex}],
    committed: [
      {"kind", {:literal, "loopex_current_restore_committed_v1"}},
      {"ordinal", :ordinal},
      {"tx_id", :hex},
      {"intent_sha256", :hex},
      {"plan_digest", :hex},
      {"prior_lineage_sha256", :hex},
      {"baseline_manifest_sha256", :hex},
      {"activation_manifest_sha256", :hex},
      {"source_retirement_sha256", :hex},
      {"destination_state_binding", :hex},
      {"ledger_proofs", {:sorted, :proof_entry, 128, "relative_root"}}
    ],
    claim: [
      {"kind", {:literal, "loopex_current_restore_claim_v1"}},
      {"tx_id", :hex},
      {"plan_digest", :hex},
      {"claim_nonce", :hex},
      {"state_root", :absolute},
      {"role", {:enum, ~w(source destination)}}
    ],
    receipt: [
      {"kind", {:literal, "loopex_current_restore_receipt_v1"}},
      {"tx_id", :hex},
      {"ordinal", :ordinal},
      {"plan_digest", :hex},
      {"intent_sha256", :hex},
      {"committed_sha256", :hex},
      {"source_retirement_sha256", :hex},
      {"baseline_manifest_sha256", :hex},
      {"activation_manifest_sha256", :hex},
      {"prior_lineage_sha256", :hex},
      {"destination_state_binding", :hex},
      {"ledger_count", {:range, 0, 128}}
    ],
    observation: [
      {"kind", {:literal, "loopex_current_restore_observation_v1"}},
      {"tx_id", :hex},
      {"ordinal", {:nullable, :ordinal}},
      {"phase", {:enum, @phases}},
      {"intent", {:enum, ~w(absent may_exist validated)}},
      {"cleanup", {:enum, ~w(joined unconfirmed)}},
      {"claim", {:enum, ~w(none held retained)}},
      {"reason", {:enum, @reasons}}
    ],
    refusal: [
      {"kind", {:literal, "loopex_current_restore_refusal_v1"}},
      {"tx_id", {:nullable, :hex}},
      {"code", {:enum, @refusals}},
      {"phase", {:enum, @phases}},
      {"cleanup", {:literal, "joined"}},
      {"claim", {:enum, ~w(none retained)}}
    ],
    lookup_refusal: [
      {"kind", {:literal, "loopex_current_restore_lookup_refusal_v1"}},
      {"tx_id", {:nullable, :hex}},
      {"code", {:enum, @lookup_codes}},
      {"cleanup", {:enum, ~w(joined unconfirmed)}}
    ]
  }

  @doc false
  def encode(type, value) do
    if valid?(type, value) do
      bytes = canonical(value)
      if byte_size(bytes) <= ceiling(type), do: {:ok, bytes}, else: :error
    else
      :error
    end
  rescue
    ArgumentError -> :error
  end

  @doc false
  def decode(type, bytes) when is_binary(bytes) do
    with true <- byte_size(bytes) <= ceiling(type),
         <<131, tag, _::binary>> when tag != 80 <- bytes,
         value <- :erlang.binary_to_term(bytes, [:safe]),
         {:ok, ^bytes} <- encode(type, value) do
      {:ok, value}
    else
      _ -> :error
    end
  rescue
    ArgumentError -> :error
  end

  def decode(_type, _bytes), do: :error

  @doc false
  def plan_digest(plan) do
    with {:ok, bytes} <- encode(:plan, plan),
         do: {:ok, digest("loopex:current-restore-plan:v1", bytes)}
  end

  @doc false
  def state_binding(placement), do: binding(placement, "loopex:current-state-root-binding:v1")

  @doc false
  def ledger_binding(placement), do: binding(placement, "loopex:local-root-binding:v1")

  @doc false
  def claim_digest(path) do
    if valid?(:absolute, path),
      do:
        {:ok,
         digest(
           "loopex:current-restore-claim:v1",
           <<byte_size(path)::unsigned-64-big, path::binary>>
         )},
      else: :error
  end

  @doc false
  def lineage_digest(entries) do
    if sorted?(:entry, entries, 65_536, "path") and Enum.all?(entries, &lineage_entry?/1),
      do: {:ok, digest("loopex:current-restore-lineage:v1", canonical(entries))},
      else: :error
  end

  @doc false
  def manifest(bytes, max_total_file_bytes) do
    with true <- valid?(:u64, max_total_file_bytes),
         {:ok, [_, entries]} <- decode(:manifest, bytes),
         true <- Enum.reduce(entries, 0, &(&1["size"] + &2)) <= max_total_file_bytes do
      {:ok, entries}
    else
      _ -> :error
    end
  end

  @doc false
  def eligible_plan(plan) do
    with {:ok, _bytes} <- encode(:plan, plan),
         true <- plan["prior_restore_count"] < 64 do
      :ok
    else
      _ -> :error
    end
  end

  @doc false
  def limits(limits) do
    with {:ok, _bytes} <- encode(:limits, limits),
         work = limits["work_ms"],
         grace = limits["cleanup_grace_ms"],
         cleanup = max(10_000, grace + 2_000),
         true <- work + cleanup <= @u64,
         native <- System.convert_time_unit(work + cleanup, :millisecond, :native),
         true <- native <= 9_223_372_036_854_775_807,
         start <- System.monotonic_time(),
         true <- start + native <= 9_223_372_036_854_775_807 do
      {:ok, %{work_ms: work, cleanup_grace_ms: grace, cleanup_window_ms: cleanup}}
    else
      _ -> :error
    end
  end

  @doc false
  def digest_bytes(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  defp ceiling(:manifest), do: 4_194_304
  defp ceiling(:generation), do: 2_048
  defp ceiling(:limits), do: 512

  defp ceiling(type)
       when type in [:invocation, :claim, :receipt, :observation, :refusal, :lookup_refusal],
       do: 2_048

  defp ceiling(_type), do: 65_536
  defp canonical(value), do: :erlang.term_to_binary(value, [:deterministic])
  defp digest(domain, bytes), do: digest_bytes(<<domain::binary, 0, bytes::binary>>)

  defp binding(placement, domain) do
    if valid?(:placement, placement) do
      path = placement["expanded_root"]

      {:ok,
       digest(
         domain,
         <<byte_size(path)::unsigned-64-big, path::binary,
           placement["major_device"]::unsigned-64-big, placement["inode"]::unsigned-64-big>>
       )}
    else
      :error
    end
  end

  defp valid?({:literal, wanted}, value), do: value === wanted
  defp valid?({:enum, choices}, value), do: value in choices

  defp valid?({:range, low, high}, value),
    do: is_integer(value) and value >= low and value <= high

  defp valid?({:nullable, _type}, nil), do: true
  defp valid?({:nullable, type}, value), do: valid?(type, value)
  defp valid?({:sorted, type, bound, key}, value), do: sorted?(type, value, bound, key)
  defp valid?(:u64, value), do: valid?({:range, 0, @u64}, value)
  defp valid?(:positive, value), do: valid?({:range, 1, @u64}, value)
  defp valid?(:ordinal, value), do: valid?({:range, 1, 64}, value)
  defp valid?(:runtime_id, value), do: text?(value, 256)
  defp valid?(:label, value), do: text?(value, 8_192)

  defp valid?(:hex, value),
    do:
      is_binary(value) and byte_size(value) == 64 and
        match?({:ok, _}, Base.decode16(value, case: :lower))

  # Concept: restore captures the current host identity, not an arbitrary Core label.
  # Technical depth: ADR 0049 binds the existing WorkspaceIdentity representation;
  # only composition observes and compares its physical hash preimage twice.
  defp valid?(:workspace_ref, <<"workspace:", hex::binary>>), do: valid?(:hex, hex)
  defp valid?(:workspace_ref, _value), do: false

  defp valid?(:absolute, value),
    do:
      text?(value, 8_192) and not String.contains?(value, <<0>>) and Path.type(value) == :absolute and
        Path.expand(value) == value

  defp valid?(:relative, value),
    do:
      text?(value, 8_192) and not String.contains?(value, <<0>>) and Path.type(value) == :relative and
        Enum.all?(String.split(value, "/"), &(&1 not in ["", ".", ".."]))

  defp valid?(:manifest_path, "."), do: true
  defp valid?(:manifest_path, value), do: valid?(:relative, value)
  defp valid?(:generation_bytes, value), do: match?({:ok, _}, decode(:generation, value))

  defp valid?(:generation, value) when is_map(value) do
    keys = [:ledger_kind, "executor_epoch", "executor_identity", "generation_id", "root_binding"]
    epoch = value["executor_epoch"]

    exact?(value, keys) and value[:ledger_kind] == "local_executor_generation_v1" and
      is_binary(value["executor_identity"]) and value["executor_identity"] != "" and
      is_integer(epoch) and epoch > 0 and epoch <= @epoch_max and
      value["generation_id"] == Base.encode16(<<epoch::unsigned-256>>, case: :lower) and
      valid?(:hex, value["root_binding"])
  end

  defp valid?(:generation, _value), do: false

  defp valid?(:manifest, ["loopex:current-state-manifest:v1", entries]) do
    sorted?(:entry, entries, 65_536, "path") and manifest_tree?(entries)
  end

  defp valid?(:manifest, _value), do: false

  defp valid?(type, value) when is_atom(type) and is_map(value) do
    case Map.fetch(@schemas, type) do
      {:ok, fields} ->
        exact?(value, Enum.map(fields, &elem(&1, 0))) and
          Enum.all?(fields, fn {key, domain} -> valid?(domain, value[key]) end) and
          relations?(type, value)

      :error ->
        false
    end
  end

  defp valid?(_type, _value), do: false

  defp exact?(value, keys),
    do:
      not is_struct(value) and map_size(value) == length(keys) and
        Enum.all?(keys, &Map.has_key?(value, &1))

  defp text?(value, bound),
    do: is_binary(value) and byte_size(value) in 1..bound and String.valid?(value)

  defp sorted?(type, values, bound, key) when is_list(values) do
    length(values) <= bound and Enum.all?(values, &valid?(type, &1)) and
      values |> Enum.map(fn value -> if key, do: value[key], else: value end) |> increasing?()
  end

  defp sorted?(_type, _values, _bound, _key), do: false
  defp increasing?([]), do: true
  defp increasing?([_]), do: true
  defp increasing?([a, b | tail]), do: a < b and increasing?([b | tail])

  defp relations?(:plan, plan) do
    roots = [
      plan["source_state_root"],
      plan["backup_state_root"],
      plan["destination_state_root"],
      plan["workspace"]["root"]
    ]

    plan["source_state_placement"]["expanded_root"] == plan["source_state_root"] and
      independent_roots?(roots) and
      Enum.all?(
        plan["ledgers"],
        &(&1["source_placement"]["expanded_root"] ==
            Path.join(plan["source_state_root"], &1["relative_root"]))
      ) and
      (plan["prior_restore_count"] != 0 or
         plan["prior_lineage_sha256"] ==
           digest("loopex:current-restore-lineage:v1", canonical([])))
  end

  defp relations?(:invocation, value),
    do:
      value["prior_admin_authority"] == "none" == is_nil(value["prior_admin_evidence_sha256"]) and
        match?({:ok, _}, limits(Map.take(value, ["work_ms", "cleanup_grace_ms"])))

  defp relations?(:limits, _value), do: true

  defp relations?(:entry, %{"kind" => "directory"} = value),
    do: value["size"] == 0 and is_nil(value["sha256"])

  defp relations?(:entry, value), do: valid?(:hex, value["sha256"])

  defp relations?(:intent, value) do
    plan = value["plan"]
    candidates = value["generations"]

    with {:ok, plan_digest} <- plan_digest(plan),
         {:ok, source_binding} <- state_binding(plan["source_state_placement"]),
         {:ok, destination_binding} <- state_binding(value["destination_state_placement"]) do
      value["ordinal"] == plan["prior_restore_count"] + 1 and value["tx_id"] == plan["tx_id"] and
        value["plan_digest"] == plan_digest and
        value["prior_lineage_sha256"] == plan["prior_lineage_sha256"] and
        value["source_state_binding"] == source_binding and
        value["destination_state_binding"] == destination_binding and
        value["destination_state_placement"]["expanded_root"] == plan["destination_state_root"] and
        length(candidates) == length(plan["ledgers"]) and
        Enum.all?(Enum.zip(candidates, plan["ledgers"]), fn {candidate, descriptor} ->
          candidate_matches?(candidate, descriptor, plan)
        end) and distinct_candidate_epochs?(candidates)
    else
      _ -> false
    end
  end

  defp relations?(:candidate, value) do
    {:ok, source} = decode(:generation, value["source_generation_bytes"])
    {:ok, destination} = decode(:generation, value["destination_generation_bytes"])
    {:ok, binding} = ledger_binding(value["destination_ledger_placement"])

    source["executor_identity"] == value["executor_identity"] and
      destination["executor_identity"] == value["executor_identity"] and
      source["root_binding"] == value["source_ledger_binding"] and
      destination["root_binding"] == value["destination_ledger_binding"] and
      binding == value["destination_ledger_binding"] and
      source["executor_epoch"] != destination["executor_epoch"]
  end

  defp relations?(:source_retirement, value),
    do:
      Enum.all?(
        value["ledger_retirements"],
        &(value["disposition"] == "lost_source_host_excluded" == is_nil(&1["record_sha256"]))
      )

  defp relations?(_type, _value), do: true

  defp candidate_matches?(candidate, descriptor, plan) do
    {:ok, binding} = ledger_binding(descriptor["source_placement"])

    candidate["relative_root"] == descriptor["relative_root"] and
      candidate["executor_identity"] == descriptor["executor_identity"] and
      digest_bytes(candidate["source_generation_bytes"]) == descriptor["source_generation_sha256"] and
      candidate["source_ledger_binding"] == binding and
      candidate["destination_ledger_placement"]["expanded_root"] ==
        Path.join(plan["destination_state_root"], candidate["relative_root"])
  end

  defp independent_roots?(roots),
    do:
      Enum.all?(roots, fn a ->
        Enum.all?(roots -- [a], fn b ->
          a != b and not String.starts_with?(a, b <> "/") and not String.starts_with?(b, a <> "/") and
            a != "/" and b != "/"
        end)
      end)

  defp manifest_tree?(entries) do
    index = Map.new(entries, &{&1["path"], &1})

    match?(%{"kind" => "directory"}, index["."]) and
      Enum.all?(entries, fn entry ->
        entry["path"] == "." or
          match?(%{"kind" => "directory"}, index[Path.dirname(entry["path"])])
      end)
  end

  defp lineage_entry?(entry),
    do: Enum.any?(Path.split(entry["path"]), &(&1 in [".loopex-restore", "restore-lineage"]))

  defp distinct_candidate_epochs?(candidates) do
    epochs =
      Enum.map(candidates, fn candidate ->
        {:ok, generation} = decode(:generation, candidate["destination_generation_bytes"])
        generation["executor_epoch"]
      end)

    length(Enum.uniq(epochs)) == length(epochs)
  end
end
