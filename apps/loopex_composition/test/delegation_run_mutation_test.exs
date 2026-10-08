defmodule LoopexComposition.DelegationRunMutationTest do
  use ExUnit.Case, async: true

  alias Loopex.Executor
  alias LoopexComposition.Delegation.{LedgerCodec, RunMutation, Tool}
  alias LoopexProtocol.{Canonical, Frame}

  @path Path.join(__DIR__, "fixtures/delegation/run-mutations-v1.json")
  @external_resource @path
  @fixture JSON.decode!(File.read!(@path))
  @ids Enum.map(@fixture["identity"], &Base.decode64!/1)
  @error {:error, :invalid_run_transaction}
  @uint64 18_446_744_073_709_551_615

  for row <- @fixture["vectors"] do
    @row row
    test "independent full transaction and result bytes #{@row["name"]}" do
      tx = @row["transaction"]

      assert hash("loopex:helper-run:v1" <> <<0>> <> @fixture["identity_json"]) ==
               @fixture["run_key"]

      assert hash("loopex:helper-tx:v1" <> <<0>> <> @row["tx_preimage"]) == tx["tx_id"]

      assert hash("loopex:helper-mutation:v1" <> <<0>> <> @row["mutation_preimage"]) ==
               tx["mutation_digest"]

      assert {:ok, ^tx} = RunMutation.transaction(@ids, tx["expected_version"], tx["mutation"])
      assert {:ok, ^tx} = RunMutation.validate(@ids, tx)
      assert {:ok, ^tx} = RunMutation.decode(@ids, @row["transaction_json"])
      assert {:ok, bytes} = LedgerCodec.encode_json(tx, :frame)
      assert bytes == @row["transaction_json"]
      assert {:ok, result} = RunMutation.result(@ids, tx)
      assert result == @row["result"]
      assert json(result) == @row["result_json"]
      assert {:ok, frame} = LedgerCodec.encode_frame(bytes)
      assert byte_size(frame) == byte_size(bytes) + 78
    end
  end

  test "every settlement retains the independent full accounting preimage" do
    for row <- @fixture["vectors"], row["transaction"]["mutation"]["kind"] == "settle" do
      accounting = row["transaction"]["mutation"]["accounting"]

      assert hash("loopex:helper-accounting-evidence:v1" <> <<0>> <> row["accounting_preimage"]) ==
               accounting["evidence_sha256"]
    end
  end

  test "run scope uses the existing opaque header owner and exact original cap" do
    mutation = mutation("initialize")

    for ids <- [
          ["r", "s", "u"],
          List.duplicate(<<255, 0, 128>>, 3),
          List.duplicate(String.duplicate("x", 256), 3)
        ] do
      assert {:ok, tx} = RunMutation.transaction(ids, 0, mutation)
      assert {:ok, ^tx} = RunMutation.validate(ids, tx)
      refute tx["tx_id"] == transaction("initialize")["tx_id"]
    end

    for ids <- [
          nil,
          [],
          ["r", "s"],
          ["r", "s", "u", "extra"],
          ["", "s", "u"],
          [String.duplicate("x", 257), "s", "u"],
          ["r", "s", 1]
        ] do
      assert RunMutation.transaction(ids, 0, mutation) == @error
    end

    for index <- 0..2 do
      ids = List.replace_at(@ids, index, "different")
      assert RunMutation.validate(ids, transaction("reserve")) == @error
    end
  end

  test "every required mutation field and unknown member refuses after full rehashing" do
    for row <- @fixture["vectors"] do
      mutation = row["transaction"]["mutation"]
      for key <- Map.keys(mutation), do: reject(Map.delete(mutation, key))
      reject(Map.put(mutation, "extra", nil))
    end
  end

  test "every nested map remains closed even when all transaction and evidence hashes agree" do
    for name <-
          ~w(initialize reserve recover_uncreated child_created child_prompted stop_cancel settle_completed bind_receipt) do
      mutation = mutation(name)

      for path <- map_paths(mutation), path != [] do
        nested = get_in(mutation, path)
        reject(put_in(mutation, path, Map.put(nested, "extra", 0)))
        for key <- Map.keys(nested), do: reject(put_in(mutation, path, Map.delete(nested, key)))
      end
    end
  end

  test "transaction envelope is closed and binds exact version expected head and full mutation" do
    tx = transaction("reserve")

    for changed <- [
          Map.put(tx, "extra", nil),
          Map.put(tx, "version", 2),
          Map.put(tx, "version", 1.0),
          Map.put(tx, "expected_version", -1),
          Map.put(tx, "expected_version", 1.0),
          Map.put(tx, "tx_id", hash("other")),
          Map.put(tx, "mutation_digest", hash("other"))
        ] do
      assert RunMutation.validate(@ids, changed) == @error
      assert RunMutation.result(@ids, changed) == @error
    end

    for key <- Map.keys(tx), do: assert(RunMutation.validate(@ids, Map.delete(tx, key)) == @error)
    assert RunMutation.validate(@ids, put_in(tx, ["mutation", "role"], "review")) == @error
    assert RunMutation.transaction(@ids, -1, tx["mutation"]) == @error
    assert RunMutation.transaction(@ids, 1.0, tx["mutation"]) == @error
  end

  test "exact positive and nonnegative domains retain quantities beyond wire and uint64 ceilings" do
    big = Integer.pow(2, 90)
    reserve = mutation("reserve")
    assert {:ok, tx} = RunMutation.transaction(@ids, big, %{reserve | "reserved_tokens" => big})
    assert {:ok, bytes} = LedgerCodec.encode_json(tx, :frame)
    assert {:ok, ^tx} = RunMutation.decode(@ids, bytes)
    assert {:ok, result} = RunMutation.result(@ids, tx)
    assert result["ledger_version"] == big + 1

    for key <- ~w(reserved_tokens absolute_cutoff_ms) do
      for value <- [0, -1, 1.0, true, nil], do: reject(Map.put(reserve, key, value))
    end

    for value <- [-1, 1.0, false, nil],
        do: reject(Map.put(reserve, "closing_credit_bytes", value))

    assert {:ok, _} = RunMutation.transaction(@ids, 0, %{reserve | "closing_credit_bytes" => 0})
    reject(%{reserve | "absolute_cutoff_ms" => 9_007_199_254_740_992})

    for value <- [0, -1, 1.0],
        do: reject(put_in(reserve, ["source_intent", "journal_version"], value))
  end

  test "job epochs and fences are native nonnegative integers and grace uses Executor's owner" do
    reserve = mutation("reserve")

    for key <- ~w(origin_session_epoch origin_executor_epoch fencing_token) do
      for value <- [0, Integer.pow(2, 90)] do
        assert {:ok, _} = RunMutation.transaction(@ids, 0, put_in(reserve, ["job", key], value))
      end

      for value <- [-1, 1.0, Base.encode64(<<0>>), false],
          do: reject(put_in(reserve, ["job", key], value))
    end

    for grace <- [1, @uint64] do
      assert {:ok, _} = Executor.cancellation_bounds(grace)

      assert {:ok, _} =
               RunMutation.transaction(
                 @ids,
                 0,
                 put_in(reserve, ["job", "cleanup_grace_ms"], grace)
               )
    end

    for grace <- [0, -1, @uint64 + 1, 1.0] do
      assert Executor.cancellation_bounds(grace) == {:error, :invalid_cleanup_grace}
      reject(put_in(reserve, ["job", "cleanup_grace_ms"], grace))
    end

    for attempt <- [0, -1, 1.0], do: reject(put_in(reserve, ["job", "attempt"], attempt))
  end

  test "executor IDs preserve original binary caps and complete attempt fields" do
    reserve = mutation("reserve")

    for key <- ~w(job_id executor_identity) do
      for bytes <- [<<255>>, String.duplicate("x", 8_192)] do
        assert {:ok, _} =
                 RunMutation.transaction(
                   @ids,
                   0,
                   put_in(reserve, ["job", key], Base.encode64(bytes))
                 )
      end

      reject(put_in(reserve, ["job", key], Base.encode64(String.duplicate("x", 8_193))))
    end

    operation = String.duplicate("x", 8_192)
    maximal = with_operation(reserve, operation)
    assert {:ok, _} = RunMutation.transaction(@ids, 0, maximal)
    reject(with_operation(reserve, operation <> "x"))
  end

  test "opaque IDs require canonical padded base64 instead of text guesses" do
    reserve = mutation("reserve")

    for value <- ["", "Zg", "Zh==", "Zg==\n", "%%%", <<255>>, nil, 1] do
      reject(put_in(reserve, ["job", "job_id"], value))
      reject(put_in(reserve, ["job", "executor_identity"], value))
      reject(put_in(reserve, ["operation_identity", "operation_id"], value))
    end

    for key <- ~w(create_command_id prompt_command_id) do
      reject(Map.put(reserve, key, Base.decode64!(reserve[key])))
      reject(Map.put(reserve, key, Base.encode64("different")))
    end
  end

  test "nested parent run operation and source digest joins cannot be repaired by rehashing" do
    reserve = mutation("reserve")

    for {path, value} <- [
          {["operation_identity", "parent_session_id"], Base.encode64("foreign")},
          {["operation_identity", "parent_run_id"], Base.encode64("foreign")},
          {["job", "session_id"], Base.encode64("foreign")},
          {["job", "run_id"], Base.encode64("foreign")},
          {["job", "operation_id"], Base.encode64("foreign")},
          {["source_intent", "session_id"], Base.encode64("foreign")},
          {["source_intent", "canonical_request_digest"], hash("foreign")},
          {["job", "canonical_request_digest"], hash("foreign")},
          {["job", "route"], "local"}
        ] do
      reject(put_in(reserve, path, value))
    end
  end

  test "all hash fields require lower hex and altered accounting evidence never authenticates itself" do
    for name <- ~w(initialize reserve child_created child_prompted settle_completed bind_receipt) do
      mutation = mutation(name)

      for key <- Map.keys(mutation), hash_field?(key) do
        for value <- ["", String.duplicate("A", 64), String.duplicate("g", 64), <<0::256>>, nil] do
          reject(Map.put(mutation, key, value))
        end
      end
    end

    mutation = mutation("settle_completed")
    altered = put_in(mutation, ["accounting", "evidence_sha256"], hash("foreign"))
    assert RunMutation.validate(@ids, rehashed(altered, false)) == @error
  end

  test "declaration validates finite role cardinality authored order and exact bounds" do
    initialize = mutation("initialize")
    limits = initialize["limits"]

    for {key, value} <- [
          {"version", 2},
          {"enabled", false},
          {"kind", "catalog"},
          {"roles", []},
          {"roles", ["inspect", "inspect"]},
          {"roles", ["Inspect"]},
          {"max_children", 0},
          {"max_children", 129},
          {"token_budget", 0},
          {"max_tokens", 0},
          {"role_budgets", Enum.reverse(limits["role_budgets"])}
        ] do
      reject(%{initialize | "limits" => Map.put(limits, key, value)})
    end

    for {key, value} <- [
          {"max_turns", 0},
          {"token_budget", 0},
          {"deadline_ms", 0},
          {"deadline_ms", 600_001}
        ] do
      reject(put_in(initialize, ["limits", "child_bounds", key], value))
    end

    for {key, value} <- [
          {"context_token_budget", 0},
          {"context_token_budget", @uint64 + 1},
          {"system_class_tokens", 0},
          {"system_class_tokens", @uint64 + 1}
        ] do
      reject(put_in(initialize, ["limits", "role_budgets", Access.at(0), key], value))
    end

    reject(
      put_in(initialize, ["limits", "role_budgets", Access.at(0), "context_token_budget"], 1)
      |> put_in(["limits", "role_budgets", Access.at(0), "system_class_tokens"], 2)
    )

    roles = Enum.map(1..16, &("r" <> Integer.to_string(&1)))

    budgets =
      Enum.map(roles, &%{"role" => &1, "context_token_budget" => 1, "system_class_tokens" => 1})

    complete = %{initialize | "limits" => %{limits | "roles" => roles, "role_budgets" => budgets}}
    assert {:ok, _} = RunMutation.transaction(@ids, 0, complete)
    reject(put_in(complete, ["limits", "roles"], roles ++ ["r17"]))
  end

  test "role names retain the fixed ASCII grammar rather than a live catalog enum" do
    reserve = mutation("reserve")

    for role <- ["r", "unlisted_role", "r" <> String.duplicate("x", 63)] do
      assert {:ok, _} = RunMutation.transaction(@ids, 0, %{reserve | "role" => role})
    end

    for role <- ["", "R", "r/x", "ré", "r\n", "r" <> String.duplicate("x", 64)],
        do: reject(%{reserve | "role" => role})
  end

  test "derived create and prompt commands are stable across original attempts" do
    reserve = mutation("reserve")

    for key <- ~w(create_command_id prompt_command_id) do
      assert reserve[key] == @fixture["command_ids"][key]
    end

    next =
      reserve
      |> put_in(["job", "job_id"], Base.encode64("next job"))
      |> put_in(["job", "attempt"], 2)

    assert {:ok, first} = RunMutation.transaction(@ids, 0, reserve)
    assert {:ok, second} = RunMutation.transaction(@ids, 1, next)
    refute first["tx_id"] == second["tx_id"]
    assert first["mutation"]["create_command_id"] == second["mutation"]["create_command_id"]
    assert first["mutation"]["prompt_command_id"] == second["mutation"]["prompt_command_id"]
    reject(%{reserve | "create_command_id" => reserve["prompt_command_id"]})
    reject(%{reserve | "prompt_command_id" => reserve["create_command_id"]})
  end

  test "stop uses its own transaction ID and preserves reason-dependent mutation bytes" do
    stops = Enum.map(~w(stop_cancel stop_cutoff stop_adapter_recovery), &transaction/1)
    assert length(Enum.uniq(Enum.map(stops, & &1["tx_id"]))) == 1
    assert length(Enum.uniq(Enum.map(stops, & &1["mutation_digest"]))) == 3
    stop = mutation("stop_cancel")
    reject(%{stop | "stop_tx_id" => hash("other")})
    reject(%{stop | "reason" => "completed"})
    # Concept: schema validity does not decide which stop won.
    # Technical depth: the later reducer/index must retain the original transaction.
    for tx <- stops, do: assert(RunMutation.validate(@ids, tx) == {:ok, tx})
  end

  test "child creation and prompt store only exact identity hashes and refusal mode" do
    created = mutation("child_created")
    prompted = mutation("child_prompted")
    reject(%{created | "policy_defer_mode" => "admit"})

    for child <- ["", Base.encode64(String.duplicate("x", 257)), "plain child"] do
      reject(%{created | "child_session_id" => child})
      reject(%{prompted | "child_session_id" => child})
    end

    assert {:ok, _} =
             RunMutation.transaction(@ids, 0, %{
               created
               | "child_session_id" => Base.encode64(String.duplicate("x", 256))
             })

    assert {:ok, _} =
             RunMutation.transaction(@ids, 0, %{
               prompted
               | "child_run_id" => Base.encode64(String.duplicate("x", 8_192))
             })

    reject(%{prompted | "child_run_id" => Base.encode64(String.duplicate("x", 8_193))})
    reject(%{prompted | "prompt_command_id" => @fixture["command_ids"]["create_command_id"]})
  end

  test "terminal unions refuse invented clean endings and forbidden null identities" do
    settle = mutation("settle_completed")

    for {key, value} <- [
          {"state", "unknown"},
          {"cleanup", "unconfirmed"},
          {"journal_version", 0},
          {"child_run_id", nil},
          {"child_session_id", nil}
        ] do
      reject(put_in(settle, ["terminal", key], value))
    end

    uncreated = mutation("settle_uncreated")
    reject(put_in(uncreated, ["terminal", "child_session_id"], Base.encode64("child")))
    reject(put_in(uncreated, ["terminal", "child_run_id"], Base.encode64("run")))

    for state <- ~w(completed cancelled bound_reached) do
      reject(put_in(mutation("settle_failed_unprompted"), ["terminal", "state"], state))
    end
  end

  test "accounting endpoint and zero variants remain exact without certifying a producer" do
    settle = mutation("settle_completed")

    for token <- [nil, "", Base.encode64(<<0::248>>), Base.encode64(<<0::264>>), "Zh=="] do
      reject(put_in(settle, ["accounting", "prefix_token"], token))
    end

    reject(put_in(settle, ["accounting", "through_version"], 0))

    for key <-
          ~w(reported_input_tokens reported_output_tokens estimated_tokens charged_tokens through_version) do
      reject(put_in(settle, ["accounting", key], -1))
    end

    uncreated = mutation("settle_uncreated")

    for key <-
          ~w(reported_input_tokens reported_output_tokens estimated_tokens charged_tokens through_version) do
      reject(put_in(uncreated, ["accounting", key], 1))
    end

    reject(put_in(uncreated, ["accounting", "prefix_token"], Base.encode64(<<0::256>>)))
    reject(put_in(uncreated, ["accounting", "unresolved_usage"], true))
    reject(%{uncreated | "refund_tokens" => 1})
    # Concept: this map is a stored projection rather than a read capability.
    # Technical depth: a different well-formed endpoint still needs its actual owner join.
    changed = put_in(settle, ["accounting", "prefix_token"], Base.encode64(<<255::256>>))
    assert {:ok, _} = RunMutation.validate(@ids, rehashed(changed))
  end

  test "known estimated and unresolved projections preserve exact local charge relationships" do
    settle = mutation("settle_completed")
    reject(%{settle | "charge_tokens" => settle["charge_tokens"] + 1})
    changed = put_in(settle, ["accounting", "charged_tokens"], settle["charge_tokens"] + 1)
    reject(%{changed | "charge_tokens" => changed["accounting"]["charged_tokens"]})
    reject(put_in(settle, ["accounting", "unresolved_usage"], 1))
    unknown = mutation("settle_estimated_unknown")
    reject(put_in(unknown, ["accounting", "unresolved_usage"], false))
    reject(%{unknown | "refund_tokens" => 1})
    insufficient = put_in(unknown, ["accounting", "charged_tokens"], 0)
    reject(%{insufficient | "charge_tokens" => 0})

    reject(
      put_in(mutation("settle_failed_unprompted"), ["accounting", "reported_input_tokens"], 1)
    )

    reject(%{settle | "refund_tokens" => -1})
  end

  test "complete transaction payload fits the exact cap and rejects the next encoded byte" do
    reserve = mutation("reserve")
    base = rehashed(%{reserve | "reserved_tokens" => 1})
    digits = 65_536 - byte_size(json(base)) + 1
    assert digits > 1

    for offset <- [-1, 0] do
      quantity = String.to_integer("1" <> String.duplicate("0", digits + offset - 1))
      mutation = %{reserve | "reserved_tokens" => quantity}
      tx = rehashed(mutation)
      assert byte_size(json(tx)) == 65_536 + offset
      assert {:ok, ^tx} = RunMutation.transaction(@ids, 0, mutation)
      assert {:ok, ^tx} = RunMutation.decode(@ids, json(tx))
    end

    quantity = String.to_integer("1" <> String.duplicate("0", digits))
    oversized = %{reserve | "reserved_tokens" => quantity}
    assert byte_size(json(rehashed(oversized))) == 65_537
    assert RunMutation.transaction(@ids, 0, oversized) == @error
    assert RunMutation.decode(@ids, json(rehashed(oversized))) == @error
  end

  test "raw byte admission refuses alternate spelling duplicate names and unknown atoms" do
    bytes = row("reserve")["transaction_json"]

    for changed <- [
          bytes <> "\n",
          " " <> bytes,
          String.replace(bytes, "\"version\":1", "\"version\":1.0", global: false),
          String.replace(bytes, "\"version\":1", ~S("version":1,"\u0076ersion":1), global: false)
        ] do
      assert RunMutation.decode(@ids, changed) == @error
    end

    name = "helper_run_unknown_" <> Integer.to_string(System.unique_integer([:positive]))
    assert_raise ArgumentError, fn -> String.to_existing_atom(name) end
    bytes = "{\"" <> name <> "\":1}"
    assert RunMutation.decode(@ids, bytes) == @error
    assert_raise ArgumentError, fn -> String.to_existing_atom(name) end
  end

  test "native malformed values cannot widen mutation maps or expose implementation terms" do
    for value <- [
          nil,
          [],
          1,
          %URI{},
          %{kind: "initialize"},
          Map.put(mutation("reserve"), "extra", self()),
          Map.put(mutation("reserve"), "extra", make_ref())
        ] do
      assert RunMutation.transaction(@ids, 0, value) == @error
    end

    for kind <- ~w(prepare_parent bind_parent future_kind),
        do: reject(%{mutation("reserve") | "kind" => kind})

    assert RunMutation.decode(@ids, nil) == @error
    assert RunMutation.validate(@ids, %URI{}) == @error
  end

  test "actual Executor JobRequest validates exact reserve stop and receipt projections" do
    original = original_job()
    assert :ok = Executor.validate_job(original)
    reserve = original_reserve(original)

    for mutation <- [
          reserve,
          %{mutation("stop_cancel") | "job" => job_projection(original)},
          %{mutation("bind_receipt") | "job" => job_projection(original)}
        ] do
      assert RunMutation.match_job(@ids, mutation, original) == :ok
    end

    reject(%{reserve | "task_digest" => <<0::256>>})

    assert RunMutation.match_job(
             @ids,
             %{reserve | "task_digest" => hash("foreign task")},
             original
           ) == {:error, :original_job_mismatch}

    assert RunMutation.match_job(@ids, %{reserve | "role" => "other"}, original) ==
             {:error, :original_job_mismatch}
  end

  test "original JobRequest canonical bytes digest and helper generation cannot be substituted" do
    original = original_job()
    reserve = original_reserve(original)

    for changed <- [
          Map.put(original, :canonical_request_bytes, "changed"),
          Map.put(original, :canonical_request_digest, hash("changed")),
          Map.put(original, :effective_job_deadline, 0)
        ] do
      assert RunMutation.match_job(@ids, reserve, changed) == {:error, :original_job_mismatch}
    end

    for fields <- [
          %{tool_id: "loopex.read"},
          %{tool_version: "2.0.0"},
          %{effect_class: "read_only"},
          %{idempotency_class: "safe_retry"},
          %{validated_arguments: %{"role" => "inspect", "description" => "", "prompt" => "task"}}
        ] do
      assert {:ok, changed} = Executor.job(Map.merge(Map.from_struct(original), fields))
      assert :ok = Executor.validate_job(changed)
      changed_reserve = original_reserve(changed)
      assert {:ok, _transaction} = RunMutation.transaction(@ids, 0, changed_reserve)

      assert RunMutation.match_job(@ids, changed_reserve, changed) ==
               {:error, :original_job_mismatch}
    end
  end

  test "changed original attempt epochs fences and source bytes fail exact projection comparison" do
    original = original_job()
    reserve = original_reserve(original)

    for fields <- [
          %{job_id: "other"},
          %{attempt: 2},
          %{origin_session_epoch: 2},
          %{origin_executor_epoch: 2},
          %{fencing_token: 2},
          %{cleanup_grace_ms: 1},
          %{executor_identity: "other"}
        ] do
      assert {:ok, changed} = Executor.job(Map.merge(Map.from_struct(original), fields))
      assert RunMutation.match_job(@ids, reserve, changed) == {:error, :original_job_mismatch}
    end

    assert RunMutation.match_job(@ids, mutation("initialize"), original) ==
             {:error, :original_job_mismatch}
  end

  defp row(name), do: Enum.find(@fixture["vectors"], &(&1["name"] == name))
  defp transaction(name), do: row(name)["transaction"]
  defp mutation(name), do: transaction(name)["mutation"]
  defp hash(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
  defp domain(label, value), do: hash(label <> <<0>> <> json_value(value))

  defp hash_field?(key),
    do: String.ends_with?(key, ["_sha256", "_digest"]) or key == "binding_key"

  defp json(value) do
    {:ok, encoded} = Frame.encode(value)
    bytes = IO.iodata_to_binary(encoded)
    binary_part(bytes, 0, byte_size(bytes) - 1)
  end

  defp json_value(value) do
    wrapped = json(%{"v" => value})
    binary_part(wrapped, 5, byte_size(wrapped) - 6)
  end

  defp rehashed(mutation, evidence \\ true) do
    mutation = if evidence, do: rehash_evidence(mutation), else: mutation
    kind = mutation["kind"]

    target =
      cond do
        kind == "initialize" ->
          []

        kind in ~w(reserve bind_receipt) ->
          [mutation["operation_identity"], get_in(mutation, ["job", "job_id"])]

        true ->
          mutation["operation_identity"]
      end

    %{
      "version" => 1,
      "tx_id" => domain("loopex:helper-tx:v1", [@fixture["run_key"], kind, target]),
      "expected_version" => 0,
      "mutation_digest" =>
        domain("loopex:helper-mutation:v1", [@fixture["run_key"], 0, mutation]),
      "mutation" => mutation
    }
  end

  defp rehash_evidence(%{"kind" => "settle", "accounting" => accounting} = mutation) do
    preimage = [
      mutation["operation_identity"],
      mutation["terminal"],
      Map.delete(accounting, "evidence_sha256")
    ]

    if Map.has_key?(accounting, "evidence_sha256"),
      do:
        put_in(
          mutation,
          ["accounting", "evidence_sha256"],
          domain("loopex:helper-accounting-evidence:v1", preimage)
        ),
      else: mutation
  end

  defp rehash_evidence(mutation), do: mutation

  defp reject(mutation) do
    assert RunMutation.transaction(@ids, 0, mutation) == @error
    # Concept: only serializable hostile maps have canonical preimages.
    # Technical depth: floats, malformed UTF-8 and native terms are refused
    # directly; serializable schema attacks carry fully recomputed hashes.
    tx =
      if json_native?(mutation),
        do: rehashed(mutation),
        else: Map.put(transaction("reserve"), "mutation", mutation)

    assert RunMutation.validate(@ids, tx) == @error
  end

  defp json_native?(value) when is_map(value),
    do:
      Enum.all?(value, fn {key, item} ->
        is_binary(key) and String.valid?(key) and json_native?(item)
      end)

  defp json_native?(value) when is_list(value), do: Enum.all?(value, &json_native?/1)
  defp json_native?(value) when is_binary(value), do: String.valid?(value)
  defp json_native?(value) when is_integer(value), do: true
  defp json_native?(value), do: value in [true, false, nil]

  defp with_operation(mutation, id) do
    mutation =
      mutation
      |> put_in(["operation_identity", "operation_id"], Base.encode64(id))
      |> put_in(["job", "operation_id"], Base.encode64(id))

    runtime = hd(@fixture["identity"])
    operation = mutation["operation_identity"]

    mutation
    |> Map.put(
      "create_command_id",
      Base.encode64(domain("loopex:helper-create:v1", [runtime, operation]))
    )
    |> Map.put(
      "prompt_command_id",
      Base.encode64(domain("loopex:helper-prompt:v1", [runtime, operation]))
    )
  end

  defp map_paths(value, path \\ [])

  defp map_paths(value, path) when is_map(value) do
    [path | Enum.flat_map(value, fn {key, member} -> map_paths(member, path ++ [key]) end)]
  end

  defp map_paths(value, path) when is_list(value) do
    value
    |> Enum.with_index()
    |> Enum.flat_map(fn {member, index} -> map_paths(member, path ++ [Access.at(index)]) end)
  end

  defp map_paths(_, _path), do: []

  defp original_job do
    [_runtime, session, run] = @ids
    definition = Tool.definition()

    {:ok, job} =
      Executor.job(%{
        protocol_version: 1,
        job_id: Base.decode64!(mutation("reserve")["job"]["job_id"]),
        operation_id: Base.decode64!(mutation("reserve")["operation_identity"]["operation_id"]),
        attempt: 1,
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
          "role" => "inspect",
          "description" => "review",
          "prompt" => "inspect exact bytes"
        },
        workspace_ref: "workspace",
        workspace_lease: "lease",
        run_deadline: 2_000_000_000_000,
        resource_budgets: definition["budgets"],
        idempotency_class: definition["idempotency_class"],
        fencing_token: 1,
        artifact_policy: %{"retain" => true},
        output_policy: %{"capture" => true},
        cleanup_grace_ms: 5_000
      })

    job
  end

  defp job_projection(job) do
    %{
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
  end

  defp original_reserve(job) do
    reserve = mutation("reserve")

    reserve
    |> Map.put("job", job_projection(job))
    |> put_in(["source_intent", "canonical_request_digest"], job.canonical_request_digest)
    |> Map.put("task_digest", Canonical.digest(job.validated_arguments))
  end
end
