Code.require_file("support/delegation_parent_binding_fixture.exs", __DIR__)

defmodule LoopexComposition.DelegationParentBindingTest do
  use ExUnit.Case, async: false

  alias Loopex.Runtime
  alias Loopex.Store
  alias Loopex.Store.{Local, Memory}
  alias LoopexComposition.Delegation.{GenesisCodec, LedgerCodec, ParentBinding, Tool}
  alias LoopexComposition.DelegationParentBindingFixture, as: Fixture
  alias LoopexProtocol.Frame

  defmodule NoHistoryStore do
    @moduledoc false
    @behaviour Store
    @impl Store
    defdelegate transact(reference, tx), to: Memory
    @impl Store
    defdelegate transaction_status(reference, session, domain, tx), to: Memory
    @impl Store
    defdelegate runtime_command(reference, command), to: Memory
    @impl Store
    defdelegate ownership_head(reference, session, domain), to: Memory
    @impl Store
    defdelegate load_records(reference, session, after_version, limit), to: Memory
    @impl Store
    defdelegate load_events(reference, session, after_sequence, limit), to: Memory
  end

  test "independent literal preimages bind opaque scope, mutation bytes and original result" do
    {:ok, fixture} =
      Frame.decode(
        String.trim_trailing(
          File.read!(Path.join(__DIR__, "fixtures/delegation/parent-binding-v1.json")),
          "\n"
        ),
        1_048_576
      )

    assert fixture["version"] == 1
    ids = Enum.map(fixture["identity"], &Base.decode64!/1)
    assert {:ok, key} = LedgerCodec.header_key(:binding, ids)
    assert key == fixture["binding_key"]
    assert hash("loopex:helper-binding:v1" <> <<0>> <> fixture["identity_json"]) == key

    for row <- fixture["vectors"] do
      tx = row["transaction"]
      assert {:ok, ^tx} = ParentBinding.transaction(key, tx["expected_version"], tx["mutation"])
      assert hash("loopex:helper-tx:v1" <> <<0>> <> row["tx_preimage"]) == tx["tx_id"]

      assert hash("loopex:helper-mutation:v1" <> <<0>> <> row["mutation_preimage"]) ==
               tx["mutation_digest"]

      assert {:ok, encoded} = LedgerCodec.encode_json(tx, :frame)
      assert encoded == row["transaction_json"]
      assert {:ok, result} = LedgerCodec.decode_json(row["result_json"], :frame)
      assert result == row["result"]
      assert {:ok, frame} = LedgerCodec.encode_frame(encoded)
      assert byte_size(frame) == row["frame_bytes"]
    end
  end

  test "captured objects preserve original opaque options and exact task and role settings" do
    {catalog, declaration, creation} = objects()
    assert {:ok, capture} = capture(catalog, declaration, creation)
    assert capture.options == %{"opaque" => <<255, 0, 128>>, "purpose" => "retained"}
    assert capture.genesis["options"] == capture.options
    assert capture.object_bytes == Enum.map([catalog, declaration, creation], &json/1)
    assert capture.creation_sha256 == hash(json(creation))
    assert capture.declaration["roles"] == ["inspect"]
    state = ParentBinding.new(capture)
    assert state.phase == :empty and state.version == 0 and state.credit == 0
    assert state.bytes == byte_size(capture.header)
  end

  test "catalog refuses open members, duplicate or unordered roles and non-environment credentials" do
    {catalog, declaration, creation} = objects()
    role = hd(catalog["roles"])

    invalid = [
      Map.put(catalog, "extra", nil),
      Map.delete(catalog, "providers"),
      %{catalog | "runtime_id" => Base.encode64("other")},
      %{catalog | "roles" => []},
      %{catalog | "roles" => [role, role]},
      %{catalog | "roles" => [Map.put(role, "name", "z"), Map.put(role, "name", "a")]},
      %{catalog | "roles" => [Map.put(role, "name", "inspect\n")]},
      %{catalog | "providers" => %{"ollama" => %{"credential" => %{"none" => true}}}},
      %{catalog | "providers" => %{"anthropic" => %{"credential" => %{"env" => "PATH"}}}}
    ]

    for changed <- invalid,
        do: assert(capture(changed, declaration, creation) == {:error, :invalid_parent_capture})
  end

  test "roles require four immutable read tools, refuse policy defer and an existing model route" do
    {catalog, declaration, creation} = objects()
    {:ok, role} = GenesisCodec.decode(hd(catalog["roles"])["genesis"])

    for changed <- [
          Map.put(role, "policy_defer_mode", "admit"),
          genesis([Tool.definition()]),
          genesis([]),
          put_in(role, ["initial_configuration", "model"], "unknown:literal")
        ] do
      # Encode admitted variants through the owning codec; malformed Core
      # metadata is retained as raw ETF to exercise its reader refusal.
      envelope =
        case GenesisCodec.encode(changed) do
          {:ok, value} -> value
          _ -> envelope(:erlang.term_to_binary(changed, [:deterministic]))
        end

      changed_catalog =
        put_in(catalog, ["roles"], [%{"name" => "inspect", "genesis" => envelope}])

      assert capture(changed_catalog, declaration, creation) == {:error, :invalid_parent_capture}
    end
  end

  test "declaration joins authored role order, exact budgets and closed positive quantity domains" do
    {catalog, declaration, creation} = objects()
    budget = hd(declaration["role_budgets"])

    invalid = [
      Map.put(declaration, "extra", nil),
      %{declaration | "enabled" => false},
      %{declaration | "roles" => ["missing"]},
      %{declaration | "roles" => ["inspect", "inspect"]},
      %{declaration | "max_children" => 129},
      %{declaration | "token_budget" => 0},
      %{declaration | "max_tokens" => 1023},
      %{declaration | "role_budgets" => []},
      %{declaration | "role_budgets" => [Map.put(budget, "context_token_budget", 8193)]},
      %{
        declaration
        | "role_budgets" => [Map.put(budget, "system_class_tokens", 18_446_744_073_709_551_616)]
      },
      put_in(declaration, ["child_bounds", "deadline_ms"], 600_001)
    ]

    for changed <- invalid,
        do: assert(capture(catalog, changed, creation) == {:error, :invalid_parent_capture})
  end

  test "unbounded private token quantities retain exact integers beyond uint64" do
    {catalog, declaration, creation} = objects()
    changed = %{declaration | "token_budget" => 18_446_744_073_709_551_616}
    changed_creation = rehash(%{creation | "declaration_sha256" => hash(json(changed))})
    assert {:ok, capture} = capture(catalog, changed, changed_creation)
    assert capture.declaration["token_budget"] == 18_446_744_073_709_551_616
  end

  test "catalog sorting and authored enabled order remain distinct exact captures" do
    {catalog, declaration, creation} = objects()
    role = hd(catalog["roles"])
    budget = hd(declaration["role_budgets"])

    catalog = %{
      catalog
      | "roles" => [Map.put(role, "name", "alpha"), Map.put(role, "name", "zeta")]
    }

    declaration = %{
      declaration
      | "roles" => ["zeta", "alpha"],
        "role_budgets" => [Map.put(budget, "role", "zeta"), Map.put(budget, "role", "alpha")]
    }

    creation =
      rehash(%{
        creation
        | "catalog_sha256" => hash(json(catalog)),
          "declaration_sha256" => hash(json(declaration))
      })

    assert {:ok, captured} = capture(catalog, declaration, creation)
    assert captured.declaration["roles"] == ["zeta", "alpha"]
    reversed = %{declaration | "role_budgets" => Enum.reverse(declaration["role_budgets"])}
    assert capture(catalog, reversed, creation) == {:error, :invalid_parent_capture}
  end

  test "creation binds all object bytes, original Core transaction and actual task generation" do
    {catalog, declaration, creation} = objects()

    invalid = [
      Map.put(creation, "extra", nil),
      Map.delete(creation, "original_options"),
      %{creation | "command_id" => Base.encode64("other")},
      %{creation | "runtime_id" => Base.encode64("other")},
      %{creation | "input_digest" => String.duplicate("0", 64)},
      rehash(%{creation | "catalog_sha256" => String.duplicate("0", 64)}),
      rehash(%{creation | "declaration_sha256" => String.duplicate("0", 64)}),
      %{creation | "canonical_create_digest" => String.duplicate("0", 64)},
      rehash(
        put_in(creation, ["task_generation", "definition_digest"], String.duplicate("0", 64))
      ),
      rehash(%{
        creation
        | "original_options" => envelope(:erlang.term_to_binary(%{"changed" => true}))
      })
    ]

    for changed <- invalid,
        do: assert(capture(catalog, declaration, changed) == {:error, :invalid_parent_capture})
  end

  test "original options refuse unsafe, compressed, trailing, oversized and noncanonical ETF envelopes" do
    {catalog, declaration, creation} = objects()
    options = Base.decode64!(creation["original_options"]["bytes"])
    compressed = :erlang.term_to_binary(%{"x" => String.duplicate("x", 1024)}, [:compressed])
    assert <<131, 80, _::binary>> = compressed

    invalid = [
      envelope(:erlang.term_to_binary(self())),
      envelope(:erlang.term_to_binary(%{"pid" => self()})),
      envelope(compressed),
      envelope(options <> <<0>>),
      envelope(:erlang.term_to_binary(%{"x" => String.duplicate("x", 65_537)})),
      envelope(:erlang.term_to_binary(["not a map"])),
      Map.put(creation["original_options"], "extra", false),
      Map.put(
        creation["original_options"],
        "bytes",
        creation["original_options"]["bytes"] <> "\n"
      )
    ]

    for changed <- invalid do
      assert capture(catalog, declaration, rehash(%{creation | "original_options" => changed})) ==
               {:error, :invalid_parent_capture}
    end
  end

  test "canonical retained object admission rejects duplicate members and altered byte spellings" do
    {catalog, declaration, creation} = objects()

    for bytes <- [
          json(catalog) <> "\n",
          " " <> json(catalog),
          String.replace(json(catalog), "\"version\":1", "\"version\":1.0"),
          String.replace(json(catalog), "\"version\":1", "\"version\":1,\"version\":1")
        ] do
      assert ParentBinding.capture("runtime", "create", bytes, json(declaration), json(creation)) ==
               {:error, :invalid_parent_capture}
    end
  end

  test "prepare reserves one maximum frame until exact historical bind consumes it" do
    capture = valid_capture()
    state = ParentBinding.new(capture)

    {:ok, prepare} =
      ParentBinding.transaction(capture.key, 0, ParentBinding.prepare_mutation(capture))

    assert {:ok, prepared, result} = ParentBinding.admit(state, prepare)

    assert result["ledger_version"] == 1 and prepared.credit == 65_614 and
             prepared.phase == :prepared

    {:ok, bind} =
      ParentBinding.transaction(capture.key, 1, ParentBinding.bind_mutation(capture, "session"))

    for missing <- [:unobserved, :absent, :conflict, :unavailable, {:commit_unknown, "tx"}] do
      assert ParentBinding.admit(prepared, bind, missing) ==
               {:error, :creation_history_unavailable}

      assert prepared.credit == 65_614 and prepared.version == 1
    end

    assert {:ok, bound, closing} =
             ParentBinding.admit(prepared, bind, {:historical, row(capture, "session")})

    assert bound.credit == 0 and bound.phase == :bound and bound.parent == "session"
    assert closing["ledger_version"] == 2
  end

  test "identical API replay returns the original result before stale-version checks while changed bytes conflict" do
    capture = valid_capture()
    {:ok, tx} = ParentBinding.transaction(capture.key, 0, ParentBinding.prepare_mutation(capture))
    assert {:ok, prepared, result} = ParentBinding.admit(ParentBinding.new(capture), tx)
    assert {:ok, ^prepared, ^result} = ParentBinding.admit(prepared, tx)

    {:ok, changed} =
      ParentBinding.transaction(capture.key, 1, ParentBinding.prepare_mutation(capture))

    assert ParentBinding.admit(prepared, changed) == {:error, :binding_conflict}
    altered = Map.put(tx, "mutation_digest", String.duplicate("0", 64))
    assert ParentBinding.admit(prepared, altered) == {:error, :invalid_binding_transaction}
  end

  test "every prefix preserves order and duplicate appended transactions cannot masquerade as re-presentation" do
    capture = valid_capture()

    {:ok, prepare} =
      ParentBinding.transaction(capture.key, 0, ParentBinding.prepare_mutation(capture))

    {:ok, bind} =
      ParentBinding.transaction(capture.key, 1, ParentBinding.bind_mutation(capture, "session"))

    history = {:historical, row(capture, "session")}

    for {transactions, phase} <- [{[], :empty}, {[prepare], :prepared}, {[prepare, bind], :bound}] do
      assert {:ok, replayed} = ParentBinding.replay(capture, transactions, history)
      assert replayed.phase == phase
    end

    assert ParentBinding.replay(capture, [prepare, prepare], history) ==
             {:error, :duplicate_appended_transaction}

    assert ParentBinding.replay(capture, [bind], history) == {:error, :stale_binding_version}

    assert ParentBinding.replay(capture, [bind, prepare], history) ==
             {:error, :stale_binding_version}

    assert ParentBinding.replay(capture, [prepare, bind, bind], history) ==
             {:error, :invalid_binding_prefix}
  end

  test "same-kind mutation shape, stale versions, unsupported operations and foreign scope refuse" do
    capture = valid_capture()
    state = ParentBinding.new(capture)
    mutation = ParentBinding.prepare_mutation(capture)
    {:ok, gap} = ParentBinding.transaction(capture.key, 2, mutation)
    assert ParentBinding.admit(state, gap) == {:error, :stale_binding_version}

    for changed <- [
          Map.put(mutation, "extra", true),
          Map.put(mutation, "closing_credit_bytes", 65_613),
          Map.put(mutation, "command_id", Base.encode64("other"))
        ] do
      {:ok, tx} = ParentBinding.transaction(capture.key, 0, changed)
      assert ParentBinding.admit(state, tx) == {:error, :invalid_binding_transition}
    end

    assert ParentBinding.transaction(capture.key, 0, %{"kind" => "reserve_child"}) ==
             {:error, :invalid_binding_transaction}

    {:ok, foreign} = ParentBinding.transaction(String.duplicate("f", 64), 0, mutation)
    assert ParentBinding.admit(state, foreign) == {:error, :invalid_binding_transaction}
  end

  test "closed history must match runtime command genesis digest and actual result tuple" do
    capture = valid_capture()
    {:ok, tx} = ParentBinding.transaction(capture.key, 0, ParentBinding.prepare_mutation(capture))
    {:ok, prepared, _} = ParentBinding.admit(ParentBinding.new(capture), tx)

    {:ok, bind} =
      ParentBinding.transaction(capture.key, 1, ParentBinding.bind_mutation(capture, "session"))

    actual = row(capture, "session")

    for changed <- [
          Map.put(actual, :extra, nil),
          %{actual | runtime_id: "other"},
          %{actual | command_id: "other"},
          %{actual | session_id: "forged"},
          %{actual | genesis_version: 2},
          %{actual | canonical_create_digest: String.duplicate("0", 64)},
          nil
        ] do
      assert ParentBinding.admit(prepared, bind, {:historical, changed}) ==
               {:error, :creation_history_conflict}
    end
  end

  test "exact cap arithmetic includes physical header frame and retained closing credit" do
    capture = valid_capture()
    state = ParentBinding.new(capture)
    {:ok, tx} = ParentBinding.transaction(capture.key, 0, ParentBinding.prepare_mutation(capture))
    {:ok, bytes} = LedgerCodec.encode_json(tx, :frame)
    {:ok, frame} = LedgerCodec.encode_frame(bytes)
    threshold = 1_048_576 - byte_size(frame) - 65_614

    for previous <- [threshold - 1, threshold] do
      assert {:ok, prepared, _} = ParentBinding.admit(%{state | bytes: previous}, tx)
      assert prepared.bytes + prepared.credit <= 1_048_576
    end

    assert ParentBinding.admit(%{state | bytes: threshold + 1}, tx) ==
             {:error, :binding_byte_limit}
  end

  test "an actual Store without the optional history callback remains unavailable rather than absent" do
    capture = valid_capture()
    {:ok, store_pid} = Memory.start_link()
    on_exit(fn -> if Process.alive?(store_pid), do: GenServer.stop(store_pid) end)
    {:ok, store} = Store.new(NoHistoryStore, store_pid)
    {:ok, transaction} = Store.create_session(capture.runtime, capture.command, capture.genesis)
    assert {:committed, _, _} = Store.transact(store, transaction)

    {:ok, runtime} =
      Loopex.start_link(runtime_id: capture.runtime, context_token_budget: 8_192, store: store)

    on_exit(fn -> if Runtime.alive?(runtime), do: Loopex.stop(runtime) end)
    before = :sys.get_state(store_pid)
    assert ParentBinding.observe_creation(runtime, capture) == {:ok, :store_unavailable}
    assert before == :sys.get_state(store_pid)
    monitor = Process.monitor(runtime.supervisor)
    assert :ok = Loopex.stop(runtime)
    assert_receive {:DOWN, ^monitor, :process, _, _}, 5_000
    stop_join(store_pid)
  end

  for adapter <- [Memory, Local] do
    @adapter adapter
    test "#{inspect(adapter)} actual writer history joins without session activation or Store mutation" do
      capture = valid_capture()

      root =
        Path.join(
          System.tmp_dir!(),
          "m7-parent-binding-#{Base.encode16(:crypto.strong_rand_bytes(12))}"
        )

      File.mkdir_p!(root)
      on_exit(fn -> File.rm_rf!(root) end)
      options = if @adapter == Local, do: [path: Path.join(root, "store.log")], else: []
      {:ok, first} = @adapter.start_link(options)
      {:ok, store} = Store.new(@adapter, first)
      {:ok, transaction} = Store.create_session(capture.runtime, capture.command, capture.genesis)
      assert {:committed, _, receipt} = Store.transact(store, transaction)
      session = receipt.session_id

      store_pid =
        if @adapter == Local do
          stop_join(first)
          {:ok, reopened} = Local.start_link(options)
          reopened
        else
          first
        end

      on_exit(fn -> if Process.alive?(store_pid), do: GenServer.stop(store_pid) end)
      {:ok, selected_store} = Store.new(@adapter, store_pid)

      {:ok, runtime} =
        Loopex.start_link(
          runtime_id: capture.runtime,
          context_token_budget: 8_192,
          store: selected_store
        )

      on_exit(fn -> if Runtime.alive?(runtime), do: Loopex.stop(runtime) end)
      {:ok, %{sessions: sessions}} = Runtime.children(runtime)
      assert DynamicSupervisor.which_children(sessions) == []

      before =
        if @adapter == Local,
          do: File.read!(Keyword.fetch!(options, :path)),
          else: :sys.get_state(store_pid)

      assert {:ok, {:historical, actual}} = ParentBinding.observe_creation(runtime, capture)
      assert actual == row(capture, session)

      {:ok, prepare} =
        ParentBinding.transaction(capture.key, 0, ParentBinding.prepare_mutation(capture))

      {:ok, bind} =
        ParentBinding.transaction(capture.key, 1, ParentBinding.bind_mutation(capture, session))

      assert {:ok, bound} = ParentBinding.replay(capture, [prepare, bind], {:historical, actual})
      assert bound.parent == session

      assert ParentBinding.observe_creation(runtime, %{capture | command: "missing"}) ==
               {:ok, :absent}

      changed = put_in(capture.genesis, ["runtime_configuration", "cleanup_grace_ms"], 5_001)

      assert ParentBinding.observe_creation(runtime, %{capture | genesis: changed}) ==
               {:ok, :conflict}

      assert DynamicSupervisor.which_children(sessions) == []

      after_read =
        if @adapter == Local,
          do: File.read!(Keyword.fetch!(options, :path)),
          else: :sys.get_state(store_pid)

      assert before == after_read
      runtime_monitor = Process.monitor(runtime.supervisor)
      assert :ok = Loopex.stop(runtime)
      assert_receive {:DOWN, ^runtime_monitor, :process, _, _}, 5_000
      stop_join(store_pid)
      assert ParentBinding.observe_creation(runtime, capture) == {:error, :runtime_unavailable}
    end
  end

  defp objects, do: Fixture.objects()
  defp genesis(definitions), do: Fixture.genesis(definitions)
  defp valid_capture, do: Fixture.valid_capture()

  defp capture(catalog, declaration, creation),
    do: Fixture.capture(catalog, declaration, creation)

  defp json(value), do: Fixture.json(value)
  defp rehash(creation), do: Fixture.rehash(creation)
  defp envelope(bytes), do: Fixture.envelope(bytes)

  defp row(capture, session),
    do: %{
      version: 1,
      runtime_id: capture.runtime,
      command_id: capture.command,
      session_id: session,
      genesis_version: 3,
      canonical_create_digest: capture.creation["canonical_create_digest"]
    }

  defp hash(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  defp stop_join(pid) do
    monitor = Process.monitor(pid)
    :ok = GenServer.stop(pid)
    assert_receive {:DOWN, ^monitor, :process, ^pid, _}, 5_000
  end
end
