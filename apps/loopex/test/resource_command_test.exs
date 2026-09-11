Code.require_file("support/m1_runtime_helper.exs", __DIR__)
Code.require_file("support/agent_loop_helper.exs", __DIR__)

defmodule Loopex.ResourceCommandTest do
  use ExUnit.Case, async: false

  alias Loopex.AgentLoopFixture, as: Fixture
  alias Loopex.ResourcePack
  alias Loopex.Runtime.SessionState
  alias LoopexProtocol.Canonical

  setup do
    files =
      for {label, content} <- [
            {"SKILL.md", "Use the project guide."},
            {"guide.txt", "Guide bytes."}
          ] do
        %{
          label: label,
          content: content,
          size: byte_size(content),
          digest: Canonical.digest_bytes(content),
          contained: true
        }
      end

    manifest = %{
      version: "loopex.resource_pack/1",
      workspace_ref: "workspace-ref",
      revision: nil,
      packs: [
        %{
          source_id: "project",
          origin: nil,
          commit: nil,
          tree_digest: nil,
          name: "guide",
          description: "A project guide",
          manual_only: true,
          files: files
        }
      ]
    }

    {:ok, digest, normalized} = ResourcePack.digest(manifest)
    fixture = Fixture.start(script: [], resource_manifest: manifest)
    on_exit(fn -> Fixture.stop(fixture) end)
    {:ok, session} = Loopex.create_session(fixture.runtime, %{}, command_id: "create")
    {:ok, attachment} = Loopex.attach(fixture.runtime, session, after_event_sequence: 0)

    decision = %{
      manifest_digest: digest,
      workspace_ref: "workspace-ref",
      trust_scope: "project_skills",
      decision_source: "host_supplied",
      issued_at: "2026-09-10T00:00:00Z",
      expires_at: nil,
      revocation_state: "active"
    }

    admit = %{
      type: :admit_resources,
      command_id: "admit",
      manifest_digest: digest,
      decision: decision
    }

    activate = %{
      type: :activate_skill,
      command_id: "select",
      manifest_digest: digest,
      source_id: "project",
      name: "guide",
      pack_digest: ResourcePack.pack_digest(hd(normalized["packs"])),
      supporting_labels: ["guide.txt"]
    }

    %{
      fixture: fixture,
      session: session,
      attachment: attachment,
      admit: admit,
      activate: activate,
      digest: digest
    }
  end

  test "admission and selection are durable commands and inspection does not select", context do
    %{fixture: fixture, session: session, attachment: attachment, digest: digest} = context

    assert {:ok, %{"entries" => [], "decision_disposition" => "no_decision"}} =
             Loopex.resource_catalog(fixture.runtime, session)

    assert {:accepted, "admit"} = Loopex.command(attachment, context.admit)

    assert {:ok, %{"admitted_manifest_digest" => ^digest, "entries" => [entry]}} =
             Loopex.resource_catalog(fixture.runtime, session)

    assert entry["name"] == "guide"

    assert {:ok, %{"content" => "Guide bytes."}} =
             Loopex.read_resource(fixture.runtime, session, %{
               manifest_digest: digest,
               source_id: "project",
               name: "guide",
               label: "guide.txt"
             })

    assert {:accepted, "select"} = Loopex.command(attachment, context.activate)
    rows = Fixture.records(fixture, session)
    assert Enum.count(rows, &(&1.payload.kind == "resource_command_v1")) == 2
    assert {:ok, durable} = SessionState.recover(session, rows, Fixture.events(fixture, session))
    assert [%{"pack_index" => 0, "supporting_files" => [file]}] = durable.resources["selections"]
    assert file["digest"] == Canonical.digest_bytes("Guide bytes.")
    assert Loopex.AgentLoopTestModel.dispatched(fixture.model) == []
  end

  test "exact repetition does not reset selection and changed labels conflict", context do
    assert {:accepted, "admit"} = Loopex.command(context.attachment, context.admit)
    assert {:accepted, "select"} = Loopex.command(context.attachment, context.activate)
    before = Fixture.records(context.fixture, context.session)
    assert {:accepted, "admit"} = Loopex.command(context.attachment, context.admit)
    assert {:accepted, "select"} = Loopex.command(context.attachment, context.activate)

    assert {:error, :idempotency_conflict} =
             Loopex.command(context.attachment, %{context.activate | supporting_labels: []})

    assert Fixture.records(context.fixture, context.session) == before
  end

  test "state dependent refusals are retained and malformed alias input is not", context do
    assert {:error, :resource_not_admitted} = Loopex.command(context.attachment, context.activate)
    before = Fixture.records(context.fixture, context.session)

    assert {:error, :invalid_command} =
             Loopex.command(context.attachment, Map.put(context.admit, "decision", nil))

    assert Fixture.records(context.fixture, context.session) == before
    assert {:accepted, "admit"} = Loopex.command(context.attachment, context.admit)
    assert {:error, :resource_not_admitted} = Loopex.command(context.attachment, context.activate)

    assert {:accepted, "new-select"} =
             Loopex.command(context.attachment, %{context.activate | command_id: "new-select"})
  end

  test "revocation retains identity and refuses inspection while command replay stays exact",
       context do
    assert {:accepted, "admit"} = Loopex.command(context.attachment, context.admit)
    assert {:accepted, "select"} = Loopex.command(context.attachment, context.activate)

    revoke = %{
      context.admit
      | command_id: "revoke",
        decision: %{context.admit.decision | revocation_state: "revoked"}
    }

    assert {:accepted, "revoke"} = Loopex.command(context.attachment, revoke)
    digest = context.digest

    assert {:ok,
            %{
              "admitted_manifest_digest" => ^digest,
              "decision_disposition" => "revoked",
              "entries" => []
            }} =
             Loopex.resource_catalog(context.fixture.runtime, context.session)

    assert {:error, :resource_not_admitted} =
             Loopex.read_resource(context.fixture.runtime, context.session, %{
               manifest_digest: digest,
               source_id: "project",
               name: "guide",
               label: "guide.txt"
             })

    assert {:accepted, "select"} = Loopex.command(context.attachment, context.activate)

    assert {:error, :resource_not_admitted} =
             Loopex.command(context.attachment, %{context.activate | command_id: "after-revoke"})

    rows = Fixture.records(context.fixture, context.session)

    assert {:ok, durable} =
             SessionState.recover(
               context.session,
               rows,
               Fixture.events(context.fixture, context.session)
             )

    assert durable.resources["selections"] == []

    assert {:accepted, %{"manifest_digest" => ^digest}} =
             Loopex.Runtime.ResourceSnapshot.resolve(nil, durable.resources, %{
               "type" => "admit_resources",
               "manifest_digest" => digest,
               "decision" => nil
             })
  end

  test "runtime children share a supervisor owned snapshot without complete manifest copies",
       context do
    runtime = context.fixture.runtime
    assert {:ok, children} = Loopex.Runtime.Supervisor.children(runtime.supervisor)
    control = :sys.get_state(children.control)
    table = control.resource_snapshot
    assert :ets.info(table, :owner) == runtime.supervisor
    assert :ets.info(table, :protection) == :protected
    refute has_key_deep?(:sys.get_state(runtime.supervisor), :resource_manifest)
    refute has_key_deep?(control, :resource_manifest)

    for number <- 1..8 do
      assert {:ok, _session} = Loopex.create_session(runtime, %{}, command_id: "extra-#{number}")
    end

    for {_session_id, entry} <- :sys.get_state(children.control).sessions do
      coordinator = :sys.get_state(entry.coordinator)
      assert coordinator.resource_snapshot == table
      refute has_key_deep?(coordinator, :resource_manifest)
      assert coordinator.durable.resources == nil
    end

    assert {:ok, %{"files" => files}} = Loopex.Runtime.ResourceSnapshot.pack(table, 0)
    refute Enum.any?(files, &Map.has_key?(&1, "content"))
    assert {:ok, "Guide bytes."} = Loopex.Runtime.ResourceSnapshot.content(table, 0, 1)
  end

  defp has_key_deep?(value, key) when is_map(value) do
    Map.has_key?(value, key) or
      Enum.any?(:maps.to_list(value), fn {_key, member} -> has_key_deep?(member, key) end)
  end

  defp has_key_deep?(value, key) when is_list(value),
    do: Enum.any?(value, &has_key_deep?(&1, key))

  defp has_key_deep?(value, key) when is_tuple(value),
    do: value |> Tuple.to_list() |> Enum.any?(&has_key_deep?(&1, key))

  defp has_key_deep?(_value, _key), do: false
end
