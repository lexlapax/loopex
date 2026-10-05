defmodule LoopexProtocol.Session.Inspection do
  @moduledoc """
  ## Concept

  One closed current inspection exposes the session's committed public views
  and the active run's captured bounds without private owner or adapter data.

  ## Technical depth

  M7 fixes eleven required fields. Native top-level keys are fixed atoms and
  status is :active. Nested public DTOs use their existing binary-key codecs;
  active_bounds preserves the coordinator's exact four atom-key members through
  a checked mapping to ActiveBounds. No defaults, clock reads or atom creation
  occur here. The outbox cursor does not identify every private journal fact;
  this codec validates a current observation, not historical durable authority.
  """

  alias LoopexProtocol.Wire

  alias LoopexProtocol.Session.{
    ActiveBounds,
    Checkpoint,
    Configuration,
    MaintenanceView,
    OpenInteraction
  }

  @fields [
    {"status", :status},
    {"event_sequence", :event_sequence},
    {"active_run_id", :active_run_id},
    {"cleanup_grace_ms", :cleanup_grace_ms},
    {"active_context_token_budget", :active_context_token_budget},
    {"pending_work_ids", :pending_work_ids},
    {"open_interaction", :open_interaction},
    {"configuration", :configuration},
    {"active_bounds", :active_bounds},
    {"checkpoint", :checkpoint},
    {"active_maintenance", :active_maintenance}
  ]
  @bounds_fields [
    {"max_turns", :max_turns},
    {"token_budget", :token_budget},
    {"deadline_ms", :deadline_ms},
    {"deadline", :deadline}
  ]
  @u64 18_446_744_073_709_551_615
  @array_members 1_024

  @doc """
  ## Concept

  Encode only the exact current native inspection allowlist.

  ## Technical depth

  Require all eleven atom-key fields, status :active and exact nested data.
  Extra owner fields refuse; the host selects its public allowlist explicitly.
  Preserve active bounds and every pending-work identity without new defaults.
  """
  @spec encode_wire(term()) :: {:ok, map()} | :error
  def encode_wire(value) do
    with true <- closed?(value, Enum.map(@fields, &elem(&1, 1))),
         :active <- value.status do
      value
      |> then(fn inspection ->
        Map.new(@fields, fn {wire, native} -> {wire, inspection[native]} end)
      end)
      |> Map.put("status", "active")
      |> project(:encode)
    else
      _ -> :error
    end
  end

  @doc """
  ## Concept

  Decode the closed current inspection with exact identities and quantities.

  ## Technical depth

  Install only compiled field atoms. ActiveBounds translates back to the same
  native four-field atom-key map; other nested DTOs retain binary keys.
  Missing fields, unknown members, null configuration and invalid types refuse.
  """
  @spec decode_wire(term()) :: {:ok, map()} | :error
  def decode_wire(value) do
    with {:ok, result} <- project(value, :decode) do
      {:ok,
       result
       |> Map.put("status", :active)
       |> then(fn inspection ->
         Map.new(@fields, fn {wire, native} -> {native, inspection[wire]} end)
       end)}
    end
  end

  defp project(value, mode) do
    with true <- closed?(value, Enum.map(@fields, &elem(&1, 0))),
         "active" <- value["status"],
         {:ok, cursor} <- quantity(value["event_sequence"], mode, 0),
         {:ok, cleanup} <- quantity(value["cleanup_grace_ms"], mode, 0),
         {:ok, context} <- optional_quantity(value["active_context_token_budget"], mode),
         {:ok, run} <- optional_identity(value["active_run_id"], mode),
         {:ok, pending} <- identities(value["pending_work_ids"], mode),
         {:ok, configuration} <- configuration(value["configuration"], mode),
         {:ok, bounds} <- bounds(value["active_bounds"], mode),
         {:ok, interaction} <- interaction(value["open_interaction"], mode),
         {:ok, checkpoint} <- checkpoint(value["checkpoint"], mode),
         {:ok, maintenance} <- maintenance(value["active_maintenance"], mode),
         true <- is_nil(run) == is_nil(bounds) do
      {:ok,
       Map.merge(value, %{
         "event_sequence" => cursor,
         "cleanup_grace_ms" => cleanup,
         "active_context_token_budget" => context,
         "active_run_id" => run,
         "pending_work_ids" => pending,
         "configuration" => configuration,
         "active_bounds" => bounds,
         "open_interaction" => interaction,
         "checkpoint" => checkpoint,
         "active_maintenance" => maintenance
       })}
    else
      _ -> :error
    end
  end

  defp bounds(nil, _mode), do: {:ok, nil}

  defp bounds(value, :encode) do
    if closed?(value, Enum.map(@bounds_fields, &elem(&1, 1))) do
      value
      |> then(fn bounds ->
        Map.new(@bounds_fields, fn {wire, native} -> {wire, bounds[native]} end)
      end)
      |> ActiveBounds.encode_wire()
    else
      :error
    end
  end

  defp bounds(value, :decode) do
    with {:ok, result} <- ActiveBounds.decode_wire(value),
         do: {:ok, Map.new(@bounds_fields, fn {wire, native} -> {native, result[wire]} end)}
  end

  defp configuration(value, :encode), do: Configuration.encode_wire(value)
  defp configuration(value, :decode), do: Configuration.decode_wire(value)
  defp checkpoint(nil, _mode), do: {:ok, nil}
  defp checkpoint(value, :encode), do: Checkpoint.encode_wire(value)
  defp checkpoint(value, :decode), do: Checkpoint.decode_wire(value)
  defp interaction(nil, _mode), do: {:ok, nil}
  defp interaction(value, :encode), do: OpenInteraction.encode_wire(value)
  defp interaction(value, :decode), do: OpenInteraction.decode_wire(value)

  defp maintenance(value, mode) do
    result =
      if mode == :encode,
        do: MaintenanceView.encode_wire(%{"active_maintenance" => value}),
        else: MaintenanceView.decode_wire(%{"active_maintenance" => value})

    with {:ok, projected} <- result, do: {:ok, projected["active_maintenance"]}
  end

  defp optional_quantity(nil, _mode), do: {:ok, nil}
  defp optional_quantity(value, mode), do: quantity(value, mode, 1)

  defp quantity(value, :encode, minimum)
       when is_integer(value) and value >= minimum and value <= @u64,
       do: {:ok, Integer.to_string(value)}

  defp quantity(value, :decode, minimum) do
    with {:ok, integer} <- Wire.u64(value),
         true <- integer >= minimum,
         do: {:ok, integer},
         else: (_ -> :error)
  end

  defp quantity(_, _, _), do: :error
  defp optional_identity(nil, _mode), do: {:ok, nil}
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

  defp identities(values, mode) when is_list(values) and length(values) <= @array_members do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, result} ->
      case identity(value, mode) do
        {:ok, id} -> {:cont, {:ok, [id | result]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      :error -> :error
    end
  end

  defp identities(_, _), do: :error

  defp closed?(value, keys),
    do: is_map(value) and not is_struct(value) and Enum.sort(Map.keys(value)) == Enum.sort(keys)
end
