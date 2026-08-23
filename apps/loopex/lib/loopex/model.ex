defmodule Loopex.Model do
  @moduledoc """
  ## Concept

  The provider-neutral model boundary. A session commits one canonical request
  before an adapter sees it; every adapter receives those exact bytes and their
  digest together with the plain semantic request.

  ## Technical depth

  Canonicalization covers one closed, versioned projection and uses Erlang's
  deterministic external-term encoding. The raw bytes and lowercase SHA-256
  digest travel together so an adapter can reject a request whose semantics,
  committed bytes, or digest disagree. Provider types and credentials never
  cross this boundary.
  """

  @protocol_version 1
  @semantic_fields [:protocol_version, :model, :messages, :tools, :max_tokens]

  @typedoc """
  ## Concept

  One complete canonical model request ready to commit and dispatch.

  ## Technical depth

  The semantic fields are bounded plain data. `canonical_request_bytes` is the
  exact deterministic encoding of their ordered projection and the digest is
  its lowercase hexadecimal SHA-256.
  """
  @type request :: %{
          required(:protocol_version) => pos_integer(),
          required(:model) => binary(),
          required(:messages) => [map()],
          required(:tools) => [map()],
          required(:max_tokens) => pos_integer(),
          required(:canonical_request_bytes) => binary(),
          required(:canonical_request_digest) => binary()
        }

  @typedoc """
  ## Concept

  A complete provider-neutral model answer.

  ## Technical depth

  M1 needs non-streaming text and non-secret identity. Later milestones may add
  the larger canonical stream algebra without changing who owns the boundary.
  """
  @type reply :: %{
          required(:text) => binary(),
          required(:identity) => map(),
          required(:usage) => map()
        }

  @callback complete(request(), keyword()) :: {:ok, reply()} | {:error, term()}

  @doc """
  ## Concept

  Builds one bounded request from plain model, message, tool, and budget data.

  ## Technical depth

  Construction and validation share the same closed projection. Unknown
  top-level input is not accepted and cannot silently escape the digest.
  """
  @spec request(binary(), [map()], keyword()) :: {:ok, request()} | {:error, term()}
  def request(model, messages, options \\ [])

  def request(model, messages, options)
      when is_binary(model) and is_list(messages) and is_list(options) do
    tools = Keyword.get(options, :tools, [])
    max_tokens = Keyword.get(options, :max_tokens, 64)

    semantic = %{
      protocol_version: @protocol_version,
      model: model,
      messages: messages,
      tools: tools,
      max_tokens: max_tokens
    }

    with :ok <- validate_semantics(semantic),
         {:ok, bytes} <- canonical_bytes(semantic) do
      {:ok,
       semantic
       |> Map.put(:canonical_request_bytes, bytes)
       |> Map.put(:canonical_request_digest, digest(bytes))}
    end
  end

  def request(_model, _messages, _options), do: {:error, :invalid_model_request}

  @doc """
  ## Concept

  Proves that a dispatched request is exactly the request whose bytes and digest
  were committed.

  ## Technical depth

  The semantic projection is recomputed independently. Both byte equality and
  digest equality are required; a self-consistent replacement of only one
  representation is refused.
  """
  @spec validate_request(map()) :: :ok | {:error, term()}
  def validate_request(request) when is_map(request) do
    semantic = Map.take(request, @semantic_fields)

    with true <- Map.keys(semantic) |> Enum.sort() == Enum.sort(@semantic_fields),
         :ok <- validate_semantics(semantic),
         {:ok, bytes} <- canonical_bytes(semantic),
         true <- Map.get(request, :canonical_request_bytes) == bytes,
         true <- Map.get(request, :canonical_request_digest) == digest(bytes) do
      :ok
    else
      _other -> {:error, :canonical_model_request_mismatch}
    end
  end

  def validate_request(_request), do: {:error, :canonical_model_request_mismatch}

  @doc """
  ## Concept

  Returns the user text for M1's single-message request.

  ## Technical depth

  This deliberately narrow extractor refuses alternate histories rather than
  guessing how to flatten them for a provider.
  """
  @spec single_user_text(request()) :: {:ok, binary()} | {:error, term()}
  def single_user_text(%{messages: [%{role: "user", content: content}]})
      when is_binary(content) and byte_size(content) > 0,
      do: {:ok, content}

  def single_user_text(_request), do: {:error, :unsupported_model_request}

  defp validate_semantics(%{
         protocol_version: @protocol_version,
         model: model,
         messages: messages,
         tools: tools,
         max_tokens: max_tokens
       })
       when is_binary(model) and byte_size(model) > 0 and byte_size(model) <= 512 and
              is_list(messages) and length(messages) > 0 and length(messages) <= 1_024 and
              is_list(tools) and length(tools) <= 256 and is_integer(max_tokens) and
              max_tokens > 0 and max_tokens <= 1_000_000 do
    if plain?(messages) and plain?(tools), do: :ok, else: {:error, :invalid_model_request}
  end

  defp validate_semantics(_semantic), do: {:error, :invalid_model_request}

  defp canonical_bytes(semantic) do
    ordered = Enum.map(@semantic_fields, &{&1, Map.fetch!(semantic, &1)})
    {:ok, :erlang.term_to_binary(ordered, [:deterministic])}
  rescue
    _error -> {:error, :invalid_model_request}
  end

  defp digest(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  defp plain?(term) when is_binary(term) or is_integer(term) or is_boolean(term) or is_nil(term),
    do: true

  defp plain?(term) when is_list(term), do: Enum.all?(term, &plain?/1)

  defp plain?(term) when is_map(term) do
    Enum.all?(term, fn {key, value} -> is_binary(key) and plain?(value) end)
  end

  defp plain?(_term), do: false
end
