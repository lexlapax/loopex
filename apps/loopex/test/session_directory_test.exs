Code.require_file("support/m1_runtime_helper.exs", __DIR__)

defmodule Loopex.SessionDirectoryTest do
  use ExUnit.Case, async: false

  alias Loopex.M1RuntimeTestStore
  alias Loopex.Runtime
  alias Loopex.SessionDirectory

  setup do
    original_home = System.fetch_env!("LOOPEX_HOME")

    root =
      Path.join(
        System.tmp_dir!(),
        "loopex-session-directory-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    System.put_env("LOOPEX_HOME", root)

    on_exit(fn ->
      System.put_env("LOOPEX_HOME", original_home)
      File.rm_rf(root)
    end)

    %{root: root}
  end

  test "a fresh operating system process lists the sessions in a resolved state root", %{
    root: root
  } do
    {store_pid, store} = M1RuntimeTestStore.start_store(label: "list-store")
    on_exit(fn -> stop_store(store_pid) end)

    assert {:ok, state_root} = SessionDirectory.state_root()
    assert state_root == root

    {:ok, runtime_id} = SessionDirectory.runtime_id(state_root)
    {:ok, runtime} = Loopex.start_link(runtime_id: runtime_id, store: store)
    on_exit(fn -> stop_runtime(runtime) end)

    {:ok, session_a} = Loopex.create_session(runtime, %{}, command_id: "create-a")
    :ok = SessionDirectory.record_session(state_root, session_a, runtime_id)

    {:ok, session_b} = Loopex.create_session(runtime, %{}, command_id: "create-b")
    :ok = SessionDirectory.record_session(state_root, session_b, runtime_id)

    # Nothing here reads the runtime this test just started: a fresh
    # operating-system process would hold no such reference either, only the
    # resolved state root on disk.
    assert {:ok, listed} = SessionDirectory.list_sessions(state_root)

    assert Enum.sort(Enum.map(listed, & &1.session_id)) == Enum.sort([session_a, session_b])
    assert Enum.all?(listed, &(&1.runtime_id == runtime_id))
  end

  test "the state root resolves from LOOPEX_HOME and never from application environment", %{
    root: root
  } do
    Application.put_env(:loopex, :state_root, "/should/never/be/read")
    on_exit(fn -> Application.delete_env(:loopex, :state_root) end)

    assert {:ok, ^root} = SessionDirectory.state_root()

    System.delete_env("LOOPEX_HOME")
    assert {:error, :loopex_home_required} = SessionDirectory.state_root()

    other_root =
      Path.join(
        System.tmp_dir!(),
        "loopex-session-directory-alt-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(other_root)
    System.put_env("LOOPEX_HOME", other_root)

    assert {:ok, ^other_root} = SessionDirectory.state_root()
    refute SessionDirectory.state_root() == {:ok, "/should/never/be/read"}

    File.rm_rf(other_root)
    System.put_env("LOOPEX_HOME", root)
  end

  test "a session resumes under the durable runtime placement identity that created it", %{
    root: root
  } do
    {store_pid, store} = M1RuntimeTestStore.start_store(label: "resume-store")
    on_exit(fn -> stop_store(store_pid) end)

    {:ok, state_root} = SessionDirectory.state_root()
    assert state_root == root

    {:ok, runtime_id} = SessionDirectory.runtime_id(state_root)

    {:ok, creating_runtime} = Loopex.start_link(runtime_id: runtime_id, store: store)
    {:ok, session_id} = Loopex.create_session(creating_runtime, %{}, command_id: "create")
    :ok = SessionDirectory.record_session(state_root, session_id, runtime_id)
    :ok = Loopex.stop(creating_runtime)

    before_epoch = session_owner_epoch(store_pid, session_id)

    # Simulate a fresh operating-system process: the only thing that survives
    # is the state root on disk and the durable Store. Re-resolving the root
    # and re-presenting its persisted runtime_id must reconstruct the exact
    # placement identity this session was created under.
    {:ok, resumed_state_root} = SessionDirectory.state_root()
    {:ok, resumed_runtime_id} = SessionDirectory.runtime_id(resumed_state_root)
    assert resumed_runtime_id == runtime_id

    {:ok, resuming_runtime} = Loopex.start_link(runtime_id: resumed_runtime_id, store: store)
    on_exit(fn -> stop_runtime(resuming_runtime) end)

    assert {:ok, ^session_id} =
             SessionDirectory.resume(resumed_state_root, resuming_runtime, session_id, "resume-1")

    assert session_owner_epoch(store_pid, session_id) == before_epoch + 1
  end

  test "resuming a session through a different runtime identity is refused with an explicit reason",
       %{root: root} do
    {store_pid, store} = M1RuntimeTestStore.start_store(label: "mismatch-store")
    on_exit(fn -> stop_store(store_pid) end)

    {:ok, state_root} = SessionDirectory.state_root()
    assert state_root == root

    {:ok, creator_runtime} = Loopex.start_link(runtime_id: "runtime-original", store: store)
    on_exit(fn -> stop_runtime(creator_runtime) end)

    {:ok, session_id} = Loopex.create_session(creator_runtime, %{}, command_id: "create")
    :ok = SessionDirectory.record_session(state_root, session_id, "runtime-original")

    {:ok, other_runtime} = Loopex.start_link(runtime_id: "runtime-different", store: store)
    on_exit(fn -> stop_runtime(other_runtime) end)

    before_epoch = session_owner_epoch(store_pid, session_id)

    assert {:error, {:runtime_placement_mismatch, reason}} =
             SessionDirectory.resume(state_root, other_runtime, session_id, "resume-wrong")

    assert is_binary(reason)
    assert reason =~ "runtime-original"

    # A refused placement never reaches the Store: ownership is exactly as it
    # was before the attempt.
    assert session_owner_epoch(store_pid, session_id) == before_epoch
  end

  test "a repeated resume command identity returns its historical result while a fresh identity acquires ownership",
       %{root: root} do
    {store_pid, store} = M1RuntimeTestStore.start_store(label: "idempotent-store")
    on_exit(fn -> stop_store(store_pid) end)

    {:ok, state_root} = SessionDirectory.state_root()
    assert state_root == root

    {:ok, runtime_id} = SessionDirectory.runtime_id(state_root)
    {:ok, runtime} = Loopex.start_link(runtime_id: runtime_id, store: store)
    on_exit(fn -> stop_runtime(runtime) end)

    {:ok, session_id} = Loopex.create_session(runtime, %{}, command_id: "create")
    :ok = SessionDirectory.record_session(state_root, session_id, runtime_id)

    assert {:ok, ^session_id} =
             SessionDirectory.resume(state_root, runtime, session_id, "resume-1")

    epoch_after_first = session_owner_epoch(store_pid, session_id)

    # Re-presenting the same command_id must return the historical result
    # without contesting ownership again.
    assert {:ok, ^session_id} =
             SessionDirectory.resume(state_root, runtime, session_id, "resume-1")

    assert session_owner_epoch(store_pid, session_id) == epoch_after_first

    # A fresh command_id, in contrast, acquires a genuine replacement owner.
    assert {:ok, ^session_id} =
             SessionDirectory.resume(state_root, runtime, session_id, "resume-2")

    assert session_owner_epoch(store_pid, session_id) == epoch_after_first + 1
  end

  defp session_owner_epoch(store_pid, session_id) do
    M1RuntimeTestStore.inspect_state(store_pid).sessions
    |> Map.fetch!(session_id)
    |> Map.fetch!(:owner_epoch)
  end

  defp stop_runtime(runtime) do
    if Runtime.alive?(runtime), do: Loopex.stop(runtime)
  end

  defp stop_store(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid)
  end
end
