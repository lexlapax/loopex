defmodule LoopexProtocol.Session.MaintenanceView do
  @moduledoc """
  ## Concept

  Share the closed active-maintenance view between public events and snapshots.
  Expose the actual owner, captured model and admission bounds without private
  recovery captures or a claim about remaining capacity.

  ## Technical depth

  ADR 0043 fixes a one-member payload, null or a six-member view. Native IDs
  remain opaque binaries and quantities are integers. Wire identities are
  canonical unpadded base64url and quantities are exact decimal strings.
  Run and compact bounds have distinct closed domains. The serial reducer
  authenticates the projection; this codec grants no authority. Enclosing
  frames and snapshots retain their existing total-size limits.
  """

  alias LoopexProtocol.Session.CheckpointOwner
  alias LoopexProtocol.Wire

  @u64 18_446_744_073_709_551_615
  @view_keys ~w(episode_id owner model reasoning configuration_version bounds)

  @doc """
  ## Concept

  Encode only the approved native active-maintenance projection.

  ## Technical depth

  Missing or extra members, non-plain maps, invalid UTF-8, wrong owner bounds
  and quantities outside the retained admission domains refuse.
  """
  @spec encode_wire(term()) :: {:ok, map()} | :error
  def encode_wire(value), do: project(value, :encode)

  @doc """
  ## Concept

  Decode the current public view without losing numeric or identity precision.

  ## Technical depth

  Refuse JSON numeric quantities, noncanonical decimals or identities and
  private fields. A null active view is a valid inactive payload.
  """
  @spec decode_wire(term()) :: {:ok, map()} | :error
  def decode_wire(value), do: project(value, :decode)

  defp project(value, mode) do
    with true <- closed?(value, ~w(active_maintenance)),
         {:ok, view} <- view(value["active_maintenance"], mode) do
      {:ok, %{"active_maintenance" => view}}
    else
      _ -> :error
    end
  end

  defp view(nil, _), do: {:ok, nil}

  defp view(value, mode) do
    with true <- closed?(value, @view_keys),
         true <- text?(value["model"]),
         "none" <- value["reasoning"],
         {:ok, episode} <- identity(value["episode_id"], mode),
         {:ok, owner} <- owner(value["owner"], mode),
         {:ok, version} <- quantity(value["configuration_version"], mode, 1, nil),
         {:ok, bounds} <- bounds(value["bounds"], owner["kind"], mode) do
      {:ok,
       Map.merge(value, %{
         "episode_id" => episode,
         "owner" => owner,
         "configuration_version" => version,
         "bounds" => bounds
       })}
    else
      _ -> :error
    end
  end

  defp bounds(value, "run", mode) do
    with true <- closed?(value, ~w(max_attempts max_turns token_budget deadline_ms run_deadline)),
         {:ok, attempts} <- quantity(value["max_attempts"], mode, 4, 4),
         {:ok, turns} <- quantity(value["max_turns"], mode, 1, nil),
         {:ok, tokens} <- quantity(value["token_budget"], mode, 1, nil),
         {:ok, duration} <- quantity(value["deadline_ms"], mode, 1, @u64),
         {:ok, deadline} <- deadline(value["run_deadline"], mode) do
      {:ok,
       %{
         "max_attempts" => attempts,
         "max_turns" => turns,
         "token_budget" => tokens,
         "deadline_ms" => duration,
         "run_deadline" => deadline
       }}
    else
      _ -> :error
    end
  end

  defp bounds(value, "compact", mode) do
    with true <- closed?(value, ~w(max_attempts deadline_ms token_budget)),
         {:ok, attempts} <- quantity(value["max_attempts"], mode, 1, 4),
         {:ok, duration} <- quantity(value["deadline_ms"], mode, 1, 60_000),
         {:ok, tokens} <- quantity(value["token_budget"], mode, 1, 32_768) do
      {:ok, %{"max_attempts" => attempts, "deadline_ms" => duration, "token_budget" => tokens}}
    else
      _ -> :error
    end
  end

  defp deadline(nil, _), do: {:ok, nil}
  defp deadline(value, mode), do: quantity(value, mode, 0, @u64)

  defp quantity(value, :encode, minimum, maximum) when is_integer(value) do
    if value >= minimum and (maximum == nil or value <= maximum),
      do: {:ok, Integer.to_string(value)},
      else: :error
  end

  defp quantity(value, :decode, minimum, maximum) when is_binary(value) do
    if Regex.match?(~r/\A(?:0|[1-9][0-9]*)\z/, value) do
      integer = String.to_integer(value)

      if integer >= minimum and (maximum == nil or integer <= maximum),
        do: {:ok, integer},
        else: :error
    else
      :error
    end
  end

  defp quantity(_, _, _, _), do: :error

  defp owner(value, :encode), do: CheckpointOwner.encode_wire(value)
  defp owner(value, :decode), do: CheckpointOwner.decode_wire(value)

  defp identity(value, :encode) when is_binary(value) and byte_size(value) in 1..65_536,
    do: {:ok, Wire.encode_identity(value)}

  defp identity(value, :decode) do
    with {:ok, native} <- Wire.identity(value),
         true <- Wire.encode_identity(native) == value,
         do: {:ok, native},
         else: (_ -> :error)
  end

  defp identity(_, _), do: :error

  defp text?(value),
    do: is_binary(value) and byte_size(value) in 1..131_072 and String.valid?(value)

  defp closed?(value, keys),
    do: is_map(value) and not is_struct(value) and Enum.sort(Map.keys(value)) == Enum.sort(keys)
end
