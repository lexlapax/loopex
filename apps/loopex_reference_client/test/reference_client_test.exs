Code.require_file("support/runtime_fixture.ex", __DIR__)

defmodule Loopex.ReferenceClientTest do
  use ExUnit.Case, async: false

  alias Loopex.ReferenceClient
  alias Loopex.ReferenceClientRuntimeFixture, as: Fixture

  test "creation requires complete current host genesis and retains it exactly" do
    label = "captured-genesis"
    fixture = Fixture.start(label, Loopex.ReferenceClientTestModel)
    on_exit(fn -> Fixture.stop(fixture) end)
    command_id = "create-#{label}"
    genesis = Fixture.genesis(fixture, label)

    for unsupported <- [
          %{"fixture" => label},
          %{"options" => %{"fixture" => label}, kind: "session_genesis_v2"},
          Map.delete(genesis, "initial_configuration"),
          put_in(genesis, ["tool_selection", "names"], %{})
        ] do
      assert {:error, :invalid_session_creation} =
               ReferenceClient.create(fixture.client, unsupported, command_id)
    end

    assert {:ok, client} = ReferenceClient.create(fixture.client, genesis, command_id)
    created = %{fixture | client: client}
    assert hd(Fixture.records(created, client.session_id)).payload == genesis

    assert {:ok, replayed} = ReferenceClient.create(fixture.client, genesis, command_id)
    assert replayed.session_id == client.session_id

    assert Enum.count(Fixture.records(created, client.session_id), fn record ->
             record.payload.kind == "session_genesis_v3"
           end) == 1
  end

  # Concept: a real-provider fixture consumes its credential when it composes:
  # afterwards this VM's environment no longer names it, and custody alone
  # holds it.
  #
  # Technical depth: a synthetic key is placed in `LOOPEX_PROVIDER_API_KEY`
  # and the fixture's credential composition runs once. The variable is then
  # absent, and the returned token routes through the returned registry to a
  # custody process that resolves exactly that key. A value the variable held
  # before the case is restored when it ends.
  test "real-provider fixture composition consumes the credential into custody" do
    variable = Loopex.LLM.ReqLLM.credential_variable()
    previous = System.get_env(variable)

    on_exit(fn ->
      if previous,
        do: System.put_env(variable, previous),
        else: System.delete_env(variable)
    end)

    key = "reference-fixture-synthetic-credential"
    System.put_env(variable, key)
    options = Fixture.provider_credential_options()

    assert System.get_env(variable) == nil
    assert Enum.sort(Keyword.keys(options)) == [:credential_registry, :credential_token]

    assert {:ok, custody} =
             Loopex.LLM.ReqLLM.CredentialRegistry.route(
               Keyword.fetch!(options, :credential_registry),
               Keyword.fetch!(options, :credential_token)
             )

    assert {:ok, %{credential: ^key}} = Loopex.LLM.ReqLLM.CredentialCustody.resolve(custody)
  end

  test "the client drives the loop through the embedded API only" do
    fixture =
      Fixture.start(
        "thin-client",
        Loopex.ReferenceClientTestModel,
        relative_path: "thin-client.txt",
        content: "thin-client-effect"
      )
      |> Fixture.create("thin-client")

    on_exit(fn -> Fixture.stop(fixture) end)

    assert {:accepted, "prompt-thin-client"} =
             ReferenceClient.prompt(fixture.client, "prompt-thin-client", "do the work")

    Fixture.await_terminal(fixture)

    events = drain(fixture.client, [])

    assert Enum.map(events, & &1.kind) == [
             "user.message_appended",
             "run.started",
             "assistant.message_appended",
             "tool.started",
             "tool.finished",
             "assistant.message_appended",
             "run.finished",
             # Accepted ADR 0011 keeps the session settling distinct from the
             # run ending, and this session had nothing queued behind it.
             "session.settled"
           ]

    assert File.read!(Path.join(fixture.workspace, "thin-client.txt")) ==
             "thin-client-effect"

    source = File.read!(Path.join(__DIR__, "../lib/reference_client.ex"))

    calls =
      ~r/Loopex\.([a-z_]+)\(/
      |> Regex.scan(source)
      |> Enum.map(fn [_match, function] -> function end)
      |> MapSet.new()

    assert calls ==
             MapSet.new(
               ~w(start_link create_session attach resume_session command open_artifact_transfer read_artifact_chunk close_artifact_transfer next_event reconciliation_query reconcile session_status stop)
             )
  end

  # Concept: the reference client reads a retained artifact through an owned
  # transfer and gets back exactly the stored bytes.
  # Technical depth: accepted ADRs 0028 and 0066 against the real Local artifact
  # store and its transfer owner. A two-chunk object crosses the embedded
  # transfer API with per-chunk and whole-object digests checked; afterwards no
  # transfer remains live in the owner, and a use from another session refuses.
  test "the client reads a retained artifact use through an owned transfer" do
    root =
      Path.join(
        System.tmp_dir!(),
        "loopex-reference-artifact-#{System.unique_integer([:positive])}"
      )

    {:ok, handle} = Loopex.Store.Local.Artifacts.open(Path.join(root, "artifacts"))
    {:ok, owner} = Loopex.Store.Local.Transfers.start_link(root: Path.join(root, "artifacts"))
    Process.unlink(owner)
    store = %{module: Loopex.Store.Local.Artifacts, handle: Map.put(handle, :transfers, owner)}

    fixture =
      Fixture.start("artifact-read", Loopex.ReferenceClientTestModel, [],
        root: root,
        artifact_store: store
      )
      |> Fixture.create("artifact-read")

    on_exit(fn ->
      Fixture.stop(fixture)
      if Process.alive?(owner), do: GenServer.stop(owner, :normal, 5_000)
      File.rm_rf!(root)
    end)

    bytes = :binary.copy("reference-artifact ", 2_000)

    {:ok, reference} =
      Loopex.ArtifactStore.put(store, bytes, use_metadata(fixture.client.session_id))

    assert byte_size(bytes) > 32_768

    assert {:ok, ^bytes} = ReferenceClient.read_artifact(fixture.client, reference.use_locator)
    assert Loopex.Store.Local.Transfers.live(owner) == []

    {:ok, foreign} = Loopex.ArtifactStore.put(store, bytes, use_metadata("another-session"))

    assert {:error, %{reason: :artifact_use_mismatch, cleanup: :unproved}} =
             ReferenceClient.read_artifact(fixture.client, foreign.use_locator)
  end

  defp use_metadata(session_id) do
    %{
      "media_type" => "text/plain",
      "role" => "tool_output",
      "session_id" => session_id,
      "run_id" => "run",
      "operation_id" => "operation",
      "attempt" => 1,
      "tool_call_id" => "tool"
    }
  end

  test "the reference prompt commits a five minute duration and derives its instant at staging" do
    fixture =
      Fixture.start(
        "prompt-deadline",
        Loopex.ReferenceClientTestModel,
        observer: self(),
        relative_path: "prompt-deadline.txt",
        content: "prompt-deadline-effect"
      )
      |> Fixture.create("prompt-deadline")

    on_exit(fn -> Fixture.stop(fixture) end)

    staging_floor = System.system_time(:millisecond)

    assert {:accepted, "prompt-deadline"} =
             ReferenceClient.prompt(fixture.client, "prompt-deadline", "do the work")

    assert_receive {:model_request, request}, 2_000
    staging_ceiling = System.system_time(:millisecond)
    Fixture.await_terminal(fixture)

    records = Fixture.records(fixture, fixture.client.session_id)
    # The configuration-bound admission retains ADR 0013's declared duration;
    # staging derives the deadline instant from that captured duration.
    admitted = Enum.find(records, &(&1.payload.kind == "prompt_admitted_v3"))
    staged = Enum.find(records, &(&1.payload.kind == "model_request_committed_v2"))

    assert admitted.payload["deadline_ms"] == 300_000
    refute Map.has_key?(admitted.payload, "deadline")
    assert staged.payload["request"]["deadline"] == request.deadline
    assert request.deadline >= staging_floor + 300_000
    assert request.deadline <= staging_ceiling + 300_000
    assert request.deadline < staging_floor + 600_000
  end

  test "the reference prompt refuses an unknown bound key before admitting a command" do
    fixture =
      Fixture.start("unknown-prompt-bound", Loopex.ReferenceClientTestModel)
      |> Fixture.create("unknown-prompt-bound")

    on_exit(fn -> Fixture.stop(fixture) end)

    assert {:error, :invalid_declared_bounds} =
             ReferenceClient.prompt(fixture.client, "prompt-typo", "do the work",
               bounds: %{
                 max_turns: 8,
                 token_budget: 1_000_000,
                 deadline_ms: 300_000,
                 deadine_ms: 300_000
               }
             )

    # A refused bound must leave no configuration-bound prompt admission.
    refute Enum.any?(Fixture.records(fixture, fixture.client.session_id), fn record ->
             record.payload.kind == "prompt_admitted_v3"
           end)
  end

  test "the reference client owns no policy durable state or alternate loop" do
    source = File.read!(Path.join(__DIR__, "../lib/reference_client.ex"))
    recovery = File.read!(Path.join(__DIR__, "../lib/recovery.ex"))

    refute String.contains?(source, "use GenServer")
    refute String.contains?(source, "handle_call")
    refute String.contains?(source, "Loopex.Store")
    refute String.contains?(source, "Loopex.Runtime.Session")
    refute String.contains?(source, "Loopex.Executor")
    refute String.contains?(source, "Loopex.Model")

    refute String.contains?(recovery, "use GenServer")
    refute String.contains?(recovery, "execute(")
    refute String.contains?(recovery, "dispatch(")

    assert Map.keys(%ReferenceClient{}) |> Enum.sort() ==
             [:__struct__, :attachment, :runtime, :session_id]
  end

  defp drain(client, accumulated) do
    case ReferenceClient.next_event(client) do
      {:ok, event} -> drain(client, [event | accumulated])
      {:error, :empty} -> Enum.reverse(accumulated)
    end
  end
end
