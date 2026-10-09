Code.require_file("support/delegation_parent_binding_fixture.exs", __DIR__)

defmodule LoopexComposition.DelegationCatalogTest do
  use ExUnit.Case, async: true

  alias LoopexComposition.Delegation.{Catalog, GenesisCodec, ParentBinding, Tool}
  alias LoopexComposition.DelegationParentBindingFixture, as: Fixture

  @providers %{"anthropic" => %{"credential" => %{"env" => "HELPER_KEY"}}}
  @limits %{
    "roles" => ["inspect"],
    "max_children" => 2,
    "token_budget" => 32_768,
    "child_bounds" => %{"max_turns" => 4, "deadline_ms" => 600_000, "token_budget" => 8_192},
    "max_tokens" => 1_024
  }
  @options %{"opaque" => <<255, 0, 128>>, "purpose" => "retained"}

  test "saved roles produce exactly the independently authored retained parent objects" do
    {catalog, declaration, creation} = Fixture.objects()
    assert {:ok, capture} = produce(%{"inspect" => role()}, @limits)

    assert capture.object_bytes ==
             [Fixture.json(catalog), Fixture.json(declaration), Fixture.json(creation)]

    assert capture.object_bytes == Fixture.valid_capture().object_bytes

    assert ParentBinding.capture(
             "runtime",
             "create",
             Enum.at(capture.object_bytes, 0),
             Enum.at(capture.object_bytes, 1),
             Enum.at(capture.object_bytes, 2)
           ) ==
             {:ok, capture}
  end

  test "the instruction catalog fact is exactly the retained catalog object address" do
    roles = %{"inspect" => role()}
    assert {:ok, capture} = produce(roles, @limits)
    assert {:ok, digest} = Catalog.digest("runtime", @providers, roles)
    assert digest == "sha256:" <> capture.creation["catalog_sha256"]
    assert {:ok, other} = Catalog.digest("other-runtime", @providers, roles)
    refute other == digest

    assert Catalog.digest("runtime", @providers, %{"inspect" => %{}}) ==
             {:error, :invalid_parent_capture}
  end

  test "role genesis freezes exact read-only tools, refusal mode and cleanup grace" do
    genesis = role()
    assert genesis["policy_defer_mode"] == "refuse" and genesis["options"] == %{}
    assert genesis["runtime_configuration"] == %{"cleanup_grace_ms" => 5_000}

    assert Enum.sort(Enum.map(genesis["tool_selection"]["definitions"], & &1["tool_id"])) ==
             ~w(loopex.find loopex.grep loopex.ls loopex.read)

    refute Enum.any?(genesis["tool_selection"]["definitions"], &(&1["tool_id"] == "loopex.task"))
    assert {:ok, ^genesis} = GenesisCodec.encode(genesis) |> elem(1) |> GenesisCodec.decode()

    write =
      Loopex.Executor.Local.CodingTools.definitions()
      |> Enum.filter(&(&1["tool_id"] in ~w(loopex.write loopex.grep loopex.find loopex.ls)))

    for definitions <- [write, read() ++ [Tool.definition()], tl(read()), [], nil] do
      assert Catalog.role_genesis(configuration(), definitions, 5_000) ==
               {:error, :invalid_helper_role}
    end

    assert Catalog.role_genesis(configuration(), read(), 0) == {:error, :invalid_helper_role}
  end

  test "catalog names sort bytewise while the authored enabled order is preserved" do
    limits = Map.put(@limits, "roles", ["review", "inspect"])
    assert {:ok, capture} = produce(%{"inspect" => role(), "review" => role()}, limits)
    assert Enum.map(capture.catalog["roles"], & &1["name"]) == ["inspect", "review"]
    assert capture.declaration["roles"] == ["review", "inspect"]
    assert Enum.map(capture.declaration["role_budgets"], & &1["role"]) == ["review", "inspect"]

    assert capture.declaration["role_budgets"] ==
             for(
               name <- ["review", "inspect"],
               do: %{
                 "role" => name,
                 "context_token_budget" => 8_192,
                 "system_class_tokens" => 5_000
               }
             )
  end

  test "unbounded, missing, widened or unbound selections refuse before any object is retained" do
    roles = %{"inspect" => role()}

    for limits <- [
          Map.put(@limits, "max_children", 129),
          Map.put(@limits, "max_children", 0),
          Map.put(@limits, "token_budget", 0),
          Map.put(@limits, "roles", ["missing"]),
          Map.put(@limits, "roles", []),
          Map.put(@limits, "max_tokens", 2_048),
          put_in(@limits, ["child_bounds", "deadline_ms"], 600_001),
          Map.put(@limits, "enabled", true),
          Map.delete(@limits, "max_tokens")
        ] do
      assert produce(roles, limits) == {:error, :invalid_parent_capture}
    end

    assert produce(%{}, @limits) == {:error, :invalid_parent_capture}
    assert produce(%{"Inspect" => role()}, @limits) == {:error, :invalid_parent_capture}

    assert Catalog.capture(
             "runtime",
             "create",
             %{"anthropic" => %{"credential" => %{"value" => "secret"}}},
             roles,
             @limits,
             @options,
             parent()
           ) == {:error, :invalid_parent_capture}

    without_task = Map.put(Fixture.genesis(read()), "options", @options)

    assert Catalog.capture(
             "runtime",
             "create",
             @providers,
             roles,
             @limits,
             @options,
             without_task
           ) ==
             {:error, :invalid_parent_capture}

    assert Catalog.capture("runtime", "create", @providers, roles, @limits, %{}, parent()) ==
             {:error, :invalid_parent_capture}
  end

  defp produce(roles, limits),
    do: Catalog.capture("runtime", "create", @providers, roles, limits, @options, parent())

  defp parent, do: Map.put(Fixture.genesis([Tool.definition()]), "options", @options)

  defp role do
    assert {:ok, genesis} = Catalog.role_genesis(configuration(), read(), 5_000)
    genesis
  end

  defp configuration, do: Fixture.genesis([])["initial_configuration"]

  defp read do
    Loopex.Executor.Local.CodingTools.definitions()
    |> Enum.filter(&(&1["tool_id"] in ~w(loopex.read loopex.grep loopex.find loopex.ls)))
  end
end
