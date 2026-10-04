defmodule LoopexProtocol.Session.Checkpoint do
  @moduledoc """
  ## Concept

  Share the public checkpoint identity, coverage and accounting projection.
  A checkpoint names its actual run or compact owner and original conversation
  sources, without summary text, instruction captures or provider state.

  ## Technical depth

  ADR 0043's event projection has twelve closed members. Covered source
  references use the three existing conversation variants. Quantities remain
  exact integers natively and canonical decimal strings on the wire; the
  strategy revision is the literal integer 3. Owner, checkpoint, episode and
  source identities are opaque. This codec validates public shape and numeric
  relations; only the session reducer authenticates committed coverage.
  """

  alias LoopexProtocol.Session.CheckpointOwner
  alias LoopexProtocol.Wire

  @keys ~w(checkpoint_id episode_id covered_range prior_checkpoint_id strategy strategy_revision model reasoning configuration_version usage owner source_excerpted)

  @doc """
  ## Concept

  Encode the closed native checkpoint projection for events and snapshots.

  ## Technical depth

  Require bounded identities, closed original-source references, valid digest
  and model text, exact accounting and the accepted strategy/thinking-off tag.
  Enclosing records retain their total byte limits.
  """
  @spec encode_wire(term()) :: {:ok, map()} | :error
  def encode_wire(value), do: project(value, :encode)

  @doc """
  ## Concept

  Decode checkpoint coverage without losing identity or numeric precision.

  ## Technical depth

  Unknown members, superseded run_id ownership, noncanonical decimals/identities
  and private recovery data refuse. Coverage adjacency and ownership authority
  remain independent serial-owner replay obligations.
  """
  @spec decode_wire(term()) :: {:ok, map()} | :error
  def decode_wire(value), do: project(value, :decode)

  defp project(value, mode) do
    with true <- closed?(value, @keys),
         "loopex.compaction.reference" <- value["strategy"],
         3 <- value["strategy_revision"],
         "none" <- value["reasoning"],
         true <- is_boolean(value["source_excerpted"]),
         true <- text?(value["model"]),
         {:ok, checkpoint} <- identity(value["checkpoint_id"], mode),
         {:ok, episode} <- identity(value["episode_id"], mode),
         {:ok, prior} <- optional_identity(value["prior_checkpoint_id"], mode),
         true <- checkpoint != prior,
         {:ok, owner} <- owner(value["owner"], mode),
         {:ok, version, _} <- quantity(value["configuration_version"], mode, 1),
         {:ok, range} <- range(value["covered_range"], mode),
         {:ok, usage} <- usage(value["usage"], mode) do
      {:ok,
       Map.merge(value, %{
         "checkpoint_id" => checkpoint,
         "episode_id" => episode,
         "prior_checkpoint_id" => prior,
         "owner" => owner,
         "configuration_version" => version,
         "covered_range" => range,
         "usage" => usage
       })}
    else
      _ -> :error
    end
  end

  defp range(value, mode) do
    with true <-
           closed?(value, ~w(unit_count record_count source_count first last first_kept digest)),
         true <- digest?(value["digest"]),
         {:ok, units, n_units} <- quantity(value["unit_count"], mode, 1),
         {:ok, records, n_records} <- quantity(value["record_count"], mode, 1),
         {:ok, sources, n_sources} <- quantity(value["source_count"], mode, 1),
         true <- n_units <= n_sources and n_records <= n_sources,
         {:ok, first} <- reference(value["first"], mode),
         {:ok, last} <- reference(value["last"], mode),
         {:ok, kept} <- optional_reference(value["first_kept"], mode),
         true <- first != kept and last != kept do
      {:ok,
       Map.merge(value, %{
         "unit_count" => units,
         "record_count" => records,
         "source_count" => sources,
         "first" => first,
         "last" => last,
         "first_kept" => kept
       })}
    else
      _ -> :error
    end
  end

  defp reference(%{"kind" => "session_command"} = value, mode) do
    with true <- closed?(value, ~w(kind run_id command_id)),
         {:ok, run} <- identity(value["run_id"], mode),
         {:ok, command} <- identity(value["command_id"], mode) do
      {:ok, %{"kind" => "session_command", "run_id" => run, "command_id" => command}}
    else
      _ -> :error
    end
  end

  defp reference(%{"kind" => kind} = value, mode)
       when kind in ~w(session_assistant session_tool_result) do
    keys =
      if kind == "session_assistant",
        do: ~w(kind run_id turn),
        else: ~w(kind run_id turn call_id)

    with true <- closed?(value, keys),
         {:ok, run} <- identity(value["run_id"], mode),
         {:ok, turn, _} <- quantity(value["turn"], mode, 1) do
      result = Map.merge(value, %{"run_id" => run, "turn" => turn})

      if kind == "session_tool_result" do
        case identity(value["call_id"], mode) do
          {:ok, call} -> {:ok, Map.put(result, "call_id", call)}
          _ -> :error
        end
      else
        {:ok, result}
      end
    else
      _ -> :error
    end
  end

  defp reference(_, _), do: :error
  defp optional_reference(nil, _), do: {:ok, nil}
  defp optional_reference(value, mode), do: reference(value, mode)

  defp usage(value, mode) do
    keys = ~w(attempts reported_tokens estimated_tokens total_tokens)

    with true <- closed?(value, keys),
         {:ok, converted, native} <- quantities(value, keys, mode),
         true <- native["total_tokens"] == native["reported_tokens"] + native["estimated_tokens"] do
      {:ok, converted}
    else
      _ -> :error
    end
  end

  defp quantities(value, keys, mode) do
    Enum.reduce_while(keys, {:ok, value, value}, fn key, {:ok, converted, native} ->
      case quantity(value[key], mode, 0) do
        {:ok, output, integer} ->
          {:cont, {:ok, Map.put(converted, key, output), Map.put(native, key, integer)}}

        _ ->
          {:halt, :error}
      end
    end)
  end

  defp quantity(value, :encode, minimum) when is_integer(value) and value >= minimum,
    do: {:ok, Integer.to_string(value), value}

  defp quantity(value, :decode, minimum) when is_binary(value) do
    if Regex.match?(~r/\A(?:0|[1-9][0-9]*)\z/, value) do
      integer = String.to_integer(value)
      if integer >= minimum, do: {:ok, integer, integer}, else: :error
    else
      :error
    end
  end

  defp quantity(_, _, _), do: :error
  defp optional_identity(nil, _), do: {:ok, nil}
  defp optional_identity(value, mode), do: identity(value, mode)

  defp identity(value, :encode) when is_binary(value) and byte_size(value) in 1..65_536,
    do: {:ok, Wire.encode_identity(value)}

  defp identity(value, :decode) do
    with {:ok, bytes} <- Wire.identity(value),
         true <- Wire.encode_identity(bytes) == value,
         do: {:ok, bytes},
         else: (_ -> :error)
  end

  defp identity(_, _), do: :error
  defp owner(value, :encode), do: CheckpointOwner.encode_wire(value)
  defp owner(value, :decode), do: CheckpointOwner.decode_wire(value)

  defp text?(value),
    do: is_binary(value) and byte_size(value) in 1..131_072 and String.valid?(value)

  defp digest?(value), do: is_binary(value) and Regex.match?(~r/\A[0-9a-f]{64}\z/, value)

  defp closed?(value, keys),
    do: is_map(value) and not is_struct(value) and Enum.sort(Map.keys(value)) == Enum.sort(keys)
end
