defmodule LoopexComposition.Restore do
  @moduledoc """
  ## Concept

  Offline current-format physical restore and bounded transaction lookup.

  ## Technical depth

  One original Restore.IO invocation owns complete audit, copy, source retirement,
  candidate publication and terminal claim release. Complete prior lineage is
  validated before appending the next ordinal. Original-transaction resolution
  reuses retained candidates under the host's exclusion and prior-owner evidence.
  A quiescent helper namespace restores only when every member passes the
  helper decoders and each task receipt matches its run log; anything else refuses.
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

  @doc """
  ## Concept

  Restore or resolve one offline current-format physical transaction.

  ## Technical depth

  ADR 0051 fixes the closed plan, invocation and result grammar. One monitored
  raw-IO administrator carries the original transaction through canonical
  publication and bounded claim cleanup. A returned receipt grants no live
  authority. The host must preserve its exclusion and prior-owner attestations.
  """
  @spec restore(map(), map()) ::
          {:committed, map()}
          | {:not_committed, map()}
          | {:cleanup_unconfirmed, map()}
          | {:commit_unknown, map()}
  def restore(plan, invocation), do: restore_validated(plan, invocation, [])

  # Concept: evidence oracles read restore artifacts through the composition.
  # Technical depth: read-only delegations to the shipped codec and guard, so a
  # host-side checker names no executor implementation.
  @doc false
  def manifest(bytes, max_total), do: RestoreCodec.manifest(bytes, max_total)
  @doc false
  def generation(bytes), do: RestoreCodec.decode(:generation, bytes)
  @doc false
  def source_state(root), do: Loopex.Executor.Local.RestoreGuard.state(root)

  # Concept: trusted fixtures exercise the same validated facade outcome flow.
  # Technical depth: options reach only the existing native IO probe gates; the
  # public plan and invocation grammar have no scheduling or fixture members.
  @doc false
  def test_restore(plan, invocation, options), do: restore_validated(plan, invocation, options)

  defp restore_validated(plan, invocation, options) do
    with {:ok, _} <- RestoreCodec.encode(:plan, plan),
         {:ok, _} <- RestoreCodec.encode(:invocation, invocation),
         limits = Map.take(invocation, ["work_ms", "cleanup_grace_ms"]),
         {:ok, _} <- RestoreCodec.limits(limits) do
      if plan["prior_restore_count"] == 64 do
        refusal(plan["tx_id"], "inventory_limit_exceeded", "claim", "none")
      else
        RestoreIO.run({:restore_driver, plan, invocation}, limits, options)
        |> restore_result(plan["tx_id"])
      end
    else
      _ -> refusal(valid_tx(plan), "invalid_plan", "claim", "none")
    end
  end

  defp restore_result(
         {:joined, {:ok, %{restore_result: {:committed, receipt}, release_claims: []}},
          %{restore_observation: %{"cleanup" => "joined", "claim" => "none"}}},
         _tx_id
       ),
       do: checked(:receipt, {:committed, receipt})

  defp restore_result({:joined, payload, %{restore_observation: observation}}, tx_id) do
    if observation["intent"] == "absent" do
      refusal(tx_id, refusal_code(payload), observation["phase"], observation["claim"])
    else
      checked(:observation, {:commit_unknown, observation})
    end
  end

  defp restore_result({:unconfirmed, _reason, %{restore_observation: observation}}, _tx_id) do
    tag = if observation["intent"] == "absent", do: :cleanup_unconfirmed, else: :commit_unknown
    checked(:observation, {tag, observation})
  end

  # Concept: an unavailable administrator cannot prove noncommit.
  # Technical depth: this closed fallback retains uncertainty without raw process
  # or OS terms. Valid input reaches this branch only when ownership proof is lost.
  defp restore_result(_result, tx_id),
    do:
      checked(
        :observation,
        {:commit_unknown,
         %{
           "kind" => "loopex_current_restore_observation_v1",
           "tx_id" => tx_id,
           "ordinal" => nil,
           "phase" => "claim",
           "intent" => "may_exist",
           "cleanup" => "unconfirmed",
           "claim" => "retained",
           "reason" => "worker_unjoined"
         }}
      )

  defp refusal_code({:ok, %{restore_result: {:not_committed, code}}}) when is_binary(code),
    do: code

  defp refusal_code(_), do: "inventory_unavailable"

  defp refusal(tx_id, code, phase, claim),
    do:
      checked(
        :refusal,
        {:not_committed,
         %{
           "kind" => "loopex_current_restore_refusal_v1",
           "tx_id" => tx_id,
           "code" => code,
           "phase" => phase,
           "cleanup" => "joined",
           "claim" => claim
         }}
      )

  defp checked(type, {_tag, value} = result) do
    {:ok, _} = RestoreCodec.encode(type, value)
    result
  end

  defp valid_tx(%{"tx_id" => tx_id}) when is_binary(tx_id),
    do: if(Regex.match?(~r/\A[0-9a-f]{64}\z/, tx_id), do: tx_id, else: nil)

  defp valid_tx(_), do: nil
end
