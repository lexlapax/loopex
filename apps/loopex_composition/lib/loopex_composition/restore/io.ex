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

  This private prerequisite exposes bounded reads, complete physical manifests,
  durable record publication, complete declared-Store semantic auditing and one
  canonical retained Resource or Local ledger record audit, and complete Local
  generation/marker/open-plane enumeration and selected reference-bound artifact
  use capture and one locator-selected streaming object audit to composition only.
  A private transition worker validates retained prior lineage and sequences
  available-source retirement or lost-source host-exclusion evidence, exact
  copy/publication and terminal
  claim release without replacing the original guardian or deadlines. Public
  restore/lookup and the remaining accepted variants are unfinished. Validated
  maps and recovered facts remain private; standalone audit operations grant no
  effect authority and do not activate a restored root. Host exclusion remains the caller's
  obligation. The caller must first validate the captured manifest against the
  original invocation's total-file-byte limit. This operation validates canonical
  membership and the selected file and ancestors; it does not re-hash
  other inventory members or establish whole-backup validity.
  """

  require Record
  Record.defrecordp(:file_info, Record.extract(:file_info, from_lib: "kernel/include/file.hrl"))

  alias Loopex.ArtifactStore
  alias Loopex.Executor.Local.{Ledger, RestoreCodec, RestoreGuard}
  alias Loopex.Runtime.SessionState
  alias Loopex.Store.Local.{Artifacts, Log, State}
  alias LoopexComposition.ResourcePacks

  @max_receive_timeout 4_294_967_295
  @chunk 65_536
  @max_read 268_435_456
  @max_resource_manifest 72_081_510
  @max_resource_provenance 1_126_241
  @max_ledger_generation 2_048
  @max_ledger_record 65_536
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
          worker_exit_seen: false,
          final_observation: :off,
          forced: false,
          work_cutoff: admitted + limits.work_ms,
          grace: limits.cleanup_grace_ms,
          cleanup_window: limits.cleanup_window_ms,
          stop: nil,
          cooperative_cutoff: nil,
          cleanup_cutoff: nil,
          restore:
            if(match?({:restore_first, _, _}, operation),
              do: %{phase: "claim", intent: false, claims: []},
              else: nil
            ),
          terminal_release: false,
          terminal_payload: nil
        }

        notify(state, {:installed, admitted, state.work_cutoff})
        send(worker, {:start, reference})
        guard(state)
    end
  end

  defp guard(state) do
    state = check_cutoffs(state)

    # Concept: join admission ends at the original cleanup observation cutoff.
    # Technical depth: a queued normal DOWN consumed late cannot let clean state
    # bypass expiry or admit terminal release under the caller's later bound.
    cond do
      state.cleanup_cutoff && now() >= state.cleanup_cutoff ->
        finish(state, {:unconfirmed, uncertainty(state)})

      clean?(state) and release_needed?(state) and now() >= state.cooperative_cutoff ->
        finish(state, {:unconfirmed, :claim_release_unconfirmed})

      clean?(state) and release_needed?(state) ->
        start_terminal_release(state)

      clean?(state) ->
        finish(
          state,
          {:joined, terminal_payload(state),
           Map.merge(
             %{
               opens: state.opens,
               closes: state.closes,
               operations: state.acknowledgements,
               stop: state.stop,
               work_cutoff: state.work_cutoff,
               cleanup_cutoff: state.cleanup_cutoff
             },
             restore_evidence(state)
           )}
        )

      true ->
        receive_event(state)
    end
  end

  defp receive_event(state) do
    state = pause_final_observation(state)
    worker = state.worker
    reference = state.reference
    caller_monitor = state.caller_monitor
    worker_monitor = state.worker_monitor

    receive do
      {:issued, ^worker, ^reference, id, kind} when id == state.next and is_nil(state.pending) ->
        state =
          check_cutoffs(observe_restore_issue(%{state | pending: {id, kind}, next: id + 1}, kind))

        notify(state, {:issued, id, kind})

        cond do
          state.stop && not cleanup_operation?(state, kind) ->
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

      {:proceed_final_observation, ^reference, id} when state.paused ->
        state = check_cutoffs(state)

        if state.pending && elem(state.pending, 0) == id && is_nil(state.stop) &&
             state.final_observation == :off do
          permit(state, id, elem(state.pending, 1))
          guard(%{state | paused: false, final_observation: :armed})
        else
          guard(state)
        end

      {:proceed, ^reference, id} when state.paused ->
        state = check_cutoffs(state)

        if state.pending && elem(state.pending, 0) == id do
          kind = elem(state.pending, 1)

          if state.stop && not cleanup_operation?(state, kind),
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
          do: guard(not_issued(%{state | pending: nil, paused: false}, elem(state.pending, 1))),
          else: guard(stop(state, :history_invalid, now()))

      {:payload, ^worker, ^reference, result} ->
        result = if state.terminal_release, do: release_payload(state, result), else: result
        state = %{state | payload: result}
        guard(stop(state, if(match?({:ok, _}, result), do: :complete, else: :io_error), now()))

      {:finished, ^worker, ^reference} ->
        guard(%{state | finished: true})

      {:EXIT, ^worker, reason} ->
        state =
          if state.final_observation == :armed,
            do: %{state | worker_exit_seen: reason == :normal},
            else: state

        guard(state)

      {:DOWN, ^caller_monitor, :process, _caller, _reason} ->
        guard(stop(state, :caller_lost, now()))

      {:DOWN, ^worker_monitor, :process, ^worker, reason} ->
        if state.final_observation == :continued,
          do: notify(state, {:worker_down_observed, worker_monitor, reason == :normal, now()})

        state = %{state | down: reason == :normal}
        state = if state.stop, do: state, else: stop(state, :worker_unjoined, now())
        guard(state)
    after
      min(next_wait(state), @max_receive_timeout) -> guard(state)
    end
  end

  # Concept: a private scheduling control holds only final join observation.
  # Technical depth: arm through the exact already-paused primitive after fixture
  # monitors exist. Finished/closed acknowledgements and the genuine normal EXIT
  # are consumed first; DOWN remains for this already-entered receive to scan.
  # Continuation never rechecks cutoffs before that scan, renews an allowance or
  # changes a result. Only the following ordinary guard admits or refuses join.
  defp pause_final_observation(
         %{
           final_observation: :armed,
           finished: true,
           down: false,
           worker_exit_seen: true,
           pending: nil,
           forced: false
         } = state
       ) do
    if MapSet.size(state.open) == 0 and not is_nil(state.payload) and
         not is_nil(state.cleanup_cutoff) and now() < state.cleanup_cutoff do
      reference = state.reference
      paused_at = now()

      notify(
        state,
        {:final_observation_paused, state.worker_monitor, paused_at,
         %{
           finished: true,
           down: false,
           pending: false,
           open_count: 0,
           worker_exit_seen: true,
           opens: state.opens,
           closes: state.closes,
           stop: state.stop,
           stop_at: state.cooperative_cutoff - state.grace,
           work_cutoff: state.work_cutoff,
           cleanup_cutoff: state.cleanup_cutoff
         }}
      )

      continuation = await_final_observation(reference, state.cleanup_cutoff)

      notify(state, {:final_observation_continued, continuation, now()})
      %{state | final_observation: :continued}
    else
      state
    end
  end

  defp pause_final_observation(state), do: state

  defp await_final_observation(reference, cutoff) do
    receive do
      {:continue_final_observation, ^reference} -> :continued
    after
      wait_chunk(cutoff) ->
        if remaining(cutoff) > 0, do: await_final_observation(reference, cutoff), else: :expired
    end
  end

  defp acknowledge(state, {:open, token}, :opened),
    do: %{state | open: MapSet.put(state.open, token), opens: state.opens + 1}

  defp acknowledge(state, {:close, token}, :closed),
    do: %{state | open: MapSet.delete(state.open, token), closes: state.closes + 1}

  defp acknowledge(state, {:restore_claim_create, claim}, observation) do
    status =
      case observation do
        :created -> :partial
        :foreign -> :foreign
        _ -> :uncertain
      end

    retain_claim(state, claim, status)
  end

  defp acknowledge(state, {:restore_claim_acquired, claim}, :completed),
    do: retain_claim(state, claim, :acquired)

  defp acknowledge(state, {:restore_claim_released, directory}, :completed),
    do: %{
      state
      | restore: %{
          state.restore
          | claims: Enum.reject(state.restore.claims, &(&1.directory == directory))
        }
    }

  defp acknowledge(state, _kind, _observation), do: state

  defp not_issued(state, {:restore_claim_create, claim}),
    do: %{
      state
      | restore: %{
          state.restore
          | claims: Enum.reject(state.restore.claims, &(&1.directory == claim.directory))
        }
    }

  defp not_issued(state, _kind), do: state

  defp clean?(state),
    do:
      not is_nil(state.stop) && state.finished && state.down && not state.forced &&
        is_nil(state.pending) &&
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

  defp terminal_payload(%{restore: %{intent: true}} = state) do
    case state.payload do
      {:ok, %{restore_result: {:committed, _}, release_claims: []}}
      when state.stop == :complete ->
        state.payload

      {:ok, %{restore_result: {:commit_unknown, _}}} ->
        state.payload

      _ ->
        {:error, :restore_commit_unknown}
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
  # Concept: claim release is terminal cleanup, never a new work invocation.
  # Technical depth: only a fresh monitored serial release worker may issue the
  # fixed claim-only operations after original payload DOWN. It shares the
  # already captured cooperative and final cleanup cutoffs, tokens and counts.
  defp cleanup_operation?(state, kind),
    do:
      close_operation?(kind) or
        (state.terminal_release and
           kind_name(kind) in [
             :open,
             :stat,
             :read,
             :file_sync,
             :directory_sync,
             :claim_delete,
             :claim_directory_delete,
             :restore_claim_released,
             :descriptor_stat,
             :manifest_stat,
             :list
           ])

  defp release_needed?(%{terminal_release: false, payload: {:ok, %{release_claims: [_ | _]}}}),
    do: true

  defp release_needed?(_), do: false

  defp start_terminal_release(state) do
    {:ok, %{release_claims: claims}} = state.payload
    guardian = self()
    reference = state.reference

    {worker, monitor} =
      :erlang.spawn_opt(
        fn -> worker_start(guardian, reference, {:release_restore_claims, claims}) end,
        [:link, :monitor]
      )

    state = %{
      state
      | worker: worker,
        worker_monitor: monitor,
        terminal_release: true,
        terminal_payload: state.payload,
        payload: nil,
        finished: false,
        down: false,
        worker_exit_seen: false,
        pending: nil,
        paused: false,
        next: 1
    }

    notify(state, {:terminal_release_installed, state.cleanup_cutoff})
    send(worker, {:start, reference})
    guard(state)
  end

  defp release_payload(state, {:ok, :released}) do
    {:ok, payload} = state.terminal_payload
    {:ok, %{payload | release_claims: []}}
  end

  defp release_payload(_state, _), do: {:error, :claim_release_unconfirmed}

  defp observe_restore_issue(%{restore: nil} = state, _), do: state

  defp observe_restore_issue(state, {:restore_phase, phase}),
    do: %{state | restore: %{state.restore | phase: phase}}

  defp observe_restore_issue(state, {:intent_may_persist, phase}),
    do: %{state | restore: %{state.restore | phase: phase, intent: true}}

  defp observe_restore_issue(state, {:restore_claim_create, claim}),
    do: retain_claim(state, claim, :uncertain)

  defp observe_restore_issue(state, _), do: state

  # Concept: completed release removes only its proved claim, never a sibling.
  # Technical depth: mkdir issue is uncertain until acknowledged; EEXIST is
  # foreign, successful mkdir remains partial until owner publication and sync
  # complete. These private states never authorize deletion of a partial claim.
  defp retain_claim(state, claim, status) do
    claims = Enum.reject(state.restore.claims, &(&1.directory == claim.directory))
    %{state | restore: %{state.restore | claims: [Map.put(claim, :status, status) | claims]}}
  end

  defp restore_evidence(%{restore: nil}), do: %{}

  defp restore_evidence(state),
    do: %{
      restore: Map.drop(state.restore, [:claims]),
      claim_count: Enum.count(state.restore.claims, &(&1.status != :foreign))
    }

  defp close_operation?({:close, _token}), do: true
  defp close_operation?(_kind), do: false
  defp kind_name({name, _token}), do: name
  defp kind_name(name), do: name

  defp permit(state, id, kind) do
    cutoff =
      if state.stop && cleanup_operation?(state, kind),
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

  defp execute({:restore_lookup, root, tx_id}), do: lookup_operation(root, tx_id, nil)

  defp execute({:restore_classification, root, plan}),
    do: lookup_operation(root, plan["tx_id"], plan)

  defp execute({:restore_first, plan, invocation}),
    do: LoopexComposition.Restore.Workflow.execute(plan, invocation, &execute/1)

  defp execute({:restore_phase, phase}) do
    primitive({:restore_phase, phase}, fn -> :ok end)
    {:ok, phase}
  end

  defp execute({:intent_may_persist, phase}) do
    primitive({:intent_may_persist, phase}, fn -> :ok end)
    {:ok, phase}
  end

  defp execute({:placement, root}) do
    manifest_ancestors(root)
    info = manifest_stat(root)
    if file_info(info, :type) != :directory, do: throw({:io_error, :invalid_placement})

    {:ok,
     %{
       "expanded_root" => root,
       "major_device" => file_info(info, :major_device),
       "inode" => file_info(info, :inode)
     }}
  end

  # Concept: a lost source is an absent endpoint beneath existing physical directories.
  # Technical depth: only native lstat ENOENT qualifies. Capture and recheck every
  # nonsymlink ancestor around both endpoint observations; missing, inaccessible
  # or replaced ancestors never establish absence. The workflow retains this
  # vector across phases under the same guardian and original cutoffs.
  defp execute({:lost_source_absent, root}) do
    ancestors = manifest_ancestors(Path.dirname(root))
    require_source_absent(root)

    Enum.each(ancestors, fn {path, identity} ->
      if directory_identity(manifest_stat(path)) != identity,
        do: throw({:io_error, :source_changed})
    end)

    require_source_absent(root)

    Enum.each(ancestors, fn {path, identity} ->
      if directory_identity(manifest_stat(path)) != identity,
        do: throw({:io_error, :source_changed})
    end)

    {:ok, ancestors}
  end

  defp execute({:directory_names, root}) do
    {:ok, require_value(primitive(:list, fn -> :prim_file.list_dir_all(root) end))}
  end

  defp execute({:make_directory, path, mode}) do
    manifest_ancestors(Path.dirname(path))
    require_ok(primitive(:make_directory, fn -> :prim_file.make_dir(path) end))

    require_ok(
      primitive(:mode, fn -> :prim_file.write_file_info(path, file_info(mode: mode)) end)
    )

    directory_sync(Path.dirname(path))
    {:ok, :created}
  end

  defp execute({:ensure_admin_directory, path}) do
    case primitive(:stat, fn -> :prim_file.read_link_info(path) end) do
      {:error, :enoent} ->
        execute({:make_directory, path, 0o700})

      {:ok, info} ->
        if file_info(info, :type) != :directory or
             Bitwise.band(file_info(info, :mode), 0o7777) != 0o700,
           do: throw({:io_error, :invalid_administration})

        {:ok, :present}

      _ ->
        throw({:io_error, :invalid_administration})
    end
  end

  defp execute({:require_directory, path, mode}) do
    info = manifest_stat(path)

    if file_info(info, :type) != :directory or
         Bitwise.band(file_info(info, :mode), 0o7777) != mode,
       do: throw({:io_error, :source_changed})

    {:ok, :present}
  end

  defp execute({:set_directory_mode, path, mode}) do
    info = manifest_stat(path)
    if file_info(info, :type) != :directory, do: throw({:io_error, :source_changed})

    require_ok(
      primitive(:mode, fn -> :prim_file.write_file_info(path, file_info(mode: mode)) end)
    )

    directory_sync(path)
    directory_sync(Path.dirname(path))
    {:ok, :synced}
  end

  defp execute({:acquire_restore_claim, claim}) do
    manifest_ancestors(Path.dirname(claim.directory))

    require_ok(
      primitive({:restore_claim_create, claim}, fn -> :prim_file.make_dir(claim.directory) end)
    )

    require_ok(
      primitive(:mode, fn ->
        :prim_file.write_file_info(claim.directory, file_info(mode: 0o700))
      end)
    )

    directory_sync(Path.dirname(claim.directory))
    owner = Path.join(claim.directory, "owner")
    execute({:publish, owner, owner <> ".tmp", claim.owner, 0o600, :absent})
    directory_sync(Path.dirname(claim.directory))

    acquired =
      Map.merge(claim, %{
        directory_identity: directory_identity(manifest_stat(claim.directory)),
        owner_identity: manifest_stat(owner)
      })

    primitive({:restore_claim_acquired, acquired}, fn -> :ok end)
    {:ok, acquired}
  end

  defp execute({:release_restore_claims, claims}) do
    Enum.each(claims, fn claim ->
      owner = Path.join(claim.directory, "owner")
      ancestors = manifest_ancestors(Path.dirname(claim.directory))

      if directory_identity(manifest_stat(claim.directory)) != claim.directory_identity,
        do: throw({:io_error, :restore_claim_changed})

      names =
        require_value(primitive(:list, fn -> :prim_file.list_dir_all(claim.directory) end))
        |> Enum.map(&manifest_name/1)

      if names != ["owner"],
        do: throw({:io_error, :restore_claim_changed})

      require_same_identity(claim.owner_identity, manifest_stat(owner))
      descriptor = open(owner, [:raw, :binary, :read])

      require_same_identity(
        claim.owner_identity,
        require_value(
          primitive(:descriptor_stat, fn -> :prim_file.read_handle_info(descriptor) end)
        )
      )

      bytes = read_chunks(descriptor, 2048, [])

      require_same_identity(
        claim.owner_identity,
        require_value(
          primitive(:descriptor_stat, fn -> :prim_file.read_handle_info(descriptor) end)
        )
      )

      close(descriptor)
      require_same_identity(claim.owner_identity, manifest_stat(owner))
      if bytes != claim.owner, do: throw({:io_error, :restore_claim_changed})

      Enum.each(ancestors, fn {path, identity} ->
        if directory_identity(manifest_stat(path)) != identity,
          do: throw({:io_error, :restore_claim_changed})
      end)

      require_ok(primitive(:claim_delete, fn -> :prim_file.delete(owner) end))
      directory_sync(claim.directory)

      require_ok(
        primitive(:claim_directory_delete, fn -> :prim_file.del_dir(claim.directory) end)
      )

      directory_sync(Path.dirname(claim.directory))
      primitive({:restore_claim_released, claim.directory}, fn -> :ok end)
    end)

    {:ok, :released}
  end

  defp execute({:audit_receipt, root, relative, manifest}) do
    {:ok, entries} = RestoreCodec.manifest(manifest, @max_uint64)

    audit_captured_record(
      root,
      relative,
      Map.new(entries, &{&1["path"], &1}),
      65_536,
      :receipt_digest,
      :receipt_decode,
      &Loopex.Executor.Local.decode_receipt_bytes/1
    )
  end

  defp execute({:copy_file, source, destination, entry}) do
    source_ancestors = manifest_ancestors(Path.dirname(source))
    destination_ancestors = manifest_ancestors(Path.dirname(destination))
    before = manifest_stat(source)
    require_audit_file(before, entry)
    input = open(source, [:raw, :binary, :read])

    opened =
      require_value(primitive(:descriptor_stat, fn -> :prim_file.read_handle_info(input) end))

    require_same_identity(before, opened)
    output = open(destination, [:raw, :binary, :write, :exclusive])

    require_ok(
      primitive(:mode, fn ->
        :prim_file.write_file_info(destination, file_info(mode: entry["mode"]))
      end)
    )

    digest = copy_chunks(input, output, entry["size"], :crypto.hash_init(:sha256))
    require_ok(primitive(:file_sync, fn -> :prim_file.sync(output) end))
    close(output)

    require_same_identity(
      before,
      require_value(primitive(:descriptor_stat, fn -> :prim_file.read_handle_info(input) end))
    )

    require_same_identity(before, manifest_stat(source))
    close(input)
    directory_sync(Path.dirname(destination))
    if digest != entry["sha256"], do: throw({:io_error, :source_changed})

    Enum.each(source_ancestors ++ destination_ancestors, fn {path, identity} ->
      if directory_identity(manifest_stat(path)) != identity,
        do: throw({:io_error, :source_changed})
    end)

    {:ok, :copied}
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

  defp execute({:audit_store, root, declaration, manifest}) do
    # Concept: the physical inventory and declared Store select the only history
    # this operation may read; successful recovery never grants dispatch.
    # Technical depth: bounded decoding, transaction replay and every session
    # recovery run in this same guardian-owned worker. The complete private maps
    # retain commands, provenance, orphan resolutions and unresolved work.
    with {:ok, _} <-
           primitive(:store_declaration, fn ->
             RestoreCodec.encode(:store_descriptor, declaration)
           end),
         {:ok, entries} <-
           primitive(:store_manifest, fn -> RestoreCodec.manifest(manifest, @max_uint64) end) do
      index = Map.new(entries, &{&1["path"], &1})
      relative = declaration["relative_path"]
      entry = Map.get(index, relative)

      if not match?(%{"kind" => "regular"}, entry) or
           entry["sha256"] != declaration["sha256"] or entry["size"] > @max_read,
         do: throw({:io_error, :inventory_mismatch})

      ancestors = manifest_ancestors(root)
      directories = audit_directories(root, Path.dirname(relative), index)
      path = Path.join(root, relative)
      before = manifest_stat(path)
      require_audit_file(before, entry)
      descriptor = open(path, [:raw, :binary, :read])

      opened =
        require_value(
          primitive(:descriptor_stat, fn -> :prim_file.read_handle_info(descriptor) end)
        )

      require_same_identity(before, opened)
      bytes = read_chunks(descriptor, entry["size"], [])

      after_read =
        require_value(
          primitive(:descriptor_stat, fn -> :prim_file.read_handle_info(descriptor) end)
        )

      require_same_identity(before, after_read)
      require_same_identity(before, manifest_stat(path))
      close(descriptor)

      if byte_size(bytes) != entry["size"] or
           primitive(:store_digest, fn -> RestoreCodec.digest_bytes(bytes) end) != entry["sha256"],
         do: throw({:io_error, :inventory_mismatch})

      result = audit_store_bytes(bytes)
      require_same_identity(before, manifest_stat(path))

      Enum.each(directories, fn {directory, identity} ->
        if manifest_identity(manifest_stat(directory)) != identity,
          do: throw({:io_error, :source_changed})
      end)

      Enum.each(ancestors, fn {ancestor, identity} ->
        if directory_identity(manifest_stat(ancestor)) != identity,
          do: throw({:io_error, :source_changed})
      end)

      result
    else
      _ -> {:error, :history_invalid}
    end
  end

  defp execute({:audit_resource, root, kind, identity, manifest}) do
    # Concept: one canonical current writer record is checked without loading a
    # catalog, rediscovering provenance or granting resource admission.
    # Technical depth: role determines the filename and raw ETF ceiling before
    # open. Capture, streaming hash, decoding and physical revalidation remain
    # in the same owned worker; the guardian joins it before exposing the map.
    with {:ok, entries} <-
           primitive(:resource_manifest, fn -> RestoreCodec.manifest(manifest, @max_uint64) end) do
      {directory, ceiling} = resource_role(kind)
      relative = Path.join(["resource-packs", directory, identity <> ".etf"])
      index = Map.new(entries, &{&1["path"], &1})

      audit_captured_record(
        root,
        relative,
        index,
        ceiling,
        :resource_digest,
        :resource_decode,
        fn bytes ->
          case kind do
            :manifest -> ResourcePacks.decode_retained_manifest(bytes, identity)
            :provenance -> ResourcePacks.decode_retained_provenance(bytes, identity)
          end
        end
      )
    else
      _ -> {:error, :history_invalid}
    end
  end

  defp execute({:audit_ledger, root, declaration, role, job_id, manifest}) do
    # Concept: retained ledger metadata is evidence without live root authority.
    # Technical depth: the exact role fixes both canonical path and pre-open cap.
    # Source placement authenticates the retained generation, not the backup's
    # current inode; complete ledger, receipt and job-history relations stay separate.
    with {:ok, _} <-
           primitive(:ledger_declaration, fn ->
             RestoreCodec.encode(:ledger_descriptor, declaration)
           end),
         {:ok, entries} <-
           primitive(:ledger_manifest, fn -> RestoreCodec.manifest(manifest, @max_uint64) end) do
      {suffix, ceiling, kind} = ledger_role(role, job_id)
      relative = Path.join(declaration["relative_root"], suffix)
      index = Map.new(entries, &{&1["path"], &1})

      audit_captured_record(
        root,
        relative,
        index,
        ceiling,
        :ledger_digest,
        :ledger_decode,
        fn bytes ->
          with {:ok, record} <- Ledger.decode_bytes(bytes, kind),
               true <- ledger_relations?(record, bytes, declaration, role, job_id) do
            {:ok, record}
          else
            _ -> {:error, :history_invalid}
          end
        end
      )
    else
      _ -> {:error, :history_invalid}
    end
  end

  defp execute({:audit_ledger_index, root, declaration, manifest}) do
    # Concept: enumerate the complete generation/marker/open metadata plane.
    # Technical depth: all IO and reductions remain in this one owned worker.
    # Receipts, recovered jobs and restore history are separate obligations.
    with {:ok, _} <-
           primitive(:ledger_declaration, fn ->
             RestoreCodec.encode(:ledger_descriptor, declaration)
           end),
         {:ok, entries} <-
           primitive(:ledger_manifest, fn -> RestoreCodec.manifest(manifest, @max_uint64) end) do
      audit_ledger_index(root, declaration, Map.new(entries, &{&1["path"], &1}))
    else
      _ -> {:error, :history_invalid}
    end
  end

  defp execute({:audit_restore_lineage, root, plan, manifest}) do
    with {:ok, _} <- primitive(:restore_history_plan, fn -> RestoreCodec.encode(:plan, plan) end),
         {:ok, entries} <-
           primitive(:restore_history_manifest, fn ->
             RestoreCodec.manifest(manifest, @max_uint64)
           end) do
      index = Map.new(entries, &{&1["path"], &1})
      generations = MapSet.new(plan["ledgers"], &Path.join(&1["relative_root"], "generation"))

      selected =
        Enum.filter(entries, fn entry ->
          entry["kind"] == "regular" and
            (MapSet.member?(generations, entry["path"]) or
               Enum.any?(
                 Path.split(entry["path"]),
                 &(&1 in [".loopex-restore", "restore-lineage"])
               ))
        end)

      # Concept: current record caps apply before any lineage file is opened.
      # Technical depth: every captured byte remains in the original manifest's
      # caller-checked total. No nested guardian, allowance or old-root IO exists.
      ceilings =
        Map.new(selected, fn entry ->
          ceiling =
            cond do
              MapSet.member?(generations, entry["path"]) -> @max_ledger_generation
              Path.basename(entry["path"]) == "baseline" -> @max_manifest
              true -> @max_ledger_record
            end

          if entry["size"] > ceiling, do: throw({:io_error, :inventory_mismatch})
          {entry["path"], ceiling}
        end)

      captured =
        Enum.reduce(selected, %{}, fn entry, acc ->
          {:ok, bytes} =
            audit_captured_record(
              root,
              entry["path"],
              index,
              ceilings[entry["path"]],
              :restore_history_digest,
              :restore_history_bytes,
              fn bytes -> {:ok, bytes} end
            )

          Map.put(acc, entry["path"], bytes)
        end)

      primitive(:restore_history_decode, fn ->
        RestoreGuard.validate_captured_lineage(plan, entries, captured)
      end)
    else
      _ -> {:error, :history_invalid}
    end
  end

  defp execute({:audit_artifact_use, root, reference, manifest}) do
    # Concept: one retained use is private evidence bound to its current reference.
    # Technical depth: the existing Core facade validates the reference before path
    # selection and closes the captured use after descriptor close. Its synchronous
    # telemetry runs inside the same owned semantic operation and original cutoff.
    # Object bytes, other uses and complete artifact history remain separate proofs.
    with true <-
           primitive(:artifact_reference, fn -> ArtifactStore.valid_reference?(reference) end),
         {:ok, entries} <-
           primitive(:artifact_manifest, fn -> RestoreCodec.manifest(manifest, @max_uint64) end) do
      digest = reference.use_digest
      relative = Path.join(["artifacts", "uses", binary_part(digest, 0, 2), digest])
      index = Map.new(entries, &{&1["path"], &1})

      audit_captured_record(
        root,
        relative,
        index,
        ArtifactStore.max_use_bytes(),
        :artifact_digest,
        :artifact_describe,
        fn bytes ->
          ArtifactStore.describe(
            %{module: Artifacts, handle: {:captured_artifact_use, bytes, digest}},
            reference
          )
        end
      )
    else
      _ -> {:error, :history_invalid}
    end
  end

  defp execute({:audit_artifact_object, root, reference, manifest, max_total}) do
    # Concept: one selected object's bytes bind its existing reference triple.
    # Technical depth: Local fetch selects by locator and verifies requested
    # digest/size; its reader does not equate locator with digest or apply put's
    # 64 MiB cap. The original total-file-byte limit is checked before open.
    with true <-
           primitive(:artifact_reference, fn -> ArtifactStore.valid_reference?(reference) end),
         true <-
           primitive(:artifact_object_locator, fn ->
             byte_size(reference.locator) == 64 and
               Regex.match?(~r/\A[0-9a-f]{64}\z/, reference.locator)
           end),
         {:ok, entries} <-
           primitive(:artifact_manifest, fn -> RestoreCodec.manifest(manifest, max_total) end) do
      relative = Path.join(["artifacts", binary_part(reference.locator, 0, 2), reference.locator])
      index = Map.new(entries, &{&1["path"], &1})
      entry = Map.get(index, relative)

      if not match?(%{"kind" => "regular"}, entry) or entry["size"] != reference.size or
           entry["sha256"] != reference.digest,
         do: throw({:io_error, :inventory_mismatch})

      audit_artifact_object(root, relative, index, entry, reference)
    else
      _ -> {:error, :history_invalid}
    end
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

  # Concept: resolution and lookup use the same owned administrative capture.
  # Technical depth: classification adds only a pure plan/transaction reduction;
  # it neither starts another guardian nor renews this worker's cutoffs.
  defp lookup_operation(root, tx_id, plan) do
    try do
      ancestors = manifest_ancestors(root)
      {:ok, placement} = execute({:placement, root})

      state = %{
        index: %{"." => manifest_directory(".", 0)},
        files: %{},
        placements: %{root => placement},
        identities: %{},
        directories: %{},
        absent: [],
        count: 1
      }

      admin = Path.join(root, ".loopex-restore")
      state = lookup_optional_tree(root, admin, state)

      intents =
        state.files
        |> Enum.filter(fn {path, _} ->
          case Path.split(path) do
            [".loopex-restore", "lineage", _ordinal, name] -> name in ["intent", "intent.tmp"]
            _ -> false
          end
        end)

      ledgers =
        Enum.flat_map(intents, fn {_path, bytes} ->
          case primitive(:lookup_intent_decode, fn -> RestoreCodec.decode(:intent, bytes) end) do
            {:ok, intent} -> Enum.map(intent["generations"], & &1["relative_root"])
            _ -> throw({:lookup_error, "restore_history_invalid"})
          end
        end)
        |> Enum.uniq()

      state =
        Enum.reduce(ledgers, state, fn relative, current ->
          path = Path.join(root, relative)
          manifest_ancestors(path)
          original = manifest_stat(path)

          observed = %{
            "expanded_root" => path,
            "major_device" => file_info(original, :major_device),
            "inode" => file_info(original, :inode)
          }

          info =
            require_value(
              primitive(:lookup_ledger_placement_stat, fn -> :prim_file.read_link_info(path) end)
            )

          if file_info(original, :type) != :directory or
               manifest_identity(info) != manifest_identity(original),
             do: throw({:lookup_error, "physical_destination_changed"})

          current = %{
            current
            | placements: Map.put(current.placements, path, observed),
              identities: Map.put(current.identities, path, original),
              index:
                Map.put(
                  current.index,
                  relative,
                  manifest_directory(relative, Bitwise.band(file_info(info, :mode), 0o7777))
                )
          }

          current = lookup_optional_tree(root, Path.join(path, "restore-lineage"), current)
          lookup_capture(root, Path.join(path, "generation"), 2048, current, false)
        end)

      {:ok, claim_digest} = RestoreCodec.claim_digest(root)
      claim_path = Path.join(Path.dirname(root), ".loopex-restore-claim-" <> claim_digest)
      {claim, state} = lookup_claim(root, claim_path, state)
      lookup_recheck(root, ancestors, state)
      result = if is_nil(plan) do
        primitive(:restore_lookup_decode, fn ->
          Loopex.Executor.Local.RestoreGuard.lookup_captured(root, tx_id, state.index,
            state.files, state.placements, claim)
        end)
      else
        primitive(:restore_classification_decode, fn ->
          Loopex.Executor.Local.RestoreGuard.classify_captured(root, plan, state.index,
            state.files, state.placements, claim)
        end)
      end
      {:ok, result}
    catch
      {:lookup_error, code} -> {:ok, lookup_refusal(tx_id, code)}
      {:io_error, :inventory_limit} -> {:ok, lookup_refusal(tx_id, "inventory_limit_exceeded")}
      {:io_error, _} -> {:ok, lookup_refusal(tx_id, "administrative_path_unavailable")}
    end
  end

  defp lookup_refusal(tx_id, code),
    do:
      {:error,
       %{
         "kind" => "loopex_current_restore_lookup_refusal_v1",
         "tx_id" => tx_id,
         "code" => code,
         "cleanup" => "joined"
       }}

  # Concept: lookup captures only administrative history and selected generations.
  # Technical depth: caps precede open, all descriptors close before reduction,
  # and the original worker rechecks file, directory and ancestor identities.
  defp lookup_optional_tree(root, path, state) do
    case primitive(:lookup_stat, fn -> :prim_file.read_link_info(path) end) do
      {:error, :enoent} -> %{state | absent: [path | state.absent]}
      {:ok, info} -> lookup_tree(root, path, info, state)
      _ -> throw({:lookup_error, "administrative_path_unavailable"})
    end
  end

  defp lookup_tree(root, path, info, state) do
    relative = Path.relative_to(path, root)

    if byte_size(relative) > 8192 or state.count >= @max_entries,
      do: throw({:lookup_error, "inventory_limit_exceeded"})

    mode = Bitwise.band(file_info(info, :mode), 0o7777)

    case file_info(info, :type) do
      :directory when mode == 0o700 ->
        names = require_value(primitive(:lookup_list, fn -> :prim_file.list_dir_all(path) end))
        if length(names) > 64, do: throw({:lookup_error, "inventory_limit_exceeded"})
        names = Enum.map(names, &manifest_name/1) |> Enum.sort()

        state = %{
          state
          | count: state.count + 1,
            index: Map.put(state.index, relative, manifest_directory(relative, mode)),
            identities: Map.put(state.identities, path, info),
            directories: Map.put(state.directories, path, names)
        }

        Enum.reduce(names, state, fn name, current ->
          child = Path.join(path, name)
          lookup_tree(root, child, manifest_stat(child), current)
        end)

      :regular ->
        cap =
          if Path.basename(path) in ["baseline", "baseline.tmp"],
            do: @max_manifest,
            else: @max_ledger_record

        lookup_capture(root, path, cap, state, true)

      _ ->
        throw({:lookup_error, "restore_history_invalid"})
    end
  end

  defp lookup_capture(root, path, cap, state, administrative) do
    before = manifest_stat(path)
    if state.count >= @max_entries, do: throw({:lookup_error, "inventory_limit_exceeded"})

    if file_info(before, :type) != :regular or file_info(before, :links) != 1 or
         (administrative and Bitwise.band(file_info(before, :mode), 0o7777) != 0o600),
       do: throw({:lookup_error, "restore_history_invalid"})

    if file_info(before, :size) > cap,
      do: throw({:lookup_error, "inventory_limit_exceeded"})

    ancestors = manifest_ancestors(Path.dirname(path))
    descriptor = open(path, [:raw, :binary, :read])

    opened =
      require_value(
        primitive(:lookup_descriptor_stat, fn -> :prim_file.read_handle_info(descriptor) end)
      )

    if manifest_identity(opened) != manifest_identity(before),
      do: throw({:lookup_error, "restore_history_invalid"})

    bytes = read_chunks(descriptor, cap, [])
    close(descriptor)

    if byte_size(bytes) != file_info(before, :size) or
         manifest_identity(manifest_stat(path)) != manifest_identity(before),
       do: throw({:lookup_error, "restore_history_invalid"})

    Enum.each(ancestors, fn {ancestor, identity} ->
      if directory_identity(manifest_stat(ancestor)) != identity,
        do: throw({:lookup_error, "physical_destination_changed"})
    end)

    relative = Path.relative_to(path, root)

    entry = %{
      "path" => relative,
      "kind" => "regular",
      "mode" => Bitwise.band(file_info(before, :mode), 0o7777),
      "size" => byte_size(bytes),
      "sha256" => RestoreCodec.digest_bytes(bytes)
    }

    %{
      state
      | count: state.count + 1,
        index: Map.put(state.index, relative, entry),
        files: Map.put(state.files, relative, bytes),
        identities: Map.put(state.identities, path, before)
    }
  end

  defp lookup_claim(root, path, state) do
    case primitive(:lookup_claim_stat, fn -> :prim_file.read_link_info(path) end) do
      {:error, :enoent} ->
        {nil, %{state | absent: [path | state.absent]}}

      {:ok, info} ->
        if file_info(info, :type) != :directory or
             Bitwise.band(file_info(info, :mode), 0o7777) != 0o700,
           do: throw({:lookup_error, "restore_conflict"})

        names =
          require_value(primitive(:lookup_claim_names, fn -> :prim_file.list_dir_all(path) end))
          |> Enum.map(&manifest_name/1)
          |> Enum.sort()

        if file_info(info, :type) != :directory or
             Bitwise.band(file_info(info, :mode), 0o7777) != 0o700 or names != ["owner"],
           do: throw({:lookup_error, "restore_conflict"})

        state = %{
          state
          | identities: Map.put(state.identities, path, info),
            directories: Map.put(state.directories, path, names)
        }

        state = lookup_capture(root, Path.join(path, "owner"), 2048, state, true)
        bytes = Map.fetch!(state.files, Path.relative_to(Path.join(path, "owner"), root))

        case primitive(:lookup_claim_decode, fn -> RestoreCodec.decode(:claim, bytes) end) do
          {:ok, claim} ->
            if claim["state_root"] == root,
              do: {claim, state},
              else: throw({:lookup_error, "restore_conflict"})

          _ ->
            throw({:lookup_error, "restore_conflict"})
        end

      _ ->
        throw({:lookup_error, "restore_conflict"})
    end
  end

  defp lookup_recheck(_root, ancestors, state) do
    Enum.each(ancestors, fn {path, identity} ->
      if directory_identity(manifest_stat(path)) != identity,
        do: throw({:lookup_error, "physical_destination_changed"})
    end)

    Enum.each(state.identities, fn {path, info} ->
      if manifest_identity(manifest_stat(path)) != manifest_identity(info),
        do: throw({:lookup_error, "physical_destination_changed"})
    end)

    Enum.each(state.directories, fn {path, expected} ->
      actual =
        require_value(primitive(:lookup_recheck_names, fn -> :prim_file.list_dir_all(path) end))
        |> Enum.map(&manifest_name/1)
        |> Enum.sort()

      if actual != expected, do: throw({:lookup_error, "restore_history_invalid"})
    end)

    Enum.each(state.absent, fn path ->
      if primitive(:lookup_recheck_absent, fn -> :prim_file.read_link_info(path) end) !=
           {:error, :enoent},
         do: throw({:lookup_error, "restore_history_invalid"})
    end)
  end

  defp resource_role(:manifest), do: {"manifests", @max_resource_manifest}
  defp resource_role(:provenance), do: {"provenance", @max_resource_provenance}

  defp ledger_role(:generation, nil),
    do: {"generation", @max_ledger_generation, "local_executor_generation_v1"}

  defp ledger_role(:admission, job_id),
    do:
      {Path.join("markers", RestoreCodec.digest_bytes(job_id)), @max_ledger_record,
       "local_effect_admission_v1"}

  defp ledger_role(:refusal, job_id),
    do:
      {Path.join("markers", RestoreCodec.digest_bytes(job_id)), @max_ledger_record,
       "local_pre_effect_refusal_v1"}

  defp ledger_role(:open, job_id),
    do:
      {Path.join("open", RestoreCodec.digest_bytes(job_id)), @max_ledger_record,
       "local_open_effect_v1"}

  defp ledger_relations?(record, bytes, declaration, :generation, nil) do
    {:ok, binding} = RestoreCodec.ledger_binding(declaration["source_placement"])

    RestoreCodec.digest_bytes(bytes) == declaration["source_generation_sha256"] and
      record["executor_identity"] == declaration["executor_identity"] and
      record["root_binding"] == binding
  end

  defp ledger_relations?(record, _bytes, declaration, role, job_id),
    do:
      record["job_id"] == job_id and
        (role != :open or record["executor_identity"] == declaration["executor_identity"])

  defp audit_ledger_index(root, declaration, index) do
    relative = declaration["relative_root"]
    ancestors = manifest_ancestors(root)
    claim = Path.join(relative, "claim")
    claim_directories = if Map.has_key?(index, claim), do: [claim], else: []

    selected_directories =
      [relative, Path.join(relative, "markers"), Path.join(relative, "open")] ++ claim_directories

    directories = Enum.flat_map(selected_directories, &audit_directories(root, &1, index))

    namespaces =
      Map.new(
        selected_directories,
        fn directory -> {directory, audit_ledger_names(root, directory, index)} end
      )

    if claim_directories != [] and namespaces[claim] != [],
      do: throw({:io_error, :inventory_mismatch})

    marker_names = namespaces[Path.join(relative, "markers")]
    open_names = namespaces[Path.join(relative, "open")]

    if not Enum.all?(marker_names ++ open_names, &Regex.match?(~r/\A[0-9a-f]{64}\z/, &1)),
      do: throw({:io_error, :unsupported_path})

    require_ok(
      primitive(:ledger_capacity, fn -> Ledger.open_index_capacity(length(open_names)) end)
    )

    members =
      [
        {Path.join(relative, "generation"), @max_ledger_generation}
        | Enum.map(marker_names, &{Path.join([relative, "markers", &1]), @max_ledger_record}) ++
            Enum.map(open_names, &{Path.join([relative, "open", &1]), @max_ledger_record})
      ]

    observed =
      Map.new(members, fn {path, ceiling} ->
        entry = index[path]

        if not match?(%{"kind" => "regular"}, entry) or entry["size"] > ceiling,
          do: throw({:io_error, :inventory_mismatch})

        info = manifest_stat(Path.join(root, path))
        require_audit_file(info, entry)
        {path, manifest_identity(info)}
      end)

    with {:ok, generation} <-
           audit_captured_record(
             root,
             Path.join(relative, "generation"),
             index,
             @max_ledger_generation,
             :ledger_digest,
             :ledger_decode,
             fn bytes ->
               with {:ok, record} <- Ledger.decode_bytes(bytes, "local_executor_generation_v1"),
                    true <- ledger_relations?(record, bytes, declaration, :generation, nil) do
                 {:ok, record}
               else
                 _ -> {:error, :history_invalid}
               end
             end
           ),
         {:ok, markers} <-
           audit_ledger_plane(root, relative, "markers", marker_names, index, declaration),
         {:ok, open_records} <-
           audit_ledger_plane(root, relative, "open", open_names, index, declaration),
         {:ok, snapshot} <-
           primitive(:ledger_snapshot, fn ->
             Ledger.validate_captured_open_index(
               declaration["source_generation_sha256"],
               generation["root_binding"],
               open_records
             )
           end),
         true <- ledger_index_pairs?(markers, open_records) do
      Enum.each(namespaces, fn {directory, names} ->
        if audit_ledger_names(root, directory, index) != names,
          do: throw({:io_error, :source_changed})
      end)

      Enum.each(observed, fn {path, identity} ->
        if manifest_identity(manifest_stat(Path.join(root, path))) != identity,
          do: throw({:io_error, :source_changed})
      end)

      Enum.each(directories, fn {path, identity} ->
        if manifest_identity(manifest_stat(path)) != identity,
          do: throw({:io_error, :source_changed})
      end)

      Enum.each(ancestors, fn {path, identity} ->
        if directory_identity(manifest_stat(path)) != identity,
          do: throw({:io_error, :source_changed})
      end)

      # Presence is evidence only. No owner is inferred, joined or reclaimed.
      {:ok,
       %{
         generation: generation,
         markers: markers,
         open: snapshot,
         claim_present: Map.has_key?(index, Path.join(relative, "claim"))
       }}
    else
      _ -> {:error, :history_invalid}
    end
  end

  defp audit_ledger_names(root, relative, index) do
    raw =
      require_value(
        primitive(:ledger_names, fn ->
          :prim_file.list_dir_all(Path.join(root, relative))
        end)
      )

    if length(raw) > @max_entries, do: throw({:io_error, :inventory_limit})
    names = Enum.sort(Enum.map(raw, &manifest_name/1))

    expected =
      index
      |> Map.keys()
      |> Enum.filter(&(Path.dirname(&1) == relative))
      |> Enum.map(&Path.basename/1)
      |> Enum.sort()

    if names != expected, do: throw({:io_error, :inventory_mismatch})
    names
  end

  defp audit_ledger_plane(root, relative, plane, names, index, declaration) do
    Enum.reduce_while(names, {:ok, []}, fn name, {:ok, records} ->
      result =
        audit_captured_record(
          root,
          Path.join([relative, plane, name]),
          index,
          @max_ledger_record,
          :ledger_digest,
          :ledger_decode,
          fn bytes ->
            decoded =
              if plane == "markers",
                do: Ledger.decode_marker_bytes(bytes),
                else: Ledger.decode_bytes(bytes, "local_open_effect_v1")

            with {:ok, record} <- decoded,
                 true <- RestoreCodec.digest_bytes(record["job_id"]) == name,
                 true <-
                   plane != "open" or
                     record["executor_identity"] == declaration["executor_identity"] do
              {:ok, record}
            else
              _ -> {:error, :history_invalid}
            end
          end
        )

      case result do
        {:ok, record} -> {:cont, {:ok, [{name, record} | records]}}
        _ -> {:halt, {:error, :history_invalid}}
      end
    end)
    |> case do
      {:ok, records} -> {:ok, Enum.reverse(records)}
      error -> error
    end
  end

  defp ledger_index_pairs?(markers, open) do
    markers = Map.new(markers)

    Enum.all?(open, fn {name, record} ->
      case markers[name] do
        %{ledger_kind: "local_effect_admission_v1"} = marker ->
          Enum.all?(
            ~w(job_id canonical_request_digest cleanup_grace_ms),
            &(marker[&1] == record[&1])
          )

        _ ->
          true
      end
    end)
  end

  # Concept: Resource, ledger and artifact-use audits share one owned physical capture.
  # Technical depth: exact inventory membership and role size precede open;
  # decoding follows explicit close, then file and ancestor identities are checked.
  defp audit_captured_record(root, relative, index, ceiling, digest_kind, decode_kind, decode) do
    entry = Map.get(index, relative)

    if not match?(%{"kind" => "regular"}, entry) or entry["size"] > ceiling,
      do: throw({:io_error, :inventory_mismatch})

    ancestors = manifest_ancestors(root)
    directories = audit_directories(root, Path.dirname(relative), index)
    path = Path.join(root, relative)
    before = manifest_stat(path)
    require_audit_file(before, entry)
    descriptor = open(path, [:raw, :binary, :read])

    opened =
      require_value(
        primitive(:descriptor_stat, fn -> :prim_file.read_handle_info(descriptor) end)
      )

    require_same_identity(before, opened)

    {bytes, context} =
      read_captured_chunks(descriptor, entry["size"], [], :crypto.hash_init(:sha256))

    after_read =
      require_value(
        primitive(:descriptor_stat, fn -> :prim_file.read_handle_info(descriptor) end)
      )

    require_same_identity(before, after_read)
    require_same_identity(before, manifest_stat(path))
    close(descriptor)

    digest =
      primitive(digest_kind, fn ->
        :crypto.hash_final(context) |> Base.encode16(case: :lower)
      end)

    if byte_size(bytes) != entry["size"] or digest != entry["sha256"],
      do: throw({:io_error, :inventory_mismatch})

    result =
      case primitive(decode_kind, fn -> decode.(bytes) end) do
        {:ok, record} -> {:ok, record}
        _ -> {:error, :history_invalid}
      end

    require_same_identity(before, manifest_stat(path))

    Enum.each(directories, fn {directory, observed} ->
      if manifest_identity(manifest_stat(directory)) != observed,
        do: throw({:io_error, :source_changed})
    end)

    Enum.each(ancestors, fn {ancestor, observed} ->
      if directory_identity(manifest_stat(ancestor)) != observed,
        do: throw({:io_error, :source_changed})
    end)

    result
  end

  # Concept: object verification streams bytes without materializing a payload.
  # Technical depth: the existing manifest hash owns each bounded raw read and
  # exact EOF witness. Shared identity guards surround the same explicit close;
  # only the private reference triple is returned after physical revalidation.
  defp audit_artifact_object(root, relative, index, entry, reference) do
    ancestors = manifest_ancestors(root)
    directories = audit_directories(root, Path.dirname(relative), index)
    path = Path.join(root, relative)
    before = manifest_stat(path)
    require_audit_file(before, entry)
    descriptor = open(path, [:raw, :binary, :read])

    opened =
      require_value(
        primitive(:descriptor_stat, fn -> :prim_file.read_handle_info(descriptor) end)
      )

    require_same_identity(before, opened)
    digest = manifest_hash(descriptor, entry["size"], :crypto.hash_init(:sha256))

    after_read =
      require_value(
        primitive(:descriptor_stat, fn -> :prim_file.read_handle_info(descriptor) end)
      )

    require_same_identity(before, after_read)
    require_same_identity(before, manifest_stat(path))
    close(descriptor)

    matched =
      primitive(:artifact_object_digest, fn ->
        digest == reference.digest and digest == entry["sha256"]
      end)

    if not matched, do: throw({:io_error, :inventory_mismatch})
    require_same_identity(before, manifest_stat(path))

    Enum.each(directories, fn {directory, observed} ->
      if manifest_identity(manifest_stat(directory)) != observed,
        do: throw({:io_error, :source_changed})
    end)

    Enum.each(ancestors, fn {ancestor, observed} ->
      if directory_identity(manifest_stat(ancestor)) != observed,
        do: throw({:io_error, :source_changed})
    end)

    {:ok, Map.take(reference, [:digest, :size, :locator])}
  end

  defp audit_store_bytes(bytes) do
    with {:ok, frames, :complete} <- primitive(:store_decode, fn -> Log.decode_bytes(bytes) end),
         {:ok, store} <- primitive(:store_replay, fn -> State.replay(frames) end) do
      store.sessions
      |> Enum.sort_by(fn {session_id, _session} -> session_id end)
      |> Enum.reduce_while({:ok, %{}}, fn {session_id, session}, {:ok, recovered} ->
        case primitive(:session_recover, fn ->
               SessionState.recover(session_id, session.records, session.events)
             end) do
          {:ok, facts} -> {:cont, {:ok, Map.put(recovered, session_id, facts)}}
          _ -> {:halt, {:error, :history_invalid}}
        end
      end)
      |> case do
        {:ok, sessions} -> {:ok, %{store: store, sessions: sessions}}
        error -> error
      end
    else
      _ -> {:error, :history_invalid}
    end
  end

  defp audit_directories(root, relative, index) do
    entry = Map.get(index, relative)
    path = if relative == ".", do: root, else: Path.join(root, relative)
    info = manifest_stat(path)

    if not match?(%{"kind" => "directory"}, entry) or
         file_info(info, :type) != :directory or
         Bitwise.band(file_info(info, :mode), 0o7777) != entry["mode"],
       do: throw({:io_error, :inventory_mismatch})

    own = {path, manifest_identity(info)}

    if relative == ".",
      do: [own],
      else: [own | audit_directories(root, Path.dirname(relative), index)]
  end

  defp copy_chunks(input, output, remaining, context) do
    case primitive(:copy_read, fn -> :prim_file.read(input, min(@chunk, remaining + 1)) end) do
      :eof when remaining == 0 ->
        :crypto.hash_final(context) |> Base.encode16(case: :lower)

      {:ok, bytes} when byte_size(bytes) > 0 and byte_size(bytes) <= remaining ->
        write(output, bytes)

        copy_chunks(
          input,
          output,
          remaining - byte_size(bytes),
          :crypto.hash_update(context, bytes)
        )

      _ ->
        throw({:io_error, :source_changed})
    end
  end

  defp require_audit_file(info, entry) do
    if file_info(info, :type) != :regular or file_info(info, :links) != 1 or
         file_info(info, :size) != entry["size"] or
         Bitwise.band(file_info(info, :mode), 0o7777) != entry["mode"],
       do: throw({:io_error, :inventory_mismatch})
  end

  defp require_same_identity(before, after_info) do
    if manifest_identity(before) != manifest_identity(after_info),
      do: throw({:io_error, :source_changed})
  end

  defp manifest_ancestors(path) do
    info = manifest_stat(path)
    if file_info(info, :type) != :directory, do: throw({:io_error, :not_directory})
    parent = Path.dirname(path)
    own = {path, directory_identity(info)}
    if parent == path, do: [own], else: [own | manifest_ancestors(parent)]
  end

  defp require_source_absent(root) do
    case primitive(:source_absence, fn -> :prim_file.read_link_info(root) end) do
      {:error, :enoent} -> :ok
      _ -> throw({:io_error, :source_not_absent})
    end
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

  defp read_captured_chunks(descriptor, remaining, chunks, context) do
    case primitive(:read, fn -> :prim_file.read(descriptor, min(@chunk, remaining + 1)) end) do
      :eof ->
        {chunks |> Enum.reverse() |> IO.iodata_to_binary(), context}

      {:ok, bytes} when byte_size(bytes) > 0 and byte_size(bytes) <= remaining ->
        read_captured_chunks(
          descriptor,
          remaining - byte_size(bytes),
          [bytes | chunks],
          :crypto.hash_update(context, bytes)
        )

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
              {{:restore_claim_create, _}, :ok} -> :created
              {{:restore_claim_create, _}, {:error, :eexist}} -> :foreign
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

  defp valid_operation?({:restore_lookup, root, tx_id}),
    do: valid_path?(root) and is_binary(tx_id) and Regex.match?(~r/\A[0-9a-f]{64}\z/, tx_id)

  defp valid_operation?({:restore_first, plan, invocation}),
    do:
      match?({:ok, _}, RestoreCodec.encode(:plan, plan)) and
        match?({:ok, _}, RestoreCodec.encode(:invocation, invocation)) and
        invocation["prior_admin_authority"] == "none"

  defp valid_operation?({:audit_restore_lineage, root, plan, manifest}),
    do:
      valid_path?(root) and is_map(plan) and is_binary(manifest) and
        byte_size(manifest) <= @max_manifest

  defp valid_operation?({:audit_store, root, declaration, manifest}),
    do:
      valid_path?(root) and is_map(declaration) and is_binary(manifest) and
        byte_size(manifest) <= @max_manifest

  defp valid_operation?({:audit_resource, root, kind, identity, manifest}),
    do:
      valid_path?(root) and kind in [:manifest, :provenance] and is_binary(identity) and
        byte_size(identity) == 64 and Regex.match?(~r/\A[0-9a-f]{64}\z/, identity) and
        is_binary(manifest) and byte_size(manifest) <= @max_manifest

  defp valid_operation?({:audit_ledger, root, declaration, role, job_id, manifest}),
    do:
      valid_path?(root) and is_map(declaration) and
        ((role == :generation and is_nil(job_id)) or
           (role in [:admission, :refusal, :open] and is_binary(job_id) and
              byte_size(job_id) in 1..8192)) and
        is_binary(manifest) and byte_size(manifest) <= @max_manifest

  defp valid_operation?({:audit_ledger_index, root, declaration, manifest}),
    do:
      valid_path?(root) and is_map(declaration) and
        is_binary(manifest) and byte_size(manifest) <= @max_manifest

  defp valid_operation?({:audit_artifact_use, root, reference, manifest}),
    do:
      valid_path?(root) and is_map(reference) and is_binary(manifest) and
        byte_size(manifest) <= @max_manifest

  defp valid_operation?({:audit_artifact_object, root, reference, manifest, max_total}),
    do:
      valid_path?(root) and is_map(reference) and is_binary(manifest) and
        byte_size(manifest) <= @max_manifest and is_integer(max_total) and
        max_total in 0..@max_uint64

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
