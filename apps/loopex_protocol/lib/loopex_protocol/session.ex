defmodule LoopexProtocol.Session do
  @moduledoc """
  ## Concept

  The current foreground experimental public session protocol: which generation a
  client and server agree on, exactly which methods and record families that
  generation admits, the limits the server enforces, and the digest that names
  the whole contract. A client negotiates against these values before it may
  change anything, and a server that changes any of them changes the digest.

  ## Technical depth

  Accepted ADR 0044 coordinates this replacement of ADR 0023. The module is
  data and validation only: it holds no connection, performs no effect, and knows nothing about a
  runtime, a transport or a facade. That is what lets the same values identify
  the contract in a server, in a client written in another language, and in a
  conformance vector.

  The digest is taken over the schema rather than over one server's
  configuration. Its seven keys bind closed payload definitions, methods, record
  families, error codes and schema maxima. A server may report smaller limits and
  still speak this generation, which is why `limits/0` is the ceiling a
  conforming server stays within rather than a promise about one process.

  Ordering is part of the identity. The method and family lists are written in
  the retained order, with configure and compact appended. Canonical encoding
  preserves list order, so a reordering changes the identity.
  """

  alias LoopexProtocol.Canonical

  @manifest_path Path.expand("../../priv/schema/loopex-experimental-3.json", __DIR__)
  @external_resource @manifest_path
  @manifest LoopexProtocol.Session.Manifest.read!(@manifest_path)
  @generation @manifest["generation"]
  @methods @manifest["methods"]
  @record_families @manifest["record_families"]
  @error_codes @manifest["error_codes"]
  @limits @manifest["limits"]

  @doc """
  ## Concept

  The protocol generation this contract names.

  ## Technical depth

  Experimental in its own name, so no client can read it as a stable release
  and no version arithmetic can round it up to one. A client offers an ordered
  list of generations and a server selects one it knows; there is no partial
  match and no nearest neighbour.
  """
  @spec generation() :: binary()
  def generation, do: @generation

  @doc """
  ## Concept

  The exact methods this generation admits.

  ## Technical depth

  A closed list. A capability a client declares never enables a method absent
  from it, and a method name absent from it is refused before any facade call,
  so an unimplemented future family cannot be reached by guessing its name.
  """
  @spec methods() :: [binary()]
  def methods, do: @methods

  @doc """
  ## Concept

  The record types a server may emit.

  ## Technical depth

  Every server record carries one of these as its `type`. The first five answer
  a request and echo its `request_id`; `event` and `progress` are asynchronous
  and never manufacture one.
  """
  @spec record_families() :: [binary()]
  def record_families, do: @record_families

  @doc """
  ## Concept

  The closed set of top-level error codes.

  ## Technical depth

  A refusal names one of these, and a cause outside the set collapses to
  `internal_failure` rather than serializing an unexpected term. The set is part
  of the digested contract because a client branches on it.
  """
  @spec error_codes() :: [binary()]
  def error_codes, do: @error_codes

  @doc """
  ## Concept

  The schema maxima a conforming server stays within.

  ## Technical depth

  These are ceilings, not one server's configuration: a server reports its own
  limits at initialization and they are never larger than these. Byte counts are
  bytes, not characters, and identity bounds are stated twice because an opaque
  identity is counted in its original bytes and again in the wire characters its
  encoding costs.
  """
  @spec limits() :: %{binary() => integer()}
  def limits, do: @limits

  @doc """
  ## Concept

  The digest that names this whole contract.

  ## Technical depth

  Taken over the complete seven-key manifest through loopex.canonical.v1.
  Closed request, record and nested payload definitions participate alongside
  the generation, ordered inventories and maxima; changing any leaf changes
  the identity. It is lowercase hexadecimal, which is
  the form the wire carries.
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

  Negotiates one generation from what a client offered.

  ## Technical depth

  The client's list is ordered by its own preference and the first entry this
  server knows wins, so a client that prefers a generation this build does not
  have still connects on one they share. No common entry is
  `unsupported_generation`; it is a refusal, never a downgrade to something
  neither side named.

  Capabilities are recorded, not obeyed. A declared capability this build does
  not know is reported back as unsupported so the client can see what was
  ignored, and it never enables a method.
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
