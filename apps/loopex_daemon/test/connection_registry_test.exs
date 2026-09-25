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

        {:registry_call, caller, reference, {:invoke, operation}} ->
          send(caller, {:registry_result, reference, operation.()})
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

  # Concept: at the real 4 MiB allowance, an attached connection can always be
  # told its session changed owner and then answer every held mutation, one at
  # a time, however full its ordinary output is.
  #
  # Technical depth: ordinary output is filled to exactly the allowance minus
  # the succession reserve. On one connection the next ordinary byte overflows.
  # On another, the maximal `detached` notice is admitted at that fill and
  # written after the ordinary backlog, then 32 maximal predecessor replies
  # each reuse the one
  # reply slot only after the previous frame was emitted, with the connection's
  # commitment never above 4 MiB and the connection kept live.
  @tag timeout: 120_000
  test "succession fits at the real allowance with 32 serial maximal replies" do
    registry = start_registry(5_000, connection_module: ManualConnection)
    allowance = 4_194_304
    reserve = 88_091
    ordinary = allowance - reserve

    overflowing = start_manual_connection(registry)
    succeeding = start_manual_connection(registry)

    for connection <- [overflowing, succeeding] do
      assert :ok = manual_registry_call(connection.pid, :promote)
      assert :ok = manual_registry_call(connection.pid, :initialize_complete)
      assert :ok = manual_registry_call(connection.pid, :reserve_succession)
      fill(connection, ordinary)
    end

    monitor = Process.monitor(overflowing.pid)

    assert {:error, :capacity_exceeded} =
             manual_registry_call(overflowing.pid, {:enqueue_output, "x"})

    assert_receive {:DOWN, ^monitor, :process, _pid, :normal}, 5_000

    {:ok, notice} =
      Frame.encode(WireRecords.detached(:binary.copy(<<255>>, 256), 18_446_744_073_709_551_615))

    notice = IO.iodata_to_binary(notice)
    assert :ok = manual_registry_call(succeeding.pid, {:enqueue_succession_notice, notice})

    # Output already queued before the cut is written first, then the notice.
    assert drain_until(succeeding, notice, 0) == ordinary

    {_id, reply_record} =
      SuccessionCapacity.reply_records()
      |> Enum.max_by(fn {_id, record} ->
        {:ok, encoded} = Frame.encode(record)
        IO.iodata_length(encoded)
      end)

    {:ok, reply} = Frame.encode(reply_record)
    reply = IO.iodata_to_binary(reply)

    for _held <- 1..32 do
      assert :ok =
               manual_registry_call(
                 succeeding.pid,
                 {:enqueue_succession_reply, reply, :after_notice}
               )

      assert ConnectionRegistry.status(registry).output_commitment <= allowance
      assert {:ok, reply_ref, ^reply} = manual_registry_call(succeeding.pid, :claim_output)
      assert :ok = manual_registry_call(succeeding.pid, {:output_emitted, reply_ref})
    end

    assert :ok = manual_registry_call(succeeding.pid, :finish_succession)
    assert Process.alive?(succeeding.pid)

    assert %{output_bytes: 0, output_commitment: 0, succession_reservations: 0} =
             ConnectionRegistry.status(registry)
  end

  defp drain_until(connection, notice, emitted) do
    {:ok, frame_ref, bytes} = manual_registry_call(connection.pid, :claim_output)
    assert :ok = manual_registry_call(connection.pid, {:output_emitted, frame_ref})

    if bytes == notice do
      emitted
    else
      assert bytes =~ ~r/\Ao+\z/
      drain_until(connection, notice, emitted + byte_size(bytes))
    end
  end

  # Concept: the output ceilings bound retained payload, not memory, so the
  # process's actual resident size under payload pressure is measured and
  # reported beside them for the closure evidence.
  #
  # Technical depth: 127 connections each hold the full 4 MiB of queued output,
  # 508 MiB against the 512 MiB aggregate commitment, in 1 MiB binaries the
  # registry retains. The commitment is asserted exactly; the VM's RSS before
  # and at pressure is printed, not asserted, because the plan promises a
  # retained-payload ceiling rather than an RSS bound.
  @tag :long_bound
  @tag timeout: 300_000
  test "retained output near the aggregate ceiling reports the process RSS" do
    registry = start_registry(5_000, connection_module: ManualConnection)
    allowance = 4_194_304
    count = 127
    before_kib = rss_kib()

    connections =
      for _index <- 1..count do
        connection = start_manual_connection(registry)
        assert :ok = manual_registry_call(connection.pid, :promote)
        fill(connection, allowance)
        connection
      end

    status = ConnectionRegistry.status(registry)
    assert status.output_commitment == count * allowance
    assert status.output_commitment <= 536_870_912
    pressure_kib = rss_kib()

    IO.puts(
      "payload-pressure RSS: retained_output_bytes=#{status.output_commitment} " <>
        "aggregate_ceiling_bytes=536870912 rss_kib_before=#{before_kib} " <>
        "rss_kib_at_pressure=#{pressure_kib} otp=#{System.otp_release()}"
    )

    Enum.each(connections, &Process.exit(&1.pid, :kill))
    eventually(fn -> ConnectionRegistry.status(registry).output_commitment == 0 end)
  end

  defp rss_kib do
    {output, 0} = System.cmd("ps", ["-o", "rss=", "-p", System.pid()])
    output |> String.trim() |> String.to_integer()
  end

  defp fill(connection, bytes) do
    chunk = 1_048_576

    Stream.unfold(bytes, fn
      0 -> nil
      left -> {min(chunk, left), left - min(chunk, left)}
    end)
    |> Enum.each(fn size ->
      assert :ok =
               manual_registry_call(connection.pid, {:enqueue_output, :binary.copy("o", size)})
    end)
  end

  # Concept: the succession reserve is sized so every connection the daemon
  # can hold may be attached at once: all 512 reserves fit inside the real
  # aggregate allowance, and the 513th connection is refused at accept.
  @tag timeout: 120_000
  test "all 512 connections can hold their succession reserve at once" do
    registry = start_registry(5_000, connection_module: ManualConnection)

    connections =
      for _index <- 1..512 do
        connection = start_manual_connection(registry)
        assert :ok = manual_registry_call(connection.pid, :promote)
        assert :ok = manual_registry_call(connection.pid, :initialize_complete)
        assert :ok = manual_registry_call(connection.pid, :reserve_succession)
        connection
      end

    assert %{succession_reservations: 512, output_commitment: commitment} =
             ConnectionRegistry.status(registry)

    assert commitment == 512 * 88_091
    assert commitment <= 536_870_912

    assert {:error, _full} =
             ConnectionRegistry.reserve(registry, self(), make_ref(), now_ms())

    Enum.each(connections, &Process.exit(&1.pid, :kill))
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

  # Concept: a lease is never routed to a connection that is already going
  # away: once a holder's connection is closing, installing a provisional
  # mirror for it is refused, and nothing is recorded.
  #
  # Technical depth: aggregate-pressure reclamation moves the holder's row to
  # `:closing` while its connection process, suspended, is still alive. A provisional
  # mirror naming that exact holder then answers `:connection_not_live`, and
  # the registry holds no routing mirror.
  test "a provisional mirror for a closing connection is refused" do
    registry =
      start_registry(5_000,
        connection_module: ManualConnection,
        output_buffer_bytes: 8,
        aggregate_output_bytes: 10
      )

    registry_incarnation = :crypto.strong_rand_bytes(16)
    assert :ok = ConnectionRegistry.bind_relay(registry, self(), registry_incarnation)

    holder = start_manual_connection(registry)
    candidate = start_manual_connection(registry)

    for connection <- [holder, candidate] do
      assert :ok = manual_registry_call(connection.pid, :promote)
      assert :ok = manual_registry_call(connection.pid, :initialize_complete)
    end

    assert :ok = manual_registry_call(holder.pid, {:enqueue_output, "123456"})

    # Suspended, the holder cannot act on its close, so its row stays closing
    # while its process is alive.
    true = :erlang.suspend_process(holder.pid)
    assert :ok = manual_registry_call(candidate.pid, {:enqueue_output, "12345"})
    assert Process.alive?(holder.pid)

    provisional =
      provisional_mirror(holder, "closing-session", self(), :crypto.strong_rand_bytes(16), 1)

    assert {:error, :connection_not_live} =
             apply_mirror(registry, registry_incarnation, :install_provisional, provisional)

    assert %{routing_mirrors: 0} = ConnectionRegistry.status(registry)
    true = :erlang.resume_process(holder.pid)
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

  # Technical depth: the connection must start before the initialize deadline
  # and then expire while the listener still owns it; 300 ms leaves a loaded
  # machine room to start it, where 30 ms did not.
  test "expiry while listener-owned requires exact close acknowledgement and child reap" do
    registry = start_registry(300)
    accepted_at = now_ms()

    assert {:ok, %{rollback_token: token}} =
             ConnectionRegistry.reserve(registry, self(), make_ref(), accepted_at)

    assert {:ok, connection, _incarnation} =
             ConnectionRegistry.start_connection(registry, token)

    assert_receive {:close_accepted, ^token}, 2_000
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

  # Concept (T10): a relay step the registry is waiting on delays only the
  # flow that needs it; the routing mirror is still applied and acknowledged.
  #
  # Technical depth: the registry is bound to a scripted relay that is never
  # told to answer, so the create promotion's relay step stays parked.
  test "the registry acknowledges a mirror while its relay step is parked" do
    registry = start_registry(5_000, connection_module: ManualConnection)
    {relay, registry_incarnation} = bind_scripted_relay(registry)
    connection = initialized_manual_connection(registry)

    _caller = spawn_promotion(registry)
    assert_receive {:relay_request, ^relay, _from, {:promote_ticket, _, _, _, _}}, 500

    mirror = provisional_mirror(connection, "parked-session", self(), incarnation(), 1)
    assert :ok = apply_mirror(registry, registry_incarnation, :install_provisional, mirror)
    assert %{provisional_routing_mirrors: 1} = ConnectionRegistry.status(registry)
    assert %{relay_flow: %{}} = :sys.get_state(registry)
  end

  # Concept (T21, partial: the registry side only; the full witness needs the
  # later lease-owner step): once the transport cut has begun the stop, a
  # relay request left unanswered past its instant is never reported.
  #
  # Technical depth: the promotion's relay request is sent while serving, so
  # its five-second instant is armed; the owner then closes the transport
  # gate, and the instant passes with no report.
  @tag timeout: 30_000
  test "a relay request overtaken by the transport cut is never reported" do
    registry = start_registry(5_000)
    {relay, _registry_incarnation} = bind_scripted_relay(registry)

    started = now_ms()
    _caller = spawn_promotion(registry)
    assert_receive {:relay_request, ^relay, _from, {:promote_ticket, _, _, _, _}}, 500
    assert %{relay_flow: %{timer: timer}} = :sys.get_state(registry)
    assert is_reference(timer)

    cut(registry)

    refute_receive {:registry_relay_unanswered, ^registry, _incarnation},
                   max(started + 5_600 - now_ms(), 0)

    assert %{relay_flow: %{timer: nil}} = :sys.get_state(registry)
    assert Process.alive?(registry)
  end

  # Concept: a relay request sent after the cut belongs to the stop and
  # carries no instant of its own.
  test "no request instant is armed for a relay request sent after the cut" do
    registry = start_registry(5_000)
    {relay, _registry_incarnation} = bind_scripted_relay(registry)
    cut(registry)

    _caller = spawn_promotion(registry)
    assert_receive {:relay_request, ^relay, _from, {:promote_ticket, _, _, _, _}}, 500
    assert %{relay_flow: %{timer: nil}} = :sys.get_state(registry)
  end

  # Concept (F1): after the stop has begun, a settlement the relay no longer
  # accepts is cleanup-only; the registry keeps serving.
  test "a settlement refused after the cut is cleanup-only" do
    registry = start_registry(5_000)
    {relay, _registry_incarnation} = bind_scripted_relay(registry)
    monitor = Process.monitor(registry)
    settle = settling_promotion(registry, relay)

    cut(registry)
    GenServer.reply(settle.from, {:error, :ticket_unavailable})

    refute_receive {:DOWN, ^monitor, :process, ^registry, _reason}, 200
    assert %{relay_flow: nil, activation_promotions: promotions} = :sys.get_state(registry)
    assert promotions == %{}
  end

  # Concept (F1): once the relay tears down, every remaining flow is
  # abandoned: queued and later callers hear `relay_unavailable` at once,
  # the settlement in flight is dropped, and the relay is asked nothing more.
  test "the relay's teardown abandons every remaining relay flow" do
    registry = start_registry(5_000)
    {relay, _registry_incarnation} = bind_scripted_relay(registry)
    settle = settling_promotion(registry, relay)

    first = spawn_promotion(registry)
    second = spawn_promotion(registry)
    eventually(fn -> :queue.len(:sys.get_state(registry).relay_flow_queue) == 2 end)

    send(registry, {:registry_tearing_down, self()})

    assert_receive {:promotion_result, ^first, {:error, :relay_unavailable}}, 500
    assert_receive {:promotion_result, ^second, {:error, :relay_unavailable}}, 500

    late = spawn_promotion(registry)
    assert_receive {:promotion_result, ^late, {:error, :relay_unavailable}}, 500
    refute_receive {:relay_request, ^relay, _from, _request}, 100

    assert %{relay_flow: nil, activation_promotions: promotions} = :sys.get_state(registry)
    refute Map.has_key?(promotions, settle.settlement_ref)
  end

  # Concept: a relay that exits under queued flows ends each call flow as
  # `relay_unavailable` and abandons each settlement, and the registry keeps
  # serving; the daemon owner classifies the relay.
  test "a relay exit ends queued calls as relay_unavailable and abandons settlements" do
    registry = start_registry(5_000)
    {relay, _registry_incarnation} = bind_scripted_relay(registry)
    monitor = Process.monitor(registry)
    settle = settling_promotion(registry, relay)

    first = spawn_promotion(registry)
    second = spawn_promotion(registry)
    eventually(fn -> :queue.len(:sys.get_state(registry).relay_flow_queue) == 2 end)

    Process.exit(relay, :kill)

    assert_receive {:promotion_result, ^first, {:error, :relay_unavailable}}, 500
    assert_receive {:promotion_result, ^second, {:error, :relay_unavailable}}, 500
    refute_receive {:DOWN, ^monitor, :process, ^registry, _reason}, 100

    assert %{relay_flow: nil, activation_promotions: promotions} = :sys.get_state(registry)
    refute Map.has_key?(promotions, settle.settlement_ref)
  end

  # Concept (F4, R3): a resume cancellation is answered at once, never waits
  # behind the relay queue, and removes the queued preparation it cancels.
  test "a resume cancellation removes its queued preparation without waiting" do
    registry = start_registry(5_000)
    {relay, _registry_incarnation} = bind_scripted_relay(registry)

    _blocker = spawn_promotion(registry)
    assert_receive {:relay_request, ^relay, blocker, {:promote_ticket, _, _, _, _}}, 500

    origin = {incarnation(), 3, 1}
    owner_incarnation = incarnation()
    prepare = raw_call(registry, prepare_request(origin, owner_incarnation))
    eventually(fn -> :sys.get_state(registry).relay_flow_count == 1 end)

    cancel = raw_call(registry, {:cancel_prepared_resume, origin, owner_incarnation})
    assert_receive {^cancel, :ok}, 200
    assert_receive {^prepare, {:error, :relay_unavailable}}, 200

    GenServer.reply(blocker, {:error, :ticket_unavailable})
    refute_receive {:relay_request, ^relay, _from, {:authorize_resume_ticket, _, _, _, _}}, 200
    refute_receive {^prepare, _second}, 50

    assert %{activation_preparations: 0, activation_reservations: 0} =
             ConnectionRegistry.status(registry)
  end

  # Concept (R3): a cancellation reaching a preparation whose relay step is in
  # flight is answered at once, and that preparation records nothing.
  test "a resume cancellation during its preparation's relay step records nothing" do
    registry = start_registry(5_000)
    {relay, _registry_incarnation} = bind_scripted_relay(registry)
    origin = {incarnation(), 3, 1}
    owner_incarnation = incarnation()

    prepare = raw_call(registry, prepare_request(origin, owner_incarnation))

    assert_receive {:relay_request, ^relay, authorize,
                    {:authorize_resume_ticket, ^origin, _, _, _}},
                   500

    cancel = raw_call(registry, {:cancel_prepared_resume, origin, owner_incarnation})
    assert_receive {^cancel, :ok}, 200

    GenServer.reply(authorize, :ok)
    assert_receive {^prepare, {:error, :relay_unavailable}}, 500
    refute_receive {^prepare, _second}, 50

    assert %{activation_preparations: 0, activation_reservations: 0} =
             ConnectionRegistry.status(registry)
  end

  # Concept (R1): teardown abandons an in-flight create once: its caller hears
  # `promotion_outcome_unknown` exactly once, its reservation and promotion are
  # released, and the relay's late answer is ignored.
  test "teardown abandons an in-flight create once and releases its reservation" do
    registry = start_registry(5_000)
    {relay, _registry_incarnation} = bind_scripted_relay(registry)
    monitor = Process.monitor(registry)

    create = raw_call(registry, create_request({incarnation(), 0, 1}, :fresh))
    assert_receive {:relay_request, ^relay, from, {:promote_ticket, origin, _, _, _}}, 500
    assert %{activation_reservations: 1} = ConnectionRegistry.status(registry)

    send(registry, {:registry_tearing_down, self()})
    assert_receive {^create, {:error, :promotion_outcome_unknown}}, 500

    GenServer.reply(from, {:ok, origin})
    refute_receive {^create, _second}, 100
    refute_receive {:DOWN, ^monitor, :process, ^registry, _reason}, 50

    assert %{relay_flow: nil, activation_promotions: promotions} = :sys.get_state(registry)
    assert promotions == %{}
    assert %{activation_reservations: 0} = ConnectionRegistry.status(registry)
  end

  # Concept (R1): teardown abandons an in-flight replacement attach once: the
  # connection hears `promotion_outcome_unknown` exactly once, the promotion is
  # dropped and the connection's previous attachment is restored.
  test "teardown abandons an in-flight attach once and restores the previous attachment" do
    registry = start_registry(5_000, connection_module: ManualConnection)
    {relay, _registry_incarnation} = bind_scripted_relay(registry)
    connection = initialized_manual_connection(registry)
    activate(registry, "attach-session")
    install_attachment(registry, relay, connection, "attach-session", 1, "attachment-1")

    replacement = attach_async(registry, connection, "attach-session", 2, "attachment-2")
    assert_receive {:relay_request, ^relay, from, {:promote_ticket, origin, _, _, _}}, 500

    send(registry, {:registry_tearing_down, self()})
    eventually(fn -> is_nil(:sys.get_state(registry).relay_flow) end)
    GenServer.reply(from, {:ok, origin})

    assert [{:error, :promotion_outcome_unknown}] = connection_replies(connection, replacement)

    assert %{attachments: attachments, activation_promotions: promotions} =
             :sys.get_state(registry)

    assert %{phase: :installed, attachment_id: "attachment-1"} =
             Map.fetch!(attachments, connection.incarnation)

    assert promotions == %{}
    refute_receive {:registry_attachment, ^registry, _, :closed, _, _, _, _}, 50
  end

  # Concept (R1): teardown abandons an in-flight resume promotion once: its
  # lease owner hears `promotion_outcome_unknown` exactly once and its claimed
  # preparation, reservation and promotion are all released.
  test "teardown abandons an in-flight resume promotion once and releases it" do
    registry = start_registry(5_000)
    {relay, _registry_incarnation} = bind_scripted_relay(registry)
    origin = {incarnation(), 4, 1}
    owner_incarnation = incarnation()

    prepare = raw_call(registry, prepare_request(origin, owner_incarnation))

    assert_receive {:relay_request, ^relay, authorize, {:authorize_resume_ticket, _, _, _, _}},
                   500

    GenServer.reply(authorize, :ok)
    assert_receive {^prepare, {:ok, :prepared}}, 500

    promote = raw_call(registry, promote_resume_request(origin, owner_incarnation))
    assert_receive {:relay_request, ^relay, from, {:promote_ticket, ^origin, _, _, _, _}}, 500

    send(registry, {:registry_tearing_down, self()})
    assert_receive {^promote, {:error, :promotion_outcome_unknown}}, 500
    GenServer.reply(from, {:ok, origin})
    refute_receive {^promote, _second}, 100

    state = :sys.get_state(registry)
    assert state.activation_promotions == %{}
    assert state.activation_promotion_bindings == %{}

    assert %{activation_preparations: 0, activation_reservations: 0} =
             ConnectionRegistry.status(registry)
  end

  # Concept (R1): teardown abandons a preparation whose authorization is in
  # flight once, recording nothing.
  test "teardown abandons an in-flight resume authorization once" do
    registry = start_registry(5_000)
    {relay, _registry_incarnation} = bind_scripted_relay(registry)
    origin = {incarnation(), 5, 1}

    prepare = raw_call(registry, prepare_request(origin, incarnation()))

    assert_receive {:relay_request, ^relay, authorize, {:authorize_resume_ticket, _, _, _, _}},
                   500

    send(registry, {:registry_tearing_down, self()})
    assert_receive {^prepare, {:error, :relay_unavailable}}, 500
    GenServer.reply(authorize, :ok)
    refute_receive {^prepare, _second}, 100

    assert %{activation_preparations: 0, activation_reservations: 0} =
             ConnectionRegistry.status(registry)
  end

  # Concept (R2): a continuation re-checks its connection's row. A refused
  # replacement attach for a connection that is retiring restores nothing and
  # closes the attachment it would have replaced, once.
  test "a refused attach for a retiring connection closes its previous attachment once" do
    registry =
      start_registry(5_000,
        connection_module: ManualConnection,
        connection_context: %{runtime: :unavailable_runtime, relay: spawn(fn -> :ok end)}
      )

    {relay, _registry_incarnation} = bind_scripted_relay(registry)
    connection = initialized_manual_connection(registry)
    activate(registry, "attach-session")
    install_attachment(registry, relay, connection, "attach-session", 1, "attachment-1")

    _replacement = attach_async(registry, connection, "attach-session", 2, "attachment-2")
    assert_receive {:relay_request, ^relay, pending, {:promote_ticket, _, _, _, _}}, 500

    Process.exit(connection.pid, :kill)
    eventually(fn -> retiring?(registry, connection.incarnation) end)
    assert retiring?(registry, connection.incarnation)

    GenServer.reply(pending, {:error, :ticket_unavailable})
    eventually(fn -> is_nil(:sys.get_state(registry).relay_flow) end)

    assert_receive {:registry_attachment, ^registry, nil, :closed, "attach-session", _, _,
                    "attachment-1"},
                   500

    refute_receive {:registry_attachment, ^registry, _, _, _, _, _, "attachment-1"}, 100
    refute Map.has_key?(:sys.get_state(registry).attachments, connection.incarnation)
  end

  # Concept (b): a connection that goes away while its replacement attach is
  # pending closes the attachment it would have replaced, exactly once.
  test "a connection lost during a pending replacement closes its previous attachment once" do
    registry = start_registry(5_000, connection_module: ManualConnection)
    {relay, _registry_incarnation} = bind_scripted_relay(registry)
    connection = initialized_manual_connection(registry)
    activate(registry, "attach-session")
    install_attachment(registry, relay, connection, "attach-session", 1, "attachment-1")

    _replacement = attach_async(registry, connection, "attach-session", 2, "attachment-2")
    assert_receive {:relay_request, ^relay, pending, {:promote_ticket, _, _, _, _}}, 500

    Process.exit(connection.pid, :kill)

    assert_receive {:registry_attachment, ^registry, nil, :closed, "attach-session", _, _,
                    "attachment-1"},
                   500

    GenServer.reply(pending, {:error, :ticket_unavailable})
    eventually(fn -> is_nil(:sys.get_state(registry).relay_flow) end)
    refute_receive {:registry_attachment, ^registry, _, _, _, _, _, "attachment-1"}, 100
    refute Map.has_key?(:sys.get_state(registry).attachments, connection.incarnation)
  end

  # Concept (R4): after an invalidation during a pending replacement, the
  # replacement's success opens the new attachment once and closes nothing,
  # and the connection's later loss closes only the new attachment.
  test "an attachment invalidated during a pending replacement is closed once on success" do
    registry = start_registry(5_000, connection_module: ManualConnection)
    {relay, _registry_incarnation} = bind_scripted_relay(registry)
    connection = initialized_manual_connection(registry)
    activate(registry, "attach-session")
    install_attachment(registry, relay, connection, "attach-session", 1, "attachment-1")

    replacement = attach_async(registry, connection, "attach-session", 2, "attachment-2")
    assert_receive {:relay_request, ^relay, from, {:promote_ticket, origin, _, ref, task}}, 500
    invalidate(registry, connection, "attachment-1")

    assert_receive {:registry_attachment, ^registry, nil, :closed, "attach-session", _, _,
                    "attachment-1"},
                   500

    GenServer.reply(from, {:ok, origin})
    assert [{:ok, :admitted}] = connection_replies(connection, replacement)
    send(registry, {:relay_ticket_settlement, relay, origin, ref, task.()})

    assert_receive {:registry_attachment, ^registry, record_ref, :opened, "attach-session", _, _,
                    "attachment-2"},
                   500

    refute_receive {:registry_attachment, ^registry, _, _, _, _, _, "attachment-1"}, 100
    send(registry, {:owner_attachment_recorded, self(), record_ref})
    assert_receive {:relay_request, ^relay, settle, {:settle_ticket, ^origin, _, ^ref}}, 500
    GenServer.reply(settle, :ok)

    Process.exit(connection.pid, :kill)

    assert_receive {:registry_attachment, ^registry, nil, :closed, "attach-session", _, _,
                    "attachment-2"},
                   500

    refute_receive {:registry_attachment, ^registry, _, _, _, _, _, "attachment-1"}, 100
    refute_receive {:registry_attachment, ^registry, _, :opened, _, _, _, _}, 50
  end

  # Concept (R5): a resume whose settlement the relay refuses after the cut
  # still gives its lease owner its classified disposition.
  test "a resume settlement refused after the cut still settles its lease owner" do
    registry = start_registry(5_000)
    {relay, _registry_incarnation} = bind_scripted_relay(registry)
    owner_incarnation = incarnation()
    {settle, origin} = settling_resume(registry, relay, owner_incarnation)

    cut(registry)
    GenServer.reply(settle, {:error, :ticket_unavailable})

    assert_receive {:registry_resume_settled, ^registry, ^origin, ^owner_incarnation, :accepted},
                   500

    refute_receive {:registry_resume_settled, ^registry, _, _, _}, 100
    assert :sys.get_state(registry).activation_promotion_bindings == %{}
  end

  # Concept (carried requirement 2): while serving, a resume's settlement
  # the relay refuses ends the registry instead of settling the lease owner,
  # so a lease owner never hears a resume settled without the relay's own
  # ticket settlement while the daemon serves.
  test "a resume settlement refused while serving ends the registry without a notice" do
    Process.flag(:trap_exit, true)
    registry = start_registry(5_000)
    {relay, _registry_incarnation} = bind_scripted_relay(registry)
    owner_incarnation = incarnation()
    {settle, _origin} = settling_resume(registry, relay, owner_incarnation)

    GenServer.reply(settle, {:error, :ticket_unavailable})

    assert_receive {:EXIT, ^registry, :activation_settlement_failed}, 500
    refute_received {:registry_resume_settled, ^registry, _, _, _}
  end

  # Concept (R5): a resume whose settlement is abandoned at teardown still
  # gives its lease owner its classified disposition.
  test "a resume settlement abandoned at teardown still settles its lease owner" do
    registry = start_registry(5_000)
    {relay, _registry_incarnation} = bind_scripted_relay(registry)
    owner_incarnation = incarnation()
    {settle, origin} = settling_resume(registry, relay, owner_incarnation)

    send(registry, {:registry_tearing_down, self()})

    assert_receive {:registry_resume_settled, ^registry, ^origin, ^owner_incarnation, :accepted},
                   500

    GenServer.reply(settle, :ok)
    refute_receive {:registry_resume_settled, ^registry, _, _, _}, 100
  end

  # Concept (R6): at most 16,384 relay flows wait in the registry's queue; a
  # call beyond that is refused at once with `relay_unavailable`, and once
  # the queue drains a new call is accepted again.
  #
  # Technical depth: the queued calls reply to a sink process, so the test's
  # own mailbox holds only the relay requests it answers while draining.
  @tag timeout: 120_000
  test "a relay flow beyond the queue bound is refused at once" do
    registry = start_registry(5_000)
    {relay, _registry_incarnation} = bind_scripted_relay(registry)
    sink = spawn(fn -> sink_loop() end)
    on_exit(fn -> Process.exit(sink, :kill) end)

    _blocker = spawn_promotion(registry)
    assert_receive {:relay_request, ^relay, blocker, {:promote_ticket, _, _, _, _}}, 500

    for sequence <- 1..16_384 do
      send(
        registry,
        {:"$gen_call", {sink, make_ref()},
         create_request({incarnation(), rem(sequence, 32), sequence}, :historical)}
      )
    end

    assert %{relay_flow_count: 16_384} = :sys.get_state(registry, 30_000)

    beyond = raw_call(registry, create_request({incarnation(), 0, 1}, :historical))
    assert_receive {^beyond, {:error, :relay_unavailable}}, 1_000
    assert %{relay_flow_count: 16_384} = :sys.get_state(registry, 30_000)

    GenServer.reply(blocker, {:error, :ticket_unavailable})

    for _ <- 1..16_384 do
      assert_receive {:relay_request, ^relay, from, {:promote_ticket, _, _, _, _}}, 5_000
      GenServer.reply(from, {:error, :ticket_unavailable})
    end

    assert %{relay_flow_count: 0, relay_flow: nil} = :sys.get_state(registry, 30_000)

    accepted = raw_call(registry, create_request({incarnation(), 1, 1}, :historical))
    assert_receive {:relay_request, ^relay, from, {:promote_ticket, origin, _, _, _}}, 500
    GenServer.reply(from, {:ok, origin})
    assert_receive {^accepted, {:ok, :admitted}}, 500
  end

  # Concept (F1): with a recorded but unsettled attach and a later pending
  # replacement on the same connection, the connection's loss closes the
  # attachment the pending replacement would have replaced, once, and never
  # the one the recorded attach already closed.
  #
  # Technical depth: the recorded promotion is re-keyed to sort first, so the
  # search over promotions meets it before the pending one on every run.
  test "a lost connection closes only the pending replacement's previous attachment" do
    registry = start_registry(5_000, connection_module: ManualConnection)
    {relay, _registry_incarnation} = bind_scripted_relay(registry)
    connection = initialized_manual_connection(registry)
    activate(registry, "attach-session")
    install_attachment(registry, relay, connection, "attach-session", 1, "attachment-1")

    recorded_ref =
      record_unacknowledged(registry, relay, connection, "attach-session", 2, "attachment-2")

    assert_receive {:registry_attachment, ^registry, nil, :closed, _, _, _, "attachment-1"}, 500

    _pending = attach_async(registry, connection, "attach-session", 3, "attachment-3")
    assert_receive {:relay_request, ^relay, _from, {:promote_ticket, _, _, _, _}}, 500
    sort_promotion_first(registry, recorded_ref)

    Process.exit(connection.pid, :kill)

    assert_receive {:registry_attachment, ^registry, nil, :closed, "attach-session", _, _,
                    "attachment-2"},
                   500

    refute_receive {:registry_attachment, ^registry, _, :closed, _, _, _, "attachment-1"}, 100
    refute_receive {:registry_attachment, ^registry, _, :closed, _, _, _, "attachment-2"}, 50
  end

  # Concept (F1): invalidating an attachment a recorded attach has already
  # replaced and closed closes nothing again, even while a later replacement
  # is pending.
  test "invalidating an already replaced attachment during a pending attach closes nothing" do
    registry = start_registry(5_000, connection_module: ManualConnection)
    {relay, _registry_incarnation} = bind_scripted_relay(registry)
    connection = initialized_manual_connection(registry)
    activate(registry, "attach-session")
    install_attachment(registry, relay, connection, "attach-session", 1, "attachment-1")

    _recorded =
      record_unacknowledged(registry, relay, connection, "attach-session", 2, "attachment-2")

    assert_receive {:registry_attachment, ^registry, nil, :closed, _, _, _, "attachment-1"}, 500

    _pending = attach_async(registry, connection, "attach-session", 3, "attachment-3")
    assert_receive {:relay_request, ^relay, _from, {:promote_ticket, _, _, _, _}}, 500

    invalidate(registry, connection, "attachment-1")
    refute_receive {:registry_attachment, ^registry, _, :closed, _, _, _, _}, 100
  end

  # Concept (F2): a resume settlement still queued at teardown is accounted
  # from core's classification: the activated session joins the activation
  # set, its reservation is resolved and its lease owner hears the classified
  # disposition exactly once.
  test "a queued resume settlement abandoned at teardown accounts its classification" do
    registry = start_registry(5_000)
    {relay, _registry_incarnation} = bind_scripted_relay(registry)
    owner_incarnation = incarnation()
    origin = {incarnation(), 6, 1}

    promote = raw_call(registry, promote_resume_request(origin, owner_incarnation))

    assert_receive {:relay_request, ^relay, from, {:promote_ticket, ^origin, _, ref, task, _}},
                   500

    GenServer.reply(from, {:ok, origin})
    assert_receive {^promote, {:ok, :admitted}}, 500

    _blocker = spawn_promotion(registry)
    assert_receive {:relay_request, ^relay, _blocker_from, {:promote_ticket, _, _, _, _}}, 500
    send(registry, {:relay_ticket_settlement, relay, origin, ref, task.()})
    eventually(fn -> :sys.get_state(registry).relay_flow_count == 1 end)
    assert %{activation_reservations: 1} = ConnectionRegistry.status(registry)

    send(registry, {:registry_tearing_down, self()})

    assert_receive {:registry_resume_settled, ^registry, ^origin, ^owner_incarnation, :accepted},
                   500

    refute_receive {:registry_resume_settled, ^registry, _, _, _}, 100
    assert %{activation_reservations: 0} = ConnectionRegistry.status(registry)
    assert :sys.get_state(registry).activation_promotions == %{}
    assert MapSet.member?(:sys.get_state(registry).activation_set, "dormant-session")
  end

  # Concept (F2): a create settlement still queued at teardown is accounted
  # from core's classification: the created session joins the activation set
  # and its reservation is resolved.
  test "a queued create settlement abandoned at teardown accounts its classification" do
    registry = start_registry(5_000)
    {relay, _registry_incarnation} = bind_scripted_relay(registry)

    create =
      raw_call(
        registry,
        create_request({incarnation(), 0, 1}, :fresh, fn ->
          {:activated, "created-session", %{"result" => "created"}}
        end)
      )

    assert_receive {:relay_request, ^relay, from, {:promote_ticket, origin, _, ref, task}}, 500
    GenServer.reply(from, {:ok, origin})
    assert_receive {^create, {:ok, :admitted}}, 500

    _blocker = spawn_promotion(registry)
    assert_receive {:relay_request, ^relay, _blocker_from, {:promote_ticket, _, _, _, _}}, 500
    send(registry, {:relay_ticket_settlement, relay, origin, ref, task.()})
    eventually(fn -> :sys.get_state(registry).relay_flow_count == 1 end)
    assert %{activation_reservations: 1} = ConnectionRegistry.status(registry)

    send(registry, {:registry_tearing_down, self()})
    eventually(fn -> :sys.get_state(registry).relay_flow_count == 0 end)

    assert %{activation_reservations: 0} = ConnectionRegistry.status(registry)
    assert :sys.get_state(registry).activation_promotions == %{}
    assert MapSet.member?(:sys.get_state(registry).activation_set, "created-session")
  end

  # Concept (round 5): a queued settlement whose classification cannot be
  # accounted at teardown is released rather than fatal, and one fixed line
  # records it; the lease owner still hears its disposition.
  test "an unaccountable settlement at teardown is released with one fixed log line" do
    registry = start_registry(5_000)
    {relay, _registry_incarnation} = bind_scripted_relay(registry)
    activate(registry, "active-session")
    owner_incarnation = incarnation()
    origin = {incarnation(), 7, 1}

    promote =
      raw_call(
        registry,
        {:promote_resume, origin, "active-session", "attached-resume", owner_incarnation,
         :eligible, true, %{"refusal" => "control"}, %{"refusal" => "capacity"},
         fn -> {:accepted, :activated, %{"resume" => "accepted"}} end}
      )

    assert_receive {:relay_request, ^relay, from, {:promote_ticket, ^origin, _, ref, task, _}},
                   500

    GenServer.reply(from, {:ok, origin})
    assert_receive {^promote, {:ok, :admitted}}, 500

    _blocker = spawn_promotion(registry)
    assert_receive {:relay_request, ^relay, _blocker_from, {:promote_ticket, _, _, _, _}}, 500
    send(registry, {:relay_ticket_settlement, relay, origin, ref, task.()})
    eventually(fn -> :sys.get_state(registry).relay_flow_count == 1 end)

    # The session is taken out of the activation set, so its classification
    # can no longer be accounted.
    :sys.replace_state(registry, fn state ->
      %{state | activation_set: MapSet.delete(state.activation_set, "active-session")}
    end)

    monitor = Process.monitor(registry)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        send(registry, {:registry_tearing_down, self()})

        assert_receive {:registry_resume_settled, ^registry, ^origin, ^owner_incarnation,
                        :accepted},
                       500
      end)

    assert log =~ "loopex daemon unsettled activation released without accounting"
    refute log =~ "active-session"
    refute_receive {:DOWN, ^monitor, :process, ^registry, _reason}, 50
  end

  # Concept (round 5): after teardown abandons an in-flight promotion, its
  # late classification and relay settlement are cleanup-only: the registry
  # stays alive and answers nothing further.
  test "a late classification and settlement after abandonment are cleanup-only" do
    registry = start_registry(5_000)
    {relay, _registry_incarnation} = bind_scripted_relay(registry)
    monitor = Process.monitor(registry)

    create = raw_call(registry, create_request({incarnation(), 0, 1}, :historical))
    assert_receive {:relay_request, ^relay, _from, {:promote_ticket, origin, _, ref, task}}, 500

    send(registry, {:registry_tearing_down, self()})
    assert_receive {^create, {:error, :promotion_outcome_unknown}}, 500

    result = task.()
    send(registry, {:relay_ticket_settlement, relay, origin, ref, result})

    refute_receive {:DOWN, ^monitor, :process, ^registry, _reason}, 200
    refute_receive {^create, _second}, 50
    assert %{activation_promotions: promotions} = :sys.get_state(registry)
    assert promotions == %{}
  end

  # Concept (round 5b): while serving, a classification or relay settlement
  # for a promotion the registry does not hold is an invalid settlement and
  # still ends the registry, with the attach arm's own reason.
  for {arm, reason} <- [
        create: :activation_settlement_invalid,
        resume: :activation_settlement_invalid,
        attach: :attachment_settlement_invalid,
        settlement: :activation_settlement_invalid
      ] do
    test "a #{arm} message for a missing promotion while serving stops the registry" do
      Process.flag(:trap_exit, true)
      registry = start_registry(5_000)
      {relay, _registry_incarnation} = bind_scripted_relay(registry)
      monitor = Process.monitor(registry)

      send(registry, late_message(unquote(arm), relay))

      assert_receive {:DOWN, ^monitor, :process, ^registry, unquote(reason)}, 500
    end
  end

  # Concept (round 5b): after the cut, with no teardown and no flow
  # abandoned, a classification or relay settlement for a promotion the
  # registry does not hold is cleanup-only on every arm.
  test "a message for a missing promotion after the cut is cleanup-only on every arm" do
    registry = start_registry(5_000)
    {relay, _registry_incarnation} = bind_scripted_relay(registry)
    monitor = Process.monitor(registry)
    cut(registry)
    assert %{relay_flows_abandoned: false, transport: :closing} = :sys.get_state(registry)

    for arm <- [:create, :resume, :attach, :settlement] do
      send(registry, late_message(arm, relay))
    end

    refute_receive {:DOWN, ^monitor, :process, ^registry, _reason}, 200
    assert %{activation_promotions: promotions} = :sys.get_state(registry)
    assert promotions == %{}
  end

  # Concept (F3): a resume settlement in flight when the relay exits still
  # gives its lease owner the classified disposition, exactly once.
  test "a resume settlement ended by the relay's exit still settles its lease owner" do
    registry = start_registry(5_000)
    {relay, _registry_incarnation} = bind_scripted_relay(registry)
    owner_incarnation = incarnation()
    {_settle, origin} = settling_resume(registry, relay, owner_incarnation)

    Process.exit(relay, :kill)

    assert_receive {:registry_resume_settled, ^registry, ^origin, ^owner_incarnation, :accepted},
                   500

    refute_receive {:registry_resume_settled, ^registry, _, _, _}, 100
    assert %{activation_reservations: 0} = ConnectionRegistry.status(registry)
  end

  # Concept (F4, R4): an attachment invalidated while its connection's
  # replacement attach waits on the relay is closed then, once; the
  # replacement's refusal cannot restore it and the connection's loss does not
  # close it again.
  test "an attachment invalidated during a pending replacement is not restored" do
    registry = start_registry(5_000, connection_module: ManualConnection)
    {relay, _registry_incarnation} = bind_scripted_relay(registry)
    connection = initialized_manual_connection(registry)
    activate(registry, "attach-session")
    install_attachment(registry, relay, connection, "attach-session", 1, "attachment-1")

    replacement = attach_async(registry, connection, "attach-session", 2, "attachment-2")
    assert_receive {:relay_request, ^relay, pending, {:promote_ticket, _, _, _, _}}, 500
    invalidate(registry, connection, "attachment-1")

    assert_receive {:registry_attachment, ^registry, nil, :closed, "attach-session", _, _,
                    "attachment-1"},
                   500

    GenServer.reply(pending, {:error, :ticket_unavailable})
    assert [{:error, :ticket_unavailable}] = connection_replies(connection, replacement)
    refute Map.has_key?(:sys.get_state(registry).attachments, connection.incarnation)

    Process.exit(connection.pid, :kill)
    refute_receive {:registry_attachment, ^registry, _, _, _, _, _, "attachment-1"}, 200
  end

  # Concept: a queued attach decides on the state current when it leaves the
  # queue, as the blocking registry did when it reached the call.
  test "a queued attach decides on the state current when it is dequeued" do
    registry = start_registry(5_000, connection_module: ManualConnection)
    {relay, _registry_incarnation} = bind_scripted_relay(registry)
    connection = initialized_manual_connection(registry)

    _blocker = spawn_promotion(registry)
    assert_receive {:relay_request, ^relay, blocker, {:promote_ticket, _, _, _, _}}, 500

    _attach = attach_async(registry, connection, "late-session", 1, "attachment-1")
    eventually(fn -> :queue.len(:sys.get_state(registry).relay_flow_queue) == 1 end)
    activate(registry, "late-session")
    GenServer.reply(blocker, {:error, :ticket_unavailable})

    assert_receive {:relay_request, ^relay, _from, {:promote_ticket, _, _, _, _task}}, 500

    assert %{attachments: %{} = attachments} = :sys.get_state(registry)
    assert %{phase: :pending} = Map.fetch!(attachments, connection.incarnation)
  end

  # A relay stand-in: each request it receives is reported with its caller's
  # reply handle, and the test answers it with `GenServer.reply/2`.
  defp bind_scripted_relay(registry) do
    test = self()
    relay = spawn(fn -> scripted_relay_loop(test) end)
    on_exit(fn -> Process.exit(relay, :kill) end)
    registry_incarnation = :crypto.strong_rand_bytes(16)
    assert :ok = ConnectionRegistry.bind_relay(registry, relay, registry_incarnation)
    {relay, registry_incarnation}
  end

  defp scripted_relay_loop(test) do
    receive do
      {:"$gen_call", from, request} ->
        send(test, {:relay_request, self(), from, request})
        scripted_relay_loop(test)
    end
  end

  defp spawn_promotion(registry) do
    test = self()

    spawn(fn ->
      result =
        registry
        |> ConnectionRegistry.promote_create_request(
          {:crypto.strong_rand_bytes(16), 0, 1},
          "command",
          :crypto.hash(:sha256, "options"),
          :historical,
          %{"refusal" => "ceiling"},
          %{"refusal" => "conflict"},
          fn -> {:no_activation, nil, %{"result" => "none"}} end
        )
        |> :gen_server.receive_response(5_000)
        |> case do
          {:reply, reply} -> reply
          _no_reply -> :call_exit
        end

      send(test, {:promotion_result, self(), result})
    end)
  end

  # A create promotion admitted and classified, whose settlement request is
  # now the registry's relay step in flight.
  defp settling_promotion(registry, relay) do
    caller = spawn_promotion(registry)
    assert_receive {:relay_request, ^relay, from, {:promote_ticket, origin, _, ref, task}}, 500
    GenServer.reply(from, {:ok, origin})
    assert_receive {:promotion_result, ^caller, {:ok, :admitted}}, 500
    send(registry, {:relay_ticket_settlement, relay, origin, ref, task.()})
    assert_receive {:relay_request, ^relay, settle, {:settle_ticket, ^origin, _, ^ref}}, 500
    %{from: settle, settlement_ref: ref}
  end

  # Sends a promotion from the connection itself with a plain reply tag, so
  # the connection stays free for its other registry calls and its replies
  # can be counted.
  defp attach_async(registry, connection, session_id, slot, attachment_id) do
    tag = make_ref()

    request =
      {:promote_attach, {connection.incarnation, slot, 1}, connection.incarnation, session_id,
       %{"refusal" => "dormant"}, %{"refusal" => "capacity"},
       fn -> {:installed, attachment_id, %{"attachment" => attachment_id}} end}

    assert :ok =
             manual_registry_call(
               connection.pid,
               {:invoke,
                fn ->
                  send(registry, {:"$gen_call", {self(), tag}, request})
                  :ok
                end}
             )

    tag
  end

  # An attach admitted and recorded at the daemon owner, whose settlement
  # waits for the owner's acknowledgement; returns its settlement reference.
  defp record_unacknowledged(registry, relay, connection, session_id, slot, attachment_id) do
    tag = attach_async(registry, connection, session_id, slot, attachment_id)
    assert_receive {:relay_request, ^relay, from, {:promote_ticket, origin, _, ref, task}}, 500
    GenServer.reply(from, {:ok, origin})
    assert [{:ok, :admitted}] = connection_replies(connection, tag)
    send(registry, {:relay_ticket_settlement, relay, origin, ref, task.()})

    assert_receive {:registry_attachment, ^registry, record_ref, :opened, ^session_id, _, _,
                    ^attachment_id},
                   500

    assert is_reference(record_ref)
    ref
  end

  # Re-keys one promotion under the smallest settlement reference, so a
  # search over the promotion map meets it first.
  defp sort_promotion_first(registry, settlement_ref) do
    :sys.replace_state(registry, fn state ->
      {promotion, promotions} = Map.pop!(state.activation_promotions, settlement_ref)
      %{state | activation_promotions: Map.put(promotions, <<0::128>>, promotion)}
    end)
  end

  defp retiring?(registry, incarnation) do
    Enum.any?(:sys.get_state(registry).rows, fn {_token, row} ->
      row.connection_incarnation == incarnation and row.phase == :retiring
    end)
  end

  defp sink_loop do
    receive do
      _message -> sink_loop()
    end
  end

  # A classification or relay settlement naming a settlement reference the
  # registry holds no promotion for.
  defp late_message(:create, _relay),
    do:
      {:activation_create_classified, make_ref(), :crypto.strong_rand_bytes(16), :no_activation,
       nil, %{"result" => "late"}}

  defp late_message(:resume, _relay),
    do:
      {:activation_resume_classified, make_ref(), :crypto.strong_rand_bytes(16), :accepted,
       :activated, %{"result" => "late"}}

  defp late_message(:attach, _relay),
    do:
      {:attachment_classified, make_ref(), :crypto.strong_rand_bytes(16),
       {:refused, %{"result" => "late"}}}

  defp late_message(:settlement, relay),
    do:
      {:relay_ticket_settlement, relay, {incarnation(), 0, 1}, :crypto.strong_rand_bytes(16),
       %{"result" => "late"}}

  # Sends a call to the registry with a plain tag, so every reply it sends
  # arrives here as `{tag, reply}` and a second reply would be seen.
  defp raw_call(registry, request) do
    tag = make_ref()
    send(registry, {:"$gen_call", {self(), tag}, request})
    tag
  end

  defp prepare_request(origin, owner_incarnation),
    do:
      {:prepare_resume, origin, "dormant-session", "resume-command", owner_incarnation, :eligible}

  defp promote_resume_request(origin, owner_incarnation) do
    {:promote_resume, origin, "dormant-session", "resume-command", owner_incarnation, :eligible,
     false, %{"refusal" => "control"}, %{"refusal" => "capacity"},
     fn -> {:accepted, :activated, %{"resume" => "accepted"}} end}
  end

  defp create_request(
         origin,
         mode,
         task \\ fn -> {:no_activation, nil, %{"result" => "none"}} end
       ) do
    command_id = Base.encode16(:crypto.strong_rand_bytes(8))

    {:promote_create, origin, command_id, :crypto.hash(:sha256, command_id), mode,
     %{"refusal" => "ceiling"}, %{"refusal" => "conflict"}, task}
  end

  # A resume promotion admitted and classified, whose settlement request is
  # now the registry's relay step in flight; the test process is its owner.
  defp settling_resume(registry, relay, owner_incarnation) do
    origin = {incarnation(), 6, 1}
    promote = raw_call(registry, promote_resume_request(origin, owner_incarnation))

    assert_receive {:relay_request, ^relay, from, {:promote_ticket, ^origin, _, ref, task, _}},
                   500

    GenServer.reply(from, {:ok, origin})
    assert_receive {^promote, {:ok, :admitted}}, 500
    send(registry, {:relay_ticket_settlement, relay, origin, ref, task.()})
    assert_receive {:relay_request, ^relay, settle, {:settle_ticket, ^origin, _, ^ref}}, 500
    {settle, origin}
  end

  # Installs one attachment for the connection through a full attach flow.
  defp install_attachment(registry, relay, connection, session_id, slot, attachment_id) do
    installed = attach_async(registry, connection, session_id, slot, attachment_id)
    assert_receive {:relay_request, ^relay, from, {:promote_ticket, origin, _, ref, task}}, 500
    GenServer.reply(from, {:ok, origin})
    assert [{:ok, :admitted}] = connection_replies(connection, installed)
    send(registry, {:relay_ticket_settlement, relay, origin, ref, task.()})

    assert_receive {:registry_attachment, ^registry, record_ref, :opened, ^session_id, _, _,
                    ^attachment_id},
                   500

    send(registry, {:owner_attachment_recorded, self(), record_ref})
    assert_receive {:relay_request, ^relay, settle, {:settle_ticket, ^origin, _, ^ref}}, 500
    GenServer.reply(settle, :ok)
    eventually(fn -> is_nil(:sys.get_state(registry).relay_flow) end)
  end

  defp invalidate(registry, connection, attachment_id) do
    assert :ok =
             manual_registry_call(
               connection.pid,
               {:invoke,
                fn ->
                  ConnectionRegistry.attachment_invalidated(
                    registry,
                    connection.incarnation,
                    attachment_id
                  )
                end}
             )
  end

  # Every registry reply the connection has received under `tag` so far.
  defp connection_replies(connection, tag) do
    manual_registry_call(
      connection.pid,
      {:invoke,
       fn ->
         Stream.repeatedly(fn ->
           receive do
             {^tag, reply} -> {:reply, reply}
           after
             50 -> :none
           end
         end)
         |> Enum.take_while(&(&1 != :none))
         |> Enum.map(fn {:reply, reply} -> reply end)
       end}
    )
  end

  defp activate(registry, session_id) do
    origin = {incarnation(), 31, 1}

    assert {:ok, {:primary, reservation_ref}} =
             ConnectionRegistry.reserve_activation(
               registry,
               origin,
               {:resume, session_id, "activate"}
             )

    assert :ok =
             ConnectionRegistry.resolve_activation(
               registry,
               reservation_ref,
               :activated,
               session_id
             )
  end

  defp cut(registry) do
    cut_ref = make_ref()
    assert {:ok, ^cut_ref} = reply_value(ConnectionRegistry.transport_closing(registry, cut_ref))
  end

  defp incarnation, do: :crypto.strong_rand_bytes(16)

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
        "loopex-registry-socket-#{Loopex.TestTmp.Daemon.token()}"
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
