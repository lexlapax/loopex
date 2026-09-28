defmodule Loopex.LLM.ReqLLM.InProcess.TestRegisterRendezvous do
  @moduledoc false

  @table :loopex_provider_register_rendezvous
  @fixture_timeout_ms 5_000

  def open! do
    @table = :ets.new(@table, [:named_table, :public, :set])
    :ok
  end

  def arm!(cell, fixture_pid, nonce) do
    true = :ets.insert_new(@table, {cell, fixture_pid, nonce})
    :ok
  end

  def await!(cell, call_ref, candidate_pid) do
    if :ets.whereis(@table) == :undefined do
      :ok
    else
      case :ets.take(@table, cell) do
        [] ->
          :ok

        [{^cell, fixture_pid, nonce}] ->
          monitor = Process.monitor(fixture_pid)
          send(fixture_pid, {:before_provider_register, nonce, self(), call_ref, candidate_pid})

          try do
            receive do
              {:continue_provider_register, ^nonce} ->
                :ok

              {:DOWN, ^monitor, :process, ^fixture_pid, _reason} ->
                raise "provider registration rendezvous fixture exited"
            after
              @fixture_timeout_ms -> raise "provider registration rendezvous timed out"
            end
          after
            Process.demonitor(monitor, [:flush])
          end
      end
    end
  end

  def close! do
    if :ets.whereis(@table) != :undefined, do: :ets.delete(@table)
    :ok
  end
end
