Code.require_file("support/delegation_parent_binding_fixture.exs", __DIR__)

defmodule LoopexComposition.DelegationRunLedgerTest do
  use ExUnit.Case, async: false

  alias Loopex.{Executor, Runtime, Store}
  alias Loopex.Store.{Local, Memory}

  alias LoopexComposition.Delegation.{
    GenesisCodec,
    LedgerCodec,
    ParentBinding,
    RunLedger,
    RunMutation,
    Tool
  }

  alias LoopexComposition.DelegationParentBindingFixture, as: Fixture
  alias LoopexProtocol.Canonical

  @frame 65_614
  @cap 16_777_216
  @identity_json "[\"cnVudGltZQ==\",\"c2Vzc2lvbg==\",\"cnVu\"]"
  @key "e76610004d2828f78a29df753e3b1e4fcf77c51cd135b45d637bd93c2eaa3e0b"
  # Concept: literals describe each complete prelaunch projection independently.
  # Technical depth: count/token/credit/version expectations are authored values;
  # neither the implementation nor its returned state generates these constants.
  @projections [
    {"initialize", 1, 0, 0, 0, :initialized},
    {"first reserve", 2, 1, 8_192, 328_070, :reserved},
    {"second reserve", 3, 1, 8_192, 393_684, :reserved},
    {"first stop", 4, 1, 8_192, 328_070, :stopped}
  ]

  for {name, version, count, reserved, credit, phase} <- @projections do
    @projection {version, count, reserved, credit, phase}
    test "independent ordered projection #{name}" do
      context = fixture()
      {_state, entries} = complete_prefix(context)
      entries = Enum.take(entries, elem(@projection, 0))
      assert {:ok, state} = replay(context, entries)

      assert {state.version, state.count, state.reserved_tokens, state.credit, state.phase} ==
               @projection

      assert state.charged_tokens == 0

      assert state.bytes ==
               byte_size(state.header) +
                 Enum.sum(Enum.map(entries, fn {tx, _} -> frame_size(tx) end))

      assert state.bytes + state.credit <= @cap
    end
  end

  test "independent opaque header and full transaction/result preimages remain exact" do
    context = fixture()
    assert {:ok, @key} = LedgerCodec.header_key(:run, context.ids)
    assert domain_bytes("loopex:helper-run:v1", @identity_json) == @key
    {_state, entries} = complete_prefix(context)

    for {tx, _} <- entries do
      mutation = tx["mutation"]

      target =
        case mutation["kind"] do
          "initialize" -> []
          "reserve" -> [mutation["operation_identity"], mutation["job"]["job_id"]]
          "stop" -> mutation["operation_identity"]
        end

      assert tx["tx_id"] == domain("loopex:helper-tx:v1", [@key, mutation["kind"], target])

      assert tx["mutation_digest"] ==
               domain("loopex:helper-mutation:v1", [@key, tx["expected_version"], mutation])

      assert {:ok, state} = replay(context, Enum.take(entries, tx["expected_version"] + 1))

      assert List.last(state.transactions) ==
               {tx,
                %{
                  "version" => 1,
                  "tx_id" => tx["tx_id"],
                  "ledger_version" => tx["expected_version"] + 1,
                  "mutation_digest" => tx["mutation_digest"]
                }}
    end
  end

  test "mutable parent projections cannot repair original bytes or missing historical binding" do
    context = fixture()

    changed = %{
      context.capture
      | declaration: %{"token_budget" => 1},
        key: String.duplicate("0", 64)
    }

    assert {:ok, state} = RunLedger.new(context.ids, changed, context.binding, context.history)
    assert state.capture == context.capture and state.binding_key == context.capture.key

    assert RunLedger.new(context.ids, context.capture, [], context.history) ==
             {:error, :invalid_run_capture}

    assert RunLedger.new(context.ids, context.capture, context.binding, :unobserved) ==
             {:error, :invalid_run_capture}

    changed = %{changed | object_bytes: ["{}" | tl(changed.object_bytes)]}

    assert RunLedger.new(context.ids, changed, context.binding, context.history) ==
             {:error, :invalid_run_capture}

    for ids <- [
          ["other", "session", "run"],
          ["runtime", "other", "run"],
          [],
          nil,
          ["runtime", "session", ""]
        ] do
      assert RunLedger.new(ids, context.capture, context.binding, context.history) ==
               {:error, :invalid_run_capture}
    end
  end

  test "initialize must be first and join every captured parent declaration member" do
    context = fixture()
    mutation = RunLedger.initialize_mutation(context.state)

    for field <- ~w(binding_key catalog_sha256 declaration_sha256) do
      tx = transaction(context.state, Map.put(mutation, field, String.duplicate("0", 64)))
      assert RunLedger.admit(context.state, tx) == {:error, :run_binding_mismatch}
    end

    changed = put_in(mutation, ["limits", "max_children"], 1)

    assert RunLedger.admit(context.state, transaction(context.state, changed)) ==
             {:error, :run_binding_mismatch}

    {ready, initialize} = initialized(context)
    assert RunLedger.admit(ready, initialize) == {:ok, ready, elem(hd(ready.transactions), 1)}

    assert RunLedger.admit(ready, transaction(ready, mutation)) ==
             {:error, :run_transaction_conflict}

    {tx, inputs} = reservation(context, context.state, job(context, 1))
    assert RunLedger.admit(context.state, tx, inputs) == {:error, :invalid_run_transition}
  end

  test "canonical byte admission refuses changed hashes alternate spelling and native values" do
    context = fixture()
    {state, tx} = initialized(context)

    assert RunLedger.admit_bytes(context.state, json(tx)) ==
             {:ok, state, elem(hd(state.transactions), 1)}

    for bytes <- [" " <> json(tx), json(tx) <> "\n", self()] do
      assert {:error, _} = RunLedger.admit_bytes(context.state, bytes)
    end

    for changed <- [
          Map.put(tx, "mutation_digest", String.duplicate("0", 64)),
          Map.put(tx, "extra", nil),
          nil
        ] do
      assert RunLedger.admit(context.state, changed) == {:error, :invalid_run_transaction}
    end
  end

  test "exact original duplicates retain results before stale checks and changed bytes conflict" do
    context = fixture()
    {state, entries} = complete_prefix(context)

    for {tx, _inputs} <- entries do
      result = elem(Enum.at(state.transactions, tx["expected_version"]), 1)
      assert RunLedger.admit(state, tx) == {:ok, state, result}
      assert RunLedger.admit_bytes(state, json(tx)) == {:ok, state, result}
    end

    {first, inputs} = Enum.at(entries, 1)

    for mutation <- [
          put_in(first["mutation"], ["source_intent", "journal_version"], 2),
          Map.put(first["mutation"], "absolute_cutoff_ms", 9_999)
        ] do
      changed = transaction(context.ids, first["expected_version"], mutation)
      assert changed["tx_id"] == first["tx_id"]
      assert RunLedger.admit(state, changed, inputs) == {:error, :run_transaction_conflict}
    end

    changed = transaction(context.ids, state.version, first["mutation"])
    assert RunLedger.admit(state, changed, inputs) == {:error, :run_transaction_conflict}
  end

  test "distinct stale transactions refuse before original jobs join and receipts gain credit" do
    context = fixture()
    {state, _tx, _inputs} = first_reserved(context)
    {tx, inputs} = reservation(context, state, job(context, 2))
    stale = transaction(context.ids, state.version - 1, tx["mutation"])
    assert RunLedger.admit(state, stale, inputs) == {:error, :stale_run_version}
  end

  test "each reservation requires the actual matching validated original helper JobRequest" do
    context = fixture()
    {ready, _} = initialized(context)
    original = job(context, 1)
    {tx, inputs} = reservation(context, ready, original)
    assert :ok = Executor.validate_job(original)
    assert :ok = RunMutation.match_job(context.ids, tx["mutation"], original)
    assert RunLedger.admit(ready, tx, %{}) == {:error, :original_job_mismatch}
    other = job(context, 2)
    assert :ok = Executor.validate_job(other)

    assert RunLedger.admit(ready, tx, %{inputs | original_job: other}) ==
             {:error, :original_job_mismatch}
  end

  test "reservation recomputes positive R and all closing credit rather than caller money" do
    context = fixture()
    {ready, _} = initialized(context)
    {tx, inputs} = reservation(context, ready, job(context, 1))

    for field <- ~w(reserved_tokens closing_credit_bytes),
        value <- [1, tx["mutation"][field] + 1] do
      changed = transaction(ready, Map.put(tx["mutation"], field, value))
      assert RunLedger.admit(ready, changed, inputs) == {:error, :reservation_mismatch}
    end

    {small, _tx, _inputs} = first_reserved(fixture(parent_with_limits(3_000, 8_192)))
    assert small.reserved_tokens == 3_000 and small.count == 1
  end

  test "huge integer allowances remain exact without clamps during reserve replay and stop" do
    large = Integer.pow(2, 100)
    context = fixture(parent_with_limits(large + 7, large))
    {state, entries} = complete_prefix(context)
    assert state.reserved_tokens == large and state.count == 1
    assert state.capture.declaration["token_budget"] == large + 7
    assert state.charged_tokens == 0 and state.credit == 328_070
    assert {:ok, ^state} = replay(context, entries)
  end

  test "first reserve accepts the original effective deadline and refuses exactly its next millisecond" do
    context = fixture()
    {ready, initialize} = initialized(context)
    original = job(context, 1)
    cutoff = original.effective_job_deadline
    {equal, inputs} = reservation_at(context, ready, original, cutoff)
    assert {:ok, admitted, result} = RunLedger.admit(ready, equal, inputs)
    assert admitted.operation.logical["absolute_cutoff_ms"] == cutoff
    assert {:ok, ^admitted} = replay(context, [{initialize, %{}}, {equal, inputs}])
    assert RunLedger.admit(admitted, equal) == {:ok, admitted, result}

    {late, late_inputs} = reservation_at(context, ready, original, cutoff + 1)

    assert Map.delete(late["mutation"], "absolute_cutoff_ms") ==
             Map.delete(equal["mutation"], "absolute_cutoff_ms")

    assert late_inputs == inputs
    assert RunLedger.admit(ready, late, late_inputs) == {:error, :parent_cutoff_exceeded}

    assert replay(context, [{initialize, %{}}, {late, late_inputs}]) ==
             {:error, :parent_cutoff_exceeded}
  end

  test "a later original attempt must accommodate the frozen cutoff under its own effective deadline" do
    context = fixture()
    {ready, initialize} = initialized(context)
    first_original = job(context, 1)
    cutoff = first_original.effective_job_deadline
    {first, first_inputs} = reservation_at(context, ready, first_original, cutoff)
    assert {:ok, reserved, _} = RunLedger.admit(ready, first, first_inputs)

    {equal, equal_inputs} = reservation_at(context, reserved, job(context, 2), cutoff)
    assert {:ok, admitted, _} = RunLedger.admit(reserved, equal, equal_inputs)
    assert admitted.operation.logical == reserved.operation.logical

    assert admitted.count == reserved.count and
             admitted.reserved_tokens == reserved.reserved_tokens

    prefix = [{initialize, %{}}, {first, first_inputs}]
    assert {:ok, ^admitted} = replay(context, prefix ++ [{equal, equal_inputs}])

    tighter = job(context, 2, run_deadline: cutoff - 1)
    assert tighter.effective_job_deadline == cutoff - 1
    {late, late_inputs} = reservation_at(context, reserved, tighter, cutoff)

    assert Map.take(late["mutation"], Map.keys(reserved.operation.logical)) ==
             reserved.operation.logical

    assert late["mutation"]["source_intent"]["canonical_request_digest"] ==
             tighter.canonical_request_digest

    assert RunLedger.admit(reserved, late, late_inputs) == {:error, :parent_cutoff_exceeded}
    assert replay(context, prefix ++ [{late, late_inputs}]) == {:error, :parent_cutoff_exceeded}
  end

  test "dispatch-local effective deadline wins over the looser original run deadline" do
    context = fixture()
    {ready, initialize} = initialized(context)
    budgets = Map.put(Tool.definition()["budgets"], "max_wall_time_ms", 1)
    run_deadline = System.system_time(:millisecond) + 60_000
    original = job(context, 1, run_deadline: run_deadline, resource_budgets: budgets)
    assert original.effective_job_deadline < original.run_deadline
    {equal, inputs} = reservation_at(context, ready, original, original.effective_job_deadline)
    assert {:ok, admitted, _} = RunLedger.admit(ready, equal, inputs)
    assert {:ok, ^admitted} = replay(context, [{initialize, %{}}, {equal, inputs}])

    {late, late_inputs} =
      reservation_at(context, ready, original, original.effective_job_deadline + 1)

    assert late["mutation"]["absolute_cutoff_ms"] <= original.run_deadline
    assert RunLedger.admit(ready, late, late_inputs) == {:error, :parent_cutoff_exceeded}
  end

  test "historical deadline equality and original duplicates need no renewed clock or live input" do
    context = fixture()
    {ready, initialize} = initialized(context)
    original = job(context, 1, run_deadline: 1)
    assert original.effective_job_deadline == 1
    assert System.system_time(:millisecond) > original.effective_job_deadline
    {tx, inputs} = reservation_at(context, ready, original, 1)
    assert {:ok, state, result} = RunLedger.admit(ready, tx, inputs)
    assert {:ok, ^state} = replay(context, [{initialize, %{}}, {tx, inputs}])
    assert RunLedger.admit(state, tx) == {:ok, state, result}
    assert RunLedger.admit(state, tx, %{original_job: nil}) == {:ok, state, result}
    stop = stop_transaction(state, original, "adapter_recovery")
    assert {:ok, stopped, _} = RunLedger.admit(state, stop, %{original_job: original})
    assert stopped.credit == state.credit - @frame
    assert RunLedger.admit(stopped, tx) == {:ok, stopped, result}
  end

  test "first reserve joins exact selected child object bytes and owning digests" do
    context = fixture()
    {ready, _} = initialized(context)
    {tx, inputs} = reservation(context, ready, job(context, 1))

    assert RunLedger.admit(ready, tx, %{inputs | child_creation: "{}"}) ==
             {:error, :child_creation_mismatch}

    changed =
      transaction(
        ready,
        Map.put(tx["mutation"], "child_creation_sha256", String.duplicate("0", 64))
      )

    assert RunLedger.admit(ready, changed, inputs) == {:error, :child_creation_mismatch}
    original = job(context, 1, role: "other")
    {tx, inputs} = reservation(context, ready, original)
    assert :ok = RunMutation.match_job(context.ids, tx["mutation"], original)
    assert RunLedger.admit(ready, tx, inputs) == {:error, :child_creation_mismatch}
  end

  for field <-
        ~w(operation_identity role task_digest child_creation_sha256 absolute_cutoff_ms reserved_tokens) do
    @field field
    test "later original attempts freeze #{@field} without another child or reservation" do
      context = fixture()
      {state, _tx, _inputs} = first_reserved(context)

      options =
        case @field do
          "operation_identity" -> [operation_id: "other-operation"]
          "role" -> [role: "other"]
          "task_digest" -> [prompt: "changed task"]
          _ -> []
        end

      original = job(context, 2, options)
      {tx, inputs} = reservation(context, state, original)

      mutation =
        case @field do
          "child_creation_sha256" -> Map.put(tx["mutation"], @field, String.duplicate("0", 64))
          "absolute_cutoff_ms" -> Map.put(tx["mutation"], @field, 9_999)
          "reserved_tokens" -> Map.put(tx["mutation"], @field, 1)
          _ -> tx["mutation"]
        end

      changed = transaction(state, mutation)
      assert :ok = Executor.validate_job(original)
      assert :ok = RunMutation.match_job(context.ids, mutation, original)
      assert RunLedger.admit(state, changed, inputs) == {:error, :operation_binding_conflict}
    end
  end

  test "derived commands cannot change under freshly recomputed transaction preimages" do
    context = fixture()
    {state, _tx, _inputs} = first_reserved(context)
    {tx, inputs} = reservation(context, state, job(context, 2))

    for field <- ~w(create_command_id prompt_command_id) do
      changed = Map.put(tx["mutation"], field, Base.encode64(String.duplicate("0", 64)))

      assert RunMutation.transaction(context.ids, state.version, changed) ==
               {:error, :invalid_run_transaction}

      assert RunLedger.admit(state, Map.put(tx, "mutation", changed), inputs) ==
               {:error, :invalid_run_transaction}
    end
  end

  test "additional originals retain each source tuple and add only receipt credit" do
    context = fixture()
    {state, first, _} = first_reserved(context)
    {tx, inputs} = reservation(context, state, job(context, 2))
    assert {:ok, next, _} = RunLedger.admit(state, tx, inputs)
    assert next.count == state.count and next.reserved_tokens == state.reserved_tokens

    assert next.operation.logical == state.operation.logical and
             next.credit == state.credit + @frame

    assert next.operation.attempts[first["mutation"]["job"]["job_id"]] == %{
             job: first["mutation"]["job"],
             source_intent: first["mutation"]["source_intent"]
           }

    assert next.operation.attempts[tx["mutation"]["job"]["job_id"]].source_intent ==
             tx["mutation"]["source_intent"]

    changed =
      transaction(next, Map.put(tx["mutation"], "closing_credit_bytes", next.credit + @frame))

    assert RunLedger.admit(next, changed, inputs) == {:error, :run_transaction_conflict}
    changed = transaction(state, Map.put(tx["mutation"], "closing_credit_bytes", state.credit))
    assert RunLedger.admit(state, changed, inputs) == {:error, :reservation_mismatch}

    assert RunLedger.admit(state, tx, %{inputs | child_creation: inputs.child_creation <> "\n"}) ==
             {:error, :child_creation_mismatch}
  end

  for reason <- ~w(cancel cutoff adapter_recovery) do
    @reason reason
    test "first #{@reason} stop preserves other obligations and excludes every new attempt" do
      context = fixture()
      {state, _tx, inputs} = first_reserved(context)
      tx = stop_transaction(state, inputs.original_job, @reason)
      assert RunLedger.first_stop(state) == :absent

      assert {:ok, stopped, result} =
               RunLedger.admit(state, tx, %{original_job: inputs.original_job})

      assert stopped.credit == 4 * @frame and stopped.count == 1 and
               stopped.reserved_tokens == 8_192

      assert RunLedger.first_stop(stopped) == {:ok, tx, result}
      assert RunLedger.admit(stopped, tx) == {:ok, stopped, result}
      {reserve, next_inputs} = reservation(context, stopped, job(context, 2))
      assert RunLedger.admit(stopped, reserve, next_inputs) == {:error, :invalid_run_transition}

      changed =
        stop_transaction(
          stopped,
          inputs.original_job,
          if(@reason == "cancel", do: "cutoff", else: "cancel")
        )

      assert RunLedger.admit(stopped, changed, %{original_job: inputs.original_job}) ==
               {:error, :run_transaction_conflict}

      assert RunLedger.first_stop(stopped) == {:ok, tx, result}
    end
  end

  test "stop must join an already retained original attempt and exact job projection" do
    context = fixture()
    {state, _tx, inputs} = first_reserved(context)
    other = job(context, 2)
    tx = stop_transaction(state, other, "cancel")
    assert :ok = RunMutation.match_job(context.ids, tx["mutation"], other)
    assert RunLedger.admit(state, tx, %{original_job: other}) == {:error, :original_stop_mismatch}
    tx = stop_transaction(state, inputs.original_job, "cancel")
    assert RunLedger.admit(state, tx, %{original_job: other}) == {:error, :original_stop_mismatch}
    assert RunLedger.admit(state, tx) == {:error, :original_stop_mismatch}
  end

  test "strict replay rejects duplicate frames gaps reordering and malformed entries" do
    context = fixture()
    {state, entries} = complete_prefix(context)
    assert {:ok, ^state} = replay(context, entries)
    assert replay(context, entries ++ [hd(entries)]) == {:error, :duplicate_appended_transaction}
    assert {:error, _} = replay(context, tl(entries))
    assert {:error, _} = replay(context, Enum.reverse(entries))
    {tx, inputs} = Enum.at(entries, 1)
    gap = transaction(context.ids, 9, tx["mutation"])
    assert replay(context, [hd(entries), {gap, inputs}]) == {:error, :stale_run_version}
    assert replay(context, [nil]) == {:error, :invalid_run_prefix}
    assert replay(context, [{job(context, 1), %{}}]) == {:error, :invalid_run_prefix}
    assert replay(context, :not_a_prefix) == {:error, :invalid_run_prefix}
    assert {:ok, empty} = replay(context, [])
    assert empty.phase == :empty and empty.count == 0 and empty.credit == 0
  end

  test "accepted later lifecycle maps remain closed to prelaunch admission" do
    context = fixture()
    {state, _tx, _inputs} = first_reserved(context)

    mutation = %{
      "kind" => "child_created",
      "operation_identity" => state.operation.logical["operation_identity"],
      "child_session_id" => Base.encode64("child"),
      "child_creation_sha256" => state.operation.logical["child_creation_sha256"],
      "configuration_digest" => String.duplicate("1", 64),
      "tool_selection_sha256" => String.duplicate("2", 64),
      "policy_defer_mode" => "refuse"
    }

    tx = transaction(state, mutation)
    assert RunLedger.admit(state, tx) == {:error, :invalid_run_transition}
  end

  test "actual complete prefix frames fill the exact cap and the next byte refuses" do
    context = fixture()
    {state, entries, tx, inputs} = capacity_prefix(context)
    assert frame_size(tx) == @frame - 128
    assert {:ok, exact, _} = RunLedger.admit(state, tx, inputs)
    assert exact.bytes + exact.credit == @cap and exact.count == 1
    assert {:ok, ^exact} = replay(context, entries ++ [{tx, inputs}])
    {larger, larger_inputs} = pad_original(context, {tx, inputs}, 1)
    assert frame_size(larger) == frame_size(tx) + 1
    assert RunLedger.admit(state, larger, larger_inputs) == {:error, :run_byte_limit}
    {extra, extra_inputs} = reservation(context, exact, job(context, 1_001))
    assert RunLedger.admit(exact, extra, extra_inputs) == {:error, :run_byte_limit}
    stop = stop_transaction(exact, inputs.original_job, "cutoff")
    assert {:ok, stopped, _} = RunLedger.admit(exact, stop, %{original_job: inputs.original_job})
    assert exact.credit == (4 + map_size(exact.operation.attempts)) * @frame
    assert stopped.credit == exact.credit - @frame
    assert stopped.bytes == exact.bytes + frame_size(stop)
    assert stopped.bytes + stopped.credit <= @cap and stopped.reserved_tokens == 8_192
  end

  for adapter <- [Memory, Local] do
    @adapter adapter
    test "#{inspect(adapter)} actual historical parent remains unactivated and unchanged" do
      capture = Fixture.valid_capture()

      root =
        Path.join(
          System.tmp_dir!(),
          "m7-run-ledger-#{Base.encode16(:crypto.strong_rand_bytes(12))}"
        )

      File.mkdir_p!(root)
      on_exit(fn -> File.rm_rf!(root) end)
      options = if @adapter == Local, do: [path: Path.join(root, "store.log")], else: []
      {:ok, first} = @adapter.start_link(options)
      on_exit(fn -> if Process.alive?(first), do: GenServer.stop(first) end)
      {:ok, store} = Store.new(@adapter, first)
      assert {:committed, _, receipt} = Fixture.commit_creation(store, capture)

      store_pid =
        if @adapter == Local do
          stop_join(first)
          {:ok, reopened} = Local.start_link(options)
          reopened
        else
          first
        end

      on_exit(fn -> if Process.alive?(store_pid), do: GenServer.stop(store_pid) end)
      {:ok, selected} = Store.new(@adapter, store_pid)

      {:ok, runtime} =
        Loopex.start_link(
          runtime_id: capture.runtime,
          context_token_budget: 8_192,
          store: selected
        )

      on_exit(fn -> if Runtime.alive?(runtime), do: Loopex.stop(runtime) end)
      assert :ok = Fixture.await_startup(runtime)
      assert {:ok, %{sessions: sessions}} = Runtime.children(runtime)
      assert DynamicSupervisor.which_children(sessions) == []
      before = store_image(@adapter, store_pid, options)
      assert {:ok, {:historical, actual}} = ParentBinding.observe_creation(runtime, capture)
      assert actual.session_id == receipt.session_id
      context = fixture(capture, actual.session_id, {:historical, actual})
      {state, entries} = complete_prefix(context)
      assert {:ok, ^state} = replay(context, entries)
      assert before == store_image(@adapter, store_pid, options)
      assert DynamicSupervisor.which_children(sessions) == []
      supervisor = runtime.supervisor
      monitor = Process.monitor(supervisor)
      assert :ok = Loopex.stop(runtime)
      assert_receive {:DOWN, ^monitor, :process, ^supervisor, _}, 5_000
      stop_join(store_pid)
    end
  end

  defp fixture(capture \\ Fixture.valid_capture(), session \\ "session", history \\ nil) do
    # Concept: pure rows validate shape without authenticating a history producer.
    # Technical depth: the separate real Store cases obtain owning observations;
    # none of these inputs establishes a live source, grant or cross-run slot.
    history =
      history ||
        {:historical,
         %{
           version: 1,
           runtime_id: capture.runtime,
           command_id: capture.command,
           session_id: session,
           genesis_version: 3,
           canonical_create_digest: capture.creation["canonical_create_digest"]
         }}

    {:ok, prepare} =
      ParentBinding.transaction(capture.key, 0, ParentBinding.prepare_mutation(capture))

    {:ok, bind} =
      ParentBinding.transaction(capture.key, 1, ParentBinding.bind_mutation(capture, session))

    ids = [capture.runtime, session, "run"]
    binding = [prepare, bind]
    assert {:ok, state} = RunLedger.new(ids, capture, binding, history)
    %{capture: capture, ids: ids, binding: binding, history: history, state: state}
  end

  defp initialized(context) do
    tx = transaction(context.state, RunLedger.initialize_mutation(context.state))
    assert {:ok, state, _} = RunLedger.admit(context.state, tx)
    {state, tx}
  end

  defp first_reserved(context) do
    {ready, _} = initialized(context)
    {tx, inputs} = reservation(context, ready, job(context, 1))
    assert {:ok, state, _} = RunLedger.admit(ready, tx, inputs)
    {state, tx, inputs}
  end

  defp complete_prefix(context) do
    {ready, initialize} = initialized(context)
    {first, first_inputs} = reservation(context, ready, job(context, 1))
    assert {:ok, state, _} = RunLedger.admit(ready, first, first_inputs)
    {second, second_inputs} = reservation(context, state, job(context, 2))
    assert {:ok, state, _} = RunLedger.admit(state, second, second_inputs)
    stop = stop_transaction(state, first_inputs.original_job, "cancel")
    stop_inputs = %{original_job: first_inputs.original_job}
    assert {:ok, state, _} = RunLedger.admit(state, stop, stop_inputs)

    {state,
     [{initialize, %{}}, {first, first_inputs}, {second, second_inputs}, {stop, stop_inputs}]}
  end

  defp replay(context, entries),
    do: RunLedger.replay(context.ids, context.capture, context.binding, context.history, entries)

  defp parent_with_limits(total, child) do
    {catalog, declaration, creation} = Fixture.objects()

    declaration =
      declaration
      |> Map.put("token_budget", total)
      |> put_in(["child_bounds", "token_budget"], child)

    creation =
      creation |> Map.put("declaration_sha256", hash(json(declaration))) |> Fixture.rehash()

    {:ok, capture} = Fixture.capture(catalog, declaration, creation)
    capture
  end

  defp job(context, attempt, options \\ []) do
    [_runtime, session, run] = context.ids
    definition = Tool.definition()

    {:ok, job} =
      Executor.job(%{
        protocol_version: 1,
        job_id: "original-job-#{attempt}",
        operation_id: Keyword.get(options, :operation_id, "operation"),
        attempt: attempt,
        session_id: session,
        run_id: run,
        turn_id: "turn",
        tool_call_id: "call",
        origin_session_epoch: 0,
        origin_executor_epoch: 1,
        executor_identity: "executor",
        required_capabilities: [],
        tool_id: definition["tool_id"],
        tool_version: definition["tool_version"],
        effect_class: definition["effect_class"],
        validated_arguments: %{
          "role" => Keyword.get(options, :role, "inspect"),
          "description" => "review",
          "prompt" => Keyword.get(options, :prompt, "inspect exact bytes")
        },
        workspace_ref: "workspace",
        workspace_lease: "lease",
        run_deadline: Keyword.get(options, :run_deadline, 2_000_000_000_000),
        resource_budgets: Keyword.get(options, :resource_budgets, definition["budgets"]),
        idempotency_class: definition["idempotency_class"],
        fencing_token: 1,
        artifact_policy: %{"retain" => true},
        output_policy: %{"capture" => true},
        cleanup_grace_ms: 5_000
      })

    assert :ok = Executor.validate_job(job)
    job
  end

  defp reservation(context, state, original) do
    operation = operation(context, original.operation_id)
    bytes = child_creation(context, operation)

    reserved =
      if state.operation,
        do: state.operation.logical["reserved_tokens"],
        else:
          min(
            context.capture.declaration["token_budget"],
            context.capture.declaration["child_bounds"]["token_budget"]
          )

    mutation = %{
      "kind" => "reserve",
      "operation_identity" => operation,
      "source_intent" => %{
        "session_id" => Base.encode64(original.session_id),
        "journal_version" => original.attempt,
        "canonical_request_digest" => original.canonical_request_digest
      },
      "job" => project(original),
      "role" => original.validated_arguments["role"],
      "task_digest" => Canonical.digest(original.validated_arguments),
      "child_creation_sha256" => hash(bytes),
      "create_command_id" => Base.encode64(command(context, operation, "create")),
      "prompt_command_id" => Base.encode64(command(context, operation, "prompt")),
      "absolute_cutoff_ms" => 10_000,
      "reserved_tokens" => reserved,
      "closing_credit_bytes" => if(state.operation, do: state.credit + @frame, else: 5 * @frame)
    }

    tx = transaction(state, mutation)
    assert :ok = RunMutation.match_job(context.ids, mutation, original)
    {tx, %{original_job: original, child_creation: bytes}}
  end

  defp reservation_at(context, state, original, cutoff) do
    {tx, inputs} = reservation(context, state, original)
    mutation = Map.put(tx["mutation"], "absolute_cutoff_ms", cutoff)
    # Concept: every boundary control reaches the consumer with valid owners.
    # Technical depth: retain coherent role/child/source/job preimages and assert
    # both owning validators before RunLedger's static deadline comparison.
    assert :ok = Executor.validate_job(original)
    tx = transaction(state, mutation)
    assert :ok = RunMutation.match_job(context.ids, mutation, original)
    {tx, inputs}
  end

  defp operation(context, id),
    do: %{
      "parent_session_id" => Base.encode64(Enum.at(context.ids, 1)),
      "parent_run_id" => Base.encode64(Enum.at(context.ids, 2)),
      "operation_id" => Base.encode64(id)
    }

  defp command(context, operation, kind),
    do: domain("loopex:helper-#{kind}:v1", [Base.encode64(hd(context.ids)), operation])

  defp child_creation(context, operation) do
    {:ok, genesis} = GenesisCodec.decode(hd(context.capture.catalog["roles"])["genesis"])

    genesis =
      Map.put(genesis, "options", %{"purpose" => "original child", "opaque" => <<255, 0, 128>>})

    {:ok, retained} = GenesisCodec.encode(genesis)
    create = command(context, operation, "create")
    {:ok, tx} = Store.create_session(hd(context.ids), create, genesis)

    object = %{
      "version" => 1,
      "kind" => "child_creation",
      "runtime_id" => Base.encode64(hd(context.ids)),
      "operation_identity" => operation,
      "role" => "inspect",
      "catalog_sha256" => context.capture.creation["catalog_sha256"],
      "declaration_sha256" => context.capture.creation["declaration_sha256"],
      "command_id" => Base.encode64(create),
      "original_options" =>
        Fixture.envelope(:erlang.term_to_binary(genesis["options"], [:deterministic])),
      "genesis" => retained,
      "canonical_create_digest" => Base.encode16(tx.canonical_mutation_digest, case: :lower),
      "input_digest" => ""
    }

    object |> Fixture.rehash() |> json()
  end

  defp project(job),
    do: %{
      "job_id" => Base.encode64(job.job_id),
      "route" => "helper",
      "operation_id" => Base.encode64(job.operation_id),
      "attempt" => job.attempt,
      "session_id" => Base.encode64(job.session_id),
      "run_id" => Base.encode64(job.run_id),
      "canonical_request_digest" => job.canonical_request_digest,
      "origin_session_epoch" => job.origin_session_epoch,
      "origin_executor_epoch" => job.origin_executor_epoch,
      "executor_identity" => Base.encode64(job.executor_identity),
      "fencing_token" => job.fencing_token,
      "cleanup_grace_ms" => job.cleanup_grace_ms
    }

  defp stop_transaction(state, original, reason) do
    operation = state.operation.logical["operation_identity"]
    {:ok, key} = LedgerCodec.header_key(:run, state.identifiers)

    transaction(state, %{
      "kind" => "stop",
      "operation_identity" => operation,
      "job" => project(original),
      "stop_tx_id" => domain("loopex:helper-tx:v1", [key, "stop", operation]),
      "reason" => reason
    })
  end

  defp transaction(state, mutation), do: transaction(state.identifiers, state.version, mutation)

  defp transaction(ids, version, mutation) do
    assert {:ok, tx} = RunMutation.transaction(ids, version, mutation)
    tx
  end

  defp frame_size(tx) do
    assert {:ok, frame} = LedgerCodec.encode_frame(json(tx))
    byte_size(frame)
  end

  defp json(value) do
    assert {:ok, bytes} = LedgerCodec.encode_json(value, :object)
    bytes
  end

  defp domain(label, value) do
    wrapped = json(%{"v" => value})
    domain_bytes(label, binary_part(wrapped, 5, byte_size(wrapped) - 6))
  end

  defp domain_bytes(label, bytes), do: hash(label <> <<0>> <> bytes)
  defp hash(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  defp capacity_prefix(context) do
    {ready, initialize} = initialized(context)
    {_state, all} = fill_capacity(context, ready, [{initialize, %{}}], 1)
    target = @frame - 128
    # Concept: adjust actual existing frames, never a fabricated byte counter.
    # Technical depth: rebuild actual validated original jobs with exact integer
    # epochs, preserving each source digest join. No epoch or row proves a producer.
    prefix = Enum.drop(all, -1)
    {:ok, earlier} = replay(context, prefix)
    remaining = @cap - earlier.bytes - (earlier.credit + @frame)
    prefix = if remaining < target, do: Enum.drop(all, -2), else: prefix
    {:ok, earlier} = replay(context, prefix)
    remaining = @cap - earlier.bytes - (earlier.credit + @frame)

    {prefix, 0} =
      Enum.map_reduce(prefix, remaining - target, fn {tx, inputs}, padding ->
        if tx["mutation"]["kind"] == "reserve" do
          spend = min(padding, @frame - frame_size(tx))
          {pad_original(context, {tx, inputs}, spend), padding - spend}
        else
          {{tx, inputs}, padding}
        end
      end)

    assert {:ok, earlier} = replay(context, prefix)
    original = job(context, 1_000)
    {last, inputs} = reservation(context, earlier, original)
    padding = target - frame_size(last)
    assert padding > 0
    {tx, inputs} = pad_original(context, {last, inputs}, padding)
    assert earlier.bytes + earlier.credit + @frame + frame_size(tx) == @cap
    {earlier, prefix, tx, inputs}
  end

  defp pad_original(_context, entry, 0), do: entry

  defp pad_original(context, {tx, inputs}, digits) do
    original = inputs.original_job
    width = byte_size(Integer.to_string(original.origin_session_epoch))

    fields =
      original
      |> Map.from_struct()
      |> Map.put(:origin_session_epoch, Integer.pow(10, width + digits - 1))

    assert {:ok, changed} = Executor.job(fields)
    assert :ok = Executor.validate_job(changed)
    mutation = tx["mutation"] |> Map.put("job", project(changed))

    mutation =
      put_in(
        mutation,
        ["source_intent", "canonical_request_digest"],
        changed.canonical_request_digest
      )

    assert :ok = RunMutation.match_job(context.ids, mutation, changed)

    {transaction(context.ids, tx["expected_version"], mutation),
     %{inputs | original_job: changed}}
  end

  defp fill_capacity(context, state, entries, attempt) do
    {tx, inputs} = reservation(context, state, job(context, attempt))

    case RunLedger.admit(state, tx, inputs) do
      {:ok, next, _} -> fill_capacity(context, next, entries ++ [{tx, inputs}], attempt + 1)
      {:error, :run_byte_limit} -> {state, entries}
      refusal -> flunk("Unexpected capacity fixture refusal: #{inspect(refusal)}")
    end
  end

  defp store_image(Local, pid, options) do
    assert Process.alive?(pid)
    File.read!(Keyword.fetch!(options, :path))
  end

  defp store_image(Memory, pid, _options), do: :sys.get_state(pid)

  defp stop_join(pid) do
    monitor = Process.monitor(pid)
    :ok = GenServer.stop(pid)
    assert_receive {:DOWN, ^monitor, :process, ^pid, _}, 5_000
  end
end
