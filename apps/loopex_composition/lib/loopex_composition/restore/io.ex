defmodule LoopexComposition.Restore.IO do
  @moduledoc """
  ## Concept

  Owned serial direct file IO for the offline physical restore administrator.
  A joined result certifies this invocation's explicit descriptor closes and
  worker termination; it grants no runtime or filesystem authority.

  ## Technical depth

  A monitored guardian installs and monitors one worker before permitting IO.
  Only the worker calls pinned OTP `:prim_file` primitives. Every synchronous
  operation is permitted before issue and acknowledged afterward. Descriptors
  remain worker-private, and the guardian tracks opaque open/close identities.
  One work cutoff and one terminal cleanup cutoff implement ADR 0051. A forced
  kill, missing acknowledgement or guardian loss remains unconfirmed even if
  BEAM termination is observed. No shared file-server convenience IO is used.

  This private prerequisite exposes bounded reads and durable record publication
  to composition only. It does not acquire claims, audit history or activate a
  restored root. Host exclusion and validated paths are the caller's obligation.
  """

  require Record
  Record.defrecordp(:file_info, Record.extract(:file_info, from_lib: "kernel/include/file.hrl"))

  alias Loopex.Executor.Local.RestoreCodec

  @chunk 65_536
  @max_read 268_435_456

  @doc false
  def run(operation, limits, options \\ []) do
    with {:ok, limits} <- RestoreCodec.limits(limits),
         true <- valid_operation?(operation),
         true <- Keyword.keyword?(options) and Enum.all?(Keyword.keys(options), &(&1 in [:probe, :pause_at])),
         probe <- Keyword.get(options, :probe),
         true <- is_nil(probe) or is_pid(probe),
         pause <- Keyword.get(options, :pause_at),
         true <- is_nil(pause) or (is_atom(pause) and is_pid(probe)) do
      caller = self()
      reference = make_ref()
      admitted = now()
      {guardian, monitor} = spawn_monitor(fn -> guardian_start(caller, reference, admitted, operation, limits, probe, pause) end)
      send(guardian, {:start, reference})
      wait(guardian, monitor, reference, admitted + limits.work_ms + limits.cleanup_window_ms)
    else
      _ -> {:error, :invalid_io_request}
    end
  end

  defp wait(guardian, monitor, reference, cutoff) do
    receive do
      {^reference, ^guardian, result} ->
        receive do
          {:DOWN, ^monitor, :process, ^guardian, :normal} -> result
          {:DOWN, ^monitor, :process, ^guardian, _reason} -> {:unconfirmed, :guardian_lost}
        after
          remaining(cutoff) -> {:unconfirmed, :guardian_unjoined}
        end

      {:DOWN, ^monitor, :process, ^guardian, _reason} ->
        {:unconfirmed, :guardian_lost}
    after
      remaining(cutoff) ->
        Process.exit(guardian, :kill)
        Process.demonitor(monitor, [:flush])
        {:unconfirmed, :guardian_unjoined}
    end
  end

  defp guardian_start(caller, reference, admitted, operation, limits, probe, pause) do
    caller_monitor = Process.monitor(caller)
    receive do
      {:start, ^reference} ->
        owner = self()
        {worker, worker_monitor} = spawn_monitor(fn -> worker_start(owner, reference, operation) end)
        state = %{caller: caller, caller_monitor: caller_monitor, reference: reference, worker: worker,
          worker_monitor: worker_monitor, probe: probe, pause: pause, pending: nil, paused: false,
          next: 1, open: MapSet.new(), opens: 0, closes: 0, acknowledgements: 0,
          payload: nil, finished: false, down: false, forced: false,
          work_cutoff: admitted + limits.work_ms, grace: limits.cleanup_grace_ms,
          cleanup_window: limits.cleanup_window_ms, stop: nil, cooperative_cutoff: nil, cleanup_cutoff: nil}
        notify(state, {:installed, admitted, state.work_cutoff})
        send(worker, {:start, reference})
        guard(state)
    end
  end

  defp guard(state) do
    state = check_cutoffs(state)

    cond do
      clean?(state) -> finish(state, {:joined, terminal_payload(state), %{opens: state.opens, closes: state.closes, operations: state.acknowledgements, stop: state.stop, work_cutoff: state.work_cutoff, cleanup_cutoff: state.cleanup_cutoff}})
      state.cleanup_cutoff && now() >= state.cleanup_cutoff -> finish(state, {:unconfirmed, uncertainty(state)})
      true -> receive_event(state)
    end
  end

  defp receive_event(state) do
    worker = state.worker
    reference = state.reference
    caller_monitor = state.caller_monitor
    worker_monitor = state.worker_monitor
    receive do
      {:issued, ^worker, ^reference, id, kind} when id == state.next and is_nil(state.pending) ->
        state = check_cutoffs(%{state | pending: {id, kind}, next: id + 1})
        notify(state, {:issued, id, kind})
        cond do
          state.stop && not close_operation?(kind) -> send(worker, {:stop, reference}); guard(state)
          state.stop && now() >= state.cooperative_cutoff -> send(worker, {:stop, reference}); guard(state)
          kind_name(kind) == state.pause -> guard(%{state | paused: true})
          true -> permit(state, id, kind); guard(state)
        end

      {:proceed, ^reference, id} when state.paused ->
        state = check_cutoffs(state)
        if state.pending && elem(state.pending, 0) == id do
          kind = elem(state.pending, 1)
          if state.stop && not close_operation?(kind),
            do: send(worker, {:stop, reference}),
            else: permit(state, id, kind)
          guard(%{state | paused: false})
        else
          guard(state)
        end

      {:acknowledged, ^worker, ^reference, id, observation} ->
        case state.pending do
          {^id, kind} ->
            state = acknowledge(state, kind, observation)
            notify(state, {:acknowledged, id, kind, observation})
            guard(%{state | pending: nil, paused: false, acknowledgements: state.acknowledgements + 1})
          _ -> guard(stop(state, :history_invalid, now()))
        end

      {:not_issued, ^worker, ^reference, id} ->
        if state.pending && elem(state.pending, 0) == id,
          do: guard(%{state | pending: nil, paused: false}),
          else: guard(stop(state, :history_invalid, now()))

      {:payload, ^worker, ^reference, result} ->
        state = %{state | payload: result}
        guard(stop(state, if(match?({:ok, _}, result), do: :complete, else: :io_error), now()))

      {:finished, ^worker, ^reference} -> guard(%{state | finished: true})
      {:DOWN, ^caller_monitor, :process, _caller, _reason} -> guard(stop(state, :caller_lost, now()))
      {:DOWN, ^worker_monitor, :process, ^worker, reason} ->
        state = %{state | down: reason == :normal}
        state = if state.stop, do: state, else: stop(state, :worker_unjoined, now())
        guard(state)
    after
      next_wait(state) -> guard(state)
    end
  end

  defp acknowledge(state, {:open, token}, :opened), do: %{state | open: MapSet.put(state.open, token), opens: state.opens + 1}
  defp acknowledge(state, {:close, token}, :closed), do: %{state | open: MapSet.delete(state.open, token), closes: state.closes + 1}
  defp acknowledge(state, _kind, _observation), do: state
  defp clean?(state), do: state.stop && state.finished && state.down && not state.forced && is_nil(state.pending) && MapSet.size(state.open) == 0 && not is_nil(state.payload)
  defp stop(%{stop: reason} = state, _new, _at) when not is_nil(reason), do: state
  defp stop(state, reason, at) do
    at = min(at, state.work_cutoff)
    send(state.worker, {:stop, state.reference})
    notify(state, {:stopping, reason, at, at + state.cleanup_window})
    %{state | stop: reason, cooperative_cutoff: at + state.grace, cleanup_cutoff: at + state.cleanup_window}
  end
  defp check_cutoffs(state) do
    state = if is_nil(state.stop) and now() >= state.work_cutoff, do: stop(state, :deadline, state.work_cutoff), else: state
    if state.cooperative_cutoff && now() >= state.cooperative_cutoff && not state.forced && not state.down do
      Process.exit(state.worker, :kill)
      %{state | forced: true}
    else
      state
    end
  end
  defp next_wait(%{stop: nil} = state), do: remaining(state.work_cutoff)
  defp next_wait(%{forced: true} = state), do: remaining(state.cleanup_cutoff)
  defp next_wait(%{down: true} = state), do: remaining(state.cleanup_cutoff)
  defp next_wait(state), do: remaining(min(state.cooperative_cutoff, state.cleanup_cutoff))
  defp uncertainty(state) do
    cond do
      MapSet.size(state.open) > 0 -> :descriptor_unclosed
      not is_nil(state.pending) -> :io_unacknowledged
      true -> :worker_unjoined
    end
  end
  defp terminal_payload(%{stop: reason}) when reason in [:deadline, :caller_lost, :worker_unjoined, :history_invalid], do: {:error, reason}
  defp terminal_payload(state), do: state.payload
  defp finish(state, result) do
    notify(state, {:terminal, result})
    send(state.caller, {state.reference, self(), result})
  end
  defp notify(%{probe: probe} = state, event) when is_pid(probe), do: send(probe, {:restore_io, self(), state.worker, state.reference, event})
  defp notify(_state, _event), do: :ok
  defp close_operation?({:close, _token}), do: true
  defp close_operation?(_kind), do: false
  defp kind_name({name, _token}), do: name
  defp kind_name(name), do: name
  defp permit(state, id, kind) do
    cutoff = if state.stop && close_operation?(kind), do: state.cooperative_cutoff, else: state.work_cutoff
    send(state.worker, {:permit, state.reference, id, cutoff})
  end
  defp now, do: System.monotonic_time(:millisecond)
  defp remaining(cutoff), do: max(0, cutoff - now())

  defp worker_start(guardian, reference, operation) do
    monitor = Process.monitor(guardian)
    Process.put(:restore_io_owner, {guardian, reference, monitor})
    Process.put(:restore_io_sequence, 0)
    Process.put(:restore_io_descriptors, %{})
    receive do
      {:start, ^reference} ->
        result = try do
          execute(operation)
        rescue
          _ -> {:error, :io_error}
        catch
          {:stopped, _reason} -> {:error, :stopped}
          {:io_error, _reason} -> {:error, :io_error}
        end
        send(guardian, {:payload, self(), reference, result})
        cleanup_descriptors()
        send(guardian, {:finished, self(), reference})
    end
  end

  defp execute({:read, path, cap}), do: {:ok, read(path, cap)}
  defp execute({:publish, path, temp, bytes, mode, expected}) do
    current = case primitive(:stat, fn -> :prim_file.read_link_info(path) end) do
      {:error, :enoent} -> :absent
      {:ok, info} -> if file_info(info, :type) == :regular, do: read(path, byte_size(bytes) + byte_size_or_zero(expected)), else: throw({:io_error, :not_regular})
      _ -> throw({:io_error, :stat_failed})
    end

    cond do
      current == bytes -> resync(path)
      current != expected -> throw({:io_error, :changed_destination})
      true ->
        descriptor = open(temp, [:raw, :binary, :write, :exclusive])
        info = file_info(mode: mode)
        require_ok(primitive(:mode, fn -> :prim_file.write_file_info(temp, info) end))
        write(descriptor, bytes)
        require_ok(primitive(:file_sync, fn -> :prim_file.sync(descriptor) end))
        close(descriptor)
        require_ok(primitive(:rename, fn -> :prim_file.rename(temp, path) end))
    end

    directory_sync(Path.dirname(path))
    if read(path, byte_size(bytes)) != bytes, do: throw({:io_error, :readback_mismatch})
    {:ok, RestoreCodec.digest_bytes(bytes)}
  end

  defp read(path, cap) do
    info = require_value(primitive(:stat, fn -> :prim_file.read_link_info(path) end))
    if file_info(info, :type) != :regular or file_info(info, :size) > cap, do: throw({:io_error, :invalid_read})
    descriptor = open(path, [:raw, :binary, :read])
    bytes = read_chunks(descriptor, cap, [])
    close(descriptor)
    bytes
  end
  defp read_chunks(descriptor, remaining, chunks) do
    case primitive(:read, fn -> :prim_file.read(descriptor, min(@chunk, remaining + 1)) end) do
      :eof -> chunks |> Enum.reverse() |> IO.iodata_to_binary()
      {:ok, bytes} when byte_size(bytes) <= remaining -> read_chunks(descriptor, remaining - byte_size(bytes), [bytes | chunks])
      _ -> throw({:io_error, :read_failed})
    end
  end
  defp write(_descriptor, <<>>), do: :ok
  defp write(descriptor, bytes) do
    size = min(@chunk, byte_size(bytes))
    <<chunk::binary-size(size), tail::binary>> = bytes
    require_ok(primitive(:write, fn -> :prim_file.write(descriptor, chunk) end))
    write(descriptor, tail)
  end
  defp resync(path) do
    descriptor = open(path, [:raw, :binary, :read])
    require_ok(primitive(:file_sync, fn -> :prim_file.sync(descriptor) end))
    close(descriptor)
  end
  defp directory_sync(path) do
    descriptor = open(path, [:raw, :read, :directory])
    require_ok(primitive(:directory_sync, fn -> :prim_file.sync(descriptor) end))
    close(descriptor)
  end
  defp open(path, modes) do
    token = make_ref()
    primitive({:open, token}, fn ->
      case :prim_file.open(path, modes) do
        {:ok, descriptor} ->
          Process.put(:restore_io_descriptors, Map.put(Process.get(:restore_io_descriptors), descriptor, token))
          {:ok, descriptor}
        error -> error
      end
    end) |> require_value()
  end
  defp close(descriptor) do
    token = Map.fetch!(Process.get(:restore_io_descriptors), descriptor)
    require_ok(primitive({:close, token}, fn ->
      case :prim_file.close(descriptor) do
        :ok -> Process.put(:restore_io_descriptors, Map.delete(Process.get(:restore_io_descriptors), descriptor)); :ok
        error -> error
      end
    end))
  end
  defp primitive(kind, function) do
    {guardian, reference, monitor} = Process.get(:restore_io_owner)
    id = Process.get(:restore_io_sequence) + 1
    Process.put(:restore_io_sequence, id)
    send(guardian, {:issued, self(), reference, id, kind})
    await_permit(guardian, reference, monitor, id, kind, function)
  end
  defp await_permit(guardian, reference, monitor, id, kind, function) do
    receive do
      {:permit, ^reference, ^id, cutoff} ->
        if now() >= cutoff do
          send(guardian, {:not_issued, self(), reference, id})
          throw({:stopped, :deadline})
        else
          result = function.()
          observation = case {kind, result} do
            {{:open, _}, {:ok, _}} -> :opened
            {{:close, _}, :ok} -> :closed
            {_, {:error, _}} -> :error
            _ -> :completed
          end
          send(guardian, {:acknowledged, self(), reference, id, observation})
          result
        end
      {:stop, ^reference} ->
        if close_operation?(kind) do
          await_permit(guardian, reference, monitor, id, kind, function)
        else
          send(guardian, {:not_issued, self(), reference, id})
          throw({:stopped, :cancelled})
        end
      {:DOWN, ^monitor, :process, ^guardian, _reason} ->
        Process.put(:restore_io_guardian_lost, true)
        throw({:stopped, :guardian_lost})
    end
  end
  defp cleanup_descriptors do
    Enum.each(Process.get(:restore_io_descriptors), fn {descriptor, _token} ->
      try do
        if Process.get(:restore_io_guardian_lost), do: :prim_file.close(descriptor), else: close(descriptor)
      catch
        _ -> :unconfirmed
      end
    end)
  end
  defp require_ok(:ok), do: :ok
  defp require_ok(_result), do: throw({:io_error, :operation_failed})
  defp require_value({:ok, value}), do: value
  defp require_value(_result), do: throw({:io_error, :operation_failed})
  defp byte_size_or_zero(:absent), do: 0
  defp byte_size_or_zero(bytes), do: byte_size(bytes)
  defp valid_operation?({:read, path, cap}), do: valid_path?(path) and is_integer(cap) and cap >= 0 and cap <= @max_read
  defp valid_operation?({:publish, path, temp, bytes, mode, expected}), do: valid_path?(path) and valid_path?(temp) and Path.dirname(path) == Path.dirname(temp) and path != temp and String.ends_with?(temp, ".tmp") and is_binary(bytes) and byte_size(bytes) <= 4_194_304 and mode in 0..4095 and (expected == :absent or (is_binary(expected) and byte_size(expected) <= 4_194_304))
  defp valid_operation?(_operation), do: false
  defp valid_path?(path), do: is_binary(path) and byte_size(path) in 1..8192 and String.valid?(path) and not String.contains?(path, <<0>>) and Path.expand(path) == path
end
