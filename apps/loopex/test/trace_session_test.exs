Code.require_file("support/m1_runtime_helper.exs", __DIR__)

defmodule Loopex.TraceSessionTest do
  @moduledoc """
  ## Concept

  A host turns on a runtime-scoped trace of Loopex calls without changing any
  source, reads bounded entries, and turns it off again. These cases prove what
  a session reports, what it refuses to report, and that it never becomes a way
  to reach the runtime or to read content.

  ## Technical depth

  Each case runs one real runtime with a real dispatcher and a test Store, and
  reads entries from the runtime's diagnostics sink. Assertions name the exact
  module a session was allowed to observe, so an entry from anything else fails
  the case rather than passing unnoticed.
  """

  use ExUnit.Case, async: false

  alias Loopex.M1RuntimeTestStore, as: TestStore
  alias Loopex.Runtime
  alias Loopex.Trace

  @control Loopex.Runtime.Control

  test "a session reports calls in the named module inside owned processes" do
    runtime = fixture()

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

    assert Enum.all?(drain_entries(), &(&1["module"] in [inspect(@control), nil]))
  end

  test "the same call in an unowned process is not reported" do
    runtime = fixture()

    assert {:ok, _status} =
             Loopex.trace(runtime, %{modules: [Loopex.Trace.Config], level: :calls})

    # The test process is not part of the runtime's supervision tree, so the
    # session must not observe it even though the module is on the allowlist.
    assert {:ok, _validated} = Loopex.Trace.Config.validate(%{level: :calls})

    refute_receive {:loopex_diagnostic, %{"kind" => "trace_call"}}, 300
  end

  test "the returns level reports a class and a duration" do
    runtime = fixture()

    assert {:ok, _status} = Loopex.trace(runtime, %{modules: [@control], level: :returns})
    provoke(runtime)

    entry = await_entry("trace_call", &Map.has_key?(&1, "class"))
    assert entry["class"] in ["return", "exception"]
    assert is_integer(entry["duration_native"]) or is_nil(entry["duration_native"])
    assert is_binary(entry["return"])
  end

  test "the arguments level renders arguments and redacts what they carry" do
    runtime = fixture()

    assert {:ok, _status} = Loopex.trace(runtime, %{modules: [@control], level: :arguments})
    provoke(runtime)

    entry = await_entry("trace_call", &Map.has_key?(&1, "arguments"))
    assert is_binary(entry["arguments"])
    assert byte_size(entry["arguments"]) <= 4_096
  end

  test "redaction replaces credentials, model content and payload bytes" do
    rendered =
      Loopex.Trace.Entry.render(
        %{
          credential_reference: "super-secret-value",
          messages: [%{"role" => "user", "content" => "private prompt"}],
          blob: :binary.copy("a", 4_096),
          session_id: "session-1"
        },
        4_096
      )

    refute rendered =~ "super-secret-value"
    refute rendered =~ "private prompt"
    refute rendered =~ String.duplicate("a", 65)
    assert rendered =~ "session-1"
    assert rendered =~ "redacted"
  end

  test "an entry is truncated to the session's byte ceiling" do
    rendered = Loopex.Trace.Entry.render(Enum.to_list(1..1_000), 256)
    assert byte_size(rendered) <= 256
  end

  test "the rate ceiling drops entries and reports the count" do
    runtime = fixture()

    assert {:ok, _status} =
             Loopex.trace(runtime, %{
               modules: [@control],
               level: :calls,
               limits: %{entries_per_second: 1}
             })

    provoke(runtime)
    # The window is one second wide; the next call after it turns over is what
    # carries the count of everything the ceiling refused in the window before.
    Process.sleep(1_100)
    provoke(runtime)

    dropped = await_entry("trace_dropped")
    assert dropped["dropped"] > 0
    assert dropped["reason"] == "trace_limit"
  end

  test "stopping the session ends every entry" do
    runtime = fixture()

    assert {:ok, _status} = Loopex.trace(runtime, %{modules: [@control], level: :calls})
    provoke(runtime)
    _observed = await_entry("trace_call")

    assert :ok = Loopex.trace_stop(runtime)
    assert {:error, :no_trace_session} = Loopex.trace_status(runtime)

    _drained = drain_entries()
    provoke(runtime)
    refute_receive {:loopex_diagnostic, %{"kind" => "trace_call"}}, 300
  end

  test "a second session on the same runtime is refused while one runs" do
    runtime = fixture()

    assert {:ok, _status} = Loopex.trace(runtime, %{modules: [@control]})

    assert {:error, :trace_session_already_running} =
             Loopex.trace(runtime, %{modules: [@control]})
  end

  test "a session cannot be started without the runtime reference" do
    runtime = fixture()
    {:ok, %{tracer: tracer}} = Runtime.children(runtime)

    assert {:error, :invalid_runtime_reference} =
             Trace.start_session(tracer, make_ref(), %{modules: [@control]})

    assert {:error, :invalid_runtime_reference} = Trace.stop_session(tracer, make_ref())
  end

  test "a configuration that widens a ceiling or a namespace is refused" do
    runtime = fixture()

    assert {:error, :invalid_trace_limits} =
             Loopex.trace(runtime, %{limits: %{entries_per_second: 2_001}})

    assert {:error, :invalid_trace_level} = Loopex.trace(runtime, %{level: :everything})
    assert {:error, :invalid_trace_sink} = Loopex.trace(runtime, %{sink: :stdout})
    assert {:error, :invalid_trace_modules} = Loopex.trace(runtime, %{modules: [:"Loopex.*"]})
    assert {:error, :invalid_trace_configuration} = Loopex.trace(runtime, %{unknown: true})
  end

  test "another tracer in the VM keeps receiving its own messages" do
    runtime = fixture()
    other = :trace.session_create(:loopex_trace_test_other, self(), [])

    on_exit(fn -> :trace.session_destroy(other) end)

    # A process never receives trace messages about itself, so the other
    # session observes a separate worker while this process is its tracer.
    worker = spawn(fn -> receive do: (:call -> Loopex.Trace.Config.ceilings()) end)
    :trace.function(other, {Loopex.Trace.Config, :ceilings, 0}, true, [:local])
    :trace.process(other, worker, true, [:call])

    assert {:ok, _status} = Loopex.trace(runtime, %{modules: [@control], level: :calls})
    send(worker, :call)

    assert_receive {:trace, ^worker, :call, {Loopex.Trace.Config, :ceilings, _arguments}}, 1_000

    provoke(runtime)
    assert await_entry("trace_call")["module"] == inspect(@control)
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
