defmodule LoopexCli.Test.HeldOutputTarget do
  @moduledoc false

  # Concept: a custom output target whose every acknowledgement the test decides.
  # Technical depth: it speaks the owned-target protocol exactly. Acquisition,
  # each write and retirement are reported to the creating test and answered
  # only on its instruction, so delayed, lost, wrong-nonce, foreign and held
  # acknowledgements are actual messages from the original target process.

  def start(options \\ []) do
    parent = self()
    pid = spawn(fn -> init(parent, options) end)
    monitor = Process.monitor(pid)
    %{pid: pid, monitor: monitor, target: {:owned, pid}}
  end

  def release(%{pid: pid}, reply), do: send(pid, {:held_target_release, reply})

  def stop(%{pid: pid, monitor: monitor}) do
    Process.exit(pid, :kill)

    receive do
      {:DOWN, ^monitor, :process, ^pid, _} -> :ok
    after
      5_000 -> raise "the held target did not stop"
    end
  end

  defp init(parent, options) do
    loop(%{
      parent: parent,
      acquire: Keyword.get(options, :acquire, :ack),
      retire: Keyword.get(options, :retire, :ack),
      owner: nil,
      incarnation: nil
    })
  end

  defp loop(state) do
    receive do
      {:loopex_cli_output_target, :acquire, owner, id} ->
        send(state.parent, {:held_target_acquire, owner, id})

        case state.acquire do
          :ack ->
            incarnation = make_ref()
            Process.monitor(owner)
            send(owner, {:loopex_cli_output_target, :acquired, self(), id, incarnation})
            loop(%{state | owner: owner, incarnation: incarnation})

          {:delay, ms} ->
            Process.sleep(ms)
            incarnation = make_ref()
            send(owner, {:loopex_cli_output_target, :acquired, self(), id, incarnation})
            loop(%{state | owner: owner, incarnation: incarnation})

          :refuse ->
            send(owner, {:loopex_cli_output_target, :refused, self(), id})
            loop(state)

          :silent ->
            loop(state)
        end

      {:loopex_cli_output_target, :write, owner, incarnation, nonce, destination, bytes} ->
        send(state.parent, {:held_target_write, destination, bytes})

        receive do
          {:held_target_release, :ok} ->
            send(owner, {:loopex_cli_output_target, :written, self(), incarnation, nonce})

          {:held_target_release, :wrong_nonce} ->
            send(owner, {:loopex_cli_output_target, :written, self(), incarnation, make_ref()})

          {:held_target_release, :duplicate} ->
            send(owner, {:loopex_cli_output_target, :written, self(), incarnation, nonce})
            send(owner, {:loopex_cli_output_target, :written, self(), incarnation, nonce})

          {:held_target_release, :lost} ->
            :ok

          {:loopex_cli_output_target, :retire, ^owner, ^incarnation, retire_nonce} ->
            # The held request is discarded before retirement is acknowledged.
            send(state.parent, {:held_target_retire, :holding})
            retire(state, owner, incarnation, retire_nonce)
        end

        loop(state)

      {:loopex_cli_output_target, :retire, owner, incarnation, nonce} ->
        send(state.parent, {:held_target_retire, :idle})
        retire(state, owner, incarnation, nonce)
        loop(state)

      {:DOWN, _monitor, :process, owner, _reason} when owner == state.owner ->
        send(state.parent, {:held_target_owner_down, owner})
        loop(state)
    end
  end

  defp retire(state, owner, incarnation, nonce) do
    case state.retire do
      :ack -> send(owner, {:loopex_cli_output_target, :retired, self(), incarnation, nonce})
      :silent -> :ok
    end
  end
end
