Code.require_file("support/delegation_runtime_fixture.exs", __DIR__)

defmodule LoopexComposition.DelegationJobIndexTest do
  use ExUnit.Case, async: false

  alias LoopexComposition.Delegation.{Helper, JobIndex, LedgerCodec, RetainedObjects}
  alias LoopexComposition.DelegationRuntimeFixture, as: Fixture

  # Concept: ADR 0046's job-index-v1 lets a later start resume classification
  # after a validated prefix instead of rescanning it, never as authority.
  test "a validated coverage entry resumes the next start after its watermark" do
    {fixture, parent, run} = delegated()
    first = Fixture.restart(fixture)
    status = Helper.status(first.helper)
    assert status.classified == :complete
    refute status.scan[parent].resumed
    [{child, job_id}] = Map.to_list(status.children)

    assert {:ok, bytes} = RetainedObjects.read_index(first.objects, JobIndex.job_name(job_id))
    assert {:ok, entry} = JobIndex.decode_job(bytes)
    assert entry["job"]["job_id"] == Base.encode64(job_id)
    {:ok, run_log} = LedgerCodec.header_key(:run, ["helper-runtime", parent, run])
    assert entry["run_log"] == run_log

    log =
      File.read!(
        Path.join([first.root, "delegation", hash("helper-runtime"), "runs", run_log <> ".log"])
      )

    offset = entry["frame_offset"]
    frame = binary_part(log, offset, byte_size(log) - offset)
    assert {:ok, payload, _rest} = LedgerCodec.decode_frame(frame)

    assert {:ok, %{"mutation" => %{"kind" => "reserve"}}} =
             LedgerCodec.decode_json(payload, :frame)

    assert {:ok, coverage} =
             RetainedObjects.read_index(first.objects, JobIndex.coverage_name(parent))

    assert {:ok, %{through: through}} =
             JobIndex.decode_coverage(coverage, "helper-runtime", parent)

    assert through == status.scan[parent].through
    second = Fixture.restart(first)
    status = Helper.status(second.helper)
    assert status.classified == :complete
    assert status.scan[parent].resumed
    # Concept: the covered prefix still classifies the settled child.
    assert {:ok, :helper_child} = Helper.classify_session(second.helper, child)
    refute LoopexComposition.Delegation.RunLedger.occupied?(status.runs[{parent, run}])
  end

  test "a mismatching coverage entry is discarded and the session rescanned" do
    {fixture, parent, _run} = delegated()
    first = Fixture.restart(fixture)
    {:ok, coverage} = RetainedObjects.read_index(first.objects, JobIndex.coverage_name(parent))
    {:ok, decoded} = LedgerCodec.decode_json(coverage, :object)

    {:ok, forged} =
      LedgerCodec.encode_json(
        %{decoded | "expected_sha256" => String.duplicate("0", 64)},
        :object
      )

    :ok = RetainedObjects.put_index(first.objects, JobIndex.coverage_name(parent), forged)
    second = Fixture.restart(first)
    status = Helper.status(second.helper)
    assert status.classified == :complete
    refute status.scan[parent].resumed
    third = Fixture.restart(second)
    assert Helper.status(third.helper).scan[parent].resumed
  end

  test "a refused registration's job entry is removed before coverage is published" do
    fixture =
      Fixture.start([
        %{
          text: "bad",
          calls: [
            %{
              id: "bad-call",
              name: "task",
              arguments: %{"role" => "inspect", "description" => "", "prompt" => "x"}
            }
          ]
        },
        %{text: "done", calls: []}
      ])

    parent = Fixture.parent(fixture, "parent-create")
    {_attachment, run} = Fixture.prompt(fixture, parent, "prompt", "investigate")
    assert Fixture.await_terminal(fixture, parent, run).terminal.state == "completed"
    {:ok, page} = Loopex.Runtime.effect_intents(fixture.runtime, parent, nil, 16)
    [%{job: job, journal_version: version}] = for %{kind: "intent"} = row <- page.rows, do: row
    projection = Helper.project(job)

    source = %{
      "session_id" => Base.encode64(parent),
      "journal_version" => version,
      "canonical_request_digest" => job.canonical_request_digest
    }

    {:ok, run_log} = LedgerCodec.header_key(:run, ["helper-runtime", parent, run])
    {:ok, planted} = JobIndex.job_entry(projection, source, run_log, nil)
    :ok = RetainedObjects.put_index(fixture.objects, JobIndex.job_name(job.job_id), planted)
    restarted = Fixture.restart(fixture)
    assert Helper.status(restarted.helper).classified == :complete

    assert RetainedObjects.read_index(restarted.objects, JobIndex.job_name(job.job_id)) ==
             :absent

    assert {:ok, _coverage} =
             RetainedObjects.read_index(restarted.objects, JobIndex.coverage_name(parent))
  end

  test "an interrupted publication leaves no validated coverage and the next start rescans" do
    {fixture, parent, _run} = delegated()
    test = self()

    fault = fn step ->
      if step == :before_coverage do
        send(test, :publishing)
        :crash
      else
        :ok
      end
    end

    catch_exit(Fixture.restart(fixture, fault: fault))
    assert_received :publishing
    Fixture.crash_all(fixture)
    restarted = Fixture.boot(fixture, recover_stale_writer: true, classify: true)
    status = Helper.status(restarted.helper)
    assert status.classified == :complete
    refute status.scan[parent].resumed

    assert {:ok, _} =
             RetainedObjects.read_index(restarted.objects, JobIndex.coverage_name(parent))
  end

  defp delegated do
    fixture =
      Fixture.start([
        %{text: "go", calls: [Fixture.task_call("call-task")]},
        %{text: "Finding.", calls: []},
        %{text: "done", calls: []}
      ])

    parent = Fixture.parent(fixture, "parent-create")
    {_attachment, run} = Fixture.prompt(fixture, parent, "prompt", "investigate")
    assert Fixture.await_terminal(fixture, parent, run).terminal.state == "completed"
    {fixture, parent, run}
  end

  defp hash(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
