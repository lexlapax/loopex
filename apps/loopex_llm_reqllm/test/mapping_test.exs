defmodule Loopex.LLM.ReqLLM.MappingTest do
  use ExUnit.Case, async: true

  alias Loopex.LLM.ReqLLM.Mapping
  alias ReqLLM.ToolCall

  test "valid application calls retain exact ordered decoded objects" do
    calls = [ToolCall.new("a", "write", ~s({"path":"é.txt"})), ToolCall.new("b", "read", "{}")]

    assert Mapping.bounded_calls(response(calls)) ==
             {:ok,
              [
                %{id: "a", name: "write", arguments: %{"path" => "é.txt"}},
                %{id: "b", name: "read", arguments: %{}}
              ]}
  end

  test "malformed visible binary arguments refuse the entire ordered list without repair" do
    valid = ToolCall.new("a", "read", "{}")

    for raw <- ["invalid", "null", "[]", ~s({"path":"a"), "", "{", "true", "1"] do
      malformed = ToolCall.new("b", "write", raw)
      assert refused?(Mapping.bounded_calls(response([valid, malformed, valid])))
    end

    assert %{arguments: %{}} = ToolCall.to_map(ToolCall.new("b", "write", "invalid"))
  end

  test "visible non-application markers and error metadata refuse" do
    valid = ToolCall.new("a", "read", "{}")

    for call <- [
          ToolCall.new_builtin("a", "read", "{}"),
          ToolCall.put_metadata(valid, %{provider_native: :openai}),
          ToolCall.put_metadata(valid, %{"provider_native" => true}),
          ToolCall.put_metadata(valid, %{error: nil}),
          ToolCall.put_metadata(valid, %{"error" => :invalid})
        ] do
      assert refused?(Mapping.bounded_calls(response([call])))
    end
  end

  test "buffered seam requires a struct, exact function type and nonempty identities" do
    valid = ToolCall.new("a", "read", "{}")

    for call <- [
          %{valid | type: "custom"},
          %{valid | id: ""},
          %{valid | id: nil},
          %{valid | function: %{name: "", arguments: "{}"}},
          %{valid | function: %{name: "read", arguments: %{}}},
          %{id: "a", name: "read", arguments: %{}}
        ] do
      assert refused?(Mapping.bounded_calls(response([call])))
    end
  end

  test "locked buffered OpenAI normalization erases missing ids, unsupported arguments and malformed members" do
    {:ok, model} = ReqLLM.model(%{provider: :openai, id: "mapping-fixture"})

    for arguments <- [nil, "{}", "null", "[]", "42", "false"] do
      {:ok, buffered} =
        ReqLLM.Provider.Defaults.decode_response_body_openai_format(
          wire([%{"id" => nil, "function" => %{"name" => "read", "arguments" => arguments}}]),
          model
        )

      assert [call] = ReqLLM.Response.tool_calls(buffered)
      assert is_binary(call.id) and String.starts_with?(call.id, "call_")
      assert call.type == "function"
      assert call.function.arguments == "{}"
      assert {:ok, [%{id: id, name: "read", arguments: %{}}]} = Mapping.bounded_calls(buffered)
      assert id == call.id
    end

    for arguments <- ["", "invalid", ~s({"path":"a")] do
      {:ok, buffered} =
        ReqLLM.Provider.Defaults.decode_response_body_openai_format(
          wire([%{"id" => "a", "function" => %{"name" => "read", "arguments" => arguments}}]),
          model
        )

      assert [call] = ReqLLM.Response.tool_calls(buffered)
      assert call.function.arguments == arguments
      assert refused?(Mapping.bounded_calls(buffered))
    end

    {:ok, omitted} =
      ReqLLM.Provider.Defaults.decode_response_body_openai_format(
        wire([%{"type" => "custom", "function" => %{"name" => "read"}}]),
        model
      )

    assert Mapping.bounded_calls(omitted) == {:ok, []}
  end

  test "locked Responses API normalizes missing, empty and unsupported arguments" do
    {:ok, model} = ReqLLM.model(%{provider: :openai, id: "mapping-fixture"})
    request = Req.Request.put_private(%Req.Request{}, :req_llm_model, model)

    for arguments <- [:missing, nil, "", %{}, 42, false] do
      segment = %{"type" => "function_call", "name" => "read"}

      segment =
        if arguments == :missing, do: segment, else: Map.put(segment, "arguments", arguments)

      raw = %Req.Response{status: 200, body: %{"status" => "completed", "output" => [segment]}}

      assert {^request, %Req.Response{body: buffered}} =
               ReqLLM.Providers.OpenAI.ResponsesAPI.decode_response({request, raw})

      assert [call] = ReqLLM.Response.tool_calls(buffered)
      assert call.type == "function"
      assert call.function.arguments == "{}"
      assert String.starts_with?(call.id, "call_")
      assert {:ok, [%{arguments: %{}}]} = Mapping.bounded_calls(buffered)
    end
  end

  test "locked buffered builder removes earlier error markers but preserves existing structs" do
    {:ok, model} = ReqLLM.model(%{provider: :openai, id: "mapping-fixture"})
    chunk = ReqLLM.StreamChunk.tool_call("read", %{}, %{id: "a", error: :erased})
    assert chunk.metadata.error == :erased

    {:ok, buffered} =
      ReqLLM.Provider.Defaults.ResponseBuilder.build_buffered_response(
        [chunk],
        %{finish_reason: :tool_calls},
        context: ReqLLM.Context.new([]),
        model: model
      )

    assert [call] = ReqLLM.Response.tool_calls(buffered)
    refute Map.has_key?(ToolCall.metadata(call), :error)
    assert {:ok, [%{name: "read", arguments: %{}}]} = Mapping.bounded_calls(buffered)

    native = ToolCall.put_metadata(ToolCall.new("a", "read", "{}"), %{provider_native: true})
    assert [^native] = ReqLLM.Provider.Defaults.ResponseBuilder.normalize_tool_calls([native])
    assert refused?(Mapping.bounded_calls(response([native])))
  end

  test "shared conversation mapping retains role, native calls and tool-result order" do
    request = %{
      messages: [
        %{"role" => "system", "content" => "rules"},
        %{"role" => "user", "content" => "question"},
        %{
          "role" => "assistant",
          "content" => "",
          "tool_calls" => [
            %{"tool_call_id" => "a", "tool_id" => "loopex.read", "arguments" => %{}}
          ]
        },
        %{"role" => "tool", "tool_call_id" => "a", "content" => "answer"}
      ]
    }

    assert {:ok, context} = Mapping.context_of(request)
    assert Enum.map(context.messages, & &1.role) == [:system, :user, :assistant, :tool]
    assert [call] = Enum.at(context.messages, 2).tool_calls
    assert call.id == "a" and call.function.name == "read" and call.function.arguments == "{}"
    assert Enum.at(context.messages, 3).tool_call_id == "a"
  end

  test "reply fields and completion failure evidence retain the companion contract" do
    identity = %{provider: "anthropic", model: "test", endpoint: "https://test"}
    request = %{canonical_request_bytes: "bytes", staged_request_digest: "digest"}
    metadata = %{headers: [{"request-id", "req_é"}], usage: %{input_tokens: 2, output_tokens: 3}}

    assert Mapping.reply(request, identity, metadata, "text", [], 0) == %{
             text: "text",
             identity: identity,
             provider_response_id: "req_é",
             usage: %{input_tokens: 2, output_tokens: 3},
             tool_calls: [],
             delta_count: 0,
             streamed: false,
             canonical_request_bytes: "bytes",
             staged_request_digest: "digest"
           }

    assert Mapping.completed(%{finish_reason: :length}) == :ok
    assert Mapping.completed(%{finish_reason: :stop}) == :ok

    assert {:error, {:stream_incomplete, :incomplete}} =
             Mapping.completed(%{finish_reason: :incomplete})

    assert {:error, {:stream_failed, nil}} = Mapping.completed(%{error: nil})

    assert Mapping.failure_pair("calls", Mapping.returned_class({:error, :refused})) ==
             %{"stage" => "calls", "class" => "returned_error"}
  end

  defp response(calls),
    do: %ReqLLM.Response{
      id: "fixture",
      model: "fixture",
      context: ReqLLM.Context.new([]),
      message: %ReqLLM.Message{role: :assistant, tool_calls: calls}
    }

  defp refused?({:error, {:tool_call_not_reconstructible, :invalid_application_call}}), do: true
  defp refused?(_), do: false

  defp wire(calls),
    do: %{
      "choices" => [
        %{
          "finish_reason" => "tool_calls",
          "message" => %{"role" => "assistant", "tool_calls" => calls}
        }
      ]
    }
end
