Code.require_file("support/daemon_socket_fixture.exs", __DIR__)

defmodule LoopexDaemon.ServiceLifecycleTest do
  use ExUnit.Case, async: false
  @moduletag capture_log: true

  import LoopexDaemon.Test.DaemonSocketFixture,
    only: [send_frame: 2, receive_records: 2, receive_records: 3]

  alias LoopexComposition.Placement
  alias LoopexDaemon.Sentinel
  alias LoopexProtocol.{Session.V2, Wire}

  defmodule DenyPolicy do
    @moduledoc false
    @behaviour Loopex.Policy

    @impl Loopex.Policy
    def decide(_request), do: {:deny, :policy_denied}
  end

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "ldl-#{Loopex.TestTmp.Daemon.token()}"
      )

    workspace = Path.join(root, "w")
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf(root) end)
    state_root = Path.join(root, "s")

    options = [
      state_root: state_root,
      socket_path: Path.join([state_root, "daemon", "d.sock"]),
      workspace: workspace,
      policy: DenyPolicy,
      credential: "service-lifecycle-placeholder",
      admission_wait_ms: 200
    ]

    %{options: options, state_root: state_root}
  end

  defmodule SlowStop do
    @moduledoc false
    use GenServer

    @impl GenServer
    def init(terminate_ms), do: {:ok, terminate_ms}

    @impl GenServer
    def terminate(_reason, terminate_ms), do: Process.sleep(terminate_ms)
  end

  # Concept (audit fix 2): a stop counts as the daemon owner's only when the
  # component exits with the owner's own stop reason; a component already
  # gone, or one that exits `:normal` itself, is that component's own exit.
  #
  # Technical depth: each case passes a production-shaped stop function,
  # which receives the owner's stop reason. The answering stand-in takes the
  # stop request's `sys:terminate` message and exits `:normal` on its own,
  # the window `proc_lib:stop/3` would count as success were the requested
  # reason `:normal`.
  test "only the owner's own stop reason is a clean stop" do
    deadline = System.monotonic_time(:millisecond) + 1_000

    {:ok, live} = Agent.start(fn -> nil end)

    assert LoopexDaemon.Service.await_requested_stop(
             live,
             &GenServer.stop(live, &1, 500),
             deadline
           ) == :stopped

    {:ok, gone} = Agent.start(fn -> nil end)
    :ok = Agent.stop(gone)

    assert LoopexDaemon.Service.await_requested_stop(
             gone,
             &GenServer.stop(gone, &1, 500),
             deadline
           ) == {:component_exit, :noproc}

    answering =
      spawn(fn ->
        receive do
          {:system, _from, {:terminate, _reason}} -> exit(:normal)
        end
      end)

    assert LoopexDaemon.Service.await_requested_stop(
             answering,
             &GenServer.stop(answering, &1, 500),
             deadline
           ) == {:component_exit, :normal}
  end

  # Concept (audit fix 2): a component that ends on its own with `:normal`
  # after this owner began watching it, but before the stop request reached
  # it, is that component's own exit, not a clean stop.
  #
  # Technical depth: the stop function first makes the component exit
  # `:normal` by itself — after `await_requested_stop/3` has set its monitor —
  # and only then asks it to stop.
  test "an independent normal exit racing a requested stop is the component's own" do
    deadline = System.monotonic_time(:millisecond) + 1_000
    {:ok, racing} = Agent.start(fn -> nil end)

    stop = fn reason ->
      :ok = Agent.stop(racing, :normal)
      GenServer.stop(racing, reason, 500)
    end

    assert LoopexDaemon.Service.await_requested_stop(racing, stop, deadline) ==
             {:component_exit, :normal}
  end

  # Concept (audit fix 2): a component that takes the stop and finishes it
  # within the deadline is clean, however the stop request itself ends —
  # even when the request gives up first, or the stop lands just before the
  # deadline.
  #
  # Technical depth: `SlowStop` sleeps in `terminate/2`. In the first case
  # the stop call's own 50 ms timeout expires inside the helper while the
  # component is still stopping; in the second the component's stop ends
  # 30 ms before the deadline that also bounds the stop call.
  test "a stop that ends within its deadline is clean whatever its request answers" do
    {:ok, slow} = GenServer.start(SlowStop, 150)
    deadline = System.monotonic_time(:millisecond) + 1_000

    assert LoopexDaemon.Service.await_requested_stop(
             slow,
             &GenServer.stop(slow, &1, 50),
             deadline
           ) == :stopped

    {:ok, edge} = GenServer.start(SlowStop, 170)
    deadline = System.monotonic_time(:millisecond) + 200

    assert LoopexDaemon.Service.await_requested_stop(
             edge,
             &GenServer.stop(edge, &1, max(deadline - System.monotonic_time(:millisecond), 1)),
             deadline
           ) == :stopped
  end

  # Concept: every Store refusal at open reaches the operator as its own exit
  # class, whatever arity the Store's refusal carries.
  test "each Store open refusal shape names its exit class" do
    for {reason, class} <- [
          {{:store_writer_active, "/r/store.log.writer"}, :store_writer_active},
          {{:store_writer_unverifiable, "/r/store.log.writer", :malformed},
           :store_writer_unverifiable},
          {{:store_log_too_large, 300, 200}, :store_log_too_large},
          {{:store_writer_lock_failed, :eacces}, :store_writer_acquisition_failed},
          {{:store_writer_lock_close_failed, :eio}, :store_writer_acquisition_failed},
          {{:store_writer_recovery_failed, :eperm}, :store_writer_acquisition_failed},
          {{:store_writer_identity_unavailable, :timeout}, :store_writer_acquisition_failed},
          {:store_writer_active, :store_writer_active},
          {{:store_corrupt, 12}, nil},
          {:unexpected, nil}
        ] do
      assert LoopexDaemon.ExitStatus.store_open_class(reason) == class, inspect(reason)
    end
  end

  test "a ready daemon serves a client and an orderly stop releases every exclusion",
       %{options: options, state_root: state_root} do
    daemon = start_daemon(options)
    ready = await_ready(daemon.output)

    assert ready["record"] == "daemon_ready"
    assert ready["root"] == state_root
    assert ready["socket"] == options[:socket_path]
    assert ready["version"] == "0.2.0"

    # Custody holds the one copy of the credential; the owner keeps none.
    refute Keyword.has_key?(:sys.get_state(daemon.owner).options, :credential)

    client = initialized(options[:socket_path])

    :ok =
      send_frame(client, %{
        "method" => "session.create",
        "request_id" => "create",
        "command_id" => Wire.encode_identity("lifecycle-create"),
        "session_options" => %{"purpose" => "lifecycle"}
      })

    assert [%{"status" => "accepted", "session_id" => encoded}] = receive_records(client, 1)
    {:ok, session_id} = Wire.identity(encoded)

    send(daemon.sentinel, {:daemon_signal, daemon.owner_ref, :sigterm})

    assert [%{"type" => "daemon.stopping", "reason" => "operator_stop"}] =
             receive_records(client, 1)

    assert Task.await(daemon.task, 30_000) == 0
    assert {:ok, %File.Stat{type: :other}} = File.lstat(options[:socket_path])
    assert Placement.live_owner(state_root) == :none

    {:ok, adapter} = Loopex.Store.Local.start_link(path: Path.join(state_root, "store.log"))
    {:ok, store} = Loopex.Store.new(Loopex.Store.Local, adapter)
    {:ok, placement} = Loopex.runtime_placement_id(state_root)

    {:ok, runtime} =
      Loopex.start_link(runtime_id: placement, store: store, context_token_budget: 8_192)

    assert {:ok, :present} = Loopex.Runtime.session_existence(runtime, session_id)
    :ok = Loopex.stop(runtime)
    :ok = GenServer.stop(adapter)
  end

  # Concept (T14): no process another component waits on under a deadline —
  # the collaboration owner, the connection registry, a lease owner or a
  # connection — makes a blocking call into another daemon component, while
  # serving or during the orderly stop. No call is allowed: a connection
  # exchanges its promotion, initialization, output, succession and route
  # requests with the registry, and its registration with the relay, by
  # request message. The witness sees blocking through `:gen.call/4` only —
  # every `GenServer.call`, `:gen_server.call` and `:sys` call goes through it
  # — and not a `proc_lib` start or a bare `receive`; no component blocks
  # those ways today, and the design allows `LeaseOwner.start_link`.
  #
  # Technical depth: every `:gen.call/4` made by the collaboration owner, the
  # registry and the listener, and by every process they spawn (lease owners,
  # connections and their workers), is traced together with their spawns. The
  # pattern is local, so a `:sys` call, which reaches `:gen.call/4` from
  # `:gen.call/3` inside `gen`, is seen too.
  # Each process's kind is fixed when it is known: the processes present at
  # the start from their initial call, and every later traced process from
  # the `gen` module named in its own spawn event, so a process that has
  # exited by the time a call is classified keeps its kind. A call's target
  # is resolved when the tracer receives it — a pid through that table or its
  # initial call, a registered name through `Process.whereis/1` — and calls
  # are classified only after the stop. A caller the table cannot name, or a
  # target that cannot be resolved, is a violation: the witness fails closed.
  # Every `:gen.send_request/3,5` is traced too, and the connections' requests
  # to the registry and the relay must have been seen, so the trace was live
  # on the connections.
  @tag timeout: 90_000
  test "no deadline-subject component blocks on another while serving or stopping",
       %{options: options} do
    daemon = start_daemon(options)
    _ready = await_ready(daemon.output)
    %{tracer: tracer} = start_call_trace(daemon)
    client = initialized(options[:socket_path])

    :ok =
      send_frame(client, %{
        "method" => "session.create",
        "request_id" => "create",
        "command_id" => Wire.encode_identity("t14-create"),
        "session_options" => %{"purpose" => "t14"}
      })

    assert [%{"status" => "accepted", "session_id" => session_id}] = receive_records(client, 1)
    acquire = %{"method" => "session.acquire_control", "session_id" => session_id}
    :ok = send_frame(client, Map.put(acquire, "request_id", "acquire"))

    assert [%{"type" => "result", "result" => %{"writer_epoch" => epoch}}] =
             receive_records(client, 1)

    :ok =
      send_frame(client, %{
        "method" => "session.attach",
        "request_id" => "attach",
        "session_id" => session_id
      })

    assert [%{"type" => "snapshot"}] = receive_records(client, 1)

    :ok =
      send_frame(client, %{
        "method" => "session.release_control",
        "request_id" => "release",
        "session_id" => session_id,
        "writer_epoch" => epoch
      })

    assert [%{"request_id" => "release", "type" => "result"}] = receive_records(client, 1)
    :ok = send_frame(client, Map.put(acquire, "request_id", "reacquire"))
    assert [%{"request_id" => "reacquire", "type" => "result"}] = receive_records(client, 1)

    send(daemon.sentinel, {:daemon_signal, daemon.owner_ref, :sigterm})
    assert Task.await(daemon.task, 60_000) == 0

    assert_call_trace_clean(tracer)
  end

  # Concept (T14, companion): the same rule holds across the rest of the
  # serving surface — a prompt's mutation ticket, a resume, the owner
  # succession it causes and the reattach after it, a lease owner that
  # is lost and the new lease owner started after it, a holder that closes
  # while holding,
  # `session.list` and `daemon.status` — and through a fail-stop instead of
  # an orderly stop.
  #
  # Technical depth: the trace is the one above. The lease owner is killed,
  # so the holder is told its owner was lost and a fresh acquire from another
  # connection starts the replacement, whose holder then closes without
  # releasing. The run ends by killing the relay, so the daemon fail-stops
  # `relay_lost`. A lease owner superseded for missing its own step (P2) is
  # witnessed in `owner_test.exs`.
  @tag timeout: 120_000
  test "T14: no component blocks across tickets, succession, replacement, close and fail-stop",
       %{options: options} do
    daemon = start_daemon(options)
    _ready = await_ready(daemon.output)
    %{collaboration: collaboration, relay: relay, tracer: tracer} = start_call_trace(daemon)
    on_exit(fn -> Process.exit(collaboration, :kill) end)

    holder = initialized(options[:socket_path])
    observer = initialized(options[:socket_path])

    :ok =
      send_frame(holder, %{
        "method" => "session.create",
        "request_id" => "create",
        "command_id" => Wire.encode_identity("t14b-create"),
        "session_options" => %{"purpose" => "t14b"}
      })

    assert [%{"status" => "accepted", "session_id" => session_id}] = receive_records(holder, 1)
    acquire = %{"method" => "session.acquire_control", "session_id" => session_id}
    attach = %{"method" => "session.attach", "session_id" => session_id}
    :ok = send_frame(holder, Map.put(acquire, "request_id", "acquire"))
    assert [%{"result" => %{"writer_epoch" => epoch}}] = receive_records(holder, 1)
    :ok = send_frame(holder, Map.put(attach, "request_id", "attach"))
    assert [%{"type" => "snapshot"}] = receive_records(holder, 1)

    # A resume of the active session goes through the lease owner's route and starts a
    # successor owner, which detaches the attached holder through the
    # succession notice before the admission; the holder reattaches.
    :ok =
      send_frame(holder, %{
        "method" => "session.resume",
        "request_id" => "resume",
        "session_id" => session_id,
        "command_id" => Wire.encode_identity("t14b-resume"),
        "writer_epoch" => epoch
      })

    assert %{"code" => "detached"} = await_record(holder, &(&1["type"] == "error"))
    assert [%{"request_id" => "resume", "status" => "accepted"}] = receive_records(holder, 1)

    :ok = send_frame(holder, Map.put(attach, "request_id", "reattach"))
    assert %{"type" => "snapshot"} = await_record(holder, &(&1["request_id"] == "reattach"))

    # A prompt's mutation ticket goes through the lease owner's route; it runs
    # after the resume, so the resume meets an idle session.
    :ok =
      send_frame(holder, %{
        "method" => "session.prompt",
        "request_id" => "prompt",
        "command_id" => Wire.encode_identity("t14b-prompt"),
        "content_b64" => Wire.encode_bytes("hello"),
        "writer_epoch" => epoch
      })

    assert %{"type" => "admission", "status" => "accepted"} =
             await_record(holder, &(&1["request_id"] == "prompt"))

    # list and status from a second connection.
    :ok =
      send_frame(observer, %{"method" => "session.list", "request_id" => "list", "limit" => 8})

    assert %{"type" => "result"} = await_record(observer, &(&1["request_id"] == "list"))
    :ok = send_frame(observer, %{"method" => "daemon.status", "request_id" => "status"})
    assert %{"type" => "result"} = await_record(observer, &(&1["request_id"] == "status"))

    # The holder's lease owner is lost: the collaboration owner pops it and
    # closes the holder, and a fresh acquire starts a new lease owner.
    {:ok, raw} = Wire.identity(session_id)
    lease_owner = Map.fetch!(:sys.get_state(collaboration).owners, raw).pid
    Process.exit(lease_owner, :kill)

    assert %{"code" => "control_owner_lost"} =
             await_record(holder, &(&1["code"] == "control_owner_lost"))

    replacement = initialized(options[:socket_path])
    :ok = send_frame(replacement, Map.put(acquire, "request_id", "replace"))

    assert %{"result" => %{"writer_epoch" => _epoch}} =
             await_record(replacement, &(&1["request_id"] == "replace"))

    # The replacement holder closes while holding.
    :socket.close(replacement)
    registry = :sys.get_state(collaboration).registry
    await_until(fn -> LoopexDaemon.ConnectionRegistry.status(registry).occupied == 2 end)

    # A fail-stop instead of an orderly stop.
    Process.exit(relay, :kill)

    assert %{"reason" => "fatal:relay_lost"} =
             await_record(observer, &(&1["type"] == "daemon.stopping"))

    {:ok, relay_lost} = LoopexDaemon.ExitStatus.fetch(:relay_lost)
    assert Task.await(daemon.task, 60_000) == relay_lost
    assert_call_trace_clean(tracer)
  end

  defp await_record(socket, predicate, timeout \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    await_record_until(socket, predicate, deadline)
  end

  defp await_record_until(socket, predicate, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)
    [record] = receive_records(socket, 1, remaining)
    if predicate.(record), do: record, else: await_record_until(socket, predicate, deadline)
  end

  # Technical depth: the trace covers the collaboration owner, the registry,
  # the listener and everything they spawn; the kinds of processes already
  # present are fixed from their initial calls.
  defp start_call_trace(daemon) do
    %{collaboration: collaboration, listener: listener} = :sys.get_state(daemon.owner).pids
    %{registry: registry, relay: relay} = :sys.get_state(collaboration)

    known =
      Process.list()
      |> Enum.map(&{&1, initial_kind(&1)})
      |> Enum.reject(fn {_pid, kind} -> is_nil(kind) end)
      |> Map.new()
      |> Map.merge(%{
        collaboration => :owner,
        registry => :registry,
        relay => :relay,
        listener => :other
      })

    test_pid = self()

    tracer =
      spawn_link(fn ->
        call_trace_loop(%{kinds: known, calls: [], requests: [], test: test_pid})
      end)

    traced = [{:gen, :call, 4}, {:gen, :send_request, 3}, {:gen, :send_request, 5}]
    for pattern <- traced, do: :erlang.trace_pattern(pattern, true, [:local])

    on_exit(fn ->
      for pattern <- traced, do: :erlang.trace_pattern(pattern, false, [:local])
    end)

    for pid <- [collaboration, registry, listener],
        do: :erlang.trace(pid, true, [:call, :procs, :set_on_spawn, {:tracer, tracer}])

    %{collaboration: collaboration, relay: relay, tracer: tracer}
  end

  defp assert_call_trace_clean(tracer) do
    send(tracer, {:violations, self()})
    assert_receive {:violations, violations, requests}, 5_000
    assert violations == []
    # The trace saw the connections' requests, so it was live on them.
    assert requests[:registry] > 0
    assert requests[:relay] > 0
  end

  defp call_trace_loop(state) do
    receive do
      {:trace, _parent, :spawn, child, mfa} ->
        call_trace_loop(put_in(state, [:kinds, child], spawn_kind(mfa)))

      {:trace, caller, :call, {:gen, :call, [target, _label, request, _timeout]}} ->
        call = {caller, resolve_target(state.kinds, target), request}
        call_trace_loop(%{state | calls: [call | state.calls]})

      {:trace, caller, :call, {:gen, :send_request, [target | _rest]}} ->
        request = {caller, resolve_target(state.kinds, target)}
        call_trace_loop(%{state | requests: [request | state.requests]})

      {:violations, from} ->
        send(from, {:violations, classify_calls(state), connection_requests(state)})
        call_trace_loop(state)

      _other ->
        call_trace_loop(state)
    end
  end

  defp classify_calls(state) do
    state.calls
    |> Enum.reverse()
    |> Enum.map(fn {caller, target, request} -> classify_call(state, caller, target, request) end)
    |> Enum.reject(&(&1 == :ignored))
  end

  defp connection_requests(state) do
    state.requests
    |> Enum.filter(fn {caller, _target} -> Map.get(state.kinds, caller) == :connection end)
    |> Enum.frequencies_by(fn {_caller, target} -> target end)
  end

  # Technical depth: a call is a violation when a deadline-subject component
  # calls another daemon component, and whenever its caller or target cannot
  # be resolved.
  defp classify_call(state, caller, target, request) do
    caller_kind = Map.get(state.kinds, caller, :unresolved)
    tag = if is_tuple(request), do: elem(request, 0), else: request

    cond do
      caller == state.test ->
        :ignored

      caller_kind == :unresolved ->
        {:unresolved_caller, target, tag}

      caller_kind not in [:owner, :registry, :lease_owner, :connection] ->
        :ignored

      target == :unresolved ->
        {caller_kind, :unresolved_target, tag}

      target in [:other, :self] ->
        :ignored

      true ->
        {caller_kind, target, tag}
    end
  end

  @component_modules %{
    LoopexDaemon.Owner => :owner,
    LoopexDaemon.ConnectionRegistry => :registry,
    LoopexDaemon.LeaseOwner => :lease_owner,
    LoopexDaemon.SocketConnection => :connection,
    LoopexDaemon.AdmissionRelay => :relay
  }

  # Technical depth: a `gen` process's spawn event names its callback module
  # in `gen:init_it/6,7`'s arguments, named or not.
  defp spawn_kind({:proc_lib, :init_p, [_parent, _ancestors, :gen, :init_it, arguments]}) do
    module =
      case arguments do
        [_gen_module, _starter, _parent, module, _args, _options] -> module
        [_gen_module, _starter, _parent, _name, module, _args, _options] -> module
        _other -> nil
      end

    Map.get(@component_modules, module, :other)
  end

  defp spawn_kind(_mfa), do: :other

  defp initial_kind(pid) do
    case Process.info(pid, :dictionary) do
      {:dictionary, dictionary} ->
        case dictionary[:"$initial_call"] do
          {module, _function, _arity} -> Map.get(@component_modules, module)
          _other -> nil
        end

      nil ->
        nil
    end
  end

  # Technical depth: a target is resolved when the call is received, while it
  # most likely still lives; a pid the table does not name is a non-component
  # when it is alive and not a component, and unresolved when it is gone.
  defp resolve_target(kinds, pid) when is_pid(pid) do
    case Map.fetch(kinds, pid) do
      {:ok, kind} ->
        kind

      :error ->
        if Process.alive?(pid), do: initial_kind(pid) || :other, else: :unresolved
    end
  end

  defp resolve_target(kinds, name) when is_atom(name),
    do: resolve_named(kinds, Process.whereis(name))

  defp resolve_target(kinds, {name, node}) when is_atom(name) and node == node(),
    do: resolve_named(kinds, Process.whereis(name))

  defp resolve_target(kinds, {:via, module, name}),
    do: resolve_named(kinds, module.whereis_name(name))

  defp resolve_target(kinds, {:global, name}),
    do: resolve_named(kinds, :global.whereis_name(name))

  defp resolve_target(_kinds, _other), do: :unresolved

  defp resolve_named(kinds, pid) when is_pid(pid), do: resolve_target(kinds, pid)
  defp resolve_named(_kinds, _missing), do: :unresolved
  # Concept (T21): during an orderly stop, a lease owner's relay request that
  # stays unanswered for longer than a serving step between the admission
  # cut and the freeze is governed by the stop's own deadlines: its
  # unanswered-request report latches nothing, the request completes once
  # the relay resumes, and the stop exits 0.
  #
  # Technical depth: a second client's acquire is opened while its lease
  # owner is suspended, so the lease owner claims it only after the cut. The
  # relay is suspended for six seconds from the moment the cut is consumed,
  # and the lease owner is then resumed, so its claim waits past its
  # five-second report, which a debug hook on the collaboration owner
  # observes. The admission wait is ten seconds, so the stop reaches the
  # freeze only after the relay resumes and the request settles. This is the
  # owner and Service halves of T21; the registry's half — a relay request
  # of the registry unanswered after the cut — is witnessed in
  # `connection_registry_test.exs` ("a resume settlement refused after the
  # cut still settles its lease owner") and `owner_test.exs` ("an
  # unanswered registry relay report after the cut is cleanup-only").
  @tag timeout: 90_000
  test "a lease owner's relay request outlasting its step during the stop still exits zero",
       %{options: options} do
    daemon = start_daemon(Keyword.put(options, :admission_wait_ms, 10_000))
    _ready = await_ready(daemon.output)
    holder = initialized(options[:socket_path])

    :ok =
      send_frame(holder, %{
        "method" => "session.create",
        "request_id" => "create",
        "command_id" => Wire.encode_identity("t21-create"),
        "session_options" => %{"purpose" => "t21"}
      })

    assert [%{"status" => "accepted", "session_id" => session_id}] = receive_records(holder, 1)
    acquire = %{"method" => "session.acquire_control", "session_id" => session_id}
    :ok = send_frame(holder, Map.put(acquire, "request_id", "holder-acquire"))
    assert [%{"type" => "result"}] = receive_records(holder, 1)

    collaboration = :sys.get_state(daemon.owner).pids.collaboration
    %{relay: relay, owners: owners} = :sys.get_state(collaboration)
    [%{pid: lease_owner}] = Map.values(owners)
    :ok = :sys.suspend(lease_owner)

    observer = initialized(options[:socket_path])
    :ok = send_frame(observer, Map.put(acquire, "request_id", "observer-acquire"))
    await_until(fn -> map_size(:sys.get_state(relay).permits) == 1 end)

    send(daemon.sentinel, {:daemon_signal, daemon.owner_ref, :sigterm})

    await_until(fn -> :sys.get_state(relay).phase == :draining end)

    test_pid = self()

    :ok =
      :sys.install(
        collaboration,
        {fn
           forwarding,
           {:in, {:lease_owner_relay_unanswered, ^lease_owner, _incarnation}},
           _state ->
             send(test_pid, :lease_owner_reported)
             forwarding

           forwarding, _event, _state ->
             forwarding
         end, :forwarding}
      )

    :ok = :sys.suspend(relay)
    :ok = :sys.resume(lease_owner)
    Process.sleep(6_000)
    # The lease owner's claim really waited on the relay past its step: its
    # report reached the collaboration owner, which latched nothing.
    assert_received :lease_owner_reported
    :ok = :sys.resume(relay)

    assert [%{"request_id" => "observer-acquire", "code" => "control_held"}] =
             receive_records(observer, 1)

    assert Task.await(daemon.task, 60_000) == 0
  end

  defp await_until(predicate, attempts \\ 1_000)
  defp await_until(predicate, 0), do: assert(predicate.())

  defp await_until(predicate, attempts) do
    if predicate.() do
      :ok
    else
      Process.sleep(10)
      await_until(predicate, attempts - 1)
    end
  end

  # Concept: losing the listener after readiness is a daemon failure: the
  # daemon tells every connected client why it is stopping and ends with the
  # listener's own exit class.
  #
  # Technical depth: the listener the service started is killed while an
  # initialized client is connected. The client receives `daemon.stopping`
  # with `fatal:listener_lost` and the sentinel exits `listener_lost` (107).
  # Concept: a Store that stops because its journal reached capacity ends the
  # daemon with that class, telling every client why, distinct from any other
  # Store loss.
  #
  # Technical depth: the Store stops with `{:store_capacity_exceeded, max}`,
  # the reason its append-failure branch stops with when the log refuses an
  # append past its ceiling, which `log_capacity_test.exs` proves. A connected
  # client receives `daemon.stopping` with `store_capacity_exceeded` and the
  # sentinel exits `store_capacity_exceeded`.
  test "a Store stopped at capacity fail-stops with store_capacity_exceeded",
       %{options: options} do
    daemon = start_daemon(options)
    _ready = await_ready(daemon.output)
    client = initialized(options[:socket_path])

    store = :sys.get_state(daemon.owner).pids.store
    # The Store traps exits, so it is stopped with the reason itself, as its
    # append path's `{:stop, reason, ...}` does.
    spawn(fn -> GenServer.stop(store, {:store_capacity_exceeded, 268_435_456}, 5_000) end)

    assert [%{"type" => "daemon.stopping", "reason" => "store_capacity_exceeded"}] =
             receive_records(client, 1)

    {:ok, capacity} = LoopexDaemon.ExitStatus.fetch(:store_capacity_exceeded)
    assert Task.await(daemon.task, 40_000) == capacity
  end

  test "losing the listener after readiness fail-stops with listener_lost",
       %{options: options, state_root: state_root} do
    daemon = start_daemon(options)
    _ready = await_ready(daemon.output)
    client = initialized(options[:socket_path])

    listener = :sys.get_state(daemon.owner).pids.listener
    Process.exit(listener, :kill)

    assert [%{"type" => "daemon.stopping", "reason" => "fatal:listener_lost"}] =
             receive_records(client, 1)

    {:ok, listener_lost} = LoopexDaemon.ExitStatus.fetch(:listener_lost)
    assert Task.await(daemon.task, 60_000) == listener_lost

    # A fail-stop leaves the host placement lock to the daemon process's own
    # exit; here that process is this test's VM, which still holds it.
    assert {:ok, _holder} = Placement.live_owner(state_root)
  end

  # Concept: the socket's privacy is verified, never repaired: a daemon
  # directory that others can read refuses the start by its class and binds
  # nothing, while an ordinary `0755` state root is accepted because the daemon
  # owns only its own `0700` subdirectory.
  test "a permissive daemon directory refuses the start and a 0755 root is accepted",
       %{options: options, state_root: state_root} do
    File.mkdir_p!(Path.join(state_root, "daemon"))
    File.chmod!(state_root, 0o755)
    File.chmod!(Path.join(state_root, "daemon"), 0o755)

    {:ok, unverified} = LoopexDaemon.ExitStatus.fetch(:socket_permission_unverified)
    {:ok, output} = StringIO.open("")
    assert Sentinel.run(options, output: output, install_signals: false) == unverified
    assert StringIO.contents(output) == {"", ""}
    refute File.exists?(options[:socket_path])
    assert File.stat!(Path.join(state_root, "daemon")).mode |> Bitwise.band(0o777) == 0o755
    assert Placement.live_owner(state_root) == :none
    refute File.exists?(Path.join(state_root, "store.log.writer"))

    File.chmod!(Path.join(state_root, "daemon"), 0o700)
    daemon = start_daemon(options)
    ready = await_ready(daemon.output)
    assert ready["socket"] == options[:socket_path]
    assert File.stat!(state_root).mode |> Bitwise.band(0o777) == 0o755
    send(daemon.sentinel, {:daemon_signal, daemon.owner_ref, :sigterm})
    assert Task.await(daemon.task, 30_000) == 0
  end

  # Concept: the listener must still be alive when the daemon is released to
  # accept; one that dies while readiness is being written ends the start as
  # `listener_start_failed`, and no client is ever accepted.
  #
  # Technical depth: the sentinel's output device holds the readiness write
  # until the test has killed the parked listener, then lets it complete. The
  # owner's recheck after the write finds the listener gone, so the gate never
  # opens: the sentinel exits `listener_start_failed` and nothing accepts on the
  # socket path.
  test "a listener lost while readiness is written ends the start listener_start_failed",
       %{options: options} do
    test = self()
    device = spawn_link(fn -> holding_device(test) end)
    sentinel_test = self()

    task =
      Task.async(fn ->
        Sentinel.run(options, output: device, install_signals: false, notify: sentinel_test)
      end)

    assert_receive {:readiness_held, writer}, 30_000

    # This daemon's own listener, started by its owner: another case's
    # listener may still be alive in the same VM, and the owner is busy in
    # startup, so the listener is found by its ancestry.
    assert_receive {:loopex_daemon_sentinel, _sentinel, _owner_ref, owner}, 5_000

    [listener] =
      for pid <- Process.list(),
          {:dictionary, dictionary} <- [Process.info(pid, :dictionary)],
          dictionary[:"$initial_call"] == {LoopexDaemon.Listener, :init, 1},
          owner in Keyword.get(dictionary, :"$ancestors", []),
          do: pid

    Process.exit(listener, :kill)
    send(writer, :release_write)

    {:ok, failed} = LoopexDaemon.ExitStatus.fetch(:listener_start_failed)
    assert Task.await(task, 60_000) == failed

    assert {:error, _refused} =
             :gen_tcp.connect({:local, options[:socket_path]}, 0, [:binary], 500)
  end

  defp holding_device(test) do
    receive do
      {:io_request, from, reply_as, {:put_chars, _encoding, _chars}} ->
        send(test, {:readiness_held, self()})

        receive do
          :release_write -> :ok
        end

        send(from, {:io_reply, reply_as, :ok})
        holding_device(test)

      {:io_request, from, reply_as, _request} ->
        send(from, {:io_reply, reply_as, {:error, :request}})
        holding_device(test)
    end
  end

  # Concept: a state root that cannot even be created refuses at the first
  # acquisition, the placement lock, and leaves nothing behind.
  test "a root that cannot be created refuses placement_lock_failed", %{options: options} do
    blocker = Path.join(Path.dirname(options[:state_root]), "a-file")
    File.write!(blocker, "not a directory")
    root = Path.join(blocker, "s")

    options =
      Keyword.merge(options,
        state_root: root,
        socket_path: Path.join([root, "daemon", "d.sock"])
      )

    {:ok, failed} = LoopexDaemon.ExitStatus.fetch(:placement_lock_failed)
    {:ok, output} = StringIO.open("")
    assert Sentinel.run(options, output: output, install_signals: false) == failed
    assert StringIO.contents(output) == {"", ""}
    assert File.read!(blocker) == "not a directory"
  end

  # Concept: the daemon owner keeps no copy of the provider credential once
  # startup begins. A credential-plane step that fails leaves no credential
  # bytes in the owner's state; the ready-daemon test pins the running state.
  #
  # Technical depth: the failed owner is inside its startup callback until it
  # stops, so its state is read from a call trace of `finish_startup_failure/2`
  # on every new process. The module is loaded first, since a pattern set on
  # an unloaded module matches nothing.
  # The synthetic key is over custody's size bound, so custody refuses it and
  # the plane step fails with `credential_plane_start_failed`.
  test "the daemon owner holds no credential bytes after a failed credential plane",
       %{options: options} do
    marker = "f4-synthetic-provider-key-#{System.unique_integer([:positive])}"
    oversized = marker <> String.duplicate("x", 65_536)
    tracer = self()

    Code.ensure_loaded!(LoopexDaemon.Service)

    assert :erlang.trace_pattern(
             {LoopexDaemon.Service, :finish_startup_failure, 2},
             true,
             [:local]
           ) == 1

    :erlang.trace(:new_processes, true, [:call, {:tracer, tracer}])

    on_exit(fn ->
      :erlang.trace_pattern({LoopexDaemon.Service, :finish_startup_failure, 2}, false, [:local])
    end)

    {:ok, failed} = LoopexDaemon.ExitStatus.fetch(:credential_plane_start_failed)
    {:ok, output} = StringIO.open("")

    assert Sentinel.run(Keyword.put(options, :credential, oversized),
             output: output,
             install_signals: false
           ) == failed

    :erlang.trace(:new_processes, false, [:call])

    assert_receive {:trace, _owner, :call,
                    {LoopexDaemon.Service, :finish_startup_failure,
                     [failed_state, {:fatal, :credential_plane_start_failed}]}},
                   1_000

    assert :binary.match(:erlang.term_to_binary(failed_state), marker) == :nomatch
  end

  # Concept: a create replayed on a state root that an earlier daemon lifetime
  # already created the session on is answered with the recorded result, and
  # activates nothing: the session is dormant in this lifetime until a resume.
  # This is the mechanism behind the maximum-population test's intermittent
  # `session_dormant`: a crashed earlier run left its root behind under a
  # reused name, so every create on it was such a replay.
  #
  # Technical depth: two daemons run in turn on one root. The second
  # daemon's create of the same command answers `accepted` with the same
  # session identity, and an attach to it is refused `session_dormant`.
  @tag timeout: 90_000
  test "a create replayed in a later daemon lifetime leaves its session dormant",
       %{options: options} do
    create = fn client ->
      :ok =
        send_frame(client, %{
          "method" => "session.create",
          "request_id" => "create",
          "command_id" => Wire.encode_identity("replayed-create"),
          "session_options" => %{}
        })

      assert [%{"status" => "accepted", "session_id" => session_id}] = receive_records(client, 1)
      session_id
    end

    attach = fn client, session_id ->
      :ok =
        send_frame(client, %{
          "method" => "session.attach",
          "request_id" => "attach",
          "session_id" => session_id
        })

      receive_records(client, 1)
    end

    first = start_daemon(options)
    _ready = await_ready(first.output)
    client = initialized(options[:socket_path])
    session_id = create.(client)
    assert [%{"type" => "snapshot"}] = attach.(client, session_id)
    :socket.close(client)
    send(first.sentinel, {:daemon_signal, first.owner_ref, :sigterm})
    assert Task.await(first.task, 60_000) == 0

    second = start_daemon(options)
    _ready = await_ready(second.output)
    client = initialized(options[:socket_path])
    assert create.(client) == session_id
    assert [%{"code" => "session_dormant"}] = attach.(client, session_id)
    :socket.close(client)
    send(second.sentinel, {:daemon_signal, second.owner_ref, :sigterm})
    assert Task.await(second.task, 60_000) == 0
  end

  # Concept: two daemons started at the same moment on one root produce one
  # daemon: exactly one reaches readiness and the other loses at the
  # placement lock without disturbing it.
  test "simultaneous starts on one root yield exactly one daemon", %{options: options} do
    parent = self()

    starts =
      for index <- 1..2 do
        Task.async(fn ->
          {:ok, output} = StringIO.open("")

          status =
            Sentinel.run(options, output: output, install_signals: false, notify: parent)

          {index, status, StringIO.contents(output)}
        end)
      end

    {:ok, active} = LoopexDaemon.ExitStatus.fetch(:placement_active)

    # The loser ends on its own; the winner is stopped once the loser has.
    {loser, [winner]} =
      case Task.yield_many(starts, 30_000) |> Enum.split_with(fn {_task, result} -> result end) do
        {[{_task, {:ok, result}}], [{task, nil}]} -> {result, [task]}
      end

    assert {_index, ^active, {"", ""}} = loser

    # Both sentinels announced themselves; the stop reaches whichever is live.
    for _announced <- 1..2 do
      assert_receive {:loopex_daemon_sentinel, sentinel, owner_ref, _owner}, 1_000
      send(sentinel, {:daemon_signal, owner_ref, :sigterm})
    end

    assert {_index, 0, {"", readiness}} = Task.await(winner, 30_000)
    assert readiness =~ ~s("record":"daemon_ready")
  end

  test "a second daemon on a held root loses at the placement lock",
       %{options: options} do
    first = start_daemon(options)
    _ready = await_ready(first.output)
    {:ok, before} = File.lstat(options[:socket_path])

    {:ok, placement_active} = LoopexDaemon.ExitStatus.fetch(:placement_active)
    {:ok, output} = StringIO.open("")
    assert Sentinel.run(options, output: output, install_signals: false) == placement_active
    assert StringIO.contents(output) == {"", ""}
    assert {:ok, ^before} = File.lstat(options[:socket_path])

    send(first.sentinel, {:daemon_signal, first.owner_ref, :sigterm})
    assert Task.await(first.task, 30_000) == 0
  end

  test "a stop before readiness exits zero holding nothing", %{
    options: options,
    state_root: state_root
  } do
    {:ok, output} = StringIO.open("")
    test = self()

    task =
      Task.async(fn ->
        Sentinel.run(options,
          output: output,
          install_signals: false,
          notify: test
        )
      end)

    assert_receive {:loopex_daemon_sentinel, sentinel, owner_ref, _owner}, 1_000
    send(sentinel, {:daemon_signal, owner_ref, :sigterm})

    status = Task.await(task, 30_000)
    assert status == 0
    assert Placement.live_owner(state_root) == :none
  end

  @tag timeout: 90_000
  test "a relay that stops answering stop barriers ends the stop as relay_lost",
       %{options: options} do
    daemon = start_daemon(options)
    _ready = await_ready(daemon.output)
    client = initialized(options[:socket_path])

    collaboration = :sys.get_state(daemon.owner).pids.collaboration
    relay = LoopexDaemon.Owner.components(collaboration).relay
    :ok = :sys.suspend(relay)

    started = System.monotonic_time(:millisecond)
    send(daemon.sentinel, {:daemon_signal, daemon.owner_ref, :sigterm})

    {:ok, relay_lost} = LoopexDaemon.ExitStatus.fetch(:relay_lost)
    assert Task.await(daemon.task, 60_000) == relay_lost
    assert System.monotonic_time(:millisecond) - started < 45_000

    # The relay is killed as fatal teardown, so the registry survives it and
    # the client learns why.
    assert [%{"type" => "daemon.stopping", "reason" => "fatal:relay_lost"}] =
             receive_records(client, 1)

    on_exit(fn -> Process.exit(collaboration, :kill) end)
  end

  # Concept: the transport cut is one five-second deadline begun before the
  # relay cut. A registry that never answers its gate ends the stop as
  # `connections_lost` at that deadline, not as `relay_lost` and not after a
  # fresh clock.
  #
  # Technical depth: the registry is suspended before `SIGTERM`, so the relay
  # acknowledges the cut and the gate request waits out the shared instant.
  # The exit class separates this from a relay that missed the cut; the
  # shared-deadline case below proves the gate waits on the cut's own clock.
  @tag timeout: 90_000
  test "a registry that misses the transport gate ends the stop as connections_lost",
       %{options: options} do
    daemon = start_daemon(options)
    _ready = await_ready(daemon.output)
    _client = initialized(options[:socket_path])

    collaboration = :sys.get_state(daemon.owner).pids.collaboration
    registry = LoopexDaemon.Owner.components(collaboration).registry
    :ok = :sys.suspend(registry)

    started = System.monotonic_time(:millisecond)
    send(daemon.sentinel, {:daemon_signal, daemon.owner_ref, :sigterm})

    {:ok, connections_lost} = LoopexDaemon.ExitStatus.fetch(:connections_lost)
    assert Task.await(daemon.task, 60_000) == connections_lost
    elapsed = System.monotonic_time(:millisecond) - started
    assert elapsed >= 4_900
    assert elapsed < 15_000
  end

  # Concept: the relay acknowledgement and the registry gate share one clock.
  # A relay that answers late leaves the registry only what remains of the
  # five seconds, never a fresh five.
  #
  # Technical depth: the relay is held for about three seconds and the
  # registry throughout. The collaboration owner kills the registry when the
  # shared deadline passes, which closes every client socket, so the socket's
  # close time is the owner's decision time: about five seconds after
  # `SIGTERM`, where a gate given its own five seconds would close at about
  # eight.
  @tag timeout: 90_000
  test "a late relay leaves the registry gate only the rest of the shared deadline",
       %{options: options} do
    daemon = start_daemon(options)
    _ready = await_ready(daemon.output)
    client = initialized(options[:socket_path])

    collaboration = :sys.get_state(daemon.owner).pids.collaboration
    components = LoopexDaemon.Owner.components(collaboration)
    :ok = :sys.suspend(components.relay)
    :ok = :sys.suspend(components.registry)

    started = System.monotonic_time(:millisecond)
    send(daemon.sentinel, {:daemon_signal, daemon.owner_ref, :sigterm})
    Process.sleep(3_000)
    :ok = :sys.resume(components.relay)

    assert :closed = await_socket_closed(client, 15_000)
    closed = System.monotonic_time(:millisecond) - started
    assert closed >= 4_900
    assert closed < 6_500

    {:ok, connections_lost} = LoopexDaemon.ExitStatus.fetch(:connections_lost)
    assert Task.await(daemon.task, 60_000) == connections_lost
  end

  # Concept: a collaboration owner that cannot answer never takes the daemon
  # owner down with it: the transport cut decides `relay_lost` at its deadline
  # and the fail-stop still stops the executor and Store.
  #
  # Technical depth: the collaboration owner is suspended before `SIGTERM`.
  # The daemon owner makes no call to it before the cut clock starts, so the
  # cut's own helper is what waits, and the daemon exits `relay_lost` rather
  # than `owner_lost`, with ordinary executor and Store stops.
  @tag timeout: 90_000
  test "a suspended collaboration owner ends the stop as relay_lost with cleanup",
       %{options: options} do
    daemon = start_daemon(options)
    _ready = await_ready(daemon.output)
    _client = initialized(options[:socket_path])

    owner_state = :sys.get_state(daemon.owner)
    collaboration = owner_state.pids.collaboration
    executor_monitor = Process.monitor(owner_state.pids.executor)
    store_monitor = Process.monitor(owner_state.pids.store)
    :ok = :sys.suspend(collaboration)
    on_exit(fn -> Process.exit(collaboration, :kill) end)

    send(daemon.sentinel, {:daemon_signal, daemon.owner_ref, :sigterm})

    {:ok, relay_lost} = LoopexDaemon.ExitStatus.fetch(:relay_lost)
    assert Task.await(daemon.task, 60_000) == relay_lost
    assert_receive {:DOWN, ^executor_monitor, :process, _executor, executor_reason}, 1_000
    assert_receive {:DOWN, ^store_monitor, :process, _store, store_reason}, 1_000
    refute executor_reason == :killed
    refute store_reason == :killed
  end

  # Concept: a relay that dies on its own is reported, not fatal to the
  # collaboration owner, so the registry survives to tell every client why
  # whatever order its exit and any teardown mark arrive in.
  #
  # Technical depth: the relay is killed directly while serving, so its exit
  # reaches the collaboration owner before the daemon owner has sent any mark.
  test "a relay lost while serving still gives clients fatal:relay_lost",
       %{options: options} do
    daemon = start_daemon(options)
    _ready = await_ready(daemon.output)
    client = initialized(options[:socket_path])

    owner_state = :sys.get_state(daemon.owner)
    on_exit(fn -> Process.exit(owner_state.pids.collaboration, :kill) end)
    Process.exit(owner_state.relay, :kill)

    assert [%{"type" => "daemon.stopping", "reason" => "fatal:relay_lost"}] =
             receive_records(client, 1)

    {:ok, relay_lost} = LoopexDaemon.ExitStatus.fetch(:relay_lost)
    assert Task.await(daemon.task, 60_000) == relay_lost
  end

  # Concept: a relay lost after the drain has answered still ends the stop with
  # its class; the check made before reporting success reads the collaboration
  # owner's relay-loss report as well as linked exits.
  #
  # Technical depth: a debug hook kills the relay as the collaboration owner
  # receives the relay's tearing-down acknowledgement, so the owner answers the
  # drain and only then handles the relay's exit and reports it.
  @tag timeout: 90_000
  test "a relay lost as the drain completes ends the stop as relay_lost, not success",
       %{options: options} do
    daemon = start_daemon(options)
    _ready = await_ready(daemon.output)
    _client = initialized(options[:socket_path])

    owner_state = :sys.get_state(daemon.owner)
    collaboration = owner_state.pids.collaboration
    relay = owner_state.relay
    on_exit(fn -> Process.exit(collaboration, :kill) end)

    :ok =
      :sys.install(
        collaboration,
        {fn
           :waiting, {:in, {:relay_barrier_ack, _ref, :tearing_down, _payload}}, _state ->
             Process.exit(relay, :kill)
             :done

           :waiting, _event, _state ->
             :waiting
         end, :waiting}
      )

    send(daemon.sentinel, {:daemon_signal, daemon.owner_ref, :sigterm})

    {:ok, relay_lost} = LoopexDaemon.ExitStatus.fetch(:relay_lost)
    assert Task.await(daemon.task, 60_000) == relay_lost
  end

  # Concept: until success is reported, a component that dies during the
  # orderly stop's own teardown is that component's loss, not a clean exit.
  #
  # Technical depth: the teardown stops the collaboration owner first and the
  # Store last. The test kills the Store the moment the collaboration owner is
  # down, so the Store is lost after the drain's final check and before its
  # own stop; the daemon must exit `store_lost`, not `0`.
  @tag timeout: 90_000
  test "a Store lost during the orderly teardown ends the stop as store_lost, not success",
       %{options: options} do
    daemon = start_daemon(options)
    _ready = await_ready(daemon.output)
    _client = initialized(options[:socket_path])

    owner_state = :sys.get_state(daemon.owner)
    collaboration_monitor = Process.monitor(owner_state.pids.collaboration)
    store = owner_state.pids.store

    send(daemon.sentinel, {:daemon_signal, daemon.owner_ref, :sigterm})
    assert_receive {:DOWN, ^collaboration_monitor, :process, _collaboration, _reason}, 30_000
    Process.exit(store, :kill)

    {:ok, store_lost} = LoopexDaemon.ExitStatus.fetch(:store_lost)
    assert Task.await(daemon.task, 60_000) == store_lost
  end

  # Concept: a collaboration owner lost after the last startup checkpoint never
  # takes the daemon owner down with a call: readiness uses what startup
  # already obtained, and the loss is classified.
  #
  # Technical depth: the collaboration owner is killed as soon as the daemon
  # owner has started it, so any later synchronous call to it would exit the
  # daemon owner and the sentinel would report `owner_lost`.
  @tag timeout: 90_000
  test "a collaboration owner lost during startup is daemon_services_start_failed",
       %{options: options} do
    {:ok, output} = StringIO.open("")
    test = self()

    task =
      Task.async(fn ->
        Sentinel.run(options, output: output, install_signals: false, notify: test)
      end)

    assert_receive {:loopex_daemon_sentinel, _sentinel, _owner_ref, owner}, 1_000
    collaboration = await_collaboration(owner)
    Process.exit(collaboration, :kill)

    # Lost before readiness it is a startup failure, whose reverse cleanup
    # releases the root; lost just after, the running classifier names the
    # relay it owned. Never `owner_lost`, which would mean the daemon owner
    # itself died on a call.
    {:ok, start_failed} = LoopexDaemon.ExitStatus.fetch(:daemon_services_start_failed)
    {:ok, relay_lost} = LoopexDaemon.ExitStatus.fetch(:relay_lost)
    status = Task.await(task, 60_000)
    assert status in [start_failed, relay_lost]

    if status == start_failed,
      do: assert(Placement.live_owner(options[:state_root]) == :none)
  end

  # Concept: after its one guarded call at startup, the daemon owner never
  # calls the collaboration owner outside a stop wait, so a collaboration
  # owner that stops answering can never exit the daemon owner with a call.
  #
  # Technical depth: the collaboration owner's received messages are traced
  # from the moment it appears. Through readiness and a full orderly stop it
  # receives at most one `:components` call from the daemon owner; the earlier
  # code made one at startup, one for the listener and one for readiness.
  @tag timeout: 90_000
  test "the daemon owner calls the collaboration owner at most once outside stop waits",
       %{options: options} do
    {:ok, output} = StringIO.open("")
    test = self()

    task =
      Task.async(fn ->
        Sentinel.run(options, output: output, install_signals: false, notify: test)
      end)

    assert_receive {:loopex_daemon_sentinel, sentinel, owner_ref, owner}, 1_000
    collaboration = await_collaboration(owner)
    1 = :erlang.trace(collaboration, true, [:receive])
    _ready = await_ready(output)

    send(sentinel, {:daemon_signal, owner_ref, :sigterm})
    assert Task.await(task, 60_000) == 0

    component_calls =
      Stream.repeatedly(fn ->
        receive do
          {:trace, ^collaboration, :receive, {:"$gen_call", {^owner, _tag}, :components}} -> :call
          {:trace, ^collaboration, :receive, _other} -> :other
        after
          0 -> :done
        end
      end)
      |> Enum.take_while(&(&1 != :done))
      |> Enum.count(&(&1 == :call))

    assert component_calls <= 1
  end

  # Concept: a registry that cannot answer its own bounded close is the
  # connections' loss, not the relay's, and it cannot hold the stop open.
  #
  # Technical depth: a debug hook suspends the registry as the collaboration
  # owner receives the orderly close call. The registry never answers, the
  # owner kills it after its deadline and the stop ends `connections_lost`.
  @tag timeout: 90_000
  test "a registry silent at the orderly close ends the stop as connections_lost",
       %{options: options} do
    daemon = start_daemon(options)
    _ready = await_ready(daemon.output)
    _client = initialized(options[:socket_path])

    owner_state = :sys.get_state(daemon.owner)
    collaboration = owner_state.pids.collaboration
    registry = owner_state.registry
    on_exit(fn -> Process.exit(collaboration, :kill) end)

    :ok =
      :sys.install(
        collaboration,
        {fn
           :waiting, {:in, {:"$gen_call", _from, {:close_connections, _record, _deadline}}}, _ ->
             :ok = :sys.suspend(registry)
             :done

           :waiting, _event, _state ->
             :waiting
         end, :waiting}
      )

    send(daemon.sentinel, {:daemon_signal, daemon.owner_ref, :sigterm})

    {:ok, connections_lost} = LoopexDaemon.ExitStatus.fetch(:connections_lost)
    assert Task.await(daemon.task, 60_000) == connections_lost
  end

  # Concept: the runtime tree is stopped on the shared teardown deadline, never
  # by an unbounded call; a tree still up at that instant is killed and the
  # stop ends `runtime_lost`, not a hang and not success.
  #
  # Technical depth: the runtime supervisor is suspended at the VM level as
  # the drain's last barrier is acknowledged, so it cannot serve the system
  # stop request; the teardown's bounded helper waits until the 2 s teardown
  # deadline, kills the tree and reports `runtime_lost`.
  @tag timeout: 90_000
  test "a runtime tree that cannot stop is killed at the teardown deadline as runtime_lost",
       %{options: options} do
    daemon = start_daemon(Keyword.put(options, :teardown_ms, 2_000))
    _ready = await_ready(daemon.output)
    _client = initialized(options[:socket_path])

    owner_state = :sys.get_state(daemon.owner)
    supervisor = owner_state.edges.runtime_supervisor
    on_exit(fn -> Process.exit(owner_state.pids.collaboration, :kill) end)
    suspend_after_drain(owner_state.pids.collaboration, supervisor)

    started = System.monotonic_time(:millisecond)
    send(daemon.sentinel, {:daemon_signal, daemon.owner_ref, :sigterm})

    {:ok, runtime_lost} = LoopexDaemon.ExitStatus.fetch(:runtime_lost)
    assert Task.await(daemon.task, 60_000) == runtime_lost
    assert System.monotonic_time(:millisecond) - started < 30_000
    refute Process.alive?(supervisor)
  end

  # Concept: a component that does not stop by the shared teardown deadline is
  # killed then, and that is its own class: the stop does not report success
  # after a component it had to kill.
  #
  # Technical depth: the executor is suspended at the VM level as the drain's
  # last barrier is acknowledged, so its stop request waits out the 2 s
  # teardown deadline.
  @tag timeout: 90_000
  test "a component that misses the teardown deadline ends the stop with its class",
       %{options: options} do
    daemon = start_daemon(Keyword.put(options, :teardown_ms, 2_000))
    _ready = await_ready(daemon.output)
    _client = initialized(options[:socket_path])

    owner_state = :sys.get_state(daemon.owner)
    executor = owner_state.pids.executor
    suspend_after_drain(owner_state.pids.collaboration, executor)

    send(daemon.sentinel, {:daemon_signal, daemon.owner_ref, :sigterm})

    {:ok, executor_lost} = LoopexDaemon.ExitStatus.fetch(:executor_lost)
    assert Task.await(daemon.task, 60_000) == executor_lost
    refute Process.alive?(executor)
  end

  # Concept: during active quiesce, losing the captured Control while the
  # runtime root still lives leaves no trustworthy census: `drain_failed`, not
  # `runtime_lost`.
  #
  # Technical depth: Control is suspended so core quiesce blocks inside the
  # drain helper; once the daemon owner is waiting on it, Control is killed.
  # The runtime root restarts it and stays alive.
  @tag timeout: 90_000
  test "Control lost during active quiesce ends the stop as drain_failed",
       %{options: options} do
    daemon = start_daemon(options)
    _ready = await_ready(daemon.output)
    _client = initialized(options[:socket_path])

    owner_state = :sys.get_state(daemon.owner)
    {:ok, children} = Loopex.Runtime.children(owner_state.edges.runtime)
    :ok = :sys.suspend(children.control)
    on_exit(fn -> Process.exit(owner_state.pids.collaboration, :kill) end)

    send(daemon.sentinel, {:daemon_signal, daemon.owner_ref, :sigterm})
    assert await_quiesce_wait(daemon.owner)
    Process.exit(children.control, :kill)

    {:ok, drain_failed} = LoopexDaemon.ExitStatus.fetch(:drain_failed)
    assert Task.await(daemon.task, 60_000) == drain_failed
    assert Process.alive?(owner_state.edges.runtime_supervisor)
  end

  # Concept: the Store's stop is its own fixed 30 s phase; a Store still
  # running at its end is killed and the stop ends `store_lost`, not success.
  #
  # Technical depth: the Store is suspended at the VM level as the drain's last
  # barrier is acknowledged, so its stop request waits out the 30 s phase.
  @tag timeout: 120_000
  test "a Store that misses its 30 s stop phase ends the stop as store_lost",
       %{options: options} do
    daemon = start_daemon(Keyword.put(options, :teardown_ms, 2_000))
    _ready = await_ready(daemon.output)
    _client = initialized(options[:socket_path])

    owner_state = :sys.get_state(daemon.owner)
    store = owner_state.pids.store
    suspend_after_drain(owner_state.pids.collaboration, store)

    started = System.monotonic_time(:millisecond)
    send(daemon.sentinel, {:daemon_signal, daemon.owner_ref, :sigterm})

    {:ok, store_lost} = LoopexDaemon.ExitStatus.fetch(:store_lost)
    assert Task.await(daemon.task, 90_000) == store_lost
    assert System.monotonic_time(:millisecond) - started >= 30_000
    refute Process.alive?(store)
  end

  # Concept: a component that dies on a call its callee never answered names
  # the callee: a listener that died waiting on the connection registry is
  # `connections_lost`, not `listener_lost`.
  #
  # Technical depth: the registry is suspended and a client connects, so the
  # listener's reservation call times out naming the registry.
  @tag timeout: 90_000
  test "a listener that dies waiting on the registry ends the daemon connections_lost",
       %{options: options} do
    daemon = start_daemon(options)
    _ready = await_ready(daemon.output)

    owner_state = :sys.get_state(daemon.owner)
    :ok = :sys.suspend(owner_state.registry)
    on_exit(fn -> Process.exit(owner_state.pids.collaboration, :kill) end)

    {:ok, socket} = :socket.open(:local, :stream, :default)
    :ok = await_connect(socket, options[:socket_path], 100)

    {:ok, connections_lost} = LoopexDaemon.ExitStatus.fetch(:connections_lost)
    assert Task.await(daemon.task, 60_000) == connections_lost
    :socket.close(socket)
  end

  # Concept: a component lost while a later stop barrier is held keeps its own
  # class; the barrier timing out behind it cannot rename it `relay_lost`.
  #
  # Technical depth: the collaboration owner is parked as the lease-freeze
  # barrier reaches it, then the Store is killed. The daemon owner is waiting
  # on the drain helper and consumes the Store's exit at once, well inside the
  # freeze barrier's five seconds.
  @tag timeout: 90_000
  test "a Store lost during a held freeze barrier ends the stop as store_lost",
       %{options: options} do
    daemon = start_daemon(options)
    _ready = await_ready(daemon.output)
    _client = initialized(options[:socket_path])

    owner_state = :sys.get_state(daemon.owner)
    collaboration = owner_state.pids.collaboration
    test_pid = self()

    :ok =
      :sys.install(
        collaboration,
        {fn
           :waiting,
           {:in, {:"$gen_call", _from, {:relay_barrier, {:freeze_lease_ops, _}, _}}},
           _state ->
             send(test_pid, :freeze_parked)

             receive do
               :continue_freeze -> :done
             end

           :waiting, _event, _state ->
             :waiting
         end, :waiting}
      )

    on_exit(fn ->
      send(collaboration, :continue_freeze)
      Process.exit(collaboration, :kill)
    end)

    send(daemon.sentinel, {:daemon_signal, daemon.owner_ref, :sigterm})
    assert_receive :freeze_parked, 10_000

    started = System.monotonic_time(:millisecond)
    Process.exit(owner_state.pids.store, :kill)

    {:ok, store_lost} = LoopexDaemon.ExitStatus.fetch(:store_lost)
    assert Task.await(daemon.task, 60_000) == store_lost
    assert System.monotonic_time(:millisecond) - started < 4_000
  end

  # Concept: the uninitialized-peer sweep is part of the transport cut. A peer
  # the registry cannot close by the cut deadline ends the stop as
  # `connections_lost`; the stop never reaches core quiesce with the sweep
  # unproved.
  #
  # Technical depth: a raw peer connects and never initializes; its connection
  # process is suspended, so the sweep's abort is never acted on and the
  # registry never acknowledges an empty set. The gate and listener reap
  # succeed, which leaves the sweep as the only missing acknowledgement.
  @tag timeout: 90_000
  test "an uninitialized peer the sweep cannot close ends the stop as connections_lost",
       %{options: options} do
    daemon = start_daemon(options)
    _ready = await_ready(daemon.output)
    _client = initialized(options[:socket_path])

    {:ok, peer} = :socket.open(:local, :stream, :default)
    :ok = await_connect(peer, options[:socket_path], 100)

    collaboration = :sys.get_state(daemon.owner).pids.collaboration
    registry = LoopexDaemon.Owner.components(collaboration).registry
    connection = await_uninitialized_connection(registry)
    :ok = :sys.suspend(connection)

    started = System.monotonic_time(:millisecond)
    send(daemon.sentinel, {:daemon_signal, daemon.owner_ref, :sigterm})

    {:ok, connections_lost} = LoopexDaemon.ExitStatus.fetch(:connections_lost)
    assert Task.await(daemon.task, 60_000) == connections_lost
    elapsed = System.monotonic_time(:millisecond) - started
    assert elapsed >= 4_900
    assert elapsed < 15_000
    :socket.close(peer)
  end

  # Concept: only the listener's exact linked exit proves no later accept, and
  # it must arrive inside the transport cut; a missing exit is
  # `listener_lost`.
  #
  # Technical depth: the owner's listener entry is swapped for an unlinked
  # decoy, so the kill the stop sends produces no linked exit and the wait
  # reaches the shared deadline. The real listener is left running until the
  # fail-stop teardown, as it would be if its exit were lost.
  @tag timeout: 90_000
  test "a listener exit missing at the transport cut ends the stop as listener_lost",
       %{options: options} do
    daemon = start_daemon(options)
    _ready = await_ready(daemon.output)
    _client = initialized(options[:socket_path])

    decoy = spawn(fn -> Process.sleep(:infinity) end)
    listener = :sys.get_state(daemon.owner).pids.listener

    :sys.replace_state(daemon.owner, fn state ->
      listener = state.pids.listener

      %{
        state
        | pids: Map.put(state.pids, :listener, decoy),
          components:
            state.components
            |> Map.delete({:pid, listener})
            |> Map.put({:pid, decoy}, :listener)
      }
    end)

    started = System.monotonic_time(:millisecond)
    send(daemon.sentinel, {:daemon_signal, daemon.owner_ref, :sigterm})

    {:ok, listener_lost} = LoopexDaemon.ExitStatus.fetch(:listener_lost)
    assert Task.await(daemon.task, 60_000) == listener_lost
    elapsed = System.monotonic_time(:millisecond) - started
    assert elapsed >= 4_900
    assert elapsed < 15_000
    refute Process.alive?(decoy)

    # The untracked real listener is not stopped by the fail-stop teardown.
    Process.exit(listener, :kill)
  end

  # Concept: a lease freeze left with unfinished registry work ends the stop
  # as `connections_lost`, not `relay_lost`, and core quiesce never starts.
  #
  # Technical depth: a client holds a session's lease. The collaboration
  # owner is parked by a debug hook as the freeze call reaches it; while
  # parked the registry is suspended and the lease owner killed, so after the
  # freeze is acknowledged the lost owner's mirror pop waits on the registry
  # through the five-second freeze deadline.
  @tag timeout: 90_000
  test "a freeze left with unfinished registry work ends the stop as connections_lost",
       %{options: options} do
    daemon = start_daemon(options)
    _ready = await_ready(daemon.output)
    client = initialized(options[:socket_path])

    :ok =
      send_frame(client, %{
        "method" => "session.create",
        "request_id" => "create",
        "command_id" => Wire.encode_identity("freeze-create"),
        "session_options" => %{"purpose" => "freeze"}
      })

    assert [%{"status" => "accepted", "session_id" => encoded}] = receive_records(client, 1)

    :ok =
      send_frame(client, %{
        "method" => "session.acquire_control",
        "request_id" => "acquire",
        "session_id" => encoded
      })

    assert [%{"request_id" => "acquire", "type" => "result"}] = receive_records(client, 1)
    collaboration = :sys.get_state(daemon.owner).pids.collaboration
    registry = LoopexDaemon.Owner.components(collaboration).registry
    [lease_owner] = for {_session_id, row} <- :sys.get_state(collaboration).owners, do: row.pid
    test_pid = self()

    :ok =
      :sys.install(
        collaboration,
        {fn
           :waiting,
           {:in, {:"$gen_call", _from, {:relay_barrier, {:freeze_lease_ops, _}, _}}},
           _state ->
             send(test_pid, :freeze_parked)

             receive do
               :continue_freeze -> :done
             end

           :waiting, _event, _state ->
             :waiting
         end, :waiting}
      )

    send(daemon.sentinel, {:daemon_signal, daemon.owner_ref, :sigterm})
    assert_receive :freeze_parked, 10_000
    :ok = :sys.suspend(registry)
    lease_owner_monitor = Process.monitor(lease_owner)
    Process.exit(lease_owner, :kill)
    assert_receive {:DOWN, ^lease_owner_monitor, :process, ^lease_owner, :killed}, 500
    # The owner's exit must already be queued behind the parked freeze call.
    assert :ok = await_queued_exit(collaboration, lease_owner)
    send(collaboration, :continue_freeze)

    {:ok, connections_lost} = LoopexDaemon.ExitStatus.fetch(:connections_lost)
    assert Task.await(daemon.task, 60_000) == connections_lost
  end

  # Concept: a fail-stop cannot be held open by a silent registry: the
  # executor and a live Store are still stopped, each inside its bound, well
  # before the sentinel's 35-second halt.
  #
  # Technical depth: the registry is suspended, then the session index is
  # killed. The owner only messages the registry, so it goes straight on to
  # stop the live executor and the healthy Store; both end with an ordinary
  # stop rather than a kill, and the daemon reports `session_index_lost`
  # within seconds.
  @tag timeout: 90_000
  test "a silent registry cannot keep a fail-stop from stopping the executor and Store",
       %{options: options} do
    daemon = start_daemon(options)
    _ready = await_ready(daemon.output)
    _client = initialized(options[:socket_path])

    owner_state = :sys.get_state(daemon.owner)
    executor = owner_state.pids.executor
    store = owner_state.pids.store
    executor_monitor = Process.monitor(executor)
    store_monitor = Process.monitor(store)
    :ok = :sys.suspend(owner_state.registry)

    # A fail-stop leaves the collaboration owner for the VM halt, which a test
    # VM never performs.
    on_exit(fn ->
      Process.exit(owner_state.registry, :kill)
      Process.exit(owner_state.pids.collaboration, :kill)
    end)

    started = System.monotonic_time(:millisecond)
    Process.exit(owner_state.pids.index, :kill)

    assert_receive {:DOWN, ^executor_monitor, :process, ^executor, executor_reason}, 10_000
    assert_receive {:DOWN, ^store_monitor, :process, ^store, store_reason}, 10_000
    refute executor_reason == :killed
    refute store_reason == :killed

    {:ok, session_index_lost} = LoopexDaemon.ExitStatus.fetch(:session_index_lost)
    assert Task.await(daemon.task, 60_000) == session_index_lost
    assert System.monotonic_time(:millisecond) - started < 10_000
    refute Process.alive?(owner_state.relay)
  end

  # Concept: the session index is a linked running component, so losing it is
  # a daemon failure with its own class rather than a daemon that stays ready
  # while every create, list and status request fails.
  #
  # Technical depth: the index the service started is killed while an
  # initialized client is connected. The client receives `daemon.stopping`
  # with `fatal:session_index_lost` and the sentinel exits
  # `session_index_lost` (111).
  test "losing the session index fail-stops with session_index_lost",
       %{options: options} do
    daemon = start_daemon(options)
    _ready = await_ready(daemon.output)
    client = initialized(options[:socket_path])

    index = :sys.get_state(daemon.owner).pids.index
    Process.exit(index, :kill)

    assert [%{"type" => "daemon.stopping", "reason" => "fatal:session_index_lost"}] =
             receive_records(client, 1)

    {:ok, session_index_lost} = LoopexDaemon.ExitStatus.fetch(:session_index_lost)
    assert session_index_lost == 111
    assert Task.await(daemon.task, 60_000) == session_index_lost
  end

  test "losing the Store fail-stops with its class and tells the client",
       %{options: options} do
    daemon = start_daemon(options)
    _ready = await_ready(daemon.output)
    client = initialized(options[:socket_path])

    store = :sys.get_state(daemon.owner).pids.store
    Process.exit(store, :kill)

    assert [%{"type" => "daemon.stopping", "reason" => "store_lost"}] =
             receive_records(client, 1)

    {:ok, store_lost} = LoopexDaemon.ExitStatus.fetch(:store_lost)
    assert Task.await(daemon.task, 40_000) == store_lost
  end

  # Concept: the daemon's routes are bound to the runtime's exact Control and
  # EventDispatcher, so losing either while serving fail-stops `runtime_lost`
  # and tells the client.
  #
  # Technical depth: each case kills one exact runtime child. The runtime's own
  # supervisor would restart it, so only the daemon's monitor can notice; the
  # client receives `daemon.stopping` naming `fatal:runtime_lost` and the
  # daemon exits with that class. A fail-stop keeps host placement until the
  # process halts, so a successor is proved by a separate operating-system
  # process in `apps/loopex_cli/test/daemon_command_test.exs`, not here.
  for child <- [:control, :dispatcher] do
    test "losing the runtime's #{child} fail-stops runtime_lost",
         %{options: options} do
      daemon = start_daemon(options)
      _ready = await_ready(daemon.output)
      client = initialized(options[:socket_path])

      {:ok, children} = Loopex.Runtime.children(:sys.get_state(daemon.owner).edges.runtime)
      Process.exit(Map.fetch!(children, unquote(child)), :kill)

      assert [%{"type" => "daemon.stopping", "reason" => "fatal:runtime_lost"}] =
               receive_records(client, 1)

      {:ok, runtime_lost} = LoopexDaemon.ExitStatus.fetch(:runtime_lost)
      assert Task.await(daemon.task, 40_000) == runtime_lost
    end
  end

  # Concept: a component lost while an orderly stop drains ends the stop with
  # that component's class; the stop never reports success.
  #
  # Technical depth: the runtime's Control is suspended so core quiesce blocks
  # inside the owner's unlinked helper; once the owner is waiting on that
  # helper, the Store or the EventDispatcher is killed. The owner consumes the
  # exit or monitor at once, kills the helper and exits with `store_lost` or
  # `runtime_lost`, and the client hears that class rather than
  # `operator_stop`.
  for {target, class, reason} <- [
        {:store, :store_lost, "store_lost"},
        {:dispatcher, :runtime_lost, "fatal:runtime_lost"}
      ] do
    test "losing the #{target} while quiesce drains ends the stop as #{class}",
         %{options: options} do
      daemon = start_daemon(options)
      _ready = await_ready(daemon.output)
      client = initialized(options[:socket_path])
      owner_state = :sys.get_state(daemon.owner)
      {:ok, children} = Loopex.Runtime.children(owner_state.edges.runtime)
      :ok = :sys.suspend(children.control)

      send(daemon.sentinel, {:daemon_signal, daemon.owner_ref, :sigterm})
      assert await_quiesce_wait(daemon.owner)

      victim =
        case unquote(target) do
          :store -> owner_state.pids.store
          :dispatcher -> children.dispatcher
        end

      Process.exit(victim, :kill)

      {:ok, status} = LoopexDaemon.ExitStatus.fetch(unquote(class))
      assert Task.await(daemon.task, 40_000) == status

      assert [%{"type" => "daemon.stopping", "reason" => unquote(reason)}] =
               receive_records(client, 1)
    end
  end

  # The owner is waiting on core quiesce: it is inside the shared stop wait for
  # the drain, and its drain helper is inside `Loopex.Runtime.quiesce/1`.
  defp await_quiesce_wait(pid, attempts \\ 500)

  defp await_quiesce_wait(pid, attempts) when attempts > 0 do
    {:current_function, current} = Process.info(pid, :current_function)
    {:current_stacktrace, stack} = Process.info(pid, :current_stacktrace)
    draining = Enum.any?(stack, &match?({LoopexDaemon.Service, :admitted_stop, 2, _}, &1))

    quiescing =
      Enum.any?(Process.list(), fn process ->
        case Process.info(process, :current_stacktrace) do
          {:current_stacktrace, frames} ->
            Enum.any?(frames, &match?({LoopexDaemon.Service, :quiesce, 1, _}, &1))

          nil ->
            false
        end
      end)

    if current == {LoopexDaemon.Service, :await_responsive, 4} and draining and quiescing do
      true
    else
      Process.sleep(10)
      await_quiesce_wait(pid, attempts - 1)
    end
  end

  defp await_quiesce_wait(_pid, 0), do: false

  defp await_queued_exit(pid, exited, attempts \\ 100)

  defp await_queued_exit(pid, exited, attempts) when attempts > 0 do
    {:messages, messages} = Process.info(pid, :messages)

    if Enum.any?(messages, &match?({:EXIT, ^exited, _reason}, &1)) do
      :ok
    else
      Process.sleep(5)
      await_queued_exit(pid, exited, attempts - 1)
    end
  end

  defp await_queued_exit(_pid, _exited, 0), do: {:error, :not_queued}

  # Suspends `target` at the VM level, where even system messages such as a
  # stop request wait, exactly as the collaboration owner receives the relay's
  # tearing-down acknowledgement: after the drain, before the teardown. The
  # test process holds the suspension, since a suspension ends with the
  # process that made it, and the collaboration owner waits until it is held.
  defp suspend_after_drain(collaboration, target) do
    test = self()

    spawn_link(fn ->
      receive do
        {:suspend_now, hook} ->
          true = :erlang.suspend_process(target)
          send(hook, :suspended)
          Process.sleep(:infinity)
      end
    end)
    |> then(&send(test, {:suspender, &1}))

    suspender =
      receive do
        {:suspender, pid} -> pid
      end

    :ok =
      :sys.install(
        collaboration,
        {fn
           :waiting, {:in, {:relay_barrier_ack, _ref, :tearing_down, _payload}}, _state ->
             send(suspender, {:suspend_now, self()})

             receive do
               :suspended -> :done
             end

           :waiting, _event, _state ->
             :waiting
         end, :waiting}
      )
  end

  defp await_collaboration(owner, attempts \\ 2_000)

  defp await_collaboration(owner, attempts) when attempts > 0 do
    case Process.info(owner, :links) do
      {:links, links} ->
        case Enum.find(links, &collaboration_owner?/1) do
          nil ->
            Process.sleep(1)
            await_collaboration(owner, attempts - 1)

          collaboration ->
            collaboration
        end

      nil ->
        flunk("daemon owner ended before starting its collaboration owner")
    end
  end

  defp await_collaboration(_owner, 0), do: flunk("collaboration owner never started")

  defp collaboration_owner?(pid) when is_pid(pid) do
    case Process.info(pid, :dictionary) do
      {:dictionary, dictionary} ->
        match?({LoopexDaemon.Owner, :init, 1}, Keyword.get(dictionary, :"$initial_call"))

      nil ->
        false
    end
  end

  defp collaboration_owner?(_port), do: false

  defp await_uninitialized_connection(registry, attempts \\ 500)

  defp await_uninitialized_connection(registry, attempts) when attempts > 0 do
    uninitialized =
      for {_token, %{initialized: false, connection_pid: pid}} <- :sys.get_state(registry).rows,
          is_pid(pid),
          do: pid

    case uninitialized do
      [connection] ->
        connection

      _none ->
        Process.sleep(10)
        await_uninitialized_connection(registry, attempts - 1)
    end
  end

  defp await_uninitialized_connection(_registry, 0),
    do: flunk("no uninitialized connection appeared")

  defp await_socket_closed(socket, timeout) do
    case :socket.recv(socket, 0, timeout) do
      {:ok, _bytes} -> await_socket_closed(socket, timeout)
      {:error, :closed} -> :closed
      {:error, :econnreset} -> :closed
      {:error, reason} -> {:error, reason}
    end
  end

  defp start_daemon(options) do
    {:ok, output} = StringIO.open("")
    test = self()

    task =
      Task.async(fn ->
        Sentinel.run(options, output: output, install_signals: false, notify: test)
      end)

    assert_receive {:loopex_daemon_sentinel, sentinel, owner_ref, owner}, 1_000
    %{task: task, sentinel: sentinel, owner_ref: owner_ref, owner: owner, output: output}
  end

  defp await_ready(output, attempts \\ 500)

  defp await_ready(output, attempts) when attempts > 0 do
    case StringIO.contents(output) do
      {"", line} when byte_size(line) > 0 ->
        assert String.ends_with?(line, "\n")
        JSON.decode!(line)

      _empty ->
        Process.sleep(10)
        await_ready(output, attempts - 1)
    end
  end

  defp await_ready(_output, 0), do: flunk("daemon never announced readiness")

  defp initialized(path) do
    {:ok, socket} = :socket.open(:local, :stream, :default)
    :ok = await_connect(socket, path, 100)

    :ok =
      send_frame(socket, %{
        "method" => "initialize",
        "request_id" => "init",
        "generations" => [V2.generation()],
        "capabilities" => []
      })

    assert [%{"type" => "initialized"}] = receive_records(socket, 1)
    socket
  end

  defp await_connect(socket, path, attempts) do
    case :socket.connect(socket, %{family: :local, path: path}) do
      :ok ->
        :ok

      {:error, _reason} when attempts > 0 ->
        Process.sleep(10)
        await_connect(socket, path, attempts - 1)

      {:error, reason} ->
        flunk("could not connect: #{inspect(reason)}")
    end
  end
end
