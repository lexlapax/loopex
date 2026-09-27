defmodule Loopex.LLM.ReqLLM do
  @moduledoc """
  ## Concept

  The reference model adapter runs each provider invocation in one host-owned
  companion BEAM. The parent maps a committed request and transient progress
  onto a bounded private channel; provider dependencies and credentials stay in
  the child. Starting this adapter never changes parent Logger configuration,
  application group leaders, or a shared ReqLLM supervisor.

  Hosts supply the trusted interpreter, worker artifact, and matching digests
  explicitly. Missing configuration refuses before dispatch. A host supplies an
  opaque credential token and routing-registry handle; a short-lived sender
  resolves them only after child readiness and writes the result to the private
  channel. The adapter call path never reads a credential from the environment.

  A complete reply crosses as bounded plain data. Partial streams, lost replies,
  channel failures after possible request delivery, and unproved cleanup never
  become successful short answers or permission to retry.

  ## Technical depth

  `complete/3` uses the configured bridge. `complete_prompt/3` builds a bounded
  standalone request and requires the same explicit launch configuration plus a
  cleanup period. The legacy bare-model `complete/2` has no such configuration
  and always refuses; there is no shared-VM fallback or ambient worker discovery.

  The companion starts ReqLLM only after protected entry and performs one
  `ReqLLM.stream_text/3` handoff with dependency retry disabled. A proved local
  pre-transport refusal is `{:error, {:not_dispatched, "model_call_failed"}}`.
  From possible invocation delivery onward, uncertainty is
  `{:error, {:dispatched_or_unknown, "model_call_failed"}}`; no raw provider
  reason leaves the child. An unreadable raw reply uses the Core-owned admission
  rule, not a lossy bridge reconstruction.

  Catalog lookup and already-open stream conversion remain ordinary adapter
  utilities. They neither launch a worker nor acquire a credential. The latter
  suppresses failure details rather than reading an ambient secret to redact
  them. `scrub_error/2` remains an explicit-value utility, not credential access.

  The private worker build, host configuration, and cleanup protocol are defined
  by ADR 0019. They change no Model callback, Core permit, or accounting authority.
  """

  @behaviour Loopex.Model

  alias Loopex.LLM.ReqLLM.{Mapping, ProviderBridge, ProviderConfiguration}
  alias Loopex.LLM.ReqLLM.TraceCapability.Direct
  alias Loopex.Model

  @credential_variable "LOOPEX_PROVIDER_API_KEY"

  # Concept: the pinned reference model. A provider-neutral credential name
  # cannot say which provider it belongs to, so the lane names the model it
  # calls and the operator points the credential at that provider.
  #
  # Technical depth: an operator whose credential belongs elsewhere overrides
  # the spec at the call site rather than editing this constant, because
  # `complete_prompt/3` takes the spec as an argument.
  @default_model "anthropic:claude-haiku-4-5"

  # Concept: one short answer is all the outcome needs; a ceiling keeps the
  # evidence run cheap and bounded.
  @max_tokens 64
  @progress_fragment_bytes 60_000

  @unknown_endpoint "unknown"
  @redacted "[redacted credential]"

  # Concept: a failed call reports its transport class and nothing else.
  #
  # Technical depth: ADR 0018 fixes the second element as this literal on both
  # classified errors. A caller reads the class and never the cause, so the
  # bound on what may cross this edge is the absence of a cause rather than a
  # scrubbing of one.
  @call_failed "model_call_failed"

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
  from the provider's per-call request identifier header (`request-id` or
  `x-request-id`), not an assembled message identifier. It is `nil` wherever the
  provider supplied none rather than being filled in with a plausible value.
  The field and its spelling alone do not prove a provider call: a deterministic
  adapter can fabricate an identifier. Retained real-call evidence needs the
  separate provider-account or support lookup required by its evidence contract;
  an unavailable lookup remains unavailable evidence.

  `staged_request_digest` names the request bytes core committed before this
  dispatch. It is spelled the way the reply this adapter actually returns spells
  it, so an embedder reading this type reaches a field production supplies rather
  than one that was renamed underneath it.

  `delta_count` and `streamed` are the attempt-private evidence `Loopex.Model`
  requires of every reply: what this adapter emitted and whether it streamed at
  all. These producer facts survive private-channel backpressure unchanged.
  The coordinator's transient domain closes with its own accepted-item count,
  which can be smaller when the best-effort channel dropped a delta.
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

  The environment variable reference hosts consume when composing provider
  credential custody.

  ## Technical depth

  Exposed so hosts and the real-provider lane can name the operator input
  without restating the string. Adapter invocation code never reads it.
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

  The legacy bare-model convenience entry refuses without host configuration.

  ## Technical depth

  Use `complete_prompt/3` with explicit worker paths, digests, and cleanup
  period. This arity cannot infer those choices or fall back to an unsafe
  shared-VM invocation.
  """
  @spec complete(String.t(), String.t()) :: {:error, {:not_dispatched, String.t()}}
  def complete(model_spec, prompt) when is_binary(model_spec) and is_binary(prompt),
    do: {:error, {:not_dispatched, @call_failed}}

  @doc """
  ## Concept

  Builds and dispatches one request with explicit host-owned provider protection.

  ## Technical depth

  Standalone callers supply the same launch options as the Model callback and
  an explicit cleanup period, opaque credential token and routing-registry
  handle. This helper adds the private no-runtime trace capability; callers
  cannot select a runtime-bound capability here. The request uses a 64-token
  output allowance and a 60-second deadline. A managed runtime instead supplies
  its own committed request, deadline, and cleanup period through `complete/3`.
  """
  @spec complete_prompt(String.t(), String.t(), keyword()) ::
          {:ok, reply()}
          | {:error, {:not_dispatched | :dispatched_or_unknown, String.t()}}
  def complete_prompt(model_spec, prompt, options)
      when is_binary(model_spec) and is_binary(prompt) and is_list(options) do
    with false <- Keyword.has_key?(options, :tracing_capability),
         {:ok, request} <-
           Model.request(model_spec, [%{"role" => "user", "content" => prompt}],
             sampling: %{"max_tokens" => @max_tokens},
             deadline: System.system_time(:millisecond) + 60_000
           ) do
      complete(
        request,
        Keyword.put(options, :tracing_capability, Direct.new()),
        Model.discard_progress()
      )
    else
      _refused -> {:error, {:not_dispatched, @call_failed}}
    end
  end

  def complete_prompt(_model_spec, _prompt, _options),
    do: {:error, {:not_dispatched, @call_failed}}

  @doc """
  ## Concept

  Dispatches exactly the committed request and returns one complete reply.

  ## Technical depth

  This adapter streams. The child accumulates the complete reply and offers
  deltas through a bounded, lossy progress channel. A saturated reader can miss
  deltas without shortening that reply or blocking cleanup. `delta_count` names
  what the producer emitted, not what a particular consumer received; Core owns
  the accepted count and closure of its separate transient stream domain.

  The stream is consumed once. Usage and the per-call request identifier are read
  from completed stream metadata after the content has drained. That ordering
  describes this adapter's read, not when the provider originally sent each
  metadata field.

  A stream that failed, was cut off, or produced a reply that could not be
  assembled is `{:error, {:dispatched_or_unknown, "model_call_failed"}}` instead
  of a reply. Deltas already emitted stay emitted; the coordinator closes that
  attempt's domain abandoned and commits no assistant message, which is what
  makes a partial answer impossible to mistake for a short one.

  Everything this function refuses on its own — a request that is not the one
  core committed, a message it cannot render, an absent credential, a model it
  cannot resolve, a tool definition it will not send, a deadline already spent —
  is `{:error, {:not_dispatched, "model_call_failed"}}`, and every one of those
  refusals happens before provider transport is entered.
  """
  @impl Loopex.Model
  @spec complete(Model.request(), keyword(), Model.progress_fun()) ::
          {:ok, reply()}
          | {:error, {:not_dispatched, String.t()}}
          | {:error, {:dispatched_or_unknown, String.t()}}
  def complete(request, options, progress)
      when is_map(request) and is_list(options) and is_function(progress, 1) do
    with {:ok, configuration} <- ProviderConfiguration.validate(options),
         :ok <- Model.validate_request(request) do
      ProviderBridge.complete(request, configuration, progress)
    else
      _refused -> {:error, {:not_dispatched, @call_failed}}
    end
  end

  def complete(_request, _options, _progress),
    do: {:error, {:not_dispatched, @call_failed}}

  # Concept: the private companion makes one provider invocation after its
  # protected channel is ready. No parent credential registry participates.
  # Technical depth: preflight and invocation have separate exception scopes.
  # Once `started` is called, no dependency result or exception can reclassify
  # the call as not dispatched. This entry has no production host-VM caller.
  @doc false
  def worker_invoke(request, credential, progress, started)
      when is_binary(credential) and is_function(progress, 1) and is_function(started, 0) do
    case worker_preflight(request, credential) do
      {:ok, context, identity, options} ->
        try do
          started.()

          case handoff(request, context, identity, options, credential, progress) do
            {:ok, reply} ->
              {:ok, reply}

            {:error, _sanitized, failure} ->
              {:error, {:dispatched_or_unknown, @call_failed}, failure}

            _failed ->
              worker_unknown()
          end
        rescue
          _error -> worker_unknown()
        catch
          _class, _reason -> worker_unknown()
        end

      _refused ->
        {:error, {:not_dispatched, @call_failed}}
    end
  end

  defp worker_preflight(request, credential) do
    with true <- byte_size(credential) in 1..65_536,
         :ok <- Model.validate_request(request),
         {:ok, context} <- Mapping.context_of(request),
         {:ok, identity} <- identity(request.model),
         {:ok, tools} <- Mapping.provider_tools(Model.model_facing_tools(request)),
         {:ok, options} <- call_options(request, credential, tools) do
      {:ok, context, identity, options}
    end
  rescue
    _error -> :refused
  catch
    _class, _reason -> :refused
  end

  @doc """
  ## Concept

  Provider options leave deadline and retry authority with the coordinator.

  ## Technical depth

  An expired request refuses before handoff. ReqLLM's relative total, stream-idle
  and receive timers are disabled, so an admitted unsigned-64-bit deadline never
  reaches a dependency timer. The coordinator's sliced committed deadline ends
  the attempt. Credentials remain parameters rather than committed request data.
  """
  @spec call_options(Model.request(), binary(), term()) ::
          {:ok, keyword()} | {:error, :deadline_elapsed}
  def call_options(request, credential, tools) do
    with {:ok, _bound} <- transport_bound(request) do
      {:ok,
       [
         api_key: credential,
         max_tokens: Model.max_tokens(request),
         tools: tools,
         total_timeout: :infinity,
         stream_idle_timeout: :infinity,
         receive_timeout: :infinity,
         max_retries: 0
       ]}
    end
  end

  @doc """
  ## Concept

  Remaining time on the request's committed deadline, checked before dispatch.

  ## Technical depth

  This admission check supplies no relative dependency timer. Each check uses
  the shared native conversion with one offset, retaining positive fractions.
  """
  @spec transport_bound(Model.request()) :: {:ok, pos_integer()} | {:error, :deadline_elapsed}
  def transport_bound(request) do
    deadline =
      Loopex.LLM.ReqLLM.Deadline.invocation_deadline(
        request.deadline,
        System.time_offset(:native)
      )

    case Loopex.LLM.ReqLLM.Deadline.remaining_timeout(deadline, System.monotonic_time()) do
      remaining when remaining > 0 -> {:ok, remaining}
      _elapsed -> {:error, :deadline_elapsed}
    end
  end

  # Concept: the position that decides the classification. Above it a refusal is
  # a refusal; from here on the only provable fact is that the request bytes were
  # handed over.
  #
  # Technical depth: ADR 0018 lets only an adapter that has neither invoked
  # provider transport nor handed request bytes to it answer `not_dispatched`,
  # and `ReqLLM.stream_text/3` is exactly that handoff. So a library error, an
  # unfinished stream, a reply that could not be assembled, a tool call that
  # could not be reconstructed, a timeout, a raise, a throw, an exit, a value of
  # no recognized shape, and a library result that tags itself `not_dispatched`
  # all collapse to the same ambiguity here. None of them observes the network,
  # and the tag a library supplies describes its own last step rather than the
  # handoff that already happened -- reading it would let the library overrule
  # the one fact this adapter actually knows.
  #
  # Each private boundary normalizes its reason into a fixed error and finite
  # pair before returning. `reply_from_stream/4` preserves its historical error
  # tag while dropping the pair; `complete/3` still exposes only generic failure.
  #
  # Technical depth: nothing raised, thrown, or exited under this call may leave
  # the worker uncaught. `call_options` carries the credential and is the
  # argument list of the frame this call sits on, so an uncaught error here is
  # reported by the VM with a stacktrace that can carry those arguments -- and
  # ADR 0018 requires credential-shaped raw errors to be absent from every
  # prohibited plane, of which the logger's crash report is one. Catching here
  # rather than reporting the reason keeps the same bounded classification the
  # branches below already produce.
  #
  # The companion's OS lifetime owns linked dependency deaths; the host bridge
  # classifies loss of that child as uncertainty without receiving a crash term.
  defp handoff(request, context, identity, call_options, credential, progress) do
    failure_stage("handoff", fn ->
      case ReqLLM.stream_text(request.model, context, call_options) do
        {:ok, response} -> drain(response, request, identity, progress, credential)
        {:error, _reason} = failed -> failed
        _failed -> {:error, {:provider_call_failed, @call_failed}}
      end
    end)
  end

  @doc """
  ## Concept

  Turns one already-open provider stream into the reply this adapter returns,
  emitting every delta on the way, or reports why that stream produced no reply
  at all.

  ## Technical depth

  This is the whole of the adapter's streaming behaviour that needs no network:
  which chunks become which deltas, how the reply is assembled from exactly those
  chunks, and which endings are failures rather than shorter answers. Both this
  helper and the child's transport path call the same drain implementation. The
  conformance suite supplies an already-open stream and proves conversion, not
  network dispatch or provider-process cleanup.

  The response is a `ReqLLM.StreamResponse` — accepted and read here, never
  returned. Failure categories stay bounded; all failure details are replaced
  by the fixed `"model_call_failed"` literal. This helper reads no credential
  and cannot know which secret its caller used to open an arbitrary stream.
  """
  @spec reply_from_stream(
          ReqLLM.StreamResponse.t(),
          Model.request(),
          identity(),
          Model.progress_fun()
        ) :: {:ok, reply()} | {:error, term()}
  def reply_from_stream(response, request, identity, progress)
      when is_map(request) and is_map(identity) and is_function(progress, 1) do
    case drain(response, request, identity, progress, nil) do
      {:ok, reply} -> {:ok, reply}
      {:error, {category, _discarded}, _failure} -> {:error, {category, @call_failed}}
    end
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
    failure_stage("stream", fn ->
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

              {:error, _reason} ->
                {:halt, {:error, {:invalid_progress_delta, @call_failed}}}
            end
        end)

      case emitted do
        {:ok, {chunks, text, deltas}} ->
          finish_drain(response, request, identity, chunks, text, deltas, credential)

        failure ->
          failure
      end
    end)
  end

  defp finish_drain(response, request, identity, chunks, text, deltas, _credential) do
    chunks = Enum.reverse(chunks)

    with {:ok, metadata} <-
           failure_stage("metadata", fn ->
             {:ok, ReqLLM.StreamResponse.MetadataHandle.await(response.metadata_handle)}
           end),
         :ok <- failure_stage("completion", fn -> Mapping.completed(metadata) end),
         {:ok, assembled} <-
           failure_stage("assembly", fn -> assemble(response, chunks, metadata) end),
         {:ok, calls} <- failure_stage("calls", fn -> Mapping.bounded_calls(assembled) end) do
      streamed = text |> Enum.reverse() |> IO.iodata_to_binary()
      {:ok, Mapping.reply(request, identity, metadata, streamed, calls, deltas)}
    end
  end

  # Concept: one unsuccessful boundary supplies the invocation's finite diagnosis.
  # Technical depth: normalize before discarding raw reasons, and propagate an
  # inner annotated failure unchanged. No process dictionary or event history is
  # needed; the caller receives only the original fixed error and one pair.
  defp failure_stage(stage, operation) do
    case operation.() do
      {:error, _sanitized, %{"stage" => _, "class" => _}} = failure ->
        failure

      {:error, {tag, _reason}} = error ->
        {:error, {tag, @call_failed}, Mapping.failure_pair(stage, Mapping.returned_class(error))}

      {:error, _reason} = error ->
        {:error, {:provider_call_failed, @call_failed},
         Mapping.failure_pair(stage, Mapping.returned_class(error))}

      success ->
        success
    end
  rescue
    exception ->
      {:error, {:stream_interrupted, @call_failed},
       Mapping.failure_pair(stage, Mapping.raised_class(exception))}
  catch
    kind, reason ->
      class =
        case {kind, reason} do
          {:exit, {:timeout, {GenServer, :call, _}}} -> "genserver_timeout"
          {:exit, _} -> "exited"
          {:throw, _} -> "thrown"
          _ -> "caught"
        end

      {:error, {:stream_interrupted, @call_failed}, Mapping.failure_pair(stage, class)}
  end

  defp worker_unknown,
    do:
      {:error, {:dispatched_or_unknown, @call_failed},
       Mapping.failure_pair("unavailable", "unclassified")}

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
