defmodule LoopexDaemon.RequestTest do
  use ExUnit.Case, async: true

  alias LoopexDaemon.Request
  alias LoopexProtocol.{Session.V2, Wire}

  @digest String.duplicate("a", 64)

  test "configure preparation preserves raw instruction bytes before ordinary admission" do
    raw = %{
      "version" => "wire.v1",
      "base" => "exact wire bytes 猫\n",
      "environment" => "",
      "appendix" => "tail"
    }

    authored = %{"model" => "host-alias", "instructions" => raw, "max_tokens" => 512}
    assert {:ok, captured} = LoopexDaemon.Request.capture_configuration_changes(authored)
    assert {:ok, instructions} = Loopex.Runtime.Instructions.capture(raw)
    assert captured == %{authored | "instructions" => instructions}
    assert Map.take(captured["instructions"], ~w(version base environment appendix)) == raw

    assert {:ok, %{"model" => "host-alias"}} =
             LoopexDaemon.Request.capture_configuration_changes(%{"model" => "host-alias"})

    for invalid <- [
          Map.put(authored, "model_capabilities", %{}),
          %{authored | "instructions" => Map.put(raw, "digest", String.duplicate("a", 64))},
          %{authored | "instructions" => Map.put(raw, "file", "unread-path")},
          %{authored | "instructions" => %{raw | "base" => <<255>>}},
          %{}
        ] do
      assert {:error, :invalid_session_configuration} =
               LoopexDaemon.Request.capture_configuration_changes(invalid)
    end

    wire =
      request("session.configure", %{
        "command_id" => identity("configure"),
        "writer_epoch" => identity("epoch"),
        "changes" => Map.put(authored, "max_tokens", "512")
      })

    assert {:ok, parsed} = Request.parse(wire)
    assert parsed.operation == :session_configure
    assert parsed.fields == %{command_id: "configure", writer_epoch: "epoch", changes: captured}
  end

  test "every current daemon method has one exact decoded request shape" do
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
             session_options: %{"version" => 1}
           }

    assert parsed["session.attach"].fields == %{
             session_id: "session",
             after_event_sequence: nil,
             replace: false
           }

    assert parsed["session.configure"].fields == %{
             command_id: "command", writer_epoch: "epoch", changes: %{"model" => "host-alias"}
           }

    assert parsed["session.compact"].fields == %{
             command_id: "command", writer_epoch: "epoch",
             bounds: %{"max_attempts" => 4, "deadline_ms" => 60_000, "token_budget" => 32_768}
           }

    assert parsed["session.respond_interaction"].fields == %{
             command_id: "command", interaction_id: "interaction",
             answer: %{"choice_id" => "choice"}, writer_epoch: "epoch"
           }

    assert parsed["session.prompt"].fields.content == <<0, 255>>
    assert parsed["session.admit_resources"].fields.decision == nil
    assert parsed["session.activate_skill"].fields.supporting_labels == []

    assert parsed["artifact.open_transfer"].fields == %{
             use_locator: "use:" <> @digest,
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
          %{},
          %{"version" => 1, "private" => "CREATION_CANARY"},
          %{"version" => 1, "tools" => [self()]},
          %{"version" => 1, "configuration" => %{"model" => fn -> :private end}},
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
             |> Map.put("session_options", %{"version" => 1, "tools" => []})
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

  test "writer epochs are required only on the eleven lease-authorized methods" do
    authorized =
      MapSet.new([
        "session.resume",
        "session.configure",
        "session.compact",
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

  test "daemon configure envelopes preserve every authored subset and refuse malformed vectors" do
    for vector <- vectors("configure-request.v1.json")["cases"], vector["transport"] == "daemon" do
      if vector["error"] do
        assert {:error, :invalid_request} = Request.parse(vector["input"]), vector["name"]
      else
        assert {:ok, parsed} = Request.parse(vector["input"]), vector["name"]
        assert parsed.operation == :session_configure
        assert parsed.request_id == vector["decoded"]["request_id"]

        changes = parsed.fields.changes

        changes =
          if Map.has_key?(changes, "instructions") do
            instructions = changes["instructions"]
            assert :ok = Loopex.Runtime.Instructions.validate(instructions)

            assert Map.take(instructions, ~w(version base environment appendix)) ==
                     vector["input"]["changes"]["instructions"]

            Map.put(changes, "instructions", Map.delete(instructions, "digest"))
          else
            changes
          end

        assert retained(%{parsed.fields | changes: changes}) ==
                 Map.delete(vector["decoded"], "request_id"), vector["name"]
      end
    end
  end

  test "current command envelopes apply every accepted bounds vector without defaults" do
    for vector <- vectors("command-bounds.v1.json")["cases"],
        vector["kind"] in ~w(prompt follow_up compact) do
      method = "session." <> vector["kind"]
      input = Map.put(examples()[method], "bounds", vector["input"])

      if vector["error"] do
        assert {:error, :invalid_request} = Request.parse(input), vector["name"]
      else
        assert {:ok, parsed} = Request.parse(input), vector["name"]
        assert retained(parsed.fields.bounds) == vector["decoded"], vector["name"]
        assert parsed.fields.command_id == "command"
        assert parsed.fields.writer_epoch == "epoch"
      end
    end
  end

  test "prompt and follow-up retain omitted empty and partial bounds across request retries" do
    for vector <- vectors("command-bounds.v1.json")["enclosing_request_cases"] do
      method = "session." <> vector["kind"]
      input = Map.merge(examples()[method], vector["request"])
      assert {:ok, parsed} = Request.parse(input)
      assert Map.has_key?(parsed.fields, :bounds) == Map.has_key?(vector["expected"], "bounds")

      if Map.has_key?(parsed.fields, :bounds) do
        assert retained(parsed.fields.bounds) == vector["expected"]["bounds"]
      end

      assert {:ok, retried} = Request.parse(Map.put(input, "request_id", "retry"))
      assert retried.fields == parsed.fields
    end

    prompt = examples()["session.prompt"]
    assert {:ok, omitted} = Request.parse(prompt)
    assert {:ok, empty} = Request.parse(Map.put(prompt, "bounds", %{}))
    assert omitted.fields != empty.fields
    assert omitted.fields.command_id == empty.fields.command_id

    for method <- ~w(session.prompt session.follow_up) do
      assert {:error, :invalid_request} = Request.parse(Map.put(examples()[method], "bounds", nil))
    end

    assert {:error, :invalid_request} =
             Request.parse(Map.put(examples()["session.steer"], "bounds", %{}))
  end

  test "answer envelopes preserve exactly one choice text or declined branch" do
    base = examples()["session.respond_interaction"]

    for vector <- vectors("question-answer.v1.json")["cases"] do
      input = Map.put(base, "answer", vector["input"])

      if vector["error"] do
        assert {:error, :invalid_request} = Request.parse(input), vector["name"]
      else
        assert {:ok, parsed} = Request.parse(input), vector["name"]
        assert parsed.operation == :session_respond_interaction
        assert parsed.fields.command_id == "command"
        assert parsed.fields.interaction_id == "interaction"
        assert parsed.fields.writer_epoch == "epoch"
        refute Map.has_key?(parsed.fields, :choice_id)

        if Map.has_key?(vector, "decoded_choice_hex") do
          assert parsed.fields.answer == %{
                   "choice_id" => Base.decode16!(vector["decoded_choice_hex"], case: :lower)
                 }
        else
          assert parsed.fields.answer == vector["decoded"]
        end
      end
    end

    for authority <- ["producer", "kind", "permit", "policy_decision"] do
      assert {:error, :invalid_request} = Request.parse(Map.put(base, authority, "allow"))
    end
  end

  test "creation envelopes apply closed version-one options and preserve authored presence" do
    base = examples()["session.create"]

    for vector <- vectors("creation-options.v1.json")["cases"] do
      input = Map.put(base, "session_options", vector["input"])

      if vector["error"] do
        assert {:error, :invalid_request} = Request.parse(input), vector["name"]
      else
        assert {:ok, parsed} = Request.parse(input), vector["name"]
        assert parsed.operation == :session_create
        assert parsed.fields.command_id == "create-command"
        assert retained(parsed.fields.session_options) == vector["decoded"], vector["name"]
        assert Map.keys(parsed.fields.session_options) |> Enum.sort() ==
                 Map.keys(vector["input"]) |> Enum.sort()
      end
    end
  end

  test "new mutation routes retain full command identity and bounded writer authority" do
    for method <- ~w(session.configure session.compact) do
      command = :binary.copy(<<0, 255>>, 32_768)
      epoch = :binary.copy(<<255>>, 64)

      input =
        examples()[method]
        |> Map.put("command_id", identity(command))
        |> Map.put("writer_epoch", identity(epoch))

      assert {:ok, parsed} = Request.parse(input)
      assert parsed.fields.command_id == command
      assert parsed.fields.writer_epoch == epoch

      for {field, value} <- [
            {"command_id", identity(command <> "x")},
            {"writer_epoch", identity(epoch <> "x")},
            {"writer_epoch", nil},
            {"writer_epoch", ""},
            {"writer_epoch", "ZXBvY2g="}
          ] do
        assert {:error, :invalid_request} = Request.parse(Map.put(input, field, value))
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
          "session_options" => %{"version" => 1}
        }),
      "session.resume" =>
        request("session.resume", %{
          "session_id" => session_id,
          "command_id" => identity("resume-command"),
          "writer_epoch" => writer_epoch
        }),
      "session.inspect" => request("session.inspect", %{"session_id" => session_id}),
      "session.attach" => request("session.attach", %{"session_id" => session_id}),
      "session.configure" =>
        request("session.configure", %{
          "command_id" => command_id,
          "changes" => %{"model" => "host-alias"},
          "writer_epoch" => writer_epoch
        }),
      "session.compact" =>
        request("session.compact", %{
          "command_id" => command_id,
          "bounds" => %{"max_attempts" => "4", "deadline_ms" => "60000", "token_budget" => "32768"},
          "writer_epoch" => writer_epoch
        }),
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

  test "artifact open admits the literal only and preserves authored windows" do
    valid = request("artifact.open_transfer", %{"use_ref" => "use:" <> @digest,
      "start_offset" => "0", "window_length" => "0"})
    assert {:ok, parsed} = Request.parse(valid)
    assert parsed.fields == %{use_locator: "use:" <> @digest, start_offset: 0, window_length: 0}
    old_envelope = Wire.encode_bytes(JSON.encode!(%{"digest" => @digest,
      "size" => "9", "locator" => "artifact", "use_locator" => "use:" <> @digest}))
    for locator <- [old_envelope, "use:", "use:" <> String.upcase(@digest),
      "use:" <> String.duplicate("g", 64), "use:" <> @digest <> "a", nil, 7] do
      assert {:error, :invalid_request} = Request.parse(Map.put(valid, "use_ref", locator))
    end
    for offset <- [nil, 0, "00", "-1", "18446744073709551616"] do
      assert {:error, :invalid_request} = Request.parse(Map.put(valid, "start_offset", offset))
    end
  end

  defp request(method, fields),
    do: Map.merge(%{"method" => method, "request_id" => "request-1"}, fields)

  defp identity(bytes), do: Wire.encode_identity(bytes)

  defp artifact_reference, do: "use:" <> @digest

  defp nested_maps(0), do: "leaf"
  defp nested_maps(depth), do: %{"next" => nested_maps(depth - 1)}

  defp vectors(file) do
    :loopex_protocol
    |> Application.app_dir("priv/vectors/" <> file)
    |> File.read!()
    |> JSON.decode!()
  end

  defp retained(value, key \\ nil)

  defp retained(value, _key) when is_map(value),
    do: Map.new(value, fn {key, member} -> {to_string(key), retained(member, to_string(key))} end)

  defp retained(value, _key) when is_list(value), do: Enum.map(value, &retained/1)

  defp retained(value, key) when is_binary(value) and key in ~w(command_id writer_epoch),
    do: %{"opaque_hex" => Base.encode16(value, case: :lower)}

  defp retained(value, key)
       when is_integer(value) and key in ~w(max_tokens context_token_budget system_class_tokens max_turns max_attempts token_budget deadline_ms),
       do: Integer.to_string(value)

  defp retained(value, _key), do: value
end
