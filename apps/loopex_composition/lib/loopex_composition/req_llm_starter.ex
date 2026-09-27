defmodule LoopexComposition.ReqLLMStarter do
  @moduledoc """
  ## Concept

  Serializes the shared provider dependency's guarded startup without owning
  a session or cancelling admitted startup when a requester leaves.

  ## Technical depth

  This private composition service groups matching host declarations. One
  unlinked, monitored worker validates configuration and receives a separate
  one-use grant for an actual start. Persistent provenance names the exact
  ReqLLM supervisor incarnation. The temporary service can be recreated while
  that initializer completes; it observes its DOWN before validating again.
  Every outward failure is a fixed admission reason, never a dependency cause.
  """

  use GenServer

  @initializer {__MODULE__, :initializer}
  @provenance {__MODULE__, :provenance}
  # Concept: unavailable shared startup cannot retain an unbounded queue.
  # Technical depth: 128 requests bound active and queued custody together;
  # overflow uses the existing startup failure without cancelling an initializer.
  @max_waiters 128
  @wait_ms 5_000
  @slice_ms 1_000
  @refusals [
    :req_llm_start_failed,
    :req_llm_already_started,
    :req_llm_host_declaration_invalid,
    :req_llm_dotenv_enabled,
    :ssl_key_log_enabled,
    :req_default_options_unsupported,
    :req_llm_tidewave_enabled
  ]

  @doc """
  ## Concept

  Starts the fixed shared startup service.

  ## Technical depth

  No alternate name, startup implementation or configuration is accepted.
  Its parent must use one_for_one with auto_shutdown: never.
  """
  @spec start_link([]) :: GenServer.on_start()
  def start_link([]), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)
  def start_link(_options), do: {:error, :req_llm_start_failed}

  @doc """
  ## Concept

  Service loss never consumes the session parent's restart budget.

  ## Technical depth

  The temporary, nonsignificant child is recreated only by later bounded
  composition bootstrap, not by an automatic restart loop.
  """
  @spec child_spec([]) :: Supervisor.child_spec()
  def child_spec(options) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [options]},
      restart: :temporary,
      significant: false,
      shutdown: @slice_ms,
      type: :worker
    }
  end

  @doc """
  ## Concept

  Requests guarded dependency availability with this requester's declaration.

  ## Technical depth

  The absolute deadline uses System.monotonic_time's native unit. The exact
  service is monitored and waits are sliced at 1,000 ms. Expiry or service
  loss returns req_llm_start_failed without resubmission or startup cancellation.
  """
  @spec request(pid(), nil | :host_started, integer()) :: :ok | {:error, atom()}
  def request(service, declaration, deadline)
      when is_pid(service) and declaration in [nil, :host_started] and is_integer(deadline) do
    expiry = min(deadline, now() + native_ms(@wait_ms))

    if remaining(expiry) == 0 do
      failed()
    else
      reference = make_ref()
      monitor = Process.monitor(service)
      send(service, {:request, self(), reference, declaration, expiry})

      try do
        await(service, monitor, reference, expiry)
      after
        Process.demonitor(monitor, [:flush])
      end
    end
  end

  def request(_service, _declaration, _deadline), do: failed()

  @impl true
  def init([]) do
    state = %{operation: nil, queued: [], reconciliation: nil, origin: nil, timer: nil}
    {:ok, reconcile_initializer(state)}
  end

  @impl true
  def handle_info({:request, requester, reference, declaration, expiry}, state)
      when is_pid(requester) and is_reference(reference) and declaration in [nil, :host_started] and
             is_integer(expiry) do
    state = prune(state)

    cond do
      node(requester) != node() or remaining(expiry) == 0 ->
        {:noreply, schedule(state)}

      waiter_count(state) >= @max_waiters ->
        reply(%{pid: requester, ref: reference, expiry: expiry}, failed())
        {:noreply, schedule(state)}

      true ->
        waiter = %{
          pid: requester,
          ref: reference,
          declaration: declaration,
          expiry: min(expiry, now() + native_ms(@wait_ms)),
          monitor: Process.monitor(requester)
        }

        state = add_waiter(state, waiter) |> advance() |> schedule()
        {:noreply, state}
    end
  end

  def handle_info({:start_requested, worker, reference}, state) do
    state = prune(state)

    case state.operation do
      %{pid: ^worker, ref: ^reference, phase: :validating, waiters: [_ | _]} = operation ->
        identity = {:preparing, worker, reference}

        if :persistent_term.get(@initializer, :absent) == :absent do
          # Concept: only admitted startup survives its creating service.
          # Technical depth: publish custody before granting the one-use start.
          :persistent_term.put(@initializer, identity)
          send(worker, {:start_grant, self(), reference})
          {:noreply, schedule(%{state | operation: %{operation | phase: :starting}})}
        else
          send(worker, {:start_refused, self(), reference})
          {:noreply, schedule(state)}
        end

      %{pid: ^worker, ref: ^reference, phase: :validating} ->
        send(worker, {:start_refused, self(), reference})
        {:noreply, schedule(state)}

      _ ->
        {:noreply, schedule(state)}
    end
  end

  def handle_info({:validation_result, worker, reference, result}, state) do
    case state.operation do
      %{pid: ^worker, ref: ^reference, result: nil} = operation ->
        {:noreply, %{state | operation: %{operation | result: sanitize_result(result)}}}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, monitor, :process, pid, reason}, state) do
    state = prune(state)

    cond do
      match?(%{pid: ^pid, monitor: ^monitor}, state.operation) ->
        operation = state.operation
        clear_initializer({:preparing, pid, operation.ref})

        result =
          if reason == :normal do
            confirm_result(operation.result, operation.declaration)
          else
            failed()
          end

        Enum.each(operation.waiters, &settle_waiter(&1, result))
        state = %{state | operation: nil} |> sync_origin() |> advance() |> schedule()
        {:noreply, state}

      match?(%{pid: ^pid, monitor: ^monitor}, state.reconciliation) ->
        clear_initializer(state.reconciliation.identity)
        state = %{state | reconciliation: nil} |> advance() |> schedule()
        {:noreply, state}

      match?(%{pid: ^pid, monitor: ^monitor}, state.origin) ->
        {:noreply, %{state | origin: nil}}

      true ->
        {:noreply, drop_waiter(state, monitor) |> advance() |> schedule()}
    end
  end

  def handle_info({:sweep, token}, %{timer: {_timer, token}} = state) do
    {:noreply, %{state | timer: nil} |> prune() |> advance() |> schedule()}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp await(service, monitor, reference, expiry) do
    wait = min(remaining(expiry), @slice_ms)

    if wait == 0 do
      failed()
    else
      receive do
        {:req_llm_start, ^service, ^reference, result} ->
          if remaining(expiry) > 0, do: public_result(result), else: failed()

        {:DOWN, ^monitor, :process, ^service, _reason} ->
          failed()
      after
        wait -> await(service, monitor, reference, expiry)
      end
    end
  end

  defp add_waiter(%{operation: %{declaration: declaration} = operation} = state, waiter)
       when declaration == waiter.declaration do
    %{state | operation: %{operation | waiters: operation.waiters ++ [waiter]}}
  end

  defp add_waiter(state, waiter), do: %{state | queued: state.queued ++ [waiter]}

  defp advance(%{operation: nil, reconciliation: nil} = state) do
    state = reconcile_initializer(state)

    case {state.reconciliation, state.queued} do
      {:invalid, waiters} ->
        Enum.each(waiters, &settle_waiter(&1, failed()))
        %{state | queued: []}

      {nil, [first | rest]} ->
        {cohort, queued} = Enum.split_with(rest, &(&1.declaration == first.declaration))
        service = self()
        reference = make_ref()

        {worker, monitor} =
          spawn_monitor(fn -> validate_worker(service, reference, first.declaration) end)

        operation = %{
          pid: worker,
          monitor: monitor,
          ref: reference,
          declaration: first.declaration,
          waiters: [first | cohort],
          phase: :validating,
          result: nil
        }

        send(worker, {:validate, service, reference})
        %{state | queued: queued, operation: operation} |> sync_origin()

      _ ->
        state
    end
  end

  defp advance(%{reconciliation: :invalid} = state) do
    advance(%{state | reconciliation: nil})
  end

  defp advance(state), do: state

  defp reconcile_initializer(%{reconciliation: nil} = state) do
    case :persistent_term.get(@initializer, :absent) do
      :absent ->
        state

      {:preparing, pid, ref} = identity when is_pid(pid) and is_reference(ref) ->
        if node(pid) == node() do
          %{
            state
            | reconciliation: %{pid: pid, monitor: Process.monitor(pid), identity: identity}
          }
        else
          %{state | reconciliation: :invalid}
        end

      _ ->
        %{state | reconciliation: :invalid}
    end
  end

  defp sync_origin(state) do
    case :persistent_term.get(@provenance, :absent) do
      {:started, pid, ref} when is_pid(pid) and is_reference(ref) ->
        cond do
          node(pid) != node() ->
            state

          match?(%{pid: ^pid}, state.origin) ->
            state

          true ->
            if state.origin, do: Process.demonitor(state.origin.monitor, [:flush])
            %{state | origin: %{pid: pid, monitor: Process.monitor(pid)}}
        end

      _ ->
        state
    end
  end

  defp validate_worker(service, reference, declaration) do
    monitor = Process.monitor(service)

    receive do
      {:validate, ^service, ^reference} ->
        result = safely(fn -> validate(declaration) end)

        result =
          case result do
            :start ->
              send(service, {:start_requested, self(), reference})
              await_start_grant(service, monitor, reference, declaration)

            other ->
              other
          end

        send(service, {:validation_result, self(), reference, result})

      {:DOWN, ^monitor, :process, ^service, _reason} ->
        :ok
    after
      @slice_ms -> :ok
    end

    Process.demonitor(monitor, [:flush])
  end

  defp await_start_grant(service, monitor, reference, declaration) do
    receive do
      {:start_grant, ^service, ^reference} ->
        Process.demonitor(monitor, [:flush])
        safely(fn -> admitted_start(reference, declaration) end)

      {:start_refused, ^service, ^reference} ->
        failed()

      {:DOWN, ^monitor, :process, ^service, _reason} ->
        failed()
    after
      @slice_ms -> failed()
    end
  end

  defp admitted_start(reference, declaration) do
    if :persistent_term.get(@initializer, :absent) == {:preparing, self(), reference} do
      case validate(declaration) do
        :start ->
          with :ok <- guards() do
            Application.put_env(:req_llm, :load_dotenv, false, persistent: true)

            case Application.ensure_all_started(:req_llm) do
              {:ok, applications} when is_list(applications) ->
                if :req_llm in applications do
                  case supervisor() do
                    {:ok, pid} ->
                      :persistent_term.put(@provenance, {:started, pid, reference})
                      {:ok, pid}

                    _ ->
                      failed()
                  end
                else
                  failed()
                end

              _ ->
                failed()
            end
          end

        other ->
          other
      end
    else
      failed()
    end
  end

  defp validate(declaration) do
    with :ok <- guards(), {:ok, provenance} <- provenance() do
      running? = Enum.any?(Application.started_applications(), &(elem(&1, 0) == :req_llm))
      pid = Process.whereis(ReqLLM.Supervisor)
      dotenv? = Application.get_env(:req_llm, :load_dotenv, true) != false

      cond do
        not running? and declaration == :host_started ->
          {:error, :req_llm_host_declaration_invalid}

        (running? or provenance != :absent) and dotenv? ->
          {:error, :req_llm_dotenv_enabled}

        running? and is_pid(pid) and Process.alive?(pid) ->
          if declaration == :host_started or match?({:started, ^pid, _}, provenance),
            do: {:ok, pid},
            else: {:error, :req_llm_already_started}

        not running? and is_nil(pid) ->
          :start

        true ->
          failed()
      end
    end
  end

  defp guards do
    cond do
      System.get_env("SSLKEYLOGFILE") != nil ->
        {:error, :ssl_key_log_enabled}

      Application.get_env(:req, :default_options, []) != [] ->
        {:error, :req_default_options_unsupported}

      System.get_env("TIDEWAVE_REPL") == "true" ->
        {:error, :req_llm_tidewave_enabled}

      true ->
        :ok
    end
  end

  defp provenance do
    case :persistent_term.get(@provenance, :absent) do
      :absent ->
        {:ok, :absent}

      {:started, pid, reference} = record when is_pid(pid) and is_reference(reference) ->
        if node(pid) == node(), do: {:ok, record}, else: failed()

      _ ->
        failed()
    end
  end

  defp supervisor do
    case Process.whereis(ReqLLM.Supervisor) do
      pid when is_pid(pid) ->
        if Process.alive?(pid) and Application.get_env(:req_llm, :load_dotenv, true) == false,
          do: {:ok, pid},
          else: failed()

      _ ->
        failed()
    end
  end

  defp confirm_result({:ok, pid}, declaration) do
    with :absent <- :persistent_term.get(@initializer, :absent),
         :ok <- guards(),
         {:ok, provenance} <- provenance(),
         {:ok, ^pid} <- supervisor() do
      if declaration == :host_started or match?({:started, ^pid, _}, provenance),
        do: :ok,
        else: {:error, :req_llm_already_started}
    else
      {:error, reason} when reason in @refusals -> {:error, reason}
      _ -> failed()
    end
  end

  defp confirm_result({:error, reason}, _declaration) when reason in @refusals,
    do: {:error, reason}

  defp confirm_result(_result, _declaration), do: failed()

  defp safely(function) do
    try do
      function.()
    rescue
      _ -> failed()
    catch
      _, _ -> failed()
    end
  end

  defp sanitize_result({:ok, pid}) when is_pid(pid), do: {:ok, pid}
  defp sanitize_result({:error, reason}) when reason in @refusals, do: {:error, reason}
  defp sanitize_result(_result), do: failed()
  defp public_result(:ok), do: :ok
  defp public_result({:error, reason}) when reason in @refusals, do: {:error, reason}
  defp public_result(_result), do: failed()
  defp failed, do: {:error, :req_llm_start_failed}

  defp clear_initializer(identity) do
    if :persistent_term.get(@initializer, :absent) == identity,
      do: :persistent_term.erase(@initializer)
  end

  defp prune(state) do
    queued = prune_waiters(state.queued)

    operation =
      case state.operation do
        nil -> nil
        operation -> %{operation | waiters: prune_waiters(operation.waiters)}
      end

    %{state | queued: queued, operation: operation}
  end

  defp prune_waiters(waiters) do
    Enum.filter(waiters, fn waiter ->
      if remaining(waiter.expiry) > 0 and Process.alive?(waiter.pid) do
        true
      else
        settle_waiter(waiter, failed())
        false
      end
    end)
  end

  defp drop_waiter(state, monitor) do
    queued = Enum.reject(state.queued, &(&1.monitor == monitor))

    operation =
      case state.operation do
        nil ->
          nil

        operation ->
          %{operation | waiters: Enum.reject(operation.waiters, &(&1.monitor == monitor))}
      end

    %{state | queued: queued, operation: operation}
  end

  defp settle_waiter(waiter, result) do
    reply(waiter, result)
    Process.demonitor(waiter.monitor, [:flush])
  end

  defp reply(waiter, result) do
    if remaining(waiter.expiry) > 0 do
      send(waiter.pid, {:req_llm_start, self(), waiter.ref, result})
    end
  end

  defp waiter_count(state) do
    length(state.queued) + if(state.operation, do: length(state.operation.waiters), else: 0)
  end

  defp schedule(state) do
    if state.timer, do: Process.cancel_timer(elem(state.timer, 0))
    waiters = state.queued ++ if(state.operation, do: state.operation.waiters, else: [])

    case waiters do
      [] ->
        %{state | timer: nil}

      _ ->
        wait = waiters |> Enum.map(&remaining(&1.expiry)) |> Enum.min() |> min(@slice_ms)
        token = make_ref()
        timer = Process.send_after(self(), {:sweep, token}, wait)
        %{state | timer: {timer, token}}
    end
  end

  defp now, do: System.monotonic_time()
  defp native_ms(ms), do: System.convert_time_unit(ms, :millisecond, :native)

  defp remaining(expiry) do
    native = max(expiry - now(), 0)
    quantum = native_ms(1)
    div(native + quantum - 1, quantum)
  end
end
