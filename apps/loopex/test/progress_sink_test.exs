defmodule Loopex.ProgressSinkTest do
  use ExUnit.Case, async: false

  alias Loopex.ProgressSink, as: Sink

  setup do
    {:ok, sink} = Sink.open()
    {guardian, _incarnation, arena} = sink

    on_exit(fn ->
      monitor = Process.monitor(guardian)
      assert_receive {:DOWN, ^monitor, :process, ^guardian, _reason}, 5_000
      assert :ets.info(arena) == :undefined
    end)

    %{sink: sink}
  end

  test "one closed native item retains exact session identity and original bytes", %{sink: sink} do
    item = text("hello")
    assert :ok = Sink.try_offer(sink, <<0, 255>>, item)
    assert {:ok, lease, <<0, 255>>, ^item} = Sink.take(sink)
    assert :ok = Sink.release(sink, lease)
    assert :empty = Sink.take(sink)
    assert :ok = Sink.close(sink)
  end

  test "all accepted ordinary and compaction kinds retain their complete closed members", %{
    sink: sink
  } do
    items = [
      text("text"),
      %{text("thought") | kind: :reasoning_delta},
      Map.merge(common(), %{
        kind: :tool_call_delta,
        model_sequence: 0,
        call_index: 0,
        tool_call_id: nil,
        name: nil,
        arguments_fragment: nil
      }),
      Map.merge(common(), %{
        kind: :tool_progress,
        tool_call_id: "tool",
        progress_sequence: 0,
        stream: "stdout",
        byte_offset: 0,
        chunk: "chunk"
      }),
      Map.merge(common(), %{kind: :model_stream_closed, disposition: :complete, delta_count: 7}),
      Map.merge(common(), %{
        kind: :tool_stream_closed,
        tool_call_id: "tool",
        disposition: :abandoned,
        progress_count: 3
      }),
      %{
        kind: "context.compaction_progress",
        episode_id: "episode",
        owner: %{"kind" => "run", "id" => "run"},
        stream_domain_id: String.duplicate("a", 32),
        progress_sequence: 0,
        base_event_sequence: 0
      }
    ]

    for item <- items do
      assert :ok = Sink.try_offer(sink, "session", item)
      assert {:ok, lease, "session", ^item} = Sink.take(sink)
      assert :ok = Sink.release(sink, lease)
    end

    assert :ok = Sink.close(sink)
  end

  test "slot ceiling includes every taken lease and frees only proved custody", %{sink: sink} do
    for index <- 0..31,
        do: assert(:ok == Sink.try_offer(sink, "s", %{text("x") | model_sequence: index}))

    assert :dropped = Sink.try_offer(sink, "s", text("overflow"))

    leases =
      for _ <- 0..31 do
        assert {:ok, lease, "s", _item} = Sink.take(sink)
        lease
      end

    assert :empty = Sink.take(sink)
    assert :dropped = Sink.try_offer(sink, "s", text("still held"))
    assert occupied(sink) == 32
    assert :ok = Sink.release(sink, hd(leases))
    assert :ok = Sink.try_offer(sink, "s", text("replacement"))
    assert :dropped = Sink.try_offer(sink, "s", text("overflow again"))
    for lease <- tl(leases), do: assert(:ok == Sink.release(sink, lease))
    assert {:ok, last, "s", _item} = Sink.take(sink)
    assert :ok = Sink.release(sink, last)
    assert :ok = Sink.close(sink)
  end

  test "exact conservative byte ceiling admits and its first extra byte refuses", %{sink: sink} do
    # Concept: independent vectors preserve the exact ceiling on both supported pairs.
    # Technical depth: OTP 27 reports heap-binary bits from referenced_byte_size;
    # OTP 28+ converts them to bytes. Keep production's conservative charge intact.
    session_id = :binary.copy("session1")
    turn_id = :binary.copy("turn0001")
    domain_id = :binary.copy("a", 32)
    backing = Enum.map([session_id, turn_id, domain_id], &:binary.referenced_byte_size/1)

    {bytes, identity_charge} =
      case backing do
        [8, 8, 32] -> {64_976, 384}
        [64, 64, 256] -> {64_892, 1_056}
        other -> flunk("Unexpected copied identity backing: #{inspect(other)}")
      end

    assert byte_size(session_id) == 8
    assert byte_size(turn_id) == 8
    assert byte_size(domain_id) == 32
    payload = :binary.copy("a", bytes)
    assert byte_size(payload) == bytes
    assert :binary.referenced_byte_size(payload) == bytes
    assert 4_096 + identity_charge + 8 * bytes == 524_288
    item = %{text(payload) | turn_id: turn_id, stream_domain_id: domain_id}

    assert :ok = Sink.try_offer(sink, session_id, item)
    assert charged(sink) == 524_288
    assert :dropped = Sink.try_offer(sink, session_id, %{item | text: :binary.copy("")})
    assert {:ok, lease, ^session_id, ^item} = Sink.take(sink)
    assert charged(sink) == 524_288
    assert :ok = Sink.release(sink, lease)
    assert charged(sink) == 0
    extra = :binary.copy("a", bytes + 1)
    assert byte_size(extra) == bytes + 1
    assert :binary.referenced_byte_size(extra) == bytes + 1
    assert 4_096 + identity_charge + 8 * (bytes + 1) == 524_296
    assert :dropped = Sink.try_offer(sink, session_id, %{item | text: extra})
    assert charged(sink) == 0
    assert :ok = Sink.close(sink)
  end

  test "charge includes escaped text base64 identities and backing storage before materialization",
       %{sink: sink} do
    session_id = :binary.copy("session1")

    item = %{
      text(:binary.copy("\n", 128))
      | turn_id: :binary.copy(<<0, 255, 0, 255, 0, 255, 0, 255>>),
        stream_domain_id: :binary.copy("a", 32)
    }

    expected =
      case Enum.map(
             [session_id, item.turn_id, item.stream_domain_id],
             &:binary.referenced_byte_size/1
           ) do
        [8, 8, 32] -> 5_504
        [64, 64, 256] -> 6_176
        other -> flunk("Unexpected copied identity backing: #{inspect(other)}")
      end

    assert byte_size(session_id) == 8
    assert byte_size(item.turn_id) == 8
    assert byte_size(item.stream_domain_id) == 32
    assert byte_size(item.text) == 128
    assert :binary.referenced_byte_size(item.text) == 128
    assert :ok = Sink.try_offer(sink, session_id, item)
    assert charged(sink) == expected
    assert {:ok, lease, ^session_id, ^item} = Sink.take(sink)
    assert :ok = Sink.release(sink, lease)

    backing = :binary.copy("a", 524_288)
    piece = binary_part(backing, 1, 1_024)
    assert :binary.referenced_byte_size(piece) == byte_size(backing)
    assert :dropped = Sink.try_offer(sink, session_id, %{item | text: piece})
    assert occupied(sink) == 0
    detached = :binary.copy(piece)
    assert :binary.referenced_byte_size(detached) == byte_size(detached)
    assert :ok = Sink.try_offer(sink, session_id, %{item | text: detached})
    assert :ok = Sink.close(sink)
  end

  test "session population shares one resident record and byte budget", %{sink: sink} do
    for index <- 1..32, do: assert(:ok == Sink.try_offer(sink, "session-#{index}", text("x")))
    assert occupied(sink) == 32
    assert :dropped = Sink.try_offer(sink, "new-session", text("x"))
    assert charged(sink) <= 524_288
    assert :ok = Sink.close(sink)
  end

  test "finite closed preflight rejects private unknown and oversized members without charging",
       %{sink: sink} do
    for item <- [
          self(),
          %{text("x") | text: self()},
          Map.put(text("x"), :private, make_ref()),
          Map.delete(text("x"), :text),
          Map.put(text("x"), "kind", :text_delta),
          %{text("x") | text: <<255>>},
          %{text("x") | text: "\e[31m"},
          %{text("x") | text: :binary.copy("a", 65_537)},
          %{text("x") | model_sequence: -1},
          %{text("x") | model_sequence: 18_446_744_073_709_551_616},
          %{text("x") | content_index: 9_007_199_254_740_992},
          %{text("x") | stream_domain_id: String.duplicate("A", 32)},
          %{text("x") | turn_id: ""},
          Map.put(text("x"), :__struct__, __MODULE__)
        ] do
      assert :dropped = Sink.try_offer(sink, "s", item)
      assert charged(sink) == 0
      assert occupied(sink) == 0
    end

    for session <- [nil, "", :binary.copy("s", 257), self(), make_ref()] do
      assert :dropped = Sink.try_offer(sink, session, text("x"))
    end

    assert :ok = Sink.close(sink)
  end

  test "opaque native handles reject every foreign incarnation guardian arena and extra member",
       %{sink: sink} do
    {guardian, incarnation, arena} = sink

    for invalid <- [
          nil,
          self(),
          {guardian, make_ref(), arena},
          {self(), incarnation, arena},
          {guardian, incarnation, make_ref()},
          {guardian, incarnation, arena, :extra}
        ] do
      assert :dropped = Sink.try_offer(invalid, "s", text("x"))
      assert :closed = Sink.take(invalid)
      assert {:error, :stale_lease} = Sink.release(invalid, {incarnation, 0, make_ref()})
      assert {:error, :cleanup_unproved} = Sink.close(invalid)
    end

    assert :ok = Sink.close(sink)
  end

  test "only the opening host takes releases and closes custody", %{sink: sink} do
    assert :ok = Sink.try_offer(sink, "s", text("x"))
    assert {:ok, lease, "s", _item} = Sink.take(sink)
    parent = self()

    {worker, monitor} =
      owned_worker(fn ->
        send(parent, {:foreign, Sink.take(sink), Sink.release(sink, lease), Sink.close(sink)})
      end)

    assert_receive {:foreign, :closed, {:error, :stale_lease}, {:error, :cleanup_unproved}}, 5_000
    assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 5_000
    assert occupied(sink) == 1
    assert :ok = Sink.release(sink, lease)
    assert :ok = Sink.close(sink)
  end

  test "foreign duplicate malformed and reused leases cannot reduce capacity", %{sink: sink} do
    assert :ok = Sink.try_offer(sink, "s", text("one"))
    assert {:ok, {incarnation, slot, token} = original, "s", _item} = Sink.take(sink)

    for wrong <- [
          nil,
          {make_ref(), slot, token},
          {incarnation, 32, token},
          {incarnation, slot, make_ref()},
          {incarnation, slot, token, :extra}
        ] do
      assert {:error, :stale_lease} = Sink.release(sink, wrong)
    end

    assert :ok = Sink.release(sink, original)
    assert {:error, :stale_lease} = Sink.release(sink, original)
    assert :ok = Sink.try_offer(sink, "s", text("two"))
    assert {:ok, {^incarnation, ^slot, next_token} = current, "s", _item} = Sink.take(sink)
    refute next_token == token
    assert {:error, :stale_lease} = Sink.release(sink, original)
    assert occupied(sink) == 1
    assert :ok = Sink.release(sink, current)
    assert :ok = Sink.close(sink)
  end

  test "resident-only close discards before native guardian join", %{sink: sink} do
    {guardian, _incarnation, arena} = sink
    monitor = Process.monitor(guardian)
    for _ <- 1..32, do: assert(:ok == Sink.try_offer(sink, "s", text("x")))
    assert :ok = Sink.close(sink)
    assert_receive {:DOWN, ^monitor, :process, ^guardian, :normal}, 5_000
    assert :ets.info(arena) == :undefined
    assert :dropped = Sink.try_offer(sink, "s", text("late"))
    assert :closed = Sink.take(sink)
  end

  test "close never calls an outstanding lease successful cleanup and stays sealed", %{sink: sink} do
    assert :ok = Sink.try_offer(sink, "s", text("x"))
    assert {:ok, lease, "s", _item} = Sink.take(sink)
    assert {:error, :cleanup_unproved} = Sink.close(sink)
    assert :dropped = Sink.try_offer(sink, "s", text("late"))
    assert :closed = Sink.take(sink)
    assert charged(sink) > 0
    assert :ok = Sink.release(sink, lease)
    assert :ok = Sink.close(sink)
  end

  test "guardian suspension does not queue reservation requests or payloads", %{sink: sink} do
    {guardian, _incarnation, _arena} = sink
    :ok = :sys.suspend(guardian)

    try do
      for _ <- 1..32, do: assert(:ok == Sink.try_offer(sink, "s", text("x")))
      for _ <- 1..64, do: assert(:dropped == Sink.try_offer(sink, "s", text("overflow")))
      assert {:message_queue_len, queued} = Process.info(guardian, :message_queue_len)
      assert queued <= 1
      assert occupied(sink) == 32
    after
      :ok = :sys.resume(guardian)
    end

    assert :ok = Sink.close(sink)
  end

  test "failed offers generate no ready notification while admitted items coalesce", %{sink: sink} do
    {guardian, _incarnation, _arena} = sink
    for _ <- 1..32, do: assert(:ok == Sink.try_offer(sink, "s", text("x")))
    assert_receive {:loopex_progress_ready, ^sink}, 5_000
    # Put the received notification back so take's actual acknowledgement owns it.
    send(self(), {:loopex_progress_ready, sink})
    for _ <- 1..64, do: assert(:dropped == Sink.try_offer(sink, "s", text("overflow")))
    :ok = :sys.suspend(guardian)

    try do
      assert_receive {:loopex_progress_ready, ^sink}
      refute_receive {:loopex_progress_ready, ^sink}, 20
      send(self(), {:loopex_progress_ready, sink})
    after
      :ok = :sys.resume(guardian)
    end

    leases =
      for _ <- 1..32 do
        assert {:ok, lease, "s", _item} = Sink.take(sink)
        lease
      end

    for lease <- leases, do: assert(:ok == Sink.release(sink, lease))
    assert :empty = Sink.take(sink)
    assert :ok = Sink.close(sink)
  end

  test "producer death after actual publication cannot retire ready or leased owner custody", %{
    sink: sink
  } do
    parent = self()

    {producer, monitor} =
      owned_worker(fn ->
        send(parent, {:offered, Sink.try_offer(sink, "s", text("x"))})
      end)

    assert_receive {:offered, :ok}, 5_000
    assert_receive {:DOWN, ^monitor, :process, ^producer, :normal}, 5_000
    assert {:ok, lease, "s", item} = Sink.take(sink)
    assert item == text("x")
    {guardian, _incarnation, _arena} = sink
    # A guardian mailbox barrier exercises cleanup without acknowledging custody.
    _state = :sys.get_state(guardian)
    assert occupied(sink) == 1
    assert :ok = Sink.release(sink, lease)
    assert :ok = Sink.close(sink)
  end

  test "exact unfinished-reservation fault retains charge until original producer DOWN", %{
    sink: sink
  } do
    parent = self()

    {producer, monitor} =
      owned_worker(fn ->
        receive do
          :finish -> send(parent, :finished)
        end
      end)

    token = inject_reservation(sink, producer, 4_512)
    assert occupied(sink) == 1
    assert charged(sink) == 4_512
    assert {:error, :cleanup_unproved} = Sink.close(sink)
    assert slot(sink, 0) == {token, :reserved, producer, 4_512}
    send(producer, :finish)
    assert_receive :finished, 5_000
    assert_receive {:DOWN, ^monitor, :process, ^producer, :normal}, 5_000
    {guardian, _incarnation, _arena} = sink
    # DOWN delivery is a native actor event; the barrier alone is not its proof.
    wait_until_reclaimed(guardian, sink, 100)
    assert charged(sink) == 0
    assert :ok = Sink.close(sink)
  end

  test "old abort marker cannot retire a fresh slot generation", %{sink: sink} do
    assert :ok = Sink.try_offer(sink, "s", text("one"))
    assert {:ok, {_incarnation, index, old_token} = lease, "s", _item} = Sink.take(sink)
    assert :ok = Sink.release(sink, lease)
    assert :ok = Sink.try_offer(sink, "s", text("two"))
    {_guardian, _incarnation, arena} = sink
    :ets.insert(arena, {{:retired, index}, old_token})
    assert {:ok, current, "s", item} = Sink.take(sink)
    assert item == text("two")
    assert :ok = Sink.release(sink, current)
    assert :ok = Sink.close(sink)
  end

  test "metadata CAS never overwrites a changed generation or transfers another holder", %{
    sink: sink
  } do
    {_guardian, _incarnation, arena} = sink
    [before] = :ets.lookup(arena, :state)
    assert :ok = Sink.try_offer(sink, "s", text("x"))
    forged = before |> put_elem(4, 0) |> put_elem(5, List.duplicate(nil, 32) |> List.to_tuple())
    assert :ets.select_replace(arena, [{before, [], [{:const, forged}]}]) == 0
    assert occupied(sink) == 1
    assert {:ok, lease, "s", _item} = Sink.take(sink)
    assert :ok = Sink.release(sink, lease)
    assert :ok = Sink.close(sink)
  end

  test "concurrent finite offers preserve exact aggregate accounting and fixed resident keys", %{
    sink: sink
  } do
    parent = self()

    workers =
      for index <- 1..64 do
        owned_worker(fn ->
          receive do
            :offer -> :ok
          end

          send(parent, {:result, self(), Sink.try_offer(sink, "session-#{index}", text("x"))})
        end)
      end

    for {pid, _monitor} <- workers, do: send(pid, :offer)

    results =
      for {pid, monitor} <- workers do
        assert_receive {:result, ^pid, result}, 5_000
        assert result in [:ok, :dropped]
        assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 5_000
        result
      end

    admitted = Enum.count(results, &(&1 == :ok))
    assert admitted > 0 and admitted <= 32
    {guardian, _incarnation, _arena} = sink
    captured = state(sink)
    completed = Enum.map(workers, &elem(&1, 0))

    expected_slots =
      for custody <- Tuple.to_list(elem(captured, 5)) do
        case custody do
          {_token, stage, producer, _charge} when stage in [:reserved, :retiring] ->
            assert producer in completed
            nil

          {_token, :ready, owner, _charge} ->
            assert owner == self()
            custody

          nil ->
            nil
        end
      end

    assert Enum.count(expected_slots, &(not is_nil(&1))) == admitted

    expected_bytes =
      Enum.reduce(expected_slots, 0, fn
        {_token, :ready, _owner, charge}, total -> total + charge
        nil, total -> total
      end)

    expected =
      captured |> put_elem(4, expected_bytes) |> put_elem(5, List.to_tuple(expected_slots))

    # Actual worker DOWN was observed above. A captured exact-row settlement
    # waits for guardian reclamation without treating an instantaneous count as proof.
    wait_until_state(guardian, sink, expected, 100)
    assert state(sink) == expected
    assert occupied(sink) == admitted
    assert charged(sink) <= 524_288
    {_guardian, _incarnation, arena} = sink
    assert :ets.select_count(arena, [{{{:payload, :_}, :_, :_, :_}, [], [true]}]) == admitted

    for _ <- 1..admitted do
      assert {:ok, lease, _session, _item} = Sink.take(sink)
      assert :ok = Sink.release(sink, lease)
    end

    assert :ok = Sink.close(sink)
  end

  test "actual concurrent offers spend at most 32 metadata comparisons before returning", %{
    sink: sink
  } do
    parent = self()
    {_guardian, _incarnation, arena} = sink
    :erlang.trace_pattern({Sink, :replace, 3}, true, [:local])

    try do
      workers =
        for index <- 1..64 do
          {pid, _monitor} =
            owned_worker(fn ->
              receive do
                :offer -> :ok
              end

              result = Sink.try_offer(sink, "s-#{index}", text("x"))
              send(parent, {:traced_result, self(), result})

              receive do
                :finish -> :ok
              end
            end)

          :erlang.trace(pid, true, [:call, {:tracer, parent}])
          pid
        end

      for pid <- workers, do: send(pid, :offer)

      for pid <- workers do
        assert_receive {:traced_result, ^pid, result}, 5_000
        assert result in [:ok, :dropped]
      end

      barriers = for pid <- workers, do: {pid, :erlang.trace_delivered(pid)}
      counts = trace_counts(arena, Map.new(workers, &{&1, 0}), barriers)
      assert Enum.any?(counts, fn {_pid, count} -> count >= 2 end)
      assert Enum.all?(counts, fn {_pid, count} -> count <= 32 end)

      for pid <- workers do
        :erlang.trace(pid, false, [:call])
        monitor = Process.monitor(pid)
        send(pid, :finish)
        assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 5_000
      end
    after
      :erlang.trace_pattern({Sink, :replace, 3}, false, [:local])
    end

    assert :ok = Sink.close(sink)
  end

  test "close invalidates the actual open-row preimage before a late reservation can publish", %{
    sink: sink
  } do
    {guardian, incarnation, arena} = sink

    {producer, monitor} =
      owned_worker(fn ->
        receive do
          :finish -> :ok
        end
      end)

    token = inject_reservation(sink, producer, 4_512)
    [open] = :ets.lookup(arena, :state)
    assert {:error, :cleanup_unproved} = Sink.close(sink)
    next_slots = put_elem(elem(open, 5), 0, {token, :ready, self(), 4_512})
    stale_publish = open |> put_elem(5, next_slots) |> put_elem(6, [0])
    assert :ets.select_replace(arena, [{open, [], [{:const, stale_publish}]}]) == 0
    assert elem(state(sink), 3) == :closed
    assert elem(state(sink), 1) == incarnation
    send(producer, :finish)
    assert_receive {:DOWN, ^monitor, :process, ^producer, :normal}, 5_000
    wait_until_reclaimed(guardian, sink, 100)
    assert :ok = Sink.close(sink)
  end

  test "guardian death invalidates resident tokens and all future offers", %{sink: sink} do
    {guardian, _incarnation, arena} = sink
    assert :ok = Sink.try_offer(sink, "s", text("x"))
    assert {:ok, lease, "s", _item} = Sink.take(sink)
    monitor = Process.monitor(guardian)
    Process.exit(guardian, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^guardian, :killed}, 5_000
    assert :ets.info(arena) == :undefined
    assert :dropped = Sink.try_offer(sink, "s", text("late"))
    assert :closed = Sink.take(sink)
    assert {:error, :stale_lease} = Sink.release(sink, lease)
    assert {:error, :cleanup_unproved} = Sink.close(sink)
  end

  test "opening owner death retires its guardian without an external cleanup acknowledgement", %{
    sink: fixture
  } do
    parent = self()

    {owner, monitor} =
      owned_worker(fn ->
        {:ok, sink} = Sink.open()
        assert :ok = Sink.try_offer(sink, "s", text("x"))
        send(parent, {:owned_sink, sink})

        receive do
          :finish -> :ok
        end
      end)

    assert_receive {:owned_sink, {guardian, _incarnation, arena} = sink}, 5_000
    guardian_monitor = Process.monitor(guardian)
    send(owner, :finish)
    assert_receive {:DOWN, ^monitor, :process, ^owner, :normal}, 5_000
    assert_receive {:DOWN, ^guardian_monitor, :process, ^guardian, :normal}, 5_000
    assert :ets.info(arena) == :undefined
    assert :dropped = Sink.try_offer(sink, "s", text("late"))
    assert {:error, :cleanup_unproved} = Sink.close(sink)
    assert :ok = Sink.close(fixture)
  end

  test "preflight rejects huge compound keys and nonatom ordinary kinds before admission", %{
    sink: sink
  } do
    huge = List.duplicate(:binary.copy("k", 1_024), 65_536)
    tuple_key = {huge, huge}
    map_key = %{tuple_key => huge}

    for key <- [huge, tuple_key, map_key] do
      item = text("x") |> Map.delete(:text) |> Map.put(key, "x")
      assert map_size(item) == map_size(text("x"))
      assert :dropped = Sink.try_offer(sink, "s", item)
      assert :dropped = Sink.try_offer(sink, "s", %{text("x") | kind: key})
      assert occupied(sink) == 0
      assert charged(sink) == 0
    end

    assert :dropped = Sink.try_offer(sink, "s", %{text("x") | kind: :unknown_native_kind})
    assert :ok = Sink.try_offer(sink, "s", text("ordinary control"))
    assert :ok = Sink.close(sink)
  end

  test "actual release never writes a marker after transferring custody to retiring", %{
    sink: fixture
  } do
    parent = self()

    {owner, monitor} =
      owned_worker(fn ->
        {:ok, sink} = Sink.open()
        assert :ok = Sink.try_offer(sink, "s", text("x"))
        assert {:ok, lease, "s", _item} = Sink.take(sink)
        send(parent, {:release_fixture, sink})

        receive do
          :release -> :ok
        end

        {_guardian, _incarnation, arena} = sink
        [notification] = :ets.lookup(arena, :notification)
        :ets.insert(arena, notification)
        send(parent, {:released, Sink.release(sink, lease)})

        receive do
          :finish -> :ok
        end

        assert :ok = Sink.close(sink)
      end)

    assert_receive {:release_fixture, {_guardian, _incarnation, arena}}, 5_000
    [notification] = :ets.lookup(arena, :notification)
    assert :erlang.trace_pattern({:ets, :insert, 2}, true, [:local]) == 1

    try do
      :erlang.trace(owner, true, [:call, {:tracer, parent}])
      send(owner, :release)
      assert_receive {:released, :ok}, 5_000
      barrier = :erlang.trace_delivered(owner)
      writes = release_marker_writes(owner, arena, barrier, [])
      # The unchanged notification-row write is the positive trace control.
      # A late retired-marker write would add a second captured row.
      assert writes == [notification]
      :erlang.trace(owner, false, [:call])
      send(owner, :finish)
      assert_receive {:DOWN, ^monitor, :process, ^owner, :normal}, 5_000
      assert :ets.info(arena) == :undefined
    after
      :erlang.trace_pattern({:ets, :insert, 2}, false, [:local])
    end

    assert :ok = Sink.close(fixture)
  end

  test "injected retiring cut preserves a reused live producer marker and exposes the old overwrite control",
       %{sink: sink} do
    # Concept: a deterministic native-cut control isolates the release ABA race.
    # Technical depth: this injects the leased-to-retiring cut, not a suspension
    # inside release. Actual release's absent marker write is traced separately.
    assert :ok = Sink.try_offer(sink, "s", text("old"))
    assert {:ok, {_incarnation, index, old_token}, "s", _item} = Sink.take(sink)
    {guardian, _incarnation, arena} = sink
    assert index == 0
    :ok = :sys.suspend(guardian)

    try do
      [leased] = :ets.lookup(arena, :state)
      {^old_token, :leased, owner, charge} = elem(elem(leased, 5), index)

      retiring =
        put_elem(
          leased,
          5,
          put_elem(elem(leased, 5), index, {old_token, :retiring, owner, charge})
        )

      assert :ets.select_replace(arena, [{leased, [], [{:const, retiring}]}]) == 1
    after
      :ok = :sys.resume(guardian)
    end

    wait_until_reclaimed(guardian, sink, 100)
    assert charged(sink) == 0

    {producer, monitor} =
      owned_worker(fn ->
        receive do
          :finish -> :ok
        end
      end)

    :ok = :sys.suspend(guardian)

    token =
      try do
        token = inject_reservation(sink, producer, 4_512)
        refute token == old_token
        :ets.insert(arena, {{:retired, index}, token})
        assert :ets.lookup(arena, {:retired, index}) == [{{:retired, index}, token}]
        # The historical continuation is a deliberately injected negative control.
        # Its late unconditional write hides the new producer's completed abort.
        :ets.insert(arena, {{:retired, index}, old_token})
        token
      after
        :ok = :sys.resume(guardian)
      end

    assert {:error, :cleanup_unproved} = Sink.close(sink)
    assert slot(sink, index) == {token, :reserved, producer, 4_512}
    assert charged(sink) == 4_512
    assert Process.alive?(producer)
    # Positive control: preserve the new generation's exact completed-abort marker.
    :ets.insert(arena, {{:retired, index}, token})
    assert :ok = Sink.close(sink)
    assert Process.alive?(producer)
    send(producer, :finish)
    assert_receive {:DOWN, ^monitor, :process, ^producer, :normal}, 5_000
  end

  test "actual opening owner death retires all leased credit and rejects it in a fresh incarnation",
       %{
         sink: fixture
       } do
    parent = self()

    {owner, owner_monitor} =
      owned_worker(fn ->
        {:ok, owned} = Sink.open()
        send(parent, {:lease_owner_opened, self(), owned})

        receive do
          :hold_all -> :ok
        end

        for sequence <- 0..31 do
          assert :ok = Sink.try_offer(owned, "s", %{text("x") | model_sequence: sequence})
        end

        leases =
          for sequence <- 0..31 do
            assert {:ok, lease, "s", %{model_sequence: ^sequence}} = Sink.take(owned)
            lease
          end

        assert occupied(owned) == 32
        assert charged(owned) > 0 and charged(owned) <= 524_288
        assert {:error, :cleanup_unproved} = Sink.close(owned)
        send(parent, {:leased_owner_held, self(), leases, charged(owned)})

        receive do
          :finish -> :ok
        end
      end)

    {guardian, incarnation, arena} =
      owned =
      receive do
        {:lease_owner_opened, ^owner, opened} -> opened
      after
        5_000 -> flunk("missing opening owner's physical sink handle")
      end

    guardian_monitor = Process.monitor(guardian)

    try do
      send(owner, :hold_all)
      assert_receive {:leased_owner_held, ^owner, leases, credit}, 5_000
      assert length(leases) == 32
      assert elem(state(owned), 3) == :closed
      assert charged(owned) == credit
      assert occupied(owned) == 32

      assert Enum.map(leases, &elem(&1, 1)) |> Enum.sort() == Enum.to_list(0..31)

      for lease <- leases do
        assert {^incarnation, index, token} = lease
        assert {^token, :leased, ^owner, charge} = slot(owned, index)
        assert charge > 0
      end

      assert :dropped = Sink.try_offer(owned, "s", text("late while held"))
      Process.exit(owner, :kill)
      assert_receive {:DOWN, ^owner_monitor, :process, ^owner, :killed}, 5_000
      assert_receive {:DOWN, ^guardian_monitor, :process, ^guardian, :normal}, 5_000
      assert :ets.info(arena) == :undefined
      assert :closed = Sink.take(owned)
      assert {:error, :cleanup_unproved} = Sink.close(owned)
      assert :dropped = Sink.try_offer(owned, "s", text("after owner loss"))

      {:ok, fresh} = Sink.open()
      {fresh_guardian, fresh_incarnation, fresh_arena} = fresh

      on_exit(fn ->
        finish_custody_cleanup([
          fn ->
            monitor = Process.monitor(fresh_guardian)
            assert_receive {:DOWN, ^monitor, :process, ^fresh_guardian, _reason}, 5_000
          end,
          fn -> assert :ets.info(fresh_arena) == :undefined end
        ])
      end)

      try do
        refute fresh_incarnation == incarnation
        assert :ok = Sink.try_offer(fresh, "s", text("fresh"))
        assert {:ok, {^fresh_incarnation, 0, fresh_token} = current, "s", item} = Sink.take(fresh)
        assert item == text("fresh")
        fresh_credit = charged(fresh)

        for old <- leases do
          refute elem(old, 2) == fresh_token
          assert {:error, :stale_lease} = Sink.release(owned, old)
          assert {:error, :stale_lease} = Sink.release(fresh, old)
          assert occupied(fresh) == 1
          assert charged(fresh) == fresh_credit
        end

        assert :ok = Sink.release(fresh, current)
        assert charged(fresh) == 0 and occupied(fresh) == 0
        assert :ok = Sink.close(fresh)
      after
        Sink.close(fresh)
      end
    after
      finish_custody_cleanup([
        fn ->
          cleanup_owner = Process.monitor(owner)
          if Process.alive?(owner), do: Process.exit(owner, :kill)
          assert_receive {:DOWN, ^cleanup_owner, :process, ^owner, _reason}, 5_000
        end,
        fn ->
          cleanup_guardian = Process.monitor(guardian)
          assert_receive {:DOWN, ^cleanup_guardian, :process, ^guardian, _reason}, 5_000
        end
      ])
    end

    assert :ok = Sink.close(fixture)
  end

  test "actual publication survives producer death before notification and keeps credit through reuse",
       %{
         sink: sink
       } do
    parent = self()
    {guardian, incarnation, arena} = sink
    :ok = :sys.suspend(guardian)

    {token, credit} =
      try do
        {producer, producer_monitor} =
          owned_worker(fn ->
            send(
              parent,
              {:published_before_notify, self(), Sink.try_offer(sink, "s", text("original"))}
            )

            receive do
              :finish -> :ok
            end
          end)

        try do
          assert_receive {:published_before_notify, ^producer, :ok}, 5_000
          assert {token, :ready, owner, credit} = slot(sink, 0)
          assert owner == self()
          assert occupied(sink) == 1 and charged(sink) == credit and credit > 0
          assert [{{:payload, 0}, ^token, "s", item}] = :ets.lookup(arena, {:payload, 0})
          assert item == text("original")
          refute_received {:loopex_progress_ready, ^sink}
          Process.exit(producer, :kill)
          assert_receive {:DOWN, ^producer_monitor, :process, ^producer, :killed}, 5_000
          assert {^token, :ready, ^owner, ^credit} = slot(sink, 0)
          assert charged(sink) == credit
          {token, credit}
        after
          cleanup_producer = Process.monitor(producer)
          if Process.alive?(producer), do: Process.exit(producer, :kill)
          assert_receive {:DOWN, ^cleanup_producer, :process, ^producer, _reason}, 5_000
        end
      after
        :ok = :sys.resume(guardian)
      end

    assert_receive {:loopex_progress_ready, ^sink}, 5_000
    assert {:ok, {^incarnation, 0, ^token} = lease, "s", item} = Sink.take(sink)
    assert item == text("original")
    assert charged(sink) == credit and occupied(sink) == 1
    assert :ok = Sink.release(sink, lease)
    assert charged(sink) == 0 and occupied(sink) == 0
    assert :ok = Sink.try_offer(sink, "s", text("replacement"))
    assert {:ok, {^incarnation, 0, fresh_token} = next, "s", replacement} = Sink.take(sink)
    assert replacement == text("replacement")
    refute fresh_token == token
    replacement_credit = charged(sink)
    assert {:error, :stale_lease} = Sink.release(sink, lease)
    assert charged(sink) == replacement_credit and occupied(sink) == 1
    assert :ok = Sink.release(sink, next)
    assert :ok = Sink.close(sink)
  end

  # Concept: attempt every owned cleanup action even after another action fails.
  # Technical depth: retain the first original exception and stack; independent
  # physical joins and arena witnesses still run with their existing deadlines.
  defp finish_custody_cleanup(actions) do
    failure =
      Enum.reduce(actions, nil, fn action, first ->
        try do
          action.()
          first
        catch
          kind, reason -> first || {kind, reason, __STACKTRACE__}
        end
      end)

    case failure do
      nil -> :ok
      {kind, reason, stack} -> :erlang.raise(kind, reason, stack)
    end
  end

  defp trace_counts(_arena, counts, []), do: counts

  defp trace_counts(arena, counts, barriers) do
    receive do
      {:trace, pid, :call, {Sink, :replace, [^arena, _old, _next]}} ->
        trace_counts(arena, Map.update!(counts, pid, &(&1 + 1)), barriers)

      {:trace_delivered, pid, reference} ->
        assert {pid, reference} in barriers
        trace_counts(arena, counts, List.delete(barriers, {pid, reference}))
    after
      5_000 -> flunk("missing native trace barrier")
    end
  end

  defp owned_worker(fun) do
    {pid, monitor} = spawn_monitor(fun)

    on_exit(fn ->
      cleanup_monitor = Process.monitor(pid)
      if Process.alive?(pid), do: Process.exit(pid, :kill)
      assert_receive {:DOWN, ^cleanup_monitor, :process, ^pid, _reason}, 5_000
    end)

    {pid, monitor}
  end

  defp common,
    do: %{turn_id: "turn", stream_domain_id: String.duplicate("a", 32), base_event_sequence: 0}

  defp text(value),
    do:
      Map.merge(common(), %{kind: :text_delta, model_sequence: 0, content_index: 0, text: value})

  defp state({_guardian, _incarnation, arena}) do
    [row] = :ets.lookup(arena, :state)
    row
  end

  defp charged(sink), do: elem(state(sink), 4)
  defp slot(sink, index), do: elem(elem(state(sink), 5), index)

  defp occupied(sink),
    do: elem(state(sink), 5) |> Tuple.to_list() |> Enum.count(&(not is_nil(&1)))

  # Concept: this fixture injects the exact native crash cut without a test callback.
  # Technical depth: it does not claim suspension inside production reserve. Real
  # try_offer concurrency/publication is exercised separately; this arena row
  # tests discoverable custody, actual producer DOWN and conservative close.
  defp inject_reservation({_guardian, incarnation, arena}, producer, charge) do
    [old] = :ets.lookup(arena, :state)
    token = make_ref()
    slots = put_elem(elem(old, 5), 0, {token, :reserved, producer, charge})
    next = old |> put_elem(4, charge) |> put_elem(5, slots)
    assert :ets.select_replace(arena, [{old, [], [{:const, next}]}]) == 1
    assert elem(next, 1) == incarnation
    token
  end

  defp release_marker_writes(owner, arena, barrier, writes) do
    receive do
      {:trace, ^owner, :call, {:ets, :insert, [^arena, row]}} ->
        release_marker_writes(owner, arena, barrier, [row | writes])

      {:trace, ^owner, :call, {:ets, :insert, _arguments}} ->
        release_marker_writes(owner, arena, barrier, writes)

      {:trace_delivered, ^owner, ^barrier} ->
        writes
    after
      5_000 -> flunk("missing actual release trace barrier")
    end
  end

  defp wait_until_state(_guardian, sink, expected, 0), do: assert(state(sink) == expected)

  defp wait_until_state(guardian, sink, expected, remaining) do
    _state = :sys.get_state(guardian)

    if state(sink) != expected do
      receive do
      after
        10 -> :ok
      end

      wait_until_state(guardian, sink, expected, remaining - 1)
    end
  end

  defp wait_until_reclaimed(_guardian, sink, 0), do: assert(occupied(sink) == 0)

  defp wait_until_reclaimed(guardian, sink, remaining) do
    _state = :sys.get_state(guardian)

    if occupied(sink) != 0 do
      receive do
      after
        10 -> :ok
      end

      wait_until_reclaimed(guardian, sink, remaining - 1)
    end
  end
end
