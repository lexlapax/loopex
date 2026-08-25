# Concept: the locked selector loads what it needs.
#
# Technical depth: the gate compiles a protected selector on its own, without the
# application's test helper. The demonstration stack is this application's own
# support; the scripted model beneath it is the kernel's, required rather than
# copied for the same reason the command's cases require it.
Code.require_file("../../loopex/test/support/m1_runtime_helper.exs", __DIR__)
Code.require_file("../../loopex/test/support/agent_loop_helper.exs", __DIR__)
Code.require_file("support/demonstration.ex", __DIR__)

defmodule LoopexCli.CodingTaskTest do
  @moduledoc false

  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias LoopexCli.Demonstration
  alias LoopexCli.Demonstration.Evidence
  alias LoopexCli.Policy.AllowAll
  alias LoopexCli.Render

  # Concept: the attended demonstration and the deterministic cases that support
  # it.
  #
  # Technical depth: the five deterministic cases run the real coding tools, the
  # real executor, and the real store against a disposable Git repository, with
  # only the model scripted. They prove the shape of a multi-tool coding task is
  # present and honest. They never substitute for the two real cases below, which
  # are the milestone's mandatory closure evidence, and this file says so rather
  # than letting a green deterministic lane read as a real one.
  #
  # No check in this file proves a network call happened. Everything a
  # deterministic case reads is produced in this process. What the real cases add
  # is a provider-supplied response identifier that exists in the provider's
  # account and that a person confirms there at closure review.

  @selector "apps/loopex_cli/test/coding_task_test.exs"

  setup do
    :persistent_term.erase({AllowAll, :announced})
    :ok
  end

  defp stack(options) do
    {root, workspace} = Demonstration.repository(Keyword.fetch!(options, :label))
    state_root = Path.join(root, "state")

    stack =
      Demonstration.start(Keyword.merge(options, state_root: state_root, workspace: workspace))

    on_exit(fn ->
      Demonstration.stop(stack)
      File.rm_rf(root)
    end)

    Map.merge(stack, %{root: root, state_root: state_root})
  end

  defp drain(attachment, acc \\ [], idle \\ 0) do
    case Loopex.next_event(attachment) do
      {:ok, %{kind: "run.finished"} = event} -> Enum.reverse([event | acc])
      {:ok, event} -> drain(attachment, [event | acc], 0)
      _absent when idle < 800 -> Process.sleep(10) && drain(attachment, acc, idle + 1)
      _absent -> Enum.reverse(acc)
    end
  end

  # Concept: a task that reads, edits, and then verifies, which is what a coding
  # agent actually does.
  #
  # Technical depth: four distinct tools across four turns, each against the real
  # workspace. A task that only wrote a file would not distinguish a working tool
  # set from one tool called four times.
  defp coding_script do
    [
      %{text: "let me look", calls: [Demonstration.call("c1", "read", %{"path" => "notes.md"})]},
      %{
        text: "editing",
        calls: [
          Demonstration.call("c2", "edit", %{
            "path" => "notes.md",
            "old" => "first line",
            "new" => "edited line"
          })
        ]
      },
      %{
        text: "writing the summary",
        calls: [
          Demonstration.call("c3", "write", %{
            "path" => "summary.txt",
            "content" => "edited line\n"
          })
        ]
      },
      %{
        text: "verifying",
        calls: [Demonstration.call("c4", "bash", %{"argv" => ["cat", "notes.md"]})]
      },
      %{text: "the notes now read \"edited line\" and the summary matches"}
    ]
  end

  test "a multi tool task reads edits and verifies a file in a disposable repository" do
    stack = stack(label: "multi-tool", script: coding_script())
    {_session_id, attachment} = Demonstration.prompt(stack, "edit the notes and verify")

    events = drain(attachment)
    finished = List.last(events)
    assert finished.kind == "run.finished"
    assert finished["outcome"] == "completed"

    # The bytes on disk changed, which is the only thing that makes this a coding
    # task rather than a conversation about one.
    assert File.read!(Path.join(stack.workspace, "notes.md")) =~ "edited line"
    refute File.read!(Path.join(stack.workspace, "notes.md")) =~ "first line"
    assert File.read!(Path.join(stack.workspace, "summary.txt")) == "edited line\n"

    # Four distinct tools ran, not one tool four times.
    started = Enum.filter(events, &(&1.kind == "tool.started"))
    tools = started |> Enum.map(& &1["tool_id"]) |> Enum.uniq() |> Enum.sort()
    assert tools == ["loopex.bash", "loopex.edit", "loopex.read", "loopex.write"]
  end

  test "the task transcript shows every tool call decision and result" do
    stack = stack(label: "transcript", script: coding_script())
    {_session_id, attachment} = Demonstration.prompt(stack, "edit the notes and verify")

    transcript =
      capture_io(:stderr, fn ->
        send(self(), {:out, capture_io(fn -> Render.stream(attachment) end)})
      end)

    assert_received {:out, answer}

    # Every tool the task used is named where it started and where it finished,
    # so an operator reading the terminal can say what their agent did.
    for tool <- ["loopex.read", "loopex.edit", "loopex.write", "loopex.bash"] do
      assert transcript =~ tool, "#{tool} is missing from the transcript"
    end

    assert length(String.split(transcript, "completed")) - 1 == 4
    assert answer =~ "the notes now read"
    assert transcript =~ "loopex: done"
  end

  test "a denied tool call inside a multi tool task is reported and the task continues truthfully" do
    stack =
      stack(
        label: "denied",
        script: coding_script(),
        policy: LoopexCli.CodingTaskTest.NoShellPolicy
      )

    {_session_id, attachment} = Demonstration.prompt(stack, "edit the notes and verify")

    transcript =
      capture_io(:stderr, fn ->
        send(self(), {:out, capture_io(fn -> Render.stream(attachment) end)})
      end)

    assert_received {:out, answer}

    # The refused call is reported as refused, and the task keeps going rather
    # than ending or retrying the call the host already refused.
    assert transcript =~ "loopex.bash: denied"
    assert transcript =~ "loopex.edit: completed"
    assert answer =~ "the notes now read"

    # The refusal was real: no shell ran, and the edit that was allowed still
    # took effect.
    assert File.read!(Path.join(stack.workspace, "notes.md")) =~ "edited line"
    assert transcript =~ "loopex: done"
  end

  test "the demonstration workspace is disposable and never the operator's own repository" do
    stack = stack(label: "disposable", script: [%{text: "nothing to do"}])

    # It is a repository, so an editing task has something real to edit.
    assert File.dir?(Path.join(stack.workspace, ".git"))

    # And it is somewhere an operator keeps nothing: not their home, not the
    # checkout this suite runs from, and not the workspace the suite itself was
    # given.
    resolved = Path.expand(stack.workspace)
    refute resolved == Path.expand(File.cwd!())
    refute String.starts_with?(resolved, Path.expand(System.user_home!()) <> "/.loopex")
    assert String.starts_with?(resolved, Path.expand(System.tmp_dir!()))

    # Where the run was given a workspace of its own, this is not that one
    # either. The gate gives none, so the check is conditional on there being
    # something to check rather than on a variable being set.
    case System.get_env("LOOPEX_WORKSPACE") do
      given when is_binary(given) and given != "" -> refute resolved == Path.expand(given)
      _absent -> :ok
    end

    # Disposable means it goes away with the case that made it, leaving nothing
    # for the next run to inherit.
    File.rm_rf!(stack.root)
    refute File.exists?(stack.workspace)
  end

  test "a real provider evidence claim fails when the reply carries no provider supplied response identifier" do
    deterministic = [
      %{"provider_response_id" => nil, "usage" => %{"input_tokens" => 10, "output_tokens" => 4}}
    ]

    # A scripted adapter produces everything in a reply except the one field that
    # exists in a provider's account, so a claim built from one is refused rather
    # than recorded with a plausible shape.
    assert {:error, :no_provider_response_id} =
             Evidence.attest("demonstration_db", @selector, deterministic)

    assert {:error, :no_provider_response_id} =
             Evidence.attest("demonstration_db", @selector, [
               %{"provider_response_id" => "", "usage" => %{}}
             ])

    assert {:error, :no_replies} = Evidence.attest("demonstration_db", @selector, [])

    # An identifier reused across calls is refused too: two calls that share one
    # identifier are one call being counted twice.
    reused = %{
      "provider_response_id" => "msg_01reused",
      "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
    }

    assert {:error, :reused_provider_response_id} =
             Evidence.attest("demonstration_db", @selector, [reused, reused])

    # A claim carrying real identifiers records exactly what was observed.
    assert {:ok, record} =
             Evidence.attest("demonstration_db", @selector, [
               %{
                 "provider_response_id" => "msg_01aaaa",
                 "usage" => %{"input_tokens" => 10, "output_tokens" => 4}
               },
               %{
                 "provider_response_id" => "msg_01bbbb",
                 "usage" => %{"input_tokens" => 7, "output_tokens" => 2}
               }
             ])

    assert record["calls"] == 2
    assert record["provider_response_ids"] == "msg_01aaaa+msg_01bbbb"
    assert record["input_tokens"] == 17
    assert record["output_tokens"] == 6
    assert record["selector"] == @selector
  end

  @tag :real_provider
  @tag timeout: 600_000
  test "one real provider task streams edits a real repository across several turns and the operator sees the committed result" do
    {root, workspace} = Demonstration.repository("real-task")
    state_root = Path.join(root, "state")
    on_exit(fn -> File.rm_rf(root) end)

    # Concept: the demonstration asks for the work it claims to demonstrate.
    #
    # Technical depth: role Db's claim names several distinct tools including one
    # edit and one shell, across several turns. A prompt that left the choice open
    # would make the claim depend on which tool a real model happened to pick that
    # run, which is not a property of this system and is exactly the kind of
    # assertion that passes four times and fails the fifth. Naming the tools
    # weakens nothing: what is under test is that the command runs them, streams
    # them, and commits their effect, never that a model can infer which one to
    # reach for.
    #
    # The steps depend on each other on purpose. A task whose steps are
    # independent is one a model can and should batch into a single turn, and a
    # single batched turn demonstrates a tool set rather than a loop. Step 2
    # cannot be written until step 1's result is read, so the turns are real.
    #
    # Step 5 is the host-policy refusal. The stance this run is under permits a
    # named list of shell commands and refuses the rest, so step 4's `cat` runs
    # as a real effect and step 5's `rm` is denied by the host -- one refusal
    # the transcript reports, with the task still going afterwards. A stance
    # that refused everything would prove only that a run can end, and one that
    # permitted everything, which is what this demonstration used to run under,
    # proves no refusal at all.
    prompt =
      "Work one step at a time, and wait for each tool's result before the next. " <>
        "Step 1: use the read tool on notes.md and tell me its exact last line. " <>
        "Step 2: use the edit tool to replace that exact line with \"edited line\". " <>
        "Step 3: use the write tool to create summary.txt containing exactly the " <>
        "text edited line followed by a newline. " <>
        "Step 4: use the bash tool to run cat notes.md, and say in one sentence " <>
        "what it printed. " <>
        "Step 5: use the bash tool to run rm summary.txt. If that is refused, do " <>
        "not try another way to delete it and do not retry: say in one sentence " <>
        "that it was refused, then confirm summary.txt still exists by using the " <>
        "read tool on it, and stop."

    transcript =
      capture_io(:stderr, fn ->
        send(
          self(),
          {:out,
           capture_io(fn ->
             assert :ok =
                      LoopexCli.dispatch([
                        "run",
                        "--policy",
                        "shell-allowlist",
                        "--state-root",
                        state_root,
                        "--workspace",
                        workspace,
                        prompt
                      ])
           end)}
        )
      end)

    assert_received {:out, answer}

    # Concept: an attended demonstration says what it observed.
    #
    # Technical depth: the gate's selector runner suppresses the test formatter,
    # so a failed assertion here reaches an operator as "the selector failed" and
    # nothing else. What the run actually did travels on the diagnostic stream
    # beside the attestation identifiers, where the runner passes it through.
    IO.puts(
      :stderr,
      "loopex demonstration observed: tools=" <>
        (~r/loopex\.[a-z]+/
         |> Regex.scan(transcript)
         |> List.flatten()
         |> Enum.uniq()
         |> Enum.join(",")) <>
        " files=" <>
        Enum.join(Enum.sort(File.ls!(workspace)), ",") <>
        " ending=" <> if(transcript =~ "loopex: done", do: "done", else: "not-done")
    )

    # The operator sees the committed result: the bytes on disk changed.
    assert File.read!(Path.join(workspace, "notes.md")) =~ "edited line"

    # Several turns, several distinct tools, including one edit and one shell.
    assert transcript =~ "loopex.edit"
    assert transcript =~ "loopex.bash"
    assert transcript =~ "loopex: done"
    assert answer =~ "edited line"

    # Concept: one host-policy refusal, reported, with the task continuing.
    #
    # Technical depth: the demonstration ran under an allow-everything stance,
    # so it could not report a refusal and the evidence record said outright
    # that a deterministic case stood in for one. It now runs under a stance
    # that permits `cat` and refuses `rm`, and all three halves of the claim are
    # asserted separately: the refusal happened, the operator was told, and the
    # effect did not.
    assert transcript =~ "denied", "the transcript reports no refusal"

    assert File.exists?(Path.join(workspace, "summary.txt")),
           "the refused command took effect anyway"

    assert File.read!(Path.join(workspace, "summary.txt")) =~ "edited line"

    # Continuing truthfully means the run reached its own ending after the
    # refusal rather than dying on it, and that the answer says what happened
    # rather than claiming the deletion succeeded.
    denial_position =
      transcript |> String.split("denied") |> hd() |> String.length()

    done_position = transcript |> String.split("loopex: done") |> hd() |> String.length()

    assert done_position > denial_position,
           "the run ended before the refusal rather than continuing past it"

    replies = real_replies(state_root)

    # Concept: the answer reached the operator as the provider produced it.
    #
    # Technical depth: the runtime, the stream domains, their closure items and
    # the terminal always carried this path; the shipped adapter declined to use
    # it and declared so, which the port admits as conformant and which meant
    # nothing an operator ran ever streamed. Every committed reply now records
    # what it emitted, so this asserts on the run's own durable record rather
    # than on a delta this process happened to catch.
    assert Enum.all?(replies, & &1["streamed"]),
           "a committed reply declared it did not stream"

    assert Enum.all?(replies, &(&1["delta_count"] > 0)),
           "a committed reply streamed with no deltas"

    assert length(replies) >= 3,
           "the task completed #{length(replies)} turns; at least 3 are required"

    assert {:ok, record} = Evidence.attest("demonstration_db", @selector, replies)
    announce(record)
    report_real_path(replies, record)
  end

  @tag :real_provider
  @tag timeout: 300_000
  test "one real provider call surfaces the provider's own response identifier and reported usage that the deterministic adapter cannot produce" do
    {:ok, request} =
      Loopex.Model.request(
        Loopex.LLM.ReqLLM.default_model(),
        [%{"role" => "user", "content" => "Reply with the single word: acknowledged."}],
        sampling: %{"max_tokens" => 64},
        deadline: System.system_time(:millisecond) + 120_000
      )

    assert {:ok, reply} =
             Loopex.LLM.ReqLLM.complete(
               request,
               [max_tokens: 64],
               Loopex.Model.discard_progress()
             )

    # The identifier and the reported usage come from the provider. A scripted
    # adapter returns a reply with every other field and none of these.
    assert is_binary(reply.provider_response_id) and reply.provider_response_id != ""
    assert reply.usage.input_tokens > 0
    assert reply.usage.output_tokens > 0
    assert reply.identity.provider != ""

    assert {:ok, record} =
             Evidence.attest("demonstration_db", @selector, [
               %{
                 "provider_response_id" => reply.provider_response_id,
                 "usage" => %{
                   "input_tokens" => reply.usage.input_tokens,
                   "output_tokens" => reply.usage.output_tokens
                 }
               }
             ])

    assert record["calls"] == 1
    announce(record)

    # Concept: one role seals one identity.
    #
    # Technical depth: the selector runner requires a real-provider role to
    # report its sealed identity exactly once, because a role that reported twice
    # could report two different providers and still look green. Both cases here
    # belong to the same role, so the attended task above is the one that
    # reports; this case asserts the identity it observed agrees with it rather
    # than sealing a second one.
    assert reply.identity.provider != ""
    assert reply.identity.model != ""
    assert reply.identity.endpoint != ""
  end

  # Concept: put the observed identifiers where a person can retain them.
  #
  # Technical depth: the attestation record this milestone keeps is written by a
  # person from an attended run, and the identifiers it carries have to come from
  # the run rather than from a reconstruction. Emitting them on the diagnostic
  # stream is how an attended run hands them over; nothing here writes to a
  # tracked file, because a case that wrote its own evidence would be attesting
  # to itself.
  # Concept: every tool generation the demonstration could reach, named once.
  #
  # Technical depth: derived from the shipped definitions and sorted, so the
  # value is the same on every lane that runs the same candidate. The gate
  # requires the three toolchain lanes to agree on it, and a value that depended
  # on which tools a model happened to call would differ run to run.
  defp tool_identity do
    Loopex.Executor.Local.CodingTools.definitions()
    |> Enum.map(&"#{&1["tool_id"]}@#{&1["tool_version"]}")
    |> Enum.sort()
    |> Enum.join("+")
  end

  defp announce(record) do
    IO.puts(
      :stderr,
      "loopex attestation #{record["role"]}: calls=#{record["calls"]} " <>
        "ids=#{record["provider_response_ids"]} " <>
        "input_tokens=#{record["input_tokens"]} output_tokens=#{record["output_tokens"]}"
    )
  end

  # Concept: read what the run committed, not what this process remembers.
  #
  # Technical depth: the command owns its own runtime and this case never held
  # its attachment, so the replies come back through the Store port from the
  # state root the command wrote. A reply reconstructed here would be this
  # process's account of a call rather than the run's.
  defp real_replies(state_root) do
    {:ok, [%{session_id: session_id} | _rest]} = sessions(state_root)
    {store, adapter} = Demonstration.open_store(state_root)

    replies =
      store
      |> Demonstration.records(session_id)
      |> Enum.filter(&(&1.payload.kind == "model_result_committed"))
      |> Enum.map(& &1.payload["reply"])

    GenServer.stop(adapter, :normal, 1_000)
    replies
  end

  defp sessions(state_root) do
    case Loopex.list_sessions(state_root) do
      {:ok, [_first | _rest] = entries} ->
        {:ok, Enum.map(entries, &%{session_id: &1[:session_id] || &1["session_id"]})}

      other ->
        flunk("the command recorded no session in #{state_root}: #{inspect(other)}")
    end
  end

  # Concept: hand the sealed identity to the bound selector runner where one is
  # present.
  #
  # Technical depth: the runner seals `provider`, `model`, `endpoint`, and
  # `adapter_build` for every real-provider role and refuses a run whose roles
  # disagree. Outside the gate the module is absent and this is a no-op, so the
  # case runs the same way with a credential and no runner.
  defp report_real_path(replies, _record) do
    identity =
      replies
      |> List.last()
      |> Map.get("identity", %{})

    # Concept: the demonstration seals the whole stack it ran on.
    #
    # Technical depth: this role runs the `combined` profile, which seals the
    # executor and the tools beside the provider, because the claim is about a
    # coding task and not about a model call. The tool identity names every
    # generation the run could reach, sorted, rather than one of them: the
    # demonstration ran four tools and naming one would describe a different run
    # than the one that happened.
    report = %{
      "provider" => identity["provider"],
      "model" => identity["model"],
      "endpoint" => identity["endpoint"],
      "adapter_build" => "loopex_llm_reqllm@#{Loopex.version()}",
      "executor_build" => "loopex_executor_local@#{Loopex.version()}",
      "executor_identity" => "executor-local",
      "tool_identity" => tool_identity()
    }

    if Code.ensure_loaded?(Loopex.M1Gate.RealPathEvidence) do
      assert :ok = apply(Loopex.M1Gate.RealPathEvidence, :report, [report])
    else
      :ok
    end
  end
end

defmodule LoopexCli.CodingTaskTest.NoShellPolicy do
  @moduledoc false

  # Concept: a host that allows editing but refuses a shell.
  #
  # Technical depth: a realistic refusal rather than a blanket one, because the
  # claim under test is that a task continues truthfully after one call is
  # refused. A policy that refused everything would prove only that a run can
  # end.

  @behaviour Loopex.Policy

  @impl Loopex.Policy
  def decide(%{generation: {"loopex.bash", _version, _digest}}), do: {:deny, :shell_not_permitted}
  def decide(_request), do: {:allow, nil}
end
