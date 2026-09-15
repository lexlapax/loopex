defmodule Loopex.Trace.Entry do
  @moduledoc """
  ## Concept

  One trace entry: who called what, in which process, when, and at the
  administrative `arguments` level a redacted rendering of the arguments and
  the return. Content never survives redaction; only bounded identities and the
  size and digest of what was removed do.

  ## Technical depth

  Redaction runs over the term before anything is rendered, because rendering
  first and filtering the text afterwards would put the secret in memory as a
  string and leave the filter guessing at its boundaries. The walk replaces a
  value with a typed placeholder when its key names a credential, a model
  request or reply body, tool arguments or results, or artifact bytes, and when
  a binary is longer than an identity can be. A placeholder carries the byte
  size and the lowercase SHA-256 digest of what it replaced, which is enough to
  correlate two entries about the same payload and never enough to read it.

  The rendered form is then truncated to the session's per-entry byte ceiling,
  so an entry is bounded however deep or wide the term was.
  """

  @credential_pattern ~r/credential|secret|token|api[_-]?key|password|authorization/i
  @content_keys ~w(messages canonical_request_bytes text tool_calls arguments argument result
                   results content contents data bytes payload body chunk)
  @identity_bytes 64
  @truncation_marker "..."

  @type placeholder :: %{binary() => binary() | non_neg_integer()}

  @doc """
  ## Concept

  Builds the entry for one observed call.

  ## Technical depth

  Keys are binaries so the entry is plain transient data the diagnostics plane
  already admits. `duration_native` appears only once a matching return or
  exception has been seen, because a call that has not returned has no duration
  to report and inventing one would be a lie a reader cannot detect.
  """
  @spec call(map()) :: map()
  def call(fields) when is_map(fields) do
    %{
      "kind" => "trace_call",
      "module" => inspect(Map.fetch!(fields, :module)),
      "function" => Atom.to_string(Map.fetch!(fields, :function)),
      "arity" => Map.fetch!(fields, :arity),
      "caller" => render_caller(Map.get(fields, :caller)),
      "pid" => inspect(Map.fetch!(fields, :pid)),
      "monotonic_native" => Map.fetch!(fields, :monotonic_native)
    }
    |> put_optional("class", Map.get(fields, :class))
    |> put_optional("duration_native", Map.get(fields, :duration_native))
    |> put_optional("arguments", Map.get(fields, :arguments))
    |> put_optional("return", Map.get(fields, :return))
  end

  @doc """
  ## Concept

  The entry a session emits when it drops what it could not report.
  """
  @spec dropped(non_neg_integer(), binary()) :: map()
  def dropped(count, reason) when is_integer(count) and count >= 0 and is_binary(reason) do
    %{"kind" => "trace_dropped", "dropped" => count, "reason" => reason}
  end

  @doc """
  ## Concept

  Replaces every credential, model body, tool argument or result, and artifact
  payload in a term with a typed placeholder.

  ## Technical depth

  The walk is bounded in depth and in list length, so a cyclic-looking or very
  wide term costs a fixed amount of work. Anything beyond those bounds is
  itself replaced by a placeholder rather than rendered, because an entry that
  silently dropped the tail of a term would misreport the call it describes.
  """
  @spec redact(term()) :: term()
  def redact(term), do: redact(term, 0, nil)

  @doc """
  ## Concept

  Renders a redacted term and truncates it to the per-entry ceiling.
  """
  @spec render(term(), pos_integer()) :: binary()
  def render(term, entry_bytes) when is_integer(entry_bytes) and entry_bytes > 0 do
    term
    |> redact()
    |> inspect(limit: 50, printable_limit: entry_bytes, structs: false)
    |> truncate(entry_bytes)
  end

  @doc """
  ## Concept

  Truncates a rendering to an exact byte ceiling.
  """
  @spec truncate(binary(), pos_integer()) :: binary()
  def truncate(rendered, entry_bytes) when byte_size(rendered) <= entry_bytes, do: rendered

  def truncate(rendered, entry_bytes) do
    kept = max(entry_bytes - byte_size(@truncation_marker), 0)
    binary_part(rendered, 0, kept) <> @truncation_marker
  end

  defp redact(term, depth, _key) when depth > 6, do: placeholder("depth", term)

  defp redact(term, depth, key) when not is_nil(key) do
    cond do
      credential_key?(key) -> placeholder("credential", term)
      content_key?(key) -> placeholder("content", term)
      true -> redact(term, depth, nil)
    end
  end

  defp redact(term, _depth, _key) when is_binary(term) and byte_size(term) > @identity_bytes,
    do: placeholder("bytes", term)

  defp redact(term, depth, _key) when is_list(term), do: redact_list(term, depth, 0, [])

  defp redact(term, depth, _key) when is_tuple(term) and tuple_size(term) <= 32 do
    term
    |> Tuple.to_list()
    |> Enum.map(&redact(&1, depth + 1, nil))
    |> List.to_tuple()
  end

  defp redact(term, _depth, _key) when is_tuple(term), do: placeholder("tuple", term)

  defp redact(term, depth, _key) when is_map(term) and not is_struct(term) do
    if map_size(term) > 32 do
      placeholder("map", term)
    else
      Map.new(term, fn {key, value} -> {key, redact(value, depth + 1, key)} end)
    end
  end

  defp redact(term, depth, _key) when is_struct(term) do
    term
    |> Map.from_struct()
    |> redact(depth, nil)
    |> Map.put("__struct__", inspect(term.__struct__))
  end

  defp redact(term, _depth, _key)
       when is_pid(term) or is_port(term) or is_reference(term) or is_function(term),
       do: placeholder("opaque", term)

  defp redact(term, _depth, _key), do: term

  # Concept: what a placeholder is allowed to say about what it replaced.
  #
  # Technical depth: the size and digest are taken from the canonical binary
  # encoding of the term, so two placeholders match exactly when they replaced
  # equal terms. Neither field can be inverted into content.
  defp placeholder(kind, term) do
    bytes = :erlang.term_to_binary(term, [:deterministic])

    %{
      "redacted" => kind,
      "bytes" => byte_size(bytes),
      "digest" => bytes |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)
    }
  end

  # Concept: a list is walked to a fixed width, whatever shape it has.
  #
  # Technical depth: the walk counts elements itself rather than measuring the
  # list first, because a traced argument may be an improper list -- a
  # `GenServer` reply tag is one -- and measuring that raises. An overlong list
  # keeps the elements already walked and replaces the rest with one
  # placeholder; an improper tail is redacted in place and stays the tail, so
  # the entry reports the shape the call actually had.
  defp redact_list([], _depth, _count, walked), do: Enum.reverse(walked)

  defp redact_list([head | tail], depth, count, walked) when count < 32 do
    redact_list(tail, depth, count + 1, [redact(head, depth + 1, nil) | walked])
  end

  defp redact_list([_head | _tail] = rest, _depth, _count, walked) do
    Enum.reverse([placeholder("list", rest) | walked])
  end

  defp redact_list(tail, depth, _count, walked) do
    Enum.reverse(walked) ++ redact(tail, depth + 1, nil)
  end

  defp credential_key?(key), do: Regex.match?(@credential_pattern, key_name(key))

  defp content_key?(key), do: key_name(key) in @content_keys

  defp key_name(key) when is_atom(key), do: Atom.to_string(key)
  defp key_name(key) when is_binary(key), do: key
  defp key_name(_key), do: ""

  defp render_caller(nil), do: "unknown"
  defp render_caller({module, function, arity}), do: "#{inspect(module)}.#{function}/#{arity}"
  defp render_caller(caller), do: inspect(caller)

  defp put_optional(entry, _key, nil), do: entry
  defp put_optional(entry, key, value), do: Map.put(entry, key, value)
end
