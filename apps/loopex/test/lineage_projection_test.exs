defmodule Loopex.LineageProjectionTest do
  use ExUnit.Case, async: true

  alias Loopex.Runtime.{ArtifactReadCapabilities, LineageProjection}
  alias Loopex.Conversation
  alias LoopexProtocol.Frame

  @binding ArtifactReadCapabilities.table() |> Map.values() |> Enum.find(& &1)
  @read {@binding["tool_id"], @binding["tool_version"], @binding["definition_digest"]}
  @question_generation LoopexProtocol.ToolDefinition.generation(
                         LoopexProtocol.ToolDefinition.question_definition()
                       )

  test "only receipt-owned references become excerpts and the original elements stay complete" do
    {elements, sources} = fixture()

    assert {:ok, entries, projection} =
             LineageProjection.project(elements, @binding, sources, %{}, 9)

    [{source, message}] = Enum.filter(entries, fn {_, message} -> message["role"] == "tool" end)
    assert {:ok, notice} = Frame.decode(message["content"], 2_048)
    assert notice["excerpt"] == "retained "
    assert [%{"source_reference" => ^source, "byte_count" => 9}] = projection["ranges"]
    assert List.last(elements).content == String.duplicate("retained text ", 400)

    assert {:ok, inline, %{"ranges" => []}} =
             LineageProjection.project(elements, @binding, %{}, %{}, 0)

    assert elem(List.last(inline), 1)["content"] == List.last(elements).content
  end

  test "legacy selections keep full inline content independently of reference availability" do
    {elements, sources} = fixture()

    for index <- [sources, %{}], allowance <- [0, 2_048] do
      assert {:ok, entries, nil} = LineageProjection.project(elements, nil, index, %{}, allowance)
      assert elem(List.last(entries), 1)["content"] == List.last(elements).content
    end
  end

  test "preparation uses encoded message cost, oldest-first order and usable membership" do
    {elements, sources} = fixture()
    later = elements |> Enum.drop(1) |> Enum.map(&%{&1 | turn_number: 2})

    assert {:ok, [first, second]} =
             LineageProjection.preparation_candidates(elements ++ later, @binding, %{}, %{})

    assert first.source_reference["turn"] == 1
    assert second.source_reference["turn"] == 2
    assert first.message["content"] == List.last(elements).content

    assert {:ok, []} =
             LineageProjection.preparation_candidates(elements ++ later, @binding, sources, %{})

    assert {:ok, [^second]} =
             LineageProjection.preparation_candidates(
               elements ++ later,
               @binding,
               %{},
               %{first.source_reference => %{message: first.message, range: nil}}
             )

    altered = update_in(sources, [reference().use_locator, "reference", "size"], &(&1 + 1))

    assert {:ok, [^first]} =
             LineageProjection.preparation_candidates(elements, @binding, altered, %{})

    assert {:ok, []} = LineageProjection.preparation_candidates(elements, nil, %{}, %{})
  end

  test "the exact encoded ceiling includes escaping and identity rather than raw text alone" do
    {elements, _sources} = fixture()
    short = put_in(elements, [Access.at(2), :content], String.duplicate("x", 1_929))
    message = elem(List.last(elem(Conversation.lineage_entries(short), 1)), 1)
    assert {:ok, encoded} = Frame.encode(message)
    assert IO.iodata_length(encoded) - 1 == 2_048

    assert {:ok, []} = LineageProjection.preparation_candidates(short, @binding, %{}, %{})

    longer = update_in(short, [Access.at(2), :content], &(&1 <> "x"))
    assert {:ok, [_]} = LineageProjection.preparation_candidates(longer, @binding, %{}, %{})

    escaped = put_in(short, [Access.at(2), :content], String.duplicate("\"", 1_100))
    assert byte_size(List.last(escaped).content) < 2_048
    assert {:ok, [_]} = LineageProjection.preparation_candidates(escaped, @binding, %{}, %{})
  end

  test "questions and explicit artifact ranges remain fixed when they lack a reference" do
    {elements, _} = fixture()

    question =
      put_in(
        elements,
        [Access.at(1), :tool_calls, Access.at(0), :generation],
        @question_generation
      )

    range =
      update_in(elements, [Access.at(1), :tool_calls, Access.at(0)], fn call ->
        %{call | generation: @read, arguments: %{"artifact_use" => reference().use_locator}}
      end)

    for fixed <- [question, range] do
      assert {:ok, []} = LineageProjection.preparation_candidates(fixed, @binding, %{}, %{})
    end
  end

  test "binary receipt content with usable membership is already retained without text encoding" do
    {elements, sources} = fixture()
    binary = put_in(elements, [Access.at(2), :content], <<255, 0, 254>>)
    assert {:ok, []} = LineageProjection.preparation_candidates(binary, @binding, sources, %{})

    assert {:error, :context_projection_invalid} =
             LineageProjection.preparation_candidates(binary, @binding, %{}, %{})

    assert {:ok, _entries, %{"ranges" => [_]}} =
             LineageProjection.project(binary, @binding, sources, %{}, 0)
  end

  test "explicit artifact ranges stay exact even if a receipt also supplies a reference" do
    {elements, sources} = fixture()

    elements =
      update_in(elements, [Access.at(1), :tool_calls, Access.at(0)], fn call ->
        %{
          call
          | generation: @read,
            arguments: %{
              "artifact_use" => reference().use_locator,
              "offset" => 0,
              "length" => 4_096
            }
        }
      end)

    assert {:ok, entries, %{"ranges" => []}} =
             LineageProjection.project(elements, @binding, sources, %{}, 0)

    assert elem(List.last(entries), 1)["content"] == List.last(elements).content
  end

  test "a frozen result and its provenance survive a smaller allowance for a later result" do
    {elements, sources} = fixture()

    assert {:ok, entries, projection} =
             LineageProjection.project(elements, @binding, sources, %{}, 90)

    {source, message} = List.last(entries)
    [range] = projection["ranges"]
    frozen = %{source => %{message: message, range: range}}
    later = elements |> Enum.drop(1) |> Enum.map(&%{&1 | turn_number: 2})

    assert {:ok, next, next_projection} =
             LineageProjection.project(elements ++ later, @binding, sources, frozen, 0)

    tool_messages = for {_, %{"role" => "tool"} = result} <- next, do: result
    assert [^message, appended] = tool_messages
    assert {:ok, notice} = Frame.decode(appended["content"], 2_048)
    assert notice["excerpt_byte_count"] == 0
    assert [^range, %{"byte_count" => 0}] = next_projection["ranges"]
  end

  test "question answers are fixed rather than eligible for ordinary excerpt allocation" do
    {elements, sources} = fixture()

    elements =
      put_in(
        elements,
        [Access.at(1), :tool_calls, Access.at(0), :generation],
        LoopexProtocol.ToolDefinition.generation(
          LoopexProtocol.ToolDefinition.question_definition()
        )
      )

    assert {:ok, entries, %{"ranges" => []}} =
             LineageProjection.project(elements, @binding, sources, %{}, 0)

    assert elem(List.last(entries), 1)["content"] == List.last(elements).content
  end

  test "one allowance applies to every new source with monotone complete projection costs" do
    {elements, sources} = fixture()
    later = elements |> Enum.drop(1) |> Enum.map(&%{&1 | turn_number: 2})

    costs =
      for allowance <- [0, 1, 9, 10, 99, 100, 255, 256, 999, 1_000, 2_047, 2_048] do
        assert {:ok, entries, projection} =
                 LineageProjection.project(elements ++ later, @binding, sources, %{}, allowance)

        [first, second] = projection["ranges"]
        assert first["byte_count"] == second["byte_count"]
        assert first["byte_count"] <= allowance
        messages = Enum.map(entries, &elem(&1, 1))

        tokens =
          Enum.sum(
            Enum.map(messages, &Loopex.Bounds.estimate(LoopexProtocol.Canonical.encode(&1)))
          )

        bytes = byte_size(LoopexProtocol.Canonical.encode([messages, projection]))
        {tokens, bytes}
      end

    for [{a_tokens, a_bytes}, {b_tokens, b_bytes}] <- Enum.chunk_every(costs, 2, 1, :discard) do
      assert a_tokens <= b_tokens
      assert a_bytes <= b_bytes
    end
  end

  defp fixture do
    reference = reference()

    call = %{
      tool_call_id: "call",
      name: "write",
      arguments: %{},
      generation: {"loopex.write", "1.0.0", String.duplicate("a", 64)}
    }

    elements = [
      %{kind: :user_message, run_id: "run", command_id: "prompt", content: "hello"},
      %{
        kind: :assistant_message,
        run_id: "run",
        turn_number: 1,
        content: "working",
        tool_calls: [call],
        stop_reason: "tool_use",
        usage: %{}
      },
      %{
        kind: :tool_result,
        run_id: "run",
        turn_number: 1,
        tool_call_id: "call",
        outcome: :completed,
        content: String.duplicate("retained text ", 400),
        artifacts: [reference]
      }
    ]

    plain = Map.new(reference, fn {key, value} -> {Atom.to_string(key), value} end)
    {elements, %{reference.use_locator => %{"reference" => plain}}}
  end

  defp reference do
    digest = String.duplicate("b", 64)

    %{
      digest: digest,
      size: 8_192,
      locator: digest,
      media_type: "text/plain",
      role: "tool_output",
      use_canonicalization_version: "loopex.canonical.v1",
      use_digest: digest,
      use_locator: "use:" <> digest
    }
  end
end
