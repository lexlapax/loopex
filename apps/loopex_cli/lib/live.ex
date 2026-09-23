defmodule LoopexCli.Live do
  @moduledoc """
  ## Concept

  The live forms drive a session a running daemon owns: `run --daemon` creates
  one and sends its first prompt, `resume --daemon` reaches an existing one,
  `sessions --daemon` lists what the daemon records, and `attach` follows a
  session as an observer or takes control of it once. The daemon owns policy,
  the state root and every other host input, so a live form never accepts a
  flag that would let a client name them. A lost connection is repaired, not
  reported: the command reconnects where it left off and neither repeats nor
  skips anything it already sent or showed.

  ## Technical depth

  Each form has its own closed grammar: every value flag takes one nonempty
  value, no flag repeats, `--` ends options, and a refused form opens no
  socket. Driving follows the plan's request sequences — create, acquire,
  attach, inspect, then the planned mutations under the granted writer epoch;
  acquire, attach or the verified dormant resume, then inspect — and renders
  durable events through the same renderer an embedded run uses.

  A streaming command keeps a non-secret phase record: form, role, session ID,
  the create and unresolved resume command IDs, the emitted event cursor and
  the ordered mutation plan whose steps are `not_sent`, `sent_unconfirmed`,
  `accepted` or `refused`. A step becomes `sent_unconfirmed` before its first
  write. After an unexpected transport loss the command redials every 250 ms
  within 35 seconds of that first loss, never restarting the clock; it
  replays create with the same ID, reacquires for a fresh epoch, reattaches at
  the retained cursor, inspects, and re-presents an unconfirmed step with its
  same command ID and content. Events at or below the cursor are dropped. An
  observer never acquires or resumes. A `detached` record reattaches on the
  same connection. `admission_unknown` for a step ends the command non-zero
  naming the unresolved method and command ID. A controller renews every ten
  seconds; a refused renewal demotes it to an observer, and every exit path
  with a writable socket releases a held lease. No request content is logged.
  """

  require Logger

  alias LoopexCli.{DaemonClient, Render}
  alias LoopexProtocol.Wire

  @renewal_ms 10_000
  @takeover_retry_ms 1_000
  @live :loopex_cli_live
  @stream_reconnect_deadline_ms 35_000
  @live_query_deadline_ms 10_000
  @reconnect_delay_ms 250
  @lease_term_ms 30_000
  @reply_wait_ms 30_000
  @release_wait_ms 5_000

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
  @spec command(binary(), [binary()], keyword()) ::
          :ok | {:error, binary()} | {:detached, non_neg_integer()}
  def command(form, arguments, options \\ []) do
    with {:ok, flags, words} <- parse(form, arguments),
         :ok <- validate(form, flags, words) do
      if Keyword.get(options, :install_signals, false),
        do: :ok = LoopexCli.LiveSignal.install(self())

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

  # Concept: a listing or status is a side-effect-free query, so a lost
  # connection is repaired by asking once more inside one fixed deadline.
  defp drive("sessions", flags, []), do: query(flags, nil)

  defp drive(form, flags, words), do: stream_command(initial(form, flags, words))

  defp query(flags, started) do
    retry? = started != nil
    started = started || now_ms()
    remaining = started + @live_query_deadline_ms - now_ms()

    outcome =
      with true <- remaining > 0,
           {:ok, client} <- DaemonClient.connect(flags.daemon, timeout: remaining) do
        try do
          {method, fields} = query_request(flags)
          wait = max(started + @live_query_deadline_ms - now_ms(), 1)

          case DaemonClient.request(client, method, fields, wait) do
            {:ok, record, _client} -> {:answered, record}
            {:error, :signalled, _client} -> :signalled
            {:error, _reason, _client} -> :lost
          end
        after
          DaemonClient.close(client)
        end
      else
        false -> :lost
        {:error, :signalled} -> :signalled
        {:error, :daemon_unreachable} -> if retry?, do: :lost, else: :unreachable
      end

    case outcome do
      {:answered, record} ->
        render_query(flags, record)

      :unreachable ->
        {:error, "cannot reach a daemon at that socket"}

      :signalled ->
        Logger.debug("loopex live client query cancelled by a signal")
        {:detached, 130}

      :lost when not retry? ->
        Logger.debug("loopex live client repeating a lost query")
        query(flags, started)

      :lost ->
        {:error, "the daemon connection was lost before the query was answered"}
    end
  end

  defp query_request(%{status: true}), do: {"daemon.status", %{}}

  defp query_request(flags) do
    fields =
      %{"limit" => String.to_integer(Map.get(flags, :limit, "256"))}
      |> maybe_put("after_session_id", flags[:after] && Wire.encode_identity(flags.after))

    {"session.list", fields}
  end

  @status_keys ~w(placement_identity daemon_incarnation socket_path connections connection_limit
                  attachments attachment_limit active_sessions activation_limit activations_used
                  index_entries index_limit index_full uptime_ms)

  # Concept: a live query prints one compact JSON object and one LF, keys in
  # a fixed order, so its output is byte-testable and machine-readable; a full
  # index is a warning on standard error, never part of the record.
  #
  # Technical depth: status values keep their wire types. A listing prints the
  # session and placement identities as the text an operator types back to
  # `resume`, `attach` or `--after`, keeping the wire form for bytes that are
  # not UTF-8; the absent continuation is `null` and the absent `index_full`
  # is `false`.
  defp render_query(%{status: true}, %{"type" => "result", "result" => status}) do
    IO.write([ordered(Enum.map(@status_keys, &{&1, Map.get(status, &1)})), "\n"])
    warn_if_full(Map.get(status, "index_full"))
  end

  defp render_query(_flags, %{"type" => "result", "result" => %{"entries" => entries} = page}) do
    sessions =
      Enum.map(entries, fn entry ->
        ordered([
          {"session_id", readable(entry["session_id"])},
          {"placement_identity", readable(entry["placement_identity"])},
          {"residency", entry["residency"]},
          {"controlled", entry["controlled"]}
        ])
      end)

    full = Map.get(page, "index_full", false)

    IO.write([
      ordered([
        {"sessions", {:raw, ["[", Enum.intersperse(sessions, ","), "]"]}},
        {"next_after_session_id", readable(Map.get(page, "next_after_session_id"))},
        {"index_full", full}
      ]),
      "\n"
    ])

    warn_if_full(full)
  end

  defp render_query(_flags, record), do: {:error, refusal_text(record)}

  defp initial("run", flags, [prompt]) do
    secondary =
      cond do
        flags[:"follow-up"] -> [step(:follow_up, "session.follow_up", flags[:"follow-up"])]
        flags[:steer] -> [step(:steer, "session.steer", flags[:steer])]
        true -> []
      end

    %{base(flags, :run, :controller, nil, 0) | create_id: unique_id()}
    |> Map.put(:steps, [step(:prompt, "session.prompt", prompt) | secondary])
  end

  defp initial("resume", flags, [session_id]),
    do: base(flags, :resume, :controller, session_id, 0)

  defp initial("attach", flags, [session_id]) do
    role = if flags[:"take-over"], do: :controller, else: :observer
    cursor = if flags[:after], do: elem(u64(flags.after), 1), else: 0
    steps = if flags[:prompt], do: [step(:prompt, "session.prompt", flags.prompt)], else: []
    %{base(flags, :attach, role, session_id, cursor) | steps: steps}
  end

  defp base(flags, form, role, session_id, cursor) do
    %{
      form: form,
      role: role,
      socket: flags.daemon,
      session_id: session_id,
      create_id: nil,
      resume_id: nil,
      resume_resolved: false,
      steps: [],
      cursor: cursor,
      delivered: cursor,
      tail: cursor,
      busy: false,
      end_at: nil,
      first_loss: nil,
      client: nil,
      epoch: nil,
      lease_deadline: nil,
      pending: %{},
      renewal_due: 0
    }
  end

  defp step(kind, method, content),
    do: %{
      kind: kind,
      method: method,
      command_id: unique_id(),
      content: content,
      run_id: nil,
      status: :not_sent
    }

  defp stream_command(state) do
    case phase(state) do
      {:done, result, state} -> finish(state, result)
      {:fail, message, state} -> finish(state, {:error, message})
      {:lost, state} -> recover(state)
      {:signalled, state} -> detach(state)
    end
  end

  # Concept: a signal detaches this window; admitted work stays the daemon's.
  defp detach(state) do
    Logger.debug("loopex live client detaching on a signal")
    IO.puts(:stderr, "loopex: detached; the session continues in the daemon")
    finish(state, {:detached, 0})
  end

  # Concept: every wait in a live command yields to an operator's signal.
  defp pause(milliseconds) do
    receive do
      {:loopex_live_signal, _signal} -> :signalled
    after
      milliseconds -> :ok
    end
  end

  defp finish(state, result) do
    release(state)
    close(state)
    result
  end

  # Concept: recovery is bounded by one instant, the first loss; nothing that
  # succeeds afterwards buys more time.
  defp recover(state) do
    state = close(state)
    first = state.first_loss || now_ms()

    # A mutation whose answer was lost may have extended the lease up to the
    # loss itself, so only the lease-term cap from the loss is known.
    unconfirmed? = Enum.any?(state.steps, &(&1.status == :sent_unconfirmed))
    state = %{state | first_loss: first}
    state = if unconfirmed?, do: %{state | lease_deadline: nil}, else: state
    remaining = first + @stream_reconnect_deadline_ms - now_ms()

    if remaining <= 0 do
      Logger.debug("loopex live client recovery deadline reached")
      {:error, unresolved("the daemon connection was lost and did not recover in time", state)}
    else
      Logger.debug("loopex live client recovering a lost connection")

      case pause(min(@reconnect_delay_ms, remaining)) do
        :ok -> stream_command(state)
        :signalled -> detach(state)
      end
    end
  end

  defp phase(state) do
    with {:ok, state} <- connect(state),
         {:ok, state} <- ensure_session(state),
         {:ok, state} <- ensure_control(state),
         {:ok, state} <- ensure_attached(state, 0),
         {:ok, state} <- inspect_session(state),
         {:ok, state, sent?} <- present_steps(state) do
      follow(state, sent?)
    end
  end

  # Concept: a re-presented step the daemon had already applied is replayed,
  # and its run may have ended while this command was away; that run is then
  # history to show, not work to wait for.
  #
  # Technical depth: a freshly admitted prompt, follow-up or steer commits its
  # durable record before its admission reply, so the session's tail advances.
  # When a pass re-presented a `sent_unconfirmed` step, the session is
  # inspected again: an unchanged tail on an idle session means nothing new was
  # applied, and following ends once the history through that tail is shown.
  defp present_steps(state) do
    represented? = Enum.any?(state.steps, &(&1.status == :sent_unconfirmed))
    before = state.tail

    with {:ok, state, sent?} <- send_steps(state, 0, false) do
      if represented? and sent? do
        case inspect_session(state) do
          {:ok, %{busy: false, tail: ^before} = state} ->
            Logger.debug("loopex live client found its re-presented work already applied")
            {:ok, state, false}

          {:ok, state} ->
            {:ok, state, sent?}

          other ->
            other
        end
      else
        {:ok, state, sent?}
      end
    end
  end

  defp connect(state) do
    case DaemonClient.connect(state.socket, timeout: bound(state)) do
      {:ok, client} ->
        {:ok, %{state | client: client}}

      {:error, :signalled} ->
        {:signalled, state}

      {:error, :daemon_unreachable} ->
        if state.first_loss,
          do: {:lost, state},
          else: {:fail, "cannot reach a daemon at that socket", state}
    end
  end

  defp request(state, method, fields) do
    case DaemonClient.request(state.client, method, fields, bound(state)) do
      {:ok, record, client} -> {:ok, record, %{state | client: client}}
      {:error, :signalled, client} -> {:signalled, %{state | client: client}}
      {:error, _reason, client} -> {:lost, %{state | client: client}}
    end
  end

  defp bound(%{first_loss: nil}), do: @reply_wait_ms
  defp bound(state), do: max(state.first_loss + @stream_reconnect_deadline_ms - now_ms(), 1)

  # Concept: create is replayed with its one command ID, so a lost answer
  # never creates a second session.
  defp ensure_session(%{session_id: nil, form: :run} = state) do
    case request(state, "session.create", %{
           "command_id" => Wire.encode_identity(state.create_id),
           "session_options" => %{}
         }) do
      {:ok, %{"type" => "admission", "status" => "accepted", "session_id" => encoded}, state} ->
        session_id = decode_identity(encoded)
        IO.puts(:stderr, "loopex: session #{session_id}")
        {:ok, %{state | session_id: session_id}}

      {:ok, record, state} ->
        {:fail, refusal_text(record), state}

      lost ->
        lost
    end
  end

  defp ensure_session(state), do: {:ok, state}

  # Concept: every mutation runs under a fresh epoch; an observer never asks.
  #
  # Technical depth: an initial take-over waits for the holder without bound; a
  # recovering controller may meet its own earlier tenure, so it retries for
  # at most one lease term after the first loss and then concludes someone
  # else holds control.
  defp ensure_control(%{role: :observer} = state), do: {:ok, state}

  defp ensure_control(state) do
    case request(state, "session.acquire_control", %{
           "session_id" => Wire.encode_identity(state.session_id)
         }) do
      {:ok, %{"type" => "result", "result" => %{"writer_epoch" => epoch} = granted}, state} ->
        state = %{state | epoch: decode_identity(epoch), renewal_due: now_ms() + @renewal_ms}
        {:ok, leased(state, granted)}

      {:ok, %{"code" => code} = record, state} when code in ["control_held", "control_pending"] ->
        cond do
          state.first_loss == nil and state.form == :attach ->
            retry_control(state, @takeover_retry_ms)

          state.first_loss == nil ->
            {:fail, refusal_text(record), state}

          now_ms() < recovery_limit(state) ->
            retry_control(
              state,
              min(@reconnect_delay_ms, max(recovery_limit(state) - now_ms(), 0))
            )

          true ->
            {:fail, "another client now controls this session", state}
        end

      {:ok, record, state} ->
        {:fail, refusal_text(record), state}

      lost ->
        lost
    end
  end

  defp retry_control(state, wait) do
    case pause(wait) do
      :ok -> ensure_control(state)
      :signalled -> {:signalled, state}
    end
  end

  # Concept: the client knows when its own last lease ends, so waiting past
  # that instant can only be waiting on someone else.
  defp leased(state, granted) do
    case Wire.u64(Map.get(granted, "expires_in_ms")) do
      {:ok, term} -> %{state | lease_deadline: now_ms() + term}
      :error -> state
    end
  end

  # Concept: an admitted mutation extends the lease by a full term from its
  # admission, which happened before its answer arrived here.
  defp extended(state), do: %{state | lease_deadline: now_ms() + @lease_term_ms}

  defp recovery_limit(%{first_loss: first, lease_deadline: nil}), do: first + @lease_term_ms

  defp recovery_limit(%{first_loss: first, lease_deadline: deadline}),
    do: min(deadline, first + @lease_term_ms)

  defp ensure_attached(state, resumes) do
    case request(state, "session.attach", %{
           "session_id" => Wire.encode_identity(state.session_id),
           "after_event_sequence" => Wire.encode_u64(state.cursor)
         }) do
      {:ok, %{"type" => "snapshot"}, state} ->
        {:ok, %{state | resume_id: nil, resume_resolved: false}}

      {:ok, %{"code" => "session_dormant"}, state} ->
        dormant(state, resumes)

      {:ok, record, state} ->
        {:fail, refusal_text(record), state}

      lost ->
        lost
    end
  end

  # Concept: only `run` and `resume` may activate a dormant session, and one
  # resume command ID is retained until it resolves.
  #
  # Technical depth: an ID that resolved but left the session dormant belonged
  # to a replaced daemon lifetime, so it is retired for one fresh ID; a second
  # dormant answer after a fresh activation is a refusal, never a loop.
  defp dormant(%{form: form, role: :controller} = state, resumes)
       when form in [:run, :resume] and resumes < 2 do
    state =
      if state.resume_id == nil or state.resume_resolved,
        do: %{state | resume_id: unique_id(), resume_resolved: false},
        else: state

    case request(state, "session.resume", %{
           "session_id" => Wire.encode_identity(state.session_id),
           "command_id" => Wire.encode_identity(state.resume_id),
           "writer_epoch" => Wire.encode_identity(state.epoch)
         }) do
      {:ok, %{"type" => "admission", "status" => "accepted"}, state} ->
        ensure_attached(%{state | resume_resolved: true}, resumes + 1)

      {:ok, %{"code" => "admission_unknown"}, state} ->
        {:fail, "session.resume command #{state.resume_id} is unresolved", state}

      {:ok, record, state} ->
        {:fail, refusal_text(record), state}

      lost ->
        lost
    end
  end

  defp dormant(%{form: form} = state, _resumes) when form in [:run, :resume],
    do: {:fail, "session #{state.session_id} stays dormant in this daemon", state}

  defp dormant(state, _resumes) do
    {:fail,
     "session #{state.session_id} is dormant in this daemon; run `loopex resume --daemon` to activate it",
     state}
  end

  # Concept: one inspect fixes where the shown history ends and whether work
  # is still live to follow, and doubles as the coordinator liveness check.
  defp inspect_session(state) do
    case request(state, "session.inspect", %{
           "session_id" => Wire.encode_identity(state.session_id)
         }) do
      {:ok, %{"type" => "result", "result" => status}, state} ->
        case Wire.u64(Map.get(status, "event_sequence")) do
          {:ok, tail} ->
            busy =
              Map.get(status, "active_run_id") != nil or
                Map.get(status, "pending_work_ids", []) not in [nil, []]

            {:ok, %{state | tail: max(tail, state.cursor), busy: busy}}

          :error ->
            {:fail, "the daemon answered unexpectedly", state}
        end

      {:ok, %{"code" => "session_unavailable"}, state} ->
        {:fail,
         "session #{state.session_id} is unavailable in this daemon; restart the daemon, then run `loopex resume --daemon` again",
         state}

      {:ok, record, state} ->
        {:fail, refusal_text(record), state}

      lost ->
        lost
    end
  end

  # Concept: the plan advances one resolved step at a time, and a step whose
  # delivery is unknown is re-presented exactly, never replaced.
  defp send_steps(state, index, sent?) do
    case Enum.at(state.steps, index) do
      nil ->
        {:ok, state, sent?}

      %{status: :accepted} ->
        send_steps(state, index + 1, sent?)

      %{kind: :steer, run_id: nil} ->
        {:ok, state, sent?}

      %{status: status} when status in [:not_sent, :sent_unconfirmed] and state.epoch != nil ->
        case present(state, index) do
          {:accepted, state} -> send_steps(state, index + 1, true)
          other -> other
        end

      _blocked ->
        {:ok, state, sent?}
    end
  end

  defp present(state, index) do
    state = put_status(state, index, :sent_unconfirmed)
    step = Enum.at(state.steps, index)

    case request(state, step.method, step_fields(step, state.epoch)) do
      {:ok, %{"type" => "admission", "status" => "accepted"}, state} ->
        {:accepted, put_status(extended(state), index, :accepted)}

      {:ok, %{"code" => "admission_unknown"}, state} ->
        {:fail, unresolved_step(step), state}

      {:ok, record, state} ->
        {:fail, refusal_text(record), put_status(state, index, :refused)}

      lost ->
        lost
    end
  end

  defp step_fields(step, epoch) do
    %{
      "command_id" => Wire.encode_identity(step.command_id),
      "content_b64" => Wire.encode_bytes(step.content),
      "writer_epoch" => Wire.encode_identity(epoch)
    }
    |> maybe_put("run_id", step.run_id && Wire.encode_identity(step.run_id))
  end

  defp put_status(state, index, status),
    do: %{state | steps: List.update_at(state.steps, index, &%{&1 | status: status})}

  # Concept: the durable stream decides when following ends, exactly as for an
  # embedded run. Replayed history is shown, never taken as the end; when no
  # work is live and nothing was just sent, the command ends once history is
  # shown.
  #
  # Technical depth: the renderer's callbacks carry no state, so the phase
  # record lives in this process's dictionary while the renderer runs. The
  # emitted cursor lags a held assistant message, so a loss while one is held
  # replays it rather than dropping it.
  defp follow(state, sent?) do
    waiting = Enum.any?(state.steps, &(&1.status != :accepted and &1.status != :refused))

    end_at = if not state.busy and not sent? and not waiting, do: state.tail
    state = %{state | end_at: end_at, delivered: state.cursor}

    if end_at != nil and state.cursor >= end_at do
      {:done, :ok, state}
    else
      Process.put(@live, state)

      outcome =
        try do
          {:rendered,
           Render.stream(nil,
             next_event: fn _attachment -> next_event() end,
             on_run_started: &run_started/1,
             replay_through: state.tail
           )}
        catch
          {@live, signal} -> signal
        end

      state = Process.delete(@live)
      conclude(outcome, state)
    end
  end

  defp conclude({:rendered, result}, state), do: {:done, result, state}
  defp conclude(:lost, state), do: {:lost, state}
  defp conclude(:signalled, state), do: {:signalled, state}
  defp conclude(:detached, state), do: reattach(state)
  defp conclude({:fail, message}, state), do: {:fail, message, state}

  defp conclude({:stopping, "operator_stop"}, state) do
    IO.puts(:stderr, "loopex: the daemon stopped; reconnect after it restarts")
    {:done, :ok, %{state | client: nil}}
  end

  defp conclude({:stopping, reason}, state),
    do: {:fail, "the daemon stopped: #{reason}", %{state | client: nil}}

  # Concept: a detached attachment is attachment loss on a live connection:
  # the command waits for its outstanding answers, then attaches again where
  # it left off, keeping its lease and epoch.
  defp reattach(state) do
    Logger.debug("loopex live client reattaching after detachment")
    state = settle_pending(state, now_ms() + @release_wait_ms)

    with {:ok, state} <- ensure_attached(state, 2),
         {:ok, state} <- inspect_session(state),
         {:ok, state, sent?} <- present_steps(state) do
      follow(state, sent?)
    end
  end

  defp settle_pending(%{pending: pending} = state, _deadline) when map_size(pending) == 0,
    do: state

  defp settle_pending(state, deadline) do
    reader = state.client.reader

    receive do
      {:loopex_daemon_record, ^reader, %{"request_id" => id} = record}
      when is_map_key(state.pending, id) ->
        case answered(state, id, record) do
          {:ok, state} -> settle_pending(state, deadline)
          {:fail, _message, state} -> state
        end
    after
      max(deadline - now_ms(), 0) -> state
    end
  end

  defp next_event do
    state = maybe_renew(Process.get(@live))
    reader = state.client.reader

    if state.end_at != nil and state.delivered >= state.end_at do
      :stop
    else
      receive do
        {:loopex_daemon_record, ^reader, %{"type" => "event"} = record} ->
          delivered(state, DaemonClient.event(record))

        # Concept: progress is handed to the renderer's own transient drain;
        # an item this client cannot read is simply not shown.
        {:loopex_daemon_record, ^reader, %{"type" => "progress"} = record} ->
          with {:ok, item} <- DaemonClient.progress(record),
               do: send(self(), {:loopex_progress, item})

          next_event()

        {:loopex_daemon_record, ^reader, %{"type" => "daemon.stopping"} = record} ->
          throw({@live, {:stopping, Map.get(record, "reason")}})

        {:loopex_daemon_record, ^reader, %{"code" => "detached"} = record}
        when not is_map_key(record, "request_id") ->
          throw({@live, :detached})

        {:loopex_daemon_record, ^reader, %{"code" => "control_owner_lost"} = record}
        when not is_map_key(record, "request_id") ->
          throw({@live, :lost})

        {:loopex_daemon_record, ^reader, %{"request_id" => id} = record} ->
          case answered(state, id, record) do
            {:ok, state} ->
              Process.put(@live, state)
              next_event()

            {:fail, message, state} ->
              Process.put(@live, state)
              throw({@live, {:fail, message}})
          end

        {:loopex_daemon_record, ^reader, _notice} ->
          next_event()

        {:loopex_daemon_closed, ^reader} ->
          throw({@live, :lost})

        {:loopex_live_signal, _signal} ->
          throw({@live, :signalled})
      after
        0 -> {:error, :empty}
      end
    end
  end

  defp delivered(state, {:ok, %{event_sequence: sequence}}) when sequence <= state.delivered,
    do: next_event()

  defp delivered(state, {:ok, event}) do
    cursor =
      if event.kind == "assistant.message_appended",
        do: state.delivered,
        else: event.event_sequence

    Process.put(@live, %{state | delivered: event.event_sequence, cursor: cursor})
    {:ok, event}
  end

  defp delivered(_state, :error),
    do: throw({@live, {:fail, "the daemon sent an event this client cannot read"}})

  defp answered(state, request_id, record) do
    {purpose, pending} = Map.pop(state.pending, request_id)
    state = %{state | pending: pending}

    case {purpose, record} do
      {:renewal, %{"type" => "result", "result" => granted}} ->
        {:ok, leased(state, granted)}

      {:renewal, _refused} ->
        Logger.debug("loopex live client renewal refused")

        if state.role == :controller,
          do: IO.puts(:stderr, "loopex: control was lost; continuing as an observer")

        {:ok, %{state | role: :observer, epoch: nil}}

      {{:step, index}, %{"type" => "admission", "status" => "accepted"}} ->
        {:ok, put_status(extended(state), index, :accepted)}

      {{:step, index}, %{"code" => "admission_unknown"}} ->
        {:fail, unresolved_step(Enum.at(state.steps, index)), state}

      {{:step, index}, _refused} ->
        IO.puts(:stderr, "loopex: the steer was refused")
        {:ok, put_status(state, index, :refused)}

      {nil, _unrelated} ->
        {:ok, state}
    end
  end

  # Concept: a steer names the run the session actually started, fixed from
  # the first durable `run.started` it sees and retained for any retry.
  defp run_started(run_id) do
    state = Process.get(@live)
    index = Enum.find_index(state.steps, &(&1.kind == :steer and &1.run_id == nil))

    if index != nil and state.epoch != nil do
      steps = List.update_at(state.steps, index, &%{&1 | run_id: run_id})
      state = put_status(%{state | steps: steps}, index, :sent_unconfirmed)
      step = Enum.at(state.steps, index)

      Process.put(
        @live,
        send_tracked(state, {:step, index}, step.method, step_fields(step, state.epoch))
      )
    end

    :ok
  end

  defp send_tracked(state, purpose, method, fields) do
    case DaemonClient.send_request(state.client, method, fields) do
      {:ok, request_id, client} ->
        %{state | client: client, pending: Map.put(state.pending, request_id, purpose)}

      {:error, :closed, client} ->
        Process.put(@live, %{state | client: client})
        throw({@live, :lost})
    end
  end

  # Concept: a controller keeps its lease alive while it follows.
  defp maybe_renew(%{epoch: epoch} = state) when epoch != nil do
    if now_ms() >= state.renewal_due do
      state = %{state | renewal_due: now_ms() + @renewal_ms}

      state =
        send_tracked(state, :renewal, "session.acquire_control", %{
          "session_id" => Wire.encode_identity(state.session_id)
        })

      Process.put(@live, state)
      state
    else
      state
    end
  end

  defp maybe_renew(state), do: state

  # Concept: a held lease is released on every exit path with a writable
  # socket; a closed socket lets the lease expire on the daemon's clock.
  defp release(%{client: client, epoch: epoch} = state) when client != nil and epoch != nil do
    Logger.debug("loopex live client releasing control")

    _ =
      DaemonClient.request(
        client,
        "session.release_control",
        %{
          "session_id" => Wire.encode_identity(state.session_id),
          "writer_epoch" => Wire.encode_identity(epoch)
        },
        @release_wait_ms
      )

    :ok
  end

  defp release(_state), do: :ok

  defp close(%{client: nil} = state), do: %{state | epoch: nil}

  defp close(%{client: client} = state) do
    DaemonClient.close(client)
    flush(client.reader)
    %{state | client: nil, epoch: nil, pending: %{}}
  end

  defp flush(reader) do
    receive do
      {:loopex_daemon_record, ^reader, _record} -> flush(reader)
      {:loopex_daemon_closed, ^reader} -> flush(reader)
    after
      0 -> :ok
    end
  end

  defp unresolved(message, state) do
    case Enum.find(state.steps, &(&1.status == :sent_unconfirmed)) do
      nil -> message
      step -> message <> "; " <> unresolved_step(step)
    end
  end

  defp unresolved_step(step), do: "#{step.method} command #{step.command_id} is unresolved"

  defp refusal_text(%{"type" => "admission", "status" => "refused", "reason" => reason}),
    do: "the daemon refused the command: #{reason}"

  defp refusal_text(%{"type" => "error", "code" => code}), do: "the daemon refused: #{code}"
  defp refusal_text(_record), do: "the daemon answered unexpectedly"

  defp ordered(pairs) do
    body =
      Enum.map_intersperse(pairs, ",", fn
        {key, {:raw, iodata}} -> [JSON.encode!(key), ":", iodata]
        {key, value} -> [JSON.encode!(key), ":", JSON.encode!(value)]
      end)

    ["{", body, "}"]
  end

  defp readable(nil), do: nil

  defp readable(encoded) do
    case Wire.identity(encoded) do
      {:ok, bytes} -> if String.valid?(bytes), do: bytes, else: encoded
      :error -> encoded
    end
  end

  defp warn_if_full(true) do
    IO.puts(
      :stderr,
      "loopex: the daemon's index is full, so this listing may omit sessions this root contains"
    )

    :ok
  end

  defp warn_if_full(_not_full), do: :ok

  defp decode_identity(encoded) do
    {:ok, value} = Wire.identity(encoded)
    value
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp unique_id, do: "live-" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
  defp now_ms, do: System.monotonic_time(:millisecond)
end
