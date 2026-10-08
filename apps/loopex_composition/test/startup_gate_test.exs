defmodule LoopexComposition.StartupGateTest do
  use ExUnit.Case, async: true

  alias Loopex.Runtime
  alias LoopexComposition.StartupGate
  alias LoopexComposition.Ephemeral.RuntimeHolder

  test "the first identity and cutoff are retained through polling" do
    cutoff = System.monotonic_time(:millisecond) + 1_000
    test = self()
    reads = :atomics.new(1, [])

    read = fn _runtime, timeout ->
      index = :atomics.add_get(reads, 1, 1)
      send(test, {:read, index, timeout})
      status(if(index == 1, do: :starting, else: :ready), cutoff)
    end

    observer = StartupGate.start(:fixture, nil, read)
    assert_receive {:read, 1, 1_000}
    assert_receive {:read, 2, timeout}
    assert timeout in 1..1_000
    assert_receive {tag, {:ok, retained}} when tag == observer.tag
    assert retained == System.convert_time_unit(cutoff, :millisecond, :native)
    assert :ok = StartupGate.cancel(observer)
  end

  for changed <- [:identity, :cutoff] do
    test "a changed #{changed} refuses the acquisition" do
      changed = unquote(changed)
      cutoff = System.monotonic_time(:millisecond) + 1_000
      reads = :atomics.new(1, [])

      read = fn _runtime, _timeout ->
        if :atomics.add_get(reads, 1, 1) == 1 do
          status(:starting, cutoff)
        else
          case changed do
            :identity -> status(:ready, cutoff, <<1::256>>)
            :cutoff -> status(:ready, cutoff + 1)
          end
        end
      end

      observer = StartupGate.start(:fixture, nil, read)
      assert_receive {tag, {:error, :runtime_unavailable}} when tag == observer.tag
      assert :ok = StartupGate.cancel(observer)
    end
  end

  test "initial ready past its cutoff cannot publish" do
    cutoff = System.monotonic_time(:millisecond) - 1
    observer = StartupGate.start(:fixture, nil, fn _, _ -> status(:ready, cutoff) end)
    assert_receive {tag, {:error, :startup_deadline_expired}} when tag == observer.tag
    assert :ok = StartupGate.cancel(observer)
  end

  test "polled ready after the original cutoff cannot publish" do
    cutoff = System.monotonic_time(:millisecond) + 40
    reads = :atomics.new(1, [])

    observer =
      StartupGate.start(:fixture, nil, fn _, _ ->
        if :atomics.add_get(reads, 1, 1) == 1 do
          status(:starting, cutoff)
        else
          Process.sleep(50)
          status(:ready, cutoff)
        end
      end)

    assert_receive {tag, {:error, :startup_deadline_expired}} when tag == observer.tag
    assert :ok = StartupGate.cancel(observer)
  end

  test "the first read spends a shorter native caller cutoff without rounding extension" do
    test = self()
    cutoff = System.monotonic_time(:millisecond) + 1_000
    deadline = System.monotonic_time() + native(80)

    observer =
      StartupGate.start(:fixture, deadline, fn _, timeout ->
        send(test, {:timeout, timeout})
        status(:ready, cutoff)
      end)

    assert_receive {:timeout, timeout}
    assert timeout in 1..80
    assert_receive {tag, {:ok, ^deadline}} when tag == observer.tag
    assert :ok = StartupGate.cancel(observer)

    earlier_core = System.monotonic_time(:millisecond) + 50
    observer = StartupGate.start(:fixture, deadline, fn _, _ -> status(:ready, earlier_core) end)
    expected = System.convert_time_unit(earlier_core, :millisecond, :native)
    assert_receive {tag, {:ok, ^expected}} when tag == observer.tag
    assert :ok = StartupGate.cancel(observer)
  end

  test "read failure and unavailable are failed observations" do
    for result <- [{:error, :runtime_unavailable}, status(:unavailable, now_ms() + 1_000)] do
      observer = StartupGate.start(:fixture, nil, fn _, _ -> result end)
      assert_receive {tag, {:error, :runtime_unavailable}} when tag == observer.tag
      assert :ok = StartupGate.cancel(observer)
    end
  end

  test "the holder owns and monitors its runtime while its first read is held" do
    test = self()
    cutoff = now_ms() + 1_000

    {holder, ref} =
      holder(self(), self(), fn runtime, _timeout ->
        send(test, {:read_held, self(), runtime})
        receive do: (:release -> status(:ready, cutoff))
      end)

    assert_receive {:read_held, observer, runtime}
    state = :sys.get_state(holder)
    assert state.phase == :observing
    assert state.runtime == runtime
    assert is_reference(state.runtime_monitor)
    assert state.observer.pid == observer
    refute_receive {:phase_result, ^holder, ^ref, :runtime, _}, 30
    send(observer, :release)
    assert_receive {:phase_result, ^holder, ^ref, :runtime, {:ok, ^runtime}}
    refute Process.alive?(observer)
    GenServer.stop(holder)
    refute Process.alive?(runtime.supervisor)
  end

  for lost <- [:owner, :root, :runtime] do
    test "#{lost} loss interrupts a held first read and joins the original observer" do
      lost = unquote(lost)
      test = self()
      dependency = spawn(fn -> dependency(test) end)
      on_exit(fn -> if Process.alive?(dependency), do: Process.exit(dependency, :kill) end)
      owner = if lost == :owner, do: dependency, else: self()
      root = if lost == :root, do: dependency, else: self()

      {holder, _ref} =
        holder(owner, root, fn runtime, _timeout ->
          send(test, {:read_held, self(), runtime})
          receive do: (:never -> status(:ready, now_ms() + 1_000))
        end)

      assert_receive {:read_held, observer, runtime}
      holder_down = Process.monitor(holder)
      observer_down = Process.monitor(observer)
      runtime_down = Process.monitor(runtime.supervisor)

      if lost == :runtime do
        send(runtime.supervisor, :finish)
      else
        send(dependency, :finish)
      end

      assert_receive {:DOWN, ^observer_down, :process, ^observer, _}, 500
      assert_receive {:DOWN, ^holder_down, :process, ^holder, _}, 500
      assert_receive {:DOWN, ^runtime_down, :process, _, _}, 500
      if Process.alive?(dependency), do: send(dependency, :finish)
    end
  end

  defp holder(owner, root, read) do
    ref = make_ref()
    deadline = System.monotonic_time() + native(1_000)

    {:ok, holder} =
      RuntimeHolder.start_link(owner, root, ref, deadline, %{
        runtime_start: fn _ ->
          supervisor = spawn_link(fn -> receive do: (:finish -> :ok) end)
          {:ok, %Runtime{supervisor: supervisor, token: make_ref()}}
        end,
        creation_startup_status: read
      })

    Process.unlink(holder)
    on_exit(fn -> if Process.alive?(holder), do: Process.exit(holder, :kill) end)
    send(holder, {root, ref, :registered})
    assert_receive {:phase_ready, ^holder, ^ref, :runtime}
    send(holder, {:grant, owner, ref, :runtime, []})
    {holder, ref}
  end

  defp status(state, cutoff, id \\ <<0::256>>),
    do: {:ok, %{state: state, startup_id: id, startup_deadline_ms: cutoff}}

  defp native(ms), do: System.convert_time_unit(ms, :millisecond, :native)
  defp now_ms, do: System.monotonic_time(:millisecond)

  defp dependency(test) do
    receive do
      :finish ->
        :ok

      message ->
        send(test, message)
        dependency(test)
    end
  end
end
