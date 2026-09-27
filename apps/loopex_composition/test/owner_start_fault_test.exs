defmodule LoopexComposition.Ephemeral.OwnerStartFaultTest do
  use ExUnit.Case, async: true

  alias LoopexComposition.Ephemeral.OwnerActivation

  @failure {:error, {:composition, :ephemeral_owner_start_failed}}

  test "an admitted owner is inert until one exact begin" do
    {:ok, supervisor} = DynamicSupervisor.start_link(strategy: :one_for_one)
    assert {:ok, activation} = OwnerActivation.start(supervisor)
    owner = OwnerActivation.owner(activation)
    assert Process.alive?(owner)
    assert Process.info(owner, :trap_exit) == {:trap_exit, true}
    assert {:ok, cell} = OwnerActivation.begin(activation)
    assert :atomics.get(cell, 1) == 0
    assert :atomics.get(cell, 2) == 0
    assert @failure = OwnerActivation.begin(activation)
    assert Process.alive?(owner)
    Process.exit(supervisor, :shutdown)
  end

  test "wrong begin token has no authority" do
    {:ok, supervisor} = DynamicSupervisor.start_link(strategy: :one_for_one)

    assert {:ok, {:owner_activation, owner, creator, ref, _token, _monitor} = activation} =
             OwnerActivation.start(supervisor)

    wrong_reply = make_ref()
    send(owner, {creator, ref, :begin, make_ref(), wrong_reply})
    refute_receive {^owner, ^wrong_reply, :begun, _}, 20
    assert {:ok, _cell} = OwnerActivation.begin(activation)
    Process.exit(supervisor, :shutdown)
  end

  test "an unbegun owner expires without gaining a session root" do
    {:ok, supervisor} = DynamicSupervisor.start_link(strategy: :one_for_one)
    assert {:ok, activation} = OwnerActivation.start(supervisor)
    owner = OwnerActivation.owner(activation)
    monitor = Process.monitor(owner)
    assert_receive {:DOWN, ^monitor, :process, ^owner, :normal}, 1_200
    assert @failure = OwnerActivation.begin(activation)
    Process.exit(supervisor, :shutdown)
  end

  test "malformed provisional return kills a known candidate without stopping a peer" do
    {:ok, supervisor} = DynamicSupervisor.start_link(strategy: :one_for_one)
    test = self()

    assert @failure =
             OwnerActivation.start(supervisor, fn sup, spec ->
               {:ok, child} = DynamicSupervisor.start_child(sup, spec)
               send(test, {:candidate, child})
               :malformed
             end)

    assert_receive {:candidate, child}
    child_monitor = Process.monitor(child)
    assert_receive {:DOWN, ^child_monitor, :process, ^child, _reason}, 1_000
    assert {:ok, peer} = OwnerActivation.start(supervisor)
    assert Process.alive?(OwnerActivation.owner(peer))
    Process.exit(supervisor, :shutdown)
  end

  test "a stalled start cannot transfer begin authority to a late child" do
    {:ok, supervisor} = DynamicSupervisor.start_link(strategy: :one_for_one)
    test = self()

    assert @failure =
             OwnerActivation.start(supervisor, fn sup, spec ->
               send(test, {:held_start, self()})

               receive do
                 :release -> DynamicSupervisor.start_child(sup, spec)
               end
             end)

    assert_receive {:held_start, proxy}
    refute Process.alive?(proxy)
    assert {:ok, peer} = OwnerActivation.start(supervisor)
    assert Process.alive?(OwnerActivation.owner(peer))
    Process.exit(supervisor, :shutdown)
  end

  test "a provisional peer PID is never reaped as this call's candidate" do
    {:ok, supervisor} = DynamicSupervisor.start_link(strategy: :one_for_one)
    {:ok, peer} = OwnerActivation.start(supervisor)
    peer_owner = OwnerActivation.owner(peer)
    assert {:ok, _cell} = OwnerActivation.begin(peer)

    assert @failure =
             OwnerActivation.start(supervisor, fn _sup, _spec -> {:ok, peer_owner} end)

    assert Process.alive?(peer_owner)
    Process.exit(supervisor, :shutdown)
  end

  test "a forged direct candidate report never kills a peer owner" do
    {:ok, supervisor} = DynamicSupervisor.start_link(strategy: :one_for_one)
    {:ok, peer} = OwnerActivation.start(supervisor)
    peer_owner = OwnerActivation.owner(peer)
    assert {:ok, _cell} = OwnerActivation.begin(peer)

    assert @failure =
             OwnerActivation.start(supervisor, fn _sup, spec ->
               {_, _, [creator, _proxy, ref, _expiry]} = spec.start
               send(creator, {peer_owner, ref, :owner_candidate})
               :malformed
             end)

    assert Process.alive?(peer_owner)
    Process.exit(supervisor, :shutdown)
  end

  test "creator loss closes an unbegun owner" do
    {:ok, supervisor} = DynamicSupervisor.start_link(strategy: :one_for_one)
    test = self()

    creator =
      spawn(fn ->
        {:ok, activation} = OwnerActivation.start(supervisor)
        send(test, {:owner, OwnerActivation.owner(activation)})
        receive do: (:wait -> :ok)
      end)

    assert_receive {:owner, owner}
    monitor = Process.monitor(owner)
    Process.exit(creator, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^owner, _}
    Process.exit(supervisor, :shutdown)
  end
end
