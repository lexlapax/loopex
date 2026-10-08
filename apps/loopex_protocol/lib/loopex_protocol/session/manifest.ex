defmodule LoopexProtocol.Session.Manifest do
  @moduledoc """
  ## Concept

  Read the single current contract asset used by a server's metadata and digest.
  Unknown top-level keys cannot silently become part of a different recipe.

  ## Technical depth

  This internal compile-time reader rejects duplicate JSON keys through Frame
  before conversion and accepts only integer-only canonical schema data. Session
  and Session.V2 retain the decoded asset in module attributes and declare its
  source path as an external resource. No connection or runtime state is read.
  """

  alias LoopexProtocol.{Canonical, Frame}

  @keys ~w(generation canonicalization_revision methods record_families error_codes limits payload_definitions)
  @inventories ~w(methods record_families error_codes)

  @doc false
  @spec read!(binary()) :: map()
  def read!(path), do: path |> File.read!() |> String.trim_trailing("\n") |> decode!()

  @doc false
  @spec decode!(binary()) :: map()
  def decode!(bytes) do
    with {:ok, manifest} <- Frame.decode(bytes, 1_048_576),
         true <- Enum.sort(Map.keys(manifest)) == Enum.sort(@keys),
         true <- manifest["generation"] in ["loopex.experimental/3", "loopex.experimental/4"],
         true <- manifest["canonicalization_revision"] == Canonical.version(),
         true <- Enum.all?(@inventories, &inventory?(manifest[&1])),
         true <- is_map(manifest["limits"]),
         true <- is_map(manifest["payload_definitions"]),
         true <- map_size(manifest["payload_definitions"]) > 0,
         true <- integer_data?(manifest),
         true <- complete_definitions?(manifest) do
      manifest
    else
      _ -> raise ArgumentError, "invalid complete current contract manifest"
    end
  end

  defp complete_definitions?(manifest) do
    definitions = manifest["payload_definitions"]

    with %{} = requests <- get_in(definitions, ["requests", "methods"]),
         %{} = records <- definitions["records"],
         %{} = nested <- definitions["nested"],
         true <- Enum.sort(Map.keys(requests)) == Enum.sort(["initialize" | manifest["methods"]]),
         true <- Enum.sort(Map.keys(records)) == Enum.sort(manifest["record_families"]),
         true <- Enum.all?(Map.values(requests) ++ Map.values(records), &closed_definition?/1) do
      references?(definitions, nested)
    else
      _ -> false
    end
  end

  defp closed_definition?(%{"closed" => true}), do: true
  defp closed_definition?(_), do: false

  defp references?(value, nested) when is_map(value) do
    valid =
      case Map.fetch(value, "definition_ref") do
        :error ->
          true

        {:ok, reference} ->
          is_binary(reference) and resolves?(nested, String.split(reference, "."))
      end

    valid and Enum.all?(Map.values(value), &references?(&1, nested))
  end

  defp references?(value, nested) when is_list(value),
    do: Enum.all?(value, &references?(&1, nested))

  defp references?(_value, _nested), do: true

  defp resolves?(_value, []), do: true

  defp resolves?(value, [key | remaining]) when is_map(value) do
    case Map.fetch(value, key) do
      {:ok, member} -> resolves?(member, remaining)
      :error -> false
    end
  end

  defp resolves?(_value, _keys), do: false

  defp inventory?(values) when is_list(values),
    do: values != [] and Enum.all?(values, &is_binary/1) and Enum.uniq(values) == values

  defp inventory?(_), do: false

  defp integer_data?(value) when is_map(value),
    do: Enum.all?(value, fn {key, member} -> is_binary(key) and integer_data?(member) end)

  defp integer_data?(value) when is_list(value), do: Enum.all?(value, &integer_data?/1)

  defp integer_data?(value),
    do: is_binary(value) or is_integer(value) or is_boolean(value) or is_nil(value)
end
