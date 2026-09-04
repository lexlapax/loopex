defmodule Loopex.Executor do
  @moduledoc """
  ## Concept

  The authority and effect-start boundary for executor-backed work. It defines
  one transport-neutral job, the exact host-grant bindings ADR 0007 requires,
  and the value checks every executor performs immediately before an effect.

  An executor also declares, for every error it returns, whether that error
  reached the caller *before* the effect started. Nothing else can know: the
  executor is the only party that was present at the boundary. A caller that
  guesses turns a mid-effect failure into an ordinary refusal and resumes the
  loop past an effect nobody can account for.

  ## Technical depth

  The job digest is SHA-256 over a deterministic encoding of one closed ordered
  semantic projection. Capability-grant bytes are not digested; their durable
  binding metadata is. Grant validation derives from the single production
  binding schema, while the protected conformance test deliberately carries the
  independent literal ADR oracle. M1 grants are trusted-VM data and make no
  authenticity or transport claim.

  An executor that refused a job before its effect started says so in the answer
  itself, by returning `{:error, {:refused_before_effect, reason}}`. Nothing else
  is a declaration. A bare `{:error, reason}` claims nothing about whether the
  effect ran, and a caller must read it as unproven -- which is also the reading
  for every executor that never adopts the tag at all, because "I did not tell
  you when my effect started" and "my effect may have started" are the same fact
  from outside.

  The declaration travels in the result rather than in a second callback the
  caller invokes afterwards. `{:error, term()}` already carries it, so it widens
  no callback; and a caller reading a returned term cannot be blocked by the
  implementation that produced it, which a caller running an implementation's
  code inside its own process can.
  """

  @protocol_version 1

  # How long this runtime waits for a host-supplied `cancel/2` before reporting
  # the cleanup unproven. Not an operator budget — see `cancel/3`.
  @cancel_bound_ms 60_000
  # A receipt lookup reads retained bytes and starts nothing; an executor that
  # cannot answer inside this bound is broken, and the coordinator leaves the
  # reconciliation to the host rather than waiting on it.
  @receipt_bound_ms 30_000

  @grant_bindings [
    :operation_id,
    :attempt,
    :canonical_request_digest,
    :tool_id,
    :tool_version,
    :effect_class,
    :workspace_lease,
    :executor_audience,
    :expiry,
    :fencing_token
  ]

  alias Loopex.Executor.JobRequest

  @job_fields JobRequest.semantic_fields()

  # Concept: the cleanup period is a fact of the request, not a setting of the
  # hand that runs it.
  #
  # Technical depth: ADR 0016 makes the committed session value a canonical
  # `JobRequest` member, so it participates in `canonical_request_digest` and a
  # job dispatched under one period can never be joined or replayed under
  # another. The admitted domain is the positive unsigned 64-bit range; every
  # scalar entry refuses outside it before any host callback runs.
  @max_cleanup_grace_ms 18_446_744_073_709_551_615
  @default_cleanup_grace_ms 5_000

  @typedoc """
  ## Concept

  One immutable executor request with its independently checkable digest.

  ## Technical depth

  The job carries the complete M1 origin tuple and bounded plain semantic data.
  `canonical_request_bytes` and `canonical_request_digest` bind exactly the
  ordered fields returned by `job_fields/0`.
  """
  @type job_request :: JobRequest.t()

  @typedoc """
  ## Concept

  A trusted-local host decision bound to one exact job and executor.

  ## Technical depth

  This is structured trusted-VM data, not a signature or portable token. The
  `issued_by` marker proves only that the reference issuance function was used;
  M1 deliberately makes no unforgeability claim.
  """
  @type grant :: map()

  @typedoc """
  ## Concept

  One bounded piece of progress from a running job, carrying the whole identity
  of the attempt that produced it.

  ## Technical depth

  Plain data carrying the protocol and job identifiers and the job's complete
  origin tuple — the call and operation it belongs to, that operation's attempt,
  the session, run, and turn, the attempt-bound `canonical_request_digest`, both
  origin epochs, the executor's identity, and its fencing token — followed by
  the executor-supplied progress sequence, the stream it came from, a contiguous
  per-stream byte offset, and a bounded chunk.

  Every one of those bindings is required, because the coordinator validates all
  of them fail-closed against the job it journaled before it projects anything.
  A `tool_call_id` on its own is not an identity: a stale or superseded executor
  can hold a live call id while being wrong about the attempt, the epoch, or the
  fence it is acting under, and an event that proves only the call id would carry
  that staleness straight to an operator.

  It carries no `stream_domain_id`: an executor never computes one, and the
  coordinator stamps the domain only after validation has proved the event
  belongs to the attempt it dispatched.
  """
  @type progress_event :: %{
          required(:protocol_version) => pos_integer(),
          required(:job_id) => binary(),
          required(:tool_call_id) => binary(),
          required(:operation_id) => binary(),
          required(:attempt) => pos_integer(),
          required(:session_id) => binary(),
          required(:run_id) => binary(),
          required(:turn_id) => binary(),
          required(:canonical_request_digest) => binary(),
          required(:session_epoch_at_dispatch) => non_neg_integer(),
          required(:executor_epoch) => non_neg_integer(),
          required(:executor_identity) => binary(),
          required(:fencing_token) => non_neg_integer(),
          required(:progress_sequence) => non_neg_integer(),
          required(:stream) => binary(),
          required(:byte_offset) => non_neg_integer(),
          required(:chunk) => binary()
        }

  @typedoc """
  ## Concept

  The function an executor calls to report one progress event.

  ## Technical depth

  An ordinary in-VM function reference in the trailing argument position. That
  one parameter is the whole streaming change to `execute`; ADR 0012 separately
  requires `cancel/2`. An executor that emits nothing stays conformant, returns
  the same receipt, and reports a `progress_count` of zero rather than a sentinel
  or an absent field.
  """
  @type progress_fun :: (progress_event() -> :ok)

  @doc """
  ## Concept

  Runs one exact job and answers with its receipt, or with the reason it could
  not.

  ## Technical depth

  `{:ok, receipt}` is the terminal fact for the job. `{:error, reason}` says
  only that no receipt was produced; on its own it says nothing about whether
  the effect started, and a caller must read it as unproven. The one answer that
  says more is `{:error, {:refused_before_effect, reason}}`, which an executor
  returns only where nothing the job would have done can have happened: no
  process started, no byte written, no request sent. `reason` is then the
  ordinary terminal failure the conversation is owed.
  """
  @callback execute(reference :: term(), job_request(), grant(), keyword(), progress_fun()) ::
              {:ok, map()} | {:error, term()}

  @doc """
  ## Concept

  Stops one running job and says whether its cleanup could be confirmed.

  ## Technical depth

  The narrowest cancellation an executor can offer: it names one job, so an
  abort ends the work the operator asked to stop and leaves every other job and
  the workspace itself usable. M1's only cancellation signal was workspace-lease
  loss, which is coarser — revoking a lease ends every job on that workspace and
  leaves the runtime unable to run more work there, which is a heavy consequence
  for one interrupt.

  The return says what actually happened rather than what was attempted.
  `{:ok, :cleaned}` means no member of the job's owned process tree remains;
  `{:ok, :unconfirmed}` means the executor could not establish that, and the run
  must then finish `outcome_unknown` rather than claiming a clean stop;
  `{:error, reason}` means the executor could not complete or report its
  cancellation attempt, and callers likewise treat cleanup as unconfirmed. A
  job that was never running, or already finished, is trivially clean.

  Every conforming executor implements this callback, including one that
  performs only in-VM work. Such an executor can answer `{:ok, :cleaned}` for a
  job it never started or has already completed; callback absence proves
  nothing about work an implementation may own.
  """
  @callback cancel(reference :: term(), job_id :: binary()) ::
              {:ok, :cleaned} | {:ok, :unconfirmed} | {:error, term()}

  @doc """
  ## Concept

  Reads the terminal receipt an executor retained for one job, so a runtime
  that has taken a session over from a dead process can learn what that
  process's effect did without running it again.

  ## Technical depth

  Optional. `{:ok, receipt}` is the retained terminal fact for the job;
  `:absent` says no receipt exists and none is coming from this executor;
  `{:error, reason}` says the executor could not answer, and a job the executor
  still holds in flight answers `{:error, :effect_in_flight}` rather than
  `:absent`, because absence there would read live work as lost. An executor
  whose durable authority shows an admitted effect that no live instance is
  settling answers `{:error, :effect_unresolved}`, and one whose receipt is
  retained but whose open entry still stands answers `{:error, :effect_settling}`;
  the coordinator ends a recovered run `outcome_unknown` on either, since the
  process that could have finished them is gone by the time a prepared resume is
  activated. The session
  coordinator asks this once, at the activation of a prepared resume whose
  pending work is a dispatched effect, and validates the answer exactly as it
  validates a receipt a host presents through `Loopex.reconcile/2`; an executor
  that does not export the callback leaves that reconciliation host-driven, and
  so does any answer the coordinator cannot validate.
  """
  @callback retained_receipt(reference :: term(), job_id :: binary()) ::
              {:ok, map()} | :absent | {:error, term()}

  @optional_callbacks retained_receipt: 2

  @doc """
  ## Concept

  Asks an executor to stop a job and fails closed when cleanup is not proved.

  ## Technical depth

  Every conforming executor implements `cancel/2`. The facade retains a
  defensive path for a legacy or nonconforming module that does not: absence is
  treated as unconfirmed, never as evidence that nothing remains. The same
  fail-closed result applies when the callback returns `{:error, reason}`, raises,
  exits, times out, or returns anything outside the two admitted success shapes.
  The safe reading of "I could not tell you" is that something may still be
  running, and a run must not claim `cancelled` on that basis.

  The call is bounded and runs in a process of its own, because it is
  host-supplied code that a caller invokes while a run is in flight. An
  implementation that blocks would otherwise block the caller — and the caller
  here is the session coordinator, which then cannot answer the operator's second
  interrupt, arm a deadline, or admit anything at all. An answer that never comes
  is `{:ok, :unconfirmed}`, which is the same reading as an answer that says it
  could not tell.

  The bound is this runtime's protection against an executor that does not
  return, not an operator-facing budget: the shipped local executor bounds its
  own cancellation by the cleanup period it was configured with, and reaches this
  bound only if it is itself broken. It is deliberately far longer than that
  period, so a slow-but-working executor is never cut off and reported unproven
  when it was about to answer.
  """
  @spec cancel(module(), term(), binary()) :: {:ok, :cleaned} | {:ok, :unconfirmed}
  def cancel(module, reference, job_id) when is_atom(module) and is_binary(job_id) do
    if function_exported?(module, :cancel, 2) do
      bounded_cancel(module, reference, job_id, @cancel_bound_ms)
    else
      # Concept: an executor that declares no cancellation has confirmed
      # nothing, and silence is not a clean stop.
      #
      # Technical depth: this used to answer `cleaned`, on the reasoning that an
      # implementation without the callback has nothing to leave behind. That is
      # a statement about the implementation this repository ships, not about the
      # port: a legacy or nonconforming module may own an operating-system process
      # and not export `cancel/2`, and reading its silence as confirmed cleanup
      # committed `cancelled` for a tree nobody signalled and nobody looked at.
      # `unconfirmed` is what this runtime actually knows, and it ends the run
      # `outcome_unknown` with a reconciliation reference instead.
      {:ok, :unconfirmed}
    end
  end

  # Concept: run it somewhere it can be abandoned, and abandon it at the bound.
  #
  # Technical depth: `spawn_monitor` rather than a linked task, so an
  # implementation that raises or exits takes nothing with it, and the answer
  # travels in the exit reason so no second message shape is needed. There is
  # deliberately no `try` around the call: a raise and an exit are then ordinary
  # abnormal terminations that arrive on the same `DOWN` as everything else, and
  # the three ways a cancellation can fail to say anything -- raising, exiting,
  # and answering with a term outside the two admitted shapes -- reach exactly
  # two branches here instead of three, both of which a case drives. Catching
  # them inside the worker would collapse the first two into a normal answer and
  # leave the abnormal branch reachable by nothing.
  #
  # The worker is killed rather than left running when the bound is reached: a
  # caller that stopped waiting has no use for an answer that arrives later, and
  # an abandoned worker holding a port would outlive the run that owned it.
  defp bounded_cancel(module, reference, job_id, bound) do
    {pid, monitor} =
      spawn_monitor(fn -> exit({:loopex_cancel_answer, module.cancel(reference, job_id)}) end)

    await_cancel(pid, monitor, System.monotonic_time(:millisecond) + bound)
  end

  # Concept: an admitted observation period is spent, never handed to one timer.
  #
  # Technical depth: `cancellation_bounds/1` admits the whole positive unsigned
  # 64-bit range, and a `receive ... after` larger than the VM's timer ceiling
  # raises rather than waiting. The wait is therefore one monotonic deadline
  # consumed in safe finite slices: each slice recomputes what remains against
  # the same instant, so no slice refreshes the allowance and the observation is
  # exact for every admitted value. Monotonic time is used because this is a
  # duration, and a wall-clock step must not lengthen or shorten it.
  @cancel_slice_ms 3_600_000

  defp await_cancel(pid, monitor, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:DOWN, ^monitor, :process, ^pid, {:loopex_cancel_answer, answer}} ->
        admitted_cancel(answer)

      {:DOWN, ^monitor, :process, ^pid, _abnormal} ->
        {:ok, :unconfirmed}
    after
      min(remaining, @cancel_slice_ms) ->
        if System.monotonic_time(:millisecond) >= deadline do
          Process.demonitor(monitor, [:flush])
          Process.exit(pid, :kill)
          {:ok, :unconfirmed}
        else
          await_cancel(pid, monitor, deadline)
        end
    end
  end

  @doc """
  ## Concept

  Asks an executor for the receipt it retained for one job, and answers
  honestly when it cannot.

  ## Technical depth

  The optional `retained_receipt/2` callback is consulted only where the module
  exports
  it; a module that does not answers `{:error, :receipt_lookup_unsupported}`,
  which the coordinator reads as "leave this to the host" rather than as any
  fact about the effect. The call is bounded and runs in a process of its own
  for the reason `cancel/3` gives: it is host-supplied code invoked by the
  session coordinator, which must stay able to answer an operator while it
  waits. A raise, an exit, an answer outside the three admitted shapes, or the
  bound elapsing each become an error the coordinator declines on; none of them
  is ever read as `:absent`, because absence is the one answer that ends a run
  `outcome_unknown` and must therefore be stated, never inferred.
  """
  @spec retained_receipt(module(), term(), binary()) ::
          {:ok, map()} | :absent | {:error, term()}
  def retained_receipt(module, reference, job_id) when is_atom(module) and is_binary(job_id) do
    if Code.ensure_loaded?(module) and function_exported?(module, :retained_receipt, 2) do
      bounded_receipt(module, reference, job_id, @receipt_bound_ms)
    else
      {:error, :receipt_lookup_unsupported}
    end
  end

  defp bounded_receipt(module, reference, job_id, bound) do
    {pid, monitor} =
      spawn_monitor(fn ->
        exit({:loopex_receipt_answer, module.retained_receipt(reference, job_id)})
      end)

    await_receipt(pid, monitor, System.monotonic_time(:millisecond) + bound)
  end

  defp await_receipt(pid, monitor, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:DOWN, ^monitor, :process, ^pid, {:loopex_receipt_answer, answer}} ->
        admitted_receipt(answer)

      {:DOWN, ^monitor, :process, ^pid, _abnormal} ->
        {:error, :receipt_lookup_failed}
    after
      min(remaining, @cancel_slice_ms) ->
        if System.monotonic_time(:millisecond) >= deadline do
          Process.demonitor(monitor, [:flush])
          Process.exit(pid, :kill)
          {:error, :receipt_lookup_timeout}
        else
          await_receipt(pid, monitor, deadline)
        end
    end
  end

  defp admitted_receipt({:ok, receipt}) when is_map(receipt), do: {:ok, receipt}
  defp admitted_receipt(:absent), do: :absent
  defp admitted_receipt({:error, reason}), do: {:error, reason}
  defp admitted_receipt(_other), do: {:error, :invalid_receipt_answer}

  @doc """
  ## Concept

  The complete set of cancellation observation bounds one committed cleanup
  period derives.

  ## Technical depth

  ADR 0016 fixes this formula in Core so no caller invents a wait and no
  executor is asked for its configuration. `executor_observe_ms` bounds the
  `cancel/2` callback, `receipt_retention_ms` bounds the durable account of what
  happened, `execute_result_reserve_ms` is the distinct window the original
  `execute/5` caller gets after the cancellation answer, `terminal_reserve_ms`
  and `session_cache_ms` bound terminal rendering and session caching, and
  `cli_backstop_ms` is the sum a process-liveness backstop must cover. The
  intervals stay distinct: the observe bound never doubles as the result
  reserve, and no bound is derived from another's already-spent instant.

  `grace_ms` is exactly `1..18_446_744_073_709_551_615`. Anything else —
  including a float, a zero, a negative, or a value one above the range — is
  `{:error, :invalid_cleanup_grace}` and reaches no callback.
  """
  @spec cancellation_bounds(term()) :: {:ok, map()} | {:error, :invalid_cleanup_grace}
  def cancellation_bounds(grace_ms)
      when is_integer(grace_ms) and grace_ms >= 1 and grace_ms <= @max_cleanup_grace_ms do
    quarter = max(1, div(grace_ms + 3, 4))
    observe = max(10_000, grace_ms + 2_000)
    reserve = quarter + 2_000
    terminal = max(10_000, reserve)

    {:ok,
     %{
       executor_observe_ms: observe,
       receipt_retention_ms: quarter,
       execute_result_reserve_ms: reserve,
       terminal_reserve_ms: terminal,
       session_cache_ms: terminal,
       cli_backstop_ms: observe + reserve + terminal
     }}
  end

  def cancellation_bounds(_grace_ms), do: {:error, :invalid_cleanup_grace}

  @doc """
  ## Concept

  Asks an executor to stop a job under the cleanup period the session committed.

  ## Technical depth

  This is the production cancellation entry. The observation bound is derived
  from `grace_ms` by `cancellation_bounds/1` rather than from this runtime's
  defensive constant, so a session that committed a long valid cleanup period is
  observed for that period instead of being cut off and reported unproven.
  `cancel/3` keeps ADR 0012's fixed defensive bound for a direct caller that has
  no committed value; production coordination never selects it.

  An invalid period is refused before the callback runs, because a bound that
  cannot be computed is not a bound that may be guessed. Every other failure
  reads exactly as it does through `cancel/3`: silence, a raise, an exit, or an
  answer outside the two admitted shapes is `{:ok, :unconfirmed}`.
  """
  @spec cancel(module(), term(), binary(), term()) ::
          {:ok, :cleaned} | {:ok, :unconfirmed} | {:error, :invalid_cleanup_grace}
  def cancel(module, reference, job_id, grace_ms)
      when is_atom(module) and is_binary(job_id) do
    case cancellation_bounds(grace_ms) do
      {:ok, %{executor_observe_ms: bound}} ->
        if function_exported?(module, :cancel, 2) do
          bounded_cancel(module, reference, job_id, bound)
        else
          {:ok, :unconfirmed}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp admitted_cancel({:ok, :cleaned}), do: {:ok, :cleaned}
  defp admitted_cancel({:ok, :unconfirmed}), do: {:ok, :unconfirmed}
  defp admitted_cancel(_other), do: {:ok, :unconfirmed}

  @doc """
  ## Concept

  A progress function that discards everything, for a caller that wants no
  stream.

  ## Technical depth

  Executors are always handed a callable rather than `nil`, so no executor needs
  a branch asking whether it was given one.
  """
  @spec discard_progress() :: progress_fun()
  def discard_progress, do: fn _event -> :ok end

  @doc """
  ## Concept

  The cleanup period a session declares when its host names none.

  ## Technical depth

  ADR 0009 makes the cleanup grace a declared session configuration value with a
  default, reported in the run's terminal evidence, so an operator can tell a
  clean cooperative stop from a forced kill that was confirmed and from a
  termination that could not be confirmed at all. The number lives here, on the
  port, because two parties need the same one: the session declares it, and the
  executor that performs the cleanup is handed it. A default defined twice is two
  numbers that agree until one of them is edited, and a terminal reporting a
  period the hand did not actually use is exactly the false record reporting it
  is meant to prevent.
  """
  @spec default_cleanup_grace_ms() :: pos_integer()
  def default_cleanup_grace_ms, do: @default_cleanup_grace_ms

  @doc """
  ## Concept

  The one production schema every M1 grant validator and mutation corpus uses.

  ## Technical depth

  Kept as ordered data for deterministic refusal and test derivation. Its
  completeness is checked against ADR 0007's independent literal oracle.
  """
  @spec required_grant_bindings() :: [atom()]
  def required_grant_bindings, do: @grant_bindings

  @doc """
  ## Concept

  The immutable semantic fields bound into a job digest.

  ## Technical depth

  Capability-grant secrets are intentionally absent. The binding values a
  grant represents are already present in the semantic job projection.
  """
  @spec job_fields() :: [atom()]
  def job_fields, do: @job_fields

  @doc """
  ## Concept

  Builds the exact immutable job an executor may be asked to start.

  ## Technical depth

  Unknown or missing semantic fields fail instead of being silently excluded
  from the digest. Canonical bytes are deterministic external-term bytes; the
  digest is lowercase hexadecimal SHA-256.
  """
  @spec job(map()) :: {:ok, job_request()} | {:error, term()}
  def job(fields) when is_map(fields) do
    # Concept: a caller that named no cleanup period gets the one this port
    # declares; every other semantic field must be supplied.
    #
    # Technical depth: ADR 0009 makes the cleanup grace a declared value with a
    # default, and ADR 0016 makes that value part of the digested projection. A
    # direct caller with no committed session value therefore digests the port's
    # default rather than a missing member, while a session hands its own
    # committed value and any change to it changes the digest. Derived members a
    # caller hands back -- which is what rebuilding a job from another job's
    # projection does -- are recomputed rather than trusted; any other extra key
    # is an unknown field and refuses, so a misspelt semantic field cannot be
    # silently dropped from what the digest covers.
    fields = Map.put_new(fields, :cleanup_grace_ms, @default_cleanup_grace_ms)
    semantic = Map.take(fields, @job_fields)

    with true <- map_size(semantic) == length(@job_fields),
         [] <- Map.keys(fields) -- (@job_fields ++ JobRequest.derived_fields()),
         :ok <- validate_job_fields(semantic),
         {:ok, bytes} <- canonical_bytes(semantic) do
      {:ok,
       JobRequest
       |> struct!(semantic)
       |> Map.put(:canonical_request_bytes, bytes)
       |> Map.put(:canonical_request_digest, digest(bytes))
       |> Map.put(:effective_job_deadline, effective_job_deadline(semantic))}
    else
      _other -> {:error, :invalid_job_request}
    end
  end

  def job(_fields), do: {:error, :invalid_job_request}

  @doc """
  ## Concept

  Proves that a job still matches the immutable bytes and digest its durable
  intent and grant bind.

  ## Technical depth

  Recomputes from semantics and requires both byte and digest equality. This is
  the independent executor-side digest computation required by ADR 0007.
  """
  @spec validate_job(map()) :: :ok | {:error, term()}
  def validate_job(job) when is_map(job) do
    fields = Map.take(job, @job_fields)

    with true <- Map.keys(fields) |> Enum.sort() == Enum.sort(@job_fields),
         :ok <- validate_job_fields(fields),
         {:ok, bytes} <- canonical_bytes(fields),
         true <- Map.get(job, :canonical_request_bytes) == bytes,
         true <- Map.get(job, :canonical_request_digest) == digest(bytes) do
      :ok
    else
      _other -> {:error, :canonical_job_request_mismatch}
    end
  end

  def validate_job(_job), do: {:error, :canonical_job_request_mismatch}

  @doc """
  ## Concept

  Issues one exact trusted-local grant only from an explicit host-policy allow
  decision.

  ## Technical depth

  Grant bindings are projected from the independently built job. The host
  supplies expiry and may carry bounded uninterpreted policy context; neither
  can widen any other binding.
  """
  @spec issue_grant(term(), job_request(), integer(), term()) ::
          {:ok, grant()} | {:error, term()}
  def issue_grant(decision, job, expiry, policy_context \\ nil)

  def issue_grant({:host_policy, :allow}, job, expiry, policy_context)
      when is_integer(expiry) do
    with :ok <- validate_job(job),
         true <- plain?(policy_context) do
      bindings = expected_bindings(job, expiry)
      {:ok, Map.merge(bindings, %{issued_by: :host_policy_allow, policy_context: policy_context})}
    else
      _other -> {:error, :invalid_grant_decision}
    end
  end

  def issue_grant(_decision, _job, _expiry, _policy_context),
    do: {:error, :host_policy_allow_required}

  @doc """
  ## Concept

  Validates every grant binding against the executor's own current facts.

  ## Technical depth

  The caller supplies only transient executor facts that cannot safely be read
  from the grant: current audience, held lease, current fence, and wall clock.
  Job-bound expectations come from the independently validated job. Missing and
  present-but-wrong values return the exact binding that refused start.
  """
  @spec validate_grant(job_request(), grant(), map()) ::
          :ok | {:error, {:missing_binding | :binding_mismatch, atom()}} | {:error, term()}
  def validate_grant(job, grant, current) when is_map(grant) and is_map(current) do
    with :ok <- validate_job(job),
         :ok <- require_issuer(grant),
         {:ok, expiry} <- fetch_binding(grant, :expiry),
         expected <- expected_bindings(job, expiry),
         :ok <- validate_current(expected, current) do
      validate_bindings(grant, expected, @grant_bindings)
    end
  end

  def validate_grant(_job, _grant, _current), do: {:error, :invalid_grant}

  defp expected_bindings(job, expiry) do
    %{
      operation_id: job.operation_id,
      attempt: job.attempt,
      canonical_request_digest: job.canonical_request_digest,
      tool_id: job.tool_id,
      tool_version: job.tool_version,
      effect_class: job.effect_class,
      workspace_lease: job.workspace_lease,
      executor_audience: job.executor_identity,
      expiry: expiry,
      fencing_token: job.fencing_token
    }
  end

  defp validate_current(expected, current) do
    checks = [
      executor_audience: Map.get(current, :executor_identity),
      workspace_lease: Map.get(current, :workspace_lease),
      fencing_token: Map.get(current, :fencing_token)
    ]

    with :ok <- compare_current(expected, checks),
         now when is_integer(now) <- Map.get(current, :now),
         true <- expected.expiry > now do
      :ok
    else
      {:error, field} -> {:error, {:binding_mismatch, field}}
      _other -> {:error, {:binding_mismatch, :expiry}}
    end
  end

  defp compare_current(expected, checks) do
    Enum.reduce_while(checks, :ok, fn {field, actual}, :ok ->
      if Map.fetch!(expected, field) == actual,
        do: {:cont, :ok},
        else: {:halt, {:error, field}}
    end)
  end

  defp validate_bindings(grant, expected, fields) do
    Enum.reduce_while(fields, :ok, fn field, :ok ->
      case Map.fetch(grant, field) do
        :error ->
          {:halt, {:error, {:missing_binding, field}}}

        {:ok, value} ->
          if value == Map.fetch!(expected, field),
            do: {:cont, :ok},
            else: {:halt, {:error, {:binding_mismatch, field}}}
      end
    end)
  end

  defp fetch_binding(grant, field) do
    case Map.fetch(grant, field) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, {:missing_binding, field}}
    end
  end

  defp require_issuer(%{issued_by: :host_policy_allow}), do: :ok
  defp require_issuer(_grant), do: {:error, :host_policy_allow_required}

  defp validate_job_fields(%{
         protocol_version: @protocol_version,
         job_id: job_id,
         operation_id: operation_id,
         attempt: attempt,
         session_id: session_id,
         run_id: run_id,
         turn_id: turn_id,
         tool_call_id: tool_call_id,
         origin_session_epoch: session_epoch,
         origin_executor_epoch: executor_epoch,
         executor_identity: executor_identity,
         required_capabilities: capabilities,
         tool_id: tool_id,
         tool_version: tool_version,
         effect_class: effect_class,
         validated_arguments: arguments,
         workspace_ref: workspace_ref,
         workspace_lease: workspace_lease,
         run_deadline: deadline,
         resource_budgets: budgets,
         idempotency_class: idempotency,
         fencing_token: fencing_token,
         artifact_policy: artifact_policy,
         output_policy: output_policy,
         cleanup_grace_ms: cleanup_grace_ms
       }) do
    identifiers = [
      job_id,
      operation_id,
      session_id,
      run_id,
      turn_id,
      tool_call_id,
      executor_identity,
      tool_id,
      tool_version,
      workspace_ref,
      workspace_lease
    ]

    valid =
      Enum.all?(identifiers, &bounded_binary?/1) and is_integer(attempt) and attempt > 0 and
        is_integer(session_epoch) and session_epoch >= 0 and is_integer(executor_epoch) and
        executor_epoch >= 0 and is_integer(deadline) and deadline > 0 and
        is_integer(fencing_token) and fencing_token >= 0 and bounded_binary?(effect_class) and
        bounded_binary?(idempotency) and plain?(capabilities) and plain?(arguments) and
        plain?(budgets) and plain?(artifact_policy) and plain?(output_policy) and
        is_integer(cleanup_grace_ms) and cleanup_grace_ms >= 1 and
        cleanup_grace_ms <= @max_cleanup_grace_ms

    if valid, do: :ok, else: {:error, :invalid_job_request}
  end

  defp validate_job_fields(_fields), do: {:error, :invalid_job_request}

  defp canonical_bytes(fields) do
    ordered = Enum.map(@job_fields, &{&1, Map.fetch!(fields, &1)})
    {:ok, :erlang.term_to_binary(ordered, [:deterministic])}
  rescue
    _error -> {:error, :invalid_job_request}
  end

  # Concept: the one wall-clock instant past which this job may not act, fixed
  # when the job is built.
  #
  # Technical depth: ADR 0009 lets a request declare a wall-time ceiling beside
  # its run deadline. The earlier of the two is the instant every later
  # effect-authorizing transition compares current wall time against, and it is
  # derived once so a later transition cannot refresh its own allowance by
  # recomputing `now + budget`. It is deliberately outside the digested
  # projection: the digest binds the declared budget and deadline, which are the
  # facts an independent party can recompute, while this instant depends on when
  # the job was built.
  defp effective_job_deadline(%{run_deadline: deadline, resource_budgets: budgets}) do
    case budgets do
      %{"max_wall_time_ms" => budget} when is_integer(budget) and budget > 0 ->
        min(deadline, System.system_time(:millisecond) + budget)

      _no_declared_ceiling ->
        deadline
    end
  end

  defp digest(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  # Technical depth: identifiers are opaque and bounded, never parsed. The bound
  # is eight kibibytes so a full 1,024-entry open index can reach ADR 0016's
  # 4,194,304-byte snapshot ceiling; below that no conforming root could.
  defp bounded_binary?(value), do: is_binary(value) and byte_size(value) in 1..8_192

  defp plain?(value)
       when is_binary(value) or is_integer(value) or is_float(value) or is_boolean(value) or
              is_nil(value),
       do: true

  defp plain?(value) when is_list(value), do: Enum.all?(value, &plain?/1)

  defp plain?(value) when is_map(value) do
    Enum.all?(value, fn {key, nested} -> is_binary(key) and plain?(nested) end)
  end

  defp plain?(_value), do: false
end
