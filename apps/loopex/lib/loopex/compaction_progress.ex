defmodule Loopex.CompactionProgress do
  @moduledoc """
  ## Concept

  One content-free observation that a maintenance summary received permission.
  Durable checkpoint and completion records remain the outcome evidence.

  ## Technical depth

  ADR 0054 fixes six native members, actual run or compact ownership, one
  sequence-zero observation per permitted attempt, and no closing item. This
  closed projection excludes private summary and provider data before routing.
  """

  @uint64_max 18_446_744_073_709_551_615

  @doc """
  ## Concept

  Construct an activity item from committed correlation identities.

  ## Technical depth

  Ownership is established by the coordinator; this function checks its plain
  boundary shape and the existing identity, domain and cursor ceilings.
  """
  @spec new(binary(), map(), binary(), non_neg_integer()) :: {:ok, map()} | :error
  def new(episode_id, owner, domain, base) do
    project(%{
      kind: "context.compaction_progress",
      episode_id: episode_id,
      owner: owner,
      stream_domain_id: domain,
      progress_sequence: 0,
      base_event_sequence: base
    })
  end

  @doc """
  ## Concept

  Admit only the current content-free activity contract.

  ## Technical depth

  Require the exact six atom keys and two string owner keys. Identities are
  opaque 1–65,536 byte binaries; domain is 32 lowercase hexadecimal bytes,
  sequence is integer zero, and base is unsigned 64-bit. Refuse structs,
  alternate keys, extra members and private payloads without serialization.
  """
  @spec project(term()) :: {:ok, map()} | :error
  def project(
        %{
          kind: "context.compaction_progress",
          episode_id: episode,
          owner: %{"kind" => kind, "id" => id} = owner,
          stream_domain_id: domain,
          progress_sequence: 0,
          base_event_sequence: base
        } = item
      )
      when not is_struct(item) and map_size(item) == 6 and
             not is_struct(owner) and map_size(owner) == 2 and kind in ["run", "compact"] and
             is_binary(episode) and byte_size(episode) in 1..65_536 and
             is_binary(id) and byte_size(id) in 1..65_536 and is_binary(domain) and
             byte_size(domain) == 32 and is_integer(base) and base in 0..@uint64_max do
    if hexadecimal?(domain), do: {:ok, item}, else: :error
  end

  def project(_item), do: :error

  defp hexadecimal?(<<>>), do: true

  defp hexadecimal?(<<byte, rest::binary>>) when byte in ?0..?9 or byte in ?a..?f,
    do: hexadecimal?(rest)

  defp hexadecimal?(_domain), do: false
end
