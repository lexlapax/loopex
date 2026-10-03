defmodule Loopex.Runtime.ArtifactReadCapabilities do
  @moduledoc """
  ## Concept

  Artifact retrieval belongs to an exact frozen read-tool generation. A name,
  schema field or current host registry cannot grant that capability during
  creation or replay.

  ## Technical depth

  Revision 1 pins the complete `(tool_id, tool_version, definition_digest)`
  triples. The current 1.1.0 vector has the bounded range capability. Unknown `loopex.read`
  generations refuse, while other tool IDs resolve to no capability.
  The table is literal and performs no registry, filesystem or clock lookup.
  Executor registration and implementation must separately prove a selected
  generation before dispatch.
  """

  alias Loopex.Store
  alias LoopexProtocol.ToolDefinition

  @revision "loopex.artifact_read.v1"
  @range {"loopex.read", "1.1.0",
          "858956b73d7059ffaf18943d28bb0654ee3ca935f86cec3a136ba8e93b6e3c9e"}
  @table %{
    @range => %{
      "revision" => @revision,
      "tool_id" => elem(@range, 0),
      "tool_version" => elem(@range, 1),
      "definition_digest" => elem(@range, 2)
    }
  }

  @typedoc """
  ## Concept

  The retained capability binding for a session's selected read generation.

  ## Technical depth

  Nil means no artifact retrieval. A non-nil value has exactly the revision
  and complete generation identity; it carries no handle or authority grant.
  """
  @type binding :: nil | %{required(binary()) => binary()}

  @doc """
  ## Concept

  The immutable generation inventory used by creation and replay.

  ## Technical depth

  Keys are complete ToolDefinition generation triples. Only the current
  shipped read definition is admitted; a version prefix never infers support.
  """
  @spec table() :: %{ToolDefinition.generation() => binding()}
  def table, do: @table

  @doc """
  ## Concept

  Resolve artifact retrieval from the complete selected definitions.

  ## Technical depth

  Input is bounded plain data containing valid normalized definitions.
  At most one `loopex.read` generation may be selected. Unknown or duplicated
  read generations and malformed selections refuse without consulting hosts.
  """
  @spec resolve(term()) :: {:ok, binding()} | {:error, :invalid_tool_selection}
  def resolve(definitions) when is_list(definitions) do
    with {:ok, _bytes} <- Store.admit_bounded(definitions),
         true <- Enum.all?(definitions, &ToolDefinition.valid?/1) do
      case Enum.filter(definitions, &(&1["tool_id"] == "loopex.read")) do
        [] ->
          {:ok, nil}

        [definition] ->
          case Map.fetch(@table, ToolDefinition.generation(definition)) do
            {:ok, binding} -> {:ok, binding}
            :error -> {:error, :invalid_tool_selection}
          end

        _ambiguous ->
          {:error, :invalid_tool_selection}
      end
    else
      _invalid -> {:error, :invalid_tool_selection}
    end
  end

  def resolve(_definitions), do: {:error, :invalid_tool_selection}

  @doc """
  ## Concept

  A retained binding must equal the capability derived from its own tools.

  ## Technical depth

  Exact map equality rejects missing, extra, substituted or relabelled members.
  A caller cannot force nil to suppress a selected artifact capability or add
  a capability to an unsupported generation.
  """
  @spec validate_binding(term(), term()) :: :ok | {:error, :invalid_tool_selection}
  def validate_binding(definitions, supplied) do
    case resolve(definitions) do
      {:ok, ^supplied} -> :ok
      _invalid -> {:error, :invalid_tool_selection}
    end
  end
end
