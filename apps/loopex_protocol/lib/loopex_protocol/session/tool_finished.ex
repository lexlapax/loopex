defmodule LoopexProtocol.Session.ToolFinished do
  @moduledoc """
  ## Concept

  Carry the tool terminal the session actually committed. A receipt-backed
  result names its executor operation; a result reported without an operation
  identity, such as an answered model question or a policy refusal, omits that
  member and may explain itself with a public reason.

  ## Technical depth

  Accepted ADR 0067 fixes two closed variants selected by exact key set, with
  no fallback from one to the other. The eight-member receipt-backed variant
  requires a nonempty operation identity, a resolved tool ID, `reason: null` and
  bounded artifact-use references. The seven-member operation-less variant has
  no `operation_id`, exactly empty artifacts, a resolved tool ID or null, and a
  null or valid UTF-8 reason of at most 131,072 bytes. Opaque identities cross
  as canonical unpadded base64url and artifact sizes as canonical decimal text.
  Absence of an operation identity proves neither absence of an operation nor
  that nothing ran; this codec grants no authority and authenticates no
  producer. Both transports share it; their envelope, queue, cursor and detach
  logic stays where it is.
  """

  alias LoopexProtocol.Wire

  @receipt_backed ~w(run_id turn_id tool_call_id operation_id tool_id outcome reason artifacts)
  @operation_less ~w(run_id turn_id tool_call_id tool_id outcome reason artifacts)
  @identities ~w(run_id turn_id tool_call_id operation_id)
  @artifact ~w(digest size locator media_type role use_canonicalization_version use_digest use_locator)
  @outcomes ~w(completed failed denied cancelled outcome_unknown cancelled_workspace_lease_lost)
  @u64_max 18_446_744_073_709_551_615
  @reason_max 131_072
  @identity_max 65_536

  @doc """
  ## Concept

  Project one native `tool.finished` payload onto its public wire variant.

  ## Technical depth

  The input is the native event without its `kind`, `event_id` and
  `event_sequence` envelope: an ordinary binary-keyed map whose key set selects
  the variant. A malformed or private member refuses the whole payload; no
  member is dropped, synthesized or truncated to fit.
  """
  @spec encode_wire(term()) :: {:ok, map()} | :error
  def encode_wire(data) when is_map(data) and not is_struct(data) do
    case variant(data) do
      nil -> :error
      fields -> project(data, fields, &encode_member/3)
    end
  end

  def encode_wire(_data), do: :error

  @doc """
  ## Concept

  Recover the exact native payload from one closed wire variant.

  ## Technical depth

  Refuse alternate key sets, nulls where a value is required, noncanonical
  identities and quantities, and any artifact on the operation-less variant.
  Decoding cannot establish which producer emitted an admitted value.
  """
  @spec decode_wire(term()) :: {:ok, map()} | :error
  def decode_wire(data) when is_map(data) and not is_struct(data) do
    case variant(data) do
      nil -> :error
      fields -> project(data, fields, &decode_member/3)
    end
  end

  def decode_wire(_data), do: :error

  defp variant(data) do
    keys = Enum.sort(Map.keys(data))

    cond do
      keys == Enum.sort(@receipt_backed) -> @receipt_backed
      keys == Enum.sort(@operation_less) -> @operation_less
      true -> nil
    end
  end

  defp project(data, fields, member) do
    receipt? = fields == @receipt_backed

    Enum.reduce_while(fields, {:ok, %{}}, fn field, {:ok, projected} ->
      case member.(field, Map.fetch!(data, field), receipt?) do
        {:ok, value} -> {:cont, {:ok, Map.put(projected, field, value)}}
        :error -> {:halt, :error}
      end
    end)
  end

  defp encode_member(field, value, _receipt?) when field in @identities do
    if is_binary(value) and byte_size(value) in 1..@identity_max,
      do: {:ok, Wire.encode_identity(value)},
      else: :error
  end

  defp encode_member("artifacts", value, receipt?), do: artifacts(value, receipt?, &encode_size/1)
  defp encode_member(field, value, receipt?), do: scalar(field, value, receipt?)

  defp decode_member(field, value, _receipt?) when field in @identities do
    with {:ok, native} <- Wire.identity(value, @identity_max),
         true <- Wire.encode_identity(native) == value do
      {:ok, native}
    else
      _invalid -> :error
    end
  end

  defp decode_member("artifacts", value, receipt?), do: artifacts(value, receipt?, &Wire.u64/1)
  defp decode_member(field, value, receipt?), do: scalar(field, value, receipt?)

  # Concept: the operation-less variant may name an unresolved tool as null and
  # explain itself; the receipt-backed variant carries neither.
  # Technical depth: the reason is exact text, including empty text, never
  # normalized or truncated; invalid UTF-8 or an over-bound value refuses whole.
  defp scalar("tool_id", nil, false), do: {:ok, nil}

  defp scalar("tool_id", value, _receipt?) when is_binary(value) and byte_size(value) in 1..128,
    do:
      if(Regex.match?(~r/\A[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)*\z/, value),
        do: {:ok, value},
        else: :error
      )

  defp scalar("outcome", value, _receipt?) when value in @outcomes, do: {:ok, value}
  defp scalar("reason", nil, _receipt?), do: {:ok, nil}

  defp scalar("reason", value, false) when is_binary(value) and byte_size(value) <= @reason_max,
    do: if(String.valid?(value), do: {:ok, value}, else: :error)

  defp scalar(_field, _value, _receipt?), do: :error

  defp artifacts([], false, _size), do: {:ok, []}

  defp artifacts(values, true, size) when is_list(values) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, projected} ->
      case artifact(value, size) do
        {:ok, reference} -> {:cont, {:ok, [reference | projected]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, projected} -> {:ok, Enum.reverse(projected)}
      :error -> :error
    end
  end

  defp artifacts(_values, _receipt?, _size), do: :error

  defp artifact(value, size) when is_map(value) and not is_struct(value) do
    with true <- Enum.sort(Map.keys(value)) == Enum.sort(@artifact),
         {:ok, _digest} <- Wire.digest(value["digest"]),
         {:ok, use_digest} <- Wire.digest(value["use_digest"]),
         {:ok, projected_size} <- size.(value["size"]),
         true <- safe_text?(value["locator"], 1_024),
         true <- safe_text?(value["media_type"], 255),
         "tool_output" <- value["role"],
         "loopex.canonical.v1" <- value["use_canonicalization_version"],
         true <- value["use_locator"] == "use:" <> use_digest do
      {:ok, Map.put(value, "size", projected_size)}
    else
      _invalid -> :error
    end
  end

  defp artifact(_value, _size), do: :error

  defp encode_size(value) when is_integer(value) and value >= 0 and value <= @u64_max,
    do: {:ok, Wire.encode_u64(value)}

  defp encode_size(_value), do: :error

  defp safe_text?(value, ceiling),
    do:
      is_binary(value) and byte_size(value) in 1..ceiling and String.valid?(value) and
        not Regex.match?(~r/[\p{Cc}\p{Cf}\p{Zl}\p{Zp}]/u, value)
end
