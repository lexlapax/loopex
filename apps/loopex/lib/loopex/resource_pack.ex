defmodule Loopex.ResourcePack do
  @moduledoc """
  ## Concept

  A resource pack is the complete, immutable set of skill instructions and
  supporting files that an operator can inspect and trust. This module checks
  host-supplied plain data and gives every accepted set one canonical identity.
  It reads no paths and grants no session or tool authority.

  ## Technical depth

  The boundary accepts atom or string aliases once, rejects ambiguous aliases
  and extra members, then emits only the string-key shapes fixed by ADR 0025.
  It bounds map shells and list spines before sorting, hashing content, or
  encoding metadata. File bodies stay in the normalized manifest, while digest
  metadata omits only each file's `content` member.
  """

  alias LoopexProtocol.Canonical

  @version "loopex.resource_pack/1"
  @manifest_kind "loopex.resource_manifest/1"
  @pack_kind "loopex.resource_pack/1"
  @max_packs 64
  @max_files 64
  @max_pack_bytes 1024 * 1024
  @max_manifest_bytes 64 * 1024 * 1024
  @max_text_resource_bytes 64 * 1024
  @max_metadata_bytes 8 * 1024 * 1024
  @max_text_bytes 1_024
  @unsafe_label_codepoints ~r/[\p{Cc}\p{Cf}\p{Zl}\p{Zp}]/u

  @manifest_keys [:version, :workspace_ref, :revision, :packs]
  @pack_keys [
    :source_id,
    :origin,
    :commit,
    :tree_digest,
    :name,
    :description,
    :manual_only,
    :files
  ]
  @file_keys [:label, :size, :digest, :content, :contained]
  @decision_keys [
    :manifest_digest,
    :workspace_ref,
    :trust_scope,
    :decision_source,
    :issued_at,
    :expires_at,
    :revocation_state
  ]
  @decision_sources ["interactive_operator", "host_supplied"]

  @type refusal :: {:error, atom(), map()}

  @doc """
  ## Concept

  Validates and identifies one complete resource manifest.

  ## Technical depth

  Packs sort by source and name. Files sort by label. The result therefore has
  one identity for every permutation of the same accepted content.
  """
  @spec digest(term()) :: {:ok, binary(), map()} | refusal()
  def digest(manifest) do
    with {:ok, normalized} <- normalize_manifest(manifest),
         :ok <- verify_file_digests(normalized),
         metadata = metadata(normalized),
         :ok <- admit_metadata_size(metadata) do
      {:ok, framed_digest(@manifest_kind, metadata), normalized}
    end
  end

  @doc """
  ## Concept

  Returns the canonical identity metadata without resource bodies.

  ## Technical depth

  The projection removes only file `content`. It keeps labels, verified sizes,
  digests, containment statements, source identity, and Git provenance.
  """
  @spec metadata(map()) :: map()
  def metadata(%{"packs" => packs} = manifest) when is_list(packs) do
    %{manifest | "packs" => Enum.map(packs, &metadata/1)}
  end

  def metadata(%{"files" => files} = pack) when is_list(files) do
    %{pack | "files" => Enum.map(files, &Map.delete(&1, "content"))}
  end

  @doc """
  ## Concept

  Identifies one normalized pack independently of its enclosing manifest.

  ## Technical depth

  Uses the ADR 0025 pack kind and the repository canonical encoding version.
  """
  @spec pack_digest(map()) :: binary()
  def pack_digest(normalized_pack),
    do: framed_digest(@pack_kind, metadata(normalized_pack))

  @doc """
  ## Concept

  Validates one host trust decision without consulting session state.

  ## Technical depth

  The accepted shape has seven string keys. Decisions are non-expiring in M3,
  and their state is exactly `active` or `revoked`.
  """
  @spec normalize_decision(term()) :: {:ok, map()} | {:error, :invalid_decision}
  def normalize_decision(decision) do
    with {:ok, normalized} <- normalize_map(decision, @decision_keys),
         true <- valid_digest?(normalized["manifest_digest"]),
         true <- valid_label?(normalized["workspace_ref"]),
         true <- normalized["trust_scope"] == "project_skills",
         true <- normalized["decision_source"] in @decision_sources,
         true <- valid_issued_at?(normalized["issued_at"]),
         true <- is_nil(normalized["expires_at"]),
         true <- normalized["revocation_state"] in ["active", "revoked"] do
      {:ok, normalized}
    else
      _invalid -> {:error, :invalid_decision}
    end
  end

  @doc """
  ## Concept

  Produces the catalog an operator may inspect when the exact manifest has a
  matching decision. A missing, revoked, malformed, or stale decision exposes
  no catalog entries.

  ## Technical depth

  This is a pure pre-session check. Runtime code must still reconcile the
  decision with durable session state before admission.
  """
  @spec catalog(term(), term()) ::
          {:staged, [map()], map()} | {:declined, atom(), map()}
  def catalog(manifest, decision) do
    case digest(manifest) do
      {:ok, manifest_digest, normalized} ->
        catalog_decision(normalized, manifest_digest, decision)

      {:error, reason, detail} ->
        {:declined, reason, receipt(nil, "manifest_rejected", detail["reason"])}
    end
  end

  defp normalize_manifest(manifest) do
    with {:ok, outer} <- normalize_map(manifest, @manifest_keys),
         true <- outer["version"] == @version,
         true <- valid_label?(outer["workspace_ref"]),
         true <- valid_optional_label?(outer["revision"]),
         {:ok, packs} <- bounded_list(outer["packs"], @max_packs, "packs"),
         {:ok, normalized_packs, total_bytes} <- normalize_packs(packs),
         :ok <- admit_total(total_bytes, @max_manifest_bytes, "manifest_bytes") do
      {:ok,
       %{
         "version" => @version,
         "workspace_ref" => outer["workspace_ref"],
         "revision" => outer["revision"],
         "packs" => Enum.sort_by(normalized_packs, &{&1["source_id"], &1["name"]})
       }}
    else
      false -> rejected("invalid_manifest")
      {:error, _reason, _detail} = error -> error
    end
  end

  defp normalize_packs(packs) do
    Enum.reduce_while(packs, {:ok, [], 0, MapSet.new()}, fn pack, {:ok, acc, total, seen} ->
      case normalize_pack(pack) do
        {:ok, normalized, pack_bytes} ->
          identity = {normalized["source_id"], normalized["name"]}

          if MapSet.member?(seen, identity) do
            {:halt, rejected("duplicate_pack_identity")}
          else
            {:cont, {:ok, [normalized | acc], total + pack_bytes, MapSet.put(seen, identity)}}
          end

        error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, normalized, total, _seen} -> {:ok, Enum.reverse(normalized), total}
      error -> error
    end
  end

  defp normalize_pack(pack) do
    with {:ok, outer} <- normalize_map(pack, @pack_keys),
         true <- valid_label?(outer["source_id"]),
         true <- valid_origin_and_git?(outer),
         true <- valid_name?(outer["name"]),
         true <- valid_description?(outer["description"]),
         true <- is_boolean(outer["manual_only"]),
         {:ok, files} <- bounded_list(outer["files"], @max_files, "files"),
         {:ok, normalized_files, pack_bytes} <- normalize_files(files),
         :ok <- require_instruction(normalized_files),
         :ok <- admit_total(pack_bytes, @max_pack_bytes, "pack_bytes") do
      {:ok,
       %{
         "source_id" => outer["source_id"],
         "origin" => outer["origin"],
         "commit" => outer["commit"],
         "tree_digest" => outer["tree_digest"],
         "name" => outer["name"],
         "description" => outer["description"],
         "manual_only" => outer["manual_only"],
         "files" => Enum.sort_by(normalized_files, & &1["label"])
       }, pack_bytes}
    else
      false -> rejected("invalid_pack")
      {:error, _reason, _detail} = error -> error
    end
  end

  defp normalize_files(files) do
    Enum.reduce_while(files, {:ok, [], 0, MapSet.new(), MapSet.new()}, fn file,
                                                                          {:ok, acc, total,
                                                                           labels, paths} ->
      case normalize_file(file) do
        {:ok, normalized} ->
          label = normalized["label"]
          path = normalized_path(label)

          cond do
            MapSet.member?(labels, label) ->
              {:halt, rejected("duplicate_file_label")}

            MapSet.member?(paths, path) ->
              {:halt, rejected("normalized_path_collision")}

            true ->
              {:cont,
               {:ok, [normalized | acc], total + normalized["size"], MapSet.put(labels, label),
                MapSet.put(paths, path)}}
          end

        error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, normalized, total, _labels, _paths} ->
        {:ok, Enum.reverse(normalized), total}

      error ->
        error
    end
  end

  defp normalize_file(file) do
    with {:ok, outer} <- normalize_map(file, @file_keys),
         true <- valid_path_label?(outer["label"]),
         true <- is_integer(outer["size"]) and outer["size"] >= 0,
         true <- is_binary(outer["content"]),
         true <- outer["size"] == byte_size(outer["content"]),
         true <- valid_digest?(outer["digest"]),
         true <- outer["contained"] == true,
         :ok <- admit_file_size(outer["label"], outer["content"], outer["size"]) do
      {:ok,
       %{
         "label" => outer["label"],
         "size" => outer["size"],
         "digest" => outer["digest"],
         "content" => outer["content"],
         "contained" => true
       }}
    else
      false -> rejected("invalid_file")
      {:error, _reason, _detail} = error -> error
    end
  end

  defp verify_file_digests(%{"packs" => packs}) do
    Enum.reduce_while(packs, :ok, fn pack, :ok ->
      Enum.reduce_while(pack["files"], :ok, fn file, :ok ->
        if Canonical.digest_bytes(file["content"]) == file["digest"] do
          {:cont, :ok}
        else
          {:halt, rejected("declared_digest_mismatch")}
        end
      end)
      |> case do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp normalize_map(term, keys) when is_map(term) and not is_struct(term) do
    if map_size(term) == length(keys) do
      Enum.reduce_while(keys, {:ok, %{}}, fn key, {:ok, acc} ->
        atom = Map.fetch(term, key)
        string_key = Atom.to_string(key)
        string = Map.fetch(term, string_key)

        case {atom, string} do
          {{:ok, _value}, {:ok, _duplicate}} -> {:halt, :error}
          {{:ok, value}, :error} -> {:cont, {:ok, Map.put(acc, string_key, value)}}
          {:error, {:ok, value}} -> {:cont, {:ok, Map.put(acc, string_key, value)}}
          _missing -> {:halt, :error}
        end
      end)
      |> case do
        {:ok, normalized} -> {:ok, normalized}
        :error -> rejected("invalid_member_set")
      end
    else
      rejected("invalid_member_set")
    end
  end

  defp normalize_map(_term, _keys), do: rejected("invalid_member_set")

  defp bounded_list(term, limit, dimension), do: bounded_list(term, limit, dimension, [], 0)

  defp bounded_list([], _limit, _dimension, acc, _count), do: {:ok, Enum.reverse(acc)}

  defp bounded_list([_head | _tail], limit, dimension, _acc, limit),
    do: over_limit(dimension, limit + 1, limit)

  defp bounded_list([head | tail], limit, dimension, acc, count),
    do: bounded_list(tail, limit, dimension, [head | acc], count + 1)

  defp bounded_list(_improper, _limit, _dimension, _acc, _count),
    do: rejected("invalid_list")

  defp valid_origin_and_git?(%{
         "origin" => nil,
         "commit" => nil,
         "tree_digest" => nil
       }),
       do: true

  defp valid_origin_and_git?(%{
         "origin" => origin,
         "commit" => commit,
         "tree_digest" => tree
       }) do
    valid_origin?(origin) and valid_git_id?(commit) and valid_git_id?(tree) and
      byte_size(commit) == byte_size(tree)
  end

  defp valid_origin_and_git?(_pack), do: false

  defp valid_origin?(origin) do
    valid_label?(origin) and not String.contains?(origin, ["?", "#"]) and
      not Regex.match?(~r|^[a-z][a-z0-9+.-]*://[^/]*@|i, origin)
  end

  defp valid_git_id?(value) when is_binary(value) and byte_size(value) in [40, 64],
    do: String.match?(value, ~r/\A[0-9a-f]+\z/)

  defp valid_git_id?(_value), do: false

  defp valid_digest?(value) when is_binary(value) and byte_size(value) == 64,
    do: String.match?(value, ~r/\A[0-9a-f]{64}\z/)

  defp valid_digest?(_value), do: false

  defp valid_name?(value) when is_binary(value) and byte_size(value) in 1..64,
    do: String.match?(value, ~r/\A[a-z0-9]+(?:-[a-z0-9]+)*\z/)

  defp valid_name?(_value), do: false

  defp valid_description?(value) when is_binary(value),
    do: byte_size(value) in 1..@max_text_bytes and String.valid?(value)

  defp valid_description?(_value), do: false

  defp valid_optional_label?(nil), do: true
  defp valid_optional_label?(value), do: valid_label?(value)

  defp valid_label?(value) when is_binary(value) do
    byte_size(value) in 1..@max_text_bytes and String.valid?(value) and
      not Regex.match?(@unsafe_label_codepoints, value)
  end

  defp valid_label?(_value), do: false

  defp valid_path_label?(label) do
    valid_label?(label) and not String.starts_with?(label, "/") and
      not String.contains?(label, "\\") and
      label
      |> String.split("/", trim: false)
      |> Enum.all?(&(&1 not in ["", ".", ".."]))
  end

  defp normalized_path(label), do: label |> String.normalize(:nfc) |> String.downcase()

  defp valid_issued_at?(value) do
    is_binary(value) and byte_size(value) in 1..64 and String.valid?(value) and
      match?({:ok, _instant, _offset}, DateTime.from_iso8601(value))
  end

  defp require_instruction(files) do
    if Enum.any?(files, &(&1["label"] == "SKILL.md")),
      do: :ok,
      else: rejected("instruction_missing")
  end

  defp admit_file_size(_label, _content, observed) when observed > @max_pack_bytes,
    do: over_limit("pack_bytes", observed, @max_pack_bytes)

  defp admit_file_size("SKILL.md", _content, observed)
       when observed > @max_text_resource_bytes,
       do: over_limit("instruction_bytes", observed, @max_text_resource_bytes)

  defp admit_file_size(_label, content, observed) when observed > @max_text_resource_bytes do
    if String.valid?(content),
      do: over_limit("text_resource_bytes", observed, @max_text_resource_bytes),
      else: :ok
  end

  defp admit_file_size(_label, _content, _observed), do: :ok

  defp admit_total(observed, limit, dimension) when observed > limit,
    do: over_limit(dimension, observed, limit)

  defp admit_total(_observed, _limit, _dimension), do: :ok

  defp admit_metadata_size(metadata) do
    size = metadata |> Canonical.encode() |> byte_size()
    admit_total(size, @max_metadata_bytes, "metadata_bytes")
  end

  defp framed_digest(kind, value) do
    Canonical.digest(%{
      "encoding" => Canonical.version(),
      "kind" => kind,
      "value" => value
    })
  end

  defp catalog_decision(_normalized, manifest_digest, nil),
    do: {:declined, :no_decision, receipt(manifest_digest, "no_decision")}

  defp catalog_decision(normalized, manifest_digest, decision) do
    case normalize_decision(decision) do
      {:error, :invalid_decision} ->
        {:declined, :binding_changed,
         receipt(manifest_digest, "binding_changed", "invalid_decision")}

      {:ok, normalized_decision} ->
        cond do
          normalized_decision["manifest_digest"] != manifest_digest or
              normalized_decision["workspace_ref"] != normalized["workspace_ref"] ->
            {:declined, :binding_changed,
             receipt(manifest_digest, "binding_changed", "decision_binding_mismatch")}

          normalized_decision["revocation_state"] == "revoked" ->
            {:declined, :revoked, receipt(manifest_digest, "revoked")}

          true ->
            {:staged, catalog_entries(normalized["packs"]), receipt(manifest_digest, "active")}
        end
    end
  end

  defp catalog_entries(packs) do
    packs
    |> Enum.with_index()
    |> Enum.map(fn {pack, index} ->
      %{
        "pack_index" => index,
        "source_id" => pack["source_id"],
        "name" => pack["name"],
        "description" => pack["description"],
        "pack_digest" => pack_digest(pack),
        "manual_only" => pack["manual_only"]
      }
    end)
  end

  defp receipt(manifest_digest, disposition, reason \\ nil) do
    %{
      "manifest_digest" => manifest_digest,
      "decision_disposition" => disposition,
      "reason" => reason
    }
  end

  defp rejected(reason), do: {:error, :manifest_rejected, %{"reason" => reason}}

  defp over_limit(dimension, observed, limit) do
    {:error, :over_limit, %{"dimension" => dimension, "observed" => observed, "limit" => limit}}
  end
end
