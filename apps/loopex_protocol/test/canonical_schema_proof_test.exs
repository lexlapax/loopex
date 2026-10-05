defmodule LoopexProtocol.CanonicalSchemaProofTest do
  @moduledoc """
  ## Concept

  Literal canonical bytes let an independent client reproduce schema digests
  without importing the server encoder.

  ## Technical depth

  These fixtures cover the JSON subset of loopex.canonical.v1, including encoded
  binary-key order, signed integer boundaries and the byte-list optimization.
  Approved payload schemas are pinned individually. Complete /3 and /4
  manifests and the transport generation switch remain separate work.
  """

  use ExUnit.Case, async: true

  alias LoopexProtocol.Canonical
  alias LoopexProtocol.Frame

  @priv Path.expand("../priv", __DIR__)
  @fixture @priv
           |> Path.join("vectors/canonical-schema-proof.v1.json")
           |> File.read!()
           |> JSON.decode!()

  test "literal schema values retain exact canonical preimages and digests" do
    assert @fixture["format"] == "loopex.canonical.schema-proof.v1"
    assert @fixture["canonicalization_revision"] == Canonical.version()

    for vector <- @fixture["cases"] do
      assert Base.encode16(Canonical.encode(vector["input"]), case: :lower) ==
               vector["canonical_hex"]

      assert Canonical.digest(vector["input"]) == vector["sha256"]
    end
  end

  test "every approved payload has its own literal canonical identity" do
    for vector <- @fixture["payloads"] do
      bytes = File.read!(Path.join([@priv, "schema", vector["schema"]]))
      assert {:ok, payload} = Frame.decode(String.trim(bytes), 1_048_576)
      assert byte_size(Canonical.encode(payload)) == vector["canonical_bytes"]
      assert Canonical.digest(payload) == vector["canonical_sha256"]
    end
  end

  test "embedded definitions affect an enclosing identity while map insertion order does not" do
    proof = %{
      "canonicalization_revision" => Canonical.version(),
      "payload_definitions" => %{"answer" => %{"text" => %{"maximum_bytes" => 8192}}}
    }

    changed = put_in(proof, ["payload_definitions", "answer", "text", "maximum_bytes"], 8193)
    refute Canonical.digest(proof) == Canonical.digest(changed)
    refute Canonical.digest(["a", "b"]) == Canonical.digest(["b", "a"])

    assert Canonical.digest(%{"z" => 1, "aa" => 2}) ==
             Canonical.digest(Map.new([{"aa", 2}, {"z", 1}]))
  end

  @tag :node_client
  test "the independent client checks canonical preimages and all embedded payload leaves" do
    node =
      System.find_executable("node") || flunk("Node is required for schema digest conformance")

    root = Path.expand("../../..", __DIR__)
    runner = Path.join(root, "clients/node/contract-manifest-vectors.mjs")
    vectors = Path.join(@priv, "vectors/canonical-schema-proof.v1.json")
    {output, status} = System.cmd(node, [runner, vectors], stderr_to_stdout: true)
    assert status == 0, output

    assert {:ok,
            %{
              "canonical_cases" => 21,
              "approved_payloads" => 11,
              "embedded_leaf_mutations" => 1307,
              "rejected_json" => 13,
              "identity_checks" => 6
            }} = Frame.decode(String.trim_trailing(output, "\n"), 65_536)
  end
end
