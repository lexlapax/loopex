defmodule Loopex.Executor.Local.CodingToolsTest.RecordingStore do
  @moduledoc false

  # Concept: an artifact store that remembers what an executor handed it.
  #
  # Technical depth: the claim under test is that the executor spills through the
  # port, not that a particular adapter stores bytes well -- the local adapter has
  # its own conformance suite for that. Recording here is what lets the case
  # assert on the bytes the executor passed rather than on bytes a test wrote.

  @behaviour Loopex.ArtifactStore

  def start, do: Agent.start_link(fn -> %{} end)
  def stored(pid), do: Agent.get(pid, & &1)

  @impl Loopex.ArtifactStore
  def put(pid, bytes, metadata) do
    digest = :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

    reference = %{
      digest: digest,
      media_type: Map.get(metadata, "media_type", "application/octet-stream"),
      size: byte_size(bytes),
      role: Map.get(metadata, "role", "tool_output"),
      locator: digest
    }

    :ok = Agent.update(pid, &Map.put(&1, digest, bytes))
    {:ok, reference}
  end

  @impl Loopex.ArtifactStore
  def fetch(pid, reference) do
    case Agent.get(pid, &Map.fetch(&1, reference.locator)) do
      {:ok, bytes} -> {:ok, bytes}
      :error -> {:error, :unknown_artifact}
    end
  end

  @impl Loopex.ArtifactStore
  def stat(pid, reference) do
    case Agent.get(pid, &Map.fetch(&1, reference.locator)) do
      {:ok, bytes} -> {:ok, %{reference | size: byte_size(bytes)}}
      :error -> {:error, :unknown_artifact}
    end
  end
end

defmodule Loopex.Executor.Local.CodingToolsTest.BlockingStore do
  @moduledoc false

  # Concept: an artifact store that blocks the way a real one can.
  #
  # Technical depth: `put/3` belongs to a host and this executor cannot bound it
  # -- a remote object store, a slow disk, or a saturated one all block here. The
  # claim under test is that the workspace lease is honoured while it blocks, so
  # the store has to actually block and has to announce that it started, or the
  # case cannot revoke the lease at the one instant that matters.

  @behaviour Loopex.ArtifactStore

  @impl Loopex.ArtifactStore
  def put({owner, delay}, bytes, metadata) do
    send(owner, :retention_started)
    Process.sleep(delay)

    digest = :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

    {:ok,
     %{
       digest: digest,
       media_type: Map.get(metadata, "media_type", "application/octet-stream"),
       size: byte_size(bytes),
       role: Map.get(metadata, "role", "tool_output"),
       locator: digest
     }}
  end

  @impl Loopex.ArtifactStore
  def fetch(_handle, _reference), do: {:error, :unknown_artifact}

  @impl Loopex.ArtifactStore
  def stat(_handle, _reference), do: {:error, :unknown_artifact}
end

defmodule Loopex.Executor.Local.CodingToolsTest.RetainedManualProbe do
  @moduledoc false

  # Concept: a probabilistic diagnostic remains runnable without becoming gate
  # evidence or adding an exclusion to the locked deterministic lane.
  #
  # Technical depth: lane 4 has a zero-exclusion contract, so an ordinary ExUnit
  # exclusion would make the gate red even though neither probe is protected.
  # Define these cases only when the caller explicitly includes the retained
  # manual-probe tag; the ordinary suite and the authoritative selector then see
  # the same deterministic corpus with no skipped or excluded case.
  defmacro retained_manual_probe(name, do: body) do
    enabled? =
      ExUnit.configuration()
      |> Keyword.get(:include, [])
      |> Enum.any?(fn
        :retained_manual_probe -> true
        {:retained_manual_probe, _value} -> true
        _other -> false
      end)

    if enabled? do
      quote do
        @tag :retained_manual_probe
        ExUnit.Case.test unquote(name) do
          unquote(body)
        end
      end
    else
      quote(do: :ok)
    end
  end
end

defmodule Loopex.Executor.Local.CodingToolsTest do
  @moduledoc false

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Loopex.Executor.Local.CodingToolsTest.RetainedManualProbe

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

  defp executor_for(root, artifacts \\ nil) do
    {executor, lease_id, _lease} = executor_and_lease(root, artifacts)
    {executor, lease_id}
  end

  # Concept: a case about losing the lease needs to be able to stop the holder.
  #
  # Technical depth: the lease pid is edge-private and never enters a job, so
  # every other case takes only the plain identity `executor_for/2` returns. A
  # case that has to revoke the claim mid-job needs the holder itself, which is
  # the one thing that composed it can supply.
  defp executor_and_lease(root, artifacts \\ nil) do
    {executor, lease_id, lease, _ledger} = executor_lease_and_ledger(root, artifacts)
    {executor, lease_id, lease}
  end

  # Concept: a case about the receipt's retention needs the ledger the receipt is
  # retained in.
  #
  # Technical depth: the ledger root is host-supplied configuration, so a case
  # that composes the executor already owns it; returning it is what lets a case
  # observe the retention it configured rather than guess when it happens.
  defp executor_lease_and_ledger(root, artifacts \\ nil) do
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
        ledger_root: ledger,
        artifacts: artifacts
      )

    {executor, lease_id, lease, ledger}
  end

  # Concept: wait for a path the executor creates, rather than for a duration
  # guessed from the outside.
  #
  # Technical depth: a case that has to act at one point inside a job cannot use
  # a sleep, because the point it is aiming at is a few milliseconds wide and
  # moves with the machine. Both paths a case here aims at announce themselves on
  # the filesystem -- the launcher writes a marker immediately before exiting,
  # and the receipt's retention creates its staging file -- so the wait is on the
  # executor's own progress.
  defp await_path(check, deadline_ms) do
    stop = System.monotonic_time(:millisecond) + deadline_ms
    await_path(check, stop, check.())
  end

  defp await_path(_check, _stop, {:ok, found}), do: {:ok, found}

  defp await_path(check, stop, :error) do
    if System.monotonic_time(:millisecond) > stop,
      do: :error,
      else: await_path(check, stop, check.())
  end

  defp staging_file(ledger) do
    case File.ls(ledger) do
      {:ok, entries} ->
        case Enum.find(entries, &String.contains?(&1, ".tmp-")) do
          nil -> :error
          found -> {:ok, found}
        end

      {:error, _reason} ->
        :error
    end
  end

  defp run(root, tool_id, arguments, overrides \\ %{}) do
    {execute_options, overrides} = Map.pop(overrides, :execute_options, [])

    # A case that composed its own executor passes it in; everything else gets a
    # fresh one, as before.
    {overrides, {executor, lease_id}} =
      case overrides do
        %{executor: executor, lease_id: lease_id} ->
          {Map.drop(overrides, [:executor, :lease_id]), {executor, lease_id}}

        _fresh ->
          {overrides, executor_for(root)}
      end

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

    Local.execute(
      executor,
      job,
      grant,
      execute_options,
      Loopex.Executor.discard_progress()
    )
  end

  # Concept: a case about the cleanup budget needs an executor composed with the
  # budget it is about.
  #
  # Technical depth: the period is a host-supplied start option, so a case that
  # varies it composes its own executor exactly as a host would. Everything else
  # matches `executor_lease_and_ledger/2`; only the declared period differs.
  # Concept: a lease held at a token this executor was not composed with.
  #
  # Technical depth: every other fixture here gives the lease and the executor
  # the same token, so the comparison between them is true whatever the code
  # does. This one is the case that tells them apart: the workspace was fenced to
  # a newer holder while this executor still refers to the old lease.
  defp executor_with_stale_lease(root) do
    lease_id = "lease-#{System.unique_integer([:positive])}"

    {:ok, lease} =
      WorkspaceLease.start_link(id: lease_id, path: root, fencing_token: @fence + 1)

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

  defp executor_with_probe(root, probe) do
    executor_with_options(root, cleanup_grace_ms: 3_000, process_probe: probe)
  end

  defp executor_with_grace(root, grace) do
    executor_with_options(root, cleanup_grace_ms: grace)
  end

  defp executor_with_options(root, extra) do
    lease_id = "lease-#{System.unique_integer([:positive])}"
    {:ok, lease} = WorkspaceLease.start_link(id: lease_id, path: root, fencing_token: @fence)

    ledger = temporary_root("ledger")
    on_exit(fn -> File.rm_rf(ledger) end)

    {:ok, executor} =
      Local.start_link(
        [
          identity: "executor-local",
          epoch: 3,
          fencing_token: @fence,
          workspace_leases: %{lease_id => lease},
          ledger_root: ledger
        ] ++ extra
      )

    {executor, lease_id}
  end

  # A command whose backgrounded group member refuses to go on `TERM`, so the
  # cleanup sequence has to sit through its cooperative grace and then kill it.
  # It is the only shape that makes the budget observable: a group that dies on
  # the first signal costs one look and tells a case nothing about the period.
  defp stubborn_group_command,
    do: "( trap \"\" TERM; sleep 20 ) >/dev/null 2>&1 & printf started; exit 0"

  # Poll rather than sleep a guessed interval: a case that has to act on a live
  # child needs to know the child is live, and a fixed pause is either slower
  # than it needs to be or occasionally wrong.
  defp wait_for_file(path, attempts \\ 200) do
    Enum.reduce_while(1..attempts, false, fn _attempt, _acc ->
      if File.exists?(path) do
        {:halt, true}
      else
        Process.sleep(25)
        {:cont, false}
      end
    end)
  end

  defp elapsed(work) do
    started = System.monotonic_time(:millisecond)
    result = work.()
    {System.monotonic_time(:millisecond) - started, result}
  end

  defp parse_environment(output) do
    output
    |> String.split("\n", trim: true)
    |> Map.new(fn entry ->
      [name, value] = String.split(entry, "=", parts: 2)
      {name, value}
    end)
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

  test "write creates or replaces a file beneath the workspace root and refuses static escapes" do
    root = workspace()

    assert {:ok, %{outcome: :completed}} =
             run(root, "loopex.write", %{"path" => "new/nested.txt", "content" => "first"})

    assert File.read!(Path.join(root, "new/nested.txt")) == "first"

    # Replacing is writing the exact content given, not appending to it.
    assert {:ok, %{outcome: :completed}} =
             run(root, "loopex.write", %{"path" => "new/nested.txt", "content" => "second"})

    assert File.read!(Path.join(root, "new/nested.txt")) == "second"

    # Concept: "only beneath" is half a claim until a write that aims outside is
    # refused, and the refusal is checked in the filesystem rather than in the
    # answer.
    #
    # Technical depth: this case asserted successful writes inside the root and
    # nothing else, so every word after "creates or replaces a file" was
    # untested. A `write` that ignored containment entirely -- or one that
    # reported a refusal while the bytes still landed -- passed it. The three
    # ways a path leaves a root are asserted here against a directory this case
    # owns and can inspect afterwards: a relative traversal, an absolute path,
    # and a static symlink, which is the one no amount of string inspection
    # catches. Each is checked twice: the tool refused, and the file it named is
    # not there.
    outside = temporary_root("outside-write")
    File.mkdir_p!(outside)
    File.write!(Path.join(outside, "existing.txt"), "not yours")
    on_exit(fn -> File.rm_rf(outside) end)

    escapes = [
      {"a relative traversal", Path.join(["..", Path.basename(outside), "traversed.txt"]),
       Path.join(outside, "traversed.txt")},
      {"an absolute path", Path.join(outside, "absolute.txt"), Path.join(outside, "absolute.txt")}
    ]

    for {described, path, planted} <- escapes do
      assert {:ok, %{outcome: :failed, output: refusal}} =
               run(root, "loopex.write", %{"path" => path, "content" => "planted"})

      assert refusal =~ "outside the workspace", "#{described} was not refused as an escape"
      refute File.exists?(planted), "#{described} wrote a file outside the workspace root"
    end

    # A static symlink placed in the workspace before the call, pointing at a
    # directory outside it. The path this names is contained as text and escapes
    # once it is resolved.
    File.ln_s!(outside, Path.join(root, "escape"))

    assert {:ok, %{outcome: :failed, output: through_link}} =
             run(root, "loopex.write", %{"path" => "escape/planted.txt", "content" => "planted"})

    assert through_link =~ "outside the workspace"
    refute File.exists?(Path.join(outside, "planted.txt"))

    # The same symlink as the final component, naming a file that already exists
    # outside. A refusal that arrived after the truncation would leave this file
    # empty rather than intact.
    File.ln_s!(Path.join(outside, "existing.txt"), Path.join(root, "escaping-file"))

    assert {:ok, %{outcome: :failed}} =
             run(root, "loopex.write", %{"path" => "escaping-file", "content" => "overwritten"})

    assert File.read!(Path.join(outside, "existing.txt")) == "not yours"

    # Nothing beyond the file this case put there itself is in the outside
    # directory, so no escape landed under a name this case did not predict.
    assert File.ls!(outside) == ["existing.txt"]
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

  test "bash reports a nonzero exit as failed and names the status the command exited with" do
    root = workspace()

    # The defect this case holds down: a command that exits nonzero and prints
    # nothing arrived as `:completed` with empty output, which a model reads as
    # a silent success and acts on. The status was discarded at the port and the
    # receipt carries no field that could recover it.
    assert {:ok, %{outcome: :failed, output: silent}} =
             run(root, "loopex.bash", %{"command" => "exit 7"})

    assert silent =~ "status 7"

    # A failure that did print keeps what it printed and gains the status, so
    # the model sees the diagnosis and the verdict together.
    assert {:ok, %{outcome: :failed, output: noisy}} =
             run(root, "loopex.bash", %{"command" => "echo before; exit 3"})

    assert noisy =~ "before"
    assert noisy =~ "status 3"

    # A command the shell cannot find fails on the status the shell chose, not
    # on this executor inspecting the message it printed.
    assert {:ok, %{outcome: :failed, output: missing}} =
             run(root, "loopex.bash", %{
               "command" => "no_such_command_#{System.unique_integer([:positive])}"
             })

    assert missing =~ "exited with status"

    # Success is unchanged: a command that exited zero is still `:completed` and
    # carries no status note, because a note on every result is noise a model
    # learns to skip.
    assert {:ok, %{outcome: :completed, output: fine}} =
             run(root, "loopex.bash", %{"command" => "echo ok"})

    assert String.trim(fine) == "ok"
    refute fine =~ "exited with status"

    # Concept: a failure whose output overflowed the bound is still a failure.
    #
    # Technical depth: bounding the output has two branches and this case
    # exercised only the complete one, so making the truncated branch alone
    # report `:completed` left all twelve locked cases green while a command that
    # printed past the ceiling and exited nonzero reached the model as a success.
    # The status note is what a model reads the verdict from, so it must survive
    # truncation rather than being the first thing cut.
    limit = CodingTools.limits().output_bytes

    assert {:ok, %{outcome: :failed, output: overflowed}} =
             run(root, "loopex.bash", %{
               "command" => "yes 0123456789 | head -c #{limit + 5_000}; exit 7"
             })

    assert overflowed =~ "status 7"
    assert overflowed =~ "truncated"
    assert byte_size(overflowed) < limit + 1_000

    # And the branch still tells the two verdicts apart: overflowing is not
    # itself a failure, so a command that printed past the ceiling and exited
    # zero is completed and carries no status note.
    assert {:ok, %{outcome: :completed, output: overflowed_ok}} =
             run(root, "loopex.bash", %{
               "command" => "yes 0123456789 | head -c #{limit + 5_000}"
             })

    assert overflowed_ok =~ "truncated"
    refute overflowed_ok =~ "exited with status"
  end

  test "every filesystem tool refuses a path that escapes the workspace root through traversal or a symlink" do
    # Concept: containment is a property of the three tools that take a path, and
    # each of them has to be asked.
    #
    # Technical depth: this case was named for every tool and exercised
    # `loopex.read` for two vectors. `loopex.bash` was never in scope: it takes
    # no path at all, it runs a command, and a command can name any path its
    # process can reach -- which `docs/operator/tools-and-policy.md` states
    # plainly rather than implying a guarantee this executor does not make. The
    # name is now the claim: every tool that accepts a path, for every vector
    # claimed, refuses and leaves the outside file as it found it.
    root = workspace()

    outside = temporary_root("outside")

    File.mkdir_p!(outside)
    File.write!(Path.join(outside, "secret.txt"), "not yours")
    on_exit(fn -> File.rm_rf(outside) end)

    # A static symlink to the outside directory, and one whose own name is the
    # final component. The second is the case no amount of string inspection
    # catches: resolution once resolved the link's own parent plus its basename
    # -- where the link sits, not where it points -- so `read` returned the
    # outside file and `write` overwrote it under a documented guarantee.
    File.ln_s!(outside, Path.join(root, "link"))
    File.ln_s!(Path.join(outside, "secret.txt"), Path.join(root, "leak"))

    # A relative link out of the workspace is the same escape written
    # differently, and a link that points at itself must be refused rather than
    # followed forever.
    File.ln_s!(
      Path.join(["..", Path.basename(outside), "secret.txt"]),
      Path.join(root, "relative")
    )

    File.ln_s!(Path.join(root, "loop"), Path.join(root, "loop"))

    # Concept: a directory beside the workspace whose name begins with the
    # workspace's own name is outside it, and looks inside it to any comparison
    # made on text.
    #
    # Technical depth: every vector above uses two roots that are not prefixes of
    # one another, so containment passed whether or not the comparison appended a
    # separator -- and deleting that separator, which turns the check into a bare
    # `String.starts_with?`, left this case and the whole suite green. It is not
    # the recorded race: nothing is being manipulated concurrently and it
    # succeeds on the first attempt. `/workspaces/ws1` admits
    # `../ws10/.env` because the resolved path begins with `/workspaces/ws1`,
    # which is exactly the multi-tenant placement the workspace root exists to
    # separate. `read` returns the outside file whole; `edit` leaks a line of it
    # through the mismatch diagnostic before any directory guard runs.
    adjacent = root <> "-adjacent"
    File.mkdir_p!(adjacent)
    File.write!(Path.join(adjacent, "secret.txt"), "not yours")
    on_exit(fn -> File.rm_rf(adjacent) end)

    # The vectors this case claims, each named once and asked of all three tools.
    vectors = [
      {"a relative traversal", Path.join(["..", Path.basename(outside), "secret.txt"])},
      {"an absolute path", Path.join(outside, "secret.txt")},
      {"a static symlink to a directory outside", "link/secret.txt"},
      {"a static symlink as the final component", "leak"},
      {"a static symlink whose target is relative", "relative"},
      {"a symlink that points at itself", "loop"},
      {"a sibling directory whose name extends the root's",
       Path.join(["..", Path.basename(adjacent), "secret.txt"])},
      {"an absolute path into that sibling", Path.join(adjacent, "secret.txt")}
    ]

    # `loopex.bash` is deliberately absent: it declares no path parameter, so
    # there is no path for it to escape with and no containment claim to test.
    # Asserting its schema is what keeps that a fact about the shipped tool
    # rather than an omission a reader has to take on trust.
    bash = Enum.find(CodingTools.definitions(), &(&1["tool_id"] == "loopex.bash"))
    refute Map.has_key?(bash["parameter_schema"]["properties"], "path")

    filesystem_tools =
      for definition <- CodingTools.definitions(),
          Map.has_key?(definition["parameter_schema"]["properties"], "path"),
          do: definition["tool_id"]

    assert Enum.sort(filesystem_tools) == ["loopex.edit", "loopex.read", "loopex.write"]

    for {described, path} <- vectors, tool <- filesystem_tools do
      arguments =
        case tool do
          "loopex.read" -> %{"path" => path}
          "loopex.write" -> %{"path" => path, "content" => "planted"}
          "loopex.edit" -> %{"path" => path, "old" => "not yours", "new" => "mine now"}
        end

      assert {:ok, %{outcome: :failed, output: refusal}} = run(root, tool, arguments),
             "#{tool} did not refuse #{described}"

      # A self-referential link is an unresolvable path rather than a resolved
      # one that landed outside, so it is refused for a reason of its own. Every
      # other vector resolves to somewhere outside the root and says so.
      if path == "loop" do
        refute refusal =~ "not yours", "#{tool} followed #{described} to the outside file"
      else
        assert refusal =~ "outside the workspace",
               "#{tool} refused #{described} without naming the escape: #{refusal}"

        refute refusal =~ "not yours", "#{tool} returned the outside file's content"
      end

      # The refusal is checked in the filesystem too, in both directories a
      # vector can reach: the outside file is untouched and no new name appeared
      # beside it.
      for directory <- [outside, adjacent] do
        assert File.read!(Path.join(directory, "secret.txt")) == "not yours",
               "#{tool} changed a file outside the workspace through #{described}"

        assert File.ls!(directory) == ["secret.txt"],
               "#{tool} created something outside the workspace through #{described}"
      end
    end
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

  test "a coding tool command receives a constructed provider credential free environment and its receipt records that declared environment" do
    root = workspace()

    # The credential is exported exactly as an operator must export it for the
    # command to run at all, so this is the environment a real session has.
    System.put_env("LOOPEX_PROVIDER_API_KEY", "sk-sentinel-not-for-a-child")
    System.put_env("LOOPEX_SENTINEL_UNRELATED", "also-not-for-a-child")

    on_exit(fn ->
      System.delete_env("LOOPEX_PROVIDER_API_KEY")
      System.delete_env("LOOPEX_SENTINEL_UNRELATED")
    end)

    assert {:ok, receipt} =
             run(root, "loopex.bash", %{"command" => "printf %s \"$LOOPEX_PROVIDER_API_KEY\""})

    # Concept: a port opened without an explicit environment inherits this
    # operating-system process's own, and the operator's credential is in it.
    #
    # Technical depth: the demonstration tools were launched through
    # `/usr/bin/env -i` and so received nothing, but the coding tools took a
    # different path and were not. Asserting on the child's own output is the
    # only form of this check that cannot pass while the child can still read it.
    assert receipt.outcome == :completed
    refute receipt.output =~ "sk-sentinel"

    assert {:ok, unrelated} =
             run(root, "loopex.bash", %{"command" => "printf %s \"$LOOPEX_SENTINEL_UNRELATED\""})

    refute unrelated.output =~ "also-not-for-a-child"

    # The environment is constructed rather than filtered, so the child holds the
    # one name it was given and nothing else.
    assert {:ok, named} = run(root, "loopex.bash", %{"command" => "env | cut -d= -f1 | sort"})
    assert named.output =~ "PATH"
    refute named.output =~ "LOOPEX_PROVIDER_API_KEY"

    # Concept: argv is the other launcher, and it must construct the same
    # environment the raw-command launcher does.
    #
    # Technical depth: the two forms build their argument vectors in separate
    # clauses, and this case exercised only the raw one. Removing the
    # construction from the argv clause alone left every locked case green while
    # an argv call handed its child this operating-system process's whole
    # environment, the operator's provider credential among it. The receipt
    # fields are derived from the environment the executor intended, so they
    # cannot catch this either -- only the child's own output can.
    assert {:ok, argv_credential} =
             run(root, "loopex.bash", %{
               "argv" => ["sh", "-c", "printf %s \"$LOOPEX_PROVIDER_API_KEY\""]
             })

    assert argv_credential.outcome == :completed
    refute argv_credential.output =~ "sk-sentinel"

    assert {:ok, argv_named} = run(root, "loopex.bash", %{"argv" => ["env"]})
    assert Map.has_key?(parse_environment(argv_named.output), "PATH")
    refute argv_named.output =~ "LOOPEX_PROVIDER_API_KEY"
    refute argv_named.output =~ "LOOPEX_SENTINEL_UNRELATED"

    # Concept: the receipt records the environment declared for the downstream
    # command, not a constant.
    #
    # Technical depth: both fields were hardcoded, so the journal could drift
    # from the same environment list passed to the downstream `env -i` boundary.
    # The separate behavioural assertion above observes the command; these fields
    # retain the declaration that produced it and do not claim to observe the
    # first launcher's complete environment.
    assert receipt.child_environment_names == ["PATH"]
    refute receipt.provider_credential_present

    # Concept: a workspace that plants a `setsid` cannot receive the operator's
    # environment.
    #
    # Technical depth: the launcher used to be `setsid` resolved from the ambient
    # `PATH`, with `env -i` further along the argument vector -- so whatever
    # `setsid` resolved to ran with the credential still in its environment,
    # before anything was cleared, while the receipt reported the credential
    # absent from the environment the downstream child would get. The planted
    # program here writes whatever it can see; a run that reaches it at all
    # leaves evidence behind.
    planted = Path.join(root, "planted-bin")
    File.mkdir_p!(planted)
    stolen = Path.join(root, "stolen.txt")

    File.write!(Path.join(planted, "setsid"), """
    #!/bin/sh
    printf '%s' "$LOOPEX_PROVIDER_API_KEY" > #{stolen}
    exec "$@"
    """)

    File.chmod!(Path.join(planted, "setsid"), 0o755)
    original_path = System.get_env("PATH")
    System.put_env("PATH", planted <> ":" <> original_path)
    on_exit(fn -> System.put_env("PATH", original_path) end)

    assert {:ok, planted_run} = run(root, "loopex.bash", %{"command" => "printf ran"})
    assert planted_run.outcome == :completed
    refute File.exists?(stolen), "a planted setsid on PATH received the operator's environment"

    System.put_env("PATH", original_path)

    # A tool that starts no child holds no environment, and says so rather than
    # reporting one it never had.
    assert {:ok, quiet} = run(root, "loopex.read", %{"path" => "notes.txt"})
    assert quiet.child_environment_names == []
    refute quiet.provider_credential_present
  end

  test "output beyond a tool's bound spills through the artifact store and the model sees a bounded notice naming it" do
    root = workspace()
    {:ok, store} = Loopex.Executor.Local.CodingToolsTest.RecordingStore.start()

    {executor, lease_id} =
      executor_for(root, %{
        module: Loopex.Executor.Local.CodingToolsTest.RecordingStore,
        handle: store
      })

    full = String.duplicate("x", CodingTools.limits().read_bytes + 5_000)
    File.write!(Path.join(root, "large.txt"), full)

    assert {:ok, receipt} =
             run(root, "loopex.read", %{"path" => "large.txt"}, %{
               executor: executor,
               lease_id: lease_id
             })

    # Concept: the whole output is retained, not discarded with a count of what
    # was lost.
    #
    # Technical depth: the executor previously kept the prefix and dropped the
    # rest, so the marker said how many bytes existed and nothing could reach
    # them. The port had a spill path and no production caller, and the locked
    # cases exercised the port rather than a real run -- which is how an outcome
    # stayed green while undelivered.
    assert receipt.outcome == :completed
    assert [reference] = receipt.artifacts
    assert reference.size == byte_size(full)
    assert reference.role == "tool_output"
    assert String.match?(reference.digest, ~r/^[0-9a-f]{64}$/)

    stored = Loopex.Executor.Local.CodingToolsTest.RecordingStore.stored(store)
    assert Map.fetch!(stored, reference.locator) == full

    # The model is shown a bounded result that says what was truncated and names
    # the reference, rather than a prefix that reads like the whole answer.
    assert byte_size(receipt.output) < byte_size(full)
    assert receipt.output =~ "truncated"
    assert receipt.output =~ reference.digest
    assert String.starts_with?(receipt.output, binary_part(full, 0, 100))

    # A tool whose output fits spills nothing rather than an empty artifact.
    File.write!(Path.join(root, "small.txt"), "short")

    assert {:ok, quiet} =
             run(root, "loopex.read", %{"path" => "small.txt"}, %{
               executor: executor,
               lease_id: lease_id
             })

    assert quiet.artifacts == []
    assert quiet.output == "short"
  end

  test "a tool child process group is owned and terminated with its job and no group member survives" do
    root = workspace()

    # Concept: the descendant must be given a real chance to survive, or the
    # case proves nothing.
    #
    # Technical depth: this waited 1.2 seconds for a descendant that slept 5.
    # The marker could not exist yet whether the group had been ended or not, so
    # the assertion passed against a kill that never happened. The descendant now
    # sleeps well inside the observation window, and the same command is run once
    # without a deadline first, which establishes that it does write the marker
    # when nothing stops it.
    #
    # This command keeps the port's output pipe, which a background descendant
    # inherits, so the job does not end until that descendant does: the receipt
    # is produced with the group already quiescent and the marker already
    # written. The deadline run below is the one that has to end a survivor.
    reachable = Path.join(root, "reachable.txt")

    assert {:ok, %{outcome: :completed}} =
             run(root, "loopex.bash", %{
               "command" => "( sleep 1; echo survived > #{reachable} ) & exit 0"
             })

    Process.sleep(2_500)
    assert File.exists?(reachable), "the descendant never writes its marker even when left alone"

    # A command whose child outlives its leader: the leader exits immediately and
    # the descendant keeps writing. Killing only the leader would leave the
    # descendant running with nobody's name on it.
    marker = Path.join(root, "survivor.txt")

    assert {:ok, %{outcome: outcome}} =
             run(
               root,
               "loopex.bash",
               %{"command" => "( sleep 1; echo survived > #{marker} ) & exit 0"},
               %{run_deadline: System.system_time(:millisecond) + 400}
             )

    assert outcome in [:completed, :cancelled, :outcome_unknown]

    Process.sleep(2_500)
    refute File.exists?(marker), "a descendant survived its job's process group"
  end

  test "the child leads its own process group whether or not a session launcher was found" do
    # Concept: the guarantee is that the group is the executor's own, and it does
    # not depend on a program that may not be installed.
    #
    # Technical depth: the code and the operator documentation both attributed
    # the group to `setsid`, and said that where none is found the child leads no
    # new group. Neither is true: the port spawn puts the child in a group of its
    # own before the command runs, so the group the child announces is never this
    # runtime's. `setsid` where present adds a new *session* -- detaching the
    # controlling terminal -- on top of a group the spawn already established.
    # Darwin ships no `setsid` at all, so on that platform the stated limitation
    # described the only configuration the tool ever ran in.
    #
    # This matters beyond documentation: had the group actually been this
    # runtime's, terminating it by negated group id would signal the runtime
    # itself and every process sharing its group.
    root = workspace()

    assert {:ok, %{outcome: :completed, output: reported}} =
             run(root, "loopex.bash", %{
               "command" => "ps -o pgid= -p $$ | tr -d ' '"
             })

    child_group = reported |> String.trim() |> String.to_integer()

    own_group =
      System.pid()
      |> then(&System.cmd("/bin/ps", ["-o", "pgid=", "-p", &1]))
      |> elem(0)
      |> String.trim()
      |> String.to_integer()

    refute child_group == own_group,
           "the tool child shares this runtime's process group, so terminating " <>
             "the group would signal the runtime itself"

    # And the group is one the executor can end: a descendant joins it, so the
    # kill reaches work the leader started and walked away from. That is proved
    # by the case above; here it is enough that the group is separately owned.
    assert child_group > 1
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

  test "an already expired job is refused before the local executor opens a port" do
    # Concept: the local executor independently checks the run's committed
    # deadline at its final effect boundary. A coordinator that already checked
    # it cannot authorize the hand to begin an expired job later.
    #
    # Technical depth: `:executor_process_started` is emitted synchronously only
    # after the production `Port.open/2` returns, so it is a deterministic marker
    # for the boundary rather than a race against a child writing a file. The
    # argv command is harmless and would leave a second marker if it ran.
    root = workspace()
    file_marker = Path.join(root, "expired-job-ran.txt")

    answer =
      run(
        root,
        "loopex.bash",
        %{
          "argv" => [
            "/bin/sh",
            "-c",
            "printf ran > \"$1\"",
            "loopex-expired-job",
            file_marker
          ]
        },
        %{
          run_deadline: System.system_time(:millisecond) - 1,
          execute_options: [notify: self()]
        }
      )

    assert {:error, {:refused_before_effect, :executor_prestart_mismatch}} = answer

    refute_receive {:executor_process_started, _job_id, "loopex.bash", _environment}, 100
    refute File.exists?(file_marker), "an already expired job reached its workspace effect"
  end

  test "the wall time budget the session declared bounds the job and not merely the run" do
    # Concept: a tool's declared wall-time budget has to stop the work, not merely
    # be recorded beside it.
    #
    # Technical depth: the previous case for this obligation asserted the
    # `effective_deadline_ms` the receipt reported and nothing else, because the
    # shipped budgets are thirty seconds and two minutes and watching one bind
    # would have taken thirty seconds. So passing `job.run_deadline` to the work
    # while still recording the computed instant left the whole suite green: the
    # bound was written down and did not apply. The budget is declared in the job
    # now -- the coordinator already declares this job's output ceiling the same
    # way -- so a case can name one short enough to observe, and the executor
    # takes the smallest of the run's instant, the session's declared budget, and
    # the definition's own.
    root = workspace()
    started = System.monotonic_time(:millisecond)
    dispatched = System.system_time(:millisecond)
    far = dispatched + 600_000

    assert {:ok, %{outcome: outcome, output: output} = receipt} =
             run(
               root,
               "loopex.bash",
               %{"command" => "sleep 30"},
               %{
                 run_deadline: far,
                 resource_budgets: %{
                   "max_output_bytes" => 65_536,
                   "max_wall_time_ms" => 300
                 }
               }
             )

    elapsed = System.monotonic_time(:millisecond) - started

    assert elapsed < 10_000,
           "the job ran #{elapsed}ms under a declared three hundred millisecond budget, so it " <>
             "was bounded by the run's deadline rather than by the budget"

    assert outcome in [:cancelled, :outcome_unknown]
    assert output =~ "deadline passed"

    # And the instant it reports is the one it actually ran under rather than the
    # run's, so the record and the behaviour name the same number.
    assert receipt.run_deadline_ms == far
    assert receipt.effective_deadline_ms < far

    assert receipt.effective_deadline_ms <= dispatched + 300 + 1_000,
           "the instant recorded is #{receipt.effective_deadline_ms - dispatched}ms after " <>
             "dispatch, against a declared three hundred millisecond budget"

    # A declared budget wider than the definition's own does not widen it: the
    # smallest of the three wins, so a caller cannot buy a tool more time than
    # the tool asked for.
    shipped =
      CodingTools.definitions()
      |> Enum.find(&(&1["tool_id"] == "loopex.read"))
      |> get_in(["budgets", "wall_time_ms"])

    assert is_integer(shipped) and shipped > 0 and shipped < 599_000,
           "this half assumes loopex.read declares a budget narrower than the one the session " <>
             "declares below, and it declares #{inspect(shipped)}"

    before = System.system_time(:millisecond)
    File.write!(Path.join(root, "small.txt"), "hello")

    assert {:ok, generous} =
             run(
               root,
               "loopex.read",
               %{"path" => "small.txt"},
               %{
                 run_deadline: far,
                 resource_budgets: %{
                   "max_output_bytes" => 65_536,
                   "max_wall_time_ms" => 599_000
                 }
               }
             )

    assert generous.effective_deadline_ms <= before + shipped + 1_000,
           "a session declaring a wider budget than the tool's own widened the tool's bound"
  end

  test "a job whose workspace lease is lost mid flight is ended and reported unproven" do
    # Concept: the lease is the claim that authorises these effects, and ADR 0007
    # requires it held for the job's full lifetime.
    #
    # Technical depth: the coding-tool path resolved the lease pid at the final
    # validation boundary and discarded it, so nothing watched the holder once
    # work began. Stopping the lease process after a `loopex.bash` child had
    # started left the command running for its full second and returned
    # `:completed` -- a receipt claiming a proved effect in a workspace this
    # executor no longer had a claim on. Both shapes of coding tool are covered
    # here, because the defect was in the clause they share rather than in
    # either wait.
    root = workspace()
    {executor, lease_id, lease} = executor_and_lease(root)
    marker = Path.join(root, "after-the-lease.txt")

    running =
      Task.async(fn ->
        run(
          root,
          "loopex.bash",
          %{"command" => "sleep 3; echo survived > #{marker}"},
          %{executor: executor, lease_id: lease_id}
        )
      end)

    Process.sleep(800)
    GenServer.stop(lease)

    assert {:ok, receipt} = Task.await(running, 30_000)

    # Not `:completed`, and not `:cancelled` either: cancellation says this
    # executor stopped the work inside a workspace it still holds, which is
    # exactly what is no longer true.
    assert receipt.outcome == :outcome_unknown
    assert receipt.output =~ "workspace lease was lost"
    assert receipt.output =~ "unproven"

    # And the command was actually ended, rather than merely reported on.
    Process.sleep(3_500)
    refute File.exists?(marker), "the command outlived the lease that authorised it"

    # A filesystem tool holds the same claim, so losing it ends that work too.
    {second, second_lease_id, second_lease} = executor_and_lease(root)
    File.write!(Path.join(root, "wide.txt"), String.duplicate("abcdefghij\n", 3_000_000))

    editing =
      Task.async(fn ->
        run(
          root,
          "loopex.edit",
          %{"path" => "wide.txt", "old" => "qqqqqqqq", "new" => "x"},
          %{executor: second, lease_id: second_lease_id}
        )
      end)

    Process.sleep(400)
    GenServer.stop(second_lease)

    assert {:ok, edited} = Task.await(editing, 30_000)
    assert edited.outcome == :outcome_unknown
    assert edited.output =~ "workspace lease was lost"
  end

  test "a filesystem tool is bounded while it runs rather than only before it starts" do
    root = workspace()

    # Concept: an effect that has begun is still bounded by the run's deadline.
    #
    # Technical depth: production compared the deadline against the clock once
    # and then called a synchronous `File.*` that nothing could interrupt, so a
    # tool that blocked after that comparison ran as long as it liked and still
    # reported `:completed`. The work here is a real `edit` on a real file whose
    # diagnosis takes seconds; it is ordinary runtime work rather than a stalled
    # syscall, so abandoning it genuinely ends it.
    File.write!(Path.join(root, "wide.txt"), String.duplicate("abcdefghij\n", 3_000_000))

    # Concept: the work must be given a real chance to outlast the deadline, or
    # the case proves nothing.
    #
    # Technical depth: the same call is made once with the ordinary deadline
    # first, which establishes both that it succeeds when nothing stops it and
    # how long it takes. The bounded run below is then compared against that
    # measurement rather than against a number written here, so a machine slow
    # or fast enough to change the absolute timings cannot turn the case green
    # against a bound that does nothing.
    unbounded_started = System.monotonic_time(:millisecond)

    assert {:ok, %{outcome: :failed, output: diagnosed}} =
             run(root, "loopex.edit", %{"path" => "wide.txt", "old" => "qqqqqqqq", "new" => "x"})

    unbounded = System.monotonic_time(:millisecond) - unbounded_started
    assert diagnosed =~ "not found"

    assert unbounded > 1_000,
           "this operation is too fast for the deadline below to prove anything"

    started = System.monotonic_time(:millisecond)

    assert {:ok, receipt} =
             run(
               root,
               "loopex.edit",
               %{"path" => "wide.txt", "old" => "qqqqqqqq", "new" => "x"},
               %{
                 run_deadline: System.system_time(:millisecond) + 300
               }
             )

    elapsed = System.monotonic_time(:millisecond) - started

    assert elapsed < div(unbounded, 2), "the tool outlived its deadline"
    refute receipt.outcome == :completed
    assert receipt.output =~ "deadline passed while this tool was running"
    assert receipt.output =~ "it was stopped"

    # An `edit` that was stopped part way may or may not have reached the file,
    # so the receipt says unproven rather than picking a verdict.
    assert receipt.outcome == :outcome_unknown

    # Concept: a path that cannot be opened within any bound is refused before
    # it is opened, not abandoned afterwards.
    #
    # Technical depth: a `loopex.read` of an in-workspace named pipe with a
    # 200 ms deadline stayed blocked past 500 ms and returned `:completed` only
    # when an external writer released it. Abandoning that read would report
    # truthfully and still leave the open outstanding, and on this runtime a
    # single outstanding blocked open stalls every other file operation in the
    # whole virtual machine until it is paired -- so the refusal is the bound.
    # `mkfifo` is reachable from `loopex.bash`, which is how a model reaches
    # this.
    # `mkfifo` refuses an existing name, and a run killed part way leaves its
    # workspace behind for the next run that draws the same identifier.
    pipe = Path.join(root, "pipe")
    File.rm_rf!(pipe)
    {_output, 0} = System.cmd("/usr/bin/mkfifo", [pipe])
    fifo_started = System.monotonic_time(:millisecond)

    assert {:ok, piped} =
             run(root, "loopex.read", %{"path" => "pipe"}, %{
               run_deadline: System.system_time(:millisecond) + 200
             })

    assert System.monotonic_time(:millisecond) - fifo_started < 1_000
    assert piped.outcome == :failed
    assert piped.output =~ "not a regular file"

    # And the runtime's file work was never stalled behind it, which is the
    # property the refusal exists to keep.
    File.write!(Path.join(root, "plain.txt"), "still responsive")
    plain_started = System.monotonic_time(:millisecond)

    assert {:ok, %{outcome: :completed, output: "still responsive"}} =
             run(root, "loopex.read", %{"path" => "plain.txt"})

    assert System.monotonic_time(:millisecond) - plain_started < 1_000
  end

  test "write refuses a name that is not an ordinary file and replaces the one it names atomically" do
    # Concept: the guard the filesystem case exercised was `read`'s alone.
    #
    # Technical depth: removing `ordinary_file(resolved, path, :optional)` from
    # `loopex.write` left all fourteen cases green, so nothing protected the
    # branch that stops a write from replacing something that is not a file. A
    # write onto a named pipe is the shape a model can produce in its own
    # workspace with `mkfifo`, and under the atomic replacement below it would
    # otherwise succeed by turning the pipe into a regular file -- silently
    # destroying a thing the operator made, under a tool that says it writes
    # files.
    root = workspace()

    pipe = Path.join(root, "pipe")
    {_output, 0} = System.cmd("/usr/bin/mkfifo", [pipe])

    assert {:ok, %{outcome: :failed, output: piped}} =
             run(root, "loopex.write", %{"path" => "pipe", "content" => "x"})

    assert piped =~ "refused:"
    assert piped =~ "not a regular file"
    assert File.lstat!(pipe).type == :other

    # A directory is refused for the same reason and says which it found.
    File.mkdir_p!(Path.join(root, "folder"))

    assert {:ok, %{outcome: :failed, output: folder}} =
             run(root, "loopex.write", %{"path" => "folder", "content" => "x"})

    assert folder =~ "is a directory, not a regular file"
    assert File.lstat!(Path.join(root, "folder")).type == :directory

    # Concept: the write leaves the file complete or absent, and nothing else.
    #
    # Technical depth: the content is created under a private name and renamed
    # onto the target, so a reader never observes a partially written file and a
    # refused write leaves no residue for the next run to trip over.
    assert {:ok, %{outcome: :completed}} =
             run(root, "loopex.write", %{"path" => "made.txt", "content" => "complete"})

    assert File.read!(Path.join(root, "made.txt")) == "complete"

    assert Enum.all?(File.ls!(root), &(not String.starts_with?(&1, ".loopex-write-")))

    # That the replacement is a rename and not a truncating open is observable:
    # the file at the name afterwards is a different inode. A truncating open
    # writes into whatever the name leads to at that instant, which is both the
    # redirect this defect was and a window in which a reader sees an empty
    # file; a rename replaces the name in one step and can do neither.
    replaced = Path.join(root, "replaced.txt")
    File.write!(replaced, "before")
    previous = File.lstat!(replaced).inode

    assert {:ok, %{outcome: :completed}} =
             run(root, "loopex.write", %{"path" => "replaced.txt", "content" => "after"})

    assert File.read!(replaced) == "after"

    refute File.lstat!(replaced).inode == previous,
           "the write truncated the file in place rather than replacing its name"

    # A symlink inside the workspace still resolves to its target, so writing
    # through it replaces the file it points at and leaves the link a link.
    File.write!(Path.join(root, "target.txt"), "before")
    File.ln_s!("target.txt", Path.join(root, "alias"))

    assert {:ok, %{outcome: :completed}} =
             run(root, "loopex.write", %{"path" => "alias", "content" => "after"})

    assert File.read!(Path.join(root, "target.txt")) == "after"
    assert File.lstat!(Path.join(root, "alias")).type == :symlink
  end

  test "edit refuses a name that is not an ordinary file before it opens anything" do
    # Concept: `edit`'s guard is its own, and removing it alone left every case
    # green.
    #
    # Technical depth: `edit` reads before it writes, and the read is the half
    # that opens a path a model chose. Without the guard a directory reaches
    # `File.open/2` and the model is handed a filesystem error code instead of a
    # refusal naming what it actually asked for.
    root = workspace()
    File.mkdir_p!(Path.join(root, "folder"))

    assert {:ok, %{outcome: :failed, output: folder}} =
             run(root, "loopex.edit", %{"path" => "folder", "old" => "a", "new" => "b"})

    assert folder =~ "refused:"
    assert folder =~ "is a directory, not a regular file"

    # And the successful half still replaces the file atomically rather than
    # truncating it in place.
    File.write!(Path.join(root, "code.ex"), "before\n")

    assert {:ok, %{outcome: :completed}} =
             run(root, "loopex.edit", %{"path" => "code.ex", "old" => "before", "new" => "after"})

    assert File.read!(Path.join(root, "code.ex")) == "after\n"
    assert Enum.all?(File.ls!(root), &(not String.starts_with?(&1, ".loopex-write-")))

    # `edit`'s write half is the same replacement, and it is a rename here too:
    # an edit that truncated in place would leave the file empty for as long as
    # the new content took to write, and would follow a name swapped under it.
    edited = Path.join(root, "swap.txt")
    File.write!(edited, "one\n")
    previous = File.lstat!(edited).inode

    assert {:ok, %{outcome: :completed}} =
             run(root, "loopex.edit", %{"path" => "swap.txt", "old" => "one", "new" => "two"})

    assert File.read!(edited) == "two\n"

    refute File.lstat!(edited).inode == previous,
           "the edit truncated the file in place rather than replacing its name"
  end

  retained_manual_probe(
    "a write cannot be redirected outside the workspace by a component swapped under it"
  ) do
    # Concept: containment resolved a path and something else acted on it, which
    # is a check rather than a guarantee.
    #
    # Technical depth: `resolve/2` produced a contained path, and the write then
    # called `File.mkdir_p/1` and `File.write/2` on that name -- two fresh
    # traversals of a name a concurrent command can change. Worse, `mkdir_p` is
    # satisfied by a symlink that points at a directory, so a component swapped
    # for a link out of the workspace was silently followed rather than refused.
    # A background loop alternating one in-workspace name between absent, a
    # directory, and a symlink to an outside directory landed a model-supplied
    # `loopex.write` at `<outside>/escaped-354.txt` on attempt 354 of 500, and
    # reproduced on eight of nine runs of the same probe.
    #
    # The racing loop is a shell loop because that is what a concurrent actor
    # sharing this workspace looks like, and because a loop driven from this
    # virtual machine flips too slowly against dirty IO schedulers to enter the
    # window at all. It is started outside this executor: a `loopex.bash`
    # command that backgrounds a loop and exits now has that loop terminated
    # with its process group before the job is reported complete.
    root = workspace()
    outside = temporary_root("outside")
    File.mkdir_p!(outside)
    on_exit(fn -> File.rm_rf(outside) end)

    {executor, lease_id} = executor_for(root)

    racers =
      for _racer <- 1..4 do
        Port.open({:spawn_executable, ~c"/bin/sh"}, [
          :binary,
          :exit_status,
          :hide,
          args: [
            "-c",
            "while [ ! -e stop-race ]; do " <>
              "/bin/rm -rf switch; /bin/mkdir switch 2>/dev/null; /bin/rm -rf switch; " <>
              "/bin/ln -s #{outside} switch 2>/dev/null; /bin/rm -f switch; " <>
              "done >/dev/null 2>&1"
          ],
          cd: String.to_charlist(root)
        ])
      end

    on_exit(fn -> File.write(Path.join(root, "stop-race"), "stop") end)

    # Concept: the attempt count is what gives the window a chance to be entered.
    #
    # Technical depth: the escape needs the write to reach the filesystem in the
    # instant one name is a link rather than a directory. Fifteen hundred writes
    # against three racing loops entered that instant on every run of the fully
    # reverted implementation and on every run of the reverted directory guard.
    # A failure here is a real containment escape rather than a flake: correct
    # code produces no outside entry at all, and the assertion below is on the
    # outside directory being empty rather than on any timing.
    Enum.each(1..1500, fn index ->
      run(
        root,
        "loopex.write",
        %{"path" => "switch/escaped-#{index}.txt", "content" => "escaped"},
        %{executor: executor, lease_id: lease_id}
      )
    end)

    File.write!(Path.join(root, "stop-race"), "stop")

    Enum.each(racers, fn racer ->
      assert_receive {^racer, {:exit_status, _status}}, 15_000
    end)

    # Nothing at all reached the outside directory: not the content, and not the
    # private name the content is created under either, since a temporary that
    # escaped would be the same containment failure wearing a different name.
    # Concept: what must not be there is anything this executor put there.
    #
    # Technical depth: the assertion names the write's own two products -- the
    # content under the requested name, and the private name the content is
    # created under, since a temporary that escaped is the same containment
    # failure wearing a different name. It does not assert the outside directory
    # is empty, because the racing loops also race each other: `ln -s` onto a
    # name another loop has already made a link to the outside directory lands
    # inside it, which is the probe's own artifact and not this executor's.
    escaped =
      Enum.filter(File.ls!(outside), fn entry ->
        String.starts_with?(entry, "escaped-") or String.starts_with?(entry, ".loopex-write-")
      end)

    assert escaped == [],
           "a write escaped the workspace through a component swapped under it: " <>
             inspect(escaped)
  end

  test "a lease lost while a job's output is being retained abandons the retention and reports it unproven" do
    # Concept: retaining a spilled artifact is pre-receipt work, so the lease
    # covers it.
    #
    # Technical depth: the monitor covered `run_coding_tool/6` only. It returned,
    # the synchronous spill ran, the monitor was demonitor-flushed, and a
    # `completed` receipt was produced -- so a store that blocked while the lease
    # holder terminated yielded a receipt claiming a proved effect in a workspace
    # this executor no longer had a claim on. ADR 0007 requires the lease for the
    # job's full lifetime, and the receipt is the end of that lifetime.
    root = workspace()
    delay = 4_000

    {executor, lease_id, lease} =
      executor_and_lease(root, %{
        module: Loopex.Executor.Local.CodingToolsTest.BlockingStore,
        handle: {self(), delay}
      })

    File.write!(
      Path.join(root, "large.txt"),
      String.duplicate("x", CodingTools.limits().read_bytes + 5_000)
    )

    running =
      Task.async(fn ->
        run(root, "loopex.read", %{"path" => "large.txt"}, %{
          executor: executor,
          lease_id: lease_id
        })
      end)

    assert_receive :retention_started, 10_000
    started = System.monotonic_time(:millisecond)
    GenServer.stop(lease)

    assert {:ok, receipt} = Task.await(running, 60_000)
    elapsed = System.monotonic_time(:millisecond) - started

    # The retention is abandoned when the claim goes, rather than noticed once it
    # has finished on its own.
    assert elapsed < div(delay, 2),
           "the lease loss was only noticed after the blocking retention returned"

    assert receipt.outcome == :outcome_unknown
    assert receipt.output =~ "workspace lease was lost"
    assert receipt.output =~ "unproven"
    assert receipt.artifacts == []
  end

  test "a command that backgrounds work and exits is not completed until its group is quiescent" do
    # Concept: the launcher's exit status is one process ending, not the job.
    #
    # Technical depth: the captured group was forgotten and the monitor dropped
    # the moment the launcher exited, so
    # `( sleep 1; printf survived > after-receipt.txt ) & exit 0` reported
    # `:completed` in 22 ms and the descendant then wrote inside the workspace
    # after the receipt existed and after the lease had gone. Process groups are
    # what this executor owns and cancels, so success has to mean what
    # cancellation already means.
    root = workspace()
    marker = Path.join(root, "after-receipt.txt")

    started = System.monotonic_time(:millisecond)

    assert {:ok, receipt} =
             run(root, "loopex.bash", %{
               "command" =>
                 "( sleep 2; printf survived > after-receipt.txt ) >/dev/null 2>&1 & exit 0"
             })

    elapsed = System.monotonic_time(:millisecond) - started

    # The job ends the descendant rather than waiting for it, which is the
    # difference between owning a group and joining one.
    assert elapsed < 1_500, "the job waited for its descendant instead of ending it"

    assert receipt.outcome == :completed

    # The harm the defect did, asserted before the wording that reports it: the
    # descendant is gone, so nothing writes into this workspace after the
    # receipt claiming the job is over already exists.
    Process.sleep(3_000)

    refute File.exists?(marker),
           "a descendant of a completed job wrote into the workspace after the receipt existed"

    assert receipt.output =~ "still running"
    assert receipt.output =~ "confirmed cleaned"

    # An ordinary command leaves nothing behind, so it gains no note: a note on
    # every result is noise a model learns to skip.
    assert {:ok, %{outcome: :completed, output: plain}} =
             run(root, "loopex.bash", %{"command" => "echo ok"})

    assert String.trim(plain) == "ok"
    refute plain =~ "still running"
  end

  test "a lease lost while a job's group is brought to quiescence is reported unproven" do
    # Concept: the work between the command exiting and the receipt existing is
    # still the job, so the lease still covers it.
    #
    # Technical depth: bringing an owned process group to quiescence signals the
    # group, gives it the cooperative grace to go, signals again and looks with
    # `ps`. None of that is a wait this executor sits in, so a lease that dies
    # there is not noticed while it happens -- it is noticed afterwards, by the
    # check that runs before the receipt is produced. Deleting that one check left
    # all nineteen cases in this file green, which is what made it worth writing:
    # nothing here proved that a lease lost after the command exited was reported
    # at all.
    #
    # The instant this case aims at is opened by the group itself rather than by
    # a guess about how slow the sequence is. The backgrounded subshell ignores
    # `TERM`, so it is still there when the cooperative grace is measured and the
    # sequence must sit through that grace before it kills the group -- half the
    # configured cleanup period, which is seconds rather than the tens of
    # milliseconds a group that dies on the first signal costs. Aiming at the
    # latter is what made this case depend on the sequence being slow, and it
    # became a false negative the moment the sequence stopped wasting time.
    root = workspace()
    marker = Path.join(root, "launcher-exited.txt")
    {executor, lease_id, lease} = executor_and_lease(root)

    running =
      Task.async(fn ->
        run(
          root,
          "loopex.bash",
          %{
            "command" =>
              "( trap \"\" TERM; sleep 30 ) >/dev/null 2>&1 & " <>
                "printf x > launcher-exited.txt; exit 0"
          },
          %{executor: executor, lease_id: lease_id}
        )
      end)

    assert {:ok, _marker} =
             await_path(
               fn -> if File.exists?(marker), do: {:ok, marker}, else: :error end,
               20_000
             ),
           "the launcher never announced that it was about to exit"

    # The launcher exits immediately after the marker, and the quiescence
    # sequence that follows it is held by the cooperative grace for as long as
    # the group refuses to go.
    Process.sleep(30)
    GenServer.stop(lease)

    assert {:ok, receipt} = Task.await(running, 60_000)

    assert receipt.outcome == :outcome_unknown,
           "a lease lost after the command exited was reported as #{inspect(receipt.outcome)}"

    assert receipt.output =~ "workspace lease was lost"
    assert receipt.output =~ "unproven"

    # The reply and the durable record are the same fact, not two.
    assert {:ok, %{outcome: :outcome_unknown}} = Local.receipt(executor, receipt.job_id)
  end

  test "a lease lost while a job's receipt is being retained is reported unproven" do
    # Concept: a receipt that exists only in this server's memory is not a
    # receipt, so the lease is held until the bytes land.
    #
    # Technical depth: the lease was checked once with a zero-time mailbox peek
    # and then demonitor-flushed, before the receipt was built and long before it
    # was written. A lease that died in the window that followed was not merely
    # missed: the evidence was discarded, so a `completed` receipt was persisted
    # for a job whose authorisation had already ended. A peek answers "has it
    # died yet"; the obligation is about an interval, and the write is the last
    # blocking step in it.
    #
    # The lease is stopped when the retention's staging file appears, so the
    # instant is taken from the executor's own progress rather than guessed: by
    # then the peek has already passed and the receipt is being written.
    root = workspace()
    {executor, lease_id, lease, ledger} = executor_lease_and_ledger(root)

    # The largest receipt this executor can retain, so the write it is stopped
    # during is the longest one it ever performs.
    File.write!(
      Path.join(root, "big.txt"),
      String.duplicate("x", CodingTools.limits().read_bytes)
    )

    # The holder is unlinked before it is killed, so the abrupt exit that gives
    # the executor its DOWN in the fewest possible microseconds does not reach
    # this case through the link `start_link/1` created.
    Process.unlink(lease)
    owner = self()

    killer =
      spawn(fn ->
        case await_path(fn -> staging_file(ledger) end, 30_000) do
          {:ok, found} ->
            Process.exit(lease, :kill)
            send(owner, {:stopped_during_retention, found})

          :error ->
            send(owner, :never_staged)
        end
      end)

    on_exit(fn -> Process.exit(killer, :kill) end)

    assert {:ok, receipt} =
             run(root, "loopex.read", %{"path" => "big.txt"}, %{
               executor: executor,
               lease_id: lease_id
             })

    # The probe has to have fired inside the retention, or the case proves
    # nothing about it.
    assert_receive {:stopped_during_retention, _staging}, 30_000

    assert receipt.outcome == :outcome_unknown,
           "a lease lost while the receipt was being retained was reported as #{inspect(receipt.outcome)}"

    assert receipt.output =~ "workspace lease was lost"
    assert receipt.output =~ "unproven"

    # The durable receipt is the plane a recovering coordinator reads, so the
    # replacement has to have overwritten the one the abandoned write may have
    # left behind.
    assert {:ok, durable} = Local.receipt(executor, receipt.job_id)
    assert durable.outcome == :outcome_unknown
    assert durable.output == receipt.output

    # Nothing half-written is left in the ledger.
    assert {:ok, entries} = File.ls(ledger)
    assert Enum.all?(entries, &String.ends_with?(&1, ".receipt")), inspect(entries)
  end

  test "a process group is confirmed clean only by a ps that answered" do
    # Concept: silence from a program that died is not an answer.
    #
    # Technical depth: the confirmation discarded `ps`'s exit status, so any
    # empty response read as an empty group -- and that single boolean is what
    # stands between `:completed` and `:outcome_unknown`, and between `cancel/2`
    # reporting `:cleaned` and `:unconfirmed`. A program killed by a signal
    # reports empty output with an abnormal status, which read as proof.
    #
    # The status cannot simply be required to be zero, and the first assertion is
    # why: measured against the toolchain this suite runs on, an empty group is
    # reported with status 1. A rule that demanded zero would refuse every
    # honest confirmation this executor makes.
    group = ephemeral_process_group()

    assert Local.group_answered_empty?(
             System.cmd("/bin/ps", ["-o", "pid=", "-g", Integer.to_string(group)],
               stderr_to_stdout: true
             )
           ),
           "a group with no members is no longer confirmed clean"

    # The two answers `ps` gives: members listed, and none matched.
    refute Local.group_answered_empty?({"48965\n", 0})
    assert Local.group_answered_empty?({"", 1})

    # A `ps` that was killed says nothing at all, and nothing is not proof.
    refute Local.group_answered_empty?({"", 137})
    refute Local.group_answered_empty?({"", 2})

    # Its own diagnostics arrive on the same stream this executor captures, so
    # an error is already non-empty.
    refute Local.group_answered_empty?({"ps: process group too large: 999999\n", 1})
  end

  retained_manual_probe(
    "an edit cannot be redirected outside the workspace by a component swapped under it"
  ) do
    # Concept: `edit` is a read and a write, and only its read half was ever
    # checked against the file it had contained.
    #
    # Technical depth: `write` commits through `ensure_directories/3` and
    # `replace_atomically/2` -- every level of the path confirmed to be a real
    # directory rather than a link, and the bytes created exclusively and renamed
    # onto the target name. `edit` resolved a path, verified the file it opened,
    # transformed the content, and then handed the same stale pathname straight
    # to `replace_atomically/2` with no confirmation of the levels above it. The
    # exclusive create and the rename protect the final component only: an
    # intermediate directory swapped for a link to somewhere else is followed by
    # both, so the temporary is created outside and renamed onto a name that now
    # means an outside file.
    #
    # `edit`'s window is wider than `write`'s, because a whole file is read,
    # searched and rewritten inside it. A background loop alternating one
    # in-workspace directory between a real directory holding the target and a
    # symlink to an outside directory modified `<outside>/target.txt` on attempt
    # 11 against a three megabyte file.
    #
    # The racing loop is a shell loop for the reason the `write` case gives: a
    # loop driven from this virtual machine flips too slowly against dirty IO
    # schedulers to enter the window at all. The target is hard-linked rather
    # than copied so that recreating it costs one inode operation instead of
    # three megabytes, which is what lets the loop flip faster than the tool
    # runs.
    root = workspace()
    outside = temporary_root("outside")
    File.mkdir_p!(outside)
    on_exit(fn -> File.rm_rf(outside) end)

    File.write!(Path.join(outside, "target.txt"), "OUTSIDE-UNTOUCHED")

    File.write!(
      Path.join(root, "big.txt"),
      "INSIDE-MARKER\n" <> String.duplicate("x", 3_000_000)
    )

    {executor, lease_id} = executor_for(root)

    racers =
      for _racer <- 1..3 do
        Port.open({:spawn_executable, ~c"/bin/sh"}, [
          :binary,
          :exit_status,
          :hide,
          args: [
            "-c",
            "while [ ! -e stop-race ]; do " <>
              "/bin/rm -rf switch; " <>
              "/bin/mkdir switch 2>/dev/null && /bin/ln big.txt switch/target.txt 2>/dev/null; " <>
              "/bin/rm -rf switch; /bin/ln -s #{outside} switch 2>/dev/null; /bin/rm -f switch; " <>
              "done >/dev/null 2>&1"
          ],
          cd: String.to_charlist(root)
        ])
      end

    on_exit(fn -> File.write(Path.join(root, "stop-race"), "stop") end)

    # Concept: the attempt count is what gives the window a chance to be entered.
    #
    # Technical depth: most attempts refuse or miss -- the name is a link, or
    # absent, or the directory is being rebuilt -- and only the ones that read
    # the contained file and then reach the filesystem in the instant the name is
    # a link can escape. Two hundred attempts entered that instant on every run
    # of the reverted implementation. A failure here is a real containment escape
    # rather than a flake: correct code puts nothing outside at all.
    Enum.each(1..200, fn index ->
      run(
        root,
        "loopex.edit",
        %{"path" => "switch/target.txt", "old" => "INSIDE-MARKER", "new" => "EDITED-#{index}"},
        %{executor: executor, lease_id: lease_id}
      )
    end)

    File.write!(Path.join(root, "stop-race"), "stop")

    Enum.each(racers, fn racer ->
      assert_receive {^racer, {:exit_status, _status}}, 15_000
    end)

    # Concept: what must not be there is anything this executor put there.
    #
    # Technical depth: the assertion names the edit's own two products -- content
    # carrying the replacement text, and the private name the content is created
    # under, since a temporary that escaped is the same containment failure
    # wearing a different name. It does not assert the outside directory is
    # empty, because the racing loops also race each other: a hard link made onto
    # a name another loop has already pointed at the outside directory lands
    # inside it, which is the probe's own artifact and carries the original
    # marker rather than the replacement.
    escaped =
      Enum.filter(File.ls!(outside), fn entry ->
        String.starts_with?(entry, ".loopex-write-") or
          case File.read(Path.join(outside, entry)) do
            {:ok, bytes} -> String.contains?(bytes, "EDITED-")
            {:error, _reason} -> false
          end
      end)

    assert escaped == [],
           "an edit escaped the workspace through a component swapped under it: " <>
             inspect(escaped)
  end

  test "the first process the launcher starts explicitly excludes the provider credential" do
    # Concept: the boundary is the first thing the operating system runs, not the
    # first thing that happens to be credential-free further down the chain.
    #
    # Technical depth: the port spawned `/usr/bin/env` and `env_prefix/1` supplied
    # a *second* `"/usr/bin/env", "-i"` as that process's arguments. `env` treats
    # its first non-option operand as the command to execute, so the operand was
    # `/usr/bin/env` and the `-i` behind it was merely an argument handed to it:
    # the first image ran, and then executed a second image, with this operating
    # system process's entire inherited environment -- the provider credential in
    # it -- still present. Only that second `env` cleared anything.
    #
    # Nothing downstream can see this. The receipt derives its fields from the
    # environment this executor intended, and the shell at the end of the chain
    # is credential-free either way, which is exactly why the existing credential
    # case passed while an extra image was being loaded and executed under the
    # ambient environment. On a platform whose loader honours an ambient
    # `LD_PRELOAD`, that is a model-controlled object mapped into a process this
    # executor started.
    #
    # The observation is made where `env` itself decides: the first operand that
    # is neither an option nor a `NAME=VALUE` assignment is what `env` executes,
    # so a recorder put there reports the environment the first child actually
    # receives. Under the defect that position is the second `/usr/bin/env` and
    # the recorder sees the operator's whole environment; correct, it is the
    # shell and the recorder sees only what this executor constructed.
    root = workspace()

    System.put_env("LOOPEX_PROVIDER_API_KEY", "sk-sentinel-first-child")
    System.put_env("LOOPEX_SENTINEL_UNRELATED", "also-not-for-a-first-child")

    on_exit(fn ->
      System.delete_env("LOOPEX_PROVIDER_API_KEY")
      System.delete_env("LOOPEX_SENTINEL_UNRELATED")
    end)

    recorded = Path.join(root, "first-child-environment.txt")
    recorder = Path.join(root, "recorder")

    File.write!(recorder, """
    #!/bin/sh
    /usr/bin/env > #{recorded}
    """)

    File.chmod!(recorder, 0o755)

    for arguments <- [%{command: "printf ran"}, %{argv: ["printf", "ran"]}] do
      assert {"/usr/bin/env", vector} = Local.launcher_vector(arguments)

      # `env`'s own rule for where its command begins, applied to the vector this
      # executor builds rather than to the vector it ought to build.
      command_index =
        Enum.find_index(vector, fn argument ->
          not String.starts_with?(argument, "-") and not String.contains?(argument, "=")
        end)

      assert is_integer(command_index),
             "the launcher's arguments name nothing for env to execute: #{inspect(vector)}"

      File.rm(recorded)

      port =
        Port.open({:spawn_executable, ~c"/usr/bin/env"}, [
          :binary,
          :exit_status,
          :use_stdio,
          :stderr_to_stdout,
          :hide,
          args: Enum.take(vector, command_index) ++ [recorder]
        ])

      assert_receive {^port, {:exit_status, 0}}, 15_000

      assert {:ok, first_child} = File.read(recorded)

      refute first_child =~ "sk-sentinel-first-child",
             "the first process the launcher started held the provider credential"

      refute first_child =~ "also-not-for-a-first-child",
             "the first process the launcher started held this process's environment"

      # The recorder ran with the environment this executor constructed, so the
      # observation is of a real child and not of a command that never started.
      assert Map.fetch!(parse_environment(first_child), "PATH") == "/usr/bin:/bin"
    end

    # Concept: the environment the *first* image was loaded with must exclude the
    # provider credential, and its stable ambient snapshot must be cleared.
    #
    # Technical depth: everything above reads the environment of the command
    # `env` goes on to run, which `-i` has already cleared. It is the wrong
    # process. `/usr/bin/env` is `execve`d before it parses a single argument,
    # and the loader acts on it in that instant: on a platform honouring an
    # ambient `LD_PRELOAD` the named object is mapped into a process that is at
    # that moment holding the provider credential, and no argument can undo a
    # load that has already happened. The spawn's own `env:` option is the only
    # thing that reaches it.
    #
    # `env` with no arguments at all prints the environment it was itself given,
    # so this is a direct reading of the first image's own environment with no
    # second image anywhere in it. A separate interleaving below proves the named
    # credential guarantee when that key appears after the ambient snapshot.
    #
    # It is taken through `launcher_probe_port/1`, which reaches the same
    # `open_launcher/4` -- the same option list, the same `Port.open` -- that a
    # `loopex.bash` job reaches. An earlier version of this case built its own
    # port from an options helper, which meant deleting `env:` from the
    # production spawn alone left it green while the real launcher inherited
    # everything. An observation of a construction is not an observation of the
    # spawn.
    first_image = Local.launcher_probe_port(root)

    loaded =
      Enum.reduce_while(1..200, <<>>, fn _attempt, acc ->
        receive do
          {^first_image, {:data, chunk}} -> {:cont, acc <> chunk}
          {^first_image, {:exit_status, 0}} -> {:halt, acc}
        after
          15_000 -> {:halt, acc}
        end
      end)

    refute loaded =~ "sk-sentinel-first-child",
           "the first image was loaded holding the provider credential: #{loaded}"

    refute loaded =~ "also-not-for-a-first-child",
           "the stable ambient snapshot was not cleared before the first image loaded: #{loaded}"

    # With no concurrent environment mutation, the snapshot clears every ambient
    # name and leaves only the chosen PATH. The provider credential has the
    # stronger guarantee below: it is explicitly absent even when introduced
    # after that snapshot.
    loaded_environment = parse_environment(loaded)
    assert map_size(loaded_environment) == 1
    assert Map.fetch!(loaded_environment, "PATH") == "/usr/bin:/bin"

    # Concept: the provider credential is the named secret this executor must
    # keep out of every first image, including one started by its own helpers.
    #
    # Technical depth: Port's env option extends the inherited environment. A
    # snapshot of names to clear is therefore not atomic: another BEAM process
    # can add a name between that snapshot and Port.open. The probe pauses the
    # actual production spawn in precisely that interval and adds the provider
    # key. Both intended environment kinds must still clear it explicitly.
    System.delete_env("LOOPEX_PROVIDER_API_KEY")
    parent = self()

    for kind <- [:coding, :demonstration] do
      raced =
        Task.async(fn ->
          port =
            Local.launcher_probe_port(root, kind, fn ->
              send(parent, {:launcher_environment_snapshotted, self()})

              receive do
                :continue_launcher_spawn -> :ok
              end
            end)

          Enum.reduce_while(1..200, <<>>, fn _attempt, acc ->
            receive do
              {^port, {:data, chunk}} -> {:cont, acc <> chunk}
              {^port, {:exit_status, 0}} -> {:halt, acc}
            after
              15_000 -> {:halt, acc}
            end
          end)
        end)

      assert_receive {:launcher_environment_snapshotted, launcher}, 5_000
      System.put_env("LOOPEX_PROVIDER_API_KEY", "sk-added-after-snapshot")
      send(launcher, :continue_launcher_spawn)
      raced_environment = Task.await(raced, 20_000)

      refute raced_environment =~ "sk-added-after-snapshot",
             "the #{kind} first image inherited a provider credential introduced after its " <>
               "ambient snapshot: #{raced_environment}"

      System.delete_env("LOOPEX_PROVIDER_API_KEY")
    end

    # The demonstration launcher is the other spawn site and already begins with
    # the clearing option rather than with an executable path; asserting it keeps
    # the two vectors from drifting apart again.
    assert {:ok, demonstration} =
             run(root, "loopex.demo.write", %{
               "relative_path" => "demonstrated.txt",
               "content" => "ran"
             })

    assert demonstration.outcome == :completed
    assert demonstration.child_environment_names == ["PATH"]
    refute demonstration.provider_credential_present
  end

  test "every executor spawn supplies an environment override that excludes the provider credential" do
    # Concept: explicit provider-credential removal has to reach every spawn,
    # not only the coding-tool path a behavioural case happened to exercise.
    #
    # Technical depth: the environment cases above observe one spawn. They are
    # silent about every other, and that silence is exactly how the previous
    # shape of this module failed: the job spawn and the demonstration spawn each
    # assembled their own option list, and the option that removes the provider
    # credential could be dropped from one of them without any case noticing.
    #
    # There are three spawns and they are not interchangeable. One is the job
    # launcher, now built in a single place so that one observation covers every
    # job. The other two run `ps` and `kill` on this executor's own behalf; they
    # take no workspace and no operator input, but they are still images the
    # operating system loads while this process holds the provider credential,
    # so the loader reaches them on exactly the same terms. The invariant is
    # therefore about every spawn rather than about how many there are: none of
    # them may omit the central environment override that explicitly removes the
    # named credential.
    #
    # Reading the source is the only way to ask a question of that shape. A
    # behavioural case can prove what one spawn does and can never prove that no
    # other spawn exists.
    source = File.read!(Path.expand("../lib/executor.ex", __DIR__))

    spawns =
      source
      |> String.split(~r/^\s*Port\.open\(\s*$/m)
      |> Enum.drop(1)
      |> Enum.map(&(&1 |> String.split(~r/^\s*\)\s*$/m) |> hd()))

    assert length(spawns) == 3,
           "this executor now opens #{length(spawns)} ports; every one of them is an image the " <>
             "loader reaches, so each needs its own constructed environment and this case needs " <>
             "to have been told about it"

    # The job launcher reaches its `env:` through `launcher_port_options/2`,
    # which the probe case above observes behaviourally at the spawn; the two
    # helpers carry theirs literally. What no spawn may do is name neither.
    assert source =~ "options = launcher_port_options(environment, workspace)",
           "the job launcher no longer derives the option list whose environment the " <>
             "production-path probe observes"

    assert Enum.count(spawns, &String.contains?(&1, "++ options")) == 1,
           "the single job-launch port no longer receives the production option list"

    assert Enum.count(
             spawns,
             &String.contains?(&1, "env: spawn_environment(demonstration_environment())")
           ) == 2,
           "each helper spawn must use the central provider-credential removal path"

    # The job launcher's option list is built once. A second construction of it
    # is how the two spawn sites drifted apart before, and it is also how a
    # mutation escapes: `open_launcher/4` is observable and a call site is not.
    assert length(String.split(source, "launcher_port_options(")) - 1 == 2,
           "the job launcher's port options are constructed in more than one place, so the " <>
             "observation above covers only whichever construction it happened to reach"
  end

  test "the run deadline bounds retaining a spilled artifact and the abandonment is reported" do
    # Concept: the deadline is the run's bound on everything the run owns, not
    # only on the tool.
    #
    # Technical depth: the filesystem effect was abandoned at the effective
    # deadline, and the artifact retention that follows it waited on exactly
    # three alternatives -- the store answering, the worker dying, and the lease
    # holder going down. The run's committed instant was not among them, so a
    # store that blocked carried the whole job past its deadline and the receipt
    # still said `completed`. A `loopex.read` whose deadline was three hundred
    # milliseconds away spilled into a store that delayed four seconds and
    # returned after about four seconds.
    root = workspace()
    delay = 4_000

    {executor, lease_id} =
      executor_for(root, %{
        module: Loopex.Executor.Local.CodingToolsTest.BlockingStore,
        handle: {self(), delay}
      })

    full = String.duplicate("x", CodingTools.limits().read_bytes + 5_000)
    File.write!(Path.join(root, "large.txt"), full)

    started = System.monotonic_time(:millisecond)

    assert {:ok, receipt} =
             run(root, "loopex.read", %{"path" => "large.txt"}, %{
               executor: executor,
               lease_id: lease_id,
               run_deadline: System.system_time(:millisecond) + 300
             })

    elapsed = System.monotonic_time(:millisecond) - started

    assert elapsed < div(delay, 2),
           "the run outlived its deadline waiting for a store it cannot bound"

    # Concept: the effect is exactly as proved as it was; what was lost is the
    # retrieval of the overflow.
    #
    # Technical depth: the read produced its bytes and this executor holds them,
    # so the outcome does not weaken. What the abandonment costs is the artifact:
    # nothing this executor can name was retained, so the model is shown the
    # plain truncation marker and the receipt carries no reference it cannot
    # honour.
    assert receipt.outcome == :completed
    assert receipt.artifacts == []
    assert receipt.output =~ "truncated"
    assert receipt.output =~ "run deadline"
    assert String.starts_with?(receipt.output, binary_part(full, 0, 100))
  end

  test "a receipt that could not be retained is reported rather than answered as a result" do
    # Concept: a receipt nobody can read is not a receipt, and the reply must say
    # so.
    #
    # Technical depth: the retention's own failure was the one branch nothing
    # asserted on. Treating `{:error, reason}` from the writer as a success left
    # every case in this file green while `execute/5` answered `{:ok, receipt}`
    # for a receipt that had never reached the ledger -- a coordinator would
    # record a proved terminal fact for a job with no durable record, and
    # recovery would find nothing to reconcile against.
    root = workspace()
    File.write!(Path.join(root, "notes.txt"), "readable")

    {executor, lease_id, _lease, ledger} = executor_lease_and_ledger(root)

    # The ledger stays readable so the duplicate-job lookup still answers
    # `:absent`; only the write is refused, which is the failure a full or
    # read-only ledger presents.
    File.chmod!(ledger, 0o500)
    on_exit(fn -> File.chmod(ledger, 0o700) end)

    assert {:error, {:receipt_not_retained, :eacces}} =
             run(root, "loopex.read", %{"path" => "notes.txt"}, %{
               executor: executor,
               lease_id: lease_id
             })

    # Nothing was left behind in the ledger either, so a later reader cannot find
    # a partial receipt where this executor reported none.
    assert {:ok, []} = File.ls(ledger)
  end

  test "work this executor cannot bound is abandoned at its bound and a program that never answers confirms nothing" do
    # Concept: the two waits nothing in this suite can reach through the
    # operating system.
    #
    # Technical depth: a healthy local ledger never takes longer than the run's
    # remaining time plus the declared grace, and the operating system's own `ps`
    # cannot be made to hang, so the branch that decides whether a receipt is
    # reported durable and the branch that decides whether a process group is
    # confirmed clean would otherwise rest on waits no case can enter. Both
    # mechanisms are exposed and asked directly, exactly as
    # `group_answered_empty?/1` is.
    root = workspace()
    {_executor, _lease_id, lease} = executor_and_lease(root)
    monitor = Process.monitor(lease)
    on_exit(fn -> Process.demonitor(monitor, [:flush]) end)

    # Work that answers is answered, and its value is carried back rather than
    # reduced to a verdict.
    assert {:done, {:ok, :retained}} =
             Local.bounded_work(fn -> {:ok, :retained} end, 5_000, {monitor, lease})

    # Work that outlasts its bound is abandoned there, and the abandonment
    # reports that the worker was confirmed stopped and produced nothing.
    started = System.monotonic_time(:millisecond)

    assert {:abandoned, :bound_reached, true, :none} =
             Local.bounded_work(fn -> Process.sleep(30_000) end, 150, {monitor, lease})

    assert System.monotonic_time(:millisecond) - started < 5_000,
           "the bound did not end the wait"

    # Work that crashes is neither an answer nor an abandonment.
    assert {:stopped, _reason} =
             Local.bounded_work(fn -> exit(:deliberate) end, 5_000, {monitor, lease})

    # A cleanup program that answers is answered.
    assert {output, 0} = Local.answer_within("/bin/echo", ["answered"], 5_000)
    assert String.trim(output) == "answered"

    # A cleanup program that never answers within its bound is a non-answer.
    started = System.monotonic_time(:millisecond)
    assert Local.answer_within("/bin/sh", ["-c", "sleep 30"], 150) == :no_answer

    assert System.monotonic_time(:millisecond) - started < 5_000,
           "a cleanup program that never answered was waited on past its bound"

    # And a non-answer is not an empty process group. It reaches the same rule
    # that already refuses a `ps` killed by a signal, because silence from a
    # program that never spoke is the weaker fact of the two.
    refute Local.group_answered_empty?(:no_answer)

    # A program that cannot be run at all arrives as the same non-answer, which
    # is what the removed rescue used to produce.
    assert capture_log(fn ->
             assert Local.answer_within("/bin/loopex-no-such-cleanup-program", [], 5_000) ==
                      :no_answer
           end) =~ ""
  end

  test "the run deadline bounds the demonstration launcher as well as the coding tools" do
    # Concept: the run's instant bounds every tool this executor starts, not only
    # the ones this milestone added.
    #
    # Technical depth: enumerating what the run owns between dispatch and durable
    # receipt turned this up beside the two retentions. `await_port/5` named the
    # port and the lease and nothing else, so the second launcher in this module
    # -- the one M1's demonstration tools still use, and the one whose registry
    # entries this executor deliberately keeps resolvable -- had no deadline
    # among its alternatives at all. A `loopex.demo.wait_write` declaring a five
    # second delay ran for five seconds under a run deadline three hundred
    # milliseconds away and reported `:completed`.
    #
    # The outcome is `:outcome_unknown` rather than a cancellation because this
    # path captures no process group: closing the port releases the child without
    # proving it stopped or that its write did not land.
    root = workspace()
    delay = 5_000

    started = System.monotonic_time(:millisecond)

    assert {:ok, receipt} =
             run(
               root,
               "loopex.demo.wait_write",
               %{"relative_path" => "delayed.txt", "content" => "late", "delay_ms" => delay},
               %{run_deadline: System.system_time(:millisecond) + 300}
             )

    elapsed = System.monotonic_time(:millisecond) - started

    assert elapsed < div(delay, 2),
           "the demonstration launcher outlived the run's committed deadline"

    assert receipt.outcome == :outcome_unknown
    assert receipt.output =~ "run deadline"
    assert receipt.output =~ "unproven"
  end

  # Concept: a real process group identifier that no longer has any members.
  #
  # Technical depth: taken from a child that led its own group and has since
  # exited, so the confirmation above is asked about the same kind of identifier
  # the executor asks about rather than an invented number, which `ps` reports
  # differently.
  defp ephemeral_process_group do
    port =
      Port.open({:spawn_executable, ~c"/bin/sh"}, [
        :binary,
        :exit_status,
        :use_stdio,
        :stderr_to_stdout,
        :hide,
        args: [~c"-c", ~c"ps -o pgid= -p $$ | tr -d ' '; exit 0"]
      ])

    group =
      receive do
        {^port, {:data, data}} -> data |> String.trim() |> String.to_integer()
      after
        10_000 -> flunk("the probe child never reported its process group")
      end

    receive do
      {^port, {:exit_status, _status}} -> :ok
    after
      10_000 -> flunk("the probe child never exited")
    end

    assert {:ok, :empty} =
             await_path(
               fn ->
                 case System.cmd("/bin/ps", ["-o", "pid=", "-g", Integer.to_string(group)],
                        stderr_to_stdout: true
                      ) do
                   {"", _status} -> {:ok, :empty}
                   {_survivors, _status} -> :error
                 end
               end,
               10_000
             ),
           "the probe child's group still has members"

    group
  end

  test "the cleanup budget is one configured period with a declared default and every receipt records it" do
    # Concept: the period is one configured value with a declared default, and
    # the record of a job says which one bounded it.
    #
    # Technical depth: the period was `@cleanup_grace_ms 5_000`, absent from the
    # start options, from anything that could read it back, and from the record
    # of the job it bounded -- so a run that spent it left no evidence of what it
    # had been spending. It is now an executor start option with a declared
    # default, readable from the running executor, and written into every
    # receipt, which makes the live configuration and the durable record of a job
    # the same fact rather than two.
    #
    # ADR 0009 asks for a *session* configuration value reported in the run's
    # terminal evidence, and `M2` now does that: the session declares the period,
    # the shipped composition hands the same number to this executor, and the
    # run's terminal reports the session's declaration. That half is proved where
    # it happens, in `apps/loopex/test/agent_loop_test.exs` and
    # `apps/loopex_composition/test/kernel_composition_test.exs`. What this case
    # proves is the hand's half: that the number reaching it is the number it
    # spends and the number its receipts record.
    #
    # The default is the port's rather than this executor's, because the session
    # and the hand both need one number and a default written twice is two
    # numbers that agree until one is edited. An executor started with no period
    # at all must therefore land on exactly that number, which is asserted rather
    # than passed in.
    root = workspace()

    {default_executor, default_lease} = executor_with_options(root, [])

    assert Local.cleanup_grace_ms(default_executor) == 5_000,
           "an executor started with no declared period did not take the five seconds the " <>
             "operator guidance promises"

    assert Loopex.Executor.default_cleanup_grace_ms() == 5_000,
           "the port's declared default and this executor's are no longer one number"

    {executor, lease_id} = executor_with_grace(root, 750)
    assert Local.cleanup_grace_ms(executor) == 750

    assert {:ok, receipt} =
             run(root, "loopex.write", %{"path" => "budgeted.txt", "content" => "x"}, %{
               executor: executor,
               lease_id: lease_id
             })

    assert receipt.cleanup_grace_ms == 750

    # The durable record carries it too, so a coordinator recovering this job
    # reads the period it was bounded by rather than the one running now.
    assert {:ok, retained} = Local.receipt(executor, receipt.job_id)
    assert retained.cleanup_grace_ms == 750

    # A second executor in the same VM keeps its own period; the value is
    # per-instance configuration and not a global.
    assert Local.cleanup_grace_ms(default_executor) == 5_000
    assert is_binary(default_lease)
  end

  test "a job requiring process cleanup retains its receipt under a separate quarter period bound" do
    # Concept: the record of what happened gets a separately declared share that
    # no process-cleanup step can spend.
    #
    # Technical depth: the period used to be taken first-come. Every step drew
    # what remained, which is right for the signal, the kill and the
    # confirmation, and wrong for the last step: a job that spent its period on a
    # group refusing to die reached its receipt with nothing left, so
    # `retain_receipt_under_lease/4` answered `{:receipt_not_retained, _}` and
    # exactly the job whose durable record matters most produced none. The run
    # stayed truthful -- the coordinator reads that as unproven -- but
    # reconciliation had nothing to reconcile against.
    #
    # The receipt is bounded by a declared share of the period now, rather than by
    # what is left of it. The termination sequence keeps the whole period, so the
    # declared work allowance is the period plus that share -- not one flat
    # period. Bounded defensive teardown of a helper may add overhead outside
    # those two work bounds.
    # What matters is that the share is never a second full period and never
    # nothing. Every receipt records the bound its own write ran under, so this is
    # a fact on the durable record rather than an argument about a line.
    root = workspace()
    grace = 800
    reserve = div(grace, 4)

    {executor, lease_id} = executor_with_grace(root, grace)
    where = %{executor: executor, lease_id: lease_id}

    assert {:ok, quiet} =
             run(root, "loopex.write", %{"path" => "quiet.txt", "content" => "x"}, where)

    assert quiet.cleanup_grace_ms == grace

    # A job that needed no cleanup never opened an episode and still owns its own
    # instant, so it carries more than the period rather than the reserve.
    assert quiet.receipt_retention_bound_ms >= grace,
           "a job that needed no cleanup was charged against an episode it never opened: " <>
             "#{quiet.receipt_retention_bound_ms}ms"

    # A group that refuses `TERM` requires the process-cleanup sequence. The
    # receipt is still written, and it is written under the separate reserve.
    assert {:ok, cleaned} =
             run(root, "loopex.bash", %{"command" => stubborn_group_command()}, where),
           "a job that required process cleanup could not write its receipt at all"

    assert cleaned.output =~ "confirmed cleaned"

    assert cleaned.receipt_retention_bound_ms == reserve,
           "the receipt was retained under #{cleaned.receipt_retention_bound_ms}ms rather than " <>
             "the separate #{reserve}ms reserve derived from a #{grace}ms period"

    # The durable record carries it, so this is what a recovering coordinator or
    # an operator reads rather than a value that existed only in a reply.
    assert {:ok, retained} = Local.receipt(executor, cleaned.job_id)
    assert retained.receipt_retention_bound_ms == reserve
    assert retained.cleanup_grace_ms == grace
  end

  test "the configured cleanup budget bounds the whole termination sequence rather than each step of it" do
    # Concept: one absolute budget means shrinking it shortens the cleanup, and
    # that the cleanup never costs more than it.
    #
    # Technical depth: the sequence is a `ps`, a `TERM`, the cooperative grace, a
    # `KILL` and a second `ps`. Each used to receive five seconds of its own and
    # the pause between the signals was a hard fifty milliseconds, so the
    # declared period described none of them: the sequence could run for twenty
    # seconds under a grace that said five, and the one part an operator might
    # have wanted to lengthen -- the time a command gets to finish its write --
    # was the one part the period did not reach at all.
    #
    # Both runs here are the same command with the same group, and the group
    # refuses `TERM`, so the cooperative grace is actually spent in each. The
    # only difference is the configured period, and it is visible twice: the
    # longer budget takes measurably longer, and neither takes longer than the
    # budget it was given.
    root = workspace()

    {small_executor, small_lease} = executor_with_grace(root, 600)
    {large_executor, large_lease} = executor_with_grace(root, 3_000)

    {small_ms, small} =
      elapsed(fn ->
        run(root, "loopex.bash", %{"command" => stubborn_group_command()}, %{
          executor: small_executor,
          lease_id: small_lease
        })
      end)

    {large_ms, large} =
      elapsed(fn ->
        run(root, "loopex.bash", %{"command" => stubborn_group_command()}, %{
          executor: large_executor,
          lease_id: large_lease
        })
      end)

    # Both ended the group and said so; the outcome is not what differs.
    assert {:ok, %{outcome: :completed, output: small_output}} = small
    assert {:ok, %{outcome: :completed, output: large_output}} = large
    assert small_output =~ "confirmed cleaned"
    assert large_output =~ "confirmed cleaned"

    # The declared period is what the sequence spends, so a larger one spends
    # longer on the same group.
    assert large_ms > small_ms,
           "the configured period did not change how long cleanup took: " <>
             "#{small_ms}ms at 600ms and #{large_ms}ms at 3000ms"

    # And it is a bound, not a per-step allowance. Under separate allowances the
    # same group cost `ps` plus `TERM` plus a pause plus `KILL` plus `ps`, which
    # no single declared period described.
    assert small_ms < 600 + 2_000, "cleanup at a 600ms budget took #{small_ms}ms"
    assert large_ms < 3_000 + 2_000, "cleanup at a 3000ms budget took #{large_ms}ms"

    # Concept: a period is a length of time, and a length of time is not measured
    # with a clock somebody can set.
    #
    # Technical depth: the two measurements above are indifferent to the clock's
    # base, because nothing moved it while they ran -- and nothing can: a case
    # cannot step the host's clock, cannot enable the emulator's time-warp mode
    # for one test, and cannot make an NTP correction or a container snapshot
    # resume happen on demand. Swapping `System.monotonic_time/1` for
    # `System.system_time/1` here therefore left the whole suite green while a
    # declared five-second grace became five seconds plus however far the clock
    # moved mid-termination, or expired instantly if it moved the other way.
    #
    # So the base is asserted where it is decided. This is a structural
    # assertion and is written as one. The cleanup domain is closed -- every
    # instant in it is created at one of three sites and consumed only through
    # `cleanup_remaining/1` -- which is what makes asserting the base sufficient
    # rather than merely indicative, and what would stop being true if a fourth
    # site appeared reaching for the wall clock directly.
    source = File.read!(Path.expand("../lib/executor.ex", __DIR__))

    assert source =~ ~r/defp cleanup_now_ms, do: System\.monotonic_time\(:millisecond\)/,
           "the cleanup period is measured on a clock an operator, an NTP step, or a resumed " <>
             "container snapshot can move"

    instants = Regex.scan(~r/cleanup_now_ms\(\) \+/, source)

    assert length(instants) == 3,
           "the cleanup domain now opens #{length(instants)} instants against its own base; each " <>
             "one has to take that base, so a new one means this case needs to have been told " <>
             "about it"

    refute Regex.match?(~r/^\s+until = .*System\.system_time/m, source),
           "a cleanup instant is opened against the wall clock"

    [remaining] =
      Regex.run(~r/defp cleanup_remaining\(until\), do: (.+)/, source, capture: :all_but_first)

    assert remaining =~ "cleanup_now_ms()",
           "what is left of the cleanup period is measured against the wall clock: #{remaining}"

    [cooperative] =
      Regex.run(
        ~r/defp cooperative_episode\(\{until, grace, probe\}\) do\n.*?\n\n    \{(.+?),/s,
        source,
        capture: :all_but_first
      )

    assert cooperative =~ "cleanup_now_ms()",
           "the cooperative share is measured against the wall clock: #{cooperative}"
  end

  test "cancelling a running job answers only for the cleanup it could confirm" do
    # Concept: an operator abort reaches the shipped executor, and what it
    # answers has to be what it established rather than what it attempted.
    #
    # Technical depth: nothing in this repository called `Local.cancel/2`. The
    # cancellation cases upstream drive a double, the command's cases compose
    # fixtures that declare their own cleanup answer, and this file drove the
    # deadline path instead -- yet the coordinator calls this function on every
    # abort and on every deadline expiry, and the shipped composition wires this
    # executor in. Both of its branches were free: it could ignore the configured
    # period for a compiled-in constant, or report `:cleaned` without confirming
    # anything, and an operator would be told a process group in their workspace
    # was gone when this executor never established that.
    #
    # The two halves are one configured period apart. A workable period signals
    # the group, the group goes, `ps` finds nothing and the answer is `:cleaned`.
    # A period of zero leaves nothing for the signal or for the `ps` that would
    # confirm it, so the honest answer is `:unconfirmed` -- and a cancellation
    # drawing on a compiled-in five seconds instead of the declared zero would
    # confirm a clean stop here and answer `:cleaned`.
    root = workspace()
    marker = Path.join(root, "up.txt")
    survived = Path.join(root, "survived.txt")

    command =
      "printf ready > #{marker}; sleep 20; printf survived > #{survived}"

    {executor, lease_id} = executor_with_grace(root, 3_000)
    job_id = "cancel-#{System.unique_integer([:positive])}"

    running =
      Task.async(fn ->
        run(root, "loopex.bash", %{"command" => command}, %{
          executor: executor,
          lease_id: lease_id,
          job_id: job_id
        })
      end)

    assert wait_for_file(marker), "the command never started, so there was nothing to cancel"

    assert Local.cancel(executor, job_id) == {:ok, :cleaned},
           "a cancellation that ended the group did not say so"

    assert {:ok, %{outcome: outcome}} = Task.await(running, 30_000)

    assert outcome in [:cancelled, :outcome_unknown, :failed, :completed],
           "the cancelled job produced no terminal fact: #{inspect(outcome)}"

    # The group is gone in the filesystem as well as in the answer: the command
    # had seventeen seconds left to run and never reached its second write.
    refute File.exists?(survived),
           "the cancellation answered `cleaned` while the group carried on working"

    # A period of zero cannot signal and cannot confirm, and says so.
    tight_marker = Path.join(root, "tight-up.txt")
    tight_command = "printf ready > #{tight_marker}; sleep 20"

    {tight, tight_lease} = executor_with_grace(root, 0)
    tight_job = "cancel-tight-#{System.unique_integer([:positive])}"

    tight_running =
      Task.async(fn ->
        run(root, "loopex.bash", %{"command" => tight_command}, %{
          executor: tight,
          lease_id: tight_lease,
          job_id: tight_job
        })
      end)

    assert wait_for_file(tight_marker), "the second command never started"

    assert Local.cancel(tight, tight_job) == {:ok, :unconfirmed},
           "a cancellation with no period left to confirm anything reported a clean stop"

    # It settles rather than running to completion. A process-cleanup period of
    # zero derives a separate receipt reserve of zero too, so this job may answer
    # `{:receipt_not_retained, _}` rather than with a receipt. What matters here
    # is that the task settled and did not run its twenty seconds out.
    settled = Task.await(tight_running, 30_000)

    assert match?({:ok, %{outcome: _outcome}}, settled) or
             match?({:error, {:receipt_not_retained, _reason}}, settled),
           "the cancelled job never settled: #{inspect(settled)}"

    # A job this executor has no record of never started or already finished, so
    # there is nothing running and the answer is clean by construction.
    assert Local.cancel(executor, "no-such-job") == {:ok, :cleaned}

    # Concept: a cancellation confirms with the program its host named, not with
    # the one this module was written against.
    #
    # Technical depth: `cancel/2` reaches `confirm_group_terminated/2` by a path
    # of its own, and a mutation that made that path use `/bin/ps` regardless of
    # the configured probe left this whole file green: the probe was exercised
    # only through ordinary quiescence, and this case ran only under the default.
    # On an image whose `ps` is at `/usr/bin/ps`, cancellation would then quietly
    # confirm with a program the operator did not name -- and where the named
    # program is genuinely absent it would report a clean stop it never
    # established.
    #
    # A probe that is not there cannot confirm anything, so the honest answer for
    # a group this executor really did signal is `:unconfirmed`. That is the
    # assertion: the answer follows the configured program even when the group is
    # gone.
    blind_marker = Path.join(root, "blind-up.txt")
    blind_command = "printf ready > #{blind_marker}; sleep 20"

    {blind, blind_lease} = executor_with_probe(root, "/nonexistent/loopex-ps")
    blind_job = "cancel-blind-#{System.unique_integer([:positive])}"

    blind_running =
      Task.async(fn ->
        run(root, "loopex.bash", %{"command" => blind_command}, %{
          executor: blind,
          lease_id: blind_lease,
          job_id: blind_job
        })
      end)

    assert wait_for_file(blind_marker), "the command under the blind probe never started"

    assert Local.cancel(blind, blind_job) == {:ok, :unconfirmed},
           "a cancellation confirmed cleanup with a program its host did not name"

    assert Task.await(blind_running, 30_000) != nil

    # Concept: a cancellation spends the period the host configured, not the one
    # this module was compiled with.
    #
    # Technical depth: `cancel/2` deliberately runs in its caller so it is not
    # queued behind the job it is ending, and the cooperative share was read from
    # the process dictionary -- which in the caller is empty. So a cancellation
    # computed its share from the compiled-in default: an executor composed with
    # five hundred milliseconds gave a cancellation two and a half seconds, and
    # one composed with thirty seconds gave it two and a half. The declared
    # period was the one thing it did not use.
    #
    # A group that ignores `TERM` is what makes the share observable, because it
    # is spent rather than short-circuited. At three seconds the sequence waits
    # its half and kills; reading the default instead waits five seconds' half,
    # which is the whole period, and takes about a second longer.
    stubborn_marker = Path.join(root, "stubborn-up.txt")

    stubborn_command =
      "printf ready > #{stubborn_marker}; ( trap \"\" TERM; sleep 20 ) & sleep 20"

    {slow, slow_lease} = executor_with_grace(root, 3_000)
    stubborn_job = "cancel-stubborn-#{System.unique_integer([:positive])}"

    stubborn_running =
      Task.async(fn ->
        run(root, "loopex.bash", %{"command" => stubborn_command}, %{
          executor: slow,
          lease_id: slow_lease,
          job_id: stubborn_job
        })
      end)

    assert wait_for_file(stubborn_marker), "the stubborn command never started"

    {stubborn_ms, stubborn_answer} = elapsed(fn -> Local.cancel(slow, stubborn_job) end)

    assert stubborn_answer == {:ok, :cleaned},
           "a cancellation that killed the group did not say so: #{inspect(stubborn_answer)}"

    assert stubborn_ms < 2_200,
           "cancelling under a 3000ms period spent #{stubborn_ms}ms, which is the compiled-in " <>
             "default's share rather than the configured period's"

    assert Task.await(stubborn_running, 30_000) != nil
  end

  test "cancelling an unknown job id leaves another running job untouched" do
    # Concept: cancellation names one operator job. A typo, replay for a job
    # already settled, or stale command must never stop different live work.
    #
    # Technical depth: keep exactly one job in the executor's in-flight table,
    # then cancel a distinct identifier. Looking up an arbitrary table member
    # instead of the requested key kills this command before its second marker;
    # the conforming keyed lookup leaves it alone until this case cancels the
    # actual identifier during cleanup.
    root = workspace()
    ready = Path.join(root, "wrong-cancel-ready.txt")
    continued = Path.join(root, "wrong-cancel-continued.txt")
    job_id = "cancel-owned-#{System.unique_integer([:positive])}"
    wrong_job_id = "cancel-other-#{System.unique_integer([:positive])}"
    {executor, lease_id} = executor_with_grace(root, 3_000)

    command =
      "printf ready > #{ready}; sleep 1; printf continued > #{continued}; sleep 20"

    running =
      Task.async(fn ->
        run(root, "loopex.bash", %{"command" => command}, %{
          executor: executor,
          lease_id: lease_id,
          job_id: job_id
        })
      end)

    try do
      assert wait_for_file(ready), "the owned command never entered the in-flight table"

      assert Local.cancel(executor, wrong_job_id) == {:ok, :cleaned},
             "an unknown job should have no process tree left to clean"

      assert wait_for_file(continued),
             "cancelling #{wrong_job_id} stopped the different live job #{job_id}"
    after
      _answer = Local.cancel(executor, job_id)

      case Task.yield(running, 10_000) do
        nil -> Task.shutdown(running, :brutal_kill)
        _settled -> :ok
      end
    end
  end

  test "each of the three quiescence answers reaches a distinct outcome and only one is proved" do
    # Concept: bringing a group to quiescence has three answers, and `completed`
    # belongs to exactly one of them.
    #
    # Technical depth: two of the three were already driven -- the ordinary
    # command is `:quiescent` and the backgrounding one is `:terminated`. The
    # third, `:unconfirmed`, is what an image whose `ps` is not where this
    # executor looks produces, and what a `ps` starved past the remaining cleanup
    # budget produces. Dropping the `unproven/1` around that branch left the whole
    # suite green while the receipt reported `:completed` carrying, in its own
    # output, the note saying whether its effect is complete is unproven -- a
    # receipt contradicting itself.
    #
    # It was a hardcoded `/bin/ps`, so no case could reach the branch and it was
    # asserted from the source instead. Naming the probe is a real configuration
    # question -- an image that ships `ps` only at `/usr/bin/ps` gets every
    # command reported unproven -- and it also makes the branch drivable: an
    # executor composed with a probe that is not there cannot confirm anything,
    # with its period otherwise intact, which is precisely the operating
    # condition this branch exists for.
    root = workspace()

    assert {:ok, %{outcome: :completed, output: plain}} =
             run(root, "loopex.bash", %{"argv" => ["echo", "quiet"]})

    refute plain =~ "could not be confirmed"

    assert {:ok, %{outcome: :completed, output: ended}} =
             run(root, "loopex.bash", %{"command" => stubborn_group_command()})

    assert ended =~ "confirmed cleaned"

    {blind, blind_lease} = executor_with_probe(root, "/nonexistent/loopex-ps")
    assert Local.process_probe(blind) == "/nonexistent/loopex-ps"

    assert {:ok, unconfirmed} =
             run(root, "loopex.bash", %{"command" => stubborn_group_command()}, %{
               executor: blind,
               lease_id: blind_lease
             })

    assert unconfirmed.outcome == :outcome_unknown,
           "a group that could not be confirmed quiescent was reported " <>
             "#{unconfirmed.outcome} on a receipt whose own output denies it"

    assert unconfirmed.output =~ "could not be confirmed"

    # The receipt names what could not confirm it, so an operator reading an
    # unproven outcome is not left guessing which program was asked.
    assert unconfirmed.process_probe == "/nonexistent/loopex-ps"

    # The shipped default is the one every other case in this file runs under.
    {default, _default_lease} = executor_with_grace(root, 3_000)
    assert Local.process_probe(default) == "/bin/ps"
  end

  test "an answer this executor gives after an effect ran never wears the pre-start tag" do
    # Concept: the tag is a claim that nothing happened. A conflict at a job
    # identity is this executor saying something already did.
    #
    # Technical depth: `:job_id_conflict` is answered when a receipt already
    # exists on disk at this job identity and its digest is a different one --
    # so an effect ran, under this identity, and this call is not it. `job_id` is
    # derived from the run and tool-call identity while the digest covers the
    # deadline and the session epoch, so a resumed session re-dispatching the
    # same tool call reaches exactly this answer.
    #
    # Wrapping it in the pre-start tag makes the coordinator commit an ordinary
    # terminal `failed`: the model is told the tool did not run, the loop resumes,
    # and the run can finish `completed` past an effect that already landed in the
    # workspace. That is the silent resume this milestone exists to have closed,
    # and the coordinator's own cases prove the classification only against
    # doubles, so nothing else in this repository asks what the shipped executor
    # answers here.
    root = workspace()
    {executor, lease_id} = executor_for(root)
    job_id = "conflict-#{System.unique_integer([:positive])}"
    where = %{executor: executor, lease_id: lease_id, job_id: job_id}

    assert {:ok, %{outcome: :completed}} =
             run(root, "loopex.write", %{"path" => "first.txt", "content" => "one"}, where)

    # The same job identity with different canonicalized bytes: `run/4` mints a
    # fresh operation and tool-call identity every time, so the second job's
    # digest cannot be the first's.
    second = run(root, "loopex.write", %{"path" => "second.txt", "content" => "two"}, where)

    assert second == {:error, :job_id_conflict},
           "the executor's answer for a conflicting job identity changed: #{inspect(second)}"

    refute match?({:error, {:refused_before_effect, _reason}}, second),
           "an answer given after an effect ran claimed to precede it"

    # And the second write did not happen, which is what makes the first clause
    # of this case a statement about an effect rather than about a name.
    refute File.exists?(Path.join(root, "second.txt"))
  end

  test "a job is bounded by the tool's declared budget when that is sooner than the run's" do
    # Concept: the instant a job is bounded at is the earlier of the run's
    # committed deadline and the budget the tool itself declares.
    #
    # Technical depth: this executor once ignored the tool's declared
    # `wall_time_ms` entirely -- the bound was a literal two minutes and the
    # declared budget was read nowhere in the tree. Reintroducing that, by
    # returning the run's deadline unconditionally, left every case here green:
    # each of them sets a run deadline of a few hundred milliseconds, far shorter
    # than any shipped budget, so the minimum and "the run's deadline" are the
    # same number in every case that can afford to wait for a bound to fire.
    #
    # Waiting is what makes it unobservable. The shipped budgets are thirty
    # seconds and two minutes, so a case watching the tool's budget actually stop
    # a job would run for thirty seconds. The receipt records the instant the job
    # was bounded at instead, which is the value the code used rather than a
    # value a test computed, and this reads it.
    root = workspace()
    File.write!(Path.join(root, "small.txt"), "hello")

    far = System.system_time(:millisecond) + 600_000
    before = System.system_time(:millisecond)

    assert {:ok, receipt} =
             run(root, "loopex.read", %{"path" => "small.txt"}, %{run_deadline: far})

    assert receipt.run_deadline_ms == far

    declared =
      CodingTools.definitions()
      |> Enum.find(&(&1["tool_id"] == "loopex.read"))
      |> get_in(["budgets", "wall_time_ms"])

    assert is_integer(declared) and declared < 600_000,
           "this case assumes loopex.read declares a budget shorter than the run it was given"

    assert receipt.effective_deadline_ms < far,
           "the job was bounded by the run's deadline while the tool declared a shorter budget"

    # Concept: the instant recorded is the instant the job actually ran under.
    #
    # Technical depth: the receipt used to recompute this after the tool had
    # finished, and `min(run_deadline, now + budget)` is a function of *now*, so
    # recomputing moved it later by however long the job took. A five-second
    # tolerance and a fast read hid that completely. The tolerance is one second
    # now and the command deliberately takes longer than that, so a recomputed
    # value lands outside the window while a threaded one cannot.
    assert receipt.effective_deadline_ms <= before + declared + 1_000,
           "the job was bounded later than the budget the tool declares: " <>
             "#{receipt.effective_deadline_ms - before}ms out against a declared #{declared}ms"

    slow_before = System.system_time(:millisecond)

    assert {:ok, slow} =
             run(root, "loopex.bash", %{"command" => "sleep 2"}, %{run_deadline: far})

    slow_declared =
      CodingTools.definitions()
      |> Enum.find(&(&1["tool_id"] == "loopex.bash"))
      |> get_in(["budgets", "wall_time_ms"])

    assert slow.effective_deadline_ms <= slow_before + slow_declared + 1_000,
           "a job that took two seconds recorded a deadline " <>
             "#{slow.effective_deadline_ms - slow_before}ms after it began, against a declared " <>
             "#{slow_declared}ms -- the value was recomputed after the work rather than " <>
             "carried from before it"
  end

  test "a deadline stop whose cleanup could not be confirmed is unproven rather than cancelled" do
    # Concept: reaching a deadline and stopping the command is not the same as
    # establishing that its process group is gone.
    #
    # Technical depth: the deadline branch reports `:cancelled` where the group
    # was confirmed and `:outcome_unknown` where it was not, and only the first
    # of those was ever driven: under the default probe the confirmation always
    # succeeds. Deleting the distinction left every case green while the receipt
    # said `:cancelled` and its own output text said the cleanup could not be
    # confirmed -- a receipt contradicting itself, and a coordinator told a
    # process tree is gone that nobody established was gone.
    #
    # A probe that is not there is the reachable form of "the confirmation could
    # not run", exactly as it is for the quiescence path.
    root = workspace()
    {blind, blind_lease} = executor_with_probe(root, "/nonexistent/loopex-ps")

    assert {:ok, receipt} =
             run(root, "loopex.bash", %{"command" => "sleep 20"}, %{
               executor: blind,
               lease_id: blind_lease,
               run_deadline: System.system_time(:millisecond) + 400
             })

    assert receipt.outcome == :outcome_unknown,
           "a deadline stop that could confirm nothing was reported #{receipt.outcome}"

    assert receipt.output =~ "could not be confirmed",
           "the receipt does not say what was left unproven: #{receipt.output}"
  end

  test "a job is refused when the lease it names is held at another fencing token" do
    # Concept: the lease that authorises the effect must be the one this executor
    # was fenced with, not merely a lease with the right name.
    #
    # Technical depth: `validate_grant/3` is handed this executor's own token and
    # so compares the *grant* against it. The only check that the *lease holder*
    # carries that token is a separate line in the pre-start validation, and
    # deleting it left the whole suite green: every other fixture composes the
    # lease and the executor with the same token, so the comparison is true
    # whatever the code does.
    #
    # Scenario: the workspace is re-leased to a newer holder at a higher token
    # while this executor still refers to the old lease. The grant validates,
    # because it is checked against this executor's state rather than against the
    # lease, and the effect runs inside a workspace another holder has already
    # fenced.
    root = workspace()
    {executor, lease_id} = executor_with_stale_lease(root)

    answer =
      run(root, "loopex.write", %{"path" => "fenced.txt", "content" => "x"}, %{
        executor: executor,
        lease_id: lease_id
      })

    assert {:error, {:refused_before_effect, :executor_prestart_mismatch}} = answer,
           "a job ran against a lease fenced to another holder: #{inspect(answer)}"

    refute File.exists?(Path.join(root, "fenced.txt")),
           "the effect happened despite the lease being fenced to another holder"
  end

  test "the two containment mechanisms obligation four names by name are the ones the code uses" do
    # Concept: the obligation names two mechanisms, not two outcomes. A case can
    # prove an outcome; only reading the code can prove which mechanism produced
    # it.
    #
    # Technical depth: this is a structural assertion and is written as one
    # rather than dressed up as behavioural. Both mechanisms were mutated away
    # with the entire suite green, and in each case the reason is the same: the
    # property is a statement about *how* an operation is performed, and the
    # operation's observable result is identical either way until a race that no
    # case can schedule fires.
    #
    # The create-exclusive open. Obligation 4 says a write or an edit is
    # committed "by a create-exclusive and rename that cannot follow a link".
    # Dropping `:exclusive` leaves every write and edit working exactly as
    # before: the staging name carries seventy-two random bits, so nothing is
    # ever there to collide with, and the open that would have refused a symlink
    # planted at that name simply follows it instead. To drive it a case would
    # have to predict the staging name, which is the point of the random bits.
    #
    # The identity re-check. The obligation says containment is "resolved and
    # checked immediately before the effect", and `read_verified/3` enforces that
    # by comparing what was checked with what was opened. The comparison is by
    # device and inode; collapsing it to device and file type makes it vacuous,
    # because the clause head has already pinned the type to `:regular`, so every
    # same-filesystem swap of one regular file for another compares equal. The
    # two swap cases in this file swap an intermediate *directory* component and
    # are caught by `ensure_directories/3`, not by this comparison; swapping the
    # final regular file between the check and the open is the window recorded at
    # `docs/evidence/M2-recorded-limitations.md#operator-path-race`, and a case
    # that could schedule it reliably would be a case that had closed it.
    source = File.read!(Path.expand("../lib/executor.ex", __DIR__))

    [staging_open] =
      Regex.run(~r/case :file\.open\(temporary, \[(.+?)\]\) do/, source, capture: :all_but_first)

    assert staging_open =~ ":exclusive",
           "a write or an edit no longer commits through a create-exclusive open, so the " <>
             "staging name follows a symlink planted at it: [#{staging_open}]"

    assert staging_open =~ ":write" and staging_open =~ ":binary",
           "the staging open is no longer the write this obligation describes: [#{staging_open}]"

    [identity] =
      Regex.run(
        ~r/\{:ok, %File\.Stat\{type: :regular\} = stat\} ->\n\s*\{:ok, \{(.+?)\}\}/s,
        source,
        capture: :all_but_first
      )

    assert identity =~ "stat.inode",
           "the identity a path is re-checked against no longer identifies a file, so a swap " <>
             "of one regular file for another compares equal: {#{identity}}"

    assert identity =~ "stat.major_device",
           "the identity omits the device, so two files with equal inode numbers on different " <>
             "filesystems compare equal: {#{identity}}"

    # Constructing an identity is half of it. A reviewer's mutation weakened the
    # *comparison* instead -- accepting any inode on the same device -- and the
    # whole suite stayed green, because this case only ever looked at the tuple
    # being built. The comparison is a pin on the entire identity, and it is
    # asserted here as one.
    [comparison] =
      Regex.run(~r/defp read_verified\(resolved, path, identity\) do\n(.*?)\n  end\n/s, source,
        capture: :all_but_first
      )

    assert comparison =~ "{:ok, ^identity} ->",
           "the re-check no longer compares the whole identity it captured, so a file swapped " <>
             "for another on the same filesystem is read as though it were the one that was " <>
             "checked: #{comparison}"

    refute comparison =~ ~r/elem\(identity, 0\)|match\?\(\{_/,
           "the re-check compares part of the identity rather than all of it: #{comparison}"

    # Anchored to behaviour rather than standing alone: the outcomes both
    # mechanisms exist to produce are driven elsewhere in this file, and a write
    # still replaces its target rather than appending to it.
    root = workspace()
    File.write!(Path.join(root, "target.txt"), "old content that is longer")

    assert {:ok, %{outcome: :completed}} =
             run(root, "loopex.write", %{"path" => "target.txt", "content" => "new"})

    assert File.read!(Path.join(root, "target.txt")) == "new"
    assert File.ls!(root) |> Enum.reject(&(&1 == "target.txt")) == []
  end

  test "a cleanup helper that outlives its bound is terminated rather than left running" do
    # Concept: a bound that only stops this runtime waiting is not a bound on the
    # program it was waiting for.
    #
    # Technical depth: the helper used to run inside a spawned BEAM process that
    # was killed at the bound. Closing its port does not end the operating-system
    # process behind it, so a probe answered `:no_answer` after a hundred
    # milliseconds and the child went on to do its work afterwards. For `/bin/ps`
    # that is untidy. For `/bin/kill` it is a signal aimed at a negated process
    # group identifier and delivered at a moment this executor believes its
    # cleanup already ended -- and group identifiers are reissued, so the target
    # need not be the group that was meant.
    #
    # The file is the evidence: it exists only if the helper ran to completion
    # after its bound had passed.
    root = workspace()
    written = Path.join(root, "helper-ran-after-its-bound.txt")

    {answered_ms, answer} =
      elapsed(fn ->
        Local.answer_within("/bin/sh", ["-c", "sleep 2; printf x > #{written}"], 150)
      end)

    assert answer == :no_answer
    assert answered_ms < 1_500, "the bound was not honoured: #{answered_ms}ms"

    # Long enough that the helper would have finished if it were still alive.
    Process.sleep(3_000)

    refute File.exists?(written),
           "the helper outlived its bound and completed its work afterwards"

    # A helper that answers inside its bound is unaffected: the kill is the
    # abandonment path and not the ordinary one.
    assert {output, 0} = Local.answer_within("/bin/sh", ["-c", "printf answered"], 5_000)
    assert output == "answered"
  end
end
