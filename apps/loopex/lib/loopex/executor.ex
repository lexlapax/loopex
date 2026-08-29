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

  @job_fields [
    :protocol_version,
    :job_id,
    :operation_id,
    :attempt,
    :session_id,
    :run_id,
    :turn_id,
    :tool_call_id,
    :origin_session_epoch,
    :origin_executor_epoch,
    :executor_identity,
    :required_capabilities,
    :tool_id,
    :tool_version,
    :effect_class,
    :validated_arguments,
    :workspace_ref,
    :workspace_lease,
    :run_deadline,
    :resource_budgets,
    :idempotency_class,
    :fencing_token,
    :artifact_policy,
    :output_policy
  ]

  @typedoc """
  ## Concept

  One immutable executor request with its independently checkable digest.

  ## Technical depth

  The job carries the complete M1 origin tuple and bounded plain semantic data.
  `canonical_request_bytes` and `canonical_request_digest` bind exactly the
  ordered fields returned by `job_fields/0`.
  """
  @type job_request :: map()

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

  Plain data carrying the job's complete origin tuple — the call and operation it
  belongs to, that operation's attempt, the session, run, and turn, the
  attempt-bound `canonical_request_digest`, both origin epochs, the executor's
  identity, and its fencing token — followed by the stream it came from, a byte
  offset, and a bounded chunk.

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
          required(:stream) => binary(),
          required(:byte_offset) => non_neg_integer(),
          required(:chunk) => binary()
        }

  @typedoc """
  ## Concept

  The function an executor calls to report one progress event.

  ## Technical depth

  An ordinary in-VM function reference in the trailing argument position. That
  one parameter is the whole executor-boundary change; an executor that emits
  nothing stays conformant, returns the same receipt, and reports a
  `progress_count` of zero rather than a sentinel or an absent field.
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
  must then finish `outcome_unknown` rather than claiming a clean stop. A job
  that was never running, or already finished, is trivially clean.

  Optional, because an executor with nothing to cancel — one that performs only
  in-VM work — has nothing to implement. A caller treats its absence as
  `{:ok, :cleaned}` for the same reason.
  """
  @callback cancel(reference :: term(), job_id :: binary()) ::
              {:ok, :cleaned} | {:ok, :unconfirmed} | {:error, term()}

  @optional_callbacks cancel: 2

  @doc """
  ## Concept

  Asks an executor to stop a job, tolerating one that cannot.

  ## Technical depth

  An executor that does not implement `cancel/2` has no operating-system work to
  leave behind, so its cleanup is confirmed by construction. Anything the call
  raises or returns outside the two admitted shapes is treated as unconfirmed:
  the safe reading of "I could not tell you" is that something may still be
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
      bounded_cancel(module, reference, job_id)
    else
      # Concept: an executor that declares no cancellation has confirmed
      # nothing, and silence is not a clean stop.
      #
      # Technical depth: this used to answer `cleaned`, on the reasoning that an
      # implementation without the callback has nothing to leave behind. That is
      # a statement about the implementation this repository ships, not about the
      # port: a conforming third-party executor may own an operating-system
      # process and not export `cancel/2`, and reading its silence as confirmed
      # cleanup committed `cancelled` for a tree nobody signalled and nobody
      # looked at. `unconfirmed` is what this runtime actually knows, and it ends
      # the run `outcome_unknown` with a reconciliation reference instead.
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
  defp bounded_cancel(module, reference, job_id) do
    {pid, monitor} =
      spawn_monitor(fn -> exit({:loopex_cancel_answer, module.cancel(reference, job_id)}) end)

    receive do
      {:DOWN, ^monitor, :process, ^pid, {:loopex_cancel_answer, answer}} ->
        admitted_cancel(answer)

      {:DOWN, ^monitor, :process, ^pid, _abnormal} ->
        {:ok, :unconfirmed}
    after
      @cancel_bound_ms ->
        Process.demonitor(monitor, [:flush])
        Process.exit(pid, :kill)
        {:ok, :unconfirmed}
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
  @default_cleanup_grace_ms 5_000

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
    with true <- Map.keys(fields) |> Enum.sort() == Enum.sort(@job_fields),
         :ok <- validate_job_fields(fields),
         {:ok, bytes} <- canonical_bytes(fields) do
      {:ok,
       fields
       |> Map.put(:canonical_request_bytes, bytes)
       |> Map.put(:canonical_request_digest, digest(bytes))}
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
         output_policy: output_policy
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
        plain?(budgets) and plain?(artifact_policy) and plain?(output_policy)

    if valid, do: :ok, else: {:error, :invalid_job_request}
  end

  defp validate_job_fields(_fields), do: {:error, :invalid_job_request}

  defp canonical_bytes(fields) do
    ordered = Enum.map(@job_fields, &{&1, Map.fetch!(fields, &1)})
    {:ok, :erlang.term_to_binary(ordered, [:deterministic])}
  rescue
    _error -> {:error, :invalid_job_request}
  end

  defp digest(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  defp bounded_binary?(value), do: is_binary(value) and byte_size(value) in 1..1_024

  defp plain?(value)
       when is_binary(value) or is_integer(value) or is_boolean(value) or is_nil(value),
       do: true

  defp plain?(value) when is_list(value), do: Enum.all?(value, &plain?/1)

  defp plain?(value) when is_map(value) do
    Enum.all?(value, fn {key, nested} -> is_binary(key) and plain?(nested) end)
  end

  defp plain?(_value), do: false
end
