defmodule LoopexComposition.Restore do
  @moduledoc """
  ## Concept

  Private development entry for current physical restore transitions, with an
  available or lost source. ADR 0051's public restore and lookup remain unfinished.

  ## Technical depth

  One original Restore.IO invocation owns complete audit, copy, source retirement,
  candidate publication and terminal claim release. Complete prior lineage is
  validated before appending the next ordinal. Original-tx resolution and the
  complete helper grammar remain unfinished. A supported current plan outside
  this private workstream is reported as unfinished
  development, never mislabeled invalid input or acknowledged as restored.
  """

  alias Loopex.Executor.Local.RestoreCodec
  alias LoopexComposition.Restore.IO, as: RestoreIO

  @doc false
  def first(plan, invocation, options \\ []) do
    with {:ok, _} <- RestoreCodec.encode(:plan, plan),
         {:ok, _} <- RestoreCodec.encode(:invocation, invocation) do
      if invocation["prior_admin_authority"] == "none" do
        limits = Map.take(invocation, ["work_ms", "cleanup_grace_ms"])
        RestoreIO.run({:restore_first, plan, invocation}, limits, options)
      else
        {:development_incomplete, :original_tx_continuation}
      end
    else
      _ -> {:error, :invalid_restore_input}
    end
  end
end
