# Concept: Prove that the proposed M4 wire fixtures are intact before acceptance.
# Technical depth: Behavioral conformance belongs to the later protocol tests.
defmodule Loopex.M4FixtureCheck do
  @schema "apps/loopex_protocol/priv/schema/loopex-experimental-1.json"
  @vectors "apps/loopex_protocol/priv/vectors/loopex-experimental-1.json"
  @methods ~w(session.create session.resume session.inspect session.attach session.prompt session.steer session.follow_up session.abort session.respond_interaction resources.catalog resources.read session.admit_resources session.activate_skill artifact.open_transfer artifact.read_chunk artifact.close_transfer)
  @records ~w(initialized result admission snapshot event progress error)
  @events ~w(user.message_appended run.started assistant.message_appended tool.started tool.finished run.finished steer.resolved follow_up.resolved session.settled interaction.requested interaction.resolved interaction.expired interaction.cancelled)
  @progress ~w(text_delta reasoning_delta tool_call_delta tool_progress model_stream_closed tool_stream_closed)
  @unavailable ~w(session.list project_resources.inspect project_resources.decide)
  @malformed ~w(invalid_utf8 crlf_delimiter top_level_array trailing_bytes_before_lf eof_inside_frame)

  def check!(schema_path \\ @schema, vector_path \\ @vectors) do
    {schema, _} = read_json!(schema_path, "schema")
    {vectors, vector_bytes} = read_json!(vector_path, "vectors")
    check_schema!(schema, vector_bytes)
    check_vectors!(vectors, schema)
    :ok
  end

  def run!(schema_path \\ @schema, vector_path \\ @vectors) do
    check!(schema_path, vector_path)

    IO.puts(
      "M4 fixture integrity OK: 16 methods, 7 records, 13 events, 6 progress kinds, 35 vectors"
    )
  end

  defp read_json!(path, label) do
    bytes = File.read!(path)

    ensure(
      String.ends_with?(bytes, "\n") and not String.contains?(bytes, "\r"),
      "#{label} must be LF-terminated"
    )

    ensure(
      String.valid?(bytes) and :binary.bin_to_list(bytes) |> Enum.all?(&(&1 < 128)),
      "#{label} must be ASCII JSON"
    )

    value = Jason.decode!(bytes)
    ensure(is_map(value), "#{label} must be a JSON object")
    {value, bytes}
  end

  defp check_schema!(schema, vector_bytes) do
    ensure(
      schema["format"] == "loopex.experimental.contract-manifest/1" and
        schema["generation"] == "loopex.experimental/1" and
        schema["status"] == "proposed_contract_candidate",
      "schema identity changed"
    )

    same_set!(schema["methods_declared"], @methods, "methods")

    same_set!(
      Map.keys(map!(schema["request_contract"]["methods"], "request methods")),
      ["initialize" | @methods],
      "request methods"
    )

    same_set!(schema["server_record_type_enum"], @records, "record types")
    records = map!(schema["server_records"], "server records")
    same_set!(Map.keys(records), @records, "server records")
    same_set!(records["event"]["event_kind_enum"], @events, "event kinds")

    same_set!(
      Map.keys(map!(schema["inherited_m3_event_data_by_kind"], "M3 event data")),
      Enum.take(@events, 8),
      "M3 event data"
    )

    same_set!(
      Map.keys(map!(schema["m4_event_data_by_kind"], "M4 event data")),
      Enum.drop(@events, 8),
      "M4 event data"
    )

    same_set!(records["progress"]["progress_kind_enum"], @progress, "progress kinds")

    same_set!(
      Map.keys(map!(schema["progress_payloads_by_kind"], "progress payloads")),
      @progress,
      "progress payloads"
    )

    unavailable = list!(schema["methods_unavailable_in_generation"], "unavailable methods")
    same_set!(Enum.map(unavailable, & &1["method"]), @unavailable, "unavailable methods")

    ensure(
      Enum.all?(unavailable, fn row -> is_binary(row["reason"]) and row["reason"] != "" end),
      "unavailable method lacks reason"
    )

    binding = map!(schema["vectors"], "vector binding")
    ensure(binding["path"] == @vectors, "vector path changed")

    ensure(
      is_binary(binding["sha256"]) and
        Regex.match?(~r/\A[0-9a-f]{64}\z/, binding["sha256"]),
      "vector digest malformed"
    )

    digest = :crypto.hash(:sha256, vector_bytes) |> Base.encode16(case: :lower)
    ensure(binding["sha256"] == digest, "schema vector digest does not match vector bytes")
  end

  defp check_vectors!(vectors, schema) do
    ensure(
      vectors["format"] == "loopex.experimental.hex-vectors/1" and
        vectors["generation"] == schema["generation"] and
        vectors["status"] == "proposed_acceptance_candidate" and
        vectors["encoding"] == "lowercase_hex_of_exact_wire_bytes",
      "vector identity changed"
    )

    cases = list!(vectors["cases"], "vector cases")
    ensure(length(cases) == 35, "expected exactly 35 vectors")
    ids = Enum.map(cases, & &1["id"])

    ensure(
      Enum.all?(ids, fn id -> is_binary(id) and Regex.match?(~r/\A[a-z][a-z0-9_]*\z/, id) end) and
        length(Enum.uniq(ids)) == 35,
      "vector IDs are malformed or repeated"
    )

    ensure(Enum.all?(@malformed, &(&1 in ids)), "malformed-frame witness missing")

    ensure(
      Enum.count(cases, &(&1["direction"] == "client_to_server")) == 21 and
        Enum.count(cases, &(&1["direction"] == "server_to_client")) == 14,
      "vector directions changed"
    )

    Enum.each(cases, fn row ->
      id = row["id"]

      ensure(
        is_binary(row["initial_state"]) and row["initial_state"] != "" and
          is_binary(row["expect"]) and row["expect"] != "",
        "#{id} lacks state or expectation"
      )

      case frame!(row) do
        nil -> ensure(id in @malformed, "#{id} is unexpectedly malformed")
        message -> check_record!(row, message)
      end
    end)
  end

  defp frame!(row) do
    id = row["id"]
    hex = row["raw_hex"]

    ensure(
      is_binary(hex) and rem(byte_size(hex), 2) == 0 and
        Regex.match?(~r/\A[0-9a-f]+\z/, hex),
      "#{id} raw_hex is not lowercase even-length hex"
    )

    {:ok, bytes} = Base.decode16(hex, case: :lower)

    case id do
      "eof_inside_frame" ->
        ensure(not String.ends_with?(bytes, "\n"), "eof_inside_frame has LF")
        nil

      "crlf_delimiter" ->
        ensure(String.ends_with?(bytes, "\r\n"), "crlf_delimiter lacks CRLF")
        nil

      _ ->
        ensure(
          String.ends_with?(bytes, "\n") and not String.ends_with?(bytes, "\r\n"),
          "#{id} lacks LF-only frame"
        )

        payload = binary_part(bytes, 0, byte_size(bytes) - 1)
        ensure(not String.contains?(payload, "\n"), "#{id} contains two frames")

        case id do
          "invalid_utf8" ->
            ensure(not String.valid?(payload), "invalid_utf8 now decodes")
            nil

          "trailing_bytes_before_lf" ->
            ensure(match?({:error, _}, Jason.decode(payload)), "trailing bytes now parse")
            nil

          "top_level_array" ->
            ensure(is_list(Jason.decode!(payload)), "top_level_array is not an array")
            nil

          _ ->
            ensure(String.valid?(payload), "#{id} contains invalid UTF-8")

            if id == "duplicate_object_member" do
              ensure(
                length(Regex.scan(~r/"method"\s*:/, payload)) == 2,
                "duplicate_object_member lost its duplicate key"
              )
            end

            ensure(is_map(Jason.decode!(payload)), "#{id} is not a JSON object")
            Jason.decode!(payload)
        end
    end
  end

  defp check_record!(row, message) do
    id = row["id"]

    if row["direction"] == "client_to_server" do
      ensure(
        is_binary(message["request_id"]) and
          message["method"] in (["initialize" | @methods] ++ @unavailable),
        "#{id} request method or ID is invalid"
      )
    else
      ensure(message["type"] in @records, "#{id} server record type is invalid")

      if message["type"] == "event",
        do: ensure(message["event"]["kind"] in @events, "#{id} event kind is invalid")

      if message["type"] == "progress",
        do: ensure(message["progress"]["kind"] in @progress, "#{id} progress kind is invalid")
    end
  end

  defp map!(value, label) do
    ensure(is_map(value), "#{label} must be an object")
    value
  end

  defp list!(value, label) do
    ensure(is_list(value), "#{label} must be an array")
    value
  end

  defp same_set!(actual, expected, label) do
    values = list!(actual, label)

    ensure(
      length(values) == length(expected) and length(Enum.uniq(values)) == length(values) and
        Enum.sort(values) == Enum.sort(expected),
      "#{label} differs from locked inventory"
    )
  end

  defp ensure(true, _message), do: :ok
  defp ensure(false, message), do: raise(ArgumentError, message)
end
