Code.require_file("../../../loopex/test/support/configured_genesis_helper.exs", __DIR__)

defmodule LoopexComposition.DelegationParentBindingFixture do
  @moduledoc false
  import ExUnit.Assertions
  alias Loopex.Store
  alias LoopexComposition.Delegation.{GenesisCodec, ParentBinding, Tool}
  alias LoopexProtocol.{Frame, ToolDefinition}

  def objects do
    read =
      Loopex.Executor.Local.CodingTools.definitions()
      |> Enum.filter(&(&1["tool_id"] in ~w(loopex.read loopex.grep loopex.find loopex.ls)))

    {:ok, role} = GenesisCodec.encode(genesis(read))

    catalog = %{
      "version" => 1,
      "kind" => "catalog",
      "runtime_id" => Base.encode64("runtime"),
      "providers" => %{"anthropic" => %{"credential" => %{"env" => "HELPER_KEY"}}},
      "roles" => [%{"name" => "inspect", "genesis" => role}]
    }

    declaration = %{
      "version" => 1,
      "kind" => "declaration",
      "enabled" => true,
      "roles" => ["inspect"],
      "max_children" => 2,
      "token_budget" => 32_768,
      "child_bounds" => %{"max_turns" => 4, "deadline_ms" => 600_000, "token_budget" => 8_192},
      "max_tokens" => 1_024,
      "role_budgets" => [
        %{"role" => "inspect", "context_token_budget" => 8_192, "system_class_tokens" => 5_000}
      ]
    }

    options = %{"opaque" => <<255, 0, 128>>, "purpose" => "retained"}
    parent = Map.put(genesis([Tool.definition()]), "options", options)
    {:ok, retained} = GenesisCodec.encode(parent)
    {:ok, tx} = Store.create_session("runtime", "create", parent)
    {id, version, digest} = ToolDefinition.generation(Tool.definition())

    creation = %{
      "version" => 1,
      "kind" => "parent_creation",
      "runtime_id" => Base.encode64("runtime"),
      "command_id" => Base.encode64("create"),
      "original_options" => envelope(:erlang.term_to_binary(options, [:deterministic])),
      "genesis" => retained,
      "catalog_sha256" => hash(json(catalog)),
      "declaration_sha256" => hash(json(declaration)),
      "task_generation" => %{
        "tool_id" => id,
        "tool_version" => version,
        "definition_digest" => digest
      },
      "canonical_create_digest" => Base.encode16(tx.canonical_mutation_digest, case: :lower),
      "input_digest" => ""
    }

    {catalog, declaration, rehash(creation)}
  end

  def genesis(definitions) do
    configuration =
      Loopex.ConfiguredGenesisFixture.configuration()
      |> Map.put("model", "anthropic:retained-literal")
      |> put_in(["model_capabilities", "model"], "anthropic:retained-literal")

    Loopex.ConfiguredGenesisFixture.genesis(definitions, configuration)
    |> Map.put("policy_defer_mode", "refuse")
  end

  def valid_capture do
    {catalog, declaration, creation} = objects()
    {:ok, capture} = capture(catalog, declaration, creation)
    capture
  end

  def capture(catalog, declaration, creation),
    do:
      ParentBinding.capture("runtime", "create", json(catalog), json(declaration), json(creation))

  def json(value) do
    {:ok, encoded} = Frame.encode(value)
    encoded = IO.iodata_to_binary(encoded)
    binary_part(encoded, 0, byte_size(encoded) - 1)
  end

  def rehash(creation) do
    bytes = json(Map.drop(creation, ~w(input_digest canonical_create_digest)))
    Map.put(creation, "input_digest", hash("loopex:helper-create-input:v1" <> <<0>> <> bytes))
  end

  def envelope(bytes),
    do: %{
      "encoding" => "loopex.ledger.plain_etf.v1.base64",
      "bytes" => Base.encode64(bytes),
      "sha256" => hash(bytes)
    }

  def capture_for(command) do
    {catalog, declaration, creation} = objects()
    {:ok, capture} = capture(catalog, declaration, creation)
    {:ok, tx} = Store.create_session("runtime", command, capture.genesis)

    creation =
      creation
      |> Map.put("command_id", Base.encode64(command))
      |> Map.put(
        "canonical_create_digest",
        Base.encode16(tx.canonical_mutation_digest, case: :lower)
      )
      |> rehash()

    {:ok, captured} =
      ParentBinding.capture("runtime", command, json(catalog), json(declaration), json(creation))

    captured
  end

  # Concept: history fixtures observe actual startup readiness before their Store baseline.
  # Technical depth: the shared gate pins Core's original startup identity/cutoff,
  # joins its owned observer and rechecks that retained cutoff before publication.
  def await_startup(runtime) do
    assert {:ok, startup_deadline} = LoopexComposition.StartupGate.await(runtime)
    assert :ok = LoopexComposition.StartupGate.publication({:ok, startup_deadline})
    :ok
  end

  # Concept: both retained-history clients seed creation through the current Store owner.
  # Technical depth: read and claim the actual head, reserve the original final
  # genesis, then verify its exact committed identity and retained terminal capsule.
  def commit_creation(store, capture) do
    {:ok, final} = Store.create_session(capture.runtime, capture.command, capture.genesis)
    {:ok, final_id} = Store.transaction_id(final)
    assert Base.encode16(final.canonical_mutation_digest, case: :lower) ==
             capture.creation["canonical_create_digest"]
    assert final.genesis["options"] == capture.options
    assert {:ok, %{head: head, command: nil}} =
             Store.creation_recovery(store, %{runtime_id: capture.runtime, command_id: nil})
    assert head.active_command_id == nil
    selection = Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)
    {:ok, claim} = Store.claim_creation_domain(capture.runtime, head.owner_generation, selection)
    {:ok, claim_id} = Store.transaction_id(claim)
    assert {:committed, ^claim_id, claimed} = Store.transact(store, claim)
    assert {:ok, %{head: current, command: nil}} =
             Store.creation_recovery(store, %{runtime_id: capture.runtime, command_id: nil})
    assert {current.owner_generation, current.owner_selection, current.domain_version,
            current.active_command_id} ==
             {claimed.owner_generation, claimed.owner_selection, claimed.domain_version, nil}

    {:ok, reserve} = Store.reserve_creation(capture.runtime, capture.command,
      current.owner_generation, current.owner_selection, current.domain_version, final.genesis)
    {:ok, reserve_id} = Store.transaction_id(reserve)
    assert reserve.genesis == final.genesis
    assert {:committed, ^reserve_id, reserved} = Store.transact(store, reserve)
    assert {:ok, %{command: capsule}} =
             Store.creation_recovery(store, %{runtime_id: capture.runtime,
               command_id: capture.command})
    assert capsule.state == :reserved and capsule.genesis == final.genesis
    assert capsule.reservation_tx_id == reserve_id
    assert capsule.reservation_owner_generation == current.owner_generation
    assert capsule.reservation_owner_selection == current.owner_selection
    assert capsule.reservation_domain_version == reserved.reservation_domain_version
    assert capsule.final_resolution == nil and capsule.session_id == nil

    assert {:committed, ^final_id, receipt} = result = Store.transact(store, final)
    assert {:ok, %{head: terminal, command: created}} =
             Store.creation_recovery(store, %{runtime_id: capture.runtime,
               command_id: capture.command})
    assert terminal.active_command_id == nil
    assert created.state == :created and created.final_resolution == :committed
    assert created.genesis == final.genesis and created.session_id == receipt.session_id
    assert created.reservation_tx_id == reserve_id
    result
  end

  def hash(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
