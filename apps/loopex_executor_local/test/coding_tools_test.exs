defmodule Loopex.Executor.Local.CodingToolsTest.RecordingStore do
  @moduledoc false

  # Concept: an artifact store that remembers what an executor handed it.
  #
  # Technical depth: the claim under test is that the executor spills through the
  # port, not that a particular adapter stores bytes well -- the local adapter has
  # its own conformance suite for that. Recording here is what lets the case
  # assert on the bytes the executor passed rather than on bytes a test wrote.
  #
  # It records the object and its immutable use separately because the port
  # separates them: `stored/1` answers only for retained bytes, which is what
  # these cases assert on, while the use record is what `describe/2` resolves.

  @behaviour Loopex.ArtifactStore

  alias LoopexProtocol.Canonical

  def start, do: Agent.start_link(fn -> %{objects: %{}, uses: %{}} end)
  def stored(pid), do: Agent.get(pid, & &1.objects)

  @impl Loopex.ArtifactStore
  def put(pid, bytes, %{media_type: media_type, role: role, metadata: metadata}) do
    digest = Canonical.digest_bytes(bytes)
    object = %{digest: digest, size: byte_size(bytes), locator: digest}

    artifact_use = %{
      canonicalization_version: Canonical.version(),
      object_digest: object.digest,
      object_size: object.size,
      object_locator: object.locator,
      media_type: media_type,
      role: role,
      metadata: metadata
    }

    use_digest = Canonical.digest(["artifact-use-v2", artifact_use])
    use_locator = "use:" <> use_digest

    :ok =
      Agent.update(pid, fn state ->
        %{
          state
          | objects: Map.put(state.objects, object.locator, bytes),
            uses: Map.put(state.uses, use_locator, artifact_use)
        }
      end)

    {:ok,
     Map.merge(object, %{
       media_type: media_type,
       role: role,
       use_canonicalization_version: Canonical.version(),
       use_digest: use_digest,
       use_locator: use_locator
     })}
  end

  def put(_pid, _bytes, _use), do: {:error, :adapter_received_unnormalized_use}

  @impl Loopex.ArtifactStore
  def fetch(pid, object) do
    case Agent.get(pid, &Map.fetch(&1.objects, object.locator)) do
      {:ok, bytes} -> {:ok, bytes}
      :error -> {:error, :unknown_artifact}
    end
  end

  @impl Loopex.ArtifactStore
  def stat(pid, locator) do
    case Agent.get(pid, &Map.fetch(&1.objects, locator)) do
      {:ok, bytes} -> {:ok, %{digest: locator, size: byte_size(bytes), locator: locator}}
      :error -> {:error, :unknown_artifact}
    end
  end

  @impl Loopex.ArtifactStore
  def describe(pid, use_locator) do
    case Agent.get(pid, &Map.fetch(&1.uses, use_locator)) do
      {:ok, artifact_use} -> {:ok, artifact_use}
      :error -> {:error, :unknown_artifact_use}
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

  alias LoopexProtocol.Canonical

  @impl Loopex.ArtifactStore
  def put({owner, delay}, bytes, %{media_type: media_type, role: role, metadata: metadata}) do
    send(owner, :retention_started)
    Process.sleep(delay)

    digest = Canonical.digest_bytes(bytes)
    object = %{digest: digest, size: byte_size(bytes), locator: digest}

    use_digest =
      Canonical.digest([
        "artifact-use-v2",
        %{
          canonicalization_version: Canonical.version(),
          object_digest: object.digest,
          object_size: object.size,
          object_locator: object.locator,
          media_type: media_type,
          role: role,
          metadata: metadata
        }
      ])

    {:ok,
     Map.merge(object, %{
       media_type: media_type,
       role: role,
       use_canonicalization_version: Canonical.version(),
       use_digest: use_digest,
       use_locator: "use:" <> use_digest
     })}
  end

  @impl Loopex.ArtifactStore
  def fetch(_handle, _object), do: {:error, :unknown_artifact}

  @impl Loopex.ArtifactStore
  def stat(_handle, _locator), do: {:error, :unknown_artifact}

  # Every case using this store abandons the wait before publication completes,
  # so no reference it returns is ever resolved. Answering unavailable is the
  # truthful answer for a use this store never published.
  @impl Loopex.ArtifactStore
  def describe(_handle, _use_locator), do: {:error, :unknown_artifact_use}
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

  defp await_queued_message(pid, predicate, deadline_ms) do
    stop = System.monotonic_time(:millisecond) + deadline_ms
    await_queued_message(pid, predicate, stop, Process.info(pid, :messages))
  end

  defp await_queued_message(pid, predicate, stop, {:messages, messages}) do
    if Enum.any?(messages, predicate) do
      :ok
    else
      await_queued_message_retry(pid, predicate, stop)
    end
  end

  defp await_queued_message(pid, predicate, stop, _gone) do
    await_queued_message_retry(pid, predicate, stop)
  end

  defp await_queued_message_retry(pid, predicate, stop) do
    if System.monotonic_time(:millisecond) >= stop do
      :timeout
    else
      Process.sleep(1)
      await_queued_message(pid, predicate, stop, Process.info(pid, :messages))
    end
  end

  defp resume_if_suspended(pid) when is_pid(pid) do
    if Process.alive?(pid) do
      try do
        :erlang.resume_process(pid)
      catch
        :error, :badarg -> :ok
      end
    end
  end

  defp monitored_guardian(waiter, excluded) do
    waiter
    |> Process.info(:monitors)
    |> elem(1)
    |> Enum.find_value(fn
      {:process, pid} -> if pid in excluded, do: nil, else: pid
      _other -> nil
    end)
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

  defp retained_receipt!(ledger, job_id) do
    name = (:crypto.hash(:sha256, job_id) |> Base.encode16(case: :lower)) <> ".receipt"
    bytes = File.read!(Path.join(ledger, name))
    :erlang.binary_to_term(bytes, [:safe])
  end

  defp run(root, tool_id, arguments, overrides \\ %{}) do
    {execute_options, overrides} = Map.pop(overrides, :execute_options, [])

    {progress, overrides} =
      Map.pop(overrides, :progress, Loopex.Executor.discard_progress())

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
      progress
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
    #
    # An intermediate session launcher reproduced the same false success on
    # Linux by forking away from a Port child that already led its own group.
    # The executor therefore keeps the Port-established group as the only
    # ownership identity and observes this command's seven directly.
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

  test "bash emits real progress before completion with exact identity sequence offsets and receipt count" do
    root = workspace()
    parent = self()
    release = ".loopex-release"
    {executor, lease_id} = executor_for(root)
    {:ok, observed} = Agent.start_link(fn -> [] end)

    on_exit(fn ->
      if Process.alive?(observed), do: Agent.stop(observed)
    end)

    progress = fn event ->
      :ok = Agent.update(observed, &(&1 ++ [event]))
      send(parent, {:local_executor_progress, event})
      :ok
    end

    task =
      Task.async(fn ->
        run(
          root,
          "loopex.bash",
          %{
            "command" =>
              "printf éfirst; while [ ! -f #{release} ]; do sleep 0.01; done; printf second"
          },
          %{
            progress: progress,
            executor: executor,
            lease_id: lease_id,
            operation_id: "operation-progress",
            session_id: "session-progress",
            run_id: "run-progress",
            turn_id: "turn-progress",
            tool_call_id: "call-progress"
          }
        )
      end)

    assert_receive {:local_executor_progress, _first}, 2_000

    await_first = fn await_first ->
      bytes =
        observed
        |> Agent.get(& &1)
        |> Enum.map_join(& &1.chunk)

      if bytes == "éfirst" do
        bytes
      else
        receive do
          {:local_executor_progress, _event} -> await_first.(await_first)
        after
          2_000 -> bytes
        end
      end
    end

    assert await_first.(await_first) == "éfirst"
    assert Task.yield(task, 0) == nil

    File.write!(Path.join(root, release), "continue")
    assert {:ok, receipt} = Task.await(task, 5_000)

    events = Agent.get(observed, & &1)
    assert length(events) >= 2
    assert receipt.progress_count == length(events)
    assert Enum.map_join(events, & &1.chunk) == "éfirstsecond"
    assert receipt.output == "éfirstsecond"

    expected_identity = %{
      protocol_version: receipt.protocol_version,
      job_id: receipt.job_id,
      operation_id: receipt.operation_id,
      attempt: receipt.attempt,
      session_id: receipt.session_id,
      run_id: receipt.run_id,
      turn_id: receipt.turn_id,
      tool_call_id: receipt.tool_call_id,
      canonical_request_digest: receipt.canonical_request_digest,
      session_epoch_at_dispatch: receipt.session_epoch_at_dispatch,
      executor_epoch: receipt.executor_epoch,
      executor_identity: receipt.executor_identity,
      fencing_token: receipt.fencing_token
    }

    identity_keys = Map.keys(expected_identity)

    {count, bytes} =
      Enum.reduce(events, {0, 0}, fn event, {sequence, offset} ->
        assert Map.keys(event) |> Enum.sort() ==
                 (identity_keys ++ [:progress_sequence, :stream, :byte_offset, :chunk])
                 |> Enum.sort()

        assert Map.take(event, identity_keys) == expected_identity
        assert event.progress_sequence == sequence
        assert event.stream == "stdout"
        assert event.byte_offset == offset
        assert byte_size(event.chunk) <= 65_536
        refute event.chunk =~ "loopex-pgid:"

        {sequence + 1, offset + byte_size(event.chunk)}
      end)

    assert count == receipt.progress_count
    assert bytes == byte_size(receipt.output)

    refute Enum.map_join(events, & &1.chunk) =~ "loopex-pgid:"
  end

  test "a blocked progress callback cannot keep an owned command beyond cancellation" do
    # Concept: progress is advisory delivery from the effect; it cannot become
    # authority for the effect to outlive cancellation.
    #
    # Technical depth: the callback blocks before returning `:ok`, while the real
    # child waits on a file the case controls. If the launch owner invokes the
    # callback itself, cancellation queues behind that invocation and the child
    # writes after the release file appears. Forwarding progress to the execute
    # caller leaves the owner free to terminate and confirm its captured group.
    root = workspace()
    parent = self()
    release = Path.join(root, "release-blocked-progress")
    escaped = Path.join(root, "escaped-blocked-progress")
    job_id = "blocked-progress-#{System.unique_integer([:positive])}"
    {executor, lease_id} = executor_for(root)

    progress = fn _event ->
      send(parent, {:blocked_progress_callback, self()})

      receive do
        :release_blocked_progress -> :ok
      end
    end

    task =
      Task.async(fn ->
        run(
          root,
          "loopex.bash",
          %{
            "command" =>
              "printf streamed; while [ ! -f #{shell_path(release)} ]; do sleep 0.01; done; " <>
                "printf escaped > #{shell_path(escaped)}; sleep 20"
          },
          %{
            progress: progress,
            executor: executor,
            lease_id: lease_id,
            job_id: job_id,
            cleanup_grace_ms: 400
          }
        )
      end)

    callback =
      receive do
        {:blocked_progress_callback, pid} -> pid
      after
        2_000 -> flunk("the command emitted no progress to block")
      end

    try do
      assert Local.cancel(executor, job_id) in [{:ok, :cleaned}, {:ok, :unconfirmed}]
      File.write!(release, "continue")
      Process.sleep(250)

      refute File.exists?(escaped),
             "the command acted while its process owner was blocked in a progress callback"
    after
      send(callback, :release_blocked_progress)
    end

    assert {:ok, receipt} = Task.await(task, 5_000)
    assert receipt.outcome != :completed
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

    # Concept: no intermediate session launcher can receive the operator's
    # environment or replace the process group the Port owns.
    #
    # Technical depth: `setsid` used to appear after `env -i`. That closed the
    # credential leak but still forked away from the Port-established group on
    # Linux, losing the command's exit status and cleanup identity. Inspect both
    # launch forms directly so reintroducing that topology cannot make this
    # credential case vacuous merely because ambient PATH substitution is gone.
    for arguments <- [%{command: "printf ran"}, %{argv: ["printf", "ran"]}] do
      assert {"/usr/bin/env", vector} = Local.launcher_vector(arguments)
      refute "setsid" in vector
    end

    # A tool that starts no child holds no environment, and says so rather than
    # reporting one it never had.
    assert {:ok, quiet} = run(root, "loopex.read", %{"path" => "notes.txt"})
    assert quiet.child_environment_names == []
    refute quiet.provider_credential_present
    assert quiet.progress_count == 0
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

  test "a shell job obeys the smaller declared output ceiling and spills the complete bytes" do
    # Concept: the ceiling committed on the job can narrow the definition, and
    # crossing it preserves the bytes without letting the artifact notice widen
    # what reaches the model.
    #
    # Technical depth: the process path bounded with CodingTools' module constant
    # after it had collected the whole answer. A job declaring a smaller ceiling
    # therefore returned all its bytes, while the receipt's durable budget said
    # it had shown less. Deleting the minimum calculation must make this case lose
    # both its artifact and its bounded model-facing result.
    root = workspace()
    {:ok, store} = Loopex.Executor.Local.CodingToolsTest.RecordingStore.start()

    {executor, lease_id} =
      executor_for(root, %{
        module: Loopex.Executor.Local.CodingToolsTest.RecordingStore,
        handle: store
      })

    output_limit = 1_024
    full = String.duplicate("bounded-output-", 256)

    assert {:ok, %{outcome: :completed} = receipt} =
             run(
               root,
               "loopex.bash",
               %{"argv" => ["/usr/bin/printf", full]},
               %{
                 executor: executor,
                 lease_id: lease_id,
                 resource_budgets: %{
                   "max_output_bytes" => output_limit,
                   "max_wall_time_ms" => 30_000
                 }
               }
             )

    assert byte_size(receipt.output) <= output_limit
    assert receipt.output =~ "truncated"
    assert [reference] = receipt.artifacts
    assert reference.size == byte_size(full)
    assert receipt.output =~ reference.digest

    assert [_, shown, total] =
             Regex.run(~r/output truncated\. (\d+) of (\d+) bytes shown/, receipt.output)

    assert String.to_integer(shown) > 0
    assert String.to_integer(total) == byte_size(full)

    assert store |> Loopex.Executor.Local.CodingToolsTest.RecordingStore.stored() |> Map.values() ==
             [
               full
             ]
  end

  test "a shell job exceeding the tool artifact ceiling is stopped without retaining a partial artifact" do
    # Concept: the artifact ceiling is a production bound, not metadata. A
    # command cannot make this executor retain output forever by never stopping.
    #
    # Technical depth: collect_output/7 appended every port chunk to one binary
    # and consulted no artifact_bytes value. This command crosses the shipped
    # definition's ceiling, then leaves ten seconds before a final marker so the
    # receiver has a deterministic opportunity to act. The implementation must stop
    # the owned group at that crossing, retain no artifact that pretends to be
    # complete, and keep the truthful receipt itself under the output ceiling.
    # Replacing the bounded collector with acc <> chunk makes the marker appear
    # and lets RecordingStore observe an over-ceiling artifact.
    root = workspace()
    marker = Path.join(root, "ran-past-artifact-ceiling")
    {:ok, store} = Loopex.Executor.Local.CodingToolsTest.RecordingStore.start()

    {executor, lease_id} =
      executor_for(root, %{
        module: Loopex.Executor.Local.CodingToolsTest.RecordingStore,
        handle: store
      })

    definition = Enum.find(CodingTools.definitions(), &(&1["tool_id"] == "loopex.bash"))
    artifact_limit = get_in(definition, ["budgets", "artifact_bytes"])
    output_limit = get_in(definition, ["budgets", "output_bytes"])

    assert {:ok, receipt} =
             run(
               root,
               "loopex.bash",
               %{
                 "argv" => [
                   "/bin/sh",
                   "-c",
                   "yes output | head -c \"$1\"; sleep 10; printf reached > \"$2\"",
                   "loopex-artifact-ceiling",
                   Integer.to_string(artifact_limit + 1_048_576),
                   marker
                 ]
               },
               %{executor: executor, lease_id: lease_id}
             )

    assert receipt.outcome in [:failed, :outcome_unknown]
    assert receipt.output =~ "artifact ceiling"
    assert receipt.output =~ Integer.to_string(artifact_limit)
    assert byte_size(receipt.output) <= output_limit
    assert receipt.artifacts == []
    assert Loopex.Executor.Local.CodingToolsTest.RecordingStore.stored(store) == %{}
    refute File.exists?(marker), "the command continued after crossing its artifact ceiling"
  end

  test "a deadline result keeps its diagnostic inside the smaller declared output ceiling" do
    # Concept: reaching a deadline does not release the output bound. The model
    # receives the reason the job stopped and a truthful indication that the
    # partial output was truncated, all within the job's committed ceiling.
    #
    # Technical depth: the deadline branch bypassed bound_process_output/4 and
    # appended its diagnostic directly to every byte collected before the
    # deadline. A command could therefore emit megabytes below the artifact
    # ceiling, wait for its deadline, and put all of them in the receipt despite
    # declaring a much smaller max_output_bytes value.
    root = workspace()
    output_limit = 1_024

    assert {:ok, receipt} =
             run(
               root,
               "loopex.bash",
               %{
                 "argv" => [
                   "/bin/sh",
                   "-c",
                   "yes partial-output | head -c 16384; sleep 10"
                 ]
               },
               %{
                 run_deadline: System.system_time(:millisecond) + 400,
                 resource_budgets: %{
                   "max_output_bytes" => output_limit,
                   "max_wall_time_ms" => 30_000
                 }
               }
             )

    assert receipt.outcome in [:cancelled, :outcome_unknown]
    assert byte_size(receipt.output) <= output_limit
    assert receipt.output =~ "deadline passed"
    assert receipt.output =~ "output truncated"
    assert receipt.artifacts == []
  end

  test "read refuses a file larger than its artifact ceiling without loading or retaining it" do
    # Concept: a regular file has a size before it is opened, so read refuses a
    # result it cannot retain rather than first loading unbounded bytes.
    #
    # Technical depth: enforcing the ceiling only in spill/5 is too late for a
    # filesystem result: File.read has already allocated the whole file by then.
    # The identity check carries the measured size into the open, and the read is
    # independently capped in case the file grows after that measurement.
    root = workspace()
    {:ok, store} = Loopex.Executor.Local.CodingToolsTest.RecordingStore.start()

    {executor, lease_id} =
      executor_for(root, %{
        module: Loopex.Executor.Local.CodingToolsTest.RecordingStore,
        handle: store
      })

    definition = Enum.find(CodingTools.definitions(), &(&1["tool_id"] == "loopex.read"))
    artifact_limit = get_in(definition, ["budgets", "artifact_bytes"])
    exact = Path.join(root, "exactly-the-artifact-bound.txt")
    large = Path.join(root, "larger-than-the-artifact-bound.txt")

    {:ok, file} = :file.open(exact, [:write, :raw, :binary])
    {:ok, _position} = :file.position(file, artifact_limit - 1)
    :ok = :file.write(file, "x")
    :ok = :file.close(file)

    assert {:ok, %{outcome: :completed, artifacts: [reference]}} =
             run(root, "loopex.read", %{"path" => Path.basename(exact)}, %{
               executor: executor,
               lease_id: lease_id
             })

    assert reference.size == artifact_limit

    stored_at_limit = Loopex.Executor.Local.CodingToolsTest.RecordingStore.stored(store)
    assert map_size(stored_at_limit) == 1
    assert [retained] = Map.values(stored_at_limit)
    assert byte_size(retained) == artifact_limit

    {:ok, file} = :file.open(large, [:write, :raw, :binary])
    observed_size = artifact_limit + 4_096
    {:ok, _position} = :file.position(file, observed_size - 1)
    :ok = :file.write(file, "x")
    :ok = :file.close(file)

    assert {:ok, %{outcome: :failed} = receipt} =
             run(root, "loopex.read", %{"path" => Path.basename(large)}, %{
               executor: executor,
               lease_id: lease_id
             })

    assert receipt.output =~ "artifact ceiling"
    assert receipt.output =~ Integer.to_string(artifact_limit)
    assert receipt.output =~ Integer.to_string(observed_size)
    assert receipt.artifacts == []

    assert Loopex.Executor.Local.CodingToolsTest.RecordingStore.stored(store) == stored_at_limit,
           "the refused oversized file changed the retained exact-bound artifact"

    # Loading is not safely measurable from outside File without making a huge
    # allocation the test's failure mode, so the preflight half is explicitly
    # structural. The open-handle half is behavioural: a small fixed file drives
    # the exact branch a file that grew after the preflight would reach, without
    # making this locked case depend on winning a filesystem race.
    source = File.read!(Path.expand("../lib/executor.ex", __DIR__))

    [read_clause] =
      Regex.run(
        ~r/defp filesystem_effect\(workspace, %\{kind: :read, path: path\}, limits\) do\n(.*?)\n  end\n/s,
        source,
        capture: :all_but_first
      )

    assert read_clause =~ ":ok <- within_artifact_ceiling(identity, limits.artifact)"
    assert read_clause =~ "read_verified(resolved, path, identity, limits.artifact)"

    opened_overflow = Path.join(root, "opened-overflow.txt")
    File.write!(opened_overflow, "limit+")
    {:ok, opened_file} = File.open(opened_overflow, [:read, :binary])

    try do
      assert {:artifact_ceiling_exceeded, 6} = Local.bounded_read_probe(opened_file, 5)
    after
      File.close(opened_file)
    end
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
    # First prove the child is capable of the delayed write when it remains the
    # foreground command. The guarded background form below must not be allowed
    # to perform that same write after its direct command has exited.
    reachable = Path.join(root, "reachable.txt")

    assert {:ok, %{outcome: :completed}} =
             run(root, "loopex.bash", %{
               "command" => "sleep 1; echo survived > #{reachable}"
             })

    assert File.exists?(reachable), "the descendant never writes its marker even when left alone"

    # A command whose child would outlive its direct parent: the direct child
    # exits immediately and the descendant keeps writing unless the launch-owned
    # guard ends the rest of its still-anchored group before releasing itself.
    marker = Path.join(root, "survivor.txt")

    assert {:ok, %{outcome: outcome}} =
             run(
               root,
               "loopex.bash",
               %{"command" => "( sleep 1; echo survived > #{marker} ) & exit 0"},
               %{}
             )

    assert outcome == :completed

    Process.sleep(2_500)
    refute File.exists?(marker), "a descendant survived its job's process group"
  end

  test "the child leads its own process group without a session launcher" do
    # Concept: the guarantee is that the group is the executor's own, and it does
    # not depend on a program that may not be installed.
    #
    # Technical depth: the code and the operator documentation both attributed
    # the group to `setsid`, and said that where none is found the child leads no
    # new group. Neither is true: the port spawn puts the child in a group of its
    # own before the command runs, so the group the child announces is never this
    # runtime's. Adding a session launcher after that spawn can fork away from the
    # stable group identity and make exit status and cleanup observe different
    # processes, so the executor deliberately has no such intermediate layer.
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

    assert {:error, {:refused_before_effect, :effective_deadline_reached}} = answer

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
    assert receipt.cleanup_confirmation == :confirmed
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
    assert edited.cleanup_confirmation == :confirmed
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
    assert receipt.cleanup_confirmation == :confirmed

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

  test "read refuses a device special file rather than treating it as ordinary" do
    # Concept: device nodes are not files the model may read through the
    # workspace tool, even when the host deliberately mounts one beneath the
    # configured workspace root.
    #
    # Technical depth: the named-pipe case above protects `:other`, but a
    # mutation admitting `File.Stat.type == :device` still left the locked lane
    # green and let `loopex.read` complete against `/dev/null`. Drive that exact
    # host-visible shape so every non-regular branch of `ordinary_file/3` cannot
    # be weakened to a type allowlist without detection.
    assert File.lstat!("/dev/null").type == :device

    assert {:ok, %{outcome: :failed, output: output}} =
             run("/dev", "loopex.read", %{"path" => "null"})

    assert output =~ "refused:"
    assert output =~ "is a device, not a regular file"
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
    assert receipt.cleanup_confirmation == :confirmed
    assert receipt.output =~ "workspace lease was lost"
    assert receipt.output =~ "unproven"
    assert receipt.artifacts == []
    assert {:ok, ^receipt} = Local.receipt(executor, receipt.job_id)
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
    {executor, lease_id, lease, ledger} = executor_lease_and_ledger(root)

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

    assert receipt.cleanup_confirmation == :confirmed,
           "confirmed process-group cleanup was erased by the later lease loss"

    assert receipt.output =~ "workspace lease was lost"
    assert receipt.output =~ "unproven"

    # The returned and retained bytes are the same fact. Confirmed process-group
    # cleanup permits the open authority to be removed even though lease loss
    # makes the operation outcome unknown.
    assert retained_receipt!(ledger, receipt.job_id) == receipt
    assert {:ok, ^receipt} = Local.receipt(executor, receipt.job_id)
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

    assert receipt.cleanup_confirmation == :confirmed,
           "the childless filesystem tool lost its independent cleanup fact"

    assert receipt.output =~ "workspace lease was lost"
    assert receipt.output =~ "unproven"

    # The replacement has to have overwritten the one the abandoned write may
    # have left behind. This childless effect was positively stopped, so the
    # independent cleanup fact permits its open authority to be removed.
    assert retained_receipt!(ledger, receipt.job_id) == receipt
    assert {:ok, ^receipt} = Local.receipt(executor, receipt.job_id)

    # Nothing half-written is left in the ledger.
    assert {:ok, entries} = File.ls(ledger)
    refute Enum.any?(entries, &String.contains?(&1, ".tmp-")), inspect(entries)
  end

  test "a process group is confirmed clean only by a ps that answered" do
    # Concept: absence from a complete process table is evidence; silence from a
    # different program or one that died is not.
    #
    # Technical depth: BSD `ps -g` selects a process group while procps `-g`
    # selects a session. Production asks for every PID and PGID and filters the
    # exact second column itself. The helper guard is a known witness in its own
    # group, so an arbitrary configured program such as `/usr/bin/true` cannot
    # pass by returning empty output and zero.
    witness = 700
    absent_group = 900
    table = "  42    42\n 700   700\n"

    assert Local.process_group_answered_empty?({table, 0}, absent_group, witness)

    refute Local.process_group_answered_empty?(
             {table <> " 48965   900\n", 0},
             absent_group,
             witness
           )

    refute Local.process_group_answered_empty?({"", 0}, absent_group, witness),
           "an empty answer from an arbitrary configured executable proved quiescence"

    refute Local.process_group_answered_empty?({table, 1}, absent_group, witness)
    refute Local.process_group_answered_empty?({table, 137}, absent_group, witness)

    refute Local.process_group_answered_empty?(
             {"not a process table\n", 0},
             absent_group,
             witness
           )

    refute Local.process_group_answered_empty?(:no_answer, absent_group, witness)
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
    # There is one spawn boundary. Jobs and bounded cleanup probes both reach
    # `open_launcher/4`, so the production-path observation above covers every
    # first image. A separate direct helper spawn is precisely how environment
    # handling and process authority drifted before: no call site may bypass the
    # common option list or turn a sampled PID into permission for a later
    # `/bin/kill`.
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

    assert length(spawns) == 1,
           "this executor now opens #{length(spawns)} ports; every one of them is an image the " <>
             "loader reaches, so each needs its own constructed environment and this case needs " <>
             "to have been told about it"

    # Every caller reaches its `env:` through `launcher_port_options/2`, which
    # the probe case above observes behaviourally at the spawn.
    assert source =~ "options = launcher_port_options(environment, workspace)",
           "the job launcher no longer derives the option list whose environment the " <>
             "production-path probe observes"

    assert Enum.count(spawns, &String.contains?(&1, "++ options")) == 1,
           "the single launch port no longer receives the production option list"

    assert source =~
             ~r/defp guarded_answer_within\(program, arguments, bound\).*?process_launcher\(%\{helper: \[program \| arguments\]\}, environment\).*?open_launcher\(launcher, command_arguments, environment/s,
           "bounded helpers no longer use the same guarded launcher and environment boundary"

    refute source =~ ~s|{:spawn_executable, ~c"/bin/kill"}|,
           "a helper timeout turned a sampled numeric PID into signal authority"

    refute source =~ "defp signal_helper(",
           "a second process can still deliver a late signal to a sampled helper PID"

    assert source =~
             ~r/defp finish_guarded_helper.*?1 <- occurrences\(output, acknowledgement\)/s,
           "a queued helper KILL can be mistaken for one the live guard processed"

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
    assert receipt.output =~ "deadline passed"
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

    # ADR 0016 admits the effect under a root-wide claim before it runs, and that
    # claim needs the same directory write bit retention does, so a ledger made
    # read-only up front now fails at admission. The case isolates retention by
    # withdrawing the write bit only once the tool is observably running.
    observer = self()

    task =
      Task.async(fn ->
        run(root, "loopex.bash", %{"command" => "sleep 1"}, %{
          executor: executor,
          lease_id: lease_id,
          execute_options: [notify: observer]
        })
      end)

    assert_receive {:executor_process_started, _job_id, "loopex.bash", _environment}, 5_000
    File.chmod!(ledger, 0o500)
    on_exit(fn -> File.chmod(ledger, 0o700) end)

    # The settlement takes the root claim before it writes, so a ledger whose
    # write bit is gone refuses the claim rather than the rename, and the same
    # `:eacces` arrives inside the bounded ledger-unavailability that a claim
    # this settlement could not take always is. The fact the case asserts is
    # unchanged: no receipt reached the ledger and the reply says so rather than
    # answering with one.
    assert {:error, {:receipt_not_retained, {:ledger_unavailable, :eacces}}} =
             Task.await(task, 10_000)

    # Nothing was left behind in the ledger either: no receipt and no staging
    # file, so a later reader cannot find a partial receipt where this executor
    # reported none. The root's own structure - generation, markers, open index -
    # is not a receipt.
    {:ok, entries} = File.ls(ledger)

    refute Enum.any?(
             entries,
             &(String.ends_with?(&1, ".receipt") or String.contains?(&1, ".tmp-"))
           ),
           inspect(entries)
  end

  test "receipt publication syncs its file and parent directory before reporting durability" do
    # Concept: a receipt reported retained must survive the same crash boundary
    # as the terminal fact it represents.
    #
    # Technical depth: a healthy filesystem cannot reveal whether the parent
    # directory was synced, so this is one of the narrow structural assertions
    # the suite uses for an otherwise unobservable syscall boundary. The actual
    # write is still driven through the production executor and read back below.
    source = File.read!(Path.expand("../lib/executor.ex", __DIR__))

    assert source =~
             ~r/with :ok <- write_synced_receipt\(temporary, bytes\),\n\s+:ok <- File\.rename\(temporary, path\),\n\s+:ok <- sync_parent_directory\(path\)/,
           "receipt publication no longer orders file sync, rename, and directory sync"

    assert source =~
             ~r/defp write_synced_receipt\(path, bytes\).*?:file\.sync\(file\)/s,
           "the receipt bytes are not synced before publication"

    assert source =~
             ~r/defp sync_parent_directory\(path\).*?:file\.open\(directory, \[:raw, :read, :directory\]\).*?:file\.sync\(file\)/s,
           "the directory entry is not synced after publication"

    root = workspace()

    assert {:ok, receipt} =
             run(root, "loopex.write", %{"path" => "durable.txt", "content" => "durable"})

    assert receipt.outcome == :completed
  end

  test "a bounded result completed under a live lease remains admitted after later lease loss" do
    # Concept: later scheduling cannot reverse authority that covered completed
    # work.
    #
    # Technical depth: the worker result and the lease monitor are independent
    # signal paths. Suspend the exact waiter, let its worker finish and queue the
    # successful value with its completion-bound lease fact, then kill the lease
    # before the waiter can inspect either message. Re-sampling in the waiter
    # would falsely abandon work that completed while its lease was live.
    root = workspace()
    {_executor, _lease_id, lease} = executor_and_lease(root)
    Process.unlink(lease)
    parent = self()

    waiter =
      spawn(fn ->
        monitor = Process.monitor(lease)

        result =
          Local.bounded_work(
            fn ->
              send(parent, {:bounded_worker_ready, self()})

              receive do
                :finish_bounded_work -> :retained
              end
            end,
            5_000,
            {monitor, lease}
          )

        send(parent, {:bounded_waiter_result, result})
      end)

    on_exit(fn ->
      resume_if_suspended(waiter)
      if Process.alive?(waiter), do: Process.exit(waiter, :kill)
    end)

    assert_receive {:bounded_worker_ready, worker}, 2_000
    assert :erlang.suspend_process(waiter)
    send(worker, :finish_bounded_work)

    assert :ok =
             await_queued_message(
               waiter,
               fn
                 {tag, {:done, :retained}} when is_reference(tag) ->
                   true

                 _other ->
                   false
               end,
               2_000
             )

    lease_monitor = Process.monitor(lease)
    Process.exit(lease, :kill)
    assert_receive {:DOWN, ^lease_monitor, :process, ^lease, :killed}, 2_000

    assert :erlang.resume_process(waiter)

    assert_receive {:bounded_waiter_result, {:done, :retained}}, 2_000
    refute Process.alive?(worker), "bounded work returned before its effect process stopped"
  end

  test "a lease certified result survives lease loss queued ahead of guardian observation" do
    # Concept: completion under a live lease is not reversed by a later revocation.
    #
    # Technical depth: suspend the sole decider, let the effect obtain its
    # certificate from the live lease and exit, then revoke the lease before the
    # guardian can inspect either signal. Re-sampling lease liveness in the
    # guardian makes this valid result fail; the lease-authored certificate does
    # not.
    root = workspace()
    {_executor, _lease_id, lease} = executor_and_lease(root)
    Process.unlink(lease)
    parent = self()

    waiter =
      spawn(fn ->
        result =
          Local.bounded_work(
            fn ->
              send(parent, {:lease_certificate_effect, self()})

              receive do
                :finish_with_lease -> :lease_certified
              end
            end,
            5_000,
            {Process.monitor(lease), lease}
          )

        send(parent, {:lease_certificate_result, result})
      end)

    assert_receive {:lease_certificate_effect, effect}, 2_000
    guardian = monitored_guardian(waiter, [lease, effect])
    assert is_pid(guardian)

    on_exit(fn ->
      resume_if_suspended(guardian)
      if Process.alive?(waiter), do: Process.exit(waiter, :kill)
      if Process.alive?(lease), do: Process.exit(lease, :kill)
    end)

    assert :erlang.suspend_process(guardian)
    effect_monitor = Process.monitor(effect)
    send(effect, :finish_with_lease)
    assert_receive {:DOWN, ^effect_monitor, :process, ^effect, :normal}, 2_000

    assert :ok =
             await_queued_message(
               guardian,
               fn
                 {:EXIT, ^effect, :normal} -> true
                 _other -> false
               end,
               2_000
             )

    lease_monitor = Process.monitor(lease)
    Process.exit(lease, :kill)
    assert_receive {:DOWN, ^lease_monitor, :process, ^lease, :killed}, 2_000
    assert :erlang.resume_process(guardian)

    assert_receive {:lease_certificate_result, {:done, :lease_certified}}, 2_000
  end

  test "lease loss before certification cannot admit a result that work already returned" do
    # Concept: returned bytes are not a completion unless the workspace claim
    # certifies that it still covers their boundary.
    #
    # Technical depth: suspend the lease itself so the effect's certification
    # call is queued, then revoke it. A direct liveness sample in the effect can
    # falsely report done here; serialization inside the lease leaves the result
    # explicitly unproven.
    root = workspace()
    {_executor, _lease_id, lease} = executor_and_lease(root)
    Process.unlink(lease)
    parent = self()

    waiter =
      spawn(fn ->
        result =
          Local.bounded_work(
            fn ->
              send(parent, {:uncertified_effect, self()})

              receive do
                :return_before_certification -> :uncertified_result
              end
            end,
            5_000,
            {Process.monitor(lease), lease}
          )

        send(parent, {:uncertified_result, result})
      end)

    assert_receive {:uncertified_effect, effect}, 2_000

    on_exit(fn ->
      resume_if_suspended(lease)
      if Process.alive?(waiter), do: Process.exit(waiter, :kill)
      if Process.alive?(lease), do: Process.exit(lease, :kill)
    end)

    assert :erlang.suspend_process(lease)
    send(effect, :return_before_certification)

    assert :ok =
             await_queued_message(
               lease,
               fn
                 {:"$gen_call", _from, {:certify_completion, _table, _tag, _owner}} ->
                   true

                 _other ->
                   false
               end,
               2_000
             )

    lease_monitor = Process.monitor(lease)
    Process.exit(lease, :kill)
    assert_receive {:DOWN, ^lease_monitor, :process, ^lease, :killed}, 2_000

    assert_receive {:uncertified_result,
                    {:abandoned, :workspace_lease_lost, true, {:late, :uncertified_result}}},
                   2_000
  end

  test "a result certified inside its bound survives guardian observation after the bound" do
    # The effect stages its bound fact before the lease serializes the completion
    # certificate, and a delayed guardian does not re-sample either fact.
    root = workspace()
    {_executor, _lease_id, lease} = executor_and_lease(root)
    parent = self()

    waiter =
      spawn(fn ->
        result =
          Local.bounded_work(
            fn ->
              send(parent, {:bound_certificate_effect, self()})

              receive do
                :finish_inside_bound -> :inside_bound
              end
            end,
            3_000,
            {Process.monitor(lease), lease}
          )

        send(parent, {:bound_certificate_result, result})
      end)

    assert_receive {:bound_certificate_effect, effect}, 2_000
    guardian = monitored_guardian(waiter, [lease, effect])
    assert is_pid(guardian)

    on_exit(fn ->
      resume_if_suspended(guardian)
      if Process.alive?(waiter), do: Process.exit(waiter, :kill)
    end)

    assert :erlang.suspend_process(guardian)
    effect_monitor = Process.monitor(effect)
    send(effect, :finish_inside_bound)
    assert_receive {:DOWN, ^effect_monitor, :process, ^effect, :normal}, 2_000
    Process.sleep(3_100)
    assert :erlang.resume_process(guardian)

    assert_receive {:bound_certificate_result, {:done, :inside_bound}}, 2_000
  end

  test "a result reaching certification after its bound is not admitted" do
    # Suspending the guardian keeps it from killing the worker first, so this
    # drives the completion certificate's own bound decision rather than merely
    # the guardian timer.
    root = workspace()
    {_executor, _lease_id, lease} = executor_and_lease(root)
    parent = self()

    waiter =
      spawn(fn ->
        result =
          Local.bounded_work(
            fn ->
              send(parent, {:late_bound_effect, self()})

              receive do
                :finish_after_bound -> :after_bound
              end
            end,
            2_000,
            {Process.monitor(lease), lease}
          )

        send(parent, {:late_bound_result, result})
      end)

    assert_receive {:late_bound_effect, effect}, 2_000
    guardian = monitored_guardian(waiter, [lease, effect])
    assert is_pid(guardian)

    on_exit(fn ->
      resume_if_suspended(guardian)
      if Process.alive?(waiter), do: Process.exit(waiter, :kill)
    end)

    assert :erlang.suspend_process(guardian)
    Process.sleep(2_100)
    effect_monitor = Process.monitor(effect)
    send(effect, :finish_after_bound)
    assert_receive {:DOWN, ^effect_monitor, :process, ^effect, :normal}, 2_000

    assert :ok =
             await_queued_message(
               guardian,
               fn
                 {:EXIT, ^effect, :normal} -> true
                 _other -> false
               end,
               2_000
             )

    assert :erlang.resume_process(guardian)

    assert_receive {:late_bound_result,
                    {:abandoned, :bound_reached, true, {:late, :after_bound}}},
                   2_000
  end

  test "a dead lease refuses bounded work before its effect can start" do
    # Concept: work is not started merely so it can be rejected afterwards.
    #
    # Technical depth: the unrelated monitor reference proves the boundary's own
    # preflight checks the lease pid. Returning a late result here would mean the
    # effect ran after its authority was already known to be gone.
    root = workspace()
    {_executor, _lease_id, lease} = executor_and_lease(root)
    Process.unlink(lease)
    death = Process.monitor(lease)
    Process.exit(lease, :kill)
    assert_receive {:DOWN, ^death, :process, ^lease, :killed}, 2_000

    assert {:abandoned, :workspace_lease_lost, true, :none} =
             Local.bounded_work(fn -> flunk("effect started under a dead lease") end, 5_000, {
               make_ref(),
               lease
             })
  end

  test "guardian death reaps a trapping bounded effect before reporting an unproven result" do
    # Concept: the process reporting the verdict may fail, but the work it owned
    # still may not escape.
    #
    # Technical depth: the effect traps ordinary linked exits, so killing only
    # its guardian leaves it live. The caller's fallback monitor must issue an
    # untrappable kill, confirm that exact effect down, and return a distinct
    # guardian failure rather than a successful or ordinarily failed operation.
    root = workspace()
    marker = Path.join(root, "guardian-survivor.txt")
    {_executor, _lease_id, lease} = executor_and_lease(root)
    parent = self()

    source = File.read!(Path.expand("../lib/executor.ex", __DIR__))

    assert source =~
             ~r/effect =\n\s*spawn_link\(fn ->.*?send\(caller, \{guardian_tag, :guardian_effect, guardian, effect\}\)/s,
           "the effect is not linked to its guardian before the caller learns its identity"

    waiter =
      spawn(fn ->
        lease_monitor = Process.monitor(lease)

        result =
          Local.bounded_work(
            fn ->
              Process.flag(:trap_exit, true)
              send(parent, {:guardian_effect_ready, self()})

              receive do
                :continue_after_guardian -> File.write(marker, "escaped")
              end
            end,
            5_000,
            {lease_monitor, lease}
          )

        send(parent, {:guardian_waiter_result, result})
      end)

    assert_receive {:guardian_effect_ready, effect}, 2_000

    guardian = monitored_guardian(waiter, [lease, effect])

    assert is_pid(guardian), "the bounded-work caller did not monitor its guardian"

    on_exit(fn ->
      if Process.alive?(waiter), do: Process.exit(waiter, :kill)
      if Process.alive?(guardian), do: Process.exit(guardian, :kill)
      if Process.alive?(effect), do: Process.exit(effect, :kill)
    end)

    effect_monitor = Process.monitor(effect)
    Process.exit(guardian, :kill)

    assert_receive {:DOWN, ^effect_monitor, :process, ^effect, :killed}, 2_000
    assert_receive {:guardian_waiter_result, {:guardian_stopped, :killed, true}}, 2_000

    send(effect, :continue_after_guardian)
    refute File.exists?(marker)
  end

  test "a guarded filesystem result completed under a live lease survives later lease loss" do
    # The owner-aware boundary has a separate result receiver. Exercise the same
    # completion-before-later-loss ordering there so one branch cannot regain a
    # waiter-time liveness sample while the retention branch stays correct.
    root = workspace()
    {executor, _lease_id, lease} = executor_and_lease(root)
    Process.unlink(lease)
    parent = self()

    waiter =
      spawn(fn ->
        monitor = Process.monitor(lease)

        result =
          Local.bounded_work(
            fn ->
              send(parent, {:guarded_worker_ready, self()})

              receive do
                :finish_guarded_work -> :effect_result
              end
            end,
            5_000,
            {monitor, lease},
            executor
          )

        send(parent, {:guarded_waiter_result, result})
      end)

    on_exit(fn ->
      resume_if_suspended(waiter)
      if Process.alive?(waiter), do: Process.exit(waiter, :kill)
    end)

    assert_receive {:guarded_worker_ready, worker}, 2_000
    assert :erlang.suspend_process(waiter)
    send(worker, :finish_guarded_work)

    assert :ok =
             await_queued_message(
               waiter,
               fn
                 {tag, {:done, :effect_result}} when is_reference(tag) ->
                   true

                 _other ->
                   false
               end,
               2_000
             )

    lease_monitor = Process.monitor(lease)
    Process.exit(lease, :kill)
    assert_receive {:DOWN, ^lease_monitor, :process, ^lease, :killed}, 2_000

    assert :erlang.resume_process(waiter)

    assert_receive {:guarded_waiter_result, {:done, :effect_result}}, 2_000
    refute Process.alive?(worker), "guarded work returned before its effect process stopped"
  end

  test "a guarded result completed under its owner survives later owner loss" do
    # Concept: authority loss cannot retroactively reverse work that completed
    # while that authority still existed.
    #
    # Technical depth: suspend the guardian after the effect starts, let the
    # effect bind its completion certificate, and only then stop the owner. The
    # guardian sees the queued result after the owner is dead; a waiter-time
    # Process.alive?/1 sample would reject it, while the completion-bound owner
    # fact admits it.
    root = workspace()
    {executor, _lease_id, lease} = executor_and_lease(root)
    Process.unlink(executor)
    Process.unlink(lease)
    parent = self()

    waiter =
      spawn(fn ->
        lease_monitor = Process.monitor(lease)

        result =
          Local.bounded_work(
            fn ->
              send(parent, {:owner_certificate_effect_ready, self()})

              receive do
                :finish_under_owner -> :owner_bound_result
              end
            end,
            5_000,
            {lease_monitor, lease},
            executor
          )

        send(parent, {:owner_certificate_result, result})
      end)

    assert_receive {:owner_certificate_effect_ready, effect}, 2_000

    guardian = monitored_guardian(waiter, [lease, effect])

    assert is_pid(guardian)

    on_exit(fn ->
      if Process.alive?(guardian) and
           Process.info(guardian, :status) == {:status, :suspended},
         do: :erlang.resume_process(guardian)

      if Process.alive?(waiter), do: Process.exit(waiter, :kill)
    end)

    assert :erlang.suspend_process(guardian)
    effect_monitor = Process.monitor(effect)
    send(effect, :finish_under_owner)
    assert_receive {:DOWN, ^effect_monitor, :process, ^effect, :normal}, 2_000

    assert :ok =
             await_queued_message(
               guardian,
               fn
                 {:EXIT, ^effect, :normal} -> true
                 _other -> false
               end,
               2_000
             )

    Process.exit(executor, :kill)
    assert :erlang.resume_process(guardian)

    assert_receive {:owner_certificate_result, {:done, :owner_bound_result}}, 2_000
  end

  test "owner loss before certification cannot be hidden by a queued result" do
    # Suspend the decider, revoke the Local owner, and only then let the effect
    # return. The lease-authored certificate records the dead owner even if the
    # effect EXIT is the first signal the guardian later reads.
    root = workspace()
    {executor, _lease_id, lease} = executor_and_lease(root)
    Process.unlink(executor)
    parent = self()

    waiter =
      spawn(fn ->
        result =
          Local.bounded_work(
            fn ->
              send(parent, {:owner_negative_effect, self()})

              receive do
                :finish_without_owner -> :ownerless_result
              end
            end,
            5_000,
            {Process.monitor(lease), lease},
            executor
          )

        send(parent, {:owner_negative_result, result})
      end)

    assert_receive {:owner_negative_effect, effect}, 2_000
    guardian = monitored_guardian(waiter, [lease, effect])
    assert is_pid(guardian)

    on_exit(fn ->
      resume_if_suspended(guardian)
      if Process.alive?(waiter), do: Process.exit(waiter, :kill)
      if Process.alive?(executor), do: Process.exit(executor, :kill)
    end)

    assert :erlang.suspend_process(guardian)
    owner_monitor = Process.monitor(executor)
    Process.exit(executor, :kill)
    assert_receive {:DOWN, ^owner_monitor, :process, ^executor, :killed}, 2_000
    effect_monitor = Process.monitor(effect)
    send(effect, :finish_without_owner)
    assert_receive {:DOWN, ^effect_monitor, :process, ^effect, :normal}, 2_000

    assert :ok =
             await_queued_message(
               guardian,
               fn
                 {:EXIT, ^effect, :normal} -> true
                 _other -> false
               end,
               2_000
             )

    assert :erlang.resume_process(guardian)

    assert_receive {:owner_negative_result,
                    {:abandoned, :effect_owner_lost, true, {:late, :ownerless_result}}},
                   2_000
  end

  test "bounded work caller loss reaps its exact effect before the guardian exits" do
    # Concept: a caller that can no longer settle a result cannot leave its
    # effect running without an observer.
    #
    # Technical depth: the effect traps ordinary exits and is not linked to the
    # caller. Only the guardian's caller monitor and exact untrappable reap can
    # stop it. Deleting that branch lets the later marker appear.
    root = workspace()
    marker = Path.join(root, "caller-loss-survivor.txt")
    {_executor, _lease_id, lease} = executor_and_lease(root)
    parent = self()

    waiter =
      spawn(fn ->
        Local.bounded_work(
          fn ->
            Process.flag(:trap_exit, true)
            send(parent, {:caller_loss_effect, self()})

            receive do
              :write_after_caller -> File.write(marker, "escaped")
            end
          end,
          5_000,
          {Process.monitor(lease), lease}
        )
      end)

    assert_receive {:caller_loss_effect, effect}, 2_000
    guardian = monitored_guardian(waiter, [lease, effect])
    assert is_pid(guardian)
    effect_monitor = Process.monitor(effect)
    guardian_monitor = Process.monitor(guardian)

    on_exit(fn ->
      if Process.alive?(waiter), do: Process.exit(waiter, :kill)
      if Process.alive?(guardian), do: Process.exit(guardian, :kill)
      if Process.alive?(effect), do: Process.exit(effect, :kill)
    end)

    Process.exit(waiter, :kill)
    assert_receive {:DOWN, ^effect_monitor, :process, ^effect, :killed}, 2_000
    assert_receive {:DOWN, ^guardian_monitor, :process, ^guardian, :normal}, 2_000

    send(effect, :write_after_caller)
    refute File.exists?(marker)
  end

  test "a dead lease refuses owner guarded work before its effect can start" do
    # The owner-aware form has the same preflight. A live Local owner cannot
    # substitute for the workspace claim the effect also requires.
    root = workspace()
    {executor, _lease_id, lease} = executor_and_lease(root)
    Process.unlink(lease)
    death = Process.monitor(lease)
    Process.exit(lease, :kill)
    assert_receive {:DOWN, ^death, :process, ^lease, :killed}, 2_000

    assert {:abandoned, :workspace_lease_lost, true, :none} =
             Local.bounded_work(
               fn -> flunk("guarded effect started under a dead lease") end,
               5_000,
               {make_ref(), lease},
               executor
             )
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
    # `process_group_answered_empty?/3` is.
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
    refute Local.process_group_answered_empty?(:no_answer, 900, 700)

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
    # The demonstration now uses the same owned process-group launcher as bash.
    # Reaching the deadline while the lease still holds therefore produces a
    # proved cancellation with confirmed cleanup rather than an unknown effect.
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

    assert receipt.outcome == :cancelled
    assert receipt.cleanup_confirmation == :confirmed
    assert receipt.output =~ "run deadline"
    assert receipt.output =~ "confirmed cleaned"

    Process.sleep(delay + 500)
    refute File.exists?(Path.join(root, "delayed.txt"))
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

    File.write!(Path.join(root, "read.txt"), "read me")
    File.write!(Path.join(root, "edit.txt"), "before")

    receipts =
      for {tool_id, arguments} <- [
            {"loopex.read", %{"path" => "read.txt"}},
            {"loopex.write", %{"path" => "budgeted.txt", "content" => "x"}},
            {"loopex.edit", %{"path" => "edit.txt", "old" => "before", "new" => "after"}},
            {"loopex.bash", %{"argv" => ["printf", "ok"]}}
          ] do
        assert {:ok, receipt} =
                 run(root, tool_id, arguments, %{
                   executor: executor,
                   lease_id: lease_id,
                   cleanup_grace_ms: 750
                 })

        assert receipt.cleanup_grace_ms == 750,
               "#{tool_id} reported #{inspect(receipt.cleanup_grace_ms)} rather than the " <>
                 "configured 750ms cleanup period"

        # The durable record carries it too, so a coordinator recovering this
        # job reads the period it was bounded by rather than the one running now.
        assert {:ok, retained} = Local.receipt(executor, receipt.job_id)

        assert retained.cleanup_grace_ms == 750,
               "#{tool_id}'s retained receipt reported " <>
                 "#{inspect(retained.cleanup_grace_ms)} rather than 750ms"

        receipt
      end

    assert Enum.map(receipts, & &1.tool_id) == [
             "loopex.read",
             "loopex.write",
             "loopex.edit",
             "loopex.bash"
           ],
           "the every-receipt claim no longer exercises every shipped tool"

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
    where = %{executor: executor, lease_id: lease_id, cleanup_grace_ms: grace}

    assert {:ok, quiet} =
             run(root, "loopex.write", %{"path" => "quiet.txt", "content" => "x"}, where)

    assert quiet.cleanup_grace_ms == grace

    # ADR 0016 fixes the receipt retention bound at the committed quarter reserve,
    # max(1, ceil(grace / 4)), whether or not the job opened a cleanup episode; the
    # period itself governs cleanup, not retention.
    assert quiet.receipt_retention_bound_ms == max(1, div(grace + 3, 4)),
           "a job that needed no cleanup did not retain under the committed quarter reserve: " <>
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
    #
    # ADR 0016 makes the period a job spends the one its own request committed,
    # so each run commits the period its executor was composed with, exactly as
    # the shipped composition does. Leaving the request at the port default made
    # both runs spend the same period and the comparison below hold only by
    # jitter.
    root = workspace()

    {small_executor, small_lease} = executor_with_grace(root, 600)
    {large_executor, large_lease} = executor_with_grace(root, 3_000)

    {small_ms, small} =
      elapsed(fn ->
        run(root, "loopex.bash", %{"command" => stubborn_group_command()}, %{
          executor: small_executor,
          lease_id: small_lease,
          cleanup_grace_ms: 600
        })
      end)

    {large_ms, large} =
      elapsed(fn ->
        run(root, "loopex.bash", %{"command" => stubborn_group_command()}, %{
          executor: large_executor,
          lease_id: large_lease,
          cleanup_grace_ms: 3_000
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

    # Four since ADR 0016's shared retention deadline: the job's cleanup episode,
    # a cancellation's own episode, the cooperative share inside both, and the
    # one retention allowance every phase of a settlement draws on.
    assert length(instants) == 4,
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
    # ADR 0016 then made the committed request value the period a cancellation
    # spends, and the executor start option the default for a request that names
    # none, so each job here commits the period its executor was composed with.
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
          job_id: job_id,
          cleanup_grace_ms: 3_000
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
          job_id: tight_job,
          # ADR 0016 makes the committed request value the period a cancellation
          # spends, and the admitted domain starts at one, so the shortest
          # period a job can commit is what stands in for the executor's zero.
          cleanup_grace_ms: 1
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

    # ADR 0016 clause 4: "An absent ID has no request digest and answers
    # unconfirmed without durable cancellation state." This assertion read
    # `{:ok, :cleaned}`, which is the claim that the job never started or already
    # finished -- a claim no record supports. Absence is not proof.
    assert Local.cancel(executor, "no-such-job") == {:ok, :unconfirmed}

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
          job_id: blind_job,
          cleanup_grace_ms: 3_000
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
          job_id: stubborn_job,
          cleanup_grace_ms: 3_000
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

      # ADR 0016 clause 4: an absent ID answers unconfirmed. This assertion read
      # `{:ok, :cleaned}` on the reasoning that an unknown job has no process
      # tree left to clean; having no record of a tree is not the same as having
      # confirmed there is none. What this case is actually about -- that
      # cancelling one identity leaves a different live job alone -- is proved by
      # the `continued` file below and is unaffected by the answer's name.
      assert Local.cancel(executor, wrong_job_id) == {:ok, :unconfirmed},
             "an unknown job has no durable cancellation state and cannot answer cleaned"

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

  test "an abrupt local executor death cannot report clean while its owned child may still act" do
    # Concept: losing the hand that serialized a job cannot turn missing
    # process-local bookkeeping into proof that the operating-system work is
    # gone.
    #
    # Technical depth: the command proves it began, waits, and then attempts a
    # second effect. Killing the real executor destroys its ETS table. The Port
    # worker must nevertheless observe that owner death, terminate the captured
    # group, and prevent the delayed effect; `cancel/2` against the unavailable
    # executor must stay unconfirmed because its caller cannot observe the
    # worker's proof. Restoring direct Port ownership lets the delayed write land;
    # reading a dead executor as an ordinary lookup miss makes the cancellation
    # assertion fail.
    root = workspace()
    ready = Path.join(root, "owner-death-ready")
    survived = Path.join(root, "owner-death-survived")
    job_id = "owner-death-#{System.unique_integer([:positive])}"
    {executor, lease_id} = executor_for(root)
    Process.unlink(executor)
    owner = self()

    {_caller, caller_monitor} =
      spawn_monitor(fn ->
        answer =
          try do
            run(
              root,
              "loopex.bash",
              %{
                "argv" => [
                  "/bin/sh",
                  "-c",
                  "printf ready > \"$1\"; sleep 1; printf survived > \"$2\"",
                  "loopex-owner-death",
                  ready,
                  survived
                ]
              },
              %{executor: executor, lease_id: lease_id, job_id: job_id}
            )
          catch
            :exit, reason -> {:executor_exit, reason}
          end

        send(owner, {:owner_death_execute_answer, answer})
      end)

    assert {:ok, ^ready} =
             await_path(fn -> if File.exists?(ready), do: {:ok, ready}, else: :error end, 5_000)

    Process.exit(executor, :kill)

    assert Local.cancel(executor, job_id) == {:ok, :unconfirmed}
    assert_receive {:owner_death_execute_answer, {:ok, %{outcome: :outcome_unknown}}}, 5_000
    assert_receive {:DOWN, ^caller_monitor, :process, _caller, :normal}, 5_000

    Process.sleep(1_200)

    refute File.exists?(survived),
           "a command owned by the dead executor continued and wrote after its owner vanished"
  end

  test "a command owner crash closes control and the live guard reaps its silent group" do
    # Concept: the operating-system guard, not the BEAM worker's continued
    # existence, is the final owner of a command that has already started.
    #
    # Technical depth: an abrupt worker exit closes the Port's control stdin.
    # The guard must observe that EOF while the command is silent and terminate
    # the group it still anchors. Merely returning an unconfirmed receipt is not
    # enough: without the concurrent control read, the silent descendant below
    # remains in the operating-system process table after the worker and receipt
    # owner have both moved on.
    root = workspace()
    ready = Path.join(root, "port-owner-crash-ready")
    job_id = "port-owner-crash-#{System.unique_integer([:positive])}"
    {executor, lease_id} = executor_for(root)

    running =
      Task.async(fn ->
        run(
          root,
          "loopex.bash",
          %{
            "command" =>
              "(printf ready > #{shell_path(ready)}; while :; do :; done) & while :; do :; done"
          },
          %{executor: executor, lease_id: lease_id, job_id: job_id, cleanup_grace_ms: 600}
        )
      end)

    assert {:ok, ^ready} =
             await_path(fn -> if File.exists?(ready), do: {:ok, ready}, else: :error end, 5_000)

    {:dictionary, dictionary} = Process.info(executor, :dictionary)
    table = Keyword.fetch!(dictionary, :loopex_inflight_table)
    authority_key = {:loopex_process_authority, job_id}

    assert {:ok, worker} =
             await_path(
               fn ->
                 case :ets.lookup(table, authority_key) do
                   [{^authority_key, worker, 600}] when is_pid(worker) -> {:ok, worker}
                   _not_published -> :error
                 end
               end,
               5_000
             )

    assert [{^job_id, group}] = :ets.lookup(table, job_id)
    assert is_integer(group) and group > 1

    Process.exit(worker, :kill)

    assert {:ok, receipt} = Task.await(running, 5_000)
    assert receipt.outcome == :outcome_unknown
    assert receipt.cleanup_confirmation == :unconfirmed

    assert {:ok, ^group} =
             await_path(
               fn -> if process_group_empty?(group), do: {:ok, group}, else: :error end,
               5_000
             ),
           "the Port-owned guard did not reap the group after control stdin closed"
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
      Regex.run(
        ~r/defp read_verified\(resolved, path, identity, artifact_limit\) do\n(.*?)\n  end\n/s,
        source,
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
        Local.answer_within(
          "/bin/sh",
          ["-c", "(sleep 1; printf x > #{shell_path(written)}) & sleep 20"],
          150
        )
      end)

    assert answer == :no_answer
    assert answered_ms < 1_500, "the bound was not honoured: #{answered_ms}ms"

    # The writer is a descendant rather than the direct helper shell. Killing
    # only that shell would leave the writer alive and make this assertion fail.
    Process.sleep(1_500)

    refute File.exists?(written),
           "the helper outlived its bound and completed its work afterwards"

    # A helper that answers inside its bound is unaffected: the kill is the
    # abandonment path and not the ordinary one.
    assert {output, 0} = Local.answer_within("/bin/sh", ["-c", "printf answered"], 5_000)
    assert output == "answered"
  end

  test "the launch guard preserves fast command status and remains the only group signal authority" do
    root = workspace()

    assert {:ok, succeeded} =
             run(root, "loopex.bash", %{"argv" => ["/usr/bin/true"]})

    assert succeeded.outcome == :completed
    assert succeeded.cleanup_confirmation == :confirmed

    assert {:ok, failed} =
             run(root, "loopex.bash", %{"argv" => ["/usr/bin/false"]})

    assert failed.outcome == :failed
    assert failed.cleanup_confirmation == :confirmed
    assert failed.output =~ "status 1"

    # Concept: the Port's operating-system child is an authority object, not a
    # sampled number. It stays alive until this runtime has either released an
    # already-quiescent group or sent the group's one final KILL.
    #
    # Technical depth: the fast commands above kill the common wait-loop mutant:
    # checking `kill -0` before the first unconditional `wait` skips a child that
    # already exited and reports the wrapper's sentinel status. The structural
    # half covers the authority transitions that are otherwise deliberately hard
    # to race in a deterministic case. It also makes each requested mutant local:
    # restoring an exec launcher removes the waiting guard, releasing before the
    # quiescence check changes the order, signalling a released guard fails the
    # live-state guard, counting the guard as a survivor changes the exact ps
    # answer, and admitting a missing/duplicate control frame breaks the final
    # protocol conjunction.
    {"/usr/bin/env", vector} = Local.launcher_vector(%{argv: ["/usr/bin/true"]})
    carrier = Enum.at(vector, Enum.find_index(vector, &(&1 == "-c")) + 1)
    script = Enum.at(vector, Enum.find_index(vector, &(&1 == "loopex-port-carrier")) + 1)

    assert carrier =~
             ~r/mode=\$1.*?if \[ "\$mode" = helper \]; then.*?set -m.*?sh -c "\$guard_script" "\$guard_name" "\$carrier_pid" "\$@" <&0 &.*?set \+m.*?else.*?sh -c "\$guard_script" "\$guard_name" "\$carrier_pid" "\$@" <&0 &/s

    assert carrier =~
             ~r/if \[ "\$mode" != helper \]; then.*?kill -TERM -- -"\$carrier_pid".*?kill -KILL -- -"\$carrier_pid"/s,
           "the carrier no longer reaps its still-anchored command group after guard loss"

    refute carrier =~ ~r/guard_group=.*?kill -(?:TERM|KILL) -- -"\$guard_group"/s,
           "the helper carrier signals a detached sampled group after its guard has exited"

    assert carrier =~ ~r/while :; do\n\s+wait "\$guard_pid"/
    assert script =~ "IFS= read -r init"
    assert script =~ "IFS= read -r permit"

    assert script =~
             ~r/carrier_group=\$1.*?if \[ "\$mode" = helper \]; then\s+group_id=\$\$\s+else\s+group_id=\$carrier_group/s

    refute script =~ ~r/group_id=\$\(.*?ps /s
    assert script =~ ~r/while :; do\n\s+wait \"\$command_pid\"/
    assert script =~ "while IFS= read -r control"
    assert script =~ ~r/case " \$\(jobs -p\) ".*?\*" \$command_pid "\*\).*?\*\) break/s
    refute script =~ ~s|kill -0 "$command_pid"|
    assert script =~ "trap - HUP INT PIPE\n  trap ':' TERM"

    assert script =~
             ~r/'loopex-signal:'"\$token"':TERM'\).*?trap '' TERM.*?kill -TERM -- -"\$group_id".*?trap 'guard_abort' TERM/s,
           "a cooperative group TERM no longer masks an external owner-loss TERM permanently"

    assert script =~
             ~r/'loopex-signal:'"\$token"':KILL'\).*?if \[ "\$mode" = helper \]; then.*?loopex-signal-accepted:%s:KILL.*?kill -KILL -- -"\$group_id"/s,
           "the live guard no longer acknowledges and performs the final group KILL"

    assert script =~ "guard_abort"
    assert script =~ "trap 'guard_abort' HUP INT PIPE TERM"

    assert script =~
             ~r/guard_abort\(\) \{\s+trap '' TERM\s+\[ -n "\$group_id" \] && kill -TERM -- -"\$group_id"/,
           "the abort trap can recurse on the group TERM it sends itself"

    assert script =~ ~r/\*\) guard_abort ;;/
    refute script =~ "exec \"$@\""

    # The unpredictable token is supplied only after Port.open; neither launcher
    # form can disclose it to the model command in argv or environment.
    refute Enum.any?(vector, &String.starts_with?(&1, "loopex-init:"))
    refute Enum.any?(vector, &String.starts_with?(&1, "loopex-run:"))

    source = File.read!(Path.expand("../lib/executor.ex", __DIR__))

    [signal_boundary] =
      Regex.run(
        ~r/defp signal_guard_group\(guard, signal\).*?\n  end\n\n  defp launch_guard_live/s,
        source
      )

    assert signal_boundary =~ "if launch_guard_live?(guard)"

    assert signal_boundary =~
             ~S|safe_port_command(guard.port, "#{@guard_signal}:#{guard.token}:#{signal_name}\n")|,
           "a group signal is no longer actuated by its live Port-owned guard"

    refute signal_boundary =~ "/bin/kill",
           "the runtime turned a sampled numeric group into signal authority"

    [waiting_close] =
      Regex.run(
        ~r/defp close_waiting_guard\(port, token\).*?\n  end\n\n  # Concept:/s,
        source
      )

    assert waiting_close =~
             ~S|safe_port_command(port, "#{@guard_abort}:#{token}\n")|

    refute waiting_close =~ "abandon_helper",
           "a pre-permit refusal signals a sampled process identifier"

    assert source =~
             ~r/defp quiesce_launch_guard.*?if guard_children_gone\?\(guard, episode\) do.*?release_launch_guard\(guard, episode, status_known\?\)/s,
           "the normal path can release the guard without first proving group quiescence"

    assert source =~
             ~r/defp release_launch_guard\(guard, _episode, status_known\?\) do.*?if status_known\? and launch_guard_live\?\(guard\) do\s+sent = safe_port_command/s,
           "the guard can be released without authenticated status or live Port authority"

    assert source =~
             ~r/defp guard_answered_alone\?.*?expected =\s+if carrier_in_group,\s+do: Enum\.sort\(\[anchor_pid, carrier_pid\]\),\s+else: \[anchor_pid\].*?Enum\.sort\(members\) == expected/s,
           "normal completion no longer requires every fixed authority member and no command member"

    assert source =~
             ~r/defp launch_guard_live\?\(%\{state: :live, port: port, os_pid: os_pid\}\).*?Port\.info\(port, :os_pid\) == \{:os_pid, os_pid\}/s,
           "a released or killed guard can still authorize a group signal"

    assert source =~
             ~r/protocol_proved =\s+collector\.protocol_valid and collector\.guard\.announced and guard_exit_proved/s,
           "missing, forged, or duplicate guard control evidence can be reported confirmed"

    assert source =~
             ~r/defp collect_guard_chunk\(%\{command_status: status\}.*?\{_offset, _size\} ->\s+\{:ok, %\{collector \| control_buffer: <<>>, protocol_valid: false\}\}/s,
           "a second authenticated command-status frame does not invalidate the protocol"

    assert source =~
             ~r/_invalid_frame ->\s+\{:ok, %\{collector \| control_buffer: <<>>, protocol_valid: false\}\}/s,
           "a malformed authenticated command-status frame does not invalidate the protocol"

    assert source =~
             ~r/defp launch_guard_exit_proved\?.*?:release_sent ->\s+is_integer\(collector\.command_status\) and status == 0.*?:kill_sent ->\s+status != 0.*?_missing_transition ->\s+false/s,
           "normal release is not status-bound, or an unowned guard exit is treated as proof"
  end

  test "a malformed control message makes the live guard reap its admitted group" do
    # Concept: malformed control is a refusal and cleanup event, never a way to
    # release an already-admitted command from its Port-owned guard.
    #
    # Technical depth: exiting the guard directly from the catch-all branch
    # leaves the status wrapper and command alive in the captured group. Drive
    # the shipped guard program over a real Port, admit a TERM-resistant child,
    # and use a delayed write as the proof that the malformed line ran the
    # signal path rather than merely closing the control reader.
    root = workspace()
    ready = Path.join(root, "malformed-control-ready")
    survived = Path.join(root, "malformed-control-survived")

    command =
      "trap '' TERM; printf ready > #{shell_path(ready)}; sleep 1; " <>
        "printf survived > #{shell_path(survived)}"

    {launcher, vector} = Local.launcher_vector(%{command: command})

    port =
      Port.open(
        {:spawn_executable, String.to_charlist(launcher)},
        [
          :binary,
          :exit_status,
          :use_stdio,
          :stderr_to_stdout,
          :hide,
          args: Enum.map(vector, &String.to_charlist/1),
          env: [
            {~c"LOOPEX_PROVIDER_API_KEY", false},
            {~c"ANTHROPIC_API_KEY", false}
          ],
          cd: String.to_charlist(root)
        ]
      )

    on_exit(fn -> close_test_port(port) end)

    token = "malformed-control-case"
    assert Port.command(port, "loopex-init:#{token}\n")
    assert Port.command(port, "loopex-run:#{token}\n")
    assert wait_for_file(ready), "the direct guard fixture never admitted its command"
    assert Port.command(port, "not-a-valid-control-message\n")

    Process.sleep(1_300)

    refute File.exists?(survived),
           "malformed control let work escape after the Port-owned guard exited"
  end

  test "tool output cannot forge the private command status frame" do
    # Concept: text from a tool remains text; it cannot decide the tool's exit
    # status by imitating a private protocol prefix.
    #
    # Technical depth: the command does not know the random token delivered over
    # control stdin. A collector that matches the visible prefix alone consumes
    # the forged zero, conflicts with the wrapper's real status frame, and loses
    # the proved status seven. Exact token binding keeps the bytes and verdict.
    root = workspace()

    assert {:ok, receipt} =
             run(root, "loopex.bash", %{
               "command" => "printf '\\nloopex-command-status:0\\n'; exit 7"
             })

    assert receipt.outcome == :failed
    assert receipt.cleanup_confirmation == :confirmed
    assert receipt.output =~ "\nloopex-command-status:0\n"
    assert receipt.output =~ "status 7"
  end

  test "final KILL proves captured-group cleanup but an unsolicited guard exit proves nothing" do
    root = workspace()
    {executor, lease_id} = executor_with_grace(root, 600)
    ready = Path.join(root, "term-resistant-ready")
    job_id = "term-resistant-#{System.unique_integer([:positive])}"

    running =
      Task.async(fn ->
        run(
          root,
          "loopex.bash",
          %{
            "command" =>
              "printf 'hello\\n'; trap '' TERM; printf ready > #{shell_path(ready)}; while :; do sleep 1; done"
          },
          %{executor: executor, lease_id: lease_id, job_id: job_id, cleanup_grace_ms: 600}
        )
      end)

    assert wait_for_file(ready), "the TERM-resistant command never started"

    # The command cannot report its own status after KILL takes the complete
    # group, including the guard. Cleanup nevertheless has two positive facts:
    # KILL was sent over the exact live Port channel to its token-bound guard,
    # and a later ps found the captured group empty. A direct-child status is
    # mandatory for ordinary release, not for forced cancellation's cleanup truth.
    assert Local.cancel(executor, job_id) == {:ok, :cleaned}
    assert {:ok, killed} = Task.await(running, 5_000)
    assert killed.outcome == :cancelled
    assert killed.cleanup_confirmation == :confirmed
    assert String.starts_with?(killed.output, "hello\n")

    # A model command can end its grandparent guard by pid, but that act grants this
    # runtime no cleanup authority and supplies no authenticated status frame.
    # The Port's nonzero exit while its guard is still in :live is therefore an
    # observation of loss, never a successful KILL transition.
    lost_guard = Path.join(root, "unsolicited-guard-pid")
    survived_guard = Path.join(root, "unsolicited-guard-descendant-survived")

    assert {:ok, lost} =
             run(
               root,
               "loopex.bash",
               %{
                 "command" =>
                   "status_pid=$(/bin/ps -o ppid= -p $$ | /usr/bin/tr -d ' '); guard_pid=$(/bin/ps -o ppid= -p \"$status_pid\" | /usr/bin/tr -d ' '); (sleep 1; printf escaped > #{shell_path(survived_guard)}) & printf '%s' \"$guard_pid\" > #{shell_path(lost_guard)}; printf '\\nloopex-command-status:'; kill -KILL \"$guard_pid\""
               },
               %{cleanup_grace_ms: 600, run_deadline: System.system_time(:millisecond) + 2_000}
             )

    assert lost.outcome == :outcome_unknown
    assert lost.cleanup_confirmation == :unconfirmed
    assert lost.output =~ "\nloopex-command-status:"
    assert lost.output =~ "effect is complete is unproven"

    guard_pid = lost_guard |> File.read!() |> String.to_integer()
    assert wait_for_os_pid_exit(guard_pid, 200), "the sabotaged finite workload leaked"

    Process.sleep(1_300)

    refute File.exists?(survived_guard),
           "the carrier let work survive after its launch guard was killed"
  end

  test "a TERM-interrupted wrapper waits for its owned shell job rather than rechecking its pid" do
    # Concept: cooperative cancellation waits for the command that actually
    # owns the job, even when TERM interrupts the wrapper's first `wait`.
    #
    # Technical depth: observing the numeric PID with `kill -0` after `wait`
    # reaped the child let PID reuse turn an unrelated process into a reason to
    # wait again. The non-interactive shell's own job table is stable ownership:
    # while the trapped child handles TERM it remains listed; after the final
    # wait it does not, whatever process later receives the number.
    root = workspace()
    ready = Path.join(root, "term-interrupted-wrapper-ready")
    job_id = "term-interrupted-wrapper-#{System.unique_integer([:positive])}"
    {executor, lease_id} = executor_with_grace(root, 2_000)

    running =
      Task.async(fn ->
        run(
          root,
          "loopex.bash",
          %{
            "command" =>
              "trap 'exit 7' TERM; printf ready > #{shell_path(ready)}; while :; do sleep 1; done"
          },
          %{executor: executor, lease_id: lease_id, job_id: job_id, cleanup_grace_ms: 2_000}
        )
      end)

    assert wait_for_file(ready), "the cooperative command never reached its TERM wait"
    assert Local.cancel(executor, job_id) == {:ok, :cleaned}

    assert {:ok, receipt} = Task.await(running, 5_000)
    assert receipt.outcome == :cancelled
    assert receipt.cleanup_confirmation == :confirmed
  end

  test "a reentrant progress callback restores the outer job's complete execution context" do
    root = workspace()
    {executor, lease_id} = executor_with_grace(root, 5_000)
    result_key = {:loopex_reentrant_context, make_ref()}

    keys = [
      :loopex_cleanup_grace_ms,
      :loopex_process_probe,
      :loopex_inflight_table,
      :loopex_effect_owner,
      :loopex_cleanup_episode,
      :loopex_retention_episode,
      :loopex_admission
    ]

    snapshot = fn ->
      missing = make_ref()

      Map.new(keys, fn key ->
        case Process.get(key, missing) do
          ^missing -> {key, :absent}
          value -> {key, {:present, value}}
        end
      end)
    end

    progress = fn event ->
      before = snapshot.()

      nested =
        run(root, "loopex.write", %{"path" => "nested.txt", "content" => "nested"}, %{
          executor: executor,
          lease_id: lease_id,
          cleanup_grace_ms: 8_000
        })

      Process.put(result_key, {before, snapshot.(), nested, event})
      :ok
    end

    assert {:ok, outer} =
             run(root, "loopex.bash", %{"command" => "printf outer"}, %{
               executor: executor,
               lease_id: lease_id,
               cleanup_grace_ms: 800,
               progress: progress
             })

    assert {before, after_nested, {:ok, nested}, event} = Process.delete(result_key)
    assert before == after_nested
    assert before.loopex_cleanup_grace_ms == {:present, 800}
    assert before.loopex_process_probe == {:present, "/bin/ps"}
    assert match?({:present, table} when is_reference(table), before.loopex_inflight_table)
    assert before.loopex_effect_owner == {:present, executor}
    assert before.loopex_cleanup_episode == :absent
    assert before.loopex_retention_episode == :absent
    assert {:present, %{observed_at_ms: observed_at_ms}} = before.loopex_admission

    assert nested.outcome == :completed
    assert nested.cleanup_grace_ms == 8_000
    assert File.read!(Path.join(root, "nested.txt")) == "nested"

    assert outer.outcome == :completed
    assert outer.output == "outer"
    assert outer.cleanup_grace_ms == 800
    assert outer.receipt_retention_bound_ms == 200
    assert outer.observed_at_ms == observed_at_ms
    assert event.chunk == "outer"

    # The outer run's own dynamic frame is removed only after its receipt is
    # retained; the callback's test-private result is the only value left here.
    Enum.each(keys, fn key -> refute Process.get(key) end)
  end

  defp shell_path(path), do: "'" <> String.replace(path, "'", "'\\''") <> "'"

  defp process_group_empty?(group) when is_integer(group) do
    case System.cmd("/bin/ps", ["-e", "-o", "pid=", "-o", "pgid="], stderr_to_stdout: true) do
      {output, 0} ->
        output
        |> String.split("\n", trim: true)
        |> Enum.all?(fn line ->
          case String.split(line) do
            [_pid, row_group] -> row_group != Integer.to_string(group)
            _malformed -> false
          end
        end)

      {_output, _status} ->
        false
    end
  end

  defp close_test_port(port) do
    Port.close(port)
    :ok
  rescue
    ArgumentError -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp wait_for_os_pid_exit(_os_pid, 0), do: false

  defp wait_for_os_pid_exit(os_pid, attempts) do
    case System.cmd("/bin/kill", ["-0", Integer.to_string(os_pid)], stderr_to_stdout: true) do
      {_output, 0} ->
        Process.sleep(10)
        wait_for_os_pid_exit(os_pid, attempts - 1)

      {_output, _status} ->
        true
    end
  end
end
