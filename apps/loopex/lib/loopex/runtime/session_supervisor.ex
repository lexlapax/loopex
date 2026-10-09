defmodule Loopex.Runtime.SessionSupervisor do
  @moduledoc """
  ## Concept

  The runtime-local parent of session coordinators. A coordinator that ends on
  its own while the runtime stops is an ordinary temporary exit, not a shutdown
  failure.

  ## Technical depth

  Uses the Erlang supervisor's simple_one_for_one strategy with temporary,
  pid-addressed coordinators and the coordinator's 5,000 ms shutdown. Erlang's
  shutdown path monitors before signalling and recovers the linked `EXIT`
  reason when a late monitor reports `noproc`. Elixir's DynamicSupervisor
  unlinks before consuming that reason, so a superseded coordinator exiting
  normally during root shutdown was reported as `shutdown_error` `noproc`, and
  one whose `shutdown` exit was already queued was reported as a shutdown
  failure. No process is globally named.
  """

  use Supervisor

  alias Loopex.Runtime.SessionCoordinator

  @doc false
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(options) when is_list(options), do: Supervisor.start_link(__MODULE__, options)

  @doc false
  @spec start_coordinator(pid(), keyword()) :: Supervisor.on_start_child()
  def start_coordinator(supervisor, options), do: :supervisor.start_child(supervisor, [options])

  @doc false
  @spec terminate_coordinator(pid(), pid()) :: :ok | {:error, :not_found}
  def terminate_coordinator(supervisor, coordinator),
    do: :supervisor.terminate_child(supervisor, coordinator)

  @impl Supervisor
  def init(_options) do
    {:ok,
     {%{strategy: :simple_one_for_one, intensity: 3, period: 5},
      [
        %{
          id: SessionCoordinator,
          start: {SessionCoordinator, :start_link, []},
          restart: :temporary,
          shutdown: 5_000,
          type: :worker
        }
      ]}}
  end
end
