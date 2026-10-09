# Concept: the shared session fixture loads under an explicit temporary home.
# Technical depth: its guard runs during require, before case setup. Restore the
# host environment immediately; the fixture starts no actors while loading.
fixture_home =
  Path.join(System.tmp_dir!(), "run-evidence-load-#{System.unique_integer([:positive])}")

File.mkdir_p!(fixture_home)
prior_home = System.get_env("LOOPEX_HOME")
System.put_env("LOOPEX_HOME", fixture_home)

try do
  Code.require_file("../../loopex/test/support/m1_runtime_helper.exs", __DIR__)
  Code.require_file("../../loopex/test/support/agent_loop_helper.exs", __DIR__)
after
  if prior_home,
    do: System.put_env("LOOPEX_HOME", prior_home),
    else: System.delete_env("LOOPEX_HOME")

  File.rm_rf!(fixture_home)
end
Code.require_file("../../loopex/test/support/configured_genesis_helper.exs", __DIR__)

defmodule LoopexComposition.RunEvidenceRestartTest do
  use ExUnit.Case, async: false

  alias Loopex.AgentLoopFixture, as: Fixture
  alias Loopex.Runtime

  # Concept: ADR 0069 evidence is the reducer's fold, so a physical restart of
  # the shipped Local Store returns the identical map without activating work.
  test "run evidence is identical after a physical Local Store restart" do
    root =
      Path.join(System.tmp_dir!(), "loopex-run-evidence-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    path = Path.join(root, "history.log")
    {:ok, store} = Loopex.Store.Local.start_link(path: path)

    fixture =
      Fixture.start(
        store: store,
        store_module: Loopex.Store.Local,
        script: [
          %{
            text: "write",
            calls: [%{id: "c1", name: "write", arguments: %{"path" => "a"}}],
            usage: %{input_tokens: 21, output_tokens: 8}
          },
          %{text: "done", calls: [], usage: %{input_tokens: 5}}
        ]
      )

    {session, attachment, {:accepted, "prompt-1"}} = Fixture.run(fixture, "work")
    await_finished(attachment, System.monotonic_time(:millisecond) + 5_000)
    {:ok, handle} = Loopex.Store.new(Loopex.Store.Local, store)
    run = run_id(handle, session)
    assert {:ok, before} = Runtime.run_evidence(fixture.runtime, session, run)
    assert before.terminal.state in ["completed", "bound_reached"]
    assert before.usage.reported_input == 21 and before.usage.reported_output == 8
    assert before.usage.unresolved and before.usage.estimated > 0
    Fixture.stop(fixture)
    if Process.alive?(store), do: :ok = GenServer.stop(store, :normal, 1_000)

    {:ok, reopened} = Loopex.Store.Local.start_link(path: path)
    {:ok, store} = Loopex.Store.new(Loopex.Store.Local, reopened)

    {:ok, runtime} =
      Loopex.start_link(
        runtime_id: "agent-loop-runtime",
        context_token_budget: 8_192,
        store: store
      )

    Loopex.ConfiguredGenesisFixture.await_creation_ready(runtime)
    {:ok, records} = Loopex.Store.load_records(store, session, 0, 1_024)
    assert Runtime.run_evidence(runtime, session, run) == {:ok, before}
    assert before.through_version == List.last(records).journal_version
    assert Runtime.run_evidence(runtime, session, "other-run") == {:error, :unknown_run}
    # Concept: the query appends nothing to the session it reads.
    assert Loopex.Store.load_records(store, session, 0, 1_024) == {:ok, records}
    assert :ok = Loopex.stop(runtime)
    if Process.alive?(reopened), do: :ok = GenServer.stop(reopened, :normal, 1_000)
  end

  defp run_id(store, session) do
    {:ok, records} = Loopex.Store.load_records(store, session, 0, 1_024)
    [admitted] = Enum.filter(records, &(&1.payload.kind == "prompt_admitted_v3"))

    admitted.payload["run_id"]
  end

  defp await_finished(attachment, deadline) do
    case Loopex.next_event(attachment) do
      {:ok, %{kind: "run.finished"}} ->
        :ok

      observation ->
        assert System.monotonic_time(:millisecond) < deadline,
               "run did not finish: #{inspect(observation)}"

        unless match?({:ok, %{}}, observation), do: Process.sleep(10)
        await_finished(attachment, deadline)
    end
  end
end
