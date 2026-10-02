defmodule LoopexComposition.DiagnosticConsumer do
  @moduledoc """
  ## Concept

  Drain one host's runtime diagnostics independently of stderr delivery. Chat,
  ask and daemon owners can share this consumer without mixing diagnostics with
  their results or durable events.

  ## Technical depth

  ADR 0049 fixes a 256-entry pending queue and one supervised IO worker. The
  drain accepts the existing `{:loopex_diagnostic, item}` sink messages while
  stderr is blocked. Rendered entries retain at most 4,096 bytes including LF.
  Trace and ordinary diagnostic delivery, drops and unconfirmed writes have
  separate counters. The mailbox is measured, not claimed bounded: runtime
  backpressure and direct senders retain ADR 0030's best-effort contract.

  Only the creating host may inspect or close this consumer. Closing discards
  its explicit queue and joins the IO worker and its private task supervisor
  within the earlier of the host deadline and captured cleanup grace. An
  unacknowledged write is delivery-unconfirmed, even if bytes may have reached
  stderr. Consumer cleanup proves nothing about session or provider cleanup.
  """

  use GenServer, restart: :temporary

  alias Loopex.Trace.Entry

  @queue_entries 256
  @entry_bytes 4_096

  @doc """
  ## Concept

  Start the diagnostic drain owned by the calling host.

  ## Technical depth

  The caller supplies its existing IO device and committed cleanup grace in
  milliseconds. This opens no file, runtime or trace. Owner loss stops the
  consumer and its linked private task supervisor; neither is restarted.
  """
  @spec start_link(IO.device(), non_neg_integer()) :: GenServer.on_start()
  def start_link(device, cleanup_grace_ms)
      when is_integer(cleanup_grace_ms) and cleanup_grace_ms >= 0,
      do: start_link({self(), device, cleanup_grace_ms})

  # Concept: a private supervisor starts the drain for its already-bound host.
  # Technical depth: the explicit owner comes from internal actor registration,
  # never from trace options. Public standalone startup captures its caller.
  @doc false
  def start_link({owner, device, cleanup_grace_ms})
      when is_pid(owner) and is_integer(cleanup_grace_ms) and cleanup_grace_ms >= 0,
      do: GenServer.start_link(__MODULE__, {owner, device, cleanup_grace_ms})

  # Concept: the host registers these private process identities before use.
  # Technical depth: this inspection is owner-only and is never a durable or
  # public session projection. A shutdown registration seals dispatch first.
  @doc false
  def owned_processes(consumer, timeout \\ 5_000),
    do: GenServer.call(consumer, :owned_processes, timeout)

  # Concept: the owner can keep handling its shutdown timer while writers end.
  # Technical depth: admission is bounded by the existing deadline. The result
  # message names the exact reference; a timed-out admission proves no cleanup.
  @doc false
  def begin_close(consumer, reference, deadline)
      when is_reference(reference) and is_integer(deadline) do
    GenServer.call(consumer, {:begin_close, reference, deadline}, remaining(deadline))
  catch
    :exit, _ -> {:error, :cleanup_unknown}
  end

  @doc """
  ## Concept

  Observe delivery counts and pending pressure without waiting on stderr.

  ## Technical depth

  Counts distinguish trace and diagnostic entries. Pending excludes the one
  active writer. Mailbox length is a current observation, not a capacity limit.
  No queued text, runtime reference or IO error detail appears in this view.
  """
  @spec status(pid()) :: map() | {:error, :not_diagnostic_owner}
  def status(consumer), do: GenServer.call(consumer, :status)

  @doc """
  ## Concept

  Stop diagnostic delivery and retain its final accounting after joining writers.

  ## Technical depth

  The deadline is an absolute monotonic millisecond cutoff shared with owner
  shutdown. It can shorten but never renew the captured cleanup grace. Queued
  entries count as dropped; an active write counts as emitted only with its IO
  acknowledgement, otherwise as unconfirmed. A missed process join returns
  cleanup_unknown rather than successful cleanup.
  """
  @spec close(pid(), integer()) ::
          {:ok, map()}
          | {:error, :cleanup_unknown, map()}
          | {:error, :not_diagnostic_owner | :invalid_diagnostic_deadline}
  def close(consumer, deadline), do: GenServer.call(consumer, {:close, deadline}, :infinity)

  @impl true
  def init({owner, device, grace}) do
    Process.flag(:trap_exit, true)
    {:ok, supervisor} = Task.Supervisor.start_link(max_children: 1)

    {:ok,
     %{
       owner: owner,
       owner_monitor: Process.monitor(owner),
       device: device,
       grace: grace,
       supervisor: supervisor,
       queue: :queue.new(),
       pending: 0,
       current: nil,
       closing: nil,
       counts: %{trace: counters(), diagnostic: counters()},
       failure: nil
     }}
  end

  @impl true
  def handle_call(_message, {caller, _}, %{owner: owner} = state) when caller != owner,
    do: {:reply, {:error, :not_diagnostic_owner}, state}

  def handle_call(:status, _from, state), do: {:reply, view(state), state}

  def handle_call(:owned_processes, _from, state), do: {:reply, {:ok, owned(state)}, state}

  def handle_call({:begin_close, ref, deadline}, _from, %{closing: nil} = state)
      when is_reference(ref) and is_integer(deadline) do
    deadline = min(deadline, now() + state.grace)
    send(self(), {:close_diagnostics, ref})
    {:reply, {:ok, owned(state)}, %{state | closing: {ref, deadline}}}
  end

  def handle_call({:begin_close, _, _}, _from, state),
    do: {:reply, {:error, :diagnostic_closing}, state}

  def handle_call({:close, deadline}, _from, state) when is_integer(deadline) do
    deadline = min(deadline, now() + state.grace)
    state = discard_queue(state)
    supervisor_joined = stop_supervisor(state.supervisor, deadline)
    {state, worker_joined} = stop_writer(state, deadline)
    final = view(%{state | supervisor: nil})

    reply =
      if worker_joined and supervisor_joined and now() <= deadline,
        do: {:ok, final},
        else: {:error, :cleanup_unknown, final}

    {:stop, :normal, reply, %{state | supervisor: nil}}
  end

  def handle_call({:close, _}, _from, state),
    do: {:reply, {:error, :invalid_diagnostic_deadline}, state}

  @impl true
  def handle_info({:loopex_diagnostic, item}, state) when is_map(item) and not is_struct(item) do
    kind = if item["kind"] in ["trace_call", "trace_dropped"], do: :trace, else: :diagnostic

    state =
      if state.failure == nil and state.closing == nil and state.pending < @queue_entries do
        bytes = Entry.render(item, @entry_bytes - 1) <> "\n"

        %{state | queue: :queue.in({kind, bytes}, state.queue), pending: state.pending + 1}
        |> dispatch()
      else
        count(state, kind, :dropped)
      end

    {:noreply, state}
  end

  def handle_info({ref, result}, %{current: %{task: %{ref: ref}} = current} = state),
    do: {:noreply, %{state | current: %{current | result: result}}}

  def handle_info({:DOWN, ref, :process, _, _}, %{owner_monitor: ref} = state),
    do: {:stop, :normal, state}

  def handle_info(
        {:DOWN, ref, :process, _, _},
        %{current: %{task: %{ref: ref}} = current} = state
      ) do
    retired = retire_writer(state.supervisor, current.task.pid)
    state = %{state | current: nil}
    counter = if current.result == :ok, do: :emitted, else: :unconfirmed
    state = count(state, current.kind, counter)

    state =
      if current.result == :ok and retired,
        do: dispatch(state),
        else: fail(state)

    {:noreply, state}
  end

  def handle_info({:EXIT, owner, _}, %{owner: owner} = state), do: {:stop, :normal, state}

  def handle_info({:EXIT, supervisor, _}, %{supervisor: supervisor} = state),
    do: {:noreply, fail(state)}

  def handle_info({:close_diagnostics, ref}, %{closing: {ref, deadline}} = state) do
    state = discard_queue(state)
    supervisor_joined = stop_supervisor(state.supervisor, deadline)
    {state, worker_joined} = stop_writer(state, deadline)
    final = view(%{state | supervisor: nil})

    result =
      if worker_joined and supervisor_joined and now() <= deadline,
        do: {:ok, final},
        else: {:error, :cleanup_unknown, final}

    send(state.owner, {:diagnostic_consumer_closed, self(), ref, result})
    {:stop, :normal, %{state | supervisor: nil}}
  end

  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def format_status(status) do
    Map.new(status, fn
      {:state, state} -> {:state, view(state)}
      {:message, _} -> {:message, :redacted}
      {:log, _} -> {:log, []}
      other -> other
    end)
  end

  @impl true
  def terminate(_, state) do
    deadline = now() + state.grace
    stop_supervisor(state.supervisor, deadline)
    {_state, _joined} = stop_writer(state, deadline)
    :ok
  end

  defp counters, do: %{emitted: 0, dropped: 0, unconfirmed: 0}

  # Concept: shutdown registration captures every process still able to write.
  # Technical depth: begin_close seals dispatch before replying with this list.
  # Previously completed workers were joined; after sealing, no new writer can
  # appear between registration and the asynchronous cleanup certificate.
  defp owned(state) do
    worker = if state.current, do: state.current.task.pid
    Enum.filter([self(), state.supervisor, worker], &is_pid/1)
  end

  defp count(state, kind, counter) do
    put_in(state.counts[kind][counter], state.counts[kind][counter] + 1)
  end

  defp view(state) do
    {:message_queue_len, mailbox} = Process.info(self(), :message_queue_len)

    %{
      counts: state.counts,
      pending: state.pending,
      active: state.current != nil,
      mailbox: mailbox,
      failure: state.failure
    }
  end

  defp dispatch(%{current: nil, failure: nil, closing: nil} = state) do
    case :queue.out(state.queue) do
      {{:value, {kind, bytes}}, rest} ->
        device = state.device
        task = Task.Supervisor.async_nolink(state.supervisor, fn -> write(device, bytes) end)

        %{
          state
          | current: %{task: task, kind: kind, result: nil},
            queue: rest,
            pending: state.pending - 1
        }

      {:empty, _} ->
        state
    end
  end

  defp dispatch(state), do: state

  defp write(device, bytes) do
    case IO.binwrite(device, bytes) do
      :ok -> :ok
      _ -> :error
    end
  rescue
    _ -> :error
  catch
    _, _ -> :error
  end

  defp discard_queue(state) do
    state =
      Enum.reduce(:queue.to_list(state.queue), state, fn {kind, _}, acc ->
        count(acc, kind, :dropped)
      end)

    %{state | queue: :queue.new(), pending: 0}
  end

  defp fail(state), do: %{discard_queue(state) | failure: :diagnostic_output_failed}

  # Concept: one completed writer releases the supervisor's one-child capacity.
  # Technical depth: the drain's DOWN and the supervisor's EXIT have different
  # recipients. Serialize removal before starting the next child; observing DOWN
  # alone cannot prove that the supervisor has processed its own exit signal.
  defp retire_writer(supervisor, writer) do
    Task.Supervisor.terminate_child(supervisor, writer) in [:ok, {:error, :not_found}]
  catch
    :exit, _ -> false
  end

  defp stop_writer(%{current: nil} = state, _), do: {state, true}

  defp stop_writer(%{current: %{task: task} = current} = state, deadline) do
    Process.exit(task.pid, :kill)

    joined =
      receive do
        {:DOWN, ref, :process, pid, _} when ref == task.ref and pid == task.pid -> true
      after
        remaining(deadline) -> false
      end

    result =
      receive do
        {ref, result} when ref == task.ref -> result
      after
        0 -> current.result
      end

    counter = if result == :ok, do: :emitted, else: :unconfirmed
    {count(%{state | current: nil}, current.kind, counter), joined}
  end

  defp stop_supervisor(nil, _), do: true

  # Concept: the private supervisor performs its own child shutdown first.
  # Technical depth: killing a writer and receiving its DOWN does not order its
  # linked EXIT at the supervisor before a stop request from this other sender.
  # Stop that supervisor, then collect both monitors under the same cutoff.
  defp stop_supervisor(supervisor, deadline) do
    ref = Process.monitor(supervisor)

    try do
      Supervisor.stop(supervisor, :normal, remaining(deadline))
    catch
      :exit, _ -> Process.exit(supervisor, :kill)
    end

    receive do
      {:DOWN, ^ref, :process, ^supervisor, _} -> true
    after
      remaining(deadline) ->
        Process.demonitor(ref, [:flush])
        false
    end
  end

  defp now, do: System.monotonic_time(:millisecond)
  defp remaining(deadline), do: max(deadline - now(), 0)
end
