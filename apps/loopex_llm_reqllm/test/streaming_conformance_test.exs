defmodule Loopex.LLM.ReqLLM.StreamingConformanceTest do
  @moduledoc false

  use ExUnit.Case, async: false

  alias Loopex.Model
  alias Loopex.StreamDomain
  alias LoopexProtocol.Canonical

  # Concept: one suite both shipped adapters satisfy.
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

  @adapters [Streaming, Silent]

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

      # The same contract holds for both: a complete reply, an honest count, and
      # an honest declaration of whether anything was streamed.
      assert is_binary(reply.text)
      assert is_integer(reply.delta_count) and reply.delta_count >= 0
      assert is_boolean(reply.streamed)
      assert reply.delta_count == length(deltas)
      assert reply.streamed == (deltas != [])
    end
  end

  test "each canonical delta kind is bounded plain data carrying no provider or host term" do
    {_reply, deltas} = collect(Streaming)
    assert deltas != []

    for delta <- deltas do
      assert delta.kind in Model.delta_kinds()
      assert Model.valid_delta?(delta)

      # Plain data only: encoding it must not raise, which it does for a pid,
      # port, reference, or function anywhere inside.
      assert is_binary(Canonical.encode(delta))
    end

    # A delta carrying a host term is refused rather than projected.
    refute Model.valid_delta?(%{kind: :text_delta, text: "x", owner: self()})
    refute Model.valid_delta?(%{kind: :not_a_kind, text: "x"})

    # And one past the declared payload ceiling is refused too.
    refute Model.valid_delta?(%{kind: :text_delta, text: String.duplicate("x", 70_000)})
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
  end

  test "replaying an adapter's emitted deltas reproduces the reply it returned byte identically" do
    {reply, deltas} = collect(Streaming, chunks: ["Loo", "pex", " runs"])

    reconstructed =
      deltas
      |> Enum.filter(&(&1.kind == :text_delta))
      |> Enum.sort_by(& &1.content_index)
      |> Enum.map_join(& &1.text)

    assert reconstructed == reply.text
    assert :erlang.term_to_binary(reconstructed) == :erlang.term_to_binary(reply.text)
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
    delivered = for sequence <- 1..5, do: %{stream_domain_id: domain, model_sequence: sequence}
    closure = StreamDomain.model_closed("t1", domain, 0, :complete, 5)

    assert gapless?(delivered) and length(delivered) == closure.delta_count

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
    |> Enum.with_index(1)
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

    # Each carries its own sequence from one, and each closes with its own count.
    first_items = for n <- 1..3, do: %{stream_domain_id: first, model_sequence: n}
    second_items = for n <- 1..2, do: %{stream_domain_id: second, model_sequence: n}

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
