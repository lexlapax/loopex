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

  test "retainer death during actual credential delivery stops the busy owned writer and child" do
    System.put_env(Adapter.credential_variable(), String.duplicate("k", 65_536))
    fixture = Fixture.new(:credential_transfer, paused: true)
    request = Fixture.request()
    {retainer, retainer_monitor} = spawn_monitor(fn -> receive do: (:stop -> :ok) end)
    call = Fixture.managed(fixture, request, retainer)
    guardian = call.guardian
    guardian_monitor = call.monitor
    caller = call.caller
    assert :erlang.trace(guardian, true, [:send, :receive, {:tracer, self()}]) == 1
    send(caller, :continue)

    try do
      assert credential_proof(fixture, "credential-entry-held", request) ==
               %{"actual_entry_not_started" => true}

      assert :erlang.suspend_process(guardian)
      File.write!(Fixture.marker(fixture, "start-entry"), "release")

      assert credential_proof(fixture, "bootstrap-reader-held", request) ==
               %{"actual_reader_suspended" => true, "private_socket" => true}

      assert :erlang.resume_process(guardian)

      assert_receive {:trace, ^guardian, :receive,
                      {:provider_sent, _bootstrap_sender, :bootstrap, :ok}},
                     remaining(request)

      # The child is still suspended in its first real recv: readiness cannot
      # race this second guardian hold, regardless of dependency startup speed.
      assert :erlang.suspend_process(guardian)
      File.write!(Fixture.marker(fixture, "resume-bootstrap"), "release")

      assert credential_proof(fixture, "credential-ready-observed", request) ==
               %{"actual_ready_send" => true}

      assert Fixture.eventually(fn -> queued_ready(guardian) != nil end, remaining(request))
      {receiver, binding} = queued_ready(guardian)
      assert Enum.sort(Map.keys(binding)) == ["build_manifest_sha256", "nonce", "version"]
      assert binding["version"] == 2
      assert binding["build_manifest_sha256"] == fixture.options[:build_manifest_sha256]
      assert binding["nonce"] =~ ~r/\A[0-9a-f]{64}\z/
      File.write!(Fixture.marker(fixture, "hold-credential-reader"), "release")

      assert credential_proof(fixture, "credential-reader-held", request) ==
               %{
                 "actual_reader_suspended" => true,
                 "actual_ready_send" => true,
                 "private_socket" => true
               }

      [socket] =
        Enum.filter(Port.list(), fn port ->
          Port.info(port, :connected) == {:connected, guardian} and local_socket?(port)
        end)

      :ok = :inet.setopts(socket, sndbuf: 1_024, high_watermark: 1_024, low_watermark: 512)
      receiver_monitor = Process.monitor(receiver)
      assert :erlang.resume_process(guardian)

      assert_receive {:trace, ^guardian, :receive,
                      {:provider_frame, ^receiver, {:ok, :ready, ^binding}}},
                     remaining(request)

      assert Fixture.eventually(
               fn -> blocked_sender(guardian, socket) != nil end,
               remaining(request)
             ),
             "no actual owned writer blocked during credential delivery"

      {writer, kind, pending} = blocked_sender(guardian, socket)
      assert pending > 0
      assert kind in [:credential, :invocation]
      writer_monitor = Process.monitor(writer)

      # A successful send may enqueue bytes without the child consuming them.
      # If that happened, the invocation writer is the next blocked helper;
      # do not mislabel it as the credential sender. The actual child remains
      # suspended before consuming its credential frame in either schedule.
      if kind == :invocation do
        assert_receive {:trace, ^guardian, :receive,
                        {:provider_sent, _credential_sender, :credential, :ok}},
                       remaining(request)
      end

      assert Fixture.alive?(Fixture.pid(fixture))
      assert File.dir?(Fixture.namespace(fixture))
      assert Fixture.canaries(fixture) == 0
      assert Fixture.transport_events(fixture) == []
      assert System.system_time(:millisecond) < request.deadline
      cooperative = System.monotonic_time(:millisecond) + 2_000
      Process.exit(retainer, :kill)
      assert_receive {:DOWN, ^retainer_monitor, :process, ^retainer, :killed}, until(cooperative)

      assert_receive {:trace, ^guardian, :receive,
                      {:DOWN, _monitor, :process, ^retainer, :killed}},
                     until(cooperative)

      assert_receive {:DOWN, ^writer_monitor, :process, ^writer, :killed}, until(cooperative)
      assert_receive {:DOWN, ^receiver_monitor, :process, ^receiver, :killed}, until(cooperative)

      assert_receive {:completed, ^caller,
                      {:error, {:dispatched_or_unknown, "model_call_failed"}}},
                     until(cooperative)

      assert_receive {:trace, ^guardian, :receive,
                      {_control, {:data, {:eol, "cleanup_complete:" <> _ = acknowledgement}}}},
                     until(cooperative)

      assert String.starts_with?(acknowledgement, "cleanup_complete:" <> binding["nonce"] <> ":")
      assert acknowledgement =~ ~r/:([0-9a-f]{32})$/
      assert_receive {:DOWN, ^guardian_monitor, :process, ^guardian, :normal}, until(cooperative)
      assert Port.info(socket) == nil
      Fixture.assert_gone(fixture)
      assert Fixture.canaries(fixture) == 0
      assert Fixture.events(fixture) == []
      assert Fixture.transport_events(fixture) == []
    after
      if Process.info(guardian, :status) == {:status, :suspended},
        do: :erlang.resume_process(guardian)

      if Process.alive?(retainer), do: Process.exit(retainer, :kill)
    end
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

  defp credential_proof(fixture, name, request) do
    assert Fixture.eventually(
             fn ->
               Fixture.reached?(fixture, name) or
                 Fixture.reached?(fixture, "credential-boundary-error")
             end,
             remaining(request)
           ),
           "missing actual credential-boundary witness: #{name}"

    refute Fixture.reached?(fixture, "credential-boundary-error"),
           "credential boundary observation failed"

    fixture |> Fixture.marker(name) |> File.read!() |> Jason.decode!()
  end

  defp queued_ready(guardian) do
    {:messages, messages} = Process.info(guardian, :messages)

    Enum.find_value(messages, fn
      {:provider_frame, receiver, {:ok, :ready, binding}} -> {receiver, binding}
      _other -> nil
    end)
  end

  defp blocked_sender(guardian, socket) do
    {:ok, [send_pend: pending]} = :inet.getstat(socket, [:send_pend])
    {:links, links} = Process.info(guardian, :links)

    if pending > 0 do
      Enum.find_value(links, fn pid ->
        if is_pid(pid) do
          case Process.info(pid, :current_stacktrace) do
            {:current_stacktrace, stack} ->
              sending =
                Enum.any?(stack, fn
                  {Loopex.LLM.ReqLLM.ProviderCodec, :send, 3, _} -> true
                  _other -> false
                end)

              kind =
                Enum.find_value(stack, fn
                  {Loopex.LLM.ReqLLM.ProviderBridge, function, _arity, _location} ->
                    name = Atom.to_string(function)

                    cond do
                      String.starts_with?(name, "-start_credential_sender/") -> :credential
                      String.starts_with?(name, "-start_send/") -> :invocation
                      true -> nil
                    end

                  _other ->
                    nil
                end)

              if sending and kind, do: {pid, kind, pending}

            nil ->
              nil
          end
        end
      end)
    end
  end

  defp local_socket?(port) do
    match?({:ok, {:local, _}}, :inet.peername(port))
  catch
    _, _ -> false
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
