Code.require_file("support/configured_genesis_helper.exs", __DIR__)

defmodule Loopex.Runtime.SessionGenesisTest do
  use ExUnit.Case, async: true

  alias Loopex.Runtime.SessionGenesis
  alias Loopex.Runtime.SessionState
  alias Loopex.Store

  @grace_max 18_446_744_073_709_551_615

  test "resolved and retained current genesis share exact normalized creation bytes" do
    options = %{tenant: "tenant-a", nested: %{selection: "coding"}}
    original = current(options, 5_000)

    assert {:ok, normalized} = SessionGenesis.normalize(original)

    assert {:ok, ^normalized} =
             SessionGenesis.resolve(options, input(5_000))

    assert normalized ==
             current(%{"tenant" => "tenant-a", "nested" => %{"selection" => "coding"}}, 5_000)

    assert {:ok, original_transaction} = Store.create_session("runtime", "create", original)
    assert {:ok, resolved} = Store.create_session("runtime", "create", normalized)
    assert original_transaction == resolved
    assert SessionGenesis.normalize(normalized) == {:ok, normalized}
  end

  test "the captured cleanup value replays without startup defaults" do
    for grace <- [1, 5_000, @grace_max] do
      assert {:ok, normalized} = SessionGenesis.normalize(current(%{}, grace))

      records = [
        %{
          journal_version: 1,
          owner_epoch: 0,
          owner_incarnation_id: nil,
          payload: normalized
        }
      ]

      assert {:ok, recovered} = SessionState.recover("session", records, [])
      assert recovered.cleanup_grace_ms == grace
    end
  end

  test "complete current key sets and cleanup domain refuse missing, extra and invented values" do
    valid = current(%{}, 5_000)

    invalid = [
      Map.delete(valid, "options"),
      Map.delete(valid, "runtime_configuration"),
      Map.put(valid, "extra", true),
      %{valid | kind: "session_genesis"},
      %{valid | kind: "session_genesis_v999"},
      Map.put(valid, "options", []),
      Map.put(valid, "runtime_configuration", %{}),
      Map.put(valid, "runtime_configuration", %{"cleanup_grace_ms" => 5_000, "extra" => true})
    ]

    invalid = invalid ++ Enum.map([nil, 0, -1, 1.0, "5000", @grace_max + 1], &current(%{}, &1))

    for payload <- invalid do
      assert SessionGenesis.normalize(payload) == {:error, :invalid_session_genesis}
    end
  end

  test "resolve's closed explicit inputs cannot silently supply or discard a setting" do
    valid = input(5_000)

    for input <- [
          %{},
          Map.delete(valid, :runtime_configuration),
          Map.delete(valid, :genesis_version),
          Map.delete(valid, :initial_configuration),
          Map.put(valid, :extra, true),
          Map.put(valid, :genesis_version, "session_genesis_v999"),
          Map.put(valid, :runtime_configuration, %{})
        ] do
      assert SessionGenesis.resolve(%{}, input) == {:error, :invalid_session_genesis}
    end
  end

  test "plain-data and key-collision checks apply inside options before retained admission" do
    invalid_options = [
      %{process: self()},
      %{reference: make_ref()},
      %{callback: fn -> :ok end},
      %{tuple: {:implementation, "value"}},
      %{value: MapSet.new()},
      Map.put(%{same: "one"}, "same", "two")
    ]

    for options <- invalid_options do
      assert SessionGenesis.normalize(current(options, 5_000)) ==
               {:error, :invalid_session_genesis}
    end
  end

  test "genesis admits 65536 normalized bytes and refuses one more" do
    for wanted <- [65_535, 65_536, 65_537] do
      payload = padded_genesis(wanted, "padding")
      assert {:ok, _normalized, ^wanted} = Store.normalize_and_measure_item(:record, payload)

      if wanted <= 65_536 do
        assert {:ok, ^payload} = SessionGenesis.normalize(payload)
      else
        assert SessionGenesis.normalize(payload) == {:error, :session_configuration_too_large}
      end
    end
  end

  test "the byte limit counts normalized keys rather than a caller's smaller atom encoding" do
    normalized = padded_genesis(65_537, "padding")
    options = %{padding: normalized["options"]["padding"]}
    caller = current(options, 5_000)
    assert byte_size(:erlang.term_to_binary(caller, [:deterministic])) < 65_537
    assert SessionGenesis.normalize(caller) == {:error, :session_configuration_too_large}
  end

  test "superseded genesis refuses normalization resolution and recovery" do
    previous = %{
      :kind => "session_genesis_v2",
      "options" => %{},
      "runtime_configuration" => %{"cleanup_grace_ms" => 5_000}
    }

    assert {:error, :invalid_session_genesis} = SessionGenesis.normalize(previous)

    assert {:error, :invalid_session_genesis} =
             SessionGenesis.resolve(%{}, %{
               genesis_version: "session_genesis_v2",
               runtime_configuration: %{"cleanup_grace_ms" => 5_000}
             })

    assert {:error, :invalid_private_history} =
             SessionState.recover(
               "session",
               [
                 %{
                   journal_version: 1,
                   owner_epoch: 0,
                   owner_incarnation_id: nil,
                   payload: previous
                 }
               ],
               []
             )
  end

  defp current(options, grace) do
    Loopex.ConfiguredGenesisFixture.genesis([])
    |> Map.put("options", options)
    |> put_in(["runtime_configuration", "cleanup_grace_ms"], grace)
  end

  defp input(grace) do
    genesis = current(%{}, grace)

    %{
      genesis_version: "session_genesis_v3",
      runtime_configuration: genesis["runtime_configuration"],
      initial_configuration: genesis["initial_configuration"],
      tool_selection: Map.drop(genesis["tool_selection"], ["artifact_read"]),
      policy_defer_mode: genesis["policy_defer_mode"]
    }
  end

  defp padded_genesis(wanted, key) do
    empty = current(%{key => ""}, 5_000)
    {:ok, _normalized, overhead} = Store.normalize_and_measure_item(:record, empty)
    current(%{key => String.duplicate("g", wanted - overhead)}, 5_000)
  end
end
