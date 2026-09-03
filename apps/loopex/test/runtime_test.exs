Code.require_file("support/m1_runtime_helper.exs", __DIR__)

defmodule Loopex.RuntimeTest do
  use ExUnit.Case, async: false

  alias Loopex.M1RuntimeTestStore
  alias Loopex.Runtime

  test "two runtimes coexist without a global name" do
    registered_before = MapSet.new(Process.registered())
    {store_a_pid, store_a} = M1RuntimeTestStore.start_store(label: "store-a")
    {store_b_pid, store_b} = M1RuntimeTestStore.start_store(label: "store-b")

    {:ok, runtime_a} =
      Loopex.start_link(context_token_budget: 8_192, runtime_id: "runtime-a", store: store_a)

    {:ok, runtime_b} =
      Loopex.start_link(context_token_budget: 8_192, runtime_id: "runtime-b", store: store_b)

    on_exit(fn -> stop_runtime(runtime_a) end)
    on_exit(fn -> stop_runtime(runtime_b) end)
    on_exit(fn -> stop_store(store_a_pid) end)
    on_exit(fn -> stop_store(store_b_pid) end)

    assert {:ok, "s_test_1"} =
             Loopex.create_session(runtime_a, %{"tenant" => "a"}, command_id: "create-1")

    assert {:ok, "s_test_1"} =
             Loopex.create_session(runtime_b, %{"tenant" => "b"}, command_id: "create-1")

    assert {:ok, %{runtime_id: "runtime-a"}} = Runtime.configuration(runtime_a)
    assert {:ok, %{runtime_id: "runtime-b"}} = Runtime.configuration(runtime_b)

    assert %{{"runtime-a", "create-1"} => _mapping} =
             M1RuntimeTestStore.inspect_state(store_a_pid).runtime_commands

    assert %{{"runtime-b", "create-1"} => _mapping} =
             M1RuntimeTestStore.inspect_state(store_b_pid).runtime_commands

    {:ok, attachment_a} = Loopex.attach(runtime_a, "s_test_1", after_event_sequence: 0)
    {:ok, attachment_b} = Loopex.attach(runtime_b, "s_test_1", after_event_sequence: 0)

    assert {:accepted, "prompt-a"} =
             Loopex.command(attachment_a, %{
               type: :prompt,
               command_id: "prompt-a",
               content: "alpha"
             })

    assert {:error, :empty} = Loopex.next_event(attachment_b)
    assert M1RuntimeTestStore.inspect_state(store_b_pid).sessions["s_test_1"].events == []

    {:ok, %{dispatcher: dispatcher_a}} = Runtime.children(runtime_a)
    {:ok, %{dispatcher: dispatcher_b}} = Runtime.children(runtime_b)
    Process.exit(dispatcher_a, :kill)

    eventually(fn ->
      match?(
        {:ok, %{dispatcher: replacement}} when replacement != dispatcher_a,
        Runtime.children(runtime_a)
      )
    end)

    assert Process.alive?(dispatcher_b)
    assert {:ok, %{dispatcher: ^dispatcher_b}} = Runtime.children(runtime_b)

    assert registered_before == MapSet.new(Process.registered())
  end

  test "a runtime reference is required rather than inferred" do
    {store_pid, store} = M1RuntimeTestStore.start_store()

    {:ok, runtime} =
      Loopex.start_link(context_token_budget: 8_192, runtime_id: "explicit-runtime", store: store)

    on_exit(fn -> Application.delete_env(:loopex, :runtime) end)
    on_exit(fn -> stop_runtime(runtime) end)
    on_exit(fn -> stop_store(store_pid) end)

    Application.put_env(:loopex, :runtime, runtime)

    assert {:error, :runtime_reference_required} =
             Loopex.create_session(nil, %{}, command_id: "missing-runtime")

    assert {:error, :runtime_reference_required} =
             Runtime.resume_session(nil, "session", "resume")

    assert {:error, :runtime_reference_required} = Loopex.diagnostic(nil, %{"message" => "x"})
    assert {:error, :attachment_required} = Loopex.command(nil, %{type: :abort, command_id: "a"})

    fields = Map.from_struct(runtime)

    foreign =
      struct!(Runtime,
        supervisor: Map.fetch!(fields, :supervisor),
        token: make_ref()
      )

    assert {:error, :runtime_unavailable} = Runtime.configuration(foreign)

    assert :ok = Loopex.stop(runtime)
    assert {:error, :runtime_unavailable} = Runtime.configuration(runtime)

    assert {:error, :runtime_unavailable} =
             Loopex.create_session(runtime, %{}, command_id: "stopped-runtime")
  end

  test "a supervised runtime starts and stops with explicit configuration" do
    {store_pid, store} = M1RuntimeTestStore.start_store()

    on_exit(fn -> stop_store(store_pid) end)

    assert {:error, :invalid_runtime_options} = Loopex.start_link([])

    assert {:error, :invalid_runtime_options} =
             Loopex.start_link(context_token_budget: 8_192, runtime_id: "r")

    assert {:error, :invalid_runtime_options} = Loopex.start_link(store: store)

    # Concept: a declared session value is validated where it is declared.
    #
    # Technical depth: ADR 0009 makes the cleanup period a session configuration
    # value with a default, and a period of nothing is not a cooperative window,
    # it is a kill. A host that means that should ask for the smallest period it
    # actually wants to wait, so every non-positive and non-integer value is
    # refused at start rather than becoming a grace an operator cannot observe
    # until something has already gone wrong.
    for refused <- [0, -1, "5000", 1.5, :never] do
      assert {:error, :invalid_runtime_options} =
               Loopex.start_link(
                 context_token_budget: 8_192,
                 runtime_id: "bad-grace-#{System.unique_integer([:positive])}",
                 store: store,
                 cleanup_grace_ms: refused
               ),
             "cleanup_grace_ms: #{inspect(refused)} started a runtime"
    end

    {:ok, runtime} =
      Loopex.start_link(
        context_token_budget: 8_192,
        runtime_id: "supervised-runtime",
        store: store,
        attachment_capacity: 7,
        progress_to: self(),
        diagnostics_to: self()
      )

    assert {:ok, %{runtime_id: "supervised-runtime", attachment_capacity: 7}} =
             Runtime.configuration(runtime)

    assert {:ok, %{control: control, sessions: sessions, dispatcher: dispatcher}} =
             Runtime.children(runtime)

    assert Enum.all?([control, sessions, dispatcher], &Process.alive?/1)

    Process.exit(control, :kill)

    eventually(fn ->
      case Runtime.children(runtime) do
        {:ok, replacement} ->
          replacement.control != control and replacement.sessions != sessions and
            replacement.dispatcher != dispatcher and
            Enum.all?(Map.values(replacement), &Process.alive?/1)

        _other ->
          false
      end
    end)

    {:ok, replacements} = Runtime.children(runtime)
    assert :ok = Loopex.stop(runtime)
    refute Runtime.alive?(runtime)
    assert {:error, :runtime_unavailable} = Runtime.children(runtime)

    eventually(fn -> Enum.all?(Map.values(replacements), &(not Process.alive?(&1))) end)
  end

  defp eventually(assertion, attempts \\ 200)

  defp eventually(assertion, attempts) when attempts > 0 do
    if assertion.() do
      :ok
    else
      Process.sleep(5)
      eventually(assertion, attempts - 1)
    end
  end

  defp eventually(_assertion, 0), do: flunk("condition did not become true")

  defp stop_runtime(runtime) do
    if Runtime.alive?(runtime), do: Loopex.stop(runtime)
  end

  defp stop_store(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid)
  end
end
