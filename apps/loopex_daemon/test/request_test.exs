defmodule LoopexDaemon.RequestTest do
  use ExUnit.Case, async: true

  alias LoopexDaemon.Request
  alias LoopexProtocol.{Session.V2, Wire}

  @digest String.duplicate("a", 64)

  test "every generation-two method has one exact decoded request shape" do
    examples = examples()
    assert Enum.sort(Map.keys(examples)) == Enum.sort(V2.methods())

    parsed =
      Map.new(examples, fn {method, request} ->
        assert {:ok, %Request{} = parsed} = Request.parse(request)
        assert parsed.method == method
        assert parsed.request_id == "request-1"
        {method, parsed}
      end)

    assert parsed["session.create"].fields == %{
             command_id: "create-command",
             session_options: %{"mode" => "test"}
           }

    assert parsed["session.attach"].fields == %{
             session_id: "session",
             after_event_sequence: nil,
             replace: false
           }

    assert parsed["session.prompt"].fields.content == <<0, 255>>
    assert parsed["session.admit_resources"].fields.decision == nil
    assert parsed["session.activate_skill"].fields.supporting_labels == []

    assert parsed["artifact.open_transfer"].fields == %{
             reference: %{
               digest: @digest,
               size: 9,
               locator: "artifact",
               use_locator: "use:" <> @digest
             },
             start_offset: 0,
             window_length: nil
           }

    assert parsed["session.list"].fields == %{limit: 1, after_session_id: nil}
    assert parsed["daemon.status"].fields == %{}

    operations = parsed |> Map.values() |> Enum.map(& &1.operation)
    assert length(Enum.uniq(operations)) == length(V2.methods())
  end

  test "every outer shape refuses missing required and unknown fields" do
    for {_method, request} <- examples() do
      assert {:error, :invalid_request} = Request.parse(Map.delete(request, "request_id"))
      assert {:error, :invalid_request} = Request.parse(Map.put(request, "extra", true))

      for field <- Map.keys(request) -- ["method", "request_id"] do
        assert {:error, :invalid_request} = Request.parse(Map.delete(request, field))
      end
    end

    assert {:error, :unsupported_method} =
             Request.parse(%{"method" => "session.teleport", "request_id" => "request-1"})

    assert {:error, :invalid_request} =
             Request.parse(%{"method" => "session.teleport", "request_id" => "has space"})

    assert {:error, :invalid_request} = Request.parse(%URI{})
    assert {:error, :invalid_request} = Request.parse(:not_a_request)
  end

  test "optional fields distinguish absence from null" do
    attach =
      examples()["session.attach"]
      |> Map.put("after_event_sequence", "18446744073709551615")
      |> Map.put("replace", true)

    assert {:ok, parsed} = Request.parse(attach)
    assert parsed.fields.after_event_sequence == 18_446_744_073_709_551_615
    assert parsed.fields.replace

    open = Map.put(examples()["artifact.open_transfer"], "window_length", "0")
    assert {:ok, parsed} = Request.parse(open)
    assert parsed.fields.window_length == 0

    list = Map.put(examples()["session.list"], "after_session_id", identity("after"))
    assert {:ok, parsed} = Request.parse(list)
    assert parsed.fields.after_session_id == "after"

    for {request, field} <- [
          {examples()["session.attach"], "after_event_sequence"},
          {examples()["session.attach"], "replace"},
          {examples()["artifact.open_transfer"], "window_length"},
          {examples()["session.list"], "after_session_id"}
        ] do
      assert {:error, :invalid_request} = Request.parse(Map.put(request, field, nil))
    end
  end

  test "identity byte ceilings and canonical encodings are enforced" do
    assert {:ok, parsed} =
             examples()["session.resume"]
             |> Map.put("session_id", identity(String.duplicate("s", 256)))
             |> Map.put("command_id", identity(String.duplicate("c", 256)))
             |> Map.put("writer_epoch", identity(String.duplicate("e", 64)))
             |> Request.parse()

    assert byte_size(parsed.fields.session_id) == 256
    assert byte_size(parsed.fields.command_id) == 256
    assert byte_size(parsed.fields.writer_epoch) == 64

    for {field, bytes} <- [
          {"session_id", String.duplicate("s", 257)},
          {"command_id", String.duplicate("c", 257)},
          {"writer_epoch", String.duplicate("e", 65)}
        ] do
      request = Map.put(examples()["session.resume"], field, identity(bytes))
      assert {:error, :invalid_request} = Request.parse(request)
    end

    for malformed <- ["", "=", "YQ==", "not+base64"] do
      request = Map.put(examples()["session.inspect"], "session_id", malformed)
      assert {:error, :invalid_request} = Request.parse(request)
    end

    assert {:ok, _parsed} =
             examples()["session.prompt"]
             |> Map.put("command_id", identity(String.duplicate("c", 65_536)))
             |> Request.parse()

    assert {:error, :invalid_request} =
             examples()["session.prompt"]
             |> Map.put("command_id", identity(String.duplicate("c", 65_537)))
             |> Request.parse()
  end

  test "content, numeric and nested plain-data boundaries refuse repair" do
    prompt = examples()["session.prompt"]
    assert {:error, :invalid_request} = Request.parse(Map.put(prompt, "content_b64", ""))
    assert {:error, :invalid_request} = Request.parse(Map.put(prompt, "content_b64", "YQ=="))

    for length <- [0, 32_769, 1.0, "1", nil] do
      request = Map.put(examples()["artifact.read_chunk"], "length", length)
      assert {:error, :invalid_request} = Request.parse(request)
    end

    for limit <- [0, 257, 1.0, "1", nil] do
      request = Map.put(examples()["session.list"], "limit", limit)
      assert {:error, :invalid_request} = Request.parse(request)
    end

    assert {:ok, _parsed} = Request.parse(Map.put(examples()["session.list"], "limit", 256))

    for options <- [
          %{"pid" => self()},
          %{"tuple" => {:runtime, :term}},
          %{:atom_key => "value"},
          %{"integer" => 9_007_199_254_740_992},
          %{"float" => 1.0},
          %{"deep" => nested_maps(16)}
        ] do
      request = Map.put(examples()["session.create"], "session_options", options)
      assert {:error, :invalid_request} = Request.parse(request)
    end

    assert {:ok, _parsed} =
             examples()["session.create"]
             |> Map.put("session_options", %{"deep" => nested_maps(15)})
             |> Request.parse()
  end

  test "resource requests apply the exact M3 validators" do
    decision = %{
      "manifest_digest" => @digest,
      "workspace_ref" => "workspace",
      "trust_scope" => "project_skills",
      "decision_source" => "host_supplied",
      "issued_at" => "2026-09-22T00:00:00Z",
      "expires_at" => nil,
      "revocation_state" => "active"
    }

    assert {:ok, parsed} =
             examples()["session.admit_resources"]
             |> Map.put("decision", decision)
             |> Request.parse()

    assert parsed.fields.decision == decision

    for invalid <- [
          Map.put(decision, "extra", true),
          Map.delete(decision, "workspace_ref"),
          Map.put(decision, "expires_at", "later"),
          Map.put(decision, "trust_scope", "all")
        ] do
      request = Map.put(examples()["session.admit_resources"], "decision", invalid)
      assert {:error, :invalid_request} = Request.parse(request)
    end

    activate = examples()["session.activate_skill"]

    for invalid_name <- ["", "UPPER", "two--parts", String.duplicate("a", 65)] do
      assert {:error, :invalid_request} =
               activate |> Map.put("name", invalid_name) |> Request.parse()
    end

    for labels <- [
          ["duplicate", "duplicate"],
          Enum.map(1..9, &"label-#{&1}"),
          ["line\nbreak"],
          [String.duplicate("x", 1_025)]
        ] do
      assert {:error, :invalid_request} =
               activate |> Map.put("supporting_labels", labels) |> Request.parse()
    end

    read = examples()["resources.read"]

    for value <- ["", "line\nbreak", String.duplicate("x", 1_025)] do
      assert {:error, :invalid_request} =
               read |> Map.put("label", value) |> Request.parse()
    end
  end

  test "writer epochs are required only on the nine lease-authorized methods" do
    authorized =
      MapSet.new([
        "session.resume",
        "session.prompt",
        "session.steer",
        "session.follow_up",
        "session.abort",
        "session.respond_interaction",
        "session.admit_resources",
        "session.activate_skill",
        "session.release_control"
      ])

    for {method, request} <- examples() do
      if MapSet.member?(authorized, method) do
        assert {:error, :invalid_request} = Request.parse(Map.delete(request, "writer_epoch"))
      else
        assert {:error, :invalid_request} =
                 Request.parse(Map.put(request, "writer_epoch", identity("epoch")))
      end
    end
  end

  defp examples do
    session_id = identity("session")
    writer_epoch = identity("epoch")
    command_id = identity("command")

    %{
      "session.create" =>
        request("session.create", %{
          "command_id" => identity("create-command"),
          "session_options" => %{"mode" => "test"}
        }),
      "session.resume" =>
        request("session.resume", %{
          "session_id" => session_id,
          "command_id" => identity("resume-command"),
          "writer_epoch" => writer_epoch
        }),
      "session.inspect" => request("session.inspect", %{"session_id" => session_id}),
      "session.attach" => request("session.attach", %{"session_id" => session_id}),
      "session.prompt" =>
        request("session.prompt", %{
          "command_id" => command_id,
          "content_b64" => Wire.encode_bytes(<<0, 255>>),
          "writer_epoch" => writer_epoch
        }),
      "session.steer" =>
        request("session.steer", %{
          "command_id" => command_id,
          "run_id" => identity("run"),
          "content_b64" => Wire.encode_bytes("steer"),
          "writer_epoch" => writer_epoch
        }),
      "session.follow_up" =>
        request("session.follow_up", %{
          "command_id" => command_id,
          "content_b64" => Wire.encode_bytes("follow"),
          "writer_epoch" => writer_epoch
        }),
      "session.abort" =>
        request("session.abort", %{
          "command_id" => command_id,
          "writer_epoch" => writer_epoch
        }),
      "session.respond_interaction" =>
        request("session.respond_interaction", %{
          "command_id" => command_id,
          "interaction_id" => identity("interaction"),
          "answer" => %{"choice_id" => identity("choice")},
          "writer_epoch" => writer_epoch
        }),
      "resources.catalog" => request("resources.catalog", %{"session_id" => session_id}),
      "resources.read" =>
        request("resources.read", %{
          "session_id" => session_id,
          "manifest_digest" => "manifest",
          "source_id" => "source",
          "name" => "skill-name",
          "label" => "SKILL.md"
        }),
      "session.admit_resources" =>
        request("session.admit_resources", %{
          "command_id" => command_id,
          "manifest_digest" => @digest,
          "decision" => nil,
          "writer_epoch" => writer_epoch
        }),
      "session.activate_skill" =>
        request("session.activate_skill", %{
          "command_id" => command_id,
          "manifest_digest" => @digest,
          "pack_digest" => @digest,
          "source_id" => "source",
          "name" => "skill-name",
          "supporting_labels" => [],
          "writer_epoch" => writer_epoch
        }),
      "artifact.open_transfer" =>
        request("artifact.open_transfer", %{
          "use_ref" => artifact_reference(),
          "start_offset" => "0"
        }),
      "artifact.read_chunk" =>
        request("artifact.read_chunk", %{
          "transfer_ref" => identity("transfer"),
          "length" => 1
        }),
      "artifact.close_transfer" =>
        request("artifact.close_transfer", %{"transfer_ref" => identity("transfer")}),
      "session.list" => request("session.list", %{"limit" => 1}),
      "daemon.status" => request("daemon.status", %{}),
      "session.acquire_control" =>
        request("session.acquire_control", %{"session_id" => session_id}),
      "session.release_control" =>
        request("session.release_control", %{
          "session_id" => session_id,
          "writer_epoch" => writer_epoch
        })
    }
  end

  defp request(method, fields),
    do: Map.merge(%{"method" => method, "request_id" => "request-1"}, fields)

  defp identity(bytes), do: Wire.encode_identity(bytes)

  defp artifact_reference do
    Wire.encode_reference(%{
      digest: @digest,
      size: 9,
      locator: "artifact",
      use_locator: "use:" <> @digest
    })
  end

  defp nested_maps(0), do: "leaf"
  defp nested_maps(depth), do: %{"next" => nested_maps(depth - 1)}
end
