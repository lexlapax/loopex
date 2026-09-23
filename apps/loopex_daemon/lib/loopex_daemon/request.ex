defmodule LoopexDaemon.Request do
  @moduledoc """
  ## Concept

  A generation-two request becomes bounded plain daemon input before it can
  reach a lease, attachment, runtime, Store, or host resource. The wire method
  selects one fixed operation; client data never selects an atom or executable
  value.

  ## Technical depth

  The parser enforces the exact outer field set for all twenty generation-two
  methods, decodes every wire primitive through `LoopexProtocol.Wire`, and
  applies the M3 resource validators that the schema names. Optional fields are
  absent or valid: `null` is refused unless the contract explicitly admits it.
  The result contains only compile-time operation atoms and decoded plain data.
  It performs no IO, starts no process, and calls no runtime boundary.
  """

  alias Loopex.ResourcePack
  alias LoopexProtocol.{Session.V2, Wire}

  @content_bytes 1_048_576
  @max_json_depth 16
  @max_json_members 1_024
  @max_json_string_bytes 131_072
  @min_json_integer -9_007_199_254_740_991
  @max_json_integer 9_007_199_254_740_991
  @resource_string_bytes 1_024
  @skill_name_bytes 64
  @writer_epoch_bytes 64
  @create_command_bytes 256
  @resource_command_bytes 256
  @chunk_bytes 32_768
  @list_page_max 256
  @unsafe_resource_codepoints ~r/[\p{Cc}\p{Cf}\p{Zl}\p{Zp}]/u
  @skill_name ~r/\A[a-z0-9]+(?:-[a-z0-9]+)*\z/

  @operations %{
    "session.create" => :session_create,
    "session.resume" => :session_resume,
    "session.inspect" => :session_inspect,
    "session.attach" => :session_attach,
    "session.prompt" => :session_prompt,
    "session.steer" => :session_steer,
    "session.follow_up" => :session_follow_up,
    "session.abort" => :session_abort,
    "session.respond_interaction" => :session_respond_interaction,
    "resources.catalog" => :resources_catalog,
    "resources.read" => :resources_read,
    "session.admit_resources" => :session_admit_resources,
    "session.activate_skill" => :session_activate_skill,
    "artifact.open_transfer" => :artifact_open_transfer,
    "artifact.read_chunk" => :artifact_read_chunk,
    "artifact.close_transfer" => :artifact_close_transfer,
    "session.list" => :session_list,
    "daemon.status" => :daemon_status,
    "session.acquire_control" => :session_acquire_control,
    "session.release_control" => :session_release_control
  }

  @enforce_keys [:method, :operation, :request_id, :fields]
  defstruct [:method, :operation, :request_id, :fields]

  @typedoc false
  @type operation ::
          :session_create
          | :session_resume
          | :session_inspect
          | :session_attach
          | :session_prompt
          | :session_steer
          | :session_follow_up
          | :session_abort
          | :session_respond_interaction
          | :resources_catalog
          | :resources_read
          | :session_admit_resources
          | :session_activate_skill
          | :artifact_open_transfer
          | :artifact_read_chunk
          | :artifact_close_transfer
          | :session_list
          | :daemon_status
          | :session_acquire_control
          | :session_release_control

  @typedoc false
  @type t :: %__MODULE__{
          method: binary(),
          operation: operation(),
          request_id: binary(),
          fields: map()
        }

  @doc false
  @spec parse(term()) :: {:ok, t()} | {:error, :invalid_request | :unsupported_method}
  def parse(request) when is_map(request) and not is_struct(request) do
    with {:ok, request_id} <- request_id(Map.get(request, "request_id")),
         method when is_binary(method) <- Map.get(request, "method"),
         {:ok, operation} <- operation(method),
         {:ok, fields} <- parse_method(method, request) do
      {:ok,
       %__MODULE__{
         method: method,
         operation: operation,
         request_id: request_id,
         fields: fields
       }}
    else
      :unsupported -> {:error, :unsupported_method}
      _invalid -> {:error, :invalid_request}
    end
  end

  def parse(_request), do: {:error, :invalid_request}

  @doc false
  @spec valid_request_id?(term()) :: boolean()
  def valid_request_id?(id) when is_binary(id) do
    byte_size(id) in 1..64 and
      id |> :binary.bin_to_list() |> Enum.all?(&request_id_byte?/1)
  end

  def valid_request_id?(_id), do: false

  defp operation(method) do
    case Map.fetch(@operations, method) do
      {:ok, operation} -> {:ok, operation}
      :error -> :unsupported
    end
  end

  defp parse_method("session.create", request) do
    with :ok <- exact_fields(request, ["command_id", "session_options"]),
         {:ok, command_id} <- identity(request, "command_id", @create_command_bytes),
         {:ok, options} <- plain_object(request, "session_options") do
      {:ok, %{command_id: command_id, session_options: options}}
    end
  end

  defp parse_method("session.resume", request) do
    with :ok <- exact_fields(request, ["session_id", "command_id", "writer_epoch"]),
         {:ok, session_id} <- session_identity(request, "session_id"),
         {:ok, command_id} <- identity(request, "command_id", @create_command_bytes),
         {:ok, writer_epoch} <- writer_epoch(request) do
      {:ok, %{session_id: session_id, command_id: command_id, writer_epoch: writer_epoch}}
    end
  end

  defp parse_method("session.inspect", request) do
    with :ok <- exact_fields(request, ["session_id"]),
         {:ok, session_id} <- session_identity(request, "session_id") do
      {:ok, %{session_id: session_id}}
    end
  end

  defp parse_method("session.attach", request) do
    with :ok <- exact_fields(request, ["session_id"], ["after_event_sequence", "replace"]),
         {:ok, session_id} <- session_identity(request, "session_id"),
         {:ok, after_sequence} <- optional_u64(request, "after_event_sequence"),
         {:ok, replace} <- optional_boolean(request, "replace", false) do
      {:ok, %{session_id: session_id, after_event_sequence: after_sequence, replace: replace}}
    end
  end

  defp parse_method("session.prompt", request) do
    content_mutation(request, "session.prompt")
  end

  defp parse_method("session.follow_up", request) do
    content_mutation(request, "session.follow_up")
  end

  defp parse_method("session.steer", request) do
    with :ok <- exact_fields(request, ["command_id", "run_id", "content_b64", "writer_epoch"]),
         {:ok, command_id} <- identity(request, "command_id"),
         {:ok, run_id} <- identity(request, "run_id"),
         {:ok, content} <- nonempty_bytes(request, "content_b64", @content_bytes),
         {:ok, writer_epoch} <- writer_epoch(request) do
      {:ok,
       %{command_id: command_id, run_id: run_id, content: content, writer_epoch: writer_epoch}}
    end
  end

  defp parse_method("session.abort", request) do
    with :ok <- exact_fields(request, ["command_id", "writer_epoch"]),
         {:ok, command_id} <- identity(request, "command_id"),
         {:ok, writer_epoch} <- writer_epoch(request) do
      {:ok, %{command_id: command_id, writer_epoch: writer_epoch}}
    end
  end

  defp parse_method("session.respond_interaction", request) do
    with :ok <-
           exact_fields(request, ["command_id", "interaction_id", "answer", "writer_epoch"]),
         {:ok, command_id} <- identity(request, "command_id"),
         {:ok, interaction_id} <- identity(request, "interaction_id"),
         {:ok, choice_id} <- interaction_answer(request),
         {:ok, writer_epoch} <- writer_epoch(request) do
      {:ok,
       %{
         command_id: command_id,
         interaction_id: interaction_id,
         choice_id: choice_id,
         writer_epoch: writer_epoch
       }}
    end
  end

  defp parse_method("resources.catalog", request) do
    with :ok <- exact_fields(request, ["session_id"]),
         {:ok, session_id} <- session_identity(request, "session_id") do
      {:ok, %{session_id: session_id}}
    end
  end

  defp parse_method("resources.read", request) do
    with :ok <-
           exact_fields(request, ["session_id", "manifest_digest", "source_id", "name", "label"]),
         {:ok, session_id} <- session_identity(request, "session_id"),
         {:ok, manifest_digest} <- resource_string(request, "manifest_digest"),
         {:ok, source_id} <- resource_string(request, "source_id"),
         {:ok, name} <- resource_string(request, "name"),
         {:ok, label} <- resource_string(request, "label") do
      {:ok,
       %{
         session_id: session_id,
         manifest_digest: manifest_digest,
         source_id: source_id,
         name: name,
         label: label
       }}
    end
  end

  defp parse_method("session.admit_resources", request) do
    with :ok <-
           exact_fields(request, ["command_id", "manifest_digest", "decision", "writer_epoch"]),
         {:ok, command_id} <- identity(request, "command_id", @resource_command_bytes),
         {:ok, manifest_digest} <- digest(request, "manifest_digest"),
         {:ok, decision} <- resource_decision(request),
         {:ok, writer_epoch} <- writer_epoch(request) do
      {:ok,
       %{
         command_id: command_id,
         manifest_digest: manifest_digest,
         decision: decision,
         writer_epoch: writer_epoch
       }}
    end
  end

  defp parse_method("session.activate_skill", request) do
    with :ok <-
           exact_fields(request, [
             "command_id",
             "manifest_digest",
             "pack_digest",
             "source_id",
             "name",
             "supporting_labels",
             "writer_epoch"
           ]),
         {:ok, command_id} <- identity(request, "command_id", @resource_command_bytes),
         {:ok, manifest_digest} <- digest(request, "manifest_digest"),
         {:ok, pack_digest} <- digest(request, "pack_digest"),
         {:ok, source_id} <- resource_string(request, "source_id"),
         {:ok, name} <- skill_name(request),
         {:ok, labels} <- supporting_labels(request),
         {:ok, writer_epoch} <- writer_epoch(request) do
      {:ok,
       %{
         command_id: command_id,
         manifest_digest: manifest_digest,
         pack_digest: pack_digest,
         source_id: source_id,
         name: name,
         supporting_labels: labels,
         writer_epoch: writer_epoch
       }}
    end
  end

  defp parse_method("artifact.open_transfer", request) do
    with :ok <- exact_fields(request, ["use_ref", "start_offset"], ["window_length"]),
         {:ok, reference} <- field(request, "use_ref", &Wire.reference/1),
         {:ok, start_offset} <- u64(request, "start_offset"),
         {:ok, window_length} <- optional_u64(request, "window_length") do
      {:ok, %{reference: reference, start_offset: start_offset, window_length: window_length}}
    end
  end

  defp parse_method("artifact.read_chunk", request) do
    with :ok <- exact_fields(request, ["transfer_ref", "length"]),
         {:ok, transfer_ref} <- identity(request, "transfer_ref"),
         length when is_integer(length) and length in 1..@chunk_bytes <-
           Map.get(request, "length") do
      {:ok, %{transfer_ref: transfer_ref, length: length}}
    else
      _invalid -> :error
    end
  end

  defp parse_method("artifact.close_transfer", request) do
    with :ok <- exact_fields(request, ["transfer_ref"]),
         {:ok, transfer_ref} <- identity(request, "transfer_ref") do
      {:ok, %{transfer_ref: transfer_ref}}
    end
  end

  defp parse_method("session.list", request) do
    with :ok <- exact_fields(request, ["limit"], ["after_session_id"]),
         limit when is_integer(limit) and limit in 1..@list_page_max <- Map.get(request, "limit"),
         {:ok, after_session_id} <- optional_session_identity(request, "after_session_id") do
      {:ok, %{limit: limit, after_session_id: after_session_id}}
    else
      _invalid -> :error
    end
  end

  defp parse_method("daemon.status", request) do
    with :ok <- exact_fields(request, []) do
      {:ok, %{}}
    end
  end

  defp parse_method("session.acquire_control", request) do
    with :ok <- exact_fields(request, ["session_id"]),
         {:ok, session_id} <- session_identity(request, "session_id") do
      {:ok, %{session_id: session_id}}
    end
  end

  defp parse_method("session.release_control", request) do
    with :ok <- exact_fields(request, ["session_id", "writer_epoch"]),
         {:ok, session_id} <- session_identity(request, "session_id"),
         {:ok, writer_epoch} <- writer_epoch(request) do
      {:ok, %{session_id: session_id, writer_epoch: writer_epoch}}
    end
  end

  defp content_mutation(request, method) do
    with :ok <- exact_fields(request, ["command_id", "content_b64", "writer_epoch"]),
         true <- Map.get(request, "method") == method,
         {:ok, command_id} <- identity(request, "command_id"),
         {:ok, content} <- nonempty_bytes(request, "content_b64", @content_bytes),
         {:ok, writer_epoch} <- writer_epoch(request) do
      {:ok, %{command_id: command_id, content: content, writer_epoch: writer_epoch}}
    else
      _invalid -> :error
    end
  end

  defp exact_fields(request, required, optional \\ []) do
    allowed = ["method", "request_id" | required ++ optional]

    if map_size(request) == 2 + length(required) + optional_count(request, optional) and
         Enum.all?(required, &Map.has_key?(request, &1)) and
         Enum.all?(Map.keys(request), &(&1 in allowed)) do
      :ok
    else
      :error
    end
  end

  defp optional_count(request, optional),
    do: Enum.count(optional, &Map.has_key?(request, &1))

  defp request_id(id), do: if(valid_request_id?(id), do: {:ok, id}, else: :error)

  defp request_id_byte?(byte) do
    byte in ?A..?Z or byte in ?a..?z or byte in ?0..?9 or byte in [?., ?_, ?~, ?-]
  end

  defp identity(request, name, max_bytes \\ 65_536),
    do: field(request, name, &Wire.identity(&1, max_bytes))

  defp session_identity(request, name), do: field(request, name, &Wire.session_identity/1)

  defp optional_session_identity(request, name) do
    if Map.has_key?(request, name),
      do: session_identity(request, name),
      else: {:ok, nil}
  end

  defp writer_epoch(request), do: identity(request, "writer_epoch", @writer_epoch_bytes)

  defp digest(request, name), do: field(request, name, &Wire.digest/1)

  defp u64(request, name), do: field(request, name, &Wire.u64/1)

  defp optional_u64(request, name) do
    if Map.has_key?(request, name), do: u64(request, name), else: {:ok, nil}
  end

  defp optional_boolean(request, name, default) do
    if Map.has_key?(request, name) do
      case Map.get(request, name) do
        value when is_boolean(value) -> {:ok, value}
        _invalid -> :error
      end
    else
      {:ok, default}
    end
  end

  defp nonempty_bytes(request, name, max_bytes) do
    case Wire.bytes(Map.get(request, name), max_bytes) do
      {:ok, bytes} when byte_size(bytes) > 0 -> {:ok, bytes}
      _invalid -> :error
    end
  end

  defp plain_object(request, name) do
    case Map.get(request, name) do
      value when is_map(value) and not is_struct(value) ->
        if plain_json?(value, 1), do: {:ok, value}, else: :error

      _invalid ->
        :error
    end
  end

  defp interaction_answer(request) do
    case Map.get(request, "answer") do
      %{"choice_id" => choice_id} = answer when map_size(answer) == 1 ->
        Wire.identity(choice_id)

      _invalid ->
        :error
    end
  end

  defp resource_string(request, name) do
    value = Map.get(request, name)
    if valid_resource_string?(value), do: {:ok, value}, else: :error
  end

  defp skill_name(request) do
    value = Map.get(request, "name")

    if valid_resource_string?(value, @skill_name_bytes) and Regex.match?(@skill_name, value),
      do: {:ok, value},
      else: :error
  end

  defp supporting_labels(request) do
    case Map.get(request, "supporting_labels") do
      labels when is_list(labels) and length(labels) <= 8 ->
        if Enum.all?(labels, &valid_resource_string?/1) and Enum.uniq(labels) == labels,
          do: {:ok, labels},
          else: :error

      _invalid ->
        :error
    end
  end

  defp resource_decision(request) do
    case Map.get(request, "decision") do
      nil ->
        {:ok, nil}

      decision when is_map(decision) and not is_struct(decision) ->
        keys = [
          "manifest_digest",
          "workspace_ref",
          "trust_scope",
          "decision_source",
          "issued_at",
          "expires_at",
          "revocation_state"
        ]

        exact_keys? = Enum.sort(Map.keys(decision)) == Enum.sort(keys)

        if map_size(decision) == length(keys) and exact_keys?,
          do: ResourcePack.normalize_decision(decision),
          else: :error

      _invalid ->
        :error
    end
  end

  defp valid_resource_string?(value, max_bytes \\ @resource_string_bytes) do
    is_binary(value) and byte_size(value) in 1..max_bytes and String.valid?(value) and
      not Regex.match?(@unsafe_resource_codepoints, value)
  end

  defp plain_json?(value, _depth) when is_nil(value) or is_boolean(value), do: true

  defp plain_json?(value, _depth) when is_integer(value),
    do: value in @min_json_integer..@max_json_integer

  defp plain_json?(value, _depth) when is_binary(value),
    do: byte_size(value) <= @max_json_string_bytes and String.valid?(value)

  defp plain_json?(value, depth) when is_list(value) and depth <= @max_json_depth do
    length(value) <= @max_json_members and Enum.all?(value, &plain_json?(&1, depth + 1))
  end

  defp plain_json?(value, depth)
       when is_map(value) and not is_struct(value) and depth <= @max_json_depth do
    map_size(value) <= @max_json_members and
      Enum.all?(value, fn {key, member} ->
        is_binary(key) and byte_size(key) <= @max_json_string_bytes and String.valid?(key) and
          plain_json?(member, depth + 1)
      end)
  end

  defp plain_json?(_value, _depth), do: false

  defp field(request, name, decoder) do
    case decoder.(Map.get(request, name)) do
      {:ok, value} -> {:ok, value}
      _invalid -> :error
    end
  end

  if Map.keys(@operations) |> Enum.sort() != V2.methods() |> Enum.sort() do
    raise "generation-two request parser method inventory drift"
  end
end
