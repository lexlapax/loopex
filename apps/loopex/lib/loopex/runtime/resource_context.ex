defmodule Loopex.Runtime.ResourceContext do
  @moduledoc """
  ## Concept

  Resolves the optional resource blocks selected for one run. Each block is
  ordinary untrusted input, and its identity comes from the run's durable
  admission and selection rather than instructions inside a skill.

  ## Technical depth

  The coordinator first measures required context with `initial_header/1`.
  Only afterward may it call `plan/2`, reserve disposition rows, and resolve
  individual blocks. Planning reads snapshot identity but no file bodies.
  Resolution reads immutable runtime memory and never opens a path or performs
  a network request. The coordinator owns whole-request admission.
  """

  alias Loopex.Runtime.ResourceSnapshot
  alias Loopex.Runtime.SessionState
  alias LoopexProtocol.Canonical

  @doc false
  def initial_header(nil), do: nil

  def initial_header(resources) do
    %{
      "version" => 1,
      "manifest_digest" => resources["manifest_digest"],
      "selection_digest" => SessionState.resource_selection_digest(resources),
      "status" => "not_evaluated",
      "blocks" => []
    }
  end

  @doc false
  def plan(_snapshot, nil), do: nil

  def plan(snapshot, resources) do
    case ResourceSnapshot.disposition(snapshot, resources) do
      "active" ->
        initial_header(resources)
        |> Map.put("status", "evaluated")
        |> Map.put("blocks", selection_rows(resources))

      disposition ->
        Map.put(initial_header(resources), "status", disposition)
    end
  end

  defp selection_rows(resources) do
    selections = resources["selections"]

    [row(64, 64)] ++
      Enum.map(selections, &row(&1["pack_index"], &1["instruction_file_index"])) ++
      Enum.flat_map(selections, fn selected ->
        Enum.map(selected["supporting_files"], &row(selected["pack_index"], &1["file_index"]))
      end)
  end

  defp row(pack, file), do: %{"pack" => pack, "file" => file, "status" => "not_evaluated"}

  @doc false
  def resolve(snapshot, resources, %{"pack" => 64, "file" => 64}) do
    with {:ok, entries} <- ResourceSnapshot.catalog(snapshot) do
      text = catalog_text(entries)

      if byte_size(text) <= 16_384 do
        {:ok, text, reference(resources, 64, 64, Canonical.digest_bytes(text))}
      else
        {:withheld, "catalog_byte_limit"}
      end
    else
      {:error, _missing} -> {:error, :resource_snapshot_unavailable}
    end
  end

  def resolve(snapshot, resources, %{"pack" => pack_index, "file" => file_index}) do
    selected = Enum.find(resources["selections"], &(&1["pack_index"] == pack_index))
    instruction? = selected["instruction_file_index"] == file_index

    identity =
      if instruction? do
        %{"digest" => selected["instruction_digest"], "size" => nil}
      else
        selected["supporting_files"]
        |> Enum.find(&(&1["file_index"] == file_index))
      end

    digest = identity["digest"]
    limit = if instruction?, do: 65_536, else: 16_384

    with {:ok, pack} <- ResourceSnapshot.pack(snapshot, pack_index),
         %{"size" => size, "digest" => ^digest} <- Enum.at(pack["files"], file_index),
         true <- is_nil(identity["size"]) or size == identity["size"],
         :ok <- block_size(size, limit),
         {:ok, text} <- ResourceSnapshot.content(snapshot, pack_index, file_index),
         true <- byte_size(text) == size and Canonical.digest_bytes(text) == digest do
      if String.valid?(text),
        do: {:ok, text, reference(resources, pack_index, file_index, digest)},
        else: {:withheld, "unsupported_text"}
    else
      {:withheld, _reason} = withheld -> withheld
      _unavailable -> {:error, :resource_snapshot_unavailable}
    end
  end

  defp block_size(size, limit) when size > limit, do: {:withheld, "resource_byte_limit"}
  defp block_size(_size, _limit), do: :ok

  defp reference(resources, pack, file, digest) do
    %{
      "kind" => "resource_pack",
      "manifest_digest" => resources["manifest_digest"],
      "pack" => pack,
      "file" => file,
      "file_digest" => digest
    }
  end

  @doc false
  def catalog_text(entries) do
    "Available project skills\n\n" <>
      Enum.map_join(entries, "\n", fn entry ->
        "Name: #{entry["name"]}\n" <>
          "Source: #{entry["source_id"]}\n" <>
          "Description: #{entry["description"]}\n" <>
          "Pack digest: #{entry["pack_digest"]}\n" <>
          "Manual only: #{entry["manual_only"]}\n"
      end)
  end
end
