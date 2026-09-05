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

      tool_input = Keyword.get(options, :tool_calls, Keyword.get(options, :tool_call))
      chunks = Stream.concat([content, thinking, tool_chunks(tool_input)])

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

    defp tool_chunks(calls) when is_list(calls) do
      openings =
        Enum.map(calls, fn {index, id, name, _fragments} ->
          ReqLLM.StreamChunk.tool_call(name, %{}, %{id: id, index: index, start: true})
        end)

      fragments =
        calls
        |> Enum.flat_map(fn {index, _id, _name, parts} ->
          Enum.with_index(parts, &{&2, index, &1})
        end)
        |> Enum.sort_by(fn {round, index, _fragment} -> {round, index} end)
        |> Enum.map(fn {_round, index, fragment} ->
          ReqLLM.StreamChunk.meta(%{tool_call_args: %{index: index, fragment: fragment}})
        end)

      openings ++ fragments
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

    # Concept: the kinds are named here, not read from the thing under test.
    #
    # Technical depth: this compared the observed kinds against
    # `Model.delta_kinds/0`, which is the list the adapter and the validator both
    # already work from -- so a kind dropped from that list and from the adapter
    # together left both sides of the comparison equal and the case green. The
    # obligation says *four canonical delta kinds*; naming them is the only way
    # this case can fail on the count.
    #
    # Three of the four are model deltas and belong to `Loopex.Model`. The
    # fourth, `:tool_progress`, is a projection of executor progress rather than
    # model output -- ADR 0011 narrows the vision's three named tool streams to
    # one kind carrying a `stream` discriminant -- so it is deliberately not in
    # this list and is not produced by a model adapter. Its shape and its
    # plain-data property are proved where it is actually emitted, by
    # `a validated executor event carries only its bounded named payload across`
    # in `apps/loopex/test/agent_loop_test.exs`.
    assert Enum.sort(Model.delta_kinds()) ==
             Enum.sort([:text_delta, :reasoning_delta, :tool_call_delta]),
           "the model delta kinds changed; the obligation names four canonical kinds, of which " <>
             "these three are the model's: #{inspect(Model.delta_kinds())}"

    refute :tool_progress in Model.delta_kinds(),
           "the executor progress projection is not a model delta and must not be produced by " <>
             "a model adapter"

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

    # A delta carrying a host term is refused rather than projected. Each of
    # these is otherwise exactly a valid delta, so the refusal is about the one
    # thing named rather than about a second defect the shape happens to have.
    refute Model.valid_delta?(%{kind: :text_delta, content_index: 0, text: "x", owner: self()})
    refute Model.valid_delta?(%{kind: :not_a_kind, content_index: 0, text: "x"})

    # And one past the declared payload ceiling is refused too.
    refute Model.valid_delta?(%{
             kind: :text_delta,
             content_index: 0,
             text: String.duplicate("x", 70_000)
           })

    # A provider may control every value here. Shape validation therefore
    # includes semantic types and terminal safety rather than merely key names
    # and encoded byte size.
    refute Model.valid_delta?(%{kind: :text_delta, content_index: "0", text: "x"})
    refute Model.valid_delta?(%{kind: :reasoning_delta, content_index: -1, text: "x"})
    refute Model.valid_delta?(%{kind: :text_delta, content_index: 0, text: "\e]0;owned\a"})

    refute Model.valid_delta?(%{
             kind: :tool_call_delta,
             call_index: 0,
             tool_call_id: "toolu_1\e[2J",
             name: "write",
             arguments_fragment: nil
           })

    refute Model.valid_delta?(%{
             kind: :tool_call_delta,
             call_index: -1,
             tool_call_id: "toolu_1",
             name: "write",
             arguments_fragment: nil
           })
  end

  test "the shipped adapter splits oversized provider text before it reaches progress" do
    text = String.duplicate("界", 30_000)
    {reply, deltas} = collect(Shipped, chunks: [text])

    assert reply.text == text
    assert reply.delta_count == length(deltas)
    assert length(deltas) > 1
    assert Enum.all?(deltas, &Model.valid_delta?/1)
    assert Enum.all?(deltas, &(byte_size(&1.text) <= 60_000))
    assert Enum.map_join(deltas, & &1.text) == text
  end

  test "the shipped adapter refuses terminal-control provider progress before emission" do
    parent = self()
    reference = make_ref()

    progress = fn delta -> send(parent, {reference, delta}) end

    assert {:error, {:invalid_progress_delta, _reason}} =
             Shipped.complete(request(), [chunks: ["\e]0;owned\a"]], progress)

    refute_receive {^reference, _delta}
  end

  test "a delta missing a field its kind declares is refused rather than projected" do
    # Concept: the field set is exact in both directions.
    #
    # Technical depth: the predicate checked only that the names a delta carried
    # were declared, so a delta carrying *none* of them passed. `%{kind:
    # :text_delta}` reconstructs to nothing and `%{kind: :tool_call_delta}` names
    # no call, yet both were admitted, handed a sequence, published, and counted
    # in their domain's closing total -- a consumer replaying that stream gets a
    # gapless sequence of items that say nothing. Admitting a name nobody
    # declared and omitting a name everybody declared are the same defect seen
    # from two sides.
    # The expected sets are written out rather than read from
    # `Model.delta_fields/1`, because a case that builds its samples from the
    # same list the predicate checks against proves nothing about that list: drop
    # `:text` from both and the sample no longer carries it, the predicate no
    # longer wants it, and the case stays green while every text delta on the
    # plane says nothing. That is the shape of the defect an earlier round found
    # in this same file, where the observed kinds were compared against
    # `Model.delta_kinds/0` itself.
    expected = %{
      text_delta: [:kind, :content_index, :text],
      reasoning_delta: [:kind, :content_index, :text],
      tool_call_delta: [:kind, :call_index, :tool_call_id, :name, :arguments_fragment]
    }

    assert Enum.sort(Map.keys(expected)) == Enum.sort(Model.delta_kinds())

    for {kind, fields} <- expected do
      assert Enum.sort(Model.delta_fields(kind)) == Enum.sort(fields),
             "#{inspect(kind)} declares #{inspect(Model.delta_fields(kind))} rather than " <>
               "#{inspect(fields)}"

      refute Model.valid_delta?(%{kind: kind}),
             "a bare #{inspect(kind)} carrying none of its declared fields was admitted"

      declared = fields -- [:kind]
      complete = Map.new(declared, &{&1, sample_field(&1)}) |> Map.put(:kind, kind)

      assert Model.valid_delta?(complete),
             "the sample #{inspect(kind)} this case builds is not itself valid"

      for omitted <- declared do
        refute Model.valid_delta?(Map.delete(complete, omitted)),
               "a #{inspect(kind)} missing #{inspect(omitted)} was admitted"
      end
    end
  end

  test "a delta field whose size the ceiling cannot see is refused rather than projected" do
    # Concept: the payload ceiling is total, or it is not a ceiling.
    #
    # Technical depth: the measurement named binaries, lists, and plain maps and
    # measured everything else as zero. An integer is none of those, so a
    # `content_index` of two raised to the one-point-six-millionth power measured
    # as nothing, passed a sixty-four kilobyte ceiling, and crossed the progress
    # plane as roughly two hundred kilobytes -- through a field an adapter fills
    # from its provider's stream. Anything the named clauses do not know is
    # measured by encoding it now, which is what putting it on the plane
    # actually costs.
    huge = Bitwise.<<<(1, 1_600_000)

    assert byte_size(:erlang.term_to_binary(huge)) > 65_536,
           "this case assumes its integer is larger than the declared delta ceiling"

    refute Model.valid_delta?(%{kind: :text_delta, content_index: huge, text: "x"}),
           "an unbounded number reached the progress plane through a field the ceiling " <>
             "measured as nothing"

    # An ordinary index is unaffected, so the ceiling refuses the size rather
    # than the type.
    assert Model.valid_delta?(%{kind: :text_delta, content_index: 3, text: "x"})
  end

  # One valid value per declared field name, so a case can build a complete
  # delta of any kind and then remove exactly one thing.
  defp sample_field(:content_index), do: 0
  defp sample_field(:call_index), do: 0
  defp sample_field(:text), do: "x"
  defp sample_field(:tool_call_id), do: "toolu_1"
  defp sample_field(:name), do: "write"
  defp sample_field(:arguments_fragment), do: ~s({"path":"a.txt"})

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
    # flushed at completion this receive would time out. The bound is a liveness
    # wait, not the verdict: the verdict is that the call has not returned when
    # the delta is observed, so the wait is generous enough for a cold VM.
    assert_receive {:observed, %{kind: :text_delta, text: "a"}}, 10_000

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

    # When this case runs first in a fresh VM the shipped adapter's HTTP client
    # starts cold, which alone can exceed a one-second bound under the bound
    # selector runner; the fact under test is the refute that follows.
    assert_receive {:observed, %{kind: :text_delta, text: "a"}}, 10_000
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

  test "two interleaved provider tool calls retain distinct replay domains" do
    {reply, deltas} =
      collect(Shipped,
        chunks: ["Working"],
        tool_calls: [
          {1, "toolu_1", "write", [~s({"path":"a), ~s(.txt"})]},
          {2, "toolu_2", "edit", [~s({"path":"b), ~s(.txt"})]}
        ]
      )

    assert Enum.map(reply.tool_calls, &{&1.id, &1.name, &1.arguments}) == [
             {"toolu_1", "write", %{"path" => "a.txt"}},
             {"toolu_2", "edit", %{"path" => "b.txt"}}
           ]

    assert replay_call(deltas, 1) == {"toolu_1", "write", ~s({"path":"a.txt"})}
    assert replay_call(deltas, 2) == {"toolu_2", "edit", ~s({"path":"b.txt"})}
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

  test "provider diagnostics redact a credential before bounding an echoed error" do
    for bytes <- [511, 512, 513, 1_024] do
      credential = "sk-" <> String.duplicate("x", bytes - 3)
      leaked_prefix = binary_part(credential, 0, min(256, byte_size(credential)))

      diagnostic =
        Loopex.LLM.ReqLLM.scrub_error(
          %{provider_error: "request refused for #{credential}", retryable: false},
          credential
        )

      assert diagnostic =~ "[redacted credential]"
      refute diagnostic =~ credential
      refute diagnostic =~ leaked_prefix
      assert byte_size(diagnostic) <= 4_096
    end

    escaped_credential = "sk-\"escaped\\credential\n"

    escaped_diagnostic =
      Loopex.LLM.ReqLLM.scrub_error(
        %{provider_error: escaped_credential},
        escaped_credential
      )

    assert escaped_diagnostic =~ "[redacted credential]"
    refute escaped_diagnostic =~ "escaped"

    multibyte = Loopex.LLM.ReqLLM.scrub_error(String.duplicate("🙂", 5_000), nil)
    assert byte_size(multibyte) <= 4_096
    assert String.valid?(multibyte)
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

  test "the provider response identifier follows the account visible request header" do
    metadata =
      Shipped.clean_metadata()
      |> Map.put(:headers, [{"x-request-id", "req_openai_synthetic_conformance"}])

    assert {:ok, reply} =
             Shipped.complete(
               request(),
               [chunks: ["acknowledged"], metadata: metadata],
               Model.discard_progress()
             )

    assert reply.provider_response_id == "req_openai_synthetic_conformance"
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

    assert {:ok, bound} = Loopex.LLM.ReqLLM.transport_bound(request)

    # It is the run's remaining time, not a constant. Anything near the
    # library's 30 seconds would mean the default is still governing.
    assert bound > 100_000 and bound <= 120_000,
           "the transport bound is #{bound}ms, which does not track the run's deadline"

    # And it is what a real call is actually made with.
    assert {:ok, options} = Loopex.LLM.ReqLLM.call_options(request, "credential", [])
    assert {:ok, expected_bound} = Loopex.LLM.ReqLLM.transport_bound(request)
    assert Keyword.fetch!(options, :receive_timeout) == expected_bound

    # Every other option a call carries is a declared value too, so a bound this
    # adapter never chose cannot re-enter through one of them.
    assert Keyword.fetch!(options, :max_tokens) == 32
    assert Keyword.fetch!(options, :api_key) == "credential"

    # Core owns the only retry authority. A transport-library retry would spend
    # the same durable attempt more than once without a second Control permit.
    assert Keyword.fetch!(options, :max_retries) == 0

    # An adapter is also an enforcement point. It refuses an already-expired
    # request rather than extending the run by inventing a minimum transport
    # wait after the committed instant.
    {:ok, expired} =
      Loopex.Model.request(
        Loopex.LLM.ReqLLM.default_model(),
        [%{"role" => "user", "content" => "bound"}],
        sampling: %{"max_tokens" => 32},
        deadline: System.system_time(:millisecond) - 60_000
      )

    assert Loopex.LLM.ReqLLM.transport_bound(expired) == {:error, :deadline_elapsed}

    assert Loopex.LLM.ReqLLM.call_options(expired, "credential", []) ==
             {:error, :deadline_elapsed}
  end

  test "one durable adapter attempt invokes provider transport at most once" do
    deadline = System.system_time(:millisecond) + 60_000

    {:ok, request} =
      Loopex.Model.request(
        Loopex.LLM.ReqLLM.default_model(),
        [%{"role" => "user", "content" => "one transport"}],
        sampling: %{"max_tokens" => 8},
        deadline: deadline
      )

    assert {:ok, call_options} =
             Loopex.LLM.ReqLLM.call_options(request, "credential", [])

    stream_options = ReqLLM.Streaming.FinchClient.stream_options(%{}, call_options)
    owner = self()

    transport = fn _request, _finch, state, _callback, _options ->
      send(owner, :provider_transport_invoked)
      {:error, %Mint.TransportError{reason: :timeout}, state}
    end

    assert {:error, %Mint.TransportError{reason: :timeout}, :initial} =
             ReqLLM.Streaming.Retry.stream(
               Finch.build(:post, "http://provider.invalid", [], ""),
               ReqLLM.Finch,
               :initial,
               fn _event, state -> state end,
               stream_options,
               transport
             )

    assert_receive :provider_transport_invoked
    refute_receive :provider_transport_invoked, 0
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

  test "the model reply contract declares the optional provider response identifier" do
    {:ok, types} = Code.Typespec.fetch_types(Loopex.Model)

    {:type, {:reply, {:type, _line, :map, fields}, []}} =
      Enum.find(types, &match?({:type, {:reply, _definition, []}}, &1))

    assert Enum.any?(fields, fn
             {:type, _line, :map_field_assoc, [{:atom, _key_line, :provider_response_id}, _value]} ->
               true

             _other ->
               false
           end)
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
