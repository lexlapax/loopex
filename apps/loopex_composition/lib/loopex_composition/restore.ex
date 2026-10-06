defmodule LoopexComposition.Restore do
  @moduledoc """
  ## Concept

  Private development entry for the first available-source current physical
  restore. This module does not yet expose ADR 0051's public restore or lookup.

  ## Technical depth

  One original Restore.IO invocation owns complete audit, copy, source retirement,
  candidate publication and terminal claim release. Lost source, repeated lineage,
  original-tx resolution and the complete helper grammar remain unfinished. A
  supported current plan outside this private workstream is reported as unfinished
  development, never mislabeled invalid input or acknowledged as restored.
  """

  alias Loopex.Executor.Local.RestoreCodec
  alias LoopexComposition.Restore.IO, as: RestoreIO

  @doc false
  def available_first(plan, invocation, options \\ []) do
    with {:ok, _} <- RestoreCodec.encode(:plan, plan),
         {:ok, _} <- RestoreCodec.encode(:invocation, invocation) do
      if plan["source_status"] == "available" and plan["prior_restore_count"] == 0 and
           invocation["prior_admin_authority"] == "none" do
        limits = Map.take(invocation, ["work_ms", "cleanup_grace_ms"])
        RestoreIO.run({:restore_available_first, plan, invocation}, limits, options)
      else
        {:development_incomplete, :available_first_only}
      end
    else
      _ -> {:error, :invalid_restore_input}
    end
  end
end
