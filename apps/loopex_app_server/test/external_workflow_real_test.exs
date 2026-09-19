Code.require_file("../../loopex_llm_reqllm/test/support/provider_build_fixture.exs", __DIR__)

defmodule Loopex.AppServer.ExternalWorkflowRealTest do
  @moduledoc """
  ## Concept

  The same chain the scripted workflow proves, driven by the same independent
  Node consumer against the same shipped server, with a real provider behind it:
  a skill selected under an operator's trust decision, a question the host policy
  asked instead of allowing, an answer relayed by the client, the authorization
  minted only afterwards, the tool running, its artifact read back in a verified
  bounded transfer, and the session surviving an abrupt loss of the process that
  served it.

  ## Technical depth

  This is outcome 5's real-path half, and it is an ordinary ExUnit case. It
  carries `@tag :real_provider`, which every ordinary run excludes, takes its
  credential from `LOOPEX_PROVIDER_API_KEY`, and needs no runner, no private
  credential frame and no attended terminal. The maintainer's attended
  demonstration is a separate thing and is not replaced by this.

  What the model does is a real model's own decision, so the assertions are
  behavioral where variance is legitimate: the tool ran after the answer
  committed, exactly one artifact crossed, and two provider replies were
  retained with the identity and non-empty response identifiers a real call
  carries. What the protocol does is asserted exactly, because none of it is the
  model's to vary.

  The credential is never read into a frame, an argument or a file. It reaches
  the adapter through the environment of the server process alone: this case
  never passes it onward, the Node consumer only inherits its own environment,
  and the adapter's companion receives it on a private channel after readiness.
  """

  use ExUnit.Case, async: false

  alias Loopex.LLM.ReqLLM
  alias Loopex.LLM.ReqLLM.ProviderBuildFixture
  alias Loopex.Store

  # The provider companion is built from clean source before the first call, and
  # a real model then takes seconds per turn. The ceiling is the build plus the
  # run, not a guess about either.
  @moduletag timeout: 1_800_000

  @workspace_ref "workspace-ref"
  @read_file "architecture.txt"

  # Concept: one task, stated the way an operator would stage a deterministic
  # verification.
  #
  # Technical depth: it names the tool, the file and the stopping condition, so
  # the only freedom left to the model is wording. The file is deliberately
  # larger than one tool response, which is what makes the result truncate and
  # spill the complete bytes to the artifact store the client then opens a
  # transfer against.
  @task "Use the read tool exactly once on the workspace file #{@read_file}. " <>
          "Do not read any other file, do not call any other tool, and do not " <>
          "retry the read. After the tool result arrives, reply with one short " <>
          "sentence saying whether the result you received was complete, and " <>
          "make no further tool calls."

  @tag :real_provider
  test "the Node consumer completes skill answer reevaluation grant tool artifact and abrupt restart against a real provider" do
    credential!()
    node_executable = System.find_executable("node") || flunk("Node is unavailable")
    elixir = System.find_executable("elixir") || flunk("Elixir is unavailable")

    root = owned_root()
    on_exit(fn -> File.rm_rf(root) end)

    home = Path.join(root, "home")
    workspace = Path.join(root, "workspace")
    state_root = Path.join(root, "state")
    store = Path.join(state_root, "store.log")
    Enum.each([home, workspace, state_root], &File.mkdir_p!/1)
    File.write!(Path.join(workspace, @read_file), architecture_fixture())

    # The companion is built from this exact clean source, as every real-provider
    # lane in this repository builds it. A dirty checkout refuses here rather
    # than proving something about an uncommitted tree.
    launch = ProviderBuildFixture.options!(Path.join(root, "provider"))
    launch_configuration = Keyword.fetch!(launch, :worker_path) <> ".launch"
    assert File.regular?(launch_configuration)

    # Every input the server and the client need is named here. The credential is
    # not among them: it is already in this process's environment and is
    # inherited, so it never appears in an argument list, a file or a record.
    environment = [
      {"LOOPEX_HOME", home},
      {"LOOPEX_WORKSPACE", workspace},
      {"LOOPEX_WORKFLOW_STORE", store},
      {"LOOPEX_WORKFLOW_PROVIDER_LAUNCH", launch_configuration},
      {"LOOPEX_WORKFLOW_ENTRY", "Loopex.AppServer.RealFixture.serve()"},
      {"LOOPEX_WORKFLOW_PROMPT", @task},
      {"LOOPEX_WORKFLOW_PATIENCE_MS", "300000"},
      {"LOOPEX_WORKSPACE_REF", @workspace_ref},
      {"ELIXIR_ERL_OPTIONS", "-noinput"}
    ]

    {output, status} =
      System.cmd(
        node_executable,
        [
          client("interaction-workflow.mjs"),
          elixir,
          ebin(:loopex_protocol),
          ebin(:loopex),
          ebin(:loopex_app_server),
          ebin(:loopex_store_local),
          ebin(:loopex_executor_local),
          ebin(:loopex_llm_reqllm),
          ebin(:telemetry)
        ] ++ require_paths(),
        env: environment,
        stderr_to_stdout: false
      )

    assert status == 0, "the independent client failed: #{output}"

    summary = decode(output)
    refute Map.has_key?(summary, "failed"), "the client reported: #{summary["failed"]}"

    # The whole chain, in one run, driven from outside and answered by a real
    # model: a skill found and selected under an operator's trust decision, a
    # question the host asked rather than an allow, an answer relayed, the
    # authorization minted only afterwards, and the tool finishing.
    assert summary["catalog_before"]["entries"] == 0
    assert summary["admission_accepted"]
    assert summary["catalog_after"]["entries"] == 1
    assert summary["skill_selected"] == "reader"

    # The question is the host policy's own, word for word. This fixture shares
    # the policy the scripted workflow uses, so the wording names writing while
    # the tool reads; what it governs is the authorization, not the verb.
    assert summary["question_prompt"] == "May the tool write the file?"
    assert summary["choice_ids"] == ["allow", "deny"]
    assert summary["answer_accepted"]
    assert summary["resolution"] in ["allowed", "resolved", "answered"]
    assert summary["tool_finished"]

    # The request came before the resolution, and the tool after both: the
    # policy was re-evaluated once the answer had committed, and only then did
    # anything run.
    kinds = summary["event_kinds"]
    assert index_of(kinds, "interaction.requested") < index_of(kinds, "interaction.resolved")
    assert index_of(kinds, "interaction.resolved") < index_of(kinds, "tool.finished")
    assert "run.finished" in kinds

    # Exactly one artifact crossed, and the client read it back in a verified
    # bounded transfer rather than being handed a path. The complete bytes are
    # larger than one tool response, which is why the spill exists at all.
    assert summary["artifacts"] == 1
    assert summary["transfer_opened"]
    assert String.to_integer(summary["total_size"]) > 16_384
    assert summary["chunk_bytes"] == 64
    assert summary["chunk_has_digest"]
    assert summary["transfer_closed"]

    # And then the server was killed rather than closed. What the successor
    # reports survived because it was already durable when the first process
    # died.
    assert summary["restarted"], "the client never restarted the server"
    assert summary["resume_refused"] == false, "the resume was refused: #{inspect(summary)}"
    assert summary["reattached"], "the successor could not attach after an abrupt loss"
    assert summary["session_known_after_restart"]
    assert File.exists?(store)

    # Nothing the client printed carries the credential, which is the only place
    # a leak could have reached this process.
    refute String.contains?(output, System.fetch_env!("LOOPEX_PROVIDER_API_KEY"))

    records = retained_records(state_root)
    events = retained_events(state_root)

    # The durable events say the same thing the client observed, and name the
    # tool that actually ran.
    finished = Enum.find(events, &(&1.kind == "tool.finished"))
    assert finished, "no tool finished durably"
    assert finished["tool_id"] == "loopex.read"
    assert finished["outcome"] == "completed"
    assert length(finished["artifacts"]) == 1

    # A real provider answered, twice: once to choose the tool and once after
    # its durable result. Both replies carry the provider's own response
    # identifier and the identity of the endpoint that produced them.
    replies = provider_replies(records)
    assert length(replies) >= 2

    assert Enum.all?(
             replies,
             &(is_binary(&1["provider_response_id"]) and &1["provider_response_id"] != "")
           )

    assert replies |> Enum.map(& &1["provider_response_id"]) |> Enum.uniq() |> length() ==
             length(replies)

    identity = List.last(replies)["identity"]
    assert {:ok, expected} = ReqLLM.identity(ReqLLM.default_model())
    assert identity["provider"] == expected.provider
    assert identity["model"] == expected.model
    assert identity["endpoint"] == expected.endpoint

    IO.puts(
      :stderr,
      "loopex M4 external real workflow observed: provider=#{identity["provider"]} " <>
        "model=#{identity["model"]} endpoint=#{identity["endpoint"]} " <>
        "provider_response_ids=" <> Enum.map_join(replies, "+", & &1["provider_response_id"])
    )
  end

  # Concept: a lane that spends a real credential refuses immediately without
  # one, and says so.
  #
  # Technical depth: the value is compared, never printed. Refusing here is what
  # keeps an unattended `--include real_provider` run from launching a build and
  # a server that could only fail later, and it is the difference between a
  # clear refusal and a wait.
  defp credential! do
    case System.get_env("LOOPEX_PROVIDER_API_KEY") do
      value when is_binary(value) and value != "" ->
        :ok

      _absent ->
        flunk(
          "credential required: this case calls a real provider and reads " <>
            "LOOPEX_PROVIDER_API_KEY from the environment. Export it and run " <>
            "mix test test/external_workflow_real_test.exs --include real_provider"
        )
    end
  end

  # Concept: a file larger than one tool response, so the read truncates and the
  # complete bytes are retained as an artifact.
  #
  # Technical depth: the content is ordinary prose rather than filler a model
  # would refuse to read, and its size is derived from the executor's own
  # declared read ceiling rather than from a constant that could drift away from
  # it.
  defp architecture_fixture do
    header = """
    # Sample service architecture

    An internet gateway authenticates requests before a private worker reads queued jobs.
    The worker reads a scoped token from process memory and writes audit events to append-only storage.
    """

    line = "The gateway validates schema, rate limits callers, and never logs bearer tokens.\n"
    header <> String.duplicate(line, div(3 * 16_384, byte_size(line)))
  end

  # Concept: an owned temporary root nothing else writes to.
  #
  # Technical depth: resolved to its physical path. On this platform the
  # temporary directory is reached through a symlink, and Mix computes a
  # dependency's `priv` link between two spellings of the same place, which
  # breaks the provider build this root holds.
  defp owned_root do
    {physical, 0} = System.cmd("pwd", ["-P"], cd: System.tmp_dir!())
    nonce = Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    root = Path.join(String.trim(physical), "loopex-m4-real-workflow-#{nonce}")
    File.mkdir!(root)
    root
  end

  defp retained_records(state_root) do
    read_store(state_root, &Store.load_records(&1, &2, 0, 4_096))
  end

  defp retained_events(state_root) do
    read_store(state_root, &Store.load_events(&1, &2, 0, 4_096))
  end

  # Concept: the session's durable truth, read the way an operator reads it.
  #
  # Technical depth: a copy is opened rather than the live log, because opening
  # the original would claim its writer marker and the copy answers the same
  # question. The session is the one this run created, named by the state root
  # rather than by anything the client reported.
  defp read_store(state_root, load) do
    assert {:ok, [%{session_id: session_id}]} = Loopex.list_sessions(state_root)
    copy = Path.join(state_root, "reader-#{System.unique_integer([:positive])}.log")
    File.cp!(Path.join(state_root, "store.log"), copy)
    {:ok, pid} = Loopex.Store.Local.start_link(path: copy)

    try do
      {:ok, store} = Store.new(Loopex.Store.Local, pid)
      {:ok, loaded} = load.(store, session_id)
      loaded
    after
      try do
        GenServer.stop(pid, :normal, 5_000)
      catch
        :exit, _reason -> :ok
      end
    end
  end

  # ADR 0018: a turn's reply is retained on the attempt settlement whose
  # conversation is canonical, as the durable projection under `result`.
  defp provider_replies(records) do
    records
    |> Enum.filter(
      &(&1.payload.kind == "model_attempt_settled_v2" and
          &1.payload["conversation"] == "canonical")
    )
    |> Enum.map(&get_in(&1.payload, ["result", "reply"]))
  end

  defp client(name), do: Path.join([repository_root(), "clients", "node", name])

  defp index_of(list, value), do: Enum.find_index(list, &(&1 == value))

  defp repository_root, do: Path.expand(Path.join([__DIR__, "..", "..", ".."]))

  defp ebin(application) do
    path = Application.app_dir(application, "ebin")
    assert File.dir?(path)
    path
  end

  # Concept: the helper files the server process requires before its entry point.
  #
  # Technical depth: the real fixture reuses the scripted fixture's host policy,
  # so that file is required too; it in turn names the scripted loop helpers,
  # which are required for the same reason the scripted workflow requires them.
  defp require_paths do
    support = Path.join([repository_root(), "apps", "loopex", "test", "support"])
    own = Path.join([repository_root(), "apps", "loopex_app_server", "test", "support"])

    [
      Path.join(support, "m1_runtime_helper.exs"),
      Path.join(support, "agent_loop_helper.exs"),
      Path.join(own, "fixture_server.exs"),
      Path.join(own, "real_fixture.exs")
    ]
  end

  defp decode(output) do
    {:ok, decoded} =
      output
      |> String.split("\n", trim: true)
      |> List.last()
      |> LoopexProtocol.Frame.decode(2_097_152)

    decoded
  end
end
