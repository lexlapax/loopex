defmodule LoopexComposition.SessionAdmission do
  @moduledoc """
  ## Concept

  The composition routes private model and tool admission to the same serial
  session owner. It grants no authority independently of that owner.

  ## Technical depth

  One monitored asynchronous request binds requester, generation, reference,
  operation and absolute native expiry. The complete handshake is capped at
  1,000 ms or the supplied expiry, whichever is earlier. Sliced receives never
  renew that expiry. The owner checks its session cell. Cleanup-only
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
    deadline =
      min(
        deadline,
        System.monotonic_time() + System.convert_time_unit(1_000, :millisecond, :native)
      )

    with {:ok, owner, generation} <- route(handle, operation),
         true <- System.monotonic_time() < deadline do
      reference = make_ref()
      monitor = Process.monitor(owner)

      try do
        send(
          owner,
          {:loopex_session_admission, self(), reference, generation, operation, deadline}
        )

        case operation do
          {:cancel_model, _call,
           {:registration_refused, registration, candidate, candidate_monitor}}
          when registration == :unmanaged or
                 registration == {:error, :provider_resource_refused} ->
            if is_pid(candidate) and is_reference(candidate_monitor) do
              await_registrar_cancel(
                owner,
                monitor,
                reference,
                generation,
                operation,
                deadline,
                candidate,
                candidate_monitor
              )
            else
              closed()
            end

          _ ->
            await(owner, monitor, reference, generation, operation, deadline)
        end
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

  # Concept: the caller cannot report a clean registrar refusal until its
  # candidate is actually gone and the session owner independently agrees.
  # Technical depth: only exact owner-origin preparation authorizes this
  # helper to kill the candidate. Missing preparation spends at most half the
  # control deadline; the model callback owns fallback reaping with its
  # already-held candidate monitor, not this generic admission helper.
  defp await_registrar_cancel(
         owner,
         owner_monitor,
         reference,
         generation,
         operation,
         deadline,
         candidate,
         candidate_monitor
       ) do
    now = System.monotonic_time()
    preparation_deadline = now + div(max(deadline - now, 0), 2)

    prepared? =
      await_cancellation_prepared(
        owner,
        owner_monitor,
        reference,
        generation,
        operation,
        deadline,
        candidate,
        preparation_deadline
      )

    if prepared? do
      Process.exit(candidate, :kill)

      await_cancellation_completion(
        owner,
        owner_monitor,
        reference,
        generation,
        operation,
        deadline,
        candidate,
        candidate_monitor,
        false,
        nil
      )
    else
      closed()
    end
  end

  defp await_cancellation_prepared(
         owner,
         owner_monitor,
         reference,
         generation,
         operation,
         deadline,
         candidate,
         preparation_deadline
       ) do
    if System.monotonic_time() < preparation_deadline do
      receive do
        {:loopex_session_admission_cancellation_prepared, ^owner, ^reference, ^generation,
         ^operation, ^deadline, ^candidate} ->
          true

        {:DOWN, ^owner_monitor, :process, ^owner, _reason} ->
          false
      after
        remaining_slice(preparation_deadline) ->
          await_cancellation_prepared(
            owner,
            owner_monitor,
            reference,
            generation,
            operation,
            deadline,
            candidate,
            preparation_deadline
          )
      end
    else
      false
    end
  end

  defp await_cancellation_completion(
         owner,
         owner_monitor,
         reference,
         generation,
         operation,
         deadline,
         candidate,
         candidate_monitor,
         candidate_down?,
         result
       ) do
    cond do
      candidate_down? and result != nil and System.monotonic_time() < deadline ->
        result

      System.monotonic_time() >= deadline ->
        closed()

      true ->
        receive do
          {:DOWN, ^candidate_monitor, :process, ^candidate, _reason} ->
            await_cancellation_completion(
              owner,
              owner_monitor,
              reference,
              generation,
              operation,
              deadline,
              candidate,
              candidate_monitor,
              true,
              result
            )

          {:loopex_session_admission_result, ^owner, ^reference, ^generation, ^operation,
           ^deadline, final_result} ->
            final_result =
              validate_result(final_result, generation, reference, operation, deadline)

            result =
              cond do
                result == nil -> final_result
                result == final_result -> result
                true -> closed()
              end

            await_cancellation_completion(
              owner,
              owner_monitor,
              reference,
              generation,
              operation,
              deadline,
              candidate,
              candidate_monitor,
              candidate_down?,
              result
            )

          {:DOWN, ^owner_monitor, :process, ^owner, _reason} ->
            await_cancellation_completion(
              owner,
              owner_monitor,
              reference,
              generation,
              operation,
              deadline,
              candidate,
              candidate_monitor,
              candidate_down?,
              result
            )
        after
          remaining_slice(deadline) ->
            await_cancellation_completion(
              owner,
              owner_monitor,
              reference,
              generation,
              operation,
              deadline,
              candidate,
              candidate_monitor,
              candidate_down?,
              result
            )
        end
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
