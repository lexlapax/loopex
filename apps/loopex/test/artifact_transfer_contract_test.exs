defmodule Loopex.ArtifactTransferContractTest do
  use ExUnit.Case, async: true

  alias Loopex.ArtifactStore
  alias LoopexProtocol.Canonical

  defmodule CurrentCapability do
    def reserve_transfer(_, _, _), do: :not_invoked
    def open_transfer(_, _, _), do: :not_invoked
    def read_transfer(_, _, _), do: :not_invoked
    def close_transfer(_, _), do: :not_invoked
  end

  defmodule MissingReservation do
    def open_transfer(_, _, _), do: :not_invoked
    def read_transfer(_, _, _), do: :not_invoked
    def close_transfer(_, _), do: :not_invoked
  end

  defmodule MissingRead do
    def reserve_transfer(_, _, _), do: :not_invoked
    def open_transfer(_, _, _), do: :not_invoked
    def close_transfer(_, _), do: :not_invoked
  end

  defmodule MissingClose do
    def reserve_transfer(_, _, _), do: :not_invoked
    def open_transfer(_, _, _), do: :not_invoked
    def read_transfer(_, _, _), do: :not_invoked
  end

  defmodule SupersededArity do
    def reserve_transfer(_, _, _), do: :not_invoked
    def open_transfer(_, _, _, _), do: :not_invoked
    def read_transfer(_, _, _), do: :not_invoked
    def close_transfer(_, _), do: :not_invoked
  end

  test "capability requires the entire current optional callback set" do
    assert ArtifactStore.supports_transfer?(CurrentCapability)
    refute ArtifactStore.supports_transfer?(MissingReservation)
    refute ArtifactStore.supports_transfer?(MissingRead)
    refute ArtifactStore.supports_transfer?(MissingClose)
    refute ArtifactStore.supports_transfer?(SupersededArity)
    refute ArtifactStore.supports_transfer?(__MODULE__)
    refute ArtifactStore.supports_transfer?(%{})
  end

  test "request preserves opaque session bytes and exact unsigned64 boundaries" do
    %{request: request} = fixture()
    assert ArtifactStore.valid_transfer_request?(request)

    assert ArtifactStore.valid_transfer_request?(
             Map.put(request, :session_id, :binary.copy(<<255>>, 256))
           )

    assert ArtifactStore.valid_transfer_request?(%{request | start: 18_446_744_073_709_551_615})

    assert ArtifactStore.valid_transfer_request?(
             Map.put(request, :length, 18_446_744_073_709_551_615)
           )

    for invalid <- [
          %{request | session_id: ""},
          %{request | session_id: :binary.copy(<<255>>, 257)},
          %{request | start: -1},
          %{request | start: 18_446_744_073_709_551_616},
          Map.put(request, :length, nil),
          Map.put(request, :length, -1),
          Map.put(request, :length, 18_446_744_073_709_551_616),
          %{request | use_locator: "use:" <> String.duplicate("A", 64)},
          Map.put(request, :object, %{}),
          Map.delete(request, :start),
          MapSet.new(),
          self()
        ] do
      refute ArtifactStore.valid_transfer_request?(invalid)
    end
  end

  test "opening context fixes work declarations and keeps signed clock data pure" do
    %{context: context, request: request, transfer: transfer, use: use, work: work} = fixture()
    opened = {:ok, %{transfer: transfer, use: use, work: work}}
    reservation = {:ok, %{transfer_ref: context.transfer_ref}}
    assert ArtifactStore.valid_reserve_result?(reservation, context)
    assert ArtifactStore.valid_open_result?(opened, request, context)

    for float_context <- [
          %{context | object_work_bytes: 134_217_728.0},
          %{context | metadata_read_bytes: 131_073.0}
        ] do
      refute ArtifactStore.valid_open_context?(float_context)
      refute ArtifactStore.valid_reserve_result?(reservation, float_context)
      refute ArtifactStore.valid_open_result?(opened, request, float_context)
    end

    for clock <- [-9_223_372_036_854_775_808, -1, 0, 9_223_372_036_854_775_807] do
      assert ArtifactStore.valid_open_context?(%{context | open_deadline_ms: clock})
    end

    for invalid <- [
          %{context | transfer_ref: String.duplicate("A", 32)},
          %{context | transfer_ref: String.duplicate("a", 31)},
          %{context | transfer_ref: String.duplicate("a", 33)},
          %{context | open_deadline_ms: nil},
          %{context | object_work_bytes: 134_217_727},
          %{context | object_work_bytes: 134_217_729},
          %{context | metadata_read_bytes: 131_072},
          %{context | metadata_read_bytes: 131_074},
          Map.put(context, :owner, self()),
          MapSet.new()
        ] do
      refute ArtifactStore.valid_open_context?(invalid)
    end
  end

  test "retire and acknowledgement selectors have separate closed identities" do
    %{context: context} = fixture()
    retire = retire(context)

    ack = %{
      action: :acknowledge,
      transfer_ref: context.transfer_ref,
      receipt_ref: String.duplicate("b", 32)
    }

    assert ArtifactStore.valid_close_context?(retire)
    assert ArtifactStore.valid_close_context?(ack)

    for invalid <- [
          Map.put(retire, :receipt_ref, ack.receipt_ref),
          Map.put(ack, :close_deadline_ms, 0),
          %{retire | action: :close},
          %{retire | close_deadline_ms: 1.0},
          %{ack | receipt_ref: String.duplicate("B", 32)},
          Map.delete(ack, :receipt_ref),
          MapSet.new()
        ] do
      refute ArtifactStore.valid_close_context?(invalid)
    end
  end

  test "pure use admission agrees with an independent explicit canonical preimage" do
    %{use: use, request: request} = fixture()
    assert Canonical.encode(["artifact-use-v2", use]) == independent_use_bytes(use)
    assert request.use_locator == "use:" <> digest(independent_use_bytes(use))
    assert ArtifactStore.valid_transfer_use?(use, request)
    assert use.metadata["session_id"] == <<0, 255>>
    other_session = %{use | metadata: %{use.metadata | "session_id" => "other"}}

    other_request = %{
      request
      | use_locator: "use:" <> digest(independent_use_bytes(other_session))
    }

    assert ArtifactStore.valid_transfer_request?(other_request)

    assert ArtifactStore.valid_transfer_use?(other_session, %{other_request | session_id: "other"})

    refute ArtifactStore.valid_transfer_use?(other_session, other_request)

    for extra_use <- [
          Map.put(use, :path, "/private"),
          %{use | metadata: Map.put(use.metadata, "note", "unknown")}
        ] do
      extra_request = %{
        request
        | use_locator: "use:" <> digest(Canonical.encode(["artifact-use-v2", extra_use]))
      }

      assert ArtifactStore.valid_transfer_request?(extra_request)
      refute ArtifactStore.valid_transfer_use?(extra_use, extra_request)
    end

    for changed <- [
          %{use | canonicalization_version: "unknown"},
          %{use | object_digest: String.duplicate("b", 64)},
          %{use | object_locator: "other-object"},
          %{use | object_size: 4},
          %{use | role: "other"},
          %{use | metadata: %{use.metadata | "session_id" => "other"}},
          Map.put(use, :path, "/private"),
          %{use | metadata: Map.put(use.metadata, "note", "unknown")},
          %{use | metadata: %{use.metadata | "attempt" => 0}},
          %{use | metadata: %{use.metadata | "tool_call_id" => self()}},
          MapSet.new()
        ] do
      refute ArtifactStore.valid_transfer_use?(changed, request)
    end
  end

  test "canonical use cap and cap plus one keep digest and session prerequisites valid" do
    %{use: use, request: request} = fixture()
    empty = %{use | metadata: %{use.metadata | "tool_call_id" => ""}}
    padding = 131_072 - byte_size(independent_use_bytes(empty))
    exact = %{use | metadata: %{use.metadata | "tool_call_id" => String.duplicate("x", padding)}}

    over = %{
      exact
      | metadata: %{exact.metadata | "tool_call_id" => exact.metadata["tool_call_id"] <> "x"}
    }

    assert byte_size(independent_use_bytes(exact)) == 131_072
    assert byte_size(independent_use_bytes(over)) == 131_073
    assert Canonical.encode(["artifact-use-v2", exact]) == independent_use_bytes(exact)
    assert Canonical.encode(["artifact-use-v2", over]) == independent_use_bytes(over)
    exact_request = %{request | use_locator: "use:" <> digest(independent_use_bytes(exact))}
    over_request = %{request | use_locator: "use:" <> digest(independent_use_bytes(over))}
    assert ArtifactStore.valid_transfer_request?(exact_request)
    assert ArtifactStore.valid_transfer_request?(over_request)
    assert ArtifactStore.valid_transfer_use?(exact, exact_request)
    refute ArtifactStore.valid_transfer_use?(over, over_request)
    assert over.metadata["session_id"] == over_request.session_id
  end

  test "oversized opaque scalars and arbitrary positive attempts refuse bounded use admission" do
    %{use: use, request: request} = fixture()

    oversized = %{
      use
      | metadata: %{use.metadata | "tool_call_id" => :binary.copy(<<255>>, 131_073)}
    }

    huge_attempt = %{use | metadata: %{use.metadata | "attempt" => Integer.pow(2, 1_048_584)}}

    oversized_request = %{
      request
      | use_locator: "use:" <> digest(independent_use_bytes(oversized))
    }

    huge_request = %{request | use_locator: "use:" <> digest(independent_use_bytes(huge_attempt))}
    assert ArtifactStore.valid_transfer_request?(oversized_request)
    assert ArtifactStore.valid_transfer_request?(huge_request)
    assert byte_size(independent_use_bytes(oversized)) > 131_072
    assert byte_size(independent_use_bytes(huge_attempt)) > 131_072
    refute ArtifactStore.valid_transfer_use?(oversized, oversized_request)
    refute ArtifactStore.valid_transfer_use?(huge_attempt, huge_request)
    small_attempt = %{use | metadata: %{use.metadata | "attempt" => 256}}

    small_request = %{
      request
      | use_locator: "use:" <> digest(independent_use_bytes(small_attempt))
    }

    assert ArtifactStore.valid_transfer_use?(small_attempt, small_request)
  end

  test "full object payload and additional metadata work retain exact separate caps" do
    %{work: work} = fixture()

    full = %{
      work
      | source_read_bytes: 67_108_864,
        snapshot_write_debit: 67_108_864,
        metadata_read_bytes: 131_073
    }

    assert ArtifactStore.valid_transfer_work?(full)
    assert ArtifactStore.valid_transfer_work?(%{full | write_uncertain: true})

    assert ArtifactStore.valid_transfer_work?(%{
             work
             | source_read_bytes: 0,
               snapshot_write_debit: 0,
               metadata_read_bytes: 0
           })

    for invalid <- [
          %{full | source_read_bytes: 67_108_865},
          %{full | snapshot_write_debit: 67_108_865},
          %{full | metadata_read_bytes: 131_074},
          %{work | source_read_bytes: -1},
          %{work | write_uncertain: nil},
          Map.put(work, :physical_written_bytes, 0),
          :unavailable,
          MapSet.new()
        ] do
      refute ArtifactStore.valid_transfer_work?(invalid)
    end
  end

  test "transfer projection binds exact original identity and unclamped window" do
    %{transfer: transfer, request: request, context: context, use: use, work: work} = fixture()
    assert ArtifactStore.valid_transfer?(transfer, request, context)
    zero = %{transfer | window_start: 3, window_length: 0}
    assert ArtifactStore.valid_transfer?(zero, %{request | start: 3}, context)

    assert ArtifactStore.valid_transfer?(
             zero,
             Map.put(%{request | start: 3}, :length, 0),
             context
           )

    for changed <- [
          %{transfer | transfer_ref: String.duplicate("b", 32)},
          %{transfer | use_locator: "use:" <> String.duplicate("b", 64)},
          %{transfer | total_size: 4},
          %{transfer | total_size: 3.0},
          %{transfer | window_start: 0.0},
          %{transfer | object_digest: String.duplicate("b", 64)},
          %{transfer | window_start: 1},
          %{transfer | window_length: 4},
          Map.put(transfer, :reader, self())
        ] do
      refute ArtifactStore.valid_transfer?(changed, request, context)

      refute ArtifactStore.valid_open_result?(
               {:ok, %{transfer: changed, use: use, work: work}},
               request,
               context
             )
    end

    refute ArtifactStore.valid_transfer?(transfer, Map.put(request, :length, 4), context)
    refute ArtifactStore.valid_transfer?(zero, %{request | start: 4}, context)

    full = %{
      transfer
      | object: %{transfer.object | size: 67_108_864},
        total_size: 67_108_864,
        window_length: 67_108_864
    }

    assert ArtifactStore.valid_transfer?(full, request, context)

    refute ArtifactStore.valid_transfer?(
             %{
               full
               | object: %{full.object | size: 67_108_865},
                 total_size: 67_108_865,
                 window_length: 67_108_865
             },
             request,
             context
           )
  end

  test "reservation and admitted refusal grammar cannot echo extra or mismatched identities" do
    %{context: context, request: request, work: work} = fixture()
    reservation = {:ok, %{transfer_ref: context.transfer_ref}}

    absent =
      {:error, %{reason: :cancelled, transfer_ref: context.transfer_ref, state: :not_reserved}}

    assert ArtifactStore.valid_reserve_result?(reservation, context)
    assert ArtifactStore.valid_reserve_result?(absent, context)

    refute ArtifactStore.valid_reserve_result?(
             {:ok, %{transfer_ref: String.duplicate("b", 32)}},
             context
           )

    refute ArtifactStore.valid_reserve_result?(
             {:ok, %{transfer_ref: context.transfer_ref, path: "/private"}},
             context
           )

    for state <- [:retiring, :retired] do
      assert ArtifactStore.valid_open_result?(
               {:error,
                %{
                  reason: :cancelled,
                  transfer_ref: context.transfer_ref,
                  work: work,
                  state: state
                }},
               request,
               context
             )
    end

    refute ArtifactStore.valid_open_result?(
             {:error,
              %{
                reason: :cancelled,
                transfer_ref: context.transfer_ref,
                work: :unavailable,
                state: :retired
              }},
             request,
             context
           )

    refute ArtifactStore.valid_reserve_result?(
             {:error,
              %{reason: :unknown, transfer_ref: context.transfer_ref, state: :not_reserved}},
             context
           )

    refute ArtifactStore.valid_reserve_result?({:error, :cancelled}, context)

    for reason <- [:reservation_conflict, :reservation_required, :transfers_unavailable] do
      refute ArtifactStore.valid_reserve_result?({:error, reason}, context)
      refute ArtifactStore.valid_open_result?({:error, reason}, request, context)
    end
  end

  test "successful open reuses pure use checks and exact object work bindings" do
    %{transfer: transfer, use: use, work: work, request: request, context: context} = fixture()
    opened = %{transfer: transfer, use: use, work: work}
    assert ArtifactStore.valid_open_result?({:ok, opened}, request, context)

    for changed_work <- [
          %{work | source_read_bytes: 2},
          %{work | source_read_bytes: 4},
          %{work | snapshot_write_debit: 2},
          %{work | snapshot_write_debit: 4},
          %{work | write_uncertain: true}
        ] do
      assert ArtifactStore.valid_transfer_work?(changed_work)

      refute ArtifactStore.valid_open_result?(
               {:ok, %{opened | work: changed_work}},
               request,
               context
             )
    end

    other_object = %{transfer.object | locator: "other-object"}

    refute ArtifactStore.valid_open_result?(
             {:ok, %{opened | transfer: %{transfer | object: other_object}}},
             request,
             context
           )

    refute ArtifactStore.valid_open_result?(
             {:ok, Map.put(opened, :handle, self())},
             request,
             context
           )

    refute ArtifactStore.valid_open_result?(
             {:ok, %{opened | use: %{use | metadata: %{use.metadata | "session_id" => "other"}}}},
             request,
             context
           )
  end

  test "retirement receipts and acknowledgements stay separate from unavailable accounting" do
    %{context: context, work: work} = fixture()
    retire = retire(context)
    receipt = String.duplicate("b", 32)
    retired = %{transfer_ref: context.transfer_ref, receipt_ref: receipt, work: work}
    ack = %{action: :acknowledge, transfer_ref: context.transfer_ref, receipt_ref: receipt}
    assert ArtifactStore.valid_close_result?({:retired, retired}, retire)
    assert ArtifactStore.valid_close_result?({:retired, %{retired | work: :unavailable}}, retire)

    assert ArtifactStore.valid_close_result?(
             {:unregistered, %{transfer_ref: context.transfer_ref}},
             retire
           )

    assert ArtifactStore.valid_close_result?({:error, :cleanup_unproved}, retire)
    assert ArtifactStore.valid_close_result?(:ok, ack)
    assert ArtifactStore.valid_close_result?({:error, :retirement_receipt_mismatch}, ack)
    refute ArtifactStore.valid_close_result?(:ok, retire)
    refute ArtifactStore.valid_close_result?({:retired, retired}, ack)

    refute ArtifactStore.valid_close_result?(
             {:retired, %{retired | receipt_ref: String.duplicate("B", 32)}},
             retire
           )

    refute ArtifactStore.valid_close_result?(
             {:retired, Map.put(retired, :reader, self())},
             retire
           )
  end

  test "public admitted failures contain only closed reason and cleanup fields" do
    assert ArtifactStore.valid_transfer_failure?(
             {:error, %{reason: :cancelled, cleanup: :proved}}
           )

    assert ArtifactStore.valid_transfer_failure?(
             {:error, %{reason: :open_deadline_exhausted, cleanup: :unproved}}
           )

    refute ArtifactStore.valid_transfer_failure?({:error, %{reason: :unknown, cleanup: :proved}})

    refute ArtifactStore.valid_transfer_failure?(
             {:error, %{reason: :cancelled, cleanup: :unknown}}
           )

    refute ArtifactStore.valid_transfer_failure?(
             {:error, %{reason: :cancelled, cleanup: :proved, work: %{}}}
           )

    refute ArtifactStore.valid_transfer_failure?({:error, :cancelled})
  end

  test "limit extensions preserve every existing safety ceiling" do
    assert ArtifactStore.transfer_limits() == %{
             object_bytes: 67_108_864,
             open_deadline_ms: 60_000,
             open_work_bytes: 134_217_728,
             metadata_read_bytes: 131_073,
             cleanup_deadline_ms: 5_000,
             chunk_bytes: 32_768,
             read_deadline_ms: 5_000,
             lifetime_ms: 600_000,
             per_attachment: 2,
             per_runtime: 4
           }
  end

  defp fixture do
    use = %{
      canonicalization_version: "loopex.canonical.v1",
      object_digest: String.duplicate("a", 64),
      object_size: 3,
      object_locator: "object:fixture",
      media_type: "application/octet-stream",
      role: "tool_output",
      metadata: %{
        "session_id" => <<0, 255>>,
        "run_id" => "run",
        "operation_id" => "operation",
        "attempt" => 1,
        "tool_call_id" => "tool"
      }
    }

    request = %{
      session_id: <<0, 255>>,
      use_locator: "use:" <> digest(independent_use_bytes(use)),
      start: 0
    }

    context = %{
      transfer_ref: String.duplicate("a", 32),
      open_deadline_ms: -1,
      object_work_bytes: 134_217_728,
      metadata_read_bytes: 131_073
    }

    transfer = %{
      transfer_ref: context.transfer_ref,
      object: %{digest: use.object_digest, size: 3, locator: use.object_locator},
      use_locator: request.use_locator,
      total_size: 3,
      window_start: 0,
      window_length: 3,
      object_digest: use.object_digest
    }

    work = %{
      source_read_bytes: 3,
      snapshot_write_debit: 3,
      metadata_read_bytes: byte_size(independent_use_bytes(use)),
      write_uncertain: false
    }

    %{request: request, context: context, use: use, transfer: transfer, work: work}
  end

  defp retire(context) do
    %{
      action: :retire,
      transfer_ref: context.transfer_ref,
      open_deadline_ms: context.open_deadline_ms,
      close_deadline_ms: 4_999
    }
  end

  # Concept: expected use bytes are independent of the production ordering walk.
  # Technical depth: this literal projection states each canonical key position;
  # OTP encodes it directly and SHA-256 covers those exact expected bytes.
  defp independent_use_bytes(use) do
    :erlang.term_to_binary(
      [
        "artifact-use-v2",
        {:loopex_map,
         [
           {:role, use.role},
           {:metadata,
            {:loopex_map,
             [
               {"run_id", use.metadata["run_id"]},
               {"attempt", use.metadata["attempt"]},
               {"session_id", use.metadata["session_id"]},
               {"operation_id", use.metadata["operation_id"]},
               {"tool_call_id", use.metadata["tool_call_id"]}
             ]}},
           {:media_type, use.media_type},
           {:object_size, use.object_size},
           {:object_digest, use.object_digest},
           {:object_locator, use.object_locator},
           {:canonicalization_version, use.canonicalization_version}
         ]}
      ],
      [:deterministic]
    )
  end

  defp digest(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
