defmodule Loopex.ProviderAttemptCeilingOrderTest do
  @moduledoc false

  # Not async: the witness below is a call trace pattern on a private function,
  # which is VM-global state; the rest of the provider attempt protocol cases
  # run concurrently in their own module.
  use ExUnit.Case, async: false

  alias Loopex.Runtime.ProviderAttempt

  @record_cardinality_limit 1_024

  # Concept: the byte and depth ceilings decide an adapter answer before it is
  # read, exactly as the cardinality ceiling already did.
  #
  # Technical depth: cardinality was applied to the raw collections, but bytes
  # and depth were not applied until `attempt_result/3` measured the settlement,
  # which is after `canonical_reply/2` has normalised keys, projected identity
  # and usage, and walked and rebuilt every tool call. So an answer carrying the
  # full 1,024 admitted tool calls with a megabyte of argument text each, or an
  # arguments map nested ten thousand levels deep, was projected in full and
  # only then failed to fit -- both of them answers no durable item could ever
  # hold, decided by ADR 0017's own 65,536-byte and depth-12 ceilings. M2's
  # row-one obligation fixes the opposite order: the raw candidate satisfies
  # plain-data, depth, item and byte ceilings first, and only then is projected.
  # Each arm asserts the order directly: a call trace on the projection's own
  # entry point shows it was never entered for a refused reply and was entered
  # for an ordinary one, under a generous wall clock. Neither elapsed time nor
  # a before-and-after heap size is that witness -- the scheduler inflates the
  # first and garbage collection hides the second -- so a fix that merely moved
  # the measurement later would fail here and nowhere else.
  test "an adapter reply above the item byte or depth ceiling is refused before it is projected" do
    projection_entry = {ProviderAttempt, :project_tool_calls, 1}
    assert {:module, ProviderAttempt} = Code.ensure_loaded(ProviderAttempt)
    assert :erlang.trace_pattern(projection_entry, true, [:local]) == 1
    on_exit(fn -> :erlang.trace_pattern(projection_entry, false, [:local]) end)

    request = %{
      canonical_request_bytes: "canonical-request-bytes",
      staged_request_digest: String.duplicate("d", 64)
    }

    megabyte = String.duplicate("x", 1024 * 1024)

    wide =
      adapter_reply(
        request,
        List.duplicate(
          %{"id" => "call-1", "name" => "tool", "arguments" => %{"text" => megabyte}},
          @record_cardinality_limit
        )
      )

    deep_arguments =
      Enum.reduce(1..10_000, %{"leaf" => 1}, fn _level, nested -> %{"nested" => nested} end)

    deep =
      adapter_reply(request, [
        %{"id" => "call-1", "name" => "tool", "arguments" => deep_arguments}
      ])

    # Each reply is canonicalised in a process of its own that this one traces,
    # and `traced/1` returns only after the trace is delivered, so the absence
    # of a call is checked without a wait. The wall-clock bound stays only as a
    # generous ceiling on the whole call under a shared scheduler; it is not
    # the witness.
    for {name, raw} <- [{"byte", wide}, {"depth", deep}] do
      {elapsed, result} =
        :timer.tc(fn -> traced(fn -> ProviderAttempt.canonical_reply(raw, request) end) end)

      assert result == {:error, :unreadable_model_answer},
             "the #{name} ceiling did not refuse the raw reply"

      refute_received {:trace, _pid, :call, {ProviderAttempt, :project_tool_calls, _calls}},
                      "the #{name} refusal entered the projection before the ceiling refused it"

      assert elapsed < 10_000_000, "the #{name} refusal took #{elapsed} microseconds"
    end

    ordinary = %{"id" => "call-1", "name" => "tool", "arguments" => %{"path" => "README.md"}}

    assert {:ok, projected} =
             traced(fn ->
               ProviderAttempt.canonical_reply(adapter_reply(request, [ordinary]), request)
             end)

    # The witness is armed: an admitted reply does enter the projection.
    assert_received {:trace, _pid, :call, {ProviderAttempt, :project_tool_calls, [_calls]}}

    assert projected["tool_calls"] == [ordinary]
    assert projected["staged_request_digest"] == request.staged_request_digest
    refute Map.has_key?(projected, "canonical_request_bytes")
  end

  # A process cannot observe its own calls, so the call under test runs in a
  # process of its own with this one as its tracer, and the result is returned
  # only once the runtime confirms every trace message has been delivered.
  defp traced(fun) do
    tracer = self()

    pid =
      spawn_link(fn ->
        receive do
          :go -> send(tracer, {:traced_result, self(), fun.()})
        end
      end)

    assert :erlang.trace(pid, true, [:call, {:tracer, tracer}]) == 1
    send(pid, :go)

    result =
      receive do
        {:traced_result, ^pid, result} -> result
      after
        60_000 -> flunk("the traced call did not return")
      end

    delivered = :erlang.trace_delivered(pid)

    receive do
      {:trace_delivered, ^pid, ^delivered} -> result
    after
      5_000 -> flunk("the trace was not delivered")
    end
  end

  defp adapter_reply(request, calls) do
    %{
      "text" => "",
      "identity" => %{
        "provider" => "scripted",
        "model" => "scripted:v1",
        "endpoint" => "in-process"
      },
      "usage" => %{"input_tokens" => 3, "output_tokens" => 2},
      "tool_calls" => calls,
      "delta_count" => 0,
      "streamed" => false,
      "provider_response_id" => nil,
      "staged_request_digest" => request.staged_request_digest,
      "canonical_request_bytes" => request.canonical_request_bytes
    }
  end
end
