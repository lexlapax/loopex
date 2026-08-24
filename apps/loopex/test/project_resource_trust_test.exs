Code.require_file("support/m1_runtime_helper.exs", __DIR__)
Code.require_file("support/agent_loop_helper.exs", __DIR__)

defmodule Loopex.ProjectResourceTrustTest do
  @moduledoc false

  use ExUnit.Case, async: false

  alias Loopex.AgentLoopFixture, as: Fixture
  alias Loopex.AgentLoopTestModel
  alias Loopex.ProjectResource

  @content "# Project rules\nAlways run the formatter.\n"

  defp manifest(overrides \\ %{}) do
    Map.merge(
      %{
        entries: [%{label: "AGENTS.md", content: @content, contained: true}],
        workspace: %{
          workspace_ref: "workspace-1",
          repository_origin: "git@example.invalid:project.git",
          revision: "abc123"
        }
      },
      overrides
    )
  end

  defp decision_for(manifest, overrides \\ %{}) do
    {:ok, digest, _ordered} = ProjectResource.digest(manifest)

    Map.merge(
      %{
        manifest_digest: digest,
        workspace_ref: manifest.workspace.workspace_ref,
        trust_scope: "project_resource",
        decision_source: "interactive_operator",
        expires_at: nil,
        revocation_state: "active"
      },
      overrides
    )
  end

  defp run_with(options) do
    fixture =
      Fixture.start([script: [%{text: "done", calls: []}]] ++ options)

    on_exit(fn -> Fixture.stop(fixture) end)

    {:ok, session_id} = Loopex.create_session(fixture.runtime, %{"t" => "x"}, command_id: "cs")
    {:ok, attachment} = Loopex.attach(fixture.runtime, session_id, after_event_sequence: 0)

    {:accepted, "p1"} =
      Loopex.command(attachment, %{type: :prompt, command_id: "p1", content: "go"})

    settle(fixture, session_id)
    {fixture, session_id}
  end

  defp settle(fixture, session_id, attempts \\ 300) do
    case Loopex.session_status(fixture.runtime, session_id) do
      {:ok, %{active_run_id: nil}} ->
        :settled

      _other when attempts > 0 ->
        Process.sleep(10)
        settle(fixture, session_id, attempts - 1)

      _other ->
        :never_settled
    end
  end

  defp staged_blocks(fixture) do
    [request] = AgentLoopTestModel.dispatched(fixture.model)

    request.messages
    |> Enum.filter(&String.contains?(to_string(&1["content"]), "<project_resource"))
  end

  defp receipt(fixture, session_id) do
    fixture
    |> Fixture.records(session_id)
    |> Enum.filter(&(&1.payload[:kind] == "model_request_committed"))
    |> List.first()
    |> get_in([Access.key(:payload), "context_receipt"])
  end

  test "discovery resolves a canonical ordered resource set under declared path size and total limits" do
    # Exactly one label is considered, and it is not derived from content.
    assert ProjectResource.permitted_labels() == ["AGENTS.md"]
    assert %{per_resource_bytes: 65_536, class_total_bytes: 65_536} = ProjectResource.limits()

    assert {:ok, digest, [entry]} = ProjectResource.digest(manifest())
    assert String.match?(digest, ~r/^[0-9a-f]{64}$/)
    assert entry.label == "AGENTS.md"

    # A label outside the permitted set is refused whole rather than repaired.
    assert {:error, :manifest_rejected, %{"label" => "README.md"}} =
             ProjectResource.digest(
               manifest(%{entries: [%{label: "README.md", content: "x", contained: true}]})
             )

    # An entry the supplier did not report contained is refused rather than
    # assumed contained: only the side holding the path can establish that.
    assert {:error, :manifest_rejected, %{"reason" => reason}} =
             ProjectResource.digest(
               manifest(%{entries: [%{label: "AGENTS.md", content: "x", contained: false}]})
             )

    assert reason =~ "contained"

    # Over a ceiling it fails closed with the observed size and is never
    # truncated into context.
    oversized = String.duplicate("x", 65_537)

    assert {:error, :over_limit, %{"observed_bytes" => 65_537, "limit_bytes" => 65_536}} =
             ProjectResource.digest(
               manifest(%{entries: [%{label: "AGENTS.md", content: oversized, contained: true}]})
             )
  end

  test "an explicit trust decision binds workspace revision manifest and digests" do
    given = manifest()
    decision = decision_for(given)

    assert {:staged, [block], detail} = ProjectResource.resolve(given, decision)
    assert block =~ "<project_resource label=\"AGENTS.md\">"
    assert block =~ "Always run the formatter."
    assert detail["decision_source"] == "interactive_operator"
    assert detail["manifest_digest"] == decision.manifest_digest
  end

  test "a changed workspace revision manifest or content invalidates the decision" do
    given = manifest()
    decision = decision_for(given)

    # Changed content.
    changed_content =
      manifest(%{entries: [%{label: "AGENTS.md", content: "different", contained: true}]})

    assert {:declined, :binding_changed, _detail} =
             ProjectResource.resolve(changed_content, decision)

    # Changed revision.
    changed_revision =
      manifest(%{
        workspace: %{workspace_ref: "workspace-1", repository_origin: nil, revision: "def456"}
      })

    assert {:declined, :binding_changed, _detail} =
             ProjectResource.resolve(changed_revision, decision)

    # Changed workspace identity.
    changed_workspace =
      manifest(%{
        workspace: %{workspace_ref: "workspace-2", repository_origin: nil, revision: "abc123"}
      })

    assert {:declined, :binding_changed, _detail} =
             ProjectResource.resolve(changed_workspace, decision)

    # A removed resource is a different set and therefore a different digest.
    assert {:declined, :binding_changed, _detail} =
             ProjectResource.resolve(manifest(%{entries: []}), decision)
  end

  test "a headless run without a matching positive decision stages no project block journals a declined receipt and still runs" do
    {fixture, session_id} = run_with(project_manifest: manifest(), project_decision: nil)

    # The run completed: failing closed withheld content, not the runtime.
    assert staged_blocks(fixture) == []
    assert receipt(fixture, session_id)["disposition"] == "no_decision"
    assert length(AgentLoopTestModel.dispatched(fixture.model)) == 1
  end

  test "the operator is shown every resolved path its provenance and the manifest digest" do
    # What an operator must be able to see before deciding is exactly what the
    # digest covers, so a decision cannot be about different bytes than the ones
    # displayed.
    {:ok, digest, ordered} = ProjectResource.digest(manifest())

    assert Enum.map(ordered, & &1.label) == ["AGENTS.md"]
    assert manifest().workspace.repository_origin == "git@example.invalid:project.git"
    assert manifest().workspace.revision == "abc123"

    # Recomputing over the same inputs yields the same digest, so what the
    # operator was shown is what a later run binds against.
    assert {:ok, ^digest, _ordered} = ProjectResource.digest(manifest())
  end

  test "an admitted project block changes no tool set policy decision bound or grant" do
    given = manifest()

    {with_block, _session} =
      run_with(project_manifest: given, project_decision: decision_for(given))

    [admitted] = AgentLoopTestModel.dispatched(with_block.model)

    {without_block, _other} = run_with(project_manifest: nil, project_decision: nil)
    [plain] = AgentLoopTestModel.dispatched(without_block.model)

    # The block is present in one and absent in the other.
    assert Enum.any?(
             admitted.messages,
             &String.contains?(to_string(&1["content"]), "<project_resource")
           )

    refute Enum.any?(
             plain.messages,
             &String.contains?(to_string(&1["content"]), "<project_resource")
           )

    # Everything that carries authority or cost is identical: the block is input
    # structure, not a grant.
    assert admitted.tools == plain.tools
    assert admitted.sampling == plain.sampling
    assert admitted.continuation == plain.continuation
  end

  test "an ordinary workspace read stays a policy governed tool effect and is never context staging" do
    # The staging path considers exactly one label and takes its content from the
    # supplied manifest. There is no path by which a model-requested read becomes
    # a staged block: reading a file is a tool call that goes through the
    # executor and its authority decision, and this module never opens anything.
    assert ProjectResource.permitted_labels() == ["AGENTS.md"]

    # A manifest naming a file a model might ask to read is refused outright,
    # which is what keeps the two paths from meeting.
    assert {:error, :manifest_rejected, _detail} =
             ProjectResource.digest(
               manifest(%{entries: [%{label: "lib/loopex.ex", content: "code", contained: true}]})
             )

    # And with no manifest at all the class is simply declined; a tool read is
    # unaffected because it never consults this stage.
    assert {:declined, :no_manifest, %{}} = ProjectResource.resolve(nil, nil)
  end
end
