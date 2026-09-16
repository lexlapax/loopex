defmodule Loopex.AppServer.Connection do
  @moduledoc """
  ## Concept

  One connection's protocol state. Before a client and server have agreed on a
  generation nothing else is answered, and they agree exactly once: a second
  attempt is refused whether the first succeeded or failed, and a refused
  connection stays refused for as long as it lives.

  ## Technical depth

  Accepted ADR 0023 makes initialization mandatory, exact and one-time, and this
  is where that is enforced rather than assumed by the transport above it. The
  state is plain data with no process of its own, so the same rules hold for a
  stdio process, a test driving frames directly, and any later transport: a
  transport that forgot to check would have to reimplement the refusals instead
  of inheriting them.

  Nothing here reaches a runtime. A request that survives these rules is handed
  on with its generation settled; a request that does not never becomes durable
  work, which is the property that makes a refused initialization safe to leave
  a client holding.
  """

  alias Loopex.AppServer.Mapping
  alias LoopexProtocol.Session

  @enforce_keys [:state]
  defstruct state: :uninitialized,
            generation: nil,
            runtime: nil,
            attachment: nil,
            in_flight: MapSet.new()

  @type t :: %__MODULE__{
          state: :uninitialized | :initialized | :refused,
          generation: binary() | nil,
          runtime: term() | nil,
          attachment: term() | nil,
          in_flight: MapSet.t(binary())
        }

  @doc """
  ## Concept

  A connection that has negotiated nothing yet.

  ## Technical depth

  The runtime is the host's, handed in at launch rather than named by a client
  frame: accepted ADR 0023 keeps launch inputs outside the protocol, so no
  request can change which runtime a connection speaks to. A connection without
  one still negotiates and still refuses correctly; it simply has nothing to
  call, which is the shape a protocol-only test wants.
  """
  @spec new(keyword()) :: t()
  def new(options \\ []) do
    %__MODULE__{state: :uninitialized, runtime: Keyword.get(options, :runtime)}
  end

  @doc """
  ## Concept

  Binds the attachment a session's commands are admitted through.

  ## Technical depth

  One connection maps to one attachment, which is what lets a command, a
  transfer and a subscription belong to the same caller without a second table
  to keep in step.
  """
  @spec attach(t(), term()) :: t()
  def attach(%__MODULE__{} = connection, attachment),
    do: %{connection | attachment: attachment}

  @doc """
  ## Concept

  The attachment this connection holds, if it has one.

  ## Technical depth

  Read by a transport that has to deliver what the attachment publishes. It is
  the same attachment the mapping admits commands through, because one
  connection has exactly one.
  """
  @spec attachment(t()) :: term() | nil
  def attachment(%__MODULE__{attachment: attachment}), do: attachment

  @doc """
  ## Concept

  Claims a request identity for work that has begun and not yet answered.

  ## Technical depth

  Accepted ADR 0023 says a `request_id` is unique among the in-flight requests
  on a connection, that reuse while in flight refuses, and that no more than
  `max_requests_in_flight` are in flight at once. The rule lives here rather
  than in a transport, because a transport that answers serially can never
  break it and a transport that pipelines would have to reinvent it. This
  connection's own `dispatch/2` claims and releases around one synchronous
  answer, so the ceiling is never reached through it; a caller that answers
  asynchronously claims and releases around its own work and inherits the rule
  for free.

  The ceiling is checked before the identity is claimed, because checking after
  would make the bound whatever arrived plus one.
  """
  @spec begin_request(t(), binary()) :: {:ok, t()} | {:error, map(), t()}
  def begin_request(%__MODULE__{} = connection, request_id) when is_binary(request_id) do
    cond do
      MapSet.member?(connection.in_flight, request_id) ->
        {:error,
         error(
           "invalid_request",
           "this request identity is already in flight on this connection",
           request_id
         ), connection}

      MapSet.size(connection.in_flight) >= Map.fetch!(Session.limits(), "max_requests_in_flight") ->
        {:error,
         error("capacity_exceeded", "too many requests are in flight on this connection", nil),
         connection}

      true ->
        {:ok, %{connection | in_flight: MapSet.put(connection.in_flight, request_id)}}
    end
  end

  @doc """
  ## Concept

  Releases a request identity once its answer has been produced.

  ## Technical depth

  Releasing an identity that was never claimed is not an error: a caller that
  released twice, or released after a refusal that never claimed, is describing
  the same end state this function guarantees. Reuse after completion is
  ordinary correlation, so nothing here remembers that an identity was once
  used.
  """
  @spec complete_request(t(), binary()) :: t()
  def complete_request(%__MODULE__{} = connection, request_id) when is_binary(request_id) do
    %{connection | in_flight: MapSet.delete(connection.in_flight, request_id)}
  end

  @doc """
  ## Concept

  The request identities this connection is currently answering.

  ## Technical depth

  Returned sorted, so a caller and a test observe one order for a set that has
  none of its own. This is the connection's own accounting of requests it has
  begun and not yet finished, and it is what `max_requests_in_flight` is
  enforced against.
  """
  @spec in_flight(t()) :: [binary()]
  def in_flight(%__MODULE__{in_flight: in_flight}),
    do: in_flight |> MapSet.to_list() |> Enum.sort()

  @doc """
  ## Concept

  Whether this connection has settled on a generation.

  ## Technical depth

  Reads the settled state rather than the presence of a generation, so a
  connection whose initialization was refused is not mistaken for one that
  never attempted it.
  """
  @spec initialized?(t()) :: boolean()
  def initialized?(%__MODULE__{state: state}), do: state == :initialized

  @doc """
  ## Concept

  The generation this connection speaks, once it has one.

  ## Technical depth

  `nil` until initialization settles, so a caller cannot read a generation the
  connection has not actually agreed. Once set it does not change for the
  connection's life.
  """
  @spec generation(t()) :: binary() | nil
  def generation(%__MODULE__{generation: generation}), do: generation

  @doc """
  ## Concept

  Handles one `initialize` request.

  ## Technical depth

  The one negotiation this connection gets. A success fixes the generation for
  the connection's life; a refusal leaves it uninitialized and spends the
  attempt, because a client allowed to retry could walk a server's list until it
  found something, which is the negotiation this decision forbids. Both
  outcomes return the connection they produced, so a caller cannot answer a
  second attempt by forgetting the first.
  """
  @spec initialize(t(), map()) :: {:ok, map(), t()} | {:error, map(), t()}
  def initialize(%__MODULE__{state: :uninitialized} = connection, request) do
    with {:ok, request_id} <- request_id(request),
         {:ok, generations} <- generations(request),
         {:ok, capabilities} <- capabilities(request) do
      case Session.negotiate(generations, capabilities) do
        {:ok, reply} ->
          {:ok, Map.put(reply, "request_id", request_id),
           %{connection | state: :initialized, generation: reply["selected_generation"]}}

        {:error, :unsupported_generation} ->
          {:error,
           error(
             "unsupported_generation",
             "no offered protocol generation is supported by this server",
             request_id
           ), %{connection | state: :refused}}
      end
    else
      {:error, reason, request_id} ->
        {:error, error("invalid_request", reason, request_id), connection}
    end
  end

  def initialize(%__MODULE__{} = connection, request) do
    {:error,
     error(
       "already_initialized",
       "this connection has already spent its one initialization",
       safe_request_id(request)
     ), connection}
  end

  @doc """
  ## Concept

  Handles one request that is not `initialize`.

  ## Technical depth

  Order first, then existence. A method this generation does not name is
  refused as unsupported only once the connection is entitled to be asking at
  all, so a client that has not initialized learns that rather than learning
  which method names exist. Neither refusal reaches a facade, so neither
  creates durable work.
  """
  @spec dispatch(t(), map()) :: {:ok, map(), t()} | {:error, map(), t()}
  def dispatch(%__MODULE__{state: :initialized} = connection, request) do
    request_id = safe_request_id(request)

    case Map.get(request, "method") do
      method when is_binary(method) ->
        if method in Session.methods() do
          claimed(connection, request_id, &answer(&1, request, request_id))
        else
          {:error, error("unsupported_method", "no such method in this generation", request_id),
           connection}
        end

      _absent ->
        {:error, error("invalid_request", "method must be a string", request_id), connection}
    end
  end

  def dispatch(%__MODULE__{} = connection, request) do
    {:error,
     error(
       "not_initialized",
       "this connection must initialize before anything else",
       safe_request_id(request)
     ), connection}
  end

  # Concept: one answer, with its identity claimed for exactly as long as it
  # takes to produce.
  #
  # Technical depth: an identity that did not parse claims nothing, because an
  # unusable identity correlates nothing and two of them are not a collision.
  # The release runs on both outcomes, so a refusal does not strand an identity
  # a client may legitimately use again.
  defp claimed(connection, nil, answer), do: answer.(connection)

  defp claimed(connection, request_id, answer) do
    with {:ok, claimed} <- begin_request(connection, request_id) do
      case answer.(claimed) do
        {:ok, record, answered} -> {:ok, record, complete_request(answered, request_id)}
        {:error, record, answered} -> {:error, record, complete_request(answered, request_id)}
      end
    end
  end

  # Concept: a named method reaches the mapping, or says it is not answered yet.
  #
  # Technical depth: a method this generation names but this build has not
  # implemented is refused as unsupported rather than answered with a guess, and
  # a connection with no runtime cannot call a facade at all. Both refusals stop
  # before any durable work, which is what keeps an unfinished build safe to
  # speak to.
  defp answer(connection, request, request_id) do
    cond do
      not Mapping.implemented?(Map.fetch!(request, "method")) ->
        {:error,
         error("unsupported_method", "this build does not yet answer that method", request_id),
         connection}

      is_nil(connection.runtime) ->
        {:error,
         error("facade_unavailable", "this connection has no runtime to answer with", request_id),
         connection}

      true ->
        context = %{runtime: connection.runtime, attachment: connection.attachment}

        case Mapping.call(request, context) do
          {:ok, record} ->
            {:ok, record, connection}

          {:ok, record, %{attachment: attachment}} ->
            {:ok, record, attach(connection, attachment)}

          {:error, record} ->
            {:error, Map.put_new(record, "request_id", request_id), connection}

          :unsupported ->
            {:error,
             error(
               "unsupported_method",
               "this build does not yet answer that method",
               request_id
             ), connection}
        end
    end
  end

  # Concept: the request identity, which must be safe before it correlates
  # anything.
  #
  # Technical depth: accepted ADR 0023 bounds it to 1-64 characters from a
  # closed alphabet, and an error copies it back only when it parsed. A reply
  # that echoed an unvalidated identity would let a client choose bytes the
  # server then repeats, so a malformed one correlates nothing.
  defp request_id(request) do
    case Map.get(request, "request_id") do
      id when is_binary(id) ->
        if valid_request_id?(id),
          do: {:ok, id},
          else: {:error, "request_id is outside the admitted alphabet or length", nil}

      _other ->
        {:error, "request_id must be a string", nil}
    end
  end

  defp safe_request_id(request) do
    case Map.get(request, "request_id") do
      id when is_binary(id) -> if valid_request_id?(id), do: id, else: nil
      _other -> nil
    end
  end

  defp valid_request_id?(id) do
    byte_size(id) in 1..64 and
      id |> :binary.bin_to_list() |> Enum.all?(&admitted_request_id_byte?/1)
  end

  defp admitted_request_id_byte?(byte) do
    byte in ?A..?Z or byte in ?a..?z or byte in ?0..?9 or byte in [?., ?_, ?~, ?-]
  end

  defp generations(request) do
    case Map.get(request, "generations") do
      [_first | _rest] = generations ->
        if Enum.all?(generations, &is_binary/1),
          do: {:ok, generations},
          else: {:error, "generations must be strings", safe_request_id(request)}

      _other ->
        {:error, "generations must be a non-empty array", safe_request_id(request)}
    end
  end

  defp capabilities(request) do
    case Map.get(request, "capabilities") do
      capabilities when is_list(capabilities) ->
        if Enum.all?(capabilities, &is_binary/1),
          do: {:ok, capabilities},
          else: {:error, "capabilities must be strings", safe_request_id(request)}

      _other ->
        {:error, "capabilities must be an array", safe_request_id(request)}
    end
  end

  # Concept: one error record, carrying a correlation only when there is one.
  #
  # Technical depth: the message is server-authored text from this module. No
  # exception, no command content, no path and no policy term reaches it, which
  # is why every call site passes a fixed sentence rather than a formatted term.
  defp error(code, message, nil) do
    %{"type" => "error", "code" => code, "message" => message}
  end

  defp error(code, message, request_id) do
    %{"type" => "error", "code" => code, "message" => message, "request_id" => request_id}
  end
end
