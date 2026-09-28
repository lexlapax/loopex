defmodule Loopex.LLM.ReqLLM.InProcess.Admission do
  @moduledoc """
  ## Concept

  The model edge asks its host's session owner for permission to advance a call.
  This private boundary contains no composition implementation or authority of
  its own.

  ## Technical depth

  The host implements `request/3`; the edge invokes it through `request/4`.
  Grants bind the requesting process, operation and native monotonic expiry.
  The host owns generation checks, one-use admission and the pending-call
  census. Completion acknowledgements use a fresh control expiry, not an
  expired activation grant. Handles and grants never enter durable data.
  """

  @type operation ::
          {:begin_model, pid(), reference()}
          | {:stage_model, reference(), pid(), reference(), reference(), term()}
          | {:register_model, reference(), pid(), reference()}
          | {:record_model_resources, reference(), pid(), pos_integer(), list()}
          | {:retire_model, reference(), pid(), reference()}
          | {:cancel_model, reference(), term()}
  @type grant ::
          {:session_grant, reference(), atom(), pid(), reference(), integer()}
  @type result ::
          {:ok, grant()} | {:error, :session_admission_closed | :model_stage_cancelled}

  @doc """
  ## Concept

  The host answers one session-local model admission request.

  ## Technical depth

  The callback must finish within the supplied absolute native expiry. It
  monitors its requester and correlates its asynchronous request and reply.
  It must never turn cleanup-only custody into a work grant.
  """
  @callback request(term(), operation(), integer()) :: result()

  @doc false
  @spec request(module(), term(), operation(), integer()) :: result()
  def request(module, handle, operation, deadline)
      when is_atom(module) and is_integer(deadline) do
    deadline =
      min(
        deadline,
        System.monotonic_time() + System.convert_time_unit(1_000, :millisecond, :native)
      )

    if known_operation?(operation) and System.monotonic_time() < deadline do
      module.request(handle, operation, deadline)
      |> admit_return(operation, deadline)
    else
      closed()
    end
  catch
    _, _ -> closed()
  end

  def request(_module, _handle, _operation, _deadline), do: closed()

  defp known_operation?({:begin_model, pid, ref}), do: is_pid(pid) and is_reference(ref)

  defp known_operation?({:stage_model, ref, pid, proof, stop, _start_proof}),
    do: is_reference(ref) and is_pid(pid) and is_reference(proof) and is_reference(stop)

  defp known_operation?({:register_model, ref, pid, proof}),
    do: is_reference(ref) and is_pid(pid) and is_reference(proof)

  defp known_operation?({:record_model_resources, ref, pid, revision, entries}),
    do:
      is_reference(ref) and is_pid(pid) and is_integer(revision) and revision > 0 and
        is_list(entries)

  defp known_operation?({:retire_model, ref, pid, proof}),
    do: is_reference(ref) and is_pid(pid) and is_reference(proof)

  defp known_operation?({:cancel_model, ref, _start_proof}), do: is_reference(ref)
  defp known_operation?(_operation), do: false

  defp admit_return(
         {:ok, {:session_grant, generation, tag, requester, reference, expiry}} = result,
         operation,
         deadline
       )
       when is_reference(generation) and is_reference(reference) and is_integer(expiry) do
    if requester == self() and tag == elem(operation, 0) and expiry <= deadline and
         System.monotonic_time() < expiry,
       do: result,
       else: closed()
  end

  # Concept: only the host's independently settled staging record can report
  # a clean pre-registrar cancellation.
  # Technical depth: this status is not a general refusal; a timeout or a
  # closed route remains ambiguous and cannot authorize candidate reaping.
  defp admit_return(
         {:error, :model_stage_cancelled} = result,
         {:stage_model, _, _, _, _, _},
         deadline
       ) do
    if System.monotonic_time() < deadline, do: result, else: closed()
  end

  defp admit_return(_result, _operation, _deadline), do: closed()
  defp closed, do: {:error, :session_admission_closed}
end
