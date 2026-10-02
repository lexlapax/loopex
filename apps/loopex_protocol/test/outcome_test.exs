defmodule LoopexProtocol.Session.OutcomeTest do
  use ExUnit.Case, async: true

  alias LoopexProtocol.Frame
  alias LoopexProtocol.Session.Outcome

  test "literal terminal vectors pin all branches, refusal shapes and exact quantities" do
    fixture = read_contract("vectors/chat-terminal-outcome.v1.json")
    assert fixture["contract"] == "chat_terminal_outcome"
    assert length(fixture["cases"]) == 64

    for vector <- fixture["cases"] do
      if vector["error"] do
        assert Outcome.decode_wire(vector["input"]) == :error, vector["name"]
      else
        assert {:ok, native} = Outcome.decode_wire(vector["input"]), vector["name"]
        assert retained(native) == vector["decoded"], vector["name"]
        assert Outcome.encode_wire(native) == {:ok, vector["input"]}, vector["name"]
      end
    end
  end

  test "native observations refuse missing, extra, mixed and private members" do
    completed = %{outcome: :completed, details: %{"cleanup_grace_ms" => 5000}}
    assert {:ok, _} = Outcome.encode_wire(completed)

    for invalid <- [
          %{completed | outcome: :no_ending},
          %{completed | outcome: "completed"},
          Map.put(completed, :cleanup, :confirmed),
          %{completed | details: %{cleanup_grace_ms: 5000}},
          %{completed | details: %{"cleanup_grace_ms" => "5000"}},
          %{completed | details: %{"cleanup_grace_ms" => 5000, "secret" => self()}},
          %{completed | details: %URI{}},
          %URI{},
          nil,
          []
        ] do
      assert Outcome.encode_wire(invalid) == :error
    end

    assert Outcome.decode_wire(completed) == :error

    assert Outcome.decode_wire(%{"outcome" => "completed", "details" => %{cleanup_grace_ms: "1"}}) ==
             :error
  end

  test "existing native deadline failure projects to the full closed wire failure" do
    native = %{
      outcome: :failed,
      details: %{
        "reason" => nil,
        "failure" => %{"category" => "deadline_preflight_failed", "retryable" => false},
        "cleanup_grace_ms" => 1
      }
    }

    assert {:ok, wire} = Outcome.encode_wire(native)

    assert wire["details"]["failure"] == %{
             "category" => "deadline_preflight_failed",
             "retryable" => false,
             "dimension" => nil,
             "observed" => nil,
             "limit" => nil
           }

    assert {:ok, decoded} = Outcome.decode_wire(wire)
    assert decoded.details["failure"]["dimension"] == nil

    private = put_in(native, [:details, "failure", "private"], "secret")
    assert Outcome.encode_wire(private) == :error
  end

  test "opaque reference bounds are exact and never interpreted as UTF-8" do
    bytes = :binary.copy(<<255>>, 65_536)

    native = %{
      outcome: :outcome_unknown,
      details: %{
        "cleanup_grace_ms" => 1,
        "reconciliation_ref" => bytes
      }
    }

    assert {:ok, wire} = Outcome.encode_wire(native)
    assert Outcome.decode_wire(wire) == {:ok, native}

    assert Outcome.encode_wire(put_in(native, [:details, "reconciliation_ref"], bytes <> "x")) ==
             :error
  end

  test "schema fixes the closed terminal-only union and retains distinct quantity domains" do
    schema = read_contract("schema/chat-terminal-outcome.v1.json")
    assert schema["required"] == ["outcome", "details"]
    assert schema["additional_members"] == "refuse"

    assert schema["details"] == %{
             "completed" => ["cleanup_grace_ms"],
             "cancelled" => ["cleanup_grace_ms"],
             "failed" => ["reason", "failure", "cleanup_grace_ms"],
             "bound_reached" => [
               "bound",
               "observed",
               "declared_limit",
               "accounting_source",
               "cleanup_grace_ms"
             ],
             "outcome_unknown" => ["reconciliation_ref", "cleanup_grace_ms"]
           }

    assert schema["quantities"]["max_turns"] == "arbitrary_nonnegative_integer"
    assert schema["quantities"]["token_budget"] == "arbitrary_nonnegative_integer"
    assert schema["quantities"]["deadline"] == "nonnegative_u64"
    assert schema["reconciliation_ref"]["original_max_bytes"] == 65_536
  end

  @tag :node_client
  test "an independent Node implementation executes the same terminal vectors" do
    node = System.find_executable("node") || flunk("Node is required for terminal conformance")
    root = Path.expand("../../..", __DIR__)
    runner = Path.join(root, "clients/node/terminal-outcome-vectors.mjs")
    vectors = Path.join(root, "apps/loopex_protocol/priv/vectors/chat-terminal-outcome.v1.json")
    {output, status} = System.cmd(node, [runner, vectors], stderr_to_stdout: true)
    assert status == 0, output

    assert {:ok,
            %{"contract" => "chat_terminal_outcome", "checked" => 64, "boundary_checks" => 2}} =
             Frame.decode(String.trim_trailing(output, "\n"), 65_536)
  end

  defp retained(%{outcome: outcome, details: details}),
    do: %{"outcome" => Atom.to_string(outcome), "details" => retained(details)}

  defp retained(value) when is_map(value) do
    Map.new(value, fn
      {"reconciliation_ref", bytes} ->
        {"reconciliation_ref", %{"opaque_hex" => Base.encode16(bytes, case: :lower)}}

      {key, member} ->
        {key, retained(member)}
    end)
  end

  defp retained(value) when is_integer(value), do: Integer.to_string(value)
  defp retained(value), do: value

  defp read_contract(relative) do
    path = Path.join([:code.priv_dir(:loopex_protocol), relative])
    {:ok, value} = path |> File.read!() |> String.trim_trailing("\n") |> Frame.decode(65_536)
    value
  end
end
