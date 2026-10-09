defmodule LoopexProtocol.Session.V2 do
  @moduledoc """
  ## Concept

  The current experimental daemon contract, loopex.experimental/4. Its exact
  generation and payload-complete digest preserve controller and writer-epoch
  authority separately from the foreground contract.

  ## Technical depth

  Accepted ADR 0044 coordinates this replacement of ADR 0032. The existing V2
  module name remains the daemon adapter's contract location; only /4 is served.
  Its seven-key manifest includes every request, record and nested union.
  Ordered inventories retain their prior order with configure and compact
  appended. The module owns no runtime, connection or negotiation lifecycle.
  """

  alias LoopexProtocol.Canonical

  @manifest_path Path.expand("../../../priv/schema/loopex-experimental-4.json", __DIR__)
  @external_resource @manifest_path
  @manifest LoopexProtocol.Session.Manifest.read!(@manifest_path)
  @generation @manifest["generation"]
  @methods @manifest["methods"]
  @record_families @manifest["record_families"]
  @error_codes @manifest["error_codes"]
  @limits @manifest["limits"]

  @doc """
  ## Concept

  The exact daemon protocol generation.

  ## Technical depth

  The daemon selects only this literal. It never silently downgrades to the
  foreground server's generation.
  """
  @spec generation() :: binary()
  def generation, do: @generation

  @doc """
  ## Concept

  The exact methods the current daemon generation admits.

  ## Technical depth

  The list is closed and ordered. An absent method is refused before daemon or
  runtime work begins.
  """
  @spec methods() :: [binary()]
  def methods, do: @methods

  @doc """
  ## Concept

  The exact record families the current daemon generation may emit.

  ## Technical depth

  The two daemon notification families are uncorrelated. The inherited
  families retain their generation-one meaning.
  """
  @spec record_families() :: [binary()]
  def record_families, do: @record_families

  @doc """
  ## Concept

  The closed current daemon error-code inventory.

  ## Technical depth

  Private daemon and core results must be projected into this list before they
  cross the wire.
  """
  @spec error_codes() :: [binary()]
  def error_codes, do: @error_codes

  @doc """
  ## Concept

  The current daemon schema maxima.

  ## Technical depth

  The foreground limits are retained byte for byte and the seven daemon
  limits are added under the names fixed by ADR 0032.
  """
  @spec limits() :: %{binary() => integer()}
  def limits, do: @limits

  @doc """
  ## Concept

  The digest that names the complete current daemon contract.

  ## Technical depth

  It covers all seven manifest keys, including every nested payload definition,
  through loopex.canonical.v1.
  """
  @spec schema_digest() :: binary()
  def schema_digest, do: Canonical.digest(@manifest)

  @doc """
  ## Concept

  The complete current contract an independent consumer pins before requests.

  ## Technical depth

  Exactly seven keys bind ordered inventories and all closed payload definitions.
  The canonicalization revision and nested data participate in the same digest.
  """
  @spec manifest() :: map()
  def manifest, do: @manifest

  @doc """
  ## Concept

  Negotiates the current daemon generation from a client's ordered offer.

  ## Technical depth

  Only the exact current daemon literal can match. Old generations and the
  foreground generation refuse when offered alone.
  Capabilities are reported as unsupported and enable no method.
  """
  @spec negotiate([binary()], [binary()]) ::
          {:ok, map()} | {:error, :unsupported_generation}
  def negotiate(generations, capabilities)
      when is_list(generations) and is_list(capabilities) do
    case Enum.find(generations, &(&1 == @generation)) do
      nil ->
        {:error, :unsupported_generation}

      selected ->
        {:ok,
         %{
           "type" => "initialized",
           "selected_generation" => selected,
           "exact_schema_sha256" => schema_digest(),
           "supported_methods" => @methods,
           "record_families" => @record_families,
           "limits" => @limits,
           "unsupported_capabilities" => capabilities
         }}
    end
  end
end
