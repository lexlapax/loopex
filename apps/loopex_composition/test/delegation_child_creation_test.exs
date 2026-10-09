Code.require_file("support/delegation_parent_binding_fixture.exs", __DIR__)

defmodule LoopexComposition.DelegationChildCreationTest do
  use ExUnit.Case, async: true

  alias Loopex.Store
  alias Loopex.Runtime.SessionGenesis
  alias LoopexComposition.Delegation.{ChildCreation, GenesisCodec, LedgerCodec, Tool}
  alias LoopexComposition.DelegationParentBindingFixture, as: Fixture

  @create "8a209c9ff81aeb672b3ddf10ad54974d6109a5e0ea40b6973db055f0dbf5bc19"
  @prompt "5b9b0359df5dd617975a3c3b602ca4d74c1ba6eb8dfd7ee801bb36c969b73e53"
  @error {:error, :invalid_child_creation}

  test "literal opaque operation preimage and original Core identity join exact object facts" do
    {parent, object, genesis} = fixture()
    bytes = json(object)
    preimage = ~s(["cnVudGltZQ==",{"operation_id":"b3AA/g==","parent_run_id":"cnVugA==","parent_session_id":"cGFyZW50AP8="}])
    assert hash("loopex:helper-create:v1" <> <<0>> <> preimage) == @create
    assert hash("loopex:helper-prompt:v1" <> <<0>> <> preimage) == @prompt
    assert {:ok, facts} = ChildCreation.validate(bytes, parent, 4_096)
    assert facts.creation == object and facts.object_bytes == bytes
    assert facts.creation_sha256 == hash(bytes)
    assert facts.runtime_id == "runtime" and facts.operation_identity == operation()
    assert facts.role == "inspect" and facts.command_id == @create
    assert facts.prompt_command_id == @prompt and facts.reserved_tokens == 4_096
    assert facts.genesis == genesis and facts.options == genesis["options"]
    assert facts.options["opaque"] == <<255, 0, 128>>
    assert facts.declaration == parent.declaration
    assert {:ok, tx} = Store.create_session("runtime", @create, genesis)
    assert object["canonical_create_digest"] == Base.encode16(tx.canonical_mutation_digest, case: :lower)
  end

  test "mutable parent projections cannot replace the retained catalog or declaration" do
    {parent, object, _} = fixture()
    changed = %{parent | catalog: %{}, declaration: %{}, genesis: %{}, options: %{}}
    assert ChildCreation.validate(json(object), changed, 4_096) ==
             ChildCreation.validate(json(object), parent, 4_096)
    for changed <- [nil, %{}, %{parent | object_bytes: []}, %{parent | runtime: "other"},
                    %{parent | command: "other"}] do
      assert ChildCreation.validate(json(object), changed, 4_096) == @error
    end
  end

  test "canonical JSON refuses duplicates alternate spelling and complete over-cap bytes" do
    {parent, object, _} = fixture()
    bytes = json(object)
    duplicate = String.replace(bytes, ~s("kind":"child_creation"),
      ~s("kind":"child_creation","kind":"child_creation"))
    escaped = String.replace(bytes, ~s("inspect"), ~S("\u0069nspect"))
    for invalid <- [duplicate, escaped, " " <> bytes, bytes <> "\n", <<239, 187, 191>> <> bytes,
                    String.replace(bytes, ~s("version":1), ~s("version":1.0)),
                    String.duplicate(" ", 1_048_577), <<255>>, nil, %{}] do
      assert ChildCreation.validate(invalid, parent, 4_096) == @error
    end
  end

  test "every required child member is mandatory and unknown fields or versions refuse" do
    {parent, object, _} = fixture()
    for key <- Map.keys(object) do
      assert ChildCreation.validate(json(Map.delete(object, key)), parent, 4_096) == @error
    end
    for changed <- [Map.put(object, "extra", nil), %{object | "version" => 2},
                    %{object | "kind" => "parent_creation"}] do
      assert ChildCreation.validate(json(rehash(changed)), parent, 4_096) == @error
    end
  end

  test "original runtime and both captured content addresses cannot be substituted" do
    {parent, object, _} = fixture()
    for {key, value} <- [{"runtime_id", Base.encode64("other")},
                         {"runtime_id", "cnVudGltZQ"},
                         {"catalog_sha256", String.duplicate("0", 64)},
                         {"declaration_sha256", String.duplicate("1", 64)}] do
      assert ChildCreation.validate(json(rehash(Map.put(object, key, value))), parent, 4_096) == @error
    end
  end

  test "operation identities are closed padded bounded opaque IDs" do
    {parent, object, _} = fixture()
    for key <- Map.keys(operation()) do
      limit = if key == "operation_id", do: 8_192, else: 256
      for value <- ["", "!", "b3AA/g", Base.encode64(String.duplicate("i", limit + 1)), nil, 1] do
        changed = put_in(object, ["operation_identity", key], value)
        assert ChildCreation.validate(json(rehash(changed)), parent, 4_096) == @error
      end
    end
    for op <- [Map.put(operation(), "attempt", 2), Map.delete(operation(), "operation_id"), []] do
      assert ChildCreation.validate(json(rehash(%{object | "operation_identity" => op})), parent, 4_096) == @error
    end
  end

  test "parent IDs at256 and executor operation ID at8192 retain exact derived identities" do
    {parent, object, genesis} = fixture()
    for {key, limit} <- [{"parent_session_id", 256}, {"parent_run_id", 256}, {"operation_id", 8_192}] do
      op = Map.put(operation(), key, Base.encode64(String.duplicate("i", limit)))
      preimage = ~s(["cnVudGltZQ==",) <> json(op) <> "]"
      create = hash("loopex:helper-create:v1" <> <<0>> <> preimage)
      prompt = hash("loopex:helper-prompt:v1" <> <<0>> <> preimage)
      changed = object |> Map.put("operation_identity", op)
        |> Map.put("command_id", Base.encode64(create)) |> with_genesis(genesis)
      assert {:ok, facts} = ChildCreation.validate(json(changed), parent, 4_096)
      assert facts.operation_identity == op
      assert facts.command_id == create and facts.prompt_command_id == prompt
      too_large = put_in(changed, ["operation_identity", key],
        Base.encode64(String.duplicate("i", limit + 1)))
      assert ChildCreation.validate(json(rehash(too_large)), parent, 4_096) == @error
    end
  end

  test "changed operation cannot retain original derived command or owning create digest" do
    {parent, object, _} = fixture()
    changed = put_in(object, ["operation_identity", "operation_id"], Base.encode64("other"))
    assert ChildCreation.validate(json(rehash(changed)), parent, 4_096) == @error
    for command <- [Base.encode64("arbitrary"), Base.encode64(@prompt), @create] do
      assert ChildCreation.validate(json(rehash(%{object | "command_id" => command})), parent, 4_096) == @error
    end
  end

  test "input digest and Core create digest are independently required original owners" do
    {parent, object, _} = fixture()
    for key <- ~w(input_digest canonical_create_digest), value <- ["", String.duplicate("0", 64),
                                                                         "A" <> binary_part(object[key], 1, 63)] do
      assert ChildCreation.validate(json(Map.put(object, key, value)), parent, 4_096) == @error
    end
    assert ChildCreation.validate(json(%{object | "canonical_create_digest" => object["input_digest"]}), parent, 4_096) == @error
  end

  test "only authored enabled roles in the retained catalog admit" do
    {catalog, declaration, creation} = Fixture.objects()
    catalog = Map.put(catalog, "roles", catalog["roles"] ++
      [%{"name" => "other", "genesis" => hd(catalog["roles"])["genesis"]}])
    parent = parent(catalog, declaration, creation)
    {_, object, _} = fixture(parent)
    for role <- ["other", "missing", "Inspect", "inspect\n"] do
      assert ChildCreation.validate(json(rehash(%{object | "role" => role})), parent, 4_096) == @error
    end
  end

  test "valid Core genesis cannot substitute captured reply model context instructions or cleanup" do
    {parent, object, genesis} = fixture()
    instructions = Loopex.ConfiguredGenesisFixture.configuration("Different captured instruction.")["instructions"]
    context = genesis |> put_in(["initial_configuration", "context_token_budget"], 8_191)
      |> put_in(["initial_configuration", "budget_origins", "context_token_budget"], "explicit")
    model = genesis |> put_in(["initial_configuration", "model"], "anthropic:other")
      |> put_in(["initial_configuration", "model_capabilities", "model"], "anthropic:other")
    for changed <- [put_in(genesis, ["runtime_configuration", "cleanup_grace_ms"], 5_001),
                    put_in(genesis, ["initial_configuration", "max_tokens"], 1_025),
                    put_in(genesis, ["initial_configuration", "system_class_tokens"], 5_001),
                    put_in(genesis, ["initial_configuration", "instructions"], instructions),
                    context, model] do
      assert {:ok, ^changed} = SessionGenesis.normalize(changed)
      changed_object = with_genesis(object, changed)
      assert ChildCreation.validate(json(changed_object), parent, 4_096) == @error
    end
  end

  test "captured immutable tools and refuse policy cannot be replaced by valid Core selections" do
    {parent, object, genesis} = fixture()
    nested = Fixture.genesis([Tool.definition()]) |> Map.put("options", genesis["options"])
    for changed <- [Map.put(genesis, "policy_defer_mode", "admit"), nested,
                    put_in(genesis, ["tool_selection", "definitions"],
                      Enum.reverse(genesis["tool_selection"]["definitions"]))] do
      assert {:ok, ^changed} = SessionGenesis.normalize(changed)
      assert ChildCreation.validate(json(with_genesis(object, changed)), parent, 4_096) == @error
    end
  end

  test "revalidated parent refuses invalid role tools policy routes and declaration reply limits" do
    {parent, object, genesis} = fixture()
    {catalog, declaration, creation} = Fixture.objects()
    assert {:ok, _} = Fixture.capture(catalog, declaration, creation)
    assert {:ok, _} = ChildCreation.validate(json(object), parent, 4_096)
    {:ok, role} = GenesisCodec.decode(hd(catalog["roles"])["genesis"])
    for changed_role <- [Map.put(role, "policy_defer_mode", "admit"), Fixture.genesis([]),
                          Fixture.genesis([Tool.definition()])] do
      assert {:ok, ^changed_role} = SessionGenesis.normalize(changed_role)
      {:ok, retained} = GenesisCodec.encode(changed_role)
      changed_catalog = put_in(catalog, ["roles", Access.at(0), "genesis"], retained)
      changed_child = Map.put(changed_role, "options", genesis["options"])
      assert {:ok, ^changed_child} = SessionGenesis.normalize(changed_child)
      raw = raw_parent(parent, changed_catalog, declaration, creation)
      changed = child_for_parent(object, changed_catalog, declaration, changed_child)
      assert Fixture.capture(changed_catalog, declaration,
        parent_creation(changed_catalog, declaration, creation)) == {:error, :invalid_parent_capture}
      assert ChildCreation.validate(json(changed), raw, 4_096) == @error
    end
    for changed_declaration <- [Map.put(declaration, "max_tokens", 1_025),
                               Map.put(declaration, "enabled", false)] do
      raw = raw_parent(parent, catalog, changed_declaration, creation)
      changed = child_for_parent(object, catalog, changed_declaration, genesis)
      assert {:ok, ^genesis} = SessionGenesis.normalize(genesis)
      assert Fixture.capture(catalog, changed_declaration,
        parent_creation(catalog, changed_declaration, creation)) == {:error, :invalid_parent_capture}
      assert ChildCreation.validate(json(changed), raw, 4_096) == @error
    end
    bad = put_in(catalog, ["providers", "anthropic", "credential"], %{"env" => "PATH"})
    raw = raw_parent(parent, bad, declaration, creation)
    changed = child_for_parent(object, bad, declaration, genesis)
    assert Fixture.capture(bad, declaration,
      parent_creation(bad, declaration, creation)) == {:error, :invalid_parent_capture}
    assert ChildCreation.validate(json(changed), raw, 4_096) == @error
  end

  test "plain original options normalize only through Store and must equal decoded genesis options" do
    {parent, object, genesis} = fixture()
    raw = %{opaque: <<255, 0, 128>>, purpose: "retained child"}
    {:ok, %{"options" => normalized}, _} =
      Store.normalize_and_measure_item(:record, %{"options" => raw, kind: "original_options"})
    assert normalized == genesis["options"]
    atom_options = %{object | "original_options" => envelope(:erlang.term_to_binary(raw))}
    assert {:ok, facts} = ChildCreation.validate(json(rehash(atom_options)), parent, 4_096)
    assert facts.options == normalized
    mismatch = %{object | "original_options" => envelope(:erlang.term_to_binary(%{"other" => true}))}
    assert ChildCreation.validate(json(rehash(mismatch)), parent, 4_096) == @error
  end

  test "options refuse compressed trailing unsafe struct and non-map ETF" do
    {parent, object, genesis} = fixture()
    padded = put_in(genesis, ["options", "padding"], String.duplicate("x", 10_000))
    plain = with_genesis(object, padded)
    assert {:ok, ^padded} = SessionGenesis.normalize(padded)
    assert {:ok, facts} = ChildCreation.validate(json(plain), parent, 4_096)
    assert facts.options == padded["options"]
    compressed = :erlang.term_to_binary(padded["options"], [:compressed])
    assert <<131, 80, _::binary>> = compressed
    assert :erlang.binary_to_term(compressed, [:safe]) == padded["options"]
    assert {:ok, %{"options" => options}, _} = Store.normalize_and_measure_item(:record,
      %{"options" => :erlang.binary_to_term(compressed, [:safe]), kind: "original_options"})
    assert options == padded["options"]
    changed = %{plain | "original_options" => envelope(compressed)} |> rehash()
    assert changed["genesis"] == plain["genesis"]
    assert changed["canonical_create_digest"] == plain["canonical_create_digest"]
    assert ChildCreation.validate(json(changed), parent, 4_096) == @error

    good = :erlang.term_to_binary(genesis["options"])
    unsafe = [self(), make_ref(), fn -> :ok end, MapSet.new(), {:opaque, "value"}, [1 | 2]]
    invalid = [good <> <<0>>, <<>>, :erlang.term_to_binary([])] ++
      Enum.map(unsafe, &:erlang.term_to_binary(%{"unsafe" => &1}))
    for bytes <- invalid do
      changed = %{object | "original_options" => envelope(bytes)}
      assert ChildCreation.validate(json(rehash(changed)), parent, 4_096) == @error
    end
  end

  test "options envelopes refuse open members digest mismatch base64 variants and payload over-cap" do
    {parent, object, _} = fixture()
    original = object["original_options"]
    for changed <- [Map.put(original, "extra", nil), Map.delete(original, "sha256"),
                    Map.put(original, "sha256", "A" <> binary_part(original["sha256"], 1, 63)),
                    Map.put(original, "bytes", original["bytes"] <> "\n"),
                    Map.put(original, "encoding", "other"),
                    envelope(:erlang.term_to_binary(%{"padding" => String.duplicate("p", 65_537)}))] do
      assert ChildCreation.validate(json(rehash(%{object | "original_options" => changed})), parent, 4_096) == @error
    end
  end

  test "retained options cannot intern a new atom through a correctly hashed ETF payload" do
    {parent, object, _} = fixture()
    name = "m7_child_options_atom_" <> Integer.to_string(System.unique_integer([:positive]))
    assert_raise ArgumentError, fn -> String.to_existing_atom(name) end
    original = :erlang.term_to_binary(%{"untrusted" => name})
    forged = :binary.replace(original, <<109, byte_size(name)::32, name::binary>>,
      <<119, byte_size(name), name::binary>>)
    refute forged == original
    assert ChildCreation.validate(json(rehash(%{object | "original_options" => envelope(forged)})), parent, 4_096) == @error
    assert_raise ArgumentError, fn -> String.to_existing_atom(name) end
  end

  test "complete genesis ceiling counts original options while object JSON counts base64 expansion" do
    {parent, object, genesis} = fixture()
    empty = Map.put(genesis, "options", %{"padding" => ""})
    overhead = :erlang.external_size(empty, [:deterministic])
    for size <- [65_535, 65_536] do
      full = put_in(empty, ["options", "padding"], String.duplicate("g", size - overhead))
      assert :erlang.external_size(full, [:deterministic]) == size
      changed = with_genesis(object, full)
      bytes = json(changed)
      assert byte_size(bytes) > 65_536 and byte_size(bytes) < 1_048_576
      assert {:ok, facts} = ChildCreation.validate(bytes, parent, 4_096)
      assert facts.genesis == full
    end
    too_large = put_in(empty, ["options", "padding"], String.duplicate("g", 65_537 - overhead))
    assert GenesisCodec.encode(too_large) == {:error, :invalid_retained_genesis}
    raw = %{object | "genesis" => envelope(:erlang.term_to_binary(too_large, [:deterministic]))}
    assert ChildCreation.validate(json(rehash(raw)), parent, 4_096) == @error
  end

  test "reservation threshold stays positive bounded and exact without allocating an allowance" do
    {parent, object, _} = fixture()
    for tokens <- [1, 4_096, 8_192] do
      assert {:ok, %{reserved_tokens: ^tokens}} = ChildCreation.validate(json(object), parent, tokens)
    end
    for tokens <- [0, -1, 8_193, 1.0, nil] do
      assert ChildCreation.validate(json(object), parent, tokens) == @error
    end
    {catalog, declaration, creation} = Fixture.objects()
    small = parent(catalog, Map.put(declaration, "token_budget", 2_048), creation)
    {_, object, _} = fixture(small)
    assert {:ok, _} = ChildCreation.validate(json(object), small, 2_048)
    assert ChildCreation.validate(json(object), small, 2_049) == @error
  end

  test "authored turn and token integers above uint64 remain exact in the retained declaration" do
    {catalog, declaration, creation} = Fixture.objects()
    huge = 18_446_744_073_709_551_617
    declaration = declaration |> Map.put("token_budget", huge)
      |> put_in(["child_bounds", "token_budget"], huge)
      |> put_in(["child_bounds", "max_turns"], huge)
    parent = parent(catalog, declaration, creation)
    {_, object, _} = fixture(parent)
    assert {:ok, facts} = ChildCreation.validate(json(object), parent, huge)
    assert facts.reserved_tokens == huge
    assert facts.declaration["child_bounds"]["max_turns"] == huge
    assert facts.declaration["child_bounds"]["deadline_ms"] == 600_000
    assert facts.declaration["max_tokens"] == facts.genesis["initial_configuration"]["max_tokens"]
  end

  test "child genesis delegates complete envelope and unsafe term refusal to its owning codec" do
    {parent, object, genesis} = fixture()
    padded = put_in(genesis, ["options", "padding"], String.duplicate("g", 10_000))
    plain = with_genesis(object, padded)
    assert {:ok, ^padded} = SessionGenesis.normalize(padded)
    assert {:ok, ^padded} = GenesisCodec.decode(plain["genesis"])
    assert {:ok, facts} = ChildCreation.validate(json(plain), parent, 4_096)
    assert facts.genesis == padded and facts.options == padded["options"]
    compressed = :erlang.term_to_binary(padded, [:compressed])
    assert <<131, 80, _::binary>> = compressed
    assert :erlang.binary_to_term(compressed, [:safe]) == padded
    assert GenesisCodec.decode(envelope(compressed)) == {:error, :invalid_retained_genesis}
    changed = %{plain | "genesis" => envelope(compressed)} |> rehash()
    assert changed["original_options"] == plain["original_options"]
    assert changed["canonical_create_digest"] == plain["canonical_create_digest"]
    assert ChildCreation.validate(json(changed), parent, 4_096) == @error

    raw = :erlang.term_to_binary(genesis, [:deterministic])
    unsafe = put_in(genesis, ["options", "unsafe"], self())
    for retained <- [envelope(raw <> <<0>>), envelope(:erlang.term_to_binary(unsafe)),
                      Map.put(object["genesis"], "extra", nil),
                      Map.put(object["genesis"], "sha256", String.duplicate("0", 64))] do
      changed = %{object | "genesis" => retained}
      assert ChildCreation.validate(json(rehash(changed)), parent, 4_096) == @error
    end
  end

  defp fixture(parent \\ Fixture.valid_capture()) do
    {:ok, selected} = GenesisCodec.decode(hd(parent.catalog["roles"])["genesis"])
    genesis = Map.put(selected, "options", %{"opaque" => <<255, 0, 128>>, "purpose" => "retained child"})
    object = %{
      "version" => 1, "kind" => "child_creation", "runtime_id" => Base.encode64(parent.runtime),
      "operation_identity" => operation(), "role" => "inspect",
      "catalog_sha256" => parent.creation["catalog_sha256"],
      "declaration_sha256" => parent.creation["declaration_sha256"],
      "command_id" => Base.encode64(@create), "original_options" => nil, "genesis" => nil,
      "input_digest" => "", "canonical_create_digest" => ""
    }
    {parent, with_genesis(object, genesis), genesis}
  end

  defp operation do
    %{"parent_session_id" => "cGFyZW50AP8=", "parent_run_id" => "cnVugA==", "operation_id" => "b3AA/g=="}
  end

  defp with_genesis(object, genesis) do
    {:ok, retained} = GenesisCodec.encode(genesis)
    {:ok, tx} = Store.create_session(Base.decode64!(object["runtime_id"]),
      Base.decode64!(object["command_id"]), genesis)
    object |> Map.put("genesis", retained)
      |> Map.put("original_options", envelope(:erlang.term_to_binary(genesis["options"], [:deterministic])))
      |> Map.put("canonical_create_digest", Base.encode16(tx.canonical_mutation_digest, case: :lower))
      |> rehash()
  end

  defp child_for_parent(object, catalog, declaration, genesis) do
    object |> Map.put("catalog_sha256", hash(json(catalog)))
      |> Map.put("declaration_sha256", hash(json(declaration)))
      |> with_genesis(genesis)
  end

  defp parent(catalog, declaration, creation) do
    creation = parent_creation(catalog, declaration, creation)
    assert {:ok, parent} = Fixture.capture(catalog, declaration, creation)
    parent
  end

  defp raw_parent(parent, catalog, declaration, creation) do
    creation = parent_creation(catalog, declaration, creation)
    %{parent | object_bytes: Enum.map([catalog, declaration, creation], &json/1)}
  end

  defp parent_creation(catalog, declaration, creation) do
    creation |> Map.put("catalog_sha256", hash(json(catalog)))
      |> Map.put("declaration_sha256", hash(json(declaration)))
      |> Fixture.rehash()
  end

  defp rehash(object) do
    Map.put(object, "input_digest", hash("loopex:helper-create-input:v1" <> <<0>> <>
      json(Map.drop(object, ~w(input_digest canonical_create_digest)))))
  end

  defp envelope(bytes), do: Fixture.envelope(bytes)

  defp json(value) do
    {:ok, bytes} = LedgerCodec.encode_json(value, :object)
    bytes
  end

  defp hash(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
