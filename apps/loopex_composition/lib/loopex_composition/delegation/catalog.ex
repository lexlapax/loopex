defmodule LoopexComposition.Delegation.Catalog do
  @moduledoc """
  ## Concept

  Turn saved helper roles and the authored delegation limits into the exact
  retained parent objects that freeze them for one parent session.

  ## Technical depth

  ADR 0046 and ADR 0049 choose what a parent retains: each enabled role's
  exact instructions, model, provider reference, cleanup grace and read-only
  tool selection, plus the finite allowance declaration. ADR 0056 fixes the
  closed catalog, declaration and parent-creation grammars. This producer
  constructs those three canonical objects from already resolved values and
  returns them only after `ParentBinding.capture/5` admits the same bytes, so
  the producer and the validator cannot drift. It reads no file, credential,
  clock, Store or runtime; it creates no session and grants no authority.
  """

  alias Loopex.Runtime.SessionGenesis
  alias Loopex.Store
  alias LoopexComposition.Delegation.{GenesisCodec, LedgerCodec, ParentBinding, Tool}
  alias LoopexProtocol.ToolDefinition

  @encoding "loopex.ledger.plain_etf.v1.base64"
  @read_only ~w(loopex.find loopex.grep loopex.ls loopex.read)
  @limits ~w(child_bounds max_children max_tokens roles token_budget)

  @doc """
  ## Concept

  Resolve one saved role into the fixed genesis every child of that role uses.

  ## Technical depth

  The caller supplies the role's already resolved initial configuration, the
  read/grep/find/ls definitions and the runtime cleanup grace. Defer is
  normalized to refusal and no task or question tool can be selected. Options
  stay empty: each child replaces them with its own original options.
  """
  @spec role_genesis(map(), [map()], pos_integer()) ::
          {:ok, map()} | {:error, :invalid_helper_role}
  def role_genesis(configuration, definitions, cleanup_grace_ms) do
    with true <- is_list(definitions),
         true <- Enum.sort(Enum.map(definitions, & &1["tool_id"])) == @read_only,
         true <- Enum.all?(definitions, &(&1["effect_class"] == "read_only")),
         {:ok, genesis} <-
           SessionGenesis.resolve(%{}, %{
             genesis_version: "session_genesis_v3",
             runtime_configuration: %{"cleanup_grace_ms" => cleanup_grace_ms},
             initial_configuration: configuration,
             tool_selection: %{"definitions" => definitions, "names" => names(definitions)},
             policy_defer_mode: "refuse"
           }) do
      {:ok, genesis}
    else
      _ -> {:error, :invalid_helper_role}
    end
  rescue
    _ -> {:error, :invalid_helper_role}
  end

  @doc """
  ## Concept

  Build and validate the exact parent catalog, declaration and creation bytes.

  ## Technical depth

  `roles` maps every enabled role name to its role genesis; the catalog lists
  them in bytewise name order. `limits` holds the authored `roles` order,
  `max_children`, aggregate `token_budget`, `child_bounds` and `max_tokens`.
  Per-role context and system budgets come from each role's own genesis, not
  from a second authored copy. The parent genesis must already select the
  fixed task generation. The result is the validated parent capture whose
  `object_bytes` are what the retained-object owner installs before prepare.
  """
  @spec capture(binary(), binary(), map(), map(), map(), map(), map()) ::
          {:ok, map()} | {:error, :invalid_parent_capture}
  def capture(runtime_id, command_id, providers, roles, limits, parent_options, parent_genesis) do
    with true <- is_map(roles) and is_map(limits) and Enum.sort(Map.keys(limits)) == @limits,
         {:ok, entries} <- catalog_roles(roles),
         catalog = %{
           "version" => 1,
           "kind" => "catalog",
           "runtime_id" => Base.encode64(runtime_id),
           "providers" => providers,
           "roles" => entries
         },
         {:ok, budgets} <- role_budgets(limits["roles"], roles),
         declaration =
           Map.merge(limits, %{
             "version" => 1,
             "kind" => "declaration",
             "enabled" => true,
             "role_budgets" => budgets
           }),
         {:ok, catalog_bytes} <- LedgerCodec.encode_json(catalog, :object),
         {:ok, declaration_bytes} <- LedgerCodec.encode_json(declaration, :object),
         {:ok, creation} <-
           creation(
             runtime_id,
             command_id,
             parent_options,
             parent_genesis,
             hash(catalog_bytes),
             hash(declaration_bytes)
           ),
         {:ok, creation_bytes} <- LedgerCodec.encode_json(creation, :object) do
      ParentBinding.capture(
        runtime_id,
        command_id,
        catalog_bytes,
        declaration_bytes,
        creation_bytes
      )
    else
      _ -> {:error, :invalid_parent_capture}
    end
  rescue
    _ -> {:error, :invalid_parent_capture}
  end

  @doc """
  ## Concept

  The exact catalog digest a helper parent's instructions name.

  ## Technical depth

  ADR 0042's `catalog_digest` host fact is `sha256:` plus the address of the
  same canonical catalog object `capture/7` retains, so instructions and the
  retained catalog cannot disagree. It needs the runtime identity because the
  catalog binds it.
  """
  @spec digest(binary(), map(), map()) :: {:ok, binary()} | {:error, :invalid_parent_capture}
  def digest(runtime_id, providers, roles) do
    with {:ok, entries} <- catalog_roles(roles),
         {:ok, bytes} <-
           LedgerCodec.encode_json(
             %{
               "version" => 1,
               "kind" => "catalog",
               "runtime_id" => Base.encode64(runtime_id),
               "providers" => providers,
               "roles" => entries
             },
             :object
           ) do
      {:ok, "sha256:" <> hash(bytes)}
    else
      _ -> {:error, :invalid_parent_capture}
    end
  end

  defp catalog_roles(roles) do
    roles
    |> Enum.sort_by(fn {name, _} -> name end)
    |> Enum.reduce_while({:ok, []}, fn {name, genesis}, {:ok, acc} ->
      case GenesisCodec.encode(genesis) do
        {:ok, retained} -> {:cont, {:ok, acc ++ [%{"name" => name, "genesis" => retained}]}}
        _ -> {:halt, :error}
      end
    end)
  end

  defp role_budgets(names, roles) when is_list(names) do
    Enum.reduce_while(names, {:ok, []}, fn name, {:ok, acc} ->
      case roles do
        %{^name => %{"initial_configuration" => configuration}} ->
          budget = %{
            "role" => name,
            "context_token_budget" => configuration["context_token_budget"],
            "system_class_tokens" => configuration["system_class_tokens"]
          }

          {:cont, {:ok, acc ++ [budget]}}

        _ ->
          {:halt, :error}
      end
    end)
  end

  defp role_budgets(_, _), do: :error

  defp creation(runtime_id, command_id, options, genesis, catalog_sha256, declaration_sha256) do
    {id, version, digest} = ToolDefinition.generation(Tool.definition())
    options_bytes = :erlang.term_to_binary(options, [:deterministic])

    with {:ok, retained} <- GenesisCodec.encode(genesis),
         {:ok, transaction} <- Store.create_session(runtime_id, command_id, genesis) do
      creation = %{
        "version" => 1,
        "kind" => "parent_creation",
        "runtime_id" => Base.encode64(runtime_id),
        "command_id" => Base.encode64(command_id),
        "original_options" => %{
          "encoding" => @encoding,
          "bytes" => Base.encode64(options_bytes),
          "sha256" => hash(options_bytes)
        },
        "genesis" => retained,
        "catalog_sha256" => catalog_sha256,
        "declaration_sha256" => declaration_sha256,
        "task_generation" => %{
          "tool_id" => id,
          "tool_version" => version,
          "definition_digest" => digest
        },
        "canonical_create_digest" =>
          Base.encode16(transaction.canonical_mutation_digest, case: :lower)
      }

      with {:ok, input} <- domain("loopex:helper-create-input:v1", creation),
           do: {:ok, Map.put(creation, "input_digest", input)}
    end
  end

  defp names(definitions) do
    Map.new(definitions, fn definition ->
      {id, version, digest} = ToolDefinition.generation(definition)

      {definition["name"],
       %{"tool_id" => id, "tool_version" => version, "definition_digest" => digest}}
    end)
  end

  # Concept: input_digest uses the accepted domain-separated canonical preimage.
  # Technical depth: the preimage is the closed creation without both digests;
  # canonical_create_digest is dropped here because it is not yet a member.
  defp domain(label, creation) do
    value = Map.delete(creation, "canonical_create_digest")

    with {:ok, wrapped} <- LedgerCodec.encode_json(%{"v" => value}, :object) do
      bytes = binary_part(wrapped, 5, byte_size(wrapped) - 6)
      {:ok, hash(label <> <<0>> <> bytes)}
    end
  end

  defp hash(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
