Code.require_file("../../loopex/test/support/m1_runtime_helper.exs", __DIR__)
Code.require_file("../../loopex/test/support/agent_loop_helper.exs", __DIR__)

# Concept: the native provider fixture loads only under a disposable home.
# Technical depth: its support guard runs during require, before any setup.
native_home =
  Path.join(
    System.tmp_dir!(),
    "m7-native-load-#{System.pid()}-#{System.unique_integer([:positive])}"
  )

File.mkdir_p!(native_home)
prior_native_home = System.get_env("LOOPEX_HOME")
System.put_env("LOOPEX_HOME", native_home)

try do
  Code.require_file(
    "../../loopex_llm_reqllm/test/support/provider_isolation_fixture.exs",
    __DIR__
  )
after
  if prior_native_home,
    do: System.put_env("LOOPEX_HOME", prior_native_home),
    else: System.delete_env("LOOPEX_HOME")

  File.rm_rf!(native_home)
end

defmodule LoopexCli.M7NativeReplies do
  @moduledoc false

  # Concept: Anthropic-native streamed replies for the real adapter, served by
  # the local isolation fixture; no provider is contacted.
  # Technical depth: blocks are thinking (with signature), text or tool_use,
  # streamed as the provider's message events with exact deltas.
  def reply(model, blocks, stop \\ "end_turn") do
    start = %{
      "type" => "message_start",
      "message" => %{
        "id" => "m7-native-reply",
        "type" => "message",
        "role" => "assistant",
        "model" => String.replace_prefix(model, "anthropic:", ""),
        "content" => [],
        "stop_reason" => nil,
        "stop_sequence" => nil,
        "usage" => %{"input_tokens" => 11}
      }
    }

    events =
      Enum.flat_map(Enum.with_index(blocks), fn {block, index} ->
        {initial, deltas} =
          case block do
            {:thinking, text, signature} ->
              {%{"type" => "thinking", "thinking" => "", "signature" => ""},
               [
                 %{"type" => "thinking_delta", "thinking" => text},
                 %{"type" => "signature_delta", "signature" => signature}
               ]}

            {:text, text} ->
              {%{"type" => "text", "text" => ""}, [%{"type" => "text_delta", "text" => text}]}

            {:tool, id, name, arguments} ->
              {%{"type" => "tool_use", "id" => id, "name" => name, "input" => %{}},
               [%{"type" => "input_json_delta", "partial_json" => JSON.encode!(arguments)}]}
          end

        [%{"type" => "content_block_start", "index" => index, "content_block" => initial}] ++
          Enum.map(deltas, &%{"type" => "content_block_delta", "index" => index, "delta" => &1}) ++
          [%{"type" => "content_block_stop", "index" => index}]
      end)

    tail = [
      %{
        "type" => "message_delta",
        "delta" => %{"stop_reason" => stop, "stop_sequence" => nil},
        "usage" => %{"output_tokens" => 4}
      },
      %{"type" => "message_stop"}
    ]

    Enum.map_join([start] ++ events ++ tail, fn event ->
      "event: #{event["type"]}\ndata: #{JSON.encode!(event)}\n\n"
    end)
  end

  # Provider B: one OpenAI Responses stream with a text answer.
  def responses(text) do
    events = [
      %{
        "type" => "response.created",
        "response" => %{"id" => "resp_m7", "status" => "in_progress"}
      },
      %{
        "type" => "response.output_text.delta",
        "item_id" => "msg_m7",
        "output_index" => 0,
        "content_index" => 0,
        "delta" => text
      },
      %{
        "type" => "response.completed",
        "response" => %{
          "id" => "resp_m7",
          "status" => "completed",
          "model" => "gpt-4.1-mini",
          "output" => [
            %{
              "type" => "message",
              "id" => "msg_m7",
              "role" => "assistant",
              "content" => [%{"type" => "output_text", "text" => text}]
            }
          ],
          "usage" => %{"input_tokens" => 9, "output_tokens" => 2, "total_tokens" => 11}
        }
      }
    ]

    Enum.map_join(events, &("event: #{&1["type"]}\ndata: " <> JSON.encode!(&1) <> "\n\n"))
  end
end

defmodule LoopexCli.M7CaseRunnerTest do
  use ExUnit.Case, async: false
  @moduletag capture_log: true

  # Concept: the dispatching entrypoint is proved credential-free. A scripted
  # model stands in only for the provider; admission, the attempts index, the
  # fixture policy, the real executor, oracle reruns and change inspection are
  # the production paths.

  alias LoopexCli.ChatConfiguration

  # Maintenance requests carry no tools; they read the summarizer script.
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

  alias Mix.Tasks.Loopex.M7Evidence.{AttemptEvents, AttemptWriter, CaseRunner, FixtureManifest}

  @fixtures Path.expand("../../../test/fixtures/m7", __DIR__)
  @candidate String.duplicate("1", 40)
  @fixed "defmodule Ledger do\n  def total(entries), do: Enum.sum(entries)\nend\n"

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "m7-case-runner-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(Path.join(root, "runs"))
    File.mkdir_p!(Path.join(root, "markers"))
    on_exit(fn -> File.rm_rf!(root) end)
    isolated_signal_manager()

    identity = %{
      "writer_id" => "writer-1",
      "host_id" => "host-1",
      "marker_dir" => Path.join(root, "markers")
    }

    {:ok, catalog} = FixtureManifest.load(@fixtures)
    index = Path.join(root, "attempts.jsonl")
    campaign = catalog.catalog["execution_manifest"]["campaign_id"]
    {:ok, writer} = AttemptWriter.create(index, campaign, identity)
    [_, designation] = records(index)
    config = Path.join(root, "template.json")
    File.write!(config, :json.encode(profile(root)))

    context = %{
      manifest: lane(catalog.catalog, ["m7.repair"]),
      manifest_digest: catalog.digest,
      catalog_root: @fixtures,
      run_root: Path.join(root, "runs"),
      candidate: @candidate,
      concept: head_line(designation),
      config_argv: ["chat", "--config", config],
      cwd: root,
      operator: "Maintainer"
    }

    %{root: root, writer: writer, index: index, context: context, config: config}
  end

  test "a repair attempt is recorded before dispatch, reopens its session and passes independently",
       f do
    parent = self()

    scripts = fn capture, call ->
      if call == 1,
        do: repair_script(capture.argv, @fixed),
        else: [%{text: "the empty-ledger boundary", calls: []}]
    end

    context = Map.put(f.context, :chat_options, chat_options(f, scripts, parent))
    result = passed!(CaseRunner.run_lane(f.writer, "m7-operator", context))
    assert result.mechanical_result == "pass"

    # Both conversations saw the started record already in the index.
    assert_received {:index_at_dispatch, 1, before_first}
    assert_received {:index_at_dispatch, 2, _}
    assert List.last(before_first)["body"]["state"] == "started"
    refute_received {:index_at_dispatch, 3, _}

    [_, _, started, completed] = records(f.index)
    assert started["body"]["attempt_id"] == completed["body"]["attempt_id"]
    assert completed["body"]["mechanical_result"] == "pass"
    assert completed["body"]["case_key"] == "m7.repair"
    assert completed["body"]["lane_id"] == "m7-operator"

    references = Enum.map(completed["body"]["evidence"], & &1["reference"])
    names = Enum.map(references, &Path.basename/1)

    for name <- ~w(execution.json oracle.txt changes.json transcript-1.txt transcript-2.txt),
        do: assert(name in names)

    for reference <- completed["body"]["evidence"] do
      bytes = File.read!(reference["reference"])
      assert LoopexProtocol.Canonical.digest_bytes(bytes) == reference["sha256"]
    end

    oracle = File.read!(Enum.find(references, &String.ends_with?(&1, "oracle.txt")))
    assert oracle =~ "status=0"
    assert File.read!(Path.join(result.root, "workspace/lib/ledger.ex")) == @fixed

    assert {:blocked, %{reason: :lane_already_ended}} =
             AttemptWriter.admit(
               f.writer,
               f.context.concept,
               lane_selection(f),
               :continue
             )
  end

  test "a failing oracle completes as assertion_failed and stops the lane", f do
    context =
      f.context
      |> Map.put(:manifest, lane(f.context.manifest, ["m7.repair", "m7.external"]))
      |> Map.put(
        :chat_options,
        chat_options(f, fn capture, _ -> repair_script(capture.argv, "broken\n") end, self())
      )

    assert {:stopped, [{:ok, result}]} = CaseRunner.run_lane(f.writer, "m7-operator", context)
    assert result.mechanical_result == "assertion_failed"
    [_, _, _, completed] = records(f.index)
    assert completed["body"]["mechanical_result"] == "assertion_failed"
    assert Enum.count(records(f.index), &(&1["body"]["case_key"] == "m7.external")) == 0

    assert {:blocked, %{reason: :consumed_lane_failure}} =
             AttemptWriter.admit(f.writer, f.context.concept, lane_selection(f), :continue)
  end

  test "a preparation refusal records a not-dispatched stop and no conversation runs", f do
    File.write!(f.config, :json.encode(Map.delete(profile(f.root), "paths")))
    parent = self()
    context = Map.put(f.context, :chat_options, chat_options(f, fn _, _ -> [] end, parent))

    assert {:stopped, [{:ok, result}]} = CaseRunner.run_lane(f.writer, "m7-operator", context)
    assert result.mechanical_result == "evidence_incomplete_pre_dispatch"
    refute_received {:index_at_dispatch, _, _}
    [_, _, pending] = records(f.index)
    assert pending["body"]["state"] == "not_dispatched"
    assert pending["body"]["attempt_id"] == nil
    [preflight] = pending["body"]["evidence"]
    assert File.read!(preflight["reference"]) =~ "invalid_m7_config"
  end

  test "the external task runs in a disposable checkout and inspects only allowed changes", f do
    {catalog_root, repository} = external_catalog(f.root)
    {:ok, catalog} = FixtureManifest.load(catalog_root)

    fixed =
      String.replace(
        base_threads(),
        "    return re.sub",
        "    name = unicodedata.normalize(\"NFKD\", name).encode(\"ascii\", \"ignore\").decode()\n    return re.sub"
      )

    fixed = String.replace(fixed, "import re\n", "import re\nimport unicodedata\n")

    script = fn capture, _ ->
      [
        %{
          text: "fix",
          calls: [
            %{
              id: "fix",
              name: "write",
              arguments: %{"path" => "tools/threads.py", "content" => fixed}
            }
          ]
        },
        %{
          text: "test",
          calls: [%{id: "oracle", name: "bash", arguments: %{"argv" => capture.argv}}]
        },
        %{text: "done", calls: []}
      ]
    end

    context =
      f.context
      |> Map.merge(%{
        manifest: lane(catalog.catalog, ["m7.external"]),
        manifest_digest: catalog.digest,
        catalog_root: catalog_root,
        external_repository: repository,
        chat_options: chat_options(f, script, self())
      })

    result = passed!(CaseRunner.run_lane(f.writer, "m7-operator", context))
    assert result.mechanical_result == "pass"
    changes = File.read!(Path.join(result.root, "records/changes.json"))
    assert JSON.decode!(changes)["changed"] == ["tools/threads.py"]
    assert File.read!(Path.join(result.root, "records/oracle.txt")) =~ "status=0"
    # The source repository itself is untouched and has no remote push path.
    assert {"", 0} = System.cmd("git", ["-C", repository, "status", "--porcelain"])
    assert {"", 0} = System.cmd("git", ["-C", Path.join(result.root, "workspace"), "remote"])
  end

  test "an unchanged external checkout fails its oracle and a stray write is denied",
       f do
    {catalog_root, repository} = external_catalog(f.root)
    {:ok, catalog} = FixtureManifest.load(catalog_root)

    script = fn capture, _ ->
      [
        %{
          text: "stray",
          calls: [
            %{id: "stray", name: "write", arguments: %{"path" => "README.md", "content" => "x\n"}}
          ]
        },
        %{
          text: "test",
          calls: [%{id: "oracle", name: "bash", arguments: %{"argv" => capture.argv}}]
        },
        %{text: "done", calls: []}
      ]
    end

    context =
      Map.merge(f.context, %{
        manifest: lane(catalog.catalog, ["m7.external"]),
        manifest_digest: catalog.digest,
        catalog_root: catalog_root,
        external_repository: repository,
        chat_options: chat_options(f, script, self())
      })

    assert {:stopped, [{:ok, result}]} = CaseRunner.run_lane(f.writer, "m7-operator", context)
    assert result.mechanical_result == "assertion_failed"
    oracle = File.read!(Path.join(result.root, "records/oracle.txt"))
    assert oracle =~ "status=2" and oracle =~ "cafe-society"
    assert File.read!(Path.join(result.root, "workspace/README.md")) == "fixture\n"
  end

  for {choice, default} <- [{"choice-1", "empty"}, {"choice-2", "literal_null"}] do
    @choice choice
    @default default
    test "feature reruns the oracle branch the committed #{@choice} answer selected", f do
      catalog = f.context.manifest
      [%{"arguments" => question}] = catalog["fixtures"]["feature"]["required_model_actions"]

      script = fn capture, _ ->
        [
          %{text: "ask", calls: [%{id: "nil-choice", name: "ask", arguments: question}]},
          %{
            text: "implement",
            calls: [
              %{
                id: "write",
                name: "write",
                arguments: %{"path" => "lib/row_encoder.ex", "content" => encoder(@default)}
              }
            ]
          },
          %{
            text: "test",
            calls: [
              %{id: "oracle", name: "bash", arguments: %{"argv" => capture.argv ++ [@default]}}
            ]
          },
          %{text: "done", calls: []}
        ]
      end

      context =
        Map.merge(f.context, %{
          manifest: lane(catalog, ["m7.feature"]),
          answers: %{"m7.feature" => @choice},
          chat_options: chat_options(f, script, self())
        })

      result = passed!(CaseRunner.run_lane(f.writer, "m7-operator", context))
      facts = JSON.decode!(File.read!(Path.join(result.root, "records/facts.json")))
      assert facts["join"] =~ @default
      assert facts["kinds"]["model_question_response_admitted_v2"] == 1
      oracle = File.read!(Path.join(result.root, "records/oracle.txt"))
      assert oracle =~ "status=0"
      runner = File.read!(Path.join(result.root, "trusted/independent.sh"))
      assert runner =~ "M7_NIL_DEFAULT='#{@default}'"
    end
  end

  # Concept: a fixture case on chat's real composition: the pinned fixture
  # policy reaches durable composition as Core's contextual reference.
  test "a feature case passes on the real composition under its fixture policy", f do
    alias LoopexCli.M7NativeReplies, as: R
    model = "anthropic:claude-haiku-4-5-20251001"

    [%{"arguments" => question}] =
      f.context.manifest["fixtures"]["feature"]["required_model_actions"]

    fixture =
      Loopex.LLM.ReqLLM.ProviderIsolationFixture.new(:reply,
        credential: "m7-feature-native-synthetic",
        response_bodies: [
          R.reply(model, [{:tool, "ask-1", "ask", question}], "tool_use"),
          R.reply(
            model,
            [
              {:tool, "write-1", "write",
               %{"path" => "lib/row_encoder.ex", "content" => encoder("literal_null")}}
            ],
            "tool_use"
          ),
          R.reply(model, [{:text, "implemented"}])
        ]
      )

    context =
      Map.merge(f.context, %{
        manifest: lane(f.context.manifest, ["m7.feature"]),
        answers: %{"m7.feature" => "choice-2"},
        chat_options: native!(f, fixture, &put_in(&1, ["session", "model"], model))
      })

    result = passed!(CaseRunner.run_lane(f.writer, "m7-operator", context))
    execution = JSON.decode!(File.read!(Path.join(result.root, "records/execution.json")))
    assert execution["policy"]["id"] =~ "m7.fixture:m7.feature:"
    assert File.read!(Path.join(result.root, "records/oracle.txt")) =~ "status=0"
  end

  test "feature without the committed question is required_action_absent and no pipe answer is guessed",
       f do
    script = fn _capture, _ ->
      [
        %{
          text: "implement",
          calls: [
            %{
              id: "write",
              name: "write",
              arguments: %{"path" => "lib/row_encoder.ex", "content" => encoder("empty")}
            }
          ]
        },
        %{text: "done", calls: []}
      ]
    end

    context =
      Map.merge(f.context, %{
        manifest: lane(f.context.manifest, ["m7.feature"]),
        answers: %{"m7.feature" => "choice-1"},
        step_deadline_ms: 3000,
        chat_options: chat_options(f, script, self())
      })

    assert {:stopped, [{:ok, result}]} = CaseRunner.run_lane(f.writer, "m7-operator", context)
    assert result.mechanical_result == "required_action_absent"
    transcript = File.read!(Path.join(result.root, "records/transcript-1.txt"))
    refute transcript =~ "/answer"
  end

  test "a piped feature run without an operator's answer refuses before dispatch", f do
    context =
      Map.merge(f.context, %{
        manifest: lane(f.context.manifest, ["m7.feature"]),
        chat_options: chat_options(f, fn _, _ -> [] end, self())
      })

    assert {:stopped, [{:ok, refused}]} = CaseRunner.run_lane(f.writer, "m7-operator", context)
    assert refused.mechanical_result == "evidence_incomplete_pre_dispatch"
    refute_received {:index_at_dispatch, _, _}
    [preflight] = List.last(records(f.index))["body"]["evidence"]
    assert File.read!(preflight["reference"]) =~ "feature_answer_requires_operator"
  end

  test "long joins automatic and explicit checkpoints, raw facts and the restart", f do
    {context, script} = long_case(f, 3000)

    result =
      passed!(
        CaseRunner.run_lane(
          f.writer,
          "m7-operator",
          Map.put(context, :chat_options, chat_options(f, script, self()))
        )
      )

    facts = JSON.decode!(File.read!(Path.join(result.root, "records/facts.json")))
    assert facts["kinds"]["compaction_checkpoint_committed_v1"] >= 1
    assert facts["kinds"]["standalone_compaction_checkpoint_committed_v1"] == 1
    assert File.read!(Path.join(result.root, "workspace/release.txt")) == "amber\n"
  end

  test "long without an automatic checkpoint is required_action_absent", f do
    {context, script} = long_case(f, 10)

    assert {:stopped, [{:ok, result}]} =
             CaseRunner.run_lane(
               f.writer,
               "m7-operator",
               Map.put(context, :chat_options, chat_options(f, script, self()))
             )

    assert result.mechanical_result == "required_action_absent"
    facts = JSON.decode!(File.read!(Path.join(result.root, "records/facts.json")))
    assert facts["join"] =~ "automatic_checkpoint"
  end

  @read %{text: "read", calls: [%{id: "read", name: "read", arguments: %{"path" => "README.md"}}]}

  defp scenario!(f, case_id, script, extra \\ %{}) do
    context =
      Map.merge(
        f.context,
        Map.merge(
          %{
            manifest: lane(f.context.manifest, [case_id]),
            chat_options: chat_options(f, fn _, call -> script.(call) end, self())
          },
          extra
        )
      )

    CaseRunner.run_lane(f.writer, "m7-operator", context)
  end

  defp facts(result),
    do: JSON.decode!(File.read!(Path.join(result.root, "records/facts.json")))

  @oversized_summary %{
    text: ~s({"summary":"ledger noted","carry_forward":{"files_read":[],"files_changed":[]}}),
    usage: %{input_tokens: 40, output_tokens: 12},
    reply_overrides: %{completion: "natural", continuation: nil}
  }

  test "an oversized source compacts excerpted, keeps its original and inherits the flag", f do
    script = fn _call ->
      %{
        main: [
          %{text: "noted", calls: []},
          %{text: "ready", calls: []},
          %{text: "again", calls: []}
        ],
        maintenance: List.duplicate(@oversized_summary, 4)
      }
    end

    result = passed!(scenario!(f, "m7.oversized-source", script))
    assert facts(result)["kinds"]["standalone_compaction_checkpoint_committed_v1"] == 2
    refute File.read!(Path.join(result.root, "records/facts.json")) =~ "SENTINEL"
  end

  test "baseline durable pins the dated default model and one committed tool round", f do
    result =
      passed!(
        scenario!(f, "m7.baseline.durable", fn _ -> [@read, %{text: "first line", calls: []}] end)
      )

    assert facts(result)["kinds"]["executor_receipt_committed_v2"] == 1
    config = JSON.decode!(File.read!(Path.join(result.root, "config.json")))
    assert config["session"]["model"] == "anthropic:claude-haiku-4-5-20251001"
  end

  test "baseline durable without its tool round is required_action_absent", f do
    assert {:stopped, [{:ok, result}]} =
             scenario!(f, "m7.baseline.durable", fn _ -> [%{text: "no tool", calls: []}] end)

    assert result.mechanical_result == "required_action_absent"
  end

  test "policy denial commits a denied call with no effect or workspace change", f do
    rm = %{
      text: "rm",
      calls: [%{id: "rm", name: "bash", arguments: %{"argv" => ["rm", "README.md"]}}]
    }

    result =
      passed!(scenario!(f, "m7.policy-denial", fn _ -> [rm, %{text: "denied", calls: []}] end))

    assert facts(result)["kinds"]["effect_intent_committed_v2"] == nil
    assert File.read!(Path.join(result.root, "workspace/README.md")) =~ "M7 scenario"
  end

  test "policy denial without the denied call is required_action_absent", f do
    assert {:stopped, [{:ok, missing}]} =
             scenario!(f, "m7.policy-denial", fn _ -> [@read, %{text: "x", calls: []}] end)

    assert missing.mechanical_result == "required_action_absent"
  end

  test "pipe answer and decline use the emitted interaction identities", f do
    ask = fn subcase ->
      %{
        text: "ask",
        calls: [
          %{
            id: "ask-#{subcase}",
            name: "ask",
            arguments: %{
              "question" => "Continue the #{subcase} subcase?",
              "choices" => ["yes", "no"]
            }
          }
        ]
      }
    end

    script = fn
      1 -> [ask.("answer"), %{text: "answered", calls: []}]
      _ -> [ask.("decline"), %{text: "declined", calls: []}]
    end

    result = passed!(scenario!(f, "m7.pipe-answer", script, %{step_deadline_ms: 5000}))
    assert File.read!(Path.join(result.root, "records/input-1.txt")) =~ "/answer "
    assert File.read!(Path.join(result.root, "records/input-2.txt")) =~ "/decline "
    assert facts(result)["kinds"]["model_question_response_admitted_v2"] == 2
  end

  test "pipe answer never invents an identity when no question is emitted", f do
    assert {:stopped, [{:ok, result}]} =
             scenario!(f, "m7.pipe-answer", fn _ -> [%{text: "no question", calls: []}] end, %{
               step_deadline_ms: 2000
             })

    assert result.mechanical_result == "required_action_absent"
  end

  for variant <- ["flag", "file"] do
    @variant variant
    test "trace #{@variant} startup enables tracing with its origin and confirmed cleanup", f do
      result =
        passed!(
          scenario!(f, "m7.trace.#{@variant}", fn _ -> [@read, %{text: "traced", calls: []}] end)
        )

      diagnostics = File.read!(Path.join(result.root, "records/diagnostics-1.txt"))
      assert diagnostics =~ ~s("setting":"/trace/enabled")
    end
  end

  # The `ask` command's own host seams stand in only for the ephemeral
  # provider session; argument handling and rendering are the command's own.
  defp ask_seams(outcome) do
    manager = spawn(fn -> receive do: (:release -> :ok) end)
    on_exit(fn -> Process.exit(manager, :kill) end)

    [
      discard_credential: fn -> :ok end,
      quiet_logger: fn -> :ok end,
      start_session: fn _ -> {:ok, :fixture_session} end,
      install_interrupt: fn _, _ -> {:ok, manager} end,
      signal_manager: fn -> manager end,
      handler_live: fn _, _ -> true end,
      interrupt_phase: fn _, _ -> :idle end,
      ask: fn _, _ ->
        {:ok,
         %{
           profile: :ephemeral,
           outcome: outcome,
           session_id: "session-1",
           run_id: "run-1",
           text: "M7 scenario workspace.",
           text_truncated: false,
           tools: [],
           tools_truncated: false,
           shadowed_skills: [],
           details: %{"cleanup_grace_ms" => 5_000}
         }}
      end,
      stop_session: fn _ -> :ok end,
      finish_interrupt: fn _, _ -> {:ok, :ordinary} end
    ]
  end

  for case_id <- ["m7.baseline.ask", "m7.trace.json"] do
    @ask_case case_id
    test "#{@ask_case} renders exactly one completed JSON result", f do
      result =
        passed!(scenario!(f, @ask_case, fn _ -> [] end, %{ask_seams: ask_seams(:completed)}))

      stdout = File.read!(Path.join(result.root, "records/stdout.txt"))
      assert [json, ""] = String.split(stdout, "\n")
      assert JSON.decode!(json)["outcome"] == "completed"
    end
  end

  test "a cancelled one-shot ask is assertion_failed", f do
    assert {:stopped, [{:ok, result}]} =
             scenario!(f, "m7.baseline.ask", fn _ -> [] end, %{ask_seams: ask_seams(:cancelled)})

    assert result.mechanical_result == "assertion_failed"
  end

  test "a pre-dispatch stop suspends the whole lane and its continuation dispatches each case once",
       f do
    File.write!(f.config, :json.encode(Map.delete(profile(f.root), "paths")))
    cases = ["m7.policy-denial", "m7.baseline.durable"]

    scripts = fn _, call ->
      if call == 1,
        do: [
          %{
            text: "rm",
            calls: [%{id: "rm", name: "bash", arguments: %{"argv" => ["rm", "README.md"]}}]
          },
          %{text: "denied", calls: []}
        ],
        else: [@read, %{text: "first line", calls: []}]
    end

    context =
      Map.merge(f.context, %{
        manifest: lane(f.context.manifest, cases),
        chat_options: chat_options(f, scripts, self())
      })

    assert {:stopped, [{:ok, first}, {:ok, second}]} =
             CaseRunner.run_lane(f.writer, "m7-operator", context)

    assert first.mechanical_result == "evidence_incomplete_pre_dispatch"
    assert second.mechanical_result == "evidence_incomplete_pre_dispatch"
    refute_received {:index_at_dispatch, _, _}

    File.write!(f.config, :json.encode(profile(f.root)))
    resumed = Map.put(context, :mode, :continue)
    assert {:ok, results} = CaseRunner.run_lane(f.writer, "m7-operator", resumed)
    assert Enum.map(results, fn {:ok, r} -> r.mechanical_result end) == ["pass", "pass"]

    started =
      for r <- records(f.index), r["body"]["state"] == "started", do: r["body"]["case_key"]

    assert started == cases

    assert {:blocked, %{reason: :lane_already_ended}} =
             CaseRunner.run_lane(f.writer, "m7-operator", resumed)
  end

  test "matrix lanes start, join and skip by the index alone", f do
    manifest =
      f.context.manifest
      |> lane(["m7.policy-denial"])
      |> put_in(["execution_manifest", "lanes", "m7-provider"], ["m7.baseline.durable"])
      |> put_in(["execution_manifest", "cases", "m7.baseline.durable", "status"], "ready")

    scripts = fn _, call ->
      if call == 1,
        do: [
          %{
            text: "rm",
            calls: [%{id: "rm", name: "bash", arguments: %{"argv" => ["rm", "README.md"]}}]
          },
          %{text: "denied", calls: []}
        ],
        else: [@read, %{text: "first line", calls: []}]
    end

    context =
      Map.merge(f.context, %{
        manifest: manifest,
        matrix: "matrix-1",
        mode: :auto,
        chat_options: chat_options(f, scripts, self())
      })

    assert {:ok, [{:ok, %{mechanical_result: "pass"}}]} =
             CaseRunner.run_lane(f.writer, "m7-operator", context)

    assert {:ok, [{:ok, %{mechanical_result: "pass"}}]} =
             CaseRunner.run_lane(f.writer, "m7-provider", context)

    assert {:ok, []} = CaseRunner.run_lane(f.writer, "m7-operator", context)
    assert {:ok, []} = CaseRunner.run_lane(f.writer, "m7-provider", context)

    matrix =
      for r <- records(f.index), r["body"]["kind"] == "case", do: r["body"]["logical_matrix_id"]

    assert Enum.uniq(matrix) == ["matrix-1"]

    assert {:blocked, %{reason: :fresh_matrix_already_consumed}} =
             CaseRunner.run_lane(f.writer, "m7-operator", %{context | matrix: "matrix-2"})
  end

  @sentinel_reply %{text: "M7 scenario workspace. AMBER-SENTINEL", calls: []}

  test "admitted project instructions are retained and followed", f do
    result =
      passed!(scenario!(f, "m7.instructions.admitted", fn _ -> [@read, @sentinel_reply] end))

    assert File.read!(Path.join(result.root, "project-instructions.md")) =~ "AMBER-SENTINEL"
  end

  test "a declined resource is never admitted", f do
    passed!(
      scenario!(f, "m7.instructions.declined", fn _ ->
        [@read, %{text: "M7 scenario workspace.", calls: []}]
      end)
    )
  end

  test "admitted text that is not followed is required_action_absent", f do
    assert {:stopped, [{:ok, missed}]} =
             scenario!(f, "m7.instructions.admitted", fn _ ->
               [@read, %{text: "no sentinel", calls: []}]
             end)

    assert missed.mechanical_result == "required_action_absent"
  end

  test "a changed resource is admitted with a new receipt in a fresh session", f do
    result =
      passed!(scenario!(f, "m7.instructions.changed", fn _ -> [@read, @sentinel_reply] end))

    facts = facts(result)
    assert facts["join"] == "{:ok, nil}"
    assert length(Path.wildcard(Path.join(result.root, "records/transcript-*.txt"))) == 2
  end

  # Concept: the review case delegates to both pinned roles through the real
  # helper owner on chat's real composition; the parent's committed final
  # reply is the oracle's finding.
  defp review_replies(roles) do
    alias LoopexCli.M7NativeReplies, as: R
    a = "anthropic:claude-haiku-4-5-20251001"

    finding =
      "file\tfunction\tdefect_code\tcall_chain\n" <>
        "lib/fees.ex\ttotal/2\tduplicate_fee\tCheckout.quote/2>Invoice.total/2>Fees.total/2\n"

    Enum.flat_map(roles, fn role ->
      arguments = %{"role" => role, "description" => role, "prompt" => "Trace Checkout.quote/2."}

      helper =
        if role == "investigate",
          do: "Checkout.quote/2>Invoice.total/2>Fees.total/2",
          else: "lib/fees.ex total/2 duplicate_fee"

      [
        R.reply(a, [{:tool, "task-#{role}", "task", arguments}], "tool_use"),
        R.reply(a, [{:text, helper}])
      ]
    end) ++ [R.reply(a, [{:text, finding}])]
  end

  defp review_context(f, roles) do
    fixture =
      Loopex.LLM.ReqLLM.ProviderIsolationFixture.new(:reply,
        credential: "m7-review-native-synthetic",
        response_bodies: review_replies(roles)
      )

    Map.merge(f.context, %{
      manifest: lane(f.context.manifest, ["m7.review"]),
      chat_options: native!(f, fixture)
    })
  end

  @tag timeout: 120_000
  test "review delegates both roles on the real composition and its finding passes the oracle",
       f do
    result =
      passed!(
        CaseRunner.run_lane(f.writer, "m7-operator", review_context(f, ~w(investigate review)))
      )

    assert File.read!(Path.join(result.root, "records/oracle.txt")) =~ "status=0"
    assert facts(result)["kinds"]["executor_receipt_committed_v2"] >= 2
  end

  @tag timeout: 120_000
  test "review without the review role call is required_action_absent", f do
    assert {:stopped, [{:ok, result}]} =
             CaseRunner.run_lane(f.writer, "m7-operator", review_context(f, ~w(investigate)))

    assert result.mechanical_result == "required_action_absent"
  end

  # Concept: native thinking replies through the real adapter and the local
  # fixture: each cell reads the three files in three rounds, then answers.
  defp rounds_replies(cells, paths \\ ~w(a.txt b.txt c.txt)) do
    alias LoopexCli.M7NativeReplies, as: R

    # Each later cell first compacts; the thinking-off summarizer answers it.
    summary =
      R.reply("anthropic:claude-haiku-4-5-20251001", [
        {:text,
         ~s({"summary":"cedar seven amber","carry_forward":{"files_read":["a.txt","b.txt","c.txt"],"files_changed":[]}})}
      ])

    Enum.flat_map(Enum.with_index(cells), fn {{model, _}, cell} ->
      think = fn n -> {:thinking, "private step #{cell}.#{n}", "sig-#{cell}-#{n}+/="} end

      rounds =
        for {path, n} <- Enum.with_index(paths) do
          R.reply(
            model,
            [think.(n), {:tool, "read-#{cell}-#{n}", "read", %{"path" => path}}],
            "tool_use"
          )
        end ++ [R.reply(model, [think.(length(paths)), {:text, "cedar seven amber"}])]

      if cell == 0, do: rounds, else: [summary | rounds]
    end)
  end

  # Seven cells of four native calls plus six checkpoints run through the
  # isolated provider worker; the measured run is about one minute.
  @tag timeout: 300_000
  test "thinking rounds replay each cell's thinking across three tool rounds and reopen", f do
    cells = Mix.Tasks.Loopex.M7Evidence.Scenarios.thinking_cells()

    fixture =
      Loopex.LLM.ReqLLM.ProviderIsolationFixture.new(:reply,
        credential: "m7-thinking-rounds-synthetic",
        response_bodies: rounds_replies(cells)
      )

    result =
      passed!(
        scenario!(f, "m7.thinking-rounds", fn _ -> [] end, %{chat_options: native!(f, fixture)})
      )

    assert facts(result)["kinds"]["model_request_committed_v2"] == 4 * length(cells)
    assert facts(result)["kinds"]["standalone_compaction_checkpoint_committed_v1"] == 6
  end

  # A single tool round per cell leaves one continuation request: not enough.
  @tag timeout: 300_000
  test "thinking rounds with one tool round per cell are required_action_absent", f do
    cells = Mix.Tasks.Loopex.M7Evidence.Scenarios.thinking_cells()

    fixture =
      Loopex.LLM.ReqLLM.ProviderIsolationFixture.new(:reply,
        credential: "m7-thinking-rounds-synthetic",
        response_bodies: rounds_replies(cells, ~w(a.txt))
      )

    assert {:stopped, [{:ok, result}]} =
             scenario!(f, "m7.thinking-rounds", fn _ -> [] end, %{
               chat_options: native!(f, fixture)
             })

    assert result.mechanical_result == "required_action_absent"
    assert facts(result)["join"] =~ "continuation_rounds"
  end

  test "a thinking-off summarizer compacts an always-on thinking conversation once", f do
    alias LoopexCli.M7NativeReplies, as: R
    fable = "anthropic:claude-fable-5-1"
    think = fn n -> {:thinking, "fable step #{n}", "fable-sig-#{n}+/="} end

    fixture =
      Loopex.LLM.ReqLLM.ProviderIsolationFixture.new(:reply,
        credential: "m7-cross-maintenance-synthetic",
        response_bodies: [
          R.reply(fable, [think.(0), {:text, "noted"}]),
          R.reply(fable, [think.(1), {:text, "ready"}]),
          R.responses(
            ~s({"summary":"release_prefix=amber, batch_size=3","carry_forward":{"files_read":[],"files_changed":[]}})
          ),
          R.reply(fable, [think.(2), {:text, "release_prefix=amber, batch_size=3"}])
        ]
      )

    result =
      passed!(
        scenario!(f, "m7.cross-provider-maintenance", fn _ -> [] end, %{
          chat_options: native!(f, fixture)
        })
      )

    assert facts(result)["kinds"]["maintenance_attempt_settled_v3"] == 1
    assert facts(result)["kinds"]["standalone_compaction_checkpoint_committed_v1"] == 1
  end

  # Per cell: a tool reply cut by the one-turn bound, then two text replies;
  # thinking appears only where the cell's mapping requires continuation.
  defp cut_replies(cells, final_thinking? \\ true) do
    alias LoopexCli.M7NativeReplies, as: R

    summary =
      R.reply("anthropic:claude-haiku-4-5-20251001", [
        {:text,
         ~s({"summary":"cedar","carry_forward":{"files_read":["a.txt"],"files_changed":[]}})}
      ])

    Enum.flat_map(Enum.with_index(cells), fn {{model, reasoning}, cell} ->
      {:ok, mapping} = Loopex.LLM.ReqLLM.ModelCapabilities.mapping(model, reasoning, 8_192)
      required = mapping["continuation_required"]

      think = fn n ->
        if required, do: [{:thinking, "cut #{cell}.#{n}", "cut-#{cell}-#{n}+/="}], else: []
      end

      last = if final_thinking?, do: think.(2), else: []

      replies = [
        R.reply(
          model,
          think.(0) ++ [{:tool, "cut-read-#{cell}", "read", %{"path" => "a.txt"}}],
          "tool_use"
        ),
        R.reply(model, think.(1) ++ [{:text, "cedar"}]),
        R.reply(model, last ++ [{:text, "cedar"}])
      ]

      if cell == 0, do: replies, else: [summary | replies]
    end)
  end

  @tag timeout: 300_000
  test "thinking bound cuts each cell after its tool group and resumes native thinking", f do
    cells = Mix.Tasks.Loopex.M7Evidence.Scenarios.bound_cells()

    fixture =
      Loopex.LLM.ReqLLM.ProviderIsolationFixture.new(:reply,
        credential: "m7-thinking-bound-synthetic",
        response_bodies: cut_replies(cells)
      )

    result =
      passed!(
        scenario!(f, "m7.thinking-bound", fn _ -> [] end, %{chat_options: native!(f, fixture)})
      )

    assert facts(result)["kinds"]["run_terminal_committed"] == 3 * length(cells)
  end

  @tag timeout: 300_000
  test "thinking bound without resumed native thinking is required_action_absent", f do
    cells = Mix.Tasks.Loopex.M7Evidence.Scenarios.bound_cells()

    fixture =
      Loopex.LLM.ReqLLM.ProviderIsolationFixture.new(:reply,
        credential: "m7-thinking-bound-synthetic",
        response_bodies: cut_replies(cells, false)
      )

    assert {:stopped, [{:ok, result}]} =
             scenario!(f, "m7.thinking-bound", fn _ -> [] end, %{
               chat_options: native!(f, fixture)
             })

    assert result.mechanical_result == "required_action_absent"
    assert facts(result)["join"] =~ "native_thinking"
  end

  # The held second request never reaches the fixture: the abort cancels it
  # before transport, so only the tool reply and the two later replies exist.
  @tag timeout: 120_000
  test "thinking cancel aborts the gated second request and resumes native thinking", f do
    cell = Mix.Tasks.Loopex.M7Evidence.Scenarios.cancel_cell()
    [_summaryless | _] = replies = cut_replies([cell])

    fixture =
      Loopex.LLM.ReqLLM.ProviderIsolationFixture.new(:reply,
        credential: "m7-thinking-cancel-synthetic",
        response_bodies: replies
      )

    result =
      passed!(
        scenario!(f, "m7.thinking-cancel", fn _ -> [] end, %{chat_options: native!(f, fixture)})
      )

    inputs = File.read!(Path.join(result.root, "records/input-1.txt"))
    [held, abort] = Enum.map([":gate_held", "/abort"], &elem(:binary.match(inputs, &1), 0))
    assert held < abort
    assert facts(result)["kinds"]["run_terminal_committed"] == 3
  end

  # Concept: provider A is the local Anthropic fixture and provider B the
  # manifest's pinned OpenAI model on the same local endpoint; the switch,
  # reopen and return run on chat's real composition and adapter.
  test "provider switch moves A to B, reopens and returns to A with its tool facts", f do
    alias LoopexCli.M7NativeReplies, as: R
    a = "anthropic:claude-haiku-4-5-20251001"

    fixture =
      Loopex.LLM.ReqLLM.ProviderIsolationFixture.new(:reply,
        credential: "m7-provider-switch-synthetic",
        response_bodies: [
          R.reply(a, [{:tool, "read-1", "read", %{"path" => "README.md"}}], "tool_use"),
          R.reply(a, [{:text, "remembered"}]),
          R.responses("M7 scenario workspace."),
          R.reply(a, [{:text, "M7 scenario workspace."}])
        ]
      )

    result =
      passed!(
        scenario!(f, "m7.provider-switch", fn _ -> [] end, %{
          chat_options: native!(f, fixture)
        })
      )

    assert facts(result)["kinds"]["session_configuration_admitted_v2"] == 2
  end

  test "provider switch with no pinned provider B refuses before dispatch", f do
    manifest =
      update_in(
        lane(f.context.manifest, ["m7.provider-switch"]),
        ["execution_manifest", "providers"],
        &Map.delete(&1, "b")
      )

    assert {:stopped, [{:ok, refused}]} =
             scenario!(f, "m7.provider-switch", fn _ -> [] end, %{manifest: manifest})

    assert refused.mechanical_result == "evidence_incomplete_pre_dispatch"
  end

  defp restart_script(f) do
    [%{"arguments" => question}] =
      f.context.manifest["fixtures"]["feature"]["required_model_actions"]

    fn
      _capture, 1 ->
        [%{text: "ask", calls: [%{id: "nil-choice", name: "ask", arguments: question}]}]

      capture, _ ->
        [
          %{
            text: "implement",
            calls: [
              %{
                id: "write",
                name: "write",
                arguments: %{"path" => "lib/row_encoder.ex", "content" => encoder("literal_null")}
              }
            ]
          },
          %{
            text: "test",
            calls: [
              %{
                id: "oracle",
                name: "bash",
                arguments: %{"argv" => capture.argv ++ ["literal_null"]}
              }
            ]
          },
          %{text: "done", calls: []}
        ]
    end
  end

  test "question restart keeps the pending identity through process loss and answers it after reopen",
       f do
    script = restart_script(f)

    context =
      Map.merge(f.context, %{
        manifest: lane(f.context.manifest, ["m7.question-restart"]),
        answers: %{"m7.question-restart" => "choice-2"},
        chat_options: chat_options(f, script, self())
      })

    result = passed!(CaseRunner.run_lane(f.writer, "m7-operator", context))
    assert facts(result)["kinds"]["model_question_requested_v1"] == 1
    assert File.read!(Path.join(result.root, "records/input-1.txt")) =~ "process_loss"
    assert File.read!(Path.join(result.root, "records/input-2.txt")) =~ "/answer "
  end

  # Under --terminal the loss stays harness-driven while the operator types
  # the answer to the emitted question on their own device.
  test "an attended question restart takes the operator's typed choice after the loss", f do
    {:ok, operator} = StringIO.open("2\n")

    context =
      Map.merge(f.context, %{
        manifest: lane(f.context.manifest, ["m7.question-restart"]),
        dispatch: :terminal,
        operator_device: operator,
        chat_options: chat_options(f, restart_script(f), self())
      })

    result = passed!(CaseRunner.run_lane(f.writer, "m7-operator", context))
    {_, shown} = StringIO.contents(operator)
    assert shown =~ "question: Which default should nil_mode use?" and shown =~ "2. literal_null"
    assert File.read!(Path.join(result.root, "records/input-1.txt")) =~ "process_loss"
    assert File.read!(Path.join(result.root, "records/input-2.txt")) =~ "/answer "
  end

  # Concept: a held tool call is released only after the observer joins the
  # active run, its operation and the accepted steer and follow-up.
  defp held_script(after_release) do
    fn capture, _call ->
      [
        %{
          text: "hold",
          calls: [%{id: "hold", name: "bash", arguments: %{"argv" => capture.argv}}]
        }
        | after_release
      ]
    end
  end

  test "steer and follow-up are admitted while the held call runs and only then released", f do
    context =
      Map.merge(f.context, %{
        manifest: lane(f.context.manifest, ["m7.steer-barrier"]),
        chat_options:
          chat_options(
            f,
            held_script([%{text: "STEERED", calls: []}, %{text: "followed", calls: []}]),
            self()
          )
      })

    result = passed!(CaseRunner.run_lane(f.writer, "m7-operator", context))
    inputs = File.read!(Path.join(result.root, "records/input-1.txt"))
    [observed, released] = Enum.map([":observed", ":released"], &:binary.match(inputs, &1))
    assert elem(observed, 0) < elem(released, 0)
    assert facts(result)["kinds"]["run_terminal_committed"] == 2
  end

  test "a held call that is never made is required_action_absent and nothing is released", f do
    context =
      Map.merge(f.context, %{
        manifest: lane(f.context.manifest, ["m7.steer-barrier"]),
        step_deadline_ms: 1_000,
        chat_options:
          chat_options(f, fn _capture, _call -> [%{text: "no", calls: []}] end, self())
      })

    {:stopped, [{:ok, result}]} = CaseRunner.run_lane(f.writer, "m7-operator", context)
    assert result.mechanical_result == "required_action_absent"
    refute File.read!(Path.join(result.root, "records/input-1.txt")) =~ ":released"
  end

  test "an expired hold is a retained failure even though the run then completes", f do
    context =
      Map.merge(f.context, %{
        manifest: lane(f.context.manifest, ["m7.steer-barrier"]),
        hold_limit_ms: 1,
        chat_options: chat_options(f, held_script([%{text: "done", calls: []}]), self())
      })

    {:stopped, [{:ok, result}]} = CaseRunner.run_lane(f.writer, "m7-operator", context)
    assert result.mechanical_result == "assertion_failed"
    assert File.read!(Path.join(result.root, "records/input-1.txt")) =~ ":hold_expired"
  end

  # Run as check-release runs the operator lane: under --terminal, whose
  # harness-driven steps keep the piped device.
  test "an interrupt cancels the held call without releasing it and cleanup is confirmed", f do
    context =
      Map.merge(f.context, %{
        manifest: lane(f.context.manifest, ["m7.interrupt"]),
        dispatch: :terminal,
        chat_options: chat_options(f, held_script([%{text: "late", calls: []}]), self())
      })

    result = passed!(CaseRunner.run_lane(f.writer, "m7-operator", context))
    inputs = File.read!(Path.join(result.root, "records/input-1.txt"))
    assert inputs =~ ":interrupt"
    refute inputs =~ ":released"
  end

  # Concept: the held run lives in an in-VM daemon host under the fixture
  # policy; its driver's connection closes, it reattaches, an observer joins
  # the same active run, and only then is the runner released.
  @tag timeout: 120_000
  test "a daemon run survives its driver detaching and completes after the observer joins", f do
    alias LoopexCli.M7NativeReplies, as: R
    model = "anthropic:claude-haiku-4-5-20251001"
    runner = Path.join([f.context.run_root, "m7.daemon-detach-d7a1", "trusted", "hold.sh"])

    fixture =
      Loopex.LLM.ReqLLM.ProviderIsolationFixture.new(:reply,
        credential: "m7-daemon-detach-synthetic",
        response_bodies: [
          R.reply(
            model,
            [{:tool, "hold-1", "bash", %{"argv" => ["/bin/sh", runner]}}],
            "tool_use"
          ),
          R.reply(model, [{:text, "released"}])
        ]
      )

    options = native!(f, fixture)

    context =
      Map.merge(f.context, %{
        manifest: lane(f.context.manifest, ["m7.daemon-detach"]),
        attempt_nonce: "d7a1",
        step_deadline_ms: 20_000,
        daemon_launch: options[:provider_launch].()
      })

    result = passed!(CaseRunner.run_lane(f.writer, "m7-operator", context))
    inputs = File.read!(Path.join(result.root, "records/input-1.txt"))
    assert inputs =~ ":driver_closed" and inputs =~ ":released"
    assert facts(result)["kinds"]["run_terminal_committed"] == 1
  end

  # Concept: the attended restore joins the rollback lane's exact retained
  # execution, produced here by running that lane's own restore test.
  # Technical depth: the producer runs as the release lane runs it, in its
  # app with M7_RESTORE_RETAIN naming the directory beside the run root.
  @tag timeout: 300_000
  test "the attended restore verifies, restores and inspects the retained rollback execution",
       f do
    retained = Path.join(Path.dirname(f.context.run_root), "m7-restore-source")
    composition = Path.expand("../../loopex_composition", __DIR__)

    {output, status} =
      System.cmd("mix", ["test", "test/restore_workflow_test.exs:77"],
        cd: composition,
        env: [{"M7_RESTORE_RETAIN", retained}, {"MIX_ENV", "test"}],
        stderr_to_stdout: true
      )

    assert status == 0, output

    context =
      Map.merge(f.context, %{
        manifest: lane(f.context.manifest, ["m7.restore"]),
        answers: %{"m7.restore" => "confirm"}
      })

    result = passed!(CaseRunner.run_lane(f.writer, "m7-operator", context))
    checks = facts(result)["checks"]
    assert checks["old_root_prevented"] and checks["manifest_complete"]
    assert checks["restored_history"] and checks["operator_confirmed"]
  end

  test "a restore without the rollback lane's retained execution is required_action_absent", f do
    context =
      Map.merge(f.context, %{
        manifest: lane(f.context.manifest, ["m7.restore"]),
        answers: %{"m7.restore" => "confirm"}
      })

    assert {:stopped, [{:ok, result}]} = CaseRunner.run_lane(f.writer, "m7-operator", context)
    assert result.mechanical_result == "required_action_absent"
    assert facts(result)["join"] =~ "retained_execution"
  end

  test "the wrapper command checks admission without staging and refuses bad arguments", f do
    :ok = AttemptWriter.close(f.writer)
    root = Path.expand("../../..", __DIR__)

    args = [
      "--lane",
      "m7-operator",
      "--attempts-index",
      f.index,
      "--writer",
      "writer-1",
      "--host",
      "host-1",
      "--markers",
      Path.join(f.root, "markers"),
      "--run-root",
      Path.join(f.root, "runs"),
      "--operator",
      "Maintainer",
      "--check",
      "chat",
      "--config",
      f.config
    ]

    output =
      ExUnit.CaptureIO.capture_io(fn ->
        assert CaseRunner.main(args, %{root: root, candidate: @candidate}) == 2
      end)

    # Admission refuses before staging: this campaign has no committed head.
    assert output =~ "committed_attempt_head_unavailable"
    assert File.ls!(Path.join(f.root, "runs")) == []

    output =
      ExUnit.CaptureIO.capture_io(fn ->
        assert CaseRunner.main(
                 List.delete(args, "--check") -- ["chat", "--config", f.config],
                 %{root: root, candidate: @candidate}
               ) == 2
      end)

    assert output =~ "evidence unavailable"

    script = Path.join(root, "scripts/m7-fixture-chat.exs")
    assert File.read!(script) =~ "CaseRunner.main"
  end

  defp encoder(default) do
    """
    defmodule RowEncoder do
      def encode(values, options \\\\ []) do
        mode = Keyword.get(options, :nil_mode, :#{default})
        Enum.map_join(values, ",", &value(&1, mode))
      end

      defp value(nil, :empty), do: ""
      defp value(nil, :literal_null), do: "null"
      defp value(value, _mode), do: to_string(value)
    end
    """
  end

  # The long case's configuration and scripts. `explain_tokens` sets the second
  # reply's reported output, which decides whether automatic compaction occurs.
  defp long_case(f, explain_tokens) do
    profile =
      profile(f.root)
      |> put_in(["session", "max_tokens"], 4096)
      |> put_in(["session", "context_token_budget"], 4000)
      |> put_in(["session", "system_class_tokens"], 3000)
      |> Map.put("maintenance", %{"model" => "anthropic:claude-haiku-4-5"})

    File.write!(f.config, :json.encode(profile))

    summary = %{
      text:
        ~s({"summary":"release_prefix=amber; batch_size=3","carry_forward":{"files_read":[],"files_changed":[]}}),
      usage: %{input_tokens: 37, output_tokens: 19},
      reply_overrides: %{completion: "natural", continuation: nil}
    }

    script = fn capture, call ->
      main =
        if call == 1 do
          [
            %{text: "release_prefix=amber; batch_size=3", calls: []},
            %{
              text:
                String.duplicate(
                  "Keep dependent release steps consistent. ",
                  div(explain_tokens, 10)
                ),
              calls: [],
              usage: %{input_tokens: 1500, output_tokens: explain_tokens}
            },
            %{text: "release_prefix=amber; batch_size=3", calls: []}
          ]
        else
          [
            %{
              text: "write retained facts",
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
            %{
              text: "verify",
              calls: [%{id: "oracle", name: "bash", arguments: %{"argv" => capture.argv}}]
            },
            %{text: "done", calls: []}
          ]
        end

      %{main: main, maintenance: List.duplicate(summary, 8)}
    end

    {%{f.context | manifest: lane(f.context.manifest, ["m7.long"])}, script}
  end

  # A failed pass expectation reports the retained transcripts and oracle.
  defp passed!({:ok, [{:ok, %{mechanical_result: "pass"} = result}]}), do: result

  defp passed!({_, [{:ok, %{root: root}} | _]} = other) do
    records = Path.join(root, "records")

    # The tail of each record holds the conversation's ending and errors.
    retained =
      for name <- File.ls!(records), into: %{} do
        bytes = File.read!(Path.join(records, name))
        {name, binary_part(bytes, max(byte_size(bytes) - 2_000, 0), min(byte_size(bytes), 2_000))}
      end

    flunk(inspect(%{lane: elem(other, 0), records: retained}, pretty: true, limit: :infinity))
  end

  # A pre-dispatch stop reports its retained refusal.
  defp passed!({_, [{:ok, %{record: %{"body" => %{"state" => "not_dispatched"} = body}}} | _]}) do
    refusals = for %{"reference" => path} <- body["evidence"], do: File.read!(path)
    flunk("not dispatched: " <> Enum.join(refusals, " "))
  end

  defp passed!(other), do: flunk(inspect(other))

  defp repair_script(argv, content) do
    [
      %{text: "the empty ledger reaches a missing base case", calls: []},
      %{
        text: "fix",
        calls: [
          %{
            id: "fix",
            name: "write",
            arguments: %{"path" => "lib/ledger.ex", "content" => content}
          }
        ]
      },
      %{text: "fixed", calls: []},
      %{text: "test", calls: [%{id: "oracle", name: "bash", arguments: %{"argv" => argv}}]},
      %{text: "tested", calls: []}
    ]
  end

  # The composition options are the real chat's, including the reference
  # host's maintenance instructions; only the model and executor are scripted.
  # A helper parent needs the real placement lock its owner records; other
  # cases stub placement so a prescribed process loss leaves no lock behind.
  defp chat_options(_f, scripts, parent, placement \\ :stub) do
    {:ok, calls} = Agent.start_link(fn -> 0 end)

    stub =
      if placement == :stub,
        do: [
          acquire_placement: fn _, _ -> {:ok, :test_lock} end,
          release_placement: fn _, _ -> :ok end
        ],
        else: []

    stub ++
      [
        provider_launch: fn -> [] end,
        placement_id: fn _ -> {:ok, "case-runner-runtime"} end,
        with_runtime: fn options, callback ->
          call = Agent.get_and_update(calls, &{&1 + 1, &1 + 1})
          capture = policy_context(options)

          index =
            Path.join([
              Path.dirname(Path.dirname(Path.dirname(options[:workspace]))),
              "attempts.jsonl"
            ])

          send(parent, {:index_at_dispatch, call, records(index)})
          with_stack(options, scripts.(capture, call), callback)
        end
      ]
  end

  # A fixture case's capture, or nil under the operator's ordinary policy.
  defp policy_context(options) do
    case options[:policy] do
      %{context: context} -> context
      _ -> nil
    end
  end

  defp with_stack(options, script, callback) do
    state = options[:state_root]
    File.mkdir_p!(state)
    {:ok, adapter} = Loopex.Store.Local.start_link(path: Path.join(state, "store.log"))
    {:ok, store} = Loopex.Store.new(Loopex.Store.Local, adapter)
    {:ok, physical} = LoopexComposition.WorkspaceIdentity.resolve_path(options[:workspace])
    {:ok, workspace_ref} = LoopexComposition.WorkspaceIdentity.reference(physical)

    {:ok, lease} =
      Loopex.Executor.Local.WorkspaceLease.start_link(
        id: "workspace",
        path: options[:workspace],
        fencing_token: 1
      )

    {:ok, executor} =
      Loopex.Executor.Local.start_link(
        identity: "fixture-executor",
        epoch: 1,
        fencing_token: 1,
        workspace_leases: %{"workspace" => lease},
        ledger_root: Path.join(state, "receipts")
      )

    {main, maintenance} =
      case script do
        %{main: main, maintenance: maintenance} -> {main, maintenance}
        main -> {main, []}
      end

    model = Loopex.AgentLoopTestModel.start(main)
    summarizer = Loopex.AgentLoopTestModel.start(maintenance)

    {:ok, maintenance_model} =
      LoopexComposition.ProviderBindings.resolve_maintenance_routes(
        options[:maintenance_model],
        Map.keys(options[:provider_bindings] || %{"anthropic" => nil})
      )

    {:ok, runtime} =
      Loopex.start_link(
        runtime_id: "case-runner-runtime",
        context_token_budget: 8192,
        store: store,
        policy: options[:policy],
        policy_identity: options[:policy_identity],
        model: %{
          module: PurposeModel,
          model: options[:model],
          options: [script: model, maintenance_script: summarizer]
        },
        maintenance_model: maintenance_model,
        maintenance_instructions: options[:maintenance_instructions],
        executor:
          helper_executor(options[:delegation], %{
            module: Loopex.Executor.Local,
            reference: executor,
            identity: "fixture-executor",
            epoch: 1,
            fencing_token: 1,
            workspace_ref: workspace_ref,
            workspace_lease: "workspace"
          }),
        tools:
          ChatConfiguration.selected_definitions(ChatConfiguration.active_tools("coding")) ++
            helper_tools(options[:delegation]),
        cleanup_grace_ms: options[:cleanup_grace_ms]
      )

    {:ok, startup_deadline} = LoopexComposition.StartupGate.await(runtime)
    :ok = LoopexComposition.StartupGate.publication({:ok, startup_deadline})

    # A helper parent binds its composed helper owner to this runtime and store.
    if match?(%{enabled: true}, options[:delegation]),
      do: :ok = LoopexComposition.Delegation.bind(options[:delegation], runtime, store)

    try do
      callback.(runtime)
    after
      ref = Process.monitor(runtime.supervisor)
      :ok = Loopex.stop(runtime)
      assert_receive {:DOWN, ^ref, :process, _, _}, 5000

      for pid <- [executor, lease, adapter, model, summarizer], is_pid(pid) do
        Process.unlink(pid)
        if Process.alive?(pid), do: GenServer.stop(pid, :normal, 1000)
      end
    end
  end

  # Concept: a native case runs chat's real composition, store and executor
  # with the real adapter; only the provider endpoint is the local fixture.
  # Technical depth: the fixture's launch options are chat's provider launch,
  # and its synthetic credential sits in the profile's named variable.
  @native_variable "M7_NATIVE_FIXTURE_CREDENTIAL"

  defp native!(f, fixture, change \\ & &1) do
    # Provider A's test variable and provider B's pinned name hold the one
    # synthetic fixture credential for this test only.
    for name <- [@native_variable, "OPENAI_API_KEY"] do
      previous = System.get_env(name)
      System.put_env(name, fixture.credential)

      on_exit(fn ->
        if previous, do: System.put_env(name, previous), else: System.delete_env(name)
      end)
    end

    profile =
      profile(f.root)
      |> put_in(["providers", "anthropic"], %{"credential" => %{"env" => @native_variable}})
      |> change.()

    File.write!(f.config, :json.encode(profile))

    [
      provider_launch: fn ->
        Keyword.drop(fixture.options, [
          :credential_token,
          :credential_registry,
          :tracing_capability
        ])
      end,
      placement_id: fn _ -> {:ok, "case-runner-native"} end
    ]
  end

  defp helper_executor(%{enabled: true, helper: helper}, executor),
    do: LoopexComposition.Delegation.Router.wrap(executor, helper)

  defp helper_executor(_delegation, executor), do: executor

  # As the real composition does, the runtime registers every profile's tools
  # (coding, and read-only for scenarios and helper children); sessions select.
  defp helper_tools(delegation) do
    coding = ChatConfiguration.active_tools("coding")
    read_only = ChatConfiguration.active_tools("read-only") -- coding

    ChatConfiguration.selected_definitions(read_only) ++
      if match?(%{enabled: true}, delegation),
        do: [LoopexComposition.Delegation.Tool.definition()],
        else: []
  end

  defp profile(root) do
    %{
      "schema_version" => 1,
      "providers" => %{
        "anthropic" => %{"credential" => %{"env" => "M7_UNUSED_FIXTURE_REFERENCE"}}
      },
      "policy" => "shell-allowlist",
      "paths" => %{"workspace" => root, "state_root" => Path.join(root, "unused")},
      "session" => %{
        "model" => "anthropic:claude-haiku-4-5",
        "tools" => "coding",
        "system_class_tokens" => 8000,
        "bounds" => %{"max_turns" => 8, "deadline_ms" => 15_000, "token_budget" => 100_000}
      }
    }
  end

  defp external_catalog(root) do
    repository = Path.join(root, "lapaxworks")
    File.mkdir_p!(Path.join(repository, "tools"))
    File.write!(Path.join(repository, "tools/threads.py"), base_threads())
    File.write!(Path.join(repository, "README.md"), "fixture\n")
    git = &System.cmd("git", ["-C", repository | &1], stderr_to_stdout: true)
    {_, 0} = git.(["init", "-q"])
    {_, 0} = git.(["add", "."])

    {_, 0} =
      git.([
        "-c",
        "user.name=Fixture",
        "-c",
        "user.email=fixture@invalid",
        "-c",
        "commit.gpgsign=false",
        "commit",
        "-qm",
        "fixture"
      ])

    {sha, 0} = git.(["rev-parse", "HEAD"])
    catalog_root = Path.join(root, "catalog")
    File.cp_r!(@fixtures, catalog_root)
    manifest = Path.join(catalog_root, "manifest.json")
    catalog = JSON.decode!(File.read!(manifest))
    catalog = put_in(catalog, ["external", "base_sha"], String.trim(sha))
    File.write!(manifest, JSON.encode!(catalog))
    {catalog_root, repository}
  end

  defp base_threads do
    """
    import re
    import sys


    def slugify(name):
        return re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-")


    if __name__ == "__main__":
        if "--check" in sys.argv:
            print("threads: up to date")
    """
  end

  defp lane(catalog, cases) do
    lanes = catalog["execution_manifest"]["lanes"]

    catalog
    |> put_in(["execution_manifest", "lanes"], %{lanes | "m7-operator" => cases})
    |> update_in(["execution_manifest", "cases"], fn all ->
      Map.new(all, fn {id, entry} ->
        {id, if(id in cases, do: %{entry | "status" => "ready"}, else: entry)}
      end)
    end)
  end

  defp lane_selection(f) do
    {:ok, selection} =
      Mix.Tasks.Loopex.M7Evidence.ExecutionManifest.selection(
        f.context.manifest["execution_manifest"],
        f.context.manifest_digest,
        "m7-operator",
        @candidate,
        nil
      )

    selection
  end

  defp records(index) do
    index
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(fn line ->
      {:ok, record} = AttemptEvents.decode(line)
      record
    end)
  end

  defp head_line(record),
    do: "index-head: #{record["campaign_id"]} #{record["sequence"]} #{record["digest"]}"

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
end
