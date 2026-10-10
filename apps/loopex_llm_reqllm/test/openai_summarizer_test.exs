Code.require_file("support/provider_isolation_fixture.exs", __DIR__)

defmodule Loopex.LLM.ReqLLM.OpenAISummarizerTest do
  use ExUnit.Case, async: false

  # Concept: M7's provider B summarizer is one registered thinking-off OpenAI
  # row. Its cells, its eligibility as a maintenance model and its exact
  # outgoing request are proved against a local OpenAI-compatible fixture;
  # no provider is contacted and no credential is real.

  alias Loopex.LLM.ReqLLM.{ModelCapabilities, ProviderIsolationFixture}
  alias Loopex.Model
  alias Loopex.Runtime.MaintenanceConfiguration

  @model "openai:gpt-4.1-mini"
  @credential "m7-openai-summarizer-synthetic"
  @none %{
    "mapping_revision" => "loopex.openai.gpt41mini.v1",
    "renderer_revision" => "loopex.reqllm.canonical.v1",
    "continuation_required" => false,
    "canonical_terminal_tool_history" => false,
    "thinking_disabled" => true,
    "thinking" => %{"mode" => "disabled"}
  }
  @generic %{
    "mapping_revision" => "loopex.unregistered.default.v1",
    "renderer_revision" => "loopex.reqllm.canonical.v1",
    "continuation_required" => false,
    "canonical_terminal_tool_history" => false,
    "thinking_disabled" => false,
    "thinking" => %{"mode" => "omitted"}
  }

  test "the registered row has exactly a generic default and a thinking-off none cell" do
    assert ModelCapabilities.mapping(@model, "default", 4_096) == {:ok, @generic}
    assert ModelCapabilities.mapping(@model, "none", 4_096) == {:ok, @none}

    for level <- ~w(low medium high unsupported) do
      assert ModelCapabilities.mapping(@model, level, 4_096) == {:error, :invalid_model_mapping}
    end

    assert {:ok, capabilities} = ModelCapabilities.capture(@model)
    assert capabilities["reasoning_levels"] == ~w(default none)

    assert MaintenanceConfiguration.eligible_model(%{
             "model" => @model,
             "reasoning" => "none",
             "model_capabilities" => capabilities,
             "provider_mapping" => @none
           }) == :ok
  end

  test "an OpenAI request must carry exactly its registered cell" do
    assert ModelCapabilities.verify_captured(request("none", @none)) == :ok
    assert ModelCapabilities.verify_captured(request("default", @generic)) == :ok

    for {level, mapping} <- [
          {"none", @generic},
          {"default", @none},
          {"none", %{@none | "thinking_disabled" => false}},
          {"none", %{@none | "mapping_revision" => "other"}}
        ] do
      assert ModelCapabilities.verify_captured(request(level, mapping)) ==
               {:error, :invalid_model_mapping}
    end
  end

  test "the none cell's outgoing request is the exact canonical body without reasoning controls" do
    fixture =
      ProviderIsolationFixture.new(:reply, credential: @credential, response_bodies: [reply()])

    assert {:ok, result} = ProviderIsolationFixture.complete(fixture, request("none", @none))
    assert result.text == "summary"
    assert result.completion == "natural"
    assert result.continuation == nil
    assert [{body, true}] = ProviderIsolationFixture.events(fixture)

    # The dependency renders this model through OpenAI's Responses API.
    assert body == %{
             "model" => "gpt-4.1-mini",
             "input" => [
               %{
                 "role" => "user",
                 "content" => [%{"type" => "input_text", "text" => "summarize"}]
               }
             ],
             "max_output_tokens" => 64,
             "stream" => true
           }

    refute Enum.any?(Map.keys(body), &(&1 =~ "reason" or &1 =~ "thinking"))
  end

  test "only the registered cell's reported completed stop is classified" do
    completed = %{"status" => "completed"}

    for {reason, meta, completion} <- [
          {:stop, completed, "natural"},
          {:stop, %{}, "unknown"},
          {:stop, %{"status" => "failed"}, "unknown"},
          {:length, %{"status" => "incomplete"}, "limit"},
          {:incomplete, completed, "unknown"}
        ] do
      metadata = %{finish_reason: reason, provider_meta: meta}
      assert ModelCapabilities.completion(request("none", @none), metadata) == completion
    end

    assert ModelCapabilities.completion(request("default", @generic), %{
             finish_reason: :stop,
             provider_meta: completed
           }) == "unknown"
  end

  # Concept: a non-streaming Responses body is natural only when it says completed.
  # Technical depth: the dependency maps every status other than completed or
  # incomplete -- failed, cancelled, in_progress, queued or missing -- to :stop,
  # so the stop alone is not evidence; the carried provider status decides.
  test "a non-streaming body without a completed status is not natural" do
    for {status, completion} <- [
          {"completed", "natural"},
          {"failed", "unknown"},
          {"cancelled", "unknown"},
          {"in_progress", "unknown"},
          {"queued", "unknown"},
          {nil, "unknown"}
        ] do
      body =
        %{
          "id" => "resp_m7",
          "model" => "gpt-4.1-mini",
          "output" => [
            %{
              "type" => "message",
              "id" => "msg_m7",
              "role" => "assistant",
              "content" => [%{"type" => "output_text", "text" => "summary"}]
            }
          ],
          "usage" => %{"input_tokens" => 9, "output_tokens" => 2}
        }
        |> then(&if(status, do: Map.put(&1, "status", status), else: &1))

      {_req, %Req.Response{body: %ReqLLM.Response{} = response}} =
        ReqLLM.Providers.OpenAI.ResponsesAPI.decode_response(
          {Req.new(), %Req.Response{status: 200, body: body}}
        )

      assert response.finish_reason == :stop
      metadata = Loopex.LLM.ReqLLM.Mapping.response_metadata(response, [])
      assert Loopex.LLM.ReqLLM.Mapping.completed(metadata) == :ok

      assert ModelCapabilities.completion(request("none", @none), metadata) == completion,
             "status #{inspect(status)}"
    end
  end

  test "a request whose captured mapping differs refuses before transport" do
    fixture =
      ProviderIsolationFixture.new(:reply, credential: @credential, response_bodies: [reply()])

    assert {:error, {:not_dispatched, _}} =
             ProviderIsolationFixture.complete(fixture, request("none", @generic))

    assert ProviderIsolationFixture.events(fixture) == []
  end

  defp request(level, mapping) do
    sampling =
      %{"max_tokens" => 64, "provider_mapping" => mapping}
      |> then(&if(level == "default", do: &1, else: Map.put(&1, "reasoning", level)))

    {:ok, request} =
      Model.request(@model, [%{"role" => "user", "content" => "summarize"}],
        sampling: sampling,
        deadline: System.system_time(:millisecond) + 10_000
      )

    request
  end

  # One OpenAI Responses stream: a text delta, then completion with usage.
  @doc false
  def reply(text \\ "summary") do
    events = [
      %{
        "type" => "response.created",
        "response" => %{"id" => "resp_m7", "status" => "in_progress"}
      },
      %{
        "type" => "response.output_text.delta",
        "item_id" => "msg_m7",
        "output_index" => 0,
        "content_index" => 0,
        "delta" => text
      },
      %{
        "type" => "response.completed",
        "response" => %{
          "id" => "resp_m7",
          "status" => "completed",
          "model" => "gpt-4.1-mini",
          "output" => [
            %{
              "type" => "message",
              "id" => "msg_m7",
              "role" => "assistant",
              "content" => [%{"type" => "output_text", "text" => text}]
            }
          ],
          "usage" => %{"input_tokens" => 9, "output_tokens" => 2, "total_tokens" => 11}
        }
      }
    ]

    Enum.map_join(events, &("event: #{&1["type"]}\ndata: " <> JSON.encode!(&1) <> "\n\n"))
  end
end
