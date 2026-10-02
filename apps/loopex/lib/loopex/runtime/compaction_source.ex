defmodule Loopex.Runtime.CompactionSource do
  @moduledoc """
  ## Concept

  A summarizer receives committed conversation data, with explicit evidence of
  any omitted middle. It receives no system message or private provider data.

  ## Technical depth

  ADR 0043's source-v2 envelope uses ADR 0042's compact sorted-key UTF-8 JSON.
  This encoder traverses caller-supplied canonical messages once. It hashes and
  counts every encoded byte, retaining a complete candidate only up to 16,384
  bytes and two end buffers of at most 4,099 bytes each. Encoding chunks are at
  most 1,030 bytes. The caller's check runs before each chunk, allowing traversal
  to spend its owning episode's deadline and cancellation budget.

  Complete-unit selection and complete maintenance-request preflight belong to
  the session owner. The owner chooses complete or excerpt form before calling;
  excerpt candidates arrive in the fixed 4,096, 2,048, 1,024, 512 quota order.
  A source-cap fit alone never authorizes provider dispatch. Prior checkpoint
  data is supplied from validated replay and appears once in each envelope.
  """

  alias LoopexProtocol.{Canonical, Frame}

  @cap 16_384
  @end_cap 4_099
  @quotas [4_096, 2_048, 1_024, 512]
  @uint64 18_446_744_073_709_551_615

  @doc false
  @spec encode(Enumerable.t(), map() | nil, :complete | :excerpt, (-> :ok | {:error, atom()})) ::
          {:ok, [map()]} | {:error, atom()}
  def encode(messages, prior, form, check)
      when form in [:complete, :excerpt] and is_function(check, 0) do
    with true <- not is_nil(Enumerable.impl_for(messages)),
         :ok <- valid_prior(prior),
         {:ok, scanned} <- scan(messages, check) do
      case form do
        :complete -> complete(scanned, prior)
        :excerpt -> excerpts(scanned, prior)
      end
    else
      {:error, _} = error -> error
      _invalid -> {:error, :context_projection_invalid}
    end
  end

  def encode(_, _, _, _), do: {:error, :context_projection_invalid}

  defp scan(messages, check) do
    initial = %{count: 0, hash: :crypto.hash_init(:sha256), complete: "", prefix: "", suffix: ""}

    with {:ok, initial} <- consume("[", initial, check),
         {:ok, scanned, false} <-
           Enum.reduce_while(messages, {:ok, initial, true}, fn message, {:ok, acc, first?} ->
             with true <- canonical_message?(message),
                  {:ok, acc} <- consume(if(first?, do: "", else: ","), acc, check),
                  {:ok, acc} <- value(message, acc, check, 1) do
               {:cont, {:ok, acc, false}}
             else
               {:error, _} = error -> {:halt, error}
               _invalid -> {:halt, {:error, :context_projection_invalid}}
             end
           end),
         {:ok, scanned} <- consume("]", scanned, check) do
      {:ok,
       Map.put(scanned, :digest, Base.encode16(:crypto.hash_final(scanned.hash), case: :lower))}
    else
      {:error, _} = error -> error
      _empty -> {:error, :context_projection_invalid}
    end
  end

  defp canonical_message?(%{"role" => "user", "content" => text} = message),
    do: map_size(message) == 2 and is_binary(text)

  defp canonical_message?(
         %{"role" => "assistant", "content" => text, "tool_calls" => calls} = message
       ),
       do:
         map_size(message) == 3 and is_binary(text) and is_list(calls) and
           Enum.all?(calls, &canonical_call?/1)

  defp canonical_message?(
         %{"role" => "tool", "content" => text, "tool_call_id" => call, "outcome" => outcome} =
           message
       ),
       do:
         map_size(message) == 4 and is_binary(text) and is_binary(call) and
           outcome in ~w(completed failed denied cancelled outcome_unknown)

  defp canonical_message?(_), do: false

  defp canonical_call?(
         %{
           "tool_call_id" => call,
           "tool_id" => id,
           "tool_version" => version,
           "definition_digest" => digest,
           "arguments" => arguments
         } = value
       ),
       do:
         map_size(value) == 5 and is_binary(call) and call != "" and is_binary(id) and
           is_binary(version) and is_binary(digest) and is_map(arguments)

  defp canonical_call?(
         %{"tool_call_id" => call, "name" => name, "arguments" => arguments} = value
       ),
       do:
         map_size(value) == 3 and is_binary(call) and call != "" and is_binary(name) and
           is_map(arguments)

  defp canonical_call?(_), do: false

  defp value(value, acc, check, depth)
       when is_map(value) and not is_struct(value) and depth <= 16 do
    members = Enum.sort_by(value, &elem(&1, 0))

    if Enum.all?(members, fn {key, _} -> is_binary(key) end) do
      with {:ok, acc} <- consume("{", acc, check),
           {:ok, acc} <-
             separated(members, acc, check, fn {key, member}, acc ->
               with {:ok, acc} <- value(key, acc, check, depth + 1),
                    {:ok, acc} <- consume(":", acc, check),
                    do: value(member, acc, check, depth + 1)
             end),
           do: consume("}", acc, check)
    else
      {:error, :context_projection_invalid}
    end
  end

  defp value(values, acc, check, depth) when is_list(values) and depth <= 16 do
    with {:ok, acc} <- consume("[", acc, check),
         {:ok, acc} <- separated(values, acc, check, &value(&1, &2, check, depth + 1)),
         do: consume("]", acc, check)
  end

  defp value(text, acc, check, _depth) when is_binary(text) do
    with {:ok, acc} <- consume("\"", acc, check),
         {:ok, acc} <- string(text, [], 0, acc, check),
         do: consume("\"", acc, check)
  end

  defp value(true, acc, check, _depth), do: consume("true", acc, check)
  defp value(false, acc, check, _depth), do: consume("false", acc, check)
  defp value(nil, acc, check, _depth), do: consume("null", acc, check)

  defp value(number, acc, check, _depth) when is_integer(number),
    do: number_chunks(Integer.to_string(number), acc, check)

  defp value(number, acc, check, _depth) when is_float(number),
    do: consume(:erlang.float_to_binary(number, [:short]), acc, check)

  defp value(_, _, _, _), do: {:error, :context_projection_invalid}

  defp number_chunks(bytes, acc, check) when byte_size(bytes) > 1_024 do
    <<chunk::binary-size(1_024), rest::binary>> = bytes
    with {:ok, acc} <- consume(chunk, acc, check), do: number_chunks(rest, acc, check)
  end

  defp number_chunks(bytes, acc, check), do: consume(bytes, acc, check)

  defp separated(values, acc, check, encode) do
    Enum.reduce_while(values, {:ok, acc, true}, fn member, {:ok, acc, first?} ->
      with {:ok, acc} <- consume(if(first?, do: "", else: ","), acc, check),
           {:ok, acc} <- encode.(member, acc) do
        {:cont, {:ok, acc, false}}
      else
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, acc, _first} -> {:ok, acc}
      error -> error
    end
  end

  defp string(rest, chunks, size, acc, check) when size >= 1_024 do
    with {:ok, acc} <- consume(chunks |> Enum.reverse() |> IO.iodata_to_binary(), acc, check),
         do: string(rest, [], 0, acc, check)
  end

  defp string("", chunks, _size, acc, check),
    do: consume(chunks |> Enum.reverse() |> IO.iodata_to_binary(), acc, check)

  defp string(<<character::utf8, rest::binary>>, chunks, size, acc, check) do
    encoded = escape(character)
    string(rest, [encoded | chunks], size + byte_size(encoded), acc, check)
  end

  defp string(_, _, _, _, _), do: {:error, :context_projection_invalid}

  defp escape(?"), do: "\\\""
  defp escape(?\\), do: "\\\\"
  defp escape(?\b), do: "\\b"
  defp escape(?\f), do: "\\f"
  defp escape(?\n), do: "\\n"
  defp escape(?\r), do: "\\r"
  defp escape(?\t), do: "\\t"

  defp escape(code) when code < 32,
    do:
      "\\u" <> (code |> Integer.to_string(16) |> String.pad_leading(4, "0") |> String.downcase())

  defp escape(code), do: <<code::utf8>>

  defp consume("", acc, _check), do: {:ok, acc}

  defp consume(bytes, acc, check) do
    with :ok <- check.(),
         count = acc.count + byte_size(bytes),
         true <- count <= @uint64 do
      joined = acc.suffix <> bytes

      suffix =
        binary_part(
          joined,
          max(0, byte_size(joined) - @end_cap),
          min(@end_cap, byte_size(joined))
        )

      prefix_room = @end_cap - byte_size(acc.prefix)
      prefix = acc.prefix <> binary_part(bytes, 0, min(prefix_room, byte_size(bytes)))
      complete = if count <= @cap, do: acc.complete <> bytes, else: nil

      {:ok,
       %{
         acc
         | count: count,
           hash: :crypto.hash_update(acc.hash, bytes),
           complete: complete,
           prefix: :binary.copy(prefix),
           suffix: :binary.copy(suffix)
       }}
    else
      {:error, _} = error -> error
      _invalid -> {:error, :context_projection_invalid}
    end
  end

  defp complete(%{complete: nil}, _prior), do: {:ok, []}

  defp complete(scanned, prior) do
    # Concept: complete source contains the exact stream, without a second copy of its messages.
    # Technical depth: the fragments below preserve sorted envelope/member keys;
    # the embedded value is already canonical JSON, never parsed and re-encoded.
    bytes =
      "{\"messages\":{\"kind\":\"complete\",\"value\":" <>
        scanned.complete <>
        "},\"prior_checkpoint\":" <>
        json(prior) <> ",\"version\":\"loopex.compaction.source.v2\"}"

    {:ok, if(byte_size(bytes) <= @cap, do: [candidate(bytes, false, nil)], else: [])}
  end

  defp excerpts(scanned, prior) do
    candidates =
      Enum.flat_map(@quotas, fn quota ->
        with prefix when is_binary(prefix) <- fragment(scanned.prefix, quota, :prefix),
             suffix when is_binary(suffix) <- fragment(scanned.suffix, quota, :suffix),
             offset = scanned.count - byte_size(suffix),
             true <- offset > byte_size(prefix) do
          bytes =
            json(%{
              "version" => "loopex.compaction.source.v2",
              "prior_checkpoint" => prior,
              "messages" => %{
                "kind" => "serialized_excerpt",
                "encoding" => "loopex.compaction.messages_json.v1",
                "sha256" => scanned.digest,
                "byte_length" => scanned.count,
                "fragments" => [
                  %{"offset" => 0, "text" => prefix},
                  %{"offset" => offset, "text" => suffix}
                ]
              }
            })

          if byte_size(bytes) <= @cap, do: [candidate(bytes, true, quota)], else: []
        else
          _invalid -> []
        end
      end)

    if candidates == [],
      do: {:error, :compaction_excerpt_budget_too_small},
      else: {:ok, candidates}
  end

  defp fragment(buffer, quota, side) do
    Enum.find_value(0..3, fn extra ->
      size = quota + extra

      if size <= byte_size(buffer) do
        offset = if side == :prefix, do: 0, else: byte_size(buffer) - size
        bytes = binary_part(buffer, offset, size)
        if String.valid?(bytes), do: bytes
      end
    end)
  end

  defp candidate(bytes, excerpted, quota),
    do: %{
      bytes: bytes,
      digest: Canonical.digest_bytes(bytes),
      source_excerpted: excerpted,
      quota: quota
    }

  defp valid_prior(nil), do: :ok

  defp valid_prior(
         %{
           "covered_range_digest" => digest,
           "summary" => summary,
           "carry_forward" => carry,
           "source_excerpted" => excerpted
         } = prior
       ) do
    with true <- map_size(prior) == 4 and is_binary(digest) and byte_size(digest) == 64,
         true <- Regex.match?(~r/\A[0-9a-f]{64}\z/, digest),
         true <- is_boolean(excerpted) and is_binary(summary) and byte_size(summary) <= 4_094,
         true <- String.valid?(summary),
         true <- valid_carry?(carry),
         true <- byte_size(json(summary)) <= 4_096,
         true <- byte_size(json(carry)) <= 2_048,
         true <- byte_size(json(%{"summary" => summary, "carry_forward" => carry})) <= 6_144 do
      :ok
    else
      _invalid -> {:error, :context_projection_invalid}
    end
  end

  defp valid_prior(_), do: {:error, :context_projection_invalid}

  defp valid_carry?(%{"files_read" => read, "files_changed" => changed} = carry)
       when map_size(carry) == 2 and is_list(read) and is_list(changed) do
    Enum.all?([read, changed], fn paths ->
      length(paths) <= 32 and
        Enum.all?(paths, fn path ->
          is_binary(path) and byte_size(path) <= 1_024 and String.valid?(path)
        end)
    end)
  end

  defp valid_carry?(_), do: false

  defp json(value) do
    {:ok, framed} = Frame.encode(%{"v" => value})
    bytes = IO.iodata_to_binary(framed)
    binary_part(bytes, 5, byte_size(bytes) - 7)
  end
end
