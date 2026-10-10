defmodule LoopexCli.M7LockPorts do
  @moduledoc false

  # Concept: every attempts index a test creates gets a lock port no other live
  # test index on this host names. ADR 0065's lock is a port, not the index, so
  # an index created while another index's writer is closed can draw that
  # index's port; the two then refuse each other as contention, which is the
  # product's safe behaviour but makes an unrelated test fail.
  #
  # Technical depth: a claim is a UDP socket on 127.0.0.1 at the port, owned by
  # one process that lives as long as the VM. UDP and TCP ports are separate
  # namespaces, so the claim never contends with the writer's TCP listener, and
  # the kernel grants each UDP port once across every VM on the host and frees
  # it when the VM exits. A port is never claimed twice in a VM, so a writer a
  # finished test leaves behind cannot hold a later test's port. The search
  # skips ports whose TCP side is held by anything else.

  @ports 20_000..32_767
  @loopback {127, 0, 0, 1}

  def claim do
    holder =
      case Agent.start(fn -> [] end, name: __MODULE__) do
        {:ok, pid} -> pid
        {:error, {:already_started, pid}} -> pid
      end

    Agent.get_and_update(holder, &search(Enum.shuffle(@ports), &1), :infinity)
  end

  defp search([port | ports], claims) do
    case :gen_udp.open(port, ip: @loopback) do
      {:ok, claim} ->
        case :gen_tcp.listen(port, ip: @loopback, reuseaddr: false) do
          {:ok, probe} ->
            :ok = :gen_tcp.close(probe)
            {port, [claim | claims]}

          # Held over TCP by something that claims nothing: keep the claim so
          # this VM never draws the port again.
          {:error, _} ->
            search(ports, [claim | claims])
        end

      {:error, _} ->
        search(ports, claims)
    end
  end
end
