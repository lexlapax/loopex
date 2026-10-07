defmodule LoopexComposition.Delegation.ParentBinding do
  @moduledoc """
  ## Concept

  Validate captured helper parent inputs and reduce their prepare/bind prefix
  without creating sessions or treating ledger bytes as authority.

  ## Technical depth

  This internal ADR 0056 boundary owns only the two parent-binding mutations.
  Core owns genesis, options, creation identity and historical observations.
  Captures retain original object bytes. The fold returns semantic state and
  expected result projections, never a sync acknowledgement or a verification
  capability. Its history input must be obtained by the composition owner using
  observe_creation/2; a six-field projection alone authenticates no producer.
  Later physical ownership must establish object sync and exclusive custody
  before appending. Missing creation evidence retains all completion credit.
  """

  alias Loopex.Runtime
  alias Loopex.Store
  alias Loopex.Store.CreationProvenance
  alias Loopex.LLM.ReqLLM.HostBindings
  alias LoopexComposition.ProviderBindings
  alias LoopexComposition.Delegation.{GenesisCodec, LedgerCodec, Tool}
  alias LoopexProtocol.ToolDefinition

  @credit 65_614
  @cap 1_048_576
  @uint64 18_446_744_073_709_551_615
  @encoding "loopex.ledger.plain_etf.v1.base64"
  @role ~r/\A[a-z][a-z0-9_-]{0,63}\z/

  @doc false
  def capture(runtime, command, catalog_bytes, declaration_bytes, creation_bytes) do
    with true <- identifier?(runtime) and identifier?(command),
         {:ok, catalog} <- LedgerCodec.decode_json(catalog_bytes, :object),
         {:ok, declaration} <- LedgerCodec.decode_json(declaration_bytes, :object),
         {:ok, creation} <- LedgerCodec.decode_json(creation_bytes, :object),
         {:ok, roles} <- catalog(catalog, runtime),
         :ok <- declaration(declaration, roles),
         {:ok, genesis, options} <-
           creation(creation, runtime, command, catalog_bytes, declaration_bytes),
         {:ok, key} <- LedgerCodec.header_key(:binding, [runtime, command]),
         {:ok, header} <- LedgerCodec.encode_header(:binding, [runtime, command]) do
      {:ok,
       %{
         runtime: runtime,
         command: command,
         catalog: catalog,
         declaration: declaration,
         creation: creation,
         genesis: genesis,
         options: options,
         creation_sha256: hash(creation_bytes),
         object_bytes: [catalog_bytes, declaration_bytes, creation_bytes],
         key: key,
         header: header
       }}
    else
      _ -> {:error, :invalid_parent_capture}
    end
  end

  @doc false
  def new(capture) do
    %{
      capture: capture,
      version: 0,
      bytes: byte_size(capture.header),
      credit: 0,
      phase: :empty,
      parent: nil,
      transactions: []
    }
  end

  @doc false
  def prepare_mutation(capture) do
    Map.take(
      capture.creation,
      ~w(command_id input_digest canonical_create_digest catalog_sha256 declaration_sha256 task_generation)
    )
    |> Map.merge(%{
      "kind" => "prepare_parent",
      "creation_sha256" => capture.creation_sha256,
      "closing_credit_bytes" => @credit
    })
  end

  @doc false
  def bind_mutation(capture, session) when is_binary(session) do
    Map.take(capture.creation, ~w(input_digest canonical_create_digest))
    |> Map.merge(%{
      "kind" => "bind_parent",
      "creation_sha256" => capture.creation_sha256,
      "parent_session_id" => Base.encode64(session)
    })
  end

  @doc false
  def transaction(key, expected, mutation)
      when is_binary(key) and is_integer(expected) and expected >= 0 and is_map(mutation) do
    with true <- digest?(key) and mutation["kind"] in ~w(prepare_parent bind_parent),
         {:ok, tx_id} <- domain("loopex:helper-tx:v1", [key, mutation["kind"], []]),
         {:ok, mutation_digest} <- domain("loopex:helper-mutation:v1", [key, expected, mutation]),
         tx = %{
           "version" => 1,
           "tx_id" => tx_id,
           "expected_version" => expected,
           "mutation_digest" => mutation_digest,
           "mutation" => mutation
         },
         {:ok, _} <- LedgerCodec.encode_json(tx, :frame) do
      {:ok, tx}
    else
      _ -> {:error, :invalid_binding_transaction}
    end
  end

  def transaction(_, _, _), do: {:error, :invalid_binding_transaction}

  @doc false
  def admit_bytes(state, bytes, history \\ :unobserved) do
    with {:ok, tx} <- LedgerCodec.decode_json(bytes, :frame), do: admit(state, tx, history)
  end

  @doc false
  def admit(state, tx, history \\ :unobserved) do
    with {:ok, canonical} <- valid_transaction(state.capture.key, tx),
         {:ok, frame} <- LedgerCodec.encode_frame(canonical) do
      case Enum.find(state.transactions, fn {old, _} -> old["tx_id"] == tx["tx_id"] end) do
        {^tx, result} -> {:ok, state, result}
        {_changed, _} -> {:error, :binding_conflict}
        nil -> advance(state, tx, byte_size(frame), history)
      end
    else
      _ -> {:error, :invalid_binding_transaction}
    end
  end

  @doc false
  def replay(capture, transactions, history \\ :unobserved)

  def replay(capture, transactions, history)
      when is_list(transactions) and length(transactions) <= 2 do
    Enum.reduce_while(transactions, {:ok, new(capture)}, fn tx, {:ok, state} ->
      if is_map(tx) and
           Enum.any?(state.transactions, fn {old, _} -> old["tx_id"] == tx["tx_id"] end) do
        {:halt, {:error, :duplicate_appended_transaction}}
      else
        case admit(state, tx, history) do
          {:ok, next, _} -> {:cont, {:ok, next}}
          error -> {:halt, error}
        end
      end
    end)
  end

  def replay(_, _, _), do: {:error, :invalid_binding_prefix}

  @doc false
  def observe_creation(runtime, capture) do
    case Runtime.lookup_create_result(runtime, capture.command, capture.options, capture.genesis) do
      {:ok, {:historical, session}} ->
        case Runtime.creation_provenance(runtime, %{kind: :command, command_id: capture.command}) do
          {:ok, {:historical, %{session_id: ^session} = row}} ->
            if history_matches?(capture, row),
              do: {:ok, {:historical, row}},
              else: {:error, :creation_history_conflict}

          {:ok, {:historical, _}} ->
            {:error, :creation_history_conflict}

          other ->
            other
        end

      other ->
        other
    end
  end

  defp advance(state, tx, size, history) do
    cond do
      tx["expected_version"] != state.version ->
        {:error, :stale_binding_version}

      state.phase == :empty and tx["mutation"] == prepare_mutation(state.capture) ->
        install(state, tx, size, @credit, :prepared, nil)

      state.phase == :prepared and match?({:historical, _}, history) ->
        {:historical, row} = history

        if history_matches?(state.capture, row) and
             tx["mutation"] == bind_mutation(state.capture, row.session_id) do
          install(state, tx, size, 0, :bound, row.session_id)
        else
          {:error, :creation_history_conflict}
        end

      state.phase == :prepared and tx["mutation"]["kind"] == "bind_parent" ->
        {:error, :creation_history_unavailable}

      true ->
        {:error, :invalid_binding_transition}
    end
  end

  defp install(state, tx, size, credit, phase, parent) do
    if state.bytes + size + credit <= @cap do
      version = state.version + 1

      result = %{
        "version" => 1,
        "tx_id" => tx["tx_id"],
        "ledger_version" => version,
        "mutation_digest" => tx["mutation_digest"]
      }

      next = %{
        state
        | version: version,
          bytes: state.bytes + size,
          credit: credit,
          phase: phase,
          parent: parent,
          transactions: state.transactions ++ [{tx, result}]
      }

      {:ok, next, result}
    else
      {:error, :binding_byte_limit}
    end
  end

  defp valid_transaction(key, tx) when is_map(tx) do
    with true <- closed?(tx, ~w(version tx_id expected_version mutation_digest mutation)),
         true <- tx["version"] === 1,
         {:ok, expected} <- transaction(key, tx["expected_version"], tx["mutation"]),
         true <- tx == expected,
         {:ok, bytes} <- LedgerCodec.encode_json(tx, :frame),
         do: {:ok, bytes}
  end

  defp valid_transaction(_, _), do: :error

  defp history_matches?(capture, row) do
    CreationProvenance.valid_row?(capture.runtime, row, false) and
      row.command_id == capture.command and
      row.canonical_create_digest == capture.creation["canonical_create_digest"]
  end

  defp catalog(value, runtime) do
    with true <- closed?(value, ~w(version kind runtime_id providers roles)),
         true <- value["version"] === 1 and value["kind"] == "catalog",
         true <- value["runtime_id"] == Base.encode64(runtime),
         {:ok, _} <- ProviderBindings.validate(value["providers"]),
         true <-
           Enum.all?(value["providers"], fn {_, binding} ->
             match?(%{"credential" => %{"env" => _}}, binding)
           end),
         entries when is_list(entries) <- value["roles"],
         true <- length(entries) in 1..16,
         {:ok, roles} <- decode_roles(entries, value["providers"]),
         names = Enum.map(entries, & &1["name"]),
         true <- names == Enum.sort(Map.keys(roles)) do
      {:ok, roles}
    else
      _ -> :error
    end
  end

  defp decode_roles(entries, providers) do
    Enum.reduce_while(entries, {:ok, %{}}, fn entry, {:ok, acc} ->
      with true <- closed?(entry, ~w(name genesis)) and role?(entry["name"]),
           false <- Map.has_key?(acc, entry["name"]),
           {:ok, genesis} <- GenesisCodec.decode(entry["genesis"]),
           true <- genesis["policy_defer_mode"] == "refuse",
           definitions = genesis["tool_selection"]["definitions"],
           true <-
             Enum.sort(Enum.map(definitions, & &1["tool_id"])) ==
               ~w(loopex.find loopex.grep loopex.ls loopex.read),
           true <- Enum.all?(definitions, &(&1["effect_class"] == "read_only")),
           {:ok, selected} <-
             HostBindings.select(genesis["initial_configuration"]["model"], providers),
           true <- is_binary(selected) do
        {:cont, {:ok, Map.put(acc, entry["name"], genesis)}}
      else
        _ -> {:halt, :error}
      end
    end)
  end

  defp declaration(value, roles) do
    with true <-
           closed?(
             value,
             ~w(version kind enabled roles max_children token_budget child_bounds max_tokens role_budgets)
           ),
         true <-
           value["version"] === 1 and value["kind"] == "declaration" and value["enabled"] === true,
         names when is_list(names) <- value["roles"],
         true <- length(names) in 1..16 and names == Enum.uniq(names),
         true <- Enum.all?(names, &Map.has_key?(roles, &1)),
         true <- positive?(value["max_children"]) and value["max_children"] <= 128,
         true <- positive?(value["token_budget"]) and positive?(value["max_tokens"]),
         bounds = value["child_bounds"],
         true <- closed?(bounds, ~w(max_turns deadline_ms token_budget)),
         true <- Enum.all?(Map.values(bounds), &positive?/1) and bounds["deadline_ms"] <= 600_000,
         budgets when is_list(budgets) <- value["role_budgets"],
         true <- length(budgets) == length(names),
         true <-
           Enum.zip(names, budgets)
           |> Enum.all?(fn {name, budget} ->
             configuration = roles[name]["initial_configuration"]

             closed?(budget, ~w(role context_token_budget system_class_tokens)) and
               budget["role"] == name and uint64_positive?(budget["context_token_budget"]) and
               uint64_positive?(budget["system_class_tokens"]) and
               budget["system_class_tokens"] <= budget["context_token_budget"] and
               budget["context_token_budget"] == configuration["context_token_budget"] and
               budget["system_class_tokens"] == configuration["system_class_tokens"] and
               value["max_tokens"] == configuration["max_tokens"]
           end) do
      :ok
    else
      _ -> :error
    end
  end

  defp creation(value, runtime, command, catalog_bytes, declaration_bytes) do
    with true <-
           closed?(
             value,
             ~w(version kind runtime_id command_id original_options genesis input_digest canonical_create_digest catalog_sha256 declaration_sha256 task_generation)
           ),
         true <- value["version"] === 1 and value["kind"] == "parent_creation",
         true <-
           value["runtime_id"] == Base.encode64(runtime) and
             value["command_id"] == Base.encode64(command),
         true <-
           value["catalog_sha256"] == hash(catalog_bytes) and
             value["declaration_sha256"] == hash(declaration_bytes),
         {:ok, genesis} <- GenesisCodec.decode(value["genesis"]),
         {:ok, options} <- options(value["original_options"]),
         true <- options == genesis["options"],
         generation = task_generation(),
         true <- value["task_generation"] == generation,
         true <- Enum.any?(genesis["tool_selection"]["definitions"], &(&1 == Tool.definition())),
         {:ok, input} <-
           domain(
             "loopex:helper-create-input:v1",
             Map.drop(value, ~w(input_digest canonical_create_digest))
           ),
         true <- value["input_digest"] == input,
         {:ok, transaction} <- Store.create_session(runtime, command, genesis),
         true <-
           value["canonical_create_digest"] ==
             Base.encode16(transaction.canonical_mutation_digest, case: :lower) do
      {:ok, genesis, options}
    else
      _ -> :error
    end
  end

  defp options(%{"encoding" => @encoding, "bytes" => encoded, "sha256" => hash} = envelope)
       when map_size(envelope) == 3 and is_binary(encoded) and byte_size(encoded) <= 87_384 do
    with {:ok, bytes} <- Base.decode64(encoded),
         true <- byte_size(bytes) <= 65_536 and Base.encode64(bytes) == encoded,
         true <- digest?(hash) and hash(bytes) == hash,
         <<131, tag, _::binary>> when tag != 80 <- bytes,
         {value, used} <- :erlang.binary_to_term(bytes, [:safe, :used]),
         true <- used == byte_size(bytes) and is_map(value) and not is_struct(value),
         {:ok, %{"options" => normalized}, _size} <-
           Store.normalize_and_measure_item(:record, %{
             "options" => value,
             kind: "original_options"
           }) do
      {:ok, normalized}
    else
      _ -> :error
    end
  rescue
    ArgumentError -> :error
  end

  defp options(_), do: :error

  defp task_generation do
    {id, version, digest} = ToolDefinition.generation(Tool.definition())
    %{"tool_id" => id, "tool_version" => version, "definition_digest" => digest}
  end

  defp domain(label, value) do
    # Concept: domain preimages can be arrays, while the JSON owner admits roots as objects.
    # Technical depth: encode a closed one-member wrapper and remove its fixed
    # ASCII prefix/suffix; the canonical value bytes retain all owner limits.
    with {:ok, wrapped} <- LedgerCodec.encode_json(%{"v" => value}, :object) do
      bytes = binary_part(wrapped, 5, byte_size(wrapped) - 6)
      {:ok, hash(label <> <<0>> <> bytes)}
    end
  end

  defp hash(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  defp digest?(value) when is_binary(value) and byte_size(value) == 64,
    do: Enum.all?(:binary.bin_to_list(value), &(&1 in ?0..?9 or &1 in ?a..?f))

  defp digest?(_), do: false
  defp identifier?(value), do: is_binary(value) and byte_size(value) in 1..256
  defp positive?(value), do: is_integer(value) and value > 0
  defp uint64_positive?(value), do: positive?(value) and value <= @uint64
  defp role?(name), do: is_binary(name) and Regex.match?(@role, name)

  defp closed?(value, keys),
    do: is_map(value) and not is_struct(value) and Enum.sort(Map.keys(value)) == Enum.sort(keys)
end
