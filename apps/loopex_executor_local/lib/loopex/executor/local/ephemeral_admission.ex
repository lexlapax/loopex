defmodule Loopex.Executor.Local.EphemeralAdmission do
  @moduledoc """
  ## Concept

  The local executor asks its host's session owner for permission to dispatch
  one ephemeral tool. This inward boundary imports neither composition nor a
  model-edge implementation.

  ## Technical depth

  The host implements `request/3`; `request/4` accepts only a correlated live
  tool grant. The host owns generation, executor-instance and one-use checks.
  The executor still checks its session cell immediately before effects.
  Handles and grants are private in-VM data, never job or receipt members.
  """

  @type operation :: {:tool_grant, pid(), reference(), reference()}
  @type grant ::
          {:session_grant, reference(), :tool_grant, pid(), reference(), integer()}
  @type result :: {:ok, grant()} | {:error, :session_admission_closed}

  @doc """
  ## Concept

  The host answers one session-local tool admission request.

  ## Technical depth

  It monitors the requesting process and correlates the exact operation,
  generation, message reference and native expiry before returning a grant.
  """
  @callback request(term(), operation(), integer()) :: result()

  @doc false
  @spec request(module(), term(), operation(), integer()) :: result()
  def request(module, handle, {:tool_grant, executor, instance, dispatch} = operation, deadline)
      when is_atom(module) and is_pid(executor) and is_reference(instance) and
             is_reference(dispatch) and is_integer(deadline) do
    if System.monotonic_time() < deadline do
      module.request(handle, operation, deadline) |> admit_return(deadline)
    else
      closed()
    end
  catch
    _, _ -> closed()
  end

  def request(_module, _handle, _operation, _deadline), do: closed()

  defp admit_return(
         {:ok, {:session_grant, generation, :tool_grant, requester, reference, expiry}} = result,
         deadline
       )
       when is_reference(generation) and is_reference(reference) and is_integer(expiry) do
    if requester == self() and expiry <= deadline and System.monotonic_time() < expiry,
      do: result,
      else: closed()
  end

  defp admit_return(_result, _deadline), do: closed()
  defp closed, do: {:error, :session_admission_closed}
end
