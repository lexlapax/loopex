defmodule Loopex.AppServer.Stdio do
  @moduledoc """
  ## Concept

  A foreground connection owns one joined output FIFO while continuing to
  receive strict LF input and cleanup control. EOF retires that connection's
  actual holders without aborting the durable session.

  ## Technical depth

  Accepted ADR 0058 reserves replies before facade dispatch and retains queued
  and active charges through OutputWriter's exact worker/group completion.
  One bounded request worker may call the runtime; Stdio remains the attachment
  holder and sole output owner. No shared standard-IO writer is used.
  """

  alias Loopex.AppServer.{Connection, Delivery, OutputWriter}
  alias LoopexProtocol.{Frame, Session, Wire}

  @idle_ms 20
  @request_ms 30_000
  @cleanup_ms 5_000

  @doc """
  ## Concept

  Runs the foreground protocol without a runtime.

  ## Technical depth

  Negotiation and closed refusals use the same owned FIFO and cleanup loop.
  """
  @spec main([binary()]) :: :ok | {:error, term()}
  def main(_arguments \\ []), do: serve(nil)

  @doc """
  ## Concept

  Serves the host's runtime on inherited stdin/stdout.

  ## Technical depth

  The trusted sink, when supplied, belongs to this same long-lived caller.
  Client frames select neither runtime placement nor progress custody.
  Start the VM with -noinput so this port exclusively owns stdin.
  """
  @spec serve(term(), term()) :: :ok | {:error, term()}
  def serve(runtime, sink \\ nil) do
    unless noinput?(),
      do: IO.puts(:stderr, "loopex app-server: start the virtual machine with -noinput")

    old_trap = Process.flag(:trap_exit, true)

    try do
      with {:ok, writer} <- OutputWriter.start() do
        monitor = Process.monitor(writer)
        key = {__MODULE__, make_ref()}

        # Concept: acquiring the independent writer immediately creates custody.
        # Technical depth: a surviving caller's caught setup/loop exception is
        # not owner DOWN. Retain this invocation's actual actors before the next
        # acquisition and clean them within the original captured episode.
        Process.put(key, %{writer: writer, writer_monitor: monitor})

        try do
          state =
            retain(%{
              port: nil,
              input: "",
              oversized: false,
              connection: Connection.new(runtime: runtime, holder: self()),
              delivery: Delivery.new(nil, 0),
              writer: writer,
              writer_monitor: monitor,
              writer_down: false,
              stop_request: nil,
              stop_result: nil,
              active_admitted: nil,
              output_pending: nil,
              job: nil,
              holder_result: nil,
              closing: false,
              cutoff: nil,
              failure: nil,
              sink: sink,
              releases: [],
              service_pending: false,
              poll_due: false,
              owned_key: key
            })

          port = Port.open({:fd, 0, 1}, [:in, :binary, :stream, :eof])
          state = retain(%{state | port: port})
          loop(state)
        catch
          kind, reason ->
            stacktrace = __STACKTRACE__
            cleanup_exception(Process.get(key), runtime, sink, key)
            :erlang.raise(kind, reason, stacktrace)
        after
          case Process.get(key) do
            %{closing: true} = state ->
              if settled?(state) and state.holder_result == :ok and
                   writer_stop_joined?(state.stop_result) and state.failure != :cleanup_unproved do
                Process.delete(key)
                Process.demonitor(monitor, [:flush])
              end

            _other ->
              :ok
          end
        end
      end
    after
      Process.flag(:trap_exit, old_trap)
    end
  end

  defp noinput?(), do: Enum.any?(:init.get_arguments(), fn {flag, _} -> flag == :noinput end)

  # Concept: input, output completion and cleanup share one serial owner.
  # Technical depth: every service turn dispatches at most one frame/read. A
  # single coalesced self-wake keeps buffered input moving without a recursive
  # batch dispatch or an output worker blocking EOF handling.
  defp loop(state) do
    state = retain(state)

    cond do
      state.closing and now_ms() >= state.cutoff -> expire_cleanup(state)
      true -> service_loop(state)
    end
  end

  defp service_loop(state) do
    state = state |> release_pending_output() |> release_discarded() |> retain()
    state = state |> service() |> retain()

    cond do
      state.closing and now_ms() >= state.cutoff ->
        expire_cleanup(state)

      settled?(state) ->
        finish(state)

      true ->
        receive do
          message -> state |> receive_message(message) |> loop()
        after
          @idle_ms -> %{state | poll_due: true} |> wake() |> loop()
        end
    end
  end

  defp receive_message(state, message) do
    case stop_response(state, message) do
      {:handled, state} -> state
      :other -> receive_owned(state, message)
    end
  end

  defp receive_owned(%{port: port, closing: false} = state, {port, {:data, bytes}})
       when is_binary(bytes) do
    # The already delivered port chunk is baseline input. Never concatenate an
    # arbitrarily large partial line or hold another decoded request while busy.
    limit = ceiling(state.connection)

    cond do
      byte_size(state.input) + byte_size(bytes) <= limit + 1 ->
        wake(%{state | input: state.input <> bytes})

      :binary.match(state.input, "\n") != :nomatch ->
        close(state, :input_pressure)

      true ->
        case :binary.match(bytes, "\n") do
          :nomatch ->
            %{state | input: "", oversized: true}

          {offset, 1} ->
            rest_size = byte_size(bytes) - offset - 1

            if rest_size <= limit and (state.oversized or byte_size(state.input) + offset > limit) do
              rest = binary_part(bytes, offset + 1, rest_size)
              wake(%{state | input: "\n" <> :binary.copy(rest), oversized: true})
            else
              close(state, :input_pressure)
            end
        end
    end
  end

  defp receive_owned(%{port: port} = state, {port, :eof}), do: close(state, nil)

  defp receive_owned(
         %{sink: sink, closing: false} = state,
         {:loopex_progress_ready, sink} = notification
       ) do
    # take/1 consumes its exact notification to clear/recheck the guardian flag.
    # Preserve that reference-only notification for this immediate owned take;
    # never forward a progress payload through the transport mailbox.
    send(self(), notification)
    consume_progress(state)
  end

  defp receive_owned(state, :service), do: %{state | service_pending: false}

  defp receive_owned(
         %{job: %{pid: pid, token: token} = job} = state,
         {:foreground_result, pid, token, result}
       ) do
    %{state | job: %{job | result: result}}
  end

  defp receive_owned(
         %{job: %{pid: pid, monitor: monitor} = job} = state,
         {:DOWN, monitor, :process, pid, reason}
       ) do
    Process.cancel_timer(job.timer)
    state = %{state | job: nil}

    if state.closing and job.kind != :cleanup do
      begin_holder_cleanup(state)
    else
      case {reason, job.result} do
        {:normal, result} when not is_nil(result) -> complete_job(state, job, result)
        _lost -> close(state, :request_worker_lost)
      end
    end
  end

  defp receive_owned(%{job: %{token: token}} = state, {:request_expired, token}),
    do: close(state, :request_expired)

  defp receive_owned(
         %{writer: writer} = state,
         {:loopex_output_writer_retired, writer, reference, reason}
       ) do
    case state.delivery.active do
      %{writer_ref: ^reference} ->
        close(state, if(state.closing and reason == :stopped, do: nil, else: reason))

      _stale ->
        state
    end
  end

  defp receive_owned(
         %{writer: writer} = state,
         {:loopex_output_writer, writer, reference, {:ok, %{cleanup: :joined}}}
       ) do
    case Delivery.joined(state.delivery, reference) do
      {:ok, entry, queue} ->
        wake(%{
          state
          | delivery: queue,
            connection: Connection.emitted(state.connection, queue.session_id, queue.cursor),
            active_admitted: nil,
            releases: lease_refs(entry) ++ state.releases
        })

      {:error, _reason, _queue} ->
        state
    end
  end

  defp receive_owned(
         %{writer: writer} = state,
         {:loopex_output_writer, writer, reference, {:error, reason, facts}}
       ) do
    case state.delivery.active do
      %{writer_ref: ^reference} ->
        reason = if state.closing and reason == :stopped, do: nil, else: reason

        if Map.get(facts, :cleanup) == :joined do
          {:ok, entry, queue} = Delivery.failed(state.delivery, reference)

          close(
            %{
              state
              | delivery: queue,
                releases: lease_refs(entry) ++ state.releases,
                active_admitted: nil
            },
            reason
          )
        else
          # Unproved cleanup retains the active frame/charge, lease and original
          # admission cutoff. Closing cannot reclaim or reuse its capacity.
          close(%{state | delivery: %{state.delivery | detached: true}}, reason)
        end

      _stale ->
        state
    end
  end

  defp receive_owned(
         %{writer: writer, writer_monitor: monitor} = state,
         {:DOWN, monitor, :process, writer, reason}
       ) do
    close(%{state | writer_down: true}, if(reason == :normal, do: nil, else: :writer_lost))
  end

  defp receive_owned(state, {:EXIT, _pid, :normal}), do: state
  defp receive_owned(state, {:EXIT, _pid, _reason}), do: close(state, :owned_actor_lost)
  defp receive_owned(state, _other), do: state

  defp service(%{closing: true} = state), do: state

  defp service(%{job: %{kind: :pending} = pending} = state) do
    state = start_output(state)

    if not Delivery.active?(state.delivery) and
         not preceding?(state.delivery, pending.reservation),
       do: resume_request(state, pending),
       else: state
  end

  defp service(state) do
    if is_nil(state.job) and :binary.match(state.input, "\n") != :nomatch do
      # A buffered durable request takes its reservation before any queued
      # transient frame can become active. Pending progress yields immediately.
      {entries, queue} = Delivery.discard_progress(state.delivery)
      leases = Enum.flat_map(entries, &lease_refs/1)
      service_input(%{state | delivery: queue, releases: leases ++ state.releases})
    else
      state = start_output(state)

      cond do
        state.closing ->
          state

        not is_nil(state.job) ->
          state

        state.poll_due and Delivery.ready?(state.delivery) and
            not is_nil(Connection.attachment(state.connection)) ->
          reserve_pull(state)

        true ->
          consume_progress(state)
      end
    end
  end

  defp service_input(state) do
    case :binary.split(state.input, "\n") do
      [payload, rest] ->
        state = %{state | input: rest}

        case Delivery.reserve(state.delivery) do
          {:ok, reservation, queue} ->
            state = %{state | delivery: queue}

            decoded =
              if state.oversized,
                do: {:error, :frame_too_large},
                else: Frame.decode(payload, ceiling(state.connection))

            state = %{state | oversized: false}

            case decoded do
              {:ok, request} ->
                start_request(state, reservation, request, now_ms() + @request_ms)

              {:error, reason} ->
                commit_error(state, reservation, invalid_frame(frame_reason(reason)))
            end

          :full ->
            close(state, :output_pressure)
        end

      [_partial] ->
        state
    end
  end

  defp start_request(state, reservation, request, cutoff) do
    # Replacement waits behind every earlier durable FIFO entry. An active old
    # attachment frame must settle before a worker replaces its native holder.
    if Map.get(request, "method") == "session.attach" and
         (Delivery.active?(state.delivery) or preceding?(state.delivery, reservation)) do
      token = make_ref()
      timer = Process.send_after(self(), {:request_expired, token}, max(cutoff - now_ms(), 0))

      %{
        state
        | job: %{
            kind: :pending,
            request: request,
            reservation: reservation,
            cutoff: cutoff,
            token: token,
            timer: timer
          }
      }
    else
      connection = state.connection

      job(
        state,
        :request,
        reservation,
        fn ->
          result =
            if Map.get(request, "method") == "initialize",
              do: Connection.initialize(connection, request),
              else: Connection.dispatch(connection, request)

          case result do
            {outcome, record, answered} when outcome in [:ok, :error] ->
              {frame, oversized} = reply_frame(record)
              {:reply, frame, record_metadata(record, answered), answered, oversized}
          end
        end,
        cutoff
      )
    end
  end

  defp resume_request(state, pending) do
    Process.cancel_timer(pending.timer)

    if now_ms() < pending.cutoff,
      do:
        start_request(%{state | job: nil}, pending.reservation, pending.request, pending.cutoff),
      else: close(%{state | job: nil}, :request_expired)
  end

  defp preceding?(queue, reservation) do
    case queue.entries do
      [%{token: ^reservation} | _rest] -> false
      _other -> true
    end
  end

  defp reserve_pull(state) do
    case Delivery.reserve(state.delivery) do
      {:ok, reservation, queue} ->
        attachment = Connection.attachment(state.connection)

        job(%{state | delivery: queue, poll_due: false}, :pull, reservation, fn ->
          Loopex.next_event(attachment)
        end)

      :full ->
        state
    end
  end

  defp job(state, kind, reservation, function, cutoff \\ nil) do
    owner = self()
    token = make_ref()
    cutoff = cutoff || if(state.closing, do: state.cutoff, else: now_ms() + @request_ms)

    {pid, monitor} =
      :erlang.spawn_opt(
        fn ->
          result = if now_ms() < cutoff, do: function.(), else: :request_expired
          send(owner, {:foreground_result, self(), token, result})
        end,
        [:link, :monitor]
      )

    duration = max(cutoff - now_ms(), 0)
    timer = Process.send_after(self(), {:request_expired, token}, duration)

    retain(%{
      state
      | job: %{
          kind: kind,
          reservation: reservation,
          pid: pid,
          monitor: monitor,
          cutoff: cutoff,
          token: token,
          timer: timer,
          result: nil
        }
    })
  end

  # Concept: intentional retirement is distinct from unexpected actor loss.
  # Technical depth: keep owner-loss linkage until the original kill is dispatched.
  # Unlink prevents future linked exits; drain only an already queued killed exit
  # for this exact job. Its original monitor still proves DOWN before cleanup.
  defp cancel_job(pid) do
    Process.exit(pid, :kill)
    Process.unlink(pid)

    receive do
      {:EXIT, ^pid, :killed} -> :ok
    after
      0 -> :ok
    end
  end

  defp complete_job(state, _job, :request_expired), do: close(state, :request_expired)

  defp complete_job(
         state,
         %{kind: :request, reservation: reservation},
         {:reply, frame, metadata, answered, oversized}
       ) do
    queue = state.delivery

    queue =
      case metadata do
        %{session: session, baseline: baseline, incarnation: incarnation} ->
          Delivery.attachment(queue, session, baseline, incarnation)

        _other ->
          queue
      end

    case Delivery.commit_frame(queue, reservation, frame, metadata) do
      {:ok, queue} ->
        state = %{state | delivery: queue, connection: answered}
        if oversized, do: close(state, :output_record_too_large), else: wake(state)

      {:error, _reason, queue} ->
        close(%{state | delivery: queue}, :output_pressure)
    end
  end

  defp complete_job(state, %{kind: :pull, reservation: reservation}, {:ok, event}) do
    record_queue = Delivery.cancel(state.delivery, reservation)
    # Event projection retains the same maximum reservation before encoding.
    queue = Delivery.event(record_queue, event)

    if Delivery.detached?(queue),
      do: close(%{state | delivery: queue}, :output_pressure),
      else: wake(%{state | delivery: queue})
  end

  defp complete_job(state, %{kind: :pull, reservation: reservation}, {:error, :empty}),
    do: %{state | delivery: Delivery.cancel(state.delivery, reservation)}

  defp complete_job(state, %{kind: :pull}, _disconnected), do: close(state, :attachment_lost)

  defp complete_job(state, %{kind: :cleanup} = job, :ok) do
    if cleanup_eligible?(state, job.cutoff),
      do: %{state | holder_result: :ok},
      else: %{state | holder_result: :unproved, failure: :cleanup_unproved}
  end

  defp complete_job(state, %{kind: :cleanup}, _failure),
    do: %{state | holder_result: :unproved, failure: :cleanup_unproved}

  # Concept: native credit survives wire encoding and the physical proxy.
  # Technical depth: requires rejoined ADR0058 projected profile
  # 8192 + 2*backing + 12*visible (raw 8*backing + 12*visible dominates it).
  # E <= 2*visible + 1024 for the closed fields. Encoder scope ends before
  # start_output: backing + host/driver/proxy(4E) + 4096 <= reserved credit.
  # Delivery retains only the flat LF frame, metadata and the exact lease.
  defp consume_progress(%{sink: nil} = state), do: state

  defp consume_progress(state) do
    case Loopex.ProgressSink.take(state.sink) do
      {:ok, lease, session, item} ->
        queue =
          if session == state.delivery.session_id and Delivery.ready?(state.delivery),
            do: Delivery.progress(state.delivery, item, lease),
            else: state.delivery

        if queue == state.delivery do
          %{state | releases: [lease | state.releases]}
        else
          wake(%{state | delivery: queue})
        end

      :empty ->
        state

      :closed ->
        state
    end
  end

  defp reply_frame(record) do
    case Delivery.encode(record) do
      {:ok, frame} ->
        {frame, false}

      {:error, :output_record_too_large} ->
        {:ok, frame} =
          Delivery.encode(%{
            "type" => "error",
            "code" => "internal_failure",
            "message" => "the reply exceeds the output ceiling"
          })

        {frame, true}
    end
  end

  defp record_metadata(%{"type" => "snapshot"} = record, connection) do
    {:ok, cursor} = Wire.u64(record["event_cursor"])
    {:ok, session} = Wire.identity(record["session_id"])

    {:ok, _runtime, ^session, attachment, incarnation} =
      Loopex.Attachment.routing(Connection.attachment(connection))

    %{session: session, baseline: cursor, incarnation: {attachment, incarnation}}
  end

  defp record_metadata(_record, _connection), do: %{}

  defp commit_error(state, reservation, record) do
    case Delivery.commit(state.delivery, reservation, record) do
      {:ok, queue} -> wake(%{state | delivery: queue})
      {:error, _reason, queue} -> close(%{state | delivery: queue}, :output_pressure)
    end
  end

  defp start_output(state) do
    case Delivery.next(state.delivery) do
      {:ok, entry} ->
        admitted = now_ms()
        state = retain(%{state | active_admitted: admitted, output_pending: entry})

        case OutputWriter.write(state.writer, entry.frame) do
          {:ok, reference} ->
            {:ok, queue} = Delivery.activate(state.delivery, entry.token, reference)
            retain(%{state | delivery: queue, active_admitted: admitted, output_pending: nil})

          {:error, reason} ->
            close(state, reason)
        end

      :empty ->
        state
    end
  end

  defp close(%{closing: true} = state, :cleanup_unproved),
    do: %{state | failure: :cleanup_unproved}

  defp close(%{closing: true} = state, reason),
    do: %{state | failure: state.failure || reason}

  defp close(state, reason) do
    input_result = close_input(state.port)
    {entries, queue} = Delivery.discard_queued(state.delivery)
    # A call may fail after physical admission and before its reference returns.
    # Keep that exact entry outside ordinary queued-discard credit until the
    # original writer has both acknowledged joined cleanup and gone DOWN.
    leases =
      entries
      |> Enum.reject(fn entry ->
        state.output_pending && entry.token == state.output_pending.token
      end)
      |> Enum.flat_map(&lease_refs/1)

    cutoff =
      if is_integer(state.active_admitted),
        do: min(now_ms() + @cleanup_ms, state.active_admitted + 10_000),
        else: now_ms() + @cleanup_ms

    failure = if input_result == :ok, do: reason, else: :cleanup_unproved

    state =
      retain(%{
        state
        | closing: true,
          port: nil,
          input: "",
          delivery: queue,
          releases: leases ++ state.releases,
          cutoff: cutoff,
          failure: failure
      })

    state = retain(request_writer_stop(state))

    case state.job do
      nil ->
        begin_holder_cleanup(state)

      %{kind: :pending, timer: timer} ->
        Process.cancel_timer(timer)
        begin_holder_cleanup(%{state | job: nil})

      %{pid: pid} ->
        cancel_job(pid)
        state
    end
  end

  defp begin_holder_cleanup(%{holder_result: result} = state) when not is_nil(result), do: state

  defp begin_holder_cleanup(%{connection: %{runtime: nil}} = state),
    do: %{state | holder_result: :ok}

  defp begin_holder_cleanup(state) do
    runtime = state.connection.runtime
    holder = self()
    job(state, :cleanup, nil, fn -> Loopex.Runtime.release_holder(runtime, holder) end)
  end

  defp close_input(nil), do: :ok

  defp close_input(port) do
    try do
      Port.close(port)
    rescue
      ArgumentError -> if Port.info(port) == nil, do: :ok, else: :unproved
    catch
      _kind, _reason -> :unproved
    else
      true -> :ok
    end
  end

  defp request_writer_stop(%{stop_request: request} = state) when not is_nil(request), do: state
  defp request_writer_stop(%{stop_result: result} = state) when not is_nil(result), do: state

  defp request_writer_stop(state) do
    %{state | stop_request: :gen_server.send_request(state.writer, :stop)}
  catch
    _kind, _reason -> %{state | stop_result: :unproved, failure: :cleanup_unproved}
  end

  defp stop_response(%{stop_request: nil}, _message), do: :other

  defp stop_response(state, message) do
    case :gen_server.check_response(message, state.stop_request) do
      {:reply, result} ->
        state =
          if cleanup_eligible?(state, state.cutoff),
            do: %{state | stop_request: nil, stop_result: result},
            else: %{state | stop_request: nil, stop_result: :unproved, failure: :cleanup_unproved}

        {:handled, state}

      {:error, _reason} ->
        {:handled,
         %{state | stop_request: nil, stop_result: :unproved, failure: :cleanup_unproved}}

      :no_reply ->
        :other
    end
  end

  defp settled?(state),
    do:
      state.closing and state.writer_down and is_nil(state.job) and
        not is_nil(state.holder_result) and not is_nil(state.stop_result)

  defp finish(state) do
    state =
      if cleanup_eligible?(state, state.cutoff),
        do: state,
        else: %{state | failure: :cleanup_unproved}

    retain(state)

    case {state.failure, state.holder_result, state.stop_result} do
      {nil, :ok, {:ok, _facts}} -> :ok
      {nil, :ok, {:error, :stopped, %{cleanup: :joined}}} -> :ok
      _other -> {:error, state.failure || :cleanup_unproved}
    end
  end

  defp expire_cleanup(state) do
    state = retain(%{state | failure: :cleanup_unproved})

    case state.job do
      %{pid: pid} -> cancel_job(pid)
      _other -> :ok
    end

    {:error, :cleanup_unproved}
  end

  # Concept: expiry cannot be undone by a late original completion.
  # Technical depth: both the job and transport capture govern observation;
  # retained unproved custody never reclaims an active frame or its native lease.
  defp writer_stop_joined?({:ok, _facts}), do: true
  defp writer_stop_joined?({:error, :stopped, %{cleanup: :joined}}), do: true
  defp writer_stop_joined?(_other), do: false

  defp cleanup_eligible?(state, cutoff),
    do:
      state.failure != :cleanup_unproved and is_integer(cutoff) and
        now_ms() < min(cutoff, state.cutoff)

  defp retain(%{owned_key: key} = state) do
    Process.put(key, state)
    state
  end

  defp cleanup_exception(%{connection: _} = state, _runtime, _sink, _key) do
    state = state |> close(:serve_failed) |> retain()

    state =
      try do
        release_discarded(state)
      catch
        _kind, _reason -> %{state | failure: :cleanup_unproved}
      end

    cleanup_loop(state)
  catch
    _kind, _reason ->
      # These independent attempts cannot invent successful cleanup or skip
      # another original actor merely because one operation failed.
      state = Process.get(state.owned_key, state)
      _ = close_input(state.port)
      if match?(%{pid: _}, state.job), do: cancel_job(state.job.pid)
      state = state |> close(:cleanup_unproved) |> request_writer_stop() |> retain()
      state = if is_nil(state.job), do: begin_holder_cleanup(state), else: state
      cleanup_loop(%{state | failure: :cleanup_unproved})
  end

  defp cleanup_exception(owned, runtime, sink, key) do
    state =
      retain(%{
        port: nil,
        input: "",
        oversized: false,
        connection: %{runtime: nil},
        delivery: Delivery.new(nil, 0),
        writer: owned.writer,
        writer_monitor: owned.writer_monitor,
        writer_down: false,
        stop_request: nil,
        stop_result: nil,
        active_admitted: nil,
        output_pending: nil,
        job: nil,
        holder_result: nil,
        closing: false,
        cutoff: nil,
        failure: nil,
        sink: sink,
        releases: [],
        service_pending: false,
        poll_due: false,
        owned_key: key
      })

    cleanup_exception(state, runtime, sink, key)
  end

  defp cleanup_loop(state) do
    state = state |> release_pending_output() |> release_discarded_during_cleanup() |> retain()

    cond do
      now_ms() >= state.cutoff ->
        expire_cleanup(state)

      settled?(state) ->
        finish(state)

      true ->
        receive do
          message -> state |> receive_message(message) |> cleanup_loop()
        after
          @idle_ms -> cleanup_loop(state)
        end
    end
  end

  defp release_discarded_during_cleanup(state) do
    release_discarded(state)
  catch
    _kind, _reason -> retain(%{state | failure: :cleanup_unproved})
  end

  defp release_pending_output(%{output_pending: nil} = state), do: state

  defp release_pending_output(state) do
    if state.writer_down and writer_stop_joined?(state.stop_result) and
         cleanup_eligible?(state, state.cutoff) do
      retain(%{
        state
        | output_pending: nil,
          releases: lease_refs(state.output_pending) ++ state.releases
      })
    else
      state
    end
  end

  defp lease_refs(%{lease: nil}), do: []
  defp lease_refs(%{lease: lease}), do: [lease]
  defp release_discarded(%{releases: []} = state), do: state

  defp release_discarded(state) do
    results = Enum.map(state.releases, &Loopex.ProgressSink.release(state.sink, &1))
    state = %{state | releases: []}
    if Enum.all?(results, &(&1 == :ok)), do: state, else: close(state, :cleanup_unproved)
  end

  defp wake(%{service_pending: true} = state), do: state

  defp wake(state) do
    send(self(), :service)
    %{state | service_pending: true}
  end

  defp now_ms(), do: System.monotonic_time(:millisecond)

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
end
