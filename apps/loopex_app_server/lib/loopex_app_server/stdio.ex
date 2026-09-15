defmodule Loopex.AppServer.Stdio do
  @moduledoc """
  ## Concept

  The first transport: one long-lived process reading LF-delimited JSON objects
  from standard input and writing LF-delimited protocol records to standard
  output. Standard output carries protocol records and nothing else, so a client
  can parse every line it receives. Anything an operator should see goes to
  standard error.

  ## Technical depth

  Accepted ADR 0023 makes this a foreground host rather than a daemon: it owns
  no session residency, and its loss is an ordinary host loss.

  One process does everything: it reads, it answers, it pulls durable events,
  and it is the only writer. Input arrives as port messages rather than through
  a blocking read, which is what makes that possible. A read that asks a pipe
  for a block of bytes does not return until the block is full or the writer
  closes, so a server built that way answers a client's first frame only once
  the client has given up and disconnected. Bytes delivered as messages arrive
  when they arrive.

  The bytes are raw. The input device's own line reading strips a carriage
  return before the newline, and this decision makes CRLF a protocol error, so a
  server that trusted the device would silently admit a framing the contract
  refuses.

  The virtual machine must be started with `-noinput`, because it otherwise owns
  standard input for its own shell and two owners of one descriptor is not a
  thing that can be made to work. That is a launch requirement like any other
  and belongs with the rest of them; `serve/1` says so rather than discovering
  it, so an operator who forgets is told plainly instead of watching output
  vanish.
  """

  alias Loopex.AppServer.Connection
  alias Loopex.AppServer.Delivery
  alias LoopexProtocol.Frame
  alias LoopexProtocol.Session
  alias LoopexProtocol.Wire

  @idle_ms 20

  @doc """
  ## Concept

  Runs a connection with no runtime behind it.

  ## Technical depth

  It still speaks the protocol and still refuses every method that would need a
  facade, which is what makes an unconfigured launch safe rather than silent.
  """
  @spec main([binary()]) :: :ok
  def main(_arguments \\ []), do: serve(nil)

  @doc """
  ## Concept

  Runs the connection against a runtime the host already composed.

  ## Technical depth

  The runtime arrives as an argument rather than being named in a frame, because
  accepted ADR 0023 keeps launch inputs outside the protocol: which store,
  model, executor and policy a session runs under is the host's decision, and no
  later client frame can change it.
  """
  @spec serve(term()) :: :ok
  def serve(runtime) do
    unless noinput?() do
      IO.puts(
        :stderr,
        "loopex app-server: start the virtual machine with -noinput, " <>
          "or it keeps standard input for its own shell"
      )
    end

    port = Port.open({:fd, 0, 1}, [:in, :binary, :stream, :eof])

    loop(%{
      port: port,
      buffer: "",
      connection: Connection.new(runtime: runtime),
      delivery: nil
    })
  end

  # Concept: whether this machine left standard input to us.
  #
  # Technical depth: read from the emulator's own arguments rather than guessed
  # from behaviour, because the failure without it is a stolen descriptor and a
  # writer that dies on a broken pipe, which looks like anything but its cause.
  defp noinput? do
    :init.get_arguments()
    |> Enum.any?(fn {flag, _values} -> flag == :noinput end)
  end

  # Concept: the one loop, taking bytes, answering requests, and pulling events.
  #
  # Technical depth: the idle timeout is what turns an otherwise reactive loop
  # into one that also delivers. A frame already in the mailbox is taken before
  # the timeout fires, so delivery never delays a reply.
  defp loop(state) do
    port = state.port

    receive do
      {^port, {:data, bytes}} ->
        state |> absorb(bytes) |> loop()

      {^port, :eof} ->
        # End of input inside a frame. What is held is not a frame, and the
        # client is told that rather than left to wonder whether its last write
        # was read.
        if state.buffer != "", do: emit(invalid_frame("the input stream ended inside a frame"))
        :ok
    after
      @idle_ms -> state |> pull() |> loop()
    end
  end

  # Concept: frames out of a byte stream, one newline at a time.
  #
  # Technical depth: the buffer holds only what has arrived since the last
  # newline, and every complete frame in a chunk is answered before the next
  # chunk is read, so a client that writes several frames at once receives its
  # answers in the order it asked.
  defp absorb(state, bytes) do
    case :binary.split(state.buffer <> bytes, "\n") do
      [payload, rest] ->
        state
        |> handle(payload)
        |> Map.put(:buffer, "")
        |> absorb(rest)

      [partial] ->
        %{state | buffer: partial}
    end
  end

  # Concept: ask the attachment whether anything has committed.
  #
  # Technical depth: one read at a time, only while nothing else is waiting to
  # be answered. An empty answer is ordinary and means the session has published
  # nothing since the last read; disconnection ends delivery at the cursor a
  # client reattaches from.
  defp pull(%{delivery: nil} = state), do: state

  defp pull(state) do
    case Loopex.next_event(Connection.attachment(state.connection)) do
      {:ok, event} -> deliver(state, event)
      {:error, :empty} -> state
      {:disconnected, _cursor} -> detach(state)
      {:error, _reason} -> detach(state)
    end
  end

  defp handle(state, payload) do
    case Frame.decode(payload, ceiling(state.connection)) do
      {:ok, request} ->
        dispatch(state, request)

      {:error, reason} ->
        # A frame that did not parse correlates nothing: there is no request
        # identity a server may trust in bytes it could not read.
        emit(invalid_frame(frame_reason(reason)))
        state
    end
  end

  defp dispatch(state, request) do
    result =
      case Map.get(request, "method") do
        "initialize" -> Connection.initialize(state.connection, request)
        _other -> Connection.dispatch(state.connection, request)
      end

    case result do
      {:ok, %{"type" => "snapshot"} = record, connection} ->
        emit(record)
        start_delivery(%{state | connection: connection}, record)

      {:ok, record, connection} ->
        emit(record)
        %{state | connection: connection}

      {:error, record, connection} ->
        emit(record)
        %{state | connection: connection}
    end
  end

  # Concept: an attachment begins delivering the moment it exists.
  #
  # Technical depth: delivery starts only after the snapshot has been written,
  # so a client never receives an event for a cursor it has not been told about.
  # A second attachment on one connection replaces the first, because accepted
  # ADR 0023 maps one connection to one attachment.
  defp start_delivery(state, record) do
    with false <- is_nil(Connection.attachment(state.connection)),
         {:ok, cursor} <- Wire.u64(record["event_cursor"]),
         {:ok, session_id} <- Wire.identity(record["session_id"]) do
      %{state | delivery: Delivery.new(session_id, cursor)}
    else
      _other -> state
    end
  end

  defp deliver(state, event) do
    delivery = Delivery.event(state.delivery, event)
    {records, drained} = Delivery.take(delivery)
    Enum.each(records, &emit/1)

    if Delivery.detached?(drained) do
      emit(Delivery.detachment(drained))
      %{state | delivery: nil}
    else
      %{state | delivery: drained}
    end
  end

  defp detach(state) do
    emit(Delivery.detachment(state.delivery))
    %{state | delivery: nil}
  end

  # Concept: the frame ceiling in force right now.
  #
  # Technical depth: smaller before initialization, because an uninitialized
  # client has agreed to nothing and a server should not hold a megabyte on its
  # word alone.
  defp ceiling(connection) do
    limits = Session.limits()

    if Connection.initialized?(connection),
      do: limits["frame_bytes"],
      else: limits["frame_bytes_before_initialization"]
  end

  defp frame_reason(:frame_too_large), do: "the frame exceeds the ceiling in force"
  defp frame_reason(:invalid_utf8), do: "the frame is not valid UTF-8"
  defp frame_reason(:not_an_object), do: "a frame must be one JSON object"
  defp frame_reason(:trailing_bytes), do: "a frame carries bytes after its object"
  defp frame_reason(:truncated), do: "the frame ended early"
  defp frame_reason(:duplicate_member), do: "the frame repeats a member name"
  defp frame_reason(:depth_exceeded), do: "the frame nests beyond the admitted depth"
  defp frame_reason(:too_many_members), do: "a collection in the frame is too large"
  defp frame_reason(:string_too_large), do: "a string in the frame is too large"
  defp frame_reason(:integer_out_of_range), do: "an integer is outside the admitted range"
  defp frame_reason(:number_not_an_integer), do: "a number is not an integer"
  defp frame_reason(_reason), do: "the frame is malformed"

  defp invalid_frame(message) do
    %{"type" => "error", "code" => "invalid_frame", "message" => message}
  end

  # Concept: one record, one line, on standard output only.
  #
  # Technical depth: a record too large to send is replaced by the bounded error
  # that says so, because a client parsing lines must receive a whole record or
  # a whole refusal and never a fragment of either.
  defp emit(record) do
    case Frame.encode(record) do
      {:ok, encoded} ->
        IO.binwrite(:stdio, encoded)

      {:error, :output_record_too_large} ->
        {:ok, encoded} =
          Frame.encode(%{
            "type" => "error",
            "code" => "internal_failure",
            "message" => "the reply exceeds the output ceiling"
          })

        IO.binwrite(:stdio, encoded)
    end

    :ok
  end
end
