defmodule Mix.Tasks.Loopex.M7Evidence.Conversation do
  @moduledoc """
  ## Concept

  A bidirectional pipe for an M7 case conversation. It is the conversation's
  standard input and output at once, so a scripted driver can wait for what
  the conversation actually said, such as a question with its real
  interaction ID, before writing the next line. It never invents an ID.

  ## Technical depth

  One process serves the Erlang IO protocol for both devices. Output bytes are
  retained in order. Input comes from a step list: `{:line, text}` writes one
  line; `{:await, text}` waits until output written after the previous await
  contains `text`; `{:answer, choice}` and `:decline` wait for the next
  unanswered `question` control record and write `/answer ID --choice CHOICE`
  or `/decline ID` with that record's exact printed identities; `choice`
  names a choice by its label or decoded identity. Every wait is bounded
  by the step deadline; expiry records `timeout` and ends input, which the
  conversation sees as end of file. `:lose` asks the
  `owner` process to end the conversation's host abruptly, the prescribed
  process loss; nothing is written after it. `known` lists interaction IDs an earlier
  conversation of the same session already settled: a reopened conversation
  replays their records, and they are never answered again. `transcript/1` returns the output and the
  ordered observations without stopping the server.
  """

  use GenServer

  @doc false
  def start(steps, deadline_ms \\ 120_000, known \\ [], owner \\ nil),
    do: GenServer.start(__MODULE__, {steps, deadline_ms, known, owner})

  @doc false
  def transcript(device), do: GenServer.call(device, :transcript)

  @doc false
  def stop(device), do: GenServer.stop(device)

  @impl true
  def init({steps, deadline, known, owner}) do
    {:ok,
     %{
       owner: owner,
       steps: steps,
       deadline: deadline,
       output: "",
       mark: 0,
       answered: known,
       pending: "",
       reader: nil,
       timer: nil,
       events: []
     }}
  end

  @impl true
  def handle_call(:transcript, _from, state),
    do: {:reply, %{output: state.output, events: Enum.reverse(state.events)}, state}

  @impl true
  def handle_info({:io_request, from, reply_as, request}, state) do
    {:noreply, io(request, {from, reply_as}, state)}
  end

  def handle_info({:deadline, ref}, %{timer: ref} = state) do
    state = %{state | steps: [], timer: nil, events: [:timeout | state.events]}
    {:noreply, serve(state)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp io({:put_chars, _encoding, chars}, client, state),
    do: reply(client, :ok, serve(%{state | output: state.output <> IO.iodata_to_binary(chars)}))

  defp io({:put_chars, _encoding, module, function, args}, client, state),
    do: io({:put_chars, :latin1, apply(module, function, args)}, client, state)

  defp io({:get_chars, _encoding, _prompt, count}, client, state),
    do:
      serve(%{state | reader: {client, {:chars, count}}, events: [{:read, count} | state.events]})

  defp io({:get_line, _encoding, _prompt}, client, state),
    do: serve(%{state | reader: {client, :line}})

  defp io({:setopts, _options}, client, state), do: reply(client, :ok, state)
  defp io(:getopts, client, state), do: reply(client, {:ok, [binary: true]}, state)
  defp io(_request, client, state), do: reply(client, {:error, :request}, state)

  defp reply({from, reply_as}, value, state) do
    send(from, {:io_reply, reply_as, value})
    state
  end

  defp serve(%{reader: nil} = state), do: state

  defp serve(%{reader: {client, want}, pending: pending} = state) when pending != "" do
    {bytes, rest} =
      case want do
        {:chars, count} ->
          size = min(count, byte_size(pending))
          {binary_part(pending, 0, size), binary_part(pending, size, byte_size(pending) - size)}

        :line ->
          case :binary.split(pending, "\n") do
            [line, rest] -> {line <> "\n", rest}
            [line] -> {line, ""}
          end
      end

    reply(client, bytes, %{state | pending: rest, reader: nil})
  end

  defp serve(%{steps: []} = state) do
    {client, _} = state.reader
    reply(client, :eof, %{state | reader: nil})
  end

  defp serve(%{steps: [step | rest]} = state) do
    case next(step, state) do
      {:write, line, state} ->
        events = [{:wrote, line} | state.events]
        serve(%{cancel(state) | steps: rest, pending: line <> "\n", events: events})

      {:skip, state} ->
        serve(%{cancel(state) | steps: rest})

      {:wait, state} ->
        arm(state)
    end
  end

  defp next({:line, line}, state), do: {:write, line, state}

  defp next({:await, text}, state) do
    seen = binary_part(state.output, state.mark, byte_size(state.output) - state.mark)

    case :binary.match(seen, text) do
      {start, length} -> {:skip, %{state | mark: state.mark + start + length}}
      :nomatch -> {:wait, state}
    end
  end

  defp next({:answer, choice}, state) do
    question(state, fn record ->
      selected =
        Enum.find(record["choices"] || [], fn entry ->
          entry["label"] == choice or
            Base.url_decode64(entry["id"], padding: false) == {:ok, choice}
        end)

      if selected, do: "/answer #{record["interaction_id"]} --choice #{selected["id"]}"
    end)
  end

  defp next(:decline, state), do: question(state, &"/decline #{&1["interaction_id"]}")

  # Controlled process loss: the owner kills the conversation's host; this
  # device writes nothing more.
  defp next(:lose, state) do
    if state.owner, do: send(state.owner, {:conversation_lose, self()})
    {:wait, %{state | steps: [:lost], events: [:process_loss | state.events]}}
  end

  defp next(:lost, state), do: {:wait, state}

  # Concept: only a question the conversation actually emitted is answered.
  # Technical depth: the first unanswered question record supplies the exact
  # printed interaction and choice identities; an unknown choice writes nothing
  # and the step waits until its deadline.
  defp question(state, render) do
    open =
      for "@loopex " <> json <- String.split(state.output, "\n"),
          {:ok, %{"event" => "question", "interaction_id" => id} = record} <- [JSON.decode(json)],
          id not in state.answered,
          do: record

    with [record | _] <- open, line when is_binary(line) <- render.(record) do
      {:write, line, %{state | answered: [record["interaction_id"] | state.answered]}}
    else
      _ -> {:wait, state}
    end
  end

  defp arm(%{timer: nil} = state) do
    ref = make_ref()
    Process.send_after(self(), {:deadline, ref}, state.deadline)
    %{state | timer: ref}
  end

  defp arm(state), do: state
  defp cancel(state), do: %{state | timer: nil}
end
