defmodule Mix.Tasks.Loopex.M7Evidence.AttemptHeads do
  @moduledoc """
  ## Concept

  Select the retained committed anchor for one M7 campaign before accepting an
  attempts index. The greatest sequence is authoritative regardless of line
  order. Missing evidence, malformed relevant lines and conflicting retained
  digests refuse; a selected head grants no ownership or dispatch authority.

  ## Technical depth

  Input is the checked-out Concept text and the manifest-pinned campaign ID.
  Relevant lines must exactly match `index-head: <campaign_id> <sequence>
  <sha256>`, with single ASCII spaces, a positive decimal sequence without
  leading zeroes and a lower-case SHA-256 digest. Every relevant line is checked,
  including lower sequences; duplicate identical heads are allowed. Foreign
  campaign lines are left to the separate succession-event admission check.

  `verify/3` passes the selected anchor to `AttemptFrames.verify/2`, which proves
  its exact occurrence in the complete presented chain. Neither helper opens
  files, interprets ownership events or permits dispatch.
  """

  alias Mix.Tasks.Loopex.M7Evidence.AttemptFrames

  @line ~r/\Aindex-head: (\S+) ([1-9][0-9]*) ([0-9a-f]{64})\z/u
  @candidate ~r/\Aindex-head:\s*(\S*)/u

  @doc false
  def select(text, campaign) when is_binary(text) and is_binary(campaign) do
    if String.valid?(text) and String.valid?(campaign) and
         Regex.match?(~r/\A\S+\z/u, campaign) do
      text
      |> String.split("\n")
      |> Enum.reduce_while({:ok, %{}}, fn line, {:ok, heads} ->
        case retain(line, campaign, heads) do
          {:ok, heads} -> {:cont, {:ok, heads}}
          error -> {:halt, error}
        end
      end)
      |> greatest(campaign)
    else
      {:error, :invalid_committed_attempt_head_lines}
    end
  end

  def select(_, _), do: {:error, :invalid_committed_attempt_head_lines}

  @doc false
  def verify(text, campaign, bytes) do
    with {:ok, head} <- select(text, campaign) do
      if is_binary(bytes),
        do: AttemptFrames.verify(bytes, head),
        else: {:error, :attempt_index_unavailable}
    end
  end

  defp retain(line, campaign, heads) do
    case Regex.run(@candidate, String.trim_leading(line)) do
      [_, ^campaign] -> retain_relevant(line, campaign, heads)
      _ -> {:ok, heads}
    end
  end

  defp retain_relevant(line, campaign, heads) do
    case Regex.run(@line, line) do
      [_, ^campaign, decimal, digest] ->
        sequence = String.to_integer(decimal)

        case Map.fetch(heads, sequence) do
          {:ok, ^digest} -> {:ok, heads}
          {:ok, _} -> {:error, :conflicting_committed_attempt_heads}
          :error -> {:ok, Map.put(heads, sequence, digest)}
        end

      _ ->
        {:error, :invalid_committed_attempt_head_line}
    end
  end

  defp greatest({:ok, heads}, _) when map_size(heads) == 0,
    do: {:error, :committed_attempt_head_unavailable}

  defp greatest({:ok, heads}, campaign) do
    {sequence, digest} = Enum.max_by(heads, fn {sequence, _} -> sequence end)
    {:ok, %{"campaign_id" => campaign, "sequence" => sequence, "digest" => digest}}
  end

  defp greatest(error, _), do: error
end
