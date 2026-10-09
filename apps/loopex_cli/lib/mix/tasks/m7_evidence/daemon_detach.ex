defmodule Mix.Tasks.Loopex.M7Evidence.DaemonDetach do
  @moduledoc """
  ## Concept

  The trusted M7 driver for V9.4: a run held on the pinned FIFO runner inside
  an in-VM daemon host survives its driver's connection closing. The driver
  reattaches, an independent observer connection confirms the same run is
  still active, and only then is the runner released.

  ## Technical depth

  `run/3` starts the daemon through its sentinel with the case's pinned
  fixture policy as Core's contextual reference and the operator's model,
  credential and provider launch. The driver connection creates the session,
  acquires control, attaches and prompts. When the runner opens the FIFO, the
  driver closes its connection, then a new connection reattaches at the
  driver's cursor. A second, observer connection attaches from sequence zero
  without control and replays the committed events. The hold is released only
  after both joins name the same session and active run; otherwise the hold
  limit releases it and records `hold_expired`. The daemon then stops and the
  committed facts decide the case.
  """

  alias LoopexCli.DaemonClient
  alias LoopexDaemon.Sentinel
  alias LoopexProtocol.Wire

  @doc false
  def run(staged, context, launch) do
    root = Path.dirname(staged.fixture.workspace)

    socket_root =
      Path.join(System.tmp_dir!(), "m7d-" <> Base.encode16(:crypto.strong_rand_bytes(4)))

    File.mkdir_p!(socket_root)
    socket = Path.join(socket_root, "d.sock")
    {:ok, output} = StringIO.open("")
    holder = hold(staged.held.fifo, Map.get(context, :hold_limit_ms, 90_000))

    try do
      daemon = start(staged, context, launch, root, socket, output)

      try do
        drive(staged, context, socket, holder, daemon)
      after
        stop(daemon)
      end
    rescue
      error -> failed(Exception.message(error), output)
    after
      send(holder.pid, :close)
      File.rm_rf(socket_root)
    end
  end

  defp start(staged, context, launch, root, socket, output) do
    profile = context.profile
    owner = self()

    options =
      [
        state_root: Path.join(root, "state"),
        socket_path: socket,
        workspace: staged.fixture.workspace,
        policy: %{module: LoopexCli.Policy.M7Fixture, context: staged.capture},
        policy_identity: LoopexCli.Policy.M7Fixture.identity(staged.capture),
        model: profile["session"]["model"],
        provider_launch: launch,
        credential: credential(profile)
      ]

    task =
      Task.async(fn ->
        Sentinel.run(options, output: output, install_signals: false, notify: owner)
      end)

    receive do
      {:loopex_daemon_sentinel, sentinel, owner_ref, _owner} ->
        :ok = ready(output, 1_000)
        %{task: task, sentinel: sentinel, owner_ref: owner_ref, output: output}
    after
      10_000 -> raise "daemon did not start"
    end
  end

  # The daemon's credential is the configuration's named provider variable.
  defp credential(profile) do
    Enum.find_value(profile["providers"] || %{}, fn {_name, %{"credential" => credential}} ->
      case credential do
        %{"env" => name} -> System.get_env(name)
        _ -> nil
      end
    end)
  end

  defp ready(output, 0), do: (StringIO.contents(output) |> elem(1) != "" && :ok) || :timeout

  defp ready(output, attempts) do
    case StringIO.contents(output) do
      {_, line} when byte_size(line) > 0 ->
        :ok

      _ ->
        Process.sleep(10)
        ready(output, attempts - 1)
    end
  end

  defp stop(daemon) do
    send(daemon.sentinel, {:daemon_signal, daemon.owner_ref, :sigterm})
    Task.await(daemon.task, 30_000)
  end

  defp drive(staged, context, socket, holder, _daemon) do
    {:ok, driver} = DaemonClient.connect(socket)

    session =
      request!(driver, "session.create", %{
        "command_id" => id(),
        "session_options" => %{"version" => 1}
      })

    session_id = session["session_id"]

    epoch =
      request!(driver, "session.acquire_control", %{"session_id" => session_id})["result"][
        "writer_epoch"
      ]

    request!(driver, "session.attach", %{
      "session_id" => session_id,
      "after_event_sequence" => "0"
    })

    admission =
      request!(driver, "session.prompt", %{
        "command_id" => id(),
        "content_b64" =>
          Wire.encode_bytes(
            Mix.Tasks.Loopex.M7Evidence.CaseRunner.held_prompt(staged.held.runner)
          ),
        "writer_epoch" => epoch
      })

    events = [{:prompted, admission["status"]}]

    case await_held(holder, Map.get(context, :step_deadline_ms, 600_000)) do
      :held ->
        cursor = drain_cursor(driver)
        :ok = DaemonClient.close(driver)
        events = [:driver_closed, :held | events]
        reattach = attach(socket, session_id, cursor)
        observer = attach(socket, session_id, "0")
        observation = observation(session_id, reattach, observer)
        events = [{:observed, observation}, {:reattached, reattach.summary} | events]

        events =
          if match?({:ok, _}, observation) do
            send(holder.pid, :release)
            [:released | events]
          else
            events
          end

        finished = await_finished(observer.client, observation)
        Enum.each([reattach.client, observer.client], &DaemonClient.close/1)

        %{
          exit: if(finished == :ok, do: 0, else: 1),
          conversations: 1,
          session: decode(session_id),
          output: "",
          diagnostics: "",
          closing: "",
          events: Enum.reverse(holder_events(holder, events)),
          interrupted: false,
          transcripts: [
            {"daemon-observation.txt", inspect(observation, pretty: true, limit: :infinity)},
            {"input-1.txt", Enum.map_join(Enum.reverse(events), &(inspect(&1) <> "\n"))}
          ]
        }

      other ->
        DaemonClient.close(driver)
        reason = "hold not reached: #{inspect(other)}; prompt #{inspect(admission)}"
        %{failed(reason, nil) | session: decode(session_id)}
    end
  end

  defp holder_events(holder, events) do
    send(holder.pid, {:expired?, self()})

    receive do
      {:expired, true} -> [:hold_expired | events]
      {:expired, false} -> events
    after
      1_000 -> events
    end
  end

  # Concept: each join comes from its own connection's snapshot and replay.
  defp attach(socket, session_id, after_sequence) do
    {:ok, client} = DaemonClient.connect(socket)

    snapshot =
      request!(client, "session.attach", %{
        "session_id" => session_id,
        "after_event_sequence" => after_sequence
      })

    events = collect(client, 200)

    %{
      client: client,
      snapshot: snapshot,
      events: events,
      summary: %{
        "active_run" => active_run(snapshot),
        "event_kinds" => Enum.map(events, & &1[:kind])
      }
    }
  end

  # The same session's same run is active in both the reattach snapshot and
  # the observer's replay, with its held tool started and not finished.
  defp observation(session_id, reattach, observer) do
    started = Enum.find(observer.events, &(&1[:kind] == "run.started"))
    run = started && started["run_id"]

    tool =
      Enum.find(
        observer.events,
        &(&1[:kind] == "tool.started" and &1["run_id"] == run)
      )

    finished? = Enum.any?(observer.events, &(&1[:kind] == "run.finished"))
    active = active_run(reattach.snapshot)

    cond do
      is_nil(run) ->
        {:error, :run_unobserved}

      finished? ->
        {:error, :run_finished_before_release}

      is_nil(tool) ->
        {:error, :held_operation_unobserved}

      active != run ->
        {:error, {:reattach_snapshot, active}}

      true ->
        {:ok,
         %{
           "session_id" => decode(session_id),
           "run_id" => run,
           "operation_id" => tool["operation_id"],
           "observer_cursor" =>
             observer.events |> Enum.map(& &1[:event_sequence]) |> Enum.max(fn -> nil end)
         }}
    end
  end

  defp active_run(%{"snapshot" => %{"active_run_id" => encoded}}), do: decode(encoded)
  defp active_run(_record), do: nil

  defp await_finished(_client, {:error, _}), do: :error

  defp await_finished(client, _observation) do
    deadline = System.monotonic_time(:millisecond) + 120_000
    wait_finished(client, deadline)
  end

  defp wait_finished(client, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    receive do
      {:loopex_daemon_record, _reader, record} ->
        case DaemonClient.event(record) do
          {:ok, %{kind: "run.finished"}} -> :ok
          _ -> wait_finished(client, deadline)
        end
    after
      max(remaining, 0) -> :timeout
    end
  end

  defp collect(client, quiet_ms) do
    receive do
      {:loopex_daemon_record, _reader, record} ->
        case DaemonClient.event(record) do
          {:ok, event} -> [event | collect(client, quiet_ms)]
          _ -> collect(client, quiet_ms)
        end
    after
      quiet_ms -> []
    end
  end

  defp drain_cursor(driver) do
    driver
    |> collect(200)
    |> Enum.map(& &1[:event_sequence])
    |> Enum.max(fn -> 0 end)
    |> Integer.to_string()
  end

  defp request!(client, method, fields) do
    case DaemonClient.request(client, method, fields) do
      {:ok, %{"type" => "error"} = record, _client} ->
        raise "#{method} refused: #{inspect(record)}"

      {:ok, record, _client} ->
        record

      other ->
        raise "#{method} failed: #{inspect(other)}"
    end
  end

  # Concept: the runner reads one line from the FIFO; the holder opens it for
  # writing and so knows the runner is waiting.
  defp hold(fifo, limit) do
    owner = self()

    pid =
      spawn(fn ->
        {:ok, io} = File.open(fifo, [:write, :raw])
        send(owner, {:m7_daemon_held, self()})
        timer = Process.send_after(self(), :limit, limit)
        holder_loop(io, timer, false)
      end)

    %{pid: pid, fifo: fifo}
  end

  defp holder_loop(io, timer, expired) do
    receive do
      :release ->
        _ = :file.write(io, "released\n")
        holder_loop(io, timer, expired)

      :limit ->
        _ = :file.write(io, "released\n")
        holder_loop(io, timer, true)

      {:expired?, from} ->
        send(from, {:expired, expired})
        holder_loop(io, timer, expired)

      :close ->
        File.close(io)
    end
  end

  defp await_held(holder, deadline) do
    receive do
      {:m7_daemon_held, pid} when pid == holder.pid -> :held
    after
      deadline ->
        # An unopened FIFO blocks its holder; one reader unblocks it.
        spawn(fn -> File.open(holder.fifo, [:read, :raw]) end)
        :timeout
    end
  end

  defp failed(reason, _output) do
    %{
      exit: 1,
      conversations: 1,
      session: nil,
      output: "",
      diagnostics: reason,
      closing: "",
      events: [],
      interrupted: false,
      transcripts: [{"daemon-failure.txt", reason}]
    }
  end

  defp id, do: Wire.encode_identity(Base.encode16(:crypto.strong_rand_bytes(12), case: :lower))

  defp decode(nil), do: nil

  defp decode(encoded) when is_binary(encoded) do
    case Wire.identity(encoded) do
      {:ok, value} -> value
      _ -> encoded
    end
  end
end
