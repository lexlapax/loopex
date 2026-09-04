#!/usr/bin/env elixir

defmodule LoopexM4BlackBoxClient do
  @moduledoc false

  @timeout_ms 15_000
  @max_stdout_bytes 262_144
  @protocol "loopex.experimental/1"

  def main([repo, initialize_path, requests_path, workspace, expected_schema, policy_revision]) do
    initialize = read_single_frame!(initialize_path)
    [create, attach, prompt, respond, settled_attach] = read_frames!(requests_path)

    executable = System.find_executable("mix") || fail!("mix is unavailable")
    env_executable = System.find_executable("env") || fail!("env is unavailable")

    child_environment =
      [
        "PATH",
        "HOME",
        "MIX_ENV",
        "MIX_HOME",
        "MIX_BUILD_ROOT",
        "MIX_DEPS_PATH",
        "HEX_HOME",
        "REBAR_CACHE_DIR",
        "LOOPEX_HOME",
        "TMPDIR",
        "LANG",
        "LC_ALL",
        "ERL_CRASH_DUMP",
        "ERL_CRASH_DUMP_SECONDS",
        "HEX_OFFLINE"
      ]
      |> Enum.flat_map(fn name ->
        case System.get_env(name) do
          nil -> []
          value -> ["#{name}=#{value}"]
        end
      end)

    child_args =
      ["-i" | child_environment] ++
        [
          executable,
          "run",
          "--no-compile",
          "--no-deps-check",
          "--no-halt",
          "-r",
          Path.join(repo, "scripts/fixtures/m4/defer-once-policy.exs"),
          "-e",
          "Loopex.AppServer.Stdio.main(policy: LoopexM4GatePolicy, " <>
            "policy_identity: \"m4-gate-defer-once\", " <>
            "policy_revision: #{inspect(policy_revision)}, " <>
            "workspace_root: #{inspect(workspace)})"
        ]

    port =
      Port.open(
        {:spawn_executable, env_executable},
        [
          :binary,
          :exit_status,
          :use_stdio,
          {:cd, repo},
          {:args, child_args}
        ]
      )

    os_pid =
      case Port.info(port, :os_pid) do
        {:os_pid, pid} -> pid
        nil -> nil
      end

    state = %{
      port: port,
      buffer: "",
      bytes: 0,
      launched: true,
      eof: false,
      initialized: false,
      phase: :initializing,
      protocol: "none",
      schema: "none",
      attached: false,
      attach_cursor: nil,
      event_cursor: nil,
      event_ids: %{},
      event_sequences_by_id: %{},
      admission: false,
      order_valid: true,
      progress: 0,
      progress_sequences: %{},
      progress_domains: %{},
      progress_closed: MapSet.new(),
      terminal: false,
      terminal_sequence: nil,
      settled: false,
      settled_sequence: nil,
      run_id: nil,
      interaction: "none",
      response_admission: false,
      tool_authorized: false,
      snapshot: false,
      stdout_over_limit: false,
      protocol_only: true,
      session_id: nil,
      tool_call_id: nil,
      interaction_id: nil,
      create: create,
      attach: attach,
      prompt: prompt,
      respond: respond,
      settled_attach: settled_attach,
      expected_schema: expected_schema,
      sent_create: false,
      sent_prompt: false,
      sent_response: false,
      sent_settled_attach: false
    }

    result =
      try do
        true = Port.command(port, initialize <> "\n")
        deadline = System.monotonic_time(:millisecond) + @timeout_ms
        {:ok, state |> receive_until_done(deadline) |> observation()}
      rescue
        exception -> {:error, Exception.message(exception)}
      catch
        {:m4_client_failure, message} -> {:error, message}
      end

    termination = terminate_child(port, os_pid)

    case {result, termination} do
      {{:ok, report}, :ok} -> IO.puts(report)
      {{:error, message}, :ok} -> fail_now!(message)
      {_, {:error, message}} -> fail_now!(message)
    end
  end

  def main(_args),
    do:
      fail!(
        "expected repo, initialization, request-vector, workspace, schema, and policy-revision arguments"
      )

  defp receive_until_done(
         %{
           snapshot: true,
           terminal: true,
           settled: true,
           interaction: "resolved",
           response_admission: true,
           tool_authorized: true
         } = state,
         _deadline
       ),
       do: state

  defp receive_until_done(%{stdout_over_limit: true} = state, _deadline), do: state

  defp receive_until_done(state, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {port, {:data, data}} when port == state.port ->
        bytes = state.bytes + byte_size(data)

        if bytes > @max_stdout_bytes do
          %{state | bytes: bytes, stdout_over_limit: true, protocol_only: false}
        else
          {lines, buffer} = complete_lines(state.buffer <> data)

          next =
            Enum.reduce(lines, %{state | buffer: buffer, bytes: bytes}, fn line, acc ->
              consume_line(line, acc)
            end)

          receive_until_done(next, deadline)
        end

      {port, {:exit_status, _status}} when port == state.port ->
        %{state | eof: true}
    after
      remaining ->
        state
    end
  end

  defp consume_line(line, state) do
    protocol_line? = String.starts_with?(line, "{") and String.ends_with?(line, "}")
    state = %{state | protocol_only: state.protocol_only and protocol_line?}
    state = reject_early_async(line, state)
    {state, duplicate_or_invalid_event?} = advance_event_cursor(line, state)

    cond do
      duplicate_or_invalid_event? ->
        state

      state.phase == :initializing and match_type?(line, "initialized") and
          request?(line, "m4-init-1") ->
        protocol = capture(line, "protocol") || "none"
        schema = capture(line, "schema_digest") || "none"
        state = %{state | initialized: true, protocol: protocol, schema: schema}

        if protocol == @protocol and schema == state.expected_schema do
          send_frame(state.port, substitute(state.create, state))
          %{state | sent_create: true, phase: :creating}
        else
          state
        end

      state.phase == :creating and
          accepted_admission?(line, "m4-create-1", "m4-create-command-1") ->
        case capture(line, "session_id") do
          nil ->
            state

          session_id ->
            next = %{state | session_id: session_id}
            send_frame(state.port, substitute(next.attach, next))
            %{next | phase: :attaching}
        end

      state.phase == :attaching and response?(line, "m4-attach-1") and
        same_session?(line, state) and authoritative_snapshot?(line, 0) ->
        cursor = capture_integer(line, "event_cursor")
        send_frame(state.port, substitute(state.prompt, state))

        %{
          state
          | attached: true,
            attach_cursor: cursor,
            event_cursor: cursor,
            sent_prompt: true,
            phase: :awaiting_prompt_admission
        }

      state.phase == :awaiting_prompt_admission and
        accepted_admission?(line, "m4-prompt-1", "m4-prompt-command-1") and
          same_session?(line, state) ->
        %{state | admission: true, phase: :running}

      state.admission and is_binary(state.run_id) and valid_progress?(line, state) and
          same_session?(line, state) ->
        accept_progress(line, state)

      state.admission and is_nil(state.run_id) and event_kind?(line, "run.started") and
        same_session?(line, state) and
          capture(line, "command_id") == "m4-prompt-command-1" ->
        case capture(line, "run_id") do
          nil -> %{state | order_valid: false}
          run_id -> %{state | run_id: run_id}
        end

      state.phase == :running and is_binary(state.run_id) and
        event_kind?(line, "interaction.requested") and same_session?(line, state) and
          same_run?(line, state) ->
        case {capture(line, "interaction_id"), capture(line, "tool_call_id")} do
          {interaction_id, tool_call_id}
          when is_binary(interaction_id) and is_binary(tool_call_id) ->
            next = %{
              state
              | interaction: "pending",
                interaction_id: interaction_id,
                tool_call_id: tool_call_id
            }

            send_frame(next.port, substitute(next.respond, next))
            %{next | sent_response: true, phase: :awaiting_interaction_admission}

          _missing_identity ->
            %{state | order_valid: false}
        end

      state.phase == :awaiting_interaction_admission and
        accepted_admission?(line, "m4-interaction-1", "m4-interaction-command-1") and
        same_session?(line, state) and same_interaction?(line, state) ->
        %{state | response_admission: true, phase: :running_after_interaction}

      event_kind?(line, "interaction.resolved") and same_session?(line, state) and
        same_run?(line, state) and same_tool?(line, state) and same_interaction?(line, state) ->
        if state.response_admission do
          %{state | interaction: "resolved"}
        else
          %{state | order_valid: false}
        end

      event_kind?(line, "tool.finished") and same_session?(line, state) and
        same_run?(line, state) and same_tool?(line, state) and
        state.interaction == "resolved" and
          capture(line, "outcome") == "completed" ->
        %{state | tool_authorized: true}

      not state.terminal and event_kind?(line, "run.finished") and same_session?(line, state) and
          same_run?(line, state) ->
        terminal_sequence = capture_integer(line, "event_sequence")

        if state.interaction == "resolved" and state.progress > 0 and
             state.tool_authorized and is_integer(terminal_sequence) and
             terminal_sequence == state.event_cursor do
          %{
            state
            | terminal: true,
              terminal_sequence: terminal_sequence,
              phase: :awaiting_settled
          }
        else
          %{state | order_valid: false}
        end

      state.phase == :awaiting_settled and event_kind?(line, "session.settled") and
          same_session?(line, state) ->
        settled_sequence = capture_integer(line, "event_sequence")

        if is_integer(settled_sequence) and settled_sequence == state.event_cursor and
             settled_sequence > state.terminal_sequence do
          next = %{state | settled: true, settled_sequence: settled_sequence}
          send_frame(next.port, substitute(next.settled_attach, next))
          %{next | sent_settled_attach: true, phase: :reattaching}
        else
          %{state | order_valid: false}
        end

      state.phase == :reattaching and response?(line, "m4-settled-attach-1") and
        same_session?(line, state) and
          authoritative_snapshot?(line, state.settled_sequence) ->
        %{state | snapshot: true, phase: :complete}

      true ->
        state
    end
  end

  defp observation(state) do
    initialize =
      if state.initialized, do: "accepted", else: if(state.eof, do: "eof", else: "none")

    schema = if state.schema == state.expected_schema, do: "exact", else: "none"

    stdout =
      cond do
        state.stdout_over_limit -> "over_limit"
        state.bytes == 0 -> "empty"
        state.protocol_only and state.buffer == "" -> "protocol_only"
        true -> "non_protocol"
      end

    order = if state.order_valid, do: "admission_then_gap_free", else: "violated"

    "LOOPEX_M4_PROBE launch=started initialize=#{initialize} protocol=#{state.protocol} " <>
      "schema=#{schema} attach=#{word(state.attached)} admission=#{word(state.admission)} " <>
      "order=#{order} progress=#{state.progress} " <>
      "response_admission=#{word(state.response_admission)} " <>
      "tool=#{if(state.tool_authorized, do: "completed", else: "none")} " <>
      "terminal=#{if(state.terminal, do: "finished", else: "none")} " <>
      "settled=#{word(state.settled)} " <>
      "interaction=#{state.interaction} snapshot=#{if(state.snapshot, do: "settled", else: "none")} " <>
      "stdout=#{stdout}"
  end

  defp substitute(frame, state) do
    frame
    |> String.replace("${SESSION_ID}", json_escape(state.session_id || ""))
    |> String.replace("${INTERACTION_ID}", json_escape(state.interaction_id || ""))
    |> String.replace("${SETTLED_EVENT_SEQUENCE}", Integer.to_string(state.settled_sequence || 0))
  end

  defp send_frame(port, frame), do: Port.command(port, frame <> "\n")
  defp match_type?(line, type), do: capture(line, "type") == type
  defp request?(line, id), do: capture(line, "request_id") == id

  defp response?(line, id),
    do: match_type?(line, "response") and request?(line, id)

  defp accepted_admission?(line, request_id, command_id) do
    match_type?(line, "admission") and request?(line, request_id) and
      capture(line, "command_id") == command_id and capture(line, "admission") == "accepted"
  end

  defp event_kind?(line, kind),
    do:
      match_type?(line, "event") and capture(line, "kind") == kind and
        not has_key?(line, "request_id")

  defp valid_progress?(line, state) do
    kind = capture(line, "kind")
    domain = capture(line, "stream_domain_id")
    base = capture_integer(line, "base_event_sequence")

    common? =
      match_type?(line, "progress") and not has_key?(line, "request_id") and
        is_binary(capture(line, "turn_id")) and
        is_binary(domain) and Regex.match?(~r/^[0-9a-f]{32}$/, domain) and
        is_integer(base) and is_integer(state.attach_cursor) and
        is_integer(state.event_cursor) and base > state.attach_cursor and
        base <= state.event_cursor

    common? and valid_progress_shape?(kind, line)
  end

  defp valid_progress_shape?(kind, line) when kind in ["text_delta", "reasoning_delta"] do
    is_integer(capture_integer(line, "model_sequence")) and
      is_integer(capture_integer(line, "content_index")) and is_binary(capture(line, "text"))
  end

  defp valid_progress_shape?("tool_call_delta", line) do
    is_integer(capture_integer(line, "model_sequence")) and
      is_integer(capture_integer(line, "call_index")) and
      Enum.all?(["tool_call_id", "name", "arguments_fragment"], &string_or_null?(line, &1)) and
      Enum.any?(["tool_call_id", "name", "arguments_fragment"], &is_binary(capture(line, &1)))
  end

  defp valid_progress_shape?("tool_progress", line) do
    is_binary(capture(line, "tool_call_id")) and
      is_integer(capture_integer(line, "progress_sequence")) and
      capture(line, "stream") in ["stdout", "stderr", "progress"] and
      is_integer(capture_integer(line, "byte_offset")) and is_binary(capture(line, "chunk"))
  end

  defp valid_progress_shape?("model_stream_closed", line) do
    capture(line, "disposition") in ["complete", "abandoned"] and
      is_integer(capture_integer(line, "delta_count"))
  end

  defp valid_progress_shape?("tool_stream_closed", line) do
    is_binary(capture(line, "tool_call_id")) and
      capture(line, "disposition") in ["complete", "abandoned"] and
      is_integer(capture_integer(line, "progress_count"))
  end

  defp valid_progress_shape?(_kind, _line), do: false

  defp authoritative_snapshot?(line, expected_cursor) do
    cursor = capture_integer(line, "event_cursor")
    sequence = capture_integer(line, "event_sequence")

    cursor == expected_cursor and sequence == expected_cursor and
      null?(line, "active_run_id")
  end

  defp accept_progress(line, state) do
    kind = capture(line, "kind")
    domain = capture(line, "stream_domain_id")
    base = capture_integer(line, "base_event_sequence")
    turn_id = capture(line, "turn_id")
    family = if kind in ["tool_progress", "tool_stream_closed"], do: :tool, else: :model
    tool_call_id = if family == :tool, do: capture(line, "tool_call_id"), else: nil

    case bind_progress_domain(state, domain, base, turn_id, family, tool_call_id) do
      {:ok, state} ->
        case kind do
          "model_stream_closed" ->
            accept_progress_closure(line, state, domain, "model_sequence", "delta_count")

          "tool_stream_closed" ->
            accept_progress_closure(line, state, domain, "progress_sequence", "progress_count")

          _ ->
            sequence_key =
              if kind == "tool_progress", do: "progress_sequence", else: "model_sequence"

            sequence = capture_integer(line, sequence_key)
            domain_key = {domain, sequence_key}
            expected = Map.get(state.progress_sequences, domain_key, -1) + 1

            if sequence == expected do
              %{
                state
                | progress: state.progress + 1,
                  progress_sequences: Map.put(state.progress_sequences, domain_key, sequence)
              }
            else
              %{state | order_valid: false}
            end
        end

      :error ->
        %{state | order_valid: false}
    end
  end

  defp bind_progress_domain(state, domain, base, turn_id, family, tool_call_id) do
    metadata = {base, turn_id, family, tool_call_id}

    cond do
      MapSet.member?(state.progress_closed, domain) ->
        :error

      Map.get(state.progress_domains, domain, metadata) == metadata ->
        {:ok, %{state | progress_domains: Map.put(state.progress_domains, domain, metadata)}}

      true ->
        :error
    end
  end

  defp accept_progress_closure(line, state, domain, sequence_key, count_key) do
    expected_count = Map.get(state.progress_sequences, {domain, sequence_key}, -1) + 1

    if capture_integer(line, count_key) == expected_count do
      %{state | progress_closed: MapSet.put(state.progress_closed, domain)}
    else
      %{state | order_valid: false}
    end
  end

  defp advance_event_cursor(line, state) do
    if match_type?(line, "event") and same_session?(line, state) do
      sequence = capture_integer(line, "event_sequence")
      event_id = capture(line, "event_id")

      cond do
        has_key?(line, "request_id") or not is_integer(sequence) or not is_binary(event_id) ->
          {%{state | order_valid: false}, true}

        Map.has_key?(state.event_ids, sequence) ->
          if Map.fetch!(state.event_ids, sequence) == {event_id, line},
            do: {state, true},
            else: {%{state | order_valid: false}, true}

        Map.has_key?(state.event_sequences_by_id, event_id) ->
          {%{state | order_valid: false}, true}

        is_integer(state.event_cursor) and sequence == state.event_cursor + 1 ->
          {%{
             state
             | event_cursor: sequence,
               event_ids: Map.put(state.event_ids, sequence, {event_id, line}),
               event_sequences_by_id: Map.put(state.event_sequences_by_id, event_id, sequence)
           }, false}

        true ->
          {%{state | order_valid: false}, true}
      end
    else
      {state, false}
    end
  end

  defp reject_early_async(line, %{admission: false, session_id: session_id} = state)
       when is_binary(session_id) do
    prompt_event? =
      match_type?(line, "event") and capture(line, "command_id") == "m4-prompt-command-1"

    if (match_type?(line, "progress") or prompt_event?) and same_session?(line, state) do
      %{state | order_valid: false}
    else
      state
    end
  end

  defp reject_early_async(_line, state), do: state

  defp same_session?(_line, %{session_id: nil}), do: false
  defp same_session?(line, state), do: capture(line, "session_id") == state.session_id
  defp same_run?(_line, %{run_id: nil}), do: false
  defp same_run?(line, state), do: capture(line, "run_id") == state.run_id
  defp same_tool?(_line, %{tool_call_id: nil}), do: false
  defp same_tool?(line, state), do: capture(line, "tool_call_id") == state.tool_call_id
  defp same_interaction?(_line, %{interaction_id: nil}), do: false
  defp same_interaction?(line, state), do: capture(line, "interaction_id") == state.interaction_id

  defp capture(line, key) do
    case Regex.run(~r/"#{Regex.escape(key)}"\s*:\s*"([^"\\]*)"/, line, capture: :all_but_first) do
      [value] -> value
      _ -> nil
    end
  end

  defp capture_integer(line, key) do
    case Regex.run(~r/"#{Regex.escape(key)}"\s*:\s*([0-9]+)/, line, capture: :all_but_first) do
      [value] -> String.to_integer(value)
      _ -> nil
    end
  end

  defp null?(line, key), do: Regex.match?(~r/"#{Regex.escape(key)}"\s*:\s*null/, line)
  defp has_key?(line, key), do: Regex.match?(~r/"#{Regex.escape(key)}"\s*:/, line)
  defp string_or_null?(line, key), do: is_binary(capture(line, key)) or null?(line, key)

  defp complete_lines(data) do
    parts = String.split(data, "\n")
    {Enum.drop(parts, -1), List.last(parts)}
  end

  defp read_single_frame!(path) do
    case read_frames!(path) do
      [frame] -> frame
      _ -> fail!("initialization vector must contain exactly one frame")
    end
  end

  defp read_frames!(path) do
    path
    |> File.read!()
    |> String.split("\n", trim: true)
  end

  defp json_escape(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
  end

  defp terminate_child(port, os_pid) do
    close_port(port)

    cond do
      not is_integer(os_pid) ->
        :ok

      wait_until_gone(os_pid, 20) ->
        :ok

      signal(os_pid, "-TERM") and wait_until_gone(os_pid, 20) ->
        :ok

      signal(os_pid, "-KILL") and wait_until_gone(os_pid, 20) ->
        :ok

      true ->
        {:error, "direct app-server child did not terminate within its bounded cleanup wait"}
    end
  rescue
    exception ->
      {:error, "direct app-server child cleanup failed: #{Exception.message(exception)}"}
  end

  defp close_port(port) do
    if Port.info(port), do: Port.close(port)
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp wait_until_gone(_os_pid, 0), do: false

  defp wait_until_gone(os_pid, remaining) do
    if process_alive?(os_pid) do
      Process.sleep(25)
      wait_until_gone(os_pid, remaining - 1)
    else
      true
    end
  end

  defp process_alive?(os_pid) do
    case System.cmd(kill_executable(), ["-0", Integer.to_string(os_pid)], stderr_to_stdout: true) do
      {_output, 0} -> true
      {_output, _status} -> false
    end
  end

  defp signal(os_pid, signal) do
    case System.cmd(kill_executable(), [signal, Integer.to_string(os_pid)],
           stderr_to_stdout: true
         ) do
      {_output, 0} -> true
      {_output, _status} -> not process_alive?(os_pid)
    end
  end

  defp kill_executable,
    do: System.find_executable("kill") || "/bin/kill"

  defp word(true), do: "accepted"
  defp word(false), do: "none"

  defp fail!(message) do
    throw({:m4_client_failure, message})
  end

  defp fail_now!(message) do
    IO.puts(:stderr, "m4 black-box client: #{message}")
    System.halt(2)
  end
end

try do
  LoopexM4BlackBoxClient.main(System.argv())
rescue
  exception ->
    IO.puts(:stderr, "m4 black-box client: #{Exception.message(exception)}")
    System.halt(2)
catch
  {:m4_client_failure, message} ->
    IO.puts(:stderr, "m4 black-box client: #{message}")
    System.halt(2)
end
