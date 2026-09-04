defmodule Loopex.Executor.Local do
  @moduledoc """
  ## Concept

  The M1 trusted-local executor. It resolves a host-held workspace lease,
  validates every ADR 0007 binding at one serialized final boundary, launches a
  fixed controlled OS tool with a credential-free environment, and durably
  retains the terminal receipt before replying.

  ## Technical depth

  One GenServer serializes final validation and process start. The fixed tool
  registry is code-owned rather than model-owned. `/usr/bin/env -i` constructs
  the child environment from nothing, then a fixed shell program receives only
  validated bounded arguments. The lease is monitored for every job's full
  lifetime: losing it ends the owned process group or abandons the filesystem
  effect, and the job is retained as unproven rather than complete. Receipts are
  synced to one file per job and exact duplicate jobs return the retained receipt
  without another start.
  """

  use GenServer

  @behaviour Loopex.Executor

  alias Loopex.Executor
  alias Loopex.Executor.Local.CodingTools
  alias Loopex.Executor.Local.Ledger
  alias Loopex.Executor.Local.WorkspaceLease

  @max_output_bytes 1_048_576
  @max_progress_chunk_bytes 65_536

  # Concept: the declared grace the cancellation sequence gets once the run's own
  # instant has passed, and the only number any of that work is measured against.
  #
  # Technical depth: obligation 4 runs termination and its confirmations *after*
  # expiry, so the work that follows a deadline cannot be bounded by the deadline
  # -- that instant is already behind it. Everything the run owns before its
  # deadline is bounded by the deadline itself and never by this.
  #
  # This used to be a bound handed separately to each cleanup program. ADR 0009
  # asks for one visible period and that was four: the `TERM`, the `KILL`, each
  # `ps` confirmation and the receipt's retention each received five seconds of
  # their own, and `quiesce_group/2` spends three of them in sequence, so a job
  # could take more than twenty seconds to finish cleaning up under a grace that
  # said five. The cooperative pause between `TERM` and `KILL` was worse than
  # invisible: it was fifty milliseconds, written nowhere an operator could read
  # and unrelated to the declared period.
  #
  # `cleanup_until/1` turns the grace into one absolute instant per job, and
  # every step of the termination sequence -- cooperative grace, forced
  # termination, and each confirmation -- draws what remains of that one
  # instant. Retaining the receipt afterwards gets the separately declared
  # quarter-period reserve, so a stubborn group cannot spend the time needed to
  # write the durable account of what happened.
  #
  # The number itself is the port's, not this executor's. ADR 0009 makes the
  # cleanup grace a session configuration value, and a session that declares one
  # hands it here; a session and a hand that each kept their own default would
  # agree only until one was edited, and the run's terminal would then report a
  # period the cleanup did not run under.
  # Concept: the program this executor asks whether a process group still has
  # members, and the share of the declared period reserved for writing down what
  # happened.
  #
  # Technical depth: the probe was the literal `/bin/ps`. That is a portability
  # assumption rather than a fact -- an image whose `ps` lives only at
  # `/usr/bin/ps`, or which ships none, makes every confirmation fail, and this
  # executor then reports every command unproven with nothing to say why. Naming
  # it is also what makes the unconfirmed branch reachable: a case can compose an
  # executor whose probe is not there, which no case could do with a literal.
  #
  # The reserve exists because one declared period taken first-come means the
  # last step gets whatever the earlier ones left -- and a job that spent its
  # period on a group refusing to die left nothing at all, so the receipt could
  # not be written for exactly the job whose durable record matters most. The
  # receipt is bounded by this declared share instead, so it is never starved and
  # never given a second full period either.
  #
  # The termination sequence keeps the whole period rather than the period less
  # this share. Reserving it there as well was tried and deleted: the cooperative
  # share already caps the sequence at half the period, which is always less than
  # the period minus a quarter, so the subtraction could never bind and no case
  # could observe it. An invariant nothing can observe is not an invariant, and
  # the honest statement is the one this makes -- the stop is bounded by the
  # period plus this share, in the worst case where the sequence spends all of
  # its own.
  @default_process_probe "/bin/ps"
  @max_uint64 18_446_744_073_709_551_615

  # How often a joining request looks for the one operation's receipt. It is a
  # poll rather than a wait because the operation may belong to another VM, and
  # it is short because the join is already bounded by the job's own deadline.
  @join_poll_ms 25

  # The longest single `receive` slice this executor ever arms. Admitted cleanup
  # periods and job deadlines span the whole positive unsigned 64-bit range,
  # which no VM timer accepts, so every long wait is spent against one instant in
  # slices no larger than this.
  @timer_slice_ms 3_600_000

  # The longest an admission waits for another instance's root claim before
  # reporting the ledger unavailable. It bounds contention between executors
  # sharing one root, is capped by the job's own deadline, and never becomes
  # permission: only the holder releases the claim.
  @claim_wait_ms 5_000

  # The share of what remains that a signalled group gets to exit on its own
  # before it is killed. It is a share rather than a number so that it cannot
  # drift away from the declared period the way fifty milliseconds had, and half
  # rather than all of it so that a group which ignores `TERM` still leaves time
  # for the `KILL` and the confirmation that follows.
  @cooperative_share 2

  # How often a signalled group is looked at while it is being given that grace.
  # A `ps` costs a few milliseconds, so the common case -- a group that is gone
  # the moment it is signalled -- pays one look rather than the whole window.
  @cooperative_poll_ms 25

  # The wait for a cleanup helper's own kill to be reported. It is a fixed bound
  # for the same reason `@abandon_confirmation_ms` is: it is asked only once a
  # bound has already been exceeded, and `kill(2)` either returns at once or the
  # process running it is itself the thing that has stopped answering.
  @helper_signal_ms 250

  # The wait for a killed worker to be confirmed dead. It is a fixed bound rather
  # than a deadline for the same reason: it is asked only once a bound has
  # already been exceeded, and a worker blocked in a dirty scheduler may never
  # answer at all.
  @abandon_confirmation_ms 1_000
  @tool_version "1.0.0"
  @write_tool "loopex.demo.write"
  @wait_write_tool "loopex.demo.wait_write"
  @credential_name "LOOPEX_PROVIDER_API_KEY"
  @search_path_name "PATH"
  @search_path_value "/usr/bin:/bin"

  @group_terminated_note "\n[loopex: the command exited while members of its own process " <>
                           "group were still running. The group was terminated and is " <>
                           "confirmed cleaned, so nothing it left behind outlives this job.]"

  @group_unconfirmed_note "\n[loopex: the command exited while members of its own process " <>
                            "group were still running, and the group could not be confirmed " <>
                            "cleaned. Whether its effect is complete is unproven.]"

  @deadline_released_note "\n[loopex: the run deadline passed while this tool was running. " <>
                            "This path captures no process group, so the child was released " <>
                            "rather than confirmed stopped and whether its effect landed is " <>
                            "unproven.]"

  @cancelled_released_note "\n[loopex: this job was cancelled while its child was running. " <>
                             "This path captures no process group, so the child was released " <>
                             "rather than confirmed stopped and whether its effect landed is " <>
                             "unproven.]"

  @open_authority_note "\n[loopex: this job's open authority could not be removed after its " <>
                         "receipt was retained, so this executor's state root stays " <>
                         "quarantined until an operator reconciles it, and this job's " <>
                         "cleanup is reported unconfirmed.]"

  @lease_lost_note "\n[loopex: the workspace lease was lost before this job's receipt was " <>
                     "durably retained. Whether its effect landed in the workspace this job " <>
                     "was authorised against is unproven.]"

  @typedoc """
  ## Concept

  The explicit reference to one local executor instance.

  ## Technical depth

  This pid is transient placement state and never enters durable or public
  protocol data.
  """
  @type t :: pid()

  @doc """
  ## Concept

  Starts one explicitly configured trusted-local executor.

  ## Technical depth

  Lease pids and the ledger path are edge-private. Identity, epoch, and fence
  are the plain values jobs and receipts bind.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options) when is_list(options), do: GenServer.start_link(__MODULE__, options)

  @doc """
  ## Concept

  Runs or recalls one exact controlled job.

  ## Technical depth

  Duplicate job IDs return a matching retained receipt. A different digest
  under the same ID is refused and never starts a process.

  The serialized owner decides *whether* this job may proceed; the caller then
  performs the work. ADR 0016 names the effect boundary as the serialized
  transition that reserves exact worker authority immediately before its single
  permit, and that is exactly what crosses the GenServer here: the quarantine
  check, the retained-receipt decision, and the in-memory reservation. Prestart
  validation, the durable admission publication under the root claim, the effect,
  its receipt, and the removal of this job's open authority all run in the
  calling process.

  That placement is not a detail. A serialized owner that also *ran* every effect
  was unavailable for the whole length of the longest job it had admitted, so a
  second job, a receipt read, and a cancellation all queued behind the work they
  needed to talk about; and a caller blocked inside an unbounded call died with
  the executor whenever the executor died, taking work that had nothing to do
  with it. Ownership of the durable truth stays with the server; ownership of the
  waiting stays with whoever chose to wait.
  """
  @impl Loopex.Executor
  @spec execute(t(), Executor.job_request(), Executor.grant(), keyword(), Executor.progress_fun()) ::
          {:ok, map()} | {:error, term()}
  def execute(executor, job, grant, options \\ [], progress \\ nil)

  def execute(executor, job, grant, options, progress)
      when is_pid(executor) and is_map(job) and is_map(grant) and is_list(options) do
    # Concept: the shipped shell tool reports output while it runs; a filesystem
    # tool that starts no child remains a truthful zero-progress executor.
    #
    # Technical depth: the callback is called only for bytes the process
    # collector has admitted after removing its private process-group preamble. A
    # duplicate job returns the retained receipt without replaying transient
    # output.
    progress = progress || Executor.discard_progress()
    job_id = Map.get(job, :job_id, "")

    case GenServer.call(executor, {:reserve, job}) do
      {:ok, placement} ->
        try do
          run_reserved(placement, job, grant, options, progress)
        after
          GenServer.cast(executor, {:release, job_id})
        end

      {:retained, receipt} ->
        {:ok, receipt}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  ## Concept

  Stops one running job's process tree and reports whether it is gone.

  ## Technical depth

  Runs in the caller rather than in this executor's GenServer, because that
  server is blocked for the duration of the job being cancelled. The operating
  system effect still belongs to this application — the hand owns effects, and
  this is the hand's code — but it must not be queued behind the very work it is
  meant to end.

  Signals the job's owned process group and then confirms by looking for
  survivors. A job this instance has no record of is decided by the root every
  instance shares rather than by this one's memory. An unavailable executor
  proves nothing, because its process-local ledger may have disappeared with
  work still in flight.
  """
  @impl Loopex.Executor
  @spec cancel(t(), binary()) :: {:ok, :cleaned} | {:ok, :unconfirmed}
  def cancel(executor, job_id) when is_pid(executor) and is_binary(job_id) do
    case lookup_inflight(executor, job_id) do
      {:ok, group, default, probe, ledger} ->
        # The cancellation is its own cleanup episode, so its one absolute
        # instant opens here rather than being inherited from a job whose own
        # deadline may be minutes away. It takes the whole period rather than the
        # period less the receipt's share, because a cancellation writes no
        # receipt: it answers its caller and the job's own path retains the
        # record.
        episode = cancellation_episode(committed_grace(ledger, job_id, default), probe)
        terminate_group(group, episode)

        if confirm_group_terminated(group, episode),
          do: {:ok, :cleaned},
          else: {:ok, :unconfirmed}

      {:starting, worker, default, probe, ledger} ->
        cancel_starting_job(
          worker,
          cancellation_episode(committed_grace(ledger, job_id, default), probe)
        )

      # Concept: an identity nothing here has ever heard of is an identity this
      # executor cannot speak for, and saying nothing is different from saying
      # nothing happened.
      #
      # Technical depth: ADR 0016 clause 4 -- "An absent ID has no request digest
      # and answers unconfirmed without durable cancellation state." This branch
      # read the shared root and answered `{:ok, :cleaned}` wherever the root held
      # no open entry for the identity. That treated absence as a positive claim
      # in the one place the ADR forbids it: `cleaned` is reserved for a matching
      # durable refusal or an independently confirmed cleanup, and an ID with no
      # entry produces neither. A root holds no entry for an identity admitted on
      # a different root, for one whose request digest nothing here can bind, and
      # for one this instance simply never saw -- and the first two of those can
      # still be running. The open-entry read is gone rather than inverted,
      # because both of its answers are `unconfirmed` and a read whose result
      # cannot change the answer is a claim to authority this branch does not
      # have. `committed_grace/3` still reads the root, because the period a
      # cancellation spends is a different question from what it may assert.
      :absent ->
        {:ok, :unconfirmed}

      :executor_unavailable ->
        {:ok, :unconfirmed}
    end
  end

  # Concept: the period a cancellation spends is the period the cancelled job
  # committed, not the period this executor happened to be started with.
  #
  # Technical depth: ADR 0016 makes the committed value the one Local uses for
  # the job being cancelled, and the open-authority entry is where that value is
  # durably recorded for exactly this job -- which is also what lets an instance
  # spend the right period for a job another instance admitted. The start default
  # stands only where no committed value can be read: a root that is unavailable
  # or holds no entry for this identity. That is a fallback for an unreadable
  # root rather than a second source of truth.
  defp committed_grace(ledger, job_id, default) do
    case open_authority(ledger, job_id) do
      {:ok, %{"cleanup_grace_ms" => grace}} -> grace
      _no_committed_value -> default
    end
  end

  # Concept: one closed reading of the shared root, taken while nothing may
  # change it.
  #
  # Technical depth: ADR 0016 requires every decision that reads open authority
  # to acquire the root-wide claim, read one complete bounded snapshot while
  # mutation is excluded, and fix its decision before releasing it; no unlocked
  # observation is cancellation authority. The claim is not waited for, because a
  # cancellation carries no deadline of its own to spend on contention, and
  # refusal is unavailability rather than permission either way.
  defp open_authority(nil, _job_id), do: :unavailable

  defp open_authority(ledger, job_id) do
    answer =
      Ledger.with_claim(ledger, fn ->
        case Ledger.open_snapshot(ledger) do
          {:ok, entries} ->
            case Enum.find(entries, &(&1["job_id"] == job_id)) do
              nil -> :absent
              entry -> {:ok, entry}
            end

          {:error, _unreadable} ->
            :unavailable
        end
      end)

    case answer do
      {:error, _claim_unavailable} -> :unavailable
      settled -> settled
    end
  end

  # Concept: waiting out an admitted period is one wait spent in slices, not one
  # timer the VM refuses to arm.
  #
  # Technical depth: ADR 0016 admits `1..2^64-1` and states that timer
  # implementation limits do not silently cap it. A `receive ... after` above
  # 2^32-1 raises `:timeout_value` instead of waiting, so the accepted maximum
  # crashed whoever called `cancel/2` rather than bounding this wait. The wait is
  # measured against the cancellation episode's one absolute instant in slices no
  # larger than `@timer_slice_ms`, which changes how the wait is implemented and
  # not how long it is. The episode is created by the caller so that both
  # branches of one cancellation open exactly one instant between them.
  defp cancel_starting_job(worker, {until, grace, probe}) do
    token = make_ref()
    monitor = Process.monitor(worker)
    send(worker, {:loopex_cancel_pending, token, self(), grace, probe})
    await_cancel_result(worker, monitor, token, until)
  end

  defp await_cancel_result(worker, monitor, token, until) do
    receive do
      {:loopex_cancel_result, ^token, result} ->
        Process.demonitor(monitor, [:flush])
        result

      {:DOWN, ^monitor, :process, ^worker, _reason} ->
        {:ok, :unconfirmed}
    after
      min(cleanup_remaining(until), @timer_slice_ms) ->
        if cleanup_remaining(until) == 0 do
          Process.demonitor(monitor, [:flush])
          {:ok, :unconfirmed}
        else
          await_cancel_result(worker, monitor, token, until)
        end
    end
  end

  @doc """
  ## Concept

  The one cleanup period this executor was configured with, in milliseconds.

  ## Technical depth

  ADR 0009 asks for a single configured *session* grace reported in the run's
  terminal evidence, and that is where the number comes from: the session
  declares it, the shipped composition hands the same value here, and the run's
  terminal reports the session's declaration. This function is not that
  declaration — it is where a **host that composed this executor** reads back the
  value it passed, which is the number this executor actually spends and the
  number every receipt it retains reports as `cleanup_grace_ms`. A host that
  composed the two halves with different numbers would see them disagree here,
  which is the point of being able to read it at all. The one default they share
  is `Loopex.Executor.default_cleanup_grace_ms/0`.
  """
  @spec cleanup_grace_ms(t()) :: non_neg_integer()
  def cleanup_grace_ms(executor) when is_pid(executor),
    do: GenServer.call(executor, :cleanup_grace_ms)

  @doc """
  ## Concept

  The cleanup period this executor starts new work with when a job names none.

  ## Technical depth

  ADR 0016 makes the committed session value the one a job actually runs under,
  carried by the `JobRequest` itself. This is the startup default beside it, and
  the retained `cleanup_grace_ms/1` name is an alias for exactly this value.
  Neither is the period of an active job: reading a period off the executor while
  a job declaring a different one is running would report the wrong number for
  the only question worth asking.
  """
  @spec default_cleanup_grace_ms(t()) :: non_neg_integer()
  def default_cleanup_grace_ms(executor) when is_pid(executor),
    do: GenServer.call(executor, :cleanup_grace_ms)

  @doc """
  ## Concept

  Validates or exclusively creates one prepared receipt-ledger root and returns
  the private authority over it.

  ## Technical depth

  The placement boundary ADR 0016 names. A host prepares the root once and every
  executor sharing it inherits the same generation, admission marker set, open
  index, and refusal or receipt truth. A whole-root move presented at another
  expanded path, a replacement directory, and an isolated copy of the generation
  file are refused. The returned authority is edge-private: it never enters a
  job, grant, receipt, event, log, or diagnostic.
  """
  @spec prepare_placement(binary(), binary(), pos_integer()) ::
          {:ok, Ledger.prepared()} | {:error, term()}
  def prepare_placement(ledger_root, executor_identity, cleanup_grace_ms),
    do: Ledger.prepare(ledger_root, executor_identity, cleanup_grace_ms)

  @doc """
  ## Concept

  The program this executor asks whether a process group still has members.

  ## Technical depth

  Read back for the same reason the cleanup period is: a host that composed a
  probe its image does not ship gets every command reported unproven, and the
  first question is which program was actually asked. It is written into every
  receipt beside the period, so a receipt saying an effect could not be confirmed
  names what could not confirm it.
  """
  @spec process_probe(t()) :: binary()
  def process_probe(executor) when is_pid(executor),
    do: GenServer.call(executor, :process_probe)

  defp lookup_inflight(executor, job_id) do
    case Process.info(executor, :dictionary) do
      nil ->
        :executor_unavailable

      {:dictionary, dictionary} ->
        table = Keyword.get(dictionary, :loopex_inflight_table)

        grace =
          Keyword.get(
            dictionary,
            :loopex_cleanup_grace_ms,
            Executor.default_cleanup_grace_ms()
          )

        probe = Keyword.get(dictionary, :loopex_process_probe, @default_process_probe)
        ledger = table && ledger_authority(table)

        case table && :ets.lookup(table, job_id) do
          [{^job_id, {:starting, worker}}] when is_pid(worker) ->
            {:starting, worker, grace, probe, ledger}

          [{^job_id, group}] when is_integer(group) and group > 1 ->
            {:ok, group, grace, probe, ledger}

          _absent ->
            :absent
        end
    end
  rescue
    ArgumentError -> :executor_unavailable
  end

  # Concept: the root authority a cancellation reads is kept where this
  # executor's other cancellation state is kept, and not where a crash prints
  # it.
  #
  # Technical depth: `cancel/2` runs in its caller, so it reaches this
  # executor's state without calling it -- the period, the probe and the
  # in-flight table are already read that way. The prepared ledger authority
  # cannot join them in the process dictionary: `proc_lib` crash reports carry a
  # process's whole dictionary, and ADR 0016 keeps the root path, generation
  # digest, and root binding out of every log and diagnostic plane. The
  # executor's own in-flight table is the same private per-instance state,
  # readable without waiting for the server, and is not dumped anywhere. The key
  # is an atom and every job identity is a binary, so the two cannot collide.
  @ledger_authority_key :loopex_ledger_authority

  defp ledger_authority(table) do
    case :ets.lookup(table, @ledger_authority_key) do
      [{@ledger_authority_key, ledger}] -> ledger
      _absent -> nil
    end
  rescue
    ArgumentError -> nil
  end

  # Concept: a job's process cleanup is one episode with one instant, opened the
  # first time termination or confirmation needs it and shared by those steps.
  #
  # Technical depth: the alternative -- deriving the instant from the run's
  # deadline -- reads well and is wrong in both directions. A job that finishes
  # cleanly a second into a sixty-second deadline would be handing each `ps` a
  # sixty-five-second bound, which is a worse hang than the five seconds it
  # replaced; and a job cleaning up *at* its deadline needs a bound independent
  # of that already-spent instant. The episode is what makes every termination
  # and confirmation step draw from one process-cleanup period rather than one
  # fresh period apiece. Receipt retention follows under its separate reserve.
  #
  # It is opened lazily, so a job that never cleans up never starts a clock, and
  # it is memoized in the process that owns the job for the reason the in-flight
  # table is: it is that job's own state, it must be reachable from every step of
  # the sequence without being threaded through the six functions between them,
  # and a VM-global name would collide between two executors in one VM.
  # `execute_new/4` closes the previous job's episode before it opens anything.
  defp cleanup_until do
    case Process.get(:loopex_cleanup_episode) do
      nil ->
        until = cleanup_now_ms() + cleanup_grace_ms()
        Process.put(:loopex_cleanup_episode, until)
        until

      until ->
        until
    end
  end

  # `nil` where no cleanup has been needed, which is what lets receipt retention
  # distinguish the ordinary run-bound path from the separate post-cleanup
  # reserve.
  defp cleanup_episode, do: Process.get(:loopex_cleanup_episode)

  defp close_cleanup_episode, do: Process.delete(:loopex_cleanup_episode)

  # Concept: one settlement gets one retention allowance, opened once and spent
  # down by every phase that follows.
  #
  # Technical depth: ADR 0016 gives receipt preparation, optional artifact
  # retention, publication, lease-loss handoff, sync recovery, and open-entry
  # removal one monotonic deadline that no phase refreshes. Each phase derived a
  # new wait instead: artifact retention took whatever remained of the run,
  # receipt retention took a fresh committed quarter, and the lease-lost
  # replacement took another quarter after that -- so a settlement could run for
  # the sum of its phases while its receipt declared one bound, which is the
  # thing the comment on `settle_receipt/4` already claimed was impossible.
  #
  # The allowance is the committed quarter the receipt declares, and the instant
  # is opened lazily by the first phase that needs it, so a settlement that
  # retains nothing starts no clock. It is memoized in the process that owns the
  # job for the reason the cleanup episode is: it is that job's own state, every
  # phase must reach it without being threaded through the functions between
  # them, and a VM-global name would collide between two executors in one VM.
  defp retention_until do
    case Process.get(:loopex_retention_episode) do
      nil ->
        until = cleanup_now_ms() + receipt_reserve_ms(cleanup_grace_ms())
        Process.put(:loopex_retention_episode, until)
        until

      until ->
        until
    end
  end

  defp retention_remaining, do: cleanup_remaining(retention_until())

  defp close_retention_episode, do: Process.delete(:loopex_retention_episode)

  defp cleanup_grace_ms,
    do: Process.get(:loopex_cleanup_grace_ms, Executor.default_cleanup_grace_ms())

  defp process_probe,
    do: Process.get(:loopex_process_probe, @default_process_probe)

  defp cancellation_episode(grace, probe),
    do: {cleanup_now_ms() + grace, grace, probe}

  # Concept: everything one cleanup episode needs, carried rather than looked up.
  #
  # Technical depth: the period and the probe were read from this process's
  # dictionary inside each function of the termination sequence. That is right
  # inside this server and wrong in `cancel/2`, which deliberately runs in its
  # caller so it is not queued behind the job it is ending -- and the caller's
  # dictionary holds neither value. A cancellation therefore computed its
  # cooperative share from the compiled-in default rather than from the period
  # the host configured: an executor composed with five hundred milliseconds gave
  # a cancellation a two-and-a-half second cooperative window, and one composed
  # with thirty seconds gave it two and a half. Carrying the episode makes both
  # paths read the value in exactly one place.
  defp job_episode do
    {cleanup_until(), cleanup_grace_ms(), process_probe()}
  end

  # Concept: the reserve a receipt gets is the retention bound that receipt
  # declares, and there is one formula for it.
  #
  # Technical depth: ADR 0016 gives core `max(1, ceil(grace_ms / 4))` and
  # `Executor.cancellation_bounds/1` is where it lives. This was a second local
  # derivation by integer division, and the two disagreed below four
  # milliseconds: a committed period of three declared one millisecond of
  # retention in every receipt and reserved zero for it, so the lease-lost
  # retention path was handed a budget that had already expired. Reading the one
  # formula removes the disagreement rather than restating it correctly twice.
  # The match is deliberate: the committed period was admitted before this
  # executor started, so a period the bounds refuse cannot reach here.
  defp receipt_reserve_ms(grace) do
    {:ok, bounds} = Executor.cancellation_bounds(grace)
    bounds.receipt_retention_ms
  end

  defp cleanup_remaining(until), do: max(until - cleanup_now_ms(), 0)
  # Concept: a cleanup budget is a length of time, and a length of time is not
  # measured with a clock somebody can set.
  #
  # Technical depth: every instant in the cleanup domain -- the episode a job
  # opens, the cancellation's own episode, and the cooperative share inside both
  # -- is created here and consumed only through `cleanup_remaining/1`, so the
  # domain is closed and can use a base of its own. On the wall clock it could
  # not: an operator, an NTP step, or a container resuming from a snapshot moves
  # `System.system_time/1` while a group is being terminated, and a five-second
  # grace becomes five seconds plus however far the clock moved. Monotonic time
  # is unaffected by all three.
  #
  # The run's committed deadline is deliberately *not* in this domain. It is a
  # durable semantic field of the job that other processes and later runs read,
  # so it stays an absolute wall-clock instant and is compared against
  # `System.system_time/1` everywhere it appears.
  defp cleanup_now_ms, do: System.monotonic_time(:millisecond)

  @doc """
  ## Concept

  Reads a terminal receipt retained by this executor.

  ## Technical depth

  Reads through the serialized owner, which validates the on-disk job binding
  before returning plain data.
  """
  @spec receipt(t(), binary()) :: {:ok, map()} | :absent | {:error, term()}
  def receipt(executor, job_id) when is_pid(executor) and is_binary(job_id),
    do: GenServer.call(executor, {:receipt, job_id})

  @doc """
  ## Concept

  The executor port's optional retained-receipt lookup, answered by `receipt/2`.

  ## Technical depth

  Named distinctly from `receipt/2` on the port because that generic name was
  already in use as an unrelated helper on more than one executor module, and a
  callback a module implements by accident is called with arguments it never
  meant to accept.
  """
  @impl Loopex.Executor
  @spec retained_receipt(t(), binary()) :: {:ok, map()} | :absent | {:error, term()}
  def retained_receipt(executor, job_id), do: receipt(executor, job_id)

  @doc false
  @spec stats(t()) :: map()
  def stats(executor) when is_pid(executor), do: GenServer.call(executor, :stats)

  @doc false
  @spec tool(binary()) :: {:ok, map()} | :error
  def tool(@write_tool),
    do: {:ok, %{id: @write_tool, version: @tool_version, effect_class: "workspace_write"}}

  def tool(@wait_write_tool),
    do: {:ok, %{id: @wait_write_tool, version: @tool_version, effect_class: "workspace_write"}}

  # Concept: the four coding tools an operator actually uses.
  #
  # Technical depth: routed here beside the two demonstration tools rather than
  # replacing them. M1's inherited executor and recovery cases still resolve the
  # demonstrations, and the registry must prove it resolves a generation outside
  # any active profile; deleting them to tidy up would break proved protection to
  # save two clauses.
  def tool(id) do
    case Enum.find(CodingTools.definitions(), &(&1["tool_id"] == id)) do
      nil ->
        :error

      definition ->
        {:ok,
         %{
           id: id,
           version: definition["tool_version"],
           effect_class: definition["effect_class"],
           coding: definition
         }}
    end
  end

  @impl GenServer
  def init(options) do
    identity = Keyword.fetch!(options, :identity)
    epoch = Keyword.fetch!(options, :epoch)
    fencing_token = Keyword.fetch!(options, :fencing_token)
    leases = Keyword.fetch!(options, :workspace_leases)
    ledger_root = Keyword.fetch!(options, :ledger_root) |> Path.expand()
    artifacts = Keyword.get(options, :artifacts)

    cleanup_grace_ms =
      Keyword.get(options, :cleanup_grace_ms, Executor.default_cleanup_grace_ms())

    process_probe = Keyword.get(options, :process_probe, @default_process_probe)

    # Concept: one paired sample of both clocks, from one place a case can
    # substitute.
    #
    # Technical depth: ADR 0016 requires the wall and monotonic instants used to
    # derive a job's effect-action deadline to come from one sample, so the two
    # cannot be taken either side of a scheduling gap. This is a reversible edge
    # seam and enters no job, ledger record, receipt, event, or public API.
    clock_provider = Keyword.get(options, :clock_provider, &paired_now/0)

    valid =
      is_binary(identity) and byte_size(identity) > 0 and is_integer(epoch) and epoch >= 0 and
        is_integer(fencing_token) and fencing_token >= 0 and is_map(leases) and
        is_integer(cleanup_grace_ms) and cleanup_grace_ms >= 0 and
        is_binary(process_probe) and String.starts_with?(process_probe, "/") and
        not String.contains?(process_probe, <<0>>) and is_function(clock_provider, 0) and
        Enum.all?(leases, fn {id, pid} -> is_binary(id) and is_pid(pid) end)

    with true <- valid,
         {:ok, ledger} <-
           Ledger.prepare(ledger_root, identity, max(cleanup_grace_ms, 1)) do
      # Concept: the configured period is kept where the code that cleans up can
      # read it, including the code that runs outside this server.
      #
      # Technical depth: `cancel/2` deliberately runs in its caller rather than in
      # this server, because this server is blocked for the duration of the job
      # being cancelled -- so it cannot ask for the period through a call it would
      # queue behind that job. It reads it from this process's dictionary exactly
      # as it already reads the in-flight table, and for the same reason: state
      # this process owns, read without waiting for it to be free, and never under
      # a VM-global name that two executors in one VM would collide on.
      Process.put(:loopex_cleanup_grace_ms, cleanup_grace_ms)
      Process.put(:loopex_process_probe, process_probe)

      # Concept: the in-flight table belongs to this executor, not to whichever
      # caller happened to start the first job.
      #
      # Technical depth: `cancel/2` finds the table through this process's
      # dictionary, so it has to be this process's table and it has to outlive any
      # one job. It used to be created lazily by whoever ran the first effect,
      # which was this server only because this server ran every effect. Creating
      # it here makes that independent of where the work runs, and the table is
      # public so a caller performing an effect can register the group it owns.
      table = inflight_table()
      :ets.insert(table, {@ledger_authority_key, ledger})

      {:ok,
       %{
         identity: identity,
         epoch: epoch,
         fencing_token: fencing_token,
         leases: leases,
         ledger_root: ledger_root,
         ledger: ledger,
         clock: clock_provider,
         artifacts: artifacts,
         cleanup_grace_ms: cleanup_grace_ms,
         process_probe: process_probe,
         inflight_table: table,
         reserved: %{},
         dispatches: %{}
       }}
    else
      {:error, reason} -> {:stop, reason}
      _other -> {:stop, :invalid_executor_configuration}
    end
  end

  # Concept: unresolved open authority on this root quarantines new effects, and
  # the root is shared, so the answer is the index as it is now.
  #
  # Technical depth: the caller already holds the root-wide claim, so the index is
  # read as one complete bounded snapshot: no entry can appear or vanish while the
  # decision is being made, and the decision is fixed before the claim is
  # released. An entry that is present, valid, and unresolved means some effect
  # was admitted and never settled: new effects are refused with reconciliation
  # required. Malformed truth, capacity, or an unreadable snapshot are
  # ledger-unavailable, which is a different fact and must not be reported as the
  # reconcilable one.
  #
  # This used to be read once in `init/1` and cached. Every Local sharing one
  # prepared root shares its open index and its refusal truth, so a verdict frozen
  # at start-up was wrong in both directions: a peer instance that stranded an
  # open entry never stopped an already running executor, and an operator who
  # reconciled a root could not make a running executor admit again without
  # restarting it. A held claim was worse still, because a peer holding the claim
  # for the length of one admission quarantined this instance for its whole life.
  #
  # `resolved` is the exact set of open entries that are not evidence of anything
  # unresolved: the request being decided, whose own entry means it is already
  # admitted and must be joined rather than refused, and every job this instance
  # currently holds reserved, whose entry means work in flight here. Reading a
  # live entry as an abandoned one would make a root unusable the moment it
  # carried two concurrent jobs, and would refuse the second instance of the pair
  # that ADR 0016 requires to join a single operation. Everything else is a peer's
  # authority this instance cannot resolve, and that is exactly what quarantines.
  defp reconcile(ledger, resolved) do
    case Ledger.open_snapshot(ledger) do
      {:ok, entries} ->
        case Enum.reject(entries, &(&1["job_id"] in resolved)) do
          [] -> nil
          unresolved -> {:reconciliation_required, length(unresolved)}
        end

      {:error, reason} ->
        reason
    end
  end

  defp paired_now,
    do: {System.system_time(:millisecond), System.monotonic_time(:millisecond)}

  @impl GenServer
  # Concept: a job this instance is still running has no receipt yet, and
  # saying so is different from saying there is none.
  #
  # Technical depth: `:absent` is what ends a recovered run `outcome_unknown`,
  # so a lookup that arrives while the job is reserved here answers
  # `effect_in_flight` instead. The reservation table is this server's own
  # state, read without waiting on the job, which runs in its caller.
  def handle_call({:receipt, job_id}, _from, state) do
    if Map.has_key?(state.reserved, job_id),
      do: {:reply, {:error, :effect_in_flight}, state},
      else: {:reply, read_receipt(state.ledger_root, job_id), state}
  end

  def handle_call(:stats, _from, state),
    do: {:reply, %{dispatches: state.dispatches}, state}

  def handle_call(:cleanup_grace_ms, _from, state),
    do: {:reply, state.cleanup_grace_ms, state}

  def handle_call(:process_probe, _from, state),
    do: {:reply, state.process_probe, state}

  # Concept: the one serialized decision, and nothing else.
  #
  # Technical depth: a quarantined root refuses everything; a retained receipt
  # for this exact request is replayed and a conflicting one refuses; anything
  # else is reserved to the caller, which then owns the waiting. The reservation
  # records who holds the job so `stats/1` and the release below describe live
  # work rather than work this server is performing.
  def handle_call({:reserve, job}, {caller, _tag}, state) do
    job_id = Map.get(job, :job_id, "")

    case reserve_decision(state, job, job_id) do
      :reserve ->
        {:reply, {:ok, placement(state)},
         %{state | reserved: Map.put(state.reserved, job_id, caller)}}

      answer ->
        {:reply, answer, state}
    end
  end

  # Concept: this decision combines the root's open authority with its terminal
  # truth, so it takes the root-wide claim and reads both while mutation is
  # excluded.
  #
  # Technical depth: ADR 0016 requires exactly that of every decision joining an
  # open entry to a terminal, and requires that no later unlocked read become its
  # authority. The open index and the receipt were previously read apart: the
  # index once at start-up and cached forever, the receipt here with nothing
  # excluding a peer that was admitting or refusing the same job at that instant.
  # Both now happen inside one claim, and the answer is fixed before it is
  # released. The cost is one directory creation and one bounded snapshot per
  # reservation; the claim is waited for rather than refused outright, because a
  # peer holding it for the length of its own admission is ordinary contention and
  # not unavailability.
  defp reserve_decision(state, job, job_id) do
    Ledger.with_claim(
      state.ledger,
      fn ->
        case reconcile(state.ledger, resolved_jobs(state, job_id)) do
          nil -> settled_or_reserved(state, job, job_id)
          quarantine -> {:error, quarantine}
        end
      end,
      claim_wait(job)
    )
  end

  defp resolved_jobs(state, job_id),
    do: MapSet.new([job_id | Map.keys(state.reserved)])

  defp settled_or_reserved(state, job, job_id) do
    case read_receipt(state.ledger_root, job_id) do
      {:ok, receipt} ->
        if Map.get(receipt, :canonical_request_digest) ==
             Map.get(job, :canonical_request_digest),
           do: {:retained, receipt},
           else: {:error, :job_id_conflict}

      :absent ->
        :reserve

      {:error, reason} ->
        {:error, reason}
    end
  end

  # A claim is waited for out of the requester's own remaining allowance, never
  # past it, and never past the ceiling one contended root is worth. A request
  # that has not yet been validated may not carry a deadline at all, and its
  # missing member is not an argument for waiting longer than the ceiling.
  defp claim_wait(job) do
    case Map.get(job, :effective_job_deadline) do
      deadline when is_integer(deadline) ->
        min(max(deadline - System.system_time(:millisecond), 0), @claim_wait_ms)

      _absent ->
        @claim_wait_ms
    end
  end

  # Concept: what a caller needs to perform one reserved job, and nothing this
  # server needs to stay the authority.
  #
  # Technical depth: identity, epoch, fence, leases, ledger root and authority,
  # clock, artifact store, configured period and probe, plus the in-flight table
  # and this server's own pid. The reservation map and the dispatch counts stay
  # here, because they are facts about the executor rather than about the job. It
  # carries the same member names the serialized state used, so every function
  # below reads one shape whichever process it runs in.
  defp placement(state) do
    state
    |> Map.drop([:reserved, :dispatches])
    |> Map.put(:executor, self())
  end

  @impl GenServer
  def handle_cast({:release, job_id}, state),
    do: {:noreply, %{state | reserved: Map.delete(state.reserved, job_id)}}

  # Concept: a job is counted as dispatched once it has been durably admitted,
  # never merely because someone asked for it.
  #
  # Technical depth: the count is the executor's own evidence of what it let
  # start, so a pre-effect refusal must leave it untouched. The caller reports
  # admission from the process that obtained it, and message order from that one
  # caller keeps the count settled before any answer that reads it.
  def handle_cast({:admitted, job_id}, state) do
    {:noreply, update_in(state.dispatches, &Map.update(&1, job_id, 1, fn count -> count + 1 end))}
  end

  # Concept: a message that arrives after the job it belongs to is over is
  # dropped, not treated as a fault.
  #
  # Technical depth: an abandoned filesystem worker can answer in the instant
  # after it was killed, and a terminated tool child's port still reports its
  # exit status. Both belong to work this server has already reported on. Without
  # this clause the default implementation logs each one as an unexpected
  # message, which turns a bounded abandonment into noise in an operator's log.
  @impl GenServer
  def handle_info(_message, state), do: {:noreply, state}

  @impl GenServer
  def format_status(status) do
    status
    |> Map.put(:state, :redacted_local_executor_state)
    |> Map.put(:message, :redacted_local_executor_message)
    |> Map.put(:reason, :redacted_local_executor_reason)
    |> Map.put(:log, [])
  end

  # Concept: this function is the one final serialized authority boundary.
  #
  # Technical depth: mutation evidence names this mechanism
  # `executor_final_prestart_validation`. No Port is opened before it has
  # independently validated job bytes, tool metadata, live lease, fence,
  # audience, expiry, and all ten grant bindings.
  defp final_prestart_validation(state, job, grant) do
    with :ok <- Executor.validate_job(job),
         {:ok, tool} <- resolve_tool(job),
         {:ok, lease_pid} <- Map.fetch(state.leases, job.workspace_lease),
         true <- Process.alive?(lease_pid),
         {:ok, lease} <- WorkspaceLease.resolve(lease_pid, job.workspace_lease),
         true <- lease.fencing_token == state.fencing_token,
         :ok <-
           Executor.validate_grant(job, grant, %{
             executor_identity: state.identity,
             workspace_lease: lease.id,
             fencing_token: state.fencing_token,
             now: System.system_time(:millisecond)
           }),
         true <- job.executor_identity == state.identity,
         true <- job.origin_executor_epoch == state.epoch,
         {:ok, arguments} <- validate_arguments(tool, job.validated_arguments) do
      {:ok, tool, lease_pid, lease.path, arguments}
    else
      :error -> refused_before_effect(:workspace_lease_not_held)
      false -> refused_before_effect(:executor_prestart_mismatch)
      {:error, reason} -> refused_before_effect(reason)
    end
  end

  # Concept: an answer this executor gives before it has started anything says so
  # in the answer itself.
  #
  # Technical depth: this was once a separate `refused_before_effect?/1` callback
  # the coordinator called back into after receiving an answer. Two things were
  # wrong with that. It widened a port ADR 0009 fixes at `execute/4` to
  # `execute/5` and nothing else, for a fact that fits inside the `term()` an
  # `{:error, term()}` already carries. And it made the coordinator run a
  # host-supplied module's code inside its own process while a run was in flight,
  # so an implementation that blocked in the callback blocked the coordinator's
  # deadline and its operator's abort along with it.
  #
  # Carrying the proof in the result costs an executor one wrapper and costs a
  # caller a pattern match. An executor that returns a bare `{:error, reason}`
  # has claimed nothing, and everything it returns is unproven -- which is the
  # right reading of an implementation that never told anyone when its effect
  # started.
  #
  # Every one of these is produced by `final_prestart_validation/3` and by
  # nothing else in this module, which is what makes the claim traceable to a
  # line rather than to a name. The post-effect answers --
  # `{:receipt_not_retained, _}`, `{:receipt_read_failed, _}`,
  # `:invalid_retained_receipt` and `:job_id_conflict` -- are deliberately
  # unwrapped: each of them is this executor saying an effect ran and its account
  # of it is gone.
  #
  # `:workspace_lease_lost` and `:workspace_lease_mismatch` are wrapped for this
  # executor and for no other reason. They reach `execute/5` only from
  # `WorkspaceLease.resolve/2` inside the pre-start validation; a lease lost while
  # a tool is running is never reported as an error at all, but as a retained
  # receipt whose own outcome is `:outcome_unknown`. An executor built
  # differently would answer differently, which is exactly why the answer is
  # given here rather than assumed by a caller.
  defp refused_before_effect(reason), do: {:error, {:refused_before_effect, reason}}

  # Concept: one place owns the lease for one job, and it owns it from before the
  # effect starts until after the receipt is on disk.
  #
  # Technical depth: the monitor used to be installed and released inside
  # `run_tool/7`, which ends where the receipt is *built*. Retention ran after
  # that with the DOWN already flushed, so a lease that died while the receipt
  # was being written was not merely undetected -- the evidence of it had been
  # thrown away. Installing the monitor here and releasing it in `after` makes
  # the monitored interval exactly the job lifetime ADR 0007 names, and every
  # blocking step inside it is a wait that carries the DOWN rather than a gap
  # between two samples of the mailbox.
  # Concept: everything a reserved job does, done where the caller can be
  # interrupted and the executor cannot be blocked.
  #
  # Technical depth: the job-scoped values the cleanup sequence reads from a
  # process dictionary are installed here for the duration of this job and
  # removed afterwards, because that sequence now runs in the caller. They are
  # this job's own state, reachable from every step without being threaded
  # through the functions between them, and they are never VM-global names two
  # executors in one VM could collide on. The effect owner stays the executor:
  # a launch-owned guard watches the process whose authority admitted the work,
  # so losing that authority still ends the captured group.
  defp run_reserved(placement, job, grant, options, progress) do
    Process.put(:loopex_cleanup_grace_ms, job_cleanup_grace_ms(placement, job))
    Process.put(:loopex_process_probe, placement.process_probe)
    Process.put(:loopex_inflight_table, placement.inflight_table)
    Process.put(:loopex_effect_owner, placement.executor)
    close_cleanup_episode()
    close_retention_episode()

    try do
      case final_prestart_validation(placement, job, grant) do
        {:ok, tool, lease_pid, workspace, arguments} ->
          admitted_execute(
            placement,
            job,
            tool,
            lease_pid,
            workspace,
            arguments,
            options,
            progress
          )

        {:error, {:refused_before_effect, reason}} ->
          publish_refusal(placement, job, reason)
          {:error, {:refused_before_effect, reason}}
      end
    after
      close_cleanup_episode()
      close_retention_episode()
      Process.delete(:loopex_cleanup_grace_ms)
      Process.delete(:loopex_process_probe)
      Process.delete(:loopex_inflight_table)
      Process.delete(:loopex_effect_owner)
    end
  end

  # Concept: every cleanup and retention window this job spends is derived from
  # the period the job's own request committed.
  #
  # Technical depth: ADR 0016 carries the committed session value on every
  # canonical `JobRequest`, uses it for the job being cancelled, and leaves this
  # executor's start option as a default for new work that names none. Installing
  # the start option here made the cleanup episode, the cooperative share, and
  # the retention reserve spend one number while the receipt reported another --
  # an executor started with twenty seconds gave a job committing four hundred
  # milliseconds a ten-second cooperative window. The start default therefore
  # stands for exactly one case: a request whose own validation has not run yet
  # and may carry no admissible value. Such a request is refused before any
  # effect and spends no cleanup window at all, so no job ever runs under it.
  defp job_cleanup_grace_ms(placement, job) do
    case Map.get(job, :cleanup_grace_ms) do
      grace when is_integer(grace) and grace >= 1 and grace <= @max_uint64 -> grace
      _uncommitted -> placement.cleanup_grace_ms
    end
  end

  # Concept: nothing runs until this root has durably said that this exact
  # request was admitted.
  #
  # Technical depth: the marker and open entry are published and parent-synced
  # under the root-wide claim, and only then does the effect start. A second
  # executor sharing the root cannot observe an admissible gap: it either sees no
  # marker and takes the claim itself, or sees this one and joins the single
  # operation. `observed_at_ms` is the wall half of the one paired sample taken
  # here and is carried to terminal construction rather than resampled, so the
  # receipt reports when the effect was admitted and not when it finished.
  defp admitted_execute(placement, job, tool, lease_pid, workspace, arguments, options, progress) do
    case admit(placement, job) do
      {:ok, admission} ->
        GenServer.cast(placement.executor, {:admitted, job.job_id})
        lease = {Process.monitor(lease_pid), lease_pid}
        Process.put(:loopex_admission, admission)

        try do
          receipt =
            run_tool(placement, job, tool, workspace, arguments, options, lease, progress)

          settle_receipt(placement, job, receipt, lease)
        after
          Process.delete(:loopex_admission)
          Process.demonitor(elem(lease, 0), [:flush])
        end

      :join ->
        join_admitted_operation(placement, job)

      {:error, {:refused_before_effect, _reason} = refusal} ->
        {:error, refusal}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Concept: the receipt, its retention, and the removal of this job's open
  # authority spend one allowance, and no phase refreshes it.
  #
  # Technical depth: the allowance is the committed cleanup period's own quarter,
  # which is also the value the receipt reports, and it is opened by the first
  # retention phase this settlement performs rather than here -- an artifact
  # spill is a phase of the same settlement and draws on the same instant, so the
  # sequence is bounded by that one value rather than by the sum of its parts.
  # What reaches this phase is therefore what the earlier ones left. Open
  # authority is removed only
  # for a receipt whose captured-group cleanup is confirmed; an `outcome_unknown`
  # whose cleanup is unconfirmed deliberately leaves the entry, and therefore
  # quarantines the root until an operator reconciles it.
  defp settle_receipt(placement, job, receipt, lease) do
    bound = retention_remaining()

    case retain_receipt_under_lease(placement.ledger_root, receipt, lease, bound) do
      {:ok, retained} ->
        close_settled_authority(placement, job, retained, lease)

      {:error, reason} ->
        {:error, {:receipt_not_retained, reason}}
    end
  end

  # Concept: removing this job's open authority is part of settling it, so a
  # removal that did not happen is part of the answer.
  #
  # Technical depth: the removal's result was discarded. A claim this instance
  # could not take, an unreadable root, or a failed unlink therefore returned a
  # receipt asserting confirmed cleanup while the entry it names quarantines
  # every later effect on that root -- success to this caller and reconciliation
  # required for everyone else. ADR 0016 removes an entry only under exact
  # authority proof and otherwise leaves the root quarantined, so the truthful
  # receipt for a job whose authority is still open reports an unconfirmed
  # cleanup beside `outcome_unknown`. That is the one pairing the ADR admits, it
  # is what stops a coordinator retrying an effectful job blindly, and it is what
  # tells an operator there is something on this root to reconcile.
  defp close_settled_authority(placement, job, receipt, lease) do
    if receipt.cleanup_confirmation == :confirmed do
      case remove_open_authority(placement, job, lease) do
        :ok -> {:ok, receipt}
        _unremoved -> retain_quarantined(placement, receipt, lease)
      end
    else
      {:ok, receipt}
    end
  end

  # Concept: the removal is a phase of one settlement, so it spends what that
  # settlement has left rather than nothing and rather than however long the
  # filesystem takes.
  #
  # Technical depth: ADR 0016 clause 6 gives receipt preparation, artifact
  # retention, publication, lease-loss handoff, sync recovery and open-entry
  # removal one monotonic deadline that no phase refreshes, and this phase was
  # outside it in both directions. It took the root claim with a zero wait, so a
  # peer holding the claim for one admission quarantined a root that a moment of
  # waiting would have cleared; and `File.rm/1` and the parent sync inside the
  # claim ran inline with no bound at all, so a ledger that never answers held
  # the job for as long as it liked while the receipt already declared the bound
  # its whole settlement received. The allowance is now carried into both: it is
  # the claim's wait, and it is the hard stop on the work done under the claim.
  #
  # An exhausted allowance is the same answer as a failed unlink, because it is
  # the same fact -- this executor did not prove the entry gone. A worker killed
  # at the bound while it held the claim leaves that claim behind, which is
  # bounded unavailability the ADR already admits and which the quarantined
  # receipt is exactly the warning about; reaping it would turn a timeout into
  # permission.
  defp remove_open_authority(placement, job, lease) do
    bound = removal_bound()

    removal =
      bounded_work(
        fn ->
          Ledger.with_claim(
            placement.ledger,
            fn -> Ledger.close_open(placement.ledger, job.job_id) end,
            bound
          )
        end,
        bound,
        lease
      )

    case removal do
      {:done, result} ->
        result

      {:abandoned, _cause, _stopped, {:late, :ok}} ->
        :ok

      {:stopped, reason} ->
        {:error, {:ledger_unavailable, {:open_authority_removal_stopped, reason}}}

      {:abandoned, cause, _stopped, _unfinished} ->
        {:error, {:ledger_unavailable, cause}}
    end
  end

  # Concept: the removal takes a share of what the settlement has left, so that
  # clearing the root can never starve writing down what happened.
  #
  # Technical depth: this is the reason `@retention_spill_share` exists for the
  # artifact phase, arriving at the phase after it. Handing the removal the whole
  # remainder makes a held claim spend every millisecond the receipt still needed:
  # the quarantined replacement would then be written against an allowance of
  # zero and abandoned, and exactly the job whose durable record matters most --
  # one whose root nothing has resolved -- would produce none. A share is not a
  # number for the same reason the cooperative one is not: it cannot drift away
  # from the declared period.
  @removal_share 2

  defp removal_bound, do: div(retention_remaining(), @removal_share)

  # The replacement names no ledger reason. Which claim, path, or errno refused
  # is this executor's private root authority, and a receipt is one of the planes
  # ADR 0016 keeps it out of; what the reader needs is that this root holds work
  # nothing has resolved.
  defp retain_quarantined(placement, receipt, lease) do
    quarantined = %{
      receipt
      | outcome: :outcome_unknown,
        cleanup_confirmation: :unconfirmed,
        output: receipt.output <> @open_authority_note
    }

    case retain_now(placement.ledger_root, quarantined, lease) do
      {:ok, retained} -> {:ok, retained}
      {:error, reason} -> {:error, {:receipt_not_retained, reason}}
    end
  end

  # Concept: one serialized decision about whether this exact request may begin.
  #
  # Technical depth: the claim orders admission against another executor's
  # admission, against a refusal, and against a peer's reconciliation read. Inside
  # it the two independent fences are checked against one paired clock sample: the
  # wall instant against the job's immutable `effective_job_deadline`, and the
  # derived monotonic action deadline under checked arithmetic. A sample that
  # cannot produce a finite action deadline is unavailable authority, never
  # permission.
  defp admit(state, job) do
    Ledger.with_claim(
      state.ledger,
      fn ->
        case Ledger.read_marker(state.ledger, job.job_id) do
          :absent ->
            open_admission(state, job)

          {:ok, record} ->
            cond do
              record["canonical_request_digest"] != job.canonical_request_digest ->
                {:error, :job_id_conflict}

              Map.get(record, :ledger_kind) == Ledger.refusal_kind() ->
                {:error, {:refused_before_effect, refusal_reason(record)}}

              true ->
                :join
            end

          {:error, reason} ->
            {:error, reason}
        end
      end,
      claim_wait(job)
    )
  end

  # Concept: the deadline is derived from one sample, and the permit is decided
  # by another taken immediately before it.
  #
  # Technical depth: the first paired sample fixes the private monotonic action
  # deadline for this job and is never taken again. The second is the last
  # effect-authorizing transition before publication, and it rechecks both fences
  # independently: current wall time must precede the job's immutable
  # `effective_job_deadline`, and current monotonic time must precede the derived
  # action deadline. A backward wall jump between the two therefore cannot extend
  # authority past the monotonic fence, and a forward one expires it by wall
  # truth. Both checks precede the marker, so a job refused here has no admission
  # to withdraw.
  defp open_admission(state, job) do
    with {:ok, wall, monotonic} <- sample(state),
         {:ok, action} <- derive_action_deadline(wall, monotonic, job),
         :ok <- authorize_effect(state, job, action),
         :ok <-
           Ledger.admit(
             state.ledger,
             Ledger.marker(job),
             Ledger.open_entry(job, state.identity)
           ) do
      {:ok, %{wall: wall, monotonic: monotonic, action: action, observed_at_ms: wall}}
    else
      {:error, {:refused_before_effect, reason}} ->
        publish_refusal(state, job, reason, :claim_held)
        {:error, {:refused_before_effect, reason}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp authorize_effect(state, job, action) do
    with {:ok, wall, monotonic} <- sample(state) do
      if wall < job.effective_job_deadline and monotonic < action,
        do: :ok,
        else: {:error, {:refused_before_effect, :effective_deadline_reached}}
    end
  end

  defp derive_action_deadline(wall, monotonic, job) do
    if wall < job.effective_job_deadline,
      do: checked_add(monotonic, job.effective_job_deadline - wall),
      else: {:error, {:refused_before_effect, :effective_deadline_reached}}
  end

  # Concept: a clock that answers with something other than a pair of instants
  # has told this executor nothing it may act on.
  #
  # Technical depth: the monotonic half is deliberately not required to be
  # nonnegative -- the VM's monotonic origin is normally negative -- so only the
  # shape is checked here and the magnitude is checked by the arithmetic that
  # uses it.
  defp sample(state) do
    case state.clock.() do
      {wall, monotonic} when is_integer(wall) and is_integer(monotonic) ->
        {:ok, wall, monotonic}

      _unusable ->
        {:error, {:refused_before_effect, :effect_start_authority_unavailable}}
    end
  end

  # Checked, never wrapping: a monotonic instant plus a remaining wall duration
  # must stay inside the admitted unsigned 64-bit range, or this job has no
  # action deadline this executor can enforce and no effect may begin.
  defp checked_add(monotonic, remaining) do
    sum = monotonic + remaining

    if remaining >= 0 and sum <= @max_uint64,
      do: {:ok, sum},
      else: {:error, {:refused_before_effect, :effect_start_authority_unavailable}}
  end

  # Concept: a request naming a live admission joins that one operation and
  # returns its receipt; it never starts a second effect.
  #
  # Technical depth: the wait polls because the operation belongs to another
  # process, possibly in another VM, and there is no message to wait on. It is
  # bounded by the job's own immutable wall deadline, and reaching that bound is
  # an unresolved join rather than a verdict about the effect.
  defp join_admitted_operation(state, job) do
    if System.system_time(:millisecond) >= job.effective_job_deadline do
      {:error, :effect_join_unresolved}
    else
      case read_receipt(state.ledger_root, job.job_id) do
        {:ok, receipt} ->
          {:ok, receipt}

        :absent ->
          Process.sleep(@join_poll_ms)
          join_admitted_operation(state, job)

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # Concept: a refusal is durable before it is reported, so "no effect began" is
  # a fact on the root rather than a claim in one process's memory.
  #
  # Technical depth: a refusal replaces exactly the marker path it names, which
  # is how a pre-marker deadline records the refusal without inventing an
  # admission. A reason outside the sixteen admitted codes is not journaled: a
  # record no reader can interpret is not proof of anything, and the caller still
  # receives its truthful pre-effect answer.
  defp publish_refusal(state, job, reason, claim \\ :take_claim) do
    {code, field} =
      case reason do
        {code, field} when is_atom(code) -> {code, field}
        code -> {code, nil}
      end

    case durable_refusal(job, code, field) do
      {:ok, refusal} when claim == :claim_held ->
        Ledger.refuse(state.ledger, refusal)

      {:ok, refusal} ->
        Ledger.with_claim(state.ledger, fn -> Ledger.refuse(state.ledger, refusal) end)

      :error ->
        :ok
    end
  rescue
    _malformed_job -> :ok
  end

  # Concept: a refusal binds the exact request it refused, so a request whose own
  # identity could not be validated has no refusal to bind.
  #
  # Technical depth: `invalid_job_request` and `canonical_job_request_mismatch`
  # are precisely the two codes reached because the digest presented cannot be
  # trusted. Journaling one under that digest would publish an authority record
  # naming bytes nobody validated, and would then conflict with the truthful
  # request that follows under the same identity. The caller still receives its
  # exact pre-effect answer; what is withheld is the durable claim.
  defp durable_refusal(_job, code, _field)
       when code in [:invalid_job_request, :canonical_job_request_mismatch],
       do: :error

  defp durable_refusal(job, code, field), do: Ledger.refusal(job, code, field)

  defp refusal_reason(record) do
    case record["reason"] do
      %{"code" => code, "field" => nil} -> String.to_existing_atom(code)
      %{"code" => code, "field" => field} -> {String.to_existing_atom(code), field}
      _malformed -> :effect_start_authority_unavailable
    end
  rescue
    ArgumentError -> :effect_start_authority_unavailable
  end

  defp resolve_tool(job) do
    case tool(job.tool_id) do
      {:ok, %{version: version, effect_class: effect_class} = found}
      when version == job.tool_version and effect_class == job.effect_class ->
        {:ok, found}

      _other ->
        {:error, :tool_definition_mismatch}
    end
  end

  defp validate_arguments(%{id: @write_tool}, arguments),
    do: write_arguments(arguments, 0)

  defp validate_arguments(%{id: @wait_write_tool}, %{
         "relative_path" => path,
         "content" => content,
         "delay_ms" => delay
       })
       when is_integer(delay) and delay in 1..30_000,
       do: write_arguments(%{"relative_path" => path, "content" => content}, delay)

  defp validate_arguments(%{coding: %{"tool_id" => "loopex.read"}}, %{"path" => path})
       when is_binary(path),
       do: {:ok, %{kind: :read, path: path}}

  defp validate_arguments(%{coding: %{"tool_id" => "loopex.write"}}, %{
         "path" => path,
         "content" => content
       })
       when is_binary(path) and is_binary(content),
       do: {:ok, %{kind: :write, path: path, content: content}}

  defp validate_arguments(%{coding: %{"tool_id" => "loopex.edit"}}, %{
         "path" => path,
         "old" => old,
         "new" => new
       })
       when is_binary(path) and is_binary(old) and is_binary(new),
       do: {:ok, %{kind: :edit, path: path, old: old, new: new}}

  # Concept: argv and a raw shell command are two operations, not one with a
  # convenience.
  #
  # Technical depth: an argv vector is passed through without a shell, so no
  # character in an argument is interpreted; a raw command asks for a shell and
  # gets one. Accepting both at once would leave a caller unable to say which
  # they meant, so supplying both is refused.
  defp validate_arguments(%{coding: %{"tool_id" => "loopex.bash"}}, arguments)
       when is_map(arguments) do
    argv = Map.get(arguments, "argv")
    command = Map.get(arguments, "command")

    cond do
      is_list(argv) and Enum.all?(argv, &is_binary/1) and argv != [] and is_nil(command) ->
        {:ok, %{kind: :bash, argv: argv}}

      is_binary(command) and command != "" and is_nil(argv) ->
        {:ok, %{kind: :bash, command: command}}

      true ->
        {:error, :invalid_tool_arguments}
    end
  end

  defp validate_arguments(_tool, _arguments), do: {:error, :invalid_tool_arguments}

  defp write_arguments(%{"relative_path" => path, "content" => content}, delay)
       when is_binary(path) and is_binary(content) and byte_size(content) <= 65_536 do
    safe =
      byte_size(path) in 1..255 and path not in [".", ".."] and
        Path.basename(path) == path and not String.contains?(path, <<0>>)

    if safe,
      do: {:ok, %{path: path, content: content, delay_ms: delay}},
      else: {:error, :invalid_tool_arguments}
  end

  defp write_arguments(_arguments, _delay), do: {:error, :invalid_tool_arguments}

  # Concept: every wait a coding tool sits in carries the lease's death as one of
  # its alternatives.
  #
  # Technical depth: ADR 0007 requires the workspace lease held for the job's
  # full lifetime. The monitor belongs to `execute_new/4`, which owns that whole
  # lifetime; this function only threads it into the waits the tool performs, so
  # stopping the lease while a `loopex.bash` child runs, while a filesystem
  # effect blocks, or while a spilled artifact is being stored is a message this
  # executor is already sitting in.
  # Concept: the instant this job is bounded at is decided once, before the work
  # starts, and every later reader is handed that same value.
  #
  # Technical depth: the receipt used to recompute it by calling
  # `effective_deadline/2` again after the tool had finished. `min(run_deadline,
  # now + budget)` is a function of *now*, so recomputing it later moved it later
  # by however long the job took: a one-second command under a two-minute budget
  # reported an instant roughly a hundred and twenty-one seconds after it began.
  # The effect was bounded correctly and the durable record of that bound was
  # false, which is worse than not recording it -- an operator reconciling a
  # stopped job reads a deadline the run never had.
  defp run_tool(
         state,
         job,
         %{coding: _definition} = tool,
         workspace,
         arguments,
         options,
         lease,
         progress
       ) do
    deadline = effective_deadline(job, tool)
    limits = effective_output_limits(job, tool)

    {tool_result, progress_count} =
      run_coding_tool(
        job,
        tool,
        workspace,
        arguments,
        options,
        lease,
        fence(state, deadline),
        limits,
        progress,
        progress_identity(state, job)
      )

    {outcome, output, artifacts} =
      spill(tool_result, state, job, lease, limits)

    receipt(
      state,
      job,
      tool,
      outcome,
      output,
      coding_tool_environment(arguments),
      artifacts,
      deadline,
      progress_count
    )
  end

  defp run_tool(
         state,
         job,
         tool,
         workspace,
         arguments,
         options,
         {monitor, lease_pid},
         _progress
       ) do
    args = launcher_arguments(arguments)
    deadline = effective_deadline(job, tool)
    fence = fence(state, deadline)

    port = open_launcher("/usr/bin/env", args, demonstration_environment(), workspace)

    # Concept: a cancellation must be able to reach this job too.
    #
    # Technical depth: this path captures no process group, so it registers the
    # process holding the Port rather than a group identifier. That is the whole
    # of what it can offer: `cancel/2` reaches the holder, the Port is released,
    # and the answer is `unconfirmed`, because releasing a handle is not proof
    # that the child stopped. Registering nothing at all was worse -- an absent
    # entry reads as "no such job", which answers `cleaned` for work that was
    # still running.
    register_inflight(job.job_id, {:starting, self()})

    notify(options, {:executor_process_started, job.job_id, tool.id, [@search_path_name]})
    {outcome, output} = await_port(port, monitor, lease_pid, <<>>, fence)
    forget_inflight(job.job_id)

    receipt(state, job, tool, outcome, output, demonstration_environment(), [], deadline, 0)
  end

  defp progress_identity(state, job) do
    %{
      protocol_version: job.protocol_version,
      job_id: job.job_id,
      operation_id: job.operation_id,
      attempt: job.attempt,
      session_id: job.session_id,
      run_id: job.run_id,
      turn_id: job.turn_id,
      tool_call_id: job.tool_call_id,
      canonical_request_digest: job.canonical_request_digest,
      session_epoch_at_dispatch: job.origin_session_epoch,
      executor_epoch: state.epoch,
      executor_identity: state.identity,
      fencing_token: state.fencing_token
    }
  end

  # Concept: the lease is honoured until the receipt is durable, not until it is
  # built.
  #
  # Technical depth: ADR 0007 requires the lease held for the job's full
  # lifetime, and the amended obligation names the end of that lifetime as the
  # point the receipt exists. A receipt that exists only as a term in this
  # server's heap is not one any operator or recovering coordinator can ever
  # read, so the lifetime ends where the bytes land rather than where the map is
  # assembled.
  #
  # The previous shape checked the mailbox once with `after 0` and then
  # demonitor-flushed, before the receipt was constructed and long before it was
  # written. A point-in-time peek answers "has the lease died yet", which is not
  # the question the obligation asks: it is a claim about an interval, so every
  # blocking step in that interval has to be a wait that names the DOWN. The
  # write is therefore done in a monitored worker for exactly the reason the
  # artifact store's `put/3` is -- `File.open/2`, `IO.binwrite/2` and
  # `:file.sync/1` are unbounded on a network, saturated or failing ledger, and
  # calling them inline would make the holder unwatchable for as long as they
  # take.
  #
  # The peek that remains is not the guarantee; it is the cheap branch for a DOWN
  # that has already arrived, which lets this executor write the truthful receipt
  # once rather than write a false one and then replace it.
  defp retain_receipt_under_lease(root, receipt, {monitor, lease_pid} = lease, bound) do
    receive do
      {:DOWN, ^monitor, :process, ^lease_pid, _reason} ->
        retain_now(root, unproven_receipt(receipt), lease)
    after
      0 -> stage_and_commit(root, receipt, lease, bound)
    end
  end

  defp stage_and_commit(root, receipt, lease, bound) do
    staging = staging_path(root, receipt)

    case bounded_work(fn -> retain_receipt(root, receipt, staging) end, bound, lease) do
      {:done, :ok} ->
        {:ok, receipt}

      {:done, {:error, reason}} ->
        {:error, reason}

      {:stopped, reason} ->
        File.rm(staging)
        {:error, {:receipt_retention_stopped, reason}}

      {:abandoned, :workspace_lease_lost, stopped, _late} ->
        abandon_retention(root, receipt, staging, stopped, lease)

      {:abandoned, :bound_reached, stopped, late} ->
        abandon_retention_at_bound(receipt, staging, stopped, late)
    end
  end

  # Concept: the run ran out of time while its receipt was being written, and
  # what that costs is knowledge of the bytes rather than knowledge of the
  # effect.
  #
  # Technical depth: the effect is exactly as proved as the receipt already says
  # it is -- a deadline bounds how long this executor may keep working, not what
  # the tool did -- so nothing here weakens the outcome. What is genuinely
  # unknown is whether the receipt is durable: only `File.rename/2` makes it
  # readable, and the writer is killed somewhere in `File.open/2`,
  # `IO.binwrite/2`, `:file.sync/1` or that rename.
  #
  # A late answer saying the rename completed is admitted, because the bytes are
  # then on disk and reporting otherwise would be false. Otherwise a writer
  # confirmed stopped left a staging file and no receipt, which is removed; a
  # writer that could not be confirmed stopped may still rename after this
  # returns, so its staging file is left where it is and which bytes are durable
  # is unknown either way.
  #
  # No replacement receipt is written here. The operation that just exceeded its
  # bound is not made safe by being run a second time, and the caller's
  # `{:receipt_not_retained, reason}` already says the one true thing.
  defp abandon_retention_at_bound(receipt, _staging, _stopped, {:late, :ok}), do: {:ok, receipt}

  defp abandon_retention_at_bound(_receipt, staging, stopped, _unfinished) do
    if stopped, do: File.rm(staging)
    {:error, :receipt_retention_abandoned_at_run_deadline}
  end

  # Concept: work this executor did not write and cannot bound is done where it
  # can be abandoned, and the abandonment is confirmed rather than assumed.
  #
  # Technical depth: a filesystem effect blocks in the operating system, a spilled
  # artifact is handed to a host-supplied store, and a receipt is written through
  # the local file layer. None of the three answers within any interval this
  # executor can state, and each used to sit in its own near-identical wait --
  # which is how two of them ended up with the lease as their only alternative
  # and no bound at all, while the third had both. One mechanism is what keeps
  # them from drifting apart again: a monitored unlinked worker, four
  # alternatives, and a confirmed kill.
  #
  # The result is delivered as a message tagged with a fresh reference rather
  # than as an exit reason, so a large value is not copied twice. A late answer
  # is drained after an abandonment because a result produced in the instant
  # before the kill would otherwise be left in this server's mailbox, and it is
  # returned rather than discarded because for the receipt it is the difference
  # between bytes that reached the ledger and bytes that did not.
  #
  # It is exposed for the reason `group_answered_empty?/1` is. No case can make a
  # healthy local ledger take longer than the run's remaining time plus the
  # declared grace, so the branch deciding whether a receipt is reported durable
  # would otherwise rest on a wait nothing can reach.
  @doc false
  @spec bounded_work((-> term()), non_neg_integer(), {reference(), pid()}) ::
          {:done, term()}
          | {:stopped, term()}
          | {:abandoned, :workspace_lease_lost | :bound_reached, boolean(),
             :none | {:late, term()}}
  def bounded_work(work, bound, {monitor, lease_pid})
      when is_function(work, 0) and is_integer(bound) and bound >= 0 do
    parent = self()
    tag = make_ref()

    {worker, reference} = spawn_monitor(fn -> send(parent, {tag, work.()}) end)

    await_bounded_work(
      worker,
      reference,
      tag,
      monitor,
      lease_pid,
      System.monotonic_time(:millisecond) + bound
    )
  end

  # Concept: one allowance, spent in slices, refreshed by nothing.
  #
  # Technical depth: an admitted cleanup period spans the whole positive unsigned
  # 64-bit range, and a `receive ... after` above the VM's timer ceiling raises
  # rather than waiting. Each slice recomputes what remains against the same
  # monotonic instant, so slicing changes how the wait is implemented and not how
  # long it is; no slice extends the allowance the caller was given.
  defp await_bounded_work(worker, reference, tag, monitor, lease_pid, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^tag, result} ->
        Process.demonitor(reference, [:flush])
        {:done, result}

      {:DOWN, ^reference, :process, ^worker, reason} ->
        {:stopped, reason}

      {:DOWN, ^monitor, :process, ^lease_pid, _reason} ->
        abandon_worker(:workspace_lease_lost, worker, reference, tag)
    after
      min(remaining, @timer_slice_ms) ->
        if System.monotonic_time(:millisecond) >= deadline,
          do: abandon_worker(:bound_reached, worker, reference, tag),
          else: await_bounded_work(worker, reference, tag, monitor, lease_pid, deadline)
    end
  end

  defp abandon_worker(cause, worker, reference, tag) do
    Process.exit(worker, :kill)

    stopped =
      receive do
        {:DOWN, ^reference, :process, ^worker, _reason} -> true
      after
        @abandon_confirmation_ms -> false
      end

    if not stopped, do: Process.demonitor(reference, [:flush])

    late =
      receive do
        {^tag, result} -> {:late, result}
      after
        0 -> :none
      end

    {:abandoned, cause, stopped, late}
  end

  # Concept: a lease lost while the receipt was being written leaves the effect
  # itself unproven, and the receipt has to say so.
  #
  # Technical depth: that the effect ran is not in doubt; everything the receipt
  # asserts about it is. The claim that authorised those effects is gone, another
  # holder may already own the workspace, and this executor can no longer prove
  # that what it wrote is what is there. A `completed` receipt would assert a
  # proved effect in a workspace this executor has no claim on, and it would be
  # durable -- the one plane a coordinator trusts on recovery. `:outcome_unknown`
  # is the honest terminal fact and is what stops the coordinator blindly
  # retrying an effectful job.
  #
  # The abandoned writer is killed and *confirmed* dead before the replacement is
  # written, because both write the same job's receipt and only ordering decides
  # which bytes survive. Where it cannot be confirmed stopped its rename may
  # still land after this one, so which receipt is durable is genuinely unknown;
  # saying the receipt was not retained is honest, and claiming an outcome for
  # bytes this executor cannot vouch for is not.
  defp abandon_retention(root, receipt, staging, stopped, lease) do
    if stopped do
      File.rm(staging)
      retain_now(root, unproven_receipt(receipt), lease)
    else
      {:error, :workspace_lease_lost_during_retention}
    end
  end

  defp unproven_receipt(receipt),
    do: %{receipt | outcome: :outcome_unknown, output: receipt.output <> @lease_lost_note}

  # The replacement receipt is written the same way the first attempt was.
  # Writing it inline would put the last unbounded call in the job exactly where
  # the lease is already gone and nothing is left to notice a ledger that never
  # answers. It gets what remains of this settlement's one retention allowance
  # rather than a second copy of it: it is a later phase of the same settlement,
  # and ADR 0016 lets no phase refresh that deadline.
  defp retain_now(root, receipt, lease) do
    staging = staging_path(root, receipt)

    case bounded_work(
           fn -> retain_receipt(root, receipt, staging) end,
           retention_remaining(),
           lease
         ) do
      {:done, :ok} -> {:ok, receipt}
      {:done, {:error, reason}} -> {:error, reason}
      {:stopped, reason} -> {:error, {:receipt_retention_stopped, reason}}
      {:abandoned, _cause, _stopped, {:late, :ok}} -> {:ok, receipt}
      {:abandoned, _cause, _stopped, _unfinished} -> {:error, :receipt_retention_abandoned}
    end
  end

  # Concept: the three filesystem tools start no child, so they hold no
  # environment; `bash` holds the one this executor constructed.
  #
  # Technical depth: reporting `PATH` for a tool that never spawned anything
  # would be as untrue as reporting the wrong one for a tool that did. A tool
  # with no child reports no environment names, which is what happened.
  defp coding_tool_environment(%{kind: :bash}), do: child_environment()
  defp coding_tool_environment(_arguments), do: []

  # Concept: the three filesystem tools do not need a process, so they do not
  # start one.
  #
  # Technical depth: spawning a shell to read a file would put an operating
  # system process, a signal path, and a termination story between the operator
  # and a `File.read`. `bash` is the tool that genuinely needs a child, and it is
  # the only one that gets one.
  # Concept: a filesystem tool is bounded by the same instant a shell tool is,
  # and it is bounded while it runs rather than only before it starts.
  #
  # Technical depth: the deadline used to be compared against the clock once and
  # then handed to a synchronous `File.*` call that nothing could interrupt, so a
  # tool that blocked after that comparison ran for as long as it liked and still
  # reported `:completed`. A `loopex.read` of an in-workspace named pipe with a
  # 200 ms run deadline stayed blocked past 500 ms and completed only when an
  # external writer released it. The effect now runs in a separate process this
  # one monitors, so the deadline and a lost lease are both waits this executor
  # is sitting in rather than events it cannot observe.
  #
  # The pre-start comparison is kept: a run whose deadline has already passed
  # should not begin an effect at all, and starting one only to abandon it a
  # moment later would be a worse way to say the same thing.
  defp run_coding_tool(
         _job,
         _tool,
         workspace,
         %{kind: kind} = arguments,
         _options,
         lease,
         deadline,
         limits,
         _progress,
         _identity
       )
       when kind in [:read, :write, :edit] do
    remaining = fence_remaining(deadline)

    if remaining <= 0 do
      {{:failed, "the effective deadline passed before this tool began"}, 0}
    else
      {run_bounded_tool(workspace, arguments, remaining, lease, limits), 0}
    end
  end

  defp run_coding_tool(
         job,
         tool,
         workspace,
         %{kind: :bash} = arguments,
         options,
         lease,
         deadline,
         limits,
         progress,
         identity
       ) do
    run_owned_process(
      job,
      tool,
      workspace,
      arguments,
      options,
      lease,
      deadline,
      limits,
      progress,
      identity
    )
  end

  # Concept: the effect runs where it can be abandoned, and the abandonment is
  # confirmed rather than assumed.
  #
  # Technical depth: the worker is spawned unlinked and monitored, so neither its
  # crash nor its kill can reach this executor. Whichever of the four outcomes
  # arrives first decides the result: the effect's own answer, the worker dying
  # on its own, the lease holder going down, or the remaining deadline elapsing.
  #
  # The mechanics of the wait live in `bounded_work/3`, which the two retentions
  # that follow the effect use as well.
  defp run_bounded_tool(workspace, arguments, remaining, lease, limits) do
    case bounded_work(
           fn -> filesystem_effect(workspace, arguments, limits) end,
           remaining,
           lease
         ) do
      {:done, result} ->
        result

      {:stopped, reason} ->
        {:failed, "the tool stopped before it produced a result: #{inspect(reason)}"}

      {:abandoned, :workspace_lease_lost, stopped, _late} ->
        abandoned(:workspace_lease_lost, arguments, stopped)

      {:abandoned, :bound_reached, stopped, _late} ->
        abandoned(:deadline, arguments, stopped)
    end
  end

  # Concept: an abandoned effect reports what is actually known about it, which
  # is usually less than a verdict.
  #
  # Technical depth: `:completed` and `:failed` are both claims. A `read` that was
  # stopped changed nothing and produced nothing, so `:failed` is exactly true. A
  # `write` or an `edit` stopped part way may or may not have reached the file,
  # and a lease that vanished mid-flight means the workspace the effect was
  # authorised against is no longer this executor's to inspect -- in both cases
  # the effect is unproven, which is what `:outcome_unknown` says and what stops
  # the coordinator from blindly retrying it.
  #
  # A worker that does not die is the same kind of fact as a process group that
  # cannot be confirmed cleaned: it may still act, so nothing about the effect is
  # known regardless of which tool it was.
  defp abandoned(cause, arguments, stopped) do
    {abandoned_outcome(cause, arguments, stopped), abandoned_message(cause, arguments, stopped)}
  end

  defp abandoned_outcome(_cause, _arguments, false), do: :outcome_unknown
  defp abandoned_outcome(:workspace_lease_lost, _arguments, true), do: :outcome_unknown
  defp abandoned_outcome(:deadline, %{kind: :read}, true), do: :failed
  defp abandoned_outcome(:deadline, _arguments, true), do: :outcome_unknown

  defp abandoned_message(cause, arguments, stopped) do
    cause_text =
      case cause do
        :deadline -> "the effective deadline passed while this tool was running"
        :workspace_lease_lost -> "the workspace lease was lost while this tool was running"
      end

    stop_text =
      if stopped,
        do: " and it was stopped.",
        else: " and it could not be confirmed stopped."

    "[loopex: " <> cause_text <> stop_text <> " " <> effect_text(cause, arguments, stopped) <> "]"
  end

  defp effect_text(:deadline, %{kind: :read}, true), do: "Nothing was read."

  defp effect_text(_cause, %{kind: kind}, _stopped),
    do: "Whether #{kind} changed the workspace is unproven."

  defp filesystem_effect(workspace, %{kind: :read, path: path}, limits) do
    with {:ok, resolved} <- CodingTools.resolve(workspace, path),
         {:ok, identity} <- ordinary_file(resolved, path, :required),
         :ok <- within_artifact_ceiling(identity, limits.artifact),
         {:ok, content} <- read_verified(resolved, path, identity, limits.artifact) do
      case CodingTools.bound_output(content, limits.output) do
        {:complete, bounded} -> {:completed, bounded, :complete}
        {:truncated, kept, full} -> {:completed, kept, {:truncated, full}}
      end
    else
      {:artifact_ceiling_exceeded, observed} ->
        {:failed,
         "read failed: the file is #{observed} bytes, exceeding the tool's declared " <>
           "artifact ceiling of #{limits.artifact} bytes"}

      {:refused, message} ->
        {:failed, message}

      {:error, reason} when is_atom(reason) ->
        {:failed, "read failed: #{:file.format_error(reason)}"}

      {:error, reason} ->
        {:failed, containment_message(reason)}
    end
  end

  defp filesystem_effect(workspace, %{kind: :write, path: path, content: content}, _limits) do
    with {:ok, root} <- CodingTools.resolve(workspace, "."),
         {:ok, resolved} <- CodingTools.resolve(workspace, path),
         {:ok, _identity} <- ordinary_file(resolved, path, :optional),
         :ok <- ensure_directories(root, Path.dirname(resolved), path),
         :ok <- replace_atomically(resolved, content) do
      {:completed, "wrote #{byte_size(content)} bytes to #{path}"}
    else
      {:refused, message} ->
        {:failed, message}

      {:error, reason} when is_atom(reason) ->
        {:failed, "write failed: #{:file.format_error(reason)}"}

      {:error, reason} ->
        {:failed, containment_message(reason)}
    end
  end

  # Concept: an edit that cannot be made says what it found instead, and an edit
  # that can be made commits the same way a write does.
  #
  # Technical depth: a blank failure costs a model a guess and another turn. The
  # diagnostics below distinguish absent from ambiguous, and an absent match
  # reports the nearest line it did find, because "your string is not here" and
  # "your string is here twice" call for different corrections.
  #
  # The write half used to hand `replace_atomically/2` the pathname resolved
  # before the read, with nothing between them but a whole file being read,
  # searched and rewritten. The exclusive create and the rename protect the
  # final component and nothing above it, so an intermediate directory swapped
  # for a link out of the workspace was followed by both: the temporary was
  # created outside and renamed onto a name that had come to mean an outside
  # file. A loop alternating one in-workspace directory between a real directory
  # holding the target and a symlink to an outside directory modified the outside
  # target on attempt 11 against a three megabyte file.
  #
  # `ensure_directories/3` is the check `write` already makes, and running it
  # here is what makes the two tools one mechanism -- read, verify, transform,
  # confirm every level is a directory rather than a link, then replace the name
  # atomically. It narrows the window to the same one `write` documents rather
  # than closing it, for the reason stated there: nothing available here can pin
  # a directory between the confirmation and the next syscall.
  defp filesystem_effect(workspace, %{kind: :edit} = arguments, _limits) do
    %{path: path, old: old, new: new} = arguments

    with {:ok, root} <- CodingTools.resolve(workspace, "."),
         {:ok, resolved} <- CodingTools.resolve(workspace, path),
         {:ok, identity} <- ordinary_file(resolved, path, :required),
         {:ok, content} <- read_verified(resolved, path, identity),
         {:ok, updated} <- replaced_once(content, old, new, path),
         :ok <- ensure_directories(root, Path.dirname(resolved), path),
         :ok <- replace_atomically(resolved, updated) do
      {:completed, "replaced 1 occurrence in #{path}"}
    else
      {:refused, message} ->
        {:failed, message}

      {:failed, _message} = mismatch ->
        mismatch

      {:error, reason} when is_atom(reason) ->
        {:failed, "edit failed: #{:file.format_error(reason)}"}

      {:error, reason} ->
        {:failed, containment_message(reason)}
    end
  end

  defp replaced_once(content, old, new, path) do
    case occurrences(content, old) do
      1 ->
        {:ok, String.replace(content, old, new)}

      0 ->
        {:failed,
         "edit failed: the exact text was not found in #{path}. " <> nearest_hint(content, old)}

      count ->
        {:failed,
         "edit failed: the text appears #{count} times in #{path}. " <>
           "Include more surrounding context so exactly one occurrence matches."}
    end
  end

  # Concept: these tools operate on ordinary files, and a path that is not one is
  # refused before anything is opened.
  #
  # Technical depth: opening a named pipe blocks until the other end is opened,
  # and in this runtime a blocked file open is not a local delay. Measured
  # directly on the supported toolchain, a single outstanding blocked open stalls
  # every subsequent `File.read` in the whole virtual machine -- with nine idle
  # dirty IO schedulers and whether the process that started it is alive or has
  # been killed -- until that open is paired and returns. Abandoning the tool at
  # its deadline keeps the tool's own promise but leaves the syscall outstanding,
  # so every other session sharing the runtime would stay stalled behind a path
  # one model chose. `mkfifo` is reachable from `loopex.bash`, so this is a path
  # a model can actually produce inside its own workspace.
  #
  # Refusing is therefore the bound that matters here, and the deadline above is
  # the bound for an operation that is merely slow: a large regular file returns
  # on its own, so abandoning one costs nothing beyond the work already started.
  # A `write` may legitimately name a path that does not exist yet; a `read` or
  # an `edit` may not.
  #
  # The device and inode are returned as well, because the check answers a
  # question about one file and the caller then acts on a *name*. Carrying the
  # identity forward is what lets the caller ask afterwards whether the name
  # still leads to the same file.
  defp ordinary_file(resolved, path, presence) do
    case File.lstat(resolved) do
      {:ok, %File.Stat{type: :regular} = stat} ->
        {:ok, {stat.major_device, stat.inode, stat.size}}

      {:ok, %File.Stat{type: type}} ->
        {:refused, "refused: #{path} is a #{type}, not a regular file"}

      {:error, :enoent} when presence == :optional ->
        {:ok, :absent}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp within_artifact_ceiling({_device, _inode, size}, limit) when size <= limit, do: :ok

  defp within_artifact_ceiling({_device, _inode, size}, _limit),
    do: {:artifact_ceiling_exceeded, size}

  # Concept: the file that was opened is checked against the file that was
  # contained, and a mismatch is refused rather than read.
  #
  # Technical depth: containment resolves a name and the read then opens that
  # name again, so a component swapped between the two would be followed. The
  # identity recorded at the containment check is compared once the handle
  # exists: if the name now leads to a different device/inode, or to something
  # that is no longer a regular file, nothing is read and the refusal says so.
  #
  # This narrows the window; it does not close it. Erlang's `:file` exposes
  # neither `O_NOFOLLOW` nor `openat`, so there is no way to open a name and
  # prove in one syscall that it is the name that was checked, and no way to
  # re-stat the handle rather than the path. An adversary that swaps the path
  # back before this comparison is still admitted. The honest claim is a smaller
  # window and a truthful refusal when the swap is visible, not containment
  # under a racing filesystem.
  defp read_verified(resolved, path, identity) do
    read_verified(resolved, path, identity, :unbounded_input)
  end

  defp read_verified(resolved, path, identity, artifact_limit) do
    case File.open(resolved, [:read, :binary]) do
      {:ok, file} ->
        try do
          case ordinary_file(resolved, path, :required) do
            {:ok, ^identity} ->
              read_open_file(file, artifact_limit)

            {:ok, _different} ->
              {:refused,
               "refused: #{path} was replaced while it was being opened; nothing was read"}

            other ->
              other
          end
        after
          File.close(file)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Concept: the bounded read of an already-open regular file refuses the first
  # byte beyond its artifact ceiling instead of returning a successful prefix.
  #
  # Technical depth: the production path reaches this boundary only if a file
  # grows after its size was checked but before its opened handle is read.
  # Arranging that interval through the filesystem is inherently racy, so the
  # locked case supplies an already-open handle and a small ceiling here. This
  # `@doc false` probe calls the same private collector and creates no runtime or
  # compatibility contract.
  @doc false
  @spec bounded_read_probe(:file.io_device(), pos_integer()) ::
          {:ok, binary()} | {:artifact_ceiling_exceeded, pos_integer()} | {:error, term()}
  def bounded_read_probe(file, limit) when is_integer(limit) and limit > 0,
    do: read_open_file(file, limit)

  defp read_open_file(file, :unbounded_input), do: read_open_file(file, :eof, nil)

  defp read_open_file(file, limit) when is_integer(limit) and limit > 0,
    do: read_open_file(file, limit + 1, limit)

  defp read_open_file(file, amount, artifact_limit) do
    case IO.binread(file, amount) do
      :eof ->
        {:ok, ""}

      data
      when is_binary(data) and is_integer(artifact_limit) and byte_size(data) > artifact_limit ->
        {:artifact_ceiling_exceeded, byte_size(data)}

      data when is_binary(data) ->
        {:ok, data}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Concept: the directories a write needs are created one level at a time, and a
  # level that is not a directory stops the write instead of being followed.
  #
  # Technical depth: `File.mkdir_p/1` stats each level and is satisfied by a
  # symlink that points at a directory, so a component swapped for a link to
  # somewhere else was silently traversed on the way to the target. Creating each
  # level with `File.mkdir/1` and, on `:eexist`, confirming with `File.lstat/1`
  # that the level is a directory *and not a link* refuses that shape truthfully.
  # It is a narrowing rather than a proof for the same reason as above: nothing
  # here can pin a directory between the confirmation and the next step.
  defp ensure_directories(root, directory, path) do
    cond do
      directory == root ->
        :ok

      not String.starts_with?(directory, root <> "/") ->
        {:error, {:path_escapes_workspace, path}}

      true ->
        directory
        |> String.replace_prefix(root <> "/", "")
        |> Path.split()
        |> Enum.reduce_while({:ok, root}, fn segment, {:ok, current} ->
          next = Path.join(current, segment)

          case create_directory(next, path) do
            :ok -> {:cont, {:ok, next}}
            other -> {:halt, other}
          end
        end)
        |> case do
          {:ok, _directory} -> :ok
          other -> other
        end
    end
  end

  defp create_directory(directory, path) do
    case File.mkdir(directory) do
      :ok ->
        :ok

      {:error, :eexist} ->
        case File.lstat(directory) do
          {:ok, %File.Stat{type: :directory}} ->
            :ok

          {:ok, %File.Stat{type: type}} ->
            {:refused, "refused: #{path} leads through a #{type}, not a directory"}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Concept: the file appears at its name complete or not at all, and creating it
  # cannot be redirected onto something the name did not mean.
  #
  # Technical depth: the write used to be `mkdir_p` on a resolved-but-stale path
  # followed by `File.write/2`, which is a fresh traversal of the same name and a
  # truncating open. A `loopex.bash` loop alternating an in-workspace name
  # between a directory and a symlink to an outside directory landed a
  # model-supplied `loopex.write` outside the workspace on attempt 354 of a
  # 500-attempt probe -- a documented containment guarantee broken by a race a
  # model can drive itself.
  #
  # Two properties replace that. `[:write, :exclusive]` is `O_CREAT|O_EXCL`,
  # which fails with `:eexist` on an existing name *including a symlink*, so the
  # bytes cannot be created through a link that appeared after the check.
  # `:file.rename/2` then replaces the target name itself rather than following
  # it, so a symlink that appeared at the target is overwritten instead of
  # dereferenced, and the file is either the old one or the new one at every
  # instant -- no reader sees a half-written file.
  #
  # The temporary name lives in the same resolved directory because `rename` is
  # only atomic within one filesystem, and it is removed on any failure so a
  # refused write leaves nothing behind.
  defp replace_atomically(resolved, content) do
    temporary =
      Path.join(
        Path.dirname(resolved),
        ".loopex-write-" <>
          Integer.to_string(System.unique_integer([:positive])) <>
          "-" <> Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)
      )

    case :file.open(temporary, [:write, :binary, :exclusive, :raw]) do
      {:ok, file} ->
        result =
          with :ok <- :file.write(file, content),
               :ok <- :file.close(file) do
            :file.rename(temporary, resolved)
          end

        if result != :ok, do: _ = :file.delete(temporary)
        result

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Concept: a command runs as a group this executor owns and can end.
  #
  # Technical depth: the port spawn places the child in a process group of its
  # own before the command runs, and every descendant it spawns joins that group.
  # Termination then signals the negated group id rather than the leader, which
  # is the difference between ending the work and ending the one process that
  # happened to be on top of it. A leader that forks and exits would otherwise
  # leave its children running with nobody's name on them.
  #
  # No later launcher may fork or replace the group identity established by the
  # spawn. The Port, the command, and descendants that remain in the inherited
  # group therefore keep one stable ownership identity from admission through
  # receipt. A descendant can deliberately leave that group; ADR 0009 records
  # that limit. The negated-group kill below is safe *because* the captured group
  # is unconditionally the child's own and never this runtime's.
  #
  # The group id is captured by the child itself and printed on its first line,
  # because the BEAM gives a port's os_pid but not the group the child chose. A
  # captured identity is the only one termination can honestly claim to have
  # confirmed.
  defp run_owned_process(
         job,
         tool,
         workspace,
         arguments,
         options,
         lease,
         deadline,
         limits,
         progress,
         identity
       ) do
    # Concept: the process that owns the operating-system child outlives an
    # abrupt death of the serialized executor long enough to end that child.
    #
    # Technical depth: the GenServer used to own the Port itself. Killing it
    # destroyed the only in-flight table and closed the launcher while a
    # descendant in the captured process group kept running; a later cancel then
    # read the missing table as proof of cleanup. A monitored worker owns the
    # Port instead, watches the executor, and performs the same bounded group
    # termination if that authority disappears. The executor still serializes
    # admission. Its public pid remains the reference.
    #
    # The guarded authority and the process this worker answers are deliberately
    # two different pids now that the effect runs in the caller. The guard is the
    # executor, because that is the authority whose reservation, ledger, and
    # cancellation entry own the child; the answer goes to the caller, because
    # that is who is waiting for it. Collapsing the two sent every result to a
    # process that was not waiting for one.
    guard = effect_owner()
    caller = self()
    tag = make_ref()
    table = inflight_table()
    grace = cleanup_grace_ms()
    probe = process_probe()

    {worker, monitor} =
      spawn_monitor(fn ->
        Process.put(:loopex_inflight_table, table)
        Process.put(:loopex_cleanup_grace_ms, grace)
        Process.put(:loopex_process_probe, probe)
        guard_monitor = Process.monitor(guard)
        send(caller, {tag, :worker_ready, self()})

        receive do
          {^tag, :run} ->
            result =
              run_owned_process_worker(
                job,
                tool,
                workspace,
                arguments,
                options,
                lease,
                deadline,
                limits,
                progress,
                identity,
                {guard_monitor, guard}
              )

            send(caller, {tag, :worker_result, result, not is_nil(cleanup_episode())})

          {:loopex_cancel_pending, token, from, _cancel_grace, _cancel_probe} ->
            forget_inflight(job.job_id)
            send(from, {:loopex_cancel_result, token, {:ok, :cleaned}})

            send(
              caller,
              {tag, :worker_result,
               {{:cancelled, "[loopex: the job was cancelled before its process began.]",
                 :complete}, 0}, false}
            )

          {:DOWN, ^guard_monitor, :process, ^guard, _reason} ->
            :ok
        end
      end)

    receive do
      {^tag, :worker_ready, ^worker} ->
        register_inflight(job.job_id, {:starting, worker})
        send(worker, {tag, :run})
        await_owned_process_worker(worker, monitor, tag, job)

      {:DOWN, ^monitor, :process, ^worker, reason} ->
        forget_inflight(job.job_id)

        {{:outcome_unknown,
          "[loopex: the process owner stopped before it could report cleanup: " <>
            inspect(reason) <> "]", :complete}, 0}
    end
  end

  defp await_owned_process_worker(worker, monitor, tag, job) do
    receive do
      {^tag, :worker_result, result, cleanup_used} ->
        Process.demonitor(monitor, [:flush])
        if cleanup_used, do: Process.put(:loopex_cleanup_episode, cleanup_now_ms())
        result

      {:DOWN, ^monitor, :process, ^worker, reason} ->
        cleanup_worker_failure(job.job_id)

        {{:outcome_unknown,
          "[loopex: the process owner stopped before it could report cleanup: " <>
            inspect(reason) <> "]", :complete}, 0}
    end
  end

  defp cleanup_worker_failure(job_id) do
    case :ets.lookup(inflight_table(), job_id) do
      [{^job_id, group}] when is_integer(group) and group > 1 ->
        terminate_group(group, job_episode())
        _confirmed = confirm_group_terminated(group, job_episode())

      _other ->
        :ok
    end

    forget_inflight(job_id)
  rescue
    ArgumentError -> :ok
  end

  defp run_owned_process_worker(
         job,
         _tool,
         workspace,
         arguments,
         options,
         lease,
         deadline,
         limits,
         progress,
         identity,
         owner
       ) do
    environment = child_environment()
    {launcher, command_arguments} = process_launcher(arguments, environment)

    port = open_launcher(launcher, command_arguments, environment, workspace)

    os_pid = port |> Port.info(:os_pid) |> elem(1)

    notify(
      options,
      {:executor_process_started, job.job_id, job.tool_id, environment_names(environment)}
    )

    register_inflight(job.job_id, os_pid)

    collector = new_output_collector(os_pid, progress, identity)
    {_parent_lease_monitor, lease_pid} = lease
    local_lease = {Process.monitor(lease_pid), lease_pid}

    result =
      case collect_output(
             port,
             deadline,
             collector,
             options,
             job,
             local_lease,
             limits.artifact,
             owner
           ) do
        # Concept: the launcher's exit is the end of one process, not the end of
        # the work this job owns.
        #
        # Technical depth: this branch treated the launcher's status as the whole
        # job's completion, forgot the captured group and dropped the monitor at
        # once. `( sleep 1; printf survived > after-receipt.txt ) & exit 0` reported
        # `:completed` in 22 ms and the descendant then wrote inside the workspace
        # after the receipt existed and after the lease had gone -- an effect
        # attributed to nothing, outside every bound the receipt claimed. Process
        # groups are what this executor owns and cancels; success has to mean the
        # same thing cancellation already means, so the group is brought to
        # quiescence and confirmed before `:completed` is reported. A command that
        # backgrounds work and exits has that work terminated, which is the
        # intended reading of owning the group rather than the leader.
        {:exited, status, output, group, progress_count} ->
          quiescence = quiesce_group(group, job_episode())
          forget_inflight(job.job_id)

          case quiescence do
            :quiescent ->
              {bound_process_output(status, output, "", limits.output), progress_count}

            :terminated ->
              {bound_process_output(status, output, @group_terminated_note, limits.output),
               progress_count}

            :unconfirmed ->
              {unproven(
                 bound_process_output(status, output, @group_unconfirmed_note, limits.output)
               ), progress_count}
          end

        {:artifact_limit_exceeded, output, group, observed, progress_count} ->
          confirmed = confirm_group_terminated(group, job_episode())

          {{if(confirmed, do: :failed, else: :outcome_unknown),
            artifact_ceiling_message(
              output,
              limits.output,
              limits.artifact,
              observed,
              confirmed
            ), :complete}, progress_count}

        {:cancelled, output, group, progress_count} ->
          confirmed = confirm_group_terminated(group, job_episode())

          suffix =
            "\n[loopex: the deadline passed and the command was terminated." <>
              if(confirmed,
                do: " Its process group is confirmed cleaned.]",
                else: " Cleanup could not be confirmed.]"
              )

          {{if(confirmed, do: :cancelled, else: :outcome_unknown),
            bounded_terminal_output(output, suffix, limits.output)}, progress_count}

        {:external_cancelled, output, _group, progress_count, confirmed} ->
          suffix =
            "\n[loopex: cancellation reached the process owner." <>
              if(confirmed,
                do: " Its process group is confirmed cleaned.]",
                else: " Cleanup could not be confirmed.]"
              )

          {{if(confirmed, do: :cancelled, else: :outcome_unknown),
            bounded_terminal_output(output, suffix, limits.output)}, progress_count}

        {:executor_owner_lost, output, _group, progress_count, confirmed} ->
          suffix =
            "\n[loopex: the local executor owner stopped while this command was running." <>
              if(confirmed,
                do:
                  " Its process group was terminated and confirmed cleaned, but no receipt owner remained.]",
                else: " Cleanup could not be confirmed and the effect remains unproven.]"
              )

          {{:outcome_unknown, bounded_terminal_output(output, suffix, limits.output)},
           progress_count}

        # Concept: a command whose lease vanished is unproven, not cancelled.
        #
        # Technical depth: a deadline cancellation happens while this executor
        # still holds the workspace, so it can say the command was stopped inside a
        # workspace that is still its own. A lost lease says the opposite: the
        # claim that authorised these effects is gone, another holder may already
        # have taken the workspace, and whatever the command wrote before the
        # signal reached it is no longer attributable. `:outcome_unknown` is what
        # stops the coordinator from blindly retrying an effectful job in that
        # state, and it is reported whether or not the group was confirmed cleaned
        # -- confirming cleanup proves the command stopped, not that its effect
        # never landed.
        {:workspace_lease_lost, output, group, progress_count} ->
          confirmed = confirm_group_terminated(group, job_episode())

          suffix =
            "\n[loopex: the workspace lease was lost and the command was terminated." <>
              if(confirmed,
                do: " Its process group is confirmed cleaned.",
                else: " Cleanup could not be confirmed."
              ) <>
              " Whether its effect landed in the workspace this job was authorised" <>
              " against is unproven.]"

          {{:outcome_unknown, bounded_terminal_output(output, suffix, limits.output)},
           progress_count}
      end

    Process.demonitor(elem(local_lease, 0), [:flush])
    result
  end

  # Concept: an in-flight job publishes the group it owns, so a cancel can reach
  # it without calling a server that is busy running it.
  #
  # Technical depth: `execute/5` blocks this executor's GenServer for the whole
  # job, so a concurrent `cancel/2` cannot be a call. The table is created per
  # executor process and its identifier is kept in that process's own dictionary
  # rather than under a registered name, because a named table is VM-global and
  # two executors in one VM would collide on it — the same reason nothing else in
  # this project hides per-runtime state in a global name. Reading another
  # process's dictionary is unusual, and it is used here precisely because it
  # reads state that process owns without waiting for it to be free.
  # Concept: the process whose authority admitted the effect is the one a
  # launch-owned guard watches.
  #
  # Technical depth: the guard exists so an operating-system child cannot outlive
  # the authority that started it. That authority is the executor, not the caller
  # that happened to ask: a caller may come and go while the executor's
  # reservation, ledger, and cancellation entry are what the child is owned
  # through. `self()` is the fallback for the one path that has no reservation.
  defp effect_owner, do: Process.get(:loopex_effect_owner, self())

  defp inflight_table do
    case Process.get(:loopex_inflight_table) do
      nil ->
        table = :ets.new(:loopex_inflight, [:public, :set])
        Process.put(:loopex_inflight_table, table)
        table

      table ->
        table
    end
  end

  defp register_inflight(job_id, group) do
    :ets.insert(inflight_table(), {job_id, group})
    :ok
  rescue
    ArgumentError -> :error
  end

  defp forget_inflight(job_id) do
    :ets.delete(inflight_table(), job_id)
    :ok
  rescue
    ArgumentError -> :ok
  end

  # Concept: a command that exited nonzero failed, and the result says with what.
  #
  # Technical depth: this path discarded the exit status and called every finished
  # command `:completed`, so `sh -c 'exit 7'`, a missing file, and an unknown
  # command all reached the model as a success with no output -- indistinguishable
  # from a command that truly succeeded silently. The sibling port path in this
  # module has always returned `{:failed, status}` for the same message, so the
  # two disagreed inside one file; `:failed` is an outcome this executor's other
  # tools already produce and the conversation plane already accepts.
  #
  # The status is appended after bounding rather than before, because a failure
  # whose diagnosis is the first thing truncated away is the defect again in
  # another form. It is appended to the spilled copy too, so the truncation
  # notice's "N of M bytes shown" counts the same bytes on both sides.
  defp bound_process_output(status, output, group_note, output_limit) do
    outcome = if status == 0, do: :completed, else: :failed
    note = exit_note(status) <> group_note
    full = output <> note

    if byte_size(full) <= output_limit do
      {outcome, full, :complete}
    else
      {outcome, bounded_with_suffix(output, note, output_limit), {:truncated, full, note}}
    end
  end

  defp unproven({_outcome, kept, spill}), do: {:outcome_unknown, kept, spill}

  # Concept: a job is over when the group it owns is empty, and that is looked
  # at rather than assumed.
  #
  # Technical depth: the common case costs one `ps` and signals nothing, because
  # a command whose group is already empty needs no termination and must not pay
  # for one. Where members remain, the existing cleanup-and-confirmation sequence
  # runs — the same one the deadline branch uses — and its answer decides between
  # a truthful `:completed` and `:outcome_unknown`.
  #
  # The signal is sent only while a member of the captured group is still
  # present, and the check runs in the instant the launcher's exit is reported,
  # which is what keeps the negated-group kill aimed at this job's own group
  # rather than at a group identifier the operating system has since reissued.
  defp quiesce_group(group, episode) do
    if confirm_group_terminated(group, episode) do
      :quiescent
    else
      terminate_group(group, episode)

      if confirm_group_terminated(group, episode), do: :terminated, else: :unconfirmed
    end
  end

  defp exit_note(0), do: ""

  defp exit_note(status), do: "\n[loopex: the command exited with status #{status}.]"

  # Concept: the effective deadline is the earlier of the run's and the tool's.
  #
  # Technical depth: a tool's own wall-time budget can only make a job end
  # sooner, never later. Taking the minimum is what stops a tool budget from
  # outliving the run that authorised it.
  # Concept: the earlier of the run's committed instant and the tool's own
  # declared wall-time budget.
  #
  # Technical depth: the budget was a literal two minutes, so a tool's declared
  # `wall_time_ms` was never read anywhere in the tree -- it happened to equal
  # `loopex.bash`'s declaration and was wrong for the other three. A definition
  # that declares none falls back to the run's instant alone rather than to a
  # number invented here.
  #
  # This instant bounds every coding tool. For `bash` it bounds a running child;
  # for the other three it is the wait after which the effect is abandoned, so a
  # tool that declares a shorter budget than the run now genuinely ends sooner
  # rather than merely being compared against the clock once and then left to
  # run.
  #
  # The bound is the smallest of the three numbers that claim to hold: the run's
  # own instant, the budget the session declared for this job, and the budget the
  # definition this executor resolved declares. The session's declaration is read
  # because it is the one that was journaled with the effect intent -- the
  # coordinator already declares this job's output ceiling the same way, and a
  # wall-time ceiling invented here alone was a bound no record named and no case
  # could drive without waiting out a shipped thirty-second budget. Taking the
  # minimum rather than the session's number is what keeps it fail-closed: a
  # caller cannot widen a tool's declared budget by declaring a larger one.
  defp effective_deadline(job, tool) do
    case tool_wall_time(tool) do
      nil -> job.effective_job_deadline
      budget -> min(job.effective_job_deadline, System.system_time(:millisecond) + budget)
    end
  end

  # Concept: the two fences a running effect is measured against, derived once
  # from the admission sample and never refreshed.
  #
  # Technical depth: the wall half is the earlier of the job's immutable
  # `effective_job_deadline` and the tool's own declared ceiling. The monotonic
  # half is the admission sample's monotonic instant plus exactly that wall
  # remainder, so a backward wall jump cannot extend authority past the monotonic
  # fence and a forward one expires it by wall truth. No wall instant is ever
  # compared with or added to a monotonic instant.
  defp fence(state, deadline) do
    admission = Process.get(:loopex_admission)

    %{
      wall_deadline: deadline,
      action_deadline: min(admission.action, admission.monotonic + (deadline - admission.wall)),
      clock: state.clock
    }
  end

  # Concept: what remains is the smaller of the two independent fences.
  #
  # Technical depth: one paired sample answers both, so the two halves cannot be
  # taken either side of a scheduling gap and disagree about the same instant.
  # Either fence reaching zero ends the allowance; neither can lengthen it.
  defp fence_remaining(%{wall_deadline: wall_deadline, action_deadline: action, clock: clock}) do
    {wall_now, monotonic_now} = clock.()
    min(wall_deadline - wall_now, action - monotonic_now)
  end

  defp tool_wall_time(%{coding: %{"budgets" => %{"wall_time_ms" => budget}}})
       when is_integer(budget) and budget > 0,
       do: budget

  defp tool_wall_time(_tool), do: nil

  # Concept: output is bounded by every declaration that applies, and artifact
  # retention is bounded by the tool definition that the grant named.
  #
  # Technical depth: the process path used CodingTools' compiled output constant
  # and never read artifact_bytes. That happened to match loopex.bash's shipped
  # output declaration, but a job carrying a smaller committed output ceiling was
  # widened at the hand, and no amount of output could reach an artifact ceiling
  # because none was consulted. The minimum keeps a caller from widening the
  # definition; the definition's artifact ceiling is the maximum complete result
  # this executor may retain in memory or hand to a store.
  defp effective_output_limits(job, %{coding: %{"budgets" => budgets}}) do
    tool_output = positive_budget!(budgets, "output_bytes")
    artifact = positive_budget!(budgets, "artifact_bytes")

    output =
      case job do
        %{resource_budgets: %{"max_output_bytes" => value}}
        when is_integer(value) and value > 0 ->
          min(value, tool_output)

        _other ->
          tool_output
      end

    %{output: output, artifact: artifact}
  end

  defp positive_budget!(budgets, name) do
    case Map.fetch!(budgets, name) do
      value when is_integer(value) and value > 0 -> value
    end
  end

  # Concept: output beyond a tool's bound is retained, not discarded.
  #
  # Technical depth: a bounded tool returned the kept prefix and dropped the
  # rest, so the marker said how many bytes existed and nothing could reach them.
  # The whole output is written to the artifact store and the model is shown the
  # notice naming the reference, which is what makes the bound a truncation
  # rather than a loss.
  #
  # A tool whose output fits spills nothing. Where no artifact store is composed,
  # or the store refuses, the tool keeps the marker it had: an operator loses the
  # retrieval, never the result, and the receipt says truthfully that nothing was
  # retained.
  defp spill({outcome, output}, state, job, lease, limits),
    do: spill({outcome, output, :complete}, state, job, lease, limits)

  defp spill({outcome, output, :complete}, _state, _job, _lease, _limits),
    do: {outcome, output, []}

  defp spill({outcome, _kept, {:truncated, full}}, state, job, lease, limits),
    do: spill_truncated(outcome, full, "", state, job, lease, limits)

  defp spill({outcome, _kept, {:truncated, full, diagnostic}}, state, job, lease, limits),
    do: spill_truncated(outcome, full, diagnostic, state, job, lease, limits)

  defp spill_truncated(outcome, full, diagnostic, state, job, lease, limits) do
    retain_truncated(outcome, full, diagnostic, state, job, lease, limits.output)
  end

  defp retain_truncated(outcome, full, diagnostic, %{artifacts: nil}, _job, _lease, limit) do
    {outcome, bounded_truncation_marker(full, diagnostic, limit), []}
  end

  # Concept: the reason an artifact was retained is the job's own identity, taken
  # whole.
  #
  # Technical depth: ADR 0015 admits exactly these five labels and no others, and
  # every one of them is read from the already validated job rather than accepted
  # a second time from a caller. Two of them were previously omitted and the
  # attempt was absent entirely, so a retained artifact could not say which run
  # or which attempt of an operation produced it — the exact question a
  # reconciliation asks. Retention goes through the Core facade, which normalizes
  # this record and proves the store's answer before any reference can reach the
  # receipt this executor is about to write.
  defp retain_truncated(outcome, full, diagnostic, state, job, lease, limit) do
    metadata = %{
      "role" => "tool_output",
      "media_type" => "text/plain",
      "session_id" => job.session_id,
      "run_id" => job.run_id,
      "operation_id" => job.operation_id,
      "attempt" => job.attempt,
      "tool_call_id" => job.tool_call_id
    }

    {bound, bound_cause} = retention_bound(job)

    case retain_under_lease(state.artifacts, full, metadata, lease, bound) do
      {:ok, reference} ->
        {outcome, bounded_artifact_notice(full, diagnostic, limit, reference), [reference]}

      # Concept: a store that refused, or answered untruthfully, cost the
      # retrieval and nothing else.
      #
      # Technical depth: the tool's own bounded result is exactly what it was, so
      # the outcome does not change. What the model must not be told is that a
      # retrieval exists, so the notice says plainly that nothing beyond the
      # bounded result was retained and the receipt names no artifact. It is kept
      # short for the same reason the artifact notice is: this sentence competes
      # with the model-facing result for a declared ceiling that may be narrow,
      # and half a warning is not one.
      {:error, _reason} ->
        {outcome,
         bounded_truncation_with_extra(
           full,
           diagnostic,
           limit,
           "\n[loopex: retention unavailable; nothing beyond it was retained.]"
         ), []}

      # Concept: this settlement ran out of the time it had for retaining
      # things, and the result it was retaining is untouched by that.
      #
      # Technical depth: the effect produced its bytes and this executor holds
      # them, so the outcome stays exactly what the tool proved. What the
      # abandonment costs is the retrieval: no reference this executor can honour
      # exists, so the model is shown the plain truncation marker and the receipt
      # names no artifact. That is the same loss the store's own refusal causes
      # above, said with the reason that actually applies. The bound reached is
      # the smaller of the run's remaining instant and this settlement's share of
      # its one retention allowance, and the message names the one that ended it.
      :retention_bound_reached ->
        {outcome,
         bounded_truncation_with_extra(full, diagnostic, limit, retention_note(bound_cause)), []}

      :workspace_lease_lost ->
        {:outcome_unknown,
         bounded_truncation_with_extra(
           full,
           diagnostic,
           limit,
           "\n[loopex: the workspace lease was lost while this job's output was being" <>
             " retained, and the retention was abandoned. Whether the effect landed in" <>
             " the workspace this job was authorised against is unproven.]"
         ), []}
    end
  end

  defp retention_note(:run_deadline) do
    "\n[loopex: the run deadline passed while this job's output was being" <>
      " retained, and the retention was abandoned. The result above is what the" <>
      " tool produced; nothing beyond it was retained.]"
  end

  defp retention_note(:retention_allowance) do
    "\n[loopex: this job's settlement ran out of the allowance it had for" <>
      " retaining its output, and the retention was abandoned. The result above" <>
      " is what the tool produced; nothing beyond it was retained.]"
  end

  # Concept: artifact retention is the first phase of one settlement, so it is
  # bounded by what the run has left and by what that settlement has left.
  #
  # Technical depth: spilled-artifact retention had no bound of any kind, and
  # then had the run's remaining instant alone -- which is not a bound this
  # settlement shares with the phases after it. ADR 0016 gives artifact
  # retention, receipt retention, and open-entry removal one monotonic deadline,
  # so a spill into a store that answers slowly cannot spend the receipt's
  # allowance as well as its own; it takes a share of what remains of that one
  # instant. The run's committed instant is still one of the
  # two, and it is the run's rather than the tool's effective deadline because a
  # tool's declared budget bounds the tool and this is the run retaining what the
  # tool produced.
  # The share is what keeps one shared allowance from starving the phase that
  # writes down what happened. A store that answers more slowly than the whole
  # allowance would otherwise leave nothing for the receipt, and exactly the job
  # whose durable record matters most would produce none -- the defect the
  # separate reserve was introduced for, reappearing as the cost of sharing one
  # instant. It is a share rather than a number for the reason the cooperative
  # one is: it cannot drift away from the declared period.
  @retention_spill_share 2

  # Which of the two bound it is carried out, because the two are different
  # facts and an abandoned retention has to say which one ended it.
  defp retention_bound(job) do
    run_remaining = max(job.run_deadline - System.system_time(:millisecond), 0)
    share = div(retention_remaining(), @retention_spill_share)

    if run_remaining <= share,
      do: {run_remaining, :run_deadline},
      else: {share, :retention_allowance}
  end

  # Concept: the receipt says the bound its whole settlement received.
  #
  # Technical depth: the value is the committed quarter ADR 0016 derives from the
  # period this job committed, and it is the allowance every retention phase of
  # this settlement shares rather than the slice one of them happened to get.
  # Recording it makes the guarantee a fact on the durable record rather than an
  # argument about a line.
  #
  # `cleanup_grace_ms` beside it is the process-cleanup period this job
  # committed, which is the period its cleanup actually spent.

  # Concept: retaining output is work the lease still covers and the run still
  # owns, so it is waited on rather than simply called.
  #
  # Technical depth: `put/3` belongs to a host-supplied store and this executor
  # cannot bound it. Calling it inline made the lease unwatchable for as long as
  # it ran, and waiting on the lease alone left the run's committed instant out
  # of the alternatives entirely -- a `loopex.read` with three hundred
  # milliseconds left spilled into a store that delayed four seconds and returned
  # after about four seconds, reporting `completed`. Both are alternatives of the
  # one wait now.
  defp retain_under_lease(store, bytes, metadata, lease, bound) do
    case bounded_work(fn -> Loopex.ArtifactStore.put(store, bytes, metadata) end, bound, lease) do
      {:done, result} -> result
      {:stopped, reason} -> {:error, {:artifact_retention_stopped, reason}}
      {:abandoned, :workspace_lease_lost, _stopped, _late} -> :workspace_lease_lost
      {:abandoned, :bound_reached, _stopped, _late} -> :retention_bound_reached
    end
  end

  # Concept: every process this executor starts explicitly excludes the provider
  # credential, and a model-supplied command receives only the environment this
  # executor constructed.
  #
  # Technical depth: a port opened without `env:` inherits the emulator's whole
  # environment. The demonstration tools were launched through `/usr/bin/env -i`
  # and so received nothing; the coding tools were not, so every `bash` call this
  # milestone added ran with the operator's variables -- the provider credential
  # among them, because the operator must export it for the command to run at
  # all. The receipt then journalled `provider_credential_present: false`, which
  # made the durable record assert an absence that was not true.
  #
  # `env:` extends rather than replaces, and clearing a name is `{name, false}`.
  # The ambient snapshot clears stable names, while the credential is cleared
  # explicitly after that snapshot so the security claim never rests on the
  # snapshot being complete. The downstream `env -i` boundary constructs the
  # exact PATH-only command environment recorded by the receipt.
  # Concept: the demonstration tools construct their environment in argv.
  #
  # Technical depth: `launcher_arguments/1` passes `-i` and one assignment to
  # `/usr/bin/env`, so the child's environment is that one name. It is expressed
  # here in the same shape the coding tools use so one function reports both.
  defp demonstration_environment do
    [{String.to_charlist(@search_path_name), String.to_charlist(@search_path_value)}]
  end

  # Concept: the one place this executor starts a model-supplied command.
  #
  # Technical depth: both spawn sites built their own option list around their
  # own `Port.open`, and a case observed the environment through a third
  # construction of its own. That made the locked observation a statement about
  # the helper rather than about the spawn: deleting `env:` from the production
  # call site alone left every environment case green while the real launcher
  # inherited this operating-system process's whole environment. A guarantee
  # about what that spawned image is loaded with can only be observed at the
  # spawn, so there is exactly one job-launch spawn, and the case drives it.
  #
  # A case enumerates every `Port.open` in this module. That assertion stops the
  # collapse from being undone by adding a second job-launch site or by letting a
  # process-management helper bypass the central credential removal.
  defp open_launcher(launcher, arguments, environment, workspace) do
    open_launcher(launcher, arguments, environment, workspace, fn -> :ok end)
  end

  defp open_launcher(launcher, arguments, environment, workspace, before_open) do
    options = launcher_port_options(environment, workspace)
    before_open.()

    Port.open(
      {:spawn_executable, String.to_charlist(launcher)},
      [args: Enum.map(arguments, &String.to_charlist/1)] ++ options
    )
  end

  # Concept: a real spawn, taken through the production path, whose first image
  # prints the environment it was itself loaded with.
  #
  # Technical depth: nothing downstream of `env -i` can see the first image's own
  # environment -- that is the whole difficulty -- and `ps` does not report a
  # foreign process's environment on every supported platform. `/usr/bin/env`
  # with no arguments at all prints what it was loaded with, so spawning it
  # through `open_launcher/4` with the environment a coding tool gets is a direct
  # reading of the first image, taken through the same function, the same option
  # list and the same `Port.open` a `loopex.bash` job goes through. The only
  # thing this seam chooses is that there is no command after the first image.
  # It is a `@doc false` seam and no part of any contract.
  @doc false
  @spec launcher_probe_port(binary()) :: port()
  def launcher_probe_port(workspace) when is_binary(workspace),
    do: open_launcher("/usr/bin/env", [], child_environment(), workspace)

  @doc false
  @spec launcher_probe_port(binary(), :coding | :demonstration, (-> term())) :: port()
  def launcher_probe_port(workspace, kind, before_open)
      when is_binary(workspace) and kind in [:coding, :demonstration] and
             is_function(before_open, 0) do
    environment =
      case kind do
        :coding -> child_environment()
        :demonstration -> demonstration_environment()
      end

    open_launcher("/usr/bin/env", [], environment, workspace, before_open)
  end

  defp launcher_port_options(environment, workspace) do
    [
      :binary,
      :exit_status,
      :use_stdio,
      :stderr_to_stdout,
      :hide,
      env: spawn_environment(environment),
      cd: String.to_charlist(workspace)
    ]
  end

  # Concept: every first image explicitly excludes the provider credential, and
  # every downstream command receives only what this executor chose.
  #
  # Technical depth: both spawn sites passed no `env:` at all, so `/usr/bin/env`
  # was `execve`d with the emulator's entire environment. Supplying `-i` in its
  # *arguments* clears the environment of the command `env` goes on to run; it
  # cannot clear the environment `env` itself was loaded with, because the loader
  # has already finished by the time `env` parses anything. On a platform whose
  # loader honours an ambient `LD_PRELOAD`, the object it names is mapped into
  # that first process -- and that first process is holding the provider
  # credential, because the operator must export it for the runtime to work at
  # all.
  #
  # A port's `env:` option extends the inherited environment rather than
  # replacing it, and `{name, false}` unsets one name. Clearing every name this
  # operating-system process currently holds and then setting the constructed
  # ones approximates replacement in the only vocabulary the option has. It is
  # not atomic replacement: another process in this VM can add a differently
  # named variable after the snapshot and before the spawn. The provider
  # credential is therefore removed explicitly after the snapshot, whatever the
  # intended environment contains and whenever that key was added.
  #
  # `env -i` in the arguments is kept. It is the exact construction boundary for
  # the downstream command, which receives only the declared `PATH`. M2 makes no
  # broader claim that the first image is atomically empty against concurrent
  # mutation of arbitrary environment names inside this VM.
  defp spawn_environment(environment) do
    cleared = for {name, _value} <- System.get_env(), do: {String.to_charlist(name), false}
    credential = String.to_charlist(@credential_name)

    (cleared ++ environment)
    |> Enum.reject(fn {name, _value} -> name == credential end)
    |> Kernel.++([{credential, false}])
  end

  defp child_environment do
    [
      {String.to_charlist(@search_path_name), String.to_charlist(@search_path_value)},
      {String.to_charlist(@credential_name), false}
    ]
  end

  # Concept: what the receipt reports is the environment intentionally given to
  # the downstream command.
  #
  # Technical depth: the names were a hardcoded list, so the receipt said `PATH`
  # whatever environment was actually declared. Deriving them from the same list
  # passed to the downstream `env -i` boundary makes the journalled claim an
  # exact statement of that construction rather than an OS observation.
  defp environment_names(environment) do
    for {name, value} <- environment, value != false, do: List.to_string(name)
  end

  defp credential_present?(environment) do
    Enum.any?(environment, fn {name, value} ->
      List.to_string(name) == @credential_name and value != false
    end)
  end

  # Concept: argv runs without a shell; a raw command runs in one.
  #
  # Technical depth: for argv the program and its arguments are passed through
  # untouched, so a `$` or a space in an argument is data. For a raw command a
  # shell is asked for explicitly, which is the whole point of that form.
  # Concept: the first image explicitly excludes the provider credential, and
  # the downstream command runs with only the constructed PATH.
  #
  # Technical depth: the launcher used to be `setsid`, resolved from the ambient
  # `PATH`, with `env -i` further along the argument vector. That ordering hands
  # the operator's whole environment -- the provider credential included -- to
  # whatever `setsid` resolved to, before anything is cleared. A workspace that
  # placed an executable named `setsid` earlier on `PATH` would receive it, while
  # the receipt still derived `provider_credential_present: false` from the
  # environment the *downstream* child was going to get.
  #
  # `/usr/bin/env` is an absolute path, so it cannot be substituted, and it is
  # the first thing executed. It clears the environment, sets the one `PATH` this
  # executor chose, and only then resolves the shell or argv command from that
  # PATH rather than the operator's.
  #
  # Concept: the launcher's own arguments are the whole of the boundary, and no
  # process inside the tree can look back at them.
  #
  # Technical depth: every image in this chain replaces the last with `execve`,
  # so the launcher and the shell are one operating-system process and the
  # argument vector the first image was handed no longer exists
  # by the time anything a case can talk to does. The vector is therefore exposed
  # for direct inspection, for the reason `group_answered_empty?/1` is: the rule
  # that decides what runs before the environment is cleared must not rest on a
  # branch nothing can observe. A case places a recorder at the first operand
  # `env` will execute -- the first argument that is neither an option nor a
  # `NAME=VALUE` assignment, which is `env`'s own parsing rule and not a
  # restatement of this vector -- and reads the environment that operand
  # receives. It is a `@doc false` seam and no part of any contract.
  @doc false
  @spec launcher_vector(map()) :: {binary(), [binary()]}
  def launcher_vector(arguments) when is_map(arguments),
    do: process_launcher(arguments, child_environment())

  defp process_launcher(%{argv: [program | rest]}, environment) do
    {"/usr/bin/env",
     env_prefix(environment) ++
       ["sh", "-c", group_preamble() <> "exec \"$0\" \"$@\"", program] ++ rest}
  end

  defp process_launcher(%{command: command}, environment) do
    {"/usr/bin/env", env_prefix(environment) ++ ["sh", "-c", group_preamble() <> command]}
  end

  # Concept: `env -i` builds the environment of the command, which is not the
  # environment of the process that runs `env`.
  #
  # Technical depth: this argument prefix was once described here as the whole
  # boundary, on the reasoning that a port's `env:` option extends the inherited
  # environment rather than replacing it and so could never clear anything. Half
  # of that is right and the conclusion was wrong. `env -i` is the correct
  # construction for the *downstream* command -- it starts from nothing and takes
  # only the assignments that follow, so this executor needs to know only the
  # names worth keeping rather than every name worth removing -- and it is kept
  # for exactly that. It cannot do anything at all about the image the operating
  # system loaded in order to parse it. `/usr/bin/env` is `execve`d with whatever
  # the port gave it, and a loader acts on that process before its first
  # instruction: an ambient `LD_PRELOAD` maps a model-controlled object into the
  # process this executor started, and that process holds the provider
  # credential while it does. `spawn_environment/1` is what closes that, and this
  # prefix now covers only what it can honestly cover.
  #
  # These are the arguments of a `/usr/bin/env` the port has already spawned, so
  # they begin with the clearing option rather than with a path to `env` again.
  # A second executable path here is not a redundant spelling of the same thing:
  # `env` executes its first non-option operand, so naming one made the clearing
  # option an argument of the command rather than an option of the clearing
  # process, and the spawned image ran and then executed a further image with
  # this operating-system process's whole inherited environment -- the provider
  # credential in it -- before anything was cleared. `launcher_arguments/1`, the
  # other spawn site in this module, has always begun with `-i`; this is the same
  # shape.
  defp env_prefix(environment) do
    ["-i"] ++
      for {name, value} <- environment,
          value != false,
          do: List.to_string(name) <> "=" <> List.to_string(value)
  end

  # The child announces the group it actually leads before doing anything else,
  # so termination confirms a group the operating system assigned rather than one
  # this executor assumed.
  defp group_preamble, do: "printf 'loopex-pgid:%s\\n' \"$(ps -o pgid= -p $$ | tr -d ' ')\" >&2; "

  # Concept: command output is accumulated only up to the artifact ceiling that
  # its resolved definition declared.
  #
  # Technical depth: appending `acc <> chunk` made memory grow with whatever the
  # command chose to print, and did quadratic copying on the way. The collector
  # keeps port chunks as reversed iodata, counts only tool output (the private
  # process-group preamble is parsed separately), and accepts no bytes after the
  # artifact ceiling. Crossing it terminates the owned group immediately. The
  # final flatten therefore has a hard upper bound, while ordinary output beneath
  # the ceiling is still byte-identical for artifact spill.
  defp new_output_collector(os_pid, progress, identity) do
    %{
      chunks: [],
      bytes: 0,
      group: os_pid,
      preamble: <<>>,
      progress: %{publish: progress, identity: identity, sequence: 0, byte_offset: 0}
    }
  end

  defp collect_output(port, deadline, collector, options, job, lease, artifact_limit, owner) do
    {monitor, lease_pid} = lease
    {owner_monitor, owner_pid} = owner
    remaining = fence_remaining(deadline)

    if remaining <= 0 do
      {output, group, progress_count} = collected_output(collector, artifact_limit)
      terminate_group(group, job_episode())
      forget_inflight(job.job_id)
      {:cancelled, output, group, progress_count}
    else
      receive do
        {^port, {:data, chunk}} ->
          notify(options, {:executor_progress, job.job_id, byte_size(chunk)})

          case collect_chunk(collector, chunk, artifact_limit) do
            {:ok, next} ->
              register_inflight(job.job_id, next.group)

              collect_output(
                port,
                deadline,
                next,
                options,
                job,
                lease,
                artifact_limit,
                owner
              )

            {:artifact_limit_exceeded, next, observed} ->
              terminate_group(next.group, job_episode())
              forget_inflight(job.job_id)

              {:artifact_limit_exceeded, flatten_chunks(next), next.group, observed,
               progress_count(next)}
          end

        {^port, {:exit_status, status}} ->
          case finish_collector(collector, artifact_limit) do
            {:ok, finished} ->
              {:exited, status, flatten_chunks(finished), finished.group,
               progress_count(finished)}

            {:artifact_limit_exceeded, finished, observed} ->
              terminate_group(finished.group, job_episode())
              forget_inflight(job.job_id)

              {:artifact_limit_exceeded, flatten_chunks(finished), finished.group, observed,
               progress_count(finished)}
          end

        {:DOWN, ^monitor, :process, ^lease_pid, _reason} ->
          {output, group, progress_count} = collected_output(collector, artifact_limit)
          terminate_group(group, job_episode())
          forget_inflight(job.job_id)
          {:workspace_lease_lost, output, group, progress_count}

        {:loopex_cancel_pending, token, caller, grace, probe} ->
          {output, group, progress_count} = collected_output(collector, artifact_limit)
          episode = cancellation_episode(grace, probe)
          terminate_group(group, episode)
          confirmed = confirm_group_terminated(group, episode)
          forget_inflight(job.job_id)

          answer = if confirmed, do: {:ok, :cleaned}, else: {:ok, :unconfirmed}
          send(caller, {:loopex_cancel_result, token, answer})
          {:external_cancelled, output, group, progress_count, confirmed}

        {:DOWN, ^owner_monitor, :process, ^owner_pid, _reason} ->
          {output, group, progress_count} = collected_output(collector, artifact_limit)
          terminate_group(group, job_episode())
          confirmed = confirm_group_terminated(group, job_episode())
          forget_inflight(job.job_id)
          {:executor_owner_lost, output, group, progress_count, confirmed}
      after
        min(remaining, 50) ->
          collect_output(
            port,
            deadline,
            collector,
            options,
            job,
            lease,
            artifact_limit,
            owner
          )
      end
    end
  end

  defp collect_chunk(%{preamble: preamble} = collector, chunk, limit)
       when is_binary(preamble) do
    combined = preamble <> chunk

    case :binary.match(combined, "\n") do
      {newline, 1} ->
        line_size = newline + 1
        line = binary_part(combined, 0, line_size)
        rest = binary_part(combined, line_size, byte_size(combined) - line_size)

        case Regex.run(~r/^loopex-pgid:(\d+)\n$/, line) do
          [_all, group] ->
            collector
            |> Map.put(:preamble, nil)
            |> Map.put(:group, String.to_integer(group))
            |> append_collected(rest, limit)

          nil ->
            collector
            |> Map.put(:preamble, nil)
            |> append_collected(combined, limit)
        end

      :nomatch when byte_size(combined) <= 64 ->
        {:ok, %{collector | preamble: combined}}

      :nomatch ->
        collector
        |> Map.put(:preamble, nil)
        |> append_collected(combined, limit)
    end
  end

  defp collect_chunk(collector, chunk, limit), do: append_collected(collector, chunk, limit)

  defp append_collected(collector, <<>>, _limit), do: {:ok, collector}

  defp append_collected(%{bytes: bytes} = collector, chunk, limit) do
    observed = bytes + byte_size(chunk)
    available = max(limit - bytes, 0)
    kept_size = min(byte_size(chunk), available)

    next =
      if kept_size == 0 do
        collector
      else
        kept = binary_part(chunk, 0, kept_size)

        collector
        |> Map.put(:chunks, [kept | collector.chunks])
        |> Map.put(:bytes, bytes + kept_size)
        |> emit_progress(kept)
      end

    if observed > limit,
      do: {:artifact_limit_exceeded, next, observed},
      else: {:ok, next}
  end

  defp finish_collector(%{preamble: nil} = collector, _limit), do: {:ok, collector}

  defp finish_collector(%{preamble: preamble} = collector, limit) do
    collector = Map.put(collector, :preamble, nil)

    if private_preamble_prefix?(preamble) do
      {:ok, collector}
    else
      append_collected(collector, preamble, limit)
    end
  end

  defp private_preamble_prefix?(bytes) do
    prefix = "loopex-pgid:"
    String.starts_with?(prefix, bytes) or String.starts_with?(bytes, prefix)
  end

  defp collected_output(collector, limit) do
    finished =
      case finish_collector(collector, limit) do
        {:ok, value} -> value
        {:artifact_limit_exceeded, value, _observed} -> value
      end

    {flatten_chunks(finished), finished.group, progress_count(finished)}
  end

  defp flatten_chunks(collector),
    do: collector.chunks |> Enum.reverse() |> IO.iodata_to_binary()

  # Concept: the stream carries exactly the child bytes admitted by the bounded
  # collector, before the terminal receipt exists.
  #
  # Technical depth: the private process-group preamble is removed before this
  # function is reached. Large port packets are split at the executor contract's
  # chunk ceiling, and one state owns both sequence and byte offset so the
  # receipt's `progress_count` is the exact number of callbacks invoked.
  defp emit_progress(collector, <<>>), do: collector

  defp emit_progress(%{progress: progress} = collector, bytes) do
    %{collector | progress: emit_progress_bytes(progress, bytes)}
  end

  defp emit_progress_bytes(progress, <<>>), do: progress

  defp emit_progress_bytes(progress, bytes) do
    size = min(byte_size(bytes), @max_progress_chunk_bytes)
    chunk = binary_part(bytes, 0, size)
    rest = binary_part(bytes, size, byte_size(bytes) - size)

    event =
      Map.merge(progress.identity, %{
        progress_sequence: progress.sequence,
        # The Port deliberately merges stderr into stdout so one offset owns the
        # exact byte order the collector and terminal receipt observed.
        stream: "stdout",
        byte_offset: progress.byte_offset,
        chunk: chunk
      })

    :ok = progress.publish.(event)

    emit_progress_bytes(
      %{progress | sequence: progress.sequence + 1, byte_offset: progress.byte_offset + size},
      rest
    )
  end

  defp progress_count(%{progress: %{sequence: sequence}}), do: sequence

  # Concept: end the group, not the leader.
  #
  # Technical depth: a negative pid names the process group. TERM first so a
  # child can finish a write, then KILL, because a command interrupted mid-write
  # leaves a half-written file the operator has to notice for themselves.
  # `--` is the portable end-of-options boundary for that negative operand.
  # Darwin's `/bin/kill` accepts the operand without it; the `/bin/kill` in the
  # locked Linux lane instead treats the number as an option and returns success
  # without signalling the group, which makes every later cleanup confirmation
  # truthfully fail.
  defp terminate_group(group, {until, _grace, _probe} = episode)
       when is_integer(group) and group > 1 do
    _ = answer_within("/bin/kill", ["-TERM", "--", "-#{group}"], cleanup_remaining(until))

    unless exited_cooperatively?(group, cooperative_episode(episode)) do
      _ = answer_within("/bin/kill", ["-KILL", "--", "-#{group}"], cleanup_remaining(until))
    end

    :ok
  end

  defp terminate_group(_group, _episode), do: :ok

  # Concept: the cooperative grace is a wait for the group to go, not a pause of
  # a length nobody declared.
  #
  # Technical depth: this was `Process.sleep(50)` -- fifty milliseconds between
  # `TERM` and `KILL`, which is not enough for a command to finish the write the
  # `TERM`-first ordering exists to protect, and is not the declared period an
  # operator configured. Looking rather than sleeping makes the common case
  # cheaper as well as the slow case correct: a group that is gone the instant it
  # is signalled costs one `ps` and no `KILL` at all, and a group that ignores
  # the signal is killed the moment its share of the budget runs out rather than
  # fifty milliseconds in.
  defp cooperative_episode({until, grace, probe}) do
    share = div(grace, @cooperative_share)

    {cleanup_now_ms() + min(share, cleanup_remaining(until)), grace, probe}
  end

  defp exited_cooperatively?(group, {until, _grace, _probe} = episode) do
    cond do
      confirm_group_terminated(group, episode) ->
        true

      cleanup_remaining(until) == 0 ->
        false

      true ->
        Process.sleep(min(@cooperative_poll_ms, cleanup_remaining(until)))
        exited_cooperatively?(group, episode)
    end
  end

  # Concept: cleanup is confirmed by looking, not by assuming the signal worked.
  #
  # Technical depth: the confirmation is that no member of the group remains. A
  # descendant that left the group is outside both the kill and this check, which
  # is stated rather than papered over: the claim is about the group this
  # executor owns and no wider.
  defp confirm_group_terminated(group, {until, _grace, probe})
       when is_integer(group) and group > 1 do
    probe
    |> answer_within(["-o", "pid=", "-g", Integer.to_string(group)], cleanup_remaining(until))
    |> group_answered_empty?()
  end

  defp confirm_group_terminated(_group, _episode), do: true

  # Concept: a program this executor runs to clean up is still a program that can
  # fail to answer, and a bound that only stops this runtime waiting is not a
  # bound on the program.
  #
  # Technical depth: `System.cmd/3` takes no timeout, and both cleanup programs
  # ran inline in the process that owns the job -- so a `/bin/ps` or `/bin/kill`
  # that never returned held this executor's serialized owner, and the caller
  # blocking on `:infinity`, with no bound at all. That was fixed by running the
  # command in a BEAM process and killing *that* at the bound, which fixed the
  # wrong half. The operating-system process was never this runtime's to abandon:
  # a probe answered `:no_answer` after a hundred milliseconds and the child went
  # on to write its file afterwards. For `/bin/kill` that is worse than untidy --
  # it is a signal aimed at a negated group identifier, delivered at a moment
  # this executor believes its cleanup already ended, and process-group
  # identifiers are reissued.
  #
  # The program is now this process's own port, so the bound reaches the thing
  # that has to stop: at expiry the child is signalled by the process identifier
  # the port reported, and only then is the port closed. Signalling before
  # closing is deliberate -- the child is still this port's child while the port
  # is open, so the identifier still names it rather than whatever the operating
  # system reissues next.
  #
  # The wait is the declared cleanup grace rather than the run deadline because
  # this is the sequence that runs *after* expiry: bounding it by an instant
  # already in the past would refuse every confirmation this executor makes at a
  # deadline. Every caller now passes what remains of one absolute instant, so
  # the whole sequence shares the budget rather than each program receiving one.
  #
  # `:no_answer` is not silence. `group_answered_empty?/1` reads an empty answer
  # as an empty group, which is only sound for an answer that arrived, so a
  # program that never answered confirms nothing and the effect stays unproven --
  # the same rule that already refuses a `ps` killed by a signal. A program that
  # cannot be run at all raises where the port is opened and arrives as the same
  # non-answer.
  #
  # It is exposed for the reason `group_answered_empty?/1` is: no case can make
  # the operating system's own `ps` hang, and a case that must prove a timed-out
  # helper is dead has to be able to time one out.
  @doc false
  @spec answer_within(binary(), [binary()], non_neg_integer()) ::
          {binary(), integer()} | :no_answer
  def answer_within(program, arguments, bound)
      when is_binary(program) and is_list(arguments) and is_integer(bound) and bound >= 0 do
    port =
      Port.open(
        {:spawn_executable, String.to_charlist(program)},
        [
          :binary,
          :exit_status,
          :use_stdio,
          :stderr_to_stdout,
          :hide,
          args: Enum.map(arguments, &String.to_charlist/1),
          env: spawn_environment(demonstration_environment())
        ]
      )

    collect_answer(port, helper_os_pid(port), <<>>, System.monotonic_time(:millisecond) + bound)
  rescue
    _error -> :no_answer
  catch
    _kind, _value -> :no_answer
  end

  defp collect_answer(port, os_pid, acc, stop) do
    remaining = stop - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      abandon_helper(port, os_pid)
    else
      receive do
        {^port, {:data, chunk}} ->
          collect_answer(port, os_pid, acc <> chunk, stop)

        {^port, {:exit_status, status}} ->
          {acc, status}
      after
        # One allowance, spent in slices, refreshed by nothing -- the rule
        # `await_bounded_work/6` follows and for the same reason. An admitted
        # cleanup period spans the whole positive unsigned 64-bit range and this
        # wait is derived from it, so an unsliced `after` raised `:timeout_value`
        # and this function reported `:no_answer` for a program that had not been
        # asked anything yet: every confirmation under a large period failed and
        # the helper's own child was left running. The instant above is what the
        # wait ends against; a slice only decides how often it is looked at.
        min(remaining, @timer_slice_ms) -> collect_answer(port, os_pid, acc, stop)
      end
    end
  end

  # Concept: the helper is killed, and only then let go of.
  #
  # Technical depth: closing the port releases this runtime's handle and does not
  # end the process behind it, which is the whole defect. `kill(2)` on the
  # reported identifier is what ends it, and it is sent while the port still owns
  # the child. The confirmation is bounded because a `/bin/kill` that does not
  # answer is itself a process that has stopped answering, and the caller is
  # already past a bound; the answer is `:no_answer` either way, because this
  # runtime cannot prove a kill it did not see reported.
  defp abandon_helper(port, os_pid) do
    if is_integer(os_pid), do: signal_helper(os_pid)
    close_helper(port)
    :no_answer
  end

  defp signal_helper(os_pid) do
    port =
      Port.open(
        {:spawn_executable, ~c"/bin/kill"},
        [
          :binary,
          :exit_status,
          :use_stdio,
          :stderr_to_stdout,
          :hide,
          args: [~c"-KILL", String.to_charlist(Integer.to_string(os_pid))],
          env: spawn_environment(demonstration_environment())
        ]
      )

    receive do
      {^port, {:exit_status, _status}} -> :ok
    after
      @helper_signal_ms -> :ok
    end

    close_helper(port)
  rescue
    _error -> :ok
  catch
    _kind, _value -> :ok
  end

  defp helper_os_pid(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} -> os_pid
      _absent -> nil
    end
  end

  defp close_helper(port) do
    Port.close(port)
    :ok
  rescue
    _error -> :ok
  catch
    _kind, _value -> :ok
  end

  # Concept: silence only means "no survivors" when it came from a `ps` that
  # actually answered.
  #
  # Technical depth: the exit status was discarded, so any empty response read as
  # an empty group. A `ps` killed by a signal reports `{"", 137}` through
  # `System.cmd/3` -- measured on the supported toolchain -- and that read as a
  # confirmed-clean group. This is the single piece of evidence standing between
  # `:completed` and `:outcome_unknown`, and between `cancel/2`'s `:cleaned` and
  # `:unconfirmed`, so a non-answer must confirm nothing.
  #
  # The status cannot simply be required to be zero: measured on the same
  # toolchain, an empty group is reported as `{"", 1}`, so zero-only would refuse
  # every honest confirmation this executor makes. `0` and `1` are the two
  # statuses `ps` uses to answer -- survivors listed, and none matched -- and its
  # own errors print a diagnostic that `stderr_to_stdout` puts in the same
  # output, so an error is already non-empty. Anything outside those two statuses
  # is not an answer.
  #
  # A program that never answered within its bound, or could not be run at all,
  # arrives here as `:no_answer` rather than as an empty answer. It is the same
  # rule the abnormal status above states, reaching the same place: this decides
  # between a proved and an unproven effect, so it is one function rather than a
  # mapping at each call site that a later change can get wrong in only one of
  # them.
  #
  # It is exposed rather than private because no test can make the operating
  # system's `ps` die abnormally, and a rule that decides between a proved and an
  # unproven effect should not rest on an unreachable branch.
  @doc false
  @spec group_answered_empty?({binary(), integer()} | :no_answer) :: boolean()
  def group_answered_empty?({output, status}) when status in 0..1,
    do: String.trim(output) == ""

  def group_answered_empty?({_output, _status}), do: false

  def group_answered_empty?(:no_answer), do: false

  defp occurrences(content, needle) when needle != "" do
    content |> String.split(needle) |> length() |> Kernel.-(1)
  end

  defp occurrences(_content, _needle), do: 0

  # Concept: point at the nearest thing that looks like what was asked for.
  #
  # Technical depth: matching the first line of the requested text against the
  # file's lines finds the common case — the model had the right place and the
  # wrong whitespace or a stale neighbouring line — without pretending to be a
  # diff engine.
  defp nearest_hint(content, old) do
    first = old |> String.split("\n", parts: 2) |> List.first() |> String.trim()

    if first == "" do
      "The file has #{content |> String.split("\n") |> length()} lines."
    else
      # Concept: the closest line, not merely one that contains the whole request.
      #
      # Technical depth: an exact containment check finds nothing in the common
      # case, because the model's text differs from the file's by exactly the
      # detail that made the edit fail. Ranking by shared prefix points at the
      # line it probably meant, which is what turns a blank failure into one
      # retry rather than several.
      content
      |> String.split("\n")
      |> Enum.reject(&(String.trim(&1) == ""))
      |> Enum.max_by(&shared_prefix_length(String.trim(&1), first), fn -> nil end)
      |> case do
        nil -> "The file is empty."
        line -> "The closest line is #{inspect(String.trim(line))}."
      end
    end
  end

  defp shared_prefix_length(left, right) do
    left
    |> String.graphemes()
    |> Enum.zip(String.graphemes(right))
    |> Enum.take_while(fn {a, b} -> a == b end)
    |> length()
  end

  defp containment_message({:path_escapes_workspace, path}),
    do: "refused: #{path} resolves outside the workspace root"

  defp containment_message({:invalid_path, _path}), do: "refused: the path is not a string"
  defp containment_message(reason), do: "refused: #{inspect(reason)}"

  defp truncation_marker(kept, total) do
    kept <>
      "\n\n[loopex: output truncated. #{byte_size(kept)} of #{total} bytes shown.]"
  end

  defp bounded_artifact_notice(full, diagnostic, limit, reference) do
    bounded_notice(
      output_without_suffix(full, diagnostic),
      diagnostic,
      limit,
      &Loopex.ArtifactStore.truncation_notice(&1, byte_size(full), reference)
    )
  end

  defp bounded_truncation_marker(full, diagnostic, limit) do
    bounded_notice(
      output_without_suffix(full, diagnostic),
      diagnostic,
      limit,
      &truncation_marker(&1, byte_size(full))
    )
  end

  defp bounded_truncation_with_extra(full, diagnostic, limit, extra) do
    bounded_notice(
      output_without_suffix(full, diagnostic),
      diagnostic,
      limit,
      &(truncation_marker(&1, byte_size(full)) <> extra)
    )
  end

  defp bounded_notice(output, diagnostic, limit, builder) do
    if byte_size(diagnostic) >= limit do
      binary_part(diagnostic, 0, limit)
    else
      converge_bounded_notice(output, diagnostic, limit, builder, 0, 0)
    end
  end

  defp converge_bounded_notice(output, diagnostic, limit, builder, shown, attempts) do
    kept = binary_part(output, 0, min(byte_size(output), shown))
    displayed = kept <> diagnostic
    candidate = builder.(displayed)
    notice_bytes = byte_size(candidate) - byte_size(displayed)
    next = min(byte_size(output), max(limit - byte_size(diagnostic) - notice_bytes, 0))

    if next == shown or attempts == 4 do
      next_kept = binary_part(output, 0, next)
      bounded = builder.(next_kept <> diagnostic)
      binary_part(bounded, 0, min(byte_size(bounded), limit))
    else
      converge_bounded_notice(output, diagnostic, limit, builder, next, attempts + 1)
    end
  end

  defp artifact_ceiling_message(output, output_limit, artifact_limit, observed, confirmed) do
    cleanup =
      if confirmed,
        do: "Its process group is confirmed clean.",
        else: "Cleanup could not be confirmed, so the effect remains unproven."

    suffix =
      "\n\n[loopex: command output exceeded the tool's declared artifact ceiling of " <>
        "#{artifact_limit} bytes after at least #{observed} bytes were observed. " <>
        "Collection stopped at the ceiling and no partial artifact was retained. #{cleanup}]"

    bounded_with_suffix(output, suffix, output_limit)
  end

  defp bounded_terminal_output(output, suffix, limit) do
    if byte_size(output) + byte_size(suffix) <= limit do
      output <> suffix
    else
      diagnostic =
        suffix <>
          "\n[loopex: output truncated after at least #{byte_size(output)} bytes were observed.]"

      bounded_with_suffix(output, diagnostic, limit)
    end
  end

  # Keep required diagnostics at the end while making the complete model-facing
  # result obey the output ceiling. All shipped ceilings are larger than these
  # suffixes; the final clause remains fail-closed for a narrower conforming
  # definition by returning only as much of the diagnostic as can fit.
  defp bounded_with_suffix(output, suffix, limit) do
    kept_suffix = binary_part(suffix, 0, min(byte_size(suffix), limit))
    available = limit - byte_size(kept_suffix)
    kept_output = binary_part(output, 0, min(byte_size(output), available))
    kept_output <> kept_suffix
  end

  defp output_without_suffix(full, ""), do: full

  defp output_without_suffix(full, suffix) do
    size = byte_size(full) - byte_size(suffix)
    binary_part(full, 0, max(size, 0))
  end

  # Concept: a tool that did something says what it did.
  #
  # Technical depth: this demonstration tool wrote its file and printed nothing,
  # so the model received an empty result. Under M1's fixed two turns nothing
  # depended on the model understanding it. Under M2's real loop it does: a
  # result that says nothing is indistinguishable from a call that failed
  # silently, and a real provider answered it by writing the same file again,
  # several times, in a live recovery trace. The four operator-facing coding
  # tools already report what they did; this one now does too.
  defp launcher_arguments(%{path: path, content: content, delay_ms: delay}) do
    script =
      "if [ \"${#{@credential_name}+x}\" = x ]; then exit 97; fi; " <>
        "delay=$1; target=$2; content=$3; " <>
        "if [ \"$delay\" -gt 0 ]; then sleep \"$delay\"; fi; " <>
        "umask 077; printf %s \"$content\" > \"$target\"; " <>
        "printf 'wrote the requested content to %s' \"$target\""

    [
      "-i",
      @search_path_name <> "=" <> @search_path_value,
      "/bin/sh",
      "-c",
      script,
      "loopex-controlled-tool",
      Integer.to_string(div(delay + 999, 1_000)),
      path,
      content
    ]
  end

  # Concept: the demonstration tools are launched by this executor too, so the
  # run's instant bounds them for the same reason it bounds everything else.
  #
  # Technical depth: this wait named the port and the lease and nothing else, so
  # a `loopex.demo.wait_write` declaring a thirty second delay ran for thirty
  # seconds under a two hundred millisecond run deadline and reported
  # `:completed`. It is the same defect the coding tools' filesystem and
  # retention waits had, in the path M1 left behind, and the same requirement
  # covers it: no operation the run owns may outlast the run's committed instant.
  #
  # The outcome is `:outcome_unknown` rather than a cancellation. This path
  # captures no process group -- only the coding path's shell announces one -- so
  # closing the port releases this executor's handle on the child without
  # proving the child stopped or that its write did not land. A cancellation
  # would claim the stop; `:outcome_unknown` claims only what was observed, and
  # is what stops a coordinator blindly retrying an effectful job.
  defp await_port(port, monitor, lease_pid, output, deadline) do
    remaining = fence_remaining(deadline)

    if remaining <= 0 do
      if Port.info(port), do: Port.close(port)
      {:outcome_unknown, output <> @deadline_released_note}
    else
      receive do
        # Concept: the job was cancelled while its child was running, and what
        # this path can honestly say is that it let the child go.
        #
        # Technical depth: no process group was captured here, so there is
        # nothing to signal and nothing to confirm quiescent. The Port is closed,
        # the answer to the cancellation is `unconfirmed`, and the job's own
        # terminal is `outcome_unknown` -- which is what stops a coordinator
        # blindly retrying an effect that may have landed.
        {:loopex_cancel_pending, token, from, _cancel_grace, _cancel_probe} ->
          if Port.info(port), do: Port.close(port)
          send(from, {:loopex_cancel_result, token, {:ok, :unconfirmed}})
          {:outcome_unknown, output <> @cancelled_released_note}

        {^port, {:data, data}} ->
          combined = output <> data

          if byte_size(combined) <= @max_output_bytes do
            await_port(port, monitor, lease_pid, combined, deadline)
          else
            Port.close(port)
            {:failed_output_limit, binary_part(combined, 0, @max_output_bytes)}
          end

        {^port, {:exit_status, 0}} ->
          {:completed, output}

        {^port, {:exit_status, status}} ->
          {{:failed, status}, output}

        {:DOWN, ^monitor, :process, ^lease_pid, _reason} ->
          if Port.info(port), do: Port.close(port)
          {:cancelled_workspace_lease_lost, output}
      after
        # Polled in the same shape and for the same reason `collect_output/7`
        # polls: the deadline is an instant rather than a message, so it has to
        # be looked at between waits.
        min(remaining, 50) -> await_port(port, monitor, lease_pid, output, deadline)
      end
    end
  end

  defp receipt(
         state,
         job,
         tool,
         outcome,
         output,
         environment,
         artifacts,
         deadline,
         progress_count
       ) do
    %{
      protocol_version: 1,
      job_id: job.job_id,
      operation_id: job.operation_id,
      attempt: job.attempt,
      session_id: job.session_id,
      run_id: job.run_id,
      turn_id: job.turn_id,
      tool_call_id: job.tool_call_id,
      session_epoch_at_dispatch: job.origin_session_epoch,
      executor_epoch: state.epoch,
      executor_identity: state.identity,
      canonical_request_digest: job.canonical_request_digest,
      fencing_token: state.fencing_token,
      tool_id: tool.id,
      tool_version: tool.version,
      outcome: outcome,
      output: output,
      progress_count: progress_count,
      # Concept: when the effect was admitted, not when it happened to finish.
      #
      # Technical depth: ADR 0016 makes this the wall half of the one paired
      # sample taken at effect admission, carried here unchanged. Resampling at
      # completion would make a slow effect report an instant at which its own
      # authority had not yet been established, and would make two receipts for
      # one operation disagree about when it began.
      observed_at_ms: admitted_at_ms(),
      child_environment_names: environment_names(environment),
      provider_credential_present: credential_present?(environment),
      # Concept: the period this job ran under is the one its request carried.
      #
      # Technical depth: ADR 0016 makes the committed session value a canonical
      # `JobRequest` member. Reporting this executor's startup default instead
      # would make the durable record name a period the cleanup did not run
      # under whenever a session declared its own.
      cleanup_grace_ms: job.cleanup_grace_ms,
      cleanup_confirmation: cleanup_confirmation(outcome),
      receipt_retention_bound_ms: committed_retention_ms(job),
      process_probe: state.process_probe,
      effective_deadline_ms: deadline,
      run_deadline_ms: job.run_deadline,
      artifacts: artifacts
    }
  end

  defp admitted_at_ms do
    case Process.get(:loopex_admission) do
      %{observed_at_ms: observed} -> observed
      _no_admission -> System.system_time(:millisecond)
    end
  end

  # Concept: whether this job's captured process group was positively confirmed
  # gone.
  #
  # Technical depth: it is derived from the same evidence the outcome is, rather
  # than guessed beside it. Every path in this executor that cannot confirm the
  # captured group quiescent, cannot confirm an abandoned worker stopped, or lost
  # the lease that authorized the effect already reports `:outcome_unknown`;
  # every other terminal was reached with either nothing to clean up or a
  # positively confirmed group. That coupling is what makes the two facts
  # consistent by construction, and it is exactly ADR 0016's relation: an
  # unconfirmed cleanup is conforming only beside `outcome_unknown`. Escaped
  # descendants remain outside this claim, as ADR 0012 and ADR 0016 both state.
  defp cleanup_confirmation(:outcome_unknown), do: :unconfirmed
  defp cleanup_confirmation(_settled), do: :confirmed

  defp committed_retention_ms(job), do: receipt_reserve_ms(job.cleanup_grace_ms)

  # The staging name is chosen by the caller rather than here, because a caller
  # that may have to abandon this write is the one that has to be able to remove
  # what it left behind.
  defp staging_path(root, receipt) do
    receipt_path(root, receipt.job_id) <>
      ".tmp-" <> Integer.to_string(System.unique_integer([:positive]))
  end

  defp retain_receipt(root, receipt, temporary) do
    path = receipt_path(root, receipt.job_id)
    bytes = :erlang.term_to_binary(receipt, [:deterministic])

    result =
      with :ok <- write_synced_receipt(temporary, bytes),
           :ok <- File.rename(temporary, path),
           :ok <- sync_parent_directory(path) do
        :ok
      end

    if result != :ok, do: File.rm(temporary)
    result
  end

  defp write_synced_receipt(path, bytes) do
    case File.open(path, [:write, :binary, :exclusive]) do
      {:ok, file} ->
        result =
          with :ok <- IO.binwrite(file, bytes),
               :ok <- :file.sync(file) do
            :ok
          end

        close_result = File.close(file)

        case {result, close_result} do
          {:ok, :ok} -> :ok
          {{:error, reason}, _close} -> {:error, {:receipt_write_failed, reason}}
          {:ok, {:error, reason}} -> {:error, {:receipt_close_failed, reason}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp sync_parent_directory(path) do
    directory = path |> Path.dirname() |> String.to_charlist()

    case :file.open(directory, [:raw, :read, :directory]) do
      {:ok, file} ->
        result = :file.sync(file)
        close_result = :file.close(file)

        case {result, close_result} do
          {:ok, :ok} -> :ok
          {{:error, reason}, _close} -> {:error, {:receipt_directory_sync_failed, reason}}
          {:ok, {:error, reason}} -> {:error, {:receipt_directory_close_failed, reason}}
        end

      {:error, reason} ->
        {:error, {:receipt_directory_unavailable, reason}}
    end
  end

  defp read_receipt(_root, ""), do: :absent

  defp read_receipt(root, job_id) do
    case File.read(receipt_path(root, job_id)) do
      {:ok, bytes} -> decode_receipt(bytes, job_id)
      {:error, :enoent} -> :absent
      {:error, reason} -> {:error, {:receipt_read_failed, reason}}
    end
  end

  defp decode_receipt(bytes, job_id) do
    receipt = :erlang.binary_to_term(bytes, [:safe])

    if is_map(receipt) and Map.get(receipt, :job_id) == job_id and
         cleanup_facts_readable?(receipt),
       do: {:ok, receipt},
       else: {:error, :invalid_retained_receipt}
  rescue
    _error -> {:error, :invalid_retained_receipt}
  end

  # Concept: a retained receipt whose cleanup facts are missing, unreadable, or
  # contradictory is not a receipt this executor will hand back.
  #
  # Technical depth: ADR 0016 makes both facts mandatory on every terminal
  # receipt and fixes one relation between them -- an unconfirmed cleanup is
  # conforming only beside `outcome_unknown`. Failing closed here is what stops a
  # rewritten or truncated ledger file from replaying as a settled operation
  # whose captured group may still be running. The retention bound is required
  # positive because zero is not a duration any phase can be spent against.
  defp cleanup_facts_readable?(receipt) do
    confirmation = Map.get(receipt, :cleanup_confirmation)
    bound = Map.get(receipt, :receipt_retention_bound_ms)

    confirmation in [:confirmed, :unconfirmed] and is_integer(bound) and
      bound in 1..@max_uint64 and
      (confirmation == :confirmed or Map.get(receipt, :outcome) == :outcome_unknown)
  end

  defp receipt_path(root, job_id) do
    name = :crypto.hash(:sha256, job_id) |> Base.encode16(case: :lower)
    Path.join(root, name <> ".receipt")
  end

  defp notify(options, message) do
    case Keyword.get(options, :notify) do
      pid when is_pid(pid) -> send(pid, message)
      _other -> :ok
    end
  end
end
