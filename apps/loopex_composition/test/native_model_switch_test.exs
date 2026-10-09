# Concept: load the shared real-transport fixture only under a disposable home.
# Technical depth: its Core support guard runs before ExUnit setup.
fixture_home =
  Path.join(System.tmp_dir!(), "native-switch-load-#{System.unique_integer([:positive])}")

File.mkdir_p!(fixture_home)
prior_home = System.get_env("LOOPEX_HOME")
System.put_env("LOOPEX_HOME", fixture_home)

try do
  Code.require_file(
    "../../loopex_llm_reqllm/test/support/provider_isolation_fixture.exs",
    __DIR__
  )

  Code.require_file("../../loopex/test/support/configured_genesis_helper.exs", __DIR__)
after
  if prior_home,
    do: System.put_env("LOOPEX_HOME", prior_home),
    else: System.delete_env("LOOPEX_HOME")

  File.rm_rf!(fixture_home)
end

defmodule LoopexComposition.NativeModelSwitchTest do
  use ExUnit.Case, async: false

  alias Loopex.LLM.ReqLLM.ProviderIsolationFixture, as: Fixture
  alias Loopex.Runtime.{Instructions, OwnerGroup, SessionCoordinator, SessionState}
  alias Loopex.Store.Local
  alias Loopex.Store.Local.Artifacts
  alias Loopex.{ArtifactStore, ProgressSink}
  alias Loopex.Trace.Capability
  alias Loopex.Executor.Local, as: LocalExecutor
  alias Loopex.Executor.Local.WorkspaceLease
  alias Loopex.Executor.Local.CodingTools
  alias LoopexProtocol.{Canonical, Frame}
  alias LoopexComposition.WorkspaceIdentity
  alias LoopexComposition.{Model, ProviderBindings}

  @model_a "anthropic:claude-fable-5-1"
  @model_b "anthropic:claude-haiku-4-5-20251001"
  @key "native-switch-synthetic-credential"
  @private_a "FIRST_PRIVATE_THINKING_CANARY"
  @signature_a "first-private-signature+/="
  @private_next "SECOND_PRIVATE_THINKING_CANARY"
  @signature_next "second-private-signature+/="

  setup do
    root = Path.join(System.tmp_dir!(), "native-switch-#{System.unique_integer([:positive])}")
    home = Path.join(root, "home")
    workspace = Path.join(root, "workspace")
    File.mkdir_p!(home)
    File.mkdir_p!(workspace)
    previous = Map.new(~w(LOOPEX_HOME LOOPEX_WORKSPACE), &{&1, System.get_env(&1)})
    System.put_env("LOOPEX_HOME", home)
    System.put_env("LOOPEX_WORKSPACE", workspace)

    on_exit(fn ->
      for {name, value} <- previous do
        if value, do: System.put_env(name, value), else: System.delete_env(name)
      end

      File.rm_rf!(root)
    end)

    {:ok, root: root}
  end

  test "real isolated transport preserves A to B to A history across physical Store reopen", %{
    root: root
  } do
    {:links, before_links} = Process.info(self(), :links)
    http_nonce = make_ref()

    fixture =
      Fixture.new(:delayed_entry,
        http_custody: {self(), http_nonce},
        credential: @key,
        response_bodies: [
          response(@model_a, "The gate is cedar.", {@private_a, @signature_a}),
          response(@model_b, "The gate stays cedar; the count is seven.", nil),
          response(
            @model_a,
            "Cedar and seven remain the facts.",
            {@private_next, @signature_next}
          )
        ]
      )

    {:links, after_links} = Process.info(self(), :links)
    fixture_links = after_links -- before_links
    fixture_ports = Enum.filter(fixture_links, &is_port/1)
    assert length(fixture_ports) == 2 and fixture.listener in fixture_ports
    # Concept: original factory actors have caller-scoped identities before work.
    # Technical depth: the fixture creates its hidden probe with spawn_link; the
    # link delta includes that exact actor, without a global trace or new port.
    fixture_actors = Enum.filter(fixture_links, &is_pid/1) ++ [fixture.store_pid]
    {:ok, fixture_children} = Loopex.Runtime.children(fixture.runtime)
    fixture_monitors = monitor(fixture_actors ++ Map.values(fixture_children))
    path = Path.join(root, "state.log")
    # Concept: physical reopen preserves the session's creating runtime identity.
    # Technical depth: process incarnations and tracing capabilities change;
    # the Store's durable placement ID is captured once for both starts.
    runtime_id = "switch-#{System.unique_integer([:positive])}"

    model =
      Model.reference(%{module: Loopex.LLM.ReqLLM, model: @model_a, options: fixture.options},
        provider_bindings: bindings()
      )

    initial = initial_configuration()
    assert initial["context_token_budget"] == 8_192
    assert initial["system_class_tokens"] == 1_000

    try do
      {session, prefix_records, prefix_events, first_runs, configured_b} =
        with_runtime(path, model, runtime_id, fn runtime, store, custody ->
          assert {:ok, session} =
                   Loopex.create_session(runtime, %{},
                     command_id: "create",
                     genesis: Loopex.ConfiguredGenesisFixture.genesis([], initial)
                   )

          assert {:ok, attachment} = Loopex.attach(runtime, session, after_event_sequence: 0)

          first =
            run(runtime, attachment, fixture, custody, "prompt-a", "Remember: the gate is cedar.")

          configured_b =
            configure(attachment, model, initial, "configure-b", %{
              "model" => "anthropic:claude-haiku-4-5",
              "reasoning" => "none"
            })

          assert configured_b["model"] == @model_b
          assert configured_b["context_token_budget"] == 8_192
          assert configured_b["system_class_tokens"] == 1_000

          second =
            run(
              runtime,
              attachment,
              fixture,
              custody,
              "prompt-b",
              "Keep cedar; add the count seven."
            )

          {records, events, state} = history(store, session)
          assert state.configuration == configured_b

          assert Enum.map(
                   state.run_order,
                   &SessionState.run_configuration(state, &1)["configuration_version"]
                 ) == [1, 2]

          assert Enum.map(state.run_order, &SessionState.run_configuration(state, &1)["model"]) ==
                   [@model_a, @model_b]

          assert state.run_order == [first, second]
          [settled_a, _settled_b] = settlements(records)
          capsule = settled_a.payload["result"]["reply"]["continuation"]
          assert is_map(capsule)
          assert capsule["status"] == "closed"
          assert capsule["model"] == @model_a
          assert :erlang.term_to_binary(capsule) =~ @private_a
          assert :erlang.term_to_binary(capsule) =~ @signature_a
          assert_public_private_absence(events, attachment)
          {session, records, events, state.run_order, configured_b}
        end)

      assert length(Fixture.events(fixture)) == 2
      before_reopen = File.read!(path)

      with_runtime(path, model, runtime_id, fn runtime, store, custody ->
        assert {:ok, ^session} = Loopex.resume_session(runtime, session, command_id: "resume")
        {resumed_records, resumed_events, resumed} = history(store, session)
        assert Enum.take(resumed_records, length(prefix_records)) == prefix_records
        assert Enum.take(resumed_events, length(prefix_events)) == prefix_events
        assert resumed.configuration == configured_b
        assert resumed.configuration["context_token_budget"] == 8_192
        assert resumed.configuration["system_class_tokens"] == 1_000
        assert resumed.run_order == first_runs
        assert length(Fixture.events(fixture)) == 2
        assert String.starts_with?(File.read!(path), before_reopen)

        assert {:ok, attachment} =
                 Loopex.attach(runtime, session, after_event_sequence: resumed.event_sequence)

        configured_a =
          configure(attachment, model, configured_b, "configure-a", %{
            "model" => @model_a,
            "reasoning" => "low"
          })

        third =
          run(
            runtime,
            attachment,
            fixture,
            custody,
            "prompt-a-again",
            "Repeat both retained facts."
          )

        {records, events, state} = history(store, session)
        assert state.configuration == configured_a
        assert state.run_order == first_runs ++ [third]
        configurations = Enum.map(state.run_order, &SessionState.run_configuration(state, &1))
        assert configurations == [initial, configured_b, configured_a]
        assert Enum.map(configurations, & &1["configuration_version"]) == [1, 2, 3]
        assert Enum.map(configurations, & &1["model"]) == [@model_a, @model_b, @model_a]
        assert Enum.map(configurations, & &1["reasoning"]) == ["low", "none", "low"]
        assert Enum.all?(configurations, &(&1["max_tokens"] == 1_024))
        assert Enum.all?(configurations, &(&1["context_token_budget"] == 8_192))
        assert Enum.all?(configurations, &(&1["system_class_tokens"] == 1_000))
        [_, _, settled_again] = settlements(records)
        capsule_again = settled_again.payload["result"]["reply"]["continuation"]
        assert capsule_again["status"] == "closed"
        assert capsule_again["model"] == @model_a
        assert :erlang.term_to_binary(capsule_again) =~ @private_next
        assert :erlang.term_to_binary(capsule_again) =~ @signature_next
        assert length(settlements(records)) == 3

        assert length(Enum.filter(records, &(&1.payload.kind == "model_request_committed_v2"))) ==
                 3

        assert_public_private_absence(events, attachment)
      end)

      assert [{body_a, true}, {body_b, true}, {body_again, true}] = Fixture.events(fixture)

      assert Enum.map([body_a, body_b, body_again], & &1["model"]) ==
               ["claude-fable-5-1", "claude-haiku-4-5-20251001", "claude-fable-5-1"]

      assert Enum.all?([body_a, body_b, body_again], &(&1["max_tokens"] == 1_024))
      assert body_a["thinking"] == %{"type" => "adaptive", "display" => "summarized"}
      assert body_again["thinking"] == body_a["thinking"]
      assert body_a["output_config"] == %{"effort" => "low"}
      assert body_again["output_config"] == body_a["output_config"]
      assert body_b["thinking"] == %{"type" => "disabled"}
      refute Map.has_key?(body_b, "output_config")

      assert body_a["messages"] ==
               messages([
                 {"user", "Remember: the gate is cedar."}
               ])

      assert body_b["messages"] ==
               messages([
                 {"user", "Remember: the gate is cedar."},
                 {"assistant", "The gate is cedar."},
                 {"user", "Keep cedar; add the count seven."}
               ])

      assert body_again["messages"] ==
               messages([
                 {"user", "Remember: the gate is cedar."},
                 {"assistant", "The gate is cedar."},
                 {"user", "Keep cedar; add the count seven."},
                 {"assistant", "The gate stays cedar; the count is seven."},
                 {"user", "Repeat both retained facts."}
               ])

      for body <- [body_a, body_b, body_again], private <- private_values() do
        refute Jason.encode!(body) =~ private
      end

      assert Fixture.methods(fixture) == ["POST", "POST", "POST"]
    after
      # Concept: fixture infrastructure is retired before its disposable files.
      # Technical depth: all original factory monitors predate the first request;
      # one captured cleanup endpoint covers sockets, runtime, servers and joins.
      cutoff = now() + 5_000
      for port <- fixture_ports, do: :ok = :gen_tcp.close(port)
      if Loopex.Runtime.alive?(fixture.runtime), do: assert(:ok == Loopex.stop(fixture.runtime))

      for pid <- [
            fixture.workers,
            fixture.capability_pid,
            fixture.store_pid,
            fixture.registry_pid,
            fixture.custody_pid,
            fixture.events,
            fixture.transport_events,
            fixture.probe_events,
            fixture.request_headers
          ] do
        if Process.alive?(pid), do: assert(:ok == GenServer.stop(pid, :normal, left(cutoff)))
      end

      join(fixture_monitors, cutoff)
    end
  end

  defmodule Policy do
    @moduledoc false
    @behaviour Loopex.Policy
    @impl true
    def decide(_request), do: {:allow, nil}
  end

  for {variant, reasoning, thinking, disclosed} <- [
        {:verified, "low", "PERMITTED_SUMMARY_CANARY", true},
        {:empty, "low", "", false},
        {:unverified, "default", "UNVERIFIED_PRIVATE_THINKING_CANARY", false}
      ] do
    test "#{variant} native summary keeps progress, canonical history and private outputs distinct",
         %{
           root: root
         } do
      privacy_workflow(
        root,
        unquote(variant),
        unquote(reasoning),
        unquote(thinking),
        unquote(disclosed)
      )
    end
  end

  test "native private continuation stays out of a real tool-created artifact across reopen", %{
    root: root
  } do
    tool_artifact_privacy_workflow(root)
  end

  defp privacy_workflow(root, variant, reasoning, thinking, disclosed) do
    answer = "PUBLIC_ANSWER_CANARY"
    signature = "private-signature-canary+/="
    redacted = "PRIVATE_REDACTED_CANARY"

    native = [
      %{"type" => "thinking", "thinking" => thinking, "signature" => signature},
      %{"type" => "redacted_thinking", "data" => redacted},
      %{"type" => "text", "text" => answer}
    ]

    # Concept: output observations use the shipped registered cell, never a
    # supplied disclosure flag or a fabricated model callback.
    # Technical depth: Fable default omits thinking controls but still captures
    # continuation; its native thinking is ineligible for summary disclosure.
    assert {:ok, initial} =
             ProviderBindings.resolve_configuration(
               initial_configuration()
               |> Map.take(
                 ~w(model reasoning configuration_version instructions max_tokens context_token_budget system_class_tokens)
               )
               |> Map.put("reasoning", reasoning),
               bindings(),
               []
             )

    mapping = initial["provider_mapping"]
    assert mapping["mapping_revision"] == "loopex.anthropic.fable51.v1"
    assert mapping["continuation_required"] == true

    assert mapping["thinking"] ==
             if(reasoning == "default",
               do: %{"mode" => "omitted"},
               else: %{"mode" => "adaptive", "effort" => "low", "display" => "summarized"}
             )

    with_privacy_fixture(response_content(@model_a, native), fn fixture ->
      model =
        Model.reference(%{module: Loopex.LLM.ReqLLM, model: @model_a, options: fixture.options},
          provider_bindings: bindings()
        )

      path = Path.join(root, "privacy-#{variant}.log")
      runtime_id = "privacy-#{variant}-#{System.unique_integer([:positive])}"
      assert {:ok, artifact_handle} = Artifacts.open(Path.join(root, "artifacts-#{variant}"))
      artifacts = %{module: Artifacts, handle: artifact_handle}
      public_exclusions = Enum.reject([thinking, signature, redacted, @key], &(&1 == ""))

      private =
        Enum.reject(
          [signature, redacted, @key] ++ if(disclosed, do: [], else: [thinking]),
          &(&1 == "")
        )

      {session, records_before, events_before, artifact, artifact_files_before} =
        with_privacy_runtime(path, model, runtime_id, artifacts, fn runtime,
                                                                    store,
                                                                    custody,
                                                                    sink ->
          start_privacy_trace(runtime)

          assert {:ok, session} =
                   Loopex.create_session(runtime, %{},
                     command_id: "privacy-create",
                     genesis: Loopex.ConfiguredGenesisFixture.genesis([], initial)
                   )

          assert {:ok, attachment} = Loopex.attach(runtime, session, after_event_sequence: 0)

          run_id =
            run(
              runtime,
              attachment,
              fixture,
              custody,
              "privacy-prompt",
              "Return the public answer.",
              fn cutoff ->
                assert_privacy_progress(
                  sink,
                  session,
                  answer,
                  thinking,
                  disclosed,
                  private,
                  cutoff
                )

                assert_privacy_trace(runtime, public_exclusions, cutoff)
              end
            )

          {records, events, state} = history(store, session)
          assert state.configuration == initial
          [settled] = settlements(records)
          reply = settled.payload["result"]["reply"]
          assert reply["text"] == answer

          assert reply["usage"] == %{
                   "status" => "reported",
                   "input_tokens" => 11,
                   "output_tokens" => 4
                 }

          assert reply["delta_count"] == if(disclosed, do: 2, else: 1)
          assert reply["continuation"]["status"] == "closed"

          assert {:ok, ^native} =
                   Loopex.Model.ContentReferences.expand(reply["continuation"], answer, [])

          assert_privacy_history(attachment, events, state, answer, public_exclusions)

          # Concept: a host-written artifact is the nonempty output control.
          # Technical depth: this is a direct trusted Store operation, not a
          # claimed executor receipt; model completion must create no artifact.
          assert artifact_files(artifact_handle.root) == %{}

          assert {:ok, artifact} =
                   ArtifactStore.put(artifacts, "HOST_ARTIFACT_OUTPUT_CONTROL", %{
                     "session_id" => session,
                     "run_id" => run_id,
                     "operation_id" => "host-privacy-control",
                     "attempt" => 1,
                     "tool_call_id" => "host-privacy-control"
                   })

          assert {:ok, "HOST_ARTIFACT_OUTPUT_CONTROL"} = ArtifactStore.fetch(artifacts, artifact)
          files = artifact_files(artifact_handle.root)
          assert map_size(files) > 0
          assert :erlang.term_to_binary(files) =~ "HOST_ARTIFACT_OUTPUT_CONTROL"
          assert_absent(files, public_exclusions)
          {session, records, events, artifact, files}
        end)

      before_reopen = File.read!(path)

      with_privacy_runtime(path, model, runtime_id, artifacts, fn runtime,
                                                                  store,
                                                                  _custody,
                                                                  sink ->
        reopen_cutoff = now() + 10_000
        start_privacy_trace(runtime)

        assert {:ok, ^session} =
                 Loopex.resume_session(runtime, session, command_id: "privacy-resume")

        {records, events, state} = history(store, session)
        assert Enum.take(records, length(records_before)) == records_before
        assert Enum.take(events, length(events_before)) == events_before
        assert state.configuration == initial
        assert length(settlements(records)) == 1
        assert String.starts_with?(File.read!(path), before_reopen)

        assert {:ok, attachment} =
                 Loopex.attach(runtime, session, after_event_sequence: length(events))

        assert_privacy_history(attachment, events, state, answer, public_exclusions)
        assert ProgressSink.take(sink) == :empty
        assert {:ok, "HOST_ARTIFACT_OUTPUT_CONTROL"} = ArtifactStore.fetch(artifacts, artifact)
        assert artifact_files(artifact_handle.root) == artifact_files_before
        assert_absent(artifact_files_before, public_exclusions)
        assert_privacy_trace(runtime, public_exclusions, reopen_cutoff)
      end)

      assert [{body, true}] = Fixture.events(fixture)
      assert body["model"] == "claude-fable-5-1"
      assert body["max_tokens"] == 1_024
      assert body["messages"] == messages([{"user", "Return the public answer."}])

      if reasoning == "default" do
        refute Map.has_key?(body, "thinking")
        refute Map.has_key?(body, "output_config")
      else
        assert body["thinking"] == %{"type" => "adaptive", "display" => "summarized"}
        assert body["output_config"] == %{"effort" => "low"}
      end

      assert_absent(body, public_exclusions)
      assert Fixture.methods(fixture) == ["POST"]
    end)
  end

  defp tool_artifact_privacy_workflow(root) do
    thinking = "TOOL_PERMITTED_SUMMARY_CANARY"
    signature = "tool-private-signature+/="
    redacted = "TOOL_PRIVATE_REDACTED_CANARY"
    answer = "TOOL_PUBLIC_ANSWER_CANARY"
    artifact_control = "TOOL_ARTIFACT_BYTES_CONTROL"
    bytes = artifact_control <> "\n" <> :binary.copy("abcdefgh", 1_024)
    workspace_file = Path.join(System.fetch_env!("LOOPEX_WORKSPACE"), "privacy-source.txt")
    File.write!(workspace_file, bytes)
    arguments = %{"path" => "privacy-source.txt"}
    native_id = "privacy-native-read"

    native = [
      %{"type" => "thinking", "thinking" => thinking, "signature" => signature},
      %{"type" => "redacted_thinking", "data" => redacted},
      %{"type" => "tool_use", "id" => native_id, "name" => "read", "input" => arguments}
    ]

    private = [signature, redacted, @key]
    public_exclusions = [thinking | private]

    definition =
      Enum.find(
        CodingTools.definitions(),
        &(&1["tool_id"] == "loopex.read" and
            &1["tool_version"] == "1.1.0")
      )

    assert is_map(definition)
    definitions = [definition]
    initial = initial_configuration()

    assert initial["provider_mapping"]["thinking"] ==
             %{"mode" => "adaptive", "effort" => "low", "display" => "summarized"}

    assert initial["provider_mapping"]["continuation_required"] == true
    path = Path.join(root, "tool-privacy.log")
    artifact_root = Path.join(root, "tool-privacy-artifacts")
    runtime_id = "tool-privacy-#{System.unique_integer([:positive])}"

    with_privacy_fixture(
      [
        response_content(@model_a, native, "tool_use"),
        response(@model_a, answer, nil)
      ],
      fn fixture ->
        model =
          Model.reference(%{module: Loopex.LLM.ReqLLM, model: @model_a, options: fixture.options},
            provider_bindings: bindings()
          )

        {session, records_before, events_before, job, receipt, artifact, files_before,
         tool_content} =
          with_tool_privacy_runtime(
            path,
            model,
            runtime_id,
            artifact_root,
            definitions,
            fn runtime, store, custody, sink, artifacts, probe, episode ->
              start_privacy_trace(runtime)

              assert {:ok, session} =
                       Loopex.create_session(runtime, %{},
                         command_id: "tool-privacy-create",
                         genesis: Loopex.ConfiguredGenesisFixture.genesis(definitions, initial)
                       )

              assert {:ok, attachment} = Loopex.attach(runtime, session, after_event_sequence: 0)

              %{run_id: run_id, executor: executor, cutoff: cutoff} =
                run_tool_privacy(runtime, attachment, fixture, custody, probe, episode)

              {records, events, state} = history(store, session)
              assert state.configuration == initial
              assert state.run_order == [run_id]
              [first, final] = settlements(records)
              first_reply = first.payload["result"]["reply"]
              assert first_reply["text"] == ""
              assert first_reply["continuation"]["status"] == "open"

              assert first_reply["tool_calls"] == [
                       %{"id" => native_id, "name" => "read", "arguments" => arguments}
                     ]

              assert {:ok, ^native} =
                       Loopex.Model.ContentReferences.expand(
                         first_reply["continuation"],
                         "",
                         [arguments]
                       )

              final_reply = final.payload["result"]["reply"]
              assert final_reply["text"] == answer
              assert final_reply["continuation"]["status"] == "closed"

              assert {:ok, [%{"type" => "text", "text" => ^answer}]} =
                       Loopex.Model.ContentReferences.expand(
                         final_reply["continuation"],
                         answer,
                         []
                       )

              assert Enum.map([first_reply, final_reply], & &1["delta_count"]) == [3, 1]

              assert Enum.all?(
                       [first_reply, final_reply],
                       &(&1["usage"] ==
                           %{"status" => "reported", "input_tokens" => 11, "output_tokens" => 4})
                     )

              [intent] = Enum.filter(records, &(&1.payload.kind == "effect_intent_committed_v2"))

              [source] =
                Enum.filter(records, &(&1.payload.kind == "executor_receipt_committed_v2"))

              job = intent.payload["job"]
              receipt = source.payload["receipt"]
              assert job["tool_id"] == "loopex.read" and job["tool_version"] == "1.1.0"

              assert job["artifact_policy"]["projection"]["artifact_read"]["tool_version"] ==
                       "1.1.0"

              assert job["validated_arguments"] == arguments
              assert receipt["outcome"] == "completed"
              assert receipt["job_id"] == job["job_id"]
              assert receipt["canonical_request_digest"] == job["canonical_request_digest"]
              assert receipt["operation_id"] == job["operation_id"]
              assert receipt["attempt"] == job["attempt"]
              [tool_finished] = Enum.filter(events, &(&1.kind == "tool.finished"))
              [reference] = tool_finished["artifacts"]
              assert receipt["artifacts"] == [reference]
              assert reference["size"] == byte_size(bytes)

              artifact =
                Map.new(reference, fn {key, value} -> {String.to_existing_atom(key), value} end)

              assert {:ok, ^bytes} = ArtifactStore.fetch(artifacts, artifact)
              assert {:ok, use} = ArtifactStore.describe(artifacts, artifact)

              assert use.metadata == %{
                       "session_id" => session,
                       "run_id" => run_id,
                       "operation_id" => job["operation_id"],
                       "attempt" => job["attempt"],
                       "tool_call_id" => job["tool_call_id"]
                     }

              assert GenServer.call(executor, :stats, left(cutoff)).dispatches == %{
                       job["job_id"] => 1
                     }

              assert {:ok, retained} = LocalExecutor.retained_receipt(executor, job["job_id"])
              assert Jason.decode!(Jason.encode!(retained)) == receipt

              [_, second_request] =
                Enum.filter(
                  records,
                  &(&1.payload.kind in [
                      "model_request_committed_v2",
                      "model_request_committed_resources_v2"
                    ])
                )

              tool_content =
                tool_privacy_request_content(
                  second_request,
                  receipt,
                  reference,
                  job["artifact_policy"]["projection"]["normalized_call_id"]
                )

              assert receipt["output"] =~ artifact_control
              assert tool_content =~ artifact_control
              assert_privacy_history(attachment, events, state, answer, public_exclusions)

              assert_tool_privacy_progress(
                sink,
                session,
                thinking,
                answer,
                native_id,
                arguments,
                job["tool_call_id"],
                private,
                cutoff
              )

              assert_privacy_trace(runtime, public_exclusions, cutoff)
              files = artifact_files(artifact_root)
              assert map_size(files) > 0
              assert :erlang.term_to_binary(files) =~ artifact_control
              assert_absent(files, public_exclusions)
              assert_absent([receipt, tool_content], public_exclusions)
              assert now() < cutoff
              {session, records, events, job, receipt, artifact, files, tool_content}
            end
          )

        before_reopen = File.read!(path)
        File.write!(workspace_file, "CHANGED_WORKSPACE_CONTROL")

        with_tool_privacy_runtime(path, model, runtime_id, artifact_root, definitions, fn runtime,
                                                                                          store,
                                                                                          _custody,
                                                                                          sink,
                                                                                          artifacts,
                                                                                          _probe,
                                                                                          _episode ->
          cutoff = now() + 10_000
          start_privacy_trace(runtime)

          assert {:ok, ^session} =
                   Loopex.resume_session(runtime, session, command_id: "tool-privacy-resume")

          {records, events, state} = history(store, session)
          assert Enum.take(records, length(records_before)) == records_before
          assert Enum.take(events, length(events_before)) == events_before
          assert String.starts_with?(File.read!(path), before_reopen)
          assert state.configuration == initial
          assert length(settlements(records)) == 2
          assert Enum.count(records, &(&1.payload.kind == "effect_intent_committed_v2")) == 1

          assert Enum.count(
                   records,
                   &(&1.payload.kind in [
                       "model_request_committed_v2",
                       "model_request_committed_resources_v2"
                     ])
                 ) == 2

          [source] = Enum.filter(records, &(&1.payload.kind == "executor_receipt_committed_v2"))
          assert source.payload["receipt"] == receipt

          assert {:ok, attachment} =
                   Loopex.attach(runtime, session, after_event_sequence: length(events))

          assert_privacy_history(attachment, events, state, answer, public_exclusions)
          assert ProgressSink.take(sink) == :empty
          assert {:ok, ^bytes} = ArtifactStore.fetch(artifacts, artifact)
          assert File.read!(workspace_file) == "CHANGED_WORKSPACE_CONTROL"
          assert artifact_files(artifact_root) == files_before
          assert_absent(files_before, public_exclusions)
          {:ok, children} = Loopex.Runtime.children(runtime)
          [{_, coordinator, :worker, _}] = DynamicSupervisor.which_children(children.sessions)
          executor = :sys.get_state(coordinator, left(cutoff)).executor.reference
          assert GenServer.call(executor, :stats, left(cutoff)).dispatches == %{}
          assert {:ok, retained} = LocalExecutor.retained_receipt(executor, job["job_id"])
          assert Jason.decode!(Jason.encode!(retained)) == receipt
          assert_privacy_trace(runtime, public_exclusions, cutoff)
          assert now() < cutoff
        end)

        assert [{first_body, true}, {second_body, true}] = Fixture.events(fixture)

        assert first_body["messages"] ==
                 messages([{"user", "Read privacy-source.txt and report its public result."}])

        assert second_body["messages"] ==
                 first_body["messages"] ++
                   [
                     %{"role" => "assistant", "content" => native},
                     %{
                       "role" => "user",
                       "content" => [
                         %{
                           "type" => "tool_result",
                           "tool_use_id" => native_id,
                           "content" => tool_content
                         }
                       ]
                     }
                   ]

        assert_absent(first_body, public_exclusions)
        assert :erlang.term_to_binary(second_body) =~ thinking
        assert :erlang.term_to_binary(second_body) =~ signature
        assert :erlang.term_to_binary(second_body) =~ redacted
        assert_absent(second_body, [@key])

        for body <- [first_body, second_body] do
          assert body["model"] == "claude-fable-5-1" and body["max_tokens"] == 1_024
          assert body["thinking"] == %{"type" => "adaptive", "display" => "summarized"}
          assert body["output_config"] == %{"effort" => "low"}
          assert [%{"name" => "read"}] = Enum.map(body["tools"], &Map.take(&1, ["name"]))
        end

        assert Fixture.methods(fixture) == ["POST", "POST"]
      end
    )
  end

  defp tool_privacy_request_content(row, receipt, reference, canonical_id) do
    request = row.payload["request"]
    [tool] = Enum.filter(request["messages"], &(&1["role"] == "tool"))
    assert tool["tool_call_id"] == canonical_id
    assert {:ok, notice} = Frame.decode(tool["content"], 2_048)
    assert notice["excerpt_source"] == "receipt_content"
    assert notice["use_locator"] == reference["use_locator"]
    assert notice["object_digest"] == reference["digest"]
    assert notice["object_size"] == reference["size"]
    assert notice["omitted"] == true
    original = receipt["output"]
    assert byte_size(original) > 2_048
    assert notice["excerpt"] == binary_part(original, 0, notice["excerpt_byte_count"])
    assert {:ok, encoded} = Frame.encode(tool)
    assert IO.iodata_length(encoded) - 1 <= 2_048
    [range] = row.payload["lineage_projection"]["ranges"]
    assert range["source_digest"] == Canonical.digest_bytes(original)
    assert range["byte_count"] == notice["excerpt_byte_count"]
    assert range["artifact_use"] == reference["use_locator"]
    tool["content"]
  end

  # Concept: cleanup attempts every original resource and preserves the failure
  # that first made the fixture unsuccessful.
  # Technical depth: capture error/exit/throw with its original stack before
  # cleanup. Each release, stop and original-monitor join is a separate attempt;
  # cleanup never renews its captured cutoff or turns uncertainty into success.
  defp preserve_fixture_failure(body, cleanup) do
    outcome = capture_fixture_attempt(body)

    first =
      case outcome do
        {:ok, _value} -> nil
        failure -> failure
      end

    first =
      case capture_fixture_attempt(fn -> cleanup.(first) end) do
        {:ok, failure} -> failure
        failure -> first || failure
      end

    case first do
      nil ->
        {:ok, value} = outcome
        value

      {:failed, kind, reason, stack} ->
        :erlang.raise(kind, reason, stack)
    end
  end

  defp capture_fixture_attempt(fun) do
    try do
      {:ok, fun.()}
    catch
      kind, reason -> {:failed, kind, reason, __STACKTRACE__}
    end
  end

  defp fixture_cleanup_step(first, fun) do
    case capture_fixture_attempt(fun) do
      {:ok, _} -> first
      failure -> first || failure
    end
  end

  defp fixture_cleanup_joins(first, originals, cutoff) do
    Enum.reduce(originals, first, fn original, failure ->
      fixture_cleanup_step(failure, fn -> join([original], cutoff) end)
    end)
  end

  defp with_privacy_fixture(body, fun) when is_binary(body),
    do: with_privacy_fixture([body], fun)

  defp with_privacy_fixture(bodies, fun) when is_list(bodies) do
    {:links, before_links} = Process.info(self(), :links)

    fixture =
      Fixture.new(:delayed_entry,
        http_custody: {self(), make_ref()},
        credential: @key,
        response_bodies: Enum.map(bodies, &{:paced, &1})
      )

    {:links, after_links} = Process.info(self(), :links)
    links = after_links -- before_links
    ports = Enum.filter(links, &is_port/1)
    assert length(ports) == 2 and fixture.listener in ports
    {:ok, children} = Loopex.Runtime.children(fixture.runtime)

    monitors =
      monitor(Enum.filter(links, &is_pid/1) ++ [fixture.store_pid] ++ Map.values(children))

    preserve_fixture_failure(fn -> fun.(fixture) end, fn first ->
      cutoff = now() + 5_000

      first =
        Enum.reduce(ports, first, fn port, failure ->
          fixture_cleanup_step(failure, fn -> assert :ok == :gen_tcp.close(port) end)
        end)

      first =
        fixture_cleanup_step(first, fn ->
          if Loopex.Runtime.alive?(fixture.runtime),
            do: assert(:ok == Loopex.stop(fixture.runtime))
        end)

      first =
        Enum.reduce(
          [
            fixture.workers,
            fixture.capability_pid,
            fixture.store_pid,
            fixture.registry_pid,
            fixture.custody_pid,
            fixture.events,
            fixture.transport_events,
            fixture.probe_events,
            fixture.request_headers
          ],
          first,
          fn pid, failure ->
            fixture_cleanup_step(failure, fn ->
              if Process.alive?(pid),
                do: assert(:ok == GenServer.stop(pid, :normal, left(cutoff)))
            end)
          end
        )

      fixture_cleanup_joins(first, monitors, cutoff)
    end)
  end

  defp with_tool_privacy_runtime(path, model, runtime_id, artifact_root, definitions, fun) do
    owner = self()

    probe =
      spawn(fn -> artifact_privacy_probe(owner, Process.monitor(owner), nil, nil, false) end)

    probe_monitors = monitor([probe])
    episode = make_ref()
    Process.put(episode, %{cutoff: nil, http: []})
    cleanup_cutoff = fn -> Process.get(episode).cutoff || now() + 5_000 end

    preserve_fixture_failure(
      fn ->
        assert {:ok, handle} = Artifacts.open(artifact_root)
        artifacts = %{module: Artifacts, handle: Map.put(handle, :fault_probe, probe)}

        with_privacy_runtime(
          path,
          model,
          runtime_id,
          artifacts,
          definitions,
          fn runtime, store, custody, sink ->
            bind = make_ref()
            bind_cutoff = cleanup_cutoff.()
            send(probe, {:bind, self(), bind, runtime.supervisor})

            receive do
              {:artifact_privacy_bound, ^probe, ^bind} -> :ok
            after
              left(bind_cutoff) -> flunk("artifact probe did not bind its original Runtime")
            end

            assert now() < bind_cutoff

            preserve_fixture_failure(
              fn ->
                fun.(runtime, store, custody, sink, artifacts, probe, episode)
              end,
              fn first ->
                cutoff = Process.get(episode).cutoff || now() + 5_000

                first =
                  fixture_cleanup_step(first, fn ->
                    disarm_artifact_privacy_probe(probe, cutoff)
                  end)

                cleanup_tool_privacy_http(episode, first)
              end
            )
          end,
          cleanup_cutoff
        )
      end,
      fn first ->
        retained = Process.delete(episode)
        cutoff = retained.cutoff || now() + 5_000

        first =
          Enum.reduce(retained.http, first, fn http, failure ->
            failure =
              fixture_cleanup_step(failure, fn -> assert :ok == :gen_tcp.close(http.socket) end)

            fixture_cleanup_step(failure, fn ->
              receive do
                {:DOWN, reference, :port, socket, _}
                when reference == http.socket_monitor and socket == http.socket ->
                  :ok
              after
                left(cutoff) -> flunk("original tool-run socket did not join during cleanup")
              end

              assert now() < cutoff
            end)
          end)

        first =
          fixture_cleanup_step(first, fn ->
            send(probe, {:stop, self()})
          end)

        fixture_cleanup_joins(first, probe_monitors, cutoff)
      end
    )
  end

  # Concept: hold the actual publisher until its original custody is retained.
  # Technical depth: release-all acknowledges disarm and continues future phases
  # before Runtime teardown; owner loss also releases the held phase. The relay
  # lives only until that exact original Runtime root is down.
  defp artifact_privacy_probe(owner, owner_monitor, root_monitor, pending, disarmed) do
    receive do
      {:bind, ^owner, reference, root} when is_pid(root) and is_nil(root_monitor) ->
        monitor = Process.monitor(root)
        send(owner, {:artifact_privacy_bound, self(), reference})
        artifact_privacy_probe(owner, owner_monitor, monitor, pending, disarmed)

      {:loopex_artifact_fault_point, caller, reference, phase} ->
        if disarmed do
          send(caller, {:loopex_artifact_fault_action, reference, :continue})
          artifact_privacy_probe(owner, owner_monitor, root_monitor, pending, true)
        else
          send(owner, {:artifact_privacy_phase, self(), caller, reference, phase})
          artifact_privacy_probe(owner, owner_monitor, root_monitor, {caller, reference}, false)
        end

      {:release_all, ^owner, reference} ->
        release_artifact_privacy_phase(pending)
        send(owner, {:artifact_privacy_disarmed, self(), reference})
        artifact_privacy_probe(owner, owner_monitor, root_monitor, nil, true)

      {:DOWN, ^owner_monitor, :process, ^owner, _} ->
        release_artifact_privacy_phase(pending)
        if root_monitor, do: artifact_privacy_probe(owner, owner_monitor, root_monitor, nil, true)

      {:DOWN, reference, :process, _root, _} when reference == root_monitor ->
        release_artifact_privacy_phase(pending)

      {:stop, ^owner} ->
        release_artifact_privacy_phase(pending)
    end
  end

  defp release_artifact_privacy_phase(nil), do: :ok

  defp release_artifact_privacy_phase({caller, reference}),
    do: send(caller, {:loopex_artifact_fault_action, reference, :continue})

  defp disarm_artifact_privacy_probe(probe, cutoff) do
    reference = make_ref()
    send(probe, {:release_all, self(), reference})

    receive do
      {:artifact_privacy_disarmed, ^probe, ^reference} -> :ok
    after
      left(cutoff) -> flunk("artifact publisher probe did not acknowledge disarm")
    end

    assert now() < cutoff
  end

  defp with_privacy_runtime(path, model, runtime_id, artifacts, fun),
    do: with_privacy_runtime(path, model, runtime_id, artifacts, [], fun)

  defp with_privacy_runtime(
         path,
         model,
         runtime_id,
         artifacts,
         definitions,
         fun,
         cleanup_cutoff \\ fn -> now() + 5_000 end
       ) do
    assert {:ok, sink} = ProgressSink.open()
    {guardian, _incarnation, _arena} = sink
    monitors = monitor([guardian])
    leases_key = {__MODULE__, sink}
    Process.put(leases_key, [])

    preserve_fixture_failure(
      fn ->
        with_runtime(
          path,
          model,
          runtime_id,
          [progress_sink: sink, diagnostics_to: self(), artifact_store: artifacts],
          definitions,
          fn runtime, store, custody -> fun.(runtime, store, custody, sink) end,
          cleanup_cutoff
        )
      end,
      fn first ->
        # Concept: assertion copies unwind before their retained native leases.
        # Technical depth: the sink owner retains only lease identities here;
        # successful close and the original guardian DOWN share the fixture bound.
        cutoff = cleanup_cutoff.()

        first =
          Enum.reduce(Process.delete(leases_key), first, fn lease, failure ->
            fixture_cleanup_step(failure, fn ->
              assert :ok == ProgressSink.release(sink, lease)
            end)
          end)

        first = fixture_cleanup_step(first, fn -> assert :ok == ProgressSink.close(sink) end)
        fixture_cleanup_joins(first, monitors, cutoff)
      end
    )
  end

  defp assert_privacy_progress(sink, session, answer, thinking, disclosed, private, cutoff) do
    items = privacy_progress(sink, session, cutoff, [])

    assert Enum.filter(items, &(&1.kind == :reasoning_delta)) |> Enum.map(& &1.text) ==
             if(disclosed, do: [thinking], else: [])

    assert Enum.filter(items, &(&1.kind == :text_delta)) |> Enum.map(& &1.text) == [answer]
    assert List.last(items).kind == :model_stream_closed
    assert List.last(items).disposition == :complete
    assert List.last(items).delta_count == if(disclosed, do: 2, else: 1)
    assert_absent(items, private)
    assert ProgressSink.take(sink) == :empty
    assert now() < cutoff, "native summary progress exceeded its captured cutoff"
  end

  defp privacy_progress(sink, session, cutoff, acc) do
    case ProgressSink.take(sink) do
      {:ok, lease, ^session, item} ->
        key = {__MODULE__, sink}
        Process.put(key, [lease | Process.get(key)])
        assert length(acc) < 3

        if item.kind == :model_stream_closed,
          do: Enum.reverse([item | acc]),
          else: privacy_progress(sink, session, cutoff, [item | acc])

      :empty ->
        assert now() < cutoff, "native summary progress did not close within the captured cutoff"
        Process.sleep(10)
        privacy_progress(sink, session, cutoff, acc)
    end
  end

  defp assert_tool_privacy_progress(
         sink,
         session,
         thinking,
         answer,
         native_id,
         arguments,
         canonical_id,
         private,
         cutoff
       ) do
    items = tool_privacy_progress(sink, session, cutoff, [])

    assert Enum.map(items, & &1.kind) == [
             :reasoning_delta,
             :tool_call_delta,
             :tool_call_delta,
             :model_stream_closed,
             :tool_stream_closed,
             :text_delta,
             :model_stream_closed
           ]

    assert Enum.filter(items, &(&1.kind == :reasoning_delta)) |> Enum.map(& &1.text) == [thinking]
    assert Enum.filter(items, &(&1.kind == :text_delta)) |> Enum.map(& &1.text) == [answer]
    [call, fragment] = Enum.filter(items, &(&1.kind == :tool_call_delta))

    assert call.tool_call_id == native_id and call.name == "read" and
             is_nil(call.arguments_fragment)

    assert fragment.call_index == call.call_index
    assert is_nil(fragment.tool_call_id) and is_nil(fragment.name)
    assert Jason.decode!(fragment.arguments_fragment) == arguments
    [first, final] = Enum.filter(items, &(&1.kind == :model_stream_closed))
    assert first.disposition == :complete and first.delta_count == 3
    assert final.disposition == :complete and final.delta_count == 1
    assert first.stream_domain_id != final.stream_domain_id
    [tool] = Enum.filter(items, &(&1.kind == :tool_stream_closed))
    assert tool.disposition == :complete and tool.progress_count == 0
    assert tool.tool_call_id == canonical_id
    assert_absent(items, private)
    assert ProgressSink.take(sink) == :empty
    assert now() < cutoff, "tool-run progress exceeded its captured cutoff"
  end

  defp tool_privacy_progress(sink, session, cutoff, acc) do
    case ProgressSink.take(sink) do
      {:ok, lease, ^session, item} ->
        key = {__MODULE__, sink}
        Process.put(key, [lease | Process.get(key)])
        assert length(acc) < 7
        items = [item | acc]

        if Enum.count(items, &(&1.kind == :model_stream_closed)) == 2 and
             Enum.count(items, &(&1.kind == :tool_stream_closed)) == 1,
           do: Enum.reverse(items),
           else: tool_privacy_progress(sink, session, cutoff, items)

      :empty ->
        assert now() < cutoff, "tool-run progress did not close within its captured cutoff"
        Process.sleep(10)
        tool_privacy_progress(sink, session, cutoff, acc)
    end
  end

  defp start_privacy_trace(runtime) do
    assert {:ok, _} =
             Loopex.trace(runtime, %{
               modules: [Loopex.Runtime.Control, SessionCoordinator, Loopex.LLM.ReqLLM],
               level: :arguments
             })

    Loopex.session_status(runtime, "privacy-trace-positive-control")
  end

  defp assert_privacy_trace(runtime, private, cutoff) do
    # Concept: inspect the real managed trace output through a delivery barrier.
    # Technical depth: this uses only this runtime's existing trace session;
    # stopping it and draining admitted diagnostics precede the sink sentinel.
    assert {:ok, %{tracer: tracer}} = Loopex.Runtime.children(runtime)
    # The handle stays in its owner's private ETS table. This test-only system
    # callback returns the identical state after the session's delivery fence;
    # queued trace frames precede the following normal trace-stop operation.
    :sys.replace_state(
      tracer,
      fn state ->
        [{:session, session}] = :ets.lookup(state.session_table, :session)
        fence = :trace.delivered(session, :all)

        receive do
          {:trace_delivered, :all, ^fence} -> state
        after
          left(cutoff) -> flunk("runtime trace delivery was not proved")
        end
      end,
      left(cutoff)
    )

    assert {:ok, %{dropped: 0}} = Loopex.trace_status(runtime)
    assert :ok = Loopex.trace_stop(runtime)
    assert {:ok, admission} = Loopex.Runtime.diagnostics_admission(runtime)
    await(fn -> Loopex.Runtime.DiagnosticsAdmission.held(admission) == 0 end, cutoff)
    assert :ok = Loopex.Runtime.diagnostic(runtime, %{"kind" => "privacy_observation_barrier"})
    entries = privacy_diagnostics(cutoff, [])

    assert Enum.any?(
             entries,
             &(&1["kind"] == "trace_call" and &1["module"] == "Loopex.Runtime.Control")
           )

    refute Enum.any?(entries, &(&1["kind"] == "diagnostics_dropped"))
    assert_absent(entries, private)
    assert now() < cutoff, "runtime trace observation exceeded its captured cutoff"
  end

  defp privacy_diagnostics(cutoff, acc) do
    receive do
      {:loopex_diagnostic, %{"kind" => "privacy_observation_barrier"}} -> Enum.reverse(acc)
      {:loopex_diagnostic, entry} -> privacy_diagnostics(cutoff, [entry | acc])
    after
      left(cutoff) -> flunk("diagnostic output barrier was not observed")
    end
  end

  defp assert_privacy_history(attachment, events, state, answer, private) do
    assert :erlang.term_to_binary(events) =~ answer
    assert :erlang.term_to_binary(state.conversation) =~ answer
    assert_absent(events, private)
    assert_absent(state.conversation, private)

    assert {:ok, current} =
             Loopex.attach(attachment.runtime, attachment.session_id,
               after_event_sequence: length(events)
             )

    snapshot = Loopex.snapshot(current)
    assert is_map(snapshot)
    assert_absent(snapshot, private)
  end

  defp assert_absent(value, private) do
    bytes = :erlang.term_to_binary(value)
    for canary <- private, do: refute(bytes =~ canary)
  end

  defp artifact_files(root) do
    root
    |> Path.join("**/*")
    |> Path.wildcard(match_dot: true)
    |> Enum.filter(&File.regular?/1)
    |> Map.new(&{Path.relative_to(&1, root), File.read!(&1)})
  end

  defp bindings,
    do: %{"anthropic" => %{"credential" => %{"env" => "NATIVE_SWITCH_HOST_REFERENCE"}}}

  defp initial_configuration do
    {:ok, instructions} =
      Instructions.capture(%{
        "version" => "switch.v1",
        "base" => "Keep the exact committed facts.",
        "environment" => "",
        "appendix" => ""
      })

    assert {:ok, configuration} =
             ProviderBindings.resolve_configuration(
               %{
                 "model" => @model_a,
                 "reasoning" => "low",
                 "configuration_version" => 1,
                 "max_tokens" => 1_024,
                 "context_token_budget" => 8_192,
                 "system_class_tokens" => 1_000,
                 "instructions" => instructions
               },
               bindings(),
               []
             )

    configuration
  end

  defp configure(attachment, model, current, command_id, changes) do
    context = %{deadline_monotonic_ms: now() + 10_000, cleanup_grace_ms: 5_000}

    assert {:ok, candidate} =
             Model.prepare_configuration(current, changes, [], context, model.options)

    assert {:accepted, ^command_id} =
             Loopex.command_with_configuration(
               attachment,
               %{type: :configure, command_id: command_id, changes: changes},
               candidate
             )

    candidate
  end

  defp with_runtime(path, model, runtime_id, fun),
    do: with_runtime(path, model, runtime_id, [], fun)

  defp with_runtime(path, model, runtime_id, observations, fun) do
    with_runtime(path, model, runtime_id, observations, [], fun)
  end

  defp with_runtime(
         path,
         model,
         runtime_id,
         observations,
         definitions,
         fun,
         cleanup_cutoff \\ fn -> now() + 5_000 end
       ) do
    custody = make_ref()
    resources = make_ref()
    Process.put(custody, [])
    Process.put(resources, %{runtime: nil, owners: []})

    preserve_fixture_failure(
      fn ->
        # Concept: each reopened runtime owns its own managed tracing capability.
        # Technical depth: preserve the fixture's other adapter options; retain
        # the fresh original actor before obtaining or binding its handle.
        assert {:ok, capability_owner} = Capability.start_link([])
        retain_resource(custody, resources, capability_owner)
        assert {:ok, capability} = Capability.handle(capability_owner)
        adapter_options = Keyword.fetch!(model.options, :adapter_options)

        runtime_model = %{
          model
          | options:
              Keyword.put(
                model.options,
                :adapter_options,
                Keyword.put(adapter_options, :tracing_capability, capability)
              )
        }

        assert {:ok, store} = Local.start_link(path: path)
        retain_resource(custody, resources, store)
        assert {:ok, store_reference} = Loopex.Store.new(Local, store)
        workspace = System.fetch_env!("LOOPEX_WORKSPACE")
        assert {:ok, workspace_ref} = WorkspaceIdentity.reference(workspace)

        assert {:ok, lease} =
                 WorkspaceLease.start_link(
                   id: "native-switch-workspace",
                   path: workspace,
                   fencing_token: 1
                 )

        retain_resource(custody, resources, lease)

        assert {:ok, executor} =
                 LocalExecutor.start_link(
                   identity: "native-switch-local",
                   epoch: 1,
                   fencing_token: 1,
                   workspace_leases: %{"native-switch-workspace" => lease},
                   ledger_root: Path.join(Path.dirname(path), "executor-receipts"),
                   artifacts:
                     if(definitions == [],
                       do: nil,
                       else: Keyword.fetch!(observations, :artifact_store)
                     ),
                   cleanup_grace_ms: 5_000
                 )

        retain_resource(custody, resources, executor)

        assert {:ok, runtime} =
                 Loopex.start_link(
                   [
                     runtime_id: runtime_id,
                     store: store_reference,
                     context_token_budget: 8_192,
                     bounds: %{max_turns: 4, token_budget: 8_192, deadline_ms: 10_000},
                     cleanup_grace_ms: 5_000,
                     model: runtime_model,
                     executor: %{
                       module: LocalExecutor,
                       reference: executor,
                       identity: "native-switch-local",
                       epoch: 1,
                       fencing_token: 1,
                       workspace_ref: workspace_ref,
                       workspace_lease: "native-switch-workspace"
                     },
                     policy: Policy,
                     policy_identity: %{"id" => "native-switch-policy", "revision" => "1"},
                     grant_decision: {:host_policy, :allow},
                     tools: definitions,
                     active_tools: Enum.map(definitions, & &1["tool_id"])
                   ] ++ observations
                 )

        Process.put(resources, %{Process.get(resources) | runtime: runtime})
        Process.put(custody, Process.get(custody) ++ monitor([runtime.supervisor]))
        assert {:ok, children} = Loopex.Runtime.children(runtime)
        Process.put(custody, Process.get(custody) ++ monitor(Map.values(children)))
        assert :ok = Capability.bind(capability, runtime)

        assert :ok =
                 LoopexComposition.StartupGate.publication(
                   LoopexComposition.StartupGate.await(runtime)
                 )

        fun.(runtime, store, custody)
      end,
      fn first ->
        # Concept: failed startup still retires every resource it already opened.
        # Technical depth: retain each original PID immediately after creation;
        # runtime joins precede hand/lease/Store/capability release under one cutoff.
        cutoff = cleanup_cutoff.()
        %{runtime: runtime, owners: owners} = Process.delete(resources)
        monitors = Process.delete(custody)

        {resource_monitors, runtime_monitors} =
          Enum.split_with(monitors, fn {pid, _reference} -> pid in owners end)

        first =
          fixture_cleanup_step(first, fn ->
            if runtime, do: assert(:ok == Loopex.stop(runtime))
          end)

        first = fixture_cleanup_joins(first, runtime_monitors, cutoff)

        first =
          fixture_cleanup_step(first, fn ->
            if runtime && definitions == [] do
              [executor, _lease, _store, _capability_owner] = owners
              assert GenServer.call(executor, :stats, left(cutoff)).dispatches == %{}
            end
          end)

        first =
          Enum.reduce(owners, first, fn owner, failure ->
            fixture_cleanup_step(failure, fn ->
              if Process.alive?(owner),
                do: assert(:ok == GenServer.stop(owner, :normal, left(cutoff)))
            end)
          end)

        fixture_cleanup_joins(first, resource_monitors, cutoff)
      end
    )
  end

  defp retain_resource(custody, resources, owner) do
    Process.put(custody, Process.get(custody) ++ monitor([owner]))
    retained = Process.get(resources)
    Process.put(resources, %{retained | owners: [owner | retained.owners]})
  end

  defp run_tool_privacy(runtime, attachment, fixture, custody, probe, episode) do
    for name <- ~w(pid namespace release), do: File.rm(Fixture.marker(fixture, name))
    work_cutoff = now() + 10_000
    cleanup_cutoff = work_cutoff + 5_000
    {observer, nonce} = fixture.http_custody
    assert observer == self()
    requests = [make_ref(), make_ref()]

    Process.put(episode, %{
      cutoff: cleanup_cutoff,
      http: [],
      binding: {fixture.acceptor, nonce, requests, work_cutoff, cleanup_cutoff}
    })

    for request <- requests do
      send(
        fixture.acceptor,
        {:fixture_http_bound, self(), nonce, request, work_cutoff, cleanup_cutoff}
      )
    end

    preserve_fixture_failure(
      fn ->
        assert {:accepted, "tool-privacy-prompt"} =
                 Loopex.command(
                   attachment,
                   %{
                     type: :prompt,
                     command_id: "tool-privacy-prompt",
                     content: "Read privacy-source.txt and report its public result."
                   }
                 )

        await(fn -> Fixture.reached?(fixture, "namespace") end, work_cutoff)
        assert {:ok, children} = Loopex.Runtime.children(runtime)
        [{_, coordinator, :worker, _}] = DynamicSupervisor.which_children(children.sessions)
        [{_, group, :worker, _}] = Supervisor.which_children(children.owner_groups)
        assert {:ok, workers} = OwnerGroup.workers(group)
        old = Process.get(custody)

        new =
          Enum.reject([coordinator, group, workers], fn pid ->
            Enum.any?(old, &(elem(&1, 0) == pid))
          end)

        Process.put(custody, old ++ monitor(new))

        first =
          capture_tool_native_invocation(
            fixture,
            coordinator,
            group,
            workers,
            custody,
            work_cutoff
          )

        Fixture.release(fixture)
        [first_request, second_request] = requests

        first_http =
          capture_tool_http(fixture, first_request, episode, custody, work_cutoff, cleanup_cutoff)

        release_tool_http(first_http)

        publisher =
          receive do
            {:artifact_privacy_phase, ^probe, caller, _reference,
             {:artifact_use_publication, :staging_write}} ->
              caller
          after
            left(work_cutoff) -> flunk("actual read output did not reach artifact publication")
          end

        publisher_monitors = monitor([publisher])
        Process.put(custody, Process.get(custody) ++ publisher_monitors)
        {:links, links} = Process.info(publisher, :links)
        [guardian] = Enum.filter(links, &is_pid/1)
        guardian_monitors = monitor([guardian])
        Process.put(custody, Process.get(custody) ++ guardian_monitors)
        state = :sys.get_state(coordinator, left(work_cutoff))
        [{_reference, {:executor, run_id, executor_callback}}] = Map.to_list(state.in_flight)
        executor_monitors = monitor([executor_callback])
        Process.put(custody, Process.get(custody) ++ executor_monitors)
        executor = state.executor.reference
        assert Process.alive?(executor)

        # The held original publisher prevents a second provider incarnation from
        # overwriting the fixture markers before this first original child joins.
        join_tool_actors(custody, first.monitors, cleanup_cutoff)
        join_tool_http(first_http, episode, custody, cleanup_cutoff)
        refute Fixture.alive?(first.child)
        refute File.exists?(first.namespace)
        await(fn -> :sys.get_state(group, left(work_cutoff)).providers == %{} end, work_cutoff)
        disarm_artifact_privacy_probe(probe, work_cutoff)

        second_http =
          capture_tool_http(
            fixture,
            second_request,
            episode,
            custody,
            work_cutoff,
            cleanup_cutoff
          )

        second =
          capture_tool_native_invocation(
            fixture,
            coordinator,
            group,
            workers,
            custody,
            work_cutoff
          )

        assert second.child != first.child and second.namespace != first.namespace
        assert MapSet.disjoint?(MapSet.new(first.members), MapSet.new(second.members))
        release_tool_http(second_http)
        terminal = finished(attachment, work_cutoff)
        assert terminal["outcome"] == "completed" and terminal["run_id"] == run_id
        assert now() < work_cutoff

        join_tool_actors(
          custody,
          publisher_monitors ++ guardian_monitors ++ executor_monitors,
          cleanup_cutoff
        )

        join_tool_actors(custody, second.monitors, cleanup_cutoff)
        join_tool_http(second_http, episode, custody, cleanup_cutoff)
        Fixture.assert_gone(fixture)
        refute Fixture.alive?(second.child)
        refute File.exists?(second.namespace)

        await(
          fn ->
            :sys.get_state(group, left(cleanup_cutoff)).providers == %{} and
              Supervisor.which_children(workers) == []
          end,
          cleanup_cutoff
        )

        assert now() < cleanup_cutoff
        %{run_id: run_id, executor: executor, cutoff: cleanup_cutoff}
      end,
      fn first ->
        first =
          fixture_cleanup_step(first, fn ->
            disarm_artifact_privacy_probe(probe, cleanup_cutoff)
          end)

        cleanup_tool_privacy_http(episode, first)
      end
    )
  end

  defp capture_tool_native_invocation(fixture, coordinator, group, workers, custody, cutoff) do
    %{coordinator: ^coordinator, workers: ^workers, providers: providers} =
      :sys.get_state(group, left(cutoff))

    [{reference, provider}] = Map.to_list(providers)
    assert provider.retainer == coordinator and provider.caretaker == nil

    assert Enum.sort(provider.original_members) ==
             Enum.sort([provider.resource, provider.worker, provider.guard])

    {:dictionary, dictionary} = Process.info(provider.guard, :dictionary)
    key = {{SessionCoordinator, :provider_callback}, reference}
    {^key, callback} = List.keyfind(dictionary, key, 0)
    members = [callback | provider.original_members]
    monitors = monitor(members)
    Process.put(custody, Process.get(custody) ++ monitors)
    child = Fixture.pid(fixture)
    namespace = Fixture.namespace(fixture)
    assert Fixture.alive?(child) and File.dir?(namespace)
    assert now() < cutoff
    %{members: members, monitors: monitors, child: child, namespace: namespace}
  end

  defp capture_tool_http(fixture, request, episode, custody, work_cutoff, cleanup_cutoff) do
    acceptor = fixture.acceptor
    {observer, nonce} = fixture.http_custody
    assert observer == self()

    {handler, socket} =
      receive do
        {:fixture_http_owned, ^acceptor, ^nonce, ^request, handler, socket, ^work_cutoff,
         ^cleanup_cutoff} ->
          {handler, socket}
      after
        left(work_cutoff) -> flunk("original tool-run HTTP custody gate was not reached")
      end

    assert Process.alive?(handler)
    assert Port.info(socket, :connected) == {:connected, handler}
    [handler_monitor] = monitor([handler])
    Process.put(custody, Process.get(custody) ++ [handler_monitor])

    http = %{
      acceptor: acceptor,
      nonce: nonce,
      request: request,
      handler: handler,
      socket: socket,
      handler_monitor: handler_monitor,
      socket_monitor: :erlang.monitor(:port, socket)
    }

    retained = Process.get(episode)
    Process.put(episode, %{retained | http: retained.http ++ [http]})
    assert now() < work_cutoff
    http
  end

  defp release_tool_http(http),
    do:
      send(
        http.acceptor,
        {:fixture_http_release, self(), http.nonce, http.request, http.handler, http.socket}
      )

  defp join_tool_http(http, episode, custody, cutoff) do
    {handler, handler_monitor} = http.handler_monitor

    receive do
      {:DOWN, ^handler_monitor, :process, ^handler, :normal} -> refute Process.alive?(handler)
    after
      left(cutoff) -> flunk("original tool-run HTTP handler did not join normally")
    end

    Process.put(custody, List.delete(Process.get(custody), http.handler_monitor))

    receive do
      {:DOWN, reference, :port, socket, :normal}
      when reference == http.socket_monitor and socket == http.socket ->
        :ok
    after
      left(cutoff) -> flunk("original tool-run HTTP socket did not join")
    end

    retained = Process.get(episode)
    Process.put(episode, %{retained | http: List.delete(retained.http, http)})
    assert now() < cutoff
  end

  defp join_tool_actors(custody, monitors, cutoff) do
    for original <- monitors do
      join([original], cutoff)
      Process.put(custody, List.delete(Process.get(custody), original))
    end
  end

  defp cleanup_tool_privacy_http(episode, first) do
    retained = Process.get(episode)

    first =
      Enum.reduce(retained.http, first, fn http, failure ->
        failure =
          fixture_cleanup_step(failure, fn -> assert :ok == :gen_tcp.close(http.socket) end)

        fixture_cleanup_step(failure, fn -> release_tool_http(http) end)
      end)

    if binding = Map.get(retained, :binding) do
      {acceptor, nonce, requests, work, cleanup} = binding
      cleanup_queued_tool_http(acceptor, nonce, requests, work, cleanup, first)
    else
      first
    end
  end

  defp cleanup_queued_tool_http(acceptor, nonce, requests, work, cleanup, first) do
    receive do
      {:fixture_http_owned, ^acceptor, ^nonce, request, handler, socket, ^work, ^cleanup}
      when is_pid(handler) ->
        first = fixture_cleanup_step(first, fn -> assert request in requests end)
        first = fixture_cleanup_step(first, fn -> assert :ok == :gen_tcp.close(socket) end)

        first =
          fixture_cleanup_step(first, fn ->
            send(acceptor, {:fixture_http_release, self(), nonce, request, handler, socket})
          end)

        cleanup_queued_tool_http(acceptor, nonce, requests, work, cleanup, first)
    after
      0 -> first
    end
  end

  defp run(runtime, attachment, fixture, custody, command_id, content, observe \\ fn _ -> :ok end) do
    for name <- ~w(pid namespace release), do: File.rm(Fixture.marker(fixture, name))
    work_cutoff = now() + 10_000
    cleanup_cutoff = work_cutoff + 5_000
    {http_observer, http_nonce} = fixture.http_custody
    assert http_observer == self()
    http_request = make_ref()

    send(
      fixture.acceptor,
      {:fixture_http_bound, self(), http_nonce, http_request, work_cutoff, cleanup_cutoff}
    )

    assert {:accepted, ^command_id} =
             Loopex.command(
               attachment,
               %{type: :prompt, command_id: command_id, content: content}
             )

    await(fn -> Fixture.reached?(fixture, "namespace") end, work_cutoff)
    assert {:ok, children} = Loopex.Runtime.children(runtime)
    [{_, coordinator, :worker, _}] = DynamicSupervisor.which_children(children.sessions)
    [{_, group, :worker, _}] = Supervisor.which_children(children.owner_groups)
    assert {:ok, private_workers} = OwnerGroup.workers(group)

    %{coordinator: ^coordinator, workers: ^private_workers, providers: providers} =
      :sys.get_state(group, left(work_cutoff))

    [{reference, provider}] = Map.to_list(providers)
    assert provider.retainer == coordinator and provider.caretaker == nil
    assert is_pid(provider.resource) and is_pid(provider.worker) and is_pid(provider.guard)

    assert Enum.sort(provider.original_members) ==
             Enum.sort([provider.resource, provider.worker, provider.guard])

    {:dictionary, dictionary} = Process.info(provider.guard, :dictionary)
    callback_key = {{SessionCoordinator, :provider_callback}, reference}
    {^callback_key, callback} = List.keyfind(dictionary, callback_key, 0)
    assert is_pid(callback) and Process.alive?(callback)
    invocation_monitors = monitor([callback | provider.original_members])
    old = Process.get(custody)

    new_actors =
      Enum.reject([coordinator, group, private_workers], fn pid ->
        Enum.any?(old, &(elem(&1, 0) == pid))
      end)

    Process.put(custody, old ++ monitor(new_actors))
    child = Fixture.pid(fixture)
    namespace = Fixture.namespace(fixture)
    assert Fixture.alive?(child) and File.dir?(namespace)
    Fixture.release(fixture)
    acceptor = fixture.acceptor

    {handler, socket} =
      receive do
        {:fixture_http_owned, ^acceptor, ^http_nonce, ^http_request, handler, socket,
         ^work_cutoff, ^cleanup_cutoff} ->
          {handler, socket}
      after
        left(work_cutoff) -> flunk("actual HTTP handler did not reach its original custody gate")
      end

    assert Process.alive?(handler)
    assert is_port(socket)
    assert Port.info(socket, :connected) == {:connected, handler}
    handler_monitor = Process.monitor(handler)
    socket_monitor = :erlang.monitor(:port, socket)
    assert now() < work_cutoff
    send(acceptor, {:fixture_http_release, self(), http_nonce, http_request, handler, socket})
    terminal = finished(attachment, work_cutoff)
    assert terminal["outcome"] == "completed"
    join(invocation_monitors, cleanup_cutoff)

    receive do
      {:DOWN, ^socket_monitor, :port, ^socket, :normal} -> :ok
    after
      left(cleanup_cutoff) -> flunk("original accepted HTTP socket did not close")
    end

    receive do
      {:DOWN, ^handler_monitor, :process, ^handler, :normal} -> refute Process.alive?(handler)
    after
      left(cleanup_cutoff) -> flunk("original accepted HTTP handler did not join")
    end

    Fixture.assert_gone(fixture)
    refute Fixture.alive?(child)
    refute File.exists?(namespace)
    assert now() < cleanup_cutoff

    await(
      fn ->
        :sys.get_state(group, left(cleanup_cutoff)).providers == %{} and
          Supervisor.which_children(private_workers) == []
      end,
      cleanup_cutoff
    )

    observe.(cleanup_cutoff)
    terminal["run_id"]
  end

  defp history(store, session) do
    assert {:ok, records} = Local.load_records(store, session, 0, 1_000)
    assert {:ok, events} = Local.load_events(store, session, 0, 1_000)
    assert length(records) < 1_000 and length(events) < 1_000
    assert {:ok, state} = SessionState.recover(session, records, events)
    assert state.journal_version == length(records)
    assert state.event_sequence == length(events)
    {records, events, state}
  end

  defp settlements(records),
    do: Enum.filter(records, &(&1.payload.kind == "model_attempt_settled_v3"))

  defp assert_public_private_absence(events, attachment) do
    assert {:ok, current} =
             Loopex.attach(attachment.runtime, attachment.session_id,
               after_event_sequence: length(events)
             )

    snapshot = Loopex.snapshot(current)
    assert is_map(snapshot)

    for private <- private_values() do
      refute :erlang.term_to_binary(events) =~ private
      refute :erlang.term_to_binary(snapshot) =~ private
    end
  end

  defp private_values, do: [@private_a, @signature_a, @private_next, @signature_next, @key]

  defp messages(pairs),
    do:
      Enum.map(pairs, fn {role, text} ->
        %{"role" => role, "content" => [%{"type" => "text", "text" => text}]}
      end)

  defp finished(attachment, cutoff) do
    case Loopex.next_event(attachment) do
      {:ok, %{kind: "run.finished"} = event} ->
        event

      _ ->
        assert now() < cutoff, "run did not finish within its captured work cutoff"
        Process.sleep(10)
        finished(attachment, cutoff)
    end
  end

  defp monitor(pids),
    do:
      Enum.map(Enum.uniq(pids), fn pid ->
        assert is_pid(pid) and Process.alive?(pid)
        {pid, Process.monitor(pid)}
      end)

  defp join(monitors, cutoff) do
    for {pid, reference} <- monitors do
      receive do
        {:DOWN, ^reference, :process, ^pid, _reason} -> refute Process.alive?(pid)
      after
        left(cutoff) ->
          flunk("original actor did not join within captured cutoff: #{inspect(pid)}")
      end
    end

    assert now() < cutoff
  end

  defp await(check, cutoff) do
    if check.() do
      :ok
    else
      assert now() < cutoff, "native entry did not reach its gate"
      Process.sleep(10)
      await(check, cutoff)
    end
  end

  defp now, do: System.monotonic_time(:millisecond)
  defp left(cutoff), do: max(cutoff - now(), 0)

  defp response(model, text, private) do
    content =
      if private do
        {thinking, signature} = private

        [
          %{"type" => "thinking", "thinking" => thinking, "signature" => signature},
          %{"type" => "text", "text" => text}
        ]
      else
        [%{"type" => "text", "text" => text}]
      end

    response_content(model, content)
  end

  defp response_content(model, content, stop_reason \\ "end_turn") do
    start = %{
      "type" => "message_start",
      "message" => %{
        "id" => "switch-reply",
        "type" => "message",
        "role" => "assistant",
        "model" => String.replace_prefix(model, "anthropic:", ""),
        "content" => [],
        "stop_reason" => nil,
        "stop_sequence" => nil,
        "usage" => %{"input_tokens" => 11}
      }
    }

    blocks =
      Enum.flat_map(Enum.with_index(content), fn {block, index} ->
        {initial, deltas} =
          case block do
            %{"type" => "redacted_thinking"} ->
              {block, []}

            %{"type" => "text", "text" => bytes} ->
              {%{"type" => "text", "text" => ""}, [%{"type" => "text_delta", "text" => bytes}]}

            %{"type" => "thinking", "thinking" => bytes, "signature" => signature} ->
              {%{"type" => "thinking", "thinking" => "", "signature" => ""},
               [
                 %{"type" => "thinking_delta", "thinking" => bytes},
                 %{"type" => "signature_delta", "signature" => signature}
               ]}

            %{"type" => "tool_use", "input" => arguments} ->
              {Map.put(block, "input", %{}),
               [%{"type" => "input_json_delta", "partial_json" => Jason.encode!(arguments)}]}
          end

        [%{"type" => "content_block_start", "index" => index, "content_block" => initial}] ++
          Enum.map(deltas, &%{"type" => "content_block_delta", "index" => index, "delta" => &1}) ++
          [%{"type" => "content_block_stop", "index" => index}]
      end)

    tail = [
      %{
        "type" => "message_delta",
        "delta" => %{"stop_reason" => stop_reason, "stop_sequence" => nil},
        "usage" => %{"output_tokens" => 4}
      },
      %{"type" => "message_stop"}
    ]

    Enum.map_join([start] ++ blocks ++ tail, fn event ->
      "event: #{event["type"]}\ndata: #{Jason.encode!(event)}\n\n"
    end)
  end
end
