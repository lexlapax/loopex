Code.require_file("check-m4-fixtures.exs", __DIR__)
ExUnit.start()

defmodule Loopex.M4FixtureCheckTest do
  use ExUnit.Case, async: true

  @source_schema "apps/loopex_protocol/priv/schema/loopex-experimental-1.json"
  @source_vectors "apps/loopex_protocol/priv/vectors/loopex-experimental-1.json"

  setup do
    dir = Path.join(System.tmp_dir!(), "loopex-m4-fixtures-#{System.unique_integer([:positive])}")
    File.mkdir!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    schema_path = Path.join(dir, "schema.json")
    vector_path = Path.join(dir, "vectors.json")
    File.cp!(@source_schema, schema_path)
    File.cp!(@source_vectors, vector_path)

    {:ok,
     schema_path: schema_path,
     vector_path: vector_path,
     schema: JSON.decode!(File.read!(@source_schema)),
     vectors: JSON.decode!(File.read!(@source_vectors))}
  end

  test "canonical fixtures pass", context do
    assert :ok == Loopex.M4FixtureCheck.check!(context.schema_path, context.vector_path)
  end

  test "a new event kind cannot be smuggled into the inventory", context do
    schema =
      update_in(
        context.schema,
        ["server_records", "event", "event_kind_enum"],
        &(&1 ++ ["unexpected.kind"])
      )

    write_schema!(context, schema)
    assert_raise ArgumentError, ~r/event kinds differs/, fn -> check!(context) end
  end

  test "the schema refuses a changed vector digest", context do
    vectors = update_in(context.vectors, ["cases"], &tl/1)
    File.write!(context.vector_path, JSON.encode!(vectors) <> "\n")
    assert_raise ArgumentError, ~r/vector digest does not match/, fn -> check!(context) end
  end

  test "rebinding a digest cannot hide a missing vector", context do
    vectors = update_in(context.vectors, ["cases"], &tl/1)
    write_pair!(context, context.schema, vectors)
    assert_raise ArgumentError, ~r/exactly 35 vectors/, fn -> check!(context) end
  end

  test "rebinding a digest cannot hide uppercase raw hex", context do
    changed = List.update_at(context.vectors["cases"], 0, &Map.put(&1, "raw_hex", "AA"))
    write_pair!(context, context.schema, Map.put(context.vectors, "cases", changed))
    assert_raise ArgumentError, ~r/raw_hex is not lowercase/, fn -> check!(context) end
  end

  test "rebinding a digest cannot erase the duplicate-key witness", context do
    changed =
      Enum.map(context.vectors["cases"], fn row ->
        if row["id"] == "duplicate_object_member" do
          {:ok, bytes} = Base.decode16(row["raw_hex"], case: :lower)

          single =
            String.replace(
              bytes,
              ~s("method":"initialize","method":"initialize",),
              ~s("method":"initialize",)
            )

          Map.put(row, "raw_hex", Base.encode16(single, case: :lower))
        else
          row
        end
      end)

    write_pair!(context, context.schema, Map.put(context.vectors, "cases", changed))
    assert_raise ArgumentError, ~r/lost its duplicate key/, fn -> check!(context) end
  end

  test "rebinding a digest cannot turn the EOF witness into an LF frame", context do
    changed =
      Enum.map(context.vectors["cases"], fn item ->
        if item["id"] == "eof_inside_frame",
          do: Map.update!(item, "raw_hex", &(&1 <> "0a")),
          else: item
      end)

    write_pair!(context, context.schema, Map.put(context.vectors, "cases", changed))
    assert_raise ArgumentError, ~r/eof_inside_frame has LF/, fn -> check!(context) end
  end

  defp check!(context), do: Loopex.M4FixtureCheck.check!(context.schema_path, context.vector_path)

  defp write_schema!(context, schema),
    do: File.write!(context.schema_path, JSON.encode!(schema) <> "\n")

  defp write_pair!(context, schema, vectors) do
    vector_bytes = JSON.encode!(vectors) <> "\n"
    digest = :crypto.hash(:sha256, vector_bytes) |> Base.encode16(case: :lower)
    File.write!(context.vector_path, vector_bytes)
    write_schema!(context, put_in(schema, ["vectors", "sha256"], digest))
  end
end
