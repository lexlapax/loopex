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

  @control Loopex.Runtime.Control

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
end
