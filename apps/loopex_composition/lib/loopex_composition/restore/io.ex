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

  This private prerequisite exposes bounded reads, complete physical manifests
  and durable record publication to composition only. It does not acquire claims,
  audit history or activate a restored root. Host exclusion and validated paths
  are the caller's obligation.
  """

  require Record
  Record.defrecordp(:file_info, Record.extract(:file_info, from_lib: "kernel/include/file.hrl"))

  alias Loopex.Executor.Local.RestoreCodec

  @max_receive_timeout 4_294_967_295
  @chunk 65_536
  @max_read 268_435_456
  @max_entries 65_536
  @max_manifest 4_194_304
  @max_uint64 18_446_744_073_709_551_615
  @manifest_domain "loopex:current-state-manifest:v1"

  @doc false
  def run(operation, limits, options \\ []) do
    with {:ok, limits} <- RestoreCodec.limits(limits),
         true <- valid_operation?(operation),
         true <-
           Keyword.keyword?(options) and
             Enum.all?(Keyword.keys(options), &(&1 in [:probe, :pause_at])),
         probe <- Keyword.get(options, :probe),
         true <- is_nil(probe) or is_pid(probe),
         pause <- Keyword.get(options, :pause_at),
         true <- is_nil(pause) or (is_atom(pause) and is_pid(probe)) do
      caller = self()
      reference = make_ref()
      admitted = now()

      {guardian, monitor} =
        spawn_monitor(fn ->
          guardian_start(caller, reference, admitted, operation, limits, probe, pause)
        end)

      send(guardian, {:start, reference})
      wait(guardian, monitor, reference, admitted + limits.work_ms + limits.cleanup_window_ms)
    else
      _ -> {:error, :invalid_io_request}
    end
  end

  defp wait(guardian, monitor, reference, cutoff) do
    receive do
      {^reference, ^guardian, result} ->
        await_guardian_down(guardian, monitor, result, cutoff)

      {:DOWN, ^monitor, :process, ^guardian, _reason} ->
        {:unconfirmed, :guardian_lost}
    after
      wait_chunk(cutoff) ->
        if remaining(cutoff) > 0 do
          wait(guardian, monitor, reference, cutoff)
        else
          Process.exit(guardian, :kill)
          Process.demonitor(monitor, [:flush])
          {:unconfirmed, :guardian_unjoined}
        end
    end
  end

  defp await_guardian_down(guardian, monitor, result, cutoff) do
    receive do
      {:DOWN, ^monitor, :process, ^guardian, :normal} -> result
      {:DOWN, ^monitor, :process, ^guardian, _reason} -> {:unconfirmed, :guardian_lost}
    after
      wait_chunk(cutoff) ->
        if remaining(cutoff) > 0,
          do: await_guardian_down(guardian, monitor, result, cutoff),
          else: {:unconfirmed, :guardian_unjoined}
    end
  end

  defp guardian_start(caller, reference, admitted, operation, limits, probe, pause) do
    # Concept: the serial worker belongs to its guardian even if the guardian fails.
    # Technical depth: the link signals guardian loss without waiting for a NIF
    # to return to an Elixir receive. The monitor still supplies exact DOWN;
    # neither signal proves an in-flight file resource or descriptor was joined.
    Process.flag(:trap_exit, true)
    caller_monitor = Process.monitor(caller)

    receive do
      {:start, ^reference} ->
        owner = self()

        {worker, worker_monitor} =
          :erlang.spawn_opt(fn -> worker_start(owner, reference, operation) end, [:link, :monitor])

        state = %{
          caller: caller,
          caller_monitor: caller_monitor,
          reference: reference,
          worker: worker,
          worker_monitor: worker_monitor,
          probe: probe,
          pause: pause,
          pending: nil,
          paused: false,
          next: 1,
          open: MapSet.new(),
          opens: 0,
          closes: 0,
          acknowledgements: 0,
          payload: nil,
          finished: false,
          down: false,
          forced: false,
          work_cutoff: admitted + limits.work_ms,
          grace: limits.cleanup_grace_ms,
          cleanup_window: limits.cleanup_window_ms,
          stop: nil,
          cooperative_cutoff: nil,
          cleanup_cutoff: nil
        }

        notify(state, {:installed, admitted, state.work_cutoff})
        send(worker, {:start, reference})
        guard(state)
    end
  end

  defp guard(state) do
    state = check_cutoffs(state)

    cond do
      clean?(state) ->
        finish(
          state,
          {:joined, terminal_payload(state),
           %{
             opens: state.opens,
             closes: state.closes,
             operations: state.acknowledgements,
             stop: state.stop,
             work_cutoff: state.work_cutoff,
             cleanup_cutoff: state.cleanup_cutoff
           }}
        )

      state.cleanup_cutoff && now() >= state.cleanup_cutoff ->
        finish(state, {:unconfirmed, uncertainty(state)})

      true ->
        receive_event(state)
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
          state.stop && not close_operation?(kind) ->
            send(worker, {:stop, reference})
            guard(state)

          state.stop && now() >= state.cooperative_cutoff ->
            send(worker, {:stop, reference})
            guard(state)

          kind_name(kind) == state.pause ->
            guard(%{state | paused: true})

          true ->
            permit(state, id, kind)
            guard(state)
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

            guard(%{
              state
              | pending: nil,
                paused: false,
                acknowledgements: state.acknowledgements + 1
            })

          _ ->
            guard(stop(state, :history_invalid, now()))
        end

      {:not_issued, ^worker, ^reference, id} ->
        if state.pending && elem(state.pending, 0) == id,
          do: guard(%{state | pending: nil, paused: false}),
          else: guard(stop(state, :history_invalid, now()))

      {:payload, ^worker, ^reference, result} ->
        state = %{state | payload: result}
        guard(stop(state, if(match?({:ok, _}, result), do: :complete, else: :io_error), now()))

      {:finished, ^worker, ^reference} ->
        guard(%{state | finished: true})

      {:EXIT, ^worker, _reason} ->
        guard(state)

      {:DOWN, ^caller_monitor, :process, _caller, _reason} ->
        guard(stop(state, :caller_lost, now()))

      {:DOWN, ^worker_monitor, :process, ^worker, reason} ->
        state = %{state | down: reason == :normal}
        state = if state.stop, do: state, else: stop(state, :worker_unjoined, now())
        guard(state)
    after
      min(next_wait(state), @max_receive_timeout) -> guard(state)
    end
  end

  defp acknowledge(state, {:open, token}, :opened),
    do: %{state | open: MapSet.put(state.open, token), opens: state.opens + 1}

  defp acknowledge(state, {:close, token}, :closed),
    do: %{state | open: MapSet.delete(state.open, token), closes: state.closes + 1}

  defp acknowledge(state, _kind, _observation), do: state

  defp clean?(state),
    do:
      state.stop && state.finished && state.down && not state.forced && is_nil(state.pending) &&
        MapSet.size(state.open) == 0 && not is_nil(state.payload)

  defp stop(%{stop: reason} = state, _new, _at) when not is_nil(reason), do: state

  defp stop(state, reason, at) do
    at = min(at, state.work_cutoff)
    send(state.worker, {:stop, state.reference})
    notify(state, {:stopping, reason, at, at + state.cleanup_window})

    %{
      state
      | stop: reason,
        cooperative_cutoff: at + state.grace,
        cleanup_cutoff: at + state.cleanup_window
    }
  end

  defp check_cutoffs(state) do
    state =
      if is_nil(state.stop) and now() >= state.work_cutoff,
        do: stop(state, :deadline, state.work_cutoff),
        else: state

    if state.cooperative_cutoff && now() >= state.cooperative_cutoff && not state.forced &&
         not state.down do
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

  defp terminal_payload(%{stop: reason})
       when reason in [:deadline, :caller_lost, :worker_unjoined, :history_invalid],
       do: {:error, reason}

  defp terminal_payload(state), do: state.payload

  defp finish(state, result) do
    notify(state, {:terminal, result})
    send(state.caller, {state.reference, self(), result})
  end

  defp notify(%{probe: probe} = state, event) when is_pid(probe),
    do: send(probe, {:restore_io, self(), state.worker, state.reference, event})

  defp notify(_state, _event), do: :ok
  defp close_operation?({:close, _token}), do: true
  defp close_operation?(_kind), do: false
  defp kind_name({name, _token}), do: name
  defp kind_name(name), do: name

  defp permit(state, id, kind) do
    cutoff =
      if state.stop && close_operation?(kind),
        do: state.cooperative_cutoff,
        else: state.work_cutoff

    send(state.worker, {:permit, state.reference, id, cutoff})
  end

  defp now, do: System.monotonic_time(:millisecond)
  defp remaining(cutoff), do: max(0, cutoff - now())

  # Concept: long accepted durations keep their original absolute deadline.
  # Technical depth: each receive fits OTP's unsigned-32-bit timeout ceiling;
  # a chunk expiry only rechecks the same cutoff, never starts a new allowance.
  defp wait_chunk(cutoff), do: min(remaining(cutoff), @max_receive_timeout)

  defp worker_start(guardian, reference, operation) do
    monitor = Process.monitor(guardian)
    Process.put(:restore_io_owner, {guardian, reference, monitor})
    Process.put(:restore_io_sequence, 0)
    Process.put(:restore_io_descriptors, %{})

    receive do
      {:start, ^reference} ->
        result =
          try do
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

  defp execute({:manifest, root, max_total}) do
    ancestors = manifest_ancestors(root)
    # Concept: listing does not give permission to retain an unbounded frontier.
    # Technical depth: native listing materializes names, but every candidate is
    # charged before traversal. Directory form is the smallest possible entry;
    # observed mode and regular-file fields charge the remaining exact ETF cost.
    empty_bytes = :erlang.external_size([@manifest_domain, []], [:deterministic]) + 5
    state = %{entries: [], count: 0, encoded: empty_bytes, total: 0, cap: max_total}
    state = reserve_manifest_entry(".", state)
    state = manifest_entry(root, ".", state)

    Enum.each(ancestors, fn {path, identity} ->
      info = manifest_stat(path)
      if directory_identity(info) != identity, do: throw({:io_error, :source_changed})
    end)

    entries = Enum.sort_by(state.entries, & &1["path"])
    {:ok, bytes} = RestoreCodec.encode(:manifest, [@manifest_domain, entries])
    if byte_size(bytes) != state.encoded, do: throw({:io_error, :manifest_measurement})
    {:ok, observed} = RestoreCodec.manifest(bytes, max_total)

    if Enum.reduce(observed, 0, &(&1["size"] + &2)) != state.total,
      do: throw({:io_error, :manifest_measurement})

    {:ok, bytes}
  end

  defp execute({:publish, path, temp, bytes, mode, expected}) do
    current =
      case primitive(:stat, fn -> :prim_file.read_link_info(path) end) do
        {:error, :enoent} ->
          :absent

        {:ok, info} ->
          if file_info(info, :type) == :regular,
            do: read(path, byte_size(bytes) + byte_size_or_zero(expected)),
            else: throw({:io_error, :not_regular})

        _ ->
          throw({:io_error, :stat_failed})
      end

    cond do
      current == bytes ->
        resync(path)

      current != expected ->
        throw({:io_error, :changed_destination})

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

  defp manifest_ancestors(path) do
    info = manifest_stat(path)
    if file_info(info, :type) != :directory, do: throw({:io_error, :not_directory})
    parent = Path.dirname(path)
    own = {path, directory_identity(info)}
    if parent == path, do: [own], else: [own | manifest_ancestors(parent)]
  end

  defp manifest_stat(path),
    do: require_value(primitive(:manifest_stat, fn -> :prim_file.read_link_info(path) end))

  defp directory_identity(info),
    do: {file_info(info, :type), file_info(info, :major_device), file_info(info, :inode)}

  defp manifest_identity(info),
    do:
      {directory_identity(info), file_info(info, :mode), file_info(info, :size),
       file_info(info, :links), file_info(info, :mtime), file_info(info, :ctime)}

  defp manifest_entry(root, relative, state) do
    path = if relative == ".", do: root, else: Path.join(root, relative)
    info = manifest_stat(path)
    type = file_info(info, :type)
    mode = Bitwise.band(file_info(info, :mode), 0o7777)

    case type do
      :directory ->
        entry = manifest_directory(relative, mode)
        state = retain_manifest_entry(entry, state)
        {names, state} = manifest_candidates(path, relative, state)

        state =
          Enum.reduce(names, state, fn name, current ->
            manifest_entry(root, manifest_child(relative, name), current)
          end)

        comparison = %{state | entries: [], count: 0, encoded: 0}
        {after_names, _} = manifest_candidates(path, relative, comparison)

        if Enum.sort(names) != Enum.sort(after_names) or
             manifest_identity(info) != manifest_identity(manifest_stat(path)),
           do: throw({:io_error, :source_changed})

        state

      :regular ->
        size = file_info(info, :size)

        if file_info(info, :links) != 1 or not is_integer(size) or size < 0 or
             size > @max_uint64 - state.total or size > state.cap - state.total,
           do: throw({:io_error, :inventory_limit})

        entry = %{
          "path" => relative,
          "kind" => "regular",
          "mode" => mode,
          "size" => size,
          "sha256" => String.duplicate("0", 64)
        }

        state = retain_manifest_entry(entry, %{state | total: state.total + size})
        descriptor = open(path, [:raw, :binary, :read])

        opened =
          require_value(
            primitive(:descriptor_stat, fn -> :prim_file.read_handle_info(descriptor) end)
          )

        if manifest_identity(info) != manifest_identity(opened),
          do: throw({:io_error, :source_changed})

        digest = manifest_hash(descriptor, size, :crypto.hash_init(:sha256))

        after_read =
          require_value(
            primitive(:descriptor_stat, fn -> :prim_file.read_handle_info(descriptor) end)
          )

        if manifest_identity(info) != manifest_identity(after_read) or
             manifest_identity(info) != manifest_identity(manifest_stat(path)),
           do: throw({:io_error, :source_changed})

        close(descriptor)
        [head | tail] = state.entries
        %{state | entries: [Map.put(head, "sha256", digest) | tail]}

      _ ->
        throw({:io_error, :unsupported_entry})
    end
  end

  defp manifest_candidates(path, relative, state) do
    raw_names = require_value(primitive(:list, fn -> :prim_file.list_dir_all(path) end))
    # Concept: an excessive listing refuses before any child traversal.
    # Technical depth: count the materialized native list before retaining names;
    # the independent encoded ceiling can bind sooner on otherwise valid counts.
    _ =
      Enum.reduce(raw_names, state.count, fn _name, count ->
        if count == @max_entries, do: throw({:io_error, :inventory_limit})
        count + 1
      end)

    {names, state} =
      Enum.reduce(raw_names, {[], state}, fn raw, {names, current} ->
        name = manifest_name(raw)
        current = reserve_manifest_entry(manifest_child(relative, name), current)
        {[name | names], current}
      end)

    {Enum.reverse(names), state}
  end

  # Concept: names retain the OS spelling; invalid UTF-8 is refused.
  # Technical depth: list_dir_all returns decoded character lists or raw binary
  # names when translation fails. Reversing the pinned native encoding preserves
  # valid names' original bytes; it never repairs a raw invalid name.
  defp manifest_name(raw) do
    name =
      cond do
        is_binary(raw) -> raw
        is_list(raw) and :file.native_name_encoding() == :latin1 -> :erlang.list_to_binary(raw)
        is_list(raw) -> :unicode.characters_to_binary(raw)
        true -> :invalid
      end

    if not is_binary(name) or byte_size(name) == 0 or not String.valid?(name) or
         String.contains?(name, [<<0>>, "/"]) or name in [".", ".."],
       do: throw({:io_error, :unsupported_path})

    name
  end

  defp manifest_child(".", name), do: name
  defp manifest_child(parent, name), do: parent <> "/" <> name

  defp manifest_directory(path, mode),
    do: %{"path" => path, "kind" => "directory", "mode" => mode, "size" => 0, "sha256" => nil}

  defp entry_bytes(entry), do: :erlang.external_size(entry, [:deterministic]) - 1

  defp reserve_manifest_entry(path, state) do
    if byte_size(path) > 8_192 or state.count == @max_entries,
      do: throw({:io_error, :inventory_limit})

    encoded = state.encoded + entry_bytes(manifest_directory(path, 0))
    if encoded > @max_manifest, do: throw({:io_error, :inventory_limit})
    %{state | count: state.count + 1, encoded: encoded}
  end

  defp retain_manifest_entry(entry, state) do
    delta = entry_bytes(entry) - entry_bytes(manifest_directory(entry["path"], 0))
    encoded = state.encoded + delta
    if encoded > @max_manifest, do: throw({:io_error, :inventory_limit})
    %{state | encoded: encoded, entries: [entry | state.entries]}
  end

  defp manifest_hash(descriptor, remaining, context) do
    length = min(@chunk, remaining + 1)

    case primitive(:hash_read, fn -> :prim_file.read(descriptor, length) end) do
      :eof when remaining == 0 ->
        :crypto.hash_final(context) |> Base.encode16(case: :lower)

      {:ok, bytes} when byte_size(bytes) > 0 and byte_size(bytes) <= remaining ->
        manifest_hash(
          descriptor,
          remaining - byte_size(bytes),
          :crypto.hash_update(context, bytes)
        )

      _ ->
        throw({:io_error, :source_changed})
    end
  end

  defp read(path, cap) do
    info = require_value(primitive(:stat, fn -> :prim_file.read_link_info(path) end))

    if file_info(info, :type) != :regular or file_info(info, :size) > cap,
      do: throw({:io_error, :invalid_read})

    descriptor = open(path, [:raw, :binary, :read])
    bytes = read_chunks(descriptor, cap, [])
    close(descriptor)
    bytes
  end

  defp read_chunks(descriptor, remaining, chunks) do
    case primitive(:read, fn -> :prim_file.read(descriptor, min(@chunk, remaining + 1)) end) do
      :eof ->
        chunks |> Enum.reverse() |> IO.iodata_to_binary()

      {:ok, bytes} when byte_size(bytes) <= remaining ->
        read_chunks(descriptor, remaining - byte_size(bytes), [bytes | chunks])

      _ ->
        throw({:io_error, :read_failed})
    end
  end

  defp write(_descriptor, <<>>), do: :ok

  defp write(descriptor, bytes) do
    size = min(@chunk, byte_size(bytes))
    chunk = binary_part(bytes, 0, size)
    tail = binary_part(bytes, size, byte_size(bytes) - size)
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
          Process.put(
            :restore_io_descriptors,
            Map.put(Process.get(:restore_io_descriptors), descriptor, token)
          )

          {:ok, descriptor}

        error ->
          error
      end
    end)
    |> require_value()
  end

  defp close(descriptor) do
    token = Map.fetch!(Process.get(:restore_io_descriptors), descriptor)

    require_ok(
      primitive({:close, token}, fn ->
        case :prim_file.close(descriptor) do
          :ok ->
            Process.put(
              :restore_io_descriptors,
              Map.delete(Process.get(:restore_io_descriptors), descriptor)
            )

            :ok

          error ->
            error
        end
      end)
    )
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

          observation =
            case {kind, result} do
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
        if Process.get(:restore_io_guardian_lost),
          do: :prim_file.close(descriptor),
          else: close(descriptor)
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

  defp valid_operation?({:manifest, root, max_total}),
    do: valid_path?(root) and is_integer(max_total) and max_total in 0..@max_uint64

  defp valid_operation?({:read, path, cap}),
    do: valid_path?(path) and is_integer(cap) and cap >= 0 and cap <= @max_read

  defp valid_operation?({:publish, path, temp, bytes, mode, expected}),
    do:
      valid_path?(path) and valid_path?(temp) and Path.dirname(path) == Path.dirname(temp) and
        path != temp and String.ends_with?(temp, ".tmp") and is_binary(bytes) and
        byte_size(bytes) <= 4_194_304 and mode in 0..4095 and
        (expected == :absent or (is_binary(expected) and byte_size(expected) <= 4_194_304))

  defp valid_operation?(_operation), do: false

  defp valid_path?(path),
    do:
      is_binary(path) and byte_size(path) in 1..8192 and String.valid?(path) and
        not String.contains?(path, <<0>>) and Path.expand(path) == path
end
