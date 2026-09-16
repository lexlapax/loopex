defmodule Loopex.Telemetry do
  @moduledoc """
  ## Concept

  The one Loopex-attached telemetry handler. It takes the spans core emits at
  its ports and transaction cuts and hands them to a runtime's diagnostics
  plane, where a host can read them. It decides nothing, publishes nothing
  durable, and never delays the process that emitted the event.

  ## Technical depth

  Telemetry runs handlers synchronously in the emitting process, which is why
  core attaches none of its own and why this one does no work worth measuring:
  it builds a bounded plain item and offers it to the runtime's asynchronous
  admission path, which either takes it or drops it and counts the drop. It
  never performs I/O, never calls the synchronous host-facing diagnostic entry,
  and never blocks on a sink, so a coordinator emitting a span pays the cost of
  one map and one send at most.

  The handler is attached per runtime with that runtime's own admission handle,
  so two runtimes in one VM neither share a handler nor see each other's events.
  Telemetry's own failure isolation detaches a handler that raises; this one has
  nothing to raise about, and anything it cannot express as bounded plain data
  it drops rather than forcing through.
  """

  alias Loopex.Runtime.DiagnosticsAdmission

  @handler_prefix "loopex-telemetry"

  @doc """
  ## Concept

  Attaches this handler to one runtime's events.

  ## Technical depth

  The handler identity carries the runtime reference, so attaching twice for one
  runtime is idempotent at the telemetry level and two runtimes never collide.
  The admission handle is read once here rather than per event: it is plain
  data, and a runtime whose dispatcher restarts gets a fresh attachment rather
  than a handler holding a dead table.
  """
  @spec attach(Loopex.Runtime.t()) :: :ok | {:error, term()}
  def attach(runtime) do
    with {:ok, admission} <- Loopex.Runtime.diagnostics_admission(runtime) do
      :telemetry.attach_many(
        handler_id(admission),
        events(),
        &__MODULE__.handle_event/4,
        admission
      )
    end
  end

  @doc """
  ## Concept

  Detaches this handler from one runtime's events.

  ## Technical depth

  The handler id is derived from that runtime's admission, so a detach names
  one runtime's handler and can never remove another's. A runtime with no
  admission returns that error unchanged rather than detaching something this
  handler does not own.
  """
  @spec detach(Loopex.Runtime.t()) :: :ok | {:error, term()}
  def detach(runtime) do
    with {:ok, admission} <- Loopex.Runtime.diagnostics_admission(runtime) do
      :telemetry.detach(handler_id(admission))
    end
  end

  @doc """
  ## Concept

  The exact events this handler carries.

  ## Technical depth

  The inventory accepted ADR 0030 fixes: the five ports and the six coordinator
  cuts, and no others. A callback or cut absent from this list is not
  instrumented, and adding one is an amendment to that decision rather than a
  line here.

  Every entry is a span, including the artifact-transfer lifecycle: it opens, is
  read many times and closes across three separate calls, so core emits its
  start and stop directly instead of wrapping one function, and the pair a
  handler sees is the same pair every other entry produces.
  """
  @spec events() :: [[atom()]]
  def events do
    spans = [
      [:loopex, :model, :complete],
      [:loopex, :store, :transact],
      [:loopex, :store, :transaction_status],
      [:loopex, :store, :runtime_command],
      [:loopex, :store, :ownership_head],
      [:loopex, :store, :load_records],
      [:loopex, :store, :load_events],
      [:loopex, :artifact, :put],
      [:loopex, :artifact, :fetch],
      [:loopex, :artifact, :stat],
      [:loopex, :artifact, :describe],
      [:loopex, :artifact, :open_transfer],
      [:loopex, :artifact, :read_transfer],
      [:loopex, :artifact, :close_transfer],
      [:loopex, :executor, :execute],
      [:loopex, :executor, :cancel],
      [:loopex, :executor, :retained_receipt],
      [:loopex, :policy, :decide],
      [:loopex, :command, :admit],
      [:loopex, :commit],
      [:loopex, :effect, :intent],
      [:loopex, :events, :publish],
      [:loopex, :interaction],
      [:loopex, :artifact, :transfer]
    ]

    Enum.flat_map(spans, fn span -> Enum.map([:start, :stop, :exception], &(span ++ [&1])) end)
  end

  @doc false
  @spec handle_event([atom()], map(), map(), term()) :: :ok
  def handle_event(event, measurements, metadata, admission) do
    item = %{
      "kind" => "telemetry_span",
      "event" => Enum.map_join(event, ".", &Atom.to_string/1),
      "measurements" => bounded(measurements),
      "metadata" => bounded(metadata)
    }

    _admitted = DiagnosticsAdmission.admit(admission, item)
    :ok
  end

  # Concept: identities and numbers cross this boundary; content does not.
  #
  # Technical depth: accepted ADR 0030 limits metadata to identities and
  # measurements to durations, counts and byte totals, and this is where that is
  # enforced rather than assumed. A value that is not bounded plain data is
  # replaced by its type, so a host that emitted something richer sees that it
  # was refused rather than receiving it.
  defp bounded(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), bounded_value(value)} end)
  end

  defp bounded(_other), do: %{}

  defp bounded_value(value) when is_binary(value) and byte_size(value) <= 256, do: value
  defp bounded_value(value) when is_integer(value) or is_float(value), do: value
  defp bounded_value(value) when is_boolean(value) or is_nil(value), do: value
  defp bounded_value(value) when is_atom(value), do: Atom.to_string(value)
  defp bounded_value(value) when is_binary(value), do: "binary/#{byte_size(value)}"
  defp bounded_value(_value), do: "unbounded"

  defp handler_id(%{dispatcher: dispatcher}),
    do: {@handler_prefix, dispatcher}
end
