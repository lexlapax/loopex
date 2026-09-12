defmodule Loopex.LLM.ReqLLM.ProviderCodec do
  @moduledoc """
  ## Concept

  The private data channel between the reference provider bridge and its
  same-build companion. Frames preserve plain candidate values so Core still
  makes the reply-validation and accounting decision.

  ## Technical depth

  An eight-byte header contains `LP`, version 2, a closed kind byte, and an
  unsigned big-endian payload length. The payload uses only explicit scalar,
  list, map, and map-key tags; it is never an external Erlang term. Binaries
  retain arbitrary bytes, integers retain sign and magnitude, and floats retain
  their IEEE bits. Atom keys remain distinct from binary keys. Decoding an atom
  key can resolve an existing atom but cannot create one. Fixed tags cover the
  three progress-kind atom values; all other atom values are refused.

  The bridge owns correlation, ordering, and one-invocation state. This module
  validates exact envelope fields, scalar identities, structural bounds, and
  finite encoded lengths. Codec failure is a transport failure, never the
  shared raw-admission `unreadable` verdict.

  The Store's 65,536-byte measure uses normalized keys and external-term size.
  Every scalar/key here costs at most seven times its corresponding measured
  component; empty lists cost three bytes instead of one. In particular, an
  external-term byte list costs about one byte per member, while this codec
  costs seven. A factor of eight therefore covers every admitted tree including
  byte lists, with no encoding overhead charged against semantic admission.
  Requests and progress reserve eight times their independent semantic bound.
  Terminal replies reserve that body bound plus *two* separately bounded binary
  request echoes, each with five bytes of framing. All kinds add 4,096 bytes for
  the fixed envelope. Credential bytes have their separate exact 65,536 limit.
  The root envelope adds one level to Store depth 12. Only the terminal reply's
  root may add two echo members to Store's 1,024-member bound.

  Socket callers supply passive, raw, binary AF_UNIX sockets and own their
  lifetime and send timeout. Receive reads at most 4,096 bytes at a time, after
  validating the header, and spends one monotonic deadline across all reads.
  A caller must retire the channel after any error; partial bytes are not a
  recoverable second invocation.
  """

  @version 2
  @failure_stages ~w(handoff stream metadata completion assembly calls)
  @failure_classes ~w(stream_http_auth stream_http_rate_limit stream_http_server
    stream_http_status stream_transport_timeout stream_transport_tls stream_transport_error
    stream_http_protocol_error stream_finch_error stream_http_task_failed stream_wait_timeout
    stream_task_call_timeout stream_decode_error stream_other_error genserver_timeout
    raised exited thrown caught provider_status stream_failed stream_incomplete
    assembly_failed returned_error unclassified)
  @failure_bytes 256
  @semantic_bytes 65_536
  @envelope_bytes 4_096
  @fragment_bytes 4_096
  @receive_slice_ms 3_600_000
  @max_depth 13
  @max_members 1_024
  @max_key_bytes 256
  @kinds [:bootstrap, :ready, :credential, :invocation, :dispatch_started, :delta, :terminal]
  @kind_codes @kinds |> Enum.with_index(1) |> Map.new()
  @code_kinds Map.new(@kind_codes, fn {kind, code} -> {code, kind} end)
  @progress_atoms %{text_delta: 8, reasoning_delta: 9, tool_call_delta: 10}
  @progress_codes Map.new(@progress_atoms, fn {atom, code} -> {code, atom} end)
  @known_key_atoms ~w(canonicalization_version model messages tools sampling deadline
    continuation canonical_request_bytes staged_request_digest text identity usage
    tool_calls delta_count streamed provider_response_id provider endpoint input_tokens
    output_tokens kind content_index call_index tool_call_id name arguments_fragment
    arguments id role content type tool_id tool_version definition_digest description
    parameter_schema result_shape effect_class idempotency_class executor_requirements
    budgets wall_time_ms output_bytes artifact_bytes max_tokens temperature top_p
    properties required enum items content_type)a
  @known_keys Map.new(@known_key_atoms, fn key -> {Atom.to_string(key), key} end)

  @doc false
  def version, do: @version

  @doc false
  def cap(kind) when kind in [:bootstrap, :ready, :dispatch_started], do: @envelope_bytes
  def cap(:credential), do: @semantic_bytes + @envelope_bytes
  def cap(:invocation), do: 8 * @semantic_bytes + @semantic_bytes + 5 + @envelope_bytes
  def cap(:delta), do: 8 * @semantic_bytes + @envelope_bytes
  def cap(:terminal), do: 8 * @semantic_bytes + 2 * (@semantic_bytes + 5) + @envelope_bytes
  def cap(_kind), do: 0

  @doc false
  def encode(kind, payload) do
    with {:ok, code} <- Map.fetch(@kind_codes, kind),
         true <- valid_payload?(kind, payload),
         {:ok, encoded, left} <- encode_value(payload, 0, cap(kind), kind),
         length = cap(kind) - left do
      {:ok, IO.iodata_to_binary([<<"LP", @version, code, length::32>>, encoded])}
    else
      _other -> {:error, :invalid_frame}
    end
  end

  @doc false
  def decode(<<header::binary-size(8), payload::binary>>) do
    with {:ok, kind, length} <- header(header),
         true <- byte_size(payload) == length do
      decode_payload(kind, payload)
    else
      _other -> {:error, :invalid_frame}
    end
  end

  def decode(_frame), do: {:error, :invalid_frame}

  @doc false
  def recv(socket, timeout) when is_integer(timeout) and timeout >= 0 do
    deadline = System.monotonic_time() + System.convert_time_unit(timeout, :millisecond, :native)

    with :ok <- raw_socket(socket),
         {:ok, header} <- receive_bytes(socket, 8, deadline, []),
         {:ok, kind, length} <- header(header),
         {:ok, payload} <- receive_bytes(socket, length, deadline, []) do
      decode_payload(kind, payload)
    end
  catch
    _class, _reason -> {:error, :invalid_frame}
  end

  def recv(_socket, _timeout), do: {:error, :invalid_frame}

  @doc false
  def send(socket, kind, payload) do
    with {:ok, frame} <- encode(kind, payload) do
      case :gen_tcp.send(socket, frame) do
        :ok -> :ok
        {:error, :closed} -> {:error, :closed}
        {:error, :timeout} -> {:error, :timeout}
        {:error, {:timeout, _remaining_bytes}} -> {:error, :timeout}
        _other -> {:error, :invalid_frame}
      end
    end
  catch
    _class, _reason -> {:error, :invalid_frame}
  end

  defp header(<<"LP", @version, code, length::32>>) do
    with {:ok, kind} <- Map.fetch(@code_kinds, code),
         true <- length > 0 and length <= cap(kind) do
      {:ok, kind, length}
    else
      _other -> {:error, :invalid_frame}
    end
  end

  defp header(_header), do: {:error, :invalid_frame}

  defp raw_socket(socket) do
    case :inet.getopts(socket, [:active, :packet, :mode]) do
      {:ok, [active: false, packet: packet, mode: :binary]} when packet in [0, :raw] -> :ok
      _other -> {:error, :invalid_frame}
    end
  end

  defp receive_bytes(_socket, 0, _deadline, chunks),
    do: {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary()}

  defp receive_bytes(socket, remaining, deadline, chunks) do
    timeout = remaining_timeout(deadline, System.monotonic_time())

    if timeout <= 0 do
      {:error, :timeout}
    else
      amount = min(remaining, @fragment_bytes)

      # Concept: a distant declared deadline remains usable by the socket.
      # Technical depth: each VM timer is capped independently of the caller's
      # integer deadline. A slice timeout retains the accumulated bytes and
      # the original deadline; the next iteration spends only what remains.
      case :gen_tcp.recv(socket, amount, min(timeout, @receive_slice_ms)) do
        {:ok, bytes} when is_binary(bytes) and byte_size(bytes) == amount ->
          receive_bytes(socket, remaining - amount, deadline, [bytes | chunks])

        {:error, :timeout} ->
          receive_bytes(socket, remaining, deadline, chunks)

        {:error, :closed} ->
          {:error, :closed}

        _other ->
          {:error, :invalid_frame}
      end
    end
  end

  # Concept: a positive part of the remaining interval is still usable time.
  # Technical depth: retain absolute instants in native units and round only
  # the socket's integer-millisecond wait upward. Flooring either the sampled
  # instant or its final remainder can return timeout before the actual bound.
  # The same production arithmetic serves the bridge's invocation receiver;
  # each codec slice still checks the original deadline, never a fresh budget.
  @doc false
  def remaining_timeout(deadline, sampled_now)
      when is_integer(deadline) and is_integer(sampled_now) do
    remaining = deadline - sampled_now

    if remaining <= 0 do
      0
    else
      milliseconds = System.convert_time_unit(remaining, :native, :millisecond)

      if System.convert_time_unit(milliseconds, :millisecond, :native) < remaining do
        milliseconds + 1
      else
        milliseconds
      end
    end
  end

  defp decode_payload(kind, bytes) do
    with {:ok, payload, <<>>} <- decode_value(bytes, 0, kind),
         true <- valid_payload?(kind, payload) do
      {:ok, kind, payload}
    else
      _other -> {:error, :invalid_frame}
    end
  end

  defp valid_payload?(kind, payload) when is_map(payload) and not is_struct(payload) do
    identity?(payload["nonce"]) and valid_fields?(kind, payload)
  end

  defp valid_payload?(_kind, _payload), do: false

  defp valid_fields?(kind, payload) when kind in [:bootstrap, :ready] do
    exact_keys?(payload, ~w(nonce version build_manifest_sha256)) and
      payload["version"] == @version and identity?(payload["build_manifest_sha256"])
  end

  defp valid_fields?(:credential, payload) do
    exact_keys?(payload, ~w(nonce credential)) and bounded_binary?(payload["credential"], 1)
  end

  defp valid_fields?(:invocation, payload) do
    exact_keys?(payload, ~w(nonce request canonical_request_bytes staged_request_digest)) and
      identity?(payload["staged_request_digest"]) and
      bounded_binary?(payload["canonical_request_bytes"], 0) and
      is_map(payload["request"]) and not is_struct(payload["request"])
  end

  defp valid_fields?(:dispatch_started, payload) do
    exact_keys?(payload, ~w(nonce staged_request_digest)) and
      identity?(payload["staged_request_digest"])
  end

  defp valid_fields?(:delta, payload) do
    exact_keys?(payload, ~w(nonce staged_request_digest payload)) and
      identity?(payload["staged_request_digest"]) and is_map(payload["payload"])
  end

  defp valid_fields?(:terminal, payload) do
    identity?(payload["staged_request_digest"]) and
      case payload["status"] do
        "reply" ->
          exact_keys?(payload, ~w(nonce staged_request_digest status reply)) and
            is_map(payload["reply"]) and not is_struct(payload["reply"]) and
            bounded_echoes?(payload["reply"])

        "dispatched_or_unknown" ->
          exact_keys?(payload, ~w(nonce staged_request_digest status failure)) and
            valid_failure?(payload["failure"])

        status when status in ["not_dispatched", "unreadable"] ->
          exact_keys?(payload, ~w(nonce staged_request_digest status))

        _other ->
          false
      end
  end

  defp valid_fields?(_kind, _payload), do: false

  defp valid_failure?(%{"stage" => stage, "class" => class} = failure)
       when map_size(failure) == 2 do
    ((stage in @failure_stages and class in @failure_classes) or
       (stage == "unavailable" and class == "unclassified")) and
      match?({:ok, _, _}, encode_value(failure, 0, @failure_bytes, :terminal))
  end

  defp valid_failure?(_failure), do: false

  defp exact_keys?(payload, expected) do
    map_size(payload) == length(expected) and Enum.all?(expected, &Map.has_key?(payload, &1))
  end

  defp identity?(value) when is_binary(value) and byte_size(value) == 64 do
    value |> :binary.bin_to_list() |> Enum.all?(&(&1 in ?0..?9 or &1 in ?a..?f))
  end

  defp identity?(_value), do: false

  defp bounded_binary?(value, minimum),
    do: is_binary(value) and byte_size(value) >= minimum and byte_size(value) <= @semantic_bytes

  defp bounded_echoes?(reply) do
    Enum.all?([:canonical_request_bytes, "canonical_request_bytes"], fn key ->
      case Map.fetch(reply, key) do
        :error -> true
        {:ok, value} -> bounded_binary?(value, 0)
      end
    end)
  end

  defp encode_value(_value, depth, left, _kind) when depth > @max_depth or left <= 0,
    do: :invalid

  defp encode_value(nil, _depth, left, _kind), do: {:ok, <<0>>, left - 1}
  defp encode_value(false, _depth, left, _kind), do: {:ok, <<1>>, left - 1}
  defp encode_value(true, _depth, left, _kind), do: {:ok, <<2>>, left - 1}

  defp encode_value(value, _depth, left, _kind) when is_binary(value) do
    size = byte_size(value)

    if size <= @semantic_bytes and size + 5 <= left,
      do: {:ok, [<<3, size::32>>, value], left - size - 5},
      else: :invalid
  end

  defp encode_value(value, _depth, left, _kind) when is_integer(value) do
    if :erlang.external_size(value) <= @semantic_bytes do
      magnitude = :binary.encode_unsigned(abs(value))
      size = byte_size(magnitude)
      sign = if value < 0, do: 1, else: 0

      if size + 6 <= left,
        do: {:ok, [<<4, sign, size::32>>, magnitude], left - size - 6},
        else: :invalid
    else
      :invalid
    end
  end

  defp encode_value(value, _depth, left, _kind) when is_float(value) and left >= 9,
    do: {:ok, <<5, value::float-big-64>>, left - 9}

  defp encode_value(value, depth, left, kind) when is_list(value) and left >= 3 do
    with {:ok, size} <- list_size(value, 0),
         {:ok, members, remaining} <- encode_members(value, depth, left - 3, kind, []) do
      {:ok, [<<6, size::16>>, members], remaining}
    end
  end

  defp encode_value(value, depth, left, kind)
       when is_map(value) and not is_struct(value) and left >= 3 do
    if map_size(value) <= map_limit(kind, depth) do
      with {:ok, members, remaining} <- encode_pairs(value, depth, left - 3, kind) do
        {:ok, [<<7, map_size(value)::16>>, members], remaining}
      end
    else
      :invalid
    end
  end

  defp encode_value(value, _depth, left, :delta) when is_map_key(@progress_atoms, value),
    do: {:ok, <<Map.fetch!(@progress_atoms, value)>>, left - 1}

  defp encode_value(_value, _depth, _left, _kind), do: :invalid

  defp list_size(_value, counted) when counted > @max_members, do: :invalid
  defp list_size([], counted), do: {:ok, counted}
  defp list_size([_head | tail], counted), do: list_size(tail, counted + 1)
  defp list_size(_value, _counted), do: :invalid

  defp encode_members([], _depth, left, _kind, members),
    do: {:ok, Enum.reverse(members), left}

  defp encode_members([head | tail], depth, left, kind, members) do
    with {:ok, member, remaining} <- encode_value(head, depth + 1, left, kind) do
      encode_members(tail, depth, remaining, kind, [member | members])
    end
  end

  defp encode_pairs(value, depth, left, kind) do
    Enum.reduce_while(value, {:ok, [], left}, fn {key, member}, {:ok, pairs, budget} ->
      with {:ok, encoded_key, remaining} <- encode_key(key, budget),
           {:ok, encoded_value, remaining} <- encode_value(member, depth + 1, remaining, kind) do
        {:cont, {:ok, [[encoded_key, encoded_value] | pairs], remaining}}
      else
        _other -> {:halt, :invalid}
      end
    end)
  end

  defp encode_key(key, left) when is_atom(key), do: encode_key(1, Atom.to_string(key), left)
  defp encode_key(key, left) when is_binary(key), do: encode_key(0, key, left)
  defp encode_key(_key, _left), do: :invalid

  defp encode_key(tag, key, left) do
    size = byte_size(key)

    if size in 1..@max_key_bytes and size + 3 <= left,
      do: {:ok, [<<tag, size::16>>, key], left - size - 3},
      else: :invalid
  end

  defp decode_value(_bytes, depth, _kind) when depth > @max_depth, do: :invalid
  defp decode_value(<<0, rest::binary>>, _depth, _kind), do: {:ok, nil, rest}
  defp decode_value(<<1, rest::binary>>, _depth, _kind), do: {:ok, false, rest}
  defp decode_value(<<2, rest::binary>>, _depth, _kind), do: {:ok, true, rest}

  defp decode_value(<<3, size::32, rest::binary>>, _depth, _kind)
       when size <= @semantic_bytes and byte_size(rest) >= size do
    {value, tail} = :erlang.split_binary(rest, size)
    {:ok, value, tail}
  end

  defp decode_value(<<4, sign, size::32, rest::binary>>, _depth, _kind)
       when sign in [0, 1] and size > 0 and size <= @semantic_bytes and byte_size(rest) >= size do
    {magnitude, tail} = :erlang.split_binary(rest, size)

    if (size == 1 or :binary.first(magnitude) != 0) and not (sign == 1 and magnitude == <<0>>) do
      value = :binary.decode_unsigned(magnitude)
      {:ok, if(sign == 1, do: -value, else: value), tail}
    else
      :invalid
    end
  end

  defp decode_value(<<5, value::float-big-64, rest::binary>>, _depth, _kind),
    do: {:ok, value, rest}

  defp decode_value(<<6, count::16, rest::binary>>, depth, kind) when count <= @max_members,
    do: decode_members(rest, count, depth, kind, [])

  defp decode_value(<<7, count::16, rest::binary>>, depth, kind) do
    if count <= map_limit(kind, depth),
      do: decode_pairs(rest, count, depth, kind, %{}),
      else: :invalid
  end

  defp decode_value(<<code, rest::binary>>, _depth, :delta)
       when is_map_key(@progress_codes, code),
       do: {:ok, Map.fetch!(@progress_codes, code), rest}

  defp decode_value(_bytes, _depth, _kind), do: :invalid

  defp decode_members(bytes, 0, _depth, _kind, values),
    do: {:ok, Enum.reverse(values), bytes}

  defp decode_members(bytes, count, depth, kind, values) do
    with {:ok, value, rest} <- decode_value(bytes, depth + 1, kind) do
      decode_members(rest, count - 1, depth, kind, [value | values])
    end
  end

  defp decode_pairs(bytes, 0, _depth, _kind, values) when not is_struct(values),
    do: {:ok, values, bytes}

  defp decode_pairs(bytes, count, depth, kind, values) when count > 0 do
    with {:ok, key, rest} <- decode_key(bytes),
         false <- Map.has_key?(values, key),
         {:ok, value, rest} <- decode_value(rest, depth + 1, kind) do
      decode_pairs(rest, count - 1, depth, kind, Map.put(values, key, value))
    else
      _other -> :invalid
    end
  end

  defp decode_pairs(_bytes, _count, _depth, _kind, _values), do: :invalid

  defp decode_key(<<tag, size::16, rest::binary>>)
       when tag in [0, 1] and size in 1..@max_key_bytes and byte_size(rest) >= size do
    {name, tail} = :erlang.split_binary(rest, size)

    case tag do
      0 -> {:ok, name, tail}
      1 -> {:ok, existing_key(name), tail}
    end
  rescue
    ArgumentError -> :invalid
  end

  defp decode_key(_bytes), do: :invalid

  defp existing_key(name) do
    case Map.fetch(@known_keys, name) do
      {:ok, key} -> key
      :error -> :erlang.binary_to_existing_atom(name, :utf8)
    end
  end

  defp map_limit(:terminal, 1), do: @max_members + 2
  defp map_limit(_kind, _depth), do: @max_members
end
