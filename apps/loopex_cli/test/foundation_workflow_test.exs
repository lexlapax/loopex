Code.require_file(
  "../../loopex_llm_reqllm/test/support/provider_isolation_fixture.exs",
  __DIR__
)

defmodule LoopexCli.FoundationWorkflowTest do
  use ExUnit.Case, async: false

  alias Loopex.LLM.ReqLLM
  alias Loopex.LLM.ReqLLM.ProviderIsolationFixture, as: ProviderFixture

  test "isolated provider responses preserve request order for the pending tool workflow" do
    credential = "m3-foundation-local-provider"

    fixture =
      ProviderFixture.new(:reply,
        credential: credential,
        response_bodies: [
          text_response("first", "msg_first"),
          text_response("second", "msg_second")
        ]
      )

    variable = ReqLLM.credential_variable()
    previous = System.get_env(variable)
    System.put_env(variable, credential)

    try do
      assert {:ok, first} = ProviderFixture.complete(fixture)
      assert {:ok, second} = ProviderFixture.complete(fixture)
      assert first.text == "first"
      assert second.text == "second"
      assert ProviderFixture.methods(fixture) == ["POST", "POST"]
    after
      if previous,
        do: System.put_env(variable, previous),
        else: System.delete_env(variable)
    end
  end

  defp text_response(text, response_id) do
    [
      %{
        "type" => "message_start",
        "message" => %{
          "id" => response_id,
          "type" => "message",
          "role" => "assistant",
          "model" => "claude-haiku-4-5",
          "content" => [],
          "usage" => %{"input_tokens" => 4, "output_tokens" => 0}
        }
      },
      %{
        "type" => "content_block_start",
        "index" => 0,
        "content_block" => %{"type" => "text", "text" => ""}
      },
      %{
        "type" => "content_block_delta",
        "index" => 0,
        "delta" => %{"type" => "text_delta", "text" => text}
      },
      %{"type" => "content_block_stop", "index" => 0},
      %{
        "type" => "message_delta",
        "delta" => %{"stop_reason" => "end_turn", "stop_sequence" => nil},
        "usage" => %{"output_tokens" => 2}
      },
      %{"type" => "message_stop"}
    ]
    |> Enum.map_join(fn event ->
      "event: #{event["type"]}\ndata: #{Jason.encode!(event)}\n\n"
    end)
  end
end
