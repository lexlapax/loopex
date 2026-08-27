defmodule Loopex.LLM.ReqLLM.StreamingConformanceTest do
  @moduledoc false

  use ExUnit.Case, async: false

  alias Loopex.Model
  alias Loopex.StreamDomain
  alias LoopexProtocol.Canonical

  # Concept: one suite every shipped adapter satisfies, the one that ships
  # included.
  #
  # Technical depth: the suite is defined over a behaviour, not over a module, so
  # adding an adapter means adding it to this list rather than writing a second
  # suite that can drift from this one. The non-streaming adapter is a
  # first-class member: declaring that it does not stream is conformance, not an
  # exemption.

  defmodule Streaming do
    @moduledoc false
    @behaviour Loopex.Model

    @impl Loopex.Model
    def complete(request, options, progress \\ nil) do
      progress = progress || Model.discard_progress()
      chunks = Keyword.get(options, :chunks, ["Hel", "lo ", "world"])
      observer = Keyword.get(options, :observer)

      Enum.each(chunks, fn chunk ->
        progress.(%{kind: :text_delta, content_index: 0, text: chunk})
        if observer, do: send(observer, {:emitted, chunk})
      end)

      {:ok,
       %{
         text: Enum.join(chunks),
         identity: %{provider: "streaming", model: request.model, endpoint: "in-process"},
         usage: %{},
         tool_calls: [],
         delta_count: length(chunks),
         streamed: true,
         canonical_request_bytes: request.canonical_request_bytes,
         staged_request_digest: request.staged_request_digest
       }}
    end
  end

  defmodule Silent do
    @moduledoc false
    @behaviour Loopex.Model

    @impl Loopex.Model
    def complete(request, _options, _progress \\ nil) do
      {:ok,
       %{
         text: "no stream",
         identity: %{provider: "silent", model: request.model, endpoint: "in-process"},
         usage: %{},
         tool_calls: [],
         delta_count: 0,
         streamed: false,
         canonical_request_bytes: request.canonical_request_bytes,
         staged_request_digest: request.staged_request_digest
       }}
    end
  end

  defmodule Shipped do
    @moduledoc """
    ## Concept

    The adapter that actually ships, held to this suite rather than represented
    in it by a fake written to agree with it.

    ## Technical depth

    `Loopex.LLM.ReqLLM.complete/3` opens a provider connection, so the
    deterministic lane cannot call it. Everything downstream of that connection
    it can call: this module hands the shipped adapter's own
    `reply_from_stream/4` a `ReqLLM.StreamResponse` built here from the chunk
    shapes `deps/req_llm`'s Anthropic decoder produces -- a `:content` chunk per
    text delta, a `:tool_call` chunk carrying the call identifier and name with
    no arguments, and one `:meta` chunk per incremental argument fragment -- and
    the real `MetadataHandle`, `ResponseBuilder`, and catalog model the adapter
    would receive from a live call.

    So what the suite exercises here is production code: the shipped adapter's
    delta emission, its reply assembly, and its disposition of a stream that did
    not finish.

    What it does not exercise, and does not claim to: that a live provider's
    stream really carries these chunk shapes, that `ReqLLM.stream_text/3` is
    invoked correctly, that the credential path behaves, or that any network call
    happened at all. Nothing that runs offline can prove those, and this suite
    does not pretend otherwise. They belong to the `real_provider` lanes, which
    are excluded from every deterministic run: this application's
    `provider_test.exs` makes one real call through the whole adapter, and the
    command application's attended demonstration runs a real multi-turn coding
    task whose tool calls travel this same path.
    """

    @behaviour Loopex.Model

    alias Loopex.LLM.ReqLLM, as: Adapter

    @impl Loopex.Model
    def complete(request, options, progress \\ nil) do
      progress = progress || Model.discard_progress()
      Adapter.reply_from_stream(stream_response(options), request, identity(), progress)
    end

    @doc """
    The non-secret identity of the pinned reference model, resolved from the
    bundled catalog with no credential and no network.
    """
    def identity do
      {:ok, identity} = Adapter.identity(Adapter.default_model())
      identity
    end

    @doc """
    The metadata a provider that finished its turn cleanly leaves behind.
    """
    def clean_metadata do
      %{
        finish_reason: :stop,
        status: 200,
        headers: [{"request-id", "req_synthetic_conformance"}],
        usage: %{input_tokens: 3, output_tokens: 5}
      }
    end

    defp stream_response(options) do
      metadata = Keyword.get(options, :metadata, clean_metadata())
      {:ok, handle} = ReqLLM.StreamResponse.MetadataHandle.start_link(fn -> metadata end)

      %ReqLLM.StreamResponse{
        stream: stream(options),
        metadata_handle: handle,
        cancel: fn -> :ok end,
        model: model(),
        context: ReqLLM.Context.new([ReqLLM.Context.user("hi")])
      }
    end

    defp model do
      {:ok, model} = ReqLLM.model(Adapter.default_model())
      model
    end

    # Concept: a lazy stream, because a list would let the adapter look
    # incremental while draining everything before emitting anything.
    #
    # Technical depth: `:release_after_first` makes the stream block inside the
    # consuming process until the test releases it, so "a delta arrived while the
    # call had not returned" is proved by construction rather than by a sleep
    # that a loaded machine can invalidate.
    defp stream(options) do
      release = Keyword.get(options, :release_after_first)

      content =
        options
        |> Keyword.get(:chunks, ["Hel", "lo ", "world"])
        |> Enum.with_index()
        |> Stream.flat_map(fn {text, index} ->
          if release && index == 1, do: await_release(release)
          [ReqLLM.StreamChunk.text(text)]
        end)

      thinking =
        options
        |> Keyword.get(:thinking, [])
        |> Enum.map(&ReqLLM.StreamChunk.thinking/1)

      chunks = Stream.concat([content, thinking, tool_chunks(Keyword.get(options, :tool_call))])

      case Keyword.get(options, :cut_after_chunks, false) do
        false -> chunks
        true -> Stream.concat(chunks, Stream.map([:cut], fn _cut -> raise cut() end))
      end
    end

    defp await_release(release) do
      receive do
        {:release, ^release} -> :ok
      after
        5_000 -> :ok
      end
    end

    defp tool_chunks(nil), do: []

    defp tool_chunks({id, name, fragments}) do
      [ReqLLM.StreamChunk.tool_call(name, %{}, %{id: id, index: 1, start: true})] ++
        Enum.map(fragments, fn fragment ->
          ReqLLM.StreamChunk.meta(%{tool_call_args: %{index: 1, fragment: fragment}})
        end)
    end

    # Concept: exactly what the library raises out of its own lazy stream when a
    # provider connection fails part way through.
    defp cut do
      %ReqLLM.Error.API.Stream{reason: "Stream failed: closed", cause: :closed}
    end
  end

  @adapters [Streaming, Silent, Shipped]

  # Concept: the members of the suite that claim to stream, which are the ones a
  # replay property can be asked of at all.
  @replaying_adapters [Streaming, Shipped]

  defp request do
    {:ok, request} =
      Model.request("conformance:v1", [%{"role" => "user", "content" => "hi"}],
        sampling: %{"max_tokens" => 64},
        deadline: System.system_time(:millisecond) + 60_000
      )

    request
  end

  defp collect(adapter, options \\ []) do
    parent = self()
    reference = make_ref()

    progress = fn delta ->
      send(parent, {reference, delta})
      :ok
    end

    {:ok, reply} = adapter.complete(request(), options, progress)
    {reply, drain(reference, [])}
  end

  defp drain(reference, acc) do
    receive do
      {^reference, delta} -> drain(reference, [delta | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  test "every model adapter satisfies one streaming conformance suite" do
    for adapter <- @adapters do
      {reply, deltas} = collect(adapter)

      # The same contract holds for all of them: a complete reply, an honest
      # count, and an honest declaration of whether anything was streamed.
      assert is_binary(reply.text)
      assert is_integer(reply.delta_count) and reply.delta_count >= 0
      assert is_boolean(reply.streamed)
      assert reply.delta_count == length(deltas)
      assert reply.streamed == (deltas != [])

      # Every item an adapter put on the plane is one the port admits, so a
      # conformant adapter cannot be conformant only in the counting.
      assert Enum.all?(deltas, &Model.valid_delta?/1)

      # The coordinator owns the sequence and the domain. An adapter that
      # supplied either could number a delta into another attempt's stream, so
      # no adapter here supplies either.
      refute Enum.any?(deltas, &Map.has_key?(&1, :sequence))
      refute Enum.any?(deltas, &Map.has_key?(&1, :stream_domain_id))
      refute Enum.any?(deltas, &Map.has_key?(&1, :model_sequence))
    end
  end

  test "each canonical delta kind is bounded plain data carrying no provider or host term" do
    # Driven through the shipped adapter, because the kinds that carry provider
    # material -- a reasoning summary, a tool call identifier and its argument
    # fragments -- are the ones where a provider struct or an unbounded blob
    # would actually cross.
    {_reply, deltas} =
      collect(Shipped,
        chunks: ["Hel", "lo"],
        thinking: ["weighing "],
        tool_call: {"toolu_1", "write", [~s({"path":"a), ~s(.txt"})]}
      )

    assert deltas != []

    assert Enum.map(deltas, & &1.kind) |> Enum.uniq() |> Enum.sort() ==
             Enum.sort(Model.delta_kinds())

    for delta <- deltas do
      assert delta.kind in Model.delta_kinds()
      assert Model.valid_delta?(delta)

      # Plain data only: encoding it must not raise, which it does for a pid,
      # port, reference, or function anywhere inside.
      assert is_binary(Canonical.encode(delta))
    end

    # The fake adapter's deltas are held to the same rule.
    {_reply, fake_deltas} = collect(Streaming)
    assert Enum.all?(fake_deltas, &Model.valid_delta?/1)

    # A delta carrying a host term is refused rather than projected.
    refute Model.valid_delta?(%{kind: :text_delta, text: "x", owner: self()})
    refute Model.valid_delta?(%{kind: :not_a_kind, text: "x"})

    # And one past the declared payload ceiling is refused too.
    refute Model.valid_delta?(%{kind: :text_delta, text: String.duplicate("x", 70_000)})
  end

  test "the delta payload ceiling counts the provider-controlled call identifier and tool name" do
    # The defect this case holds down: the ceiling counted only the two fields
    # that obviously carry prose, while the shipped adapter fills `tool_call_id`
    # and `name` verbatim from the provider's stream. A delta carrying a
    # megabyte in either field passed the check and reached the progress plane.
    oversized = String.duplicate("a", 1_048_576)

    refute Model.valid_delta?(%{
             kind: :tool_call_delta,
             call_index: 0,
             tool_call_id: oversized,
             name: "write",
             arguments_fragment: nil
           })

    refute Model.valid_delta?(%{
             kind: :tool_call_delta,
             call_index: 0,
             tool_call_id: "toolu_1",
             name: oversized,
             arguments_fragment: nil
           })

    # The counted fields sum rather than being weighed one at a time, so two
    # halves of the ceiling in different fields is one delta past it.
    half = String.duplicate("b", 33_000)

    refute Model.valid_delta?(%{
             kind: :tool_call_delta,
             call_index: 0,
             tool_call_id: half,
             name: half,
             arguments_fragment: half
           })

    # A delta of the shape the shipped adapter actually emits is unaffected.
    assert Model.valid_delta?(%{
             kind: :tool_call_delta,
             call_index: 0,
             tool_call_id: "toolu_1",
             name: "write",
             arguments_fragment: ~s({"path":"a.txt"})
           })
  end

  test "a text delta is observable while its operation is still incomplete rather than after the reply returns" do
    parent = self()

    progress = fn delta ->
      send(parent, {:observed, delta})
      :ok
    end

    task =
      Task.async(fn ->
        Streaming.complete(request(), [chunks: ["a", "b", "c"], observer: parent], progress)
      end)

    # The first delta must arrive before the call returns. If deltas were only
    # flushed at completion this receive would time out.
    assert_receive {:observed, %{kind: :text_delta, text: "a"}}, 1_000

    {:ok, reply} = Task.await(task)
    assert reply.text == "abc"

    # The same, proved of the adapter that ships: its provider stream is held
    # open after the first chunk, so observing the first delta while the call
    # cannot yet have returned is a fact rather than a race won.
    release = make_ref()

    shipped =
      Task.async(fn ->
        Shipped.complete(
          request(),
          [chunks: ["a", "b", "c"], release_after_first: release],
          progress
        )
      end)

    assert_receive {:observed, %{kind: :text_delta, text: "a"}}, 1_000
    refute Task.yield(shipped, 0)

    send(shipped.pid, {:release, release})
    assert {:ok, shipped_reply} = Task.await(shipped)
    assert shipped_reply.text == "abc"
  end

  test "replaying an adapter's emitted deltas reproduces the reply it returned byte identically" do
    for adapter <- @replaying_adapters do
      {reply, deltas} = collect(adapter, chunks: ["Loo", "pex", " runs"])

      reconstructed =
        deltas
        |> Enum.filter(&(&1.kind == :text_delta))
        |> Enum.sort_by(& &1.content_index)
        |> Enum.map_join(& &1.text)

      assert reconstructed == reply.text
      assert :erlang.term_to_binary(reconstructed) == :erlang.term_to_binary(reply.text)
    end

    # A reply that contains a tool call is only reproducible from its deltas if
    # the deltas carry the call: which call, by what identifier, under what name,
    # and the argument bytes the reply's arguments were decoded from. Deltas that
    # merely announce that some call happened describe a reply they cannot
    # reproduce, which is the defect this asserts against.
    {reply, deltas} =
      collect(Shipped,
        chunks: ["Writing "],
        tool_call: {"toolu_1", "write", [~s({"path":"a), ~s(.txt"})]}
      )

    assert [%{id: "toolu_1", name: "write", arguments: %{"path" => "a.txt"}}] = reply.tool_calls
    assert replay_call(deltas, 1) == {"toolu_1", "write", ~s({"path":"a.txt"})}

    # And the fragments are the source of those arguments rather than something
    # emitted alongside them: change only the fragments and the reply follows.
    {other, other_deltas} =
      collect(Shipped,
        chunks: ["Writing "],
        tool_call: {"toolu_2", "edit", [~s({"path":"b), ~s(.txt"})]}
      )

    assert [%{id: "toolu_2", name: "edit", arguments: %{"path" => "b.txt"}}] = other.tool_calls
    assert replay_call(other_deltas, 1) == {"toolu_2", "edit", ~s({"path":"b.txt"})}
  end

  # Concept: everything a consumer holding only the deltas can rebuild about one
  # call.
  #
  # Technical depth: the opening delta names the call and the later ones carry
  # its argument JSON in order, all tied together by `call_index`. Joining them
  # yields the exact bytes the provider sent, which is what the reply's decoded
  # arguments came from.
  defp replay_call(deltas, call_index) do
    scoped =
      Enum.filter(deltas, &(&1.kind == :tool_call_delta and &1.call_index == call_index))

    opening = Enum.find(scoped, &(&1.tool_call_id != nil))

    arguments =
      scoped
      |> Enum.filter(& &1.arguments_fragment)
      |> Enum.map_join(& &1.arguments_fragment)

    {opening.tool_call_id, opening.name, arguments}
  end

  test "an interrupted stream is an error and never the partial text the adapter already streamed" do
    interruptions = [
      # The connection fails part way through, which the library reports by
      # raising out of the lazy stream the adapter is draining.
      {:connection_cut, [chunks: ["half a th"], cut_after_chunks: true]},
      # The stream collapsed and the failure reached the adapter only in the
      # metadata the provider left behind.
      {:metadata_error, [chunks: ["half a th"], metadata: %{error: :closed, headers: []}]},
      # A rate limit arrived after the provider had already sent content.
      {:provider_status,
       [chunks: ["half a th"], metadata: %{finish_reason: :stop, status: 429, headers: []}]},
      # The stream ended without the provider's terminal event, which is the
      # dangerous shape: it halts normally and says so only in the finish reason.
      {:no_terminal_event,
       [chunks: ["half a th"], metadata: %{finish_reason: :incomplete, headers: []}]}
    ]

    for {_label, options} <- interruptions do
      parent = self()

      progress = fn delta ->
        send(parent, {:delta, delta})
        :ok
      end

      assert {:error, {tag, detail}} = Shipped.complete(request(), options, progress)
      assert tag in [:stream_interrupted, :stream_failed, :stream_incomplete]

      # The reason is bounded plain data, so a coordinator can report it without
      # a provider term crossing the boundary.
      assert is_binary(detail)

      # The text really was streamed and really is thrown away. Core builds the
      # committed assistant message from the returned reply, and there is no
      # reply, so the operator's terminal showed a fragment and the session
      # commits nothing -- rather than committing the fragment as the answer.
      assert_received {:delta, %{kind: :text_delta, text: "half a th"}}
    end
  end

  test "a completion the provider finished with nothing to say is a success and not an interruption" do
    # The distinction the failure rule turns on: emptiness is not evidence of
    # interruption. A model that finished its turn having produced no text and
    # asked for no tool is a complete answer, and treating it as a cut stream
    # would refuse the reply that ends a run.
    assert {:ok, reply} = Shipped.complete(request(), [chunks: []], Model.discard_progress())

    assert reply.text == ""
    assert reply.tool_calls == []
    assert reply.delta_count == 0
    assert reply.streamed == false
    assert reply.provider_response_id == "req_synthetic_conformance"
  end

  test "a reply the provider's own builder cannot assemble is an error and never a completion with no tool calls" do
    # A builder failure used to become `nil`, and `nil` became empty text and no
    # tool calls -- the exact reply shape that means "the model asked for nothing
    # and is done", which is what the loop ends a run on. Any builder failure
    # will do here; the metadata below is one the library's own normaliser
    # refuses, and what is asserted is the adapter's disposition of it.
    unassemblable = %{finish_reason: :stop, status: 200, headers: [], usage: :not_a_usage_map}

    result =
      Shipped.complete(
        request(),
        [chunks: ["Hello"], metadata: unassemblable],
        Model.discard_progress()
      )

    assert {:error, {:reply_not_assembled, detail}} = result
    assert is_binary(detail)
    refute match?({:ok, %{tool_calls: []}}, result)
  end

  test "a tool call the stream cut short is an error and never a call with empty arguments" do
    # The provider opened a `write` call and the argument JSON never finished.
    # The library keeps the call with empty arguments and records the loss; a
    # reply carrying it would present "call write with no arguments" as what the
    # model asked for.
    cut_call = [
      chunks: [],
      tool_call: {"toolu_1", "write", [~s({"path":"a)]},
      metadata: %{finish_reason: :length, status: 200, headers: []}
    ]

    result =
      ExUnit.CaptureLog.capture_log(fn ->
        send(self(), {:result, Shipped.complete(request(), cut_call, Model.discard_progress())})
      end)

    assert is_binary(result)
    assert_received {:result, {:error, {:tool_call_not_reconstructible, detail}}}
    assert is_binary(detail)
  end

  test "the transport is bounded by the run's committed deadline and not by a library default" do
    # Concept: nothing bounds a real provider call except what the run declared.
    #
    # Technical depth: the streaming client applies its own 30-second receive
    # timeout when a call supplies none, and this adapter supplied none. That is
    # precisely the independent per-call timeout the committed absolute deadline
    # exists to replace: undeclared, absent from the journal, invisible to the
    # operator, and shorter than the bound the run actually chose. Under load it
    # fired with minutes of the declared deadline remaining, failing an attempt
    # for a reason nobody selected and nothing recorded -- which is how it was
    # found, as a gate lane that went red while two lanes on the same bytes went
    # green.
    #
    # The bound handed to the transport is now the remaining time on the run's
    # own deadline, so there is one bound rather than two and it is the declared
    # one.
    deadline = System.system_time(:millisecond) + 120_000

    {:ok, request} =
      Loopex.Model.request(
        Loopex.LLM.ReqLLM.default_model(),
        [%{"role" => "user", "content" => "bound"}],
        sampling: %{"max_tokens" => 32},
        deadline: deadline
      )

    bound = Loopex.LLM.ReqLLM.transport_bound(request)

    # It is the run's remaining time, not a constant. Anything near the
    # library's 30 seconds would mean the default is still governing.
    assert bound > 100_000 and bound <= 120_000,
           "the transport bound is #{bound}ms, which does not track the run's deadline"

    # And it is what a real call is actually made with.
    options = Loopex.LLM.ReqLLM.call_options(request, "credential", [])
    assert Keyword.fetch!(options, :receive_timeout) == Loopex.LLM.ReqLLM.transport_bound(request)

    # Every other option a call carries is a declared value too, so a bound this
    # adapter never chose cannot re-enter through one of them.
    assert Keyword.fetch!(options, :max_tokens) == 32
    assert Keyword.fetch!(options, :api_key) == "credential"

    # A run whose deadline has already passed still gets a bounded attempt
    # rather than a zero or negative timeout, which the transport would read as
    # its own default or as an immediate failure. Whether such a run should be
    # dispatched at all is the coordinator's decision and not this adapter's.
    {:ok, expired} =
      Loopex.Model.request(
        Loopex.LLM.ReqLLM.default_model(),
        [%{"role" => "user", "content" => "bound"}],
        sampling: %{"max_tokens" => 32},
        deadline: System.system_time(:millisecond) - 60_000
      )

    assert Loopex.LLM.ReqLLM.transport_bound(expired) == 1_000
  end

  test "the exported reply type names exactly the fields a reply carries" do
    # Concept: an embedder reads the exported type and reaches for a field.
    #
    # Technical depth: the type is a public contract, and the only way it stays
    # true is to check it against a reply production actually produced rather
    # than against a reading of the source. It named `canonical_request_digest`
    # while production returned `staged_request_digest` -- the rename that
    # separated the model request digest from the executor's attempt-bound job
    # digest reached the code and not the type -- so an embedder following it
    # fetched a key that was never there.
    assert {:ok, reply} = Shipped.complete(request(), [], Model.discard_progress())

    declared = declared_reply_fields()
    assert declared == reply |> Map.keys() |> Enum.sort()

    # Every field `Loopex.Model` requires of a reply is declared, and the field
    # the rename left behind is not.
    for required <- [
          :text,
          :identity,
          :usage,
          :tool_calls,
          :delta_count,
          :streamed,
          :canonical_request_bytes,
          :staged_request_digest
        ] do
      assert required in declared
    end

    refute :canonical_request_digest in declared
  end

  defp declared_reply_fields do
    {:ok, types} = Code.Typespec.fetch_types(Loopex.LLM.ReqLLM)

    {:type, {:reply, {:type, _line, :map, fields}, []}} =
      Enum.find(types, &match?({:type, {:reply, _definition, []}}, &1))

    fields
    |> Enum.map(fn {:type, _line, :map_field_exact, [{:atom, _key_line, name}, _value]} ->
      name
    end)
    |> Enum.sort()
  end

  test "the model and executor progress domains carry separate sequences each closed by its own content free item" do
    model_domain = StreamDomain.derive(:model, "s1", "op-1", 1)
    tool_domain = StreamDomain.derive(:executor, "s1", "op-1", 1)

    # Same session, same operation identity, same attempt: only the kind
    # differs, and that alone must separate the domains.
    assert model_domain != tool_domain

    model_closure = StreamDomain.model_closed("t1", model_domain, 0, :complete, 3)
    tool_closure = StreamDomain.tool_closed("t1", tool_domain, "c1", 0, :complete, 2)

    assert model_closure.stream_domain_id == model_domain
    assert tool_closure.stream_domain_id == tool_domain
    assert model_closure.delta_count == 3
    assert tool_closure.progress_count == 2

    # Content free: a closure carries counts and a disposition and no fragment of
    # what was streamed.
    refute Map.has_key?(model_closure, :text)
    refute Map.has_key?(tool_closure, :chunk)
  end

  test "a gapless sequence within one stream domain and its closing total make lost progress detectable" do
    domain = StreamDomain.derive(:model, "s1", "op-1", 1)
    delivered = for sequence <- 0..4, do: %{stream_domain_id: domain, model_sequence: sequence}
    closure = StreamDomain.model_closed("t1", domain, 0, :complete, 5)

    # ADR 0011 fixes the base: a model sequence starts at zero for each attempt
    # and increases by one per emitted delta. A suite that accepted a sequence
    # starting at one would protect the off-by-one instead of the algebra, and
    # the count would then have to be read as the last sequence rather than as a
    # total.
    assert Enum.min(Enum.map(delivered, & &1.model_sequence)) == 0
    assert gapless?(delivered) and length(delivered) == closure.delta_count

    # The closing total is a count and never a final sequence number, which is
    # what lets a domain that emitted nothing state zero exactly.
    assert closure.delta_count == Enum.max(Enum.map(delivered, & &1.model_sequence)) + 1

    # Drop one from the middle: the gap is detectable without any timeout.
    with_gap = List.delete_at(delivered, 2)
    refute gapless?(with_gap)

    # Drop the last: the sequence is still gapless, and only the closing total
    # reveals the loss. That is why closure carries a count at all.
    truncated = Enum.take(delivered, 4)
    assert gapless?(truncated)
    refute length(truncated) == closure.delta_count
  end

  defp gapless?(items) do
    items
    |> Enum.map(& &1.model_sequence)
    |> Enum.sort()
    |> Enum.with_index(0)
    |> Enum.all?(fn {sequence, expected} -> sequence == expected end)
  end

  test "the canonical identity encoding is injective and sampled distinct encodings derive stable distinct labels" do
    # A delimiter-joined identity would collide when an identifier contains the
    # delimiter. The canonical encoding is length-aware, so these stay distinct.
    colliding = [
      {"a:b", "c"},
      {"a", "b:c"},
      {"a", "bc"},
      {"ab", "c"}
    ]

    labels =
      for {session, operation} <- colliding do
        StreamDomain.derive(:model, session, operation, 1)
      end

    assert length(Enum.uniq(labels)) == length(labels)

    # Every label is the declared fixed width, and derivation is stable.
    for label <- labels do
      assert String.match?(label, ~r/^[0-9a-f]{32}$/)
    end

    assert StreamDomain.derive(:model, "s", "op", 1) ==
             StreamDomain.derive(:model, "s", "op", 1)

    # The attempt is the integer itself, not a rendering of it, so attempt 1 and
    # attempt "1" cannot be made to agree.
    assert StreamDomain.derive(:model, "s", "op", 1) !=
             StreamDomain.derive(:model, "s", "op", 2)
  end

  test "the committed assistant message is built from the reply and never assembled from deltas" do
    # The adapter's deltas deliberately disagree with the reply it returns. Core
    # has nothing to assemble from, so the committed text must follow the reply.
    defmodule Divergent do
      @moduledoc false
      @behaviour Loopex.Model

      @impl Loopex.Model
      def complete(request, _options, progress \\ nil) do
        progress = progress || Loopex.Model.discard_progress()
        progress.(%{kind: :text_delta, content_index: 0, text: "PARTIAL"})

        {:ok,
         %{
           text: "AUTHORITATIVE",
           identity: %{provider: "divergent", model: request.model, endpoint: "in-process"},
           usage: %{},
           tool_calls: [],
           delta_count: 1,
           streamed: true,
           canonical_request_bytes: request.canonical_request_bytes,
           staged_request_digest: request.staged_request_digest
         }}
      end
    end

    {reply, deltas} = collect(Divergent)

    assert reply.text == "AUTHORITATIVE"
    assert Enum.map_join(deltas, & &1.text) == "PARTIAL"
    refute reply.text =~ "PARTIAL"
  end

  test "a cancelled stream commits no assistant message and a late reply never becomes canonical" do
    # An adapter cancelled mid-stream returns no reply at all. Core builds the
    # committed assistant message from the adapter's return value, so there is
    # nothing to commit — not a partial message assembled from what did arrive.
    defmodule Cancelled do
      @moduledoc false
      @behaviour Loopex.Model

      @impl Loopex.Model
      def complete(_request, _options, progress \\ nil) do
        progress = progress || Loopex.Model.discard_progress()
        progress.(%{kind: :text_delta, content_index: 0, text: "half a th"})
        {:error, :cancelled}
      end
    end

    parent = self()

    observed =
      fn delta ->
        send(parent, {:delta, delta})
        :ok
      end

    assert {:error, :cancelled} = Cancelled.complete(request(), [], observed)
    assert_received {:delta, %{text: "half a th"}}

    # Deltas arrived, and no reply did. Core has nothing to assemble from, which
    # is what makes "commits no assistant message" structural rather than a rule
    # someone has to remember.
    refute match?({:ok, _reply}, Cancelled.complete(request(), [], observed))

    # The shipped adapter reaches the same place when its provider stream is cut,
    # so this is the runtime's behaviour and not only the fake's.
    assert {:error, _reason} =
             Shipped.complete(
               request(),
               [chunks: ["half a th"], cut_after_chunks: true],
               observed
             )

    assert_received {:delta, %{kind: :text_delta, text: "half a th"}}

    # The domain still closes, abandoned, stating what the coordinator observed.
    domain = StreamDomain.derive(:model, "s1", "op-1", 1)
    closure = StreamDomain.model_closed("t1", domain, 0, :abandoned, 1)
    assert closure.disposition == :abandoned
    assert closure.delta_count == 1

    # A late reply for that abandoned attempt belongs to a new domain, never to
    # the closed one, so it cannot be mistaken for the cancelled attempt's own.
    retried = StreamDomain.derive(:model, "s1", "op-1", 2)
    assert retried != domain
  end

  test "an adapter that emits no deltas is conformant and declares that it does not stream" do
    {reply, deltas} = collect(Silent)

    assert deltas == []
    assert reply.delta_count == 0
    assert reply.streamed == false
    assert reply.text == "no stream"

    # Its domain still closes, with a truthful zero rather than a sentinel or an
    # absent item a consumer would have to interpret.
    domain = StreamDomain.derive(:model, "s1", "op-1", 1)
    closure = StreamDomain.model_closed("t1", domain, 0, :complete, 0)
    assert closure.disposition == :complete
    assert closure.delta_count == 0
  end

  test "a provider retry opens a second stream domain under one turn and neither domain reports the other as loss" do
    # Same session, same model operation, two attempts. The staged bytes and
    # their digest are reused by a provider retry, so the attempt is the only
    # thing that differs — and it alone must separate the domains.
    first = StreamDomain.derive(:model, "s1", "model-op-1", 1)
    second = StreamDomain.derive(:model, "s1", "model-op-1", 2)

    assert first != second

    # Each carries its own sequence from zero, and each closes with its own
    # count. Both attempts starting at zero under one turn is exactly why the
    # domain has to exist: without it the second attempt's first delta reads as a
    # duplicate of the first attempt's.
    first_items = for n <- 0..2, do: %{stream_domain_id: first, model_sequence: n}
    second_items = for n <- 0..1, do: %{stream_domain_id: second, model_sequence: n}

    first_closure = StreamDomain.model_closed("t1", first, 0, :abandoned, 3)
    second_closure = StreamDomain.model_closed("t1", second, 0, :complete, 2)

    # Continuity is evaluated strictly within a domain. Neither domain sees the
    # other's items as a gap, because no comparison between two domains is
    # defined at all — two domains under one turn are the ordinary shape of a
    # retried turn rather than a fault.
    assert gapless?(first_items) and length(first_items) == first_closure.delta_count
    assert gapless?(second_items) and length(second_items) == second_closure.delta_count

    combined = first_items ++ second_items
    assert length(Enum.uniq_by(combined, & &1.stream_domain_id)) == 2

    for domain_id <- [first, second] do
      scoped = Enum.filter(combined, &(&1.stream_domain_id == domain_id))
      assert gapless?(scoped)
    end
  end

  test "a retried executor operation attempt opens its own stream domain closed by its own closure item and count" do
    first = StreamDomain.derive(:executor, "s1", "op-1", 1)
    second = StreamDomain.derive(:executor, "s1", "op-1", 2)

    assert first != second

    first_closure = StreamDomain.tool_closed("t1", first, "c1", 0, :abandoned, 4)
    second_closure = StreamDomain.tool_closed("t1", second, "c1", 0, :complete, 1)

    # One tool call, two attempts, two closures. Each states its own count, so a
    # consumer attributing progress per call still knows which attempt produced
    # what.
    assert first_closure.tool_call_id == second_closure.tool_call_id
    assert first_closure.stream_domain_id != second_closure.stream_domain_id
    assert first_closure.progress_count == 4
    assert second_closure.progress_count == 1
    assert first_closure.disposition == :abandoned
    assert second_closure.disposition == :complete
  end

  test "an abandoned domain is closed and stated rather than guessed from a stream that stopped" do
    domain = StreamDomain.derive(:model, "s1", "op-1", 1)
    closure = StreamDomain.model_closed("t1", domain, 0, :abandoned, 2)

    assert closure.disposition == :abandoned
    assert closure.delta_count == 2
    assert closure.disposition in StreamDomain.dispositions()

    # An abandoned domain is closed with what the coordinator observed, which is
    # exact because it stops accepting items once it has closed the domain.
    assert StreamDomain.dispositions() == [:complete, :abandoned]
  end
end
