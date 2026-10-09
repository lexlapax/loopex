defmodule LoopexComposition.Delegation.RetainedObjects do
  @moduledoc """
  ## Concept

  Retain the exact validated bytes of a helper catalog or creation object under
  its SHA-256 identity. One private owner serializes installation; a corrupt
  published object is refused rather than repaired or replaced.

  ## Technical depth

  ADR 0046 places these immutable objects below delegation/<runtime-id-sha256>
  under an existing host placement acquisition. Opening verifies that the
  acquisition's regular hard-linked handle still names this VM's placement
  lock, and retains physical directory identities. Every operation rechecks
  those identities and ownership. The Local writer lock supplies independent
  process exclusion; its existing format is reused without a new journal.

  Callers own canonical JSON and semantic validation before installation. This
  physical unit bounds UTF-8 bytes to 1 MiB and verifies exact digests on reads.
  Parent binding operations additionally validate and sync the exact captured
  objects and the accepted two-transition log. No helper dispatch, accounting,
  receipt, session creation or activation occurs here.
  Temporary-file sync precedes rename and strict directory sync. A failure after
  rename returns object_durability_unknown, never a durability acknowledgement.
  Repeated installation confirms the existing file and directory durability.
  Read success proves current integrity, not a previously lost acknowledgement.
  Binding headers and transactions use LedgerCodec's current JSON framing.
  Objects sync before prepare; full file and directory sync, descriptor close
  and exact readback precede a transaction acknowledgement. Uncertainty gates
  every binding and run in this owner. Initialize-only run logs revalidate the
  actual bound parent and retain zero counts, tokens and completion credit;
  later lifecycle mutations remain unavailable. Lookup replays the original
  transaction and may repair only a strict incomplete final transaction after
  exclusive stale-writer recovery. Required missing/torn headers remain
  unavailable. Reopening requires explicit classification of every physically
  present binding and run before mutations;
  this is not complete Core-history startup coverage or helper activation.
  An unresolved owner retains its existing marker on stop so the next acquisition
  must establish that exact writer gone. No marker or persistent schema is added.
  Paths are revalidated using ordinary OTP file identities under the exclusive
  trusted host lease; this is not isolation from host code changing the root.
  """

  use GenServer

  alias Loopex.Store.Local.{Log, WriterLock}
  alias LoopexComposition.Placement
  alias LoopexComposition.Delegation.{LedgerCodec, ParentBinding, RunLedger, RunMutation}

  @cap 1_048_576
  @run_cap 16_777_216
  @run_checkpoints %{
    binding_header_written: :run_header_written,
    binding_header_synced: :run_header_synced,
    binding_partial_written: :run_partial_written,
    binding_written: :run_written,
    binding_synced: :run_synced,
    binding_closed: :run_closed,
    binding_directory_synced: :run_directory_synced,
    binding_recovered_synced: :run_recovered_synced,
    binding_before_truncate: :run_before_truncate,
    binding_truncated: :run_truncated,
    binding_repair_synced: :run_repair_synced
  }

  @doc false
  def open(root, runtime_id, placement_owner, options \\ []) do
    case GenServer.start(__MODULE__, {self(), root, runtime_id, placement_owner, options}) do
      {:ok, owner} ->
        Process.link(owner)
        {:ok, owner}

      refusal ->
        refusal
    end
  end

  @doc false
  def install(owner, bytes), do: GenServer.call(owner, {:install, bytes}, :infinity)

  @doc false
  def read(owner, digest), do: GenServer.call(owner, {:read, digest}, :infinity)

  @doc false
  def open_binding(owner, command, objects, runtime \\ nil),
    do: GenServer.call(owner, {:open_binding, command, objects, runtime}, :infinity)

  @doc false
  def commit_binding(owner, command, transaction, runtime \\ nil),
    do: GenServer.call(owner, {:commit_binding, command, transaction, runtime}, :infinity)

  @doc false
  def lookup_binding(owner, command, tx_id, runtime \\ nil),
    do: GenServer.call(owner, {:lookup_binding, command, tx_id, runtime}, :infinity)

  @doc false
  def read_binding(owner, command, runtime \\ nil),
    do: GenServer.call(owner, {:read_binding, command, runtime}, :infinity)

  @doc false
  def open_run(owner, command, identifiers, runtime),
    do: GenServer.call(owner, {:open_run, command, identifiers, runtime}, :infinity)

  @doc false
  def commit_run(owner, command, identifiers, transaction, runtime),
    do: GenServer.call(owner, {:commit_run, command, identifiers, transaction, runtime}, :infinity)

  @doc false
  def lookup_run(owner, command, identifiers, tx_id, runtime),
    do: GenServer.call(owner, {:lookup_run, command, identifiers, tx_id, runtime}, :infinity)

  @doc false
  def read_run(owner, command, identifiers, runtime),
    do: GenServer.call(owner, {:read_run, command, identifiers, runtime}, :infinity)

  # Concept: offline readers inspect the same exact bytes without starting an owner.
  # Technical depth: the first header is mandatory; only a strict final transaction
  # fragment is classified incomplete. This function performs no repair or IO.
  @doc false
  def decode_binding(bytes, runtime, command)
      when is_binary(bytes) and byte_size(bytes) <= @cap do
    with {:ok, key} <- LedgerCodec.header_key(:binding, [runtime, command]),
         {:ok, _payload, rest} <- LedgerCodec.decode_frame(bytes),
         header_size = byte_size(bytes) - byte_size(rest),
         header = binary_part(bytes, 0, header_size),
         {:ok, _} <- LedgerCodec.decode_header(header, :binding, [runtime, command], key),
         {:ok, transactions, complete_size, tail} <- binding_frames(rest, header_size, []) do
      {:ok, %{key: key, transactions: transactions, complete_size: complete_size, tail: tail}}
    else
      _ -> {:error, :invalid_binding_log}
    end
  end

  def decode_binding(_, _, _), do: {:error, :invalid_binding_log}

  # Concept: the current physical run foundation admits initialization only.
  # Technical depth: validate the mandatory scoped header and the sole closed
  # transaction before exposing a prefix; a later lifecycle frame is unavailable,
  # never skipped or repaired into a fresh allowance.
  @doc false
  def decode_run(bytes, identifiers) when is_binary(bytes) and byte_size(bytes) <= @run_cap do
    with {:ok, key} <- LedgerCodec.header_key(:run, identifiers),
         {:ok, _payload, rest} <- LedgerCodec.decode_frame(bytes),
         header_size = byte_size(bytes) - byte_size(rest),
         header = binary_part(bytes, 0, header_size),
         {:ok, _} <- LedgerCodec.decode_header(header, :run, identifiers, key),
         {:ok, transactions, complete_size, tail} <- run_frames(rest, identifiers, header_size, []) do
      {:ok, %{key: key, transactions: transactions, complete_size: complete_size, tail: tail}}
    else
      _ -> {:error, :invalid_run_log}
    end
  end

  def decode_run(_, _), do: {:error, :invalid_run_log}

  @impl true
  def init({caller, root, runtime_id, placement_owner, options}) do
    caller_monitor = Process.monitor(caller)

    with true <- is_binary(root) and Path.type(root) == :absolute and Path.expand(root) == root,
         true <- is_binary(runtime_id) and byte_size(runtime_id) in 1..256,
         true <- is_function(Keyword.get(options, :checkpoint, fn _ -> :ok end), 1),
         :ok <- physical_directory(root),
         :ok <- placement(root, placement_owner),
         {:ok, directory} <- directories(root, digest(runtime_id)),
         :ok <- placement(root, placement_owner),
         {:ok, identities} <- identities([root, Path.dirname(directory), directory]),
         :ok <- optional_writer_marker(Path.join(directory, "objects.writer")),
         previous_marker = File.exists?(Path.join(directory, "objects.writer")),
         {:ok, lock} <-
           WriterLock.acquire(
             Path.join(directory, "objects"),
             Keyword.get(options, :recover_stale_writer, false)
           ) do
      with {:ok, pending, binding_identity} <- binding_namespace(directory),
           {:ok, runs, run_identity} <- ledger_namespace(directory, :run) do
          {:ok,
           %{
             root: root,
             runtime_id: runtime_id,
             pending_bindings: pending,
             binding_identity: binding_identity,
             pending_runs: runs,
             known_runs: runs,
             run_identity: run_identity,
             recoverable_runs:
               if(previous_marker and Keyword.get(options, :recover_stale_writer, false),
                 do: runs,
                 else: MapSet.new()
               ),
             recoverable_bindings:
               if(previous_marker and Keyword.get(options, :recover_stale_writer, false),
                 do: pending,
                 else: MapSet.new()
               ),
             fence: nil,
             placement_owner: placement_owner,
             directory: directory,
             identities: identities,
             lock: lock,
             caller_monitor: caller_monitor,
             checkpoint: Keyword.get(options, :checkpoint, fn _ -> :ok end)
           }}

      else
        {:error, reason} ->
          {:stop, reason}
      end
    else
      false -> {:stop, :invalid_object_root}
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call({:install, bytes}, _from, state) do
    result = with :ok <- mutation_open(state), do: install_object(state, bytes)
    {:reply, result, state}
  end

  def handle_call({:read, hash}, _from, state) do
    result =
      with true <- is_binary(hash) and Regex.match?(~r/\A[0-9a-f]{64}\z/, hash),
           :ok <- verify(state),
           {:ok, bytes} <- read_file(state, Path.join(state.directory, hash)),
           true <- digest(bytes) == hash do
        {:ok, bytes}
      else
        false -> {:error, :invalid_or_corrupt_object}
        {:error, reason} -> {:error, reason}
      end

    {:reply, result, state}
  end

  def handle_call({:open_binding, command, objects, runtime}, _from, state) do
    case do_open_binding(state, command, objects, runtime) do
      {:ok, key, next} -> {:reply, {:ok, key}, next}
      {:unknown, tx, file_identity, next} -> binding_unknown(next, command, tx, file_identity)
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:commit_binding, command, tx, runtime}, _from, state) do
    case do_commit_binding(state, command, tx, runtime) do
      {:ok, result} -> {:reply, {:ok, result}, state}
      {:unknown, file_identity} -> binding_unknown(state, command, tx, file_identity)
      {:error, reason} -> {:reply, {:error, reason}, note_unavailable(state, command, reason)}
    end
  end

  def handle_call({:lookup_binding, command, tx_id, runtime}, _from, state) do
    case do_lookup_binding(state, command, tx_id, runtime) do
      {:ok, result, next} -> {:reply, {:ok, result}, next}
      {:error, reason} -> {:reply, {:error, reason}, note_unavailable(state, command, reason)}
    end
  end

  def handle_call({:read_binding, command, runtime}, _from, state) do
    result =
      with :ok <- mutation_open(state),
           {:ok, image} <- binding_image(state, command),
           true <- image.decoded.tail == :complete,
           {:ok, reduced} <- reduce_image(state, command, image, runtime),
           :ok <- confirm_binding(state, image) do
        {:ok, view(reduced)}
      else
        false -> {:error, :incomplete_binding_tail}
        {:error, reason} -> {:error, reason}
      end

    next =
      case result do
        {:error, reason} -> note_unavailable(state, command, reason)
        _ -> state
      end

    {:reply, result, next}
  end

  def handle_call({:open_run, command, identifiers, runtime}, _from, state) do
    case do_open_run(state, command, identifiers, runtime) do
      {:ok, key, next} -> {:reply, {:ok, key}, next}
      {:unknown, tx, file_identity, next} ->
        run_unknown(next, command, identifiers, tx, file_identity)
      {:error, reason} ->
        {:reply, {:error, reason}, note_run_unavailable(state, identifiers, reason)}
    end
  end

  def handle_call({:commit_run, command, identifiers, tx, runtime}, _from, state) do
    case do_commit_run(state, command, identifiers, tx, runtime) do
      {:ok, result} -> {:reply, {:ok, result}, state}
      {:unknown, file_identity} -> run_unknown(state, command, identifiers, tx, file_identity)
      {:error, reason} ->
        {:reply, {:error, reason}, note_run_unavailable(state, identifiers, reason)}
    end
  end

  def handle_call({:lookup_run, command, identifiers, tx_id, runtime}, _from, state) do
    case do_lookup_run(state, command, identifiers, tx_id, runtime) do
      {:ok, result, next} -> {:reply, {:ok, result}, next}
      {:error, reason} ->
        {:reply, {:error, reason}, note_run_unavailable(state, identifiers, reason)}
    end
  end

  def handle_call({:read_run, command, identifiers, runtime}, _from, state) do
    result =
      with :ok <- mutation_open(state),
           {:ok, parent} <- run_parent(state, command, identifiers, runtime),
           {:ok, image} <- ledger_image(state, :run, identifiers),
           true <- image.decoded.tail == :complete,
           {:ok, reduced} <- reduce_run(parent, image),
           :ok <- confirm_run(state, image) do
        {:ok, run_view(reduced)}
      else
        false -> {:error, :incomplete_run_tail}
        {:error, reason} -> {:error, reason}
      end

    next =
      case result do
        {:error, reason} -> note_run_unavailable(state, identifiers, reason)
        _ -> state
      end

    {:reply, result, next}
  end

  @impl true
  def terminate(_reason, %{fence: nil} = state) do
    if MapSet.size(state.pending_bindings) == 0 and MapSet.size(state.pending_runs) == 0,
      do: WriterLock.release(state.lock)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  @impl true
  def handle_info(
        {:DOWN, monitor, :process, _caller, _reason},
        %{caller_monitor: monitor} = state
      ),
      do: {:stop, :normal, state}

  defp install_object(state, bytes) do
    with :ok <- valid_bytes(bytes), :ok <- verify(state) do
      hash = digest(bytes)
      path = Path.join(state.directory, hash)

      case read_file(state, path) do
        {:ok, ^bytes} -> confirm_existing(state, path, hash)
        {:ok, _} -> {:error, :object_integrity_conflict}
        {:error, :enoent} -> publish(state, path, hash, bytes)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp note_unavailable(state, command, reason) do
    if reason in [
         :binding_unavailable,
         :invalid_binding_log,
         :binding_object_unavailable,
         :incomplete_binding_tail,
         :binding_directory_changed,
         :binding_file_changed
       ] do
      case LedgerCodec.header_key(:binding, [state.runtime_id, command]) do
        {:ok, key} -> %{state | pending_bindings: MapSet.put(state.pending_bindings, key)}
        _ -> state
      end
    else
      state
    end
  end

  defp mutation_open(%{fence: nil, pending_bindings: pending, pending_runs: runs}) do
    if MapSet.size(pending) == 0 and MapSet.size(runs) == 0,
      do: :ok,
      else: {:error, :ledger_fenced}
  end

  defp mutation_open(_), do: {:error, :ledger_fenced}

  defp binding_unknown(state, command, tx, file_identity) do
    fence = %{kind: :binding, command: command, tx: tx, identity: file_identity}
    {:reply, {:error, {:commit_unknown, tx["tx_id"]}}, %{state | fence: fence}}
  end

  defp do_open_binding(state, command, [catalog, declaration, creation], runtime) do
    with :ok <- mutation_open(state),
         {:ok, capture} <-
           ParentBinding.capture(state.runtime_id, command, catalog, declaration, creation),
         :ok <- install_capture(state, capture),
         {:ok, next} <- binding_directory(state),
         path = binding_path(next, capture.key),
         {:ok, tx} <-
           ParentBinding.transaction(capture.key, 0, ParentBinding.prepare_mutation(capture)) do
      case File.lstat(path) do
        {:error, :enoent} ->
          case create_binding_header(next, path, capture.header) do
            :ok -> {:ok, capture.key, next}
            {:unknown, file_identity} -> {:unknown, tx, file_identity, next}
            {:error, reason} -> {:error, reason}
          end

        {:ok, _} ->
          with {:ok, image} <- binding_image(next, command),
               true <- image.decoded.tail == :complete,
               {:ok, _} <-
                 ParentBinding.replay(
                   capture,
                   image.decoded.transactions,
                   history(runtime, capture, image.decoded.transactions)
                 ),
               :ok <- confirm_binding(next, image) do
            {:ok, capture.key, next}
          else
            false -> {:error, :incomplete_binding_tail}
            {:error, reason} -> {:error, reason}
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp do_open_binding(_, _, _, _), do: {:error, :invalid_parent_capture}

  defp do_commit_binding(state, command, tx, runtime) when is_map(tx) do
    with :ok <- mutation_open(state),
         {:ok, _} <- LedgerCodec.encode_json(tx, :frame),
         {:ok, image} <- binding_image(state, command),
         true <- image.decoded.tail == :complete,
         {:ok, capture} <- image_capture(state, command, image, tx),
         observed = history(runtime, capture, image.decoded.transactions ++ [tx]),
         {:ok, reduced} <- ParentBinding.replay(capture, image.decoded.transactions, observed),
         {:ok, next, result} <- ParentBinding.admit(reduced, tx, observed) do
      if next.version == reduced.version do
        with :ok <- confirm_binding(state, image), do: {:ok, result}
      else
        with :ok <- install_capture(state, capture),
             {:ok, payload} <- LedgerCodec.encode_json(tx, :frame),
             {:ok, frame} <- LedgerCodec.encode_frame(payload) do
          case append_binding(state, image, frame) do
            :ok -> {:ok, result}
            {:error, _reason} -> {:unknown, image.identity}
          end
        end
      end
    else
      false -> {:error, :incomplete_binding_tail}
      {:error, reason} -> {:error, reason}
    end
  end

  defp do_commit_binding(_, _, _, _), do: {:error, :invalid_binding_transaction}

  defp do_lookup_binding(state, command, tx_id, runtime) do
    with true <- is_binary(tx_id) and Regex.match?(~r/\A[0-9a-f]{64}\z/, tx_id),
         :ok <- lookup_allowed(state, command, tx_id),
         {:ok, image} <- binding_image(state, command),
         :ok <- original_identity(state, image),
         {:ok, reduced} <- reduce_image(state, command, image, runtime),
         :ok <- recover_binding(state, image),
         {:ok, confirmed} <- binding_image(state, command),
         true <- confirmed.decoded.tail == :complete and confirmed.identity == image.identity,
         {:ok, final} <- reduce_image(state, command, confirmed, runtime),
         true <- final.version == reduced.version,
         :ok <- resolved_original(state, final),
         :ok <- confirm_binding(state, confirmed) do
      result =
        case Enum.find(final.transactions, fn {tx, _} -> tx["tx_id"] == tx_id end) do
          nil -> :absent
          {_, result} -> result
        end

      pending = MapSet.delete(state.pending_bindings, confirmed.decoded.key)
      recoverable = MapSet.delete(state.recoverable_bindings, confirmed.decoded.key)

      {:ok, result,
       %{state | fence: nil, pending_bindings: pending, recoverable_bindings: recoverable}}
    else
      false -> {:error, :binding_lookup_unavailable}
      {:error, reason} -> {:error, reason}
    end
  end

  defp resolved_original(%{fence: nil}, _), do: :ok

  defp resolved_original(%{fence: %{tx: expected}}, final) do
    case Enum.find(final.transactions, fn {tx, _} -> tx["tx_id"] == expected["tx_id"] end) do
      {^expected, _} ->
        :ok

      nil ->
        if final.version == expected["expected_version"],
          do: :ok,
          else: {:error, :binding_conflict}

      _ ->
        {:error, :binding_conflict}
    end
  end

  defp lookup_allowed(%{fence: nil}, _, _), do: :ok

  defp lookup_allowed(%{fence: %{kind: :binding, command: command, tx: %{"tx_id" => tx_id}}}, command, tx_id),
    do: :ok

  defp lookup_allowed(_, _, _), do: {:error, :ledger_fenced}

  defp original_identity(%{fence: nil}, _), do: :ok
  defp original_identity(%{fence: %{identity: identity}}, %{identity: identity}), do: :ok
  defp original_identity(_, _), do: {:error, :binding_file_changed}

  defp reduce_image(_state, _command, %{decoded: %{transactions: []}} = image, _runtime) do
    {:ok,
     %{
       version: 0,
       bytes: image.decoded.complete_size,
       credit: 0,
       phase: :empty,
       parent: nil,
       transactions: []
     }}
  end

  defp reduce_image(state, command, image, runtime) do
    with {:ok, capture} <- image_capture(state, command, image, nil) do
      ParentBinding.replay(
        capture,
        image.decoded.transactions,
        history(runtime, capture, image.decoded.transactions)
      )
    end
  end

  defp image_capture(state, command, image, proposed) do
    case image.decoded.transactions ++ List.wrap(proposed) do
      [%{"mutation" => %{"kind" => "prepare_parent", "creation_sha256" => creation_hash}} | _] ->
        with {:ok, creation} <- read_object(state, creation_hash),
             {:ok, object} <- LedgerCodec.decode_json(creation, :object),
             {:ok, catalog} <- read_object(state, object["catalog_sha256"]),
             {:ok, declaration} <- read_object(state, object["declaration_sha256"]),
             {:ok, capture} <-
               ParentBinding.capture(state.runtime_id, command, catalog, declaration, creation) do
          {:ok, capture}
        end

      _ ->
        {:error, :invalid_binding_prefix}
    end
  end

  defp read_object(state, hash) when is_binary(hash) and byte_size(hash) == 64 do
    with true <- Regex.match?(~r/\A[0-9a-f]{64}\z/, hash),
         {:ok, bytes} <- read_file(state, Path.join(state.directory, hash)),
         true <- digest(bytes) == hash do
      {:ok, bytes}
    else
      _ -> {:error, :binding_object_unavailable}
    end
  end

  defp read_object(_, _), do: {:error, :binding_object_unavailable}

  defp history(runtime, capture, transactions) do
    if Enum.any?(transactions, &match?(%{"mutation" => %{"kind" => "bind_parent"}}, &1)) do
      case ParentBinding.observe_creation(runtime, capture) do
        {:ok, {:historical, row}} -> {:historical, row}
        _ -> :unobserved
      end
    else
      :unobserved
    end
  end

  defp install_capture(state, capture) do
    Enum.reduce_while(capture.object_bytes, :ok, fn bytes, :ok ->
      case install_object(state, bytes) do
        {:ok, _hash} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp view(reduced),
    do: Map.take(reduced, [:version, :bytes, :credit, :phase, :parent, :transactions])

  defp run_view(reduced),
    do: Map.take(reduced, [:version, :bytes, :credit, :phase, :count, :reserved_tokens,
                         :charged_tokens, :transactions])

  defp note_run_unavailable(state, identifiers, reason) do
    if reason in [:run_unavailable, :invalid_run_log, :incomplete_run_tail,
                  :binding_unavailable, :invalid_binding_log, :binding_object_unavailable,
                  :binding_directory_changed, :binding_file_changed, :invalid_parent_capture,
                  :invalid_binding_prefix, :incomplete_binding_tail,
                  :creation_history_unavailable] do
      case LedgerCodec.header_key(:run, identifiers) do
        {:ok, key} -> %{state | pending_runs: MapSet.put(state.pending_runs, key)}
        _ -> state
      end
    else
      state
    end
  end

  defp run_unknown(state, command, identifiers, tx, file_identity) do
    fence = %{kind: :run, command: command, identifiers: identifiers, tx: tx,
              identity: file_identity}
    {:reply, {:error, {:commit_unknown, tx["tx_id"]}}, %{state | fence: fence}}
  end

  # Concept: run initialization has the same actual parent provenance as binding.
  # Technical depth: read the owned physical log and objects, observe Core's
  # original creation, then rebuild the pure empty run. No caller projection or
  # nil runtime can supply a bound parent or replace its declaration.
  defp run_parent(state, command, identifiers, runtime) do
    with {:ok, image} <- binding_image(state, command),
         true <- image.decoded.tail == :complete,
         {:ok, capture} <- image_capture(state, command, image, nil),
         observed = history(runtime, capture, image.decoded.transactions),
         {:ok, parent} <- RunLedger.new(identifiers, capture, image.decoded.transactions, observed),
         :ok <- confirm_run_parent(state, image) do
      {:ok, parent}
    else
      false -> {:error, :incomplete_binding_tail}
      {:error, reason} -> {:error, reason}
    end
  end

  defp do_open_run(state, command, identifiers, runtime) do
    with :ok <- mutation_open(state),
         {:ok, parent} <- run_parent(state, command, identifiers, runtime),
         {:ok, key} <- LedgerCodec.header_key(:run, identifiers),
         {:ok, next} <- ledger_directory(state, :run),
         path = ledger_path(next, :run, key),
         {:ok, tx} <- RunMutation.transaction(identifiers, 0, RunLedger.initialize_mutation(parent)) do
      case File.lstat(path) do
        {:error, :enoent} ->
          if MapSet.member?(next.known_runs, key) do
            {:error, :run_unavailable}
          else
            next = %{next | known_runs: MapSet.put(next.known_runs, key)}
            case create_ledger_header(next, path, parent.header, :run) do
              :ok -> {:ok, key, next}
              {:unknown, file_identity} -> {:unknown, tx, file_identity, next}
              {:error, reason} -> {:error, reason}
            end
          end

        {:ok, _} ->
          with {:ok, image} <- ledger_image(next, :run, identifiers),
               true <- image.decoded.tail == :complete,
               {:ok, _} <- reduce_run(parent, image),
               :ok <- confirm_run(next, image) do
            {:ok, key, next}
          else
            false -> {:error, :incomplete_run_tail}
            {:error, reason} -> {:error, reason}
          end

        {:error, _} -> {:error, :run_unavailable}
      end
    end
  end

  defp do_commit_run(state, command, identifiers, tx, runtime) do
    with :ok <- mutation_open(state),
         {:ok, ^tx} <- RunMutation.validate(identifiers, tx),
         true <- tx["mutation"]["kind"] == "initialize",
         {:ok, parent} <- run_parent(state, command, identifiers, runtime),
         {:ok, image} <- ledger_image(state, :run, identifiers),
         :ok <- complete_run(image),
         {:ok, reduced} <- reduce_run(parent, image),
         {:ok, next, result} <- RunLedger.admit(reduced, tx) do
      if next.version == reduced.version do
        case confirm_run(state, image) do
          :ok -> {:ok, result}
          {:error, _} -> {:unknown, image.identity}
        end
      else
        with {:ok, payload} <- LedgerCodec.encode_json(tx, :frame),
             {:ok, frame} <- LedgerCodec.encode_frame(payload) do
          case append_ledger(state, image, frame, :run) do
            :ok -> {:ok, result}
            {:error, _} -> {:unknown, image.identity}
          end
        end
      end
    else
      false -> {:error, :invalid_run_prefix}
      {:error, reason} -> {:error, reason}
    end
  end

  defp complete_run(%{decoded: %{tail: :complete}}), do: :ok
  defp complete_run(_), do: {:error, :incomplete_run_tail}

  defp confirm_run_parent(state, image) do
    case confirm_binding(state, image) do
      :ok -> :ok
      {:error, _} -> {:error, :binding_unavailable}
    end
  end

  defp confirm_run(state, image) do
    case confirm_ledger(state, image, :run) do
      :ok -> :ok
      {:error, _} -> {:error, :run_unavailable}
    end
  end

  defp reduce_run(parent, image) do
    Enum.reduce_while(image.decoded.transactions, {:ok, parent}, fn tx, {:ok, current} ->
      case RunLedger.admit(current, tx) do
        {:ok, next, _} -> {:cont, {:ok, next}}
        _ -> {:halt, {:error, :invalid_run_log}}
      end
    end)
  end

  defp do_lookup_run(state, command, identifiers, tx_id, runtime) do
    with true <- is_binary(tx_id) and Regex.match?(~r/\A[0-9a-f]{64}\z/, tx_id),
         :ok <- run_lookup_allowed(state, command, identifiers, tx_id),
         {:ok, parent} <- run_parent(state, command, identifiers, runtime),
         {:ok, image} <- ledger_image(state, :run, identifiers),
         :ok <- original_identity(state, image),
         {:ok, reduced} <- reduce_run(parent, image),
         :ok <- recover_run(state, image),
         {:ok, confirmed} <- ledger_image(state, :run, identifiers),
         true <- confirmed.decoded.tail == :complete and confirmed.identity == image.identity,
         {:ok, final} <- reduce_run(parent, confirmed),
         true <- final.version == reduced.version,
         :ok <- resolved_original(state, final),
         :ok <- confirm_run(state, confirmed) do
      result =
        case Enum.find(final.transactions, fn {tx, _} -> tx["tx_id"] == tx_id end) do
          nil -> :absent
          {_, result} -> result
        end
      {:ok, result, %{state | fence: nil,
                     pending_runs: MapSet.delete(state.pending_runs, confirmed.decoded.key),
                     recoverable_runs: MapSet.delete(state.recoverable_runs, confirmed.decoded.key)}}
    else
      false -> {:error, :run_lookup_unavailable}
      {:error, reason} -> {:error, reason}
    end
  end

  defp run_lookup_allowed(%{fence: nil}, _, _, _), do: :ok
  defp run_lookup_allowed(%{fence: %{kind: :run, command: command, identifiers: identifiers,
                                   tx: %{"tx_id" => tx_id}}}, command, identifiers, tx_id), do: :ok
  defp run_lookup_allowed(_, _, _, _), do: {:error, :ledger_fenced}

  defp recover_run(_state, %{decoded: %{tail: :complete}}), do: :ok
  defp recover_run(%{fence: fence}, _) when not is_nil(fence),
    do: {:error, :run_recovery_unproved}
  defp recover_run(state, image) do
    if MapSet.member?(state.recoverable_runs, image.decoded.key),
      do: repair_ledger(state, image, :run),
      else: {:error, :run_recovery_unproved}
  end

  defp run_frames("", _identifiers, offset, transactions),
    do: {:ok, Enum.reverse(transactions), offset, :complete}
  defp run_frames(_bytes, _identifiers, _offset, [_]), do: {:error, :invalid_run_prefix}
  defp run_frames(bytes, identifiers, offset, []) do
    case LedgerCodec.decode_frame(bytes) do
      {:ok, payload, rest} ->
        with {:ok, tx} <- RunMutation.decode(identifiers, payload),
             true <- tx["expected_version"] == 0 and tx["mutation"]["kind"] == "initialize" do
          run_frames(rest, identifiers, offset + byte_size(bytes) - byte_size(rest), [tx])
        else
          _ -> {:error, :invalid_run_prefix}
        end
      {:error, :incomplete_frame} ->
        if possible_binding_tail?(bytes),
          do: {:ok, [], offset, :incomplete},
          else: {:error, :invalid_run_log}
      {:error, reason} -> {:error, reason}
    end
  end

  defp binding_path(state, key), do: Path.join([state.directory, "bindings", key <> ".log"])

  defp ledger_name(:binding), do: "bindings"
  defp ledger_name(:run), do: "runs"
  defp ledger_cap(:binding), do: @cap
  defp ledger_cap(:run), do: @run_cap
  defp ledger_path(state, kind, key),
    do: Path.join([state.directory, ledger_name(kind), key <> ".log"])
  defp directory_identity(state, :binding), do: state.binding_identity
  defp directory_identity(state, :run), do: state.run_identity
  defp put_directory_identity(state, :binding, value), do: %{state | binding_identity: value}
  defp put_directory_identity(state, :run, value), do: %{state | run_identity: value}
  defp ledger_checkpoint(state, :binding, step), do: checkpoint(state, step)
  defp ledger_checkpoint(state, :run, step), do: checkpoint(state, Map.fetch!(@run_checkpoints, step))

  # Concept: another parent's recovered file cannot be omitted from this gate.
  # Technical depth: present filenames are only recovery work, not proof of
  # complete Core history. Each must pass original lookup; missing expected logs
  # and startup history coverage remain the host's separate classification gate.
  defp binding_namespace(directory), do: ledger_namespace(directory, :binding)

  defp ledger_namespace(directory, kind) do
    path = Path.join(directory, ledger_name(kind))

    case File.lstat(path) do
      {:error, :enoent} ->
        {:ok, MapSet.new(), nil}

      {:ok, %File.Stat{type: :directory, mode: mode} = stat}
      when Bitwise.band(mode, 0o7777) == 0o700 ->
        with {:ok, names} <- File.ls(path),
             true <- Enum.all?(names, &Regex.match?(~r/\A[0-9a-f]{64}\.log\z/, &1)) do
          {:ok, MapSet.new(Enum.map(names, &String.trim_trailing(&1, ".log"))), identity(stat)}
        else
          _ -> {:error, invalid_namespace(kind)}
        end

      _ ->
        {:error, invalid_namespace(kind)}
    end
  end

  defp binding_directory(state), do: ledger_directory(state, :binding)

  defp ledger_directory(state, kind) do
    path = Path.join(state.directory, ledger_name(kind))

    with :ok <- verify(state) do
      case directory_identity(state, kind) do
        nil ->
          with :ok <- File.mkdir(path),
               :ok <- File.chmod(path, 0o700),
               :ok <- Log.sync_parent(path),
               {:ok, info} <- File.lstat(path) do
            {:ok, put_directory_identity(state, kind, identity(info))}
          end

        _ ->
          with :ok <- verify_ledger_directory(state, kind), do: {:ok, state}
      end
    end
  end

  defp verify_ledger_directory(state, kind) do
    with :ok <- verify(state),
         {:ok, %File.Stat{type: :directory} = info} <-
           File.lstat(Path.join(state.directory, ledger_name(kind))),
         true <-
           identity(info) == directory_identity(state, kind) and Bitwise.band(info.mode, 0o7777) == 0o700 do
      :ok
    else
      _ -> {:error, :binding_directory_changed}
    end
  end

  defp create_binding_header(state, path, header),
    do: create_ledger_header(state, path, header, :binding)

  defp create_ledger_header(state, path, header, kind) do
    case :file.open(String.to_charlist(path), [:write, :binary, :raw, :exclusive]) do
      {:ok, io} ->
        case :file.read_file_info(io) do
          {:ok, record} ->
            file_identity = identity(File.Stat.from_record(record))

            result =
              ledger_io(state, io, path, file_identity, header, kind, fn ->
                with :ok <- File.chmod(path, 0o600),
                     :ok <- :file.write(io, header),
                     :ok <- ledger_checkpoint(state, kind, :binding_header_written),
                     :ok <- :file.sync(io),
                     :ok <- ledger_checkpoint(state, kind, :binding_header_synced),
                     do: :ok
              end)

            case result do
              :ok -> :ok
              {:error, _} -> {:unknown, file_identity}
            end

          {:error, _} ->
            :file.close(io)
            {:unknown, nil}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Concept: an ambiguous append fences the entire owner until original lookup.
  # Technical depth: the first half is a real physical write, allowing genuine
  # crash cuts. Every acknowledgement follows sync, close, parent sync and exact
  # path/descriptor identity verification under the retained exclusive lease.
  defp append_binding(state, image, frame), do: append_ledger(state, image, frame, :binding)

  defp append_ledger(state, image, frame, kind) do
    with :ok <- verify_ledger_directory(state, kind),
         :ok <- same_binding_file(image.path, image.identity),
         {:ok, io} <- :file.open(String.to_charlist(image.path), [:read, :write, :binary, :raw]) do
      ledger_io(state, io, image.path, image.identity, image.bytes <> frame, kind, fn ->
        with {:ok, record} <- :file.read_file_info(io),
             true <- File.Stat.from_record(record).size == byte_size(image.bytes),
             {:ok, original} <- :file.pread(io, 0, ledger_cap(kind) + 1),
             true <- original == image.bytes,
             {:ok, _} <- :file.position(io, byte_size(image.bytes)),
             half = div(byte_size(frame), 2),
             <<first::binary-size(^half), rest::binary>> = frame,
             :ok <- :file.write(io, first),
             :ok <- ledger_checkpoint(state, kind, :binding_partial_written),
             :ok <- :file.write(io, rest),
             :ok <- ledger_checkpoint(state, kind, :binding_written),
             :ok <- :file.sync(io),
             :ok <- ledger_checkpoint(state, kind, :binding_synced) do
          :ok
        else
          false -> {:error, :binding_file_changed}
          {:error, reason} -> {:error, reason}
        end
      end)
    end
  end

  defp ledger_io(state, io, path, file_identity, expected_bytes, ledger_kind, operation) do
    result =
      try do
        with {:ok, record} <- :file.read_file_info(io),
             true <- identity(File.Stat.from_record(record)) == file_identity,
             :ok <- verify_ledger_directory(state, ledger_kind),
             do: operation.()
      catch
        kind, reason -> {:error, {:binding_io_interrupted, kind, reason}}
      end

    closed = :file.close(io)

    try do
      with :ok <- result,
           :ok <- closed,
           :ok <- ledger_checkpoint(state, ledger_kind, :binding_closed),
           :ok <- same_binding_file(path, file_identity),
           :ok <- Log.sync_parent(path),
           :ok <- ledger_checkpoint(state, ledger_kind, :binding_directory_synced),
           :ok <- verify_ledger_directory(state, ledger_kind),
           :ok <- same_binding_file(path, file_identity),
           :ok <- ledger_readback(state, path, file_identity, expected_bytes, ledger_kind) do
        :ok
      else
        false -> {:error, :binding_file_changed}
        {:error, reason} -> {:error, reason}
      end
    catch
      kind, reason -> {:error, {:binding_io_interrupted, kind, reason}}
    end
  end

  defp ledger_readback(state, path, file_identity, expected, ledger_kind) do
    with {:ok, io} <- :file.open(String.to_charlist(path), [:read, :binary, :raw]) do
      result =
        try do
          with {:ok, record} <- :file.read_file_info(io),
               true <- identity(File.Stat.from_record(record)) == file_identity,
               {:ok, bytes} <- :file.read(io, ledger_cap(ledger_kind) + 1),
               true <- bytes == expected,
               :ok <- verify_ledger_directory(state, ledger_kind),
               :ok <- same_binding_file(path, file_identity) do
            :ok
          else
            _ -> {:error, :binding_file_changed}
          end
        catch
          kind, reason -> {:error, {:binding_read_interrupted, kind, reason}}
        end

      closed = :file.close(io)
      with :ok <- closed, do: result
    end
  end

  defp same_binding_file(path, expected) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular, links: 1} = stat} ->
        if identity(stat) == expected and Bitwise.band(stat.mode, 0o7777) == 0o600,
          do: :ok,
          else: {:error, :binding_file_changed}

      _ ->
        {:error, :binding_file_changed}
    end
  end

  defp binding_image(state, command),
    do: ledger_image(state, :binding, [state.runtime_id, command])

  defp ledger_image(state, kind, identifiers) do
    cap = ledger_cap(kind)
    with {:ok, key} <- LedgerCodec.header_key(kind, identifiers),
         :ok <- verify_ledger_directory(state, kind),
         path = ledger_path(state, kind, key),
         {:ok, %File.Stat{type: :regular, links: 1} = info} <- File.lstat(path),
         true <- info.size in 1..cap and Bitwise.band(info.mode, 0o7777) == 0o600,
         {:ok, io} <- :file.open(String.to_charlist(path), [:read, :binary, :raw]) do
      result =
        try do
          with {:ok, record} <- :file.read_file_info(io),
               true <- identity(File.Stat.from_record(record)) == identity(info),
               {:ok, bytes} <- :file.read(io, cap + 1),
               true <- byte_size(bytes) == info.size,
               :ok <- verify_ledger_directory(state, kind),
               :ok <- same_binding_file(path, identity(info)),
               {:ok, decoded} <- decode_ledger(bytes, kind, identifiers) do
            {:ok, %{path: path, identity: identity(info), bytes: bytes, decoded: decoded}}
          else
            _ -> {:error, invalid_log(kind)}
          end
        catch
          kind, reason -> {:error, {:binding_read_interrupted, kind, reason}}
        end

      closed = :file.close(io)
      with :ok <- closed, do: result
    else
      _ -> {:error, unavailable_log(kind)}
    end
  end

  defp decode_ledger(bytes, :binding, [runtime, command]), do: decode_binding(bytes, runtime, command)
  defp decode_ledger(bytes, :run, identifiers), do: decode_run(bytes, identifiers)
  defp invalid_log(:binding), do: :invalid_binding_log
  defp invalid_log(:run), do: :invalid_run_log
  defp invalid_namespace(:binding), do: :invalid_binding_namespace
  defp invalid_namespace(:run), do: :invalid_run_namespace
  defp unavailable_log(:binding), do: :binding_unavailable
  defp unavailable_log(:run), do: :run_unavailable

  defp confirm_binding(state, image), do: confirm_ledger(state, image, :binding)

  defp confirm_ledger(state, image, kind) do
    with :ok <- same_binding_file(image.path, image.identity),
         {:ok, io} <- :file.open(String.to_charlist(image.path), [:read, :binary, :raw]) do
      ledger_io(state, io, image.path, image.identity, image.bytes, kind, fn ->
        with {:ok, bytes} <- :file.read(io, ledger_cap(kind) + 1),
             true <- bytes == image.bytes,
             :ok <- :file.sync(io),
             :ok <- ledger_checkpoint(state, kind, :binding_recovered_synced) do
          :ok
        else
          _ -> {:error, :binding_file_changed}
        end
      end)
    end
  end

  # Concept: a running writer cannot repair its own interrupted append.
  # Technical depth: uncertain termination retains the old marker. Only a later
  # exclusive acquire with stale-writer recovery permits truncation of a file
  # present at that acquisition. Successful lookup consumes that permission;
  # a current-owner append fence never inherits it. Lookup compares the complete
  # observed image after the checkpoint and syncs the result.
  defp recover_binding(_state, %{decoded: %{tail: :complete}}), do: :ok

  defp recover_binding(%{fence: fence}, _) when not is_nil(fence),
    do: {:error, :binding_recovery_unproved}

  defp recover_binding(state, image) do
    if MapSet.member?(state.recoverable_bindings, image.decoded.key),
      do: repair_binding(state, image),
      else: {:error, :binding_recovery_unproved}
  end

  defp repair_binding(state, image), do: repair_ledger(state, image, :binding)

  defp repair_ledger(state, image, kind) do
    with :ok <- same_binding_file(image.path, image.identity),
         {:ok, io} <- :file.open(String.to_charlist(image.path), [:read, :write, :binary, :raw]) do
      ledger_io(
        state,
        io,
        image.path,
        image.identity,
        binary_part(image.bytes, 0, image.decoded.complete_size),
        kind,
        fn ->
          with {:ok, bytes} <- :file.read(io, ledger_cap(kind) + 1),
               true <- bytes == image.bytes,
               :ok <- ledger_checkpoint(state, kind, :binding_before_truncate),
               :ok <- same_binding_file(image.path, image.identity),
               {:ok, current} <- :file.pread(io, 0, ledger_cap(kind) + 1),
               true <- current == image.bytes,
               {:ok, offset} <- :file.position(io, image.decoded.complete_size),
               true <- offset == image.decoded.complete_size,
               :ok <- :file.truncate(io),
               :ok <- ledger_checkpoint(state, kind, :binding_truncated),
               :ok <- :file.sync(io),
               :ok <- ledger_checkpoint(state, kind, :binding_repair_synced) do
            :ok
          else
            _ -> {:error, :binding_file_changed}
          end
        end
      )
    end
  end

  defp binding_frames("", offset, transactions),
    do: {:ok, Enum.reverse(transactions), offset, :complete}

  defp binding_frames(_bytes, _offset, transactions) when length(transactions) == 2,
    do: {:error, :invalid_binding_prefix}

  defp binding_frames(bytes, offset, transactions) do
    case LedgerCodec.decode_frame(bytes) do
      {:ok, payload, rest} ->
        with {:ok, tx} <- LedgerCodec.decode_json(payload, :frame) do
          binding_frames(rest, offset + byte_size(bytes) - byte_size(rest), [tx | transactions])
        end

      {:error, :incomplete_frame} ->
        if possible_binding_tail?(bytes),
          do: {:ok, Enum.reverse(transactions), offset, :incomplete},
          else: {:error, :invalid_binding_log}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp possible_binding_tail?(bytes) do
    expected = <<"LXPHELP1", 1::unsigned-big-16>>
    available = min(byte_size(bytes), byte_size(expected))
    magic_matches = binary_part(bytes, 0, available) == binary_part(expected, 0, available)

    if byte_size(bytes) >= 14 do
      <<prefix::binary-14, remaining::binary>> = bytes
      <<_::binary-10, size::unsigned-big-32>> = prefix
      checksum_bytes = min(byte_size(remaining), 32)
      checksum = :crypto.hash(:sha256, prefix)

      valid_header =
        magic_matches and size in 1..65_536 and
          binary_part(remaining, 0, checksum_bytes) == binary_part(checksum, 0, checksum_bytes)

      if valid_header and byte_size(remaining) >= 32 + size do
        <<_::binary-32, payload::binary-size(^size), trailer::binary>> = remaining
        trailer_hash = :crypto.hash(:sha256, payload)

        byte_size(trailer) < 32 and
          trailer == binary_part(trailer_hash, 0, byte_size(trailer))
      else
        valid_header
      end
    else
      magic_matches
    end
  end

  defp confirm_existing(state, path, hash) do
    with :ok <- sync_file(path),
         :ok <- checkpoint(state, :existing_synced),
         :ok <- Log.sync_parent(path),
         :ok <- checkpoint(state, :directory_synced),
         {:ok, bytes} <- read_file(state, path),
         true <- digest(bytes) == hash do
      {:ok, hash}
    else
      false -> unknown(hash, :object_integrity_conflict)
      {:error, reason} -> unknown(hash, reason)
    end
  end

  # Concept: only this owner may publish; readers never promote temporary files.
  # Technical depth: the writer lock and serial mailbox prevent another installer
  # from racing the absent check. Only this invocation's exclusive temporary is
  # removed on a returned failure; process death leaves an unreferenced temporary.
  defp publish(state, path, hash, bytes) do
    temporary =
      Path.join(state.directory, ".tmp-" <> Base.encode16(:crypto.strong_rand_bytes(16)))

    try do
      with {:ok, io} <-
             :file.open(String.to_charlist(temporary), [:write, :raw, :binary, :exclusive]) do
        written =
          try do
            with :ok <- :file.write(io, bytes),
                 :ok <- checkpoint(state, :temporary_written),
                 :ok <- :file.sync(io),
                 :ok <- checkpoint(state, :temporary_synced),
                 :ok <- verify(state) do
              :ok
            end
          catch
            kind, reason ->
              :file.close(io)
              :erlang.raise(kind, reason, __STACKTRACE__)
          end

        closed = :file.close(io)

        with :ok <- written,
             :ok <- closed,
             {:error, :enoent} <- File.lstat(path),
             :ok <- File.rename(temporary, path) do
          with :ok <- checkpoint(state, :renamed),
               :ok <- Log.sync_parent(path),
               :ok <- checkpoint(state, :directory_synced),
               {:ok, published} <- read_file(state, path),
               true <- published == bytes do
            {:ok, hash}
          else
            false -> unknown(hash, :object_integrity_conflict)
            {:error, reason} -> unknown(hash, reason)
          end
        else
          {:ok, _existing} -> {:error, :object_integrity_conflict}
          {:error, reason} -> {:error, reason}
        end
      end
    after
      File.rm(temporary)
    end
  end

  defp unknown(hash, reason), do: {:error, {:object_durability_unknown, hash, reason}}

  defp checkpoint(state, step), do: state.checkpoint.(step)

  defp valid_bytes(bytes) when is_binary(bytes) and byte_size(bytes) in 1..@cap do
    if String.valid?(bytes), do: :ok, else: {:error, :invalid_object_bytes}
  end

  defp valid_bytes(_), do: {:error, :invalid_object_bytes}

  defp read_file(state, path) do
    with {:ok, %File.Stat{type: :regular} = expected} <- File.lstat(path),
         true <- expected.size <= @cap,
         {:ok, io} <- :file.open(String.to_charlist(path), [:read, :binary, :raw]) do
      try do
        with {:ok, record} <- :file.read_file_info(io),
             opened = File.Stat.from_record(record),
             true <- identity(opened) == identity(expected) and opened.type == :regular,
             {:ok, bytes} <- :file.read(io, @cap + 1),
             :ok <- valid_bytes(bytes),
             :ok <- verify(state),
             {:ok, current} <- File.lstat(path),
             true <- current.type == :regular and identity(current) == identity(expected) do
          {:ok, bytes}
        else
          false -> {:error, :invalid_or_corrupt_object}
          :eof -> {:error, :invalid_or_corrupt_object}
          {:error, reason} -> {:error, reason}
        end
      after
        :file.close(io)
      end
    else
      {:ok, _} -> {:error, :invalid_or_corrupt_object}
      false -> {:error, :invalid_or_corrupt_object}
      {:error, reason} -> {:error, reason}
    end
  end

  defp sync_file(path) do
    with {:ok, io} <- :file.open(String.to_charlist(path), [:read, :binary, :raw]) do
      result = :file.sync(io)
      closed = :file.close(io)
      with :ok <- result, do: closed
    end
  end

  defp verify(state) do
    with :ok <- physical_directory(state.root),
         :ok <- placement(state.root, state.placement_owner),
         {:ok, %File.Stat{type: :regular} = lock_stat} <- File.lstat(state.lock.path),
         true <- lock_stat.size == byte_size(state.lock.marker),
         {:ok, marker} <- File.read(state.lock.path),
         true <- marker == state.lock.marker do
      Enum.reduce_while(state.identities, :ok, fn {path, expected}, :ok ->
        case File.lstat(path) do
          {:ok, %File.Stat{type: :directory} = stat} ->
            if identity(stat) == expected,
              do: {:cont, :ok},
              else: {:halt, {:error, :object_root_changed}}

          _ ->
            {:halt, {:error, :object_root_changed}}
        end
      end)
    else
      false -> {:error, :object_writer_changed}
      {:ok, _} -> {:error, :object_writer_changed}
      {:error, reason} -> {:error, reason}
    end
  end

  defp placement(root, owner) when is_binary(owner) do
    lock = Path.join(root, "placement.lock")

    with true <-
           Path.dirname(owner) == root and
             String.starts_with?(Path.basename(owner), "placement.lock.owner-"),
         {:ok, %File.Stat{type: :regular} = acquired} <- File.lstat(owner),
         {:ok, %File.Stat{type: :regular} = current} <- File.lstat(lock),
         true <- identity(acquired) == identity(current),
         {:ok, pid} <- Placement.live_owner(root),
         true <- pid == System.pid() do
      :ok
    else
      _ -> {:error, :placement_ownership_unavailable}
    end
  end

  defp placement(_, _), do: {:error, :placement_ownership_unavailable}

  defp physical_directory(path) do
    with {:ok, %File.Stat{type: :directory}} <- File.lstat(path) do
      parent = Path.dirname(path)
      if parent == path, do: :ok, else: physical_directory(parent)
    else
      _ -> {:error, :invalid_object_root}
    end
  end

  defp directories(root, runtime_hash) do
    Enum.reduce_while(["delegation", runtime_hash], {:ok, root}, fn component, {:ok, parent} ->
      child = Path.join(parent, component)

      with :ok <- physical_directory(parent),
           :ok <- mkdir(child),
           :ok <- physical_directory(child),
           :ok <- Log.sync_parent(child) do
        {:cont, {:ok, child}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp mkdir(path) do
    case File.mkdir(path) do
      :ok -> :ok
      {:error, :eexist} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp optional_writer_marker(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular}} -> :ok
      {:error, :enoent} -> :ok
      _ -> {:error, :invalid_object_root}
    end
  end

  defp identities(paths) do
    Enum.reduce_while(paths, {:ok, []}, fn path, {:ok, held} ->
      case File.lstat(path) do
        {:ok, %File.Stat{type: :directory} = stat} ->
          {:cont, {:ok, [{path, identity(stat)} | held]}}

        _ ->
          {:halt, {:error, :invalid_object_root}}
      end
    end)
  end

  defp identity(stat), do: {stat.major_device, stat.minor_device, stat.inode}
  defp digest(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
