Code.require_file("../../loopex/test/support/m1_runtime_helper.exs", __DIR__)
Code.require_file("../../loopex/test/support/agent_loop_helper.exs", __DIR__)
Code.require_file("../../loopex/test/support/configured_genesis_helper.exs", __DIR__)

defmodule LoopexCli.ChatResumeConfigurationTest do
  use ExUnit.Case, async: false
  @moduletag capture_log: true
  alias LoopexCli.ChatConfiguration
  alias Loopex.AgentLoopFixture, as: Fixture

  defmodule PendingPolicy do
    @moduledoc false
    @behaviour Loopex.Policy
    @impl true
    def decide(_request), do: {:deny, :policy_denied}

    @impl true
    def decide(request, observer) do
      if Map.has_key?(request, :interaction_response) do
        send(observer, {:policy_reevaluation, self()})
        receive do: (:release -> {:deny, :policy_denied})
      else
        {:defer,
         %{
           kind: :choice,
           prompt: "May this effect proceed?",
           choices: [%{id: "allow", label: "Allow"}, %{id: "deny", label: "Deny"}],
           expires_in_ms: 60_000
         }}
      end
    end
  end

  setup do
    root = Path.join(System.tmp_dir!(), "chat-resume-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "workspace"))
    path = Path.join(root, "config.json")

    profile = %{
      "schema_version" => 1,
      "providers" => %{"anthropic" => %{"credential" => %{"env" => "M7_RESUME_SLOT"}}},
      "policy" => "allow-all",
      "paths" => %{"workspace" => "workspace", "state_root" => "state"},
      "session" => %{
        "model" => "anthropic:claude-haiku-4-5",
        "tools" => "read-only",
        "system_class_tokens" => 8000,
        "bounds" => %{"max_turns" => 8, "deadline_ms" => 1000, "token_budget" => 10000}
      }
    }

    File.write!(path, :json.encode(profile))
    {:ok, prepared} = ChatConfiguration.load(["chat", "--config", path], root, nil)

    fixture =
      start(
        tools: prepared.genesis["tool_selection"]["definitions"],
        model: prepared.selection.configuration["model"]
      )

    {:ok, session} =
      Loopex.create_session(fixture.runtime, prepared.session_options,
        command_id: "create",
        genesis: prepared.genesis
      )

    on_exit(fn -> File.rm_rf!(root) end)

    %{
      root: root,
      path: path,
      profile: profile,
      prepared: prepared,
      fixture: fixture,
      session: session
    }
  end

  test "restart preserves exact settings and ignores changed file instructions, tools and helper defaults",
       f do
    assert :ok = Loopex.stop(f.fixture.runtime)
    restarted = start(store: f.fixture.store, tools: [], model: "anthropic:file-default")

    profile =
      f.profile
      |> put_in(["session", "model"], "anthropic:unknown-file-default")
      |> put_in(["session", "max_tokens"], 1024)
      |> put_in(["session", "context_token_budget"], 16000)
      |> put_in(["session", "tools"], "coding")
      |> put_in(["session", "instructions"], %{"system_file" => "absent-do-not-read.txt"})
      |> Map.put("roles", %{
        "reviewer" => %{
          "model" => "anthropic:claude-haiku-4-5",
          "instructions_file" => "also-absent.txt"
        }
      })
      |> Map.put("delegation", %{
        "enabled" => true,
        "roles" => ["reviewer"],
        "max_children" => 1,
        "token_budget" => 1000,
        "child_bounds" => %{"max_turns" => 1, "deadline_ms" => 1000, "token_budget" => 1000}
      })

    File.write!(f.path, :json.encode(profile))
    {:ok, invocation} = load(f, ["--max-steps", "3", "--no-helpers"])
    activation = activation(restarted, f.session)
    before = Fixture.records(restarted, f.session)
    assert {:ok, resumed} = ChatConfiguration.resume(invocation, activation)
    assert resumed.selection.configuration == f.prepared.selection.configuration
    assert resumed.retained.tool_selection == f.prepared.genesis["tool_selection"]
    assert resumed.startup.session_options == f.prepared.session_options

    assert resumed.selection.profile["session"]["model"] ==
             resumed.selection.configuration["model"]

    assert resumed.selection.profile["session"]["tools"] == "read-only"
    refute Map.has_key?(resumed.selection.profile["session"], "instructions")
    assert resumed.selection.profile["roles"] == %{}
    assert resumed.selection.profile["delegation"] == %{"enabled" => false, "roles" => []}
    assert resumed.selection.profile["session"]["bounds"]["max_turns"] == 3
    assert resumed.selection.origins["/session/model"] == "committed"
    assert resumed.selection.origins["/session/instructions"] == "committed"
    assert resumed.selection.origins["/session/bounds/max_turns"] == "flag"
    rows = LoopexCli.ConfigInspection.settings_rows(resumed.selection, %{})

    for field <- ~w(model reasoning max_tokens context_token_budget system_class_tokens) do
      row = Enum.find(rows, &(&1["setting"] == "/session/" <> field))
      retained = f.prepared.selection.configuration[field]
      assert row["origin"] == "committed"

      assert row["value"] ==
               if(is_integer(retained), do: Integer.to_string(retained), else: retained)
    end

    assert Enum.find(rows, &(&1["setting"] == "/session/cleanup_grace_ms"))["origin"] ==
             "committed"

    refute inspect(rows) =~ "absent-do-not-read"
    refute inspect(rows) =~ "M7_RESUME_SLOT"
    assert Fixture.records(restarted, f.session) == before
    assert Loopex.AgentLoopTestModel.dispatched(restarted.model) == []
    assert Agent.get(restarted.executor, & &1.jobs) == []
    assert {:ok, _} = Loopex.prepared_session_configuration(activation)

    assert {:ok, %{"max_tokens" => 2048}, candidate} =
             ChatConfiguration.update(resumed, %{"max_tokens" => 2048})

    assert candidate["configuration_version"] == 2
    assert :ok = Loopex.abandon_resume(activation)
  end

  for status <- [:pending, :answered] do
    @pending_status status
    test "#{status} policy question requires the exact selected registry identity before activation",
         f do
      expected = %{"id" => inspect(LoopexCli.Policy.AllowAll), "revision" => "0.2.0"}
      fixture = pending_policy_fixture(f, expected, @pending_status)
      bound = %{f | fixture: fixture.fixture, session: fixture.session}
      {:ok, invocation} = load(bound)
      activation = activation(fixture.fixture, fixture.session)

      before =
        {Fixture.records(fixture.fixture, fixture.session),
         Fixture.events(fixture.fixture, fixture.session)}

      assert {:ok, capture} = Loopex.prepared_session_startup(activation)
      assert capture.session_options == f.prepared.session_options

      assert invocation.selection.profile["paths"]["workspace"] ==
               f.prepared.selection.profile["paths"]["workspace"]

      assert {:ok, actual_workspace} =
               LoopexComposition.WorkspaceIdentity.reference(
                 invocation.selection.profile["paths"]["workspace"]
               )

      assert actual_workspace == capture.session_options["workspace_binding"]["workspace_ref"]

      assert capture.admitted_workspace_refs in [
               [],
               [f.prepared.session_options["workspace_binding"]["workspace_ref"]]
             ]

      assert {:ok, resumed} = ChatConfiguration.resume(invocation, activation)
      assert resumed.startup.pending_policy_identity == expected
      assert resumed.startup.admitted_models == [f.prepared.selection.configuration["model"]]

      assert {Fixture.records(fixture.fixture, fixture.session),
              Fixture.events(fixture.fixture, fixture.session)} == before

      assert Loopex.AgentLoopTestModel.dispatched(fixture.fixture.model) == []
      assert Agent.get(fixture.fixture.executor, & &1.jobs) == []
      refute_receive {:policy_reevaluation, _}, 0
      assert :ok = Loopex.abandon_resume(activation)

      {:ok, conflicting} = load(bound, ["--policy", "shell-allowlist"])
      activation = activation(fixture.fixture, fixture.session)

      refused_before =
        {Fixture.records(fixture.fixture, fixture.session),
         Fixture.events(fixture.fixture, fixture.session)}

      assert {:error, :chat_pending_policy_binding_conflict} =
               ChatConfiguration.resume(conflicting, activation)

      assert {:error, :resume_activation_abandoned} = Loopex.prepared_session_startup(activation)

      assert {Fixture.records(fixture.fixture, fixture.session),
              Fixture.events(fixture.fixture, fixture.session)} == refused_before

      assert Loopex.AgentLoopTestModel.dispatched(fixture.fixture.model) == []
      assert Agent.get(fixture.fixture.executor, & &1.jobs) == []
      refute_receive {:policy_reevaluation, _}, 0
    end
  end

  test "a matching policy name cannot adopt another retained revision", f do
    identity = %{"id" => inspect(LoopexCli.Policy.AllowAll), "revision" => "changed"}
    fixture = pending_policy_fixture(f, identity, :pending)
    {:ok, invocation} = load(%{f | fixture: fixture.fixture, session: fixture.session})
    activation = activation(fixture.fixture, fixture.session)

    before =
      {Fixture.records(fixture.fixture, fixture.session),
       Fixture.events(fixture.fixture, fixture.session)}

    assert {:error, :chat_pending_policy_binding_conflict} =
             ChatConfiguration.resume(invocation, activation)

    assert {:error, :resume_activation_abandoned} = Loopex.prepared_session_startup(activation)

    assert {Fixture.records(fixture.fixture, fixture.session),
            Fixture.events(fixture.fixture, fixture.session)} == before

    assert Loopex.AgentLoopTestModel.dispatched(fixture.fixture.model) == []
    assert Agent.get(fixture.fixture.executor, & &1.jobs) == []
  end

  test "a pending run refuses a missing admitted-model route without consuming credentials", f do
    identity = %{"id" => inspect(LoopexCli.Policy.AllowAll), "revision" => "0.2.0"}
    fixture = pending_policy_fixture(f, identity, :pending)

    profile =
      f.profile
      |> Map.put("providers", %{
        "openai" => %{"credential" => %{"env" => "M7_PENDING_ROUTE_SLOT"}}
      })
      |> put_in(["session", "model"], "openai:irrelevant-file-default")

    File.write!(f.path, :json.encode(profile))
    {:ok, invocation} = load(%{f | fixture: fixture.fixture, session: fixture.session})
    activation = activation(fixture.fixture, fixture.session)
    assert {:ok, %{admitted_models: models}} = Loopex.prepared_session_startup(activation)
    assert models == [f.prepared.selection.configuration["model"]]

    before =
      {Fixture.records(fixture.fixture, fixture.session),
       Fixture.events(fixture.fixture, fixture.session)}

    previous = System.get_env("M7_PENDING_ROUTE_SLOT")
    System.put_env("M7_PENDING_ROUTE_SLOT", "unconsumed-pending-route-canary")

    try do
      assert {:error, :provider_route_unavailable} =
               ChatConfiguration.resume(invocation, activation)

      assert {:error, :resume_activation_abandoned} = Loopex.prepared_session_startup(activation)
      assert System.get_env("M7_PENDING_ROUTE_SLOT") == "unconsumed-pending-route-canary"

      assert {Fixture.records(fixture.fixture, fixture.session),
              Fixture.events(fixture.fixture, fixture.session)} == before

      assert Loopex.AgentLoopTestModel.dispatched(fixture.fixture.model) == []
      assert Agent.get(fixture.fixture.executor, & &1.jobs) == []
      refute_receive {:policy_reevaluation, _}, 0
    after
      if previous,
        do: System.put_env("M7_PENDING_ROUTE_SLOT", previous),
        else: System.delete_env("M7_PENDING_ROUTE_SLOT")
    end
  end

  test "a different selected policy is permitted when no retained policy question exists", f do
    {:ok, invocation} = load(f, ["--policy", "shell-allowlist"])
    activation = activation(f.fixture, f.session)

    assert {:ok, %{startup: %{pending_policy_identity: nil}}} =
             ChatConfiguration.resume(invocation, activation)

    assert :ok = Loopex.abandon_resume(activation)
  end

  test "a same-root alias retains binding but an explicit different workspace refuses", f do
    alias_path = Path.join(f.root, "workspace-alias")
    File.ln_s!(Path.join(f.root, "workspace"), alias_path)
    {:ok, invocation} = load(f, ["--workspace", alias_path])
    activation = activation(f.fixture, f.session)
    assert {:ok, resumed} = ChatConfiguration.resume(invocation, activation)
    assert resumed.startup.session_options == f.prepared.session_options
    assert :ok = Loopex.abandon_resume(activation)

    alternate = Path.join(f.root, "another-workspace")
    File.mkdir!(alternate)
    {:ok, invocation} = load(f, ["--workspace", alternate])
    assert_workspace_refusal(f, invocation, :chat_workspace_binding_conflict)
  end

  test "replacement after file preflight refuses even at the same textual path", f do
    {:ok, invocation} = load(f)
    workspace = Path.join(f.root, "workspace")
    File.rename!(workspace, workspace <> "-previous")
    File.mkdir!(workspace)
    assert {:ok, changed} = LoopexComposition.WorkspaceIdentity.reference(workspace)
    refute changed == f.prepared.session_options["workspace_binding"]["workspace_ref"]
    assert_workspace_refusal(f, invocation, :chat_workspace_binding_conflict)
  end

  test "an absent or non-directory selected workspace abandons without creating a root", f do
    {:ok, invocation} = load(f)
    workspace = Path.join(f.root, "workspace")
    File.rename!(workspace, workspace <> "-previous")
    assert_workspace_refusal(f, invocation, :enoent)
    refute File.exists?(workspace)
    File.write!(workspace, "not a directory")
    assert_workspace_refusal(f, invocation, :workspace_root_not_directory)
    assert File.read!(workspace) == "not a directory"
  end

  test "retargeting a captured workspace symlink refuses before activation", f do
    workspace = Path.join(f.root, "workspace")
    alias_path = Path.join(f.root, "workspace-alias")
    alternate = Path.join(f.root, "another-workspace")
    File.mkdir!(alternate)
    File.ln_s!(workspace, alias_path)

    {:ok, prepared} =
      ChatConfiguration.load(["chat", "--config", f.path, "--workspace", alias_path], f.root, nil)

    {:ok, session} =
      Loopex.create_session(f.fixture.runtime, prepared.session_options,
        command_id: "symlink-create",
        genesis: prepared.genesis
      )

    bound = %{f | session: session, prepared: prepared}
    {:ok, invocation} = load(bound, ["--workspace", alias_path])
    File.rm!(alias_path)
    File.ln_s!(alternate, alias_path)
    assert_workspace_refusal(bound, invocation, :chat_workspace_binding_conflict)
  end

  test "missing or malformed binding refuses rather than adopting an explicit host workspace",
       f do
    for {options, index} <-
          Enum.with_index([
            %{"surface" => "chat"},
            put_in(f.prepared.session_options, ["workspace_binding", "revision"], 0),
            put_in(f.prepared.session_options, ["workspace_binding", "unexpected"], true)
          ]) do
      genesis = Map.put(f.prepared.genesis, "options", options)

      {:ok, session} =
        Loopex.create_session(f.fixture.runtime, options,
          command_id: "unbound-#{index}",
          genesis: genesis
        )

      bound = %{f | session: session}
      {:ok, invocation} = load(bound, ["--workspace", Path.join(f.root, "workspace")])
      assert_workspace_refusal(bound, invocation, :chat_workspace_binding_unavailable)
    end
  end

  test "a real retained effect for another workspace refuses without redispatch", f do
    fixture =
      Fixture.start(
        script: [
          %{
            text: "proposed",
            calls: [
              %{id: "call", name: "write", arguments: %{"path" => "owned.txt"}}
            ]
          }
        ]
      )

    on_exit(fn -> Fixture.stop(fixture) end)

    genesis =
      Loopex.ConfiguredGenesisFixture.genesis(fixture.definitions)
      |> Map.put("options", f.prepared.session_options)

    {:ok, session} =
      Loopex.create_session(fixture.runtime, f.prepared.session_options,
        command_id: "pending-effect",
        genesis: genesis
      )

    {:ok, attachment} = Loopex.attach(fixture.runtime, session)

    :ok =
      Loopex.M1RuntimeTestStore.delay_after_record(
        fixture.store,
        "effect_intent_committed_v2",
        self()
      )

    assert {:accepted, "prompt"} =
             Loopex.command(
               attachment,
               %{type: :prompt, command_id: "prompt", content: "effect"}
             )

    assert_receive {:record_linearized, waiter, _store, "effect_intent_committed_v2", _tx,
                    {:committed, _, _}},
                   5_000

    {:ok, children} = Loopex.Runtime.children(fixture.runtime)
    coordinator = :sys.get_state(children.control).sessions[session].coordinator
    monitor = Process.monitor(coordinator)
    Process.exit(coordinator, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^coordinator, :killed}, 5_000
    Loopex.M1RuntimeTestStore.release(waiter)
    bound = %{f | fixture: fixture, session: session}
    {:ok, invocation} = load(bound)
    activation = activation(fixture, session)

    assert {:ok, %{admitted_workspace_refs: ["workspace-ref"]}} =
             Loopex.prepared_session_startup(activation)

    before = {Fixture.records(fixture, session), Fixture.events(fixture, session)}
    dispatched = Loopex.AgentLoopTestModel.dispatched(fixture.model)
    assert length(dispatched) == 1

    assert ChatConfiguration.resume(invocation, activation) ==
             {:error, :chat_workspace_binding_conflict}

    assert {:error, :resume_activation_abandoned} = Loopex.prepared_session_startup(activation)
    assert {Fixture.records(fixture, session), Fixture.events(fixture, session)} == before
    assert Loopex.AgentLoopTestModel.dispatched(fixture.model) == dispatched
    assert Agent.get(fixture.executor, & &1.jobs) == []
  end

  test "each conflicting durable flag abandons its owner without dispatch or configuration mutation",
       f do
    for {flag, value} <- [
          {"cleanup-grace-ms", "17"},
          {"reasoning", "none"},
          {"max-tokens", "8000"},
          {"context-token-budget", "16000"},
          {"system-class-tokens", "2000"},
          {"tools", "coding"},
          {"model", "anthropic:claude-fable-5-1"}
        ] do
      {:ok, invocation} = load(f, ["--" <> flag, value])
      activation = activation(f.fixture, f.session)
      before = Fixture.records(f.fixture, f.session)

      assert ChatConfiguration.resume(invocation, activation) ==
               {:error, {:chat_resume_configuration_conflict, "/flags/" <> flag}}

      assert {:error, :resume_activation_abandoned} =
               Loopex.prepared_session_configuration(activation)

      assert Fixture.records(f.fixture, f.session) == before
      assert Loopex.AgentLoopTestModel.dispatched(f.fixture.model) == []
      assert Agent.get(f.fixture.executor, & &1.jobs) == []
    end
  end

  test "matching explicit values and model alias retain the original configuration bytes", f do
    configuration = f.prepared.selection.configuration

    flags = [
      "--model",
      "anthropic:claude-haiku-4-5",
      "--tools",
      "read-only",
      "--reasoning",
      "default",
      "--max-tokens",
      Integer.to_string(configuration["max_tokens"]),
      "--context-token-budget",
      Integer.to_string(configuration["context_token_budget"]),
      "--system-class-tokens",
      "8000",
      "--cleanup-grace-ms",
      "5000"
    ]

    {:ok, invocation} = load(f, flags)
    activation = activation(f.fixture, f.session)
    assert {:ok, resumed} = ChatConfiguration.resume(invocation, activation)
    assert resumed.selection.configuration == configuration
    assert :ok = Loopex.abandon_resume(activation)
  end

  test "missing retained model route refuses and abandons, without credential reads", f do
    profile =
      f.profile
      |> Map.put("providers", %{"openai" => %{"credential" => %{"env" => "M7_ABSENT_SLOT"}}})
      |> put_in(["session", "model"], "openai:gpt-4o")

    File.write!(f.path, :json.encode(profile))
    {:ok, invocation} = load(f)
    activation = activation(f.fixture, f.session)

    assert {:error, :provider_route_unavailable} =
             ChatConfiguration.resume(invocation, activation)

    assert {:error, :resume_activation_abandoned} =
             Loopex.prepared_session_configuration(activation)
  end

  test "resume uses the latest confirmed configuration rather than genesis or file defaults", f do
    changes = %{"max_tokens" => 2048}
    assert {:ok, ^changes, candidate} = ChatConfiguration.update(f.prepared, changes)
    {:ok, attachment} = Loopex.attach(f.fixture.runtime, f.session)

    assert {:accepted, "configure"} =
             Loopex.command_with_configuration(
               attachment,
               %{type: :configure, command_id: "configure", changes: changes},
               candidate
             )

    {:ok, invocation} = load(f)
    activation = activation(f.fixture, f.session)
    assert {:ok, resumed} = ChatConfiguration.resume(invocation, activation)
    assert resumed.selection.configuration == candidate
    assert resumed.selection.profile["session"]["max_tokens"] == 2048
    assert {:ok, _, next} = ChatConfiguration.update(resumed, %{"max_tokens" => 1024})
    assert next["configuration_version"] == 3
    assert :ok = Loopex.abandon_resume(activation)
    {:ok, conflicting} = load(f, ["--max-tokens", "4096"])
    activation = activation(f.fixture, f.session)

    assert {:error, {:chat_resume_configuration_conflict, "/flags/max-tokens"}} =
             ChatConfiguration.resume(conflicting, activation)

    assert {:error, :resume_activation_abandoned} =
             Loopex.prepared_session_configuration(activation)
  end

  test "new maintenance selection stays separate and no provider credential is consumed", f do
    previous = System.get_env("M7_RESUME_SLOT")
    System.put_env("M7_RESUME_SLOT", "resume-credential-canary")

    try do
      {:ok, invocation} = load(f, ["--compaction-model", "anthropic:claude-haiku-4-5"])
      activation = activation(f.fixture, f.session)
      assert {:ok, resumed} = ChatConfiguration.resume(invocation, activation)
      assert resumed.selection.configuration == f.prepared.selection.configuration
      assert resumed.selection.maintenance_model["reasoning"] == "none"
      assert resumed.selection.maintenance_model["provider_mapping"]["thinking_disabled"]
      assert resumed.selection.origins["/maintenance/model"] == "flag"
      assert System.get_env("M7_RESUME_SLOT") == "resume-credential-canary"
      refute :erlang.term_to_binary(resumed.retained) =~ "resume-credential-canary"
      assert :ok = Loopex.abandon_resume(activation)
    after
      if previous,
        do: System.put_env("M7_RESUME_SLOT", previous),
        else: System.delete_env("M7_RESUME_SLOT")
    end
  end

  test "authored bounds stay mandatory and inspection cannot acquire a resume profile", f do
    for key <- ~w(max_turns deadline_ms token_budget) do
      invalid = update_in(f.profile, ["session", "bounds"], &Map.delete(&1, key))
      File.write!(f.path, :json.encode(invalid))

      assert {:error, {:missing_member, pointer}} =
               load(f, ["--max-steps", "8", "--deadline-ms", "1000", "--token-budget", "10000"])

      assert pointer == "/session/bounds/" <> key
    end

    assert {:error, _} =
             ChatConfiguration.load_resume(
               ["config", "show", "--config", f.path, "--effective"],
               f.root,
               nil
             )

    refute File.exists?(Path.join(f.root, "state"))
  end

  test "only explicit prompt files are read and changed bytes abandon before activation", f do
    path = Path.join(f.root, "appendix.txt")
    File.write!(path, "")
    {:ok, invocation} = load(f, ["--append-system-prompt-file", path])
    activation = activation(f.fixture, f.session)
    assert {:ok, resumed} = ChatConfiguration.resume(invocation, activation)
    assert resumed.selection.configuration == f.prepared.selection.configuration
    assert :ok = Loopex.abandon_resume(activation)
    File.write!(path, "Changed 猫\n")
    activation = activation(f.fixture, f.session)

    assert {:error, {:chat_resume_configuration_conflict, "/flags/append-system-prompt-file"}} =
             ChatConfiguration.resume(invocation, activation)

    assert {:error, :resume_activation_abandoned} =
             Loopex.prepared_session_configuration(activation)
  end

  test "post-preparation input and instruction refusals abandon the owner", f do
    for failure <- [:invalid_invocation, :missing_file, :oversized_file] do
      activation = activation(f.fixture, f.session)

      {invocation, expected} =
        case failure do
          :invalid_invocation ->
            {nil, :invalid_chat_resume_invocation}

          disposition ->
            path = Path.join(f.root, "#{disposition}.txt")

            if disposition == :oversized_file,
              do: File.write!(path, String.duplicate("x", 32_769))

            {:ok, invocation} = load(f, ["--system-prompt-file", path])

            {invocation,
             if(disposition == :missing_file,
               do: :invalid_instruction_file,
               else: :instruction_file_too_large
             )}
        end

      assert ChatConfiguration.resume(invocation, activation) == {:error, expected}

      assert {:error, :resume_activation_abandoned} =
               Loopex.prepared_session_configuration(activation)
    end
  end

  test "failed abandonment preserves the original refusal and never claims confirmed cleanup",
       f do
    {:ok, invocation} = load(f)
    activation = activation(f.fixture, f.session)
    parent = self()

    holder =
      spawn(fn ->
        receive do
          :abandon -> send(parent, {:abandoned, Loopex.abandon_resume(activation)})
        end
      end)

    monitor = Process.monitor(holder)
    assert :ok = Loopex.transfer_resume(activation, holder)

    assert {:error,
            {:resume_configuration_owner_unconfirmed, :resume_activation_holder_mismatch,
             :resume_activation_holder_mismatch}} =
             ChatConfiguration.resume(invocation, activation)

    send(holder, :abandon)
    assert_receive {:abandoned, :ok}
    assert_receive {:DOWN, ^monitor, :process, ^holder, :normal}
  end

  defp pending_policy_fixture(f, identity, status) do
    options = [
      tools: f.prepared.genesis["tool_selection"]["definitions"],
      model: f.prepared.selection.configuration["model"],
      policy: %{module: PendingPolicy, context: self()},
      policy_identity: identity,
      workspace_ref: f.prepared.session_options["workspace_binding"]["workspace_ref"],
      script: [
        %{
          text: "proposed",
          calls: [%{id: "read", name: "read", arguments: %{"path" => "owned.txt"}}]
        }
      ]
    ]

    original = Fixture.start(options)
    on_exit(fn -> Fixture.stop(original) end)

    {:ok, session} =
      Loopex.create_session(original.runtime, f.prepared.session_options,
        command_id: "policy-create",
        genesis: f.prepared.genesis
      )

    {:ok, attachment} = Loopex.attach(original.runtime, session)

    assert {:accepted, "policy-prompt"} =
             Loopex.command(
               attachment,
               %{type: :prompt, command_id: "policy-prompt", content: "request read"}
             )

    question =
      await_policy_question(original.runtime, session, System.monotonic_time(:millisecond) + 5000)

    if status == :answered do
      assert {:accepted, "policy-answer"} =
               Loopex.command(
                 attachment,
                 %{
                   type: :interaction_answer,
                   command_id: "policy-answer",
                   interaction_id: question["interaction_id"],
                   choice_id: "allow"
                 }
               )

      assert_receive {:policy_reevaluation, _}, 5000
    end

    assert :ok = Loopex.stop(original.runtime)
    restarted = start(store: original.store, tools: [], policy_identity: identity)
    %{fixture: restarted, session: session}
  end

  defp await_policy_question(runtime, session, deadline) do
    {:ok, status} = Loopex.session_status(runtime, session)

    cond do
      status.open_interaction != nil ->
        status.open_interaction

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("policy question did not commit")

      true ->
        Process.sleep(1)
        await_policy_question(runtime, session, deadline)
    end
  end

  defp start(options) do
    fixture = Fixture.start(Keyword.put(options, :script, []))
    on_exit(fn -> Fixture.stop(fixture) end)
    fixture
  end

  defp assert_workspace_refusal(f, invocation, reason) do
    activation = activation(f.fixture, f.session)
    before = {Fixture.records(f.fixture, f.session), Fixture.events(f.fixture, f.session)}
    assert ChatConfiguration.resume(invocation, activation) == {:error, reason}
    assert {:error, :resume_activation_abandoned} = Loopex.prepared_session_startup(activation)
    assert {Fixture.records(f.fixture, f.session), Fixture.events(f.fixture, f.session)} == before
    assert Loopex.AgentLoopTestModel.dispatched(f.fixture.model) == []
    assert Agent.get(f.fixture.executor, & &1.jobs) == []
  end

  defp activation(fixture, session) do
    {:ok, {:prepared, activation}} =
      Loopex.prepare_resume_session(
        fixture.runtime,
        session,
        "resume-#{System.unique_integer([:positive])}"
      )

    activation
  end

  defp load(f, flags \\ []),
    do:
      ChatConfiguration.load_resume(
        ["chat", "--config", f.path, "--resume", f.session] ++ flags,
        f.root,
        nil
      )
end
