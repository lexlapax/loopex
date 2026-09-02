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

    {:ok, runtime} =
      Loopex.start_link(context_token_budget: 8_192, runtime_id: runtime_id, store: store)

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

    {:ok, creating_runtime} =
      Loopex.start_link(context_token_budget: 8_192, runtime_id: runtime_id, store: store)

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

    {:ok, resuming_runtime} =
      Loopex.start_link(context_token_budget: 8_192, runtime_id: resumed_runtime_id, store: store)

    on_exit(fn -> stop_runtime(resuming_runtime) end)

    assert {:ok, ^session_id} =
             SessionDirectory.resume(resumed_state_root, resuming_runtime, session_id, "resume-1")

    assert session_owner_epoch(store_pid, session_id) == before_epoch + 1
  end

  test "a fresh operating system process re-presents the runtime placement identity persisted by its predecessor",
       %{root: root} do
    assert {:ok, runtime_id} = SessionDirectory.runtime_id(root)
    assert File.read!(Path.join(root, "runtime_id")) == runtime_id

    elixir = System.find_executable("elixir") || flunk("the accepted Elixir toolchain is absent")
    ebin = Path.expand("../../../_build/test/lib/loopex/ebin", __DIR__)

    expression = """
    case Loopex.SessionDirectory.state_root() do
      {:ok, root} ->
        case Loopex.SessionDirectory.runtime_id(root) do
          {:ok, runtime_id} -> IO.binwrite(runtime_id)
          other -> IO.binwrite(:stderr, inspect(other)); System.halt(2)
        end

      other ->
        IO.binwrite(:stderr, inspect(other)); System.halt(3)
    end
    """

    # The child is compared on its exact output. Under the bound selector runner
    # it inherits no locale, and on Linux a VM without one prints a latin1
    # encoding warning on that same stream, so the child's locale is set here
    # rather than read from whatever environment happens to launch the suite.
    assert {^runtime_id, 0} =
             System.cmd(elixir, ["-pa", ebin, "-e", expression],
               env: [{"LOOPEX_HOME", root}, {"LANG", "C.UTF-8"}, {"LC_ALL", "C.UTF-8"}],
               stderr_to_stdout: true
             )
  end

  test "the runtime identity is synced as a file and directory entry before it is returned", %{
    root: root
  } do
    # Concept: a runtime identity returned to a host must be the identity a
    # process after a crash can re-present, not merely bytes still resident in
    # the writer's cache.
    #
    # Technical depth: crash durability cannot be induced portably in ExUnit, so
    # this case pairs a production round trip with the narrow structural proof
    # of the two fsync boundaries. Removing either syscall makes this selector
    # fail while ordinary healthy-disk tests would continue to pass.
    source = File.read!(Path.expand("../lib/loopex/session_directory.ex", __DIR__))

    assert source =~
             ~r/IO\.binwrite\(io, candidate\).*?:file\.sync\(io\)/s,
           "the generated identity is returned without syncing its bytes"

    assert source =~
             ~r/defp sync_runtime_id_directory\(path\).*?:file\.open\(directory, \[:raw, :read, :directory\]\).*?:file\.sync\(io\)/s,
           "the generated identity is returned without syncing its directory entry"

    assert {:ok, runtime_id} = SessionDirectory.runtime_id(root)
    assert {:ok, ^runtime_id} = SessionDirectory.runtime_id(root)
    assert File.read!(Path.join(root, "runtime_id")) == runtime_id
  end

  test "concurrent runtime identity bootstrap publishes only a complete winning identity", %{
    root: root
  } do
    parent = self()
    contenders = 16

    tasks =
      for _index <- 1..contenders do
        Task.async(fn ->
          SessionDirectory.runtime_id(root,
            before_publish: fn ->
              send(parent, {:runtime_id_ready, self()})

              receive do
                {:publish_runtime_id, ^parent} -> :ok
              end
            end
          )
        end)
      end

    publishers =
      for _index <- 1..contenders do
        assert_receive {:runtime_id_ready, publisher}, 2_000
        publisher
      end

    # Every contender has finished and synced its private candidate. The public
    # name still does not exist: a caller can see absent or complete, never the
    # empty interval an exclusive open of the final path exposed.
    refute File.exists?(Path.join(root, "runtime_id"))

    Enum.each(publishers, &send(&1, {:publish_runtime_id, parent}))

    results = Task.await_many(tasks, 5_000)
    assert Enum.all?(results, &match?({:ok, _runtime_id}, &1))

    identities = results |> Enum.map(&elem(&1, 1)) |> Enum.uniq()
    assert [runtime_id] = identities
    assert File.read!(Path.join(root, "runtime_id")) == runtime_id

    assert File.ls!(root)
           |> Enum.reject(&String.starts_with?(&1, "runtime_id.tmp-"))
           |> Enum.sort() == ["runtime_id"]
  end

  test "resuming a session through a different runtime identity is refused with an explicit reason",
       %{root: root} do
    {store_pid, store} = M1RuntimeTestStore.start_store(label: "mismatch-store")
    on_exit(fn -> stop_store(store_pid) end)

    {:ok, state_root} = SessionDirectory.state_root()
    assert state_root == root

    {:ok, creator_runtime} =
      Loopex.start_link(context_token_budget: 8_192, runtime_id: "runtime-original", store: store)

    on_exit(fn -> stop_runtime(creator_runtime) end)

    {:ok, session_id} = Loopex.create_session(creator_runtime, %{}, command_id: "create")
    :ok = SessionDirectory.record_session(state_root, session_id, "runtime-original")

    {:ok, other_runtime} =
      Loopex.start_link(
        context_token_budget: 8_192,
        runtime_id: "runtime-different",
        store: store
      )

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

    {:ok, runtime} =
      Loopex.start_link(context_token_budget: 8_192, runtime_id: runtime_id, store: store)

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

  test "Store replay of a resume command survives a missing directory cache", %{root: root} do
    {store_pid, store} = M1RuntimeTestStore.start_store(label: "resume-store-replay")
    on_exit(fn -> stop_store(store_pid) end)

    {:ok, runtime_id} = SessionDirectory.runtime_id(root)

    {:ok, runtime} =
      Loopex.start_link(context_token_budget: 8_192, runtime_id: runtime_id, store: store)

    on_exit(fn -> stop_runtime(runtime) end)

    {:ok, session_id} = Loopex.create_session(runtime, %{}, command_id: "create-replay")
    :ok = SessionDirectory.record_session(root, session_id, runtime_id)

    assert {:ok, ^session_id} =
             Loopex.Runtime.resume_session(runtime, session_id, "resume-store-owned")

    epoch = session_owner_epoch(store_pid, session_id)

    assert {:ok, ^session_id} =
             SessionDirectory.resume(root, runtime, session_id, "resume-store-owned")

    assert session_owner_epoch(store_pid, session_id) == epoch
  end

  test "simultaneous resume misses converge on one durable owner advance", %{root: root} do
    {store_pid, store} = M1RuntimeTestStore.start_store(label: "resume-convergence")
    on_exit(fn -> stop_store(store_pid) end)

    {:ok, runtime_id} = SessionDirectory.runtime_id(root)

    {:ok, runtime} =
      Loopex.start_link(context_token_budget: 8_192, runtime_id: runtime_id, store: store)

    on_exit(fn -> stop_runtime(runtime) end)

    {:ok, session_id} = Loopex.create_session(runtime, %{}, command_id: "create-convergence")
    before_epoch = session_owner_epoch(store_pid, session_id)

    :ok =
      M1RuntimeTestStore.delay_after_commit(
        store_pid,
        :runtime_control_stage_owner_attempt,
        self()
      )

    first = Task.async(fn -> Runtime.resume_session(runtime, session_id, "resume-concurrent") end)

    assert_receive {:transaction_linearized, waiter, ^store_pid,
                    :runtime_control_stage_owner_attempt, {:committed, _tx_id, _receipt}}

    second =
      Task.async(fn -> Runtime.resume_session(runtime, session_id, "resume-concurrent") end)

    M1RuntimeTestStore.release(waiter)

    assert Task.await(first) == {:ok, session_id}
    assert Task.await(second) == {:ok, session_id}
    assert session_owner_epoch(store_pid, session_id) == before_epoch + 1
  end

  test "one runtime command identity conflicts across session and command kind", %{root: root} do
    {store_pid, store} = M1RuntimeTestStore.start_store(label: "resume-binding-conflict")
    on_exit(fn -> stop_store(store_pid) end)

    {:ok, runtime_id} = SessionDirectory.runtime_id(root)

    {:ok, runtime} =
      Loopex.start_link(context_token_budget: 8_192, runtime_id: runtime_id, store: store)

    on_exit(fn -> stop_runtime(runtime) end)

    {:ok, session_a} = Loopex.create_session(runtime, %{}, command_id: "create-a-conflict")
    {:ok, session_b} = Loopex.create_session(runtime, %{}, command_id: "create-b-conflict")

    assert {:ok, ^session_a} = Runtime.resume_session(runtime, session_a, "shared-resume")
    before_b = session_owner_epoch(store_pid, session_b)

    assert {:error, :runtime_command_conflict} =
             Runtime.resume_session(runtime, session_b, "shared-resume")

    assert {:error, :runtime_command_conflict} =
             Runtime.resume_session(runtime, session_a, "create-a-conflict")

    changed_canonical = resume_command_binding(runtime_id, session_a, "shared-resume", "v2")

    assert {:error, :runtime_command_conflict} =
             Loopex.Store.runtime_command(store, changed_canonical)

    assert session_owner_epoch(store_pid, session_b) == before_b
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

  test "a non regular session entry is refused before it can block or redirect a read", %{
    root: root
  } do
    {:ok, state_root} = SessionDirectory.state_root()
    {:ok, runtime_id} = SessionDirectory.runtime_id(state_root)

    sessions = Path.join(root, "sessions")
    File.mkdir_p!(Path.join(sessions, "not-a-session"))

    assert {:ok, []} = SessionDirectory.list_sessions(state_root)

    assert {:error, :invalid_session_id} =
             SessionDirectory.record_session(
               state_root,
               "not-a-session",
               runtime_id
             )

    assert {:error, :invalid_session_id} =
             SessionDirectory.resume(
               state_root,
               :unused,
               "not-a-session",
               "resume-1"
             )
  end

  test "runtime identity refuses a link or fifo before reading placement bytes", %{root: root} do
    identity_path = Path.join(root, "runtime_id")
    outside = Path.join(root, "outside-runtime-id")
    File.write!(outside, "runtime_attacker")
    File.ln_s!(outside, identity_path)

    assert {:error, :corrupt_runtime_id} = SessionDirectory.runtime_id(root)
    File.rm!(identity_path)

    mkfifo = System.find_executable("mkfifo") || flunk("the POSIX mkfifo tool is unavailable")
    {_output, 0} = System.cmd(mkfifo, [identity_path], stderr_to_stdout: true)

    task = Task.async(fn -> SessionDirectory.runtime_id(root) end)
    assert {:error, :corrupt_runtime_id} = Task.await(task, 1_000)
  end

  test "a linked sessions directory cannot redirect listing recording or resume", %{root: root} do
    outside = Path.join(root, "outside-sessions")
    File.mkdir_p!(outside)

    outside_entry =
      :erlang.term_to_binary(%{
        session_id: "s_outside",
        runtime_id: "runtime_attacker",
        commands: %{}
      })

    File.write!(Path.join(outside, "s_outside"), outside_entry)

    File.ln_s!(outside, Path.join(root, "sessions"))

    assert {:error, :sessions_directory_unreadable} = SessionDirectory.list_sessions(root)

    assert {:error, :invalid_session_id} =
             SessionDirectory.record_session(root, "s_outside", "runtime_real")

    assert {:error, :invalid_session_id} =
             SessionDirectory.resume(root, :unused, "s_outside", "resume-1")

    assert File.read!(Path.join(outside, "s_outside")) == outside_entry
  end

  test "a session entry is bounded and its durable identity cannot disagree with its name", %{
    root: root
  } do
    sessions = Path.join(root, "sessions")
    File.mkdir_p!(sessions)

    planted = fn name, entry ->
      File.write!(Path.join(sessions, name), :erlang.term_to_binary(entry))
    end

    planted.("s_mismatch", %{
      session_id: "s_other",
      runtime_id: "runtime_attacker",
      commands: %{}
    })

    planted.("s_host_term", %{
      session_id: "s_host_term",
      runtime_id: "runtime_attacker",
      commands: %{"resume-1" => self()}
    })

    compressed =
      :erlang.term_to_binary(
        %{
          session_id: "s_compressed",
          runtime_id: "runtime_attacker",
          commands: %{},
          padding: String.duplicate("x", 2_000_000)
        },
        compressed: 9
      )

    assert byte_size(compressed) < 1_048_576
    File.write!(Path.join(sessions, "s_compressed"), compressed)
    File.write!(Path.join(sessions, "s_oversized"), String.duplicate("x", 1_048_577))

    for session_id <- ["s_mismatch", "s_host_term", "s_compressed", "s_oversized"] do
      assert {:error, :corrupt_session_entry} =
               SessionDirectory.resume(root, :unused, session_id, "resume-1"),
             "#{session_id} crossed the public resume boundary"
    end

    assert {:ok, []} = SessionDirectory.list_sessions(root)
  end

  test "cold runtime and session directory publication syncs every new namespace boundary", %{
    root: root
  } do
    cold_root = Path.join([root, "cold-parent", "state"])

    {runtime_result, runtime_syncs} =
      trace_syncs(fn -> SessionDirectory.runtime_id(cold_root) end)

    assert {:ok, runtime_id} = runtime_result
    assert runtime_syncs == 5

    {record_result, record_syncs} =
      trace_syncs(fn -> SessionDirectory.record_session(cold_root, "s_durable", runtime_id) end)

    assert :ok = record_result
    assert record_syncs == 3

    assert {:ok, [%{session_id: "s_durable", runtime_id: ^runtime_id}]} =
             SessionDirectory.list_sessions(cold_root)
  end

  defp trace_syncs(fun) do
    test = self()
    tracer = spawn_link(fn -> trace_sync_forwarder(test, 0) end)
    1 = :erlang.trace_pattern({:file, :sync, 1}, true, [])
    1 = :erlang.trace(self(), true, [:call, {:tracer, tracer}])

    result =
      try do
        fun.()
      after
        1 = :erlang.trace(self(), false, [:call])
        1 = :erlang.trace_pattern({:file, :sync, 1}, false, [])
      end

    delivery = :erlang.trace_delivered(self())

    receive do
      {:trace_delivered, _tracee, ^delivery} -> :ok
    after
      1_000 -> flunk("session-directory sync trace was not delivered")
    end

    send(tracer, {:finish, self()})

    receive do
      {:session_directory_syncs, count} -> {result, count}
    after
      1_000 -> flunk("session-directory sync trace did not finish")
    end
  end

  defp trace_sync_forwarder(test, count) do
    receive do
      {:trace, ^test, :call, {:file, :sync, [_io_device]}} ->
        trace_sync_forwarder(test, count + 1)

      {:finish, ^test} ->
        send(test, {:session_directory_syncs, count})
    end
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

  defp resume_command_binding(runtime_id, session_id, command_id, version) do
    canonical =
      :erlang.term_to_binary(
        [
          "loopex_runtime_command_#{version}",
          runtime_id,
          command_id,
          :resume,
          session_id,
          "session"
        ],
        [:deterministic]
      )

    succession_bytes =
      :erlang.term_to_binary(
        ["loopex_owner_operation_v1", runtime_id, "resume", session_id, command_id],
        [:deterministic]
      )

    encoded = :crypto.hash(:sha256, succession_bytes) |> Base.encode16(case: :lower)

    %{
      runtime_id: runtime_id,
      command_id: command_id,
      command_kind: :resume,
      session_id: session_id,
      mutation_domain: "session",
      succession_id: "succession_" <> binary_part(encoded, 0, 40),
      canonical_command_bytes: canonical,
      canonical_command_digest: :crypto.hash(:sha256, canonical)
    }
  end

  defp stop_runtime(runtime) do
    if Runtime.alive?(runtime), do: Loopex.stop(runtime)
  end

  defp stop_store(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid)
  end
end
