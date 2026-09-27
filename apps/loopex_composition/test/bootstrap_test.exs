defmodule LoopexComposition.BootstrapTest do
  use ExUnit.Case, async: true

  alias LoopexComposition.Ephemeral.Bootstrap

  @failure {:error, {:composition, :composition_application_start_failed}}

  test "success requires the real normal worker DOWN" do
    test = self()

    assert :ok =
             Bootstrap.start(fn requester, ref ->
               send(test, {:worker, self()})
               send(requester, {self(), ref, {:ok, []}, System.monotonic_time()})
             end)

    assert_receive {:worker, worker}
    refute Process.alive?(worker)
  end

  test "a matching success followed by abnormal DOWN is refused" do
    assert @failure =
             Bootstrap.start(fn requester, ref ->
               send(requester, {self(), ref, {:ok, []}, System.monotonic_time()})
               exit(:private_sentinel)
             end)
  end

  test "malformed and future completion values kill and reap the actual worker" do
    for result <- [{:ok, :malformed}, {:error, "private sentinel"}, {:ok, []}] do
      test = self()

      assert @failure =
               Bootstrap.start(fn requester, ref ->
                 send(test, {:worker, self()})

                 stamp =
                   if result == {:ok, []},
                     do:
                       System.monotonic_time() +
                         System.convert_time_unit(10_000, :millisecond, :native),
                     else: System.monotonic_time()

                 send(requester, {self(), ref, result, stamp})

                 receive do
                 after
                   1_000 -> :ok
                 end
               end)

      assert_receive {:worker, worker}
      refute Process.alive?(worker)
    end
  end

  test "requester loss cannot transfer session authority or kill a peer bootstrap" do
    test = self()

    requester =
      spawn(fn ->
        Bootstrap.start(fn requester, ref ->
          send(test, {:held_worker, self()})

          receive do
            :release -> send(requester, {self(), ref, {:ok, []}, System.monotonic_time()})
          after
            1_000 -> :ok
          end
        end)
      end)

    assert_receive {:held_worker, worker}
    worker_monitor = Process.monitor(worker)
    requester_monitor = Process.monitor(requester)
    Process.exit(requester, :kill)
    assert_receive {:DOWN, ^requester_monitor, :process, ^requester, :killed}
    assert Process.alive?(worker)

    assert :ok =
             Bootstrap.start(fn requester, ref ->
               send(requester, {self(), ref, {:ok, []}, System.monotonic_time()})
             end)

    send(worker, :release)
    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, :normal}
  end

  test "an in-time success without worker completion is killed at the reap bound" do
    test = self()
    before = System.monotonic_time(:millisecond)

    assert @failure =
             Bootstrap.start(fn requester, ref ->
               send(test, {:worker, self()})
               send(requester, {self(), ref, {:ok, []}, System.monotonic_time()})

               receive do
                 :never_sent -> :ok
               end
             end)

    elapsed = System.monotonic_time(:millisecond) - before
    assert elapsed >= 6_000
    assert_receive {:worker, worker}
    refute Process.alive?(worker)
  end

  test "fresh VM concurrent cold bootstrap starts only composition infrastructure" do
    assert_fresh("""
    tasks = for _ <- 1..8, do: Task.async(fn -> LoopexComposition.Ephemeral.Bootstrap.start() end)
    true = Enum.all?(tasks, &(Task.await(&1, 7_000) == :ok))
    supervisor = Process.whereis(LoopexComposition.Supervisor)
    owners = Process.whereis(LoopexComposition.Ephemeral.OwnerSupervisor)
    true = is_pid(supervisor) and is_pid(owners)
    {:ok, peer} = DynamicSupervisor.start_child(owners,
      %{id: :peer, start: {Agent, :start_link, [fn -> :peer end]}, restart: :temporary})
    for _ <- 1..5 do
      starter = Process.whereis(LoopexComposition.ReqLLMStarter)
      monitor = Process.monitor(starter)
      Process.exit(starter, :kill)
      receive do {:DOWN, ^monitor, :process, ^starter, :killed} -> :ok end
      nil = Process.whereis(LoopexComposition.ReqLLMStarter)
      true = Process.alive?(supervisor) and Process.alive?(owners) and Process.alive?(peer)
      {:ok, _} = Supervisor.start_child(supervisor, {LoopexComposition.ReqLLMStarter, []})
    end
    started = Application.started_applications() |> Enum.map(&elem(&1, 0))
    false = Enum.any?([:req_llm, :req, :finch], &(&1 in started))
    IO.puts("bootstrap-proof:ok")
    """)
  end

  test "stalled real controller returns at the decision bound and later startup is safe" do
    assert_fresh("""
    controller = Process.whereis(:application_controller)
    true = :erlang.suspend_process(controller)
    before = System.monotonic_time(:millisecond)
    #{inspect(@failure)} = LoopexComposition.Ephemeral.Bootstrap.start()
    elapsed = System.monotonic_time(:millisecond) - before
    true = elapsed >= 5_000 and elapsed < 6_000
    true = :erlang.resume_process(controller)
    :ok = LoopexComposition.Ephemeral.Bootstrap.start()
    false = Enum.any?(Application.started_applications(), &(elem(&1, 0) in [:req_llm, :req, :finch]))
    IO.puts("bootstrap-proof:ok")
    """)
  end

  defp assert_fresh(code) do
    paths = :code.get_path() |> Enum.flat_map(fn path -> ["-pa", List.to_string(path)] end)

    {output, status} =
      System.cmd(
        System.find_executable("elixir"),
        ["--erl", "+S 2:2"] ++ paths ++ ["-e", code],
        stderr_to_stdout: true
      )

    assert status == 0, output
    assert output =~ "bootstrap-proof:ok"
  end
end
