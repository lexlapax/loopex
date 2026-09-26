Code.require_file("support/provider_isolation_fixture.exs", __DIR__)

defmodule Loopex.LLM.ReqLLM.ProviderStartupBoundariesTest do
  # The no-fallback witness installs a VM-global trace pattern on
  # System.get_env/1 and captures Logger output, so this module remains serial.
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO
  import ExUnit.CaptureLog

  alias Loopex.LLM.ReqLLM, as: Adapter
  alias Loopex.LLM.ReqLLM.ProviderIsolationFixture, as: Fixture

  @canary "synthetic-provider-preentry-credential-7d81"

  test "an actual pre-entry crash resolves no credential and invokes no transport" do
    # Concept: readiness, not merely child creation, authorizes credential
    # resolution. An entry failure must stay a bounded pre-dispatch refusal.
    # Technical depth: both branches use host custody, and the environment-call
    # observer proves neither falls back to the old adapter read. The failing
    # child exits before Worker.main; neither branch supplies a synthetic
    # private-protocol acknowledgement. Trace only calls, never return values.
    assert :erlang.trace_pattern({System, :get_env, 1}, true, [:local]) == 1
    observer = self()

    try do
      logs =
        capture_log(fn ->
          output =
            capture_io(fn ->
              for mode <- [:reply, :pre_entry_crash] do
                fixture = Fixture.new(mode, paused: true, credential: @canary)

                # The crashing child never becomes ready, so its refusal is
                # reached by the committed deadline expiring, and the deadline
                # is what that mode costs. It keeps the port default all the
                # same: the entry markers asserted below are written by the
                # booted child before it halts, and a shorter deadline had the
                # boot stopped early on a loaded hosted runner. The replying
                # child ends when it answers.
                request = Fixture.request()
                call = Fixture.managed(fixture, request, :unmanaged)

                caller = call.caller
                guardian = call.guardian
                guardian_monitor = call.monitor

                assert :erlang.trace(guardian, true, [
                         :call,
                         :procs,
                         :set_on_spawn,
                         {:tracer, self()}
                       ]) == 1

                send(caller, :continue)
                # The crashing child's result arrives after the deadline and the
                # unmanaged cleanup grace that follows it, so the wait is derived
                # from the deadline rather than a number sized against it.
                assert_receive {:completed, ^caller, result}, Fixture.until_settled(call)
                assert_receive {:DOWN, ^guardian_monitor, :process, ^guardian, :normal}, 500
                barrier = :erlang.trace_delivered(:all)
                assert_receive {:trace_delivered, :all, ^barrier}, 1_000
                reads = credential_reads([])

                if mode == :reply do
                  assert {:ok, %{text: text}} = result
                  assert is_binary(text)
                  assert reads == []
                  assert Fixture.methods(fixture) == ["POST"]
                  assert [{_body, true}] = Fixture.events(fixture)
                else
                  assert result == {:error, {:not_dispatched, "model_call_failed"}}
                  assert reads == []
                  assert Fixture.methods(fixture) == []
                  assert Fixture.events(fixture) == []
                  assert Fixture.transport_events(fixture) == []
                  assert File.regular?(Fixture.marker(fixture, "entry-env"))
                end

                Fixture.assert_gone(fixture)

                refute File.read!(Fixture.marker(fixture, "entry-env")) =~
                         Adapter.credential_variable()
              end
            end)

          send(observer, {:startup_host_output, output})
        end)

      assert_receive {:startup_host_output, output}
      refute output =~ @canary
      refute logs =~ @canary
    after
      :erlang.trace_pattern({System, :get_env, 1}, false, [:local])
    end
  end

  defp credential_reads(reads) do
    receive do
      {:trace, pid, :call, {System, :get_env, ["LOOPEX_PROVIDER_API_KEY"]}} ->
        credential_reads([pid | reads])

      {:trace, _pid, _kind, _detail} ->
        credential_reads(reads)

      {:trace, _pid, _kind, _first, _second} ->
        credential_reads(reads)
    after
      0 -> Enum.reverse(reads)
    end
  end
end
