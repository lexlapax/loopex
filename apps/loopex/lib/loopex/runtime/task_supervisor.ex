defmodule Loopex.Runtime.TaskSupervisor do
  @moduledoc """
  ## Concept

  The runtime's parent for owner, creation and runtime-wide tasks. A task that
  ends on its own while its supervisor stops is an ordinary temporary exit,
  not a shutdown failure; a task that had to be killed is still reported.

  ## Technical depth

  An Erlang `one_for_one` supervisor whose temporary children carry their own
  shutdown (default 5,000 ms, or `:brutal_kill`) under a fresh reference ID.
  Erlang's shutdown path monitors before signalling and recovers a queued or
  late `EXIT` reason, so `:normal`, `:shutdown` and `{:shutdown, _}` exits stay
  silent. Elixir's `Task.Supervisor` is a DynamicSupervisor: it unlinked before
  consuming a racing `EXIT` (reported as `noproc`) and reported any already
  queued temporary exit other than `:normal` as `shutdown_error`.

  `async_nolink/2` returns an ordinary `%Task{}` owned by the caller: the
  caller monitors the child and hands it the monitor reference, and the child
  replies `{ref, result}`. A child whose owner is gone before that handoff exits
  `{:shutdown, reason}`. Children inherit `$callers` like Elixir tasks.
  """

  use Supervisor

  @id_key :"$loopex_task_id"

  @doc false
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(options \\ []) when is_list(options),
    do: Supervisor.start_link(__MODULE__, [], Keyword.take(options, [:name]))

  @doc false
  @spec start_child(pid(), (-> term()), keyword()) :: DynamicSupervisor.on_start_child()
  def start_child(supervisor, fun, options \\ []) when is_function(fun, 0) do
    start(supervisor, {:run, callers(), fun}, Keyword.get(options, :shutdown, 5_000))
  end

  @doc false
  @spec async_nolink(pid(), (-> term())) :: Task.t()
  def async_nolink(supervisor, fun) when is_function(fun, 0) do
    owner = self()
    {:ok, pid} = start(supervisor, {:reply, owner, callers(), fun}, 5_000)
    ref = Process.monitor(pid)
    send(pid, {__MODULE__, owner, ref})
    %Task{mfa: {:erlang, :apply, 2}, owner: owner, pid: pid, ref: ref}
  end

  @doc false
  @spec terminate_child(pid(), pid()) :: :ok | {:error, :not_found}
  def terminate_child(supervisor, pid) when is_pid(pid) do
    case child_id(pid) do
      nil -> {:error, :not_found}
      id -> :supervisor.terminate_child(supervisor, id)
    end
  end

  # Concept: a task is stopped by one request naming it, as with a pid-addressed child.
  # Technical depth: Erlang's one_for_one supervisor terminates by child ID. The
  # ID is stored in the child before its start acknowledgement, so it is readable
  # from the moment `start_child` returns; a gone child yields `nil`.
  @doc false
  @spec child_id(pid()) :: reference() | nil
  def child_id(pid) when is_pid(pid) do
    case Process.info(pid, {:dictionary, @id_key}) do
      {{:dictionary, @id_key}, id} when is_reference(id) -> id
      _gone_or_foreign -> nil
    end
  end

  @doc false
  @spec children(pid()) :: [pid()]
  def children(supervisor) do
    for {_id, pid, _type, _modules} <- :supervisor.which_children(supervisor),
        is_pid(pid),
        do: pid
  end

  @doc false
  def start_task(id, work), do: :proc_lib.start_link(__MODULE__, :init_task, [id, work])

  @doc false
  def init_task(id, work) do
    Process.put(@id_key, id)
    :proc_lib.init_ack({:ok, self()})
    run(work)
  end

  @doc false
  def run({:run, callers, fun}) do
    Process.put(:"$callers", callers)
    fun.()
  end

  def run({:reply, owner, callers, fun}) do
    Process.put(:"$callers", callers)
    owner_monitor = Process.monitor(owner)

    receive do
      {__MODULE__, ^owner, ref} ->
        Process.demonitor(owner_monitor, [:flush])
        send(owner, {ref, fun.()})

      {:DOWN, ^owner_monitor, :process, ^owner, reason} ->
        exit({:shutdown, reason})
    end
  end

  @impl Supervisor
  def init(_options), do: {:ok, {%{strategy: :one_for_one, intensity: 3, period: 5}, []}}

  defp start(supervisor, work, shutdown),
    do: :supervisor.start_child(supervisor, spec(work, shutdown))

  # Concept: callers that must bound their own start request send this exact spec.
  # Technical depth: it is the `start_child/3` request body for `fun`, for use
  # with an asynchronous `{:start_child, spec}` supervisor call.
  @doc false
  @spec task_spec((-> term()), timeout() | :brutal_kill) :: Supervisor.child_spec()
  def task_spec(fun, shutdown) when is_function(fun, 0),
    do: spec({:run, callers(), fun}, shutdown)

  defp spec(work, shutdown) do
    id = make_ref()

    %{
      id: id,
      start: {__MODULE__, :start_task, [id, work]},
      restart: :temporary,
      shutdown: shutdown,
      type: :worker
    }
  end

  defp callers, do: [self() | Process.get(:"$callers", [])]
end
