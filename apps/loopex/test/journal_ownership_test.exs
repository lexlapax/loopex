Code.require_file("support/durable_truth_helper.exs", __DIR__)

defmodule Loopex.JournalOwnershipTest do
  @moduledoc """
  ## Concept

  Proves that only the live owning process changes a journal, and that every way
  a non-owner reached a mutation is refused.

  ## Technical depth

  Each case is deterministic. The races these cover were originally demonstrated
  by timing -- stale-token appends landing after a takeover, a repair truncating a
  journal a new owner had claimed mid-scan -- and a timing reproduction is a bad
  regression test: it passes on a fast machine whether or not the defect is there.
  Every case here constructs the *state* the race produced and asserts the rule
  directly, so it fails on a mistake rather than on a schedule.

  Identity is three things, and each case names which one it exercises: the token
  proves knowledge, the OS pid proves the same VM (two unnamed BEAMs are both
  `nonode@nohost`, so the node name cannot), and the Erlang pid proves the same
  process, which is what makes the Coordinator the ownership boundary rather than
  the file.

  What these do NOT prove is in the module's own limitation list: nothing here
  covers multiple hosts, divergent temporary namespaces, a tampered sentinel, or
  fsync behaviour on truncation.
  """

  use ExUnit.Case, async: true

  alias Loopex.Journal
  alias LoopexTest.DurableTruth

  setup do
    Process.flag(:trap_exit, true)
    :ok
  end

  defp record(seq), do: %{kind: :fact_committed, seq: seq, fact: "f#{seq}"}

  # Runs `fun` in another process and waits for its result, so a case can present
  # a token from a process that is not the owner.
  defp elsewhere(fun) do
    parent = self()
    spawn(fn -> send(parent, {:elsewhere, fun.()}) end)

    receive do
      {:elsewhere, result} -> result
    after
      5_000 -> flunk("the other process did not answer")
    end
  end

  test "a release that lost its claim to a new owner cannot delete the new claim" do
    journal = DurableTruth.journal_path("ownership-stale-release")
    {:ok, first} = Journal.claim_session(journal)
    {:ok, lock} = Journal.session_lock_path(journal)

    # The state the race produced: the first claim is gone and a second owner
    # holds the journal, while a delayed release still carries the first token.
    assert :ok = Journal.release_session(journal, first)
    {:ok, second} = Journal.claim_session(journal)
    refute second == first
    assert File.exists?(lock)

    assert {:error, {:not_the_claim_holder, ^lock}} = Journal.release_session(journal, first)

    assert File.exists?(lock),
           "a release holding a superseded token must not delete the live claim"

    # The live owner can still release its own claim.
    assert :ok = Journal.release_session(journal, second)
    refute File.exists?(lock)
  end

  test "an append carrying a token from a replaced ownership is refused" do
    journal = DurableTruth.journal_path("ownership-append-replaced")
    {:ok, first} = Journal.claim_session(journal)
    assert :ok = Journal.append(journal, record(1), first)
    assert :ok = Journal.release_session(journal, first)

    {:ok, second} = Journal.claim_session(journal)
    before = File.stat!(journal).size

    assert {:error, {:not_the_session_owner, ^journal}} =
             Journal.append(journal, record(2), first)

    assert File.stat!(journal).size == before,
           "a refused append must not write a byte"

    assert :ok = Journal.append(journal, record(2), second)
    assert {:ok, records, :complete} = Journal.read(journal)
    assert length(records) == 2
  end

  test "a repair carrying a token from a replaced ownership does not truncate" do
    journal = DurableTruth.journal_path("ownership-repair-replaced")
    {:ok, first} = Journal.claim_session(journal)
    for seq <- 1..3, do: assert(:ok = Journal.append(journal, record(seq), first))

    File.open!(journal, [:append, :binary], fn io -> IO.binwrite(io, <<0, 0, 0, 90, 1>>) end)
    assert {:ok, _kept, {:torn, offset}} = Journal.read(journal)
    size = File.stat!(journal).size

    assert :ok = Journal.release_session(journal, first)
    {:ok, second} = Journal.claim_session(journal)

    # This is the demonstrated failure in constructed form: a repair begun under
    # one claim, completing while another owner holds the journal, truncated it.
    assert {:error, {:not_the_session_owner, ^journal}} =
             Journal.discard_torn_tail(journal, offset, first)

    assert File.stat!(journal).size == size,
           "a refused repair must not remove a byte, least of all all of them"

    assert :ok = Journal.discard_torn_tail(journal, offset, second)
    assert {:ok, records, :complete} = Journal.read(journal)
    assert length(records) == 3
  end

  test "a second process holding the owner's token is still refused" do
    journal = DurableTruth.journal_path("ownership-foreign-process")
    {:ok, token} = Journal.claim_session(journal)
    assert :ok = Journal.append(journal, record(1), token)
    size = File.stat!(journal).size

    # The token is correct and the OS process is the same. Only the Erlang pid
    # differs, which is the check that makes the owning PROCESS the boundary --
    # copying a token out of the owner is not enough.
    assert {:error, {:not_the_session_owner, ^journal}} =
             elsewhere(fn -> Journal.append(journal, record(2), token) end)

    assert {:error, {:not_the_claim_holder, _lock}} =
             elsewhere(fn -> Journal.release_session(journal, token) end)

    assert File.stat!(journal).size == size
    assert {:ok, [_one], :complete} = Journal.read(journal)
  end

  test "a token whose claim was taken by another OS process is refused" do
    journal = DurableTruth.journal_path("ownership-foreign-vm")
    {:ok, setup_token} = Journal.claim_session(journal)
    {:ok, lock} = Journal.session_lock_path(journal)
    assert :ok = Journal.append(journal, record(1), setup_token)
    size = File.stat!(journal).size
    assert :ok = Journal.release_session(journal, setup_token)

    # A claim held by a DIFFERENT OS process, whose token this caller happens to
    # know and whose Erlang pid happens to match this process. Only the OS pid
    # separates them, which is the whole point: two unnamed BEAMs are both
    # `nonode@nohost`, so the node name cannot make this distinction and the OS
    # pid is the only field that does.
    token = "a-known-token"
    digest = :crypto.hash(:sha256, token) |> Base.encode16(case: :lower)
    foreign_os_pid = if System.pid() == "1", do: "2", else: "1"
    refute foreign_os_pid == System.pid()

    File.write!(
      lock,
      "node=#{node()} os_pid=#{foreign_os_pid} erl_pid=#{inspect(self())} token_digest=#{digest} at=0\n"
    )

    assert {:error, {:not_the_session_owner, ^journal}} =
             Journal.append(journal, record(2), token)

    assert {:error, {:not_the_session_owner, ^journal}} =
             Journal.discard_torn_tail(journal, 0, token)

    assert {:error, {:not_the_claim_holder, ^lock}} = Journal.release_session(journal, token)

    assert File.stat!(journal).size == size, "a foreign claim must stop every mutation"
    assert File.exists?(lock), "and its sentinel must survive"
    File.rm(lock)
  end

  test "a live owner is not evicted and a second claim is refused" do
    journal = DurableTruth.journal_path("ownership-live-owner")
    {:ok, token} = Journal.claim_session(journal)
    {:ok, lock} = Journal.session_lock_path(journal)
    held = File.read!(lock)

    assert {:error, {:repair_already_held, ^lock, _who}} = Journal.claim_session(journal)

    assert {:error, {:repair_already_held, ^lock, _who}} =
             elsewhere(fn -> Journal.claim_session(journal) end)

    assert File.read!(lock) == held, "a refused claim must not disturb the live one"
    assert :ok = Journal.append(journal, record(1), token)
  end

  test "exactly one contender takes over a provably dead claim" do
    journal = DurableTruth.journal_path("ownership-dead-takeover")

    # The sentinel is keyed by device and inode, so the journal has to exist
    # before there is a lock path to write. Claiming creates it; releasing leaves
    # the file in place with no live claim.
    {:ok, setup_token} = Journal.claim_session(journal)
    {:ok, lock} = Journal.session_lock_path(journal)
    assert :ok = Journal.release_session(journal, setup_token)

    # A claim recorded by this VM and this OS process, whose Erlang process is
    # gone: provably dead, and therefore takeable. Written directly so the case
    # does not depend on scheduling a real death.
    dead =
      "node=#{node()} os_pid=#{System.pid()} erl_pid=#PID<0.99999.0> " <>
        "token_digest=#{String.duplicate("0", 64)} at=0\n"

    File.write!(lock, dead)

    parent = self()
    contenders = 32

    for _ <- 1..contenders do
      spawn(fn -> send(parent, {:claim, Journal.claim_session(journal)}) end)
    end

    results =
      for _ <- 1..contenders do
        receive do
          {:claim, result} -> result
        after
          5_000 -> flunk("a contender never answered")
        end
      end

    winners = Enum.filter(results, &match?({:ok, _token}, &1))
    losers = Enum.filter(results, &match?({:error, {:repair_already_held, _, _}}, &1))

    assert length(winners) == 1,
           "exactly one contender may take over a dead claim, got #{length(winners)}"

    assert length(winners) + length(losers) == contenders,
           "every contender must either win or be told the claim is held: #{inspect(results)}"

    assert File.read!(lock) != dead, "the winner must have replaced the dead claim"
  end
end
