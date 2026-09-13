Code.require_file("support/provider_phase_diagnostic.exs", __DIR__)

defmodule Loopex.LLM.ReqLLM.ProviderPhaseDiagnosticTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO
  alias Loopex.LLM.ReqLLM.ProviderPhaseDiagnostic, as: Diagnostic

  defmodule Control do
    def loop(_state), do: :ok
    def begin_cleanup(_state, _request), do: :ok
    def cleanup_proved(_state), do: :ok
    def fail(_state), do: :ok
    def port_lost(_state), do: :ok
    def deliver(_state, _result), do: :ok
    def observe_failure(_stage, _class), do: :ok
  end

  @failure_stages ~w(handoff stream metadata completion assembly calls)
  @failure_classes ~w(stream_http_auth stream_http_rate_limit stream_http_server stream_http_status stream_transport_timeout stream_transport_tls stream_transport_error stream_http_protocol_error stream_finch_error stream_http_task_failed stream_wait_timeout stream_task_call_timeout stream_decode_error stream_other_error genserver_timeout raised exited thrown caught provider_status stream_failed stream_incomplete assembly_failed returned_error unclassified)

  defp failure_report(calls) do
    capture_io(fn ->
      assert catch_throw(
               Diagnostic.capture(
                 fn ->
                   Control.loop(%{phase: :running})

                   Enum.each(calls, fn {stage, class} -> Control.observe_failure(stage, class) end)

                   Control.cleanup_proved(%{})
                   throw(:original_failure)
                 end,
                 Control
               )
             ) == :original_failure
    end)
    |> String.trim()
    |> String.replace_prefix("provider phase diagnostic ", "")
    |> Jason.decode!()
  end

  test "finite failure pairs are static evidence separate from the thirteen phase labels" do
    pairs = for stage <- @failure_stages, class <- @failure_classes, do: {stage, class}

    for {stage, class} <- pairs ++ [{"unavailable", "unclassified"}] do
      report = failure_report([{stage, class}])
      assert report["failure"] == %{"stage" => stage, "class" => class}
      assert report["healthy"] and report["cleanup_confirmed"]
      refute report["incomplete"]
      assert map_size(report["phases"]) == 2
      assert report["counts"] == %{"dispatch_started" => 1, "cleanup_proved" => 1}
    end

    assert {:flags, []} = :erlang.trace_info(self(), :flags)
    assert {:traced, false} = :erlang.trace_info({Control, :observe_failure, 2}, :traced)
  end

  test "missing duplicate and unknown failure evidence never yields a guessed pair" do
    absent = failure_report([])
    assert absent["failure"] == nil
    refute absent["incomplete"]

    canary = "private-secret-provider-body"

    for calls <- [
          [{"stream", "stream_transport_timeout"}, {"stream", "stream_transport_timeout"}],
          [{"stream", "stream_transport_timeout"}, {"calls", "raised"}],
          [{"unavailable", "raised"}],
          [{canary, "raised"}],
          [{"stream", %{secret: canary}}],
          [{canary, canary}, {"calls", "raised"}],
          [{"calls", "raised"}, {canary, canary}]
        ] do
      report = failure_report(calls)
      assert report["failure"] == nil
      assert report["incomplete"]
      assert report["cleanup_confirmed"]
      refute Jason.encode!(report) =~ canary
    end
  end

  test "accepted failure evidence is silent on success and cannot survive into another capture" do
    assert capture_io(fn ->
             assert Diagnostic.capture(
                      fn ->
                        Control.loop(%{phase: :running})
                        Control.observe_failure("stream", "returned_error")
                        :original_result
                      end,
                      Control
                    ) == :original_result
           end) == ""

    assert failure_report([])["failure"] == nil
  end

  test "a descendant's finite failure is delivered before the collector barrier" do
    output =
      capture_io(fn ->
        assert catch_throw(
                 Diagnostic.capture(
                   fn ->
                     {child, reference} =
                       spawn_monitor(fn ->
                         Control.loop(%{phase: :running})
                         Control.observe_failure("metadata", "returned_error")
                         Control.cleanup_proved(%{})
                       end)

                     assert_receive {:DOWN, ^reference, :process, ^child, :normal}
                     throw(:original_failure)
                   end,
                   Control
                 )
               ) == :original_failure
      end)

    report =
      output
      |> String.trim()
      |> String.replace_prefix("provider phase diagnostic ", "")
      |> Jason.decode!()

    assert report["failure"] == %{"stage" => "metadata", "class" => "returned_error"}
    assert report["healthy"] and report["cleanup_confirmed"]
    refute report["incomplete"]
    assert {:traced, false} = :erlang.trace_info({Control, :observe_failure, 2}, :traced)
  end

  test "actual match specifications preserve late phases and never disclose arguments" do
    canary = "private-credential-body-state-canary"

    output =
      capture_io(fn ->
        assert catch_throw(
                 Diagnostic.capture(
                   fn ->
                     for _ <- 1..150, do: Control.loop(%{phase: :running, credential: canary})

                     for result <- [
                           {:ok, canary},
                           {:error, {:dispatched_or_unknown, canary}},
                           {:error, {:not_dispatched, canary}}
                         ] do
                       Control.loop(%{phase: :terminal_end, result: result})
                       Control.begin_cleanup(%{result: result}, canary)
                       Control.deliver(%{}, result)
                     end

                     Control.cleanup_proved(%{secret: canary})
                     Control.fail(canary)
                     Control.port_lost(canary)
                     throw(:original_failure)
                   end,
                   Control
                 )
               ) == :original_failure
      end)

    refute output =~ canary

    report =
      output
      |> String.trim()
      |> String.replace_prefix("provider phase diagnostic ", "")
      |> Jason.decode!()

    assert report["available"]
    refute report["incomplete"]
    assert map_size(report["phases"]) == 13
    assert report["counts"]["dispatch_started"] == 150

    assert Enum.all?(report["phases"], fn {_label, offset} ->
             is_integer(offset) and offset >= 0
           end)

    assert report["phases"]["terminal_ok"] >= report["phases"]["dispatch_started"]
    assert {:flags, []} = :erlang.trace_info(self(), :flags)
    assert {:traced, false} = :erlang.trace_info({Control, :loop, 1}, :traced)
  end

  test "successful callback retains the original caller and emits nothing" do
    caller = self()

    assert capture_io(fn ->
             assert Diagnostic.capture(
                      fn ->
                        assert self() == caller
                        Control.loop(%{phase: :running})
                        :original_result
                      end,
                      Control
                    ) == :original_result
           end) == ""

    assert {:flags, []} = :erlang.trace_info(self(), :flags)
  end

  test "original exception and stack survive unavailable instrumentation" do
    output =
      capture_io(fn ->
        try do
          Diagnostic.capture(
            fn -> raise ArgumentError, "original exception" end,
            MissingDiagnosticModule
          )

          flunk("must raise")
        rescue
          exception in ArgumentError ->
            assert exception.message == "original exception"
            assert [{__MODULE__, _, _, _} | _] = __STACKTRACE__
        end
      end)

    assert output =~ "\"available\":false"
  end

  test "descendant traces are fenced and collector exits after the original failure" do
    owner = self()

    output =
      capture_io(fn ->
        assert catch_throw(
                 Diagnostic.capture(
                   fn ->
                     {:tracer, tracer} = :erlang.trace_info(self(), :tracer)
                     send(owner, {:diagnostic_tracer, tracer})

                     {child, reference} =
                       spawn_monitor(fn -> Control.cleanup_proved(%{secret: "hidden"}) end)

                     receive do
                       {:DOWN, ^reference, :process, ^child, :normal} -> :ok
                     end

                     throw(:original_failure)
                   end,
                   Control
                 )
               ) == :original_failure
      end)

    assert output =~ "cleanup_proved"
    refute output =~ "hidden"
    assert_receive {:diagnostic_tracer, tracer}
    reference = Process.monitor(tracer)
    assert_receive {:DOWN, ^reference, :process, ^tracer, _}
  end

  test "successful original callback cannot hide unavailable or incomplete diagnostics" do
    owner = self()

    capture_io(fn ->
      for module <- [MissingDiagnosticModule, Control] do
        assert_raise RuntimeError, "provider phase diagnostic unavailable or incomplete", fn ->
          Diagnostic.capture(
            fn ->
              send(owner, :called_once)
              :ok
            end,
            module
          )
        end

        assert_receive :called_once
        refute_receive :called_once
      end

      assert_raise RuntimeError, "provider phase diagnostic unavailable or incomplete", fn ->
        Diagnostic.capture(
          fn ->
            for _ <- 1..10_001, do: Control.loop(%{phase: :running})
            :ok
          end,
          Control
        )
      end
    end)
  end

  test "uncatchable owner death removes global patterns before collector terminates" do
    parent = self()

    {owner, owner_monitor} =
      spawn_monitor(fn ->
        Diagnostic.capture(
          fn ->
            {:tracer, tracer} = :erlang.trace_info(self(), :tracer)
            Control.observe_failure("stream", "raised")
            send(parent, {:ready_to_kill, self(), tracer})

            receive do
              :never -> :ok
            end
          end,
          Control
        )
      end)

    on_exit(fn -> cleanup_owner(owner) end)
    assert_receive {:ready_to_kill, ^owner, tracer}
    tracer_monitor = Process.monitor(tracer)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^owner_monitor, :process, ^owner, :killed}
    assert_receive {:DOWN, ^tracer_monitor, :process, ^tracer, :normal}

    for {function, arity, _spec} <- Diagnostic.specifications() do
      assert {:traced, false} = :erlang.trace_info({Control, function, arity}, :traced)
    end
  end

  test "owner death with a queued snapshot still finalizes global patterns" do
    parent = self()

    {owner, owner_monitor} =
      spawn_monitor(fn ->
        Diagnostic.capture(
          fn ->
            {:tracer, tracer} = :erlang.trace_info(self(), :tracer)
            Control.observe_failure("stream", "raised")
            send(parent, {:snapshot_owner, self(), tracer})

            receive do
              :never -> :ok
            end
          end,
          Control
        )
      end)

    on_exit(fn -> cleanup_owner(owner) end)
    assert_receive {:snapshot_owner, ^owner, tracer}
    tracer_monitor = Process.monitor(tracer)
    true = :erlang.suspend_process(tracer)

    try do
      send(tracer, {:snapshot, owner, make_ref()})
      Process.exit(owner, :kill)
      assert_receive {:DOWN, ^owner_monitor, :process, ^owner, :killed}
    after
      :erlang.resume_process(tracer)
    end

    assert_receive {:DOWN, ^tracer_monitor, :process, ^tracer, :normal}

    for {function, arity, _spec} <- Diagnostic.specifications() do
      assert {:traced, false} = :erlang.trace_info({Control, function, arity}, :traced)
    end
  end

  defp cleanup_owner(owner) do
    tracer =
      case :erlang.trace_info(owner, :tracer) do
        {:tracer, pid} when is_pid(pid) -> pid
        _ -> nil
      end

    reference = Process.monitor(owner)
    Process.exit(owner, :kill)

    receive do
      {:DOWN, ^reference, :process, ^owner, _} -> :ok
    after
      1_000 -> raise "diagnostic owner cleanup failed"
    end

    if tracer do
      reference = Process.monitor(tracer)

      receive do
        {:DOWN, ^reference, :process, ^tracer, _} -> :ok
      after
        1_000 -> raise "diagnostic collector cleanup failed"
      end
    end

    await_patterns_removed(System.monotonic_time(:millisecond) + 1_000)
  end

  defp await_patterns_removed(deadline) do
    clean =
      Enum.all?(Diagnostic.specifications(), fn {f, a, _} ->
        :erlang.trace_info({Control, f, a}, :traced) == {:traced, false}
      end)

    cond do
      clean ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        raise "diagnostic patterns cleanup failed"

      true ->
        receive do
        after
          1 -> await_patterns_removed(deadline)
        end
    end
  end

  test "count saturation reports incomplete without dropping later labels" do
    output =
      capture_io(fn ->
        assert catch_exit(
                 Diagnostic.capture(
                   fn ->
                     for _ <- 1..10_001, do: Control.loop(%{phase: :running})
                     Control.cleanup_proved(%{})
                     exit(:original_exit)
                   end,
                   Control
                 )
               ) == :original_exit
      end)

    report =
      output
      |> String.trim()
      |> String.replace_prefix("provider phase diagnostic ", "")
      |> Jason.decode!()

    assert report["incomplete"]
    assert report["counts"]["dispatch_started"] == 10_000
    assert Map.has_key?(report["phases"], "cleanup_proved")
  end
end
