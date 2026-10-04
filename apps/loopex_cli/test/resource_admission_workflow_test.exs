defmodule LoopexCli.ResourceAdmissionWorkflowTest do
  use ExUnit.Case, async: false

  alias Loopex.ResourcePack
  alias Loopex.Runtime
  alias LoopexCli.DurableAsk
  alias LoopexComposition.Ephemeral
  alias LoopexComposition.Ephemeral.{OwnerActivation, SessionOwner}
  alias LoopexComposition.ResourcePacks

  defmodule Policy do
    @behaviour Loopex.Policy

    @impl true
    def decide(_request), do: {:allow, nil}
  end

  defmodule EphemeralFacade do
    @moduledoc false

    def create_session(runtime, %{"surface" => "embedded"},
          command_id: "create",
          genesis: genesis
        ) do
      {:ok, ^genesis} = Loopex.Runtime.SessionGenesis.normalize(genesis)
      send(runtime.token.test, :ephemeral_created)
      {:ok, "session-1"}
    end

    def attach(runtime, "session-1", after_event_sequence: 0) do
      {:ok,
       %Loopex.Attachment{
         runtime: runtime,
         session_id: "session-1",
         attachment_id: "attachment-1",
         incarnation_id: "incarnation-1",
         snapshot: %{}
       }}
    end

    def command(%Loopex.Attachment{runtime: runtime}, command) do
      send(runtime.token.test, {:ephemeral_command, command})

      if command.type == :activate_skill and command.name == runtime.token.fail_skill,
        do: {:accepted, "wrong-id"},
        else: {:accepted, command.command_id}
    end

    def resource_catalog(runtime, "session-1") do
      send(runtime.token.test, :ephemeral_catalog)
      {:ok, digest, normalized} = ResourcePack.digest(runtime.token.manifest)

      entries =
        Enum.map(normalized["packs"], fn pack ->
          %{
            "source_id" => pack["source_id"],
            "name" => pack["name"],
            "pack_digest" => ResourcePack.pack_digest(pack)
          }
        end)

      entries = if runtime.token.fail_catalog, do: tl(entries), else: entries

      {:ok,
       %{
         "configured_manifest_digest" => digest,
         "admitted_manifest_digest" => digest,
         "decision_disposition" => "active",
         "entries" => entries
       }}
    end

    def session_status(_runtime, "session-1"), do: {:error, :unexpected_status}
  end

  setup do
    root = Path.join(System.tmp_dir!(), "loopex-admission-#{System.unique_integer([:positive])}")
    workspace = Path.join(root, "workspace")
    File.mkdir_p!(workspace)

    paths = [
      skill(Path.join([workspace, ".agents", "skills", "zulu"]), "zulu"),
      skill(Path.join([workspace, ".agents", "skills", "alpha"]), "alpha"),
      skill(Path.join([root, "user", "alpha"]), "alpha"),
      skill(Path.join([root, "user", "beta"]), "beta")
    ]

    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root, workspace: workspace, paths: paths}
  end

  test "named directories cross both startup paths with one exact selection", fixture do
    %{workspace: workspace, paths: paths, root: root} = fixture

    assert {:ok, selected} =
             ResourcePacks.read_directories(Enum.reverse(paths), workspace: workspace)

    assert selected.shadowed_skills == ["user:alpha"]

    assert Enum.map(selected.manifest["packs"], &{&1["source_id"], &1["name"]}) == [
             {"project:alpha", "alpha"},
             {"project:zulu", "zulu"},
             {"user:beta", "beta"}
           ]

    # The public embedded startup must consume the same paths, not a prebuilt
    # manifest or ambient project discovery. No model call is made.
    assert {:ok, session} =
             Ephemeral.start_session(
               policy: Policy,
               model: "ollama:llama3.2",
               cwd: workspace,
               skills: paths,
               tools: :none
             )

    assert :ok = Ephemeral.stop_session(session)

    {seams, calls} = durable_harness(workspace, selected)

    assert %{status: 0, stdout: stdout, stderr: ""} =
             DurableAsk.run(durable_options(root, paths), workspace, "review", seams)

    assert JSON.decode!(String.trim_trailing(stdout, "\n"))["shadowed_skills"] == ["user:alpha"]

    observed = Agent.get(calls, & &1)
    assert Enum.count(observed, &match?({:helper, _}, &1)) == 1
    assert {:helper, ^selected} = hd(observed)
    assert {:composition_manifest, selected.manifest} in observed

    commands = for {:command, command} <- observed, do: command

    assert Enum.map(commands, & &1.type) == [
             :admit_resources,
             :activate_skill,
             :activate_skill,
             :activate_skill,
             :prompt
           ]

    {:ok, digest, normalized} = ResourcePack.digest(selected.manifest)
    assert hd(commands).manifest_digest == digest

    assert hd(commands).decision == %{
             "manifest_digest" => digest,
             "workspace_ref" => normalized["workspace_ref"],
             "trust_scope" => "project_skills",
             "decision_source" => "host_supplied",
             "issued_at" => "2026-09-27T12:34:56Z",
             "expires_at" => nil,
             "revocation_state" => "active"
           }

    assert Enum.map(Enum.slice(commands, 1, 3), &{&1.source_id, &1.name, &1.pack_digest}) ==
             Enum.map(normalized["packs"], fn pack ->
               {pack["source_id"], pack["name"], ResourcePack.pack_digest(pack)}
             end)

    assert Enum.all?(Enum.slice(commands, 1, 3), &(&1.supporting_labels == []))
    assert Enum.map(commands, & &1.command_id) |> Enum.uniq() |> length() == 5

    assert Enum.find_index(observed, &match?({:catalog, _}, &1)) <
             Enum.find_index(observed, &match?({:command, %{type: :activate_skill}}, &1))
  end

  test "an empty named selection starts ephemeral and skips durable resource commands", fixture do
    %{workspace: workspace, root: root} = fixture
    assert {:ok, selected} = ResourcePacks.read_directories([], workspace: workspace)

    assert {:ok, session} =
             Ephemeral.start_session(
               policy: Policy,
               model: "ollama:llama3.2",
               cwd: workspace,
               skills: [],
               tools: :none
             )

    assert :ok = Ephemeral.stop_session(session)

    {seams, calls} = durable_harness(workspace, selected)

    assert %{status: 0} =
             DurableAsk.run(durable_options(root, []), workspace, "review", seams)

    assert for({:command, command} <- Agent.get(calls, & &1), do: command.type) == [:prompt]
    refute Enum.any?(Agent.get(calls, & &1), &match?({:catalog, _}, &1))
  end

  test "durable admission faults stop at the first uncertain command or catalog", fixture do
    %{workspace: workspace, paths: paths, root: root} = fixture
    assert {:ok, selected} = ResourcePacks.read_directories(paths, workspace: workspace)

    faults = [
      {:refused, {:error, :refused}},
      {:session_lost, {:error, :session_unavailable}},
      {:malformed, {:accepted, "other-id"}},
      {:raise, :raise},
      {:exit, :exit}
    ]

    for {_kind, fault} <- faults do
      {seams, calls} = durable_harness(workspace, selected, admission: fault)

      assert %{status: 1, stdout: "", stderr: "loopex: resource_admission_failed\n"} =
               DurableAsk.run(durable_options(root, paths), workspace, "review", seams)

      assert for({:command, command} <- Agent.get(calls, & &1), do: command.type) == [
               :admit_resources
             ]

      refute Enum.any?(Agent.get(calls, & &1), &match?({:catalog, _}, &1))
    end

    for fault <- [
          :missing_tuple,
          :extra_tuple,
          :duplicate_tuple,
          :digest_mismatch,
          :refused,
          :malformed,
          :session_lost,
          :raise,
          :exit
        ] do
      {seams, calls} = durable_harness(workspace, selected, catalog: fault)

      assert %{status: 1, stdout: "", stderr: "loopex: resource_admission_failed\n"} =
               DurableAsk.run(durable_options(root, paths), workspace, "review", seams)

      assert for({:command, command} <- Agent.get(calls, & &1), do: command.type) == [
               :admit_resources
             ]

      assert Enum.count(Agent.get(calls, & &1), &match?({:catalog, _}, &1)) == 1
    end
  end

  test "each durable activation failure stops at its possibly accepted command prefix", fixture do
    %{workspace: workspace, paths: paths, root: root} = fixture
    assert {:ok, selected} = ResourcePacks.read_directories(paths, workspace: workspace)

    for index <- 1..3 do
      {seams, calls} = durable_harness(workspace, selected, activation: index)

      assert %{status: 1, stdout: "", stderr: "loopex: skill_activation_failed\n"} =
               DurableAsk.run(durable_options(root, paths), workspace, "review", seams)

      commands = for {:command, command} <- Agent.get(calls, & &1), do: command

      assert Enum.map(commands, & &1.type) ==
               [:admit_resources | List.duplicate(:activate_skill, index)]

      refute Enum.any?(commands, &(&1.type == :prompt))
    end
  end

  test "ephemeral catalog and later activation failures remove partial session roots", fixture do
    %{workspace: workspace, paths: paths, root: root} = fixture
    assert {:ok, selected} = ResourcePacks.read_directories(paths, workspace: workspace)

    for {fault, cause} <- [
          {{true, nil}, :resource_admission},
          {{false, "zulu"}, :skill_activation}
        ] do
      {fail_catalog, fail_skill} = fault
      tmp = Path.join(root, "ephemeral-#{cause}")
      File.mkdir!(tmp)
      test = self()

      configuration = %{
        cwd: workspace,
        model: "ollama:test",
        provider: %{credential_variable: nil},
        base_url: "http://localhost:11434",
        policy: Policy,
        tools: :none,
        skills: selected,
        max_steps: 16,
        deadline_ms: 60_000,
        max_tokens: 128,
        context_token_budget: 8_192,
        timeout: 90_000,
        test_facade: EphemeralFacade,
        test_now: fn -> ~U[2026-09-27 12:34:56Z] end,
        test_seams: %{
          temp_root: %{tmp: fn -> tmp end},
          runtime_holder: %{
            runtime_start: fn _options ->
              {:ok, supervisor} = Supervisor.start_link([], strategy: :one_for_one)

              {:ok,
               %Runtime{
                 supervisor: supervisor,
                 token: %{
                   test: test,
                   manifest: selected.manifest,
                   fail_catalog: fail_catalog,
                   fail_skill: fail_skill
                 }
               }}
            end
          },
          trace_bind: fn _, _ -> :ok end,
          group_drain: fn executor, instance, owner, nonce, _deadline ->
            send(owner, {executor, instance, nonce, :groups_empty})
            {:ok, nonce}
          end,
          group_attest: fn _executor, _instance, _nonce, _deadline -> :ok end
        }
      }

      {:ok, genesis} =
        Ephemeral.Preflight.genesis(configuration, workspace, %{
          "ollama" => %{"credential" => %{"none" => true}}
        })

      configuration = Map.put(configuration, :genesis, genesis)

      {:ok, supervisor} = DynamicSupervisor.start_link(strategy: :one_for_one)
      {:ok, activation} = OwnerActivation.start(supervisor)
      owner = OwnerActivation.owner(activation)
      {:ok, cell} = OwnerActivation.begin(activation)

      assert {:error, {^cause, :failed}} =
               SessionOwner.start_session(owner, configuration, 6_000)

      assert_receive :ephemeral_created
      assert_receive {:ephemeral_command, %{type: :admit_resources}}
      assert_receive :ephemeral_catalog

      if fail_skill do
        assert_receive {:ephemeral_command, %{type: :activate_skill, name: "alpha"}}
        assert_receive {:ephemeral_command, %{type: :activate_skill, name: "zulu"}}
      else
        refute_receive {:ephemeral_command, %{type: :activate_skill}}, 20
      end

      assert File.ls!(tmp) == []
      assert :atomics.get(cell, 1) == 2
      Supervisor.stop(supervisor)
    end
  end

  defp durable_options(root, paths) do
    %{
      profile: :durable,
      state_root: Path.join(root, "state"),
      skills: paths,
      policy: Policy,
      model: nil,
      tools: :none,
      max_steps: nil,
      deadline_ms: nil,
      output: "json"
    }
  end

  defp durable_harness(workspace, selected, faults \\ []) do
    {:ok, digest, normalized} = ResourcePack.digest(selected.manifest)
    root = Path.join(Path.dirname(workspace), "state")
    {:ok, calls} = Agent.start_link(fn -> [] end)
    record = fn entry -> Agent.update(calls, &(&1 ++ [entry])) end

    entries =
      Enum.map(normalized["packs"], fn pack ->
        %{
          "source_id" => pack["source_id"],
          "name" => pack["name"],
          "pack_digest" => ResourcePack.pack_digest(pack)
        }
      end)

    catalog = %{
      "configured_manifest_digest" => digest,
      "admitted_manifest_digest" => digest,
      "decision_disposition" => "active",
      "entries" => entries
    }

    facade = fn
      Loopex, :runtime_placement_id, [^root] ->
        {:ok, "placement-1"}

      Loopex, :create_session, [:runtime, %{"surface" => "cli"}, _] ->
        {:ok, "session-1"}

      Loopex, :track_session, [^root, "session-1", "placement-1"] ->
        :ok

      Loopex, :attach, [:runtime, "session-1", [after_event_sequence: 0]] ->
        {:ok, %Loopex.Attachment{}}

      Loopex, :resource_catalog, [:runtime, "session-1"] ->
        record.({:catalog, digest})
        catalog_fault(catalog, Keyword.get(faults, :catalog))

      Loopex, :session_status, [:runtime, "session-1"] ->
        {:ok, %{status: :active, cleanup_grace_ms: 5_000}}

      Loopex, :command, [%Loopex.Attachment{}, command] ->
        record.({:command, command})

        cond do
          command.type == :admit_resources ->
            command_fault(command, Keyword.get(faults, :admission))

          command.type == :activate_skill ->
            count =
              Agent.get(calls, fn observed ->
                Enum.count(observed, &match?({:command, %{type: :activate_skill}}, &1))
              end)

            if count == Keyword.get(faults, :activation),
              do: {:accepted, "other-id"},
              else: {:accepted, command.command_id}

          true ->
            {:accepted, command.command_id}
        end

      Loopex, :next_event, [%Loopex.Attachment{}] ->
        sequence = Agent.get(calls, &Enum.count(&1, fn entry -> entry == :next_event end))
        record.(:next_event)

        prompt =
          Agent.get(
            calls,
            &Enum.find_value(&1, fn
              {:command, %{type: :prompt, command_id: id}} -> id
              _ -> nil
            end)
          )

        event =
          case sequence do
            0 ->
              %{
                "run_id" => "run-1",
                "command_id" => prompt,
                event_sequence: 1,
                kind: "user.message_appended"
              }

            1 ->
              %{
                "run_id" => "run-1",
                "content" => "ready",
                event_sequence: 2,
                kind: "assistant.message_appended"
              }

            _ ->
              %{
                "run_id" => "run-1",
                "outcome" => "completed",
                "cleanup_grace_ms" => 5_000,
                event_sequence: 3,
                kind: "run.finished"
              }
          end

        {:ok, event}
    end

    seams = [
      read_directories: fn paths, [workspace: ^workspace] ->
        result = ResourcePacks.read_directories(paths, workspace: workspace)

        case result do
          {:ok, value} -> record.({:helper, value})
          _ -> record.({:helper_error, result})
        end

        result
      end,
      acquire_placement: fn ^root -> {:ok, :lock} end,
      release_placement: fn :lock -> :ok end,
      facade: facade,
      open_credential_host: fn -> {:ok, :host} end,
      credential_plane: fn :host -> {:ok, :plane} end,
      release_credential_plane: fn :plane -> :ok end,
      provider_launch: fn -> [] end,
      with_runtime: fn options, callback ->
        record.({:composition_manifest, options[:resource_manifest]})
        callback.(:runtime)
      end,
      interrupt_install: fn _, _ -> :ok end,
      entropy: fn 16 -> <<System.unique_integer([:positive])::128>> end,
      utc_now: fn -> ~U[2026-09-27 12:34:56Z] end
    ]

    {seams, calls}
  end

  defp command_fault(command, nil), do: {:accepted, command.command_id}
  defp command_fault(_command, :raise), do: raise("admission failed")
  defp command_fault(_command, :exit), do: exit(:admission_failed)
  defp command_fault(_command, reply), do: reply

  defp catalog_fault(catalog, nil), do: {:ok, catalog}
  defp catalog_fault(_catalog, :refused), do: {:error, :refused}
  defp catalog_fault(_catalog, :malformed), do: {:ok, :malformed}
  defp catalog_fault(_catalog, :session_lost), do: {:error, :session_unavailable}
  defp catalog_fault(_catalog, :raise), do: raise("catalog failed")
  defp catalog_fault(_catalog, :exit), do: exit(:catalog_failed)

  defp catalog_fault(catalog, :missing_tuple),
    do: {:ok, %{catalog | "entries" => tl(catalog["entries"])}}

  defp catalog_fault(catalog, :extra_tuple),
    do:
      {:ok,
       %{
         catalog
         | "entries" => [
             %{"source_id" => "extra", "name" => "extra", "pack_digest" => "extra"}
             | catalog["entries"]
           ]
       }}

  defp catalog_fault(catalog, :duplicate_tuple),
    do: {:ok, %{catalog | "entries" => [hd(catalog["entries"]) | catalog["entries"]]}}

  defp catalog_fault(catalog, :digest_mismatch),
    do: {:ok, %{catalog | "admitted_manifest_digest" => "wrong"}}

  defp skill(path, name) do
    File.mkdir_p!(path)

    File.write!(
      Path.join(path, "SKILL.md"),
      "---\nname: #{name}\ndescription: test skill\n---\nRead only.\n"
    )

    path
  end
end
