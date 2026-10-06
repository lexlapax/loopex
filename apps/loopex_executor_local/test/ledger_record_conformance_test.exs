defmodule Loopex.Executor.Local.LedgerRecordConformanceTest do
  use ExUnit.Case, async: false

  alias Loopex.Executor
  alias Loopex.Executor.Local.Ledger

  @max_uint64 18_446_744_073_709_551_615
  @snapshot_bytes 4_194_304
  @codes ~w(
    cancelled_before_start workspace_lease_not_held workspace_lease_lost
    workspace_lease_mismatch executor_prestart_mismatch invalid_job_request
    canonical_job_request_mismatch tool_definition_mismatch host_policy_allow_required
    invalid_grant invalid_tool_arguments receipt_record_shape_too_large
    effective_deadline_reached effect_start_authority_unavailable missing_binding binding_mismatch
  )
  @fields ~w(
    operation_id attempt canonical_request_digest tool_id tool_version effect_class
    workspace_lease executor_audience expiry fencing_token
  )

  setup do
    root =
      Path.join(System.tmp_dir!(), "loopex-ledger-record-#{System.unique_integer([:positive])}")

    File.mkdir!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    assert {:ok, prepared} = Ledger.prepare(root, "ledger-record-test", 5_000)
    %{root: root, prepared: prepared, job: job()}
  end

  test "captured records reuse actual current writers without retaining a path", context do
    marker = Ledger.marker(context.job)
    open = Ledger.open_entry(context.job, context.job.executor_identity)
    refused_job = job(%{job_id: "captured-refusal", operation_id: "captured-refusal-operation"})
    assert {:ok, refusal} = Ledger.refusal(refused_job, :workspace_lease_lost)

    assert :ok =
             Ledger.with_claim(context.prepared, fn claimed ->
               assert :ok = Ledger.admit(claimed, marker, open)
               Ledger.refuse(claimed, refusal)
             end)

    paths = [
      Path.join(context.root, "generation"),
      marker_path(context.root, context.job.job_id),
      open_path(context.root, context.job.job_id),
      marker_path(context.root, refused_job.job_id)
    ]

    captures =
      Enum.map(paths, fn path ->
        bytes = File.read!(path)
        record = :erlang.binary_to_term(bytes, [:safe])
        {bytes, record}
      end)

    File.rm_rf!(context.root)

    for {bytes, record} <- captures do
      assert {:ok, ^record} = Ledger.decode_bytes(bytes, record.ledger_kind)
      assert bytes == encode(record)
    end

    refute File.exists?(context.root)
  end

  test "captured kind and actual byte ceilings precede complete schema admission", context do
    generation =
      File.read!(Path.join(context.root, "generation")) |> :erlang.binary_to_term([:safe])

    marker = Ledger.marker(context.job)
    open = Ledger.open_entry(context.job, context.job.executor_identity)
    assert {:ok, refusal} = Ledger.refusal(context.job, :workspace_lease_lost)

    for record <- [generation, marker, open, refusal] do
      kind = record.ledger_kind
      ceiling = if kind == "local_executor_generation_v1", do: 2_048, else: 65_536
      canonical = encode(record)
      assert {:ok, ^record} = Ledger.decode_bytes(canonical, kind)
      compressed = :erlang.term_to_binary(record, [:deterministic, :compressed])
      assert <<131, 80, _::binary>> = compressed

      for bytes <- [
            compressed,
            canonical <> <<0>>,
            encode([record]),
            encode(Map.put(record, "extra", true)),
            encode(Map.delete(record, :ledger_kind))
          ] do
        assert {:error, {:ledger_unavailable, :malformed_record}} =
                 Ledger.decode_bytes(bytes, kind)
      end

      oversized = canonical <> :binary.copy(<<0>>, ceiling + 1 - byte_size(canonical))
      assert byte_size(oversized) == ceiling + 1

      assert {:error, {:ledger_unavailable, :record_too_large}} =
               Ledger.decode_bytes(oversized, kind)

      assert {:error, {:ledger_unavailable, :malformed_record}} =
               Ledger.decode_bytes(canonical, "retired")

      assert {:error, {:ledger_unavailable, :malformed_record}} =
               Ledger.decode_bytes(canonical, nil)

      assert {:error, {:ledger_unavailable, :malformed_record}} = Ledger.decode_bytes(nil, kind)

      other_kind =
        if kind == "local_executor_generation_v1",
          do: "local_open_effect_v1",
          else: "local_executor_generation_v1"

      assert {:error, {:ledger_unavailable, :malformed_record}} =
               Ledger.decode_bytes(canonical, other_kind)
    end

    identity = generation["executor_identity"]
    room = 2_048 - byte_size(encode(generation))
    exact = Map.put(generation, "executor_identity", identity <> String.duplicate("x", room))
    assert byte_size(encode(exact)) == 2_048
    assert {:ok, ^exact} = Ledger.decode_bytes(encode(exact), exact.ledger_kind)
    beyond = Map.update!(exact, "executor_identity", &(&1 <> "x"))
    assert byte_size(encode(beyond)) == 2_049

    assert {:error, {:ledger_unavailable, :record_too_large}} =
             Ledger.decode_bytes(encode(beyond), beyond.ledger_kind)
  end

  test "new generations use lowercase fixed-width spelling and reopen without rewriting",
       context do
    path = Path.join(context.root, "generation")
    bytes = File.read!(path)
    record = :erlang.binary_to_term(bytes, [:safe])
    assert record["generation_id"] =~ ~r/\A[0-9a-f]{64}\z/
    assert Integer.parse(record["generation_id"], 16) == {record["executor_epoch"], ""}
    assert {:ok, same} = Ledger.prepare(context.root, "ledger-record-test", 5_000)
    assert same == context.prepared
    assert File.read!(path) == bytes
  end

  test "all retained kinds refuse compression, trailing bytes and non-map roots", context do
    generation_path = Path.join(context.root, "generation")
    generation = generation_path |> File.read!() |> :erlang.binary_to_term([:safe])
    marker = Ledger.marker(context.job)
    open = Ledger.open_entry(context.job, context.job.executor_identity)
    assert {:ok, refusal} = Ledger.refusal(context.job, :workspace_lease_lost)

    cases = [
      {generation_path, generation,
       fn -> Ledger.prepare(context.root, "ledger-record-test", 5_000) end},
      {marker_path(context.root, context.job.job_id), marker,
       fn -> Ledger.read_marker(context.prepared, context.job) end},
      {marker_path(context.root, context.job.job_id), refusal,
       fn -> Ledger.read_marker(context.prepared, context.job) end},
      {open_path(context.root, context.job.job_id), open, fn -> snapshot(context.prepared) end}
    ]

    for {path, record, read} <- cases do
      canonical = encode(record)
      compressed = :erlang.term_to_binary(record, [:deterministic, :compressed])
      assert <<131, 80, _rest::binary>> = compressed
      assert byte_size(compressed) < byte_size(canonical)

      for bytes <- [compressed, canonical <> <<0>>, encode([record])] do
        File.write!(path, bytes)
        assert_unavailable(read.())
        assert File.read!(path) == bytes
      end

      File.write!(path, canonical)
      assert {:ok, _record_or_snapshot} = read.()
      assert File.read!(path) == canonical
    end
  end

  test "compressed and non-map generation bytes never enter the actual term decoder", context do
    path = Path.join(context.root, "generation")
    canonical = File.read!(path)
    record = :erlang.binary_to_term(canonical, [:safe])
    boundary = {:erlang, :binary_to_term, 2}
    assert {:traced, false} = :erlang.trace_info(boundary, :traced)
    deadline = System.monotonic_time(:millisecond) + 5_000
    remaining = fn -> max(deadline - System.monotonic_time(:millisecond), 0) end
    parent = self()

    try do
      assert 1 == :erlang.trace_pattern(boundary, true, [:local])

      for {bytes, expected_calls} <- [
            {canonical, 1},
            {:erlang.term_to_binary(record, [:deterministic, :compressed]), 0},
            {encode([record]), 0}
          ] do
        File.write!(path, bytes)

        {reader, monitor} =
          spawn_monitor(fn ->
            receive do
              :read ->
                result = Ledger.prepare(context.root, "ledger-record-test", 5_000)
                send(parent, {:generation_read, self(), result})

                receive do
                  :finish -> :ok
                after
                  remaining.() -> exit(:observer_deadline)
                end
            after
              remaining.() -> exit(:observer_deadline)
            end
          end)

        try do
          assert 1 == :erlang.trace(reader, true, [:call, :arity])
          send(reader, :read)
          assert_receive {:generation_read, ^reader, result}, remaining.()

          if expected_calls == 1,
            do: assert(match?({:ok, _}, result)),
            else: assert_unavailable(result)

          barrier = :erlang.trace_delivered(reader)
          assert_receive {:trace_delivered, ^reader, ^barrier}, remaining.()

          if expected_calls == 1 do
            assert_receive {:trace, ^reader, :call, ^boundary}, 0
          end

          refute_receive {:trace, ^reader, :call, ^boundary}, 0
          assert File.read!(path) == bytes
          send(reader, :finish)
          assert_receive {:DOWN, ^monitor, :process, ^reader, :normal}, remaining.()
        after
          if Process.alive?(reader) do
            Process.exit(reader, :kill)
            assert_receive {:DOWN, ^monitor, :process, ^reader, _reason}, remaining.()
          end
        end
      end
    after
      :erlang.trace_pattern(boundary, false, [:local])
      File.write!(path, canonical)
    end
  end

  test "generation readers admit independently specified lowercase epoch vectors", context do
    path = Path.join(context.root, "generation")
    original = path |> File.read!() |> :erlang.binary_to_term([:safe])
    maximum = Integer.pow(2, 256) - 1

    for {epoch, spelling} <- [
          {1, String.duplicate("0", 63) <> "1"},
          {10, String.duplicate("0", 63) <> "a"},
          {16, String.duplicate("0", 62) <> "10"},
          {1023, String.duplicate("0", 61) <> "3ff"},
          {maximum, String.duplicate("f", 64)}
        ] do
      record = Map.merge(original, %{"executor_epoch" => epoch, "generation_id" => spelling})
      bytes = encode(record)
      File.write!(path, bytes)
      assert {:ok, prepared} = Ledger.prepare(context.root, "ledger-record-test", 5_000)
      assert prepared.executor_epoch == epoch
      assert prepared.generation_digest == digest(bytes)
      assert File.read!(path) == bytes
    end
  end

  test "invalid generation spellings and epochs refuse without changing retained bytes",
       context do
    path = Path.join(context.root, "generation")
    original = path |> File.read!() |> :erlang.binary_to_term([:safe])

    for {epoch, spelling} <- [
          {10, String.duplicate("0", 63) <> "A"},
          {171, String.duplicate("0", 62) <> "aB"},
          {10, "a"},
          {10, String.duplicate("0", 64) <> "a"},
          {10, String.duplicate("0", 63) <> "g"},
          {10, String.duplicate("0", 63) <> "b"},
          {0, String.duplicate("0", 64)},
          {-1, String.duplicate("f", 64)},
          {Integer.pow(2, 256), String.duplicate("0", 64)},
          {1.0, String.duplicate("0", 63) <> "1"}
        ] do
      bytes =
        encode(Map.merge(original, %{"executor_epoch" => epoch, "generation_id" => spelling}))

      File.write!(path, bytes)
      assert_unavailable(Ledger.prepare(context.root, "ledger-record-test", 5_000))
      assert File.read!(path) == bytes
    end
  end

  # These cases exercise retained-data validation directly. They never pass
  # malformed records to Local.execute/5 or ask an executor to perform an effect.
  test "marker domains refuse before either admission publication and on read", context do
    marker = Ledger.marker(context.job)
    open = Ledger.open_entry(context.job, context.job.executor_identity)

    for {field, invalid} <-
          invalid_attempt_fields() ++
            [
              {"cleanup_grace_ms", 0},
              {"cleanup_grace_ms", @max_uint64 + 1},
              {"admission_nonce", String.duplicate("A", 64)},
              {"admission_nonce", "00"}
            ] do
      record = Map.put(marker, field, invalid)

      assert_unavailable(Ledger.admit(context.prepared, record, open))
      assert_empty_index(context.root)
      write_marker(context.root, context.job.job_id, record)
      assert_unavailable(Ledger.read_marker(context.prepared, context.job.job_id))
      File.rm!(marker_path(context.root, context.job.job_id))
    end

    for invalid <- [nil, [], %{}, Map.put(marker, "extra", 1), Map.delete(marker, "attempt")] do
      assert_unavailable(Ledger.admit(context.prepared, invalid, open))
      assert_empty_index(context.root)
    end
  end

  test "open domains refuse before publication and before snapshot admission", context do
    marker = Ledger.marker(context.job)
    open = Ledger.open_entry(context.job, context.job.executor_identity)

    invalids = [
      {"job_id", ""},
      {"job_id", String.duplicate("j", 8_193)},
      {"canonical_request_digest", String.duplicate("G", 64)},
      {"canonical_request_digest", nil},
      {"executor_identity", ""},
      {"executor_identity", String.duplicate("e", 8_193)},
      {"origin_executor_epoch", -1},
      {"origin_executor_epoch", "0"},
      {"cleanup_grace_ms", 0},
      {"cleanup_grace_ms", @max_uint64 + 1}
    ]

    for {field, invalid} <- invalids do
      record = Map.put(open, field, invalid)
      assert_unavailable(Ledger.admit(context.prepared, marker, record))
      assert_unavailable(restore(context.prepared, record))
      assert_empty_index(context.root)
      path = open_path(context.root, context.job.job_id)
      File.write!(path, encode(record))
      assert_unavailable(snapshot(context.prepared))
      File.rm!(path)
    end

    for invalid <- [nil, [], %{}, Map.put(open, "extra", 1), Map.delete(open, "job_id")] do
      assert_unavailable(Ledger.admit(context.prepared, marker, invalid))
      assert_unavailable(restore(context.prepared, invalid))
      assert_empty_index(context.root)
    end
  end

  test "refusal domains and closed nested reasons are checked by producer and reader", context do
    assert {:ok, refusal} = Ledger.refusal(context.job, :workspace_lease_lost)

    for {field, invalid} <- invalid_attempt_fields() do
      record = Map.put(refusal, field, invalid)
      assert_unavailable(Ledger.refuse(context.prepared, record))
      assert_empty_index(context.root)
      write_marker(context.root, context.job.job_id, record)
      assert_unavailable(Ledger.read_marker(context.prepared, context.job.job_id))
      File.rm!(marker_path(context.root, context.job.job_id))
    end

    for reason <- [
          nil,
          %{},
          %{"code" => "workspace_lease_lost"},
          %{code: "workspace_lease_lost", field: nil},
          %{"code" => "workspace_lease_lost", "field" => nil, "extra" => true},
          %{"code" => "unknown", "field" => nil},
          %{"code" => :workspace_lease_lost, "field" => nil},
          %{"code" => "workspace_lease_lost", "field" => "attempt"},
          %{"code" => "missing_binding", "field" => "not_a_binding"},
          %{"code" => "binding_mismatch", "field" => :attempt}
        ] do
      record = Map.put(refusal, "reason", reason)
      assert_unavailable(Ledger.refuse(context.prepared, record))
      assert_empty_index(context.root)
      write_marker(context.root, context.job.job_id, record)
      assert_unavailable(Ledger.read_marker(context.prepared, context.job.job_id))
      File.rm!(marker_path(context.root, context.job.job_id))
    end

    assert :error = Ledger.refusal(context.job, :missing_binding, :not_a_binding)
    assert :error = Ledger.refusal(context.job, :workspace_lease_lost, :attempt)
    assert :error = Ledger.refusal(context.job, %{}, nil)
    assert :error = Ledger.refusal(%{}, :workspace_lease_lost)

    assert :error =
             Ledger.refusal(%{context.job | attempt: Integer.pow(2, 8 * 65_536)}, :invalid_grant)
  end

  test "all sixteen refusal codes and ten binding names retain exact valid bytes", context do
    assert length(@codes) == 16
    assert length(@fields) == 10

    for code <- @codes,
        field <-
          if(code in ~w(missing_binding binding_mismatch), do: [nil | @fields], else: [nil]) do
      assert {:ok, refusal} = Ledger.refusal(context.job, code, field)
      assert refusal["reason"] == %{"code" => code, "field" => field}

      assert :ok =
               Ledger.with_claim(context.prepared, fn ->
                 Ledger.refuse(context.prepared, refusal)
               end)

      assert {:ok, ^refusal} = Ledger.read_marker(context.prepared, context.job)
      assert File.read!(marker_path(context.root, context.job.job_id)) == encode(refusal)
    end
  end

  test "opaque identifiers and unbounded positive attempts and nonnegative job epochs survive",
       context do
    huge = Integer.pow(2, 300)

    request =
      job(%{
        job_id: <<255>> <> String.duplicate("j", 8_191),
        operation_id: String.duplicate("o", 8_192),
        attempt: huge,
        origin_executor_epoch: huge,
        cleanup_grace_ms: @max_uint64
      })

    marker = Ledger.marker(request)
    open = Ledger.open_entry(request, <<0, 255>> <> String.duplicate("e", 8_190))

    assert :ok =
             Ledger.with_claim(context.prepared, fn ->
               Ledger.admit(context.prepared, marker, open)
             end)

    assert {:ok, ^marker} = Ledger.read_marker(context.prepared, request)
    assert {:ok, [^open]} = snapshot(context.prepared)
    assert :ok = restore(context.prepared, open)

    zero =
      Ledger.open_entry(context.job, context.job.executor_identity)
      |> Map.put("origin_executor_epoch", 0)

    assert :ok = restore(context.prepared, zero)
    assert {:ok, entries} = snapshot(context.prepared)
    assert zero in entries
  end

  test "admission pairs must agree before their first write", context do
    marker = Ledger.marker(context.job)
    open = Ledger.open_entry(context.job, context.job.executor_identity)

    for {field, other} <- [
          {"job_id", "another-job"},
          {"canonical_request_digest", String.duplicate("0", 64)},
          {"cleanup_grace_ms", 1}
        ] do
      assert {:error, {:ledger_unavailable, :admission_record_mismatch}} =
               Ledger.admit(context.prepared, marker, Map.put(open, field, other))

      assert_empty_index(context.root)
    end

    oversized = Map.put(marker, "attempt", Integer.pow(2, 8 * 65_536))
    assert_unavailable(Ledger.admit(context.prepared, oversized, open))
    assert_empty_index(context.root)
  end

  test "a basename and marker lookup must name their decoded job", context do
    open = Ledger.open_entry(context.job, context.job.executor_identity)
    wrong = open_path(context.root, "another-job")
    File.write!(wrong, encode(open))
    assert_unavailable(snapshot(context.prepared))
    File.rm!(wrong)
    assert :ok = restore(context.prepared, open)
    assert {:ok, [^open]} = snapshot(context.prepared)

    marker = Ledger.marker(context.job)
    write_marker(context.root, "another-job", marker)

    assert {:error, {:ledger_unavailable, :marker_identity_mismatch}} =
             Ledger.read_marker(context.prepared, "another-job")

    assert {:ok, absent_job} =
             Executor.job(Map.put(Map.from_struct(context.job), :job_id, "missing"))

    assert :absent = Ledger.read_marker(context.prepared, absent_job)
  end

  test "job-aware reads verify immutable relations without revalidating an ephemeral grant",
       context do
    marker = Ledger.marker(context.job)

    for {field, other} <- [
          {"operation_id", "another-operation"},
          {"attempt", 2},
          {"cleanup_grace_ms", 1}
        ] do
      write_marker(context.root, context.job.job_id, Map.put(marker, field, other))

      assert {:error, {:ledger_unavailable, :marker_request_mismatch}} =
               Ledger.read_marker(context.prepared, context.job)
    end

    write_marker(context.root, context.job.job_id, marker)
    assert {:ok, ^marker} = Ledger.read_marker(context.prepared, context.job)
    changed = job(%{operation_id: "another-operation"})
    assert {:error, :job_id_conflict} = Ledger.read_marker(context.prepared, changed)

    assert {:error, :canonical_job_request_mismatch} =
             Ledger.read_marker(context.prepared, %{context.job | attempt: 2})

    # This is only the read-only relation boundary. The existing Local corpus
    # separately proves duplicate joins with expired grants and real effects.
    assert {:ok, refusal} = Ledger.refusal(context.job, :missing_binding, :expiry)
    write_marker(context.root, context.job.job_id, refusal)
    assert {:ok, ^refusal} = Ledger.read_marker(context.prepared, context.job)
  end

  test "refusal replacement preserves exact request identity and admission bytes", context do
    assert {:ok, refusal} = Ledger.refusal(context.job, :workspace_lease_lost)

    assert :ok =
             Ledger.with_claim(context.prepared, fn ->
               Ledger.refuse(context.prepared, refusal)
             end)

    original = File.read!(marker_path(context.root, context.job.job_id))

    for {field, other} <- [
          {"canonical_request_digest", String.duplicate("0", 64)},
          {"operation_id", "another-operation"},
          {"attempt", 2}
        ] do
      changed = Map.put(refusal, field, other)

      assert {:error, {:ledger_conflict, :refusal_identity_mismatch}} =
               Ledger.with_claim(context.prepared, fn ->
                 Ledger.refuse(context.prepared, changed)
               end)

      assert File.read!(marker_path(context.root, context.job.job_id)) == original
    end

    marker = Ledger.marker(context.job)
    write_marker(context.root, context.job.job_id, marker)

    assert {:error, {:ledger_conflict, :admission_marker_present}} =
             Ledger.with_claim(context.prepared, fn ->
               Ledger.refuse(context.prepared, refusal)
             end)

    assert File.read!(marker_path(context.root, context.job.job_id)) == encode(marker)
  end

  test "claim callbacks receive fresh ephemeral context while zero-arity bodies stay compatible",
       context do
    before = File.ls!(context.root) |> Enum.sort()

    assert {:error, {:ledger_unavailable, :missing_claim_context}} =
             Ledger.open_snapshot(context.prepared)

    read_nonce = fn claimed ->
      assert Map.delete(claimed, :root_claim_nonce) == context.prepared
      assert byte_size(claimed.root_claim_nonce) == 64
      assert {:ok, <<_::256>>} = Base.decode16(claimed.root_claim_nonce, case: :lower)
      assert File.ls!(Path.join(context.root, "claim")) == []
      assert {:ok, []} = Ledger.open_snapshot(claimed)
      claimed.root_claim_nonce
    end

    first = Ledger.with_claim(context.prepared, read_nonce)

    second =
      Ledger.with_claim_until(
        context.prepared,
        read_nonce,
        System.monotonic_time(:millisecond) + 5_000
      )

    refute first == second
    assert :old_callback = Ledger.with_claim(context.prepared, fn -> :old_callback end)
    assert File.ls!(context.root) |> Enum.sort() == before
    refute Map.has_key?(context.prepared, :root_claim_nonce)

    assert_raise RuntimeError, "body failure", fn ->
      Ledger.with_claim(context.prepared, fn _claimed -> raise "body failure" end)
    end

    refute File.exists?(Path.join(context.root, "claim"))

    assert {:error, {:ledger_unavailable, {:root_claim_retained, :unproved}}} =
             Ledger.with_claim(context.prepared, fn _claimed -> Ledger.retain_claim(:unproved) end)

    assert File.dir?(Path.join(context.root, "claim"))

    assert {:error, {:ledger_unavailable, :root_claim_held}} =
             Ledger.with_claim(context.prepared, fn -> :must_not_run end)
  end

  test "the measured snapshot includes the nonce member at its exact byte ceiling", context do
    Ledger.with_claim(context.prepared, fn claimed ->
      entries = ceiling_entries(claimed, context.job)
      assert byte_size(snapshot_bytes(claimed, entries)) == @snapshot_bytes
      # Omitting the nonce would undercount this observation, while all its
      # individual records and identifiers still satisfy their own domains.
      Enum.each(entries, fn {_name, record} ->
        File.write!(open_path(context.root, record["job_id"]), encode(record))
      end)

      assert {:ok, actual} = Ledger.open_snapshot(claimed)
      assert actual == Enum.map(entries, &elem(&1, 1))

      [{name, first} | rest] = entries
      larger = Map.update!(first, "executor_identity", &(&1 <> "x"))
      assert byte_size(snapshot_bytes(claimed, [{name, larger} | rest])) == @snapshot_bytes + 1
      File.write!(open_path(context.root, larger["job_id"]), encode(larger))
      assert {:error, {:ledger_unavailable, :snapshot_too_large}} = Ledger.open_snapshot(claimed)
    end)
  end

  test "snapshot serialization carries this acquisition's exact nonce value", context do
    mfa = {:erlang, :term_to_binary, 2}
    assert {:match_spec, false} = :erlang.trace_info(mfa, :match_spec)
    parent = self()
    deadline = System.monotonic_time(:millisecond) + 5_000
    remaining = fn -> max(deadline - System.monotonic_time(:millisecond), 0) end

    {reader, monitor} =
      spawn_monitor(fn ->
        receive do
          :read ->
            result =
              Ledger.with_claim(context.prepared, fn claimed ->
                send(parent, {:acquired_nonce, self(), claimed.root_claim_nonce})
                Ledger.open_snapshot(claimed)
              end)

            send(parent, {:snapshot_result, self(), result})

            receive do
              :finish -> :ok
            after
              remaining.() -> exit(:observer_deadline)
            end
        after
          remaining.() -> exit(:observer_deadline)
        end
      end)

    on_exit(fn ->
      :erlang.trace_pattern(mfa, false, [:local])
      if Process.alive?(reader), do: Process.exit(reader, :kill)
    end)

    try do
      assert 1 == :erlang.trace_pattern(mfa, true, [:local])
      assert 1 == :erlang.trace(reader, true, [:call])
      send(reader, :read)
      assert_receive {:acquired_nonce, ^reader, nonce}, remaining.()
      assert_receive {:snapshot_result, ^reader, {:ok, []}}, remaining.()
      barrier = :erlang.trace_delivered(reader)
      assert_receive {:trace_delivered, ^reader, ^barrier}, remaining.()
      generation = context.prepared.generation_digest
      binding = context.prepared.root_binding

      # This is actual administrative value-flow observation only. The nonce is
      # not ownership authority, and byte-ceiling coverage is a separate case.
      assert_receive {:trace, ^reader, :call,
                      {:erlang, :term_to_binary,
                       [
                         ["loopex:local-root-snapshot:v1", ^generation, ^binding, ^nonce, 0, []],
                         [:deterministic]
                       ]}},
                     0

      send(reader, :finish)
      assert_receive {:DOWN, ^monitor, :process, ^reader, :normal}, remaining.()
      refute File.exists?(Path.join(context.root, "claim"))
    after
      :erlang.trace_pattern(mfa, false, [:local])
      if Process.alive?(reader), do: Process.exit(reader, :kill)
    end
  end

  test "captured marker-plane decoding uses the actual admission and refusal grammar", context do
    marker = Ledger.marker(context.job)
    refused_job = job(%{job_id: <<0, 255, "refused">>, operation_id: "captured-refused"})
    assert {:ok, refusal} = Ledger.refusal(refused_job, :workspace_lease_lost)

    assert :ok =
             Ledger.with_claim(context.prepared, fn claimed ->
               assert :ok =
                        Ledger.admit(
                          claimed,
                          marker,
                          Ledger.open_entry(context.job, context.job.executor_identity)
                        )

               Ledger.refuse(claimed, refusal)
             end)

    for record <- [marker, refusal] do
      bytes = File.read!(marker_path(context.root, record["job_id"]))
      assert {:ok, ^record} = Ledger.decode_marker_bytes(bytes)

      for hostile <- [
            bytes <> <<0>>,
            :erlang.term_to_binary(record, [:compressed]),
            encode(Map.put(record, "extra", 1)),
            :binary.copy(<<0>>, 65_537)
          ] do
        assert_unavailable(Ledger.decode_marker_bytes(hostile))
      end
    end

    assert_unavailable(
      Ledger.decode_marker_bytes(encode(Ledger.open_entry(context.job, "identity")))
    )

    assert_unavailable(
      Ledger.decode_marker_bytes(File.read!(Path.join(context.root, "generation")))
    )

    assert_unavailable(Ledger.decode_marker_bytes(:invalid))
  end

  test "captured open index agrees with the actual claimed writer snapshot", context do
    request = job(%{job_id: <<0, 255, 128, "open">>})
    record = Ledger.open_entry(request, context.job.executor_identity)
    assert :ok = restore(context.prepared, record)
    entries = [{digest(record["job_id"]), record}]
    assert {:ok, [^record]} = snapshot(context.prepared)

    assert {:ok, [^record]} =
             Ledger.validate_captured_open_index(
               context.prepared.generation_digest,
               context.prepared.root_binding,
               entries
             )

    assert {:ok, []} =
             Ledger.validate_captured_open_index(
               context.prepared.generation_digest,
               context.prepared.root_binding,
               []
             )

    refute File.exists?(Path.join(context.root, "claim"))
  end

  test "captured snapshot size equals the live nonce-bound exact ceiling", context do
    Ledger.with_claim(context.prepared, fn claimed ->
      entries = ceiling_entries(claimed, context.job)
      assert byte_size(snapshot_bytes(claimed, entries)) == @snapshot_bytes
      expected = Enum.map(entries, &elem(&1, 1))

      assert {:ok, ^expected} =
               Ledger.validate_captured_open_index(
                 claimed.generation_digest,
                 claimed.root_binding,
                 entries
               )

      [{name, first} | rest] = entries
      larger = Map.update!(first, "executor_identity", &(&1 <> "x"))
      assert byte_size(snapshot_bytes(claimed, [{name, larger} | rest])) == @snapshot_bytes + 1

      assert {:error, {:ledger_unavailable, :snapshot_too_large}} =
               Ledger.validate_captured_open_index(
                 claimed.generation_digest,
                 claimed.root_binding,
                 [{name, larger} | rest]
               )
    end)
  end

  test "captured open index refuses count basename shape ordering and binding violations",
       context do
    generation = context.prepared.generation_digest
    binding = context.prepared.root_binding
    record = Ledger.open_entry(context.job, context.job.executor_identity)
    entry = {digest(record["job_id"]), record}
    assert :ok = Ledger.open_index_capacity(1_024)
    assert_unavailable(Ledger.open_index_capacity(1_025))

    for entries <- [
          [entry, entry],
          [{"wrong", record}],
          [:invalid],
          [{elem(entry, 0), Map.put(record, "extra", 1)}],
          List.duplicate(entry, 1_025)
        ] do
      assert_unavailable(Ledger.validate_captured_open_index(generation, binding, entries))
    end

    other = Map.put(record, "job_id", "other")
    sorted = Enum.sort([{digest(other["job_id"]), other}, entry])
    assert {:ok, _} = Ledger.validate_captured_open_index(generation, binding, sorted)

    assert_unavailable(
      Ledger.validate_captured_open_index(generation, binding, Enum.reverse(sorted))
    )

    assert_unavailable(Ledger.validate_captured_open_index("bad", binding, [entry]))
    assert_unavailable(Ledger.validate_captured_open_index(generation, "bad", [entry]))
    assert_unavailable(Ledger.validate_captured_open_index(generation, binding, :invalid))
  end

  defp invalid_attempt_fields do
    [
      {"job_id", ""},
      {"job_id", nil},
      {"job_id", String.duplicate("j", 8_193)},
      {"operation_id", ""},
      {"operation_id", String.duplicate("o", 8_193)},
      {"canonical_request_digest", String.duplicate("A", 64)},
      {"canonical_request_digest", "00"},
      {"attempt", 0},
      {"attempt", -1},
      {"attempt", "1"}
    ]
  end

  defp assert_unavailable(result), do: assert(match?({:error, {:ledger_unavailable, _}}, result))

  defp assert_empty_index(root) do
    assert File.ls!(Path.join(root, "open")) == []
    assert File.ls!(Path.join(root, "markers")) == []
  end

  defp snapshot(prepared), do: Ledger.with_claim(prepared, &Ledger.open_snapshot/1)

  defp restore(prepared, record),
    do: Ledger.with_claim(prepared, fn -> Ledger.restore_open(prepared, record) end)

  defp encode(record), do: :erlang.term_to_binary(record, [:deterministic])
  defp digest(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
  defp marker_path(root, id), do: Path.join([root, "markers", digest(id)])
  defp open_path(root, id), do: Path.join([root, "open", digest(id)])
  defp write_marker(root, id, record), do: File.write!(marker_path(root, id), encode(record))

  # Build a valid 512-entry observation, then fill exactly the remaining bytes
  # with one bounded executor identity. This measures the literal ADR projection,
  # not an inferred latency or serialization trace as proof of claim ownership.
  defp ceiling_entries(claimed, request) do
    base = Ledger.open_entry(request, "x")

    build = fn width ->
      for index <- 1..512 do
        id = String.pad_leading(Integer.to_string(index), 4, "0") <> String.duplicate("j", width)
        record = Map.put(base, "job_id", id)
        {digest(id), record}
      end
      |> Enum.sort_by(&elem(&1, 0))
    end

    width = largest_fitting_width(claimed, build, 0, 8_188)
    [{name, first} | rest] = entries = build.(width)
    remaining = @snapshot_bytes - byte_size(snapshot_bytes(claimed, entries))
    assert remaining in 0..511
    first = Map.put(first, "executor_identity", String.duplicate("x", remaining + 1))
    [{name, first} | rest]
  end

  defp largest_fitting_width(_claimed, _build, low, high) when low == high, do: low

  defp largest_fitting_width(claimed, build, low, high) do
    middle = div(low + high + 1, 2)

    if byte_size(snapshot_bytes(claimed, build.(middle))) <= @snapshot_bytes,
      do: largest_fitting_width(claimed, build, middle, high),
      else: largest_fitting_width(claimed, build, low, middle - 1)
  end

  defp snapshot_bytes(claimed, entries) do
    encode([
      "loopex:local-root-snapshot:v1",
      claimed.generation_digest,
      claimed.root_binding,
      claimed.root_claim_nonce,
      length(entries),
      Enum.map(entries, fn {name, record} -> [name, digest(encode(record)), record] end)
    ])
  end

  defp job(overrides \\ %{}) do
    fields = %{
      protocol_version: 1,
      job_id: "ledger-record-job",
      operation_id: "ledger-record-operation",
      attempt: 1,
      session_id: "session",
      run_id: "run",
      turn_id: "turn",
      tool_call_id: "call",
      origin_session_epoch: 0,
      origin_executor_epoch: 0,
      executor_identity: "ledger-record-test",
      required_capabilities: [],
      tool_id: "ledger-component-only",
      tool_version: "1",
      effect_class: "workspace_write",
      validated_arguments: %{},
      workspace_ref: "workspace",
      workspace_lease: "lease",
      run_deadline: 1,
      resource_budgets: %{},
      idempotency_class: "never_blind_retry",
      fencing_token: 0,
      artifact_policy: %{},
      output_policy: %{},
      cleanup_grace_ms: 5_000
    }

    assert {:ok, request} = Executor.job(Map.merge(fields, overrides))
    request
  end
end
