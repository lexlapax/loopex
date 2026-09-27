defmodule LoopexComposition.Ephemeral.ModelCensusTest do
  @moduledoc false
  use ExUnit.Case, async: true
  alias LoopexComposition.Ephemeral.ModelCensus
  alias LoopexComposition.SessionAdmission

  test "one live callback reserves the sole pending record and exact no-proxy cancellation clears it" do
    generation = make_ref()
    cell = :atomics.new(2, [])
    {owner, monitor} = census_owner(generation, cell)
    handle = SessionAdmission.handle(owner, generation, cell)
    call = make_ref()

    assert {:ok, _} = SessionAdmission.request(handle, {:begin_model, self(), call}, deadline())
    assert :atomics.get(cell, 2) == 1

    assert {:error, :session_admission_closed} =
             SessionAdmission.request(handle, {:begin_model, self(), make_ref()}, deadline())

    assert {:ok, _} =
             SessionAdmission.request(handle, {:cancel_model, call, :no_proxy}, deadline())

    assert :atomics.get(cell, 2) == 0

    assert {:error, :session_admission_closed} =
             SessionAdmission.request(handle, {:begin_model, self(), call}, deadline())

    assert {:ok, _} =
             SessionAdmission.request(handle, {:begin_model, self(), make_ref()}, deadline())

    send(owner, :stop)
    assert_receive {:DOWN, ^monitor, :process, ^owner, :normal}
  end

  test "a cached work grant cannot be replayed after the lifecycle closes" do
    for lifecycle <- [1, 2, 3] do
      generation = make_ref()
      cell = :atomics.new(2, [])
      {owner, monitor} = census_owner(generation, cell)
      operation = {:begin_model, self(), make_ref()}
      reference = make_ref()
      expiry = deadline()
      message = {:loopex_session_admission, self(), reference, generation, operation, expiry}
      send(owner, message)

      assert_receive {:loopex_session_admission_result, ^owner, ^reference, ^generation,
                      ^operation, ^expiry, {:ok, _}}

      :atomics.put(cell, 1, lifecycle)
      send(owner, message)

      assert_receive {:loopex_session_admission_result, ^owner, ^reference, ^generation,
                      ^operation, ^expiry, {:error, :session_admission_closed}}

      send(owner, :stop)
      assert_receive {:DOWN, ^monitor, :process, ^owner, :normal}
    end
  end

  test "callback loss retains no arbitrary exit value and keeps pending until proof" do
    generation = make_ref()
    cell = :atomics.new(2, [])
    {owner, monitor} = census_owner(generation, cell)
    test = self()
    canary = "request-bearing-callback-exit"

    {callback, callback_monitor} =
      spawn_monitor(fn ->
        handle = SessionAdmission.handle(owner, generation, cell)

        send(
          test,
          {:begun,
           SessionAdmission.request(handle, {:begin_model, self(), make_ref()}, deadline())}
        )

        receive do: (:exit -> exit({:private, canary}))
      end)

    assert_receive {:begun, {:ok, _}}
    send(callback, :exit)
    assert_receive {:DOWN, ^callback_monitor, :process, ^callback, {:private, ^canary}}
    await_callback_down(owner)
    send(owner, {:inspect, self()})
    assert_receive {:census_state, state}
    refute inspect(state) =~ canary
    assert :atomics.get(cell, 2) == 1
    send(owner, :stop)
    assert_receive {:DOWN, ^monitor, :process, ^owner, :normal}
  end

  test "missing callback cleanup seals only its cell after the bounded reconciliation window" do
    generation = make_ref()
    cell = :atomics.new(2, [])
    peer_cell = :atomics.new(2, [])
    {owner, monitor} = census_owner(generation, cell)
    test = self()

    {callback, callback_monitor} =
      spawn_monitor(fn ->
        handle = SessionAdmission.handle(owner, generation, cell)

        send(
          test,
          {:begun,
           SessionAdmission.request(handle, {:begin_model, self(), make_ref()}, deadline())}
        )
      end)

    assert_receive {:begun, {:ok, _}}
    assert_receive {:DOWN, ^callback_monitor, :process, ^callback, :normal}
    await_callback_down(owner)
    assert :atomics.get(cell, 1) == 0
    assert :atomics.get(cell, 2) == 1
    await_sealed(owner, cell, deadline() + System.convert_time_unit(250, :millisecond, :native))
    assert :atomics.get(cell, 1) == 3
    assert :atomics.get(cell, 2) == 1
    assert :atomics.get(peer_cell, 1) == 0
    assert :atomics.get(peer_cell, 2) == 0
    assert Process.alive?(owner)
    send(owner, :stop)
    assert_receive {:DOWN, ^monitor, :process, ^owner, :normal}
  end

  defp await_sealed(owner, cell, expiry) do
    if :atomics.get(cell, 1) != 3 do
      assert System.monotonic_time() < expiry
      send(owner, {:inspect, self()})
      assert_receive {:census_state, _state}
      Process.sleep(1)
      await_sealed(owner, cell, expiry)
    end
  end

  defp await_callback_down(owner) do
    send(owner, {:inspect, self()})
    assert_receive {:census_state, state}

    if state.pending.callback_down == nil do
      await_callback_down(owner)
    end
  end

  defp census_owner(generation, cell) do
    {owner, monitor} =
      spawn_monitor(fn ->
        state = ModelCensus.new(generation, cell)
        census_loop(state)
      end)

    on_exit(fn -> if Process.alive?(owner), do: Process.exit(owner, :kill) end)
    {owner, monitor}
  end

  defp census_loop(state) do
    receive do
      :stop ->
        :ok

      {:inspect, requester} ->
        send(requester, {:census_state, state})
        census_loop(state)

      message ->
        census_loop(ModelCensus.handle(state, message))
    end
  end

  defp deadline,
    do: System.monotonic_time() + System.convert_time_unit(1_000, :millisecond, :native)
end
