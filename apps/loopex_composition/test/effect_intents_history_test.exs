Code.require_file("../../loopex/test/support/agent_loop_adapters.exs", __DIR__)

defmodule LoopexComposition.EffectIntentsHistoryTest do
  use ExUnit.Case, async: false

  alias Loopex.AgentLoopTestModel
  alias Loopex.AgentLoopTestExecutor
  alias Loopex.AgentLoopTestPolicy
  alias Loopex.Runtime
  alias Loopex.Store
  alias Loopex.Store.Local
  alias Loopex.Store.Memory

  for adapter <- [Memory, Local] do
    @adapter adapter

    test "#{inspect(adapter)} retains captured effect coverage through appends and runtime replacement" do
      root =
        Path.join(
          System.tmp_dir!(),
          "loopex-m7-effects-#{Base.encode16(:crypto.strong_rand_bytes(12))}"
        )

      File.mkdir_p!(root)
      on_exit(fn -> File.rm_rf!(root) end)
      previous = Map.new(~w(LOOPEX_HOME LOOPEX_WORKSPACE), &{&1, System.get_env(&1)})

      for {name, directory} <- [{"LOOPEX_HOME", "home"}, {"LOOPEX_WORKSPACE", "workspace"}] do
        isolated = Path.join(root, directory)
        File.mkdir_p!(isolated)
        System.put_env(name, isolated)
      end

      on_exit(fn ->
        Enum.each(previous, fn
          {name, nil} -> System.delete_env(name)
          {name, value} -> System.put_env(name, value)
        end)
      end)

      path = Path.join(root, "history.log")
      options = if @adapter == Local, do: [path: path], else: []
      {:ok, first_store} = @adapter.start_link(options)
      on_exit(fn -> stop_store(first_store) end)

      fixture = fixture(@adapter, first_store, root)

      on_exit(fn -> stop_runtime(fixture.runtime) end)
      assert {:ok, session} = Loopex.create_session(fixture.runtime, %{}, command_id: "create-1")
      assert {:ok, attachment} = Loopex.attach(fixture.runtime, session, after_event_sequence: 0)

      assert {:accepted, "prompt-1"} =
               Loopex.command(attachment, %{
                 type: :prompt,
                 command_id: "prompt-1",
                 content: "implement"
               })

      await_finished(attachment, System.monotonic_time(:millisecond) + 5_000)
      [job] = AgentLoopTestExecutor.jobs(fixture.executor)
      {:ok, source} = Store.new(@adapter, first_store)
      {:ok, original} = Store.load_records(source, session, 0, 1_000)
      assert {:ok, first} = Runtime.effect_intents(fixture.runtime, session, nil, 3)
      assert first.through_version == List.last(original).journal_version

      assert {:accepted, "prompt-2"} =
               Loopex.command(attachment, %{
                 type: :prompt,
                 command_id: "prompt-2",
                 content: "continue"
               })

      await_finished(attachment, System.monotonic_time(:millisecond) + 5_000)
      captured = pages(fixture.runtime, session, first.next_cursor, 3, [])
      assert List.last(captured).scanned_through == first.through_version
      assert Enum.all?(captured, &(&1.through_version == first.through_version))
      :ok = Loopex.stop(fixture.runtime)

      store =
        if @adapter == Local do
          :ok = GenServer.stop(first_store)
          {:ok, reopened} = Local.start_link(path: path)
          on_exit(fn -> stop_store(reopened) end)
          reopened
        else
          first_store
        end

      {:ok, port} = Store.new(@adapter, store)

      {:ok, successor} =
        Loopex.start_link(
          runtime_id: "agent-loop-runtime",
          context_token_budget: 8_192,
          store: port
        )

      on_exit(fn -> stop_runtime(successor) end)
      {:ok, %{sessions: supervisor}} = Runtime.children(successor)
      assert DynamicSupervisor.which_children(supervisor) == []
      before = if @adapter == Local, do: File.read!(path), else: :sys.get_state(store)
      all = pages(successor, session, nil, 16, [])
      assert List.last(all).scanned_through > first.through_version

      assert [
               %{kind: "intent", job: projected},
               %{
                 kind: "terminal",
                 disposition: "receipt_committed",
                 run_id: run,
                 tool_call_id: "call-1"
               }
             ] = Enum.flat_map(all, & &1.rows)

      assert projected == Map.from_struct(job)
      assert run == job.run_id

      resume = %{
        version: 1,
        runtime_id: "agent-loop-runtime",
        session_id: session,
        resume_after_version: first.scanned_through,
        prefix_token: first.prefix_token
      }

      assert {:ok, resumed} = Runtime.effect_intents(successor, session, resume, 16)
      assert resumed.through_version == List.last(all).through_version
      assert resumed.scanned_through > first.scanned_through
      assert {:error, :session_absent} = Runtime.effect_intents(successor, "missing", nil, 16)
      assert DynamicSupervisor.which_children(supervisor) == []
      assert AgentLoopTestExecutor.jobs(fixture.executor) == [job]
      assert before == if(@adapter == Local, do: File.read!(path), else: :sys.get_state(store))
    end
  end

  defp fixture(adapter, store, root) do
    definition = %{
      "tool_id" => "example.write",
      "tool_version" => "1.0.0",
      "name" => "write",
      "description" => "Write a file beneath the workspace root.",
      "parameter_schema" => %{
        "type" => "object",
        "properties" => %{"path" => %{"type" => "string"}},
        "required" => ["path"]
      },
      "result_shape" => %{"content_type" => "text", "description" => "What was written."},
      "effect_class" => "workspace_write",
      "idempotency_class" => "reconcile_then_retry",
      "budgets" => %{
        "wall_time_ms" => 30_000,
        "output_bytes" => 65_536,
        "artifact_bytes" => 1_048_576
      }
    }

    model =
      AgentLoopTestModel.start([
        %{text: "write", calls: [%{id: "call-1", name: "write", arguments: %{"path" => "a"}}]},
        %{text: "done", calls: []}
      ])

    executor = AgentLoopTestExecutor.start()
    {:ok, port} = Store.new(adapter, store)

    {:ok, runtime} =
      Loopex.start_link(
        runtime_id: "agent-loop-runtime",
        context_token_budget: 8_192,
        store: port,
        model: %{
          module: AgentLoopTestModel,
          model: "scripted:v1",
          options: [script: model, max_tokens: 256]
        },
        executor: %{
          module: AgentLoopTestExecutor,
          reference: executor,
          identity: "history-executor",
          epoch: 1,
          fencing_token: 1,
          workspace_ref: Path.join(root, "workspace"),
          workspace_lease: "workspace-lease"
        },
        bounds: %{max_turns: 8, token_budget: 1_000_000, deadline_ms: 600_000},
        tool: nil,
        tools: [definition],
        active_tools: [definition["tool_id"]],
        policy: AgentLoopTestPolicy,
        policy_identity: %{"id" => "loopex.test.history_policy", "revision" => "1"},
        grant_decision: {:host_policy, :allow}
      )

    %{runtime: runtime, executor: executor}
  end

  defp pages(runtime, session, cursor, limit, reversed) do
    assert {:ok, page} = Runtime.effect_intents(runtime, session, cursor, limit)

    if page.next_cursor,
      do: pages(runtime, session, page.next_cursor, limit, [page | reversed]),
      else: Enum.reverse([page | reversed])
  end

  defp await_finished(attachment, deadline) do
    case Loopex.next_event(attachment) do
      {:ok, %{kind: "run.finished"}} ->
        :ok

      observation ->
        assert System.monotonic_time(:millisecond) < deadline,
               "run did not finish: #{inspect(observation)}"

        unless match?({:ok, %{}}, observation), do: Process.sleep(10)
        await_finished(attachment, deadline)
    end
  end

  defp stop_runtime(runtime) do
    Loopex.stop(runtime)
  catch
    :exit, _ -> :ok
  end

  defp stop_store(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid)
  catch
    :exit, _ -> :ok
  end
end
