defmodule Loopex.ArtifactOpenClockTest do
  use ExUnit.Case, async: true

  alias Loopex.Attachment
  alias Loopex.ArtifactStore
  alias Loopex.Runtime
  alias Loopex.Runtime.EventDispatcher

  test "opening captures one clock before supervisor queuing and binds the actual route" do
    test = self()
    dispatcher = owned(fn -> dispatcher(test) end)
    supervisor = owned(fn -> supervisor(test, dispatcher) end)
    attachment = attachment(supervisor, dispatcher)
    request = %{use_locator: "use:" <> String.duplicate("a", 64), start: 0}
    before_open = System.monotonic_time(:millisecond)
    caller = Task.async(fn -> Runtime.open_artifact_transfer(attachment, request) end)

    assert_receive {:lookup, ^supervisor, lookup_from}, 1_000
    after_lookup = System.monotonic_time(:millisecond)
    Process.sleep(2)
    assert System.monotonic_time(:millisecond) > after_lookup
    assert System.monotonic_time(:millisecond) < before_open + 1_000
    GenServer.reply(lookup_from, [{EventDispatcher, dispatcher, :worker, [EventDispatcher]}])

    assert_receive {:open, ^dispatcher, message, from}, 1_000
    assert {:open_transfer, token, "session", "attachment", "incarnation", routed, context} = message
    assert token === attachment.runtime.token
    assert routed === Map.put(request, :session_id, "session")
    assert ArtifactStore.valid_transfer_request?(routed)
    assert ArtifactStore.valid_open_context?(context)
    assert context.open_deadline_ms >= before_open + 60_000
    assert context.open_deadline_ms <= after_lookup + 60_000
    assert context.object_work_bytes === 134_217_728
    assert context.metadata_read_bytes === 131_073
    assert System.monotonic_time(:millisecond) < context.open_deadline_ms
    GenServer.reply(from, {:ok, %{transfer_ref: context.transfer_ref}})
    assert {:ok, %{transfer_ref: id}} = Task.await(caller, 1_000)
    assert id === context.transfer_ref
  end

  test "unknown object, null window and mismatched routed session refuse before lookup" do
    test = self()
    supervisor = owned(fn -> supervisor(test, self()) end)
    attachment = attachment(supervisor)
    request = %{use_locator: "use:" <> String.duplicate("b", 64), start: 0}

    for invalid <- [
          Map.put(request, :object, %{digest: "not caller authority"}),
          Map.put(request, :length, nil),
          Map.put(request, :session_id, "other"),
          Map.delete(request, :start)
        ] do
      assert {:error, :invalid_artifact_request} =
               Runtime.open_artifact_transfer(attachment, invalid)
    end

    refute_received {:lookup, ^supervisor, _from}
  end

  test "a lost original dispatcher returns uncertainty without following another child" do
    test = self()
    dispatcher = owned(fn -> dispatcher(test) end)
    supervisor = owned(fn -> supervisor(test, dispatcher) end)
    attachment = attachment(supervisor, dispatcher)
    request = %{use_locator: "use:" <> String.duplicate("c", 64), start: 0}
    caller = Task.async(fn -> Runtime.open_artifact_transfer(attachment, request) end)
    assert_receive {:lookup, ^supervisor, lookup_from}, 1_000
    GenServer.reply(lookup_from, [{EventDispatcher, dispatcher, :worker, [EventDispatcher]}])
    assert_receive {:open, ^dispatcher, _message, _from}, 1_000
    monitor = Process.monitor(dispatcher)
    Process.exit(dispatcher, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^dispatcher, :killed}, 1_000

    assert {:error, %{reason: :transfers_unavailable, cleanup: :unproved}} =
             Task.await(caller, 1_000)

    refute_received {:lookup, ^supervisor, _from}
  end

  test "a replacement child cannot recover the original generation's artifact credit" do
    test = self()
    original = owned(fn -> dispatcher(test) end)
    replacement = owned(fn -> dispatcher(test) end)
    supervisor = owned(fn -> supervisor(test, replacement) end)
    attachment = attachment(supervisor, original)
    request = %{use_locator: "use:" <> String.duplicate("d", 64), start: 0}
    caller = Task.async(fn -> Runtime.open_artifact_transfer(attachment, request) end)
    assert_receive {:lookup, ^supervisor, lookup_from}, 1_000
    GenServer.reply(lookup_from, [{EventDispatcher, replacement, :worker, [EventDispatcher]}])
    assert {:error, %{reason: :transfers_unavailable, cleanup: :unproved}} = Task.await(caller, 1_000)
    refute_received {:open, _, _, _}
    assert Process.alive?(original)
  end

  test "read and close capture their original five-second clock before lookup" do
    test = self()
    dispatcher = owned(fn -> dispatcher(test) end)
    supervisor = owned(fn -> supervisor(test, dispatcher) end)
    attachment = attachment(supervisor, dispatcher)
    id = String.duplicate("e", 32)

    for operation <- [:read, :close] do
      before_call = System.monotonic_time(:millisecond)
      caller = Task.async(fn ->
        case operation do
          :read -> Runtime.read_artifact_chunk(attachment, id, 3)
          :close -> Runtime.close_artifact_transfer(attachment, id)
        end
      end)
      assert_receive {:lookup, ^supervisor, lookup_from}, 1_000
      queued_at = System.monotonic_time(:millisecond)
      Process.sleep(2)
      assert System.monotonic_time(:millisecond) > queued_at
      assert System.monotonic_time(:millisecond) < before_call + 1_000
      GenServer.reply(lookup_from, [{EventDispatcher, dispatcher, :worker, [EventDispatcher]}])
      assert_receive {:open, ^dispatcher, message, from}, 1_000

      case operation do
        :read ->
          assert {:read_transfer, token, "session", "attachment", "incarnation", ^id, 3, deadline} = message
          assert token === attachment.runtime.token
          assert deadline >= before_call + 5_000
          assert deadline <= queued_at + 5_000
          GenServer.reply(from, {:ok, :complete})
          assert {:ok, :complete} = Task.await(caller, 1_000)

        :close ->
          assert {:close_transfer, token, "session", "attachment", "incarnation", ^id, anchor} = message
          assert token === attachment.runtime.token
          assert anchor >= before_call
          assert anchor <= queued_at
          GenServer.reply(from, :ok)
          assert :ok = Task.await(caller, 1_000)
      end
    end
  end

  defp attachment(supervisor, dispatcher \\ nil) do
    Attachment.from_runtime(
      %Runtime{supervisor: supervisor, token: make_ref(), artifact_dispatcher: dispatcher},
      "session",
      "attachment",
      "incarnation",
      %{}
    )
  end

  defp owned(function) do
    pid = spawn(function)
    on_exit(fn ->
      monitor = Process.monitor(pid)
      if Process.alive?(pid), do: Process.exit(pid, :kill)

      receive do
        {:DOWN, ^monitor, :process, ^pid, _reason} -> :ok
      after
        1_000 -> raise "fixture actor remained unjoined"
      end
    end)

    pid
  end

  defp supervisor(test, _dispatcher) do
    receive do
      {:'$gen_call', from, :which_children} ->
        send(test, {:lookup, self(), from})
        supervisor(test, nil)
    end
  end

  defp dispatcher(test) do
    receive do
      {:'$gen_call', from, message} ->
        send(test, {:open, self(), message, from})
        dispatcher(test)
      {:'$gen_cast', message} ->
        send(test, {:cancel, self(), message})
        dispatcher(test)
    end
  end
end
