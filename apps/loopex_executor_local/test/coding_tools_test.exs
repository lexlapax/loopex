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

    {executor, lease_id, lease}
  end

  defp run(root, tool_id, arguments, overrides \\ %{}) do
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

    # Concept: the escaping symlink is the last component, not a directory on
    # the way to it.
    #
    # Technical depth: resolution used to notice a symlink, confirm its target
    # existed, and then resolve the link's own parent plus its basename -- which
    # is where the link sits, not where it points. Only the case above was
    # caught, because resolving the parent happened to follow a symlinked
    # directory. A link whose own name is the final component resolved to a
    # contained path and passed, so `read` returned the outside file and `write`
    # overwrote it, under a documented containment guarantee.
    File.ln_s!(Path.join(outside, "secret.txt"), Path.join(root, "leak"))

    assert {:ok, %{outcome: :failed, output: final_component}} =
             run(root, "loopex.read", %{"path" => "leak"})

    assert final_component =~ "outside the workspace"
    refute final_component =~ "not yours"

    assert {:ok, %{outcome: :failed}} =
             run(root, "loopex.write", %{"path" => "leak", "content" => "overwritten"})

    assert File.read!(Path.join(outside, "secret.txt")) == "not yours"

    assert {:ok, %{outcome: :failed}} =
             run(root, "loopex.edit", %{
               "path" => "leak",
               "old" => "not yours",
               "new" => "mine now"
             })

    assert File.read!(Path.join(outside, "secret.txt")) == "not yours"

    # A relative link out of the workspace is the same escape written differently.
    File.ln_s!(
      Path.join(["..", Path.basename(outside), "secret.txt"]),
      Path.join(root, "relative")
    )

    assert {:ok, %{outcome: :failed, output: relative}} =
             run(root, "loopex.read", %{"path" => "relative"})

    assert relative =~ "outside the workspace"

    # A link that points at itself is refused rather than followed forever.
    File.ln_s!(Path.join(root, "loop"), Path.join(root, "loop"))
    assert {:ok, %{outcome: :failed}} = run(root, "loopex.read", %{"path" => "loop"})
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

  test "a coding tool child receives a constructed credential free environment and its receipt reports what it received" do
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
    assert argv_named.output =~ "PATH="
    refute argv_named.output =~ "LOOPEX_PROVIDER_API_KEY"
    refute argv_named.output =~ "LOOPEX_SENTINEL_UNRELATED"

    # Concept: the receipt reports what the child received, not a constant.
    #
    # Technical depth: both fields were hardcoded, so the journal asserted an
    # absence it had not observed. A durable record that states a credential was
    # absent when it was present is worse than one that states nothing.
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
end
