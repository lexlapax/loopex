Code.require_file("support/configured_genesis_helper.exs", __DIR__)
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

  test "a fresh operating system process re-presents the runtime placement identity persisted by its predecessor",
       %{root: root} do
    assert {:ok, runtime_id} = SessionDirectory.runtime_id(root)
    assert File.read!(Path.join(root, "runtime_id")) == runtime_id

    elixir = System.find_executable("elixir") || flunk("the accepted Elixir toolchain is absent")
    # The child loads the same compiled application this suite is running from.
    # The bound selector runner compiles into an owned build root outside the
    # checkout, so a path derived from the source tree names a directory that
    # need not exist there.
    ebin = Application.app_dir(:loopex, "ebin")

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

  test "a repeated resume command identity returns its historical result while a fresh identity acquires ownership",
       %{root: root} do
    {store_pid, store} = M1RuntimeTestStore.start_store(label: "idempotent-store")
    on_exit(fn -> stop_store(store_pid) end)

    {:ok, state_root} = SessionDirectory.state_root()
    assert state_root == root

    {:ok, runtime_id} = SessionDirectory.runtime_id(state_root)

    {:ok, runtime} =
      Loopex.start_link(
        context_token_budget: 8_192,
        session_creation_defaults:
          Loopex.ConfiguredGenesisFixture.genesis([]) |> Map.drop([:kind, "options"]),
        runtime_id: runtime_id,
        store: store
      )

    on_exit(fn -> stop_runtime(runtime) end)

    :ok = Loopex.ConfiguredGenesisFixture.await_creation_ready(runtime)

    {:ok, session_id} = Loopex.create_session(runtime, %{}, command_id: "create")

    assert {:ok, ^session_id} =
             Runtime.resume_session(runtime, session_id, "resume-1")

    epoch_after_first = session_owner_epoch(store_pid, session_id)

    # Re-presenting the same command_id must return the historical result
    # without contesting ownership again.
    assert {:ok, ^session_id} =
             Runtime.resume_session(runtime, session_id, "resume-1")

    assert session_owner_epoch(store_pid, session_id) == epoch_after_first

    # A fresh command_id, in contrast, acquires a genuine replacement owner.
    assert {:ok, ^session_id} =
             Runtime.resume_session(runtime, session_id, "resume-2")

    assert session_owner_epoch(store_pid, session_id) == epoch_after_first + 1
  end

  test "simultaneous resume misses converge on one durable owner advance", %{root: root} do
    {store_pid, store} = M1RuntimeTestStore.start_store(label: "resume-convergence")
    on_exit(fn -> stop_store(store_pid) end)

    {:ok, runtime_id} = SessionDirectory.runtime_id(root)

    {:ok, runtime} =
      Loopex.start_link(
        context_token_budget: 8_192,
        session_creation_defaults:
          Loopex.ConfiguredGenesisFixture.genesis([]) |> Map.drop([:kind, "options"]),
        runtime_id: runtime_id,
        store: store
      )

    on_exit(fn -> stop_runtime(runtime) end)

    :ok = Loopex.ConfiguredGenesisFixture.await_creation_ready(runtime)

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
      Loopex.start_link(
        context_token_budget: 8_192,
        session_creation_defaults:
          Loopex.ConfiguredGenesisFixture.genesis([]) |> Map.drop([:kind, "options"]),
        runtime_id: runtime_id,
        store: store
      )

    on_exit(fn -> stop_runtime(runtime) end)

    :ok = Loopex.ConfiguredGenesisFixture.await_creation_ready(runtime)

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

  test "cold runtime identity publication syncs every new namespace boundary", %{root: root} do
    cold_root = Path.join([root, "cold-parent", "state"])

    {runtime_result, runtime_syncs} =
      trace_syncs(fn -> SessionDirectory.runtime_id(cold_root) end)

    assert {:ok, _runtime_id} = runtime_result
    assert runtime_syncs == 5
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
