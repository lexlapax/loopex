defmodule Loopex.ToolRegistry do
  @moduledoc """
  ## Concept

  The set of tool definitions one runtime knows about. It is reached only
  through that runtime's own reference: two runtimes in one VM hold independent
  tool sets, and neither can observe or displace the other's. There is no
  VM-global registered name, no application-environment key, and no process
  dictionary or persistent term keyed by tool identity.

  Registration is append-only. A new generation is admitted, an identical one is
  accepted without changing anything, and a *different* definition offered under
  an identity that is already taken is refused rather than allowed to overwrite
  what a committed request may already name. M2 has no unregistration and no
  replacement.

  Being registered and being offered to a model are separate facts. The registry
  holds generations; a session's *active set* is the much smaller map of
  model-visible names it composes at start. M1's two demonstration tools stay
  registered exactly as they were and are members of no active set, so an
  inherited executor case still resolves them while no real conversation is ever
  shown one.

  Fixed by
  [ADR 0009](../../../../docs/adr/0009-tool-executor-and-grant-contracts.md#concept).

  ## Technical depth

  A `GenServer` started unnamed as the first child of
  `Loopex.Runtime.Supervisor` and resolved through the runtime's retained root
  pid, exactly as control and delivery are. It is first under `:rest_for_one`
  because control and every session coordinator resolve tools through it, so a
  registry failure must reset what depends on it rather than leave a coordinator
  holding a reference to a registry that has forgotten what it held.

  Registry contents are configuration, not session truth. Nothing here is
  durable and nothing here is journaled: a staged request carries the complete
  definition bytes it used, so projection and replay never read this process and
  a run stays reconstructible after a tool is version-bumped or removed
  entirely.

  The `loopex.` namespace is reserved. A reserved identifier is admitted only
  through the runtime's configured tool set at start, which is the reference
  distribution declaring its own tools; `register/2` refuses one at runtime.
  That is the whole enforcement of "from outside the reference distribution",
  and it needs no trust flag on the call because the start option is already the
  boundary between what a runtime was composed with and what asked it for
  something later.

  Name collisions are deliberately *not* refused here. Two generations may
  legitimately claim one model-visible name as long as they are never
  simultaneously active, so the name rule belongs to `compose_active_set/2` and
  is enforced once, at session start.
  """

  use GenServer

  alias LoopexProtocol.ToolDefinition

  @typedoc """
  ## Concept

  One registered generation: the definition, its identity, and the exact bytes
  its digest covers.

  ## Technical depth

  The canonical bytes are retained beside the generation rather than recomputed
  on demand, because admission compares bytes rather than digests: equal digests
  must never admit different bytes, and a comparison that recomputes from a
  definition cannot detect that.
  """
  @type entry :: %{
          definition: ToolDefinition.t(),
          generation: ToolDefinition.generation(),
          canonical_bytes: binary()
        }

  @typedoc """
  ## Concept

  A model-visible name mapped to the one generation that serves it.

  ## Technical depth

  Committed with the session's active-set record and immutable for that
  session's lifetime, so a registration made mid-run can neither add, remove,
  nor repoint a name the model has already been shown.
  """
  @type active_set :: %{binary() => ToolDefinition.generation()}

  @doc """
  ## Concept

  Starts one runtime's registry, pre-loaded with the tool set the runtime was
  composed with.

  ## Technical depth

  `:tools` is the reference distribution's own declaration and is the only path
  by which a reserved `loopex.` identifier enters the registry. An invalid or
  conflicting definition in that list refuses runtime start rather than leaving
  a runtime half-composed.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options) when is_list(options),
    do: GenServer.start_link(__MODULE__, options)

  @doc """
  ## Concept

  Registers a tool definition with this runtime.

  ## Technical depth

  Outcomes, exactly as ADR 0009 fixes them:

  | Offered | Result |
  | --- | --- |
  | A new `{tool_id, tool_version}` | `:ok`, retained |
  | An identical definition under an identity already held | `:ok`, nothing changes |
  | A different definition under an identity already held | `{:error, :tool_definition_conflict}` |
  | A new `tool_version` of a known `tool_id` | `:ok`, admitted additively |
  | A reserved `loopex.` identifier | `{:error, :reserved_tool_namespace}` |
  | A name outside the declared charset | `{:error, :invalid_tool_name}` |

  Identity comparison is over canonical bytes, never over the digest alone, so
  equal digests can never admit different bytes.
  """
  @spec register(Loopex.Runtime.t(), ToolDefinition.t()) :: :ok | {:error, term()}
  def register(runtime, definition) do
    with {:ok, registry} <- resolve_registry(runtime) do
      GenServer.call(registry, {:register, definition, :host})
    end
  end

  @doc """
  ## Concept

  The highest registered version of a tool.

  ## Technical depth

  Versions order by their numeric `major.minor.patch` components, not by binary
  comparison, so `0.10.0` resolves above `0.9.0`.
  """
  @spec resolve(Loopex.Runtime.t(), binary()) :: {:ok, entry()} | {:error, term()}
  def resolve(runtime, tool_id) when is_binary(tool_id) do
    with {:ok, registry} <- resolve_registry(runtime) do
      GenServer.call(registry, {:resolve, tool_id})
    end
  end

  @doc """
  ## Concept

  One exact generation of a tool.

  ## Technical depth

  Distinguishes an unknown tool from a known tool at an unknown version, because
  the two say different things to a caller: the first is a name that was never
  registered, the second is a version that was never registered under a name
  that was.
  """
  @spec resolve(Loopex.Runtime.t(), binary(), binary()) :: {:ok, entry()} | {:error, term()}
  def resolve(runtime, tool_id, tool_version)
      when is_binary(tool_id) and is_binary(tool_version) do
    with {:ok, registry} <- resolve_registry(runtime) do
      GenServer.call(registry, {:resolve, tool_id, tool_version})
    end
  end

  @doc """
  ## Concept

  Every generation this runtime holds.

  ## Technical depth

  Ordered by `{tool_id, version components}` so a caller comparing two runtimes'
  registries compares stable output. Used by conformance and by the composition
  that builds a session's active set.
  """
  @spec list(Loopex.Runtime.t()) :: {:ok, [entry()]} | {:error, term()}
  def list(runtime) do
    with {:ok, registry} <- resolve_registry(runtime) do
      GenServer.call(registry, :list)
    end
  end

  @doc """
  ## Concept

  Builds the map of model-visible names a session offers, refusing a session
  whose selected tools claim one name twice.

  ## Technical depth

  Three steps, in order: resolve each selection to one generation, build
  `name -> generation`, and refuse the whole composition if any name is claimed
  twice, naming both claiming generations. There is no precedence, no ordering
  rule, no last-writer-wins, and no automatic disambiguation suffix — an
  ambiguous active set is an operator or host composition error and is reported
  as one.

  A selection is either a `tool_id`, which takes that tool's highest version, or
  an exact `{tool_id, tool_version}`. The resulting map is committed with the
  session's active-set record and is immutable for that session, so registering
  a tool mid-run can neither add, remove, nor repoint a name the model has
  already been shown.
  """
  @spec compose_active_set(Loopex.Runtime.t(), [binary() | {binary(), binary()}]) ::
          {:ok, active_set()} | {:error, term()}
  def compose_active_set(runtime, selections) when is_list(selections) do
    with {:ok, registry} <- resolve_registry(runtime) do
      GenServer.call(registry, {:compose_active_set, selections})
    end
  end

  @impl GenServer
  def init(options) do
    tools = Keyword.get(options, :tools, [])

    report_narrowing(
      Keyword.get(options, :declared_tools, tools),
      Keyword.get(options, :diagnostics_to)
    )

    Enum.reduce_while(tools, {:ok, %{}}, fn definition, {:ok, entries} ->
      case put(entries, definition, :reference) do
        {:ok, entries} -> {:cont, {:ok, entries}}
        {:error, reason} -> {:halt, {:stop, {:invalid_tool_set, reason}}}
      end
    end)
  end

  # Concept: a narrowing is announced, never silent.
  #
  # Technical depth: the runtime completes a host's partial declaration into the
  # canonical record and drops schema keywords the kernel cannot evaluate. Doing
  # that quietly would leave a host believing a constraint is enforced when
  # nothing enforces it, so every dropped keyword is named on the diagnostics
  # plane at registration. This is transient plain data and is not durable truth:
  # a host with no diagnostics sink loses the notice, which is why the same
  # limitation is documented on `LoopexProtocol.ToolDefinition.normalize/1`
  # rather than existing only here.
  defp report_narrowing(_declared, nil), do: :ok

  defp report_narrowing(declared, sink) when is_pid(sink) do
    for declaration <- declared,
        dropped = ToolDefinition.narrowing(declaration),
        dropped != [] do
      send(
        sink,
        {:loopex_diagnostic,
         %{
           "kind" => "tool_schema_narrowed",
           "tool_id" => Map.get(declaration, "tool_id"),
           "dropped" => dropped
         }}
      )
    end

    :ok
  end

  @impl GenServer
  def handle_call({:register, definition, origin}, _from, entries) do
    case put(entries, definition, origin) do
      {:ok, entries} -> {:reply, :ok, entries}
      {:error, reason} -> {:reply, {:error, reason}, entries}
    end
  end

  def handle_call({:resolve, tool_id}, _from, entries) do
    entries
    |> Enum.filter(fn {{id, _version}, _entry} -> id == tool_id end)
    |> Enum.max_by(fn {{_id, version}, _entry} -> version_order(version) end, fn -> nil end)
    |> case do
      nil -> {:reply, {:error, :unknown_tool}, entries}
      {_identity, entry} -> {:reply, {:ok, entry}, entries}
    end
  end

  def handle_call({:resolve, tool_id, tool_version}, _from, entries) do
    known_id? = Enum.any?(entries, fn {{id, _version}, _entry} -> id == tool_id end)

    case Map.fetch(entries, {tool_id, tool_version}) do
      {:ok, entry} -> {:reply, {:ok, entry}, entries}
      :error when known_id? -> {:reply, {:error, :unknown_tool_generation}, entries}
      :error -> {:reply, {:error, :unknown_tool}, entries}
    end
  end

  def handle_call(:list, _from, entries), do: {:reply, {:ok, sorted(entries)}, entries}

  def handle_call({:compose_active_set, selections}, _from, entries) do
    {:reply, compose(entries, selections), entries}
  end

  defp compose(entries, selections) do
    Enum.reduce_while(selections, {:ok, %{}, %{}}, fn selection, {:ok, active, claimed} ->
      case select(entries, selection) do
        {:ok, %{definition: definition, generation: generation}} ->
          name = Map.fetch!(definition, "name")

          case Map.fetch(claimed, name) do
            {:ok, held} ->
              {:halt, {:error, {:duplicate_tool_name, name, held, generation}}}

            :error ->
              {:cont,
               {:ok, Map.put(active, name, generation), Map.put(claimed, name, generation)}}
          end

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, active, _claimed} -> {:ok, active}
      {:error, reason} -> {:error, reason}
    end
  end

  defp select(entries, {tool_id, tool_version}) when is_binary(tool_id) do
    case Map.fetch(entries, {tool_id, tool_version}) do
      {:ok, entry} ->
        {:ok, entry}

      :error ->
        if Enum.any?(entries, fn {{id, _version}, _entry} -> id == tool_id end),
          do: {:error, {:unknown_tool_generation, tool_id, tool_version}},
          else: {:error, {:unknown_tool, tool_id}}
    end
  end

  defp select(entries, tool_id) when is_binary(tool_id) do
    entries
    |> Enum.filter(fn {{id, _version}, _entry} -> id == tool_id end)
    |> Enum.max_by(fn {{_id, version}, _entry} -> version_order(version) end, fn -> nil end)
    |> case do
      nil -> {:error, {:unknown_tool, tool_id}}
      {_identity, entry} -> {:ok, entry}
    end
  end

  # Concept: one admission rule, used by both start-up loading and `register/2`.
  #
  # Technical depth: `origin` distinguishes the reference distribution's own
  # declaration from a later caller, and reserves the `loopex.` namespace to the
  # former. Validity is checked before the namespace so a malformed reserved
  # definition reports what is actually wrong with it rather than only that its
  # name is taken.
  defp put(entries, definition, origin) do
    with :ok <- validity(definition),
         :ok <- namespace(definition, origin) do
      identity = {Map.fetch!(definition, "tool_id"), Map.fetch!(definition, "tool_version")}
      bytes = ToolDefinition.canonical_bytes(definition)

      case Map.fetch(entries, identity) do
        {:ok, %{canonical_bytes: ^bytes}} ->
          {:ok, entries}

        {:ok, _different} ->
          {:error, :tool_definition_conflict}

        :error ->
          entry = %{
            definition: definition,
            generation: ToolDefinition.generation(definition),
            canonical_bytes: bytes
          }

          {:ok, Map.put(entries, identity, entry)}
      end
    end
  end

  defp validity(definition) do
    case ToolDefinition.validate(definition) do
      [] ->
        :ok

      reasons ->
        if Enum.any?(reasons, &String.starts_with?(&1, "name:")),
          do: {:error, :invalid_tool_name},
          else: {:error, {:invalid_tool_definition, reasons}}
    end
  end

  defp namespace(definition, origin) do
    reserved? = definition |> Map.fetch!("tool_id") |> ToolDefinition.reserved?()

    if reserved? and origin != :reference,
      do: {:error, :reserved_tool_namespace},
      else: :ok
  end

  defp sorted(entries) do
    entries
    |> Enum.sort_by(fn {{id, version}, _entry} -> {id, version_order(version)} end)
    |> Enum.map(fn {_identity, entry} -> entry end)
  end

  # Concept: `0.10.0` is above `0.9.0`.
  #
  # Technical depth: the definition record already refuses any version that is
  # not exactly three integer components, so this parse is total over what the
  # registry can hold and needs no fallback clause.
  defp version_order(version) do
    version |> String.split(".") |> Enum.map(&String.to_integer/1) |> List.to_tuple()
  end

  defp resolve_registry(runtime), do: Loopex.Runtime.tool_registry(runtime)
end
