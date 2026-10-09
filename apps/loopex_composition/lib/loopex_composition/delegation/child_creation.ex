defmodule LoopexComposition.Delegation.ChildCreation do
  @moduledoc """
  ## Concept

  Validate the original retained child creation against its captured parent
  selections without creating a child or granting permission to run one.

  ## Technical depth

  This internal ADR 0056 object validator reuses ParentBinding for catalog and
  declaration admission, GenesisCodec for current genesis and Store for plain
  options and the original create digest. It retains exact canonical object
  bytes. Its returned facts prove neither synced objects nor original source
  intent, current job, reservation availability, cross-run slot or authority.
  Prompt bounds and admission still require the pending owning Core producer.
  """

  alias Loopex.Store
  alias LoopexComposition.Delegation.{GenesisCodec, LedgerCodec, ParentBinding}

  @encoding "loopex.ledger.plain_etf.v1.base64"
  @keys ~w(version kind runtime_id operation_identity role catalog_sha256 declaration_sha256 command_id original_options genesis input_digest canonical_create_digest)
  @operation_keys ~w(parent_session_id parent_run_id operation_id)

  @doc """
  ## Concept

  Read one closed child object under the original retained parent selections.

  ## Technical depth

  Revalidate the parent's original three object bytes rather than trusting its
  mutable projections. IDs retain their padded base64 representation; derived
  commands bind the original operation, excluding executor attempt. Reserved
  tokens must fit retained child and aggregate ceilings, but this read proves
  no aggregate availability. Full role genesis, including configured reply
  limit, model, context, instructions, cleanup and tools, stays exact except
  for its separately validated original options. Turn and deadline limits come
  from the returned declaration and do not prove an admitted prompt.
  """
  @spec validate(term(), term(), term()) ::
          {:ok, map()} | {:error, :invalid_child_creation}
  def validate(bytes, parent_capture, reserved_tokens) do
    with {:ok, parent} <- parent(parent_capture),
         {:ok, creation} <- LedgerCodec.decode_json(bytes, :object),
         true <- closed?(creation, @keys),
         true <- creation["version"] === 1 and creation["kind"] == "child_creation",
         true <- creation["runtime_id"] == Base.encode64(parent.runtime),
         true <- creation["catalog_sha256"] == parent.creation["catalog_sha256"],
         true <- creation["declaration_sha256"] == parent.creation["declaration_sha256"],
         :ok <- operation(creation["operation_identity"]),
         {:ok, command} <- command("loopex:helper-create:v1", parent.runtime, creation),
         {:ok, prompt} <- command("loopex:helper-prompt:v1", parent.runtime, creation),
         true <- creation["command_id"] == Base.encode64(command),
         true <- creation["role"] in parent.declaration["roles"],
         role when is_map(role) <-
           Enum.find(parent.catalog["roles"], &(&1["name"] == creation["role"])),
         {:ok, selected} <- GenesisCodec.decode(role["genesis"]),
         {:ok, genesis} <- GenesisCodec.decode(creation["genesis"]),
         {:ok, options} <- options(creation["original_options"]),
         true <- options == genesis["options"],
         true <- Map.put(selected, "options", options) == genesis,
         true <-
           genesis["initial_configuration"]["max_tokens"] == parent.declaration["max_tokens"],
         true <- reservation?(reserved_tokens, parent.declaration),
         {:ok, input_digest} <-
           domain("loopex:helper-create-input:v1",
             Map.drop(creation, ~w(input_digest canonical_create_digest))),
         true <- creation["input_digest"] == input_digest,
         {:ok, transaction} <- Store.create_session(parent.runtime, command, genesis),
         true <- creation["canonical_create_digest"] ==
           Base.encode16(transaction.canonical_mutation_digest, case: :lower) do
      {:ok,
       %{
         creation: creation,
         object_bytes: bytes,
         creation_sha256: hash(bytes),
         runtime_id: parent.runtime,
         operation_identity: creation["operation_identity"],
         role: creation["role"],
         command_id: command,
         prompt_command_id: prompt,
         reserved_tokens: reserved_tokens,
         genesis: genesis,
         options: options,
         declaration: parent.declaration
       }}
    else
      _invalid -> {:error, :invalid_child_creation}
    end
  end

  defp parent(%{runtime: runtime, command: command, object_bytes: [catalog, declaration, creation]}),
    do: ParentBinding.capture(runtime, command, catalog, declaration, creation)

  defp parent(_capture), do: :error

  # Concept: opaque operation IDs keep their existing executor identity ceiling.
  # Technical depth: parent session/run IDs share the 256-byte ledger header
  # ceiling; operation_id is an executor identity with its owning 8192-byte cap.
  defp operation(value) do
    if closed?(value, @operation_keys) and
         identifier?(value["parent_session_id"], 256) and
         identifier?(value["parent_run_id"], 256) and
         identifier?(value["operation_id"], 8_192),
      do: :ok,
      else: :error
  end

  defp identifier?(encoded, limit)
       when is_binary(encoded) and byte_size(encoded) <= 4 * div(limit + 2, 3) do
    with {:ok, bytes} <- Base.decode64(encoded),
         true <- byte_size(bytes) in 1..limit and Base.encode64(bytes) == encoded do
      true
    else
      _invalid -> false
    end
  end

  defp identifier?(_encoded, _limit), do: false

  defp command(label, runtime, creation),
    do: domain(label, [Base.encode64(runtime), creation["operation_identity"]])

  defp reservation?(tokens, declaration),
    do: is_integer(tokens) and tokens > 0 and
      tokens <= declaration["child_bounds"]["token_budget"] and
      tokens <= declaration["token_budget"]

  # Concept: options use Core's plain-data owner, not the genesis schema.
  # Technical depth: reject compressed, unsafe and trailing ETF before calling
  # Store's original-options wrapper. Integrity covers retained bytes; decoding
  # never demands another OTP release reproduce their external encoding.
  defp options(%{"encoding" => @encoding, "bytes" => encoded, "sha256" => digest} = envelope)
       when map_size(envelope) == 3 and is_binary(encoded) and byte_size(encoded) <= 87_384 and
              is_binary(digest) and byte_size(digest) == 64 do
    with {:ok, bytes} <- Base.decode64(encoded),
         true <- byte_size(bytes) <= 65_536 and Base.encode64(bytes) == encoded,
         true <- hash(bytes) == digest,
         <<131, tag, _::binary>> when tag != 80 <- bytes,
         {value, used} <- :erlang.binary_to_term(bytes, [:safe, :used]),
         true <- used == byte_size(bytes) and is_map(value) and not is_struct(value),
         {:ok, %{"options" => normalized}, _size} <-
           Store.normalize_and_measure_item(:record, %{"options" => value, kind: "original_options"}) do
      {:ok, normalized}
    else
      _invalid -> :error
    end
  rescue
    ArgumentError -> :error
  end

  defp options(_envelope), do: :error

  # Concept: digest identities use the accepted canonical private JSON recipe.
  # Technical depth: LedgerCodec admits root objects; remove the fixed wrapper
  # around a domain preimage so arrays share its complete bounds and encoding.
  defp domain(label, value) do
    with {:ok, wrapped} <- LedgerCodec.encode_json(%{"v" => value}, :object) do
      bytes = binary_part(wrapped, 5, byte_size(wrapped) - 6)
      {:ok, hash(label <> <<0>> <> bytes)}
    end
  end

  defp hash(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  defp closed?(value, keys),
    do: is_map(value) and not is_struct(value) and Enum.sort(Map.keys(value)) == Enum.sort(keys)
end
