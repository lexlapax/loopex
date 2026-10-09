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
  helper index first and falls back to Local only for a non-helper ID.
  """

  @behaviour Loopex.Executor

  alias LoopexComposition.Delegation.{Helper, Tool}

  @doc false
  def wrap(executor, helper) when is_map(executor) and is_pid(helper),
    do: %{
      executor
      | module: __MODULE__,
        reference: %{helper: helper, local: {executor.module, executor.reference}}
    }

  @impl true
  def execute(%{helper: helper, local: {module, reference}}, job, grant, options, progress) do
    if job.tool_id == Tool.definition()["tool_id"] do
      Helper.execute(helper, job)
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

  @impl true
  def cancel(%{helper: helper, local: {module, reference}}, job_id) do
    case Helper.cancel(helper, job_id) do
      {:ok, _confirmation} = answer -> answer
      _local_or_unknown -> module.cancel(reference, job_id)
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
