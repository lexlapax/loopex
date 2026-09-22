defmodule LoopexCli.Live do
  @moduledoc """
  ## Concept

  The live forms drive a session a running daemon owns: `run --daemon` creates
  one and sends its first prompt, `resume --daemon` reaches an existing one,
  `sessions --daemon` lists what the daemon records, and `attach` follows a
  session as an observer or takes control of it once. The daemon owns policy,
  the state root and every other host input, so a live form never accepts a
  flag that would let a client name them.

  ## Technical depth

  Each form has its own closed grammar: every value flag takes one nonempty
  value, no flag repeats, `--` ends options, and a refused form opens no
  socket. Driving follows the plan's exact request sequences — create, acquire,
  attach, then prompt under the granted writer epoch; acquire, attach or the
  verified dormant resume, then inspect — and renders durable events through
  the same renderer an embedded run uses. A controller renews its lease every
  ten seconds; a refused renewal stops further mutations and the command
  continues as an observer. Every exit path that still has a writable socket
  releases a held lease. Command identities are fresh random values; no
  request content is logged.
  """

  require Logger

  alias LoopexCli.{DaemonClient, Render}
  alias LoopexProtocol.Wire

  @renewal_ms 10_000
  @takeover_retry_ms 1_000
  @live :loopex_cli_live

  @forms %{
    "run" => %{daemon: :value, steer: :value, "follow-up": :value},
    "resume" => %{daemon: :value},
    "sessions" => %{daemon: :value, limit: :value, after: :value, status: :boolean},
    "attach" => %{
      daemon: :value,
      observe: :boolean,
      "take-over": :boolean,
      prompt: :value,
      after: :value
    }
  }

  @doc false
  @spec daemon_form?([binary()]) :: boolean()
  def daemon_form?(arguments),
    do:
      arguments
      |> Enum.take_while(&(&1 != "--"))
      |> Enum.any?(&(&1 == "--daemon" or String.starts_with?(&1, "--daemon=")))

  @doc """
  ## Concept

  Runs one live form and returns the ordinary command result.

  ## Technical depth

  Grammar refusals return before any socket is opened.
  """
  @spec command(binary(), [binary()]) :: :ok | {:error, binary()}
  def command(form, arguments) do
    with {:ok, flags, words} <- parse(form, arguments),
         :ok <- validate(form, flags, words) do
      drive(form, flags, words)
    end
  end

  defp parse(form, arguments),
    do: parse(Map.fetch!(@forms, form), arguments, %{}, [], form)

  defp parse(_spec, [], flags, words, _form), do: {:ok, flags, Enum.reverse(words)}

  defp parse(_spec, ["--" | rest], flags, words, _form),
    do: {:ok, flags, Enum.reverse(words, rest)}

  defp parse(spec, ["--" <> encoded | rest], flags, words, form) do
    {name, inline} =
      case String.split(encoded, "=", parts: 2) do
        [name, value] -> {name, {:inline, value}}
        [name] -> {name, :none}
      end

    key = String.to_existing_atom(name)

    case {Map.fetch(spec, key), inline, rest} do
      {:error, _inline, _rest} ->
        {:error, "unrecognised option --#{name} for #{form} --daemon"}

      {{:ok, _kind}, _inline, _rest} when is_map_key(flags, key) ->
        {:error, "--#{name} may be given only once"}

      {{:ok, :boolean}, :none, _rest} ->
        parse(spec, rest, Map.put(flags, key, true), words, form)

      {{:ok, :boolean}, {:inline, _value}, _rest} ->
        {:error, "--#{name} takes no value"}

      {{:ok, :value}, {:inline, value}, _rest} when value != "" ->
        parse(spec, rest, Map.put(flags, key, value), words, form)

      {{:ok, :value}, :none, [value | tail]} when value != "" ->
        if String.starts_with?(value, "--"),
          do: {:error, "--#{name} requires a value"},
          else: parse(spec, tail, Map.put(flags, key, value), words, form)

      {{:ok, :value}, _inline, _rest} ->
        {:error, "--#{name} requires a value"}
    end
  rescue
    ArgumentError -> {:error, "unrecognised option for #{form} --daemon"}
  end

  defp parse(spec, [word | rest], flags, words, form),
    do: parse(spec, rest, flags, [word | words], form)

  defp validate("run", flags, words) do
    cond do
      Map.has_key?(flags, :steer) and Map.has_key?(flags, :"follow-up") ->
        {:error, "--steer and --follow-up cannot be combined"}

      length(words) != 1 ->
        {:error, "run --daemon takes exactly one prompt"}

      true ->
        :ok
    end
  end

  defp validate("resume", _flags, [_session_id]), do: :ok
  defp validate("resume", _flags, _words), do: {:error, "resume --daemon takes one session id"}

  defp validate("sessions", flags, []) do
    cond do
      flags[:status] && (Map.has_key?(flags, :limit) or Map.has_key?(flags, :after)) ->
        {:error, "--status cannot be combined with --limit or --after"}

      Map.has_key?(flags, :limit) and not valid_limit?(flags.limit) ->
        {:error, "--limit must be an integer from 1 to 256"}

      true ->
        :ok
    end
  end

  defp validate("sessions", _flags, _words), do: {:error, "sessions --daemon takes no arguments"}

  defp validate("attach", flags, [_session_id]) do
    cond do
      flags[:observe] && flags[:"take-over"] ->
        {:error, "--observe and --take-over cannot be combined"}

      Map.has_key?(flags, :prompt) and !flags[:"take-over"] ->
        {:error, "--prompt requires --take-over"}

      Map.has_key?(flags, :after) and not match?({:ok, _}, u64(flags.after)) ->
        {:error, "--after must be an unsigned event sequence"}

      true ->
        :ok
    end
  end

  defp validate("attach", _flags, _words), do: {:error, "attach takes one session id"}

  defp valid_limit?(value) do
    match?({limit, ""} when limit in 1..256, Integer.parse(value))
  end

  defp u64(value) do
    case Integer.parse(value) do
      {sequence, ""} when sequence >= 0 and sequence <= 18_446_744_073_709_551_615 ->
        {:ok, sequence}

      _invalid ->
        :error
    end
  end

  defp drive(form, flags, words) do
    case DaemonClient.connect(flags.daemon) do
      {:ok, client} ->
        try do
          drive(form, client, flags, words)
        after
          DaemonClient.close(client)
        end

      {:error, :daemon_unreachable} ->
        {:error, "cannot reach a daemon at that socket"}
    end
  end

  defp drive("sessions", client, %{status: true}, []) do
    case DaemonClient.request(client, "daemon.status", %{}) do
      {:ok, %{"type" => "result", "result" => status}, _client} ->
        for key <- ~w(connections attachments active_sessions activations_used index_entries) do
          IO.puts("#{key} #{Map.fetch!(status, key)}")
        end

        :ok

      other ->
        refusal(other)
    end
  end

  defp drive("sessions", client, flags, []) do
    fields =
      %{"limit" => String.to_integer(Map.get(flags, :limit, "256"))}
      |> maybe_put("after_session_id", flags[:after] && Wire.encode_identity(flags.after))

    case DaemonClient.request(client, "session.list", fields) do
      {:ok, %{"type" => "result", "result" => %{"entries" => entries}}, _client} ->
        entries
        |> Enum.map(&%{session_id: decode_identity(&1["session_id"])})
        |> Render.sessions()

      other ->
        refusal(other)
    end
  end

  defp drive("run", client, flags, [prompt]) do
    with {:ok, %{"status" => "accepted", "session_id" => encoded}, client} <-
           DaemonClient.request(client, "session.create", %{
             "command_id" => Wire.encode_identity(unique_id()),
             "session_options" => %{}
           }),
         session_id = decode_identity(encoded),
         {:ok, epoch, client} <- acquire(client, session_id) do
      IO.puts(:stderr, "loopex: session #{session_id}")
      control = %{session_id: session_id, epoch: epoch}

      controlled(client, control, fn client ->
        with {:ok, client, snapshot} <- attach(client, session_id, nil),
             {:ok, client} <- mutation(client, "session.prompt", prompt, control),
             {:ok, client} <- follow_up(client, flags, control) do
          follow(client, control, snapshot, steer: flags[:steer], end_after_replay: false)
        end
      end)
    else
      other -> refusal(other)
    end
  end

  defp drive("resume", client, _flags, [session_id]) do
    with {:ok, epoch, client} <- acquire(client, session_id) do
      control = %{session_id: session_id, epoch: epoch}

      controlled(client, control, fn client ->
        case attach(client, session_id, nil) do
          {:ok, client, snapshot} ->
            follow(client, control, snapshot, end_after_replay: snapshot.active_run_id == nil)

          {:dormant, client} ->
            with {:ok, client} <- resume(client, control),
                 {:ok, client, snapshot} <- attach(client, session_id, nil) do
              follow(client, control, snapshot, end_after_replay: snapshot.active_run_id == nil)
            end

          other ->
            other
        end
      end)
    else
      other -> refusal(other)
    end
  end

  defp drive("attach", client, flags, [session_id]) do
    after_sequence = flags[:after] && elem(u64(flags.after), 1)

    if flags[:"take-over"] do
      with {:ok, epoch, client} <- take_over(client, session_id) do
        control = %{session_id: session_id, epoch: epoch}

        controlled(client, control, fn client ->
          case attach(client, session_id, after_sequence) do
            {:ok, client, snapshot} ->
              take_over_follow(client, control, snapshot, Map.fetch(flags, :prompt))

            {:dormant, _client} ->
              {:error,
               "session #{session_id} is dormant in this daemon; run `loopex resume --daemon` to activate it"}

            other ->
              other
          end
        end)
      else
        other -> refusal(other)
      end
    else
      case attach(client, session_id, after_sequence) do
        {:ok, client, snapshot} ->
          {result, _control} =
            follow(client, nil, snapshot, end_after_replay: snapshot.active_run_id == nil)

          result

        {:dormant, _client} ->
          {:error, "session #{session_id} is dormant in this daemon"}

        other ->
          refusal(other)
      end
    end
  end

  defp take_over_follow(client, control, snapshot, {:ok, prompt}) do
    with {:ok, client} <- mutation(client, "session.prompt", prompt, control),
         do: follow(client, control, snapshot, end_after_replay: false)
  end

  defp take_over_follow(client, control, snapshot, :error),
    do: follow(client, control, snapshot, end_after_replay: snapshot.active_run_id == nil)

  # Concept: a held lease is released on every exit path with a writable
  # socket; a closed socket lets the lease expire on the daemon's clock.
  #
  # Technical depth: `body` answers `{result, control}` once following began,
  # where `control` is nil after a refused renewal, or any other value for a
  # refusal before the stream, while the granted lease is still held.
  defp controlled(client, control, body) do
    case body.(client) do
      {result, held} when is_map(held) or is_nil(held) ->
        release(client, held)
        result

      {:error, message} = refused when is_binary(message) ->
        release(client, control)
        refused

      refused ->
        release(client, control)
        refusal(refused)
    end
  end

  defp release(_client, nil), do: :ok

  defp release(client, control) do
    Logger.debug("loopex live client releasing control")

    _ =
      DaemonClient.request(
        client,
        "session.release_control",
        %{
          "session_id" => Wire.encode_identity(control.session_id),
          "writer_epoch" => Wire.encode_identity(control.epoch)
        },
        5_000
      )

    :ok
  end

  defp acquire(client, session_id) do
    case DaemonClient.request(client, "session.acquire_control", %{
           "session_id" => Wire.encode_identity(session_id)
         }) do
      {:ok, %{"type" => "result", "result" => %{"writer_epoch" => epoch}}, client} ->
        {:ok, decode_identity(epoch), client}

      other ->
        other
    end
  end

  # Concept: taking over waits for a live holder to release or expire and
  # never forces it off.
  defp take_over(client, session_id) do
    case acquire(client, session_id) do
      {:ok, %{"code" => code}, client} when code in ["control_held", "control_pending"] ->
        Process.sleep(@takeover_retry_ms)
        take_over(client, session_id)

      other ->
        other
    end
  end

  # Concept: an attachment starts where the operator said it left off, or at
  # the session's beginning; one inspect then fixes how far the replay runs and
  # whether a run is still live to follow.
  #
  # Technical depth: the cursor is always sent, because the daemon reads an
  # absent one as the live tail. The inspect doubles as the liveness check a
  # one-way activation set cannot give: `session_unavailable` means the
  # session's coordinator is gone and only a restarted daemon can resume it.
  defp attach(client, session_id, after_sequence) do
    start = after_sequence || 0

    fields = %{
      "session_id" => Wire.encode_identity(session_id),
      "after_event_sequence" => Wire.encode_u64(start)
    }

    with {:ok, %{"type" => "snapshot"}, client} <-
           DaemonClient.request(client, "session.attach", fields),
         {:ok, %{"type" => "result", "result" => status}, client} <-
           DaemonClient.request(client, "session.inspect", %{
             "session_id" => Wire.encode_identity(session_id)
           }),
         {:ok, tail} <- Wire.u64(Map.get(status, "event_sequence")) do
      {:ok, client,
       %{start: start, cursor: max(tail, start), active_run_id: Map.get(status, "active_run_id")}}
    else
      {:ok, %{"code" => "session_dormant"}, client} ->
        {:dormant, client}

      {:ok, %{"code" => "session_unavailable"}, _client} ->
        {:error,
         "session #{session_id} is unavailable in this daemon; restart the daemon, then run `loopex resume --daemon` again"}

      other ->
        other
    end
  end

  defp resume(client, control) do
    case DaemonClient.request(client, "session.resume", %{
           "session_id" => Wire.encode_identity(control.session_id),
           "command_id" => Wire.encode_identity(unique_id()),
           "writer_epoch" => Wire.encode_identity(control.epoch)
         }) do
      {:ok, %{"type" => "admission", "status" => "accepted"}, client} -> {:ok, client}
      other -> other
    end
  end

  defp mutation(client, method, content, control) do
    case DaemonClient.request(client, method, %{
           "command_id" => Wire.encode_identity(unique_id()),
           "content_b64" => Wire.encode_bytes(content),
           "writer_epoch" => Wire.encode_identity(control.epoch)
         }) do
      {:ok, %{"type" => "admission", "status" => "accepted"}, client} -> {:ok, client}
      other -> other
    end
  end

  defp follow_up(client, %{"follow-up": text}, control),
    do: mutation(client, "session.follow_up", text, control)

  defp follow_up(client, _flags, _control), do: {:ok, client}

  # Concept: the durable stream decides when following ends, exactly as for an
  # embedded run. Replayed history up to the attach cursor is shown, never taken
  # as the end; a session with no active run ends once its history is shown.
  # The daemon's stop, a detachment or a lost owner end it early with the
  # reason on standard error.
  #
  # Technical depth: the renderer's callbacks carry no state, so the socket
  # client, the held control, pending request identities and the renewal clock
  # live in this process's dictionary for exactly the duration of the stream.
  # Answers correlated to a renewal or steer are consumed here; every other
  # correlated answer is dropped.
  defp follow(client, control, snapshot, options) do
    steer = Keyword.get(options, :steer)

    live = %{
      client: client,
      control: control,
      pending: %{},
      renewal_due: now_ms() + @renewal_ms,
      end_at: if(Keyword.fetch!(options, :end_after_replay), do: snapshot.cursor),
      last: snapshot.start
    }

    Process.put(@live, live)

    result =
      if live.end_at != nil and live.last >= live.end_at do
        :ok
      else
        try do
          Render.stream(nil,
            next_event: fn _attachment -> next_event() end,
            on_run_started: fn run_id -> maybe_steer(steer, run_id) end,
            replay_through: snapshot.cursor
          )
        catch
          {@live, :replayed} ->
            :ok

          {@live, reason} ->
            Logger.debug("loopex live client stream ended early")
            {:error, reason}
        end
      end

    {result, Process.delete(@live).control}
  end

  defp maybe_steer(nil, _run_id), do: :ok

  defp maybe_steer(text, run_id) do
    live = Process.get(@live)

    if live.control do
      send_tracked(live, :steer, "session.steer", %{
        "command_id" => Wire.encode_identity(unique_id()),
        "run_id" => Wire.encode_identity(run_id),
        "content_b64" => Wire.encode_bytes(text),
        "writer_epoch" => Wire.encode_identity(live.control.epoch)
      })
    end

    :ok
  end

  defp send_tracked(live, purpose, method, fields) do
    case DaemonClient.send_request(live.client, method, fields) do
      {:ok, request_id, client} ->
        Process.put(@live, %{
          live
          | client: client,
            pending: Map.put(live.pending, request_id, purpose)
        })

      {:error, :closed, client} ->
        Process.put(@live, %{live | client: client})
    end
  end

  defp next_event do
    maybe_renew()
    live = Process.get(@live)
    reader = live.client.reader

    if live.end_at != nil and live.last >= live.end_at, do: throw({@live, :replayed})

    receive do
      {:loopex_daemon_record, ^reader, %{"type" => "event"} = record} ->
        case DaemonClient.event(record) do
          {:ok, event} ->
            Process.put(@live, %{live | last: event.event_sequence})
            {:ok, event}

          :error ->
            throw({@live, "the daemon sent an event this client cannot read"})
        end

      {:loopex_daemon_record, ^reader, %{"type" => "daemon.stopping"}} ->
        throw({@live, "the daemon is stopping; reconnect after it restarts"})

      {:loopex_daemon_record, ^reader, %{"code" => "detached", "event_cursor" => cursor}} ->
        throw({@live, "detached by the daemon; reattach with --after #{cursor}"})

      {:loopex_daemon_record, ^reader, %{"code" => "control_owner_lost"} = record}
      when not is_map_key(record, "request_id") ->
        throw({@live, "the session's control owner was lost; take control again"})

      {:loopex_daemon_record, ^reader, %{"request_id" => request_id} = record} ->
        answered(live, request_id, record)
        next_event()

      {:loopex_daemon_record, ^reader, _notice} ->
        next_event()

      {:loopex_daemon_closed, ^reader} ->
        throw({@live, "the daemon connection closed"})
    after
      0 -> {:error, :empty}
    end
  end

  defp answered(live, request_id, record) do
    {purpose, pending} = Map.pop(live.pending, request_id)
    live = %{live | pending: pending}

    case {purpose, record} do
      {:renewal, %{"type" => "result"}} ->
        Process.put(@live, live)

      {:renewal, _refused} ->
        Logger.debug("loopex live client renewal refused")

        if live.control,
          do: IO.puts(:stderr, "loopex: control was lost; continuing as an observer")

        Process.put(@live, %{live | control: nil})

      {:steer, %{"type" => "admission", "status" => "accepted"}} ->
        Process.put(@live, live)

      {:steer, _refused} ->
        IO.puts(:stderr, "loopex: the steer was refused")
        Process.put(@live, live)

      {nil, _unrelated} ->
        Process.put(@live, live)
    end
  end

  # Concept: a controller keeps its lease alive while it follows; a refused
  # renewal stops mutations and the command continues as an observer.
  defp maybe_renew do
    live = Process.get(@live)

    if live.control && now_ms() >= live.renewal_due do
      live = %{live | renewal_due: now_ms() + @renewal_ms}

      send_tracked(live, :renewal, "session.acquire_control", %{
        "session_id" => Wire.encode_identity(live.control.session_id)
      })
    end
  end

  defp refusal({:ok, %{"type" => "error", "code" => code}, _client}),
    do: {:error, "the daemon refused: #{code}"}

  defp refusal(
         {:ok, %{"type" => "admission", "status" => "refused", "reason" => reason}, _client}
       ),
       do: {:error, "the daemon refused the command: #{reason}"}

  defp refusal({:error, :closed, _client}), do: {:error, "the daemon connection closed"}
  defp refusal({:error, :timeout, _client}), do: {:error, "the daemon did not answer"}
  defp refusal({:error, message}) when is_binary(message), do: {:error, message}
  defp refusal(_other), do: {:error, "the daemon answered unexpectedly"}

  defp decode_identity(encoded) do
    {:ok, value} = Wire.identity(encoded)
    value
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp unique_id, do: "live-" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
  defp now_ms, do: System.monotonic_time(:millisecond)
end
