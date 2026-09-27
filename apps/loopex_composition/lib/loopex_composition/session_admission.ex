defmodule LoopexComposition.SessionAdmission do
  @moduledoc """
  ## Concept

  The composition routes private model and tool admission to the same serial
  session owner. It grants no authority independently of that owner.

  ## Technical depth

  One monitored asynchronous request binds requester, generation, reference,
  operation and absolute native expiry. Receive waits are capped at 1,000 ms
  and never renew that expiry. The owner checks its session cell. Cleanup-only
  custody carries no cell and admits only retirement or cancellation for its
  recorded candidate and call. The owner validates state transitions and
  one-use tokens; neither inward edge imports this implementation.
  """

  @behaviour Loopex.LLM.ReqLLM.InProcess.Admission
  # Concept: one request implementation satisfies both inward admission ports.
  # Technical depth: both declare request/3; annotating both produces Elixir's
  # conflicting-behaviours warning. The conformance test checks both contracts;
  # the single annotation retains compiler checking without suppressing warnings.

  @doc false
  def handle(owner, generation, cell), do: {__MODULE__, owner, generation, cell}

  @doc false
  @impl true
  @spec request(
          term(),
          Loopex.LLM.ReqLLM.InProcess.Admission.operation()
          | Loopex.Executor.Local.EphemeralAdmission.operation(),
          integer()
        ) :: Loopex.LLM.ReqLLM.InProcess.Admission.result()
  def request(handle, operation, deadline) when is_integer(deadline) do
    with {:ok, owner, generation} <- route(handle, operation),
         true <- System.monotonic_time() < deadline do
      reference = make_ref()
      monitor = Process.monitor(owner)

      try do
        send(
          owner,
          {:loopex_session_admission, self(), reference, generation, operation, deadline}
        )

        await(owner, monitor, reference, generation, operation, deadline)
      after
        Process.demonitor(monitor, [:flush])
      end
    else
      _ -> closed()
    end
  catch
    _, _ -> closed()
  end

  def request(_handle, _operation, _deadline), do: closed()

  defp route({__MODULE__, owner, generation, cell}, _operation)
       when is_pid(owner) and is_reference(generation) and is_reference(cell),
       do: {:ok, owner, generation}

  defp route(
         {:model_cleanup_custody, owner, generation, call, candidate, proof},
         {:retire_model, call, candidate, proof}
       )
       when is_pid(owner) and is_reference(generation) and is_reference(call) and
              is_pid(candidate) and is_reference(proof) and candidate == self(),
       do: {:ok, owner, generation}

  defp route(
         {:model_cleanup_custody, owner, generation, call, candidate, proof},
         {:cancel_model, call, _start_proof}
       )
       when is_pid(owner) and is_reference(generation) and is_reference(call) and
              is_pid(candidate) and is_reference(proof) and candidate == self(),
       do: {:ok, owner, generation}

  defp route(_handle, _operation), do: closed()

  defp await(owner, monitor, reference, generation, operation, deadline) do
    if System.monotonic_time() < deadline do
      receive do
        {:loopex_session_admission_result, ^owner, ^reference, ^generation, ^operation, ^deadline,
         result} ->
          validate_result(result, generation, reference, operation, deadline)

        {:DOWN, ^monitor, :process, ^owner, _reason} ->
          closed()
      after
        remaining_slice(deadline) ->
          await(owner, monitor, reference, generation, operation, deadline)
      end
    else
      closed()
    end
  end

  defp validate_result(
         {:ok, {:session_grant, generation, tag, requester, reference, deadline}} = result,
         generation,
         reference,
         operation,
         deadline
       ) do
    if requester == self() and tag == elem(operation, 0) and
         System.monotonic_time() < deadline,
       do: result,
       else: closed()
  end

  defp validate_result(_result, _generation, _reference, _operation, _deadline), do: closed()

  defp remaining_slice(deadline) do
    remaining = max(deadline - System.monotonic_time(), 0)
    milliseconds = System.convert_time_unit(remaining, :native, :millisecond)

    rounded =
      milliseconds +
        if(System.convert_time_unit(milliseconds, :millisecond, :native) < remaining,
          do: 1,
          else: 0
        )

    min(rounded, 1_000)
  end

  defp closed, do: {:error, :session_admission_closed}
end
