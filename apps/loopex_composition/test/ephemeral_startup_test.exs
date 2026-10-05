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

    def create_session(runtime, %{"surface" => "embedded"},
          command_id: "create",
          genesis: _genesis
        ) do
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

    def create_session(runtime, %{"surface" => "embedded"},
          command_id: "create",
          genesis: _genesis
        ) do
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

      if Map.get(runtime.token, :refuse) == command.command_id,
        do: {:error, :scripted_failure},
        else: {:accepted, command.command_id}
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

    def create_session(runtime, %{"surface" => "embedded"},
          command_id: "create",
          genesis: _genesis
        ) do
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
            {:ok, supervisor} = Supervisor.start_link([], strategy: :one_for_one)
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
    assert Enum.map(options[:tools], & &1["tool_id"]) == options[:active_tools]
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
    assert options[:model].module == LoopexComposition.Model
    assert options[:model].options[:adapter] == Loopex.LLM.ReqLLM.InProcess
    assert options[:model].options[:adapter_options][:session_cell] == cell
    assert :atomics.get(cell, 1) == 0
    Process.exit(supervisor, :shutdown)
  end

  test "the real runtime and core facade complete startup without a model call", %{tmp: tmp} do
    block = %{"version" => "ephemeral.v1", "body" => "Retain exact host summary bytes 猫\n"}

    bindings = %{
      "ollama" => %{"credential" => %{"none" => true}},
      "anthropic" => %{"credential" => %{"env" => "M7_STARTUP_REFERENCE_ONLY"}}
    }

    assert {:ok, maintenance} =
             LoopexComposition.ProviderBindings.resolve_maintenance_model(
               "anthropic:claude-haiku-4-5",
               bindings
             )

    configuration =
      configuration(tmp, %{})
      |> Map.put(:maintenance_instructions, block)
      |> Map.put(:maintenance_model, maintenance)
      |> Map.put(:provider_bindings, bindings)

    {:ok, supervisor} = DynamicSupervisor.start_link(strategy: :one_for_one)
    {:ok, activation} = OwnerActivation.start(supervisor)
    owner = OwnerActivation.owner(activation)
    {:ok, cell} = OwnerActivation.begin(activation)

    assert {:ok, :session_ready} = SessionOwner.start_session(owner, configuration, 6_000)
    assert :atomics.get(cell, 1) == 0
    runtime = :sys.get_state(owner).startup.registered.runtime
    assert {:ok, children} = Runtime.children(runtime)
    assert {:ok, captured} = Loopex.Runtime.MaintenanceConfiguration.capture_instructions(block)
    assert :sys.get_state(children.control).maintenance_instructions == captured
    [{_, coordinator, _, _}] = DynamicSupervisor.which_children(children.sessions)
    assert :sys.get_state(coordinator).maintenance_instructions == captured
    assert :sys.get_state(coordinator).maintenance_model == maintenance
    model_options = :sys.get_state(coordinator).model.options
    assert model_options[:adapter_options][:provider_bindings] == bindings
    assert model_options[:host_options] == [provider_bindings: bindings]
    refute Keyword.has_key?(model_options, :credential_variable)
    assert {:ok, public} = Runtime.configuration(runtime)
    refute :erlang.term_to_binary(public) =~ block["body"]
    refute :erlang.term_to_binary(public) =~ "M7_STARTUP_REFERENCE_ONLY"
    Process.exit(supervisor, :shutdown)
  end

  test "cancellation stops a ready session whose startup reply was dropped", %{tmp: tmp} do
    configuration = configuration(tmp, %{})
    {:ok, supervisor} = DynamicSupervisor.start_link(strategy: :one_for_one)
    {:ok, activation} = OwnerActivation.start(supervisor)
    owner = OwnerActivation.owner(activation)
    {:ok, cell} = OwnerActivation.begin(activation)
    request = :erlang.alias([:reply])
    owner_monitor = Process.monitor(owner)

    send(owner, {self(), request, :start_session, configuration})
    :erlang.unalias(request)
    assert eventually(fn -> :sys.get_state(owner).phase == :ready end)
    assert :atomics.get(cell, 1) == 0

    send(owner, {self(), request, :cancel_start})
    assert_receive {:DOWN, ^owner_monitor, :process, ^owner, :normal}, 6_000
    assert :atomics.get(cell, 1) == 2
    refute_received {^owner, ^request, _}
    assert File.ls!(tmp) == []
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
            {:ok, supervisor} = Supervisor.start_link([], strategy: :one_for_one)
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
    assert admit.command_id == "admit-resources"
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

    assert {first.command_id, first.name, first.supporting_labels} ==
             {"activate-skill-1", "alpha", []}

    assert {second.command_id, second.name, second.supporting_labels} ==
             {"activate-skill-2", "zeta", []}

    assert_receive :status_read
    Process.exit(supervisor, :shutdown)
  end

  for {refused_command, expected_cause} <- [
        {"admit-resources", {:resource_admission, :failed}},
        {"activate-skill-2", {:skill_activation, :failed}}
      ] do
    test "refusing #{refused_command} rolls back the named-skill startup", %{tmp: tmp} do
      test = self()
      refused_command = unquote(refused_command)
      expected_cause = unquote(Macro.escape(expected_cause))
      {:ok, _digest, manifest} = Loopex.ResourcePack.digest(skill_manifest())

      configuration =
        configuration(tmp, %{
          runtime_holder: %{
            runtime_start: fn _options ->
              {:ok, supervisor} = Supervisor.start_link([], strategy: :one_for_one)

              {:ok,
               %Runtime{
                 supervisor: supervisor,
                 token: %{test: test, manifest: manifest, refuse: refused_command}
               }}
            end
          },
          trace_bind: fn _handle, _runtime -> :ok end
        })
        |> Map.put(:test_facade, SkillFacade)
        |> put_in([:skills, :manifest], manifest)

      {:ok, supervisor} = DynamicSupervisor.start_link(strategy: :one_for_one)
      {:ok, activation} = OwnerActivation.start(supervisor)
      owner = OwnerActivation.owner(activation)
      {:ok, cell} = OwnerActivation.begin(activation)

      assert {:error, ^expected_cause} = SessionOwner.start_session(owner, configuration, 6_000)
      assert_receive :created
      assert_receive :attached
      assert_receive {:command, %{command_id: "admit-resources"}}

      if refused_command == "admit-resources" do
        refute_received :catalog_read
      else
        assert_receive :catalog_read
        assert_receive {:command, %{command_id: "activate-skill-1", name: "alpha"}}
        assert_receive {:command, %{command_id: "activate-skill-2", name: "zeta"}}
      end

      refute_received {:command, _}
      refute_received :status_read
      assert File.ls!(tmp) == []
      assert :atomics.get(cell, 1) == 2
      assert Process.alive?(supervisor)
      Process.exit(supervisor, :shutdown)
    end
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

  test "facade client start failure rolls back before create", %{tmp: tmp} do
    test = self()

    configuration =
      configuration(tmp, %{
        facade_client_start: fn _owner, _runtime, _genesis, _facade ->
          send(test, :facade_client_start_attempted)
          raise "scripted facade client start failure"
        end,
        runtime_holder: %{
          runtime_start: fn _options ->
            send(test, :runtime_started)
            {:ok, runtime_supervisor} = Supervisor.start_link([], strategy: :one_for_one)
            {:ok, %Runtime{supervisor: runtime_supervisor, token: test}}
          end
        },
        trace_bind: fn _handle, _runtime -> :ok end
      })
      |> Map.put(:test_facade, Facade)

    {:ok, supervisor} = DynamicSupervisor.start_link(strategy: :one_for_one)
    {:ok, activation} = OwnerActivation.start(supervisor)
    owner = OwnerActivation.owner(activation)
    {:ok, cell} = OwnerActivation.begin(activation)

    assert {:error, {:client_start, :failed}} =
             SessionOwner.start_session(owner, configuration, 6_000)

    assert_receive :runtime_started
    assert_receive :facade_client_start_attempted
    refute_received :created
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
              {:ok, supervisor} = Supervisor.start_link([], strategy: :one_for_one)
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
               pending: pending,
               cause: {:composition, :runtime_start_failed}
             }}} =
             SessionOwner.start_session(owner, configuration, 6_000)

    # Concept: a false group certificate keeps the root, even if subtree stop proves.
    # Technical depth: worker DOWN and the owner slot timer may finish in either order.
    assert pending in [[:process_groups], [:process_groups, :session_subtree]]
    assert_receive :runtime_start_attempted
    assert File.dir?(root)
    assert :atomics.get(cell, 1) == 3
    Process.exit(supervisor, :shutdown)
  end

  test "a store lost before its granted handle returns never permits commit", %{tmp: tmp} do
    test = self()

    configuration =
      configuration(tmp, %{
        store_new: fn module, pid ->
          Process.exit(pid, :kill)
          send(test, {:store_died, self(), pid})
          receive do: (:release_store_handle -> Loopex.Store.new(module, pid))
        end,
        runtime_holder: %{
          runtime_start: fn _options ->
            send(test, :unexpected_runtime_start)
            {:error, :must_not_start}
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
        send(test, {:result, SessionOwner.start_session(owner, configuration, 6_000)})
        receive do: (:finish -> :ok)
      end)

    assert_receive {:owner, owner, cell}
    assert_receive {:store_died, root_process, _store_pid}

    assert eventually(fn ->
             try do
               :sys.get_state(owner).phase == :aborting
             catch
               :exit, _ -> :atomics.get(cell, 1) == 3
             end
           end)

    send(root_process, :release_store_handle)

    assert_receive {:result,
                    {:error,
                     {:cleanup_unproved,
                      %{
                        root: root,
                        pending: [:session_subtree],
                        cause: {:composition, :dependency_start_failed}
                      }}}},
                   6_000

    refute_receive :unexpected_runtime_start
    assert File.dir?(root)
    assert :atomics.get(cell, 1) == 3
    send(creator, :finish)
  end

  test "an ungranted startup phase times out without inventing an unknown child", %{tmp: tmp} do
    test = self()

    configuration =
      configuration(tmp, %{
        store_new: fn module, pid ->
          send(test, {:store_handle_blocked, self()})
          receive do: (:release_store_handle -> Loopex.Store.new(module, pid))
        end
      })

    creator =
      spawn(fn ->
        {:ok, supervisor} = DynamicSupervisor.start_link(strategy: :one_for_one)
        {:ok, activation} = OwnerActivation.start(supervisor)
        owner = OwnerActivation.owner(activation)
        {:ok, cell} = OwnerActivation.begin(activation)
        send(test, {:owner, owner, cell})
        send(test, {:result, SessionOwner.start_session(owner, configuration, 6_000)})
        receive do: (:finish -> :ok)
      end)

    on_exit(fn -> Process.exit(creator, :kill) end)
    assert_receive {:owner, owner, cell}, 6_000

    root =
      receive do
        {:store_handle_blocked, root} -> root
        {:result, _} -> flunk("startup completed before the store-handle seam")
      after
        6_000 -> flunk("startup did not reach the store-handle seam")
      end

    on_exit(fn ->
      for pid <- [owner, root] do
        resume_if_suspended(pid)
      end
    end)

    assert :erlang.suspend_process(owner)
    send(root, :release_store_handle)
    assert eventually(fn -> match?({:store_handle, _}, :sys.get_state(root).awaiting_ack) end)
    assert :erlang.suspend_process(root)
    assert :erlang.resume_process(owner)

    assert eventually(fn ->
             startup = :sys.get_state(owner).startup
             startup.expected == :workspace_lease and startup.granted == false
           end)

    # Proved teardown may move cell 1 to 2 before this observer samples it.
    assert eventually(fn -> :atomics.get(cell, 1) != 0 end, 1_200)
    resume_if_suspended(root)

    assert_receive {:result, {:error, {:composition, :workspace_lease_failed}}}, 6_000
    assert File.ls!(tmp) == []
    assert :atomics.get(cell, 1) == 2
    send(creator, :finish)
  end

  test "a granted success with an unregistrable handle remains an unknown start", %{tmp: tmp} do
    configuration =
      configuration(tmp, %{
        store_new: fn module, _pid -> Loopex.Store.new(module, self()) end
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
               pending: [:session_subtree],
               cause: {:composition, :store_start_failed}
             }}} = SessionOwner.start_session(owner, configuration, 6_000)

    assert File.dir?(root)
    assert :atomics.get(cell, 1) == 3
    Process.exit(supervisor, :shutdown)
  end

  defp eventually(fun, attempts \\ 100)
  defp eventually(_fun, 0), do: false

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end

  defp resume_if_suspended(pid) do
    try do
      :erlang.resume_process(pid)
    catch
      :error, :badarg -> :ok
    end
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
        |> Map.put_new(:group_attest, fn _executor, _instance, _nonce, _deadline -> :ok end)
        |> Map.put_new(:group_drain, fn executor, instance, owner, nonce, _deadline ->
          send(owner, {executor, instance, nonce, :groups_empty})
          {:ok, nonce}
        end)
    }
    |> LoopexComposition.PreparedSessionFixture.capture()
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
