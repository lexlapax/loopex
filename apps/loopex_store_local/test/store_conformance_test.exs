Code.require_file("support/store_conformance_helper.exs", __DIR__)

defmodule Loopex.Store.Local.ConformanceTest do
  @moduledoc """
  ## Concept

  Outcome 3: the in-memory test Store and durable local Store obey the same
  atomic transaction, ownership, version, resolution, and outbox semantics;
  only the durable implementation claims restart and replay.

  ## Technical depth

  The five protected cases delegate to one reusable conformance helper. Each
  case contains multiple derived subcases, but the locked selector exposes only
  the exact identities required by the M1 gate. The standalone gate runner does
  not load `test_helper.exs`, so the helper uses only the isolated
  `LOOPEX_HOME` supplied by its invocation.
  """

  use ExUnit.Case, async: false

  alias LoopexStoreLocalTest.Conformance

  setup do
    previous = Process.flag(:trap_exit, true)
    on_exit(fn -> Process.flag(:trap_exit, previous) end)
    :ok
  end

  test "every implementation atomically refuses a stale owner epoch incarnation and version" do
    Conformance.atomic_fencing()
  end

  test "a killed writer loses no acknowledged fact" do
    Conformance.killed_writer_and_fault_catalogue()
  end

  test "replay audits durable truth but grants no write authority" do
    Conformance.replay_audit()
  end

  test "known transactions return their retained resolution without a second mutation" do
    Conformance.retained_resolutions()
  end

  test "the durable local store survives process death with consecutive store-stamped history" do
    Conformance.durable_restart()
  end
end
