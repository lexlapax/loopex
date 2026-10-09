defmodule LoopexComposition.FacadeClientTest do
  use ExUnit.Case, async: true

  alias LoopexComposition.Ephemeral.FacadeClient

  defmodule Facade do
    def create_session(test, options, command_options) do
      send(test, {:entered, self(), options, command_options})
      {:ok, "session"}
    end
  end

  defmodule BlockingFacade do
    def create_session(test, _options, _command_options) do
      send(test, {:blocked, self()})

      receive do
        :release -> {:ok, "session"}
        :fail -> raise "private sentinel"
      end
    end
  end

  defmodule ObservedRealFacade do
    def create_session({runtime, test}, options, command_options) do
      result = Loopex.create_session(runtime, options, command_options)
      send(test, {:create_returned, self(), result})
      result
    end
  end

  defmodule Model do
    @behaviour Loopex.Model

    @impl true
    def complete(request, _options, _progress) do
      {:ok,
       %{
         completion: "unknown",
         continuation: nil,
         text: "facade answer",
         tool_calls: [],
         identity: %{provider: "scripted", model: request.model, endpoint: "in-process"},
         usage: %{input_tokens: 1, output_tokens: 1},
         delta_count: 0,
         streamed: false,
         provider_response_id: nil,
         canonical_request_bytes: request.canonical_request_bytes,
         staged_request_digest: request.staged_request_digest
       }}
    end
  end

  defmodule UnusedExecutor do
    @behaviour Loopex.Executor
    @impl true
    def execute(_, _, _, _, _), do: raise("no tools were offered")
    @impl true
    def cancel(_, _), do: raise("no tools were offered")
    @impl true
    def retained_receipt(_, _), do: raise("no tools were offered")
  end

  test "unchanged facade runs a scripted prompt with Memory and releases the actor attachment" do
    {:ok, store_pid} = Loopex.Store.Memory.start_link()
    {:ok, store} = Loopex.Store.new(Loopex.Store.Memory, store_pid)

    {:ok, runtime} =
      Loopex.start_link(
        runtime_id: "facade-#{System.unique_integer([:positive])}",
        context_token_budget: 8_192,
        store: store,
        model: %{module: Model, model: "scripted:v1", options: [max_tokens: 256]},
        executor: %{
          module: UnusedExecutor,
          reference: self(),
          identity: "unused",
          epoch: 1,
          fencing_token: 1,
          workspace_ref: "unused",
          workspace_lease: "unused"
        },
        grant_decision: {:host_policy, :allow},
        bounds: %{max_turns: 2, token_budget: 1_000_000, deadline_ms: 5_000}
      )

    try do
      assert :ok = LoopexComposition.StartupGate.publication(LoopexComposition.StartupGate.await(runtime))
      {client, monitor} = FacadeClient.start(self(), runtime, genesis())
      assert {:ok, session} = operation(client, :create)
      assert {:ok, attachment} = operation(client, :attach)
      assert {:ok, _catalog} = operation(client, :resource_catalog)
      assert {:ok, _status} = operation(client, :session_status)

      assert {:accepted, "prompt"} =
               operation(
                 client,
                 {:command, %{type: :prompt, command_id: "prompt", content: "hello"}}
               )

      events = follow(client, System.monotonic_time(:millisecond) + 2_000, [])
      assert Enum.any?(events, &(&1.kind == "assistant.message_appended"))
      assert List.last(events).kind == "run.finished"
      assert {:ok, _} = Loopex.attachment_status(attachment)
      kill(client, monitor)
      await_attachment_release(attachment, System.monotonic_time(:millisecond) + 1_000)
      assert {:ok, _} = Loopex.session_status(runtime, session)
    after
      Loopex.stop(runtime)
      GenServer.stop(store_pid)
    end
  end

  test "normal owner loss during a real facade call drains once and terminates" do
    {:ok, store_pid} = Loopex.Store.Memory.start_link()
    {:ok, store} = Loopex.Store.new(Loopex.Store.Memory, store_pid)

    {:ok, runtime} =
      Loopex.start_link(
        runtime_id: "owner-loss-#{System.unique_integer([:positive])}",
        context_token_budget: 8_192,
        store: store
      )

    on_exit(fn ->
      if Process.alive?(runtime.supervisor), do: Loopex.stop(runtime)
      if Process.alive?(store_pid), do: GenServer.stop(store_pid)
    end)

    assert :ok = LoopexComposition.StartupGate.publication(LoopexComposition.StartupGate.await(runtime))
    {:ok, %{control: control}} = Loopex.Runtime.children(runtime)
    true = :erlang.suspend_process(control)
    test = self()

    owner =
      spawn(fn ->
        {client, _monitor} =
          FacadeClient.start(self(), {runtime, test}, genesis(), ObservedRealFacade)

        send(test, {:client, client})
        ref = make_ref()
        send(client, {self(), ref, :create})

        receive do
          {^client, ^ref, :ready} -> send(client, {self(), ref, :dispatch, deadline()})
        end

        receive do
          :stop -> :ok
        end
      end)

    try do
      assert_receive {:client, client}, 1_000
      on_exit(fn -> if Process.alive?(client), do: Process.exit(client, :kill) end)
      monitor = Process.monitor(client)
      wait_for_call(control, client, System.monotonic_time(:millisecond) + 5_000)
      owner_monitor = Process.monitor(owner)
      send(owner, :stop)
      assert_receive {:DOWN, ^owner_monitor, :process, ^owner, :normal}, 1_000
      assert Process.alive?(client)
      true = :erlang.resume_process(control)
      # Concept: owner loss retires the actor after its real core call returns.
      # Technical depth: resuming Control is not a barrier for session activation.
      assert_receive {:create_returned, ^client, {:ok, _session}}, 5_000
      assert_receive {:DOWN, ^monitor, :process, ^client, :normal}, 5_000
      refute Process.alive?(client)

      assert {:ok, _} =
               Loopex.create_session(runtime, %{"surface" => "embedded"},
                 command_id: "create",
                 genesis: genesis()
               )
    after
      if Process.alive?(owner), do: Process.exit(owner, :kill)

      if Process.info(control, :status) == {:status, :suspended},
        do: :erlang.resume_process(control)

      Loopex.stop(runtime)
      GenServer.stop(store_pid)
    end
  end

  defp wait_for_call(control, client, deadline) do
    assert System.monotonic_time(:millisecond) < deadline

    messages =
      case Process.info(control, :messages) do
        {:messages, messages} -> messages
        _other -> []
      end

    queued? =
      Enum.any?(messages, fn message ->
        match?(
          {:"$gen_call", {^client, _reply_ref},
           {:create_session_with_genesis, _token, "create", %{"surface" => "embedded"}, _genesis}},
          message
        )
      end)

    if queued? do
      :ok
    else
      receive do
      after
        1 -> :ok
      end

      wait_for_call(control, client, deadline)
    end
  end

  defp await_attachment_release(attachment, deadline) do
    assert System.monotonic_time(:millisecond) < deadline

    case Loopex.attachment_status(attachment) do
      {:error, _} ->
        :ok

      {:ok, _} ->
        receive do
        after
          1 -> :ok
        end

        await_attachment_release(attachment, deadline)
    end
  end

  defp operation(client, operation) do
    ref = make_ref()
    send(client, {self(), ref, operation})
    assert_receive {^client, ^ref, :ready}, 1_000
    send(client, {self(), ref, :dispatch, deadline()})

    receive do
      {^client, ^ref, result} -> result
    after
      1_000 -> flunk("facade did not return")
    end
  end

  defp follow(client, deadline, events) do
    assert System.monotonic_time(:millisecond) < deadline

    case operation(client, :next_event) do
      {:ok, %{kind: "run.finished"} = event} ->
        Enum.reverse([event | events])

      {:ok, event} ->
        follow(client, deadline, [event | events])

      {:error, :empty} ->
        receive do
        after
          10 -> :ok
        end

        follow(client, deadline, events)
    end
  end

  test "only the live owner and current reference grant entry, and loss never retries" do
    {client, monitor} = FacadeClient.start(self(), self(), genesis(), Facade)
    ref = make_ref()
    send(client, {self(), ref, :create})
    assert_receive {^client, ^ref, :ready}, 1_000
    send(client, {self(), make_ref(), :dispatch, deadline()})
    send(client, {spawn(fn -> :ok end), ref, :dispatch, deadline()})
    send(client, {self(), make_ref(), :cancel})
    send(client, {spawn(fn -> :ok end), ref, :cancel})
    send(client, {self(), ref, :dispatch, :invalid})
    refute_receive {:entered, _, _, _}
    send(client, {self(), ref, :dispatch, deadline()})
    assert_receive {^client, ^ref, {:ok, "session"}}, 1_000

    assert_received {:entered, ^client, %{"surface" => "embedded"},
                     [command_id: "create", genesis: expected]}

    assert expected == genesis()
    send(client, {self(), ref, :dispatch, deadline()})
    refute_receive {:entered, _, _, _}
    kill(client, monitor)
    refute_receive {:entered, _, _, _}
  end

  test "a grant delayed past its absolute deadline never enters the facade" do
    {client, monitor} = FacadeClient.start(self(), self(), genesis(), Facade)
    ref = make_ref()
    send(client, {self(), ref, :create})
    assert_receive {^client, ^ref, :ready}, 1_000
    send(client, {self(), ref, :dispatch, System.monotonic_time() - 1})
    refute_receive {:entered, _, _, _}
    send(client, {self(), ref, :cancel})
    assert_receive {^client, ^ref, :cancelled}, 1_000
    kill(client, monitor)
  end

  test "application exceptions become a fixed private failure" do
    {client, monitor} = FacadeClient.start(self(), self(), genesis(), BlockingFacade)
    on_exit(fn -> if Process.alive?(client), do: Process.exit(client, :kill) end)
    ref = make_ref()
    send(client, {self(), ref, :create})
    assert_receive {^client, ^ref, :ready}, 1_000
    send(client, {self(), ref, :dispatch, deadline()})
    send(client, :fail)
    assert_receive {^client, ^ref, {:error, :facade_client_failed}}, 1_000
    assert_received {:blocked, ^client}
    kill(client, monitor)
  end

  test "normal owner death before a grant terminates the actual actor" do
    test = self()

    owner =
      spawn(fn ->
        {client, _monitor} = FacadeClient.start(self(), test, genesis(), Facade)
        send(test, {:client, client})
        ref = make_ref()
        send(client, {self(), ref, :create})

        receive do
          {^client, ^ref, :ready} -> :ok
        end
      end)

    assert_receive {:client, client}, 1_000
    monitor = Process.monitor(client)
    assert_receive {:DOWN, ^monitor, :process, ^client, _}, 1_000
    refute Process.alive?(owner)
    refute_receive {:entered, _, _, _}
  end

  test "normal and abnormal owner death during a call leave no retrying actor" do
    for reason <- [:normal, :kill] do
      test = self()

      owner =
        spawn(fn ->
          {client, _monitor} = FacadeClient.start(self(), test, genesis(), BlockingFacade)
          send(test, {:client, client})
          ref = make_ref()
          send(client, {self(), ref, :create})

          receive do
            {^client, ^ref, :ready} -> send(client, {self(), ref, :dispatch, deadline()})
          end

          receive do
            :stop -> :ok
          end
        end)

      on_exit(fn -> if Process.alive?(owner), do: Process.exit(owner, :kill) end)
      assert_receive {:client, client}, 1_000
      on_exit(fn -> if Process.alive?(client), do: Process.exit(client, :kill) end)
      monitor = Process.monitor(client)
      assert_receive {:blocked, ^client}, 1_000
      owner_monitor = Process.monitor(owner)
      if reason == :normal, do: send(owner, :stop), else: Process.exit(owner, reason)
      assert_receive {:DOWN, ^owner_monitor, :process, ^owner, _}, 1_000

      if reason == :normal do
        assert Process.alive?(client)
        send(client, :release)
      end

      assert_receive {:DOWN, ^monitor, :process, ^client, _}, 1_000
      refute_receive {:blocked, _}
    end
  end

  defp deadline,
    do: System.monotonic_time() + System.convert_time_unit(1_000, :millisecond, :native)

  defp kill(client, monitor) do
    Process.unlink(client)
    Process.exit(client, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^client, :killed}, 1_000
  end

  test "cancellation acknowledges the exact queued operation without facade entry" do
    {client, monitor} = FacadeClient.start(self(), self(), genesis(), Facade)
    true = :erlang.suspend_process(client)
    ref = make_ref()
    send(client, {self(), ref, :create})
    send(client, {self(), ref, :cancel})
    true = :erlang.resume_process(client)
    assert_receive {^client, ^ref, :cancelled}, 1_000
    assert_received {^client, ^ref, :ready}
    refute_receive {:entered, _, _, _}
    Process.unlink(client)
    Process.exit(client, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^client, :killed}, 1_000
  end

  defp genesis do
    Loopex.ConfiguredGenesisFixture.genesis([])
    |> Map.put("options", %{"surface" => "embedded"})
  end
end
