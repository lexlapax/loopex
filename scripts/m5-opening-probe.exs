# Concept: observe whether a second operating-system process can attach to a
# live durable session. Today the local Store admits one writer per path and no
# daemon owns the session, so the observer is refused twice: the Store path is
# held and no Unix-domain socket exists. Two positive controls prove the
# observation is about process boundaries and nothing else: a second attachment
# inside the controller's own VM replays the same committed events, and a fresh
# process attaches to the same session after the controller stops.
# Technical depth: the controller runs a real local Store, runtime and session
# with a deterministic model that answers in one turn without tools. The
# observer is this same script re-executed as a separate `elixir` process on the
# same isolated code path, so the boundary it crosses is an actual OS process
# boundary. Green requires the observer to reach the live session through the
# daemon socket at the state root's canonical path and receive a snapshot naming
# the session at a cursor no older than the controller's committed tail, while
# the direct Store open is still refused; a store that admits the second writer
# is a broken exclusion and therefore a WITNESS ERROR, never green.
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

  # Concept: the daemon socket lives at a short, deterministic path derived
  # from the state root, because a Unix-domain socket path is bounded by the
  # platform (about 104 bytes on Darwin) while an isolated task root is not.
  # Technical depth: both processes derive the same path from the same root, so
  # a future daemon started for this root listens exactly where the observer
  # connects. The directory is the fixed `/tmp`, not the ambient temporary
  # directory, because the gate points that at its own long task root and the
  # bound would then be exceeded before any daemon could listen there.
  defp socket_path(root) do
    digest = :crypto.hash(:sha256, root) |> Base.encode16(case: :lower) |> String.slice(0, 12)
    "/tmp/loopex-m5-#{digest}.sock"
  end

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
  # Controller
  # ---------------------------------------------------------------------------

  def run(root) do
    File.mkdir_p!(root)
    path = Path.join(root, @log_relative)
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

        # The observation: a separate OS process tries to attach while this
        # process still holds the session.
        live = observe(root, session, "live", tail)

        {session, %{tail: tail, live: live, count: length(committed)}}
      after
        Loopex.stop(runtime)
      end

    GenServer.stop(store_pid)

    # Positive control B: once the controller has released the path, a fresh
    # process opens the store, resumes the session and replays the same tail.
    after_stop = observe(root, session, "after_stop", committed.tail)

    require_witness(
      after_stop.exit == 0 and after_stop.fields["store"] == "opened" and
        integer_field(after_stop.fields, "events") >= committed.count,
      "after_stop_control_failed"
    )

    live = committed.live

    IO.puts(
      "LOOPEX_M5_OBSERVATION controls=2/2 committed_events=#{committed.count} tail=#{committed.tail} " <>
        "live_store=#{live.fields["store"]} live_socket=#{live.fields["socket"]} " <>
        "live_attach=#{live.fields["attach"]} live_exit=#{live.exit} " <>
        "after_stop_events=#{after_stop.fields["events"]}"
    )

    cond do
      live.exit == 1 and live.fields["store"] == "store_writer_active" and
          live.fields["socket"] == "enoent" ->
        IO.puts(
          "M5 gate RED: a second process cannot attach to a live session; the local Store refuses the path as store_writer_active and no daemon socket exists"
        )

        System.halt(1)

      live.exit == 0 and live.fields["store"] == "store_writer_active" and
        live.fields["socket"] == "connected" and live.fields["attach"] == "ok" ->
        IO.puts(
          "M5 opening GREEN: a second process attaches to the live session through the daemon socket while the store stays single-writer"
        )

      live.fields["store"] == "opened" ->
        throw({:witness_error, "second_process_opened_the_held_store"})

      true ->
        throw({:witness_error, "live_observation_neither_refused_nor_attached"})
    end
  end

  defp observe(root, session, phase, tail) do
    elixir = System.find_executable("elixir") || throw({:witness_error, "elixir_unavailable"})

    code_paths =
      :code.get_path()
      |> Enum.map(&List.to_string/1)
      |> Enum.filter(&String.contains?(&1, "/lib/loopex"))
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
    path = Path.join(root, @log_relative)
    Process.flag(:trap_exit, true)

    store =
      case Loopex.Store.Local.start_link(path: path) do
        {:error, {:store_writer_active, _path}} -> "store_writer_active"
        {:ok, pid} -> GenServer.stop(pid) && "opened"
        {:error, other} -> "error:" <> sanitize(inspect(other))
      end

    socket_path = socket_path(root)

    {socket, attach} =
      try do
        case :gen_tcp.connect({:local, socket_path}, 0, [:binary, active: false], 1_000) do
          {:ok, socket} ->
            {"connected", attach_over_socket(socket, session, tail)}

          {:error, reason} ->
            {sanitize(to_string(reason)), "none"}
        end
      catch
        :exit, :badarg -> {"path_invalid", "none"}
      end

    IO.puts("LOOPEX_M5_OBSERVER phase=live store=#{store} socket=#{socket} attach=#{attach}")

    cond do
      store == "store_writer_active" and socket == "connected" and attach == "ok" ->
        System.halt(0)

      store == "store_writer_active" and socket == "enoent" ->
        System.halt(1)

      true ->
        System.halt(2)
    end
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

  # Concept: the green route is the ADR 0023 JSONL protocol carried over the
  # daemon socket, so the observer speaks that protocol rather than a private
  # shortcut. Technical depth: initialize, then attach at cursor 0 and accept
  # only a snapshot record naming this session at a cursor no older than the
  # controller's tail; anything else is not an attachment.
  defp attach_over_socket(socket, session, tail) do
    send_frame(socket, %{
      "method" => "initialize",
      "request_id" => "m5-observer-init",
      "generations" => ["loopex.experimental/1"],
      "capabilities" => []
    })

    send_frame(socket, %{
      "method" => "session.attach",
      "request_id" => "m5-observer-attach",
      "session_id" => session,
      "after_event_sequence" => 0
    })

    deadline = System.monotonic_time(:millisecond) + 5_000

    case read_until_attached(socket, session, tail, "", deadline) do
      :ok -> "ok"
      {:error, reason} -> "failed:" <> sanitize(reason)
    end
  after
    :gen_tcp.close(socket)
  end

  defp send_frame(socket, map), do: :ok = :gen_tcp.send(socket, JSON.encode!(map) <> "\n")

  defp read_until_attached(socket, session, tail, buffer, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      {:error, "timeout"}
    else
      case :gen_tcp.recv(socket, 0, remaining) do
        {:ok, bytes} ->
          {records, rest} = split_records(buffer <> bytes)

          attached? =
            Enum.any?(records, fn record ->
              case JSON.decode(record) do
                {:ok, %{"session_id" => ^session, "event_sequence" => sequence}}
                when is_integer(sequence) and sequence >= tail ->
                  true

                _ ->
                  false
              end
            end)

          if attached?, do: :ok, else: read_until_attached(socket, session, tail, rest, deadline)

        {:error, reason} ->
          {:error, to_string(reason)}
      end
    end
  end

  defp split_records(buffer) do
    case String.split(buffer, "\n") do
      [only] -> {[], only}
      parts -> {Enum.drop(parts, -1), List.last(parts)}
    end
  end

  # ---------------------------------------------------------------------------
  # Shared machinery
  # ---------------------------------------------------------------------------

  defp start_runtime(store, runtime_id) do
    Loopex.start_link(
      runtime_id: runtime_id,
      store: store,
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
    )
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
