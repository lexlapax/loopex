defmodule Loopex.Runtime.DiagnosticsAdmission do
  @moduledoc """
  ## Concept

  Bounded admission for the diagnostics plane. A trace tracer or a telemetry
  handler hands an item to the runtime's dispatcher without waiting for it and
  without being able to grow the dispatcher's mailbox past a fixed ceiling.
  When the backlog is full the sender drops its own item and counts the drop,
  so a busy or blocked sink slows nothing that produced the item.

  ## Technical depth

  The bound is a slot reservation, not a counter pair. The runtime owns one
  `:atomics` array of two cells, a monotonic ticket counter and a drop count,
  and one public ETS `set` of slot rows `{slot, owner_pid, ticket}`. A sender
  takes a ticket, derives `rem(ticket, ceiling)`, and claims that slot with one
  `:ets.insert_new/2`. That single atomic insert is the whole reservation: it
  records the sender as the slot's owner or fails because the slot is still
  held. Only `ceiling` slot keys exist, so at most `ceiling` items are claimed
  at any instant however many senders race, and the dispatcher's mailbox holds
  no more than that.

  No step is ever rolled back, so a sender killed between any two steps leaves
  nothing its `DOWN` cannot account for. Erlang delivers every message a
  process sent before its `DOWN`, so when the dispatcher reconciles a dead
  sender the slots still owned by that pid are exactly its claims never sent
  for. A release names the exact `{slot, pid, ticket}` triple the message
  carried, so it can never free a slot a later claim now holds.

  Dropped diagnostics are lost. Nothing in the journal, public events or
  progress depends on their delivery.
  """

  @ceiling 4_096

  @type t :: %{
          slots: :ets.table(),
          counters: :atomics.atomics_ref(),
          ceiling: pos_integer(),
          dispatcher: pid()
        }

  @doc """
  ## Concept

  Creates the admission state for one runtime, owned by the calling dispatcher.

  ## Technical depth

  The ETS table is public because every sender claims its own slot, and it is
  owned by the dispatcher so the reservation state dies with the plane it
  bounds. A host may lower the ceiling and never raise it.
  """
  @spec new(pos_integer()) :: t()
  def new(ceiling \\ @ceiling) when is_integer(ceiling) and ceiling > 0 do
    %{
      slots:
        :ets.new(:loopex_diagnostics_slots, [
          :set,
          :public,
          {:write_concurrency, true},
          {:read_concurrency, true}
        ]),
      counters: :atomics.new(2, signed: true),
      ceiling: min(ceiling, @ceiling),
      dispatcher: self()
    }
  end

  @doc """
  ## Concept

  The ceiling this contract admits by default.

  ## Technical depth

  Exposed as a function so a host, a test and the dispatcher all read one
  value. It is fixed at compile time: the bound on the diagnostics backlog does
  not depend on how many senders exist or how fast they run.
  """
  @spec default_ceiling() :: pos_integer()
  def default_ceiling, do: @ceiling

  @doc """
  ## Concept

  Admits one item from the calling sender, or drops it and says so.

  ## Technical depth

  The sender registers itself for monitoring once per dispatcher, takes a
  ticket, claims its slot and sends immediately after the claim succeeds. A
  failed claim counts one drop and sends nothing. A handle whose table is gone
  because the dispatcher restarted reports `:unavailable`; there is no counter
  left to count into, and the sender's next handle comes from the live runtime.
  """
  @spec admit(t(), term()) :: :ok | :dropped | :unavailable
  def admit(handle, item) do
    register(handle)
    ticket = take_ticket(handle)

    case claim(handle, ticket) do
      {:ok, slot} ->
        deliver(handle, slot, ticket, item)
        :ok

      :taken ->
        count_drop(handle)
        :dropped
    end
  rescue
    ArgumentError -> :unavailable
  end

  @doc """
  ## Concept

  Registers this sender for monitoring by the dispatcher, once.

  ## Technical depth

  Registration is idempotent per dispatcher, so a sender may call it on every
  admission without accumulating monitors. The monitor is what lets the
  dispatcher release a killed sender's claimed-but-unsent slots at its `DOWN`.
  """
  @spec register(t()) :: :ok
  def register(%{dispatcher: dispatcher}), do: ensure_monitor(dispatcher)

  @doc """
  ## Concept

  Takes the next ticket. A ticket alone reserves nothing.

  ## Technical depth

  `:atomics.add_get/3` is one atomic step, so two senders never hold the same
  ticket and a sender killed here holds nothing at all.
  """
  @spec take_ticket(t()) :: integer()
  def take_ticket(%{counters: counters}), do: :atomics.add_get(counters, 1, 1)

  @doc """
  ## Concept

  Claims the slot a ticket maps to, or reports that it is still held.

  ## Technical depth

  The claim is one `:ets.insert_new/2` recording this process and its ticket as
  the slot's owner. There is nothing to roll back: it either records the owner
  or changes nothing, so a sender killed immediately afterwards holds exactly
  the slot its `DOWN` releases.
  """
  @spec claim(t(), integer()) :: {:ok, non_neg_integer()} | :taken
  def claim(%{slots: slots, ceiling: ceiling}, ticket) do
    slot = rem(ticket, ceiling)
    if :ets.insert_new(slots, {slot, self(), ticket}), do: {:ok, slot}, else: :taken
  end

  @doc """
  ## Concept

  Sends the claimed item to the dispatcher.

  ## Technical depth

  Only a sender holding the slot sends, and it sends immediately after the
  claim, so the dispatcher's backlog never exceeds the number of slots.
  """
  @spec deliver(t(), non_neg_integer(), integer(), term()) :: :ok
  def deliver(%{dispatcher: dispatcher}, slot, ticket, item) do
    send(dispatcher, {:loopex_diagnostic_admission, self(), slot, ticket, item})
    :ok
  end

  @doc """
  ## Concept

  Frees the slot an admitted item held.

  ## Technical depth

  Deleting the exact triple the message carried is what makes a late release
  safe: if the slot has since been claimed again, the stored row differs and
  nothing is removed.
  """
  @spec release(t(), non_neg_integer(), pid(), integer()) :: :ok
  def release(%{slots: slots}, slot, pid, ticket) do
    :ets.delete_object(slots, {slot, pid, ticket})
    :ok
  end

  @doc """
  ## Concept

  Releases every slot a dead sender claimed and never sent for.

  ## Technical depth

  Called only on that sender's `DOWN`, after which no further message from it
  can arrive, so a live sender's slot is never touched.
  """
  @spec reconcile(t(), pid()) :: :ok
  def reconcile(%{slots: slots}, pid) when is_pid(pid) do
    :ets.match_delete(slots, {:_, pid, :_})
    :ok
  end

  @doc """
  ## Concept

  How many slots are held right now.

  ## Technical depth

  Reads the slot table's size, so it counts claims that have not been released
  yet, including those of a sender that has already died but whose `DOWN` the
  dispatcher has not processed. It is an observation, never a reservation.
  """
  @spec held(t()) :: non_neg_integer()
  def held(%{slots: slots}), do: :ets.info(slots, :size)

  @doc """
  ## Concept

  Whether the backlog has drained far enough to report drops.

  ## Technical depth

  Reporting below half the ceiling keeps the summary itself out of a full
  backlog, where it would displace an admitted item.
  """
  @spec drained?(t()) :: boolean()
  def drained?(%{ceiling: ceiling} = handle), do: held(handle) < div(ceiling, 2)

  @doc """
  ## Concept

  Takes the pending drop count and resets it in one step.

  ## Technical depth

  `:atomics.exchange/3` is one atomic read-and-reset, so a drop counted
  concurrently is either included in this window or waits for the next one and
  is never lost or double-counted.
  """
  @spec take_drops(t()) :: non_neg_integer()
  def take_drops(%{counters: counters}), do: :atomics.exchange(counters, 2, 0)

  @doc """
  ## Concept

  Counts one item the dispatcher admitted but could not deliver.

  ## Technical depth

  An item lost at egress is as lost as one that never claimed a slot, and the
  same drop cell reports both, so the summary a host reads counts every
  diagnostic this runtime discarded rather than only the contended ones.
  """
  @spec count_drop(t()) :: :ok
  def count_drop(%{counters: counters}), do: :atomics.add(counters, 2, 1)

  @doc """
  ## Concept

  The drop count waiting to be reported, without taking it.

  ## Technical depth

  Reads the counter without clearing it, unlike the atomic exchange the drain
  summary performs. A caller can therefore observe what was lost without
  consuming it and without racing whoever reports it.
  """
  @spec pending_drops(t()) :: non_neg_integer()
  def pending_drops(%{counters: counters}), do: :atomics.get(counters, 2)

  @doc """
  ## Concept

  The last ticket any sender has taken.

  ## Technical depth

  The drop summary names the ticket range it covers, which is the only window
  both sides can agree on without a shared clock.
  """
  @spec ticket(t()) :: integer()
  def ticket(%{counters: counters}), do: :atomics.get(counters, 1)

  # Concept: one monitor registration per sender per dispatcher.
  #
  # Technical depth: the record lives in the sender's process dictionary, so it
  # dies with the process and a reused pid registers again. The dispatcher
  # ignores a duplicate registration, so a lost record costs one message.
  defp ensure_monitor(dispatcher) do
    key = {__MODULE__, dispatcher}

    case Process.get(key) do
      true ->
        :ok

      _unregistered ->
        send(dispatcher, {:loopex_diagnostic_monitor_me, self()})
        Process.put(key, true)
        :ok
    end
  end
end
