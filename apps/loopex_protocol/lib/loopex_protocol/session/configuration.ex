defmodule LoopexProtocol.Session.Configuration do
  @moduledoc """
  ## Concept

  Share the committed configuration allowlist between events and snapshots.
  Expose selected settings and instruction identity without private content,
  capabilities, provider mappings or credential references.

  ## Technical depth

  ADR 0044 fixes seven members. Configuration version retains an exact positive
  integer; reply, context and system ceilings retain positive uint64 domains.
  Wire quantities are canonical decimal strings. Instruction identity contains
  its bounded ASCII version and lowercase SHA-256 digest. This codec validates
  shape and precision, not host admission or durable configuration authority.
  """

  @u64 18_446_744_073_709_551_615
  alias LoopexProtocol.Wire

  @keys ~w(configuration_version model reasoning max_tokens context_token_budget system_class_tokens instructions)
  @quantities ~w(configuration_version max_tokens context_token_budget system_class_tokens)

  @doc """
  ## Concept

  Encode only the native committed configuration projection.

  ## Technical depth

  Require a closed plain map, valid UTF-8 model identity, admitted reasoning
  vocabulary, exact positive quantities and closed instruction provenance.
  """
  @spec encode_wire(term()) :: {:ok, map()} | :error
  def encode_wire(value), do: project(value, :encode)

  @doc """
  ## Concept

  Recover exact configuration quantities without exposing private captures.

  ## Technical depth

  JSON numbers, noncanonical decimals, unknown members and malformed provenance
  refuse. Enclosing frames retain their total byte/depth/cardinality limits.
  """
  @spec decode_wire(term()) :: {:ok, map()} | :error
  def decode_wire(value), do: project(value, :decode)

  @doc """
  ## Concept

  Encode a committed configuration change with its actual command identity.

  ## Technical depth

  Require exactly command_id and configuration. The opaque command is nonempty
  and bounded by Wire; the nested configuration uses the same closed allowlist.
  """
  @spec encode_change(term()) :: {:ok, map()} | :error
  def encode_change(value), do: change(value, :encode)

  @doc """
  ## Concept

  Decode a public configuration change without adding authority.

  ## Technical depth

  Refuse null/noncanonical identities, extra outer members and malformed nested
  configuration. Command identity remains opaque bytes.
  """
  @spec decode_change(term()) :: {:ok, map()} | :error
  def decode_change(value), do: change(value, :decode)

  defp change(value, mode) do
    with true <- closed?(value, ~w(command_id configuration)),
         {:ok, command} <- identity(value["command_id"], mode),
         {:ok, configuration} <- project(value["configuration"], mode) do
      {:ok, %{"command_id" => command, "configuration" => configuration}}
    else
      _ -> :error
    end
  end

  defp identity(value, :encode) when is_binary(value) and byte_size(value) in 1..65_536,
    do: {:ok, Wire.encode_identity(value)}

  defp identity(value, :decode) do
    with {:ok, bytes} <- Wire.identity(value),
         true <- Wire.encode_identity(bytes) == value,
         do: {:ok, bytes},
         else: (_ -> :error)
  end

  defp identity(_, _), do: :error

  defp project(value, mode) do
    with true <- closed?(value, @keys),
         true <- text?(value["model"]),
         true <- value["reasoning"] in ~w(default none low medium high),
         true <- instructions?(value["instructions"]) do
      Enum.reduce_while(@quantities, {:ok, value}, fn key, {:ok, result} ->
        maximum = if key == "configuration_version", do: nil, else: @u64

        case quantity(value[key], mode, maximum) do
          {:ok, converted} -> {:cont, {:ok, Map.put(result, key, converted)}}
          :error -> {:halt, :error}
        end
      end)
    else
      _ -> :error
    end
  end

  defp instructions?(value) do
    closed?(value, ~w(version digest)) and is_binary(value["version"]) and
      byte_size(value["version"]) in 1..64 and
      Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9._-]{0,63}\z/, value["version"]) and
      is_binary(value["digest"]) and
      Regex.match?(~r/\A[0-9a-f]{64}\z/, value["digest"])
  end

  defp quantity(value, :encode, maximum) when is_integer(value) and value > 0 do
    if maximum == nil or value <= maximum, do: {:ok, Integer.to_string(value)}, else: :error
  end

  defp quantity(value, :decode, maximum) when is_binary(value) do
    if Regex.match?(~r/\A[1-9][0-9]*\z/, value) do
      integer = String.to_integer(value)
      if maximum == nil or integer <= maximum, do: {:ok, integer}, else: :error
    else
      :error
    end
  end

  defp quantity(_, _, _), do: :error

  defp text?(value),
    do: is_binary(value) and byte_size(value) in 1..131_072 and String.valid?(value)

  defp closed?(value, keys),
    do: is_map(value) and not is_struct(value) and Enum.sort(Map.keys(value)) == Enum.sort(keys)
end
