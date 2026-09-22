defmodule LoopexCli.LiveSignal do
  @moduledoc """
  ## Concept

  A live command is a window onto work the daemon owns, so a signal closes the
  window and never stops the work. `SIGTERM`, `SIGHUP` and `SIGQUIT` — and a
  terminal `Ctrl-C`, which the launcher forwards as `SIGTERM` — reach the live
  command as a request to detach.

  ## Technical depth

  `install/1` takes over the emulator's signal handling the same way the
  offline interrupt does: it replaces the default `:erl_signal_handler` in
  `:erl_signal_server`, whose own `SIGTERM` handling would stop the emulator
  before the command could release its lease. The handler only forwards
  `{:loopex_live_signal, signal}` to the installing process and never blocks
  the signal server. `uninstall/0` restores the default handler for a caller
  that continues running, such as a test VM. Direct `SIGINT` remains the
  emulator's reserved break behaviour.
  """

  @behaviour :gen_event

  require Logger

  @signals [:sigterm, :sighup, :sigquit]

  @doc false
  @spec install(pid()) :: :ok | {:error, term()}
  def install(terminal) when is_pid(terminal) do
    manager = :erl_signal_server

    result =
      if :erl_signal_handler in :gen_event.which_handlers(manager),
        do:
          :gen_event.swap_handler(
            manager,
            {:erl_signal_handler, :loopex_live_installed},
            {__MODULE__, %{terminal: terminal}}
          ),
        else: :gen_event.add_handler(manager, __MODULE__, %{terminal: terminal})

    case result do
      :ok ->
        Enum.each(@signals, &set_handled/1)
        Logger.debug("loopex live client signal handler installed")
        :ok

      error ->
        error
    end
  end

  @doc false
  @spec uninstall() :: :ok
  def uninstall do
    manager = :erl_signal_server
    _ = :gen_event.delete_handler(manager, __MODULE__, :uninstalled)

    unless :erl_signal_handler in :gen_event.which_handlers(manager),
      do: :gen_event.add_handler(manager, :erl_signal_handler, [])

    :ok
  end

  @doc false
  @spec signals() :: [atom()]
  def signals, do: @signals

  defp set_handled(signal) do
    :os.set_signal(signal, :handle)
  rescue
    _unsupported -> :ok
  end

  @impl :gen_event
  def init({state, _previous}) when is_map(state), do: {:ok, state}
  def init(state) when is_map(state), do: {:ok, state}

  @impl :gen_event
  def handle_event(signal, state) when signal in @signals do
    send(state.terminal, {:loopex_live_signal, signal})
    {:ok, state}
  end

  def handle_event({signal, _pid}, state) when signal in @signals,
    do: handle_event(signal, state)

  def handle_event(_other, state), do: {:ok, state}

  @impl :gen_event
  def handle_call(_request, state), do: {:ok, :ok, state}
end
