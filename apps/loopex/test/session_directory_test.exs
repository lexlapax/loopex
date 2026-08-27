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

  test "a session identifier that is not one contained name is refused before any file is touched",
       %{root: root} do
    # Concept: the identifier an operator types names an entry in this
    # directory, never a path through the rest of the state root.
    #
    # Technical depth: `loopex resume` hands its positional argument straight
    # here, and the argument used to be joined unchecked. A traversal
    # identifier therefore read and wrote outside the sessions directory --
    # `record_session/3` would create a file anywhere the process can write,
    # and `resume/4` became a probe for whatever was there.
    {:ok, state_root} = SessionDirectory.state_root()
    {:ok, runtime_id} = SessionDirectory.runtime_id(state_root)

    outside = Path.join(root, "outside-entry")

    File.write!(
      outside,
      :erlang.term_to_binary(%{session_id: "x", runtime_id: "r", commands: %{}})
    )

    for identifier <- ["../outside-entry", "../../etc/passwd", "..", ".", "a/b", <<"a", 0, "b">>] do
      assert {:error, :invalid_session_id} =
               SessionDirectory.record_session(state_root, identifier, runtime_id),
             "#{inspect(identifier)} was accepted as a session identifier"
    end

    # The escape was readable as well as writable: the planted entry decodes,
    # so an unchecked join would have answered from it.
    assert {:error, :invalid_session_id} =
             SessionDirectory.resume(state_root, :unused, "../outside-entry", "resume-1")

    # Nothing was created beside the file that was planted, and it is unchanged.
    assert File.ls!(root) |> Enum.sort() == ["outside-entry", "runtime_id"]
  end

  test "two runtimes recording one session concurrently leave exactly one durable binding", %{
    root: root
  } do
    # Concept: the runtime that creates a session owns it permanently, and two
    # arriving together cannot both come away believing they own it.
    #
    # Technical depth: `record_session/3` read, saw the session unknown, and
    # renamed unconditionally. Between the read and the rename another runtime
    # could complete the same sequence, and the later rename replaced the
    # earlier binding with no error to either caller -- the ADR 0008 placement
    # binding lost to a race that the `:session_already_bound` branch appeared
    # to cover. Creation now links rather than renames, so exactly one writer
    # can win and the other settles against what is durably there.
    {:ok, state_root} = SessionDirectory.state_root()
    session_id = "contended-session"

    # Serialised on a barrier so both attempts pass their read before either
    # publishes; that is the window the unconditional rename left open.
    barrier = :counters.new(1, [:atomics])

    runtimes = for index <- 1..8, do: "runtime-#{index}"

    results =
      runtimes
      |> Enum.map(fn id ->
        Task.async(fn ->
          :counters.add(barrier, 1, 1)
          wait_for_barrier(barrier, length(runtimes))
          {id, SessionDirectory.record_session(state_root, session_id, id)}
        end)
      end)
      |> Task.await_many(5_000)

    winners = for {id, :ok} <- results, do: id
    assert length(winners) == 1, "expected one binding, got #{inspect(winners)}"

    for {_id, result} <- results, result != :ok do
      assert {:error, {:session_already_bound, bound}} = result
      assert bound == hd(winners)
    end

    # The durable record agrees with the one caller that was told it won, and
    # that caller can re-present its own identity idempotently.
    assert {:ok, [%{session_id: ^session_id, runtime_id: recorded}]} =
             SessionDirectory.list_sessions(state_root)

    assert recorded == hd(winners)
    assert :ok = SessionDirectory.record_session(state_root, session_id, recorded)

    # No temporary file survived any losing attempt.
    assert Path.join([root, "sessions"]) |> File.ls!() == [session_id]
  end

  test "a planted symlink is not an entry of this directory and never becomes one", %{root: root} do
    # Concept: an entry in the sessions directory is a file that directory
    # holds. A name pointing somewhere else is not a session of this state root,
    # whatever it decodes to.
    #
    # Technical depth: `contained?/1` constrains the identifier and says nothing
    # about what the name already refers to, and `File.read/1` follows a symlink
    # to its target. Anyone able to write into the sessions directory could
    # therefore plant one: `list_sessions/1` reported bytes from outside the
    # state root as a session of it, under a `runtime_id` the planter chose, and
    # the name being taken made `record_session/3` refuse the real session
    # `:session_already_bound` against a binding this host never made. Neither
    # the listing nor the refusal was true.
    {:ok, state_root} = SessionDirectory.state_root()
    {:ok, runtime_id} = SessionDirectory.runtime_id(state_root)

    sessions = Path.join(root, "sessions")
    File.mkdir_p!(sessions)

    outside = Path.join(root, "planted-entry")

    File.write!(
      outside,
      :erlang.term_to_binary(%{
        session_id: "s_planted",
        runtime_id: "runtime_attacker",
        commands: %{}
      })
    )

    File.ln_s!(outside, Path.join(sessions, "s_planted"))

    # The listing answers from what this directory holds, and it holds no
    # session by that name.
    assert {:ok, listed} = SessionDirectory.list_sessions(state_root)

    refute Enum.any?(listed, &(&1.session_id == "s_planted")),
           "a planted symlink was listed as a session: #{inspect(listed)}"

    refute Enum.any?(listed, &(&1.runtime_id == "runtime_attacker")),
           "an outside runtime_id reached the listing: #{inspect(listed)}"

    # And the squat is refused as what it is, rather than answered from the
    # bytes it points at.
    assert {:error, :invalid_session_id} =
             SessionDirectory.record_session(state_root, "s_planted", runtime_id)

    assert {:error, :invalid_session_id} =
             SessionDirectory.resume(state_root, :unused, "s_planted", "resume-1")

    # The link and its target are left exactly as they were: refusing an entry
    # is not licence to delete whatever an operator deliberately linked.
    assert {:ok, %File.Stat{type: :symlink}} = File.lstat(Path.join(sessions, "s_planted"))
    assert File.exists?(outside)

    # An ordinary entry beside it is unaffected, so the rule is about the link
    # and not about the directory.
    assert :ok = SessionDirectory.record_session(state_root, "s_real", runtime_id)
    assert {:ok, entries} = SessionDirectory.list_sessions(state_root)
    assert Enum.map(entries, & &1.session_id) == ["s_real"]
  end

  defp wait_for_barrier(barrier, target) do
    if :counters.get(barrier, 1) >= target do
      :ok
    else
      wait_for_barrier(barrier, target)
    end
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
