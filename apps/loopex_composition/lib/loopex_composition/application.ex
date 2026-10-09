defmodule LoopexComposition.Application do
  @moduledoc """
  ## Concept

  Owns shared composition infrastructure. Session owners and guarded provider
  startup are independent siblings, so starter loss does not stop sessions.

  ## Technical depth

  The named one-for-one supervisor never automatically shuts down. ReqLLMStarter
  is temporary and nonsignificant. The owner DynamicSupervisor accepts each
  session's temporary child specification. This callback starts no provider
  dependency and creates no session or runtime.
  """

  use Application

  @doc false
  @impl true
  def start(_type, _args) do
    children = [
      {LoopexComposition.ReqLLMStarter, []},
      {Registry, keys: :unique, name: LoopexComposition.Delegation.Registry},
      {DynamicSupervisor,
       strategy: :one_for_one, name: LoopexComposition.Ephemeral.OwnerSupervisor}
    ]

    Supervisor.start_link(children,
      strategy: :one_for_one,
      auto_shutdown: :never,
      name: LoopexComposition.Supervisor
    )
  end
end
