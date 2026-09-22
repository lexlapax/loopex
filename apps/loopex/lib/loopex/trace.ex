defmodule Loopex.Trace do
  @moduledoc """
  ## Concept

  A runtime-scoped trace session. A host turns on tracing of every call in the
  modules it names, inside the processes this runtime owns, without changing a
  line of source, and turns it off again. Entries carry identities, timing and,
  at the administrative level, redacted arguments; they never carry content and
  never grant authority.

  ## Technical depth

  The session is an OTP 27 `trace` session, so it coexists with any other
  tracer in the VM and is destroyed as a unit. Only processes reachable from
  this runtime's supervisor are flagged, with `set_on_spawn` so a session
  coordinator started later is covered and a process the runtime does not own
  never is. Only modules on the allowlist have call patterns installed.

  This process is the only consumer of raw trace messages. It applies the
  session's ceilings before anything reaches a sink: entries beyond the
  per-second rate, or arriving while its own mailbox is over the queue ceiling,
  are dropped and counted, and the count is reported as its own entry. It never
  calls into a traced process and never replies to one, so a traced process is
  never delayed by the fact that it is traced.

  A trace session starts only through the runtime reference its host holds. No
  session command, client content, model output, project resource or app-server
  request reaches this module.
  """

  use GenServer

  alias Loopex.Runtime.DiagnosticsAdmission
  alias Loopex.Runtime.Supervisor, as: RuntimeSupervisor
  alias Loopex.Trace.Config
  alias Loopex.Trace.Entry

  require Logger

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options) when is_list(options), do: GenServer.start_link(__MODULE__, options)

  @doc false
  @spec start_session(pid(), reference(), term()) :: {:ok, map()} | {:error, term()}
  def start_session(tracer, token, config) when is_pid(tracer) do
    GenServer.call(tracer, {:start_session, token, config})
  end

  @doc false
  @spec stop_session(pid(), reference()) :: :ok | {:error, term()}
  def stop_session(tracer, token) when is_pid(tracer) do
    GenServer.call(tracer, {:stop_session, token})
  end

  @doc false
  @spec status(pid(), reference()) :: {:ok, map()} | {:error, term()}
  def status(tracer, token) when is_pid(tracer) do
    GenServer.call(tracer, {:session_status, token})
  end

  @doc """
  ## Concept

  Whether this OTP release offers trace sessions at all.

  ## Technical depth

  There is no fallback to `:dbg` or `erlang:trace/3`: both are VM-global and
  would collide with another tracer, which is the failure this facility exists
  to avoid. A release without the `trace` module reports unavailability and
  changes nothing.
  """
  @spec available?() :: boolean()
  def available?, do: available?(:trace)

  @doc """
  ## Concept

  Whether the named module provides OTP trace sessions.

  ## Technical depth

  The module is a parameter so a runtime can be started against the module an
  older release would have, and the unavailable path is then the real path
  rather than a simulated one. Production always names `:trace`.
  """
  @spec available?(module()) :: boolean()
  def available?(module) when is_atom(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :session_create, 3)
  end

  @impl GenServer
  def init(options) do
    {:ok,
     %{
       root: Keyword.fetch!(options, :root),
       token: Keyword.fetch!(options, :token),
       trace_module: Keyword.get(options, :trace_module, :trace),
       session: nil,
       config: nil,
       admission: nil,
       calls: %{},
       call_monitors: %{},
       monitor_to_call_pid: %{},
       window: nil,
       emitted: 0,
       dropped: 0
     }}
  end

  @impl GenServer
  def handle_call({:start_session, token, config}, _from, state) do
    with :ok <- authorize(token, state),
         :ok <- ensure_available(state),
         :ok <- ensure_idle(state),
         {:ok, validated} <- Config.validate(config),
         {:ok, session} <- create_session(validated, state) do
      started = %{
        state
        | session: session,
          config: validated,
          admission: admission(state, validated),
          calls: %{},
          call_monitors: %{},
          monitor_to_call_pid: %{},
          window: nil,
          emitted: 0,
          dropped: 0
      }

      {:reply, {:ok, session_description(validated)}, started}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:stop_session, token}, _from, state) do
    case authorize(token, state) do
      :ok -> {:reply, :ok, destroy_session(state)}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:session_status, token}, _from, state) do
    with :ok <- authorize(token, state),
         %{} = config <- state.config do
      {:reply, {:ok, Map.merge(session_description(config), counters(state))}, state}
    else
      nil -> {:reply, {:error, :no_trace_session}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl GenServer
  def handle_info(message, state)
      when is_tuple(message) and elem(message, 0) in [:trace, :trace_ts] do
    if state.session, do: {:noreply, observe(state, message)}, else: {:noreply, state}
  end

  def handle_info({:DOWN, reference, :process, pid, _reason}, state) do
    case Map.pop(state.monitor_to_call_pid, reference) do
      {^pid, monitor_to_call_pid} ->
        calls = Map.reject(state.calls, fn {{call_pid, _, _, _}, _started} -> call_pid == pid end)

        {:noreply,
         %{
           state
           | calls: calls,
             call_monitors: Map.delete(state.call_monitors, pid),
             monitor_to_call_pid: monitor_to_call_pid
         }}

      {nil, _unchanged} ->
        {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, state) do
    destroy_session(state)
    :ok
  end

  @impl GenServer
  def format_status(status) do
    status
    |> Map.put(:state, :redacted_trace_state)
    |> Map.put(:message, :redacted_trace_message)
    |> Map.put(:reason, :redacted_trace_reason)
    |> Map.put(:log, [])
  end

  # Concept: one observed trace message becomes at most one entry.
  #
  # Technical depth: a call is remembered per process and MFA so a later return
  # can carry its duration. The stack cannot grow without bound, because the
  # queue ceiling drops the traffic that would fill it.
  defp observe(state, {:trace_ts, pid, :call, {module, function, arguments}, caller, timestamp}) do
    call_arity = arity(arguments)

    state
    |> remember_call(pid, module, function, call_arity, timestamp)
    |> emit(
      Entry.call(%{
        module: module,
        function: function,
        arity: call_arity,
        caller: caller,
        pid: pid,
        monotonic_native: timestamp,
        arguments: rendered_arguments(state, arguments)
      })
    )
  end

  defp observe(state, {:trace_ts, pid, kind, {module, function, call_arity}, value, timestamp})
       when kind in [:return_from, :exception_from] do
    {started, state} = take_call(state, pid, module, function, call_arity)

    emit(
      state,
      Entry.call(%{
        module: module,
        function: function,
        arity: call_arity,
        caller: nil,
        pid: pid,
        monotonic_native: timestamp,
        class: class(kind),
        duration_native: duration(started, timestamp),
        return: rendered_return(state, value)
      })
    )
  end

  defp observe(state, _message), do: state

  defp class(:return_from), do: "return"
  defp class(:exception_from), do: "exception"

  defp arity(arguments) when is_list(arguments), do: length(arguments)
  defp arity(call_arity) when is_integer(call_arity), do: call_arity

  defp duration(nil, _timestamp), do: nil
  defp duration(started, timestamp), do: timestamp - started

  defp rendered_arguments(%{config: %{level: :arguments, limits: limits}}, arguments)
       when is_list(arguments),
       do: Entry.render(arguments, limits.entry_bytes)

  defp rendered_arguments(_state, _arguments), do: nil

  defp rendered_return(%{config: %{level: level, limits: limits}}, value)
       when level in [:returns, :arguments],
       do: Entry.render(value, limits.entry_bytes)

  defp rendered_return(_state, _value), do: nil

  defp remember_call(%{config: %{level: :calls}} = state, _pid, _module, _function, _arity, _at),
    do: state

  defp remember_call(state, pid, module, function, call_arity, timestamp) do
    key = {pid, module, function, call_arity}
    calls = Map.update(state.calls, key, [timestamp], &[timestamp | &1])

    case Map.fetch(state.call_monitors, pid) do
      {:ok, %{reference: reference, count: count}} ->
        call_monitors =
          Map.put(state.call_monitors, pid, %{reference: reference, count: count + 1})

        %{state | calls: calls, call_monitors: call_monitors}

      :error ->
        reference = Process.monitor(pid)

        %{
          state
          | calls: calls,
            call_monitors: Map.put(state.call_monitors, pid, %{reference: reference, count: 1}),
            monitor_to_call_pid: Map.put(state.monitor_to_call_pid, reference, pid)
        }
    end
  end

  defp take_call(state, pid, module, function, call_arity) do
    key = {pid, module, function, call_arity}

    case Map.get(state.calls, key, []) do
      [] ->
        {nil, state}

      [started] ->
        {started, drop_call_monitor(%{state | calls: Map.delete(state.calls, key)}, pid)}

      [started | rest] ->
        {started, drop_call_monitor(%{state | calls: Map.put(state.calls, key, rest)}, pid)}
    end
  end

  defp drop_call_monitor(state, pid) do
    case Map.fetch(state.call_monitors, pid) do
      {:ok, %{reference: reference, count: 1}} ->
        Process.demonitor(reference, [:flush])

        %{
          state
          | call_monitors: Map.delete(state.call_monitors, pid),
            monitor_to_call_pid: Map.delete(state.monitor_to_call_pid, reference)
        }

      {:ok, %{reference: reference, count: count}} ->
        %{
          state
          | call_monitors:
              Map.put(state.call_monitors, pid, %{reference: reference, count: count - 1})
        }

      :error ->
        state
    end
  end

  # Concept: the ceilings are applied here, before a sink can see anything.
  #
  # Technical depth: the queue check comes first, because an over-full mailbox
  # means this process is already behind and building an entry it will discard
  # costs exactly the work the ceiling exists to refuse. Every drop is counted,
  # and the count is reported as its own entry once the rate window turns over.
  defp emit(state, entry) do
    if queue_over_ceiling?(state) do
      %{state | dropped: state.dropped + 1}
    else
      rate_limited_emit(state, entry)
    end
  end

  defp rate_limited_emit(state, entry) do
    state = roll_window(state, System.monotonic_time(:second))

    if state.emitted >= state.config.limits.entries_per_second do
      %{state | dropped: state.dropped + 1}
    else
      send_entry(state, entry)
      %{state | emitted: state.emitted + 1}
    end
  end

  defp roll_window(%{window: second} = state, second), do: state

  defp roll_window(state, second) do
    reported =
      if state.dropped > 0 do
        send_entry(state, Entry.dropped(state.dropped, "trace_limit"))
        %{state | dropped: 0}
      else
        state
      end

    %{reported | window: second, emitted: 0}
  end

  defp queue_over_ceiling?(state) do
    case :erlang.process_info(self(), :message_queue_len) do
      {:message_queue_len, queued} -> queued > state.config.limits.queued
      _unavailable -> false
    end
  end

  defp send_entry(%{config: %{sink: :logger}}, entry) do
    Logger.debug(fn -> inspect(entry) end)
    :ok
  end

  defp send_entry(%{admission: nil}, _entry), do: :ok

  defp send_entry(%{admission: admission}, entry) do
    _admitted = DiagnosticsAdmission.admit(admission, entry)
    :ok
  end

  defp admission(_state, %{sink: :logger}), do: nil

  defp admission(state, _config) do
    with {:ok, %{dispatcher: dispatcher}} <- RuntimeSupervisor.children(state.root),
         {:ok, handle} <- GenServer.call(dispatcher, {:diagnostics_admission, state.token}) do
      handle
    else
      _unavailable -> nil
    end
  end

  defp authorize(token, %{token: token}), do: :ok
  defp authorize(_token, _state), do: {:error, :invalid_runtime_reference}

  defp ensure_available(state) do
    if available?(state.trace_module), do: :ok, else: {:error, :trace_sessions_unavailable}
  end

  defp ensure_idle(%{session: nil}), do: :ok
  defp ensure_idle(_state), do: {:error, :trace_session_already_running}

  defp session_description(config) do
    %{modules: config.modules, level: config.level, limits: config.limits, sink: config.sink}
  end

  defp counters(state), do: %{emitted: state.emitted, dropped: state.dropped}

  # Concept: the session observes named modules inside owned processes only.
  #
  # Technical depth: call patterns are installed per module, and trace flags per
  # owned process with `set_on_spawn`, so a session coordinator started later is
  # covered and a process outside this runtime's tree never is. A session that
  # cannot install its patterns is destroyed rather than left half-armed.
  defp create_session(config, state) do
    session = :trace.session_create(:loopex_trace, self(), [])

    try do
      Enum.each(modules(config), fn module ->
        :trace.function(session, {module, :_, :_}, match_spec(config.level), [:local])
      end)

      state.root
      |> runtime_processes()
      |> Enum.reject(&excluded?(&1, config, state))
      |> Enum.each(fn pid ->
        :trace.process(session, pid, true, process_flags(config.level, pid == state.root))
      end)

      {:ok, session}
    rescue
      error ->
        _destroyed = :trace.session_destroy(session)
        {:error, {:trace_session_refused, Exception.message(error)}}
    end
  end

  defp destroy_session(%{session: nil} = state), do: state

  defp destroy_session(state) do
    _destroyed = :trace.session_destroy(state.session)

    Enum.each(state.call_monitors, fn {_pid, %{reference: reference}} ->
      Process.demonitor(reference, [:flush])
    end)

    %{
      state
      | session: nil,
        config: nil,
        admission: nil,
        calls: %{},
        call_monitors: %{},
        monitor_to_call_pid: %{},
        window: nil,
        emitted: 0
    }
  end

  defp modules(config) do
    config.modules
    |> Enum.flat_map(fn
      namespace when namespace in [:loopex, :loopex_protocol] -> application_modules(namespace)
      module -> [module]
    end)
    |> Enum.uniq()
  end

  # Concept: a namespace wildcard means that application's own modules.
  #
  # Technical depth: reading the application's module list rather than matching
  # a name prefix keeps a module that merely starts with `Loopex` in some other
  # application out of the session.
  defp application_modules(application) do
    case :application.get_key(application, :modules) do
      {:ok, modules} -> modules
      :undefined -> []
    end
  end

  defp match_spec(:calls), do: [{:_, [], [{:message, {:caller}}]}]

  defp match_spec(level) when level in [:returns, :arguments],
    do: [{:_, [], [{:message, {:caller}}, {:exception_trace}]}]

  # Concept: children started later are traced; the runtime's own root is not a
  # place from which trace flags may spread.
  #
  # Technical depth: `set_on_spawn` on a session supervisor is what puts a
  # coordinator started after the session began under the same trace. On the
  # runtime root it would do something else entirely: the root is what restarts
  # this tracer, so a tracer replacing a crashed one would inherit the flags and
  # trace the code that builds its own entries. The root is therefore flagged
  # without propagation.
  defp process_flags(level, root?) do
    flags = if level == :arguments, do: [:call], else: [:call, :arity]
    flags = if root?, do: flags, else: [:set_on_spawn | flags]
    [:monotonic_timestamp | flags]
  end

  # Concept: a session never traces the process carrying its own entries.
  #
  # Technical depth: the tracer is excluded because tracing it would make every
  # entry produce the calls that build the next one. The dispatcher is excluded
  # for the same reason while the session's sink is the diagnostics plane it
  # owns: an entry admitted there is handled by dispatcher code, which would
  # emit further entries without end, bounded only by the rate ceiling. A host
  # that needs the dispatcher itself traced runs the session with the `logger`
  # sink, which leaves the plane out of the loop.
  defp excluded?(pid, config, state) do
    pid == self() or (config.sink == :diagnostics and pid == dispatcher(state))
  end

  defp dispatcher(state) do
    case RuntimeSupervisor.children(state.root) do
      {:ok, %{dispatcher: dispatcher}} -> dispatcher
      _unavailable -> nil
    end
  end

  defp runtime_processes(root), do: [root | supervised(root)]

  defp supervised(supervisor) do
    supervisor
    |> Supervisor.which_children()
    |> Enum.flat_map(fn
      {_id, pid, :supervisor, _modules} when is_pid(pid) -> [pid | supervised(pid)]
      {_id, pid, _type, _modules} when is_pid(pid) -> [pid]
      _other -> []
    end)
  catch
    :exit, _reason -> []
  end
end
