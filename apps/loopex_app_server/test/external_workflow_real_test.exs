Code.require_file("../../loopex_llm_reqllm/test/support/provider_build_fixture.exs", __DIR__)
Code.require_file("support/source_archive.exs", __DIR__)

defmodule Loopex.AppServer.ExternalWorkflowRealTest do
  @moduledoc """
  ## Concept

  An operator follows the commands in the app-server guide, from an archive of
  the exact committed source, and the whole chain works: a skill discovered in
  their own workspace and selected under their trust decision, a question the
  host policy asked instead of allowing, an answer relayed by an independent
  client, the authorization minted only afterwards, a real model choosing the
  tool, its artifact read back in a verified bounded transfer, and the session
  surviving an abrupt loss of the process that served it.

  ## Technical depth

  Three claims are proved together here because separating them is what let the
  gap in, and each one alone is weaker than it reads. The source is the exact
  committed revision, staged with `git archive` and extracted outside the
  checkout, so nothing untracked and nothing already built travels with it. The
  server is `Loopex.AppServer.Host`, the host this repository ships, launched by
  the command the guide prints rather than by a fixture that lives in this test
  tree. And the model is real, so the tool call, the truncation and the spill
  are a model's own decisions rather than a script's.

  The consumer command runs through `/bin/sh` and is the guide's text, glob and
  all, because the argument shape is part of what an operator copies: every
  argument that is not an `.exs` file becomes a code directory, so
  `_build/prod/lib/*/ebin` has to expand to a working code path or the
  instruction is wrong.

  Dependencies are supplied rather than fetched. The guide says `mix deps.get`;
  a build here that reached the network would be proving something about the
  network, so the tree this suite's own build resolved is copied in and the
  compile is offline. The provider companion is built from the checkout, not
  from the extraction, because that build establishes the revision it came from
  through Git and an archive has no Git directory — which is exactly why its
  `.launch` file is an operator input to the server rather than something the
  server finds.

  What the model does is a real model's own decision, so the assertions are
  behavioral where variance is legitimate: the tool ran after the answer
  committed, exactly one artifact crossed, and two provider replies were
  retained with the identity and non-empty response identifiers a real call
  carries. What the protocol does is asserted exactly, because none of it is the
  model's to vary.

  The credential is never read into a frame, an argument or a file. It sits in
  this process's environment, which the shell, the client and the server it
  launches inherit; the adapter's companion receives it on a private channel
  after readiness, and the case asserts that nothing the client printed carries
  it.
  """

  use ExUnit.Case, async: false

  alias Loopex.LLM.ReqLLM
  alias Loopex.AppServer.SourceArchive
  alias Loopex.LLM.ReqLLM.ProviderBuildFixture
  alias Loopex.Store
  alias LoopexProtocol.Wire

  # The extraction is compiled from nothing, the provider companion is built
  # from clean source, and a real model then takes seconds per turn. The ceiling
  # is those three, not a guess about any of them.
  @moduletag timeout: 1_800_000

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
  test "an extracted source archive follows the operator guide to serve the shipped host and complete the chain against a real provider" do
    credential = credential!()
    node_executable = System.find_executable("node") || flunk("Node is unavailable")
    elixir = System.find_executable("elixir") || flunk("Elixir is unavailable")
    mix = System.find_executable("mix") || flunk("Mix is unavailable")

    root = SourceArchive.owned_root("real-workflow")
    # Set LOOPEX_KEEP_ROOT to inspect the retained store after a failure.
    if System.get_env("LOOPEX_KEEP_ROOT") in [nil, ""], do: on_exit(fn -> File.rm_rf(root) end)
    IO.puts(:stderr, "real workflow root: #{root}")

    extracted = SourceArchive.extract!(root)
    SourceArchive.build!(extracted, mix)

    home = Path.join(root, "home")
    workspace = Path.join(root, "workspace")
    store = Path.join(home, "store.log")
    File.mkdir_p!(home)
    stage_workspace!(workspace)

    # The companion is built from the checkout's exact clean source, as every
    # real-provider lane in this repository builds it. A dirty checkout refuses
    # there rather than proving something about an uncommitted tree.
    launch = ProviderBuildFixture.options!(Path.join(root, "provider"))
    launch_configuration = Keyword.fetch!(launch, :worker_path) <> ".launch"
    assert File.regular?(launch_configuration)

    # Every input the guide names. The credential reaches the shell, the client
    # and the server child through the environment the guide describes, but
    # this VM consumed it at the start and holds it only in a variable: it is
    # handed to that one command's environment, never to this VM's, so it never
    # appears in an argument list, a file or a record.
    environment = [
      {"LOOPEX_PROVIDER_API_KEY", credential},
      {"PATH", Enum.join([Path.dirname(elixir), Path.dirname(node_executable), path()], ":")},
      {"LOOPEX_HOME", home},
      {"LOOPEX_WORKSPACE", workspace},
      {"LOOPEX_PROVIDER_LAUNCH", launch_configuration},
      {"LOOPEX_POLICY", "ask"},
      {"ELIXIR_ERL_OPTIONS", "-noinput"},
      {"LOOPEX_WORKFLOW_STORE", store},
      {"LOOPEX_WORKFLOW_PROMPT", @task},
      {"LOOPEX_WORKFLOW_PATIENCE_MS", "300000"}
    ]

    {output, status} =
      System.cmd("/bin/sh", ["-c", documented_consumer_command(extracted)],
        env: environment,
        stderr_to_stdout: false
      )

    assert status == 0, "the documented consumer command failed: #{output}"

    summary = decode(output)
    refute Map.has_key?(summary, "failed"), "the client reported: #{summary["failed"]}"

    # The whole chain, in one run, driven from outside and answered by a real
    # model: a skill the host found in the operator's own workspace, selected
    # under an operator's trust decision, a question the host asked rather than
    # an allow, an answer relayed, the authorization minted only afterwards, and
    # the tool finishing.
    assert summary["catalog_before"]["entries"] == 0
    assert summary["admission_accepted"]
    assert summary["catalog_after"]["entries"] == 1
    assert summary["skill_selected"] == "reader"

    # The question is the shipped policy's own, word for word, and a client that
    # renders it renders exactly this.
    assert summary["question_prompt"] == "Allow this tool call?"
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
    refute String.contains?(output, credential)

    # The client reports the wire form of the session identity; the Store keys
    # the session by the identity the runtime assigned, which the wire encodes.
    assert {:ok, session_id} = Wire.identity(summary["session_id"] || "")
    records = retained_records(home, session_id)
    events = retained_events(home, session_id)

    # The durable events say the same thing the client observed, and name the
    # tool that actually ran.
    finished = Enum.find(events, &(&1.kind == "tool.finished"))

    assert finished,
           "no tool finished durably: #{length(records)} records, " <>
             "#{length(events)} events, kinds=#{inspect(Enum.map(events, & &1.kind))}, " <>
             "files=#{inspect(File.ls!(home))}, store_bytes=#{byte_size(File.read!(store))}, " <>
             "id_in_log=#{String.contains?(File.read!(store), session_id)}, session_id=#{session_id}"

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

  # Concept: the consumer command the operator guide prints, run as an operator
  # would run it.
  #
  # Technical depth: the text is the guide's, including the glob, because the
  # argument shape is part of the instruction: the client turns every argument
  # that is not an `.exs` file into a code directory, so the glob either expands
  # to a working code path or the documented command does not work. The
  # workspace reference is obtained the way the guide says to obtain it, from
  # the host itself, because a client cannot derive one and a reference this
  # case computed in Elixir would not be evidence about the instruction.
  defp documented_consumer_command(extracted) do
    """
    set -eu
    cd #{extracted}
    export LOOPEX_WORKSPACE_REF="$(ERL_LIBS=_build/prod/lib elixir -e 'IO.write(Loopex.AppServer.Host.workspace_reference!())')"
    export LOOPEX_WORKFLOW_ENTRY="Loopex.AppServer.Host.serve()"
    node clients/node/interaction-workflow.mjs "$(command -v elixir)" _build/prod/lib/*/ebin
    """
  end

  # Concept: an ordinary operator workspace: the file to read, and one project
  # skill the host discovers for itself.
  #
  # Technical depth: the skill is written where the shipped discovery walk looks
  # and nowhere else, so what the client can select is what the workspace admits
  # rather than a manifest a fixture handed the runtime. The read file is
  # deliberately larger than the executor's declared read ceiling, which is what
  # makes the result truncate and the complete bytes spill to the artifact store.
  defp stage_workspace!(workspace) do
    skill = Path.join([workspace, ".agents", "skills", "reader"])
    File.mkdir_p!(skill)

    File.write!(Path.join(skill, "SKILL.md"), """
    ---
    name: reader
    description: Reads a named workspace file
    ---
    Read the file the operator names, using the read tool exactly once. Then
    report whether the result you received was complete.
    """)

    File.write!(
      Path.join(skill, "notes.txt"),
      "The workspace file #{@read_file} is larger than one tool response.\n"
    )

    File.write!(Path.join(workspace, @read_file), architecture_fixture())
  end

  # Concept: a lane that spends a real credential refuses immediately without
  # one, and says so.
  #
  # Technical depth: the value is read and deleted from this VM's environment
  # in one step and returned; it is compared, never printed. Refusing here is what
  # keeps an unattended `--include real_provider` run from building a source
  # archive and a provider companion that could only fail later, and it is the
  # difference between a clear refusal and a wait.
  defp credential! do
    value = System.get_env("LOOPEX_PROVIDER_API_KEY")
    System.delete_env("LOOPEX_PROVIDER_API_KEY")

    case value do
      value when is_binary(value) and value != "" ->
        value

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

  defp path, do: System.get_env("PATH") || "/usr/bin:/bin"

  defp retained_records(state_root, session_id) do
    read_store(state_root, session_id, &Store.load_records(&1, &2, 0, 1_000))
  end

  defp retained_events(state_root, session_id) do
    read_store(state_root, session_id, &Store.load_events(&1, &2, 0, 1_000))
  end

  # Concept: the session's durable truth, read the way an operator reads it.
  #
  # Technical depth: a copy is opened rather than the live log, because opening
  # the original would claim its writer marker and the copy answers the same
  # question. The session is the one the client created and reported; the app
  # server registers no session directory, so the state root alone cannot name it.
  defp read_store(state_root, session_id, load) do
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

  defp index_of(list, value), do: Enum.find_index(list, &(&1 == value))

  defp decode(output) do
    {:ok, decoded} =
      output
      |> String.split("\n", trim: true)
      |> List.last()
      |> LoopexProtocol.Frame.decode(2_097_152)

    decoded
  end
end
