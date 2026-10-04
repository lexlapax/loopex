Code.require_file("../../loopex/test/support/m1_runtime_helper.exs", __DIR__)
Code.require_file("../../loopex/test/support/agent_loop_helper.exs", __DIR__)

defmodule LoopexCli.M7FixturePolicyTest do
  use ExUnit.Case, async: false
  @moduletag capture_log: true

  alias LoopexCli.{Chat, ChatConfiguration}
  alias LoopexCli.Policy.M7Fixture, as: Policy
  alias LoopexComposition.WorkspaceIdentity
  alias LoopexProtocol.{Canonical, ToolDefinition}
  alias Mix.Tasks.Loopex.M7Evidence.FixtureManifest

  defmodule PurposeModel do
    @moduledoc false
    @behaviour Loopex.Model

    @impl true
    def complete(request, options, progress) do
      script =
        if request.tools == [],
          do: Keyword.fetch!(options, :maintenance_script),
          else: Keyword.fetch!(options, :script)

      Loopex.AgentLoopTestModel.complete(request, [script: script], progress)
    end
  end

  @fixtures Path.expand("../../../test/fixtures/m7", __DIR__)

  setup do
    root = Path.join(System.tmp_dir!(), "m7-pinned-policy-#{System.unique_integer([:positive])}")
    workspace = Path.join(root, "workspace")
    trusted = Path.join(root, "trusted")
    File.mkdir_p!(trusted)
    File.cp_r!(Path.join(@fixtures, "repair/workspace"), workspace)
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, catalog} = FixtureManifest.load(@fixtures)
    oracle = Path.join(trusted, "oracle.exs")
    File.cp!(Path.join(@fixtures, "repair/oracle.exs"), oracle)

    assert Canonical.digest_bytes(File.read!(oracle)) ==
             catalog["fixtures"]["repair"]["oracle"]["sha256"]

    {:ok, elixir} =
      WorkspaceIdentity.resolve_path(
        Path.expand("../../bin/elixir", List.to_string(:code.lib_dir(:elixir)))
      )

    path =
      Path.dirname(elixir) <>
        ":" <> Path.join(List.to_string(:code.root_dir()), "bin") <> ":/usr/bin:/bin"

    runner = Path.join(trusted, "run.sh")

    File.write!(
      runner,
      "#!/bin/sh\nset -eu\ntest -z \"${M7_FIXTURE_HOST_SENTINEL:-}\"\nexec /usr/bin/env -i PATH=" <>
        shell_quote(path) <>
        " M7_WORKSPACE=" <>
        shell_quote(workspace) <> " " <> shell_quote(elixir) <> " " <> shell_quote(oracle) <> "\n"
    )

    argv = ["/bin/sh", runner]
    pins = Map.new(["/bin/sh", runner, oracle, elixir], &{&1, pin(&1)})
    digest = Canonical.digest_bytes(File.read!(Path.join(@fixtures, "manifest.json")))
    {:ok, capture} = Policy.prepare("m7.repair", digest, workspace, argv, pins)

    profile = %{
      "schema_version" => 1,
      "providers" => %{
        "anthropic" => %{"credential" => %{"env" => "M7_UNUSED_FIXTURE_REFERENCE"}}
      },
      "policy" => "shell-allowlist",
      "paths" => %{"workspace" => workspace, "state_root" => Path.join(root, "state")},
      "session" => %{
        "model" => "anthropic:claude-haiku-4-5",
        "tools" => "coding",
        "system_class_tokens" => 8000,
        "bounds" => %{"max_turns" => 8, "deadline_ms" => 15_000, "token_budget" => 100_000}
      }
    }

    config = Path.join(root, "config.json")
    File.write!(config, :json.encode(profile))

    %{
      root: root,
      workspace: workspace,
      runner: runner,
      oracle: oracle,
      argv: argv,
      pins: pins,
      capture: capture,
      digest: digest,
      config: config,
      profile: profile
    }
  end

  test "only exact argv, current generations and the selected lease permit dispatch", f do
    request = request("loopex.bash", %{"argv" => f.argv})
    assert Policy.decide(request, f.capture) == {:allow, nil}
    assert Policy.decide(request) == {:deny, :policy_unavailable}

    for changed <- [
          %{request | arguments: %{"argv" => f.argv ++ ["extra"]}},
          %{request | arguments: %{"command" => Enum.join(f.argv, " ")}},
          %{request | arguments: %{"argv" => f.argv, "command" => nil}},
          %{request | workspace_lease: "another"},
          %{request | effect_class: "invented"},
          %{request | generation: {"loopex.bash", "old", String.duplicate("0", 64)}}
        ] do
      assert Policy.decide(changed, f.capture) == {:deny, :policy_denied}
    end

    assert {:ok, review} = Policy.prepare("m7.review", f.digest, f.workspace, f.argv, f.pins)

    assert Policy.decide(request("loopex.write", %{"path" => "file", "content" => "x"}), review) ==
             {:deny, :policy_denied}

    assert Policy.decide(request("loopex.read", %{"path" => "lib/ledger.ex"}), review) ==
             {:allow, nil}
  end

  test "changed runner, oracle, modes, targets and incomplete captures fail closed", f do
    original = File.read!(f.runner)
    File.write!(f.runner, original <> "# changed\n")
    assert Policy.check(f.capture) == {:error, :fixture_policy_unavailable}

    assert Policy.decide(request("loopex.bash", %{"argv" => f.argv}), f.capture) ==
             {:deny, :policy_unavailable}

    File.write!(f.runner, original)
    File.chmod!(f.runner, 0o755)
    assert Policy.check(f.capture) == {:error, :fixture_policy_unavailable}
    File.chmod!(f.runner, f.pins[f.runner].mode)
    File.rm!(f.oracle)
    File.ln_s!(Path.join(@fixtures, "repair/oracle.exs"), f.oracle)
    assert Policy.check(f.capture) == {:error, :fixture_policy_unavailable}
    assert Policy.check(%{}) == {:error, :fixture_policy_unavailable}
  end

  test "harness pins cannot select task-owned files or unpinned executables", f do
    task_file = Path.join(f.workspace, "lib/ledger.ex")

    assert Policy.prepare(
             "m7.repair",
             f.digest,
             f.workspace,
             f.argv,
             Map.put(f.pins, task_file, pin(task_file))
           ) == {:error, :fixture_policy_unavailable}

    assert Policy.prepare("m7.repair", f.digest, f.workspace, ["/bin/echo", "x"], f.pins) ==
             {:error, :fixture_policy_unavailable}

    assert Policy.prepare("other", f.digest, f.workspace, f.argv, f.pins) ==
             {:error, :fixture_policy_unavailable}
  end

  test "ordinary profile validation precedes the trusted override and owned startup", f do
    File.write!(f.config, :json.encode(put_in(f.profile, ["policy"], "invented")))
    {:ok, input} = StringIO.open("/quit\n", encoding: :latin1)
    {:ok, output} = StringIO.open("", encoding: :latin1)

    assert Chat.run(["chat", "--config", f.config],
             cwd: f.root,
             home: nil,
             fixture_policy: f.capture,
             input: input,
             output: output,
             acquire_placement: fn _, _ -> flunk("invalid authored profile reached placement") end
           ) == 1

    assert StringIO.contents(input) == {"/quit\n", ""}
  end

  test "real chat commits the agent oracle, refuses alternate shell, reports harness and independently reruns unchanged bytes",
       f do
    isolated_signal_manager()

    script = [
      %{
        text: "repair",
        calls: [
          %{
            id: "fix",
            name: "write",
            arguments: %{
              "path" => "lib/ledger.ex",
              "content" =>
                "defmodule Ledger do\n  def total(entries), do: Enum.sum(entries)\nend\n"
            }
          }
        ]
      },
      %{
        text: "refused",
        calls: [%{id: "wrong", name: "bash", arguments: %{"command" => Enum.join(f.argv, " ")}}]
      },
      %{text: "test", calls: [%{id: "oracle", name: "bash", arguments: %{"argv" => f.argv}}]},
      %{text: "done", calls: []}
    ]

    {:ok, input} = StringIO.open("repair\n/wait\n/status\n/quit\n", encoding: :latin1)
    {:ok, output} = StringIO.open("", encoding: :latin1)
    {:ok, diagnostic} = StringIO.open("", encoding: :latin1)
    parent = self()

    opts = [
      cwd: f.root,
      home: nil,
      input: input,
      output: output,
      diagnostic_device: diagnostic,
      mode: :pipe,
      fixture_policy: f.capture,
      provider_launch: fn -> [] end,
      acquire_placement: fn _, _ -> {:ok, :test_lock} end,
      release_placement: fn _, _ -> :ok end,
      placement_id: fn _ -> {:ok, "fixture-real-runtime"} end,
      with_runtime: fn options, callback ->
        with_stack(f, script, options, callback, parent)
      end
    ]

    prior = System.get_env("M7_FIXTURE_HOST_SENTINEL")
    System.put_env("M7_FIXTURE_HOST_SENTINEL", "must-not-reach-job")

    try do
      result = Chat.run(["chat", "--config", f.config], opts)

      fault =
        receive do
          {:fixture_failure, reason} -> reason
        after
          0 -> nil
        end

      assert result == 0,
             inspect(%{
               output: StringIO.contents(output),
               diagnostics: StringIO.contents(diagnostic),
               fault: fault
             })
    after
      if prior,
        do: System.put_env("M7_FIXTURE_HOST_SENTINEL", prior),
        else: System.delete_env("M7_FIXTURE_HOST_SENTINEL")
    end

    assert_receive {:committed, session, rows, stats, _requests}
    assert Enum.count(rows, &(&1.payload.kind == "effect_intent_committed_v2")) == 2
    assert Enum.count(rows, &(&1.payload.kind == "executor_receipt_committed_v2")) == 2

    assert Enum.any?(
             rows,
             &(&1.payload.kind == "tool_result_committed_v2" and &1.payload["outcome"] == "denied")
           )

    assert Enum.sum(Map.values(stats.dispatches)) == 2

    receipts =
      for row <- rows,
          row.payload.kind == "executor_receipt_committed_v2",
          do: row.payload["receipt"]

    assert [oracle_receipt] = Enum.filter(receipts, &(&1["tool_call_id"] == "oracle"))
    assert oracle_receipt["outcome"] == "completed"
    assert oracle_receipt["cleanup_confirmation"] == "confirmed"
    assert oracle_receipt["child_environment_names"] == ["PATH"]
    assert_suite(oracle_receipt["output"], Path.join(f.root, "trusted/agent.log"))

    {_, stdout} = StringIO.contents(output)
    controls = for "@loopex " <> bytes <- String.split(stdout, "\n"), do: :json.decode(bytes)
    assert Enum.find(controls, &(&1["event"] == "status"))["policy"]["origin"] == "harness"
    assert List.last(controls)["cleanup"] == "confirmed"
    {_, report} = StringIO.contents(diagnostic)
    assert report =~ "harness" and report =~ "shell-allowlist" and report =~ f.digest, report
    refute report =~ "M7_UNUSED_FIXTURE_REFERENCE"

    {:ok, resumed_input} =
      StringIO.open("remember the repair\n/wait\n/status\n/quit\n", encoding: :latin1)

    File.write!(f.config, :json.encode(put_in(f.profile, ["session", "tools"], "none")))

    resumed_options =
      opts
      |> Keyword.put(:input, resumed_input)
      |> Keyword.put(:with_runtime, fn options, callback ->
        with_stack(f, [%{text: "retained repair", calls: []}], options, callback, parent)
      end)

    assert Chat.run(["chat", "--config", f.config, "--resume", session], resumed_options) == 0
    assert_receive {:committed, ^session, resumed_rows, resumed_stats, [resumed_request]}
    assert resumed_stats.dispatches == %{}
    assert Enum.count(resumed_rows, &(&1.payload.kind == "effect_intent_committed_v2")) == 2
    assert Enum.any?(resumed_request.messages, &(&1["content"] == "repair"))
    assert Enum.any?(resumed_request.messages, &(&1["content"] == "remember the repair"))
    {_, resumed_stdout} = StringIO.contents(output)

    resumed_controls =
      for "@loopex " <> bytes <- String.split(resumed_stdout, "\n"), do: :json.decode(bytes)

    resumed_status = resumed_controls |> Enum.filter(&(&1["event"] == "status")) |> List.last()
    assert resumed_status["policy"]["id"] == Policy.identity(f.capture)["id"]
    assert resumed_status["policy"]["fixture_manifest_digest"] == f.digest
    assert List.last(resumed_controls)["cleanup"] == "confirmed"

    assert Policy.check(f.capture) == :ok

    {independent, code} =
      System.cmd("/usr/bin/env", ["-i", "PATH=/usr/bin:/bin" | f.argv],
        cd: f.workspace,
        stderr_to_stdout: true
      )

    assert code == 0
    assert_suite(independent, Path.join(f.root, "trusted/independent.log"))
    assert Policy.check(f.capture) == :ok
    {:ok, catalog} = FixtureManifest.load(@fixtures)
    assert FixtureManifest.verify_workspace(catalog["fixtures"]["repair"], f.workspace) == :ok
  end

  for {choice, default} <- [{"choice-1", "empty"}, {"choice-2", "literal_null"}] do
    @feature_choice choice
    @feature_default default
    test "feature commits its nil question and #{@feature_choice} before effects and passes both immutable oracle modes",
         f do
      File.rm_rf!(f.workspace)
      File.cp_r!(Path.join(@fixtures, "feature/workspace"), f.workspace)
      File.cp!(Path.join(@fixtures, "feature/oracle.exs"), f.oracle)
      runner = File.read!(f.runner)

      File.write!(
        f.runner,
        String.replace(
          runner,
          " M7_WORKSPACE=",
          " M7_NIL_DEFAULT=#{@feature_default} M7_WORKSPACE="
        )
      )

      pins = Map.new(Map.keys(f.pins), &{&1, pin(&1)})
      {:ok, capture} = Policy.prepare("m7.feature", f.digest, f.workspace, f.argv, pins)
      f = %{f | capture: capture, pins: pins}
      {:ok, catalog} = FixtureManifest.load(@fixtures)
      spec = catalog["fixtures"]["feature"]
      assert Canonical.digest_bytes(File.read!(f.oracle)) == spec["oracle"]["sha256"]
      [%{"arguments" => question}] = spec["required_model_actions"]

      code = """
      defmodule RowEncoder do
        def encode(values, options \\\\ []) do
          mode = Keyword.get(options, :nil_mode, :#{@feature_default})
          Enum.map_join(values, ",", &value(&1, mode))
        end
        defp value(nil, :empty), do: ""
        defp value(nil, :literal_null), do: "null"
        defp value(value, _mode), do: to_string(value)
      end
      """

      script = [
        %{
          text: "ask before editing",
          calls: [%{id: "nil-choice", name: "ask", arguments: question}]
        },
        %{
          text: "implement chosen default",
          calls: [
            %{
              id: "feature-write",
              name: "write",
              arguments: %{"path" => "lib/row_encoder.ex", "content" => code}
            }
          ]
        },
        %{text: "verify", calls: [%{id: "oracle", name: "bash", arguments: %{"argv" => f.argv}}]},
        %{text: "done", calls: []}
      ]

      {:ok, prepared} = ChatConfiguration.load(["chat", "--config", f.config], f.root, nil)

      options = [
        policy: %{module: Policy, context: capture},
        policy_identity: Policy.identity(capture),
        model: prepared.selection.configuration["model"],
        cleanup_grace_ms: 1000
      ]

      parent = self()

      callback = fn runtime ->
        {:ok, session} =
          Loopex.create_session(runtime, prepared.session_options,
            command_id: "feature-create",
            genesis: prepared.genesis
          )

        :ok = Loopex.track_session(Path.join(f.root, "state"), session, "fixture-real-runtime")
        {:ok, attachment} = Loopex.attach(runtime, session, after_event_sequence: 0)
        [prompt] = spec["prompts"]

        assert {:accepted, "feature-prompt"} =
                 Loopex.command(attachment, %{
                   type: :prompt,
                   command_id: "feature-prompt",
                   content: prompt
                 })

        pending = await_event(attachment, "interaction.requested", deadline())
        assert pending["producer"] == "model_tool"
        assert pending["prompt"] == question["question"]
        assert Enum.map(pending["choices"], & &1["label"]) == question["choices"]
        {:ok, status} = Loopex.session_status(runtime, session)
        assert status.open_interaction["interaction_id"] == pending["interaction_id"]

        assert {:accepted, "feature-answer"} =
                 Loopex.command(attachment, %{
                   type: :interaction_answer,
                   command_id: "feature-answer",
                   interaction_id: pending["interaction_id"],
                   choice_id: @feature_choice
                 })

        terminal = await_event(attachment, "run.finished", deadline())
        assert terminal["outcome"] == "completed"
        0
      end

      assert with_stack(f, script, options, callback, parent) == 0
      assert_receive {:committed, _session, rows, stats, requests}
      assert Enum.sum(Map.values(stats.dispatches)) == 2
      assert length(requests) == 4

      pending = Enum.find(rows, &(&1.payload.kind == "model_question_requested_v1"))
      answer = Enum.find(rows, &(&1.payload.kind == "model_question_response_admitted_v2"))
      first_effect = Enum.find(rows, &(&1.payload.kind == "effect_intent_committed_v2"))
      assert pending != nil and answer != nil
      assert pending.journal_version < answer.journal_version
      assert answer.journal_version < first_effect.journal_version
      assert answer.payload["answer"]["choice_id"] == @feature_choice

      assert Enum.any?(
               Enum.at(requests, 1).messages,
               &(&1["role"] == "tool" and &1["content"] == @feature_default)
             )

      receipt =
        Enum.find_value(rows, fn row ->
          if row.payload.kind == "executor_receipt_committed_v2" and
               row.payload["receipt"]["tool_call_id"] == "oracle",
             do: row.payload["receipt"]
        end)

      assert receipt["outcome"] == "completed", receipt["output"]
      assert receipt["cleanup_confirmation"] == "confirmed"
      assert_suite(receipt["output"], Path.join(f.root, "trusted/feature-agent.log"))
      assert Policy.check(capture) == :ok

      {independent, 0} =
        System.cmd("/usr/bin/env", ["-i", "PATH=/usr/bin:/bin" | f.argv],
          cd: f.workspace,
          stderr_to_stdout: true
        )

      assert_suite(independent, Path.join(f.root, "trusted/feature-independent.log"))
      assert Policy.check(capture) == :ok
      assert FixtureManifest.verify_workspace(spec, f.workspace) == :ok
    end
  end

  test "long fixture retains raw facts through automatic and explicit checkpoints and physical restart",
       f do
    File.rm_rf!(f.workspace)
    File.cp_r!(Path.join(@fixtures, "long/workspace"), f.workspace)
    File.cp!(Path.join(@fixtures, "long/oracle.exs"), f.oracle)
    pins = Map.new(Map.keys(f.pins), &{&1, pin(&1)})
    {:ok, capture} = Policy.prepare("m7.long", f.digest, f.workspace, f.argv, pins)
    f = %{f | capture: capture, pins: pins}
    {:ok, catalog} = FixtureManifest.load(@fixtures)
    spec = catalog["fixtures"]["long"]
    assert Canonical.digest_bytes(File.read!(f.oracle)) == spec["oracle"]["sha256"]
    [facts, explain, recall, outputs] = spec["prompts"]

    profile =
      f.profile
      |> put_in(["session", "max_tokens"], 4096)
      |> put_in(["session", "context_token_budget"], 4000)
      |> put_in(["session", "system_class_tokens"], 3000)
      |> Map.put("maintenance", %{"model" => f.profile["session"]["model"]})

    File.write!(f.config, :json.encode(profile))
    {:ok, prepared} = ChatConfiguration.load(["chat", "--config", f.config], f.root, nil)
    parent = self()

    summary = %{
      text: fn request ->
        assert_fact_input(request)

        ~s({"summary":"release_prefix=amber; batch_size=3","carry_forward":{"files_read":[],"files_changed":[]}})
      end,
      usage: %{input_tokens: 37, output_tokens: 19},
      reply_overrides: %{completion: "natural", continuation: nil}
    }

    options = [
      policy: %{module: Policy, context: capture},
      policy_identity: Policy.identity(capture),
      model: prepared.selection.configuration["model"],
      model_module: PurposeModel,
      maintenance_model: prepared.selection.maintenance_model,
      maintenance_instructions: %{
        "version" => "m7.fixture.v1",
        "body" => "Keep exact release_prefix and batch_size facts."
      },
      maintenance_script: List.duplicate(summary, 8),
      cleanup_grace_ms: 1000
    ]

    script = [
      %{text: "release_prefix=amber; batch_size=3", calls: []},
      %{
        text: String.duplicate("Keep dependent release steps consistent. ", 300),
        calls: [],
        usage: %{input_tokens: 1500, output_tokens: 3000}
      },
      %{
        text: fn request ->
          assert_fact_input(request)
          "release_prefix=amber; batch_size=3"
        end,
        calls: []
      }
    ]

    callback = fn runtime ->
      {:ok, session} =
        Loopex.create_session(runtime, prepared.session_options,
          command_id: "long-create",
          genesis: prepared.genesis
        )

      :ok = Loopex.track_session(Path.join(f.root, "state"), session, "fixture-real-runtime")
      {:ok, attachment} = Loopex.attach(runtime, session, after_event_sequence: 0)

      for {prompt, index} <- Enum.with_index([facts, explain, recall], 1) do
        command = "long-prompt-#{index}"

        assert {:accepted, ^command} =
                 Loopex.command(attachment, %{type: :prompt, command_id: command, content: prompt})

        assert await_event(attachment, "run.finished", deadline())["outcome"] == "completed"
      end

      assert {:accepted, "long-compact"} =
               Loopex.command(attachment, %{
                 type: :compact,
                 command_id: "long-compact",
                 bounds: %{"deadline_ms" => 15_000, "max_attempts" => 4, "token_budget" => 10_000}
               })

      ending = await_event(attachment, "context.compaction_finished", deadline())
      assert ending["result"]["disposition"] == "checkpointed", inspect(ending)
      send(parent, {:long_session, session})
      0
    end

    assert with_stack(f, script, options, callback, parent) == 0
    assert_receive {:long_session, session}
    assert_receive {:committed, ^session, before, stats, requests}
    assert stats.dispatches == %{}
    assert length(requests) == 3
    assert Enum.any?(before, &(&1.payload.kind == "compaction_checkpoint_committed_v1"))

    assert Enum.any?(
             before,
             &(&1.payload.kind == "standalone_compaction_checkpoint_committed_v1")
           )

    raw_fact =
      Enum.find(
        before,
        &(&1.payload.kind == "prompt_admitted_v3" and &1.payload["command_id"] == "long-prompt-1")
      )

    assert raw_fact.payload["content"] == facts
    assert_receive {:maintenance_requests, summaries}
    assert length(summaries) >= 2
    assert Enum.all?(summaries, &(&1.tools == [] and &1.sampling["max_tokens"] == 1024))

    final_script = [
      %{
        text: fn request ->
          assert_fact_input(request)
          "write retained facts"
        end,
        calls: [
          %{
            id: "release",
            name: "write",
            arguments: %{"path" => "release.txt", "content" => "amber\n"}
          },
          %{
            id: "batches",
            name: "write",
            arguments: %{
              "path" => "batches.txt",
              "content" => "amber-001\namber-002\namber-003\n"
            }
          }
        ]
      },
      %{text: "verify", calls: [%{id: "oracle", name: "bash", arguments: %{"argv" => f.argv}}]},
      %{text: "done", calls: []}
    ]

    resumed = fn runtime ->
      {:ok, {:prepared, activation}} =
        Loopex.prepare_resume_session(runtime, session, "long-resume")

      assert {:ok, retained} = Loopex.prepared_session_configuration(activation)
      assert retained.configuration == prepared.selection.configuration
      assert {:ok, ^session} = Loopex.activate_resume(activation)
      {:ok, attachment} = Loopex.attach(runtime, session)

      assert {:accepted, "long-output"} =
               Loopex.command(attachment, %{
                 type: :prompt,
                 command_id: "long-output",
                 content: outputs
               })

      assert await_event(attachment, "run.finished", deadline())["outcome"] == "completed"
      0
    end

    assert with_stack(f, final_script, options, resumed, parent) == 0
    assert_receive {:committed, ^session, after_restart, stats, [first | _]}
    assert Enum.sum(Map.values(stats.dispatches)) == 3
    assert Enum.take(after_restart, length(before)) == before
    assert Enum.find(after_restart, &(&1.journal_version == raw_fact.journal_version)) == raw_fact
    assert_fact_input(first)
    refute Enum.any?(first.messages, &(&1["role"] == "user" and &1["content"] == facts))

    receipt =
      Enum.find_value(after_restart, fn row ->
        if row.payload.kind == "executor_receipt_committed_v2" and
             row.payload["receipt"]["tool_call_id"] == "oracle",
           do: row.payload["receipt"]
      end)

    assert receipt["outcome"] == "completed", receipt["output"]
    assert receipt["cleanup_confirmation"] == "confirmed"
    assert_suite(receipt["output"], Path.join(f.root, "trusted/long-agent.log"), 2)
    assert Policy.check(capture) == :ok

    {independent, 0} =
      System.cmd("/usr/bin/env", ["-i", "PATH=/usr/bin:/bin" | f.argv],
        cd: f.workspace,
        stderr_to_stdout: true
      )

    assert_suite(independent, Path.join(f.root, "trusted/long-independent.log"), 2)
    assert Policy.check(capture) == :ok
    assert FixtureManifest.verify_workspace(spec, f.workspace) == :ok
  end

  defp assert_fact_input(request) do
    input = Enum.map_join(request.messages, "\n", & &1["content"])
    assert input =~ "release_prefix=amber"
    assert input =~ "batch_size=3"
  end

  defp deadline, do: System.monotonic_time(:millisecond) + 5000

  defp await_event(attachment, kind, deadline) do
    case Loopex.next_event(attachment) do
      {:ok, %{kind: ^kind} = event} ->
        event

      _ ->
        if System.monotonic_time(:millisecond) >= deadline,
          do: flunk("fixture did not commit #{kind}")

        Process.sleep(1)
        await_event(attachment, kind, deadline)
    end
  end

  defp request(id, arguments) do
    definition =
      Enum.find(
        ChatConfiguration.selected_definitions(ChatConfiguration.active_tools("coding")),
        &(&1["tool_id"] == id)
      )

    %{
      generation: ToolDefinition.generation(definition),
      arguments: arguments,
      effect_class: definition["effect_class"],
      workspace_lease: "workspace"
    }
  end

  defp with_stack(f, script, options, callback, parent) do
    assert options[:policy] == %{module: Policy, context: f.capture}
    assert options[:policy_identity] == Policy.identity(f.capture)
    stack = start_stack(f, script, options)

    try do
      result = callback.(stack.runtime)
      {:ok, [session]} = Loopex.list_sessions(Path.join(f.root, "state"))
      {:ok, rows} = Loopex.Store.load_records(stack.store, session.session_id, 0, 1000)

      send(
        parent,
        {:committed, session.session_id, rows, Loopex.Executor.Local.stats(stack.executor),
         Loopex.AgentLoopTestModel.dispatched(stack.model)}
      )

      if stack.maintenance_script do
        send(
          parent,
          {:maintenance_requests, Loopex.AgentLoopTestModel.dispatched(stack.maintenance_script)}
        )
      end

      result
    after
      stop_stack(stack)
    end
  rescue
    error ->
      send(parent, {:fixture_failure, Exception.format(:error, error, __STACKTRACE__)})
      reraise error, __STACKTRACE__
  end

  defp start_stack(f, script, options) do
    File.mkdir_p!(Path.join(f.root, "state"))
    {:ok, adapter} = Loopex.Store.Local.start_link(path: Path.join(f.root, "state/store.log"))
    {:ok, store} = Loopex.Store.new(Loopex.Store.Local, adapter)

    {:ok, lease} =
      Loopex.Executor.Local.WorkspaceLease.start_link(
        id: "workspace",
        path: f.workspace,
        fencing_token: 1
      )

    {:ok, executor} =
      Loopex.Executor.Local.start_link(
        identity: "fixture-executor",
        epoch: 1,
        fencing_token: 1,
        workspace_leases: %{"workspace" => lease},
        ledger_root: Path.join(f.root, "state/receipts")
      )

    model = Loopex.AgentLoopTestModel.start(script)

    maintenance_script =
      if options[:maintenance_script],
        do: Loopex.AgentLoopTestModel.start(options[:maintenance_script])

    {:ok, runtime} =
      Loopex.start_link(
        runtime_id: "fixture-real-runtime",
        context_token_budget: 8192,
        store: store,
        policy: options[:policy],
        policy_identity: options[:policy_identity],
        model: %{
          module: options[:model_module] || Loopex.AgentLoopTestModel,
          model: options[:model],
          options: [script: model, maintenance_script: maintenance_script]
        },
        maintenance_model: options[:maintenance_model],
        maintenance_instructions: options[:maintenance_instructions],
        executor: %{
          module: Loopex.Executor.Local,
          reference: executor,
          identity: "fixture-executor",
          epoch: 1,
          fencing_token: 1,
          workspace_ref: f.capture.workspace_ref,
          workspace_lease: "workspace"
        },
        tools: ChatConfiguration.selected_definitions(ChatConfiguration.active_tools("coding")),
        cleanup_grace_ms: options[:cleanup_grace_ms]
      )

    %{
      runtime: runtime,
      store: store,
      adapter: adapter,
      lease: lease,
      executor: executor,
      model: model,
      maintenance_script: maintenance_script
    }
  end

  defp stop_stack(stack) do
    runtime_monitor = Process.monitor(stack.runtime.supervisor)
    assert :ok == Loopex.stop(stack.runtime)
    assert_receive {:DOWN, ^runtime_monitor, :process, _, _}, 1000

    for pid <-
          Enum.filter(
            [stack.executor, stack.lease, stack.adapter, stack.model, stack.maintenance_script],
            &is_pid/1
          ) do
      Process.unlink(pid)
      ref = Process.monitor(pid)
      if Process.alive?(pid), do: GenServer.stop(pid, :normal, 1000)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 1000
    end
  end

  defp pin(path) do
    {:ok, physical} = WorkspaceIdentity.resolve_path(path)
    {:ok, stat} = File.stat(physical)
    %{mode: Bitwise.band(stat.mode, 0o7777), sha256: Canonical.digest_bytes(File.read!(physical))}
  end

  defp assert_suite(bytes, log, count \\ 3) do
    File.write!(log, bytes)
    script = Path.expand("../../../scripts/suite-summary.sh", __DIR__)

    assert {Integer.to_string(count) <> "\n", 0} ==
             System.cmd("/bin/bash", [script, log, "--count"], stderr_to_stdout: true)
  end

  defp isolated_signal_manager do
    original = Process.whereis(:erl_signal_server)
    {:ok, manager} = :gen_event.start()
    :ok = :gen_event.add_handler(manager, :erl_signal_handler, [])
    Process.unregister(:erl_signal_server)
    true = Process.register(manager, :erl_signal_server)

    on_exit(fn ->
      if Process.whereis(:erl_signal_server) == manager,
        do: Process.unregister(:erl_signal_server)

      if Process.alive?(manager), do: :gen_event.stop(manager)

      if is_pid(original) and Process.alive?(original),
        do: Process.register(original, :erl_signal_server)
    end)
  end

  defp shell_quote(value), do: "'" <> String.replace(value, "'", "'\\''") <> "'"
end
