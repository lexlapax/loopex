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
    "session.prompt",
    "session.follow_up",
    "session.steer",
    "session.abort"
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
  @spec call(map(), map()) :: {:ok, map()} | {:error, map()} | :unsupported
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
  defp admit(request, context, type, extra) do
    with :ok <- attached(context),
         {:ok, command_id} <- field(request, "command_id", &Wire.identity/1),
         {:ok, fields} <- command_fields(request, extra) do
      command = Map.merge(%{type: type, command_id: command_id}, fields)

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
  defp message(:commit_unknown), do: "the outcome of this command is not yet known"
  defp message(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp message(_reason), do: "the request could not be answered"
end
