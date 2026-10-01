defmodule Loopex.Runtime.OwnerGroups do
  @moduledoc """
  ## Concept

  The runtime-local parent of session owner groups. Control waits for a group's
  termination before allowing a successor to dispatch model or policy work.

  ## Technical depth

  Uses the Erlang supervisor's simple_one_for_one strategy with temporary,
  pid-addressed children and parallel shutdown. Its shutdown path recovers the
  linked EXIT reason when a late monitor reports noproc for a normally exiting
  group; Elixir's DynamicSupervisor can unlink before consuming that reason.
  Groups retain infinite shutdown because their private worker subtrees must
  terminate before the owner barrier completes. No process is globally named.
  """

  use Supervisor

  alias Loopex.Runtime.OwnerGroup

  @doc false
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(options) when is_list(options), do: Supervisor.start_link(__MODULE__, options)

  @impl Supervisor
  def init(_options) do
    {:ok,
     {%{strategy: :simple_one_for_one, intensity: 3, period: 5},
      [
        %{
          id: OwnerGroup,
          start: {OwnerGroup, :start_link, []},
          restart: :temporary,
          shutdown: :infinity,
          type: :worker
        }
      ]}}
  end
end
