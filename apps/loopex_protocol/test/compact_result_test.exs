defmodule LoopexProtocol.CompactResultTest do
  use ExUnit.Case, async: true
  alias LoopexProtocol.Frame
  alias LoopexProtocol.Session.CompactResult

  test "literal standalone result vectors pin exact bytes and every closed failure" do
    fixture = read_contract("vectors/standalone-compact-result.v1.json")
    assert fixture["format"] == "loopex.experimental.payload-vectors/1"
    assert fixture["contract"] == "standalone_compact_result"
    assert length(fixture["cases"]) == 119

    for vector <- fixture["cases"] do
      if vector["error"] do
        assert CompactResult.decode_wire(vector["input"]) == :error, vector["name"]
      else
        assert {:ok, native} = CompactResult.decode_wire(vector["input"]), vector["name"]
        assert retained(native) == vector["decoded"], vector["name"]
        assert CompactResult.encode_wire(native) == {:ok, vector["input"]}, vector["name"]
      end
    end
  end

  test "opaque checkpoints retain the complete identity boundary" do
    bytes = :binary.copy(<<255>>, 65_536)
    native = result("checkpointed", bytes, nil, "confirmed", 0)
    assert {:ok, wire} = CompactResult.encode_wire(native)
    assert CompactResult.decode_wire(wire) == {:ok, native}

    assert CompactResult.encode_wire(%{native | "checkpoint_id" => bytes <> "x"}) == :error

    assert CompactResult.decode_wire(%{
             wire
             | "checkpoint_id" => Base.url_encode64(bytes <> "x", padding: false)
           }) == :error
  end

  test "schema fixes standalone bounds and closed accounting without parent run fields" do
    schema = read_contract("schema/standalone-compact-result.v1.json")
    assert schema["required"] == ~w(disposition checkpoint_id failure usage cleanup)
    assert schema["additional_members"] == "refuse"

    assert schema["usage"]["required"] ==
             ~w(attempts reported_tokens estimated_tokens total_tokens)

    assert schema["usage"]["domain"] == "arbitrary_nonnegative_integer"

    assert schema["failure"]["bound_reached"]["bounds"] ==
             ~w(max_attempts deadline_ms token_budget)

    assert schema["failure"]["bound_reached"]["max_attempts_accounting_source"] == nil
    assert schema["failure"]["numeric_v2"]["context_record_bytes_hard_limit"] == "65536"
    assert schema["failure"]["preparation_v2"]["measurement_scope"] == [nil, "ordinary"]
    assert length(schema["failure"]["preparation_v2"]["causes"]) == 17
  end

  test "the complete schema and literal vector bytes have retained identities" do
    for {relative, digest} <- [
          {"schema/standalone-compact-result.v1.json",
           "b0f47ab083166328d9c66d5f084daa52d0e5aaea59182af1649a108fe3ab026f"},
          {"vectors/standalone-compact-result.v1.json",
           "f25445cd209927d8166744db843cfc81a2e16ed9f527e2b1867030cc07454982"}
        ] do
      path = Path.join([:code.priv_dir(:loopex_protocol), relative])
      assert :crypto.hash(:sha256, File.read!(path)) |> Base.encode16(case: :lower) == digest
    end
  end

  @tag :node_client
  test "an independent Node consumer executes the retained result vectors" do
    node = System.find_executable("node") || flunk("Node is required for compact conformance")
    root = Path.expand("../../..", __DIR__)
    runner = Path.join(root, "clients/node/compact-result-vectors.mjs")

    vectors =
      Path.join(root, "apps/loopex_protocol/priv/vectors/standalone-compact-result.v1.json")

    {output, status} = System.cmd(node, [runner, vectors], stderr_to_stdout: true)
    assert status == 0, output

    assert {:ok,
            %{"contract" => "standalone_compact_result", "checked" => 119, "boundary_checks" => 4}} =
             Frame.decode(String.trim_trailing(output, "\n"), 65_536)
  end

  test "success and partial failure retain opaque checkpoints and arbitrary usage" do
    huge = Integer.pow(2, 100)

    for {disposition, checkpoint, failure, cleanup} <- [
          {"checkpointed", <<0, 255, 10>>, nil, "confirmed"},
          {"unchanged", nil, nil, "confirmed"},
          {"failed", <<255>>, %{"category" => "cancelled", "retryable" => false}, "unknown"}
        ] do
      native = result(disposition, checkpoint, failure, cleanup, huge)
      assert {:ok, wire} = CompactResult.encode_wire(native)
      assert wire["usage"]["total_tokens"] == Integer.to_string(huge + 7)
      assert wire["usage"]["attempts"] == "2"
      assert {:ok, ^native} = CompactResult.decode_wire(wire)
    end
  end

  test "failure alternatives retain their exact fields and numeric domains" do
    for failure <- failures() do
      native = result("failed", nil, failure, "confirmed", 3)
      assert {:ok, wire} = CompactResult.encode_wire(native)
      assert {:ok, ^native} = CompactResult.decode_wire(wire)

      for key <- Map.keys(failure) do
        assert CompactResult.encode_wire(%{native | "failure" => Map.delete(failure, key)}) ==
                 :error
      end

      assert CompactResult.encode_wire(%{
               native
               | "failure" => Map.put(failure, "secret", "canary")
             }) == :error

      assert CompactResult.decode_wire(put_in(wire, ["failure", "retryable"], true)) == :error
    end
  end

  test "every result and usage member is required and private additions refuse" do
    native = result("unchanged", nil, nil, "confirmed", 3)

    for key <- Map.keys(native),
        do: assert(CompactResult.encode_wire(Map.delete(native, key)) == :error)

    for key <- Map.keys(native["usage"]) do
      assert CompactResult.encode_wire(
               put_in(native, ["usage"], Map.delete(native["usage"], key))
             ) == :error
    end

    assert CompactResult.encode_wire(Map.put(native, "provider_continuation", "canary")) == :error
    assert CompactResult.encode_wire(put_in(native, ["usage", "secret"], "canary")) == :error
    assert CompactResult.encode_wire(put_in(native, ["usage", "total_tokens"], 0)) == :error
    assert CompactResult.encode_wire(put_in(native, ["usage", "attempts"], -1)) == :error
    assert CompactResult.encode_wire(%URI{}) == :error
  end

  test "success cannot hide failed or unconfirmed cleanup or invent a checkpoint" do
    native = result("unchanged", nil, nil, "confirmed", 3)

    for changes <- [
          %{"cleanup" => "unknown"},
          %{"disposition" => "checkpointed"},
          %{"checkpoint_id" => "checkpoint"},
          %{"disposition" => "failed"},
          %{"failure" => %{"category" => "cancelled", "retryable" => false}}
        ] do
      assert CompactResult.encode_wire(Map.merge(native, changes)) == :error
    end
  end

  test "decimal and identity decoding refuses alternate spellings and numeric JSON" do
    assert {:ok, wire} =
             CompactResult.encode_wire(result("checkpointed", <<255>>, nil, "confirmed", 3))

    for value <- [0, 2, "02", "+2", " 2", "2.0", "-1", "", nil] do
      assert CompactResult.decode_wire(put_in(wire, ["usage", "attempts"], value)) == :error
    end

    for id <- ["_x", "_w=", "_w==", "", 5] do
      assert CompactResult.decode_wire(%{wire | "checkpoint_id" => id}) == :error
    end

    assert CompactResult.encode_wire(result("checkpointed", "", nil, "confirmed", 3)) == :error
  end

  test "numeric context failures enforce scope, threshold and hard-limit relations" do
    failure = %{
      "version" => 2,
      "category" => "context_budget_exceeded",
      "retryable" => false,
      "measurement_scope" => "maintenance",
      "dimension" => "system_class_tokens",
      "observed" => 1000,
      "limit" => 1000,
      "hard_limit" => 1000
    }

    native = result("failed", nil, failure, "confirmed", 3)
    assert {:ok, _} = CompactResult.encode_wire(native)

    for changes <- [
          %{"observed" => 999},
          %{"dimension" => "context_tokens"},
          %{"hard_limit" => 1001},
          %{"measurement_scope" => nil},
          %{"observed" => 18_446_744_073_709_551_616},
          %{"limit" => 0}
        ] do
      assert CompactResult.encode_wire(%{native | "failure" => Map.merge(failure, changes)}) ==
               :error
    end

    headroom = %{
      failure
      | "category" => "thinking_exchange_headroom",
        "dimension" => "context_tokens",
        "observed" => 101,
        "limit" => 100,
        "hard_limit" => 1000
    }

    assert {:ok, _} = CompactResult.encode_wire(%{native | "failure" => headroom})

    for changes <- [
          %{"dimension" => "system_class_tokens"},
          %{"observed" => 100},
          %{"hard_limit" => 99}
        ] do
      assert CompactResult.encode_wire(%{native | "failure" => Map.merge(headroom, changes)}) ==
               :error
    end
  end

  test "standalone bound failures exclude parent turns and preserve reserved-token observations" do
    failure = %{
      "category" => "bound_reached",
      "retryable" => false,
      "bound" => "token_budget",
      "observed" => 3,
      "declared_limit" => Integer.pow(2, 100),
      "accounting_source" => "reported"
    }

    native = result("failed", nil, failure, "confirmed", 3)
    assert {:ok, _} = CompactResult.encode_wire(native)

    for changes <- [
          %{"bound" => "max_turns"},
          %{"bound" => "deadline_ms"},
          %{"bound" => "max_attempts"},
          %{"declared_limit" => 0}
        ] do
      assert CompactResult.encode_wire(%{native | "failure" => Map.merge(failure, changes)}) ==
               :error
    end
  end

  defp result(disposition, checkpoint, failure, cleanup, reported) do
    %{
      "disposition" => disposition,
      "checkpoint_id" => checkpoint,
      "failure" => failure,
      "cleanup" => cleanup,
      "usage" => %{
        "attempts" => 2,
        "reported_tokens" => reported,
        "estimated_tokens" => 7,
        "total_tokens" => reported + 7
      }
    }
  end

  defp failures do
    [
      %{"category" => "model_call_failed", "retryable" => false},
      %{"category" => "cancelled", "retryable" => false},
      %{
        "category" => "bound_reached",
        "retryable" => false,
        "bound" => "max_attempts",
        "observed" => 4,
        "declared_limit" => 4,
        "accounting_source" => nil
      },
      %{
        "category" => "bound_reached",
        "retryable" => false,
        "bound" => "deadline_ms",
        "observed" => 18_446_744_073_709_551_615,
        "declared_limit" => 1,
        "accounting_source" => nil
      },
      %{
        "version" => 2,
        "category" => "context_preparation_failed",
        "retryable" => false,
        "measurement_scope" => nil,
        "cause" => "maintenance_model_unconfigured"
      },
      %{
        "version" => 2,
        "category" => "context_preparation_failed",
        "retryable" => false,
        "measurement_scope" => "ordinary",
        "cause" => "compaction_no_progress"
      }
    ]
  end

  defp retained(value) when is_map(value) do
    Map.new(value, fn
      {"checkpoint_id", nil} ->
        {"checkpoint_id", nil}

      {"checkpoint_id", bytes} ->
        {"checkpoint_id", %{"opaque_hex" => Base.encode16(bytes, case: :lower)}}

      {"version", version} ->
        {"version", version}

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
