defmodule Loopex.LLM.ReqLLM do
  @moduledoc """
  ## Concept

  The reference model adapter. It maps one canonical model request onto ReqLLM
  and maps the provider's answer back to plain data, which is the whole of
  outcome 7: proving a real model call completes *from the adapter application*
  rather than from core.

  Two directions are kept clean. Nothing about Loopex sessions, operations,
  durability, or policy appears here — the caller passes a model identity and a
  prompt and receives text, identity, and usage. Nothing about ReqLLM, Req,
  Finch, or a provider's wire format leaves this module: `ReqLLM` structs are
  accepted and read here and never returned, so a host or a later core boundary
  sees only bounded serializable maps and strings.

  A stream that did not finish is a failure and not a shorter answer. A provider
  that emits some text and then loses its connection, is rate limited, or stops
  mid tool call has produced no assistant message, so this adapter returns an
  error and the coordinator abandons that attempt. It never hands back the
  fragment that did arrive as though the model had said it and stopped.

  The credential arrives only from the `LOOPEX_PROVIDER_API_KEY` environment
  variable, is handed to ReqLLM as a per-request option, and is never returned,
  logged, or written anywhere. No other provider variable is consulted, so a key
  that happens to sit in the operator's environment cannot be spent by this lane
  by accident.

  ## Technical depth

  `ReqLLM` here is the top-level library module `Elixir.ReqLLM`; Elixir resolves
  aliases from the root, so the trailing segment of this module's own name does
  not shadow it.

  The credential is passed as `api_key:` on the call rather than through
  `ReqLLM.put_key/2` or ReqLLM's own environment lookup. A per-request option is
  scoped to the one request, leaves no value in application environment for
  another process to read, and — because ReqLLM's key resolution prefers the
  explicit option — removes any path by which a differently named provider
  variable already present in the environment could satisfy the call instead.

  Model identity is resolved through `ReqLLM.model/1`, which reads the bundled
  LLMDB catalog with no network access and no credential. That resolution is
  therefore usable as an ordinary untagged test: it proves the pinned reference
  model spec still names a real catalog entry without spending a token. The
  endpoint recorded is the catalog's base URL when it carries one and the
  provider module's default otherwise, which is an endpoint *class* — a
  non-secret host, never a credentialed URL.

  Provider failures are reduced to a bounded, scrubbed string rather than passed
  through as a term. A provider error can carry request context, so the raw term
  is inspected with hard limits and the credential value is substituted out
  before it can reach a caller, a report, or an operator's terminal. The gate
  runner redacts its captured output as well; these are two independent planes
  and each needs its own containment.

  `complete/2` returns before any dispatch when the credential is absent, so a
  missing credential is a reported absence rather than a provider call with an
  empty key.
  """

  @behaviour Loopex.Model

  alias Loopex.Model

  @credential_variable "LOOPEX_PROVIDER_API_KEY"

  # Concept: the pinned reference model. A provider-neutral credential name
  # cannot say which provider it belongs to, so the lane names the model it
  # calls and the operator points the credential at that provider.
  #
  # Technical depth: an operator whose credential belongs elsewhere overrides
  # the spec at the call site rather than editing this constant, because
  # `complete/2` takes the spec as an argument.
  @default_model "anthropic:claude-haiku-4-5"

  # Concept: one short answer is all the outcome needs; a ceiling keeps the
  # evidence run cheap and bounded.
  @max_tokens 64
  @progress_fragment_bytes 60_000

  @unknown_endpoint "unknown"
  @redacted "[redacted credential]"

  @typedoc """
  ## Concept

  The non-secret identity of a model call, retained so a reviewer can judge what
  was actually called.

  ## Technical depth

  Plain strings only. `endpoint` is an endpoint class — a host, never a URL
  carrying a credential or a tenant identifier.
  """
  @type identity :: %{provider: String.t(), model: String.t(), endpoint: String.t()}

  @typedoc """
  ## Concept

  What one completed model call yields: the assistant text, the identity that
  produced it, and the provider's reported token usage.

  ## Technical depth

  Bounded serializable data. Usage is reduced to two integer counts, or `nil`
  where the provider reported none, so no provider struct crosses the boundary.

  `provider_response_id` is the provider's own identifier for the response, taken
  from the `request-id` header the provider returns per call. It is the one field
  in a reply that a deterministic adapter cannot invent, because it exists in the
  provider's account and can be looked up there. That is what makes it the anchor
  of the milestone's real-call evidence, and it is `nil` wherever the provider
  supplied none rather than being filled in with a plausible value.

  A streamed call cannot carry the provider's assembled *message* identifier: the
  library keeps only usage from the provider's opening event and discards the
  rest. The per-call request identifier survives streaming and is the identifier
  the provider's own account and support surface use, so it is the one retained.

  `staged_request_digest` names the request bytes core committed before this
  dispatch. It is spelled the way the reply this adapter actually returns spells
  it, so an embedder reading this type reaches a field production supplies rather
  than one that was renamed underneath it.

  `delta_count` and `streamed` are the attempt-private evidence `Loopex.Model`
  requires of every reply: what this adapter emitted and whether it streamed at
  all. They belong to the type because the coordinator closes the attempt's
  progress domain with them.
  """
  @type reply :: %{
          text: String.t(),
          identity: identity(),
          provider_response_id: String.t() | nil,
          usage: %{input_tokens: non_neg_integer() | nil, output_tokens: non_neg_integer() | nil},
          tool_calls: [map()],
          delta_count: non_neg_integer(),
          streamed: boolean(),
          canonical_request_bytes: binary(),
          staged_request_digest: binary()
        }

  @doc """
  ## Concept

  The environment variable this adapter reads the provider credential from, and
  the only one it will read.

  ## Technical depth

  Exposed so the real-provider lane can name it in its own failure message
  without restating the string and drifting from the value actually read.
  """
  @spec credential_variable() :: String.t()
  def credential_variable, do: @credential_variable

  @doc """
  ## Concept

  The pinned reference model specification the real-provider lane calls.

  ## Technical depth

  A `provider:model` specification ReqLLM resolves through its bundled catalog.
  """
  @spec default_model() :: String.t()
  def default_model, do: @default_model

  @doc """
  ## Concept

  Resolves a model specification to the non-secret identity a call against it
  would carry.

  ## Technical depth

  Needs no credential and makes no network request, so the lane can record what
  it is about to call — and an ordinary test can prove the pinned spec still
  resolves — without spending a token. An unresolvable specification is an
  error, never a guessed identity.
  """
  @spec identity(String.t()) ::
          {:ok, identity()} | {:error, {:unresolved_model, String.t(), term()}}
  def identity(model_spec) when is_binary(model_spec) do
    case ReqLLM.model(model_spec) do
      {:ok, model} ->
        {:ok,
         %{
           provider: to_string(model.provider),
           model: to_string(model.id),
           endpoint: endpoint(model)
         }}

      {:error, reason} ->
        {:error, {:unresolved_model, model_spec, reason}}
    end
  end

  @doc """
  ## Concept

  Builds and dispatches one request from a bare model name and prompt.

  ## Technical depth

  A convenience for callers that hold no committed request, used by the
  credential-free adapter lane. It declares its own sampling bound explicitly,
  because there is no default anywhere and a request without one is refused.
  """
  @spec complete(String.t(), String.t()) ::
          {:ok, reply()}
          | {:error, {:credential_unset, String.t()}}
          | {:error, {:unresolved_model, String.t(), term()}}
          | {:error, {:provider_call_failed, String.t()}}
  def complete(model_spec, prompt) when is_binary(model_spec) and is_binary(prompt) do
    with {:ok, request} <-
           Model.request(model_spec, [%{"role" => "user", "content" => prompt}],
             sampling: %{"max_tokens" => @max_tokens},
             deadline: System.system_time(:millisecond) + 60_000
           ) do
      complete(request, [], Model.discard_progress())
    end
  end

  @doc """
  ## Concept

  Dispatches exactly the committed request and returns one complete reply.

  ## Technical depth

  This adapter streams. Every chunk the provider sends is emitted through
  `progress` as it arrives and accumulated at the same time, so the reply this
  returns is assembled from exactly the chunks the deltas carried and replays
  them byte for byte. `delta_count` is what was emitted and `streamed` is true,
  so the coordinator closes that attempt's domain with a truthful count.

  The stream is consumed once. Usage and the per-call request identifier come
  from the metadata the provider sends after the content, so they are read once
  the stream is drained rather than beside it.

  A stream that failed, was cut off, or produced a reply that could not be
  assembled returns `{:error, reason}` instead of a reply. Deltas already emitted
  stay emitted; the coordinator closes that attempt's domain abandoned and
  commits no assistant message, which is what makes a partial answer impossible
  to mistake for a short one.
  """
  @impl Loopex.Model
  @spec complete(Model.request(), keyword(), Model.progress_fun()) ::
          {:ok, reply()} | {:error, term()}
  def complete(request, options, progress)
      when is_map(request) and is_list(options) and is_function(progress, 1) do
    with :ok <- Model.validate_request(request),
         {:ok, context} <- context_of(request),
         {:ok, credential} <- credential(),
         {:ok, identity} <- identity(request.model),
         {:ok, tools} <- provider_tools(Model.model_facing_tools(request)) do
      dispatch(request, context, credential, identity, tools, progress)
    end
  end

  # Concept: the run's own deadline bounds the transport, rather than a number
  # this adapter never declared.
  #
  # Technical depth: the streaming client defaults to a 30-second receive
  # timeout when none is given, and this passed none. That is exactly the
  # independent per-call timeout the run's committed absolute deadline is
  # supposed to replace: a bound nobody declared, invisible in the journal,
  # governing a real provider call. Under load it fires while the run has
  # minutes of its declared deadline left, and the attempt fails for a reason
  # the operator never chose and cannot find recorded anywhere.
  #
  # The remaining time on the committed deadline is what goes to the transport,
  # so the transport bound is the run's bound. It cannot outlast the deadline
  # because it is derived from it, and it cannot cut a call short of the
  # deadline either. A deadline already reached yields the floor rather than a
  # negative or zero timeout, because a call dispatched at all is owed a bounded
  # attempt to fail in; the coordinator, not this adapter, decides that a run
  # past its deadline stops.
  @doc """
  ## Concept

  Every option this adapter hands the provider for one call.

  ## Technical depth

  Built here rather than inline so the values a real call is made with can be
  read back and checked, instead of being visible only to the library. Each one
  is derived from the committed request: the sampling bound the run declared,
  the tools it staged, and the remaining time on its committed deadline. None
  of them is a default this adapter invented, and a value missing from this list
  is a value the library would supply on its own behalf.

  The credential is a parameter rather than a field of the request, because it
  never enters a committed request in the first place.
  """
  @spec call_options(Model.request(), binary(), term()) ::
          {:ok, keyword()} | {:error, :deadline_elapsed}
  def call_options(request, credential, tools) do
    with {:ok, bound} <- transport_bound(request) do
      {:ok,
       [
         api_key: credential,
         max_tokens: Model.max_tokens(request),
         tools: tools,
         receive_timeout: bound
       ]}
    end
  end

  @doc """
  ## Concept

  How long the transport may wait, taken from the run's own deadline.

  ## Technical depth

  Public because it is the value that replaced an undeclared default, and a
  regression here is silent: the call still works, it simply stops being bounded
  by anything the run declared.
  """
  @spec transport_bound(Model.request()) :: {:ok, pos_integer()} | {:error, :deadline_elapsed}
  def transport_bound(request) do
    case request.deadline - System.system_time(:millisecond) do
      remaining when remaining > 0 -> {:ok, remaining}
      _elapsed -> {:error, :deadline_elapsed}
    end
  end

  # Concept: the credential is read here and nowhere else, and an absent or
  # empty value is an absence rather than a call with a blank key.
  defp credential do
    case System.get_env(@credential_variable) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _absent -> {:error, {:credential_unset, @credential_variable}}
    end
  end

  # Concept: the answer reaches the operator as the provider produces it.
  #
  # Technical depth: this adapter used to call the non-streaming form and declare
  # `streamed: false` with no deltas, which the port admits as conformant. It was
  # conformant and it was also the reason nothing an operator ran ever streamed,
  # while the runtime, the stream domains, their closure items and the terminal
  # all carried the path.
  #
  # The stream is consumed exactly once. Every chunk is emitted through the
  # progress function the coordinator supplied — closed over that attempt's
  # stream domain — and accumulated at the same time, so the reply this returns
  # is assembled from the same chunks the deltas carried and replays them byte
  # for byte. Usage and the provider's response identifier come from the metadata
  # the provider sends after the content, which is why they are read once the
  # stream is drained rather than beside it.
  defp dispatch(request, context, credential, identity, tools, progress) do
    with {:ok, options} <- call_options(request, credential, tools) do
      case ReqLLM.stream_text(request.model, context, options) do
        {:ok, response} ->
          drain(response, request, identity, progress, credential)

        {:error, error} ->
          {:error, {:provider_call_failed, scrub_error(error, credential)}}
      end
    end
  end

  @doc """
  ## Concept

  Turns one already-open provider stream into the reply this adapter returns,
  emitting every delta on the way, or reports why that stream produced no reply
  at all.

  ## Technical depth

  This is the whole of the adapter's streaming behaviour that needs no network:
  which chunks become which deltas, how the reply is assembled from exactly those
  chunks, and which endings are failures rather than shorter answers. `dispatch`
  calls it with the stream ReqLLM opened; the streaming conformance suite calls
  it with a stream it built itself, so the shipped adapter is judged by the same
  suite as every other one instead of being exempt for needing a credential.

  The response is a `ReqLLM.StreamResponse` — accepted and read here, never
  returned. Errors are already bounded and scrubbed, so a caller may report them
  without inspecting a provider term.
  """
  @spec reply_from_stream(
          ReqLLM.StreamResponse.t(),
          Model.request(),
          identity(),
          Model.progress_fun()
        ) :: {:ok, reply()} | {:error, term()}
  def reply_from_stream(response, request, identity, progress)
      when is_map(request) and is_map(identity) and is_function(progress, 1) do
    drain(response, request, identity, progress, nil)
  end

  # Concept: an interrupted stream produces an error, never the fragment that
  # happened to arrive first.
  #
  # Technical depth: the library reports a broken stream two ways, and both end
  # here as `{:error, _}`. Pulling a chunk after the transport or the provider
  # failed raises out of the lazy stream, which is why the whole drain is
  # rescued: an adapter that let that escape would hand the coordinator an exit
  # where a fact belongs. A stream that ended without the provider's terminal
  # event instead halts normally and says so only in the metadata, which is the
  # dangerous shape -- text already streamed, `{:ok, reply}` one line away -- and
  # is why the metadata is judged before a reply is built at all.
  defp drain(response, request, identity, progress, credential) do
    emitted =
      Enum.reduce_while(response.stream, {:ok, {[], [], 0}}, fn
        chunk, {:ok, {chunks, text, deltas}} ->
          case emit(chunk, progress) do
            {:text, fragment, count} ->
              {:cont, {:ok, {[chunk | chunks], [fragment | text], deltas + count}}}

            {:counted, count} ->
              {:cont, {:ok, {[chunk | chunks], text, deltas + count}}}

            :ignored ->
              {:cont, {:ok, {[chunk | chunks], text, deltas}}}

            {:error, reason} ->
              {:halt, {:error, reason}}
          end
      end)

    case emitted do
      {:ok, {chunks, text, deltas}} ->
        finish_drain(response, request, identity, chunks, text, deltas, credential)

      {:error, reason} ->
        {:error, {:invalid_progress_delta, scrub_error(reason, credential)}}
    end
  rescue
    interrupted -> {:error, {:stream_interrupted, scrub_error(interrupted, credential)}}
  end

  defp finish_drain(response, request, identity, chunks, text, deltas, credential) do
    chunks = Enum.reverse(chunks)
    metadata = ReqLLM.StreamResponse.MetadataHandle.await(response.metadata_handle)

    with :ok <- completed(metadata),
         {:ok, assembled} <- assemble(response, chunks, metadata),
         {:ok, calls} <- bounded_calls(assembled) do
      streamed = text |> Enum.reverse() |> IO.iodata_to_binary()
      {:ok, reply(request, identity, metadata, streamed, calls, deltas)}
    else
      {:error, {tag, reason}} -> {:error, {tag, scrub_error(reason, credential)}}
    end
  end

  defp reply(request, identity, metadata, text, calls, deltas) do
    reported = Map.get(metadata, :usage) || %{}

    %{
      text: text,
      identity: identity,
      provider_response_id: provider_request_id(metadata),
      usage: %{
        input_tokens: Map.get(reported, :input_tokens),
        output_tokens: Map.get(reported, :output_tokens)
      },
      tool_calls: calls,
      delta_count: deltas,
      streamed: deltas > 0,
      canonical_request_bytes: request.canonical_request_bytes,
      staged_request_digest: request.staged_request_digest
    }
  end

  # Concept: a completion the provider finished, distinguished from one that was
  # cut off — including the completion that finished with nothing to say.
  #
  # Technical depth: failure is decided on positive evidence and never on
  # emptiness. A model that answers with no text at all still finishes `stop` and
  # is a success; what fails is a metadata error, a provider status of 400 or
  # above, or a finish reason that names an ending rather than a stop. The
  # library guarantees one of the first two whenever the stream did not terminate
  # cleanly, and substitutes `incomplete` for a missing finish reason on that
  # path, so an unfamiliar provider-specific reason is not read as a fault: a
  # reason this adapter has never seen is not evidence that anything went wrong.
  # `length` is a stop, not a cut: the provider ended the turn at the output
  # allowance core committed, and the tool-call check below is what catches a
  # call that allowance truncated.
  defp completed(metadata) do
    cond do
      is_map(metadata) and is_map_key(metadata, :error) ->
        {:error, {:stream_failed, Map.get(metadata, :error)}}

      error_status?(Map.get(metadata, :status)) ->
        {:error, {:stream_failed, {:provider_status, Map.get(metadata, :status)}}}

      Map.get(metadata, :finish_reason) in [:incomplete, :cancelled, :error] ->
        {:error, {:stream_incomplete, Map.get(metadata, :finish_reason)}}

      true ->
        :ok
    end
  end

  defp error_status?(status) when is_integer(status) and status >= 400, do: true
  defp error_status?(_status), do: false

  # Concept: the turn's tool calls come from the provider, assembled.
  #
  # Technical depth: a streaming `tool_call` chunk carries the name and an empty
  # argument map, because the provider sends the arguments as incremental JSON
  # after it and the chunk is emitted before they arrive. Reading the chunk alone
  # gives a call with no arguments, which the runtime refuses and which made a
  # coding agent that could name a tool and never use one.
  #
  # The provider's own response builder assembles the same chunks into a complete
  # response -- with the provider's tool-call identifiers and its arguments -- so
  # the chunks are collected as they stream and handed to it afterwards. This is
  # what `StreamResponse.to_response/1` does, minus re-consuming a stream that
  # has already been drained once and cannot be drained twice.
  #
  # A builder that fails is a failed turn. It used to become `nil`, and `nil`
  # became empty text and no tool calls -- so the one reply shape that means "the
  # model asked for nothing and is done" was also the shape produced by a reply
  # nobody could assemble, and the loop would have ended the run on it.
  defp assemble(response, chunks, metadata) do
    builder = ReqLLM.Provider.ResponseBuilder.for_model(response.model)

    case builder.build_response(chunks, metadata,
           context: response.context,
           model: response.model
         ) do
      {:ok, assembled} -> {:ok, assembled}
      {:error, reason} -> {:error, {:reply_not_assembled, reason}}
      other -> {:error, {:reply_not_assembled, other}}
    end
  end

  # Concept: a call the model asked for either crosses this boundary whole or
  # does not cross it.
  #
  # Technical depth: the library reports arguments it could not rebuild -- a
  # stream cut inside the argument JSON, or fragments that never arrived -- by
  # keeping the call with empty arguments and recording the loss in its metadata.
  # Passing that on would present "call `write` with no arguments" as the model's
  # actual request. The metadata is also a provider term carrying a tuple, which
  # is not plain boundary data, so the check that refuses the call is the same
  # step that keeps the term from crossing: what crosses is exactly the
  # identifier, the name, and the decoded arguments.
  defp bounded_calls(assembled) do
    assembled
    |> ReqLLM.Response.tool_calls()
    |> Enum.reduce_while({:ok, []}, fn call, {:ok, built} ->
      case ReqLLM.ToolCall.to_map(call) do
        %{metadata: %{error: reason}} ->
          {:halt, {:error, {:tool_call_not_reconstructible, reason}}}

        %{id: id, name: name, arguments: arguments}
        when is_binary(id) and id != "" and is_binary(name) and name != "" and is_map(arguments) ->
          {:cont, {:ok, [%{id: id, name: name, arguments: arguments} | built]}}

        malformed ->
          {:halt, {:error, {:tool_call_not_reconstructible, malformed}}}
      end
    end)
    |> case do
      {:ok, built} -> {:ok, Enum.reverse(built)}
      {:error, reason} -> {:error, reason}
    end
  end

  # Concept: one provider chunk becomes as many bounded deltas as it needs, and
  # the deltas of one attempt are everything needed to rebuild the reply that
  # attempt returns.
  #
  # Technical depth: the reply's text is the concatenation of exactly these text
  # deltas rather than a second assembly of the same chunks, so replaying them is
  # byte-identical by construction and not by two code paths agreeing.
  #
  # A tool call is streamed as an opening chunk carrying the provider's call
  # identifier and the tool name with no arguments, followed by metadata chunks
  # carrying the argument JSON in fragments under the same content-block index.
  # Both become `tool_call_delta`s: the opening one names the call, each later
  # one carries the next fragment, and `call_index` is what ties them together --
  # so a consumer joins the fragments of one index and gets the exact JSON the
  # reply's arguments were decoded from. The previous version emitted one
  # argument-free delta per call and dropped the fragments entirely, which
  # described a call it could not reproduce.
  #
  # `content_index` is zero for text and reasoning because this adapter produces
  # one content part per attempt; a provider that interleaved several would need
  # it to say which, and this one does not. No delta carries a sequence: the
  # coordinator owns the sequence and the domain, and an adapter that supplied
  # either could misattribute an item to another attempt.
  defp emit(%{type: :content, text: fragment}, progress)
       when is_binary(fragment) and fragment != "" do
    deltas =
      Enum.map(split_progress_fragment(fragment), fn text ->
        %{kind: :text_delta, content_index: 0, text: text}
      end)

    case emit_checked(deltas, progress) do
      {:ok, count} -> {:text, fragment, count}
      {:error, reason} -> {:error, reason}
    end
  end

  defp emit(%{type: :thinking, text: fragment}, progress)
       when is_binary(fragment) and fragment != "" do
    deltas =
      Enum.map(split_progress_fragment(fragment), fn text ->
        %{kind: :reasoning_delta, content_index: 0, text: text}
      end)

    case emit_checked(deltas, progress) do
      {:ok, count} -> {:counted, count}
      {:error, reason} -> {:error, reason}
    end
  end

  defp emit(%{type: :tool_call, name: name} = chunk, progress)
       when is_binary(name) and name != "" do
    metadata = Map.get(chunk, :metadata) || %{}

    delta = %{
      kind: :tool_call_delta,
      call_index: call_index(metadata),
      tool_call_id: field(metadata, :id),
      name: name,
      arguments_fragment: nil
    }

    case emit_checked([delta], progress) do
      {:ok, count} -> {:counted, count}
      {:error, reason} -> {:error, reason}
    end
  end

  defp emit(%{type: :meta, metadata: metadata}, progress) when is_map(metadata) do
    case argument_fragment(metadata) do
      {index, fragment} ->
        deltas =
          Enum.map(split_progress_fragment(fragment), fn part ->
            %{
              kind: :tool_call_delta,
              call_index: index,
              tool_call_id: nil,
              name: nil,
              arguments_fragment: part
            }
          end)

        case emit_checked(deltas, progress) do
          {:ok, count} -> {:counted, count}
          {:error, reason} -> {:error, reason}
        end

      :none ->
        :ignored
    end
  end

  defp emit(_chunk, _progress), do: :ignored

  defp emit_checked(deltas, progress) do
    if Enum.all?(deltas, &Model.valid_delta?/1) do
      Enum.each(deltas, progress)
      {:ok, length(deltas)}
    else
      {:error, :provider_progress_not_bounded_plain_terminal_safe_data}
    end
  end

  defp split_progress_fragment(fragment) do
    if Loopex.ProgressPayload.terminal_safe?(fragment) do
      do_split_progress_fragment(fragment)
    else
      [fragment]
    end
  end

  defp do_split_progress_fragment(fragment)
       when byte_size(fragment) <= @progress_fragment_bytes,
       do: [fragment]

  defp do_split_progress_fragment(fragment) do
    size = utf8_prefix_size(fragment, @progress_fragment_bytes)
    <<prefix::binary-size(^size), rest::binary>> = fragment
    [prefix | do_split_progress_fragment(rest)]
  end

  defp utf8_prefix_size(fragment, size) do
    if String.valid?(binary_part(fragment, 0, size)) do
      size
    else
      utf8_prefix_size(fragment, size - 1)
    end
  end

  # Concept: read the provider's own argument fragment the way the library's own
  # assembler reads it, so the deltas and the reply cannot disagree about which
  # call a fragment belongs to.
  #
  # Technical depth: decoders reach this metadata with atom or string keys, and
  # the library's accumulator accepts both; accepting one here would silently
  # drop every fragment from the other kind of provider and leave a delta stream
  # that names a call whose arguments it never carried.
  defp argument_fragment(metadata) do
    case field(metadata, :tool_call_args) do
      arguments when is_map(arguments) ->
        case field(arguments, :fragment) do
          fragment when is_binary(fragment) and fragment != "" ->
            {call_index(arguments), fragment}

          _absent ->
            :none
        end

      _absent ->
        :none
    end
  end

  defp call_index(metadata) do
    case field(metadata, :index) do
      index when is_integer(index) and index >= 0 -> index
      _absent -> 0
    end
  end

  defp field(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp field(_absent, _key), do: nil

  # Concept: the identifier this call is known by in the provider's account.
  #
  # Technical depth: a streamed call cannot carry the assembled message
  # identifier, because the library keeps only usage from the provider's
  # `message_start` event and discards the rest. What survives is the response's
  # own `request-id` header, which the provider issues per call and which is the
  # identifier its account and its support surface use -- so it is the one an
  # auditor looks a retained claim up by, and the attestation declares its form.
  #
  # A provider that returns no such header yields `nil` rather than a
  # manufactured substitute, and an evidence claim built from replies carrying
  # none is refused rather than recorded.
  defp provider_request_id(metadata) do
    metadata
    |> Map.get(:headers, [])
    |> header("request-id")
  end

  defp header(headers, name) when is_list(headers) do
    Enum.find_value(headers, fn
      {key, value} when is_binary(key) -> if String.downcase(key) == name, do: present(value)
      _other -> nil
    end)
  end

  defp header(headers, name) when is_map(headers), do: headers |> Map.to_list() |> header(name)
  defp header(_headers, _name), do: nil

  defp present(value) when is_binary(value) and value != "", do: value
  defp present([value | _rest]), do: present(value)
  defp present(_absent), do: nil

  # Concept: render the whole committed conversation, not the last thing said.
  #
  # Technical depth: core stages the full history — the operator's prompt, the
  # model's own prior assistant messages with their tool calls, and the real
  # result of each call — and this adapter must carry all of it to the provider.
  # An earlier version sent only the most recent user message. Every test passed,
  # because fixtures read `request.messages` directly, and the real path was
  # nonetheless broken: the model saw its original instruction again on every
  # turn, never learned it had already done the work, and called the same tool
  # until the run hit its turn bound. A history the kernel commits and the edge
  # discards is not a history.
  #
  # Roles map onto the provider's own shapes rather than being flattened into
  # prose. A tool result rendered as text would read to the model as something
  # the operator said, which is exactly the confusion the role exists to prevent.
  defp context_of(%{messages: messages}) when is_list(messages) do
    case Enum.reduce_while(messages, {:ok, []}, &render_message/2) do
      {:ok, rendered} -> {:ok, ReqLLM.Context.new(Enum.reverse(rendered))}
      {:error, reason} -> {:error, reason}
    end
  end

  defp context_of(_request), do: {:error, :unsupported_model_request}

  defp render_message(%{"role" => "system", "content" => content}, {:ok, acc})
       when is_binary(content),
       do: {:cont, {:ok, [ReqLLM.Context.system(content) | acc]}}

  defp render_message(%{"role" => "user", "content" => content}, {:ok, acc})
       when is_binary(content),
       do: {:cont, {:ok, [ReqLLM.Context.user(content) | acc]}}

  defp render_message(%{"role" => "assistant"} = message, {:ok, acc}) do
    text = Map.get(message, "content", "")

    case Map.get(message, "tool_calls", []) do
      [] ->
        {:cont, {:ok, [ReqLLM.Context.assistant(text) | acc]}}

      calls ->
        # The provider's encoder accepts a plain map with the arguments already
        # decoded, so nothing here has to encode JSON. That matters: the ADR 0002
        # floor has neither `:json` nor `JSON`, and adding an encoder to reach a
        # provider would be an external dependency this edge is not permitted.
        rendered =
          Enum.map(calls, fn call ->
            %{
              id: call["tool_call_id"],
              name: provider_name(call),
              arguments: call["arguments"] || %{}
            }
          end)

        parts = if text in [nil, ""], do: [], else: [ReqLLM.Message.ContentPart.text(text)]

        {:cont,
         {:ok, [%ReqLLM.Message{role: :assistant, content: parts, tool_calls: rendered} | acc]}}
    end
  end

  defp render_message(%{"role" => "tool"} = message, {:ok, acc}) do
    content = Map.get(message, "content", "")
    id = Map.get(message, "tool_call_id")
    {:cont, {:ok, [ReqLLM.Context.tool_result(id, content) | acc]}}
  end

  defp render_message(_unknown, {:ok, acc}), do: {:cont, {:ok, acc}}

  # Concept: the name the provider knows a call by.
  #
  # Technical depth: a committed call carries its generation triple, and the
  # provider knows the tool by its model-visible name. The staged request carries
  # the definitions, so the name is recovered from the call's own tool_id rather
  # than guessed; a blank name is what made a second call render as `· ()` in the
  # operator's terminal.
  defp provider_name(call) do
    case call do
      %{"name" => name} when is_binary(name) and name != "" ->
        name

      %{"tool_id" => tool_id} when is_binary(tool_id) ->
        tool_id |> String.split(".") |> List.last()

      _absent ->
        "unknown"
    end
  end

  defp provider_tools(tools) when is_list(tools) do
    Enum.reduce_while(tools, {:ok, []}, fn definition, {:ok, built} ->
      case provider_tool(definition) do
        {:ok, tool} -> {:cont, {:ok, [tool | built]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, built} -> {:ok, Enum.reverse(built)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp provider_tool(%{
         "name" => name,
         "description" => description,
         "parameter_schema" => input_schema
       })
       when is_binary(name) and is_binary(description) and is_map(input_schema) do
    case ReqLLM.Tool.new(
           name: name,
           description: description,
           parameter_schema: input_schema,
           callback: fn _arguments -> {:error, :executor_boundary_required} end
         ) do
      {:ok, tool} -> {:ok, tool}
      {:error, _reason} -> {:error, :invalid_model_tool}
    end
  end

  defp provider_tool(_definition), do: {:error, :invalid_model_tool}

  # Concept: a provider error is bounded and stripped of the credential before
  # any caller, report, or terminal can see it.
  #
  # Technical depth: the limits cap an arbitrarily large error term, and the
  # substitution is unconditional rather than dependent on recognising which
  # field a provider chose to echo the key into. A drain driven without a
  # credential -- the conformance suite's -- still gets the bound, because the
  # bound is what makes the term plain boundary data and only the substitution
  # depends on there being a secret.
  @doc false
  @spec scrub_error(term(), binary() | nil) :: binary()
  def scrub_error(error, credential) do
    # The credential must remain visible to the scrubber before the diagnostic
    # is shortened. Truncating first can retain a long credential's prefix while
    # removing the complete value that replacement needs to find.
    {printable_limit, escaped_body} =
      case credential do
        value when is_binary(value) and value != "" ->
          escaped = inspect(value, printable_limit: :infinity)

          escaped_body =
            if String.starts_with?(escaped, "\"") and String.ends_with?(escaped, "\"") do
              binary_part(escaped, 1, byte_size(escaped) - 2)
            else
              escaped
            end

          # Any credential beginning inside the retained diagnostic must remain
          # complete long enough to be replaced. The escaped form can be larger
          # than the source bytes, so budget for the larger representation.
          {4_096 + max(byte_size(value), byte_size(escaped_body)), escaped_body}

        _absent ->
          {4_096, nil}
      end

    inspected = inspect(error, limit: 8, printable_limit: printable_limit)

    case credential do
      value when is_binary(value) and value != "" ->
        inspected
        |> redact_inspected_credential(value, escaped_body)
        |> inspect_bound()

      _absent ->
        inspect_bound(inspected)
    end
  end

  defp redact_inspected_credential(inspected, credential, escaped_body) do
    inspected
    |> String.replace(credential, @redacted)
    |> String.replace(escaped_body, @redacted)
  end

  # `inspect/2` bounds collection members and printable members, not the complete
  # rendered diagnostic. Keep the public failure plane bounded in bytes after
  # redaction; a character count would admit up to four times the declared
  # boundary for multibyte UTF-8. The inspected term is valid UTF-8, so at most
  # three trailing bytes need to be removed after a byte cut.
  defp inspect_bound(inspected) when byte_size(inspected) <= 4_096, do: inspected

  defp inspect_bound(inspected) do
    inspected
    |> binary_part(0, 4_096)
    |> valid_utf8_prefix()
  end

  defp valid_utf8_prefix(prefix) do
    if String.valid?(prefix) do
      prefix
    else
      valid_utf8_prefix(binary_part(prefix, 0, byte_size(prefix) - 1))
    end
  end

  defp endpoint(%{base_url: url}) when is_binary(url) and url != "", do: url
  defp endpoint(%{provider: provider}), do: provider_default_endpoint(provider)

  defp provider_default_endpoint(provider) do
    case ReqLLM.provider(provider) do
      {:ok, module} -> default_base_url(module)
      _other -> @unknown_endpoint
    end
  end

  defp default_base_url(module) do
    case Code.ensure_loaded?(module) and function_exported?(module, :default_base_url, 0) do
      true -> module.default_base_url()
      false -> @unknown_endpoint
    end
  end
end
