Code.require_file("support/daemon_socket_fixture.exs", __DIR__)

defmodule LoopexDaemon.MaximumPopulationTest do
  use ExUnit.Case, async: false
  @moduletag capture_log: true

  import LoopexDaemon.Test.DaemonSocketFixture, only: [send_frame: 2, receive_records: 3]

  alias LoopexDaemon.Sentinel
  alias LoopexProtocol.{Session.V2, Wire}

  defmodule Policy do
    @moduledoc false
    @behaviour Loopex.Policy

    @impl Loopex.Policy
    def decide(_request), do: {:deny, :policy_denied}
  end

  @connections 512
  @sessions 8

  # Concept: the measurement behind `teardown_ms`: an orderly stop of a
  # daemon at its full population of 512 initialized, attached connections —
  # 64 attachments on each of 8 sessions — completes and reports its duration.
  #
  # Technical depth: every connection receives its `daemon.stopping` record or
  # sees its socket close, and the stop's wall time from the signal to the
  # sentinel's exit status is printed with the toolchain for the closure
  # evidence. The case asserts only that the stop succeeds inside the
  # provisional `teardown_ms` plus the fixed pre-teardown phases.
  @tag :long_bound
  @tag timeout: 900_000
  test "an orderly stop at the full connection and attachment population" do
    root =
      Path.join(
        System.tmp_dir!(),
        "lmp-#{Loopex.TestTmp.Daemon.token()}"
      )

    # A fresh, never-reused root: a crashed earlier run can leave its Store
    # behind, and a create replayed on it is answered historically, leaving the
    # session dormant in this daemon lifetime.
    File.mkdir!(root)
    workspace = Path.join(root, "w")
    File.mkdir!(workspace)
    on_exit(fn -> File.rm_rf(root) end)
    socket = Path.join([root, "s", "daemon", "d.sock"])

    options = [
      state_root: Path.join(root, "s"),
      socket_path: socket,
      workspace: workspace,
      policy: Policy,
      credential: "maximum-population-placeholder"
    ]

    {:ok, output} = StringIO.open("")
    test = self()

    daemon =
      Task.async(fn ->
        Sentinel.run(options, output: output, install_signals: false, notify: test)
      end)

    assert_receive {:loopex_daemon_sentinel, sentinel, owner_ref, _owner}, 5_000
    await_ready(output, 3_000)

    creator = client(socket)

    sessions =
      for index <- 1..@sessions do
        :ok =
          send_frame(creator, %{
            "method" => "session.create",
            "request_id" => "create-#{index}",
            "command_id" => Wire.encode_identity("population-#{index}"),
            "session_options" => %{}
          })

        [%{"status" => "accepted", "session_id" => encoded}] = receive_records(creator, 1, 30_000)
        encoded
      end

    :socket.close(creator)

    clients =
      for index <- 0..(@connections - 1) do
        client = client(socket)
        encoded = Enum.at(sessions, rem(index, @sessions))

        :ok =
          send_frame(client, %{
            "method" => "session.attach",
            "request_id" => "attach",
            "session_id" => encoded,
            "after_event_sequence" => "0"
          })

        [%{"type" => "snapshot"}] = receive_records(client, 1, 30_000)
        client
      end

    # Status is asked over an attached connection: at the full population a
    # further connection would be accepted and closed unread.
    probe = List.last(clients)
    :ok = send_frame(probe, %{"method" => "daemon.status", "request_id" => "status"})
    [%{"request_id" => "status", "result" => status}] = receive_records(probe, 1, 30_000)
    assert status["connections"] == @connections
    assert status["attachments"] == @connections

    # At the full population a second attach is refused locally, while an
    # explicit replacement of the connection's own attachment is net zero: it
    # delivers a fresh snapshot and the counts stay at the ceiling.
    probe_session = Enum.at(sessions, rem(@connections - 1, @sessions))
    attach = %{"method" => "session.attach", "session_id" => probe_session}
    :ok = send_frame(probe, Map.put(attach, "request_id", "second"))

    [%{"request_id" => "second", "code" => "attachment_conflict"}] =
      receive_records(probe, 1, 30_000)

    :ok = send_frame(probe, Map.merge(attach, %{"request_id" => "replace", "replace" => true}))
    [%{"request_id" => "replace", "type" => "snapshot"}] = receive_records(probe, 1, 30_000)
    :ok = send_frame(probe, %{"method" => "daemon.status", "request_id" => "after"})
    [%{"request_id" => "after", "result" => after_replace}] = receive_records(probe, 1, 30_000)
    assert after_replace["connections"] == @connections
    assert after_replace["attachments"] == @connections

    # The attachment ceiling bounds retained payload, not memory; the VM's
    # resident size at the full population is reported for the closure evidence.
    {rss, 0} = System.cmd("ps", ["-o", "rss=", "-p", System.pid()])

    IO.puts(
      "maximum-population RSS: connections=#{@connections} attachments=#{@connections} " <>
        "rss_kib=#{String.trim(rss)} otp=#{System.otp_release()}"
    )

    started = System.monotonic_time(:millisecond)
    send(sentinel, {:daemon_signal, owner_ref, :sigterm})
    assert Task.await(daemon, 600_000) == 0
    elapsed = System.monotonic_time(:millisecond) - started

    IO.puts(
      "maximum-population orderly stop: connections=#{@connections} attachments=#{@connections} " <>
        "elapsed_ms=#{elapsed} elixir=#{System.version()} otp=#{System.otp_release()}"
    )

    assert elapsed < 5_000 + 5_000 + 5_000 + 5_000 + 30_000
    Enum.each(clients, &:socket.close/1)
  end

  # Concept (T15): at the full population every lease-operation step the
  # daemon owner waits on — registry, relay and lease-owner steps, and the
  # holder's close — answers within its five-second step while the owner is
  # under load: grants, releases and owner losses run in the middle of two
  # bursts of 252 concurrent refused acquires, and the run ends in an orderly
  # stop.
  #
  # Technical depth: the daemon owner's private `enter_step/3`, its two
  # completion functions and its deadline path `late_action/4` are traced
  # with monotonic timestamps (nanoseconds). A step's duration runs from its
  # entry to the next transition of the same operation; a step that reaches
  # the deadline path is a failure and counts as at least 5,000 ms. The
  # distribution per class is printed and asserted before anything about the
  # workload's replies or the exit status, so a slow step fails here and
  # nowhere else first. Replies are read by request id and a missing one is
  # recorded, not raised, until the distribution has been judged. Every wait
  # is bounded: 30 s per reply, 60 s for the stop, 240 s for the case, and
  # `on_exit` kills the daemon and closes every connection. The bursts come
  # only from clients of sessions whose lease stays held, so no burst acquire
  # contends for a free lease; a burst that did — 64 connections acquiring one
  # unheld session at once — made the test VM itself fail with a segmentation
  # fault or a spinning scheduler on both toolchain pairs, which is recorded
  # for investigation rather than exercised here.
  @tag :long_bound
  @tag timeout: 240_000
  test "T15: every step answers within its instant at the full population" do
    root =
      Path.join(
        System.tmp_dir!(),
        "lms-#{Loopex.TestTmp.Daemon.token()}"
      )

    # A fresh, never-reused root: a crashed earlier run can leave its Store
    # behind, and a create replayed on it is answered historically, leaving the
    # session dormant in this daemon lifetime.
    File.mkdir!(root)
    workspace = Path.join(root, "w")
    File.mkdir!(workspace)
    on_exit(fn -> File.rm_rf(root) end)
    socket = Path.join([root, "s", "daemon", "d.sock"])

    options = [
      state_root: Path.join(root, "s"),
      socket_path: socket,
      workspace: workspace,
      policy: Policy,
      credential: "maximum-population-placeholder"
    ]

    {:ok, output} = StringIO.open("")
    test = self()

    daemon =
      Task.async(fn ->
        Sentinel.run(options, output: output, install_signals: false, notify: test)
      end)

    assert_receive {:loopex_daemon_sentinel, sentinel, owner_ref, service}, 5_000
    on_exit(fn -> Process.exit(service, :kill) end)
    await_ready(output, 3_000)
    collaboration = :sys.get_state(service).pids.collaboration
    tracer = spawn_link(fn -> step_trace_loop([]) end)
    trace_steps(collaboration, tracer)
    on_exit(fn -> untrace_steps() end)

    creator = client(socket)

    sessions =
      for index <- 1..@sessions do
        :ok =
          send_frame(creator, %{
            "method" => "session.create",
            "request_id" => "create-#{index}",
            "command_id" => Wire.encode_identity("steps-#{index}"),
            "session_options" => %{}
          })

        [%{"status" => "accepted", "session_id" => encoded}] = receive_records(creator, 1, 30_000)
        encoded
      end

    :socket.close(creator)

    clients =
      for index <- 0..(@connections - 1) do
        client = client(socket)
        encoded = Enum.at(sessions, rem(index, @sessions))

        :ok =
          send_frame(client, %{
            "method" => "session.attach",
            "request_id" => "attach",
            "session_id" => encoded,
            "after_event_sequence" => "0"
          })

        [%{"type" => "snapshot"}] = receive_records(client, 1, 30_000)
        client
      end

    on_exit(fn -> Enum.each(clients, &:socket.close/1) end)

    # Client i is attached to session rem(i, 8), and a connection may act only
    # on its own session. Holders (clients 0-5) are granted sessions 0-5 first.
    # Burst one adds, in its middle, all 64 clients of each of sessions 6 and
    # 7 acquiring that unheld session at once: exactly one of each 64 is
    # granted and the rest are refused `control_held`.
    session_of = fn index -> rem(index, @sessions) end
    holder = &Enum.at(clients, &1)
    session = &Enum.at(sessions, &1)
    others = clients |> Enum.with_index() |> Enum.drop(@sessions)
    in_sessions = fn range -> Enum.filter(others, fn {_c, i} -> session_of.(i) in range end) end

    all_in = fn range ->
      clients |> Enum.with_index() |> Enum.filter(fn {_c, i} -> session_of.(i) in range end)
    end

    grant = fn index ->
      case reply(holder.(index), "grant") do
        %{"result" => %{"writer_epoch" => epoch}} -> {:ok, epoch}
        other -> {:missing, index, other}
      end
    end

    early =
      for index <- 0..5 do
        send_acquire(holder.(index), session.(index), "grant")
        grant.(index)
      end

    epochs = for {{:ok, epoch}, index} <- Enum.with_index(early), into: %{}, do: {index, epoch}

    burst = fn pairs, tag ->
      Enum.each(pairs, fn {client, index} ->
        send_acquire(client, session.(session_of.(index)), tag)
      end)
    end

    # Burst one: the 252 other clients of sessions 2-5, with the 128
    # contended acquires of sessions 6 and 7 and the releases of sessions 0
    # and 1 in its middle.
    {first_half, second_half} = Enum.split(in_sessions.(2..5), 126)
    contended = all_in.(6..7)
    burst.(first_half, "burst-1")
    burst.(contended, "contended")
    # A session whose grant went missing has nothing to release; that is
    # recorded and judged after the distribution.
    released = Enum.filter(0..1, &Map.has_key?(epochs, &1))
    Enum.each(released, &send_release(holder.(&1), session.(&1), epochs[&1]))
    burst.(second_half, "burst-1")

    burst_one =
      Enum.map(first_half ++ second_half, fn {client, _i} -> reply(client, "burst-1") end)

    contention =
      Enum.map(contended, fn {client, i} -> {session_of.(i), reply(client, "contended")} end)

    releases = Enum.map(released, &reply(holder.(&1), "release"))

    # Burst two: the 252 other clients of sessions 4-7, with the lease owners
    # of sessions 2 and 3 killed in its middle.
    owners = :sys.get_state(collaboration).owners
    {first_half, second_half} = Enum.split(in_sessions.(4..7), 126)
    burst.(first_half, "burst-2")

    Enum.each(2..3, fn index ->
      {:ok, raw} = Wire.identity(session.(index))

      case Map.fetch(owners, raw) do
        {:ok, %{pid: pid}} -> Process.exit(pid, :kill)
        :error -> :no_owner
      end
    end)

    burst.(second_half, "burst-2")

    burst_two =
      Enum.map(first_half ++ second_half, fn {client, _i} -> reply(client, "burst-2") end)

    owner_lost? = &(&1["code"] == "control_owner_lost")
    losses = Enum.map(2..3, &reply_matching(holder.(&1), owner_lost?))

    send(sentinel, {:daemon_signal, owner_ref, :sigterm})
    status = Task.yield(daemon, 60_000) || Task.shutdown(daemon, :brutal_kill)
    untrace_steps()
    send(tracer, {:events, self()})
    assert_receive {:events, events}, 5_000

    # The distribution is judged first.
    durations = step_durations(events)

    for {class, samples} <- Enum.sort(durations) do
      sorted = Enum.sort(samples)
      count = length(sorted)
      p50 = Enum.at(sorted, div(count, 2))
      p99 = Enum.at(sorted, min(count - 1, div(count * 99, 100)))

      IO.puts(
        "maximum-population steps: class=#{class} count=#{count} p50_ms=#{p50} " <>
          "p99_ms=#{p99} max_ms=#{List.last(sorted)} otp=#{System.otp_release()}"
      )
    end

    for class <- [:registry, :relay, :lease_owner, :connection] do
      assert Map.get(durations, class, []) != [], "no #{class} step was sampled"
    end

    for {class, samples} <- durations do
      assert Enum.max(samples) < 5_000, "#{class} step took #{Enum.max(samples)} ms"
    end

    # Then the workload's own replies and the orderly stop.
    assert Enum.all?(early, &match?({:ok, _epoch}, &1)), inspect(early)
    held? = &match?(%{"type" => "error", "code" => "control_held"}, &1)
    granted? = &match?(%{"type" => "result", "result" => %{"writer_epoch" => _}}, &1)
    assert Enum.all?(burst_one, held?)

    for index <- 6..7 do
      replies = for {^index, record} <- contention, do: record
      assert length(replies) == 64
      assert Enum.count(replies, granted?) == 1, inspect(Enum.frequencies(replies))
      assert Enum.count(replies, held?) == 63
    end

    # In burst two a contended session's winner, when it is one of the other
    # clients, renews its own lease.
    {two_held, two_contended} =
      Enum.split_with(Enum.zip(in_sessions.(4..7), burst_two), fn {{_c, i}, _r} ->
        session_of.(i) in 4..5
      end)

    assert Enum.all?(two_held, fn {_client, record} -> held?.(record) end)

    assert Enum.all?(two_contended, fn {_client, record} ->
             held?.(record) or granted?.(record)
           end)

    assert length(releases) == 2 and Enum.all?(releases, &match?(%{"type" => "result"}, &1))
    assert Enum.all?(losses, owner_lost?)
    assert status == {:ok, 0}

    Enum.each(clients, &:socket.close/1)
  end

  # A send to a connection the daemon closed returns its error instead of
  # raising; the missing reply is judged after the step distribution.
  defp send_acquire(client, encoded, request_id) do
    send_frame(client, %{
      "method" => "session.acquire_control",
      "request_id" => request_id,
      "session_id" => encoded
    })
  end

  defp send_release(client, encoded, epoch) do
    send_frame(client, %{
      "method" => "session.release_control",
      "request_id" => "release",
      "session_id" => encoded,
      "writer_epoch" => epoch
    })
  end

  # Technical depth: a reply is the next record carrying the request id; any
  # other record is skipped. A socket that closes or stays silent for 30 s
  # yields `{:missing, reason}` rather than raising, so the step distribution
  # is judged before the workload is.
  defp reply(client, request_id), do: reply_matching(client, &(&1["request_id"] == request_id))

  defp reply_matching(client, predicate) do
    case receive_one(client) do
      {:ok, record} ->
        if predicate.(record), do: record, else: reply_matching(client, predicate)

      {:missing, _reason} = missing ->
        missing
    end
  end

  defp receive_one(client) do
    buffered = Process.get({LoopexDaemon.Test.DaemonSocketFixture, client}, "")

    case :binary.split(buffered, "\n") do
      [_payload, _rest] ->
        {:ok, hd(receive_records(client, 1, 30_000))}

      [_partial] ->
        case :socket.recv(client, 0, 30_000) do
          {:ok, bytes} ->
            Process.put({LoopexDaemon.Test.DaemonSocketFixture, client}, buffered <> bytes)
            receive_one(client)

          {:error, reason} ->
            {:missing, reason}
        end
    end
  end

  @registry_steps [
    :install,
    :install_connection_lost,
    :resolve_granted,
    :resolve_cancelled,
    :resolve_owner_lost,
    :clear,
    :pop_owner
  ]
  @relay_steps [
    :select_result,
    :await_connection_loss,
    :settle_result,
    :settle_result_after_owner_loss,
    :settle_disposition,
    :await_classification
  ]
  @lease_owner_steps [
    :resolve_owner_grant,
    :resolve_owner_cancel,
    :resolve_owner_expiry,
    :resolve_owner_release
  ]

  defp trace_steps(collaboration, tracer) do
    step = [{[:_, :"$1", :"$2"], [], [{:message, {{:"$1", :"$2"}}}]}]
    done = [{[:_, :"$1", :_], [], [{:message, {{:"$1", :done}}}]}]
    late = [{[:_, :"$1", :_, :_], [], [{:message, {{:"$1", :late}}}]}]
    :erlang.trace_pattern({LoopexDaemon.Owner, :enter_step, 3}, step, [:local])
    :erlang.trace_pattern({LoopexDaemon.Owner, :complete_operation, 3}, done, [:local])

    :erlang.trace_pattern(
      {LoopexDaemon.Owner, :complete_owner_loss_notification, 3},
      done,
      [:local]
    )

    :erlang.trace_pattern({LoopexDaemon.Owner, :late_action, 4}, late, [:local])
    :erlang.trace(collaboration, true, [:call, :arity, :monotonic_timestamp, {:tracer, tracer}])
  end

  defp untrace_steps do
    for {function, arity} <- [
          enter_step: 3,
          complete_operation: 3,
          complete_owner_loss_notification: 3,
          late_action: 4
        ],
        do: :erlang.trace_pattern({LoopexDaemon.Owner, function, arity}, false, [:local])
  end

  defp step_trace_loop(events) do
    receive do
      {:trace_ts, _pid, :call, {LoopexDaemon.Owner, _function, _arity}, {ref, step}, at} ->
        step_trace_loop([{ref, step, at} | events])

      {:events, from} ->
        send(from, {:events, Enum.reverse(events)})
        step_trace_loop(events)

      _other ->
        step_trace_loop(events)
    end
  end

  # Technical depth: `:monotonic_timestamp` trace times are nanoseconds. A
  # step's duration runs from its entry to the next transition of the same
  # operation; a step whose next transition is the deadline path counts as
  # at least 5,000 ms.
  defp step_durations(events) do
    events
    |> Enum.group_by(fn {ref, _step, _at} -> ref end)
    |> Enum.flat_map(fn {_ref, transitions} ->
      transitions
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.flat_map(fn [{_ref, step, entered}, {_next_ref, next, left}] ->
        elapsed = :erlang.convert_time_unit(left - entered, :nanosecond, :millisecond)
        elapsed = if next == :late, do: max(elapsed, 5_000), else: elapsed

        case step_class(step) do
          nil -> []
          class -> [{class, elapsed}]
        end
      end)
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  defp step_class(step) when step in @registry_steps, do: :registry
  defp step_class(step) when step in @relay_steps, do: :relay
  defp step_class(step) when step in @lease_owner_steps, do: :lease_owner
  defp step_class(:await_holder_close), do: :connection
  defp step_class(_step), do: nil

  defp client(path) do
    {:ok, socket} = :socket.open(:local, :stream, :default)
    :ok = :socket.connect(socket, %{family: :local, path: path})

    :ok =
      send_frame(socket, %{
        "method" => "initialize",
        "request_id" => "init",
        "generations" => [V2.generation()],
        "capabilities" => []
      })

    [%{"type" => "initialized"}] = receive_records(socket, 1, 30_000)
    socket
  end

  defp await_ready(output, attempts) when attempts > 0 do
    case StringIO.contents(output) do
      {"", line} when byte_size(line) > 0 ->
        :ok

      _empty ->
        Process.sleep(10)
        await_ready(output, attempts - 1)
    end
  end

  defp await_ready(_output, 0), do: flunk("daemon never announced readiness")
end
