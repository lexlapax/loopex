defmodule Loopex.LLM.ReqLLM.Application do
  @moduledoc false

  use Application

  @impl Application
  def start(_type, _arguments) do
    application_group_leader = Process.group_leader()
    children = [Loopex.LLM.ReqLLM.ProviderIOSink, Loopex.LLM.ReqLLM.CredentialFilter]

    case Supervisor.start_link(children, strategy: :one_for_all, name: __MODULE__.Supervisor) do
      {:ok, supervisor} -> {:ok, supervisor, %{group_leader: application_group_leader}}
      {:error, _reason} = error -> error
    end
  end

  @impl Application
  def prep_stop(%{group_leader: group_leader} = state) do
    _ = Loopex.LLM.ReqLLM.CredentialFilter.restore_provider_io(group_leader)
    state
  end
end
