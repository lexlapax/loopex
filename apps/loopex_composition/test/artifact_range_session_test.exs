Code.require_file("../../loopex/test/support/configured_genesis_helper.exs", __DIR__)

defmodule LoopexComposition.ArtifactRangeSessionTest do
  use ExUnit.Case, async: false

  alias Loopex.Runtime
  alias Loopex.Runtime.SessionState
  alias Loopex.Executor.Local, as: Executor
  alias Loopex.Executor.Local.{CodingTools, WorkspaceLease}
  alias Loopex.Store.Local, as: Store
  alias Loopex.Store.Local.{Artifacts, Transfers}
  alias LoopexProtocol.{Canonical, Frame}

  defmodule Model do
    @moduledoc false
    @behaviour Loopex.Model

    @impl true
    def complete(request, options, _progress) do
      index = Agent.get_and_update(options[:observer], &{length(&1), &1 ++ [request]})

      calls =
        if rem(index, 2) == 0 do
          prompt = Enum.find(Enum.reverse(request.messages), &(&1["role"] == "user"))
          {:ok, arguments} = Frame.decode(prompt["content"], 8_192)

          if arguments == %{"finish" => true},
            do: [],
            else: [%{id: "read-#{index}", name: "read", arguments: arguments}]
        else
          []
        end

      {:ok,
       %{
         text: "done",
         identity: %{provider: "scripted", model: request.model, endpoint: "in-process"},
         usage: %{input_tokens: 1, output_tokens: 1},
         tool_calls: calls,
         delta_count: 0,
         streamed: false,
         provider_response_id: nil,
         canonical_request_bytes: request.canonical_request_bytes,
         staged_request_digest: request.staged_request_digest
       }}
    end
  end

  defmodule Policy do
    @moduledoc false
    @behaviour Loopex.Policy
    @impl true
    def decide(_request), do: {:allow, nil}
  end

  for restart_after <- [:file, :range] do
    test "a retained range survives restart after #{restart_after} without projection changes" do
      workflow(unquote(restart_after))
    end
  end

  defp workflow(restart_after) do
    root =
      Path.join(System.tmp_dir!(), "loopex-range-session-#{System.unique_integer([:positive])}")

    workspace = Path.join(root, "workspace")
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf!(root) end)
    bytes = :binary.copy("abcdefgh", 4_096)
    File.write!(Path.join(workspace, "source.txt"), bytes)
    artifact_root = Path.join(root, "artifacts")
    transfers = start_supervised!({Transfers, root: artifact_root})
    artifacts = %{module: Artifacts, handle: %{root: artifact_root, transfers: transfers}}
    lease = start_supervised!({WorkspaceLease, id: "lease", path: workspace, fencing_token: 1})

    executor_options = [
      identity: "range-session",
      epoch: 1,
      fencing_token: 1,
      workspace_leases: %{"lease" => lease},
      ledger_root: Path.join(root, "receipts"),
      artifacts: artifacts
    ]

    executor = start_supervised!({Executor, executor_options})
    observer = start_supervised!({Agent, fn -> [] end})
    path = Path.join(root, "store.log")
    store = start_supervised!({Store, path: path})
    definition = Enum.find(CodingTools.generations(), &(&1["tool_version"] == "1.1.0"))
    runtime = runtime(store, executor, observer, [definition])

    assert {:ok, session} =
             Runtime.create_session_with_genesis(
               runtime,
               "create",
               %{},
               Loopex.ConfiguredGenesisFixture.genesis([definition])
             )

    assert {:ok, attachment} = Loopex.attach(runtime, session, after_event_sequence: 0)
    first = run(attachment, "file", %{"path" => "source.txt"})
    assert List.last(first)["outcome"] == "completed", inspect(first, limit: :infinity)
    [reference] = Enum.find(first, &(&1.kind == "tool.finished"))["artifacts"]
    assert reference["size"] == byte_size(bytes)
    use = reference["use_locator"]

    {runtime, store, attachment} =
      if restart_after == :file,
        do: restart(runtime, path, executor_options, observer, session, workspace),
        else: {runtime, store, attachment}

    arguments = %{"artifact_use" => use, "offset" => 20_000, "length" => 4_096}
    second = run(attachment, "range", arguments)
    assert List.last(second)["outcome"] == "completed"
    assert Enum.find(second, &(&1.kind == "tool.finished"))["artifacts"] == []
    [_, _, _, after_range] = Agent.get(observer, & &1)
    range_message = Enum.find(Enum.reverse(after_range.messages), &(&1["role"] == "tool"))
    assert {:ok, range} = Frame.decode(range_message["content"], 8_192)
    assert range["excerpt_source"] == "artifact_object"
    assert range["artifact"] == reference
    assert range["offset"] == 20_000
    assert range["byte_count"] == 4_096
    assert range["next_offset"] == 24_096
    assert range["content"] == binary_part(bytes, 20_000, 4_096)
    assert {:ok, encoded_message} = Frame.encode(range_message)
    assert IO.iodata_length(encoded_message) - 1 <= 8_192

    assert {:ok, records} = Store.load_records(store, session, 0, 1_000)
    [source, result] = Enum.filter(records, &(&1.payload.kind == "executor_receipt_committed"))
    [_, range_intent] = Enum.filter(records, &(&1.payload.kind == "effect_intent_committed"))
    resolved = range_intent.payload["job"]["validated_arguments"]["resolved_artifact"]
    assert resolved["reference"] == reference
    assert resolved["source"]["record_digest"] == Canonical.digest(source.payload)
    assert resolved["source"]["journal_version"] == source.journal_version
    assert result.payload["receipt"]["output"] == range_message["content"]

    {runtime, store, attachment} =
      if restart_after == :range,
        do: restart(runtime, path, executor_options, observer, session, workspace),
        else: {runtime, store, attachment}

    third = run(attachment, "finish", %{"finish" => true})
    assert List.last(third)["outcome"] == "completed", inspect(third, limit: :infinity)
    requests = Agent.get(observer, & &1)
    assert length(requests) == 5
    assert range_message in List.last(requests).messages

    assert {:ok, records} = Store.load_records(store, session, 0, 1_000)
    assert {:ok, events} = Store.load_events(store, session, 0, 1_000)
    assert {:ok, recovered} = SessionState.recover(session, records, events)
    assert recovered.artifact_sources[use] == resolved
    assert Enum.count(records, &(&1.payload.kind == "executor_receipt_committed")) == 2
    assert :sys.get_state(transfers).jobs == %{}
    assert :ok = Loopex.stop(runtime)
  end

  defp restart(runtime, path, executor_options, observer, session, workspace) do
    assert :ok = Loopex.stop(runtime)
    assert :ok = stop_supervised(Store)
    assert :ok = stop_supervised(Executor)
    File.write!(Path.join(workspace, "source.txt"), "changed workspace")
    store = start_supervised!({Store, path: path})
    executor = start_supervised!({Executor, executor_options})
    restarted = runtime(store, executor, observer, [])
    assert {:ok, ^session} = Loopex.resume_session(restarted, session, command_id: "resume")
    assert {:ok, attachment} = Loopex.attach(restarted, session, after_event_sequence: 0)
    drain(attachment)
    {restarted, store, attachment}
  end

  defp runtime(store_pid, executor, observer, definitions) do
    {:ok, store} = Loopex.Store.new(Store, store_pid)

    {:ok, runtime} =
      Loopex.start_link(
        runtime_id: "range-session",
        store: store,
        context_token_budget: 8_192,
        model: %{
          module: Model,
          model: "scripted:v1",
          options: [observer: observer, max_tokens: 1_024]
        },
        executor: %{
          module: Executor,
          reference: executor,
          identity: "range-session",
          epoch: 1,
          fencing_token: 1,
          workspace_ref: "workspace",
          workspace_lease: "lease"
        },
        tools: definitions,
        active_tools: Enum.map(definitions, & &1["tool_id"]),
        policy: Policy,
        policy_identity: %{"id" => "range-policy", "revision" => "1"},
        grant_decision: {:host_policy, :allow}
      )

    on_exit(fn -> if Process.alive?(runtime.supervisor), do: Loopex.stop(runtime) end)
    runtime
  end

  defp run(attachment, id, arguments) do
    {:ok, json} = Frame.encode(arguments)

    assert {:accepted, ^id} =
             Loopex.command(attachment, %{
               type: :prompt,
               command_id: id,
               content: json |> IO.iodata_to_binary() |> String.trim_trailing("\n")
             })

    collect(attachment, System.monotonic_time(:millisecond) + 10_000, [])
  end

  defp collect(attachment, deadline, events) do
    assert System.monotonic_time(:millisecond) < deadline, "run did not finish"

    case Loopex.next_event(attachment) do
      {:ok, %{kind: "run.finished"} = event} ->
        Enum.reverse([event | events])

      {:ok, event} ->
        collect(attachment, deadline, [event | events])

      _ ->
        Process.sleep(10)
        collect(attachment, deadline, events)
    end
  end

  defp drain(attachment) do
    case Loopex.next_event(attachment) do
      {:ok, _} -> drain(attachment)
      _ -> :ok
    end
  end
end
