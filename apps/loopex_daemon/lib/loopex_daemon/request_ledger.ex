defmodule LoopexDaemon.RequestLedger do
  @moduledoc """
  ## Concept

  One daemon connection's account of the requests it has admitted and not yet
  answered, and of the one session it may serve. Every answer is correlated to
  exactly one admitted request, and a connection can never hold a lease on one
  session while attaching to another.

  ## Technical depth

  ADR 0023 bounds a connection to 32 in-flight requests with unique request
  identities. Each admitted request occupies one local slot and is named at
  the relay by `{connection_incarnation, slot, sequence}`; the strictly
  increasing sequence prevents slot-reuse ABA. ADR 0032's session binding is
  `unbound`, `reserving(session_id, request_id, request)` or
  `bound(session_id)`: the first acquire or attach reserves before any
  asynchronous work, an exact retransmission coalesces, and any other request
  naming a session while reserving, or naming another session once bound, is
  refused before any gate or side effect. This module is pure data and
  performs no IO.
  """

  alias LoopexProtocol.Session.V2

  @enforce_keys [:incarnation]
  defstruct incarnation: nil,
            next_sequence: 1,
            free_slots: Enum.to_list(0..31),
            requests: %{},
            request_ids: %{},
            binding: :unbound

  @typedoc false
  @type origin_id :: {binary(), 0..31, pos_integer()}

  @typedoc false
  @type binding ::
          :unbound
          | {:reserving, binary(), binary(), term()}
          | {:bound, binary()}

  @typedoc false
  @type t :: %__MODULE__{
          incarnation: binary(),
          next_sequence: pos_integer(),
          free_slots: [0..31],
          requests: %{origin_id() => map()},
          request_ids: %{binary() => origin_id()},
          binding: binding()
        }

  @doc false
  @spec new(binary()) :: t()
  def new(incarnation) when is_binary(incarnation), do: %__MODULE__{incarnation: incarnation}

  @doc false
  @spec begin(t(), binary(), map()) ::
          {:ok, origin_id(), t()} | {:error, :duplicate_request | :capacity_exceeded}
  def begin(%__MODULE__{} = ledger, request_id, entry)
      when is_binary(request_id) and is_map(entry) do
    cond do
      Map.has_key?(ledger.request_ids, request_id) ->
        {:error, :duplicate_request}

      map_size(ledger.requests) >= Map.fetch!(V2.limits(), "max_requests_in_flight") ->
        {:error, :capacity_exceeded}

      true ->
        [slot | free_slots] = ledger.free_slots
        origin = {ledger.incarnation, slot, ledger.next_sequence}
        entry = Map.put(entry, :request_id, request_id)

        {:ok, origin,
         %{
           ledger
           | next_sequence: ledger.next_sequence + 1,
             free_slots: free_slots,
             requests: Map.put(ledger.requests, origin, entry),
             request_ids: Map.put(ledger.request_ids, request_id, origin)
         }}
    end
  end

  @doc false
  @spec fetch(t(), origin_id()) :: {:ok, map()} | :error
  def fetch(%__MODULE__{requests: requests}, origin), do: Map.fetch(requests, origin)

  @doc false
  @spec update(t(), origin_id(), (map() -> map())) :: t()
  def update(%__MODULE__{} = ledger, origin, fun) do
    case Map.fetch(ledger.requests, origin) do
      {:ok, entry} -> %{ledger | requests: Map.put(ledger.requests, origin, fun.(entry))}
      :error -> ledger
    end
  end

  @doc false
  @spec complete(t(), origin_id()) :: {map() | nil, t()}
  def complete(%__MODULE__{} = ledger, {_incarnation, slot, _sequence} = origin) do
    case Map.pop(ledger.requests, origin) do
      {nil, _requests} ->
        {nil, ledger}

      {entry, requests} ->
        {entry,
         %{
           ledger
           | requests: requests,
             request_ids: Map.delete(ledger.request_ids, entry.request_id),
             free_slots: Enum.sort([slot | ledger.free_slots])
         }}
    end
  end

  @doc false
  @spec in_flight(t()) :: non_neg_integer()
  def in_flight(%__MODULE__{requests: requests}), do: map_size(requests)

  @doc """
  ## Concept

  Claims the connection's one session for an acquire or attach.

  ## Technical depth

  `request` is the decoded method and fields without the request identity's
  own bytes; equality with the reserving request is the canonical digest
  comparison ADR 0032 names.
  """
  @spec reserve(t(), binary(), binary(), term()) ::
          {:ok, t()} | :coalesced | {:error, :session_conflict}
  def reserve(%__MODULE__{binding: :unbound} = ledger, session_id, request_id, request),
    do: {:ok, %{ledger | binding: {:reserving, session_id, request_id, request}}}

  def reserve(
        %__MODULE__{binding: {:reserving, session_id, request_id, request}},
        session_id,
        request_id,
        request
      ),
      do: :coalesced

  def reserve(%__MODULE__{binding: {:bound, session_id}} = ledger, session_id, _id, _request),
    do: {:ok, ledger}

  def reserve(%__MODULE__{}, _session_id, _request_id, _request),
    do: {:error, :session_conflict}

  @doc false
  @spec admit_session(t(), binary()) :: :ok | {:error, :session_conflict}
  def admit_session(%__MODULE__{binding: :unbound}, _session_id), do: :ok
  def admit_session(%__MODULE__{binding: {:bound, session_id}}, session_id), do: :ok
  def admit_session(%__MODULE__{}, _session_id), do: {:error, :session_conflict}

  @doc false
  @spec bind(t(), binary(), binary()) :: t()
  def bind(
        %__MODULE__{binding: {:reserving, session_id, request_id, _}} = ledger,
        session_id,
        request_id
      ),
      do: %{ledger | binding: {:bound, session_id}}

  def bind(%__MODULE__{} = ledger, _session_id, _request_id), do: ledger

  @doc false
  @spec clear_reservation(t(), binary()) :: t()
  def clear_reservation(
        %__MODULE__{binding: {:reserving, _session_id, request_id, _}} = ledger,
        request_id
      ),
      do: %{ledger | binding: :unbound}

  def clear_reservation(%__MODULE__{} = ledger, _request_id), do: ledger

  @doc false
  @spec bound_session(t()) :: binary() | nil
  def bound_session(%__MODULE__{binding: {:bound, session_id}}), do: session_id
  def bound_session(%__MODULE__{}), do: nil
end
