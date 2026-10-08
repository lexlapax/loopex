Code.require_file("support/m1_runtime_helper.exs", __DIR__)
Code.require_file("support/agent_loop_helper.exs", __DIR__)
Code.require_file("support/progress_test_consumer.exs", __DIR__)

defmodule Loopex.CompactionProgressTest do
  use ExUnit.Case, async: true
  import Loopex.ProgressTestConsumer

  alias Loopex.CompactionProgress
  alias Loopex.Runtime.StreamRelay

  @maximum 18_446_744_073_709_551_615

  test "both actual owner shapes preserve opaque identity bytes and cursor endpoints" do
    for kind <- ["run", "compact"], base <- [0, @maximum], size <- [1, 65_536] do
      episode = :binary.copy(<<255>>, size)
      owner = %{"kind" => kind, "id" => :binary.copy(<<0>>, size)}
      assert {:ok, item} = CompactionProgress.new(episode, owner, domain(), base)

      assert item == %{
               kind: "context.compaction_progress",
               episode_id: episode,
               owner: owner,
               stream_domain_id: domain(),
               progress_sequence: 0,
               base_event_sequence: base
             }

      assert CompactionProgress.project(item) == {:ok, item}
    end
  end

  test "missing alternate extra struct and private data refuse before projection" do
    {:ok, item} =
      CompactionProgress.new("episode", %{"kind" => "run", "id" => "owner"}, domain(), 0)

    for key <- Map.keys(item) do
      assert CompactionProgress.project(Map.delete(item, key)) == :error
      assert CompactionProgress.project(Map.put(item, key, nil)) == :error
      alternate = item |> Map.delete(key) |> Map.put(Atom.to_string(key), item[key])
      assert CompactionProgress.project(alternate) == :error
    end

    for {key, value} <- [
          kind: :context_compaction_progress,
          kind: "context.compacted",
          episode_id: "",
          episode_id: :binary.copy(<<0>>, 65_537),
          stream_domain_id: String.duplicate("A", 32),
          stream_domain_id: String.duplicate("g", 32),
          stream_domain_id: "a",
          progress_sequence: 1,
          progress_sequence: 0.0,
          base_event_sequence: -1,
          base_event_sequence: @maximum + 1,
          base_event_sequence: 0.0,
          base_event_sequence: "0"
        ] do
      assert CompactionProgress.project(Map.put(item, key, value)) == :error
    end

    for owner <- [
          %{"kind" => "other", "id" => "owner"},
          %{"kind" => "run", "id" => ""},
          %{"kind" => "run", "id" => :binary.copy(<<0>>, 65_537)},
          %{kind: "run", id: "owner"},
          %{"kind" => "run", "id" => "owner", "extra" => true},
          %{"kind" => "run", "id" => "owner", :__struct__ => URI}
        ] do
      assert CompactionProgress.project(%{item | owner: owner}) == :error
    end

    for key <- [
          :summary,
          :input,
          :attempt,
          :operation_id,
          :staged_request_digest,
          :usage,
          :provider,
          :deadline,
          :permit,
          :session_epoch,
          :credential,
          :__struct__
        ] do
      assert CompactionProgress.project(Map.put(item, key, "private")) == :error
    end
  end

  test "activity relay sends closed items without a closure and ends with its owner" do
    supervisor = start_supervised!({Task.Supervisor, []})
    observer = self()
    fixture = Loopex.AgentLoopFixture.start(script: [], tools: [], progress_sink: open_sink())
    on_exit(fn -> Loopex.AgentLoopFixture.stop(fixture) end)
    route = Loopex.ProgressTestConsumer.route(fixture)

    {:ok, item} =
      CompactionProgress.new("episode", %{"kind" => "compact", "id" => "owner"}, domain(), 0)

    {owner, owner_monitor} =
      spawn_monitor(fn ->
        {:ok, relay} = StreamRelay.open_activity(supervisor, route)
        send(observer, {:relay, relay})

        receive do
          :emit ->
            StreamRelay.emit(relay, Map.put(item, :summary, "private"))
            StreamRelay.emit(relay, item)
            receive do: (:stop -> :ok)
        end
      end)

    assert_receive {:relay, relay}, 5_000
    relay_pid = StreamRelay.pid(relay)
    relay_monitor = Process.monitor(relay_pid)
    send(owner, :emit)
    assert_progress({:loopex_progress, ^item}, 5_000)
    assert Task.Supervisor.children(supervisor) == [StreamRelay.pid(relay)]
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^owner_monitor, :process, ^owner, :killed}, 5_000
    assert_receive {:DOWN, ^relay_monitor, :process, ^relay_pid, :killed}, 5_000
    assert Task.Supervisor.children(supervisor) == []
    StreamRelay.emit(relay, item)
    refute_progress({:loopex_progress, _}, 0)
  end

  test "normal owner termination also joins its activity relay without a closure" do
    supervisor = start_supervised!({Task.Supervisor, []})
    observer = self()
    fixture = Loopex.AgentLoopFixture.start(script: [], tools: [], progress_sink: open_sink())
    on_exit(fn -> Loopex.AgentLoopFixture.stop(fixture) end)
    route = Loopex.ProgressTestConsumer.route(fixture)

    {owner, owner_monitor} =
      spawn_monitor(fn ->
        {:ok, relay} = StreamRelay.open_activity(supervisor, route)
        send(observer, {:relay, relay})
        receive do: (:stop -> :ok)
      end)

    assert_receive {:relay, relay}, 5_000
    relay_pid = StreamRelay.pid(relay)
    relay_monitor = Process.monitor(relay_pid)
    send(owner, :stop)
    assert_receive {:DOWN, ^owner_monitor, :process, ^owner, :normal}, 5_000
    assert_receive {:DOWN, ^relay_monitor, :process, ^relay_pid, :normal}, 5_000
    assert Task.Supervisor.children(supervisor) == []
    refute_progress({:loopex_progress, _}, 0)
  end

  test "normal owner death prevents a suspended relay draining its earlier queued activity" do
    supervisor = start_supervised!({Task.Supervisor, []})
    observer = self()
    fixture = Loopex.AgentLoopFixture.start(script: [], tools: [], progress_sink: open_sink())
    on_exit(fn -> Loopex.AgentLoopFixture.stop(fixture) end)
    route = Loopex.ProgressTestConsumer.route(fixture)

    {:ok, item} =
      CompactionProgress.new("episode", %{"kind" => "run", "id" => "owner"}, domain(), 0)

    {owner, owner_monitor} =
      spawn_monitor(fn ->
        {:ok, relay} = StreamRelay.open_activity(supervisor, route)
        send(observer, {:relay, relay})

        receive do
          :queue_and_stop ->
            StreamRelay.emit(relay, item)
            :ok
        end
      end)

    assert_receive {:relay, relay}, 5_000
    true = :erlang.suspend_process(StreamRelay.pid(relay))
    relay_pid = StreamRelay.pid(relay)
    relay_monitor = Process.monitor(relay_pid)
    send(owner, :queue_and_stop)
    assert_receive {:DOWN, ^owner_monitor, :process, ^owner, :normal}, 5_000
    assert {:messages, messages} = Process.info(StreamRelay.pid(relay), :messages)
    refute Enum.any?(messages, &match?({:emit, _payload}, &1))
    assert Loopex.ProgressSink.references(StreamRelay.sink(relay), relay_pid, :relay_ready) != []
    true = :erlang.resume_process(StreamRelay.pid(relay))
    assert_receive {:DOWN, ^relay_monitor, :process, ^relay_pid, :normal}, 5_000
    assert Task.Supervisor.children(supervisor) == []
    refute_progress({:loopex_progress, _}, 0)
  end

  defp domain, do: String.duplicate("a", 32)
end
