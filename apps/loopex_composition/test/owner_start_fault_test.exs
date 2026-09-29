defmodule LoopexComposition.Ephemeral.OwnerStartFaultTest do
  use ExUnit.Case, async: false

  alias LoopexComposition.Ephemeral.{OwnerActivation, SessionOwner}

  @failure {:error, {:composition, :ephemeral_owner_start_failed}}

  test "an admitted owner is inert until one exact begin" do
    test_pid = self()

    control =
      spawn(fn ->
        receive do
          :emit -> send(test_pid, :control_reply)
        end
      end)

    assert :erlang.trace(control, true, [:send]) == 1
    send(control, :emit)
    assert_receive {:trace, ^control, :send, :control_reply, ^test_pid}
    assert_receive :control_reply

    {:ok, supervisor} = DynamicSupervisor.start_link(strategy: :one_for_one)
    assert {:ok, activation} = OwnerActivation.start(supervisor)
    owner = OwnerActivation.owner(activation)
    assert Process.alive?(owner)
    assert Process.info(owner, :trap_exit) == {:trap_exit, true}
    assert :erlang.trace(owner, true, [:send]) == 1
    assert {:ok, cell} = OwnerActivation.begin(activation)
    refute_receive {:trace, ^owner, :send, _, _}, 20
    assert :erlang.trace(owner, false, [:send]) == 1
    assert :atomics.get(cell, 1) == 0
    assert :atomics.get(cell, 2) == 0
    assert @failure = OwnerActivation.begin(activation)
    assert Process.alive?(owner)
    Process.exit(supervisor, :shutdown)
  end

  test "wrong begin token has no authority" do
    {:ok, supervisor} = DynamicSupervisor.start_link(strategy: :one_for_one)

    assert {:ok, {:owner_activation, owner, creator, ref, _token, _monitor, _expiry} = activation} =
             OwnerActivation.start(supervisor)

    wrong_reply = make_ref()
    send(owner, {creator, ref, :begin, make_ref(), wrong_reply})
    refute_receive {^owner, ^wrong_reply, :begun, _}, 20
    assert {:ok, _cell} = OwnerActivation.begin(activation)
    Process.exit(supervisor, :shutdown)
  end

  test "prepare waits for the owner's own proxy DOWN" do
    creator = self()
    ref = make_ref()
    token = make_ref()
    proxy = spawn(fn -> receive do: (:retire -> :ok) end)
    monitor = Process.monitor(proxy)

    state = %{
      creator: creator,
      ref: ref,
      proxy: proxy,
      monitors: %{proxy: monitor},
      expiry: System.monotonic_time() + System.convert_time_unit(30_000, :millisecond, :native),
      retiring: false,
      phase: :blocked,
      token: nil
    }

    # Concept: the creator's proxy DOWN does not order the owner's DOWN.
    # Technical depth: impose the valid cross-sender ordering directly so this
    # witness fails when blocked-phase prepare is discarded by the owner.
    assert {:noreply, retired} =
             SessionOwner.handle_info({proxy, ref, :proxy_retiring}, state)

    assert {:noreply, waiting} =
             SessionOwner.handle_info({creator, ref, :prepare, token}, retired)

    refute_receive {_, ^ref, :prepared}, 0
    send(proxy, :retire)
    assert_receive {:DOWN, ^monitor, :process, ^proxy, :normal}, 1_000

    assert {:noreply, %{phase: :prepared, token: ^token}} =
             SessionOwner.handle_info({:DOWN, monitor, :process, proxy, :normal}, waiting)

    assert_receive {^creator, ^ref, :prepared}, 100
  end

  test "begin retires its activation monitor before exposing the owner" do
    {:ok, supervisor} = DynamicSupervisor.start_link(strategy: :one_for_one)

    assert {:ok,
            {:owner_activation, owner, _creator, _ref, _token, activation_monitor, _expiry} =
              activation} =
             OwnerActivation.start(supervisor)

    assert {:ok, _cell} = OwnerActivation.begin(activation)
    observer = Process.monitor(owner)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^observer, :process, ^owner, :killed}, 1_000
    refute_receive {:DOWN, ^activation_monitor, :process, ^owner, _reason}, 20
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

  test "begin cannot extend the original owner activation deadline" do
    {:ok, supervisor} = DynamicSupervisor.start_link(strategy: :one_for_one)

    assert {:ok,
            {:owner_activation, _owner, _creator, _ref, _token, activation_monitor, _expiry} =
              activation} = OwnerActivation.start(supervisor)

    owner = OwnerActivation.owner(activation)
    monitor = Process.monitor(owner)
    assert :erlang.suspend_process(owner)
    Process.sleep(750)

    {result, elapsed_ms} =
      try do
        started_ms = System.monotonic_time(:millisecond)
        result = OwnerActivation.begin(activation)
        {result, System.monotonic_time(:millisecond) - started_ms}
      after
        :erlang.resume_process(owner)
      end

    assert @failure = result
    assert elapsed_ms < 850
    assert_receive {:DOWN, ^monitor, :process, ^owner, :expired_owner_start}, 1_000
    refute_receive {:DOWN, ^activation_monitor, :process, ^owner, _reason}, 20
    Process.exit(supervisor, :shutdown)
  end

  test "malformed provisional return self-fences an unmatched candidate without stopping a peer" do
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
               send(creator, {peer_owner, ref, :owner_candidate, make_ref()})
               :malformed
             end)

    assert Process.alive?(peer_owner)
    Process.exit(supervisor, :shutdown)
  end

  test "matching forged reports cannot kill a peer without owner-origin identity" do
    {:ok, supervisor} = DynamicSupervisor.start_link(strategy: :one_for_one)
    {:ok, peer} = OwnerActivation.start(supervisor)
    peer_owner = OwnerActivation.owner(peer)
    assert {:ok, _cell} = OwnerActivation.begin(peer)

    assert @failure =
             OwnerActivation.start(supervisor, fn _sup, spec ->
               {_, _, [creator, _proxy, ref, _expiry]} = spec.start
               send(creator, {peer_owner, ref, :owner_candidate, make_ref()})
               {:ok, peer_owner}
             end)

    assert Process.alive?(peer_owner)
    Process.exit(supervisor, :shutdown)
  end

  test "creator loss closes an unbegun owner" do
    {:ok, supervisor} = DynamicSupervisor.start_link(strategy: :one_for_one)
    test = self()

    # Concept: creator loss applies after owner creation, independently of activation timing.
    # Technical depth: a direct child avoids the activation handshake's one-second deadline.
    creator =
      spawn(fn ->
        ref = make_ref()
        expiry = System.monotonic_time() + System.convert_time_unit(30_000, :millisecond, :native)

        spec = %{
          id: SessionOwner,
          start: {SessionOwner, :start_link, [self(), test, ref, expiry]},
          restart: :temporary
        }

        {:ok, owner} = DynamicSupervisor.start_child(supervisor, spec)
        send(test, {:owner, owner})
        receive do: (:wait -> :ok)
      end)

    assert_receive {:owner, owner}, 5_000
    assert Process.alive?(owner)
    monitor = Process.monitor(owner)
    Process.exit(creator, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^owner, :normal}, 1_000
    Process.exit(supervisor, :shutdown)
  end
end
