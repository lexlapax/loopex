defmodule Mix.Tasks.Loopex.M7Evidence.Conversation do
  @moduledoc """
  ## Concept

  A bidirectional pipe for an M7 case conversation. It is the conversation's
  standard input and output at once, so a scripted driver can wait for what
  the conversation actually said, such as a question with its real
  interaction ID, before writing the next line. It never invents an ID.

  ## Technical depth

  One process serves the Erlang IO protocol for input and is chat's owned
  output target under accepted ADR 0068. Output bytes are retained in order. Input comes from a step list: `{:line, text}` writes one
  line; `{:await, text}` waits until output written after the previous await
  contains `text`; `{:answer, choice}` and `:decline` wait for the next
  unanswered `question` control record and write `/answer ID --choice CHOICE`
  or `/decline ID` with that record's exact printed identities; `choice`
  names a choice by its label or decoded identity. Every wait is bounded
  by the step deadline; expiry records `timeout` and ends input, which the
  conversation sees as end of file. `:lose` asks the
  `owner` process to end the conversation's host abruptly, the prescribed
  process loss; nothing is written after it. `{:answer, :operator}` asks the
  `owner` for the operator's typed choice for the next unanswered question,
  then answers it as above. `known` lists interaction IDs an earlier
  conversation of the same session already settled: a reopened conversation
  replays their records, and they are never answered again. `transcript/1` returns the output and the
  ordered observations without stopping the server.

  A held case adds four steps. `{:hold, fifo, limit_ms}` opens the harness
  FIFO for writing in a holder process and waits until the case's runner has
  opened it for reading, so the tool call is provably running. If `:release`
  has not run `limit_ms` after that, the holder is released, `hold_expired` is
  recorded and input ends: expiry is a retained failure, never a pass. `:observe` asks the
  `owner` for its independent observation and waits for the reply; a refused
  observation ends input. `:release` writes one line to the FIFO, which lets
  the runner finish; nothing else releases it. `:interrupt` asks the owner to
  deliver the terminal interrupt. `:await_gate` waits until the owner reports
  that its pre-transport model gate holds a request. Stopping the device closes the holder without
  writing, and an unopened FIFO is unblocked by a reader that discards nothing.
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
       stderr: "",
       target: nil,
       mark: 0,
       answered: known,
       pending: "",
       reader: nil,
       timer: nil,
       holder: nil,
       held: false,
       released: false,
       observed: nil,
       gate_held: false,
       operator_choice: nil,
       events: []
     }}
  end

  @impl true
  def handle_call(:transcript, _from, state),
    do:
      {:reply, %{output: state.output, stderr: state.stderr, events: Enum.reverse(state.events)},
       state}

  @impl true
  def handle_info({:io_request, from, reply_as, request}, state) do
    {:noreply, io(request, {from, reply_as}, state)}
  end

  # Concept: the conversation is also chat's owned ADR 0068 output target.
  # Technical depth: one acquisition only; a write is complete once appended
  # here, so the exact incarnation and nonce are answered at once. Standard
  # output feeds the awaits and transcript; standard error is kept apart.
  def handle_info({:loopex_cli_output_target, :acquire, owner, id}, %{target: nil} = state)
      when is_pid(owner) do
    incarnation = make_ref()
    send(owner, {:loopex_cli_output_target, :acquired, self(), id, incarnation})
    {:noreply, %{state | target: {owner, Process.monitor(owner), incarnation}}}
  end

  def handle_info({:loopex_cli_output_target, :acquire, owner, id}, state) when is_pid(owner) do
    send(owner, {:loopex_cli_output_target, :refused, self(), id})
    {:noreply, state}
  end

  def handle_info(
        {:loopex_cli_output_target, :write, owner, incarnation, nonce, destination, bytes},
        %{target: {owner, _monitor, incarnation}} = state
      )
      when destination in [:stdout, :stderr] and is_binary(bytes) do
    send(owner, {:loopex_cli_output_target, :written, self(), incarnation, nonce})

    if destination == :stdout,
      do: {:noreply, serve(%{state | output: state.output <> bytes})},
      else: {:noreply, %{state | stderr: state.stderr <> bytes}}
  end

  def handle_info(
        {:loopex_cli_output_target, :retire, owner, incarnation, nonce},
        %{target: {owner, monitor, incarnation}} = state
      ) do
    Process.demonitor(monitor, [:flush])
    send(owner, {:loopex_cli_output_target, :retired, self(), incarnation, nonce})
    {:noreply, %{state | target: :retired}}
  end

  def handle_info(
        {:DOWN, monitor, :process, _owner, _reason},
        %{target: {_, monitor, _}} = state
      ),
      do: {:noreply, %{state | target: :retired}}

  def handle_info({:held, {_pid, _fifo, limit} = holder}, %{holder: holder} = state) do
    Process.send_after(self(), {:hold_limit, holder}, limit)
    {:noreply, serve(%{state | held: true, events: [:held | state.events]})}
  end

  def handle_info({:hold_limit, {pid, _, _} = holder}, %{holder: holder, released: false} = state) do
    send(pid, :release)
    events = [:released, :hold_expired | state.events]
    {:noreply, serve(%{state | steps: [], released: true, events: events})}
  end

  def handle_info({:operator_choice, choice}, state),
    do: {:noreply, serve(%{state | operator_choice: {:chosen, choice}})}

  def handle_info(:gate_held, state),
    do: {:noreply, serve(%{state | gate_held: true, events: [:gate_held | state.events]})}

  def handle_info({:observed, result}, state),
    do:
      {:noreply, serve(%{state | observed: result, events: [{:observed, result} | state.events]})}

  def handle_info({:deadline, ref}, %{timer: ref} = state) do
    state = %{state | steps: [], timer: nil, events: [:timeout | state.events]}
    {:noreply, serve(state)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{holder: {pid, fifo, _limit}, held: held}) do
    # An unopened FIFO blocks its holder's open; one reader unblocks it.
    unless held, do: spawn(fn -> File.open(fifo, [:read, :raw]) end)
    Process.exit(pid, :kill)
  end

  def terminate(_reason, _state), do: :ok

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

      {:end, state} ->
        serve(%{cancel(state) | steps: []})

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

  # The operator's typed label or number selects among the emitted choices.
  defp next({:answer, :operator}, %{operator_choice: {:chosen, typed}} = state) do
    question(state, fn record ->
      selected =
        record["choices"]
        |> Kernel.||([])
        |> Enum.with_index(1)
        |> Enum.find(fn {entry, index} -> typed in [entry["label"], Integer.to_string(index)] end)

      case selected do
        {entry, _} -> "/answer #{record["interaction_id"]} --choice #{entry["id"]}"
        nil -> nil
      end
    end)
  end

  defp next({:answer, :operator}, %{operator_choice: nil} = state) do
    open =
      for "@loopex " <> json <- String.split(state.output, "\n"),
          {:ok, %{"event" => "question", "interaction_id" => id} = record} <- [JSON.decode(json)],
          id not in state.answered,
          do: record

    case open do
      [record | _] ->
        if state.owner, do: send(state.owner, {:conversation_choose, self(), record})
        {:wait, %{state | operator_choice: :asked}}

      [] ->
        {:wait, state}
    end
  end

  defp next({:answer, :operator}, state), do: {:wait, state}

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

  defp next({:hold, fifo, limit}, %{holder: nil} = state) do
    device = self()

    pid =
      spawn(fn ->
        {:ok, io} = File.open(fifo, [:write, :raw])
        send(device, {:held, {self(), fifo, limit}})

        receive do
          :release -> _ = :file.write(io, "released\n")
        end

        File.close(io)
      end)

    {:wait, %{state | holder: {pid, fifo, limit}}}
  end

  defp next({:hold, _fifo, _limit}, %{held: true} = state), do: {:skip, state}
  defp next({:hold, _fifo, _limit}, state), do: {:wait, state}

  defp next(:observe, %{observed: nil} = state) do
    if state.owner, do: send(state.owner, {:conversation_observe, self(), state.output})
    {:wait, %{state | observed: :pending}}
  end

  defp next(:observe, %{observed: :pending} = state), do: {:wait, state}
  defp next(:observe, %{observed: {:ok, _}} = state), do: {:skip, state}
  defp next(:observe, state), do: {:end, state}

  defp next(:release, %{holder: {pid, _fifo, _limit}, held: true} = state) do
    send(pid, :release)
    {:skip, %{state | released: true, events: [:released | state.events]}}
  end

  defp next(:await_gate, %{gate_held: true} = state), do: {:skip, state}
  defp next(:await_gate, state), do: {:wait, state}

  defp next(:interrupt, state) do
    if state.owner, do: send(state.owner, {:conversation_interrupt, self()})
    {:skip, %{state | events: [:interrupt | state.events]}}
  end

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
