Code.require_file("support/m1_runtime_helper.exs", __DIR__)

defmodule Loopex.TraceSessionTest do
  @moduledoc """
  ## Concept

  A host turns on a runtime-scoped trace of Loopex calls without changing any
  source, reads bounded entries, and turns it off again. These cases prove what
  a session reports, what it refuses to report, that its ceilings hold without
  delaying the runtime, and that nothing reachable from a session, a client or
  a model can start, change or stop one.

  ## Technical depth

  Each case runs one real runtime with a real dispatcher and a test Store, and
  reads entries from the runtime's diagnostics sink. Assertions name the exact
  module a session was allowed to observe, so an entry from anything else fails
  the case rather than passing unnoticed. The unavailable path runs against a
  runtime whose trace-capability module is one an older release would not have,
  so it is the real refusal rather than a simulated one.
  """

  use ExUnit.Case, async: false

  alias Loopex.M1RuntimeTestStore, as: TestStore
  alias Loopex.Runtime
  alias Loopex.Trace
  alias Loopex.Trace.Capability

  @control Loopex.Runtime.Control

  defmodule PendingCall do
    @moduledoc false

    def block(parent) do
      send(parent, {:pending_trace_call, self()})
      receive do: (:finish -> :ok)
    end
  end

  defmodule ExclusionProbe do
    @moduledoc false

    def before(parent) do
      send(parent, {:exclusion_probe, self(), :before})
      :ok
    end

    def after_exclusion(parent) do
      send(parent, {:exclusion_probe, self(), :after})
      :ok
    end

    def control(parent) do
      send(parent, {:exclusion_probe, self(), :control})
      :ok
    end
  end

  defmodule SensitiveProbe do
    @moduledoc false

    def carry(parent) do
      send(parent, {:sensitive_probe, self()})
      :ok
    end
  end

  defmodule CanaryTrace do
    @moduledoc false

    @canary "loopex-private-trace-handle-canary"

    def canary, do: @canary

    def session_create(:loopex_trace, tracer, []) when is_pid(tracer) do
      {{@canary, make_ref()}, {:loopex_trace, System.unique_integer([:positive])}}
    end

    def function({{@canary, reference}, {:loopex_trace, id}}, _mfa, _match_spec, _options)
        when is_reference(reference) and is_integer(id),
        do: 1

    def process({{@canary, reference}, {:loopex_trace, id}}, pid, _enabled, _flags)
        when is_reference(reference) and is_integer(id) and is_pid(pid),
        do: 1

    def session_destroy({{@canary, reference}, {:loopex_trace, id}})
        when is_reference(reference) and is_integer(id),
        do: true
  end

  test "a runtime owned session traces only allowed modules and owned processes and leaves a second VM tracer unaffected" do
    runtime = fixture()

    # Another tracer in the VM, on its own session. A process never receives
    # trace messages about itself, so the other session observes a worker.
    other = :trace.session_create(:loopex_trace_test_other, self(), [])
    on_exit(fn -> :trace.session_destroy(other) end)
    worker = spawn(fn -> receive do: (:call -> Loopex.Trace.Config.ceilings()) end)
    {:module, _module} = Code.ensure_loaded(Loopex.Trace.Config)
    1 = :trace.function(other, {Loopex.Trace.Config, :ceilings, 0}, true, [:local])
    1 = :trace.process(other, worker, true, [:call])

    assert {:ok, status} = Loopex.trace(runtime, %{modules: [@control], level: :calls})
    assert status.level == :calls
    assert status.sink == :diagnostics

    provoke(runtime)

    entry = await_entry("trace_call")
    assert entry["module"] == inspect(@control)
    assert is_integer(entry["arity"])
    assert is_binary(entry["pid"])
    assert is_integer(entry["monotonic_native"])
    refute Map.has_key?(entry, "arguments")

    # Every entry this session produced is from the one allowed module.
    assert Enum.all?(drain_entries(), &(&1["module"] in [inspect(@control), nil]))

    # An unowned process calling a module on the allowlist is not observed.
    assert {:ok, _validated} = Loopex.Trace.Config.validate(%{level: :calls})
    refute_receive {:loopex_diagnostic, %{"kind" => "trace_call"}}, 300

    # The other tracer still receives its own session's messages.
    send(worker, :call)
    assert_receive {:trace, ^worker, :call, {Loopex.Trace.Config, :ceilings, _arguments}}, 1_000
  end

  test "each trace level reports its documented fields and the arguments level redacts credential references model content tool arguments and artifact bytes" do
    calls = fixture()
    assert {:ok, _status} = Loopex.trace(calls, %{modules: [@control], level: :calls})
    provoke(calls)
    call_entry = await_entry("trace_call")
    assert is_binary(call_entry["caller"])
    refute Map.has_key?(call_entry, "class")
    refute Map.has_key?(call_entry, "arguments")
    refute Map.has_key?(call_entry, "return")
    assert :ok = Loopex.trace_stop(calls)
    _drained = drain_entries()

    returns = fixture(runtime_id: "trace-returns")
    assert {:ok, _status} = Loopex.trace(returns, %{modules: [@control], level: :returns})
    provoke(returns)
    return_entry = await_entry("trace_call", &Map.has_key?(&1, "class"))
    assert return_entry["class"] in ["return", "exception"]
    assert is_binary(return_entry["return"])
    refute Map.has_key?(return_entry, "arguments")
    assert :ok = Loopex.trace_stop(returns)
    _drained = drain_entries()

    arguments = fixture(runtime_id: "trace-arguments")
    assert {:ok, _status} = Loopex.trace(arguments, %{modules: [@control], level: :arguments})
    provoke(arguments)
    argument_entry = await_entry("trace_call", &Map.has_key?(&1, "arguments"))
    assert is_binary(argument_entry["arguments"])
    assert byte_size(argument_entry["arguments"]) <= 4_096

    # Redaction runs over the term before it is rendered, so a credential
    # reference, a model body, tool arguments and artifact bytes are replaced
    # by placeholders that carry only a size and a digest.
    rendered =
      Loopex.Trace.Entry.render(
        %{
          credential_reference: "super-secret-value",
          messages: [%{"role" => "user", "content" => "private prompt"}],
          arguments: %{"path" => "workspace/file.txt", "content" => "tool argument content"},
          artifact: :binary.copy("a", 4_096),
          session_id: "session-1"
        },
        4_096
      )

    refute rendered =~ "super-secret-value"
    refute rendered =~ "private prompt"
    refute rendered =~ "tool argument content"
    refute rendered =~ String.duplicate("a", 65)
    assert rendered =~ "session-1"
    assert rendered =~ "redacted"

    short_credential = "canary-under-sixty-four-bytes"

    keyword_rendered =
      Loopex.Trace.Entry.render(
        [credential_token: short_credential, ordinary_option: short_credential],
        4_096
      )

    refute keyword_rendered =~ "credential_token: \"#{short_credential}\""
    assert keyword_rendered =~ "ordinary_option: \"#{short_credential}\""
    assert keyword_rendered =~ "redacted"

    # An entry is bounded whatever the term was.
    assert byte_size(Loopex.Trace.Entry.render(Enum.to_list(1..1_000), 256)) <= 256
  end

  test "trace limits drop with a counted entry and never block a coordinator" do
    runtime = fixture()

    assert {:ok, _status} =
             Loopex.trace(runtime, %{
               modules: [@control],
               level: :calls,
               limits: %{entries_per_second: 1}
             })

    provoke(runtime)
    # The rate window is one second wide; the next call after it turns over is
    # what carries the count of everything the ceiling refused before it.
    Process.sleep(1_100)

    # The runtime answers while the session is dropping, and answers promptly:
    # a tracer that made a traced process wait would show up here as a timeout.
    started = System.monotonic_time(:millisecond)
    provoke(runtime)
    assert System.monotonic_time(:millisecond) - started < 1_000

    dropped = await_entry("trace_dropped")
    assert dropped["dropped"] > 0
    assert dropped["reason"] == "trace_limit"

    assert Loopex.Trace.Config.ceilings() == %{
             entry_bytes: 4_096,
             entries_per_second: 2_000,
             queued: 8_192
           }

    # A host lowers a ceiling and never raises one.
    assert :ok = Loopex.trace_stop(runtime)

    assert {:error, :invalid_trace_limits} =
             Loopex.trace(runtime, %{limits: %{entries_per_second: 2_001}})

    assert {:error, :invalid_trace_limits} = Loopex.trace(runtime, %{limits: %{queued: 8_193}})

    assert {:error, :invalid_trace_limits} =
             Loopex.trace(runtime, %{limits: %{entry_bytes: 4_097}})
  end

  test "calls-only sessions retain no pending calls and return sessions purge pending calls when a process dies" do
    calls = fixture(runtime_id: "trace-no-pending-calls")
    assert {:ok, _status} = Loopex.trace(calls, %{modules: [PendingCall], level: :calls})
    {:ok, %{tracer: calls_tracer, workers: calls_workers}} = Runtime.children(calls)
    parent = self()

    {:ok, calls_task} =
      Task.Supervisor.start_child(calls_workers, fn -> PendingCall.block(parent) end)

    assert_receive {:pending_trace_call, ^calls_task}
    assert %{calls: %{}, call_monitors: %{}} = :sys.get_state(calls_tracer)
    send(calls_task, :finish)

    returns = fixture(runtime_id: "trace-pending-return")
    assert {:ok, _status} = Loopex.trace(returns, %{modules: [PendingCall], level: :returns})
    {:ok, %{tracer: returns_tracer, workers: returns_workers}} = Runtime.children(returns)

    {:ok, returns_task} =
      Task.Supervisor.start_child(returns_workers, fn -> PendingCall.block(parent) end)

    assert_receive {:pending_trace_call, ^returns_task}

    assert eventually(fn ->
             state = :sys.get_state(returns_tracer)
             map_size(state.calls) == 1 and map_size(state.call_monitors) == 1
           end)

    Process.exit(returns_task, :kill)

    assert eventually(fn ->
             state = :sys.get_state(returns_tracer)
             state.calls == %{} and state.call_monitors == %{}
           end)
  end

  test "trace status formatting exposes no process state message reason or log" do
    secret = "credential-canary"

    assert %{
             state: :redacted_trace_state,
             message: :redacted_trace_message,
             reason: :redacted_trace_reason,
             log: []
           } =
             Trace.format_status(%{
               state: %{credential_token: secret},
               message: {:credential_token, secret},
               reason: {:credential_token, secret},
               log: [secret]
             })
  end

  test "a bound capability excludes its caller through a delivery barrier and restores the last named MFA on caller death" do
    runtime = fixture(runtime_id: "trace-exclusion")
    {:ok, capability_pid} = Capability.start_link()
    {:ok, capability} = Capability.handle(capability_pid)
    assert :ok = Capability.bind(capability, runtime)
    assert :ok = Capability.bind(capability, runtime)

    assert {:ok, _status} =
             Loopex.trace(runtime, %{
               modules: [Trace, ExclusionProbe, SensitiveProbe],
               level: :returns
             })

    {:ok, %{tracer: tracer, workers: workers, control: control}} = Runtime.children(runtime)
    :ok = :sys.suspend(tracer)
    parent = self()

    {:ok, sender} =
      Task.Supervisor.start_child(workers, fn ->
        ExclusionProbe.before(parent)

        result =
          Trace.exclude_self(capability,
            functions: [{SensitiveProbe, :carry, 1}]
          )

        send(parent, {:excluded, self(), result})
        SensitiveProbe.carry(parent)
        ExclusionProbe.after_exclusion(parent)
        send(parent, {:excluded_sender_parked, self()})
        receive do: (:finish -> :ok)
      end)

    assert_receive {:exclusion_probe, ^sender, :before}
    refute_receive {:excluded, ^sender, _result}, 50
    :ok = :sys.resume(tracer)
    assert_receive {:excluded, ^sender, :ok}, 1_000

    trace_state = :sys.get_state(tracer)

    refute Enum.any?(trace_state.calls, fn {{pid, _, _, _}, _started} -> pid == sender end)
    refute Map.has_key?(trace_state.call_monitors, sender)

    assert_receive {:sensitive_probe, ^sender}
    assert_receive {:exclusion_probe, ^sender, :after}
    assert_receive {:excluded_sender_parked, ^sender}

    before_entry =
      await_entry("trace_call", fn entry ->
        entry["pid"] == inspect(sender) and entry["function"] == "before"
      end)

    assert before_entry["pid"] == inspect(sender)

    sender_text = inspect(sender)

    refute_receive {:loopex_diagnostic,
                    %{"kind" => "trace_call", "pid" => ^sender_text, "function" => "carry"}},
                   50

    refute_receive {:loopex_diagnostic,
                    %{
                      "kind" => "trace_call",
                      "pid" => ^sender_text,
                      "function" => "after_exclusion"
                    }},
                   50

    {:ok, control_task} =
      Task.Supervisor.start_child(workers, fn -> ExclusionProbe.control(parent) end)

    assert_receive {:exclusion_probe, ^control_task, :control}

    control_entry =
      await_entry("trace_call", fn entry ->
        entry["pid"] == inspect(control_task) and entry["function"] == "control"
      end)

    assert control_entry["pid"] == inspect(control_task)

    {:ok, globally_cleared} =
      Task.Supervisor.start_child(workers, fn -> SensitiveProbe.carry(parent) end)

    assert_receive {:sensitive_probe, ^globally_cleared}
    Process.sleep(50)

    refute Enum.any?(drain_entries(), fn entry ->
             entry["pid"] == inspect(globally_cleared) and entry["function"] == "carry"
           end)

    send(sender, :finish)

    assert eventually(fn ->
             state = :sys.get_state(control)
             state.trace_excluded == %{} and state.trace_mfa_counts == %{}
           end)

    {:ok, restored} = Task.Supervisor.start_child(workers, fn -> SensitiveProbe.carry(parent) end)
    assert_receive {:sensitive_probe, ^restored}

    restored_entry =
      await_entry("trace_call", fn entry ->
        entry["pid"] == inspect(restored) and entry["function"] == "carry"
      end)

    assert restored_entry["pid"] == inspect(restored)
  end

  test "a capability binds once and malformed or cross-runtime handles refuse" do
    runtime_a = fixture(runtime_id: "trace-capability-a")
    runtime_b = fixture(runtime_id: "trace-capability-b")
    {:ok, capability_pid} = Capability.start_link()
    {:ok, capability} = Capability.handle(capability_pid)

    assert :ok = Capability.bind(capability, runtime_a)
    assert :ok = Capability.bind(capability, runtime_a)
    assert {:error, :capability_already_bound} = Capability.bind(capability, runtime_b)

    malformed = Map.put(capability, :extra, :not_allowed)
    assert {:error, :invalid_tracing_capability} = Capability.bind(malformed, runtime_a)
    assert {:error, :unavailable} = Trace.exclude_self(malformed, functions: [])
  end

  test "trace exclusions grow with live senders instead of refusing an artificial MFA ceiling" do
    runtime = fixture(runtime_id: "trace-proportional-exclusion")
    {:ok, capability_pid} = Capability.start_link()
    {:ok, capability} = Capability.handle(capability_pid)
    assert :ok = Capability.bind(capability, runtime)

    assert {:ok, _status} =
             Loopex.trace(runtime, %{modules: [ExclusionProbe], level: :calls})

    {:ok, %{workers: workers, control: control}} = Runtime.children(runtime)
    functions = Enum.map(0..64, &{ExclusionProbe, :proportional_probe, &1})
    parent = self()

    {:ok, sender} =
      Task.Supervisor.start_child(workers, fn ->
        send(
          parent,
          {:proportional_exclusion, self(), Trace.exclude_self(capability, functions: functions)}
        )

        receive do: (:finish -> :ok)
      end)

    assert_receive {:proportional_exclusion, ^sender, :ok}, 1_000

    assert eventually(fn ->
             state = :sys.get_state(control)

             case state.trace_excluded do
               %{^sender => %{functions: retained}} ->
                 MapSet.size(retained) == 65 and map_size(state.trace_mfa_counts) == 65

               _not_registered ->
                 false
             end
           end)

    send(sender, :finish)

    assert eventually(fn ->
             state = :sys.get_state(control)
             state.trace_excluded == %{} and state.trace_mfa_counts == %{}
           end)
  end

  test "Trace owns the only full session handle in private ETS and restores an active session after restart" do
    runtime = fixture(runtime_id: "trace-private-handle")
    assert {:ok, original} = Loopex.trace(runtime, %{modules: [@control], level: :calls})
    {:ok, %{tracer: tracer}} = Runtime.children(runtime)
    state = :sys.get_state(tracer)

    assert state.session_identity == {:loopex_trace, elem(state.session_identity, 1)}
    assert_raise ArgumentError, fn -> :ets.lookup(state.session_table, :session) end
    refute Map.has_key?(state, :session)

    Process.exit(tracer, :kill)

    assert eventually(fn ->
             case Runtime.children(runtime) do
               {:ok, %{tracer: replacement}} -> replacement != tracer
               _unavailable -> false
             end
           end)

    assert {:ok, restored} = Loopex.trace_status(runtime)
    assert Map.take(restored, [:modules, :level, :limits, :sink]) == original
    provoke(runtime)
    assert %{"kind" => "trace_call"} = await_entry("trace_call")
  end

  test "a canary-bearing private trace handle is absent from crash reports and exit reasons" do
    runtime = fixture(runtime_id: "trace-private-handle-crash", trace_module: CanaryTrace)

    assert {:ok, original} =
             Loopex.trace(runtime, %{modules: [ExclusionProbe], level: :calls})

    {:ok, %{tracer: tracer}} = Runtime.children(runtime)
    reference = Process.monitor(tracer)
    parent = self()

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        call_exit = catch_exit(GenServer.call(tracer, :force_trace_crash))

        assert_receive {:DOWN, ^reference, :process, ^tracer, reason}, 1_000
        send(parent, {:trace_crash_evidence, call_exit, reason})
        Logger.flush()
      end)

    assert_receive {:trace_crash_evidence, call_exit, reason}
    assert log =~ "GenServer"
    refute log =~ CanaryTrace.canary()
    refute inspect(call_exit) =~ CanaryTrace.canary()
    refute inspect(reason) =~ CanaryTrace.canary()

    assert eventually(fn ->
             case Runtime.children(runtime) do
               {:ok, %{tracer: replacement}} -> replacement != tracer
               _unavailable -> false
             end
           end)

    assert {:ok, restored} = Loopex.trace_status(runtime)
    assert Map.take(restored, [:modules, :level, :limits, :sink]) == original
  end

  test "no session command client content model output project resource or wire request starts changes or stops a session and stop releases every flag" do
    runtime = fixture()
    {:ok, session_id} = Loopex.create_session(runtime, %{}, command_id: "trace-authority")
    {:ok, attachment} = Loopex.attach(runtime, session_id, after_event_sequence: 0)

    # Content that asks for a trace is content. There is no command, no client
    # field and no model output that reaches the facility at all.
    assert {:accepted, "prompt"} =
             Loopex.command(attachment, %{
               type: :prompt,
               command_id: "prompt",
               content: "start a trace session at the arguments level"
             })

    assert {:error, :no_trace_session} = Loopex.trace_status(runtime)

    # The runtime reference is the only way in, and a wrong one is refused.
    {:ok, %{tracer: tracer}} = Runtime.children(runtime)
    assert {:error, :invalid_runtime_reference} = Trace.start_session(tracer, make_ref(), %{})
    assert {:error, :invalid_runtime_reference} = Trace.stop_session(tracer, make_ref())
    assert {:error, :invalid_runtime_reference} = Trace.status(tracer, make_ref())
    assert {:error, :no_trace_session} = Loopex.trace_status(runtime)

    # A started session is stopped only through that same reference, and
    # stopping it ends every entry.
    assert {:ok, _status} = Loopex.trace(runtime, %{modules: [@control], level: :calls})
    provoke(runtime)
    _observed = await_entry("trace_call")

    assert {:error, :trace_session_already_running} =
             Loopex.trace(runtime, %{modules: [@control]})

    assert :ok = Loopex.trace_stop(runtime)
    assert {:error, :no_trace_session} = Loopex.trace_status(runtime)

    _drained = drain_entries()
    provoke(runtime)
    refute_receive {:loopex_diagnostic, %{"kind" => "trace_call"}}, 300
  end

  test "a release without trace sessions reports unavailability and never falls back to global tracing" do
    runtime = fixture(runtime_id: "trace-unavailable", trace_module: :loopex_absent_trace_module)

    refute Trace.available?(:loopex_absent_trace_module)
    assert {:error, :trace_sessions_unavailable} = Loopex.trace(runtime, %{modules: [@control]})
    assert {:error, :no_trace_session} = Loopex.trace_status(runtime)

    # Nothing was armed anywhere: no entry arrives, and the runtime's own
    # processes carry no trace flags from a global fallback.
    provoke(runtime)
    refute_receive {:loopex_diagnostic, %{"kind" => "trace_call"}}, 300

    {:ok, %{control: control}} = Runtime.children(runtime)
    assert :erlang.trace_info(control, :flags) == {:flags, []}
  end

  test "a configuration outside the accepted shape is refused by name" do
    runtime = fixture()

    assert {:error, :invalid_trace_level} = Loopex.trace(runtime, %{level: :everything})
    assert {:error, :invalid_trace_sink} = Loopex.trace(runtime, %{sink: :stdout})
    assert {:error, :invalid_trace_modules} = Loopex.trace(runtime, %{modules: [:"Loopex.*"]})
    assert {:error, :invalid_trace_modules} = Loopex.trace(runtime, %{modules: []})
    assert {:error, :invalid_trace_configuration} = Loopex.trace(runtime, %{unknown: true})
    assert {:error, :no_trace_session} = Loopex.trace_status(runtime)
  end

  defp fixture(options \\ []) do
    {store_pid, store} = TestStore.start_store()

    {:ok, runtime} =
      Loopex.start_link(
        Keyword.merge(
          [
            context_token_budget: 8_192,
            runtime_id: "trace-session",
            store: store,
            diagnostics_to: self()
          ],
          options
        )
      )

    on_exit(fn ->
      if Runtime.alive?(runtime), do: Loopex.stop(runtime)
      if Process.alive?(store_pid), do: GenServer.stop(store_pid)
    end)

    runtime
  end

  # Concept: one ordinary call into a process this runtime owns.
  #
  # Technical depth: the session status of an absent session is answered inside
  # the control process and mutates nothing, so it provokes traced calls
  # without changing what any other assertion observes.
  defp provoke(runtime) do
    Loopex.session_status(runtime, "absent-session")
  end

  defp await_entry(kind, accept \\ fn _entry -> true end, deadline \\ 2_000) do
    receive do
      {:loopex_diagnostic, %{"kind" => ^kind} = entry} ->
        if accept.(entry), do: entry, else: await_entry(kind, accept, deadline)

      {:loopex_diagnostic, _other} ->
        await_entry(kind, accept, deadline)
    after
      deadline -> flunk("no #{kind} entry arrived within #{deadline}ms")
    end
  end

  defp drain_entries(collected \\ []) do
    receive do
      {:loopex_diagnostic, entry} -> drain_entries([entry | collected])
    after
      50 -> Enum.reverse(collected)
    end
  end

  defp eventually(fun, attempts \\ 100)

  defp eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end

  defp eventually(_fun, 0), do: false
end
