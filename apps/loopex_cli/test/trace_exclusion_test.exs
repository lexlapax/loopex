Code.require_file(
  "../../loopex_llm_reqllm/test/support/provider_isolation_fixture.exs",
  __DIR__
)

defmodule LoopexCli.TraceExclusionTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Loopex.LLM.ReqLLM
  alias Loopex.LLM.ReqLLM.ProviderIsolationFixture, as: ProviderFixture

  @credential "trace-exclusion-sentinel-5c1e"
  @excluded ~w(route_credential receive_custody_reply write_credential_frame)

  defmodule AllowPolicy do
    @moduledoc false
    @behaviour Loopex.Policy

    @impl Loopex.Policy
    def decide(_request), do: {:allow, nil}
  end

  # Concept: an operator's trace session over the provider bridge, at the
  # administrative level, sees the bridge at work but never the three
  # functions that carry the credential, and never the credential itself.
  #
  # Technical depth: a reference composition runs one prompt through a
  # scripted provider while a runtime trace session names the provider bridge
  # at `:arguments` level with the logger as its sink. The bridge module is
  # loaded before the session starts, because a trace session installs call
  # patterns only for modules already loaded. Bridge entries appear, so the
  # session covered the invocation's processes; none names `route_credential`,
  # `receive_custody_reply` or `write_credential_frame`, and no captured line
  # carries the credential or its base64 form.
  @tag timeout: 120_000
  test "a trace over the provider bridge never records the credential functions" do
    root = Path.join(System.tmp_dir!(), "lte-#{System.unique_integer([:positive])}")
    workspace = Path.join(root, "w")
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf(root) end)
    Code.ensure_loaded!(Loopex.LLM.ReqLLM.ProviderBridge)

    provider =
      ProviderFixture.new(:reply,
        credential: @credential,
        response_bodies: [text_response("traced answer")]
      )

    variable = ReqLLM.credential_variable()
    System.put_env(variable, @credential)
    on_exit(fn -> System.delete_env(variable) end)

    log =
      capture_log([level: :debug], fn ->
        LoopexComposition.with_runtime(
          [
            runtime_id: "trace-exclusion",
            state_root: Path.join(root, "s"),
            workspace: workspace,
            policy: AllowPolicy,
            provider_launch:
              Keyword.drop(provider.options, [
                :credential_token,
                :credential_registry,
                :tracing_capability
              ])
          ],
          fn runtime ->
            assert {:ok, _status} =
                     Loopex.trace(runtime, %{
                       modules: [Loopex.LLM.ReqLLM.ProviderBridge],
                       level: :arguments,
                       sink: :logger
                     })

            {:ok, session_id} = Loopex.create_session(runtime, %{}, command_id: "trace-create")
            {:ok, attachment} = Loopex.attach(runtime, session_id)

            {:accepted, "trace-prompt"} =
              Loopex.command(attachment, %{
                type: :prompt,
                command_id: "trace-prompt",
                content: "go"
              })

            await_finished(attachment, System.monotonic_time(:millisecond) + 60_000)
            :ok = Loopex.trace_stop(runtime)
          end
        )
      end)

    # The invocation succeeded with the session live: the credential reached
    # the provider, so the functions below ran and were excluded, not skipped.
    assert ProviderFixture.count(provider) == 1

    assert log =~ ~s("module" => "Loopex.LLM.ReqLLM.ProviderBridge"),
           "the trace session recorded nothing from the bridge"

    for function <- @excluded do
      refute log =~ ~s("function" => "#{function}"), "the trace recorded #{function}"
    end

    refute log =~ @credential
    refute log =~ Base.encode64(@credential)
  end

  defp await_finished(attachment, deadline) do
    case Loopex.next_event(attachment) do
      {:ok, %{kind: "run.finished"}} ->
        :ok

      {:ok, _event} ->
        await_finished(attachment, deadline)

      _none ->
        if System.monotonic_time(:millisecond) >= deadline,
          do: flunk("the run did not finish"),
          else: Process.sleep(10)

        await_finished(attachment, deadline)
    end
  end

  defp text_response(text) do
    [
      %{
        "type" => "message_start",
        "message" => %{
          "id" => "msg_trace",
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
