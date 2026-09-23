defmodule LoopexDaemon.ConnectionRegistryTest do
  use ExUnit.Case, async: true
  @moduletag capture_log: true

  alias LoopexDaemon.{
    ConnectionRegistry,
    ListenerSocket,
    SocketConnection,
    SuccessionCapacity,
    WireRecords
  }

  alias LoopexProtocol.{Frame, Session.V2}

  defmodule ImmediateExitConnection do
    def start_link(_options) do
      pid = spawn_link(fn -> exit(:forced_child_exit) end)
      {:ok, pid}
    end
  end

  defmodule SlowConnection do
    def start_link(options) do
      Process.sleep(30)
      SocketConnection.start_link(options)
    end
  end

  defmodule ManualConnection do
    def start_link(options) do
      listener = Keyword.fetch!(options, :listener)

      pid =
        spawn_link(fn ->
          send(listener, {:manual_connection_started, self(), options})
          loop(options, Keyword.fetch!(options, :rollback_token))
        end)

      {:ok, pid}
    end

    defp loop(options, token) do
      receive do
        {:registry_call, caller, reference, :promote} ->
          result =
            ConnectionRegistry.promote(
              Keyword.fetch!(options, :registry),
              Keyword.fetch!(options, :rollback_token),
              Keyword.fetch!(options, :connection_incarnation)
            )

          send(caller, {:registry_result, reference, result})
          loop(options, token)

        {:registry_call, caller, reference, :initialize_complete} ->
          result =
            ConnectionRegistry.initialize_complete(
              Keyword.fetch!(options, :registry),
              Keyword.fetch!(options, :rollback_token),
              Keyword.fetch!(options, :connection_incarnation)
            )

          send(caller, {:registry_result, reference, result})
          loop(options, token)

        {:registry_call, caller, reference, {:enqueue_output, bytes}} ->
          result =
            ConnectionRegistry.enqueue_output(
              Keyword.fetch!(options, :registry),
              Keyword.fetch!(options, :connection_incarnation),
              bytes
            )

          send(caller, {:registry_result, reference, result})
          loop(options, token)

        {:registry_call, caller, reference, :claim_output} ->
          result =
            ConnectionRegistry.claim_output(
              Keyword.fetch!(options, :registry),
              Keyword.fetch!(options, :connection_incarnation)
            )

          send(caller, {:registry_result, reference, result})
          loop(options, token)

        {:registry_call, caller, reference, {:output_emitted, frame_ref}} ->
          result =
            ConnectionRegistry.output_emitted(
              Keyword.fetch!(options, :registry),
              Keyword.fetch!(options, :connection_incarnation),
              frame_ref
            )

          send(caller, {:registry_result, reference, result})
          loop(options, token)

        {:registry_call, caller, reference, :reserve_succession} ->
          result =
            ConnectionRegistry.reserve_succession(
              Keyword.fetch!(options, :registry),
              Keyword.fetch!(options, :connection_incarnation)
            )

          send(caller, {:registry_result, reference, result})
          loop(options, token)

        {:registry_call, caller, reference, :release_succession} ->
          result =
            ConnectionRegistry.release_succession(
              Keyword.fetch!(options, :registry),
              Keyword.fetch!(options, :connection_incarnation)
            )

          send(caller, {:registry_result, reference, result})
          loop(options, token)

        {:registry_call, caller, reference, {:enqueue_succession_notice, bytes}} ->
          result =
            ConnectionRegistry.enqueue_succession_notice(
              Keyword.fetch!(options, :registry),
              Keyword.fetch!(options, :connection_incarnation),
              bytes
            )

          send(caller, {:registry_result, reference, result})
          loop(options, token)

        {:registry_call, caller, reference, {:enqueue_succession_reply, bytes, mode}} ->
          result =
            ConnectionRegistry.enqueue_succession_reply(
              Keyword.fetch!(options, :registry),
              Keyword.fetch!(options, :connection_incarnation),
              bytes,
              mode
            )

          send(caller, {:registry_result, reference, result})
          loop(options, token)

        {:registry_call, caller, reference, :finish_succession} ->
          result =
            ConnectionRegistry.finish_succession(
              Keyword.fetch!(options, :registry),
              Keyword.fetch!(options, :connection_incarnation)
            )

          send(caller, {:registry_result, reference, result})
          loop(options, token)

        {:connection_abort, ^token, _reason} ->
          :ok

        :stop ->
          :ok
      end
    end
  end

  test "a transferred socket becomes live only after registry promotion" do
    fixture = socket_fixture()
    registry = start_registry(1_000)
    listener_incarnation = make_ref()
    accepted_at = now_ms()

    assert {:ok, %{rollback_token: token, initialize_deadline: deadline}} =
             ConnectionRegistry.reserve(registry, self(), listener_incarnation, accepted_at)

    assert deadline == accepted_at + 1_000
    assert {:ok, connection, incarnation} = ConnectionRegistry.start_connection(registry, token)
    assert :ok = ConnectionRegistry.begin_transfer(registry, token, incarnation)

    assert :ok =
             :socket.setopt(
               fixture.accepted,
               {:otp, :controlling_process},
               connection
             )

    assert :ok = ConnectionRegistry.transfer_result(registry, token, incarnation, :ok)
    assert :ok = SocketConnection.activate(connection, fixture.accepted)

    assert_receive {:promotion_complete, ^token, ^incarnation, ^connection}
    assert %{occupied: 1, provisional: 0, live: 1} = ConnectionRegistry.status(registry)

    assert :ok = client_send(fixture.client, initialize_frame())
    assert {:ok, initialized_bytes} = client_recv(fixture.client)
    [initialized_payload, ""] = :binary.split(initialized_bytes, "\n", [:global])
    assert {:ok, %{"type" => "initialized"}} = Frame.decode(initialized_payload, 2_097_152)
    assert %{occupied: 1, live: 1} = ConnectionRegistry.status(registry)

    Process.exit(connection, :kill)
    eventually(fn -> ConnectionRegistry.status(registry).occupied == 0 end)
    close_fixture(fixture)
  end

  test "the registry owns output charges until exact emission and reclaims them on close" do
    registry =
      start_registry(5_000,
        connection_module: ManualConnection,
        output_buffer_bytes: 10,
        aggregate_output_bytes: 10
      )

    connection = start_manual_connection(registry)
    assert :ok = manual_registry_call(connection.pid, :promote)
    assert :ok = manual_registry_call(connection.pid, :initialize_complete)

    assert :ok = manual_registry_call(connection.pid, {:enqueue_output, "1234567890"})

    assert %{
             output_bytes: 10,
             output_commitment: 10,
             output_commitment_limit: 10
           } = ConnectionRegistry.status(registry)

    assert {:ok, frame_ref, "1234567890"} =
             manual_registry_call(connection.pid, :claim_output)

    assert %{output_bytes: 10, output_commitment: 10} = ConnectionRegistry.status(registry)
    assert :ok = manual_registry_call(connection.pid, {:output_emitted, frame_ref})
    assert %{output_bytes: 0, output_commitment: 0} = ConnectionRegistry.status(registry)

    assert :ok = manual_registry_call(connection.pid, {:enqueue_output, "1234567890"})
    monitor = Process.monitor(connection.pid)

    assert {:error, :capacity_exceeded} =
             manual_registry_call(connection.pid, {:enqueue_output, "x"})

    assert_receive {:DOWN, ^monitor, :process, connection_pid, :normal}, 500
    assert connection_pid == connection.pid
    eventually(fn -> ConnectionRegistry.status(registry).output_commitment == 0 end)
  end

  test "aggregate pressure reclaims another client's buffer before refusing admission" do
    registry =
      start_registry(5_000,
        connection_module: ManualConnection,
        output_buffer_bytes: 8,
        aggregate_output_bytes: 10
      )

    first = start_manual_connection(registry)
    second = start_manual_connection(registry)
    assert :ok = manual_registry_call(first.pid, :promote)
    assert :ok = manual_registry_call(second.pid, :promote)

    assert :ok = manual_registry_call(first.pid, {:enqueue_output, "123456"})
    first_monitor = Process.monitor(first.pid)

    # The unattached holder's bytes are reclaimed and it is closed; the
    # candidate's output is admitted within the commitment.
    assert :ok = manual_registry_call(second.pid, {:enqueue_output, "12345"})
    assert_receive {:DOWN, ^first_monitor, :process, first_pid, :normal}, 500
    assert first_pid == first.pid

    eventually(fn ->
      match?(
        %{occupied: 1, live: 1, output_bytes: 5, output_commitment: 5},
        ConnectionRegistry.status(registry)
      )
    end)

    Process.exit(second.pid, :kill)
    eventually(fn -> ConnectionRegistry.status(registry).output_commitment == 0 end)
  end

  test "reclamation takes the largest unattached buffer first and refuses what still cannot fit" do
    registry =
      start_registry(5_000,
        connection_module: ManualConnection,
        output_buffer_bytes: 8,
        aggregate_output_bytes: 12
      )

    [small, large, candidate] = for _ <- 1..3, do: start_manual_connection(registry)

    for connection <- [small, large, candidate],
        do: :ok = manual_registry_call(connection.pid, :promote)

    assert :ok = manual_registry_call(small.pid, {:enqueue_output, "123"})
    assert :ok = manual_registry_call(large.pid, {:enqueue_output, "1234567"})
    small_monitor = Process.monitor(small.pid)
    large_monitor = Process.monitor(large.pid)

    # Four bytes over: the seven-byte buffer alone covers it, the three-byte
    # one is left alone.
    assert :ok = manual_registry_call(candidate.pid, {:enqueue_output, "12345678"})
    assert_receive {:DOWN, ^large_monitor, :process, _pid, :normal}, 500
    refute_received {:DOWN, ^small_monitor, :process, _pid, _reason}

    # Nothing can make room for more than the whole commitment.
    candidate_monitor = Process.monitor(candidate.pid)

    assert {:error, :capacity_exceeded} =
             manual_registry_call(candidate.pid, {:enqueue_output, "x"})

    assert_receive {:DOWN, ^candidate_monitor, :process, _pid, :normal}, 500
    Process.exit(small.pid, :kill)
    eventually(fn -> ConnectionRegistry.status(registry).output_commitment == 0 end)
  end

  test "succession reserve is owner authenticated and aggregate charged through serial replies" do
    registry =
      start_registry(5_000,
        connection_module: ManualConnection,
        output_buffer_bytes: 100_000,
        aggregate_output_bytes: 170_000
      )

    first = start_manual_connection(registry)
    second = start_manual_connection(registry)
    assert :ok = manual_registry_call(first.pid, :promote)
    assert :ok = manual_registry_call(first.pid, :initialize_complete)
    assert :ok = manual_registry_call(second.pid, :promote)
    assert :ok = manual_registry_call(second.pid, :initialize_complete)

    assert {:error, :reservation_unavailable} =
             ConnectionRegistry.reserve_succession(registry, first.incarnation)

    assert :ok = manual_registry_call(first.pid, :reserve_succession)

    assert %{
             output_bytes: 0,
             output_commitment: 88_091,
             succession_reservations: 1
           } = ConnectionRegistry.status(registry)

    assert {:error, :capacity_exceeded} =
             manual_registry_call(second.pid, :reserve_succession)

    assert Process.alive?(second.pid)
    assert :ok = manual_registry_call(first.pid, :release_succession)
    assert :ok = manual_registry_call(second.pid, :reserve_succession)

    {:ok, notice} =
      Frame.encode(
        WireRecords.detached(
          :binary.copy(<<255>>, 256),
          18_446_744_073_709_551_615
        )
      )

    notice = IO.iodata_to_binary(notice)

    assert :ok =
             manual_registry_call(second.pid, {:enqueue_succession_notice, notice})

    assert {:ok, notice_ref, ^notice} = manual_registry_call(second.pid, :claim_output)
    assert :ok = manual_registry_call(second.pid, {:output_emitted, notice_ref})

    {reply_id, reply_record} =
      SuccessionCapacity.reply_records()
      |> Enum.max_by(fn {_id, record} ->
        {:ok, encoded} = Frame.encode(record)
        IO.iodata_length(encoded)
      end)

    assert reply_id == "session.respond_interaction/refused/invalid_interaction_answer"
    {:ok, reply} = Frame.encode(reply_record)
    reply = IO.iodata_to_binary(reply)

    assert :ok =
             manual_registry_call(
               second.pid,
               {:enqueue_succession_reply, reply, :after_notice}
             )

    assert {:ok, reply_ref, ^reply} = manual_registry_call(second.pid, :claim_output)
    assert :ok = manual_registry_call(second.pid, {:output_emitted, reply_ref})

    {:ok, short_reply} =
      Frame.encode(WireRecords.succession_error(String.duplicate("~", 64), "control_not_held"))

    short_reply = IO.iodata_to_binary(short_reply)

    assert :ok =
             manual_registry_call(
               second.pid,
               {:enqueue_succession_reply, short_reply, :after_notice}
             )

    assert {:ok, short_ref, ^short_reply} = manual_registry_call(second.pid, :claim_output)
    assert :ok = manual_registry_call(second.pid, {:output_emitted, short_ref})
    assert :ok = manual_registry_call(second.pid, :finish_succession)

    assert %{
             output_bytes: 0,
             output_commitment: 0,
             succession_reservations: 0
           } = ConnectionRegistry.status(registry)
  end

  test "pending attachment conflict consumes the reply slot without a notice" do
    registry =
      start_registry(5_000,
        connection_module: ManualConnection,
        output_buffer_bytes: 100_000,
        aggregate_output_bytes: 100_000
      )

    connection = start_manual_connection(registry)
    assert :ok = manual_registry_call(connection.pid, :promote)
    assert :ok = manual_registry_call(connection.pid, :initialize_complete)
    assert :ok = manual_registry_call(connection.pid, :reserve_succession)

    {:ok, reply} =
      Frame.encode(WireRecords.succession_error(String.duplicate("~", 64), "attachment_conflict"))

    reply = IO.iodata_to_binary(reply)

    assert :ok =
             manual_registry_call(
               connection.pid,
               {:enqueue_succession_reply, reply, :without_notice}
             )

    assert %{output_commitment: 87_595, succession_reservations: 1} =
             ConnectionRegistry.status(registry)

    assert {:ok, reply_ref, ^reply} = manual_registry_call(connection.pid, :claim_output)
    assert :ok = manual_registry_call(connection.pid, {:output_emitted, reply_ref})
    assert :ok = manual_registry_call(connection.pid, :finish_succession)

    assert %{output_commitment: 0, succession_reservations: 0} =
             ConnectionRegistry.status(registry)
  end

  test "a locally full connection refuses only the reserve and stays live" do
    registry =
      start_registry(5_000,
        connection_module: ManualConnection,
        output_buffer_bytes: 88_100,
        aggregate_output_bytes: 100_000
      )

    connection = start_manual_connection(registry)
    assert :ok = manual_registry_call(connection.pid, :promote)
    assert :ok = manual_registry_call(connection.pid, :initialize_complete)
    assert :ok = manual_registry_call(connection.pid, {:enqueue_output, "1234567890"})

    assert {:error, :capacity_exceeded} =
             manual_registry_call(connection.pid, :reserve_succession)

    assert Process.alive?(connection.pid)

    assert %{output_bytes: 10, output_commitment: 10, succession_reservations: 0} =
             ConnectionRegistry.status(registry)

    assert {:ok, frame_ref, "1234567890"} =
             manual_registry_call(connection.pid, :claim_output)

    assert :ok = manual_registry_call(connection.pid, {:output_emitted, frame_ref})
    assert :ok = manual_registry_call(connection.pid, :reserve_succession)
    assert :ok = manual_registry_call(connection.pid, :release_succession)
  end

  test "routing mirror promotes after holder loss and exact pop is idempotent" do
    registry = start_registry(5_000, connection_module: ManualConnection)
    registry_incarnation = :crypto.strong_rand_bytes(16)
    assert :ok = ConnectionRegistry.bind_relay(registry, self(), registry_incarnation)

    holder = start_manual_connection(registry)
    assert :ok = manual_registry_call(holder.pid, :promote)
    assert :ok = manual_registry_call(holder.pid, :initialize_complete)

    owner_incarnation = :crypto.strong_rand_bytes(16)
    writer_epoch = :crypto.strong_rand_bytes(16)

    provisional = %{
      permit_id: {holder.incarnation, 0, 1},
      start_op_ref: make_ref(),
      session_id: "mirror-session",
      owner_pid: self(),
      owner_incarnation: owner_incarnation,
      holder_pid: holder.pid,
      holder_incarnation: holder.incarnation,
      writer_epoch: writer_epoch
    }

    stale_ref = make_ref()

    assert :ok =
             ConnectionRegistry.apply_mirror(
               registry,
               stale_ref,
               :crypto.strong_rand_bytes(16),
               :install_provisional,
               provisional
             )

    refute_receive {:mirror_applied, ^stale_ref, _, _, _}, 30

    assert :ok = apply_mirror(registry, registry_incarnation, :install_provisional, provisional)
    assert :ok = apply_mirror(registry, registry_incarnation, :install_provisional, provisional)

    assert %{
             routing_mirrors: 1,
             provisional_routing_mirrors: 1,
             granted_routing_mirrors: 0
           } = ConnectionRegistry.status(registry)

    holder_monitor = Process.monitor(holder.pid)
    Process.exit(holder.pid, :kill)
    assert_receive {:DOWN, ^holder_monitor, :process, _, :killed}, 500
    eventually(fn -> ConnectionRegistry.status(registry).occupied == 0 end)

    assert :ok =
             apply_mirror(
               registry,
               registry_incarnation,
               {:resolve_provisional, :granted},
               provisional
             )

    assert %{
             routing_mirrors: 1,
             provisional_routing_mirrors: 0,
             granted_routing_mirrors: 1
           } = ConnectionRegistry.status(registry)

    owner = %{
      session_id: provisional.session_id,
      owner_pid: provisional.owner_pid,
      owner_incarnation: provisional.owner_incarnation
    }

    assert {:ok,
            {:holder,
             %{
               holder_pid: holder_pid,
               holder_incarnation: holder_incarnation,
               writer_epoch: ^writer_epoch
             }}} = apply_mirror(registry, registry_incarnation, :pop_owner_mirror, owner)

    assert holder_pid == holder.pid
    assert holder_incarnation == holder.incarnation

    assert {:ok, :absent} =
             apply_mirror(registry, registry_incarnation, :pop_owner_mirror, owner)

    assert %{routing_mirrors: 0} = ConnectionRegistry.status(registry)
  end

  test "routing mirror cancellation and stale owner operations preserve a successor" do
    registry = start_registry(5_000, connection_module: ManualConnection)
    registry_incarnation = :crypto.strong_rand_bytes(16)
    assert :ok = ConnectionRegistry.bind_relay(registry, self(), registry_incarnation)

    first = initialized_manual_connection(registry)
    second = initialized_manual_connection(registry)
    session_id = "successor-session"

    predecessor =
      provisional_mirror(first, session_id, self(), :crypto.strong_rand_bytes(16), 1)

    assert :ok = apply_mirror(registry, registry_incarnation, :install_provisional, predecessor)

    assert :ok =
             apply_mirror(
               registry,
               registry_incarnation,
               {:resolve_provisional, :cancelled},
               predecessor
             )

    assert :ok =
             apply_mirror(
               registry,
               registry_incarnation,
               {:resolve_provisional, :cancelled},
               predecessor
             )

    successor_owner = spawn(fn -> Process.sleep(:infinity) end)
    on_exit(fn -> Process.exit(successor_owner, :kill) end)

    successor =
      provisional_mirror(
        second,
        session_id,
        successor_owner,
        :crypto.strong_rand_bytes(16),
        2
      )

    assert :ok = apply_mirror(registry, registry_incarnation, :install_provisional, successor)

    predecessor_granted = granted_mirror(predecessor)

    assert {:error, :mirror_conflict} =
             apply_mirror(
               registry,
               registry_incarnation,
               :clear_granted,
               predecessor_granted
             )

    assert {:ok, :absent} =
             apply_mirror(
               registry,
               registry_incarnation,
               :pop_owner_mirror,
               Map.take(predecessor, [:session_id, :owner_pid, :owner_incarnation])
             )

    assert %{routing_mirrors: 1, provisional_routing_mirrors: 1} =
             ConnectionRegistry.status(registry)

    assert :ok =
             apply_mirror(
               registry,
               registry_incarnation,
               {:resolve_provisional, :granted},
               successor
             )

    successor_granted = granted_mirror(successor)
    assert :ok = apply_mirror(registry, registry_incarnation, :clear_granted, successor_granted)
    assert :ok = apply_mirror(registry, registry_incarnation, :clear_granted, successor_granted)
    assert %{routing_mirrors: 0} = ConnectionRegistry.status(registry)

    Process.exit(first.pid, :kill)
    Process.exit(second.pid, :kill)
  end

  test "routing mirror install requires the exact initialized live connection" do
    registry = start_registry(5_000, connection_module: ManualConnection)
    registry_incarnation = :crypto.strong_rand_bytes(16)
    assert :ok = ConnectionRegistry.bind_relay(registry, self(), registry_incarnation)

    holder = start_manual_connection(registry)

    provisional =
      provisional_mirror(
        holder,
        "not-live-session",
        self(),
        :crypto.strong_rand_bytes(16),
        1
      )

    assert {:error, :connection_not_live} =
             apply_mirror(registry, registry_incarnation, :install_provisional, provisional)

    assert :ok = manual_registry_call(holder.pid, :promote)
    assert :ok = manual_registry_call(holder.pid, :initialize_complete)

    assert {:error, :invalid_mirror} =
             apply_mirror(
               registry,
               registry_incarnation,
               :install_provisional,
               Map.put(provisional, :unexpected, true)
             )

    assert :ok = apply_mirror(registry, registry_incarnation, :install_provisional, provisional)

    assert {:error, :mirror_provisional} =
             apply_mirror(
               registry,
               registry_incarnation,
               :pop_owner_mirror,
               Map.take(provisional, [:session_id, :owner_pid, :owner_incarnation])
             )

    Process.exit(holder.pid, :kill)
  end

  test "activation reservations coalesce exact commands and reject conflicting bindings" do
    registry = start_registry(5_000)
    command_id = "create-command"
    digest = :crypto.hash(:sha256, "options-a")
    first = activation_origin(0, 1)
    duplicate = activation_origin(1, 1)

    assert {:ok, {:primary, reservation_ref}} =
             ConnectionRegistry.reserve_activation(
               registry,
               first,
               {:create, command_id, digest}
             )

    assert {:ok, {:primary, ^reservation_ref}} =
             ConnectionRegistry.reserve_activation(
               registry,
               first,
               {:create, command_id, digest}
             )

    assert {:ok, {:duplicate, ^first, ^reservation_ref}} =
             ConnectionRegistry.reserve_activation(
               registry,
               duplicate,
               {:create, command_id, digest}
             )

    assert {:error, :activation_conflict} =
             ConnectionRegistry.reserve_activation(
               registry,
               activation_origin(2, 1),
               {:create, command_id, :crypto.hash(:sha256, "options-b")}
             )

    assert {:error, :activation_conflict} =
             ConnectionRegistry.reserve_activation(
               registry,
               first,
               {:resume, "other-session", "resume-command"}
             )

    assert %{
             active_sessions: 0,
             activation_reservations: 1,
             activations_used: 1,
             activation_limit: 64
           } = ConnectionRegistry.status(registry)

    assert :ok =
             ConnectionRegistry.resolve_activation(
               registry,
               reservation_ref,
               :activated,
               "created-session"
             )

    assert :ok =
             ConnectionRegistry.resolve_activation(
               registry,
               reservation_ref,
               :activated,
               "created-session"
             )

    assert %{
             active_sessions: 1,
             activation_reservations: 0,
             activations_used: 1
           } = ConnectionRegistry.status(registry)

    assert {:ok, :already_active} =
             ConnectionRegistry.reserve_activation(
               registry,
               activation_origin(3, 1),
               {:resume, "created-session", "resume-active"}
             )
  end

  test "distinct dormant resume commands reserve independently while exact replay joins" do
    registry = start_registry(5_000)
    session_id = "dormant-session"
    first = activation_origin(0, 1)
    replay = activation_origin(1, 1)
    second = activation_origin(2, 1)

    assert {:ok, {:primary, first_ref}} =
             ConnectionRegistry.reserve_activation(
               registry,
               first,
               {:resume, session_id, "resume-one"}
             )

    assert {:ok, {:duplicate, ^first, ^first_ref}} =
             ConnectionRegistry.reserve_activation(
               registry,
               replay,
               {:resume, session_id, "resume-one"}
             )

    assert {:ok, {:primary, second_ref}} =
             ConnectionRegistry.reserve_activation(
               registry,
               second,
               {:resume, session_id, "resume-two"}
             )

    assert first_ref != second_ref

    assert %{active_sessions: 0, activation_reservations: 2, activations_used: 2} =
             ConnectionRegistry.status(registry)

    assert {:error, :activation_resolution_invalid} =
             ConnectionRegistry.resolve_activation(
               registry,
               first_ref,
               :activated,
               "wrong-session"
             )

    assert :ok =
             ConnectionRegistry.resolve_activation(
               registry,
               first_ref,
               :activated,
               session_id
             )

    assert %{active_sessions: 1, activation_reservations: 1, activations_used: 2} =
             ConnectionRegistry.status(registry)

    assert {:ok, :already_active} =
             ConnectionRegistry.reserve_activation(
               registry,
               activation_origin(3, 1),
               {:resume, session_id, "resume-three"}
             )

    assert :ok =
             ConnectionRegistry.resolve_activation(
               registry,
               second_ref,
               :no_activation
             )

    assert %{active_sessions: 1, activation_reservations: 0, activations_used: 1} =
             ConnectionRegistry.status(registry)
  end

  test "the serialized activation ledger admits only one call at sixty-three" do
    registry = start_registry(5_000)

    Enum.each(1..63, fn index ->
      origin = activation_origin(rem(index, 32), index)
      session_id = "active-#{index}"

      assert {:ok, {:primary, reservation_ref}} =
               ConnectionRegistry.reserve_activation(
                 registry,
                 origin,
                 {:resume, session_id, "resume-#{index}"}
               )

      assert :ok =
               ConnectionRegistry.resolve_activation(
                 registry,
                 reservation_ref,
                 :activated,
                 session_id
               )
    end)

    contenders =
      for index <- 64..65 do
        Task.async(fn ->
          ConnectionRegistry.reserve_activation(
            registry,
            activation_origin(rem(index, 32), index),
            {:resume, "dormant-#{index}", "resume-#{index}"}
          )
        end)
      end

    results = Enum.map(contenders, &Task.await/1)

    assert [{:error, :activation_ceiling_reached}, {:ok, {:primary, reservation_ref}}] =
             Enum.sort(results)

    assert %{active_sessions: 63, activation_reservations: 1, activations_used: 64} =
             ConnectionRegistry.status(registry)

    assert :ok =
             ConnectionRegistry.resolve_activation(
               registry,
               reservation_ref,
               :no_activation
             )

    assert %{active_sessions: 63, activation_reservations: 0, activations_used: 63} =
             ConnectionRegistry.status(registry)
  end

  test "the transport cut freezes and reaps one exact uninitialized population" do
    registry = start_registry(5_000, connection_module: ManualConnection)

    initialized = start_manual_connection(registry)
    assert :ok = manual_registry_call(initialized.pid, :promote)
    assert :ok = manual_registry_call(initialized.pid, :initialize_complete)

    uninitialized = start_manual_connection(registry)
    assert :ok = manual_registry_call(uninitialized.pid, :promote)

    pending = start_manual_connection(registry)
    transferring = start_manual_connection(registry, :transferring)

    assert {:ok, %{rollback_token: listener_owned_token}} =
             ConnectionRegistry.reserve(registry, self(), make_ref(), now_ms())

    initialized_monitor = Process.monitor(initialized.pid)
    uninitialized_monitor = Process.monitor(uninitialized.pid)
    pending_monitor = Process.monitor(pending.pid)
    transferring_monitor = Process.monitor(transferring.pid)
    cut_ref = make_ref()

    assert {:error, :owner_mismatch} =
             Task.async(fn ->
               registry
               |> ConnectionRegistry.transport_closing(cut_ref)
               |> registry_response()
             end)
             |> Task.await()
             |> reply_value()

    assert {:ok, ^cut_ref} =
             registry |> ConnectionRegistry.transport_closing(cut_ref) |> reply_value()

    assert {:ok, ^cut_ref} =
             registry |> ConnectionRegistry.transport_closing(cut_ref) |> reply_value()

    assert {:error, :transport_cut_mismatch} =
             registry |> ConnectionRegistry.transport_closing(make_ref()) |> reply_value()

    assert %{
             occupied: 5,
             live: 2,
             provisional: 3,
             transport: :closing,
             transport_marked: 4
           } = ConnectionRegistry.status(registry)

    assert {:error, :transport_closing} =
             ConnectionRegistry.reserve(registry, self(), make_ref(), now_ms())

    assert {:error, :transport_closing} = manual_registry_call(pending.pid, :promote)

    assert {:error, :transport_closing} =
             manual_registry_call(uninitialized.pid, :initialize_complete)

    assert {:error, :transport_cut_mismatch} =
             registry |> ConnectionRegistry.reap_uninitialized(make_ref()) |> reply_value()

    assert {:error, :owner_mismatch} =
             Task.async(fn ->
               registry
               |> ConnectionRegistry.reap_uninitialized(cut_ref)
               |> registry_response()
             end)
             |> Task.await()
             |> reply_value()

    assert :ok = registry |> ConnectionRegistry.reap_uninitialized(cut_ref) |> reply_value()

    assert_receive {:close_accepted, ^listener_owned_token}, 500
    assert :ok = ConnectionRegistry.listener_closed(registry, listener_owned_token)
    refute_receive {:transport_uninitialized_empty, ^registry, ^cut_ref}, 20

    assert :ok =
             ConnectionRegistry.transfer_result(
               registry,
               transferring.token,
               transferring.incarnation,
               :ok
             )

    assert_receive {:DOWN, ^uninitialized_monitor, :process, uninitialized_pid, :normal}, 500
    assert uninitialized_pid == uninitialized.pid
    assert_receive {:DOWN, ^pending_monitor, :process, pending_pid, :normal}, 500
    assert pending_pid == pending.pid

    assert_receive {:DOWN, ^transferring_monitor, :process, transferring_pid, :normal}, 500
    assert transferring_pid == transferring.pid

    assert_receive {:transport_uninitialized_empty, ^registry, ^cut_ref}, 500
    refute_receive {:transport_uninitialized_empty, ^registry, ^cut_ref}, 20

    assert {:error, :transport_sweep_already_started} =
             registry |> ConnectionRegistry.reap_uninitialized(cut_ref) |> reply_value()

    assert %{
             occupied: 1,
             live: 1,
             provisional: 0,
             closing: 0,
             transport: :closing,
             transport_marked: 0
           } = ConnectionRegistry.status(registry)

    assert Process.alive?(initialized.pid)
    Process.exit(initialized.pid, :kill)
    assert_receive {:DOWN, ^initialized_monitor, :process, initialized_pid, :killed}, 500
    assert initialized_pid == initialized.pid
    eventually(fn -> ConnectionRegistry.status(registry).occupied == 0 end)
  end

  test "the unchanged accept-time deadline closes an uninitialized promoted connection" do
    fixture = socket_fixture()
    registry = start_registry(50)
    accepted_at = now_ms()

    assert {:ok, %{rollback_token: token}} =
             ConnectionRegistry.reserve(registry, self(), make_ref(), accepted_at)

    assert {:ok, connection, incarnation} = ConnectionRegistry.start_connection(registry, token)
    assert :ok = ConnectionRegistry.begin_transfer(registry, token, incarnation)

    assert :ok =
             :socket.setopt(
               fixture.accepted,
               {:otp, :controlling_process},
               connection
             )

    assert :ok = ConnectionRegistry.transfer_result(registry, token, incarnation, :ok)
    SocketConnection.activate(connection, fixture.accepted)
    assert_receive {:promotion_complete, ^token, ^incarnation, ^connection}

    monitor = Process.monitor(connection)
    assert_receive {:DOWN, ^monitor, :process, ^connection, :normal}, 500
    eventually(fn -> ConnectionRegistry.status(registry).occupied == 0 end)
    close_fixture(fixture)
  end

  test "expiry while listener-owned requires exact close acknowledgement and child reap" do
    registry = start_registry(30)
    accepted_at = now_ms()

    assert {:ok, %{rollback_token: token}} =
             ConnectionRegistry.reserve(registry, self(), make_ref(), accepted_at)

    assert {:ok, connection, _incarnation} =
             ConnectionRegistry.start_connection(registry, token)

    assert_receive {:close_accepted, ^token}, 500
    assert %{occupied: 1, provisional: 1} = ConnectionRegistry.status(registry)

    assert :ok = ConnectionRegistry.listener_closed(registry, token)
    monitor = Process.monitor(connection)
    assert_receive {:DOWN, ^monitor, :process, ^connection, _reason}, 500
    eventually(fn -> ConnectionRegistry.status(registry).occupied == 0 end)
  end

  test "a failed transfer returns ownership to the listener before cleanup" do
    registry = start_registry(1_000)
    accepted_at = now_ms()

    assert {:ok, %{rollback_token: token}} =
             ConnectionRegistry.reserve(registry, self(), make_ref(), accepted_at)

    assert {:ok, connection, incarnation} = ConnectionRegistry.start_connection(registry, token)
    assert :ok = ConnectionRegistry.begin_transfer(registry, token, incarnation)

    assert {:error, :transfer_failed} =
             ConnectionRegistry.transfer_result(
               registry,
               token,
               incarnation,
               {:error, :einval}
             )

    assert_receive {:close_accepted, ^token}
    assert :ok = ConnectionRegistry.listener_closed(registry, token)
    monitor = Process.monitor(connection)
    assert_receive {:DOWN, ^monitor, :process, ^connection, _reason}, 500
    eventually(fn -> ConnectionRegistry.status(registry).occupied == 0 end)
  end

  test "all 512 provisional slots remain charged until listener close evidence" do
    registry = start_registry(5_000)
    listener_incarnation = make_ref()

    tokens =
      for _index <- 1..512 do
        assert {:ok, %{rollback_token: token}} =
                 ConnectionRegistry.reserve(
                   registry,
                   self(),
                   listener_incarnation,
                   now_ms()
                 )

        token
      end

    assert {:error, :capacity_exceeded} =
             ConnectionRegistry.reserve(registry, self(), listener_incarnation, now_ms())

    assert %{occupied: 512, provisional: 512, limit: 512} =
             ConnectionRegistry.status(registry)

    assert :ok = ConnectionRegistry.abort_provisional_for(registry, listener_incarnation)

    for token <- tokens do
      assert_receive {:close_accepted, ^token}
      assert :ok = ConnectionRegistry.listener_closed(registry, token)
    end

    eventually(fn -> ConnectionRegistry.status(registry).occupied == 0 end)
  end

  test "an abort during transfer waits for the exact transfer result" do
    registry = start_registry(40)
    accepted_at = now_ms()

    assert {:ok, %{rollback_token: token}} =
             ConnectionRegistry.reserve(registry, self(), make_ref(), accepted_at)

    assert {:ok, connection, incarnation} = ConnectionRegistry.start_connection(registry, token)
    assert :ok = ConnectionRegistry.begin_transfer(registry, token, incarnation)
    monitor = Process.monitor(connection)

    Process.sleep(50)
    refute_receive {:close_accepted, ^token}, 20
    refute_receive {:DOWN, ^monitor, :process, ^connection, _reason}, 20
    assert %{occupied: 1, provisional: 1} = ConnectionRegistry.status(registry)

    assert {:error, :transfer_failed} =
             ConnectionRegistry.transfer_result(
               registry,
               token,
               incarnation,
               {:error, :einval}
             )

    assert_receive {:close_accepted, ^token}
    assert :ok = ConnectionRegistry.listener_closed(registry, token)
    assert_receive {:DOWN, ^monitor, :process, ^connection, :normal}, 500
    eventually(fn -> ConnectionRegistry.status(registry).occupied == 0 end)
  end

  test "an expired successful transfer reaps the connection-owned socket" do
    fixture = socket_fixture()
    registry = start_registry(60)

    assert {:ok, %{rollback_token: token}} =
             ConnectionRegistry.reserve(registry, self(), make_ref(), now_ms())

    assert {:ok, connection, incarnation} = ConnectionRegistry.start_connection(registry, token)
    assert :ok = ConnectionRegistry.begin_transfer(registry, token, incarnation)

    assert :ok =
             :socket.setopt(
               fixture.accepted,
               {:otp, :controlling_process},
               connection
             )

    monitor = Process.monitor(connection)
    Process.sleep(80)
    assert %{occupied: 1, provisional: 1} = ConnectionRegistry.status(registry)

    assert :ok = ConnectionRegistry.transfer_result(registry, token, incarnation, :ok)
    refute_receive {:close_accepted, ^token}, 20
    assert_receive {:DOWN, ^monitor, :process, ^connection, :normal}, 500
    eventually(fn -> ConnectionRegistry.status(registry).occupied == 0 end)
    close_fixture(fixture)
  end

  test "initialize completion queued before but consumed after the deadline loses" do
    fixture = socket_fixture()
    registry = start_registry(150)
    accepted_at = now_ms()

    assert {:ok, %{rollback_token: token}} =
             ConnectionRegistry.reserve(registry, self(), make_ref(), accepted_at)

    assert {:ok, connection, incarnation} = ConnectionRegistry.start_connection(registry, token)
    assert :ok = ConnectionRegistry.begin_transfer(registry, token, incarnation)

    assert :ok =
             :socket.setopt(
               fixture.accepted,
               {:otp, :controlling_process},
               connection
             )

    assert :ok = ConnectionRegistry.transfer_result(registry, token, incarnation, :ok)
    SocketConnection.activate(connection, fixture.accepted)
    assert_receive {:promotion_complete, ^token, ^incarnation, ^connection}

    :ok = :sys.suspend(registry)
    monitor = Process.monitor(connection)
    assert :ok = client_send(fixture.client, initialize_frame())
    Process.sleep(170)
    :ok = :sys.resume(registry)

    assert_receive {:DOWN, ^monitor, :process, ^connection, :normal}, 500
    eventually(fn -> ConnectionRegistry.status(registry).occupied == 0 end)
    close_fixture(fixture)
  end

  test "listener death during transfer reaps the possible socket owner" do
    registry = start_registry(1_000)
    parent = self()

    listener =
      spawn(fn ->
        accepted_at = now_ms()
        incarnation = make_ref()

        {:ok, %{rollback_token: token}} =
          ConnectionRegistry.reserve(registry, self(), incarnation, accepted_at)

        {:ok, connection, connection_incarnation} =
          ConnectionRegistry.start_connection(registry, token)

        :ok = ConnectionRegistry.begin_transfer(registry, token, connection_incarnation)
        send(parent, {:transferring, self(), token, connection})

        receive do
          :stop -> :ok
        end
      end)

    assert_receive {:transferring, ^listener, _token, connection}
    monitor = Process.monitor(connection)
    Process.exit(listener, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^connection, :normal}, 500
    eventually(fn -> ConnectionRegistry.status(registry).occupied == 0 end)
  end

  test "only the reserving listener can continue or acknowledge a handoff" do
    registry = start_registry(1_000)

    listener =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    result =
      Task.async(fn ->
        ConnectionRegistry.reserve(registry, listener, make_ref(), now_ms())
      end)
      |> Task.await()

    assert {:error, :reservation_unavailable} = result
    Process.exit(listener, :kill)

    listener_incarnation = make_ref()

    assert {:ok, %{rollback_token: token}} =
             ConnectionRegistry.reserve(registry, self(), listener_incarnation, now_ms())

    assert {:error, :abort_unavailable} =
             Task.async(fn ->
               ConnectionRegistry.abort_provisional(registry, token, :handoff_failed)
             end)
             |> Task.await()

    assert {:error, :reservation_unavailable} =
             Task.async(fn -> ConnectionRegistry.start_connection(registry, token) end)
             |> Task.await()

    assert {:ok, connection, _incarnation} =
             ConnectionRegistry.start_connection(registry, token)

    assert {:error, :close_acknowledgement_unavailable} =
             ConnectionRegistry.listener_closed(registry, token)

    monitor = Process.monitor(connection)
    assert :ok = ConnectionRegistry.abort_provisional_for(registry, listener_incarnation)
    assert_receive {:close_accepted, ^token}
    assert :ok = ConnectionRegistry.listener_closed(registry, token)
    assert_receive {:DOWN, ^monitor, :process, ^connection, :normal}, 500
    eventually(fn -> ConnectionRegistry.status(registry).occupied == 0 end)
  end

  test "a child exit between linked start and unlink is reaped without losing the registry" do
    registry = start_registry(1_000, connection_module: ImmediateExitConnection)
    listener_incarnation = make_ref()

    assert {:ok, %{rollback_token: token}} =
             ConnectionRegistry.reserve(registry, self(), listener_incarnation, now_ms())

    assert {:ok, _connection, _incarnation} =
             ConnectionRegistry.start_connection(registry, token)

    assert_receive {:close_accepted, ^token}, 500
    assert :ok = ConnectionRegistry.listener_closed(registry, token)
    eventually(fn -> ConnectionRegistry.status(registry).occupied == 0 end)
    assert Process.alive?(registry)
  end

  test "a child start that crosses the accept deadline enters exact cleanup" do
    registry = start_registry(10, connection_module: SlowConnection)
    listener_incarnation = make_ref()

    assert {:ok, %{rollback_token: token}} =
             ConnectionRegistry.reserve(registry, self(), listener_incarnation, now_ms())

    assert {:error, :initialize_deadline_expired} =
             ConnectionRegistry.start_connection(registry, token)

    assert_receive {:close_accepted, ^token}, 500
    assert :ok = ConnectionRegistry.listener_closed(registry, token)
    eventually(fn -> ConnectionRegistry.status(registry).occupied == 0 end)
    assert Process.alive?(registry)
  end

  defp start_registry(deadline_ms, options \\ []) do
    {:ok, registry} =
      ConnectionRegistry.start_link(
        Keyword.merge(
          [owner: self(), initialize_deadline_ms: deadline_ms],
          options
        )
      )

    on_exit(fn ->
      try do
        if Process.alive?(registry), do: GenServer.stop(registry)
      catch
        :exit, _reason -> :ok
      end
    end)

    registry
  end

  defp start_manual_connection(registry, disposition \\ :connection_owned) do
    listener_incarnation = make_ref()

    assert {:ok, %{rollback_token: token}} =
             ConnectionRegistry.reserve(registry, self(), listener_incarnation, now_ms())

    assert {:ok, pid, incarnation} = ConnectionRegistry.start_connection(registry, token)
    assert_receive {:manual_connection_started, ^pid, options}
    assert Keyword.fetch!(options, :rollback_token) == token
    assert Keyword.fetch!(options, :connection_incarnation) == incarnation
    assert :ok = ConnectionRegistry.begin_transfer(registry, token, incarnation)

    if disposition == :connection_owned,
      do: assert(:ok = ConnectionRegistry.transfer_result(registry, token, incarnation, :ok))

    %{pid: pid, token: token, incarnation: incarnation}
  end

  defp manual_registry_call(pid, operation) do
    reference = make_ref()
    send(pid, {:registry_call, self(), reference, operation})
    assert_receive {:registry_result, ^reference, result}, 500
    result
  end

  defp initialized_manual_connection(registry) do
    connection = start_manual_connection(registry)
    assert :ok = manual_registry_call(connection.pid, :promote)
    assert :ok = manual_registry_call(connection.pid, :initialize_complete)
    connection
  end

  defp apply_mirror(registry, registry_incarnation, action, exact_row) do
    op_ref = make_ref()

    assert :ok =
             ConnectionRegistry.apply_mirror(
               registry,
               op_ref,
               registry_incarnation,
               action,
               exact_row
             )

    assert_receive {:mirror_applied, ^op_ref, ^registry, ^registry_incarnation, result}, 500
    result
  end

  defp provisional_mirror(connection, session_id, owner_pid, owner_incarnation, sequence) do
    %{
      permit_id: {connection.incarnation, 0, sequence},
      start_op_ref: make_ref(),
      session_id: session_id,
      owner_pid: owner_pid,
      owner_incarnation: owner_incarnation,
      holder_pid: connection.pid,
      holder_incarnation: connection.incarnation,
      writer_epoch: :crypto.strong_rand_bytes(16)
    }
  end

  defp granted_mirror(provisional) do
    provisional
    |> Map.drop([:permit_id, :start_op_ref])
    |> Map.put(:phase, :granted)
  end

  defp reply_value({:reply, reply}), do: reply

  defp reply_value(request_id) do
    assert {:reply, reply} = registry_response(request_id)
    reply
  end

  defp registry_response(request_id),
    do: :gen_server.receive_response(request_id, 500)

  defp socket_fixture do
    directory =
      Path.join(
        System.tmp_dir!(),
        "loopex-registry-socket-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir!(directory)
    path = Path.join(directory, "daemon.sock")
    uid = File.stat!(directory).uid
    {:ok, listener} = ListenerSocket.open_parked(path, uid)
    parent = self()

    client =
      Task.async(fn ->
        {:ok, socket} = :socket.open(:local, :stream, :default)
        :ok = :socket.connect(socket, %{family: :local, path: path})
        send(parent, {:client_ready, self()})
        client_loop(socket, "")
      end)

    assert_receive {:client_ready, client_pid} when client_pid == client.pid
    {:ok, accepted} = :socket.accept(listener, 1_000)

    %{directory: directory, path: path, listener: listener, accepted: accepted, client: client}
  end

  defp close_fixture(fixture) do
    send(fixture.client.pid, :close)
    assert :ok = Task.await(fixture.client)
    assert :ok = ListenerSocket.close(fixture.listener)
    File.rm!(fixture.path)
    File.rmdir!(fixture.directory)
  end

  defp client_loop(socket, buffer) do
    receive do
      {:send, caller, reference, bytes} ->
        send(caller, {:client_result, reference, :socket.send(socket, bytes)})
        client_loop(socket, buffer)

      {:recv, caller, reference} ->
        {result, buffer} = read_frame(socket, buffer)
        send(caller, {:client_result, reference, result})
        client_loop(socket, buffer)

      :close ->
        :socket.close(socket)
    end
  end

  defp read_frame(socket, buffer) do
    case :binary.match(buffer, "\n") do
      {offset, 1} ->
        frame_bytes = offset + 1
        frame = binary_part(buffer, 0, frame_bytes)
        rest = binary_part(buffer, frame_bytes, byte_size(buffer) - frame_bytes)
        {{:ok, frame}, rest}

      :nomatch ->
        case :socket.recv(socket, 0, 1_000) do
          {:ok, bytes} -> read_frame(socket, buffer <> bytes)
          {:error, _reason} = error -> {error, buffer}
        end
    end
  end

  defp client_send(client, bytes) do
    reference = make_ref()
    send(client.pid, {:send, self(), reference, bytes})
    assert_receive {:client_result, ^reference, result}, 1_000
    result
  end

  defp client_recv(client) do
    reference = make_ref()
    send(client.pid, {:recv, self(), reference})
    assert_receive {:client_result, ^reference, result}, 1_000
    result
  end

  defp initialize_frame do
    {:ok, encoded} =
      Frame.encode(%{
        "method" => "initialize",
        "request_id" => "registry-test",
        "generations" => [V2.generation()],
        "capabilities" => []
      })

    encoded
  end

  defp eventually(predicate, attempts \\ 50)

  defp eventually(predicate, 0), do: assert(predicate.())

  defp eventually(predicate, attempts) do
    if predicate.() do
      :ok
    else
      Process.sleep(10)
      eventually(predicate, attempts - 1)
    end
  end

  defp now_ms, do: System.monotonic_time(:millisecond)

  defp activation_origin(slot, sequence),
    do: {:crypto.hash(:md5, Integer.to_string(sequence)), slot, sequence}
end
