defmodule LoopexCli.Test.DaemonProxy do
  @moduledoc false

  # Concept: a loss the client cannot tell apart from a real one. The proxy
  # sits on its own Unix socket in front of a daemon and forwards both ways; a
  # scheduled cut forwards one named request, waits until the daemon has
  # answered it, then discards that answer and closes both sides, so the
  # client must recover from a request the daemon applied but whose reply it
  # never saw.
  #
  # Technical depth: requests are read as JSON lines from the client. A cut is
  # `{method, count}`: the next `count` requests with that method are each
  # followed by one lost reply, or `{method, {:nth, ordinals}}` loses the reply
  # to exactly those occurrences, counted from one; each loss is reported to
  # the starting process as `{:proxy_lost, method, ordinal}`.
  # `{{:before, method}, count}` instead closes the
  # connection without forwarding the request, so the daemon never sees it;
  # its count may be `{skip, count}` to let the first `skip` such requests
  # through first. Every other byte is forwarded unchanged. The
  # proxy records each request it saw, in order, for the test to inspect. An
  # optional `rewrite` function sees each chunk the daemon sends before the
  # client does, so a test can present a daemon answer it cannot easily cause.

  # Concept: optional observations identify what actually crossed this proxy.
  # Technical depth: the original owner retains only closed public identity and
  # ordering fields, at most 128 records and 65,536 external-term bytes. One bounded
  # public frame is assembled transiently; no content, arguments or chunk bytes
  # enter retained observations. Decoded public answer text contributes only its
  # byte count and SHA256, charged to those same caps, to compare stream and record.
  # Exhaustion is reported, never treated as loss
  # of a model item or as proof that a closure did not exist.
  @observation_records 128
  @observation_bytes 65_536

  def start(daemon_path, cuts, rewrite \\ & &1, options \\ []) do
    # A random name: `unique_integer` restarts in every VM, so a socket a
    # killed run left behind made a later bind fail with `:eaddrinuse`.
    suffix = Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)
    path = Path.join("/tmp", "ldp-#{suffix}.sock")
    parent = self()

    pid =
      spawn_link(fn ->
        {:ok, listener} =
          :gen_tcp.listen(0, [:binary, {:ifaddr, {:local, path}}, active: false])

        send(parent, {:proxy_listening, self()})

        accept(listener, daemon_path, %{
          cuts: Map.new(cuts),
          seen: [],
          commands: [],
          counts: %{},
          rewrite: rewrite,
          parent: parent,
          observations:
            if(Keyword.get(options, :observe, false),
              do: new_observations(Keyword.get(options, :observation_scope, :all))
            )
        })
      end)

    receive do
      {:proxy_listening, ^pid} -> :ok
    after
      5_000 -> raise "the proxy did not listen"
    end

    ExUnit.Callbacks.on_exit(fn -> File.rm(path) end)
    %{pid: pid, path: path}
  end

  # Each request's method and command identity, in order.
  def commands(proxy) do
    send(proxy.pid, {:commands, self()})

    receive do
      {:proxy_commands, commands} -> commands
    after
      5_000 -> raise "the proxy did not answer"
    end
  end

  def seen(proxy) do
    send(proxy.pid, {:seen, self()})

    receive do
      {:proxy_seen, requests} -> requests
    after
      5_000 -> raise "the proxy did not answer"
    end
  end

  def observations(proxy) do
    send(proxy.pid, {:observations, self()})

    receive do
      {:proxy_observations, observations} -> observations
    after
      5_000 -> raise "the proxy did not answer"
    end
  end

  defp accept(listener, daemon_path, state) do
    receive do
      {:seen, caller} ->
        send(caller, {:proxy_seen, state.seen})
        accept(listener, daemon_path, state)

      {:commands, caller} ->
        send(caller, {:proxy_commands, state.commands})
        accept(listener, daemon_path, state)

      {:observations, caller} ->
        send(caller, {:proxy_observations, observation_snapshot(state)})
        accept(listener, daemon_path, state)
    after
      0 ->
        case :gen_tcp.accept(listener, 50) do
          {:ok, client} ->
            case :gen_tcp.connect({:local, daemon_path}, 0, [:binary, active: true, packet: :raw]) do
              {:ok, daemon} ->
                :ok = :inet.setopts(client, active: true, packet: :line, buffer: 4_194_304)
                state = begin_observed_connection(state)
                accept(listener, daemon_path, relay(client, daemon, state))

              {:error, _no_daemon} ->
                # A daemon being replaced is simply not there yet.
                :gen_tcp.close(client)
                accept(listener, daemon_path, state)
            end

          {:error, :timeout} ->
            accept(listener, daemon_path, state)
        end
    end
  end

  defp relay(client, daemon, state) do
    receive do
      {:tcp, ^client, line} ->
        method = method(line)
        count = Map.get(state.counts, method, 0) + 1

        state = %{
          state
          | seen: state.seen ++ [method],
            commands: state.commands ++ [{method, command_id(line)}],
            counts: Map.put(state.counts, method, count)
        }

        case Map.get(state.cuts, {:before, method}, 0) do
          {skip, remaining} when skip > 0 ->
            state = %{state | cuts: Map.put(state.cuts, {:before, method}, {skip - 1, remaining})}
            forward(client, daemon, line, method, state)

          {0, remaining} when remaining > 0 ->
            close(client, daemon)
            %{state | cuts: Map.put(state.cuts, {:before, method}, {0, remaining - 1})}

          remaining when is_integer(remaining) and remaining > 0 ->
            close(client, daemon)
            %{state | cuts: Map.put(state.cuts, {:before, method}, remaining - 1)}

          _none ->
            forward(client, daemon, line, method, state)
        end

      {:tcp, ^daemon, bytes} ->
        forwarded = state.rewrite.(bytes)
        state = observe_bytes(state, :forwarded, forwarded)
        :ok = :gen_tcp.send(client, forwarded)
        relay(client, daemon, state)

      {:tcp_closed, _socket} ->
        close(client, daemon)
        finish_observed_connection(state)

      {:seen, caller} ->
        send(caller, {:proxy_seen, state.seen})
        relay(client, daemon, state)

      {:commands, caller} ->
        send(caller, {:proxy_commands, state.commands})
        relay(client, daemon, state)

      {:observations, caller} ->
        send(caller, {:proxy_observations, observation_snapshot(state)})
        relay(client, daemon, state)
    end
  end

  defp forward(client, daemon, line, method, state) do
    state = observe_record(state, :request_forwarded, binary_part(line, 0, byte_size(line) - 1))
    :ok = :gen_tcp.send(daemon, line)

    case Map.get(state.cuts, method, 0) do
      {:nth, ordinals} ->
        if Map.fetch!(state.counts, method) in ordinals do
          state = lose_reply(client, daemon, state)
          send(state.parent, {:proxy_lost, method, Map.fetch!(state.counts, method)})
          state
        else
          relay(client, daemon, state)
        end

      remaining when is_integer(remaining) and remaining > 0 ->
        state = lose_reply(client, daemon, state)
        send(state.parent, {:proxy_lost, method, Map.fetch!(state.counts, method)})
        %{state | cuts: Map.put(state.cuts, method, remaining - 1)}

      _none ->
        relay(client, daemon, state)
    end
  end

  # The request reached the daemon; its answer, and whatever else the daemon
  # wrote first, never reaches the client.
  defp lose_reply(client, daemon, state) do
    state =
      receive do
        {:tcp, ^daemon, bytes} -> observe_bytes(state, :discarded_reply, bytes)
      after
        10_000 -> state
      end

    close(client, daemon)
    finish_observed_connection(state)
  end

  defp new_observations(scope) when scope in [:all, :answer] do
    %{
      scope: scope,
      omitted_control_records: 0,
      records: [],
      bytes: 0,
      connection: 0,
      next_order: 0,
      pending: "",
      pending_direction: nil,
      incomplete: false,
      overflow: false
    }
  end

  defp begin_observed_connection(%{observations: nil} = state), do: state

  defp begin_observed_connection(state) do
    state = finish_observed_connection(state)
    update_in(state.observations.connection, &(&1 + 1))
  end

  defp finish_observed_connection(%{observations: nil} = state), do: state

  defp finish_observed_connection(state) do
    observations = state.observations

    %{
      state
      | observations: %{
          observations
          | pending: "",
            pending_direction: nil,
            incomplete: observations.incomplete or observations.pending != ""
        }
    }
  end

  defp observation_snapshot(%{observations: nil}), do: nil

  defp observation_snapshot(%{observations: observations}) do
    %{
      scope: observations.scope,
      omitted_control_records: observations.omitted_control_records,
      records: Enum.reverse(observations.records),
      overflow: observations.overflow,
      incomplete: observations.incomplete or observations.pending != ""
    }
  end

  defp observe_bytes(%{observations: nil} = state, _direction, _bytes), do: state
  defp observe_bytes(%{observations: %{overflow: true}} = state, _direction, _bytes), do: state

  defp observe_bytes(state, direction, bytes) when is_binary(bytes) do
    state =
      if state.observations.pending != "" and
           state.observations.pending_direction != direction,
         do: finish_observed_connection(state),
         else: state

    pending = state.observations.pending

    if byte_size(pending) + byte_size(bytes) <= LoopexProtocol.Frame.output_record_bytes() do
      [tail | lines] = Enum.reverse(:binary.split(pending <> bytes, "\n", [:global]))
      state = put_in(state.observations.pending, :binary.copy(tail))
      state = put_in(state.observations.pending_direction, direction)
      Enum.reduce(Enum.reverse(lines), state, &observe_record(&2, direction, &1))
    else
      observation_overflow(state)
    end
  end

  defp observe_bytes(state, _direction, _bytes), do: observation_overflow(state)

  defp observe_record(%{observations: nil} = state, _direction, _line), do: state
  defp observe_record(%{observations: %{overflow: true}} = state, _direction, _line), do: state

  defp observe_record(state, direction, line) do
    case LoopexProtocol.Frame.decode(line, LoopexProtocol.Frame.output_record_bytes()) do
      {:ok, record} ->
        observations = state.observations

        if observations.scope == :answer and not answer_observation?(record) do
          %{
            state
            | observations: %{
                observations
                | next_order: observations.next_order + 1,
                  omitted_control_records: observations.omitted_control_records + 1
              }
          }
        else
          event = record["event"]
          event_data = if is_map(event), do: event["data"]

          metadata = %{
            order: observations.next_order,
            connection: observations.connection,
            direction: direction,
            envelope:
              observation_fields(
                record,
                ~w(type method request_id session_id command_id status code event_cursor)
              ),
            event: observation_fields(record["event"], ~w(kind event_id event_sequence)),
            event_data: observation_fields(event_data, ~w(run_id turn_id command_id)),
            progress:
              observation_fields(
                record["progress"],
                ~w(kind turn_id stream_domain_id base_event_sequence model_sequence progress_sequence disposition delta_count progress_count)
              ),
            readable: observation_readable(record),
            content: observation_content(record)
          }

          records = [metadata | observations.records]
          bytes = :erlang.external_size(records)

          if length(records) <= @observation_records and bytes <= @observation_bytes do
            %{
              state
              | observations: %{
                  observations
                  | records: records,
                    bytes: bytes,
                    next_order: observations.next_order + 1
                }
            }
          else
            observation_overflow(state)
          end
        end

      _invalid ->
        put_in(state.observations.incomplete, true)
    end
  end

  # Concept: capture every answer-plane record despite lease-recovery polling.
  # Technical depth: the answer scope retains every progress, durable event,
  # snapshot and command admission plus create/prompt/attach requests. Other
  # control records are counted explicitly, and order still advances for them.
  # It is not a complete control-wire trace. Framing failure and the original
  # whole-record count/byte overflow remain failures in either scope.
  defp answer_observation?(record) do
    record["type"] in ~w(progress event snapshot admission) or
      record["method"] in ~w(session.create session.prompt session.attach)
  end

  defp observation_fields(record, fields) when is_map(record) do
    record
    |> Map.take(fields)
    |> Map.new(fn
      {key, value} when is_binary(value) -> {:binary.copy(key), :binary.copy(value)}
      {key, value} when is_integer(value) or is_nil(value) -> {:binary.copy(key), value}
      {key, _value} -> {:binary.copy(key), :non_scalar}
    end)
  end

  defp observation_fields(_record, _fields), do: %{}

  defp observation_readable(%{"type" => "progress"} = record),
    do: match?({:ok, _}, LoopexCli.DaemonClient.progress(record))

  defp observation_readable(%{"type" => "event"} = record),
    do: match?({:ok, _}, LoopexCli.DaemonClient.event(record))

  defp observation_readable(_record), do: :not_applicable

  defp observation_content(
         %{"type" => "progress", "progress" => %{"kind" => "text_delta"}} = record
       ) do
    case LoopexCli.DaemonClient.progress(record) do
      {:ok, %{text: text}} when is_binary(text) -> content_fingerprint(text)
      _invalid -> nil
    end
  end

  defp observation_content(
         %{"type" => "event", "event" => %{"kind" => "assistant.message_appended"}} = record
       ) do
    case LoopexCli.DaemonClient.event(record) do
      {:ok, %{"content" => text}} when is_binary(text) -> content_fingerprint(text)
      _invalid -> nil
    end
  end

  defp observation_content(_record), do: nil

  defp content_fingerprint(text) do
    %{
      bytes: byte_size(text),
      sha256: Base.encode16(:crypto.hash(:sha256, text), case: :lower)
    }
  end

  defp observation_overflow(state) do
    %{
      state
      | observations: %{
          state.observations
          | overflow: true,
            pending: "",
            pending_direction: nil
        }
    }
  end

  defp close(client, daemon) do
    :gen_tcp.close(client)
    :gen_tcp.close(daemon)
  end

  defp command_id(line) do
    with {:ok, %{"command_id" => encoded}} <- JSON.decode(line),
         {:ok, command_id} <- LoopexProtocol.Wire.identity(encoded) do
      command_id
    else
      _none -> nil
    end
  end

  defp method(line) do
    case JSON.decode(line) do
      {:ok, %{"method" => method}} -> method
      _other -> nil
    end
  end
end
