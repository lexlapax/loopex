Code.require_file("support/configured_genesis_helper.exs", __DIR__)

defmodule Loopex.CreationTransactionsTest do
  use ExUnit.Case, async: true

  alias Loopex.ConfiguredGenesisFixture, as: Fixture
  alias Loopex.Store
  alias Loopex.Store.Transitions

  @selection String.duplicate("a", 64)
  @uint64 18_446_744_073_709_551_615

  defmodule Adapter do
    @moduledoc false
    @behaviour Store
    @impl Store
    def transact({:reply, result}, t) do
      send(self(), {:creation_transaction_called, t})
      result
    end

    def transact(:exit, _t), do: exit(:lost_reply)
    def transact(:raise, _t), do: raise("lost reply")
    def transact(:throw, _t), do: throw(:lost_reply)
    @impl Store
    def creation_recovery({:reply, result}, request) do
      send(self(), {:creation_recovery_called, request})
      result
    end

    def creation_recovery(:exit, _), do: exit(:lost_reply)
    def creation_recovery(:raise, _), do: raise("lost reply")
    def creation_recovery(:throw, _), do: throw(:lost_reply)
    @impl Store
    def transaction_status(_, _, _, _), do: :unavailable
    @impl Store
    def runtime_command({:reply, result}, _), do: result
    @impl Store
    def ownership_head(_, _, _), do: :unavailable
    @impl Store
    def load_records(_, _, _, _), do: :unavailable
    @impl Store
    def load_events(_, _, _, _), do: :unavailable
  end

  defmodule MissingAdapter do
    @moduledoc false
    @behaviour Store
    @impl Store
    def transact(_, _), do: {:not_committed, :invalid_transaction}
    @impl Store
    def transaction_status(_, _, _, _), do: :unavailable
    @impl Store
    def runtime_command(_, _), do: :unavailable
    @impl Store
    def ownership_head(_, _, _), do: :unavailable
    @impl Store
    def load_records(_, _, _, _), do: :unavailable
    @impl Store
    def load_events(_, _, _, _), do: :unavailable
  end

  test "three literal ordered canonical families and distinct ID recipes retain original final bytes" do
    g = genesis()
    {:ok, final} = Store.create_session("runtime", "command", g)

    expected_final =
      encode(type: :create_session, runtime_id: "runtime", command_id: "command", genesis: g)

    assert final.canonical_record_bytes == expected_final
    assert Store.transaction_id(final) == {:ok, "command"}
    {:ok, claim} = Store.claim_creation_domain("runtime", 0, @selection)
    assert claim.tx_id == "ad04e6f1f0e0b8dea25401b4456a1514ff838af03f780b2b9415338f1db5f90e"
    assert claim.tx_id == id(["loopex_creation_claim_v1", "runtime", 0, @selection])

    assert claim.canonical_record_bytes ==
             encode(
               type: :claim_creation_domain,
               runtime_id: "runtime",
               expected_owner_generation: 0,
               owner_selection: @selection,
               tx_id: claim.tx_id
             )

    {:ok, reserve} = Store.reserve_creation("runtime", "command", 1, @selection, 0, g)
    assert reserve.tx_id == "ad95b29d59d0e145979d67f9bc570b6aad1f049dfa2909a4ea2e4de10b0439ff"
    assert reserve.tx_id == id(["loopex_creation_reserve_v1", "runtime", "command", 1])

    assert reserve.canonical_record_bytes ==
             encode(
               type: :reserve_creation,
               runtime_id: "runtime",
               command_id: "command",
               owner_generation: 1,
               owner_selection: @selection,
               expected_domain_version: 0,
               genesis: g,
               tx_id: reserve.tx_id
             )

    {:ok, close} =
      Store.close_creation_reservation(
        "runtime",
        "command",
        2,
        @selection,
        1,
        reserve.tx_id,
        1,
        final
      )

    assert close.tx_id == "c979e5784eb42f500d91d24ff78a1e7988ed27ab72ef7fca737d9c31233fe0a5"

    assert close.tx_id ==
             id([
               "loopex_creation_close_v1",
               "runtime",
               "command",
               reserve.tx_id,
               2,
               1,
               @selection
             ])

    assert close.canonical_record_bytes ==
             encode(
               type: :close_creation_reservation,
               runtime_id: "runtime",
               command_id: "command",
               owner_generation: 2,
               owner_selection: @selection,
               expected_domain_version: 1,
               reservation_tx_id: reserve.tx_id,
               reservation_domain_version: 1,
               final_canonical_record_bytes: expected_final,
               final_canonical_mutation_digest: hash(expected_final),
               tx_id: close.tx_id
             )

    for t <- [claim, reserve, close] do
      assert :ok = Store.validate_transaction(t)
      assert {:ok, ^t} = Store.immutable_binding(t)
      assert {:ok, tx} = Store.transaction_id(t)
      assert tx == t.tx_id and byte_size(tx) == 64
      assert t.canonical_mutation_digest == hash(t.canonical_record_bytes)
    end
  end

  test "new catalogue entries retain all existing transitions and exactly three fault phases" do
    originals = [
      :runtime_control_create_session,
      :runtime_control_stage_owner_attempt,
      :session_journal_advance_owner,
      :session_journal_commit
    ]

    added = [
      :runtime_control_claim_creation_domain,
      :runtime_control_reserve_creation,
      :runtime_control_close_creation_reservation
    ]

    assert Enum.sort(Map.keys(Transitions.catalogue())) == Enum.sort(originals ++ added)
    assert length(Transitions.declared_pairs()) == 21

    for t <- transactions() do
      assert {:ok, transition} = Transitions.id(t)
      assert transition in added

      assert Transitions.catalogue()[transition] == [
               :before_linearization,
               :after_linearization_before_result,
               :recovery_representation
             ]
    end
  end

  test "changed reserve genesis keeps scoped ID and changes full binding" do
    {:ok, a} = Store.reserve_creation("runtime", "command", 1, @selection, 0, genesis())

    {:ok, b} =
      Store.reserve_creation(
        "runtime",
        "command",
        1,
        @selection,
        0,
        genesis("different original sections")
      )

    assert a.tx_id == b.tx_id
    refute a.canonical_record_bytes == b.canonical_record_bytes
    refute a.canonical_mutation_digest == b.canonical_mutation_digest
    {:ok, c} = Store.reserve_creation("runtime", "command", 2, @selection, 0, genesis())
    refute a.tx_id == c.tx_id
  end

  test "canonical byte and digest tampering is refused for every new family" do
    for t <- transactions() do
      assert {:error, _} =
               Store.validate_transaction(%{
                 t
                 | canonical_record_bytes: t.canonical_record_bytes <> <<0>>
               })

      assert {:error, _} =
               Store.validate_transaction(%{t | canonical_mutation_digest: <<0::256>>})

      assert {:error, _} = Store.validate_transaction(%{t | tx_id: String.duplicate("f", 64)})
      assert {:error, _} = Store.validate_transaction(Map.put(t, :extra, nil))
      assert {:error, _} = Store.validate_transaction(Map.put(t, :__struct__, URI))

      for key <- Map.keys(t),
          do: assert({:error, _} = Store.validate_transaction(Map.delete(t, key)))
    end
  end

  test "scalar validation rejects resources wrong IDs selections and out-of-range quantities" do
    for bad <- [-1, @uint64 + 1, 1.0, "1", nil, self()] do
      assert {:error, _} = Store.claim_creation_domain("runtime", bad, @selection)

      assert {:error, _} =
               Store.reserve_creation("runtime", "command", bad, @selection, 0, genesis())

      assert {:error, _} =
               Store.reserve_creation("runtime", "command", 1, @selection, bad, genesis())
    end

    for bad <- [
          "",
          String.duplicate("A", 64),
          String.duplicate("a", 63),
          String.duplicate("a", 65),
          self()
        ] do
      assert {:error, _} = Store.claim_creation_domain("runtime", 0, bad)
    end

    for bad <- ["", String.duplicate("r", 257), nil, self(), %{}] do
      assert {:error, _} = Store.claim_creation_domain(bad, 0, @selection)
      assert {:error, _} = Store.reserve_creation("runtime", bad, 1, @selection, 0, genesis())
    end

    assert {:ok, _} = Store.claim_creation_domain(String.duplicate("r", 256), @uint64, @selection)

    assert {:ok, _} =
             Store.reserve_creation("runtime", "command", @uint64, @selection, @uint64, genesis())
  end

  test "reserve normalizes v3 atom key spellings without changing final constructor" do
    g = genesis()
    input = Map.delete(g, "options") |> Map.put(:options, %{})
    {:ok, reserve} = Store.reserve_creation("runtime", "command", 1, @selection, 0, input)
    assert reserve.genesis == g
    assert :ok = Store.validate_transaction(reserve)
    assert {:error, _} = Store.validate_transaction(%{reserve | genesis: input})

    assert {:error, _} =
             Store.reserve_creation("runtime", "command", 1, @selection, 0, %{
               g
               | kind: "session_genesis_v2"
             })
  end

  test "authored capture is checked while native current-v3 options retain their grammar" do
    g = genesis()
    assert {:ok, _} = Store.reserve_creation("runtime", "command", 1, @selection, 0, g)
    authored = Map.put(g, "options", %{"version" => 1})
    assert {:ok, _} = Store.reserve_creation("runtime", "command", 1, @selection, 0, authored)

    assert {:error, _} =
             Store.reserve_creation(
               "runtime",
               "command",
               1,
               @selection,
               0,
               Map.put(g, "options", %{"version" => 2})
             )

    bad =
      Map.put(g, "options", %{
        "version" => 1,
        "configuration" => %{
          "instructions" => %{"version" => "host.v1", "digest" => String.duplicate("f", 64)}
        }
      })

    assert {:error, _} = Store.reserve_creation("runtime", "command", 1, @selection, 0, bad)
  end

  test "close authenticates exact original final identity full bytes digest and bounded reservation version" do
    [_, reserve, close] = transactions()
    {:ok, final} = Store.create_session("runtime", "command", genesis())
    assert close.final_canonical_record_bytes == final.canonical_record_bytes
    assert close.final_canonical_mutation_digest == final.canonical_mutation_digest

    for bad <- [
          %{close | final_canonical_record_bytes: final.canonical_record_bytes <> <<0>>},
          %{close | final_canonical_mutation_digest: <<0::256>>},
          %{
            close
            | final_canonical_record_bytes:
                :erlang.term_to_binary([
                  "loopex_store_transaction_v1",
                  :create_session,
                  "runtime",
                  "command",
                  genesis()
                ])
          },
          %{close | reservation_domain_version: 0},
          %{close | reservation_tx_id: ""}
        ] do
      assert {:error, _} = Store.validate_transaction(recanonical(bad))
    end

    {:ok, other} = Store.create_session("other", "command", genesis())

    assert {:error, _} =
             Store.close_creation_reservation(
               "runtime",
               "command",
               2,
               @selection,
               1,
               reserve.tx_id,
               1,
               other
             )

    assert {:error, _} =
             Store.close_creation_reservation(
               "runtime",
               "command",
               2,
               @selection,
               1,
               reserve.tx_id,
               0,
               final
             )
  end

  test "compressed or oversized embedded canonical bytes cannot become an alternate final encoding" do
    [_, _, close] = transactions()
    decoded = :erlang.binary_to_term(close.final_canonical_record_bytes)
    compressed = :erlang.term_to_binary(decoded, [:compressed])

    for bytes <- [compressed, String.duplicate("b", 1_048_577), <<131, 108>>] do
      assert {:error, _} =
               Store.validate_transaction(
                 recanonical(%{
                   close
                   | final_canonical_record_bytes: bytes,
                     final_canonical_mutation_digest: hash(bytes)
                 })
               )
    end
  end

  test "valid new receipts retain exact resulting head and terminal correlations" do
    for t <- transactions() do
      result = {:committed, t.tx_id, receipt(t)}
      assert Store.transact(store({:reply, result}), t) == result
      assert_receive {:creation_transaction_called, ^t}
    end

    [_, _, close] = transactions()

    historical = %{
      receipt(close)
      | owner_generation: 7,
        owner_selection: String.duplicate("b", 64),
        domain_version: 5,
        active_command_id: "another",
        final_resolution: :committed,
        session_id: "historical-session"
    }

    assert Store.transact(store({:reply, {:committed, close.tx_id, historical}}), close) ==
             {:committed, close.tx_id, historical}
  end

  test "malformed receipts and wrong tx identities retain original unknown" do
    for t <- transactions() do
      r = receipt(t)

      for bad <-
            Enum.map(Map.keys(r), &Map.delete(r, &1)) ++
              [
                Map.put(r, :extra, nil),
                Map.put(r, :__struct__, URI),
                %{r | runtime_id: "other"},
                %{r | owner_generation: @uint64 + 1},
                %{r | owner_selection: "invalid"},
                %{r | active_command_id: self()}
              ] do
        assert Store.transact(store({:reply, {:committed, t.tx_id, bad}}), t) ==
                 {:commit_unknown, t.tx_id}
      end

      assert Store.transact(store({:reply, {:committed, "wrong", r}}), t) ==
               {:commit_unknown, t.tx_id}

      assert Store.transact(store({:reply, {:commit_unknown, "wrong"}}), t) ==
               {:commit_unknown, t.tx_id}
    end

    [claim, reserve, close] = transactions()

    for {t, bad} <- [
          {claim, %{receipt(claim) | owner_generation: 2}},
          {reserve, %{receipt(reserve) | reservation_domain_version: 2}},
          {reserve, %{receipt(reserve) | active_command_id: nil}},
          {close, %{receipt(close) | session_id: "session"}},
          {close, %{receipt(close) | final_resolution: :committed}},
          {close, %{receipt(close) | domain_version: close.reservation_domain_version}}
        ] do
      assert Store.transact(store({:reply, {:committed, t.tx_id, bad}}), t) ==
               {:commit_unknown, t.tx_id}
    end
  end

  test "only the closed new-family private terminal refusal set is admitted" do
    [claim | _] = transactions()

    for reason <- [
          :invalid_transaction,
          :tx_id_conflict,
          :stale_creation_generation,
          :creation_domain_conflict,
          :creation_in_progress,
          :runtime_command_conflict,
          :creation_counter_exhausted,
          :creation_recovery_too_large,
          :creation_reservation_conflict
        ] do
      assert Store.transact(store({:reply, {:not_committed, reason}}), claim) ==
               {:not_committed, reason}
    end

    for result <- [
          {:not_committed, :adapter_text},
          {:not_committed, "text"},
          {:not_committed, :creation_cancelled},
          :ok,
          nil
        ] do
      assert Store.transact(store({:reply, result}), claim) == {:commit_unknown, claim.tx_id}
    end
  end

  test "adapter exit raise and throw normalize to original-ID unknown with a positive control" do
    [claim | _] = transactions()

    for mode <- [:exit, :raise, :throw] do
      assert Store.transact(store(mode), claim) == {:commit_unknown, claim.tx_id}
    end

    assert Store.transact(store({:reply, {:commit_unknown, claim.tx_id}}), claim) ==
             {:commit_unknown, claim.tx_id}

    assert Store.transact(store({:reply, {:committed, claim.tx_id, receipt(claim)}}), claim) ==
             {:committed, claim.tx_id, receipt(claim)}
  end

  test "malformed new proposals never invoke the mutation adapter" do
    [claim | _] = transactions()

    for bad <- [
          Map.put(claim, :extra, nil),
          %{claim | canonical_mutation_digest: <<0::256>>},
          %{claim | expected_owner_generation: self()}
        ] do
      assert Store.transact(store({:reply, {:not_committed, :creation_domain_conflict}}), bad) ==
               {:not_committed, :invalid_transaction}

      refute_received {:creation_transaction_called, _}
    end
  end

  test "closed recovery requests reject unknown missing and nonplain identities before callback" do
    for bad <- [
          nil,
          %{},
          %{runtime_id: "runtime"},
          %{runtime_id: "runtime", command_id: ""},
          %{runtime_id: "runtime", command_id: self()},
          %{runtime_id: "runtime", command_id: nil, extra: nil},
          %{runtime_id: String.duplicate("r", 257), command_id: nil}
        ] do
      assert Store.creation_recovery(store({:reply, :unavailable}), bad) ==
               {:error, :invalid_creation_recovery}

      refute_received {:creation_recovery_called, _}
    end
  end

  test "missing callback failures and malformed recovery preserve unavailable instead of empty coverage" do
    request = %{runtime_id: "runtime", command_id: nil}
    assert {:ok, missing} = Store.new(MissingAdapter, nil)
    assert Store.creation_recovery(missing, request) == :unavailable

    for mode <- [:exit, :raise, :throw],
        do: assert(Store.creation_recovery(store(mode), request) == :unavailable)

    for result <- [:absent, nil, :ok, {:ok, %{}}, {:error, :absent}],
        do: assert(Store.creation_recovery(store({:reply, result}), request) == :unavailable)

    assert Store.creation_recovery(store({:reply, {:ok, zero_reply()}}), request) ==
             {:ok, zero_reply()}
  end

  test "initial zero head is the sole nil-selection head and cannot hide an active command" do
    request = %{runtime_id: "runtime", command_id: nil}
    zero = zero_reply()
    assert Store.creation_recovery(store({:reply, {:ok, zero}}), request) == {:ok, zero}

    for head <- [
          %{zero.head | owner_generation: 1},
          %{zero.head | domain_version: 1},
          %{zero.head | active_command_id: "command"},
          %{zero.head | owner_selection: @selection},
          Map.put(zero.head, :extra, nil),
          Map.delete(zero.head, :domain_version)
        ] do
      assert Store.creation_recovery(store({:reply, {:ok, %{zero | head: head}}}), request) ==
               :unavailable
    end
  end

  test "active capsule retains original reservation while a successor selection changes only head" do
    reply = reserved_reply()
    request = %{runtime_id: "runtime", command_id: nil}
    assert Store.creation_recovery(store({:reply, {:ok, reply}}), request) == {:ok, reply}

    next = %{
      reply
      | head: %{reply.head | owner_generation: 3, owner_selection: String.duplicate("b", 64)}
    }

    assert Store.creation_recovery(store({:reply, {:ok, next}}), request) == {:ok, next}

    for bad <- [
          %{reply | command: nil},
          %{reply | runtime_id: "other"},
          %{reply | head: %{reply.head | active_command_id: "other"}},
          %{reply | head: %{reply.head | owner_selection: String.duplicate("b", 64)}},
          %{reply | command: %{reply.command | runtime_id: "other"}},
          %{reply | command: %{reply.command | reservation_tx_id: "changed"}}
        ] do
      assert Store.creation_recovery(store({:reply, {:ok, bad}}), request) == :unavailable
    end
  end

  test "reserved recovery rejects a domain advance while retaining the active capsule" do
    reply = reserved_reply()
    request = %{runtime_id: "runtime", command_id: nil}

    successor = %{
      reply
      | head: %{reply.head | owner_generation: 3, owner_selection: String.duplicate("b", 64)}
    }

    assert Store.creation_recovery(store({:reply, {:ok, successor}}), request) == {:ok, successor}
    assert successor.command == reply.command

    for version <- [0, 2] do
      impossible = %{successor | head: %{successor.head | domain_version: version}}
      assert Store.creation_recovery(store({:reply, {:ok, impossible}}), request) == :unavailable
    end
  end

  test "command selector admits exact terminal history while another command owns the head" do
    request = %{runtime_id: "runtime", command_id: "command"}
    reserved = reserved_reply()

    for {state, resolution, session} <- [
          {:created, :committed, "session"},
          {:not_committed, {:not_committed, :creation_cancelled}, nil}
        ] do
      reply = %{
        reserved
        | head: %{
            reserved.head
            | owner_generation: 6,
              domain_version: 5,
              active_command_id: "another"
          },
          command: %{
            reserved.command
            | state: state,
              final_resolution: resolution,
              session_id: session
          }
      }

      assert Store.creation_recovery(store({:reply, {:ok, reply}}), request) == {:ok, reply}

      assert Store.creation_recovery(store({:reply, {:ok, reply}}), %{request | command_id: nil}) ==
               :unavailable

      assert Store.creation_recovery(store({:reply, {:ok, reply}}), %{
               request
               | command_id: "wrong"
             }) == :unavailable
    end

    empty = %{reserved | head: %{reserved.head | active_command_id: "another"}, command: nil}
    assert Store.creation_recovery(store({:reply, {:ok, empty}}), request) == {:ok, empty}
  end

  test "positive recovery and receipt heads retain generation above domain version" do
    request = %{runtime_id: "runtime", command_id: nil}
    zero = zero_reply()
    claimed = %{zero | head: %{zero.head | owner_generation: 1, owner_selection: @selection}}
    assert Store.creation_recovery(store({:reply, {:ok, claimed}}), request) == {:ok, claimed}

    for {generation, version} <- [{1, 1}, {1, 2}] do
      impossible = %{
        claimed
        | head: %{claimed.head | owner_generation: generation, domain_version: version}
      }

      assert Store.creation_recovery(store({:reply, {:ok, impossible}}), request) == :unavailable
    end

    reserved = reserved_reply()

    terminal = %{
      reserved
      | head: %{reserved.head | owner_generation: 3, domain_version: 2, active_command_id: nil},
        command: %{
          reserved.command
          | state: :created,
            final_resolution: :committed,
            session_id: "session"
        }
    }

    exact = %{request | command_id: "command"}
    assert Store.creation_recovery(store({:reply, {:ok, terminal}}), exact) == {:ok, terminal}
    impossible = %{terminal | head: %{terminal.head | owner_generation: 3, domain_version: 3}}
    assert Store.creation_recovery(store({:reply, {:ok, impossible}}), exact) == :unavailable
    [_claim, _reserve, close] = transactions()
    r = receipt(close)

    assert Store.transact(store({:reply, {:committed, close.tx_id, r}}), close) ==
             {:committed, close.tx_id, r}

    impossible_receipt = %{r | owner_generation: r.domain_version}

    assert Store.transact(store({:reply, {:committed, close.tx_id, impossible_receipt}}), close) ==
             {:commit_unknown, close.tx_id}
  end

  test "head occupation and domain version parity reject impossible recovery and receipts" do
    reserved = reserved_reply()
    absent = %{runtime_id: "runtime", command_id: "absent"}
    occupied = %{reserved | command: nil}
    assert Store.creation_recovery(store({:reply, {:ok, occupied}}), absent) == {:ok, occupied}
    even_occupied = %{occupied | head: %{occupied.head | owner_generation: 3, domain_version: 2}}
    assert Store.creation_recovery(store({:reply, {:ok, even_occupied}}), absent) == :unavailable
    active = %{absent | command_id: nil}

    empty = %{
      occupied
      | head: %{occupied.head | owner_generation: 3, domain_version: 2, active_command_id: nil}
    }

    assert Store.creation_recovery(store({:reply, {:ok, empty}}), active) == {:ok, empty}
    odd_empty = %{empty | head: %{empty.head | domain_version: 1}}
    assert Store.creation_recovery(store({:reply, {:ok, odd_empty}}), active) == :unavailable
    [_claim, _reserve, close] = transactions()
    r = receipt(close)

    assert Store.transact(store({:reply, {:committed, close.tx_id, r}}), close) ==
             {:committed, close.tx_id, r}

    for impossible <- [
          %{r | owner_generation: 4, domain_version: 3},
          %{r | owner_generation: 5, domain_version: 4, active_command_id: "another"}
        ] do
      assert Store.transact(store({:reply, {:committed, close.tx_id, impossible}}), close) ==
               {:commit_unknown, close.tx_id}
    end
  end

  test "capsules are closed and terminal conditional members cannot be substituted" do
    reply = reserved_reply()
    request = %{runtime_id: "runtime", command_id: nil}

    for command <-
          Enum.map(Map.keys(reply.command), &Map.delete(reply.command, &1)) ++
            [
              Map.put(reply.command, :extra, nil),
              %{reply.command | state: :unknown},
              %{reply.command | final_resolution: :committed},
              %{reply.command | session_id: "session"},
              %{reply.command | reservation_owner_generation: 0},
              %{reply.command | reservation_owner_generation: @uint64},
              %{reply.command | reservation_domain_version: 0},
              %{reply.command | reservation_owner_selection: "invalid"},
              %{reply.command | genesis: %{kind: "old"}}
            ] do
      assert Store.creation_recovery(store({:reply, {:ok, %{reply | command: command}}}), request) ==
               :unavailable
    end

    assert Store.creation_recovery(store({:reply, {:ok, Map.put(reply, :extra, nil)}}), request) ==
             :unavailable
  end

  test "recovery normalizes its one genesis independently of fixed envelope nesting" do
    reply = reserved_reply()
    changed = Map.delete(reply.command.genesis, "options") |> Map.put(:options, %{})
    input = %{reply | command: %{reply.command | genesis: changed}}

    assert Store.creation_recovery(store({:reply, {:ok, input}}), %{
             runtime_id: "runtime",
             command_id: nil
           }) == {:ok, reply}

    deep = Enum.reduce(1..13, "leaf", fn _, acc -> %{"nested" => acc} end)
    oversized = Map.put(reply.command.genesis, "options", %{"nested" => deep})

    assert Store.creation_recovery(
             store({:reply, {:ok, %{reply | command: %{reply.command | genesis: oversized}}}}),
             %{runtime_id: "runtime", command_id: nil}
           ) == :unavailable
  end

  test "genesis item and entire recovery reply byte ceilings retain bounded unavailable results" do
    reply = reserved_reply()

    giant =
      Map.put(reply.command.genesis, "options", %{"payload" => String.duplicate("b", 1_048_577)})

    bad = %{reply | command: %{reply.command | genesis: giant}}
    assert :erlang.external_size(bad, [:deterministic]) > 1_048_576

    assert Store.creation_recovery(store({:reply, {:ok, bad}}), %{
             runtime_id: "runtime",
             command_id: nil
           }) == :unavailable

    assert {:error, _} = Store.reserve_creation("runtime", "command", 1, @selection, 0, giant)
    # A closed reply has only one at-most65536-byte genesis; fixed IDs are at most256.
    bounded = %{reply | head: %{reply.head | owner_generation: @uint64 - 1}}
    assert :erlang.external_size(bounded, [:deterministic]) <= 1_048_576

    assert Store.creation_recovery(store({:reply, {:ok, bounded}}), %{
             runtime_id: "runtime",
             command_id: nil
           }) == {:ok, bounded}
  end

  test "counter exhaustion remains a closed atomic adapter refusal not a malformed binding" do
    {:ok, reserve} =
      Store.reserve_creation("runtime", "command", @uint64, @selection, @uint64, genesis())

    assert :ok = Store.validate_transaction(reserve)

    assert Store.transact(store({:reply, {:not_committed, :creation_counter_exhausted}}), reserve) ==
             {:not_committed, :creation_counter_exhausted}

    assert Store.transact(store({:reply, {:committed, reserve.tx_id, receipt(reserve)}}), reserve) ==
             {:commit_unknown, reserve.tx_id}
  end

  test "runtime command normalization retains cancellation and preserves successful final result" do
    request = %{
      runtime_id: "runtime",
      command_id: "command",
      command_kind: :create,
      mutation_domain: "runtime",
      succession_id: "succession",
      canonical_command_bytes: "original",
      canonical_command_digest: hash("original")
    }

    assert Store.runtime_command(store({:reply, {:not_committed, :creation_cancelled}}), request) ==
             {:not_committed, :creation_cancelled}

    assert Store.runtime_command(store({:reply, {:completed, %{result: "session"}}}), request) ==
             {:completed, %{result: "session"}}

    assert Store.runtime_command(store({:reply, {:not_committed, :adapter_text}}), request) ==
             :unavailable
  end

  test "recovery scalar counters and fixed version members refuse coercion and overflow" do
    reply = reserved_reply()
    request = %{runtime_id: "runtime", command_id: nil}

    for bad <- [-1, @uint64 + 1, 2.0, "2", self()] do
      for field <- [:owner_generation, :domain_version] do
        changed = %{reply | head: Map.put(reply.head, field, bad)}
        assert Store.creation_recovery(store({:reply, {:ok, changed}}), request) == :unavailable
      end
    end

    for changed <- [
          %{reply | head: %{reply.head | owner_generation: @uint64}},
          %{reply | head: %{reply.head | domain_version: @uint64}},
          %{reply | version: 1.0},
          %{reply | head: %{reply.head | version: 1.0}},
          %{reply | command: %{reply.command | version: 1.0}},
          Map.put(reply, :__struct__, URI)
        ] do
      assert Store.creation_recovery(store({:reply, {:ok, changed}}), request) == :unavailable
    end
  end

  test "terminal recovery rejects wrong cancellation result missing session and active reattachment" do
    reserved = reserved_reply()
    request = %{runtime_id: "runtime", command_id: "command"}

    closed = %{
      reserved
      | head: %{reserved.head | owner_generation: 3, domain_version: 2, active_command_id: nil},
        command: %{
          reserved.command
          | state: :created,
            final_resolution: :committed,
            session_id: "session"
        }
    }

    assert Store.creation_recovery(store({:reply, {:ok, closed}}), request) == {:ok, closed}

    for changed <- [
          %{closed | command: %{closed.command | session_id: nil}},
          %{
            closed
            | command: %{
                closed.command
                | state: :not_committed,
                  final_resolution: {:not_committed, :adapter_text},
                  session_id: nil
              }
          },
          %{
            closed
            | command: %{
                closed.command
                | state: :not_committed,
                  final_resolution: {:not_committed, :creation_cancelled}
              }
          },
          %{closed | head: %{closed.head | active_command_id: "command"}},
          %{closed | head: %{closed.head | domain_version: 1}}
        ] do
      assert Store.creation_recovery(store({:reply, {:ok, changed}}), request) == :unavailable
    end
  end

  test "capsule origin and head advances reject four impossible correlations with reachable controls" do
    reserved = reserved_reply()
    request = %{runtime_id: "runtime", command_id: "command"}

    reply = fn origin, reservation_version, generation, version, selection, state ->
      command = %{
        reserved.command
        | reservation_owner_generation: origin,
          reservation_domain_version: reservation_version,
          reservation_tx_id: id(["loopex_creation_reserve_v1", "runtime", "command", origin]),
          state: state,
          final_resolution: if(state == :reserved, do: nil, else: :committed),
          session_id: if(state == :reserved, do: nil, else: "session")
      }

      head = %{
        reserved.head
        | owner_generation: generation,
          domain_version: version,
          owner_selection: selection,
          active_command_id: if(state == :reserved, do: "command", else: nil)
      }

      %{reserved | command: command, head: head}
    end

    for {origin, reservation_version, generation, version, selection, state} <- [
          {1, 1, 2, 1, @selection, :reserved},
          {1, 1, 3, 2, @selection, :created},
          {1, 1, 4, 2, String.duplicate("b", 64), :created},
          {3, 3, 4, 3, @selection, :reserved},
          {5, 3, 6, 3, @selection, :reserved},
          {1, 1, 7, 6, @selection, :created},
          {1, 1, 8, 6, String.duplicate("b", 64), :created}
        ] do
      reachable = reply.(origin, reservation_version, generation, version, selection, state)

      assert Store.creation_recovery(store({:reply, {:ok, reachable}}), request) ==
               {:ok, reachable}
    end

    for {label, origin, reservation_version, generation, version, selection, state} <- [
          {"even reservation version", 3, 2, 6, 4, @selection, :created},
          {"origin generation below reservation version", 1, 3, 4, 3, @selection, :reserved},
          {"version advances exceed generation advances", 5, 1, 8, 6, @selection, :created},
          {"changed selection without a later claim", 1, 1, 3, 2, String.duplicate("b", 64),
           :created}
        ] do
      impossible = reply.(origin, reservation_version, generation, version, selection, state)

      assert Store.creation_recovery(store({:reply, {:ok, impossible}}), request) == :unavailable,
             label
    end
  end

  test "claim receipts preserve empty and occupied headroom without rejecting exhaustion proposals" do
    {:ok, last_empty} = Store.claim_creation_domain("runtime", @uint64 - 3, @selection)
    assert :ok = Store.validate_transaction(last_empty)
    valid_empty = receipt(last_empty)

    assert Store.transact(
             store({:reply, {:committed, last_empty.tx_id, valid_empty}}),
             last_empty
           ) ==
             {:committed, last_empty.tx_id, valid_empty}

    for generation <- [@uint64 - 2, @uint64 - 1] do
      {:ok, exhausted} = Store.claim_creation_domain("runtime", generation, @selection)
      assert :ok = Store.validate_transaction(exhausted)
      impossible = receipt(exhausted)

      assert Store.transact(store({:reply, {:committed, exhausted.tx_id, impossible}}), exhausted) ==
               {:commit_unknown, exhausted.tx_id}

      assert Store.transact(
               store({:reply, {:not_committed, :creation_counter_exhausted}}),
               exhausted
             ) ==
               {:not_committed, :creation_counter_exhausted}
    end

    {:ok, last_occupied} = Store.claim_creation_domain("runtime", @uint64 - 2, @selection)
    valid_occupied = %{receipt(last_occupied) | domain_version: 1, active_command_id: "command"}

    assert Store.transact(
             store({:reply, {:committed, last_occupied.tx_id, valid_occupied}}),
             last_occupied
           ) ==
             {:committed, last_occupied.tx_id, valid_occupied}
  end

  test "close receipts reject even reservation versions while preserving well-shaped proposals" do
    [_claim, reserve, original] = transactions()
    {:ok, final} = Store.create_session("runtime", "command", genesis())

    {:ok, even} =
      Store.close_creation_reservation(
        "runtime",
        "command",
        2,
        @selection,
        1,
        reserve.tx_id,
        2,
        final
      )

    assert :ok = Store.validate_transaction(even)
    assert even.tx_id == original.tx_id
    refute even.canonical_record_bytes == original.canonical_record_bytes
    assert even.final_canonical_record_bytes == final.canonical_record_bytes

    impossible = %{
      receipt(even)
      | owner_generation: 5,
        domain_version: 4,
        final_resolution: :committed,
        session_id: "historical-session"
    }

    assert Store.transact(store({:reply, {:committed, even.tx_id, impossible}}), even) ==
             {:commit_unknown, even.tx_id}

    assert Store.transact(store({:reply, {:not_committed, :creation_reservation_conflict}}), even) ==
             {:not_committed, :creation_reservation_conflict}

    valid = receipt(original)

    assert Store.transact(store({:reply, {:committed, original.tx_id, valid}}), original) ==
             {:committed, original.tx_id, valid}
  end

  defp genesis(base \\ "original creation"), do: Fixture.genesis([], Fixture.configuration(base))

  defp store(reference) do
    {:ok, store} = Store.new(Adapter, reference)
    store
  end

  defp transactions do
    {:ok, claim} = Store.claim_creation_domain("runtime", 0, @selection)
    {:ok, reserve} = Store.reserve_creation("runtime", "command", 1, @selection, 0, genesis())
    {:ok, final} = Store.create_session("runtime", "command", genesis())

    {:ok, close} =
      Store.close_creation_reservation(
        "runtime",
        "command",
        2,
        @selection,
        1,
        reserve.tx_id,
        1,
        final
      )

    [claim, reserve, close]
  end

  defp receipt(%{type: :claim_creation_domain} = t),
    do: %{
      type: t.type,
      runtime_id: t.runtime_id,
      owner_generation: t.expected_owner_generation + 1,
      owner_selection: t.owner_selection,
      domain_version: 0,
      active_command_id: nil
    }

  defp receipt(%{type: :reserve_creation} = t),
    do: %{
      type: t.type,
      runtime_id: t.runtime_id,
      owner_generation: t.owner_generation + 1,
      owner_selection: t.owner_selection,
      domain_version: t.expected_domain_version + 1,
      active_command_id: t.command_id,
      reservation_tx_id: t.tx_id,
      reservation_domain_version: t.expected_domain_version + 1
    }

  defp receipt(%{type: :close_creation_reservation} = t),
    do: %{
      type: t.type,
      runtime_id: t.runtime_id,
      owner_generation: t.owner_generation + 1,
      owner_selection: t.owner_selection,
      domain_version: t.expected_domain_version + 1,
      active_command_id: nil,
      command_id: t.command_id,
      reservation_tx_id: t.reservation_tx_id,
      final_resolution: {:not_committed, :creation_cancelled},
      session_id: nil
    }

  defp zero_reply,
    do: %{
      version: 1,
      runtime_id: "runtime",
      head: %{
        version: 1,
        owner_generation: 0,
        owner_selection: nil,
        domain_version: 0,
        active_command_id: nil
      },
      command: nil
    }

  defp reserved_reply do
    [_, reserve | _] = transactions()

    capsule = %{
      version: 1,
      runtime_id: "runtime",
      command_id: "command",
      reservation_tx_id: reserve.tx_id,
      reservation_owner_generation: 1,
      reservation_owner_selection: @selection,
      reservation_domain_version: 1,
      genesis: reserve.genesis,
      state: :reserved,
      final_resolution: nil,
      session_id: nil
    }

    %{
      version: 1,
      runtime_id: "runtime",
      head: %{
        version: 1,
        owner_generation: 2,
        owner_selection: @selection,
        domain_version: 1,
        active_command_id: "command"
      },
      command: capsule
    }
  end

  defp recanonical(t) do
    fields =
      case t.type do
        :claim_creation_domain ->
          [:type, :runtime_id, :expected_owner_generation, :owner_selection, :tx_id]

        :reserve_creation ->
          [
            :type,
            :runtime_id,
            :command_id,
            :owner_generation,
            :owner_selection,
            :expected_domain_version,
            :genesis,
            :tx_id
          ]

        :close_creation_reservation ->
          [
            :type,
            :runtime_id,
            :command_id,
            :owner_generation,
            :owner_selection,
            :expected_domain_version,
            :reservation_tx_id,
            :reservation_domain_version,
            :final_canonical_record_bytes,
            :final_canonical_mutation_digest,
            :tx_id
          ]
      end

    bytes = encode(Enum.map(fields, &{&1, Map.fetch!(t, &1)}))
    %{t | canonical_record_bytes: bytes, canonical_mutation_digest: hash(bytes)}
  end

  defp encode(fields),
    do: :erlang.term_to_binary(["loopex_store_transaction_v1" | fields], [:deterministic])

  defp hash(bytes), do: :crypto.hash(:sha256, bytes)

  defp id(values),
    do:
      values |> :erlang.term_to_binary([:deterministic]) |> hash() |> Base.encode16(case: :lower)
end
