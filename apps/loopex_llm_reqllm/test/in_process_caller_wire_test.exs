Code.require_file("support/in_process_caller_wire_fixture.ex", __DIR__)

defmodule Loopex.LLM.ReqLLM.InProcess.CallerWireTest do
  use ExUnit.Case, async: false

  alias Loopex.LLM.ReqLLM.InProcess.Caller
  alias Loopex.LLM.ReqLLM.InProcessCallerWireFixture, as: Fixture

  setup do
    {:ok, _} = Application.ensure_all_started(:req_llm)
    runtime = Fixture.runtime()
    on_exit(fn -> Fixture.close_runtime(runtime) end)
    {:ok, runtime: runtime}
  end

  test "an uncatalogued Ollama model reaches ReqLLM and the owned HTTP pool", %{
    runtime: runtime
  } do
    call = Fixture.start(runtime, "ollama:uncatalogued:name", Fixture.wire(:chat, "answer"))
    {result, call} = call |> Fixture.begin() |> Fixture.result()

    assert {:ok, %{text: "answer", streamed: false, tool_calls: []}} = result
    assert call.prepared.surface == :ollama_chat_completions
    assert [wire] = call.writes
    assert wire.line == "POST /chat/completions HTTP/1.1"
    assert Jason.decode!(wire.body)["model"] == "uncatalogued:name"
    assert Jason.decode!(wire.body)["max_tokens"] == 64
    Fixture.stop(call)
  end

  test "the trace capability records its control but excludes the sensitive caller", %{
    runtime: runtime
  } do
    assert {:ok, _} =
             Loopex.trace(runtime.runtime, %{
               modules: [Caller, Loopex.Runtime.Control],
               level: :arguments
             })

    Loopex.session_status(runtime.runtime, "absent")

    assert_receive {:loopex_diagnostic,
                    %{"kind" => "trace_call", "module" => "Loopex.Runtime.Control"}},
                   1_000

    call = Fixture.start(runtime, "ollama:trace", Fixture.wire(:chat, "trace-safe"))
    {result, call} = call |> Fixture.begin() |> Fixture.result()
    assert {:ok, %{text: "trace-safe"}} = result

    {:ok, %{control: control}} = Loopex.Runtime.children(runtime.runtime)
    state = :sys.get_state(control)
    assert MapSet.member?(state.trace_excluded[call.caller].functions, {Caller, :run, 1})
    assert :erlang.process_info(call.caller, :dictionary) == {:dictionary, []}
    Fixture.stop(call)

    refute_receive {:loopex_diagnostic,
                    %{"kind" => "trace_call", "module" => "Loopex.LLM.ReqLLM.InProcess.Caller"}},
                   30
  end

  test "all hosted provider surfaces make a verified TLS call with the selected key" do
    {output, status} = Fixture.hosted_child()
    assert status == 0, output
    assert output =~ "IN_PROCESS_CALLER_WIRE_PROBE_PASSED"
  end

  test "a closed admission cell refuses before any provider write", %{runtime: runtime} do
    call = Fixture.start(runtime, "ollama:closed", Fixture.wire(:chat, "unreached"))
    :atomics.put(call.cell, 1, 3)
    {result, call} = call |> Fixture.begin() |> Fixture.result()
    assert result == {:error, {:not_dispatched, "model_call_failed"}}
    Fixture.refute_write(call)
    Fixture.stop(call)
  end

  test "post-dispatch decoder failure cannot become a second send", %{runtime: runtime} do
    call = Fixture.start(runtime, "ollama:malformed", "not-json")
    {result, call} = call |> Fixture.begin() |> Fixture.result()
    assert result == {:error, {:dispatched_or_unknown, "model_call_failed"}}
    Fixture.assert_one_write(call)
    Fixture.stop(call)
  end
end
