defmodule Loopex.TelemetryTest do
  @moduledoc """
  ## Concept

  The one Loopex-attached handler carries what core emits into a runtime's
  bounded diagnostics plane, as identities and numbers, and refuses anything
  richer.

  ## Technical depth

  The events are dispatched through the real `:telemetry` registry from core's
  own `Loopex.Instrumentation`, so the names this application subscribes to are
  proved against the names core actually emits rather than against a copy of the
  table. The admission handle is a real one whose dispatcher is the test
  process, which is what lets a case read exactly what a runtime's dispatcher
  would have received. This application depends on core and `:telemetry` alone,
  so no store and no runtime appear here; the end-to-end wiring belongs to a
  composition that holds both.
  """

  use ExUnit.Case, async: false

  alias Loopex.Instrumentation
  alias Loopex.Runtime.DiagnosticsAdmission, as: Admission
  alias Loopex.Telemetry

  test "the inventory is the accepted one, and every entry is a span" do
    events = Telemetry.events()

    for span <- [
          [:loopex, :model, :complete],
          [:loopex, :store, :transact],
          [:loopex, :artifact, :open_transfer],
          [:loopex, :executor, :execute],
          [:loopex, :policy, :decide],
          [:loopex, :command, :admit],
          [:loopex, :commit],
          [:loopex, :effect, :intent],
          [:loopex, :events, :publish],
          [:loopex, :interaction],
          [:loopex, :artifact, :transfer]
        ] do
      assert (span ++ [:start]) in events
      assert (span ++ [:stop]) in events
      assert (span ++ [:exception]) in events
    end

    # A cut whose lifetime is not one call is still a span, so nothing is
    # carried under a bare prefix.
    refute [:loopex, :artifact, :transfer] in events
    refute [:loopex, :interaction] in events

    # Nothing outside the accepted table is carried.
    refute [:loopex, :store, :retrieve, :stop] in events
    refute [:loopex, :context, :stage, :stop] in events

    assert Enum.all?(events, &match?([:loopex | _rest], &1))
    assert Enum.uniq(events) == events
  end

  test "an attached handler carries a span core emits, with its identities and timing" do
    admission = attached()

    Instrumentation.span(
      [:store, :transact],
      %{session_id: "s_1", type: :session_commit, records: 2},
      fn -> {:committed, "tx_1", %{}} end,
      fn _result -> :committed end
    )

    assert %{"event" => "loopex.store.transact.start"} = admitted(admission)

    item = admitted(admission)
    assert item["kind"] == "telemetry_span"
    assert item["event"] == "loopex.store.transact.stop"
    assert item["metadata"]["session_id"] == "s_1"
    assert item["metadata"]["type"] == "session_commit"
    assert item["metadata"]["outcome"] == "committed"
    assert item["metadata"]["records"] == 2
    assert is_integer(item["measurements"]["duration"])
  end

  test "an attached handler carries a lifetime that is not one call as the same span pair" do
    admission = attached()

    token = Instrumentation.open_span([:artifact, :transfer], %{session_id: "s_1"})

    start = admitted(admission)
    assert start["event"] == "loopex.artifact.transfer.start"
    assert is_integer(start["measurements"]["monotonic_time"])

    Instrumentation.close_span(
      token,
      %{bytes: 4_096, chunks: 4},
      %{session_id: "s_1", transfer_ref: "t_1", disposition: :closed}
    )

    stop = admitted(admission)
    assert stop["event"] == "loopex.artifact.transfer.stop"
    assert stop["measurements"]["bytes"] == 4_096
    assert stop["measurements"]["chunks"] == 4
    assert is_integer(stop["measurements"]["duration"])
    assert stop["metadata"]["disposition"] == "closed"
  end

  test "a detached handler carries nothing further" do
    admission = attached()

    token = Instrumentation.open_span([:artifact, :transfer], %{session_id: "s_1"})
    assert %{"event" => "loopex.artifact.transfer.start"} = admitted(admission)

    :ok = :telemetry.detach({__MODULE__, admission.dispatcher})

    Instrumentation.close_span(token, %{bytes: 2}, %{session_id: "s_1"})
    refute_receive {:loopex_diagnostic_admission, _pid, _slot, _ticket, _item}, 200
  end

  test "a value the inventory does not admit is replaced rather than carried" do
    admission = Admission.new(16)

    :ok =
      Telemetry.handle_event(
        [:loopex, :store, :transact, :stop],
        %{duration: 17},
        %{session_id: "s_1", holder: self(), blob: :binary.copy("x", 1_024)},
        admission
      )

    item = admitted(admission)
    assert item["metadata"]["session_id"] == "s_1"
    assert item["metadata"]["holder"] == "unbounded"
    assert item["metadata"]["blob"] == "binary/1024"
    assert item["measurements"]["duration"] == 17
  end

  test "attaching to something that is not a runtime reports that, and attaches nothing" do
    before = length(:telemetry.list_handlers([]))

    assert {:error, _reason} = Telemetry.attach(%{})
    assert length(:telemetry.list_handlers([])) == before
  end

  # Concept: a real admission handle whose dispatcher is this test process, with
  # the handler attached to the whole accepted inventory.
  #
  # Technical depth: the handler is attached under this case's own identity
  # rather than through `attach/1`, because `attach/1` resolves the handle from a
  # runtime and a runtime needs a store this application does not depend on. What
  # is being proved here is the carrying, and that is the same function either
  # way.
  defp attached do
    admission = Admission.new(16)

    :ok =
      :telemetry.attach_many(
        {__MODULE__, admission.dispatcher},
        Telemetry.events(),
        &Telemetry.handle_event/4,
        admission
      )

    on_exit(fn -> :telemetry.detach({__MODULE__, admission.dispatcher}) end)
    admission
  end

  defp admitted(admission) do
    receive do
      {:loopex_diagnostic_admission, pid, slot, ticket, item} ->
        # The slot is released the way the dispatcher releases it, so a case
        # emitting more items than the ceiling does not starve itself.
        Admission.release(admission, pid, slot, ticket)
        item
    after
      2_000 -> flunk("nothing was admitted")
    end
  end
end
