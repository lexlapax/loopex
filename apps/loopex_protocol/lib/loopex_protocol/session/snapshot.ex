defmodule LoopexProtocol.Session.Snapshot do
  @moduledoc """
  ## Concept

  One closed revision-3 snapshot describes a session at one committed cursor.
  Configuration, checkpoint, maintenance, pending question and last compact
  completion belong to that same point in history.

  ## Technical depth

  ADRs 0043–0045 require the coordinated M7 foreground/daemon contract.
  Native top-level keys are fixed atoms; wire keys are binaries. Configuration
  is required and current, with no legacy/default branch. Other views are null
  or their shared closed projections. Opaque session identity retains its
  256-byte ceiling; run identities retain 65,536 bytes. Event cursor is uint64.
  The literal integer revision is distinct from decimal observed quantities.
  This codec checks shape and cross-view consistency, not durable authority.
  """

  alias LoopexProtocol.Wire

  alias LoopexProtocol.Session.{
    Checkpoint,
    CompactResult,
    Configuration,
    MaintenanceView,
    PendingInteraction
  }

  @fields [
    {"snapshot_revision", :snapshot_revision},
    {"session_id", :session_id},
    {"event_sequence", :event_sequence},
    {"active_run_id", :active_run_id},
    {"active_run_phase", :active_run_phase},
    {"configuration", :configuration},
    {"checkpoint", :checkpoint},
    {"active_maintenance", :active_maintenance},
    {"open_interaction", :open_interaction},
    {"last_compact", :last_compact}
  ]
  @u64 18_446_744_073_709_551_615

  @doc """
  ## Concept

  Encode all current cursor views without private recovery fields.

  ## Technical depth

  Native keys must be exactly the ten fixed members. Validate each nested
  projection and the relationships among active run, question and maintenance.
  """
  @spec encode_wire(term()) :: {:ok, map()} | :error
  def encode_wire(value) do
    if closed?(value, Enum.map(@fields, &elem(&1, 1))) do
      value
      |> then(fn snapshot ->
        Map.new(@fields, fn {wire, native} -> {wire, snapshot[native]} end)
      end)
      |> project(:encode)
    else
      :error
    end
  end

  @doc """
  ## Concept

  Decode one complete current snapshot with exact quantities and identities.

  ## Technical depth

  Reject older revisions, missing configuration, extra members and inconsistent
  cross-view facts. Only compile-time field atoms are installed in native data.
  """
  @spec decode_wire(term()) :: {:ok, map()} | :error
  def decode_wire(value) do
    with {:ok, converted} <- project(value, :decode) do
      {:ok, Map.new(@fields, fn {wire, native} -> {native, converted[wire]} end)}
    end
  end

  defp project(value, mode) do
    with true <- closed?(value, Enum.map(@fields, &elem(&1, 0))),
         3 <- value["snapshot_revision"],
         true <- value["active_run_phase"] in [nil, "admitted_unstaged", "started"],
         {:ok, session} <- identity(value["session_id"], mode, 256),
         {:ok, cursor} <- cursor(value["event_sequence"], mode),
         {:ok, run} <- optional_identity(value["active_run_id"], mode),
         {:ok, configuration} <- configuration(value["configuration"], mode),
         {:ok, checkpoint} <- checkpoint(value["checkpoint"], mode),
         {:ok, interaction} <- interaction(value["open_interaction"], mode),
         {:ok, maintenance} <- maintenance(value["active_maintenance"], mode),
         {:ok, compact} <- compact(value["last_compact"], mode),
         converted =
           Map.merge(value, %{
             "session_id" => session,
             "event_sequence" => cursor,
             "active_run_id" => run,
             "configuration" => configuration,
             "checkpoint" => checkpoint,
             "open_interaction" => interaction,
             "active_maintenance" => maintenance,
             "last_compact" => compact
           }),
         true <- consistent?(converted, mode) do
      {:ok, converted}
    else
      _ -> :error
    end
  end

  defp consistent?(value, mode) do
    run = value["active_run_id"]
    maintenance = value["active_maintenance"]
    question = value["open_interaction"]
    configuration_version = integer(value["configuration"]["configuration_version"], mode)

    run_phase = is_nil(run) == is_nil(value["active_run_phase"])

    question_owner =
      is_nil(question) or
        (not is_nil(run) and is_nil(maintenance) and question["run_id"] == run)

    maintenance_owner =
      case maintenance do
        nil -> true
        %{"owner" => %{"kind" => "run", "id" => owner}} -> owner == run
        %{"owner" => %{"kind" => "compact"}} -> is_nil(run)
      end

    maintenance_version =
      is_nil(maintenance) or
        integer(maintenance["configuration_version"], mode) == configuration_version

    checkpoint_version =
      is_nil(value["checkpoint"]) or
        integer(value["checkpoint"]["configuration_version"], mode) <= configuration_version

    initial_cursor =
      integer(value["event_sequence"], mode) != 0 or
        Enum.all?(
          ~w(active_run_id checkpoint active_maintenance open_interaction last_compact),
          &is_nil(value[&1])
        )

    run_phase and question_owner and maintenance_owner and maintenance_version and
      checkpoint_version and initial_cursor
  end

  defp configuration(value, :encode), do: Configuration.encode_wire(value)
  defp configuration(value, :decode), do: Configuration.decode_wire(value)
  defp checkpoint(nil, _mode), do: {:ok, nil}
  defp checkpoint(value, :encode), do: Checkpoint.encode_wire(value)
  defp checkpoint(value, :decode), do: Checkpoint.decode_wire(value)
  defp interaction(nil, _mode), do: {:ok, nil}
  defp interaction(value, :encode), do: PendingInteraction.encode_wire(value)
  defp interaction(value, :decode), do: PendingInteraction.decode_wire(value)

  defp maintenance(value, mode) do
    result =
      if mode == :encode,
        do: MaintenanceView.encode_wire(%{"active_maintenance" => value}),
        else: MaintenanceView.decode_wire(%{"active_maintenance" => value})

    with {:ok, projected} <- result, do: {:ok, projected["active_maintenance"]}
  end

  defp compact(nil, _mode), do: {:ok, nil}
  defp compact(value, :encode), do: CompactResult.encode_completion(value)
  defp compact(value, :decode), do: CompactResult.decode_completion(value)

  defp optional_identity(nil, _mode), do: {:ok, nil}
  defp optional_identity(value, mode), do: identity(value, mode, 65_536)

  defp identity(value, :encode, maximum)
       when is_binary(value) and byte_size(value) > 0 and byte_size(value) <= maximum,
       do: {:ok, Wire.encode_identity(value)}

  defp identity(value, :decode, maximum) do
    with {:ok, bytes} <- Wire.identity(value),
         true <- byte_size(bytes) <= maximum and Wire.encode_identity(bytes) == value,
         do: {:ok, bytes},
         else: (_ -> :error)
  end

  defp identity(_, _, _), do: :error

  defp cursor(value, :encode) when is_integer(value) and value >= 0 and value <= @u64,
    do: {:ok, Integer.to_string(value)}

  defp cursor(value, :decode), do: Wire.u64(value)
  defp cursor(_, _), do: :error
  defp integer(value, :encode), do: String.to_integer(value)
  defp integer(value, :decode), do: value

  defp closed?(value, keys),
    do: is_map(value) and not is_struct(value) and Enum.sort(Map.keys(value)) == Enum.sort(keys)
end
