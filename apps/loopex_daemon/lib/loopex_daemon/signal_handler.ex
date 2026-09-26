defmodule LoopexDaemon.SignalHandler do
  @moduledoc """
  ## Concept

  A daemon turns `SIGTERM` into one ref-bound message to its lifecycle
  sentinel. The handler owns no daemon resource and performs no cleanup; the
  command process decides whether the signal stops startup or a running daemon.

  ## Technical depth

  The handler replaces OTP's default `:erl_signal_handler` in
  `:erl_signal_server`, configures only `:sigterm` for Erlang delivery, accepts
  both event shapes emitted by supported OTP versions, and ignores every other
  event without removing itself. A distinct handler identifier binds one
  installation to its `owner_ref`.
  """

  @behaviour :gen_event

  require Logger

  defmodule Handle do
    @moduledoc false
    @enforce_keys [:manager, :handler, :owner_ref]
    defstruct [:manager, :handler, :owner_ref]

    @type t :: %__MODULE__{
            manager: pid(),
            handler: {module(), reference()},
            owner_ref: reference()
          }
  end

  @doc """
  ## Concept

  Installs the daemon's one handled operating-system signal route.

  ## Technical depth

  Installation is complete only when the handler is present in the current
  signal manager, `SIGTERM` is configured for Erlang delivery and every OTP
  default handler has been removed. Any failure is normalized before startup
  acquires a placement lock or Store marker.
  """
  @spec install(pid(), reference()) :: {:ok, Handle.t()} | {:error, :signal_install_failed}
  def install(sentinel, owner_ref) when is_pid(sentinel) and is_reference(owner_ref) do
    case Process.whereis(:erl_signal_server) do
      manager when is_pid(manager) -> install_on(manager, sentinel, owner_ref, &:os.set_signal/2)
      nil -> {:error, :signal_install_failed}
    end
  end

  @doc false
  @spec install_on(pid(), pid(), reference(), (atom(), atom() -> term())) ::
          {:ok, Handle.t()} | {:error, :signal_install_failed}
  def install_on(manager, sentinel, owner_ref, set_signal)
      when is_pid(manager) and is_pid(sentinel) and is_reference(owner_ref) and
             is_function(set_signal, 2) do
    handler = {__MODULE__, owner_ref}
    state = %{sentinel: sentinel, owner_ref: owner_ref}

    with {:ok, handlers} <- handlers(manager),
         :ok <- ensure_absent(handlers),
         {:ok, install_mode} <- add_or_swap(manager, handlers, handler, state) do
      finish_install(manager, handler, owner_ref, install_mode, set_signal)
    else
      _failure -> {:error, :signal_install_failed}
    end
  rescue
    _failure -> {:error, :signal_install_failed}
  catch
    :exit, _manager_lost -> {:error, :signal_install_failed}
  end

  @doc false
  @spec uninstall(Handle.t()) :: :ok
  def uninstall(%Handle{manager: manager, handler: handler}) do
    _ = delete_exact(manager, handler)
    Logger.debug("loopex daemon signal handler removed")
    :ok
  end

  @impl :gen_event
  def init({state, _previous}) when is_map(state), do: init(state)

  def init(%{sentinel: sentinel, owner_ref: owner_ref} = state)
      when is_pid(sentinel) and is_reference(owner_ref),
      do: {:ok, state}

  @impl :gen_event
  def handle_event(:sigterm, state) do
    send(state.sentinel, {:daemon_signal, state.owner_ref, :sigterm})
    {:ok, state}
  end

  def handle_event({:sigterm, _pid}, state), do: handle_event(:sigterm, state)
  def handle_event(_event, state), do: {:ok, state}

  @impl :gen_event
  def handle_call(_request, state), do: {:ok, :ok, state}

  @impl :gen_event
  def handle_info(_message, state), do: {:ok, state}

  @impl :gen_event
  def terminate(_reason, _state), do: :ok

  @impl :gen_event
  def code_change(_old_version, state, _extra), do: {:ok, state}

  @impl :gen_event
  def format_status(_reason, _data),
    do: [data: [{~c"State", %{installed: true, signal: :sigterm}}]]

  defp handlers(manager) do
    try do
      {:ok, :gen_event.which_handlers(manager)}
    catch
      :exit, _manager_lost -> {:error, :signal_install_failed}
    end
  end

  defp ensure_absent(handlers) do
    if Enum.any?(handlers, fn
         {__MODULE__, _owner_ref} -> true
         __MODULE__ -> true
         _other -> false
       end),
       do: {:error, :signal_install_failed},
       else: :ok
  end

  defp add_or_swap(manager, handlers, handler, state) do
    if :erl_signal_handler in handlers do
      case :gen_event.swap_handler(
             manager,
             {:erl_signal_handler, :loopex_daemon_handler_installed},
             {handler, state}
           ) do
        :ok -> {:ok, :swapped}
        _failure -> {:error, :signal_install_failed}
      end
    else
      case :gen_event.add_handler(manager, handler, state) do
        :ok -> {:ok, :added}
        _failure -> {:error, :signal_install_failed}
      end
    end
  end

  defp finish_install(manager, handler, owner_ref, install_mode, set_signal) do
    result =
      try do
        with :ok <- configure_signal(set_signal),
             :ok <- remove_default_handlers(manager),
             {:ok, installed} <- handlers(manager),
             true <- handler in installed and :erl_signal_handler not in installed do
          :ok
        else
          _failure -> {:error, :signal_install_failed}
        end
      rescue
        _failure -> {:error, :signal_install_failed}
      catch
        :exit, _manager_lost -> {:error, :signal_install_failed}
      end

    case result do
      :ok ->
        Logger.debug("loopex daemon signal handler installed")
        {:ok, %Handle{manager: manager, handler: handler, owner_ref: owner_ref}}

      {:error, :signal_install_failed} ->
        cleanup_failed_install(manager, handler, install_mode)
        {:error, :signal_install_failed}
    end
  end

  defp cleanup_failed_install(manager, handler, install_mode) do
    _ = delete_exact(manager, handler)

    if install_mode == :swapped do
      case handlers(manager) do
        {:ok, current} ->
          if :erl_signal_handler not in current,
            do: :gen_event.add_handler(manager, :erl_signal_handler, []),
            else: :ok

        _present_or_lost ->
          :ok
      end
    end
  end

  defp configure_signal(set_signal) do
    case set_signal.(:sigterm, :handle) do
      :ok -> :ok
      _failure -> {:error, :signal_install_failed}
    end
  end

  defp remove_default_handlers(manager) do
    case :gen_event.delete_handler(manager, :erl_signal_handler, []) do
      :ok -> remove_default_handlers(manager)
      {:error, :module_not_found} -> :ok
      _failure -> {:error, :signal_install_failed}
    end
  end

  defp delete_exact(manager, handler) do
    case :gen_event.delete_handler(manager, handler, []) do
      :ok -> :ok
      {:error, :module_not_found} -> :ok
      _failure -> :ok
    end
  catch
    :exit, _manager_lost -> :ok
  end
end
