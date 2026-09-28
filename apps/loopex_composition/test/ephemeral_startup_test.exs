defmodule LoopexComposition.Ephemeral.StartupTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias Loopex.Runtime
  alias LoopexComposition.Ephemeral.{OwnerActivation, SessionOwner}

  defmodule Policy do
    @moduledoc false
    def decide(_request), do: {:allow, nil}
  end

  setup do
    tmp =
      Path.join(System.tmp_dir!(), "loopex-owner-startup-#{System.unique_integer([:positive])}")

    File.mkdir!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)
    {:ok, tmp: tmp}
  end

  test "the owner commits only after registering every returned edge", %{tmp: tmp} do
    test = self()

    configuration =
      configuration(tmp, %{
        runtime_holder: %{
          runtime_start: fn options ->
            send(test, {:runtime_options, options})
            supervisor = spawn_link(fn -> receive do: (:finish -> :ok) end)
            {:ok, %Runtime{supervisor: supervisor, token: make_ref()}}
          end
        },
        trace_bind: fn _handle, _runtime -> :ok end
      })

    {:ok, supervisor} = DynamicSupervisor.start_link(strategy: :one_for_one)
    assert {:ok, activation} = OwnerActivation.start(supervisor)
    owner = OwnerActivation.owner(activation)
    assert {:ok, cell} = OwnerActivation.begin(activation)

    assert {:ok, {:subtree_committed, prepared}} =
             SessionOwner.start_session(owner, configuration, 6_000)

    assert_receive {:runtime_options, options}
    assert options[:runtime_id] =~ ~r/^ephemeral-[0-9a-f]{32}$/
    assert options[:policy_identity] == %{"id" => inspect(Policy), "revision" => "0.2.0"}
    assert options[:active_tools] == ~w(loopex.read loopex.grep loopex.find loopex.ls)
    assert length(options[:tools]) == 7
    assert options[:resource_manifest] == %{}
    assert options[:model].options[:session_cell] == cell
    assert prepared.root.path |> String.starts_with?(tmp)
    assert Process.alive?(prepared.supervisor)
    assert Process.alive?(prepared.runtime.supervisor)
    assert Process.alive?(prepared.runtime_holder)
    assert :atomics.get(cell, 1) == 0
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

    assert {:error,
            {:cleanup_unproved,
             %{root: root, root_ownership: :owned, cause: :runtime_start_failed}}} =
             SessionOwner.start_session(owner, configuration, 6_000)

    assert_receive :runtime_start_attempted
    assert String.starts_with?(root, tmp)
    assert :atomics.get(cell, 1) == 3
    assert Process.alive?(supervisor)
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

    assert {:error, {:cleanup_unproved, %{root_ownership: :owned}}} =
             SessionOwner.start_session(owner, configuration, 6_000)

    assert_receive {:store_died, _store_pid}
    refute_receive :unexpected_runtime_start
    assert :atomics.get(cell, 1) == 3
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
                      %{root: ^path, root_ownership: :unknown, cause: :startup_deadline_expired}}}},
                   6_000

    assert :atomics.get(cell, 1) == 3
    refute File.exists?(path)
    send(creator, :finish)
  end

  defp configuration(tmp, seams) do
    %{
      cwd: tmp,
      model: "ollama:test",
      provider: %{credential_variable: nil},
      base_url: "http://localhost:11434",
      policy: Policy,
      tools: :read_only,
      skills: %{manifest: %{}, shadowed_skills: []},
      max_steps: 16,
      deadline_ms: 60_000,
      max_tokens: 128,
      context_token_budget: 8_192,
      test_seams: Map.put_new(seams, :temp_root, %{tmp: fn -> tmp end})
    }
  end
end
