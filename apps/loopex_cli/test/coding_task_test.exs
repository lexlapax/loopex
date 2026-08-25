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
    refute resolved == Path.expand(System.get_env("LOOPEX_WORKSPACE"))
    assert String.starts_with?(resolved, Path.expand(System.tmp_dir!()))

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

    prompt =
      "In notes.md, replace the text \"first line\" with \"edited line\". " <>
        "Then create summary.txt containing exactly the text edited line followed by a newline. " <>
        "Then run cat notes.md to verify, and say what it printed."

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
                        "allow-all",
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

    # The operator sees the committed result: the bytes on disk changed.
    assert File.read!(Path.join(workspace, "notes.md")) =~ "edited line"
    assert File.read!(Path.join(workspace, "summary.txt")) =~ "edited line"

    # Several turns, several distinct tools, including one edit and one shell.
    assert transcript =~ "loopex.edit"
    assert transcript =~ "loopex.bash"
    assert transcript =~ "loopex: done"
    assert answer =~ "edited line"

    replies = real_replies(state_root)

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

    report_real_path(
      [%{"identity" => stringify(reply.identity)}],
      record
    )
  end

  # Concept: put the observed identifiers where a person can retain them.
  #
  # Technical depth: the attestation record this milestone keeps is written by a
  # person from an attended run, and the identifiers it carries have to come from
  # the run rather than from a reconstruction. Emitting them on the diagnostic
  # stream is how an attended run hands them over; nothing here writes to a
  # tracked file, because a case that wrote its own evidence would be attesting
  # to itself.
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

    report = %{
      "provider" => identity["provider"],
      "model" => identity["model"],
      "endpoint" => identity["endpoint"],
      "adapter_build" => "loopex_llm_reqllm@#{Loopex.version()}"
    }

    if Code.ensure_loaded?(Loopex.M1Gate.RealPathEvidence) do
      assert :ok = apply(Loopex.M1Gate.RealPathEvidence, :report, [report])
    else
      :ok
    end
  end

  defp stringify(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
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
