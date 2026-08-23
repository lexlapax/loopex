defmodule Loopex.Runtime.Supervisor do
  @moduledoc """
  ## Concept

  The unnamed root of one explicit runtime instance. Runtime control, session
  processes, and attachment delivery share one supervised lifetime without
  becoming VM-global services.

  ## Technical depth

  Children use stable supervisor-local IDs and are resolved through the root
  pid retained by `Loopex.Runtime`. `:rest_for_one` orders authority before
  owned work and delivery: a control failure removes every later child, a
  session-supervisor failure removes delivery state, and a dispatcher failure
  leaves current session coordinators alive so public events can be re-read
  from the durable outbox.
  """

  use Supervisor

  alias Loopex.Runtime.Control
  alias Loopex.Runtime.EventDispatcher

  @control_id Loopex.Runtime.Control
  @workers_id Loopex.Runtime.Workers
  @sessions_id Loopex.Runtime.SessionSupervisor
  @dispatcher_id Loopex.Runtime.EventDispatcher

  @doc """
  ## Concept

  Starts one unregistered runtime supervisor.

  ## Technical depth

  The caller supplies already validated configuration and the runtime-local
  token. No child receives or creates a global name.
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(options) when is_list(options), do: Supervisor.start_link(__MODULE__, options)

  @impl Supervisor
  def init(options) do
    root = self()

    children = [
      %{
        id: @control_id,
        start: {Control, :start_link, [[root: root] ++ options]}
      },
      Supervisor.child_spec({Task.Supervisor, []}, id: @workers_id),
      Supervisor.child_spec(
        {DynamicSupervisor, strategy: :one_for_one},
        id: @sessions_id
      ),
      %{
        id: @dispatcher_id,
        start: {EventDispatcher, :start_link, [[root: root] ++ options]}
      }
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  @doc false
  @spec children(pid()) :: {:ok, map()} | {:error, :runtime_unavailable}
  def children(root) when is_pid(root) do
    try do
      resolved =
        Map.new(Supervisor.which_children(root), fn {id, pid, _type, _modules} -> {id, pid} end)

      with control when is_pid(control) <- Map.get(resolved, @control_id),
           workers when is_pid(workers) <- Map.get(resolved, @workers_id),
           sessions when is_pid(sessions) <- Map.get(resolved, @sessions_id),
           dispatcher when is_pid(dispatcher) <- Map.get(resolved, @dispatcher_id) do
        {:ok, %{control: control, workers: workers, sessions: sessions, dispatcher: dispatcher}}
      else
        _other -> {:error, :runtime_unavailable}
      end
    catch
      :exit, _reason -> {:error, :runtime_unavailable}
    end
  end

  def children(_root), do: {:error, :runtime_unavailable}
end
