defmodule Loopex.AppServer.ExternalWorkflowTest do
  @moduledoc """
  ## Concept

  An independent client, written in another language and running in its own
  process, completes a whole session against the shipped server: it negotiates,
  creates, attaches, prompts, follows the durable events to the end of the run,
  reads the session back, survives a refusal, and leaves cleanly.

  ## Technical depth

  This is outcome 5's unattended half. Nothing about the client is Elixir: it
  speaks bytes over a pipe and reports only what it could observe through the
  protocol, so the evidence is what a real consumer can see rather than what the
  server happens to log. The client's summary is asserted here, which is why it
  prints one and why every member of it is something a record carried.

  The attended real-provider demonstration outcome 5 also names is the
  maintainer's to perform. It spends a provider key and needs a person watching,
  so it is deliberately not simulated here; the model behind this server is
  scripted and says so.
  """

  use ExUnit.Case, async: false

  alias LoopexProtocol.Frame
  alias LoopexProtocol.Session

  @moduletag timeout: 120_000

  test "an independent client completes a session over the wire and reports what it saw" do
    node_executable = System.find_executable("node")

    if is_nil(node_executable) do
      flunk("Node is required for the independent client workflow and was not found")
    end

    {output, status} =
      System.cmd(
        node_executable,
        [
          client("workflow.mjs"),
          System.find_executable("elixir") || flunk("Elixir executable unavailable"),
          ebin(:loopex_protocol),
          ebin(:loopex),
          ebin(:loopex_app_server),
          ebin(:telemetry)
        ] ++ require_paths(),
        env: child_environment(),
        stderr_to_stdout: false
      )

    assert status == 0, "the independent client failed: #{output}"

    summary = decode(output)

    refute Map.has_key?(summary, "failed"), "the client reported: #{summary["failed"]}"

    # It negotiated the contract it was written against, by digest.
    assert summary["generation"] == LoopexProtocol.Session.generation()
    assert summary["schema_digest"] == LoopexProtocol.Session.schema_digest()
    assert summary["method_count"] == 16
    assert summary["frame_bytes"] == 1_048_576

    # It created a session and received back the identity it sent.
    assert summary["session_created"]
    assert summary["command_id_returned"] == "client-create"

    # It attached and was given the exact snapshot members.
    assert summary["snapshot_members"] == [
             "active_run_id",
             "active_run_phase",
             "event_sequence",
             "session_id",
             "snapshot_revision"
           ]

    # It prompted, and followed durable events to the end of the run.
    assert summary["prompt_accepted"]
    assert is_binary(summary["run_finished_sequence"])
    assert "run.finished" in summary["event_kinds"]
    assert "user.message_appended" in summary["event_kinds"]
    assert summary["sequences_ordered"]

    # It read the session back and saw the public projection only.
    assert summary["inspect_members"] == [
             "active_context_token_budget",
             "active_run_id",
             "cleanup_grace_ms",
             "event_sequence",
             "open_interaction",
             "pending_work_ids",
             "status"
           ]

    assert summary["event_sequence_is_string"]

    # A refusal did not cost it the connection.
    assert summary["unknown_method_code"] == "unsupported_method"
    assert summary["survived_refusal"]
  end

  test "an independent client selects a skill, answers the question and reads what the tool kept" do
    node_executable = System.find_executable("node")

    if is_nil(node_executable) do
      flunk("Node is required for the independent client workflow and was not found")
    end

    {output, status} =
      System.cmd(
        node_executable,
        [
          client("interaction-workflow.mjs"),
          System.find_executable("elixir") || flunk("Elixir executable unavailable"),
          ebin(:loopex_protocol),
          ebin(:loopex),
          ebin(:loopex_app_server),
          ebin(:telemetry)
        ] ++ require_paths(),
        env: [{"LOOPEX_WORKSPACE_REF", "workspace-ref"} | child_environment()],
        stderr_to_stdout: false
      )

    assert status == 0, "the independent client failed: #{output}"

    summary = decode(output)
    refute Map.has_key?(summary, "failed"), "the client reported: #{summary["failed"]}"

    # Before a trust decision the catalog names the launched manifest and
    # withholds everything else. The workspace reference the decision must carry
    # is not among the fields a client can read, so it cannot admit its own
    # trust from what the server told it.
    assert summary["catalog_before"]["disposition"] == "no_decision"
    assert summary["catalog_before"]["entries"] == 0
    assert is_nil(summary["catalog_before"]["admitted"])
    refute summary["catalog_before"]["names_workspace"]

    # The client relayed the operator's decision and the runtime admitted it as
    # a durable command.
    assert summary["admission_accepted"]

    # Only then did the catalog describe the skill, and the client selected it
    # using the identity and pack digest the catalog gave it.
    assert summary["catalog_after"]["disposition"] == "active"
    assert summary["catalog_after"]["entries"] == 1
    assert summary["catalog_after"]["names"] == ["writer"]
    assert summary["skill_selected"] == "writer"
    assert String.match?(summary["skill_pack_digest"], ~r/\A[0-9a-f]{64}\z/)

    # The host policy asked rather than allowing, and the question reached the
    # client with its exact wording and its offered choices.
    assert summary["question_prompt"] == "May the tool write the file?"
    assert summary["choice_ids"] == ["allow", "deny"]
    assert is_binary(summary["interaction_id"])

    # The client answered with one of those identities and the runtime admitted
    # it as a durable command.
    assert summary["answer_accepted"]
    assert summary["resolution"] in ["allowed", "resolved", "answered"]

    # Only after that answer committed did the policy mint an allow and the
    # tool run. The client never decided anything.
    assert summary["tool_finished"]
    assert "interaction.requested" in summary["event_kinds"]
    assert "interaction.resolved" in summary["event_kinds"]
    assert "tool.finished" in summary["event_kinds"]
    assert "run.finished" in summary["event_kinds"]

    # The tool kept an artifact, and the client read it back over the wire in a
    # verified bounded transfer rather than being handed a path.
    assert summary["artifacts"] == 1
    assert summary["transfer_opened"]
    assert summary["total_size"] == "23"
    assert summary["chunk_bytes"] == 23
    assert summary["chunk_has_digest"]
    assert summary["transfer_closed"]

    # The request came before the resolution, and the tool after both.
    kinds = summary["event_kinds"]

    assert index_of(kinds, "interaction.requested") < index_of(kinds, "interaction.resolved")
    assert index_of(kinds, "interaction.resolved") < index_of(kinds, "tool.finished")
  end

  test "the client library and workflow are plain source with no package manifest" do
    for name <- ["loopex-client.mjs", "workflow.mjs", "interaction-workflow.mjs"] do
      assert File.regular?(client(name))
    end

    directory = Path.dirname(client("workflow.mjs"))

    # The maintainer chose a client with no second package manager, so there is
    # nothing here to install and nothing to lock.
    refute File.exists?(Path.join(directory, "package.json"))
    refute File.exists?(Path.join(directory, "package-lock.json"))
    refute File.exists?(Path.join(directory, "node_modules"))

    # And nothing it imports comes from outside Node itself or this directory.
    source =
      ["loopex-client.mjs", "workflow.mjs", "interaction-workflow.mjs"]
      |> Enum.map_join("\n", &File.read!(client(&1)))

    imports =
      Regex.scan(~r/from "([^"]+)"/, source)
      |> Enum.map(fn [_whole, target] -> target end)
      |> Enum.uniq()

    assert Enum.all?(imports, fn target ->
             String.starts_with?(target, "node:") or String.starts_with?(target, "./")
           end),
           "unexpected imports: #{inspect(imports)}"
  end

  test "the Node consumer completes skill answer reevaluation grant tool artifact and abrupt restart from operator input against the shipped server" do
    node_executable = System.find_executable("node")

    if is_nil(node_executable) do
      flunk("Node is required for the independent client workflow and was not found")
    end

    %{environment: environment, store: store} = durable_environment()

    # Every input the client needs it is given: the workspace reference the
    # trust decision must carry, and where the session lives. It invents
    # neither, and it cannot read either from the server.
    operator_inputs =
      environment
      |> Keyword.new(fn {key, value} -> {String.to_atom(key), value} end)
      |> Keyword.take([:LOOPEX_HOME, :LOOPEX_WORKSPACE, :LOOPEX_WORKFLOW_STORE])

    assert Keyword.fetch!(operator_inputs, :LOOPEX_WORKFLOW_STORE) == store

    {output, status} =
      System.cmd(
        node_executable,
        [
          client("interaction-workflow.mjs"),
          System.find_executable("elixir") || flunk("Elixir executable unavailable"),
          ebin(:loopex_protocol),
          ebin(:loopex),
          ebin(:loopex_app_server),
          ebin(:loopex_store_local),
          ebin(:telemetry)
        ] ++ require_paths(),
        env: [{"LOOPEX_WORKSPACE_REF", "workspace-ref"} | environment],
        stderr_to_stdout: false
      )

    assert status == 0, "the independent client failed: #{output}"

    summary = decode(output)
    refute Map.has_key?(summary, "failed"), "the client reported: #{summary["failed"]}"

    # The whole chain, in one run, driven from outside: a skill found and
    # selected under an operator's trust decision, a question the host asked
    # rather than an allow, an answer relayed, the authorization minted only
    # afterwards, the tool finishing, and its artifact read back in a verified
    # bounded transfer.
    assert summary["catalog_before"]["entries"] == 0
    assert summary["admission_accepted"]
    assert summary["skill_selected"] == "writer"
    assert summary["question_prompt"] == "May the tool write the file?"
    assert summary["answer_accepted"]
    assert summary["tool_finished"]
    assert summary["artifacts"] == 1
    assert summary["transfer_opened"]
    assert summary["chunk_has_digest"]
    assert summary["transfer_closed"]

    # And then the server was killed rather than closed. What the successor
    # reports survived because it was already durable when the first process
    # died, not because anything was tidied up on the way out.
    assert summary["restarted"], "the client never restarted the server"
    assert summary["resume_refused"] == false, "the resume was refused: #{inspect(summary)}"
    assert summary["reattached"], "the successor could not attach after an abrupt loss"
    assert summary["session_known_after_restart"]

    # The Store outlived both processes, which is what made the second one a
    # successor rather than a fresh start.
    assert File.exists?(store)
  end

  @tag timeout: 600_000
  test "a fresh extraction of the exact source candidate follows the operator guide to build and run the server and Node consumer with operator supplied inputs" do
    node_executable = System.find_executable("node") || flunk("Node is unavailable")
    elixir = System.find_executable("elixir") || flunk("Elixir is unavailable")
    mix = System.find_executable("mix") || flunk("Mix is unavailable")

    root = repository_root()
    {committed, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: root)
    committed = String.trim(committed)

    {dirty, 0} = System.cmd("git", ["status", "--porcelain"], cd: root)

    assert dirty == "",
           "the tree is not the committed candidate; extracting it would prove nothing: #{dirty}"

    workspace =
      Path.join(System.tmp_dir!(), "loopex-extract-#{System.unique_integer([:positive])}")

    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf(workspace) end)

    # The archive is staged from the exact committed revision, not from the
    # working tree, so what is built is what a reader could fetch by that name.
    archive = Path.join(workspace, "source.tar")

    {_output, 0} =
      System.cmd("git", ["archive", "--format=tar", "-o", archive, committed], cd: root)

    archive_digest =
      archive |> File.read!() |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)

    assert String.match?(archive_digest, ~r/\A[0-9a-f]{64}\z/)

    extracted = Path.join(workspace, "source")
    File.mkdir_p!(extracted)
    {_output, 0} = System.cmd("tar", ["-xf", archive, "-C", extracted])

    # It is an extraction, not the checkout: no build, no dependencies, and no
    # Git directory travel with it.
    refute File.exists?(Path.join(extracted, "_build"))
    refute File.exists?(Path.join(extracted, "deps"))
    refute File.exists?(Path.join(extracted, ".git"))
    assert File.exists?(Path.join(extracted, "mix.exs"))
    assert File.exists?(Path.join([extracted, "clients", "node", "workflow.mjs"]))

    # Dependencies are supplied rather than fetched, because a build that
    # reached the network would be proving something about the network.
    File.cp_r!(Path.join(root, "deps"), Path.join(extracted, "deps"))

    {build_output, build_status} =
      System.cmd(mix, ["compile"],
        cd: extracted,
        stderr_to_stdout: true,
        env: [{"MIX_ENV", "dev"}]
      )

    assert build_status == 0, "the extracted source did not build: #{build_output}"

    for application <- ~w(loopex_protocol loopex loopex_app_server loopex_store_local) do
      assert File.dir?(Path.join([extracted, "_build", "dev", "lib", application, "ebin"])),
             "#{application} is missing from the extracted build"
    end

    # And then it is run, from that tree, with inputs an operator supplies: the
    # consumer the operator guide names, driving the server the same guide says
    # to launch.
    %{environment: environment} = durable_environment()

    {output, status} =
      System.cmd(
        node_executable,
        [
          Path.join([extracted, "clients", "node", "workflow.mjs"]),
          elixir,
          Path.join([extracted, "_build", "dev", "lib", "loopex_protocol", "ebin"]),
          Path.join([extracted, "_build", "dev", "lib", "loopex", "ebin"]),
          Path.join([extracted, "_build", "dev", "lib", "loopex_app_server", "ebin"]),
          Path.join([extracted, "_build", "dev", "lib", "loopex_store_local", "ebin"]),
          Path.join([extracted, "_build", "dev", "lib", "telemetry", "ebin"]),
          Path.join([extracted, "apps", "loopex", "test", "support", "m1_runtime_helper.exs"]),
          Path.join([extracted, "apps", "loopex", "test", "support", "agent_loop_helper.exs"]),
          Path.join([
            extracted,
            "apps",
            "loopex_app_server",
            "test",
            "support",
            "fixture_server.exs"
          ])
        ],
        env: Keyword.drop(environment, ["LOOPEX_WORKFLOW_SCRIPT", "LOOPEX_WORKFLOW_STORE"]),
        stderr_to_stdout: false
      )

    assert status == 0, "the extracted consumer failed: #{output}"

    summary = decode(output)

    refute Map.has_key?(summary, "failed"),
           "the extracted consumer reported: #{summary["failed"]}"

    assert summary["session_created"]
    assert summary["event_kinds"] != [], "the extracted consumer observed nothing"
    assert "run.finished" in summary["event_kinds"]
  end

  test "stdin EOF performs orderly shutdown without cancellation and the pending interaction survives restart" do
    %{environment: environment, store: store} = durable_environment()

    # First process: drive the session to a question the host policy asked, then
    # close standard input and nothing else.
    first = launch(environment)
    session_id = create_and_prompt(first)
    interaction = await_record(first, "interaction.requested")

    assert is_binary(interaction["interaction_id"])

    Port.close(first)

    # An orderly shutdown releases the Store's writer claim. A process that had
    # been killed would leave it held, and the second server below would refuse
    # to start rather than reporting anything about the session.
    await_release(store)

    # A second process over the same Store. The session is still there, the
    # question is still open, and nothing recorded a cancellation: closing a pipe
    # is not a decision about a run.
    second = launch(environment)

    resumed =
      request(second, %{
        "method" => "session.resume",
        "request_id" => "rs1",
        "session_id" => session_id,
        "command_id" => encode("crs")
      })

    assert resumed["type"] != "error", "the session did not resume: #{inspect(resumed)}"

    # Recovery re-arms the question as part of resuming, and the attachment's
    # snapshot is anchored rather than live, so this reattaches until the
    # recovered state is the state it reports. Waiting is the test's patience,
    # not a verdict about the session.
    open_interaction = await_open_interaction(second, session_id)

    assert is_map(open_interaction), "the question did not survive the restart"
    assert open_interaction["interaction_id"] == interaction["interaction_id"]
    assert open_interaction["status"] == "pending"

    Port.close(second)

    # The store outlived both processes, which is what made the restart a
    # restart rather than a new session.
    assert File.exists?(store)
  end

  test "session abort is the only deliberate cancellation and an aborted interaction is never pending after restart" do
    %{environment: environment, store: store} = durable_environment()

    first = launch(environment)
    session_id = create_and_prompt(first)
    interaction = await_record(first, "interaction.requested")

    assert is_binary(interaction["interaction_id"])

    # Abort says what EOF does not: end this run. The question goes with it.
    abort =
      request(first, %{
        "method" => "session.abort",
        "request_id" => "ab",
        "command_id" => encode("cab")
      })

    assert abort["status"] == "accepted", "the abort was #{inspect(abort)}"

    Port.close(first)
    await_release(store)

    # After a restart the question is gone rather than waiting: an aborted
    # interaction never reappears, which is the difference between cancelling a
    # run and losing a connection.
    second = launch(environment)

    resumed =
      request(second, %{
        "method" => "session.resume",
        "request_id" => "rs2",
        "session_id" => session_id,
        "command_id" => encode("crs2")
      })

    assert resumed["type"] != "error", "the session did not resume: #{inspect(resumed)}"

    # The same patience the surviving case uses, spent the other way: the
    # question is given every chance to come back, and must not. Asserting its
    # absence immediately would pass before recovery had finished and prove
    # nothing.
    recovered = await_open_interaction(second, session_id)

    refute is_map(recovered) and recovered["status"] == "pending",
           "an aborted question was pending again: #{inspect(recovered)}"

    Port.close(second)
    assert File.exists?(store)
  end

  # Concept: one isolated home, workspace and durable Store, shared by every
  # process a case launches.
  #
  # Technical depth: a restart across operating-system processes is only a
  # restart if the session outlives the process, so the Store is a real local one
  # on a path both processes are given. It is named in the environment rather
  # than in a frame, because where a session lives is a launch input.
  defp durable_environment do
    root = Path.join(System.tmp_dir!(), "loopex-restart-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "home"))
    File.mkdir_p!(Path.join(root, "workspace"))
    on_exit(fn -> File.rm_rf(root) end)

    store = Path.join(root, "store.log")

    environment = [
      {"LOOPEX_HOME", Path.join(root, "home")},
      {"LOOPEX_WORKSPACE", Path.join(root, "workspace")},
      {"LOOPEX_WORKFLOW_SCRIPT", "tool"},
      {"LOOPEX_WORKFLOW_STORE", store},
      {"ELIXIR_ERL_OPTIONS", "-noinput"}
    ]

    %{environment: environment, store: store}
  end

  defp launch(environment) do
    elixir = System.find_executable("elixir") || flunk("Elixir executable unavailable")

    arguments =
      ["-pa", ebin(:loopex_protocol), "-pa", ebin(:loopex), "-pa", ebin(:loopex_app_server)] ++
        ["-pa", ebin(:loopex_store_local), "-pa", ebin(:telemetry)] ++
        Enum.flat_map(require_paths(), &["-r", &1]) ++
        ["-e", "Loopex.AppServer.Fixture.serve()"]

    port =
      Port.open({:spawn_executable, elixir}, [
        :binary,
        :exit_status,
        args: arguments,
        env: for({key, value} <- environment, do: {to_charlist(key), to_charlist(value)})
      ])

    initialized = request(port, %{"method" => "initialize", "request_id" => "i1"})
    assert initialized["type"] == "initialized"
    port
  end

  defp create_and_prompt(port) do
    created =
      request(port, %{
        "method" => "session.create",
        "request_id" => "c1",
        "command_id" => encode("cs")
      })

    assert created["status"] == "accepted"
    session_id = created["session_id"]

    attached = attach(port, session_id)
    assert attached["type"] == "snapshot"

    prompted =
      request(port, %{
        "method" => "session.prompt",
        "request_id" => "p1",
        "command_id" => encode("cp"),
        "content_b64" => Base.url_encode64("write the file", padding: false)
      })

    assert prompted["status"] == "accepted"
    session_id
  end

  defp attach(port, session_id) do
    request(port, %{
      "method" => "session.attach",
      "request_id" => "a#{System.unique_integer([:positive])}",
      "session_id" => session_id,
      "replace" => true
    })
  end

  # Concept: one request, and the first record that answers it.
  #
  # Technical depth: events arrive unasked between an answer and the next
  # request, so a reader that took the next line would sometimes read one. This
  # keeps reading until a record carries the identity it asked under.
  defp request(port, frame) do
    request_id = Map.fetch!(frame, "request_id")
    {:ok, encoded} = Frame.encode(negotiation(frame))
    Port.command(port, IO.iodata_to_binary(encoded))
    await_reply(port, request_id, System.monotonic_time(:millisecond) + 20_000)
  end

  # An initialize frame carries both negotiation members; every other frame
  # carries neither, because a member a method does not name is not an input.
  defp negotiation(%{"method" => "initialize"} = frame) do
    frame
    |> Map.put("generations", [Session.generation()])
    |> Map.put("capabilities", [])
  end

  defp negotiation(frame), do: frame

  defp await_reply(port, request_id, deadline) do
    record = next_record(port, deadline)

    if record["request_id"] == request_id do
      record
    else
      await_reply(port, request_id, deadline)
    end
  end

  defp await_record(port, kind, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + 20_000
    record = next_record(port, deadline)

    cond do
      record["type"] == "event" and record["event"]["kind"] == kind -> record["event"]["data"]
      true -> await_record(port, kind, deadline)
    end
  end

  defp next_record(port, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)
    if remaining <= 0, do: flunk("the server said nothing in time")

    receive do
      {^port, {:data, chunk}} ->
        lines = chunk |> String.split("\n", trim: true)

        case lines do
          [] ->
            next_record(port, deadline)

          [line | rest] ->
            Enum.each(rest, fn extra -> send(self(), {port, {:data, extra <> "\n"}}) end)
            {:ok, record} = Frame.decode(line, 2_097_152)
            record
        end

      {^port, {:exit_status, status}} ->
        flunk("the server exited with #{status}")
    after
      remaining -> flunk("the server said nothing in time")
    end
  end

  defp encode(value), do: Base.url_encode64(value, padding: false)

  # Concept: the open question a restarted server reports, once it has finished
  # recovering.
  #
  # Technical depth: resuming re-arms a pending interaction, and an attachment's
  # snapshot is anchored at a cursor rather than following the session, so a
  # single attach can read the moment before recovery completed. This reattaches
  # until one reports a question or the patience runs out, and returns whatever
  # the last snapshot said either way, so a case asserting absence waits exactly
  # as long as one asserting presence.
  defp await_open_interaction(port, session_id, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + 10_000
    snapshot = attach(port, session_id)

    assert snapshot["type"] == "snapshot", "the restart could not attach: #{inspect(snapshot)}"

    open_interaction = snapshot["open_interaction"]

    cond do
      is_map(open_interaction) ->
        open_interaction

      System.monotonic_time(:millisecond) > deadline ->
        open_interaction

      true ->
        Process.sleep(100)
        await_open_interaction(port, session_id, deadline)
    end
  end

  # Concept: waiting until the Store has no writer.
  #
  # Technical depth: the local Store claims a writer beside its log and releases
  # it when the owning process ends. Waiting for that release is how a case knows
  # the first server actually finished rather than merely stopped being spoken
  # to, and it is also what makes the second server's start meaningful: a Store
  # still claimed refuses a second writer outright.
  defp await_release(store, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + 30_000
    claim = store <> ".writer"

    cond do
      not File.exists?(claim) ->
        :released

      System.monotonic_time(:millisecond) > deadline ->
        flunk("the Store's writer claim was still held after an orderly shutdown")

      true ->
        Process.sleep(25)
        await_release(store, deadline)
    end
  end

  defp client(name), do: Path.join([repository_root(), "clients", "node", name])

  defp index_of(list, value), do: Enum.find_index(list, &(&1 == value))

  defp repository_root do
    Path.expand(Path.join([__DIR__, "..", "..", ".."]))
  end

  defp ebin(application) do
    path = Application.app_dir(application, "ebin")
    assert File.dir?(path)
    path
  end

  # Concept: the environment the server child runs under.
  #
  # Technical depth: a fresh isolated state root per run, and the helper files
  # required before the entry point so the fixture's own modules exist when it
  # is called. The state root is passed rather than inherited, because a server
  # that fell back to real user state would be a far worse failure than a test
  # that could not start.
  defp child_environment do
    root = Path.join(System.tmp_dir!(), "loopex-workflow-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "home"))
    File.mkdir_p!(Path.join(root, "workspace"))
    on_exit(fn -> File.rm_rf(root) end)

    [
      {"LOOPEX_HOME", Path.join(root, "home")},
      {"LOOPEX_WORKSPACE", Path.join(root, "workspace")},
      {"ELIXIR_ERL_OPTIONS", "-noinput"}
    ]
  end

  defp require_paths do
    support = Path.join([repository_root(), "apps", "loopex", "test", "support"])
    own = Path.join([repository_root(), "apps", "loopex_app_server", "test", "support"])

    [
      Path.join(support, "m1_runtime_helper.exs"),
      Path.join(support, "agent_loop_helper.exs"),
      Path.join(own, "fixture_server.exs")
    ]
  end

  # Concept: the client's own summary line, read with this protocol's decoder.
  #
  # Technical depth: decoded by the same decoder the server uses, because the
  # repository carries no JSON library and because the summary is one bounded
  # object like every other record on this wire.
  defp decode(output) do
    {:ok, decoded} =
      output
      |> String.split("\n", trim: true)
      |> List.last()
      |> LoopexProtocol.Frame.decode(2_097_152)

    decoded
  end
end
