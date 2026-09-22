defmodule LoopexDaemon.RequestLedgerTest do
  use ExUnit.Case, async: true

  alias LoopexDaemon.RequestLedger

  test "thirty-two in-flight requests get distinct sequenced origins and the next refuses" do
    incarnation = :crypto.strong_rand_bytes(16)

    {ledger, origins} =
      Enum.reduce(1..32, {RequestLedger.new(incarnation), []}, fn index, {ledger, origins} ->
        assert {:ok, origin, ledger} = RequestLedger.begin(ledger, "r#{index}", %{})
        {ledger, [origin | origins]}
      end)

    assert length(Enum.uniq(origins)) == 32
    assert Enum.all?(origins, fn {^incarnation, slot, _sequence} -> slot in 0..31 end)
    assert {:error, :capacity_exceeded} = RequestLedger.begin(ledger, "r33", %{})
    assert {:error, :duplicate_request} = RequestLedger.begin(ledger, "r1", %{})

    [{_incarnation, slot, sequence} = last | _rest] = origins
    assert {%{request_id: "r32"}, ledger} = RequestLedger.complete(ledger, last)
    assert {:ok, {_incarnation, ^slot, next}, ledger} = RequestLedger.begin(ledger, "r32", %{})
    assert next > sequence
    assert {nil, ^ledger} = RequestLedger.complete(ledger, last)
  end

  test "the first acquire or attach reserves the one session a connection serves" do
    ledger = RequestLedger.new(:crypto.strong_rand_bytes(16))
    request = {:session_acquire_control, %{session_id: "a"}}

    assert :ok = RequestLedger.admit_session(ledger, "a")
    assert {:ok, reserving} = RequestLedger.reserve(ledger, "a", "r1", request)
    assert :coalesced = RequestLedger.reserve(reserving, "a", "r1", request)

    assert {:error, :session_conflict} =
             RequestLedger.reserve(reserving, "a", "r2", request)

    assert {:error, :session_conflict} = RequestLedger.admit_session(reserving, "a")
    assert RequestLedger.clear_reservation(reserving, "r1").binding == :unbound
    assert RequestLedger.clear_reservation(reserving, "other") == reserving

    bound = RequestLedger.bind(reserving, "a", "r1")
    assert RequestLedger.bound_session(bound) == "a"
    assert {:ok, ^bound} = RequestLedger.reserve(bound, "a", "r3", request)
    assert :ok = RequestLedger.admit_session(bound, "a")
    assert {:error, :session_conflict} = RequestLedger.reserve(bound, "b", "r4", request)
    assert {:error, :session_conflict} = RequestLedger.admit_session(bound, "b")
    assert RequestLedger.clear_reservation(bound, "r1") == bound
  end
end
