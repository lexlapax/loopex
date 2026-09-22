defmodule LoopexDaemon.ConnectionProtocol do
  @moduledoc """
  ## Concept

  One daemon connection negotiates generation two exactly once before any
  daemon or session method can run. Invalid input reveals no method inventory
  and reaches no runtime work.

  ## Technical depth

  This pure state machine reuses generation two's contract metadata while
  retaining ADR 0023's request-identity, generation-list and capability-list
  validation. A well-formed unsupported offer spends the negotiation attempt;
  a malformed request does not. After negotiation, `LoopexDaemon.Request`
  enforces and decodes every named method's exact generation-two request shape;
  a valid request is returned to the connection as plain decoded data for
  serving, and nothing here performs a host or runtime effect.
  """

  alias LoopexDaemon.Request
  alias LoopexProtocol.Session.V2

  @enforce_keys [:state]
  defstruct state: :uninitialized, generation: nil

  @typedoc false
  @type t :: %__MODULE__{
          state: :uninitialized | :initialized | :refused,
          generation: binary() | nil
        }

  @typedoc false
  @type disposition :: :initialized | :none

  @doc false
  @spec new() :: t()
  def new, do: %__MODULE__{state: :uninitialized}

  @doc false
  @spec initialized?(t()) :: boolean()
  def initialized?(%__MODULE__{state: state}), do: state == :initialized

  @doc false
  @spec handle(t(), map()) ::
          {:ok | :error, map(), t(), disposition()} | {:request, Request.t(), t()}
  def handle(%__MODULE__{} = protocol, request) when is_map(request) do
    case Map.get(request, "method") do
      "initialize" -> initialize(protocol, request)
      _other -> dispatch(protocol, request)
    end
  end

  defp initialize(%__MODULE__{state: :uninitialized} = protocol, request) do
    with :ok <- initialize_fields(request),
         {:ok, request_id} <- request_id(request),
         {:ok, generations} <- generations(request),
         {:ok, capabilities} <- capabilities(request) do
      case V2.negotiate(generations, capabilities) do
        {:ok, reply} ->
          initialized = %{
            protocol
            | state: :initialized,
              generation: reply["selected_generation"]
          }

          {:ok, Map.put(reply, "request_id", request_id), initialized, :initialized}

        {:error, :unsupported_generation} ->
          {:error,
           error(
             "unsupported_generation",
             "no offered protocol generation is supported by this server",
             request_id
           ), %{protocol | state: :refused}, :none}
      end
    else
      {:error, reason} ->
        {:error, error("invalid_request", reason, safe_request_id(request)), protocol, :none}

      {:error, reason, request_id} ->
        {:error, error("invalid_request", reason, request_id), protocol, :none}
    end
  end

  defp initialize(%__MODULE__{} = protocol, request) do
    {:error,
     error(
       "already_initialized",
       "this connection has already spent its one initialization",
       safe_request_id(request)
     ), protocol, :none}
  end

  defp dispatch(%__MODULE__{state: :initialized} = protocol, request) do
    request_id = safe_request_id(request)

    case Request.parse(request) do
      {:ok, parsed} ->
        {:request, parsed, protocol}

      {:error, :unsupported_method} ->
        {:error, error("unsupported_method", "no such method in this generation", request_id),
         protocol, :none}

      {:error, :invalid_request} ->
        {:error,
         error(
           "invalid_request",
           "request does not match the generation-two contract",
           request_id
         ), protocol, :none}
    end
  end

  defp dispatch(%__MODULE__{} = protocol, request) do
    {:error,
     error(
       "not_initialized",
       "this connection must initialize before anything else",
       safe_request_id(request)
     ), protocol, :none}
  end

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

  defp initialize_fields(request) do
    allowed = MapSet.new(["method", "request_id", "generations", "capabilities"])

    if request |> Map.keys() |> Enum.all?(&MapSet.member?(allowed, &1)),
      do: :ok,
      else: {:error, "initialize request carries an unknown field"}
  end

  defp safe_request_id(request) do
    case Map.get(request, "request_id") do
      id when is_binary(id) -> if valid_request_id?(id), do: id, else: nil
      _other -> nil
    end
  end

  defp valid_request_id?(id) do
    Request.valid_request_id?(id)
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

  defp error(code, message, nil),
    do: %{"type" => "error", "code" => code, "message" => message}

  defp error(code, message, request_id) do
    %{"type" => "error", "code" => code, "message" => message, "request_id" => request_id}
  end
end
