defmodule LoopexComposition.Ephemeral.ModelIntegrationTest do
  use ExUnit.Case, async: false

  alias LoopexComposition.Ephemeral

  defmodule Policy do
    @moduledoc false
    @behaviour Loopex.Policy

    @impl true
    def decide(_request), do: {:allow, nil}
  end

  defmodule DeferringPolicy do
    @moduledoc false
    @behaviour Loopex.Policy

    @impl true
    def decide(_request) do
      {:defer,
       %{
         kind: :choice,
         prompt: "May the tool list this workspace?",
         choices: [%{id: "allow", label: "Allow once"}],
         expires_in_ms: 60_000
       }}
    end
  end

  defmodule ExpiringPolicy do
    @moduledoc false
    @behaviour Loopex.Policy

    @impl true
    def decide(_request) do
      {:defer,
       %{
         kind: :choice,
         prompt: "May the tool list this workspace?",
         choices: [%{id: "allow", label: "Allow once"}],
         expires_in_ms: 1_500
       }}
    end
  end

  setup do
    # Concept: cleanup witnesses observe only this fixture's temporary roots.
    # Technical depth: distinct VMs may run supported toolchains concurrently;
    # a shared system-temp snapshot would attribute a peer VM's root to this call.
    original = System.get_env("TMPDIR")

    namespace =
      Path.join(
        System.tmp_dir!(),
        "loopex-model-fixture-#{Base.encode16(:crypto.strong_rand_bytes(12))}"
      )

    File.mkdir!(namespace)
    System.put_env("TMPDIR", namespace)

    on_exit(fn ->
      if original, do: System.put_env("TMPDIR", original), else: System.delete_env("TMPDIR")
      File.rm_rf!(namespace)
    end)

    :ok
  end

  test "a real in-process model turn retires custody before a second ask and stop" do
    root = Path.join(System.tmp_dir!(), "loopex-model-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    port = start_server(["first answer", "second answer"])

    assert {:ok, session} =
             Ephemeral.start_session(
               policy: Policy,
               model: "ollama:llama3.2",
               provider_bindings: %{"ollama" => %{"credential" => %{"none" => true}}},
               base_url: "http://127.0.0.1:#{port}/v1",
               cwd: root,
               tools: :none,
               max_tokens: 128,
               timeout: 15_000
             )

    assert {:ok, %{outcome: :completed, text: "first answer"}} =
             Ephemeral.ask(session, "first prompt")

    assert_receive {:model_request, first_request}, 15_000
    assert first_request =~ "POST /v1/chat/completions HTTP/1.1"

    # The owner-start ticket expires after one second; a running session must
    # outlive it and admit another model call.
    Process.sleep(1_100)

    assert {:ok, %{outcome: :completed, text: "second answer"}} =
             Ephemeral.ask(session, "second prompt")

    assert_receive {:model_request, second_request}, 15_000
    assert second_request =~ "POST /v1/chat/completions HTTP/1.1"
    assert :ok = Ephemeral.stop_session(session)
  end

  test "one-call embedding outlives its owner-start ticket while the model answers" do
    root = Path.join(System.tmp_dir!(), "loopex-once-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    port = start_server(["one-call answer"], 1_100)

    assert {:ok, %{outcome: :completed, text: "one-call answer"}} =
             Ephemeral.run("one prompt",
               policy: Policy,
               model: "ollama:llama3.2",
               base_url: "http://127.0.0.1:#{port}/v1",
               cwd: root,
               tools: :none,
               max_tokens: 128,
               timeout: 15_000
             )

    assert_receive {:model_request, request}, 15_000
    assert request =~ "POST /v1/chat/completions HTTP/1.1"
  end

  test "public trace startup survives real model turns and ends with session cleanup" do
    root =
      Path.join(System.tmp_dir!(), "loopex-model-trace-#{System.unique_integer([:positive])}")

    File.mkdir!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    port = start_server(["first traced answer", "second traced answer"])

    stderr =
      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        assert {:ok, session} =
                 Ephemeral.start_session(
                   policy: Policy,
                   model: "ollama:llama3.2",
                   provider_bindings: %{"ollama" => %{"credential" => %{"none" => true}}},
                   base_url: "http://127.0.0.1:#{port}/v1",
                   cwd: root,
                   tools: :none,
                   max_tokens: 128,
                   timeout: 15_000,
                   trace: %{"enabled" => true, "modules" => ["Loopex.Runtime.Control"]}
                 )

        owner = elem(session, 1)
        startup = :sys.get_state(owner).startup
        runtime = startup.registered.runtime

        assert {:ok, %{outcome: :completed, text: "first traced answer"}} =
                 Ephemeral.ask(session, "first traced prompt")

        assert_receive {:model_request, first}, 15_000
        assert first =~ "POST /v1/chat/completions HTTP/1.1"
        assert {:ok, trace} = Loopex.trace_status(runtime)
        assert trace.modules == [Loopex.Runtime.Control]

        assert {:ok, %{outcome: :completed, text: "second traced answer"}} =
                 Ephemeral.ask(session, "second traced prompt")

        assert_receive {:model_request, second}, 15_000
        assert second =~ "POST /v1/chat/completions HTTP/1.1"
        assert {:ok, _} = Loopex.trace_status(runtime)
        assert :ok = Ephemeral.stop_session(session)
        refute Process.alive?(startup.registered.diagnostics)
        refute Process.alive?(startup.registered.diagnostic_supervisor)
        refute Process.alive?(runtime.supervisor)
        refute File.exists?(startup.owned_root.path)
      end)

    assert stderr =~ "trace_call"
    assert stderr =~ "Loopex.Runtime.Control"
  end

  test "one session executes an admitted read-only tool and continues the model turn" do
    root = Path.join(System.tmp_dir!(), "loopex-tool-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    File.write!(Path.join(root, "needle.txt"), "find me")
    on_exit(fn -> File.rm_rf!(root) end)
    port = start_server([{:tool, "ls", %{"path" => "."}}, "tool complete"])

    assert {:ok, %{outcome: :completed, text: "tool complete", tools: tools}} =
             Ephemeral.run("list the workspace",
               policy: Policy,
               model: "ollama:llama3.2",
               base_url: "http://127.0.0.1:#{port}/v1",
               cwd: root,
               tools: :read_only,
               max_tokens: 128,
               timeout: 15_000
             )

    assert [%{tool_id: "loopex.ls", outcome: "completed"}] = tools
    assert_receive {:model_request, first_request}, 15_000
    assert first_request =~ "POST /v1/chat/completions HTTP/1.1"
    assert_receive {:model_request, second_request}, 15_000
    assert second_request =~ "needle.txt"
  end

  for enabled <- [false, true] do
    test "one-call embedding preserves ordinary policy deferral with questions=#{enabled}" do
      root = Path.join(System.tmp_dir!(), "loopex-deferral-#{System.unique_integer([:positive])}")
      File.mkdir!(root)
      on_exit(fn -> File.rm_rf!(root) end)
      port = start_server([{:tool, "ls", %{"path" => "."}}])
      prior_roots = ephemeral_roots()

      assert {:error, :interaction_requires_session} =
               Ephemeral.run("list the workspace",
                 policy: DeferringPolicy,
                 model: "ollama:llama3.2",
                 base_url: "http://127.0.0.1:#{port}/v1",
                 cwd: root,
                 tools: :read_only,
                 questions: unquote(enabled),
                 max_tokens: 128,
                 timeout: 15_000
               )

      assert_receive {:model_request, request}, 15_000
      assert request =~ "POST /v1/chat/completions HTTP/1.1"
      assert MapSet.difference(ephemeral_roots(), prior_roots) == MapSet.new()
    end
  end

  test "an unanswered real-core interaction expires and frees the embedded session" do
    root = Path.join(System.tmp_dir!(), "loopex-expiry-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    port = start_server([{:tool, "ls", %{"path" => "."}}, "after expiry", "second answer"])

    assert {:ok, session} =
             Ephemeral.start_session(
               policy: ExpiringPolicy,
               model: "ollama:llama3.2",
               base_url: "http://127.0.0.1:#{port}/v1",
               cwd: root,
               tools: :read_only,
               max_tokens: 128,
               timeout: 15_000
             )

    assert {:error, {:interaction_pending, question}} =
             Ephemeral.ask(session, "list the workspace")

    assert {:error, :run_open} = Ephemeral.ask(session, "too early")

    assert eventually(fn ->
             match?(
               {:ok,
                %{
                  outcome: :completed,
                  text: "after expiry",
                  tools: [%{tool_id: "loopex.ls", outcome: "denied"}]
                }},
               Ephemeral.last_result(session)
             )
           end)

    assert {:error, :invalid_interaction_answer} =
             Ephemeral.answer(session, question["interaction_id"], "allow")

    assert {:ok, %{outcome: :completed, text: "second answer"}} =
             Ephemeral.ask(session, "second prompt")

    assert :ok = Ephemeral.stop_session(session)
  end

  test "an answer queued behind expiry observation loses to core's committed expiry" do
    root =
      Path.join(System.tmp_dir!(), "loopex-expiry-race-#{System.unique_integer([:positive])}")

    File.mkdir!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    port = start_server([{:tool, "ls", %{"path" => "."}}, "after expiry", "second answer"])

    assert {:ok, session} =
             Ephemeral.start_session(
               policy: ExpiringPolicy,
               model: "ollama:llama3.2",
               base_url: "http://127.0.0.1:#{port}/v1",
               cwd: root,
               tools: :read_only,
               max_tokens: 128,
               timeout: 15_000
             )

    assert {:error, {:interaction_pending, question}} =
             Ephemeral.ask(session, "list the workspace")

    {:loopex_ephemeral_session, owner, _cell} = session
    state = :sys.get_state(owner)
    runtime = state.startup.registered.runtime
    session_id = state.startup.session_id
    true = :erlang.suspend_process(owner)

    on_exit(fn ->
      if Process.alive?(owner) and Process.info(owner, :status) == {:status, :suspended},
        do: :erlang.resume_process(owner)
    end)

    assert {:ok, attachment} = Loopex.attach(runtime, session_id, after_event_sequence: 0)

    assert eventually(
             fn ->
               match?({:ok, %{kind: "interaction.expired"}}, Loopex.next_event(attachment))
             end,
             300
           )

    request = make_ref()
    send(owner, {self(), request, :public, {:answer, question["interaction_id"], "allow"}})
    true = :erlang.resume_process(owner)
    assert_receive {^owner, ^request, {:error, :invalid_interaction_answer}}, 5_000

    assert eventually(fn ->
             match?(
               {:ok, %{outcome: :completed, text: "after expiry"}},
               Ephemeral.last_result(session)
             )
           end)

    assert {:ok, %{outcome: :completed, text: "second answer"}} =
             Ephemeral.ask(session, "second prompt")

    assert :ok = Ephemeral.stop_session(session)
  end

  test "a declared turn ceiling stops a tool run before another model call" do
    root = Path.join(System.tmp_dir!(), "loopex-turn-bound-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    port = start_server([{:tool, "ls", %{"path" => "."}}, "unexpected second call"])

    assert {:error,
            {:run, :bound_reached,
             %{
               details: %{"bound" => "max_turns", "observed" => 1, "declared_limit" => 1},
               tools: [%{tool_id: "loopex.ls", outcome: "completed"}]
             }}} =
             Ephemeral.run("list once",
               policy: Policy,
               model: "ollama:llama3.2",
               base_url: "http://127.0.0.1:#{port}/v1",
               cwd: root,
               tools: :read_only,
               max_steps: 1,
               max_tokens: 128,
               timeout: 15_000
             )

    assert_receive {:model_request, request}, 15_000
    assert request =~ "POST /v1/chat/completions HTTP/1.1"
    refute_receive {:model_request, _second}, 300
  end

  test "a failed tool call is carried into the next real model request" do
    root =
      Path.join(System.tmp_dir!(), "loopex-tool-failed-#{System.unique_integer([:positive])}")

    File.mkdir!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    port = start_server([{:tool, "ls", %{"path" => 42}}, "recovered after tool failure"])

    assert {:ok, %{outcome: :completed, text: "recovered after tool failure", tools: [tool]}} =
             Ephemeral.run("list the workspace",
               policy: Policy,
               model: "ollama:llama3.2",
               base_url: "http://127.0.0.1:#{port}/v1",
               cwd: root,
               tools: :read_only,
               max_tokens: 128,
               timeout: 15_000
             )

    assert tool.tool_id == "loopex.ls"
    assert tool.outcome == "failed"
    assert_receive {:model_request, first_request}, 15_000
    assert first_request =~ "POST /v1/chat/completions HTTP/1.1"
    assert_receive {:model_request, second_request}, 15_000
    messages = request_body(second_request)["messages"]

    assert [%{"role" => "tool", "tool_call_id" => normalized_id, "content" => content}] =
             Enum.filter(messages, &(&1["role"] == "tool"))

    assert normalized_id =~ ~r/\Alx_[0-9a-f]{48}\z/

    assert [%{"tool_calls" => [%{"id" => ^normalized_id}]}] =
             Enum.filter(messages, &(&1["role"] == "assistant"))

    assert content =~ "failed"
    assert content =~ "invalid_tool_arguments"
  end

  test "one-shot questions without a responder deny before waiting and preserve ordinary effects" do
    root =
      Path.join(System.tmp_dir!(), "loopex-no-responder-#{System.unique_integer([:positive])}")

    File.mkdir!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    port =
      start_server([
        {:tool, "ask", %{"question" => "Which encoding?"}},
        {:tool, "ls", %{"path" => "."}, "call_loopex_1"},
        {:tool, "ls", %{"path" => "."}, "call_loopex_1"},
        "continued without waiting"
      ])

    assert {:ok, %{outcome: :completed, text: "continued without waiting", tools: tools}} =
             Ephemeral.run("ask then list",
               policy: Policy,
               model: "ollama:llama3.2",
               base_url: "http://127.0.0.1:#{port}/v1",
               cwd: root,
               tools: :read_only,
               questions: true,
               max_tokens: 128,
               timeout: 15_000
             )

    assert [
             %{tool_id: "loopex.ask", outcome: "denied"},
             %{tool_id: "loopex.ls", outcome: "completed"},
             %{tool_id: "loopex.ls", outcome: "completed"}
           ] = tools

    assert_receive {:model_request, first}, 15_000
    assert Enum.any?(request_body(first)["tools"], &(&1["function"]["name"] == "ask"))
    assert_receive {:model_request, second}, 15_000
    [denied] = Enum.filter(request_body(second)["messages"], &(&1["role"] == "tool"))
    assert denied["content"] =~ "interaction_unsupported"
    assert_receive {:model_request, _third}, 15_000
    assert_receive {:model_request, _fourth}, 15_000
  end

  for {arguments, response, expected} <- [
        {%{"question" => "How should nil be encoded?"}, {:text, String.duplicate("é", 1_100)},
         String.duplicate("é", 1_100)},
        {%{"question" => "Which encoding?", "choices" => ["empty", "literal null"]},
         {:choice, "choice-2"}, "literal null"},
        {%{"question" => "How should nil be encoded?"}, :decline, "declined"}
      ] do
    test "the actual ephemeral owner carries #{inspect(response |> then(fn value -> if is_tuple(value), do: elem(value, 0), else: value end))} through Core and real HTTP" do
      root =
        Path.join(
          System.tmp_dir!(),
          "loopex-question-#{Base.encode16(:crypto.strong_rand_bytes(12))}"
        )

      File.mkdir!(root)
      on_exit(fn -> File.rm_rf!(root) end)

      port =
        start_server([
          {:tool, "ask", unquote(Macro.escape(arguments))},
          "answered",
          "next prompt survived"
        ])

      assert {:ok, session} =
               Ephemeral.start_session(
                 policy: Policy,
                 model: "ollama:llama3.2",
                 base_url: "http://127.0.0.1:#{port}/v1",
                 cwd: root,
                 tools: :read_only,
                 questions: true,
                 max_tokens: 128,
                 timeout: 15_000
               )

      {:loopex_ephemeral_session, owner, _cell} = session
      on_exit(fn -> Ephemeral.stop_session(session) end)

      assert {:error,
              {:interaction_pending, %{"producer" => "model_tool", "interaction_id" => id}}} =
               Ephemeral.ask(session, "ask about encoding")

      assert_receive {:model_request, first}, 15_000
      assert Enum.any?(request_body(first)["tools"], &(&1["function"]["name"] == "ask"))
      refute_receive {:model_request, _}, 50
      startup = :sys.get_state(owner).startup
      store = startup.registered.store_handle
      session_id = startup.session_id

      assert {:ok, %{text: "answered", outcome: :completed}} =
               Ephemeral.answer(session, id, unquote(Macro.escape(response)))

      assert_receive {:model_request, second}, 15_000
      [tool] = Enum.filter(request_body(second)["messages"], &(&1["role"] == "tool"))
      assert tool["content"] =~ unquote(expected)
      assert {:ok, records} = Loopex.Store.load_records(store, session_id, 0, 256)
      refute Enum.any?(records, &(&1.payload.kind == "effect_intent_committed_v2"))
      assert Enum.any?(records, &(&1.payload.kind == "model_question_response_admitted_v2"))
      assert {:error, :invalid_interaction_answer} = Ephemeral.answer(session, id, :decline)
      assert {:ok, %{text: "next prompt survived"}} = Ephemeral.ask(session, "next")
      assert_receive {:model_request, _}, 15_000
      assert :ok = Ephemeral.stop_session(session)
    end
  end

  for {arguments, response, expected} <- [
        {%{"question" => "How should nil be encoded?"}, {:text, String.duplicate("é", 4_096)},
         String.duplicate("é", 4_096)},
        {%{"question" => "Which encoding?", "choices" => ["empty", "literal null"]},
         {:choice, "choice-2"}, "literal null"},
        {%{"question" => "How should nil be encoded?"}, :decline, "declined"}
      ] do
    test "one-call responder joins exact #{inspect(response |> then(fn value -> if is_tuple(value), do: elem(value, 0), else: value end))} worker before completing" do
      workspace = responder_workspace()
      port = start_server([{:tool, "ask", unquote(Macro.escape(arguments))}, "answered once"])
      parent = self()

      callback = fn dto ->
        send(parent, {:callback, self(), dto})

        receive do
          :respond -> unquote(Macro.escape(response))
        end
      end

      task =
        Task.async(fn ->
          Ephemeral.run("ask once", responder_options(workspace, port, callback))
        end)

      assert_receive {:callback, worker, dto}, 15_000
      monitor = Process.monitor(worker)
      owner = responder_owner(task.pid)
      state = :sys.get_state(owner)
      owned_root = state.startup.owned_root.path
      assert state.responder.pid == worker
      assert Enum.sort(Map.keys(dto)) == ~w(choices expires_at interaction_id kind prompt)
      refute Map.has_key?(state.startup.configuration, :question_responder)
      assert state.session.active.kind == :observe
      refute owner == worker
      send(worker, :respond)
      assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 15_000
      assert {:ok, %{text: "answered once", outcome: :completed}} = Task.await(task, 15_000)
      refute File.exists?(owned_root)
      assert_receive {:model_request, _first}, 15_000
      assert_receive {:model_request, second}, 15_000
      [tool] = Enum.filter(request_body(second)["messages"], &(&1["role"] == "tool"))
      assert tool["content"] =~ unquote(expected)
    end
  end

  test "serial callbacks reuse one runtime and the original wait cutoff" do
    workspace = responder_workspace()

    port =
      start_server([
        {:tool, "ask", %{"question" => "First?"}, "question_1"},
        {:tool, "ask", %{"question" => "Second?"}, "question_2"},
        "both answered"
      ])

    parent = self()

    callback = fn dto ->
      send(parent, {:callback, self(), dto})

      receive do
        :respond -> {:text, "yes"}
      end
    end

    task =
      Task.async(fn ->
        Ephemeral.run("ask twice", responder_options(workspace, port, callback))
      end)

    assert_receive {:callback, first, first_dto}, 15_000
    owner = responder_owner(task.pid)
    initial = :sys.get_state(owner)
    generation = initial.responder.generation
    deadline = initial.responder.deadline
    runtime = initial.startup.registered.runtime
    monitor = Process.monitor(first)
    send(first, :respond)
    assert_receive {:DOWN, ^monitor, :process, ^first, :normal}, 15_000
    assert_receive {:callback, second, second_dto}, 15_000
    refute Process.alive?(first)
    refute second == first
    refute first_dto["interaction_id"] == second_dto["interaction_id"]
    current = :sys.get_state(owner)
    assert current.responder.generation == generation
    assert current.responder.deadline == deadline
    assert current.startup.registered.runtime == runtime
    assert current.responder.pid == second

    send(
      owner,
      {first, generation, initial.responder.reference, :question_response,
       {:ok, {:text, "stale"}}}
    )

    send(
      owner,
      {second, make_ref(), current.responder.reference, :question_response,
       {:ok, {:text, "wrong generation"}}}
    )

    assert :sys.get_state(owner).responder.result == nil
    monitor = Process.monitor(second)
    send(second, :respond)
    assert_receive {:DOWN, ^monitor, :process, ^second, :normal}, 15_000
    assert {:ok, %{text: "both answered"}} = Task.await(task, 15_000)
  end

  test "invalid and raised callbacks abort instead of leaving a pending question" do
    for reply <- [:invalid, :raise, :throw, :exit] do
      workspace = responder_workspace()
      port = start_server([{:tool, "ask", %{"question" => "Answer?"}}, "must not continue"])
      parent = self()

      callback = fn _dto ->
        send(parent, {:callback, self()})

        receive do
          :respond -> :ok
        end

        case reply do
          :invalid -> self()
          :raise -> raise "private callback detail"
          :throw -> throw("private callback detail")
          :exit -> exit("private callback detail")
        end
      end

      task =
        Task.async(fn -> Ephemeral.run("ask", responder_options(workspace, port, callback)) end)

      assert_receive {:callback, worker}, 15_000
      monitor = Process.monitor(worker)
      owner = responder_owner(task.pid)
      owned_root = :sys.get_state(owner).startup.owned_root.path
      send(worker, :respond)
      assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 15_000
      assert {:error, :responder_failed} = Task.await(task, 15_000)
      refute File.exists?(owned_root)
      assert_receive {:model_request, _}, 15_000
      refute_receive {:model_request, _}, 50
    end
  end

  test "blocked callback is killed at the captured call cutoff and joined before cleanup" do
    workspace = responder_workspace()
    port = start_server([{:tool, "ask", %{"question" => "Wait forever?"}}])
    parent = self()

    callback = fn _dto ->
      send(parent, {:callback, self()})

      receive do
        :never -> {:text, "late"}
      end
    end

    task =
      Task.async(fn ->
        Ephemeral.run(
          "ask",
          Keyword.put(responder_options(workspace, port, callback), :timeout, 1_500)
        )
      end)

    assert_receive {:callback, worker}, 15_000
    monitor = Process.monitor(worker)
    owner = responder_owner(task.pid)
    state = :sys.get_state(owner)
    owned_root = state.startup.owned_root.path
    # A forged DOWN must not release a worker that is still alive.
    send(owner, {:DOWN, state.responder.monitor, :process, worker, :normal})
    :sys.get_state(owner)
    assert Process.alive?(worker)
    assert :sys.get_state(owner).responder.pid == worker
    assert_receive {:DOWN, ^monitor, :process, ^worker, :killed}, 15_000
    assert {:error, {:timeout, _snapshot}} = Task.await(task, 15_000)
    refute File.exists?(owned_root)
  end

  test "callback result cannot replace Core's run expiry" do
    workspace = responder_workspace()
    port = start_server([{:tool, "ask", %{"question" => "Wait?"}}, "must not continue"])
    parent = self()

    callback = fn _dto ->
      send(parent, {:callback, self()})

      receive do
        :never -> {:text, "late"}
      end
    end

    task =
      Task.async(fn ->
        Ephemeral.run(
          "ask",
          Keyword.put(responder_options(workspace, port, callback), :deadline_ms, 1_500)
        )
      end)

    assert_receive {:callback, worker}, 15_000
    monitor = Process.monitor(worker)
    owner = responder_owner(task.pid)
    state = :sys.get_state(owner)

    assert state.responder.deadline <
             System.monotonic_time() +
               System.convert_time_unit(2_000, :millisecond, :native)

    assert_receive {:DOWN, ^monitor, :process, ^worker, :killed}, 15_000
    assert {:error, {:run, :bound_reached, _}} = Task.await(task, 15_000)
    refute File.exists?(state.startup.owned_root.path)
    assert_receive {:model_request, _}, 15_000
    refute_receive {:model_request, _}, 50
  end

  test "caller death kills and joins the responder and its owning tree" do
    workspace = responder_workspace()
    port = start_server([{:tool, "ask", %{"question" => "Wait?"}}])
    parent = self()

    callback = fn _dto ->
      send(parent, {:callback, self()})

      receive do
        :never -> {:text, "late"}
      end
    end

    {caller, caller_monitor} =
      spawn_monitor(fn ->
        Ephemeral.run("ask", responder_options(workspace, port, callback))
      end)

    assert_receive {:callback, worker}, 15_000
    monitor = Process.monitor(worker)
    owner = responder_owner(caller)
    owner_monitor = Process.monitor(owner)
    state = :sys.get_state(owner)
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^caller_monitor, :process, ^caller, :killed}, 15_000
    assert_receive {:DOWN, ^monitor, :process, ^worker, :killed}, 15_000
    assert_receive {:DOWN, ^owner_monitor, :process, ^owner, :normal}, 15_000
    refute File.exists?(state.startup.owned_root.path)
    refute Enum.any?(Map.keys(state.startup.process_monitors), &Process.alive?/1)
  end

  test "responder failure yields cleanup uncertainty when root removal is unproved" do
    workspace = responder_workspace()
    port = start_server([{:tool, "ask", %{"question" => "Answer?"}}])
    parent = self()

    callback = fn _dto ->
      send(parent, {:callback, self()})

      receive do
        :respond -> :invalid
      end
    end

    task =
      Task.async(fn -> Ephemeral.run("ask", responder_options(workspace, port, callback)) end)

    assert_receive {:callback, worker}, 15_000
    monitor = Process.monitor(worker)
    owner = responder_owner(task.pid)
    state = :sys.get_state(owner)
    owned = state.startup.owned_root.path
    on_exit(fn -> File.rm_rf!(owned) end)

    :sys.replace_state(owner, fn current ->
      root = current.startup.owned_root

      put_in(current, [:startup, :owned_root], %{
        root
        | identity: %{root.identity | inode: root.identity.inode + 1}
      })
    end)

    send(worker, :respond)
    assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 15_000

    assert {:error, {:cleanup_unproved, %{pending: [:root_removal], root: ^owned}}} =
             Task.await(task, 15_000)

    assert File.exists?(owned)
    refute Process.alive?(worker)
  end

  for trigger <- [:deadline, :late_down] do
    test "a missed exact join cutoff through #{trigger} retains uncertainty after ordinary cleanup" do
      workspace = responder_workspace()
      port = start_server([{:tool, "ask", %{"question" => "Wait?"}}])
      parent = self()

      callback = fn _dto ->
        send(parent, {:callback, self()})

        receive do
          :respond -> {:text, "late"}
        end
      end

      task =
        Task.async(fn -> Ephemeral.run("ask", responder_options(workspace, port, callback)) end)

      assert_receive {:callback, worker}, 15_000
      monitor = Process.monitor(worker)
      owner = responder_owner(task.pid)
      state = :sys.get_state(owner)
      # Fault injection proves the cutoff disposition with a genuinely live
      # registered worker. Normal and killed joins have separate witnesses.
      :sys.replace_state(owner, fn current ->
        put_in(current.responder.join_deadline, System.monotonic_time() - 1)
      end)

      reason =
        case unquote(trigger) do
          :deadline ->
            send(
              owner,
              {:question_responder_join_deadline, state.responder.generation,
               state.responder.reference}
            )

            :killed

          :late_down ->
            send(worker, :respond)
            :normal
        end

      assert_receive {:DOWN, ^monitor, :process, ^worker, ^reason}, 15_000

      assert {:error, {:cleanup_unproved, %{pending: [:session_subtree]}}} =
               Task.await(task, 15_000)

      refute File.exists?(state.startup.owned_root.path)
    end
  end

  test "policy-defer interactions never invoke the model-question responder" do
    workspace = responder_workspace()
    port = start_server([{:tool, "ls", %{"path" => "."}}])
    parent = self()

    callback = fn _dto ->
      send(parent, :unexpected_callback)
      :decline
    end

    options =
      responder_options(workspace, port, callback) |> Keyword.put(:policy, DeferringPolicy)

    assert {:error, :interaction_requires_session} = Ephemeral.run("list", options)
    refute_receive :unexpected_callback, 50
  end

  defp responder_workspace do
    root =
      Path.join(
        System.tmp_dir!(),
        "loopex-responder-#{Base.encode16(:crypto.strong_rand_bytes(12))}"
      )

    File.mkdir!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    root
  end

  defp responder_options(root, port, callback) do
    [
      policy: Policy,
      model: "ollama:llama3.2",
      base_url: "http://127.0.0.1:#{port}/v1",
      cwd: root,
      tools: :read_only,
      questions: true,
      question_responder: callback,
      provider_bindings: %{"ollama" => %{"credential" => %{"none" => true}}},
      max_tokens: 128,
      timeout: 15_000
    ]
  end

  defp responder_owner(creator) do
    DynamicSupervisor.which_children(LoopexComposition.Ephemeral.OwnerSupervisor)
    |> Enum.find_value(fn {_id, pid, _type, _modules} ->
      if :sys.get_state(pid).creator == creator, do: pid
    end)
    |> then(fn owner ->
      assert is_pid(owner)
      owner
    end)
  end

  defp ephemeral_roots do
    System.tmp_dir!()
    |> Path.join("loopex-*")
    |> Path.wildcard()
    |> Enum.filter(&(Path.basename(&1) =~ ~r/\Aloopex-[0-9a-f]{64}\z/))
    |> MapSet.new()
  end

  defp request_body(request) do
    [_headers, body] = :binary.split(request, "\r\n\r\n")
    JSON.decode!(body)
  end

  test "a tool reply arriving after stop starts no effect and leaves a peer session usable" do
    root =
      Path.join(System.tmp_dir!(), "loopex-stopped-tool-#{System.unique_integer([:positive])}")

    File.mkdir!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    {port, server} =
      start_held_server({:tool, "write", %{"path" => "late.txt", "content" => "late"}})

    assert {:ok, session} =
             Ephemeral.start_session(
               policy: Policy,
               model: "ollama:llama3.2",
               base_url: "http://127.0.0.1:#{port}/v1",
               cwd: root,
               tools: :coding,
               max_tokens: 128,
               timeout: 15_000
             )

    asking = Task.async(fn -> Ephemeral.ask(session, "write late.txt") end)
    assert_receive {:held_model_request, ^server, request}, 15_000
    assert request =~ "POST /v1/chat/completions HTTP/1.1"

    assert :ok = Ephemeral.stop_session(session)
    send(server, :release)
    assert {:ok, {:error, {:run, :cancelled, _}}} = Task.yield(asking, 5_000)
    refute File.exists?(Path.join(root, "late.txt"))
    assert {:error, :session_closed} = Ephemeral.ask(session, "try again")

    peer_port = start_server(["peer answer"])

    assert {:ok, %{outcome: :completed, text: "peer answer"}} =
             Ephemeral.run("peer prompt",
               policy: Policy,
               model: "ollama:llama3.2",
               base_url: "http://127.0.0.1:#{peer_port}/v1",
               cwd: root,
               tools: :read_only,
               max_tokens: 128,
               timeout: 15_000
             )

    assert_receive {:model_request, peer_request}, 15_000
    assert peer_request =~ "peer prompt"
    refute File.exists?(Path.join(root, "late.txt"))
  end

  test "unproved root removal seals one real session without stopping its peer" do
    workspace =
      Path.join(System.tmp_dir!(), "loopex-isolated-peer-#{System.unique_integer([:positive])}")

    File.mkdir!(workspace)
    on_exit(fn -> File.rm_rf!(workspace) end)

    assert {:ok, {:loopex_ephemeral_session, owner, _cell} = session} =
             Ephemeral.start_session(
               policy: Policy,
               model: "ollama:llama3.2",
               cwd: workspace,
               tools: :coding,
               timeout: 15_000
             )

    owned = :sys.get_state(owner).startup.owned_root.path
    File.write!(Path.join(owned, "retained-marker"), "still here")
    on_exit(fn -> File.rm_rf!(owned) end)

    # Concept: uncertain cleanup must seal this session, not its peer.
    # Technical depth: invalidate only the stored removal identity. Moving the
    # live root would also move the executor ledger and test a different failure.
    :sys.replace_state(owner, fn state ->
      root = state.startup.owned_root
      invalid_identity = %{root.identity | inode: root.identity.inode + 1}
      put_in(state, [:startup, :owned_root], %{root | identity: invalid_identity})
    end)

    assert {:error,
            {:cleanup_unproved, %{pending: [:root_removal], root: ^owned, root_ownership: :owned}}} =
             Ephemeral.stop_session(session)

    assert File.read!(Path.join(owned, "retained-marker")) == "still here"
    assert {:error, :session_unavailable} = Ephemeral.ask(session, "write a file")

    peer_port = start_server(["peer survived"])

    assert {:ok, %{outcome: :completed, text: "peer survived"}} =
             Ephemeral.run("answer in the peer session",
               policy: Policy,
               model: "ollama:llama3.2",
               base_url: "http://127.0.0.1:#{peer_port}/v1",
               cwd: workspace,
               tools: :read_only,
               max_tokens: 128,
               timeout: 15_000
             )

    assert_receive {:model_request, peer_request}, 15_000
    assert peer_request =~ "answer in the peer session"
  end

  defp start_held_server(answer) do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, {_, port}} = :inet.sockname(listener)
    parent = self()

    server =
      spawn(fn ->
        with {:ok, socket} <- :gen_tcp.accept(listener, 15_000),
             {:ok, request} <- read_request(socket, <<>>) do
          send(parent, {:held_model_request, self(), request})

          receive do
            :release ->
              body = response(answer)

              :gen_tcp.send(socket, [
                "HTTP/1.1 200 OK\r\n",
                "content-type: application/json\r\n",
                "content-length: ",
                Integer.to_string(byte_size(body)),
                "\r\nconnection: close\r\n\r\n",
                body
              ])
          end

          :gen_tcp.close(socket)
        end
      end)

    on_exit(fn ->
      if Process.alive?(server), do: Process.exit(server, :kill)
      :gen_tcp.close(listener)
    end)

    {port, server}
  end

  defp start_server(answers, delay_ms \\ 0) do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, {_, port}} = :inet.sockname(listener)
    parent = self()

    server =
      spawn(fn ->
        Enum.reduce_while(answers, :ok, fn answer, :ok ->
          case :gen_tcp.accept(listener, 15_000) do
            {:ok, socket} ->
              {:ok, request} = read_request(socket, <<>>)
              send(parent, {:model_request, request})
              Process.sleep(delay_ms)
              body = response(answer)

              :ok =
                :gen_tcp.send(socket, [
                  "HTTP/1.1 200 OK\r\n",
                  "content-type: application/json\r\n",
                  "content-length: ",
                  Integer.to_string(byte_size(body)),
                  "\r\nconnection: close\r\n\r\n",
                  body
                ])

              :gen_tcp.close(socket)
              {:cont, :ok}

            {:error, :closed} ->
              {:halt, :ok}
          end
        end)
      end)

    on_exit(fn ->
      if Process.alive?(server), do: Process.exit(server, :kill)
      :gen_tcp.close(listener)
    end)

    port
  end

  defp read_request(socket, buffered) do
    case :binary.match(buffered, "\r\n\r\n") do
      {header_end, 4} ->
        header_size = header_end + 4
        <<headers::binary-size(^header_size), body::binary>> = buffered

        size =
          case Regex.run(~r/content-length:\s*(\d+)/i, headers) do
            [_, digits] -> String.to_integer(digits)
            _ -> 0
          end

        if byte_size(body) >= size do
          {:ok, buffered}
        else
          read_more(socket, buffered)
        end

      :nomatch ->
        read_more(socket, buffered)
    end
  end

  defp read_more(socket, buffered) do
    with {:ok, chunk} <- :gen_tcp.recv(socket, 0, 15_000),
         true <- byte_size(buffered) + byte_size(chunk) <= 1_048_576 do
      read_request(socket, buffered <> chunk)
    else
      other -> other
    end
  end

  defp response({:tool, name, arguments}),
    do: response({:tool, name, arguments, "call_loopex_1"})

  defp response({:tool, name, arguments, call_id}) do
    JSON.encode!(%{
      id: "chatcmpl-loopex-tool",
      object: "chat.completion",
      created: 1_800_000_000,
      model: "llama3.2",
      choices: [
        %{
          index: 0,
          message: %{
            role: "assistant",
            content: nil,
            tool_calls: [
              %{
                id: call_id,
                type: "function",
                function: %{name: name, arguments: JSON.encode!(arguments)}
              }
            ]
          },
          finish_reason: "tool_calls"
        }
      ],
      usage: %{prompt_tokens: 12, completion_tokens: 3, total_tokens: 15}
    })
  end

  defp response(answer) do
    JSON.encode!(%{
      id: "chatcmpl-loopex-fixture",
      object: "chat.completion",
      created: 1_800_000_000,
      model: "llama3.2",
      choices: [
        %{index: 0, message: %{role: "assistant", content: answer}, finish_reason: "stop"}
      ],
      usage: %{prompt_tokens: 12, completion_tokens: 3, total_tokens: 15}
    })
  end

  defp eventually(fun, attempts \\ 200)
  defp eventually(_fun, 0), do: false

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(20)
      eventually(fun, attempts - 1)
    end
  end
end
