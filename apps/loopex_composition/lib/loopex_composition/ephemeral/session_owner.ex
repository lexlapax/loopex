defmodule LoopexComposition.Ephemeral.SessionOwner do
  @moduledoc """
  ## Concept

  Holds one ephemeral session's lifecycle, but does no session work before its
  creator completes owner activation and supplies a one-use begin token. After
  begin it grants each startup step and returns no subtree before exact commit.

  ## Technical depth

  The temporary supervisor child receives only process identities, a reference
  and an expiry. It monitors the creator, proxy and supervisor, and treats proxy
  loss as authorized only after the exact retirement notice and normal DOWN.
  The two-slot atomics cell is private to this owner until the begin handshake.
  A single absolute startup deadline covers the root candidate, child
  registration, runtime and subtree commit. A returned process is monitored
  before the root receives its acknowledgement.
  """

  use GenServer

  alias Loopex.Runtime
  alias Loopex.Store
  alias Loopex.Trace.Capability.Handle, as: TraceHandle
  alias Loopex.Attachment
  alias Loopex.ResourcePack
  alias LoopexComposition.SessionAdmission
  alias LoopexComposition.Ephemeral.{FacadeClient, SessionRoot, TempRoot}

  @startup_ms 5_000
  @startup_wait_ms 16_000
  @phase_order [
    :candidate_prepare,
    :root_claim,
    :private_supervisor,
    :memory_store,
    :store_handle,
    :workspace_lease,
    :executor,
    :trace_capability,
    :trace_handle,
    :runtime_holder,
    :runtime,
    :trace_bind
  ]
  @coding ~w(loopex.read loopex.write loopex.edit loopex.bash)
  @read_only ~w(loopex.read loopex.grep loopex.find loopex.ls)

  @doc false
  def start_link(creator, proxy, ref, expiry) do
    GenServer.start_link(__MODULE__, {creator, proxy, ref, expiry})
  end

  @doc false
  @spec start_session(pid(), map(), pos_integer()) ::
          {:ok, :session_ready} | {:error, term()}
  def start_session(owner, configuration, timeout_ms)
      when is_pid(owner) and is_map(configuration) and is_integer(timeout_ms) and timeout_ms > 0 do
    reference = make_ref()
    monitor = Process.monitor(owner)
    send(owner, {self(), reference, :start_session, configuration})

    receive do
      {^owner, ^reference, result} ->
        Process.demonitor(monitor, [:flush])
        result

      {:DOWN, ^monitor, :process, ^owner, _reason} ->
        {:error, :session_unavailable}
    after
      max(timeout_ms, @startup_wait_ms) ->
        send(owner, {self(), reference, :cancel_start})
        Process.demonitor(monitor, [:flush])
        {:error, :session_unavailable}
    end
  end

  def start_session(_owner, _configuration, _timeout_ms),
    do: {:error, :session_unavailable}

  @impl true
  def init({creator, proxy, ref, expiry}) do
    Process.flag(:sensitive, true)
    Process.flag(:trap_exit, true)
    supervisor = supervisor_from_ancestry()

    if is_pid(supervisor) and fresh?(expiry) and
         Enum.all?([creator, proxy, supervisor], &Process.alive?/1) do
      monitors = %{
        creator: Process.monitor(creator),
        proxy: Process.monitor(proxy),
        supervisor: Process.monitor(supervisor)
      }

      cell = :atomics.new(2, signed: false)
      identity = make_ref()
      send(creator, {self(), ref, :owner_candidate, identity})
      Process.send_after(self(), {:activation_expired, ref}, remaining(expiry))

      {:ok,
       %{
         creator: creator,
         proxy: proxy,
         supervisor: supervisor,
         ref: ref,
         expiry: expiry,
         monitors: monitors,
         cell: cell,
         cleanup_grace_ms: Loopex.Executor.default_cleanup_grace_ms(),
         identity: identity,
         retiring: false,
         phase: :blocked,
         token: nil,
         startup_deadline: nil,
         startup: nil,
         abort: nil
       }}
    else
      {:stop, :expired_owner_start}
    end
  end

  @impl true
  def handle_info(
        {creator, ref, :identify, identity, challenge},
        %{creator: creator, ref: ref, identity: identity, phase: :blocked} = state
      )
      when is_reference(challenge) do
    send(creator, {self(), ref, :candidate_identity, challenge})
    {:noreply, state}
  end

  def handle_info(
        {proxy, ref, :proxy_retiring},
        %{proxy: proxy, ref: ref, phase: :blocked} = state
      ) do
    {:noreply, %{state | retiring: true}}
  end

  def handle_info(
        {:DOWN, monitor, :process, proxy, :normal},
        %{proxy: proxy, monitors: %{proxy: monitor}, retiring: true, phase: :blocked} = state
      ) do
    {:noreply, %{state | phase: :ready}}
  end

  def handle_info(
        {creator, ref, :prepare, token},
        %{creator: creator, ref: ref, phase: :ready} = state
      )
      when is_reference(token) do
    if fresh?(state.expiry) do
      send(creator, {self(), ref, :prepared})
      {:noreply, %{state | phase: :prepared, token: token}}
    else
      {:stop, :expired_owner_start, state}
    end
  end

  def handle_info(
        {creator, ref, :begin, token, reply_ref},
        %{creator: creator, ref: ref, phase: :prepared, token: token} = state
      )
      when is_reference(reply_ref) do
    if fresh?(state.expiry) do
      send(creator, {self(), reply_ref, :begun, state.cell})
      deadline = System.monotonic_time() + native(@startup_ms)
      Process.send_after(self(), {:startup_deadline, ref}, @startup_ms)
      {:noreply, %{state | phase: :begun, token: nil, startup_deadline: deadline}}
    else
      {:stop, :expired_owner_start, state}
    end
  end

  def handle_info({:activation_expired, ref}, %{ref: ref, phase: phase} = state)
      when phase in [:blocked, :ready, :prepared] do
    if fresh?(state.expiry),
      do: {:noreply, state},
      else: {:stop, :normal, state}
  end

  def handle_info(
        {creator, request, :start_session, configuration},
        %{creator: creator, phase: :begun, startup: nil} = state
      )
      when is_reference(request) and is_map(configuration) do
    if fresh?(state.startup_deadline) do
      start_subtree(state, request, configuration)
    else
      send(creator, {self(), request, {:error, :session_unavailable}})
      {:noreply, close_proved(state)}
    end
  end

  def handle_info(
        {creator, request, :cancel_start},
        %{creator: creator, startup: %{request: request}, phase: :starting} = state
      ) do
    {:noreply, fail_start(state, :session_unavailable, :unknown)}
  end

  def handle_info({:startup_deadline, ref}, %{ref: ref, phase: :begun} = state) do
    if fresh?(state.startup_deadline) do
      {:noreply, state}
    else
      {:noreply, close_proved(state)}
    end
  end

  def handle_info({:startup_deadline, ref}, %{ref: ref, phase: :starting} = state) do
    if fresh?(state.startup_deadline),
      do: {:noreply, state},
      else: {:noreply, fail_start(state, timeout_cause(state.startup), :unknown)}
  end

  def handle_info(
        {:root_ready, root, reference},
        %{startup: %{root: root, reference: reference} = startup, phase: :starting} = state
      ) do
    {:noreply, %{state | startup: %{startup | root_ready: true}} |> maybe_grant()}
  end

  def handle_info(
        {:phase_ready, sender, reference, phase},
        %{startup: %{reference: reference, expected: phase} = startup, phase: :starting} = state
      ) do
    if sender == expected_sender(startup, phase) and not startup.granted do
      {:noreply, %{state | startup: %{startup | ready: true}} |> maybe_grant()}
    else
      {:noreply, state}
    end
  end

  # RuntimeHolder and SessionRoot have different senders. The latter may send
  # trace_bind ready before the owner's runtime-result message is processed.
  def handle_info(
        {:phase_ready, root, reference, :trace_bind},
        %{
          startup: %{root: root, reference: reference, expected: :runtime} = startup,
          phase: :starting
        } = state
      ) do
    {:noreply, %{state | startup: %{startup | early_trace_bind: true}}}
  end

  def handle_info(
        {:phase_result, sender, reference, phase, result},
        %{
          startup: %{reference: reference, expected: phase, granted: true} = startup,
          phase: :starting
        } = state
      ) do
    if sender == expected_sender(startup, phase) do
      # The exact return ends this grant, including a returned failure. A
      # later rollback must not classify it as an unknown child start.
      state = %{state | startup: %{startup | granted: false}}
      {:noreply, accept_phase_result(state, phase, result)}
    else
      {:noreply, state}
    end
  end

  def handle_info(
        {:subtree_prepared, root, reference, prepared},
        %{
          startup: %{root: root, reference: reference, expected: :prepared} = startup,
          phase: :starting
        } = state
      ) do
    if prepared_matches?(startup, prepared) and live_subtree?(startup) and
         fresh?(startup.deadline) do
      send(root, {:commit, self(), reference})
      {:noreply, %{state | startup: %{startup | expected: :committed, prepared: prepared}}}
    else
      {:noreply, fail_start(state, :dependency_start_failed, :unknown)}
    end
  end

  def handle_info(
        {:DOWN, monitor, :process, pid, reason},
        %{phase: :aborting, startup: startup, abort: abort} = state
      ) do
    cond do
      abort.worker && abort.worker.pid == pid && abort.worker.monitor == monitor ->
        {:noreply, finish_abort_worker(state, reason)}

      Map.get(startup.process_monitors, pid) == monitor ->
        next = %{state | abort: %{abort | down: MapSet.put(abort.down, pid)}}
        {:noreply, continue_abort(next)}

      true ->
        {:noreply, state}
    end
  end

  def handle_info(
        {:abort_deadline, reference},
        %{phase: :aborting, startup: %{reference: reference}} = state
      ) do
    if fresh?(state.abort.deadline) do
      {:noreply, state}
    else
      if state.abort.worker, do: Process.exit(state.abort.worker.pid, :kill)
      {:noreply, state |> mark_abort_timeout() |> finish_abort()}
    end
  end

  def handle_info(
        {:abort_facade_deadline, reference},
        %{phase: :aborting, startup: %{reference: reference}, abort: %{stage: :facade_reap}} =
          state
      ) do
    {:noreply, state |> mark_abort_timeout() |> finish_abort()}
  end

  def handle_info(
        {:abort_operation_cutoff, reference},
        %{phase: :aborting, abort: %{worker: %{reference: reference} = worker}} = state
      ) do
    if not worker.finish_sent, do: Process.exit(worker.pid, :kill)
    {:noreply, state}
  end

  def handle_info(
        {:abort_slot_deadline, reference},
        %{phase: :aborting, abort: %{worker: %{reference: reference} = worker}} = state
      ) do
    Process.exit(worker.pid, :kill)
    {:noreply, state |> mark_abort_timeout() |> finish_abort()}
  end

  def handle_info(
        {worker_pid, reference, phase, :result, result, completed_at},
        %{
          phase: :aborting,
          abort:
            %{worker: %{pid: worker_pid, reference: reference, phase: phase} = worker} = abort
        } = state
      ) do
    valid = completed_at <= worker.cutoff and valid_abort_result?(phase, result, worker.nonce)
    updated = %{worker | result: valid}
    next = %{state | abort: %{abort | worker: updated}}

    if valid,
      do: {:noreply, maybe_finish_abort_worker(next)},
      else:
        (
          Process.exit(worker_pid, :kill)
          {:noreply, next}
        )
  end

  def handle_info(
        {executor, instance, nonce, :groups_empty},
        %{
          phase: :aborting,
          startup: %{executor_instance: instance, registered: %{executor: executor}},
          abort: %{worker: %{phase: :process_groups, nonce: nonce} = worker} = abort
        } = state
      ) do
    next = %{state | abort: %{abort | worker: %{worker | certificate: true}}}
    {:noreply, maybe_finish_abort_worker(next)}
  end

  def handle_info(
        {:subtree_committed, root, reference},
        %{
          startup: %{root: root, reference: reference, expected: :committed} = startup,
          phase: :starting
        } = state
      ) do
    if fresh?(startup.deadline) and live_subtree?(startup) do
      {:noreply, start_facade(state)}
    else
      {:noreply, fail_start(state, :dependency_start_failed, :unknown)}
    end
  end

  def handle_info(
        {client, reference, :ready},
        %{
          phase: :starting,
          startup:
            %{facade: %{pid: client, reference: reference, stage: :await_ready} = facade} =
              startup
        } = state
      ) do
    if fresh?(startup.deadline) and fresh?(facade.handshake_deadline) do
      operation_deadline = System.monotonic_time() + native(5_000)
      send(client, {self(), reference, :dispatch, operation_deadline})
      next_facade = %{facade | stage: :dispatched, operation_deadline: operation_deadline}
      {:noreply, %{state | startup: %{startup | facade: next_facade}}}
    else
      {:noreply, cancel_facade(state)}
    end
  end

  def handle_info(
        {client, reference, :cancelled},
        %{
          phase: :starting,
          startup: %{facade: %{pid: client, reference: reference, stage: :cancelling} = facade}
        } = state
      ) do
    {:noreply, fail_start(state, facade_failure(facade.operation), :known)}
  end

  def handle_info(
        {client, reference, result},
        %{
          phase: :starting,
          startup: %{facade: %{pid: client, reference: reference, stage: :dispatched}}
        } = state
      ) do
    {:noreply, accept_facade_result(state, result)}
  end

  def handle_info(
        {:facade_handshake_deadline, reference},
        %{
          phase: :starting,
          startup: %{facade: %{reference: reference, stage: :await_ready} = facade}
        } = state
      ) do
    if fresh?(facade.handshake_deadline),
      do: {:noreply, state},
      else: {:noreply, cancel_facade(state)}
  end

  def handle_info(
        {:facade_cancel_deadline, reference},
        %{
          phase: :starting,
          startup: %{facade: %{reference: reference, stage: :cancelling} = facade}
        } = state
      ) do
    {:noreply, fail_start(state, facade_failure(facade.operation), :known)}
  end

  def handle_info(
        {:DOWN, monitor, :process, root, _reason},
        %{phase: :starting, startup: %{root: root, process_monitors: monitors}} = state
      ) do
    if Map.get(monitors, root) == monitor do
      failed = fail_start(state, :dependency_start_failed, :unknown)
      abort = %{failed.abort | down: MapSet.put(failed.abort.down, root)}
      {:noreply, continue_abort(%{failed | abort: abort})}
    else
      {:noreply, state}
    end
  end

  def handle_info(
        {:DOWN, monitor, :process, pid, _reason},
        %{phase: :ready, startup: startup} = state
      ) do
    cond do
      {monitor, pid} == {state.monitors.creator, state.creator} ->
        {:noreply, fail_start(state, :session_unavailable, :known)}

      {monitor, pid} in [
        {state.monitors.proxy, state.proxy},
        {state.monitors.supervisor, state.supervisor}
      ] ->
        {:stop, :normal, state}

      Map.get(startup.process_monitors, pid) == monitor ->
        failed = fail_start(state, :dependency_start_failed, :unknown)
        abort = %{failed.abort | down: MapSet.put(failed.abort.down, pid)}
        {:noreply, continue_abort(%{failed | abort: abort})}

      true ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, monitor, :process, pid, _reason}, state) do
    cond do
      state.phase == :starting and
          {monitor, pid} ==
            {state.monitors.creator, state.creator} ->
        {:noreply, fail_start(state, :session_unavailable, :known)}

      {monitor, pid} in [
        {state.monitors.creator, state.creator},
        {state.monitors.proxy, state.proxy},
        {state.monitors.supervisor, state.supervisor}
      ] ->
        {:stop, :normal, state}

      state.phase == :starting and
          Map.get(state.startup.process_monitors, pid) == monitor ->
        failed = fail_start(state, :dependency_start_failed, :unknown)
        abort = %{failed.abort | down: MapSet.put(failed.abort.down, pid)}
        {:noreply, continue_abort(%{failed | abort: abort})}

      true ->
        {:noreply, state}
    end
  end

  def handle_info({:EXIT, supervisor, _reason}, %{supervisor: supervisor} = state),
    do: {:stop, :normal, state}

  def handle_info(:retire_sealed, %{phase: :sealed} = state), do: {:stop, :normal, state}

  def handle_info(_message, state), do: {:noreply, state}

  defp start_subtree(state, request, configuration) do
    reference = make_ref()
    seams = test_seams(configuration)

    case SessionRoot.start_link(self(), reference, state.startup_deadline, configuration, seams) do
      {:ok, root} ->
        monitor = Process.monitor(root)

        startup = %{
          request: request,
          replied: false,
          owner: self(),
          reference: reference,
          deadline: state.startup_deadline,
          configuration: configuration,
          root: root,
          root_ready: false,
          expected: :candidate_prepare,
          ready: false,
          granted: false,
          early_trace_bind: false,
          candidate: nil,
          owned_root: nil,
          registered: %{},
          process_monitors: %{root => monitor},
          prepared: nil,
          generation: make_ref(),
          executor_instance: make_ref(),
          facade: nil,
          session_id: nil,
          attachment: nil,
          skill_index: 0,
          manifest_digest: nil,
          owner_epoch: nil
        }

        {:noreply, %{state | phase: :starting, startup: startup}}

      _failure ->
        send(state.creator, {self(), request, {:error, {:composition, :dependency_start_failed}}})
        {:noreply, close_proved(state)}
    end
  end

  defp start_facade(state) do
    startup = state.startup

    case ResourcePack.digest(startup.configuration.skills.manifest) do
      {:ok, digest, %{"packs" => packs}} when is_list(packs) ->
        try do
          {client, monitor} =
            FacadeClient.start(
              self(),
              startup.registered.runtime,
              test_facade(startup.configuration)
            )

          process_monitors = Map.put(startup.process_monitors, client, monitor)

          state = %{
            state
            | startup: %{
                startup
                | manifest_digest: digest,
                  process_monitors: process_monitors,
                  registered: Map.put(startup.registered, :facade_client, client)
              }
          }

          start_facade_operation(state, :create)
        catch
          _, _ -> fail_start(state, :client_start_failed, :known)
        end

      _ ->
        fail_start(state, :resource_admission_failed, :known)
    end
  end

  defp start_facade_operation(state, operation) do
    startup = state.startup
    client = Map.fetch!(startup.registered, :facade_client)
    reference = make_ref()
    handshake_deadline = min(System.monotonic_time() + native(1_000), startup.deadline)
    send(client, {self(), reference, operation})

    Process.send_after(
      self(),
      {:facade_handshake_deadline, reference},
      remaining(handshake_deadline)
    )

    facade = %{
      pid: client,
      reference: reference,
      operation: operation,
      stage: :await_ready,
      handshake_deadline: handshake_deadline,
      operation_deadline: nil
    }

    %{state | startup: %{startup | facade: facade}}
  end

  defp cancel_facade(state) do
    startup = state.startup
    facade = startup.facade
    send(facade.pid, {self(), facade.reference, :cancel})

    Process.send_after(
      self(),
      {:facade_cancel_deadline, facade.reference},
      min(1_000, remaining(startup.deadline))
    )

    %{state | startup: %{startup | facade: %{facade | stage: :cancelling}}}
  end

  defp accept_facade_result(state, result) do
    startup = state.startup

    if fresh?(startup.deadline) do
      case facade_transition(state, startup.facade.operation, result) do
        {:next, next_state, operation} ->
          start_facade_operation(next_state, operation)

        {:ready, ready_state} ->
          send(state.creator, {self(), startup.request, {:ok, :session_ready}})
          %{ready_state | phase: :ready, startup: %{ready_state.startup | replied: true}}

        {:error, cause} ->
          fail_start(state, cause, :known)
      end
    else
      fail_start(state, facade_failure(startup.facade.operation), :known)
    end
  end

  defp facade_transition(state, :create, {:ok, session_id})
       when is_binary(session_id) and byte_size(session_id) in 1..256 do
    if String.valid?(session_id) do
      {:next, put_in(state.startup.session_id, session_id), :attach}
    else
      {:error, :session_create_failed}
    end
  end

  defp facade_transition(state, :attach, {:ok, %Attachment{session_id: session_id} = attachment}) do
    if session_id == state.startup.session_id and
         attachment.runtime == state.startup.registered.runtime and
         is_binary(attachment.attachment_id) and
         is_binary(attachment.incarnation_id) and is_map(attachment.snapshot) do
      state = put_in(state.startup.attachment, attachment)
      packs = state.startup.configuration.skills.manifest["packs"]

      if packs == [],
        do: {:next, state, :session_status},
        else: {:next, state, {:command, admit_command(state)}}
    else
      {:error, :attach_failed}
    end
  end

  defp facade_transition(
         state,
         {:command, %{type: :admit_resources, command_id: id}},
         {:accepted, id}
       ) do
    {:next, state, :resource_catalog}
  end

  defp facade_transition(state, :resource_catalog, {:ok, catalog}) do
    if catalog_matches?(state.startup, catalog) do
      {:next, state, {:command, activation_command(state, 0)}}
    else
      {:error, :resource_admission_failed}
    end
  end

  defp facade_transition(
         state,
         {:command, %{type: :activate_skill, command_id: id}},
         {:accepted, id}
       ) do
    next_index = state.startup.skill_index + 1
    state = put_in(state.startup.skill_index, next_index)
    packs = state.startup.configuration.skills.manifest["packs"]

    if next_index == length(packs),
      do: {:next, state, :session_status},
      else: {:next, state, {:command, activation_command(state, next_index)}}
  end

  defp facade_transition(state, :session_status, {:ok, status}) when is_map(status) do
    owner_epoch = Map.get(status, :owner_epoch)

    if Map.get(status, :status) == :active and is_integer(owner_epoch) and
         owner_epoch >= 0 and Map.has_key?(status, :active_run_id) and
         Map.get(status, :active_run_id) == nil and
         Map.get(status, :pending_work_ids) == [] do
      {:ready, put_in(state.startup.owner_epoch, owner_epoch)}
    else
      {:error, :attach_failed}
    end
  end

  defp facade_transition(_state, operation, _result), do: {:error, facade_failure(operation)}

  defp admit_command(state) do
    manifest = state.startup.configuration.skills.manifest
    digest = state.startup.manifest_digest
    issued_at = issued_at(state.startup.configuration)

    %{
      type: :admit_resources,
      command_id: fresh_command_id("admit-resources"),
      manifest_digest: digest,
      decision: %{
        manifest_digest: digest,
        workspace_ref: manifest["workspace_ref"],
        trust_scope: "project_skills",
        decision_source: "host_supplied",
        issued_at: issued_at,
        expires_at: nil,
        revocation_state: "active"
      }
    }
  end

  defp activation_command(state, index) do
    pack = state.startup.configuration.skills.manifest["packs"] |> Enum.at(index)

    %{
      type: :activate_skill,
      command_id: fresh_command_id("activate-skill-#{index + 1}"),
      manifest_digest: state.startup.manifest_digest,
      source_id: pack["source_id"],
      name: pack["name"],
      pack_digest: ResourcePack.pack_digest(pack),
      supporting_labels: []
    }
  end

  defp catalog_matches?(startup, %{
         "configured_manifest_digest" => configured,
         "admitted_manifest_digest" => admitted,
         "decision_disposition" => "active",
         "entries" => entries
       })
       when is_list(entries) do
    digest = startup.manifest_digest
    packs = startup.configuration.skills.manifest["packs"]
    expected = Enum.map(packs, &{&1["source_id"], &1["name"], ResourcePack.pack_digest(&1)})
    actual = Enum.map(entries, &catalog_tuple/1)

    configured == digest and admitted == digest and length(actual) == length(expected) and
      Enum.sort(actual) == Enum.sort(expected)
  end

  defp catalog_matches?(_startup, _catalog), do: false

  defp catalog_tuple(%{"source_id" => source, "name" => name, "pack_digest" => digest})
       when is_binary(source) and is_binary(name) and is_binary(digest),
       do: {source, name, digest}

  defp catalog_tuple(_entry), do: :invalid

  defp fresh_command_id(prefix),
    do: prefix <> "-" <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)

  defp facade_failure(:create), do: :session_create_failed
  defp facade_failure(:attach), do: :attach_failed
  defp facade_failure(:session_status), do: :attach_failed
  defp facade_failure(:resource_catalog), do: :resource_admission_failed
  defp facade_failure({:command, %{type: :admit_resources}}), do: :resource_admission_failed
  defp facade_failure({:command, %{type: :activate_skill}}), do: :skill_activation_failed

  if Mix.env() == :test do
    defp test_facade(configuration), do: Map.get(configuration, :test_facade, Loopex)

    defp issued_at(configuration) do
      now = Map.get(configuration, :test_now, fn -> DateTime.utc_now() end).()
      now |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    end
  else
    defp test_facade(_configuration), do: Loopex

    defp issued_at(_configuration),
      do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
  end

  defp maybe_grant(%{phase: :starting, startup: startup} = state) do
    if startup.ready and startup.root_ready and not startup.granted and
         fresh?(startup.deadline) do
      phase = startup.expected
      sender = expected_sender(startup, phase)
      send(sender, {:grant, self(), startup.reference, phase, phase_payload(state, phase)})
      %{state | startup: %{startup | ready: false, granted: true}}
    else
      state
    end
  end

  defp maybe_grant(state), do: state

  defp accept_phase_result(
         state,
         :candidate_prepare,
         {:ok, %{path: path, nonce: nonce} = candidate}
       )
       when is_binary(path) and is_binary(nonce) and byte_size(nonce) == 32 do
    advance(state, :root_claim, %{candidate: candidate})
  end

  defp accept_phase_result(state, :root_claim, {:error, :collision}),
    do: advance(state, :candidate_prepare, %{candidate: nil})

  defp accept_phase_result(
         state,
         :root_claim,
         {:error, {:claim_unproved, %{candidate: candidate, ownership: ownership} = claim}}
       )
       when ownership in [:owned, :unknown] do
    startup = state.startup

    if candidate.path == startup.candidate.path and candidate.nonce == startup.candidate.nonce do
      owned =
        if ownership == :owned and is_map(Map.get(claim, :identity)),
          do: Map.put(candidate, :identity, claim.identity),
          else: nil

      %{state | startup: %{startup | candidate: candidate, owned_root: owned}}
      |> fail_start(:temporary_root_creation_failed, ownership)
    else
      fail_start(state, :temporary_root_creation_failed, :unknown)
    end
  end

  defp accept_phase_result(state, :root_claim, {:ok, %{identity: identity} = owned})
       when is_map(identity) do
    if owned.path == state.startup.candidate.path and
         owned.nonce == state.startup.candidate.nonce do
      advance(state, :private_supervisor, %{owned_root: owned})
    else
      fail_start(state, :temporary_root_creation_failed, :unknown)
    end
  end

  defp accept_phase_result(state, :trace_bind, :ok), do: advance(state, :prepared, %{})

  defp accept_phase_result(state, :candidate_prepare, {:error, :temporary_root_unusable}),
    do: fail_start(state, :temporary_root_unusable, :known)

  defp accept_phase_result(state, phase, {:ok, value}) when phase in @phase_order do
    case register_result(state.startup, phase, value) do
      {:ok, startup} ->
        if phase != :runtime,
          do: send(startup.root, {:ack, self(), startup.reference, phase, value})

        next = next_phase(phase)
        %{state | startup: startup} |> advance(next, %{})

      :error ->
        fail_start(state, failure_cause(phase), :unknown)
    end
  end

  defp accept_phase_result(state, phase, result) when phase in @phase_order do
    ownership =
      if phase == :root_claim and match?({:error, {:claim_unproved, _}}, result),
        do: :unknown,
        else: :known

    fail_start(state, failure_cause(phase), ownership)
  end

  defp advance(state, phase, changes) do
    startup =
      state.startup
      |> Map.merge(changes)
      |> Map.merge(%{
        expected: phase,
        ready: phase == :trace_bind and state.startup.early_trace_bind,
        granted: false
      })

    %{state | startup: startup} |> maybe_grant()
  end

  defp register_result(startup, phase, value)
       when phase in [
              :private_supervisor,
              :memory_store,
              :workspace_lease,
              :executor,
              :trace_capability,
              :runtime_holder
            ] and is_pid(value) do
    if Process.alive?(value) do
      monitor = Process.monitor(value)

      {:ok,
       %{
         startup
         | registered: Map.put(startup.registered, phase, value),
           process_monitors: Map.put(startup.process_monitors, value, monitor)
       }}
    else
      :error
    end
  end

  defp register_result(startup, :store_handle, %Store{reference: reference} = value)
       when reference == startup.registered.memory_store,
       do: {:ok, %{startup | registered: Map.put(startup.registered, :store_handle, value)}}

  defp register_result(startup, :trace_handle, %TraceHandle{pid: pid} = value)
       when pid == startup.registered.trace_capability,
       do: {:ok, %{startup | registered: Map.put(startup.registered, :trace_handle, value)}}

  defp register_result(startup, :runtime, %Runtime{supervisor: supervisor} = runtime)
       when is_pid(supervisor) do
    if Process.alive?(supervisor) do
      monitor = Process.monitor(supervisor)

      {:ok,
       %{
         startup
         | registered:
             Map.merge(startup.registered, %{runtime: runtime, runtime_supervisor: supervisor}),
           process_monitors: Map.put(startup.process_monitors, supervisor, monitor)
       }}
    else
      :error
    end
  end

  defp register_result(_startup, _phase, _value), do: :error

  defp next_phase(:private_supervisor), do: :memory_store
  defp next_phase(:memory_store), do: :store_handle
  defp next_phase(:store_handle), do: :workspace_lease
  defp next_phase(:workspace_lease), do: :executor
  defp next_phase(:executor), do: :trace_capability
  defp next_phase(:trace_capability), do: :trace_handle
  defp next_phase(:trace_handle), do: :runtime_holder
  defp next_phase(:runtime_holder), do: :runtime
  defp next_phase(:runtime), do: :trace_bind

  defp expected_sender(startup, :runtime), do: Map.get(startup.registered, :runtime_holder)
  defp expected_sender(startup, _phase), do: startup.root

  defp phase_payload(state, :executor) do
    [
      session_owner: self(),
      session_instance: state.startup.executor_instance,
      session_generation: state.startup.generation,
      session_cell: state.cell,
      session_admission: SessionAdmission.handle(self(), state.startup.generation, state.cell),
      cleanup_grace_ms: state.cleanup_grace_ms
    ]
  end

  defp phase_payload(state, :runtime), do: runtime_options(state)
  defp phase_payload(_state, _phase), do: nil

  defp runtime_options(state) do
    startup = state.startup
    config = startup.configuration

    tools =
      if config.tools == :none, do: [], else: Loopex.Executor.Local.CodingTools.definitions()

    active =
      if config.tools == :read_only,
        do: @read_only,
        else: if(config.tools == :none, do: [], else: @coding)

    trace = Map.fetch!(startup.registered, :trace_handle)

    model = %{
      module: Loopex.LLM.ReqLLM.InProcess,
      model: config.model,
      options: [
        base_url: config.base_url,
        credential_variable: config.provider.credential_variable,
        trace_capability: trace,
        session_admission: SessionAdmission.handle(self(), startup.generation, state.cell),
        session_cell: state.cell
      ]
    }

    [
      runtime_id: TempRoot.runtime_id(startup.owned_root.nonce),
      store: Map.fetch!(startup.registered, :store_handle),
      policy: config.policy,
      policy_identity: %{"id" => inspect(config.policy), "revision" => "0.2.0"},
      executor: %{
        module: Loopex.Executor.Local,
        reference: Map.fetch!(startup.registered, :executor),
        identity: "executor-local",
        epoch: 1,
        fencing_token: 1,
        workspace_ref: config.skills.manifest["workspace_ref"],
        workspace_lease: "workspace"
      },
      tools: tools,
      active_tools: active,
      model: model,
      bounds: %{max_turns: config.max_steps, deadline_ms: config.deadline_ms},
      sampling: %{"max_tokens" => config.max_tokens},
      context_token_budget: config.context_token_budget,
      resource_manifest: config.skills.manifest,
      cleanup_grace_ms: state.cleanup_grace_ms
    ]
  end

  defp prepared_matches?(startup, prepared) when is_map(prepared) do
    registered = startup.registered

    Map.get(prepared, :root) == startup.owned_root and
      Map.get(prepared, :supervisor) == registered.private_supervisor and
      Map.get(prepared, :store) ==
        %{pid: registered.memory_store, handle: registered.store_handle} and
      Map.get(prepared, :workspace_lease) == registered.workspace_lease and
      Map.get(prepared, :executor) == registered.executor and
      Map.get(prepared, :trace_capability) ==
        %{pid: registered.trace_capability, handle: registered.trace_handle} and
      Map.get(prepared, :runtime_holder) == registered.runtime_holder and
      Map.get(prepared, :runtime) == registered.runtime
  end

  defp prepared_matches?(_startup, _prepared), do: false

  defp live_subtree?(startup) do
    Enum.all?(Map.keys(startup.process_monitors), &Process.alive?/1)
  end

  defp failure_cause(phase) when phase in [:candidate_prepare, :root_claim],
    do: :temporary_root_creation_failed

  defp failure_cause(:private_supervisor), do: :dependency_start_failed

  defp failure_cause(phase) when phase in [:memory_store, :store_handle],
    do: :store_start_failed

  defp failure_cause(:workspace_lease), do: :workspace_lease_failed
  defp failure_cause(:executor), do: :executor_start_failed

  defp failure_cause(phase) when phase in [:trace_capability, :trace_handle],
    do: :trace_capability_start_failed

  defp failure_cause(:runtime_holder), do: :dependency_start_failed
  defp failure_cause(:runtime), do: :runtime_start_failed
  defp failure_cause(:trace_bind), do: :trace_capability_bind_failed

  defp timeout_cause(%{facade: %{operation: operation}}), do: facade_failure(operation)
  defp timeout_cause(%{expected: phase}) when phase in @phase_order, do: failure_cause(phase)
  defp timeout_cause(_startup), do: :dependency_start_failed

  # Concept: rollback observes the same one-session proof obligations as stop.
  # Technical depth: an exact returned failure is not a lost grant. Cleanup
  # attempts never block this receive loop and never remove an unowned path.
  defp fail_start(%{startup: startup} = state, cause, ownership) do
    :atomics.put(state.cell, 1, 1)
    deadline = System.monotonic_time() + native(state.cleanup_grace_ms + 5_000)
    Process.send_after(self(), {:abort_deadline, startup.reference}, remaining(deadline))

    unknown_start =
      startup.expected in @phase_order and
        startup.expected not in [:candidate_prepare, :root_claim] and
        (startup.granted or (ownership == :unknown and cause == failure_cause(startup.expected)))

    possible_root =
      cond do
        is_map(startup.owned_root) ->
          startup.owned_root.path

        startup.expected == :root_claim and is_map(startup.candidate) and
            (startup.granted or ownership in [:owned, :unknown]) ->
          startup.candidate.path

        true ->
          nil
      end

    next = %{
      state
      | phase: :aborting,
        startup:
          Map.merge(startup, %{
            cause: startup_cause(cause),
            ownership: ownership,
            possible_root: possible_root
          }),
        abort: %{
          deadline: deadline,
          stage: :facade_reap,
          down: MapSet.new(),
          worker: nil,
          unknown_start: unknown_start,
          group_proved: false,
          group_failed: false,
          subtree_failed: false,
          root_failed: false,
          root_proved: false
        }
    }

    case Map.get(startup.registered, :facade_client) do
      client when is_pid(client) ->
        Process.exit(client, :kill)
        Process.send_after(self(), {:abort_facade_deadline, startup.reference}, 1_000)

      _ ->
        :ok
    end

    continue_abort(next)
  end

  defp continue_abort(%{abort: %{stage: :facade_reap} = abort} = state) do
    client = Map.get(state.startup.registered, :facade_client)

    if not is_pid(client) or MapSet.member?(abort.down, client),
      do: start_group_drain(state),
      else: state
  end

  defp continue_abort(%{abort: %{stage: :await_subtree} = abort} = state) do
    if all_subtree_down?(state.startup, abort.down), do: after_subtree(state), else: state
  end

  defp continue_abort(state), do: state

  defp start_group_drain(state) do
    startup = state.startup
    abort = state.abort
    executor = Map.get(startup.registered, :executor)

    cond do
      not is_pid(executor) and startup.expected == :executor and startup.granted ->
        start_runtime_stop(%{state | abort: %{abort | group_failed: true}})

      not is_pid(executor) ->
        start_runtime_stop(%{state | abort: %{abort | group_proved: true}})

      MapSet.member?(abort.down, executor) or not Process.alive?(executor) ->
        start_runtime_stop(%{state | abort: %{abort | group_failed: true}})

      true ->
        start_abort_worker(state, :process_groups, make_ref())
    end
  end

  defp start_runtime_stop(state) do
    runtime = Map.get(state.startup.registered, :runtime)

    if match?(%Runtime{}, runtime) and
         not MapSet.member?(state.abort.down, runtime.supervisor) do
      start_abort_worker(state, :runtime_stop, nil)
    else
      start_subtree_stop(state)
    end
  end

  defp start_subtree_stop(state) do
    if MapSet.member?(state.abort.down, state.startup.root),
      do: await_subtree(state),
      else: start_abort_worker(state, :subtree_stop, nil)
  end

  defp await_subtree(state) do
    next = %{state | abort: %{state.abort | stage: :await_subtree}}
    continue_abort(next)
  end

  defp after_subtree(%{abort: abort, startup: startup} = state) do
    cond do
      abort.unknown_start or abort.group_failed or abort.subtree_failed ->
        finish_abort(state)

      is_map(startup.owned_root) ->
        start_abort_worker(state, :root_removal, nil)

      startup.possible_root != nil ->
        finish_abort(%{state | abort: %{abort | root_failed: true}})

      true ->
        finish_abort(%{state | abort: %{abort | root_proved: true}})
    end
  end

  defp start_abort_worker(state, phase, nonce) do
    owner = self()
    reference = make_ref()
    now = System.monotonic_time()
    cutoff = min(now + native(500), state.abort.deadline)
    slot = min(now + native(1_000), state.abort.deadline)

    {pid, monitor} =
      :erlang.spawn_opt(
        fn ->
          Process.flag(:sensitive, true)

          result =
            try do
              abort_operation(state, phase, nonce, cutoff)
            rescue
              _ -> {:error, :operation_failed}
            catch
              _, _ -> {:error, :operation_failed}
            end

          send(owner, {self(), reference, phase, :result, result, System.monotonic_time()})

          receive do
            {^owner, ^reference, :finish} -> :ok
          after
            remaining(slot) -> exit(:finish_not_received)
          end
        end,
        [:link, :monitor]
      )

    Process.send_after(self(), {:abort_operation_cutoff, reference}, remaining(cutoff))
    Process.send_after(self(), {:abort_slot_deadline, reference}, remaining(slot))

    worker = %{
      pid: pid,
      monitor: monitor,
      reference: reference,
      phase: phase,
      nonce: nonce,
      cutoff: cutoff,
      result: false,
      certificate: false,
      finish_sent: false
    }

    %{state | abort: %{state.abort | stage: phase, worker: worker}}
  end

  defp abort_operation(state, :process_groups, nonce, deadline) do
    startup = state.startup

    group_drain(startup.configuration).(
      startup.registered.executor,
      startup.executor_instance,
      self_owner(state),
      nonce,
      deadline
    )
  end

  defp abort_operation(state, :runtime_stop, _nonce, _deadline),
    do: Loopex.stop(state.startup.registered.runtime)

  defp abort_operation(state, :subtree_stop, _nonce, _deadline) do
    Process.exit(state.startup.root, :shutdown)
    :ok
  end

  defp abort_operation(state, :root_removal, _nonce, _deadline),
    do: TempRoot.remove(state.startup.owned_root)

  defp abort_operation(state, :root_absence, _nonce, _deadline) do
    case File.lstat(state.startup.owned_root.path) do
      {:error, :enoent} -> :ok
      _ -> {:error, :root_removal_unproved}
    end
  end

  defp self_owner(state), do: state.startup.owner

  defp valid_abort_result?(:process_groups, {:ok, nonce}, nonce), do: true

  defp valid_abort_result?(phase, :ok, _nonce)
       when phase in [:runtime_stop, :subtree_stop, :root_removal, :root_absence], do: true

  defp valid_abort_result?(_phase, _result, _nonce), do: false

  defp maybe_finish_abort_worker(%{abort: %{worker: worker}} = state) do
    if worker.result and (worker.phase != :process_groups or worker.certificate) and
         not worker.finish_sent do
      send(worker.pid, {self(), worker.reference, :finish})
      put_in(state.abort.worker.finish_sent, true)
    else
      state
    end
  end

  defp finish_abort_worker(%{abort: %{worker: worker} = abort} = state, reason) do
    success =
      worker.result and worker.finish_sent and reason == :normal and
        (worker.phase != :process_groups or worker.certificate)

    next = %{state | abort: %{abort | worker: nil}}

    case worker.phase do
      :process_groups ->
        next = %{next | abort: %{next.abort | group_proved: success, group_failed: not success}}
        start_runtime_stop(next)

      :runtime_stop ->
        start_subtree_stop(next)

      :subtree_stop ->
        next = %{next | abort: %{next.abort | subtree_failed: not success}}
        await_subtree(next)

      :root_removal ->
        if success,
          do: start_abort_worker(next, :root_absence, nil),
          else: finish_abort(%{next | abort: %{next.abort | root_failed: true}})

      :root_absence ->
        finish_abort(%{
          next
          | abort: %{next.abort | root_proved: success, root_failed: not success}
        })
    end
  end

  defp mark_abort_timeout(state) do
    phase = state.abort.stage
    abort = state.abort

    abort =
      cond do
        phase == :process_groups ->
          %{abort | group_failed: true}

        phase in [:root_removal, :root_absence] ->
          %{abort | root_failed: true}

        phase in [:runtime_stop, :subtree_stop, :await_subtree, :facade_reap] ->
          %{abort | subtree_failed: true}

        true ->
          abort
      end

    %{state | abort: abort}
  end

  defp all_subtree_down?(startup, down) do
    Enum.all?(Map.keys(startup.process_monitors), &MapSet.member?(down, &1))
  end

  defp finish_abort(%{phase: :aborting, startup: startup, abort: abort} = state) do
    pending =
      []
      |> maybe_pending(abort.group_failed, :process_groups)
      |> maybe_pending(
        abort.unknown_start or abort.subtree_failed or
          not all_subtree_down?(startup, abort.down) or
          (abort.worker != nil and abort.worker.phase not in [:root_removal, :root_absence]),
        :session_subtree
      )
      |> maybe_pending(abort.root_failed, :root_removal)

    result =
      if pending == [] and (abort.root_proved or startup.possible_root == nil) do
        {:error, startup.cause}
      else
        {:error,
         {:cleanup_unproved,
          %{
            root: startup.possible_root,
            root_ownership: if(is_map(startup.owned_root), do: :owned, else: :unknown),
            pending: pending,
            ending: :none,
            cause: startup.cause
          }}}
      end

    :atomics.put(
      state.cell,
      1,
      if(match?({:error, {:cleanup_unproved, _}}, result), do: 3, else: 2)
    )

    unless startup.replied, do: send(state.creator, {self(), startup.request, result})
    send(self(), :retire_sealed)
    %{state | phase: :sealed}
  end

  defp maybe_pending(pending, true, item), do: pending ++ [item]
  defp maybe_pending(pending, false, _item), do: pending

  defp startup_cause(:session_create_failed), do: {:session_create, :failed}
  defp startup_cause(:client_start_failed), do: {:client_start, :failed}
  defp startup_cause(:attach_failed), do: {:attach, :failed}
  defp startup_cause(:resource_admission_failed), do: {:resource_admission, :failed}
  defp startup_cause(:skill_activation_failed), do: {:skill_activation, :failed}
  defp startup_cause(cause), do: {:composition, cause}

  if Mix.env() == :test do
    defp group_drain(configuration),
      do:
        get_in(configuration, [:test_seams, :group_drain]) ||
          default_group_drain()
  else
    defp group_drain(_configuration), do: default_group_drain()
  end

  defp default_group_drain do
    fn executor, instance, owner, nonce, deadline ->
      apply(Loopex.Executor.Local, :drain_process_groups, [
        executor,
        instance,
        owner,
        nonce,
        deadline
      ])
    end
  end

  defp close_proved(state) do
    :atomics.put(state.cell, 1, 2)
    send(self(), :retire_sealed)
    %{state | phase: :sealed}
  end

  if Mix.env() == :test do
    defp test_seams(configuration), do: Map.get(configuration, :test_seams, %{})
  else
    defp test_seams(_configuration), do: %{}
  end

  defp native(ms), do: System.convert_time_unit(ms, :millisecond, :native)

  defp fresh?(expiry), do: is_integer(expiry) and System.monotonic_time() < expiry

  defp supervisor_from_ancestry do
    case {Process.get(:"$ancestors"), Process.info(self(), :links)} do
      {[parent | _], {:links, links}} when is_pid(parent) ->
        if parent in links, do: parent, else: nil

      _ ->
        nil
    end
  end

  defp remaining(expiry) do
    difference = max(expiry - System.monotonic_time(), 0)
    unit = System.convert_time_unit(1, :millisecond, :native)
    div(difference + unit - 1, unit)
  end
end
