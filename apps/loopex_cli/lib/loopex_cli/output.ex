defmodule LoopexCli.Output do
  @moduledoc """
  ## Concept

  One private output owner per command. It owns everything that can still put
  bytes in front of the operator: the native progress sink, the transcript
  queue, the evidence used to suppress a repeated answer and the physical
  writes. It is acquired before any runtime or provider work, keeps live output
  bounded when the terminal stops reading, and confirms delivery only after a
  complete write whose holder has joined.

  ## Technical depth

  Accepted ADR 0068. The command captures one acquisition, `D = A + 5,000 ms`,
  immediately before its first output effect. Sink opening, target launch or
  ownership transfer, and publication of the handle to the original command
  all spend `D`; publication must happen strictly before it. Failure or caller
  loss retires what was acquired within the remaining time, starts no runtime
  work and never writes through the failed target.

  The owner is unlinked from the command and monitors it. Only that command may
  reserve, submit, settle, finish or retire. Two targets exist: `:stdio`, the
  fixed Bash writer over the inherited descriptors, and `{:owned, pid}`, a
  custom target whose creator transferred exclusive ownership through the
  acquisition handshake. Borrowed IO devices are refused.

  The queue keeps ADR 0049 limits: 262,144 transcript bytes across
  reservations, queued and active output; control records of at most 65,536
  bytes, each with a 5,000-ms cutoff captured at reservation; one active write;
  progress dropped first under pressure and required output never dropped.
  Native items keep their lease through every rendered copy until the write
  joins or the copy is discarded. Suppression evidence is no further copy: a
  domain keeps only the SHA-256 state, length and fragment count of its answer
  bytes, so exact-text comparison needs no retained text outside native credit.
  A durable answer waits behind its streamed fragments and is suppressed only
  when the exact complete domain's fragments all joined. Uncertain delivery permits durable fallback and never a retry of
  an uncertain write. Diagnostics keep their own separate path.
  """

  use GenServer

  alias Loopex.ProgressSink
  alias LoopexCli.{ProgressConsumer, Render}
  alias LoopexCli.Output.Stdio

  @acquire_ms 5_000
  @queue_bytes 262_144
  @control_bytes 65_536
  @control_ms 5_000
  @finish_ms 5_000
  @current :loopex_cli_output

  @typedoc false
  @opaque t :: {:loopex_cli_output, pid(), reference()}

  @typedoc false
  @type acquisition :: %{started: integer(), cutoff: integer(), id: reference()}

  @doc """
  ## Concept

  Capture the one acquisition interval a command spends opening its output.

  ## Technical depth

  Call immediately before the first output-acquisition effect. The cutoff is
  never renewed: recovery, a second runtime or a late reply cannot extend it.
  """
  @spec acquisition() :: acquisition()
  def acquisition do
    started = now()
    %{started: started, cutoff: started + @acquire_ms, id: make_ref()}
  end

  @doc """
  ## Concept

  Acquire the command's output target and open its native progress sink.

  ## Technical depth

  `target` is `:stdio` or `{:owned, pid}` from trusted host code. Options are
  `mode: :plain | :chat` and, for chat, `progress_device: :stdout | :stderr`
  for progress that is not answer text. Returns the opaque handle and the
  unbound sink to give the one serving runtime. A failed or late open returns
  a fixed code and leaves cleanup to the unpublished owner.
  """
  @spec open(:stdio | {:owned, pid()}, acquisition(), keyword()) ::
          {:ok, t(), ProgressSink.t()} | {:error, atom()}
  def open(target, %{cutoff: cutoff, id: id} = acquisition, options \\ []) do
    cond do
      not valid_target?(target) ->
        {:error, :output_target_refused}

      now() >= cutoff ->
        {:error, :output_acquisition_expired}

      true ->
        {:ok, pid} = GenServer.start(__MODULE__, {self(), target, acquisition, options})
        monitor = Process.monitor(pid)

        receive do
          {:loopex_cli_output_opened, ^pid, ^id, {:ok, output, sink}} ->
            Process.demonitor(monitor, [:flush])

            if now() < cutoff do
              {:ok, output, sink}
            else
              send(pid, {:loopex_cli_output_abandon, id})
              {:error, :output_acquisition_expired}
            end

          {:loopex_cli_output_opened, ^pid, ^id, {:error, code}} ->
            Process.demonitor(monitor, [:flush])
            {:error, code}

          {:DOWN, ^monitor, :process, ^pid, _reason} ->
            {:error, :output_unavailable}
        after
          remaining(cutoff) ->
            send(pid, {:loopex_cli_output_abandon, id})
            Process.demonitor(monitor, [:flush])
            {:error, :output_acquisition_expired}
        end
    end
  end

  defp valid_target?(:stdio), do: true
  defp valid_target?({:owned, pid}) when is_pid(pid), do: pid != self()
  defp valid_target?(_), do: false

  @doc """
  ## Concept

  Reserve room for one already rendered record without sending its bytes.

  ## Technical depth

  Kinds are control, text and progress; destinations are stdout and stderr.
  Progress answers `:dropped` when it does not fit; required output first
  discards queued progress and otherwise fails the output. One reservation may
  be outstanding. The one-use ticket binds caller, incarnation, destination,
  kind, size and domain.
  """
  @spec reserve(t(), :control | :text | :progress, :stdout | :stderr, non_neg_integer(), term()) ::
          {:ok, term()} | :dropped | {:error, atom()}
  def reserve(output, kind, destination, size, domain \\ nil),
    do: call(output, {:reserve, kind, destination, size, domain})

  @doc """
  ## Concept

  Transfer exactly the reserved bytes to the queue.

  ## Technical depth

  Success is admission only. A wrong size, reused ticket or another caller
  fails the output.
  """
  @spec submit(t(), term(), binary()) :: :ok | {:error, atom()}
  def submit(output, ticket, bytes), do: call(output, {:submit, ticket, bytes})

  @doc """
  ## Concept

  Reserve and submit one record.

  ## Technical depth

  Empty output creates no queued item.
  """
  @spec write(t(), :control | :text | :progress, :stdout | :stderr, iodata(), term()) ::
          :ok | :dropped | {:error, atom()}
  def write(output, kind, destination, iodata, domain \\ nil) do
    bytes = IO.iodata_to_binary(iodata)

    if bytes == "" do
      :ok
    else
      with {:ok, ticket} <- reserve(output, kind, destination, byte_size(bytes), domain),
           do: submit(output, ticket, bytes)
    end
  end

  # Concept: wire-delivered progress joins the same transient view.
  # Technical depth: the daemon client already validated and credited the item;
  # this owner renders it under transcript pressure without a native lease.
  @doc false
  def progress(output, item), do: call(output, {:progress, item})

  # Concept: a durable answer is shown unless its streamed copy already was.
  # Technical depth: drain native progress first, choose the exact complete
  # candidate domain now, and decide at the head of the queue, after every
  # earlier fragment has either joined or failed.
  @doc false
  def assistant(output, event_sequence, content, rendered, destination \\ :stdout),
    do: call(output, {:assistant, event_sequence, content, rendered, destination})

  # Concept: a durable cursor retires earlier transient domains.
  @doc false
  def advance(output, cursor), do: call(output, {:advance, cursor})

  @doc """
  ## Concept

  Report and retire one domain's delivery evidence.

  ## Technical depth

  Undelivered queued fragments of that domain are discarded first; the answer
  contains only bounded counters.
  """
  def settle(output, domain), do: call(output, {:settle, domain})

  @doc """
  ## Concept

  Observe pressure and drop counts without blocking on IO.

  ## Technical depth

  Bytes include reservations and the active write. Failure is a fixed code or
  nil; no payload or raw error is exposed.
  """
  def status(output), do: call(output, :status)

  # Concept: stop showing transient progress before final records.
  # Technical depth: seal progress, discard its queued copies and answer the
  # stable drop count; required output keeps its lifecycle.
  @doc false
  def seal_progress(output), do: call(output, :seal_progress)

  # Concept: a prompt must reach the operator before input is read.
  # Technical depth: wait for every admitted item to join within one fresh
  # control cutoff; missing it fails the output.
  @doc false
  def flush(output) do
    cutoff = now() + @control_ms
    request(output, {:flush, cutoff}, cutoff)
  end

  @doc """
  ## Concept

  Seal admission, deliver what was admitted and join every original resource.

  ## Technical depth

  The cutoff defaults to five seconds from now and never extends an earlier
  control cutoff. The caller stops waiting at the cutoff; a late success cannot
  repair that verdict.
  """
  @spec finish(t(), integer()) :: :ok | {:error, atom()}
  def finish(output, cutoff \\ now() + @finish_ms),
    do: request(output, {:finish, cutoff}, cutoff)

  @doc """
  ## Concept

  Discard pending output and retire the target.

  ## Technical depth

  Used after failure or loss. Cleanup spends only the supplied cutoff.
  """
  @spec retire(t(), integer()) :: :ok | {:error, atom()}
  def retire(output, cutoff \\ now() + @finish_ms),
    do: request(output, {:retire, cutoff}, cutoff)

  # Concept: the command process names its own output owner and sink.
  # Technical depth: this is the original command's process dictionary, never
  # application state; the previous binding returns for restoration.
  @doc false
  def put_current(output, sink), do: Process.put(@current, {output, sink})

  @doc false
  def restore_current(nil), do: Process.delete(@current)
  def restore_current(previous), do: Process.put(@current, previous)

  @doc false
  def current do
    case Process.get(@current) do
      {{:loopex_cli_output, _pid, _incarnation} = output, _sink} -> output
      _ -> raise ArgumentError, "this command has no output owner"
    end
  end

  @doc false
  def current?, do: match?({{:loopex_cli_output, _, _}, _}, Process.get(@current))

  @doc false
  def current_sink do
    case Process.get(@current) do
      {{:loopex_cli_output, _, _}, sink} -> sink
      _ -> nil
    end
  end

  # Concept: ordinary command lines use the command's own output owner.
  # Technical depth: there is no borrowed-device fallback; a command without an
  # owner raises instead of writing to the group leader.
  @doc false
  def puts(destination \\ :stdout, text),
    do: write(current(), :text, destination, [to_string(text), "\n"])

  @doc false
  def put(destination \\ :stdout, iodata), do: write(current(), :text, destination, iodata)

  defp call({:loopex_cli_output, pid, incarnation}, message) do
    GenServer.call(pid, {incarnation, message}, :infinity)
  catch
    :exit, _ -> {:error, :output_unavailable}
  end

  defp request({:loopex_cli_output, pid, incarnation}, message, cutoff) do
    pid
    |> :gen_server.send_request({incarnation, message})
    |> :gen_server.receive_response(remaining(cutoff))
    |> case do
      {:reply, reply} -> reply
      :timeout -> {:error, :cleanup_unproved}
      {:error, _} -> {:error, :output_unavailable}
    end
  end

  # Owner process.

  @impl true
  def init({command, target, acquisition, options}) do
    Process.flag(:trap_exit, true)
    mode = Keyword.get(options, :mode, :plain)

    {:ok,
     %{
       command: command,
       command_monitor: Process.monitor(command),
       incarnation: make_ref(),
       acquisition: acquisition,
       target_spec: target,
       target: nil,
       mode: mode,
       progress_device: Keyword.get(options, :progress_device, :stderr),
       sink: nil,
       sink_monitor: nil,
       consumer: if(mode == :chat, do: ProgressConsumer.new(:chat), else: ProgressConsumer.new()),
       queue: :queue.new(),
       bytes: 0,
       reservation: nil,
       active: nil,
       sequence: 0,
       delivery: %{},
       dropped: 0,
       progress_sealed: false,
       failure: nil,
       waiters: [],
       closing: nil,
       timer: nil,
       delivery_deadline: nil
     }, {:continue, :acquire}}
  end

  # Concept: every acquisition stage spends the command's one original cutoff.
  # Technical depth: resources are recorded in state as soon as they exist, so
  # a failure at any later stage retires exactly what was created.
  @impl true
  def handle_continue(:acquire, state) do
    %{cutoff: cutoff, id: id} = state.acquisition

    result =
      with :ok <- fresh(cutoff),
           {:ok, sink} <- ProgressSink.open(),
           state = %{state | sink: sink, sink_monitor: Process.monitor(elem(sink, 0))},
           :ok <- fresh(cutoff),
           {:ok, state} <- acquire_target(state, cutoff) do
        if now() < cutoff, do: {:ok, state}, else: {:error, :output_acquisition_expired, state}
      else
        {:error, code, state} -> {:error, code, state}
        {:error, code} -> {:error, code, state}
      end

    case result do
      {:ok, state} ->
        output = {:loopex_cli_output, self(), state.incarnation}
        send(state.command, {:loopex_cli_output_opened, self(), id, {:ok, output, state.sink}})
        {:noreply, state}

      {:error, code, state} ->
        send(state.command, {:loopex_cli_output_opened, self(), id, {:error, code}})
        state |> fail(code) |> close(nil, cutoff)
    end
  end

  defp fresh(cutoff),
    do: if(now() < cutoff, do: :ok, else: {:error, :output_acquisition_expired})

  defp acquire_target(%{target_spec: :stdio} = state, cutoff) do
    nonce = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)

    case Stdio.launch(nonce) do
      {:ok, port, leader} ->
        target = %{
          kind: :stdio,
          port: port,
          leader: leader,
          nonce: nonce,
          control: "",
          exited: false,
          stopped: false,
          killed: false
        }

        await_ready(%{state | target: target}, "READY #{nonce} #{leader}\n", cutoff)

      :error ->
        {:error, :output_target_unavailable}
    end
  end

  defp acquire_target(%{target_spec: {:owned, pid}} = state, cutoff) do
    id = state.acquisition.id

    target = %{
      kind: :owned,
      pid: pid,
      monitor: Process.monitor(pid),
      incarnation: nil,
      stopped: false,
      retire_nonce: make_ref(),
      retired: false,
      lost: false
    }

    state = %{state | target: target}
    send(pid, {:loopex_cli_output_target, :acquire, self(), id})

    receive do
      {:loopex_cli_output_target, :acquired, ^pid, ^id, incarnation}
      when is_reference(incarnation) ->
        {:ok, put_in(state.target.incarnation, incarnation)}

      {:loopex_cli_output_target, :refused, ^pid, ^id} ->
        {:error, :output_target_refused, put_in(state.target.retired, true)}

      {:DOWN, _monitor, :process, ^pid, _reason} ->
        {:error, :output_target_unavailable, put_in(state.target.lost, true)}
    after
      remaining(cutoff) -> {:error, :output_acquisition_expired, state}
    end
  end

  # Concept: the writer is usable only after its exact readiness line.
  # Technical depth: the line may arrive in pieces; anything else, a longer
  # line or the writer's exit refuses the target within the original cutoff.
  defp await_ready(%{target: %{port: port}} = state, expected, cutoff) do
    receive do
      {^port, {:data, bytes}} ->
        control = state.target.control <> bytes

        cond do
          control == expected ->
            {:ok, put_in(state.target.control, "")}

          String.starts_with?(expected, control) ->
            await_ready(put_in(state.target.control, control), expected, cutoff)

          true ->
            {:error, :output_target_refused, state}
        end

      {^port, {:exit_status, _}} ->
        {:error, :output_target_refused, put_in(state.target.exited, true)}
    after
      remaining(cutoff) -> {:error, :output_acquisition_expired, state}
    end
  end

  @impl true
  def handle_call({incarnation, _message}, {caller, _}, state)
      when caller != state.command or incarnation != state.incarnation,
      do: {:reply, {:error, :not_output_owner}, state}

  def handle_call({_incarnation, message}, from, state),
    do: command(message, from, drain_sink(state))

  defp command(:status, _from, state),
    do: {:reply, %{bytes: state.bytes, dropped: state.dropped, failure: state.failure}, state}

  defp command({:finish, cutoff}, from, %{closing: nil} = state) when is_integer(cutoff),
    do: close(state, from, cutoff)

  defp command({:retire, cutoff}, from, %{closing: nil} = state) when is_integer(cutoff),
    do: state |> fail(:output_retired) |> close(from, cutoff)

  defp command(_message, _from, %{failure: failure} = state) when failure != nil,
    do: {:reply, {:error, failure}, state}

  defp command(_message, _from, %{closing: closing} = state) when closing != nil,
    do: {:reply, {:error, :output_closed}, state}

  defp command({:reserve, _, _, _, _}, _from, %{reservation: reservation} = state)
       when reservation != nil,
       do: {:reply, {:error, :invalid_output}, fail(state, :invalid_output)}

  defp command({:reserve, kind, destination, size, domain}, _from, state)
       when kind in [:control, :text, :progress] and destination in [:stdout, :stderr] and
              is_integer(size) and size > 0 do
    case admit(state, kind, size) do
      {:ok, state} ->
        reservation = %{
          ticket: make_ref(),
          kind: kind,
          destination: destination,
          size: size,
          domain: domain,
          deadline: if(kind == :control, do: now() + @control_ms)
        }

        state = %{state | reservation: reservation, bytes: state.bytes + size}
        {:reply, {:ok, reservation.ticket}, arm(state)}

      {:dropped, state} ->
        {:reply, :dropped, state}

      {:error, code, state} ->
        {:reply, {:error, code}, state}
    end
  end

  defp command({:submit, ticket, bytes}, _from, %{reservation: %{ticket: ticket} = r} = state)
       when is_binary(bytes) and byte_size(bytes) == r.size do
    item = %{
      kind: r.kind,
      destination: r.destination,
      bytes: bytes,
      domain: r.domain,
      deadline: r.deadline,
      lease: nil,
      candidate: nil
    }

    {:reply, :ok, %{state | reservation: nil} |> enqueue(item) |> dispatch() |> arm()}
  end

  defp command({:progress, item}, _from, state),
    do: {:reply, :ok, state |> consume(item, nil) |> dispatch() |> arm()}

  defp command({:assistant, sequence, content, rendered, destination}, _from, state)
       when is_binary(rendered) and destination in [:stdout, :stderr] do
    # Concept: only an answer with a durable position can match a stream.
    # Technical depth: without a positive sequence it is always written whole.
    {state, candidate} =
      if is_integer(sequence) and sequence > 0 do
        {consumer, candidate} =
          if state.mode == :chat,
            do: ProgressConsumer.chat_assistant(state.consumer, sequence, content),
            else: ProgressConsumer.plain_assistant(state.consumer, sequence, content)

        {retire_domains(%{state | consumer: consumer}, sequence, candidate), candidate}
      else
        {state, nil}
      end

    case {rendered, admit(state, :text, byte_size(rendered))} do
      {"", {:ok, state}} ->
        {:reply, :ok, state}

      {_rendered, {:ok, state}} ->
        item = %{
          kind: :text,
          destination: destination,
          bytes: rendered,
          domain: nil,
          deadline: nil,
          lease: nil,
          candidate: candidate
        }

        state = %{state | bytes: state.bytes + byte_size(rendered)}
        {:reply, :ok, state |> enqueue(item) |> dispatch() |> arm()}

      {_rendered, {:error, code, state}} ->
        {:reply, {:error, code}, state}
    end
  end

  defp command({:advance, cursor}, _from, state) when is_integer(cursor),
    do: {:reply, :ok, retire_domains(state, cursor, nil)}

  defp command({:settle, domain}, _from, state) do
    state = discard_progress(state, &(&1.domain == domain))
    counts = Map.get(state.delivery, domain, empty_counts())

    {:reply, Map.take(counts, [:admitted, :delivered, :dropped]),
     %{state | delivery: Map.delete(state.delivery, domain)}}
  end

  defp command(:seal_progress, _from, state) do
    state = discard_progress(state, fn _ -> true end)
    {:reply, state.dropped, %{state | progress_sealed: true}}
  end

  defp command({:flush, cutoff}, from, state) when is_integer(cutoff) do
    state = %{state | waiters: [{from, cutoff} | state.waiters]}
    {:noreply, state |> answer_waiters() |> arm()}
  end

  defp command(_message, _from, state),
    do: {:reply, {:error, :invalid_output}, fail(state, :invalid_output)}

  @impl true
  def handle_info({:loopex_progress_ready, sink}, %{sink: sink} = state),
    do: {:noreply, state |> drain_sink() |> dispatch() |> arm()}

  def handle_info({port, {:data, bytes}}, %{target: %{kind: :stdio, port: port}} = state) do
    control = state.target.control <> bytes

    if byte_size(control) <= Stdio.control_bytes(),
      do: progress_close(acknowledge(put_in(state.target.control, control))),
      else: progress_close(fail(state, :output_failed))
  end

  def handle_info({port, {:exit_status, _}}, %{target: %{kind: :stdio, port: port}} = state) do
    state = put_in(state.target.exited, true)
    expected = state.target.stopped and state.failure == nil and state.active == nil
    progress_close(if expected, do: state, else: fail(state, :output_failed))
  end

  # Concept: a closed control pipe is target loss, never a delivery.
  # Technical depth: the port may close on a broken control pipe without an
  # exit status; group absence, not this signal, later proves cleanup.
  def handle_info({:EXIT, port, _reason}, %{target: %{kind: :stdio, port: port}} = state) do
    state = put_in(state.target.exited, true)
    expected = state.target.stopped and state.failure == nil and state.active == nil
    progress_close(if expected, do: state, else: fail(state, :output_failed))
  end

  def handle_info(
        {:loopex_cli_output_target, :written, pid, incarnation, nonce},
        %{target: %{kind: :owned, pid: pid, incarnation: incarnation}, active: %{nonce: nonce}} =
          state
      ),
      do: progress_close(delivered(state))

  def handle_info(
        {:loopex_cli_output_target, :retired, pid, incarnation, nonce},
        %{target: %{kind: :owned, pid: pid, incarnation: incarnation, retire_nonce: nonce}} =
          state
      ),
      do: progress_close(put_in(state.target.retired, true))

  # Concept: a wrong actor, nonce or trailing acknowledgement retires the target.
  def handle_info({:loopex_cli_output_target, _, _, _, _}, %{target: %{kind: :owned}} = state),
    do: progress_close(fail(state, :output_failed))

  def handle_info({:DOWN, monitor, :process, _, _}, %{target: %{monitor: monitor}} = state) do
    state = put_in(state.target.lost, true)
    progress_close(fail(state, :output_failed))
  end

  def handle_info({:DOWN, monitor, :process, _, _}, %{command_monitor: monitor} = state) do
    state = %{state | command_monitor: nil}

    if state.closing,
      do: progress_close(state),
      else: state |> fail(:output_owner_lost) |> close(nil, now() + @finish_ms)
  end

  def handle_info({:DOWN, monitor, :process, _, _}, %{sink_monitor: monitor} = state),
    do: progress_close(fail(%{state | sink_monitor: nil, sink: nil}, :progress_sink_lost))

  def handle_info({:loopex_cli_output_abandon, id}, %{acquisition: %{id: id}} = state) do
    if state.closing,
      do: {:noreply, state},
      else: state |> fail(:output_acquisition_expired) |> close(nil, now() + @finish_ms)
  end

  def handle_info({:output_deadline, token}, %{timer: {_timer, token}} = state) do
    state = expire_waiters(%{state | timer: nil})
    state = if overdue?(state), do: fail(state, :output_drain_timeout), else: state
    progress_close(arm(state))
  end

  def handle_info(:join_poll, state), do: progress_close(state)

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def format_status(status) do
    Map.new(status, fn
      {:state, state} -> {:state, Map.take(state, [:bytes, :dropped, :failure])}
      {:message, _} -> {:message, :redacted}
      {:log, _} -> {:log, []}
      other -> other
    end)
  end

  # Native and wire progress.

  defp drain_sink(%{sink: nil} = state), do: state
  defp drain_sink(state), do: drain_sink(state, 32)

  defp drain_sink(state, 0), do: state

  defp drain_sink(state, remaining) do
    case ProgressSink.take(state.sink) do
      {:ok, lease, _session, item} -> drain_sink(consume(state, item, lease), remaining - 1)
      _ -> state
    end
  end

  # Concept: one transient item becomes at most one rendered copy under its lease.
  # Technical depth: an item with no visible action, or one that does not fit,
  # releases its lease at once; a queued copy holds it until its write joins.
  defp consume(state, item, lease) do
    {consumer, actions} = ProgressConsumer.consume(state.consumer, item)
    state = %{state | consumer: consumer}
    open? = not state.progress_sealed and state.failure == nil and state.closing == nil

    with true <- open?,
         [{channel, text} | _] <- actions,
         {:ok, bytes} when bytes != "" <- render_progress(state.mode, text) do
      destination = if channel == :stdout, do: :stdout, else: progress_destination(state)
      domain = if channel == :stdout, do: Map.get(item, :stream_domain_id)
      enqueue_progress(state, bytes, destination, domain, lease)
    else
      _ -> release(state, lease)
    end
  end

  defp progress_destination(%{mode: :chat, progress_device: device}), do: device
  defp progress_destination(_state), do: :stderr

  defp render_progress(:chat, text), do: Render.chat_text(text)
  defp render_progress(:plain, text), do: {:ok, text}

  defp enqueue_progress(state, bytes, destination, domain, lease) do
    case admit(state, :progress, byte_size(bytes)) do
      {:ok, state} ->
        item = %{
          kind: :progress,
          destination: destination,
          bytes: bytes,
          domain: domain,
          deadline: nil,
          lease: lease,
          candidate: nil
        }

        %{state | bytes: state.bytes + byte_size(bytes)}
        |> account(domain, :admitted)
        |> enqueue(item)

      {:dropped, state} ->
        state |> account(domain, :dropped) |> release(lease)
    end
  end

  defp release(state, nil), do: state
  defp release(%{sink: nil} = state, _lease), do: state

  defp release(state, lease) do
    case ProgressSink.release(state.sink, lease) do
      :ok -> state
      _ -> fail(state, :progress_sink_lost)
    end
  end

  # Admission and queue.

  defp admit(%{progress_sealed: true} = state, :progress, _size), do: {:dropped, state}

  defp admit(state, :control, size) when size > @control_bytes,
    do: {:error, :control_record_too_large, fail(state, :control_record_too_large)}

  defp admit(state, :progress, size) do
    if state.bytes + size <= @queue_bytes,
      do: {:ok, state},
      else: {:dropped, %{state | dropped: state.dropped + 1}}
  end

  defp admit(state, _required, size) do
    state =
      if state.bytes + size > @queue_bytes,
        do: discard_progress(state, fn _ -> true end),
        else: state

    if state.bytes + size <= @queue_bytes,
      do: {:ok, state},
      else: {:error, :output_overflow, fail(state, :output_overflow)}
  end

  defp enqueue(state, item) do
    state = %{state | queue: :queue.in(item, state.queue)}

    case item.candidate do
      {domain, _fragments} -> update_counts(state, domain, &%{&1 | pinned: true})
      nil -> state
    end
  end

  defp discard_progress(state, selected) do
    {progress, kept} =
      Enum.split_with(:queue.to_list(state.queue), &(&1.kind == :progress and selected.(&1)))

    Enum.reduce(progress, %{state | queue: :queue.from_list(kept)}, fn item, acc ->
      %{acc | bytes: acc.bytes - byte_size(item.bytes), dropped: acc.dropped + 1}
      |> account(item.domain, :dropped)
      |> release(item.lease)
    end)
  end

  defp empty_counts, do: %{admitted: 0, delivered: 0, dropped: 0, pinned: false}

  defp account(state, nil, _field), do: state

  defp account(state, domain, field),
    do: update_counts(state, domain, &Map.update!(&1, field, fn count -> count + 1 end))

  defp update_counts(state, domain, fun) do
    counts = Map.get(state.delivery, domain, empty_counts())
    %{state | delivery: Map.put(state.delivery, domain, fun.(counts))}
  end

  # Concept: domains before a durable cursor can no longer suppress anything.
  # Technical depth: their counters go unless a queued answer still waits on
  # them; their queued copies still drain and release their leases.
  defp retire_domains(state, cursor, candidate) do
    {consumer, retired} = ProgressConsumer.advance(state.consumer, cursor)
    keep = if candidate, do: elem(candidate, 0)

    delivery =
      Enum.reduce(retired, state.delivery, fn domain, acc ->
        case Map.get(acc, domain) do
          %{pinned: true} -> acc
          _ when domain == keep -> acc
          _ -> Map.delete(acc, domain)
        end
      end)

    %{state | consumer: consumer, delivery: delivery}
  end

  # Writes: one at a time, decided at the head of the queue.

  defp dispatch(%{active: nil, failure: nil, target: target} = state) when target != nil do
    case :queue.out(state.queue) do
      {:empty, _} ->
        state

      {{:value, %{candidate: {domain, fragments}} = item}, rest} ->
        counts = Map.get(state.delivery, domain, empty_counts())
        state = %{state | queue: rest, delivery: Map.delete(state.delivery, domain)}

        if counts.admitted == fragments and counts.delivered == fragments and counts.dropped == 0,
          do: dispatch(%{state | bytes: state.bytes - byte_size(item.bytes)}),
          else: start_write(state, item)

      {{:value, item}, rest} ->
        start_write(%{state | queue: rest}, item)
    end
  end

  defp dispatch(state), do: state

  defp start_write(state, item) do
    sequence = state.sequence + 1
    nonce = make_ref()
    state = %{state | sequence: sequence, active: Map.merge(item, %{nonce: nonce, seq: sequence})}

    sent =
      case state.target do
        %{kind: :stdio} = target ->
          Stdio.write(target.port, target.nonce, sequence, item.destination, item.bytes)

        %{kind: :owned} = target ->
          message =
            {:loopex_cli_output_target, :write, self(), target.incarnation, nonce,
             item.destination, item.bytes}

          send(target.pid, message)
          true
      end

    if sent, do: state, else: fail(state, :output_failed)
  end

  # Concept: only the exact next acknowledgement confirms a write.
  defp acknowledge(%{target: %{control: control}} = state) do
    case :binary.split(control, "\n") do
      [record, rest] ->
        state = put_in(state.target.control, rest)

        expected = state.active && "WRITTEN #{state.target.nonce} #{state.active.seq}"

        if record == expected,
          do: state |> delivered() |> acknowledge(),
          else: fail(state, :output_failed)

      [_partial] ->
        state
    end
  end

  defp delivered(%{active: item} = state) do
    state = %{state | active: nil, bytes: state.bytes - byte_size(item.bytes)}
    state = if item.kind == :progress, do: account(state, item.domain, :delivered), else: state
    state |> release(item.lease) |> dispatch() |> answer_waiters() |> arm()
  end

  defp answer_waiters(%{waiters: []} = state), do: state

  defp answer_waiters(state) do
    if state.active == nil and :queue.is_empty(state.queue) do
      Enum.each(state.waiters, fn {from, _cutoff} -> GenServer.reply(from, :ok) end)
      %{state | waiters: []}
    else
      state
    end
  end

  defp expire_waiters(state) do
    if Enum.any?(state.waiters, fn {_from, cutoff} -> now() >= cutoff end),
      do: fail(state, :output_drain_timeout),
      else: state
  end

  defp overdue?(state) do
    [state.reservation, state.active | :queue.to_list(state.queue)]
    |> Enum.any?(&(is_map(&1) and is_integer(&1.deadline) and now() >= &1.deadline))
  end

  # Concept: failure seals output and retires the target before any reuse.
  # Technical depth: the command learns once. Queued copies are discarded and
  # their leases released; an active write stays charged until retirement
  # proves its holder gone.
  defp fail(%{failure: nil} = state, reason) do
    send(state.command, {:loopex_cli_output_failed, state.incarnation, reason})
    Enum.each(state.waiters, fn {from, _} -> GenServer.reply(from, {:error, reason}) end)

    state =
      Enum.reduce(:queue.to_list(state.queue), state, fn item, acc ->
        release(%{acc | bytes: acc.bytes - byte_size(item.bytes)}, item.lease)
      end)

    stop_target(%{state | failure: reason, waiters: [], queue: :queue.new(), reservation: nil})
  end

  defp fail(state, _reason), do: state

  defp stop_target(%{target: nil} = state), do: state
  defp stop_target(%{target: %{stopped: true}} = state), do: state

  defp stop_target(%{target: %{kind: :stdio} = target} = state) do
    cond do
      target.exited ->
        put_in(state.target.stopped, true)

      state.failure == nil and state.active == nil ->
        Stdio.stop(target.port, target.nonce)
        put_in(state.target.stopped, true)

      true ->
        kill(state)
    end
  end

  defp stop_target(%{target: %{kind: :owned} = target} = state) do
    if target.incarnation != nil and not target.lost do
      send(
        target.pid,
        {:loopex_cli_output_target, :retire, self(), target.incarnation, target.retire_nonce}
      )
    end

    put_in(state.target.stopped, true)
  end

  # Closing.

  defp close(state, from, cutoff) do
    cutoff = min(cutoff, now() + @finish_ms)
    state = discard_progress(%{state | progress_sealed: true}, fn _ -> true end)
    progress_close(arm(%{state | closing: %{from: from, cutoff: cutoff}}))
  end

  # Concept: closing completes only after every original resource has joined.
  # Technical depth: a drained queue and no active write, then the target's
  # exact stop and join, then native sink close, all before the captured cutoff.
  defp progress_close(%{closing: nil} = state), do: {:noreply, state}

  defp progress_close(%{closing: closing} = state) do
    cond do
      now() >= closing.cutoff ->
        reply_close(state, {:error, :cleanup_unproved})

      state.failure == nil and (state.active != nil or not :queue.is_empty(state.queue)) ->
        {:noreply, state}

      # Concept: a lost custom target can never acknowledge its retirement.
      # Technical depth: its root DOWN does not prove downstream copies gone, so
      # the verdict is unproved at once rather than after the cutoff.
      match?(%{target: %{kind: :owned, lost: true, retired: false}}, state) ->
        reply_close(state, {:error, :cleanup_unproved})

      true ->
        state = stop_target(state)

        if target_joined?(state) do
          state =
            if state.active, do: release(%{state | active: nil}, state.active.lease), else: state

          close_sink(state)
        else
          Process.send_after(self(), :join_poll, 25)
          {:noreply, state}
        end
    end
  end

  defp target_joined?(%{target: nil}), do: true

  defp target_joined?(%{target: %{kind: :stdio} = target, closing: closing}),
    do: target.exited and Stdio.group_absent?(target.leader, closing.cutoff)

  defp target_joined?(%{target: %{kind: :owned} = target}),
    do: target.retired or target.incarnation == nil

  defp close_sink(%{sink: nil} = state), do: finish_close(state)

  defp close_sink(state) do
    if state.sink_monitor, do: Process.demonitor(state.sink_monitor, [:flush])
    result = ProgressSink.close(state.sink)
    state = %{state | sink: nil, sink_monitor: nil}

    if result == :ok,
      do: finish_close(state),
      else: reply_close(state, {:error, :cleanup_unproved})
  end

  defp finish_close(state) do
    reply =
      cond do
        now() >= state.closing.cutoff -> {:error, :cleanup_unproved}
        state.failure in [nil, :output_retired] -> :ok
        true -> {:error, state.failure}
      end

    reply_close(state, reply)
  end

  # Concept: a verdict never waits past its cutoff, and custody is not dropped.
  # Technical depth: an unproved close still ends the writer group, exactly
  # once; a group that already received its kill keeps that one retirement.
  defp reply_close(state, reply) do
    if state.closing.from, do: GenServer.reply(state.closing.from, reply)

    state =
      case state.target do
        %{kind: :stdio, exited: false, killed: false} -> kill(state)
        _ -> state
      end

    {:stop, :normal, state}
  end

  defp kill(%{target: %{killed: true}} = state), do: state

  defp kill(state) do
    Stdio.kill_group(state.target.leader)
    %{state | target: %{state.target | stopped: true, killed: true}}
  end

  # Concept: the earliest captured cutoff drives one timer.
  defp arm(state) do
    if state.timer, do: Process.cancel_timer(elem(state.timer, 0))
    state = notify_delivery_deadline(state)

    deadlines =
      [state.closing, state.reservation, state.active | :queue.to_list(state.queue)]
      |> Enum.flat_map(fn
        %{cutoff: cutoff} -> [cutoff]
        %{deadline: deadline} when is_integer(deadline) -> [deadline]
        _ -> []
      end)
      |> Kernel.++(Enum.map(state.waiters, &elem(&1, 1)))

    case deadlines do
      [] ->
        %{state | timer: nil}

      pending ->
        token = make_ref()
        delay = max(Enum.min(pending) - now(), 0)
        %{state | timer: {Process.send_after(self(), {:output_deadline, token}, delay), token}}
    end
  end

  # Concept: the command can shorten its own shutdown without waiting on IO.
  # Technical depth: notify only when the earliest admitted control cutoff
  # changes; clearing delivered controls cannot renew a captured cutoff.
  defp notify_delivery_deadline(state) do
    deadline =
      [state.reservation, state.active | :queue.to_list(state.queue)]
      |> Enum.flat_map(fn
        %{deadline: deadline} when is_integer(deadline) -> [deadline]
        _ -> []
      end)
      |> Enum.min(fn -> nil end)

    if deadline != state.delivery_deadline do
      send(state.command, {:loopex_cli_output_deadline, state.incarnation, deadline})
      %{state | delivery_deadline: deadline}
    else
      state
    end
  end

  defp remaining(cutoff), do: max(cutoff - now(), 0)
  defp now, do: System.monotonic_time(:millisecond)
end
