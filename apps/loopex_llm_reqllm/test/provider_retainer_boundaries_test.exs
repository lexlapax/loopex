Code.require_file("support/provider_isolation_fixture.exs", __DIR__)

defmodule Loopex.LLM.ReqLLM.ProviderRetainerBoundariesTest do
  use ExUnit.Case, async: false

  alias Loopex.LLM.ReqLLM, as: Adapter
  alias Loopex.LLM.ReqLLM.ProviderIsolationFixture, as: Fixture

  setup do
    variable = Adapter.credential_variable()
    previous = System.get_env(variable)
    System.put_env(variable, "synthetic-retainer-boundary-credential")

    on_exit(fn ->
      if previous, do: System.put_env(variable, previous), else: System.delete_env(variable)
    end)

    :ok
  end

  test "retainer death after actual OS cleanup begins ends the lifetime without a later Core stop" do
    fixture = Fixture.new(:blocked, paused: true)
    request = Fixture.request()
    {retainer, retainer_monitor} = spawn_monitor(fn -> receive do: (:stop -> :ok) end)
    call = Fixture.managed(fixture, request, retainer)
    guardian = call.guardian
    guardian_monitor = call.monitor
    caller = call.caller
    assert :erlang.trace(guardian, true, [:send, :receive, {:tracer, self()}]) == 1
    send(caller, :continue)

    try do
      assert_receive {:trace, ^guardian, :receive,
                      {:provider_frame, _receiver, {:ok, :dispatch_started, binding}}},
                     remaining(request)

      assert Fixture.eventually(fn -> Fixture.count(fixture) == 1 end)
      assert Fixture.methods(fixture) == ["POST"]
      assert [{_request, true}] = Fixture.events(fixture)
      child = Fixture.pid(fixture)
      namespace = Fixture.namespace(fixture)
      assert File.dir?(namespace)
      signal(child, "STOP")
      assert Fixture.eventually(fn -> stopped?(child) end)

      cooperative = System.monotonic_time(:millisecond) + remaining(request) + 2_000
      observation = cooperative + 100

      assert_receive {:completed, ^caller,
                      {:error, {:dispatched_or_unknown, "model_call_failed"}}},
                     until(cooperative)

      assert System.system_time(:millisecond) >= request.deadline

      # Concept: this is the cleanup interval, not a queued provider result.
      # Technical depth: the unchanged OS guard removes its namespace only in
      # cleanup. The stopped, still-live worker prevents cessation proof while
      # the guard's original watchdog and inspection loop are already active.
      assert Fixture.eventually(fn -> not File.exists?(namespace) end, until(cooperative))
      assert stopped?(child)
      assert Process.alive?(guardian)

      Process.exit(retainer, :kill)
      assert_receive {:DOWN, ^retainer_monitor, :process, ^retainer, :killed}, until(cooperative)

      assert_receive {:trace, ^guardian, :receive,
                      {:DOWN, _monitor, :process, ^retainer, :killed}},
                     until(cooperative)

      assert System.monotonic_time(:millisecond) < cooperative
      assert stopped?(child)
      signal(child, "CONT")

      # No Core stop is supplied: ignoring retainer loss in the cleanup phase
      # would strand this guardian in its post-proof retained state.
      assert_receive {:trace, ^guardian, :receive,
                      {_control, {:data, {:eol, "cleanup_complete:" <> _ = acknowledgement}}}},
                     until(cooperative)

      assert String.starts_with?(acknowledgement, "cleanup_complete:" <> binding["nonce"] <> ":")
      assert acknowledgement =~ ~r/:([0-9a-f]{32})$/
      assert_receive {:DOWN, ^guardian_monitor, :process, ^guardian, :normal}, until(observation)
      fence = :erlang.trace_delivered(guardian)
      assert_receive {:trace_delivered, ^guardian, ^fence}, until(observation)

      refute_receive {:trace, ^guardian, :send, {:loopex_provider_resource_stopped, _, _}, _},
                     0

      assert Fixture.eventually(
               fn -> Fixture.transport_events(fixture) == [:connected, :closed] end,
               until(observation)
             )

      Fixture.assert_gone(fixture)
      assert Fixture.canaries(fixture) == 1
      assert Fixture.count(fixture) == 1
    after
      if Fixture.reached?(fixture, "pid") and Fixture.alive?(Fixture.pid(fixture)),
        do: signal(Fixture.pid(fixture), "CONT")

      if Process.alive?(retainer), do: Process.exit(retainer, :kill)
    end
  end

  defp until(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)
  defp remaining(request), do: max(request.deadline - System.system_time(:millisecond), 0)

  defp signal(pid, name) do
    assert {_output, 0} = System.cmd("/bin/kill", ["-" <> name, Integer.to_string(pid)])
  end

  defp stopped?(pid) do
    case System.cmd("/bin/ps", ["-p", Integer.to_string(pid), "-o", "stat="]) do
      {state, 0} -> String.starts_with?(String.trim(state), "T")
      {_missing, 1} -> false
      other -> flunk("process observation unavailable: #{inspect(other)}")
    end
  end
end
