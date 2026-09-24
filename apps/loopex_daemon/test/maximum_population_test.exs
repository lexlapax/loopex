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
    root = Path.join(System.tmp_dir!(), "lmp-#{System.unique_integer([:positive])}")
    workspace = Path.join(root, "w")
    File.mkdir_p!(workspace)
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
  # holder's close — answers within its five-second step, measured as a
  # distribution per step class over a composed grant, refusal, release,
  # retirement and owner-loss run, and the run ends in an orderly stop with
  # status 0.
  #
  # Technical depth: the daemon owner's private `enter_step/3` and its two
  # completion functions are traced with monotonic timestamps; each step's
  # duration runs from its entry to the next transition of the same
  # operation. A step still open when its operation leaves by another path
  # is not sampled. The distribution per class is printed for the closure
  # evidence and every class's maximum must stay below 5,000 ms.
  @tag :long_bound
  @tag timeout: 240_000
  test "T15: every step answers within its instant at the full population" do
    root = Path.join(System.tmp_dir!(), "lms-#{System.unique_integer([:positive])}")
    workspace = Path.join(root, "w")
    File.mkdir_p!(workspace)
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

    acquire = fn client, encoded, request_id ->
      :ok =
        send_frame(client, %{
          "method" => "session.acquire_control",
          "request_id" => request_id,
          "session_id" => encoded
        })
    end

    # One holder per session: eight grants.
    holders =
      for index <- 0..(@sessions - 1) do
        client = Enum.at(clients, index)
        acquire.(client, Enum.at(sessions, index), "grant")
        [%{"request_id" => "grant", "result" => granted}] = receive_records(client, 1, 30_000)
        {client, Enum.at(sessions, index), granted["writer_epoch"]}
      end

    # Every other connection asks too and is refused while the lease is held.
    others = Enum.drop(clients, @sessions)

    others
    |> Enum.with_index(@sessions)
    |> Enum.each(fn {client, index} ->
      acquire.(client, Enum.at(sessions, rem(index, @sessions)), "refused")
    end)

    Enum.each(others, fn client ->
      [%{"request_id" => "refused", "code" => "control_held"}] =
        receive_records(client, 1, 30_000)
    end)

    # Half the holders release; their lease owners then retire.
    {releasing, losing} = Enum.split(holders, div(@sessions, 2))

    Enum.each(releasing, fn {client, encoded, epoch} ->
      :ok =
        send_frame(client, %{
          "method" => "session.release_control",
          "request_id" => "release",
          "session_id" => encoded,
          "writer_epoch" => epoch
        })
    end)

    Enum.each(releasing, fn {client, _encoded, _epoch} ->
      [%{"request_id" => "release", "type" => "result"}] = receive_records(client, 1, 30_000)
    end)

    # The other half lose their lease owners: pop, classification, holder close.
    owners = :sys.get_state(collaboration).owners

    Enum.each(losing, fn {_client, encoded, _epoch} ->
      {:ok, raw} = Wire.identity(encoded)
      Process.exit(Map.fetch!(owners, raw).pid, :kill)
    end)

    Enum.each(losing, fn {client, _encoded, _epoch} ->
      [%{"code" => "control_owner_lost"}] = receive_records(client, 1, 30_000)
    end)

    send(sentinel, {:daemon_signal, owner_ref, :sigterm})
    assert Task.await(daemon, 60_000) == 0
    untrace_steps()
    send(tracer, {:events, self()})
    assert_receive {:events, events}, 5_000

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

    Enum.each(clients, &:socket.close/1)
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
    :erlang.trace_pattern({LoopexDaemon.Owner, :enter_step, 3}, step, [:local])
    :erlang.trace_pattern({LoopexDaemon.Owner, :complete_operation, 3}, done, [:local])

    :erlang.trace_pattern(
      {LoopexDaemon.Owner, :complete_owner_loss_notification, 3},
      done,
      [:local]
    )

    :erlang.trace(collaboration, true, [:call, :arity, :monotonic_timestamp, {:tracer, tracer}])
  end

  defp untrace_steps do
    for function <- [:enter_step, :complete_operation, :complete_owner_loss_notification],
        do: :erlang.trace_pattern({LoopexDaemon.Owner, function, 3}, false, [:local])
  end

  defp step_trace_loop(events) do
    receive do
      {:trace_ts, _pid, :call, {LoopexDaemon.Owner, _function, 3}, {ref, step}, at} ->
        step_trace_loop([{ref, step, at} | events])

      {:events, from} ->
        send(from, {:events, Enum.reverse(events)})
        step_trace_loop(events)

      _other ->
        step_trace_loop(events)
    end
  end

  # Technical depth: a step's duration runs from its entry to the next
  # transition of the same operation, in native monotonic units converted to
  # milliseconds.
  defp step_durations(events) do
    events
    |> Enum.group_by(fn {ref, _step, _at} -> ref end)
    |> Enum.flat_map(fn {_ref, transitions} ->
      transitions
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.flat_map(fn [{_ref, step, entered}, {_next_ref, _next, left}] ->
        case step_class(step) do
          nil -> []
          class -> [{class, System.convert_time_unit(left - entered, :native, :millisecond)}]
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
