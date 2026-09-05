defmodule Loopex.Executor.LocalAuthorityContractTest.ArtifactStore do
  @moduledoc false

  @behaviour Loopex.ArtifactStore

  alias LoopexProtocol.Canonical

  def start(mode), do: Agent.start_link(fn -> %{mode: mode, retained: [], uses: %{}} end)
  def retained(pid), do: Agent.get(pid, &Enum.reverse(&1.retained))

  @impl Loopex.ArtifactStore
  def put(pid, bytes, use) do
    mode = Agent.get(pid, & &1.mode)
    :ok = Agent.update(pid, &%{&1 | retained: [{bytes, use} | &1.retained]})

    case mode do
      :refuse ->
        {:error, :retention_refused}

      :malformed ->
        {:ok, %{locator: "malformed-only"}}

      :truthful ->
        digest = Canonical.digest_bytes(bytes)
        locator = "contract:" <> digest

        artifact_use = %{
          canonicalization_version: Canonical.version(),
          object_digest: digest,
          object_size: byte_size(bytes),
          object_locator: locator,
          media_type: use.media_type,
          role: use.role,
          metadata: use.metadata
        }

        use_digest = Canonical.digest(["artifact-use-v2", artifact_use])

        :ok =
          Agent.update(pid, &%{&1 | uses: Map.put(&1.uses, "use:" <> use_digest, artifact_use)})

        {:ok,
         %{
           digest: digest,
           size: byte_size(bytes),
           locator: locator,
           media_type: use.media_type,
           role: use.role,
           use_canonicalization_version: Canonical.version(),
           use_digest: use_digest,
           use_locator: "use:" <> use_digest
         }}
    end
  end

  @impl Loopex.ArtifactStore
  def fetch(_pid, _reference), do: {:error, :not_used}

  @impl Loopex.ArtifactStore
  def stat(_pid, _reference), do: {:error, :not_used}

  # ADR 0015 closes the callback set with describe/2: Core resolves the use it
  # just retained before it returns a reference, so a double that cannot answer
  # never yields one. Only the truthful mode retains a describable use.
  @impl Loopex.ArtifactStore
  def describe(pid, use_locator) do
    case Agent.get(pid, &Map.fetch(&1.uses, use_locator)) do
      {:ok, artifact_use} -> {:ok, artifact_use}
      :error -> {:error, :unknown_artifact_use}
    end
  end
end

defmodule Loopex.Executor.LocalAuthorityContractTest do
  @moduledoc false

  use ExUnit.Case, async: false

  alias Loopex.Executor
  alias Loopex.Executor.Local
  alias Loopex.Executor.Local.Ledger
  alias Loopex.Executor.Local.WorkspaceLease
  alias Loopex.Executor.LocalAuthorityContractTest.ArtifactStore

  @identity "local-authority-contract"
  @fence 91
  # Every job in this file writes its receipt under the retention share ADR 0016
  # derives from the committed cleanup period, and that write is `File.open/2`,
  # `IO.binwrite/2`, two `:file.sync/1` calls and a rename. A literal period of
  # 41 gave those five syscalls 11 ms. On an idle box they take 1 ms at the
  # median and 6 ms at the worst and every case here passed; on a box whose
  # cores are all busy they take 10 ms at the median and 48 ms at the worst, so
  # any case that settles a receipt failed with `{:receipt_not_retained,
  # :receipt_retention_abandoned_at_run_deadline}` wherever the scheduler
  # happened to be slow. Nothing about the executor was in doubt in those runs:
  # it abandoned the write at exactly the bound the formula gave it.
  #
  # The period is therefore taken from that one formula rather than written
  # down. It is the smallest committed value whose own receipt-retention share
  # covers a real fsynced ledger write, so the allowance these cases depend on
  # is named as a duration a write needs and cannot be widened by quietly
  # growing a number. It stays distinct from the 5_000 startup default, so the
  # cases asserting that a receipt reports the committed period rather than the
  # composed one still discriminate, and it stays indivisible by four, so a
  # second derivation by `div/2` in place of ADR 0016's ceiling would still
  # disagree with it.
  @ledger_write_allowance_ms 500
  @grace Enum.find(1..(4 * @ledger_write_allowance_ms), fn candidate ->
           {:ok, bounds} = Executor.cancellation_bounds(candidate)
           bounds.receipt_retention_ms >= @ledger_write_allowance_ms
         end)
  @max_uint64 18_446_744_073_709_551_615

  test "a prepared Local root binds one exact canonical generation before returning" do
    root = temporary_root("root-binding")
    on_exit(fn -> File.rm_rf(root) end)

    assert {:ok, prepared} =
             invoke(Local, :prepare_placement, [root, @identity, @grace])

    assert {:ok, same} = invoke(Local, :prepare_placement, [root, @identity, @grace])
    assert same == prepared

    generation_path = generation_path!(root)
    generation = generation_record!(root)
    assert generation.ledger_kind == "local_executor_generation_v1"
    assert generation["executor_identity"] == @identity
    assert is_integer(generation["executor_epoch"]) and generation["executor_epoch"] > 0

    assert Map.keys(generation) |> Enum.sort() ==
             [
               :ledger_kind,
               "executor_epoch",
               "executor_identity",
               "generation_id",
               "root_binding"
             ]
             |> Enum.sort()

    assert generation["generation_id"] ==
             generation["executor_epoch"]
             |> Integer.to_string(16)
             |> String.pad_leading(64, "0")

    assert generation["root_binding"] == expected_root_binding(root)

    assert File.read!(generation_path) == :erlang.term_to_binary(generation, [:deterministic])
    assert byte_size(File.read!(generation_path)) <= 2_048
  end

  test "same-path directory replacement and an isolated generation copy both refuse" do
    root = temporary_root("root-replacement")
    retired = root <> "-retired"
    on_exit(fn -> Enum.each([root, retired], &File.rm_rf/1) end)

    assert {:ok, _prepared} = invoke(Local, :prepare_placement, [root, @identity, @grace])
    generation_path = generation_path!(root)
    relative_generation = Path.relative_to(generation_path, root)

    File.rename!(root, retired)
    File.mkdir_p!(root)
    replacement_generation = Path.join(root, relative_generation)
    File.mkdir_p!(Path.dirname(replacement_generation))
    File.cp!(Path.join(retired, relative_generation), replacement_generation)

    assert_refused(invoke(Local, :prepare_placement, [root, @identity, @grace]))

    source_root = temporary_root("generation-copy-source")
    copied_root = temporary_root("generation-copy-target")
    on_exit(fn -> Enum.each([source_root, copied_root], &File.rm_rf/1) end)

    assert {:ok, _prepared} =
             invoke(Local, :prepare_placement, [source_root, @identity, @grace])

    copied_generation =
      source_root
      |> generation_path!()
      |> Path.relative_to(source_root)
      |> then(&Path.join(copied_root, &1))

    File.mkdir_p!(Path.dirname(copied_generation))
    File.cp!(generation_path!(source_root), copied_generation)

    assert_refused(invoke(Local, :prepare_placement, [copied_root, @identity, @grace]))
  end

  test "generation validation rejects extra keys broken relations symlinks and oversized bytes" do
    mutations = [
      {:extra_key, fn record -> Map.put(record, "unexpected", true) end},
      {:generation_relation,
       fn record -> Map.put(record, "generation_id", String.duplicate("0", 64)) end},
      {:root_relation,
       fn record -> Map.put(record, "root_binding", String.duplicate("f", 64)) end}
    ]

    for {label, mutate} <- mutations do
      root = temporary_root("generation-#{label}")
      on_exit(fn -> File.rm_rf(root) end)
      assert {:ok, _prepared} = invoke(Local, :prepare_placement, [root, @identity, @grace])

      path = generation_path!(root)
      record = generation_record!(root)
      File.write!(path, :erlang.term_to_binary(mutate.(record), [:deterministic]))

      assert_refused(invoke(Local, :prepare_placement, [root, @identity, @grace]))
    end

    oversized_root = temporary_root("generation-oversized")
    on_exit(fn -> File.rm_rf(oversized_root) end)

    assert {:ok, _prepared} =
             invoke(Local, :prepare_placement, [oversized_root, @identity, @grace])

    File.write!(generation_path!(oversized_root), :binary.copy(<<0>>, 2_049))

    assert_refused(invoke(Local, :prepare_placement, [oversized_root, @identity, @grace]))

    symlink_root = temporary_root("generation-symlink")
    target_root = temporary_root("generation-target")
    on_exit(fn -> Enum.each([symlink_root, target_root], &File.rm_rf/1) end)
    assert {:ok, _prepared} = invoke(Local, :prepare_placement, [symlink_root, @identity, @grace])
    path = generation_path!(symlink_root)
    bytes = File.read!(path)
    File.mkdir_p!(target_root)
    target = Path.join(target_root, "generation")
    File.write!(target, bytes)
    File.rm!(path)
    File.ln_s!(target, path)

    assert_refused(invoke(Local, :prepare_placement, [symlink_root, @identity, @grace]))
  end

  test "placement publication syncs the generation file and its parent before returning" do
    root = temporary_root("generation-sync")
    on_exit(fn -> File.rm_rf(root) end)

    assert :erlang.trace_pattern({:file, :sync, 1}, true, [:local]) == 1

    assert :erlang.trace_pattern(
             {:file, :open, 2},
             [{:_, [], [{:return_trace}]}],
             [:local]
           ) == 1

    on_exit(fn ->
      _ = :erlang.trace_pattern({:file, :sync, 1}, false, [:local])
      _ = :erlang.trace_pattern({:file, :open, 2}, false, [:local])
    end)

    parent = self()

    {preparer, monitor} =
      spawn_monitor(fn ->
        :erlang.trace(self(), true, [:call, :set_on_spawn, {:tracer, parent}])

        send(
          parent,
          {:prepared_with_sync, invoke(Local, :prepare_placement, [root, @identity, @grace])}
        )
      end)

    assert_receive {:prepared_with_sync, preparation}, 5_000
    assert_receive {:DOWN, ^monitor, :process, ^preparer, :normal}, 1_000
    assert {:ok, _prepared} = preparation

    synced_paths = collect_file_trace() |> synced_paths()
    generation_path = generation_path!(root)
    assert generation_path in synced_paths, "generation bytes were not synced"

    assert Path.dirname(generation_path) in synced_paths,
           "the generation parent was not synced after publication"

    # The root is also synced into its own parent when it is created, so the
    # first sync of this directory is no longer the publication's. What the
    # ordering claim is about is unchanged: a sync of the parent that follows the
    # generation bytes, so the entry naming them is never durable first.
    published = Enum.find_index(synced_paths, &(&1 == generation_path))

    assert Enum.find_index(
             Enum.drop(synced_paths, published + 1),
             &(&1 == Path.dirname(generation_path))
           ),
           "the generation parent was synced before the generation bytes and not after them"

    assert generation_record!(root)["executor_identity"] == @identity
  end

  test "two Local instances sharing one root issue one effect permit and conflict on changed bytes" do
    fixture = prepared_fixture("one-effect")

    {:ok, first} = start_local(fixture)
    {:ok, second} = start_local(fixture)

    on_exit(fn ->
      stop(first)
      stop(second)
    end)

    job = job(fixture, "shared-job", %{"command" => "printf 'one\\n' >> effect.log"})
    grant = grant(job)
    parent = self()

    workers =
      for local <- [first, second] do
        spawn_monitor(fn ->
          send(parent, {:execute_result, self(), Local.execute(local, job, grant, [], nil)})
        end)
      end

    results =
      for {pid, monitor} <- workers do
        assert_receive {:execute_result, ^pid, result}, 10_000
        assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 1_000
        result
      end

    assert Enum.all?(results, &match?({:ok, %{outcome: :completed}}, &1))
    assert File.read!(Path.join(fixture.workspace, "effect.log")) == "one\n"

    conflicting = job(fixture, "shared-job", %{"command" => "printf two\\n >> effect.log"})

    assert {:error, :job_id_conflict} =
             Local.execute(second, conflicting, grant(conflicting), [], nil)

    assert File.read!(Path.join(fixture.workspace, "effect.log")) == "one\n"
  end

  test "wall truth and the immutable monotonic action deadline fence effects independently" do
    wall = System.system_time(:millisecond)

    # `clock_provider` is a reversible test-only edge seam: it substitutes the
    # one paired sample source ADR 0016 names and enters no job, ledger, receipt,
    # event, or public API. The normal case below prevents an implementation
    # from making every injected clock refuse; the two expiry cases prevent it
    # from accepting the option while ignoring the supplied samples.

    cases = [
      {"monotonic", [{wall, 1_000}, {wall - 10_000, 2_000}], :refused},
      {"wall", [{wall, 1_000}, {wall + 2_000, 1_001}], :refused},
      {"narrow-normal", [{wall, 1_000}, {wall + 90, 1_090}], :completed},
      {"normal", [{wall, 1_000}, {wall + 1, 1_001}], :completed}
    ]

    for {name, samples, expectation} <- cases do
      fixture = prepared_fixture("clock-#{name}")
      clock = clock_provider(samples)
      {:ok, local} = start_local(fixture, clock_provider: clock)
      on_exit(fn -> stop(local) end)

      marker = "#{name}.txt"

      request =
        job(fixture, "clock-#{name}", %{"path" => marker, "content" => "forbidden"}, wall + 100)

      result = Local.execute(local, request, grant(request), [], nil)

      case expectation do
        :refused ->
          assert {:error, {:refused_before_effect, :effective_deadline_reached}} = result
          refute File.exists?(Path.join(fixture.workspace, marker))

        :completed ->
          assert {:ok, %{outcome: :completed}} = result
          assert File.read!(Path.join(fixture.workspace, marker)) == "forbidden"
      end
    end

    overflow = prepared_fixture("clock-overflow")
    overflow_clock = clock_provider([{wall, @max_uint64 - 5}])
    {:ok, overflow_local} = start_local(overflow, clock_provider: overflow_clock)
    on_exit(fn -> stop(overflow_local) end)

    overflow_job =
      job(overflow, "clock-overflow", %{"path" => "overflow.txt", "content" => "forbidden"})

    assert {:error, {:refused_before_effect, overflow_reason}} =
             Local.execute(overflow_local, overflow_job, grant(overflow_job), [], nil)

    assert overflow_reason in [:effective_deadline_reached, :effect_start_authority_unavailable]

    refute File.exists?(Path.join(overflow.workspace, "overflow.txt"))

    sliced = prepared_fixture("clock-sliced")
    sliced_clock = clock_provider([{1, 1}, {2, 2}])
    {:ok, sliced_local} = start_local(sliced, clock_provider: sliced_clock)
    on_exit(fn -> stop(sliced_local) end)

    sliced_job =
      job(
        sliced,
        "clock-sliced",
        %{"path" => "sliced.txt", "content" => "ok"},
        @max_uint64
      )

    assert {:ok, %{outcome: :completed}} =
             Local.execute(sliced_local, sliced_job, grant(sliced_job), [], nil)

    assert File.read!(Path.join(sliced.workspace, "sliced.txt")) == "ok"
  end

  test "an owned process cannot start after its admitted action deadline expires" do
    # Concept: admission authorizes one future transition; it does not authorize
    # a process to start after that transition's immutable deadline has passed.
    #
    # Technical depth: the first two paired samples admit the job. The third is
    # consumed by the launch worker immediately before it sends the token-bound
    # run permit to an already-open waiting guard and crosses both fences. Opening
    # the guard is not the effect: it cannot create the command before that
    # permit. The missing process-start notification is the decisive observation
    # that no model command was created.
    fixture = prepared_fixture("process-expired-before-port")
    wall = System.system_time(:millisecond)

    clock =
      clock_provider([
        {wall, 1_000},
        {wall + 1, 1_001},
        {wall + 200, 1_200}
      ])

    {:ok, local} = start_local(fixture, clock_provider: clock)
    on_exit(fn -> stop(local) end)

    target = Path.join(fixture.workspace, "must-not-start.txt")

    request =
      job(
        fixture,
        "process-expired-before-port",
        %{"command" => "printf forbidden > #{shell_path(target)}"},
        wall + 100
      )

    assert {:ok, receipt} =
             Local.execute(local, request, grant(request), [notify: self()], nil)

    assert receipt.outcome == :cancelled
    assert receipt.cleanup_confirmation == :confirmed

    refute_receive {:executor_process_started, "process-expired-before-port", _tool,
                    _environment},
                   100

    refute File.exists?(target)

    source = File.read!(Path.expand("../lib/executor.ex", __DIR__))

    [launch_boundary] =
      Regex.run(
        ~r/defp run_owned_process_after_fence\((.*?)\n  end\n\n  # Concept: an in-flight/s,
        source,
        capture: :all_but_first
      )

    {ready_offset, _size} =
      :binary.match(launch_boundary, "await_launch_guard_ready(")

    {fence_offset, _size} =
      :binary.match(launch_boundary, "remaining = fence_remaining(deadline)")

    {run_offset, _size} =
      :binary.match(
        launch_boundary,
        ~S|safe_port_command(port, "#{@guard_run}:#{token}\n")|
      )

    {notification_offset, _size} =
      :binary.match(launch_boundary, "{:executor_process_started,")

    assert ready_offset < fence_offset,
           "the final fence ran before the waiting guard established its identity"

    assert fence_offset < run_offset,
           "the final fence moved after the token-bound command-start permit"

    assert run_offset < notification_offset,
           "the process-start notification moved before the command-start permit"

    assert launch_boundary =~ "not Process.alive?(lease_pid)"
    assert launch_boundary =~ "not effect_owner_alive?(owner)"
    assert launch_boundary =~ "remaining <= 0"

    assert launch_boundary =~ "close_waiting_guard(port, token)"

    assert launch_boundary =~
             ~S|unless safe_port_command(port, "#{@guard_run}:#{token}\n")|,
           "the command can start without the authenticated run permit"
  end

  test "an owned process cannot start after its workspace lease dies at the launch boundary" do
    fixture = prepared_fixture("process-lease-lost-before-port")
    Process.unlink(fixture.lease)
    wall = System.system_time(:millisecond)

    clock =
      clock_provider_with_action(
        [{wall, 1_000}, {wall + 1, 1_001}, {wall + 2, 1_002}],
        3,
        fn -> stop(fixture.lease) end
      )

    {:ok, local} = start_local(fixture, clock_provider: clock)
    on_exit(fn -> stop(local) end)
    target = Path.join(fixture.workspace, "must-not-start-after-lease.txt")

    request =
      job(
        fixture,
        "process-lease-lost-before-port",
        %{"command" => "printf forbidden > #{shell_path(target)}"},
        wall + 10_000
      )

    assert {:ok, receipt} =
             Local.execute(local, request, grant(request), [notify: self()], nil)

    assert receipt.outcome == :outcome_unknown
    assert receipt.cleanup_confirmation == :confirmed

    refute_receive {:executor_process_started, "process-lease-lost-before-port", _tool,
                    _environment},
                   100

    refute File.exists?(target)
  end

  test "an owned process cannot start after its Local owner dies at the launch boundary" do
    fixture = prepared_fixture("process-owner-lost-before-port")
    wall = System.system_time(:millisecond)
    {:ok, owner_cell} = Agent.start_link(fn -> nil end)
    on_exit(fn -> stop(owner_cell) end)

    clock =
      clock_provider_with_action(
        [{wall, 1_000}, {wall + 1, 1_001}, {wall + 2, 1_002}],
        3,
        fn ->
          owner = Agent.get(owner_cell, & &1)
          if is_pid(owner), do: Process.exit(owner, :kill)
        end
      )

    {:ok, local} = start_local(fixture, clock_provider: clock)
    Process.unlink(local)
    Agent.update(owner_cell, fn _old -> local end)
    on_exit(fn -> stop(local) end)
    target = Path.join(fixture.workspace, "must-not-start-after-owner.txt")

    request =
      job(
        fixture,
        "process-owner-lost-before-port",
        %{"command" => "printf forbidden > #{shell_path(target)}"},
        wall + 10_000
      )

    assert {:ok, receipt} =
             Local.execute(local, request, grant(request), [notify: self()], nil)

    assert receipt.outcome == :outcome_unknown
    assert receipt.cleanup_confirmation == :confirmed

    refute_receive {:executor_process_started, "process-owner-lost-before-port", _tool,
                    _environment},
                   100

    refute File.exists?(target)
  end

  test "a later effect transition reuses the handoff deadline after wall time moves backward" do
    fixture = prepared_fixture("clock-no-refresh")
    wall = System.system_time(:millisecond)
    clock = expiring_monotonic_clock(wall)
    {:ok, local} = start_local(fixture, clock_provider: clock)
    on_exit(fn -> stop(local) end)

    request =
      job(
        fixture,
        "clock-no-refresh",
        %{
          "relative_path" => "clock-no-refresh.txt",
          "content" => "forbidden",
          "delay_ms" => 175
        },
        wall + 100
      )

    result = Local.execute(local, request, grant(request), [], nil)

    # Concept: only an effect that actually started can show that a later
    # transition reused the deadline the handoff fixed.
    #
    # Technical depth: `refute match?({:ok, %{outcome: :completed}}, result)` is
    # equally satisfied by `{:error, {:refused_before_effect,
    # :effective_deadline_reached}}`, which is what a setup slower than this
    # job's 100 ms window produces -- the job never starts, the second clock
    # reading is never taken, and the case says nothing about refreshing. The
    # shape that carries the claim is the post-start stop: an outcome that is
    # unproven or failed, on a receipt whose note names a deadline that passed
    # while this tool was already running.
    refute match?({:error, {:refused_before_effect, _reason}}, result),
           "the job never started, so nothing observed the later reading: #{inspect(result)}"

    assert {:ok, %{outcome: outcome, output: output}} = result

    refute outcome == :completed,
           "a job stopped at its deadline was reported completed: #{inspect(result)}"

    assert output =~ "run deadline passed" and output =~ "terminated",
           "the receipt does not name the post-start deadline termination: #{output}"

    refute File.exists?(Path.join(fixture.workspace, "clock-no-refresh.txt"))
  end

  test "a Local receipt reports the committed cleanup facts and fits the Store item envelope" do
    fixture = prepared_fixture("receipt")
    {:ok, local} = start_local(fixture)
    on_exit(fn -> stop(local) end)

    request = job(fixture, "receipt-job", %{"path" => "receipt.txt", "content" => "ok"})
    assert {:ok, receipt} = Local.execute(local, request, grant(request), [], nil)

    assert receipt.cleanup_grace_ms == @grace
    assert receipt.cleanup_confirmation == :confirmed
    assert invoke(Local, :default_cleanup_grace_ms, [local]) == @grace
    assert Local.cleanup_grace_ms(local) == @grace

    assert {:ok, bounds} = invoke(Executor, :cancellation_bounds, [@grace])
    assert receipt.receipt_retention_bound_ms == bounds.receipt_retention_ms

    # The Store admits plain boundary data only, so the envelope check runs on
    # the durable projection the runtime retains: the receipt's atom-valued
    # members rendered as the strings its record carries.
    durable =
      receipt
      |> Map.put(:kind, "executor_receipt")
      |> Map.new(fn
        {key, value} when is_atom(value) and not is_boolean(value) and not is_nil(value) ->
          {key, Atom.to_string(value)}

        member ->
          member
      end)

    assert Loopex.Store.validate_private_record(durable) == :ok
  end

  test "missing malformed and contradictory cleanup facts make a retained receipt unavailable" do
    mutations = [
      missing_confirmation: &Map.delete(&1, :cleanup_confirmation),
      invalid_confirmation: &Map.put(&1, :cleanup_confirmation, :maybe),
      contradictory_confirmation:
        &(&1
          |> Map.put(:outcome, :completed)
          |> Map.put(:cleanup_confirmation, :unconfirmed)),
      invalid_retention: &Map.put(&1, :receipt_retention_bound_ms, 0)
    ]

    for {label, mutate} <- mutations do
      fixture = prepared_fixture("receipt-#{label}")
      {:ok, local} = start_local(fixture)

      request =
        job(fixture, "receipt-#{label}", %{
          "path" => "receipt-#{label}.txt",
          "content" => "ok"
        })

      assert {:ok, receipt} = Local.execute(local, request, grant(request), [], nil)
      path = receipt_path!(fixture.ledger, request.job_id)
      stop(local)
      File.write!(path, :erlang.term_to_binary(mutate.(receipt), [:deterministic]))

      case start_local(fixture) do
        {:error, _reason} ->
          :ok

        {:ok, restarted} ->
          on_exit(fn -> stop(restarted) end)
          assert {:error, _reason} = Local.receipt(restarted, request.job_id)
      end
    end
  end

  test "receipt fitting spills complete bytes and fail-closed artifact answers claim no suffix" do
    full = :binary.copy("receipt-fit-line\n", 512)

    for mode <- [:truthful, :refuse, :malformed] do
      fixture = prepared_fixture("receipt-fit-#{mode}")
      File.write!(Path.join(fixture.workspace, "large.txt"), full)
      {:ok, artifact_store} = ArtifactStore.start(mode)
      on_exit(fn -> stop(artifact_store) end)

      {:ok, local} =
        start_local(fixture,
          artifacts: %{module: ArtifactStore, handle: artifact_store}
        )

      on_exit(fn -> stop(local) end)

      request =
        job(
          fixture,
          "receipt-fit-#{mode}",
          %{"path" => "large.txt"},
          System.system_time(:millisecond) + 60_000,
          %{
            tool_id: "loopex.read",
            effect_class: "read_only",
            required_capabilities: ["read_only"],
            resource_budgets: %{"max_output_bytes" => 128}
          }
        )

      assert {:ok, receipt} = Local.execute(local, request, grant(request), [], nil)
      assert [{^full, _normalized_use}] = ArtifactStore.retained(artifact_store)
      assert byte_size(:erlang.term_to_binary(receipt, [:deterministic])) <= 65_536
      assert byte_size(receipt.output) < byte_size(full)

      case mode do
        :truthful ->
          assert [reference] = receipt.artifacts
          assert Loopex.ArtifactStore.valid_reference?(reference)

        unavailable when unavailable in [:refuse, :malformed] ->
          assert receipt.artifacts == []

          assert receipt.output =~ "nothing beyond" or
                   receipt.output =~ "not retained" or
                   receipt.output =~ "retention unavailable"
      end
    end
  end

  test "complete root snapshots enforce both entry capacity and the byte ceiling" do
    {capacity_fixture, capacity_directory} = abandoned_open_directory("snapshot-capacity")
    replace_open_index(capacity_fixture, capacity_directory, 1_024, 32)
    assert_reconciliation_snapshot(capacity_fixture)

    append_open_record(capacity_fixture, capacity_directory, 1_025, 32)
    assert_ledger_unavailable(capacity_fixture, "capacity")

    {size_fixture, size_directory} = abandoned_open_directory("snapshot-bytes")
    replace_open_index(size_fixture, size_directory, 900, 4_800)

    raw_bytes =
      size_directory
      |> File.ls!()
      |> Enum.map(&File.stat!(Path.join(size_directory, &1)).size)
      |> Enum.sum()

    assert raw_bytes > 4_194_304
    assert_ledger_unavailable(size_fixture, "snapshot")
  end

  test "observed_at is sampled at effect admission and not resampled after delayed work" do
    fixture = prepared_fixture("observed-at")
    wall = System.system_time(:millisecond)
    boundary = Path.join(fixture.workspace, "observed-at.txt")
    refute File.exists?(boundary)
    {clock, phase, samples} = admission_phase_clock(wall, boundary)
    {:ok, local} = start_local(fixture, clock_provider: clock)
    on_exit(fn -> stop(local) end)

    request =
      job(fixture, "observed-at-job", %{
        "relative_path" => "observed-at.txt",
        "content" => "ok",
        "delay_ms" => 150
      })

    # Hold the executor between request handoff and admission. Prestart
    # validation resolves the workspace lease with a call; while the lease is
    # suspended that call cannot be answered, so the executor has received the
    # request but cannot yet admit the effect. The lease call carries a five
    # second timeout, so this window must close well inside it, and a slow
    # machine fails loudly on a lease refusal rather than passing.
    :erlang.suspend_process(fixture.lease)
    execution = Task.async(fn -> Local.execute(local, request, grant(request), [], nil) end)

    assert await_queued_call(fixture.lease),
           "the executor never asked the workspace lease, so admission was never held"

    Agent.update(phase, fn _handoff -> :admitted end)
    :erlang.resume_process(fixture.lease)

    assert {:ok, receipt} = Task.await(execution, 10_000)
    assert receipt.outcome == :completed

    assert File.exists?(boundary),
           "the delayed effect never wrote its output, so no completion boundary was crossed"

    assert Agent.get(samples, & &1) > 0, "the supplied clock was never consulted"

    refute receipt.observed_at_ms == wall,
           "observed_at was sampled at request handoff, before the effect was admitted"

    refute receipt.observed_at_ms == wall + 20_000,
           "observed_at was resampled after the delayed effect wrote its output"

    assert receipt.observed_at_ms == wall + 10_000,
           "observed_at must be the one admission sample and reports #{receipt.observed_at_ms}"
  end

  test "effect admission retains exact marker and open authority and observes file before parent sync" do
    fixture = prepared_fixture("ledger-open")
    {:ok, local} = start_local(fixture)
    on_exit(fn -> stop(local) end)

    request =
      job(fixture, "ledger-open-job", %{
        "relative_path" => "ledger-open.txt",
        "content" => "forbidden",
        "delay_ms" => 5_000
      })

    assert :erlang.trace_pattern({:file, :sync, 1}, true, [:local]) == 1

    assert :erlang.trace_pattern(
             {:file, :open, 2},
             [{:_, [], [{:return_trace}]}],
             [:local]
           ) == 1

    on_exit(fn ->
      _ = :erlang.trace_pattern({:file, :sync, 1}, false, [:local])
      _ = :erlang.trace_pattern({:file, :open, 2}, false, [:local])
    end)

    parent = self()

    task =
      Task.async(fn ->
        receive do
          :begin_admission ->
            Local.execute(local, request, grant(request), [notify: parent], nil)
        end
      end)

    :erlang.trace(local, true, [:call, {:tracer, parent}])
    :erlang.trace(task.pid, true, [:call, :set_on_spawn, {:tracer, parent}])
    send(task.pid, :begin_admission)

    assert_receive {:executor_process_started, "ledger-open-job", _tool, _environment}, 5_000

    records = ledger_records(fixture.ledger)
    assert [{marker_path, marker}] = records_by_kind(records, "local_effect_admission_v1")
    assert [{open_path, open}] = records_by_kind(records, "local_open_effect_v1")

    assert Map.keys(marker) |> Enum.sort() ==
             [
               :ledger_kind,
               "admission_nonce",
               "attempt",
               "canonical_request_digest",
               "cleanup_grace_ms",
               "job_id",
               "operation_id"
             ]
             |> Enum.sort()

    assert marker["job_id"] == request.job_id
    assert marker["canonical_request_digest"] == request.canonical_request_digest
    assert marker["operation_id"] == request.operation_id
    assert marker["attempt"] == request.attempt
    assert marker["cleanup_grace_ms"] == @grace
    assert marker["admission_nonce"] =~ ~r/^[0-9a-f]{64}$/

    assert open == %{
             :ledger_kind => "local_open_effect_v1",
             "job_id" => request.job_id,
             "canonical_request_digest" => request.canonical_request_digest,
             "executor_identity" => @identity,
             "origin_executor_epoch" => fixture.epoch,
             "cleanup_grace_ms" => @grace
           }

    assert Path.basename(open_path) == sha256(request.job_id)

    synced = collect_file_trace() |> synced_paths()

    for path <- [open_path, marker_path] do
      assert path in synced, "#{path} was not synced before the effect permit"

      assert Path.dirname(path) in synced,
             "#{path}'s parent was not synced before the effect permit"

      assert Enum.find_index(synced, &(&1 == path)) <
               Enum.find_index(synced, &(&1 == Path.dirname(path)))
    end

    assert Local.cancel(local, request.job_id) in [{:ok, :cleaned}, {:ok, :unconfirmed}]
    assert {:ok, receipt} = Task.await(task, 10_000)
    assert receipt.outcome != :completed
    refute File.exists?(Path.join(fixture.workspace, "ledger-open.txt"))
  end

  test "deadline refusal precedes admission while post-admission cancellation cannot rewrite no-effect truth" do
    fixture = prepared_fixture("admission-races")
    {:ok, local} = start_local(fixture)
    on_exit(fn -> stop(local) end)

    expired =
      job(
        fixture,
        "expired-before-admission",
        %{"path" => "expired.txt", "content" => "forbidden"},
        System.system_time(:millisecond) - 1
      )

    assert {:error, {:refused_before_effect, :effective_deadline_reached}} =
             Local.execute(local, expired, grant(expired), [], nil)

    refute File.exists?(Path.join(fixture.workspace, "expired.txt"))

    assert [{_refusal_path, refusal}] =
             fixture.ledger
             |> ledger_records()
             |> records_by_kind("local_pre_effect_refusal_v1")

    assert refusal == %{
             :ledger_kind => "local_pre_effect_refusal_v1",
             "job_id" => expired.job_id,
             "canonical_request_digest" => expired.canonical_request_digest,
             "operation_id" => expired.operation_id,
             "attempt" => expired.attempt,
             "reason" => %{"code" => "effective_deadline_reached", "field" => nil}
           }

    assert records_by_kind(ledger_records(fixture.ledger), "local_effect_admission_v1") == []
    assert records_by_kind(ledger_records(fixture.ledger), "local_open_effect_v1") == []

    admitted =
      job(fixture, "cancel-after-admission", %{
        "relative_path" => "cancel-after-admission.txt",
        "content" => "forbidden",
        "delay_ms" => 5_000
      })

    parent = self()

    task =
      Task.async(fn -> Local.execute(local, admitted, grant(admitted), [notify: parent], nil) end)

    assert_receive {:executor_process_started, "cancel-after-admission", _tool, _environment},
                   5_000

    assert Local.cancel(local, admitted.job_id) in [{:ok, :cleaned}, {:ok, :unconfirmed}]
    assert {:ok, receipt} = Task.await(task, 10_000)
    assert receipt.outcome != :completed
    refute File.exists?(Path.join(fixture.workspace, "cancel-after-admission.txt"))

    refute Enum.any?(
             records_by_kind(ledger_records(fixture.ledger), "local_pre_effect_refusal_v1"),
             fn
               {_path, record} -> record["job_id"] == admitted.job_id
             end
           )
  end

  test "Local owner loss terminates launch-owned authority and quarantines unresolved root truth" do
    fixture = prepared_fixture("owner-loss")

    {:ok, local} =
      start_local(fixture,
        process_probe: "/definitely/missing/loopex-process-probe"
      )

    ready = Path.join(fixture.workspace, "ready")
    escaped = Path.join(fixture.workspace, "escaped")

    # The shell traps TERM, so the group survives cooperative termination and
    # goes only to this executor's forced kill -- and every step of that
    # sequence is bounded by the committed cleanup period, not by a constant.
    # A descendant told to write a third of a second from now therefore proves
    # the kill landed only while that period happens to be shorter than a third
    # of a second, which is a fact about the fixture rather than about the
    # termination. The natural write is placed a whole further period after the
    # budget can expire and the observation a further one again, so a longer
    # committed period moves all three together instead of turning a literal
    # delay into a verdict.
    escape_delay_ms = 2 * @grace
    observation_ms = escape_delay_ms + @grace

    request =
      job(fixture, "owner-loss-job", %{
        "command" =>
          "trap '' TERM; printf ready > #{shell_path(ready)}; " <>
            "(sleep #{escape_delay_ms / 1_000}; printf escaped > #{shell_path(escaped)}) & wait"
      })

    parent = self()

    worker =
      spawn(fn ->
        send(parent, {:owner_loss_result, Local.execute(local, request, grant(request), [], nil)})
      end)

    assert wait_for_file(ready)

    Process.unlink(local)
    Process.exit(local, :kill)
    refute Process.alive?(local)

    Process.sleep(observation_ms)

    refute File.exists?(escaped),
           "an operating-system descendant wrote after its natural delay and owner death"

    refute_receive {:owner_loss_result, {:ok, %{outcome: :completed}}}, 100
    Process.exit(worker, :kill)

    {:ok, restarted} = start_local(fixture)
    on_exit(fn -> stop(restarted) end)

    next = job(fixture, "after-owner-loss", %{"path" => "after.txt", "content" => "forbidden"})
    assert {:error, reason} = Local.execute(restarted, next, grant(next), [], nil)
    assert inspect(reason) =~ "reconciliation"
    refute File.exists?(Path.join(fixture.workspace, "after.txt"))
  end

  test "restart refuses a malformed open-index tail without downgrading existing open authority" do
    fixture = prepared_fixture("complete-open-index")
    {:ok, local} = start_local(fixture)
    Process.unlink(local)

    request =
      job(fixture, "open-index-authority", %{
        "relative_path" => "must-not-land.txt",
        "content" => "forbidden",
        "delay_ms" => 5_000
      })

    parent = self()

    task =
      Task.async(fn -> Local.execute(local, request, grant(request), [notify: parent], nil) end)

    on_exit(fn ->
      if Process.alive?(task.pid), do: Task.shutdown(task, :brutal_kill)
      stop(local)
    end)

    assert_receive {:executor_process_started, "open-index-authority", _tool, _environment},
                   5_000

    assert [{open_path, _open}] =
             fixture.ledger
             |> ledger_records()
             |> records_by_kind("local_open_effect_v1")

    Process.exit(local, :kill)
    refute Process.alive?(local)

    malformed_tail = Path.join(Path.dirname(open_path), "zz-malformed-open-entry")
    File.write!(malformed_tail, <<131, 116, 0, 0, 0, 0>>)

    start_answer = start_local(fixture)

    case start_answer do
      {:error, reason} ->
        rendered = inspect(reason)
        assert rendered =~ "ledger" and rendered =~ "unavailable"
        refute rendered =~ "reconciliation_required"

      {:ok, restarted} ->
        on_exit(fn -> stop(restarted) end)

        next =
          job(fixture, "after-malformed-open-index", %{
            "path" => "forbidden.txt",
            "content" => "forbidden"
          })

        assert {:error, reason} = Local.execute(restarted, next, grant(next), [], nil)
        rendered = inspect(reason)
        assert rendered =~ "ledger" and rendered =~ "unavailable"
        refute rendered =~ "reconciliation_required"
    end

    refute File.exists?(Path.join(fixture.workspace, "must-not-land.txt"))
    refute File.exists?(Path.join(fixture.workspace, "forbidden.txt"))
  end

  test "stopping only the Local runtime can leave a bypassed OS child alive and rollback requires positive termination" do
    fixture = prepared_fixture("rollback-survivor")
    {:ok, local} = start_local(fixture)
    Process.unlink(local)

    ready = Path.join(fixture.workspace, "rollback-child-ready")
    survived = Path.join(fixture.workspace, "rollback-child-survived")
    continue = Path.join(fixture.workspace, "rollback-owners-stopped")
    pid_file = Path.join(fixture.workspace, "rollback-child-pid")
    parent = self()

    on_exit(fn ->
      with {:ok, bytes} <- File.read(pid_file),
           {os_pid, ""} <- bytes |> String.trim() |> Integer.parse() do
        _terminated = terminate_os_process(os_pid)
      end
    end)

    # Concept: rollback cannot infer host quiescence from the application being
    # stopped. A child whose launch-owned guard never became authority can still
    # act after every Local process the operator knows about has stopped.
    #
    # Technical depth: this is deliberate fault injection, not a second product
    # launcher. The short-lived process below owns the Port directly, bypassing
    # Local's accepted launch guard. Its shell ignores the signals associated
    # with losing that Port, announces that it began, waits for the test to prove
    # both owners stopped, performs one observable effect, and then stays alive.
    # The case positively terminates that exact child before returning so the
    # retained demonstration itself leaves no operating-system residue.
    {bypass_owner, owner_monitor} =
      spawn_monitor(fn ->
        port =
          Port.open({:spawn_executable, ~c"/bin/sh"}, [
            :binary,
            :exit_status,
            :hide,
            args: [
              ~c"-c",
              ~c"trap \"\" HUP TERM; printf '%s' \"$$\" > rollback-child-pid; " ++
                ~c"printf ready > rollback-child-ready; " ++
                ~c"while [ ! -e rollback-owners-stopped ]; do sleep 0.05; done; " ++
                ~c"printf survived > rollback-child-survived; " ++
                ~c"while :; do sleep 1; done"
            ],
            cd: String.to_charlist(fixture.workspace)
          ])

        {:os_pid, os_pid} = Port.info(port, :os_pid)
        send(parent, {:bypassed_child_started, self(), os_pid})

        receive do
          :hold_bypassed_owner -> :ok
        end
      end)

    assert_receive {:bypassed_child_started, ^bypass_owner, os_pid}, 5_000
    assert wait_for_file(ready), "the deliberately unguarded child never began"
    assert File.read!(pid_file) == Integer.to_string(os_pid)

    try do
      Process.exit(bypass_owner, :kill)
      assert_receive {:DOWN, ^owner_monitor, :process, ^bypass_owner, :killed}, 1_000

      stop(local)
      refute Process.alive?(local)

      assert os_process_alive?(os_pid),
             "stopping the Port owner and Local runtime also terminated the bypassed child"

      File.write!(continue, "owners stopped")

      assert wait_for_file(survived),
             "the fault-injected child did not survive its Port owner and Local runtime"

      assert os_process_alive?(os_pid),
             "the survivor marker was written but its operating-system child was not alive"

      assert terminate_os_process(os_pid),
             "the rollback demonstration could not positively terminate its surviving child"

      refute os_process_alive?(os_pid),
             "the rollback demonstration left its surviving child behind"
    after
      _terminated = terminate_os_process(os_pid)
      if Process.alive?(bypass_owner), do: Process.exit(bypass_owner, :kill)
      stop(local)
    end
  end

  test "a peer's stranded open entry quarantines a running instance until it is reconciled" do
    fixture = prepared_fixture("peer-strand")

    {:ok, running} = start_local(fixture)
    on_exit(fn -> stop(running) end)

    {:ok, peer} = start_local(fixture)
    Process.unlink(peer)
    on_exit(fn -> stop(peer) end)

    stranded =
      job(fixture, "peer-stranded", %{
        "relative_path" => "never-settles.txt",
        "content" => "held",
        "delay_ms" => 5_000
      })

    parent = self()

    worker =
      spawn(fn -> Local.execute(peer, stranded, grant(stranded), [notify: parent], nil) end)

    assert_receive {:executor_process_started, "peer-stranded", _tool, _environment}, 5_000

    # The peer's authority is open on the shared root. Killing its worker and
    # then the peer itself leaves the entry with nothing that will ever settle
    # it, which is the state an operator finds after a host dies mid-effect.
    Process.exit(worker, :kill)
    stop(peer)

    assert [{open_path, open_record}] =
             fixture.ledger |> ledger_records() |> records_by_kind("local_open_effect_v1")

    assert open_record["job_id"] == "peer-stranded"

    # `running` never restarted, so a verdict decided when it started cannot see
    # this entry. ADR 0016 makes the open index shared truth, so its next
    # admission decision must read the index as it is now and refuse.
    different =
      job(fixture, "after-peer-strand", %{"path" => "forbidden.txt", "content" => "no"})

    assert {:error, {:reconciliation_required, 1}} =
             Local.execute(running, different, grant(different), [], nil)

    refute File.exists?(Path.join(fixture.workspace, "forbidden.txt"))

    # Exact reconciliation closes the entry, and the same instance admits again
    # without being restarted -- which a verdict frozen at start-up could not do
    # either.
    File.rm!(open_path)

    assert {:ok, %{outcome: :completed}} =
             Local.execute(running, different, grant(different), [], nil)

    assert File.read!(Path.join(fixture.workspace, "forbidden.txt")) == "no"
  end

  test "a peer's live job does not quarantine the instance that owns its own concurrent job" do
    fixture = prepared_fixture("concurrent-open")

    {:ok, local} = start_local(fixture)
    on_exit(fn -> stop(local) end)

    parent = self()

    held =
      job(fixture, "concurrent-held", %{
        "relative_path" => "held.txt",
        "content" => "held",
        "delay_ms" => 1_500
      })

    holder =
      Task.async(fn -> Local.execute(local, held, grant(held), [notify: parent], nil) end)

    assert_receive {:executor_process_started, "concurrent-held", _tool, _environment}, 5_000

    # One open entry exists and it is this instance's own live work. Reading it
    # as unresolved authority would make a root unusable the moment it carried
    # two jobs, which is a different failure from the one the quarantine exists
    # to cause.
    second = job(fixture, "concurrent-second", %{"path" => "second.txt", "content" => "yes"})

    assert {:ok, %{outcome: :completed}} =
             Local.execute(local, second, grant(second), [], nil)

    assert {:ok, %{outcome: :completed}} = Task.await(holder, 15_000)
  end

  test "lease-lost retention carries one shared absolute allowance into its worker" do
    # ADR 0016 gives one formula for `receipt_retention_ms`, and a committed
    # period of three is exactly where a second derivation by integer division
    # disagrees with it: the canonical result is one millisecond while `div/2`
    # produces zero. Proving the pure function alone proves nothing about the
    # running path, so this observes both the allowance production opens and the
    # exact absolute instant its later lease-lost retention worker receives.
    # Claim acquisition is an earlier phase of the same episode;
    # translating the remainder back into a duration would let scheduling delay
    # refresh it and violate the contract this case protects.
    assert {:ok, one_millisecond} = Executor.cancellation_bounds(3)
    assert one_millisecond.receipt_retention_ms == 1

    grace = 4_000
    assert {:ok, bounds} = Executor.cancellation_bounds(grace)

    fixture = prepared_fixture("lease-lost-reserve", grace)
    {:ok, local} = start_local(fixture)
    on_exit(fn -> stop(local) end)

    request =
      job(fixture, "lease-lost-reserve", %{"command" => "sleep 0.4; printf 'done\\n'"})

    parent = self()

    {:module, Local} = Code.ensure_loaded(Local)

    # A refutation over an untraced function proves nothing, so the pattern is
    # asserted to have matched exactly the one entry this reads.
    assert :erlang.trace_pattern({Local, :bound_only_work_until, 2}, true, [:local]) == 1
    assert :erlang.trace_pattern({Local, :retain_after_lease_loss, 2}, true, [:local]) == 1

    assert :erlang.trace_pattern(
             {Local, :receipt_reserve_ms, 1},
             [{:_, [], [{:return_trace}]}],
             [:local]
           ) == 1

    assert :erlang.trace_pattern(
             {Local, :retention_until, 0},
             [{:_, [], [{:return_trace}]}],
             [:local]
           ) == 1

    on_exit(fn ->
      _ = :erlang.trace_pattern({Local, :bound_only_work_until, 2}, false, [:local])
      _ = :erlang.trace_pattern({Local, :retain_after_lease_loss, 2}, false, [:local])
      _ = :erlang.trace_pattern({Local, :receipt_reserve_ms, 1}, false, [:local])
      _ = :erlang.trace_pattern({Local, :retention_until, 0}, false, [:local])
    end)

    task =
      Task.async(fn ->
        # The whole job runs in its caller, so tracing that process from its own
        # first instruction removes any window between arming the trace and the
        # calls it has to see.
        :erlang.trace(self(), true, [:call, {:tracer, parent}])
        result = Local.execute(local, request, grant(request), [notify: parent], nil)
        send(parent, {:retention_finished, self(), result})

        receive do
          :trace_collected -> result
        end
      end)

    assert_receive {:executor_process_started, "lease-lost-reserve", _tool, _environment}, 5_000

    # The lease that authorised the effect dies while the tool is still running.
    # The bash path monitors it locally, so the parent monitor's DOWN is still
    # in the mailbox when the receipt is settled, which is the lease-lost
    # retention this reserve belongs to.
    stop(fixture.lease)

    assert_receive {:retention_finished, tracee, result}, 15_000
    assert tracee == task.pid

    # Task completion and trace messages travel on different signal paths. A
    # zero-time mailbox drain after observing completion can therefore run before
    # the trace messages arrive. Keep the tracee alive, request the VM's delivery
    # barrier, and only then let it exit; every call and return used below is in
    # this mailbox before `collect_call_trace/0` starts.
    delivered = :erlang.trace_delivered(tracee)
    assert_receive {:trace_delivered, ^tracee, ^delivered}, 5_000
    send(tracee, :trace_collected)
    assert Task.await(task, 5_000) == result

    events = collect_call_trace()

    assert Enum.any?(
             events,
             &match?({:call, Local, :retain_after_lease_loss, _arguments}, &1)
           ),
           "the lease-lost retention path was never reached, so its reserve was not observed"

    assert canonical_retention_bound!(events, grace) == bounds.receipt_retention_ms

    {shared_deadline, worker_deadline} = lease_lost_deadline!(events)

    assert worker_deadline == shared_deadline,
           "the lease-lost retention refreshed or translated the shared absolute deadline: " <>
             "#{worker_deadline} != #{shared_deadline}"

    source = File.read!(Path.expand("../lib/executor.ex", __DIR__))

    assert source =~
             ~r/defp retention_until do\s+case Process\.get\(:loopex_retention_episode\) do.*?Process\.put\(:loopex_retention_episode, until\).*?until ->\s+until\s+end/s,
           "retention_until/0 no longer memoizes and reuses the first settlement deadline"
  end

  test "a refusal never renames over an admission marker for the same job" do
    fixture = prepared_fixture("refusal-conflict")

    assert {:ok, prepared} =
             invoke(Local, :prepare_placement, [fixture.ledger, @identity, @grace])

    admitted = job(fixture, "refused-over-admission", %{"path" => "x.txt", "content" => "x"})

    assert :ok =
             Ledger.with_claim(prepared, fn ->
               Ledger.admit(
                 prepared,
                 Ledger.marker(admitted),
                 Ledger.open_entry(admitted, @identity)
               )
             end)

    assert {:ok, refusal} = Ledger.refusal(admitted, :workspace_lease_not_held)

    # "No effect began" written over the exact record proving one did is the one
    # rewrite this plane must never make, and call-site ordering in one module is
    # not a property of a root two instances share.
    assert {:error, {:ledger_conflict, :admission_marker_present}} =
             Ledger.with_claim(prepared, fn -> Ledger.refuse(prepared, refusal) end)

    assert {:ok, marker} = Ledger.read_marker(prepared, admitted.job_id)
    assert marker.ledger_kind == Ledger.marker_kind()
    assert marker["canonical_request_digest"] == admitted.canonical_request_digest

    # An absent marker and an existing refusal both still admit the write,
    # because neither of them claims an effect began.
    unadmitted = job(fixture, "refused-twice", %{"path" => "y.txt", "content" => "y"})
    assert {:ok, first} = Ledger.refusal(unadmitted, :workspace_lease_not_held)
    assert {:ok, second} = Ledger.refusal(unadmitted, :effective_deadline_reached)

    assert :ok = Ledger.with_claim(prepared, fn -> Ledger.refuse(prepared, first) end)
    assert :ok = Ledger.with_claim(prepared, fn -> Ledger.refuse(prepared, second) end)

    assert {:ok, replaced} = Ledger.read_marker(prepared, unadmitted.job_id)
    assert replaced.ledger_kind == Ledger.refusal_kind()
    assert replaced["reason"]["code"] == "effective_deadline_reached"
  end

  defp canonical_retention_bound!(events, grace) do
    assert Enum.any?(events, &match?({:call, Local, :receipt_reserve_ms, [^grace]}, &1)),
           "the running settlement never derived its allowance from the canonical formula"

    events
    |> Enum.find_value(fn
      {:return, Local, :receipt_reserve_ms, 1, reserve} -> {:ok, reserve}
      _other -> nil
    end)
    |> case do
      {:ok, reserve} -> reserve
      nil -> flunk("the canonical retention formula returned no observed allowance")
    end
  end

  # The trace is ordered per process. Inside `retain_after_lease_loss/2`,
  # production reads the one shared instant and hands those exact bytes to
  # `bound_only_work_until/2`; no later phase turns its remainder into a fresh
  # duration.
  defp lease_lost_deadline!(events) do
    all_shared_deadlines =
      for {:return, Local, :retention_until, 0, value} <- events,
          do: value

    after_retain =
      Enum.drop_while(
        events,
        &(not match?({:call, Local, :retain_after_lease_loss, _arguments}, &1))
      )

    worker_deadline =
      Enum.find_value(after_retain, fn
        {:call, Local, :bound_only_work_until, [_work, value]} -> {:ok, value}
        _other -> nil
      end)

    case {all_shared_deadlines, worker_deadline} do
      {[first, _later | _rest] = deadlines, {:ok, worker_deadline}} ->
        assert Enum.uniq(deadlines) == [first],
               "one settlement returned more than one retention deadline: #{inspect(deadlines)}"

        {first, worker_deadline}

      {deadlines, _worker_deadline} when length(deadlines) < 2 ->
        flunk("the lease-lost settlement did not read its shared deadline in both phases")

      {_shared_deadlines, nil} ->
        flunk("the lease-lost retention entered no absolute-deadline bounded work")
    end
  end

  defp collect_call_trace(acc \\ []) do
    receive do
      {:trace, _pid, :call, {module, function, arguments}} ->
        collect_call_trace([{:call, module, function, arguments} | acc])

      {:trace, _pid, :return_from, {module, function, arity}, result} ->
        collect_call_trace([{:return, module, function, arity, result} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp prepared_fixture(label, grace \\ @grace) do
    workspace = temporary_root("workspace-#{label}")
    ledger = temporary_root("ledger-#{label}")
    File.mkdir_p!(workspace)

    on_exit(fn ->
      File.rm_rf(workspace)
      File.rm_rf(ledger)
    end)

    assert {:ok, _prepared} = invoke(Local, :prepare_placement, [ledger, @identity, grace])
    generation = generation_record!(ledger)
    lease_id = "lease-#{System.unique_integer([:positive])}"
    {:ok, lease} = WorkspaceLease.start_link(id: lease_id, path: workspace, fencing_token: @fence)
    on_exit(fn -> stop(lease) end)

    %{
      workspace: workspace,
      ledger: ledger,
      epoch: generation["executor_epoch"],
      grace: grace,
      lease_id: lease_id,
      lease: lease
    }
  end

  defp start_local(fixture, extra \\ []) do
    options =
      Keyword.merge(
        [
          identity: @identity,
          epoch: fixture.epoch,
          fencing_token: @fence,
          workspace_leases: %{fixture.lease_id => fixture.lease},
          ledger_root: fixture.ledger,
          cleanup_grace_ms: fixture.grace
        ],
        extra
      )

    Local.start_link(options)
  end

  defp job(
         fixture,
         id,
         arguments,
         deadline \\ System.system_time(:millisecond) + 60_000,
         overrides \\ %{}
       ) do
    default_tool_id =
      cond do
        Map.has_key?(arguments, "command") -> "loopex.bash"
        Map.has_key?(arguments, "delay_ms") -> "loopex.demo.wait_write"
        true -> "loopex.write"
      end

    tool_id = Map.get(overrides, :tool_id, default_tool_id)

    effect_class =
      Map.get(
        overrides,
        :effect_class,
        if(tool_id == "loopex.bash", do: "process", else: "workspace_write")
      )

    fields =
      Map.merge(
        %{
          protocol_version: 1,
          job_id: id,
          operation_id: "operation-#{id}",
          attempt: 1,
          session_id: "session-contract",
          run_id: "run-contract",
          turn_id: "turn-contract",
          tool_call_id: "call-#{id}",
          origin_session_epoch: 1,
          origin_executor_epoch: fixture.epoch,
          executor_identity: @identity,
          required_capabilities: [effect_class],
          tool_id: tool_id,
          tool_version: "1.0.0",
          effect_class: effect_class,
          validated_arguments: arguments,
          workspace_ref: "workspace-contract",
          workspace_lease: fixture.lease_id,
          run_deadline: deadline,
          resource_budgets: %{"max_output_bytes" => 65_536},
          idempotency_class: "never_blind_retry",
          fencing_token: @fence,
          artifact_policy: %{"retain" => true},
          output_policy: %{"capture" => true},
          cleanup_grace_ms: fixture.grace
        },
        Map.drop(overrides, [:tool_id, :effect_class])
      )

    assert {:ok, request} = Executor.job(fields)
    request
  end

  defp grant(job) do
    assert {:ok, grant} =
             Executor.issue_grant(
               {:host_policy, :allow},
               job,
               System.system_time(:millisecond) + 60_000
             )

    grant
  end

  defp generation_record!(root) do
    root
    |> Path.join("**/*")
    |> Path.wildcard(match_dot: true)
    |> Enum.find_value(fn path ->
      with {:ok, %File.Stat{type: :regular}} <- File.lstat(path),
           {:ok, bytes} <- File.read(path),
           record when is_map(record) <- safe_decode(bytes),
           "local_executor_generation_v1" <- Map.get(record, :ledger_kind) do
        record
      else
        _other -> nil
      end
    end)
    |> case do
      nil -> flunk("the prepared root has no valid generation record")
      record -> record
    end
  end

  defp generation_path!(root) do
    root
    |> Path.join("**/*")
    |> Path.wildcard(match_dot: true)
    |> Enum.find(fn path ->
      with {:ok, bytes} <- File.read(path),
           record when is_map(record) <- safe_decode(bytes) do
        Map.get(record, :ledger_kind) == "local_executor_generation_v1"
      else
        _other -> false
      end
    end)
    |> case do
      nil -> flunk("the prepared root has no generation file")
      path -> path
    end
  end

  defp clock_provider([first | rest]) do
    {:ok, clock} = Agent.start_link(fn -> {first, rest} end)
    on_exit(fn -> stop(clock) end)

    fn ->
      Agent.get_and_update(clock, fn
        {current, [next | tail]} -> {current, {next, tail}}
        {current, []} -> {current, {current, []}}
      end)
    end
  end

  defp clock_provider_with_action([first | rest], action_sample, action)
       when is_integer(action_sample) and action_sample > 0 and is_function(action, 0) do
    {:ok, clock} = Agent.start_link(fn -> {1, first, rest} end)
    on_exit(fn -> stop(clock) end)

    fn ->
      {sample, act?} =
        Agent.get_and_update(clock, fn
          {index, current, [next | tail]} ->
            {{current, index == action_sample}, {index + 1, next, tail}}

          {index, current, []} ->
            {{current, index == action_sample}, {index + 1, current, []}}
        end)

      if act?, do: action.()
      sample
    end
  end

  # Concept: three phases, each entered by an event the case controls or the
  # effect produces, never by elapsed time or by counting calls. Phase one is
  # request handoff: the executor is held between handoff and admission because
  # prestart validation resolves the workspace lease with a call and a suspended
  # lease cannot answer it. The case advances to phase two immediately before it
  # lets the lease answer, so every admission-time sample is distinguishable from
  # a handoff-time one. Phase three is the delayed effect's own output file, so a
  # completion-time resample is distinguishable from the admission sample. ADR
  # 0016 requires the admission sample and forbids the other two.
  defp admission_phase_clock(wall, boundary_path) do
    {:ok, phase} = Agent.start_link(fn -> :handoff end)
    {:ok, samples} = Agent.start_link(fn -> 0 end)
    on_exit(fn -> stop(phase) end)
    on_exit(fn -> stop(samples) end)

    clock = fn ->
      taken = Agent.get_and_update(samples, &{&1, &1 + 1})

      sampled_wall =
        cond do
          File.exists?(boundary_path) -> wall + 20_000
          Agent.get(phase, & &1) == :admitted -> wall + 10_000
          true -> wall
        end

      {sampled_wall, 10_000 + taken}
    end

    {clock, phase, samples}
  end

  # One second at most: the lease call this waits behind times out at five.
  defp await_queued_call(pid, attempts \\ 200)
  defp await_queued_call(_pid, 0), do: false

  defp await_queued_call(pid, attempts) do
    queued? =
      case Process.info(pid, :messages) do
        {:messages, messages} -> Enum.any?(messages, &match?({:"$gen_call", _from, _}, &1))
        _dead -> false
      end

    if queued? do
      true
    else
      Process.sleep(5)
      await_queued_call(pid, attempts - 1)
    end
  end

  defp expiring_monotonic_clock(wall) do
    started = System.monotonic_time(:millisecond)
    {:ok, samples} = Agent.start_link(fn -> :first end)
    on_exit(fn -> stop(samples) end)

    fn ->
      elapsed = System.monotonic_time(:millisecond) - started

      sampled_wall =
        Agent.get_and_update(samples, fn
          :first -> {wall, :later}
          :later -> {wall - 10_000, :later}
        end)

      {sampled_wall, 20_000 + elapsed}
    end
  end

  defp expected_root_binding(root) do
    expanded = Path.expand(root)
    stat = File.stat!(expanded, time: :posix)

    input =
      <<"loopex:local-root-binding:v1", 0, byte_size(expanded)::unsigned-64-big, expanded::binary,
        stat.major_device::unsigned-64-big, stat.inode::unsigned-64-big>>

    sha256(input)
  end

  defp receipt_path!(root, job_id) do
    root
    |> Path.join("**/*")
    |> Path.wildcard(match_dot: true)
    |> Enum.find(fn path ->
      with {:ok, %File.Stat{type: :regular}} <- File.lstat(path),
           {:ok, bytes} <- File.read(path),
           receipt when is_map(receipt) <- safe_decode(bytes) do
        Map.get(receipt, :job_id) == job_id and Map.has_key?(receipt, :outcome)
      else
        _other -> false
      end
    end)
    |> case do
      nil -> flunk("the retained receipt for #{inspect(job_id)} has no durable file")
      path -> path
    end
  end

  defp abandoned_open_directory(label) do
    fixture = prepared_fixture(label)
    {:ok, local} = start_local(fixture)
    Process.unlink(local)

    request =
      job(fixture, "seed-#{label}", %{
        "relative_path" => "seed-#{label}.txt",
        "content" => "forbidden",
        "delay_ms" => 30_000
      })

    parent = self()

    task =
      Task.async(fn -> Local.execute(local, request, grant(request), [notify: parent], nil) end)

    job_id = request.job_id

    assert_receive {:executor_process_started, ^job_id, _tool, _environment}, 5_000

    assert [{open_path, _open}] =
             fixture.ledger
             |> ledger_records()
             |> records_by_kind("local_open_effect_v1")

    Process.exit(local, :kill)
    Task.shutdown(task, :brutal_kill)

    fixture.ledger
    |> ledger_records()
    |> Enum.reject(fn {_path, record} ->
      record.ledger_kind == "local_executor_generation_v1"
    end)
    |> Enum.each(fn {path, _record} -> File.rm!(path) end)

    {fixture, Path.dirname(open_path)}
  end

  defp replace_open_index(fixture, directory, count, id_width) do
    File.mkdir_p!(directory)

    directory
    |> File.ls!()
    |> Enum.each(&File.rm!(Path.join(directory, &1)))

    for index <- 1..count do
      append_open_record(fixture, directory, index, id_width)
    end
  end

  defp append_open_record(fixture, directory, index, id_width) do
    suffix = Integer.to_string(index)
    job_id = :binary.copy("j", id_width) <> "-" <> suffix
    request = job(fixture, job_id, %{"path" => "never-#{suffix}.txt", "content" => "x"})

    record = %{
      :ledger_kind => "local_open_effect_v1",
      "job_id" => request.job_id,
      "canonical_request_digest" => request.canonical_request_digest,
      "executor_identity" => @identity,
      "origin_executor_epoch" => fixture.epoch,
      "cleanup_grace_ms" => fixture.grace
    }

    File.write!(
      Path.join(directory, sha256(request.job_id)),
      :erlang.term_to_binary(record, [:deterministic])
    )
  end

  defp assert_reconciliation_snapshot(fixture) do
    case start_local(fixture) do
      {:error, reason} ->
        rendered = inspect(reason)
        assert rendered =~ "reconciliation"
        refute rendered =~ "ledger_unavailable"

      {:ok, local} ->
        next =
          job(fixture, "after-complete-snapshot", %{"path" => "forbidden.txt", "content" => "x"})

        assert {:error, reason} = Local.execute(local, next, grant(next), [], nil)
        assert inspect(reason) =~ "reconciliation"
        stop(local)
    end
  end

  defp assert_ledger_unavailable(fixture, expected_detail) do
    answer =
      case start_local(fixture) do
        {:error, reason} ->
          {:error, reason}

        {:ok, local} ->
          next =
            job(fixture, "after-unavailable-#{expected_detail}", %{
              "path" => "forbidden.txt",
              "content" => "x"
            })

          result = Local.execute(local, next, grant(next), [], nil)
          stop(local)
          result
      end

    assert {:error, reason} = answer
    rendered = inspect(reason)
    assert rendered =~ "ledger"
    assert rendered =~ "unavailable" or rendered =~ expected_detail
  end

  defp ledger_records(root) do
    root
    |> Path.join("**/*")
    |> Path.wildcard(match_dot: true)
    |> Enum.flat_map(fn path ->
      with {:ok, %File.Stat{type: :regular}} <- File.lstat(path),
           {:ok, bytes} <- File.read(path),
           record when is_map(record) <- safe_decode(bytes),
           kind when is_binary(kind) <- Map.get(record, :ledger_kind) do
        [{path, record}]
      else
        _other -> []
      end
    end)
  end

  defp records_by_kind(records, kind) do
    Enum.filter(records, fn {_path, record} -> Map.get(record, :ledger_kind) == kind end)
  end

  defp collect_file_trace(acc \\ []) do
    receive do
      {:trace, _pid, :call, {:file, :open, [_path, _modes]}} = event ->
        collect_file_trace([event | acc])

      {:trace, _pid, :return_from, {:file, :open, 2}, _result} = event ->
        collect_file_trace([event | acc])

      {:trace, _pid, :call, {:file, :sync, [_device]}} = event ->
        collect_file_trace([event | acc])

      {:trace, _pid, :call, {:file, :sync, _device}} = event ->
        collect_file_trace([event | acc])
    after
      50 -> Enum.reverse(acc)
    end
  end

  defp synced_paths(events) do
    {_pending, _devices, synced} =
      Enum.reduce(events, {%{}, %{}, []}, fn
        {:trace, pid, :call, {:file, :open, [path, _modes]}}, {pending, devices, synced} ->
          stack = Map.get(pending, pid, [])
          {Map.put(pending, pid, [normalize_path(path) | stack]), devices, synced}

        {:trace, pid, :return_from, {:file, :open, 2}, {:ok, device}},
        {pending, devices, synced} ->
          case Map.get(pending, pid, []) do
            [path | rest] ->
              {Map.put(pending, pid, rest), Map.put(devices, device, path), synced}

            [] ->
              {pending, devices, synced}
          end

        {:trace, _pid, :return_from, {:file, :open, 2}, _error}, {pending, devices, synced} ->
          {pending, devices, synced}

        {:trace, _pid, :call, {:file, :sync, [device]}}, {pending, devices, synced} ->
          {pending, devices, [Map.get(devices, device) | synced]}

        {:trace, _pid, :call, {:file, :sync, device}}, {pending, devices, synced} ->
          {pending, devices, [Map.get(devices, device) | synced]}
      end)

    synced |> Enum.reverse() |> Enum.reject(&is_nil/1)
  end

  defp normalize_path(path) when is_binary(path), do: Path.expand(path)

  defp normalize_path(path) when is_list(path),
    do: path |> IO.chardata_to_string() |> Path.expand()

  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  defp safe_decode(bytes) do
    :erlang.binary_to_term(bytes, [:safe])
  rescue
    _error -> :invalid
  end

  defp wait_for_file(path, attempts \\ 200)
  defp wait_for_file(_path, 0), do: false

  defp wait_for_file(path, attempts) do
    if File.exists?(path) do
      true
    else
      Process.sleep(10)
      wait_for_file(path, attempts - 1)
    end
  end

  defp os_process_alive?(os_pid) when is_integer(os_pid) and os_pid > 1 do
    case System.cmd("/bin/kill", ["-0", Integer.to_string(os_pid)], stderr_to_stdout: true) do
      {_output, 0} -> true
      {_output, _status} -> false
    end
  end

  defp terminate_os_process(os_pid) when is_integer(os_pid) and os_pid > 1 do
    if os_process_alive?(os_pid) do
      _ = System.cmd("/bin/kill", ["-KILL", Integer.to_string(os_pid)], stderr_to_stdout: true)
    end

    wait_for_process_exit(os_pid, 200)
  end

  defp wait_for_process_exit(_os_pid, 0), do: false

  defp wait_for_process_exit(os_pid, attempts) do
    if os_process_alive?(os_pid) do
      Process.sleep(10)
      wait_for_process_exit(os_pid, attempts - 1)
    else
      true
    end
  end

  defp temporary_root(label) do
    Path.join(System.tmp_dir!(), "loopex-a4-#{label}-#{System.unique_integer([:positive])}")
  end

  defp shell_path(path), do: "'" <> String.replace(path, "'", "'\\''") <> "'"

  defp stop(pid) when is_pid(pid) do
    if Process.alive?(pid) do
      try do
        GenServer.stop(pid, :normal, 1_000)
      catch
        :exit, _reason -> :ok
      end
    end
  end

  # Concept: a refusal is only evidence if the contract entry exists to refuse.
  # `invoke/3` reports an absent entry as an ordinary error, so a bare
  # `{:error, _}` here would be satisfied by the boundary simply not shipping.
  defp assert_refused(result) do
    assert {:error, reason} = result

    refute match?({:contract_entry_missing, _module, _function, _arity}, reason),
           "the contract entry is absent, so this refusal proves nothing: #{inspect(reason)}"

    reason
  end

  defp invoke(module, function, arguments) do
    if Code.ensure_loaded?(module) and function_exported?(module, function, length(arguments)) do
      apply(module, function, arguments)
    else
      {:error, {:contract_entry_missing, module, function, length(arguments)}}
    end
  end
end
