defmodule Loopex.Runtime.ResourceSnapshot do
  @moduledoc """
  ## Concept

  One runtime retains one immutable collection of admitted resource bytes.
  Sessions carry resource identities and a runtime-local reference, so opening
  another session does not copy the complete collection into its process state.

  ## Technical depth

  The runtime supervisor owns an unnamed protected ETS table. It inserts the
  already validated manifest during initialization, then passes only the table
  reference to child specifications. Metadata and individual file bodies have
  separate keys: inspection and selection need not read optional file content.
  The table survives child restarts and disappears with the runtime supervisor.
  It has no filesystem, network, discovery or permission behavior.
  """

  alias Loopex.ResourcePack
  alias LoopexProtocol.Canonical

  @typedoc """
  ## Concept

  A reference to the resource snapshot of one running runtime.

  ## Technical depth

  This private routing value never enters a journal, command, public query
  response or session's durable projection. Nil means no snapshot was supplied.
  """
  @type t :: :ets.tid() | nil

  @doc false
  @spec new(nil | {binary(), map()}) :: t()
  def new(nil), do: nil

  def new({digest, manifest}) do
    table = :ets.new(__MODULE__, [:set, :protected, read_concurrency: true])

    :ets.insert(table, {
      :identity,
      %{
        "manifest_digest" => digest,
        "workspace_ref" => manifest["workspace_ref"],
        "revision" => manifest["revision"]
      }
    })

    entries =
      manifest["packs"]
      |> Enum.with_index()
      |> Enum.map(fn {pack, pack_index} ->
        files =
          pack["files"]
          |> Enum.with_index()
          |> Enum.map(fn {file, file_index} ->
            :ets.insert(table, {{:file, pack_index, file_index}, file["content"]})
            Map.delete(file, "content")
          end)

        :ets.insert(table, {{:pack, pack_index}, Map.put(pack, "files", files)})
        :ets.insert(table, {{:name, pack["source_id"], pack["name"]}, pack_index})

        %{
          "pack_index" => pack_index,
          "source_id" => pack["source_id"],
          "name" => pack["name"],
          "description" => pack["description"],
          "pack_digest" => ResourcePack.pack_digest(pack),
          "manual_only" => pack["manual_only"]
        }
      end)

    :ets.insert(table, {:catalog, entries})
    table
  end

  @doc false
  @spec identity(t()) :: {:ok, map()} | {:error, atom()}
  def identity(snapshot), do: fetch(snapshot, :identity)

  @doc false
  @spec catalog(t()) :: {:ok, [map()]} | {:error, atom()}
  def catalog(snapshot), do: fetch(snapshot, :catalog)

  @doc false
  @spec pack(t(), non_neg_integer()) :: {:ok, map()} | {:error, atom()}
  def pack(snapshot, index), do: fetch(snapshot, {:pack, index})

  @doc false
  @spec find_pack(t(), binary(), binary()) ::
          {:ok, non_neg_integer(), map()} | {:error, atom()}
  def find_pack(snapshot, source, name) do
    with {:ok, index} <- fetch(snapshot, {:name, source, name}),
         {:ok, pack} <- pack(snapshot, index) do
      {:ok, index, pack}
    end
  end

  @doc false
  @spec content(t(), non_neg_integer(), non_neg_integer()) ::
          {:ok, binary()} | {:error, atom()}
  def content(snapshot, pack, file), do: fetch(snapshot, {:file, pack, file})

  @doc false
  @spec disposition(t(), map() | nil) :: binary()
  def disposition(_snapshot, nil), do: "no_decision"
  def disposition(_snapshot, %{"decision" => nil}), do: "no_decision"
  def disposition(_snapshot, %{"decision" => %{"revocation_state" => "revoked"}}), do: "revoked"

  def disposition(snapshot, resources) do
    case identity(snapshot) do
      {:ok, identity} ->
        if identity["manifest_digest"] == resources["manifest_digest"] and
             identity["workspace_ref"] == resources["workspace_ref"],
           do: "active",
           else: "binding_changed"

      {:error, _missing} ->
        "retained_content_missing"
    end
  end

  @doc false
  @spec view(t(), map() | nil) :: {:ok, map()} | {:error, atom()}
  def view(snapshot, resources) do
    configured =
      case identity(snapshot) do
        {:ok, identity} -> identity["manifest_digest"]
        _missing -> nil
      end

    status = disposition(snapshot, resources)

    entries =
      case {status, catalog(snapshot)} do
        {"active", {:ok, entries}} -> entries
        _withheld -> []
      end

    response = %{
      "configured_manifest_digest" => configured,
      "admitted_manifest_digest" =>
        if(is_map(resources), do: resources["manifest_digest"], else: nil),
      "decision_disposition" => status,
      "entries" => entries
    }

    if byte_size(Canonical.encode(response)) <= 262_144,
      do: {:ok, response},
      else: {:error, :resource_catalog_limit}
  end

  @doc false
  @spec resolve(t(), map() | nil, map()) :: {:accepted, map()} | {:refused, atom()}
  def resolve(snapshot, resources, %{"type" => "admit_resources"} = command) do
    decision = command["decision"]
    disabled = is_nil(decision) or decision["revocation_state"] == "revoked"

    target =
      if disabled do
        if is_map(resources),
          do: {:ok, Map.take(resources, ["workspace_ref", "manifest_digest"])},
          else: {:error, :resource_not_admitted}
      else
        identity(snapshot)
      end

    with {:ok, identity} <- target,
         true <- identity["manifest_digest"] == command["manifest_digest"],
         true <-
           is_nil(decision) or
             (decision["manifest_digest"] == identity["manifest_digest"] and
                decision["workspace_ref"] == identity["workspace_ref"]) do
      {:accepted, Map.take(identity, ["workspace_ref", "manifest_digest"])}
    else
      false -> {:refused, :resource_binding_changed}
      {:error, reason} -> {:refused, reason}
    end
  end

  def resolve(snapshot, resources, %{"type" => "activate_skill"} = command) do
    with :ok <- readable(snapshot, resources, command["manifest_digest"]),
         {:ok, index, pack} <- find_pack(snapshot, command["source_id"], command["name"]),
         true <- ResourcePack.pack_digest(pack) == command["pack_digest"],
         :ok <- selection_capacity(resources, index),
         {:ok, instruction, instruction_index} <- find_file(pack, "SKILL.md"),
         {:ok, supporting} <- supporting_files(pack, command["supporting_labels"]) do
      {:accepted,
       %{
         "pack_index" => index,
         "instruction_file_index" => instruction_index,
         "instruction_digest" => instruction["digest"],
         "supporting_files" => supporting
       }}
    else
      false -> {:refused, :resource_binding_changed}
      {:error, reason} -> {:refused, reason}
    end
  end

  @doc false
  @spec read(t(), map() | nil, term()) :: {:ok, map()} | {:error, atom()}
  def read(snapshot, resources, request) do
    with {:ok, request} <- read_request(request),
         :ok <- readable(snapshot, resources, request["manifest_digest"]),
         {:ok, pack_index, pack} <- find_pack(snapshot, request["source_id"], request["name"]),
         {:ok, file, file_index} <- find_file(pack, request["label"]),
         :ok <- read_size(file["size"]),
         {:ok, bytes} <- content(snapshot, pack_index, file_index),
         true <-
           byte_size(bytes) == file["size"] and Canonical.digest_bytes(bytes) == file["digest"] do
      {:ok, %{"digest" => file["digest"], "size" => file["size"], "content" => bytes}}
    else
      false -> {:error, :resource_binding_changed}
      {:error, reason} -> {:error, reason}
    end
  end

  defp read_size(size) when size <= 65_536, do: :ok
  defp read_size(_size), do: {:error, :resource_byte_limit}

  defp readable(_snapshot, nil, _digest), do: {:error, :resource_not_admitted}

  defp readable(snapshot, resources, digest) do
    if digest != resources["manifest_digest"] do
      {:error, :resource_binding_changed}
    else
      case disposition(snapshot, resources) do
        "active" -> :ok
        "retained_content_missing" -> {:error, :resource_manifest_missing}
        "binding_changed" -> {:error, :resource_binding_changed}
        _not_admitted -> {:error, :resource_not_admitted}
      end
    end
  end

  defp selection_capacity(resources, index) do
    selected = resources["selections"]

    if length(selected) < 4 or Enum.any?(selected, &(&1["pack_index"] == index)),
      do: :ok,
      else: {:error, :resource_selection_limit}
  end

  defp find_file(pack, label) do
    case Enum.find_index(pack["files"], &(&1["label"] == label)) do
      nil -> {:error, :resource_not_found}
      index -> {:ok, Enum.at(pack["files"], index), index}
    end
  end

  defp supporting_files(pack, labels) do
    Enum.reduce_while(labels, {:ok, []}, fn label, {:ok, entries} ->
      case find_file(pack, label) do
        {:ok, file, index} when label != "SKILL.md" ->
          entry = %{"file_index" => index, "digest" => file["digest"], "size" => file["size"]}
          {:cont, {:ok, entries ++ [entry]}}

        _missing ->
          {:halt, {:error, :resource_support_not_found}}
      end
    end)
  end

  defp read_request(request)
       when is_map(request) and not is_struct(request) and map_size(request) == 4 do
    Enum.reduce_while([:manifest_digest, :source_id, :name, :label], {:ok, %{}}, fn key,
                                                                                    {:ok, acc} ->
      value =
        case {Map.fetch(request, key), Map.fetch(request, Atom.to_string(key))} do
          {{:ok, value}, :error} -> value
          {:error, {:ok, value}} -> value
          _invalid -> nil
        end

      if is_binary(value) and byte_size(value) in 1..1_024 and String.valid?(value),
        do: {:cont, {:ok, Map.put(acc, Atom.to_string(key), value)}},
        else: {:halt, {:error, :invalid_resource_request}}
    end)
  end

  defp read_request(_request), do: {:error, :invalid_resource_request}

  defp fetch(nil, _key), do: {:error, :resource_manifest_missing}

  defp fetch(snapshot, key) do
    case :ets.lookup(snapshot, key) do
      [{^key, value}] -> {:ok, value}
      [] -> {:error, :resource_not_found}
    end
  rescue
    ArgumentError -> {:error, :resource_manifest_missing}
  end
end
