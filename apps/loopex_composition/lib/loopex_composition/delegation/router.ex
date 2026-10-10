defmodule LoopexComposition.Delegation.Router do
  @moduledoc """
  ## Concept

  The executor a helper-capable durable host gives its runtime. It sends the
  fixed `loopex.task` generation to the helper owner and every other job to the
  local executor unchanged.

  ## Technical depth

  ADR 0046's composite router. Local requests, receipts and cancellation pass
  through byte-for-byte; the owner only records each live local job ID so a
  later cancel classifies it as local. A cancel the owner does not recognize
  leaves an incarnation-local tombstone before it is forwarded, so a delayed
  helper registration of that ID refuses. Receipt lookup asks the owner's
  helper index first and falls back to Local only for a non-helper ID. A helper
  job first passes Core's standard grant validation against the wrapped
  executor's audience, lease and fence, so a refused grant never reaches the
  owner and reserves nothing.
  """

  @behaviour Loopex.Executor

  alias LoopexComposition.Delegation.{Helper, Tool}

  @doc false
  def wrap(executor, helper) when is_map(executor) and is_pid(helper),
    do: %{
      executor
      | module: __MODULE__,
        reference: %{
          helper: helper,
          local: {executor.module, executor.reference},
          audience: Map.take(executor, [:identity, :epoch, :fencing_token, :workspace_lease])
        }
    }

  @impl true
  def execute(
        %{helper: helper, local: {module, reference}} = router,
        job,
        grant,
        options,
        progress
      ) do
    if job.tool_id == Tool.definition()["tool_id"] do
      case prestart(router.audience, job, grant) do
        :ok -> Helper.execute(helper, job)
        {:error, reason} -> {:error, {:refused_before_effect, reason}}
      end
    else
      case Helper.register_local(helper, job.job_id) do
        :ok ->
          try do
            module.execute(reference, job, grant, options, progress)
          after
            Helper.unregister_local(helper, job.job_id)
          end

        refusal ->
          refusal
      end
    end
  end

  # Concept: a helper job is an executor effect, so it passes the same grant
  # check as a local job before anything is reserved or created.
  # Technical depth: ADR 0046 keeps grant validation unchanged on the helper
  # branch. `Loopex.Executor.validate_grant/3` checks the job and all ten grant
  # bindings against this executor's audience, held lease, fence and the wall
  # clock; a job naming another audience or executor epoch refuses
  # `executor_prestart_mismatch`, exactly as the local executor does.
  defp prestart(audience, job, grant) do
    with :ok <-
           Loopex.Executor.validate_grant(job, grant, %{
             executor_identity: audience.identity,
             workspace_lease: audience.workspace_lease,
             fencing_token: audience.fencing_token,
             now: System.system_time(:millisecond)
           }) do
      if job.executor_identity == audience.identity and
           job.origin_executor_epoch == audience.epoch,
         do: :ok,
         else: {:error, :executor_prestart_mismatch}
    end
  end

  @impl true
  def cancel(%{helper: helper, local: {module, reference}}, job_id) do
    case Helper.cancel(helper, job_id) do
      {:stopped, child} -> observe(child)
      {:ok, _confirmation} = answer -> answer
      _local_or_unknown -> module.cancel(reference, job_id)
    end
  end

  # Concept: a helper stop is cleaned only once the child's run has ended.
  # Technical depth: the bound is derived once from the parent job's committed
  # grace and Core's executor observation window, less a fixed reply margin.
  # Missing that bound answers unconfirmed; it never rewrites the parent.
  defp observe(child) do
    {:ok, bounds} = Loopex.Executor.cancellation_bounds(child.grace)
    deadline = System.monotonic_time(:millisecond) + bounds.executor_observe_ms - 250
    observe(child, deadline)
  end

  defp observe(child, deadline) do
    case Loopex.Runtime.run_evidence(child.runtime, child.session, child.run) do
      {:ok, %{terminal: %{}}} ->
        {:ok, :cleaned}

      _ ->
        if System.monotonic_time(:millisecond) >= deadline do
          {:ok, :unconfirmed}
        else
          Process.sleep(20)
          observe(child, deadline)
        end
    end
  end

  @impl true
  def retained_receipt(%{helper: helper, local: {module, reference}}, job_id) do
    case Helper.retained_receipt(helper, job_id) do
      :not_helper ->
        if function_exported?(module, :retained_receipt, 2),
          do: module.retained_receipt(reference, job_id),
          else: {:error, :receipt_lookup_unsupported}

      answer ->
        answer
    end
  end
end
