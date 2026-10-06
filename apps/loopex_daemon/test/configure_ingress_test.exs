defmodule LoopexDaemon.ConfigureIngressTest do
  use ExUnit.Case, async: true

  alias LoopexDaemon.Request, as: Adapter
  alias LoopexProtocol.{Frame, Session.ConfigureRequest}

  test "all admitted literal daemon requests preserve exact native authored values and capture instructions" do
    for vector <- vectors()["cases"], vector["transport"] == "daemon", vector["error"] != true do
      request = vector["input"]
      assert {:ok, decoded} = ConfigureRequest.decode_wire(request, :daemon)
      assert {:ok, prepared} = Adapter.prepare_configuration_request(request)

      expected =
        if Map.has_key?(decoded.changes, "instructions") do
          assert {:ok, captured} =
                   Loopex.Runtime.Instructions.capture(decoded.changes["instructions"])

          Map.put(decoded.changes, "instructions", captured)
        else
          decoded.changes
        end

      assert prepared == %{decoded | changes: expected}, vector["name"]
      assert Loopex.Runtime.SessionConfiguration.validate_update(prepared.changes) == :ok
    end
  end

  test "instruction capture retains authored aliases bytes and deterministic rendered digest" do
    request = request()
    assert {:ok, prepared} = Adapter.prepare_configuration_request(request)
    raw = request["changes"]["instructions"]
    captured = prepared.changes["instructions"]
    assert Map.delete(captured, "digest") == raw

    assert captured["digest"] ==
             "40e32aaecf50de1888225a4e98670fdb54619568cd07308b0f1395903da183e4"

    rendered =
      raw["version"] <>
        ": " <>
        Enum.join(
          Enum.reject([raw["base"], raw["environment"], raw["appendix"]], &(&1 == "")),
          "\n\n"
        )

    assert captured["digest"] == :crypto.hash(:sha256, rendered) |> Base.encode16(case: :lower)
    assert prepared.changes["model"] == " alias/model "
    assert prepared.changes["max_tokens"] == 9_007_199_254_740_993
    assert prepared.changes["context_token_budget"] == 18_446_744_073_709_551_615
    assert prepared.command_id == <<0, 255, 1, 128>>
    assert prepared.writer_epoch == <<255, 0, 42>>
  end

  test "all refused transport vectors and private instruction facts refuse before native preparation" do
    for vector <- vectors()["cases"], vector["transport"] == "daemon", vector["error"] do
      assert Adapter.prepare_configuration_request(vector["input"]) == {:error, :invalid_request},
             vector["name"]
    end

    request = request()

    for key <- ~w(digest file metadata authority) do
      invalid = update_in(request, ["changes", "instructions"], &Map.put(&1, key, "private"))
      assert Adapter.prepare_configuration_request(invalid) == {:error, :invalid_request}
    end
  end

  test "native whole-update limit remains effective after valid field decoding" do
    request =
      Map.put(request(), "changes", %{
        "model" => String.duplicate("m", Loopex.Store.max_item_bytes())
      })

    assert {:ok, decoded} = ConfigureRequest.decode_wire(request, :daemon)
    assert decoded.changes["model"] == request["changes"]["model"]
    assert {:error, {:item_too_large, _, _}} = Loopex.Store.admit_bounded(decoded.changes)
    assert Adapter.prepare_configuration_request(request) == {:error, :invalid_request}
  end

  test "duplicate-aware Frame and served generation stay unchanged by this prerequisite" do
    for vector <- vectors()["frame_cases"] do
      assert Frame.decode(vector["json"], 2_097_152) == {:error, :duplicate_member}
    end

    assert Adapter.parse(request()) == {:error, :unsupported_method}
  end

  defp request do
    Enum.find(vectors()["cases"], &(&1["name"] == "daemon-subset-63"))["input"]
  end

  defp vectors do
    JSON.decode!(
      File.read!(Path.join(:code.priv_dir(:loopex_protocol), "vectors/configure-request.v1.json"))
    )
  end
end
