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

    assert_receive {:loopex_daemon_sentinel, sentinel, owner_ref, service}, 5_000
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

    registry = :sys.get_state(service).registry
    retirement_owners = trace_retirement(registry)
    started = System.monotonic_time(:millisecond)
    retirement_cutoff = started + 600_000
    send(sentinel, {:daemon_signal, owner_ref, :sigterm})
    status = Task.await(daemon, 600_000)
    elapsed = System.monotonic_time(:millisecond) - started
    retirement = finish_retirement_trace(registry, retirement_owners, retirement_cutoff)
    untrace_retirement(registry, retirement_owners)
    IO.puts("maximum-population native retirement: #{inspect(retirement)}")
    assert status == 0

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

    registry = :sys.get_state(service).registry
    retirement_owners = trace_retirement(registry)
    retirement_cutoff = System.monotonic_time(:millisecond) + 60_000
    send(sentinel, {:daemon_signal, owner_ref, :sigterm})
    status = Task.yield(daemon, 60_000) || Task.shutdown(daemon, :brutal_kill)
    retirement = finish_retirement_trace(registry, retirement_owners, retirement_cutoff)
    untrace_retirement(registry, retirement_owners)
    IO.puts("maximum-population T15 native retirement: #{inspect(retirement)}")
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

  # Concept: native retirement diagnostics retain decisions without copying owner state.
  # Technical depth: the original Registry and its captured initialized Socket
  # owners are traced. Tokens, incarnations and sinks stay private match-spec
  # inputs. Messages retain closed decisions or the two ProgressSink.close
  # results. Each Socket has one owner-close call, so at most 512 extra returns
  # can precede the unchanged original stop-cutoff delivery fence.
  defp trace_retirement(registry) when is_pid(registry) do
    owners =
      for {token, row} <- :sys.get_state(registry).rows,
          row.initialized and is_pid(row.connection_pid) do
        {row.connection_pid, {token, row.connection_incarnation, row.progress_sink}}
      end

    assert length(owners) <= @connections

    valid_owners? =
      Enum.all?(owners, fn {pid, {token, incarnation, sink}} ->
        is_pid(pid) and is_binary(token) and byte_size(token) == 16 and
          is_binary(incarnation) and byte_size(incarnation) == 16 and
          is_tuple(sink) and tuple_size(sink) == 3
      end)

    assert valid_owners?

    entries = owners
    owners = Map.new(entries)
    assert map_size(owners) == length(entries)

    selected = retirement_get(retirement_get(retirement_get(:"$1", :close_all), :selected), :map)
    sticky = retirement_get(:"$1", :close_all_failed)
    intent = retirement_get(:"$3", :native_retirement)
    selected_guards = [{:is_map, selected}, {:is_map_key, :"$2", selected}, {:is_boolean, sticky}]

    disposition = [
      {[:"$1", :"$2", :"$3"],
       selected_guards ++
         [
           {:is_map, intent},
           {:orelse, {:==, retirement_get(intent, :outcome), :proved},
            {:orelse, {:==, retirement_get(intent, :outcome), :unproved},
             {:==, retirement_get(intent, :outcome), :pending}}},
           {:is_boolean, retirement_get(intent, :guardian_joined)},
           {:is_boolean, retirement_get(intent, :control_joined)}
         ],
       [
         {:message,
          retirement_tuple([
            :selected_disposition,
            retirement_get(intent, :outcome),
            {:==, retirement_get(intent, :result), :ok},
            retirement_get(intent, :guardian_joined),
            retirement_get(intent, :control_joined),
            sticky
          ])}
       ]},
      {[:"$1", :"$2", :"$3"], selected_guards ++ [{:==, intent, nil}],
       [
         {:message,
          retirement_tuple([:selected_disposition, :missing, false, false, false, sticky])}
       ]},
      {[:"$1", :"$2", :_], selected_guards,
       [
         {:message,
          retirement_tuple([:selected_disposition, :invalid, false, false, false, sticky])}
       ]}
    ]

    close = retirement_get(:"$1", :close_all)

    finish =
      for reply <- [:ok, {:error, :connections_lost}] do
        label = if reply == :ok, do: :ok, else: :connections_lost

        {[:"$1", reply], [{:is_boolean, sticky}],
         [
           {:message,
            retirement_tuple([
              :registry_finish,
              label,
              sticky,
              {:==, retirement_get(:"$1", :progress_phase), :closed},
              {:==, retirement_get(close, :phase), :joining},
              {:map_size, retirement_get(close, :dispositions)},
              {:map_size, retirement_get(:"$1", :rows)}
            ])}
         ]}
      end

    on_exit(fn -> untrace_retirement(registry, owners) end)

    assert :erlang.trace_pattern(
             {LoopexDaemon.ConnectionRegistry, :retain_socket_retirement_disposition, 3},
             disposition,
             [:local]
           ) == 1

    assert :erlang.trace_pattern(
             {LoopexDaemon.ConnectionRegistry, :finish_registry_progress_close, 2},
             finish,
             [:local]
           ) == 1

    owner_close =
      for {pid, {_token, _incarnation, sink}} <- owners do
        {[:"$1"], [retirement_actor_guard(pid), {:==, :"$1", {:const, sink}}],
         [{:message, false}, {:return_trace}]}
      end

    assert :erlang.trace_pattern(
             {Loopex.ProgressSink, :close, 1},
             [{:_, [retirement_actor_guard(registry)], [{:message, false}, {:return_trace}]}] ++
               owner_close,
             [:local]
           ) == 1

    assert :erlang.trace(registry, true, [:call, :arity, {:tracer, self()}]) == 1
    Enum.each(Map.keys(owners), &trace_retirement_actor(&1, true))
    owners
  end

  defp untrace_retirement(registry, owners) do
    Enum.each([registry | Map.keys(owners)], &trace_retirement_actor(&1, false))

    for {module, function, arity} <- [
          {LoopexDaemon.ConnectionRegistry, :retain_socket_retirement_disposition, 3},
          {LoopexDaemon.ConnectionRegistry, :finish_registry_progress_close, 2},
          {Loopex.ProgressSink, :close, 1}
        ],
        do: :erlang.trace_pattern({module, function, arity}, false, [:local])
  end

  # Concept: an already-retired original actor remains unobserved.
  # Technical depth: trace enable/disable can race that actor's actual exit.
  # A dead original PID is never replaced or treated as owner-close success.
  defp trace_retirement_actor(pid, enabled) do
    flags = if enabled, do: [:call, :arity, {:tracer, self()}], else: [:call]

    try do
      :erlang.trace(pid, enabled, flags)
    rescue
      ArgumentError -> :ok
    end
  end

  defp retirement_actor_guard(pid), do: {:==, {:self}, {:const, pid}}

  defp retirement_get(map, key), do: {:map_get, key, map}
  defp retirement_tuple(items), do: {List.to_tuple(items)}

  # Concept: the snapshot precedes the original exit-status assertion even on 106.
  # Technical depth: trace_delivered is a delivery fence, not an actor join.
  # Collection spends the original stop allowance; pre/post checks cannot accept
  # a late queued fence. No receive consumes unrelated caller-mailbox evidence.
  defp finish_retirement_trace(registry, owners, cutoff) do
    summary = %{
      dispositions: 0,
      outcomes: %{proved: 0, unproved: 0, pending: 0, missing: 0, invalid: 0},
      result_unproved: 0,
      guardian_unjoined: 0,
      control_unjoined: 0,
      sticky_seen: false,
      owner_close: %{
        captured: map_size(owners),
        ok: 0,
        cleanup_unproved: 0,
        unobserved: map_size(owners),
        overflow: false
      },
      arena_result: :not_observed,
      finish: :not_observed,
      controls: 0,
      overflow: false,
      complete: false
    }

    if System.monotonic_time(:millisecond) < cutoff do
      fence = :erlang.trace_delivered(:all)
      collect_retirement_trace(registry, owners, MapSet.new(), fence, cutoff, summary)
    else
      summary
    end
  end

  defp collect_retirement_trace(registry, owners, observed, fence, cutoff, summary) do
    remaining = max(cutoff - System.monotonic_time(:millisecond), 0)

    if remaining == 0 do
      summary
    else
      receive do
        {:trace, ^registry, :call,
         {LoopexDaemon.ConnectionRegistry, :retain_socket_retirement_disposition, 3},
         {:selected_disposition, outcome, result_ok, guardian_joined, control_joined, sticky}}
        when outcome in [:proved, :unproved, :pending, :missing, :invalid] and
               is_boolean(result_ok) and is_boolean(guardian_joined) and
               is_boolean(control_joined) and is_boolean(sticky) ->
          summary =
            if summary.dispositions < @connections do
              %{
                summary
                | dispositions: summary.dispositions + 1,
                  outcomes: Map.update!(summary.outcomes, outcome, &(&1 + 1)),
                  result_unproved: summary.result_unproved + if(result_ok, do: 0, else: 1),
                  guardian_unjoined:
                    summary.guardian_unjoined + if(guardian_joined, do: 0, else: 1),
                  control_unjoined: summary.control_unjoined + if(control_joined, do: 0, else: 1),
                  sticky_seen: summary.sticky_seen or sticky
              }
            else
              %{summary | overflow: true}
            end

          collect_retirement_trace(registry, owners, observed, fence, cutoff, summary)

        {:trace, ^registry, :return_from, {Loopex.ProgressSink, :close, 1}, result}
        when result == :ok or result == {:error, :cleanup_unproved} ->
          arena_result = if result == :ok, do: :ok, else: :cleanup_unproved
          summary = retirement_control(summary, :arena_result, arena_result)
          collect_retirement_trace(registry, owners, observed, fence, cutoff, summary)

        {:trace, ^registry, :call,
         {LoopexDaemon.ConnectionRegistry, :finish_registry_progress_close, 2},
         {:registry_finish, reply, sticky, arena_closed, joining, dispositions, rows}}
        when reply in [:ok, :connections_lost] and is_boolean(sticky) and
               is_boolean(arena_closed) and is_boolean(joining) and
               is_integer(dispositions) and dispositions in 0..@connections and
               is_integer(rows) and rows in 0..@connections ->
          finish = %{
            input: reply,
            sticky: sticky,
            arena_closed: arena_closed,
            joining: joining,
            dispositions: dispositions,
            rows: rows
          }

          summary = retirement_control(summary, :finish, finish)
          collect_retirement_trace(registry, owners, observed, fence, cutoff, summary)

        {:trace, pid, :return_from, {Loopex.ProgressSink, :close, 1}, result}
        when is_map_key(owners, pid) and
               (result == :ok or result == {:error, :cleanup_unproved}) ->
          owner_close = summary.owner_close

          {owner_close, observed} =
            if MapSet.member?(observed, pid) do
              {%{owner_close | overflow: true}, observed}
            else
              key = if result == :ok, do: :ok, else: :cleanup_unproved

              owner_close =
                owner_close
                |> Map.update!(key, &(&1 + 1))
                |> Map.update!(:unobserved, &(&1 - 1))

              {owner_close, MapSet.put(observed, pid)}
            end

          summary = %{summary | owner_close: owner_close}
          collect_retirement_trace(registry, owners, observed, fence, cutoff, summary)

        {:trace_delivered, :all, ^fence} ->
          %{summary | complete: System.monotonic_time(:millisecond) < cutoff}
      after
        remaining -> summary
      end
    end
  end

  defp retirement_control(summary, key, value) do
    if summary.controls < 2 and Map.fetch!(summary, key) == :not_observed,
      do: %{Map.put(summary, key, value) | controls: summary.controls + 1},
      else: %{summary | overflow: true}
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
    # Concept: T15 keeps only its original collaboration owner's step events.
    # Technical depth: Socket call tracing cannot enable these unrelated local
    # patterns on another actor or expose its operation reference to the caller.
    owner = [retirement_actor_guard(collaboration)]
    step = [{[:_, :"$1", :"$2"], owner, [{:message, {{:"$1", :"$2"}}}]}]
    done = [{[:_, :"$1", :_], owner, [{:message, {{:"$1", :done}}}]}]
    late = [{[:_, :"$1", :_, :_], owner, [{:message, {{:"$1", :late}}}]}]
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
