defmodule Loopex.Model do
  @moduledoc """
  ## Concept

  The provider-neutral model boundary. A session commits one canonical request
  before an adapter sees it; every adapter receives those exact bytes and their
  digest together with the plain semantic request, and hands back one complete
  reply.

  An adapter may also report progress while it works. Streaming is one extra
  argument on the same call, not a second callback and not a second code path:
  an adapter that cannot stream emits nothing, returns the same reply, and is
  conformant.

  Fixed by
  [ADR 0010](../../../../docs/adr/0010-provider-continuation-and-context-staging.md#concept)
  and
  [ADR 0011](../../../../docs/adr/0011-session-input-algebra-and-streaming.md#concept).

  ## Technical depth

  The canonical request is a closed, versioned projection carrying the model
  identity, the projected message list, the complete tool definitions, every
  declared sampling bound, the run's absolute deadline, and a reserved
  continuation field. Its digest is `staged_request_digest`.

  Only the digest is renamed; the bytes keep their `canonical_request_bytes`
  name, because the bytes never carried the ambiguity. The executor's job digest
  is also a request digest, and while both were called `canonical_request_digest`
  one identifier carried two opposite retry rules. They are opposite: a provider retry dispatches the same
  staged bytes under a newly recorded attempt and *reuses* their
  `staged_request_digest`, because the model request has no operation or attempt
  member; an executor attempt computes its *own* attempt-bound
  `canonical_request_digest`, because job canonicalization covers attempt
  identity. Two attempts of one tool operation therefore produce two different
  job digests by construction, while two attempts of one model call produce one
  staged digest.

  `continuation` is structurally present and always empty here. It exists so a
  later adapter-private continuation handle can land without changing what the
  canonicalization covers, and M2 never reads, writes, or compares it.

  There is no sampling default anywhere. `max_tokens` is a declared committed
  value and a request built without one is refused, rather than silently
  truncated at dispatch by a number no record names.
  """

  alias LoopexProtocol.Canonical
  alias LoopexProtocol.ToolDefinition
  alias Loopex.ProgressPayload

  @canonicalization_version "loopex.model_request.v1"

  @semantic_fields [
    :canonicalization_version,
    :model,
    :messages,
    :tools,
    :sampling,
    :deadline,
    :continuation
  ]

  @delta_kinds [:text_delta, :reasoning_delta, :tool_call_delta]

  @max_delta_bytes 65_536

  # Concept: a delta carries the fields its kind declares and no others.
  #
  # Technical depth: the ceiling used to be measured over four recognised names
  # while the shape check admitted any plain map, so a field nobody had named
  # was neither bounded nor refused: a one-megabyte `vendor_blob` beside a
  # short `text` measured as the length of the text and crossed onto the
  # progress plane. The same gap let an adapter carry `"stream_domain_id"` and
  # `"model_sequence"` as *string* keys, which the coordinator's atom-keyed
  # labels do not overwrite, so an item reached a consumer wearing two
  # contradictory sequences and the label the coordinator derived was no longer
  # the only one there.
  #
  # Admitting an exact set per kind closes both at once. It also makes the
  # ceiling total rather than partial, because every admitted field is now a
  # field the measurement knows about.
  @delta_fields %{
    text_delta: [:kind, :content_index, :text],
    reasoning_delta: [:kind, :content_index, :text],
    tool_call_delta: [:kind, :call_index, :tool_call_id, :name, :arguments_fragment]
  }

  @typedoc """
  ## Concept

  One complete canonical model request ready to commit and dispatch.

  ## Technical depth

  The semantic fields are bounded plain data. `canonical_request_bytes` is the
  exact canonical encoding of their ordered projection and
  `staged_request_digest` is its lowercase hexadecimal SHA-256. Both travel
  together so an adapter can refuse a request whose semantics, committed bytes,
  or digest disagree.
  """
  @type request :: %{
          required(:canonicalization_version) => binary(),
          required(:model) => binary(),
          required(:messages) => [map()],
          required(:tools) => [map()],
          required(:sampling) => %{binary() => term()},
          required(:deadline) => integer(),
          required(:continuation) => nil,
          required(:canonical_request_bytes) => binary(),
          required(:staged_request_digest) => binary()
        }

  @typedoc """
  ## Concept

  A complete provider-neutral model answer.

  ## Technical depth

  `delta_count` and `streamed` are attempt-private evidence about how the reply
  was produced, not fields of the committed assistant message. They let the
  coordinator close that attempt's progress domain with the producer's own
  statement of how many items it emitted.
  """
  @type reply :: %{
          required(:text) => binary(),
          required(:identity) => map(),
          required(:usage) => map(),
          required(:tool_calls) => [map()],
          required(:delta_count) => non_neg_integer(),
          required(:streamed) => boolean(),
          optional(:provider_response_id) => binary() | nil,
          required(:canonical_request_bytes) => binary(),
          required(:staged_request_digest) => binary()
        }

  @typedoc """
  ## Concept

  One bounded piece of progress observed while a reply is still incomplete.

  ## Technical depth

  Plain data carrying no provider or host term. The coordinator stamps
  `stream_domain_id` and the sequence; an adapter supplies only the content
  fields, because a domain an adapter could name is a domain an adapter could
  misattribute.
  """
  @type delta :: %{required(:kind) => atom(), optional(atom()) => term()}

  @typedoc """
  ## Concept

  The function an adapter calls to report one delta.

  ## Technical depth

  An ordinary in-VM function reference, created for exactly one model attempt
  and closing over that attempt's identity. It returns `:ok` and never blocks on
  a consumer, because progress is transient and a slow reader must not stall a
  provider call.
  """
  @type progress_fun :: (delta() -> :ok)

  @callback complete(request(), keyword(), progress_fun()) :: {:ok, reply()} | {:error, term()}

  @doc """
  ## Concept

  The delta kinds an adapter may emit.

  ## Technical depth

  Exposed so the streaming conformance suite enumerates them from the boundary
  rather than from a transcription that can drift.
  """
  @spec delta_kinds() :: [atom()]
  def delta_kinds, do: @delta_kinds

  @doc """
  ## Concept

  A progress function that discards everything, for a caller that wants no
  stream.

  ## Technical depth

  Adapters must always be handed a callable, so the non-streaming path supplies
  this rather than `nil`. That keeps the adapter free of a "did I get a progress
  function" branch, which is exactly the second code path ADR 0011 refuses.
  """
  @spec discard_progress() :: progress_fun()
  def discard_progress, do: fn _delta -> :ok end

  @doc """
  ## Concept

  Builds one bounded canonical request from plain model, message, tool, and
  bound data.

  ## Technical depth

  `:sampling` and `:deadline` are required; there is no default for either.
  Tools are complete definition records, each carrying its generation triple, so
  the staged bytes stay independently verifiable from the journal after the
  registry that held them has changed.
  """
  @spec request(binary(), [map()], keyword()) :: {:ok, request()} | {:error, term()}
  def request(model, messages, options \\ [])

  def request(model, messages, options)
      when is_binary(model) and is_list(messages) and is_list(options) do
    semantic = %{
      canonicalization_version: @canonicalization_version,
      model: model,
      messages: messages,
      tools: Keyword.get(options, :tools, []),
      sampling: Keyword.get(options, :sampling),
      deadline: Keyword.get(options, :deadline),
      continuation: nil
    }

    with :ok <- validate_semantics(semantic),
         {:ok, bytes} <- canonical_bytes(semantic) do
      {:ok,
       semantic
       |> Map.put(:canonical_request_bytes, bytes)
       |> Map.put(:staged_request_digest, Canonical.digest_bytes(bytes))}
    end
  end

  def request(_model, _messages, _options), do: {:error, :invalid_model_request}

  @doc """
  ## Concept

  Proves that a dispatched request is exactly the request whose bytes and digest
  were committed.

  ## Technical depth

  The semantic projection is recomputed independently. Both byte equality and
  digest equality are required, so a self-consistent replacement of only one
  representation is refused.
  """
  @spec validate_request(map()) :: :ok | {:error, term()}
  def validate_request(request) when is_map(request) do
    semantic = Map.take(request, @semantic_fields)

    with true <- Enum.sort(Map.keys(semantic)) == Enum.sort(@semantic_fields),
         :ok <- validate_semantics(semantic),
         {:ok, bytes} <- canonical_bytes(semantic),
         true <- Map.get(request, :canonical_request_bytes) == bytes,
         true <- Map.get(request, :staged_request_digest) == Canonical.digest_bytes(bytes) do
      :ok
    else
      _other -> {:error, :canonical_model_request_mismatch}
    end
  end

  def validate_request(_request), do: {:error, :canonical_model_request_mismatch}

  @doc """
  ## Concept

  Whether a term is one bounded delta an adapter may emit.

  ## Technical depth

  Enforces the exact field set, the payload ceiling, and the plain-data rule at
  the boundary, so an adapter cannot put an unbounded term or a provider struct
  on the progress plane. A delta that fails this check is dropped rather than
  projected, and it reserves no sequence, so it never appears in the count its
  domain's closure publishes -- a malformed item must not be able to break a
  sequence a consumer uses to detect loss.

  The set is exact in both directions. Admitting only declared names stops a
  field nobody bounded from riding along; requiring every declared name stops the
  opposite defect, which is a delta whose meaning is missing: a `text_delta`
  carrying no `text` reconstructs to nothing, and a `tool_call_delta` carrying no
  `tool_call_id` names no call, yet both were admitted, sequenced, and published
  as though they said something.
  """
  @spec valid_delta?(term()) :: boolean()
  def valid_delta?(%{kind: kind} = delta) when kind in @delta_kinds do
    admitted = Map.fetch!(@delta_fields, kind)

    Enum.sort(Map.keys(delta)) == Enum.sort(admitted) and
      plain?(Map.delete(delta, :kind)) and
      semantic_delta?(delta) and
      delta_bytes(delta) <= @max_delta_bytes
  end

  def valid_delta?(_delta), do: false

  defp semantic_delta?(%{kind: kind, content_index: index, text: text})
       when kind in [:text_delta, :reasoning_delta],
       do: is_integer(index) and index >= 0 and ProgressPayload.terminal_safe?(text)

  defp semantic_delta?(%{
         kind: :tool_call_delta,
         call_index: index,
         tool_call_id: call_id,
         name: name,
         arguments_fragment: fragment
       }) do
    is_integer(index) and index >= 0 and optional_safe_text?(call_id) and
      optional_safe_text?(name) and optional_safe_text?(fragment)
  end

  defp semantic_delta?(_delta), do: false

  defp optional_safe_text?(nil), do: true
  defp optional_safe_text?(value), do: ProgressPayload.terminal_safe?(value)

  @doc """
  ## Concept

  The exact fields a delta of each kind may carry.

  ## Technical depth

  Published so a conformance suite can assert the set rather than read it back
  from the same predicate it is testing, and so an adapter author can see what
  will be refused rather than discovering it as a dropped item.
  """
  @spec delta_fields(atom()) :: [atom()]
  def delta_fields(kind) when kind in @delta_kinds, do: Map.fetch!(@delta_fields, kind)

  @doc """
  ## Concept

  The bounded model-facing projection of the tool definitions a request carries.

  ## Technical depth

  An adapter renders this into its provider's own tool format. The request
  itself carries the complete records; this is the subset a provider is shown,
  and core never stages the projection in place of the records.
  """
  @spec model_facing_tools(request()) :: [map()]
  def model_facing_tools(%{tools: tools}), do: Enum.map(tools, &ToolDefinition.model_facing/1)

  @doc """
  ## Concept

  The declared maximum output allowance for this request.

  ## Technical depth

  Read from the committed sampling bounds rather than from a default, because a
  turn that produces no complete reply is charged this value in full and a
  number no record names cannot be charged honestly.
  """
  @spec max_tokens(request()) :: pos_integer()
  def max_tokens(%{sampling: %{"max_tokens" => max_tokens}}), do: max_tokens

  defp validate_semantics(%{
         canonicalization_version: @canonicalization_version,
         model: model,
         messages: messages,
         tools: tools,
         sampling: %{"max_tokens" => max_tokens} = sampling,
         deadline: deadline,
         continuation: nil
       })
       when is_binary(model) and byte_size(model) > 0 and byte_size(model) <= 512 and
              is_list(messages) and length(messages) > 0 and length(messages) <= 1_024 and
              is_list(tools) and length(tools) <= 256 and
              is_integer(max_tokens) and max_tokens > 0 and max_tokens <= 1_000_000 and
              is_integer(deadline) do
    cond do
      not Enum.all?(tools, &ToolDefinition.valid?/1) -> {:error, :invalid_model_request}
      not plain?(messages) -> {:error, :invalid_model_request}
      not plain?(sampling) -> {:error, :invalid_model_request}
      true -> :ok
    end
  end

  defp validate_semantics(_semantic), do: {:error, :invalid_model_request}

  defp canonical_bytes(semantic) do
    ordered = Enum.map(@semantic_fields, &{&1, Map.fetch!(semantic, &1)})
    {:ok, Canonical.encode(ordered)}
  rescue
    _error -> {:error, :invalid_model_request}
  end

  # Concept: the ceiling covers every field a provider fills, not only the two
  # that obviously carry prose.
  #
  # Technical depth: a shipped tool call delta takes `tool_call_id` and `name`
  # verbatim from the provider's stream alongside `arguments_fragment`, so a
  # delta carrying two megabyte-long identifiers passed this check untouched and
  # the declared payload ceiling bounded nothing that mattered on that kind.
  # `:chunk` was counted and no delta kind in this tree carries it: a name in a
  # bound list that matches nothing reads as coverage the check does not have.
  # Every binary the delta carries, not a named four. A partial measurement is
  # the same defect as a partial field check: what it does not look at is
  # unbounded.
  #
  # The measurement is total for the same reason. Everything that is not a
  # binary, a list, or a plain map used to measure as zero, and an integer is
  # neither -- so a `content_index` of two raised to the one-point-six-millionth
  # power measured as nothing and crossed the plane as two hundred kilobytes
  # under a sixty-four kilobyte ceiling. A term whose size the named clauses do
  # not know is measured by encoding it, which is exactly what putting it on the
  # plane will cost.
  defp delta_bytes(delta) do
    delta
    |> Map.delete(:kind)
    |> Enum.reduce(0, fn {_key, value}, total -> total + term_bytes(value) end)
  end

  defp term_bytes(value) when is_binary(value), do: byte_size(value)
  defp term_bytes(value) when is_list(value), do: Enum.reduce(value, 0, &(term_bytes(&1) + &2))

  defp term_bytes(value) when is_map(value) and not is_struct(value) do
    Enum.reduce(value, 0, fn {key, inner}, total ->
      total + term_bytes(key) + term_bytes(inner)
    end)
  end

  defp term_bytes(value), do: byte_size(:erlang.term_to_binary(value))

  defp plain?(term)
       when is_binary(term) or is_integer(term) or is_float(term) or is_boolean(term) or
              is_nil(term),
       do: true

  defp plain?(term) when is_list(term), do: Enum.all?(term, &plain?/1)

  defp plain?(term) when is_map(term) and not is_struct(term) do
    Enum.all?(term, fn {key, value} -> (is_binary(key) or is_atom(key)) and plain?(value) end)
  end

  defp plain?(_term), do: false
end
