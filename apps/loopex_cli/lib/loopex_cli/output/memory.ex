defmodule LoopexCli.Output.Memory do
  @moduledoc """
  ## Concept

  An owned in-memory output target for trusted host code, such as a test or an
  embedding host that wants a command's exact bytes. Its creator hands it to
  exactly one command output owner and reads what was written after that owner
  has finished with it.

  ## Technical depth

  Accepted ADR 0068 admits a custom target only through explicit exclusive
  acquisition. This target is one process with no downstream copy holder: a
  write is complete when its bytes are appended here, and that same process
  answers with the exact incarnation and write nonce. It acknowledges one
  acquisition only, monitors the acquiring owner and retires itself when that
  owner ends, so a later write from any process is refused. The trusted host
  that created it reads the retained bytes. It is not model configuration or a
  Core callback.
  """

  use GenServer

  @doc """
  ## Concept

  Create a target owned by the calling host process.

  ## Technical depth

  The process is unlinked; its creator reads with `contents/1` and stops it
  with `stop/1`.
  """
  @spec start() :: {:ok, pid()}
  def start, do: GenServer.start(__MODULE__, :target)

  @doc false
  @spec target(pid()) :: {:owned, pid()}
  def target(pid) when is_pid(pid), do: {:owned, pid}

  @doc """
  ## Concept

  Return the bytes written to standard output and standard error.

  ## Technical depth

  The answer is a snapshot; it never waits for the owner to finish.
  """
  @spec contents(pid()) :: {binary(), binary()}
  def contents(pid), do: GenServer.call(pid, :contents)

  @doc false
  @spec status(pid()) :: :available | :acquired | :retired
  def status(pid), do: GenServer.call(pid, :status)

  @doc false
  def stop(pid), do: GenServer.stop(pid)

  @impl true
  def init(:target) do
    {:ok,
     %{
       owner: nil,
       owner_monitor: nil,
       incarnation: nil,
       phase: :available,
       stdout: [],
       stderr: []
     }}
  end

  @impl true
  def handle_call(:contents, _from, state),
    do: {:reply, {IO.iodata_to_binary(state.stdout), IO.iodata_to_binary(state.stderr)}, state}

  def handle_call(:status, _from, state), do: {:reply, state.phase, state}

  @impl true
  def handle_info({:loopex_cli_output_target, :acquire, owner, id}, %{phase: :available} = state)
      when is_pid(owner) do
    incarnation = make_ref()
    send(owner, {:loopex_cli_output_target, :acquired, self(), id, incarnation})

    {:noreply,
     %{
       state
       | owner: owner,
         owner_monitor: Process.monitor(owner),
         incarnation: incarnation,
         phase: :acquired
     }}
  end

  def handle_info({:loopex_cli_output_target, :acquire, owner, id}, state) when is_pid(owner) do
    send(owner, {:loopex_cli_output_target, :refused, self(), id})
    {:noreply, state}
  end

  def handle_info(
        {:loopex_cli_output_target, :write, owner, incarnation, nonce, destination, bytes},
        %{owner: owner, incarnation: incarnation, phase: :acquired} = state
      )
      when destination in [:stdout, :stderr] and is_binary(bytes) do
    state = Map.update!(state, destination, &[&1, bytes])
    send(owner, {:loopex_cli_output_target, :written, self(), incarnation, nonce})
    {:noreply, state}
  end

  def handle_info(
        {:loopex_cli_output_target, :retire, owner, incarnation, nonce},
        %{owner: owner, incarnation: incarnation} = state
      ) do
    send(owner, {:loopex_cli_output_target, :retired, self(), incarnation, nonce})
    {:noreply, retired(state)}
  end

  def handle_info({:DOWN, monitor, :process, _owner, _reason}, %{owner_monitor: monitor} = state),
    do: {:noreply, retired(state)}

  def handle_info(_message, state), do: {:noreply, state}

  defp retired(state) do
    if state.owner_monitor, do: Process.demonitor(state.owner_monitor, [:flush])
    %{state | phase: :retired, owner_monitor: nil}
  end
end
