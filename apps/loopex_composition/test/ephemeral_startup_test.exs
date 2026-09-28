defmodule LoopexComposition.Ephemeral.StartupTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias Loopex.Runtime
  alias LoopexComposition.Ephemeral
  alias LoopexComposition.Ephemeral.{OwnerActivation, SessionOwner}

  defmodule Policy do
    @moduledoc false
    def decide(_request), do: {:allow, nil}
  end

  defmodule Facade do
    @moduledoc false

    def create_session(runtime, %{"surface" => "embedded"}, command_id: "create") do
      send(runtime.token, :created)
      {:ok, "ephemeral-session"}
    end

    def attach(runtime, "ephemeral-session", after_event_sequence: 0) do
      send(runtime.token, :attached)

      {:ok,
       %Loopex.Attachment{
         runtime: runtime,
         session_id: "ephemeral-session",
         attachment_id: "a",
         incarnation_id: "i",
         snapshot: %{}
       }}
    end

    def session_status(runtime, "ephemeral-session") do
      send(runtime.token, :status_read)

      {:ok,
       %{
         status: :active,
         owner_epoch: 0,
         active_run_id: nil,
         pending_work_ids: [],
         cleanup_grace_ms: 5_000
       }}
    end
  end

  defmodule SkillFacade do
    @moduledoc false
    alias Loopex.ResourcePack

    def create_session(runtime, %{"surface" => "embedded"}, command_id: "create") do
      send(runtime.token.test, :created)
      {:ok, "ephemeral-session"}
    end

    def attach(runtime, "ephemeral-session", after_event_sequence: 0) do
      send(runtime.token.test, :attached)

      {:ok,
       %Loopex.Attachment{
         runtime: runtime,
         session_id: "ephemeral-session",
         attachment_id: "a",
         incarnation_id: "i",
         snapshot: %{}
       }}
    end

    def command(%Loopex.Attachment{runtime: runtime}, command) do
      send(runtime.token.test, {:command, command})
      {:accepted, command.command_id}
    end

    def resource_catalog(runtime, "ephemeral-session") do
      send(runtime.token.test, :catalog_read)
      manifest = runtime.token.manifest
      {:ok, digest, normalized} = ResourcePack.digest(manifest)

      entries =
        for pack <- normalized["packs"] do
          %{
            "source_id" => pack["source_id"],
            "name" => pack["name"],
            "pack_digest" => ResourcePack.pack_digest(pack)
          }
        end

      {:ok,
       %{
         "configured_manifest_digest" => digest,
         "admitted_manifest_digest" => digest,
         "decision_disposition" => "active",
         "entries" => entries
       }}
    end

    def session_status(runtime, "ephemeral-session") do
      send(runtime.token.test, :status_read)

      {:ok,
       %{
         status: :active,
         owner_epoch: 0,
         active_run_id: nil,
         pending_work_ids: [],
         cleanup_grace_ms: 5_000
       }}
    end
  end

  defmodule FaultFacade do
    @moduledoc false

    def create_session(runtime, %{"surface" => "embedded"}, command_id: "create") do
      send(runtime.token.test, :created)

      if runtime.token.failure == :create,
        do: {:error, :scripted_failure},
        else: {:ok, "ephemeral-session"}
    end

    def attach(runtime, "ephemeral-session", after_event_sequence: 0) do
      send(runtime.token.test, :attached)

      if runtime.token.failure == :attach,
        do: {:error, :scripted_failure},
        else:
          {:ok,
           %Loopex.Attachment{
             runtime: runtime,
             session_id: "ephemeral-session",
             attachment_id: "a",
             incarnation_id: "i",
             snapshot: %{}
           }}
    end

    def session_status(runtime, "ephemeral-session") do
      send(runtime.token.test, :status_read)

      if runtime.token.failure == :status,
        do: {:ok, %{status: :active, owner_epoch: -1}},
        else:
          {:ok,
           %{
             status: :active,
             owner_epoch: 0,
             active_run_id: nil,
             pending_work_ids: [],
             cleanup_grace_ms: 5_000
           }}
    end
  end

  setup do
    tmp =
      Path.join(System.tmp_dir!(), "loopex-owner-startup-#{System.unique_integer([:positive])}")

    File.mkdir!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)
    {:ok, tmp: tmp}
  end

  test "public start refuses missing policy before allocating an owner" do
    before_children = DynamicSupervisor.count_children(Ephemeral.OwnerSupervisor)
    assert {:error, {:composition, :host_policy_required}} = Ephemeral.start_session([])
    assert DynamicSupervisor.count_children(Ephemeral.OwnerSupervisor) == before_children
  end

  test "the owner commits only after registering every returned edge", %{tmp: tmp} do
    test = self()

    configuration =
      configuration(tmp, %{
        runtime_holder: %{
          runtime_start: fn options ->
            send(test, {:runtime_options, options})
            supervisor = spawn_link(fn -> receive do: (:finish -> :ok) end)
            {:ok, %Runtime{supervisor: supervisor, token: test}}
          end
        },
        trace_bind: fn _handle, _runtime -> :ok end
      })
      |> Map.put(:test_facade, Facade)

    {:ok, supervisor} = DynamicSupervisor.start_link(strategy: :one_for_one)
    assert {:ok, activation} = OwnerActivation.start(supervisor)
    owner = OwnerActivation.owner(activation)
    assert {:ok, cell} = OwnerActivation.begin(activation)

    assert {:ok, :session_ready} =
             SessionOwner.start_session(owner, configuration, 6_000)

    assert_receive {:runtime_options, options}
    assert_receive :created
    assert_receive :attached
    assert_receive :status_read
    assert options[:runtime_id] =~ ~r/^ephemeral-[0-9a-f]{32}$/
    assert options[:policy_identity] == %{"id" => inspect(Policy), "revision" => "0.2.0"}
    assert options[:active_tools] == ~w(loopex.read loopex.grep loopex.find loopex.ls)
    assert length(options[:tools]) == 7
    assert options[:resource_manifest] == configuration.skills.manifest

    assert options[:executor] == %{
             module: Loopex.Executor.Local,
             reference: options[:executor].reference,
             identity: "executor-local",
             epoch: 1,
             fencing_token: 1,
             workspace_ref: configuration.skills.manifest["workspace_ref"],
             workspace_lease: "workspace"
           }

    assert is_pid(options[:executor].reference)
    assert options[:model].options[:session_cell] == cell
    assert :atomics.get(cell, 1) == 0
    Process.exit(supervisor, :shutdown)
  end

  test "the real runtime and core facade complete startup without a model call", %{tmp: tmp} do
    configuration = configuration(tmp, %{})
    {:ok, supervisor} = DynamicSupervisor.start_link(strategy: :one_for_one)
    {:ok, activation} = OwnerActivation.start(supervisor)
    owner = OwnerActivation.owner(activation)
    {:ok, cell} = OwnerActivation.begin(activation)

    assert {:ok, :session_ready} = SessionOwner.start_session(owner, configuration, 6_000)
    assert :atomics.get(cell, 1) == 0
    Process.exit(supervisor, :shutdown)
  end

  test "named skills are admitted, checked and activated in canonical order", %{tmp: tmp} do
    test = self()
    manifest = skill_manifest()
    {:ok, digest, normalized} = Loopex.ResourcePack.digest(manifest)

    configuration =
      configuration(tmp, %{
        runtime_holder: %{
          runtime_start: fn _options ->
            supervisor = spawn_link(fn -> receive do: (:finish -> :ok) end)
            {:ok, %Runtime{supervisor: supervisor, token: %{test: test, manifest: normalized}}}
          end
        },
        trace_bind: fn _handle, _runtime -> :ok end
      })
      |> Map.put(:test_facade, SkillFacade)
      |> Map.put(:test_now, fn -> ~U[2026-09-27 11:22:33Z] end)
      |> put_in([:skills, :manifest], normalized)

    {:ok, supervisor} = DynamicSupervisor.start_link(strategy: :one_for_one)
    {:ok, activation} = OwnerActivation.start(supervisor)
    owner = OwnerActivation.owner(activation)
    {:ok, _cell} = OwnerActivation.begin(activation)
    assert {:ok, :session_ready} = SessionOwner.start_session(owner, configuration, 6_000)
    assert_receive :created
    assert_receive :attached
    assert_receive {:command, admit}
    assert admit.command_id =~ ~r/^admit-resources-[0-9a-f]{32}$/
    assert admit.manifest_digest == digest

    assert admit.decision == %{
             manifest_digest: digest,
             workspace_ref: "workspace-ref",
             trust_scope: "project_skills",
             decision_source: "host_supplied",
             issued_at: "2026-09-27T11:22:33Z",
             expires_at: nil,
             revocation_state: "active"
           }

    assert_receive :catalog_read
    assert_receive {:command, first}
    assert_receive {:command, second}

    assert first.command_id =~ ~r/^activate-skill-1-[0-9a-f]{32}$/
    assert {first.name, first.supporting_labels} == {"alpha", []}

    assert second.command_id =~ ~r/^activate-skill-2-[0-9a-f]{32}$/
    assert {second.name, second.supporting_labels} == {"zeta", []}
    refute first.command_id == second.command_id

    assert_receive :status_read
    Process.exit(supervisor, :shutdown)
  end

  test "a phase failure before mkdir names no root", %{tmp: tmp} do
    configuration =
      configuration(tmp, %{
        temp_root: %{
          tmp: fn -> tmp end,
          entropy: fn 32 -> <<1>> end
        }
      })

    {:ok, supervisor} = DynamicSupervisor.start_link(strategy: :one_for_one)
    {:ok, activation} = OwnerActivation.start(supervisor)
    owner = OwnerActivation.owner(activation)
    {:ok, cell} = OwnerActivation.begin(activation)

    assert {:error, {:composition, :temporary_root_creation_failed}} =
             SessionOwner.start_session(owner, configuration, 6_000)

    assert File.ls!(tmp) == []
    assert :atomics.get(cell, 1) == 2
    Process.exit(supervisor, :shutdown)
  end

  test "a claimed-root runtime failure seals only that session", %{tmp: tmp} do
    test = self()

    configuration =
      configuration(tmp, %{
        runtime_holder: %{
          runtime_start: fn _options ->
            send(test, :runtime_start_attempted)
            {:error, :scripted_failure}
          end
        }
      })

    {:ok, supervisor} = DynamicSupervisor.start_link(strategy: :one_for_one)
    {:ok, activation} = OwnerActivation.start(supervisor)
    owner = OwnerActivation.owner(activation)
    {:ok, cell} = OwnerActivation.begin(activation)

    assert {:error, {:composition, :runtime_start_failed}} =
             SessionOwner.start_session(owner, configuration, 6_000)

    assert_receive :runtime_start_attempted
    assert File.ls!(tmp) == []
    assert :atomics.get(cell, 1) == 2
    assert Process.alive?(supervisor)
    Process.exit(supervisor, :shutdown)
  end

  for {fault, expected_cause} <- [
        {:create, {:session_create, :failed}},
        {:attach, {:attach, :failed}},
        {:status, {:attach, :failed}}
      ] do
    test "#{fault} refusal rolls back without returning a handle", %{tmp: tmp} do
      test = self()
      fault = unquote(fault)
      expected_cause = unquote(Macro.escape(expected_cause))

      configuration =
        configuration(tmp, %{
          runtime_holder: %{
            runtime_start: fn _options ->
              supervisor = spawn_link(fn -> receive do: (:finish -> :ok) end)
              {:ok, %Runtime{supervisor: supervisor, token: %{test: test, failure: fault}}}
            end
          },
          trace_bind: fn _handle, _runtime -> :ok end
        })
        |> Map.put(:test_facade, FaultFacade)

      {:ok, supervisor} = DynamicSupervisor.start_link(strategy: :one_for_one)
      {:ok, activation} = OwnerActivation.start(supervisor)
      owner = OwnerActivation.owner(activation)
      {:ok, cell} = OwnerActivation.begin(activation)

      assert {:error, ^expected_cause} = SessionOwner.start_session(owner, configuration, 6_000)
      assert_receive :created
      assert File.ls!(tmp) == []
      assert :atomics.get(cell, 1) == 2
      Process.exit(supervisor, :shutdown)
    end
  end

  test "a mismatched process-group certificate retains the owned root", %{tmp: tmp} do
    test = self()

    configuration =
      configuration(tmp, %{
        runtime_holder: %{
          runtime_start: fn _options ->
            send(test, :runtime_start_attempted)
            {:error, :scripted_failure}
          end
        },
        group_drain: fn executor, instance, owner, nonce, _deadline ->
          send(owner, {executor, instance, make_ref(), :groups_empty})
          {:ok, nonce}
        end
      })

    {:ok, supervisor} = DynamicSupervisor.start_link(strategy: :one_for_one)
    {:ok, activation} = OwnerActivation.start(supervisor)
    owner = OwnerActivation.owner(activation)
    {:ok, cell} = OwnerActivation.begin(activation)

    assert {:error,
            {:cleanup_unproved,
             %{
               root: root,
               root_ownership: :owned,
               pending: [:process_groups],
               cause: {:composition, :runtime_start_failed}
             }}} =
             SessionOwner.start_session(owner, configuration, 6_000)

    assert_receive :runtime_start_attempted
    assert File.dir?(root)
    assert :atomics.get(cell, 1) == 3
    Process.exit(supervisor, :shutdown)
  end

  test "a returned store that dies at registration never permits commit", %{tmp: tmp} do
    test = self()

    configuration =
      configuration(tmp, %{
        store_new: fn module, pid ->
          send(test, {:store_died, pid})
          Process.exit(pid, :kill)
          Loopex.Store.new(module, pid)
        end,
        runtime_holder: %{
          runtime_start: fn _options ->
            send(test, :unexpected_runtime_start)
            {:error, :must_not_start}
          end
        }
      })

    {:ok, supervisor} = DynamicSupervisor.start_link(strategy: :one_for_one)
    {:ok, activation} = OwnerActivation.start(supervisor)
    owner = OwnerActivation.owner(activation)
    {:ok, cell} = OwnerActivation.begin(activation)

    assert {:error, {:composition, :dependency_start_failed}} =
             SessionOwner.start_session(owner, configuration, 6_000)

    assert_receive {:store_died, _store_pid}
    refute_receive :unexpected_runtime_start
    assert File.ls!(tmp) == []
    assert :atomics.get(cell, 1) == 2
    Process.exit(supervisor, :shutdown)
  end

  test "a blocked mkdir cannot become an owned root after the startup deadline", %{tmp: tmp} do
    test = self()

    configuration =
      configuration(tmp, %{
        temp_root: %{
          tmp: fn -> tmp end,
          mkdir: fn path ->
            send(test, {:mkdir_blocked, self(), path})
            receive do: (:release -> File.mkdir(path))
          end
        }
      })

    creator =
      spawn(fn ->
        {:ok, supervisor} = DynamicSupervisor.start_link(strategy: :one_for_one)
        {:ok, activation} = OwnerActivation.start(supervisor)
        owner = OwnerActivation.owner(activation)
        {:ok, cell} = OwnerActivation.begin(activation)
        send(test, {:owner, owner, cell})
        result = SessionOwner.start_session(owner, configuration, 6_000)
        send(test, {:result, result})
        receive do: (:finish -> :ok)
      end)

    assert_receive {:owner, owner, cell}
    assert_receive {:mkdir_blocked, root_process, path}
    assert is_pid(root_process)
    send(owner, {:phase_result, root_process, make_ref(), :root_claim, {:ok, %{path: path}}})
    refute_receive {:result, _}, 50

    assert_receive {:result,
                    {:error,
                     {:cleanup_unproved,
                      %{
                        root: ^path,
                        root_ownership: :unknown,
                        cause: {:composition, :temporary_root_creation_failed}
                      }}}},
                   6_000

    assert :atomics.get(cell, 1) == 3
    refute File.exists?(path)
    send(creator, :finish)
  end

  defp configuration(tmp, seams) do
    {:ok, _digest, manifest} =
      Loopex.ResourcePack.digest(%{
        "version" => "loopex.resource_pack/1",
        "workspace_ref" => "workspace-ref",
        "revision" => nil,
        "packs" => []
      })

    %{
      cwd: tmp,
      model: "ollama:test",
      provider: %{credential_variable: nil},
      base_url: "http://localhost:11434",
      policy: Policy,
      tools: :read_only,
      skills: %{manifest: manifest, shadowed_skills: []},
      max_steps: 16,
      deadline_ms: 60_000,
      max_tokens: 128,
      context_token_budget: 8_192,
      test_seams:
        seams
        |> Map.put_new(:temp_root, %{tmp: fn -> tmp end})
        |> Map.put_new(:group_drain, fn executor, instance, owner, nonce, _deadline ->
          send(owner, {executor, instance, nonce, :groups_empty})
          {:ok, nonce}
        end)
    }
  end

  defp skill_manifest do
    packs =
      for name <- ["zeta", "alpha"] do
        content = "# #{name}"

        file = %{
          label: "SKILL.md",
          content: content,
          size: byte_size(content),
          digest: LoopexProtocol.Canonical.digest_bytes(content),
          contained: true
        }

        %{
          source_id: "project:#{name}",
          origin: nil,
          commit: nil,
          tree_digest: nil,
          name: name,
          description: "test skill",
          manual_only: true,
          files: [file]
        }
      end

    %{
      version: "loopex.resource_pack/1",
      workspace_ref: "workspace-ref",
      revision: nil,
      packs: packs
    }
  end
end
