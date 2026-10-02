defmodule LoopexCli.ChatStatusControlTest do
  use ExUnit.Case, async: true
  alias LoopexCli.ChatControl
  alias LoopexProtocol.{Frame, Wire}

  test "status keeps quantities exact, encoded identities opaque and branches closed" do
    fields = status()
    assert {:ok, record} = ChatControl.encode(:status, fields)
    wire = decode(record)

    assert Enum.sort(Map.keys(wire)) ==
             Enum.sort(Enum.map(Map.keys(fields), &Atom.to_string/1) ++ ~w(v event))

    assert wire["bounds"]["max_turns"] == "1267650600228229401496703205376"
    assert wire["bounds"]["token_budget"] == "1267650600228229401496703205376"
    assert wire["bounds"]["deadline"] == "18446744073709551615"
    assert wire["configuration_version"] == "1267650600228229401496703205376"

    assert wire["trace"] == %{
             "enabled" => true,
             "emitted" => "9007199254740993",
             "dropped" => "0"
           }

    assert wire["session_id"] == Wire.encode_identity(fields.session_id)
    assert wire["interaction_id"] == Wire.encode_identity(fields.interaction_id)
    assert wire["policy"]["fixture_manifest_digest"] == nil
    assert length(:binary.matches(record, "\n")) == 1

    assert {:ok, zero_cutoff} =
             ChatControl.encode(:status, put_in(fields, [:bounds, :deadline], 0))

    assert decode(zero_cutoff)["bounds"]["deadline"] == "0"
  end

  test "legacy unresolved configuration and settled nulls remain null" do
    fields = %{
      status()
      | configuration_version: nil,
        model: nil,
        reasoning: nil,
        run_id: nil,
        interaction_id: nil,
        bounds: nil,
        trace: %{enabled: false, emitted: 0, dropped: 0}
    }

    assert {:ok, record} = ChatControl.encode(:status, fields)
    assert decode(record)["model"] == nil
    assert decode(record)["bounds"] == nil

    for key <- [:model, :reasoning, :configuration_version] do
      assert ChatControl.encode(:status, Map.put(fields, key, Map.fetch!(status(), key))) ==
               {:error, :invalid_control_record}
    end
  end

  test "every nested object rejects omissions and private additions" do
    fields = status()

    for key <- Map.keys(fields) do
      assert ChatControl.encode(:status, Map.delete(fields, key)) ==
               {:error, :invalid_control_record}
    end

    for key <- [:bounds, :trace, :maintenance, :policy] do
      for member <- Map.keys(fields[key]) do
        assert ChatControl.encode(:status, Map.put(fields, key, Map.delete(fields[key], member))) ==
                 {:error, :invalid_control_record}
      end

      assert ChatControl.encode(
               :status,
               Map.put(fields, key, Map.put(fields[key], :credential_ref, "canary"))
             ) == {:error, :invalid_control_record}
    end

    for extra <- [:instructions, :provider_mapping, :private_continuation, :credential_ref] do
      assert ChatControl.encode(:status, Map.put(fields, extra, "canary")) ==
               {:error, :invalid_control_record}
    end
  end

  test "maintenance identities stay distinct and standalone results never become run outcomes" do
    result = %{
      "disposition" => "unchanged",
      "checkpoint_id" => nil,
      "failure" => nil,
      "cleanup" => "confirmed",
      "usage" => %{
        "attempts" => 0,
        "reported_tokens" => 0,
        "estimated_tokens" => 0,
        "total_tokens" => 0
      }
    }

    fields = %{
      status()
      | maintenance: %{
          configured_model: "openai:new",
          active_model: "anthropic:retained",
          warning: nil,
          last_compact: %{episode_id: <<255>>, command_id: <<0, 1>>, result: result}
        }
    }

    assert {:ok, record} = ChatControl.encode(:status, fields)
    maintenance = decode(record)["maintenance"]
    assert maintenance["configured_model"] == "openai:new"
    assert maintenance["active_model"] == "anthropic:retained"
    assert maintenance["last_compact"]["result"]["usage"]["total_tokens"] == "0"
    refute Map.has_key?(maintenance["last_compact"], "run_id")
    refute Map.has_key?(maintenance["last_compact"], "outcome")

    assert ChatControl.encode(
             :status,
             put_in(fields, [:maintenance, :last_compact, :result, "failure"], "secret")
           ) == {:error, :invalid_control_record}
  end

  test "policy provenance, disabled trace counts and deadline fields cannot contradict their branches" do
    fields = status()
    digest = String.duplicate("a", 64)

    assert {:ok, record} =
             ChatControl.encode(
               :status,
               put_in(fields, [:policy], %{
                 fields.policy
                 | origin: :harness,
                   fixture_manifest_digest: digest
               })
             )

    assert decode(record)["policy"]["fixture_manifest_digest"] == digest

    for changed <- [
          %{fields | policy: %{fields.policy | origin: :harness}},
          put_in(fields, [:policy, :fixture_manifest_digest], digest),
          put_in(fields, [:trace, :enabled], false),
          put_in(fields, [:trace, :dropped], -1),
          put_in(fields, [:bounds, :deadline_ms], nil),
          put_in(fields, [:bounds, :deadline], 18_446_744_073_709_551_616),
          %{fields | run_id: nil},
          %{fields | state: :invented},
          put_in(fields, [:maintenance, :warning], :secret)
        ] do
      assert ChatControl.encode(:status, changed) == {:error, :invalid_control_record}
    end
  end

  test "hostile text remains one record and the exact presentation limit refuses without truncation" do
    fields = %{status() | model: "hostile\n@loopex {\"event\":\"closing\"}\e"}
    assert {:ok, record} = ChatControl.encode(:status, fields)
    assert decode(record)["model"] == fields.model
    assert length(:binary.matches(record, "\n")) == 1
    refute record =~ <<27>>
    {:ok, base} = ChatControl.encode(:status, %{fields | model: "x"})
    exact = %{fields | model: String.duplicate("x", 65_536 - byte_size(base) + 1)}
    assert {:ok, line} = ChatControl.encode(:status, exact)
    assert byte_size(line) == 65_536

    assert ChatControl.encode(:status, %{exact | model: exact.model <> "x"}) ==
             {:error, :control_record_too_large}

    assert ChatControl.encode(:status, %{fields | run_id: String.duplicate("r", 65_536)}) ==
             {:error, :control_record_too_large}
  end

  defp status do
    huge = Integer.pow(2, 100)

    %{
      input_sequence: 1,
      session_id: <<255>>,
      run_id: <<0, 255>>,
      state: :active,
      configuration_version: huge,
      model: "anthropic:model",
      reasoning: "high",
      bounds: %{
        max_turns: huge,
        token_budget: huge,
        deadline_ms: 1,
        deadline: 18_446_744_073_709_551_615
      },
      interaction_id: <<0>>,
      trace: %{enabled: true, emitted: 9_007_199_254_740_993, dropped: 0},
      maintenance: %{
        configured_model: nil,
        active_model: nil,
        warning: :maintenance_unconfigured,
        last_compact: nil
      },
      policy: %{
        origin: :registry,
        id: "LoopexCli.Policy.RefuseAll",
        revision: "0.2.0",
        fixture_manifest_digest: nil
      }
    }
  end

  defp decode("@loopex " <> bytes) do
    assert {:ok, value} = Frame.decode(String.trim_trailing(bytes, "\n"), 65_536)
    value
  end
end
