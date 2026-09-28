defmodule LoopexComposition.Ephemeral.SessionRootStartTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias Loopex.Runtime
  alias Loopex.Store
  alias Loopex.Trace.Capability
  alias LoopexComposition.Ephemeral.{RuntimeHolder, SessionRoot}

  setup do
    tmp =
      Path.join(System.tmp_dir!(), "loopex-session-root-#{System.unique_integer([:positive])}")

    File.mkdir!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)
    {:ok, tmp: tmp}
  end

  test "root startup and wrong grants cannot inspect or create a temporary root", %{tmp: tmp} do
    test = self()

    seams = %{
      temp_root: %{
        tmp: fn ->
          send(test, :tmp_lookup)
          tmp
        end,
        entropy: fn 32 ->
          send(test, :entropy)
          :binary.copy(<<7>>, 32)
        end
      }
    }

    {root, ref} = start_root(tmp, seams)
    assert_receive {:root_ready, ^root, ^ref}
    assert_receive {:phase_ready, ^root, ^ref, :candidate_prepare}
    refute_receive :tmp_lookup

    send(root, {:grant, self(), make_ref(), :candidate_prepare, nil})
    send(root, {:grant, self(), ref, :root_claim, nil})
    refute_receive :tmp_lookup, 30

    send(root, {:grant, self(), ref, :candidate_prepare, nil})
    assert_receive :tmp_lookup
    assert_receive :entropy
    assert_receive {:phase_result, ^root, ^ref, :candidate_prepare, {:ok, candidate}}
    assert_receive {:phase_ready, ^root, ^ref, :root_claim}
    assert File.lstat(candidate.path) == {:error, :enoent}

    send(root, {:grant, self(), make_ref(), :root_claim, nil})
    refute_receive {:phase_result, ^root, ^ref, :root_claim, _}, 30
    assert File.lstat(candidate.path) == {:error, :enoent}

    send(root, {:grant, self(), ref, :root_claim, nil})
    assert_receive {:phase_result, ^root, ^ref, :root_claim, {:ok, owned}}
    assert_receive {:phase_ready, ^root, ^ref, :private_supervisor}
    assert File.dir?(owned.path)
    assert File.lstat!(owned.path).inode == owned.identity.inode
  end

  test "a supervisor and child start only after each exact acknowledgement", %{tmp: tmp} do
    {root, ref} = start_root(tmp)
    {owned, supervisor} = claim_and_supervise(root, ref)

    refute_receive {:phase_ready, ^root, ^ref, :memory_store}, 30
    send(root, {:ack, self(), make_ref(), :private_supervisor, supervisor})
    send(root, {:ack, self(), ref, :private_supervisor, self()})
    refute_receive {:phase_ready, ^root, ^ref, :memory_store}, 30

    send(root, {:ack, self(), ref, :private_supervisor, supervisor})
    assert_receive {:phase_ready, ^root, ^ref, :memory_store}
    send(root, {:grant, self(), ref, :memory_store, nil})
    assert_receive {:phase_result, ^root, ^ref, :memory_store, {:ok, store_pid}}
    assert is_pid(store_pid)
    assert Process.alive?(store_pid)

    refute_receive {:phase_ready, ^root, ^ref, :store_handle}, 30
    send(root, {:ack, self(), ref, :memory_store, self()})
    refute_receive {:phase_ready, ^root, ^ref, :store_handle}, 30
    send(root, {:ack, self(), ref, :memory_store, store_pid})
    assert_receive {:phase_ready, ^root, ^ref, :store_handle}
    send(root, {:grant, self(), ref, :store_handle, nil})
    assert_receive {:phase_result, ^root, ^ref, :store_handle, {:ok, store_handle}}
    refute_receive {:phase_ready, ^root, ^ref, :workspace_lease}, 30
    send(root, {:ack, self(), ref, :store_handle, store_handle})
    assert_receive {:phase_ready, ^root, ^ref, :workspace_lease}

    root_monitor = Process.monitor(root)
    supervisor_monitor = Process.monitor(supervisor)
    Process.exit(store_pid, :kill)
    assert_receive {:DOWN, ^supervisor_monitor, :process, ^supervisor, _}, 1_000
    assert_receive {:DOWN, ^root_monitor, :process, ^root, _}, 1_000
    assert File.dir?(owned.path)
  end

  test "sixteen exclusive-create collisions stop without starting a private supervisor", %{
    tmp: tmp
  } do
    test = self()

    seams = %{
      temp_root: %{
        tmp: fn -> tmp end,
        entropy: fn 32 ->
          count = Process.get(:session_root_nonce_count, 0) + 1
          Process.put(:session_root_nonce_count, count)
          send(test, {:nonce, count})
          <<count::unsigned-size(256)>>
        end,
        mkdir: fn path ->
          send(test, {:mkdir, path})
          {:error, :eexist}
        end
      }
    }

    {root, ref} = start_root(tmp, seams)
    assert_receive {:root_ready, ^root, ^ref}
    assert_receive {:phase_ready, ^root, ^ref, :candidate_prepare}

    for attempt <- 1..16 do
      send(root, {:grant, self(), ref, :candidate_prepare, nil})
      assert_receive {:nonce, ^attempt}
      assert_receive {:phase_result, ^root, ^ref, :candidate_prepare, {:ok, candidate}}
      assert_receive {:phase_ready, ^root, ^ref, :root_claim}
      send(root, {:grant, self(), ref, :root_claim, nil})
      assert_receive {:mkdir, path}
      assert path == candidate.path

      if attempt < 16 do
        assert_receive {:phase_result, ^root, ^ref, :root_claim, {:error, :collision}}
        assert_receive {:phase_ready, ^root, ^ref, :candidate_prepare}
      else
        assert_receive {:phase_result, ^root, ^ref, :root_claim,
                        {:error, :temporary_root_creation_failed}}
      end
    end

    refute_receive {:phase_ready, ^root, ^ref, :private_supervisor}, 30
    assert File.ls!(tmp) == []
  end

  test "startup expiry leaves a started tree for the owner to prove and stop", %{tmp: tmp} do
    {root, ref} = start_root(tmp, %{}, 1_000)
    {_owned, supervisor} = claim_and_supervise(root, ref)
    ack(root, ref, :private_supervisor, supervisor, :memory_store)
    store_pid = grant(root, ref, :memory_store)
    ack(root, ref, :memory_store, store_pid, :store_handle)
    store_handle = grant(root, ref, :store_handle)
    ack(root, ref, :store_handle, store_handle, :workspace_lease)

    Process.sleep(1_100)
    assert Process.alive?(root)
    assert Process.alive?(supervisor)
    assert Process.alive?(store_pid)
    send(root, {:grant, self(), ref, :workspace_lease, nil})
    refute_receive {:phase_result, ^root, ^ref, :workspace_lease, _}, 30
    assert Process.alive?(store_pid)
  end

  test "the full private child order reaches a blocked runtime and commit", %{tmp: tmp} do
    test = self()

    seams = %{
      store_new: fn module, pid ->
        send(test, {:store_new, pid})
        Store.new(module, pid)
      end,
      trace_handle: fn pid ->
        send(test, {:trace_handle, pid})
        Capability.handle(pid)
      end,
      runtime_holder: %{
        runtime_start: fn options ->
          send(test, {:runtime_start, options})
          supervisor = spawn_link(fn -> receive do: (:stop -> :ok) end)
          {:ok, %Runtime{supervisor: supervisor, token: make_ref()}}
        end
      },
      trace_bind: fn handle, runtime ->
        send(test, {:trace_bind, handle, runtime})
        :ok
      end
    }

    {root, ref} = start_root(tmp, seams)
    {_owned, supervisor} = claim_and_supervise(root, ref)
    ack(root, ref, :private_supervisor, supervisor, :memory_store)

    store_pid = grant(root, ref, :memory_store)
    refute_receive {:store_new, _}, 30
    ack(root, ref, :memory_store, store_pid, :store_handle)
    store_handle = grant(root, ref, :store_handle)
    assert_receive {:store_new, ^store_pid}
    ack(root, ref, :store_handle, store_handle, :workspace_lease)
    lease = grant(root, ref, :workspace_lease)
    assert is_pid(lease)
    ack(root, ref, :workspace_lease, lease, :executor)
    executor = grant(root, ref, :executor, [])
    assert is_pid(executor)
    ack(root, ref, :executor, executor, :trace_capability)
    trace_pid = grant(root, ref, :trace_capability)
    assert is_pid(trace_pid)
    refute_receive {:trace_handle, _}, 30
    ack(root, ref, :trace_capability, trace_pid, :trace_handle)
    trace_handle = grant(root, ref, :trace_handle)
    assert_receive {:trace_handle, ^trace_pid}
    ack(root, ref, :trace_handle, trace_handle, :runtime_holder)
    holder = grant(root, ref, :runtime_holder)
    refute_receive {:phase_ready, ^holder, ^ref, :runtime}, 30
    send(holder, {:grant, self(), ref, :runtime, []})
    refute_receive {:runtime_start, _}, 30
    ack(root, ref, :runtime_holder, holder, nil)
    assert_receive {:phase_ready, ^holder, ^ref, :runtime}

    send(holder, {:grant, self(), ref, :runtime, [runtime_id: "ephemeral-test"]})
    assert_receive {:runtime_start, [runtime_id: "ephemeral-test"]}
    assert_receive {:phase_result, ^holder, ^ref, :runtime, {:ok, runtime}}
    assert_receive {:phase_ready, ^root, ^ref, :trace_bind}
    send(root, {:grant, self(), ref, :trace_bind, nil})
    assert_receive {:trace_bind, ^trace_handle, ^runtime}
    assert_receive {:phase_result, ^root, ^ref, :trace_bind, :ok}
    assert_receive {:subtree_prepared, ^root, ^ref, prepared}
    assert prepared.runtime == runtime
    assert prepared.runtime_holder == holder
    assert prepared.store == %{pid: store_pid, handle: store_handle}
    assert prepared.trace_capability == %{pid: trace_pid, handle: trace_handle}
    assert prepared.executor == executor
    assert prepared.root.path |> String.starts_with?(tmp)
    send(root, {:commit, self(), ref})
    assert_receive {:subtree_committed, ^root, ^ref}
    assert Process.alive?(root)
    assert Process.alive?(runtime.supervisor)
  end

  test "runtime holder does not call the starter before an exact grant" do
    test = self()
    ref = make_ref()
    deadline = System.monotonic_time() + native(1_000)

    {:ok, holder} =
      RuntimeHolder.start_link(self(), self(), ref, deadline, %{
        runtime_start: fn options ->
          send(test, {:started, options})
          supervisor = spawn_link(fn -> receive do: (:stop -> :ok) end)
          {:ok, %Runtime{supervisor: supervisor, token: make_ref()}}
        end
      })

    Process.unlink(holder)
    on_exit(fn -> if Process.alive?(holder), do: Process.exit(holder, :kill) end)
    refute_receive {:started, _}, 30
    send(holder, {:grant, self(), ref, :runtime, []})
    refute_receive {:started, _}, 30
    send(holder, {self(), ref, :registered})
    assert_receive {:phase_ready, ^holder, ^ref, :runtime}
    send(holder, {:grant, self(), make_ref(), :runtime, []})
    refute_receive {:started, _}, 30
    send(holder, {:grant, self(), ref, :runtime, []})
    assert_receive {:started, []}
    assert_receive {:phase_result, ^holder, ^ref, :runtime, {:ok, runtime}}
    assert Process.alive?(runtime.supervisor)
  end

  test "a normal owner exit ends a still-blocked root without a temporary directory", %{tmp: tmp} do
    test = self()

    owner =
      spawn(fn ->
        ref = make_ref()
        deadline = System.monotonic_time() + native(1_000)
        {:ok, root} = SessionRoot.start_link(self(), ref, deadline, %{cwd: tmp})
        send(test, {:root, root})
        receive do: (:finish -> :ok)
      end)

    assert_receive {:root, root}
    monitor = Process.monitor(root)
    send(owner, :finish)
    assert_receive {:DOWN, ^monitor, :process, ^root, _}, 1_000
    assert File.ls!(tmp) == []
  end

  test "holder owner loss closes an already started runtime" do
    test = self()

    root =
      spawn(fn ->
        receive do
          {:register, holder, ref} -> send(holder, {self(), ref, :registered})
        end

        receive do: (:finish -> :ok)
      end)

    on_exit(fn -> if Process.alive?(root), do: Process.exit(root, :kill) end)

    owner =
      spawn(fn ->
        ref = make_ref()
        deadline = System.monotonic_time() + native(1_000)

        {:ok, holder} =
          RuntimeHolder.start_link(self(), root, ref, deadline, %{
            runtime_start: fn _options ->
              supervisor = spawn_link(fn -> receive do: (:finish -> :ok) end)
              send(test, {:runtime_supervisor, supervisor})
              {:ok, %Runtime{supervisor: supervisor, token: make_ref()}}
            end
          })

        send(test, {:holder, holder, ref})
        receive do: (:grant -> :ok)
        send(root, {:register, holder, ref})

        receive do
          {:phase_ready, ^holder, ^ref, :runtime} -> :ok
        end

        send(holder, {:grant, self(), ref, :runtime, []})

        receive do
          {:phase_result, ^holder, ^ref, :runtime, {:ok, _runtime}} -> :ok
        end

        send(test, :owner_finished)
      end)

    assert_receive {:holder, holder, _ref}
    holder_monitor = Process.monitor(holder)
    send(owner, :grant)
    assert_receive {:runtime_supervisor, supervisor}
    supervisor_monitor = Process.monitor(supervisor)
    assert_receive :owner_finished
    assert_receive {:DOWN, ^holder_monitor, :process, ^holder, _}, 1_000
    assert_receive {:DOWN, ^supervisor_monitor, :process, ^supervisor, _}, 1_000
  end

  defp start_root(tmp, seams \\ %{}, deadline_ms \\ 5_000) do
    ref = make_ref()
    deadline = System.monotonic_time() + native(deadline_ms)
    seams = Map.put_new(seams, :temp_root, %{tmp: fn -> tmp end})
    {:ok, root} = SessionRoot.start_link(self(), ref, deadline, %{cwd: tmp}, seams)
    Process.unlink(root)
    on_exit(fn -> if Process.alive?(root), do: Process.exit(root, :kill) end)
    {root, ref}
  end

  defp claim_and_supervise(root, ref) do
    assert_receive {:root_ready, ^root, ^ref}, 1_000
    assert_receive {:phase_ready, ^root, ^ref, :candidate_prepare}, 1_000
    send(root, {:grant, self(), ref, :candidate_prepare, nil})
    assert_receive {:phase_result, ^root, ^ref, :candidate_prepare, {:ok, _candidate}}, 1_000
    assert_receive {:phase_ready, ^root, ^ref, :root_claim}, 1_000
    send(root, {:grant, self(), ref, :root_claim, nil})
    assert_receive {:phase_result, ^root, ^ref, :root_claim, {:ok, owned}}, 1_000
    assert_receive {:phase_ready, ^root, ^ref, :private_supervisor}, 1_000
    send(root, {:grant, self(), ref, :private_supervisor, nil})
    assert_receive {:phase_result, ^root, ^ref, :private_supervisor, {:ok, supervisor}}, 1_000
    {owned, supervisor}
  end

  defp grant(root, ref, phase, payload \\ nil) do
    send(root, {:grant, self(), ref, phase, payload})
    assert_receive {:phase_result, ^root, ^ref, ^phase, {:ok, result}}, 1_000
    result
  end

  defp ack(root, ref, phase, result, next) do
    send(root, {:ack, self(), ref, phase, result})
    if next, do: assert_receive({:phase_ready, ^root, ^ref, ^next}, 1_000)
  end

  defp native(ms), do: System.convert_time_unit(ms, :millisecond, :native)
end
