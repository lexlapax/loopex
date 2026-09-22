defmodule LoopexDaemon.OwnerTest do
  use ExUnit.Case, async: true
  @moduletag capture_log: true

  alias LoopexDaemon.{AdmissionRelay, ConnectionRegistry, LeaseOwner, Owner}

  defmodule ManualConnection do
    def start_link(options) do
      listener = Keyword.fetch!(options, :listener)

      pid =
        spawn_link(fn ->
          send(listener, {:manual_connection_started, self(), options})
          loop(listener, options)
        end)

      {:ok, pid}
    end

    defp loop(parent, options) do
      receive do
        {:manual_call, caller, reference, :promote} ->
          result =
            ConnectionRegistry.promote(
              Keyword.fetch!(options, :registry),
              Keyword.fetch!(options, :rollback_token),
              Keyword.fetch!(options, :connection_incarnation)
            )

          send(caller, {:manual_result, reference, result})
          loop(parent, options)

        {:manual_call, caller, reference, :initialize} ->
          result =
            ConnectionRegistry.initialize_complete(
              Keyword.fetch!(options, :registry),
              Keyword.fetch!(options, :rollback_token),
              Keyword.fetch!(options, :connection_incarnation)
            )

          send(caller, {:manual_result, reference, result})
          loop(parent, options)

        {:manual_call, caller, reference, {:register_relay, relay, recipient}} ->
          result =
            AdmissionRelay.register_connection(
              relay,
              Keyword.fetch!(options, :connection_incarnation),
              recipient
            )

          send(caller, {:manual_result, reference, result})
          loop(parent, options)

        {:connection_abort, _token, _reason} ->
          :ok

        message ->
          send(parent, {:manual_connection_message, self(), message})
          loop(parent, options)
      end
    end
  end

  test "the fixed owner publishes a grant before delivery and clears it before release" do
    owner = start_owner()
    components = Owner.components(owner)
    connection = initialized_connection(components)

    acquire_origin = {connection.incarnation, 0, 1}

    {acquire_worker, acquire_worker_incarnation} =
      start_worker(connection.pid, acquire_origin)

    assert {:ok, :proposed, lease_owner, owner_incarnation} =
             Owner.acquire_control(
               owner,
               acquire_origin,
               "acquire-1",
               "session",
               connection.pid,
               connection.incarnation,
               acquire_worker,
               acquire_worker_incarnation,
               now_ms() + 1_000
             )

    assert_receive {:worker_go, ^acquire_worker, ^acquire_origin}, 500

    assert_receive {:manual_connection_message, connection_pid,
                    {:relay_permit_result, ^acquire_origin, acquire_result}},
                   500

    assert connection_pid == connection.pid
    assert acquire_result["method"] == "session.acquire_control"
    writer_epoch = Base.url_decode64!(acquire_result["result"]["writer_epoch"], padding: false)

    assert %{granted_routes: 1, lease_operations: 0, mirror_operations: 0} =
             wait_for_owner_settlement(owner)

    assert %{phase: :held, held: true} = LeaseOwner.status(lease_owner)

    assert %{granted_routing_mirrors: 1, provisional_routing_mirrors: 0} =
             ConnectionRegistry.status(components.registry)

    release_origin = {connection.incarnation, 1, 1}

    {release_worker, release_worker_incarnation} =
      start_worker(connection.pid, release_origin)

    assert {:ok, :proposed, ^lease_owner, ^owner_incarnation} =
             Owner.release_control(
               owner,
               release_origin,
               "release-1",
               "session",
               connection.pid,
               connection.incarnation,
               release_worker,
               release_worker_incarnation,
               writer_epoch,
               now_ms() + 1_000
             )

    assert_receive {:worker_go, ^release_worker, ^release_origin}, 500

    assert_receive {:manual_connection_message, ^connection_pid,
                    {:relay_permit_result, ^release_origin, release_result}},
                   500

    assert release_result == %{
             "method" => "session.release_control",
             "request_id" => "release-1",
             "result" => %{"released" => true},
             "type" => "result"
           }

    assert %{granted_routes: 0, lease_operations: 0, mirror_operations: 0} =
             wait_for_owner_settlement(owner)

    assert %{phase: :released, held: false} = LeaseOwner.status(lease_owner)
    assert %{routing_mirrors: 0} = ConnectionRegistry.status(components.registry)

    refused_origin = {connection.incarnation, 2, 1}

    {refused_worker, refused_worker_incarnation} =
      start_worker(connection.pid, refused_origin)

    assert {:ok, :completed, ^lease_owner, ^owner_incarnation} =
             Owner.release_control(
               owner,
               refused_origin,
               "release-refused",
               "session",
               connection.pid,
               connection.incarnation,
               refused_worker,
               refused_worker_incarnation,
               writer_epoch,
               now_ms() + 1_000
             )

    assert_receive {:manual_connection_message, ^connection_pid,
                    {:relay_permit_result, ^refused_origin, refused_result}},
                   500

    assert refused_result["code"] == "control_not_held"
    assert %{lease_operations: 0, mirror_operations: 0} = Owner.status(owner)
  end

  test "a suspended registry cannot extend the mirror deadline" do
    owner = start_owner(mirror_deadline_ms: 30)
    components = Owner.components(owner)
    connection = initialized_connection(components)
    origin = {connection.incarnation, 0, 1}
    {worker, worker_incarnation} = start_worker(connection.pid, origin)

    :sys.suspend(components.registry)

    owner_monitor = Process.monitor(owner)

    assert {:ok, :proposed, lease_owner, owner_incarnation} =
             Owner.acquire_control(
               owner,
               origin,
               "deadline-acquire",
               "deadline-session",
               connection.pid,
               connection.incarnation,
               worker,
               worker_incarnation,
               now_ms() + 1_000
             )

    assert_receive {:worker_go, ^worker, ^origin}, 500
    assert is_pid(lease_owner)
    assert byte_size(owner_incarnation) == 16
    assert_receive {:DOWN, ^owner_monitor, :process, ^owner, :connections_lost}, 500
    refute Process.alive?(components.registry)
  end

  test "expiry clears the granted route before the lease becomes expired" do
    owner = start_owner(lease_term_ms: 30)
    components = Owner.components(owner)
    connection = initialized_connection(components)
    origin = {connection.incarnation, 0, 1}
    {worker, worker_incarnation} = start_worker(connection.pid, origin)

    assert {:ok, :proposed, lease_owner, _owner_incarnation} =
             Owner.acquire_control(
               owner,
               origin,
               "expiring-acquire",
               "expiring-session",
               connection.pid,
               connection.incarnation,
               worker,
               worker_incarnation,
               now_ms() + 1_000
             )

    assert_receive {:manual_connection_message, _, {:relay_permit_result, ^origin, _result}}, 500
    assert %{phase: :expired, held: false} = wait_for_expiry(owner, lease_owner)
    assert %{routing_mirrors: 0} = ConnectionRegistry.status(components.registry)
  end

  defp start_owner(options \\ []) do
    options =
      Keyword.merge(
        [admission_wait_ms: 1_000, connection_module: ManualConnection],
        options
      )

    start_supervised!({Owner, options}, restart: :temporary)
  end

  defp initialized_connection(components) do
    listener_incarnation = make_ref()

    assert {:ok, %{rollback_token: token}} =
             ConnectionRegistry.reserve(
               components.registry,
               self(),
               listener_incarnation,
               now_ms()
             )

    assert {:ok, pid, incarnation} =
             ConnectionRegistry.start_connection(components.registry, token)

    assert_receive {:manual_connection_started, ^pid, _options}, 500
    assert :ok = ConnectionRegistry.begin_transfer(components.registry, token, incarnation)
    assert :ok = ConnectionRegistry.transfer_result(components.registry, token, incarnation, :ok)
    assert :ok = manual_call(pid, :promote)
    assert :ok = manual_call(pid, :initialize)
    assert :ok = manual_call(pid, {:register_relay, components.relay, components.registry})
    %{pid: pid, incarnation: incarnation}
  end

  defp manual_call(pid, operation) do
    reference = make_ref()
    send(pid, {:manual_call, self(), reference, operation})

    receive do
      {:manual_result, ^reference, result} -> result
    after
      500 -> flunk("manual connection call did not answer")
    end
  end

  defp start_worker(connection, origin) do
    parent = self()
    worker_incarnation = incarnation()

    worker =
      spawn(fn ->
        monitor = Process.monitor(connection)

        receive do
          {:relay_go, ^origin, ^worker_incarnation} ->
            send(parent, {:worker_go, self(), origin})

          {:DOWN, ^monitor, :process, ^connection, _reason} ->
            :ok
        end
      end)

    {worker, worker_incarnation}
  end

  defp wait_for_owner_settlement(owner, attempts \\ 20)

  defp wait_for_owner_settlement(owner, attempts) when attempts > 0 do
    status = Owner.status(owner)

    if status.lease_operations == 0 and status.mirror_operations == 0 do
      status
    else
      Process.sleep(5)
      wait_for_owner_settlement(owner, attempts - 1)
    end
  end

  defp wait_for_owner_settlement(owner, 0), do: Owner.status(owner)

  defp wait_for_expiry(owner, lease_owner, attempts \\ 40)

  defp wait_for_expiry(owner, lease_owner, attempts) when attempts > 0 do
    lease_status = LeaseOwner.status(lease_owner)
    owner_status = Owner.status(owner)

    if lease_status.phase == :expired and owner_status.granted_routes == 0 and
         owner_status.mirror_operations == 0 do
      lease_status
    else
      Process.sleep(5)
      wait_for_expiry(owner, lease_owner, attempts - 1)
    end
  end

  defp wait_for_expiry(_owner, lease_owner, 0), do: LeaseOwner.status(lease_owner)

  defp incarnation, do: :crypto.strong_rand_bytes(16)
  defp now_ms, do: System.monotonic_time(:millisecond)
end
