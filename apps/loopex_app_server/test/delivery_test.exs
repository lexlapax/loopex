Code.require_file("../../loopex/test/support/m1_runtime_helper.exs", __DIR__)
Code.require_file("../../loopex/test/support/agent_loop_helper.exs", __DIR__)

defmodule Loopex.AppServer.DeliveryTest do
  @moduledoc """
  ## Concept

  Durable events and transient progress travel to a client on separate terms.
  An event advances the client's cursor and is never dropped quietly; progress
  does not and may be. A writer that cannot keep up with durable history is
  detached at the exact cursor it reached.

  ## Technical depth

  Accepted ADR 0023 bounds the two planes separately, and the asymmetry is the
  point: a lost durable event leaves a client's view permanently wrong, while
  lost progress costs only smoothness. The cases drive the real committed events
  of a real run through the queue, so the projection is checked against what the
  runtime actually publishes rather than against a shape this test invented.
  """

  use ExUnit.Case, async: false

  alias Loopex.AgentLoopFixture, as: Fixture
  alias Loopex.AppServer.Delivery
  alias LoopexProtocol.Wire

  test "a durable event becomes one record carrying its kind, identity and sequence" do
    [event | _rest] = committed_events()

    queue = Delivery.new("s_1", 0)
    {[record], _drained} = queue |> Delivery.event(event) |> Delivery.take()

    assert record["type"] == "event"
    assert {:ok, "s_1"} = Wire.identity(record["session_id"])

    body = record["event"]
    assert body["kind"] == event.kind
    assert {:ok, event.event_id} == Wire.identity(body["event_id"])
    assert {:ok, event.event_sequence} == Wire.u64(body["event_sequence"])

    # The envelope carries the identity and the sequence; the data carries what
    # the kind itself says and keeps its own member names.
    refute Map.has_key?(body["data"], :kind)
    refute Map.has_key?(body["data"], :event_id)
    refute Map.has_key?(body["data"], :event_sequence)
  end

  test "only a durable event advances the cursor" do
    [event | _rest] = committed_events()

    queue = Delivery.new("s_1", 0)
    assert Delivery.cursor(queue) == 0

    advanced = Delivery.event(queue, event)
    assert Delivery.cursor(advanced) == event.event_sequence

    unchanged = Delivery.progress(advanced, text_item("x", 0, event.event_sequence))
    assert Delivery.cursor(unchanged) == event.event_sequence
  end

  test "maintenance events share the closed codec with exact quantities and opaque identities" do
    path = Path.join(:code.priv_dir(:loopex_protocol), "vectors/maintenance-view.v1.json")
    cases = JSON.decode!(File.read!(path))["cases"]

    for name <- [
          "inactive",
          "run-captured-null-deadline",
          "compact-captured-ceilings",
          "run-unbounded-bounds.token_budget"
        ] do
      wire = Enum.find(cases, &(&1["name"] == name))["input"]
      assert {:ok, native} = LoopexProtocol.Session.MaintenanceView.decode_wire(wire)

      event =
        Map.merge(native, %{
          kind: "context.maintenance_changed",
          event_id: "view",
          event_sequence: 1
        })

      {[record], _} = Delivery.new("session", 0) |> Delivery.event(event) |> Delivery.take()
      assert record["event"]["data"] == wire
      assert record["event"]["kind"] == "context.maintenance_changed"

      assert {:ok, ^native} =
               LoopexProtocol.Session.MaintenanceView.decode_wire(record["event"]["data"])
    end
  end

  test "both checkpoint owner kinds preserve opaque bytes in the foreground envelope" do
    for kind <- ["run", "compact"] do
      event = %{
        :kind => "context.compacted",
        :event_id => "event",
        :event_sequence => 1,
        "owner" => %{"kind" => kind, "id" => <<0, 255, 10>>}
      }

      {[record], drained} = Delivery.new("session", 0) |> Delivery.event(event) |> Delivery.take()
      assert record["event"]["data"] == %{"owner" => %{"kind" => kind, "id" => "AP8K"}}
      assert Delivery.cursor(drained) == 1
      assert {:ok, _} = LoopexProtocol.Frame.encode(record)
    end
  end

  test "completed compaction events preserve each closed result and refuse private data" do
    path =
      Path.join(:code.priv_dir(:loopex_protocol), "vectors/standalone-compact-completion.v1.json")

    cases = JSON.decode!(File.read!(path))["cases"]

    for vector <- cases, is_nil(vector["error"]) do
      wire = vector["input"]
      assert {:ok, native} = LoopexProtocol.Session.CompactResult.decode_completion(wire)

      event =
        Map.merge(native, %{
          kind: "context.compaction_finished",
          event_id: "finished",
          event_sequence: 1
        })

      {[record], _} = Delivery.new("session", 0) |> Delivery.event(event) |> Delivery.take()
      assert record["event"]["data"] == wire
      assert {:ok, _} = LoopexProtocol.Frame.encode(record)

      assert_raise MatchError, fn ->
        Delivery.event(
          Delivery.new("session", 0),
          Map.put(event, "source", "PRIVATE_COMPLETION_CANARY")
        )
      end
    end
  end

  test "durable records are emitted ahead of progress" do
    [event | _rest] = committed_events()

    {records, _drained} =
      Delivery.new("s_1", 0)
      |> Delivery.progress(text_item("first offered", 0, 0))
      |> Delivery.event(event)
      |> Delivery.take()

    assert Enum.map(records, & &1["type"]) == ["event", "progress"]
  end

  test "a writer that cannot keep up detaches at the cursor it reached" do
    [event | _rest] = committed_events()

    queue =
      Enum.reduce(1..100, Delivery.new("s_1", 0), fn index, queue ->
        Delivery.event(queue, %{event | event_sequence: index})
      end)

    assert Delivery.detached?(queue)

    # The cursor is the last one completely queued, not the last one offered.
    cursor = Delivery.cursor(queue)
    assert cursor > 0
    assert cursor < 100

    detachment = Delivery.detachment(queue)
    assert detachment["type"] == "error"
    assert detachment["code"] == "detached"
    assert {:ok, ^cursor} = Wire.u64(detachment["event_cursor"])

    # Nothing is delivered after the detachment.
    assert Delivery.event(queue, event) == queue
    assert Delivery.progress(queue, %{kind: "text_delta"}) == queue
  end

  test "progress that does not fit is dropped and never detaches the writer" do
    queue =
      Enum.reduce(1..200, Delivery.new("s_1", 0), fn index, queue ->
        Delivery.progress(queue, text_item("item #{index}", index - 1, 0))
      end)

    refute Delivery.detached?(queue)

    {records, _drained} = Delivery.take(queue)
    assert length(records) == 32
    assert Enum.all?(records, &(&1["type"] == "progress"))
  end

  test "a progress record places itself against durable history without advancing it" do
    queue =
      Delivery.progress(Delivery.new("s_1", 7), text_item("a delta", 0, 7))

    {[record], _drained} = Delivery.take(queue)

    body = record["progress"]
    assert {:ok, "0123456789abcdef0123456789abcdef"} = Wire.identity(body["stream_domain_id"])
    assert {:ok, 7} = Wire.u64(body["base_event_sequence"])
    assert Delivery.cursor(queue) == 7
  end

  test "taking twice does not deliver the same record twice" do
    [event | _rest] = committed_events()

    {first, drained} = Delivery.new("s_1", 0) |> Delivery.event(event) |> Delivery.take()
    {second, _again} = Delivery.take(drained)

    assert length(first) == 1
    assert second == []
  end

  test "compaction activity uses the exact closed envelope for both owners without advancing history" do
    for kind <- ["run", "compact"], base <- [0, 18_446_744_073_709_551_615] do
      item = compaction_item(kind, base)

      {[record], drained} =
        Delivery.new(<<255, 0>>, base) |> Delivery.progress(item) |> Delivery.take()

      assert record == compaction_record(kind, base)
      assert Delivery.cursor(drained) == base

      assert {:ok, ^item} =
               LoopexProtocol.Session.CompactionProgress.decode_wire(record["progress"])

      assert {:ok, _} = LoopexProtocol.Frame.encode(record)
    end
  end

  test "malformed compaction activity drops whole before private values can reach encoding" do
    item = compaction_item("run", 0)
    queue = Delivery.new("session", 0)

    for invalid <- [
          Map.put(item, :summary, "PRIVATE_CANARY"),
          Map.put(item, :permit, fn -> :private end),
          Map.delete(item, :episode_id),
          Map.put(item, :owner, %{"kind" => "run", "id" => nil}),
          Map.put(item, :stream_domain_id, String.duplicate("A", 32)),
          Map.put(item, :episode_id, :binary.copy(<<255>>, 65_537)),
          Map.put(item, :base_event_sequence, 18_446_744_073_709_551_616),
          Map.put(item, :__struct__, __MODULE__),
          %{"kind" => "context.compaction_progress", "summary" => fn -> :private end}
        ] do
      assert Delivery.progress(queue, invalid) == queue
    end
  end

  test "compaction records obey the unchanged transient record ceiling and durable priority" do
    item = compaction_item("compact", 7)

    queue =
      Enum.reduce(1..33, Delivery.new(<<255, 0>>, 7), fn _, queue ->
        Delivery.progress(queue, item)
      end)

    refute Delivery.detached?(queue)
    assert Delivery.cursor(queue) == 7
    {records, _} = Delivery.take(queue)
    assert length(records) == 32
    assert Enum.all?(records, &(&1 == compaction_record("compact", 7)))

    event = %{kind: "run.progressed", event_id: "event", event_sequence: 8}
    {[durable | activity], drained} = queue |> Delivery.event(event) |> Delivery.take()
    assert durable["type"] == "event"
    assert length(activity) == 32
    assert Delivery.cursor(drained) == 8
  end

  test "maximum valid identities spend the unchanged progress byte budget independently" do
    bytes = :binary.copy(<<255>>, 65_536)

    item = %{
      compaction_item("run", 0)
      | episode_id: bytes,
        owner: %{"kind" => "run", "id" => bytes}
    }

    queue =
      Enum.reduce(1..3, Delivery.new("session", 0), fn _, queue ->
        Delivery.progress(queue, item)
      end)

    refute Delivery.detached?(queue)
    {records, _} = Delivery.take(queue)
    assert length(records) == 2

    sizes =
      Enum.map(records, fn record ->
        assert {:ok, encoded} = LoopexProtocol.Frame.encode(record)
        IO.iodata_length(encoded)
      end)

    assert Enum.sum(sizes) <= 524_288
    assert Enum.sum(sizes) + hd(sizes) > 524_288
  end

  test "ordinary progress encodes all six native kinds with exact identities and u64 edges" do
    for quantity <- [0, 18_446_744_073_709_551_615],
        {item, expected} <- ordinary_cases(quantity) do
      assert_ordinary_record(item, expected)
    end
  end

  test "tool call progress preserves every permitted nullable combination" do
    for id <- [nil, <<0, 255, 128>>], name <- [nil, "tool"], fragment <- [nil, "{}"] do
      item = %{
        text_item("unused", 0, 0)
        | kind: :tool_call_delta
      }

      item =
        item
        |> Map.drop([:content_index, :text])
        |> Map.merge(%{
          call_index: 0,
          tool_call_id: id,
          name: name,
          arguments_fragment: fragment
        })

      expected = %{
        "kind" => "tool_call_delta",
        "turn_id" => "AP-A",
        "stream_domain_id" => "MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY",
        "model_sequence" => "0",
        "base_event_sequence" => "0",
        "call_index" => 0,
        "tool_call_id" => if(is_nil(id), do: nil, else: "AP-A"),
        "name" => name,
        "arguments_fragment" => fragment
      }

      assert_ordinary_record(item, expected)
    end
  end

  test "ordinary progress refuses private fields and malformed native members whole" do
    for {item, _expected} <- ordinary_cases(0) do
      for invalid <- [
            Map.put(item, :credential, "PRIVATE_PROGRESS_CANARY"),
            Map.put(item, :permit, fn -> :private end),
            Map.put(item, :owner_pid, self()),
            Map.put(item, :monitor, make_ref()),
            Map.put(item, :__struct__, __MODULE__),
            Map.put(item, :turn_id, nil),
            Map.put(item, :turn_id, ""),
            Map.put(item, :turn_id, :binary.copy(<<255>>, 65_537)),
            Map.put(item, :stream_domain_id, String.duplicate("A", 32)),
            Map.put(item, :stream_domain_id, String.duplicate("a", 31)),
            Map.put(item, :kind, Atom.to_string(item.kind)),
            Map.new(item, fn {key, value} -> {Atom.to_string(key), value} end)
          ] do
        assert_ordinary_refusal(invalid)
      end

      for field <- Map.keys(item), do: assert_ordinary_refusal(Map.delete(item, field))

      if Map.has_key?(item, :tool_call_id) do
        for value <- ["", :binary.copy(<<255>>, 65_537), fn -> :private end] do
          assert_ordinary_refusal(Map.put(item, :tool_call_id, value))
        end

        if item.kind != :tool_call_delta,
          do: assert_ordinary_refusal(Map.put(item, :tool_call_id, nil))
      end

      for field <- [
            :model_sequence,
            :progress_sequence,
            :base_event_sequence,
            :byte_offset,
            :delta_count,
            :progress_count
          ],
          Map.has_key?(item, field),
          invalid <- [nil, -1, 18_446_744_073_709_551_616, "0", 0.0] do
        assert_ordinary_refusal(Map.put(item, field, invalid))
      end

      for field <- [:content_index, :call_index],
          Map.has_key?(item, field),
          invalid <- [nil, -1, 9_007_199_254_740_992, 0.0] do
        assert_ordinary_refusal(Map.put(item, field, invalid))
      end

      for field <- [:text, :name, :arguments_fragment, :chunk],
          Map.has_key?(item, field),
          invalid <- [<<255>>, "\e[31mprivate", fn -> :private end] do
        assert_ordinary_refusal(Map.put(item, field, invalid))
      end
    end

    for invalid <- [nil, [], fn -> :private end, %{kind: :unknown}] do
      assert_ordinary_refusal(invalid)
    end

    [{tool, _}] =
      Enum.filter(ordinary_cases(0), fn {item, _} ->
        item.kind == :tool_progress and item.stream == "stdout"
      end)

    for invalid <- [
          Map.put(tool, :stream, "other"),
          Map.put(tool, :tool_call_id, nil),
          Map.put(tool, :tool_call_id, ""),
          Map.put(tool, :chunk, nil)
        ] do
      assert_ordinary_refusal(invalid)
    end

    for {item, _} <- ordinary_cases(0),
        Map.has_key?(item, :disposition),
        invalid <- [nil, "complete", :other] do
      assert_ordinary_refusal(Map.put(item, :disposition, invalid))
    end
  end

  test "ordinary payload ceilings include model indices and all tool call fragments" do
    text = String.duplicate("x", 65_536 - byte_size(:erlang.term_to_binary(0)))
    item = text_item(text, 0, 0)

    expected = %{
      "kind" => "text_delta",
      "turn_id" => "AP-A",
      "stream_domain_id" => "MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY",
      "model_sequence" => "0",
      "base_event_sequence" => "0",
      "content_index" => 0,
      "text" => text
    }

    assert_ordinary_record(item, expected)
    assert_ordinary_record(%{item | text: ""}, Map.put(expected, "text", ""))
    assert_ordinary_refusal(Map.put(item, :text, text <> "x"))

    [{call, _}] =
      Enum.filter(ordinary_cases(0), fn {item, _} -> item.kind == :tool_call_delta end)

    assert_ordinary_refusal(%{
      call
      | tool_call_id: String.duplicate("i", 32_768),
        name: String.duplicate("n", 32_768),
        arguments_fragment: ""
    })

    [{tool, expected}] =
      Enum.filter(ordinary_cases(0), fn {item, _} ->
        item.kind == :tool_progress and item.stream == "stdout"
      end)

    chunk = String.duplicate("x", 65_536)

    assert_ordinary_record(
      %{tool | chunk: chunk},
      Map.put(expected, "chunk_b64", Base.url_encode64(chunk, padding: false))
    )

    assert_ordinary_record(%{tool | chunk: ""}, Map.put(expected, "chunk_b64", ""))
    assert_ordinary_refusal(%{tool | chunk: chunk <> "x"})
  end

  test "maximum opaque ordinary identities retain bytes and obey existing encoded limits" do
    bytes = :binary.copy(<<255>>, 65_536)

    [{tool, expected}] =
      Enum.filter(ordinary_cases(0), fn {item, _} ->
        item.kind == :tool_progress and item.stream == "stdout"
      end)

    item = %{tool | turn_id: bytes, tool_call_id: bytes}

    expected =
      Map.merge(expected, %{
        "turn_id" => Base.url_encode64(bytes, padding: false),
        "tool_call_id" => Base.url_encode64(bytes, padding: false)
      })

    record = assert_ordinary_record(item, expected)
    assert {:ok, ^bytes} = LoopexProtocol.Wire.identity(record["progress"]["turn_id"])
    assert {:ok, ^bytes} = LoopexProtocol.Wire.identity(record["progress"]["tool_call_id"])

    for {closure, wire} <- ordinary_cases(0), Map.has_key?(closure, :disposition) do
      closure = Map.put(closure, :turn_id, bytes)
      wire = Map.put(wire, "turn_id", Base.url_encode64(bytes, padding: false))

      {closure, wire} =
        if Map.has_key?(closure, :tool_call_id) do
          {Map.put(closure, :tool_call_id, bytes),
           Map.put(wire, "tool_call_id", Base.url_encode64(bytes, padding: false))}
        else
          {closure, wire}
        end

      assert_ordinary_record(closure, wire)
    end

    assert_ordinary_refusal(%{item | turn_id: bytes <> <<255>>})
    assert_ordinary_refusal(%{item | tool_call_id: bytes <> <<255>>})

    queue =
      Enum.reduce(1..3, Delivery.new("session", 7), fn _, queue ->
        Delivery.progress(queue, item)
      end)

    {records, drained} = Delivery.take(queue)
    assert length(records) == 2
    refute Delivery.detached?(drained)
    assert Delivery.cursor(drained) == 7

    sizes =
      Enum.map(records, fn record ->
        assert {:ok, encoded} = LoopexProtocol.Frame.encode(record)
        IO.iodata_length(encoded)
      end)

    assert Enum.sum(sizes) <= 524_288
    assert Enum.sum(sizes) + hd(sizes) > 524_288
    session = :binary.copy(<<255>>, 256)
    {[session_record], _} = Delivery.new(session, 0) |> Delivery.progress(tool) |> Delivery.take()
    assert {:ok, ^session} = LoopexProtocol.Wire.session_identity(session_record["session_id"])

    assert Delivery.progress(Delivery.new(:binary.copy(<<255>>, 257), 0), tool) ==
             Delivery.new(:binary.copy(<<255>>, 257), 0)
  end

  defp text_item(text, sequence, base) do
    %{
      kind: :text_delta,
      turn_id: <<0, 255, 128>>,
      stream_domain_id: "0123456789abcdef0123456789abcdef",
      model_sequence: sequence,
      base_event_sequence: base,
      content_index: 0,
      text: text
    }
  end

  defp ordinary_cases(quantity) do
    anchor = %{
      turn_id: <<0, 255, 128>>,
      stream_domain_id: "0123456789abcdef0123456789abcdef",
      base_event_sequence: quantity
    }

    wire_anchor = %{
      "turn_id" => "AP-A",
      "stream_domain_id" => "MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY",
      "base_event_sequence" => Integer.to_string(quantity)
    }

    models =
      for kind <- [:text_delta, :reasoning_delta] do
        item =
          Map.merge(anchor, %{
            kind: kind,
            model_sequence: quantity,
            content_index: 9_007_199_254_740_991,
            text: "summary\tline\n"
          })

        expected =
          Map.merge(wire_anchor, %{
            "kind" => Atom.to_string(kind),
            "model_sequence" => Integer.to_string(quantity),
            "content_index" => 9_007_199_254_740_991,
            "text" => "summary\tline\n"
          })

        {item, expected}
      end

    call = {
      Map.merge(anchor, %{
        kind: :tool_call_delta,
        model_sequence: quantity,
        call_index: 9_007_199_254_740_991,
        tool_call_id: <<0, 255, 128>>,
        name: "tool",
        arguments_fragment: "{}"
      }),
      Map.merge(wire_anchor, %{
        "kind" => "tool_call_delta",
        "model_sequence" => Integer.to_string(quantity),
        "call_index" => 9_007_199_254_740_991,
        "tool_call_id" => "AP-A",
        "name" => "tool",
        "arguments_fragment" => "{}"
      })
    }

    tools =
      for stream <- ["stdout", "stderr", "progress"] do
        item =
          Map.merge(anchor, %{
            kind: :tool_progress,
            tool_call_id: <<255, 0, 128>>,
            progress_sequence: quantity,
            byte_offset: quantity,
            stream: stream,
            chunk: "chunk\t\n"
          })

        expected =
          Map.merge(wire_anchor, %{
            "kind" => "tool_progress",
            "tool_call_id" => "_wCA",
            "progress_sequence" => Integer.to_string(quantity),
            "byte_offset" => Integer.to_string(quantity),
            "stream" => stream,
            "chunk_b64" => "Y2h1bmsJCg"
          })

        {item, expected}
      end

    closures =
      for disposition <- [:complete, :abandoned],
          kind <- [:model_stream_closed, :tool_stream_closed] do
        item = Map.merge(anchor, %{kind: kind, disposition: disposition})

        expected =
          Map.merge(wire_anchor, %{
            "kind" => Atom.to_string(kind),
            "disposition" => Atom.to_string(disposition)
          })

        if kind == :model_stream_closed do
          {Map.put(item, :delta_count, quantity),
           Map.put(expected, "delta_count", Integer.to_string(quantity))}
        else
          {Map.merge(item, %{tool_call_id: <<255, 0, 128>>, progress_count: quantity}),
           Map.merge(expected, %{
             "tool_call_id" => "_wCA",
             "progress_count" => Integer.to_string(quantity)
           })}
        end
      end

    models ++ [call] ++ tools ++ closures
  end

  defp assert_ordinary_record(item, expected) do
    {[record], drained} =
      Delivery.new(<<255, 0>>, 7) |> Delivery.progress(item) |> Delivery.take()

    assert record == %{"type" => "progress", "session_id" => "_wA", "progress" => expected}
    assert Delivery.cursor(drained) == 7
    assert {:ok, encoded} = LoopexProtocol.Frame.encode(record)

    assert {:ok, ^record} =
             LoopexProtocol.Frame.decode(
               IO.iodata_to_binary(encoded) |> String.trim_trailing("\n"),
               LoopexProtocol.Frame.output_record_bytes()
             )

    record
  end

  defp assert_ordinary_refusal(item) do
    queue = Delivery.new("session", 7)
    assert Delivery.progress(queue, item) == queue
  end

  defp compaction_item(kind, base) do
    %{
      kind: "context.compaction_progress",
      episode_id: <<0, 255, 10>>,
      owner: %{"kind" => kind, "id" => <<255, 0, 128>>},
      stream_domain_id: "0123456789abcdef0123456789abcdef",
      progress_sequence: 0,
      base_event_sequence: base
    }
  end

  defp compaction_record(kind, base) do
    %{
      "type" => "progress",
      "session_id" => "_wA",
      "progress" => %{
        "kind" => "context.compaction_progress",
        "episode_id" => "AP8K",
        "owner" => %{"kind" => kind, "id" => "_wCA"},
        "stream_domain_id" => "MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY",
        "progress_sequence" => "0",
        "base_event_sequence" => Integer.to_string(base)
      }
    }
  end

  # Concept: events a real run actually committed.
  #
  # Technical depth: taken from the Store rather than written here, so the
  # projection is checked against what the runtime publishes. A shape invented
  # by this test would keep passing after the runtime changed its own.
  defp committed_events do
    fixture = Fixture.start(script: [%{text: "done", calls: []}])
    on_exit(fn -> Fixture.stop(fixture) end)

    {:ok, session_id} = Loopex.create_session(fixture.runtime, %{}, command_id: "cs")
    {:ok, attachment} = Loopex.attach(fixture.runtime, session_id, after_event_sequence: 0)

    {:accepted, _id} =
      Loopex.command(attachment, %{type: :prompt, command_id: "p1", content: "the task"})

    settle(fixture, session_id)

    events = Fixture.events(fixture, session_id)
    assert events != []
    events
  end

  defp settle(fixture, session_id, attempts \\ 300) do
    case Loopex.session_status(fixture.runtime, session_id) do
      {:ok, %{active_run_id: nil}} ->
        :settled

      _other when attempts > 0 ->
        Process.sleep(10)
        settle(fixture, session_id, attempts - 1)

      _other ->
        :active
    end
  end
end
