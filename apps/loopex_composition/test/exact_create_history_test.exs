Code.require_file("../../loopex/test/support/configured_genesis_helper.exs", __DIR__)

defmodule LoopexComposition.ExactCreateHistoryTest do
  use ExUnit.Case, async: false

  alias Loopex.Runtime
  alias Loopex.Store
  alias Loopex.Store.Local
  alias Loopex.Store.Memory

  for adapter <- [Memory, Local] do
    @adapter adapter

    test "#{inspect(adapter)} reads current exact creation through the public facade after runtime replacement" do
      root =
        Path.join(
          System.tmp_dir!(),
          "loopex-m7-history-#{Base.encode16(:crypto.strong_rand_bytes(12))}"
        )

      File.mkdir_p!(root)
      on_exit(fn -> File.rm_rf!(root) end)

      version = 3
      path = Path.join(root, "history-#{version}.log")
      options = if @adapter == Local, do: [path: path], else: []
      {:ok, first_store} = @adapter.start_link(options)
      on_exit(fn -> stop_store(first_store) end)
      runtime = start_runtime(@adapter, first_store, 1_500)
      original_options = %{"purpose" => "retained-#{version}"}

      genesis =
        Loopex.ConfiguredGenesisFixture.genesis([])
        |> Map.put("options", original_options)
        |> put_in(["runtime_configuration", "cleanup_grace_ms"], 1_500)

      assert {:ok, session} =
               Loopex.create_session(runtime, original_options,
                 command_id: "create",
                 genesis: genesis
               )

      :ok = Loopex.stop(runtime)

      # Local reconstructs its retained command binding from the actual log.
      # Memory keeps its live Store, whose contract promises no persistence.
      store =
        if @adapter == Local do
          :ok = GenServer.stop(first_store)
          {:ok, reopened} = Local.start_link(path: path)
          on_exit(fn -> stop_store(reopened) end)
          reopened
        else
          first_store
        end

      successor = start_runtime(@adapter, store, 3_000)
      {:ok, %{sessions: supervisor}} = Runtime.children(successor)
      assert DynamicSupervisor.which_children(supervisor) == []
      before = if @adapter == Local, do: File.read!(path), else: :sys.get_state(store)

      {:ok, transaction} = Store.create_session("m7-exact-history", "create", genesis)

      projection = %{
        version: 1,
        runtime_id: "m7-exact-history",
        command_id: "create",
        session_id: session,
        genesis_version: version,
        canonical_create_digest:
          Base.encode16(transaction.canonical_mutation_digest, case: :lower)
      }

      assert {:ok, {:historical, ^projection}} =
               Loopex.creation_provenance(successor, %{kind: :command, command_id: "create"})

      assert {:ok, {:historical, ^projection}} =
               Loopex.creation_provenance(successor, %{kind: :session, session_id: session})

      assert {:ok, {:page, page}} =
               Loopex.creation_provenance(successor, %{
                 kind: :runtime_page,
                 cursor: nil,
                 limit: 16
               })

      assert page.rows == [Map.put(projection, :create_ordinal, 1)]
      assert page.through_create_ordinal == 1
      assert is_nil(page.next_cursor)

      assert {:ok, {:historical, ^session}} =
               Loopex.lookup_create_result(successor, "create", original_options, genesis)

      changed = put_in(genesis, ["runtime_configuration", "cleanup_grace_ms"], 1_501)

      assert {:ok, :conflict} =
               Loopex.lookup_create_result(successor, "create", original_options, changed)

      assert {:ok, :absent} =
               Loopex.lookup_create_result(successor, "absent", original_options, genesis)

      after_reads = if @adapter == Local, do: File.read!(path), else: :sys.get_state(store)
      assert before == after_reads
      assert DynamicSupervisor.which_children(supervisor) == []
      :ok = Loopex.stop(successor)
      :ok = GenServer.stop(store)
    end
  end

  defp start_runtime(adapter, pid, grace) do
    {:ok, store} = Store.new(adapter, pid)

    {:ok, runtime} =
      Loopex.start_link(
        runtime_id: "m7-exact-history",
        context_token_budget: 8_192,
        cleanup_grace_ms: grace,
        store: store
      )

    on_exit(fn -> if Runtime.alive?(runtime), do: Loopex.stop(runtime) end)
    runtime
  end

  defp stop_store(pid), do: if(Process.alive?(pid), do: GenServer.stop(pid))
end
