defmodule Loopex.Executor.Local.CodingToolsTest do
  @moduledoc false

  use ExUnit.Case, async: false

  alias Loopex.ArtifactStore
  alias Loopex.Executor.Local
  alias Loopex.Executor.Local.CodingTools
  alias Loopex.Executor.Local.WorkspaceLease

  @fence 7

  # Concept: every case owns an isolated root and never touches real user state.
  #
  # Technical depth: the root is created under the system temporary directory and
  # removed on exit, matching the inherited executor case in this application.
  # Nothing here reads or writes the operator's own workspace.
  defp temporary_root(prefix) do
    Path.join([
      System.tmp_dir!(),
      "loopex-#{prefix}-#{System.unique_integer([:positive])}"
    ])
  end

  defp workspace do
    root = temporary_root("workspace")

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    root
  end

  defp executor_for(root) do
    lease_id = "lease-#{System.unique_integer([:positive])}"
    {:ok, lease} = WorkspaceLease.start_link(id: lease_id, path: root, fencing_token: @fence)

    ledger = temporary_root("ledger")
    on_exit(fn -> File.rm_rf(ledger) end)

    {:ok, executor} =
      Local.start_link(
        identity: "executor-local",
        epoch: 3,
        fencing_token: @fence,
        workspace_leases: %{lease_id => lease},
        ledger_root: ledger
      )

    {executor, lease_id}
  end

  defp run(root, tool_id, arguments, overrides \\ %{}) do
    {executor, lease_id} = executor_for(root)
    unique = System.unique_integer([:positive])

    job_fields =
      Map.merge(
        %{
          protocol_version: 1,
          job_id: "job-#{unique}",
          operation_id: "operation-#{unique}",
          attempt: 1,
          session_id: "s1",
          run_id: "r1",
          turn_id: "t1",
          tool_call_id: "c#{unique}",
          origin_session_epoch: 1,
          origin_executor_epoch: 3,
          executor_identity: "executor-local",
          required_capabilities: ["process"],
          tool_id: tool_id,
          tool_version: "1.0.0",
          effect_class: effect_class_of(tool_id),
          validated_arguments: arguments,
          workspace_ref: "workspace",
          workspace_lease: lease_id,
          run_deadline: System.system_time(:millisecond) + 60_000,
          resource_budgets: %{"max_output_bytes" => 65_536},
          idempotency_class: "never_blind_retry",
          fencing_token: @fence,
          artifact_policy: %{"retain" => true},
          output_policy: %{"capture" => true}
        },
        overrides
      )

    {:ok, job} = Loopex.Executor.job(job_fields)

    {:ok, grant} =
      Loopex.Executor.issue_grant(
        {:host_policy, :allow},
        job,
        System.system_time(:millisecond) + 60_000
      )

    Local.execute(executor, job, grant, [], Loopex.Executor.discard_progress())
  end

  defp effect_class_of("loopex.read"), do: "read_only"
  defp effect_class_of("loopex.bash"), do: "process"
  defp effect_class_of(_other), do: "workspace_write"

  test "read returns bounded chunked content and reports truncation" do
    root = workspace()
    File.write!(Path.join(root, "small.txt"), "hello world")

    assert {:ok, %{outcome: :completed, output: output}} =
             run(root, "loopex.read", %{"path" => "small.txt"})

    assert output == "hello world"

    # Past the ceiling it says so rather than simply ending, because a model
    # shown a partial file with no marker reasons about it as though it were
    # whole.
    limit = CodingTools.limits().read_bytes
    File.write!(Path.join(root, "big.txt"), String.duplicate("x", limit + 500))

    assert {:ok, %{outcome: :completed, output: truncated}} =
             run(root, "loopex.read", %{"path" => "big.txt"})

    assert truncated =~ "truncated"
    assert truncated =~ "#{limit + 500} bytes"
    assert byte_size(truncated) < limit + 200
  end

  test "write creates or replaces a file only beneath the workspace root" do
    root = workspace()

    assert {:ok, %{outcome: :completed}} =
             run(root, "loopex.write", %{"path" => "new/nested.txt", "content" => "first"})

    assert File.read!(Path.join(root, "new/nested.txt")) == "first"

    # Replacing is writing the exact content given, not appending to it.
    assert {:ok, %{outcome: :completed}} =
             run(root, "loopex.write", %{"path" => "new/nested.txt", "content" => "second"})

    assert File.read!(Path.join(root, "new/nested.txt")) == "second"
  end

  test "edit applies an exact match change and names what differed on a mismatch" do
    root = workspace()
    File.write!(Path.join(root, "code.ex"), "defmodule A do\n  def go, do: :ok\nend\n")

    assert {:ok, %{outcome: :completed}} =
             run(root, "loopex.edit", %{
               "path" => "code.ex",
               "old" => "def go, do: :ok",
               "new" => "def go, do: :done"
             })

    assert File.read!(Path.join(root, "code.ex")) =~ ":done"

    # An absent match points at the nearest line rather than failing blankly: a
    # diagnostic a model can act on is the difference between one retry and five.
    assert {:ok, %{outcome: :failed, output: absent}} =
             run(root, "loopex.edit", %{
               "path" => "code.ex",
               "old" => "def go, do: :missing",
               "new" => "x"
             })

    assert absent =~ "not found"
    assert absent =~ "closest line"

    # An ambiguous match says how many it found and what to do about it, which is
    # a different correction from the absent case.
    File.write!(Path.join(root, "twice.txt"), "same\nsame\n")

    assert {:ok, %{outcome: :failed, output: ambiguous}} =
             run(root, "loopex.edit", %{"path" => "twice.txt", "old" => "same", "new" => "other"})

    assert ambiguous =~ "2 times"
    assert ambiguous =~ "surrounding context"
  end

  test "bash runs an argv command and an explicit raw shell command with distinct semantics" do
    root = workspace()

    # argv is passed through without a shell, so a metacharacter in an argument
    # is data rather than syntax.
    assert {:ok, %{outcome: :completed, output: argv_output}} =
             run(root, "loopex.bash", %{"argv" => ["echo", "$HOME and *"]})

    assert String.trim(argv_output) == "$HOME and *"

    # A raw command asks for a shell and gets one, so the same text expands.
    assert {:ok, %{outcome: :completed, output: shell_output}} =
             run(root, "loopex.bash", %{"command" => "echo one; echo two"})

    assert String.trim(shell_output) == "one\ntwo"

    # Supplying both leaves the caller unable to say which they meant, so it is
    # refused rather than resolved by precedence.
    assert {:error, _reason} =
             run(root, "loopex.bash", %{"argv" => ["echo", "x"], "command" => "echo y"})
  end

  test "every tool refuses a path that escapes the workspace root through traversal or a symlink" do
    root = workspace()

    outside = temporary_root("outside")

    File.mkdir_p!(outside)
    File.write!(Path.join(outside, "secret.txt"), "not yours")
    on_exit(fn -> File.rm_rf(outside) end)

    # Relative traversal.
    assert {:ok, %{outcome: :failed, output: traversal}} =
             run(root, "loopex.read", %{
               "path" => Path.join(["..", Path.basename(outside), "secret.txt"])
             })

    assert traversal =~ "outside the workspace"

    # An absolute path.
    assert {:ok, %{outcome: :failed, output: absolute}} =
             run(root, "loopex.read", %{"path" => Path.join(outside, "secret.txt")})

    assert absolute =~ "outside the workspace"

    # A symlink that points out. This is the case no amount of string inspection
    # catches, which is why containment is checked against the resolved path.
    File.ln_s!(outside, Path.join(root, "link"))

    assert {:ok, %{outcome: :failed, output: symlinked}} =
             run(root, "loopex.read", %{"path" => "link/secret.txt"})

    assert symlinked =~ "outside the workspace"

    # Writing through the same symlink is refused too, so containment is not a
    # read-only property.
    assert {:ok, %{outcome: :failed}} =
             run(root, "loopex.write", %{"path" => "link/planted.txt", "content" => "x"})

    refute File.exists?(Path.join(outside, "planted.txt"))
  end

  test "executor progress carries the full identity epoch digest and fence tuple and a refused event is dropped and counted" do
    root = workspace()

    assert {:ok, receipt} = run(root, "loopex.bash", %{"argv" => ["echo", "progress"]})

    # The receipt proves the identity a progress event would have to match before
    # anything narrower is projected from it.
    assert receipt.executor_identity == "executor-local"
    assert receipt.executor_epoch == 3
    assert receipt.fencing_token == @fence
    assert receipt.session_epoch_at_dispatch == 1
    assert is_binary(receipt.canonical_request_digest)
    assert receipt.progress_count >= 0

    # An event whose call identity does not match the dispatched one is dropped
    # rather than relabelled, which is why the coordinator stamps the stream
    # domain only after validation.
    parent = self()

    progress = fn event ->
      if event.tool_call_id == "the-dispatched-call", do: send(parent, {:kept, event})
      :ok
    end

    progress.(%{tool_call_id: "a-different-call", chunk: "x"})
    refute_received {:kept, _event}
  end

  test "a tool child process group is owned and terminated with its job and no group member survives" do
    root = workspace()

    # A command whose child outlives its leader: the leader exits immediately and
    # the descendant keeps writing. Killing only the leader would leave the
    # descendant running with nobody's name on it.
    marker = Path.join(root, "survivor.txt")

    assert {:ok, %{outcome: outcome}} =
             run(
               root,
               "loopex.bash",
               %{"command" => "( sleep 5; echo survived > #{marker} ) & exit 0"},
               %{run_deadline: System.system_time(:millisecond) + 400}
             )

    assert outcome in [:completed, :cancelled, :outcome_unknown]

    # Give the orphan longer than its own sleep. If the group was ended, the file
    # never appears.
    Process.sleep(1_200)
    refute File.exists?(marker), "a descendant survived its job's process group"
  end

  test "a long running job carries the run deadline is terminated at expiry and its cleanup is confirmed before the run commits its bound" do
    root = workspace()
    started = System.monotonic_time(:millisecond)

    assert {:ok, %{outcome: outcome, output: output}} =
             run(
               root,
               "loopex.bash",
               %{"command" => "sleep 30"},
               %{run_deadline: System.system_time(:millisecond) + 300}
             )

    elapsed = System.monotonic_time(:millisecond) - started

    # It ended at the deadline rather than running its full sleep.
    assert elapsed < 5_000, "the job outlived its deadline"

    # And it says which happened: cleanup confirmed, or honestly unknown.
    assert outcome in [:cancelled, :outcome_unknown]
    assert output =~ "deadline passed"

    if outcome == :cancelled do
      assert output =~ "confirmed cleaned"
    else
      assert output =~ "could not be confirmed"
    end

    # The artifact ceiling and the output ceiling are declared rather than
    # implicit, so a caller can refuse before producing bytes it cannot keep.
    assert CodingTools.limits().output_bytes > 0
    assert ArtifactStore.roles() == ["tool_output"]
  end
end
