Code.require_file("../../../loopex/test/support/m1_runtime_helper.exs", __DIR__)
Code.require_file("../../../loopex/test/support/agent_loop_helper.exs", __DIR__)

defmodule LoopexComposition.HelperDeciderModel do
  @moduledoc false
  @behaviour Loopex.Model

  # Concept: a scripted model whose reply depends on the request it is handed.
  # Technical depth: concurrent parents and children interleave requests, so a
  # shared ordered script cannot describe them; the test's decision function
  # reads the first user message and the number of assistant turns instead.
  def start(decide) when is_function(decide, 2) do
    {:ok, pid} = Agent.start_link(fn -> %{decide: decide, seen: []} end)
    pid
  end

  def dispatched(pid), do: Agent.get(pid, & &1.seen) |> Enum.reverse()

  @impl Loopex.Model
  def complete(request, options, _progress \\ nil) do
    pid = Keyword.fetch!(options, :script)
    decide = Agent.get(pid, & &1.decide)
    Agent.update(pid, &%{&1 | seen: [request | &1.seen]})
    user = Enum.find_value(request.messages, fn m -> m["role"] == "user" && m["content"] end)
    turns = Enum.count(request.messages, &(&1["role"] == "assistant"))
    turn = decide.(user, turns)

    case Map.get(turn, :hold) do
      waiter when is_pid(waiter) ->
        send(waiter, {:holding, user, self()})

        receive do
          :release -> :ok
        after
          Map.get(turn, :hold_timeout_ms, 30_000) -> :ok
        end

      nil ->
        :ok
    end

    {:ok,
     %{
       completion: "unknown",
       continuation: nil,
       text: Map.get(turn, :text, ""),
       identity: %{provider: "scripted", model: request.model, endpoint: "in-process"},
       usage: Map.get(turn, :usage, %{input_tokens: 1, output_tokens: 1}),
       tool_calls: Map.get(turn, :calls, []),
       delta_count: 0,
       streamed: false,
       provider_response_id: nil,
       canonical_request_bytes: request.canonical_request_bytes,
       staged_request_digest: request.staged_request_digest
     }}
  end
end

defmodule LoopexComposition.DelegationRuntimeFixture do
  @moduledoc false
  import ExUnit.Assertions
  import ExUnit.Callbacks

  alias Loopex.{AgentLoopFixture, AgentLoopTestModel}
  alias LoopexComposition.Delegation.{Catalog, Helper, RetainedObjects, Router, Tool}
  alias LoopexComposition.Placement

  @model "anthropic:helper-fixture"
  @providers %{"anthropic" => %{"credential" => %{"env" => "HELPER_FIXTURE_KEY"}}}

  # Concept: a durable runtime whose executor is the helper router over a
  # scripted local executor, with the shipped Local Store and a physical ledger.
  def start(script, options \\ []) do
    root =
      Path.join(
        if(File.dir?("/private/tmp"), do: "/private/tmp", else: "/tmp"),
        "loopex-helper-#{Base.encode16(:crypto.strong_rand_bytes(8))}"
      )

    File.mkdir!(root)
    {:ok, lease} = Placement.acquire(root)
    {:ok, owned} = Agent.start(fn -> [] end)

    on_exit(fn ->
      entries = Agent.get(owned, & &1)

      for {:runtime_ref, runtime, supervisor} <- entries,
          Process.alive?(supervisor),
          do: Loopex.stop(runtime)

      for {:pid, kind, pid} <- entries, kind != :runtime, Process.alive?(pid) do
        try do
          GenServer.stop(pid, :normal, 5_000)
        catch
          :exit, _ -> :ok
        end
      end

      Agent.stop(owned)

      Placement.release(lease)
      File.rm_rf!(root)
    end)

    {model_module, model} =
      if is_function(script, 2),
        do:
          {LoopexComposition.HelperDeciderModel,
           LoopexComposition.HelperDeciderModel.start(script)},
        else: {AgentLoopTestModel, AgentLoopTestModel.start(script)}

    boot(
      %{root: root, lease: lease, owned: owned, model: model, model_module: model_module},
      options
    )
  end

  # Concept: one host incarnation over the retained root and model.
  def boot(base, options) do
    {:ok, objects} =
      RetainedObjects.open(base.root, "helper-runtime", base.lease,
        recover_stale_writer: Keyword.get(options, :recover_stale_writer, false),
        checkpoint: Keyword.get(options, :checkpoint, fn _ -> :ok end)
      )

    Process.unlink(objects)

    {:ok, store_pid} =
      Loopex.Store.Local.start_link(
        path: Path.join(base.root, "core.log"),
        recover_stale_writer: Keyword.get(options, :recover_stale_writer, false)
      )

    Process.unlink(store_pid)
    {:ok, store} = Loopex.Store.new(Loopex.Store.Local, store_pid)

    {:ok, helper} =
      Helper.start_link(
        objects: objects,
        runtime_id: "helper-runtime",
        fault: Keyword.get(options, :fault, fn _ -> :ok end)
      )

    Process.unlink(helper)
    executor = Loopex.AgentLoopTestExecutor.start(Keyword.get(options, :outcomes, %{}))
    Process.unlink(executor)
    definitions = read_definitions() ++ [Tool.definition()]

    {:ok, runtime} =
      Loopex.start_link(
        runtime_id: "helper-runtime",
        store: store,
        context_token_budget: 8_192,
        session_creation_defaults:
          AgentLoopFixture.creation_defaults(read_definitions(), model: @model),
        model: %{
          module: base.model_module,
          model: @model,
          options: [script: base.model, max_tokens: 256]
        },
        executor:
          Router.wrap(
            %{
              module: Loopex.AgentLoopTestExecutor,
              reference: executor,
              identity: "helper-executor",
              epoch: 1,
              fencing_token: 1,
              workspace_ref: "workspace-ref",
              workspace_lease: "workspace-lease"
            },
            helper
          ),
        tool: nil,
        tools: definitions,
        active_tools: Enum.map(definitions, & &1["tool_id"]),
        policy: Keyword.get(options, :policy, Loopex.AgentLoopTestPolicy),
        policy_identity: %{"id" => "loopex.test.helper_policy", "revision" => "1"},
        grant_decision: {:host_policy, :allow},
        bounds: %{max_turns: 8, token_budget: 1_000_000, deadline_ms: 600_000}
      )

    Process.unlink(runtime.supervisor)

    Agent.update(
      base.owned,
      &(&1 ++
          [
            {:pid, :runtime, runtime.supervisor},
            {:runtime_ref, runtime, runtime.supervisor},
            {:pid, :helper, helper},
            {:pid, :objects, objects},
            {:pid, :store, store_pid},
            {:pid, :executor, executor}
          ])
    )

    Loopex.ConfiguredGenesisFixture.await_creation_ready(runtime)
    assert :ok = Helper.bind(helper, runtime, store)

    case Keyword.get(options, :classify, false) do
      true -> Helper.classify(helper)
      :skip -> :ok
      false -> Helper.classification(helper, :complete)
    end

    Map.merge(base, %{
      runtime: runtime,
      helper: helper,
      objects: objects,
      executor: executor,
      store: store,
      store_pid: store_pid
    })
  end

  # Concept: abrupt loss of every host process; durable bytes stay on disk.
  def crash(fixture) do
    for pid <- [
          fixture.helper,
          fixture.runtime.supervisor,
          fixture.objects,
          fixture.store_pid,
          fixture.executor
        ],
        Process.alive?(pid) do
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 5_000
    end

    :ok
  end

  def restart(fixture, options \\ []) do
    crash(fixture)
    boot(fixture, Keyword.merge([recover_stale_writer: true, classify: true], options))
  end

  def read_definitions do
    Loopex.Executor.Local.CodingTools.definitions()
    |> Enum.filter(&(&1["tool_id"] in ~w(loopex.read loopex.grep loopex.find loopex.ls)))
  end

  def configuration do
    AgentLoopFixture.creation_defaults(read_definitions(), model: @model)["initial_configuration"]
  end

  # Concept: one enabled role over the scripted model with finite limits.
  def parent(fixture, command, limits \\ %{}, role \\ nil) do
    assert {:ok, session} = Helper.create_parent(fixture.helper, capture(command, limits, role))
    session
  end

  def capture(command, limits \\ %{}, role \\ nil) do
    role = role || default_role()

    limits =
      Map.merge(
        %{
          "roles" => ["inspect"],
          "max_children" => 4,
          "token_budget" => 4_000,
          "child_bounds" => %{"max_turns" => 4, "deadline_ms" => 600_000, "token_budget" => 1_000},
          "max_tokens" => 256
        },
        limits
      )

    options = %{"tenant" => "helper"}

    {:ok, genesis} =
      Loopex.Runtime.SessionGenesis.resolve(options, %{
        genesis_version: "session_genesis_v3",
        runtime_configuration: %{"cleanup_grace_ms" => 5_000},
        initial_configuration: configuration(),
        tool_selection: selection(read_definitions() ++ [Tool.definition()]),
        policy_defer_mode: "admit"
      })

    assert {:ok, capture} =
             Catalog.capture(
               "helper-runtime",
               command,
               @providers,
               %{"inspect" => role},
               limits,
               options,
               genesis
             )

    capture
  end

  defp default_role do
    assert {:ok, role} = Catalog.role_genesis(configuration(), read_definitions(), 5_000)
    role
  end

  defp selection(definitions) do
    %{
      "definitions" => definitions,
      "names" =>
        Map.new(definitions, fn definition ->
          {id, version, digest} = LoopexProtocol.ToolDefinition.generation(definition)

          {definition["name"],
           %{"tool_id" => id, "tool_version" => version, "definition_digest" => digest}}
        end)
    }
  end

  def task_call(id, role \\ "inspect", prompt \\ "Inspect the workspace."),
    do: %{
      id: id,
      name: "task",
      arguments: %{"role" => role, "description" => "investigate", "prompt" => prompt}
    }

  def await_terminal(fixture, session, run, cutoff \\ nil) do
    cutoff = cutoff || System.monotonic_time(:millisecond) + 10_000

    case Loopex.Runtime.run_evidence(fixture.runtime, session, run) do
      {:ok, %{terminal: %{}} = evidence} ->
        evidence

      _ ->
        assert System.monotonic_time(:millisecond) < cutoff, "run did not end"
        Process.sleep(10)
        await_terminal(fixture, session, run, cutoff)
    end
  end

  def prompt(fixture, session, command_id, content) do
    {:ok, attachment} = Loopex.attach(fixture.runtime, session, after_event_sequence: 0)

    assert {:accepted, ^command_id} =
             Loopex.command(attachment, %{type: :prompt, command_id: command_id, content: content})

    {:ok, {:committed, :admitted, _code, run}} =
      Loopex.command_disposition(attachment, command_id)

    {attachment, run}
  end
end
