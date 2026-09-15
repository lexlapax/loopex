defmodule Loopex.AppServer.Stdio do
  @moduledoc """
  ## Concept

  The first transport: one long-lived process reading LF-delimited JSON objects
  from standard input and writing LF-delimited protocol records to standard
  output. Standard output carries protocol records and nothing else, so a
  client can parse every line it receives. Anything the operator should see goes
  to standard error.

  ## Technical depth

  Accepted ADR 0023 makes this a foreground host rather than a daemon: it owns
  no session residency, and its loss is an ordinary host loss. The loop holds
  only the connection state, so what it admits and refuses is decided by the
  protocol rules rather than reimplemented here.

  The reader takes raw bytes and finds the newline itself rather than asking the
  input device for a line. It has to: the device's own line reading strips a
  carriage return before the newline, and this decision makes CRLF a protocol
  error, so a reader that accepted the device's answer would silently admit a
  framing the contract refuses. Reading raw also lets the ceiling stop a frame
  while it is still arriving, instead of after a whole line has been held.
  """

  alias Loopex.AppServer.Connection
  alias LoopexProtocol.Frame
  alias LoopexProtocol.Session

  @doc """
  ## Concept

  Runs the connection until standard input ends.

  ## Technical depth

  Reads raw bytes rather than characters, because framing and the byte ceilings
  are defined in bytes and a character-oriented device would re-encode what a
  client sent. End of input ends the process; a partial line at end of input is
  reported as the protocol error it is before the process stops, so a client
  that was cut off mid-frame learns that rather than seeing silence.
  """
  @spec main([binary()]) :: :ok
  def main(_arguments \\ []) do
    case :file.open(~c"/dev/stdin", [:raw, :binary, :read]) do
      {:ok, input} ->
        loop(input, "", Connection.new())
        :file.close(input)
        :ok

      {:error, _reason} ->
        emit(invalid_frame("standard input is not readable as raw bytes"))
        :ok
    end
  end

  @read_chunk 65_536

  # Concept: frames out of a byte stream, one newline at a time.
  #
  # Technical depth: the buffer holds only what has arrived since the last
  # newline. A buffer that passes the ceiling without one is refused there and
  # then, and the rest of that oversized frame is discarded up to its newline
  # rather than parsed, so a client cannot spend the server's memory by never
  # finishing a frame.
  defp loop(input, buffer, connection) do
    case :binary.split(buffer, "\n") do
      [payload, rest] ->
        loop(input, rest, handle(payload, connection))

      [partial] ->
        cond do
          byte_size(partial) > ceiling(connection) ->
            emit(invalid_frame("the frame exceeds the ceiling in force"))
            discard(input, connection)

          true ->
            case :file.read(input, @read_chunk) do
              {:ok, bytes} ->
                loop(input, partial <> bytes, connection)

              :eof when partial == "" ->
                :ok

              :eof ->
                # End of input inside a frame. The bytes are not a frame, and
                # the process does not wait for a newline that is not coming.
                emit(invalid_frame("the input stream ended inside a frame"))
                :ok

              {:error, _reason} ->
                emit(invalid_frame("the input stream failed"))
                :ok
            end
        end
    end
  end

  # Concept: skip what is left of a frame already refused for its size.
  #
  # Technical depth: reading it into the buffer would defeat the refusal that
  # just happened, so the bytes are read and dropped until the newline that ends
  # that frame, and the connection carries on from the next one.
  defp discard(input, connection) do
    case :file.read(input, @read_chunk) do
      {:ok, bytes} ->
        case :binary.split(bytes, "\n") do
          [_dropped, rest] -> loop(input, rest, connection)
          [_dropped] -> discard(input, connection)
        end

      _eof_or_error ->
        :ok
    end
  end

  defp handle(payload, connection) do
    case Frame.decode(payload, ceiling(connection)) do
      {:ok, request} ->
        dispatch(request, connection)

      {:error, reason} ->
        # A frame that did not parse correlates nothing: there is no request
        # identity a server may trust in bytes it could not read.
        emit(invalid_frame(frame_reason(reason)))
        connection
    end
  end

  defp dispatch(request, connection) do
    result =
      case Map.get(request, "method") do
        "initialize" -> Connection.initialize(connection, request)
        _other -> Connection.dispatch(connection, request)
      end

    case result do
      {:ok, record, connection} ->
        emit(record)
        connection

      {:error, record, connection} ->
        emit(record)
        connection
    end
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
