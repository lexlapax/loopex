Code.require_file("support/m1_runtime_helper.exs", __DIR__)
Code.require_file("support/agent_loop_helper.exs", __DIR__)

defmodule Loopex.SkillContextTest do
  use ExUnit.Case, async: false

  alias Loopex.AgentLoopFixture, as: Fixture
  alias Loopex.AgentLoopTestModel
  alias Loopex.ProjectResource
  alias Loopex.ResourcePack
  alias Loopex.Runtime.SessionState
  alias LoopexProtocol.Canonical

  test "catalog selected instructions and manifested supporting blocks stage in durable order" do
    context = start_context()
    admit(context)
    select(context, "beta", ["second.txt", "first.txt"])
    select(context, "alpha", ["first.txt"])
    prompt(context, "run-one")
    settle(context)

    [request] = AgentLoopTestModel.dispatched(context.fixture.model)

    [system, root, catalog, beta, alpha, beta_second, beta_first, alpha_first, prompt] =
      request.messages

    assert system["role"] == "system"
    assert root["content"] =~ "Root project guidance"
    assert catalog["content"] =~ "Available project skills"
    assert catalog["content"] =~ "Name: gamma"
    assert beta["content"] == "beta instructions"
    assert alpha["content"] == "alpha instructions"
    assert beta_second["content"] == "beta second support"
    assert beta_first["content"] == "beta first support"
    assert alpha_first["content"] == "alpha first support"
    assert prompt["content"] == "Use the selected project skills."
    refute Enum.any?(request.messages, &(&1["content"] == "gamma instructions"))

    record = resource_record(context)
    receipt = record["context_receipt"]
    assert receipt["provider_revision"] == 3
    assert receipt["resource_packs"]["status"] == "evaluated"

    assert Enum.map(receipt["resource_packs"]["blocks"], &{&1["pack"], &1["file"], &1["status"]}) ==
             [
               {64, 64, "staged"},
               {1, 0, "staged"},
               {0, 0, "staged"},
               {1, 2, "staged"},
               {1, 1, "staged"},
               {0, 1, "staged"}
             ]

    descriptors = Enum.filter(receipt["blocks"], &(&1["provenance_class"] == "resource_pack"))
    assert length(descriptors) == 6
    assert Enum.all?(descriptors, &(&1["trust_class"] == "untrusted_behavior_shaping_data"))

    assert hd(descriptors)["source_reference"]["file_digest"] ==
             Canonical.digest_bytes(catalog["content"])

    rows = Fixture.records(context.fixture, context.session)
    events = Fixture.events(context.fixture, context.session)

    assert {:ok, recovered} =
             Task.async(fn -> SessionState.recover(context.session, rows, events) end)
             |> Task.await()

    assert recovered.resources["selections"] |> Enum.map(& &1["pack_index"]) == [1, 0]
    assert Enum.count(rows, &(&1.payload.kind == "model_attempt_opened_v1")) == 1
  end

  test "only settled operator commands change the next run selection" do
    context = start_context(script: [%{text: "done", hold: self()}])
    admit(context)
    select(context, "alpha", [])
    prompt(context, "held-run")
    assert_receive {:holding, worker}, 2_000

    command = selection(context, "beta", [], "during-run")
    assert {:error, :run_active} = Loopex.command(context.attachment, command)

    assert {:error, :run_active} =
             Loopex.command(
               context.attachment,
               %{
                 type: :admit_resources,
                 command_id: "disable-during-run",
                 manifest_digest: context.digest,
                 decision: nil
               }
             )

    [first] = AgentLoopTestModel.dispatched(context.fixture.model)
    assert Enum.any?(first.messages, &(&1["content"] == "alpha instructions"))
    refute Enum.any?(first.messages, &(&1["content"] == "beta instructions"))

    send(worker, :release)
    settle(context)
    assert {:error, :run_active} = Loopex.command(context.attachment, command)
    select(context, "beta", ["first.txt"])
    prompt(context, "next-run")
    settle(context)
    [_first, second] = AgentLoopTestModel.dispatched(context.fixture.model)
    assert Enum.any?(second.messages, &(&1["content"] == "beta instructions"))
    assert Enum.any?(second.messages, &(&1["content"] == "beta first support"))
  end

  test "an oversized whole support block is withheld while a later selected block still fits" do
    context = start_context(large_support: true)
    admit(context)
    select(context, "alpha", ["first.txt", "second.txt"])
    prompt(context, "run-one")
    settle(context)
    [request] = AgentLoopTestModel.dispatched(context.fixture.model)
    refute Enum.any?(request.messages, &(&1["content"] == String.duplicate("x", 16_385)))
    assert Enum.any?(request.messages, &(&1["content"] == "alpha second support"))

    assert Enum.map(
             resource_record(context)["context_receipt"]["resource_packs"]["blocks"],
             & &1["status"]
           ) == ["staged", "staged", "resource_byte_limit", "staged"]
  end

  test "missing retained content withdraws earlier resource blocks and preserves root context" do
    context = start_context()
    admit(context)
    select(context, "alpha", ["first.txt"])

    # A faulted retained snapshot still has its admitted identity and metadata,
    # but the later supporting body cannot be supplied. Catalog and instruction
    # candidates have already been evaluated when that missing body is reached.
    snapshot = Loopex.Runtime.ResourceSnapshot.new({context.digest, context.manifest})
    :ets.delete(snapshot, {:file, 0, 1})

    {:ok, children} = Loopex.Runtime.Supervisor.children(context.fixture.runtime.supervisor)
    coordinator = :sys.get_state(children.control).sessions[context.session].coordinator
    :sys.replace_state(coordinator, &%{&1 | resource_snapshot: snapshot})

    prompt(context, "missing-body")
    settle(context)
    [request] = AgentLoopTestModel.dispatched(context.fixture.model)
    assert [_, root, prompt] = request.messages
    assert root["content"] =~ "Root project guidance"
    assert prompt["content"] == "Use the selected project skills."

    assert %{"status" => "retained_content_missing", "blocks" => []} =
             resource_record(context)["context_receipt"]["resource_packs"]
  end

  defp start_context(options \\ []) do
    packs =
      for name <- ["alpha", "beta", "gamma"] do
        first =
          if name == "alpha" and Keyword.get(options, :large_support, false),
            do: String.duplicate("x", 16_385),
            else: "#{name} first support"

        %{
          source_id: "project",
          origin: nil,
          commit: nil,
          tree_digest: nil,
          name: name,
          description: "The #{name} project skill",
          manual_only: true,
          files: [
            file("SKILL.md", "#{name} instructions"),
            file("first.txt", first),
            file("second.txt", "#{name} second support")
          ]
        }
      end

    manifest = %{
      version: "loopex.resource_pack/1",
      workspace_ref: "workspace-ref",
      revision: nil,
      packs: packs
    }

    {:ok, digest, normalized} = ResourcePack.digest(manifest)
    root = "Root project guidance"

    project = %{
      workspace: %{workspace_ref: "workspace-ref", repository_origin: nil, revision: nil},
      entries: [
        %{
          label: "AGENTS.md",
          content: root,
          byte_size: byte_size(root),
          content_digest: Canonical.digest_bytes(root),
          contained: true
        }
      ]
    }

    {:ok, project_digest, _entries} = ProjectResource.digest(project)
    decision = decision(digest, "project_skills")

    fixture =
      Fixture.start(
        script: Keyword.get(options, :script, []),
        resource_manifest: manifest,
        project_manifest: project,
        project_decision: decision(project_digest, "project_resource")
      )

    on_exit(fn -> Fixture.stop(fixture) end)
    {:ok, session} = Loopex.create_session(fixture.runtime, %{}, command_id: "create")
    {:ok, attachment} = Loopex.attach(fixture.runtime, session, after_event_sequence: 0)

    %{
      fixture: fixture,
      session: session,
      attachment: attachment,
      digest: digest,
      decision: decision,
      manifest: normalized
    }
  end

  defp file(label, content),
    do: %{
      label: label,
      content: content,
      size: byte_size(content),
      digest: Canonical.digest_bytes(content),
      contained: true
    }

  defp decision(digest, scope),
    do: %{
      manifest_digest: digest,
      workspace_ref: "workspace-ref",
      trust_scope: scope,
      decision_source: "host_supplied",
      issued_at: "2026-09-10T00:00:00Z",
      expires_at: nil,
      revocation_state: "active"
    }

  defp admit(context) do
    assert {:accepted, "admit"} =
             Loopex.command(
               context.attachment,
               %{
                 type: :admit_resources,
                 command_id: "admit",
                 manifest_digest: context.digest,
                 decision: context.decision
               }
             )
  end

  defp selection(context, name, labels, id) do
    pack = Enum.find(context.manifest["packs"], &(&1["name"] == name))

    %{
      type: :activate_skill,
      command_id: id,
      manifest_digest: context.digest,
      source_id: "project",
      name: name,
      pack_digest: ResourcePack.pack_digest(pack),
      supporting_labels: labels
    }
  end

  defp select(context, name, labels) do
    id = "select-#{name}"

    assert {:accepted, ^id} =
             Loopex.command(context.attachment, selection(context, name, labels, id))
  end

  defp prompt(context, id) do
    assert {:accepted, ^id} =
             Loopex.command(
               context.attachment,
               %{type: :prompt, command_id: id, content: "Use the selected project skills."}
             )
  end

  defp settle(context, remaining \\ 300) do
    case Loopex.session_status(context.fixture.runtime, context.session) do
      {:ok, %{active_run_id: nil}} ->
        :ok

      _pending when remaining > 0 ->
        Process.sleep(10)
        settle(context, remaining - 1)

      failure ->
        flunk("session did not settle: #{inspect(failure)}")
    end
  end

  defp resource_record(context) do
    context.fixture
    |> Fixture.records(context.session)
    |> Enum.find(&(&1.payload.kind == "model_request_committed_resources_v1"))
    |> Map.fetch!(:payload)
  end
end
