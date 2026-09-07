Code.require_file("../../loopex/test/support/m1_runtime_helper.exs", __DIR__)
Code.require_file("../../loopex/test/support/agent_loop_helper.exs", __DIR__)
Code.require_file("../../loopex_llm_reqllm/test/support/provider_isolation_fixture.exs", __DIR__)

defmodule LoopexCli.ProviderAccountingIntegrationTest do
  @moduledoc false
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO

  alias Loopex.AgentLoopFixture
  alias Loopex.AgentLoopTestExecutor
  alias Loopex.LLM.ReqLLM, as: Adapter
  alias Loopex.LLM.ReqLLM.ProviderIsolationFixture, as: Provider
  alias Loopex.M1RuntimeTestStore
  alias Loopex.Runtime
  alias Loopex.Runtime.SessionState

  setup do
    previous = System.get_env(Adapter.credential_variable())
    System.put_env(Adapter.credential_variable(), "synthetic-accounting-integration-key")

    on_exit(fn ->
      if previous,
        do: System.put_env(Adapter.credential_variable(), previous),
        else: System.delete_env(Adapter.credential_variable())
    end)

    :ok
  end

  for boundary <- [:raw_refusal, :settlement_compaction] do
    @boundary boundary
    test "actual provider #{@boundary} reaches durable Core accounting and private rendering" do
      provider = Provider.new(:reply, response_body: stream_body(@boundary))
      {store_pid, store} = M1RuntimeTestStore.start_store(label: "provider-accounting")
      executor = AgentLoopTestExecutor.start()
      definition = AgentLoopFixture.tool_definition()

      {:ok, runtime} =
        Loopex.start_link(
          context_token_budget: 8_192,
          runtime_id: "provider-accounting-integration",
          store: store,
          diagnostics_to: self(),
          cleanup_grace_ms: 2_000,
          sampling: %{"max_tokens" => 64},
          model: %{module: Adapter, model: Adapter.default_model(), options: provider.options},
          executor: %{
            module: AgentLoopTestExecutor,
            reference: executor,
            identity: "agent-loop-executor",
            epoch: 1,
            fencing_token: 1,
            workspace_ref: "workspace-ref",
            workspace_lease: "workspace-lease"
          },
          tools: [definition],
          active_tools: [definition["tool_id"]],
          policy: Loopex.AgentLoopTestPolicy,
          grant_decision: {:host_policy, :allow},
          bounds: %{max_turns: 2, token_budget: 256, deadline_ms: 30_000}
        )

      on_exit(fn ->
        if Runtime.alive?(runtime), do: Loopex.stop(runtime)
        if Process.alive?(store_pid), do: GenServer.stop(store_pid)
        if Process.alive?(executor), do: Agent.stop(executor)
      end)

      {:ok, session_id} = Loopex.create_session(runtime, %{}, command_id: "create-accounting")
      {:ok, attachment} = Loopex.attach(runtime, session_id, after_event_sequence: 0)
      {:ok, %{control: control}} = Runtime.children(runtime)
      coordinator = :sys.get_state(control).sessions[session_id].coordinator
      assert :erlang.trace(coordinator, true, [:send, {:tracer, self()}]) == 1

      assert {:accepted, "accounting-prompt"} =
               Loopex.command(attachment, %{
                 type: :prompt,
                 command_id: "accounting-prompt",
                 content: "observe accounting without executing discarded tools"
               })

      output =
        capture_io(:stderr, fn ->
          stdout =
            capture_io(fn ->
              assert :ok = LoopexCli.Render.stream(attachment, idle_limit_ms: 10_000)
            end)

          send(self(), {:rendered_stdout, stdout})
        end)

      assert_receive {:rendered_stdout, stdout}

      assert {:ok, _status} = Loopex.session_status(runtime, session_id)
      fence = :erlang.trace_delivered(coordinator)
      assert_receive {:trace_delivered, ^coordinator, ^fence}, 1_000
      :erlang.trace(coordinator, false, [:send])
      {:messages, observed} = Process.info(self(), :messages)
      assert Enum.any?(observed, &match?({:trace, ^coordinator, :send, _, _}, &1))

      diagnostics =
        for {:trace, ^coordinator, :send, {:loopex_diagnostic, value}, destination} <- observed,
            destination == self(),
            do: value

      session = M1RuntimeTestStore.inspect_state(store_pid).sessions[session_id]

      [settlement] =
        for %{payload: %{kind: "model_attempt_settled_v2"} = record} <- session.records,
            do: record

      assert settlement["result"]["category"] == "unreadable_model_answer"
      assert settlement["next"] == "terminal"
      assert settlement["conversation"] == "none"
      assert {:ok, recovered} = SessionState.recover(session_id, session.records, session.events)

      case @boundary do
        :raw_refusal ->
          assert settlement["result"]["accounting_evidence"] == %{"kind" => "none"}

          assert settlement["accounting"] == %{
                   "source" => "estimated",
                   "basis" => "remaining_allowance"
                 }

          assert elem(SessionState.accounting(recovered, settlement["run_id"]), 1) == %{
                   tokens: 256,
                   source: :estimated
                 }

        :settlement_compaction ->
          assert settlement["result"]["accounting_evidence"] == %{
                   "kind" => "validated_reply_compaction_v1",
                   "usage" => %{
                     "status" => "reported",
                     "input_tokens" => 37,
                     "output_tokens" => 11
                   },
                   "dimension" => "record_depth",
                   "observed" => 13,
                   "limit" => 12
                 }

          assert elem(SessionState.accounting(recovered, settlement["run_id"]), 1) == %{
                   tokens: 48,
                   source: :reported
                 }
      end

      assert Provider.methods(provider) == ["POST"]
      assert [{_actual_request, true}] = Provider.events(provider)
      assert AgentLoopTestExecutor.jobs(executor) == []
      Provider.assert_gone(provider)
      assert diagnostics == []

      for plane <- [
            session.events,
            diagnostics,
            output,
            stdout,
            SessionState.elements(recovered, settlement["run_id"])
          ] do
        for private <- [
              "accounting_evidence",
              "validated_reply_compaction_v1",
              "record_depth",
              "input_tokens",
              "output_tokens",
              "\"usage\"",
              "\"dimension\"",
              "\"observed\"",
              "\"limit\""
            ] do
          refute inspect(plane, limit: :infinity, printable_limit: :infinity) =~ private
        end
      end

      assert output =~ "failed"
    end
  end

  defp stream_body(boundary) do
    content =
      case boundary do
        :raw_refusal ->
          [
            %{
              "type" => "content_block_start",
              "index" => 0,
              "content_block" => %{"type" => "text", "text" => ""}
            },
            %{
              "type" => "content_block_delta",
              "index" => 0,
              "delta" => %{"type" => "text_delta", "text" => String.duplicate("x", 65_537)}
            }
          ]

        :settlement_compaction ->
          arguments = %{
            "path" => "discarded-tool.txt",
            "nested" => Enum.reduce(1..7, "leaf", fn _, value -> %{"next" => value} end)
          }

          [
            %{
              "type" => "content_block_start",
              "index" => 0,
              "content_block" => %{
                "type" => "tool_use",
                "id" => "call_Accounting",
                "name" => "write",
                "input" => %{}
              }
            },
            %{
              "type" => "content_block_delta",
              "index" => 0,
              "delta" => %{
                "type" => "input_json_delta",
                "partial_json" => Jason.encode!(arguments)
              }
            }
          ]
      end

    ([
       %{
         "type" => "message_start",
         "message" => %{
           "id" => "msg_accounting",
           "type" => "message",
           "role" => "assistant",
           "model" => "claude-haiku-4-5",
           "content" => [],
           "usage" => %{"input_tokens" => 37, "output_tokens" => 0}
         }
       }
     ] ++
       content ++
       [
         %{"type" => "content_block_stop", "index" => 0},
         %{
           "type" => "message_delta",
           "delta" => %{
             "stop_reason" => if(boundary == :raw_refusal, do: "end_turn", else: "tool_use"),
             "stop_sequence" => nil
           },
           "usage" => %{"output_tokens" => 11}
         },
         %{"type" => "message_stop"}
       ])
    |> Enum.map_join(fn event -> "event: #{event["type"]}\ndata: #{Jason.encode!(event)}\n\n" end)
  end
end
