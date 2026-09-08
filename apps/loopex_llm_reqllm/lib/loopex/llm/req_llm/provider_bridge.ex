defmodule Loopex.LLM.ReqLLM.ProviderBridge do
  @moduledoc false

  alias Loopex.Model
  alias Loopex.Runtime.ProviderLifetime
  alias Loopex.LLM.ReqLLM.{ProviderCodec, ProviderConfiguration, ProviderLauncher}

  @not_dispatched {:error, {:not_dispatched, "model_call_failed"}}
  @unknown {:error, {:dispatched_or_unknown, "model_call_failed"}}
  @semantic_fields [
    :canonicalization_version,
    :model,
    :messages,
    :tools,
    :sampling,
    :deadline,
    :continuation
  ]

  @doc false
  def complete(request, configuration, progress) when is_function(progress, 1) do
    with :ok <- Model.validate_request(request),
         true <- request.deadline > System.system_time(:millisecond),
         :ok <- ProviderConfiguration.verify_artifact(configuration) do
      caller = self()
      reference = make_ref()
      stop_reference = make_ref()
      progress_slot = :atomics.new(1, [])

      {guardian, monitor} =
        spawn_monitor(fn -> initialize(caller, reference, stop_reference, progress_slot) end)

      lifetime = ProviderLifetime.register(guardian, stop_reference)
      send(guardian, {:initialize, reference, lifetime, request, configuration})
      await_result(guardian, monitor, reference, progress_slot, progress)
    else
      _refused -> @not_dispatched
    end
  catch
    _kind, _reason -> @unknown
  end

  defp await_result(guardian, monitor, reference, progress_slot, progress) do
    receive do
      {:provider_delta, ^reference, ^guardian, delta} ->
        try do
          progress.(delta)
        catch
          _kind, _reason -> :ok
        after
          :atomics.put(progress_slot, 1, 0)
        end

        await_result(guardian, monitor, reference, progress_slot, progress)

      {:provider_result, ^reference, ^guardian, result} ->
        Process.demonitor(monitor, [:flush])
        result

      {:DOWN, ^monitor, :process, ^guardian, _reason} ->
        @unknown
    end
  end

  defp initialize(caller, reference, stop_reference, progress_slot) do
    Process.flag(:trap_exit, true)
    caller_monitor = Process.monitor(caller)

    receive do
      {:initialize, ^reference, lifetime, request, configuration} ->
        case ProviderConfiguration.cleanup_period(configuration, lifetime) do
          {:ok, grace} ->
            retainer =
              case lifetime do
                {:managed, pid, ^grace} -> pid
                :unmanaged -> caller
              end

            state = %{
              caller: caller,
              caller_monitor: caller_monitor,
              reference: reference,
              stop_reference: stop_reference,
              slot: progress_slot,
              lifetime: lifetime,
              retainer: retainer,
              retainer_monitor: Process.monitor(retainer),
              request: request,
              configuration: configuration,
              grace: grace,
              nonce: Base.encode16(:crypto.strong_rand_bytes(32), case: :lower),
              deadline: invocation_deadline(request.deadline, System.time_offset(:native)),
              phase: :launch,
              namespace: nil,
              port: nil,
              carrier: nil,
              socket: nil,
              receiver: nil,
              sender: nil,
              possible_delivery: false,
              result: nil,
              delivered: false,
              cleanup: nil,
              proved: false,
              protocol_failed: false,
              port_exited: false,
              retainer_lost: false
            }

            launch(state)

          _refused ->
            send(caller, {:provider_result, reference, self(), @not_dispatched})
        end

      {:DOWN, ^caller_monitor, :process, ^caller, _reason} ->
        :ok
    end
  end

  defp launch(state) do
    receive do
      {:DOWN, monitor, :process, _pid, _reason}
      when monitor == state.retainer_monitor or monitor == state.caller_monitor ->
        :ok
    after
      0 ->
        case ProviderLauncher.prepare() do
          {:ok, namespace} ->
            next = %{state | namespace: namespace}

            case ProviderLauncher.start(
                   namespace,
                   state.configuration,
                   state.nonce,
                   state.grace,
                   state.request.deadline
                 ) do
              {:ok, %{port: port, carrier: carrier}} ->
                loop(%{next | phase: :guard_ready, port: port, carrier: carrier})

              _refused ->
                :gen_tcp.close(namespace.listener)
                ProviderLauncher.abandon(namespace.namespace)
                finish_without_os(next, @not_dispatched)
            end

          _refused ->
            finish_without_os(state, @not_dispatched)
        end
    end
  end

  defp finish_without_os(state, result) do
    state |> Map.put(:proved, true) |> Map.put(:result, result) |> deliver_or_retain()
  end

  # Concept: the resource owner remains responsive in every phase, including
  # credential delivery and the wait after a callback answer.
  # Technical depth: blocking socket reads and writes run in raw monitored
  # children. Each receiver submits one frame and waits for permission before
  # another read; the guardian mailbox cannot accumulate an unbounded data queue.
  defp loop(state) do
    receive do
      {port, {:data, {:eol, line}}} when port == state.port ->
        control_frame(state, line)

      {port, {:data, _partial_or_invalid}} when port == state.port ->
        fail(state)

      {port, {:exit_status, _status}} when port == state.port ->
        port_lost(%{state | port_exited: true})

      {:EXIT, port, _reason} when port == state.port ->
        port_lost(state)

      {:provider_frame, receiver, frame} when receiver == state.receiver ->
        data_frame(state, frame)

      {:provider_sent, sender, phase, result} when sender == state.sender ->
        sent(%{state | sender: nil}, phase, result)

      {:DOWN, monitor, :process, _pid, _reason} when monitor == state.retainer_monitor ->
        begin_cleanup(%{state | result: @unknown, retainer_lost: true}, nil)

      {:DOWN, monitor, :process, _pid, _reason} when monitor == state.caller_monitor ->
        if state.lifetime == :unmanaged or not state.delivered do
          begin_cleanup(%{state | result: @unknown}, nil)
        else
          loop(state)
        end

      {:DOWN, _monitor, :process, pid, _reason} when pid == state.sender ->
        fail(%{state | sender: nil})

      {:DOWN, _monitor, :process, pid, _reason} when pid == state.receiver ->
        fail(%{state | receiver: nil})

      {:loopex_provider_resource_stop, stop_reference, stop, requester, cooperative, observation}
      when stop_reference == state.stop_reference and is_reference(stop) and is_pid(requester) and
             is_integer(cooperative) and is_integer(observation) and observation >= cooperative ->
        begin_cleanup(state, {requester, stop, cooperative, observation})

      _irrelevant ->
        loop(state)
    after
      10 -> tick(state)
    end
  end

  defp control_frame(%{phase: :guard_ready} = state, line) do
    expected = "ready:#{state.nonce}:#{state.carrier}:"

    with true <- String.starts_with?(line, expected),
         [guard_bytes, namespace] <- String.split(String.replace_prefix(line, expected, ""), ":"),
         {guard, ""} <- Integer.parse(guard_bytes),
         true <- guard > 1 and guard != state.carrier,
         true <- namespace == state.namespace.namespace,
         true <- Port.command(state.port, "run:#{state.nonce}\n") do
      loop(%{state | phase: :accept})
    else
      _invalid -> fail(state)
    end
  end

  defp control_frame(%{cleanup: %{id: id}} = state, line) do
    cond do
      line == "cleanup_complete:#{state.nonce}:#{id}" ->
        if now() <= state.cleanup.cooperative do
          cleanup_proved(%{state | proved: true})
        else
          deliver(state, @unknown)
          close_port(state.port)
        end

      valid_ready?(state, line) ->
        loop(state)

      true ->
        fail(%{state | protocol_failed: true})
    end
  end

  defp control_frame(state, _line), do: fail(state)

  defp tick(%{phase: :retained} = state), do: loop(state)

  defp tick(%{cleanup: cleanup} = state) when not is_nil(cleanup) do
    if now() >= cleanup.observation do
      deliver(state, @unknown)
      close_port(state.port)
    else
      loop(state)
    end
  end

  defp tick(state) do
    cond do
      System.monotonic_time() >= state.deadline -> fail(state)
      state.phase == :accept -> accept(state)
      true -> loop(state)
    end
  end

  defp accept(state) do
    case :gen_tcp.accept(state.namespace.listener, 0) do
      {:ok, socket} ->
        :gen_tcp.close(state.namespace.listener)

        # Concept: the committed invocation deadline, not an additional socket
        # timer, bounds a write even when the child stops reading.
        # Technical depth: every send runs in a raw linked and monitored child.
        # This guardian keeps reducing deadline and lifetime events, kills its
        # sender and aborts the socket on cleanup; its own abnormal death also
        # kills those linked helpers. The primitive cannot represent the full
        # uint64 deadline domain, so it supplies no competing timeout.
        :ok =
          :inet.setopts(socket, [
            {:send_timeout, :infinity},
            {:send_timeout_close, true},
            {:linger, {true, 0}}
          ])

        receiver = start_receiver(socket, state.deadline)
        payload = identity(state)
        sender = start_send(socket, :bootstrap, payload)
        loop(%{state | socket: socket, receiver: receiver, sender: sender, phase: :bootstrap})

      {:error, :timeout} ->
        loop(state)

      _refused ->
        fail(state)
    end
  end

  defp start_receiver(socket, deadline) do
    guardian = self()

    {receiver, _monitor} =
      :erlang.spawn_opt(fn -> receive_frame(guardian, socket, deadline) end, [:link, :monitor])

    receiver
  end

  defp receive_frame(guardian, socket, deadline) do
    frame =
      try do
        socket
        |> ProviderCodec.recv(ProviderCodec.remaining_timeout(deadline, System.monotonic_time()))
        |> received_frame()
      catch
        _kind, _reason -> {:error, :invalid_frame}
      end

    send(guardian, {:provider_frame, self(), frame})

    receive do
      :next -> receive_frame(guardian, socket, deadline)
      :stop -> :ok
    end
  end

  # Concept: a child may not echo the credential through an ordinary host
  # message, even when deliberately exercising a protocol failure.
  # Technical depth: this check runs inside the raw socket receiver, before it
  # sends anything to the guardian. Only child-to-host kinds may carry payloads;
  # every other kind or failure reduces to a closed, atom-only error.
  defp received_frame({:ok, kind, payload})
       when kind in [:ready, :dispatch_started, :delta, :terminal],
       do: {:ok, kind, payload}

  defp received_frame({:error, reason}) when reason in [:closed, :timeout],
    do: {:error, reason}

  defp received_frame(_rejected), do: {:error, :invalid_frame}

  defp start_send(socket, kind, payload) do
    guardian = self()

    {sender, _monitor} =
      :erlang.spawn_opt(
        fn ->
          result =
            try do
              ProviderCodec.send(socket, kind, payload)
            catch
              _kind, _reason -> :error
            end

          send(guardian, {:provider_sent, self(), kind, result})
        end,
        [:link, :monitor]
      )

    sender
  end

  # Concept: only a minimal raw sender resolves and transmits the credential.
  # Technical depth: its closure contains no credential. It establishes its own
  # IO sink, reads the environment after exact readiness, validates the bound,
  # sends the frame itself and reports only an atom. No Task/GenServer request,
  # process state, exit reason, argv, environment update or file carries the key.
  defp start_credential_sender(socket, nonce) do
    guardian = self()

    {sender, _monitor} =
      :erlang.spawn_opt(
        fn ->
          sender = self()
          sink = spawn(fn -> sink_loop(Process.monitor(sender)) end)
          Process.group_leader(self(), sink)

          result =
            try do
              case System.get_env("LOOPEX_PROVIDER_API_KEY") do
                key when is_binary(key) and byte_size(key) in 1..65_536 ->
                  case ProviderCodec.send(socket, :credential, %{
                         "nonce" => nonce,
                         "credential" => key
                       }) do
                    :ok -> :ok
                    _failed -> :error
                  end

                _refused ->
                  :error
              end
            catch
              _kind, _reason -> :error
            end

          send(guardian, {:provider_sent, self(), :credential, result})
        end,
        [:link, :monitor]
      )

    sender
  end

  defp sink_loop(monitor) do
    receive do
      {:io_request, from, reply_as, _request} ->
        send(from, {:io_reply, reply_as, {:error, :enotsup}})
        sink_loop(monitor)

      {:DOWN, ^monitor, :process, _sender, _reason} ->
        :ok

      _other ->
        sink_loop(monitor)
    end
  end

  defp sent(%{phase: :bootstrap} = state, :bootstrap, :ok), do: loop(state)

  defp sent(%{phase: :credential} = state, :credential, :ok) do
    payload = %{
      "nonce" => state.nonce,
      "request" => Map.take(state.request, @semantic_fields),
      "canonical_request_bytes" => state.request.canonical_request_bytes,
      "staged_request_digest" => state.request.staged_request_digest
    }

    sender = start_send(state.socket, :invocation, payload)
    loop(%{state | phase: :invocation, sender: sender, possible_delivery: true})
  end

  defp sent(%{phase: phase} = state, :invocation, :ok)
       when phase in [:invocation, :running, :terminal_end, :retained],
       do: loop(state)

  defp sent(state, _phase, _failed), do: fail(state)

  defp data_frame(%{phase: :bootstrap} = state, {:ok, :ready, payload}) do
    if payload == identity(state) do
      send(state.receiver, :next)
      sender = start_credential_sender(state.socket, state.nonce)
      loop(%{state | phase: :credential, sender: sender})
    else
      fail(state)
    end
  end

  defp data_frame(%{phase: :invocation} = state, {:ok, :dispatch_started, payload}) do
    if payload == invocation_binding(state) do
      send(state.receiver, :next)
      loop(%{state | phase: :running})
    else
      fail(state)
    end
  end

  defp data_frame(%{phase: :running} = state, {:ok, :delta, payload}) do
    if Map.drop(payload, ["payload"]) == invocation_binding(state) do
      delta = Map.get(payload, "payload")

      if Model.valid_delta?(delta) and :atomics.compare_exchange(state.slot, 1, 0, 1) == :ok do
        send(state.caller, {:provider_delta, state.reference, self(), delta})
      end

      send(state.receiver, :next)
      loop(state)
    else
      fail(state)
    end
  end

  defp data_frame(%{phase: phase} = state, {:ok, :terminal, payload})
       when phase in [:invocation, :running] do
    case terminal(state, payload) do
      {:ok, result} ->
        send(state.receiver, :next)
        loop(%{state | phase: :terminal_end, result: result})

      :error ->
        fail(state)
    end
  end

  # EOF seals one already validated terminal frame; it is never cleanup proof.
  defp data_frame(%{phase: :terminal_end} = state, {:error, :closed}) do
    stop_process(state.receiver)
    state = %{state | receiver: nil}
    if state.lifetime == :unmanaged, do: begin_cleanup(state, nil), else: deliver_or_retain(state)
  end

  defp data_frame(state, _invalid), do: fail(%{state | protocol_failed: true})

  defp terminal(state, payload) do
    if Map.drop(payload, ["status", "reply"]) == invocation_binding(state) do
      case {payload["status"], Map.fetch(payload, "reply"), state.phase} do
        {"reply", {:ok, reply}, :running} -> {:ok, {:ok, reply}}
        {"unreadable", :error, :running} -> {:ok, {:ok, %{}}}
        {"not_dispatched", :error, :invocation} -> {:ok, @not_dispatched}
        {"dispatched_or_unknown", :error, _phase} -> {:ok, @unknown}
        _contradiction -> :error
      end
    else
      :error
    end
  end

  defp identity(state),
    do: %{
      "nonce" => state.nonce,
      "version" => 1,
      "build_manifest_sha256" => state.configuration.build_manifest_sha256
    }

  defp invocation_binding(state),
    do: %{
      "nonce" => state.nonce,
      "staged_request_digest" => state.request.staged_request_digest
    }

  defp fail(state) do
    result = if state.possible_delivery, do: @unknown, else: @not_dispatched
    begin_cleanup(%{state | result: result}, nil)
  end

  defp port_lost(%{proved: true} = state), do: cleanup_proved(state)
  defp port_lost(%{cleanup: nil} = state), do: fail(state)
  defp port_lost(state), do: loop(state)

  defp begin_cleanup(state, request) do
    # Concept: cleanup must not wait for a child to drain buffered invocation
    # bytes before it can stop that child.
    # Technical depth: terminate the owned blocked helpers first. The data
    # socket's abortive-close setting discards pending output here; ordinary
    # close may wait on an independent drain timer beyond the committed bound.
    stop_process(state.sender)
    stop_process(state.receiver)
    close_socket(state.socket)
    if state.namespace, do: close_socket(state.namespace.listener)
    state = %{state | sender: nil, receiver: nil, socket: nil}

    cleanup = state.cleanup || new_cleanup(state, request)
    cleanup = attach_request(cleanup, request)
    state = %{state | cleanup: cleanup, phase: :cleanup}

    cond do
      state.proved ->
        cleanup_proved(state)

      is_nil(state.port) ->
        cleanup_proved(%{state | proved: true})

      cleanup.sent ->
        loop(state)

      true ->
        command = "stop:#{state.nonce}:#{cleanup.id}:#{remaining(cleanup.cooperative)}\n"

        _sent =
          try do
            Port.command(state.port, command)
          catch
            _, _ -> false
          end

        next = %{state | cleanup: %{cleanup | sent: true}}

        next =
          if state.lifetime != :unmanaged, do: deliver(next, next.result || @unknown), else: next

        loop(next)
    end
  end

  defp new_cleanup(state, request) do
    {cooperative, observation} =
      case request do
        {_requester, _stop, cooperative, observation} ->
          {cooperative, observation}

        nil ->
          # Unmanaged cleanup has exactly one window, including confirmation.
          until = now() + state.grace
          {until, until}
      end

    %{
      id: Base.encode16(:crypto.strong_rand_bytes(16), case: :lower),
      sent: false,
      cooperative: cooperative,
      observation: observation,
      requester: nil,
      stop: nil
    }
  end

  defp attach_request(cleanup, nil), do: cleanup

  defp attach_request(cleanup, {requester, stop, cooperative, observation}) do
    %{
      cleanup
      | requester: requester,
        stop: stop,
        cooperative: min(cleanup.cooperative, cooperative),
        observation: min(cleanup.observation, observation)
    }
  end

  defp cleanup_proved(%{cleanup: %{requester: requester, stop: stop}} = state)
       when is_pid(requester) and is_reference(stop) do
    send(requester, {:loopex_provider_resource_stopped, stop, self()})
    close_port(state.port)
    :ok
  end

  defp cleanup_proved(%{retainer_lost: true} = state) do
    close_port(state.port)
    :ok
  end

  defp cleanup_proved(state), do: deliver_or_retain(%{state | proved: true})

  defp deliver_or_retain(%{lifetime: :unmanaged} = state) do
    deliver(state, state.result || @unknown)
    close_port(state.port)
    :ok
  end

  defp deliver_or_retain(state) do
    next = deliver(state, state.result || @unknown)
    loop(%{next | phase: :retained})
  end

  defp deliver(%{delivered: true} = state, _result), do: state

  defp deliver(state, result) do
    send(state.caller, {:provider_result, state.reference, self(), result})
    %{state | delivered: true}
  end

  defp stop_process(nil), do: :ok
  defp stop_process(pid), do: Process.exit(pid, :kill)
  defp close_socket(nil), do: :ok
  defp close_socket(socket), do: :gen_tcp.close(socket)
  defp close_port(nil), do: :ok

  defp close_port(port) do
    try do
      Port.close(port)
    catch
      _, _ -> :ok
    end
  end

  # Concept: conversion retains the invocation's one committed instant.
  # Technical depth: adding a later wall remainder to an earlier monotonic
  # sample charges the interval between reads twice. One native offset maps
  # the wall instant without either that loss or an opposite extra allowance.
  # Freeze this offset once; cleanup continues to use its existing millisecond
  # clock. This internal arithmetic entry is also the deterministic test seam,
  # not an alternate clock, runtime option, or Model callback.
  @doc false
  def invocation_deadline(wall_milliseconds, native_offset)
      when is_integer(wall_milliseconds) and is_integer(native_offset) do
    System.convert_time_unit(wall_milliseconds, :millisecond, :native) - native_offset
  end

  defp now, do: System.monotonic_time(:millisecond)
  defp remaining(deadline), do: max(deadline - now(), 0)

  defp valid_ready?(state, line) do
    prefix = "ready:#{state.nonce}:#{state.carrier}:"

    with true <- String.starts_with?(line, prefix),
         [guard_bytes, namespace] <- String.split(String.replace_prefix(line, prefix, ""), ":"),
         {guard, ""} <- Integer.parse(guard_bytes) do
      guard > 1 and guard != state.carrier and namespace == state.namespace.namespace
    else
      _invalid -> false
    end
  end
end
