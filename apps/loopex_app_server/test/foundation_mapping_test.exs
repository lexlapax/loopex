Code.require_file("../../loopex/test/support/m1_runtime_helper.exs", __DIR__)
Code.require_file("../../loopex/test/support/agent_loop_helper.exs", __DIR__)

defmodule Loopex.AppServer.FoundationMappingTest.DeferringPolicy do
  @moduledoc """
  ## Concept

  A host policy that asks before it allows, so the answer and the authorization
  are two facts rather than one.

  ## Technical depth

  The allow is minted here, by the host, after the answer committed. A policy
  that allowed outright would make the witness that separates the two vacuous.
  """

  @behaviour Loopex.Policy

  @impl Loopex.Policy
  def decide(request) do
    case Map.get(request, :interaction_response) do
      nil ->
        {:defer,
         %{
           kind: :choice,
           prompt: "May the tool write?",
           choices: [%{id: "allow", label: "Allow"}, %{id: "deny", label: "Deny"}],
           expires_in_ms: 60_000
         }}

      %{answer: %{choice_id: "allow"}} ->
        {:allow, nil}

      %{answer: %{choice_id: _refused}} ->
        {:deny, :policy_denied}
    end
  end
end

defmodule Loopex.AppServer.FoundationMappingTest do
  @moduledoc """
  ## Concept

  Attaching over the wire gives a client the same authoritative snapshot the
  facade gives, at the same cursor, and an interaction answered over the wire is
  the same durable answer the facade would have committed. Neither carries
  anything a client is not owed.

  ## Technical depth

  Accepted ADR 0023 fixes the snapshot's exact members and the answer's exact
  shape, and accepted ADR 0024 owns what an interaction is. These cases assert
  the wire projection member by member rather than comparing it to itself, and
  they assert the refusals that keep an answer from becoming an authority: an
  answer naming anything besides one choice is refused before a facade sees it,
  because a client that could attach a second member to an answer would be
  writing policy input.
  """

  use ExUnit.Case, async: false

  alias Loopex.AgentLoopFixture, as: Fixture
  alias Loopex.AppServer.Connection
  alias LoopexProtocol.Session
  alias LoopexProtocol.Wire

  test "attaching returns the snapshot and the cursor, in their wire representations" do
    fixture = fixture()
    {connection, session_id} = created(fixture)

    {:ok, record, _connection} =
      Connection.dispatch(connection, %{
        "method" => "session.attach",
        "request_id" => "r2",
        "session_id" => Wire.encode_identity(session_id),
        "after_event_sequence" => "0"
      })

    assert record["type"] == "snapshot"
    assert record["request_id"] == "r2"
    assert {:ok, ^session_id} = Wire.identity(record["session_id"])

    # The cursor is a decimal string, and the snapshot reports the same number.
    assert {:ok, cursor} = Wire.u64(record["event_cursor"])
    assert record["snapshot"]["event_sequence"] == record["event_cursor"]
    assert is_integer(cursor)

    snapshot = record["snapshot"]
    assert snapshot["snapshot_revision"] == 2

    assert Enum.sort(Map.keys(snapshot)) == [
             "active_run_id",
             "active_run_phase",
             "event_sequence",
             "session_id",
             "snapshot_revision"
           ]

    # The two active members are both absent or both present; a phase is never
    # inferred from an identity.
    assert is_nil(snapshot["active_run_id"]) == is_nil(snapshot["active_run_phase"])
  end

  test "the wire snapshot carries the same state the facade's own attachment does" do
    fixture = fixture()
    {connection, session_id} = created(fixture)

    {:ok, record, _connection} =
      Connection.dispatch(connection, %{
        "method" => "session.attach",
        "request_id" => "r2",
        "session_id" => Wire.encode_identity(session_id)
      })

    {:ok, attachment} = Loopex.attach(fixture.runtime, session_id, after_event_sequence: 0)
    facade = Loopex.snapshot(attachment)

    assert record["snapshot"]["snapshot_revision"] == facade.snapshot_revision
    assert {:ok, ^session_id} = Wire.identity(record["snapshot"]["session_id"])

    assert {:ok, facade.event_sequence} == Wire.u64(record["snapshot"]["event_sequence"])
  end

  test "a cursor in any spelling but canonical decimal is refused" do
    fixture = fixture()
    {connection, session_id} = created(fixture)

    for bad <- [0, "00", "-1", "1.0", " 0"] do
      assert {:error, refusal, _connection} =
               Connection.dispatch(connection, %{
                 "method" => "session.attach",
                 "request_id" => "r2",
                 "session_id" => Wire.encode_identity(session_id),
                 "after_event_sequence" => bad
               })

      assert refusal["code"] == "invalid_request", "admitted #{inspect(bad)}"
    end
  end

  test "replace must be a boolean, and defaults to leaving another attachment alone" do
    fixture = fixture()
    {connection, session_id} = created(fixture)

    assert {:error, refusal, _connection} =
             Connection.dispatch(connection, %{
               "method" => "session.attach",
               "request_id" => "r2",
               "session_id" => Wire.encode_identity(session_id),
               "replace" => "true"
             })

    assert refusal["code"] == "invalid_request"

    assert {:ok, record, _connection} =
             Connection.dispatch(connection, %{
               "method" => "session.attach",
               "request_id" => "r3",
               "session_id" => Wire.encode_identity(session_id)
             })

    assert record["type"] == "snapshot"
  end

  test "an answer must name exactly one offered choice and nothing else" do
    fixture = fixture()
    {connection, session_id} = created(fixture)
    {:ok, attachment} = Loopex.attach(fixture.runtime, session_id, after_event_sequence: 0)
    connection = Connection.attach(connection, attachment)

    for bad <- [
          %{},
          %{"choice_id" => Wire.encode_identity("yes"), "note" => "extra"},
          %{"choice" => Wire.encode_identity("yes")},
          %{"choice_id" => "not base64url!"},
          "yes"
        ] do
      assert {:error, refusal, _connection} =
               Connection.dispatch(connection, %{
                 "method" => "session.respond_interaction",
                 "request_id" => "r2",
                 "command_id" => Wire.encode_identity("a1"),
                 "interaction_id" => Wire.encode_identity("i1"),
                 "answer" => bad
               })

      assert refusal["code"] == "invalid_request", "admitted #{inspect(bad)}"
    end
  end

  test "an answer to no open question is refused by the runtime, not accepted here" do
    fixture = fixture()
    {connection, session_id} = created(fixture)
    {:ok, attachment} = Loopex.attach(fixture.runtime, session_id, after_event_sequence: 0)
    connection = Connection.attach(connection, attachment)

    assert {:ok, record, _connection} =
             Connection.dispatch(connection, %{
               "method" => "session.respond_interaction",
               "request_id" => "r2",
               "command_id" => Wire.encode_identity("a1"),
               "interaction_id" => Wire.encode_identity("i1"),
               "answer" => %{"choice_id" => Wire.encode_identity("yes")}
             })

    # It reaches the facade and comes back refused with a stable reason, rather
    # than being accepted by a layer with no authority to accept it.
    assert record["type"] == "admission"
    assert record["status"] == "refused"
    assert is_binary(record["reason"])
  end

  test "an answer carries no authority: the wire cannot mark a decision allowed" do
    fixture = fixture()
    {connection, session_id} = created(fixture)
    {:ok, attachment} = Loopex.attach(fixture.runtime, session_id, after_event_sequence: 0)
    connection = Connection.attach(connection, attachment)

    assert {:ok, record, _connection} =
             Connection.dispatch(connection, %{
               "method" => "session.respond_interaction",
               "request_id" => "r2",
               "command_id" => Wire.encode_identity("a1"),
               "interaction_id" => Wire.encode_identity("i1"),
               "answer" => %{"choice_id" => Wire.encode_identity("yes")}
             })

    rendered = inspect(record, limit: :infinity)

    refute rendered =~ "allow"
    refute rendered =~ "grant"
    refute rendered =~ "policy"
  end

  test "a resource read names at least one selector" do
    fixture = fixture()
    {connection, session_id} = created(fixture)

    assert {:error, refusal, _connection} =
             Connection.dispatch(connection, %{
               "method" => "resources.read",
               "request_id" => "r2",
               "session_id" => Wire.encode_identity(session_id)
             })

    assert refusal["code"] == "invalid_request"
  end

  test "every method this build answers is one the generation names" do
    for method <- ["session.attach", "session.respond_interaction", "resources.catalog"] do
      assert method in Session.methods()
    end
  end

  defp fixture do
    fixture = Fixture.start(script: [%{text: "done", calls: []}])
    on_exit(fn -> Fixture.stop(fixture) end)
    fixture
  end

  # The four cases below are this outcome's locked witnesses. Each carries the
  # exact identity acceptance bound; the narrower cases above remain because they
  # say which single rule broke when one of these fails.

  test "wire clients select only admitted catalog resources and cannot name roots modules profiles or grants" do
    fixture = resourced_fixture()
    {connection, session_id} = created(fixture)
    connection = attached(connection, session_id)
    {manifest_digest, connection} = admit(connection, session_id)

    {:ok, catalog, connection} =
      Connection.dispatch(connection, %{
        "method" => "resources.catalog",
        "request_id" => "rc",
        "session_id" => Wire.encode_identity(session_id)
      })

    [entry] = catalog["result"]["entries"]

    # What a client may select is what the catalog described, and nothing else.
    assert {:ok, admitted, connection} =
             Connection.dispatch(connection, %{
               "method" => "session.activate_skill",
               "request_id" => "rs",
               "command_id" => Wire.encode_identity("cs1"),
               "manifest_digest" => manifest_digest,
               "pack_digest" => entry["pack_digest"],
               "source_id" => entry["source_id"],
               "name" => entry["name"],
               "supporting_labels" => []
             })

    assert admitted["status"] == "accepted"

    # A selection naming something the catalog never described is refused, even
    # when every field is well formed.
    assert {:ok, invented, _connection} =
             Connection.dispatch(connection, %{
               "method" => "session.activate_skill",
               "request_id" => "rs2",
               "command_id" => Wire.encode_identity("cs2"),
               "manifest_digest" => manifest_digest,
               "pack_digest" => entry["pack_digest"],
               "source_id" => "invented",
               "name" => "invented",
               "supporting_labels" => []
             })

    assert invented["status"] == "refused"

    # And the generation names no method through which a client could reach a
    # root, a module, a grant profile or a grant. These are launch inputs and
    # host authority; there is nothing to refuse because there is nothing to ask.
    for forbidden <- ~w(root module profile grant credential executor store policy) do
      refute Enum.any?(Session.methods(), &String.contains?(&1, forbidden)),
             "the generation names a method mentioning #{forbidden}"
    end
  end

  test "no request parameter model output resource or answer replaces an immutable launch input" do
    fixture = resourced_fixture()
    {connection, session_id} = created(fixture)

    connection = attached(connection, session_id)
    {:ok, configuration} = Loopex.Runtime.configuration(fixture.runtime)

    # A request carrying launch-shaped members changes nothing: the mapping reads
    # the members its method names and the runtime it was launched with, and a
    # member it does not name is not an instruction.
    assert {:ok, _admission, connection} =
             Connection.dispatch(connection, %{
               "method" => "session.prompt",
               "request_id" => "rp",
               "command_id" => Wire.encode_identity("cp"),
               "content_b64" => Base.url_encode64("go", padding: false),
               "runtime_id" => "someone-elses-runtime",
               "policy" => "AllowEverything",
               "store" => "/tmp/somewhere",
               "model" => "provider:model",
               "executor" => "somewhere-else"
             })

    assert {:ok, after_prompt} = Loopex.Runtime.configuration(fixture.runtime)
    assert after_prompt == configuration

    # The same is true of an attach: a client names a session and a cursor, and
    # nothing about what answers it.
    assert {:ok, _snapshot, _connection} =
             Connection.dispatch(connection, %{
               "method" => "session.attach",
               "request_id" => "ra",
               "session_id" => Wire.encode_identity(session_id),
               "replace" => true,
               "runtime_id" => "someone-elses-runtime"
             })

    assert {:ok, ^configuration} = Loopex.Runtime.configuration(fixture.runtime)
  end

  test "missing or stale trust withholds staged content while ordinary coding continues" do
    fixture = resourced_fixture()
    {connection, session_id} = created(fixture)

    {:ok, withheld, connection} =
      Connection.dispatch(connection, %{
        "method" => "resources.catalog",
        "request_id" => "rc",
        "session_id" => Wire.encode_identity(session_id)
      })

    # No decision: the manifest is named, and nothing it holds is described.
    body = withheld["result"]

    assert body["decision_disposition"] == "no_decision"
    assert body["entries"] == []
    assert is_nil(body["admitted_manifest_digest"])
    refute Map.has_key?(body, "workspace_ref")

    # Reading a resource under no trust is refused rather than served.
    assert {:error, read, connection} =
             Connection.dispatch(connection, %{
               "method" => "resources.read",
               "request_id" => "rr",
               "session_id" => Wire.encode_identity(session_id),
               "manifest_digest" => body["configured_manifest_digest"],
               "source_id" => "project",
               "name" => "writer",
               "label" => "SKILL.md"
             })

    assert read["type"] == "error"
    assert read["message"] == "resource_not_admitted"

    # Ordinary coding is unaffected: withholding content is not refusing a
    # session.
    {:ok, attached, connection} =
      Connection.dispatch(connection, %{
        "method" => "session.attach",
        "request_id" => "ra",
        "session_id" => Wire.encode_identity(session_id)
      })

    assert attached["type"] == "snapshot"

    assert {:ok, admission, _connection} =
             Connection.dispatch(connection, %{
               "method" => "session.prompt",
               "request_id" => "rp",
               "command_id" => Wire.encode_identity("cp"),
               "content_b64" => Base.url_encode64("write something", padding: false)
             })

    assert admission["status"] == "accepted"
  end

  test "interaction answer admission is observed separately from policy re-evaluation grant intent and tool receipt" do
    fixture = deferring_fixture()
    {connection, session_id} = created(fixture)

    {:ok, _snapshot, connection} =
      Connection.dispatch(connection, %{
        "method" => "session.attach",
        "request_id" => "ra",
        "session_id" => Wire.encode_identity(session_id)
      })

    {:ok, _admission, connection} =
      Connection.dispatch(connection, %{
        "method" => "session.prompt",
        "request_id" => "rp",
        "command_id" => Wire.encode_identity("cp"),
        "content_b64" => Base.url_encode64("write the file", padding: false)
      })

    interaction_id = await_interaction(fixture, session_id)

    kinds_before = record_kinds(fixture, session_id)
    assert "interaction_requested_v1" in kinds_before

    # The answer is admitted as its own durable command. Nothing about the
    # policy's second decision has happened yet.
    assert {:ok, answered, _connection} =
             Connection.dispatch(connection, %{
               "method" => "session.respond_interaction",
               "request_id" => "rz",
               "command_id" => Wire.encode_identity("ca"),
               "interaction_id" => Wire.encode_identity(interaction_id),
               "answer" => %{"choice_id" => Wire.encode_identity("allow")}
             })

    assert answered["status"] == "accepted"

    settle(fixture, session_id)
    kinds_after = record_kinds(fixture, session_id)

    # Five distinct durable facts, in this order: the question, the answer's own
    # admission, the resolution the policy's second decision produced, the intent
    # that authorization committed, and the receipt of what the tool did. A design
    # that folded the answer into the authorization would show four, and one that
    # let an answer authorize directly would show the intent without a
    # resolution between them.
    requested = Enum.find_index(kinds_after, &(&1 == "interaction_requested_v1"))
    resolved = Enum.find_index(kinds_after, &(&1 == "interaction_resolved_v1"))
    intent = Enum.find_index(kinds_after, &(&1 == "effect_intent_committed"))
    receipt = Enum.find_index(kinds_after, &(&1 == "executor_receipt_committed"))

    # The answer is admitted as an ordinary command, between the question and
    # its resolution, rather than as part of either.
    answered =
      kinds_after
      |> Enum.with_index()
      |> Enum.find_index(fn {kind, index} ->
        kind == "command_admitted" and index > requested
      end)

    for {label, position} <- [
          requested: requested,
          answered: answered,
          resolved: resolved,
          intent: intent,
          receipt: receipt
        ] do
      refute is_nil(position), "#{label} was never committed: #{inspect(kinds_after)}"
    end

    assert requested < answered
    assert answered < resolved
    assert resolved < intent
    assert intent < receipt
    assert length(kinds_after) > length(kinds_before)
  end

  defp resourced_fixture do
    fixture = Fixture.start(script: [%{text: "done", calls: []}], resource_manifest: manifest())
    on_exit(fn -> Fixture.stop(fixture) end)
    fixture
  end

  defp deferring_fixture do
    fixture =
      Fixture.start(
        script: [
          %{
            text: "writing",
            calls: [%{id: "mapping-call", name: "write", arguments: %{"path" => "out.txt"}}]
          },
          %{text: "done", calls: []}
        ],
        policy: Loopex.AppServer.FoundationMappingTest.DeferringPolicy,
        policy_identity: %{"id" => "loopex.test.foundation_mapping", "revision" => "1"}
      )

    on_exit(fn -> Fixture.stop(fixture) end)
    fixture
  end

  defp manifest do
    files =
      for {label, content} <- [{"SKILL.md", "Write the file."}, {"notes.txt", "Notes."}] do
        %{
          label: label,
          content: content,
          size: byte_size(content),
          digest: LoopexProtocol.Canonical.digest_bytes(content),
          contained: true
        }
      end

    %{
      version: "loopex.resource_pack/1",
      workspace_ref: "workspace-ref",
      revision: nil,
      packs: [
        %{
          source_id: "project",
          origin: nil,
          commit: nil,
          tree_digest: nil,
          name: "writer",
          description: "Writes a file",
          manual_only: true,
          files: files
        }
      ]
    }
  end

  defp attached(connection, session_id) do
    {:ok, _snapshot, connection} =
      Connection.dispatch(connection, %{
        "method" => "session.attach",
        "request_id" => "ratt",
        "session_id" => Wire.encode_identity(session_id)
      })

    connection
  end

  defp admit(connection, session_id) do
    {:ok, catalog, connection} =
      Connection.dispatch(connection, %{
        "method" => "resources.catalog",
        "request_id" => "rc0",
        "session_id" => Wire.encode_identity(session_id)
      })

    digest = catalog["result"]["configured_manifest_digest"]

    {:ok, admission, connection} =
      Connection.dispatch(connection, %{
        "method" => "session.admit_resources",
        "request_id" => "rad",
        "command_id" => Wire.encode_identity("cad"),
        "manifest_digest" => digest,
        "decision" => %{
          "manifest_digest" => digest,
          "workspace_ref" => "workspace-ref",
          "trust_scope" => "project_skills",
          "decision_source" => "interactive_operator",
          "issued_at" => "2026-09-15T00:00:00Z",
          "expires_at" => nil,
          "revocation_state" => "active"
        }
      })

    assert admission["status"] == "accepted"
    {digest, connection}
  end

  defp await_interaction(fixture, session_id, attempts \\ 300) do
    case Loopex.session_status(fixture.runtime, session_id) do
      {:ok, %{open_interaction: %{"interaction_id" => id}}} when is_binary(id) ->
        id

      _other when attempts > 0 ->
        Process.sleep(10)
        await_interaction(fixture, session_id, attempts - 1)

      _other ->
        flunk("no question was ever asked")
    end
  end

  defp record_kinds(fixture, session_id) do
    fixture |> Fixture.records(session_id) |> Enum.map(& &1.payload.kind)
  end

  defp settle(fixture, session_id, attempts \\ 300) do
    case Loopex.session_status(fixture.runtime, session_id) do
      {:ok, %{active_run_id: nil}} ->
        :settled

      _other when attempts > 0 ->
        Process.sleep(10)
        settle(fixture, session_id, attempts - 1)

      _other ->
        :active
    end
  end

  defp created(fixture) do
    connection = Connection.new(runtime: fixture.runtime)

    {:ok, _reply, connection} =
      Connection.initialize(connection, %{
        "request_id" => "r0",
        "generations" => [Session.generation()],
        "capabilities" => []
      })

    {:ok, record, connection} =
      Connection.dispatch(connection, %{
        "method" => "session.create",
        "request_id" => "r1",
        "command_id" => Wire.encode_identity("cs")
      })

    {:ok, session_id} = Wire.identity(record["session_id"])
    {connection, session_id}
  end
end
