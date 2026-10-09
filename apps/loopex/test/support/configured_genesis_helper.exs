defmodule Loopex.ConfiguredGenesisFixture do
  @moduledoc false

  alias Loopex.Runtime.Instructions
  alias Loopex.Runtime.SessionGenesis
  alias LoopexProtocol.ToolDefinition

  def configuration(base \\ "Follow the host's captured instructions.") do
    {:ok, instructions} =
      Instructions.capture(%{
        "version" => "host.v1",
        "base" => base,
        "environment" => "captured environment",
        "appendix" => ""
      })

    %{
      "model" => "scripted:v1",
      "reasoning" => "default",
      "configuration_version" => 1,
      "instructions" => instructions,
      "max_tokens" => 1_024,
      "context_token_budget" => 8_192,
      "system_class_tokens" => 5_000,
      "budget_origins" => %{
        "context_token_budget" => "unknown_window",
        "system_class_tokens" => "explicit"
      },
      "model_capabilities" => %{
        "model" => "scripted:v1",
        "context_window" => nil,
        "output_limit" => nil,
        "reasoning_levels" => [],
        "source_revision" => "fixture.v1",
        "source_digest" => String.duplicate("0", 64)
      },
      "provider_mapping" => %{
        "mapping_revision" => "loopex.unregistered.default.v1",
        "renderer_revision" => "loopex.reqllm.canonical.v1",
        "continuation_required" => false,
        "canonical_terminal_tool_history" => false,
        "thinking_disabled" => false,
        "thinking" => %{"mode" => "omitted"}
      }
    }
  end

  def genesis(definitions, configuration \\ configuration()) do
    names =
      Map.new(definitions, fn definition ->
        {id, version, digest} = ToolDefinition.generation(definition)

        {definition["name"],
         %{"tool_id" => id, "tool_version" => version, "definition_digest" => digest}}
      end)

    {:ok, genesis} =
      SessionGenesis.resolve(%{}, %{
        genesis_version: "session_genesis_v3",
        runtime_configuration: %{"cleanup_grace_ms" => 5_000},
        initial_configuration: configuration,
        tool_selection: %{"definitions" => definitions, "names" => names},
        policy_defer_mode: "admit"
      })

    genesis
  end

  # Concept: placement fixtures observe the original creation startup, including
  # intentional unavailable starts whose retired slot permits read-only queries.
  # Technical depth: one existing 1,000 ms fixture cutoff bounds native reads and
  # exact original-Control retirement observations. No creation is retried.
  def await_creation_ready(runtime), do: await_creation_state(runtime, :ready)
  def await_creation_unavailable(runtime), do: await_creation_state(runtime, :unavailable)

  defp await_creation_state(runtime, desired) do
    cutoff = System.monotonic_time(:millisecond) + 1_000
    remaining = creation_remaining!(cutoff)
    children = GenServer.call(runtime.supervisor, :which_children, remaining)
    _remaining = creation_remaining!(cutoff)

    {Loopex.Runtime.Control, control, _type, _modules} =
      List.keyfind(children, Loopex.Runtime.Control, 0)

    true = is_pid(control)
    await_creation_state(runtime, control, desired, cutoff, nil)
  catch
    :exit, _reason -> raise "fixture creation startup capability unavailable"
  end

  defp await_creation_state(runtime, control, desired, cutoff, original) do
    remaining = creation_remaining!(cutoff)

    {:ok, %{state: status, startup_id: id, startup_deadline_ms: deadline}} =
      Loopex.Runtime.creation_startup_status(runtime, remaining)

    remaining = creation_remaining!(cutoff)
    capture = {id, deadline}

    if original != nil and original != capture,
      do: raise("fixture creation startup identity changed during observation")

    state = :sys.get_state(control, remaining)
    _remaining = creation_remaining!(cutoff)

    %{
      creation_startup: %{startup_id: ^id, startup_deadline_ms: ^deadline},
      creation_status: actual_status,
      creation: creation
    } = state

    cond do
      status == desired and actual_status == desired and is_nil(creation) ->
        _remaining = creation_remaining!(cutoff)
        :ok

      status == :starting or (desired == :unavailable and status == :unavailable) ->
        remaining = creation_remaining!(cutoff)

        receive do
          :no_fixture_message -> :ok
        after
          min(remaining, 10) -> :ok
        end

        await_creation_state(runtime, control, desired, cutoff, capture)

      true ->
        raise "fixture creation startup unavailable: #{inspect(status)}"
    end
  catch
    :exit, _reason -> raise "fixture creation startup capability unavailable"
  end

  defp creation_remaining!(cutoff) do
    remaining = cutoff - System.monotonic_time(:millisecond)

    if remaining <= 0,
      do: raise("fixture creation startup did not settle within its observation bound")

    remaining
  end

  # Concept: direct Store seeds use the same current creation custody as Runtime.
  # Technical depth: claim and reserve the actual original final bytes, observe
  # their exact head/capsule joins, then present that unchanged final once.
  def commit_creation(store, %{type: :create_session} = final) do
    :ok = Loopex.Store.validate_transaction(final)
    runtime = final.runtime_id
    command = final.command_id
    {:ok, final_id} = Loopex.Store.transaction_id(final)

    {:ok, %{head: head, command: nil}} =
      Loopex.Store.creation_recovery(store, %{runtime_id: runtime, command_id: nil})

    true = is_nil(head.active_command_id)
    selection = Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)
    {:ok, claim} = Loopex.Store.claim_creation_domain(runtime, head.owner_generation, selection)
    {:ok, claim_id} = Loopex.Store.transaction_id(claim)
    {:committed, ^claim_id, claimed} = Loopex.Store.transact(store, claim)

    {:ok, %{head: current, command: nil}} =
      Loopex.Store.creation_recovery(store, %{runtime_id: runtime, command_id: nil})

    true =
      {current.owner_generation, current.owner_selection, current.domain_version,
       current.active_command_id} ==
        {claimed.owner_generation, claimed.owner_selection, claimed.domain_version, nil}

    {:ok, reserve} =
      Loopex.Store.reserve_creation(
        runtime,
        command,
        current.owner_generation,
        current.owner_selection,
        current.domain_version,
        final.genesis
      )

    :ok = Loopex.Store.validate_transaction(reserve)
    true = reserve.genesis == final.genesis
    {:ok, reserve_id} = Loopex.Store.transaction_id(reserve)
    {:committed, ^reserve_id, reserved} = Loopex.Store.transact(store, reserve)

    {:ok, %{command: capsule}} =
      Loopex.Store.creation_recovery(store, %{runtime_id: runtime, command_id: command})

    true = capsule.state == :reserved and capsule.genesis == final.genesis
    true = capsule.reservation_tx_id == reserve_id
    true = capsule.reservation_owner_generation == current.owner_generation
    true = capsule.reservation_owner_selection == current.owner_selection
    true = capsule.reservation_domain_version == reserved.reservation_domain_version
    true = capsule.final_resolution == nil and capsule.session_id == nil

    {:committed, ^final_id, receipt} = result = Loopex.Store.transact(store, final)

    {:ok, %{head: terminal, command: created}} =
      Loopex.Store.creation_recovery(store, %{runtime_id: runtime, command_id: command})

    true = terminal.active_command_id == nil
    true = created.state == :created and created.final_resolution == :committed
    true = created.genesis == final.genesis and created.session_id == receipt.session_id
    true = created.reservation_tx_id == reserve_id
    result
  end

  # Concept: StoreItemBudgetTest's generated admission property and
  # AuditRepairsTest's item parity property share the same real record proof.
  # Technical depth: create complete current genesis, claim the observed owner,
  # then commit and load the unchanged root record with exact stamps and bytes.
  def commit_normalized_record(store, final, expected_bytes) do
    :ok = Loopex.Store.validate_transaction(final)
    command_id = final.command_id

    {:ok, seed} =
      Loopex.Store.create_session(
        final.runtime_id,
        command_id,
        Loopex.ConfiguredGenesisFixture.genesis([])
      )

    {:committed, ^command_id, created} =
      Loopex.ConfiguredGenesisFixture.commit_creation(store, seed)

    session_id = created.session_id
    {:ok, head} = Loopex.Store.ownership_head(store, session_id, session_id)
    true = head.journal_version == created.journal_version
    owner_id = "owner-#{command_id}"

    {:ok, advance} =
      Loopex.Store.advance_owner(
        session_id,
        session_id,
        owner_id,
        head.owner_epoch,
        head.journal_version,
        owner_id
      )

    {:committed, ^owner_id, owner} = Loopex.Store.transact(store, advance)
    true = owner.owner_epoch == head.owner_epoch + 1
    true = owner.journal_version == head.journal_version + 1
    true = owner.owner_incarnation_id == owner_id

    {:ok, transaction} =
      Loopex.Store.session_commit(
        session_id,
        session_id,
        command_id,
        owner.owner_epoch,
        owner.owner_incarnation_id,
        owner.journal_version,
        [final.genesis],
        []
      )

    true = transaction.records == [final.genesis]
    :ok = Loopex.Store.validate_transaction(transaction)
    {:committed, ^command_id, receipt} = result = Loopex.Store.transact(store, transaction)
    {:ok, [stored]} = Loopex.Store.load_records(store, session_id, owner.journal_version, 1)
    true = stored.journal_version == owner.journal_version + 1

    true =
      receipt.journal_versions == %{first: stored.journal_version, last: stored.journal_version}

    true = stored.owner_epoch == owner.owner_epoch
    true = stored.owner_incarnation_id == owner.owner_incarnation_id
    true = stored.payload == final.genesis
    true = byte_size(:erlang.term_to_binary(stored.payload, [:deterministic])) == expected_bytes
    result
  end
end
