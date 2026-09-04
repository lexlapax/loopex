Code.require_file("support/m1_runtime_helper.exs", __DIR__)

defmodule Loopex.StoreItemBudgetTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias Loopex.Store
  alias Loopex.M1RuntimeTestStore

  @max_item_bytes 65_536
  @max_item_depth 12
  @max_item_cardinality 1_024

  test "the shared Store item normalizer reports exact byte depth and cardinality boundaries" do
    rejected_depth = @max_item_depth + 1
    rejected_cardinality = @max_item_cardinality + 1

    assert dynamic_apply(Store, :max_item_bytes, []) == @max_item_bytes
    assert dynamic_apply(Store, :max_item_depth, []) == @max_item_depth
    assert dynamic_apply(Store, :max_item_cardinality, []) == @max_item_cardinality

    for plane <- [:record, :event],
        target <- [@max_item_bytes - 1, @max_item_bytes, @max_item_bytes + 1] do
      {body, item} = sized_item(plane, target)

      assert {:ok, normalized_at_target, ^target} = normalize(plane, item)
      assert normalized_at_target["body"] == body
    end

    at_depth = nested_value(@max_item_depth - 1)
    above_depth = nested_value(@max_item_depth)

    assert {:ok, normalized, bytes} =
             normalize(:record, %{"value" => at_depth, kind: "depth-boundary"})

    assert normalized["value"] == at_depth
    assert bytes == byte_size(:erlang.term_to_binary(normalized, [:deterministic]))

    assert {:error, {:item_structure_exceeded, :depth, ^rejected_depth, @max_item_depth}} =
             normalize(:record, %{"value" => above_depth, kind: "depth-boundary"})

    admitted_map =
      1..(@max_item_cardinality - 1)
      |> Map.new(&{"k#{&1}", &1})
      |> Map.put(:kind, "cardinality-boundary")

    assert {:ok, normalized_map, _bytes} = normalize(:record, admitted_map)
    assert map_size(normalized_map) == @max_item_cardinality

    oversized_map = Map.put(admitted_map, "owner_epoch", self())

    assert {:error,
            {:item_structure_exceeded, :cardinality, ^rejected_cardinality, @max_item_cardinality}} =
             normalize(:record, oversized_map)

    oversized_event_map =
      admitted_map
      |> Map.put(:event_id, "event-cardinality")
      |> Map.put("owner_epoch", self())

    assert {:error,
            {:item_structure_exceeded, :cardinality, ^rejected_cardinality, @max_item_cardinality}} =
             normalize(:event, oversized_event_map)

    admitted_list = Enum.to_list(1..@max_item_cardinality)

    assert {:ok, normalized_list_record, _bytes} =
             normalize(:record, %{"value" => admitted_list, kind: "list-boundary"})

    assert normalized_list_record["value"] == admitted_list

    # The tail is deliberately not plain data. A whole-list predicate or traversal
    # past the first rejected witness would report invalid data instead of the
    # required allocation-safe cardinality result.
    oversized_improper = improper_list(@max_item_cardinality + 1, {:unvisited_tail, self()})

    assert {:error,
            {:item_structure_exceeded, :cardinality, ^rejected_cardinality, @max_item_cardinality}} =
             normalize(:record, %{"value" => oversized_improper, kind: "list-boundary"})
  end

  test "event normalization and transaction-only protections remain exact and separate" do
    capability = "owner-incarnation-secret"

    ordinary = %{
      event_id: "ordinary-event",
      kind: "fact",
      payload: %{"visible" => ["safe", 1, true, nil]}
    }

    capability_event = %{
      event_id: "capability-event",
      kind: "fact",
      payload: %{"visible" => "prefix-#{capability}-suffix"}
    }

    assert {:ok, normalized_ordinary, ordinary_bytes} = normalize(:event, ordinary)
    assert {:ok, normalized_capability, capability_bytes} = normalize(:event, capability_event)

    assert ordinary_bytes ==
             byte_size(:erlang.term_to_binary(normalized_ordinary, [:deterministic]))

    assert capability_bytes ==
             byte_size(:erlang.term_to_binary(normalized_capability, [:deterministic]))

    assert {:error, :owner_capability_in_public_event} =
             Store.session_commit(
               "session",
               "session",
               "capability-transaction",
               0,
               capability,
               0,
               [%{kind: "private-fact"}],
               [capability_event]
             )

    assert {:error, :invalid_events} =
             Store.session_commit(
               "session",
               "session",
               "duplicate-event-transaction",
               0,
               capability,
               0,
               [%{kind: "private-fact"}],
               [ordinary, ordinary]
             )

    for reserved <- ["event_sequence", "owner_epoch", "owner_incarnation_id"] do
      root = Map.put(ordinary, reserved, 1)
      nested = put_in(ordinary, [:payload, reserved], 1)

      assert {:error, :invalid_event} = normalize(:event, root)
      assert {:error, :invalid_event} = normalize(:event, nested)
    end
  end

  test "generated normalization equals real Store transaction normalization and byte admission" do
    {store_pid, store} = M1RuntimeTestStore.start_store(label: "item-budget-parity")
    on_exit(fn -> if Process.alive?(store_pid), do: GenServer.stop(store_pid) end)

    samples = [
      nil,
      false,
      true,
      -1,
      0,
      1,
      1.5,
      "scalar",
      ["list", 1, true, nil],
      %{:atom_key => "normalized", "nested" => %{"list" => [1, 2, 3]}}
    ]

    for {value, index} <- Enum.with_index(samples) do
      record = %{:kind => "generated-parity", "sample" => value}

      assert {:ok, normalized, bytes} = normalize(:record, record)
      assert bytes == byte_size(:erlang.term_to_binary(normalized, [:deterministic]))

      command_id = "generated-#{index}"
      assert {:ok, transaction} = Store.create_session("runtime-#{index}", command_id, record)
      assert transaction.genesis == normalized
      assert {:committed, ^command_id, _receipt} = Store.transact(store, transaction)
    end

    for target <- [@max_item_bytes - 1, @max_item_bytes] do
      {_body, record} = sized_record(target)
      command_id = "bytes-#{target}"

      assert {:ok, normalized, ^target} = normalize(:record, record)
      assert {:ok, transaction} = Store.create_session("runtime-#{target}", command_id, record)
      assert transaction.genesis == normalized
      assert {:committed, ^command_id, _receipt} = Store.transact(store, transaction)
    end

    oversized_bytes = @max_item_bytes + 1
    {_body, oversized} = sized_record(oversized_bytes)
    assert {:ok, _normalized, ^oversized_bytes} = normalize(:record, oversized)

    assert {:error, {:item_too_large, ^oversized_bytes, @max_item_bytes}} =
             Store.create_session("runtime-oversized", "bytes-oversized", oversized)
  end

  test "oversized map and improper list report the first structural witness while admitted invalid keys stay distinct" do
    rejected = @max_item_cardinality + 1

    huge_map =
      1..100_000
      |> Map.new(fn index ->
        {"k#{String.pad_leading(Integer.to_string(index), 6, "0")}", index}
      end)
      |> Map.put(:kind, "huge-map")
      |> Map.put({:invalid_key_beyond_the_witness, self()}, self())

    assert {:error, {:item_structure_exceeded, :cardinality, ^rejected, @max_item_cardinality}} =
             normalize(:record, huge_map)

    huge_list = improper_list(100_000, {:unvisited_tail, self()})

    assert {:error, {:item_structure_exceeded, :cardinality, ^rejected, @max_item_cardinality}} =
             normalize(:record, %{:kind => "huge-list", "value" => huge_list})

    admitted_bad_key = %{:kind => "bad-key", {:invalid_key, self()} => "visited"}
    assert {:error, :invalid_item} = normalize(:record, admitted_bad_key)

    colliding_keys = %{:kind => "collision", :collision => 1, "collision" => 2}
    assert {:error, :invalid_item} = normalize(:record, colliding_keys)

    depth_and_cardinality =
      nested_value(@max_item_depth)
      |> Map.put("wide", Enum.to_list(1..(@max_item_cardinality + 1)))

    rejected_depth = @max_item_depth + 1

    assert {:error, {:item_structure_exceeded, :depth, ^rejected_depth, @max_item_depth}} =
             normalize(:record, %{:kind => "depth-first", "value" => depth_and_cardinality})
  end

  # Concept: an item nothing could ever admit is refused without a copy of it
  # ever being built.
  #
  # Technical depth: ADR 0017 requires a structurally valid item to be "measured
  # with a deterministic external-term size calculator without first allocating
  # the encoded byte string", and returns the exact count even above
  # `max_item_bytes/0`. The normalizer admits an arbitrary-size binary as an
  # ordinary scalar, so encoding the complete normalized term to measure it
  # built a full encoded copy of a 100 MiB payload and only then refused it at
  # the 65,536-byte ceiling. The exact count is still asserted here, because a
  # calculator that stops counting at the ceiling would break the byte cost an
  # over-ceiling refusal has to report.
  test "an oversized scalar binary is measured exactly and refused without an encoded copy" do
    payload = :binary.copy("x", 100 * 1024 * 1024)
    item = %{"body" => payload, kind: "allocation-safety"}
    expected = independent_size(%{"body" => "", kind: "allocation-safety"}) + byte_size(payload)

    :erlang.garbage_collect()
    before = :erlang.memory(:binary)
    measured = normalize(:record, item)
    refusal = Store.create_session("runtime-allocation", "allocation-safety", item)
    allocated = :erlang.memory(:binary) - before

    assert {:ok, ^item, ^expected} = measured
    assert expected > @max_item_bytes
    assert refusal == {:error, {:item_too_large, expected, @max_item_bytes}}
    assert allocated < 32 * 1024 * 1024
  end

  # Concept: the size a caller is told is the size the Store will encode.
  #
  # Technical depth: the measured cost is compared with `max_item_bytes/0` by
  # the caller and again by `transact/2`, and an over-ceiling refusal records it
  # as a durable byte cost, so an approximation anywhere in the admitted scalar
  # domain would move the ceiling or record a number that was never true. Every
  # admitted form is pinned against the encoding itself: small and large
  # integers, bignums of both signs, floats, the byte-list shape the external
  # format encodes as a string rather than a list, empty collections, and depth.
  test "the measured cost equals the deterministic encoding for every admitted form" do
    values = [
      0,
      255,
      256,
      -1,
      2_147_483_647,
      -2_147_483_648,
      123_456_789_012_345_678_901_234_567_890,
      -123_456_789_012_345_678_901_234_567_890,
      1.5,
      -0.125,
      nil,
      true,
      false,
      "",
      :binary.copy("z", 300),
      [],
      Enum.to_list(0..255),
      [1, 2, 3, 256],
      List.duplicate(7, 1_000),
      %{},
      %{"a" => %{"b" => [%{"c" => []}]}},
      nested_value(@max_item_depth - 1)
    ]

    for {value, index} <- Enum.with_index(values) do
      item = %{"value" => value, kind: "sizer-#{index}"}
      assert {:ok, normalized, bytes} = normalize(:record, item)
      assert bytes == byte_size(:erlang.term_to_binary(normalized, [:deterministic]))
    end
  end

  defp normalize(plane, item),
    do: dynamic_apply(Store, :normalize_and_measure_item, [plane, item])

  defp dynamic_apply(module, function, arguments), do: apply(module, function, arguments)

  defp sized_record(target) do
    empty = %{"body" => "", kind: "byte-boundary"}
    body_size = target - independent_size(empty)
    body = String.duplicate("x", body_size)
    normalized = %{"body" => body, kind: "byte-boundary"}

    assert independent_size(normalized) == target
    {body, %{"body" => body, kind: "byte-boundary"}}
  end

  defp sized_item(:record, target), do: sized_record(target)
  defp sized_item(:event, target), do: sized_event(target)

  defp sized_event(target) do
    empty = %{"body" => "", event_id: "byte-boundary", kind: "byte-boundary"}
    body_size = target - independent_size(empty)
    body = String.duplicate("x", body_size)
    event = %{"body" => body, event_id: "byte-boundary", kind: "byte-boundary"}
    normalized = %{"body" => body, event_id: "byte-boundary", kind: "byte-boundary"}

    assert independent_size(normalized) == target
    {body, event}
  end

  defp independent_size(normalized),
    do: byte_size(:erlang.term_to_binary(normalized, [:deterministic]))

  defp nested_value(0), do: "leaf"
  defp nested_value(depth), do: %{"next" => nested_value(depth - 1)}

  defp improper_list(count, tail) do
    Enum.reduce(1..count, tail, fn value, acc -> [value | acc] end)
  end
end
