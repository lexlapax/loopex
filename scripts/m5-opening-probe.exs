# Concept: the local controls prove committed replay; the missing M5 behavior is
# two client processes reaching one session owned by a third, daemon process.
# Technical depth: all three processes share one isolated code path. The daemon
# must own its Store and runtime. Clients speak only the generation-2 JSONL
# socket protocol. Green requires a committed controller turn and a correlated
# observer snapshot at or beyond that turn's tail. A socket connection alone
# never suffices.
defmodule Loopex.M5Opening.Model do
  def complete(request, options, _progress) do
    send(Keyword.fetch!(options, :observer), :model_called)

    {:ok,
     %{
       text: "done",
       identity: %{provider: "fixture", model: request.model, endpoint: "in-process"},
       usage: %{input_tokens: 1, output_tokens: 1},
       tool_calls: [],
       delta_count: 0,
       streamed: false,
       canonical_request_bytes: request.canonical_request_bytes,
       staged_request_digest: request.staged_request_digest
     }}
  end
end

defmodule Loopex.M5Opening.AllowPolicy do
  def decide(_request), do: {:allow, nil}
end

defmodule Loopex.M5Opening.Executor do
  def execute(observer, job, _grant, _options, _progress) do
    send(observer, {:executor_called, job.tool_call_id})
    {:error, :m5_probe_executor_never_expected}
  end

  def cancel(_, _), do: {:ok, :cleaned}
end

defmodule Loopex.M5Opening do
  alias Loopex.Store

  @log_relative "probe-session.log"

  # Concept: use ADR 0032's default address, not a probe-only convention.
  # Technical depth: the runner allocates a short root, so `daemon.sock` fits
  # Darwin's 104-byte Unix address bound without an override.
  defp socket_path(root), do: Path.join(root, "daemon.sock")

  @tool %{
    "tool_id" => "example.write",
    "tool_version" => "1.0.0",
    "name" => "write",
    "description" => "Write a file beneath the workspace root.",
    "parameter_schema" => %{
      "type" => "object",
      "properties" => %{"path" => %{"type" => "string"}},
      "required" => ["path"]
    },
    "result_shape" => %{"content_type" => "text", "description" => "What was written."},
    "effect_class" => "workspace_write",
    "idempotency_class" => "reconcile_then_retry",
    "budgets" => %{
      "wall_time_ms" => 30_000,
      "output_bytes" => 65_536,
      "artifact_bytes" => 1_048_576
    }
  }

  # ---------------------------------------------------------------------------
  # Existing-runtime positive controls
  # ---------------------------------------------------------------------------

  def run(root) do
    local_root = Path.join(root, "local")
    File.mkdir_p!(local_root)
    path = Path.join(local_root, @log_relative)
    {:ok, store_pid} = Loopex.Store.Local.start_link(path: path)
    {:ok, store} = Store.new(Loopex.Store.Local, store_pid)
    {:ok, runtime} = start_runtime(store, "m5-probe-controller")

    {session, committed} =
      try do
        {:ok, session} = Loopex.create_session(runtime, %{}, command_id: "controller-create")
        {:ok, first} = Loopex.attach(runtime, session, after_event_sequence: 0)

        {:accepted, _} =
          Loopex.command(first, %{
            type: :prompt,
            command_id: "controller-prompt",
            content: "answer in one turn"
          })

        require_witness(
          settle(runtime, session, System.monotonic_time(:millisecond) + 6_000),
          "controller_run_did_not_settle"
        )

        require_witness(drain(:model_called, 0) == 1, "controller_model_turns_unexpected")
        require_witness(drain_executor([]) == [], "controller_unexpected_executor_call")

        committed = drain_events(first, [])
        require_witness(committed != [], "controller_committed_no_public_event")
        tail = List.last(committed)["event_sequence"] || List.last(committed)[:event_sequence]
        require_witness(is_integer(tail) and tail > 0, "controller_tail_sequence_missing")

        # Positive control A: a second attachment inside the same VM replays
        # exactly the committed events from cursor 0.
        {:ok, second} = Loopex.attach(runtime, session, after_event_sequence: 0)
        replayed = drain_events(second, [])

        require_witness(
          Enum.map(replayed, &event_key/1) == Enum.map(committed, &event_key/1),
          "in_process_second_attachment_replay_differs"
        )

        {session, %{tail: tail, count: length(committed)}}
      after
        Loopex.stop(runtime)
      end

    GenServer.stop(store_pid)

    # Positive control B: once the controller has released the path, a fresh
    # process opens the store, resumes the session and replays the same tail.
    after_stop = observe(local_root, session, "after_stop", committed.tail)

    require_witness(
      after_stop.exit == 0 and after_stop.fields["store"] == "opened" and
        integer_field(after_stop.fields, "events") >= committed.count,
      "after_stop_control_failed"
    )

    daemon_root = Path.join(root, "daemon")
    File.mkdir_p!(daemon_root)
    require_witness(byte_size(socket_path(daemon_root)) < 104, "daemon_socket_path_too_long")

    IO.puts(
      "LOOPEX_M5_OBSERVATION controls=2/2 committed_events=#{committed.count} tail=#{committed.tail} after_stop_events=#{after_stop.fields["events"]}"
    )

    daemon = start_daemon(daemon_root)

    result =
      try do
        case wait_for_socket(
               daemon,
               socket_path(daemon_root),
               "",
               System.monotonic_time(:millisecond) + 5_000
             ) do
          :absent ->
            :red

          :ready ->
            {live_session, tail} = drive_controller(socket_path(daemon_root))
            live = observe(daemon_root, live_session, "live", tail)

            require_witness(
              live.exit == 0 and live.fields["socket"] == "connected" and
                live.fields["attach"] == "ok",
              "second_client_did_not_attach"
            )

            :green
        end
      after
        stop_daemon(daemon)
      end

    case result do
      :red ->
        IO.puts(
          "M5 gate RED: no daemon owns an attachable session at the state root's daemon.sock"
        )

        System.halt(1)

      :green ->
        IO.puts(
          "M5 opening GREEN: two client processes attach to one daemon-owned session through daemon.sock at the committed cursor"
        )
    end
  end

  defp observe(root, session, phase, tail) do
    elixir = System.find_executable("elixir") || throw({:witness_error, "elixir_unavailable"})

    code_paths =
      :code.get_path()
      |> Enum.map(&List.to_string/1)
      |> Enum.filter(&String.contains?(&1, "/prod/lib/"))
      |> Enum.flat_map(&["-pa", &1])

    {output, exit} =
      System.cmd(
        elixir,
        code_paths ++ [__ENV__.file, "--observe", root, session, phase, Integer.to_string(tail)],
        stderr_to_stdout: true
      )

    lines = output |> String.split("\n", trim: true)
    Enum.each(lines, &IO.puts("observer[#{phase}]: " <> &1))

    line =
      Enum.find(Enum.reverse(lines), &String.starts_with?(&1, "LOOPEX_M5_OBSERVER ")) ||
        throw({:witness_error, "observer_#{phase}_printed_no_observation"})

    fields =
      line
      |> String.split(" ")
      |> tl()
      |> Enum.map(&String.split(&1, "=", parts: 2))
      |> Enum.filter(&(length(&1) == 2))
      |> Map.new(fn [key, value] -> {key, value} end)

    %{exit: exit, fields: fields}
  end

  # ---------------------------------------------------------------------------
  # Observer (a separate OS process)
  # ---------------------------------------------------------------------------

  def observe_live(root, session, tail) do
    {socket, attach} =
      case :gen_tcp.connect({:local, socket_path(root)}, 0, socket_options(), 1_000) do
        {:ok, socket} ->
          {"connected", attach_over_socket(socket, session, tail)}

        {:error, reason} ->
          {sanitize(to_string(reason)), "none"}
      end

    IO.puts("LOOPEX_M5_OBSERVER phase=live socket=#{socket} attach=#{attach}")

    System.halt(if(socket == "connected" and attach == "ok", do: 0, else: 2))
  end

  def observe_after_stop(root, session, tail) do
    path = Path.join(root, @log_relative)
    Process.flag(:trap_exit, true)
    {:ok, store_pid} = Loopex.Store.Local.start_link(path: path)
    {:ok, store} = Store.new(Loopex.Store.Local, store_pid)
    # Concept: the successor carries the creating runtime's placement identity.
    # Technical depth: ADR 0008 lets only the runtime that created a session
    # recover it, so a fresh process resumes under the same `runtime_id`; a
    # daemon that owns session lifetime is the process that carries that
    # identity across client processes, which is exactly what M5 adds.
    {:ok, runtime} = start_runtime(store, "m5-probe-controller")

    events =
      try do
        {:ok, ^session} = Loopex.resume_session(runtime, session, command_id: "observer-resume")
        {:ok, attachment} = Loopex.attach(runtime, session, after_event_sequence: 0)
        replayed = drain_events(attachment, [])
        last = List.last(replayed)
        replayed_tail = (last && (last["event_sequence"] || last[:event_sequence])) || 0
        if replayed_tail < tail, do: throw({:witness_error, "after_stop_replay_short"})
        length(replayed)
      after
        Loopex.stop(runtime)
        GenServer.stop(store_pid)
      end

    IO.puts("LOOPEX_M5_OBSERVER phase=after_stop store=opened events=#{events}")
    System.halt(0)
  end

  # Concept: the observer accepts only a negotiated, correlated attachment.
  # Technical depth: the top-level cursor is a decimal string and must equal
  # the nested snapshot sequence. A stray event or another request's snapshot
  # cannot satisfy the witness.
  defp attach_over_socket(socket, session, tail) do
    initialize!(socket, "m5-observer-init")

    send_frame(socket, %{
      "method" => "session.attach",
      "request_id" => "m5-observer-attach",
      "session_id" => session,
      "after_event_sequence" => "0"
    })

    snapshot = read_correlated!(socket, "m5-observer-attach")

    require_witness(
      snapshot_cursor(snapshot, session) >= tail,
      "observer_snapshot_before_committed_tail"
    )

    "ok"
  after
    :gen_tcp.close(socket)
  end

  defp send_frame(socket, map), do: :ok = :gen_tcp.send(socket, JSON.encode!(map) <> "\n")

  defp socket_options,
    do: [:binary, active: false, packet: :line, packet_size: 2_097_152]

  defp connect!(path) do
    case :gen_tcp.connect({:local, path}, 0, socket_options(), 1_000) do
      {:ok, socket} -> socket
      {:error, reason} -> throw({:witness_error, "daemon_socket_connect_#{reason}"})
    end
  end

  defp initialize!(socket, request_id) do
    schema_path = "apps/loopex_protocol/priv/schema/loopex-experimental-2.json"
    require_witness(File.regular?(schema_path), "generation_2_schema_missing")
    digest = :crypto.hash(:sha256, File.read!(schema_path)) |> Base.encode16(case: :lower)

    send_frame(socket, %{
      "method" => "initialize",
      "request_id" => request_id,
      "generations" => ["loopex.experimental/2"],
      "capabilities" => []
    })

    initialized = read_correlated!(socket, request_id)

    require_witness(
      initialized["type"] == "initialized" and
        initialized["selected_generation"] == "loopex.experimental/2" and
        initialized["exact_schema_sha256"] == digest and is_map(initialized["limits"]),
      "generation_2_initialize_mismatch"
    )
  end

  defp read_correlated!(socket, request_id) do
    read_correlated!(socket, request_id, System.monotonic_time(:millisecond) + 5_000)
  end

  defp read_correlated!(socket, request_id, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)
    require_witness(remaining > 0, "protocol_response_timeout")

    case :gen_tcp.recv(socket, 0, remaining) do
      {:ok, line} ->
        case JSON.decode(line) do
          {:ok, %{"request_id" => ^request_id} = record} ->
            record

          {:ok, %{"type" => "event", "event" => %{"kind" => "session.settled"}}} ->
            Process.put(:m5_saw_settled, true)
            read_correlated!(socket, request_id, deadline)

          {:ok, %{"type" => "error"}} ->
            throw({:witness_error, "uncorrelated_protocol_error"})

          {:ok, %{} = _other} ->
            read_correlated!(socket, request_id, deadline)

          _ ->
            throw({:witness_error, "invalid_protocol_record"})
        end

      {:error, reason} ->
        throw({:witness_error, "protocol_recv_#{reason}"})
    end
  end

  defp snapshot_cursor(record, session) do
    require_witness(
      record["type"] == "snapshot" and record["session_id"] == session and
        is_map(record["snapshot"]) and record["snapshot"]["session_id"] == session and
        Map.has_key?(record, "open_interaction"),
      "correlated_snapshot_shape_invalid"
    )

    cursor = u64!(record["event_cursor"])

    require_witness(
      u64!(record["snapshot"]["event_sequence"]) == cursor,
      "snapshot_cursor_mismatch"
    )

    cursor
  end

  defp u64!(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} when number >= 0 ->
        require_witness(Integer.to_string(number) == value, "invalid_u64")
        number

      _ ->
        throw({:witness_error, "invalid_u64"})
    end
  end

  defp u64!(_), do: throw({:witness_error, "invalid_u64"})

  defp start_daemon(root) do
    elixir = System.find_executable("elixir") || throw({:witness_error, "elixir_unavailable"})

    Port.open({:spawn_executable, elixir}, [
      :binary,
      :exit_status,
      :stderr_to_stdout,
      {:args, code_paths() ++ [__ENV__.file, "--daemon", root]}
    ])
  end

  defp stop_daemon(port) do
    if Port.info(port) do
      try do
        Port.command(port, "stop\n")

        receive do
          {^port, {:exit_status, _}} -> :ok
        after
          2_000 -> Port.close(port)
        end
      catch
        :error, :badarg -> :ok
      end
    end
  end

  defp wait_for_socket(port, path, output, deadline) do
    if socket_ready?(path) do
      :ready
    else
      require_witness(System.monotonic_time(:millisecond) < deadline, "daemon_start_timeout")

      receive do
        {^port, {:data, bytes}} ->
          wait_for_socket(port, path, String.slice(output <> bytes, -1_000..-1), deadline)

        {^port, {:exit_status, 1}} ->
          require_witness(
            String.contains?(output, "LOOPEX_M5_DAEMON module_absent"),
            "daemon_start_refused_or_crashed"
          )

          :absent

        {^port, {:exit_status, _}} ->
          throw({:witness_error, "daemon_exited_before_socket"})
      after
        25 -> wait_for_socket(port, path, output, deadline)
      end
    end
  end

  defp socket_ready?(path) do
    if File.exists?(path) do
      case :gen_tcp.connect({:local, path}, 0, socket_options(), 100) do
        {:ok, socket} ->
          :gen_tcp.close(socket)
          true

        _ ->
          false
      end
    else
      false
    end
  end

  def run_daemon(root) do
    # This exact, small test-start contract belongs to the M5 daemon. It must
    # open its own Store and runtime, then listen at ADR 0032's default path.
    if not Code.ensure_loaded?(Loopex.Daemon) do
      IO.puts("LOOPEX_M5_DAEMON module_absent")
      System.halt(1)
    end

    case Loopex.Daemon.start_link(
           state_root: root,
           runtime_options: runtime_options("m5-probe-daemon")
         ) do
      {:ok, _daemon} ->
        IO.puts("LOOPEX_M5_DAEMON listening")
        IO.gets("")
        System.halt(0)

      {:error, reason} ->
        IO.puts("LOOPEX_M5_DAEMON start_refused=#{sanitize(inspect(reason))}")
        System.halt(1)
    end
  end

  defp drive_controller(path) do
    socket = connect!(path)

    try do
      initialize!(socket, "m5-controller-init")

      send_frame(socket, %{
        "method" => "session.create",
        "request_id" => "m5-controller-create",
        "command_id" => wire_id("controller-create"),
        "session_options" => %{}
      })

      created = read_correlated!(socket, "m5-controller-create")

      require_witness(
        created["type"] == "admission" and created["status"] == "accepted" and
          is_binary(created["session_id"]),
        "daemon_session_create_failed"
      )

      session = created["session_id"]

      send_frame(socket, %{
        "method" => "session.attach",
        "request_id" => "m5-controller-attach",
        "session_id" => session,
        "after_event_sequence" => "0"
      })

      attached = read_correlated!(socket, "m5-controller-attach")
      initial_cursor = snapshot_cursor(attached, session)

      send_frame(socket, %{
        "method" => "session.acquire_control",
        "request_id" => "m5-controller-acquire",
        "session_id" => session
      })

      acquired = read_correlated!(socket, "m5-controller-acquire")
      epoch = get_in(acquired, ["result", "writer_epoch"])

      require_witness(
        acquired["type"] == "result" and u64!(epoch) > 0,
        "daemon_control_acquire_failed"
      )

      Process.put(:m5_saw_settled, false)

      send_frame(socket, %{
        "method" => "session.prompt",
        "request_id" => "m5-controller-prompt",
        "command_id" => wire_id("controller-prompt"),
        "content_b64" => wire_id("answer in one turn"),
        "writer_epoch" => epoch
      })

      prompted = read_correlated!(socket, "m5-controller-prompt")

      require_witness(
        prompted["type"] == "admission" and prompted["status"] == "accepted",
        "daemon_prompt_not_admitted"
      )

      tail =
        inspect_until_settled(
          socket,
          session,
          initial_cursor,
          0,
          System.monotonic_time(:millisecond) + 6_000
        )

      {session, tail}
    after
      :gen_tcp.close(socket)
    end
  end

  defp inspect_until_settled(socket, session, initial_cursor, attempt, deadline) do
    require_witness(System.monotonic_time(:millisecond) < deadline, "daemon_run_did_not_settle")
    request_id = "m5-inspect-#{attempt}"

    send_frame(socket, %{
      "method" => "session.inspect",
      "request_id" => request_id,
      "session_id" => session
    })

    record = read_correlated!(socket, request_id)
    status = record["result"]

    if Process.get(:m5_saw_settled) and record["type"] == "result" and is_map(status) and
         status["active_run_id"] == nil and
         status["pending_work_ids"] == [] and u64!(status["event_sequence"]) > initial_cursor do
      u64!(status["event_sequence"])
    else
      Process.sleep(20)
      inspect_until_settled(socket, session, initial_cursor, attempt + 1, deadline)
    end
  end

  defp wire_id(value), do: Base.url_encode64(value, padding: false)

  defp code_paths do
    :code.get_path()
    |> Enum.map(&List.to_string/1)
    |> Enum.filter(&String.contains?(&1, "/prod/lib/"))
    |> Enum.flat_map(&["-pa", &1])
  end

  # ---------------------------------------------------------------------------
  # Shared machinery
  # ---------------------------------------------------------------------------

  defp start_runtime(store, runtime_id) do
    Loopex.start_link([store: store] ++ runtime_options(runtime_id))
  end

  defp runtime_options(runtime_id) do
    [
      runtime_id: runtime_id,
      model: %{
        module: Loopex.M5Opening.Model,
        model: "fixture:v1",
        options: [observer: self()]
      },
      executor: %{
        module: Loopex.M5Opening.Executor,
        reference: self(),
        identity: "probe-executor",
        epoch: 1,
        fencing_token: 1,
        workspace_ref: "workspace-ref",
        workspace_lease: "workspace-lease"
      },
      policy: Loopex.M5Opening.AllowPolicy,
      bounds: %{max_turns: 4, token_budget: 100_000, deadline_ms: 60_000},
      context_token_budget: 100_000,
      tools: [@tool],
      active_tools: ["example.write"]
    ]
  end

  defp settle(runtime, session, deadline) do
    case Loopex.session_status(runtime, session) do
      {:ok, %{active_run_id: nil, pending_work_ids: []}} ->
        true

      _ ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(10)
          settle(runtime, session, deadline)
        else
          false
        end
    end
  end

  defp drain_events(attachment, acc) do
    case Loopex.next_event(attachment) do
      {:ok, event} -> drain_events(attachment, [event | acc])
      {:error, :empty} -> Enum.reverse(acc)
      {:disconnected, _} -> Enum.reverse(acc)
      {:error, _other} -> Enum.reverse(acc)
    end
  end

  defp event_key(event),
    do: {event["event_sequence"] || event[:event_sequence], event["event_id"] || event[:event_id]}

  defp integer_field(fields, key) do
    case Integer.parse(Map.get(fields, key, "")) do
      {value, ""} -> value
      _ -> -1
    end
  end

  defp sanitize(text),
    do: text |> String.replace(~r/[^A-Za-z0-9_.:-]/, "_") |> String.slice(0, 80)

  defp drain(message, count) do
    receive do
      ^message -> drain(message, count + 1)
    after
      0 -> count
    end
  end

  defp drain_executor(calls) do
    receive do
      {:executor_called, id} -> drain_executor(calls ++ [id])
    after
      0 -> calls
    end
  end

  defp require_witness(true, _reason), do: :ok
  defp require_witness(false, reason), do: throw({:witness_error, reason})
end

Process.flag(:trap_exit, true)

try do
  case System.argv() do
    [root] ->
      Loopex.M5Opening.run(root)

    ["--daemon", root] ->
      Loopex.M5Opening.run_daemon(root)

    ["--observe", root, session, "live", tail] ->
      Loopex.M5Opening.observe_live(root, session, String.to_integer(tail))

    ["--observe", root, session, "after_stop", tail] ->
      Loopex.M5Opening.observe_after_stop(root, session, String.to_integer(tail))

    _ ->
      IO.puts(:stderr, "usage: m5-opening-probe.exs <state-root>")
      System.halt(2)
  end
rescue
  error ->
    IO.puts(
      :stderr,
      "M5 opening UNAVAILABLE: " <> String.slice(Exception.message(error), 0, 300)
    )

    System.halt(2)
catch
  {:witness_error, reason} ->
    IO.puts("M5 opening WITNESS ERROR: #{reason}")
    System.halt(2)
end
