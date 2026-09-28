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
  alias LoopexComposition.SessionAdmission
  alias LoopexComposition.Ephemeral.{SessionRoot, TempRoot}

  @startup_ms 5_000
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
          {:ok, {:subtree_committed, map()}} | {:error, term()}
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
      timeout_ms ->
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
         startup: nil
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
      else: {:noreply, fail_start(state, :startup_deadline_expired, :unknown)}
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
        {:DOWN, monitor, :process, root, _reason},
        %{phase: :aborting, startup: %{root: root, process_monitors: monitors}} = state
      ) do
    if Map.get(monitors, root) == monitor do
      {:noreply, finish_abort(state, true)}
    else
      {:noreply, state}
    end
  end

  def handle_info(
        {:startup_reap_deadline, reference},
        %{phase: :aborting, startup: %{reference: reference}} = state
      ) do
    {:noreply, finish_abort(state, false)}
  end

  def handle_info(
        {:subtree_committed, root, reference},
        %{
          startup: %{root: root, reference: reference, expected: :committed} = startup,
          phase: :starting
        } = state
      ) do
    if fresh?(startup.deadline) and live_subtree?(startup) do
      send(
        state.creator,
        {self(), startup.request, {:ok, {:subtree_committed, startup.prepared}}}
      )

      {:noreply, %{state | phase: :subtree_committed}}
    else
      {:noreply, fail_start(state, :startup_deadline_expired, :unknown)}
    end
  end

  def handle_info(
        {:DOWN, monitor, :process, root, _reason},
        %{phase: :starting, startup: %{root: root, process_monitors: monitors}} = state
      ) do
    if Map.get(monitors, root) == monitor do
      failed = fail_start(state, :dependency_start_failed, :unknown)
      {:noreply, finish_abort(failed, true)}
    else
      {:noreply, state}
    end
  end

  def handle_info(
        {:DOWN, monitor, :process, pid, _reason},
        %{phase: :subtree_committed, startup: startup} = state
      ) do
    cond do
      {monitor, pid} in [
        {state.monitors.creator, state.creator},
        {state.monitors.proxy, state.proxy},
        {state.monitors.supervisor, state.supervisor}
      ] ->
        {:stop, :normal, state}

      Map.get(startup.process_monitors, pid) == monitor ->
        :atomics.put(state.cell, 1, 3)
        if Process.alive?(startup.root), do: Process.exit(startup.root, :shutdown)
        {:noreply, %{state | phase: :sealed}}

      true ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, monitor, :process, pid, _reason}, state) do
    if {monitor, pid} in [
         {state.monitors.creator, state.creator},
         {state.monitors.proxy, state.proxy},
         {state.monitors.supervisor, state.supervisor}
       ] do
      {:stop, :normal, state}
    else
      if state.phase == :starting and
           Enum.any?(state.startup.process_monitors, fn {registered_pid, registered_monitor} ->
             registered_pid == pid and registered_monitor == monitor
           end) do
        {:noreply, fail_start(state, :dependency_start_failed, :unknown)}
      else
        {:noreply, state}
      end
    end
  end

  def handle_info({:EXIT, supervisor, _reason}, %{supervisor: supervisor} = state),
    do: {:stop, :normal, state}

  def handle_info(_message, state), do: {:noreply, state}

  defp start_subtree(state, request, configuration) do
    reference = make_ref()
    seams = test_seams(configuration)

    case SessionRoot.start_link(self(), reference, state.startup_deadline, configuration, seams) do
      {:ok, root} ->
        monitor = Process.monitor(root)

        startup = %{
          request: request,
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
          generation: make_ref()
        }

        {:noreply, %{state | phase: :starting, startup: startup}}

      _failure ->
        send(state.creator, {self(), request, {:error, {:composition, :dependency_start_failed}}})
        {:noreply, close_proved(state)}
    end
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
         {:error, {:claim_unproved, %{candidate: candidate, ownership: ownership}}}
       )
       when ownership in [:owned, :unknown] do
    startup = state.startup

    if candidate.path == startup.candidate.path and candidate.nonce == startup.candidate.nonce do
      %{state | startup: %{startup | candidate: candidate}}
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
      executor: Map.fetch!(startup.registered, :executor),
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

  defp fail_start(%{startup: startup} = state, cause, ownership) do
    if is_pid(startup.root) and Process.alive?(startup.root),
      do: Process.exit(startup.root, :shutdown)

    :atomics.put(state.cell, 1, 1)
    Process.send_after(self(), {:startup_reap_deadline, startup.reference}, 1_000)

    %{
      state
      | phase: :aborting,
        startup: Map.merge(startup, %{cause: cause, ownership: ownership})
    }
  end

  defp finish_abort(%{startup: startup} = state, root_down) do
    result = aborted_result(startup, root_down)

    :atomics.put(
      state.cell,
      1,
      if(match?({:error, {:cleanup_unproved, _}}, result), do: 3, else: 2)
    )

    send(state.creator, {self(), startup.request, result})
    %{state | phase: :sealed}
  end

  defp aborted_result(startup, root_down) do
    root =
      cond do
        is_map(startup.owned_root) ->
          startup.owned_root.path

        startup.expected == :root_claim and startup.granted and
            is_map(startup.candidate) ->
          startup.candidate.path

        true ->
          nil
      end

    cond do
      root == nil and root_down ->
        {:error, {:composition, startup.cause}}

      true ->
        pending =
          cond do
            not root_down -> [:session_subtree, :root_removal]
            root == nil -> [:session_subtree]
            is_map(startup.owned_root) -> [:session_subtree, :root_removal]
            true -> [:root_removal]
          end

        {:error,
         {:cleanup_unproved,
          %{
            root: root,
            root_ownership: if(is_map(startup.owned_root), do: :owned, else: startup.ownership),
            pending: pending,
            ending: :none,
            cause: startup.cause
          }}}
    end
  end

  defp close_proved(state) do
    :atomics.put(state.cell, 1, 2)
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
