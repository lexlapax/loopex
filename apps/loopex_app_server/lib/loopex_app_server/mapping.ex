defmodule Loopex.AppServer.Mapping do
  @moduledoc """
  ## Concept

  Where a wire request becomes a facade call and a facade answer becomes a wire
  record. Nothing here decides anything: the identities and meanings on both
  sides are the same ones, so a session created over the wire and a session
  created through the facade are the same session, described twice.

  ## Technical depth

  Accepted ADR 0023 makes this a client of the runtime rather than a second one.
  It owns no coordinator, no reducer, no Store access, no cursor truth and no
  policy, and it adds nothing to a durable command: a `command_id` a client sent
  is the `command_id` that commits, so a retry under the same identity is the
  facade's replay and not a second command this layer invented.

  Every field is decoded from its wire representation before the facade sees it,
  and the facade's own validators still apply afterwards. A refusal from either
  is reported as what it is. A commit whose outcome is unknown is never
  rendered as an admission, because a client that read a fabricated acceptance
  would stop retrying the one identity that could still resolve it.
  """

  alias LoopexProtocol.Wire

  @content_bytes 1_048_576

  @implemented [
    "session.create",
    "session.inspect",
    "session.attach",
    "session.prompt",
    "session.follow_up",
    "session.steer",
    "session.abort",
    "session.respond_interaction",
    "resources.catalog",
    "resources.read",
    "artifact.open_transfer",
    "artifact.read_chunk",
    "artifact.close_transfer",
    "session.resume",
    "session.admit_resources",
    "session.activate_skill"
  ]

  @doc """
  ## Concept

  Whether this build answers a method at all.

  ## Technical depth

  Asked before anything about a runtime, because a method this build does not
  implement is unsupported however well the connection is otherwise placed.
  Deciding the other way round would report a missing runtime for a method that
  does not exist, which tells a client to fix the wrong thing.
  """
  @spec implemented?(binary()) :: boolean()
  def implemented?(method) when is_binary(method), do: method in @implemented

  @doc """
  ## Concept

  Answers one already-initialized request against a runtime.

  ## Technical depth

  The connection supplies the runtime and, where a method needs one, the
  attachment; both are the caller's, not this module's. A method that this
  build does not yet answer returns `:unsupported`, so the caller reports the
  one refusal rather than each method inventing its own.
  """
  @spec call(map(), map()) ::
          {:ok, map()} | {:ok, map(), map()} | {:error, map()} | :unsupported
  def call(%{"method" => "session.create"} = request, context) do
    with {:ok, command_id} <- field(request, "command_id", &Wire.identity/1),
         {:ok, options} <- session_options(request) do
      case Loopex.create_session(context.runtime, options, command_id: command_id) do
        {:ok, session_id} ->
          {:ok,
           admission(request, command_id, "accepted", %{
             "session_id" => Wire.encode_identity(session_id)
           })}

        {:error, reason} ->
          {:ok, refused(request, command_id, reason)}
      end
    end
  end

  def call(%{"method" => "session.resume"} = request, context) do
    with {:ok, session_id} <- field(request, "session_id", &Wire.session_identity/1),
         {:ok, command_id} <- field(request, "command_id", &Wire.identity/1) do
      case Loopex.resume_session(context.runtime, session_id, command_id: command_id) do
        {:ok, resumed} ->
          {:ok,
           admission(request, command_id, "accepted", %{
             "session_id" => Wire.encode_identity(resumed)
           })}

        {:error, :recovery_required} ->
          {:error, error(request, "recovery_required", :recovery_required)}

        {:error, reason} ->
          {:ok, refused(request, command_id, reason)}
      end
    end
  end

  def call(%{"method" => "session.admit_resources"} = request, context) do
    with {:ok, manifest_digest} <- field(request, "manifest_digest", &Wire.digest/1),
         {:ok, decision} <- resource_decision(request) do
      admit(request, context, :admit_resources, [],
        manifest_digest: manifest_digest,
        decision: decision
      )
    end
  end

  def call(%{"method" => "session.activate_skill"} = request, context) do
    with {:ok, manifest_digest} <- field(request, "manifest_digest", &Wire.digest/1),
         {:ok, pack_digest} <- field(request, "pack_digest", &Wire.digest/1),
         {:ok, source_id} <- required_string(request, "source_id"),
         {:ok, name} <- required_string(request, "name"),
         {:ok, labels} <- supporting_labels(request) do
      admit(request, context, :activate_skill, [],
        manifest_digest: manifest_digest,
        pack_digest: pack_digest,
        source_id: source_id,
        name: name,
        supporting_labels: labels
      )
    end
  end

  def call(%{"method" => "session.inspect"} = request, context) do
    with {:ok, session_id} <- field(request, "session_id", &Wire.session_identity/1) do
      case Loopex.session_status(context.runtime, session_id) do
        {:ok, status} ->
          {:ok, result(request, projected_status(status))}

        {:error, reason} ->
          {:error, error(request, "facade_unavailable", reason)}
      end
    end
  end

  def call(%{"method" => "session.attach"} = request, context) do
    with {:ok, session_id} <- field(request, "session_id", &Wire.session_identity/1),
         {:ok, options} <- attach_options(request) do
      case Loopex.attach(context.runtime, session_id, options) do
        {:ok, attachment} ->
          # The attachment goes back with the snapshot because the connection,
          # not this call, is what holds it: a later command is admitted through
          # the same one, and a transport delivers what it publishes.
          {:ok, snapshot_record(request, attachment), %{attachment: attachment}}

        {:error, :attachment_conflict} ->
          {:error, error(request, "attachment_conflict", :attachment_conflict)}

        {:error, reason} ->
          {:error, error(request, "facade_unavailable", reason)}
      end
    end
  end

  def call(%{"method" => "resources.catalog"} = request, context) do
    with {:ok, session_id} <- field(request, "session_id", &Wire.session_identity/1) do
      case Loopex.resource_catalog(context.runtime, session_id) do
        {:ok, catalog} -> {:ok, result(request, catalog)}
        {:error, reason} -> {:error, error(request, "facade_unavailable", reason)}
      end
    end
  end

  def call(%{"method" => "resources.read"} = request, context) do
    with {:ok, session_id} <- field(request, "session_id", &Wire.session_identity/1),
         {:ok, read} <- resource_request(request) do
      case Loopex.read_resource(context.runtime, session_id, read) do
        {:ok, resource} -> {:ok, result(request, read_projection(resource))}
        {:error, reason} -> {:error, error(request, "facade_unavailable", reason)}
      end
    end
  end

  def call(%{"method" => "session.respond_interaction"} = request, context) do
    with {:ok, interaction_id} <- field(request, "interaction_id", &Wire.identity/1),
         {:ok, choice_id} <- answer_choice(request) do
      admit(request, context, :interaction_answer, [],
        interaction_id: interaction_id,
        choice_id: choice_id
      )
    end
  end

  def call(%{"method" => "artifact.open_transfer"} = request, context) do
    with :ok <- attached(context),
         {:ok, open} <- transfer_window(request) do
      case Loopex.open_artifact_transfer(context.attachment, open) do
        {:ok, transfer} -> {:ok, result(request, opened(transfer))}
        {:error, reason} -> {:error, transfer_refused(request, reason)}
      end
    end
  end

  def call(%{"method" => "artifact.read_chunk"} = request, context) do
    with :ok <- attached(context),
         {:ok, transfer_ref} <- field(request, "transfer_ref", &Wire.identity/1),
         {:ok, length} <- chunk_length(request) do
      case Loopex.read_artifact_chunk(context.attachment, transfer_ref, length) do
        {:ok, :complete} ->
          {:ok, result(request, %{"eof" => true})}

        {:ok, chunk} ->
          {:ok,
           result(request, %{
             "offset" => Wire.encode_u64(Map.fetch!(chunk, :offset)),
             "bytes_b64" => Wire.encode_bytes(Map.fetch!(chunk, :bytes)),
             "chunk_digest" => Map.fetch!(chunk, :chunk_digest),
             "eof" => false
           })}

        {:error, reason} ->
          {:error, transfer_refused(request, reason)}
      end
    end
  end

  def call(%{"method" => "artifact.close_transfer"} = request, context) do
    with :ok <- attached(context),
         {:ok, transfer_ref} <- field(request, "transfer_ref", &Wire.identity/1) do
      case Loopex.close_artifact_transfer(context.attachment, transfer_ref) do
        :ok -> {:ok, result(request, %{"closed" => true})}
        {:error, reason} -> {:error, transfer_refused(request, reason)}
      end
    end
  end

  def call(%{"method" => "session.prompt"} = request, context) do
    admit(request, context, :prompt, ["content_b64"])
  end

  def call(%{"method" => "session.follow_up"} = request, context) do
    admit(request, context, :follow_up, ["content_b64"])
  end

  def call(%{"method" => "session.steer"} = request, context) do
    admit(request, context, :steer, ["content_b64", "run_id"])
  end

  def call(%{"method" => "session.abort"} = request, context) do
    admit(request, context, :abort, [])
  end

  def call(_request, _context), do: :unsupported

  # Concept: one durable command, built from exactly what the client sent.
  #
  # Technical depth: the command identity is the client's, and no field this
  # layer invented joins it. An attachment is required because a command is
  # admitted through one; a client that has not attached is told that rather
  # than having an attachment opened on its behalf, which would make this layer
  # the owner of a cursor it has no right to.
  defp admit(request, context, type, extra, fixed \\ []) do
    with :ok <- attached(context),
         {:ok, command_id} <- field(request, "command_id", &Wire.identity/1),
         {:ok, fields} <- command_fields(request, extra) do
      command =
        %{type: type, command_id: command_id}
        |> Map.merge(fields)
        |> Map.merge(Map.new(fixed))

      case Loopex.command(context.attachment, command) do
        {:accepted, accepted_id} ->
          {:ok, admission(request, accepted_id, "accepted", %{})}

        {:error, :commit_unknown} ->
          {:error, error(request, "admission_unknown", :commit_unknown)}

        {:error, reason} ->
          {:ok, refused(request, command_id, reason)}
      end
    end
  end

  defp command_fields(request, extra) do
    Enum.reduce_while(extra, {:ok, %{}}, fn
      "content_b64", {:ok, acc} ->
        case field(request, "content_b64", &Wire.bytes(&1, @content_bytes)) do
          {:ok, content} when byte_size(content) > 0 ->
            {:cont, {:ok, Map.put(acc, :content, content)}}

          {:ok, _empty} ->
            {:halt, {:error, error(request, "invalid_request", :empty_content)}}

          {:error, refusal} ->
            {:halt, {:error, refusal}}
        end

      "run_id", {:ok, acc} ->
        case field(request, "run_id", &Wire.identity/1) do
          {:ok, run_id} -> {:cont, {:ok, Map.put(acc, :run_id, run_id)}}
          {:error, refusal} -> {:halt, {:error, refusal}}
        end
    end)
  end

  # Concept: the window a client asked to read, in the facade's own terms.
  #
  # Technical depth: the object and use identities are the compact reference the
  # client already holds, decoded here and never re-derived. A window length is
  # optional because an absent one means the rest of the object, which is
  # different from a length of zero and must stay different.
  defp transfer_window(request) do
    with {:ok, reference} <- field(request, "use_ref", &Wire.reference/1),
         {:ok, start_offset} <- required_u64(request, "start_offset"),
         {:ok, length} <- optional_u64_field(request, "window_length") do
      open = %{
        object: %{
          digest: reference.digest,
          size: reference.size,
          locator: reference.locator
        },
        use_locator: reference.use_locator,
        start: start_offset
      }

      {:ok, if(length, do: Map.put(open, :length, length), else: open)}
    end
  end

  defp required_u64(request, name) do
    case Wire.u64(Map.get(request, name)) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, error(request, "invalid_request", :invalid_field)}
    end
  end

  # Concept: how many bytes of object a client wants in one chunk.
  #
  # Technical depth: an ordinary integer rather than a decimal string, because
  # accepted ADR 0023 bounds it by the negotiated raw-chunk ceiling and a value
  # that small always fits a number both sides round-trip. The runtime bounds it
  # again regardless of what is asked.
  defp chunk_length(request) do
    case Map.get(request, "length") do
      length when is_integer(length) and length > 0 -> {:ok, length}
      _other -> {:error, error(request, "invalid_request", :invalid_field)}
    end
  end

  # Concept: the opened transfer, as identities and numbers.
  #
  # Technical depth: no path, no adapter handle and no private provenance
  # crosses. The transfer reference is opaque and belongs to the attachment that
  # opened it; the window bounds and the object digest are what let a client
  # verify the bytes it later receives.
  defp opened(transfer) do
    %{
      "transfer_ref" => Wire.encode_identity(Map.fetch!(transfer, :transfer_ref)),
      "total_size" => Wire.encode_u64(Map.fetch!(transfer, :total_size)),
      "window_start" => Wire.encode_u64(Map.fetch!(transfer, :window_start)),
      "window_end_exclusive" =>
        Wire.encode_u64(
          Map.fetch!(transfer, :window_start) + Map.fetch!(transfer, :window_length)
        ),
      "object_digest" => Map.fetch!(transfer, :object_digest)
    }
  end

  # Concept: a refused transfer, named by the cause accepted ADR 0028 closed.
  #
  # Technical depth: the reason is a core atom from that closed set, so it
  # carries a cause and never an adapter exception or a storage path. A reason
  # outside the set is not a cause a client can act on and collapses instead.
  defp transfer_refused(request, reason) when is_atom(reason) do
    %{
      "type" => "error",
      "code" => "transfer_refused",
      "reason" => Atom.to_string(reason),
      "message" => "the transfer was refused",
      "request_id" => Map.get(request, "request_id")
    }
  end

  defp transfer_refused(request, _reason), do: error(request, "internal_failure", :unknown)

  # Concept: the operator's decision about a project manifest, or none.
  #
  # Technical depth: accepted ADR 0023 admits `null` as well as the seven-field
  # M3 decision, because admitting resources without deciding anything about
  # them is a real operator action. What is present is passed through unchanged:
  # the decision is part of the durable command identity, so altering a member
  # here would change what the operator approved.
  defp resource_decision(request) do
    case Map.get(request, "decision") do
      nil -> {:ok, nil}
      decision when is_map(decision) -> {:ok, decision}
      _other -> {:error, error(request, "invalid_request", :invalid_field)}
    end
  end

  defp required_string(request, name) do
    case Map.get(request, name) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _other -> {:error, error(request, "invalid_request", :invalid_field)}
    end
  end

  # Concept: the ordered labels a skill activation carries.
  #
  # Technical depth: order is part of the command, so the list is passed
  # through as given rather than sorted or deduplicated. An absent list is an
  # empty one, which is an activation that supports nothing further.
  defp supporting_labels(request) do
    case Map.get(request, "supporting_labels") do
      nil ->
        {:ok, []}

      labels when is_list(labels) ->
        if Enum.all?(labels, &is_binary/1),
          do: {:ok, labels},
          else: {:error, error(request, "invalid_request", :invalid_field)}

      _other ->
        {:error, error(request, "invalid_request", :invalid_field)}
    end
  end

  # Concept: what a client may say about where its attachment starts.
  #
  # Technical depth: an absent cursor asks for the current tail, which is what a
  # client with no history of its own wants; a supplied one invokes the facade's
  # retained-cursor replay. `replace` is explicit because detaching another
  # attachment is a decision rather than a default.
  defp attach_options(request) do
    with {:ok, after_sequence} <- optional_u64_field(request, "after_event_sequence"),
         {:ok, replace} <- optional_boolean(request, "replace") do
      options = if replace, do: [replace: true], else: []

      options =
        if after_sequence,
          do: [{:after_event_sequence, after_sequence} | options],
          else: options

      {:ok, options}
    end
  end

  defp optional_u64_field(request, name) do
    case Map.get(request, name) do
      nil ->
        {:ok, nil}

      value ->
        case Wire.u64(value) do
          {:ok, decoded} -> {:ok, decoded}
          :error -> {:error, error(request, "invalid_request", :invalid_field)}
        end
    end
  end

  defp optional_boolean(request, name) do
    case Map.get(request, name) do
      nil -> {:ok, false}
      value when is_boolean(value) -> {:ok, value}
      _other -> {:error, error(request, "invalid_request", :invalid_field)}
    end
  end

  # Concept: an answer is exactly one offered choice, named by its identity.
  #
  # Technical depth: accepted ADR 0023 fixes the shape as a single-member object
  # so an answer cannot carry anything else a policy might read. Whether that
  # choice was offered is the reducer's decision, not this layer's: an answer is
  # not an allow and never becomes one here.
  defp answer_choice(request) do
    case Map.get(request, "answer") do
      %{"choice_id" => choice_id} = answer when map_size(answer) == 1 ->
        case Wire.identity(choice_id) do
          {:ok, decoded} -> {:ok, decoded}
          :error -> {:error, error(request, "invalid_request", :invalid_field)}
        end

      _other ->
        {:error, error(request, "invalid_request", :invalid_answer)}
    end
  end

  # Concept: the resource request a client named, in the facade's own terms.
  #
  # Technical depth: the four selectors are M3 strings and are passed through
  # unchanged. A request naming none of them is refused here, because the facade
  # would otherwise be asked to resolve nothing at all.
  defp resource_request(request) do
    fields =
      for {wire, key} <- [
            {"manifest_digest", :manifest_digest},
            {"source_id", :source_id},
            {"name", :name},
            {"label", :label}
          ],
          value = Map.get(request, wire),
          is_binary(value),
          into: %{},
          do: {key, value}

    if map_size(fields) == 0,
      do: {:error, error(request, "invalid_request", :invalid_field)},
      else: {:ok, fields}
  end

  # Concept: a resource read, with its bytes as bytes.
  #
  # Technical depth: content crosses base64url rather than as text, because a
  # project resource may hold anything and rendering it as a string would
  # corrupt what is not valid UTF-8.
  defp read_projection(%{digest: digest, size: size, content: content}) do
    %{
      "digest" => digest,
      "size" => Wire.encode_u64(size),
      "content_b64" => Wire.encode_bytes(content)
    }
  end

  defp read_projection(resource), do: resource

  # Concept: the attachment's authoritative snapshot, at its own cursor.
  #
  # Technical depth: the cursor and the snapshot's event sequence are the same
  # number, reported twice because a client reads one to place later events and
  # the other as part of the state it was handed. The open interaction is the
  # view at that same cursor, so a client never receives a question belonging to
  # a later moment than the snapshot it arrived with.
  defp snapshot_record(request, attachment) do
    snapshot = Loopex.snapshot(attachment)
    cursor = Map.get(snapshot, :event_sequence, 0)

    %{
      "type" => "snapshot",
      "request_id" => Map.get(request, "request_id"),
      "session_id" => Wire.encode_identity(Map.fetch!(snapshot, :session_id)),
      "event_cursor" => Wire.encode_u64(cursor),
      "snapshot" => %{
        "snapshot_revision" => Map.fetch!(snapshot, :snapshot_revision),
        "session_id" => Wire.encode_identity(Map.fetch!(snapshot, :session_id)),
        "event_sequence" => Wire.encode_u64(cursor),
        "active_run_id" => optional_identity(Map.get(snapshot, :active_run_id)),
        "active_run_phase" => optional_word(Map.get(snapshot, :active_run_phase))
      },
      "open_interaction" => Map.get(snapshot, :open_interaction)
    }
  end

  defp optional_word(nil), do: nil
  defp optional_word(value) when is_atom(value), do: Atom.to_string(value)
  defp optional_word(value) when is_binary(value), do: value

  defp attached(%{attachment: attachment}) when not is_nil(attachment), do: :ok
  defp attached(_context), do: {:error, %{"type" => "error", "code" => "not_attached"}}

  # Concept: the bounded options a client may supply at creation.
  #
  # Technical depth: absent is an empty set rather than an error, because a
  # session with no options is ordinary. What is present must already be plain
  # data: the frame decoder produced it, so nothing richer than JSON can be
  # here, and this layer adds no run policy of its own.
  defp session_options(request) do
    case Map.get(request, "session_options") do
      nil -> {:ok, %{}}
      options when is_map(options) -> {:ok, options}
      _other -> {:error, error(request, "invalid_request", :invalid_session_options)}
    end
  end

  defp field(request, name, decoder) do
    case decoder.(Map.get(request, name)) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, error(request, "invalid_request", :invalid_field)}
    end
  end

  # Concept: the public status projection, and only it.
  #
  # Technical depth: accepted ADR 0023 names the exact members. Owner epoch,
  # journal version, handles and attachment state are deliberately absent: they
  # are how the runtime keeps its promises, not what a client is owed, and a
  # client that could read them would start depending on them.
  defp projected_status(status) do
    %{
      "status" => to_string(Map.get(status, :status)),
      "event_sequence" => Wire.encode_u64(Map.get(status, :event_sequence, 0)),
      "active_run_id" => optional_identity(Map.get(status, :active_run_id)),
      "cleanup_grace_ms" => Wire.encode_u64(Map.get(status, :cleanup_grace_ms, 0)),
      "active_context_token_budget" =>
        optional_u64(Map.get(status, :active_context_token_budget)),
      "pending_work_ids" =>
        status |> Map.get(:pending_work_ids, []) |> Enum.map(&Wire.encode_identity/1),
      "open_interaction" => Map.get(status, :open_interaction)
    }
  end

  defp optional_identity(nil), do: nil
  defp optional_identity(value) when is_binary(value), do: Wire.encode_identity(value)

  defp optional_u64(nil), do: nil
  defp optional_u64(value) when is_integer(value), do: Wire.encode_u64(value)

  # Concept: one query answer, named by the method that asked.
  #
  # Technical depth: the method travels back with the result so a client holding
  # several answers can tell them apart without relying on the order they
  # arrived in, which is not a guarantee this protocol makes.
  defp result(request, body) do
    %{
      "type" => "result",
      "method" => Map.fetch!(request, "method"),
      "request_id" => Map.get(request, "request_id"),
      "result" => body
    }
  end

  defp admission(request, command_id, status, extra) do
    Map.merge(
      %{
        "type" => "admission",
        "method" => Map.fetch!(request, "method"),
        "request_id" => Map.get(request, "request_id"),
        "command_id" => Wire.encode_identity(command_id),
        "status" => status,
        "reason" => nil
      },
      extra
    )
  end

  # Concept: a refusal the facade decided, named by its own stable word.
  #
  # Technical depth: the reason is a core atom from a closed set, so rendering
  # it as text carries a category and never a message someone wrote. A reason
  # that is not an atom is not a category, and collapses rather than being
  # serialized.
  defp refused(request, command_id, reason) do
    request
    |> admission(command_id, "refused", %{})
    |> Map.put("reason", reason_word(reason))
  end

  defp reason_word(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_word(_reason), do: "internal_failure"

  defp error(request, code, reason) do
    %{
      "type" => "error",
      "code" => code,
      "message" => message(reason),
      "request_id" => Map.get(request, "request_id")
    }
  end

  defp message(:invalid_field), do: "a field is missing or not in its wire representation"
  defp message(:empty_content), do: "content must not be empty"
  defp message(:invalid_session_options), do: "session_options must be an object"
  defp message(:invalid_answer), do: "an answer must name exactly one offered choice"
  defp message(:attachment_conflict), do: "another attachment holds this session"
  defp message(:unknown), do: "the request could not be answered"
  defp message(:recovery_required), do: "this session cannot be resumed without recovery"
  defp message(:commit_unknown), do: "the outcome of this command is not yet known"
  defp message(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp message(_reason), do: "the request could not be answered"
end
