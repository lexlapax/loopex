defmodule LoopexComposition.Restore do
  @moduledoc """
  ## Concept

  Private development entry for current physical restore transitions, with an
  available or lost source, and bounded public read-only transaction lookup.

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

  @doc """
  ## Concept

  Read retained restore completion or uncertainty without granting authority.

  ## Technical depth

  ADR 0051 fixes current/historical receipts, pending observations and present
  absence. One monitored raw-IO invocation owns the reads and original explicit
  work/cleanup limits. Lookup never writes, reclaims, continues or activates.
  """
  @spec lookup(binary(), binary(), map()) ::
          {:committed, map()} | {:pending, map()} | {:absent, map()} | {:error, map()}
  def lookup(root, tx_id, limits) do
    valid_tx = is_binary(tx_id) and Regex.match?(~r/\A[0-9a-f]{64}\z/, tx_id)

    if valid_lookup_root?(root) and valid_tx and match?({:ok, _}, RestoreCodec.limits(limits)) do
      case RestoreIO.run({:restore_lookup, root, tx_id}, limits) do
        {:joined, {:ok, result}, _evidence} ->
          result

        {:joined, {:error, :deadline}, _evidence} ->
          lookup_error(tx_id, "deadline", "joined")

        {:joined, {:error, _}, _evidence} ->
          lookup_error(tx_id, "administrative_path_unavailable", "joined")

        {:unconfirmed, _reason} ->
          lookup_error(tx_id, "cleanup_unconfirmed", "unconfirmed")

        _ ->
          lookup_error(tx_id, "cleanup_unconfirmed", "unconfirmed")
      end
    else
      lookup_error(if(valid_tx, do: tx_id, else: nil), "invalid_query", "joined")
    end
  end

  defp valid_lookup_root?(root),
    do:
      is_binary(root) and byte_size(root) in 1..8192 and String.valid?(root) and
        not String.contains?(root, <<0>>) and Path.type(root) == :absolute and
        Path.expand(root) == root

  defp lookup_error(tx_id, code, cleanup),
    do:
      {:error,
       %{
         "kind" => "loopex_current_restore_lookup_refusal_v1",
         "tx_id" => tx_id,
         "code" => code,
         "cleanup" => cleanup
       }}

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
