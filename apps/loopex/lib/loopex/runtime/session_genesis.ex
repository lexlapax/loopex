defmodule Loopex.Runtime.SessionGenesis do
  @moduledoc """
  ## Concept

  Creation and recovery share one interpretation of a session's initial
  durable settings. Normalization never supplies current startup defaults to
  retained history.

  ## Technical depth

  The v2 payload retains its closed options/runtime-configuration shape and
  mandatory cleanup grace. `resolve/2` constructs it from explicit startup
  data; `normalize/1` admits complete retained payloads. Both use the Store
  facade's pure plain-data traversal and measure the normalized complete item
  against 65,536 bytes. Neither function calls a Store adapter, registry,
  catalog or clock.
  """

  alias Loopex.Store

  @max_bytes 65_536
  @uint64_max 18_446_744_073_709_551_615
  @v2_keys Enum.sort([:kind, "options", "runtime_configuration"])

  @typedoc """
  ## Concept

  An admitted complete genesis, with no inferred settings.

  ## Technical depth

  Keys follow the Store's normalized record representation: atom `kind` and
  binary data keys. Options remain bounded plain data; cleanup grace is a
  positive unsigned 64-bit value.
  """
  @type genesis :: map()

  @typedoc """
  ## Concept

  Why initial session settings cannot be retained.

  ## Technical depth

  Invalid shapes, unsupported generations and non-plain data use
  `invalid_session_genesis`; a valid complete item above the byte ceiling uses
  `session_configuration_too_large`.
  """
  @type refusal :: :invalid_session_genesis | :session_configuration_too_large

  @doc """
  ## Concept

  Construct genesis from settings the caller has already resolved.

  ## Technical depth

  The v2 input has exactly `genesis_version` and `runtime_configuration`.
  Missing or unknown fields refuse rather than being filled or discarded.
  The constructed payload passes through the same decoder as replay.
  """
  @spec resolve(term(), term()) :: {:ok, genesis()} | {:error, refusal()}
  def resolve(
        options,
        %{
          genesis_version: "session_genesis_v2",
          runtime_configuration: configuration
        } = input
      )
      when map_size(input) == 2 do
    normalize(%{
      "options" => options,
      "runtime_configuration" => configuration,
      kind: "session_genesis_v2"
    })
  end

  def resolve(_options, _input), do: {:error, :invalid_session_genesis}

  @doc """
  ## Concept

  Validate complete retained genesis without changing its meaning.

  ## Technical depth

  Store normalization rejects key collisions, implementation terms and
  structural overages. The versioned closed decoder then validates all required
  members, and the exact normalized item determines the byte cost.
  """
  @spec normalize(term()) :: {:ok, genesis()} | {:error, refusal()}
  def normalize(payload) do
    with {:ok, normalized, bytes} <- Store.normalize_and_measure_item(:record, payload),
         :ok <- validate(normalized) do
      if bytes <= @max_bytes,
        do: {:ok, normalized},
        else: {:error, :session_configuration_too_large}
    else
      _invalid -> {:error, :invalid_session_genesis}
    end
  end

  defp validate(
         %{
           "options" => options,
           "runtime_configuration" => %{"cleanup_grace_ms" => grace} = configuration,
           kind: "session_genesis_v2"
         } = payload
       )
       when is_map(options) and map_size(configuration) == 1 and is_integer(grace) and
              grace >= 1 and grace <= @uint64_max do
    if Enum.sort(Map.keys(payload)) == @v2_keys,
      do: :ok,
      else: {:error, :invalid_session_genesis}
  end

  defp validate(_payload), do: {:error, :invalid_session_genesis}
end
